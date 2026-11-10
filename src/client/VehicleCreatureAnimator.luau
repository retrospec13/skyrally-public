--!strict
-- Creature vehicle clip player (client only, nothing replicates): every vehicle in workspace.Planes whose model carries
-- CreatureClips (server/kit/CreatureMesh; first: the Void Dragon) plays the baked clips in
-- ReplicatedStorage.Shared.vehicleclips.<CreatureClips> on its bones. The clip math is the boss player's, reused as-is
-- (Shared.bossclips.ClipMath: sample, accumulate, overlay, crossfade, one-shot weights, validate); per bone, per frame
--   Bone.Transform = CFrame.new(D.t * CreatureScale) * rotation(D.q)
-- exactly as client/BossAnimator writes it. What is new here is only the choice of weights, from flight state that is
-- already there, through the pure Shared.VehicleCreatureRules:
--   base (crossfaded): hover on the grid / countdown, boost while BoostState is set, fly when throttling / climbing /
--     slow / just hit, glide when cruising level or diving with low throttle;
--   bank: bankL / bankR overlaid by the yaw rate; hit: a one-shot on an item hit (the local stun, a bot's Stunned).
-- The local player's mount reads FlightController (throttle, boost, stun); every other mount reads its replicated Speed,
-- BoostState, Stunned and hull motion. The tail sway is in the clips.
-- LOD and phone budget (VehicleCreatureRules.lodStep): the local mount every frame; others full rate near the camera
-- (at most MAX_FULL_RATE per frame), throttled further out, nothing out of view or past CULL_DISTANCE.
-- Without a clip module (the art lane has not delivered it yet) the creature stays at its rest pose and logs once.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Prof = require(Shared:WaitForChild("Prof"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("VehicleCreatureRules"))
local ClipMath = require(Shared:WaitForChild("bossclips"):WaitForChild("ClipMath"))

local VehicleCreatureAnimator = {}

local SCAN_INTERVAL = 0.5
local MAX_STEP = 0.5

type Slot = { bone: Bone, ci: number }
type Rig = {
	model: Model,
	hull: BasePart,
	mod: ClipMath.Module,
	slots: { Slot },
	fader: ClipMath.Fader,
	times: { [string]: number },
	st: Rules.State,
	isBot: boolean,
	speedF: number,
	accel: number,
	lastLook: Vector3,
	turnF: number,
	hitAt: number,
	stunned: boolean,
	hitT: number?,
	hitDur: number,
	pending: number,
}

local rigs: { [Model]: Rig } = {}
local tried: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local modules: { [string]: ClipMath.Module | false } = {}
local logged: { [string]: boolean } = {}
local initialized = false
local scanClock = 0
local flight: any = nil -- client/FlightController (lazy: read only, never required at load)

local function logOnce(key: string, msg: string)
	if not logged[key] then
		logged[key] = true
		print(msg)
	end
end

local function loadClips(name: string): ClipMath.Module?
	local cached = modules[name]
	if cached == false then
		return nil
	elseif cached then
		return cached :: ClipMath.Module
	end
	local folder = Shared:FindFirstChild(Rules.CLIP_FOLDER)
	local ms = if folder then folder:FindFirstChild(name) else nil
	if not ms or not ms:IsA("ModuleScript") then
		modules[name] = false
		logOnce("none:" .. name, string.format("[SkyRally][CREATUREANIM] clips=none (no module Shared.%s.%s): creature at rest", Rules.CLIP_FOLDER, name))
		return nil
	end
	local ok, res = pcall(require, ms)
	local valid, err = false, tostring(res) :: string?
	if ok then
		valid, err = ClipMath.validate(res)
	end
	if not valid then
		warn(string.format("[SkyRally][CREATUREANIM] clips %s rejected: %s", name, tostring(err)))
		modules[name] = false
		return nil
	end
	modules[name] = res :: ClipMath.Module
	return res :: ClipMath.Module
end

local function attach(model: Model): boolean
	local hull = model.PrimaryPart
	local clipsName = model:GetAttribute(Rules.ATTR_CLIPS)
	if not hull or type(clipsName) ~= "string" or clipsName == "" then
		return false
	end
	local bones: { Bone } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Bone") then
			table.insert(bones, d)
		end
	end
	if #bones == 0 then
		return false -- the creature has not replicated yet: try again on the next scan
	end
	local mod = loadClips(clipsName)
	if not mod then
		return true -- no clips: rest pose, nothing to run (do not retry every scan)
	end
	local index: { [string]: number } = {}
	for i, n in mod.bones do
		index[n] = i
	end
	local slots: { Slot } = {}
	for _, b in bones do
		local ci = index[b.Name]
		if ci then
			b.Transform = CFrame.identity
			table.insert(slots, { bone = b, ci = ci })
		end
	end
	local initial = Rules.resolve("hover", mod.clips) or Rules.resolve("fly", mod.clips)
	if not initial then
		return true
	end
	local r: Rig = {
		model = model,
		hull = hull,
		mod = mod,
		slots = slots,
		fader = ClipMath.newFader(initial, Rules.BASE_FADE),
		times = {},
		st = Rules.newState(),
		isBot = model:GetAttribute("IsAI") == true,
		speedF = 0,
		accel = 0,
		lastLook = hull.CFrame.LookVector,
		turnF = 0,
		hitAt = -math.huge,
		stunned = model:GetAttribute("Stunned") == true,
		hitT = nil,
		hitDur = 0,
		pending = 0,
	}
	for name, clip in mod.clips do
		if clip.loop then
			r.times[name] = math.random() * ClipMath.duration(clip, mod.fps) -- two dragons never flap in step
		end
	end
	rigs[model] = r
	print(string.format("[SkyRally][CREATUREANIM] %s bones=%d matched=%d clips=%s scale=%.3f", model.Name, #bones, #slots, clipsName,
		(model:GetAttribute(Rules.ATTR_SCALE) :: number?) or 1))
	return true
end

local function scan()
	local folder = workspace:FindFirstChild("Planes")
	if not folder then
		return
	end
	local now = os.clock()
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and not rigs[m] and m:GetAttribute(Rules.ATTR_CLIPS) ~= nil then
			local t = tried[m]
			if t == nil or (t > 0 and now - t > 1) then
				tried[m] = if attach(m) then 0 else now
			end
		end
	end
end

local function playHit(r: Rig)
	local clip = r.mod.clips.hit
	if clip then
		r.hitT = 0
		r.hitDur = ClipMath.duration(clip, r.mod.fps)
	end
	r.hitAt = os.clock()
end

local function isLocalMount(r: Rig): boolean
	return flight ~= nil and flight.plane == r.model
end

local function update(r: Rig, dt: number, grid: boolean)
	local m = r.model
	local hull = r.hull
	local mine = isLocalMount(r)
	local speed: number
	local throttle: number? = nil
	local boosting: boolean
	if mine then
		speed = tonumber(flight.currentSpeed) or 0
		local t = tonumber(flight.throttleInput) or 0
		throttle = if flight.autoThrottle and t == 0 then 0 else math.max(0, t)
		boosting = flight.boostState ~= nil and flight.boostState ~= "None"
		local stun = tonumber(flight.itemStunTimer) or 0
		if stun > 0 and not r.stunned then
			playHit(r)
		end
		r.stunned = stun > 0
	else
		local a = m:GetAttribute("Speed")
		speed = if type(a) == "number" then a else 0
		local b = m:GetAttribute("BoostState")
		boosting = b ~= nil and b ~= "None"
		local stunned = m:GetAttribute("Stunned") == true
		if stunned and not r.stunned then
			playHit(r)
		end
		r.stunned = stunned
	end
	local prevF = r.speedF
	r.speedF += (speed - r.speedF) * math.min(1, dt * 3)
	if dt > 0 then
		r.accel += ((r.speedF - prevF) / dt - r.accel) * math.min(1, dt * 4)
	end
	-- Yaw rate from the hull's heading (deg/s, + = right), smoothed.
	local look = hull.CFrame.LookVector
	local flatA = Vector3.new(r.lastLook.X, 0, r.lastLook.Z)
	local flatB = Vector3.new(look.X, 0, look.Z)
	local turn = 0
	if dt > 0 and flatA.Magnitude > 1e-3 and flatB.Magnitude > 1e-3 then
		local a, b = flatA.Unit, flatB.Unit
		local ang = math.atan2(a:Cross(b).Y, a:Dot(b)) -- + = turned left (counter-clockwise from above)
		turn = -math.deg(ang) / dt
	end
	r.lastLook = look
	r.turnF += (turn - r.turnF) * math.min(1, dt * 6)

	local mod = r.mod
	local base = Rules.stepBase(r.st, {
		grid = grid,
		speed = r.speedF,
		climb = hull.AssemblyLinearVelocity.Y,
		accel = r.accel,
		throttle = throttle,
		boosting = boosting,
		hitAge = os.clock() - r.hitAt,
	}, dt)
	local clipName = Rules.resolve(base, mod.clips)
	if clipName then
		ClipMath.fadeTo(r.fader, clipName)
	end
	ClipMath.stepFader(r.fader, dt)
	for name in r.fader.weights do
		r.times[name] = (r.times[name] or 0) + dt
	end
	local bank = Rules.stepBank(r.st, r.turnF, dt)
	local wl, wr = Rules.bankWeights(bank, mod.clips)
	if wl > 0 then
		r.times.bankL = (r.times.bankL or 0) + dt
	end
	if wr > 0 then
		r.times.bankR = (r.times.bankR or 0) + dt
	end
	local hitW = 0
	local hitT = r.hitT
	if hitT then
		hitT += dt
		r.hitT = if hitT >= r.hitDur then nil else hitT
		hitW = ClipMath.oneShotWeight(hitT, r.hitDur, Rules.HIT_IN, Rules.HIT_OUT)
	end

	local scaleAttr = m:GetAttribute(Rules.ATTR_SCALE)
	local scale = if type(scaleAttr) == "number" then scaleAttr else 1
	local acc = ClipMath.newAcc()
	local fps = mod.fps
	local clips = mod.clips
	for _, slot in r.slots do
		ClipMath.resetAcc(acc)
		local ci = slot.ci
		for name, w in r.fader.weights do
			local clip = clips[name]
			if clip then
				ClipMath.accumulate(acc, w, ClipMath.sample(clip, ci, r.times[name] or 0, fps))
			end
		end
		if wl > 0 then
			ClipMath.overlay(acc, wl, ClipMath.sample(clips.bankL, ci, r.times.bankL or 0, fps))
		end
		if wr > 0 then
			ClipMath.overlay(acc, wr, ClipMath.sample(clips.bankR, ci, r.times.bankR or 0, fps))
		end
		if hitW > 0 and hitT then
			ClipMath.overlay(acc, hitW, ClipMath.sample(clips.hit, ci, hitT, fps))
		end
		slot.bone.Transform = CFrame.new(acc[5] * scale, acc[6] * scale, acc[7] * scale, acc[1], acc[2], acc[3], acc[4])
	end
end

local function step(dt: number)
	scanClock -= dt
	if scanClock <= 0 then
		scanClock = SCAN_INTERVAL
		scan()
	end
	if next(rigs) == nil then
		return
	end
	local cam = workspace.CurrentCamera
	local camCF = if cam then cam.CFrame else CFrame.identity
	local camPos, camLook = camCF.Position, camCF.LookVector
	local goTime = RaceAttr.mine("RaceGoTime")
	local grid = type(goTime) == "number" and workspace:GetServerTimeNow() < goTime
	local fullUsed = 0
	for model, r in rigs do
		if not model.Parent or not r.hull.Parent then
			rigs[model] = nil
			continue
		end
		r.pending = math.min(r.pending + dt, MAX_STEP)
		local mine = isLocalMount(r)
		local to = r.hull.Position - camPos
		local every = Rules.lodStep(to.Magnitude, mine, r.isBot, Rules.inView(to, camLook), fullUsed)
		if every ~= nil and r.pending >= every then
			if every == 0 and not mine then
				fullUsed += 1
			end
			update(r, r.pending, grid)
			r.pending = 0
		end
	end
end

function VehicleCreatureAnimator.init()
	if initialized then
		return
	end
	initialized = true
	task.defer(function()
		local ok, fc = pcall(function(): any
			return (require :: any)(script.Parent:WaitForChild("FlightController"))
		end)
		if ok then
			flight = fc
		end
	end)
	RunService.RenderStepped:Connect(Prof.wrap("SR_CreatureAnimator", step))
end

return VehicleCreatureAnimator
