--!strict
-- SNOW-BATTLE survival (LAUNCH_PROGRESSION 2b; TEST_LIST_LAUNCH L72) on the SNOW-1 frozen-lake overlay (plane vs three
-- bots). Scoring is SurvivalRules (lives, out, last standing, cap and tie rules, all specced under Lune); this module
-- only wires it to the battle framework: landed item hits cost lives, an entrant at 0 is out (BattleCore stops it
-- acting and it hovers), the battle ends at the last entrant with lives (or when every player is out), and at the
-- 3-minute cap the most lives win. Weapon pods are the plan's pickups (red, green, yellow at level one, 12 s respawn).
-- Bots: no item -> the nearest ready pod; holding one (or no pod ready) -> hunt the nearest opponent and fire when
-- BattleBots' item decision says so.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local battleShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("battle")
local BattleRules = require(battleShared:WaitForChild("BattleRules"))
local SurvivalRules = require(battleShared:WaitForChild("SurvivalRules"))
local BattleCore = require(script.Parent.Parent.BattleCore)

type Ctx = BattleCore.Ctx
type Entrant = BattleCore.Entrant
type Result = BattleCore.Result

type State = {
	rules: SurvivalRules.State,
}

local Survival = {}

Survival.kind = "survival"
Survival.title = "SURVIVAL"
-- Section 2b: red, green, yellow at level one (the plan's pickups name their own colour; anchors cycle these).
Survival.podTypes = { "Red", "Green", "Yellow" }

local REASON_TEXT: { [string]: string } = {
	["last standing"] = "last one standing",
	["no players left"] = "every player is out - ranked by lives",
	time = "time up - most lives wins",
	qa = "ended early (QA) - ranked by lives",
}

local function refresh(ctx: Ctx, st: State)
	local alive = #SurvivalRules.alive(st.rules)
	for _, e in ctx.entrants do
		if not e.spectator then
			local lives = SurvivalRules.livesOf(st.rules, e.id)
			ctx.setScore(e.id, lives, SurvivalRules.scoreText(st.rules, e.id))
			if lives > 0 then
				local rivals = alive - 1
				ctx.setHud(e.id, string.format("LIVES %d  -  %d RIVAL%s LEFT", lives, rivals, if rivals == 1 then "" else "S"))
			else
				ctx.setHud(e.id, "OUT - spectating")
			end
		end
	end
end

local function toResult(st: State, outcome: SurvivalRules.Outcome, reason: string): Result
	local ranking = SurvivalRules.ranking(st.rules)
	local texts: { [string]: string } = {}
	for _, id in ranking do
		texts[id] = SurvivalRules.scoreText(st.rules, id)
	end
	return {
		winner = outcome.winner,
		ranking = ranking,
		reason = REASON_TEXT[reason] or reason,
		texts = texts,
	}
end

local function checkEnd(ctx: Ctx, st: State)
	local outcome = SurvivalRules.checkEnd(st.rules, true)
	if outcome.over then
		ctx.finish(toResult(st, outcome, outcome.reason))
	end
end

function Survival.start(ctx: Ctx): State
	local seats: { SurvivalRules.Seat } = {}
	for _, e in ctx.entrants do
		if not e.spectator then
			table.insert(seats, { id = e.id, isPlayer = e.isPlayer, slot = e.slot })
		end
	end
	local lives = tonumber(ctx.rules.lives) or tonumber(ctx.battle.lives) or BattleRules.DEFAULT_LIVES
	local st: State = { rules = SurvivalRules.new(seats, lives) }
	refresh(ctx, st)
	ctx.log("survival start entrants=%d lives=%d", #seats, st.rules.lives)
	return st
end

function Survival.onHit(ctx: Ctx, st: State, victim: Entrant, attacker: Entrant?, source: string, _pos: Vector3)
	local lost, out = SurvivalRules.hit(st.rules, victim.id, if attacker then attacker.id else nil, ctx.elapsed())
	if not lost then
		return
	end
	local lives = SurvivalRules.livesOf(st.rules, victim.id)
	ctx.log("survival hit victim=%s by=%s source=%s lives=%d", victim.name, if attacker then attacker.name else "self", source, lives)
	if out then
		ctx.eliminate(victim.id, "no lives left")
		ctx.toast(nil, string.format("%s is OUT", victim.name), "info")
		ctx.toast(victim.id, "OUT OF LIVES - spectating", "bad")
	else
		ctx.toast(victim.id, string.format("HIT! %d %s left", lives, if lives == 1 then "life" else "lives"), "bad")
	end
	if attacker and attacker.isPlayer then
		ctx.toast(attacker.id, string.format("HIT %s!", string.upper(victim.name)), "good")
	end
	refresh(ctx, st)
	checkEnd(ctx, st)
end

function Survival.onLeave(ctx: Ctx, st: State, entrant: Entrant)
	SurvivalRules.eliminate(st.rules, entrant.id, ctx.elapsed())
	refresh(ctx, st)
	checkEnd(ctx, st)
end

function Survival.botGoal(ctx: Ctx, _st: State, bot: Entrant): any
	local color = ctx.holding(bot.id)
	if not color then
		local pod = ctx.nearestPod(bot.id)
		if pod then
			return { pos = pod.pos, reason = "pod" }
		end
	end
	local target = ctx.nearestOpponent(bot.id)
	local tpos = if target then ctx.position(target.id) else nil
	if target and tpos then
		return { pos = tpos, attack = target.id, reason = "hunt" }
	end
	return { pos = ctx.arena.center, reason = "centre" }
end

function Survival.resolve(_ctx: Ctx, st: State, reason: string): Result
	return toResult(st, SurvivalRules.resolveCap(st.rules), reason)
end

return Survival
