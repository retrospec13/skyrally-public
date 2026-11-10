--!strict
-- Boss clip player (client only, nothing replicates). Every boss model (IsBoss) in workspace.Planes whose mesh is skinned
-- plays the clips authored in Blender on the neutral-pose rig and baked by tools/bake_boss_clips.py into
-- ReplicatedStorage.Shared.bossclips.<BossConfig.clips> (math in bossclips/ClipMath). Per bone, per frame:
--   Bone.Transform = CFrame.new(D.t * BossScale) * rotation(D.q)
-- where D is the baked delta from the rest pose (glTF node-local, Studio-verified to equal the Bone's own frame) and
-- BossScale is the Model:ScaleTo factor BossBuilder stored on the model. Layers:
--   1. base loop with 0.35 s crossfades: flyers fly <-> glide (or hover): flap while slow, accelerating, boosting or
--      just hit, glide stretches of 1.5-3 s otherwise; walkers walk at playback rate Speed / speedRef (0.4-2.2), idle
--      below 6 studs/s; karts drive, idle when stopped.
--   2. one-shots (fade in 0.12 s, out 0.2 s, optional bone mask): hit on the Stunned rising edge, roar when the boss
--      intro sweep starts (BossIntro.onIntro), attack when the server's hazard drop sets BossDropAt (BossRace).
--   3. procedural spins: Wheel* bones roll from Speed and BossConfig.wheelRadius about the creature-frame right axis,
--      Prop spins at BossConfig.propRps about the forward axis (axes converted into each bone's rest frame, measured
--      against the hull's RigFrame attachment with every Transform at identity). Clips leave these bones at rest.
-- A boss without a clip module stays at its rest pose (the mechanical spins still run) and logs once. LOD: full rate
-- within 250 studs of the camera, 15 Hz to 600, skipped beyond; rigs whose model left are dropped.
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local BossConfig = require(Shared:WaitForChild("BossConfig"))
local bossclips = Shared:WaitForChild("bossclips")
local ClipMath = require(bossclips:WaitForChild("ClipMath"))

local BossAnimator = {}

local FULL_RATE_DISTANCE = 250
local LOD_DISTANCE = 600
local LOD_STEP = 1 / 15
local MAX_STEP = 0.5 -- dt cap when a skipped rig comes back into range
local BASE_FADE = 0.35
local SHOT_IN, SHOT_OUT = 0.12, 0.2
local IDLE_BELOW = 6 -- studs/s: walkers and karts idle under this
local RATE_MIN, RATE_MAX = 0.4, 2.2
local GLIDE_MIN, GLIDE_MAX = 1.5, 3.0
local FLAP_MIN, FLAP_MAX = 1.6, 3.0
local FLAP_AFTER_HIT = 1.5
local SLOW_FLAP = 40 -- studs/s: flyers below this keep flapping (grid hold, recovery)
local ROAR_DELAY = 0.45 -- seconds into the intro sweep
BossAnimator.ROAR_DELAY = ROAR_DELAY -- client/Music cuts the theme and plays the roar sound on the same beat
local DROP_STALE = 0.6 -- a BossDropAt older than this (server time) plays no attack
local PRIORITY: { [string]: number } = { hit = 3, roar = 2, attack = 1 }

local RIGHT = Vector3.new(1, 0, 0)
local FORWARD = Vector3.new(0, 0, -1)

type Slot = { bone: Bone, clipIndex: number?, spin: string?, axis: Vector3 }
type Shot = { name: string, clip: ClipMath.Clip, t: number, dur: number, mask: { [number]: boolean }?, priority: number, killAt: number?, w: number }
type Rig = {
	model: Model,
	hull: BasePart,
	boss: BossConfig.Boss,
	mod: ClipMath.Module?,
	fps: number,
	kind: string, -- "flyer" | "walker" | "kart" | "loop" | "none"
	slots: { Slot },
	fader: ClipMath.Fader?,
	times: { [string]: number },
	glide: string?,
	mode: string,
	modeLeft: number,
	shots: { Shot },
	stunned: boolean,
	dropAt: number?,
	hitAt: number,
	speedF: number,
	accel: number,
	wheelAngle: number,
	propAngle: number,
	wheelRadius: number,
	propRps: number,
	pending: number,
	acc: ClipMath.Acc,
}

local rigs: { [Model]: Rig } = {}
local roarAt: { [Model]: number } = {}
local modules: { [string]: ClipMath.Module } = {}
local failed: { [string]: boolean } = {}
local logged: { [string]: boolean } = {}

local function logOnce(key: string, msg: string)
	if not logged[key] then
		logged[key] = true
		print(msg)
	end
end

-- The baked clip module for a boss (cached; a missing or malformed one is remembered as failed).
local function loadClips(name: string): ClipMath.Module?
	if failed[name] then
		return nil
	elseif modules[name] then
		return modules[name]
	end
	local ms = bossclips:FindFirstChild(name)
	if not ms or not ms:IsA("ModuleScript") then
		failed[name] = true
		return nil
	end
	local ok, res = pcall(require, ms)
	if not ok then
		warn(string.format("[SkyRally][BOSSANIM] clips %s failed to load: %s", name, tostring(res)))
		failed[name] = true
		return nil
	end
	local valid, err = ClipMath.validate(res)
	if not valid then
		warn(string.format("[SkyRally][BOSSANIM] clips %s rejected: %s", name, tostring(err)))
		failed[name] = true
		return nil
	end
	modules[name] = res :: ClipMath.Module
	return res :: ClipMath.Module
end

local function kindOf(mod: ClipMath.Module?): string
	if not mod then
		return "none"
	elseif mod.clips.fly then
		return "flyer"
	elseif mod.clips.walk then
		return "walker"
	elseif mod.clips.drive then
		return "kart"
	end
	return "loop"
end

local function firstLoop(mod: ClipMath.Module): string?
	local best: string? = nil
	for name, clip in mod.clips do
		if clip.loop and (best == nil or name < (best :: string)) then
			best = name
		end
	end
	return best
end

local preloaded: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function attach(model: Model)
	if rigs[model] then
		return
	end
	local hull = model.PrimaryPart
	if not hull then
		return
	end
	local boss = BossConfig.forZone(model:GetAttribute("BossZone") :: string?)
	if not boss then
		return
	end
	-- Fetch the boss's mesh and SurfaceAppearance maps now (it is built under the load curtain), so it never shows up
	-- untextured grey for the intro sweep.
	if not preloaded[model] then
		preloaded[model] = true
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync({ model })
			end)
		end)
	end
	local bones: { Bone } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Bone") then
			d.Transform = CFrame.identity
			table.insert(bones, d)
		end
	end
	if #bones == 0 then
		return -- mesh not replicated yet (or an unrigged fallback): the caller retries
	end
	local mod = if boss.clips then loadClips(boss.clips) else nil
	local index: { [string]: number } = {}
	if mod then
		for i, n in mod.bones do
			index[n] = i
		end
	end
	-- Creature frame: the hull's RigFrame attachment (lean included), else the hull itself.
	local frameAtt = hull:FindFirstChild("RigFrame")
	local frame = if frameAtt and frameAtt:IsA("Attachment") then frameAtt.WorldCFrame else hull.CFrame
	local slots: { Slot } = {}
	local matched = 0
	for _, b in bones do
		local ci = index[b.Name]
		local spin: string? = nil
		if string.sub(b.Name, 1, 5) == "Wheel" then
			spin = "wheel"
		elseif b.Name == "Prop" then
			spin = "prop"
		end
		if ci or spin then
			local rest = frame:ToObjectSpace(b.WorldCFrame)
			local axis = rest:VectorToObjectSpace(if spin == "prop" then FORWARD else RIGHT)
			table.insert(slots, { bone = b, clipIndex = ci, spin = spin, axis = axis })
			if ci then
				matched += 1
			end
		end
	end
	local kind = kindOf(mod)
	local r: Rig = {
		model = model,
		hull = hull,
		boss = boss,
		mod = mod,
		fps = if mod then mod.fps else 30,
		kind = kind,
		slots = slots,
		fader = nil,
		times = {},
		glide = nil,
		mode = "fly",
		modeLeft = FLAP_MIN,
		shots = {},
		stunned = model:GetAttribute("Stunned") == true,
		dropAt = model:GetAttribute("BossDropAt") :: number?,
		hitAt = -math.huge,
		speedF = 0,
		accel = 0,
		wheelAngle = 0,
		propAngle = 0,
		wheelRadius = boss.wheelRadius or boss.length * 0.09,
		propRps = boss.propRps or 3,
		pending = 0,
		acc = ClipMath.newAcc(),
	}
	if mod then
		local initial: string?
		if kind == "flyer" then
			initial = "fly"
			r.glide = if mod.clips.glide then "glide" elseif mod.clips.hover then "hover" else nil
		elseif kind == "walker" or kind == "kart" then
			initial = if mod.clips.idle then "idle" elseif kind == "walker" then "walk" else "drive"
		else
			initial = firstLoop(mod)
		end
		if initial then
			r.fader = ClipMath.newFader(initial, BASE_FADE)
		end
		-- Desynchronise the loops a little so two races never look identical.
		for name, clip in mod.clips do
			if clip.loop then
				r.times[name] = math.random() * ClipMath.duration(clip, r.fps)
			end
		end
		local names = {}
		for name in mod.clips do
			table.insert(names, name)
		end
		table.sort(names)
		print(string.format("[SkyRally][BOSSANIM] %s bones=%d matched=%d clips=%s kind=%s scale=%.3f", model.Name, #bones, matched,
			table.concat(names, ","), kind, (model:GetAttribute("BossScale") :: number?) or 1))
	else
		logOnce("noclips:" .. boss.name, string.format("[SkyRally][BOSSANIM] %s bones=%d clips=none (no module Shared.bossclips.%s): mesh at rest",
			model.Name, #bones, tostring(boss.clips)))
	end
	rigs[model] = r
end

local function playShot(r: Rig, name: string)
	local mod = r.mod
	local clip = mod and mod.clips[name]
	if not mod or not clip then
		return
	end
	local priority = PRIORITY[name] or 1
	for _, s in r.shots do
		-- A stronger one-shot still in its body keeps playing (an attack does not cut a hit short).
		if not s.killAt and s.priority > priority and s.t < s.dur - SHOT_OUT then
			return
		end
	end
	for _, s in r.shots do
		if not s.killAt then
			s.killAt = s.t -- fades out over SHOT_IN while the new one fades in
		end
	end
	table.insert(r.shots, { name = name, clip = clip, t = 0, dur = ClipMath.duration(clip, r.fps), mask = ClipMath.maskSet(mod, clip), priority = priority, killAt = nil, w = 0 })
end

local function triggers(r: Rig, now: number)
	local m = r.model
	local stunned = m:GetAttribute("Stunned") == true
	if stunned and not r.stunned then
		r.hitAt = now
		playShot(r, "hit")
	end
	r.stunned = stunned
	local drop = m:GetAttribute("BossDropAt")
	if type(drop) == "number" and drop ~= r.dropAt then
		r.dropAt = drop
		if workspace:GetServerTimeNow() - drop < DROP_STALE then
			playShot(r, "attack")
		end
	end
	local roar = roarAt[m]
	if roar and now >= roar then
		roarAt[m] = nil
		playShot(r, "roar")
	end
end

-- Base-layer choice and playback rates.
local function base(r: Rig, speed: number, dt: number, now: number)
	local fader = r.fader
	local mod = r.mod
	if not fader or not mod then
		return
	end
	local rate: { [string]: number } = {}
	if r.kind == "flyer" then
		local boosting = speed > r.boss.pace * 1.06
		local flap = r.stunned or boosting or r.accel > 6 or speed < SLOW_FLAP or now - r.hitAt < FLAP_AFTER_HIT
		r.modeLeft -= dt
		if r.mode == "glide" then
			if flap or r.modeLeft <= 0 then
				r.mode = "fly"
				r.modeLeft = FLAP_MIN + math.random() * (FLAP_MAX - FLAP_MIN)
			end
		elseif r.glide and not flap and r.modeLeft <= 0 then
			r.mode = "glide"
			-- Cruising fast glides longer; a slow boss gets back to flapping sooner.
			local share = math.clamp(speed / math.max(r.boss.pace, 1), 0.6, 1.1)
			r.modeLeft = (GLIDE_MIN + math.random() * (GLIDE_MAX - GLIDE_MIN)) * share
		end
		ClipMath.fadeTo(fader, if r.mode == "glide" and r.glide then r.glide :: string else "fly")
	elseif r.kind == "walker" or r.kind == "kart" then
		local loopName = if r.kind == "walker" then "walk" else "drive"
		local moving = speed >= IDLE_BELOW or not mod.clips.idle
		ClipMath.fadeTo(fader, if moving then loopName else "idle")
		local ref = mod.clips[loopName].speedRef
		if ref then
			rate[loopName] = math.clamp(speed / ref, RATE_MIN, RATE_MAX)
		end
	end
	ClipMath.stepFader(fader, dt)
	for name in fader.weights do
		r.times[name] = (r.times[name] or 0) + dt * (rate[name] or 1)
	end
end

local function update(r: Rig, dt: number)
	local now = os.clock()
	local m = r.model
	local speedAttr = m:GetAttribute("Speed")
	local speed = if type(speedAttr) == "number" then speedAttr else 0
	local prevF = r.speedF
	r.speedF += (speed - r.speedF) * math.min(1, dt * 3)
	if dt > 0 then
		r.accel += ((r.speedF - prevF) / dt - r.accel) * math.min(1, dt * 4)
	end
	r.wheelAngle = (r.wheelAngle + speed * dt / math.max(r.wheelRadius, 0.2)) % (math.pi * 2)
	r.propAngle = (r.propAngle + dt * r.propRps * math.pi * 2) % (math.pi * 2)

	local mod = r.mod
	if mod then
		triggers(r, now)
		base(r, speed, dt, now)
		for i = #r.shots, 1, -1 do
			local s = r.shots[i]
			s.t += dt
			local w = ClipMath.oneShotWeight(s.t, s.dur, SHOT_IN, SHOT_OUT)
			if s.killAt then
				w *= 1 - ClipMath.smoothstep((s.t - s.killAt) / SHOT_IN)
			end
			s.w = w
			if s.t >= s.dur or (s.killAt and s.t - s.killAt >= SHOT_IN) then
				table.remove(r.shots, i)
			end
		end
	end

	local scaleAttr = m:GetAttribute("BossScale")
	local scale = if type(scaleAttr) == "number" then scaleAttr else 1
	local acc = r.acc
	local fader = r.fader
	for _, slot in r.slots do
		ClipMath.resetAcc(acc)
		local ci = slot.clipIndex
		if mod and ci then
			if fader then
				for name, w in fader.weights do
					local clip = mod.clips[name]
					if clip then
						ClipMath.accumulate(acc, w, ClipMath.sample(clip, ci, r.times[name] or 0, r.fps))
					end
				end
			end
			for _, s in r.shots do -- oldest first, so a replacing one-shot lands on top
				if s.w > 0 and (not s.mask or s.mask[ci]) then
					ClipMath.overlay(acc, s.w, ClipMath.sample(s.clip, ci, s.t, r.fps))
				end
			end
		end
		local T = CFrame.new(acc[5] * scale, acc[6] * scale, acc[7] * scale, acc[1], acc[2], acc[3], acc[4])
		if slot.spin == "wheel" then
			-- Rolling toward -Z about +X is a negative angle (the top of the wheel moves forward).
			T *= CFrame.fromAxisAngle(slot.axis, -r.wheelAngle)
		elseif slot.spin == "prop" then
			T *= CFrame.fromAxisAngle(slot.axis, r.propAngle)
		end
		slot.bone.Transform = T
	end
end

function BossAnimator.init()
	local BossIntro = require(script.Parent.BossIntro)
	BossIntro.onIntro(function(model: Model, _sweep: number)
		roarAt[model] = os.clock() + ROAR_DELAY
	end)
	BossIntro.init()
	local planes = workspace:WaitForChild("Planes", 60)
	if not planes then
		return
	end
	local function consider(m: Instance)
		if m:IsA("Model") and m:GetAttribute("IsBoss") == true then
			-- The boss mesh is inserted by the server after the hull: try again for a few seconds.
			task.spawn(function()
				for _ = 1, 20 do
					if rigs[m] or not m.Parent then
						return
					end
					attach(m)
					task.wait(0.5)
				end
			end)
		end
	end
	planes.ChildAdded:Connect(consider)
	for _, m in planes:GetChildren() do
		consider(m)
	end
	RunService.RenderStepped:Connect(Prof.wrap("SR_BossAnimator", function(dt: number)
		local cam = workspace.CurrentCamera
		local camPos = if cam then cam.CFrame.Position else Vector3.zero
		for model, r in rigs do
			if not model.Parent or not r.hull.Parent then
				rigs[model] = nil
				roarAt[model] = nil
				continue
			end
			r.pending = math.min(r.pending + dt, MAX_STEP)
			local d = (r.hull.Position - camPos).Magnitude
			if d < FULL_RATE_DISTANCE or (d < LOD_DISTANCE and r.pending >= LOD_STEP) then
				update(r, r.pending)
				r.pending = 0
			end
		end
		-- Intro roars that never found a rig (mesh still loading) expire.
		local now = os.clock()
		for model, at in roarAt do
			if now - at > 3 or not model.Parent then
				roarAt[model] = nil
			end
		end
	end))
end

return BossAnimator
