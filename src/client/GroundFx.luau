--!strict
-- Car ground effects (lane vfx-car-ground). Everything here is ParticleEmitters and Trails (no solid meshes), built once
-- per car and only switched afterwards: the instance count never grows while driving.
--   mini-turbo   charge visuals per tier (inner glow ember at the rear tyres, electric arcs on the top tier) and a
--                dedicated release at the rear wheels: tier-coloured shockwave ring, forward-biased sparks, flame kick;
--                tierPop is the small ring + star + streak flash at the rear wheels the moment the tier rises.
--   tyre marks   flat dark Trails at the rear tyres while the body slides hard on a dry surface (4 s lifetime, capped
--                length), colour from the surface, nothing on grass or in water. Fade out through the Trail's own alpha.
--   water        rear-wheel spray + droplets and a flat foam V-wake Trail while wading; snow/ice: rear-wheel powder.
--   contacts     pooled spark sprays for wall scrapes and car-to-car bumps (+ tiny camera trauma for the local player).
-- Phone budget: every rate and burst count goes through Settings.particleScale(); each car is distance-culled (other
-- cars only within GroundFxRules.CULL_REMOTE and only the nearest MAX_REMOTE_RIGS); surfaces are probed with one ray
-- per car every 0.14 s (the sandKick/meadowSkim cadence of Vfx). Rules and tuning live in shared/GroundFxRules.
-- Camera rule: nothing here sits in front of the chase camera; plumes are small, low, behind the tyres and short-lived,
-- the release ring is <= 8 studs for 0.38 s, and sparks are thin streaks that live ~0.25 s.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CarConfig = require(Shared:WaitForChild("CarConfig"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local Rules = require(Shared:WaitForChild("GroundFxRules"))
local GroundTexAssets = require(Shared:WaitForChild("GroundTexAssets"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local GroundFx = {}

export type Info = {
	speed: number, -- signed
	grounded: boolean,
	drifting: boolean,
	slipDeg: number, -- body yaw vs travel direction, degrees
	wet: boolean?, -- local car: CarController's own wading flag (sea or battle tide)
	waterY: number?, -- local car: the water surface when wet
}

type Fx = {
	hull: BasePart,
	isLocal: boolean,
	skid: { Trail },
	skidA: { Attachment },
	skidKey: string,
	wake: Trail,
	wakeA: { Attachment },
	wakeOn: boolean,
	spray: { ParticleEmitter },
	droplets: { ParticleEmitter },
	powder: { ParticleEmitter },
	sprayKey: string,
	ember: { ParticleEmitter },
	arcs: { ParticleEmitter },
	chargeKey: string,
	ring: { ParticleEmitter }, -- local car only (release)
	sparks: { ParticleEmitter },
	popStars: { ParticleEmitter }, -- local car only (tier-up pop)
	popSparks: { ParticleEmitter },
	flame: ParticleEmitter?,
	rayClock: number,
	wet: boolean,
	waterY: number?,
	material: string,
	idle: boolean,
}

local fxByHull: { [BasePart]: Fx } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false
rayParams.RespectCanCollide = false

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function assetTexture(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

-- Own textures when uploaded (id > 0), else the old soft trail sprite (tinted white-with-alpha, so it still reads).
local function groundTexture(name: string): string
	local id = (GroundTexAssets :: any)[name]
	if type(id) == "number" and id > 0 then
		return "rbxassetid://" .. tostring(id)
	end
	return assetTexture("trail_soft")
end

local function seq(...: number): NumberSequence
	local pts = { ... }
	local kps = {}
	for i = 1, #pts, 2 do
		table.insert(kps, NumberSequenceKeypoint.new(pts[i], pts[i + 1]))
	end
	return NumberSequence.new(kps)
end

local function newAttachment(hull: BasePart, name: string, pos: Vector3): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.Position = pos
	a.Parent = hull
	return a
end

local function newEmitter(att: Attachment, name: string): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Name = name
	pe.Rate = 0
	pe.Enabled = false
	pe.LightInfluence = 0
	pe.Parent = att
	return pe
end

-- ---------------------------------------------------------------- emitter recipes
local function makeSpray(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxSpray")
	local flip = FlipFx.apply(pe, "water_splash_8x8")
	pe.Lifetime = NumberRange.new(0.55, 0.7) -- OneShot flipbook: the lifetime is the playback time
	pe.Speed = NumberRange.new(8, 16)
	pe.SpreadAngle = Vector2.new(28, 28)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Size = if flip then seq(0, 1.6, 1, 3.2) else seq(0, 0.8, 1, 2.2)
	pe.Transparency = seq(0, 0.3, 0.6, 0.55, 1, 1)
	pe.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 232, 255))
	pe.LightEmission = 0.25
	pe.Acceleration = Vector3.new(0, -28, 0)
	pe.Orientation = if flip then Enum.ParticleOrientation.FacingCameraWorldUp else Enum.ParticleOrientation.FacingCamera
	pe.Rotation = if flip then NumberRange.new(0) else NumberRange.new(0, 360)
	return pe
end

local function makeDroplets(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxDroplets")
	pe.Texture = assetTexture("water_droplet")
	pe.Lifetime = NumberRange.new(0.4, 0.7)
	pe.Speed = NumberRange.new(14, 28)
	pe.SpreadAngle = Vector2.new(38, 38)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Size = seq(0, 0.5, 1, 0.12)
	pe.Transparency = seq(0, 0.1, 1, 1)
	pe.Color = ColorSequence.new(Color3.fromRGB(214, 242, 255))
	pe.LightEmission = 0.35
	pe.Acceleration = Vector3.new(0, -70, 0)
	return pe
end

local function makePowder(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxPowder")
	local flip = FlipFx.apply(pe, "snow_burst_4x4")
	pe.Lifetime = NumberRange.new(0.6, 0.9)
	pe.Speed = NumberRange.new(5, 12)
	pe.SpreadAngle = Vector2.new(34, 34)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Size = if flip then seq(0, 1.8, 1, 3.8) else seq(0, 1.0, 1, 3.0)
	pe.Transparency = seq(0, 0.2, 0.6, 0.5, 1, 1)
	pe.Color = ColorSequence.new(Color3.fromRGB(248, 252, 255))
	pe.Acceleration = Vector3.new(0, -5, 0)
	pe.Drag = 2
	pe.Orientation = if flip then Enum.ParticleOrientation.FacingCameraWorldUp else Enum.ParticleOrientation.FacingCamera
	pe.Rotation = if flip then NumberRange.new(0) else NumberRange.new(0, 360)
	return pe
end

local function makeEmber(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxEmber")
	pe.Texture = assetTexture("glow_soft")
	pe.Lifetime = NumberRange.new(0.22, 0.34)
	pe.Speed = NumberRange.new(1, 4)
	pe.SpreadAngle = Vector2.new(60, 60)
	pe.EmissionDirection = Enum.NormalId.Back
	pe.Size = seq(0, 1.2, 0.35, 1.6, 1, 0)
	pe.Transparency = seq(0, 0.15, 1, 1)
	pe.LightEmission = 0.8 -- v20: full additive washed every tier to white on sunlit sand/grass; keep the tier hue
	return pe
end

local function makeArcs(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxArcs")
	FlipFx.apply(pe, "electric_arc_4x4")
	pe.Lifetime = NumberRange.new(0.2, 0.3)
	pe.Speed = NumberRange.new(0, 1)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = seq(0, 2.4, 1, 2.0)
	pe.Transparency = seq(0, 0.05, 0.7, 0.2, 1, 1)
	pe.LightEmission = 1
	pe.Rotation = NumberRange.new(0, 360)
	return pe
end

local function makeRing(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxRing")
	FlipFx.apply(pe, "shockwave_8x8")
	pe.Lifetime = NumberRange.new(0.38) -- one-shot playback time
	pe.Speed = NumberRange.new(0)
	pe.Size = seq(0, 1, 1, 5)
	pe.Transparency = seq(0, 0.25, 0.7, 0.5, 1, 1)
	pe.LightEmission = 1
	pe.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
	pe.Rotation = NumberRange.new(0)
	return pe
end

local function makeSparks(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxSparks")
	pe.Texture = assetTexture("spark_streak")
	pe.Lifetime = NumberRange.new(0.18, 0.3)
	pe.Speed = NumberRange.new(40, 80)
	pe.SpreadAngle = Vector2.new(24, 24)
	pe.EmissionDirection = Enum.NormalId.Front -- hull -Z: forward
	pe.Size = seq(0, 1.3, 1, 0)
	pe.Transparency = seq(0, 0, 1, 1)
	pe.LightEmission = 1
	pe.Orientation = Enum.ParticleOrientation.VelocityParallel
	pe.Acceleration = Vector3.new(0, -40, 0)
	return pe
end

-- Tier-up pop layers (local car): a tier-coloured twinkle star and radial spark streaks, one-shot at each rear wheel.
local function makePopStar(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxPopStar")
	FlipFx.apply(pe, "sparkle_star_4x4")
	pe.Lifetime = NumberRange.new(0.26, 0.32)
	pe.Speed = NumberRange.new(2, 6)
	pe.SpreadAngle = Vector2.new(60, 60)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Size = seq(0, 0, 0.35, 2.2, 1, 0)
	pe.Transparency = seq(0, 0.05, 1, 0.8)
	pe.LightEmission = 1
	pe.Rotation = NumberRange.new(-20, 20)
	pe.ZOffset = -1 -- behind the hull from the chase camera
	return pe
end

local function makePopSparks(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxPopSparks")
	pe.Texture = assetTexture("spark_streak")
	pe.Lifetime = NumberRange.new(0.16, 0.22)
	pe.Speed = NumberRange.new(25, 45)
	pe.SpreadAngle = Vector2.new(70, 70)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Size = seq(0, 0.7, 1, 0)
	pe.Transparency = seq(0, 0, 1, 1)
	pe.LightEmission = 1
	pe.Orientation = Enum.ParticleOrientation.VelocityParallel
	pe.Acceleration = Vector3.new(0, -50, 0)
	return pe
end

local function makeFlame(att: Attachment): ParticleEmitter
	local pe = newEmitter(att, "GFxFlameKick")
	local flip = FlipFx.apply(pe, "fire_loop_8x8")
	pe.Lifetime = NumberRange.new(0.2, 0.3)
	pe.Speed = NumberRange.new(4, 9)
	pe.SpreadAngle = Vector2.new(10, 10)
	pe.EmissionDirection = Enum.NormalId.Back
	pe.Size = seq(0, 1.2, 0.3, 2.2, 1, 0.3)
	pe.Transparency = seq(0, 0.1, 0.7, 0.35, 1, 1)
	pe.LightEmission = 1
	pe.Rotation = if flip then NumberRange.new(0) else NumberRange.new(0, 360)
	return pe
end

local function makeTrail(a0: Attachment, a1: Attachment, name: string): Trail
	local t = Instance.new("Trail")
	t.Name = name
	t.Attachment0 = a0
	t.Attachment1 = a1
	t.FaceCamera = false -- lies flat on the ground / water, the ribbon follows the attachments' span and the path
	t.LightInfluence = 1
	t.LightEmission = 0
	t.Enabled = false
	t.Parent = a0.Parent
	return t
end

-- ---------------------------------------------------------------- per-car build
local function build(hull: BasePart, isLocal: boolean): Fx
	local rearY = CarConfig.WHEELS[3][2] - CarConfig.WHEEL_RADIUS
	local wheelAtt: { Attachment } = {}
	for k = 1, 2 do
		local w = CarConfig.WHEELS[2 + k] -- RL, RR
		wheelAtt[k] = newAttachment(hull, if k == 1 then "GFx_RL" else "GFx_RR", Vector3.new(w[1], rearY + 0.35, w[3] + 0.6))
	end
	local skid: { Trail } = {}
	local skidA: { Attachment } = {}
	local skidTex = groundTexture("skid_strip")
	for k = 1, 2 do
		local w = CarConfig.WHEELS[2 + k]
		local y = rearY + 0.12
		local a0 = newAttachment(hull, "GFx_SkidA" .. k, Vector3.new(w[1] - 0.5, y, w[3]))
		local a1 = newAttachment(hull, "GFx_SkidB" .. k, Vector3.new(w[1] + 0.5, y, w[3]))
		local t = makeTrail(a0, a1, "GFxSkid")
		t.Lifetime = Rules.SKID_LIFETIME
		t.MinLength = 0.8
		t.MaxLength = if isLocal then 320 else 140
		t.Texture = skidTex
		t.TextureMode = Enum.TextureMode.Wrap
		t.TextureLength = 4
		t.Color = ColorSequence.new(Color3.fromRGB(30, 29, 32))
		-- Transparency runs along the trail's age: solid black near the tyre, easing out over the last third.
		t.Transparency = seq(0, 0.25, 0.55, 0.45, 1, 1)
		t.WidthScale = NumberSequence.new(1)
		skid[k] = t
		skidA[k] = a0
	end
	-- V-wake: one foam ribbon from the bow whose width scale opens up along its length, so it reads as a wedge.
	local nose = -CarConfig.HALF_LENGTH + 1.5
	local wa0 = newAttachment(hull, "GFx_WakeA", Vector3.new(-1.1, rearY, nose))
	local wa1 = newAttachment(hull, "GFx_WakeB", Vector3.new(1.1, rearY, nose))
	local wake = makeTrail(wa0, wa1, "GFxWake")
	wake.Lifetime = 1.3
	wake.MinLength = 0.6
	wake.MaxLength = 90
	wake.Texture = groundTexture("wake_foam")
	wake.TextureMode = Enum.TextureMode.Wrap
	wake.TextureLength = 6
	wake.Color = ColorSequence.new(Color3.fromRGB(236, 250, 255))
	wake.LightEmission = 0.35
	wake.Transparency = seq(0, 0.3, 0.4, 0.55, 1, 1)
	wake.WidthScale = seq(0, 1, 0.5, 3, 1, 5.5)

	local spray: { ParticleEmitter }, droplets: { ParticleEmitter }, powder: { ParticleEmitter } = {}, {}, {}
	local ember: { ParticleEmitter }, arcs: { ParticleEmitter } = {}, {}
	for k = 1, 2 do
		spray[k] = makeSpray(wheelAtt[k])
		droplets[k] = makeDroplets(wheelAtt[k])
		powder[k] = makePowder(wheelAtt[k])
		ember[k] = makeEmber(wheelAtt[k])
		arcs[k] = makeArcs(wheelAtt[k])
	end
	local ring: { ParticleEmitter } = {}
	local sparks: { ParticleEmitter } = {}
	local popStars: { ParticleEmitter }, popSparks: { ParticleEmitter } = {}, {}
	local flame: ParticleEmitter? = nil
	if isLocal then
		for k = 1, 2 do
			ring[k] = makeRing(wheelAtt[k])
			sparks[k] = makeSparks(wheelAtt[k])
			popStars[k] = makePopStar(wheelAtt[k])
			popSparks[k] = makePopSparks(wheelAtt[k])
		end
		local tail = newAttachment(hull, "GFx_Tail", Vector3.new(0, 0.6, CarConfig.HALF_LENGTH + 0.3))
		flame = makeFlame(tail)
	end
	return {
		hull = hull,
		isLocal = isLocal,
		skid = skid,
		skidA = skidA,
		skidKey = "",
		wake = wake,
		wakeA = { wa0, wa1 },
		wakeOn = false,
		spray = spray,
		droplets = droplets,
		powder = powder,
		sprayKey = "",
		ember = ember,
		arcs = arcs,
		chargeKey = "",
		ring = ring,
		sparks = sparks,
		popStars = popStars,
		popSparks = popSparks,
		flame = flame,
		rayClock = math.random() * 0.14,
		wet = false,
		waterY = nil,
		material = "",
		idle = false,
	}
end

local function getFx(hull: BasePart, isLocal: boolean): Fx
	local fx = fxByHull[hull]
	if not fx then
		fx = build(hull, isLocal)
		fxByHull[hull] = fx
	end
	return fx
end

-- All continuous layers off (out of range, or the car is gone): rates to 0 so nothing keeps emitting unseen.
local function switchOff(fx: Fx)
	for _, t in fx.skid do
		t.Enabled = false
	end
	fx.wake.Enabled = false
	fx.wakeOn = false
	for _, list in { fx.spray, fx.droplets, fx.powder, fx.ember, fx.arcs } do
		for _, pe in list do
			pe.Enabled = false
			pe.Rate = 0
		end
	end
	fx.skidKey, fx.sprayKey, fx.chargeKey = "", "", ""
	fx.idle = true
end

-- ---------------------------------------------------------------- surface probe (one ray per car per 0.14 s)
local function probe(fx: Fx, info: Info)
	local hull = fx.hull
	local planes = workspace:FindFirstChild("Planes")
	rayParams.FilterDescendantsInstances = if planes then { planes } else {}
	local cf = hull.CFrame
	local origin = hull.Position + Vector3.yAxis * 6
	local hit = workspace:Raycast(origin, Vector3.new(0, -(6 + CarConfig.RIDE_HEIGHT + 5), 0), rayParams)
	local wet = false
	local waterY: number? = nil
	local material = ""
	if hit then
		if hit.Material == Enum.Material.Water then
			-- Wading only when the bed is at or under the surface (a bridge over the sea is not wading).
			if hit.Position.Y >= cf.Position.Y - CarConfig.RIDE_HEIGHT - 0.2 then
				wet = true
				waterY = hit.Position.Y
			end
		else
			material = hit.Material.Name
		end
	end
	if info.wet ~= nil then -- the local car knows better (the battle tide part is not queryable)
		wet = info.wet
		waterY = info.waterY or waterY
	end
	fx.wet, fx.waterY, fx.material = wet, waterY, material
end

-- ---------------------------------------------------------------- per-car update
local function applyFx(fx: Fx, info: Info, dist: number, scale: number)
	local inRange = Rules.inRange(dist, fx.isLocal)
	local speed = info.speed
	local strength = if inRange and info.grounded then Rules.sprayStrength(speed, CarConfig.TOP_SPEED) else 0
	local kind = Rules.surfaceKind(fx.material, fx.wet)

	-- Spray / powder: written only when the surface kind, speed bucket or particle scale changes.
	local q = math.floor(strength * 4 + 0.5)
	local sKey = kind .. "|" .. q .. "|" .. scale
	if sKey ~= fx.sprayKey then
		fx.sprayKey = sKey
		local f = q / 4
		for k = 1, 2 do
			local sp, dr, po = fx.spray[k], fx.droplets[k], fx.powder[k]
			sp.Rate = if kind == "water" then Rules.rate(18 * f, scale) else 0
			dr.Rate = if kind == "water" then Rules.rate(26 * f, scale) else 0
			po.Rate = if kind == "snow" then Rules.rate(14 * f, scale) else 0
			sp.Enabled, dr.Enabled, po.Enabled = sp.Rate > 0, dr.Rate > 0, po.Rate > 0
		end
	end

	-- V-wake (flat foam ribbon at the water line): needs no particle scale, one Trail per car.
	local wakeOn = kind == "water" and strength > 0 and fx.waterY ~= nil
	if wakeOn ~= fx.wakeOn then
		fx.wakeOn = wakeOn
		fx.wake.Enabled = wakeOn
	end
	if wakeOn then
		local local0 = fx.hull.CFrame:PointToObjectSpace(Vector3.new(fx.hull.Position.X, (fx.waterY :: number) + 0.12, fx.hull.Position.Z))
		for _, a in fx.wakeA do
			a.Position = Vector3.new(a.Position.X, local0.Y, a.Position.Z)
		end
	end

	-- Tyre marks.
	local color = Rules.markColor(fx.material)
	local skidOn = inRange and color ~= nil and Rules.skidActive(info.grounded, fx.wet, speed, info.drifting, info.slipDeg)
	local kKey = if skidOn then fx.material else "off"
	if kKey ~= fx.skidKey then
		fx.skidKey = kKey
		for _, t in fx.skid do
			t.Enabled = skidOn
			if skidOn and color then
				t.Color = ColorSequence.new(rgb(color))
			end
		end
	end
end

-- ---------------------------------------------------------------- charge + release
-- Called by CarController.setDriftEffects (edge-only). level 0 = not charged; color = the tier colour.
function GroundFx.setCharge(hull: BasePart, isLocal: boolean, level: number, sliding: boolean, color: Color3)
	local fx = fxByHull[hull]
	if not fx then
		if level <= 0 or not sliding then
			return
		end
		local cam = workspace.CurrentCamera
		if cam and not Rules.inRange((cam.CFrame.Position - hull.Position).Magnitude, isLocal) then
			return
		end
		fx = getFx(hull, isLocal)
	end
	local scale = Settings.particleScale()
	local on = sliding and level > 0
	local key = if on then level .. "|" .. tostring(color) .. "|" .. scale else "off"
	if key == fx.chargeKey then
		return
	end
	fx.chargeKey = key
	if not on then
		for k = 1, 2 do
			fx.ember[k].Enabled, fx.ember[k].Rate = false, 0
			fx.arcs[k].Enabled, fx.arcs[k].Rate = false, 0
		end
		return
	end
	local tier = Rules.tier(level)
	if level == 1 then
		color = rgb(Rules.TIER1_FX_RGB) -- v21: the sky blue vanished on bright sand
	end
	local glow = ColorSequence.new(Color3.new(1, 1, 1):Lerp(color, if level == 1 then 0.96 else 0.85), color)
	for k = 1, 2 do
		local e = fx.ember[k]
		e.Color = glow
		-- Tier 1: a hard-cored sprite (pickup_glint: disc and ring) that blends instead of adding, so the deep blue keeps
		-- an outline on sand; tiers 2-3 keep the soft glow with a capped additive weight.
		e.Texture = assetTexture(if level == 1 then "pickup_glint" else "glow_soft")
		e.LightEmission = tier.emberLight
		e.Transparency = if level == 1 then seq(0, 0.05, 0.7, 0.25, 1, 1) else seq(0, 0.15, 1, 1)
		e.Size = seq(0, 0.7 * tier.ember, 0.35, tier.ember, 1, 0)
		e.Rate = Rules.rate(tier.emberRate, scale)
		e.Enabled = e.Rate > 0
		local a = fx.arcs[k]
		a.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
		a.Rate = if tier.arcs then Rules.rate(9, scale) else 0
		a.Enabled = a.Rate > 0
	end
end

-- The mini-turbo release for the local car (replaces the plane boost burst): a tier-coloured shockwave ring at each
-- rear wheel, forward-biased sparks and a short flame kick. Counts scale with Settings.particleScale().
function GroundFx.release(hull: BasePart, level: number, color: Color3)
	if level <= 0 then
		return
	end
	local fx = getFx(hull, true)
	if #fx.ring == 0 then
		return
	end
	local tier = Rules.tier(level)
	local scale = Settings.particleScale()
	if level == 1 then
		color = rgb(Rules.TIER1_FX_RGB)
	end
	local tint = ColorSequence.new(Color3.new(1, 1, 1):Lerp(color, 0.8), color) -- v20: was 0.25 white-ward: every tier read as the same white ring
	for k = 1, 2 do
		local r = fx.ring[k]
		r.Color = tint
		r.Size = seq(0, 1.2, 1, tier.ringSize)
		if scale > 0 then
			r:Emit(1)
		end
		local s = fx.sparks[k]
		s.Color = tint
		s:Emit(Rules.scaled(tier.sparks / 2, scale))
		-- v20: the fire flipbook ignores the tint, so the tier's own colour rides a soft glow burst at each rear wheel
		local e = fx.ember[k]
		e.Color = tint
		e.Texture = assetTexture(if level == 1 then "pickup_glint" else "glow_soft")
		e.LightEmission = tier.emberLight
		e.Size = seq(0, tier.ember * 0.9, 0.4, math.min(tier.ember * 1.5, tier.emberMax), 1, 0) -- v21: the top tier no longer swells to 6 studs over the hull
		e:Emit(Rules.scaled(3 + 2 * level, scale))
	end
	local flame = fx.flame
	if flame then
		flame.Color = ColorSequence.new(Color3.new(1, 1, 1):Lerp(color, 0.75), color)
		flame.Size = seq(0, tier.flameSize * 0.5, 0.3, tier.flameSize, 1, 0.3)
		flame:Emit(Rules.scaled(tier.flames, scale))
	end
end

-- The tier-up pop for the local car (CarController, the frame the drift charge crosses into tier `level`): a small
-- tier-coloured ring, a twinkle star and radial streaks at each rear wheel, pre-built emitters only. Budget: GroundFxRules
-- POP_MAX_TOTAL particles over both wheels; the star layer is skipped on a thin particle scale (phone).
function GroundFx.tierPop(hull: BasePart, level: number, color: Color3)
	if level <= 0 then
		return
	end
	local scale = Settings.particleScale()
	if scale <= 0 then
		return
	end
	local fx = getFx(hull, true)
	if #fx.popSparks == 0 then
		return
	end
	local pop = Rules.tierPop(level, scale)
	if level == 1 then
		color = rgb(Rules.TIER1_FX_RGB)
	end
	local tint = ColorSequence.new(Color3.new(1, 1, 1):Lerp(color, 0.7), color) -- v21: 0.25 read as a white flicker on sand
	for k = 1, 2 do
		local r = fx.ring[k]
		r.Color = tint
		r.Size = seq(0, 0.8, 1, pop.ring)
		r:Emit(1)
		if pop.stars > 0 then
			local st = fx.popStars[k]
			st.Color = tint
			st:Emit(pop.stars)
		end
		local sp = fx.popSparks[k]
		sp.Color = tint
		sp:Emit(pop.streaks)
	end
end

-- ---------------------------------------------------------------- contact sparks (pooled: one attachment + emitter per kind)
local sprayPool: { [string]: { att: Attachment, pe: ParticleEmitter, flash: ParticleEmitter, lastFlash: number } } = {}

local function sprayFor(kind: string): { att: Attachment, pe: ParticleEmitter, flash: ParticleEmitter, lastFlash: number }
	local p = sprayPool[kind]
	if p then
		return p
	end
	local att = Instance.new("Attachment")
	att.Name = "GFxContact_" .. kind
	att.Parent = workspace.Terrain
	local pe = newEmitter(att, "GFxContactSparks")
	pe.Texture = assetTexture("spark_streak")
	-- v21: the 0.5-stud, fully additive streaks were invisible behind the wheel on bright sand (wall scrape, car bump):
	-- longer-lived, twice the size, partly blended so the orange / blue keeps its hue, and a short flash at the contact.
	pe.Lifetime = NumberRange.new(0.18, 0.36)
	pe.Speed = NumberRange.new(18, 40)
	pe.SpreadAngle = Vector2.new(50, 50)
	pe.EmissionDirection = Enum.NormalId.Front
	pe.Size = seq(0, 1.15, 0.6, 0.75, 1, 0)
	pe.Transparency = seq(0, 0, 1, 1)
	pe.LightEmission = 0.55
	pe.Orientation = Enum.ParticleOrientation.VelocityParallel
	pe.Acceleration = Vector3.new(0, -45, 0)
	local flash = newEmitter(att, "GFxContactFlash")
	flash.Texture = assetTexture("glow_soft")
	flash.Lifetime = NumberRange.new(0.1, 0.14)
	flash.Speed = NumberRange.new(0)
	flash.Size = seq(0, 3.4, 1, 1)
	flash.Transparency = seq(0, 0.2, 1, 1)
	flash.LightEmission = 0.5
	flash.ZOffset = -0.5
	if kind == "car" then
		-- v21 (vfx critic 3): warm white to yellow, bigger and a bigger flash (the cold blue 5 px slashes read as glitch lines)
		pe.Color = ColorSequence.new(Color3.fromRGB(255, 255, 240), Color3.fromRGB(255, 190, 50))
		pe.Size = seq(0, 1.7, 0.6, 1.1, 1, 0)
		pe.Lifetime = NumberRange.new(0.22, 0.42)
		flash.Size = seq(0, 6.5, 1, 2)
		flash.Color = ColorSequence.new(Color3.fromRGB(255, 244, 200), Color3.fromRGB(255, 170, 40))
	else
		pe.Color = ColorSequence.new(Color3.fromRGB(255, 236, 150), Color3.fromRGB(255, 110, 20))
		flash.Color = ColorSequence.new(Color3.fromRGB(255, 226, 140), Color3.fromRGB(255, 130, 40))
	end
	local made = { att = att, pe = pe, flash = flash, lastFlash = 0 }
	sprayPool[kind] = made
	return made
end

-- kind "wall" | "car"; normal points away from the contact surface (sparks spray along it).
function GroundFx.sparkSpray(pos: Vector3, normal: Vector3, count: number, kind: string)
	local scale = Settings.particleScale()
	if scale <= 0 then
		return
	end
	local cam = workspace.CurrentCamera
	if cam and (cam.CFrame.Position - pos).Magnitude > 200 then
		return
	end
	local p = sprayFor(kind)
	p.att.WorldCFrame = CFrame.lookAt(pos, pos + normal)
	p.pe:Emit(Rules.scaled(if kind == "car" then math.floor(count * 1.6) else count, scale))
	local now = os.clock()
	if now - p.lastFlash > 0.12 then -- a scrape calls this every frame: one flash per 0.12 s, not a strobe
		p.lastFlash = now
		p.flash:Emit(1)
	end
end

-- ---------------------------------------------------------------- the step
-- Other cars: the Planes folder scanned every 0.5 s, ranked by camera distance every 0.25 s.
type Other = { model: Model, hull: BasePart, lastDist: number, cooldown: number }
local others: { [Model]: Other } = {}
local scanClock = 0
local rankClock = 0
local allowedRemote: { [BasePart]: boolean } = {}

local function scanOthers(self: Model?)
	local folder = workspace:FindFirstChild("Planes")
	local seen: { [Model]: boolean } = {}
	if folder then
		for _, m in folder:GetChildren() do
			if m:IsA("Model") and m ~= self and m:GetAttribute("VehicleType") == "car" then
				local hull = m:FindFirstChild("Hull")
				if hull and hull:IsA("BasePart") then
					seen[m] = true
					if not others[m] then
						others[m] = { model = m, hull = hull, lastDist = math.huge, cooldown = 0 }
					end
				end
			end
		end
	end
	for m in others do
		if not seen[m] then
			others[m] = nil
		end
	end
end

local function rankOthers(camPos: Vector3)
	local list: { { hull: BasePart, d: number } } = {}
	for _, o in others do
		table.insert(list, { hull = o.hull, d = (o.hull.Position - camPos).Magnitude })
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	allowedRemote = {}
	for i = 1, math.min(#list, Rules.MAX_REMOTE_RIGS) do
		if Rules.inRange(list[i].d, false) then
			allowedRemote[list[i].hull] = true
		end
	end
end

local function remoteInfo(model: Model): Info
	local s = model:GetAttribute("Speed")
	local drifting = model:GetAttribute("Drifting") == true
	return {
		speed = if type(s) == "number" then s else 0,
		grounded = model:GetAttribute("Airborne") ~= true,
		drifting = drifting,
		slipDeg = if drifting then 18 else 0,
		wet = nil,
		waterY = nil,
	}
end

-- Car-to-car bumps: the other hull overlaps the local car's footprint. Sparks at the midpoint, a small shake, a scrape.
local function stepBumps(dt: number, localHull: BasePart, localSpeed: number, onTrauma: (number) -> ())
	local lcf = localHull.CFrame
	local now = os.clock()
	for _, o in others do
		if o.hull == localHull then
			continue
		end
		local d = (o.hull.Position - lcf.Position).Magnitude
		local closing = (o.lastDist - d) / math.max(dt, 1 / 240)
		o.lastDist = d
		if d < 14 and now >= o.cooldown then
			local rel = lcf:PointToObjectSpace(o.hull.Position)
			if Rules.overlaps(rel.X, rel.Y, rel.Z, CarConfig.HALF_WIDTH, CarConfig.HALF_LENGTH) then
				local os_ = o.model:GetAttribute("Speed")
				local sev = Rules.bumpSeverity(closing, localSpeed - (if type(os_) == "number" then os_ else 0))
				local mid = (lcf.Position + o.hull.Position) / 2 + lcf.UpVector * 0.4
				local away = Vector3.new(lcf.Position.X - o.hull.Position.X, 0, lcf.Position.Z - o.hull.Position.Z)
				local n = if away.Magnitude > 0.05 then away.Unit else lcf.RightVector
				GroundFx.sparkSpray(mid, n + Vector3.yAxis * 0.5, Rules.bumpSparks(sev), "car")
				onTrauma(Rules.bumpTrauma(sev))
				Sfx.play("wall_scrape", 1.1 + math.random() * 0.2, 0.2 + 0.3 * sev)
				o.cooldown = now + Rules.BUMP_COOLDOWN
			end
		end
	end
end

-- Once per frame from CarController.stepCar (after the car moved). localHull nil = no local car yet.
function GroundFx.step(dt: number, localHull: BasePart?, localInfo: Info?, onTrauma: (number) -> ())
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local scale = Settings.particleScale()
	scanClock -= dt
	if scanClock <= 0 then
		scanClock = 0.5
		local selfModel = if localHull and localHull.Parent and localHull.Parent:IsA("Model") then localHull.Parent else nil
		scanOthers(selfModel :: Model?)
		for hull, fx in fxByHull do
			if not hull.Parent then
				fxByHull[hull] = nil
			end
		end
	end
	rankClock -= dt
	if rankClock <= 0 then
		rankClock = 0.25
		rankOthers(camPos)
	end

	if localHull and localInfo and localHull.Parent then
		local fx = fxByHull[localHull]
		-- A local car that never drifted, waded or slid has no instances yet: build on the first need only.
		local needs = fx ~= nil or localInfo.wet == true or localInfo.drifting or math.abs(localInfo.slipDeg) >= Rules.SKID_SLIP_DEG
			or Rules.sprayStrength(localInfo.speed, CarConfig.TOP_SPEED) > 0
		if needs then
			fx = getFx(localHull, true)
			fx.idle = false
			fx.rayClock -= dt
			if fx.rayClock <= 0 then
				fx.rayClock = 0.14
				probe(fx, localInfo)
			end
			applyFx(fx, localInfo, (camPos - localHull.Position).Magnitude, scale)
		end
		stepBumps(dt, localHull, localInfo.speed, onTrauma)
	end

	for model, o in others do
		local hull = o.hull
		if allowedRemote[hull] then
			local info = remoteInfo(model)
			-- Cars that neither move nor have any FX yet cost nothing.
			local fx = fxByHull[hull]
			if fx or math.abs(info.speed) > Rules.SPRAY_MIN_SPEED then
				local rf = getFx(hull, false)
				rf.idle = false
				rf.rayClock -= dt
				if rf.rayClock <= 0 then
					rf.rayClock = 0.14
					probe(rf, info)
				end
				applyFx(rf, info, (camPos - hull.Position).Magnitude, scale)
			end
		else
			local fx = fxByHull[hull]
			if fx and not fx.idle then
				switchOff(fx)
			end
		end
	end
end

return GroundFx
