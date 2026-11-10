--!strict
-- Per-group mode systems (systems audit v32 T0-2, code part; docs/design/PER_GROUP_RACES.md "Mode systems per group").
-- The mode systems behind the boot script's startMode (BossRace hazards, CoinChallenge coins, KeyPickup, DuckHunt via
-- WorldSetPieces, the galleon cannons, VolcanoVents, BattleCore) each kept ONE `active` state and one Heartbeat: a
-- second group's load stopped the first group's coins and boss hazards. Each now keeps its state in a Slot: one value
-- per shared/RaceScope scope (the hub scope DEFAULT, one per RaceInstance), so a group's start / stop touches only its
-- own scope, and the system's single Heartbeat steps every scope that holds a value, inside that scope (records,
-- splines, race attributes, items and bots all resolve to that instance there).
--
-- RaceFlowRules.PER_GROUP false (today): RaceScope.current() is always DEFAULT, so a Slot is one box, get/set read and
-- write it, and each() calls fn once with the value when there is one, on the calling thread, with no pcall: exactly
-- the old `local a = active; if not a then return end` step. bind() returns fn itself; audience() returns nil
-- ("every client", FireAllClients as before).
--
-- Pure: no Instances (players are only asked for an attribute through RaceScope), specced in
-- tools/tests/per_group_modes_spec.luau.
local RaceScope = require(script.Parent:WaitForChild("RaceScope"))

local ModeScopeRules = {}

-- Whether mode systems run one state per scope now (RaceFlowRules.PER_GROUP, through RaceScope).
function ModeScopeRules.perGroup(): boolean
	return RaceScope.enabled()
end

-- Whether the calling thread runs in a group's scope (false in the hub scope and on the single-race path).
function ModeScopeRules.inGroup(): boolean
	return RaceScope.current() ~= RaceScope.DEFAULT
end

export type Slot<T> = {
	name: string,
	get: (self: Slot<T>) -> T?,
	set: (self: Slot<T>, value: T?) -> (),
	holders: (self: Slot<T>) -> { number },
	each: (self: Slot<T>, fn: (value: T, id: number) -> ()) -> (),
	any: (self: Slot<T>) -> boolean,
}

-- One value per scope under RaceScope.state("ModeSlot:<name>"). RaceScope.close(id) forgets the instance's box (the
-- owner stops the system in that scope first: RaceGroups' stopMode hook, so its Instances go with it).
function ModeScopeRules.slot<T>(name: string): Slot<T>
	local key = "ModeSlot:" .. name
	local function box(): { v: any }
		return RaceScope.state(key, function(): any
			return { v = nil }
		end)
	end
	local slot = { name = name } :: any
	function slot.get(_self: any): any
		return box().v
	end
	function slot.set(_self: any, value: any)
		box().v = value
	end
	-- Scope ids holding a value, the hub (DEFAULT, 0) first, then in id order (ids grow with each open).
	function slot.holders(_self: any): { number }
		local out: { number } = {}
		RaceScope.each(key, function(id: number, b: any)
			if b.v ~= nil then
				table.insert(out, id)
			end
		end)
		table.sort(out)
		return out
	end
	function slot.each(self: any, fn: (any, number) -> ())
		if not RaceScope.enabled() then
			local v = box().v
			if v ~= nil then
				fn(v, RaceScope.DEFAULT)
			end
			return
		end
		for _, id in self:holders() do
			-- One group's error never stops another group's step (each scope is its own pcall).
			local ok, err = pcall(RaceScope.run, id, function()
				local v = box().v
				if v ~= nil then
					fn(v, id)
				end
			end)
			if not ok then
				warn(string.format("[SkyRally][MODES] %s step error in scope %d: %s", name, id, tostring(err)))
			end
		end
	end
	function slot.any(self: any): boolean
		return #self:holders() > 0
	end
	return slot :: Slot<T>
end

-- fn bound to the calling thread's scope: a task.delay / task.spawn / signal callback made inside a group's step runs
-- in the hub scope otherwise (RaceScope: a new thread starts in DEFAULT). Off the per-group path: fn itself.
function ModeScopeRules.bind<A..., R...>(fn: (A...) -> R...): (A...) -> R...
	if not RaceScope.enabled() then
		return fn
	end
	local id = RaceScope.current()
	return function(...: A...): R...
		return RaceScope.run(id, fn :: any, ...)
	end
end

-- Runs fn(...) in the scope of the race `player` is seated in (the hub scope when none): a remote or a player
-- attribute signal arrives on a fresh thread, in the hub scope. Off the per-group path: a plain call.
function ModeScopeRules.runFor(player: any, fn: (...any) -> ...any, ...: any): ...any
	if not RaceScope.enabled() then
		return fn(...)
	end
	return RaceScope.run(RaceScope.instanceOf(player), fn, ...)
end

-- Who a mode system's "everyone" message goes to from the calling scope. nil: every client (FireAllClients, the single
-- path, unchanged). Per group: the players seated in this scope (the hub scope: the players in no race), so one group's
-- toast, cannon shot or duck line never reaches another group or the plaza.
function ModeScopeRules.audience(all: { any }): { any }?
	if not RaceScope.enabled() then
		return nil
	end
	return RaceScope.players(all)
end

------------------------------------------------------------------------------------------------------------------
-- Readiness: every mode a group can pick and every system behind it, with how it is per group. The spec checks that
-- every Progression mode and every server mode system is listed, that GROUP_MODES matches
-- RaceInstanceRules.groupModeOk, and that docs/design/PER_GROUP_RACES.md carries the same rows.

-- Modes a group may race in its own RaceInstance (RaceInstanceRules.groupModeOk reads this). "stormcup" is the v1 cup,
-- which takes the whole server by design; its per-group replacement is storm race v2 ("stormrace", server/StormRace).
-- "hub" is never a group's (the hub is the DEFAULT scope).
ModeScopeRules.GROUP_MODES = table.freeze({
	race = true,
	quickrace = true,
	timetrial = true,
	coin = true,
	boss = true,
	rematch = true,
	battle = true,
	stormrace = true,
}) :: { [string]: boolean }

ModeScopeRules.GROUP_REFUSED = table.freeze({
	stormcup = "Storm Cup v1 takes the whole server; per group a storm is storm race v2 (stormrace)",
	hub = "the hub is the DEFAULT scope, never a group",
}) :: { [string]: string }

function ModeScopeRules.groupMode(mode: string): boolean
	return ModeScopeRules.GROUP_MODES[mode] == true
end

-- status: "scoped" (state per RaceScope scope, stepped in its scope), "routed" (one module, every call routed to the
-- caller's instance), "hub" (the hub scope only, by design), "server" (one per server by design, never per group).
export type System = { id: string, file: string, status: string, how: string }

ModeScopeRules.SYSTEMS = {
	{ id = "race-state", file = "src/server/RaceManager.luau", status = "scoped", how = "RaceState per scope (phase 2b)" },
	{ id = "bots", file = "src/server/AIRacers.luau", status = "scoped", how = "FieldState per scope; bots = field minus that field's humans" },
	{ id = "items", file = "src/server/ItemService.luau", status = "scoped", how = "one ledger and one effects engine per scope; the battle arena hooks per scope" },
	{ id = "boss-hazards", file = "src/server/BossRace.luau", status = "scoped", how = "Slot BossRace; hazards in the shared BossHazards folder, owned per scope" },
	{ id = "boss-intro", file = "src/server/RaceGroups.luau", status = "scoped", how = "holdFor(mode) adds BOSS_INTRO per group; client BossIntro reads RaceAttr.mine" },
	{ id = "coins", file = "src/server/CoinChallenge.luau", status = "scoped", how = "Slot CoinChallenge; CoinsTotal shimmed onto the instance root" },
	{ id = "keys", file = "src/server/KeyPickup.luau", status = "scoped", how = "Slot KeyPickup" },
	{ id = "ducks", file = "src/server/DuckHunt.luau", status = "scoped", how = "Slot DuckHunt; the find line goes to the scope's players" },
	{ id = "cannons", file = "src/server/WorldSetPieces.luau", status = "scoped", how = "Slot WorldSetPieces; CannonFire goes to the scope's players" },
	{ id = "retired-bosses", file = "src/server/WorldSetPieces.luau", status = "hub", how = "templates while the hub scope is loaded; a group's start never changes inHub" },
	{ id = "vents", file = "src/server/VolcanoVents.luau", status = "scoped", how = "vents and cooldowns per scope; a crossing is checked in the sender's scope" },
	{ id = "battles", file = "src/server/battle/BattleCore.luau", status = "scoped", how = "Slot BattleCore, BattleBots.bots per scope, Battle* attributes shimmed, toasts to the scope's players, respawn guard dispatched by the player's scope" },
	{ id = "time-trials", file = "src/server/AIRacers.luau", status = "scoped", how = "no bots for the scope's RaceMode timetrial (RaceAttr.here)" },
	{ id = "storm-race-v2", file = "src/server/StormRace.luau", status = "routed", how = "RaceGroups.request(mode stormrace) on a free track; refused next to a normal race on that track" },
	{ id = "storm-cup-v1", file = "src/server/StormCup.luau", status = "server", how = "whole server by design; per group refused (RaceInstanceRules.groupModeOk) and the cup start skipped" },
	{ id = "hud-attributes", file = "src/shared/RaceAttr.luau", status = "routed", how = "RaceInstanceRules.SHIMMED on the instance root; server_race_reads_spec pins the direct workspace reads left" },
	{ id = "results-rewards", file = "src/server/RaceManager.luau", status = "scoped", how = "finish order per scope; awardFinish reads RaceAttr.here mode; photo finish reads the scope's mode" },
	{ id = "portal-queue", file = "src/shared/PortalQueueRules.luau", status = "routed", how = "one lobby per arch; every message to the joined player only" },
	{ id = "purchase-prompts", file = "src/server/Economy.luau", status = "routed", how = "prompt gate reads the player's own race (T1-7)" },
	{ id = "track-load", file = "src/server/TrackDirector.luau", status = "routed", how = "per group every request goes to RaceGroups (buildGroupMap, no curtain, no Terrain clear); the whole-server load stays the single path" },
} :: { System }

return ModeScopeRules
