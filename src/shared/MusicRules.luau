--!strict
-- Pure music decisions for client/Music (REMARKABLE Batch 1 items 1, 2, 3 and 9), kept free of Roblox services so the
-- Lune spec tools/tests/music_spec.luau can pin them: which theme a zone plays, which boss chase theme and roar a boss
-- gets (with fallbacks), which finish jingle a place earns, when the final-lap surge fires, how fast the theme runs,
-- and how stacked ducks combine.
local MusicRules = {}

MusicRules.THEME_BY_ZONE = {
	HUB = "music_hub",
	DINO = "music_dino",
	SNOW = "music_snow",
	ISLAND = "music_island",
	FOREST = "music_forest",
	SPACE = "music_space",
} :: { [string]: string }

MusicRules.REMATCH_SPEED = 1.04
MusicRules.FINAL_LAP_GAIN = 1.06
MusicRules.FINAL_LAP_GAIN_BOSS = 1.08
MusicRules.SPEED_CAP = 1.12

-- Modes with no lap race (battle has its own results flow; the hub free-roams).
local NO_RACE_MUSIC: { [string]: boolean } = { battle = true, hub = true }

function MusicRules.isBossMode(mode: any): boolean
	return mode == "boss" or mode == "rematch"
end

function MusicRules.zoneTheme(zone: any): string?
	return if type(zone) == "string" then MusicRules.THEME_BY_ZONE[zone] else nil
end

-- Boss chase theme, best first: the zone's own, the shared fallback, the first boss theme (DINO), then the zone theme.
function MusicRules.bossThemeCandidates(zone: any): { string }
	local list: { string } = {}
	if type(zone) == "string" and zone ~= "" then
		table.insert(list, "music_boss_" .. string.lower(zone))
	end
	table.insert(list, "music_boss")
	table.insert(list, "music_boss_dino")
	local theme = MusicRules.zoneTheme(zone)
	if theme then
		table.insert(list, theme)
	end
	return list
end

-- First candidate with an asset id (has(cue) -> boolean), or nil when nothing can play.
function MusicRules.pick(candidates: { string }, has: (string) -> boolean): string?
	for _, cue in candidates do
		if has(cue) then
			return cue
		end
	end
	return nil
end

-- roar_<clips module name lowercased>: "Cinderwing" -> "roar_cinderwing".
function MusicRules.roarCue(clips: any): string?
	return if type(clips) == "string" and clips ~= "" then "roar_" .. string.lower(clips) else nil
end

-- Finish jingle for a place: 1 victory, 2 runner-up, 3 bronze, last of four or more the comic wah-wah, any other
-- place the friendly good-try. nil in modes with no race finish (battle, hub) or for a nonsense rank.
function MusicRules.finishCue(rank: any, total: any, mode: any): string?
	if type(rank) ~= "number" or rank < 1 or NO_RACE_MUSIC[mode] then
		return nil
	end
	local n = if type(total) == "number" then total else 0
	if rank == 1 then
		return "jingle_victory"
	elseif rank == 2 then
		return "jingle_place2"
	elseif rank == 3 then
		return "jingle_place3"
	elseif rank >= n and n >= 4 then
		return "jingle_last"
	end
	return "jingle_midpack"
end

-- Last place on the results card (the sign drops off a nail): same rule as the jingle.
function MusicRules.isLastPlace(rank: any, total: any): boolean
	return type(rank) == "number" and type(total) == "number" and total >= 4 and rank >= total
end

-- The race's lap count: workspace.TotalLaps when the track director sets it, else the shared default.
function MusicRules.totalLaps(attr: any, default: number): number
	return if type(attr) == "number" and attr >= 1 then math.floor(attr) else default
end

-- True on the Lap change that enters the last lap of a real race: more than one lap, a lap race mode, a racer who has
-- not finished (a finished spectator never gets the surge), and a step up from an earlier lap.
function MusicRules.isFinalLapEntry(prevLap: any, lap: any, totalLaps: number, mode: any, finished: any): boolean
	if type(lap) ~= "number" or totalLaps <= 1 or lap ~= totalLaps then
		return false
	end
	if NO_RACE_MUSIC[mode] or finished == true then
		return false
	end
	return type(prevLap) ~= "number" or prevLap < lap
end

function MusicRules.themeSpeed(mode: any): number
	return if mode == "rematch" then MusicRules.REMATCH_SPEED else 1
end

-- Final-lap tempo: about 6 % up, 8 % in boss races (lifting the chase theme), capped so a rematch stays musical.
function MusicRules.finalLapSpeed(base: number, mode: any): number
	local gain = if MusicRules.isBossMode(mode) then MusicRules.FINAL_LAP_GAIN_BOSS else MusicRules.FINAL_LAP_GAIN
	return math.min(MusicRules.SPEED_CAP, base * gain)
end

-- Ducks stack by reason (curtain, roar, finish, sting, secret); the quietest wins, none = full volume.
function MusicRules.duckFactor(ducks: { [string]: number }): number
	local f = 1
	for _, v in ducks do
		f = math.min(f, v)
	end
	return math.clamp(f, 0, 1)
end

-- Secret Stinger: the chip cue for a find kind ("key" gets the long fanfare, anything else the short one).
function MusicRules.secretCue(kind: any): string
	return if kind == "key" then "chip_secret" else "chip_find"
end

return MusicRules
