--!strict
-- Pure rules for the DINO-4 launch upgrade (docs/design/TRACK_VARIETY.md 5a). No services, no Instances beyond
-- Vector3 values: server/VolcanoVents (the check), client/VolcanoMoments (the effects and the crossing) and
-- tools/tests/volcano_spec.luau all read the same numbers.
-- * GEYSER updraft (Alt1 only): a non-collidable vent on a FIXED 4 s cycle that is a pure function of server time
--   (workspace:GetServerTimeNow()) plus the vent's phase, so every client and the server agree with no traffic. The
--   cycle is dormant (a faint ember glow), then build-up (the telegraph: the crater brightens and steam thickens,
--   1.6 s), then ACTIVE (a column of steam and sparks, 1.2 s). Crossing the column while it is ACTIVE gives the
--   ordinary ring boost. The server re-checks the stage and the position when the client reports the crossing. It is
--   never a hazard: no damage, no stun, no collision, and missing the window costs nothing.
-- * ERUPTION (the final lap): when the local racer starts lap 3 the volcano wakes. The lava glow pulses, ash drifts
--   down, a rumble sounds on a fixed beat, and the camera gets a small shake. Everything is a pure function of the
--   seconds since the lap began, capped for phone players, and never hides the route.
local VolcanoRules = {}

---------------------------------------------------------------------------------------------------- geyser vents

VolcanoRules.CYCLE = 4 -- seconds, fixed
VolcanoRules.DORMANT = 1.2 -- faint glow
VolcanoRules.BUILD = 1.6 -- telegraph: the crater brightens, steam thickens
VolcanoRules.ACTIVE = 1.2 -- the column; DORMANT + BUILD + ACTIVE == CYCLE
VolcanoRules.RADIUS = 12 -- horizontal reach of the column (Alt1's tunnel is 26 studs wide)
VolcanoRules.HEIGHT = 26 -- reach above the vent base (the flight line sits 12 studs above the floor)
VolcanoRules.SERVER_SLACK = 0.45 -- seconds of network and clock slack the server grants either side of the window
VolcanoRules.SERVER_REACH = 8 -- extra studs of horizontal slack for the server's position check
VolcanoRules.CLAIM_REACH = 3 -- slack on the client-reported position (the client tests the exact column)
VolcanoRules.LAG_MAX = 60 -- studs: the most the server hull may trail a client position, however fast or laggy
VolcanoRules.LAG_FLOOR = 12 -- studs: the least allowance (a slow plane still trails by a physics step)
VolcanoRules.STEP = 1 / 30 -- one physics/replication step, seconds
VolcanoRules.INTERP = 0.2 -- seconds: the server's copy of a client-owned hull trails by the replication buffer even at
-- zero ping (Studio V7A: 17-35 studs at ~170 studs/s with near-zero ping), so this term is ping-independent
VolcanoRules.COOLDOWN = 3.5 -- seconds before the same player can take the same vent again (once per cycle)
VolcanoRules.BOOST_KIND = "Standard" -- the ring boost; never the overcharge

export type Vent = {
	id: string,
	pos: Vector3, -- centre of the crater on the floor
	phase: number, -- seconds added to the clock: staggers two vents
	radius: number,
	height: number,
}

export type Stage = "dormant" | "build" | "active"

-- Seconds into the vent's cycle, 0 <= t < CYCLE.
function VolcanoRules.cycleTime(now: number, phase: number): number
	return (now - phase) % VolcanoRules.CYCLE
end

-- Stage and progress (0..1) through that stage.
function VolcanoRules.stage(now: number, phase: number): (Stage, number)
	local t = VolcanoRules.cycleTime(now, phase)
	local dormant, build = VolcanoRules.DORMANT, VolcanoRules.BUILD
	if t < dormant then
		return "dormant", t / dormant
	elseif t < dormant + build then
		return "build", (t - dormant) / build
	end
	return "active", (t - dormant - build) / VolcanoRules.ACTIVE
end

-- Crater glow 0..1: faint when dormant, rising through the build-up, full while active, so the telegraph reads from a
-- distance and the column never arrives without it.
function VolcanoRules.glow(now: number, phase: number): number
	local s, k = VolcanoRules.stage(now, phase)
	if s == "dormant" then
		return 0.12
	elseif s == "build" then
		return 0.12 + 0.68 * k * k
	end
	return 1 - 0.25 * k
end

-- Steam particles per second for the (client-side) emitter: a trickle, a thickening build-up, then the column.
function VolcanoRules.steamRate(now: number, phase: number, scale: number): number
	local s, k = VolcanoRules.stage(now, phase)
	local r = if s == "dormant" then 2 elseif s == "build" then 4 + 14 * k else 50
	return r * math.clamp(scale, 0, 1)
end

-- True while the column is up. `slack` widens the window on both sides (the server passes SERVER_SLACK).
function VolcanoRules.isActive(now: number, phase: number, slack: number?): boolean
	local sl = math.clamp(slack or 0, 0, VolcanoRules.DORMANT + VolcanoRules.BUILD - 0.1)
	local t = VolcanoRules.cycleTime(now, phase)
	local a0 = VolcanoRules.DORMANT + VolcanoRules.BUILD
	return t >= a0 - sl or t < sl -- the second half is the slack past the end of the cycle
end

-- Seconds until the column is next up (0 while it is up): for tests and the QA print.
function VolcanoRules.untilActive(now: number, phase: number): number
	local t = VolcanoRules.cycleTime(now, phase)
	local a0 = VolcanoRules.DORMANT + VolcanoRules.BUILD
	if t >= a0 then
		return 0
	end
	return a0 - t
end

-- Is `pos` inside the vent's column (a cylinder: radius around the vertical axis, from just under the crater to
-- height above it)? `reach` widens the radius and the height (the server's slack).
function VolcanoRules.inColumn(vent: Vent, pos: Vector3, reach: number?): boolean
	local r = vent.radius + (reach or 0)
	local dx, dz = pos.X - vent.pos.X, pos.Z - vent.pos.Z
	if dx * dx + dz * dz > r * r then
		return false
	end
	local dy = pos.Y - vent.pos.Y
	return dy >= -(reach or 0) and dy <= vent.height + (reach or 0)
end

-- How far the server's copy of a hull may trail the client's: speed * (replication buffer + one-way ping + one step),
-- clamped. `ping` is the
-- round-trip seconds (nil = assume 0.2).
function VolcanoRules.lagAllowance(speed: number, ping: number?): number
	local rtt = math.clamp(ping or 0.2, 0, 0.5)
	return math.clamp(math.max(speed, 0) * (VolcanoRules.INTERP + rtt / 2 + VolcanoRules.STEP), VolcanoRules.LAG_FLOOR, VolcanoRules.LAG_MAX)
end

-- The server's verdict on a reported crossing: the stage at the report (with slack), the position, the cooldown.
-- `pos` is the server's hull position (it lags the client). `claim` is the position the client reported: it counts when it
-- is inside the column (CLAIM_REACH slack) AND within `allowance` studs of the server hull, so an honest fast crossing
-- passes while a teleport claim (far from where the server sees the plane) is refused. Without a claim the server hull
-- must itself be in the column (SERVER_REACH). `lastTaken` is the server time this player last took this vent (or nil).
function VolcanoRules.validate(vent: Vent, pos: Vector3, now: number, lastTaken: number?, claim: Vector3?, allowance: number?): (boolean, string)
	if lastTaken and now - lastTaken < VolcanoRules.COOLDOWN then
		return false, "cooldown"
	end
	if not VolcanoRules.isActive(now, vent.phase, VolcanoRules.SERVER_SLACK) then
		return false, "dormant"
	end
	if VolcanoRules.inColumn(vent, pos, VolcanoRules.SERVER_REACH) then
		return true, "ok"
	end
	if claim and VolcanoRules.inColumn(vent, claim, VolcanoRules.CLAIM_REACH) then
		local lim = math.clamp(allowance or VolcanoRules.LAG_FLOOR, 0, VolcanoRules.LAG_MAX)
		if (claim - pos).Magnitude <= lim then
			return true, "ok"
		end
		return false, "far"
	end
	return false, "far"
end

-- One vent row from plan data (TrackData.geysers). nil for malformed data.
function VolcanoRules.parseVent(row: any): Vent?
	if type(row) ~= "table" or type(row.id) ~= "string" or typeof(row.pos) ~= "Vector3" then
		return nil
	end
	local phase = if type(row.phase) == "number" then row.phase else 0
	local radius = if type(row.radius) == "number" then math.clamp(row.radius, 4, 20) else VolcanoRules.RADIUS
	local height = if type(row.height) == "number" then math.clamp(row.height, 8, 40) else VolcanoRules.HEIGHT
	return { id = row.id, pos = row.pos, phase = phase, radius = radius, height = height }
end

---------------------------------------------------------------------------------------------------- lap-3 eruption

VolcanoRules.ERUPTION_LAP = 3 -- the lap the volcano wakes on (TrackData.eruption.lap overrides it)
VolcanoRules.RAMP = 2.5 -- seconds from the first tremor to the full eruption mood
VolcanoRules.BEAT = 9 -- seconds between rumbles; the first is at 0
VolcanoRules.RUMBLE_SEC = 2.4 -- how long one rumble swell lasts
VolcanoRules.PULSE_PERIOD = 2.2 -- lava glow pulse
VolcanoRules.GLOW_MAX = 1.1 -- peak Brightness of the lava light under the racer (a PointLight, Range LIGHT_RANGE)
VolcanoRules.LIGHT_RANGE = 55
VolcanoRules.ASH_MAX = 14 -- particles per second at full strength, before the phone scale: a drift, never a curtain
VolcanoRules.ASH_SIZE_MAX = 0.7 -- studs
VolcanoRules.ASH_TRANSPARENCY_MIN = 0.45 -- ash is never more opaque than this
VolcanoRules.SHAKE_MAX = 0.1 -- camera trauma per rumble at its peak (a boost is 0.2)
VolcanoRules.RUMBLE_VOLUME = 0.45
VolcanoRules.RUMBLE_SPEED = 0.4 -- playback speed of the stand-in swell (a sample pitched down)

-- True when lap `lap` of `laps` is the eruption lap and the mode is a race.
function VolcanoRules.erupting(lap: number?, eruptionLap: number?): boolean
	return type(lap) == "number" and lap == (eruptionLap or VolcanoRules.ERUPTION_LAP)
end

-- 0..1 eruption mood `t` seconds after the lap began: ramps in, then stays.
function VolcanoRules.level(t: number): number
	if t <= 0 then
		return 0
	end
	local x = math.clamp(t / VolcanoRules.RAMP, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Lava light Brightness: a slow pulse that swells with each rumble.
function VolcanoRules.lavaLight(t: number): number
	local lv = VolcanoRules.level(t)
	if lv <= 0 then
		return 0
	end
	local pulse = 0.5 + 0.5 * math.sin(2 * math.pi * t / VolcanoRules.PULSE_PERIOD)
	local swell = VolcanoRules.rumbleSwell(t)
	return VolcanoRules.GLOW_MAX * lv * math.clamp(0.35 + 0.45 * pulse + 0.35 * swell, 0, 1)
end

-- 0..1 swell of the rumble at time t (a half sine over RUMBLE_SEC at the start of every BEAT).
function VolcanoRules.rumbleSwell(t: number): number
	if t < 0 then
		return 0
	end
	local into = t % VolcanoRules.BEAT
	if into >= VolcanoRules.RUMBLE_SEC then
		return 0
	end
	return math.sin(math.pi * into / VolcanoRules.RUMBLE_SEC)
end

-- True when a rumble starts between the previous frame time and this one (the first at t = 0).
function VolcanoRules.rumbleStarts(prevT: number, t: number): boolean
	if t < 0 or t <= prevT then
		return false
	end
	local prevBeat = if prevT < 0 then -1 else math.floor(prevT / VolcanoRules.BEAT)
	return math.floor(t / VolcanoRules.BEAT) > prevBeat
end

-- Ash particles per second (scale is the phone/low-graphics particle scale, 0..1).
function VolcanoRules.ashRate(t: number, scale: number): number
	return VolcanoRules.ASH_MAX * VolcanoRules.level(t) * math.clamp(scale, 0, 1)
end

-- Camera trauma to add as a rumble starts.
function VolcanoRules.shake(): number
	return VolcanoRules.SHAKE_MAX
end

return VolcanoRules
