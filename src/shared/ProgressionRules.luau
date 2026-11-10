--!strict
-- Progression analytics payloads (T1-4 / PO progression events). Pure: no Instances, no clock, specced in
-- tools/tests/progression_spec.luau. server/Funnels turns an Event into AnalyticsService:LogProgressionStartEvent /
-- LogProgressionCompleteEvent / LogProgressionFailEvent (pcall-wrapped there). Cash sources and sinks are NOT here: they
-- already go through Economy's LogEconomyEvent (flow Source/Sink, txType Gameplay / TimedReward / IAP / Shop, item sku).
--
-- The event catalogue (every payload carries only ids and words from OnboardingRules.fields, never a name, user id or text):
--   race start     Start    path race_<mode>     level 1            levelName <trackId>     (the countdown reached GO)
--   race finish    Complete path race_<mode>     level <rank 1..99> levelName <trackId>     (crossed the line; custom field detail "token" when it earned a Sky Token)
--   race DNF       Fail     path race_<mode>     level 1            levelName <trackId>     (the race ended without a finish)
--   unlock         Complete path unlock_<kind>   level 1            levelName <id>          (kind portal / mode, from SaveService.award's newly opened set)
--   badge          Complete path badge           level 1            levelName <badge key>   (BadgeService really awarded it)
--   explainer      Complete path explainer       level 1 (2 = skipped all) levelName <id>   (a first-time explainer was answered)
local OnboardingRules = require(script.Parent:WaitForChild("OnboardingRules"))

local ProgressionRules = {}

export type Event = {
	kind: string, -- "start" | "complete" | "fail"
	path: string,
	level: number,
	levelName: string?,
	fields: OnboardingRules.Fields,
}

ProgressionRules.KINDS = { "start", "complete", "fail" } :: { string }
ProgressionRules.MAX_LEVEL = 99
-- Race modes that count as a race for the progression path (the hub and the battle have their own results).
ProgressionRules.RACE_MODES = { race = true, boss = true, coin = true, rematch = true, stormcup = true, storm = true } :: { [string]: boolean }

local function word(v: any): string?
	local f = OnboardingRules.fields(v, nil, nil)
	return f.track
end

local function make(kind: string, path: string, level: number, levelName: any, detail: any, mode: any): Event
	return {
		kind = kind,
		path = path,
		level = math.clamp(math.floor(level), 1, ProgressionRules.MAX_LEVEL),
		levelName = word(levelName),
		fields = OnboardingRules.fields(levelName, mode, detail),
	}
end

local function racePath(mode: any): string?
	local m = word(mode)
	if not m or m == "hub" or m == "battle" then
		return nil
	end
	return "race_" .. m
end

function ProgressionRules.raceStart(track: any, mode: any): Event?
	local path = racePath(mode)
	return if path then make("start", path, 1, track, nil, mode) else nil
end

-- rank: finishing place (nil or < 1 = unknown, stored as 1). finished false = DNF (a Fail event).
function ProgressionRules.raceFinish(track: any, mode: any, rank: any, finished: boolean, token: boolean?): Event?
	local path = racePath(mode)
	if not path then
		return nil
	end
	if not finished then
		return make("fail", path, 1, track, nil, mode)
	end
	local r = if type(rank) == "number" and rank == rank and rank >= 1 then rank else 1
	return make("complete", path, r, track, if token == true then "token" else nil, mode)
end

-- key is SaveService.award's newly unlocked id: "portal:ISLAND" or "mode:DINO-1:coin".
function ProgressionRules.unlock(key: any): Event?
	if type(key) ~= "string" then
		return nil
	end
	local kind, id = string.match(key, "^(%a+):(.+)$")
	if not kind or not id or (kind ~= "portal" and kind ~= "mode") then
		return nil
	end
	return make("complete", "unlock_" .. kind, 1, id, nil, nil)
end

function ProgressionRules.badge(key: any): Event?
	if type(key) ~= "string" or key == "" then
		return nil
	end
	return make("complete", "badge", 1, key, nil, nil)
end

function ProgressionRules.explainer(id: any, skippedAll: boolean?): Event?
	if type(id) ~= "string" or id == "" then
		return nil
	end
	return make("complete", "explainer", if skippedAll == true then 2 else 1, id, nil, nil)
end

-- The Roblox side, injectable: sink.start / complete / fail (player, path, level, levelName, fields). Returns whether the event
-- was sent (nil event = not a countable event). Never throws: a sink error is swallowed (analytics never touches a race).
export type Sink = {
	start: (player: any, path: string, level: number, levelName: string?, fields: OnboardingRules.Fields) -> (),
	complete: (player: any, path: string, level: number, levelName: string?, fields: OnboardingRules.Fields) -> (),
	fail: (player: any, path: string, level: number, levelName: string?, fields: OnboardingRules.Fields) -> (),
}

function ProgressionRules.emit(sink: Sink, player: any, ev: Event?): boolean
	if not ev or player == nil then
		return false
	end
	local fn = (sink :: any)[ev.kind]
	if type(fn) ~= "function" then
		return false
	end
	local ok = pcall(fn, player, ev.path, ev.level, ev.levelName, ev.fields)
	return ok
end

return ProgressionRules
