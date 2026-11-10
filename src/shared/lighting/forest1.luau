--!strict
-- FOREST-1 "Windmill Vale" lighting profile (loaded by shared/LightingProfiles from shared/lighting/*).
-- Guide: assets/concepts/map_proposals_20/13_FOREST1_WINDMILL_PLAINS.png.
-- L61 art pass (critic r0 4/10: "overbright neon grass, weak value separation, flat sky/fog integration, little
-- shadow drama"): a storybook GOLDEN AFTERNOON. The sun is low in the west (ClockTime 15.85, ~32 degrees up), so every
-- windmill, tree and aqueduct pier throws a long shadow across the meadows and the hills model into a warm lit side and
-- a cool sky-lit side. The shadow floor comes down (Ambient, OutdoorAmbient, EnvironmentDiffuse) and is blue-violet,
-- the sun and the upward faces are honey-warm, exposure comes down so the sea-grass greens keep their form instead of
-- clipping, and the distance goes to a warm cream haze with blue decay (layered hills read as planes of depth). The
-- final straight flies west into the sun: the glare and the sun rays are that leg's golden moment.
-- The terrain colours carry the hue (plan materials.terrainColors); post-processing stays restrained (ART_BAR:
-- light first, post after). No requires here: LightingProfiles requires this module while it loads.

-- Same shapes as LightingProfiles' exported types (declared here: requiring LightingProfiles would be circular).
type PropList = { { any } }
type Effect = { className: string, name: string, props: PropList }
type Profile = { lighting: PropList, effects: { Effect } }

local profiles: { [string]: Profile } = {
	["FOREST-1"] = {
		-- Sky side v2 (visibility fix 3, 2026-10-20; tools/vfx/make_sky_land_v2.py, assets/sky/forest1_v2): far hills,
		-- golden fields and treelines below the horizon so a culled rim reads as more land. Old side id
		-- 120626758127697 (plain green below the horizon, assets/sky/forest1); up/down unchanged.
		sky = "forest1",
		lighting = {
			{ "Brightness", 2.3 },
			-- Low west sun: the start view (north) is side-lit from the left, the high line (east) has the sun behind it,
			-- the final straight (west) flies into it.
			{ "ClockTime", 15.85 }, -- r3: ~32 deg: long readable shadows, no wash-out into the sun
			{ "GeographicLatitude", 38 }, -- tilts the sun a little south, so north-facing slopes stay in cool shade
			{ "Ambient", Color3.fromRGB(70, 70, 92) }, -- low blue-violet shadow floor, never black
			{ "OutdoorAmbient", Color3.fromRGB(104, 118, 160) }, -- cool sky fill in the shade
			{ "ColorShift_Top", Color3.fromRGB(255, 208, 150) }, -- honey-gold sun on the lit faces
			{ "ColorShift_Bottom", Color3.fromRGB(84, 116, 132) }, -- teal-grey bounce under sails, arches and canopies
			{ "EnvironmentDiffuseScale", 0.38 },
			{ "EnvironmentSpecularScale", 0.4 }, -- a sheen on the river, the pond and the waterfalls
			{ "ExposureCompensation", -0.2 },
			{ "ShadowSoftness", 0.12 }, -- crisp storybook shadows
			{ "GlobalShadows", true },
		},
		effects = {
			{
				className = "Atmosphere",
				name = "SkyRally_Atmosphere",
				props = {
					-- Warm cream haze near the horizon with blue decay: the rim hills and the far windmills step back in
					-- layers, the lap stays crisp.
					{ "Density", 0.102 }, -- v28 1.6: -40% (0.17 -> 0.102; AdaptiveHaze reads this as the art value and still thickens it at low graphics); v21 A/B: v20 0.18 -> 0.17 (v20 from 0.24; no grey-teal slab over the lake)
					-- Visibility v1 (owner report 2026-10-20, docs/design/BACKDROP_SHELLS.md): past the heightfield rim the
					-- terrain ended in void and the thin haze hid nothing. Offset lowered (far geometry blends into the haze
					-- at the horizon, so a draw cut or the new ridge ring has no hard edge on the sky); Density stays at the
					-- v21 value that keeps the lake clear. The backdrop ridge ring (kit/Backdrop) fills the horizon.
					{ "Offset", 0.15 }, -- visibility v1: old 0.28 -> 0.15 (v21 A/B: v20 0.2 -> 0.28, v20 from 0.1; clear near field)
					{ "Color", Color3.fromRGB(214, 226, 244) }, -- v28 1.6: pale cobalt-cream (was cream 238, 226, 200)
					{ "Decay", Color3.fromRGB(104, 138, 214) }, -- v28 1.6 pale-cobalt decay (was 130, 160, 205); v21 A/B: v20 (150, 172, 214) -> (130, 160, 205) (v20 from (118, 148, 196)); bluer decay over the lake
					{ "Glare", 0.32 }, -- golden glare toward the low sun
					{ "Haze", 0.5 }, -- v21 A/B: v20 0.8 -> 0.5 (v20 from 1.15)
				},
			},
			-- Restrained bloom: the waterfall foam, the rings, the lanterns and the boost flames glow, never the meadow.
			{
				className = "BloomEffect",
				name = "SkyRally_Bloom",
				props = {
					{ "Intensity", 0.16 }, -- v28 1.6: 0.24 -> 0.16
					{ "Size", 28 },
					{ "Threshold", 2.2 }, -- v28 1.6: 1.65 -> 2.2 (cobble road no longer blooms)
				},
			},
			{
				className = "ColorCorrectionEffect",
				name = "SkyRally_ColorCorrection",
				props = {
					{ "Brightness", -0.01 },
					{ "Contrast", 0.24 },
					{ "Saturation", 0.14 }, -- v28 1.6: +0.1
					{ "TintColor", Color3.fromRGB(255, 244, 226) }, -- a warm afternoon grade over the whole frame
				},
			},
			{
				className = "SunRaysEffect",
				name = "SkyRally_SunRays",
				props = {
					-- Atmosphere lane: god rays through the golden afternoon. old Intensity 0.06 / Spread 0.6 -> 0.12 / 0.75
					-- (still faint: shafts around the sun, never a white-out toward the west straight).
					{ "Intensity", 0.12 },
					{ "Spread", 0.75 },
				},
			},
		},
	},
}

return profiles
