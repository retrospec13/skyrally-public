--!strict
-- Survival scoring (LAUNCH_PROGRESSION section 2b, SNOW-BATTLE; TEST_LIST_LAUNCH L72). Also the lives half of the
-- ISLAND water battle ("3 lives, item combat as SNOW"), so that mode reuses this module as-is. Pure: the server mode
-- (server/battle/modes/Survival) feeds it hits and reads the outcome; tools/tests/battle_spec.luau specs every rule.
--
-- Rules (OURS numbers, section 2b):
-- * Every entrant starts with `lives` (3). A landed item hit removes one life; a shield block or a hit inside the
--   post-hit immunity window is not a landed hit (ItemEffects decides that before this module hears of it). A trap
--   the victim dropped itself still costs the life but credits nobody.
-- * An entrant at 0 lives is OUT for the rest of the battle: it cannot be hit, holds and fires nothing and hovers as a
--   spectator. A player who leaves is out at that moment (forfeit).
-- * The battle ends as soon as at most one entrant has lives left (that entrant wins). With endWhenNoPlayers it also
--   ends as soon as every human player is out while bots still fight (a solo player never waits out three minutes of
--   bots); the bots are then ranked by the cap rule.
-- * At the 3-minute cap: most lives wins.
-- * Tie rule (cap, no-players end): among equal lives the entrant whose LAST life loss came earliest wins, i.e. the
--   one that has been hit-free the longest (never hit beats any hit); then more hits landed on rivals; then a player
--   over a bot; then the lower spawn slot. Never random. Out entrants rank below every survivor, a later exit higher.

local SurvivalRules = {}

export type Seat = {
	id: string,
	isPlayer: boolean,
	slot: number,
}

export type Entry = {
	id: string,
	isPlayer: boolean,
	slot: number,
	lives: number,
	hitsTaken: number,
	hitsLanded: number,
	lastLossAt: number?,
	outAt: number?,
}

export type State = {
	lives: number,
	entries: { [string]: Entry },
	ids: { string }, -- seat order
}

export type Outcome = {
	over: boolean,
	winner: string?,
	reason: string, -- "last standing" | "no players left" | "time" | "running"
}

function SurvivalRules.new(seats: { Seat }, lives: number?): State
	local n = if lives and lives >= 1 then math.floor(lives) else 3
	local state: State = { lives = n, entries = {}, ids = {} }
	for _, s in seats do
		if not state.entries[s.id] then
			state.entries[s.id] = {
				id = s.id,
				isPlayer = s.isPlayer,
				slot = s.slot,
				lives = n,
				hitsTaken = 0,
				hitsLanded = 0,
				lastLossAt = nil,
				outAt = nil,
			}
			table.insert(state.ids, s.id)
		end
	end
	return state
end

function SurvivalRules.livesOf(state: State, id: string): number
	local e = state.entries[id]
	return if e then e.lives else 0
end

function SurvivalRules.isOut(state: State, id: string): boolean
	local e = state.entries[id]
	return e == nil or e.lives <= 0
end

-- One landed hit at time t. Returns (lifeLost, nowOut). Hits on an unknown or already-out entrant change nothing.
function SurvivalRules.hit(state: State, victimId: string, attackerId: string?, t: number): (boolean, boolean)
	local v = state.entries[victimId]
	if not v or v.lives <= 0 then
		return false, false
	end
	v.lives -= 1
	v.hitsTaken += 1
	v.lastLossAt = t
	if attackerId and attackerId ~= victimId then
		local a = state.entries[attackerId]
		if a then
			a.hitsLanded += 1
		end
	end
	if v.lives <= 0 then
		v.lives = 0
		v.outAt = t
		return true, true
	end
	return true, false
end

-- Forfeit (the player left): out now with no life loss credited to anyone. Returns true when it changed anything.
function SurvivalRules.eliminate(state: State, id: string, t: number): boolean
	local e = state.entries[id]
	if not e or e.lives <= 0 then
		return false
	end
	e.lives = 0
	e.outAt = t
	return true
end

function SurvivalRules.alive(state: State): { string }
	local out: { string } = {}
	for _, id in state.ids do
		if state.entries[id].lives > 0 then
			table.insert(out, id)
		end
	end
	return out
end

-- true when a ranks above b (see the tie rule in the header).
function SurvivalRules.better(state: State, a: string, b: string): boolean
	local ea, eb = state.entries[a], state.entries[b]
	if not ea or not eb then
		return ea ~= nil
	end
	local aliveA, aliveB = ea.lives > 0, eb.lives > 0
	if aliveA ~= aliveB then
		return aliveA
	end
	if aliveA then
		if ea.lives ~= eb.lives then
			return ea.lives > eb.lives
		end
		local la, lb = ea.lastLossAt or -math.huge, eb.lastLossAt or -math.huge
		if la ~= lb then
			return la < lb
		end
	else
		local oa, ob = ea.outAt or 0, eb.outAt or 0
		if oa ~= ob then
			return oa > ob
		end
	end
	if ea.hitsLanded ~= eb.hitsLanded then
		return ea.hitsLanded > eb.hitsLanded
	end
	if ea.isPlayer ~= eb.isPlayer then
		return ea.isPlayer
	end
	return ea.slot < eb.slot
end

-- Every entrant, best first.
function SurvivalRules.ranking(state: State): { string }
	local ids = table.clone(state.ids)
	table.sort(ids, function(a: string, b: string): boolean
		return SurvivalRules.better(state, a, b)
	end)
	return ids
end

-- Whether the battle is over now (before the cap). See the header for endWhenNoPlayers.
function SurvivalRules.checkEnd(state: State, endWhenNoPlayers: boolean?): Outcome
	local alive = SurvivalRules.alive(state)
	if #alive <= 1 and #state.ids > 1 then
		local winner = alive[1] or SurvivalRules.ranking(state)[1]
		return { over = true, winner = winner, reason = "last standing" }
	end
	if endWhenNoPlayers then
		local players, playersAlive = 0, 0
		for _, id in state.ids do
			local e = state.entries[id]
			if e.isPlayer then
				players += 1
				if e.lives > 0 then
					playersAlive += 1
				end
			end
		end
		if players > 0 and playersAlive == 0 then
			return { over = true, winner = SurvivalRules.ranking(state)[1], reason = "no players left" }
		end
	end
	return { over = false, winner = nil, reason = "running" }
end

-- The 3-minute cap: most lives wins, ties by the tie rule.
function SurvivalRules.resolveCap(state: State): Outcome
	return { over = true, winner = SurvivalRules.ranking(state)[1], reason = "time" }
end

-- HUD / results text for one entrant.
function SurvivalRules.scoreText(state: State, id: string): string
	local e = state.entries[id]
	if not e or e.lives <= 0 then
		return "OUT"
	end
	return string.format("%d %s", e.lives, if e.lives == 1 then "LIFE" else "LIVES")
end

return SurvivalRules
