--!strict
-- SPACE-4 "Neon Moon" lighting (LightingProfiles format; LightingProfiles.luau loads every module in shared/lighting).
-- L61 art pass (critic r0 5/10: "washed-out midday haze, not neon or lunar, weak local contrast"): NEON WONDER AT
-- NIGHT. The sky is a night cube (tools/map/author_space4.py write_sky): indigo zenith, a magenta-violet glow of city
-- light at the horizon, a far neon skyline with lit windows, stars and a violet/teal nebula band, the blue home planet
-- rising over the city on the north face (behind the viaduct in the start view) and a ringed gas giant on the east
-- face (the long downtown straights drive at it). The Sky's own sun disc is hidden; the directional light is the
-- gas giant's warm peach "planetshine", low in the east (ClockTime 7.0 at latitude 10: ~15 degrees up), so towers, piers
-- and the viaduct throw long shadows across the plazas. Ambient and OutdoorAmbient are a deep blue-violet floor
-- (dark, never black: the road plates and the moon rock keep their read at phone size). Light hierarchy comes from
-- the scene: neon lane lines and parapet rails, tower bands and rim strips, sodium/cyan streetlamp PointLights, the
-- vault fill, prop glows, the skyway arch keystones. Emissive tiers (critic r1): the cyan centre line and amber lane
-- lines brightest, arches and signs next, the violet parapet rails and the tower rim strips dimmer; bloom restrained
-- so the road plates never wash out (the plates themselves are darker in kit/styles/space4).
-- space-neon pass (owner: "this darker map feels like it needs more bright lights and neon"): the night mood stays, the
-- floor is lifted a step (Brightness 0.8 -> 0.95, ambient +14, exposure 0.05 -> 0.2), bloom a little stronger with a lower
-- threshold so the new pink/cyan/violet edge strips, light arches, holograms and billboards glow, saturation up, and the
-- haze warms toward magenta. Every change is small; the stage-lighting spec still treats the raw map as dark.

-- Same shapes as LightingProfiles.Profile (declared here: requiring LightingProfiles from this module would cycle).
type PropList = { { any } }
type Effect = { className: string, name: string, props: PropList }
type Profile = {
	lighting: PropList,
	effects: { Effect },
	sky: string?,
	skyFaces: { [string]: string }?,
	skyProps: PropList?,
}

-- v29 W1b A9 (critic v29: SPACE-4 colour/light 3.5, "matches proposal" 2.5; the V12 miss): the v28 1.4 golden-hour
-- re-grade below never showed because the SKY was still the painted night cube (indigo zenith, magenta city glow,
-- stars, nebula, ringed giant): a Lighting profile cannot recolour Skybox images, and that cube filled the upper half of
-- every frame. No new upload is allowed in this wave, so the sky reuses the warm day set already uploaded and granted
-- for ISLAND-2 (shared/sky/island2: cream-peach horizon under a cobalt zenith, soft clouds) and keeps one SPACE-4 image:
-- the home-planet disc (shared/sky/space4 `earth`, the disc write_sky made for exactly this) as the Sky's sun, so the
-- low warm key light comes out of a pale planet over the west skyline. The ringed giant and the painted night faces stay
-- in assets/sky/space4 for the Wave 2 repaint (peach horizon, warm cobalt zenith, sparse stars, a smaller desaturated
-- giant), which needs a new upload. Haze 1.4 -> 0.8 so the borrowed horizon is not washed out.
local profiles: { [string]: Profile } = {
	["SPACE-4"] = {
		sky = "island2", -- v29 A9: was "space4" (night cube, skyFaces Ft = earthface, Lf = planet)
		skyProps = {
			{ "CelestialBodiesShown", true :: any }, -- v29 A9: the sun disc is the home planet (below)
			{ "SunTextureId", "@space4:earth" :: any }, -- already uploaded and granted (assets/sky/space4/earth.png)
			{ "SunAngularSize", 14 :: any },
			{ "MoonAngularSize", 0 :: any }, -- no Roblox moon
			{ "StarCount", 0 :: any },
		},
		lighting = {
			{ "Brightness", 1.9 }, -- v28 1.4: golden-hour re-grade, the peach sun is the key light
			{ "ClockTime", 17.5 }, -- v28 1.4: golden hour, low warm sun (was 7.0 planetshine)
			{ "GeographicLatitude", 10 },
			{ "Ambient", Color3.fromRGB(118, 98, 150) }, -- v28 1.4 lifted from (84, 70, 132): deep blue-violet shadow floor (lifted: no crushed blacks)
			{ "OutdoorAmbient", Color3.fromRGB(150, 124, 176) }, -- v28 1.4 raised from (100, 84, 160): lavender night-sky fill
			{ "ColorShift_Top", Color3.fromRGB(255, 196, 140) }, -- v28 1.4: warm golden-peach sun against the cool fill
			{ "ColorShift_Bottom", Color3.fromRGB(140, 70, 190) }, -- magenta bounce from the neon city
			{ "EnvironmentDiffuseScale", 0.3 },
			{ "EnvironmentSpecularScale", 0.3 }, -- a little sheen on brass and glass; the road plates never glare
			{ "ExposureCompensation", 0.0 }, -- v28 1.4: 0.2 -> 0.0 (brighter sun, same read)
			{ "ShadowSoftness", 0.15 },
			{ "GlobalShadows", true },
		},
		effects = {
			{
				className = "Atmosphere",
				name = "SkyRally_Atmosphere",
				props = {
					-- violet city-glow haze: the far towers step back into magenta, the first 50 studs stay crisp
					{ "Density", 0.3 }, -- v28 1.4: cream-peach haze
					{ "Offset", 0.05 },
					{ "Color", Color3.fromRGB(246, 212, 184) }, -- v28 1.4: cream-peach (was violet 120, 60, 160)
					{ "Decay", Color3.fromRGB(96, 100, 170) }, -- v28 1.4: cooler decay (was 40, 34, 100)
					{ "Glare", 0 },
					{ "Haze", 0.8 }, -- v29 A9: was 1.4
				},
			},
			-- Neon is the point at night: lane lines, rails, tower bands, lamp heads and train windows bloom; the
			-- unlit plates, stone and rock stay under the threshold.
			{
				className = "BloomEffect",
				name = "SkyRally_Bloom",
				props = {
					{ "Intensity", 0.28 }, -- v28 1.4: 0.4 -> 0.28 (lit scene; neon still above the threshold)
					{ "Size", 12 }, -- v20: old 24 -> 12: the lane lines stop smearing into wide glow bands
					{ "Threshold", 1.35 }, -- v28 1.4: 1.25 -> 1.35; neon emissive stays above it, sunlit plates do not bloom
				},
			},
			{
				className = "ColorCorrectionEffect",
				name = "SkyRally_ColorCorrection",
				props = {
					{ "Brightness", 0 },
					{ "Contrast", 0.1 },
					{ "Saturation", 0.2 },
					{ "TintColor", Color3.fromRGB(255, 240, 228) }, -- v28 1.4: warm grade (was lilac 236, 230, 255)
				},
			},
			{
				className = "SunRaysEffect",
				name = "SkyRally_SunRays",
				props = {
					{ "Intensity", 0 },
					{ "Spread", 0.5 },
				},
			},
		},
	},
}

return profiles
