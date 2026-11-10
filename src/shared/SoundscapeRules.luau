--!strict
-- Pure soundscape decisions (docs/REMARKABLE.md Batch 2 items 12, 26 and 29), free of Roblox services so the Lune spec
-- tools/tests/soundscape_spec.luau can pin them:
--   12. which ambience bed a zone plays (amb_<zone>), the Storm Cup rain layer, how loud the DINO bed gets near the lava,
--       and the stopgap that keeps the old engine-sample "lava rumble" off every map but DINO (and off DINO once its
--       real bed exists);
--   26. which theme a mode plays (Storm Cup, one per battle kind, falling back to the zone theme), the last-10-seconds
--       clock (tick, tock, the last three, then the air horn) and the clock's duck and tempo;
--   29. the local engine's two-band crossfade, each rival's engine voice, the Doppler pitch of a passing racer, the fly-by
--       moment, the lift-off backfire and the speed wind.
-- Vectors are plain {x, y, z}-free numbers here (callers pass components), so Lune needs no Vector3.
local SoundscapeRules = {}

------------------------------------------------------------------------------------------------------------ 12. ambience

SoundscapeRules.AMB_ZONES = { DINO = true, SNOW = true, ISLAND = true, FOREST = true, SPACE = true, HUB = true } :: { [string]: boolean }
-- Bed level per zone (Sound.Volume before the player's AmbienceVolume): a bed sits under the music, never over it.
SoundscapeRules.AMB_VOLUME = { DINO = 0.5, SNOW = 0.45, ISLAND = 0.42, FOREST = 0.4, SPACE = 0.42, HUB = 0.38 } :: { [string]: number }
SoundscapeRules.STORM_VOLUME = 0.4
SoundscapeRules.CURTAIN_DUCK = 0.35 -- under the track-switch curtain the bed keeps a hint of the old map
SoundscapeRules.LAVA_FLOOR_Y = 14.0 -- the old lava loop's proximity range (SoundJuice): louder near the lava sea
SoundscapeRules.LAVA_CEIL_Y = 120.0

function SoundscapeRules.ambienceCue(zone: any): string?
	if type(zone) ~= "string" or not SoundscapeRules.AMB_ZONES[zone] then
		return nil
	end
	return "amb_" .. string.lower(zone)
end

function SoundscapeRules.ambienceVolume(zone: any): number
	return if type(zone) == "string" then SoundscapeRules.AMB_VOLUME[zone] or 0.4 else 0.4
end

-- The Storm Cup's rain-and-thunder layer plays over the zone bed only while a cup runs, and (economy v3 phase 5) in the
-- hub while a storm race runs elsewhere on the server (hubStorm: workspace.StormRaceLive, or the HubStormQA capture
-- switch). It is the thunder stand-in until the owner OKs a real thunder clap.
function SoundscapeRules.stormLayer(mode: any, hubStorm: any?): boolean
	return mode == "stormcup" or mode == "stormrace" or (mode == "hub" and hubStorm == true)
end

-- 0 high above the lava (LAVA_CEIL_Y and up) .. 1 at the lava floor.
function SoundscapeRules.lavaProximity(altitudeY: number): number
	local span = SoundscapeRules.LAVA_CEIL_Y - SoundscapeRules.LAVA_FLOOR_Y
	return 1 - math.clamp((altitudeY - SoundscapeRules.LAVA_FLOOR_Y) / span, 0, 1)
end

-- The DINO bed swells as you drop toward the lava: x0.7 high up, x1.3 skimming it.
function SoundscapeRules.dinoBedGain(proximity: number): number
	return 0.7 + 0.6 * math.clamp(proximity, 0, 1)
end

-- The stopgap for the lava rumble heard on every map (SoundJuice built LavaAmbienceLoop from the engine sample on every
-- zone): the old loop sounds only on DINO, and only while DINO has no real bed. proximityVolume is the old loop's own
-- altitude-based level (0.10 .. 0.28).
function SoundscapeRules.legacyLavaVolume(zone: any, hasDinoBed: boolean, proximityVolume: number): number
	if zone ~= "DINO" or hasDinoBed then
		return 0
	end
	return proximityVolume
end

------------------------------------------------------------------------------------------------- 26. themes and clock

SoundscapeRules.STORM_THEME = "music_stormcup"
SoundscapeRules.BATTLE_KINDS = { survival = true, egg = true, water = true, hoard = true } :: { [string]: boolean }

-- Theme candidates, best first: the Storm Cup theme in a cup, the battle kind's theme while a battle runs (a finished
-- battle goes back to the map's own theme for the results), then the zone theme (zoneTheme may be nil).
function SoundscapeRules.themeCandidates(zoneTheme: string?, mode: any, battleKind: any, battleState: any): { string }
	local list: { string } = {}
	if mode == "stormcup" or mode == "stormrace" then
		table.insert(list, SoundscapeRules.STORM_THEME)
	elseif mode == "battle" and battleState ~= "over" and type(battleKind) == "string" and SoundscapeRules.BATTLE_KINDS[battleKind] then
		table.insert(list, "music_battle_" .. battleKind)
	end
	if zoneTheme then
		table.insert(list, zoneTheme)
	end
	return list
end

SoundscapeRules.CLOCK_FROM = 10 -- the clock ticks for the last ten seconds
SoundscapeRules.CLOCK_LAST = 3 -- the last three get the hard tick with a ping
SoundscapeRules.CLOCK_DUCK = 0.55 -- the theme steps back so the clock is heard
SoundscapeRules.CLOCK_TEMPO = 1.05 -- and pushes a little
SoundscapeRules.TAPE_STOP = 0.65 -- the theme winds down like a stopped tape under the horn
SoundscapeRules.TAPE_STOP_SPEED = 0.22

-- The cue for the tick on whole second s (10..1): tick and tock alternate (even seconds tick), the last three are hard.
function SoundscapeRules.clockCue(s: number): string?
	if s < 1 or s > SoundscapeRules.CLOCK_FROM then
		return nil
	end
	if s <= SoundscapeRules.CLOCK_LAST then
		return "clock_last"
	end
	return if s % 2 == 0 then "clock_tick" else "clock_tock"
end

-- What the clock does between two looks at the time left (seconds; prevLeft nil = first look, which never fires, so a
-- player who joins at 4 s left hears the next tick, not a burst). Returns ("tick", s) when the shown second
-- (ceil(left)) steps down onto s in 10..1, ("horn", 0) when the time runs out, else nil.
function SoundscapeRules.clockEvent(prevLeft: number?, left: number): (string?, number)
	if prevLeft == nil then
		return nil, 0
	end
	local before = math.ceil(prevLeft)
	local now = math.ceil(left)
	if now >= before then
		return nil, 0
	end
	if left <= 0 then
		return if prevLeft > 0 then "horn" else nil, 0
	end
	if now <= SoundscapeRules.CLOCK_FROM then
		return "tick", now
	end
	return nil, 0
end

-- Whether a clock is in its last ten seconds (duck and tempo on).
function SoundscapeRules.clockActive(left: number?): boolean
	return left ~= nil and left > 0 and left <= SoundscapeRules.CLOCK_FROM
end

-------------------------------------------------------------------------------------------- 29. engines and fly-bys

-- Local engine bands. Pitch p is SoundJuice's 0.75..1.65 speed pitch. The low band was rendered at 0.8 x the reference
-- revs, the high band at 0.8 x ratio (car 4200 / 2400 rpm = 1.75, plane 2500 / 1500 = 1.667), so each plays at the
-- speed that puts it on the same revs; they cross over (equal power) between p 0.95 and 1.35. load (0..1: throttle
-- climbing, a boost) brings the high band in earlier and louder, so a boost snarls.
SoundscapeRules.LOW_REF = 0.8
SoundscapeRules.BAND_RATIO = { car = 1.75, plane = 1.667 } :: { [string]: number }
SoundscapeRules.XFADE_FROM = 0.95
SoundscapeRules.XFADE_TO = 1.35

function SoundscapeRules.engineBands(p: number, vehicle: any, load: number): (number, number, number, number)
	local ratio = SoundscapeRules.BAND_RATIO[if vehicle == "plane" then "plane" else "car"]
	local lowSpeed = p / SoundscapeRules.LOW_REF
	local highSpeed = p / (SoundscapeRules.LOW_REF * ratio)
	local l = math.clamp(load, 0, 1)
	local x = math.clamp((p - SoundscapeRules.XFADE_FROM) / (SoundscapeRules.XFADE_TO - SoundscapeRules.XFADE_FROM) + 0.25 * l, 0, 1)
	local lowGain = math.cos(x * math.pi / 2)
	local highGain = math.min(1, math.sin(x * math.pi / 2) * (1 + 0.25 * l))
	return lowGain, highGain, lowSpeed, highSpeed
end

-- Rival engine voices: a bot keeps one voice for life (its roster id), a player gets one from its user id, so the same
-- rival always sounds the same. Cars: the bratty single, the lumpy V-twin, the turbo six. Planes: the radial prop, its
-- pitch spread so two planes side by side do not phase into one.
SoundscapeRules.CAR_VOICES = { "eng_voice_putt", "eng_voice_twin", "eng_voice_turbo" }
SoundscapeRules.PLANE_VOICES = { "eng_voice_prop" }
-- Each voice's PlaybackSpeed at the reference pitch 1.0 (they were rendered at different revs).
SoundscapeRules.VOICE_BASE = {
	eng_voice_putt = 0.62,
	eng_voice_twin = 1.1,
	eng_voice_turbo = 0.72,
	eng_voice_prop = 0.85,
} :: { [string]: number }
SoundscapeRules.VOICE_SPREAD = { 0.94, 1.0, 1.06, 0.97, 1.03 }

export type Voice = { cue: string, pitch: number }

function SoundscapeRules.voiceFor(id: number, vehicle: any): Voice
	local n = math.abs(math.floor(id))
	local list = if vehicle == "plane" then SoundscapeRules.PLANE_VOICES else SoundscapeRules.CAR_VOICES
	local cue = list[(n % #list) + 1]
	local spread = SoundscapeRules.VOICE_SPREAD[((n // #list) % #SoundscapeRules.VOICE_SPREAD) + 1]
	return { cue = cue, pitch = (SoundscapeRules.VOICE_BASE[cue] or 1) * spread }
end

-- The speed pitch SoundJuice uses for the player's own engine (70..210 studs/s -> 0.75..1.65), shared by the rivals.
function SoundscapeRules.speedPitch(speed: number): number
	return 0.75 + 0.9 * math.clamp((speed - 70) / 140, 0, 1)
end

-- Doppler: f' = f (c + v_listener toward the source) / (c - v_source toward the listener). C is a cartoon speed of
-- sound (real sound is 1225 studs/s): the sweep of a racer passing at 150 studs/s is about +25 % then -20 %, a big
-- "neeeoowww", but never silly; the result is clamped. Components: source position s, source velocity vs, listener
-- position l, listener velocity vl.
SoundscapeRules.SOUND_SPEED = 650
SoundscapeRules.DOPPLER_MIN = 0.7
SoundscapeRules.DOPPLER_MAX = 1.45

function SoundscapeRules.doppler(sx: number, sy: number, sz: number, vsx: number, vsy: number, vsz: number,
	lx: number, ly: number, lz: number, vlx: number, vly: number, vlz: number): number
	local dx, dy, dz = lx - sx, ly - sy, lz - sz
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	if d < 1e-3 then
		return 1
	end
	dx, dy, dz = dx / d, dy / d, dz / d -- unit vector source -> listener
	local c = SoundscapeRules.SOUND_SPEED
	local vs = vsx * dx + vsy * dy + vsz * dz -- source speed toward the listener
	local vl = -(vlx * dx + vly * dy + vlz * dz) -- listener speed toward the source
	local denom = math.max(c * 0.25, c - vs)
	return math.clamp((c + vl) / denom, SoundscapeRules.DOPPLER_MIN, SoundscapeRules.DOPPLER_MAX)
end

-- A fly-by: a rival that was closing on you is now pulling away, it passed close, and fast. radial = closing speed
-- (positive while it approaches). 30 studs/s relative is a boosting rival (boost 165 against full throttle 128) or
-- anything head-on; an ordinary overtake (10-25) only gets the Doppler bend, no whoosh.
SoundscapeRules.FLYBY_DIST = 30
SoundscapeRules.FLYBY_REL_SPEED = 30
SoundscapeRules.FLYBY_COOLDOWN = 1.2

function SoundscapeRules.isFlyby(prevRadial: number, radial: number, dist: number, relSpeed: number): boolean
	return prevRadial > 0 and radial <= 0 and dist <= SoundscapeRules.FLYBY_DIST and relSpeed >= SoundscapeRules.FLYBY_REL_SPEED
end

-- Nearest-racer pick for the (at most MAX_VOICES) rival engine loops. dists: candidate key -> distance (already
-- culled to MAX_DIST by the caller or not). current: the keys holding a voice now. A held voice keeps its slot unless a
-- newcomer is closer by more than HYSTERESIS (so two racers at similar range do not swap voices every scan).
SoundscapeRules.MAX_VOICES = 3
SoundscapeRules.MAX_DIST = 260
SoundscapeRules.HYSTERESIS = 0.8

function SoundscapeRules.pickVoices(dists: { [any]: number }, current: { any }, maxN: number?): { any }
	local n = maxN or SoundscapeRules.MAX_VOICES
	local order: { any } = {}
	for key, d in dists do
		if d <= SoundscapeRules.MAX_DIST then
			table.insert(order, key)
		end
	end
	table.sort(order, function(a, b)
		if dists[a] == dists[b] then
			return tostring(a) < tostring(b)
		end
		return dists[a] < dists[b]
	end)
	local keep: { any } = {}
	local held: { [any]: boolean } = {}
	for _, key in current do
		local d = dists[key]
		if d and d <= SoundscapeRules.MAX_DIST then
			held[key] = true
		end
	end
	-- Fill with the nearest; a held voice counts as HYSTERESIS x its distance (sticky).
	local scored: { any } = table.clone(order)
	table.sort(scored, function(a, b)
		local da = if held[a] then dists[a] * SoundscapeRules.HYSTERESIS else dists[a]
		local db = if held[b] then dists[b] * SoundscapeRules.HYSTERESIS else dists[b]
		if da == db then
			return tostring(a) < tostring(b)
		end
		return da < db
	end)
	for i = 1, math.min(n, #scored) do
		table.insert(keep, scored[i])
	end
	return keep
end

-- Lift-off backfire: the revs fall (decel, studs/s^2, the caller's smoothed value) at a lift, a brake or a boost
-- running out (coasting is 26, a full brake 150, a boost ending about 40), not crash-fast; from high revs; with no
-- boost on; and the last pop was a while ago. roll (0..1) is the caller's random draw: 60 % of qualifying lifts pop,
-- so it stays a surprise.
SoundscapeRules.BACKFIRE_MIN_SPEED = 118
SoundscapeRules.BACKFIRE_DECEL = { 22, 260 }
SoundscapeRules.BACKFIRE_COOLDOWN = 2.5
SoundscapeRules.BACKFIRE_CHANCE = 0.6

function SoundscapeRules.backfire(speed: number, decel: number, boost: any, sinceLast: number, roll: number): boolean
	if speed < SoundscapeRules.BACKFIRE_MIN_SPEED or sinceLast < SoundscapeRules.BACKFIRE_COOLDOWN then
		return false
	end
	if boost == "Standard" or boost == "Overcharge" then
		return false
	end
	return decel >= SoundscapeRules.BACKFIRE_DECEL[1] and decel <= SoundscapeRules.BACKFIRE_DECEL[2] and roll < SoundscapeRules.BACKFIRE_CHANCE
end

-- Speed wind: silent at cruising pace, a rush at full tilt (planes hear more of it: open cockpit).
function SoundscapeRules.windGain(speed: number, vehicle: any): number
	local a = math.clamp((speed - 90) / 120, 0, 1)
	return a * a * (if vehicle == "plane" then 0.55 else 0.35)
end

return SoundscapeRules
