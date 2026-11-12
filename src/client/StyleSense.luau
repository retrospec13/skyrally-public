--!strict
-- Near-miss sparks, the LAVA SKIM ember wake and the zone-turbo burst (REMARKABLE Batch 2 items 15 and 16). Client
-- only and cosmetic: no speed, no item, nothing the server sees. Both controllers call StyleSense.step once per frame
-- with their vehicle's frame; it casts
--   two side rays (left, right) at StyleRules.NEAR_HZ while the vehicle is at NEAR_SPEED_FRAC of its top speed:
--     a collidable wall coming within the near band (a hand's width for a car, a wing's length for a plane) without
--     touching = NEAR MISS (both sides at once = SQUEEZE): sparks fly off the wall, a doppler "zwip", a chain point;
--   one down ray at StyleRules.SKIM_HZ: lava (a lethal hazard part or lava terrain) 1.5-16 studs under the belly =
--     LAVA SKIM: an ember wake streams off the vehicle, the belly glows orange, a sizzle plays, a chain point (and one
--     every second it lasts), and a "LAVA SKIM" stamp the first time in a while. On DINO-4 this is the clip.
--     The same ray also feels lava up to StyleRules.HEAT_MAX below: a thin rising ember spray that fades with height
--     (a vehicle passing over or beside the lava lake) and, on a thick particle budget only, a faint charcoal heat haze.
-- Phone budget: at most 3 raycasts per sample (20 Hz / 10 Hz, never per frame), one pooled burst per effect (Vfx
-- pool), one wake attachment with four emitters and a light per vehicle hull, edge-only property writes. Heat rates go
-- through Settings.particleScale() (the haze layer is dropped on phone, see StyleRules.heatRates).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StyleRules = require(Shared:WaitForChild("StyleRules"))
local FlipFx = require(Shared:WaitForChild("FlipFx"))
local Vfx = require(script.Parent:WaitForChild("Vfx"))
local StyleChain = require(script.Parent:WaitForChild("StyleChain"))
local TrickJuice = require(script.Parent:WaitForChild("TrickJuice"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local LocalPlayer = Players.LocalPlayer

local StyleSense = {}

-- ================================================================ presets
local function ns(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kps)
end

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local CREAM = Color3.fromRGB(255, 244, 214)
local HOT = Color3.fromRGB(255, 120, 40)
local presetsDefined = false

local function definePresets()
	if presetsDefined then
		return
	end
	presetsDefined = true
	-- Near miss: a short spray of sparks off the wall, thrown back along the travel, and a pin-prick flash.
	Vfx.definePreset("styleNearMiss", {
		{ tex = "spark_streak", count = 12, lifetime = NumberRange.new(0.18, 0.36), speed = NumberRange.new(26, 52), spread = Vector2.new(28, 28),
			size = ns({ { 0, 1.1 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM, HOT), lightEmission = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -60, 0), drag = 2 },
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.12), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 3 }, { 1, 6 } }), transparency = ns({ { 0, 0.2 }, { 1, 1 } }), color = ColorSequence.new(CREAM), lightEmission = 1 },
	})
	-- Zone turbo (third drift tier) in each zone's own colour: a ring, a burst of streaks and a few stars.
	for z, c in StyleRules.ZONE_COLOR do
		local col = rgb(c)
		Vfx.definePreset("zoneTurbo_" .. z, {
			{ tex = "shockwave_8x8", count = 1, lifetime = NumberRange.new(0.42, 0.5), speed = NumberRange.new(0.01), spread = Vector2.zero,
				size = ns({ { 0, 16 }, { 1, 16 } }), transparency = ns({ { 0, 0 }, { 0.7, 0.15 }, { 1, 1 } }), color = ColorSequence.new(col), lightEmission = 0.8,
				orientation = Enum.ParticleOrientation.VelocityPerpendicular, zOffset = 0.5, fbSize = ns({ { 0, 4 }, { 1, 19 } }) },
			{ tex = "spark_streak", count = 26, lifetime = NumberRange.new(0.3, 0.55), speed = NumberRange.new(40, 90), spread = Vector2.new(60, 60),
				size = ns({ { 0, 1.7 }, { 1, 0.2 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = ColorSequence.new(CREAM, col), lightEmission = 1,
				orientation = Enum.ParticleOrientation.VelocityParallel, drag = 3 },
			{ tex = "sparkle_star_4x4", count = 8, lifetime = NumberRange.new(0.4, 0.7), speed = NumberRange.new(12, 28), spread = Vector2.new(180, 180),
				size = ns({ { 0, 2.6 }, { 0.6, 2.1 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = ColorSequence.new(col), lightEmission = 0.8,
				drag = 2 },
		})
	end
end

-- Zone turbo burst at a frame (CarController: the tier-3 charge and its release).
function StyleSense.zoneBurst(cf: CFrame, zone: string?, scale: number?)
	definePresets()
	local z = if zone and StyleRules.ZONE_COLOR[zone] then zone else "SPACE"
	Vfx.burst("zoneTurbo_" .. z, cf, scale)
end

-- ================================================================ wake (one per hull)
type Wake = {
	hull: BasePart, att: Attachment, embers: ParticleEmitter, glow: ParticleEmitter, light: PointLight, on: boolean,
	heatEmbers: ParticleEmitter, haze: ParticleEmitter, heat: number, heatScale: number,
}
local wake: Wake? = nil

local function buildWake(hull: BasePart, vehicle: string): Wake
	local att = Instance.new("Attachment")
	att.Name = "StyleSkimWake"
	att.Position = if vehicle == "plane" then Vector3.new(0, -1.2, 4.5) else Vector3.new(0, -1.4, 2.6)
	att.Orientation = Vector3.new(0, 180, 0) -- Front faces backward: the wake streams off the tail
	local e = Instance.new("ParticleEmitter")
	e.Name = "SkimEmbers"
	FlipFx.apply(e, "ember")
	e.Enabled = false
	e.Rate = 0
	e.Lifetime = NumberRange.new(0.5, 1.1)
	e.Speed = NumberRange.new(8, 22)
	e.SpreadAngle = Vector2.new(38, 22)
	e.Size = ns({ { 0, 0.9 }, { 1, 0.15 } })
	e.Transparency = ns({ { 0, 0 }, { 0.8, 0.2 }, { 1, 1 } })
	e.Color = ColorSequence.new(Color3.fromRGB(255, 236, 150), HOT)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Acceleration = Vector3.new(0, 26, 0)
	e.Drag = 1.2
	e.EmissionDirection = Enum.NormalId.Front
	e.Parent = att
	local g = Instance.new("ParticleEmitter")
	g.Name = "SkimHeat"
	FlipFx.apply(g, "glow_soft")
	g.Enabled = false
	g.Rate = 0
	g.Lifetime = NumberRange.new(0.3, 0.5)
	g.Speed = NumberRange.new(2, 6)
	g.SpreadAngle = Vector2.new(20, 20)
	g.Size = ns({ { 0, 3.5 }, { 1, 6 } })
	g.Transparency = ns({ { 0, 0.55 }, { 1, 1 } })
	g.Color = ColorSequence.new(Color3.fromRGB(255, 150, 60))
	g.LightEmission = 1
	g.LightInfluence = 0
	g.EmissionDirection = Enum.NormalId.Front
	g.Parent = att
	-- Lava heat (item 9): embers rising off the underside and a faint charcoal haze; both ride the wake attachment.
	local he = Instance.new("ParticleEmitter")
	he.Name = "LavaHeatEmbers"
	FlipFx.apply(he, "ember")
	he.Enabled = false
	he.Rate = 0
	he.Lifetime = NumberRange.new(0.4, 0.6)
	he.Speed = NumberRange.new(3, 9)
	he.SpreadAngle = Vector2.new(35, 35)
	he.Size = ns({ { 0, 0.9 }, { 1, 0 } }) -- v21: 0.5 studs read as pixel dust from the chase camera
	he.Transparency = ns({ { 0, 0 }, { 0.8, 0.2 }, { 1, 1 } })
	he.Color = ColorSequence.new(Color3.fromRGB(255, 170, 60), Color3.fromRGB(120, 30, 10))
	he.LightEmission = 1
	he.LightInfluence = 0
	he.Acceleration = Vector3.new(0, 8, 0)
	he.EmissionDirection = Enum.NormalId.Top
	he.Parent = att
	local hz = Instance.new("ParticleEmitter")
	hz.Name = "LavaHeatHaze"
	FlipFx.apply(hz, "smoke_puff_8x8")
	hz.Enabled = false
	hz.Rate = 0
	hz.Lifetime = NumberRange.new(0.5, 0.7)
	hz.Speed = NumberRange.new(2, 5)
	hz.SpreadAngle = Vector2.new(25, 25)
	hz.Size = ns({ { 0, 2.5 }, { 1, 4.5 } })
	hz.Transparency = ns({ { 0, 0.88 }, { 1, 1 } }) -- starts faint: never a smudge over the road or the lens
	hz.Color = ColorSequence.new(Color3.fromRGB(60, 50, 46))
	hz.LightEmission = 0
	hz.LightInfluence = 0
	hz.ZOffset = -1
	hz.Rotation = NumberRange.new(0, 360)
	hz.EmissionDirection = Enum.NormalId.Top
	hz.Parent = att
	local l = Instance.new("PointLight")
	l.Name = "SkimBellyGlow"
	l.Color = Color3.fromRGB(255, 120, 40)
	l.Brightness = 2.2
	l.Range = 16
	l.Shadows = false
	l.Enabled = false
	l.Parent = att
	att.Parent = hull
	return { hull = hull, att = att, embers = e, glow = g, light = l, on = false, heatEmbers = he, haze = hz, heat = 0, heatScale = 1 }
end

local function setWake(hull: BasePart, vehicle: string, on: boolean)
	local w = wake
	if not w or w.hull ~= hull or not w.att.Parent then
		if not on then
			return
		end
		if w and w.att.Parent then
			w.att:Destroy()
		end
		w = buildWake(hull, vehicle)
		wake = w
	end
	local ww = w :: Wake
	if ww.on == on then
		return
	end
	ww.on = on
	ww.embers.Enabled = on
	ww.embers.Rate = if on then 70 else 0
	ww.glow.Enabled = on
	ww.glow.Rate = if on then 14 else 0
	ww.light.Enabled = on
end

-- Lava heat 0..1 (StyleRules.lavaHeat): ember spray + haze rates, written only when the heat or the particle scale moved.
local function setHeat(hull: BasePart, vehicle: string, heat: number)
	local w = wake
	if (not w or w.hull ~= hull or not w.att.Parent) and heat > 0 then
		if w and w.att.Parent then
			w.att:Destroy()
		end
		w = buildWake(hull, vehicle)
		wake = w
	end
	if not w or w.hull ~= hull then
		return
	end
	local scale = Settings.particleScale()
	if math.abs(w.heat - heat) < 0.05 and w.heatScale == scale and (heat > 0) == (w.heat > 0) then
		return
	end
	w.heat, w.heatScale = heat, scale
	local ember, haze = StyleRules.heatRates(heat, scale)
	w.heatEmbers.Rate = ember
	w.heatEmbers.Enabled = ember > 0
	w.haze.Rate = haze
	w.haze.Enabled = haze > 0
end

-- ================================================================ sensing
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true
local filterClock = -math.huge
local nearClock = 0
local skimClock = 0
local nearState = StyleRules.newNear()
local skimState = StyleRules.newSkim()
local skimStampClock = -math.huge
local lastHull: BasePart? = nil
local SKIM_STAMP_GAP = 6

local function refreshFilter(now: number)
	if now - filterClock < 2 then
		return
	end
	filterClock = now
	local ex: { Instance } = {}
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		table.insert(ex, planes)
	end
	if LocalPlayer.Character then
		table.insert(ex, LocalPlayer.Character)
	end
	params.FilterDescendantsInstances = ex
end

local function isLava(r: RaycastResult): boolean
	local inst = r.Instance
	if inst == workspace.Terrain then
		return r.Material == Enum.Material.CrackedLava
	end
	return inst:GetAttribute("HazardType") == "LethalLava" or inst.Name == "LavaSeaFloor"
end

-- A side hit counts as a wall: terrain, or a collidable part (trigger volumes, rings and pods are not walls).
local function wallDist(r: RaycastResult?): number?
	if not r then
		return nil
	end
	local inst = r.Instance
	if inst == workspace.Terrain or (inst:IsA("BasePart") and inst.CanCollide) or isLava(r) then
		return r.Distance
	end
	return nil
end

-- Clears the wake and the sizzle (respawn, a vehicle swap, the grid).
function StyleSense.stop()
	local w = wake
	if w then
		setWake(w.hull, "car", false)
		setHeat(w.hull, "car", 0)
	end
	StyleChain.loop("lava_sizzle", false)
	skimState = StyleRules.newSkim()
	nearState = StyleRules.newNear()
end

-- One frame. vehicle: "car" | "plane"; cf: the vehicle's travel frame (no barrel roll, no drift slide); speed and
-- top in studs/s; lastContact: os.clock() of the last wall touch (a scrape is never a near miss). Returns the move
-- that happened this frame ("NearMiss" | "Squeeze" | "LavaSkim" | nil) so the caller can add its own camera kick.
function StyleSense.step(dt: number, vehicle: string, hull: BasePart, cf: CFrame, speed: number, top: number, lastContact: number): string?
	local now = os.clock()
	if hull ~= lastHull then
		lastHull = hull
		filterClock = -math.huge
		StyleSense.stop()
	end
	refreshFilter(now)
	definePresets()
	local result: string? = nil
	local profile = StyleRules.NEAR[vehicle] or StyleRules.NEAR.car
	local pos = cf.Position

	-- Side rays (20 Hz, only when fast: slow driving along a wall is not a near miss).
	nearClock += dt
	if nearClock >= 1 / StyleRules.NEAR_HZ then
		nearClock = 0
		local fast = speed >= top * StyleRules.NEAR_SPEED_FRAC
		if fast or nearState.left ~= "clear" or nearState.right ~= "clear" then
			local origin = if vehicle == "car" then pos + cf.UpVector * 0.3 else pos -- car: CarConfig.WALL_RAY_LIFT, over curb lips
			local reach = StyleRules.nearReach(profile)
			local right = cf.RightVector
			local rl = workspace:Raycast(origin, -right * reach, params)
			local rr = workspace:Raycast(origin, right * reach, params)
			local kind, side = StyleRules.nearStep(nearState, wallDist(rl), wallDist(rr), profile, now, fast, lastContact)
			if kind then
				result = kind
				local back = -cf.LookVector
				local scale = if kind == "Squeeze" then 1.3 else 1
				if rl and side <= 0 then
					Vfx.burst("styleNearMiss", CFrame.lookAt(rl.Position, rl.Position + back + rl.Normal * 0.6), scale)
				end
				if rr and side >= 0 then
					Vfx.burst("styleNearMiss", CFrame.lookAt(rr.Position, rr.Position + back + rr.Normal * 0.6), scale)
				end
				-- Doppler zwip, a touch higher for a squeeze, never machine-gunned.
				StyleChain.sfx("near_miss", (if kind == "Squeeze" then 1.12 else 1) * (0.95 + math.random() * 0.1))
				StyleChain.event(kind)
				LocalPlayer:SetAttribute("NearMissCount", ((LocalPlayer:GetAttribute("NearMissCount") :: number?) or 0) + 1)
			end
		end
	end

	-- Down ray (10 Hz): lava under the belly.
	skimClock += dt
	if skimClock >= 1 / StyleRules.SKIM_HZ then
		local sdt = skimClock
		skimClock = 0
		local bottom = if vehicle == "car" then 1.9 else 1.5
		local r = workspace:Raycast(pos, Vector3.new(0, -(StyleRules.HEAT_MAX + bottom + 1), 0), params)
		local gap = if r and isLava(r) then r.Distance - bottom else nil
		local kind, active = StyleRules.skimStep(skimState, gap, sdt)
		setWake(hull, vehicle, active)
		setHeat(hull, vehicle, StyleRules.lavaHeat(gap))
		StyleChain.loop("lava_sizzle", active)
		if kind then
			result = result or kind
			StyleChain.event(kind)
			if now - skimStampClock >= SKIM_STAMP_GAP then
				skimStampClock = now
				TrickJuice.callout("LAVA SKIM", Color3.fromRGB(255, 150, 60), 1.2)
				LocalPlayer:SetAttribute("LavaSkimCount", ((LocalPlayer:GetAttribute("LavaSkimCount") :: number?) or 0) + 1)
			end
		end
	end
	if skimState.active then
		StyleChain.sustain()
	end
	return result
end

return StyleSense
