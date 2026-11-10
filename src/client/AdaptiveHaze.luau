--!strict
-- Adaptive haze (owner, FOREST-1 2026-10-20: "too much of the map is waiting to load until you get closer"). Rules and
-- the why: shared/AdaptiveHazeRules; design and Studio recipe: docs/design/ADAPTIVE_HAZE.md.
-- At 10 Hz the map's SkyRally_Atmosphere is thickened on this client so the engine's current terrain draw distance
-- (client/DressingLod's estimate: Studio level, slider, or frame time under Automatic; phones at the Level01 cut) sits
-- inside the haze: Density toward reach / radius within the map's clamps, Offset / Haze / Color toward the map's low
-- look by the same weight, the density moving at most UP_RATE / DOWN_RATE per second (no pumping). At a high graphics
-- level the target is the art look and the atmosphere returns to it.
-- The art look is whatever the live Atmosphere holds that this module did not write: a new instance (LightingProfiles
-- re-applied on a map switch) is read fresh and snaps to its target; a value someone else wrote (StormCup night)
-- becomes the new art value. While FinishLighting stages the podium nothing is written (it restores to our last write).
-- Writes are local Atmosphere properties only; nothing else in Lighting, nothing on the server.
-- Studio A/B: workspace attribute AdaptiveHazeOff = true restores the art look; AdaptiveHazeReach (number) forces the
-- curve's REACH; DressingLodRadius forces the radius for both modules. LocalPlayer attribute AdaptiveHazeState reads
-- "map=<id> r=<radius> src=<source> d=<applied>/<target> art=<density> w=<weight>".
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("AdaptiveHazeRules"))
local Prof = require(Shared:WaitForChild("Prof"))
local DressingLod = require(script.Parent:WaitForChild("DressingLod"))
local FinishLighting = require(script.Parent:WaitForChild("FinishLighting"))

local AdaptiveHaze = {}

local atmo: Atmosphere? = nil
local art: Rules.Look? = nil -- the art-directed look of the current instance
local written: Rules.Look? = nil -- what this module last wrote (read back), nil when the art look is on
local applied = 0 -- applied density
local fresh = true -- next pass snaps to the target (new instance or map)
local lastMap: string? = nil
local lastState = ""
local lastLogged = ""

local function read(a: Atmosphere): Rules.Look
	return { density = a.Density, offset = a.Offset, haze = a.Haze, color = a.Color }
end

local function findAtmosphere(): Atmosphere?
	local a = Lighting:FindFirstChild(Rules.ATMOSPHERE)
	if a and a:IsA("Atmosphere") then
		return a
	end
	return nil
end

-- Adopt values someone else wrote since our last write as the new art look.
local function adopt(a: Atmosphere)
	local cur = read(a)
	local base = art :: Rules.Look
	local mine = written
	if not mine then
		art = cur
		return
	end
	if Rules.differs(cur.density, mine.density) then
		base.density = cur.density
	end
	if Rules.differs(cur.offset, mine.offset) then
		base.offset = cur.offset
	end
	if Rules.differs(cur.haze, mine.haze) then
		base.haze = cur.haze
	end
	if Rules.colorDiffers(cur.color, mine.color) then
		base.color = cur.color
	end
end

local function write(a: Atmosphere, look: Rules.Look)
	local eps = Rules.EPS
	if math.abs(a.Density - look.density) > eps then
		a.Density = look.density
	end
	if math.abs(a.Offset - look.offset) > eps then
		a.Offset = look.offset
	end
	if math.abs(a.Haze - look.haze) > eps then
		a.Haze = look.haze
	end
	if Rules.colorDiffers(a.Color, look.color) then
		a.Color = look.color
	end
	written = read(a)
end

local function restore()
	local a, base = atmo, art
	if a and base and a.Parent and written then
		adopt(a)
		write(a, art :: Rules.Look)
	end
	written = nil
end

local function tick()
	local a = findAtmosphere()
	if a ~= atmo then
		atmo = a
		art = if a then read(a) else nil
		written = nil
		fresh = true
	end
	local mapId = RaceAttr.mine("ActiveTrackId")
	local id = if type(mapId) == "string" then mapId else nil
	if id ~= lastMap then
		lastMap = id
		fresh = true
	end
	if not a or not art then
		return
	end
	if FinishLighting.isActive() then
		return -- the podium stage owns the atmosphere; it restores our last write on release
	end
	local cfg = Rules.forMap(id)
	if workspace:GetAttribute(Rules.OFF_ATTR) == true or not cfg or workspace:GetAttribute("TrackSwitching") == true then
		restore()
		fresh = true
		return
	end
	adopt(a)
	local base = art :: Rules.Look
	local radius, src = DressingLod.estimate()
	local reach = workspace:GetAttribute(Rules.REACH_ATTR)
	local target = Rules.targetDensity(radius, base.density, cfg, if type(reach) == "number" then reach else nil)
	if fresh then
		applied = target
		fresh = false
	else
		applied = Rules.step(applied, target, Rules.TICK)
	end
	local look = Rules.look(applied, base, cfg)
	write(a, look)
	local r = if radius == math.huge then "inf" else tostring(math.floor(radius + 0.5))
	local state = string.format("map=%s r=%s src=%s d=%.3f/%.3f art=%.3f w=%.2f", tostring(id), r, src, look.density,
		target, base.density, Rules.weight(applied, base.density, cfg))
	if state ~= lastState then
		lastState = state
		local lp = Players.LocalPlayer
		if lp then
			lp:SetAttribute(Rules.STATE_ATTR, state)
		end
	end
	-- Log once each time the haze settles on a new target (not per frame-time wobble in the source label).
	local key = string.format("%s %.3f", tostring(id), target)
	if math.abs(applied - target) < 1e-4 and key ~= lastLogged then
		lastLogged = key
		print("[SkyRally][HAZE] " .. state)
	end
end

function AdaptiveHaze.init()
	local step = Prof.wrap("SR_AdaptiveHaze", tick)
	task.spawn(function()
		while true do
			task.wait(Rules.TICK)
			local ok, err = pcall(function()
				step()
			end)
			if not ok then
				warn("[SkyRally][HAZE] " .. tostring(err))
			end
		end
	end)
end

return AdaptiveHaze
