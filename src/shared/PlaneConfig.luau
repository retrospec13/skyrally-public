--!strict
local PlaneConfig = {}

-- Core Flight Speeds (studs/s) per gamemap.md §2.1
PlaneConfig.BASE_SPEED = 110
PlaneConfig.MIN_CRUISE_SPEED = 78
PlaneConfig.FULL_THROTTLE_SPEED = 128
PlaneConfig.SPEED_PICKUP_BONUS = 1.4
PlaneConfig.MAX_SPEED_PICKUPS = 10

-- Boost Parameters per gamemap.md §2.1 & §2.2
PlaneConfig.BOOST_SPEED = 165
PlaneConfig.BOOST_DURATION = 1.8
PlaneConfig.OVERCHARGE_SPEED = 210
PlaneConfig.OVERCHARGE_DURATION = 2.6
PlaneConfig.OVERCHARGE_RELEASE_WINDOW = 0.15

-- Ring & Pad Detection / World Teaching Pull
-- Ring magnetism (flight_feel.md C6): a ring up to RING_PULL_DISTANCE ahead and within RING_PULL_RADIUS of the flight
-- path pulls the plane sideways at up to RING_PULL_STRENGTH studs/s (PlaneConfig.ringPull). Was 55 / 30 / 18: half a
-- second of a weak pull moved a plane ~4.5 studs, so a ring only caught planes already within ~23 of its centre. Now
-- the window is ~0.75 s at cruise and the catch is ~29 (tools/tests/flight_feel_spec.luau simulates it). The trigger
-- (19, a sphere past the 13.4 rim) is unchanged: the pull brings the plane to it, the rim stays honest.
PlaneConfig.RING_PULL_DISTANCE = 80
PlaneConfig.RING_PULL_RADIUS = 36
PlaneConfig.RING_PULL_STRENGTH = 26
PlaneConfig.RING_PULL_FORWARD = 14 -- studs/s of forward push at the pull's start (the old literal)
-- The sideways pull settles onto the ring's axis instead of crossing it (plane_stutter.md C2): at most
-- RING_PULL_SETTLE x the distance left per second, and never more than that distance in one frame. A fixed 26 studs/s
-- toward the axis overshot it by up to 0.43 studs every frame at 60 fps, so a plane that reached the axis chattered
-- sideways at 30 Hz (and the chase camera with it) until it passed the ring.
PlaneConfig.RING_PULL_SETTLE = 8
PlaneConfig.RING_TRIGGER_RADIUS = 19
PlaneConfig.PAD_TRIGGER_RADIUS = 18
PlaneConfig.PICKUP_TRIGGER_RADIUS = 14

-- Turn & Bank Rates (deg/s) per gamemap.md §2.1
PlaneConfig.PITCH_RATE = 65
PlaneConfig.SHARP_PITCH_RATE = 135
PlaneConfig.YAW_RATE = 75
PlaneConfig.SHARP_YAW_RATE = 145
-- Boosting used to turn SLOWER than cruising (65 vs 75 deg/s) at 1.5x the speed: a boosted radius of 145 studs
-- (165 / 65 deg/s) against bends of R 103-131 right after rings on DINO-4, SNOW-1 and ISLAND-2 inside a 34-stud
-- half-width corridor (flight_feel.md C4). 85 deg/s gives R 111 at 165 (cruise is R 84 at 110), still wider than a
-- cruise turn so a boost is a commitment, but one a bend after a ring can take without the sharp bank.
-- tools/map/tests/test_boost_windows.py reads BOOST_SPEED / BOOST_YAW_RATE.
PlaneConfig.BOOST_PITCH_RATE = 62
PlaneConfig.BOOST_YAW_RATE = 85

PlaneConfig.MAX_PITCH_DEG = 52
PlaneConfig.SHARP_MAX_PITCH_DEG = 78
PlaneConfig.MAX_BANK_DEG = 46
PlaneConfig.SHARP_MAX_BANK_DEG = 72
PlaneConfig.BANK_LERP_SPEED = 7.5

-- ---------------------------------------------------------------- Flight feel (docs/audits/flight_feel.md)
-- Owner 2026-10-20: "flying navigation is a bit hard". The pure curves below are specced in
-- tools/tests/flight_feel_spec.luau; FlightController applies them. Car handling is not touched.

-- Pitch auto-level (C1). Pitch is a rate control: holding up keeps climbing. It used to level (toward -2 deg at
-- 1.4/s) only with the stick exactly centred, so any held touch drift kept the nose climbing and a released 30 deg
-- climb still rose ~32 studs, more than the 30 studs of corridor above the line. Now the level pull scales with
-- (1 - |stick Y|): a partial hold settles at a pitch (0.3 -> ~8 deg, 0.5 -> ~23 deg), full deflection still climbs to
-- MAX_PITCH_DEG, and a release levels with a 0.38 s time constant (1 / PITCH_LEVEL_RATE): ~17 studs of rise.
PlaneConfig.PITCH_LEVEL_RATE = 2.6
PlaneConfig.PITCH_LEVEL_TARGET = -2 -- a hair nose-down: the dive assist keeps the speed up

-- Touch thumb pad (C2). The pad was linear with no dead zone, so every sideways drag also pitched (a thumb is never
-- exactly level: a 15 deg drift is 0.26 of pitch). Radial dead zone, then a Y-only dead zone so turning does not
-- climb, then an expo curve so small corrections are small.
PlaneConfig.TOUCH_DEADZONE = 0.08
PlaneConfig.TOUCH_PITCH_DEADZONE = 0.3
PlaneConfig.TOUCH_EXPO = 0.45 -- 0 = linear, 1 = cubic

-- Gamepad left stick (C2): same expo after the existing 0.15 radial dead zone.
PlaneConfig.PAD_DEADZONE = 0.15
PlaneConfig.PAD_EXPO = 0.35

-- Keyboard and D-pad (C2): digital keys ramp to full lock over KEY_RISE_S (a tap is a nudge, not 75 deg/s at once)
-- and let go over KEY_FALL_S.
PlaneConfig.KEY_RISE_S = 0.16
PlaneConfig.KEY_FALL_S = 0.08

-- Course assist (C3). The assist only filled axes the player was NOT steering (player wins per axis, L03), so a
-- touch player who always has a thumb on the pad never got any help, and it took ASSIST_RELEASE_S to come back.
-- Now under partial input the assist adds ASSIST_UNDER_INPUT of itself, scaled by the stick's headroom (1 - |stick|),
-- so full deflection is still purely the player's and the help fades as the player commits.
PlaneConfig.ASSIST_UNDER_INPUT = 0.45
PlaneConfig.ASSIST_RELEASE_S = 0.35 -- was 0.6: seconds for the full idle assist to return after a release
-- Pursuit point = LOOKAHEAD_BASE + LOOKAHEAD_PER_SPEED * speed studs ahead (was 65 + 0.45 v: 114 at 110; now 99).
-- Shorter pulls a drifted plane back to the line faster (cross-track time constant ~ lookahead / speed: 1.04 -> 0.9 s).
PlaneConfig.ASSIST_LOOKAHEAD_BASE = 55
PlaneConfig.ASSIST_LOOKAHEAD_PER_SPEED = 0.4
PlaneConfig.ASSIST_YAW_GAIN_DEG = 22 -- yaw error for full assist steer (was 26)
PlaneConfig.ASSIST_PITCH_GAIN_DEG = 18
PlaneConfig.ASSIST_MAX_X = 0.95 -- was 0.92
PlaneConfig.ASSIST_MAX_Y = 0.88

-- Respawn & Collision Rules
PlaneConfig.RESPAWN_DELAY = 1.0
PlaneConfig.RESPAWN_INVULN = 1.6
PlaneConfig.WALL_DEFLECT_DOT = -0.58 -- Glancing hits gentler than this slide along walls

-- Chase Camera (framed closely behind the plane so it occupies the lower-central fifth of the screen per 04_dino4_controls.png)
PlaneConfig.CAM_DISTANCE = 15.2
PlaneConfig.CAM_HEIGHT = 4.5
PlaneConfig.CAM_BANK_FACTOR = 0.32
PlaneConfig.CAM_BASE_FOV = 65
PlaneConfig.CAM_BOOST_FOV = 73
PlaneConfig.CAM_OVERCHARGE_FOV = 77 -- v38-feel: an Overcharge boost reads wider than a ring
PlaneConfig.CAM_FOV_EASE_BACK = 2.6 -- (1/s) the boost FOV eases back over ~1 s (widening stays at 9/s)
-- Turn lead (C5): the look point swings into the turn by the yaw rate times CAM_TURN_LEAD_S (capped), so the bend's
-- exit is on screen while turning; the camera position and the framing lock (FOV, distance) are unchanged. Eased at
-- CAM_LEAD_LERP 1/s so a flick does not whip the view. At 75 deg/s: 12 deg of lead.
PlaneConfig.CAM_TURN_LEAD_S = 0.16
PlaneConfig.CAM_TURN_LEAD_MAX_DEG = 14
PlaneConfig.CAM_LEAD_LERP = 5
-- Follow (docs/audits/plane_stutter.md C1). The camera used to lerp toward its goal by dt * 18 each frame, which leaves
-- it speed * (1 - 18 dt) / 18 behind a moving plane: the gap changed with every frame time (0.4 studs between a 16.7 and
-- a 20 ms frame at 128 studs/s, 2 studs on a 33 ms hitch), so the plane surged against the camera whenever frame times
-- varied. Now the smoothed frame is first carried by the plane's own move this frame, then eased toward the goal at a
-- dt-exact rate, and the old 60 fps gap is kept on purpose as a trail along the velocity: identical framing at 60 fps,
-- and a straight flight has no frame-time term left at all.
PlaneConfig.CAM_FOLLOW_RATE = 21.4 -- 1/s: 1 - exp(-21.4 / 60) = 0.30, the old dt * 18 at 60 fps
PlaneConfig.CAM_SPEED_TRAIL_S = 0.7 / 18 -- s: the old steady gap at 60 fps, speed * (1 - 0.3) / 18
PlaneConfig.CAM_CARRY_MAX = 40 -- studs: a move longer than this in one frame is a teleport (snap, do not carry)

-- Race & AI Configuration
PlaneConfig.TOTAL_LAPS = 3
-- LAUNCH_PROGRESSION section 4 / TEST_LIST_LAUNCH L08: every race has eight entrants; bots fill the empty seats.
-- THE field size: AIRacers (bots = field - humans in that field), the start grid (FlightServer, AIRacers freeSlot) and
-- the results card rows (RaceUI) follow it. Changing it also needs tools/map/adapt.py GRID_SLOTS (re-bake every map's
-- start slots) and one AI_BOTS roster entry (with a BotPersonality and a PilotSeat preset) per extra bot;
-- tools/tests/racer_view_spec checks they agree. Eight stays the default (DKR's eight; the per-entrant server, network
-- and phone numbers are in docs/DECISIONS.md D02).
PlaneConfig.AI_FIELD_SIZE = 8
-- Economy v3 phase 2 (proposed D22): the server size is its own number, separate from the race field. Players on the
-- server = default.project.json MaxPlayers (racer_view_spec checks they agree; the live value is the Creator Hub server
-- size). Eight at launch; above the field only once RaceFlowRules.PER_GROUP is on and 16 is measured on phones
-- (docs/design/PER_GROUP_RACES.md), since the single-race path seats every player in one field.
PlaneConfig.SERVER_SIZE = 8
PlaneConfig.MAX_PLAYERS = PlaneConfig.SERVER_SIZE
-- Hub plaza spawn seats (FlightServer.getStartCFrame in hub mode: rows of four, 12 studs apart, rows 16 back). A slot
-- past the last seat wraps instead of landing in the upper town (L31), whatever the field or server size; two rows
-- are what the plaza holds clear of the fountain today.
PlaneConfig.HUB_SEATS = 8
-- Bot roster size: the most bots one race can hold. The live count is AI_FIELD_SIZE minus the players
-- (AIRacers.botsNeeded), so this is #AI_BOTS, not "bots per race".
PlaneConfig.AI_COUNT = PlaneConfig.AI_FIELD_SIZE - 1
-- Economy v3 phase 4 (bots pass as players): ON. server/AIRacers gives each race bot a generated username (checked to be
-- nobody's account: server/BotNamePool), a random pilot outfit and Garage cosmetics, a neutral model name (no "AI_"), and
-- human-like pace (shared/BotPaceRules); RaceManager stops telling clients which standings rows are bots. OFF = the old
-- seven stylised roster names and the AI_ model names. Needs the owner's yes on Roblox's policy for undisclosed bots
-- (DECISIONS_V3_PROPOSED O9) before a public release; private builds run with it on.
PlaneConfig.BOT_DISGUISE = true
PlaneConfig.CHECKPOINT_GATE_FRACTION = 0.55

-- Roster, fastest first: the first k entries race when k seats are free, and the fastest takes the frontmost free slot.
-- Ace/Blaze/Nova pace numbers are the L14 measurements and stay exact; the four added racers sit below them in 3/0.01
-- steps. Names are original (no DKR character). Lanes/heights are a three-tier stagger inside the brief's box
-- (lanes within +-12, heights 8..17 above the line): low 8 at -12/0/+12, mid 12.5 at -6/+6, high 17 at -9/+9, so every
-- lane is distinct and any two bots are at least 12 studs apart sideways or 4.5 apart vertically. A pass between
-- bots whose wings would still touch is resolved at run time by AIRacers' lift (AI_AVOID).
-- Bot i always starts in grid slot 9 - i (AIRacers.botSlots), and even slots sit right of the line (+lateral), odd
-- slots left, so each lane is on its slot's side (or the centre): row-mates fan outward off the grid, never across.
PlaneConfig.AI_BOTS = {
	{
		name = "Ace Aero",
		color = Color3.fromRGB(55, 165, 255),
		accent = Color3.fromRGB(255, 220, 60),
		baseSpeed = 139, -- 2026-10-18 retune after the 2.05x speed fix (L14 runs): beats an idle assisted run, loses to mid skill
		boostFactor = 1.10,
		laneOffset = 6,
		heightOffset = 12.5,
	},
	{
		name = "Blaze Wing",
		color = Color3.fromRGB(255, 95, 45),
		accent = Color3.fromRGB(255, 235, 120),
		baseSpeed = 134,
		boostFactor = 1.07,
		laneOffset = -6,
		heightOffset = 12.5,
	},
	{
		name = "Nova Sky",
		color = Color3.fromRGB(120, 235, 95),
		accent = Color3.fromRGB(240, 255, 255),
		baseSpeed = 129,
		boostFactor = 1.04,
		laneOffset = 0,
		heightOffset = 8,
	},
	{
		name = "Zephyr Dash",
		color = Color3.fromRGB(35, 200, 185),
		accent = Color3.fromRGB(235, 255, 250),
		baseSpeed = 126,
		boostFactor = 1.03,
		laneOffset = -12,
		heightOffset = 8,
	},
	{
		name = "Indigo Comet",
		color = Color3.fromRGB(100, 80, 220),
		accent = Color3.fromRGB(255, 210, 90),
		baseSpeed = 123,
		boostFactor = 1.02,
		laneOffset = 9,
		heightOffset = 17,
	},
	{
		name = "Rosa Glide",
		color = Color3.fromRGB(240, 95, 175),
		accent = Color3.fromRGB(255, 235, 245),
		baseSpeed = 120,
		boostFactor = 1.0,
		laneOffset = -9,
		heightOffset = 17,
	},
	{
		name = "Sunny Rotor",
		color = Color3.fromRGB(250, 205, 45),
		accent = Color3.fromRGB(110, 60, 30),
		baseSpeed = 117,
		boostFactor = 0.98,
		laneOffset = 12,
		heightOffset = 8,
	},
}

-- Lane box from the L08 brief; AIRacers.validateRoster and SelfTest check the roster against it.
PlaneConfig.AI_LANES = { maxLateral = 12, minHeight = 8, maxHeight = 17 }

-- Start grid when the active track registered no start CFrames: the slot formula of tools/map/adapt.py grid_slot with
-- DINO-4's plan numbers (slot 1 on the centre line at station 18, then pairs at +-12 one 28-stud row further down the
-- route, 11 above the line). Bots blend from their slot to their lane over mergeDistance studs of travel.
-- Spacing (2026-10-19, grid-order regression): rows 28 apart put the plane one row behind wholly behind the chase camera
-- (CAM_DISTANCE 15.2 + half a plane 7 + RacerViewRules.NEAR_CLEAR 6), and lanes +-12 (AI_LANES.maxLateral) keep the
-- centre-line plane out of the sightline of a player beside it; tools/map/adapt.py grid_camera_gate holds every map to it.
PlaneConfig.AI_GRID = { station = 18, rowSpacing = 28, laneOffset = 12, height = 11, mergeDistance = 150 }

-- Seconds after a race (re)start during which a join or leave resizes the field at once (seats are still on the grid).
-- Later a joiner takes the last-placed bot's seat and a leaver's seat stays empty until the next reset.
PlaneConfig.AI_FIELD_OPEN_SECONDS = 3

-- Cosmetic lane weave (studs, rad/s); faded in with the grid merge so the start stays in formation.
PlaneConfig.AI_WEAVE = { lateral = 2.5, vertical = 1.2, rate = 1.6 }

-- Bot-to-bot separation. Plane envelope: span 16 (ItemRules.TUNING "plane hull is about 16 wide"), 5 tall with the fin,
-- 14 long (the old grid row spacing). Two bots overlapping along the course, following within length + near, or closing
-- inside length + max(lookahead, closing speed * planSeconds), whose lane centres are closer than span (plus their
-- weave) are a conflict: merged bots first step apart sideways (each up to maxSide, plus sideMargin), and only a pair
-- that still overlaps gets the higher-tier one lifted until they are clearHeight apart. `near` covers a spin-out right
-- ahead (it closes in < 0.1 s). Lift and side step follow a critically damped spring (natural rate `response` 1/s)
-- capped at climbRate up / fallRate down / sideRate sideways (studs/s) and at `accel` (studs/s^2), so neither the
-- position nor its speed steps: a plane at ~135 studs/s climbing 16 studs/s is
-- a 7 degree climb, where the old 0.1 s lag popped bots up at up to 84 studs/s several times per bot per minute.
-- settleSeconds is the spring tail a side step is given before it counts. tools/tests/field_spec.luau simulates the
-- field (lift events, climb and side speeds, wing overlap).
PlaneConfig.AI_AVOID = {
	span = 16,
	clearHeight = 5,
	length = 14,
	near = 10,
	lookahead = 45,
	planSeconds = 2.0,
	maxLift = 14,
	response = 7,
	climbRate = 16,
	accel = 60, -- studs/s^2 cap on the eased lift and side step (full climb rate in about a quarter second)
	liftMargin = 0.75, -- studs over the bare clearance: the eased lift trails a weaving target a little
	urgentClimbRate = 30, -- a climb that cannot wait (contact nearer than the eased climb finishes)
	urgentResponse = 16,
	urgentAccel = 400,
	urgentDeficit = 1, -- studs still to climb below which a late climb stays eased (a weave wobble, not a pass)
	fallRate = 5,
	maxSide = 5,
	sideMargin = 0.5,
	sideRate = 10,
	settleSeconds = 0.35,
}

-- Bot item heuristics (OURS; tuned under TEST_LIST_LAUNCH L07/L08). Distances are course studs.
PlaneConfig.AI_ITEMS = {
	podReach = 14, -- a bot takes an item pod it passes within this distance of (PICKUP_TRIGGER_RADIUS, the player's)
	thinkInterval = 0.25, -- s between item decisions
	minHold = 0.6, -- s a fresh item is held before use, so a pickup and its use read as two moments
	maxHold = 12, -- s before a held item is used anyway (no hoarding)
	missileMinAhead = 20,
	missileMaxAhead = 150,
	trapMaxBehind = 60,
	shieldThreatBehind = 150, -- a rival this close behind holding a missile counts as an incoming missile
	magnetMinAhead = 30,
	straightLookahead = 150,
	straightMinDot = 0.97,
	-- Items v4 (AIRacers.decideItemUse): Golden Wings rams a rival this near; Boom Bomb lands near a rival this far
	-- ahead (thrown 60); Frost Shot / Coin Burst are straight shots, kept to rivals this near.
	ramReach = 40,
	bombMinAhead = 35,
	bombMaxAhead = 95,
	shotMaxAhead = 110,
	-- v38: the horn spins a rival this near (its ring is 18-30); Item Steal waits this long (a pickup then a theft read
	-- as two moments).
	hornReach = 16,
	stealDelay = 1.5,
}

-- Bot reaction to a missile/trap hit (ItemService.setBotHitHandler): speed cut, brake rate and barrel-roll spin.
PlaneConfig.AI_HIT = { defaultStun = 1.2, minStun = 0.4, maxStun = 3, speedFactor = 0.4, brakeRate = 8, spinTurns = 2 }

-- Light rubber-banding so a clean-flying player beats the bots
PlaneConfig.RUBBER_BAND_BEHIND_DIST = 260
PlaneConfig.RUBBER_BAND_AHEAD_DIST = 200
PlaneConfig.RUBBER_BAND_MAX_BOOST = 0.14 -- +14% when far behind player
PlaneConfig.RUBBER_BAND_MAX_SLOW = 0.12  -- -12% when far ahead of player

-- Course leash (trap audit G5.4: F5, SN-10, D4-09). In race modes (not battles, not the hub) a plane further than
-- LEASH_WARN from the course (the main line or an alternate line, at flight height) gets the WRONG WAY arrow and its
-- steering is pulled back toward the course even with the assist off: LEASH_MIN_PULL at LEASH_WARN rising to all of
-- it at LEASH_FULL. Further than LEASH_RESPAWN for LEASH_RESPAWN_TIME, it is put back on the course: in a race through the
-- server's RETURN to course frame (shared/FlightGuideRules, FLIGHT_GUIDE.md 4.4: near where it left, never ahead of its
-- best progress), else (or when the server refuses) at its last checkpoint (the plane's own rescue path, as the RESPAWN
-- button). The warning clears LEASH_CLEAR_MARGIN inside LEASH_WARN.
-- Steering only: the leash never changes speed (the off-course drag at 80 studs is FlightGuideRules').
PlaneConfig.LEASH_WARN = 200
PlaneConfig.LEASH_FULL = 300
PlaneConfig.LEASH_RESPAWN = 380
PlaneConfig.LEASH_RESPAWN_TIME = 1.5
PlaneConfig.LEASH_MIN_PULL = 0.2 -- flight_feel.md C7: was 0.35, a yank at 200; the guide's drag and RETURN start at 80
PlaneConfig.LEASH_CLEAR_MARGIN = 20
PlaneConfig.LEASH_HZ = 10 -- course distance samples per second when the assist is not already computing it

-- ---------------------------------------------------------------- Flight feel curves (flight_feel.md)

-- Turn radius (studs) at a speed (studs/s) and yaw rate (deg/s).
function PlaneConfig.turnRadius(speed: number, yawRateDeg: number): number
	return speed / math.rad(yawRateDeg)
end

-- One axis through a dead zone and an expo curve: (1 - e) x + e x^3 on the rescaled magnitude, sign kept.
function PlaneConfig.shapeAxis(v: number, deadzone: number, expo: number): number
	local a = math.abs(v)
	if a <= deadzone then
		return 0
	end
	local x = math.min(1, (a - deadzone) / (1 - deadzone))
	return math.sign(v) * ((1 - expo) * x + expo * x * x * x)
end

-- Touch pad (normalised -1..1 each axis) to steer: radial dead zone, Y-only dead zone, expo on each axis.
function PlaneConfig.shapeTouch(x: number, y: number): (number, number)
	local m = math.sqrt(x * x + y * y)
	if m <= PlaneConfig.TOUCH_DEADZONE then
		return 0, 0
	end
	return PlaneConfig.shapeAxis(x, PlaneConfig.TOUCH_DEADZONE, PlaneConfig.TOUCH_EXPO),
		PlaneConfig.shapeAxis(y, PlaneConfig.TOUCH_PITCH_DEADZONE, PlaneConfig.TOUCH_EXPO)
end

-- Gamepad stick to steer: radial dead zone (direction kept), expo on the magnitude.
function PlaneConfig.shapeStick(x: number, y: number): (number, number)
	local m = math.sqrt(x * x + y * y)
	if m <= PlaneConfig.PAD_DEADZONE then
		return 0, 0
	end
	local k = PlaneConfig.shapeAxis(math.min(1, m), PlaneConfig.PAD_DEADZONE, PlaneConfig.PAD_EXPO) / m
	return x * k, y * k
end

-- Digital key ramp: cur moves toward target (-1, 0 or 1) at 1 / KEY_RISE_S per second when pushing further out,
-- 1 / KEY_FALL_S when easing back or reversing.
function PlaneConfig.rampKey(cur: number, target: number, dt: number): number
	local out = math.abs(target) > math.abs(cur) and (cur == 0 or math.sign(target) == math.sign(cur))
	local rate = if out then 1 / PlaneConfig.KEY_RISE_S else 1 / PlaneConfig.KEY_FALL_S
	local step = rate * dt
	if math.abs(target - cur) <= step then
		return target
	end
	return cur + math.sign(target - cur) * step
end

-- One pitch step (degrees). `level` (0..1) scales the auto-level: FlightController passes 1 minus the assist's share
-- of the pitch axis, so the course assist is never fought while it holds the line height.
function PlaneConfig.pitchStep(pitch: number, y: number, rate: number, maxPitch: number, dt: number, level: number): number
	local p = pitch + y * rate * dt
	local k = PlaneConfig.PITCH_LEVEL_RATE * (1 - math.min(1, math.abs(y))) * level
	p += (PlaneConfig.PITCH_LEVEL_TARGET - p) * math.clamp(dt * k, 0, 1)
	return math.clamp(p, -maxPitch, maxPitch)
end

-- One axis of the course assist under the player's input. ramp (0..1) is how far the idle assist has come back since
-- the player last steered this axis. Returns the steer value and the assist's share of the axis.
function PlaneConfig.assistAxis(player: number, assist: number, ramp: number): (number, number)
	local w = PlaneConfig.ASSIST_UNDER_INPUT + (1 - PlaneConfig.ASSIST_UNDER_INPUT) * math.clamp(ramp, 0, 1)
	local a = math.abs(player)
	if a <= 0.05 then
		return assist * w, w
	end
	local share = w * (1 - math.min(1, a))
	return math.clamp(player + assist * share, -1, 1), share
end

-- Pursuit lookahead (studs) at a speed.
function PlaneConfig.assistLookahead(speed: number): number
	return PlaneConfig.ASSIST_LOOKAHEAD_BASE + PlaneConfig.ASSIST_LOOKAHEAD_PER_SPEED * speed
end

-- Sideways ring pull (studs/s) for a ring forwardDot studs ahead and lateral studs off the flight path; 0 outside.
function PlaneConfig.ringPull(forwardDot: number, lateral: number): number
	if forwardDot <= -4 or forwardDot >= PlaneConfig.RING_PULL_DISTANCE or lateral >= PlaneConfig.RING_PULL_RADIUS then
		return 0
	end
	return PlaneConfig.RING_PULL_STRENGTH * math.min(1, 1 - forwardDot / PlaneConfig.RING_PULL_DISTANCE)
end

-- Sideways ring pull speed (studs/s) actually applied this frame, `lateral` studs off the ring's axis: the ringPull
-- strength, eased onto the axis (RING_PULL_SETTLE) and never past it in one dt-long step.
function PlaneConfig.ringPullLateral(pull: number, lateral: number, dt: number): number
	return math.max(0, math.min(pull, lateral * PlaneConfig.RING_PULL_SETTLE, lateral / math.max(dt, 1e-3)))
end

-- Chase camera follow (plane_stutter.md C1): `prev` is last frame's smoothed camera frame, `carry` the plane's move since
-- then, `goal` this frame's goal (already trailed by camTrail). Returns the new smoothed frame.
function PlaneConfig.camFollow(prev: CFrame, carry: Vector3, goal: CFrame, dt: number): CFrame
	return (prev + carry):Lerp(goal, 1 - math.exp(-PlaneConfig.CAM_FOLLOW_RATE * dt))
end

-- The speed trail the follow keeps behind the goal (studs, world): the old 60 fps gap, along the plane's velocity.
function PlaneConfig.camTrail(velocity: Vector3): Vector3
	return velocity * PlaneConfig.CAM_SPEED_TRAIL_S
end

-- Camera look lead (degrees, + = left like yawDeg) for a yaw rate (deg/s, + = turning left).
function PlaneConfig.camLeadDeg(yawRateDeg: number): number
	local m = PlaneConfig.CAM_TURN_LEAD_MAX_DEG
	return math.clamp(yawRateDeg * PlaneConfig.CAM_TURN_LEAD_S, -m, m)
end

-- Pull weight (0..1) at a course distance.
function PlaneConfig.leashWeight(dist: number): number
	if dist <= PlaneConfig.LEASH_WARN then
		return 0
	end
	local t = math.clamp((dist - PlaneConfig.LEASH_WARN) / (PlaneConfig.LEASH_FULL - PlaneConfig.LEASH_WARN), 0, 1)
	return PlaneConfig.LEASH_MIN_PULL + (1 - PlaneConfig.LEASH_MIN_PULL) * t
end

export type LeashState = { warn: boolean, outTimer: number }
function PlaneConfig.newLeash(): LeashState
	return { warn = false, outTimer = 0 }
end

-- One step. Returns "ok" | "warn" | "respawn" ("respawn" once, then the out timer starts over).
function PlaneConfig.leashStep(s: LeashState, dist: number, dt: number): string
	if s.warn then
		s.warn = dist > PlaneConfig.LEASH_WARN - PlaneConfig.LEASH_CLEAR_MARGIN
	else
		s.warn = dist > PlaneConfig.LEASH_WARN
	end
	if dist > PlaneConfig.LEASH_RESPAWN then
		s.outTimer += dt
		if s.outTimer >= PlaneConfig.LEASH_RESPAWN_TIME then
			s.outTimer = 0
			return "respawn"
		end
	else
		s.outTimer = 0
	end
	return if s.warn then "warn" else "ok"
end

return PlaneConfig
