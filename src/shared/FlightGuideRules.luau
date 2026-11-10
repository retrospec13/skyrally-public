--!strict
-- Flight modes, RETURN to course and the Free-driving bead mist (docs/design/FLIGHT_GUIDE.md section 12, the owner's
-- note of 2026-10-20). Pure: numbers and Vector3 / CFrame maths only (the pocket publish / read take any object with
-- Get/SetAttribute), so tools/tests/flight_guide_spec.luau runs every rule under Lune.
--   * Two modes per player (server attribute FlightMode, from the FREE DRIVING setting; SettingsService validates it):
--       "mk"    the default, Mario Kart style: past BOUND from every course line (and outside every authored allow-pocket)
--               for BOUND_HOLD the plane is put back on the path at once, mid-air and still flying (the server's RETURN
--               frame). No caption, no button, no guide visuals.
--       "free"  fly anywhere. The only path hint is the faint bead mist. RETURN is offered after RETURN_OFFER off course;
--               a gentle automatic return fires when far (LOST_DIST) with no progress for LOST_TIME (a lost kid).
--     Both: no off-path slowdown (secret routes sit a little off the path, as in DKR 64), WRONG WAY after WRONG_WAY_S of
--     heading away (as Mario Kart), and the leash's far rescue (PlaneConfig.LEASH_RESPAWN) stays the emergency backstop.
--   * Server (4.3, 4.6): its own off-course clock, best progress that cannot leap, the per-reason return gate and frame,
--     and the checkpoint rules that keep a Free-driving chord from skipping the course.
--   * Visual guide (4.7, 8): window, station grid, fade, per-tier budgets and the presets as data, drawn by client/FlightGuide
--     with five element kinds (emit, chain, ring, gate, chevron). Particles and beams only. Free driving only.
-- courseDist is FlightController's distance to the nearest course line (main or alternate) at flight height.
local FlightGuideRules = {}

local EPS = 1e-6

-- ---------------------------------------------------------------- modes
FlightGuideRules.MODE_MK = "mk"
FlightGuideRules.MODE_FREE = "free"
-- The server owns this player attribute (server/SettingsService, from the saved freeDriving setting); the client only
-- reads it, so what the client flies by and what the server checks returns against are the same value.
FlightGuideRules.MODE_ATTR = "FlightMode"

-- Any attribute value -> a mode: only the exact string "free" is Free driving; nil, junk or "mk" is the default.
function FlightGuideRules.modeOf(v: any): string
	return if v == FlightGuideRules.MODE_FREE then FlightGuideRules.MODE_FREE else FlightGuideRules.MODE_MK
end

-- ---------------------------------------------------------------- default mode: course bounds (client)
-- 130 = the carved corridor half-width 34 (plan skyrally.flight.corridor) + one full-throttle turn radius (128 studs/s at
-- YAW_RATE 75 = 98, PlaneConfig.turnRadius): a player who overshoots a bend and turns back at the normal rate swings at
-- most that far outside the corridor, so a late turn, a wide racing line, ring chasing or a secret route a little off
-- the path never resets anyone. It is 3.8 corridor half-widths, inside the old WRONG WAY line (LEASH_WARN 200).
-- Anything further that is meant to be flown is an authored allow-pocket (map data, below).
FlightGuideRules.BOUND = 130
-- 0.3 s = three course samples at LEASH_HZ (10 Hz when the assist is off), so one noisy sample never resets; at
-- 128 studs/s it adds at most 38 studs, so the reset happens before about 170 studs out.
FlightGuideRules.BOUND_HOLD = 0.3

-- ---------------------------------------------------------------- Free driving: RETURN shortcut and lost return (client)
-- RETURN shortcut: out past OUT_ENTER (for OUT_DEBOUNCE), back under OUT_EXIT (for EXIT_DEBOUNCE); offered after
-- RETURN_OFFER out. 80 = corridor half-width 34 + the plane's span, the bots' lane stagger and a margin.
FlightGuideRules.OUT_ENTER = 80
FlightGuideRules.OUT_DEBOUNCE = 0.25
FlightGuideRules.OUT_EXIT = 60 -- 20 of hysteresis, as PlaneConfig.LEASH_CLEAR_MARGIN
FlightGuideRules.EXIT_DEBOUNCE = 0.4
FlightGuideRules.RETURN_OFFER = 2.0 -- the owner's number: RETURN shows after 2 s off course
-- Lost: further than LOST_DIST and no LOST_PROGRESS of main-route progress for LOST_TIME -> a gentle automatic return.
-- 200 = PlaneConfig.LEASH_WARN (the old WRONG WAY line), past the default mode's 130 bound, so Free driving always gets
-- more room than the default and no secret route "a little off the path" comes near it. 15 s = the top of Mario Kart's
-- 10-15 s wrong-way Lakitu, under a third of a lap (about 50 s): time to explore a hidden corner, short enough that a
-- lost kid is never stuck. 150 studs of progress (1.4 s along the course at 110) means the player is going somewhere,
-- so a far-off line flown along the course is never "lost". LOST_CLEAR: hysteresis, as LEASH_CLEAR_MARGIN.
FlightGuideRules.LOST_DIST = 200
FlightGuideRules.LOST_CLEAR = 20
FlightGuideRules.LOST_TIME = 15
FlightGuideRules.LOST_PROGRESS = 150

-- ---------------------------------------------------------------- both modes
FlightGuideRules.AWAY_DEG = 110 -- heading this far off the line ahead is "away" (an 85-radius turn is about 30)
FlightGuideRules.WRONG_WAY_S = 3.0 -- away this long: the WRONG WAY sign (lane A, top centre), as Mario Kart
FlightGuideRules.LEASH_PULL_IN_RACE = false -- MK has no pull to the path: the leash steers nobody in a race (fewer forces)
-- Auto-throttle: the idle throttle FlightController uses (the ASSIST cruise, Mario Kart Tour "drives forward for you").
-- It acts only while ASSIST is on AND a race is running (AssistRules); the player's switch wins on every device.
FlightGuideRules.AUTO_THROTTLE = 0.65

-- ---------------------------------------------------------------- return (client + server)
FlightGuideRules.RETURN_BACK = 30 -- the return station sits this far behind the best progress (never ahead)
FlightGuideRules.RETURN_LIFT = 14 -- RouteBranch.PLANE_LIFT: the flown line above the ribbon
FlightGuideRules.RETURN_SPEED = 110 -- PlaneConfig.BASE_SPEED (completeRespawn's speed)
FlightGuideRules.RETURN_GRACE = 1.6 -- PlaneConfig.RESPAWN_INVULN: nothing arms right after landing
FlightGuideRules.CLIENT_COOLDOWN = 3 -- RespawnRules.MANUAL_COOLDOWN pattern (the RETURN button)
FlightGuideRules.REPLY_TIMEOUT = 1.0 -- no server answer by then: give up (an automatic return falls back to RESPAWN)
FlightGuideRules.RETURN_COOLDOWN = 8 -- server: between two returns (button, lost, far)
FlightGuideRules.RETURN_MIN_OFF = 1.5 -- server: its own off-course clock must reach this (button, lost, far)
-- A bounds reset is the default mode's whole rule, so it must work every time: the server's clock (from 55 studs) only
-- needs 0.3 s (a plane past 130 has been past 55 for longer than that, replication lag included), and two resets need
-- only the grace plus a margin between them. A return is never ahead of best progress, so it is never a shortcut.
FlightGuideRules.BOUND_MIN_OFF = 0.3
FlightGuideRules.BOUND_COOLDOWN = 2.0
FlightGuideRules.RESPAWN_FLOOR = 1.0 -- server: CarConfig.RESPAWN_MIN_INTERVAL after any respawn
-- The reasons a client may send, and the mode each one belongs to (false = either mode).
FlightGuideRules.REASONS = { Button = "free", Bounds = "mk", Lost = "free", Far = false } :: { [string]: string | false }

-- ---------------------------------------------------------------- server off-course clock and best progress
FlightGuideRules.SERVER_OUT = 55 -- under the client's 80 and 130, so the server's clock never trails the client's
FlightGuideRules.SERVER_IN = 40
FlightGuideRules.SERVER_CLEAR = 0.4
FlightGuideRules.SPEED_CEILING = 260 -- PlaneGuardRules.SPEED_CEILING
FlightGuideRules.BEST_SLACK = 1.5
FlightGuideRules.BEST_PAD = 30

-- ================================================================ client state machine
export type Off = {
	grace: number, -- after a return / respawn: nothing arms
	-- default mode
	boundT: number, -- time held beyond BOUND (outside every pocket)
	boundFired: boolean, -- the reset fired for this excursion
	-- Free driving: the RETURN shortcut
	out: boolean,
	enterT: number, -- time held beyond OUT_ENTER while inside
	exitT: number, -- time held under OUT_EXIT while out
	outTime: number, -- continuous time out
	-- Free driving: lost
	lostT: number, -- time far with no progress
	lostAnchor: number?, -- main-route station the progress is measured from (nil = not far)
	lostFired: boolean,
	-- both
	awayT: number, -- time heading away from the line ahead
}

function FlightGuideRules.newOff(): Off
	return {
		grace = 0, boundT = 0, boundFired = false, out = false, enterT = 0, exitT = 0, outTime = 0,
		lostT = 0, lostAnchor = nil, lostFired = false, awayT = 0,
	}
end

local function clearOff(s: Off)
	s.boundT = 0
	s.boundFired = false
	s.out = false
	s.enterT = 0
	s.exitT = 0
	s.outTime = 0
	s.lostT = 0
	s.lostAnchor = nil
	s.lostFired = false
	s.awayT = 0
end

-- A return or any respawn just put the plane on the course: RETURN_GRACE with nothing armed.
function FlightGuideRules.startGrace(s: Off, seconds: number?)
	clearOff(s)
	s.grace = seconds or FlightGuideRules.RETURN_GRACE
end

-- Not racing (hub, battle, grid, finished): everything off at once.
function FlightGuideRules.resetOff(s: Off)
	clearOff(s)
	s.grace = 0
end

-- Default mode. dist: the course distance; inPocket: inside an authored allow-pocket. Returns true once per excursion:
-- put the plane back now.
function FlightGuideRules.stepBounds(s: Off, dist: number, inPocket: boolean, dt: number): boolean
	if inPocket or dist <= FlightGuideRules.BOUND then
		s.boundT = 0
		s.boundFired = false
		return false
	end
	s.boundT += dt
	if not s.boundFired and s.boundT >= FlightGuideRules.BOUND_HOLD - EPS then
		s.boundFired = true
		return true
	end
	return false
end

-- Free driving's RETURN shortcut. Returns "inside" | "out" | "offer" (RETURN may be pressed).
function FlightGuideRules.stepOff(s: Off, dist: number, dt: number): string
	if s.out then
		s.outTime += dt
		if dist < FlightGuideRules.OUT_EXIT then
			s.exitT += dt
			if s.exitT >= FlightGuideRules.EXIT_DEBOUNCE - EPS then
				s.out = false
				s.exitT = 0
				s.outTime = 0
			end
		else
			s.exitT = 0
		end
	elseif dist > FlightGuideRules.OUT_ENTER then
		s.enterT += dt
		if s.enterT >= FlightGuideRules.OUT_DEBOUNCE - EPS then
			s.out = true
			s.enterT = 0
			s.exitT = 0
			s.outTime = 0
		end
	else
		s.enterT = 0
	end
	if s.out and s.outTime >= FlightGuideRules.RETURN_OFFER - EPS then
		return "offer"
	end
	return if s.out then "out" else "inside"
end

-- Forward progress from `from` to `to` on a closed loop of `length` (a step back, or none, is <= 0).
function FlightGuideRules.progress(from: number, to: number, length: number?): number
	local d = to - from
	if length and length > 0 then
		d = (d + length / 2) % length - length / 2
	end
	return d
end

-- Free driving's lost watch. station: the main-route station of the plane's nearest point; trackLength: the loop length
-- (for the wrap at the line). Returns true once per lost spell: return the plane gently now.
function FlightGuideRules.stepLost(s: Off, dist: number, station: number, trackLength: number?, dt: number): boolean
	if dist < FlightGuideRules.LOST_DIST - FlightGuideRules.LOST_CLEAR then
		s.lostT = 0
		s.lostAnchor = nil
		s.lostFired = false
		return false
	end
	local anchor = s.lostAnchor
	if anchor == nil then
		if dist <= FlightGuideRules.LOST_DIST then
			return false -- in the hysteresis band without having been far: nothing yet
		end
		s.lostAnchor = station
		s.lostT = 0
		return false
	end
	if FlightGuideRules.progress(anchor, station, trackLength) >= FlightGuideRules.LOST_PROGRESS then
		s.lostAnchor = station -- going somewhere: not lost, measure again from here
		s.lostT = 0
		return false
	end
	s.lostT += dt
	if not s.lostFired and s.lostT >= FlightGuideRules.LOST_TIME - EPS then
		s.lostFired = true
		return true
	end
	return false
end

-- WRONG WAY (both modes). yawErrDeg: the heading error toward the line ahead (the pursuit point; +-180). True once
-- heading away for WRONG_WAY_S; facing the line again clears it at once.
function FlightGuideRules.stepWrongWay(s: Off, yawErrDeg: number, dt: number): boolean
	if math.abs(yawErrDeg) > FlightGuideRules.AWAY_DEG then
		s.awayT += dt
	else
		s.awayT = 0
	end
	return s.awayT >= FlightGuideRules.WRONG_WAY_S - EPS
end

export type Sample = {
	dist: number, -- course distance (nearest course line at flight height)
	inPocket: boolean, -- inside an authored allow-pocket
	station: number, -- main-route station of the nearest point
	trackLength: number?,
	yawErr: number, -- heading error toward the line ahead (deg)
}

-- One client step in a race. Returns (verdict, wrong way):
--   "inside" | "out" | "offer"  Free driving's RETURN shortcut state ("inside" always in the default mode)
--   "bounds"                    default mode: past the bounds, put the plane back now (no caption, no button)
--   "lost"                      Free driving: far with no progress for LOST_TIME, return it gently now
-- Nothing arms during the grace after a return or respawn.
function FlightGuideRules.stepMode(s: Off, mode: string, c: Sample, dt: number): (string, boolean)
	if s.grace > 0 then
		s.grace = math.max(0, s.grace - dt)
		clearOff(s)
		return "inside", false
	end
	local wrong = FlightGuideRules.stepWrongWay(s, c.yawErr, dt)
	if mode ~= FlightGuideRules.MODE_FREE then
		return if FlightGuideRules.stepBounds(s, c.dist, c.inPocket, dt) then "bounds" else "inside", wrong
	end
	local verdict = FlightGuideRules.stepOff(s, c.dist, dt)
	if FlightGuideRules.stepLost(s, c.dist, c.station, c.trackLength, dt) then
		return "lost", wrong
	end
	return verdict, wrong
end

-- The throttle with no throttle input: the ASSIST cruise while ASSIST is on and a race runs, else none. Planes never stop:
-- throttle 0 is still BASE_SPEED.
function FlightGuideRules.idleThrottle(autoThrottle: boolean, racing: boolean): number
	if autoThrottle and racing then
		return FlightGuideRules.AUTO_THROTTLE
	end
	return 0
end

-- ================================================================ allow-pockets (map data)
-- Per-map volumes where off-line flight is allowed and the default mode never resets: plan skyrally.flight.allowPockets,
-- a list of { kind = "sphere", center = {x, y, z}, radius } or { kind = "capsule", a = {x, y, z}, b = {x, y, z}, radius }
-- in world studs (tools/map/adapt.py validates them; docs/MAP_PLAN_SCHEMA.md). MapAdapter publishes them as attributes
-- on the track root (AllowPocketCount, AllowPocketA<i> / AllowPocketB<i> Vector3, AllowPocketR<i>); a sphere is a
-- capsule with a = b. Checked only once the plane is past BOUND, so the per-frame cost on the path is nothing.
FlightGuideRules.POCKET_MAX = 16
FlightGuideRules.POCKET_MAX_R = 200

export type Pocket = { a: Vector3, b: Vector3, r: number }

local function v3(p: any): Vector3?
	if typeof(p) == "Vector3" then
		return p
	elseif type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and type(p[3]) == "number" then
		return Vector3.new(p[1], p[2], p[3])
	end
	return nil
end

-- One plan / TrackData entry -> a pocket, or nil when it is malformed.
function FlightGuideRules.cleanPocket(e: any): Pocket?
	if type(e) ~= "table" then
		return nil
	end
	local r = e.radius
	if type(r) ~= "number" or r ~= r or r <= 0 or r > FlightGuideRules.POCKET_MAX_R then
		return nil
	end
	if e.kind == "sphere" then
		local c = v3(e.center)
		return if c then { a = c, b = c, r = r } else nil
	elseif e.kind == "capsule" then
		local a, b = v3(e.a), v3(e.b)
		return if a and b then { a = a, b = b, r = r } else nil
	end
	return nil
end

function FlightGuideRules.cleanPockets(list: any): { Pocket }
	local out: { Pocket } = {}
	if type(list) == "table" then
		for _, e in list :: { any } do
			local p = FlightGuideRules.cleanPocket(e)
			if p and #out < FlightGuideRules.POCKET_MAX then
				table.insert(out, p)
			end
		end
	end
	return out
end

-- True when pos is inside any pocket (distance to the capsule's segment <= its radius).
function FlightGuideRules.inPocket(pockets: { Pocket }, pos: Vector3): boolean
	for _, p in pockets do
		local ab = p.b - p.a
		local len2 = ab:Dot(ab)
		local t = if len2 > EPS then math.clamp((pos - p.a):Dot(ab) / len2, 0, 1) else 0
		if (pos - (p.a + ab * t)).Magnitude <= p.r then
			return true
		end
	end
	return false
end

-- Server (MapAdapter): writes the cleaned pockets as attributes on the track root. Returns the count.
function FlightGuideRules.publishPockets(root: any, list: any): number
	local pockets = FlightGuideRules.cleanPockets(list)
	for i, p in pockets do
		root:SetAttribute("AllowPocketA" .. i, p.a)
		root:SetAttribute("AllowPocketB" .. i, p.b)
		root:SetAttribute("AllowPocketR" .. i, p.r)
	end
	root:SetAttribute("AllowPocketCount", #pockets)
	return #pockets
end

-- Client and server: the pockets a track root carries (none when it has no AllowPocketCount yet).
function FlightGuideRules.readPockets(root: any): { Pocket }
	local out: { Pocket } = {}
	local n = if root then root:GetAttribute("AllowPocketCount") else nil
	if type(n) ~= "number" then
		return out
	end
	for i = 1, math.min(n, FlightGuideRules.POCKET_MAX) do
		local a, b, r = root:GetAttribute("AllowPocketA" .. i), root:GetAttribute("AllowPocketB" .. i), root:GetAttribute("AllowPocketR" .. i)
		if typeof(a) == "Vector3" and typeof(b) == "Vector3" and type(r) == "number" and r > 0 then
			table.insert(out, { a = a, b = b, r = r })
		end
	end
	return out
end

-- ================================================================ server
export type ServerGuide = {
	offTime: number, -- continuous time beyond SERVER_OUT (held in the 40..55 band, cleared after SERVER_CLEAR inside 40)
	inT: number,
	best: number?, -- best main-route station this lap (nil until the first on-course sample)
	age: number, -- seconds since best last advanced
	lastReturn: number, -- os.clock() of the last return
	dist: number, -- the last course distance (main line and alternates), for the checkpoint rule
}

function FlightGuideRules.newServerGuide(): ServerGuide
	return { offTime = 0, inT = 0, best = nil, age = 0, lastReturn = -math.huge, dist = 0 }
end

-- Best progress: advances only while on course and only by what a legal plane could have flown since it last
-- advanced (SPEED_CEILING x BEST_SLACK x age + BEST_PAD), so a teleport or a forged position cannot leap it forward,
-- while a real chord back onto the line still catches up. Returns true when it advanced.
function FlightGuideRules.advanceBest(g: ServerGuide, st: number, dt: number, onCourse: boolean): boolean
	g.age += dt
	if not onCourse then
		return false
	end
	local best = g.best
	if best == nil then
		g.best = st
		g.age = 0
		return true
	end
	if st <= best then
		return false
	end
	local allowed = FlightGuideRules.BEST_SLACK * FlightGuideRules.SPEED_CEILING * g.age + FlightGuideRules.BEST_PAD
	if st - best > allowed then
		return false
	end
	g.best = st
	g.age = 0
	return true
end

-- A new lap (or a race reset): the next on-course sample sets best again.
function FlightGuideRules.newLap(g: ServerGuide)
	g.best = nil
	g.age = 0
end

-- One server step: the off-course clock and the best progress.
function FlightGuideRules.stepServer(g: ServerGuide, dist: number, st: number, dt: number)
	g.dist = dist
	if dist > FlightGuideRules.SERVER_OUT then
		g.offTime += dt
		g.inT = 0
	elseif dist < FlightGuideRules.SERVER_IN then
		g.inT += dt
		if g.inT >= FlightGuideRules.SERVER_CLEAR - EPS then
			g.offTime = 0
		end
	else
		g.inT = 0
	end
	FlightGuideRules.advanceBest(g, st, dt, dist <= FlightGuideRules.SERVER_OUT)
end

-- Not racing / a car / finished: the clock is cleared (best is kept: a mid-race car swap never happens on plane maps).
function FlightGuideRules.idleServer(g: ServerGuide)
	g.offTime = 0
	g.inT = 0
end

-- The return station: at or behind best progress minus RETURN_BACK, never ahead of the nearest point either, never
-- below 0 (no wrap back across the line, which would confuse the lap gate).
function FlightGuideRules.returnStation(nearest: number, best: number?, back: number?): number
	local b = back or FlightGuideRules.RETURN_BACK
	local s = if best then math.min(nearest, best) else nearest
	return math.max(0, s - b)
end

export type ReturnCtx = {
	mode: any, -- workspace RaceMode
	started: boolean, -- past RaceGoTime
	switching: boolean, -- workspace TrackSwitching
	battleOut: boolean,
	finished: boolean,
	trusted: boolean, -- not PositionTrusted == false
	isCar: boolean,
	offTime: number, -- the server's clock
	sinceReturn: number,
	sinceRespawn: number,
	reason: any, -- the client's reason (REASONS)
	flightMode: string, -- the player's FlightMode (modeOf the server attribute)
}

-- The server's gate for RequestCourseReturn. Returns (ok, why). A reason must be known and belong to the player's mode;
-- a default-mode bounds reset has its own short clock and cooldown (BOUND_MIN_OFF, BOUND_COOLDOWN), every other reason
-- the RETURN ones.
function FlightGuideRules.canReturn(c: ReturnCtx): (boolean, string)
	local want = if type(c.reason) == "string" then FlightGuideRules.REASONS[c.reason] else nil
	local bounds = c.reason == "Bounds"
	if c.mode == "hub" or c.mode == "battle" then
		return false, "mode"
	elseif c.isCar then
		return false, "car"
	elseif want == nil then
		return false, "reason"
	elseif want and want ~= c.flightMode then
		return false, "flightMode"
	elseif not c.started or c.switching then
		return false, "notRacing"
	elseif c.battleOut then
		return false, "battleOut"
	elseif c.finished then
		return false, "finished"
	elseif not c.trusted then
		return false, "untrusted"
	elseif c.offTime < (if bounds then FlightGuideRules.BOUND_MIN_OFF else FlightGuideRules.RETURN_MIN_OFF) - EPS then
		return false, "onCourse"
	elseif c.sinceReturn < (if bounds then FlightGuideRules.BOUND_COOLDOWN else FlightGuideRules.RETURN_COOLDOWN) - EPS then
		return false, "cooldown"
	elseif c.sinceRespawn < FlightGuideRules.RESPAWN_FLOOR - EPS then
		return false, "respawnFloor"
	end
	return true, "ok"
end

-- A level frame at `pos` looking along the horizontal part of `dir`, built with fromMatrix (exact on Roblox and under
-- Lune; RespawnRules uses the same construction).
function FlightGuideRules.frameAt(pos: Vector3, dir: Vector3): CFrame
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local look = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local right = look:Cross(Vector3.yAxis).Unit
	local up = right:Cross(look).Unit
	return CFrame.fromMatrix(pos, right, up)
end

-- The return frame from the ribbon point and tangent at the return station: lifted to the flown line, level, facing
-- along the course.
function FlightGuideRules.returnFrame(ribbonPoint: Vector3, tangent: Vector3): CFrame
	return FlightGuideRules.frameAt(ribbonPoint + Vector3.new(0, FlightGuideRules.RETURN_LIFT, 0), tangent)
end

-- ================================================================ checkpoints (server, planes)
-- Free driving lets a plane leave the course anywhere, and the old lap rule (CHECKPOINT_GATE_FRACTION 0.55 of the gates,
-- one credited when the plane's projected station is within 110 of it) let a chord across the map skip almost half of
-- them. For a plane in a race (either mode: a client that lies about its mode gains nothing) a checkpoint now counts
-- when the plane passes near the gate itself (CP_GATE studs), or by station only while it is on the course: within
-- CP_COURSE_DIST of a course line (= BOUND, where a default-mode player can fly) or inside an allow-pocket. A lap needs
-- every checkpoint an alternate line does not bypass (strictly between its join and rejoin stations), less CP_SLACK
-- (one projection glitch at an over/under crossing must not hold a lap).
FlightGuideRules.CP_GATE = 85 -- RaceManager's gate radius
FlightGuideRules.CP_COURSE_DIST = FlightGuideRules.BOUND
FlightGuideRules.CP_SLACK = 1

-- nearGate: within CP_GATE of the gate; stationHit: the projected station within the station window; courseDist: the
-- server's course distance (main line and alternates); inPocket: inside an allow-pocket.
function FlightGuideRules.checkpointCounts(nearGate: boolean, stationHit: boolean, courseDist: number, inPocket: boolean): boolean
	return nearGate or (stationHit and (courseDist <= FlightGuideRules.CP_COURSE_DIST or inPocket))
end

-- The checkpoints a plane's lap must pass: every one no alternate line bypasses (a bypassed one sits strictly inside an
-- alternate's (join, rejoin) stretch). cps: { index, station } (RaceManager.checkpoints); lines: RouteBranch lines (a
-- line without both join and rejoin is a dead end like the key gallery and bypasses nothing). Returns their indices.
function FlightGuideRules.mustPassCheckpoints(cps: { any }, lines: { any }): { number }
	local out: { number } = {}
	for _, cp in cps do
		local st = cp.station
		local bypassed = false
		for _, l in lines do
			local j, r = l.join, l.rejoin
			if type(j) == "number" and type(r) == "number" and st > j + EPS and st < r - EPS then
				bypassed = true
				break
			end
		end
		if not bypassed then
			table.insert(out, cp.index)
		end
	end
	return out
end

-- A plane's lap gates: at most CP_SLACK of the must-pass checkpoints missing (on top of the old fraction rule).
function FlightGuideRules.planeGatesOk(passed: { [number]: boolean }, must: { number }): boolean
	local missing = 0
	for _, idx in must do
		if not passed[idx] then
			missing += 1
		end
	end
	return missing <= FlightGuideRules.CP_SLACK
end

-- ================================================================ visual guide (Free driving only)
FlightGuideRules.NEAR = 70 -- nothing nearer the plane (the chase camera sits 15.2 behind it)
FlightGuideRules.FAR = 560 -- about 5 s of road at 110
FlightGuideRules.FADE_IN = 80 -- over the first studs of the window
FlightGuideRules.FADE_OUT = 160 -- over the last studs of the window
FlightGuideRules.CAM_CLEAR = 25 -- an element this close to the camera shows nothing
FlightGuideRules.R_IN = 12 -- the annulus around the line: outside the plane's 15.6 span ...
FlightGuideRules.R_OUT = 26 -- ... inside the 34-stud corridor
FlightGuideRules.HZ = { desktop = 10, phone = 10, low = 6 } :: { [string]: number }
FlightGuideRules.MIN_T_PARTICLE = 0.55
FlightGuideRules.MIN_T_BEAM = 0.7
-- Free driving draws the guide at this share of its visibility: the owner asked for the bead mist "more transparent than
-- in the images" (the mockups drew the beads at the 0.55 floor). 0.5 puts the beads at 0.78 transparency at best and the
-- mist at 0.89; the default mode draws nothing at all.
FlightGuideRules.FREE_ALPHA = 0.5

export type Tier = string -- "desktop" | "phone" | "low"
-- Live guide particles (rate x lifetime x emitters), node scale and Instance cap per tier (section 8).
FlightGuideRules.BUDGET = { desktop = 90, phone = 54, low = 30 } :: { [string]: number }
FlightGuideRules.NODE_SCALE = { desktop = 1, phone = 0.7, low = 0.5 } :: { [string]: number }
FlightGuideRules.INSTANCE_CAP = { desktop = 40, phone = 26, low = 18 } :: { [string]: number }

-- Settings.particleScale() is 1 desktop, 0.6 phone, 0.4 LOW GRAPHICS.
function FlightGuideRules.tierOf(low: boolean, phone: boolean): Tier
	local tier: Tier = if low then "low" elseif phone then "phone" else "desktop"
	return tier
end

-- Owner's pick (2026-10-20): the bead mist, on every tier (phones and LOW GRAPHICS draw fewer nodes, LOW GRAPHICS
-- without the mist layer). A workspace or player attribute GuidePreset (a preset id, or "off") overrides it, for the
-- pick board and QA.
FlightGuideRules.DEFAULT_PRESET = "bead_mist"
FlightGuideRules.PHONE_PRESET = "bead_mist"

-- Tints (LightEmission 1, never fully saturated; ART_BAR). Per map: snow warmer so it reads on white and blue,
-- dino pale cyan-white so it reads on red rock and lava. Final colours at the Studio review.
FlightGuideRules.TINT_DEFAULT = { core = { 255, 246, 222 }, edge = { 255, 226, 150 } }
FlightGuideRules.TINTS = {
	["SNOW-1"] = { core = { 255, 238, 220 }, edge = { 255, 200, 150 } },
	["DINO-4"] = { core = { 236, 250, 255 }, edge = { 190, 236, 255 } },
	["FOREST-1"] = { core = { 255, 246, 222 }, edge = { 255, 226, 150 } },
} :: { [string]: { core: { number }, edge: { number } } }

function FlightGuideRules.tintFor(trackId: string?): { core: { number }, edge: { number } }
	return (if trackId then FlightGuideRules.TINTS[trackId] else nil) or FlightGuideRules.TINT_DEFAULT
end

-- Element kinds (client/FlightGuide draws each with pooled Attachments + ParticleEmitters or Beams):
--   emit     one emitter per offset per node. offsets = { {lateral, vertical} } on the node frame, or spiral = degrees
--            per node with radius (a soft spiral around the line). tex = VfxAssets key. locked = particles ride the node.
--   chain    one beam chain through the nodes at offset (a ribbon / streamer).
--   ring     a faint ring of radius around the line: two arc beams per node.
--   gate     two posts and a lintel (three beams) at +-halfW, +-halfH.
--   chevron  two beams meeting at a tip that points ahead, at offset.
export type Layer = { [string]: any }
export type Preset = {
	id: string,
	spacing: number, -- studs between nodes on the line's own grid
	nodes: number, -- node count at the desktop tier (NODE_SCALE shrinks it)
	layers: { Layer },
	minT: number?, -- transparency floor override (never under the kind's floor)
}

local R_MID = (FlightGuideRules.R_IN + FlightGuideRules.R_OUT) / 2

FlightGuideRules.PRESETS = {
	-- slow drifting soft dots spiralling round the line (the recommended default)
	motes = { id = "motes", spacing = 48, nodes = 10, layers = {
		{ kind = "emit", tex = "glow_soft", spiral = 137.5, radius = R_MID, rate = 3, life = 3, size = 2.2, speed = 0.8,
			spread = 180, drag = 0.6 },
	} },
	-- very faint thin rings forming a tunnel
	ring_tunnel = { id = "ring_tunnel", spacing = 80, nodes = 7, layers = {
		{ kind = "ring", radius = 22, width = 0.35 },
	} },
	-- one thin translucent contrail below the eye line
	ribbon = { id = "ribbon", spacing = 52, nodes = 10, layers = {
		{ kind = "chain", offset = { 0, -3 }, width = 0.6, tex = "trail_soft" },
	} },
	-- tiny light gates, nearly transparent
	gates = { id = "gates", spacing = 150, nodes = 4, layers = {
		{ kind = "gate", halfW = 24, halfH = 11, width = 0.4 },
	} },
	-- chevrons pointing ahead, low on the line
	chevron_stream = { id = "chevron_stream", spacing = 64, nodes = 6, layers = {
		{ kind = "chevron", offset = { 0, -4 }, halfW = 3.2, depth = 2.6, width = 0.45 },
	} },
	-- a low sparkle flow along the line
	sparkle_river = { id = "sparkle_river", spacing = 60, nodes = 8, layers = {
		{ kind = "emit", tex = "star_twinkle", offsets = { { 0, -5 } }, rate = 5, life = 1.6, size = 1.2, speed = 2,
			spread = 35, drag = 1.5 },
	} },
	-- two faint parallel cloud wisps either side of the line
	wisp_lane = { id = "wisp_lane", spacing = 80, nodes = 6, layers = {
		{ kind = "emit", tex = "glow_soft", offsets = { { -18, -1 }, { 18, -1 } }, rate = 2, life = 2.4, size = 3,
			speed = 0.6, spread = 25, drag = 0.4, stretch = true },
	} },
	-- a dotted string of small glowing beads below the eye line (cheap: ~1 live particle per bead)
	beads = { id = "beads", spacing = 40, nodes = 12, layers = {
		{ kind = "emit", tex = "glow_soft", offsets = { { 0, -3 } }, rate = 2, life = 0.6, size = 0.9, speed = 0,
			spread = 0, locked = true },
	} },
	-- Free driving (owner 2026-10-20): the bead string with a soft mist drifting round each bead, both fainter than the
	-- mockup (alpha: the layer's share of the visibility). LOW GRAPHICS drops the mist (noLow).
	bead_mist = { id = "bead_mist", spacing = 48, nodes = 10, layers = {
		{ kind = "emit", tex = "glow_soft", offsets = { { 0, -3 } }, rate = 2, life = 0.6, size = 0.9, speed = 0,
			spread = 0, locked = true },
		{ kind = "emit", tex = "glow_soft", offsets = { { 0, -3 } }, rate = 0.5, life = 2.4, size = 3.5, speed = 0.4,
			spread = 180, drag = 0.6, alpha = 0.5, noLow = true },
	} },
	-- glow arrows resting on small clouds
	cloud_arrows = { id = "cloud_arrows", spacing = 200, nodes = 3, layers = {
		{ kind = "emit", tex = "glow_soft", offsets = { { 0, -6 } }, rate = 2, life = 1.5, size = 4, speed = 0.3,
			spread = 180, drag = 0.5 },
		{ kind = "chevron", offset = { 0, -3 }, halfW = 3.6, depth = 3, width = 0.5 },
	} },
	-- two thin side streamers marking the corridor edges
	streamers = { id = "streamers", spacing = 60, nodes = 9, layers = {
		{ kind = "chain", offset = { -FlightGuideRules.R_OUT, 0 }, width = 0.5, tex = "trail_soft" },
		{ kind = "chain", offset = { FlightGuideRules.R_OUT, 0 }, width = 0.5, tex = "trail_soft" },
	} },
} :: { [string]: Preset }

-- The mockup order (docs/design/FLIGHT_GUIDE.md 4.7; the pick board shows them 1:1).
FlightGuideRules.ORDER = {
	"motes", "ring_tunnel", "ribbon", "gates", "chevron_stream", "sparkle_river", "wisp_lane", "beads", "cloud_arrows", "streamers",
	"bead_mist",
} :: { string }

-- The preset to draw: the override (attribute) when it names a preset, "off" -> nil, else by tier.
function FlightGuideRules.presetFor(override: any, tier: Tier): Preset?
	if override == "off" then
		return nil
	end
	if type(override) == "string" and FlightGuideRules.PRESETS[override] then
		return FlightGuideRules.PRESETS[override]
	end
	return FlightGuideRules.PRESETS[if tier == "desktop" then FlightGuideRules.DEFAULT_PRESET else FlightGuideRules.PHONE_PRESET]
end

-- Emitters and Instances one node of a layer costs.
local function layerEmitters(l: Layer): number
	if l.kind ~= "emit" then
		return 0
	end
	return if l.spiral then 1 else #(l.offsets :: { any })
end

local ATTACH_PER = { ring = 2, gate = 4, chevron = 3, chain = 1 } :: { [string]: number }
local BEAM_PER = { ring = 2, gate = 3, chevron = 2, chain = 1 } :: { [string]: number }

-- Instances for `nodes` nodes of a layer (attachments + emitters / beams; a chain has nodes - 1 beams).
function FlightGuideRules.layerInstances(l: Layer, nodes: number): number
	if l.kind == "emit" then
		return nodes * layerEmitters(l) * 2
	elseif l.kind == "chain" then
		return nodes + math.max(0, nodes - 1)
	end
	return nodes * ((ATTACH_PER[l.kind] or 0) + (BEAM_PER[l.kind] or 0))
end

-- The layers a tier draws: all of them, except noLow layers on the LOW GRAPHICS tier (a new table only then; called
-- when a pool is built, never per frame).
function FlightGuideRules.layersFor(p: Preset, tier: Tier): { Layer }
	if tier ~= "low" then
		return p.layers
	end
	local out: { Layer } = {}
	for _, l in p.layers do
		if not l.noLow then
			table.insert(out, l)
		end
	end
	return out
end

-- A layer's transparency floor: the kind's floor (particles 0.55, beams 0.7), raised by the layer's alpha share.
function FlightGuideRules.layerFloor(l: Layer): number
	local floor = if l.kind == "emit" then FlightGuideRules.MIN_T_PARTICLE else FlightGuideRules.MIN_T_BEAM
	return 1 - (1 - floor) * math.clamp(if type(l.alpha) == "number" then l.alpha else 1, 0, 1)
end

-- Live particles of a preset at `nodes` nodes and full rate (on `tier`; default desktop: every layer).
function FlightGuideRules.liveParticles(p: Preset, nodes: number, tier: Tier?): number
	local n = 0
	for _, l in FlightGuideRules.layersFor(p, tier or "desktop") do
		if l.kind == "emit" then
			n += nodes * layerEmitters(l) * l.rate * l.life
		end
	end
	return n
end

export type Plan = { nodes: number, rateMul: number, instances: number, particles: number }

-- What a tier draws of a preset: the node count (NODE_SCALE, then trimmed to the Instance cap) and the rate
-- multiplier that keeps live particles within the tier's budget.
function FlightGuideRules.plan(p: Preset, tier: Tier): Plan
	local nodes = math.max(2, math.ceil(p.nodes * (FlightGuideRules.NODE_SCALE[tier] or 1) - EPS))
	local layers = FlightGuideRules.layersFor(p, tier)
	local function instancesAt(n: number): number
		local total = 0
		for _, l in layers do
			total += FlightGuideRules.layerInstances(l, n)
		end
		return total
	end
	local cap = FlightGuideRules.INSTANCE_CAP[tier] or 40
	while nodes > 2 and instancesAt(nodes) > cap do
		nodes -= 1
	end
	local live = FlightGuideRules.liveParticles(p, nodes, tier)
	local budget = FlightGuideRules.BUDGET[tier] or 90
	local rateMul = if live > budget then budget / live else 1
	return { nodes = nodes, rateMul = rateMul, instances = instancesAt(nodes), particles = live * rateMul }
end

-- The grid positions (studs along the line) of the nodes ahead of `at`: multiples of spacing in (at + near, at + far],
-- at most maxNodes, written into `out` (a reused buffer) and returned with the count. Grid-anchored, so the nodes do
-- not swim with the plane; the caller recycles slot (index % pool) as a node falls behind.
function FlightGuideRules.nodeStations(at: number, spacing: number, near: number, far: number, maxNodes: number, out: { number }): ({ number }, number)
	local first = math.floor((at + near) / spacing) + 1
	local n = 0
	local g = first
	while n < maxNodes do
		local s = g * spacing
		if s > at + far + EPS then
			break
		end
		n += 1
		out[n] = s
		g += 1
	end
	for i = n + 1, #out do
		out[i] = nil
	end
	return out, n
end

-- Visibility 0..1 of an element `ahead` studs along the line from the plane and `camDist` from the camera: nothing
-- inside CAM_CLEAR or outside the window, a ramp in over FADE_IN and out over FADE_OUT.
function FlightGuideRules.alphaAt(ahead: number, camDist: number): number
	local near, far = FlightGuideRules.NEAR, FlightGuideRules.FAR
	if camDist < FlightGuideRules.CAM_CLEAR or ahead < near - EPS or ahead > far + EPS then
		return 0
	end
	local a = math.min(1, (ahead - near) / FlightGuideRules.FADE_IN, (far - ahead) / FlightGuideRules.FADE_OUT)
	return math.clamp(a, 0, 1)
end

-- Transparency for a visibility, never under the layer's floor (layerFloor).
function FlightGuideRules.transparencyAt(alpha: number, floor: number): number
	return 1 - (1 - floor) * math.clamp(alpha, 0, 1)
end

-- Alpha quantised to LEVELS steps so the client reuses cached NumberSequences (no churn at 10 Hz).
FlightGuideRules.LEVELS = 8 -- 8, not 4: FREE_ALPHA x the window fade needs steps under a quarter
function FlightGuideRules.level(alpha: number): number
	return math.clamp(math.floor(alpha * FlightGuideRules.LEVELS + 0.5), 0, FlightGuideRules.LEVELS)
end

return FlightGuideRules
