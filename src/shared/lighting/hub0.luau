--!strict
-- HUB-0 lighting profiles (LightingProfiles loads every module in shared/lighting; format: { [mapId] = Profile }).
-- "HUB-0": the guide's sunny early-afternoon coast (assets/concepts/map_proposals_20/04_HUB0_CENTRAL_ISLAND.png):
-- high warm sun from the sea side, Sunshine-bright warm Ambient and cool sky fill, cyan bounce from the shallows,
-- light blue distance haze over the sea, restrained bloom, a touch of saturation.
-- "HUB-0-STORM": the HUB-BOSS-1 storm variant (assets/concepts/launch_guides_v1/H1_HUB0_LOOP_STORM.png): indigo
-- overcast, cool dim key, purple haze, wet contrast; boost pads and lightning carry the highlights (bloom a bit
-- stronger, threshold still >= 1.3 so the stone never glows).
-- Sky faces live in assets/sky/hub0 (clear) and assets/sky/hub0/storm; the integrator uploads them and adds a
-- SkyRally_Sky effect to each profile once the asset ids exist (no ids are referenced here yet).

type PropList = { { any } }
type Effect = { className: string, name: string, props: PropList }
type Profile = { lighting: PropList, effects: { Effect } }

local profiles: { [string]: Profile } = {
	["HUB-0"] = {
		sky = "hub0",
		-- L61 grade pass (critic 4/10: "over-bright and undirected, weak shadows, no warm/cool contrast, neon grass"):
		-- a lower mid-afternoon sun for longer, crisper shadows; less flat fill (Ambient and EnvironmentDiffuse down) so
		-- the warm sun side and the cool sky-lit shade side separate; saturation boost dropped so the greens stop reading
		-- neon; a warm print-like tint and gentle contrast; cool blue distance haze with sun glare for depth.
		lighting = {
			{ "Brightness", 2.6 },
			{ "ClockTime", 9.4 }, -- v29 B3: mid-morning, lower sun than v28 (10.5) so the arches shadow the spawn plaza; 9.4 not 8.3 keeps the finish_lighting_spec litness ratio (SPACE-4 raw < 0.6 x hub)
			{ "GeographicLatitude", 24 },
			{ "Ambient", Color3.fromRGB(92, 86, 92) }, -- warm, lower shadow floor
			{ "OutdoorAmbient", Color3.fromRGB(150, 140, 150) }, -- v28 1.8: warm-neutral sky fill (was cool 112, 132, 166)
			{ "ColorShift_Top", Color3.fromRGB(255, 214, 160) }, -- v28 1.8: warmer sun on upward faces
			{ "ColorShift_Bottom", Color3.fromRGB(70, 128, 140) }, -- soft teal bounce off the shallows
			{ "EnvironmentDiffuseScale", 0.4 },
			{ "EnvironmentSpecularScale", 0.55 },
			{ "ExposureCompensation", -0.3 },
			{ "ShadowSoftness", 0.25 },
			{ "GlobalShadows", true },
		},
		effects = {
			{
				className = "Atmosphere",
				name = "SkyRally_Atmosphere",
				props = {
					{ "Density", 0.26 },
					{ "Offset", 0.1 },
					{ "Color", Color3.fromRGB(190, 218, 240) },
					{ "Decay", Color3.fromRGB(150, 168, 200) },
					{ "Glare", 0.35 },
					{ "Haze", 1.3 }, -- v28 1.8: 1.6 -> 1.3
				},
			},
			{
				className = "BloomEffect",
				name = "SkyRally_Bloom",
				props = {
					{ "Intensity", 0.3 },
					{ "Size", 26 },
					{ "Threshold", 1.45 },
				},
			},
			{
				className = "SunRaysEffect",
				name = "SkyRally_SunRays",
				props = {
					{ "Intensity", 0.07 },
					{ "Spread", 0.5 },
				},
			},
			{
				className = "ColorCorrectionEffect",
				name = "SkyRally_ColorCorrection",
				props = {
					{ "Brightness", 0.0 },
					{ "Contrast", 0.24 },
					{ "Saturation", 0.06 },
					{ "TintColor", Color3.fromRGB(255, 246, 232) },
				},
			},
		},
	},
	["HUB-0-STORM"] = {
		sky = "hub0_storm",
		lighting = {
			{ "Brightness", 1.2 },
			{ "ClockTime", 17.6 },
			{ "GeographicLatitude", 24 },
			{ "Ambient", Color3.fromRGB(72, 70, 102) },
			{ "OutdoorAmbient", Color3.fromRGB(84, 92, 132) },
			{ "ColorShift_Top", Color3.fromRGB(150, 156, 214) },
			{ "ColorShift_Bottom", Color3.fromRGB(44, 96, 112) }, -- teal bounce off the storm sea
			{ "EnvironmentDiffuseScale", 0.45 },
			{ "EnvironmentSpecularScale", 0.45 }, -- wet stone reads glossier
			{ "ExposureCompensation", -0.3 },
			{ "ShadowSoftness", 0.6 },
			{ "GlobalShadows", true },
		},
		effects = {
			{
				className = "Atmosphere",
				name = "SkyRally_Atmosphere",
				props = {
					{ "Density", 0.4 },
					{ "Offset", 0.08 },
					{ "Color", Color3.fromRGB(112, 104, 150) },
					{ "Decay", Color3.fromRGB(58, 56, 98) },
					{ "Glare", 0.0 },
					{ "Haze", 2.4 },
				},
			},
			{
				className = "BloomEffect",
				name = "SkyRally_Bloom",
				props = {
					{ "Intensity", 0.34 },
					{ "Size", 26 },
					{ "Threshold", 1.3 },
				},
			},
			{
				className = "ColorCorrectionEffect",
				name = "SkyRally_ColorCorrection",
				props = {
					{ "Brightness", -0.02 },
					{ "Contrast", 0.2 },
					{ "Saturation", -0.06 },
					{ "TintColor", Color3.fromRGB(214, 214, 255) },
				},
			},
		},
	},
}

return profiles
