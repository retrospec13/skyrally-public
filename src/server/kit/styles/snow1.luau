--!strict
-- SNOW-1 deck style (kit/Deck loads every module in kit/styles; missing fields fall back to dino_paver).
-- kind "none": the guide (05_SNOW1_EVERFROST_PEAK.png) shows an open flight line over the frozen river, the plateau,
-- the bridge deck and the lake, so Deck.build places no road. The palette still matters: Deck.buildAlternate builds the
-- Alt1 mine tunnel through the west gorge wall from these fields (floor = paverWarmA, walls = terracottaCliff,
-- roof = upperSlatePurple, lantern strip = torchAmber, ledge = sandstoneWarm). The plan's materials.partRules then give
-- the tunnel parts the SNOW texture set (pavers, fieldstone, timber); the colours are near-white tints so the textures
-- carry the colour, as DINO-4 does.

local styles: any = {
	snow1_open = {
		kind = "none",
		paverCols = 2,
		paverRows = 1,
		footingY = 16,
		zoneFootingY = 16,
		mortarBaseCol = Color3.fromRGB(106, 120, 140), -- blue-grey mortar
		paverWarmA = Color3.fromRGB(226, 232, 240), -- frosted pale stone floor (SR_SNOW_Pavers)
		paverWarmB = Color3.fromRGB(214, 222, 232),
		paverWarmC = Color3.fromRGB(236, 240, 246),
		sandstoneWarm = Color3.fromRGB(232, 236, 242), -- ledge timber/stone
		terracottaCliff = Color3.fromRGB(109, 122, 148), -- tunnel walls (SR_SNOW_Fieldstone), v29 D6 slate shell
		terracottaDeep = Color3.fromRGB(170, 180, 198),
		basaltDark = Color3.fromRGB(64, 74, 92),
		basaltMid = Color3.fromRGB(92, 104, 124),
		upperSlatePurple = Color3.fromRGB(93, 106, 132), -- tunnel roof, v29 D6 slate shell
		noTorchStrip = true, -- v29 D6: timber ribs and lanterns from the plan instead
		torchAmber = Color3.fromRGB(255, 196, 110), -- warm lantern strip inside the tunnel
	},
}

return styles
