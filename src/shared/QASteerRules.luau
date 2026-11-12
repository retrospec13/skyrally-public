--!strict
-- Studio-only QA steering hook, pure (no Roblox services; tools/tests/qa_steer_spec.luau runs it under Lune).
-- A Studio verification agent cannot press a precise line (VirtualInputManager is blocked, command-bar requires get separate
-- module copies, real-key calls cost ~1.3 s), and AutoPilot follows the main route only. These workspace attributes fix that:
--   QAFollowLine = "Alt2" | "Alt1" | "cliff" | "span" | <line id>   with AutoPilot = true: the LOCAL vehicle's existing AutoPilot
--       pursues that TrackData.alternates line (published under the track root as AltRoutes) instead of the main route: from
--       JOIN_LEAD studs of main-route station before the line's join to the end of its polyline, then back on the main spline
--       from the line's rejoin station. Matches the line id first (case-insensitive), then the first line of that style.
--       The pursuit is dropped ("lost") after a respawn or when the vehicle leaves the line, until the next join.
--   QASteer / QAThrottle = number -1..1   override the steer axis / throttle of the running controller (AutoPilot or not), so a
--       probe can hold an exact input. Clamped; non-numbers and NaN are ignored.
-- Everything is gated by RunService:IsStudio() at the call sites (client controllers) and cleared by the server in a live
-- server (guard). Only the INPUTS the controller already feeds its physics are chosen: no teleport, no physics, adhesion,
-- wall-climb or rescue change (owner HARD RULE: wall and mountain driving stay as they are).
local RouteBranch = require(script.Parent:WaitForChild("RouteBranch"))

local QASteerRules = {}

QASteerRules.FOLLOW_ATTR = "QAFollowLine"
QASteerRules.STEER_ATTR = "QASteer"
QASteerRules.THROTTLE_ATTR = "QAThrottle"
QASteerRules.JOIN_LEAD = 90 -- studs of main-route station before the join at which the line pursuit starts
QASteerRules.END_MARGIN = 3 -- studs before the polyline's end counted as "left the line"
QASteerRules.RESET_GAP = 260 -- studs of station from the join after which a finished line may be taken again (next lap)
-- V8 (DINO-4 Alt1 lap 3): a respawn puts the vehicle back on the main route, which can be 80+ studs from the line with rock in
-- between, and the pursuit kept aiming at the line through the rock: crash, respawn, repeat for 5+ minutes. So the pursuit
-- is dropped ("lost") after a respawn (the vehicle jumped further than RESPAWN_JUMP studs in one frame) or when the vehicle,
-- having reached the line (within ARRIVE_DIST), is more than LOST_DIST studs from it, and stays dropped until the next join.
QASteerRules.RESPAWN_JUMP = 60
QASteerRules.ARRIVE_DIST = 40
QASteerRules.LOST_DIST = 70

export type State = { phase: string, lineId: string?, arrived: boolean }

function QASteerRules.newState(): State
	return { phase = "main", lineId = nil, arrived = false }
end

-- The hook exists only in Studio. Every read goes through this.
function QASteerRules.enabled(isStudio: boolean): boolean
	return isStudio == true
end

-- A number -1..1, or nil for anything else (nil, strings, NaN).
function QASteerRules.axis(isStudio: boolean, v: any): number?
	if not isStudio or type(v) ~= "number" or v ~= v then
		return nil
	end
	return math.clamp(v, -1, 1)
end

-- The requested line name (non-empty string) or nil.
function QASteerRules.lineName(isStudio: boolean, v: any): string?
	if not isStudio or type(v) ~= "string" or v == "" then
		return nil
	end
	return v
end

-- Picks the line called `name` (id, case-insensitive; else the first line of that style).
function QASteerRules.findLine(lines: { RouteBranch.Line }, name: string): RouteBranch.Line?
	local want = string.lower(name)
	for _, line in lines do
		if string.lower(line.id) == want and #line.points >= 2 then
			return line
		end
	end
	for _, line in lines do
		if string.lower(line.style) == want and #line.points >= 2 then
			return line
		end
	end
	return nil
end

-- Stations ahead of `from` to reach `to` on a looped track (nil length: plain difference).
local function forwardGap(from: number, to: number, trackLength: number?): number
	local d = to - from
	if trackLength and trackLength > 0 then
		d = d % trackLength
	end
	return d
end

-- One frame of the follow state machine. Returns the new phase event ("join" | "rejoin" | "reset" | "lost") or nil.
-- main  -> line  when the vehicle is within JOIN_LEAD studs (station) before the join, or just past it
-- line  -> done  at the end of the polyline (then the caller pursues the main spline from line.rejoin)
-- done  -> main  once the vehicle is RESET_GAP studs from the join (a later lap may take the line again)
-- line  -> lost  after a respawn (`jump` > RESPAWN_JUMP) or when it left the line (`lateral` > LOST_DIST after arriving)
-- lost  -> main  once it is back before the join (inside JOIN_LEAD) or RESET_GAP studs past it: the next join
-- `lateral` (distance to the line) and `jump` (studs moved since the last frame) are optional.
function QASteerRules.step(
	s: State,
	line: RouteBranch.Line?,
	station: number,
	along: number,
	trackLength: number?,
	lateral: number?,
	jump: number?
): string?
	if not line then
		if s.phase ~= "main" then
			s.phase, s.lineId = "main", nil
			return "lost"
		end
		return nil
	end
	local join = line.join
	local ahead = if join then forwardGap(station, join, trackLength) else 0
	if s.phase == "main" then
		local near = not join or ahead <= QASteerRules.JOIN_LEAD or (trackLength ~= nil and ahead >= trackLength - 30)
		if near then
			s.phase, s.lineId, s.arrived = "line", line.id, false
			return "join"
		end
	elseif s.phase == "line" then
		if jump and jump > QASteerRules.RESPAWN_JUMP then
			s.phase = "lost"
			return "lost"
		end
		if lateral then
			if lateral <= QASteerRules.ARRIVE_DIST then
				s.arrived = true
			elseif s.arrived and lateral > QASteerRules.LOST_DIST then
				s.phase = "lost"
				return "lost"
			end
		end
		if along >= line.length - QASteerRules.END_MARGIN then
			s.phase = "done"
			return "rejoin"
		end
	elseif s.phase == "lost" then
		local before = join ~= nil and ahead > 0 and ahead <= QASteerRules.JOIN_LEAD
		local away = if join then math.min(ahead, (trackLength or math.huge) - ahead) else math.huge
		if before or away > QASteerRules.RESET_GAP then
			s.phase, s.lineId = "main", nil
			return "reset"
		end
	elseif s.phase == "done" then
		local away = if join then math.min(ahead, (trackLength or math.huge) - ahead) else math.huge
		if away > QASteerRules.RESET_GAP then
			s.phase, s.lineId = "main", nil
			return "reset"
		end
	end
	return nil
end

-- The point to pursue and whether it is on the line (false: the caller keeps the main route). `lookahead` in studs.
function QASteerRules.target(s: State, line: RouteBranch.Line, along: number, lookahead: number): (Vector3?, number)
	if s.phase ~= "line" then
		return nil, 0
	end
	return RouteBranch.target(line, along, lookahead)
end

-- What the AutoPilot pursues this frame: a point on the line, or a main-spline station (the caller samples it), or neither
-- (nil, nil: the caller keeps its own main-route target). On the line the pursuit point runs `lookahead` along the polyline
-- (RouteBranch.target); once that runs past the polyline's end, the rest of the lookahead continues along the main spline
-- from the rejoin station. Clamping the point onto the line's last vertex instead collapsed the lookahead onto the car in the
-- last metres, where a stud of lateral offset swung the steer error past the drift threshold with either sign: on ISLAND-2
-- Alt2 (V7A) laps 2 and 3 locked a LEFT drift there and the car crossed the road into the sea. After the line ("done") the
-- pursuit continues from the car's own station when it is already past the rejoin, never from a fixed point behind it.
function QASteerRules.pursue(s: State, line: RouteBranch.Line, along: number, lookahead: number, station: number, trackLength: number?): (Vector3?, number?)
	if s.phase == "line" then
		local p, over = RouteBranch.target(line, along, lookahead)
		if over > 0 and line.rejoin then
			return nil, line.rejoin + over
		end
		return p, nil
	elseif s.phase == "done" and line.rejoin then
		local past = forwardGap(line.rejoin, station, trackLength)
		local base = if past < QASteerRules.RESET_GAP then station else line.rejoin
		return nil, base + lookahead
	end
	return nil, nil
end

-- AutoPilot drift button: held through a bend (|steer error| > DRIFT_ERR_DEG at speed), released when a drift that is
-- running was locked to the other side (CarController locks the drift direction at its start and only widens it while it is
-- held, so a wrong-way drift would carry the car off the outside of the bend). driftDir: -1 / 1 while drifting, else 0.
QASteerRules.DRIFT_ERR_DEG = 22
QASteerRules.DRIFT_MIN_SPEED = 70
QASteerRules.DRIFT_WRONG_DEG = 8 -- steer error on the far side of a running drift at which the button lets go

function QASteerRules.autoDrift(errDeg: number, speed: number, drifting: boolean, driftDir: number): boolean
	if drifting and driftDir ~= 0 and errDeg * driftDir < -QASteerRules.DRIFT_WRONG_DEG then
		return false
	end
	return math.abs(errDeg) > QASteerRules.DRIFT_ERR_DEG and speed > QASteerRules.DRIFT_MIN_SPEED
end

-- Live-server guard: clears every QA attribute on `ws` (anything with SetAttribute) when not in Studio. Returns whether it ran.
function QASteerRules.guard(isStudio: boolean, ws: any): boolean
	if isStudio then
		return false
	end
	for _, a in { QASteerRules.FOLLOW_ATTR, QASteerRules.STEER_ATTR, QASteerRules.THROTTLE_ATTR } do
		if ws:GetAttribute(a) ~= nil then
			ws:SetAttribute(a, nil)
		end
	end
	return true
end

-- V4-1 (tooling hygiene, Studio only): the workspace attributes a verification run sets stay set after it. The pilot tools clear
-- them at start (tools/lane.py clear_qa_luau runs this list on the server DataModel; win/key_pilot.js does the same).
-- QAGoal is deliberately not listed: BattleCore publishes it and tools/key_check.py sets it before the pilot starts.
QASteerRules.PILOT_WORKSPACE_ATTRS = { "AutoPilot", "QAFollowLine", "QASteer", "QAThrottle" }
QASteerRules.RESPAWN_ATTR = "QARespawnAt"
QASteerRules.RESPAWN_RAY_UP = 10 -- the ground ray starts this far above the requested point (a point inside a floor still counts)
QASteerRules.RESPAWN_RAY_LEN = 600

-- Clears every pilot attribute on `ws` and the one-shot respawn attribute on each player. Returns how many were set.
function QASteerRules.clearPilotAttrs(ws: any, players: { any }?): number
	local list: { any } = if players then players else {}
	local n = 0
	for _, a in QASteerRules.PILOT_WORKSPACE_ATTRS do
		if ws:GetAttribute(a) ~= nil then
			ws:SetAttribute(a, nil)
			n += 1
		end
	end
	for _, p in list do
		if p:GetAttribute(QASteerRules.RESPAWN_ATTR) ~= nil then
			p:SetAttribute(QASteerRules.RESPAWN_ATTR, nil)
			n += 1
		end
	end
	return n
end

-- A QARespawnAt point is accepted only with ground under it: `hitY` is the raycast hit height (nil = no ground). A point with
-- none made the car fall, respawn at the same checkpoint and fall again (V4-1: 18 min below the map).
function QASteerRules.respawnGroundOk(hitY: number?): boolean
	return type(hitY) == "number" and hitY == hitY
end

function QASteerRules.logLine(vehicle: string, event: string, line: RouteBranch.Line, station: number, along: number): string
	return string.format("[SkyRally][QASTEER] %s %s line %s (%s) at station %.0f along %.0f/%.0f", vehicle, event, line.id, line.style, station, along, line.length)
end

return QASteerRules
