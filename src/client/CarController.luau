--!strict
-- Launch car controller (PLAN L2, TEST_LIST_LAUNCH L05): kinematic arcade driving in the DKR / Mario Kart class.
--
-- Model: ONE authoritative simulated position (simPos) integrated from its own velocity every frame and written to
-- the Hull, never re-read from hull.Position. The Hull is unanchored with a LinearVelocity for replication, so physics
-- also moves it between frames; integrating from hull.Position counted that motion twice (the 2.05x plane speed bug,
-- FlightController ~752). The only time simPos follows the Hull is a server teleport (> 40 studs away).
--   ground  four probes cast down from the wheel centres (CarConfig.WHEELS) give contact, the road normal (slopes and
--           banks) and the suspension correction (median wheel, so a paver seam does not dip the car).
--   air     fewer than two touching wheels = airborne (ramp lips, gaps): ballistic with CarConfig.GRAVITY, a little
--           air steer, landing squash on touchdown.
--   steer   speed-sensitive turn rate (CarConfig.turnRate); drift (Shift / R1 / touch TURN) while steering slides the
--           body CarConfig.DRIFT_SLIDE_DEG into the turn and charges mini-turbo levels (blue, orange sparks), released
--           as a boost.
--   walls   swept rays along the move: shallow hits deflect along the wall, steep hits bump (speed loss / bounce
--           back), hard fast hits spin out. No crash-explode like the plane.
--   recover kill height, water deeper than CarConfig.WATER_SINK_DEPTH (terrain sea or a battle tide), lethal hazards
--           or stranded off-track: fade, FlightStateRemote "RequestRespawn", the server answers "CheckpointRespawn"
--           with RaceManager's last checkpoint frame (the plane's remotes), the car is set down on the road under it
--           facing the route. A respawn the server orders on its own (a tide drown, an arena boundary return) plays
--           the same fade-out and splash or poof first, never a silent pop (trap audit X-02).
--   way out (trap audit G5, shared/RespawnRules) the RESPAWN button, Backspace or gamepad View asks for the same
--           server-placed respawn (3 s cooldown, server-checked); a stuck watchdog offers it after 3 s of trying
--           without progress and runs it at 6 s. Out of a battle (BattleOut) nothing respawns the car (X-03).
-- Server authority: the client only proposes its transform (SyncTransform); CarServer validates every replicated
-- position and sends "RequestCorrection" for impossible moves. Laps, finish and awards stay with RaceManager.
--
-- Input follows FlightController's conventions (D20): keyboard A/D or arrows steer, W/Up gas, S/Down brake/reverse,
-- Shift/R/Space drift; gamepad left stick or D-pad steer, A/R2 gas, B/L2 brake, R1 (or L1) drift; mouse steering only
-- while the right button is held; touch uses RaceUI's controls, which write FlightController.mobile*: stone pad X
-- steers (pull down = brake/reverse), TURN = drift, gas is automatic in Touch mode (ITEM fires items). Items: F /
-- gamepad X / touch ITEM go through FlightController.requestItemUse (server decides), and the effects the server
-- sends back reach the car through this module's own ItemRemote "ItemEffect" listener (init()).
--
-- Tricks (REMARKABLE Batch 1, shared/TrickRules): Hop and Spin (a drift press with the stick centred pops the car
-- up; a press with steer in the air spins the body; land it upright for STUCK IT!, a ramp-length jump also earns the
-- drift tier 1 boost; land mid-spin and it flubs), Grid Bounce (the same press on the start line bounces and spins the
-- body only; others see it through the TrickSpin/GridHop car attributes CarServer replicates) and the rev-match start
-- (gas on the "1" = PERFECT START with the drift tier 1 boost, gas held from the 3 = FLOODED, touch taps a ring).
--
-- Coexists with FlightController: it binds "Plane_<name>", this binds "Car_<name>" in workspace.Planes, so exactly
-- one of them drives. While a car is bound, this mirrors speed/boost/drift into FlightController's exposed fields so
-- RaceUI's button highlights and the Vfx.step call in FlightController (speed lines, rigs) follow the car.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CarConfig = require(Shared:WaitForChild("CarConfig"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr")) -- economy v3 phase 2b: this player's own race GO time
local FlightController = require(script.Parent:WaitForChild("FlightController"))
local SoundJuice = require(script.Parent:WaitForChild("SoundJuice"))
local Vfx = require(script.Parent:WaitForChild("Vfx"))
local ReverseRules = require(Shared:WaitForChild("ReverseRules")) -- reverse v2: brake, stop, hold, then back up (MK rule)
local TrickRules = require(Shared:WaitForChild("TrickRules"))
local TrickJuice = require(script.Parent:WaitForChild("TrickJuice"))
local StartFx = require(script.Parent:WaitForChild("StartFx")) -- v37 rocket start: exhaust charge glow, whine, GO burst
local Slipstream = require(script.Parent:WaitForChild("Slipstream")) -- v37: a rival's wake charges a slingshot
local SlipstreamRules = require(Shared:WaitForChild("SlipstreamRules"))
local RespawnRules = require(Shared:WaitForChild("RespawnRules"))
-- The magnet reads another player's hull at the engine's replicated pose, never RacerView's stream draw (remote-smooth).
-- Style lane (REMARKABLE Batch 2 items 15-17: zone turbo, near misses, the style chain) and alternate lines (G8).
local QASteerRules = require(Shared:WaitForChild("QASteerRules")) -- Studio-only QA steering hook (QAFollowLine / QASteer / QAThrottle)

-- Cold-path module requires grouped in one table: the chunk is capped at 200 top-level locals (Luau register limit).
local Mods = {
	Prof = require(Shared:WaitForChild("Prof")), -- MicroProfiler labels (perf review v21 PF-10)
	FidelityRules = require(Shared:WaitForChild("FidelityRules")), -- timed hub-boss pads (PadLive, M-2)
	SplineUtils = require(Shared:WaitForChild("SplineUtils")),
	Sfx37 = require(script.Parent:WaitForChild("Sfx37")), -- v38-feel: the drift charge whine
	TrackRegistry = require(Shared:WaitForChild("TrackRegistry")),
	VfxAssets = require(Shared:WaitForChild("VfxAssets")),
	FlipFx = require(Shared:WaitForChild("FlipFx")),
	TriggerIndex = require(script.Parent:WaitForChild("TriggerIndex")),
	Sfx = require(script.Parent:WaitForChild("Sfx")),
	Settings = require(script.Parent:WaitForChild("Settings")), -- audit H13: camera shake toggle
	GroundFx = require(script.Parent:WaitForChild("GroundFx")), -- tyre marks, spray/powder, mini-turbo release, contact sparks
	InputMode = require(script.Parent:WaitForChild("InputMode")),
	AssistRules = require(Shared:WaitForChild("AssistRules")), -- when the touch auto throttle may act
	TouchSteerRules = require(Shared:WaitForChild("TouchSteerRules")), -- touch steer dead zone / curve, pad brake
	CourseArrow = require(script.Parent:WaitForChild("CourseArrow")), -- the car WRONG WAY sign (reverse v2)
	HudPhase = require(script.Parent:WaitForChild("HudPhase")),
	GroundFxRules = require(Shared:WaitForChild("GroundFxRules")),
	SfxRules = require(Shared:WaitForChild("SfxRules")),
	ItemRules = require(Shared:WaitForChild("ItemRules")),
	PlayerStreamRules = require(Shared:WaitForChild("PlayerStreamRules")),
	PodLocal = require(script.Parent:WaitForChild("PodLocal")),
	StyleChain = require(script.Parent:WaitForChild("StyleChain")),
	StyleSense = require(script.Parent:WaitForChild("StyleSense")),
	RouteBranch = require(Shared:WaitForChild("RouteBranch")),
}

local CarController = {}

-- ---------------------------------------------------------------- exposed state (HUD, QA, SelfTest probes)
CarController.initialized = false
CarController.car = nil :: Model?
CarController.hull = nil :: BasePart?
CarController.speed = 0 -- signed: negative = reversing
CarController.steer = 0 -- smoothed -1..1
CarController.throttle = 0 -- -1..1
CarController.grounded = false
CarController.contacts = 0
CarController.airTime = 0
CarController.drifting = false
CarController.driftDir = 0
CarController.driftCharge = 0
CarController.driftLevel = 0
CarController.boostState = "None"
CarController.boostTimer = 0
CarController.spinning = false
CarController.respawning = false
CarController.invulnTimer = 0
CarController.lastRespawnAt = -math.huge -- os.clock of the last completed respawn (ItemClient: stale item hits)
CarController.speedPickups = 0
CarController.lastCheckpointCF = CFrame.new()
CarController.cameraTrauma = 0
CarController.corrections = 0
CarController.stuckOffer = false -- HUD: the stuck watchdog offers the rescue (the RESPAWN button pulses)
CarController.reverseMode = "drive" :: string -- ReverseRules mode this frame (RaceUI's BRAKE / REV caption)
-- REMARKABLE item 13 (client/GalleonMoments): a scripted ride (the galleon cannons). While `ride` returns a frame the
-- step only writes that frame; when it returns nil the car is set down on `rideLand` at `rideLandSpeed`. A respawn or
-- a fade cancels it (the server already announced the landing: its correction lands the car there anyway).
CarController.ride = nil :: ((dt: number) -> CFrame?)?
CarController.rideLand = nil :: CFrame?
CarController.rideLandSpeed = 0

-- ---------------------------------------------------------------- simulation state
local simPos: Vector3? = nil
local forward = Vector3.new(0, 0, -1) -- travel heading, unit, in the road plane
local up = Vector3.yAxis -- smoothed road normal (world up in the air)
local velocity = Vector3.zero
local slideDeg = 0 -- drift body yaw offset
local spinAngle = 0
local spinTotal = 0
local spinTimer = 0
local spinDuration = 1
local boostSpeed = 0
local hopTimer = 0
local squash = 0
local squashVel = 0
local bumpCooldown = 0
local hitStopTimer = 0
local traumaClock = 0
local appliedFovKick = 0 -- Vfx.fovKick() already added to the camera FOV (removed before smoothing)
local magnetTimer = 0
local magnetPull = 0 -- studs/s over top speed while the magnet runs (CarConfig.MAGNET_MAX_SPEED caps the sum)
local magnetTarget: Model? = nil -- magnet v2: the racer the server locked; the steering leans toward it
local itemSlowTimer = 0 -- items v4: a slow (Frost Shot, Coin Burst, patches) caps the speed at TOP_SPEED x itemSlowFactor
local itemSlowFactor = 1
local itemAutoTimer = 0 -- items v4: Rocket Rush drives the line (the AutoPilot follower) this long
local offTrackTimer = 0
local offTrackFlag = false
local routeCheckClock = 0
local reverseState = ReverseRules.newState() -- reverse v2: brake / hold / reverse intent and the car WRONG WAY clock
local wrongWayShown = false -- the route check's verdict (every 0.25 s)
local wrongWayAngle = 0 -- CourseArrow rotation: the way to turn the nose
local arrowUp = false -- this controller has the CourseArrow up (hidden on a respawn, a battle out or the car going away)
local killY = -math.huge
local killYReady = false
local lastGroundedPos: Vector3? = nil -- where the car last stood on ground above the kill height
local inShallowWater = false
local waterSurfaceY: number? = nil -- the water line while wading (GroundFx wake/spray)
local onOffroad = false
local syncAccumulator = 0
local wheelSpin = 0
local wheelOffsets = { 0, 0, 0, 0 }
local probeDistances: { number } = { math.huge, math.huge, math.huge, math.huge }

-- Tricks (REMARKABLE items 5 and 6). trickSpin/trickTarget are body-only yaw degrees rendered through the BodyMotor
-- (never spinAngle, which turns the travel heading); a spin started in the air is judged on touchdown.
local lastDriftHeld = false
local hopCooldown = 0
local hopAir = false -- this airtime began with a hop (landing dust)
local hopSurfaceFactor = 1 -- off-road / shallow-water speed factor where the hop took off (braked in the air too)
local trickSpin = 0
local trickTarget = 0
local trickActive = false -- a spin was queued this airtime
local unwindRate = 0 -- > 0 while a flubbed spin unwinds to upright
local flubTimer = 0
local gridHopTimer = 0
local gridHopCooldown = 0
local gridHopSeq = 0 -- replicated (GridHop) so other clients replay each bounce
local revThrottle = 0 -- smoothed grid rev (body shake and nose lift)
local onGrid = false
local startState = TrickRules.newStart()
local startGoTime: number? = nil -- the RaceGoTime startState belongs to
local startPending = false -- GO not yet applied for startGoTime
local floodTimer = 0
local floodPuffClock = 0
-- Style lane: the last wall touch (a scrape is never a near miss), the route line the car is on (G8: the off-track
-- check measures a lower alternate ledge against that ledge, not the main road above it) and the grid clear flag.
local lastWallTouch = -math.huge
local wallContact = Mods.SfxRules.newWallContact() -- one pinned-wall contact: wall_bump once, then wall_scrape until it ends
local branchId: string? = nil
local holdCleared = false
-- Ground wait: a race reset or spawn whose frame has no ground under it on this client yet (a cached map's terrain is
-- pasted on the server in a fraction of a second, then streams to clients for a few seconds: the hub return dropped the
-- car through the plaza to the kill height) holds the car like the grid until the ground arrives, GROUND_WAIT at most.
local groundWaitUntil = 0
local GROUND_WAIT = 8

-- Respawn and fade: "none" | "out" (falling, fading) | "wait" (asked the server) | "in" (placed, fading back)
local fadePhase = "none"
local fadeTimer = 0
local respawnTarget: CFrame? = nil
local fadeFrame: Frame? = nil
-- Where and when the last respawn set the car down: a server reply that arrives after the client already timed out
-- and used the cached checkpoint (RESPAWN_REPLY_TIMEOUT) names the same frame and must not place the car twice.
local lastRespawnCF: CFrame? = nil
local lastRespawnClock = -math.huge
local LATE_REPLY_WINDOW = 3.0
-- Why the car is respawning ("Water", "Fell", "OffTrack", "LethalLava", "Manual", "Stuck", "Server") and whether its
-- water came from the battle tide (the server drowns tide cars itself: the client waits for that answer first).
local respawnReason = "crash"
local respawnFromTide = false
local askedServer = false -- this respawn's RequestRespawn went out
-- Way out (G5): the last manual press, the stuck watchdog and the crash-loop guard (D4-02 fix 4, all maps).
local lastManualRespawn = -math.huge
local stuckWatch = RespawnRules.newWatch()
local loopGuard = RespawnRules.newLoopGuard()
-- The cached checkpoint's epoch (track, mode, reset): a frame cached under another map or race is never used as the
-- timeout fallback (the stale-HUB respawn: a client that missed every race event kept the hub frame into a battle).
local checkpointEpoch = ""
local spawnFrameConn: RBXScriptConnection? = nil
-- Battle tide (X-02): the Water mode's TideWater part (CanQuery off, attribute TideLevel), looked up now and then.
local tidePart: BasePart? = nil
local tideLookupClock = 0

-- Camera
local camForward = Vector3.new(0, 0, -1)
local camY = 0
local camReady = false
-- v38-feel state (one table: the module is at its top-level local budget): feel.camRoll eased lean into the turn (degrees),
-- feel.camSide eased drift look-ahead (-1..1), feel.camDip/feel.camDipVel the landing dip spring (studs), flicker* the post-hit /
-- post-respawn shield blink (local view only, LocalTransparencyModifier).
local feel = { camRoll = 0, camSide = 0, camDip = 0, camDipVel = 0, flickerTimer = 0, flickerOn = false, flickerParts = {} :: { BasePart } }

-- Remotes
local flightStateRemote: RemoteEvent? = nil
local raceEventRemote: RemoteEvent? = nil

-- Raycast params (filters refreshed on bind)
local groundParams = RaycastParams.new()
local wallParams = RaycastParams.new()
local waterParams = RaycastParams.new()

local ownsVfxStep = false

-- ---------------------------------------------------------------- small math helpers
local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function safeUnit(v: Vector3, fallback: Vector3): Vector3
	local m = v.Magnitude
	return if m > 1e-5 then v / m else fallback
end

local function onPlane(v: Vector3, n: Vector3): Vector3
	return v - n * v:Dot(n)
end

local function rotateAbout(v: Vector3, axis: Vector3, angle: number): Vector3
	return CFrame.fromAxisAngle(axis, angle):VectorToWorldSpace(v)
end

-- Rotation frame with LookVector = fwd (projected into the plane of upv) and UpVector = upv.
local function frame(pos: Vector3, fwd: Vector3, upv: Vector3): CFrame
	local right = safeUnit(fwd:Cross(upv), Vector3.xAxis)
	return CFrame.fromMatrix(pos, right, upv)
end

local function expAlpha(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function isLethal(inst: Instance?): boolean
	return inst ~= nil and (inst:GetAttribute("HazardType") == "LethalLava" or inst.Name == "LavaSeaFloor")
end

local function isWallNormal(n: Vector3, upv: Vector3): boolean
	return math.abs(n:Dot(upv)) < CarConfig.WALL_MAX_UP_DOT
end

-- ---------------------------------------------------------------- rigs (local car and other players' cars)
type Rig = {
	model: Model,
	hull: BasePart,
	bodyMotor: Motor6D?,
	wheelMotors: { Motor6D },
	sparks: { ParticleEmitter },
	smoke: { ParticleEmitter },
	spin: number,
	isLocal: boolean,
	vfxAdapted: boolean,
	trick: number, -- remote rigs: displayed TrickSpin (degrees, follows the replicated attribute)
	hopT: number, -- remote rigs: grid bounce time left
	hopSeq: number, -- remote rigs: last GridHop seen (-1 = none yet)
	bodyDirty: boolean, -- remote rigs: BodyMotor still carries a trick pose to clear
	sparkKey: string, -- drift effects last written (level|zone|sliding): edge-only writes
	glow: PointLight?, -- the zone turbo's road glow (third drift tier), created on first use
	bob: { number }, -- remote rigs: per-wheel suspension offset (no probes for other cars: a small speed bob instead)
}
local rigs: { [Model]: Rig } = {}
local rigScanClock = 0

local OFFROAD: { [string]: boolean } = {}
for _, m in CarConfig.OFFROAD_MATERIALS do
	OFFROAD[m] = true
end

local function texture(name: string): string
	local e = (Mods.VfxAssets :: any)[name]
	return if e then e.id else ""
end

local function makeSparkEmitter(parent: Instance): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "CarDriftSparks"
	pe.Texture = texture("spark_streak")
	pe.Rate = 0
	pe.Enabled = false
	pe.Lifetime = NumberRange.new(0.22, 0.42) -- v37: long enough to read from the chase camera (0.16-0.3 vanished)
	pe.Speed = NumberRange.new(10, 24)
	pe.SpreadAngle = Vector2.new(50, 40)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.Orientation = Enum.ParticleOrientation.VelocityParallel
	pe.Acceleration = Vector3.new(0, -45, 0)
	pe.EmissionDirection = Enum.NormalId.Front
	pe.Parent = parent
	return pe
end

local function makeSmokeEmitter(parent: Instance): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "CarDriftSmoke"
	-- dust_burst_4x4 (flip_v2): each particle plays the ground-kick sheet over its Lifetime (OneShot), kept upright and
	-- unrotated so the flattened puffs stay on the road; the old smoke_puff_4x4 stands in if the sheet id is missing.
	local flip = Mods.FlipFx.apply(pe, "dust_burst_4x4")
	pe.Rate = 0
	pe.Enabled = false
	pe.Lifetime = NumberRange.new(0.5, 0.8)
	pe.Speed = NumberRange.new(2, 5)
	pe.SpreadAngle = Vector2.new(25, 25)
	pe.Size = if flip
		then NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.8), NumberSequenceKeypoint.new(1, 3) })
		else NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 3.4) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0.8) })
	pe.Color = ColorSequence.new(rgb(CarConfig.DRIFT_SMOKE_COLOR))
	pe.Orientation = if flip then Enum.ParticleOrientation.FacingCameraWorldUp else Enum.ParticleOrientation.FacingCamera
	pe.Rotation = if flip then NumberRange.new(0) else NumberRange.new(0, 360)
	pe.Drag = 2
	pe.EmissionDirection = Enum.NormalId.Front
	pe.Parent = parent
	return pe
end

local function attachRig(model: Model, isLocal: boolean): Rig?
	local existing = rigs[model]
	if existing then
		return existing
	end
	local hull = model:FindFirstChild("Hull")
	if not hull or not hull:IsA("BasePart") then
		return nil
	end
	local wheelMotors: { Motor6D } = {}
	for i, name in CarConfig.WHEEL_NAMES do
		local m = hull:FindFirstChild(name .. "Motor")
		if m and m:IsA("Motor6D") then
			wheelMotors[i] = m
		end
	end
	local bodyMotor = hull:FindFirstChild("BodyMotor")
	local sparks: { ParticleEmitter } = {}
	local smoke: { ParticleEmitter } = {}
	for _, attName in { "DriftSparkL", "DriftSparkR" } do
		local att = hull:FindFirstChild(attName)
		if att and att:IsA("Attachment") then
			table.insert(sparks, makeSparkEmitter(att))
			table.insert(smoke, makeSmokeEmitter(att))
		end
	end
	local rig: Rig = {
		model = model,
		hull = hull,
		bodyMotor = if bodyMotor and bodyMotor:IsA("Motor6D") then bodyMotor else nil,
		wheelMotors = wheelMotors,
		sparks = sparks,
		smoke = smoke,
		spin = 0,
		isLocal = isLocal,
		vfxAdapted = false,
		trick = 0,
		hopT = 0,
		hopSeq = -1,
		bodyDirty = false,
		sparkKey = "",
		glow = nil,
		bob = { 0, 0, 0, 0 },
	}
	rigs[model] = rig
	return rig
end

-- Vfx attaches its plane rig to every Hull in workspace.Planes, cars included. Its wing-vapor trails sit at +-7.6
-- (a plane's wingtips), which on a 6.3-wide car would float beside it whenever it drifts or boosts. Vfx only toggles
-- Enabled after creating them, so re-seating their attachments at the rear tyres turns them into tyre streaks.
-- Runs until the rig shows up (Vfx creates it lazily on its own step).
local function adaptVfxRig(rig: Rig)
	if rig.vfxAdapted then
		return
	end
	for _, d in rig.hull:GetChildren() do
		if d:IsA("Trail") and d.Name == "VfxVapor" and d.Attachment0 and d.Attachment1 then
			local a0 = d.Attachment0 :: Attachment
			local a1 = d.Attachment1 :: Attachment
			local side = if a0.Position.X < 0 then -1 else 1
			local w = CarConfig.WHEELS[if side < 0 then 3 else 4]
			local y = w[2] - CarConfig.WHEEL_RADIUS + 0.1
			-- v29 W1b A6: 40 % narrower (was +-0.45), unlit and mostly see-through (Vfx shows it only while drifting or boosting)
			a0.Position = Vector3.new(w[1] - 0.27, y, w[3] + 0.4)
			a1.Position = Vector3.new(w[1] + 0.27, y, w[3] + 0.4)
			d.Color = ColorSequence.new(Color3.fromRGB(70, 60, 58))
			d.LightEmission = 0
			d.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.75), NumberSequenceKeypoint.new(0.6, 0.9), NumberSequenceKeypoint.new(1, 1) })
			rig.vfxAdapted = true
		end
	end
end

-- Drift effect state: smoke while sliding uncharged, sparks in the level colour once a mini-turbo is charged. The
-- third tier (the ZONE TURBO, REMARKABLE item 15) throws bigger sparks in the zone's own colour and lights the road
-- under the car. Written only when the level, zone or sliding state changes (this runs every frame for every car).
local sparkColors: { [string]: ColorSequence } = {}
local SPARK_SIZE = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 0) })
local SPARK_SIZE_ZONE = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.7), NumberSequenceKeypoint.new(1, 0) })
local SPARK_SIZE_T2 = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.7), NumberSequenceKeypoint.new(1, 0) }) -- v37: 1.2 was a few flecks
local SPARK_SIZE_T1 = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.9), NumberSequenceKeypoint.new(1, 0) }) -- v21: 1.3 was faint on bright sand
local function setDriftEffects(rig: Rig, drifting: boolean, level: number, grounded: boolean)
	local sliding = drifting and grounded
	local zone = RaceAttr.mine("ActiveZone")
	local z = if type(zone) == "string" then zone else ""
	local pscale = Mods.Settings.particleScale() -- phone budget: every rate below scales with it
	local key = if sliding then level .. "|" .. z .. "|" .. pscale else "off"
	if key == rig.sparkKey then
		return
	end
	rig.sparkKey = key
	local lv = if level > 0 then CarConfig.DRIFT_LEVELS[level] else nil
	local top = lv ~= nil and level >= 3
	for _, pe in rig.smoke do
		pe.Enabled = sliding and pscale > 0
		pe.Rate = (if sliding and not lv then 26 elseif sliding then 8 else 0) * pscale
	end
	local colorKey = level .. "|" .. z
	local seq = sparkColors[colorKey]
	if lv and not seq then
		-- Tier 1 sparks use the deeper effect blue (GroundFxRules.TIER1_FX_RGB): the HUD sky blue vanished on sand.
		local c = if level == 1 then rgb(Mods.GroundFxRules.TIER1_FX_RGB :: any) else rgb(CarConfig.driftColor(level, z))
		seq = ColorSequence.new(Color3.new(1, 1, 1):Lerp(c, if level == 1 then 0.94 else 0.85), c)
		sparkColors[colorKey] = seq
	end
	for _, pe in rig.sparks do
		pe.Enabled = sliding and lv ~= nil and pscale > 0
		if lv and seq then
			-- Other cars (bots, rivals) throw GroundFxRules.REMOTE_SPARK_FRAC of the local rate: the top tier is 170/s per emitter.
			-- v37: tiers 1-2 were flecks next to the top tier (Studio captures sp4d_*): denser, and each tier a clear step up.
			pe.Rate = Mods.GroundFxRules.sparkRate(if top then 170 elseif level == 2 then 140 else 110, pscale, rig.isLocal)
			pe.Color = seq
			pe.LightEmission = if level == 1 then 0.55 else 1 -- additive blue vanishes on bright sand, 0.3 vanished on dark road
			pe.Size = if top then SPARK_SIZE_ZONE elseif level == 2 then SPARK_SIZE_T2 else SPARK_SIZE_T1
			pe.Speed = if top then NumberRange.new(22, 46) elseif level == 2 then NumberRange.new(16, 34) else NumberRange.new(12, 26)
		else
			pe.Rate = 0
		end
	end
	-- Zone turbo road glow: one PointLight per car, only switched.
	if top and sliding and rig.isLocal and not rig.glow then -- v21: local car only (bots lit the road green-white), softer: it washed the sand and the rear wheel out
		local l = Instance.new("PointLight")
		l.Name = "ZoneTurboGlow"
		l.Brightness = 1.6
		l.Range = 11
		l.Shadows = false
		l.Parent = rig.hull
		rig.glow = l
	end
	local glow = rig.glow
	if glow then
		glow.Enabled = top and sliding
		if top then
			glow.Color = rgb(CarConfig.driftColor(level, z))
		end
	end
	-- Charge tiers beyond the sparks: inner glow ember at the rear tyres, electric arcs on the top tier (GroundFx).
	Mods.GroundFx.setCharge(rig.hull, rig.isLocal, if lv then level else 0, sliding, rgb(CarConfig.driftColor(level, z)))
end

local function setWheels(rig: Rig, spin: number, steerDeg: number, offsets: { number }?)
	for i, m in rig.wheelMotors do
		local yaw = if i <= 2 then math.rad(-steerDeg) else 0
		local dy = if offsets then offsets[i] else 0
		m.Transform = CFrame.new(0, dy, 0) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(spin, 0, 0)
	end
end

-- Other players' cars: wheels and drift effects from the attributes CarServer replicates (Speed, Steer, DriftLevel).
local function stepRemoteRigs(dt: number)
	rigScanClock -= dt
	if rigScanClock <= 0 then
		rigScanClock = 0.5
		local folder = workspace:FindFirstChild("Planes")
		if folder then
			for _, m in folder:GetChildren() do
				if m:IsA("Model") and m:GetAttribute("VehicleType") == "car" and m ~= CarController.car and not rigs[m] then
					attachRig(m, false)
				end
			end
		end
		for _, rig in rigs do
			adaptVfxRig(rig)
		end
	end
	for model, rig in rigs do
		if not model.Parent then
			rigs[model] = nil
		elseif not rig.isLocal then
			local s = model:GetAttribute("Speed")
			local st = model:GetAttribute("Steer")
			local lvl = model:GetAttribute("DriftLevel")
			local speed = if type(s) == "number" then s else 0
			rig.spin -= speed / CarConfig.WHEEL_RADIUS * dt
			-- Suspension: other cars have no wheel probes here, so the wheels ride a small speed-scaled bob (each wheel
			-- out of phase) and hang down in the air, the way the local car's probed wheels do.
			local airborne = model:GetAttribute("Airborne") == true
			local speedFrac = math.clamp(math.abs(speed) / CarConfig.TOP_SPEED, 0, 1)
			local now = os.clock()
			for i = 1, 4 do
				local target = if airborne
					then -CarConfig.SUSPENSION_TRAVEL * 0.6
					else math.sin(now * 13 + i * 1.9) * CarConfig.SUSPENSION_TRAVEL * 0.18 * speedFrac
				rig.bob[i] += (target - rig.bob[i]) * expAlpha(20, dt)
			end
			setWheels(rig, rig.spin, (if type(st) == "number" then st else 0) * CarConfig.WHEEL_STEER_VISUAL_DEG, rig.bob)
			setDriftEffects(rig, model:GetAttribute("Drifting") == true, if type(lvl) == "number" then lvl else 0, model:GetAttribute("Airborne") ~= true)
			-- Trick spin and grid bounce (CarServer replicates TrickSpin, wrapped to +-180 in 15-degree steps, and the
			-- GridHop bounce counter): follow the spin the short way round, replay each new bounce with a boing.
			local ts = model:GetAttribute("TrickSpin")
			local gh = model:GetAttribute("GridHop")
			if type(gh) == "number" and gh ~= rig.hopSeq then
				if rig.hopSeq >= 0 then
					rig.hopT = TrickRules.GRID_HOP_TIME
					TrickJuice.play3D("hop_boing", rig.hull, 0.35)
				end
				rig.hopSeq = gh
			end
			local target = if type(ts) == "number" then ts else 0
			rig.trick = TrickRules.wrap180(rig.trick + TrickRules.wrap180(target - rig.trick) * expAlpha(22, dt))
			rig.hopT = math.max(0, rig.hopT - dt)
			local motor = rig.bodyMotor
			if motor and (rig.hopT > 0 or math.abs(rig.trick) > 0.5 or rig.bodyDirty) then
				local t = 1 - rig.hopT / TrickRules.GRID_HOP_TIME
				local lift = if rig.hopT > 0 then math.sin(t * math.pi) * TrickRules.GRID_HOP_HEIGHT else 0
				motor.Transform = CFrame.new(0, lift, 0) * CFrame.Angles(math.rad(lift * 4), math.rad(-rig.trick), 0)
				rig.bodyDirty = rig.hopT > 0 or math.abs(rig.trick) > 0.5
			end
		end
	end
end

-- ---------------------------------------------------------------- wall impact sparks
-- Wall sparks go through GroundFx's pooled, particleScale-d spray (the old per-module emitter is gone).
local function impactSparks(pos: Vector3, normal: Vector3, count: number)
	Mods.GroundFx.sparkSpray(pos, normal, count, "wall")
end

-- ---------------------------------------------------------------- fade overlay
local function ensureFade(): Frame
	if fadeFrame and fadeFrame.Parent then
		return fadeFrame
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyCarFade"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 4 -- under the speed lines (5) and the controls hint (40)
	local f = Instance.new("Frame")
	f.Name = "Fade"
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.fromRGB(24, 16, 14)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = sg
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	fadeFrame = f
	return f
end

local function setFadeAlpha(alpha: number)
	local f = ensureFade()
	f.BackgroundTransparency = 1 - math.clamp(alpha, 0, 1) * CarConfig.FADE_MAX_ALPHA
end

-- ---------------------------------------------------------------- feedback
function CarController.addTrauma(amount: number)
	CarController.cameraTrauma = math.clamp(CarController.cameraTrauma + amount, 0, 1)
end

local function hullCF(): CFrame
	local h = CarController.hull
	return if h then h.CFrame else CFrame.new(simPos or Vector3.zero)
end

-- kind: "Pad" | "MiniTurbo" | "Item" | "Pod"; state is the Vfx/SoundJuice family ("Standard" or "Overcharge").
-- kick: the share of `speed` the car jumps to at once (default 0.85); mini-turbo tiers step it up (CarConfig.DRIFT_KICK).
function CarController.triggerBoost(kind: string, speed: number, duration: number, state: string, kick: number?)
	if floodTimer > 0 and not string.find(kind, "^Item") then
		return -- v37: a stalled (burnt) start takes no pad / ring boost until the engine catches (SPACE-4's grid rings)
	end
	if CarController.boostState ~= "Overcharge" or state == "Overcharge" then
		CarController.boostState = state
	end
	CarController.boostTimer = math.max(CarController.boostTimer, duration)
	boostSpeed = math.max(if CarController.boostTimer > duration then boostSpeed else 0, speed)
	local k = kick or 0.85
	if CarController.speed < speed * k and CarController.grounded then
		CarController.speed = math.max(CarController.speed, speed * k) -- the kick: boosts must be felt at once
	end
	LocalPlayer:SetAttribute("BoostState", CarController.boostState)
	LocalPlayer:SetAttribute("LastBoostKind", kind)
	if kind ~= "MiniTurbo" then -- a mini-turbo has its own tier-coloured release (GroundFx.release, from endDrift)
		Vfx.onBoost(hullCF(), state == "Overcharge")
	end
	CarController.addTrauma(if state == "Overcharge" then 0.3 else 0.2)
	hitStopTimer = math.max(hitStopTimer, if state == "Overcharge" then 0.04 else 0.025)
	SoundJuice.triggerFeedback("medium", if state == "Overcharge" then "Overcharge" else "Boost")
end

-- v38-feel: the rising drift charge (MK8's sparks building): the rocket-start charge whine, quiet, restarted a step
-- higher at every tier so the pitch climbs with the charge; it is 1.5 s long, so a held top tier falls silent (no drone).
function feel.chargeVoice(level: number)
	Mods.Sfx37.stop("rs_charge")
	Mods.Sfx37.play("rs_charge", 0.12 + 0.04 * level, 0.8 + 0.155 * level)
end

local function endDrift(release: boolean)
	if not CarController.drifting then
		return
	end
	Mods.Sfx37.stop("rs_charge")
	local level = CarConfig.driftLevel(CarController.driftCharge)
	CarController.drifting = false
	CarController.driftDir = 0
	CarController.driftCharge = 0
	CarController.driftLevel = 0
	if release and level > 0 then
		local lv = CarConfig.DRIFT_LEVELS[level]
		CarController.triggerBoost("MiniTurbo", lv.boostSpeed, lv.boostDuration, lv.boostState, CarConfig.DRIFT_KICK[level])
		Vfx.boostPunch(level >= 2) -- v37: every tier gets the ignite FOV punch (the top two the big one); GroundFx draws the burst
		LocalPlayer:SetAttribute("LastMiniTurbo", lv.name)
		if CarController.hull then
			Mods.GroundFx.release(CarController.hull, level, rgb(CarConfig.driftColor(level, RaceAttr.mine("ActiveZone") :: string?)))
		end
		Mods.StyleChain.event("Drift" .. level) -- REMARKABLE 17
		if level >= 3 then
			-- REMARKABLE 15: the zone turbo goes off in the zone's colour behind the car.
			local cf = hullCF()
			local tail = cf:PointToWorldSpace(Vector3.new(0, 0.4, CarConfig.HALF_LENGTH))
			Mods.StyleSense.zoneBurst(CFrame.lookAt(tail, tail - cf.LookVector), RaceAttr.mine("ActiveZone") :: string?, 1.2)
			CarController.addTrauma(0.12)
		end
	end
end

local function cancelBoost()
	CarController.boostTimer = 0
	CarController.boostState = "None"
	boostSpeed = 0
	LocalPlayer:SetAttribute("BoostState", "None")
end

local function noteCrash(reason: string, pos: Vector3)
	LocalPlayer:SetAttribute("LastCrashReason", reason)
	LocalPlayer:SetAttribute("LastCrashPos", pos)
	LocalPlayer:SetAttribute("CrashCount", ((LocalPlayer:GetAttribute("CrashCount") :: number?) or 0) + 1)
end

-- force: an item hit the server scored (ItemClient already dropped the stale ones, RespawnRules.clientIgnoresHit), so
-- the client's own respawn invulnerability (walls, lava, water) does not hide it.
function CarController.spinOut(reason: string, seconds: number?, pos: Vector3?, normal: Vector3?, force: boolean?)
	if CarController.spinning or (CarController.invulnTimer > 0 and not force) or CarController.respawning then
		return
	end
	endDrift(false)
	cancelBoost()
	trickActive, trickSpin, trickTarget, unwindRate = false, 0, 0, 0
	CarController.spinning = true
	spinDuration = seconds or CarConfig.SPIN_DURATION
	spinTimer = spinDuration
	spinAngle = 0
	spinTotal = CarConfig.SPIN_TURNS * 360 * (if math.random() < 0.5 then -1 else 1)
	CarController.speed *= CarConfig.SPIN_SPEED_KEEP
	Mods.StyleChain.breakChain(reason) -- REMARKABLE 17
	local at = pos or simPos or Vector3.zero
	noteCrash(reason, at)
	LocalPlayer:SetAttribute("SpinningOut", true)
	LocalPlayer:SetAttribute("ItemStunned", reason == "ItemHit") -- same flag FlightController sets for a plane
	Vfx.onCrash(at, reason, normal or Vector3.yAxis)
	CarController.addTrauma(0.55)
	hitStopTimer = math.max(hitStopTimer, 0.06)
	-- REMARKABLE item 14: an item hit sounds as ItemClient's comic BONK (it falls back to this thud until the cue is
	-- uploaded), so only the other spin-outs play the crash thud here.
	if reason ~= "ItemHit" then
		SoundJuice.triggerFeedback("large", "Crash")
	end
end

-- ---------------------------------------------------------------- respawn frame cache and the battle tide
local function currentEpoch(): string
	return string.format("%s|%s|%s", tostring(RaceAttr.mine("ActiveTrackId")), tostring(RaceAttr.mine("RaceMode")), tostring(RaceAttr.mine("RaceResetSeq")))
end

-- Every write of the cached checkpoint goes through here so it carries the epoch it belongs to.
local function setCheckpoint(cf: CFrame)
	CarController.lastCheckpointCF = cf
	checkpointEpoch = currentEpoch()
end

-- The frame a respawn falls back to when the server's answer is late: the cached checkpoint while it belongs to this
-- map and race, else the car's own SpawnCFrame (CarServer sets it on every spawn and reset; it replicates with the
-- model, so it is right even for a client that missed the race events).
local function fallbackTarget(): CFrame
	if checkpointEpoch == currentEpoch() then
		return CarController.lastCheckpointCF
	end
	local car = CarController.car
	local spawnCF = if car then car:GetAttribute("SpawnCFrame") else nil
	if typeof(spawnCF) == "CFrame" then
		print("[SkyRally][CAR] cached checkpoint is from another map or race: falling back to the spawn frame")
		return spawnCF
	end
	return CarController.lastCheckpointCF
end

-- The battle tide over `pos` (trap audit X-02), or nil: the server's workspace TideLevel when it publishes one (limited
-- to the arena), else the Water mode's TideWater part (its TideLevel attribute, limited to its disk). Battles only.
local function tideLevelAt(pos: Vector3): number?
	if RaceAttr.mine("RaceMode") ~= "battle" then
		tidePart = nil
		return nil
	end
	local published = workspace:GetAttribute("TideLevel")
	if type(published) == "number" then
		return RespawnRules.tideAt(pos, published, workspace:GetAttribute("BattleCenter"), workspace:GetAttribute("BattleReturnRadius"))
	end
	local part = tidePart
	if not part or not part.Parent then
		tidePart = nil
		local now = os.clock()
		if now - tideLookupClock < 1 then
			return nil
		end
		tideLookupClock = now
		local root = Mods.TrackRegistry.getRoot()
		local overlay = if root then root:FindFirstChild("BattleOverlay") else nil
		local found = if overlay then overlay:FindFirstChild("TideWater", true) else nil
		if not found or not found:IsA("BasePart") then
			return nil
		end
		tidePart = found
		part = found
	end
	local p = part :: BasePart
	-- The part is a flat cylinder (axis X): its disk radius is half its Y/Z size.
	return RespawnRules.tideAt(pos, p:GetAttribute("TideLevel"), p.Position, p.Size.Y / 2)
end

-- ---------------------------------------------------------------- placement and respawn
local function writeHull(cf: CFrame, vel: Vector3)
	local hull = CarController.hull
	if not hull then
		return
	end
	hull.CFrame = cf
	hull.AssemblyLinearVelocity = vel
	hull.AssemblyAngularVelocity = Vector3.zero
	local lv = hull:FindFirstChild("DriveVelocity")
	if lv and lv:IsA("LinearVelocity") then
		lv.VectorVelocity = vel
	end
	local ao = hull:FindFirstChild("DriveOrientation")
	if ao and ao:IsA("AlignOrientation") then
		ao.CFrame = cf
	end
end

-- Sets the car down on the road under a frame (respawn, reset, correction): ray down from the frame (RaceManager's
-- respawn frames sit 12 studs over the route), sit on the hit, face the frame's heading along the road.
local function placeAt(cf: CFrame, startSpeed: number, dropToGround: boolean)
	local fwd = safeUnit(flat(cf.LookVector), Vector3.new(0, 0, -1))
	local pos = cf.Position
	local n = Vector3.yAxis
	local landed = false
	if dropToGround then
		-- 30 studs reaches the deck under any respawn frame but never a pool floor under a deck gap (the ground
		-- params ignore water), which would set the car down underwater and drown it again at once.
		local hit = workspace:Raycast(cf.Position, Vector3.new(0, -30, 0), groundParams)
		if hit and not isWallNormal(hit.Normal, Vector3.yAxis) then
			n = hit.Normal
			pos = hit.Position + n * CarConfig.RIDE_HEIGHT
			landed = true
		end
	end
	simPos = pos
	up = n
	forward = safeUnit(onPlane(fwd, n), fwd)
	CarController.speed = startSpeed
	velocity = forward * startSpeed
	CarController.grounded = landed
	CarController.airTime = 0
	CarController.spinning = false
	LocalPlayer:SetAttribute("SpinningOut", false)
	LocalPlayer:SetAttribute("ItemStunned", false)
	spinAngle = 0
	slideDeg = 0
	squash, squashVel = 0, 0
	offTrackTimer = 0
	trickActive, trickSpin, trickTarget, unwindRate, flubTimer, hopAir = false, 0, 0, 0, 0, false
	floodTimer = 0
	endDrift(false)
	writeHull(frame(pos, forward, up), velocity)
	camReady = false
end

local function resetRaceState(startCF: CFrame)
	CarController.speedPickups = 0
	LocalPlayer:SetAttribute("SpeedPickups", 0)
	cancelBoost()
	CarController.invulnTimer = 1.0
	CarController.cameraTrauma = 0
	CarController.respawning = false
	fadePhase = "none"
	setFadeAlpha(0)
	LocalPlayer:SetAttribute("Crashing", false)
	setCheckpoint(startCF)
	killYReady = false
	RespawnRules.resetWatch(stuckWatch)
	CarController.stuckOffer = false
	loopGuard = RespawnRules.newLoopGuard()
	placeAt(startCF, 0, true)
	groundWaitUntil = if CarController.grounded then 0 else os.clock() + GROUND_WAIT
end

-- force: a rescue the player asked for ("Manual", "Stuck") runs through the respawn protection, which only shields
-- against crashes. fromTide: the water is the battle tide (the server drowns that car itself and names the pad).
-- serverCF: the server already ordered this respawn (its CheckpointRespawn came first): play the fade-out and the
-- reason effect, then set down there without asking again.
function CarController.beginRespawn(reason: string, normal: Vector3?, force: boolean?, fromTide: boolean?, serverCF: CFrame?)
	if CarController.respawning or (CarController.invulnTimer > 0 and not force and not serverCF) then
		return
	end
	-- Out of a battle (X-03): the car stays where it went out; only a frame the server orders still moves it.
	if not serverCF and LocalPlayer:GetAttribute("BattleOut") == true then
		return
	end
	local at = simPos or Vector3.zero
	print(string.format("[SkyRally][CAR] client respawn reason=%s at=(%.0f,%.0f,%.0f) killY=%.1f%s%s", reason, at.X, at.Y, at.Z, killY, if fromTide then " tide" else "", if serverCF then " server" else ""))
	CarController.respawning = true
	endDrift(false)
	cancelBoost()
	magnetTimer, magnetPull, magnetTarget = 0, 0, nil
	itemSlowTimer, itemSlowFactor, itemAutoTimer = 0, 1, 0
	Mods.StyleChain.breakChain(reason) -- REMARKABLE 17
	Mods.StyleSense.stop()
	CarController.spinning = false
	fadePhase = "out"
	fadeTimer = 0
	respawnTarget = serverCF
	respawnReason = reason
	respawnFromTide = fromTide == true
	askedServer = serverCF ~= nil
	RespawnRules.resetWatch(stuckWatch)
	CarController.stuckOffer = false
	LocalPlayer:SetAttribute("Crashing", true)
	if reason == "Manual" or reason == "Stuck" or reason == "Server" then
		-- A rescue (or a boundary return): a poof and a whoosh, not a crash.
		LocalPlayer:SetAttribute("LastCrashReason", reason)
		LocalPlayer:SetAttribute("LastCrashPos", at)
		Vfx.onRespawn(hullCF())
		TrickJuice.play("trick_whoosh", 0.9)
		CarController.addTrauma(0.12)
		return
	end
	noteCrash(reason, at)
	if reason == "Water" then
		Vfx.onSplash(at)
		Mods.Sfx.play("splash_big", 1, 0.81) -- the splash stands in for the crash thud
	else
		Vfx.onCrash(at, reason, normal or Vector3.yAxis)
	end
	CarController.addTrauma(0.45)
	if reason ~= "Water" then
		SoundJuice.triggerFeedback("large", "Crash")
	end
end

local function completeRespawn()
	local target = respawnTarget or fallbackTarget()
	respawnTarget = nil
	lastRespawnCF = target
	lastRespawnClock = os.clock()
	CarController.lastRespawnAt = lastRespawnClock
	placeAt(target, CarConfig.RESPAWN_SPEED, true)
	CarController.invulnTimer = CarConfig.RESPAWN_INVULN
	feel.flickerTimer = CarConfig.RESPAWN_INVULN
	CarController.respawning = false
	LocalPlayer:SetAttribute("Crashing", false)
	fadePhase = "in"
	fadeTimer = 0
	RespawnRules.resetWatch(stuckWatch)
	-- Reverse v2: a respawn lands facing the course, so a WRONG WAY verdict from before it never flashes (and beeps) when
	-- the respawn shield ends, before the next route check (that check is frozen while invulnerable).
	reverseState.awayT = 0
	wrongWayShown = false
	CarController.stuckOffer = false
	Vfx.onRespawn(hullCF())
	Mods.Sfx.play("respawn_pop", 1, 0.58)
	-- Crash-loop guard (D4-02 fix 4, all maps): a crash at the same spot as the last one inside the window means the
	-- frame keeps feeding this player into the same trap; the respawn gets a longer shield and a RESCUE! callout.
	if respawnReason ~= "Manual" and respawnReason ~= "Stuck" and respawnReason ~= "Server" then
		local crashPos = LocalPlayer:GetAttribute("LastCrashPos")
		if typeof(crashPos) == "Vector3" and RespawnRules.noteCrash(loopGuard, crashPos, os.clock()) then
			CarController.invulnTimer = math.max(CarController.invulnTimer, RespawnRules.LOOP_INVULN)
			Vfx.burst("trickLand", hullCF(), 1.2)
			TrickJuice.callout("RESCUE", TrickJuice.GOLD, 1.2)
			LocalPlayer:SetAttribute("RescueGlides", ((LocalPlayer:GetAttribute("RescueGlides") :: number?) or 0) + 1)
			print("[SkyRally][CAR] rescue (repeat crash)")
		end
	end
end

local function stepFade(dt: number)
	if fadePhase == "none" then
		return
	end
	fadeTimer += dt
	if fadePhase == "out" then
		setFadeAlpha(fadeTimer / CarConfig.FADE_OUT)
		if fadeTimer >= CarConfig.FADE_OUT then
			fadePhase = "wait"
			fadeTimer = 0
		end
	elseif fadePhase == "wait" then
		setFadeAlpha(1)
		-- Ask the server for the frame unless it already named one (its own CheckpointRespawn came during the fade).
		-- A tide drown waits TIDE_SERVER_WAIT first: the server drowns tide cars itself and its answer names the dry
		-- pad; asking at once could be answered with the old pad and then moved again (two teleports for one drown).
		local askAt = if respawnFromTide then RespawnRules.TIDE_SERVER_WAIT else 0
		if not askedServer and not respawnTarget and fadeTimer >= askAt then
			askedServer = true
			fadeTimer = 0
			if flightStateRemote then
				flightStateRemote:FireServer("RequestRespawn", { reason = respawnReason })
			end
		end
		if not respawnTarget and LocalPlayer:GetAttribute("BattleOut") == true then
			-- Out of the battle while the fade ran (X-03: the tide took the last life during the TIDE_SERVER_WAIT, or
			-- the server refused the request): the server will not answer, and the timeout below would put the
			-- spectator back on its cached pad. Stay where the car went out.
			print("[SkyRally][CAR] respawn cancelled: out of the battle")
			respawnTarget = nil
			CarController.respawning = false
			LocalPlayer:SetAttribute("Crashing", false)
			fadePhase = "in"
			fadeTimer = 0
		elseif respawnTarget or (askedServer and fadeTimer >= CarConfig.RESPAWN_REPLY_TIMEOUT) then
			completeRespawn()
		end
	elseif fadePhase == "in" then
		setFadeAlpha(1 - fadeTimer / CarConfig.FADE_IN)
		if fadeTimer >= CarConfig.FADE_IN then
			fadePhase = "none"
			setFadeAlpha(0)
		end
	end
end

-- ---------------------------------------------------------------- way out (trap audit G5)
-- Same rule as the plane: a vehicle in play (not out of a battle, not on the grid or under the map-switch curtain).
function CarController.rescueAllowed(): boolean
	return FlightController.rescueAllowed()
end

-- Manual respawn for the car. source: "button" | "key" | "pad" | "Stuck" (the watchdog). The frame is the server's
-- (CarServer RequestRespawn: the last checkpoint, the battle seat, or in the hub the nearest anchor); the request
-- carries the reason so the server can hold it to its own floor. Returns true when it started.
function CarController.requestManualRespawn(source: string?): boolean
	if not CarController.car or CarController.respawning or fadePhase ~= "none" then
		return false
	end
	local now = os.clock()
	if not CarController.rescueAllowed() or not RespawnRules.canManual(lastManualRespawn, lastRespawnClock, now) then
		return false
	end
	lastManualRespawn = now
	CarController.beginRespawn(if source == "Stuck" then "Stuck" else "Manual", nil, true)
	print(string.format("[SkyRally][CAR] manual respawn source=%s", tostring(source)))
	return true
end

-- HUD state of the RESPAWN button: (shown, cooldown fraction left 0..1, the stuck watchdog offers it).
function CarController.respawnStatus(): (boolean, number, boolean)
	if not CarController.car or LocalPlayer:GetAttribute("BattleOut") == true or workspace:GetAttribute("TrackSwitching") == true then
		return false, 0, false
	end
	local now = os.clock()
	local left = math.max(RespawnRules.cooldownLeft(lastManualRespawn, now), RespawnRules.AFTER_RESPAWN_GAP - (now - lastRespawnClock))
	local frac = if CarController.respawning or fadePhase ~= "none" then 1 else math.clamp(left / RespawnRules.MANUAL_COOLDOWN, 0, 1)
	return true, frac, CarController.stuckOffer
end

-- ---------------------------------------------------------------- tricks (REMARKABLE items 5 and 6)
local function exhaustCF(): CFrame
	local cf = hullCF()
	local p = cf:PointToWorldSpace(Vector3.new(0, 0.2, CarConfig.HALF_LENGTH + 0.4))
	return CFrame.lookAt(p, p + cf.LookVector * -1 + Vector3.yAxis * 0.35)
end

local function groundCF(pos: Vector3): CFrame
	local base = pos - up * CarConfig.RIDE_HEIGHT
	return CFrame.lookAt(base, base + up)
end

-- Drift press while grounded with the stick centred: pop up (the airborne branch does the rest, no new physics).
local function tryHop(pos: Vector3, steerIn: number): boolean
	if CarController.respawning or not TrickRules.canHop(CarController.grounded, CarController.drifting, CarController.spinning, steerIn, CarController.speed, hopCooldown) then
		return false
	end
	velocity += up * TrickRules.HOP_VY
	CarController.grounded = false -- next probe pass resolves airborne (rising faster than LAND_MAX_UP_SPEED)
	CarController.airTime = 0
	hopCooldown = TrickRules.HOP_COOLDOWN
	hopAir = true
	hopSurfaceFactor = (if onOffroad then CarConfig.OFFROAD_SPEED_FACTOR else 1) * (if inShallowWater then CarConfig.WATER_SPEED_FACTOR else 1)
	trickActive, trickSpin, trickTarget, unwindRate = false, 0, 0, 0
	squash = math.min(squash, -0.35) -- body stretches up off the springs
	squashVel = 0
	LocalPlayer:SetAttribute("LastJumpClock", os.clock())
	LocalPlayer:SetAttribute("HopCount", ((LocalPlayer:GetAttribute("HopCount") :: number?) or 0) + 1)
	Vfx.burst("hopDust", groundCF(pos), 0.8)
	TrickJuice.play("hop_boing")
	return true
end

-- Drift press in the air with steer: queue a turn of body spin.
local function trySpin(steerIn: number)
	if CarController.spinning or CarController.respawning then
		return
	end
	local t = TrickRules.queueSpin(trickTarget, steerIn)
	if t ~= trickTarget then
		trickTarget = t
		trickActive = true
		unwindRate = 0
		TrickJuice.play("trick_whoosh", 1 + 0.08 * (math.abs(t) / 360 - 1))
	end
end

-- Touchdown verdict for a spin queued this airtime (air = seconds airborne, read before airTime is reset).
local function landTrick(pos: Vector3, air: number)
	if hopAir then
		hopAir = false
		hopSurfaceFactor = 1
		Vfx.burst("hopDust", groundCF(pos), 0.6)
	end
	if not trickActive then
		return
	end
	trickActive = false
	if math.abs(trickTarget) < 360 and math.abs(TrickRules.wrap180(trickSpin)) <= TrickRules.LAND_TOLERANCE_DEG then
		trickSpin, trickTarget = 0, 0 -- a spin cancelled by an opposite tap: nothing to judge
		return
	end
	if math.abs(trickTarget) >= 360 and TrickRules.trickLanded(trickTarget, trickSpin) then
		-- STUCK IT: the last few degrees whip round on the wheels (unwindRate finishes them in ~0.07 s).
		unwindRate = math.max(TrickRules.SPIN_DEG_PER_S, math.abs(trickTarget - trickSpin) / 0.07)
		local turns = math.floor(math.abs(trickTarget) / 360 + 0.5)
		Vfx.burst("trickLand", groundCF(pos), if turns >= 2 then 1.6 else 1)
		TrickJuice.play("trick_stuck", if turns >= 2 then 1.12 else 1)
		TrickJuice.callout(if turns >= 2 then "DOUBLE STUCK IT" else "STUCK IT", TrickJuice.GOLD, 1.1)
		squash = math.max(squash, 0.5)
		CarController.addTrauma(0.12)
		LocalPlayer:SetAttribute("LastTrick", if turns >= 2 then "StuckDouble" else "Stuck")
		LocalPlayer:SetAttribute("TrickStuckCount", ((LocalPlayer:GetAttribute("TrickStuckCount") :: number?) or 0) + 1)
		Mods.StyleChain.event(if turns >= 2 then "StuckDouble" else "Stuck") -- REMARKABLE 17
		if TrickRules.trickBoostEligible(air) then
			local tier = CarConfig.DRIFT_LEVELS[1]
			CarController.triggerBoost("Trick", tier.boostSpeed, TrickRules.BOOST_TIME, "Standard")
		end
	else
		-- Flub: wobble, cough smoke, lose a little speed, unwind to the nearest upright over FLUB_UNWIND_TIME.
		CarController.speed *= TrickRules.FLUB_SPEED_KEEP
		trickTarget = math.floor(trickSpin / 360 + 0.5) * 360
		unwindRate = math.max(180, math.abs(trickTarget - trickSpin) / TrickRules.FLUB_UNWIND_TIME)
		flubTimer = TrickRules.FLUB_WOBBLE_TIME
		squash = math.max(squash, 0.8)
		Vfx.burst("floodPuff", groundCF(pos) * CFrame.new(0, 0, -1), 0.6)
		Vfx.burst("hopDust", groundCF(pos), 1)
		TrickJuice.play("trick_flub")
		CarController.addTrauma(0.2)
		LocalPlayer:SetAttribute("LastTrick", "Flub")
		Mods.StyleChain.breakChain("Flub") -- REMARKABLE 17: a flubbed landing drops the chain (with the bwomp)
	end
end

-- Body spin follows its target every frame (air, ground and grid); a finished spin folds back to 0 (360 = upright).
local function stepTrickSpin(dt: number)
	if trickSpin ~= trickTarget then
		local rate = if unwindRate > 0 then unwindRate else TrickRules.SPIN_DEG_PER_S
		trickSpin = TrickRules.approach(trickSpin, trickTarget, rate * dt)
	elseif not trickActive and trickTarget ~= 0 then
		trickSpin, trickTarget, unwindRate = 0, 0, 0
	end
	hopCooldown = math.max(0, hopCooldown - dt)
	flubTimer = math.max(0, flubTimer - dt)
end

-- Touch START ring tap (TrickJuice.setStartRing): judged against the server clock like the keyboard press.
local function onStartTap()
	local go = startGoTime
	if not go then
		return
	end
	local before = startState.state
	if TrickRules.tapStart(startState, go - workspace:GetServerTimeNow()) == "perfect" and before ~= "perfect" then
		revThrottle = 1 -- the body kicks up on the springs: the tap landed
	end
end

-- One grid frame (car held on the line until RaceGoTime): Grid Bounce and the rev-match start. Hull, simPos and
-- velocity stay frozen, so the start slot and the server validator never see any of it.
local function stepGrid(dt: number, goTime: number, left: number, steerIn: number, throttle: number, driftHeld: boolean)
	if startGoTime ~= goTime then
		startGoTime = goTime
		startState = TrickRules.newStart()
		startPending = true
	end
	-- Grid Bounce: the drift press bounces the body on its springs; with steer it also spins on the spot.
	local edge = driftHeld and not lastDriftHeld
	lastDriftHeld = driftHeld
	gridHopCooldown = math.max(0, gridHopCooldown - dt)
	if edge and gridHopCooldown <= 0 then
		gridHopTimer = TrickRules.GRID_HOP_TIME
		gridHopCooldown = TrickRules.GRID_HOP_COOLDOWN
		gridHopSeq = (gridHopSeq + 1) % 64
		TrickJuice.play("hop_boing", 0.92)
		-- Spam-tapping breakdances, but never queues more than two turns ahead of the body.
		if math.abs(steerIn) >= TrickRules.SPIN_STEER_MIN and math.abs(trickTarget - trickSpin) < 540 then
			trickTarget += 360 * math.sign(steerIn)
			unwindRate = 0
			TrickJuice.play("trick_whoosh")
		end
		LocalPlayer:SetAttribute("GridBounces", ((LocalPlayer:GetAttribute("GridBounces") :: number?) or 0) + 1)
	end
	-- Rev-match start. Touch runs auto-gas, so touch starts through the ring and cannot flood.
	local touch = Mods.InputMode.current == "Touch"
	local pressed = not touch and throttle > 0.5
	local before = startState.state
	local state = TrickRules.stepStart(startState, pressed, left, not touch)
	TrickJuice.setStartRing(left <= TrickRules.TOUCH_TAP_SHOW_LEFT, left >= TrickRules.START_WINDOW_LO and left <= TrickRules.START_WINDOW_HI, if touch then onStartTap else nil)
	local revTarget = if touch then 0.1 elseif pressed then throttle else 0
	if state == "flooded" then
		-- Flooding: the engine bogs and stutters and a black puff coughs out now and then. Let go to recover.
		revTarget = 0.3 + 0.25 * math.sin(os.clock() * 23)
		floodPuffClock -= dt
		if before ~= "flooded" then
			require(script.Parent:WaitForChild("Sfx37")).play("burnt_sputter", 0.5) -- v37: the burnt start cough
		end
		if before ~= "flooded" or floodPuffClock <= 0 then
			floodPuffClock = 0.7
			Vfx.burst("floodPuff", exhaustCF(), 0.35)
		end
	end
	StartFx.step(CarController.hull, exhaustCF(), state, TrickRules.startCharge(startState, left))
	revThrottle += (revTarget - revThrottle) * expAlpha(1 / 0.15, dt)
	-- Engine pitch through SoundJuice's own speed mapping (0.75 + 0.9 * (speed - 70) / 140), so 0.75 + 0.6 * rev.
	local pitch = TrickRules.revPitch(revTarget)
	local altitude = if RaceAttr.mine("ActiveZone") == "DINO" and simPos then (simPos :: Vector3).Y else 1000
	SoundJuice.step(dt, 70 + (pitch - 0.75) / 0.9 * 140, altitude, "None", revTarget, 0) -- held still: level from the revs only
end

-- First driving frame after the grid hold: hide the ring and apply the start result once per RaceGoTime.
local function applyStart(goTime: any)
	onGrid = false
	TrickJuice.setStartRing(false, false, nil)
	if not startPending then
		StartFx.stop()
		return
	end
	startPending = false
	if type(goTime) ~= "number" or workspace:GetServerTimeNow() - goTime > 0.5 then
		StartFx.stop()
		return -- the hold ended some other way (reset, hub): no start to judge
	end
	local state = startState.state
	LocalPlayer:SetAttribute("StartResult", state)
	if state == "perfect" or state == "good" then
		-- v37 rocket start: perfect = the pad boost (an existing legal speed) for START_BOOST_TIME, good = the blue
		-- mini-turbo speed for START_GOOD_TIME. The callout waits for the GO! numeral to clear.
		local perfect = state == "perfect"
		local speed = if perfect then CarConfig.PAD_BOOST_SPEED else CarConfig.DRIFT_LEVELS[1].boostSpeed
		CarController.triggerBoost("Start", speed, TrickRules.startBoostTime(state), if perfect then "Overcharge" else "Standard")
		StartFx.release(CarController.hull, exhaustCF(), state)
		TrickJuice.play("start_perfect", if perfect then 1 else 0.9)
		task.delay(0.7, TrickJuice.callout, if perfect then "ROCKET START" else "GOOD START", TrickJuice.BLUE, 1.1)
		if perfect then
			Mods.StyleChain.event("PerfectStart") -- REMARKABLE 17
		end
	elseif state == "flooded" then
		StartFx.stop()
		floodTimer = TrickRules.FLOOD_TIME
		Vfx.burst("floodPuff", exhaustCF(), 1)
		TrickJuice.play("start_flood")
		task.delay(0.7, TrickJuice.callout, "STALLED", TrickJuice.SOOT, 1.1)
		CarController.addTrauma(0.15)
	else
		StartFx.stop()
	end
	print(string.format("[SkyRally][TRICK] start=%s", state))
end

-- ---------------------------------------------------------------- input
local assistState = Mods.AssistRules.newState()
local function readInputs(): (number, number, boolean)
	local steer, throttle, drift = 0, 0, false
	-- Typing in chat (or any focused TextBox) must not drive the car: "wasd" in a message is not steering.
	local typing = UserInputService:GetFocusedTextBox() ~= nil
	local key = function(k: Enum.KeyCode): boolean
		return not typing and UserInputService:IsKeyDown(k)
	end
	if key(Enum.KeyCode.A) or key(Enum.KeyCode.Left) then
		steer -= 1
	end
	if key(Enum.KeyCode.D) or key(Enum.KeyCode.Right) then
		steer += 1
	end
	if key(Enum.KeyCode.W) or key(Enum.KeyCode.Up) then
		throttle += 1
	end
	if key(Enum.KeyCode.S) or key(Enum.KeyCode.Down) then
		throttle -= 1
	end
	if key(Enum.KeyCode.LeftShift) or key(Enum.KeyCode.RightShift) or key(Enum.KeyCode.R) or key(Enum.KeyCode.Space) then
		drift = true
	end

	-- Gamepad (console-ready, D20): left stick or D-pad steer, A/R2 gas (R2 analog), B/L2 brake, R1/L1 drift.
	local GP = Enum.UserInputType.Gamepad1
	if UserInputService.GamepadEnabled and UserInputService:GetGamepadConnected(GP) then
		local r2, l2 = 0, 0
		for _, st in UserInputService:GetGamepadState(GP) do
			if st.KeyCode == Enum.KeyCode.Thumbstick1 then
				local x = st.Position.X
				if math.abs(x) > 0.15 then
					steer += math.sign(x) * (math.min(1, math.abs(x)) - 0.15) / 0.85
				end
			elseif st.KeyCode == Enum.KeyCode.ButtonR2 then
				r2 = st.Position.Z
			elseif st.KeyCode == Enum.KeyCode.ButtonL2 then
				l2 = st.Position.Z
			end
		end
		-- Analog trigger pressure where the pad reports it, the digital state otherwise.
		if r2 < 0.05 and UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonR2) then
			r2 = 1
		end
		if l2 < 0.05 and UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonL2) then
			l2 = 1
		end
		throttle += (if r2 > 0.05 then r2 else 0) - (if l2 > 0.05 then l2 else 0)
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.DPadLeft) then
			steer -= 1
		end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.DPadRight) then
			steer += 1
		end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonA) then
			throttle += 1
		end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonB) then
			throttle -= 1
		end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonR1) or UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonL1) then
			drift = true
		end
	end

	-- Desktop mouse steering only while the right button is held (D20): cursor moves alone never steer.
	if not typing and math.abs(steer) < 0.05 and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		local cam = workspace.CurrentCamera
		if cam and cam.ViewportSize.X > 100 then
			local mx = UserInputService:GetMouseLocation().X
			local nx = (mx - cam.ViewportSize.X * 0.5) / (cam.ViewportSize.X * 0.38)
			if math.abs(nx) > 0.14 then
				steer = math.clamp((nx - math.sign(nx) * 0.14) / 0.86, -1, 1) * 0.85
			end
		end
	end

	-- Touch (RaceUI writes these on FlightController): pad X steers, pad pulled down brakes, TURN drifts. RaceUI's
	-- ITEM button fires items now, so Touch drives on CarConfig.AUTO_THROTTLE; mobileThrottle is still read in case
	-- a gas button returns.
	-- Controls v2 (TouchSteerRules): pad X through a dead zone and a mild curve; the pad brakes only on a mostly-downward
	-- pull (the BRAKE button, mobileThrottle = -1, is the main brake / reverse on a phone).
	local ms = FlightController.mobileSteer
	steer += Mods.TouchSteerRules.steer(ms.X)
	local padBrake = Mods.TouchSteerRules.padBrake(ms.X, ms.Y)
	throttle -= padBrake
	throttle += FlightController.mobileThrottle
	if FlightController.mobileSharpBank then
		drift = true
	end
	-- Touch drive (no gas button): ASSIST's auto throttle only in a running race with ASSIST on (a car that stands still hands
	-- off or on the brake for IDLE_STOP_S is left alone); otherwise it drives while a finger is on the steer pad (AssistRules).
	-- The grid ignores it: touch starts via the ring.
	if Mods.InputMode.current == "Touch" then
		local racing = Mods.AssistRules.racingPhase(Mods.HudPhase.phase()) and LocalPlayer:GetAttribute("RaceFinished") ~= true
		local enabled = LocalPlayer:GetAttribute("AutoThrottle") ~= false
		-- The BRAKE button is not a drive input: holding it while stopped counts as standing still (AssistRules).
		local touching = FlightController.padHeld or math.abs(ms.X) > 0.05 or FlightController.mobileSharpBank or FlightController.mobileThrottle >= 0.05
		-- A spin-out, an item stun (bubble 2 s) or a respawn is not the player standing still: the auto throttle picks up after it.
		local busy = CarController.spinning or CarController.respawning or LocalPlayer:GetAttribute("ItemStunned") == true
		local braking = padBrake > 0 or FlightController.mobileThrottle <= -0.05
		local auto = Mods.AssistRules.step(assistState, os.clock(), enabled, racing, touching or (racing and busy), braking, math.abs(CarController.speed))
		if auto and math.abs(throttle) < 0.05 then
			throttle = CarConfig.AUTO_THROTTLE
		end
	end
	return math.clamp(steer, -1, 1), math.clamp(throttle, -1, 1), drift
end

-- QA (Studio only, shared/QASteerRules): workspace.QAFollowLine names an alternate line the AutoPilot pursues from its join to
-- its end, then the main spline again from the line's rejoin station. Inputs only: nothing here moves or limits the car.
local IS_STUDIO = RunService:IsStudio()
local qaState = QASteerRules.newState()
local qaLastName: string? = nil
local qaLastPos: Vector3? = nil
local function qaLineTarget(pos: Vector3, station: number, mainAhead: Vector3): Vector3
	local name = QASteerRules.lineName(IS_STUDIO, workspace:GetAttribute(QASteerRules.FOLLOW_ATTR))
	if name ~= qaLastName then
		qaLastName = name
		qaLastPos = nil
		qaState = QASteerRules.newState()
		if name then
			print("[SkyRally][QASTEER] car follow " .. name .. " requested")
		end
	end
	if not name then
		return mainAhead
	end
	local line = QASteerRules.findLine(Mods.RouteBranch.load(Mods.TrackRegistry.getRoot(), 0), name)
	if not line then
		if qaState.phase ~= "missing" then
			qaState.phase = "missing"
			print("[SkyRally][QASTEER] car line " .. name .. " not found")
		end
		return mainAhead
	end
	local _, trackLength = Mods.SplineUtils.loadWaypoints()
	local lateral, along = Mods.RouteBranch.nearest(line, pos)
	local jump = if qaLastPos then (pos - qaLastPos).Magnitude else 0 -- a respawn teleports: the line pursuit is dropped (V8)
	qaLastPos = pos
	local event = QASteerRules.step(qaState, line, station, along, trackLength, lateral, jump)
	if event then
		print(QASteerRules.logLine("car", event, line, station, along))
	end
	local look = 30 + math.abs(CarController.speed) * 0.45
	local target, mainStation = QASteerRules.pursue(qaState, line, along, look, station, trackLength)
	if target then
		return target
	end
	if mainStation then
		return Mods.SplineUtils.sampleAtStation(mainStation)
	end
	return mainAhead
end

-- QA (workspace.AutoPilot = true): pure-pursuit along the route at full gas, drifting the tight bends.
local function autopilotInputs(): (number, number, boolean)
	local pos = simPos
	if not pos then
		return 0, 0, false
	end
	local st = Mods.SplineUtils.projectPosition(pos, LocalPlayer:GetAttribute("Station") :: number?)
	local ahead = Mods.SplineUtils.sampleAtStation(st + 30 + math.abs(CarController.speed) * 0.45)
	if IS_STUDIO then
		ahead = qaLineTarget(pos, st, ahead) -- QAFollowLine: the named alternate line instead of the main route (Studio only)
	end
	local to = safeUnit(flat(ahead - pos), flat(forward))
	local f = safeUnit(flat(forward), to)
	local errDeg = math.deg(math.atan2(-f:Cross(to).Y, f:Dot(to)))
	local steer = math.clamp(errDeg / 25, -1, 1)
	local throttle = if math.abs(errDeg) > 55 and CarController.speed > 80 then 0.3 else 1
	local drift = QASteerRules.autoDrift(errDeg, CarController.speed, CarController.drifting, CarController.driftDir)
	return steer, throttle, drift
end

-- ---------------------------------------------------------------- track triggers (pads, rings, pods)
local triggerCooldowns: { [Instance]: number } = {}
local gridRevCueFor: number? = nil -- the RaceGoTime the grid rev blip already played for

local function evaluateTriggers(pos: Vector3)
	local now = os.clock()
	for _, trig in Mods.TriggerIndex.get() do
		if trig.Parent then
			local tType = trig:GetAttribute("TriggerType")
			local dist = (trig.Position - pos).Magnitude
			local last = triggerCooldowns[trig] or 0
			if tType == "GroundBoostPad" and dist <= CarConfig.PAD_TRIGGER_RADIUS and now - last > CarConfig.TRIGGER_COOLDOWN and Mods.FidelityRules.padIsLive(if trig.Parent then trig.Parent:GetAttribute("PadLive") else nil) then
				triggerCooldowns[trig] = now
				Vfx.onPad(trig.CFrame)
				Mods.Sfx.play("pad_zip", 1, 0.44)
				CarController.triggerBoost("Pad", CarConfig.PAD_BOOST_SPEED, CarConfig.PAD_BOOST_DURATION, "Standard")
				if raceEventRemote then
					raceEventRemote:FireServer("PadTriggered", { padName = if trig.Parent then trig.Parent.Name else trig.Name, overcharged = false })
				end
			elseif tType == "BoosterRing" and dist <= CarConfig.RING_TRIGGER_RADIUS and now - last > CarConfig.TRIGGER_COOLDOWN then
				triggerCooldowns[trig] = now
				Vfx.onRing(CFrame.lookAt(trig.Position, trig.Position + forward), Vfx.ringRadius(trig.Size))
				Mods.Sfx.play("ring_pass", 1, 0.48) -- layers with the boost hit
				CarController.triggerBoost("Pad", CarConfig.PAD_BOOST_SPEED, CarConfig.PAD_BOOST_DURATION, "Standard")
				if raceEventRemote then
					raceEventRemote:FireServer("RingTriggered", { ringName = if trig.Parent then trig.Parent.Name else trig.Name, overcharged = false })
				end
			elseif trig:GetAttribute("ItemPodSpawn") == true and dist <= CarConfig.PICKUP_TRIGGER_RADIUS and trig:GetAttribute("OnCooldown") ~= true and now - last > Mods.ItemRules.podRetrigger(trig:GetAttribute("RespawnSeconds")) and Mods.ItemRules.clientTakesPod(trig:GetAttribute("PodType"), LocalPlayer:GetAttribute("RaceFinished")) and Mods.PodLocal.take(trig, now) then
				-- Cubes v3: the pod is shared; PodLocal.take pops it on this screen at once (the server's OnCooldown hides
				-- it for everyone a round trip later) and refuses a second cube of the rank just taken.
				triggerCooldowns[trig] = now
				local podType = trig:GetAttribute("PodType")
				Vfx.onPickup(trig.Position, if type(podType) == "string" then podType else nil)
				if podType == "Speed" then
					CarController.speedPickups = math.min(CarConfig.MAX_SPEED_PICKUPS, CarController.speedPickups + 1)
					LocalPlayer:SetAttribute("SpeedPickups", CarController.speedPickups)
					SoundJuice.triggerFeedback("small", "Pickup")
				elseif podType == "Air" or (podType == "Blue" and CarConfig.BLUE_POD_INSTANT_BOOST and trig:GetAttribute("MysteryCube") ~= true) then
					CarController.triggerBoost("Pod", CarConfig.PAD_BOOST_SPEED, CarConfig.PAD_BOOST_DURATION, "Standard")
				else
					SoundJuice.triggerFeedback("small", "Pickup")
				end
				if raceEventRemote then
					raceEventRemote:FireServer("PickupCollected", { podName = trig.Name, podType = podType })
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- binding
local function refreshFilters()
	local exclude: { Instance } = {}
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		table.insert(exclude, planes)
	end
	if LocalPlayer.Character then
		table.insert(exclude, LocalPlayer.Character)
	end
	for _, name in { "SkyRallyVfx", "SkyRallyItemFX" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.FilterDescendantsInstances = exclude
	groundParams.IgnoreWater = true
	-- Visible non-colliding surfaces count as road (the deck's pavers are CanCollide=false over the collidable
	-- TrackSeg); invisible triggers are CanQuery=false (kit/Gameplay) and never reach a probe.
	groundParams.RespectCanCollide = false
	wallParams.FilterType = Enum.RaycastFilterType.Exclude
	wallParams.FilterDescendantsInstances = exclude
	wallParams.IgnoreWater = true
	wallParams.RespectCanCollide = true
	waterParams.FilterType = Enum.RaycastFilterType.Include
	waterParams.FilterDescendantsInstances = { workspace.Terrain }
	waterParams.IgnoreWater = false
end

local function showCarHint()
	task.defer(function()
		if not CarController.car then
			return
		end
		local sg = LocalPlayer.PlayerGui:FindFirstChild("SkyRallyControlsHint")
		local label = if sg then sg:FindFirstChild("Hint") else nil
		local text = CarConfig.HINTS[Mods.InputMode.current]
		if label and label:IsA("TextLabel") and text then
			label.Text = text
			label.Visible = true
			local shown = text
			task.delay(7, function()
				if label.Text == shown then
					label.Visible = false
				end
			end)
		end
	end)
end

local function unbind()
	local car = CarController.car
	if car then
		rigs[car] = nil
	end
	Slipstream.stop()
	StartFx.stop()
	CarController.car = nil
	CarController.hull = nil
	local conn = spawnFrameConn
	if conn then
		conn:Disconnect()
		spawnFrameConn = nil
	end
	simPos = nil
	camReady = false
	fadePhase = "none"
	CarController.respawning = false
	setFadeAlpha(0)
	-- Reverse v2: no stale WRONG WAY sign or reverse intent once the car is gone.
	reverseState = ReverseRules.newState()
	CarController.reverseMode = "drive"
	LocalPlayer:SetAttribute("CarReversing", false)
	wrongWayShown = false
	if arrowUp then
		arrowUp = false
		Mods.CourseArrow.set(false, 0, 0)
	end
	local cam = workspace.CurrentCamera
	-- Hand the camera back unless the plane controller already owns a vehicle to follow.
	if cam and not FlightController.plane then
		cam.CameraType = Enum.CameraType.Custom
	end
end

local function bind(): boolean
	local car = CarController.car
	if car and car.Parent and CarController.hull and (CarController.hull :: BasePart).Parent then
		return true
	end
	if car then
		unbind()
	end
	local planes = workspace:FindFirstChild("Planes")
	local model = if planes then planes:FindFirstChild("Car_" .. LocalPlayer.Name) else nil
	if not model or not model:IsA("Model") or not model.PrimaryPart then
		return false
	end
	CarController.car = model
	CarController.hull = model.PrimaryPart
	refreshFilters()
	attachRig(model, true)
	local spawnCF = (model:GetAttribute("SpawnCFrame") :: CFrame?) or (model.PrimaryPart :: BasePart).CFrame
	resetRaceState(spawnCF)
	CarController.invulnTimer = 2.0
	-- CarServer rewrites SpawnCFrame on every spawn and race reset of a reused car: follow it, so the cached checkpoint
	-- is this map's start even when the RaceReset/CarMounted events were missed or arrive late.
	spawnFrameConn = model:GetAttributeChangedSignal("SpawnCFrame"):Connect(function()
		local cf = model:GetAttribute("SpawnCFrame")
		if typeof(cf) == "CFrame" and CarController.car == model then
			setCheckpoint(cf)
		end
	end)
	if (LocalPlayer:GetAttribute("FirstDriveReadySeconds") :: number?) == nil then
		LocalPlayer:SetAttribute("FirstDriveReadySeconds", os.clock() - FlightController.joinClock)
	end
	showCarHint()
	print(string.format("[SkyRally][CAR] client bound %s mesh=%s", model.Name, tostring(model:GetAttribute("HasTripoMesh"))))
	return true
end

-- Kill height: lowest route point minus KILL_DEPTH, or the track's lava floor when it is higher.
local function refreshKillY()
	if killYReady then
		return
	end
	local wps = Mods.SplineUtils.loadWaypoints()
	if #wps < 2 then
		return
	end
	local minY = math.huge
	for _, w in wps do
		minY = math.min(minY, w.pos.Y)
	end
	killY = minY - CarConfig.KILL_DEPTH
	local lava = Mods.TrackRegistry.lavaFloorY()
	if lava then
		killY = math.max(killY, lava)
	end
	killYReady = true
end

-- ---------------------------------------------------------------- camera
local function updateCamera(dt: number)
	local cam = workspace.CurrentCamera
	local pos = simPos
	if not cam or not pos then
		return
	end
	local shot = workspace:GetAttribute("ShotCam")
	if shot and shot ~= "" then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	-- Follow the travel heading, not the body: drifts and spin-outs swing the car across a steady frame.
	local travel = safeUnit(flat(forward), camForward)
	if not camReady then
		camForward = travel
		camY = pos.Y
		feel.camRoll, feel.camSide, feel.camDip, feel.camDipVel = 0, 0, 0, 0
		camReady = true
	else
		-- Reverse v2: a calmer heading follow while backing up (no whip as the tail swings), v27 response going forward.
		local yawResp = ReverseRules.camera(CarController.speed)
		camForward = safeUnit(camForward:Lerp(travel, expAlpha(yawResp, dt)), travel)
		camY += (pos.Y - camY) * expAlpha(CarConfig.CAM_VERTICAL_RESPONSE, dt)
	end
	local speedFrac = math.clamp(math.abs(CarController.speed) / CarConfig.TOP_SPEED, 0, 1)
	local _, revPull = ReverseRules.camera(CarController.speed)
	local dist = CarConfig.CAM_DISTANCE + CarConfig.CAM_SPEED_PULLBACK * speedFrac + revPull
	-- v38-feel: drift look-ahead (the look point swings to the inside, the camera slides a little outside), lean into the
	-- turn, and a landing dip spring (feel.camDipVel is kicked at touchdown). Spin-outs keep the steady frame.
	local driving = not CarController.spinning and not CarController.respawning
	local sideTarget = if driving and CarController.drifting then CarController.driftDir else 0
	feel.camSide += (sideTarget - feel.camSide) * expAlpha(CarConfig.CAM_DRIFT_LOOK_RESPONSE, dt)
	local rollTarget = if driving
		then -(CarController.steer * speedFrac * CarConfig.CAM_LEAN_DEG + (if CarController.drifting then CarController.driftDir * CarConfig.CAM_DRIFT_LEAN_DEG else 0))
		else 0
	feel.camRoll += (rollTarget - feel.camRoll) * expAlpha(CarConfig.CAM_LEAN_RESPONSE, dt)
	local sdt = math.min(dt, 0.05)
	feel.camDipVel += (-90 * feel.camDip - 11 * feel.camDipVel) * sdt
	feel.camDip = math.clamp(feel.camDip + feel.camDipVel * sdt, -CarConfig.CAM_LAND_DIP_MAX, CarConfig.CAM_LAND_DIP_MAX * 0.5)
	local right = safeUnit(camForward:Cross(Vector3.yAxis), Vector3.xAxis)
	local base = Vector3.new(pos.X, camY, pos.Z)
	local camPos = base - camForward * dist + Vector3.yAxis * (CarConfig.CAM_HEIGHT + feel.camDip) - right * (feel.camSide * CarConfig.CAM_DRIFT_SWING)
	local target = Vector3.new(pos.X, (camY + pos.Y) * 0.5, pos.Z)
		+ camForward * CarConfig.CAM_LOOK_AHEAD
		+ Vector3.yAxis * (CarConfig.CAM_LOOK_HEIGHT + feel.camDip * 0.4)
		+ right * (feel.camSide * CarConfig.CAM_DRIFT_LOOK)
	local cf = CFrame.lookAt(camPos, target) * CFrame.Angles(0, 0, math.rad(feel.camRoll))

	-- Camera-only trauma shake (never touches the simulated car).
	if CarController.cameraTrauma > 0 then
		CarController.cameraTrauma = math.max(0, CarController.cameraTrauma - 1.5 * dt)
		local shake = CarController.cameraTrauma * CarController.cameraTrauma * Mods.Settings.shakeScale()
		traumaClock += dt * 28
		cf *= CFrame.new(0.8 * shake * math.sin(traumaClock * 1.7), 0.6 * shake * math.sin(traumaClock * 2.3), 0)
			* CFrame.Angles(0, 0, 0.04 * shake * math.sin(traumaClock * 1.1))
	end
	cam.CFrame = cf

	local fov = CarConfig.CAM_BASE_FOV + CarConfig.CAM_SPEED_FOV * speedFrac
	if CarController.boostState == "Overcharge" then
		fov += CarConfig.CAM_OVERCHARGE_FOV -- v38-feel: the stronger boost reads wider
	elseif CarController.boostState ~= "None" then
		fov += CarConfig.CAM_BOOST_FOV
	end
	if hitStopTimer > 0 then
		fov += 3
	end
	-- Boost ignite punch (Vfx.boostPunch): the FOV overshoot rides on top of the smoothed FOV; queued trauma joins the shake.
	local baseFov = cam.FieldOfView - appliedFovKick
	baseFov += (fov - baseFov) * expAlpha(if fov >= baseFov then CarConfig.CAM_FOV_RESPONSE else CarConfig.CAM_FOV_EASE_BACK, dt)
	appliedFovKick = Vfx.fovKick()
	cam.FieldOfView = baseFov + appliedFovKick
	local punchTrauma = Vfx.takeTrauma()
	if punchTrauma > 0 then
		CarController.addTrauma(punchTrauma)
	end
end

-- ---------------------------------------------------------------- visuals for the local car
local function updateLocalVisuals(dt: number, throttle: number)
	local car = CarController.car
	local rig = if car then rigs[car] else nil
	if not rig then
		return
	end
	-- v38-feel: the shield blink after a spin-out or respawn (MK-style: the kart flickers while it cannot be hit).
	if feel.flickerTimer > 0 or feel.flickerOn then
		feel.flickerTimer = math.max(0, feel.flickerTimer - dt)
		local on = feel.flickerTimer > 0 and (feel.flickerTimer * 14) % 2 < 1
		if on ~= feel.flickerOn then
			feel.flickerOn = on
			if on then
				table.clear(feel.flickerParts)
				for _, d in rig.model:GetDescendants() do
					if d:IsA("BasePart") and d.Transparency < 1 then
						table.insert(feel.flickerParts, d)
					end
				end
			end
			for _, p in feel.flickerParts do
				p.LocalTransparencyModifier = if on then 0.65 else 0
			end
		end
	end
	-- Landing squash spring and drift hop (body only; Motor6D.Transform stays on this client).
	squashVel += (-180 * squash - 14 * squashVel) * dt
	squash += squashVel * dt
	hopTimer = math.max(0, hopTimer - dt)
	local hop = 0
	if hopTimer > 0 then
		local t = 1 - hopTimer / CarConfig.DRIFT_HOP_TIME
		hop = math.sin(t * math.pi) * CarConfig.DRIFT_HOP_HEIGHT
	end
	local speedFrac = math.clamp(math.abs(CarController.speed) / CarConfig.TOP_SPEED, 0, 1)
	local roll = CarController.steer * speedFrac * CarConfig.LEAN_DEG + CarController.driftDir * CarConfig.DRIFT_LEAN_DEG
	local pitch = throttle * CarConfig.PITCH_ACCEL_DEG * (1 - speedFrac * 0.5)
	if not CarController.grounded then
		local h = flat(velocity).Magnitude
		pitch += math.deg(math.atan2(velocity.Y, math.max(h, 1))) * CarConfig.AIR_NOSE_PITCH
	end
	-- Grid Bounce (lowrider pop, nose first) and the grid rev (engine shake, nose lifts with the revs).
	if gridHopTimer > 0 then
		gridHopTimer = math.max(0, gridHopTimer - dt)
		local t = 1 - gridHopTimer / TrickRules.GRID_HOP_TIME
		hop += math.sin(t * math.pi) * TrickRules.GRID_HOP_HEIGHT
		pitch += math.sin(t * math.pi) * 7
		if gridHopTimer == 0 then
			squash = math.max(squash, 0.55) -- springs take the landing and wobble
		end
	end
	if onGrid then
		hop += math.sin(os.clock() * 61) * 0.035 * (0.3 + revThrottle)
		pitch += revThrottle * 3
	end
	-- Flubbed trick landing: the body wobbles side to side as it settles.
	if flubTimer > 0 then
		local k = flubTimer / TrickRules.FLUB_WOBBLE_TIME
		roll += math.sin((1 - k) * 34) * 11 * k
	end
	if rig.bodyMotor then
		rig.bodyMotor.Transform = CFrame.new(0, -squash * CarConfig.LAND_SQUASH_DEPTH + hop, 0)
			* CFrame.Angles(0, math.rad(-trickSpin), 0)
			* CFrame.Angles(math.rad(pitch), 0, math.rad(roll))
	end
	wheelSpin -= CarController.speed / CarConfig.WHEEL_RADIUS * dt
	for i = 1, 4 do
		local target = if CarController.grounded and probeDistances[i] ~= math.huge
			then math.clamp(CarConfig.WHEEL_RADIUS - probeDistances[i], -CarConfig.SUSPENSION_TRAVEL, CarConfig.SUSPENSION_TRAVEL)
			else -CarConfig.SUSPENSION_TRAVEL * 0.6
		wheelOffsets[i] += (target - wheelOffsets[i]) * expAlpha(20, dt)
	end
	setWheels(rig, wheelSpin, CarController.steer * CarConfig.WHEEL_STEER_VISUAL_DEG, wheelOffsets)
	setDriftEffects(rig, CarController.drifting, CarController.driftLevel, CarController.grounded)
	Mods.GroundFx.step(dt, rig.hull, {
		speed = CarController.speed,
		grounded = CarController.grounded,
		drifting = CarController.drifting,
		slipDeg = slideDeg,
		wet = inShallowWater,
		waterY = waterSurfaceY,
	}, CarController.addTrauma)
end

-- ---------------------------------------------------------------- the step
local function syncToServer(dt: number, cf: CFrame)
	syncAccumulator += dt
	if syncAccumulator >= CarConfig.SYNC_INTERVAL and flightStateRemote then
		syncAccumulator = 0
		flightStateRemote:FireServer("SyncTransform", {
			cframe = cf,
			speed = math.abs(CarController.speed),
			boostState = CarController.boostState,
			steer = CarController.steer,
			drifting = CarController.drifting,
			driftLevel = CarController.driftLevel,
			airborne = not CarController.grounded,
			vehicle = "car",
			-- Trick lane: body spin (wrapped, 15-degree steps) and the grid bounce counter, for other clients' rigs.
			trick = math.floor(TrickRules.wrap180(trickSpin) / 15 + 0.5) * 15,
			gridHop = gridHopSeq,
		})
	end
end

local function mirrorToFlightController(throttle: number)
	-- RaceUI highlights (TURN lit while drifting, ITEM lit on gas) and FlightController's Vfx.step call read these.
	FlightController.currentSpeed = math.abs(CarController.speed)
	FlightController.boostState = CarController.boostState
	FlightController.sharpBank = CarController.drifting
	FlightController.steerInput = Vector2.new(CarController.steer, 0)
	FlightController.throttleInput = throttle
end

local function probeGround(pos: Vector3, bodyFwd: Vector3, upv: Vector3): { RaycastResult? }
	local rot = frame(Vector3.zero, bodyFwd, upv)
	local results: { RaycastResult? } = {}
	local castLen = CarConfig.PROBE_UP + CarConfig.WHEEL_RADIUS + CarConfig.PROBE_DOWN
	for i, w in CarConfig.WHEELS do
		local wheel = pos + rot:VectorToWorldSpace(Vector3.new(w[1], w[2], w[3]))
		local r = workspace:Raycast(wheel + upv * CarConfig.PROBE_UP, -upv * castLen, groundParams)
		if r and not isWallNormal(r.Normal, upv) then
			probeDistances[i] = r.Distance - CarConfig.PROBE_UP
			results[i] = r
		else
			probeDistances[i] = math.huge
			results[i] = nil
		end
	end
	return results
end

local function stepCarOnce(rawDt: number)
	local dt = math.clamp(rawDt, 1 / 240, 0.05)
	stepRemoteRigs(dt)
	if not bind() then
		Mods.GroundFx.step(dt, nil, nil, CarController.addTrauma) -- other cars' marks and spray still run in the hub
		return
	end
	local hull = CarController.hull :: BasePart
	refreshKillY()

	CarController.invulnTimer = math.max(0, CarController.invulnTimer - dt)
	hitStopTimer = math.max(0, hitStopTimer - dt)
	bumpCooldown = math.max(0, bumpCooldown - dt)
	-- The fade can finish a respawn here (completeRespawn -> placeAt moves simPos to the checkpoint). Read the start
	-- position AFTER it: read before, this step integrated from where the car died and committed that, putting the car
	-- straight back in the water it was rescued from.
	stepFade(dt)
	local pos0 = simPos or hull.Position
	if (hull.Position - pos0).Magnitude > 40 then
		pos0 = hull.Position -- moved by the server (escalation hold): follow it
	end

	if CarController.boostTimer > 0 then
		CarController.boostTimer = math.max(0, CarController.boostTimer - dt)
		if CarController.boostTimer == 0 then
			cancelBoost()
		end
	end
	if magnetTimer > 0 then
		magnetTimer = math.max(0, magnetTimer - dt)
		if magnetTimer == 0 then
			magnetPull, magnetTarget = 0, nil
		end
	end
	itemSlowTimer = math.max(0, itemSlowTimer - dt)
	itemAutoTimer = math.max(0, itemAutoTimer - dt)

	-- REMARKABLE item 13: a scripted ride (galleon cannon) owns the hull until it lands (see CarController.ride).
	local ride = CarController.ride
	if ride then
		local rideCF = if CarController.respawning or fadePhase ~= "none" then nil else ride(dt)
		if rideCF then
			simPos = rideCF.Position
			velocity = Vector3.zero
			forward = safeUnit(flat(rideCF.LookVector), forward)
			writeHull(rideCF, Vector3.zero)
			updateCamera(dt)
			mirrorToFlightController(0)
			syncToServer(dt, hull.CFrame)
			return
		end
		CarController.ride = nil
		local land = CarController.rideLand
		CarController.rideLand = nil
		if land and not CarController.respawning and fadePhase == "none" then
			placeAt(land, CarController.rideLandSpeed, true)
		end
		pos0 = simPos or hull.Position
	end

	-- Respawning: no control, the car keeps falling / sinking under the fade. A rescue or an off-track return (grounded:
	-- the stranded rule needs it) is not a fall: the car holds its height under the poof. Integrated with gravity and
	-- no ground, it sank through the floor of the 1-deep ISLAND-2 shallows "to its roof" before the gull lifted it out.
	if CarController.respawning or fadePhase == "wait" then
		local holds = RespawnRules.holdsUnderFade(respawnReason)
		local sink = if inShallowWater or (LocalPlayer:GetAttribute("LastCrashReason") == "Water") then 0.25 else 1
		local vy = if holds then 0 else math.max(-CarConfig.MAX_FALL_SPEED, velocity.Y - CarConfig.GRAVITY * sink * dt)
		velocity = Vector3.new(velocity.X * 0.96, vy, velocity.Z * 0.96)
		local p = pos0 + velocity * dt
		simPos = p
		writeHull(frame(p, forward, up), velocity)
		updateCamera(dt)
		mirrorToFlightController(0)
		syncToServer(dt, hull.CFrame)
		return
	end

	-- Start countdown (TrackDirector, workspace.RaceGoTime): hold on the grid until GO.
	-- Also held while the server swaps maps under the curtain (workspace.TrackSwitching): the ground is about to vanish.
	-- Per group (economy v3 phase 2b) GO is this player's own race's (shared/RaceAttr.mine; workspace when off).
	local goTime = RaceAttr.mine("RaceGoTime")
	local switching = workspace:GetAttribute("TrackSwitching") == true
	if groundWaitUntil > 0 then
		if os.clock() >= groundWaitUntil or workspace:Raycast(pos0, Vector3.new(0, -30, 0), groundParams) then
			groundWaitUntil = 0
		else
			switching = true -- no ground here yet: hold like the map swap
		end
	end
	if switching or (type(goTime) == "number" and workspace:GetServerTimeNow() < goTime) then
		if not holdCleared then
			holdCleared = true
			Mods.StyleSense.stop() -- no wake or sizzle left running on the grid or under the curtain
		end
		velocity = Vector3.zero
		CarController.speed = 0
		simPos = pos0
		writeHull(hull.CFrame, velocity)
		if not switching and type(goTime) == "number" then
			local left = goTime - workspace:GetServerTimeNow()
			if gridRevCueFor ~= goTime and left <= 1.15 and left > 0 then
				gridRevCueFor = goTime
				Mods.Sfx.play("grid_rev", 1, 0.4) -- the rev blip just before GO
			end
		end
		-- Grid Bounce and the rev-match start (REMARKABLE items 5, 6): body, sound and HUD only.
		local gridThrottle = 0
		if not switching and type(goTime) == "number" and workspace:GetAttribute("AutoPilot") ~= true then
			local gSteer, gThrottle, gDrift = readInputs()
			onGrid = true
			gridThrottle = math.max(0, gThrottle)
			stepGrid(dt, goTime, goTime - workspace:GetServerTimeNow(), gSteer, gThrottle, gDrift)
		else
			onGrid = false
			TrickJuice.setStartRing(false, false, nil)
		end
		stepTrickSpin(dt)
		updateLocalVisuals(dt, if onGrid then revThrottle else 0)
		updateCamera(dt)
		mirrorToFlightController(gridThrottle)
		syncToServer(dt, hull.CFrame)
		return
	end
	holdCleared = false
	if startPending or onGrid then
		applyStart(goTime)
	end

	-- Inputs
	local steerIn, throttle, driftHeld
	-- Items v4: Rocket Rush drives the line with the QA AutoPilot's pure pursuit for its few seconds (inputs only:
	-- adhesion, walls and the rest of the car are untouched).
	if workspace:GetAttribute("AutoPilot") == true or itemAutoTimer > 0 then
		steerIn, throttle, driftHeld = autopilotInputs()
	elseif LocalPlayer:GetAttribute("RaceFinished") == true and RaceAttr.mine("RaceMode") ~= "battle" and RaceAttr.mine("RaceMode") ~= "hub" then
		-- v38-feel: past the line the car drives itself (MK8): the route's pure pursuit at a cruise, no drifts, so the
		-- finish swing (client/FinishShow) shows it rolling on instead of stopping dead when the keys let go.
		steerIn, throttle = autopilotInputs()
		throttle = math.min(throttle, if math.abs(CarController.speed) > 95 then 0 else 0.7)
		driftHeld = false
	else
		steerIn, throttle, driftHeld = readInputs()
	end
	if IS_STUDIO then
		-- QASteer / QAThrottle (-1..1): a probe holds an exact input; the same variables a player's keys feed.
		steerIn = QASteerRules.axis(IS_STUDIO, workspace:GetAttribute(QASteerRules.STEER_ATTR)) or steerIn
		throttle = QASteerRules.axis(IS_STUDIO, workspace:GetAttribute(QASteerRules.THROTTLE_ATTR)) or throttle
	end
	-- Battle arena edge (workspace BattleCenter/BattleRadius/BattleReturnRadius from the server's BattleCore): from 90 %
	-- of the play radius outward the steering blends toward the centre, all of it at the boundary.
	local battleCenter = RaceAttr.mine("BattleCenter")
	local battleRadius = RaceAttr.mine("BattleRadius")
	local battleOuter = RaceAttr.mine("BattleReturnRadius")
	if RaceAttr.mine("RaceMode") == "battle" and typeof(battleCenter) == "Vector3" and type(battleRadius) == "number" and type(battleOuter) == "number" then
		local inward = flat(battleCenter - pos0)
		local start = battleRadius * 0.9
		if inward.Magnitude > start and inward.Magnitude > 1 then
			local w = math.clamp((inward.Magnitude - start) / math.max(battleOuter - start, 1), 0, 1)
			local f = safeUnit(flat(forward), inward.Unit)
			local errDeg = math.deg(math.atan2(-f:Cross(inward.Unit).Y, f:Dot(inward.Unit)))
			local pull = math.clamp(errDeg / 25, -1, 1)
			steerIn += (pull - steerIn) * math.max(w, 0.35)
		end
	end
	-- Magnet v2: the steering leans toward the locked racer (magnetSteerBlend of it; the player keeps the rest) and the
	-- gas is held down unless the player brakes. Inputs only: grip, wall/slope driving and every rescue are untouched,
	-- so the car still drives the road and stops at whatever a wall stops. Contact ends the pull.
	if magnetTimer > 0 and magnetTarget then
		local tm = magnetTarget :: Model
		local tHull = if tm.Parent then tm.PrimaryPart else nil
		if not tHull then
			magnetTimer, magnetPull, magnetTarget = 0, 0, nil
		elseif (Mods.PlayerStreamRules.enginePosition(tHull) - pos0).Magnitude <= Mods.ItemRules.TUNING.magnetArrive then
			magnetTimer, magnetPull, magnetTarget = 0, 0, nil
			local cb = FlightController.onMagnetArrive
			if cb then
				cb(tm)
			end
		else
			local to = flat(Mods.PlayerStreamRules.enginePosition(tHull) - pos0)
			if to.Magnitude > 1 then
				local f = safeUnit(flat(forward), to.Unit)
				local errDeg = math.deg(math.atan2(-f:Cross(to.Unit).Y, f:Dot(to.Unit)))
				local lean = math.clamp(errDeg / 25, -1, 1)
				-- Far off, the straight line to them cuts the road's bends, so the lean is light (35 %) and the road is
				-- the player's; it reaches the full blend inside 60 studs, where the line and the road agree.
				local w = Mods.ItemRules.TUNING.magnetSteerBlend * math.clamp(1.4 - to.Magnitude / 150, 0.35, 1)
				steerIn += (lean - steerIn) * w
			end
			if throttle > -0.05 then
				throttle = 1
			end
		end
	end
	if CarController.spinning or LocalPlayer:GetAttribute("BattleOut") == true then
		-- Spinning out, or out of a battle (spectating): no control, the car rolls to a stop.
		steerIn, throttle, driftHeld = 0, 0, false
	end
	-- FLOODED start: the engine stalls for FLOOD_TIME (gas capped at FLOOD_THROTTLE_CAP, sputter jolts on the body).
	if floodTimer > 0 then
		local before = floodTimer
		floodTimer = math.max(0, floodTimer - dt)
		throttle = math.min(throttle, TrickRules.FLOOD_THROTTLE_CAP)
		if math.floor(before / 0.11) ~= math.floor(floodTimer / 0.11) then
			squash = math.max(squash, 0.3)
		end
	end
	-- Slipstream (v37): in a rival's wake for SlipstreamRules.CHARGE_TIME, the wake slingshots the car (blue
	-- mini-turbo speed, inside the validator's bound). Races only; never while spun out, stunned or reversing.
	if RaceAttr.mine("RaceMode") ~= "hub" and not CarController.spinning and CarController.speed > 0 then
		if Slipstream.step(dt, CarController.hull, CarController.speed, CarConfig.HALF_WIDTH) then
			CarController.triggerBoost("Draft", SlipstreamRules.CAR_SPEED, SlipstreamRules.CAR_SECONDS, "Standard")
			LocalPlayer:SetAttribute("DraftCount", ((LocalPlayer:GetAttribute("DraftCount") :: number?) or 0) + 1)
		end
	else
		Slipstream.stop()
	end
	CarController.steer += (steerIn - CarController.steer) * expAlpha(CarConfig.STEER_RESPONSE, dt)
	local steer = CarController.steer
	CarController.throttle = throttle

	-- Hop and Spin (REMARKABLE item 5): a drift press with the stick centred hops; in the air, a press with steer
	-- spins the body. Holding on and steering after a hop is the usual hop-into-drift (the drift starts on landing).
	if driftHeld and not lastDriftHeld and workspace:GetAttribute("AutoPilot") ~= true then
		if CarController.grounded then
			tryHop(pos0, steerIn)
		else
			trySpin(steerIn)
		end
	end
	lastDriftHeld = driftHeld
	stepTrickSpin(dt)

	-- Spin-out timer: the body turns SPIN_TURNS times, travel keeps its heading.
	if CarController.spinning then
		spinTimer = math.max(0, spinTimer - dt)
		local t = 1 - spinTimer / math.max(0.01, spinDuration)
		spinAngle = spinTotal * (1 - (1 - t) ^ 2)
		if spinTimer == 0 then
			CarController.spinning = false
			spinAngle = 0
			CarController.invulnTimer = math.max(CarController.invulnTimer, 0.6)
			feel.flickerTimer = math.max(feel.flickerTimer, 0.6)
			LocalPlayer:SetAttribute("SpinningOut", false)
			LocalPlayer:SetAttribute("ItemStunned", false)
		end
	end

	-- Ground probes under the body (the body is rotated by the drift slide).
	local bodyFwd = rotateAbout(forward, up, -math.rad(slideDeg + spinAngle))
	local results = probeGround(pos0, bodyFwd, up)
	local wasGrounded = CarController.grounded
	local vUp = velocity:Dot(up)
	local grounded, contacts = CarConfig.resolveGrounded(wasGrounded, probeDistances, vUp)
	CarController.contacts = contacts
	local correction = if grounded then CarConfig.groundCorrection(probeDistances, wasGrounded) else 0

	if grounded then
		-- Road normal, surface type, hazards from the touching wheels.
		local nSum = Vector3.zero
		local terrainHits, offroadHits, lethal = 0, 0, false
		local reach = CarConfig.WHEEL_RADIUS + (if wasGrounded then CarConfig.SNAP_GROUNDED else CarConfig.SNAP_LANDING)
		for i = 1, 4 do
			local r = results[i]
			if r and probeDistances[i] <= reach then
				nSum += r.Normal
				if r.Instance == workspace.Terrain then
					terrainHits += 1
					if OFFROAD[r.Material.Name] then
						offroadHits += 1
					end
				end
				if isLethal(r.Instance) then
					lethal = true
				end
			end
		end
		if lethal and CarController.invulnTimer <= 0 then
			CarController.beginRespawn("LethalLava", up)
			return
		end
		onOffroad = offroadHits * 2 > contacts
		offTrackFlag = terrainHits * 2 > contacts
		local targetUp = safeUnit(nSum, up)
		if not wasGrounded then
			-- Touchdown: keep the momentum along the road, squash by the impact speed.
			local impact = math.max(0, -velocity:Dot(targetUp))
			up = safeUnit(up:Lerp(targetUp, 0.6), targetUp)
			forward = safeUnit(onPlane(forward, up), forward)
			CarController.speed = velocity:Dot(forward) * CarConfig.LAND_SPEED_KEEP
			local s = math.clamp((impact - CarConfig.LAND_SQUASH_MIN_SPEED) / (CarConfig.LAND_SQUASH_FULL_SPEED - CarConfig.LAND_SQUASH_MIN_SPEED), 0, 1)
			if impact > CarConfig.LAND_SQUASH_MIN_SPEED then
				squash = math.max(squash, 0.25 + 0.75 * s)
				CarController.addTrauma(0.08 + 0.2 * s)
				feel.camDipVel = math.min(feel.camDipVel, -impact * CarConfig.CAM_LAND_DIP) -- v38-feel: the camera dips with the landing
			end
			LocalPlayer:SetAttribute("LastLandingSpeed", math.floor(impact))
			if impact > CarConfig.LAND_SQUASH_MIN_SPEED and not hopAir then
				Vfx.onLand(groundCF(pos0), s) -- real air (ramps, drops); a hop's own landing dust is landTrick's hopDust
				Mods.Sfx.play("land_thud", 1.15 - 0.3 * s, 0.25 + 0.5 * s)
				SoundJuice.accent("land")
			end
			landTrick(pos0, CarController.airTime) -- before airTime resets: only ramp-length air earns the boost
			CarController.airTime = 0
		else
			up = safeUnit(up:Lerp(targetUp, expAlpha(CarConfig.GROUND_ALIGN_RESPONSE, dt)), targetUp)
			forward = safeUnit(onPlane(forward, up), forward)
		end

		-- Speed: boost, gas, brake/reverse, coast, slope. Reverse v2 (ReverseRules): brake to a stop, keep holding for
		-- REVERSE_DELAY, then back up; the speed TARGET only (slope gravity below and adhesion are untouched).
		local speed = CarController.speed
		local revMode = ReverseRules.step(reverseState, throttle, speed, dt)
		if (revMode == "reverse") ~= (CarController.reverseMode == "reverse") then
			LocalPlayer:SetAttribute("CarReversing", revMode == "reverse") -- RaceUI's pedal caption: BRAKE / REV
		end
		CarController.reverseMode = revMode
		local surfaceFactor = (if onOffroad then CarConfig.OFFROAD_SPEED_FACTOR else 1) * (if inShallowWater then CarConfig.WATER_SPEED_FACTOR else 1)
		local top = (CarConfig.TOP_SPEED + CarController.speedPickups * CarConfig.SPEED_PICKUP_BONUS) * surfaceFactor
		if CarController.drifting then
			top *= CarConfig.DRIFT_SPEED_FACTOR
		end
		if CarController.spinning then
			speed *= math.exp(-3 * dt)
		elseif CarController.boostTimer > 0 then
			-- Boosts ignore off-road (MK rule) and pull the speed up fast.
			if speed < boostSpeed then
				speed += (boostSpeed - speed) * expAlpha(CarConfig.BOOST_RESPONSE, dt)
			end
		elseif throttle > 0.05 then
			if speed < -1 then
				speed = math.min(0, speed + CarConfig.BRAKE_DECEL * dt)
			else
				local target = top * throttle
				if speed < target then
					speed = math.min(target, speed + math.max(CarConfig.ACCEL_MIN, (target - speed) * CarConfig.ACCEL_RESPONSE) * dt)
				else
					speed = math.max(target, speed - math.max(CarConfig.COAST_DECEL, (speed - target) * CarConfig.OVERSPEED_DECAY) * dt)
				end
			end
		elseif revMode ~= "drive" then
			speed = ReverseRules.stepSpeed(revMode, speed, -throttle, dt)
		else
			local decay = math.max(CarConfig.COAST_DECEL, if speed > top then (speed - top) * CarConfig.OVERSPEED_DECAY else 0) * dt
			speed = if speed > 0 then math.max(0, speed - decay) else math.min(0, speed + decay)
		end
		speed -= CarConfig.SLOPE_GRAVITY * forward.Y * dt
		if itemSlowTimer > 0 and CarController.boostTimer <= 0 then
			-- Items v4: a slow eases the car down to its cap (the slow itself is capped server-side).
			local cap = CarConfig.TOP_SPEED * itemSlowFactor
			if speed > cap then
				speed += (cap - speed) * expAlpha(6, dt)
			end
		end
		-- Magnet pull raises speed toward top + pull (never past MAGNET_MAX_SPEED, inside the validator's item-boost
		-- allowance); it must never clamp a faster boost (pad, mini-turbo) down to that.
		local magnetCap = math.min(top + magnetPull, CarConfig.MAGNET_MAX_SPEED)
		if magnetPull > 0 and speed > 0 and speed < magnetCap then
			speed = math.min(speed + magnetPull * dt * 3, magnetCap)
		end
		CarController.speed = speed

		-- Drift: starts when the button is held while steering at speed, direction locked until release.
		if not CarController.drifting and driftHeld and not CarController.spinning and math.abs(steerIn) >= CarConfig.DRIFT_STEER_START and speed >= CarConfig.DRIFT_MIN_SPEED then
			CarController.drifting = true
			CarController.driftDir = if steerIn > 0 then 1 else -1
			CarController.driftCharge = 0
			CarController.driftLevel = 0
			hopTimer = CarConfig.DRIFT_HOP_TIME
			feel.chargeVoice(0)
		end
		if CarController.drifting then
			if not driftHeld then
				endDrift(true)
			elseif speed < CarConfig.DRIFT_CANCEL_SPEED then
				endDrift(false)
			else
				CarController.driftCharge += CarConfig.driftChargeRate(steerIn, CarController.driftDir) * dt
				local lvl = CarConfig.driftLevel(CarController.driftCharge)
				if lvl > CarController.driftLevel then
					CarController.driftLevel = lvl
					feel.chargeVoice(lvl)
					-- REMARKABLE 15: each tier has its own crackle (tiers no longer reuse the pickup chime, which
					-- stays as the fallback until the style cues are uploaded); the zone tier also flashes its burst.
					if not Mods.StyleChain.sfx("drift_tier" .. lvl) then
						SoundJuice.triggerFeedback("small", "Checkpoint")
					end
					if CarController.hull then -- tier-up pop at the rear wheels (the release below flashes the bigger one)
						Mods.GroundFx.tierPop(CarController.hull, lvl, rgb(CarConfig.driftColor(lvl, RaceAttr.mine("ActiveZone") :: string?)))
					end
					if lvl >= 3 then
						Mods.StyleSense.zoneBurst(groundCF(pos0), RaceAttr.mine("ActiveZone") :: string?, 0.7)
						CarController.addTrauma(0.1)
						LocalPlayer:SetAttribute("ZoneTurboCount", ((LocalPlayer:GetAttribute("ZoneTurboCount") :: number?) or 0) + 1)
					else
						CarController.addTrauma(0.05)
					end
				end
				Mods.StyleChain.sustain() -- a drift held keeps the style chain's fuse from burning
			end
		end

		-- Yaw: grip turning, or the locked drift arc; reversing steers like a real car (the tail follows the wheel) with a
		-- turn-rate floor once rolling, so a three-point turn swings at once (ReverseRules.gripYaw).
		local yawDeg: number
		if CarController.drifting then
			yawDeg = CarController.driftDir * CarConfig.turnRate(speed) * CarConfig.driftTurnMultiplier(steer, CarController.driftDir)
			if speed < 0 then
				yawDeg = -yawDeg * ReverseRules.TURN_FACTOR
			end
		else
			yawDeg = ReverseRules.gripYaw(steer, speed)
		end
		forward = safeUnit(rotateAbout(forward, up, -math.rad(yawDeg * dt)), forward)
		velocity = forward * speed
	else
		-- Airborne: ballistic, a little air steer, up vector eases back to world up.
		if wasGrounded then
			velocity = forward * CarController.speed
			LocalPlayer:SetAttribute("LastJumpClock", os.clock())
		end
		CarController.airTime += dt
		onOffroad, offTrackFlag = false, false
		velocity = Vector3.new(velocity.X, math.clamp(velocity.Y - CarConfig.GRAVITY * dt, -CarConfig.MAX_FALL_SPEED, CarConfig.MAX_RISE_SPEED), velocity.Z)
		local hSpeed = flat(velocity).Magnitude
		local airYaw = steer * CarConfig.turnRate(hSpeed) * CarConfig.AIR_STEER_FACTOR * dt
		forward = safeUnit(rotateAbout(flat(forward), Vector3.yAxis, -math.rad(airYaw)), flat(forward))
		local hv = rotateAbout(flat(velocity), Vector3.yAxis, -math.rad(airYaw * CarConfig.AIR_VELOCITY_TURN))
		-- Fairness (review fix): a hop off grass or shallows keeps that surface's braking in the air, so hop spam is
		-- never a way to cross a slow shortcut faster than driving it (boosts ignore off-road, as on the ground).
		if hopAir and hopSurfaceFactor < 1 and CarController.boostTimer <= 0 then
			local hs = hv.Magnitude
			local surfaceTop = (CarConfig.TOP_SPEED + CarController.speedPickups * CarConfig.SPEED_PICKUP_BONUS) * hopSurfaceFactor
			local ns = TrickRules.hopAirSpeed(hs, surfaceTop, dt, CarConfig.COAST_DECEL, CarConfig.OVERSPEED_DECAY)
			if ns < hs and hs > 1e-3 then
				hv *= ns / hs
			end
		end
		velocity = Vector3.new(hv.X, velocity.Y, hv.Z)
		up = safeUnit(up:Lerp(Vector3.yAxis, expAlpha(CarConfig.AIR_LEVEL_RESPONSE, dt)), Vector3.yAxis)
		forward = safeUnit(onPlane(forward, up), forward)
		CarController.speed = velocity:Dot(safeUnit(flat(forward), Vector3.new(0, 0, -1)))
		if CarController.drifting and not driftHeld then
			endDrift(true)
		end
	end
	CarController.grounded = grounded

	-- Drift slide angle (body yaw toward the inside of the turn).
	local slideTarget = if CarController.drifting then CarController.driftDir * CarConfig.DRIFT_SLIDE_DEG else 0
	slideDeg += (slideTarget - slideDeg) * expAlpha(CarConfig.DRIFT_SLIDE_RESPONSE, dt)

	-- Integrate, then resolve walls along the move.
	local nextPos = pos0 + velocity * dt + up * correction
	local move = nextPos - pos0
	local moveUp = up * move:Dot(up)
	local moveFlat = move - moveUp
	local flatLen = moveFlat.Magnitude
	if flatLen > 1e-4 then
		local dir = moveFlat / flatLen
		local side = safeUnit(dir:Cross(up), Vector3.xAxis)
		local base = pos0 + up * CarConfig.WALL_RAY_LIFT
		local reach = CarConfig.HALF_LENGTH
		local best: RaycastResult? = nil
		local bestAllowed = flatLen
		for _, lateral in { 0, CarConfig.HALF_WIDTH * 0.85, -CarConfig.HALF_WIDTH * 0.85 } do
			local r = workspace:Raycast(base + side * lateral, dir * (reach + flatLen + CarConfig.WALL_CLEARANCE), wallParams)
			if r and isWallNormal(r.Normal, up) then
				local allowed = r.Distance - reach - CarConfig.WALL_CLEARANCE
				if allowed < bestAllowed then
					best = r
					bestAllowed = allowed
				end
			end
		end
		if best then
			local hit = best :: RaycastResult
			if isLethal(hit.Instance) and CarController.invulnTimer <= 0 then
				CarController.beginRespawn("LethalLava", hit.Normal)
				return
			end
			local n = safeUnit(onPlane(hit.Normal, up), -dir)
			local impact = -dir:Dot(n)
			local class = CarConfig.classifyWallHit(impact, CarController.speed)
			local travel = math.max(0, bestAllowed)
			local along = safeUnit(forward - n * forward:Dot(n), side)
			if class == "Deflect" then
				-- Glancing: slide along the wall, scrape off a little speed.
				if forward:Dot(n) < 0 then
					forward = along
				end
				CarController.speed *= 1 - CarConfig.WALL_SCRAPE_LOSS * impact
				lastWallTouch = os.clock() -- a scrape is never a near miss (StyleSense)
				local slideDir = safeUnit(dir - n * dir:Dot(n), along)
				nextPos = pos0 + dir * travel + slideDir * (flatLen - travel) * (1 - impact) + moveUp
				if bumpCooldown <= 0 then
					impactSparks(hit.Position, n, 8)
					CarController.addTrauma(Mods.GroundFxRules.SCRAPE_TRAUMA * (0.5 + impact)) -- tiny shake on a scrape
					bumpCooldown = 0.12
					Mods.Sfx.play("wall_scrape", 0.9 + math.random() * 0.2, 0.25 + 0.4 * (1 - impact))
				end
			elseif class == "Spin" and CarController.invulnTimer <= 0 then
				forward = along
				nextPos = pos0 + dir * travel + moveUp
				CarController.spinOut("WallSpin", nil, hit.Position, n)
			elseif class ~= "None" then
				-- Steep bump: big speed loss; nearly head-on bounces back, otherwise the nose is turned along the wall.
				lastWallTouch = os.clock()
				local before = CarController.speed
				if impact >= CarConfig.WALL_HEADON_DOT then
					CarController.speed = -math.sign(before) * math.max(6, math.abs(before) * CarConfig.WALL_BUMP_BACK)
				else
					forward = safeUnit(forward:Lerp(along, 0.6), along)
					CarController.speed = before * CarConfig.WALL_BUMP_KEEP
				end
				nextPos = pos0 + dir * travel + moveUp
				local cue = Mods.SfxRules.wallCue(wallContact, os.clock(), math.abs(before), impact)
				if cue == "wall_bump" and bumpCooldown <= 0 then
					bumpCooldown = 0.25
					impactSparks(hit.Position, n, 16)
					Mods.Sfx.play("wall_bump", 0.92 + math.random() * 0.13, 0.4 + 0.5 * impact)
					CarController.addTrauma(0.22 * impact)
					LocalPlayer:SetAttribute("WallBumps", ((LocalPlayer:GetAttribute("WallBumps") :: number?) or 0) + 1)
				elseif cue == "wall_scrape" and bumpCooldown <= 0 then
					-- Contact continues: hand off to the scrape instead of repeating the bump.
					bumpCooldown = 0.3
					Mods.Sfx.play("wall_scrape", 0.9 + math.random() * 0.2, 0.3 + 0.3 * impact)
				end
			end
			if CarController.grounded then
				velocity = forward * CarController.speed
			else
				velocity -= n * math.min(0, velocity:Dot(n)) * 1.2
			end
		end
	end

	-- Push out of walls the body overlaps sideways (drift slides, corners).
	local bodyRight = safeUnit(bodyFwd:Cross(up), Vector3.xAxis)
	for _, alongOff in { CarConfig.HALF_LENGTH * 0.55, -CarConfig.HALF_LENGTH * 0.55 } do
		for _, s in { 1, -1 } do
			local origin = nextPos + up * CarConfig.WALL_RAY_LIFT + bodyFwd * alongOff
			local r = workspace:Raycast(origin, bodyRight * s * (CarConfig.HALF_WIDTH + CarConfig.WALL_CLEARANCE), wallParams)
			if r and isWallNormal(r.Normal, up) then
				local pen = CarConfig.HALF_WIDTH + CarConfig.WALL_CLEARANCE - r.Distance
				nextPos += safeUnit(onPlane(r.Normal, up), -bodyRight * s) * pen
				lastWallTouch = os.clock()
			end
		end
	end

	-- Never fall through the road in one long frame: clamp a descent to the first surface under the step.
	if not CarController.grounded and velocity.Y < 0 then
		local drop = math.max(0, pos0.Y - nextPos.Y) + CarConfig.RIDE_HEIGHT + 0.5
		local r = workspace:Raycast(Vector3.new(nextPos.X, pos0.Y, nextPos.Z), Vector3.new(0, -drop, 0), groundParams)
		if r and not isWallNormal(r.Normal, Vector3.yAxis) and r.Position.Y + CarConfig.RIDE_HEIGHT > nextPos.Y then
			nextPos = Vector3.new(nextPos.X, r.Position.Y + CarConfig.RIDE_HEIGHT, nextPos.Z)
		end
	end

	-- Recovery checks: kill height, water depth, stranded off the route. Out of a battle (BattleOut: spectating) none
	-- of them runs (trap audit X-03): the car stays where it went out instead of being put back on its last pad.
	local battleOut = LocalPlayer:GetAttribute("BattleOut") == true
	if CarController.grounded and nextPos.Y > killY then
		lastGroundedPos = nextPos
	elseif battleOut and nextPos.Y < killY then
		-- Nothing respawns a spectator's car (X-03), so one that slipped under the world (the tide basin) is held where
		-- it last stood instead of falling to the destroy height (Studio probe: y -493).
		nextPos = lastGroundedPos or Vector3.new(nextPos.X, killY + 40, nextPos.Z)
		velocity = Vector3.zero
		CarController.speed = 0
	end
	if CarController.invulnTimer <= 0 and not battleOut then
		if nextPos.Y < killY then
			CarController.beginRespawn("Fell", Vector3.yAxis)
		else
			local wasShallow = inShallowWater
			inShallowWater = false
			waterSurfaceY = nil
			-- Water is the terrain sea (a ray, Terrain only) or the battle tide (X-02: the tide part is CanQuery off, so
			-- only its published level shows it), whichever is deeper. The tide gives the same slowdown, entry crown,
			-- sink and splash as the sea, so a tide drown is no longer a dry car popping across the arena.
			local wr = workspace:Raycast(nextPos + Vector3.yAxis * 12, Vector3.new(0, -(12 + CarConfig.RIDE_HEIGHT + 4), 0), waterParams)
			local seaY = if wr and wr.Material == Enum.Material.Water then wr.Position.Y else nil
			local tideY = tideLevelAt(nextPos)
			local depth, source = RespawnRules.waterDepth(nextPos.Y - CarConfig.RIDE_HEIGHT, seaY, tideY)
			if depth > CarConfig.WATER_SINK_DEPTH then
				CarController.beginRespawn("Water", Vector3.yAxis, false, source == "tide")
			elseif depth > 0.3 then
				inShallowWater = true
				waterSurfaceY = if source == "tide" then tideY else seaY
				if not wasShallow and math.abs(CarController.speed) > 20 then
					local surfaceY = if source == "tide" then tideY else seaY
					Vfx.onWaterEntry(Vector3.new(nextPos.X, surfaceY or nextPos.Y, nextPos.Z)) -- the crown on the water line where the car drove in
					Mods.Sfx.play("splash_small", 0.9 + 0.3 * math.min(1, math.abs(CarController.speed) / 150), 0.57)
				end
			end
		end
		routeCheckClock -= dt
		if routeCheckClock <= 0 then
			routeCheckClock = 0.25
			local root = Mods.TrackRegistry.getRoot()
			local dropAttr = if root then root:GetAttribute("CarOffTrackDrop") else nil
			local drop = if type(dropAttr) == "number" then dropAttr else CarConfig.OFFTRACK_DROP
			local stranded = false
			-- A battle arena is off the route by design (BattleCore also zeroes CarOffTrackDrop there).
			local wrongWay = false
			if RaceAttr.mine("RaceMode") ~= "battle" then
				local station, point, tangent, courseDist = Mods.SplineUtils.projectPosition(nextPos, LocalPlayer:GetAttribute("Station") :: number?)
				-- G8: the line the car is on. On an alternate ledge (ISLAND-2 Alt1, HUB-0 AltCove, SPACE-4 Alt1) the
				-- stranded test measures the drop from that line, never from the main road it runs beside or under.
				local _, trackLength = Mods.SplineUtils.loadWaypoints()
				local lines = Mods.RouteBranch.load(Mods.TrackRegistry.getRoot(), 0)
				local line = Mods.RouteBranch.pick(lines, nextPos, (nextPos - point).Magnitude, branchId, station, trackLength)
				local id = if line then line.id else nil
				if id ~= branchId then
					branchId = id
					LocalPlayer:SetAttribute("RouteBranch", id)
					print(string.format("[SkyRally][CAR] route branch %s at station %.0f", tostring(id or "main"), station))
				end
				if drop > 0 and CarController.grounded and offTrackFlag then
					local refY = point.Y
					if line then
						local _, _, onLine = Mods.RouteBranch.nearest(line, nextPos)
						refY = onLine.Y
					end
					stranded = (refY + CarConfig.RIDE_HEIGHT) - nextPos.Y > drop
				end
				-- Reverse v2: the car WRONG WAY sign (a sign only: never steers, slows or rescues). Main route, near it, in a
				-- running race; the travel direction (the tail when backing up) against the course tangent.
				local racingNow = Mods.AssistRules.racingPhase(Mods.HudPhase.phase()) and LocalPlayer:GetAttribute("RaceFinished") ~= true
				if racingNow and id == nil and courseDist < 120 and not CarController.respawning then
					local dir = flat(forward) * (if CarController.speed < 0 then -1 else 1)
					local err = ReverseRules.yawErrDeg(dir.X, dir.Z, tangent.X, tangent.Z)
					wrongWay = ReverseRules.stepWrongWay(reverseState, err, CarController.speed, 0.25)
					-- The chevron points the way to turn the NOSE (FlightController's convention: -yawErr).
					local nose = flat(forward)
					wrongWayAngle = -ReverseRules.yawErrDeg(nose.X, nose.Z, tangent.X, tangent.Z)
				else
					reverseState.awayT = 0
				end
			end
			wrongWayShown = wrongWay
			offTrackTimer = if stranded then offTrackTimer + 0.25 else 0
			if offTrackTimer >= CarConfig.OFFTRACK_TIME then
				offTrackTimer = 0
				CarController.beginRespawn("OffTrack", Vector3.yAxis)
			end
		end
	end

	-- Stuck watchdog (G5, H0-05 a): trying to move (gas or steer held; touch auto-gas counts) without leaving an 8-stud
	-- ball. Every mode, which covers the hub and the battles, where the off-track rescue is off: the RESPAWN button
	-- pulses from STUCK_OFFER, and at STUCK_AUTO the rescue runs (no life lost in a battle: it is not a drown).
	-- Reverse v2: the car WRONG WAY sign, refreshed every frame (its pulse), never during a respawn or a battle out.
	if wrongWayShown and not CarController.respawning and not battleOut and CarController.invulnTimer <= 0 then
		Mods.CourseArrow.set(true, wrongWayAngle, 0.5)
		arrowUp = true
	elseif arrowUp then
		Mods.CourseArrow.set(false, 0, 0)
		arrowUp = false
	end
	local trying = RespawnRules.isTrying(throttle, steerIn)
	-- A spin-out freezes the watch (no time, no reset): a car bouncing off a kerb hard enough to spin is not unstuck.
	-- OWNER RULE (wall and mountain driving untouched): a climbing car keeps the stage-v21 watch, where letting go of
	-- the controls or a spin-out resets it (RespawnRules.isClimbing), so the idle grace and spin freeze never make a
	-- climb more likely to be rescued.
	local climbing = RespawnRules.isClimbing(CarController.grounded, up.Y)
	local watchActive = not CarController.respawning and not battleOut and CarController.rescueAllowed()
		and not (climbing and (CarController.spinning or not trying))
	local verdict = RespawnRules.stepWatch(stuckWatch, nextPos, trying, watchActive, dt, CarController.spinning)
	CarController.stuckOffer = verdict == "offer"
	if verdict == "auto" then
		CarController.requestManualRespawn("Stuck")
	end

	-- Commit: one authoritative position, written to the Hull with the body rotation.
	simPos = nextPos
	local bodyFwdFinal = rotateAbout(forward, up, -math.rad(slideDeg + spinAngle))
	local cf = frame(nextPos, bodyFwdFinal, up)
	writeHull(cf, velocity)

	if not CarController.respawning then
		evaluateTriggers(nextPos)
		-- REMARKABLE 16: near-miss sparks and the lava-skim wake (side rays at 20 Hz above 0.8 x top speed, a down
		-- ray at 10 Hz), judged on the travel frame (not the drift-slid body).
		if Mods.StyleSense.step(dt, "car", hull, frame(nextPos, forward, up), math.abs(CarController.speed), CarConfig.TOP_SPEED, lastWallTouch) then
			CarController.addTrauma(0.06)
		end
	end
	updateLocalVisuals(dt, throttle)
	updateCamera(dt)
	mirrorToFlightController(throttle)
	local altitude = if RaceAttr.mine("ActiveZone") == "DINO" then nextPos.Y else 1000
	SoundJuice.step(dt, math.abs(CarController.speed), altitude, CarController.boostState, throttle)
	syncToServer(dt, cf)

	LocalPlayer:SetAttribute("CarSpeed", math.floor(math.abs(CarController.speed)))
	LocalPlayer:SetAttribute("CarGrounded", CarController.grounded)
	LocalPlayer:SetAttribute("CarDriftLevel", CarController.driftLevel)
end

-- Substeps of at most 0.05 s up to 0.25 s per frame: the wheel probes and gravity arc need short steps, and a slow
-- device must not drive in slow motion against server-side real-time bots (2026-10-18 low-fps regression).
local function stepCar(rawDt: number)
	local total = math.clamp(rawDt, 1 / 240, 0.25)
	local n = math.max(1, math.ceil(total / 0.05))
	for _ = 1, n do
		stepCarOnce(total / n)
	end
end

-- ---------------------------------------------------------------- remote events
local function onRaceEvent(eventType: string, data: any)
	if type(data) ~= "table" then
		return
	end
	if eventType == "CheckpointPassed" then
		if typeof(data.respawnCFrame) == "CFrame" then
			setCheckpoint(data.respawnCFrame)
		end
		return
	end
	if not CarController.car then
		return
	end
	if eventType == "CarMounted" or eventType == "RaceReset" then
		if typeof(data.startCFrame) == "CFrame" then
			resetRaceState(data.startCFrame)
			CarController.invulnTimer = 2.0
		end
	elseif eventType == "CheckpointRespawn" then
		if typeof(data.cframe) == "CFrame" then
			setCheckpoint(data.cframe)
			local prev = lastRespawnCF
			if CarController.respawning or fadePhase == "wait" then
				respawnTarget = data.cframe
			elseif
				prev
				and os.clock() - lastRespawnClock < LATE_REPLY_WINDOW
				and (prev.Position - data.cframe.Position).Magnitude < 1
				and simPos ~= nil
				and ((simPos :: Vector3) - data.cframe.Position).Magnitude
					< 40 + CarConfig.maxHorizontalSpeed() * (os.clock() - lastRespawnClock)
			then
				-- Late answer to a respawn the client already completed on the cached checkpoint: nothing to do. Only
				-- while the car can have driven there from that frame: in Studio the car sat under the hub's coordinates
				-- and every boundary return to the same pad was dropped here as "late", so it fell out of the world.
				return
			else
				-- Server-ordered respawn (not asked for: a tide drown, an arena boundary return, a server-side rescue).
				-- X-02: never a silent pop. The same fade-out as a crash, with the splash when the car is in water (or
				-- the server says it drowned) and a poof otherwise, then set down on the server's frame.
				local pos = simPos or (if CarController.hull then (CarController.hull :: BasePart).Position else data.cframe.Position)
				local tideY = tideLevelAt(pos)
				local wet = data.reason == "Water" or inShallowWater or (tideY ~= nil and tideY > pos.Y - CarConfig.RIDE_HEIGHT)
				CarController.beginRespawn(if wet then "Water" else "Server", Vector3.yAxis, true, tideY ~= nil, data.cframe)
			end
		end
	elseif eventType == "RaceFinished" then
		local h = CarController.hull
		if h then
			Vfx.onFinish(h.Position + h.CFrame.LookVector * 30 + Vector3.new(0, 6, 0))
		end
	end
end

local function onFlightStateClient(action: string, data: any)
	if action ~= "RequestCorrection" or type(data) ~= "table" or not CarController.car then
		return
	end
	if typeof(data.cframe) == "CFrame" then
		CarController.corrections += 1
		LocalPlayer:SetAttribute("CarCorrections", CarController.corrections)
		local s = if type(data.speed) == "number" then math.min(math.abs(CarController.speed), data.speed) else 0
		cancelBoost()
		placeAt(data.cframe, s, false)
		CarController.addTrauma(0.15)
	end
end

-- Item effects for the car (same kinds and payloads as FlightController.applyItemEffect): "boost" {seconds, speed,
-- level}, "hit" {seconds} (spin-out), "magnet" {target, seconds, pull} (magnet v2: steer + speed toward the closest
-- racer the server locked, CarController step). Values are clamped:
-- a bad packet must not launch the car.
function CarController.applyItemEffect(kind: string, data: any)
	local d = if type(data) == "table" then data else {}
	if kind == "boost" then
		local seconds = math.clamp(tonumber(d.seconds) or CarConfig.PAD_BOOST_DURATION, 0.1, 8)
		local speed = math.clamp(tonumber(d.speed) or CarConfig.PAD_BOOST_SPEED, CarConfig.TOP_SPEED, CarConfig.ITEM_BOOST_MAX_SPEED)
		if type(d.factor) == "number" then
			-- Items v4: a cruise-factor lift (Golden Wings, coins) scales the car's own top speed.
			speed = math.clamp(CarConfig.TOP_SPEED * math.clamp(d.factor, 1, 1.3), CarConfig.TOP_SPEED, CarConfig.ITEM_BOOST_MAX_SPEED)
		end
		if type(d.auto) == "number" and d.auto > 0 then
			itemAutoTimer = math.clamp(d.auto, 0, 5) -- Rocket Rush: the line follower drives it
		end
		local level = tonumber(d.level) or 1
		CarController.triggerBoost("Item", speed, seconds, if level >= 3 and not d.factor then "Overcharge" else "Standard")
	elseif kind == "coins" then
		-- v38 Coin Pouch / Item Steal fallback: race coins straight into the count (capped like Speed pods).
		CarController.speedPickups = math.min(CarConfig.MAX_SPEED_PICKUPS, CarController.speedPickups + math.max(0, math.floor(tonumber(d.count) or 0)))
		LocalPlayer:SetAttribute("SpeedPickups", CarController.speedPickups)
	elseif kind == "slow" then
		itemSlowTimer = math.clamp(tonumber(d.seconds) or 1, 0, Mods.ItemRules.SLOW.maxSeconds)
		itemSlowFactor = math.clamp(tonumber(d.factor) or 1, Mods.ItemRules.SLOW.floor, 1)
	elseif kind == "hit" then
		-- G2 / H0-07: the server scored this hit (it sends none inside its respawn window). Only a stale one, decided
		-- before the respawn stamp and still in flight, is dropped; the rest spin the car even inside invulnTimer.
		local untilT = LocalPlayer:GetAttribute("RespawnShieldUntil")
		local shieldLeft = if type(untilT) == "number" then math.max(0, untilT - os.clock()) else 0
		if RespawnRules.clientIgnoresHit(CarController.respawning or fadePhase == "out" or fadePhase == "wait", os.clock() - lastRespawnClock, shieldLeft) then
			return
		end
		CarController.spinOut("ItemHit", math.clamp(tonumber(d.seconds) or 1.2, 0.2, 4), nil, nil, true)
		-- v39: the spiked crate (trap level three) also pops the car into a short hop while it spins (ItemRules.TRAP_KNOCK_VY).
		local knock = if d.source == "trap" then Mods.ItemRules.trapKnockVy(d.form) else 0
		if knock > 0 and CarController.grounded and not CarController.respawning then
			velocity += up * math.clamp(knock, 0, 60)
			CarController.grounded = false -- next probe pass resolves airborne, like a hop
			CarController.airTime = 0
			squash = math.min(squash, -0.45)
			squashVel = 0
		end
		-- v38 (Mario Kart 8): a hit spills coins (ItemRules.COIN_HIT_LOSS) and the top-speed bonus they gave.
		CarController.speedPickups = math.max(0, CarController.speedPickups - Mods.ItemRules.COIN_HIT_LOSS)
		LocalPlayer:SetAttribute("SpeedPickups", CarController.speedPickups)
	elseif kind == "magnet" then
		local target = d.target
		if typeof(target) == "Instance" and target:IsA("Model") then
			magnetTarget = target
			magnetTimer = math.clamp(tonumber(d.seconds) or 2.5, 0.1, 5)
			magnetPull = math.clamp(tonumber(d.pull) or 55, 0, 90)
		end
	end
end

-- The car's only item-effect path (see init): ItemRemote "ItemEffect" for this player, applied while a car is bound.
local function onItemEvent(eventType: string, kind: any, payload: any)
	if eventType == "ItemEffect" and CarController.car and type(kind) == "string" then
		CarController.applyItemEffect(kind, payload)
	end
end

function CarController.init()
	if CarController.initialized then
		return
	end
	CarController.initialized = true
	-- FlightController's RenderStepped already calls Vfx.step with the fields mirrored above; only a build without
	-- it steps Vfx here, so speed lines never advance twice per frame.
	ownsVfxStep = not FlightController.initialized
	if ownsVfxStep then
		SoundJuice.init()
		Vfx.init()
	end
	refreshFilters()
	ensureFade()

	-- Item effects reach the car through its own ItemRemote listener (below). ItemClient deliberately skips
	-- FlightController.applyItemEffect while a "Car_<name>" model exists, so routing through that hook alone left the
	-- car with no item effects at all. The hook is still wrapped so that, should ItemClient forward a car effect again,
	-- it is swallowed rather than applied twice: exactly one path applies each effect.
	local fc = FlightController :: any
	if type(fc.applyItemEffect) == "function" then
		local planeApply = fc.applyItemEffect
		fc.applyItemEffect = function(kind: string, data: any)
			if not CarController.car then
				planeApply(kind, data)
			end
		end
	end

	-- The RESPAWN button, Backspace and gamepad View all call FlightController's entry points (RaceUI and the input
	-- binding live there); while a car is bound they are the car's.
	local planeManual = fc.requestManualRespawn
	fc.requestManualRespawn = function(source: string?): boolean
		if CarController.car then
			return CarController.requestManualRespawn(source)
		end
		return planeManual(source)
	end
	local planeStatus = fc.respawnStatus
	fc.respawnStatus = function(): (boolean, number, boolean)
		if CarController.car then
			return CarController.respawnStatus()
		end
		return planeStatus()
	end

	task.spawn(function()
		-- Stale-respawn root cause (Studio, ISLAND-2 water battle under load): the server builds the boot map before it
		-- creates FlightStateRemote/RaceEventRemote (60-70 s under heavy CPU), and SkyRallyRemotes already exists, so
		-- the old 5 s WaitForChild gave up. The car then never heard RaceReset or CheckpointRespawn, never sent
		-- RequestRespawn, and every respawn timed out onto the frame cached at the first bind: the hub plaza, from
		-- which it fell out of the cleared world in a loop. Wait as long as it takes (one warning per 10 s).
		local function waitForever(parent: Instance, name: string): Instance
			local found = parent:WaitForChild(name, 10)
			while not found do
				warn("[SkyRally][CAR] still waiting for " .. name .. " (server still building the map?)")
				found = parent:WaitForChild(name, 10)
			end
			return found :: Instance
		end
		local remotes = waitForever(ReplicatedStorage, "SkyRallyRemotes")
		local fsr = waitForever(remotes, "FlightStateRemote") :: RemoteEvent
		local rer = waitForever(remotes, "RaceEventRemote") :: RemoteEvent
		flightStateRemote = fsr
		raceEventRemote = rer
		rer.OnClientEvent:Connect(onRaceEvent)
		fsr.OnClientEvent:Connect(onFlightStateClient)
		-- ItemService creates its remote after the map builds; keep waiting quietly (as ItemClient does).
		local itemRemote: Instance? = nil
		while not itemRemote do
			itemRemote = remotes:WaitForChild("ItemRemote", 10)
		end
		if itemRemote and itemRemote:IsA("RemoteEvent") then
			itemRemote.OnClientEvent:Connect(onItemEvent)
		end
	end)

	LocalPlayer:GetAttributeChangedSignal("InputMode"):Connect(showCarHint)
	-- A respawned character is a new model: the ray filters must exclude it (its late-loading accessories are queryable
	-- and sit inside the car, where the wall rays and wheel probes run).
	LocalPlayer.CharacterAdded:Connect(function()
		task.defer(refreshFilters)
	end)
	-- QA (Studio only): client command bar `game.Players.LocalPlayer:SetAttribute("CarQATeleportOffset",
	-- Vector3.new(400, 0, 0))` jumps the car the way an exploit would (simulated position and hull together), so the
	-- server validator's correction can be provoked on purpose: expect "[SkyRally][CAR] correction ..." in Output and
	-- the car back on its last valid frame.
	if RunService:IsStudio() then
		LocalPlayer:GetAttributeChangedSignal("CarQATeleportOffset"):Connect(function()
			local off = LocalPlayer:GetAttribute("CarQATeleportOffset")
			local hull = CarController.hull
			if typeof(off) == "Vector3" and simPos and hull then
				simPos = (simPos :: Vector3) + off
				writeHull(hull.CFrame + off, velocity)
				LocalPlayer:SetAttribute("CarQATeleportOffset", nil)
				print(string.format("[SkyRally][CAR] QA teleport offset=(%.0f,%.0f,%.0f)", off.X, off.Y, off.Z))
			end
		end)
	end
	RaceAttr.changed("ActiveTrackId", function()
		killYReady = false
	end)

	RunService:BindToRenderStep("SkyRallyCarStep", Enum.RenderPriority.Camera.Value + 2, Mods.Prof.wrap("SR_CarStep", stepCar))
	if ownsVfxStep then
		RunService.RenderStepped:Connect(Mods.Prof.wrap("SR_CarVfx", function(dt: number)
			if CarController.car then
				Vfx.step(dt, { speed = math.abs(CarController.speed), boost = CarController.boostState, sharp = CarController.drifting })
			end
		end))
	end
end

return CarController
