--!strict
-- First-time explainers beyond racing (T1-15, PO-06). Pure: no Instances, no clock, specced in tools/tests/explainer_spec.luau.
-- client/LadderNotices owns the queue and the calm-hub gate; server/Funnels takes the answer on OnboardingRemote ("explained"),
-- SaveService.markExplained saves it. Five topics, each shown ONCE per account and skippable:
--   items    first item picked up          -> item_first_explain   (saved here)
--   keys     first hidden key found        -> key_first_explain    (saved here too; the trigger is also the 0 -> 1 key count)
--   battles  first battle opened           -> battle_first_explain (legacy flag BattleIntroSeen stays the source of truth; also saved here)
--   tokens   first Sky Token earned        -> token_first_explain  (tokens and the gates they open)
--   garage   first calm hub moment after the first race started (Onboarded) with the Garage on -> garage_first_explain
-- Answering a card (either button) marks that topic seen. "Skip tips" (the close button of the new cards) marks it and turns
-- every topic off for the account (ex_skip). Storage: profile.settings keys "ex_<id>" and "ex_skip" (booleans), replicated as
-- the player attribute "Explained" ("items,keys" - the seen ids, comma separated) and "ExplainSkip".
local ExplainerRules = {}

export type Topic = { id: string, row: string, legacy: boolean }

ExplainerRules.TOPICS = {
	{ id = "items", row = "item_first_explain", legacy = false },
	{ id = "keys", row = "key_first_explain", legacy = false },
	{ id = "battles", row = "battle_first_explain", legacy = true },
	{ id = "tokens", row = "token_first_explain", legacy = false },
	{ id = "garage", row = "garage_first_explain", legacy = false },
} :: { Topic }

ExplainerRules.ATTR = "Explained"
ExplainerRules.SKIP_ATTR = "ExplainSkip"
ExplainerRules.SKIP_FLAG = "ex_skip"
ExplainerRules.PREFIX = "ex_"

-- Copy limits so a card fits a 740x360 phone screen: at most 3 lines, 40 characters a line, a 16 character title.
ExplainerRules.MAX_LINES = 3
ExplainerRules.MAX_LINE = 40
ExplainerRules.MAX_TITLE = 16

local byId: { [string]: Topic } = {}
local byRow: { [string]: Topic } = {}
for _, t in ExplainerRules.TOPICS do
	byId[t.id] = t
	byRow[t.row] = t
end

function ExplainerRules.isId(id: any): boolean
	return type(id) == "string" and byId[id] ~= nil
end

function ExplainerRules.topicForRow(row: any): string?
	local t = if type(row) == "string" then byRow[row] else nil
	return if t then t.id else nil
end

function ExplainerRules.rowOf(id: string): string?
	local t = byId[id]
	return if t then t.row else nil
end

function ExplainerRules.flag(id: string): string
	return ExplainerRules.PREFIX .. id
end

-- The seen set and the skip switch, read from a profile.settings table (nil or a bad value reads as "not seen").
function ExplainerRules.read(settings: { [any]: any }?): ({ [string]: boolean }, boolean)
	local seen: { [string]: boolean } = {}
	local skip = false
	if type(settings) == "table" then
		for _, t in ExplainerRules.TOPICS do
			if settings[ExplainerRules.flag(t.id)] == true then
				seen[t.id] = true
			end
		end
		skip = settings[ExplainerRules.SKIP_FLAG] == true
	end
	return seen, skip
end

-- "items,keys" (topic order) <-> set.
function ExplainerRules.encode(seen: { [string]: boolean }): string
	local out: { string } = {}
	for _, t in ExplainerRules.TOPICS do
		if seen[t.id] then
			table.insert(out, t.id)
		end
	end
	return table.concat(out, ",")
end

function ExplainerRules.decode(text: any): { [string]: boolean }
	local seen: { [string]: boolean } = {}
	if type(text) == "string" then
		for id in string.gmatch(text, "[^,]+") do
			if byId[id] then
				seen[id] = true
			end
		end
	end
	return seen
end

-- The once-only rule: a topic is due when it is a known topic, has not been seen and the account has not skipped tips.
-- legacySeen: the battle topic's older flag (BattleIntroSeen); true counts as seen.
function ExplainerRules.due(id: any, seen: { [string]: boolean }, skipAll: boolean, legacySeen: boolean?): boolean
	if not ExplainerRules.isId(id) or skipAll then
		return false
	end
	if seen[id] or (id == "battles" and legacySeen == true) then
		return false
	end
	return true
end

-- Applies an answer to a settings table. Returns whether anything changed (an equal answer is not a change, so the server
-- skips a save for a repeat). skipAll also marks every topic seen. An unknown id changes nothing.
function ExplainerRules.apply(settings: { [any]: any }, id: any, skipAll: boolean?): boolean
	if not ExplainerRules.isId(id) then
		return false
	end
	local changed = false
	local function set(key: string)
		if settings[key] ~= true then
			settings[key] = true
			changed = true
		end
	end
	set(ExplainerRules.flag(id :: string))
	if skipAll == true then
		set(ExplainerRules.SKIP_FLAG)
		for _, t in ExplainerRules.TOPICS do
			set(ExplainerRules.flag(t.id))
		end
	end
	return changed
end

-- Trigger conditions as pure functions, so the wiring in the client stays a thin shell.
-- items: the held-item attribute went from empty to something.
function ExplainerRules.itemTrigger(before: any, after: any): boolean
	local had = type(before) == "string" and before ~= ""
	local has = type(after) == "string" and after ~= ""
	return has and not had
end

-- garage: the Garage is on and the account has started its first race (Onboarded saved).
function ExplainerRules.garageTrigger(garageOn: any, onboarded: any): boolean
	return garageOn == true and onboarded == true
end

-- tokens: SkyTokens rose (the first value is a baseline and never triggers).
function ExplainerRules.tokenTrigger(before: any, after: any): boolean
	return type(before) == "number" and type(after) == "number" and after > before
end

return ExplainerRules
