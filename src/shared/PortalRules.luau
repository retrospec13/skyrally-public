--!strict
-- Portal Plunge rules (REMARKABLE Batch 2 item 20; trap audit H0-09). Pure: no Instances, no clock, specced in
-- tools/tests/portal_spec.luau. Shared by the server (TrackDirector: what counts as driving through an arch, when a warp
-- holds) and the client (client/PortalPlunge: when a locked arch spits the car back out, the FOV stretch and iris curves).
--
-- An arch's frame is the hub plan's portal cf (build/hub0 TrackData hub.portals, and the PortalShimmer_<ZONE> fx part):
-- centre 11 studs above the plaza, LookVector pointing OUT of the plaza, so driving through goes from side < 0 (the plaza)
-- to side >= 0. A graze past the front or the back of an arch is not a crossing (H0-09: the old 15-stud sphere around
-- the centre switched the whole server when someone circled the lamp ring).
local PortalRules = {}

PortalRules.HALF_WIDTH = 12 -- the veil is 24 wide (portal size X)
PortalRules.LATERAL_SLACK = 1.5 -- the hull centre may sit this far into the pillar line (a car body is ~6 wide)
PortalRules.BELOW = 16 -- the cf is 11 above the plaza; a car hull rides ~2-3 above it
PortalRules.ABOVE = 20 -- the round top of the opening is ~21 above the cf: planes fly through, never over
PortalRules.MAX_STEP = 80 -- a jump longer than this between two samples is a respawn or a swap, never a drive
-- ...unless the samples are far apart in time: no vehicle outruns this (overcharge/item boost tops out at 210), so a
-- server hitch between two samples never turns a boosted pass into a "teleport" (portal-load).
PortalRules.MAX_RATE = 320
PortalRules.WARP_SECONDS = 1.5 -- the cancelable countdown between crossing and the server switching (H0-09)
PortalRules.CANCEL_BACK = 3 -- reversing this far back onto the plaza side cancels the warp (and re-arms the arch)
-- portal-load (owner 2026-10-21: "two times it failed to load me in and then I had to slowly drive in"): the warp used
-- to cancel too once the hull was 45 studs off the arch's axis. A car through at 150 studs/s leaves that corridor in
-- the 1.5 s countdown at any angle over ~12 degrees (or when it steers after the veil), so fast passes were cancelled
-- as "backed out" and only a crawl loaded. Only the plaza side cancels now; distance travelled never does.
PortalRules.SPIT_ZONE = 7 -- a locked arch spits a car whose hull is within this many studs in front of the veil
PortalRules.SPIT_MIN_APPROACH = 2 -- studs/s toward the veil; a car parked in front of an arch is never spat
PortalRules.SPIT_COOLDOWN = 1.2
PortalRules.SPIT_SPEED_FRACTION = 0.6
PortalRules.SPIT_SPEED_MIN = 16
PortalRules.FOV_STRETCH = 45 -- degrees added at the end of the warp
PortalRules.FOV_MAX = 118
PortalRules.IRIS_HOLD = 0.16 -- hole size (fraction of the start) the iris pauses on, framing the car
PortalRules.IRIS_HOLD_FROM = 0.5 -- of the close
PortalRules.IRIS_HOLD_TO = 0.78

local function frameOf(pos: Vector3, cf: CFrame): (number, number, number)
	local rel = pos - cf.Position
	return rel:Dot(cf.LookVector), rel:Dot(cf.RightVector), rel:Dot(cf.UpVector)
end

-- Signed distance through the arch: negative on the plaza side, positive beyond the veil.
function PortalRules.side(pos: Vector3, cf: CFrame): number
	return (pos - cf.Position):Dot(cf.LookVector)
end

local function inOpening(lateral: number, up: number, slack: number?): boolean
	return math.abs(lateral) <= PortalRules.HALF_WIDTH + (slack or PortalRules.LATERAL_SLACK)
		and up >= -PortalRules.BELOW
		and up <= PortalRules.ABOVE
end

-- The longest move between two samples dt seconds apart that is still a drive (not a respawn or a swap).
function PortalRules.maxStep(dt: number?): number
	return math.max(PortalRules.MAX_STEP, PortalRules.MAX_RATE * math.max(0, dt or 0))
end

-- True when the move prev -> pos passes through the arch's opening from the plaza side. The point where the path meets
-- the veil plane is interpolated (a swept segment test), so a sample at any speed is judged where it really crossed.
-- maxStep defaults to MAX_STEP (pass PortalRules.maxStep(dt) when the sample interval is known).
function PortalRules.crossed(prev: Vector3, pos: Vector3, cf: CFrame, maxStep: number?): boolean
	local s0 = PortalRules.side(prev, cf)
	local s1 = PortalRules.side(pos, cf)
	if not (s0 < 0 and s1 >= 0) then
		return false
	end
	if (pos - prev).Magnitude > (maxStep or PortalRules.MAX_STEP) then
		return false
	end
	local t = s0 / (s0 - s1)
	local hit = prev + (pos - prev) * t
	local _, lateral, up = frameOf(hit, cf)
	return inOpening(lateral, up)
end

-- While a warp counts down, it holds unless the car backed out onto the plaza side of the arch. How far or which way it
-- drives on beyond the veil never matters (portal-load: a fast pass carries the car far past the arch in 1.5 s).
function PortalRules.warpHolds(pos: Vector3, cf: CFrame): boolean
	return PortalRules.side(pos, cf) >= -PortalRules.CANCEL_BACK
end

-- portal-load: one vehicle's crossing watch, stepped by the server every Heartbeat in the hub. Swept: each step tests
-- the segment from the previous sample to this one against every arch, so no speed or frame rate skips the veil. Exactly
-- once: an arch that fired stays spent for this vehicle until it is back on the plaza side (side < -CANCEL_BACK), so a
-- car nosing back and forth on the veil, or sitting in it, never triggers twice in one pass.
export type Watch = { prev: Vector3?, at: number?, spent: { [number]: boolean } }

function PortalRules.newWatch(): Watch
	return { prev = nil, at = nil, spent = {} }
end

-- A set-down, respawn or vehicle swap: the next sample starts a new path (spent arches stay spent until backed out).
function PortalRules.resetWatch(w: Watch)
	w.prev = nil
	w.at = nil
end

-- Feeds one sample (pos at clock now) and returns the index into cfs of the arch driven through, or nil.
function PortalRules.watchStep(w: Watch, pos: Vector3, now: number, cfs: { CFrame }): number?
	local prev, at = w.prev, w.at
	w.prev = pos
	w.at = now
	for i, cf in cfs do
		if w.spent[i] and PortalRules.side(pos, cf) < -PortalRules.CANCEL_BACK then
			w.spent[i] = nil
		end
	end
	if not prev then
		return nil
	end
	local limit = PortalRules.maxStep(if at then now - at else nil)
	for i, cf in cfs do
		if not w.spent[i] and PortalRules.crossed(prev, pos, cf, limit) then
			w.spent[i] = true
			return i
		end
	end
	return nil
end

-- Client, locked arch: the hull is just in front of the veil, inside the opening, and moving toward it.
function PortalRules.inSpitZone(pos: Vector3, vel: Vector3, cf: CFrame): boolean
	local side, lateral, up = frameOf(pos, cf)
	if side < -PortalRules.SPIT_ZONE or side > 1.5 then
		return false
	end
	if vel:Dot(cf.LookVector) < PortalRules.SPIT_MIN_APPROACH then
		return false
	end
	return inOpening(lateral, up, 3)
end

-- The (negative) speed a spat-out car leaves with: a fraction of what it came in with, never faster than the car's own
-- reverse top speed, so the spit is no speed source (REMARKABLE fair-racing rule; the hub has no race either way).
function PortalRules.spitSpeed(speed: number, reverseCap: number): number
	local cap = math.max(0, reverseCap)
	local want = math.max(math.abs(speed) * PortalRules.SPIT_SPEED_FRACTION, math.min(PortalRules.SPIT_SPEED_MIN, cap))
	return -math.min(want, cap)
end

-- FOV over the warp (t = seconds since the warp began): an ease-in stretch to base + FOV_STRETCH, capped.
function PortalRules.fovAt(t: number, base: number): number
	local k = math.clamp(t / PortalRules.WARP_SECONDS, 0, 1)
	return math.min(PortalRules.FOV_MAX, base + PortalRules.FOV_STRETCH * k * k * k)
end

-- Iris hole size over the close, as a fraction of the opening size (k = 0..1 of the close): ease in to IRIS_HOLD, pause
-- there framing the car (a little pulse so it reads as alive), then snap shut.
function PortalRules.irisClose(k: number): number
	local h = PortalRules.IRIS_HOLD
	if k <= 0 then
		return 1
	elseif k < PortalRules.IRIS_HOLD_FROM then
		local u = k / PortalRules.IRIS_HOLD_FROM
		return 1 - (1 - h) * (1 - (1 - u) * (1 - u))
	elseif k < PortalRules.IRIS_HOLD_TO then
		local u = (k - PortalRules.IRIS_HOLD_FROM) / (PortalRules.IRIS_HOLD_TO - PortalRules.IRIS_HOLD_FROM)
		return h * (1 + 0.12 * math.sin(u * math.pi))
	elseif k < 1 then
		local u = (k - PortalRules.IRIS_HOLD_TO) / (1 - PortalRules.IRIS_HOLD_TO)
		return h * (1 - u * u)
	end
	return 0
end

-- Iris opening on arrival (k = 0..1): overshoots a touch so the reveal "pops".
function PortalRules.irisOpen(k: number): number
	if k <= 0 then
		return 0
	elseif k >= 1 then
		return 1
	end
	local c = 1.70158
	local u = k - 1
	return 1 + (c + 1) * u * u * u + c * u * u
end

-- The speech bubble a locked arch says (the server's reason, shouted). Short enough for a 740 px phone.
function PortalRules.bubbleText(why: any): string
	local s = string.upper(tostring(why or "LOCKED"))
	if string.find(s, "TOKEN", 1, true) then
		return "NOT YET! " .. s
	end
	return "LOCKED! " .. s
end

return PortalRules
