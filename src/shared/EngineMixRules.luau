--!strict
-- Engine mix rules (audio-v2; owner 2026-10-20: "the engine running sound needs to be removed when not doing anything or
-- see what mario kart does"). Pure maths, no services; client/SoundJuice applies the result to the engine loops and
-- tools/tests/engine_mix_spec.luau pins the curve.
--   * Idle is silent: a vehicle that is stopped and off the throttle has level 0 and fades out within FADE_SECONDS.
--   * Driving is a subtle low layer well under the music: full speed and full throttle reach CEILING (0.4) of the
--     engine loops' base gain, never the old constant drone.
--   * Short accents (throttle-up, boost, landing) swell the layer for a fraction of a second, capped at MAX_LEVEL.
--   * The ENGINE SOUND setting (shared/SettingsRules engineSound) is a hard gate: off = level 0 for everything.
local EngineMixRules = {}

EngineMixRules.IDLE_SPEED = 6 -- studs/s: at or below this, with no throttle, the engine is silent
EngineMixRules.IDLE_THROTTLE = 0.08 -- throttle at or below this counts as off
EngineMixRules.FULL_SPEED = 120 -- studs/s where the speed term is full
EngineMixRules.CEILING = 0.4 -- driving level at full speed and full throttle (share of the loops' base gain)
EngineMixRules.COAST_SHARE = 0.55 -- level share kept at speed with the throttle released
EngineMixRules.LAUNCH_SHARE = 0.25 -- level share of throttle held from a standstill (the launch rev)
EngineMixRules.BOOST_GAIN = 1.2 -- multiplier while a boost lasts
EngineMixRules.MAX_LEVEL = 0.55 -- accents included
EngineMixRules.ATTACK_RATE = 6 -- 1/s: level rises toward its target
EngineMixRules.RELEASE_RATE = 9 -- 1/s: level falls toward silence (e^-4.5 at 0.5 s)
EngineMixRules.SNAP_OFF = 0.012 -- a level this low is silence: the loop stops
EngineMixRules.FADE_SECONDS = 0.5 -- a full level is silent within this long of stopping
EngineMixRules.STALE_SECONDS = 0.2 -- no engine step for this long (no vehicle driving it) counts as idle: fade and stop

-- Accent kinds: amp = peak added level, seconds = length of the swell.
EngineMixRules.ACCENTS = {
	throttle = { amp = 0.12, seconds = 0.4 },
	boost = { amp = 0.16, seconds = 0.6 },
	land = { amp = 0.12, seconds = 0.35 },
} :: { [string]: { amp: number, seconds: number } }

-- A throttle press from rest (below LOW) to firm (at or above HIGH) is a throttle-up accent, at most one per COOLDOWN.
EngineMixRules.THROTTLE_LOW = 0.2
EngineMixRules.THROTTLE_HIGH = 0.6
EngineMixRules.THROTTLE_COOLDOWN = 1.5

local function smooth(x: number): number
	local t = math.clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Target level 0..CEILING*BOOST_GAIN for a vehicle state. enabled = the ENGINE SOUND setting.
function EngineMixRules.target(speed: number, throttle: number, boosting: boolean, enabled: boolean): number
	if not enabled then
		return 0
	end
	local v = math.abs(speed)
	local thr = math.clamp(throttle, 0, 1)
	if v <= EngineMixRules.IDLE_SPEED and thr <= EngineMixRules.IDLE_THROTTLE then
		return 0
	end
	local moving = smooth((v - EngineMixRules.IDLE_SPEED) / (EngineMixRules.FULL_SPEED - EngineMixRules.IDLE_SPEED))
	local drive = moving * (EngineMixRules.COAST_SHARE + (1 - EngineMixRules.COAST_SHARE) * thr)
	local launch = thr * EngineMixRules.LAUNCH_SHARE * (1 - moving)
	local level = (drive + launch) * EngineMixRules.CEILING
	if boosting then
		level *= EngineMixRules.BOOST_GAIN
	end
	return level
end

-- Eases a level toward its target (attack up, faster release down) and snaps a fading level to exact silence.
function EngineMixRules.ease(current: number, target: number, dt: number): number
	local rate = if target > current then EngineMixRules.ATTACK_RATE else EngineMixRules.RELEASE_RATE
	local nextLevel = current + (target - current) * (1 - math.exp(-rate * math.max(0, dt)))
	if target <= 0 and nextLevel < EngineMixRules.SNAP_OFF then
		return 0
	end
	return nextLevel
end

-- The accent's added level `t` seconds after it began (a half-sine swell), 0 for an unknown kind or after it ends.
function EngineMixRules.accentLevel(kind: string, t: number): number
	local a = EngineMixRules.ACCENTS[kind]
	if not a or t < 0 or t >= a.seconds then
		return 0
	end
	return a.amp * math.sin(math.pi * t / a.seconds)
end

-- The level to apply this frame: the eased base plus the accent swell, capped, and 0 when the setting is off.
function EngineMixRules.final(level: number, accent: number, enabled: boolean): number
	if not enabled then
		return 0
	end
	return math.clamp(level + accent, 0, EngineMixRules.MAX_LEVEL)
end

-- Throttle-up detector: true on the frame the throttle rises from rest to firm (prev < LOW, now >= HIGH) when the cooldown
-- has passed. `since` = seconds since the last throttle accent.
function EngineMixRules.throttleUp(prevThrottle: number, throttle: number, since: number): boolean
	return prevThrottle < EngineMixRules.THROTTLE_LOW and throttle >= EngineMixRules.THROTTLE_HIGH and since >= EngineMixRules.THROTTLE_COOLDOWN
end

-- True when the engine has not been stepped for STALE_SECONDS (under the map-swap curtain, a respawn fade, a scripted
-- ride, out of a vehicle): the client fades the loops to silence instead of holding their last driving volume.
function EngineMixRules.stale(now: number, lastStepAt: number): boolean
	return now - lastStepAt > EngineMixRules.STALE_SECONDS
end

return EngineMixRules
