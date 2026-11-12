--!strict
-- Exhaust flame tuning (particle layers) for planes and cars. Pure numbers and maths, no Roblox types, so
-- tools/tests/flame_spec.luau can pin the rules and a Studio verifier can retune everything from THIS block.
-- client/Vfx builds up to 3 ParticleEmitters per FlameNozzle* attachment (core, sparks, smoke) and each frame asks
-- FlameRules.rate(...) for the live emission rate and FlameRules.active(...) for the cull decision; when the blend moves
-- it asks FlameRules.look(...) for the layer's speed, lifetime, size and colours.
--
-- State blend: every value runs pilot -> cruise by throttle `thr` (0..1 of top speed), then toward the BOOST value by
-- `heat` (0..1, standard boost) and toward the OVERCHARGE value by `over` (0..1). A layer value is {pilot, cruise, boost, over}.
-- `scale` is the nozzle's FlameScale attribute (plane 1.0, each car pipe 0.55): it scales size and length, rate by sqrt.
-- Flame length is about speed * life; keep the whole flame short so it never fills the chase camera (plane scale 1:
-- core ~1 stud idle, ~3.4 studs boosting).
local FlameRules = {}

-- ---------------------------------------------------------------- tuning (edit here)
FlameRules.CULL_DIST = 300 -- studs from the camera: beyond this the emitters are disabled
-- Phone tier, other racers only (perf review v21 PF-03): a 1-3.4 stud flame is a few points tall at this range on a
-- 390-point-high phone view, so a rival's flame stops there; the local vehicle keeps CULL_DIST.
FlameRules.PHONE_REMOTE_CULL_DIST = 120
FlameRules.FULL_SPEED = 128 -- Speed at full throttle (PlaneConfig.FULL_THROTTLE_SPEED / CarConfig.TOP_SPEED)
FlameRules.MIN_RATE = 2 -- never below this while active and the layer is on (a pilot light always flickers)
FlameRules.PILOT_FLICKER = 0.45 -- idle rate wobble amplitude (0..1) at PILOT_FLICKER_HZ, fades out with throttle
FlameRules.PILOT_FLICKER_HZ = 9
FlameRules.RING_TIME = 0.28 -- boost-start shock ring (mesh pulse, kept)
FlameRules.RING_D0 = 1.0
FlameRules.RING_D1 = 5.5
FlameRules.RING_THICK = 0.044

export type Quad = { number } -- {pilot, cruise, boost, over}
export type Rgb = { number } -- 0..1 triplet
export type Layer = {
	tex: string, -- FlipFx sheet name
	rate: Quad, -- particles per second at scale 1
	speed: Quad, -- studs/s along the exhaust (backwards)
	life: Quad, -- seconds
	size: Quad, -- start size in studs at scale 1
	sizeEnd: number, -- end size as a multiple of the start size
	spread: number, -- degrees
	lightEmission: number,
	lockedToPart: boolean, -- true: the layer rides the vehicle; false: it is left behind in the world
	accel: number, -- world-up drift (studs/s^2; negative falls)
	drag: number,
	color0: { Rgb }, -- birth colour per state: {cruise, boost, over}
	color1: { Rgb }, -- death colour per state
	alpha0: number, -- birth / mid / death transparency
	alphaMid: number,
	alpha1: number,
}

FlameRules.LAYERS = {
	-- Flipbook fire loop: the flame body.
	core = {
		tex = "fire_loop_8x8",
		rate = { 6, 14, 24, 28 },
		speed = { 5, 8, 13, 14 },
		life = { 0.16, 0.2, 0.26, 0.28 },
		size = { 0.55, 0.9, 1.2, 1.3 },
		sizeEnd = 0.35,
		spread = 6,
		lightEmission = 0.85,
		lockedToPart = true,
		accel = 0,
		drag = 0,
		color0 = { { 1.0, 0.86, 0.55 }, { 0.75, 0.88, 1.0 }, { 0.7, 1.0, 0.8 } },
		color1 = { { 1.0, 0.4, 0.12 }, { 1.0, 0.55, 0.2 }, { 0.2, 0.9, 0.45 } },
		alpha0 = 0.05, alphaMid = 0.25, alpha1 = 1,
	},
	-- Hot sparks (ember texture): a few fast specks that fall behind.
	sparks = {
		tex = "ember",
		rate = { 0, 5, 14, 18 },
		speed = { 4, 7, 11, 12 },
		life = { 0.25, 0.3, 0.35, 0.4 },
		size = { 0.2, 0.28, 0.36, 0.4 },
		sizeEnd = 0.35,
		spread = 16,
		lightEmission = 1,
		lockedToPart = false,
		accel = -14,
		drag = 1,
		color0 = { { 1.0, 0.8, 0.4 }, { 1.0, 0.85, 0.6 }, { 0.6, 1.0, 0.7 } },
		color1 = { { 1.0, 0.35, 0.1 }, { 1.0, 0.45, 0.15 }, { 0.2, 0.9, 0.4 } },
		alpha0 = 0, alphaMid = 0.1, alpha1 = 1,
	},
	-- Soft heat / smoke trail: faint, left in the world behind the tail.
	smoke = {
		tex = "smoke_puff_8x8",
		rate = { 3, 6, 12, 12 },
		speed = { 3, 4, 6, 6 },
		life = { 0.5, 0.65, 0.8, 0.8 },
		size = { 0.5, 0.7, 1.0, 1.0 },
		sizeEnd = 2.2,
		spread = 10,
		lightEmission = 0,
		lockedToPart = false,
		accel = 2,
		drag = 2,
		color0 = { { 0.5, 0.46, 0.44 }, { 0.46, 0.46, 0.5 }, { 0.4, 0.55, 0.45 } },
		color1 = { { 0.78, 0.76, 0.74 }, { 0.78, 0.78, 0.82 }, { 0.7, 0.85, 0.75 } },
		alpha0 = 0.55, alphaMid = 0.7, alpha1 = 1,
	},
} :: { [string]: Layer }

-- Emitter creation order (also the per-nozzle budget: 3).
FlameRules.ORDER = { "core", "sparks", "smoke" }

-- ---------------------------------------------------------------- rules
local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Blend of a {pilot, cruise, boost, over} value.
function FlameRules.blend(q: Quad, thr: number, heat: number, over: number): number
	local v = lerp(q[1], q[2], math.clamp(thr, 0, 1))
	v = lerp(v, q[3], math.clamp(heat, 0, 1))
	return lerp(v, q[4], math.clamp(over, 0, 1))
end

-- Colour blend over {cruise, boost, over}.
function FlameRules.blendColor(c: { Rgb }, heat: number, over: number): Rgb
	local h, o = math.clamp(heat, 0, 1), math.clamp(over, 0, 1)
	local a, b, d = c[1], c[2], c[3]
	return {
		lerp(lerp(a[1], b[1], h), d[1], o),
		lerp(lerp(a[2], b[2], h), d[2], o),
		lerp(lerp(a[3], b[3], h), d[3], o),
	}
end

export type Look = {
	speed: number, life: number, size0: number, size1: number, c0: Rgb, c1: Rgb, spread: number,
}

-- Everything about a layer except the live rate (written on a state change, not every frame).
function FlameRules.look(name: string, thr: number, heat: number, over: number, scale: number): Look
	local L = FlameRules.LAYERS[name]
	local size0 = FlameRules.blend(L.size, thr, heat, over) * scale
	return {
		speed = FlameRules.blend(L.speed, thr, heat, over) * math.sqrt(scale),
		life = FlameRules.blend(L.life, thr, heat, over),
		size0 = size0,
		size1 = size0 * L.sizeEnd,
		c0 = FlameRules.blendColor(L.color0, heat, over),
		c1 = FlameRules.blendColor(L.color1, heat, over),
		spread = L.spread,
	}
end

-- Approximate flame length in studs (speed * life).
function FlameRules.length(name: string, thr: number, heat: number, over: number, scale: number): number
	local l = FlameRules.look(name, thr, heat, over, scale)
	return l.speed * l.life
end

-- Live emission rate (particles/s). The pilot flicker wobbles an idle flame, fading out as throttle rises.
-- pscale: Settings.particleScale() (1 desktop, 0.6 phone tier, 0.4 LOW GRAPHICS; omitted = 1); MIN_RATE still holds.
function FlameRules.rate(name: string, thr: number, heat: number, over: number, scale: number, now: number, phase: number, pscale: number?): number
	local L = FlameRules.LAYERS[name]
	local r = FlameRules.blend(L.rate, thr, heat, over) * math.sqrt(scale) * (pscale or 1)
	if r <= 0 then
		return 0
	end
	local idle = (1 - math.clamp(thr * 4, 0, 1)) * (1 - math.clamp(heat, 0, 1))
	if idle > 0 then
		local w = math.noise(now * FlameRules.PILOT_FLICKER_HZ, phase + 0.37) * 2
		r *= 1 + FlameRules.PILOT_FLICKER * idle * math.clamp(w, -1, 1)
	end
	return math.max(r, FlameRules.MIN_RATE)
end

-- v38-feel: a car pipe (FlameScale under 1) grows while boosting, so the boost reads at the chase camera (at 0.55 the
-- boosted core was a ~0.7-stud speck behind the body). Planes (scale 1) keep their flame. Returns the scale multiplier.
FlameRules.PIPE_BOOST_GROW = 1.0 -- standard boost: x2 (0.55 -> 1.1)
FlameRules.PIPE_OVER_GROW = 0.5 -- overcharge on top: x2.5 (0.55 -> 1.375)
function FlameRules.boostScale(scale: number, heat: number, over: number): number
	if scale >= 1 then
		return 1
	end
	return 1 + FlameRules.PIPE_BOOST_GROW * math.clamp(heat, 0, 1) + FlameRules.PIPE_OVER_GROW * math.clamp(over, 0, 1)
end

-- Emitters run only near the camera and not under LOW GRAPHICS. remoteOnPhone: a rival's vehicle on a phone-tier device
-- (nil or false keeps CULL_DIST).
function FlameRules.active(dist: number, lowGraphics: boolean, remoteOnPhone: boolean?): boolean
	return not lowGraphics and dist <= (if remoteOnPhone == true then FlameRules.PHONE_REMOTE_CULL_DIST else FlameRules.CULL_DIST)
end

return FlameRules
