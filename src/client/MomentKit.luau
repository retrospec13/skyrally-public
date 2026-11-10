--!strict
-- Shared plumbing for the Batch 2 set pieces on the client (client/GalleonMoments, BossRetirement, DuckMoments,
-- MoonMonorail; docs/REMARKABLE.md items 13, 21, 22, 25). Phone budget first: every Sound, emitter and billboard is
-- created once per key and reused, one Heartbeat runs only while an animation is alive, and nothing here allocates
-- per frame. Visual and audio only: no vehicle, race or reward state is touched.
-- * sfx(key, cue, pos, ...): a 3D sound from one pooled slot per key; cues come from the generated SetPiecesAudio
--   (this lane's uploads), then AudioAssets, TrickAudio and WorldMomentsAudio (Batch 1 roars, boing, cough, chimes); a
--   missing cue is silent.
-- * ui(key, cue, ...): the same for 2D sounds (the rider's slide whistle, the toasts).
-- * burst(preset, cf, scale): pooled particle presets below (cannon smoke, muzzle flash, feathers, ice, sparks...).
-- * animate(dur, step, done): a cheap tween loop; a failing step ends only its own animation.
-- * text(key, ...): comic pop-in text in the world.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local Settings = require(script.Parent:WaitForChild("Settings")) -- LOW GRAPHICS thins every burst (particleScale)

local LocalPlayer = Players.LocalPlayer

local MomentKit = {}

local function loadTable(name: string): { [string]: string }
	local mod = Shared:FindFirstChild(name)
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok and type(res) == "table" then
			return res :: any
		end
	end
	return {}
end

local AUDIO: { [string]: string } = {}
for _, name in { "WorldMomentsAudio", "TrickAudio", "AudioAssets", "SetPiecesAudio" } do
	for k, v in loadTable(name) do
		if type(v) == "string" then
			AUDIO[k] = v
		end
	end
end
MomentKit.AUDIO = AUDIO

function MomentKit.has(cue: string): boolean
	return AUDIO[cue] ~= nil
end

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end
MomentKit.rgb = rgb
MomentKit.CREAM = rgb(255, 244, 214)
MomentKit.INK = rgb(40, 26, 18)
MomentKit.GOLD = rgb(255, 214, 90)

function MomentKit.ns(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kps)
end
local ns = MomentKit.ns

---------------------------------------------------------------------------------------------------- vehicles

function MomentKit.vehicleOf(userId: number): Model?
	local planes = workspace:FindFirstChild("Planes")
	if not planes then
		return nil
	end
	for _, m in planes:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("OwnerUserId") == userId then
			return m
		end
	end
	return nil
end

function MomentKit.hullOf(model: Model): BasePart?
	local h = model.PrimaryPart or model:FindFirstChild("Hull")
	return if h and h:IsA("BasePart") then h else nil
end

-- Where this client "is": its own vehicle, else the camera.
function MomentKit.focus(): Vector3
	local model = MomentKit.vehicleOf(LocalPlayer.UserId)
	local hull = model and MomentKit.hullOf(model)
	if hull then
		return hull.Position
	end
	local cam = workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

function MomentKit.camPos(): Vector3
	local cam = workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

local controllers: { car: any?, plane: any? } = {}
function MomentKit.setControllers(car: any, plane: any)
	controllers.car = car
	controllers.plane = plane
end

-- Camera kick on whichever controller drives this client's camera (camera only; the hull never moves).
function MomentKit.trauma(amount: number)
	if amount <= 0 then
		return
	end
	local model = MomentKit.vehicleOf(LocalPlayer.UserId)
	if not model then
		return
	end
	local c = if model:GetAttribute("IsCar") == true then controllers.car else controllers.plane
	if c and type(c.addTrauma) == "function" then
		pcall(c.addTrauma, amount)
	end
end

-- Trauma that fades with distance from `pos` (full at the source, none past `reach`).
function MomentKit.traumaNear(pos: Vector3, peak: number, reach: number)
	local d = (MomentKit.focus() - pos).Magnitude
	if d < reach then
		MomentKit.trauma(peak * (1 - d / reach))
	end
end

-- Hides (or shows) every visible part of a model on this client only.
function MomentKit.hideModel(model: Instance, hidden: boolean)
	local v = if hidden then 1 else 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = v
		elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
			(d :: any).Enabled = not hidden
		end
	end
end

---------------------------------------------------------------------------------------------------- animation loop

type Anim = { t0: number, dur: number, step: (k: number, t: number) -> (), done: (() -> ())? }
local anims: { Anim } = {}
local loopConn: RBXScriptConnection? = nil

local function report(err: any)
	warn("[SkyRally][SETPIECE] " .. tostring(err))
end

local function stepAnims()
	local now = os.clock()
	for i = #anims, 1, -1 do
		local a = anims[i]
		local t = now - a.t0
		local last = t >= a.dur
		local ok = xpcall(a.step, report, if last then 1 else t / a.dur, if last then a.dur else t)
		if last or not ok then
			table.remove(anims, i)
			local done = a.done
			if done then
				xpcall(done, report)
			end
		end
	end
	if #anims == 0 and loopConn then
		loopConn:Disconnect()
		loopConn = nil
	end
end

-- Runs step(k 0..1, t seconds) every frame for `dur` seconds (the last call is k = 1), then done().
function MomentKit.animate(dur: number, step: (k: number, t: number) -> (), done: (() -> ())?)
	table.insert(anims, { t0 = os.clock(), dur = math.max(dur, 1e-3), step = step, done = done })
	if not loopConn then
		loopConn = RunService.Heartbeat:Connect(stepAnims)
	end
end

function MomentKit.easeOutBack(x: number): number
	local c1, c3 = 1.70158, 2.70158
	local t = x - 1
	return 1 + c3 * t * t * t + c1 * t * t
end

---------------------------------------------------------------------------------------------------- sounds (pooled)

type Slot = { att: Attachment?, sound: Sound }
local slots: { [string]: Slot } = {}
local uiFolder: Folder? = nil

-- 3D: plays `cue` at `pos` from the slot `key` (one Sound per key, restarted on reuse). Returns the Sound.
function MomentKit.sfx(key: string, cue: string, pos: Vector3, volume: number, speed: number?, maxDist: number?): Sound?
	local id = AUDIO[cue]
	if not id then
		return nil
	end
	local slot: Slot
	local existing = slots[key]
	if existing and existing.att and (existing.att :: Attachment).Parent then
		slot = existing
	else
		local att = Instance.new("Attachment")
		att.Name = "SetPieceSound_" .. key
		att.Parent = workspace.Terrain
		local snd = Instance.new("Sound")
		snd.Name = key
		snd.RollOffMode = Enum.RollOffMode.InverseTapered
		snd.RollOffMinDistance = 25
		snd.Parent = att
		slot = { att = att, sound = snd }
		slots[key] = slot
	end
	local s = slot.sound;
	(slot.att :: Attachment).WorldPosition = pos
	if s.SoundId ~= id then
		s.SoundId = id
	end
	s.Volume = volume
	s.PlaybackSpeed = speed or 1
	s.RollOffMaxDistance = maxDist or 400
	s.TimePosition = 0
	s:Play()
	return s
end

-- 2D (this client only): the rider's own effects and the toasts' stingers.
function MomentKit.ui(key: string, cue: string, volume: number, speed: number?): Sound?
	local id = AUDIO[cue]
	if not id then
		return nil
	end
	local slot: Slot? = slots["ui_" .. key]
	if not slot then
		if not uiFolder or not uiFolder.Parent then
			local f = Instance.new("Folder")
			f.Name = "SkyRallySetPieceUI"
			f.Parent = SoundService
			uiFolder = f
		end
		local s = Instance.new("Sound")
		s.Name = key
		s.Parent = uiFolder
		local made: Slot = { att = nil, sound = s }
		slots["ui_" .. key] = made
		slot = made
	end
	local s = (slot :: Slot).sound
	if s.SoundId ~= id then
		s.SoundId = id
	end
	s.Volume = volume
	s.PlaybackSpeed = speed or 1
	s.TimePosition = 0
	s:Play()
	return s
end

---------------------------------------------------------------------------------------------------- particles (pooled)

type Preset = {
	tex: string,
	count: number,
	lifetime: NumberRange,
	speed: NumberRange,
	spread: Vector2,
	size: NumberSequence,
	transparency: NumberSequence,
	color: ColorSequence,
	lightEmission: number?,
	accel: Vector3?,
	drag: number?,
	rotation: NumberRange?,
	rotSpeed: NumberRange?,
	orientation: Enum.ParticleOrientation?,
	zOffset: number?,
}

local WHITE = Color3.new(1, 1, 1)
local function cs(a: Color3, b: Color3?): ColorSequence
	return if b then ColorSequence.new(a, b) else ColorSequence.new(a)
end

-- OURS. Counts are modest: these fire a handful of times per race at most.
local PRESETS: { [string]: { Preset } } = {
	-- muzzle blast: one big flipbook fireball, a shock ring along the barrel, sparks out of the bore
	muzzle = {
		{ tex = "explosion_8x8", count = 1, lifetime = NumberRange.new(0.75, 0.85), speed = NumberRange.new(4, 8), spread = Vector2.new(10, 10),
			size = ns({ { 0, 16 }, { 1, 18 } }), transparency = ns({ { 0, 0 }, { 1, 0.1 } }), color = cs(WHITE), lightEmission = 0.4, zOffset = 1,
			rotation = NumberRange.new(0, 360) },
		{ tex = "shockwave_8x8", count = 1, lifetime = NumberRange.new(0.45), speed = NumberRange.new(0.01), spread = Vector2.zero,
			size = ns({ { 0, 22 }, { 1, 22 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(rgb(255, 236, 190)), lightEmission = 0.8,
			orientation = Enum.ParticleOrientation.VelocityPerpendicular },
		{ tex = "spark_streak", count = 26, lifetime = NumberRange.new(0.3, 0.6), speed = NumberRange.new(70, 130), spread = Vector2.new(16, 16),
			size = ns({ { 0, 1.8 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(rgb(255, 240, 180), rgb(255, 120, 40)),
			lightEmission = 1, orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -60, 0), drag = 1.5 },
	},
	-- the big lingering powder smoke that rolls out of the muzzle and drifts up
	cannonSmoke = {
		{ tex = "smoke_puff_8x8", count = 9, lifetime = NumberRange.new(2.2, 3.2), speed = NumberRange.new(12, 34), spread = Vector2.new(22, 22),
			size = ns({ { 0, 7 }, { 1, 22 } }), transparency = ns({ { 0, 0.1 }, { 0.7, 0.4 }, { 1, 1 } }), color = cs(rgb(236, 232, 226), rgb(190, 184, 178)),
			accel = Vector3.new(0, 4, 0), drag = 2.2, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-30, 30) },
	},
	-- fuse sparks (emitted a few at a time while the fuse burns)
	fuse = {
		{ tex = "spark_streak", count = 5, lifetime = NumberRange.new(0.18, 0.35), speed = NumberRange.new(8, 18), spread = Vector2.new(70, 70),
			size = ns({ { 0, 0.5 }, { 1, 0.05 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(rgb(255, 250, 200), rgb(255, 150, 40)),
			lightEmission = 1, orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -40, 0) },
	},
	-- landing thump on sand or planks
	landDust = {
		{ tex = "dust_burst_4x4", count = 3, lifetime = NumberRange.new(0.8, 1.1), speed = NumberRange.new(6, 14), spread = Vector2.new(80, 80),
			size = ns({ { 0, 6 }, { 1, 11 } }), transparency = ns({ { 0, 0.1 }, { 1, 1 } }), color = cs(rgb(236, 218, 186)), orientation = Enum.ParticleOrientation.FacingCameraWorldUp },
		{ tex = "shockwave_ring", count = 1, lifetime = NumberRange.new(0.4), speed = NumberRange.new(0.01), spread = Vector2.zero,
			size = ns({ { 0, 4 }, { 1, 26 } }), transparency = ns({ { 0, 0.2 }, { 1, 1 } }), color = cs(rgb(255, 240, 210)),
			orientation = Enum.ParticleOrientation.VelocityPerpendicular },
	},
	-- the gull: a sploosh out of the water and white feathers
	pluck = {
		{ tex = "water_splash_8x8", count = 2, lifetime = NumberRange.new(0.7, 0.9), speed = NumberRange.new(2, 6), spread = Vector2.new(20, 20),
			size = ns({ { 0, 9 }, { 1, 12 } }), transparency = ns({ { 0, 0 }, { 1, 0.2 } }), color = cs(WHITE), orientation = Enum.ParticleOrientation.FacingCameraWorldUp },
		{ tex = "water_droplet", count = 24, lifetime = NumberRange.new(0.6, 1.0), speed = NumberRange.new(14, 30), spread = Vector2.new(40, 40),
			size = ns({ { 0, 1.0 }, { 1, 0.5 } }), transparency = ns({ { 0, 0 }, { 1, 0.6 } }), color = cs(rgb(220, 248, 255)), accel = Vector3.new(0, -60, 0) },
	},
	drips = {
		{ tex = "water_droplet", count = 3, lifetime = NumberRange.new(0.5, 0.8), speed = NumberRange.new(1, 3), spread = Vector2.new(30, 30),
			size = ns({ { 0, 0.7 }, { 1, 0.4 } }), transparency = ns({ { 0, 0.1 }, { 1, 0.7 } }), color = cs(rgb(220, 248, 255)), accel = Vector3.new(0, -50, 0) },
	},
	feathers = {
		{ tex = "leaf", count = 10, lifetime = NumberRange.new(1.4, 2.2), speed = NumberRange.new(6, 14), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.1 }, { 1, 0.9 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = cs(rgb(250, 250, 250), rgb(210, 214, 220)),
			accel = Vector3.new(0, -6, 0), drag = 2.5, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-200, 200) },
	},
	-- boss gags
	slam = {
		{ tex = "dust_burst_4x4", count = 5, lifetime = NumberRange.new(0.9, 1.3), speed = NumberRange.new(10, 22), spread = Vector2.new(85, 85),
			size = ns({ { 0, 9 }, { 1, 18 } }), transparency = ns({ { 0, 0.05 }, { 1, 1 } }), color = cs(rgb(230, 214, 190)), orientation = Enum.ParticleOrientation.FacingCameraWorldUp },
		{ tex = "shockwave_ring", count = 1, lifetime = NumberRange.new(0.5), speed = NumberRange.new(0.01), spread = Vector2.zero,
			size = ns({ { 0, 8 }, { 1, 50 } }), transparency = ns({ { 0, 0.1 }, { 1, 1 } }), color = cs(rgb(255, 236, 200)),
			orientation = Enum.ParticleOrientation.VelocityPerpendicular },
		{ tex = "debris_shard", count = 10, lifetime = NumberRange.new(0.7, 1.1), speed = NumberRange.new(20, 40), spread = Vector2.new(60, 60),
			size = ns({ { 0, 1.2 }, { 1, 0.8 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = cs(rgb(150, 120, 96)),
			accel = Vector3.new(0, -120, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-300, 300) },
	},
	stars = {
		{ tex = "sparkle_star_4x4", count = 8, lifetime = NumberRange.new(0.6, 1.0), speed = NumberRange.new(6, 12), spread = Vector2.new(180, 180),
			size = ns({ { 0, 2.6 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = cs(rgb(255, 230, 120)), lightEmission = 1 },
	},
	smoke = {
		{ tex = "smoke_puff_8x8", count = 3, lifetime = NumberRange.new(1.0, 1.5), speed = NumberRange.new(3, 8), spread = Vector2.new(40, 40),
			size = ns({ { 0, 5 }, { 1, 12 } }), transparency = ns({ { 0, 0.2 }, { 1, 1 } }), color = cs(rgb(70, 64, 62), rgb(130, 124, 120)),
			accel = Vector3.new(0, 8, 0), drag = 1.4, rotation = NumberRange.new(0, 360) },
	},
	ice = {
		{ tex = "sparkle_star_4x4", count = 16, lifetime = NumberRange.new(0.4, 0.8), speed = NumberRange.new(8, 20), spread = Vector2.new(180, 180),
			size = ns({ { 0, 2 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.4 } }), color = cs(rgb(220, 248, 255)), lightEmission = 0.9 },
		{ tex = "snow_burst_4x4", count = 2, lifetime = NumberRange.new(0.7, 0.9), speed = NumberRange.new(2, 5), spread = Vector2.new(60, 60),
			size = ns({ { 0, 10 }, { 1, 14 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = cs(WHITE), orientation = Enum.ParticleOrientation.FacingCameraWorldUp },
	},
	shards = {
		{ tex = "debris_shard", count = 22, lifetime = NumberRange.new(0.8, 1.3), speed = NumberRange.new(25, 55), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.6 }, { 1, 1.0 } }), transparency = ns({ { 0, 0.15 }, { 0.8, 0.3 }, { 1, 1 } }), color = cs(rgb(200, 240, 255), rgb(150, 210, 255)),
			lightEmission = 0.4, accel = Vector3.new(0, -110, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-400, 400) },
	},
	sparks = {
		{ tex = "spark_streak", count = 14, lifetime = NumberRange.new(0.25, 0.5), speed = NumberRange.new(30, 60), spread = Vector2.new(35, 35),
			size = ns({ { 0, 1.3 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(rgb(255, 250, 200), rgb(110, 220, 255)),
			lightEmission = 1, orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -80, 0) },
	},
	poof = {
		{ tex = "smoke_puff_8x8", count = 6, lifetime = NumberRange.new(0.8, 1.1), speed = NumberRange.new(8, 16), spread = Vector2.new(180, 180),
			size = ns({ { 0, 8 }, { 1, 16 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(rgb(250, 248, 240)), rotation = NumberRange.new(0, 360) },
		{ tex = "sparkle_star_4x4", count = 12, lifetime = NumberRange.new(0.5, 0.9), speed = NumberRange.new(10, 22), spread = Vector2.new(180, 180),
			size = ns({ { 0, 2.4 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = cs(rgb(255, 236, 160), rgb(255, 160, 220)), lightEmission = 1 },
	},
	-- ducks: a squeak of golden sparkles and confetti
	duck = {
		{ tex = "confetti_burst_4x4", count = 2, lifetime = NumberRange.new(1.2, 1.5), speed = NumberRange.new(4, 10), spread = Vector2.new(40, 40),
			size = ns({ { 0, 8 }, { 1, 8 } }), transparency = ns({ { 0, 0 }, { 1, 0 } }), color = cs(WHITE), orientation = Enum.ParticleOrientation.FacingCameraWorldUp },
		{ tex = "sparkle_star_4x4", count = 20, lifetime = NumberRange.new(0.7, 1.2), speed = NumberRange.new(14, 30), spread = Vector2.new(180, 180),
			size = ns({ { 0, 2.2 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = cs(rgb(255, 230, 90), rgb(255, 255, 220)), lightEmission = 1,
			accel = Vector3.new(0, -20, 0), drag = 1.2 },
	},
}

function MomentKit.definePreset(name: string, layers: { any })
	if PRESETS[name] == nil then
		PRESETS[name] = layers :: any
	end
end

type Pool = { att: Attachment, emitters: { ParticleEmitter }, preset: { Preset } }
local pools: { [string]: Pool } = {}

local function makeEmitter(p: Preset, parent: Instance): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	if FlipFx.SHEETS[p.tex] then
		FlipFx.apply(pe, p.tex)
	else
		local e = (VfxAssets :: any)[p.tex]
		pe.Texture = if e then e.id else ""
	end
	pe.Enabled = false
	pe.Rate = 0
	pe.Lifetime = p.lifetime
	pe.Speed = p.speed
	pe.SpreadAngle = p.spread
	pe.Size = p.size
	pe.Transparency = p.transparency
	pe.Color = p.color
	pe.LightEmission = p.lightEmission or 0
	pe.LightInfluence = if (p.lightEmission or 0) > 0.5 then 0 else 1
	pe.Acceleration = p.accel or Vector3.zero
	pe.Drag = p.drag or 0
	pe.Rotation = p.rotation or NumberRange.new(0)
	pe.RotSpeed = p.rotSpeed or NumberRange.new(0)
	pe.Orientation = p.orientation or Enum.ParticleOrientation.FacingCamera
	pe.ZOffset = p.zOffset or 0
	pe.EmissionDirection = Enum.NormalId.Front
	pe.LockedToPart = false
	pe.Parent = parent
	return pe
end

local function pool(name: string): Pool?
	local existing = pools[name]
	if existing and existing.att.Parent then
		return existing
	end
	local preset = PRESETS[name]
	if not preset then
		return nil
	end
	local att = Instance.new("Attachment")
	att.Name = "SetPiece_" .. name
	att.Parent = workspace.Terrain
	local emitters = {}
	for _, p in preset do
		table.insert(emitters, makeEmitter(p, att))
	end
	local entry = { att = att, emitters = emitters, preset = preset }
	pools[name] = entry
	return entry
end

-- A VelocityPerpendicular ring emitted exactly vertically is not drawn (zero velocity x world-up basis): lean a vertical
-- facing ~2.5 degrees so ground rings (MomentKit.up) render and still lie flat.
local function offVertical(cf: CFrame): CFrame
	local look = cf.LookVector
	if math.abs(look.Y) > 0.998 then
		return CFrame.lookAt(cf.Position, cf.Position + Vector3.new(0.045, look.Y, 0).Unit, Vector3.zAxis)
	end
	return cf
end

-- Emits a preset at `cf` (LookVector = spray direction); `scale` scales the counts.
function MomentKit.burst(name: string, cf: CFrame, scale: number?)
	local entry = pool(name)
	if not entry then
		return
	end
	entry.att.WorldCFrame = offVertical(cf)
	for i, pe in entry.emitters do
		pe:Emit(math.max(1, math.floor(entry.preset[i].count * (scale or 1) * Settings.particleScale() + 0.5)))
	end
end

function MomentKit.up(pos: Vector3): CFrame
	return CFrame.lookAt(pos, pos + Vector3.yAxis)
end

---------------------------------------------------------------------------------------------------- world text (pooled)

type Pop = { att: Attachment, gui: BillboardGui, label: TextLabel, token: number }
local pops: { [string]: Pop } = {}

local function pop(key: string): Pop
	local existing = pops[key]
	if existing and existing.att.Parent then
		return existing
	end
	local att = Instance.new("Attachment")
	att.Name = "SetPieceText_" .. key
	att.Parent = workspace.Terrain
	local gui = Instance.new("BillboardGui")
	gui.Adornee = att
	gui.LightInfluence = 0
	gui.MaxDistance = 700
	gui.AlwaysOnTop = true
	gui.Enabled = false
	gui.Parent = att
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = MomentKit.CREAM
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = MomentKit.INK
	stroke.Thickness = 3
	stroke.Parent = label
	local p = { att = att, gui = gui, label = label, token = 0 }
	pops[key] = p
	return p
end

-- Comic text at `pos`: pops in with a back-ease to w x h studs, rises `rise` studs, fades over the last 30 %.
-- follow(): optional, re-anchors it every frame (text riding on a moving thing).
function MomentKit.text(key: string, text: string, color: Color3, pos: Vector3, w: number, h: number, dur: number, rise: number, follow: (() -> Vector3?)?)
	local p = pop(key)
	p.label.Text = text
	p.label.TextColor3 = color
	p.label.TextTransparency = 0
	p.att.WorldPosition = pos
	p.gui.Size = UDim2.fromScale(w * 0.3, h * 0.3)
	p.gui.Enabled = true
	p.token += 1
	local mine = p.token
	MomentKit.animate(dur, function(k: number, t: number)
		if p.token ~= mine then
			return
		end
		local s = 0.3 + 0.7 * MomentKit.easeOutBack(math.clamp(t / 0.22, 0, 1))
		p.gui.Size = UDim2.fromScale(w * s, h * s)
		local base = if follow then (follow() or pos) else pos
		p.att.WorldPosition = base + Vector3.new(0, rise * k, 0)
		p.label.TextTransparency = math.clamp((k - 0.7) / 0.3, 0, 1)
	end, function()
		if p.token == mine then
			p.gui.Enabled = false
		end
	end)
end

return MomentKit
