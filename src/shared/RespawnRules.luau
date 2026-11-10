--!strict
-- Way-out rules (trap audit G5, X-02, X-06, H0-05, G4, D4-02 fix 4): the pure parts of "no player is ever trapped",
-- shared by the car and plane clients and the server, specced under Lune (tools/tests/respawn_spec.luau).
-- * Manual respawn: one press (RESPAWN button, Backspace, gamepad View/Select) per MANUAL_COOLDOWN on the client; the
--   server keeps its own floor SERVER_MANUAL_FLOOR a little under it, so clock jitter never rejects an honest press
--   (a rejected request would leave the client to time out onto its cached frame).
-- * Stuck watchdog: a vehicle whose pilot is trying (gas or steer held, or touch auto-gas) but that has not left a
--   STUCK_RADIUS ball for STUCK_OFFER seconds gets the RESPAWN button pulsing; at STUCK_AUTO the rescue runs by itself.
-- * Water depth: the deeper of the terrain sea and the battle tide (the tide part is CanQuery off, so no ray sees it;
--   its level is published as TideLevel), limited to the tide disk.
-- * Hub rescue frame: the nearest of the hub anchors (TrackData hub.respawns) and the route frame under the crash,
--   the route only within HUB_ROUTE_REACH (horizontal) of it.
-- * Crash-loop guard: a crash within LOOP_RADIUS of the previous one inside LOOP_WINDOW seconds is a loop; the next
--   respawn gets LOOP_INVULN seconds of protection and (planes) the course assist forced on ("RESCUE GLIDE").
-- * Hub vehicle exchange: which pad a vehicle is on and where the swapped vehicle appears.
local RespawnRules = {}

RespawnRules.MANUAL_COOLDOWN = 3 -- client: seconds between manual respawns (the button greys out meanwhile)
RespawnRules.SERVER_MANUAL_FLOOR = 2.5 -- server: manual requests closer together than this are ignored
RespawnRules.AFTER_RESPAWN_GAP = 1.2 -- client: no manual press this soon after any respawn (server RESPAWN_MIN_INTERVAL 1.0)

RespawnRules.STUCK_RADIUS = 8 -- studs: leaving this ball counts as progress
RespawnRules.STUCK_OFFER = 3 -- seconds trying with no progress: offer the rescue (button pulse and hint)
RespawnRules.STUCK_AUTO = 6 -- seconds trying with no progress: rescue without asking
RespawnRules.TRYING_INPUT = 0.3 -- |throttle| or |steer| at least this = the pilot is trying to move
-- OURS (H0-05, v20 Studio note: a car stuck on a hub kerb): letting go of the controls this long or less only pauses
-- the watch. A kid stuck on a kerb lifts a thumb, looks, and tries again; resetting on the first idle frame meant a
-- stop-and-go driver never reached STUCK_AUTO.
RespawnRules.STUCK_IDLE_GRACE = 1.0
-- OWNER RULE (2026-10-20): driving up walls and mountains stays exactly as it was. A grounded car whose road normal
-- is tilted past CLIMB_UP_Y (about 26 degrees) is climbing, and for it the watch keeps the stage-v21 behaviour: letting
-- go of the controls or a spin-out resets it (no idle grace, no spin freeze), so a kid rocking up a slope is never
-- rescued sooner than before. The H0-05 grace applies on level ground only (the hub kerb trap).
RespawnRules.CLIMB_UP_Y = 0.9

RespawnRules.TIDE_SERVER_WAIT = 0.6 -- client: a tide drown waits this long for the server's own drown answer before asking

RespawnRules.HUB_ROUTE_REACH = 120 -- hub: the route frame counts within this horizontal distance of the crash
RespawnRules.HUB_ROUTE_LIFT = 4 -- hub: route frames sit this far over the ribbon (the car drops onto the deck)
-- OURS (H0-05): a stuck rescue never sets the car down on the spot it was stuck on. A frame (route or anchor) within
-- HUB_STUCK_CLEAR horizontally of the stuck car is that trap; the route frame moves HUB_STUCK_ADVANCE ahead instead.
RespawnRules.HUB_STUCK_CLEAR = 12
RespawnRules.HUB_STUCK_ADVANCE = 30

-- Respawn protection (trap audit G2, H0-07), shared by server and client. The server's item and hazard window,
-- counted from its respawn stamp (FlightServer LastRespawnClock; server/kit/ItemEffects.RESPAWN_IMMUNE_SECONDS reads
-- this). A car's stamp lands when its RequestRespawn arrives, before the reply and the fade-in, so about 2 s of it is
-- visible protected driving; every client draws the bubble for the seconds the server sends ("respawnShield").
RespawnRules.RESPAWN_GRACE = 2.5
-- Client: an item "hit" reaching this client while its vehicle is still respawning, or this soon after the respawn
-- completed, was decided by the server before the respawn stamp (in flight across the respawn); it is dropped.
RespawnRules.HIT_STALE_WINDOW = 0.6

RespawnRules.LOOP_RADIUS = 40
RespawnRules.LOOP_WINDOW = 20
RespawnRules.LOOP_INVULN = 3

RespawnRules.EXCHANGE_DWELL = 0.5 -- seconds on a pad before the swap
-- E1: a plane crosses the 36-stud pad chord in ~0.46 s even braking (78 studs/s) and the hub steps at 5 Hz, so it
-- never reached EXCHANGE_DWELL. A plane swaps on a SLOW pass instead: speed at or under EXCHANGE_PLANE_MAX_SPEED
-- (braking ~78; cruise is 110+) and in the volume for EXCHANGE_PLANE_DWELL (two consecutive 0.2 s steps). A fast
-- fly-over never swaps. The car direction keeps EXCHANGE_DWELL.
RespawnRules.EXCHANGE_PLANE_DWELL = 0.15
RespawnRules.EXCHANGE_PLANE_MAX_SPEED = 100
RespawnRules.EXCHANGE_COOLDOWN = 2.5 -- seconds after a swap before the next one
RespawnRules.EXCHANGE_PLANE_LIFT = 18 -- the plane appears this far over its pad (planes crash under Y 16) ...
RespawnRules.EXCHANGE_PLANE_PITCH = 12 -- ... nose up this many degrees, already climbing out of the bay
RespawnRules.EXCHANGE_CAR_LIFT = 3 -- the car appears this far over its pad and drops onto it
RespawnRules.EXCHANGE_PLANE_OVER = 45 -- a plane counts over the car pad up to this far above it ...
RespawnRules.EXCHANGE_PLANE_SLACK = 4 -- ... and this much outside its radius (a flyover is never pixel-exact)

-- ------------------------------------------------------------------ manual respawn
function RespawnRules.cooldownLeft(lastManual: number, now: number): number
	return math.max(0, RespawnRules.MANUAL_COOLDOWN - (now - lastManual))
end

-- lastManual: the last manual press; lastRespawn: the last respawn of any kind (both os.clock, -math.huge = never).
function RespawnRules.canManual(lastManual: number, lastRespawn: number, now: number): boolean
	return now - lastManual >= RespawnRules.MANUAL_COOLDOWN and now - lastRespawn >= RespawnRules.AFTER_RESPAWN_GAP
end

-- Server: a request whose reason is a rescue the player (or his own client's watchdog) asked for.
function RespawnRules.isManualReason(reason: any): boolean
	return reason == "Manual" or reason == "Stuck"
end

-- Client: a respawn of this reason holds the vehicle's height under the fade-out (a rescue poof, a boundary return, a
-- grounded off-track return) instead of letting it fall or sink (a fall, a drown, lava). ISLAND-2 v20 Studio note: an
-- off-track return from the 1-deep shallows sank the car through the sea floor to its roof under the fade.
function RespawnRules.holdsUnderFade(reason: any): boolean
	return reason == "Manual" or reason == "Stuck" or reason == "Server" or reason == "OffTrack"
end

-- ------------------------------------------------------------------ stuck watchdog
export type Watch = { anchor: Vector3?, timer: number, idle: number }

function RespawnRules.newWatch(): Watch
	return { anchor = nil, timer = 0, idle = 0 }
end

function RespawnRules.resetWatch(w: Watch)
	w.anchor = nil
	w.timer = 0
	w.idle = 0
end

-- Whether a car is climbing (OWNER RULE above): grounded on a surface whose normal's Y is below CLIMB_UP_Y.
function RespawnRules.isClimbing(grounded: boolean, upY: number): boolean
	return grounded and upY < RespawnRules.CLIMB_UP_Y
end

function RespawnRules.isTrying(throttle: number, steer: number): boolean
	return math.abs(throttle) >= RespawnRules.TRYING_INPUT or math.abs(steer) >= RespawnRules.TRYING_INPUT
end

-- One frame. active = false (grid hold, respawning, out of a battle) resets the watch: a held vehicle is not stuck.
-- hold = true (a spin-out) freezes it: no time counts, nothing resets. Not trying pauses it for up to
-- STUCK_IDLE_GRACE, then resets it: a parked vehicle is not stuck. Returns "none", "offer" (from STUCK_OFFER) or
-- "auto" (at STUCK_AUTO, once: the watch resets so the next rescue needs another full window).
function RespawnRules.stepWatch(w: Watch, pos: Vector3, trying: boolean, active: boolean, dt: number, hold: boolean?): string
	if not active then
		RespawnRules.resetWatch(w)
		return "none"
	end
	if hold or not trying then
		if not hold then
			w.idle += dt
			if w.idle > RespawnRules.STUCK_IDLE_GRACE then
				RespawnRules.resetWatch(w)
				return "none"
			end
		end
		return if w.anchor ~= nil and w.timer >= RespawnRules.STUCK_OFFER then "offer" else "none"
	end
	w.idle = 0
	local a = w.anchor
	if not a or (pos - a).Magnitude > RespawnRules.STUCK_RADIUS then
		w.anchor = pos
		w.timer = 0
		return "none"
	end
	w.timer += dt
	if w.timer >= RespawnRules.STUCK_AUTO then
		RespawnRules.resetWatch(w)
		return "auto"
	end
	return if w.timer >= RespawnRules.STUCK_OFFER then "offer" else "none"
end

-- ------------------------------------------------------------------ water and tide
-- The tide level over `pos`, or nil off the tide disk (centre/radius nil = everywhere) or with no tide.
function RespawnRules.tideAt(pos: Vector3, level: any, center: any, radius: any): number?
	if type(level) ~= "number" or level ~= level then
		return nil
	end
	if typeof(center) == "Vector3" and type(radius) == "number" then
		local dx, dz = pos.X - center.X, pos.Z - center.Z
		if dx * dx + dz * dz > radius * radius then
			return nil
		end
	end
	return level
end

-- How deep the car's bottom is under water: the deeper of the terrain surface over it and the tide (either nil).
-- <= 0 = dry. Second result: "tide" when the tide is the deeper one, else "terrain" (or "none" when both are nil).
function RespawnRules.waterDepth(bottomY: number, terrainSurfaceY: number?, tideLevel: number?): (number, string)
	local best, source = -math.huge, "none"
	if terrainSurfaceY then
		best, source = terrainSurfaceY - bottomY, "terrain"
	end
	if tideLevel and tideLevel - bottomY > best then
		best, source = tideLevel - bottomY, "tide"
	end
	return best, source
end

-- ------------------------------------------------------------------ hub rescue frame
export type Anchor = { cf: CFrame, name: string? }

-- A frame at `pos` looking along `dir` (unit, not vertical), its up as close to world up as the look allows. Built
-- with fromMatrix (exact on Roblox and under Lune, whose CFrame.lookAt flips the look's Z).
local function facing(pos: Vector3, dir: Vector3): CFrame
	local right = dir:Cross(Vector3.yAxis).Unit
	local upv = right:Cross(dir).Unit
	return CFrame.fromMatrix(pos, right, upv)
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- The frame a hub rescue sets the car down at, and its name ("route" or the anchor's). routePoint/routeTangent: the
-- route frame for `pos` (nil = no route): its projection, or for a stuck rescue the point stuckRouteAdvance moved
-- ahead. Nearest by horizontal distance; the route only within HUB_ROUTE_REACH. clear (a stuck rescue:
-- HUB_STUCK_CLEAR): candidates closer than this are skipped, unless that leaves none.
function RespawnRules.pickHubFrame(pos: Vector3, anchors: { Anchor }, routePoint: Vector3?, routeTangent: Vector3?, clear: number?): (CFrame?, string?)
	local minD = clear or 0
	local bestCF: CFrame? = nil
	local bestName: string? = nil
	local bestD = math.huge
	if routePoint and routeTangent then
		local d = flatDist(pos, routePoint)
		local flatT = Vector3.new(routeTangent.X, 0, routeTangent.Z)
		if d <= RespawnRules.HUB_ROUTE_REACH and d >= minD and flatT.Magnitude > 1e-3 then
			local at = routePoint + Vector3.new(0, RespawnRules.HUB_ROUTE_LIFT, 0)
			bestCF = facing(at, flatT.Unit)
			bestName = "route"
			bestD = d
		end
	end
	for i, a in anchors do
		local d = flatDist(pos, a.cf.Position)
		if d < bestD and d >= minD then
			bestD = d
			bestCF = a.cf
			bestName = a.name or ("anchor" .. i)
		end
	end
	if bestCF == nil and minD > 0 then
		return RespawnRules.pickHubFrame(pos, anchors, routePoint, routeTangent, nil)
	end
	return bestCF, bestName
end

-- Hub: how far ahead along the route (studs) the route frame moves for a rescue of this reason, the car routeDist
-- (horizontal) from its projection. A stuck car that close to the route is stuck ON it: setting it down on its own
-- projection would put it straight back on the kerb.
function RespawnRules.stuckRouteAdvance(reason: any, routeDist: number): number
	if reason == "Stuck" and routeDist < RespawnRules.HUB_STUCK_CLEAR then
		return RespawnRules.HUB_STUCK_ADVANCE
	end
	return 0
end

-- The minimum distance a hub rescue of this reason keeps from the car (pickHubFrame's clear), or nil.
function RespawnRules.hubClear(reason: any): number?
	return if reason == "Stuck" then RespawnRules.HUB_STUCK_CLEAR else nil
end

-- ------------------------------------------------------------------ respawn protection, client side (G2, H0-07)
-- Whether this client drops an item "hit" aimed at its own vehicle. respawning: the vehicle is fading out or waiting
-- for its frame; sinceRespawn: seconds since its last respawn completed (math.huge = never); shieldLeft: seconds left
-- on the server's respawn bubble on it (0 = none). The server is the authority: it never sends a hit inside its own
-- window, so a hit that arrives anyway is either stale (decided before the stamp, still in flight across the respawn)
-- or the server's considered verdict (its window is over, or an asked respawn inside the rearm time got none). The
-- first is dropped; the second is applied, so the car spins when the server says it was hit (before, the client's
-- own 1.0-3.0 s invulnerability hid hits the server scored: the life was lost and the car never spun).
function RespawnRules.clientIgnoresHit(respawning: boolean, sinceRespawn: number, shieldLeft: number): boolean
	return respawning or sinceRespawn < RespawnRules.HIT_STALE_WINDOW or shieldLeft > 0
end

-- ------------------------------------------------------------------ crash-loop guard
export type LoopGuard = { lastPos: Vector3?, lastClock: number }

function RespawnRules.newLoopGuard(): LoopGuard
	return { lastPos = nil, lastClock = -math.huge }
end

-- Records a crash; true when it repeats the previous one (same spot, inside the window).
function RespawnRules.noteCrash(g: LoopGuard, pos: Vector3, now: number): boolean
	local prev = g.lastPos
	local loop = prev ~= nil and now - g.lastClock <= RespawnRules.LOOP_WINDOW and (pos - prev).Magnitude <= RespawnRules.LOOP_RADIUS
	g.lastPos = pos
	g.lastClock = now
	return loop
end

-- ------------------------------------------------------------------ hub vehicle exchange
export type Pad = { cf: CFrame, radius: number, vehicle: string }

-- True when a `vehicle` at `pos` is on `pad` and the pad would swap it (a pad never swaps its own vehicle). A car is
-- on the plane pad within its radius (and 6 over it); a plane is over the car pad within radius + slack horizontally
-- and 0..EXCHANGE_PLANE_OVER above it.
function RespawnRules.exchangeHit(vehicle: string, pos: Vector3, pad: Pad): boolean
	if pad.vehicle == vehicle then
		return false
	end
	local p = pad.cf.Position
	local d = flatDist(pos, p)
	local dy = pos.Y - p.Y
	if vehicle == "car" then
		return d <= pad.radius and dy >= -4 and dy <= 6
	end
	return d <= pad.radius + RespawnRules.EXCHANGE_PLANE_SLACK and dy >= 0 and dy <= RespawnRules.EXCHANGE_PLANE_OVER
end

-- True when `inside` seconds in the pad volume at `speed` (studs/s) is enough for `vehicle` to swap.
function RespawnRules.exchangeReady(vehicle: string, speed: number, inside: number): boolean
	if vehicle == "plane" then
		return speed <= RespawnRules.EXCHANGE_PLANE_MAX_SPEED and inside >= RespawnRules.EXCHANGE_PLANE_DWELL
	end
	return inside >= RespawnRules.EXCHANGE_DWELL
end

-- Where the swapped vehicle appears: over the pad, facing the pad's heading; a plane is lifted and pitched up.
function RespawnRules.exchangeFrame(pad: Pad): CFrame
	local look = Vector3.new(pad.cf.LookVector.X, 0, pad.cf.LookVector.Z)
	local fwd = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
	if pad.vehicle == "plane" then
		local at = pad.cf.Position + Vector3.new(0, RespawnRules.EXCHANGE_PLANE_LIFT, 0)
		local pitch = math.rad(RespawnRules.EXCHANGE_PLANE_PITCH)
		local dir = fwd * math.cos(pitch) + Vector3.new(0, math.sin(pitch), 0)
		return facing(at, dir.Unit)
	end
	local at = pad.cf.Position + Vector3.new(0, RespawnRules.EXCHANGE_CAR_LIFT, 0)
	return facing(at, fwd)
end

return RespawnRules
