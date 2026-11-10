--!strict
-- Race scope (economy v3 phase 2b, docs/design/PER_GROUP_RACES.md "Per-instance engine"). The race engine (RaceManager,
-- AIRacers, ItemService, kit/ItemEffects, TrackRegistry's active track, SplineUtils' spline cache) was written for one
-- race per server. Per group, every RaceInstance needs its own copy of that state. Instead of threading an instance
-- through every call, each module keeps its per-race state in a table it asks this module for (RaceScope.state), and
-- the server runs one instance's work inside RaceScope.run(id, fn): every state lookup in fn, and in everything fn
-- calls, lands on that instance's tables, so two fields never see each other's records, bots or items.
--
-- The scope belongs to the running thread (coroutine), so a load that yields (map build, plane template, task.wait)
-- keeps its instance across the yield; a thread spawned inside a run starts in the hub scope (DEFAULT) and must enter
-- its own run if it touches race state.
--
-- RaceFlowRules.PER_GROUP false (today): current() is always DEFAULT, state() hands back the one table each module had
-- before, filter() returns the record map it was given (the same table) and run() just calls fn. The single-race path
-- therefore takes exactly the steps it took before this module existed. Pure: no Instances (players are only asked
-- for an attribute), specced in tools/tests/per_group_engine_spec.luau.
local RaceFlowRules = require(script.Parent:WaitForChild("RaceFlowRules"))

local RaceScope = {}

RaceScope.DEFAULT = 0 -- the hub (and the whole server on the single-race path)
RaceScope.PLAYER_ATTRIBUTE = "RaceInstanceId" -- same name as RaceAttr.PLAYER_ATTRIBUTE (the seated player's instance)

local threadScope: { [thread]: number } = setmetatable({}, { __mode = "k" }) :: any
local states: { [string]: { [number]: any } } = {}
-- Live instance scopes (id -> track id), in open order; DEFAULT is never listed.
local live: { [number]: string } = {}
local order: { number } = {}

local function enabled(): boolean
	return RaceFlowRules.PER_GROUP == true
end
RaceScope.enabled = enabled

-- The scope the calling thread runs in.
function RaceScope.current(): number
	if not enabled() then
		return RaceScope.DEFAULT
	end
	return threadScope[coroutine.running()] or RaceScope.DEFAULT
end

-- Runs fn(...) in instance `id`'s scope on this thread and returns its results; the previous scope comes back after,
-- also when fn errors (the error is re-raised). Off the per-group path it is a plain call.
function RaceScope.run(id: number, fn: (...any) -> ...any, ...: any): ...any
	if not enabled() then
		return fn(...)
	end
	local co = coroutine.running()
	local prev = threadScope[co]
	if id == RaceScope.DEFAULT then
		threadScope[co] = nil
	else
		threadScope[co] = id
	end
	local results = table.pack(pcall(fn, ...))
	threadScope[co] = prev
	if not results[1] then
		error(results[2], 0)
	end
	return table.unpack(results, 2, results.n)
end

-- The per-scope state table `name` (one per module), made by factory() the first time a scope asks for it.
function RaceScope.state<T>(name: string, factory: () -> T): T
	local byId = states[name]
	if not byId then
		byId = {}
		states[name] = byId
	end
	local id = RaceScope.current()
	local s = byId[id]
	if s == nil then
		s = factory()
		byId[id] = s
	end
	return s
end

-- Every scope's existing state table `name` (PlayerRemoving clean-up across fields).
function RaceScope.each(name: string, fn: (id: number, state: any) -> ())
	local byId = states[name]
	if not byId then
		return
	end
	for id, s in byId do
		fn(id, s)
	end
end

-- An instance opened / closed. close forgets every module's state for it (the next instance gets fresh tables).
function RaceScope.open(id: number, trackId: string)
	if live[id] == nil then
		table.insert(order, id)
	end
	live[id] = trackId
end

function RaceScope.setTrack(id: number, trackId: string)
	if live[id] ~= nil then
		live[id] = trackId
	end
end

function RaceScope.close(id: number)
	live[id] = nil
	local i = table.find(order, id)
	if i then
		table.remove(order, i)
	end
	for _, byId in states do
		byId[id] = nil
	end
end

-- Live instance ids in the order they opened (a copy: a step may close one).
function RaceScope.liveIds(): { number }
	return table.clone(order)
end

-- The track id the calling thread's instance races on; nil in the hub scope (the workspace ActiveTrackId applies).
function RaceScope.track(): string?
	local id = RaceScope.current()
	if id == RaceScope.DEFAULT then
		return nil
	end
	return live[id]
end

-- The instance a player is seated in (DEFAULT for the hub and on the single-race path).
function RaceScope.instanceOf(player: any): number
	if not enabled() or player == nil then
		return RaceScope.DEFAULT
	end
	local ok, id = pcall(function(): any
		return player:GetAttribute(RaceScope.PLAYER_ATTRIBUTE)
	end)
	return if ok and type(id) == "number" then id else RaceScope.DEFAULT
end

-- Whether a player belongs to the calling thread's scope.
function RaceScope.includes(player: any): boolean
	if not enabled() then
		return true
	end
	return RaceScope.instanceOf(player) == RaceScope.current()
end

-- FlightServer.records seen from this scope: the same table on the single-race path; per group, a new map with only
-- the players seated in this scope (the hub scope gets the players in no instance).
function RaceScope.filter<V>(records: { [any]: V }): { [any]: V }
	if not enabled() then
		return records
	end
	local id = RaceScope.current()
	local out: { [any]: V } = {}
	for player, rec in records do
		if RaceScope.instanceOf(player) == id then
			out[player] = rec
		end
	end
	return out
end

-- A player list (Players:GetPlayers()) seen from this scope; the same list on the single-race path.
function RaceScope.players(list: { any }): { any }
	if not enabled() then
		return list
	end
	local id = RaceScope.current()
	local out = {}
	for _, p in list do
		if RaceScope.instanceOf(p) == id then
			table.insert(out, p)
		end
	end
	return out
end

-- Spec helper: forget every scope (the per-group spec runs several servers' worth of instances in one Lune process).
function RaceScope.resetForSpec()
	table.clear(states)
	table.clear(live)
	table.clear(order)
	table.clear(threadScope)
end

return RaceScope
