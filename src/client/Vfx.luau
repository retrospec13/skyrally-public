--!strict
-- SkyRally client VFX (ART_BAR Polish bar). One pooled, preset-driven system for every effect the player sees:
-- one-shot world bursts, oriented shockwave rings, per-vehicle persistent rigs (layered particle exhaust flame with a boost
-- shockwave ring emitter, heat wisp, wingtip vapor, engine light) for the local vehicle AND rivals, the boost ignite punch
-- (FOV overshoot, trauma, 2-frame tint), a screen-space speed-line layer plus world wind streaks and an edge vignette, and
-- zone ambience.
-- Textures: the owned flipbook sheets of assets/vfx/flip_v2 (VfxFlipAssets, resolved with layout/mode/framerate by
-- Shared.FlipFx; the old VfxAssets texture stands in only when a sheet id is missing) plus the single-frame VfxAssets
-- set (sparks, debris, embers, droplets, trails). One-shot sheets play over each particle's Lifetime (FlipbookMode
-- OneShot), loops at their framerate, bolts Random. A preset's `fbSize` is its size for the old fallback texture
-- (the shockwave sheet grows its ring inside the sheet, so the flip size is constant; the old ring needs to grow).
-- Restraint rules: nothing covers the route at phone size, no full-screen flash, emitter counts capped, everything
-- client-only.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))
local VfxAssets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("VfxAssets"))
local GarageModel = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GarageModel"))
local FlipFx = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FlipFx"))
local BossConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BossConfig"))
local BossIntro = require(script.Parent:WaitForChild("BossIntro"))
-- Audit H13 / L40: LOW GRAPHICS thins the burst particles and switches the zone ambience emitters off.
local Settings = require(script.Parent:WaitForChild("Settings"))
local FlameRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FlameRules"))
local BoostRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BoostRules"))
local BoostPadFx = require(script.Parent:WaitForChild("BoostPadFx"))
local PickupFxRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PickupFxRules"))
local AirFxRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AirFxRules"))
local GroundTexAssets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GroundTexAssets"))
local ItemFxRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemFxRules"))
local AtmosTexAssets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AtmosTexAssets"))
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")

local Vfx = {}

local LocalPlayer = Players.LocalPlayer

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
	flipbook: boolean?,
	shape: Enum.ParticleEmitterShape?,
	zOffset: number?,
	squash: NumberSequence?,
	fps: number?, -- loop/random sheets: FlipbookFramerate override
	fbSize: NumberSequence?, -- size when the old fallback texture stands in for a flip_v2 sheet
	locked: boolean?, -- LockedToPart (rig emitters that ride the hull)
	texId: string?, -- an uploaded single-frame texture id that replaces `tex` (the god_ray shaft); `tex` stays a stand-in
}

local function ns(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2], p[3] or 0))
	end
	return NumberSequence.new(kps)
end

local function cs(a: Color3, b: Color3?): ColorSequence
	return if b then ColorSequence.new(a, b) else ColorSequence.new(a)
end

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function tex(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

-- Palette (Sunshine warmth, cool boost cyan, overcharge green; the engine light and flame tints follow it)
local WARM = rgb(255, 196, 92)
local HOT = rgb(255, 120, 40)
local CYAN = rgb(110, 232, 255)
local GREEN = rgb(96, 255, 150)
local CREAM = rgb(255, 244, 214)

local WHITE = Color3.new(1, 1, 1)
local VIOLET = rgb(176, 104, 255) -- Void Dragon boost: ember / starfield trail, engine light
local VIOLET_DEEP = rgb(70, 26, 140)
local DUST = rgb(230, 210, 180) -- manifest dust_burst colour #E6D2B4 (the sheet is near-neutral)
local UPRIGHT = Enum.ParticleOrientation.FacingCameraWorldUp -- crowns, ground puffs, upright flames and bolts

-- shockwave_8x8 ring facing the burst CFrame's LookVector. The ring grows inside the sheet, so Size stays constant;
-- the old flat ring (fallback) grows from a quarter to 1.2 x instead.
local function ring(size: number, life: number, color: ColorSequence, count: number?): Preset
	return { tex = "shockwave_8x8", count = count or 1, lifetime = NumberRange.new(life, life * 1.15), speed = NumberRange.new(0.01), spread = Vector2.zero,
		size = ns({ { 0, size }, { 1, size } }), transparency = ns({ { 0, 0 }, { 0.7, 0.15 }, { 1, 1 } }), color = color, lightEmission = 0.7,
		orientation = Enum.ParticleOrientation.VelocityPerpendicular, zOffset = 0.5, fbSize = ns({ { 0, size * 0.25 }, { 1, size * 1.2 } }) }
end

-- sparkle_star_4x4 glints (a twinkling loop; the size envelope shrinks each star out).
local function sparkles(count: number, life: NumberRange, speed: NumberRange, size: number, color: ColorSequence, extra: { [string]: any }?): Preset
	local p: { [string]: any } = { tex = "sparkle_star_4x4", count = count, lifetime = life, speed = speed, spread = Vector2.new(180, 180),
		size = ns({ { 0, size }, { 0.6, size * 0.8 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = color, lightEmission = 0.8,
		rotation = NumberRange.new(-15, 15), drag = 2 }
	if extra then
		for k, v in pairs(extra) do
			p[k] = v
		end
	end
	return p :: any
end

local PRESETS: { [string]: { Preset } } = {
	boost = {
		{ tex = "spark_streak", count = 22, lifetime = NumberRange.new(0.25, 0.5), speed = NumberRange.new(40, 85), spread = Vector2.new(35, 35),
			size = ns({ { 0, 1.6 }, { 1, 0.2 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(CREAM, CYAN), lightEmission = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, drag = 3 },
		-- No flat ring, no fire tongues and no big glow here: the vehicle's layered exhaust flame and its shockwave ring
		-- emitter (stepFlames) own the boost-start look; the small flash is its own preset (boostFlash) placed ahead of the
		-- car, so nothing bright ever sits between the chase camera and the vehicle.
	},
	-- Ignite flash (local vehicle only): 6 studs, 0.16 s, placed above and ahead of the hull (Vfx.onBoost).
	-- v29 W1b A4: this soft ball ahead of the hull read as the white "pass sphere" at every ring (a ring pass is a boost):
	-- half the size, 0.85 transparent, barely emissive (was 2.5-4 studs at 0.5, LightEmission 1).
	boostFlash = {
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.16), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 1.2 }, { 1, 2 } }), transparency = ns({ { 0, 0.85 }, { 1, 1 } }), color = cs(CYAN), lightEmission = 0.3 },
	},
	overchargeFlash = {
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.16), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 1.5 }, { 1, 2.3 } }), transparency = ns({ { 0, 0.85 }, { 1, 1 } }), color = cs(GREEN), lightEmission = 0.3 },
	},
	-- Pad touch: a light streak shot down the route from the pad (the burst faces the pad's route direction).
	padStreak = {
		{ tex = "speed_streak", count = 3, lifetime = NumberRange.new(0.3, 0.4), speed = NumberRange.new(110, 150), spread = Vector2.new(3, 3),
			size = ns({ { 0, 2.4 }, { 1, 1.2 } }), transparency = ns({ { 0, 0.1 }, { 0.6, 0.35 }, { 1, 1 } }), color = cs(CREAM, CYAN), lightEmission = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, squash = ns({ { 0, 2.5 }, { 1, 2.5 } }) },
	},
	overcharge = {
		{ tex = "spark_streak", count = 32, lifetime = NumberRange.new(0.3, 0.6), speed = NumberRange.new(55, 110), spread = Vector2.new(45, 45),
			size = ns({ { 0, 2 }, { 1, 0.2 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(CREAM, GREEN), lightEmission = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, drag = 3 },
		sparkles(6, NumberRange.new(0.3, 0.5), NumberRange.new(8, 20), 3, cs(CREAM)),
	},
	-- v29 A4: no longer fired by onRing; the geyser moment (WorldMoments) keeps it, faint and unlit.
	ringPass = {
		(function()
			local p = ring(26, 0.5, cs(WARM, CYAN))
			p.transparency = ns({ { 0, 0.85 }, { 1, 1 } })
			p.lightEmission = 0
			return p
		end)(),
	},
	-- v28 W1.2: the ring-pass sparkle is its own small preset, fired at four points on the ring's rim (Vfx.onRing), 0.3 s.
	ringRim = {
		sparkles(3, NumberRange.new(0.18, 0.3), NumberRange.new(4, 10), 1.2, cs(CREAM, WARM)),
	},
	pad = {
		ring(18, 0.45, cs(CYAN)),
		{ tex = "spark_streak", count = 18, lifetime = NumberRange.new(0.3, 0.5), speed = NumberRange.new(30, 60), spread = Vector2.new(25, 25),
			size = ns({ { 0, 1.4 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(CREAM, CYAN), lightEmission = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -40, 0) },
	},
	-- v28 W1.2: no glint quad, no flat ring: about 12 small additive sparks (<= 1.5 studs, 0.15-0.3 s) thrown upward.
	pickup = {
		sparkles(12, NumberRange.new(0.15, 0.3), NumberRange.new(10, 24), 1.4, cs(CREAM, rgb(255, 214, 120)), { spread = Vector2.new(70, 70), lightEmission = 1 }),
	},
	-- Per-kind pickup burst (Vfx.onPickup tints every layer with PickupFxRules.colorRgb): glint, 4 twinkles, small ring.
	pickupTint = {
		sparkles(12, NumberRange.new(0.15, 0.3), NumberRange.new(10, 24), 1.4, cs(WHITE), { spread = Vector2.new(70, 70), lightEmission = 1 }),
	},
	-- crashStone / crashLava / battleOut (item lane): fireball and smoke shrunk (8 / 4-7 studs) and pushed away from the
	-- chase camera (negative ZOffset, smoke rising), so a crash never hides the road behind it.
	crashStone = {
		{ tex = "explosion_8x8", count = 1, lifetime = NumberRange.new(0.8, 0.95), speed = NumberRange.new(0, 2), spread = Vector2.new(180, 180),
			size = ns({ { 0, 8 }, { 1, 8 } }), transparency = ns({ { 0, 0.05 }, { 1, 0.2 } }), color = cs(WHITE), lightEmission = 0.3,
			rotation = NumberRange.new(0, 360), zOffset = -1, fbSize = ns({ { 0, 5 }, { 1, 8 } }) },
		-- Item lane: a 0.1 s small white-orange glow flash (never longer than 2 frames of full brightness at phone size).
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.1), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 5 }, { 1, 9 } }), transparency = ns({ { 0, 0.25 }, { 1, 1 } }), color = cs(CREAM, HOT), lightEmission = 1, zOffset = -1 },
		ring(18, 0.5, cs(CREAM, HOT)),
		{ tex = "spark_streak", count = 24, lifetime = NumberRange.new(0.3, 0.7), speed = NumberRange.new(45, 95), spread = Vector2.new(70, 70),
			size = ns({ { 0, 1.5 }, { 1, 0.1 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(CREAM, HOT), lightEmission = 1,
			orientation = Enum.ParticleOrientation.VelocityParallel, accel = Vector3.new(0, -90, 0), drag = 1.5 },
		-- v19 tune: 14 shards of 1.4 -> 8 of 0.8 (at the chase-camera distance the old ones read as ~100 px tiles), smoke
		-- 3 puffs of 4-7 studs at 0.15 alpha -> 2 of 3-5 at 0.5 (it hid the road ahead for ~1 s at phone size).
		{ tex = "debris_shard", count = 8, lifetime = NumberRange.new(0.8, 1.3), speed = NumberRange.new(25, 60), spread = Vector2.new(65, 65),
			size = ns({ { 0, 0.8 }, { 1, 0.5 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = cs(rgb(150, 112, 84), rgb(92, 70, 60)),
			lightEmission = 0, accel = Vector3.new(0, -140, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-360, 360) },
		{ tex = "smoke_puff_8x8", count = 2, lifetime = NumberRange.new(0.5, 0.7), speed = NumberRange.new(3, 7), spread = Vector2.new(60, 60),
			size = ns({ { 0, 2.5 }, { 1, 3.5 } }), transparency = ns({ { 0, 0.5 }, { 1, 0.95 } }), color = cs(rgb(190, 178, 166), rgb(222, 214, 204)), lightEmission = 0,
			rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-30, 30), accel = Vector3.new(0, 14, 0), drag = 1.2, zOffset = -2 },
	},
	crashLava = {
		{ tex = "fire_loop_8x8", count = 6, lifetime = NumberRange.new(0.55, 0.85), speed = NumberRange.new(10, 22), spread = Vector2.new(35, 35),
			size = ns({ { 0, 3 }, { 1, 5 } }), transparency = ns({ { 0, 0 }, { 0.75, 0.1 }, { 1, 1 } }), color = cs(WHITE), lightEmission = 0.6,
			accel = Vector3.new(0, 30, 0), orientation = UPRIGHT, zOffset = -1 },
		{ tex = "explosion_8x8", count = 1, lifetime = NumberRange.new(0.9, 1.05), speed = NumberRange.new(0, 2), spread = Vector2.new(180, 180),
			size = ns({ { 0, 8 }, { 1, 8 } }), transparency = ns({ { 0, 0.05 }, { 1, 0.2 } }), color = cs(rgb(255, 226, 190)), lightEmission = 0.45,
			rotation = NumberRange.new(0, 360), zOffset = -1, fbSize = ns({ { 0, 5 }, { 1, 8 } }) },
		-- Item lane: a 0.1 s small white-orange glow flash (never longer than 2 frames of full brightness at phone size).
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.1), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 5 }, { 1, 9 } }), transparency = ns({ { 0, 0.25 }, { 1, 1 } }), color = cs(CREAM, HOT), lightEmission = 1, zOffset = -1 },
		{ tex = "ember", count = 30, lifetime = NumberRange.new(0.8, 1.8), speed = NumberRange.new(30, 70), spread = Vector2.new(40, 40),
			size = ns({ { 0, 1.1 }, { 1, 0.2 } }), transparency = ns({ { 0, 0 }, { 1, 1 } }), color = cs(rgb(255, 230, 140), HOT), lightEmission = 1,
			accel = Vector3.new(0, -60, 0), drag = 0.8 },
		{ tex = "smoke_puff_8x8", count = 3, lifetime = NumberRange.new(1.1, 1.5), speed = NumberRange.new(6, 12), spread = Vector2.new(30, 30),
			size = ns({ { 0, 5 }, { 1, 8 } }), transparency = ns({ { 0, 0.2 }, { 1, 0.65 } }), color = cs(rgb(96, 78, 72), rgb(140, 120, 112)),
			rotation = NumberRange.new(0, 360), accel = Vector3.new(0, 18, 0), drag = 1, zOffset = -2 },
	},
	respawn = {
		{ tex = "shockwave_ring", count = 2, lifetime = NumberRange.new(0.5, 0.7), speed = NumberRange.new(0.01), spread = Vector2.zero,
			size = ns({ { 0, 20 }, { 1, 3 } }), transparency = ns({ { 0, 1 }, { 0.3, 0.2 }, { 1, 0.6 } }), color = cs(CREAM, CYAN), lightEmission = 1,
			orientation = Enum.ParticleOrientation.VelocityPerpendicular },
		{ tex = "star_twinkle", count = 18, lifetime = NumberRange.new(0.5, 0.9), speed = NumberRange.new(4, 10), spread = Vector2.new(180, 180),
			size = ns({ { 0, 1.8 }, { 1, 0 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = cs(CREAM), lightEmission = 1, rotation = NumberRange.new(0, 90) },
		sparkles(4, NumberRange.new(0.5, 0.8), NumberRange.new(5, 12), 2.2, cs(CREAM, CYAN)), -- arrival sparkle ring
	},
	-- Lakitu-style return (audit item 5), fired by Vfx.onRespawn: a cloud carrier under the wheels (sprayed down and
	-- out, so it sits below the chase camera's line to the road) and the descending god_ray light column.
	respawnCloud = {
		{ tex = "smoke_puff_8x8", count = 6, lifetime = NumberRange.new(0.7, 0.9), speed = NumberRange.new(3, 8), spread = Vector2.new(70, 70),
			size = ns({ { 0, 4 }, { 1, 7 } }), transparency = ns({ { 0, 0.3 }, { 1, 1 } }), color = cs(WHITE, rgb(196, 226, 255)),
			lightEmission = 0.25, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-30, 30), drag = 2, zOffset = -2 },
	},
	respawnColumn = {
		{ tex = "glow_soft", texId = "rbxassetid://" .. tostring(AtmosTexAssets.god_ray), count = 1, lifetime = NumberRange.new(ItemFxRules.COLUMN_LIFE),
			speed = NumberRange.new(ItemFxRules.columnSpeed()), spread = Vector2.zero, size = ns({ { 0, 14 }, { 1, 10 } }),
			transparency = ns({ { 0, 0.75 }, { 0.5, 0.85 }, { 1, 1 } }), color = cs(CREAM, CYAN), lightEmission = 1,
			orientation = UPRIGHT, zOffset = -2 },
	},
	finish = {
		sparkles(24, NumberRange.new(0.8, 1.4), NumberRange.new(40, 80), 2.1, cs(rgb(255, 214, 90), rgb(255, 120, 200)),
			{ accel = Vector3.new(0, -30, 0), drag = 1.4 }),
		{ tex = "confetti_burst_4x4", count = 2, lifetime = NumberRange.new(1.3, 1.6), speed = NumberRange.new(6, 14), spread = Vector2.new(70, 70),
			size = ns({ { 0, 6.5 }, { 1, 6.5 } }), transparency = ns({ { 0, 0 }, { 1, 0 } }), color = cs(WHITE), lightEmission = 0.1,
			accel = Vector3.new(0, -6, 0), drag = 1, orientation = UPRIGHT }, -- gravity is baked into the sheet: no rotation
		ring(40, 0.7, cs(rgb(255, 214, 90))),
	},
	confetti = (function(): { Preset }
		local out: { Preset } = {}
		for _, c in { rgb(255, 92, 92), rgb(255, 214, 72), rgb(84, 190, 255), rgb(120, 230, 110) } do
			table.insert(out, { tex = "confetti", count = 20, lifetime = NumberRange.new(2.2, 3.4), speed = NumberRange.new(35, 95), spread = Vector2.new(55, 55),
				size = ns({ { 0, 0.7 }, { 1, 0.55 } }), transparency = ns({ { 0, 0 }, { 0.85, 0 }, { 1, 1 } }), color = cs(c), lightEmission = 0.15,
				accel = Vector3.new(0, -26, 0), drag = 1.8, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-320, 320),
				squash = ns({ { 0, 0 }, { 0.25, -0.6 }, { 0.5, 0.6 }, { 0.75, -0.6 }, { 1, 0.4 } }) })
		end
		-- The rendered burst (already coloured paper and ribbons) pops at the origin under the flying ribbons.
		table.insert(out, { tex = "confetti_burst_4x4", count = 2, lifetime = NumberRange.new(1.2, 1.5), speed = NumberRange.new(4, 10), spread = Vector2.new(40, 40),
			size = ns({ { 0, 8 }, { 1, 8 } }), transparency = ns({ { 0, 0 }, { 1, 0 } }), color = cs(WHITE), lightEmission = 0.1,
			accel = Vector3.new(0, -4, 0), drag = 1, orientation = UPRIGHT })
		return out
	end)(),
	-- Trick lane (REMARKABLE items 5-6, CarController): STUCK IT! gold stars (the finish star layer at ~40 %, 0.5 s),
	-- hop take-off/landing dust, and the flooded-engine black "POMF". Small counts: phone budget.
	trickLand = {
		sparkles(14, NumberRange.new(0.35, 0.5), NumberRange.new(26, 52), 2.6, cs(rgb(255, 236, 140), rgb(255, 196, 60)), { accel = Vector3.new(0, -30, 0) }),
		ring(12, 0.42, cs(rgb(255, 214, 90))),
	},
	hopDust = {
		{ tex = "dust_burst_4x4", count = 3, lifetime = NumberRange.new(0.5, 0.75), speed = NumberRange.new(3, 8), spread = Vector2.new(80, 10),
			size = ns({ { 0, 3 }, { 1, 4 } }), transparency = ns({ { 0, 0.15 }, { 1, 0.5 } }), color = cs(DUST), lightEmission = 0,
			orientation = UPRIGHT, drag = 4 },
	},
	-- Car touchdown from real air (not a hop: hopDust covers those), CarController's landing branch.
	landDust = {
		{ tex = "dust_burst_4x4", count = 4, lifetime = NumberRange.new(0.6, 0.9), speed = NumberRange.new(4, 12), spread = Vector2.new(85, 8),
			size = ns({ { 0, 4 }, { 1, 5.5 } }), transparency = ns({ { 0, 0.1 }, { 1, 0.5 } }), color = cs(DUST), lightEmission = 0,
			orientation = UPRIGHT, drag = 3 },
	},
	floodPuff = {
		{ tex = "smoke_puff_8x8", count = 6, lifetime = NumberRange.new(0.7, 1.1), speed = NumberRange.new(6, 14), spread = Vector2.new(25, 25),
			size = ns({ { 0, 1.5 }, { 0.3, 4.5 }, { 1, 7 } }), transparency = ns({ { 0, 0.05 }, { 1, 1 } }), color = cs(rgb(24, 20, 20), rgb(70, 64, 62)),
			lightEmission = 0, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-40, 40), accel = Vector3.new(0, 8, 0), drag = 2 },
	},
	-- Sink / drown (and the hub fountain): the crown splash sits on the water line, upright, no rotation.
	splash = {
		{ tex = "water_splash_8x8", count = 1, lifetime = NumberRange.new(0.8, 1), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 10 }, { 1, 10 } }), transparency = ns({ { 0, 0 }, { 1, 0 } }), color = cs(rgb(235, 248, 255)), lightEmission = 0.1,
			orientation = UPRIGHT, zOffset = 0.5, fbSize = ns({ { 0, 1 }, { 1, 0.5 } }) },
		{ tex = "water_droplet", count = 18, lifetime = NumberRange.new(0.5, 0.9), speed = NumberRange.new(20, 45), spread = Vector2.new(50, 50),
			size = ns({ { 0, 0.9 }, { 1, 0.4 } }), transparency = ns({ { 0, 0 }, { 1, 0.8 } }), color = cs(rgb(220, 250, 255)), lightEmission = 0.2,
			accel = Vector3.new(0, -110, 0) },
	},
	-- Plane skimming low over water (stepWaterSkim): a small upright crown thrown up behind the plane, a few drops.
	skimSpray = {
		{ tex = "water_splash_8x8", count = 1, lifetime = NumberRange.new(0.5, 0.6), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 6 }, { 1, 9 } }), transparency = ns({ { 0, 0.1 }, { 1, 0.4 } }), color = cs(rgb(235, 248, 255)), lightEmission = 0.1, -- v21: 4->6 studs was a speck from the chase camera
			orientation = UPRIGHT, zOffset = -1, fbSize = ns({ { 0, 0.8 }, { 1, 0.4 } }) },
		{ tex = "water_droplet", count = 8, lifetime = NumberRange.new(0.4, 0.7), speed = NumberRange.new(14, 30), spread = Vector2.new(40, 40),
			size = ns({ { 0, 1.1 }, { 1, 0.4 } }), transparency = ns({ { 0, 0.1 }, { 1, 0.8 } }), color = cs(rgb(220, 250, 255)), lightEmission = 0.2,
			accel = Vector3.new(0, -110, 0) },
	},
	-- Driving into shallow water (CarController): a small crown and a few drops.
	waterEntry = {
		{ tex = "water_splash_8x8", count = 1, lifetime = NumberRange.new(0.65, 0.8), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 6 }, { 1, 6 } }), transparency = ns({ { 0, 0 }, { 1, 0 } }), color = cs(rgb(235, 248, 255)), lightEmission = 0.1,
			orientation = UPRIGHT, fbSize = ns({ { 0, 0.8 }, { 1, 0.4 } }) },
		{ tex = "water_droplet", count = 8, lifetime = NumberRange.new(0.4, 0.7), speed = NumberRange.new(12, 26), spread = Vector2.new(45, 45),
			size = ns({ { 0, 0.7 }, { 1, 0.3 } }), transparency = ns({ { 0, 0 }, { 1, 0.8 } }), color = cs(rgb(220, 250, 255)), lightEmission = 0.2,
			accel = Vector3.new(0, -110, 0) },
	},
	-- SNOW ambience: a powder puff off to the side of the route now and then (Vfx.step).
	snowPuff = {
		{ tex = "snow_burst_4x4", count = 1, lifetime = NumberRange.new(0.8, 1), speed = NumberRange.new(0, 2), spread = Vector2.new(30, 30),
			size = ns({ { 0, 6 }, { 1, 7 } }), transparency = ns({ { 0, 0.25 }, { 1, 0.5 } }), color = cs(WHITE), lightEmission = 0.2,
			orientation = UPRIGHT, fbSize = ns({ { 0, 0.6 }, { 1, 0.3 } }) },
	},
	-- SNOW skim (L61): powder kicked off the snow or ice under a low local plane (Vfx stepSnowSkim), small and short so it
	-- trails behind and below the plane, never over the route ahead. Float fix (2026-10-20): the 3.5-6 stud puffs lived
	-- 0.9 s, long enough for the chase camera to fly over them, and showed as big flat white quads when the sheet was not
	-- drawn; now 2.5-4.5 studs for 0.5-0.65 s, never emitted near the camera, never before the sheet has loaded.
	snowSkim = {
		{ tex = "snow_burst_4x4", count = 1, lifetime = NumberRange.new(0.5, 0.65), speed = NumberRange.new(2, 5), spread = Vector2.new(35, 35),
			size = ns({ { 0, 2.5 }, { 1, 4.5 } }), transparency = ns({ { 0, 0.45 }, { 1, 0.85 } }), color = cs(WHITE), lightEmission = 0.25,
			orientation = UPRIGHT, fbSize = ns({ { 0, 0.6 }, { 1, 0.3 } }) },
		{ tex = "snowflake", count = 4, lifetime = NumberRange.new(0.5, 0.8), speed = NumberRange.new(8, 16), spread = Vector2.new(40, 40),
			size = ns({ { 0, 0.6 }, { 1, 0.3 } }), transparency = ns({ { 0, 0.1 }, { 1, 0.8 } }), color = cs(WHITE), lightEmission = 0.4,
			accel = Vector3.new(0, -20, 0), drag = 1.5, rotSpeed = NumberRange.new(-180, 180) },
	},
	-- FOREST skim (L61): leaves and grass blades whipped up off the meadow under a low local plane (Vfx stepMeadowSkim),
	-- golden chaff over the wheat fields; small and short, trailing behind and below the plane.
	meadowSkim = {
		{ tex = "leaf", count = 3, lifetime = NumberRange.new(0.8, 1.3), speed = NumberRange.new(8, 15), spread = Vector2.new(50, 50),
			size = ns({ { 0, 0.9 }, { 1, 0.6 } }), transparency = ns({ { 0, 0.05 }, { 0.75, 0.2 }, { 1, 1 } }),
			color = cs(rgb(128, 168, 82), rgb(206, 196, 96)), accel = Vector3.new(0, -9, 0), drag = 1.6,
			rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-260, 260) },
	},
	wheatSkim = {
		{ tex = "leaf", count = 4, lifetime = NumberRange.new(0.8, 1.3), speed = NumberRange.new(9, 17), spread = Vector2.new(55, 55),
			size = ns({ { 0, 0.75 }, { 1, 0.5 } }), transparency = ns({ { 0, 0.05 }, { 0.75, 0.2 }, { 1, 1 } }),
			color = cs(rgb(246, 210, 110), rgb(222, 166, 70)), lightEmission = 0.15, accel = Vector3.new(0, -8, 0), drag = 1.6,
			rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-300, 300) },
		{ tex = "dust_burst_4x4", count = 1, lifetime = NumberRange.new(0.6, 0.8), speed = NumberRange.new(1, 3), spread = Vector2.new(30, 30),
			size = ns({ { 0, 3 }, { 1, 5 } }), transparency = ns({ { 0, 0.5 }, { 1, 0.85 } }), color = cs(rgb(240, 214, 150)), lightEmission = 0.1,
			orientation = UPRIGHT, fbSize = ns({ { 0, 0.6 }, { 1, 0.3 } }) },
	},
	-- ISLAND sand kick (L61): a warm dust puff and a few grains thrown up behind the local car while it drives on
	-- beach sand off the road (Vfx stepSandKick); small and short, behind the car, never over the route ahead.
	sandKick = {
		{ tex = "dust_burst_4x4", count = 1, lifetime = NumberRange.new(0.6, 0.8), speed = NumberRange.new(2, 5), spread = Vector2.new(35, 10),
			size = ns({ { 0, 2.5 }, { 1, 4.5 } }), transparency = ns({ { 0, 0.3 }, { 1, 0.75 } }), color = cs(rgb(236, 210, 160)), lightEmission = 0.05,
			orientation = UPRIGHT, drag = 3, fbSize = ns({ { 0, 0.6 }, { 1, 0.3 } }) },
	},
	-- Boss hazard hits (ItemClient "explode" with source boss_<kind>, via Vfx.onHazardHit).
	snowHit = {
		{ tex = "snow_burst_4x4", count = 3, lifetime = NumberRange.new(0.75, 1), speed = NumberRange.new(4, 10), spread = Vector2.new(180, 180),
			size = ns({ { 0, 7 }, { 1, 9 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = cs(WHITE), lightEmission = 0.2,
			orientation = UPRIGHT, fbSize = ns({ { 0, 0.8 }, { 1, 0.4 } }) },
		{ tex = "snowflake", count = 14, lifetime = NumberRange.new(0.6, 1), speed = NumberRange.new(20, 40), spread = Vector2.new(180, 180),
			size = ns({ { 0, 0.7 }, { 1, 0.4 } }), transparency = ns({ { 0, 0 }, { 1, 0.6 } }), color = cs(WHITE), lightEmission = 0.3,
			accel = Vector3.new(0, -60, 0), drag = 1, rotSpeed = NumberRange.new(-180, 180) },
		ring(14, 0.45, cs(rgb(220, 244, 255))),
	},
	bubblePop = {
		{ tex = "water_splash_8x8", count = 1, lifetime = NumberRange.new(0.7, 0.85), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 9 }, { 1, 9 } }), transparency = ns({ { 0, 0 }, { 1, 0 } }), color = cs(rgb(200, 240, 255)), lightEmission = 0.15,
			orientation = UPRIGHT, fbSize = ns({ { 0, 1 }, { 1, 0.5 } }) },
		{ tex = "water_droplet", count = 16, lifetime = NumberRange.new(0.4, 0.8), speed = NumberRange.new(18, 34), spread = Vector2.new(180, 180),
			size = ns({ { 0, 0.8 }, { 1, 0.3 } }), transparency = ns({ { 0, 0 }, { 1, 0.8 } }), color = cs(rgb(220, 250, 255)), lightEmission = 0.2,
			accel = Vector3.new(0, -60, 0) },
		ring(12, 0.4, cs(rgb(200, 245, 255))),
	},
	lightningStrike = {
		{ tex = "lightning_bolt_2x2", count = 2, lifetime = NumberRange.new(0.15, 0.25), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 16 }, { 1, 16 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = cs(WHITE), lightEmission = 0.7,
			orientation = UPRIGHT, zOffset = 1, fbSize = ns({ { 0, 3 }, { 1, 3 } }) },
		{ tex = "electric_arc_4x4", count = 3, lifetime = NumberRange.new(0.4, 0.6), speed = NumberRange.new(0, 4), spread = Vector2.new(180, 180),
			size = ns({ { 0, 4 }, { 1, 4.5 } }), transparency = ns({ { 0, 0 }, { 0.7, 0.1 }, { 1, 1 } }), color = cs(WHITE), lightEmission = 0.6,
			rotation = NumberRange.new(0, 360) },
		ring(16, 0.45, cs(rgb(200, 240, 255))),
	},
	-- Survival / water battle: an entrant is OUT (BattleOut rising edge on a vehicle in Planes).
	battleOut = {
		{ tex = "explosion_8x8", count = 1, lifetime = NumberRange.new(1, 1.1), speed = NumberRange.new(0, 2), spread = Vector2.new(180, 180),
			size = ns({ { 0, 9 }, { 1, 9 } }), transparency = ns({ { 0, 0.05 }, { 1, 0.2 } }), color = cs(WHITE), lightEmission = 0.3,
			rotation = NumberRange.new(0, 360), zOffset = -1, fbSize = ns({ { 0, 6 }, { 1, 9 } }) },
		-- Item lane: a 0.1 s small white-orange glow flash (never longer than 2 frames of full brightness at phone size).
		{ tex = "glow_soft", count = 1, lifetime = NumberRange.new(0.1), speed = NumberRange.new(0), spread = Vector2.zero,
			size = ns({ { 0, 5 }, { 1, 9 } }), transparency = ns({ { 0, 0.25 }, { 1, 1 } }), color = cs(CREAM, HOT), lightEmission = 1, zOffset = -1 },
		ring(24, 0.6, cs(CREAM, HOT)),
		{ tex = "debris_shard", count = 16, lifetime = NumberRange.new(0.8, 1.3), speed = NumberRange.new(25, 60), spread = Vector2.new(70, 70),
			size = ns({ { 0, 1.4 }, { 1, 0.9 } }), transparency = ns({ { 0, 0 }, { 0.8, 0 }, { 1, 1 } }), color = cs(rgb(120, 110, 104), rgb(70, 64, 60)),
			lightEmission = 0, accel = Vector3.new(0, -140, 0), rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-360, 360) },
		{ tex = "smoke_puff_8x8", count = 4, lifetime = NumberRange.new(1.6, 2.2), speed = NumberRange.new(6, 12), spread = Vector2.new(25, 25),
			size = ns({ { 0, 5 }, { 1, 8 } }), transparency = ns({ { 0, 0.15 }, { 1, 0.6 } }), color = cs(rgb(70, 62, 60), rgb(130, 122, 118)),
			rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-25, 25), accel = Vector3.new(0, 16, 0), drag = 1, zOffset = -2 },
	},
}

-- ---------------------------------------------------------------- burst pool
local poolFolder: Folder? = nil
local pool: { [string]: { att: Attachment, emitters: { ParticleEmitter } } } = {}

local function applyPreset(pe: ParticleEmitter, p: Preset)
	-- Texture + FlipbookLayout/Mode/Framerate from the sheet (flip_v2, or an old 4x4 sheet's own layout).
	local isFlip = FlipFx.apply(pe, p.tex, p.fps)
	pe.Enabled = false
	pe.Rate = 0
	pe.Lifetime = p.lifetime
	pe.Speed = p.speed
	pe.SpreadAngle = p.spread
	if p.texId and p.texId ~= "" then
		pe.Texture = p.texId
		pe.FlipbookLayout = Enum.ParticleFlipbookLayout.None -- a single-frame shaft, not the stand-in's sheet
		isFlip = false
	end
	pe.Size = if not isFlip and p.fbSize then p.fbSize else p.size
	pe.Transparency = p.transparency
	pe.Color = p.color
	pe.LightEmission = p.lightEmission or 0
	-- Emissive sheets (fire 0.45+, arcs, swirls, sparkles, rings) ignore scene light; lit smoke/dust/explosion keep it.
	pe.LightInfluence = if (p.lightEmission or 0) >= 0.45 then 0 else 1
	pe.Acceleration = p.accel or Vector3.zero
	pe.Drag = p.drag or 0
	pe.Rotation = p.rotation or NumberRange.new(0)
	pe.RotSpeed = p.rotSpeed or NumberRange.new(0)
	pe.Orientation = p.orientation or Enum.ParticleOrientation.FacingCamera
	pe.EmissionDirection = Enum.NormalId.Front
	pe.ZOffset = p.zOffset or 0
	pe.LockedToPart = p.locked == true
	if p.shape then
		pe.Shape = p.shape
		pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	end
	if p.squash then
		pe.Squash = p.squash
	end
end

-- Texture gate (float fix 2026-10-20): a ParticleEmitter whose texture has not loaded, or failed to, is drawn as a
-- flat untextured square; on a loaded machine the SNOW skim's snow_burst sheet showed as big white quads around the
-- plane. A burst layer emits only once its texture reports Success (built-in rbxasset:// textures always do); the
-- first ask starts a PreloadAsync. If the fetch API is unavailable the gate stays open (never blocks effects).
local texReady: { [string]: boolean } = {}
local texAsked: { [string]: boolean } = {}
local function textureReady(id: string): boolean
	if id == "" then
		return false
	end
	if texReady[id] then
		return true
	end
	if string.sub(id, 1, 11) == "rbxasset://" then
		texReady[id] = true
		return true
	end
	local ok, status = pcall(function(): Enum.AssetFetchStatus
		return ContentProvider:GetAssetFetchStatus(id)
	end)
	if not ok then
		texReady[id] = true
		return true
	end
	if status == Enum.AssetFetchStatus.Success then
		texReady[id] = true
		return true
	end
	if not texAsked[id] and status ~= Enum.AssetFetchStatus.Loading then
		texAsked[id] = true
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync({ id })
			end)
			local ok2, st2 = pcall(function(): Enum.AssetFetchStatus
				return ContentProvider:GetAssetFetchStatus(id)
			end)
			if ok2 and st2 == Enum.AssetFetchStatus.Failure then
				warn("[SkyRally][VFX] texture failed to load, its burst layers stay off: " .. id)
			elseif ok2 and st2 ~= Enum.AssetFetchStatus.Success then
				texAsked[id] = nil -- timed out or still pending: ask again on a later burst
			end
		end)
	end
	return false
end

local function getPool(name: string): { att: Attachment, emitters: { ParticleEmitter } }?
	local existing = pool[name]
	if existing then
		return existing
	end
	local preset = PRESETS[name]
	if not preset then
		return nil
	end
	local att = Instance.new("Attachment")
	att.Name = "VfxBurst_" .. name
	att.Parent = workspace.Terrain
	local emitters = {}
	for i, p in preset do
		local pe = Instance.new("ParticleEmitter")
		pe.Name = name .. "_" .. tostring(i)
		applyPreset(pe, p)
		pe.Parent = att
		table.insert(emitters, pe)
	end
	local entry = { att = att, emitters = emitters }
	pool[name] = entry
	for _, pe in emitters do
		textureReady(pe.Texture) -- starts the fetch now, so the first burst usually finds the texture loaded
	end
	return entry
end

-- A VelocityPerpendicular particle whose velocity is exactly vertical is not drawn (its quad basis comes from velocity x
-- world up, which is zero), so every "flat ring on the road" emitted with lookAt(pos, pos + yAxis) vanished. Nudge a
-- (nearly) vertical facing ~2.5 degrees off the vertical: the ring still lies flat and now renders.
local function offVertical(cf: CFrame): CFrame
	local look = cf.LookVector
	if math.abs(look.Y) > 0.998 then
		return CFrame.lookAt(cf.Position, cf.Position + Vector3.new(0.045, look.Y, 0).Unit, Vector3.zAxis)
	end
	return cf
end

-- Emits a preset at a world CFrame. The CFrame's LookVector is the effect's facing (ring normal, spray direction).
function Vfx.burst(name: string, cf: CFrame, scale: number?)
	local entry = getPool(name)
	if not entry then
		return
	end
	entry.att.WorldCFrame = offVertical(cf)
	local preset = PRESETS[name]
	for i, pe in entry.emitters do
		if not textureReady(pe.Texture) then
			continue
		end
		local n = preset[i].count
		pe:Emit(math.max(1, math.floor(n * (scale or 1) * Settings.particleScale() + 0.5)))
	end
end

-- Style lane hook (REMARKABLE items 15-16, client/StyleSense): another module registers its own burst presets (the
-- zone turbo per zone, near-miss sparks) in this same pool. Same layer fields as PRESETS; an existing name is kept.
function Vfx.definePreset(name: string, layers: { any })
	if PRESETS[name] == nil then
		PRESETS[name] = layers :: any
	end
end

-- ---------------------------------------------------------------- plane rigs
-- One flame per nozzle attachment: up to 3 ParticleEmitter layers (core, sparks, smoke) parented to the attachment.
type FlameLayer = {
	name: string, -- key into FlameRules.LAYERS
	pe: ParticleEmitter,
	lastRate: number, -- last Rate written (-1 = none)
}
type Flame = {
	nozzle: Attachment, -- server-made FlameNozzle* attachment (PlaneBuilder tail, CarBuilder tailpipes)
	scale: number, -- the nozzle's FlameScale attribute (1 plane, 0.55 per car pipe)
	phase: number, -- noise offset, so twin flames never flicker in step
	layers: { FlameLayer },
}
type FlameFx = {
	flames: { Flame },
	ring: ParticleEmitter, -- boost-start shockwave_8x8 ring on the first nozzle (Rate 0, one Emit per boost start)
	thr: number, -- smoothed throttle 0..1 (from Speed)
	heat: number, -- smoothed boost 0..1
	over: number, -- smoothed overcharge 0..1 (green)
	kick: number, -- 1 -> 0 over KICK_TIME after a boost starts (core rate overshoot)
	lThr: number, -- thr/heat/over the emitter looks were last written for
	lHeat: number,
	lOver: number,
	on: boolean, -- emitters enabled (false while far from the camera or under LOW GRAPHICS)
}

type Rig = {
	model: Model,
	embers: { ParticleEmitter }?, -- creature avatars: violet ember / starfield trail at the wingtips and tail tip while boosting
	creature: boolean?,
	hull: BasePart,
	racer: Color3?, -- the model's RacerColor (server/kit/RacerPaint): tints the wingtip vapour and the boost ribbons
	exhaust: ParticleEmitter, -- heat wisp (boost start burst + a thin stream while boosting)
	rear: Attachment, -- wisp emitter and engine light mount; moved onto the nozzles once they are known
	fx: FlameFx?,
	fxNext: number, -- os.clock() of the next template/nozzle lookup while fx is nil
	fxTries: number,
	vaporL: Trail,
	vaporR: Trail,
	light: PointLight,
	lastBoost: string,
	trailRaw: string?, -- owner's Equipped attribute the cosmetic trail was built from
	cosmetic: { Instance }, -- Garage trail ribbons and their attachments
	rolling: boolean?, -- barrel-roll corkscrew vapor is on (local plane)
	streaks: { ParticleEmitter }?, -- speed_streak wind lines off the wingtips (local vehicle only)
	streakRate: number?, -- last Rate written to the streaks (edge-only writes)
	boostTrails: { Trail }?, -- short trail_soft ribbons at the wingtips / rear corners while boosting (local vehicle only)
	out: boolean?, -- BattleOut seen (the OUT burst fires on the rising edge)
	vortex: { ParticleEmitter }?, -- world-space wingtip vortex / contrail puffs (planes only)
	vortexRate: number?, -- last Rate written to the vortex emitters (edge-only writes)
	draftTrails: { Trail }?, -- slipstream ribbons off this (rival) plane's rear corners, built on first use
	remote: boolean?, -- another racer's vehicle (set by Vfx.step each frame; the phone-tier flame cull reads it)
}
local rigs: { [Model]: Rig } = {}

local function makeEmitter(parent: Instance, name: string, p: Preset, rate: number): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.Name = name
	applyPreset(pe, p)
	pe.Rate = rate
	pe.Enabled = rate > 0
	pe.Parent = parent
	return pe
end

local function attachRig(model: Model)
	if rigs[model] then
		return
	end
	local hull = model:FindFirstChild("Hull") :: BasePart?
	if not hull then
		return
	end
	-- Creature avatars (VehicleCreatureRules attributes set by kit/CreatureMesh): the wingtips and the tail tip are where
	-- the effects live; there is no belly flame or plane tail.
	local wingAttr, tailAttr = model:GetAttribute("CreatureWingHalf"), model:GetAttribute("CreatureTailBack")
	local creature = type(wingAttr) == "number" and type(tailAttr) == "number"
	local wingX: number = if creature then wingAttr :: number else 7.6
	local tailZ: number = if creature then tailAttr :: number else 6.2
	local rear = Instance.new("Attachment")
	rear.Name = "VfxRear"
	rear.CFrame = CFrame.new(0, if creature then 0.3 else 0, tailZ) * CFrame.Angles(0, math.pi, 0) -- emits backwards (+Z is behind the hull)
	rear.Parent = hull
	-- Heat wisp (replaces the old constant smoke puffs and the flipbook boost flame): a few pale, nearly transparent
	-- puffs thrown back at boost start and a thin stream while boosting, so the air behind the nozzle seems to shimmer.
	local exhaust = makeEmitter(rear, "VfxExhaust", {
		tex = "smoke_puff_8x8", count = 0, lifetime = NumberRange.new(0.45, 0.75), speed = NumberRange.new(5, 9), spread = Vector2.new(10, 10),
		size = ns({ { 0, 1.0 }, { 1, 4.2 } }), transparency = ns({ { 0, 0.82 }, { 0.5, 0.9 }, { 1, 1 } }), color = cs(rgb(232, 226, 214)),
		rotation = NumberRange.new(0, 360), drag = 2.5,
	}, 0)
	local racerAttr = model:GetAttribute("RacerColor")
	local racer: Color3? = if typeof(racerAttr) == "Color3" then racerAttr else nil
	local function wingTrail(x: number): Trail
		local a0 = Instance.new("Attachment")
		a0.CFrame = CFrame.new(x, 0.15, 0.6)
		a0.Parent = hull
		local a1 = Instance.new("Attachment")
		a1.CFrame = CFrame.new(x, -0.15, 0.6)
		a1.Parent = hull
		local tr = Instance.new("Trail")
		tr.Name = "VfxVapor"
		tr.Attachment0 = a0
		tr.Attachment1 = a1
		tr.Texture = tex("trail_soft")
		tr.Lifetime = 0.11 -- fades before the chase camera (14 studs back) so it never sweeps the lens
		tr.MinLength = 0.2
		tr.FaceCamera = true
		tr.LightEmission = 0.6
		tr.Color = if racer then cs(racer:Lerp(WHITE, 0.3), WHITE) else cs(Color3.new(1, 1, 1))
		tr.Transparency = ns({ { 0, 0.5 }, { 0.6, 0.85 }, { 1, 1 } })
		tr.WidthScale = ns({ { 0, 1 }, { 1, 0.2 } })
		tr.Enabled = false
		tr.Parent = hull
		return tr
	end
	-- Boost ribbons (local vehicle only): short trail_soft Trails at the wingtips (plane) or rear corners (car), on while
	-- boosting. Lifetime BoostRules.TRAIL_LIFE keeps the ribbon shorter than the chase camera's distance.
	local boostTrails: { Trail }? = nil
	if string.find(model.Name, LocalPlayer.Name, 1, true) then
		local isCar = model:GetAttribute("IsCar") == true
		local x = if isCar then math.clamp(hull.Size.X * 0.5, 1.5, 4) else wingX
		local z = if isCar then math.clamp(hull.Size.Z * 0.5, 2, 5) else 0.8
		local list = {}
		for _, side in { -1, 1 } do
			local a0 = Instance.new("Attachment")
			a0.Name = "VfxBoostTrailA"
			a0.CFrame = CFrame.new(side * x, 0.18, z) -- v29 W1b A6: 40 % narrower (was +-0.3)
			a0.Parent = hull
			local a1 = Instance.new("Attachment")
			a1.Name = "VfxBoostTrailB"
			a1.CFrame = CFrame.new(side * x, -0.18, z)
			a1.Parent = hull
			local tr = Instance.new("Trail")
			tr.Name = "VfxBoostTrail"
			tr.Attachment0 = a0
			tr.Attachment1 = a1
			tr.Texture = tex("trail_soft")
			tr.Lifetime = BoostRules.TRAIL_LIFE
			tr.MinLength = 0.2
			tr.FaceCamera = true
			-- v29 W1b A6 (critic v29 island2 02/06/07: cream ribbons off the rear wheels dominated the foreground): unlit
			-- and mostly see-through (was LightEmission 1, alpha 0.15 at the root). Still on only while boosting.
			tr.LightEmission = 0
			tr.Color = cs(WHITE, racer or CYAN)
			tr.Transparency = ns({ { 0, 0.75 }, { 0.5, 0.87 }, { 1, 1 } })
			tr.WidthScale = ns({ { 0, 1.6 }, { 1, 0.2 } })
			tr.Enabled = false
			tr.Parent = hull
			table.insert(list, tr)
		end
		boostTrails = list
	end
	local light = Instance.new("PointLight")
	light.Name = "VfxEngineLight"
	light.Range = 14
	light.Brightness = 0
	light.Color = CYAN
	light.Shadows = false
	light.Parent = rear
	-- The wingtip speed_streak particle cards are gone (they read as flat translucent rectangles beside the vehicle): the
	-- world wind streaks are thin tapered Beams now (buildWind), for every vehicle.
	local streaks: { ParticleEmitter }? = nil
	-- Wingtip vortices / contrails (planes only): two world-space puffs per plane (left behind where they were emitted, so
	-- they fall back and away from the chase camera), rate from speed and bank in stepVortex. Soft and half transparent.
	local vortex: { ParticleEmitter }? = nil
	if model:GetAttribute("IsCar") ~= true then
		local list = {}
		local tint = AirFxRules.vortexTint(racer)
		for _, side in { -1, 1 } do
			local a = Instance.new("Attachment")
			a.Name = "VfxVortexAtt"
			a.CFrame = CFrame.new(side * wingX, 0, 0.8)
			a.Parent = hull
			table.insert(list, makeEmitter(a, "VfxVortex", {
				tex = "trail_soft", count = 0, lifetime = NumberRange.new(AirFxRules.VORTEX_LIFE * 0.9, AirFxRules.VORTEX_LIFE * 1.2), speed = NumberRange.new(0, 1),
				spread = Vector2.zero, size = ns({ { 0, 0.9 }, { 0.4, 2.2 }, { 1, 3.6 } }), transparency = ns({ { 0, 0.35 }, { 0.5, 0.65 }, { 1, 1 } }), -- v21: was 0.6/1.6/2.8 at 0.55/0.8: a hairline on a bright sky
				color = cs(tint), lightEmission = 0.1, rotation = NumberRange.new(0, 360), drag = 0.5, zOffset = -1,
			}, 0))
		end
		vortex = list
	end
	-- Void Dragon boost: small violet embers and star twinkles riding the wingtips and tail tip (LockedToPart, a couple of
	-- studs of drift and a short life, so nothing ever sits near the chase camera). Off until boosting (updateRig).
	local embers: { ParticleEmitter }? = nil
	if creature then
		local list = {}
		for _, spot in { Vector3.new(-wingX, 0.2, 0.8), Vector3.new(wingX, 0.2, 0.8), Vector3.new(0, 0.3, tailZ) } do
			local a = Instance.new("Attachment")
			a.Name = "VfxEmberAtt"
			a.CFrame = CFrame.new(spot) * CFrame.Angles(0, math.pi, 0)
			a.Parent = hull
			table.insert(list, makeEmitter(a, "VfxEmber", {
				tex = "ember", count = 0, lifetime = NumberRange.new(0.3, 0.5), speed = NumberRange.new(2, 5), spread = Vector2.new(25, 25),
				size = ns({ { 0, 0.34 }, { 1, 0.06 } }), transparency = ns({ { 0, 0.2 }, { 0.7, 0.5 }, { 1, 1 } }), color = cs(VIOLET, VIOLET_DEEP),
				lightEmission = 0.9, rotation = NumberRange.new(0, 360), locked = true,
			}, 0))
			table.insert(list, makeEmitter(a, "VfxStar", {
				tex = "star_twinkle", count = 0, lifetime = NumberRange.new(0.35, 0.55), speed = NumberRange.new(1, 3), spread = Vector2.new(60, 60),
				size = ns({ { 0, 0.5 }, { 0.5, 0.35 }, { 1, 0 } }), transparency = ns({ { 0, 0.3 }, { 1, 1 } }), color = cs(WHITE, VIOLET),
				lightEmission = 1, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-90, 90), locked = true,
			}, 0))
		end
		embers = list
	end
	rigs[model] = {
		model = model, hull = hull, racer = racer, exhaust = exhaust, vortex = vortex, rear = rear, fx = nil, fxNext = 0, fxTries = 0,
		vaporL = wingTrail(-wingX), vaporR = wingTrail(wingX), light = light, lastBoost = "None", trailRaw = nil, cosmetic = {},
		streaks = streaks, boostTrails = boostTrails, creature = creature, embers = embers,
	}
end

-- ---------------------------------------------------------------- particle exhaust flame
-- Owner: the mesh flames are rejected ("should be particle effects not actual models"; the plane's solid cone hid the
-- track). Each FlameNozzle* attachment (PlaneBuilder tail, CarBuilder tailpipes) now carries up to 3 ParticleEmitters:
-- core (fire_loop_8x8 flipbook), sparks (ember) and smoke (soft puff). ALL tuning lives in shared/FlameRules (top of that
-- file): rates, speeds, lifetimes, sizes, colours per state (pilot -> cruise by throttle, then boost, then overcharge).
-- Emission runs backwards along the nozzle (+Z, EmissionDirection Back); core is LockedToPart so it rides the tail, sparks
-- and smoke are left in the world as a trail. Emitters are Enabled only within FlameRules.CULL_DIST of the camera and when
-- LOW GRAPHICS is off (the smoke layer also stays off on a phone: Settings.heavySmoke). The boost-start ring is a
-- shockwave_8x8 ParticleEmitter on the first nozzle (no mesh left in the boost look); the flame_core/flame_outer/shock_ring
-- meshes (FxModelAssets) are retired and unused. Cost per nozzle: 3 emitters (+1 ring emitter on the first), Rate writes
-- only on a change > 0.5, look writes only while the heat/over blend is moving.
local FLAME_TRIES = 8 -- nozzle lookups before a hull (a boss, a model without nozzles) is given up on
local FLAME_LOOK_EPS = 0.01 -- heat/over/throttle change that triggers a look rewrite
local KICK_RATE_MUL = 2.2 -- core emission-rate overshoot right after a boost starts (decays over KICK_TIME)
local KICK_TIME = 0.3
local RING_OVER = Color3.new(0.6, 1, 0.75)
local flameRng = Random.new(2026)

local function seq3(c0: { number }, c1: { number }): ColorSequence
	return ColorSequence.new(Color3.new(c0[1], c0[2], c0[3]), Color3.new(c1[1], c1[2], c1[3]))
end

-- Builds the emitters for a rig once the vehicle's FlameNozzle* attachments exist (retried a few times for replication
-- order). A hull that never gets nozzles (boss) simply has no exhaust flame.
local function tryBuildFlames(rig: Rig, now: number)
	rig.fxNext = now + 0.5
	rig.fxTries += 1
	local nozzles: { Attachment } = {}
	for _, d in rig.model:GetDescendants() do
		if d:IsA("Attachment") and string.sub(d.Name, 1, 11) == "FlameNozzle" then
			table.insert(nozzles, d)
		end
	end
	if #nozzles == 0 then
		return
	end
	table.sort(nozzles, function(a, b)
		return a.Name < b.Name
	end)
	local flames: { Flame } = {}
	local sum = Vector3.zero
	for i, att in nozzles do
		local attr = att:GetAttribute("FlameScale")
		local scale: number = if type(attr) == "number" then attr else 1
		local layers: { FlameLayer } = {}
		for _, name in FlameRules.ORDER do
			local L = FlameRules.LAYERS[name]
			local pe = Instance.new("ParticleEmitter")
			pe.Name = "VfxFlame_" .. name
			FlipFx.apply(pe, L.tex)
			pe.Enabled = false
			pe.Rate = 0
			pe.EmissionDirection = Enum.NormalId.Back -- the nozzle's +Z is backwards
			pe.Orientation = Enum.ParticleOrientation.FacingCamera
			pe.LightEmission = L.lightEmission
			pe.LightInfluence = if L.lightEmission >= 0.45 then 0 else 1
			pe.LockedToPart = L.lockedToPart
			pe.Acceleration = Vector3.new(0, L.accel, 0)
			pe.Drag = L.drag
			pe.Rotation = NumberRange.new(0, 360)
			pe.RotSpeed = NumberRange.new(-60, 60)
			pe.Transparency = ns({ { 0, L.alpha0 }, { 0.4, L.alphaMid }, { 1, L.alpha1 } })
			pe.Parent = att
			table.insert(layers, { name = name, pe = pe, lastRate = -1 })
		end
		table.insert(flames, { nozzle = att, scale = scale, phase = i * 17.3 + flameRng:NextNumber(0, 50), layers = layers })
		sum += att.WorldPosition
	end
	-- Engine light sits between the nozzles, just behind their mouths.
	local mid = rig.hull.CFrame:PointToObjectSpace(sum / #nozzles)
	rig.rear.CFrame = CFrame.new(mid + Vector3.new(0, 0, 0.4)) * CFrame.Angles(0, math.pi, 0)
	-- Boost-start shockwave ring: faces back along the nozzle axis, rides the tail, one Emit per boost start.
	local ringPreset = ring(FlameRules.RING_D1, FlameRules.RING_TIME, cs(WHITE))
	ringPreset.locked = true
	local ringPe = makeEmitter(nozzles[1], "VfxBoostRing", ringPreset, 0)
	ringPe.EmissionDirection = Enum.NormalId.Back
	rig.fx = {
		flames = flames, ring = ringPe, thr = 0, heat = 0, over = 0, kick = 0,
		lThr = -1, lHeat = -1, lOver = -1, on = false,
	}
end

-- Boost start (rising edge, or standard -> overcharge): shockwave ring out of the nozzle, a rate overshoot and the wisp.
local function boostPulse(rig: Rig, over: boolean)
	local fx = rig.fx
	if fx and fx.on then
		fx.kick = 1
		fx.ring.Color = ColorSequence.new(if over then RING_OVER else WHITE)
		fx.ring:Emit(1)
	end
	if Settings.heavySmoke() and not rig.creature then
		rig.exhaust:Emit(6)
	end
end

local function setFlamesOn(fx: FlameFx, on: boolean)
	fx.on = on
	for _, f in fx.flames do
		for _, l in f.layers do
			l.pe.Enabled = on and (l.name ~= "smoke" or Settings.heavySmoke()) -- phone tier: no heavy smoke layer
			l.lastRate = -1
		end
	end
	if on then
		fx.lThr = -1 -- force a look rewrite
	end
end

local function stepFlames(rig: Rig, dt: number, boost: string, speed: number)
	local now = os.clock()
	local fx = rig.fx
	if not fx then
		if rig.fxTries < FLAME_TRIES and now >= rig.fxNext then
			tryBuildFlames(rig, now)
		end
		return
	end
	local cam = workspace.CurrentCamera
	local dist = if cam then (rig.hull.Position - cam.CFrame.Position).Magnitude else 0
	local active = FlameRules.active(dist, Settings.lowGraphics(), rig.remote == true and Settings.phoneTier())
	if active ~= fx.on then
		setFlamesOn(fx, active)
	end
	if not active then
		return
	end

	local boosting = boost ~= "None"
	fx.thr += (math.clamp(speed / FlameRules.FULL_SPEED, 0, 1) - fx.thr) * (1 - math.exp(-dt * 6))
	local k = 1 - math.exp(-dt * (if boosting then 14 else 4)) -- heats up fast, cools down slower
	fx.heat += ((if boosting then 1 else 0) - fx.heat) * k
	fx.over += ((if boost == "Overcharge" then 1 else 0) - fx.over) * k
	if fx.kick > 0 then
		fx.kick = math.max(0, fx.kick - dt / KICK_TIME)
	end

	-- Look (speed, lifetime, size, colour): rewritten only while the blend is still moving.
	if math.abs(fx.thr - fx.lThr) > FLAME_LOOK_EPS or math.abs(fx.heat - fx.lHeat) > FLAME_LOOK_EPS or math.abs(fx.over - fx.lOver) > FLAME_LOOK_EPS then
		fx.lThr, fx.lHeat, fx.lOver = fx.thr, fx.heat, fx.over
		for _, f in fx.flames do
			for _, l in f.layers do
				local lk = FlameRules.look(l.name, fx.thr, fx.heat, fx.over, f.scale * FlameRules.boostScale(f.scale, fx.heat, fx.over))
				local pe = l.pe
				pe.Speed = NumberRange.new(lk.speed * 0.85, lk.speed * 1.15)
				pe.Lifetime = NumberRange.new(lk.life * 0.8, lk.life * 1.2)
				pe.SpreadAngle = Vector2.new(lk.spread, lk.spread)
				pe.Size = ns({ { 0, lk.size0 }, { 1, lk.size1 } })
				pe.Color = seq3(lk.c0, lk.c1)
			end
		end
	end

	local kickMul = 1 + (KICK_RATE_MUL - 1) * fx.kick
	local pscale = Settings.particleScale() -- phone tier / LOW GRAPHICS / frame governor (perf review v21 PF-03)
	for _, f in fx.flames do
		for _, l in f.layers do
			local r = FlameRules.rate(l.name, fx.thr, fx.heat, fx.over, f.scale * FlameRules.boostScale(f.scale, fx.heat, fx.over), now, f.phase, pscale) * (if l.name == "core" then kickMul else 1)
			if math.abs(r - l.lastRate) > 0.5 then
				l.lastRate = r
				l.pe.Rate = r
			end
		end
	end

end

local function destroyFlames(rig: Rig)
	local fx = rig.fx
	if fx then
		for _, f in fx.flames do
			for _, l in f.layers do
				l.pe:Destroy()
			end
		end
		fx.ring:Destroy()
		rig.fx = nil
	end
end

-- Garage trail (MONETIZATION_PROPOSAL 2a): the owner's equipped trail as a ribbon pair at the wingtips (plane) or rear
-- corners (car), rebuilt only when their replicated loadout (player attribute Equipped) changes. Rivals see a longer
-- ribbon than the owner, whose ribbon fades before the chase camera like the vapor (GarageModel.trailLook).
local function syncCosmeticTrail(rig: Rig, isLocal: boolean)
	local uid = rig.model:GetAttribute("OwnerUserId")
	local owner = if type(uid) == "number" then Players:GetPlayerByUserId(uid) else nil
	local raw = if owner then owner:GetAttribute("Equipped") else nil
	-- a disguised race bot wears a Garage trail the server picked (model attribute CosmeticTrail, a catalog key)
	local botTrail = if owner == nil then rig.model:GetAttribute("CosmeticTrail") else nil
	if type(botTrail) == "string" and botTrail ~= "" then
		raw = string.format('{"trail":"%s"}', botTrail)
	end
	local key = if type(raw) == "string" then raw else ""
	if key == rig.trailRaw then
		return
	end
	rig.trailRaw = key
	for _, inst in rig.cosmetic do
		inst:Destroy()
	end
	table.clear(rig.cosmetic)
	local item = GarageModel.equipped(GarageModel.decodeLoadout(key), "trail")
	local style = item and item.trail
	if not style then
		return
	end
	local look = GarageModel.trailLook(style, isLocal, rig.model:GetAttribute("IsCar") == true)
	for _, side in { -1, 1 } do
		local a0 = Instance.new("Attachment")
		a0.Name = "VfxCosmeticTrailA0"
		a0.CFrame = CFrame.new(side * look.offsetX, look.offsetY + look.halfSpan, look.offsetZ)
		a0.Parent = rig.hull
		local a1 = Instance.new("Attachment")
		a1.Name = "VfxCosmeticTrailA1"
		a1.CFrame = CFrame.new(side * look.offsetX, look.offsetY - look.halfSpan, look.offsetZ)
		a1.Parent = rig.hull
		local tr = Instance.new("Trail")
		tr.Name = "VfxCosmeticTrail"
		tr.Attachment0 = a0
		tr.Attachment1 = a1
		tr.Texture = tex(look.texture)
		tr.Lifetime = look.lifetime
		tr.MinLength = 0.1
		tr.FaceCamera = true
		-- v29 W1b A3 (critic v29 forest1_02: a rival bot's Prism ribbon swept the frame as a wide magenta band): a rival's
		-- ribbon keeps its colours but is fainter, half as emissive and tapers to nothing; the owner's own is unchanged.
		tr.LightEmission = if isLocal then look.lightEmission else look.lightEmission * 0.5
		tr.Color = cs(rgb(look.color0[1], look.color0[2], look.color0[3]), rgb(look.color1[1], look.color1[2], look.color1[3]))
		tr.Transparency = if isLocal then ns({ { 0, 0.2 }, { 0.7, 0.65 }, { 1, 1 } }) else ns({ { 0, 0.45 }, { 0.6, 0.8 }, { 1, 1 } })
		tr.WidthScale = if isLocal then ns({ { 0, look.width }, { 1, 0.15 } }) else ns({ { 0, math.min(look.width, 1.2) }, { 1, 0 } })
		tr.Parent = rig.hull
		table.insert(rig.cosmetic, tr)
		table.insert(rig.cosmetic, a0)
		table.insert(rig.cosmetic, a1)
	end
end

local function updateRig(rig: Rig, dt: number, boost: string, speed: number, sharp: boolean, roll: boolean?)
	-- Boost state writes only on a change (no per-frame ColorSequence allocation).
	if boost ~= rig.lastBoost then
		local boosting = boost ~= "None"
		-- The flame itself is stepFlames below; here: the ring pulse + wisp on a boost start, the wisp stream, boost ribbons, the light.
		if boosting and (rig.lastBoost == "None" or boost == "Overcharge") then
			boostPulse(rig, boost == "Overcharge")
		end
		local wisp = boosting and Settings.heavySmoke() and not rig.creature
		rig.exhaust.Rate = if wisp then 10 else 0
		rig.exhaust.Enabled = wisp
		local bt = rig.boostTrails
		if bt then
			local trailOn = boosting and not Settings.lowGraphics()
			for _, tr in bt do
				tr.Enabled = trailOn
				tr.Color = if boost == "Overcharge" then cs(WHITE, GREEN) else cs(WHITE, if rig.creature then VIOLET else rig.racer or CYAN)
			end
		end
		local embers = rig.embers
		if embers then
			local per = Settings.particleScale()
			for i, pe in embers do
				local rate = if not boosting then 0 elseif i % 2 == 1 then 16 * per else 7 * per -- embers, then twinkles
				pe.Rate = rate * (if boost == "Overcharge" then 1.5 else 1)
				pe.Enabled = rate > 0
			end
		end
		rig.light.Brightness = if boost == "Overcharge" then 3 elseif boosting then 2.2 else 0
		rig.light.Color = if boost == "Overcharge" then GREEN elseif rig.creature then VIOLET else WARM -- the standard boost flame is orange now
	end
	stepFlames(rig, dt, boost, speed)
	-- v29 W1b A6: a car's vapor pair (re-seated at the rear tyres by CarController) shows only while drifting or
	-- boosting, never just for being fast; a plane keeps its speed rule.
	local isCar = rig.model:GetAttribute("IsCar") == true
	local vapor = if isCar then (sharp or boost ~= "None") else (sharp or speed > 150 or roll == true)
	rig.vaporL.Enabled = vapor
	rig.vaporR.Enabled = vapor
	-- Barrel roll (FlightController, REMARKABLE item 7): the wingtip vapor rides the rolling hull, so a longer, wider
	-- trail draws the corkscrew. Changed only on the edge, so no per-frame property writes.
	if (roll == true) ~= (rig.rolling == true) then
		rig.rolling = roll == true
		for _, tr in { rig.vaporL, rig.vaporR } do
			tr.Lifetime = if roll then 0.26 else 0.11
			tr.WidthScale = if roll then ns({ { 0, 3 }, { 1, 0.6 } }) else ns({ { 0, 1 }, { 1, 0.2 } })
			tr.Transparency = if roll then ns({ { 0, 0.25 }, { 0.6, 0.7 }, { 1, 1 } }) else ns({ { 0, 0.5 }, { 0.6, 0.85 }, { 1, 1 } })
		end
	end
	rig.lastBoost = boost
end

-- ---------------------------------------------------------------- speed lines
local speedGui: ScreenGui? = nil
local lines: { { img: ImageLabel, angle: number, phase: number } } = {}
local LINE_COUNT = 16
-- Peripheral vignette: four edge gradient frames (outer edge opaque, inner edge clear), fading in with speed. Edges only,
-- so the route and the next gate in the centre are never touched.
local VIGNETTE_COLOR = rgb(16, 44, 92)
local vignette: { Frame } = {}
local vigLevel = 0 -- smoothed opacity 0..VIGNETTE_MAX
local vigWritten = -1
-- World wind streaks: two thin emitter boxes that follow the camera, left and right of the view, streaks rush back past
-- the lens edges. Rate follows the speed fraction (not just boost).
type WindBeam = { beam: Beam, a0: Attachment, a1: Attachment, age: number, side: number, x: number, y: number, len: number }
local windBeams: { WindBeam } = {}
local windPart: Part? = nil -- one hidden anchored part holds every streak's two attachments
local windActive = 0
local windRng = Random.new(4242)

local function buildSpeedLines()
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallySpeedLines"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 5 -- under the HUD
	local rng = Random.new(77)
	for i = 1, LINE_COUNT do
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Image = tex("speed_line")
		img.AnchorPoint = Vector2.new(0, 0.5)
		img.Size = UDim2.fromScale(0.16, 0.005)
		img.ImageTransparency = 1
		img.Parent = sg
		local angle = (i - 1) / LINE_COUNT * math.pi * 2 + rng:NextNumber(-0.12, 0.12)
		img.Rotation = math.deg(angle) -- fixed per line: written once here, not every frame
		-- Keep the centre band (where the route and next gate sit) clear: lines start at 45% of the half-diagonal.
		table.insert(lines, { img = img, angle = angle, phase = rng:NextNumber() })
	end
	-- Edge vignette: each frame is a gradient from opaque (screen edge) to clear (toward the centre).
	local edges = {
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(BoostRules.EDGE_WIDTH, 1), rot = 0 }, -- left
		{ pos = UDim2.fromScale(1 - BoostRules.EDGE_WIDTH, 0), size = UDim2.fromScale(BoostRules.EDGE_WIDTH, 1), rot = 180 }, -- right
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(1, BoostRules.EDGE_WIDTH * 0.6), rot = 90 }, -- top
		{ pos = UDim2.fromScale(0, 1 - BoostRules.EDGE_WIDTH * 0.6), size = UDim2.fromScale(1, BoostRules.EDGE_WIDTH * 0.6), rot = 270 }, -- bottom
	}
	for i, e in edges do
		local f = Instance.new("Frame")
		f.Name = "SpeedVignette" .. tostring(i)
		f.BackgroundColor3 = VIGNETTE_COLOR
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Position = e.pos
		f.Size = e.size
		f.Visible = false
		local g = Instance.new("UIGradient")
		g.Rotation = e.rot
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = f
		f.Parent = sg
		table.insert(vignette, f)
	end
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	speedGui = sg
end

local function respawnWind(w: WindBeam)
	w.age = 0
	w.x, w.y, w.len = BoostRules.windSlot(w.side, windRng:NextNumber(), windRng:NextNumber(), windRng:NextNumber())
end

-- Thin streaks (BoostRules wind block): Beams whose width tapers tail -> head, fading at both ends, far from the camera.
local function buildWind(parent: Instance)
	local part = Instance.new("Part")
	part.Name = "VfxWindAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.new(0, -500, 0)
	part.Parent = parent
	windPart = part
	for i = 1, BoostRules.WIND_BEAMS do
		local a0 = Instance.new("Attachment")
		a0.Name = "VfxWindTail" .. tostring(i)
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Name = "VfxWindHead" .. tostring(i)
		a1.Parent = part
		local beam = Instance.new("Beam")
		beam.Name = "VfxWindStreak"
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.FaceCamera = true
		beam.Segments = 1
		beam.Width0 = 0
		beam.Width1 = 0
		beam.LightEmission = 0.7
		beam.LightInfluence = 0
		beam.Color = cs(WHITE, rgb(205, 240, 255))
		beam.Transparency = ns({ { 0, 1 }, { 0.45, 0.6 }, { 1, 0.78 } })
		beam.Enabled = false
		beam.Parent = part
		local w: WindBeam = { beam = beam, a0 = a0, a1 = a1, age = 0, side = if i % 2 == 1 then -1 else 1, x = 0, y = 0, len = 10 }
		respawnWind(w)
		w.age = windRng:NextNumber() * BoostRules.WIND_LIFE -- staggered, so they never fire in step
		table.insert(windBeams, w)
	end
end

local lineClock = 0
local linesHidden = true -- every line is at ImageTransparency 1 (built that way)
local function stepSpeedLines(dt: number, intensity: number)
	if not speedGui then
		return
	end
	lineClock += dt
	-- Below the threshold a line is at most 0.6% opaque: hide them all once and stop writing (perf review v21 PF-07: 32
	-- GUI property writes per frame for nothing at cruise speed).
	if not BoostRules.speedLinesVisible(intensity) then
		if not linesHidden then
			linesHidden = true
			for _, l in lines do
				l.img.ImageTransparency = 1
			end
		end
		return
	end
	linesHidden = false
	for _, l in lines do
		local t = (l.phase + lineClock * (1.6 + intensity)) % 1
		local r = 0.55 + t * 0.3
		local x, y = math.cos(l.angle), math.sin(l.angle)
		l.img.Position = UDim2.fromScale(0.5 + x * r * 0.62, 0.5 + y * r * 0.62)
		l.img.ImageTransparency = 1 - intensity * 0.2 * math.sin(t * math.pi)
	end
end

-- Vignette + wind streaks for the local vehicle's speed fraction (planes and cars share it; Vfx.step).
local function stepSpeedWorld(dt: number, speed: number, boosting: boolean)
	local frac = BoostRules.speedFrac(speed)
	local scale = Settings.particleScale()
	-- Vignette: smoothed, written only when it moved.
	local target = BoostRules.vignette(frac, boosting)
	vigLevel += (target - vigLevel) * (1 - math.exp(-dt * 5))
	if math.abs(vigLevel - vigWritten) > 0.01 or (vigLevel < 0.01 and vigWritten ~= 0) then
		vigWritten = if vigLevel < 0.01 then 0 else vigLevel
		for _, f in vignette do
			f.Visible = vigWritten > 0
			f.BackgroundTransparency = 1 - vigWritten
		end
	end
	-- Wind: a few thin tapered Beams in camera space, far ahead and out at the screen edges; none at cruise.
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local want = BoostRules.windBeams(BoostRules.windRate(frac, boosting), scale)
	if want == 0 and windActive == 0 then
		return
	end
	windActive = want
	local camCF = cam.CFrame
	for i, w in windBeams do
		if i > want then
			if w.beam.Enabled then
				w.beam.Enabled = false
			end
			continue
		end
		w.age += dt
		if w.age >= BoostRules.WIND_LIFE then
			respawnWind(w)
		end
		local head, env = BoostRules.windHead(w.age / BoostRules.WIND_LIFE)
		w.a1.WorldPosition = camCF:PointToWorldSpace(Vector3.new(w.x, w.y, -head))
		w.a0.WorldPosition = camCF:PointToWorldSpace(Vector3.new(w.x, w.y, -head - w.len))
		w.beam.Width1 = BoostRules.WIND_WIDTH * env
		if not w.beam.Enabled then
			w.beam.Enabled = true
		end
	end
	if want == 0 then
		windActive = 0
	end
end

-- ---------------------------------------------------------------- ambience
local ambientPart: Part? = nil
local ambientEmitters: { [string]: ParticleEmitter } = {}

local AMBIENT: { [string]: Preset } = {
	-- DINO (L61): embers big enough to read at phone size, drifting and swirling up through the cavern air.
	DINO = { tex = "ember", count = 0, lifetime = NumberRange.new(3, 5), speed = NumberRange.new(5, 11), spread = Vector2.new(35, 35),
		size = ns({ { 0, 0.8 }, { 0.5, 1.05 }, { 1, 0 } }), transparency = ns({ { 0, 1 }, { 0.15, 0.05 }, { 0.75, 0.25 }, { 1, 1 } }),
		color = cs(rgb(255, 222, 140), HOT), lightEmission = 1, accel = Vector3.new(1.5, 3.5, 0.5), shape = Enum.ParticleEmitterShape.Box },
	-- FOREST (L61): leaves big enough to read at phone size, sea-green to autumn gold, tumbling on the valley breeze.
	FOREST = { tex = "leaf", count = 0, lifetime = NumberRange.new(4, 7), speed = NumberRange.new(2, 5), spread = Vector2.new(30, 30),
		size = ns({ { 0, 1.05 }, { 1, 0.85 } }), transparency = ns({ { 0, 1 }, { 0.12, 0.05 }, { 0.85, 0.1 }, { 1, 1 } }),
		color = cs(rgb(132, 172, 86), rgb(232, 176, 70)), lightEmission = 0.05, accel = Vector3.new(6, -2.2, 2),
		rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-150, 150), shape = Enum.ParticleEmitterShape.Box },
	-- ISLAND (L61 late afternoon): warm sea-spray motes glowing in the low sun, drifting inland on the sea breeze, big
	-- enough to read at phone size (the old 0.35-stud twinkles never showed).
	ISLAND = { tex = "glow_soft", count = 0, lifetime = NumberRange.new(4, 6), speed = NumberRange.new(0.5, 1.8), spread = Vector2.new(180, 180),
		size = ns({ { 0, 0 }, { 0.25, 0.42 }, { 0.75, 0.34 }, { 1, 0 } }), transparency = ns({ { 0, 0.25 }, { 1, 0.75 } }),
		color = cs(rgb(255, 236, 196), rgb(255, 206, 150)), lightEmission = 0.8, accel = Vector3.new(2.2, 0.5, 0.8),
		shape = Enum.ParticleEmitterShape.Box },
	-- HUB (L61): blossom petals drifting on the sea breeze across the island (pink and cream, tumbling), not sparkles.
	HUB = { tex = "leaf", count = 0, lifetime = NumberRange.new(4, 7), speed = NumberRange.new(1.5, 3.5), spread = Vector2.new(40, 40),
		size = ns({ { 0, 0.4 }, { 1, 0.3 } }), transparency = ns({ { 0, 1 }, { 0.15, 0.25 }, { 0.85, 0.35 }, { 1, 1 } }), -- v28 W1.3: 0.7 -> 0.4 (a near petal read as a white disc)
		color = cs(rgb(255, 160, 192), rgb(255, 205, 200)), lightEmission = 0.1, accel = Vector3.new(4, -1.8, 1.5),
		rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-140, 140), shape = Enum.ParticleEmitterShape.Box },
	-- SPACE (L61 night): neon motes, cyan to hot pink, big enough to read at phone size, rising slowly in low gravity.
	SPACE = { tex = "glow_soft", count = 0, lifetime = NumberRange.new(4, 6), speed = NumberRange.new(0.5, 2), spread = Vector2.new(180, 180),
		size = ns({ { 0, 0 }, { 0.3, 0.75 }, { 0.7, 0.6 }, { 1, 0 } }), transparency = ns({ { 0, 0.15 }, { 1, 0.7 } }),
		color = cs(rgb(110, 236, 255), rgb(255, 110, 220)), lightEmission = 1, accel = Vector3.new(0.6, 0.9, 0.3),
		shape = Enum.ParticleEmitterShape.Box },
	-- SNOW (L61): drifting powder on a cross wind, big enough to read at phone size, sparkling where the sun catches it.
	SNOW = { tex = "snowflake", count = 0, lifetime = NumberRange.new(4, 6), speed = NumberRange.new(3, 6), spread = Vector2.new(25, 25),
		size = ns({ { 0, 0.5 }, { 0.5, 0.45 }, { 1, 0.3 } }), transparency = ns({ { 0, 1 }, { 0.12, 0.15 }, { 0.8, 0.3 }, { 1, 1 } }),
		color = cs(Color3.new(1, 1, 1), rgb(220, 238, 255)), lightEmission = 0, accel = Vector3.new(6, -4.5, 2), -- v28 W1.3: size 0.85 / emission 0.45 -> 0.5 / 0
		rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-90, 90), shape = Enum.ParticleEmitterShape.Box },
}

-- Second ambience layer per zone (L61): FOREST pollen and dandelion fluff glowing in the low afternoon sun.
local AMBIENT_EXTRA: { [string]: { preset: Preset, rate: number } } = {
	-- SPACE (L61 night): violet star-dust twinkles drifting down through the neon light.
	SPACE = { rate = 16, preset = { tex = "star_twinkle", count = 0, lifetime = NumberRange.new(3, 5), speed = NumberRange.new(0.5, 1.5),
		spread = Vector2.new(180, 180), size = ns({ { 0, 0 }, { 0.25, 0.42 }, { 0.75, 0.3 }, { 1, 0 } }),
		transparency = ns({ { 0, 0.2 }, { 1, 0.75 } }), color = cs(rgb(196, 160, 255), rgb(150, 220, 255)), lightEmission = 1,
		rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-60, 60), accel = Vector3.new(0.4, -0.8, 0.2),
		shape = Enum.ParticleEmitterShape.Box } },
	-- ISLAND (L61): hibiscus petals and palm-leaf bits tumbling on the breeze, coral to cream.
	ISLAND = { rate = 10, preset = { tex = "leaf", count = 0, lifetime = NumberRange.new(4, 7), speed = NumberRange.new(1.5, 3.5),
		spread = Vector2.new(40, 40), size = ns({ { 0, 0.55 }, { 1, 0.45 } }), transparency = ns({ { 0, 1 }, { 0.15, 0.1 }, { 0.85, 0.2 }, { 1, 1 } }),
		color = cs(rgb(240, 120, 96), rgb(255, 226, 186)), lightEmission = 0.1, accel = Vector3.new(5, -1.8, 1.5),
		rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-150, 150), shape = Enum.ParticleEmitterShape.Box } },
	-- HUB: dust motes hanging in the god-ray light, slow and warm (PortalTexAssets.mote is still id 0, so glow_soft).
	-- v21: 0.3-stud additive pale motes were invisible on the sunlit plaza; larger, warmer and half blended, a few more of them.
	HUB = { rate = 20, preset = { tex = "glow_soft", count = 0, lifetime = NumberRange.new(4, 6), speed = NumberRange.new(0.3, 1),
		spread = Vector2.new(180, 180), size = ns({ { 0, 0 }, { 0.25, 0.6 }, { 0.75, 0.5 }, { 1, 0 } }),
		transparency = ns({ { 0, 0.2 }, { 1, 0.7 } }), color = cs(rgb(255, 214, 130), rgb(240, 160, 80)), lightEmission = 0.3,
		accel = Vector3.new(0.8, 0.5, 0.3), shape = Enum.ParticleEmitterShape.Box } },
	FOREST = { rate = 22, preset = { tex = "glow_soft", count = 0, lifetime = NumberRange.new(4, 6), speed = NumberRange.new(0.5, 1.5),
		spread = Vector2.new(180, 180), size = ns({ { 0, 0 }, { 0.25, 0.32 }, { 0.75, 0.26 }, { 1, 0 } }),
		transparency = ns({ { 0, 0.25 }, { 1, 0.7 } }), color = cs(rgb(255, 238, 178), rgb(255, 214, 140)), lightEmission = 0.7,
		accel = Vector3.new(1.5, 0.4, 0.6), shape = Enum.ParticleEmitterShape.Box } },
}
local ambientExtras: { [string]: ParticleEmitter } = {}

local currentZone: string? = nil
local meadowSkimClock = 0
local snowPuffClock = 1.5
local snowSkimClock = 0
local localHull: BasePart? = nil
local SKIM_CAM_CLEAR = 24 -- no skim puff this close to the camera (a low pass under a dipping chase camera)
local SKIM_HEIGHT = 22 -- the SNOW-1 line is 16 over the river ice: low passes over ice and snow kick powder
local SKIM_MATERIALS = { [Enum.Material.Snow] = true, [Enum.Material.Ice] = true, [Enum.Material.Glacier] = true }
local skimParams = RaycastParams.new()
skimParams.FilterType = Enum.RaycastFilterType.Include

local AMBIENT_RATE = 34

function Vfx.setZone(zone: string?)
	currentZone = zone
	local ambienceOn = not Settings.lowGraphics()
	-- The box follows the camera, so every particle is in view: rates go through particleScale (phone tier 0.6, frame
	-- governor 0.4; perf review v21 PF-03). LOW GRAPHICS still switches the ambience off.
	local pscale = Settings.particleScale()
	for z, pe in ambientEmitters do
		pe.Enabled = z == zone and ambienceOn
		pe.Rate = AMBIENT_RATE * pscale
	end
	if zone and AMBIENT[zone] and not ambientEmitters[zone] then
		if not ambientPart then
			local a = Instance.new("Part")
			a.Name = "VfxAmbientVolume"
			a.Anchored = true
			a.CanCollide = false
			a.CanQuery = false
			a.CanTouch = false
			a.Transparency = 1
			a.Size = Vector3.new(170, 30, 170)
			a.Parent = poolFolder or workspace
			ambientPart = a
		end
		local p = AMBIENT[zone]
		local pe = makeEmitter(ambientPart :: Part, "VfxAmbient_" .. zone, p, AMBIENT_RATE * pscale)
		pe.EmissionDirection = if zone == "DINO" then Enum.NormalId.Top else Enum.NormalId.Bottom
		pe.Enabled = ambienceOn
		ambientEmitters[zone] = pe
		local extra = AMBIENT_EXTRA[zone]
		if extra then
			local ex = makeEmitter(ambientPart :: Part, "VfxAmbient2_" .. zone, extra.preset, extra.rate * pscale)
			ex.Enabled = ambienceOn
			ambientExtras[zone] = ex
		end
	end
	for z, pe in ambientExtras do
		pe.Enabled = z == zone and ambienceOn
		local extra = AMBIENT_EXTRA[z]
		if extra then
			pe.Rate = extra.rate * pscale
		end
	end
end

-- LOW GRAPHICS flipped in the Settings panel (or the frame governor lowered the particle scale): the zone ambience
-- follows at once.
Settings.onChanged(function(key: string)
	if key == "lowGraphics" or key == "particleScale" then
		Vfx.setZone(currentZone)
	end
end)

-- SNOW ambience burst: now and then a snow_burst powder puff well off to one side of the view (28-50 studs lateral at
-- 60 ahead, below eye level), so it reads as wind lifting snow and never sits on the route in the centre.
local function stepSnowPuffs(dt: number)
	if currentZone ~= "SNOW" then
		return
	end
	snowPuffClock -= dt
	local cam = workspace.CurrentCamera
	if snowPuffClock > 0 or not cam then
		return
	end
	snowPuffClock = 1.8 + math.random() * 1.4
	local c = cam.CFrame
	local side = if math.random() < 0.5 then -1 else 1
	local at = c.Position + c.LookVector * 60 + c.RightVector * side * (28 + math.random() * 22) + Vector3.new(0, -4 - math.random() * 8, 0)
	Vfx.burst("snowPuff", CFrame.lookAt(at, at + Vector3.yAxis))
end

-- FOREST skim (L61): while the local plane is low over the meadows (and the dirt under the road), leaves and grass
-- blades whip up behind it every ~0.16 s; over the wheat fields it is golden chaff and a dust puff.
local MEADOW_SKIM_HEIGHT = 24
local MEADOW_MATERIALS = { [Enum.Material.Grass] = "meadowSkim", [Enum.Material.Mud] = "meadowSkim",
	[Enum.Material.Ground] = "meadowSkim", [Enum.Material.LeafyGrass] = "wheatSkim" }
local function stepMeadowSkim(dt: number)
	local hull = localHull
	if currentZone ~= "FOREST" or not hull or not hull.Parent then
		return
	end
	meadowSkimClock -= dt
	if meadowSkimClock > 0 then
		return
	end
	meadowSkimClock = 0.16
	skimParams.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(hull.Position, Vector3.new(0, -MEADOW_SKIM_HEIGHT, 0), skimParams)
	local kind = hit and MEADOW_MATERIALS[hit.Material]
	if hit and kind then
		local back = hull.CFrame.LookVector * -6
		local at = hit.Position + Vector3.new(back.X, 0.8, back.Z)
		Vfx.burst(kind, CFrame.lookAt(at, at + Vector3.yAxis), if hit.Distance < 14 then 1.4 else 1)
	end
end

-- ISLAND sand kick (L61): while the local car rolls on Sand terrain (off the paved road: the deck parts are not in the
-- ray filter, so on the road the ray finds the sand only well under the wheels), a dust puff behind it every ~0.14 s.
local sandKickClock = 0
local sandKickLast: Vector3? = nil
local SAND_KICK_HEIGHT = 3.4 -- hull ride 1.9 over sand; on the road the hull is 3.6 over the shoulder sand
local function stepSandKick(dt: number)
	local hull = localHull
	if currentZone ~= "ISLAND" or not hull or not hull.Parent then
		return
	end
	sandKickClock -= dt
	if sandKickClock > 0 then
		return
	end
	-- speed from the hull's own motion (the car may be kinematic: AssemblyLinearVelocity can read 0)
	local pos = hull.Position
	local last = sandKickLast
	sandKickLast = pos
	sandKickClock = 0.14
	if not last or (pos - last).Magnitude < 25 * 0.14 then
		return
	end
	skimParams.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(hull.Position, Vector3.new(0, -SAND_KICK_HEIGHT, 0), skimParams)
	if hit and hit.Material == Enum.Material.Sand then
		local back = hull.CFrame.LookVector * -5
		local at = hit.Position + Vector3.new(back.X, 0.6, back.Z)
		Vfx.burst("sandKick", CFrame.lookAt(at, at + Vector3.yAxis))
	end
end

-- Birds (L61 gulls, owner: "the flying bird is crude"): each bird is the fx_v1 gull_body plus gull_wing_L/R meshes (server-made
-- templates in ReplicatedStorage.SkyRallyBirdTemplates, see server/kit/WorldArt; clients cannot LoadAsset), wheeling 30-70
-- studs over the scene ahead of the camera, wings flapping about the body's Z axis from the shoulder joint, with glide
-- phases between flap bursts, real shadows on the ground. A small species table widens the zone gate: gulls on ISLAND and
-- HUB, swallows (dark blue) on FOREST, pale snow birds on SNOW, a few dark birds high over the DINO canyon, none in SPACE.
-- One loop and one BulkMoveTo for all birds (<= MAX_BIRDS x 3 parts), nothing created per frame; the flock is rebuilt only
-- when the zone changes and hidden under a roof (the cavern) or when the zone has none.
local BIRD_TEMPLATES = "SkyRallyBirdTemplates"
local MAX_BIRDS = 8
-- Meshes are authored in glTF space (beak toward -Z, right wing toward +X, pivot at the file origin) while a Part sits at its
-- bounding-box centre; Roblox imports a GLB turned 180 deg about Y (BossConfig.yawOffset, verified on a rigged GLB), so a
-- part's CFrame is  bird * pose * CFrame.new(bbox centre) * BIRD_IMPORT_FIX.  TODO(Studio): if the birds fly tail first or the
-- wings float off the body, set BIRD_IMPORT_FIX to CFrame.identity (the importer did not turn static meshes).
local BIRD_IMPORT_FIX = CFrame.Angles(0, math.pi, 0)
-- fx_v1 manifest (studs at scale 1, glTF space): bbox centres and the shoulder joints in body space.
local BODY_C = Vector3.new(0, 0.0275, 0)
local WING_L_C = Vector3.new(-0.85, 0.124, 0.0895)
local WING_R_C = Vector3.new(0.85, 0.124, 0.0895)
local SHOULDER_L = Vector3.new(-0.2, 0.11, 0)
local SHOULDER_R = Vector3.new(0.2, 0.11, 0)
-- Hand-built fallback when the templates never arrive: same pose maths, block geometry (no import turn, no bbox offset).
local FALLBACK_BODY = Vector3.new(0.7, 0.6, 2.2)
local FALLBACK_WING = Vector3.new(1.7, 0.15, 1.1)
local FLAP_PERIOD = 4.2 -- one flap burst + one glide per period
local FLAP_LEN = 2.0
local FLAP_EASE = 0.3
local GLIDE_ANGLE = math.rad(9) -- wings held slightly up while gliding

type Species = { scale: number, tint: Color3?, hz: number, amp: number }
local SPECIES: { [string]: Species } = {
	gull = { scale = 1.3, tint = nil, hz = 1.7, amp = math.rad(48) },
	swallow = { scale = 0.85, tint = rgb(44, 62, 110), hz = 3.4, amp = math.rad(52) }, -- quick, small, dark blue
	snowbird = { scale = 1.0, tint = rgb(226, 230, 238), hz = 2.4, amp = math.rad(46) }, -- white-grey
	crow = { scale = 1.15, tint = rgb(54, 48, 58), hz = 1.4, amp = math.rad(42) }, -- slow dark birds, high
}
type Flock = { species: string, count: number, radius: number, height: number }
local ZONE_FLOCKS: { [string]: { Flock } } = {
	ISLAND = { { species = "gull", count = 6, radius = 26, height = 30 } },
	HUB = { { species = "gull", count = 4, radius = 30, height = 34 } },
	FOREST = { { species = "swallow", count = 5, radius = 22, height = 26 } },
	SNOW = { { species = "snowbird", count = 4, radius = 28, height = 32 } },
	DINO = { { species = "crow", count = 3, radius = 40, height = 75 } }, -- high over the canyon, well above the route
}

type Bird = {
	body: BasePart,
	wl: BasePart,
	wr: BasePart,
	k: number, -- species scale
	mesh: boolean,
	r: number, -- orbit radius
	h: number, -- orbit height over the camera
	w: number, -- signed angular speed (rad/s)
	a: number, -- orbit angle
	t: number, -- clock (bob and flap)
	phase: number, -- flap cycle offset, so the flock never beats in step
	hz: number,
	amp: number,
}
local birds: { Bird } = {}
local birdFolder: Folder? = nil
local birdZone: string? = nil
local birdCentre: Vector3? = nil
local birdRoofClock = 0
local birdHidden = true
local birdWanted = 0 -- seconds a flock has been wanted while the templates were not ready
local birdTpl: { body: MeshPart, wl: MeshPart, wr: MeshPart }? = nil
local birdTplFailed = false
local birdParts: { BasePart } = table.create(MAX_BIRDS * 3)
local birdCFs: { CFrame } = table.create(MAX_BIRDS * 3)
local birdParams = RaycastParams.new()
birdParams.FilterType = Enum.RaycastFilterType.Include

local function findBirdTemplates(): boolean
	local f = ReplicatedStorage:FindFirstChild(BIRD_TEMPLATES)
	if not f then
		return false
	end
	local b, l, r = f:FindFirstChild("GullBody"), f:FindFirstChild("GullWingL"), f:FindFirstChild("GullWingR")
	if b and l and r and b:IsA("MeshPart") and l:IsA("MeshPart") and r:IsA("MeshPart") then
		birdTpl = { body = b, wl = l, wr = r }
		return true
	end
	return false
end

local function birdPart(tpl: MeshPart?, name: string, fallbackSize: Vector3, k: number, tint: Color3?, parent: Instance): BasePart
	local p: BasePart
	if tpl then
		local m = tpl:Clone()
		m.Size = tpl.Size * k
		p = m
	else
		local b = Instance.new("Part")
		b.Material = Enum.Material.SmoothPlastic
		b.Size = fallbackSize * k
		p = b
	end
	p.Name = name
	p.Color = tint or (if tpl then Color3.new(1, 1, 1) else rgb(240, 240, 236))
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = parent
	return p
end

local function clearBirds()
	if birdFolder then
		birdFolder:Destroy()
		birdFolder = nil
	end
	table.clear(birds)
	table.clear(birdParts)
	table.clear(birdCFs)
	birdCentre = nil
	birdHidden = true
end

local function buildBirds(zone: string)
	clearBirds()
	birdZone = zone
	local f = Instance.new("Folder")
	f.Name = "VfxBirds"
	-- Parented by the first roof check below (this very frame), so a flock under a roof never shows at the origin.
	birdFolder = f
	birdRoofClock = 0
	local n = 0
	local flocks: { Flock } = ZONE_FLOCKS[zone]
	for _, flock in flocks do
		local sp = SPECIES[flock.species]
		for i = 1, flock.count do
			if n >= MAX_BIRDS then
				break
			end
			n += 1
			local tpl = birdTpl
			local bird: Bird = {
				body = birdPart(if tpl then tpl.body else nil, "BirdBody", FALLBACK_BODY, sp.scale, sp.tint, f),
				wl = birdPart(if tpl then tpl.wl else nil, "BirdWingL", FALLBACK_WING, sp.scale, sp.tint, f),
				wr = birdPart(if tpl then tpl.wr else nil, "BirdWingR", FALLBACK_WING, sp.scale, sp.tint, f),
				k = sp.scale,
				mesh = tpl ~= nil,
				r = flock.radius + i * 6,
				h = flock.height + (i % 3) * 6,
				w = (0.28 + 0.05 * (i % 3)) * (if i % 2 == 0 then 1 else -1),
				a = i * 1.1 + n,
				t = i * 0.7,
				phase = i * 1.37,
				hz = sp.hz * (0.92 + 0.05 * (i % 3)),
				amp = sp.amp,
			}
			table.insert(birds, bird)
			birdParts[#birdParts + 1] = bird.body
			birdParts[#birdParts + 1] = bird.wl
			birdParts[#birdParts + 1] = bird.wr
		end
	end
	table.move(table.create(#birdParts, CFrame.identity), 1, #birdParts, 1, birdCFs)
end

local function smooth01(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

local function stepBirds(dt: number)
	local zone = currentZone
	local cam = workspace.CurrentCamera
	local flocks = if zone then ZONE_FLOCKS[zone] else nil
	if not flocks or not cam then
		if birdFolder then
			clearBirds()
			birdZone = nil
		end
		return
	end
	if birdZone ~= zone then
		-- Zone change: drop the old flock; the new one is built below once the templates are ready (or have timed out).
		clearBirds()
		birdZone = nil
	end
	if not birdFolder then
		if not birdTpl and not birdTplFailed and not findBirdTemplates() then
			birdWanted += dt
			if birdWanted > 30 then
				birdTplFailed = true -- server never published them: block birds rather than none
			else
				return
			end
		end
		buildBirds(zone :: string)
	end
	birdRoofClock -= dt
	if birdRoofClock <= 0 then
		birdRoofClock = 0.5
		birdParams.FilterDescendantsInstances = { workspace.Terrain }
		local roof = workspace:Raycast(cam.CFrame.Position, Vector3.new(0, 120, 0), birdParams)
		local hide = roof ~= nil
		if hide ~= birdHidden then
			birdHidden = hide
			;(birdFolder :: Folder).Parent = if hide then nil else (poolFolder or workspace)
		end
	end
	if birdHidden then
		return
	end
	local look = cam.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zAxis
	local target = cam.CFrame.Position + flat * 110
	local c = birdCentre
	if not c or (c - target).Magnitude > 400 then
		c = target
	else
		c = c:Lerp(target, math.min(1, dt * 0.25))
	end
	birdCentre = c
	local i = 0
	for _, g in birds do
		g.a += g.w * dt
		g.t += dt
		local pos = (c :: Vector3) + Vector3.new(math.cos(g.a) * g.r, g.h + math.sin(g.t * 0.6 + g.phase) * 3, math.sin(g.a) * g.r)
		local tangent = Vector3.new(-math.sin(g.a), 0, math.cos(g.a)) * (if g.w > 0 then 1 else -1)
		local bank = if g.w > 0 then -0.35 else 0.35
		local root = CFrame.lookAt(pos, pos + tangent) * CFrame.Angles(0, 0, bank)
		-- Flap burst (eased in and out) then a glide with the wings held slightly up; R wing up = +theta about Z, L = -theta.
		local cycle = (g.t + g.phase) % FLAP_PERIOD
		local env = smooth01(cycle / FLAP_EASE) * (1 - smooth01((cycle - (FLAP_LEN - FLAP_EASE)) / FLAP_EASE))
		local theta = GLIDE_ANGLE * (1 - env) + env * g.amp * math.sin(g.t * g.hz * math.pi * 2)
		local k = g.k
		local fix = if g.mesh then BIRD_IMPORT_FIX else CFrame.identity
		local bodyC = if g.mesh then BODY_C else Vector3.zero
		local wlC = if g.mesh then WING_L_C else Vector3.new(-FALLBACK_WING.X * 0.5, 0, 0)
		local wrC = if g.mesh then WING_R_C else Vector3.new(FALLBACK_WING.X * 0.5, 0, 0)
		local sl = if g.mesh then SHOULDER_L else Vector3.new(-0.3, 0.1, 0)
		local sr = if g.mesh then SHOULDER_R else Vector3.new(0.3, 0.1, 0)
		birdCFs[i + 1] = root * CFrame.new(bodyC * k) * fix
		birdCFs[i + 2] = root * CFrame.new(sl * k) * CFrame.Angles(0, 0, -theta) * CFrame.new(wlC * k) * fix
		birdCFs[i + 3] = root * CFrame.new(sr * k) * CFrame.Angles(0, 0, theta) * CFrame.new(wrC * k) * fix
		i += 3
	end
	workspace:BulkMoveTo(birdParts, birdCFs, Enum.BulkMoveMode.FireCFrameChanged)
end

-- SNOW skim: while the local plane is low over snow, ice or glacier, a powder kick at the ground under it every ~0.12 s.
local function stepSnowSkim(dt: number)
	local hull = localHull
	if currentZone ~= "SNOW" or not hull or not hull.Parent then
		return
	end
	snowSkimClock -= dt
	if snowSkimClock > 0 then
		return
	end
	snowSkimClock = 0.12
	skimParams.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(hull.Position, Vector3.new(0, -SKIM_HEIGHT, 0), skimParams)
	if hit and SKIM_MATERIALS[hit.Material] then
		local back = hull.CFrame.LookVector * -4
		local at = hit.Position + Vector3.new(back.X, 0.5, back.Z)
		local cam = workspace.CurrentCamera
		if cam and (cam.CFrame.Position - at).Magnitude < SKIM_CAM_CLEAR then
			return -- owner rule: no effect over the chase camera
		end
		Vfx.burst("snowSkim", CFrame.lookAt(at, at + Vector3.yAxis), if hit.Distance < 12 then 1.5 else 1)
	end
end

-- ---------------------------------------------------------------- boss fx
-- Thunderwright's tesla coils (any boss rig with Coil* bones): each leaf Coil bone gets a looping electric_arc_4x4
-- crackle (a Bone is an Attachment, so the emitter rides the animated coil) and a lightning_bolt_2x2 emitter that throws
-- one bolt (FlipbookMode Random: one of the four variants) from a random coil every 1.2-2.6 s. Off beyond COIL_RANGE of
-- the camera. Sizes scale with BossConfig.length (44 studs -> 4-stud arcs, 13-stud bolts).
type BossFx = { arcs: { ParticleEmitter }, bolts: { ParticleEmitter }, nextBolt: number, tries: number, nextScan: number, on: boolean }
local bossFx: { [Model]: BossFx } = {}
local COIL_RANGE = 400

local function bossLength(model: Model): number
	local boss = BossConfig.forZone(model:GetAttribute("BossZone") :: string?)
	return if boss then boss.length else 44
end

local function scanCoils(model: Model, fx: BossFx)
	local len = bossLength(model)
	for _, d in model:GetDescendants() do
		if d:IsA("Bone") and string.sub(d.Name, 1, 4) == "Coil" then
			local leaf = true
			for _, c in d:GetChildren() do
				if c:IsA("Bone") and string.sub(c.Name, 1, 4) == "Coil" then
					leaf = false
				end
			end
			if leaf then
				table.insert(fx.arcs, makeEmitter(d, "VfxCoilArc", {
					tex = "electric_arc_4x4", count = 0, lifetime = NumberRange.new(0.4, 0.6), speed = NumberRange.new(0), spread = Vector2.zero,
					size = ns({ { 0, len * 0.08 }, { 1, len * 0.1 } }), transparency = ns({ { 0, 0.2 }, { 0.7, 0.3 }, { 1, 1 } }), color = cs(WHITE),
					lightEmission = 0.6, rotation = NumberRange.new(0, 360), locked = true, zOffset = 0.5,
				}, 5))
				table.insert(fx.bolts, makeEmitter(d, "VfxCoilBolt", {
					tex = "lightning_bolt_2x2", count = 0, lifetime = NumberRange.new(0.15, 0.25), speed = NumberRange.new(0), spread = Vector2.zero,
					size = ns({ { 0, len * 0.3 }, { 1, len * 0.3 } }), transparency = ns({ { 0, 0 }, { 1, 0.3 } }), color = cs(WHITE),
					lightEmission = 0.7, orientation = UPRIGHT, locked = true, zOffset = 1,
				}, 0))
			end
		end
	end
end

local function stepBoss(model: Model, now: number)
	local fx = bossFx[model]
	if not fx then
		fx = { arcs = {}, bolts = {}, nextBolt = now + 1.5, tries = 0, nextScan = now, on = true }
		bossFx[model] = fx
	end
	if #fx.arcs == 0 then
		-- The skinned mesh can replicate after the model: retry for ~20 s, then give up (a boss without coils).
		if fx.tries < 20 and now >= fx.nextScan then
			fx.tries += 1
			fx.nextScan = now + 1
			scanCoils(model, fx)
		end
		return
	end
	local cam = workspace.CurrentCamera
	local hull = model.PrimaryPart
	local near = cam ~= nil and hull ~= nil and (hull.Position - cam.CFrame.Position).Magnitude < COIL_RANGE
	if near ~= fx.on then
		fx.on = near
		for _, pe in fx.arcs do
			pe.Enabled = near
		end
	end
	if near and now >= fx.nextBolt then
		fx.nextBolt = now + 1.2 + math.random() * 1.4
		fx.bolts[math.random(1, #fx.bolts)]:Emit(1)
	end
end

-- Boss intro aura: a magic_swirl_8x8 vortex (looping at 30 fps, kept white: the sheet is authored violet/magenta/cyan
-- and Color multiplies) locked behind the boss for the intro sweep, then it winds down. Grid hold only, so it never
-- covers a live route.
function Vfx.bossAura(model: Model, seconds: number)
	local hull = model.PrimaryPart
	if not hull or hull:FindFirstChild("VfxBossAuraAt") then
		return
	end
	local len = bossLength(model)
	local at = Instance.new("Attachment") -- a point at the hull centre, so the swirls stay concentric behind the boss
	at.Name = "VfxBossAuraAt"
	at.Parent = hull
	local pe = makeEmitter(at, "VfxBossAura", {
		tex = "magic_swirl_8x8", count = 0, lifetime = NumberRange.new(2), speed = NumberRange.new(0), spread = Vector2.zero,
		size = ns({ { 0, len * 0.5 }, { 0.5, len * 0.7 }, { 1, len * 0.75 } }), transparency = ns({ { 0, 1 }, { 0.2, 0.35 }, { 0.8, 0.45 }, { 1, 1 } }),
		color = cs(WHITE), lightEmission = 0.6, rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-20, 20), locked = true, zOffset = -4,
	}, 1.2)
	pe:Emit(1)
	-- Stop 0.6 s before hand-back: the last 2 s swirl is gone by GO (hand-back is 1.4 s before GO).
	task.delay(math.max(0.5, seconds - 0.6), function()
		pe.Enabled = false
	end)
	task.delay(math.max(0.5, seconds) + 2.5, function()
		at:Destroy()
	end)
end

-- Boost ignite punch state (local vehicle): see Vfx.boostPunch below.
local punchT = -1 -- seconds since the punch started, -1 = idle
local punchOver = false
local pendingTrauma = 0
local tintFrames = 0
local tint: ColorCorrectionEffect? = nil

local function stepPunch(dt: number)
	if punchT >= 0 then
		punchT += dt
		if punchT >= BoostRules.punchDuration() then
			punchT = -1
		end
	end
	if tintFrames > 0 then
		tintFrames -= 1
		local t = tint
		if tintFrames == 0 and t then
			t.Enabled = false
		end
	end
end

-- ---------------------------------------------------------------- per-frame
type FrameState = { speed: number, boost: string, sharp: boolean, hullCF: CFrame?, roll: boolean? }

local function planeState(model: Model): (string, number)
	local b = model:GetAttribute("BoostState")
	local s = model:GetAttribute("Speed")
	return (if type(b) == "string" then b else "None"), (if type(s) == "number" then s else 110)
end

-- Survival / water battles: an entrant is OUT when its vehicle (bots) or its owner (players) carries BattleOut.
local function isOut(model: Model): boolean
	if model:GetAttribute("BattleOut") == true then
		return true
	end
	local uid = model:GetAttribute("OwnerUserId")
	local owner = if type(uid) == "number" then Players:GetPlayerByUserId(uid) else nil
	return owner ~= nil and owner:GetAttribute("BattleOut") == true
end

-- Wingtip vortices: rate from speed, bank and roll; remote planes only in range, outside the lens, desktop only.
-- Returns true when a remote plane is emitting (the caller counts them against the cap).
local function stepVortex(rig: Rig, speed: number, sharp: boolean, roll: boolean, isLocal: boolean, camPos: Vector3?, remoteOn: number): boolean
	local list = rig.vortex
	if not list then
		return false
	end
	local scale = Settings.particleScale()
	local allowed = isLocal or (camPos ~= nil and AirFxRules.remoteVortexAllowed((rig.hull.Position - camPos).Magnitude, scale, remoteOn))
	local rate = 0
	if allowed then
		local bankT = math.abs(math.asin(math.clamp(rig.hull.CFrame.RightVector.Y, -1, 1))) / (math.pi * 0.5)
		rate = AirFxRules.vortexRate(speed, bankT, sharp, roll, scale)
	end
	if rate ~= rig.vortexRate then
		rig.vortexRate = rate
		for _, pe in list do
			pe.Rate = rate
			pe.Enabled = rate > 0
		end
	end
	return rate > 0 and not isLocal
end

-- Slipstream (cosmetic only, no physics): the nearest rival ahead inside a narrow cone leaves a wake: (desktop) two thin tapered
-- Trails off the rival's rear corners (v29 A3: the edge-box streak cards are gone). Fades in over 0.3 s, lingers 0.4 s.
local draftLevel = 0
local draftHold = 0
local draftRival: Rig? = nil
local function setDraftTrails(rig: Rig, on: boolean)
	local trails = rig.draftTrails
	if not trails then
		if not on then
			return
		end
		local made: { Trail } = {}
		for _, side in { -1, 1 } do
			local a0 = Instance.new("Attachment")
			a0.Name = "VfxDraftA"
			a0.CFrame = CFrame.new(side * 3.2, 0.2, 5.5) -- v29 A3: 0.4 wide (was 0.5)
			a0.Parent = rig.hull
			local a1 = Instance.new("Attachment")
			a1.Name = "VfxDraftB"
			a1.CFrame = CFrame.new(side * 3.2, -0.2, 5.5)
			a1.Parent = rig.hull
			local tr = Instance.new("Trail")
			tr.Name = "VfxDraftTrail"
			tr.Attachment0 = a0
			tr.Attachment1 = a1
			tr.Texture = tex("trail_soft")
			-- v29 W1b A3: thin, faint, unlit and tapered to nothing (was 0.4 s, LightEmission 0.6, alpha 0.65, taper 0.3)
			tr.Lifetime = 0.35
			tr.MinLength = 0.2
			tr.FaceCamera = true
			tr.LightEmission = 0
			tr.Color = cs(WHITE, rgb(190, 222, 255))
			tr.Transparency = ns({ { 0, 0.72 }, { 0.5, 0.88 }, { 1, 1 } })
			tr.WidthScale = ns({ { 0, 1 }, { 1, 0 } })
			tr.Enabled = false
			tr.Parent = rig.hull
			table.insert(made, tr)
		end
		rig.draftTrails = made
		trails = made
	end
	for _, tr in trails :: { Trail } do
		tr.Enabled = on
	end
end

local function stepDraft(dt: number, localSpeed: number)
	local hull = localHull
	local scale = Settings.particleScale()
	local best: Rig? = nil
	if hull and hull.Parent and scale > 0 then
		local cf = hull.CFrame
		local bestAhead = math.huge
		for model, rig in rigs do
			if rig.hull == hull or rig.out == true or model:GetAttribute("IsBoss") == true then
				continue
			end
			local rel = cf:PointToObjectSpace(rig.hull.Position)
			local _, rivalSpeed = planeState(model)
			if -rel.Z < bestAhead and AirFxRules.inSlipstream(rel.X, rel.Y, rel.Z, localSpeed, rivalSpeed) then
				bestAhead = -rel.Z
				best = rig
			end
		end
	end
	if draftRival and not draftRival.model.Parent then
		draftRival = nil -- that plane was destroyed (respawn / track switch): drop the stale rig
	end
	draftLevel, draftHold = AirFxRules.draftStep(draftLevel, draftHold, best ~= nil, dt)
	local rival = if best then best elseif draftHold > 0 then draftRival else nil
	local trailsOn = rival ~= nil and AirFxRules.draftTrails(scale)
	if draftRival ~= rival then
		if draftRival then
			setDraftTrails(draftRival, false)
		end
		if rival then
			setDraftTrails(rival, trailsOn)
		end
		draftRival = rival
	elseif rival then
		local trails = rival.draftTrails
		if (trails == nil and trailsOn) or (trails ~= nil and trails[1].Enabled ~= trailsOn) then
			setDraftTrails(rival, trailsOn)
		end
	end
end

-- Plane skimming low over water: a spray burst behind it every 0.14 s and (desktop) a flat wake_foam Trail on the surface.
local skimWaterClock = 0
local skimWaterParams = RaycastParams.new()
skimWaterParams.FilterType = Enum.RaycastFilterType.Include
skimWaterParams.IgnoreWater = false
local skimHost: Part? = nil
local skimTrail: Trail? = nil
local skimWaterY: number? = nil
local function setSkimTrail(on: boolean)
	if not skimTrail then
		if not on or not poolFolder then
			return
		end
		local host = Instance.new("Part")
		host.Name = "VfxSkimHost"
		host.Anchored = true
		host.CanCollide = false
		host.CanQuery = false
		host.CanTouch = false
		host.CastShadow = false
		host.Transparency = 1
		host.Size = Vector3.one
		host.CFrame = CFrame.new(0, -500, 0)
		host.Parent = poolFolder
		local a0 = Instance.new("Attachment")
		a0.CFrame = CFrame.new(-1.5, 0, 0)
		a0.Parent = host
		local a1 = Instance.new("Attachment")
		a1.CFrame = CFrame.new(1.5, 0, 0)
		a1.Parent = host
		local tr = Instance.new("Trail")
		tr.Name = "VfxSkimFoam"
		tr.Attachment0 = a0
		tr.Attachment1 = a1
		local id = (GroundTexAssets :: any).wake_foam
		tr.Texture = if type(id) == "number" and id > 0 then "rbxassetid://" .. tostring(id) else tex("trail_soft")
		tr.Lifetime = 2
		tr.MinLength = 1
		tr.FaceCamera = false -- lies flat on the water
		tr.LightEmission = 0.2
		tr.Color = cs(rgb(235, 248, 255))
		tr.Transparency = ns({ { 0, 0.4 }, { 1, 1 } })
		tr.WidthScale = ns({ { 0, 1 }, { 1, 1.7 } })
		tr.Enabled = false
		tr.Parent = host
		skimHost = host
		skimTrail = tr
	end
	local tr = skimTrail
	if tr and tr.Enabled ~= on then
		tr.Enabled = on
		if not on and skimHost then
			skimHost.CFrame = CFrame.new(0, -500, 0)
		end
	end
end

local function stepWaterSkim(dt: number, speed: number)
	local hull = localHull
	if not hull or not hull.Parent or (hull.Parent :: Instance):GetAttribute("IsCar") == true then
		setSkimTrail(false)
		return
	end
	skimWaterClock -= dt
	if skimWaterClock <= 0 then
		skimWaterClock = AirFxRules.SKIM_INTERVAL
		skimWaterParams.FilterDescendantsInstances = { workspace.Terrain }
		local hit = workspace:Raycast(hull.Position, Vector3.new(0, -AirFxRules.SKIM_MAX, 0), skimWaterParams)
		if hit and hit.Material == Enum.Material.Water and AirFxRules.skimActive(hit.Distance, speed) then
			local back = hull.CFrame.LookVector * -5
			local at = hit.Position + Vector3.new(back.X, 0.3, back.Z)
			Vfx.burst("skimSpray", CFrame.lookAt(at, at + Vector3.yAxis), AirFxRules.skimIntensity(hit.Distance))
			skimWaterY = hit.Position.Y
			setSkimTrail(AirFxRules.skimTrail(Settings.particleScale()))
		else
			skimWaterY = nil
			setSkimTrail(false)
		end
	end
	local y = skimWaterY
	if y and skimHost and skimTrail and skimTrail.Enabled then
		local p = hull.Position
		local look = hull.CFrame.LookVector
		local at = Vector3.new(p.X, y + 0.15, p.Z)
		skimHost.CFrame = CFrame.lookAt(at, at + Vector3.new(look.X, 0, look.Z))
	end
end

function Vfx.step(dt: number, local_: FrameState)
	local now = os.clock()
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		for _, m in planes:GetChildren() do
			if m:IsA("Model") then
				if not rigs[m] then
					attachRig(m)
				end
				if m:GetAttribute("IsBoss") == true then
					stepBoss(m, now)
				end
			end
		end
	end
	for model in bossFx do
		if not model.Parent then
			bossFx[model] = nil
		end
	end
	local intensity = if local_.boost == "Overcharge" then 1 elseif local_.boost == "Standard" then 0.75 else math.clamp((local_.speed - 125) / 60, 0, 0.4)
	local battle = RaceAttr.mine("RaceMode") == "battle"
	local camPos = if workspace.CurrentCamera then workspace.CurrentCamera.CFrame.Position else nil
	local remoteVortex = 0
	for model, rig in rigs do
		if not model.Parent then
			destroyFlames(rig)
			rigs[model] = nil
			continue
		end
		local out = battle and isOut(model)
		if out and rig.out == false then -- nil = first frame for this rig: someone already OUT gets no burst on join
			Vfx.burst("battleOut", CFrame.lookAt(rig.hull.Position, rig.hull.Position + Vector3.yAxis))
		end
		rig.out = out
		local streaks = rig.streaks
		if streaks then
			-- v28 W1.1: boost only (cruise speed shows none), a handful per second: 3-4 on screen at the outer edges.
			local rate = if local_.boost ~= "None" then math.floor(math.max(0, intensity - 0.2) * 14 + 0.5) else 0
			if rate ~= rig.streakRate then
				rig.streakRate = rate
				for _, pe in streaks do
					pe.Rate = rate
					pe.Enabled = rate > 0
				end
			end
		end
		if string.find(model.Name, LocalPlayer.Name, 1, true) then
			rig.remote = false
			localHull = rig.hull
			syncCosmeticTrail(rig, true)
			updateRig(rig, dt, local_.boost, local_.speed, local_.sharp, local_.roll)
			stepVortex(rig, local_.speed, local_.sharp, local_.roll == true, true, camPos, 0)
		else
			syncCosmeticTrail(rig, false)
			rig.remote = true
			local b, s = planeState(model)
			if b ~= rig.lastBoost and b ~= "None" then
				Vfx.burst(if b == "Overcharge" then "overcharge" else "boost", rig.hull.CFrame * CFrame.new(0, 0, 6) * CFrame.Angles(0, math.pi, 0), 0.6)
			end
			updateRig(rig, dt, b, s, false)
			if stepVortex(rig, s, false, false, false, camPos, remoteVortex) then
				remoteVortex += 1
			end
		end
	end
	stepDraft(dt, local_.speed)
	-- v28 W1.1: the screen speed lines only draw while boosting (cruise speed is calm).
	stepSpeedLines(dt, if local_.boost ~= "None" then intensity else 0)
	stepSpeedWorld(dt, local_.speed, local_.boost ~= "None")
	stepPunch(dt)
	BoostPadFx.step(dt)
	stepSnowPuffs(dt)
	stepSnowSkim(dt)
	stepWaterSkim(dt, local_.speed)
	stepMeadowSkim(dt)
	stepSandKick(dt)
	stepBirds(dt)
	if ambientPart then
		local cam = workspace.CurrentCamera
		if cam then
			-- Ambience follows the camera so it is always local and cheap.
			ambientPart.CFrame = CFrame.new(cam.CFrame.Position + cam.CFrame.LookVector * 40 + Vector3.new(0, -10, 0))
		end
	end
end

-- ---------------------------------------------------------------- gameplay hooks
-- Boost ignite punch (local vehicle). The camera controllers read Vfx.fovKick() (added on top of their own boost FOV) and
-- drain Vfx.takeTrauma() into their own trauma shake; the optional ColorCorrection tint lasts at most 2 frames.
function Vfx.boostPunch(over: boolean)
	punchT = 0
	punchOver = over
	pendingTrauma += BoostRules.trauma(over)
	if not Settings.lowGraphics() then
		local t: ColorCorrectionEffect
		if tint then
			t = tint
		else
			t = Instance.new("ColorCorrectionEffect")
			t.Name = "SkyRallyBoostTint"
			t.Enabled = false
			t.Parent = Lighting
			tint = t
		end
		t.Brightness = BoostRules.TINT_BRIGHTNESS
		t.Saturation = BoostRules.TINT_SATURATION
		t.TintColor = if over then Color3.fromRGB(226, 255, 236) else Color3.fromRGB(226, 246, 255)
		t.Enabled = true
		tintFrames = BoostRules.TINT_FRAMES
	end
end

-- Extra degrees of FOV right now (0 when no punch is running).
function Vfx.fovKick(): number
	return BoostRules.fovKick(punchT, punchOver)
end

-- Trauma queued by boostPunch since the last call (the active camera controller adds it to its own shake).
function Vfx.takeTrauma(): number
	local a = pendingTrauma
	pendingTrauma = 0
	return a
end

function Vfx.onBoost(hullCF: CFrame, overcharged: boolean)
	Vfx.burst(if overcharged then "overcharge" else "boost", hullCF * CFrame.new(0, 0, 6) * CFrame.Angles(0, math.pi, 0))
	-- The flash sits above and AHEAD of the hull (the chase camera is behind it), small and 0.16 s.
	Vfx.burst(if overcharged then "overchargeFlash" else "boostFlash", hullCF * CFrame.new(0, 3.2, -7))
	Vfx.boostPunch(overcharged)
end

-- Radius of a ring trigger from its size (the second-largest side: the trigger is a thin slab or cube across the ring).
function Vfx.ringRadius(size: Vector3): number
	local a = { size.X, size.Y, size.Z }
	table.sort(a)
	return math.clamp(a[2] * 0.5, 4, 40)
end

function Vfx.onRing(ringCF: CFrame, radius: number?)
	-- v29 W1b A4 (critic v29: ring-pass bloom and bubble still on screen in V12, dino4 05 / island2 04/06): the
	-- ringPass shockwave disc (26 studs, opaque, emissive, centred in the opening the camera flies through) is no longer
	-- fired on a pass: the opening stays clear and only the rim sparkles below mark it. Wave 1 had only moved the
	-- sparkle to the rim and tuned SailGateFx; this disc was the bloom.
	-- v28 W1.2: the sparkle sits on the rim (never the middle of the opening), four points a frame apart.
	local r = radius or 14
	for i = 0, 3 do
		task.delay(0.03 * i, function()
			local a = i * math.pi / 2 + math.pi / 4
			local at = ringCF * CFrame.new(math.cos(a) * r, math.sin(a) * r, 0)
			Vfx.burst("ringRim", CFrame.lookAt(at.Position, at.Position + (at.Position - ringCF.Position).Unit))
		end)
	end
end

function Vfx.onPad(padCF: CFrame)
	Vfx.burst("pad", CFrame.lookAt(padCF.Position, padCF.Position + Vector3.yAxis))
	-- Light streak down the route (the pad's -Z is the route direction), just above the deck.
	local from = padCF.Position + Vector3.new(0, 1, 0)
	local fwd = padCF.LookVector
	Vfx.burst("padStreak", CFrame.lookAt(from, from + Vector3.new(fwd.X, 0, fwd.Z)))
	BoostPadFx.flare(padCF.Position)
end

-- Collect streak: one pooled Beam (two attachments, built on first use) from the pod to the local vehicle, 0.3 s.
local streak: { beam: Beam, from: Attachment, to: Attachment, conn: RBXScriptConnection?, t0: number, hull: BasePart? }? = nil

local function playStreak(pos: Vector3, hull: BasePart, color: Color3)
	local st = streak
	if not st or not st.beam.Parent then
		local from = Instance.new("Attachment")
		from.Name = "VfxPickupStreakFrom"
		from.Parent = workspace.Terrain
		local to = Instance.new("Attachment")
		to.Name = "VfxPickupStreakTo"
		to.Parent = workspace.Terrain
		local b = Instance.new("Beam")
		b.Name = "VfxPickupStreak"
		b.Attachment0 = from
		b.Attachment1 = to
		b.Texture = tex("trail_soft")
		b.TextureMode = Enum.TextureMode.Stretch
		b.LightEmission = 1
		b.LightInfluence = 0
		b.FaceCamera = true
		b.Segments = 1
		b.Enabled = false
		b.Parent = workspace.Terrain
		st = { beam = b, from = from, to = to, conn = nil, t0 = 0, hull = nil }
		streak = st
	end
	local s = st :: any
	s.from.WorldPosition = pos
	s.hull = hull
	s.to.WorldPosition = hull.Position
	-- v28 W1.1: pale at both ends (a deep pod hue read as a dark line along the route on bright roads).
	s.beam.Color = ColorSequence.new(WHITE, WHITE:Lerp(color, 0.45))
	s.beam.Enabled = true
	s.t0 = os.clock()
	if s.conn then
		return
	end
	s.conn = RunService.Heartbeat:Connect(function()
		local k = (os.clock() - s.t0) / PickupFxRules.STREAK_LIFE
		local h = s.hull :: BasePart?
		if k >= 1 or not h or not h.Parent then
			s.beam.Enabled = false
			if s.conn then
				s.conn:Disconnect()
				s.conn = nil
			end
			return
		end
		s.to.WorldPosition = (h :: BasePart).Position + Vector3.new(0, 0.6, 0) -- the vehicle end follows the hull
		s.beam.Width0 = PickupFxRules.streakWidth(k)
		s.beam.Width1 = 0.2
		s.beam.Transparency = ns({ { 0, 0.5 + 0.5 * k }, { 1, 0.7 + 0.3 * k } })
	end)
end

-- Item and secret pickups take the colour of their kind (PickupFxRules.colorRgb: pod balloon, token, key, gear, cube; no or
-- unknown kind keeps the cream look) and, in range of the local vehicle on a thick particle budget, a short collect streak.
function Vfx.onPickup(pos: Vector3, kind: string?)
	local c = PickupFxRules.colorRgb(kind)
	local color = rgb(c[1], c[2], c[3])
	local entry = getPool("pickupTint")
	if entry then
		for _, pe in entry.emitters do
			-- v21: the pod hues read as one white bloom on bright sand (additive, 35 % tint): deeper tint, half blended.
			pe.Color = cs(WHITE:Lerp(color, 0.65), color)
			pe.LightEmission = 0.9
		end
		Vfx.burst("pickupTint", CFrame.lookAt(pos, pos + Vector3.yAxis))
	else
		Vfx.burst("pickup", CFrame.lookAt(pos, pos + Vector3.yAxis))
	end
	local hull = localHull
	if hull and hull.Parent and PickupFxRules.streakOn((hull.Position - pos).Magnitude, Settings.particleScale()) then
		playStreak(pos, hull, color)
	end
end

function Vfx.onCrash(pos: Vector3, reason: string, normal: Vector3?)
	local n = normal or Vector3.yAxis
	local cf = CFrame.lookAt(pos, pos + n)
	if reason == "LethalLava" or reason == "LavaFloor" then
		Vfx.burst("crashLava", cf)
	else
		Vfx.burst("crashStone", cf)
	end
end

function Vfx.onRespawn(hullCF: CFrame)
	Vfx.burst("respawn", hullCF)
	local layers = ItemFxRules.respawnLayers(Settings.phoneTier(), Settings.lowGraphics())
	local pos = hullCF.Position
	if layers.cloud then
		Vfx.burst("respawnCloud", CFrame.lookAt(pos - Vector3.new(0, 1.5, 0), pos - Vector3.new(0, 20, 0)))
	end
	if layers.column then
		-- Starts COLUMN_HEIGHT above the hull and lowers onto it over COLUMN_LIFE, fading out as it lands.
		Vfx.burst("respawnColumn", CFrame.lookAt(pos + Vector3.new(0, ItemFxRules.COLUMN_HEIGHT, 0), pos))
	end
end

function Vfx.onFinish(pos: Vector3)
	task.spawn(pcall, function() -- moments VFX: shells, streamers and colour jets (client/CelebrationFx)
		(require(script.Parent:WaitForChild("CelebrationFx")) :: any).finishShow(pos)
	end)
	-- v21: the ring, sparkles and confetti used to burst at the road centre under the gantry (pos) and covered the route for
	-- ~2 s. They now play at the gantry's two sides (the camera's right axis, 22 studs out like CelebrationFx's jets), high
	-- and leaning outward, so the cone around the screen centre stays clear.
	local cam = workspace.CurrentCamera
	local right = Vector3.xAxis
	if cam then
		local r = cam.CFrame.RightVector
		local flat = Vector3.new(r.X, 0, r.Z)
		if flat.Magnitude > 0.05 then
			right = flat.Unit
		end
	end
	local SIDE = 22
	for i, side in { -1, 1 } do
		-- the pools are one attachment per preset: a frame apart per side so each burst keeps its own position
		task.delay(0.05 * (i - 1), function()
			local base = pos + right * (side * SIDE)
			Vfx.burst("finish", CFrame.lookAt(base + Vector3.new(0, 12, 0), base + Vector3.new(0, 13, 0)), 0.7)
			-- aimed up and outward: elevation >= ~70 degrees, drifting away from the centre line
			Vfx.burst("confetti", CFrame.lookAt(base + Vector3.new(0, 3, 0), base + Vector3.new(0, 50, 0) + right * (side * 16)), 0.8)
		end)
		task.delay(0.4 + 0.35 * (i - 1), function()
			Vfx.burst("finish", CFrame.new(pos + right * (side * SIDE) + Vector3.new(0, 20 + 4 * i, 0)), 0.5)
		end)
	end
end

-- Sink / drown: the crown's base sits ~0.2 x its size under the particle centre, so lift it onto the water line.
function Vfx.onSplash(pos: Vector3)
	local at = pos + Vector3.new(0, 2, 0)
	Vfx.burst("splash", CFrame.lookAt(at, at + Vector3.yAxis))
end

-- Driving into shallow water at speed (CarController): a small crown on the water line.
local lastWaterEntry = 0
function Vfx.onWaterEntry(pos: Vector3)
	local now = os.clock()
	if now - lastWaterEntry < 0.6 then
		return -- the shallow-water flag can flicker at a shoreline: one crown per 0.6 s
	end
	lastWaterEntry = now
	local at = pos + Vector3.new(0, 1.2, 0)
	Vfx.burst("waterEntry", CFrame.lookAt(at, at + Vector3.yAxis))
end

-- Car touchdown from real air (strength 0-1 from the impact speed); hops have the tricks lane's hopDust instead.
function Vfx.onLand(cf: CFrame, strength: number)
	Vfx.burst("landDust", cf, 0.6 + 0.6 * math.clamp(strength, 0, 1))
end

-- Boss hazard hit (ItemClient "explode" with source "boss_<kind>"): the hazard's own impact. Returns false for kinds
-- without one (mine), which keep the item missile blast.
local HAZARD_HIT: { [string]: string } = {
	snowball = "snowHit", iceshard = "snowHit", bubble = "bubblePop", lightning = "lightningStrike",
	lavabomb = "crashLava", fireball = "crashLava", rockfall = "crashStone",
}
function Vfx.onHazardHit(kind: string, pos: Vector3): boolean
	local preset = HAZARD_HIT[kind]
	if not preset then
		return false
	end
	local at = if kind == "lightning" then pos + Vector3.new(0, 5, 0) else pos
	Vfx.burst(preset, CFrame.lookAt(at, at + Vector3.yAxis))
	return true
end

function Vfx.init()
	if poolFolder then
		return
	end
	local f = Instance.new("Folder")
	f.Name = "SkyRallyVfx"
	f.Parent = workspace
	poolFolder = f
	buildSpeedLines()
	buildWind(f)
	BoostPadFx.init(f)
	-- Warm the pools so the first boost/crash never hitches on instance creation.
	for name in PRESETS do
		getPool(name)
	end
	local zone = RaceAttr.mine("ActiveZone")
	Vfx.setZone(if type(zone) == "string" then zone else "DINO")
	RaceAttr.changed("ActiveZone", function()
		local z = RaceAttr.mine("ActiveZone")
		Vfx.setZone(if type(z) == "string" then z else nil)
	end)
	BossIntro.onIntro(function(model: Model, sweep: number)
		Vfx.bossAura(model, sweep)
	end)
	-- Optional test hook (QA): workspace attribute VfxTest = "<preset>" fires that preset in front of the camera.
	workspace:GetAttributeChangedSignal("VfxTest"):Connect(function()
		local name = workspace:GetAttribute("VfxTest")
		local cam = workspace.CurrentCamera
		if type(name) == "string" and cam then
			Vfx.burst(name, CFrame.lookAt(cam.CFrame.Position + cam.CFrame.LookVector * 40, cam.CFrame.Position))
		end
	end)
end

return Vfx
