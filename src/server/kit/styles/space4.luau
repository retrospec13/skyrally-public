--!strict
-- SPACE-4 "Monorail Neon Grid" deck style (kit/Deck.luau loads every module in kit/styles; missing fields fall back
-- to dino_paver). Road deck = bridge kind; the plan sets piersEvery 6 for the elevated highway, and at grade the
-- piers sit buried in the embankment. Palette from 20_SPACE4_STAR_CITY.png: blue-grey riveted road plates over brass
-- seams (the TrackSeg shows between the two paver columns), cream/navy rumble curbs, navy steel fascia. The plan's
-- materials.partRules give these parts the space_v1 MaterialVariants (road plates, brass, metal plates, stone arch)
-- and override the pier colours; the colours here are what reads before the variants load.
return {
	space4_neon = {
		kind = "bridge",
		paverCols = 2,
		paverRows = 1,
		footingY = 2,
		zoneFootingY = 2,
		mortarBaseCol = Color3.fromRGB(200, 150, 62), -- brass seams and deck sides (TrackSeg)
		-- v29 W1b A10 (critic v29): warm grey-stone road plates (were slate blue-greys 98,106,140 / 90,98,132 / 106,112,146
		-- from the L61 night grade), under the golden-hour light and the borrowed warm sky
		paverWarmA = Color3.fromRGB(152, 142, 130),
		paverWarmB = Color3.fromRGB(144, 134, 122),
		paverWarmC = Color3.fromRGB(158, 148, 136),
		sandstoneWarm = Color3.fromRGB(234, 222, 198), -- cream curb blocks
		terracottaCliff = Color3.fromRGB(60, 72, 102), -- navy steel fascia (piers recoloured by the plan's partRules)
		terracottaDeep = Color3.fromRGB(47, 58, 88), -- navy curb blocks
		basaltMid = Color3.fromRGB(72, 86, 116), -- steel-blue curb blocks
		basaltDark = Color3.fromRGB(150, 138, 118), -- pier footings
		upperSlatePurple = Color3.fromRGB(94, 47, 90), -- Alt1 tunnel roof (plum)
		torchAmber = Color3.fromRGB(255, 170, 60), -- Alt1 tunnel light strip (sodium)
	},
}
