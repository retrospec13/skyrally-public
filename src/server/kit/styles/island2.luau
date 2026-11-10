--!strict
-- ISLAND-2 deck style (kit/Deck loads kit/styles/*.luau; missing fields fall back to dino_paver). The guide's beach
-- road: cream cobble pavers (SR_ISLAND_Cobble via plan materials.partRules), low grey stone curbs flush with the sand,
-- sandy stone fascia. Road deck = bridge kind with piersEvery 0 in the plan; the lagoon bridge's arches and piers are
-- plan prefabs. The Alt1 boardwalk (ledge style) is retextured to ship-deck planks by partRules.

return {
	island2_cobble = {
		kind = "bridge",
		paverCols = 3,
		paverRows = 1,
		mortarBaseCol = Color3.fromRGB(184, 160, 122), -- sandy mortar slab (TrackSeg)
		paverWarmA = Color3.fromRGB(246, 238, 220), -- cream cobble
		paverWarmB = Color3.fromRGB(238, 226, 200),
		paverWarmC = Color3.fromRGB(228, 212, 182),
		sandstoneWarm = Color3.fromRGB(214, 208, 196), -- light curb stone (also the Alt1 ledge before partRules)
		terracottaCliff = Color3.fromRGB(198, 176, 140), -- fascia under the deck edge
		terracottaDeep = Color3.fromRGB(150, 147, 142), -- grey curb stone
		basaltDark = Color3.fromRGB(92, 86, 80),
		basaltMid = Color3.fromRGB(124, 124, 128), -- darker curb stone
		upperSlatePurple = Color3.fromRGB(122, 96, 70),
		torchAmber = Color3.fromRGB(255, 170, 64),
	},
}
