--!strict
-- HUB-0 deck style (kit/Deck.luau loads every module in kit/styles; missing fields fall back to dino_paver).
-- Palette from assets/concepts/map_proposals_20/04_HUB0_CENTRAL_ISLAND.png: a cream stone coastal road with low
-- cream curbs (Super Mario Sunshine plaza stone), not DINO's warm cavern pavers. The plan's materials.partRules then
-- swap the pavers to the SR_HUB_PlazaStone variant and the deck body/curbs to SR_HUB_Masonry, so these colours are
-- the untextured read (and the tint under the textures). Generated maps never edit this file's consumers.
-- HUB-0's road is a bridge deck with piersEvery = 0 (plan deck block): the terrain meets the road edge, and the deck
-- body shows only on the east causeway and at the two log-bridge abutments.

return {
	hub0_road = {
		-- kit/Deck.luau centres exactly two columns (xOff = (c - 1.5) * pitch); 3 would leave the left 7 studs of the
		-- road without pavers and hang a third paver 7 studs past the right curb. The flagstone read comes from the
		-- SR_HUB_PlazaStone texture (16 studs per tile).
		paverCols = 2,
		paverRows = 1,
		-- No dark centre stripe at chase distance: the column split jogs +-1.4 studs on alternate segments (brick bond);
		-- outer edges, paver tops and the deck envelope are unchanged. v29 W1b A7: no mortar gap at all (was 0.10): the
		-- 0.1-stud slot still showed the deck body as a dark line straight down the road under the chase camera (the
		-- critic's "dark tail line", hub0 07-10). Pavers are CanCollide false; the collider is the TrackSeg beam below.
		paverGap = 0,
		paverStagger = 1.4,
		footingY = -30, -- unused (piersEvery = 0); kept below sea level so a stray pier would never show
		zoneFootingY = -30,
		mortarBaseCol = Color3.fromRGB(206, 192, 164), -- deck body / causeway sides
		paverWarmA = Color3.fromRGB(242, 230, 204),
		paverWarmB = Color3.fromRGB(233, 218, 188),
		paverWarmC = Color3.fromRGB(248, 239, 218),
		sandstoneWarm = Color3.fromRGB(238, 225, 196), -- curb light
		terracottaCliff = Color3.fromRGB(214, 198, 164), -- fascia under the deck edge
		terracottaDeep = Color3.fromRGB(222, 205, 172), -- curb alternate (cream, not terracotta)
		basaltDark = Color3.fromRGB(150, 132, 108),
		basaltMid = Color3.fromRGB(226, 210, 178),
		upperSlatePurple = Color3.fromRGB(168, 140, 112),
		torchAmber = Color3.fromRGB(255, 205, 120),
	},
}
