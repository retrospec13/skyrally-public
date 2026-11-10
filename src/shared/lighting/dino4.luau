--!strict
-- DINO-4 Dino Ridge lighting (LightingProfiles loads every module in shared/lighting; format: { [mapId] = Profile }).
-- Guide: assets/concepts/skyrally_mockups_v1/04_dino4_controls.png - a sealed lava cavern, molten warm light from below
-- against cool violet-blue rock shadow and a cool skylight from above.
-- L61 grade pass (critic r0 4/10 colour: "over-orange, blown out, one value band, no cool counterlight"):
-- - the shadow floor (Ambient) is a cool violet instead of plum-warm, so every face the lava lights does not reach
--   reads cool and the lava rigs (plan routeLights, lava fx) are the only warm source;
-- - cool upward-face shift (ColorShift_Top) for the skylight feel, hot lava bounce on downward faces;
-- - a cool blue-violet Atmosphere so the far walls of the tube and the great halls fall back into cool haze (depth);
-- - grade: less saturation and a touch of cool tint so the strata stop reading neon orange, more contrast, bloom
--   threshold low enough that lava and embers glow while lit rock stays under it.
-- The sun never reaches the course (sealed cave), so Brightness/ClockTime only matter for the skylight colour.

-- Sky v3 (visibility fix 3, 2026-10-20; tools/vfx/make_dino_sky_v3.py, assets/sky/dino_cave_v3): all six faces are the
-- inside of this cave - painted strata walls in the terrain palette hazing into the Atmosphere colour at the horizon,
-- a glowing crust-plated lava sea below, a dark rock ceiling with a warm lava bounce above (no oculus: the hall roof is
-- sealed). At graphics level 1 Roblox culls the far walls, ceiling and backdrop shell, so the sky IS the far cave.
-- Old ids (v2 side + v1 up/down, kept in assets/sky/dino_cave_v2 and dino_cave, src/shared/SkyAssets.luau):
--   side = rbxassetid://118871156482188 (v2 violet haze with mountain silhouettes, read as "outdoors at night"),
--   up = rbxassetid://90805080890326, down = rbxassetid://77932208519276 (v1).
local DinoSky = require(script.Parent.Parent:WaitForChild("sky"):WaitForChild("dino4"))

type PropList = { { any } }
type Effect = { className: string, name: string, props: PropList }
type Profile = { lighting: PropList, effects: { Effect } }

local profiles: { [string]: Profile } = {
	["DINO-4"] = {
		lighting = {
			{ "Brightness", 2.4 },
			{ "ClockTime", 13.4 },
			{ "GeographicLatitude", 22 },
			{ "Ambient", Color3.fromRGB(108, 122, 176) }, -- cool shadow floor: the warmth comes from the lava. v20 counter-colour: old (122, 112, 146) -> (108, 122, 176), blue-teal-violet so shaded walls stop reading red
			{ "OutdoorAmbient", Color3.fromRGB(100, 130, 176) }, -- v20: old (110, 118, 150) -> (100, 130, 176) cool teal-blue bounce
			{ "ColorShift_Bottom", Color3.fromRGB(232, 112, 62) }, -- molten bounce on downward faces. v20: old (255, 104, 34) -> (232, 112, 62) less saturated orange so walls and deck stop merging
			{ "ColorShift_Top", Color3.fromRGB(110, 150, 196) }, -- cool skylight on upward faces. v20: old (120, 140, 180) -> (110, 150, 196) teal-leaning rim on deck tops
			{ "EnvironmentDiffuseScale", 0.5 },
			{ "EnvironmentSpecularScale", 0.4 }, -- glints on basalt and bone
			{ "ExposureCompensation", 0.1 },
			{ "ShadowSoftness", 0.25 },
			{ "GlobalShadows", true },
		},
		effects = {
			{
				className = "Atmosphere",
				name = "SkyRally_Atmosphere",
				props = {
					-- Visibility v1 (owner report 2026-10-20, docs/design/BACKDROP_SHELLS.md): the hall's far walls (600-1350
					-- studs) stayed crisp up to the client's terrain draw cut, then stopped against the violet sky. Thicker,
					-- warmer smoky-rock haze so the cut lands inside haze of the rock's own colour (about half hazed at 400
					-- studs, mostly at 700+); the backdrop shell (kit/Backdrop) stands in for the culled walls behind it.
					-- Warm lava-bounce decay instead of the dark violet one, so the v21 "black voids" do not come back.
					{ "Density", 0.2 }, -- Wave 1b C1 (critic v29: V12 read as warm smoke over the halls): 0.34 -> 0.2. visibility v1: old 0.2 -> 0.34 (v21 A/B: 0.28 -> 0.2, no black voids over the lava floor)
					{ "Offset", 0.1 }, -- Wave 1b C1: 0.01 -> 0.1 (near halls clear, haze starts deeper). visibility v1: old 0.08 -> 0.01 (far rock blends into the haze, no silhouette edge on the sky)
					{ "Color", Color3.fromRGB(104, 104, 140) }, -- Wave 1b C1: (132, 96, 92) warm smoke -> (104, 104, 140) cool slate haze (warm Decay kept, so far lava bounce stays warm). visibility v1: old (150, 118, 128) warm mauve -> (132, 96, 92) warm smoky rock (v21 A/B: (122, 108, 140) -> (150, 118, 128))
					{ "Decay", Color3.fromRGB(150, 92, 70) }, -- visibility v1: old (92, 70, 96) dark violet -> (150, 92, 70) warm lava bounce
					{ "Glare", 0.0 },
					{ "Haze", 0.3 }, -- Wave 1b C1: 0.6 -> 0.3. visibility v1: old 1.2 -> 0.6 (less sky tint toward the flat violet field; v21 A/B: 2.2 -> 1.2)
				},
			},
			-- Cave skybox v3: cave walls, lava sea and rock ceiling on all six faces (assets/sky/dino_cave_v3).
			{
				className = "Sky",
				name = "SkyRally_Sky",
				props = {
					{ "SkyboxBk", DinoSky.side },
					{ "SkyboxFt", DinoSky.side },
					{ "SkyboxLf", DinoSky.side },
					{ "SkyboxRt", DinoSky.side },
					{ "SkyboxUp", DinoSky.up },
					{ "SkyboxDn", DinoSky.down },
					{ "CelestialBodiesShown", false },
					{ "StarCount", 0 },
				},
			},
			{
				className = "BloomEffect",
				name = "SkyRally_Bloom",
				props = {
					{ "Intensity", 0.3 }, -- Wave 1b C1: 0.42 -> 0.3
					{ "Size", 26 },
					{ "Threshold", 1.6 }, -- Wave 1b C1: 1.3 -> 1.6 (only lava and embers bloom)
				},
			},
			{
				className = "ColorCorrectionEffect",
				name = "SkyRally_ColorCorrection",
				props = {
					{ "Brightness", -0.02 },
					{ "Contrast", 0.2 },
					{ "Saturation", 0.0 }, -- v20: old 0.04 -> 0.0 (calms the red walls). Atmosphere lane: old -0.04 -> 0.04, the magma oranges and jungle greens read bright (ART_BAR: slight saturation)
					{ "TintColor", Color3.fromRGB(228, 238, 255) }, -- v20: old (240, 242, 255) -> (228, 238, 255) cooler grade
				},
			},
		},
	},
}

return profiles
