--!strict
-- Race moments VFX (countdown, GO, lap gate, final lap, finish show, podium, boss defeat finale). Client only, visual only.
-- Owner rules, in code: everything is ParticleEmitter layers (flipbooks where the sheet exists), never solid meshes;
-- nothing covers the chase camera's view of the route (rings lie flat on the road, shells open high and off to the
-- verges, confetti jets sit beside the road, every burst lives 1.5 s or less, no full-screen flash); phone budget: one
-- pooled Attachment per preset (a fixed number of emitters, created on first use, never per frame), every Emit count is
-- scaled by Settings.particleScale() and by CelebrationRules.cullScale(distance to the camera); maths/tuning lives in
-- shared/CelebrationRules (specced). Textures: the existing flip_v2 sheets and VfxAssets, plus the procedural
-- fireworks_burst_4x4 (CelebrationTexAssets, 0 = not uploaded: the shell then opens with its spark streaks and the
-- sparkle_star sheet, so the game works before upload).
-- The final lap also starts a subtle vehicle aura (two ember emitters + two thin ribbons on the local vehicle's tail, built
-- once per hull, edge-only writes) that ends when the racer finishes; phone keeps the embers only (CelebrationRules.auraPlan).
-- Entry points (each is pcall-safe for callers): countdown(label), go(), lap(final), finishShow(center, away?, right?),
-- bossFinale(centre, forward, bodyLength, half), auraStop().
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CarConfig = require(Shared:WaitForChild("CarConfig"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local Rules = require(Shared:WaitForChild("CelebrationRules"))
local TexAssets = require(Shared:WaitForChild("CelebrationTexAssets"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local Kit = require(script.Parent:WaitForChild("MomentKit"))

local CelebrationFx = {}

local LocalPlayer = Players.LocalPlayer

-- Tuning (studs). The start/finish gantry is looked up by prefab name; these are the fallbacks and the road width.
local ROAD_HALF = 22 -- verge distance from the road centre for jets and fountains
local GANTRY_AHEAD = 28 -- where the start gantry sides sit ahead of a car on the grid when no gantry prefab is found
local GANTRY_NAMES = { "StartFinishGantry", "FinishGantry", "StartFinishGate", "FTUEFinishArch", "StartForegroundArch" }
local GATE_MAX_DIST = 160 -- a gantry prefab farther than this from the car is not "the" gate

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function ns(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kps)
end

local WHITE = Color3.new(1, 1, 1)
local WARM = Color3.fromRGB(255, 214, 120)
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 96, 96)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 214, 80)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(110, 235, 130)),
	ColorSequenceKeypoint.new(0.75, Color3.fromRGB(100, 200, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 130, 230)),
})

---------------------------------------------------------------------------------------------------- presets

type Layer = {
	tex: string, -- FlipFx sheet, VfxAssets key, or "@fireworks"
	count: number,
	lifetime: NumberRange,
	speed: NumberRange,
	spread: Vector2,
	size: NumberSequence,
	transparency: NumberSequence,
	color: ColorSequence,
	light: number?,
	accel: Vector3?,
	drag: number?,
	rotation: NumberRange?,
	rotSpeed: NumberRange?,
	orientation: Enum.ParticleOrientation?,
	zOffset: number?,
	tint: boolean?, -- colour comes from the burst's tint
	ring: boolean?, -- shockwave ring: constant size on the flipbook, grows on the old fallback texture
	rise: boolean?, -- Speed comes from the burst's `speed` option (shell trails)
}

local FADE = ns({ { 0, 0 }, { 0.7, 0.2 }, { 1, 1 } })

local function ringLayer(size: number, life: number): Layer
	return { tex = "shockwave_8x8", count = 1, lifetime = NumberRange.new(life, life * 1.1), speed = NumberRange.new(0.01), spread = Vector2.zero,
		size = ns({ { 0, size }, { 1, size } }), transparency = FADE, color = ColorSequence.new(WHITE), light = 0.8,
		orientation = Enum.ParticleOrientation.VelocityPerpendicular, zOffset = 0.5, tint = true, ring = true }
end

local function sparkleLayer(count: number, life: number, speed: number, size: number): Layer
	return { tex = "sparkle_star_4x4", count = count, lifetime = NumberRange.new(life * 0.7, life), speed = NumberRange.new(speed * 0.4, speed),
		spread = Vector2.new(180, 180), size = ns({ { 0, size }, { 0.6, size * 0.8 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }),
		color = ColorSequence.new(WHITE), light = 0.8, rotation = NumberRange.new(-15, 15), drag = 2, tint = true }
end

local PRESETS: { [string]: { Layer } } = {
	-- 3-2-1 pulse on the road under the car: a flat tinted ring plus a few sparkles
	-- v19: the additive tinted ring washed out on sunlit sand. Now: a saturated low-glow ring (keeps its colour on bright
	-- ground), a smaller white additive core ring, and a short upward streak column in the beat colour (reads at chase distance).
	pulse = {
		(function(): Layer
			local L = ringLayer(14, 0.55)
			L.light = 0.1
			L.transparency = ns({ { 0, 0.05 }, { 0.75, 0.15 }, { 1, 1 } })
			return L
		end)(),
		(function(): Layer
			local L = ringLayer(8, 0.4)
			L.tint = false
			L.light = 1
			return L
		end)(),
		sparkleLayer(5, 0.6, 14, 1.8),
		{ tex = "spark_streak", count = 8, lifetime = NumberRange.new(0.3, 0.45), speed = NumberRange.new(22, 34), spread = Vector2.new(35, 35),
			size = ns({ { 0, 1.6 }, { 1, 0.2 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(WHITE), light = 0.3,
			orientation = Enum.ParticleOrientation.VelocityParallel, drag = 1, tint = true },
	},
	-- GO / lap gate: the same, bigger, with an upward spray of spark streaks
	gate = {
		ringLayer(30, 0.6),
		sparkleLayer(10, 0.8, 26, 2.4),
		{ tex = "spark_streak", count = 12, lifetime = NumberRange.new(0.4, 0.7), speed = NumberRange.new(30, 55), spread = Vector2.new(20, 20),
			size = ns({ { 0, 1.4 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(WHITE), light = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -50, 0), drag = 1, tint = true },
	},
	-- ground colour jet at the verge: streaks fountaining up, a glow at the nozzle
	jet = {
		{ tex = "spark_streak", count = 14, lifetime = NumberRange.new(0.6, 0.95), speed = NumberRange.new(45, 80), spread = Vector2.new(12, 12),
			size = ns({ { 0, 1.8 }, { 1, 0.2 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(WHITE), light = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -60, 0), drag = 0.5, tint = true },
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.3), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 6 }, { 1, 9 } }), transparency = ns({ { 0, 0.3 }, { 1, 1 } }), color = ColorSequence.new(WHITE), light = 1, tint = true },
	},
	confetti = {
		{ tex = "confetti_burst_4x4", count = 14, lifetime = NumberRange.new(1.1, 1.6), speed = NumberRange.new(30, 60), spread = Vector2.new(24, 24),
			size = ns({ { 0, 2.2 }, { 1, 2.2 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = RAINBOW, light = 0.2,
			accel = Vector3.new(0, -26, 0), drag = 1.2, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-200, 200) },
	},
	streamers = {
		{ tex = "spark_streak", count = 9, lifetime = NumberRange.new(1.0, 1.5), speed = NumberRange.new(35, 65), spread = Vector2.new(30, 30),
			size = ns({ { 0, 3.2 }, { 0.7, 2.4 }, { 1, 0.4 } }), transparency = ns({ { 0, 0 }, { 0.7, 0.1 }, { 1, 1 } }), color = RAINBOW, light = 0.6,
			orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -22, 0), drag = 1.4 },
	},
	-- firework shell, stage 1: a few streaks launched fast upward, dying about where the shell opens
	shellTrail = {
		{ tex = "spark_streak", count = 6, lifetime = NumberRange.new(0.5, 0.6), speed = NumberRange.new(60, 70), spread = Vector2.new(2, 2),
			size = ns({ { 0, 1.5 }, { 1, 0.3 } }), transparency = ns({ { 0, 0 }, { 0.8, 0.1 }, { 1, 1 } }), color = ColorSequence.new(WHITE), light = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, drag = 0, tint = true, rise = true },
	},
	-- stage 2: the tinted opening (flipbook sheet when uploaded, radial streaks and glitter always)
	shellBoom = {
		{ tex = "@fireworks", count = 1, lifetime = NumberRange.new(1.0, 1.1), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 36 }, { 1, 40 } }), transparency = ns({ { 0, 0 }, { 1, 0 } }), color = ColorSequence.new(WHITE), light = 1, tint = true },
		{ tex = "spark_streak", count = 34, lifetime = NumberRange.new(0.8, 1.2), speed = NumberRange.new(26, 46), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.6 }, { 0.6, 1.1 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 0.7, 0.2 }, { 1, 1 } }), color = ColorSequence.new(WHITE), light = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -22, 0), drag = 2.2, tint = true },
		{ tex = "sparkle_star_4x4", count = 8, lifetime = NumberRange.new(0.8, 1.3), speed = NumberRange.new(8, 24), spread = Vector2.new(180, 180),
			size = ns({ { 0, 2.6 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = ColorSequence.new(WARM), light = 0.9,
			accel = Vector3.new(0, -8, 0), drag = 2 },
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.14), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 10 }, { 1, 14 } }), transparency = ns({ { 0, 0.2 }, { 1, 1 } }), color = ColorSequence.new(WHITE), light = 1, tint = true },
	},
	-- vertical light sweep column (final lap): glow dots climbing a post
	sweep = {
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.35), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 5 }, { 1, 1 } }), transparency = ns({ { 0, 0.2 }, { 1, 1 } }), color = ColorSequence.new(WHITE), light = 1, tint = true },
	},
	-- boss finale: one explosion of the chain, with sparks and a puff
	bossBoom = {
		{ tex = "explosion_8x8", count = 1, lifetime = NumberRange.new(0.8, 0.95), speed = NumberRange.new(0, 1), spread = Vector2.new(180, 180),
			size = ns({ { 0, 10 }, { 1, 10 } }), transparency = ns({ { 0, 0 }, { 1, 0.1 } }), color = ColorSequence.new(WHITE), light = 0.4,
			rotation = NumberRange.new(0, 360), zOffset = 1 },
		{ tex = "spark_streak", count = 14, lifetime = NumberRange.new(0.4, 0.7), speed = NumberRange.new(40, 80), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.8 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(Color3.fromRGB(255, 240, 180), Color3.fromRGB(255, 120, 40)),
			light = 1, orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -50, 0), drag = 1.5 },
		{ tex = "smoke_puff_8x8", count = 1, lifetime = NumberRange.new(1.0, 1.2), speed = NumberRange.new(2, 6), spread = Vector2.new(180, 180),
			size = ns({ { 0, 6 }, { 1, 10 } }), transparency = ns({ { 0, 0.3 }, { 1, 1 } }), color = ColorSequence.new(Color3.fromRGB(190, 180, 170)), light = 0,
			rotation = NumberRange.new(0, 360) },
	},
	bossDebris = {
		{ tex = "debris_shard", count = 16, lifetime = NumberRange.new(0.9, 1.4), speed = NumberRange.new(25, 60), spread = Vector2.new(70, 70),
			size = ns({ { 0, 1.6 }, { 1, 0.6 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = ColorSequence.new(Color3.fromRGB(230, 205, 170)),
			light = 0, accel = Vector3.new(0, -80, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-300, 300) },
	},
	-- reward rain: confetti and sparkles drifting down from above the boss
	rain = {
		{ tex = "confetti_burst_4x4", count = 10, lifetime = NumberRange.new(1.2, 1.6), speed = NumberRange.new(2, 10), spread = Vector2.new(70, 70),
			size = ns({ { 0, 2 }, { 1, 2 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = RAINBOW, light = 0.2,
			accel = Vector3.new(0, -9, 0), drag = 1, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-180, 180) },
		sparkleLayer(5, 1.2, 8, 2),
	},
}

---------------------------------------------------------------------------------------------------- pooled emitters

type Pool = { att: Attachment, emitters: { ParticleEmitter }, lastSize: number }
local pools: { [string]: Pool } = {}

local function fireworksId(): string?
	local id = TexAssets.fireworks_burst_4x4
	return if type(id) == "number" and id > 0 then "rbxassetid://" .. tostring(id) else nil
end

local function scaledSeq(seq: NumberSequence, k: number): NumberSequence
	if k == 1 then
		return seq
	end
	local kps = {}
	for _, kp in seq.Keypoints do
		table.insert(kps, NumberSequenceKeypoint.new(kp.Time, kp.Value * k))
	end
	return NumberSequence.new(kps)
end

local function layerSize(L: Layer, k: number): NumberSequence
	if L.ring and not FlipFx.isFlip("shockwave_8x8") then
		-- the old flat ring texture grows from a quarter to 1.2 x (the new sheet grows its ring inside the sheet)
		local s = L.size.Keypoints[1].Value * k
		return ns({ { 0, s * 0.25 }, { 1, s * 1.2 } })
	end
	return scaledSeq(L.size, k)
end

local function makeEmitter(L: Layer): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	if L.tex == "@fireworks" then
		local id = fireworksId()
		if id then
			pe.Texture = id
			pe.FlipbookLayout = Enum.ParticleFlipbookLayout.Grid4x4
			pe.FlipbookMode = Enum.ParticleFlipbookMode.OneShot
		else
			FlipFx.apply(pe, "sparkle_star_4x4") -- not uploaded yet: the streak layers carry the shell
		end
	elseif FlipFx.SHEETS[L.tex] then
		FlipFx.apply(pe, L.tex)
	else
		local e = (VfxAssets :: any)[L.tex]
		pe.Texture = if e then e.id else ""
	end
	pe.Enabled = false
	pe.Rate = 0
	pe.Lifetime = L.lifetime
	pe.Speed = L.speed
	pe.SpreadAngle = L.spread
	pe.Size = layerSize(L, 1)
	pe.Transparency = L.transparency
	pe.Color = L.color
	pe.LightEmission = L.light or 0
	pe.LightInfluence = if (L.light or 0) >= 0.45 then 0 else 1
	pe.Acceleration = L.accel or Vector3.zero
	pe.Drag = L.drag or 0
	pe.Rotation = L.rotation or NumberRange.new(0)
	pe.RotSpeed = L.rotSpeed or NumberRange.new(0)
	pe.Orientation = L.orientation or Enum.ParticleOrientation.FacingCamera
	pe.ZOffset = L.zOffset or 0
	pe.EmissionDirection = Enum.NormalId.Front
	pe.LockedToPart = false
	return pe
end

local function getPool(name: string): Pool?
	local existing = pools[name]
	if existing and existing.att.Parent then
		return existing
	end
	local preset = PRESETS[name]
	if not preset then
		return nil
	end
	local att = Instance.new("Attachment")
	att.Name = "Celebration_" .. name
	att.Parent = workspace.Terrain
	local emitters = {}
	for _, L in preset do
		local pe = makeEmitter(L)
		pe.Parent = att
		table.insert(emitters, pe)
	end
	local entry = { att = att, emitters = emitters, lastSize = 1 }
	pools[name] = entry
	return entry
end

export type Opts = { scale: number?, tint: Color3?, size: number?, speed: number? }

-- A VelocityPerpendicular ring emitted exactly vertically is not drawn (zero velocity x world-up basis), so the flat rings
-- on the road (countdown, GO, lap gate) never showed. Lean a vertical facing ~2.5 degrees: still flat, now rendered.
local function offVertical(cf: CFrame): CFrame
	local look = cf.LookVector
	if math.abs(look.Y) > 0.998 then
		return CFrame.lookAt(cf.Position, cf.Position + Vector3.new(0.045, look.Y, 0).Unit, Vector3.zAxis)
	end
	return cf
end

-- Emits preset `name` at `cf` (LookVector = spray direction / ring normal). Counts x particleScale x distance cull.
local function emit(name: string, cf: CFrame, o: Opts?)
	local cam = workspace.CurrentCamera
	local cull = if cam then Rules.cullScale((cf.Position - cam.CFrame.Position).Magnitude) else 1
	local k = (if o and o.scale then o.scale else 1) * Settings.particleScale() * cull
	if k <= 0 then
		return
	end
	local entry = getPool(name)
	if not entry then
		return
	end
	local preset = PRESETS[name]
	local sizeK = if o and o.size then o.size else 1
	entry.att.WorldCFrame = offVertical(cf)
	for i, pe in entry.emitters do
		local L = preset[i]
		if o and o.tint and L.tint then
			pe.Color = ColorSequence.new(o.tint)
		end
		if sizeK ~= 1 or entry.lastSize ~= 1 then
			pe.Size = layerSize(L, sizeK)
		end
		if L.rise and o and o.speed then
			pe.Speed = NumberRange.new(o.speed * 0.92, o.speed)
		end
		local n = Rules.count(L.count, k)
		if n > 0 then
			pe:Emit(n)
		end
	end
	entry.lastSize = sizeK
end

---------------------------------------------------------------------------------------------------- geometry

local function localHull(): BasePart?
	local model = Kit.vehicleOf(LocalPlayer.UserId)
	return if model then Kit.hullOf(model) else nil
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.zAxis
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- The road/ground just under `pos` (a hull rides low; a plane flies up to 80 studs over it); else a little below.
local function groundUnder(pos: Vector3, skip: Instance?): Vector3
	local list: { Instance } = {}
	if skip then
		table.insert(list, skip)
	end
	local cam = workspace.CurrentCamera
	if cam then
		table.insert(list, cam)
	end
	rayParams.FilterDescendantsInstances = list
	local hit = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -90, 0), rayParams)
	return if hit then hit.Position + Vector3.new(0, 0.6, 0) else pos - Vector3.new(0, 6, 0)
end

local COUNTDOWN_AHEAD = 6 -- cars
local COUNTDOWN_AHEAD_PLANE = 24 -- planes hover and the chase camera looks down past the nose: 6 studs left the ring at the bottom edge
local function countdownAhead(model: Instance): number
	return if string.sub(model.Name, 1, 4) == "Car_" then COUNTDOWN_AHEAD else COUNTDOWN_AHEAD_PLANE
end
local gateCache: Instance? = nil

-- The start/finish gantry near `near`, found by prefab name (cached); nil when the map has none close by.
local function findGate(near: Vector3): Vector3?
	local g = gateCache
	if g and g.Parent == nil then
		g = nil
		gateCache = nil
	end
	if not g then
		for _, n in GANTRY_NAMES do
			local f = workspace:FindFirstChild(n, true)
			if f and (f:IsA("Model") or f:IsA("BasePart")) then
				g = f
				break
			end
		end
		gateCache = g
	end
	if not g then
		return nil
	end
	local pos = if g:IsA("Model") then g:GetPivot().Position else (g :: BasePart).Position
	return if (pos - near).Magnitude <= GATE_MAX_DIST then pos else nil
end

type Pose = { pos: Vector3, fwd: Vector3, right: Vector3, model: Instance }

-- Where the local vehicle is and which way it faces (flat forward and right), nil when it has none.
local function pose(): Pose?
	local hull = localHull()
	if not hull then
		return nil
	end
	local fwd = flat(hull.CFrame.LookVector)
	return { pos = hull.Position, fwd = fwd, right = fwd:Cross(Vector3.yAxis).Unit, model = hull.Parent :: Instance }
end

---------------------------------------------------------------------------------------------------- countdown / GO

-- 3 / 2 / 1: a flat coloured ring pulses out on the road under the car.
function CelebrationFx.countdown(label: string)
	if label == "GO!" then
		CelebrationFx.go()
		return
	end
	local ps = pose()
	if not ps then
		return
	end
	-- v20: ~6 studs ahead of the hull so the car body never hides the ring from the chase camera.
	local g = groundUnder(ps.pos + ps.fwd * countdownAhead(ps.model), ps.model)
	emit("pulse", CFrame.lookAt(g, g + Vector3.yAxis), { tint = rgb(Rules.countdownColor(label)), size = Rules.countdownRingSize(label) / 14 })
end

-- Confetti jets and streamers at the two sides of the start gantry (leaning in a little), and a streak of colour.
local function gantrySides(pos: Vector3, fwd: Vector3, right: Vector3, model: Instance)
	local centre = findGate(pos) or (pos + fwd * GANTRY_AHEAD)
	for _, side in { -1, 1 } do
		local base = groundUnder(centre + right * side * ROAD_HALF, model)
		local up = Vector3.yAxis * 1.0 - right * side * 0.35 + fwd * 0.1
		emit("confetti", CFrame.lookAt(base, base + up), { scale = 1 })
		emit("streamers", CFrame.lookAt(base, base + up), { scale = 0.7 })
	end
end

-- GO: a big green shockwave ring on the road, a short FOV pop and a hint of shake, confetti at the gantry sides.
function CelebrationFx.go()
	local ps = pose()
	if not ps then
		return
	end
	local g = groundUnder(ps.pos + ps.fwd * countdownAhead(ps.model), ps.model)
	emit("gate", CFrame.lookAt(g, g + Vector3.yAxis), { tint = rgb(Rules.countdownColor("GO!")), size = Rules.countdownRingSize("GO!") / 30 })
	local cam = workspace.CurrentCamera
	if cam then
		-- Small and one-shot: the controller's own FOV response eases it back over a few frames.
		cam.FieldOfView += Rules.fovPop(Settings.lowGraphics())
	end
	Kit.trauma(0.1)
	gantrySides(ps.pos, ps.fwd, ps.right, ps.model)
end

---------------------------------------------------------------------------------------------------- lap / final lap

local sweepToken = 0

-- Two glow posts' worth of light climbing the verges at the gate (final lap).
local function lightSweep(centre: Vector3, right: Vector3, model: Instance)
	sweepToken += 1
	local token = sweepToken
	local bases = {
		groundUnder(centre + right * ROAD_HALF, model),
		groundUnder(centre - right * ROAD_HALF, model),
	}
	Kit.animate(0.6, function(k: number)
		if token ~= sweepToken then
			return
		end
		for i, b in bases do
			emit("sweep", CFrame.new(b + Vector3.new(0, 2 + k * 32, 0)), { tint = if i == 1 then Color3.fromRGB(255, 90, 70) else Color3.fromRGB(255, 200, 80), scale = 0.5 })
		end
	end)
end

-- Final-lap aura. State: the hull it is built on, its attachments/emitters/ribbons, and the poll connection (10 Hz).
type Aura = { hull: BasePart, root: { Instance }, embers: { ParticleEmitter }, trails: { Trail }, rate: number, trailOn: boolean }
local aura: Aura? = nil
local auraConn: RBXScriptConnection? = nil
local auraClock = 0

local function auraColor(i: number): Color3
	return rgb(Rules.AURA_COLORS[i] :: { number })
end

local function buildAura(hull: BasePart): Aura
	local half = hull.Size * 0.5
	local x = math.min(half.X * 0.7, 3)
	local y = -half.Y * 0.3
	local z = half.Z -- the tail (the hull's -Z is forward)
	local root: { Instance } = {}
	local embers: { ParticleEmitter } = {}
	local trails: { Trail } = {}
	for k, side in { -1, 1 } do
		local a0 = Instance.new("Attachment")
		a0.Name = "FinalLapAura_" .. k
		a0.Position = Vector3.new(x * side, y, z)
		a0.Parent = hull
		local a1 = Instance.new("Attachment")
		a1.Name = "FinalLapAuraB_" .. k
		a1.Position = Vector3.new(x * side, y + 0.6, z)
		a1.Parent = hull
		table.insert(root, a0)
		table.insert(root, a1)
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "FinalLapEmbers"
		FlipFx.apply(pe, "ember")
		pe.Enabled = false
		pe.Rate = 0
		pe.Lifetime = NumberRange.new(0.3, 0.4)
		pe.Speed = NumberRange.new(3, 8)
		pe.SpreadAngle = Vector2.new(30, 30)
		pe.EmissionDirection = Enum.NormalId.Back
		pe.Size = ns({ { 0, 0.8 }, { 1, 0 } })
		pe.Transparency = ns({ { 0, 0.3 }, { 0.8, 0.4 }, { 1, 1 } }) -- low opacity: a glow on the tail, not a smoke screen
		pe.Color = ColorSequence.new(auraColor(1), auraColor(2))
		pe.LightEmission = 1
		pe.LightInfluence = 0
		pe.ZOffset = -0.5
		pe.Parent = a0
		table.insert(embers, pe)
		local t = Instance.new("Trail")
		t.Name = "FinalLapRibbon"
		t.Attachment0 = a0
		t.Attachment1 = a1
		t.Texture = (VfxAssets :: any).trail_soft.id
		t.TextureMode = Enum.TextureMode.Stretch
		t.FaceCamera = true
		t.Lifetime = 0.25
		t.MinLength = 0.2
		t.LightEmission = 1
		t.LightInfluence = 0
		t.Color = ColorSequence.new(auraColor(1), auraColor(2))
		t.Transparency = ns({ { 0, 0.5 }, { 1, 1 } })
		t.Enabled = false
		t.Parent = a0
		table.insert(trails, t)
	end
	return { hull = hull, root = root, embers = embers, trails = trails, rate = -1, trailOn = false }
end

local function destroyAura()
	local a = aura
	aura = nil
	if a then
		for _, i in a.root do
			i:Destroy() -- the emitters and ribbons are children of the attachments
		end
	end
end

function CelebrationFx.auraStop()
	local c = auraConn
	auraConn = nil
	if c then
		c:Disconnect()
	end
	destroyAura()
end

local function auraStep(dt: number)
	auraClock += dt
	if auraClock < 0.1 then
		return
	end
	auraClock = 0
	local hull = localHull()
	if not Rules.auraActive(true, LocalPlayer:GetAttribute("RaceFinished") == true, hull ~= nil) then
		CelebrationFx.auraStop()
		return
	end
	local h = hull :: BasePart
	local a = aura
	if not a or a.hull ~= h or not a.hull.Parent then
		destroyAura()
		a = buildAura(h)
		aura = a
	end
	local au = a :: Aura
	local plan = Rules.auraPlan(Settings.particleScale())
	if au.rate ~= plan.emberRate then
		au.rate = plan.emberRate
		for _, pe in au.embers do
			pe.Rate = plan.emberRate
			pe.Enabled = plan.emberRate > 0
		end
	end
	local on = plan.trail and Rules.auraTrailOn(h.AssemblyLinearVelocity.Magnitude, CarConfig.TOP_SPEED, au.trailOn)
	if on ~= au.trailOn then
		au.trailOn = on
		for _, t in au.trails do
			t.Enabled = on
		end
	end
end

-- Starts the aura on the local vehicle (idempotent); it ends by itself at the finish (RaceFinished), without a vehicle, or
-- through auraStop.
local function auraStart()
	if not auraConn then
		auraClock = 1
		auraConn = RunService.Heartbeat:Connect(auraStep)
	end
end

-- Lap complete (the local car just crossed the line): a ring and sparkles on the road at the gate and colour fountains at
-- both verges. Final lap adds the light sweep and two shells off to the sides, away from the camera.
function CelebrationFx.lap(final: boolean)
	local ps = pose()
	if not ps then
		return
	end
	local pos, fwd, right, model = ps.pos, ps.fwd, ps.right, ps.model
	local centre = findGate(pos) or pos
	local g = groundUnder(centre, model)
	local tint = if final then Color3.fromRGB(255, 120, 90) else Color3.fromRGB(255, 226, 110)
	emit("gate", CFrame.lookAt(g, g + Vector3.yAxis), { tint = tint, size = 0.8 })
	for i, side in { -1, 1 } do
		local b = groundUnder(centre + right * side * ROAD_HALF, model)
		emit("jet", CFrame.lookAt(b, b + Vector3.yAxis), { tint = rgb(Rules.SHELL_COLORS[if final then i * 2 else i]) })
	end
	if final then
		auraStart()
		lightSweep(centre, right, model)
		local plan = Rules.shellPlan(4)
		for i = 1, 2 do
			local s = plan[i]
			CelebrationFx.shell(centre + fwd * (s.ahead + 20) + right * s.side * ROAD_HALF * 1.4, s.height, rgb(Rules.SHELL_COLORS[s.color]), 0.15 + s.delay)
		end
	end
end

---------------------------------------------------------------------------------------------------- fireworks

-- One shell: a short rising trail from `base`, then the tinted opening `height` studs above it, `delay` s from now.
function CelebrationFx.shell(base: Vector3, height: number, tint: Color3, delay: number)
	task.delay(delay, function()
		emit("shellTrail", CFrame.lookAt(base, base + Vector3.yAxis), { tint = tint, speed = height / Rules.SHELL_RISE })
		task.delay(Rules.SHELL_RISE, function()
			emit("shellBoom", CFrame.new(base + Vector3.new(0, height, 0)), { tint = tint })
		end)
	end)
end

-- The finish show: 4-6 shells (rising trail, then a tinted opening) over the verges beyond `center`, streamer and
-- confetti jets and colour fountains at the arch sides. `away` is the flat direction away from the camera, `right` the
-- road's right; both default to the camera's view. Total under two seconds; every count is phone-scaled in emit().
function CelebrationFx.finishShow(center: Vector3, away: Vector3?, right: Vector3?)
	CelebrationFx.auraStop()
	local cam = workspace.CurrentCamera
	local look = away or (if cam then flat(cam.CFrame.LookVector) else Vector3.zAxis)
	local rt = right or (look:Cross(Vector3.yAxis).Unit)
	local model = Kit.vehicleOf(LocalPlayer.UserId)
	local plan = Rules.shellPlan(if Settings.lowGraphics() then 4 else 6)
	for _, s in plan do
		local base = groundUnder(center + look * s.ahead + rt * s.side * ROAD_HALF * 1.5, model)
		CelebrationFx.shell(base, s.height, rgb(Rules.SHELL_COLORS[s.color]), s.delay)
	end
	-- ground colour jets and streamers beside the arch, twice
	for round = 0, 1 do
		task.delay(round * 0.55, function()
			for i, side in { -1, 1 } do
				local b = groundUnder(center + rt * side * ROAD_HALF, model)
				-- v21: the jets leaned INWARD (-0.25 / -0.3) and dropped streamers and confetti on the road centre for ~2 s; they
				-- lean outward now and stay at the verges.
				emit("jet", CFrame.lookAt(b, b + Vector3.yAxis + rt * side * 0.2), { tint = rgb(Rules.SHELL_COLORS[(i + round * 2 - 1) % #Rules.SHELL_COLORS + 1]) })
				emit("streamers", CFrame.lookAt(b, b + Vector3.yAxis + rt * side * 0.25), { scale = 0.8 })
				emit("confetti", CFrame.lookAt(b, b + Vector3.yAxis + rt * side * 0.25), { scale = 0.8 })
			end
		end)
	end
end

---------------------------------------------------------------------------------------------------- boss finale

-- Boss defeat: a chain of explosions down the body (tail to head), a ground shockwave, debris, a big camera pulse and a
-- short confetti/sparkle reward rain from above. `centre` is the body centre, `forward` the body axis, `half` half height.
-- Sizes are capped (CelebrationRules.bossBurstSize) so the racer still sees the road through it.
function CelebrationFx.bossFinale(centre: Vector3, forward: Vector3, bodyLength: number, half: number)
	local axis = flat(forward)
	local base = Rules.bossBurstSize(bodyLength)
	for _, c in Rules.bossChain(5) do
		task.delay(c.delay, function()
			local p = centre + axis * (c.along * bodyLength) + Vector3.new(0, half * 0.3, 0)
			emit("bossBoom", CFrame.lookAt(p, p + Vector3.yAxis), { size = base * c.size / 10, scale = if c.size > 1.2 then 1 else 0.7 })
			Kit.trauma(0.12 * c.size)
		end)
	end
	local last = Rules.bossChain(5)
	local tEnd = last[#last].delay
	task.delay(tEnd, function()
		local g = centre - Vector3.new(0, half * 0.9, 0)
		emit("gate", CFrame.lookAt(g, g + Vector3.yAxis), { tint = Color3.fromRGB(255, 210, 120), size = math.clamp(bodyLength / 30, 0.8, 1.6) })
		emit("bossDebris", CFrame.lookAt(centre, centre + Vector3.yAxis))
		Kit.trauma(0.5)
	end)
	for i = 0, 2 do
		task.delay(tEnd + 0.25 + i * 0.25, function()
			local p = centre + Vector3.new((i - 1) * 8, half + 14, 0) + axis * ((i - 1) * 6)
			emit("rain", CFrame.lookAt(p, p - Vector3.yAxis), { scale = 0.8 })
		end)
	end
end

return CelebrationFx
