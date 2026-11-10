--!strict
-- Boost / speed VFX tuning and pure maths (client/Vfx boostPunch, wind streaks, vignette; client/BoostPadFx pad
-- anticipation). No Instances here so tools/tests/boost_spec.luau can pin the numbers: the ignite punch stays short,
-- the screen edge layers stay peripheral and faint, and the pad decoration stays capped and culled.
local BoostRules = {}

-- Ignite punch (a boost starts): FOV overshoot on top of the controller's own boost FOV, a small camera trauma burst and
-- an optional ColorCorrection tint that lasts at most 2 frames (ART_BAR: no full-screen flash longer than 2 frames).
BoostRules.FOV_KICK = 4 -- degrees at the peak
BoostRules.FOV_RISE = 0.04 -- seconds up to the peak
BoostRules.FOV_HOLD = 0.15 -- seconds held at the peak (total ~0.15 s before it settles)
BoostRules.FOV_FALL = 0.3 -- seconds back to the boost FOV
BoostRules.TRAUMA_STANDARD = 0.12 -- on top of the controllers' own boost trauma (0.2 / 0.3 cars, 0.22 / 0.34 planes)
BoostRules.TRAUMA_OVERCHARGE = 0.18
BoostRules.TINT_FRAMES = 2
BoostRules.TINT_BRIGHTNESS = 0.05
BoostRules.TINT_SATURATION = 0.15

-- Extra field of view in degrees `t` seconds after the punch started (0 outside the punch).
function BoostRules.fovKick(t: number, over: boolean?): number
	if t < 0 then
		return 0
	end
	local peak = BoostRules.FOV_KICK * (if over then 1.25 else 1)
	if t < BoostRules.FOV_RISE then
		return peak * (t / BoostRules.FOV_RISE)
	end
	if t < BoostRules.FOV_HOLD then
		return peak
	end
	local u = (t - BoostRules.FOV_HOLD) / BoostRules.FOV_FALL
	if u >= 1 then
		return 0
	end
	return peak * (1 - u) * (1 - u) -- quad out
end

function BoostRules.punchDuration(): number
	return BoostRules.FOV_HOLD + BoostRules.FOV_FALL
end

function BoostRules.trauma(over: boolean): number
	return if over then BoostRules.TRAUMA_OVERCHARGE else BoostRules.TRAUMA_STANDARD
end

-- Speed fraction 0..1 for the wind layers: ~cruise (70) is nothing, ~boost pace (170) is full. Planes and cars share it.
BoostRules.SPEED_LO = 70
BoostRules.SPEED_HI = 170

function BoostRules.speedFrac(speed: number): number
	return math.clamp((speed - BoostRules.SPEED_LO) / (BoostRules.SPEED_HI - BoostRules.SPEED_LO), 0, 1)
end

-- World wind streaks (camera-following emitters, two of them): total particles/s from the speed fraction, more while
-- boosting. Nothing under a third of the speed range, so slow flight stays calm. Capped at WIND_MAX.
BoostRules.WIND_START = 0.3
BoostRules.WIND_MAX = 16

function BoostRules.windRate(frac: number, boosting: boolean): number
	-- v28 W1.1: only while boosting or above 90% of the speed range; a few sheets, not a storm.
	if not boosting and frac < 0.9 then
		return 0
	end
	local u = math.clamp((frac - BoostRules.WIND_START) / (1 - BoostRules.WIND_START), 0, 1)
	local r = 4 + 8 * u + (if boosting then 4 else 0)
	return math.min(BoostRules.WIND_MAX, math.floor(r + 0.5))
end

-- Wind streaks as thin tapered Beams (client/Vfx buildWind; replaces the speed_streak particle cards that read as flat
-- translucent rectangles near the vehicle): a small pool of 1-pixel-class lines in camera space, each a Beam whose width
-- tapers from nothing at the tail to WIND_WIDTH at the head and whose transparency fades both ends. They live far from
-- the lens (WIND_NEAR..WIND_FAR studs ahead of the camera, past the vehicle) and out at the screen edges (|x| WIND_X0..X1).
BoostRules.WIND_BEAMS = 6 -- pool size (3 per side), at most this many on screen at once
BoostRules.WIND_SHARE = 0.3 -- beams per unit of windRate (before the particle scale)
BoostRules.WIND_NEAR = 36 -- studs ahead of the camera where a streak ends (its head)
BoostRules.WIND_FAR = 100 -- studs ahead of the camera where it starts
BoostRules.WIND_X0 = 20
BoostRules.WIND_X1 = 36 -- lateral reach (studs each side of the camera axis)
BoostRules.WIND_Y0 = -12
BoostRules.WIND_Y1 = 14
BoostRules.WIND_LEN0 = 9
BoostRules.WIND_LEN1 = 16
BoostRules.WIND_WIDTH = 0.16 -- head width in studs (tail 0)
BoostRules.WIND_LIFE = 0.42 -- seconds to cross WIND_FAR -> WIND_NEAR

-- Number of beams alive for a wind rate and the particle scale (phones / LOW GRAPHICS pass < 1).
function BoostRules.windBeams(rate: number, scale: number): number
	return math.clamp(math.floor(rate * BoostRules.WIND_SHARE * scale + 0.5), 0, BoostRules.WIND_BEAMS)
end

-- Where a fresh streak spawns: side = -1 / 1, u1..u3 in 0..1. Returns x, y and length in camera-local studs.
function BoostRules.windSlot(side: number, u1: number, u2: number, u3: number): (number, number, number)
	local R = BoostRules
	return side * (R.WIND_X0 + (R.WIND_X1 - R.WIND_X0) * u1), R.WIND_Y0 + (R.WIND_Y1 - R.WIND_Y0) * u2, R.WIND_LEN0 + (R.WIND_LEN1 - R.WIND_LEN0) * u3
end

-- Head distance ahead of the camera (studs) and the width/opacity envelope (0..1) at life 0..1.
function BoostRules.windHead(life: number): (number, number)
	local u = math.clamp(life, 0, 1)
	return BoostRules.WIND_FAR + (BoostRules.WIND_NEAR - BoostRules.WIND_FAR) * u, math.sin(u * math.pi)
end

-- Peripheral vignette: opacity of the four edge gradients (0 = invisible). Fades in from 55% of the speed range, never
-- above VIGNETTE_MAX (the edges only; the route in the centre is untouched).
BoostRules.VIGNETTE_START = 0.55
BoostRules.VIGNETTE_MAX = 0.42
BoostRules.EDGE_WIDTH = 0.13 -- screen share each edge gradient covers

function BoostRules.vignette(frac: number, boosting: boolean): number
	local u = math.clamp((frac - BoostRules.VIGNETTE_START) / (1 - BoostRules.VIGNETTE_START), 0, 1)
	local a = u * 0.34 + (if boosting then 0.08 else 0)
	return math.min(BoostRules.VIGNETTE_MAX, a)
end

-- Screen speed lines (client/Vfx): a line's peak opacity is intensity * 0.32, so under this intensity (0.6% opaque)
-- nothing shows and the 16 lines are hidden once instead of rewritten every frame (perf review v21 PF-07).
BoostRules.SPEED_LINES_MIN = 0.02

function BoostRules.speedLinesVisible(intensity: number): boolean
	return intensity >= BoostRules.SPEED_LINES_MIN
end

-- Boost-pad anticipation: only pads near the camera are decorated, from a small fixed pool.
BoostRules.PAD_RADIUS = 150
BoostRules.PAD_POOL = 6
BoostRules.PAD_SCAN = 0.4 -- seconds between distance scans
BoostRules.FLARE_TIME = 0.5

-- Idle pulse 0..1 (slow, ~1.6 s), offset per pad so neighbours do not blink together.
function BoostRules.padPulse(now: number, phase: number): number
	return 0.5 + 0.5 * math.sin(now * 3.9 + phase)
end

function BoostRules.padLight(pulse: number, flare: number): number
	return 0.9 + 1.3 * pulse + 4 * flare
end

function BoostRules.padInRange(dist: number): boolean
	return dist <= BoostRules.PAD_RADIUS
end

-- Indices of the (at most `cap`) nearest pads within the radius; dists[i] is the camera distance of pad i.
function BoostRules.pickPads(dists: { number }, cap: number): { number }
	local idx: { number } = {}
	for i, d in dists do
		if BoostRules.padInRange(d) then
			table.insert(idx, i)
		end
	end
	table.sort(idx, function(a, b)
		return dists[a] < dists[b]
	end)
	while #idx > cap do
		table.remove(idx)
	end
	return idx
end

-- Boost trails at the wingtips / rear corners: shorter than the chase camera's distance divided by the top pace, so
-- the ribbon never reaches the lens (camera 14.5 back at ~170 studs/s is 0.085 s).
BoostRules.TRAIL_LIFE = 0.08

return BoostRules
