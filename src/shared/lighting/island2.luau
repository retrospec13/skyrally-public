--!strict
-- ISLAND-2 "Tropical Galleon Coast" lighting (guide assets/concepts/map_proposals_20/10_ISLAND2_CRESCENT_ISLAND.png).
-- L61 art pass (critic r0 3/10: "overbright, low contrast, toxic greens, almost no mood shaping, flat lighting with
-- weak shadows"): a warm tropical LATE AFTERNOON. The sun stands low in the west-south-west (ClockTime 16.35, ~30 deg
-- up), so the start grid (looking north up the crescent) is side-lit from the left: the galleon, the palms and the
-- headland throw long shadows across the sand, the cliff faces model into a honey-lit side and a cool sky-lit side,
-- and the bridge leg (heading west) drives into the glare. The shadow floor comes down and goes blue-violet
-- (Ambient, OutdoorAmbient, EnvironmentDiffuse), so the torch-lit cavern reads 20-30 % darker than the beach and the
-- tiki flames carry; exposure comes down so cream sand and pavers keep their texture instead of clipping; the far sea
-- fades into a warm peach haze with a blue decay (the far islands and sea stacks step back in layers).
-- Terrain colours carry the hue (plan materials.terrainColors: olive sea-grass, warm sand, warm grey stone); post stays
-- restrained (ART_BAR: light first, post after). The cavern's torchlight comes from the plan (rib torches, routeLights,
-- Fire fx), not from post-processing. Sky faces: assets/sky/island2 (tools/map/author_island2.py make_sky).
-- No requires here: LightingProfiles requires this module while it loads.

-- Same shape as LightingProfiles.Profile (not required here: LightingProfiles requires this module).
type PropList = { { any } }
type Profile = { lighting: PropList, effects: { { className: string, name: string, props: PropList } }, sky: string?, skyProps: PropList? }

local profiles: { [string]: Profile } = {
	["ISLAND-2"] = {
		sky = "island2",
		-- r3: a smaller sun disc (critic r2: "the blown sun steals attention", "keep the sun disc less nuclear")
		skyProps = { { "SunAngularSize", 5 :: any } },
		lighting = {
			{ "Brightness", 2.4 },
			-- Low west-south-west sun: the start view (north) is side-lit from the left, the ledge road (east) has the
			-- sun behind it, the bridge leg (west) drives into it.
			{ "ClockTime", 16.35 },
			{ "GeographicLatitude", 24 },
			{ "Ambient", Color3.fromRGB(100, 98, 124) }, -- v20 light pass: old (66, 70, 98) -> (100, 98, 124): the beach huts and galleon hull read as shapes against the sun, not black cut-outs; caves still darker than the beach
			{ "OutdoorAmbient", Color3.fromRGB(126, 130, 166) }, -- cool sky fill in the shade; v20: old (92, 110, 152) -> (126, 130, 166), lifts the shaded faces of the shacks
			{ "ColorShift_Top", Color3.fromRGB(255, 204, 146) }, -- honey-gold sun on the lit faces
			{ "ColorShift_Bottom", Color3.fromRGB(66, 128, 136) }, -- teal bounce off the lagoon and the shallows
			{ "EnvironmentDiffuseScale", 0.3 },
			{ "EnvironmentSpecularScale", 0.4 }, -- v29 D9: 0.55 -> 0.4, paver seams stop glinting gold; a sheen on the sea and the wet sand
			{ "ExposureCompensation", -0.22 }, -- v20: old -0.28 -> -0.22 (lifts the shadow side; sand still under clipping)
			{ "GlobalShadows", true },
			{ "ShadowSoftness", 0.12 }, -- v20: old 0.08 -> 0.12, softer edge so shadows do not cut as hard black
		},
		effects = {
			{
				className = "Atmosphere",
				name = "SkyRally_Atmosphere",
				props = {
					-- Warm peach haze at the horizon with a blue decay: the far islands and stacks step back in layers,
					-- the lap stays crisp.
					{ "Density", 0.27 },
					{ "Offset", 0.14 },
					{ "Color", Color3.fromRGB(200, 220, 240) }, -- v28 1.7: cooler (was peach 240, 214, 182)
					{ "Decay", Color3.fromRGB(120, 170, 220) }, -- v28 1.7: pale-blue decay (was 96, 142, 178)
					{ "Glare", 0.12 }, -- r2: a golden hint toward the low sun, never a white-out (critic r1)
					{ "Haze", 0.65 }, -- v28 1.7: 1.1 -> 0.65
				},
			},
			-- Restrained bloom: the torches, the lanterns, the hoard and the boost rings glow, never the sand.
			{
				className = "BloomEffect",
				name = "SkyRally_Bloom",
				props = {
					{ "Intensity", 0.14 }, -- v28 1.7: 0.2 -> 0.14
					{ "Size", 26 },
					{ "Threshold", 2.1 }, -- v28 1.7: 1.7 -> 2.1 (Atmosphere lane had 1.9 -> 1.7 for water glints); water and sand stay below it
				},
			},
			{
				className = "SunRaysEffect",
				name = "SkyRally_SunRays",
				props = {
					-- Atmosphere lane: old Intensity 0.04 / Spread 0.4 -> 0.08 / 0.5 (a visible low-sun shimmer over the sea).
					{ "Intensity", 0.04 }, -- v28 1.7: half strength
					{ "Spread", 0.5 },
				},
			},
			{
				className = "ColorCorrectionEffect",
				name = "SkyRally_ColorCorrection",
				props = {
					{ "Brightness", -0.02 },
					{ "Contrast", 0.26 },
					{ "Saturation", 0.08 }, -- Atmosphere lane: old 0.03 -> 0.08, a touch more tropical colour (ART_BAR: slight saturation)
					{ "TintColor", Color3.fromRGB(255, 240, 222) }, -- a warm late-afternoon grade over the whole frame
				},
			},
		},
	},
}

return profiles
