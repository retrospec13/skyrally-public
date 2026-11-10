--!strict
-- Car ground-FX textures (assets/vfx/ground/*.png, made by tools/gen_ground_tex.py): name -> Roblox image asset id
-- number. 0 = not uploaded yet; client/GroundFx then falls back to VfxAssets.trail_soft (tinted), so the game works
-- before the integrator uploads. Both are white-with-alpha and tinted by the Trail colour.
--   skid_strip  tyre mark ribbon, U along the trail (tiles), V across
--   wake_foam   water V-wake foam streak, same mapping
return {
	skid_strip = 113729616009980,
	wake_foam = 96645779324441,
} :: { [string]: number }
