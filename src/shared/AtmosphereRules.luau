--!strict
-- Pure maths and tuning for client/AtmosphereFx (per-map atmosphere layered over Vfx's AMBIENT emitters). No Roblox
-- instances here, so tools/tests/atmosphere_spec.luau covers it under Lune. Everything is a number or a string.
--   zone layers  base emitter rate (per second, before the phone scale), per layer; 0 = off
--   speed        how hard the camera is travelling: drives the SPACE star streak length and rate
--   lights       the DINO lava glow and the hub warm light ease toward a target instead of popping
--   culling      the probe-driven layers (sea glints, shore spray, lava light) only run while their surface is near
local AtmosphereRules = {}

-- Camera-relative emitter cells (studs). Side cells keep shafts and star dust off the route in the middle of the view.
-- right/up/look are offsets in the camera's yaw frame; size is the emitter box (x right, y up, z look).
AtmosphereRules.CELLS = {
	Around = { right = 0, up = 6, look = 0, sx = 130, sy = 44, sz = 130 },
	Left = { right = -46, up = 6, look = 48, sx = 36, sy = 30, sz = 80 },
	Right = { right = 46, up = 6, look = 48, sx = 36, sy = 30, sz = 80 },
	Top = { right = 0, up = 36, look = 55, sx = 110, sy = 6, sz = 100 },
	Low = { right = 0, up = -9, look = 58, sx = 100, sy = 2, sz = 80 },
} :: { [string]: { right: number, up: number, look: number, sx: number, sy: number, sz: number } }

-- Base rates per second at full graphics. The first number is what the layer is at 1.0 particleScale.
-- A layer name is "<ZONE>.<what>"; AtmosphereFx builds exactly these emitters once and never adds more.
AtmosphereRules.RATES = {
	["DINO.ash"] = 16, -- falling ash flakes
	["DINO.shimmer"] = 5, -- faint rising heat wisps over the lava
	["FOREST.shaftsL"] = 0.45, -- a handful of light shafts at a time, left of the route
	["FOREST.shaftsR"] = 0.45,
	["FOREST.pollen"] = 12, -- glowing pollen motes (a second layer over Vfx's drifting motes)
	["SNOW.streaks"] = 6, -- wind-blown ground snow streaks across the road
	["ISLAND.glints"] = 16, -- sun glints on the water
	["ISLAND.spray"] = 9, -- sea spray at a shore
	["SPACE.dustL"] = 18, -- star dust streaming past, left
	["SPACE.dustR"] = 18,
	["SPACE.dustTop"] = 10,
	["HUB.blossom"] = 6, -- extra blossom drift beside the plaza
	["HUB.shaft"] = 0.35, -- a soft warm shaft or two
} :: { [string]: number }

-- Zone of a layer name ("DINO.ash" -> "DINO").
function AtmosphereRules.zoneOf(layer: string): string
	return (string.match(layer, "^(%w+)%.") :: string?) or ""
end

-- Emitter Rate for a layer: base * the phone particle scale, 0 when the layer's zone is not active, a culled
-- probe layer, or `enabled` is false (LOW GRAPHICS drops the optional shimmer/light layers via `lowDrops`).
function AtmosphereRules.rate(layer: string, activeZone: string?, particleScale: number, gate: number?): number
	local base = AtmosphereRules.RATES[layer]
	if not base or activeZone == nil or AtmosphereRules.zoneOf(layer) ~= activeZone then
		return 0
	end
	return base * math.max(0, particleScale) * math.clamp(gate or 1, 0, 1)
end

-- Layers LOW GRAPHICS switches off entirely (instead of merely thinning).
AtmosphereRules.LOW_DROPS = { ["DINO.shimmer"] = true, ["FOREST.shaftsL"] = true, ["FOREST.shaftsR"] = true, ["HUB.shaft"] = true, ["ISLAND.spray"] = true } :: { [string]: boolean }

-- How hard the camera is travelling, 0..1 (SPACE streaks). 40 studs/s is a crawl (0), 200 is full flight (1).
function AtmosphereRules.speedFrac(speed: number): number
	return math.clamp((speed - 40) / 160, 0, 1)
end

-- Star-streak length in studs: a dot at rest, a streak at speed.
function AtmosphereRules.streakLength(frac: number): number
	return 0.7 + frac * frac * 5.3
end

-- Star dust travel speed toward the camera (studs/s): a gentle drift at rest, quick at speed.
function AtmosphereRules.dustSpeed(frac: number): number
	return 22 + frac * 70
end

-- Dust rate multiplier: a little thinner when slow, full at speed.
function AtmosphereRules.dustRateScale(frac: number): number
	return 0.55 + 0.45 * frac
end

-- Smoothed camera speed: ignores a teleport (respawn, portal, restart) so a jump never reads as warp speed.
function AtmosphereRules.smoothSpeed(prev: number, moved: number, dt: number): number
	if dt <= 0 then
		return prev
	end
	local inst = moved / dt
	if moved > 150 or inst > 600 then
		return prev * 0.5
	end
	local k = math.clamp(dt * 6, 0, 1)
	return prev + (inst - prev) * k
end

-- Ease a value toward a target at `rate` per second (lights fade in and out, never pop).
function AtmosphereRules.approach(cur: number, target: number, rate: number, dt: number): number
	local step = rate * dt
	if cur < target then
		return math.min(target, cur + step)
	end
	return math.max(target, cur - step)
end

-- Materials that count as lava for the DINO glow light (the map's lava and magma surfaces).
AtmosphereRules.LAVA = { CrackedLava = true } :: { [string]: boolean }
function AtmosphereRules.isLava(materialName: string): boolean
	return AtmosphereRules.LAVA[materialName] == true
end

-- Lava glow light brightness: how many of the probe samples hit lava (0..n) -> 0..MAX, with a slow flicker (t seconds).
AtmosphereRules.LAVA_LIGHT_MAX = 1.3
function AtmosphereRules.lavaTarget(hits: number, samples: number, t: number): number
	if hits <= 0 or samples <= 0 then
		return 0
	end
	local flicker = 0.85 + 0.15 * math.sin(t * 5.1) * math.sin(t * 2.3 + 1)
	return AtmosphereRules.LAVA_LIGHT_MAX * math.clamp(hits / samples, 0, 1) * flicker
end

-- The hub's warm light: a gentle constant glow (golden hour on the plaza).
AtmosphereRules.HUB_LIGHT = 0.5

-- Distance cull for a world-placed layer: on while its surface is within `range` of the camera, fading over the last 30%.
-- Returns the 0..1 gate AtmosphereRules.rate takes.
function AtmosphereRules.cullGate(dist: number?, range: number): number
	if dist == nil then
		return 0
	end
	local fade = range * 0.7
	return math.clamp((range - dist) / (range - fade), 0, 1)
end
AtmosphereRules.GLINT_RANGE = 110 -- camera height above the sea where glints still run
AtmosphereRules.SPRAY_RANGE = 90 -- distance to the shore point where spray runs

return AtmosphereRules
