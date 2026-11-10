--!strict
-- Copyable skeleton for a battle mode (NOT registered: BattleCore.init only loads modules under battle/modes). To add a
-- mode: copy this file to server/battle/modes/<Name>.luau, set `kind` to the TrackData.modes.battle.kind it runs
-- ("egg", "water", "hoard"), put its pure rules (scores, timers, carry/drop, tide steps, win resolution) in
-- src/shared/battle/<Name>Rules.luau with a Lune spec under tools/tests/, and fill the callbacks below. No shared file
-- needs an edit: BattleCore registers the module by kind, TrackDirector opens the battle on the board once the kind is
-- registered and the track's TrackData has a modes.battle block with that kind, and the client HUD renders whatever
-- the mode puts in ctx.setHud / ctx.setScore. modes/Survival.luau is the worked example.
--
-- What a mode gets (BattleCore.Ctx, see BattleCore's header for the full list):
--   ctx.battle / ctx.rules     TrackData.modes.battle as the plan wrote it (Vector3 anchors, nests, rings, tide steps)
--   ctx.arena                  BattleRules.Arena (center, radius, returnRadius, floor, ceiling, spawns)
--   ctx.entrants / ctx.byId    Entrant list (id "player:<userId>" | "bot:<n>", name, isPlayer, slot, out, spectator)
--   ctx.folder                 Folder for the mode's visuals (destroyed with the battle)
--   ctx.position(id) / ctx.forward(id) / ctx.alive() / ctx.nearestOpponent(id) / ctx.nearestPod(id) / ctx.holding(id)
--   ctx.elapsed() / ctx.timeLeft()            seconds since GO / to the cap
--   ctx.setScore(id, n, text)  board value (higher ranks first) and its text; ctx.setHud(id, text) objective line
--   ctx.toast(id | nil, text, "good" | "bad" | "info")
--   ctx.eliminate(id, why)     out for the rest of the battle (no items, not hittable, bots hover)
--   ctx.hit(victim, attacker?, source, stun?, pos?)   a hazard hit through the item system (shields block it; a landed
--                              hit comes back through onHit like any missile)
--   ctx.respawn(id, cf?)       back to its seat
--   ctx.finish(result)         end now; otherwise the core calls resolve() at the 3-minute cap
local BattleCore = require(script.Parent.BattleCore)

type Ctx = BattleCore.Ctx
type Entrant = BattleCore.Entrant
type Result = BattleCore.Result

type State = {
	score: { [string]: number },
}

local Mode = {}

Mode.kind = "template" -- TrackData.modes.battle.kind this mode runs
Mode.title = "TEMPLATE"
-- Optional: Mode.capSeconds = 180; Mode.podTypes = { "Red", "Green", "Yellow" }; Mode.maxWaterDepth = 2.2
-- Optional: function Mode.itemPods(ctx) return { { pos = ..., podType = "Red", respawn = 12 } } end

function Mode.start(ctx: Ctx): State
	local st: State = { score = {} }
	for _, e in ctx.entrants do
		if not e.spectator then
			st.score[e.id] = 0
			ctx.setScore(e.id, 0, "0")
			ctx.setHud(e.id, "OBJECTIVE 0/3")
		end
	end
	-- Build nests / rings / pickups under ctx.folder here.
	return st
end

-- Every Heartbeat after GO: move the objective, check who touched what (ctx.position), award, and when someone has
-- won: ctx.finish({ winner = id, ranking = { ... }, reason = "first to 3" }).
function Mode.step(_ctx: Ctx, _st: State, _dt: number) end

-- A landed hit (shield blocks and immune passes never arrive here). attacker is nil for a self-hit or a hazard.
function Mode.onHit(_ctx: Ctx, _st: State, _victim: Entrant, _attacker: Entrant?, _source: string, _pos: Vector3) end

-- A seated player left during the countdown or the fight (already marked out by the core): forfeit its standing.
-- Not called for the last seated player: the core then waits for the next player instead.
function Mode.onLeave(_ctx: Ctx, _st: State, _entrant: Entrant) end

-- Where a bot heads now: { pos = Vector3, attack = racer id to hunt (aims items), reason = "debug label" }.
function Mode.botGoal(ctx: Ctx, _st: State, bot: Entrant): any
	local pod = ctx.nearestPod(bot.id)
	return { pos = if pod then pod.pos else ctx.arena.center, reason = if pod then "pod" else "centre" }
end

-- The cap ("time") or a QA end ("qa"): rank everyone, pick the winner (nil for none).
function Mode.resolve(ctx: Ctx, st: State, reason: string): Result
	local ids: { string } = {}
	for _, e in ctx.entrants do
		if not e.spectator then
			table.insert(ids, e.id)
		end
	end
	table.sort(ids, function(a: string, b: string): boolean
		return (st.score[a] or 0) > (st.score[b] or 0)
	end)
	return { winner = ids[1], ranking = ids, reason = reason }
end

-- Anything outside ctx.folder (the folder is destroyed by the core).
function Mode.stop(_ctx: Ctx, _st: State) end

return Mode
