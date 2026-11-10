--!strict
-- Badge rules (social lane). Pure: no BadgeService, no clock, specced in tools/tests/badges_spec.luau. server/BadgeAwards
-- owns the Roblox side (ids, UserHasBadgeAsync cache, AwardBadge).
--
-- Ten badges. Each is judged from the saved profile (so an account that already earned it before the badge existed gets it
-- on its next join) and, for the finish that just happened, from the finish itself (so a profile that has not loaded yet
-- still earns the first-finish badge). The first five read only the flags SaveService already keeps; the five storm
-- badges (economy v3 phase 5) read the storm record's counters (profile.storm.races / dragonWins, via StormRules.read,
-- so an old profile reads zeros), and the finish itself for the first storm finish and the first dragon win.
-- server/StormShards counts the finish before BadgeAwards judges it (init.server's finishHook order).
local LeaderboardRules = require(script.Parent:WaitForChild("LeaderboardRules"))
local StormRules = require(script.Parent:WaitForChild("StormRules"))
local StormConfig = require(script.Parent:WaitForChild("StormConfig"))

local BadgeRules = {}

export type Def = { key: string, title: string, description: string }

-- The rows the owner creates in Creator Hub (docs/BADGES.md repeats them). Order is award order.
BadgeRules.DEFS = {
	{ key = "first_race", title = "First Flight", description = "Finish your first race in Sky Rally." },
	{ key = "first_win", title = "Top of the Podium", description = "Win a race: cross the line in first place." },
	{ key = "first_boss", title = "Boss Buster", description = "Beat your first boss." },
	{ key = "all_tracks", title = "World Traveller", description = "Race on every track: Dino Ridge, Frostpeak, Sunreef Isles, Windmill Vale and Neon Moon." },
	{ key = "three_star", title = "Three-Star Racer", description = "Earn all three stars on any one track: win the race, win the coin challenge and beat the boss." },
	-- Storm race badges (economy v3 phase 5, O7).
	{ key = "storm_racer", title = "Storm Racer", description = "Finish a storm race." },
	{ key = "dragon_slayer", title = "Dragon Slayer", description = "Beat the storm dragon in a storm race." },
	{ key = "dragon_hunter", title = "Dragon Hunter", description = "Beat the storm dragon 5 times." },
	{ key = "dragon_bane", title = "Dragon Bane", description = "Beat the storm dragon 25 times." },
	{ key = "stormbreaker", title = "Stormbreaker", description = "Beat the storm dragon 100 times." },
} :: { Def }

BadgeRules.KEYS = {} :: { string }
for _, d in BadgeRules.DEFS do
	table.insert(BadgeRules.KEYS, d.key)
end

export type Profile = {
	tokens: { [string]: boolean }?,
	boss: { [string]: { first: boolean?, rematch: boolean? } }?,
	finalBoss: boolean?,
	bestTimes: { [string]: number }?,
	storm: any?, -- StormRules.read shape
}

-- The finish that just happened (RaceManager.awardFinish's info). Optional: the join check passes none.
export type Event = {
	trackId: string,
	mode: string,
	rank: number,
	finished: boolean,
	simulated: boolean?,
	beatBoss: boolean?,
	beatDragon: boolean?, -- storm race: crossed the line ahead of the storm dragon
}

local function hasPrefixToken(tokens: { [string]: boolean }, prefix: string): boolean
	for id, held in tokens do
		if held == true and string.sub(id, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function bossBeaten(p: Profile): boolean
	if p.finalBoss == true then
		return true
	end
	if p.boss then
		for _, b in p.boss do
			if b.first == true or b.rematch == true then
				return true
			end
		end
	end
	return false
end

-- Race tracks the account has raced: a saved best time, or a race token, coin token or boss win on it.
-- The title the owner gave the badge (docs/BADGES.md), for the earned toast; nil for an unknown key.
function BadgeRules.titleOf(key: any): string?
	for _, d in BadgeRules.DEFS do
		if d.key == key then
			return d.title
		end
	end
	return nil
end

function BadgeRules.racedTracks(p: Profile?, ev: Event?): { [string]: boolean }
	local raced: { [string]: boolean } = {}
	if p then
		for _, trackId in LeaderboardRules.RACE_TRACKS do
			local tokens = p.tokens or {}
			local boss = if p.boss then p.boss[trackId] else nil
			if
				(p.bestTimes and type(p.bestTimes[trackId]) == "number")
				or tokens["race:" .. trackId] == true
				or tokens["coin:" .. trackId] == true
				or (boss ~= nil and (boss.first == true or boss.rematch == true))
			then
				raced[trackId] = true
			end
		end
	end
	if ev and ev.finished and ev.simulated ~= true then
		raced[ev.trackId] = true
	end
	return raced
end

local function realFinish(ev: Event?): boolean
	return ev ~= nil and ev.finished == true and ev.simulated ~= true
end

-- Every badge key the account has earned by now, in DEFS order. profile and ev may each be nil.
function BadgeRules.earned(p: Profile?, ev: Event?): { string }
	local out: { string } = {}
	local profile: Profile = p or {}
	local tokens = profile.tokens or {}

	local firstRace = realFinish(ev) or next(BadgeRules.racedTracks(profile, nil)) ~= nil
	if firstRace then
		table.insert(out, "first_race")
	end

	local won = hasPrefixToken(tokens, "race:")
	if realFinish(ev) and (ev :: Event).rank == 1 and ((ev :: Event).mode == "race" or (ev :: Event).mode == "quickrace") then
		won = true
	end
	if won then
		table.insert(out, "first_win")
	end

	local boss = bossBeaten(profile)
	if realFinish(ev) and ((ev :: Event).mode == "boss" or (ev :: Event).mode == "rematch") and (ev :: Event).beatBoss == true then
		boss = true
	end
	if boss then
		table.insert(out, "first_boss")
	end

	local raced = BadgeRules.racedTracks(profile, ev)
	local all = true
	for _, trackId in LeaderboardRules.RACE_TRACKS do
		if not raced[trackId] then
			all = false
			break
		end
	end
	if all then
		table.insert(out, "all_tracks")
	end

	for _, trackId in LeaderboardRules.RACE_TRACKS do
		if LeaderboardRules.trackStars(profile, trackId) >= 3 then
			table.insert(out, "three_star")
			break
		end
	end

	-- Storm badges: counters from the saved record; the finish itself earns the first storm finish and the first dragon win.
	local storm = StormRules.read(profile)
	local stormFinish = realFinish(ev) and StormRules.isStormMode((ev :: Event).mode)
	if storm.races >= 1 or stormFinish then
		table.insert(out, "storm_racer")
	end
	local dragonWins = storm.dragonWins
	if stormFinish and (ev :: Event).beatDragon == true then
		dragonWins = math.max(dragonWins, 1)
	end
	if dragonWins >= 1 then
		table.insert(out, "dragon_slayer")
	end
	for _, key in { "dragon_hunter", "dragon_bane", "stormbreaker" } do
		if dragonWins >= StormConfig.BADGE_DRAGON_WINS[key] then
			table.insert(out, key)
		end
	end
	return out
end

-- What to do about the earned badges: each key with its id. A key with no id is "unset" (log once, skip); one already
-- handled this session is dropped. Returns { key, id } rows to award and the list of unset keys to log.
function BadgeRules.plan(earned: { string }, ids: { [string]: number? }, handled: { [string]: boolean }): ({ { key: string, id: number } }, { string })
	local award: { { key: string, id: number } } = {}
	local unset: { string } = {}
	for _, key in earned do
		if not handled[key] then
			local id = ids[key]
			if type(id) == "number" and id > 0 and id == id and id == math.floor(id) then
				table.insert(award, { key = key, id = id })
			else
				table.insert(unset, key)
			end
		end
	end
	return award, unset
end

return BadgeRules
