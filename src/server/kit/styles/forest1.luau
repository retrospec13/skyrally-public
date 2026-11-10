--!strict
-- FOREST-1 deck style (kit/Deck partial Style; fields not listed fall back to dino_paver). Loaded by kit/Deck from
-- kit/styles/*; no requires here (Deck requires this module while it loads).
-- The guide's cobblestone country road (13_FOREST1_WINDMILL_PLAINS.png): a bridge-kind deck with piersEvery = 0 in the
-- plan, so it lies on the terrain (the author script grades the ground to meet the curb tops). The plan's
-- materials.partRules give the parts their owned MaterialVariants (pavers -> SR_FOREST_Cobble, mortar beam, curbs and
-- fascia -> SR_FOREST_Masonry), so the colours below are light tints multiplied over those textures: near-white
-- keeps the painted cobble colour, darker values separate curbs and fascia. The Alt1 cobble ledge through Granary
-- Hill (Deck.buildAlternate "ledge") uses sandstoneWarm; the tunnel-style fields (paverWarmA floor, terracottaCliff
-- walls, upperSlatePurple roof, torchAmber strip) are set for any later masonry tunnel alternate.

return {
	forest1_cobble = {
		kind = "bridge",
		paverCols = 2, -- the kit centres exactly two columns per segment
		-- v29 W1b A7 (critic v29 "dark tail line", forest1 00/01/06/07/09/11): with the default 0.30 mortar gap the two
		-- paver columns left a slot down the road centre showing the darker masonry beam; the chase camera rides the race
		-- line, so the slot ran from under the plane's tail to the bottom of every frame (and stayed with shadows off, out
		-- /v12 forest1_line_A/B). No gap and a brick-bond jog: no continuous centre line. Pavers are CanCollide false (the
		-- TrackSeg beam is the collider), so nothing about the drivable surface changes.
		paverGap = 0,
		paverStagger = 1.4,
		paverRows = 2,
		footingY = 40,
		zoneFootingY = 40,
		mortarBaseCol = Color3.fromRGB(122, 108, 88), -- masonry beam under the cobbles (shows at the road edge)
		-- Wave 1b C10 (critic v29 forest1 00/01/07-11: "pink cobble with glowing chartreuse grout"; v28 1.6 asked for this
		-- and Wave 1 never edited this file). The SR_FOREST_Cobble ColorMap is the neutral T5 tile (stones ~220 grey,
		-- grout a light green ~(159,199,124)), so the part colour is the whole hue: the old warm cream tints turned the
		-- stones pink and lifted the grout to chartreuse. Grey-brown tints put the stones at ~(150,135,115) and the grout
		-- at a dark moss ~(108,122,65), darker than the stones (no new texture; non-Neon, no emissive).
		paverWarmA = Color3.fromRGB(174, 156, 133),
		paverWarmB = Color3.fromRGB(164, 147, 124),
		paverWarmC = Color3.fromRGB(182, 164, 140),
		sandstoneWarm = Color3.fromRGB(150, 136, 116), -- curb stones, ~15% under the road (L61: frame against the meadow)
		terracottaCliff = Color3.fromRGB(212, 206, 188), -- fascia / Alt1 tunnel walls (mossy grey masonry)
		terracottaDeep = Color3.fromRGB(128, 116, 98), -- darker curb stones (Wave 1b C10: with the road)
		basaltDark = Color3.fromRGB(118, 112, 98),
		basaltMid = Color3.fromRGB(146, 140, 124), -- alternate curb stones (Wave 1b C10: with the road)
		upperSlatePurple = Color3.fromRGB(146, 154, 128), -- Alt1 tunnel vault: moss-darkened stone
		torchAmber = Color3.fromRGB(255, 196, 110), -- Alt1 lantern strip
	},
}
