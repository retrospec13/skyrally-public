--!strict
-- SNOW-1 "Frozen River Peak" lighting (guide: assets/concepts/map_proposals_20/05_SNOW1_EVERFROST_PEAK.png).
-- A crisp cold morning (L61): low warm sun, deep cobalt snow shadows (blue OutdoorAmbient and ColorShift_Bottom do the
-- shadow colour, not post), pale blue distance haze over the far ranges, restrained bloom so the snow and the cyan
-- river ice never wash out. Loaded by LightingProfiles from shared/lighting; the plan's skyrally.lighting is "SNOW-1".
-- Sky: shared/sky/snow1 (the uploaded faces of assets/sky/snow1_v2: the v1 up/down with the v2 land side face).

-- One { property, value } pair, typed loosely: a profile mixes numbers, colours and booleans (LightingProfiles.PropList).
local function kv(key: string, value: any): { any }
	return { key, value }
end

local profile = {
	-- Sky side v2 (visibility fix 3, 2026-10-20; tools/vfx/make_sky_land_v2.py, assets/sky/snow1_v2): far snowfields,
	-- white-blue ranges and fir specks below the horizon so a culled rim reads as more land. Old side id
	-- 90151922700164 (plain white below the horizon, assets/sky/snow1); up/down unchanged.
	skyProps = { kv("SunAngularSize", 8) }, -- v28 1.5: smaller sun disc
	sky = "snow1", -- shared/sky/snow1 (faces of assets/sky/snow1_v2, uploaded)
	-- L61 grade pass (critic r0 4/10: "flat, overexposed snow, weak shadows, no warm/cool contrast"): a crisp cold
	-- MORNING. The sun is low (long blue shadows across the river from every fir and boulder), warm on the faces it
	-- hits and cool everywhere else; the shadow floor drops (Ambient, OutdoorAmbient and EnvironmentDiffuse down) so
	-- the sunlit and the sky-lit sides separate; exposure comes down so the snow keeps its form; contrast up,
	-- saturation neutral; the haze is pale blue with warm sun glare. Lanterns, lodge windows and rings carry the warm
	-- accents (bloom catches only them, never the snow).
	lighting = {
		kv("Brightness", 2.25), -- v20: old 2.1 -> 2.25 (a touch more sun vs the shade; 2.4 clipped the snow)
		kv("ClockTime", 8.4), -- low morning sun from the east: long shadows
		kv("GeographicLatitude", 46),
		kv("Ambient", Color3.fromRGB(74, 80, 100)), -- v21 A/B: v20 (72, 76, 108) -> (74, 80, 100); (v20 from (58, 70, 104)) neutral slate shade so the cliffs read warm grey, not royal blue
		kv("OutdoorAmbient", Color3.fromRGB(125, 149, 200)), -- v28 1.5: #7d95c8 blue shadows; -- v21 A/B: v20 (104, 118, 170) -> (118, 130, 160) (v20 from (88, 116, 184)); the Rock tint #9a9591 now reads warm grey in shade
		kv("ColorShift_Bottom", Color3.fromRGB(126, 136, 158)), -- v22 polish (Studio A/B pending): (120, 138, 176) -> (126, 136, 158), less blue so the shaded cliff faces read warm grey; v21 A/B: v20 (120, 140, 196) -> (120, 138, 176) (v20 from (86, 132, 214)); faces away from the sun pick up a softer sky blue
		kv("ColorShift_Top", Color3.fromRGB(255, 190, 130)), -- v20: old (255, 206, 160) -> (255, 190, 130) warmer gold sun -- warm low sun on the lit snow and the stone
		kv("EnvironmentDiffuseScale", 0.32),
		kv("EnvironmentSpecularScale", 0.5), -- sheen on the river and lake ice
		kv("ExposureCompensation", -0.3), -- v28 1.5 (was -0.28); -- snow is near-white: keep it below clipping
		kv("ShadowSoftness", 0.08),
		kv("GlobalShadows", true),
	},
	effects = {
		{
			className = "Atmosphere",
			name = "SkyRally_Atmosphere",
			props = {
				kv("Density", 0.22), -- v29 D1: 0.27 -> 0.22; the peak and far ranges go pale blue, the lap stays crisp
				kv("Offset", 0.35), -- v29 D1: 0.22 -> 0.35
				kv("Color", Color3.fromRGB(214, 226, 246)), -- v29 D1: cooler still; v28 1.5: cooler (was 236, 232, 238); -- v20: old (214, 228, 248) -> (236, 232, 238) pale warm-lilac haze, not blue
				kv("Decay", Color3.fromRGB(130, 150, 210)), -- v28 1.5: cool decay (was 160, 160, 206); v20: old (122, 156, 214) -> (160, 160, 206)
				kv("Glare", 0), -- v28 1.5: no glare wash (was 0.3)
				kv("Haze", 0.35), -- v29 D1: 1.05 -> 0.35, the peak silhouette reads at 1500+ studs
			},
		},
		{
			className = "BloomEffect",
			name = "SkyRally_Bloom",
			props = {
				kv("Intensity", 0.2), -- v28 1.5: 0.4 -> 0.2
				kv("Size", 26),
				kv("Threshold", 2.5), -- v28 1.5: 1.45 -> 2.5; -- lanterns, rings, glints and boost flames glow; sunlit snow does not bloom
			},
		},
		{
			className = "SunRaysEffect",
			name = "SkyRally_SunRays",
			props = {
				kv("Intensity", 0.03), -- v28 1.5: 0.06 -> 0.03
				kv("Spread", 0.6),
			},
		},
		{
			className = "ColorCorrectionEffect",
			name = "SkyRally_ColorCorrection",
			props = {
				kv("Brightness", -0.02),
				kv("Contrast", 0.4), -- v28 1.5: +0.1
				kv("Saturation", 0.12), -- v29 D1: 0.04 -> 0.12; -- v21 A/B: v20 0.10 -> 0.04 (v20 from 0.16): the single blue stops dominating
				kv("TintColor", Color3.fromRGB(242, 246, 255)), -- v28 1.5: #f2f6ff (was warm 255, 246, 236); -- v20: old (250, 250, 255) -> (255, 246, 236) warm grade
			},
		},
	},
}

return {
	["SNOW-1"] = profile,
}
