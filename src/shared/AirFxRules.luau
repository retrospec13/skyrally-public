--!strict
-- Pure tuning and decisions for the plane air effects (client/Vfx wingtip vortices, slipstream wind lines and the water
-- skim; client/FlightController wall-scrape sparks). No Instances, no clock: every function takes its inputs so
-- tools/tests/air_fx_spec.luau can pin the numbers down. All counts are "before Settings.particleScale()".
local AirFxRules = {}

-- ---------------------------------------------------------------- wall-scrape sparks (FlightController -> GroundFx.sparkSpray)
AirFxRules.SCRAPE_SPARKS = 8 -- per contact burst (desktop; GroundFx scales it by particleScale, ~5 on a phone)
AirFxRules.SCRAPE_INTERVAL = 0.12 -- seconds between bursts (CarController's bump cooldown)
AirFxRules.SCRAPE_TRAUMA = 0.04

function AirFxRules.scrapeDue(now: number, last: number): boolean
	return now - last >= AirFxRules.SCRAPE_INTERVAL
end

-- ---------------------------------------------------------------- wingtip vortices / contrails
AirFxRules.VORTEX_SPEED = 150 -- nothing below this speed (the same line as the short vapour Trail)
AirFxRules.VORTEX_SPEED_MAX = 230
AirFxRules.VORTEX_RATE_MAX = 30 -- v21: was 22; particles/s per wingtip at full speed and bank (desktop)
AirFxRules.VORTEX_LIFE = 1 -- seconds a puff stays in the world
AirFxRules.VORTEX_MIN_CAM = 12 -- a remote plane closer to the camera than this emits nothing
AirFxRules.VORTEX_REMOTE_RANGE = 220
AirFxRules.VORTEX_MAX_REMOTE = 5 -- remote planes that may emit at once
AirFxRules.VORTEX_PHONE_SCALE = 0.6 -- at or below this particleScale remote planes draw no contrail
AirFxRules.VORTEX_RACER_MIX = 0.2 -- how much of the racer colour tints the white-blue vapour

-- Rate per wingtip. bankT is |bank| / 90 degrees (0..1); a sharp bank or a barrel roll adds condensation.
function AirFxRules.vortexRate(speed: number, bankT: number, sharp: boolean, roll: boolean, scale: number): number
	if speed < AirFxRules.VORTEX_SPEED then
		return 0
	end
	local speedT = math.clamp((speed - AirFxRules.VORTEX_SPEED) / (AirFxRules.VORTEX_SPEED_MAX - AirFxRules.VORTEX_SPEED), 0, 1)
	local load = 0.3 + 0.3 * speedT + 0.4 * math.clamp(bankT, 0, 1) + (if sharp then 0.2 else 0) + (if roll then 0.3 else 0)
	return math.floor(AirFxRules.VORTEX_RATE_MAX * math.clamp(load, 0, 1) * scale + 0.5)
end

-- Remote planes: only in range, never in the lens, not on a phone / LOW GRAPHICS, and only the first MAX_REMOTE of the frame.
function AirFxRules.remoteVortexAllowed(camDist: number, scale: number, alreadyOn: number): boolean
	return scale > AirFxRules.VORTEX_PHONE_SCALE
		and camDist >= AirFxRules.VORTEX_MIN_CAM
		and camDist <= AirFxRules.VORTEX_REMOTE_RANGE
		and alreadyOn < AirFxRules.VORTEX_MAX_REMOTE
end

function AirFxRules.vortexTint(racer: Color3?): Color3
	local base = Color3.fromRGB(214, 232, 252)
	return if racer then base:Lerp(racer, AirFxRules.VORTEX_RACER_MIX) else base
end

-- ---------------------------------------------------------------- slipstream / rival wake wind lines (cosmetic only)
AirFxRules.DRAFT_MIN = 8 -- studs behind the rival (nearer is a collision, not a wake)
AirFxRules.DRAFT_MAX = 45
AirFxRules.DRAFT_CONE_DEG = 20
AirFxRules.DRAFT_MIN_SPEED = 100 -- the rival must be moving fast enough to leave a wake
AirFxRules.DRAFT_SPEED_RATIO = 0.8 -- and the local plane no slower than this fraction of it (closing or matching)
AirFxRules.DRAFT_RISE = 0.3 -- seconds to fade in
AirFxRules.DRAFT_HOLD = 0.4 -- seconds the wake lingers after the test fails (hysteresis)
AirFxRules.DRAFT_RATE_MAX = 30 -- particles/s per edge box
AirFxRules.DRAFT_TRAIL_SCALE = 0.8 -- the rival-side Trails need at least this particleScale (desktop only)

-- rel = rival position in the local hull's object space (-Z is forward).
function AirFxRules.inSlipstream(relX: number, relY: number, relZ: number, localSpeed: number, rivalSpeed: number): boolean
	local ahead = -relZ
	if ahead < AirFxRules.DRAFT_MIN or ahead > AirFxRules.DRAFT_MAX then
		return false
	end
	if math.sqrt(relX * relX + relY * relY) > ahead * math.tan(math.rad(AirFxRules.DRAFT_CONE_DEG)) then
		return false
	end
	return rivalSpeed >= AirFxRules.DRAFT_MIN_SPEED and localSpeed >= rivalSpeed * AirFxRules.DRAFT_SPEED_RATIO
end

-- One step of the fade: returns the new level (0..1) and the remaining hold time.
function AirFxRules.draftStep(level: number, hold: number, wanted: boolean, dt: number): (number, number)
	if wanted then
		return math.min(1, level + dt / AirFxRules.DRAFT_RISE), AirFxRules.DRAFT_HOLD
	end
	if hold > 0 then
		return level, math.max(0, hold - dt)
	end
	return math.max(0, level - dt / AirFxRules.DRAFT_RISE), 0
end

function AirFxRules.draftRate(level: number, scale: number): number
	return math.floor(AirFxRules.DRAFT_RATE_MAX * level * scale + 0.5)
end

function AirFxRules.draftTrails(scale: number): boolean
	return scale >= AirFxRules.DRAFT_TRAIL_SCALE
end

-- ---------------------------------------------------------------- water skim spray
AirFxRules.SKIM_MIN = 1.5 -- studs over the water surface (below this the plane is in the water: crash logic owns it)
AirFxRules.SKIM_MAX = 16
AirFxRules.SKIM_MIN_SPEED = 90
AirFxRules.SKIM_INTERVAL = 0.14

function AirFxRules.skimActive(height: number, speed: number): boolean
	return height >= AirFxRules.SKIM_MIN and height <= AirFxRules.SKIM_MAX and speed >= AirFxRules.SKIM_MIN_SPEED
end

-- Burst scale: a bigger plume the lower the pass (1.4 at the minimum height down to 0.5 at the maximum).
function AirFxRules.skimIntensity(height: number): number
	local u = math.clamp((height - AirFxRules.SKIM_MIN) / (AirFxRules.SKIM_MAX - AirFxRules.SKIM_MIN), 0, 1)
	return 1.4 - 0.9 * u
end

-- The flat foam Trail is a desktop layer; phones and LOW GRAPHICS get only the burst.
function AirFxRules.skimTrail(scale: number): boolean
	return scale >= 1
end

return AirFxRules
