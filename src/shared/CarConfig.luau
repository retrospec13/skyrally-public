--!strict
-- Launch car tuning (PLAN L2, TEST_LIST_LAUNCH L05; ISLAND-2 and SPACE-4 are car tracks) plus the small pure helpers
-- that interpret it. The client CarController and the server CarServer read the SAME numbers, so the validator's
-- speed bound can never drift from what the controller can legally reach.
-- Everything here is plain numbers, strings and number arrays (no Vector3/Color3/CFrame) so the Lune spec
-- (tools/tests/car_spec.luau) loads it without Roblox types. Units: studs, seconds, degrees.
-- Pace reference (PlaneConfig): plane cruise 110, full throttle 128, ring/pad boost 165, overcharge 210.

local CarConfig = {}

-- ---------------------------------------------------------------- speeds (studs/s)
CarConfig.TOP_SPEED = 128 -- full throttle on flat road, equal to the plane's full-throttle pace
-- REVERSE_SPEED is the v27 reverse top speed, kept ONLY as the locked-arch spit cap (PortalRules.spitSpeed) so that push is
-- unchanged. Driving backwards uses REVERSE_DRIVE_SPEED through shared/ReverseRules (reverse v2, owner 2026-10-21).
CarConfig.REVERSE_SPEED = 34
CarConfig.REVERSE_DRIVE_SPEED = 50
CarConfig.ACCEL_RESPONSE = 1.15 -- exponential approach to the throttle target (1/s): 0 -> 85 in ~1 s, 114 in ~2 s
CarConfig.ACCEL_MIN = 20 -- studs/s^2 floor so the last few studs/s of the approach still arrive
CarConfig.BRAKE_DECEL = 150 -- full brake from top speed to 0 in ~0.85 s
CarConfig.REVERSE_ACCEL = 45 -- v27 (unused since reverse v2: ReverseRules.REVERSE_RESPONSE / REVERSE_ACCEL_MIN)
CarConfig.COAST_DECEL = 26 -- no throttle, no brake
CarConfig.OVERSPEED_DECAY = 1.6 -- (1/s) after a boost ends, speed above the target eases back (never a hard cut)
CarConfig.SLOPE_GRAVITY = 70 -- along-road gravity component: uphill slows, downhill speeds up (arcade-damped)
-- Touch has no gas button (RaceUI's ITEM button fires items, L07), so in Touch mode the car always drives itself
-- forward at this throttle unless the pad is pulled down to brake (Mario Kart Tour style).
CarConfig.AUTO_THROTTLE = 0.92
CarConfig.SPEED_PICKUP_BONUS = 1.4 -- per "Speed" pod, same stacking rule as the plane (PlaneConfig)
CarConfig.MAX_SPEED_PICKUPS = 10

-- Surfaces (Terrain material names). Off-road slows the car unless a boost is running (MK/DKR rule).
CarConfig.OFFROAD_SPEED_FACTOR = 0.62
CarConfig.OFFROAD_MATERIALS = { "Grass", "LeafyGrass", "Sand", "Mud", "Ground", "Snow", "Pebble" } :: { string }
CarConfig.WATER_SPEED_FACTOR = 0.72 -- shallow water (ISLAND-2 water battle drives through it)

-- ---------------------------------------------------------------- boosts
CarConfig.PAD_BOOST_SPEED = 165 -- ground boost pad: the plane's ring/pad boost speed
CarConfig.PAD_BOOST_DURATION = 1.6
CarConfig.BOOST_RESPONSE = 7 -- (1/s) how fast speed rises to a boost target
CarConfig.ITEM_BOOST_MAX_SPEED = 210 -- ItemRules level-3 blue boost; the validator must allow it
CarConfig.MAGNET_MAX_BONUS = 40 -- cap on the rainbow-magnet pull added to speed
-- Magnet v2: a car's magnet speed (top + pull) never passes the level-3 item boost, so the validator's allowance
-- (maxHorizontalSpeed: item boost + MAGNET_MAX_BONUS) is unchanged.
CarConfig.MAGNET_MAX_SPEED = CarConfig.ITEM_BOOST_MAX_SPEED
-- Off: Blue is an item now (ItemRules.classifyPod "item"; ItemService grants it server-side and its boost fires when the
-- item is used), and FlightController dropped its Blue pickup boost. On, a Blue pod would boost at once AND hand over
-- a Blue item. "Air" pods still boost on pickup, as on the plane.
CarConfig.BLUE_POD_INSTANT_BOOST = false
-- Trigger radii from the hull centre (the car sits ~4.6 above the ribbon; pads lie 1.6 above it, pods float).
CarConfig.PAD_TRIGGER_RADIUS = 14
CarConfig.RING_TRIGGER_RADIUS = 16
CarConfig.PICKUP_TRIGGER_RADIUS = 10
CarConfig.TRIGGER_COOLDOWN = 1.2

-- ---------------------------------------------------------------- steering
CarConfig.TURN_RATE_MAX = 112 -- deg/s at FULL_TURN_SPEED
CarConfig.FULL_TURN_SPEED = 42 -- below this the rate ramps down to 0 (no turning on the spot)
CarConfig.TURN_LOW_SPEED_EXP = 0.75 -- <1 gives usable steering soon after pulling away
CarConfig.HIGH_SPEED_TURN_FACTOR = 0.68 -- fraction of TURN_RATE_MAX left at TOP_SPEED (radius ~94 studs flat out)
CarConfig.STEER_RESPONSE = 10 -- (1/s) input smoothing so digital keys ramp instead of snapping
CarConfig.REVERSE_STEER_FACTOR = 0.7 -- v27 (unused since reverse v2: ReverseRules.turnRate / TURN_FACTOR 0.9)
CarConfig.WHEEL_STEER_VISUAL_DEG = 26

-- ---------------------------------------------------------------- drift (MK-style mini-turbo)
CarConfig.DRIFT_MIN_SPEED = 45 -- below this a held drift button does not start a drift
CarConfig.DRIFT_CANCEL_SPEED = 30 -- a running drift ends (no boost) when speed falls under this
CarConfig.DRIFT_STEER_START = 0.3 -- |steer| needed to pick the drift direction
CarConfig.DRIFT_TURN_MIN = 0.45 -- turn-rate multiplier steering out of the drift (wide line)
CarConfig.DRIFT_TURN_MAX = 1.35 -- ... steering into the drift (tight line: radius ~70 studs flat out)
CarConfig.DRIFT_SLIDE_DEG = 24 -- body yaw toward the inside of the turn while sliding
CarConfig.DRIFT_SLIDE_RESPONSE = 9
CarConfig.DRIFT_SPEED_FACTOR = 0.97
CarConfig.DRIFT_CHARGE_BASE = 1.0 -- charge per second while sliding on the ground
CarConfig.DRIFT_CHARGE_TIGHT = 0.7 -- extra charge per second at full steer into the drift
CarConfig.DRIFT_HOP_HEIGHT = 0.9 -- visual hop on drift start (body only, local client)
CarConfig.DRIFT_HOP_TIME = 0.18

export type DriftLevel = {
	name: string,
	threshold: number, -- charge needed
	color: { number }, -- spark colour {r, g, b} 0-255
	boostSpeed: number,
	boostDuration: number,
	boostState: string, -- Vfx/SoundJuice boost family: "Standard" (cyan) or "Overcharge"
}

-- Level 1 blue, level 2 orange (mini-turbo / super mini-turbo), level 3 the ZONE TURBO (REMARKABLE item 15): its
-- sparks take the zone's own colour (DRIFT_ZONE_COLORS; `color` below is only the fallback) instead of a fixed purple.
-- Fairness: tier 3 reuses the pad boost exactly (PAD_BOOST_SPEED 165 for PAD_BOOST_DURATION 1.6), so it adds no new
-- speed and maxHorizontalSpeed() is unchanged. 1.6 s is under the 1.8 s ring boost every bot takes from each ring in
-- the field simulation (PlaneConfig.BOOST_DURATION, tools/tests/field_spec.luau), and it takes a long committed drift
-- to reach: ~1.8 s held tight into the turn, 3.1 s neutral (orange is ~1.1 s tight).
CarConfig.DRIFT_LEVELS = {
	{ name = "Blue", threshold = 0.85, color = { 70, 170, 255 }, boostSpeed = 150, boostDuration = 0.75, boostState = "Standard" },
	{ name = "Orange", threshold = 1.9, color = { 255, 140, 40 }, boostSpeed = 165, boostDuration = 1.25, boostState = "Overcharge" },
	{ name = "Zone", threshold = 3.1, color = { 186, 92, 255 }, boostSpeed = 165, boostDuration = 1.6, boostState = "Overcharge" },
} :: { DriftLevel }
CarConfig.DRIFT_SMOKE_COLOR = { 235, 228, 214 } :: { number } -- sliding but not charged yet
-- Zone turbo spark colours (workspace ActiveZone): magma gold, ice white, seafoam, meadow lime, neon violet, coral.
-- The same palette as StyleRules.ZONE_COLOR (the style chain meter); tools/tests/style_spec.luau keeps them equal.
CarConfig.DRIFT_ZONE_COLORS = {
	DINO = { 255, 184, 40 },
	SNOW = { 222, 244, 255 },
	ISLAND = { 80, 238, 196 },
	FOREST = { 166, 240, 84 },
	SPACE = { 186, 92, 255 },
	HUB = { 255, 128, 186 },
} :: { [string]: { number } }

-- ---------------------------------------------------------------- air
CarConfig.GRAVITY = 140 -- floatier than workspace gravity (196.2) so ramp jumps read as DKR hops
CarConfig.MAX_FALL_SPEED = 220
CarConfig.MAX_RISE_SPEED = 120 -- ramp launches and items never push the car up faster than this
CarConfig.AIR_STEER_FACTOR = 0.35
CarConfig.AIR_VELOCITY_TURN = 0.6 -- fraction of an air yaw change applied to the travel direction
CarConfig.AIR_LEVEL_RESPONSE = 2.5 -- (1/s) up vector returns to world up while airborne
CarConfig.AIR_NOSE_PITCH = 0.35 -- airborne nose follows the vertical velocity this much (visual)

-- ---------------------------------------------------------------- ground contact (4 wheel probes)
CarConfig.WHEEL_RADIUS = 1.35
CarConfig.WHEEL_WIDTH = 1.1
-- Hull-local wheel centres {x, y, z} in FL, FR, RL, RR order; -Z is forward (Roblox LookVector).
CarConfig.WHEELS = {
	{ -2.75, -0.55, -3.3 },
	{ 2.75, -0.55, -3.3 },
	{ -2.85, -0.55, 3.2 },
	{ 2.85, -0.55, 3.2 },
} :: { { number } }
CarConfig.WHEEL_NAMES = { "Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR" } :: { string }
CarConfig.RIDE_HEIGHT = 1.9 -- hull centre above the road = WHEEL_RADIUS - wheel y (1.35 + 0.55)
CarConfig.PROBE_UP = 2.5 -- probes start this far above each wheel centre (catch steps and seams)
CarConfig.PROBE_DOWN = 4.0 -- cast length below the wheel's resting contact point
CarConfig.SNAP_GROUNDED = 1.2 -- grounded: a wheel within RADIUS + this still touches (sticks over crests)
CarConfig.SNAP_LANDING = 0.3 -- airborne: must really reach the road before it counts as landed
CarConfig.MIN_CONTACTS = 2 -- fewer touching wheels = airborne (ramp lip, gap, cliff)
CarConfig.LAND_MAX_UP_SPEED = 2 -- still rising faster than this along the up axis: not landed yet
CarConfig.GROUND_ALIGN_RESPONSE = 14 -- (1/s) up vector follows the road normal (slopes, banks)
CarConfig.SUSPENSION_TRAVEL = 0.6 -- visual wheel travel each way
CarConfig.LAND_SQUASH_MIN_SPEED = 20 -- vertical impact speed that starts a visible landing squash
CarConfig.LAND_SQUASH_FULL_SPEED = 110
CarConfig.LAND_SQUASH_DEPTH = 0.7 -- body drop at full squash (visual)
CarConfig.LAND_SPEED_KEEP = 0.97

-- ---------------------------------------------------------------- body and walls
CarConfig.HALF_WIDTH = 3.15
CarConfig.HALF_LENGTH = 5.25
CarConfig.HULL_SIZE = { 6.3, 2.4, 10.5 } :: { number }
CarConfig.WALL_MAX_UP_DOT = 0.5 -- a hit normal flatter than this against the car's up is a wall, not a slope
CarConfig.WALL_RAY_LIFT = 0.3 -- wall rays run this far above the hull centre (2.2 above the road: over curb lips)
CarConfig.WALL_CLEARANCE = 0.2
CarConfig.WALL_SHALLOW_DOT = 0.42 -- impact |dir . n| below this (~25 deg) deflects along the wall
CarConfig.WALL_SCRAPE_LOSS = 0.35 -- speed fraction lost per unit of impact on a deflect
CarConfig.WALL_BUMP_KEEP = 0.4 -- speed kept on a steep bump
CarConfig.WALL_BUMP_BACK = 0.25 -- near head-on bumps bounce back at this fraction of the speed
CarConfig.WALL_HEADON_DOT = 0.85
CarConfig.WALL_SPIN_DOT = 0.8 -- harder than this AND faster than WALL_SPIN_MIN_SPEED: spin-out
CarConfig.WALL_SPIN_MIN_SPEED = 90
CarConfig.SPIN_DURATION = 0.9
CarConfig.SPIN_TURNS = 1.5
CarConfig.SPIN_SPEED_KEEP = 0.2

-- ---------------------------------------------------------------- recovery
CarConfig.KILL_DEPTH = 60 -- below the lowest route waypoint by this much = fell off the world
CarConfig.WATER_SINK_DEPTH = 2.2 -- car bottom this far under a water surface = drowned (shallower is drivable)
CarConfig.OFFTRACK_DROP = 6 -- grounded on Terrain this far below the route's height ...
CarConfig.OFFTRACK_TIME = 1.6 -- ... for this long = cannot get back, respawn (root attr CarOffTrackDrop overrides)
CarConfig.FADE_OUT = 0.3
CarConfig.FADE_IN = 0.35
CarConfig.FADE_MAX_ALPHA = 0.85 -- the fade never fully blacks out the screen (ART_BAR: no full-screen flash)
CarConfig.RESPAWN_REPLY_TIMEOUT = 0.8 -- wait this long for the server's CheckpointRespawn, then use the cached one
CarConfig.RESPAWN_SPEED = 30
CarConfig.RESPAWN_INVULN = 1.0

-- ---------------------------------------------------------------- camera
CarConfig.CAM_DISTANCE = 14.5
CarConfig.CAM_HEIGHT = 5.4
CarConfig.CAM_SPEED_PULLBACK = 2.5 -- extra distance at top speed
CarConfig.CAM_LOOK_AHEAD = 16
CarConfig.CAM_LOOK_HEIGHT = 2.0
CarConfig.CAM_YAW_RESPONSE = 5.5 -- (1/s) camera heading lag: drifts swing the car across the frame
CarConfig.CAM_VERTICAL_RESPONSE = 6 -- (1/s) camera height lag: jumps arc, landings settle
CarConfig.CAM_BASE_FOV = 68
CarConfig.CAM_SPEED_FOV = 4 -- added at top speed
CarConfig.CAM_BOOST_FOV = 9 -- added while boosting
CarConfig.CAM_FOV_RESPONSE = 8

-- ---------------------------------------------------------------- visuals
CarConfig.LEAN_DEG = 5 -- body roll toward the outside of a turn at full steer and speed
CarConfig.DRIFT_LEAN_DEG = 7
CarConfig.PITCH_ACCEL_DEG = 2 -- nose up under throttle, down under brake

-- ---------------------------------------------------------------- network and server validation
CarConfig.SYNC_INTERVAL = 0.08 -- SyncTransform cadence (same as the plane)
CarConfig.VALIDATION_SLACK = 1.6 -- allowed = maxSpeed * dt * slack + tolerance
CarConfig.VALIDATION_TOLERANCE = 8
CarConfig.VALIDATION_MAX_DT = 1.0 -- a stall never earns more than one second of travel
CarConfig.VALIDATION_IDLE_EPS = 0.05 -- smaller moves do not restart the clock (replication arrives in bursts)
CarConfig.TELEPORT_GRACE_RADIUS = 30 -- after a server-issued teleport the car must appear within this of the target
CarConfig.TELEPORT_GRACE_TIME = 2.0
CarConfig.ESCALATE_COUNT = 3 -- corrections within ESCALATE_WINDOW: the server takes the hull back for a moment
CarConfig.ESCALATE_WINDOW = 6
CarConfig.ESCALATE_HOLD = 1.0
CarConfig.RESPAWN_MIN_INTERVAL = 1.0

-- ---------------------------------------------------------------- controls hint (InputMode families, D20)
CarConfig.HINTS = {
	-- Short on purpose: InputMode's hint is TextScaled in 80% of the width, and at 740x360 an 88-character line
	-- shrank to ~11 px. Gas is automatic in Touch and the ITEM button carries its own caption.
	Touch = "Auto gas  ·  pad steers, pull down to brake  ·  hold TURN to drift",
	Gamepad = "Left stick steer  ·  A/R2 gas  ·  B/L2 brake\nR1 drift  ·  X item",
	KeyboardMouse = "A/D steer  ·  W gas  ·  S brake/reverse\nShift drift  ·  F item" -- v21: two fixed lines (the one-line wrap left a trailing separator),
} :: { [string]: string }

-- ================================================================ pure helpers
-- Turn rate (deg/s) at a speed: ramps in from 0 at standstill, peaks at FULL_TURN_SPEED, eases down to
-- HIGH_SPEED_TURN_FACTOR of the peak at TOP_SPEED and stays there above it (boosts).
function CarConfig.turnRate(speed: number): number
	local v = math.abs(speed)
	local low = math.clamp(v / CarConfig.FULL_TURN_SPEED, 0, 1) ^ CarConfig.TURN_LOW_SPEED_EXP
	local highT = math.clamp((v - CarConfig.FULL_TURN_SPEED) / (CarConfig.TOP_SPEED - CarConfig.FULL_TURN_SPEED), 0, 1)
	local high = 1 - (1 - CarConfig.HIGH_SPEED_TURN_FACTOR) * highT
	return CarConfig.TURN_RATE_MAX * low * high
end

-- Drift turn multiplier: steering into the drift tightens the line, steering out widens it, never straightens it.
function CarConfig.driftTurnMultiplier(steer: number, dir: number): number
	local into = math.clamp(steer * dir, -1, 1)
	return CarConfig.DRIFT_TURN_MIN + (CarConfig.DRIFT_TURN_MAX - CarConfig.DRIFT_TURN_MIN) * (into + 1) * 0.5
end

function CarConfig.driftChargeRate(steer: number, dir: number): number
	return CarConfig.DRIFT_CHARGE_BASE + CarConfig.DRIFT_CHARGE_TIGHT * math.max(0, math.clamp(steer * dir, -1, 1))
end

-- Spark colour {r, g, b} of a drift level in a zone: tiers 1-2 keep blue and orange, the top tier is the zone's.
function CarConfig.driftColor(level: number, zone: string?): { number }
	local lv = CarConfig.DRIFT_LEVELS[level]
	if not lv then
		return CarConfig.DRIFT_SMOKE_COLOR
	end
	if level == #CarConfig.DRIFT_LEVELS and level >= 3 then
		return (if zone then CarConfig.DRIFT_ZONE_COLORS[zone] else nil) or lv.color
	end
	return lv.color
end

-- Highest mini-turbo level the charge has reached (0 = none).
function CarConfig.driftLevel(charge: number): number
	local level = 0
	for i, lv in CarConfig.DRIFT_LEVELS do
		if charge >= lv.threshold then
			level = i
		end
	end
	return level
end

-- Ground contact from the four wheel probes. distances[i] = distance from wheel i's centre down to the road along
-- the car's down axis (math.huge = the probe hit nothing). verticalSpeed is the velocity along the car's up axis.
-- Returns grounded and the number of touching wheels. Hysteresis: a grounded car keeps contact over small crests
-- (SNAP_GROUNDED), an airborne one only lands when a wheel is really on the road and it is not still rising.
function CarConfig.resolveGrounded(wasGrounded: boolean, distances: { number }, verticalSpeed: number): (boolean, number)
	local reach = CarConfig.WHEEL_RADIUS + (if wasGrounded then CarConfig.SNAP_GROUNDED else CarConfig.SNAP_LANDING)
	local contacts = 0
	for _, d in distances do
		if d ~= math.huge and d <= reach then
			contacts += 1
		end
	end
	if not wasGrounded and verticalSpeed > CarConfig.LAND_MAX_UP_SPEED then
		return false, contacts
	end
	return contacts >= CarConfig.MIN_CONTACTS, contacts
end

-- Median suspension compression (WHEEL_RADIUS - distance) over the touching wheels: how far the hull must rise
-- (positive) or drop (negative) to sit on the road. The median ignores one wheel dropping into a paver seam.
function CarConfig.groundCorrection(distances: { number }, wasGrounded: boolean): number
	local reach = CarConfig.WHEEL_RADIUS + (if wasGrounded then CarConfig.SNAP_GROUNDED else CarConfig.SNAP_LANDING)
	local comps: { number } = {}
	for _, d in distances do
		if d ~= math.huge and d <= reach then
			table.insert(comps, CarConfig.WHEEL_RADIUS - d)
		end
	end
	local n = #comps
	if n == 0 then
		return 0
	end
	table.sort(comps)
	if n % 2 == 1 then
		return comps[(n + 1) // 2]
	end
	return (comps[n // 2] + comps[n // 2 + 1]) * 0.5
end

-- Wall response class from how head-on the hit is (impact = -moveDir . wallNormal, 0..1) and the speed.
function CarConfig.classifyWallHit(impact: number, speed: number): string
	if impact <= 0 then
		return "None"
	elseif impact < CarConfig.WALL_SHALLOW_DOT then
		return "Deflect"
	elseif impact >= CarConfig.WALL_SPIN_DOT and math.abs(speed) >= CarConfig.WALL_SPIN_MIN_SPEED then
		return "Spin"
	end
	return "Bump"
end

-- Highest horizontal speed any legal source reaches (top speed + pickups, pads, mini-turbos, item boost + magnet).
function CarConfig.maxHorizontalSpeed(): number
	local m = math.max(
		CarConfig.TOP_SPEED + CarConfig.SPEED_PICKUP_BONUS * CarConfig.MAX_SPEED_PICKUPS,
		CarConfig.PAD_BOOST_SPEED,
		CarConfig.ITEM_BOOST_MAX_SPEED
	)
	for _, lv in CarConfig.DRIFT_LEVELS do
		m = math.max(m, lv.boostSpeed)
	end
	return m + CarConfig.MAGNET_MAX_BONUS
end

-- One-gap displacement bound: horizontal and vertical are bounded separately (a falling car may drop at
-- MAX_FALL_SPEED while also driving at full boost). Returns ok plus the horizontal and vertical allowances. The
-- validator below does NOT apply it per sample (the tolerance would repeat every sample); it sizes the budget caps.
function CarConfig.checkDisplacement(horizontal: number, vertical: number, dt: number): (boolean, number, number)
	local t = math.clamp(dt, 0, CarConfig.VALIDATION_MAX_DT)
	local slack, tol = CarConfig.VALIDATION_SLACK, CarConfig.VALIDATION_TOLERANCE
	local allowedH = CarConfig.maxHorizontalSpeed() * t * slack + tol
	local vSpeed = if vertical < 0 then CarConfig.MAX_FALL_SPEED else CarConfig.MAX_RISE_SPEED
	local allowedV = vSpeed * t * slack + tol
	return horizontal <= allowedH and math.abs(vertical) <= allowedV, allowedH, allowedV
end

-- ---------------------------------------------------------------- displacement validator (server, pure)
-- One per player. Fed the hull position the server sees (replicated from the owning client) every Heartbeat.
-- Verdicts: "ok" (accepted, becomes the last valid position), "idle" (no real movement), "grace" (waiting for the
-- client to arrive after a server-issued teleport), "violation" (caller corrects the client to last valid).
-- Travel budgets (token bucket), not a per-sample bound: each axis earns legalSpeed * VALIDATION_SLACK studs per
-- second of real time, capped at one VALIDATION_MAX_DT of travel + VALIDATION_TOLERANCE, and every accepted move
-- spends what it covered. A per-sample "speed * dt * slack + tolerance" bound hands out the tolerance on EVERY
-- replicated sample, so a client moving 14 studs per 60 Hz sample (840 studs/s, 6x top speed) passed it forever.
-- With budgets the sustained rate is bounded by legalSpeed * slack whatever the sample rate, and a replication burst
-- after a stall is still judged over the whole gap (the budget kept filling while the position stood still).
-- Per-vehicle speed limits (L30, L53): nil = the car's. A plane's validator is built with PlaneGuardRules.limits().
export type Limits = {
	maxH: number, -- horizontal studs/s the vehicle can legally reach
	maxRise: number,
	maxFall: number,
	slack: number, -- allowance multiplier on top of the legal speed
}

export type Validator = {
	limits: Limits?,
	hasLast: boolean,
	x: number,
	y: number,
	z: number,
	clock: number, -- time of the last accepted move (reported as dt)
	refillClock: number, -- time the budgets were last topped up
	budgetH: number, -- horizontal studs the car may still cover right now
	budgetUp: number,
	budgetDown: number,
	hasGrace: boolean,
	gx: number,
	gy: number,
	gz: number,
	graceUntil: number,
}

-- Budget caps: exactly what checkDisplacement allows over VALIDATION_MAX_DT (the longest stall that earns travel).
function CarConfig.carLimits(): Limits
	return {
		maxH = CarConfig.maxHorizontalSpeed(),
		maxRise = CarConfig.MAX_RISE_SPEED,
		maxFall = CarConfig.MAX_FALL_SPEED,
		slack = CarConfig.VALIDATION_SLACK,
	}
end

function CarConfig.budgetCaps(limits: Limits?): (number, number, number)
	local lim = limits or CarConfig.carLimits()
	local t, slack, tol = CarConfig.VALIDATION_MAX_DT, lim.slack, CarConfig.VALIDATION_TOLERANCE
	return lim.maxH * t * slack + tol, lim.maxRise * t * slack + tol, lim.maxFall * t * slack + tol
end

function CarConfig.newValidator(limits: Limits?): Validator
	return {
		limits = limits,
		hasLast = false,
		x = 0,
		y = 0,
		z = 0,
		clock = 0,
		refillClock = 0,
		budgetH = 0,
		budgetUp = 0,
		budgetDown = 0,
		hasGrace = false,
		gx = 0,
		gy = 0,
		gz = 0,
		graceUntil = 0,
	}
end

-- Server-issued teleport (spawn, reset, checkpoint respawn, correction): accept the next position near the target.
function CarConfig.expectTeleport(v: Validator, x: number, y: number, z: number, now: number)
	v.hasGrace = true
	v.gx, v.gy, v.gz = x, y, z
	v.graceUntil = now + CarConfig.TELEPORT_GRACE_TIME
end

-- A fresh reference (first sample, arrival after a server teleport): budgets restart at the tolerance only, so a
-- reference reset never hands out a stored-up burst.
local function reset(v: Validator, x: number, y: number, z: number, now: number)
	v.hasLast = true
	v.x, v.y, v.z = x, y, z
	v.clock = now
	v.refillClock = now
	local tol = CarConfig.VALIDATION_TOLERANCE
	v.budgetH, v.budgetUp, v.budgetDown = tol, tol, tol
end

local function refill(v: Validator, now: number)
	local elapsed = math.max(0, now - v.refillClock)
	v.refillClock = math.max(v.refillClock, now)
	if elapsed <= 0 then
		return
	end
	local lim = v.limits or CarConfig.carLimits()
	local slack = lim.slack
	local capH, capUp, capDown = CarConfig.budgetCaps(v.limits)
	v.budgetH = math.min(capH, v.budgetH + lim.maxH * slack * elapsed)
	v.budgetUp = math.min(capUp, v.budgetUp + lim.maxRise * slack * elapsed)
	v.budgetDown = math.min(capDown, v.budgetDown + lim.maxFall * slack * elapsed)
end

function CarConfig.observe(v: Validator, x: number, y: number, z: number, now: number): (string, number, number, number)
	if v.hasGrace then
		local d = math.sqrt((x - v.gx) ^ 2 + (y - v.gy) ^ 2 + (z - v.gz) ^ 2)
		if d <= CarConfig.TELEPORT_GRACE_RADIUS then
			v.hasGrace = false
			reset(v, x, y, z, now)
			return "ok", d, CarConfig.TELEPORT_GRACE_RADIUS, 0
		elseif now < v.graceUntil then
			return "grace", d, CarConfig.TELEPORT_GRACE_RADIUS, 0
		end
		-- Never arrived: judge it against the teleport target from here on.
		v.hasGrace = false
		reset(v, v.gx, v.gy, v.gz, v.graceUntil)
	end
	if not v.hasLast then
		reset(v, x, y, z, now)
		return "ok", 0, 0, 0
	end
	refill(v, now)
	local dx, dy, dz = x - v.x, y - v.y, z - v.z
	local horizontal = math.sqrt(dx * dx + dz * dz)
	local dt = now - v.clock
	if horizontal < CarConfig.VALIDATION_IDLE_EPS and math.abs(dy) < CarConfig.VALIDATION_IDLE_EPS then
		return "idle", 0, v.budgetH, dt
	end
	local budgetV = if dy < 0 then v.budgetDown else v.budgetUp
	if horizontal <= v.budgetH and math.abs(dy) <= budgetV then
		local allowedH = v.budgetH
		v.budgetH -= horizontal
		if dy < 0 then
			v.budgetDown += dy
		else
			v.budgetUp -= dy
		end
		v.hasLast = true
		v.x, v.y, v.z = x, y, z
		v.clock = now
		return "ok", horizontal, allowedH, dt
	end
	-- Nothing is spent on a violation: the caller corrects to (v.x, v.y, v.z). Report the axis that failed.
	if horizontal <= v.budgetH then
		return "violation", math.abs(dy), budgetV, dt
	end
	return "violation", horizontal, v.budgetH, dt
end

-- Airborne detection convenience for callers that only have probe distances.
function CarConfig.isAirborne(wasGrounded: boolean, distances: { number }, verticalSpeed: number): boolean
	local grounded = CarConfig.resolveGrounded(wasGrounded, distances, verticalSpeed)
	return not grounded
end

return CarConfig
