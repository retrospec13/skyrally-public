--!strict
-- Pure tuning and decisions for the car ground effects (client/GroundFx): mini-turbo tier looks, tyre-mark gating,
-- surface kinds (water spray / snow powder / mark colour), spray rates, distance culling and car-to-car bump severity.
-- No Instances, no clock: everything takes its inputs so tools/tests/ground_fx_spec.luau can pin it down.
local GroundFxRules = {}

-- ---------------------------------------------------------------- mini-turbo tiers (1 blue, 2 orange, 3 violet/zone)
export type Tier = {
	ringSize: number, -- shockwave ring end size at each rear wheel (studs)
	sparks: number, -- forward-biased sparks on release (total, before particleScale)
	flames: number, -- flame-kick particles from the exhaust
	flameSize: number,
	ember: number, -- inner glow ember size while charged
	arcs: boolean, -- electric arc layer while charged and on release (top tier only)
	emberRate: number, -- charged ember particles per second per wheel (before particleScale)
	emberLight: number, -- ember LightEmission: v21 tier 1 blends (bright sand swallowed the additive blue), tier 3 is capped (it blew the rear wheel out to white)
	emberMax: number, -- release ember size cap (studs), keeps the top tier from swelling over the hull
}
-- v21: tier 1 was faint on bright ground: bigger, denser, a hard-cored sprite (pickup_glint) in a deeper blue. Tier 3 ember
-- shrunk (4.0 -> 3.0), its additive cap at 0.5 and its rate lowered so the rear wheel keeps its own colour.
GroundFxRules.TIERS = {
	{ ringSize = 5.5, sparks = 20, flames = 2, flameSize = 1.6, ember = 3.4, arcs = false, emberRate = 56, emberLight = 0.3, emberMax = 4.4 },
	{ ringSize = 7.2, sparks = 38, flames = 3, flameSize = 2.1, ember = 3.2, arcs = false, emberRate = 44, emberLight = 0.5, emberMax = 4.0 },
	{ ringSize = 8.8, sparks = 64, flames = 5, flameSize = 2.8, ember = 3.0, arcs = true, emberRate = 36, emberLight = 0.5, emberMax = 3.8 },
} :: { Tier }

-- Effect-only tint of tier 1 (CarConfig keeps the sky blue for the HUD): a deeper blue that still reads on sand and cobble.
GroundFxRules.TIER1_FX_RGB = table.freeze({ 36, 108, 248 })

-- Mini-turbo sparks on other cars (bots, rivals) run at this fraction of the local car's rate: the top tier is 170/s per
-- emitter and a pack of bots drifting together was the most expensive particle load on the track.
GroundFxRules.REMOTE_SPARK_FRAC = 0.35
function GroundFxRules.sparkRate(base: number, scale: number, isLocal: boolean): number
	return math.max(0, base) * math.clamp(scale, 0, 1) * (if isLocal then 1 else GroundFxRules.REMOTE_SPARK_FRAC)
end

function GroundFxRules.tier(level: number): Tier
	return GroundFxRules.TIERS[math.clamp(math.floor(level), 1, #GroundFxRules.TIERS)] :: Tier
end

-- Tier-up pop (the instant the drift charge crosses into tier 1/2/3): a short per-rear-wheel flash, deliberately smaller
-- than the release. Both wheels together stay within POP_MAX_TOTAL particles; the star layer is skipped on a thin
-- particle scale (phone) and every other layer is scaled down but never to zero (the pop must still show).
export type Pop = {
	ring: number, -- shockwave ring end size per wheel (studs), always under the tier's release ring
	stars: number, -- sparkle stars per wheel (0 on a thin particle scale)
	streaks: number, -- radial spark streaks per wheel
}
GroundFxRules.POP_MAX_TOTAL = 14
GroundFxRules.POP_STAR_MIN_SCALE = 0.6
local POP_RING = { 2.4, 3.0, 3.6 }
local POP_STARS = { 1, 1, 2 }
local POP_STREAKS = { 2, 3, 4 }

function GroundFxRules.tierPop(level: number, scale: number): Pop
	local i = math.clamp(math.floor(level), 1, #POP_RING)
	local s = math.clamp(scale, 0, 1)
	return {
		ring = POP_RING[i] :: number,
		stars = if s < GroundFxRules.POP_STAR_MIN_SCALE then 0 else POP_STARS[i] :: number,
		streaks = GroundFxRules.scaled(POP_STREAKS[i] :: number, s),
	}
end

-- A particle count scaled for the phone budget: never below 1 for a requested burst (a release must still show).
function GroundFxRules.scaled(count: number, scale: number): number
	if count <= 0 then
		return 0
	end
	return math.max(1, math.floor(count * math.clamp(scale, 0, 1) + 0.5))
end

-- Emitter Rate under the particle scale (0 stays 0, so a switched-off layer is truly off).
function GroundFxRules.rate(base: number, scale: number): number
	return math.max(0, base) * math.clamp(scale, 0, 1)
end

-- ---------------------------------------------------------------- distance culling
GroundFxRules.CULL_LOCAL = 400 -- the local car is always near the camera; kept only as a safety
GroundFxRules.CULL_REMOTE = 130 -- other cars: effects only within this of the camera
GroundFxRules.MAX_REMOTE_RIGS = 5 -- other cars that may hold ground-FX instances at once (nearest first)

function GroundFxRules.inRange(dist: number, isLocal: boolean): boolean
	return dist <= (if isLocal then GroundFxRules.CULL_LOCAL else GroundFxRules.CULL_REMOTE)
end

-- ---------------------------------------------------------------- tyre marks
GroundFxRules.SKID_MIN_SPEED = 38
GroundFxRules.SKID_SLIP_DEG = 9 -- body slip angle beyond which a non-drifting car also lays marks (hard cornering)
GroundFxRules.SKID_LIFETIME = 4

-- Marks while the body slides hard on the ground: a drift always marks; otherwise a slip angle past the threshold.
-- slipDeg = angle between the body heading and the travel direction. Water and the air never mark.
function GroundFxRules.skidActive(grounded: boolean, wet: boolean, speed: number, drifting: boolean, slipDeg: number): boolean
	if not grounded or wet or math.abs(speed) < GroundFxRules.SKID_MIN_SPEED then
		return false
	end
	return drifting or math.abs(slipDeg) >= GroundFxRules.SKID_SLIP_DEG
end

-- Mark colour by surface material name; nil = no mark (grass, leaves, mud, water: nothing to scuff).
local MARK_COLORS: { [string]: { number } } = {
	Asphalt = { 28, 27, 30 }, Concrete = { 40, 39, 42 }, Pavement = { 36, 35, 38 }, Slate = { 36, 36, 40 },
	Plastic = { 34, 33, 38 }, SmoothPlastic = { 34, 33, 38 }, Metal = { 34, 34, 38 }, DiamondPlate = { 34, 34, 38 },
	Brick = { 44, 36, 34 }, Cobblestone = { 44, 40, 38 }, Granite = { 40, 40, 44 }, Marble = { 56, 54, 58 },
	Wood = { 48, 36, 28 }, WoodPlanks = { 48, 36, 28 }, Neon = { 34, 33, 38 }, Foil = { 34, 34, 38 },
	Sand = { 150, 122, 84 }, Ground = { 74, 58, 44 }, Pebble = { 70, 62, 56 }, Rock = { 52, 50, 52 },
	Snow = { 118, 134, 156 }, Ice = { 96, 128, 168 }, Glacier = { 96, 128, 168 },
}
function GroundFxRules.markColor(material: string): { number }?
	return MARK_COLORS[material]
end

-- ---------------------------------------------------------------- surfaces: spray and powder
GroundFxRules.SPRAY_MIN_SPEED = 14

-- "water" | "snow" | "none" from the contact material and whether the car is wading.
function GroundFxRules.surfaceKind(material: string, wet: boolean): string
	if wet then
		return "water"
	end
	if material == "Snow" or material == "Ice" or material == "Glacier" then
		return "snow"
	end
	return "none"
end

-- Rear-wheel spray/powder strength 0..1 from speed: nothing below SPRAY_MIN_SPEED, full at top speed.
function GroundFxRules.sprayStrength(speed: number, topSpeed: number): number
	local s = math.abs(speed)
	if s < GroundFxRules.SPRAY_MIN_SPEED then
		return 0
	end
	return math.clamp((s - GroundFxRules.SPRAY_MIN_SPEED) / math.max(1, topSpeed - GroundFxRules.SPRAY_MIN_SPEED), 0, 1)
end

-- ---------------------------------------------------------------- contacts
GroundFxRules.BUMP_COOLDOWN = 0.35 -- per other car
GroundFxRules.SCRAPE_TRAUMA = 0.035 -- wall scrape (the hard bump keeps CarController's own 0.22 * impact)

-- Overlap test in the local car's frame (relX right, relY up, relZ back of the other hull), box = both footprints.
function GroundFxRules.overlaps(relX: number, relY: number, relZ: number, halfWidth: number, halfLength: number): boolean
	return math.abs(relX) < halfWidth * 1.8 and math.abs(relZ) < halfLength * 1.7 and math.abs(relY) < 4
end

-- 0.2..1 from the closing speed (studs/s the gap shrinks) and the speed difference of the two cars.
function GroundFxRules.bumpSeverity(closing: number, relSpeed: number): number
	return math.clamp(0.2 + math.max(0, closing) / 90 + math.abs(relSpeed) / 220, 0.2, 1)
end

function GroundFxRules.bumpSparks(severity: number): number
	return math.floor(5 + 14 * math.clamp(severity, 0, 1) + 0.5)
end

-- Tiny camera trauma for the local player; capped far under a wall bump's 0.22.
function GroundFxRules.bumpTrauma(severity: number): number
	return 0.03 + 0.07 * math.clamp(severity, 0, 1)
end

return GroundFxRules
