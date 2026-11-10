--!strict
-- Hub portal textures (assets/vfx/portal/*.png, made by tools/gen_portal_tex.py): name -> Roblox image asset id number.
-- 0 = not uploaded yet; client/PortalFill then falls back to the VfxAssets textures. Uploaded 2026-10-19 from
-- assets/vfx/portal_tex (uploaded.json; Use granted to universe 0, validated per item).
return {
	vortex_a = 118390072974450, -- 4/5-arm log spiral, white, alpha
	vortex_b = 135165017054527, -- the counter-rotating spiral
	core = 140148772194720, -- soft radial depth disc
	rim = 131547814616853, -- crisp ring with inner glow
	streaks = 72647457681124, -- inward speed lines
	mote = 0, -- reserved: a mote sprite (PortalFill uses VfxAssets.glow_soft)
} :: { [string]: number }
