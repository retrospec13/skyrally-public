--!strict
-- Atmosphere lane textures (assets/vfx/atmos, made by tools/gen_atmos_tex.py: white RGB, shape in alpha, tinted per map
-- by the emitter's Color). Asset ids: 0 = not uploaded yet; client/AtmosphereFx then uses the fallback VfxAssets
-- texture named in FALLBACK so the game looks right before the integrator uploads and fills these in.
local AtmosTexAssets = {
	ash_flake = 81185727218192, -- DINO-4 falling ash
	god_ray = 99077326544330, -- FOREST-1 / hub light shafts
	star_streak = 104077554321209, -- SPACE-4 streaming star dust
}

AtmosTexAssets.FALLBACK = {
	ash_flake = "debris_shard",
	god_ray = "glow_soft",
	star_streak = "spark_streak",
} :: { [string]: string }

return AtmosTexAssets
