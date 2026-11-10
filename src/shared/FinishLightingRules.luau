--!strict
-- Finish stage lighting (owner: "the neon map is too dark at the end of a race you can't even see the trophy screen or
-- players at all"). While the finish show / podium / results card is up, client/FinishLighting lifts the map's Lighting
-- to a readable floor and the podium stage carries its own key / fill / rim lights, so SPACE-4 (night, violet haze) and
-- every other map read like the hub at midday. Pure numbers, no Instances, specced in tools/tests/finish_lighting_spec.luau.
-- Only ever raises (a bright map keeps its own look) and never touches race lighting: the client restores the snapshot.
local FinishLightingRules = {}

export type Snapshot = {
	Brightness: number,
	ClockTime: number,
	ExposureCompensation: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	atmosphereDensity: number?, -- nil: the map has no Atmosphere
	atmosphereHaze: number?,
	ccBrightness: number?, -- nil: no ColorCorrectionEffect
}

FinishLightingRules.BRIGHTNESS = 3 -- hub midday is 2.6
FinishLightingRules.CLOCK = 14 -- sun well up: the directional key lands on the podium from above
FinishLightingRules.CLOCK_DAY_FROM = 9 -- a map already inside [9, 16.5] keeps its own sun angle
FinishLightingRules.CLOCK_DAY_TO = 16.5
FinishLightingRules.EXPOSURE = 0.2
FinishLightingRules.AMBIENT = Color3.fromRGB(150, 148, 160)
FinishLightingRules.OUTDOOR_AMBIENT = Color3.fromRGB(150, 158, 182)
FinishLightingRules.DENSITY_MAX = 0.08 -- haze off the podium: the violet Atmosphere (0.30) swallowed the stage
FinishLightingRules.HAZE_MAX = 0.4
FinishLightingRules.CC_BRIGHTNESS = 0.04

-- Stage lights, in stage space (the stage's origin is the base of the steps, +Z toward the camera, steps at x = -9 / 0 / 9
-- and heights 4 / 6 / 2.6). Built once with the stage, parked with it.
FinishLightingRules.STAGE_LIGHTS = {
	{ name = "Key", kind = "SpotLight", pos = Vector3.new(-14, 34, 30), aim = Vector3.new(0, 5, 0), brightness = 6, range = 60, angle = 70, color = Color3.fromRGB(255, 244, 226) },
	{ name = "Fill", kind = "PointLight", pos = Vector3.new(14, 12, 28), brightness = 1.6, range = 56, color = Color3.fromRGB(214, 226, 255) },
	{ name = "RimL", kind = "PointLight", pos = Vector3.new(-9, 12, -8), brightness = 2.4, range = 26, color = Color3.fromRGB(255, 226, 190) },
	{ name = "RimC", kind = "PointLight", pos = Vector3.new(0, 14, -8), brightness = 2.4, range = 26, color = Color3.fromRGB(255, 232, 200) },
	{ name = "RimR", kind = "PointLight", pos = Vector3.new(9, 11, -8), brightness = 2.4, range = 26, color = Color3.fromRGB(255, 226, 190) },
} :: { { name: string, kind: string, pos: Vector3, aim: Vector3?, brightness: number, range: number, angle: number?, color: Color3 } }

local function lum(c: Color3): number
	return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
end

local function lift(c: Color3, floor: Color3): Color3
	return Color3.new(math.max(c.R, floor.R), math.max(c.G, floor.G), math.max(c.B, floor.B))
end

-- Sun height 0..1 from a ClockTime (6 h sunrise, 18 h sunset), the proxy the specs compare maps with.
function FinishLightingRules.sunHeight(clock: number): number
	return math.max(0, math.sin(math.pi * (clock - 6) / 12))
end

-- Rough "how lit is a surface facing the sky" number: exposure * (ambient + sun). Only for comparing profiles.
function FinishLightingRules.litness(s: Snapshot): number
	local ambient = 0.5 * lum(s.Ambient) + 0.5 * lum(s.OutdoorAmbient)
	local haze = if s.atmosphereDensity then 1 - math.min(s.atmosphereDensity, 1) * 0.5 else 1
	return (2 ^ s.ExposureCompensation) * (ambient + 0.35 * s.Brightness * FinishLightingRules.sunHeight(s.ClockTime)) * haze
end

-- The finish stage values for a map's snapshot. Each is the larger of the map's own and the floor (the atmosphere
-- the smaller), so a bright map is left alone and a dark one comes up to a readable level.
function FinishLightingRules.target(s: Snapshot): Snapshot
	local clock = s.ClockTime
	if clock < FinishLightingRules.CLOCK_DAY_FROM or clock > FinishLightingRules.CLOCK_DAY_TO then
		clock = FinishLightingRules.CLOCK
	end
	return {
		Brightness = math.max(s.Brightness, FinishLightingRules.BRIGHTNESS),
		ClockTime = clock,
		ExposureCompensation = math.max(s.ExposureCompensation, FinishLightingRules.EXPOSURE),
		Ambient = lift(s.Ambient, FinishLightingRules.AMBIENT),
		OutdoorAmbient = lift(s.OutdoorAmbient, FinishLightingRules.OUTDOOR_AMBIENT),
		atmosphereDensity = if s.atmosphereDensity then math.min(s.atmosphereDensity, FinishLightingRules.DENSITY_MAX) else nil,
		atmosphereHaze = if s.atmosphereHaze then math.min(s.atmosphereHaze, FinishLightingRules.HAZE_MAX) else nil,
		ccBrightness = if s.ccBrightness then math.max(s.ccBrightness, FinishLightingRules.CC_BRIGHTNESS) else nil,
	}
end

return FinishLightingRules
