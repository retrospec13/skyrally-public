--!strict
-- Pure decisions for the server's check of a PLANE's replicated position (L30, L53). The owning client simulates its
-- plane (network ownership) and RaceManager credits whatever rec.hull.Position says, so without this a client could
-- set its hull onto each checkpoint and the finish arch in turn. Cars already went through CarConfig.observe; planes
-- use the same budget validator with their own limits, and the finish needs a lap time no legal flight can beat.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CarConfig = require(Shared:WaitForChild("CarConfig"))
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))

local PlaneGuardRules = {}

-- The most any legal source reaches: FlightServer and FlightController both clamp a reported/boost speed to 260; the
-- overcharge boost with every speed pickup is OVERCHARGE_SPEED + pickups = 224, below that.
PlaneGuardRules.SPEED_CEILING = 260
PlaneGuardRules.PULL_ALLOWANCE = 40 -- ring pull, magnet and dive assist on top of the ceiling
-- Allowance on top of the legal speed (the car's is 1.6): it only covers replication jitter. 1.5 keeps a 2 s
-- replication stall at 224 studs/s (448) inside the budget cap, one second of travel at the slacked speed (458).
PlaneGuardRules.SLACK = 1.5
-- A finish earlier than this fraction of the track at OVERCHARGE_SPEED is not flown (shortcut branches are well under
-- 15% shorter than the spline, and nobody holds the overcharge for a lap).
PlaneGuardRules.MIN_LAP_FRACTION = 0.65
PlaneGuardRules.MIN_LAP_FLOOR = 8.0 -- the old fixed floor, kept for short or unloaded splines
-- V5-1: travel credited on arrival at a server teleport (RETURN frame, respawn): 0.2 s at the slacked limit (about
-- 98 studs with the tolerance) covers a replication burst right after landing; a jump still bigger is corrected.
PlaneGuardRules.ARRIVAL_SECONDS = 0.2

function PlaneGuardRules.limits(): CarConfig.Limits
	local top = math.max(PlaneGuardRules.SPEED_CEILING, PlaneConfig.OVERCHARGE_SPEED + PlaneConfig.SPEED_PICKUP_BONUS * PlaneConfig.MAX_SPEED_PICKUPS)
	local v = top + PlaneGuardRules.PULL_ALLOWANCE
	-- A plane dives and climbs along its heading, so the vertical bounds are the speed bound too.
	return { maxH = v, maxRise = v, maxFall = v, slack = PlaneGuardRules.SLACK, arrivalSeconds = PlaneGuardRules.ARRIVAL_SECONDS }
end

-- Shortest lap time (s) the finish check accepts for a track of `totalLen` studs.
function PlaneGuardRules.minLapSeconds(totalLen: number): number
	if totalLen ~= totalLen or totalLen <= 0 then
		return PlaneGuardRules.MIN_LAP_FLOOR
	end
	return math.max(PlaneGuardRules.MIN_LAP_FLOOR, PlaneGuardRules.MIN_LAP_FRACTION * totalLen / PlaneConfig.OVERCHARGE_SPEED)
end

-- True when the lap took long enough to have been flown (FastLapTest is the QA bypass).
function PlaneGuardRules.lapTimeOk(lapElapsed: number, totalLen: number, fastLapTest: boolean): boolean
	return fastLapTest or lapElapsed >= PlaneGuardRules.minLapSeconds(totalLen)
end

return PlaneGuardRules
