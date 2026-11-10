--!strict
-- Textures made for the boost / speed lane (assets/vfx/boost/*.png, procedural: tools/vfx/gen_boost_tex.py). 0 = not
-- uploaded yet: client code falls back to an existing VfxAssets / flip_v2 texture, so the game works before the upload.
-- The integrator uploads each PNG and writes its numeric asset id here.
return {
	pad_chevron = 133428689898991, -- assets/vfx/boost/pad_chevron.png (upward chevron arrow, white RGB with alpha, tinted by Color)
}
