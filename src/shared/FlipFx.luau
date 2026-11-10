--!strict
-- Flipbook VFX v2 lookup (assets/vfx/flip_v2, owned Blender/numpy renders; ids in the generated VfxFlipAssets).
-- One place that knows each sheet's FlipbookLayout, FlipbookMode and framerate (manifest.json grid/loop/suggested), so
-- every emitter that shows a flipbook (client Vfx/ItemClient/TrackFlow/CarController, the server-built hazard, key and
-- battle emitters) sets them the same way:
--   one-shots  FlipbookMode OneShot: a particle plays its whole sheet over its own Lifetime (Lifetime = playback time)
--   loops      FlipbookMode Loop at the sheet's FlipbookFramerate, FlipbookStartRandom so neighbours never sync
--   bolts      FlipbookMode Random (lightning_bolt_2x2: four variants; a short particle shows one or two of them)
-- A sheet whose id is missing falls back to the old VfxAssets texture named in SHEETS (its own layout, OneShot), so a
-- partial upload degrades to the previous look instead of a blank square. Any other name resolves as an old VfxAssets
-- key, so callers can route every texture through FlipFx.resolve/apply. Pure lookup plus one property writer; no state.
local Shared = script.Parent

local function load(name: string): { [string]: any }
	local mod = Shared:WaitForChild(name, 10)
	if not mod then
		return {}
	end
	local ok, t = pcall(require, mod :: any)
	return if ok and type(t) == "table" then t else {}
end

local VfxFlipAssets = load("VfxFlipAssets")
local VfxAssets = load("VfxAssets")

local FlipFx = {}

export type Sheet = { layout: string, mode: string, fps: number?, fallback: string }
export type Resolved = { texture: string, layout: string, mode: string, fps: number?, flip: boolean }

-- layout/mode/fps from assets/vfx/flip_v2/manifest.json (grid, loop, suggested.flipbookMode/flipbookFramerate);
-- tools/tests/flipfx_spec.luau checks them against the manifest and VfxFlipAssets.
FlipFx.SHEETS = {
	explosion_8x8 = { layout = "Grid8x8", mode = "OneShot", fallback = "explosion_4x4" },
	smoke_puff_8x8 = { layout = "Grid8x8", mode = "OneShot", fallback = "smoke_puff_4x4" },
	fire_loop_8x8 = { layout = "Grid8x8", mode = "Loop", fps = 30, fallback = "fire_lick_4x4" },
	shockwave_8x8 = { layout = "Grid8x8", mode = "OneShot", fallback = "shockwave_ring" },
	water_splash_8x8 = { layout = "Grid8x8", mode = "OneShot", fallback = "water_droplet" },
	magic_swirl_8x8 = { layout = "Grid8x8", mode = "Loop", fps = 30, fallback = "glow_soft" },
	dust_burst_4x4 = { layout = "Grid4x4", mode = "OneShot", fallback = "smoke_puff_4x4" },
	snow_burst_4x4 = { layout = "Grid4x4", mode = "OneShot", fallback = "snowflake" },
	confetti_burst_4x4 = { layout = "Grid4x4", mode = "OneShot", fallback = "confetti" },
	sparkle_star_4x4 = { layout = "Grid4x4", mode = "Loop", fps = 24, fallback = "star_twinkle" },
	electric_arc_4x4 = { layout = "Grid4x4", mode = "Loop", fps = 24, fallback = "spark_streak" },
	lightning_bolt_2x2 = { layout = "Grid2x2", mode = "Random", fps = 10, fallback = "lightning_beam" },
	speed_streak = { layout = "None", mode = "None", fallback = "speed_line" },
} :: { [string]: Sheet }

local function old(name: string): Resolved
	local e = VfxAssets[name]
	local id = if type(e) == "table" and type(e.id) == "string" then e.id else ""
	local layout = if type(e) == "table" and type(e.flipbook) == "string" then e.flipbook else "None"
	return { texture = id, layout = layout, mode = if layout == "None" then "None" else "OneShot", fps = nil, flip = false }
end

-- Texture id and flipbook settings for a flip_v2 sheet name (or an old VfxAssets key). flip = the new sheet is used.
function FlipFx.resolve(name: string): Resolved
	local sheet = FlipFx.SHEETS[name]
	if not sheet then
		return old(name)
	end
	local id = VfxFlipAssets[name]
	if type(id) == "string" and id ~= "" then
		return { texture = id, layout = sheet.layout, mode = sheet.mode, fps = sheet.fps, flip = true }
	end
	return old(sheet.fallback)
end

-- True when `name` resolves to its new flip_v2 sheet (false: fallback or an old key).
function FlipFx.isFlip(name: string): boolean
	return FlipFx.resolve(name).flip
end

-- Writes Texture and the flipbook properties for `name` onto an emitter; `fps` overrides a loop's framerate.
-- Returns whether the new sheet is in use (a caller can pick fallback sizes for the old texture).
-- An unresolved name (texture "") never leaves the emitter blank: a blank ParticleEmitter draws flat white squares, so
-- it gets Roblox's built-in soft smoke puff (local content, always loads) as a single frame instead.
FlipFx.BLANK_STANDIN = "rbxasset://textures/particles/smoke_main.dds"
function FlipFx.apply(pe: ParticleEmitter, name: string, fps: number?): boolean
	local r = FlipFx.resolve(name)
	if r.texture == "" then
		r = { texture = FlipFx.BLANK_STANDIN, layout = "None", mode = "None", fps = nil, flip = false }
	end
	pe.Texture = r.texture
	pe.FlipbookLayout = (Enum.ParticleFlipbookLayout :: any)[r.layout]
	if r.layout ~= "None" then
		pe.FlipbookMode = (Enum.ParticleFlipbookMode :: any)[r.mode]
		local rate = fps or r.fps
		if rate then
			pe.FlipbookFramerate = NumberRange.new(rate)
		end
		pe.FlipbookStartRandom = r.mode == "Loop" or r.mode == "Random"
	end
	return r.flip
end

return FlipFx
