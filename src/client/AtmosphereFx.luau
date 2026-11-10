--!strict
-- Per-map atmosphere (VFX atmosphere lane), layered on top of Vfx's AMBIENT emitters (which it never touches).
--   DINO   falling ash flakes, a low lava glow light over lava, faint heat wisps rising off it
--   FOREST light shafts either side of the route, glinting pollen motes (sun rays live in lighting/forest1)
--   SNOW   wind-blown ground snow streaks sweeping across the road
--   ISLAND sun glints on the water, sea spray where the water meets a shore
--   SPACE  star dust streaming past the sides, streaking longer with speed
--   HUB    blossom drift and a warm light
-- Budget rules (owner VFX rules, docs/ART_BAR.md): every emitter is built once per zone (a fixed few, no per-frame
-- Instance.new), every rate is base * Settings.particleScale() through AtmosphereRules.rate, LOW GRAPHICS drops the
-- optional layers and the lights, the probe-driven layers (glints, spray, lava light, heat wisps) run only while their
-- surface is within range, and nothing sits in the middle of the view: shafts and star dust live in side cells, the
-- ground layers are thin low-alpha streaks on the ground, all faint and short-lived. Pure tuning: shared/AtmosphereRules.
-- Textures: shared/AtmosTexAssets (0 = not uploaded: the named VfxAssets fallback stands in).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("AtmosphereRules"))
local AtmosTexAssets = require(Shared:WaitForChild("AtmosTexAssets"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local AtmosphereFx = {}

local TICK = 0.25 -- seconds between probe raycasts and rate updates
local WIND = Vector3.new(1, 0, 0.35).Unit -- SNOW-1 cross wind (the same side-drift as Vfx's SNOW ambience accel)
local GROUND_PROBES = { { 0, 0 }, { 0, 40 }, { 0, 80 }, { -40, 40 }, { 40, 40 } } -- { right, look } studs, probed straight down

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function ns(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kps)
end

-- Own textures first (when uploaded), else the named VfxAssets fallback.
local function ownTexture(key: string): string
	local id = (AtmosTexAssets :: any)[key]
	if type(id) == "number" and id > 0 then
		return "rbxassetid://" .. tostring(id)
	end
	local fb = (AtmosTexAssets.FALLBACK :: any)[key]
	local e = (VfxAssets :: any)[fb]
	return if e then e.id else ""
end

type Layer = {
	name: string, -- AtmosphereRules.RATES key
	cell: string, -- AtmosphereRules.CELLS key, or "Sea" / "Spray" (world-placed by the probe)
	orient: string?, -- "camera" (default, yaw frame), "toward" (emission points at the camera), "wind"
	own: string?, -- AtmosTexAssets key
	flip: string?, -- FlipFx sheet or VfxAssets key
	dir: Enum.NormalId?,
	life: NumberRange,
	speed: NumberRange,
	spread: number,
	size: NumberSequence,
	transparency: NumberSequence,
	color: ColorSequence,
	emission: number,
	accel: Vector3?,
	drag: number?,
	rotation: NumberRange?,
	rotSpeed: NumberRange?,
	orientation: Enum.ParticleOrientation?,
	zOffset: number?,
}

local FADE = ns({ { 0, 1 }, { 0.15, 0.1 }, { 0.8, 0.3 }, { 1, 1 } })

local LAYERS: { [string]: { Layer } } = {
	DINO = {
		-- Ash flakes sifting down through the cavern air, ember-lit orange at birth, charcoal as they cool.
		{ name = "DINO.ash", cell = "Around", own = "ash_flake", life = NumberRange.new(6, 9), speed = NumberRange.new(0, 1), spread = 180,
			size = ns({ { 0, 0.5 }, { 1, 0.4 } }), transparency = FADE,
			color = ColorSequence.new(rgb(255, 150, 80), rgb(96, 88, 84)), emission = 0.12, accel = Vector3.new(2, -3.5, 1), drag = 0.8,
			rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-120, 120), dir = Enum.NormalId.Bottom },
		-- Heat wisps: big, very faint, warm soft puffs rising off the lava (gated by how much lava is near).
		{ name = "DINO.shimmer", cell = "Low", flip = "glow_soft", life = NumberRange.new(2, 3), speed = NumberRange.new(0.5, 1.5), spread = 25,
			size = ns({ { 0, 5 }, { 1, 11 } }), transparency = ns({ { 0, 1 }, { 0.25, 0.9 }, { 0.7, 0.93 }, { 1, 1 } }),
			color = ColorSequence.new(rgb(255, 170, 96), rgb(255, 214, 160)), emission = 0.45, accel = Vector3.new(0.5, 7, 0.3),
			dir = Enum.NormalId.Top },
	},
	FOREST = {
		-- Light shafts: tall, soft and 86% see-through at their brightest, drifting in beside the route.
		{ name = "FOREST.shaftsL", cell = "Left", own = "god_ray", life = NumberRange.new(6, 8), speed = NumberRange.new(0.2, 0.6), spread = 180,
			size = ns({ { 0, 26 }, { 1, 30 } }), transparency = ns({ { 0, 1 }, { 0.3, 0.86 }, { 0.7, 0.86 }, { 1, 1 } }),
			color = ColorSequence.new(rgb(255, 232, 170), rgb(255, 210, 130)), emission = 0.6,
			orientation = Enum.ParticleOrientation.FacingCameraWorldUp, dir = Enum.NormalId.Bottom },
		{ name = "FOREST.shaftsR", cell = "Right", own = "god_ray", life = NumberRange.new(6, 8), speed = NumberRange.new(0.2, 0.6), spread = 180,
			size = ns({ { 0, 26 }, { 1, 30 } }), transparency = ns({ { 0, 1 }, { 0.3, 0.86 }, { 0.7, 0.86 }, { 1, 1 } }),
			color = ColorSequence.new(rgb(255, 232, 170), rgb(255, 210, 130)), emission = 0.6,
			orientation = Enum.ParticleOrientation.FacingCameraWorldUp, dir = Enum.NormalId.Bottom },
		-- Pollen motes: small twinkles lit gold in the low sun.
		{ name = "FOREST.pollen", cell = "Around", flip = "sparkle_star_4x4", life = NumberRange.new(3, 5), speed = NumberRange.new(0.3, 1), spread = 180,
			size = ns({ { 0, 0 }, { 0.3, 0.55 }, { 0.7, 0.45 }, { 1, 0 } }), transparency = ns({ { 0, 0.2 }, { 1, 0.6 } }),
			color = ColorSequence.new(rgb(255, 240, 180), rgb(255, 214, 120)), emission = 0.9, accel = Vector3.new(1.2, 0.3, 0.5),
			dir = Enum.NormalId.Bottom },
	},
	SNOW = {
		-- Ground streaks: thin white wisps sweeping across the road on the wind, ground-level, half see-through, ~1 s each.
		{ name = "SNOW.streaks", cell = "Low", orient = "wind", own = "star_streak", life = NumberRange.new(0.9, 1.5), speed = NumberRange.new(45, 70),
			spread = 8, size = ns({ { 0, 0.4 }, { 1, 0.8 } }), transparency = ns({ { 0, 1 }, { 0.2, 0.75 }, { 0.7, 0.8 }, { 1, 1 } }),
			color = ColorSequence.new(rgb(226, 240, 255), rgb(160, 192, 236)), emission = 0.12,
			orientation = Enum.ParticleOrientation.VelocityParallel, dir = Enum.NormalId.Front },
	},
	ISLAND = {
		-- Sun glints: quick white twinkles on the water.
		-- v29 W1b A5 (critic v29 island2 09/10/11: an always-on cloud of big four-point stars round the camera): small,
		-- half see-through, less emissive glints (peak 1.9 -> 0.8 studs, alpha 0 -> 0.35, emission 1 -> 0.55).
		{ name = "ISLAND.glints", cell = "Sea", flip = "sparkle_star_4x4", life = NumberRange.new(0.4, 0.7), speed = NumberRange.new(0, 0.3), spread = 180,
			size = ns({ { 0, 0 }, { 0.4, 0.8 }, { 1, 0 } }), transparency = ns({ { 0, 0.35 }, { 1, 0.7 } }),
			color = ColorSequence.new(rgb(255, 252, 232), rgb(255, 226, 170)), emission = 0.55, rotation = NumberRange.new(-20, 20),
			dir = Enum.NormalId.Top },
		-- Shore spray: small white splash puffs where the water meets land.
		{ name = "ISLAND.spray", cell = "Spray", flip = "water_splash_8x8", life = NumberRange.new(0.7, 1.0), speed = NumberRange.new(2, 6), spread = 25,
			size = ns({ { 0, 6 }, { 1, 6 } }), transparency = ns({ { 0, 0.15 }, { 0.7, 0.4 }, { 1, 1 } }),
			color = ColorSequence.new(rgb(255, 255, 255), rgb(222, 244, 255)), emission = 0.15, accel = Vector3.new(0, -4, 0),
			rotation = NumberRange.new(0, 360), dir = Enum.NormalId.Top },
	},
	SPACE = {
		-- Star dust streaming past the left, right and top edges (never the middle of the view). Streak length and
		-- speed follow the camera speed (updateSpeedLayers).
		{ name = "SPACE.dustL", cell = "Left", orient = "toward", own = "star_streak", life = NumberRange.new(1.2, 2), speed = NumberRange.new(30, 40),
			spread = 5, size = ns({ { 0, 1 }, { 1, 1 } }), transparency = ns({ { 0, 1 }, { 0.15, 0.3 }, { 0.8, 0.45 }, { 1, 1 } }),
			color = ColorSequence.new(rgb(200, 236, 255), rgb(214, 170, 255)), emission = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, dir = Enum.NormalId.Front },
		{ name = "SPACE.dustR", cell = "Right", orient = "toward", own = "star_streak", life = NumberRange.new(1.2, 2), speed = NumberRange.new(30, 40),
			spread = 5, size = ns({ { 0, 1 }, { 1, 1 } }), transparency = ns({ { 0, 1 }, { 0.15, 0.3 }, { 0.8, 0.45 }, { 1, 1 } }),
			color = ColorSequence.new(rgb(200, 236, 255), rgb(255, 170, 230)), emission = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, dir = Enum.NormalId.Front },
		{ name = "SPACE.dustTop", cell = "Top", orient = "toward", own = "star_streak", life = NumberRange.new(1.2, 2), speed = NumberRange.new(30, 40),
			spread = 5, size = ns({ { 0, 1 }, { 1, 1 } }), transparency = ns({ { 0, 1 }, { 0.15, 0.3 }, { 0.8, 0.45 }, { 1, 1 } }),
			color = ColorSequence.new(rgb(220, 240, 255), rgb(190, 200, 255)), emission = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, dir = Enum.NormalId.Front },
	},
	HUB = {
		-- Blossom drift: small pink and cream petals tumbling across the plaza on the sea breeze.
		{ name = "HUB.blossom", cell = "Around", flip = "leaf", life = NumberRange.new(5, 8), speed = NumberRange.new(0.8, 2), spread = 40,
			size = ns({ { 0, 0.5 }, { 1, 0.4 } }), transparency = FADE,
			color = ColorSequence.new(rgb(255, 190, 214), rgb(255, 244, 224)), emission = 0.12, accel = Vector3.new(3, -1.5, 1.2),
			rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-130, 130), dir = Enum.NormalId.Bottom },
		-- A soft warm shaft or two off to the side.
		{ name = "HUB.shaft", cell = "Left", own = "god_ray", life = NumberRange.new(6, 8), speed = NumberRange.new(0.2, 0.5), spread = 180,
			size = ns({ { 0, 24 }, { 1, 28 } }), transparency = ns({ { 0, 1 }, { 0.3, 0.88 }, { 0.7, 0.88 }, { 1, 1 } }),
			color = ColorSequence.new(rgb(255, 226, 168), rgb(255, 200, 140)), emission = 0.55,
			orientation = Enum.ParticleOrientation.FacingCameraWorldUp, dir = Enum.NormalId.Bottom },
	},
}

-- ---------------------------------------------------------------- state
local folder: Folder? = nil
local cellParts: { [string]: Part } = {}
local emitters: { [string]: ParticleEmitter } = {} -- by layer name, built lazily per zone
local layerDefs: { [string]: Layer } = {}
local zone: string? = nil
local started = false

local lastCamPos: Vector3? = nil
local camSpeed = 0
local speedFrac = 0
local tickClock = 0
local clock = 0

-- Probe results (refreshed every TICK).
local groundY: number? = nil -- terrain/ground height ahead of the camera
local lavaFrac = 0
local lavaPoint: Vector3? = nil
local seaY: number? = nil
local seaDist: number? = nil
local sprayPoint: Vector3? = nil
local sprayDist: number? = nil
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false

-- Lights (one lava glow light, one hub warm light), each on its own anchored part.
local lavaPart: Part? = nil
local lavaLight: PointLight? = nil
local hubLight: PointLight? = nil
local hubPart: Part? = nil

local function makePart(name: string, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = size
	p.Parent = folder
	return p
end

local function ensureFolder()
	if folder and folder.Parent then
		return
	end
	local f = Instance.new("Folder")
	f.Name = "SkyRallyAtmosphere"
	f.Parent = workspace
	folder = f
	cellParts = {}
	emitters = {}
	lavaPart, lavaLight, hubPart, hubLight = nil, nil, nil, nil
end

local function cellPart(cell: string): Part
	local p = cellParts[cell]
	if p then
		return p
	end
	local def = Rules.CELLS[cell]
	local size = if def then Vector3.new(def.sx, def.sy, def.sz) elseif cell == "Sea" then Vector3.new(120, 0.5, 100) else Vector3.new(40, 1, 40)
	local made = makePart("AtmosCell_" .. cell, size)
	cellParts[cell] = made
	return made
end

local function buildEmitter(L: Layer)
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "Atmos_" .. L.name
	if L.own then
		pe.Texture = ownTexture(L.own)
	elseif L.flip then
		FlipFx.apply(pe, L.flip)
	end
	pe.Enabled = false
	pe.Rate = 0
	pe.Lifetime = L.life
	pe.Speed = L.speed
	pe.SpreadAngle = Vector2.new(L.spread, L.spread)
	pe.Size = L.size
	pe.Transparency = L.transparency
	pe.Color = L.color
	pe.LightEmission = L.emission
	pe.LightInfluence = if L.emission >= 0.45 then 0 else 1
	pe.Acceleration = L.accel or Vector3.zero
	pe.Drag = L.drag or 0
	pe.Rotation = L.rotation or NumberRange.new(0)
	pe.RotSpeed = L.rotSpeed or NumberRange.new(0)
	pe.Orientation = L.orientation or Enum.ParticleOrientation.FacingCamera
	pe.EmissionDirection = L.dir or Enum.NormalId.Front
	pe.ZOffset = L.zOffset or 0
	pe.Shape = Enum.ParticleEmitterShape.Box
	pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	pe.Parent = cellPart(L.cell)
	emitters[L.name] = pe
	layerDefs[L.name] = L
end

local function ensureLights()
	if not lavaPart then
		lavaPart = makePart("AtmosLavaGlow", Vector3.new(1, 1, 1))
		local l = Instance.new("PointLight")
		l.Name = "LavaGlow"
		l.Color = rgb(255, 112, 40)
		l.Range = 38
		l.Brightness = 0
		l.Shadows = false
		l.Enabled = false
		l.Parent = lavaPart
		lavaLight = l
	end
	if not hubPart then
		hubPart = makePart("AtmosHubWarm", Vector3.new(1, 1, 1))
		local l = Instance.new("PointLight")
		l.Name = "HubWarm"
		l.Color = rgb(255, 214, 160)
		l.Range = 46
		l.Brightness = 0
		l.Shadows = false
		l.Enabled = false
		l.Parent = hubPart
		hubLight = l
	end
end

-- ---------------------------------------------------------------- probes
local function refreshFilter()
	local list: { Instance } = {}
	if folder then
		table.insert(list, folder)
	end
	for _, name in { "SkyRallyVfx", "Planes", "Cars" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	local ch = Players.LocalPlayer and Players.LocalPlayer.Character
	if ch then
		table.insert(list, ch)
	end
	rayParams.FilterDescendantsInstances = list
end

-- Straight-down probes from the camera's height at a few spots around and ahead of it: ground height, lava share,
-- the nearest water level and a shore point where water and land meet.
local function probe(cam: Camera)
	refreshFilter()
	local cp = cam.CFrame.Position
	local look = cam.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 0.05 then flat.Unit else Vector3.new(0, 0, -1)
	local right = Vector3.new(-flat.Z, 0, flat.X) -- 90 degrees clockwise of the flat look: the camera's right
	local lavaHits, nearestLava = 0, nil :: Vector3?
	local water: { Vector3 } = {}
	local land: { Vector3 } = {}
	local gy: number? = nil
	local sea: number? = nil
	local seaD: number? = nil
	for _, pr in GROUND_PROBES do
		local o = cp + right * pr[1] + flat * pr[2]
		local hit = workspace:Raycast(o, Vector3.new(0, -260, 0), rayParams)
		if hit then
			if hit.Material == Enum.Material.Water then
				table.insert(water, hit.Position)
				local d = (hit.Position - cp).Magnitude
				if seaD == nil or d < seaD then
					sea, seaD = hit.Position.Y, d
				end
			else
				table.insert(land, hit.Position)
				if Rules.isLava(hit.Material.Name) then
					lavaHits += 1
					if nearestLava == nil or (hit.Position - cp).Magnitude < (nearestLava - cp).Magnitude then
						nearestLava = hit.Position
					end
				end
			end
			if pr[1] == 0 and pr[2] == 40 then
				gy = hit.Position.Y
			end
		end
	end
	groundY = gy
	lavaFrac = lavaHits / #GROUND_PROBES
	lavaPoint = nearestLava
	seaY, seaDist = sea, seaD
	sprayPoint, sprayDist = nil, nil
	if #water > 0 and #land > 0 then
		-- the water sample and the land sample closest to each other: spray at their midpoint, on the water level
		local bestD, bw, bl = math.huge, nil :: Vector3?, nil :: Vector3?
		for _, w in water do
			for _, l in land do
				local d = (w - l).Magnitude
				if d < bestD then
					bestD, bw, bl = d, w, l
				end
			end
		end
		if bw and bl then
			local mid = (bw + bl) / 2
			sprayPoint = Vector3.new(mid.X, bw.Y + 0.6, mid.Z)
			sprayDist = (mid - cp).Magnitude
		end
	end
end

-- ---------------------------------------------------------------- per-tick rates, lights
local function layerGate(name: string): number
	if name == "DINO.shimmer" then
		return lavaFrac
	elseif name == "ISLAND.glints" then
		return Rules.cullGate(seaDist, Rules.GLINT_RANGE)
	elseif name == "ISLAND.spray" then
		-- no spray right under the lens: gate out inside 22 studs
		return if sprayDist and sprayDist > 22 then Rules.cullGate(sprayDist, Rules.SPRAY_RANGE) else 0
	end
	return 1
end

local function applyRates()
	local pscale = Settings.particleScale()
	local low = Settings.lowGraphics()
	for name, pe in emitters do
		local r = if low and Rules.LOW_DROPS[name] then 0 else Rules.rate(name, zone, pscale, layerGate(name))
		if string.sub(name, 1, 10) == "SPACE.dust" then
			r *= Rules.dustRateScale(speedFrac)
		end
		pe.Rate = r
		pe.Enabled = r > 0
	end
	-- Star dust follows the camera speed: longer streaks and a faster stream.
	if zone == "SPACE" then
		local len = Rules.streakLength(speedFrac)
		local spd = Rules.dustSpeed(speedFrac)
		local life = math.clamp(90 / spd, 0.8, 3)
		for name, pe in emitters do
			if string.sub(name, 1, 10) == "SPACE.dust" then
				pe.Size = NumberSequence.new(len)
				pe.Speed = NumberRange.new(spd * 0.85, spd)
				pe.Lifetime = NumberRange.new(life * 0.7, life)
			end
		end
	end
end

local function updateLights(dt: number, cam: Camera)
	local low = Settings.lowGraphics()
	if lavaLight and lavaPart then
		local want = if zone == "DINO" and not low then Rules.lavaTarget(math.floor(lavaFrac * #GROUND_PROBES + 0.5), #GROUND_PROBES, clock) else 0
		local lp = lavaPoint
		if lp then
			lavaPart.Position = lp + Vector3.new(0, 7, 0)
		end
		lavaLight.Brightness = Rules.approach(lavaLight.Brightness, want, 2.5, dt)
		lavaLight.Enabled = lavaLight.Brightness > 0.01
	end
	if hubLight and hubPart then
		local want = if zone == "HUB" and not low then Rules.HUB_LIGHT else 0
		hubPart.Position = cam.CFrame.Position + cam.CFrame.LookVector * 12 + Vector3.new(0, 14, 0)
		hubLight.Brightness = Rules.approach(hubLight.Brightness, want, 0.6, dt)
		hubLight.Enabled = hubLight.Brightness > 0.01
	end
end

-- ---------------------------------------------------------------- cells follow the camera
local function placeCells(cam: Camera)
	local cf = cam.CFrame
	local cp = cf.Position
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 0.05 then flat.Unit else Vector3.new(0, 0, -1)
	local right = Vector3.new(-flat.Z, 0, flat.X)
	local gy = groundY
	for name, pe in emitters do
		local L = layerDefs[name]
		local part = pe.Parent :: Part?
		if not part or not pe.Enabled then
			continue
		end
		local pos: Vector3
		local def = Rules.CELLS[L.cell]
		if L.cell == "Sea" then
			local sy = seaY
			if not sy then
				continue
			end
			pos = Vector3.new(cp.X + flat.X * 45, sy + 0.5, cp.Z + flat.Z * 45)
		elseif L.cell == "Spray" then
			local sp = sprayPoint
			if not sp then
				continue
			end
			pos = sp
		else
			pos = cp + right * def.right + flat * def.look + Vector3.new(0, def.up, 0)
			-- ground layers ride the actual ground (lava level, road snow) instead of a camera-relative height
			if L.cell == "Low" and gy and gy < cp.Y and cp.Y - gy < 70 then
				pos = Vector3.new(pos.X, gy + 1.5, pos.Z)
			end
		end
		local aim: Vector3
		if L.orient == "toward" then
			aim = Vector3.new(cp.X, pos.Y, cp.Z)
		elseif L.orient == "wind" then
			aim = pos + WIND
		else
			aim = pos + flat
		end
		if (aim - pos).Magnitude < 0.01 then
			aim = pos + flat
		end
		part.CFrame = CFrame.lookAt(pos, aim)
	end
end

-- ---------------------------------------------------------------- zone + frame
local function setZone(z: string?)
	zone = z
	ensureFolder()
	local defs = if z then LAYERS[z] else nil
	if defs then
		for _, L in defs do
			if not emitters[L.name] then
				buildEmitter(L)
			end
		end
	end
	if z == "DINO" or z == "HUB" then
		ensureLights()
	end
	tickClock = TICK -- refresh rates on the next frame
end

local function step(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	clock += dt
	local cp = cam.CFrame.Position
	if lastCamPos then
		camSpeed = Rules.smoothSpeed(camSpeed, (cp - lastCamPos).Magnitude, dt)
	end
	lastCamPos = cp
	speedFrac = Rules.speedFrac(camSpeed)
	tickClock += dt
	if tickClock >= TICK then
		tickClock = 0
		probe(cam)
		applyRates()
	end
	placeCells(cam)
	updateLights(dt, cam)
end

function AtmosphereFx.init()
	if started then
		return
	end
	started = true
	local z = RaceAttr.mine("ActiveZone")
	setZone(if type(z) == "string" then z else "HUB")
	RaceAttr.changed("ActiveZone", function()
		local nz = RaceAttr.mine("ActiveZone")
		setZone(if type(nz) == "string" then nz else nil)
	end)
	Settings.onChanged(function(key: string)
		if key == "lowGraphics" or key == "particleScale" then -- particleScale: the frame governor's session cap
			tickClock = TICK
		end
	end)
	RunService.RenderStepped:Connect(Prof.wrap("SR_AtmosphereFx", step))
end

return AtmosphereFx
