--!strict
-- Graphics cost rules for low-end devices (docs/audits/perf_review_v21.md PF-02, PF-05, PF-22). Pure numbers, no Roblox
-- types, so tools/tests/graphics_lod_spec.luau pins them:
--   * map fx LOD (client/MapFxLod): the map's baked emitters, Fire and Beams (MapAdapter step "fx", attribute MapFx)
--     emit at base rate x Settings.particleScale() and stop beyond the range where their biggest particle would be
--     under MIN_PX tall on this screen, so a desktop view keeps everything it could see;
--   * post-processing (client/MapFxLod): SunRays off on phone tier and LOW GRAPHICS, Bloom off under LOW GRAPHICS;
--     the shared lighting profiles are never edited;
--   * frame governor and telemetry (client/FrameGovernor, server/Funnels): a 1 ms histogram of frame times, its p50 and
--     p95, the sustained-slow decision and the cleaning of the per-race report a client sends.
local GraphicsLodRules = {}

------------------------------------------------------------------------------------------------------------ map fx LOD

GraphicsLodRules.FX_ATTR = "MapFx" -- set by MapAdapter on every effect its fx step creates
GraphicsLodRules.FX_TICK = 0.5 -- seconds between distance passes (2 Hz)
GraphicsLodRules.MIN_PX = 2 -- a particle under this many screen points tall is a speck: the emitter can stop
GraphicsLodRules.MIN_RANGE = 120 -- never cull nearer than this, whatever the size
GraphicsLodRules.DEFAULT_FOV = 70

-- Screen points per stud at a distance of one stud, for a viewport this many points tall at this vertical FOV.
function GraphicsLodRules.pointsPerStud(viewportY: number, fovDeg: number?): number
	local fov = math.clamp(fovDeg or GraphicsLodRules.DEFAULT_FOV, 1, 120)
	return math.max(1, viewportY) / (2 * math.tan(math.rad(fov) * 0.5))
end

-- Distance beyond which an effect whose biggest particle (or flame, or beam width) is `maxSize` studs shows under MIN_PX.
function GraphicsLodRules.cullRange(maxSize: number, viewportY: number, fovDeg: number?): number
	local size = if maxSize == maxSize and maxSize > 0 then maxSize else 0
	return math.max(GraphicsLodRules.MIN_RANGE, size * GraphicsLodRules.pointsPerStud(viewportY, fovDeg) / GraphicsLodRules.MIN_PX)
end

-- Largest value + envelope over NumberSequence keypoints given as { value, envelope } pairs.
function GraphicsLodRules.maxKeypoint(keys: { { number } }): number
	local m = 0
	for _, k in keys do
		m = math.max(m, (k[1] or 0) + math.abs(k[2] or 0))
	end
	return m
end

-- Distance from a point (already in the box's local frame) to a box of half extents hx, hy, hz; 0 inside.
function GraphicsLodRules.boxDistance(x: number, y: number, z: number, hx: number, hy: number, hz: number): number
	local dx = math.max(math.abs(x) - hx, 0)
	local dy = math.max(math.abs(y) - hy, 0)
	local dz = math.max(math.abs(z) - hz, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Distance from point p to the segment a-b (a beam between its two attachments).
function GraphicsLodRules.segmentDistance(px: number, py: number, pz: number, ax: number, ay: number, az: number, bx: number, by: number, bz: number): number
	local ux, uy, uz = bx - ax, by - ay, bz - az
	local len2 = ux * ux + uy * uy + uz * uz
	local t = 0
	if len2 > 0 then
		t = math.clamp(((px - ax) * ux + (py - ay) * uy + (pz - az) * uz) / len2, 0, 1)
	end
	local cx, cy, cz = ax + ux * t - px, ay + uy * t - py, az + uz * t - pz
	return math.sqrt(cx * cx + cy * cy + cz * cz)
end

-- Live emission rate of a map emitter: base x particle scale in range, 0 beyond it (live particles finish their life,
-- so the edge fades instead of popping).
function GraphicsLodRules.emitterRate(base: number, pscale: number, inRange: boolean): number
	return if inRange then base * pscale else 0
end

-- Fire and Beams have no rate: on in range unless LOW GRAPHICS (only ever switched off when they started on).
function GraphicsLodRules.solidOn(startedOn: boolean, inRange: boolean, low: boolean): boolean
	return startedOn and inRange and not low
end

-------------------------------------------------------------------------------------------------------- post-processing

-- Whether a SkyRally post effect from the lighting profile stays enabled on this device. baseOn: what the profile set.
-- SunRays is a full-screen pass for intensities of 0.06-0.12 on the shipped maps; Bloom is the multi-tap glow.
function GraphicsLodRules.postOn(className: string, baseOn: boolean, phone: boolean, low: boolean): boolean
	if not baseOn then
		return false
	end
	if className == "SunRaysEffect" then
		return not (phone or low)
	elseif className == "BloomEffect" then
		return not low
	end
	return true
end

------------------------------------------------------------------------------------------------- frame governor + report

GraphicsLodRules.HIST_BINS = 250 -- 1 ms bins; the last bin holds every frame of 250 ms or more
GraphicsLodRules.WINDOW = 8 -- seconds per governor window
GraphicsLodRules.MIN_WINDOW_FRAMES = 60 -- a window with fewer frames (a long stall) is not judged
GraphicsLodRules.SLOW_P95_MS = 40 -- a window whose p95 is above this is slow (under 25 fps for 1 frame in 20)
GraphicsLodRules.STRIKES = 2 -- consecutive slow windows before the governor acts (16 s sustained)
GraphicsLodRules.CAP_SCALE = 0.4 -- the particle scale the governor applies (the LOW GRAPHICS share)
GraphicsLodRules.MIN_RACE_FRAMES = 600 -- a race shorter than this (about 10 s) sends no report
GraphicsLodRules.REPORT_MAX_MS = 1000
GraphicsLodRules.TIERS = { desktop = true, phone = true, desktop_low = true, phone_low = true } :: { [string]: boolean }

export type Hist = { counts: { number }, n: number }

function GraphicsLodRules.newHist(): Hist
	return { counts = table.create(GraphicsLodRules.HIST_BINS, 0), n = 0 }
end

function GraphicsLodRules.clearHist(h: Hist)
	table.clear(h.counts)
	for i = 1, GraphicsLodRules.HIST_BINS do
		h.counts[i] = 0
	end
	h.n = 0
end

-- One frame of dt seconds. Bin i holds frames of (i-1, i] ms.
function GraphicsLodRules.addFrame(h: Hist, dt: number)
	if dt ~= dt or dt <= 0 then
		return
	end
	local bin = math.clamp(math.ceil(dt * 1000), 1, GraphicsLodRules.HIST_BINS)
	h.counts[bin] += 1
	h.n += 1
end

-- q in (0, 1]: the upper edge in ms of the bin that holds the q-th frame; 0 for an empty histogram.
function GraphicsLodRules.percentile(h: Hist, q: number): number
	if h.n <= 0 then
		return 0
	end
	local want = math.max(1, math.ceil(h.n * math.clamp(q, 0, 1)))
	local seen = 0
	for i = 1, GraphicsLodRules.HIST_BINS do
		seen += h.counts[i]
		if seen >= want then
			return i
		end
	end
	return GraphicsLodRules.HIST_BINS
end

-- One closed window -> (strikes after it, act now). A short window (a stall, a load) neither counts nor resets.
function GraphicsLodRules.judge(strikes: number, p95: number, frames: number): (number, boolean)
	if frames < GraphicsLodRules.MIN_WINDOW_FRAMES then
		return strikes, false
	end
	if p95 > GraphicsLodRules.SLOW_P95_MS then
		local s = strikes + 1
		return s, s >= GraphicsLodRules.STRIKES
	end
	return 0, false
end

function GraphicsLodRules.tierWord(phone: boolean, low: boolean): string
	return (if phone then "phone" else "desktop") .. (if low then "_low" else "")
end

local function cleanMs(v: any): number?
	if type(v) ~= "number" or v ~= v or v < 1 or v > GraphicsLodRules.REPORT_MAX_MS then
		return nil
	end
	return math.floor(v + 0.5)
end

-- A client's per-race report -> (p50, p95, tier), or nil when anything is off (wrong type, out of range, p50 > p95,
-- an unknown tier word). Only these three values ever reach analytics.
function GraphicsLodRules.cleanReport(p50: any, p95: any, tier: any): (number?, number?, string?)
	local a, b = cleanMs(p50), cleanMs(p95)
	if not a or not b or a > b or type(tier) ~= "string" or not GraphicsLodRules.TIERS[tier] then
		return nil, nil, nil
	end
	return a, b, tier
end

return GraphicsLodRules
