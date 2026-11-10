--!strict
-- Adaptive haze (owner, FOREST-1 plane race 2026-10-20: "the map is not loading entirely when you're driving through it
-- and too much of the map is waiting to load until you get closer"). Pure rules for client/AdaptiveHaze; design and
-- Studio recipe in docs/design/ADAPTIVE_HAZE.md.
--
-- Roblox draws terrain only out to a distance that shrinks with the graphics level (about 500 studs at Level01,
-- 600-800 at Level05; phones and a loaded Automatic sit there), and parts and meshes swap to coarser LODs on the way.
-- Against the map's thin art-directed haze that cut is a hard edge and the scenery visibly pops in. The client thickens
-- the map's Atmosphere so the scenery at the current draw radius is already mostly haze: the cut and the pop-in happen
-- inside the fog and scenery fades in out of it (Mario Kart distance fog). The radius is the dressing LOD's estimate
-- (shared/DressingLodRules.targetRadius: Studio level, the slider, or the frame time under Automatic; phones at the
-- Level01 cut), so props that DressingLod fades out and the haze agree.
--
-- * Curve (Beer-Lambert): light from distance d through density D survives as exp(-k * D * d). Keeping the same
--   survival at the radius R as the art look has at its reference distance means D * R = const, so the density the
--   radius needs is REACH / R (REACH per map, studs x density). The applied density is that, never below the art value
--   (a high graphics level keeps the art-directed look) and never above the map's maxDensity.
-- * Weight w = (D - art) / (maxDensity - art) in 0..1 drives the rest: Offset toward lowOffset (far geometry blends
--   into the sky), Haze toward lowHaze, Color toward lowColor (default: the art colour, so the hue never shifts).
-- * Smoothing: the applied density moves toward the target at most UP_RATE (thickening) or DOWN_RATE (clearing) per
--   second, so a frame-time wobble never pumps the fog. A new map (a new Atmosphere instance) snaps to its target.
-- Lighting.FogEnd/FogStart are ignored by the engine while an Atmosphere exists, so only the Atmosphere is driven.
local DressingLodRules = require(script.Parent:WaitForChild("DressingLodRules"))

local AdaptiveHazeRules = {}

AdaptiveHazeRules.TICK = 0.1 -- seconds between passes (10 Hz; writes only when a value moves)
AdaptiveHazeRules.UP_RATE = 0.03 -- density per second while thickening (0.17 -> 0.40 in about 8 s)
AdaptiveHazeRules.DOWN_RATE = 0.012 -- density per second while clearing (slower: the cut may still be short)
AdaptiveHazeRules.EPS = 1e-4 -- property writes below this change are skipped
AdaptiveHazeRules.OFF_ATTR = "AdaptiveHazeOff" -- workspace attribute (Studio A/B): true restores the art look
AdaptiveHazeRules.REACH_ATTR = "AdaptiveHazeReach" -- workspace attribute (Studio calibration): a number forces REACH
AdaptiveHazeRules.STATE_ATTR = "AdaptiveHazeState" -- LocalPlayer readout
AdaptiveHazeRules.ATMOSPHERE = "SkyRally_Atmosphere" -- LightingProfiles' effect name

export type MapHaze = {
	reach: number, -- studs x density: density needed at radius R is reach / R
	maxDensity: number, -- never thicker than this (the lap must stay readable)
	lowOffset: number, -- Offset at full weight
	lowHaze: number, -- Haze at full weight
	lowColor: Color3?, -- Color at full weight; nil keeps the art colour
}

-- Per map (ActiveTrackId). Art values come from the live SkyRally_Atmosphere (shared/lighting/*.luau); these are the
-- clamps. A map not listed keeps its art look (SPACE-4's neon night and the hub are never fogged). REACH is first
-- tuned so the Level01 cut (DressingLod 450) lands near maxDensity; docs/design/ADAPTIVE_HAZE.md has the table and
-- the Studio calibration step (AdaptiveHazeReach).
AdaptiveHazeRules.MAPS = table.freeze({
	-- art D 0.102 (v28 1.6: -40% from 0.17) / Offset 0.15 / Haze 0.5: pale cobalt-cream haze; reach 170 -> 130 keeps the cut-hiding at the low levels while the high levels return to the thinner art look
	["FOREST-1"] = { reach = 130, maxDensity = 0.4, lowOffset = 0.06, lowHaze = 1.0 },
	-- art D 0.27 / Offset 0.22 / Haze 1.05: pale lilac; L01 0.42, L05 0.34, L08+ art
	["SNOW-1"] = { reach = 190, maxDensity = 0.42, lowOffset = 0.12, lowHaze = 1.4 },
	-- art D 0.27 / Offset 0.14 / Haze 1.1: sea haze; L01 0.36, L05 0.29, L06+ art
	["ISLAND-2"] = { reach = 160, maxDensity = 0.38, lowOffset = 0.08, lowHaze = 1.4 },
	-- art D 0.2 / Offset 0.1 / Haze 0.3: cool slate haze (Wave 1b C1). The old clamp (reach 180, max 0.42, lowHaze 0.9)
	-- thickened the cave back to ~0.40 at the low graphics levels the captures and phones run at, which is why the
	-- Wave 1 grade read as warm smoke on screen whatever the profile said. The sealed cave's skybox is the far wall
	-- (sky v3) and the backdrop shell covers the culled walls, so a light clamp is enough: L01 ~0.24, max 0.26.
	["DINO-4"] = { reach = 110, maxDensity = 0.26, lowOffset = 0.06, lowHaze = 0.45 },
}) :: { [string]: MapHaze }

export type Look = { density: number, offset: number, haze: number, color: Color3 }

function AdaptiveHazeRules.forMap(id: string?): MapHaze?
	return if type(id) == "string" then AdaptiveHazeRules.MAPS[id] else nil
end

-- The radius estimate, shared with the dressing LOD (same inputs, same answer).
AdaptiveHazeRules.targetRadius = DressingLodRules.targetRadius

-- Target density for a draw radius: reach / R, clamped to [art, maxDensity]. math.huge (LOD off) is the art value.
function AdaptiveHazeRules.targetDensity(radius: number, art: number, cfg: MapHaze, reach: number?): number
	local hi = math.max(art, cfg.maxDensity)
	if radius == math.huge or radius ~= radius or radius <= 0 then
		return art
	end
	local need = (if type(reach) == "number" and reach > 0 then reach else cfg.reach) / radius
	return math.clamp(need, art, hi)
end

-- Weight 0..1 of the adaptive look at a density.
function AdaptiveHazeRules.weight(density: number, art: number, cfg: MapHaze): number
	local span = cfg.maxDensity - art
	if span <= 1e-6 then
		return if density > art + 1e-6 then 1 else 0
	end
	return math.clamp((density - art) / span, 0, 1)
end

-- Applied density: toward the target by at most UP_RATE / DOWN_RATE per second, never overshooting.
function AdaptiveHazeRules.step(current: number, target: number, dt: number): number
	local d = math.max(0, dt)
	if target > current then
		return math.min(target, current + AdaptiveHazeRules.UP_RATE * d)
	end
	return math.max(target, current - AdaptiveHazeRules.DOWN_RATE * d)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- The full look at an applied density: the art look at weight 0, the map's low look at weight 1.
function AdaptiveHazeRules.look(density: number, art: Look, cfg: MapHaze): Look
	local w = AdaptiveHazeRules.weight(density, art.density, cfg)
	if w <= 0 then
		return { density = art.density, offset = art.offset, haze = art.haze, color = art.color }
	end
	local low = cfg.lowColor or art.color
	return {
		density = density,
		offset = lerp(art.offset, cfg.lowOffset, w),
		haze = lerp(art.haze, cfg.lowHaze, w),
		color = art.color:Lerp(low, w),
	}
end

-- Did something else write the property since we did (StormCup night, a profile reapplied)? Floats read back in 32
-- bits, so compare with a tolerance.
function AdaptiveHazeRules.differs(a: number, b: number): boolean
	return math.abs(a - b) > 1e-3
end

function AdaptiveHazeRules.colorDiffers(a: Color3, b: Color3): boolean
	local t = 1.5 / 255
	return math.abs(a.R - b.R) > t or math.abs(a.G - b.G) > t or math.abs(a.B - b.B) > t
end

return AdaptiveHazeRules
