--!strict
-- Creature vehicle rules (owner 2026-10-21: a rideable, animated Void Dragon as a plane-class avatar). Pure: no
-- Instances, no services, no clock. Used by server/kit/CreatureMesh (the fit and the camera bound), client/
-- VehicleCreatureAnimator (flight state -> clip weights, LOD) and tools/tests/vehicle_creature_spec.luau.
--
-- Stat-neutral: nothing here reads or writes the hull, the controller or PlaneConfig tuning. The creature is a skin on
-- the same invisible hull every plane flies (AvatarConfig header); its clips only move bones.
--
-- Flight state (base layer, one clip at a time, crossfaded):
--   hover  on the start grid / countdown, and when nearly stopped
--   boost  while BoostState is not "None"
--   fly    flapping: throttling, climbing, accelerating, slow, or just hit
--   glide  wings spread: cruising level, or diving with low throttle
-- A change away from the current state waits HOLD seconds (no flicker between fly and glide on a gentle bump); hover
-- and boost switch at once. Bank layer: bankL / bankR overlaid with a weight from the turn rate (dead zone, ramp,
-- capped at BANK_MAX so the flap still reads through a hard turn). Hit: a one-shot on an item hit.
local VehicleCreatureRules = {}

VehicleCreatureRules.KIND = "creature"
VehicleCreatureRules.CLIP_FOLDER = "vehicleclips" -- ReplicatedStorage.Shared.<CLIP_FOLDER>.<Mesh.clips>
VehicleCreatureRules.ATTR_CLIPS = "CreatureClips" -- model attribute: the clip module name (set by the builder)
VehicleCreatureRules.ATTR_SCALE = "CreatureScale" -- model attribute: the Model:ScaleTo factor (clip translations are glTF units)
VehicleCreatureRules.BASE = { "hover", "fly", "glide", "boost" }

-- State thresholds (studs/s, studs/s per s, 0..1 throttle)
VehicleCreatureRules.HOVER_BELOW = 8 -- nearly stopped: hover
VehicleCreatureRules.SLOW_FLAP = 60 -- below this the creature keeps flapping
VehicleCreatureRules.CLIMB_FLAP = 6 -- vertical speed above this: flapping (climbing)
VehicleCreatureRules.DIVE_GLIDE = -10 -- vertical speed below this with low throttle: glide (dive)
VehicleCreatureRules.ACCEL_FLAP = 5 -- smoothed acceleration above this: flapping
VehicleCreatureRules.THROTTLE_FLAP = 0.35 -- throttle input above this: flapping
VehicleCreatureRules.HOLD = 0.6 -- s before a fly <-> glide change takes
VehicleCreatureRules.HIT_FLAP = 1.2 -- s of flapping after a hit
VehicleCreatureRules.BASE_FADE = 0.35 -- s crossfade between base clips

-- Bank layer
VehicleCreatureRules.TURN_DEAD = 8 -- deg/s of yaw rate that bank nothing
VehicleCreatureRules.TURN_FULL = 70 -- deg/s for the full bank weight
VehicleCreatureRules.BANK_MAX = 0.75
VehicleCreatureRules.BANK_RATE = 4 -- 1/s: the bank weight eases toward its target at this rate

-- Hit one-shot
VehicleCreatureRules.HIT_IN = 0.1
VehicleCreatureRules.HIT_OUT = 0.25

-- LOD (phone budget). Distances from the camera, studs. The local player's own mount always runs at full rate.
VehicleCreatureRules.FULL_RATE_DISTANCE = 220
VehicleCreatureRules.MID_DISTANCE = 450 -- MID_STEP beyond FULL_RATE_DISTANCE up to here
VehicleCreatureRules.CULL_DISTANCE = 700 -- nothing beyond (inside PlayerStreamRules.RELAY_RANGE 1200; VehicleMotion's prop cull)
VehicleCreatureRules.MID_STEP = 1 / 20
VehicleCreatureRules.FAR_STEP = 1 / 8
VehicleCreatureRules.MAX_FULL_RATE = 4 -- full-rate rigs per frame besides the local one; the rest drop to MID_STEP
VehicleCreatureRules.VIEW_DOT = -0.2 -- direction-to-rig . camera look below this = behind the camera (out of view)

-- Chase-camera bound (PlaneConfig.CAM_DISTANCE 15.2 behind, CAM_HEIGHT 4.5 above the hull). The animated creature must
-- never reach the camera or rise across its eye line: tail tip no further back than REAR_MAX, wing tips at the top of
-- a flap no higher than UP_MAX (hull-local studs). fitLength shrinks the creature to fit; it never grows it.
VehicleCreatureRules.CAM_DISTANCE = 15.2
VehicleCreatureRules.CAM_HEIGHT = 4.5
VehicleCreatureRules.NEAR_CLEAR = 6 -- RacerViewRules.NEAR_CLEAR: the camera's clear radius
VehicleCreatureRules.REAR_MAX = VehicleCreatureRules.CAM_DISTANCE - VehicleCreatureRules.NEAR_CLEAR -- 9.2
VehicleCreatureRules.UP_MAX = VehicleCreatureRules.CAM_HEIGHT -- 4.5
-- Owner 2026-10-21 (V15 captures): the dragon read plane-sized. A creature avatar may now be big if the chase camera
-- moves out for it (creature avatars only; planes and cars keep PlaneConfig.CAM_*): the camera sits at camera(...) below,
-- never beyond MAX_CAM_DISTANCE / MAX_CAM_HEIGHT, and fitLength shrinks to those, so the same bound still holds: no part
-- of the animated creature (tail tip at REAR, wing tips at the top of a flap) is inside the camera's NEAR_CLEAR radius
-- plus CAM_MARGIN, and none rises above the eye line less UP_MARGIN.
VehicleCreatureRules.MAX_CAM_DISTANCE = 24
VehicleCreatureRules.MAX_CAM_HEIGHT = 9
VehicleCreatureRules.CAM_MARGIN = 1.5
VehicleCreatureRules.UP_MARGIN = 0.6
VehicleCreatureRules.REAR_FIT = VehicleCreatureRules.MAX_CAM_DISTANCE - VehicleCreatureRules.NEAR_CLEAR - VehicleCreatureRules.CAM_MARGIN -- 16.5
VehicleCreatureRules.UP_FIT = VehicleCreatureRules.MAX_CAM_HEIGHT - VehicleCreatureRules.UP_MARGIN -- 8.4
VehicleCreatureRules.WING_HALF = 0.5 -- wing tip lateral reach as a fraction of the length (wingspan ~ the length)
VehicleCreatureRules.ATTR_CAM_DISTANCE = "CreatureCamDistance" -- model attributes read by client/FlightController
VehicleCreatureRules.ATTR_CAM_HEIGHT = "CreatureCamHeight"
VehicleCreatureRules.ATTR_WING_HALF = "CreatureWingHalf" -- hull-local wing tip |x|, studs (client/Vfx particles)
VehicleCreatureRules.ATTR_TAIL_BACK = "CreatureTailBack" -- hull-local tail tip z (+ = behind), studs
VehicleCreatureRules.MIN_LENGTH = 8
VehicleCreatureRules.DEFAULT_REACH = { 0.55, 0.3 }

export type Input = {
	grid: boolean, -- the race countdown is running (RaceGoTime in the future) or the vehicle is held
	speed: number, -- studs/s
	climb: number, -- vertical speed, studs/s (+ up)
	accel: number, -- smoothed d(speed)/dt
	throttle: number?, -- 0..1 when known (the local player's input); nil for remote players and bots
	boosting: boolean,
	hitAge: number, -- seconds since the last item hit (math.huge = never)
}

export type State = { base: string, pending: string?, pendingFor: number, bank: number }

function VehicleCreatureRules.newState(): State
	return { base = "hover", pending = nil, pendingFor = 0, bank = 0 }
end

-- The base state this input asks for (no hysteresis).
function VehicleCreatureRules.wanted(i: Input): string
	local R = VehicleCreatureRules
	if i.grid or i.speed < R.HOVER_BELOW then
		return "hover"
	end
	if i.boosting then
		return "boost"
	end
	local throttle = i.throttle
	local throttling = (throttle ~= nil and throttle > R.THROTTLE_FLAP) or i.accel > R.ACCEL_FLAP
	if i.hitAge < R.HIT_FLAP or i.speed < R.SLOW_FLAP or i.climb > R.CLIMB_FLAP then
		return "fly"
	end
	if i.climb < R.DIVE_GLIDE then
		-- A dive speeds a vehicle up by itself: with no throttle reading (remote, bot) that is not flapping.
		return if throttle ~= nil and throttle > R.THROTTLE_FLAP then "fly" else "glide"
	end
	return if throttling then "fly" else "glide"
end

-- Steps the base state with hysteresis: hover and boost (and leaving them) take at once, fly <-> glide after HOLD.
function VehicleCreatureRules.stepBase(st: State, i: Input, dt: number): string
	local want = VehicleCreatureRules.wanted(i)
	if want == st.base then
		st.pending, st.pendingFor = nil, 0
		return st.base
	end
	local instant = want == "hover" or want == "boost" or st.base == "hover" or st.base == "boost"
	if instant then
		st.base, st.pending, st.pendingFor = want, nil, 0
		return st.base
	end
	if st.pending ~= want then
		st.pending, st.pendingFor = want, 0
	end
	st.pendingFor += dt
	if st.pendingFor >= VehicleCreatureRules.HOLD then
		st.base, st.pending, st.pendingFor = want, nil, 0
	end
	return st.base
end

-- Signed bank target from the yaw rate (deg/s, + = turning right): -BANK_MAX..BANK_MAX.
function VehicleCreatureRules.bankTarget(turnRateDeg: number): number
	local R = VehicleCreatureRules
	local a = math.abs(turnRateDeg)
	if a ~= a or a <= R.TURN_DEAD then
		return 0
	end
	local k = math.clamp((a - R.TURN_DEAD) / (R.TURN_FULL - R.TURN_DEAD), 0, 1)
	return (if turnRateDeg > 0 then 1 else -1) * k * R.BANK_MAX
end

-- Eases the signed bank weight toward the turn's target (frame-rate independent).
function VehicleCreatureRules.stepBank(st: State, turnRateDeg: number, dt: number): number
	local target = VehicleCreatureRules.bankTarget(turnRateDeg)
	st.bank += (target - st.bank) * (1 - math.exp(-VehicleCreatureRules.BANK_RATE * dt))
	return st.bank
end

-- The clip that plays for a wanted name, given the clips a module has (missing clips fall back, never error).
local FALLBACK: { [string]: { string } } = {
	hover = { "hover", "glide", "fly" },
	fly = { "fly", "glide", "hover" },
	glide = { "glide", "fly", "hover" },
	boost = { "boost", "fly", "glide" },
}
function VehicleCreatureRules.resolve(name: string, has: { [string]: any }): string?
	local order: { string } = FALLBACK[name] or { name }
	for _, n in order do
		if has[n] ~= nil then
			return n
		end
	end
	return nil
end

-- Overlay weights {bankL, bankR} for the signed bank weight (only clips the module has).
function VehicleCreatureRules.bankWeights(bank: number, has: { [string]: any }): (number, number)
	local l = if bank < 0 and has.bankL ~= nil then -bank else 0
	local r = if bank > 0 and has.bankR ~= nil then bank else 0
	return l, r
end

-- Update interval for a rig (0 = every frame, nil = skip this frame). fullUsed = full-rate rigs already updated this
-- frame (the phone budget). Bots out of view get nothing; players out of view nothing either (their mount is not on
-- screen), except the local player's own mount.
function VehicleCreatureRules.lodStep(dist: number, isLocal: boolean, isBot: boolean, inView: boolean, fullUsed: number): number?
	local R = VehicleCreatureRules
	if isLocal then
		return 0
	end
	if not inView or dist > R.CULL_DISTANCE then
		return nil
	end
	if dist <= R.FULL_RATE_DISTANCE then
		return if fullUsed < R.MAX_FULL_RATE then 0 else R.MID_STEP
	end
	if dist <= R.MID_DISTANCE then
		return R.MID_STEP
	end
	return if isBot then R.FAR_STEP * 1.5 else R.FAR_STEP
end

-- Whether a point is in front of the camera (cheap view test: the direction to it against the camera's look).
function VehicleCreatureRules.inView(toRig: Vector3, look: Vector3): boolean
	local d = toRig.Magnitude
	if d < 1 then
		return true
	end
	return toRig:Dot(look) / d >= VehicleCreatureRules.VIEW_DOT
end

-- The fitted length (studs, longest side) under the chase-camera bound. reach = {back, up} as fractions of length,
-- offset = the weld offset {x, y, z} (hull-local; +z = behind). Shrinks only; never below MIN_LENGTH.
function VehicleCreatureRules.fitLength(length: number, reach: { number }?, offset: { number }?): number
	local R = VehicleCreatureRules
	local r = reach or R.DEFAULT_REACH
	local back, up = r[1] or R.DEFAULT_REACH[1], r[2] or R.DEFAULT_REACH[2]
	local oy = if offset then offset[2] or 0 else 0
	local oz = if offset then offset[3] or 0 else 0
	local L = length
	if back > 0 then
		L = math.min(L, (R.REAR_FIT - oz) / back)
	end
	if up > 0 then
		L = math.min(L, (R.UP_FIT - oy) / up)
	end
	return math.max(R.MIN_LENGTH, L)
end

-- The furthest the fitted creature reaches behind and above the hull centre (studs), for the spec and the log line.
function VehicleCreatureRules.extent(length: number, reach: { number }?, offset: { number }?): (number, number)
	local R = VehicleCreatureRules
	local r = reach or R.DEFAULT_REACH
	local oy = if offset then offset[2] or 0 else 0
	local oz = if offset then offset[3] or 0 else 0
	return oz + length * (r[1] or R.DEFAULT_REACH[1]), oy + length * (r[2] or R.DEFAULT_REACH[2])
end

-- The chase camera for a creature of this fitted length: (distance behind, height above) the hull. Never nearer or lower
-- than the plane camera, never beyond the MAX_* the fit was computed against.
function VehicleCreatureRules.camera(length: number, reach: { number }?, offset: { number }?): (number, number)
	local R = VehicleCreatureRules
	local back, up = R.extent(length, reach, offset)
	local dist = math.clamp(back + R.NEAR_CLEAR + R.CAM_MARGIN, R.CAM_DISTANCE, R.MAX_CAM_DISTANCE)
	local height = math.clamp(up + R.UP_MARGIN, R.CAM_HEIGHT, R.MAX_CAM_HEIGHT)
	return dist, height
end

-- Wing tip lateral reach and tail tip z (hull-local studs) of a fitted creature, for the boost particles.
function VehicleCreatureRules.tips(length: number, reach: { number }?, offset: { number }?): (number, number)
	local back = VehicleCreatureRules.extent(length, reach, offset)
	return length * VehicleCreatureRules.WING_HALF, back
end

-- A mesh registry entry that asks for the creature path.
function VehicleCreatureRules.isCreature(mesh: any): boolean
	return type(mesh) == "table" and mesh.kind == VehicleCreatureRules.KIND and type(mesh.modelId) == "number" and mesh.modelId > 0
end

return VehicleCreatureRules
