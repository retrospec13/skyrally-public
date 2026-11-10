--!strict
-- Pure rules for the sfx_v2 cue set (client/Sfx plays them; assets/audio/sfx_v2 holds the sources, shared/SfxV2Audio the
-- uploaded ids). No Roblox services here, so tools/tests/sfx_spec.luau checks the table, the cooldowns and the voice
-- limiter under Lune.
--   * ROLES: per cue the suggested Sound.Volume (upload_list.json), a priority (what survives a crowded mix), a
--     cooldown (seconds between two plays of the cue), a pitch jitter, the clip length (when a voice is free again)
--     and, for 3D cues, the roll-off. A cue in the table but not played through client/Sfx (the UI kinds, the
--     countdown) still lives here so the set stays in one place.
--   * Voice limiter: at most MAX_VOICES one-shots at once; a new cue steals the lowest-priority (then oldest) voice,
--     or is dropped when everything playing matters more. Loops are counted apart (MAX_LOOPS).
--   * 3D cues farther than their roll-off max from the camera are skipped (they would be inaudible and still cost a
--     voice); cues of other racers play at OTHER_SCALE of the own-vehicle volume.
local SfxRules = {}

export type Role = {
	volume: number, -- Sound.Volume before the SfxVolume group (upload_list.json)
	priority: number, -- 1 (ambience) .. 10 (never dropped)
	cooldown: number, -- seconds between two plays of this cue
	jitter: number, -- random pitch half-width around the caller's pitch (0 = exactly the pitch asked for)
	length: number, -- seconds at pitch 1
	loop: boolean?,
	minDist: number?, -- 3D roll-off start, studs
	maxDist: number?, -- 3D roll-off end, studs (also the audibility cut-off)
}

SfxRules.MAX_VOICES = 12
SfxRules.MAX_LOOPS = 8
SfxRules.OTHER_SCALE = 0.65
SfxRules.DEFAULT_MIN_DIST = 14
SfxRules.DEFAULT_MAX_DIST = 170
SfxRules.DEFAULT_JITTER = 0.03

SfxRules.ROLES = {
	boost_kick = { volume = 0.6, priority = 6, cooldown = 0.1, jitter = 0.03, length = 0.947 },
	boost_overcharge = { volume = 0.65, priority = 6, cooldown = 0.1, jitter = 0, length = 1.15 },
	boost_loop = { volume = 0.36, priority = 3, cooldown = 0, jitter = 0, length = 1.5, loop = true },
	ring_pass = { volume = 0.48, priority = 5, cooldown = 0.15, jitter = 0.03, length = 0.847 },
	pad_zip = { volume = 0.44, priority = 4, cooldown = 0.15, jitter = 0.03, length = 0.497 },
	pod_pickup = { volume = 0.52, priority = 4, cooldown = 0.05, jitter = 0, length = 0.57 },
	pod_pop = { volume = 0.71, priority = 3, cooldown = 0.05, jitter = 0.05, length = 0.303, minDist = 12, maxDist = 150 },
	countdown_v2 = { volume = 0.94, priority = 10, cooldown = 1, jitter = 0, length = 4.2 },
	lap_ding = { volume = 0.56, priority = 8, cooldown = 1, jitter = 0, length = 1.1 },
	finish_tada = { volume = 0.76, priority = 9, cooldown = 1, jitter = 0, length = 1.9 },
	place_up = { volume = 0.31, priority = 2, cooldown = 0.4, jitter = 0, length = 0.215 },
	place_down = { volume = 0.25, priority = 2, cooldown = 0.4, jitter = 0, length = 0.237 },
	respawn_pop = { volume = 0.58, priority = 6, cooldown = 0.3, jitter = 0.03, length = 0.739 },
	land_thud = { volume = 0.63, priority = 4, cooldown = 0.15, jitter = 0.03, length = 0.417 },
	wall_scrape = { volume = 0.45, priority = 2, cooldown = 0.12, jitter = 0, length = 0.49 },
	wall_bump = { volume = 0.68, priority = 5, cooldown = 0.12, jitter = 0, length = 0.447 },
	crash_hit = { volume = 0.79, priority = 8, cooldown = 0.2, jitter = 0.04, length = 0.947 },
	splash_big = { volume = 0.81, priority = 6, cooldown = 0.3, jitter = 0.03, length = 0.997 },
	splash_small = { volume = 0.57, priority = 4, cooldown = 0.2, jitter = 0.03, length = 0.497 },
	missile_launch = { volume = 0.86, priority = 6, cooldown = 0.05, jitter = 0.04, length = 0.811, minDist = 14, maxDist = 220 },
	missile_loop = { volume = 0.32, priority = 3, cooldown = 0, jitter = 0, length = 1.0, loop = true, minDist = 12, maxDist = 140 },
	missile_explode = { volume = 0.9, priority = 7, cooldown = 0.05, jitter = 0.05, length = 0.947, minDist = 24, maxDist = 260 },
	trap_drop = { volume = 0.72, priority = 3, cooldown = 0.05, jitter = 0.03, length = 0.417 },
	oil_splat = { volume = 0.63, priority = 3, cooldown = 0.05, jitter = 0.03, length = 0.547 },
	oil_slip = { volume = 0.5, priority = 5, cooldown = 0.3, jitter = 0.03, length = 0.796 },
	mine_blast = { volume = 0.76, priority = 7, cooldown = 0.05, jitter = 0.04, length = 0.588, minDist = 20, maxDist = 220 },
	trap_arm = { volume = 0.24, priority = 1, cooldown = 0.15, jitter = 0.03, length = 0.17, minDist = 8, maxDist = 40 },
	shield_up = { volume = 0.56, priority = 5, cooldown = 0.1, jitter = 0, length = 0.886 },
	shield_loop = { volume = 0.28, priority = 3, cooldown = 0, jitter = 0, length = 1.0, loop = true, minDist = 10, maxDist = 120 },
	shield_block = { volume = 0.76, priority = 7, cooldown = 0.1, jitter = 0.03, length = 0.547 },
	shield_break = { volume = 0.82, priority = 6, cooldown = 0.1, jitter = 0.03, length = 0.705 },
	magnet_lock = { volume = 0.59, priority = 5, cooldown = 0.3, jitter = 0.02, length = 0.997 },
	coin_pickup = { volume = 0.5, priority = 3, cooldown = 0.05, jitter = 0, length = 0.447 },
	coin_all = { volume = 0.56, priority = 4, cooldown = 0.5, jitter = 0, length = 1.1 },
	unlock_fanfare = { volume = 0.65, priority = 7, cooldown = 0.5, jitter = 0, length = 1.5 },
	vote_pip = { volume = 0.25, priority = 1, cooldown = 0.1, jitter = 0, length = 0.133 },
	wrong_way = { volume = 0.56, priority = 5, cooldown = 0.6, jitter = 0, length = 0.547 },
	grid_rev = { volume = 0.4, priority = 3, cooldown = 1, jitter = 0.03, length = 0.896 },
} :: { [string]: Role }

-- Major pentatonic over two octaves for the challenge-coin ladder: the Nth coin of a track sounds the Nth note.
SfxRules.COIN_LADDER = { 1, 9 / 8, 5 / 4, 3 / 2, 5 / 3, 2, 9 / 4, 5 / 2 }

function SfxRules.coinPitch(count: number): number
	local n = #SfxRules.COIN_LADDER
	return SfxRules.COIN_LADDER[math.clamp(math.floor(count), 1, n)]
end

-- What a change of the player's coin count says: (ladder step to ring, whether this was the last coin of the track).
-- prev is the count last seen (nil on the first look: a join mid-run is silent); a count that did not rise is a reset.
function SfxRules.coinStep(prev: number?, coins: number, total: number?): (number?, boolean)
	if prev == nil or coins <= prev then
		return nil, false
	end
	return coins, total ~= nil and total > 0 and coins >= total
end

-- Pitch for one play: the caller's base times a random spread of +-jitter (r is a 0..1 roll, math.random() in play).
function SfxRules.pitch(role: string, base: number?, r: number): number
	local def = SfxRules.ROLES[role]
	local jitter = if def then def.jitter else SfxRules.DEFAULT_JITTER
	return (base or 1) * (1 + (r * 2 - 1) * jitter)
end

-- Whether a cue may start: its own cooldown since `lastAt` (nil = never played).
function SfxRules.cooldownOk(role: string, now: number, lastAt: number?): boolean
	local def = SfxRules.ROLES[role]
	if not def then
		return false
	end
	return lastAt == nil or now - lastAt >= def.cooldown
end

-- 3D cues beyond their roll-off max cannot be heard: skip them instead of spending a voice.
function SfxRules.audible(role: string, distance: number): boolean
	local def = SfxRules.ROLES[role]
	local maxDist = if def and def.maxDist then def.maxDist else SfxRules.DEFAULT_MAX_DIST
	return distance <= maxDist
end

function SfxRules.rollOff(role: string): (number, number)
	local def = SfxRules.ROLES[role]
	return (def and def.minDist) or SfxRules.DEFAULT_MIN_DIST, (def and def.maxDist) or SfxRules.DEFAULT_MAX_DIST
end

-- Volume for a racer that is not the local player: the same cue, quieter, so a pile-up behind you does not drown your own.
function SfxRules.otherVolume(volume: number): number
	return volume * SfxRules.OTHER_SCALE
end

-- Seconds a voice stays busy: the clip length at its playback speed.
function SfxRules.duration(role: string, pitch: number): number
	local def = SfxRules.ROLES[role]
	return (if def then def.length else 1) / math.max(pitch, 0.1)
end

export type Voice = { priority: number, startedAt: number, endsAt: number, snd: any? }

-- Removes finished voices in place and returns how many were removed.
function SfxRules.prune(voices: { Voice }, now: number): number
	local removed = 0
	for i = #voices, 1, -1 do
		if voices[i].endsAt <= now then
			table.remove(voices, i)
			removed += 1
		end
	end
	return removed
end

-- Voice limiter. Returns (admit, stealIndex): admit=false drops the new cue; stealIndex (when set) is the voice the
-- caller must stop to make room. The victim is the lowest priority, the oldest among equals; a new cue never evicts a
-- voice that outranks it.
function SfxRules.admit(voices: { Voice }, now: number, priority: number, maxVoices: number?): (boolean, number?)
	SfxRules.prune(voices, now)
	local cap = maxVoices or SfxRules.MAX_VOICES
	if #voices < cap then
		return true, nil
	end
	local victim: number? = nil
	for i, v in voices do
		local best = if victim then voices[victim] else nil
		if best == nil or v.priority < best.priority or (v.priority == best.priority and v.startedAt < best.startedAt) then
			victim = i
		end
	end
	if victim and voices[victim].priority <= priority then
		return true, victim
	end
	return false, nil
end

-- Wall contact (car pinned against a wall). A fresh contact (none for WALL_RESET_S) plays wall_bump once. While the
-- contact continues, the cue hands off to wall_scrape instead of repeating wall_bump, unless the new hit is clearly
-- harder (speed into the wall WALL_HARD_RATIO times the last bump's). `c` is the caller's state from newWallContact;
-- `into` is speed * impact (speed driven into the wall). Returns the cue to play.
SfxRules.WALL_RESET_S = 0.6
SfxRules.WALL_HARD_RATIO = 1.35

export type WallContact = { lastAt: number, into: number }

function SfxRules.newWallContact(): WallContact
	return { lastAt = -math.huge, into = 0 }
end

function SfxRules.wallCue(c: WallContact, now: number, speed: number, impact: number): string
	local into = math.max(0, speed) * math.clamp(impact, 0, 1)
	local fresh = now - c.lastAt > SfxRules.WALL_RESET_S
	local hard = not fresh and into > c.into * SfxRules.WALL_HARD_RATIO + 1
	c.lastAt = now
	if fresh or hard then
		c.into = into
		return "wall_bump"
	end
	c.into = math.max(c.into, into)
	return "wall_scrape"
end

return SfxRules
