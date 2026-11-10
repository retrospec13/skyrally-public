--!strict
-- Economy v3 phase 8 (owner spec sections 5 and 5b): the copy and progress maths that EXPLAIN the hidden keys and the map-unlock ladder.
-- Pure: no services, no UI, so the arch signs, the Adventure board, the Garage "how to get" line and the toasts all read one source
-- and tools/tests/ladder_spec.luau runs it under Lune. Thresholds come from Progression (D15), never copied here.
--  * Ladder: DINO 0, SNOW 1, ISLAND 2, FOREST 4 Sky Tokens, SPACE after the final boss. Tokens come from race wins, coin-challenge
--    wins and hub finds (SOURCES_LINE).
--  * Keys: one hidden key per zone (4); a key opens that zone's battle mode, a battle win gives a fragment, four fragments make the
--    Battle Amulet.
-- Visual styling stays in NotifyKit's SKIN tables; this module only produces strings and numbers.
local Progression = require(script.Parent:WaitForChild("Progression"))

local LadderRules = {}

export type Row = {
	zone: string,
	need: number?, -- tokens to hold; nil = opens on the final boss
	have: number,
	open: boolean,
	remaining: number, -- tokens still missing (0 when open or boss-gated)
}

LadderRules.ORDER = { "DINO", "SNOW", "ISLAND", "FOREST", "SPACE" } :: { string }
LadderRules.SOURCES_LINE = "Win races and coin challenges, or find them around the hub."
LadderRules.SOURCES_SHORT = "Race wins, coin wins, hub finds"
LadderRules.BOSS_LINE = "Beat the final boss on the hub loop."

type NameOf = (string) -> string?

local function nameFor(zone: string, nameOf: NameOf?): string
	local n = if nameOf then nameOf(zone) else nil
	return string.upper(n or zone)
end

-- One ladder row. have = Sky Tokens held; finalBoss = the final boss is beaten (opens SPACE).
function LadderRules.row(zone: string, have: number, finalBoss: boolean?): Row
	local need = Progression.PORTAL_THRESHOLD[zone]
	local h = math.max(0, math.floor(have))
	if need == nil then
		local open = finalBoss == true
		return { zone = zone, need = nil, have = h, open = open, remaining = 0 }
	end
	return { zone = zone, need = need, have = h, open = h >= need, remaining = math.max(0, need - h) }
end

function LadderRules.ladder(have: number, finalBoss: boolean?): { Row }
	local out: { Row } = {}
	for _, zone in ipairs(LadderRules.ORDER) do
		table.insert(out, LadderRules.row(zone, have, finalBoss))
	end
	return out
end

-- The first count-gated zone still shut (the "next goal"); nil when every token gate is open.
function LadderRules.nextGoal(have: number): Row?
	for _, zone in ipairs(LadderRules.ORDER) do
		local r = LadderRules.row(zone, have, false)
		if r.need ~= nil and not r.open then
			return r
		end
	end
	return nil
end

-- "1/2 TOKENS" for a count-gated zone; the progress is capped at the need so a 5/2 never shows.
function LadderRules.progressText(r: Row): string
	if r.need == nil then
		return if r.open then "OPEN" else "FINAL BOSS"
	end
	return string.format("%d/%d TOKENS", math.min(r.have, r.need), r.need)
end

-- Gate text on a locked arch / board row; nil when the zone is open (the caller shows its own "drive in" line).
function LadderRules.archText(r: Row): string?
	if r.open then
		return nil
	end
	if r.need == nil then
		return "LOCKED - FINAL BOSS"
	end
	return "LOCKED - " .. LadderRules.progressText(r)
end

-- The one line under the gate text on how to get there.
function LadderRules.hintText(r: Row): string?
	if r.open then
		return nil
	end
	return if r.need == nil then LadderRules.BOSS_LINE else LadderRules.SOURCES_LINE
end

-- "1 more for ISLAND" (the award line); nil when no token gate is left.
function LadderRules.nextLine(have: number, nameOf: NameOf?): string?
	local g = LadderRules.nextGoal(have)
	if not g then
		return nil
	end
	return string.format("%d more for %s", g.remaining, nameFor(g.zone, nameOf))
end

-- Zones whose token gate opened going from `before` to `after` tokens, in ladder order. A drop (reset, other profile) opens nothing.
function LadderRules.crossed(before: number, after: number): { string }
	local out: { string } = {}
	if after <= before then
		return out
	end
	for _, zone in ipairs(LadderRules.ORDER) do
		local need = Progression.PORTAL_THRESHOLD[zone]
		if need ~= nil and need > 0 and before < need and after >= need then
			table.insert(out, zone)
		end
	end
	return out
end

-- Vars for NotifySpec "token_progress" ({n}/{need} for {zone}) after a gain; nil when no token gate is left (use "token_gain").
function LadderRules.tokenVars(have: number, nameOf: NameOf?): { [string]: any }?
	local g = LadderRules.nextGoal(have)
	if not g then
		return nil
	end
	local n = if nameOf then nameOf(g.zone) else nil
	return { n = g.have, need = g.need, zone = n or g.zone }
end

-- Baseline-aware step for the client watcher: prev = the last count seen (nil until the profile first reports; that first value is a
-- baseline and announces nothing). Returns gained, crossed zones.
function LadderRules.delta(prev: number?, now: number): (number, { string })
	if prev == nil or now <= prev then
		return 0, {}
	end
	return now - prev, LadderRules.crossed(prev, now)
end

---------------------------------------------------------------------------------------------------- keys and the amulet

LadderRules.KEYS_TOTAL = Progression.KEYS_TOTAL
LadderRules.FRAGMENTS_TOTAL = Progression.BATTLE_FRAGMENTS_TOTAL

-- "1/4" for the key modal / toast.
function LadderRules.keyVars(keys: number): { [string]: any }
	return { n = math.clamp(math.floor(keys), 0, LadderRules.KEYS_TOTAL), total = LadderRules.KEYS_TOTAL }
end

-- Whether finding this key is the player's first: only when the count went 0 -> 1 (a saved profile that already held keys never
-- gets the explainer, and nothing is stored for it).
-- Deferral of the first-key explainer modal: in a race, countdown, boss intro or battle only the short KEY n/4 toast shows;
-- the modal is queued and opens at the next calm hub moment (LoginRules.canShowNow: hub, no lobby / Storm lobby / map switch /
-- Garage / other modal). `calm` is that gate's answer. Returns "open" (show it now), "wait" (keep it queued) or "none".
function LadderRules.explainerStep(queued: boolean, calm: boolean): string
	if not queued then
		return "none"
	end
	return if calm then "open" else "wait"
end

function LadderRules.isFirstKey(keysAfter: number): boolean
	return keysAfter == 1
end

function LadderRules.fragmentVars(fragments: number): { [string]: any }
	return { n = math.clamp(math.floor(fragments), 0, LadderRules.FRAGMENTS_TOTAL), total = LadderRules.FRAGMENTS_TOTAL }
end

export type AmuletProgress = { keys: number, fragments: number }

-- Garage "how to get" line for the Battle Amulet tint, shown before it is owned. With progress it adds the counts.
function LadderRules.amuletHowTo(p: AmuletProgress?): string
	if not p then
		return "FIND HIDDEN KEYS, WIN BATTLES, COLLECT 4 FRAGMENTS"
	end
	local k = LadderRules.keyVars(p.keys)
	local f = LadderRules.fragmentVars(p.fragments)
	return string.format("HIDDEN KEYS %d/%d - FRAGMENTS %d/%d", k.n, k.total, f.n, f.total)
end

return LadderRules
