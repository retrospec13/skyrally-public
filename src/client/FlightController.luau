--!strict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr")) -- economy v3 phase 2b: this player's own race GO time
local ItemRules = require(Shared:WaitForChild("ItemRules"))
-- The magnet reads another player's hull at the engine's replicated pose, never RacerView's stream draw (remote-smooth).
local PlayerStreamRules = require(Shared:WaitForChild("PlayerStreamRules"))
local PodLocal = require(script.Parent:WaitForChild("PodLocal"))
local TriggerIndex = require(script.Parent:WaitForChild("TriggerIndex"))
local SoundJuice = require(script.Parent:WaitForChild("SoundJuice"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))
local Settings = require(script.Parent:WaitForChild("Settings")) -- audit H13: camera shake toggle
local Vfx = require(script.Parent:WaitForChild("Vfx"))
local GroundFx = require(script.Parent:WaitForChild("GroundFx"))
local AirFxRules = require(Shared:WaitForChild("AirFxRules"))
local TrickRules = require(Shared:WaitForChild("TrickRules"))
local DodgeRules = require(Shared:WaitForChild("DodgeRules"))
local MissileRules = require(Shared:WaitForChild("MissileRules"))
local TrickJuice = require(script.Parent:WaitForChild("TrickJuice"))
-- Way-out rules (trap audit G5, G4, D4-02 fix 4): manual respawn cooldown, stuck watchdog, crash-loop guard.
local RespawnRules = require(Shared:WaitForChild("RespawnRules"))
-- Style lane (REMARKABLE Batch 2 items 16-17) and the course leash / alternate lines (trap audit G5.4, G8).
local StyleChain = require(script.Parent:WaitForChild("StyleChain"))
local StyleSense = require(script.Parent:WaitForChild("StyleSense"))
local CourseArrow = require(script.Parent:WaitForChild("CourseArrow"))
local VehicleMotion = require(script.Parent:WaitForChild("VehicleMotion")) -- every plane's propeller (this one's live speed)
local RouteBranch = require(Shared:WaitForChild("RouteBranch"))
local QASteerRules = require(Shared:WaitForChild("QASteerRules")) -- Studio-only QA steering hook (QAFollowLine / QASteer / QAThrottle)
local SailGateRules = require(Shared:WaitForChild("SailGateRules")) -- FOREST-1: a sail-gap ring acts only while lit
-- Flight modes (Mario Kart default / Free driving), the bead mist and RETURN to course (docs/design/FLIGHT_GUIDE.md 12).
local FlightGuideRules = require(Shared:WaitForChild("FlightGuideRules"))
local FlightGuide = require(script.Parent:WaitForChild("FlightGuide"))
local AssistRules = require(Shared:WaitForChild("AssistRules"))
local HudPhase = require(script.Parent:WaitForChild("HudPhase")) -- the auto throttle acts in the "race" phase only

local FlightController = {}

-- Uploaded procedural audio asset IDs (granted to Universe 0)
local SOUND_IDS = {
	EngineLoop = "rbxassetid://91840597129266",
	BoostWhoosh = "rbxassetid://88248374325910",
	CrashThud = "rbxassetid://85851839192561",
	LapFanfare = "rbxassetid://86367042177551",
}

local engineSound: Sound? = nil
local boostSound: Sound? = nil
local crashSound: Sound? = nil
local fanfareSound: Sound? = nil

-- Exposed state for RaceUI and SelfTest probes
FlightController.initialized = false
FlightController.plane = nil :: Model?
FlightController.hull = nil :: BasePart?
FlightController.currentSpeed = PlaneConfig.BASE_SPEED
FlightController.pitchDeg = -4
FlightController.yawDeg = 0
FlightController.bankDeg = 0
FlightController.throttleInput = 0 -- -1..1
FlightController.steerInput = Vector2.zero -- X = roll/yaw (-1..1), Y = pitch (-1..1)
FlightController.autoThrottle = true
-- L03: steering assist is blended under player input (player always wins per axis); toggled with autoThrottle on the HUD.
FlightController.steerAssist = true
-- The one switch for ASSIST (auto throttle + steering assist): RaceUI's chip / T key / the gear panel's ASSIST row call it
-- through Settings (saved in the profile). It mirrors the AutoThrottle player attribute the HUD reads; the attribute is also
-- how the saved value arrives from the server, so a change from either side lands in the same two flags.
function FlightController.setAssist(on: boolean)
	FlightController.autoThrottle = on
	FlightController.steerAssist = on
	if LocalPlayer:GetAttribute("AutoThrottle") ~= on then
		LocalPlayer:SetAttribute("AutoThrottle", on)
	end
end
FlightController.assistSteer = Vector2.zero
FlightController.assistWeight = 1
FlightController.sharpBank = false
FlightController.boostState = "None" -- "None" | "Standard" | "Overcharge"
FlightController.boostTimer = 0
FlightController.speedPickups = 0
FlightController.crashing = false
FlightController.crashTimer = 0
FlightController.invulnTimer = 2.0
FlightController.lastRespawnAt = -math.huge -- os.clock of the last completed respawn (ItemClient: stale item hits)
FlightController.lastCheckpointCF = CFrame.new(0, 146, -10)
FlightController.firstInputTime = 0
FlightController.joinClock = os.clock()

-- Touch / Mobile input state set by RaceUI two-thumb zones
FlightController.mobileSteer = Vector2.zero
FlightController.mobileThrottle = 0 -- -1, 0, or 1
FlightController.mobileSharpBank = false
FlightController.padSideX = 0 -- the side of the touch steer pad a finger is on, -1..1 (RaceUI): a tap on the pad counts as a press
FlightController.padHeld = false -- a finger is on the touch steer pad (RaceUI): the hold-to-drive input (AssistRules)

-- Item hooks (TEST_LIST_LAUNCH L07). The server decides every item outcome (ItemService + kit/ItemEffects); this
-- client only asks to fire (one "Use" per press; the server ignores any payload) and applies what the server sends
-- back through ItemClient, because this client owns the hull's transform (network ownership).
FlightController.itemStunTimer = 0 -- spin-out left (missile/trap hit): no steering, speed capped
FlightController.itemStunTotal = 0
FlightController.itemBoostTimer = 0 -- blue item: target speed floor for this long
FlightController.itemBoostSpeed = 0
FlightController.itemMagnetTimer = 0 -- rainbow item (magnet v2): carried to the closest racer the server locked
FlightController.itemMagnetPull = 0
FlightController.itemMagnetRange = 0
FlightController.itemMagnetTarget = nil :: Model?
-- Items v4: a slow (Frost Shot, Coin Burst, patches) caps the speed at BASE_SPEED x itemSlowFactor; Rocket Rush flies
-- the line itself (the AutoPilot follower) for itemAutoTimer seconds.
FlightController.itemSlowTimer = 0
FlightController.itemSlowFactor = 1
FlightController.itemAutoTimer = 0
-- Magnet v2 hook (set by ItemClient): contact with the target (the pull has just ended; CarController calls it too).
FlightController.onMagnetArrive = nil :: ((target: Model) -> ())?

-- Game-feel camera trauma & visual hit-stop state (never affects simulated physics hull)
FlightController.cameraTrauma = 0
FlightController.hitStopTimer = 0
local traumaClock = 0
local appliedFovKick = 0 -- Vfx.fovKick() already added to the camera FOV (removed before smoothing)

function FlightController.addTrauma(amount: number)
	FlightController.cameraTrauma = math.clamp(FlightController.cameraTrauma + amount, 0, 1)
end

function FlightController.triggerHitStop(duration: number)
	FlightController.hitStopTimer = math.max(FlightController.hitStopTimer, duration)
end

local throttleReleaseDuration = 0

-- Barrel roll and the plane's start (REMARKABLE items 6 and 7, shared/TrickRules). The roll is visual: it is
-- multiplied into the hull's orientation last, so LookVector (the flight path), the camera and the server's view of
-- the plane's speed are unchanged. A roll through a booster ring lengthens that ring's boost (THREADED!).
FlightController.rollTimer = 0
local rollDir = 1
local rollCooldown = 0
local rollEndClock = -math.huge
local rollTap = DodgeRules.new() -- dodge = double tap left / right (shared/DodgeRules)
local rawDodgeX = 0 -- this frame's raw direction for it, set by readCombinedInputs
local lastSharpPress = false -- grid: any sharp-bank input (wing wobble)
local THREAD_GRACE = 0.15 -- a roll that ended this recently still threads the ring
local planeStart = TrickRules.newStart()
local planeStartGo: number? = nil
local gridRevCueFor: number? = nil -- the RaceGoTime the grid rev blip already played for
local lastScrapeSfx = 0 -- os.clock() of the last wall-scrape cue (the slide runs every frame)
local lastScrapeSparks = 0 -- os.clock() of the last wall-scrape spark burst (AirFxRules.SCRAPE_INTERVAL apart)
local planeStartPending = false
local planeFloodTimer = 0
local planeFloodPuff = 0
local gridWobbleClock = -math.huge
local gridWobbleDir = 1
local gridRev = 0

-- Course leash (trap audit G5.4, PlaneConfig.leashStep) and alternate lines (G8, shared/RouteBranch). courseDist is the
-- plane's distance to the nearest course line at flight height (main or alternate), sampled by the assist every frame
-- it runs and at PlaneConfig.LEASH_HZ otherwise; courseTarget is the point ahead on the line the plane is on.
local leash = PlaneConfig.newLeash()
local courseClock = 0
local courseDist = 0
local courseTarget: Vector3? = nil
local courseFresh = false -- the assist sampled the course this frame
local branchId: string? = nil
local lastWallTouch = -math.huge -- os.clock() of the last slide/deflect off a surface (a scrape is not a near miss)
local holdCleared = false -- the grid / curtain hold already cleared the style effects and the leash
local lastShownCourseDist = -1
-- The last sampleCourse result (the guide draws along this line): main-route station, picked line, distance along it.
local sampleStation = 0
local sampleLine: RouteBranch.Line? = nil
local sampleAlong = 0

-- Flight modes (FLIGHT_GUIDE.md 12): the state machine, the RETURN request in flight and the frame the server sent.
local offState = FlightGuideRules.newOff()
local offVerdict = "inside"
local offSample: FlightGuideRules.Sample = { dist = 0, inPocket = false, station = 0, trackLength = nil, yawErr = 0 } -- reused
local pocketRoot: Instance? = nil -- allow-pockets of the active track (FlightGuideRules.readPockets), re-read every 2 s
local pocketList: { FlightGuideRules.Pocket } = {}
local pocketCheck = -math.huge
local returnPending: { at: number, reason: string }? = nil
local pendingReturnCF: CFrame? = nil
local lastReturnRequest = -math.huge
local returnFailSeq = 0 -- bumped when a RETURN press is refused or times out (HUD: a quiet notice)
local lastOffAttr: boolean? = nil

local function planeExhaustCF(hull: BasePart): CFrame
	local p = hull.CFrame:PointToWorldSpace(Vector3.new(0, 0, 6.4))
	return CFrame.lookAt(p, p - hull.CFrame.LookVector + Vector3.yAxis * 0.3)
end
local lastRingCooldowns: { [Instance]: number } = {}
local syncAccumulator = 0

local mouseSteerOffset = Vector2.zero
local mouseMovedRecently = 0

local flightStateRemote: RemoteEvent? = nil
local raceEventRemote: RemoteEvent? = nil

-- Way out (trap audit G5, D4-02 fix 4). Manual respawn: the RESPAWN button (HudExtras via RaceUI), Backspace and the
-- gamepad View/Select button all reach FlightController.requestManualRespawn, which CarController wraps while a car
-- is bound. The plane's own rescue is the crash path with a short poof instead of the tumble; the server-side check
-- for a plane is FlightServer's (the plane's respawn frame is its own cached checkpoint, as for every plane crash).
local lastManualRespawn = -math.huge
local lastRespawnClock = -math.huge
local stuckWatch = RespawnRules.newWatch()
local loopGuard = RespawnRules.newLoopGuard()
local rescueGlideNext = false -- the crash being recovered repeats the last one: the respawn gets the rescue glide
FlightController.rescueAssistTimer = 0 -- > 0: the course assist is on whatever the HUD toggle says (RESCUE GLIDE)
FlightController.stuckOffer = false -- HUD: the stuck watchdog offers the rescue (the RESPAWN button pulses)

local function initSounds()
	SoundJuice.init()
	local sf = SoundService:FindFirstChild("SkyRallySounds")
	if sf then
		engineSound = sf:FindFirstChild("EngineHumLoop") :: Sound?
		boostSound = sf:FindFirstChild("BoostWhoosh") :: Sound?
		crashSound = sf:FindFirstChild("CrashThud") :: Sound?
		fanfareSound = sf:FindFirstChild("LapFanfare") :: Sound?
	end
end

-- kind "Finish" plays the finish tada, anything else the lap ding.
function FlightController.playFanfare(kind: string?)
	SoundJuice.triggerFeedback("large", if kind == "Finish" then "Finish" else "Lap")
end

-- Authoritative simulated hull position (see stepFlight); nil until the first step or pose set.
local simPos: Vector3? = nil

local function headingAndPitchFromVector(dir: Vector3): (number, number)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local yaw = 0
	if flat.Magnitude > 0.001 then
		yaw = math.deg(math.atan2(-dir.X, -dir.Z))
	end
	local pitch = math.deg(math.asin(math.clamp(dir.Y, -0.98, 0.98)))
	return yaw, pitch
end

-- Where the plane waits while the server swaps maps under the curtain (workspace.TrackSwitching): the frame it had
-- when the curtain fell, or the last one the server posed it at since. Never the client's own last checkpoint: that
-- snap (hundreds of studs after a finish) tripped the server's anti-teleport correction at every race end (L30).
local switchHoldCF: CFrame? = nil

function FlightController.setPoseFromCFrame(cf: CFrame)
	if switchHoldCF then
		switchHoldCF = cf
	end
	simPos = cf.Position
	FlightController.rollTimer = 0 -- respawn / reset: never carry a half-finished barrel roll
	local yaw, pitch = headingAndPitchFromVector(cf.LookVector)
	FlightController.yawDeg = yaw
	FlightController.pitchDeg = math.clamp(pitch, -45, 45)
	FlightController.bankDeg = 0
	if FlightController.hull then
		FlightController.hull.CFrame = cf
		local lv = FlightController.hull:FindFirstChild("FlightVelocity") :: LinearVelocity?
		if lv then
			lv.VectorVelocity = cf.LookVector * FlightController.currentSpeed
		end
		local ao = FlightController.hull:FindFirstChild("FlightOrientation") :: AlignOrientation?
		if ao then
			ao.CFrame = cf
		end
	end
	-- The seated pilot (server/kit/PilotSeat) is welded to the hull, so moving the hull moved it. A character not yet
	-- welded (the server's mount is a moment behind) is put at the seat so it does not trail across the map.
	local character = LocalPlayer.Character
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	if hrp then
		local weld = hrp:FindFirstChild("PilotWeld")
		local welded = weld ~= nil and weld:IsA("Weld") and weld.Part0 ~= nil and (weld.Part0 :: BasePart):IsDescendantOf(workspace)
		if not welded then
			local plane = FlightController.plane
			local anchor = if plane then plane:GetAttribute("SeatAnchor") else nil
			hrp.CFrame = cf * (if typeof(anchor) == "CFrame" then anchor else CFrame.new(0, 1.35, 0.2))
		end
	end
end

function FlightController.triggerBoost(overcharged: boolean)
	if overcharged then
		FlightController.boostState = "Overcharge"
		FlightController.boostTimer = PlaneConfig.OVERCHARGE_DURATION
		FlightController.currentSpeed = math.max(FlightController.currentSpeed, PlaneConfig.OVERCHARGE_SPEED)
	else
		if FlightController.boostState ~= "Overcharge" then
			FlightController.boostState = "Standard"
		end
		FlightController.boostTimer = math.max(FlightController.boostTimer, PlaneConfig.BOOST_DURATION)
		FlightController.currentSpeed = math.max(FlightController.currentSpeed, PlaneConfig.BOOST_SPEED)
	end
	LocalPlayer:SetAttribute("BoostState", FlightController.boostState)
	if FlightController.hull then
		Vfx.onBoost(FlightController.hull.CFrame, overcharged)
	end
	FlightController.addTrauma(if overcharged then 0.34 else 0.22)
	FlightController.triggerHitStop(if overcharged then 0.045 else 0.025)
	SoundJuice.triggerFeedback("medium", if overcharged then "Overcharge" else "Boost")
end

-- force: a rescue the player asked for (Manual, Stuck) runs through the respawn protection, which only shields against
-- crashes; it plays a short poof instead of the explosion and tumble.
function FlightController.triggerCrash(_reason: string, hitPart: Instance?, force: boolean?)
	if FlightController.crashing or (FlightController.invulnTimer > 0 and not force) then
		return
	end
	-- "Leash": the course leash put a lost plane back (G5.4), a rescue like the RESPAWN button. "Return": RETURN to
	-- course (the server's frame follows the poof, FLIGHT_GUIDE.md 4.3).
	local rescue = _reason == "Manual" or _reason == "Stuck" or _reason == "Leash" or _reason == "Return"
	StyleChain.breakChain(_reason) -- REMARKABLE 17: a crash or a rescue drops the style chain
	StyleSense.stop()
	FlightController.crashing = true
	FlightController.crashTimer = if rescue then 0.45 else PlaneConfig.RESPAWN_DELAY
	FlightController.clearItemEffects()
	FlightController.currentSpeed = 0
	FlightController.boostState = "None"
	FlightController.boostTimer = 0
	LocalPlayer:SetAttribute("Crashing", true)
	LocalPlayer:SetAttribute("LastCrashReason", _reason)
	LocalPlayer:SetAttribute("LastCrashPart", if hitPart then hitPart:GetFullName() else "")
	local h = FlightController.hull
	LocalPlayer:SetAttribute("LastCrashPos", if h then h.Position else Vector3.zero)
	LocalPlayer:SetAttribute("CrashCount", ((LocalPlayer:GetAttribute("CrashCount") :: number?) or 0) + 1)
	if rescue then
		if h then
			Vfx.onRespawn(h.CFrame)
		end
		TrickJuice.play("trick_whoosh", 0.9)
		FlightController.addTrauma(0.15)
		rescueGlideNext = false
		return
	end
	-- Crash-loop guard (D4-02 fix 4): a second crash at the same spot inside the window gets the rescue glide.
	rescueGlideNext = h ~= nil and RespawnRules.noteCrash(loopGuard, h.Position, os.clock())
	if h then
		Vfx.onCrash(h.Position, _reason, -h.CFrame.LookVector)
	end
	FlightController.addTrauma(0.68)
	FlightController.triggerHitStop(0.065)
	SoundJuice.triggerFeedback("large", "Crash")
end

-- serverPlaced: the server already chose and announced this frame (RETURN to course), so no RequestRespawn follows
-- (it would send the plane on to the checkpoint).
function FlightController.completeRespawn(targetCF: CFrame?, serverPlaced: boolean?)
	local cf = targetCF or FlightController.lastCheckpointCF
	CourseArrow.set(false, 0, 0) -- G5.4: a respawn always lands on the course
	FlightGuideRules.startGrace(offState) -- nothing arms (bounds, RETURN, lost) right after landing on the course
	local reason = LocalPlayer:GetAttribute("LastCrashReason")
	FlightController.crashing = false
	FlightController.crashTimer = 0
	FlightController.invulnTimer = PlaneConfig.RESPAWN_INVULN
	lastRespawnClock = os.clock()
	FlightController.lastRespawnAt = lastRespawnClock
	RespawnRules.resetWatch(stuckWatch)
	FlightController.stuckOffer = false
	if rescueGlideNext then
		-- RESCUE GLIDE: the same crash twice running. Longer protection and the course assist on for the stretch that
		-- keeps catching this player, with a golden trail and a callout (a visible helping hand, not another explosion).
		rescueGlideNext = false
		FlightController.invulnTimer = math.max(FlightController.invulnTimer, RespawnRules.LOOP_INVULN)
		FlightController.rescueAssistTimer = RespawnRules.LOOP_INVULN
		Vfx.burst("trickLand", cf, 1.4)
		TrickJuice.callout("RESCUE GLIDE", TrickJuice.GOLD, 1.4)
		LocalPlayer:SetAttribute("RescueGlides", ((LocalPlayer:GetAttribute("RescueGlides") :: number?) or 0) + 1)
		print("[SkyRally][FLIGHT] rescue glide (repeat crash)")
	end
	FlightController.currentSpeed = PlaneConfig.BASE_SPEED
	FlightController.setPoseFromCFrame(cf)
	Vfx.onRespawn(cf)
	Sfx.play("respawn_pop", 1, 0.58)
	local lvC = if FlightController.hull then FlightController.hull:FindFirstChild("FlightVelocity") :: LinearVelocity? else nil
	local aoC = if FlightController.hull then FlightController.hull:FindFirstChild("FlightOrientation") :: AlignOrientation? else nil
	if lvC then
		lvC.Enabled = true
	end
	if aoC then
		aoC.Enabled = true
	end
	LocalPlayer:SetAttribute("Crashing", false)
	FlightController.clearItemEffects()

	if flightStateRemote and not serverPlaced then
		flightStateRemote:FireServer("RequestRespawn", { reason = if type(reason) == "string" then reason else "crash" })
	end
end

-- Whether a rescue makes sense right now: a vehicle in play (not out of a battle, not on the grid or under the
-- map-switch curtain). Shared by the car through CarController's wrapper.
function FlightController.rescueAllowed(): boolean
	if LocalPlayer:GetAttribute("BattleOut") == true or workspace:GetAttribute("TrackSwitching") == true then
		return false
	end
	local goTime = RaceAttr.mine("RaceGoTime")
	return not (type(goTime) == "number" and workspace:GetServerTimeNow() < goTime)
end

-- Manual respawn for the plane (G5). source: "button" | "key" | "pad" | "Stuck" (the watchdog). Returns true when it
-- started. CarController replaces this while a car is bound.
function FlightController.requestManualRespawn(source: string?): boolean
	local hull = FlightController.hull
	if not FlightController.plane or not hull or not hull.Parent or FlightController.crashing then
		return false
	end
	local now = os.clock()
	if not FlightController.rescueAllowed() or not RespawnRules.canManual(lastManualRespawn, lastRespawnClock, now) then
		return false
	end
	lastManualRespawn = now
	print(string.format("[SkyRally][FLIGHT] manual respawn source=%s", tostring(source)))
	FlightController.triggerCrash(if source == "Stuck" then "Stuck" else "Manual", nil, true)
	return true
end

-- HUD state of the RESPAWN button: (shown, cooldown fraction left 0..1, the stuck watchdog offers it).
function FlightController.respawnStatus(): (boolean, number, boolean)
	local hull = FlightController.hull
	if not FlightController.plane or not hull or not hull.Parent or LocalPlayer:GetAttribute("BattleOut") == true or workspace:GetAttribute("TrackSwitching") == true then
		return false, 0, false
	end
	local now = os.clock()
	local left = math.max(RespawnRules.cooldownLeft(lastManualRespawn, now), RespawnRules.AFTER_RESPAWN_GAP - (now - lastRespawnClock))
	local frac = if FlightController.crashing then 1 else math.clamp(left / RespawnRules.MANUAL_COOLDOWN, 0, 1)
	return true, frac, FlightController.stuckOffer
end

-- ---------------------------------------------------------------- item hooks (L07)
local ITEM_USE_DEBOUNCE = 0.3 -- one press, one request; matches the server's own limit (ItemService.USE_MIN_INTERVAL)
local lastItemUseRequest = 0
local itemSpinDeg = 0
local itemUseQueued = false
-- Seconds the HUD's mystery roulette still spins (ItemClient wires HudExtras.rollLeft here; nil: no buffering).
FlightController.itemRollLeft = nil :: (() -> number)?

local function itemRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	local remote = if remotes then remotes:FindFirstChild("ItemRemote") else nil
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

-- Missile v3 (shared/MissileRules.pressAction): with a trap held, nothing fires on the press. A release before
-- dragHoldSeconds drops it; a longer hold sends "Drag" (the trap trails behind and blocks a missile) and the release drops
-- it. itemDragging is local display state; the server keeps the real one.
FlightController.itemDragging = false
local trapPressAt: number? = nil

-- Missile v3: a barrel roll is reported so the server can judge a dodge (it accepts one per rollMinInterval).
function FlightController.reportRoll()
	local remote = itemRemote()
	if remote then
		remote:FireServer("Roll")
	end
end

-- Keyboard F, gamepad X and the touch ITEM button all land here (press). fromQueue: a press kept through the
-- roulette and replayed after it; it is a tap (the button was let go long ago).
function FlightController.requestItemUse(fromQueue: boolean?): boolean
	local now = os.clock()
	-- Item bugs audit: the server refuses a fire while the roulette spins ("rolling"), which swallowed an eager press.
	-- A press during the spin is kept and sent once the item is revealed (the client's spin ends after the server's).
	local rollLeft = FlightController.itemRollLeft
	local left = if rollLeft then rollLeft() else 0
	if left > 0 then
		if not itemUseQueued then
			itemUseQueued = true
			task.delay(left + 0.08, function()
				itemUseQueued = false
				FlightController.requestItemUse(true)
			end)
		end
		return true
	end
	if not fromQueue and MissileRules.pressAction(LocalPlayer:GetAttribute("ItemColor") :: string?, 0, false, false) == nil then
		-- A trap: wait for the release (tap = drop) or the hold (drag).
		local pressAt = now
		trapPressAt = pressAt
		task.delay(MissileRules.TUNING.dragHoldSeconds, function()
			if trapPressAt ~= pressAt or FlightController.itemDragging then
				return
			end
			local held = os.clock() - pressAt
			if MissileRules.pressAction(LocalPlayer:GetAttribute("ItemColor") :: string?, held, false, false) == "drag" then
				local remote = itemRemote()
				if remote then
					FlightController.itemDragging = true
					remote:FireServer("Drag")
				end
			end
		end)
		return true
	end
	if now - lastItemUseRequest < ITEM_USE_DEBOUNCE then
		return false
	end
	local remote = itemRemote()
	if not remote then
		return false
	end
	lastItemUseRequest = now
	remote:FireServer("Use")
	return true
end

-- The item button let go (keyboard F, gamepad X, touch ITEM). Only a trap press acts here: it drops the trap.
function FlightController.releaseItemUse()
	local pressAt = trapPressAt
	if pressAt == nil then
		return
	end
	trapPressAt = nil
	local wasDragging = FlightController.itemDragging
	FlightController.itemDragging = false
	if MissileRules.pressAction("green", os.clock() - pressAt, true, wasDragging) ~= "use" then
		return
	end
	local remote = itemRemote()
	if remote then
		lastItemUseRequest = os.clock()
		remote:FireServer("Use")
	end
end

function FlightController.clearItemEffects()
	FlightController.itemStunTimer = 0
	FlightController.itemStunTotal = 0
	FlightController.itemBoostTimer = 0
	FlightController.itemMagnetTimer = 0
	FlightController.itemMagnetTarget = nil
	FlightController.itemSlowTimer = 0
	FlightController.itemSlowFactor = 1
	FlightController.itemAutoTimer = 0
	itemSpinDeg = 0
	LocalPlayer:SetAttribute("ItemStunned", false)
end

-- Applies one server-decided effect to this plane. kind: "boost" {seconds, speed}, "hit" {seconds, source},
-- "magnet" {target: Model, seconds, pull, range}. Values are clamped: a bad packet must not launch the plane.
function FlightController.applyItemEffect(kind: string, data: any)
	local d = if type(data) == "table" then data else {}
	if kind == "boost" and type(d.factor) == "number" then
		-- Items v4: a cruise-factor lift (Golden Wings, coins): a speed floor only, no ring-boost state.
		local seconds = math.clamp(tonumber(d.seconds) or 1, 0.1, 8)
		local speed = PlaneConfig.BASE_SPEED * math.clamp(d.factor, 1, 1.3)
		FlightController.itemBoostTimer = math.max(FlightController.itemBoostTimer, seconds)
		FlightController.itemBoostSpeed = math.max(if FlightController.itemBoostTimer > seconds then FlightController.itemBoostSpeed else 0, speed)
	elseif kind == "boost" then
		local seconds = math.clamp(tonumber(d.seconds) or PlaneConfig.BOOST_DURATION, 0.1, 5)
		local speed = math.clamp(tonumber(d.speed) or PlaneConfig.BOOST_SPEED, PlaneConfig.BASE_SPEED, 260)
		if type(d.auto) == "number" and d.auto > 0 then
			FlightController.itemAutoTimer = math.clamp(d.auto, 0, 5) -- Rocket Rush: the line follower flies it
		end
		FlightController.triggerBoost(speed >= PlaneConfig.OVERCHARGE_SPEED)
		FlightController.boostTimer = math.max(FlightController.boostTimer, seconds)
		FlightController.itemBoostTimer = math.max(FlightController.itemBoostTimer, seconds)
		FlightController.itemBoostSpeed = speed
		FlightController.currentSpeed = math.max(FlightController.currentSpeed, speed)
	elseif kind == "hit" then
		if FlightController.crashing then
			return
		end
		local seconds = math.clamp(tonumber(d.seconds) or 1.2, 0.2, 4)
		FlightController.itemStunTimer = seconds
		FlightController.itemStunTotal = seconds
		FlightController.itemBoostTimer = 0
		FlightController.boostState = "None"
		FlightController.boostTimer = 0
		LocalPlayer:SetAttribute("BoostState", "None")
		LocalPlayer:SetAttribute("ItemStunned", true)
		StyleChain.breakChain("ItemHit") -- REMARKABLE 17
		FlightController.currentSpeed = math.min(FlightController.currentSpeed, PlaneConfig.BASE_SPEED * ItemRules.TUNING.stunSpeedFactor)
		FlightController.addTrauma(0.55)
		FlightController.triggerHitStop(0.05)
		-- REMARKABLE item 14: no crash thud here; ItemClient plays the comic BONK for an item hit (thud as fallback).
	elseif kind == "slow" then
		FlightController.itemSlowTimer = math.clamp(tonumber(d.seconds) or 1, 0, ItemRules.SLOW.maxSeconds)
		FlightController.itemSlowFactor = math.clamp(tonumber(d.factor) or 1, ItemRules.SLOW.floor, 1)
	elseif kind == "magnet" then
		local target = d.target
		if typeof(target) == "Instance" and target:IsA("Model") then
			FlightController.itemMagnetTarget = target
			FlightController.itemMagnetTimer = math.clamp(tonumber(d.seconds) or 2, 0.1, 5)
			FlightController.itemMagnetPull = math.clamp(tonumber(d.pull) or 55, 0, 90)
			FlightController.itemMagnetRange = math.clamp(tonumber(d.range) or 140, 0, 400)
		end
	end
end

-- Ticks the item timers; returns the magnet's extra velocity (studs/s) for this frame.
local function stepItemEffects(dt: number, pos: Vector3): Vector3
	if FlightController.itemBoostTimer > 0 then
		FlightController.itemBoostTimer = math.max(0, FlightController.itemBoostTimer - dt)
	end
	if FlightController.itemSlowTimer > 0 then
		FlightController.itemSlowTimer = math.max(0, FlightController.itemSlowTimer - dt)
	end
	if FlightController.itemAutoTimer > 0 then
		FlightController.itemAutoTimer = math.max(0, FlightController.itemAutoTimer - dt)
	end
	if FlightController.itemStunTimer > 0 then
		FlightController.itemStunTimer = math.max(0, FlightController.itemStunTimer - dt)
		if FlightController.itemStunTimer == 0 then
			LocalPlayer:SetAttribute("ItemStunned", false)
		end
	end
	if FlightController.itemMagnetTimer > 0 then
		FlightController.itemMagnetTimer = math.max(0, FlightController.itemMagnetTimer - dt)
		local target = FlightController.itemMagnetTarget
		local tHull = if target and target.Parent then target.PrimaryPart else nil
		if tHull and FlightController.itemMagnetTimer > 0 then
			local to = PlayerStreamRules.enginePosition(tHull) - pos
			local dist = to.Magnitude
			if dist <= ItemRules.TUNING.magnetArrive then
				-- Contact: the pull ends here (no stun for them; the pop is ItemClient's).
				FlightController.itemMagnetTimer = 0
				FlightController.itemMagnetTarget = nil
				local cb = FlightController.onMagnetArrive
				if cb and target then
					cb(target)
				end
			elseif dist <= FlightController.itemMagnetRange * 1.6 then
				-- Past 1.6x the lock range the target respawned or teleported: never drag the plane after it.
				return to.Unit * FlightController.itemMagnetPull
			end
		else
			FlightController.itemMagnetTimer = 0
			FlightController.itemMagnetTarget = nil
		end
	end
	return Vector3.zero
end

-- Magnet v2: while the pull runs, the heading turns toward the target at magnetYawRate on top of the player's own
-- steering (the pull velocity alone slid the plane sideways while its nose pointed elsewhere). Flat only: the pull
-- velocity carries the height, and the plane's normal collision and course bounds still apply.
local function magnetYaw(yawDeg: number, pos: Vector3, dt: number): number
	if FlightController.itemMagnetTimer <= 0 or FlightController.itemStunTimer > 0 then
		return yawDeg
	end
	local target = FlightController.itemMagnetTarget
	local tHull = if target and target.Parent then target.PrimaryPart else nil
	if not tHull then
		return yawDeg
	end
	local to = PlayerStreamRules.enginePosition(tHull) - pos
	if to.X * to.X + to.Z * to.Z < 1 then
		return yawDeg
	end
	-- CFrame.Angles(0, yaw, 0).LookVector = (-sin yaw, 0, -cos yaw)
	local want = math.deg(math.atan2(-to.X, -to.Z))
	local diff = (want - yawDeg + 180) % 360 - 180
	local maxStep = ItemRules.TUNING.magnetYawRate * dt
	return (yawDeg + math.clamp(diff, -maxStep, maxStep)) % 360
end

-- Spin-out: two flat turns easing out over the stun, on the hull only. The camera keeps following the unspun
-- frame so the route stays readable while the plane spins in front of it.
local function applyItemSpin(hull: BasePart, cf: CFrame)
	if FlightController.itemStunTimer <= 0 or FlightController.itemStunTotal <= 0 then
		itemSpinDeg = 0
		return
	end
	local t = 1 - FlightController.itemStunTimer / FlightController.itemStunTotal
	itemSpinDeg = 720 * (1 - (1 - t) * (1 - t))
	local spun = cf * CFrame.Angles(0, math.rad(itemSpinDeg), math.rad(math.sin(t * math.pi * 3) * 18))
	hull.CFrame = spun
	local ao = hull:FindFirstChild("FlightOrientation") :: AlignOrientation?
	if ao then
		ao.CFrame = spun
	end
end

-- Waits for a child however long it takes (one warning after 10 s), for remotes the server creates late.
local function waitForever(parent: Instance, name: string): Instance
	local found = parent:WaitForChild(name, 10)
	if not found then
		warn("[SkyRally][FLIGHT] still waiting for " .. name .. " (server still building the map?)")
		repeat
			found = parent:WaitForChild(name, 10)
		until found
	end
	return found :: Instance
end

-- True while this player's vehicle is a car (CarController binds "Car_<name>"; requiring it here would be circular).
local function carBound(): boolean
	local planes = workspace:FindFirstChild("Planes")
	return planes ~= nil and planes:FindFirstChild("Car_" .. LocalPlayer.Name) ~= nil
end

local function bindToPlane(): boolean
	local planesFolder = workspace:FindFirstChild("Planes")
	if not planesFolder then
		return false
	end
	local myPlane = planesFolder:FindFirstChild("Plane_" .. LocalPlayer.Name)
	if not myPlane or not myPlane:IsA("Model") or not myPlane.PrimaryPart then
		-- The plane went (hub exchange back to a car, a car track): drop the stale binding so nothing (CarController's
		-- camera hand-back, the HUD) takes a destroyed plane for the vehicle in play.
		local old = FlightController.plane
		if old and not old.Parent then
			FlightController.plane = nil
			FlightController.hull = nil
		end
		return false
	end
	if FlightController.plane ~= myPlane then
		FlightController.plane = myPlane
		FlightController.hull = myPlane.PrimaryPart
		local spawnCF = (myPlane:GetAttribute("SpawnCFrame") :: CFrame?) or (myPlane.PrimaryPart :: BasePart).CFrame
		FlightController.lastCheckpointCF = spawnCF
		FlightController.setPoseFromCFrame(spawnCF)
		FlightController.invulnTimer = 2.0
		if FlightController.firstInputTime == 0 then
			FlightController.firstInputTime = os.clock() - FlightController.joinClock
			LocalPlayer:SetAttribute("FirstFlightReadySeconds", FlightController.firstInputTime)
		end
	end
	return true
end

local assistHold = Vector2.zero -- seconds of suppressed assist left per axis after the player last steered it
local assistShareY = 0 -- the course assist's share of the pitch axis this frame (PlaneConfig.pitchStep skips levelling it)
local keySteer = Vector2.zero -- keyboard / D-pad steer after PlaneConfig.rampKey
local camYawRate = 0 -- deg/s this frame (+ = turning left), for the camera's turn lead
local camLead = 0 -- eased look lead, degrees
-- Chase follow state (docs/audits/plane_stutter.md C1): the smoothed frame before shake, the frame last written to the
-- camera (anything else found there was written by someone else: a cinematic or a punch, eased from as before), and the
-- followed hull position (the carry is its move since the last frame).
local camBase: CFrame? = nil
local camWritten: CFrame? = nil
local camHullPos: Vector3? = nil
local battleOutHoldCF: CFrame? = nil -- spectator hover frame once this player is out of a battle

-- Battle arena edge (server BattleCore publishes workspace BattleCenter/BattleRadius/BattleReturnRadius): from 90 % of
-- the play radius outward the plane is steered back toward the centre, harder the deeper it goes, so the server's
-- put-back past the band is the exception. Returns the pull weight (0..1) and the yaw error to the centre in degrees.
local function battleEdgePull(pos: Vector3): (number, number)
	if RaceAttr.mine("RaceMode") ~= "battle" then
		return 0, 0
	end
	local center = RaceAttr.mine("BattleCenter")
	local radius = RaceAttr.mine("BattleRadius")
	local outer = RaceAttr.mine("BattleReturnRadius")
	if typeof(center) ~= "Vector3" or type(radius) ~= "number" or type(outer) ~= "number" then
		return 0, 0
	end
	local inward = Vector3.new(center.X - pos.X, 0, center.Z - pos.Z)
	local d = inward.Magnitude
	-- Trap audit G6: the server's BattlePullStart is at least one turn radius inside the return line (the 90 % rule
	-- left a 55-stud band a plane needs 87+ studs to turn round in, so a straight run out was always put back).
	local pullStart = RaceAttr.mine("BattlePullStart")
	local start = if type(pullStart) == "number" then math.min(pullStart, radius * 0.9) else radius * 0.9
	if d <= start or d < 1 then
		return 0, 0
	end
	local w = math.clamp((d - start) / math.max(outer - start, 1), 0, 1)
	if d > radius * 0.9 then
		w = math.max(w, 0.35) -- from the old start on: at least a third, as before
	end
	local targetYaw = headingAndPitchFromVector(inward.Unit)
	return w, ((targetYaw - FlightController.yawDeg + 540) % 360) - 180
end

-- Battle ceiling (workspace BattleCeiling, trap audit G6 / SN-08 / D4-08 / F6): from 30 studs under it the nose is
-- pulled toward a shallow dive, all of it at the ceiling, so a climb to dodge a missile levels off instead of being
-- put back on a pad. Returns the pull weight (0..1) and the pitch error to that dive in degrees.
local CEILING_BAND = 30
local CEILING_PITCH = -10
local function battleCeilingPull(pos: Vector3): (number, number)
	if RaceAttr.mine("RaceMode") ~= "battle" then
		return 0, 0
	end
	local ceiling = RaceAttr.mine("BattleCeiling")
	if type(ceiling) ~= "number" or pos.Y <= ceiling - CEILING_BAND then
		return 0, 0
	end
	local w = math.clamp((pos.Y - (ceiling - CEILING_BAND)) / CEILING_BAND, 0, 1)
	return w, CEILING_PITCH - FlightController.pitchDeg
end

-- Hub free flight: where an idle plane heads. Far from the plaza it comes back toward it; near it, it circles at
-- HUB_ORBIT_RADIUS. The cruise height clears the spire top (188) and the ridge, so letting go never flies into the
-- island; a dive for the spire find is the player's own.
local HUB_ORBIT_RADIUS = 300
local HUB_ORBIT_HEIGHT = 215
local function hubOrbitTarget(pos: Vector3): Vector3
	local spawnCF = workspace:GetAttribute("HubSpawnCF")
	local c = if typeof(spawnCF) == "CFrame" then spawnCF.Position else pos
	local center = Vector3.new(c.X, HUB_ORBIT_HEIGHT, c.Z)
	local flatOff = Vector3.new(pos.X - c.X, 0, pos.Z - c.Z)
	if flatOff.Magnitude > HUB_ORBIT_RADIUS * 1.6 or flatOff.Magnitude < 1 then
		return center
	end
	-- A point ahead on the circle (counter-clockwise from above).
	local radial = flatOff.Unit
	local tangentDir = Vector3.new(-radial.Z, 0, radial.X)
	return center + radial * HUB_ORBIT_RADIUS + tangentDir * 160
end

-- Trap audit G8 + G5.4: the plane's place on the course. Projects onto the main spline, picks the alternate line it
-- is on (shared/RouteBranch, with hysteresis: tunnels, ledges, FOREST-1's key gallery) and refreshes courseDist (the
-- nearest course line of any kind, at flight height) and the RouteBranch player attribute. Returns the main-route
-- station, the line (nil = main), the distance along it and the main line's distance at flight height.
local function sampleCourse(pos: Vector3): (number, RouteBranch.Line?, number, number)
	local station, point = SplineUtils.projectPosition(pos, LocalPlayer:GetAttribute("Station") :: number?)
	local mainDist = (pos - (point + Vector3.new(0, RouteBranch.PLANE_LIFT, 0))).Magnitude
	local _, trackLength = SplineUtils.loadWaypoints()
	local lines = RouteBranch.load(TrackRegistry.getRoot(), RouteBranch.PLANE_LIFT)
	local line, _, along, nearest = RouteBranch.pick(lines, pos, mainDist, branchId, station, trackLength)
	local id = if line then line.id else nil
	if id ~= branchId then
		branchId = id
		LocalPlayer:SetAttribute("RouteBranch", id)
		print(string.format("[SkyRally][FLIGHT] route branch %s at station %.0f", tostring(id or "main"), station))
	end
	courseDist = nearest
	sampleStation, sampleLine, sampleAlong = station, line, along
	return station, line, along, mainDist
end

-- Pursuit point `lookahead` studs ahead on the line the plane is on, and the main spline's bank there. Past an
-- alternate's end the point runs on along the main spline from its rejoin station.
local function courseAhead(station: number, line: RouteBranch.Line?, along: number, lookahead: number): (Vector3, number)
	local lift = Vector3.new(0, RouteBranch.PLANE_LIFT, 0)
	if line then
		local p, over = RouteBranch.target(line, along, lookahead)
		local rejoin = line.rejoin
		if over > 0 and rejoin then
			return SplineUtils.sampleAtStation(rejoin + over) + lift, 0
		end
		return p, 0
	end
	local aheadPos, _, bank = SplineUtils.sampleAtStation(station + lookahead)
	return aheadPos + lift, bank
end

-- QA (Studio only, shared/QASteerRules): workspace.QAFollowLine names an alternate line the AutoPilot plane pursues from its join
-- to its end, then the main spline again from the line's rejoin station. Inputs only: no teleport, no physics change.
local IS_STUDIO = RunService:IsStudio()
local qaState = QASteerRules.newState()
local qaLastName: string? = nil
local qaLastPos: Vector3? = nil
local function qaLineTarget(pos: Vector3, station: number, mainAhead: Vector3, lookahead: number): Vector3
	local name = QASteerRules.lineName(IS_STUDIO, workspace:GetAttribute(QASteerRules.FOLLOW_ATTR))
	if name ~= qaLastName then
		qaLastName = name
		qaLastPos = nil
		qaState = QASteerRules.newState()
		if name then
			print("[SkyRally][QASTEER] plane follow " .. name .. " requested")
		end
	end
	if not name then
		return mainAhead
	end
	local line = QASteerRules.findLine(RouteBranch.load(TrackRegistry.getRoot(), RouteBranch.PLANE_LIFT), name)
	if not line then
		if qaState.phase ~= "missing" then
			qaState.phase = "missing"
			print("[SkyRally][QASTEER] plane line " .. name .. " not found")
		end
		return mainAhead
	end
	local _, trackLength = SplineUtils.loadWaypoints()
	local lateral, along = RouteBranch.nearest(line, pos)
	local jump = if qaLastPos then (pos - qaLastPos).Magnitude else 0 -- a respawn teleports: the line pursuit is dropped (V8)
	qaLastPos = pos
	local event = QASteerRules.step(qaState, line, station, along, trackLength, lateral, jump)
	if event then
		print(QASteerRules.logLine("plane", event, line, station, along))
	end
	local target = QASteerRules.target(qaState, line, along, lookahead)
	if target then
		return target
	end
	if qaState.phase == "done" and line.rejoin then
		return SplineUtils.sampleAtStation(line.rejoin + lookahead) + Vector3.new(0, 12, 0)
	end
	return mainAhead
end

-- The leash runs in race modes only: never in a battle arena (BattleCore steers there), the hub (free flight), under
-- AutoPilot QA or for a battle spectator.
local function leashActive(): boolean
	local mode = RaceAttr.mine("RaceMode")
	return mode ~= "battle" and mode ~= "hub" and workspace:GetAttribute("AutoPilot") ~= true
		and LocalPlayer:GetAttribute("BattleOut") ~= true
end

-- ---------------------------------------------------------------- flight modes and RETURN (FLIGHT_GUIDE.md 4.3, 12)
-- The modes, the bead mist and RETURN run where the leash does (race modes) and only until this racer finishes.
local function guideActive(): boolean
	return leashActive() and LocalPlayer:GetAttribute("RaceFinished") ~= true
end

-- "mk" (the default) or "free": the server-owned FlightMode attribute (server/SettingsService validates the setting).
local function flightMode(): string
	return FlightGuideRules.modeOf(LocalPlayer:GetAttribute(FlightGuideRules.MODE_ATTR))
end

-- The active track's allow-pockets (published by MapAdapter on the root), re-read every 2 s like RouteBranch.load.
local function pockets(): { FlightGuideRules.Pocket }
	local root = TrackRegistry.getRoot()
	local now = os.clock()
	if root ~= pocketRoot or now - pocketCheck >= 2 then
		pocketRoot, pocketCheck = root, now
		pocketList = FlightGuideRules.readPockets(root)
	end
	return pocketList
end

-- RETURN is Free driving's shortcut only: the default mode puts the plane back by itself and shows no button.
local function returnOffered(): boolean
	local hull = FlightController.hull
	return FlightController.plane ~= nil and hull ~= nil and hull.Parent ~= nil and not FlightController.crashing
		and offVerdict == "offer" and returnPending == nil and guideActive() and FlightController.rescueAllowed()
		and flightMode() == FlightGuideRules.MODE_FREE and os.clock() - lastReturnRequest >= FlightGuideRules.CLIENT_COOLDOWN
end

-- Asks the server to put the plane back on the course. reason: "Button" (Free driving's RETURN button / Enter /
-- gamepad Y; only while offered), "Bounds" (the default mode's Lakitu reset past the course bounds), "Lost" (Free
-- driving: far with no progress for 15 s) or "Far" (the leash's far rescue, both modes). The client sends no frame; the
-- reply is RaceEvent "CourseReturn" (frame) or "CourseReturnRefused". Returns true when it went out.
function FlightController.requestCourseReturn(reason: string): boolean
	local remote = flightStateRemote
	if not remote or returnPending ~= nil or FlightController.crashing then
		return false
	end
	if reason == "Button" and not returnOffered() then
		return false
	end
	local now = os.clock()
	local label: string = reason
	returnPending = { at = now, reason = label }
	lastReturnRequest = now
	print(string.format("[SkyRally][GUIDE] return request reason=%s dist=%.0f", reason, courseDist))
	remote:FireServer("RequestCourseReturn", { reason = reason })
	return true
end

-- The server refused (or never answered): an automatic return falls back to the old far rescue (the last checkpoint),
-- silently for a bounds reset (the default mode never says anything); a press only says so quietly.
local function returnFailed(why: string)
	local pend = returnPending
	returnPending = nil
	if not pend then
		return
	end
	print(string.format("[SkyRally][GUIDE] return failed reason=%s why=%s", pend.reason, why))
	if pend.reason ~= "Button" then
		if guideActive() and not FlightController.crashing then
			if pend.reason ~= "Bounds" then
				CourseArrow.rescued()
			end
			FlightController.triggerCrash("Leash", nil, true)
		end
	else
		returnFailSeq += 1
	end
end

-- HUD state of RETURN: (RETURN offered: the button, failure counter: a notice per bump). No "Off course" caption in
-- either mode (there is no slowdown to explain, and the default mode never says anything).
function FlightController.returnStatus(): (boolean, number)
	return returnOffered(), returnFailSeq
end

-- L03: blend the course assist under the player's input (PlaneConfig.assistAxis, flight_feel.md C3). At full
-- deflection the player's value is used unchanged; under partial input the assist adds a share scaled by the stick's
-- headroom; an idle axis gets the assist, fading back to all of it over ASSIST_RELEASE_S after release.
local function blendAssist(player: Vector2, playerSharp: boolean, assist: Vector2, assistSharp: boolean, dt: number): (Vector2, boolean)
	local release = PlaneConfig.ASSIST_RELEASE_S
	local hx = if math.abs(player.X) > 0.05 then release else math.max(0, assistHold.X - dt)
	local hy = if math.abs(player.Y) > 0.05 then release else math.max(0, assistHold.Y - dt)
	assistHold = Vector2.new(hx, hy)
	local rx = 1 - hx / release
	local x, wx = PlaneConfig.assistAxis(player.X, assist.X, rx)
	local y, wy = PlaneConfig.assistAxis(player.Y, assist.Y, 1 - hy / release)
	-- No assist pitch (no course sample, or on the line) leaves the auto-level on: an idle plane never holds a climb.
	assistShareY = wy * math.min(1, math.abs(assist.Y) / 0.1)
	FlightController.assistSteer = assist
	FlightController.assistWeight = math.min(wx, wy)
	return Vector2.new(x, y), playerSharp or (assistSharp and rx > 0.5)
end

local function readCombinedInputs(dt: number): (Vector2, number, boolean)
	local kbSteerX = 0
	local kbSteerY = 0
	local kbThrottle = 0
	local sharp = false

	if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
		kbSteerX = kbSteerX - 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
		kbSteerX = kbSteerX + 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Up) or UserInputService:IsKeyDown(Enum.KeyCode.I) or UserInputService:IsKeyDown(Enum.KeyCode.E) then
		kbSteerY = kbSteerY + 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Down) or UserInputService:IsKeyDown(Enum.KeyCode.K) or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
		kbSteerY = kbSteerY - 1
	end

	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		kbThrottle = kbThrottle + 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		kbThrottle = kbThrottle - 1
	end

	if UserInputService:IsKeyDown(Enum.KeyCode.R) or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		sharp = true
	end

	-- Gamepad (console-ready, D20): left stick or D-pad steer/pitch, A/R2 throttle, B/L2 brake, R1 sharp bank.
	local stickX, stickY = 0, 0
	local rawStickX = 0
	local GP = Enum.UserInputType.Gamepad1
	if UserInputService.GamepadEnabled and UserInputService:GetGamepadConnected(GP) then
		for _, st in UserInputService:GetGamepadState(GP) do
			if st.KeyCode == Enum.KeyCode.Thumbstick1 then
				-- Radial dead zone and expo (flight_feel.md C2).
				stickX, stickY = PlaneConfig.shapeStick(st.Position.X, st.Position.Y)
				rawStickX = st.Position.X
			end
		end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.DPadLeft) then kbSteerX -= 1 end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.DPadRight) then kbSteerX += 1 end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.DPadUp) then kbSteerY += 1 end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.DPadDown) then kbSteerY -= 1 end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonA) or UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonR2) then
			kbThrottle += 1
		end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonB) or UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonL2) then
			kbThrottle -= 1
		end
		if UserInputService:IsGamepadButtonDown(GP, Enum.KeyCode.ButtonR1) then
			sharp = true
		end
	end
	-- Dodge input: the RAW side pressed (keys / D-pad as -1..1 before the ramp, stick X, touch pad X or landing side).
	rawDodgeX = DodgeRules.pick(kbSteerX, rawStickX, FlightController.mobileSteer.X, FlightController.padSideX)
	-- Digital keys and the D-pad ramp to full lock (PlaneConfig.rampKey, flight_feel.md C2); the stick adds on top.
	keySteer = Vector2.new(
		PlaneConfig.rampKey(keySteer.X, math.clamp(kbSteerX, -1, 1), dt),
		PlaneConfig.rampKey(keySteer.Y, math.clamp(kbSteerY, -1, 1), dt)
	)
	kbSteerX = math.clamp(keySteer.X + stickX, -1, 1)
	kbSteerY = math.clamp(keySteer.Y + stickY, -1, 1)

	-- Desktop mouse steering is opt-in: only while the right mouse button is held, so moving the cursor to use
	-- the UI (or any tool that nudges the mouse) never steers the plane.
	local mouseSteering = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	if not mouseSteering then
		mouseMovedRecently = 0
	end
	local useMouseX = if math.abs(kbSteerX) < 0.05 and FlightController.mobileSteer.Magnitude < 0.05 and mouseSteering then mouseSteerOffset.X else 0
	local useMouseY = if math.abs(kbSteerY) < 0.05 and FlightController.mobileSteer.Magnitude < 0.05 and mouseSteering then mouseSteerOffset.Y else 0

	-- Touch pad: dead zones (a sideways drag does not pitch) and expo (flight_feel.md C2).
	local touchX, touchY = PlaneConfig.shapeTouch(FlightController.mobileSteer.X, FlightController.mobileSteer.Y)
	local steerX = math.clamp(kbSteerX + touchX + useMouseX, -1, 1)
	local steerY = math.clamp(kbSteerY + touchY + useMouseY, -1, 1)

	local throttle = kbThrottle + FlightController.mobileThrottle
	if math.abs(throttle) < 0.05 then
		-- ASSIST cruise (Mario Kart Tour drives forward for you): only while a race runs and the player has ASSIST on.
		local racing = AssistRules.racingPhase(HudPhase.phase()) and LocalPlayer:GetAttribute("RaceFinished") ~= true
		throttle = FlightGuideRules.idleThrottle(FlightController.autoThrottle, racing)
	else
		throttle = math.clamp(throttle, -1, 1)
	end

	if FlightController.mobileSharpBank then
		sharp = true
	end

	return Vector2.new(steerX, steerY), throttle, sharp
end

local function stepSpinningPropeller(hull: BasePart, dt: number, speed: number, gas: number?, levelSpeed: number?)
	local plane = FlightController.plane
	if not plane then
		return
	end
	-- The rotor itself is turned by VehicleMotion (every plane on this client); this plane hands it the live speed.
	VehicleMotion.setLocalSpeed(plane, speed)

	SoundJuice.step(dt, speed, hull.Position.Y, FlightController.boostState, gas, levelSpeed)
end

local function evaluateRingsAndPads(pos: Vector3, lookVec: Vector3, dt: number): Vector3
	local cachedTriggers = TriggerIndex.get() -- tagged set, no map walk (L40)
	local now = os.clock()
	local pullVelocity = Vector3.zero

	for _, trig in ipairs(cachedTriggers) do
		if trig and trig.Parent then
			local tType = trig:GetAttribute("TriggerType")
			local podSpawn = trig:GetAttribute("ItemPodSpawn")
			local toTrig = trig.Position - pos
			local dist = toTrig.Magnitude

			-- A sail-gap ring (FOREST-1) with a sail across it is inert: no pull, no boost, no penalty.
			local gateCfg = if tType == "BoosterRing" then SailGateRules.configOf(trig) else nil
			if tType == "BoosterRing" and gateCfg ~= nil and not SailGateRules.live(workspace:GetServerTimeNow(), gateCfg) then
				-- skip the whole ring block
			elseif tType == "BoosterRing" then
				local forwardDot = toTrig:Dot(lookVec)
				-- Ring magnetism (PlaneConfig.ringPull, flight_feel.md C6).
				local lateralVec = toTrig - lookVec * forwardDot
				local lateral = lateralVec.Magnitude
				local pull = PlaneConfig.ringPull(forwardDot, lateral)
				if pull > 0 then
					-- The forward push follows the window as before; the sideways part settles onto the axis instead of
					-- overshooting it every frame (plane_stutter.md C2).
					local pullFactor = pull / PlaneConfig.RING_PULL_STRENGTH
					pullVelocity = pullVelocity + lookVec * (PlaneConfig.RING_PULL_FORWARD * pullFactor)
					local side = PlaneConfig.ringPullLateral(pull, lateral, dt)
					if side > 0 and lateral > 1e-3 then
						pullVelocity = pullVelocity + lateralVec * (side / lateral)
					end
				end

				if dist <= PlaneConfig.RING_TRIGGER_RADIUS then
					local lastHit = lastRingCooldowns[trig] or 0
					if now - lastHit > 1.2 then
						lastRingCooldowns[trig] = now
						local overcharge = throttleReleaseDuration >= PlaneConfig.OVERCHARGE_RELEASE_WINDOW
						Vfx.onRing(CFrame.lookAt(trig.Position, trig.Position + lookVec), Vfx.ringRadius(trig.Size))
						Sfx.play("ring_pass", 1, 0.48) -- layers with the boost hit
						FlightController.triggerBoost(overcharge)
						-- THREADED! (REMARKABLE item 7): rolling through the ring keeps the same BOOST_SPEED for
						-- ROLL_RING_BONUS longer. The server only receives the flag (no reward is decided there).
						local threaded = FlightController.rollTimer > 0 or now - rollEndClock <= THREAD_GRACE
						if threaded then
							FlightController.boostTimer = math.max(FlightController.boostTimer, PlaneConfig.BOOST_DURATION + TrickRules.ROLL_RING_BONUS)
							TrickJuice.callout("THREADED!", TrickJuice.MINT, 1.1)
							TrickJuice.play("trick_stuck", 1.2)
							StyleChain.event("Threaded") -- REMARKABLE 17
							Vfx.burst("trickLand", CFrame.lookAt(trig.Position, trig.Position + lookVec), 0.8)
							LocalPlayer:SetAttribute("ThreadedCount", ((LocalPlayer:GetAttribute("ThreadedCount") :: number?) or 0) + 1)
						end
						if raceEventRemote then
							raceEventRemote:FireServer("RingTriggered", {
								ringName = trig.Parent.Name,
								overcharged = overcharge,
								threaded = threaded or nil,
							})
						end
					end
				end
			elseif tType == "GroundBoostPad" then
				-- Cubes v2: on plane maps the pad's volume reaches PickupLift studs up (ItemRules.CUBES.planeLift).
				-- Only a plane above the sphere and inside the capsule's reach pays for the attribute read.
				local padDist = dist
				if dist > PlaneConfig.PAD_TRIGGER_RADIUS and dist <= PlaneConfig.PAD_TRIGGER_RADIUS + ItemRules.CUBES.planeLift then
					local lift = trig:GetAttribute("PickupLift")
					if type(lift) == "number" then
						padDist = ItemRules.liftedDistance(-toTrig.X, -toTrig.Y, -toTrig.Z, lift)
					end
				end
				if padDist <= PlaneConfig.PAD_TRIGGER_RADIUS then
					local lastHit = lastRingCooldowns[trig] or 0
					if now - lastHit > 1.2 then
						lastRingCooldowns[trig] = now
						local overcharge = throttleReleaseDuration >= PlaneConfig.OVERCHARGE_RELEASE_WINDOW
						Vfx.onPad(trig.CFrame)
						Sfx.play("pad_zip", 1, 0.44)
						FlightController.triggerBoost(overcharge)
						if raceEventRemote then
							raceEventRemote:FireServer("PadTriggered", {
								padName = trig.Parent.Name,
								overcharged = overcharge,
							})
						end
					end
				end
			elseif podSpawn == true then
				-- Item bugs audit: no pop and chime for an item pod the server will refuse (this racer has finished).
				-- Cubes v2: plane-map Speed/Air pods take a plane anywhere in a tall capsule (PickupLift), not a sphere.
				local podDist = dist
				if dist > PlaneConfig.PICKUP_TRIGGER_RADIUS and dist <= PlaneConfig.PICKUP_TRIGGER_RADIUS + ItemRules.CUBES.planeLift then
					local lift = trig:GetAttribute("PickupLift")
					if type(lift) == "number" then
						podDist = ItemRules.liftedDistance(-toTrig.X, -toTrig.Y, -toTrig.Z, lift)
					end
				end
				if podDist <= PlaneConfig.PICKUP_TRIGGER_RADIUS and trig:GetAttribute("OnCooldown") ~= true and ItemRules.clientTakesPod(trig:GetAttribute("PodType"), LocalPlayer:GetAttribute("RaceFinished")) then
					local lastHit = lastRingCooldowns[trig] or 0
					-- Cubes v3: shared pods; PodLocal.take pops it here at once and keeps one cube per rank per pass.
					if now - lastHit > ItemRules.podRetrigger(trig:GetAttribute("RespawnSeconds")) and PodLocal.take(trig, now) then
						lastRingCooldowns[trig] = now
						local podType = trig:GetAttribute("PodType")
						Vfx.onPickup(trig.Position, if type(podType) == "string" then podType else nil)
						if podType == "Speed" then
							FlightController.speedPickups = math.min(PlaneConfig.MAX_SPEED_PICKUPS, FlightController.speedPickups + 1)
							LocalPlayer:SetAttribute("SpeedPickups", FlightController.speedPickups)
							FlightController.addTrauma(0.14)
							SoundJuice.triggerFeedback("small", "Pickup")
						elseif podType == "Air" then -- Blue is an item now: it boosts when fired, not on pickup
							local overcharge = throttleReleaseDuration >= PlaneConfig.OVERCHARGE_RELEASE_WINDOW
							FlightController.triggerBoost(overcharge)
						end
						if raceEventRemote then
							raceEventRemote:FireServer("PickupCollected", {
								podName = trig.Name,
								podType = podType,
							})
						end
					end
				end
			end
		end
	end

	return pullVelocity
end

local function updateChaseCamera(hullCF: CFrame, dt: number, velocity: Vector3?)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if workspace:GetAttribute("ShotCam") and workspace:GetAttribute("ShotCam") ~= "" then
		return
	end

	cam.CameraType = Enum.CameraType.Scriptable

	local look = hullCF.LookVector
	local flatLook = Vector3.new(look.X, look.Y * 0.55, look.Z)
	if flatLook.Magnitude < 0.01 then
		flatLook = Vector3.new(0, 0, -1)
	else
		flatLook = flatLook.Unit
	end

	-- Creature avatars (the Void Dragon) are bigger than a plane: their model carries the camera that keeps them out of
	-- the near band (VehicleCreatureRules.camera, set by kit/CreatureMesh); every other vehicle keeps the plane camera.
	local plane = FlightController.plane
	local camDist = if plane then (plane:GetAttribute("CreatureCamDistance") :: number?) or PlaneConfig.CAM_DISTANCE else PlaneConfig.CAM_DISTANCE
	local camHeight = if plane then (plane:GetAttribute("CreatureCamHeight") :: number?) or PlaneConfig.CAM_HEIGHT else PlaneConfig.CAM_HEIGHT
	local desiredCamPos = hullCF.Position - flatLook * camDist + Vector3.new(0, camHeight, 0)
	-- Turn lead (flight_feel.md C5): the look point swings into the turn so the bend's exit stays on screen. A snap
	-- (respawn, reset) drops the lead.
	camLead = if dt >= 0.5 then 0 else camLead + (PlaneConfig.camLeadDeg(camYawRate) - camLead) * math.clamp(dt * PlaneConfig.CAM_LEAD_LERP, 0, 1)
	local leadLook = if math.abs(camLead) > 0.05 then CFrame.Angles(0, math.rad(camLead), 0):VectorToWorldSpace(look) else look
	local lookTarget = hullCF.Position + leadLook * 32 + Vector3.new(0, 1.2, 0)

	local camBankRad = math.rad(-FlightController.bankDeg * PlaneConfig.CAM_BANK_FACTOR)
	-- The speed trail (PlaneConfig.camTrail) is part of the goal, so the follow below has no frame-time term on a
	-- straight flight: carried by the plane's move, the smoothed frame already sits on the goal.
	local goalCF = CFrame.lookAt(desiredCamPos, lookTarget) * CFrame.Angles(0, 0, camBankRad) - PlaneConfig.camTrail(velocity or Vector3.zero)

	local here = hullCF.Position
	local carry = if camHullPos then here - camHullPos else Vector3.zero
	camHullPos = here
	local base = camBase
	if base == nil or camWritten == nil or cam.CFrame ~= camWritten then
		base = cam.CFrame -- someone else moved the camera since our write: ease from where it is (as before)
	end
	local prev = base :: CFrame
	if dt >= 0.5 or carry.Magnitude > PlaneConfig.CAM_CARRY_MAX or (prev.Position + carry - goalCF.Position).Magnitude > 14 then
		base = goalCF -- reset, respawn or teleport: cut
	else
		base = PlaneConfig.camFollow(prev, carry, goalCF, dt)
	end
	camBase = base
	local out = base :: CFrame

	-- Apply smooth quadratic decaying camera trauma shake (camera-only visual offset; never mutates hull transform). It
	-- rides on the output only: the follow above never eases from a shaken frame.
	if FlightController.cameraTrauma > 0 then
		FlightController.cameraTrauma = math.max(0, FlightController.cameraTrauma - 1.45 * dt)
		local shake = FlightController.cameraTrauma * FlightController.cameraTrauma * Settings.shakeScale()
		traumaClock = traumaClock + dt * 28.0
		local offX = 0.85 * shake * math.sin(traumaClock * 1.7)
		local offY = 0.65 * shake * math.sin(traumaClock * 2.3)
		local rollShake = 0.045 * shake * math.sin(traumaClock * 1.1)
		out = out * CFrame.new(offX, offY, 0) * CFrame.Angles(0, 0, rollShake)
	end
	cam.CFrame = out
	camWritten = cam.CFrame

	-- Boost ignite punch (Vfx.boostPunch): the FOV overshoot rides on top of the smoothed FOV, so the smoothing does not
	-- swallow it; the queued trauma joins the shake above on the next frame.
	local fovPunch = if FlightController.hitStopTimer > 0 then 3.5 else 0
	local targetFov = (if FlightController.boostState ~= "None" then PlaneConfig.CAM_BOOST_FOV else PlaneConfig.CAM_BASE_FOV) + fovPunch
	local baseFov = cam.FieldOfView - appliedFovKick
	baseFov = baseFov + (targetFov - baseFov) * math.clamp(dt * 9, 0, 1)
	appliedFovKick = Vfx.fovKick()
	cam.FieldOfView = baseFov + appliedFovKick
	local punchTrauma = Vfx.takeTrauma()
	if punchTrauma > 0 then
		FlightController.addTrauma(punchTrauma)
	end
end

-- Touch START ring tap (TrickJuice.setStartRing), judged against the server clock.
function FlightController.onStartTap()
	local go = planeStartGo
	if go then
		local before = planeStart.state
		if TrickRules.tapStart(planeStart, go - workspace:GetServerTimeNow()) == "perfect" and before ~= "perfect" then
			gridRev = 1
		end
	end
end

-- First flying frame after the grid hold: apply the rev-match start once per RaceGoTime. Perfect = the normal ring
-- boost (BOOST_SPEED) cut to START_BOOST_TIME; flooded = gas capped for FLOOD_TIME.
function FlightController.applyStart(goTime: any)
	planeStartPending = false
	TrickJuice.setStartRing(false, false, nil)
	gridRev = 0
	if type(goTime) ~= "number" or workspace:GetServerTimeNow() - goTime > 0.5 then
		return
	end
	local state = planeStart.state
	LocalPlayer:SetAttribute("StartResult", state)
	if state == "perfect" then
		FlightController.triggerBoost(false)
		FlightController.boostTimer = TrickRules.START_BOOST_TIME
		TrickJuice.play("start_perfect")
		TrickJuice.callout("PERFECT START!", TrickJuice.BLUE, 1.2)
		StyleChain.event("PerfectStart") -- REMARKABLE 17
	elseif state == "flooded" then
		planeFloodTimer = TrickRules.FLOOD_TIME
		local h = FlightController.hull
		if h then
			Vfx.burst("floodPuff", planeExhaustCF(h), 1)
		end
		TrickJuice.play("start_flood")
		TrickJuice.callout("FLOODED!", TrickJuice.SOOT, 1.1)
		FlightController.addTrauma(0.15)
	end
	print(string.format("[SkyRally][TRICK] plane start=%s", state))
end

local lastObservedResetSeq = 0

local function stepFlight(dt: number)
	-- Up to 0.25 s per step (was 0.08): a slow device must not fly in slow motion while server-side bots keep real time
	-- (2026-10-18: a low-fps Studio window finished 8th in 180 s vs 102 s). The collision ray spans the whole step, so a
	-- long step cannot tunnel through a wall.
	local clampedDt = math.clamp(dt, 1 / 240, 0.25)
	camYawRate = 0 -- set again below once this frame's yaw is stepped (crash / grid frames: no turn lead)
	assistShareY = 0 -- set by blendAssist when the course assist runs this frame
	if not bindToPlane() then
		FlightGuide.hide() -- no plane (a car map, the hub exchange): nothing drawn
		return
	end
	local hull = FlightController.hull :: BasePart
	if not hull or not hull.Parent then
		return
	end
	local pend = returnPending
	if pend and os.clock() - pend.at > FlightGuideRules.REPLY_TIMEOUT then
		returnFailed("timeout")
	end

	local resetSeq = (RaceAttr.mine("RaceResetSeq") :: number?) or 0
	if resetSeq > lastObservedResetSeq then
		lastObservedResetSeq = resetSeq
		-- The plane's own slot (FlightServer sets SpawnCFrame on every spawn and reset); RaceStartCF is slot 1, and
		-- with 2+ humans it stacked every plane on pole (L30).
		local pm = FlightController.plane
		local own = if pm then pm:GetAttribute("SpawnCFrame") else nil
		local startCF = (if typeof(own) == "CFrame" then own else nil)
			or (RaceAttr.mine("RaceStartCF") :: CFrame?)
			or TrackRegistry.startCFrame(1)
			or CFrame.lookAt(Vector3.new(-2, 151, -18), Vector3.new(-4, 141, -145))
		FlightController.speedPickups = 0
		FlightController.boostState = "None"
		FlightController.boostTimer = 0
		FlightController.crashing = false
		FlightController.cameraTrauma = 0
		FlightController.hitStopTimer = 0
		FlightController.invulnTimer = 2.0
		FlightController.joinClock = os.clock()
		FlightController.clearItemEffects()
		FlightController.lastCheckpointCF = startCF
		FlightController.setPoseFromCFrame(startCF)
		updateChaseCamera(startCF, 1.0)
	end

	if FlightController.invulnTimer > 0 then
		FlightController.invulnTimer = math.max(0, FlightController.invulnTimer - clampedDt)
	end
	FlightController.rescueAssistTimer = math.max(0, FlightController.rescueAssistTimer - clampedDt)
	if FlightController.hitStopTimer > 0 then
		FlightController.hitStopTimer = math.max(0, FlightController.hitStopTimer - clampedDt)
	end

	if FlightController.crashing then
		FlightController.crashTimer = FlightController.crashTimer - clampedDt
		local lvC = hull:FindFirstChild("FlightVelocity") :: LinearVelocity?
		local aoC = hull:FindFirstChild("FlightOrientation") :: AlignOrientation?
		if lvC then
			lvC.Enabled = false
		end
		if aoC then
			aoC.Enabled = false
		end
		hull.AssemblyLinearVelocity = Vector3.zero
		hull.AssemblyAngularVelocity = Vector3.zero
		local tumbleCF = hull.CFrame * CFrame.Angles(math.rad(-90 * clampedDt), math.rad(180 * clampedDt), math.rad(260 * clampedDt))
		hull.CFrame = tumbleCF
		local lv = hull:FindFirstChild("FlightVelocity") :: LinearVelocity?
		if lv then
			lv.VectorVelocity = Vector3.zero
		end
		updateChaseCamera(hull.CFrame, clampedDt)
		if FlightController.crashTimer <= 0 then
			if LocalPlayer:GetAttribute("BattleOut") == true then
				-- Out of a battle (trap audit X-03): the wreck levels off where it went out, a spectator, never back on its pad.
				local look = hull.CFrame.LookVector
				local level = Vector3.new(look.X, 0, look.Z)
				local p = hull.Position
				FlightController.completeRespawn(CFrame.lookAt(p, p + (if level.Magnitude > 0.01 then level.Unit else Vector3.new(0, 0, -1))))
			elseif pendingReturnCF then
				-- RETURN to course: the server's frame (it is already announced to the position validator).
				local cf = pendingReturnCF
				pendingReturnCF = nil
				FlightController.completeRespawn(cf, true)
			else
				FlightController.completeRespawn(FlightController.lastCheckpointCF)
			end
		end
		return
	end

	-- Out of a battle (player attribute BattleOut, server BattleCore): hover level where the plane is, as a spectator.
	if LocalPlayer:GetAttribute("BattleOut") == true then
		if not battleOutHoldCF then
			local look = hull.CFrame.LookVector
			local level = Vector3.new(look.X, 0, look.Z)
			battleOutHoldCF = CFrame.lookAt(hull.Position, hull.Position + (if level.Magnitude > 0.01 then level.Unit else Vector3.new(0, 0, -1)))
		end
	else
		battleOutHoldCF = nil
	end
	if workspace:GetAttribute("TrackSwitching") == true then
		if not switchHoldCF then
			local look = hull.CFrame.LookVector
			local level = Vector3.new(look.X, 0, look.Z)
			switchHoldCF = CFrame.lookAt(hull.Position, hull.Position + (if level.Magnitude > 0.01 then level.Unit else Vector3.new(0, 0, -1)))
		end
	else
		switchHoldCF = nil
	end

	-- Start countdown (TrackDirector, workspace.RaceGoTime): hover on the grid until GO, released at cruise speed.
	-- Also held while the server swaps maps under the curtain (workspace.TrackSwitching): the ground is about to vanish.
	-- Per group (economy v3 phase 2b) GO is this player's own race's (shared/RaceAttr.mine; workspace when off).
	local goTime = RaceAttr.mine("RaceGoTime")
	if battleOutHoldCF or switchHoldCF or (type(goTime) == "number" and workspace:GetServerTimeNow() < goTime) then
		local holdCF = battleOutHoldCF or switchHoldCF or FlightController.lastCheckpointCF
		if not holdCleared then
			-- Style lane / leash: no wake, sizzle or WRONG WAY arrow on the grid, under the curtain or spectating.
			holdCleared = true
			StyleSense.stop()
			CourseArrow.set(false, 0, 0)
			leash = PlaneConfig.newLeash()
			FlightGuide.hide()
			FlightGuideRules.resetOff(offState)
			offVerdict = "inside"
		end
		hull.AssemblyLinearVelocity = Vector3.zero
		local lvH = hull:FindFirstChild("FlightVelocity") :: LinearVelocity?
		if lvH then
			lvH.VectorVelocity = Vector3.zero
		end
		simPos = holdCF.Position
		-- Start grid (REMARKABLE items 5-6, planes): a sharp-bank press wobbles the wings, the gas revs the engine and
		-- propeller, and the rev-match start is judged. Orientation only: the hold position is untouched.
		local wobble = 0
		local onPlaneGrid = not battleOutHoldCF and workspace:GetAttribute("TrackSwitching") ~= true and type(goTime) == "number"
			and workspace:GetAttribute("AutoPilot") ~= true
		if onPlaneGrid then
			local left = goTime - workspace:GetServerTimeNow()
			if gridRevCueFor ~= goTime and left <= 1.15 and left > 0 then
				gridRevCueFor = goTime
				Sfx.play("grid_rev", 0.7, 0.4) -- the rev blip just before GO (lower on a plane)
			end
			if planeStartGo ~= goTime then
				planeStartGo = goTime
				planeStart = TrickRules.newStart()
				planeStartPending = true
			end
			local gSteer, gThrottle, gSharp = readCombinedInputs(clampedDt)
			if gSharp and not lastSharpPress then
				gridWobbleClock = os.clock()
				gridWobbleDir = if math.abs(gSteer.X) > 0.2 then math.sign(gSteer.X) else -gridWobbleDir
				TrickJuice.play("trick_whoosh", 1.15, 0.35)
			end
			lastSharpPress = gSharp
			wobble = TrickRules.gridWobbleDeg(os.clock() - gridWobbleClock, gridWobbleDir)
			local touch = LocalPlayer:GetAttribute("InputMode") == "Touch"
			local pressed = not touch and gThrottle > 0.8
			local before = planeStart.state
			local state = TrickRules.stepStart(planeStart, pressed, left, not touch)
			TrickJuice.setStartRing(left <= TrickRules.TOUCH_TAP_SHOW_LEFT, left >= TrickRules.START_WINDOW_LO and left <= TrickRules.START_WINDOW_HI, if touch then FlightController.onStartTap else nil)
			local revTarget = if pressed then 1 else 0.1
			if state == "flooded" then
				revTarget = 0.3 + 0.25 * math.sin(os.clock() * 23)
				planeFloodPuff -= clampedDt
				if before ~= "flooded" or planeFloodPuff <= 0 then
					planeFloodPuff = 0.7
					Vfx.burst("floodPuff", planeExhaustCF(hull), 0.35)
				end
			end
			gridRev += (revTarget - gridRev) * math.clamp(clampedDt / 0.15, 0, 1)
		else
			TrickJuice.setStartRing(false, false, nil)
			gridRev = 0
		end
		hull.CFrame = holdCF * CFrame.new(0, math.sin(os.clock() * 3) * 0.3, 0) * CFrame.Angles(math.rad(gridRev * 2), 0, math.rad(-wobble))
		FlightController.currentSpeed = PlaneConfig.BASE_SPEED
		if onPlaneGrid then
			-- Propeller and engine pitch follow the revs (SoundJuice maps speed 70..210 to pitch 0.75..1.65).
			stepSpinningPropeller(hull, clampedDt, 70 + (TrickRules.revPitch(gridRev) - 0.75) / 0.9 * 140, gridRev, 0)
		end
		updateChaseCamera(hull.CFrame, clampedDt)
		return
	end
	holdCleared = false
	-- One position for the whole frame (plane_stutter.md C3): simPos, not hull.Position. Between two frames physics moves
	-- the unanchored hull by its velocity for however many 240 Hz substeps it ran (a count that varies frame to frame), so
	-- hull.Position carried up to a substep of noise (~0.8 studs at 200 studs/s) into the course assist, the leash, the
	-- guide, the ring pull and the magnet. A server teleport (reset, respawn, RETURN) is the hull landing further from
	-- simPos than that drift explains: follow it. (The old check left the drift in, so a 0.2 s frame at 210 studs/s read
	-- as a teleport and the plane moved twice that frame.)
	local drift = hull.AssemblyLinearVelocity * clampedDt
	if simPos == nil or (hull.Position - drift - (simPos :: Vector3)).Magnitude > 40 then
		simPos = hull.Position
	end
	local here = simPos :: Vector3
	if planeStartPending then
		FlightController.applyStart(goTime)
	end

	local steer, throttle, sharp = readCombinedInputs(clampedDt)
	local playerSteer, playerSharp = steer, sharp

	-- Items v4: Rocket Rush flies the same line follower as the QA AutoPilot for its few seconds (itemAutoTimer).
	if workspace:GetAttribute("AutoPilot") == true or FlightController.itemAutoTimer > 0 then
		local curStation, _, _, _ = SplineUtils.projectPosition(here, LocalPlayer:GetAttribute("Station") :: number?)
		local lookahead = 60 + FlightController.currentSpeed * 0.55
		local aheadPos, _, aheadBank = SplineUtils.sampleAtStation(curStation + lookahead)
		local aheadTarget = aheadPos + Vector3.new(0, 12, 0)
		if IS_STUDIO then
			aheadTarget = qaLineTarget(here, curStation, aheadTarget, lookahead)
		end
		local toAhead = aheadTarget - here
		if toAhead.Magnitude > 1 then
			local targetYaw, targetPitch = headingAndPitchFromVector(toAhead.Unit)
			local yawErr = ((targetYaw - FlightController.yawDeg + 540) % 360) - 180
			steer = Vector2.new(math.clamp(-yawErr / 34, -1, 1), math.clamp((targetPitch - FlightController.pitchDeg) / 22, -1, 1))
			sharp = math.abs(yawErr) > 40
			if math.abs(aheadBank) > 18 then
				sharp = true
			end
		end
		throttle = 1
		assistShareY = 1 -- QA autopilot owns the pitch: no auto-level against it
	elseif RaceAttr.mine("RaceMode") == "hub" and (FlightController.steerAssist or FlightController.rescueAssistTimer > 0) then
		-- Hub free flight (exchange plane, G4): the race loop runs through a car tunnel and along cliff roads, so an idle
		-- plane is not steered along it; it circles the island above the spire and the ridge instead.
		local target = hubOrbitTarget(here)
		steer, sharp = Vector2.zero, false
		local toTarget = target - here
		if toTarget.Magnitude > 1 then
			local targetYaw, targetPitch = headingAndPitchFromVector(toTarget.Unit)
			local yawErr = ((targetYaw - FlightController.yawDeg + 540) % 360) - 180
			steer = Vector2.new(math.clamp(-yawErr / 40, -0.7, 0.7), math.clamp((targetPitch - FlightController.pitchDeg) / 18, -0.8, 0.8))
		end
		steer, sharp = blendAssist(playerSteer, playerSharp, steer, sharp, clampedDt)
	elseif (FlightController.steerAssist or FlightController.rescueAssistTimer > 0) and (os.clock() - FlightController.joinClock > 0.65) and RaceAttr.mine("RaceMode") ~= "battle" then
		-- (No course assist in a battle arena: there is no route to steer toward.) RESCUE GLIDE turns it on for a
		-- moment even when the player switched it off.
		steer, sharp = Vector2.zero, false
		-- G8: the line the plane is on (main, or an alternate tunnel / ledge / key gallery). The old RouteBranch block
		-- (DINO-4 builder coordinates, ~8,000 studs off SNOW-1, never set by anything: SN-11) is gone.
		local curStation, line, along, distToRibbon = sampleCourse(here)
		if distToRibbon < 420 or line then
			courseFresh = true -- the leash below reuses this frame's sample and pursuit point
			local lookahead = PlaneConfig.assistLookahead(FlightController.currentSpeed)
			-- Curvature-aware pursuit: on tight turns aim nearer so the assist tracks the line instead of
			-- cutting the chord across the inside of the bend (hairpin wall hits, 2026-10-18 lap runs). An alternate
			-- line shortens its own lookahead in tunnels (RouteBranch.target).
			if not line then
				local q0 = SplineUtils.sampleAtStation(curStation)
				local q1 = SplineUtils.sampleAtStation(curStation + lookahead * 0.5)
				local q2 = SplineUtils.sampleAtStation(curStation + lookahead)
				local a, b = q1 - q0, q2 - q1
				if a.Magnitude > 1 and b.Magnitude > 1 then
					local turnDeg = math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
					if turnDeg > 18 then
						lookahead = math.max(35, lookahead * 18 / turnDeg)
					end
				end
			end
			local targetPos, aheadBank = courseAhead(curStation, line, along, lookahead)
			courseTarget = targetPos
			local toAhead = targetPos - here
			if toAhead.Magnitude > 1 then
				local targetYaw, targetPitch = headingAndPitchFromVector(toAhead.Unit)
				local yawErr = ((targetYaw - FlightController.yawDeg + 540) % 360) - 180
				steer = Vector2.new(
					math.clamp(-yawErr / PlaneConfig.ASSIST_YAW_GAIN_DEG, -PlaneConfig.ASSIST_MAX_X, PlaneConfig.ASSIST_MAX_X),
					math.clamp((targetPitch - FlightController.pitchDeg) / PlaneConfig.ASSIST_PITCH_GAIN_DEG, -PlaneConfig.ASSIST_MAX_Y, PlaneConfig.ASSIST_MAX_Y)
				)
				if math.abs(yawErr) > 30 or math.abs(aheadBank) > 16 then
					sharp = true
				end
			end
		end
		-- Never written into mobileSteer (that is the touch D-pad's slot).
		steer, sharp = blendAssist(playerSteer, playerSharp, steer, sharp, clampedDt)
	end
	if IS_STUDIO then
		-- QASteer / QAThrottle (-1..1): a probe holds an exact input (steer = the yaw axis); same variables a player feeds.
		local qs = QASteerRules.axis(IS_STUDIO, workspace:GetAttribute(QASteerRules.STEER_ATTR))
		if qs then
			steer = Vector2.new(qs, steer.Y)
		end
		throttle = QASteerRules.axis(IS_STUDIO, workspace:GetAttribute(QASteerRules.THROTTLE_ATTR)) or throttle
	end
	-- Course leash (trap audit G5.4: F5, SN-10, D4-09). Past LEASH_RESPAWN for LEASH_RESPAWN_TIME the plane is put back
	-- on the course (the emergency rescue, both modes). In a race the leash neither steers nor shows its arrow
	-- (FLIGHT_GUIDE.md 12: no pull toward the path, no off-course messages); outside the guided race (a finished racer)
	-- it still shows the WRONG WAY arrow past LEASH_WARN and pulls the steering back, assist on or off. Steering only.
	if leashActive() then
		local guiding = guideActive()
		if not courseFresh then
			courseClock += clampedDt
			if courseClock >= 1 / PlaneConfig.LEASH_HZ or courseTarget == nil then
				courseClock = 0
				local st, line, along = sampleCourse(here)
				courseTarget = (courseAhead(st, line, along, 90))
			end
		end
		local verdict = PlaneConfig.leashStep(leash, courseDist, clampedDt)
		local w = PlaneConfig.leashWeight(courseDist)
		local shownDist = math.floor(courseDist / 5) * 5 -- QA probe: CourseDist in 5-stud steps, written on change
		if shownDist ~= lastShownCourseDist then
			lastShownCourseDist = shownDist
			LocalPlayer:SetAttribute("CourseDist", shownDist)
		end
		local yawErr = 0
		local tgt = courseTarget
		if tgt then
			local to = tgt - here
			if to.Magnitude > 1 then
				local ty, tp = headingAndPitchFromVector(to.Unit)
				yawErr = ((ty - FlightController.yawDeg + 540) % 360) - 180
				local pullW = if guiding and not FlightGuideRules.LEASH_PULL_IN_RACE then 0 else w
				if pullW > 0 then
					local pullX = math.clamp(-yawErr / 26, -1, 1)
					local pullY = math.clamp((tp - FlightController.pitchDeg) / 18, -1, 1)
					steer = Vector2.new(steer.X + (pullX - steer.X) * pullW, steer.Y + (pullY - steer.Y) * pullW)
					sharp = sharp or (pullW >= 0.5 and math.abs(yawErr) > 30)
				end
			end
		end
		-- Flight modes (FLIGHT_GUIDE.md 12). Default: past the course bounds (130, outside every allow-pocket) for 0.3 s
		-- the plane is put back at once, no caption, no button, nothing drawn. Free driving: the bead mist, RETURN after
		-- 2 s past 80, a gentle return when far (200) with no progress for 15 s. Both: WRONG WAY after 3 s heading away.
		local wrongWay = false
		local mode = flightMode()
		if guiding then
			local dist = courseDist
			offSample.dist = dist
			-- Pockets only matter past the bounds: nothing is checked on the path.
			offSample.inPocket = dist > FlightGuideRules.BOUND and FlightGuideRules.inPocket(pockets(), here)
			offSample.station = sampleStation
			local _, trackLength = SplineUtils.loadWaypoints()
			offSample.trackLength = trackLength
			offSample.yawErr = yawErr
			offVerdict, wrongWay = FlightGuideRules.stepMode(offState, mode, offSample, clampedDt)
			if mode == FlightGuideRules.MODE_FREE then
				FlightGuide.step(clampedDt, here, sampleStation, sampleLine, sampleAlong)
			else
				FlightGuide.hide()
			end
		else
			FlightGuideRules.resetOff(offState)
			offVerdict = "inside"
			FlightGuide.hide()
		end
		-- The chevron points the way to turn: +yawErr = the course is to the left (the assist steers -X).
		CourseArrow.set(wrongWay or (leash.warn and not guiding), -yawErr, w)
		if lastOffAttr ~= offState.out then
			lastOffAttr = offState.out
			LocalPlayer:SetAttribute("OffCourse", offState.out)
		end
		local auto = if guiding and (offVerdict == "bounds" or offVerdict == "lost") then offVerdict else nil
		if verdict == "respawn" or auto then
			local far = verdict == "respawn"
			print(string.format("[SkyRally][FLIGHT] %s dist=%.0f mode=%s", if far then "leash respawn" else auto :: string, courseDist, mode))
			if far then
				LocalPlayer:SetAttribute("LeashRespawns", ((LocalPlayer:GetAttribute("LeashRespawns") :: number?) or 0) + 1)
				leash = PlaneConfig.newLeash()
			end
			-- Racing: the server's RETURN frame (near where the plane left, never ahead of its best progress); the old
			-- last-checkpoint rescue only when that cannot be asked (or, via returnFailed, when it is refused).
			local reason = if far then "Far" elseif auto == "bounds" then "Bounds" else "Lost"
			if not (guiding and (returnPending ~= nil or FlightController.requestCourseReturn(reason))) then
				if reason ~= "Bounds" then
					CourseArrow.rescued() -- the arrow says "BACK YOU GO!" through the rescue poof; completeRespawn hides it
				end
				FlightController.triggerCrash("Leash", nil, true)
				return
			end
		end
	elseif leash.warn or leash.outTimer > 0 then
		leash = PlaneConfig.newLeash()
		CourseArrow.set(false, 0, 0)
	end
	if not leashActive() then
		if offVerdict ~= "inside" or offState.out then
			FlightGuideRules.resetOff(offState)
			offVerdict = "inside"
		end
		FlightGuide.hide()
	end
	courseFresh = false
	local edgeW, edgeErr = battleEdgePull(here)
	if edgeW > 0 then
		-- Toward the arena edge: blend toward the centre (gently from the pull start, at least a third from 90 % of the
		-- play radius, all of it at the boundary).
		local pull = math.clamp(-edgeErr / 26, -1, 1)
		steer = Vector2.new(steer.X + (pull - steer.X) * edgeW, steer.Y)
		sharp = sharp or (edgeW >= 0.35 and math.abs(edgeErr) > 30)
	end
	local highW, highErr = battleCeilingPull(here)
	if highW > 0 then
		-- Under the battle ceiling: blend the pitch toward a shallow dive (all of it at the ceiling).
		local pull = math.clamp(highErr / 18, -1, 1)
		steer = Vector2.new(steer.X, steer.Y + (pull - steer.Y) * math.max(highW, 0.35))
	end
	if FlightController.itemStunTimer > 0 then
		steer, sharp = Vector2.zero, false -- spinning out: no control until it ends
	end
	LocalPlayer:SetAttribute("SteerX", math.floor(steer.X * 100) / 100)
	LocalPlayer:SetAttribute("PlayerSteerX", math.floor(playerSteer.X * 100) / 100)
	LocalPlayer:SetAttribute("AssistWeight", math.floor(FlightController.assistWeight * 100) / 100)

	-- FLOODED start: the gas is capped for FLOOD_TIME after GO.
	if planeFloodTimer > 0 then
		planeFloodTimer = math.max(0, planeFloodTimer - clampedDt)
		throttle = math.min(throttle, TrickRules.FLOOD_THROTTLE_CAP)
	end

	-- Dodge / barrel roll (REMARKABLE item 7): DOUBLE-TAP left or right (A/D or arrows, D-pad or stick flick twice, a double
	-- tap on the touch steer pad), rolling to that side. Raw input only, never the course assist, never while stunned;
	-- BarrelRoll = false turns it off. A single tap or a held steer never dodges (shared/DodgeRules).
	local nowClock = os.clock()
	rollCooldown = math.max(0, rollCooldown - clampedDt)
	local flickDir = DodgeRules.step(rollTap, rawDodgeX, nowClock)
	if flickDir ~= 0 and rollCooldown <= 0 and FlightController.rollTimer <= 0 and FlightController.itemStunTimer <= 0
		and LocalPlayer:GetAttribute("BarrelRoll") ~= false and workspace:GetAttribute("AutoPilot") ~= true then
		FlightController.rollTimer = TrickRules.ROLL_TIME
		rollDir = flickDir
		rollCooldown = TrickRules.ROLL_COOLDOWN
		TrickJuice.play(if rollDir > 0 then "roll_whoosh_r" else "roll_whoosh_l")
		StyleChain.event("Roll") -- REMARKABLE 17
		FlightController.reportRoll() -- missile v3: the server judges a dodge from this
		LocalPlayer:SetAttribute("RollCount", ((LocalPlayer:GetAttribute("RollCount") :: number?) or 0) + 1)
		print(string.format("[SkyRally][ROLL] dir=%d source=doubletap lap=%s", rollDir, tostring(LocalPlayer:GetAttribute("Lap"))))
	end
	if FlightController.rollTimer > 0 then
		FlightController.rollTimer = math.max(0, FlightController.rollTimer - clampedDt)
		if FlightController.rollTimer == 0 then
			rollEndClock = nowClock
		end
	end

	FlightController.steerInput = steer
	FlightController.throttleInput = throttle
	FlightController.sharpBank = sharp

	if throttle <= -0.1 or (not FlightController.autoThrottle and math.abs(throttle) < 0.05) then
		throttleReleaseDuration = math.min(2.0, throttleReleaseDuration + clampedDt)
	else
		throttleReleaseDuration = math.max(0, throttleReleaseDuration - clampedDt * 2.5)
	end

	if FlightController.boostTimer > 0 then
		FlightController.boostTimer = math.max(0, FlightController.boostTimer - clampedDt)
		if FlightController.boostTimer == 0 then
			FlightController.boostState = "None"
			LocalPlayer:SetAttribute("BoostState", "None")
		end
	end

	local pickupBonus = FlightController.speedPickups * PlaneConfig.SPEED_PICKUP_BONUS
	local baseTarget = PlaneConfig.BASE_SPEED + pickupBonus
	if throttle > 0.05 then
		baseTarget = baseTarget + (PlaneConfig.FULL_THROTTLE_SPEED - PlaneConfig.BASE_SPEED) * throttle
	elseif throttle < -0.05 then
		baseTarget = PlaneConfig.MIN_CRUISE_SPEED + (baseTarget - PlaneConfig.MIN_CRUISE_SPEED) * (1 + throttle)
	end

	local diveAssist = -math.sin(math.rad(FlightController.pitchDeg)) * 12
	local targetSpeed = math.max(PlaneConfig.MIN_CRUISE_SPEED, baseTarget + diveAssist)

	if FlightController.boostState == "Overcharge" then
		targetSpeed = PlaneConfig.OVERCHARGE_SPEED + pickupBonus
	elseif FlightController.boostState == "Standard" then
		targetSpeed = PlaneConfig.BOOST_SPEED + pickupBonus
	end

	if FlightController.itemBoostTimer > 0 then
		targetSpeed = math.max(targetSpeed, FlightController.itemBoostSpeed + pickupBonus) -- item boost levels 1-3
	end
	-- No off-path slowdown in either flight mode (FLIGHT_GUIDE.md 12: secret routes sit a little off the path).
	local accelRate = if targetSpeed > FlightController.currentSpeed then 9.0 else 4.5
	FlightController.currentSpeed = FlightController.currentSpeed + (targetSpeed - FlightController.currentSpeed) * math.clamp(clampedDt * accelRate, 0, 1)
	if FlightController.itemStunTimer > 0 then
		FlightController.currentSpeed = math.min(FlightController.currentSpeed, PlaneConfig.BASE_SPEED * ItemRules.TUNING.stunSpeedFactor)
	elseif FlightController.itemSlowTimer > 0 then
		-- Items v4: a slow eases the plane down to its cap (never a hard stop; the slow itself is capped server-side).
		local cap = PlaneConfig.BASE_SPEED * FlightController.itemSlowFactor
		if FlightController.currentSpeed > cap then
			FlightController.currentSpeed += (cap - FlightController.currentSpeed) * math.clamp(clampedDt * 6, 0, 1)
		end
	end

	local pitchRate = if sharp then PlaneConfig.SHARP_PITCH_RATE else PlaneConfig.PITCH_RATE
	local yawRate = if sharp then PlaneConfig.SHARP_YAW_RATE else PlaneConfig.YAW_RATE
	if FlightController.boostState ~= "None" and not sharp then
		pitchRate = PlaneConfig.BOOST_PITCH_RATE
		yawRate = PlaneConfig.BOOST_YAW_RATE
	end

	local maxPitch = if sharp then PlaneConfig.SHARP_MAX_PITCH_DEG else PlaneConfig.MAX_PITCH_DEG
	-- Auto-level scaled by the stick's headroom (flight_feel.md C1); never against the course assist's pitch.
	FlightController.pitchDeg = PlaneConfig.pitchStep(FlightController.pitchDeg, steer.Y, pitchRate, maxPitch, clampedDt, 1 - assistShareY)

	camYawRate = -steer.X * yawRate
	FlightController.yawDeg = (FlightController.yawDeg - steer.X * yawRate * clampedDt) % 360
	FlightController.yawDeg = magnetYaw(FlightController.yawDeg, here, clampedDt)

	local maxBank = if sharp then PlaneConfig.SHARP_MAX_BANK_DEG else PlaneConfig.MAX_BANK_DEG
	local targetBank = -steer.X * maxBank
	FlightController.bankDeg = FlightController.bankDeg + (targetBank - FlightController.bankDeg) * math.clamp(clampedDt * PlaneConfig.BANK_LERP_SPEED, 0, 1)

	local newOrientation = CFrame.Angles(0, math.rad(FlightController.yawDeg), 0)
		* CFrame.Angles(math.rad(FlightController.pitchDeg), 0, 0)
		* CFrame.Angles(0, 0, math.rad(FlightController.bankDeg))

	local lookVec = newOrientation.LookVector
	local pullVel = evaluateRingsAndPads(here, lookVec, clampedDt)
	pullVel += stepItemEffects(clampedDt, here)
	local velocityVec = lookVec * FlightController.currentSpeed + pullVel
	-- One authoritative simulated position. The hull is also unanchored with a LinearVelocity (for replication), so
	-- physics moves it between frames; integrating from hull.Position counted that motion twice (measured 2.05x the
	-- configured speed on 2026-10-18). Integrate from simPos and overwrite the physics drift every frame (the teleport
	-- check is at the top of the flying step).
	local fromPos = here
	local nextPos = fromPos + velocityVec * clampedDt

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	local planesFolder = workspace:FindFirstChild("Planes")
	if planesFolder then
		table.insert(exclude, planesFolder)
	end
	if LocalPlayer.Character then
		table.insert(exclude, LocalPlayer.Character)
	end
	rayParams.FilterDescendantsInstances = exclude

	local stepVec = nextPos - fromPos
	local castDir = if stepVec.Magnitude > 0.05 then stepVec.Unit * math.max(stepVec.Magnitude + 4.5, 6.0) else lookVec * 6.0
	local hit = workspace:Raycast(fromPos, castDir, rayParams)

	if hit and hit.Instance then
		local hitPart = hit.Instance
		if hitPart:GetAttribute("HazardType") == "LethalLava" or hitPart.Name == "LavaSeaFloor" then
			if FlightController.invulnTimer > 0 then
				-- Invulnerable (just respawned): lift clear and keep flying instead of freezing in place.
				nextPos = Vector3.new(nextPos.X, math.max(nextPos.Y, hit.Position.Y + 8), nextPos.Z)
			else
				FlightController.triggerCrash("LethalLava", hitPart)
				return
			end
		elseif hitPart.CanCollide then
			local impactDot = lookVec:Dot(hit.Normal)
			local isTrackSurface = hitPart.Name:match("^TrackSeg_") ~= nil or hitPart.Name:match("^Curb") ~= nil or hitPart.Name:match("^Paver_") ~= nil or hitPart.Name:match("^BridgeFascia_") ~= nil or hitPart.Name:match("^Alt") ~= nil or hitPart.Name:match("^TunnelRamp") ~= nil
			if isTrackSurface then
				lastWallTouch = os.clock() -- a surface touch voids a near miss (StyleSense)
				nextPos = hit.Position + hit.Normal * 6.0
				if hit.Normal.Y > 0.3 and FlightController.pitchDeg < 6 then
					FlightController.pitchDeg = 8
				end
			elseif impactDot < PlaneConfig.WALL_DEFLECT_DOT and FlightController.invulnTimer <= 0 then
				FlightController.triggerCrash("WallHit", hitPart)
				return
			else
				lastWallTouch = os.clock()
				nextPos = hit.Position + hit.Normal * 5.5
				if hit.Normal.Y > 0.4 and FlightController.pitchDeg < 4 then
					FlightController.pitchDeg = 6
				else
					local slideDir = (lookVec - hit.Normal * impactDot)
					-- Wall scrape: pooled sparks at the contact point, sprayed off the wall (away from the chase camera).
					if AirFxRules.scrapeDue(os.clock(), lastScrapeSparks) then
						lastScrapeSparks = os.clock()
						GroundFx.sparkSpray(hit.Position, hit.Normal, AirFxRules.SCRAPE_SPARKS, "wall")
						FlightController.addTrauma(AirFxRules.SCRAPE_TRAUMA)
					end
					if os.clock() - lastScrapeSfx > 0.3 then
						lastScrapeSfx = os.clock()
						Sfx.play("wall_scrape", 0.9 + math.random() * 0.2, 0.4)
					end
					if slideDir.Magnitude > 0.1 then
						local newYaw, newPitch = headingAndPitchFromVector(slideDir.Unit)
						FlightController.yawDeg = newYaw
						FlightController.pitchDeg = math.clamp(newPitch, -45, 45)
					end
				end
			end
		end
	end

	if nextPos.Y <= 16 then
		if FlightController.invulnTimer > 0 then
			nextPos = Vector3.new(nextPos.X, 18, nextPos.Z)
		else
			FlightController.triggerCrash("LavaFloor")
			return
		end
	end

	-- Stuck watchdog (G5): a plane always has the gas on, so one pinned in the same 8-stud ball for STUCK_OFFER seconds
	-- (wedged against a wall it keeps deflecting off) gets the RESPAWN button pulsing, and the rescue at STUCK_AUTO.
	-- An item stun freezes the watch (no time, no reset).
	local verdict = RespawnRules.stepWatch(stuckWatch, nextPos, true, FlightController.rescueAllowed(), clampedDt, FlightController.itemStunTimer > 0)
	FlightController.stuckOffer = verdict == "offer"
	if verdict == "auto" then
		FlightController.requestManualRespawn("Stuck")
	end

	local finalCF = CFrame.new(nextPos) * newOrientation.Rotation
	simPos = nextPos
	-- The barrel roll is the last rotation, about the hull's own forward axis: LookVector (and the flight path,
	-- the camera and the synced frame, which all use finalCF) stays the same.
	local shownCF = if FlightController.rollTimer > 0
		then finalCF * CFrame.Angles(0, 0, -math.rad(TrickRules.rollDeg(FlightController.rollTimer, rollDir)))
		else finalCF
	hull.CFrame = shownCF
	hull.AssemblyLinearVelocity = velocityVec
	hull.AssemblyAngularVelocity = Vector3.zero

	local lv = hull:FindFirstChild("FlightVelocity") :: LinearVelocity?
	if lv then
		lv.VectorVelocity = velocityVec
	end
	local ao = hull:FindFirstChild("FlightOrientation") :: AlignOrientation?
	if ao then
		ao.CFrame = shownCF
	end
	applyItemSpin(hull, finalCF)

	stepSpinningPropeller(hull, clampedDt, FlightController.currentSpeed, FlightController.throttleInput)
	-- REMARKABLE 16: near-miss sparks and the lava-skim ember wake (two side rays at 20 Hz, a down ray at 10 Hz). The
	-- side rays run level (heading only): a banked wing over flat ground is not a near miss, a canyon wall is.
	local levelCF = CFrame.new(nextPos) * CFrame.Angles(0, math.rad(FlightController.yawDeg), 0)
	if StyleSense.step(clampedDt, "plane", hull, levelCF, FlightController.currentSpeed, PlaneConfig.FULL_THROTTLE_SPEED, lastWallTouch) then
		FlightController.addTrauma(0.06)
	end
	updateChaseCamera(finalCF, clampedDt, velocityVec)

	syncAccumulator = syncAccumulator + clampedDt
	if syncAccumulator >= 0.08 and flightStateRemote then
		syncAccumulator = 0
		flightStateRemote:FireServer("SyncTransform", {
			cframe = finalCF,
			speed = FlightController.currentSpeed,
			boostState = FlightController.boostState,
		})
	end
end

function FlightController.init()
	if FlightController.initialized then
		return
	end
	FlightController.initialized = true
	FlightController.joinClock = os.clock()

	initSounds()
	StyleChain.init() -- REMARKABLE 17: the chain meter, its fuse and the per-race reset

	-- ASSIST: the saved value (SettingsService publishes AutoThrottle on load) wins; a fresh client starts on.
	if LocalPlayer:GetAttribute("AutoThrottle") == nil then
		LocalPlayer:SetAttribute("AutoThrottle", true)
	end
	FlightController.setAssist(LocalPlayer:GetAttribute("AutoThrottle") ~= false)
	LocalPlayer:GetAttributeChangedSignal("AutoThrottle"):Connect(function()
		FlightController.setAssist(LocalPlayer:GetAttribute("AutoThrottle") ~= false)
	end)
	LocalPlayer:SetAttribute("SpeedPickups", 0)
	LocalPlayer:SetAttribute("BoostState", "None")

	-- Remotes (trap audit, stale-respawn root cause): the server builds the boot map (60-70 s under load in Studio)
	-- BEFORE FlightServer/CarServer create FlightStateRemote and RaceEventRemote, while SkyRallyRemotes itself exists
	-- early (Economy, CosmeticService). A 5 s WaitForChild gave up, so this client never heard PlaneMounted, RaceReset or
	-- CheckpointRespawn and never sent RequestRespawn or SyncTransform for the whole session. Wait for them in the
	-- background for as long as it takes; the step runs meanwhile (every use is nil-checked).
	local function onRaceEvent(eventType: string, data: any)
		-- While this player drives a car, the car's frames are CarController's: setPoseFromCFrame moves the character's
		-- root, which is welded inside the car, so a pose here would pop the car to the frame with no fade.
		local inCar = carBound()
		if eventType == "PlaneMounted" and type(data) == "table" then
			if typeof(data.startCFrame) == "CFrame" then
				FlightController.lastCheckpointCF = data.startCFrame
				FlightController.setPoseFromCFrame(data.startCFrame)
			end
		elseif eventType == "CheckpointPassed" and type(data) == "table" then
			if typeof(data.respawnCFrame) == "CFrame" then
				FlightController.lastCheckpointCF = data.respawnCFrame
			end
		elseif eventType == "LapCompleted" or eventType == "RaceFinished" then
			FlightController.playFanfare(if eventType == "RaceFinished" then "Finish" else "Lap")
			local hf = FlightController.hull
			if hf and eventType == "RaceFinished" then
				Vfx.onFinish(hf.Position + hf.CFrame.LookVector * 30 + Vector3.new(0, 6, 0))
			end
		elseif eventType == "CheckpointRespawn" and type(data) == "table" then
			if typeof(data.cframe) == "CFrame" and not inCar then
				FlightController.lastCheckpointCF = data.cframe
				FlightController.crashing = false
				FlightController.crashTimer = 0
				FlightController.currentSpeed = PlaneConfig.BASE_SPEED
				FlightController.setPoseFromCFrame(data.cframe)
				FlightController.invulnTimer = PlaneConfig.RESPAWN_INVULN
				FlightGuideRules.startGrace(offState)
				pendingReturnCF = nil
				lastRespawnClock = os.clock()
				FlightController.lastRespawnAt = lastRespawnClock
				FlightController.clearItemEffects()
				Sfx.play("respawn_pop", 1, 0.58)
				local lvC = if FlightController.hull then FlightController.hull:FindFirstChild("FlightVelocity") :: LinearVelocity? else nil
				local aoC = if FlightController.hull then FlightController.hull:FindFirstChild("FlightOrientation") :: AlignOrientation? else nil
				if lvC then
					lvC.Enabled = true
				end
				if aoC then
					aoC.Enabled = true
				end
			end
		elseif eventType == "CourseReturn" and type(data) == "table" then
			-- RETURN to course (FLIGHT_GUIDE.md 4.3): the server's frame, after the short rescue poof. Never the checkpoint.
			-- A reply that arrives after the client gave up still lands (the server already told the position validator
			-- to expect this frame), unless a respawn has superseded the request since.
			local pend = returnPending
			returnPending = nil
			local superseded = lastRespawnClock > lastReturnRequest and not FlightController.crashing
			if typeof(data.cframe) == "CFrame" and not inCar and not superseded then
				pendingReturnCF = data.cframe
				LocalPlayer:SetAttribute("CourseReturns", ((LocalPlayer:GetAttribute("CourseReturns") :: number?) or 0) + 1)
				-- "BACK YOU GO!" for Free driving's lost return and the far rescue; a bounds reset says nothing (Mario Kart).
				local why = if pend then pend.reason else data.reason
				if why == "Lost" or why == "Far" then
					CourseArrow.rescued()
				end
				if not FlightController.crashing then
					FlightController.triggerCrash("Return", nil, true)
				end
			end
		elseif eventType == "CourseReturnRefused" and type(data) == "table" then
			returnFailed(if type(data.why) == "string" then data.why else "refused")
		elseif eventType == "RaceReset" and type(data) == "table" then
			FlightController.speedPickups = 0
			returnPending = nil
			pendingReturnCF = nil
			FlightGuideRules.resetOff(offState)
			FlightController.boostState = "None"
			FlightController.boostTimer = 0
			FlightController.crashing = false
			FlightController.cameraTrauma = 0
			FlightController.hitStopTimer = 0
			FlightController.invulnTimer = 2.0
			FlightController.joinClock = os.clock()
			FlightController.rescueAssistTimer = 0
			FlightController.clearItemEffects()
			RespawnRules.resetWatch(stuckWatch)
			loopGuard = RespawnRules.newLoopGuard()
			if typeof(data.startCFrame) == "CFrame" and not inCar then
				bindToPlane()
				FlightController.lastCheckpointCF = data.startCFrame
				FlightController.setPoseFromCFrame(data.startCFrame)
				updateChaseCamera(data.startCFrame, 1.0)
			end
		elseif eventType == "VehicleExchange" and type(data) == "table" then
			-- Hub exchange pad (G4, server TrackDirector.exchangeVehicle): the pop at the pad, whichever controller
			-- binds the new vehicle a frame later.
			local cf = if typeof(data.cframe) == "CFrame" then data.cframe else nil
			if cf then
				Vfx.onRespawn(cf)
				Vfx.burst("trickLand", cf, 1.6)
			end
			TrickJuice.play("trick_stuck", if data.vehicle == "plane" then 1.12 else 0.92)
			Sfx.play("respawn_pop", 1, 0.58)
			FlightController.addTrauma(0.25)
			TrickJuice.callout(if data.vehicle == "plane" then "PLANE!" else "CAR!", if data.vehicle == "plane" then TrickJuice.BLUE else TrickJuice.GOLD, 1.2)
			LocalPlayer:SetAttribute("LastExchange", if type(data.vehicle) == "string" then data.vehicle else nil)
		end
	end

	task.spawn(function()
		local remotesFolder = waitForever(ReplicatedStorage, "SkyRallyRemotes")
		flightStateRemote = waitForever(remotesFolder, "FlightStateRemote") :: RemoteEvent
		local rer = waitForever(remotesFolder, "RaceEventRemote") :: RemoteEvent
		raceEventRemote = rer
		rer.OnClientEvent:Connect(onRaceEvent)
	end)

	-- Manual respawn (G5): keyboard Backspace (never R: drift / sharp bank) and the gamepad View/Select button, bound
	-- through ContextActionService above the default handlers so Select respawns instead of opening UI selection;
	-- while a menu already holds gamepad selection (GuiService.SelectedObject) the press passes through to it. A
	-- focused TextBox (chat) never reaches an action binding, so Backspace while typing only edits text.
	ContextActionService:BindActionAtPriority("SkyRallyRespawn", function(_: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if input.KeyCode == Enum.KeyCode.ButtonSelect and GuiService.SelectedObject ~= nil then
			return Enum.ContextActionResult.Pass
		end
		FlightController.requestManualRespawn(if input.KeyCode == Enum.KeyCode.ButtonSelect then "pad" else "key")
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonSelect)

	-- RETURN to course (FLIGHT_GUIDE.md 4.3, Free driving): Enter / keypad Enter and gamepad Y, only while RETURN is offered; any other
	-- time the press passes through (Y opens the Adventure board in the hub, the Garage and podium bind above this).
	ContextActionService:BindActionAtPriority("SkyRallyCourseReturn", function(_: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if state ~= Enum.UserInputState.Begin or not returnOffered() then
			return Enum.ContextActionResult.Pass
		end
		FlightController.requestCourseReturn("Button")
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter, Enum.KeyCode.ButtonY)

	-- Item fire (D20): keyboard F, gamepad X. E stays pitch-up (readCombinedInputs). gameProcessed is true while a
	-- menu button holds gamepad selection, so navigating the results screen never fires an item.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonX then
			FlightController.requestItemUse()
		end
	end)
	-- Missile v3: the release drops a trap (a tap or the end of a drag). Not gated on gameProcessed: a menu taking
	-- focus mid-hold must not leave the trap dragging.
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonX then
			FlightController.releaseItemUse()
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			local cam = workspace.CurrentCamera
			if cam then
				local vp = cam.ViewportSize
				if vp.X > 100 and vp.Y > 100 then
					local nx = (input.Position.X - vp.X * 0.5) / (vp.X * 0.38)
					local ny = (vp.Y * 0.5 - input.Position.Y) / (vp.Y * 0.38)
					local deadzone = 0.14
					local sx = if math.abs(nx) < deadzone then 0 else math.clamp((nx - math.sign(nx) * deadzone) / (1 - deadzone), -1, 1)
					local sy = if math.abs(ny) < deadzone then 0 else math.clamp((ny - math.sign(ny) * deadzone) / (1 - deadzone), -1, 1)
					mouseSteerOffset = Vector2.new(sx * 0.75, sy * 0.75)
					mouseMovedRecently = 1.5
				end
			end
		end
	end)

	RunService:BindToRenderStep("SkyRallyFlightStep", Enum.RenderPriority.Camera.Value + 1, Prof.wrap("SR_FlightStep", stepFlight))
	Vfx.init()
	RunService.RenderStepped:Connect(Prof.wrap("SR_FlightVfx", function(dt: number)
		Vfx.step(dt, {
			speed = FlightController.currentSpeed,
			boost = FlightController.boostState,
			sharp = FlightController.sharpBank,
			roll = FlightController.rollTimer > 0, -- barrel-roll corkscrew vapor
		})
	end))
end

function FlightController.requestPlayAgain()
	if flightStateRemote then
		flightStateRemote:FireServer("RequestPlayAgain")
	end
end

return FlightController
