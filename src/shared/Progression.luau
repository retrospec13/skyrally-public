--!strict
-- Launch unlock graph (docs/LAUNCH_PROGRESSION.md section 3). Pure data and pure functions: no services, no yields,
-- so the server (award gating), the hub portal menus and the completion screen all evaluate one profile the same way,
-- and the Lune specs run it without stubs. SaveService owns the stored record; this module reads only ProgressState.
-- Every count below is computed from the source flags (tokens, boss, keys, battles), never from stored counters, so a
-- stray or stale counter in a save can never open a portal.

local Progression = {}

export type Zone = "DINO" | "SNOW" | "ISLAND" | "FOREST" | "SPACE"
export type Mode = "race" | "coin" | "boss" | "rematch" | "timetrial" | "quickrace" | "battle"
export type TokenKind = "race" | "coin" | "hub"

export type BossState = {
	first: boolean,
	rematch: boolean,
}

-- The progression slice of a saved profile; SaveService.Profile is a superset of this shape.
export type ProgressState = {
	tokens: { [string]: boolean },
	boss: { [string]: BossState },
	keys: { [string]: boolean },
	battles: { [string]: boolean },
	finalBoss: boolean,
	-- trackId -> best finish time in ms. Read only to tell that a map was completed (any placing); old fixtures may omit it.
	bestTimes: { [string]: number }?,
}

export type TrackInfo = {
	id: string,
	zone: Zone?, -- nil for the hub
	vehicle: string,
	hasBoss: boolean,
	hasKey: boolean,
}

export type TokenInfo = {
	id: string,
	kind: TokenKind,
	trackId: string?, -- nil for hub finds
}

export type CompletionSummary = {
	tokens: number,
	tokensTotal: number,
	keys: number,
	keysTotal: number,
	bossFragments: number,
	bossFragmentsTotal: number,
	battleFragments: number,
	battleFragmentsTotal: number,
	battleAmulet: boolean,
	finalBoss: boolean,
	-- Every launch reward held. The screen still says more worlds are coming, never "game complete".
	complete: boolean,
	text: string,
	roadmap: string,
}

Progression.HUB_TRACK = "HUB-0"
Progression.FINAL_BOSS_ID = "HUB-BOSS-1"
-- Progression reward for the completed Battle Amulet; never sold and never stocked in the Gears shop.
Progression.BATTLE_AMULET_LIVERY = "Livery_BattleAmulet"

Progression.ZONES = { "DINO", "SNOW", "ISLAND", "FOREST", "SPACE" } :: { Zone }
-- Zones with a regional boss chain and a hidden key; SPACE has neither at launch (SPACE-BOSS is U3, no fifth battle).
Progression.CHAIN_ZONES = { "DINO", "SNOW", "ISLAND", "FOREST" } :: { Zone }

Progression.TRACKS = {
	["DINO-4"] = { id = "DINO-4", zone = "DINO", vehicle = "plane", hasBoss = true, hasKey = true },
	["SNOW-1"] = { id = "SNOW-1", zone = "SNOW", vehicle = "plane", hasBoss = true, hasKey = true },
	["ISLAND-2"] = { id = "ISLAND-2", zone = "ISLAND", vehicle = "car", hasBoss = true, hasKey = true },
	["FOREST-1"] = { id = "FOREST-1", zone = "FOREST", vehicle = "plane", hasBoss = true, hasKey = true },
	["SPACE-4"] = { id = "SPACE-4", zone = "SPACE", vehicle = "car", hasBoss = false, hasKey = false },
	["HUB-0"] = { id = "HUB-0", zone = nil, vehicle = "car", hasBoss = true, hasKey = false },
} :: { [string]: TrackInfo }

-- One launch race map per zone; boss, coin, key and battle all live on it.
Progression.ZONE_TRACK = {
	DINO = "DINO-4",
	SNOW = "SNOW-1",
	ISLAND = "ISLAND-2",
	FOREST = "FOREST-1",
	SPACE = "SPACE-4",
} :: { [string]: string }

Progression.RACE_TRACKS = { "DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1", "SPACE-4" } :: { string }

-- Tokens held to open each portal. SPACE is absent on purpose: it opens on the final-boss win, not on a count.
Progression.PORTAL_THRESHOLD = {
	DINO = 0,
	SNOW = 1,
	ISLAND = 2,
	FOREST = 4,
} :: { [string]: number }

-- Ground, water edge, high ledge (plane), hidden cove (car); discoverable without any portal.
Progression.HUB_FINDS = { "HubFind_Ground", "HubFind_WaterEdge", "HubFind_Ledge", "HubFind_Cove" } :: { string }

-- Storm Cup ("stormcup", server/StormCup) is not a mode a player opens: the server runs it on the UTC schedule for
-- everyone, and it awards no token, best time or key (Gears and Win Pass only), so it is not listed here.
Progression.MODES = { "race", "coin", "boss", "rematch", "timetrial", "quickrace", "battle" } :: { Mode }

Progression.KEYS_TOTAL = 4
Progression.BOSS_FRAGMENTS_TOTAL = 4
Progression.BATTLE_FRAGMENTS_TOTAL = 4
Progression.FINAL_BOSS_FRAGMENTS = 4

function Progression.raceTokenId(trackId: string): string
	return "race:" .. trackId
end

function Progression.coinTokenId(trackId: string): string
	return "coin:" .. trackId
end

-- Ordered list (race, coin, hub) and lookup of the 14 launch tokens.
Progression.TOKENS = {} :: { string }
Progression.TOKEN_INFO = {} :: { [string]: TokenInfo }

local function addToken(id: string, kind: TokenKind, trackId: string?)
	table.insert(Progression.TOKENS, id)
	Progression.TOKEN_INFO[id] = { id = id, kind = kind, trackId = trackId }
end

for _, trackId in ipairs(Progression.RACE_TRACKS) do
	addToken(Progression.raceTokenId(trackId), "race", trackId)
end
for _, trackId in ipairs(Progression.RACE_TRACKS) do
	addToken(Progression.coinTokenId(trackId), "coin", trackId)
end
for _, findId in ipairs(Progression.HUB_FINDS) do
	addToken(findId, "hub", nil)
end

Progression.TOKENS_TOTAL = #Progression.TOKENS

local MODE_SET: { [string]: boolean } = {}
for _, mode in ipairs(Progression.MODES) do
	MODE_SET[mode] = true
end

local CHAIN_ZONE_SET: { [string]: boolean } = {}
for _, zone in ipairs(Progression.CHAIN_ZONES) do
	CHAIN_ZONE_SET[zone] = true
end

-- Accepts a zone name or a launch track id, so award callers can pass whichever their event carries.
function Progression.zoneOf(zoneOrTrackId: string): Zone?
	if Progression.ZONE_TRACK[zoneOrTrackId] then
		return zoneOrTrackId :: Zone
	end
	local info = Progression.TRACKS[zoneOrTrackId]
	return if info then info.zone else nil
end

function Progression.isChainZone(zone: string): boolean
	return CHAIN_ZONE_SET[zone] == true
end

local function bossState(profile: ProgressState, zone: string): BossState?
	local boss = profile.boss[zone]
	return if type(boss) == "table" then boss else nil
end

-- Only the 14 known ids count; unknown keys left in a save never move a threshold.
function Progression.tokenCount(profile: ProgressState): number
	local n = 0
	for _, id in ipairs(Progression.TOKENS) do
		if profile.tokens[id] == true then
			n += 1
		end
	end
	return n
end

function Progression.keyCount(profile: ProgressState): number
	local n = 0
	for _, zone in ipairs(Progression.CHAIN_ZONES) do
		if profile.keys[zone] == true then
			n += 1
		end
	end
	return n
end

-- First amulet: one fragment per boss rematch win.
function Progression.bossFragmentCount(profile: ProgressState): number
	local n = 0
	for _, zone in ipairs(Progression.CHAIN_ZONES) do
		local boss = bossState(profile, zone)
		if boss and boss.rematch == true then
			n += 1
		end
	end
	return n
end

-- Second amulet: one fragment per battle win.
function Progression.battleFragmentCount(profile: ProgressState): number
	local n = 0
	for _, zone in ipairs(Progression.CHAIN_ZONES) do
		if profile.battles[zone] == true then
			n += 1
		end
	end
	return n
end

function Progression.hasBattleAmulet(profile: ProgressState): boolean
	return Progression.battleFragmentCount(profile) >= Progression.BATTLE_FRAGMENTS_TOTAL
end

function Progression.isFinalBossUnlocked(profile: ProgressState): boolean
	return Progression.bossFragmentCount(profile) >= Progression.FINAL_BOSS_FRAGMENTS
end

-- Owner admin (DECISIONS D22): adminOpen is the admin's runtime map-access bypass (server/AdminService flags, never saved).
-- It branches first and reads no profile; every other caller passes nothing and gets the unchanged gate below.
function Progression.isPortalOpen(profile: ProgressState, zone: string, adminOpen: boolean?): boolean
	if adminOpen == true then
		return Progression.ZONE_TRACK[zone] ~= nil
	end
	if zone == "SPACE" then
		return profile.finalBoss == true
	end
	local threshold = Progression.PORTAL_THRESHOLD[zone]
	if threshold == nil then
		return false
	end
	return Progression.tokenCount(profile) >= threshold
end

local function isHubModeUnlocked(profile: ProgressState, mode: string): boolean
	-- The hub loop road hosts only HUB-BOSS-1 at launch; replays stay open once it is unlocked.
	return mode == "boss" and Progression.isFinalBossUnlocked(profile)
end

-- Whether this map's race was ever finished: a saved best time (every finished race, quick race or time trial writes one,
-- whatever the placing) or the race win token (older records). Derived from existing saved fields, so a profile saved
-- before battles opened on completion needs no migration.
function Progression.mapCompleted(profile: ProgressState, trackId: string): boolean
	local times = profile.bestTimes
	local ms = if times then times[trackId] else nil
	if type(ms) == "number" and ms > 0 then
		return true
	end
	return profile.tokens[Progression.raceTokenId(trackId)] == true
end

-- How a zone's battle opened for this player: "complete" (map finished once), "key" (hidden key only) or nil (locked).
-- "complete" wins when both hold. Does not look at the portal; isModeUnlocked adds that gate.
function Progression.battleAccess(profile: ProgressState, trackId: string): string?
	local info = Progression.TRACKS[trackId]
	if not info or not info.hasKey or not info.zone then
		return nil
	end
	if Progression.mapCompleted(profile, trackId) then
		return "complete"
	end
	if profile.keys[info.zone] == true then
		return "key"
	end
	return nil
end

-- Zones whose battle this player may start now, in chain order (portal open and access held). adminOpen: D22 bypass.
function Progression.battleZones(profile: ProgressState, adminOpen: boolean?): { string }
	local out: { string } = {}
	for _, zone in ipairs(Progression.CHAIN_ZONES) do
		local trackId = Progression.ZONE_TRACK[zone]
		if Progression.isModeUnlocked(profile, trackId, "battle", adminOpen) then
			table.insert(out, zone)
		end
	end
	return out
end

-- Whether `mode` exists on `trackId` at all (independent of any profile): the hub hosts only its boss; SPACE-4 has no boss,
-- rematch or battle; a battle needs the zone's key track.
function Progression.modeExists(trackId: string, mode: string): boolean
	local info = Progression.TRACKS[trackId]
	if not info or not MODE_SET[mode] then
		return false
	end
	if trackId == Progression.HUB_TRACK then
		return mode == "boss"
	end
	if mode == "battle" then
		return info.hasKey == true
	end
	if mode == "boss" or mode == "rematch" then
		return info.hasBoss == true
	end
	return true
end

-- adminOpen (DECISIONS D22): the admin's runtime bypass opens every mode that exists, before any profile read.
function Progression.isModeUnlocked(profile: ProgressState, trackId: string, mode: string, adminOpen: boolean?): boolean
	if adminOpen == true then
		return Progression.modeExists(trackId, mode)
	end
	local info = Progression.TRACKS[trackId]
	if not info or not MODE_SET[mode] then
		return false
	end
	if trackId == Progression.HUB_TRACK then
		return isHubModeUnlocked(profile, mode)
	end
	local zone = info.zone
	if not zone or not Progression.isPortalOpen(profile, zone) then
		return false
	end
	if mode == "race" or mode == "timetrial" or mode == "quickrace" then
		return true
	end
	local raceWon = profile.tokens[Progression.raceTokenId(trackId)] == true
	if not info.hasBoss then
		-- SPACE-4 has no boss at launch: its coin challenge follows its own race win, like every coin challenge
		-- follows a win on that track; no boss, rematch or battle exists there.
		return mode == "coin" and raceWon
	end
	local boss = bossState(profile, zone)
	if mode == "boss" then
		return raceWon
	elseif mode == "coin" then
		return boss ~= nil and boss.first == true
	elseif mode == "rematch" then
		return profile.tokens[Progression.coinTokenId(trackId)] == true
	elseif mode == "battle" then
		-- Side chain: never the token thresholds or the boss chain. Finishing the zone's map race once (any placing) or
		-- finding its hidden key opens it.
		return Progression.battleAccess(profile, trackId) ~= nil
	end
	return false
end

-- Unlocked modes on one track in menu order, for the hub portal mode list and the track exit menu.
function Progression.modesFor(profile: ProgressState, trackId: string): { Mode }
	local out: { Mode } = {}
	for _, mode in ipairs(Progression.MODES) do
		if Progression.isModeUnlocked(profile, trackId, mode) then
			table.insert(out, mode)
		end
	end
	return out
end

-- Flat set of everything currently open ("portal:SNOW", "mode:DINO-4:boss", "finalBossUnlocked", "battleAmulet").
-- Diffing two sets tells the results screen what an award just opened.
function Progression.unlockSet(profile: ProgressState): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, zone in ipairs(Progression.ZONES) do
		if Progression.isPortalOpen(profile, zone) then
			set["portal:" .. zone] = true
		end
	end
	for trackId in pairs(Progression.TRACKS) do
		for _, mode in ipairs(Progression.MODES) do
			if Progression.isModeUnlocked(profile, trackId, mode) then
				set["mode:" .. trackId .. ":" .. mode] = true
			end
		end
	end
	if Progression.isFinalBossUnlocked(profile) then
		set.finalBossUnlocked = true
	end
	if Progression.hasBattleAmulet(profile) then
		set.battleAmulet = true
	end
	return set
end

function Progression.newlyUnlocked(before: { [string]: boolean }, after: { [string]: boolean }): { string }
	local out: { string } = {}
	for key in pairs(after) do
		if not before[key] then
			table.insert(out, key)
		end
	end
	table.sort(out)
	return out
end

-- v38 (results "what is next" bar): the ONE next goal for this profile, in the order the adventure opens: the next
-- world portal by Sky Tokens, then the hub boss by boss fragments, then the final-boss win that opens SPACE, then the
-- rest of the Sky Tokens. nil when everything is done. label: the goal's name; have/need: the bar; unit: what fills it.
export type NextUnlock = { key: string, label: string, have: number, need: number, unit: string }
function Progression.nextUnlock(profile: ProgressState): NextUnlock?
	local tokens = Progression.tokenCount(profile)
	for _, zone in ipairs(Progression.CHAIN_ZONES) do
		local need = Progression.PORTAL_THRESHOLD[zone]
		if need and tokens < need then
			return { key = "portal_" .. zone, label = zone .. " WORLD", have = tokens, need = need, unit = "token" }
		end
	end
	if not Progression.isFinalBossUnlocked(profile) then
		return {
			key = "hub_boss",
			label = "HUB BOSS",
			have = Progression.bossFragmentCount(profile),
			need = Progression.FINAL_BOSS_FRAGMENTS,
			unit = "fragment",
		}
	end
	if profile.finalBoss ~= true then
		return { key = "portal_SPACE", label = "SPACE WORLD", have = 0, need = 1, unit = "boss" }
	end
	if tokens < Progression.TOKENS_TOTAL then
		return { key = "all_tokens", label = "ALL SKY TOKENS", have = tokens, need = Progression.TOKENS_TOTAL, unit = "token" }
	end
	return nil
end

function Progression.completion(profile: ProgressState): CompletionSummary
	local tokens = Progression.tokenCount(profile)
	local keys = Progression.keyCount(profile)
	local bossFragments = Progression.bossFragmentCount(profile)
	local battleFragments = Progression.battleFragmentCount(profile)
	local finalBoss = profile.finalBoss == true
	local complete = tokens == Progression.TOKENS_TOTAL
		and keys == Progression.KEYS_TOTAL
		and bossFragments == Progression.BOSS_FRAGMENTS_TOTAL
		and battleFragments == Progression.BATTLE_FRAGMENTS_TOTAL
		and finalBoss
	local text = string.format(
		"%d/%d tokens, %d/%d keys, %d/%d boss fragments, %d/%d battle fragments, %s",
		tokens,
		Progression.TOKENS_TOTAL,
		keys,
		Progression.KEYS_TOTAL,
		bossFragments,
		Progression.BOSS_FRAGMENTS_TOTAL,
		battleFragments,
		Progression.BATTLE_FRAGMENTS_TOTAL,
		if finalBoss then "final boss beaten" else "final boss not yet beaten"
	)
	if complete then
		text ..= "; more worlds coming"
	end
	return {
		tokens = tokens,
		tokensTotal = Progression.TOKENS_TOTAL,
		keys = keys,
		keysTotal = Progression.KEYS_TOTAL,
		bossFragments = bossFragments,
		bossFragmentsTotal = Progression.BOSS_FRAGMENTS_TOTAL,
		battleFragments = battleFragments,
		battleFragmentsTotal = Progression.BATTLE_FRAGMENTS_TOTAL,
		battleAmulet = battleFragments >= Progression.BATTLE_FRAGMENTS_TOTAL,
		finalBoss = finalBoss,
		complete = complete,
		text = text,
		roadmap = "More worlds arrive in updates; SPACE-BOSS, the encounter that uses both amulets, comes in a later update.",
	}
end

return Progression
