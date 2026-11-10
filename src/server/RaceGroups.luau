--!strict
-- Per-group race director (economy v3 phase 2b, Option A; docs/design/PER_GROUP_RACES.md "Per-instance engine").
-- With RaceFlowRules.PER_GROUP true the hub never switches: TrackDirector keeps stepping it (portals, finds, exchange
-- pads) and hands every race request here. Each request becomes (or joins) a RaceInstance: its map is built next to
-- the live hub, ONLY its players are seated on its grid, its bots, items, checkpoints and finish order live in its own
-- RaceScope, its race end (DNF deadline, return timer, FLY AGAIN / HUB votes) counts only its own humans, and its
-- return to the hub moves only its players back while every other group keeps racing.
--
-- Nobody is pulled into a race: a player enters an instance only by his own portal crossing or board pick, and a pick
-- of a track whose instance is still on its grid joins that grid. A track whose instance is already racing answers
-- "busy" (one map per track: two groups never share pods or checkpoints). No server-wide message is sent for any of
-- it; only the players concerned hear about their own race.
--
-- Every world-facing call goes through Deps (the boot wiring in TrackDirector.init passes the live ones), so
-- tools/tests/per_group_engine_spec.luau runs two concurrent instances, joins, leaves and returns under Lune.
-- Every mode a group picks runs in its own instance, its mode systems included (shared/ModeScopeRules: boss hazards,
-- coins, key, duck, cannons, vents and battles keep one state per scope; systems audit v32 T0-2). Storm Cup v1 (a
-- whole-server cup by design; per group a storm is storm race v2) and the final boss on the hub loop are refused
-- ("coming soon") and a Storm Cup start (no player) is skipped (see the design doc).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
local RaceInstanceRules = require(Shared:WaitForChild("RaceInstanceRules"))
local RaceScope = require(Shared:WaitForChild("RaceScope"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local GridOrder = require(Shared:WaitForChild("GridOrder"))
local GroupCurtainRules = require(Shared:WaitForChild("GroupCurtainRules"))

local RaceGroups = {}

RaceGroups.COUNTDOWN = 3.6 -- same grid hold as TrackDirector.COUNTDOWN (3, 2, 1 at one second each, GO at 0.6)
RaceGroups.BOSS_INTRO = 3.5
RaceGroups.RETURN_AFTER_FINISH = 22
-- A group whose map and grid are not up this long after its request goes back to the hub with a message (watchdog;
-- the client's curtain gives up a little later on its own, GroupCurtainRules.CLIENT_TIMEOUT).
RaceGroups.LOAD_TIMEOUT = GroupCurtainRules.SERVER_LOAD_TIMEOUT

-- What a RaceInstance object offers (server/RaceInstance; the spec passes a fake with the same shape).
export type Inst = {
	rules: RaceInstanceRules.RaceInst,
	root: Instance,
	players: { [Player]: boolean },
	setAttr: (self: any, name: string, value: any) -> (),
	getAttr: (self: any, name: string) -> any,
	transition: (self: any, to: RaceInstanceRules.State) -> boolean,
	join: (self: any, player: Player) -> boolean,
	leave: (self: any, player: Player) -> boolean,
	close: (self: any) -> (),
}

export type Hooks = {
	suspendRace: (boolean) -> (),
	onTrackChanged: () -> (),
	spawnBots: (enabled: boolean) -> (),
	despawnBots: () -> (),
	clearItems: () -> (),
	resetRace: (goTime: number?) -> (),
	allPlayersFinished: () -> boolean,
	startMode: (mode: string, td: any) -> (),
	-- The group's mode systems stop (in its scope) before the scope closes (systems audit v32 T0-2): its coins, boss
	-- hazards, key, duck, cannons, vents and battle go with it.
	stopMode: (() -> ())?,
	markDnf: ((Player) -> ())?,
	fieldDone: (() -> boolean)?,
	refreshField: ((reason: string, leaving: Player?) -> ())?,
	botSlots: (() -> { [number]: boolean })?,
	-- A leaver's held item and shield go from his instance's ledger (run in that scope before his seat is cleared).
	dropRacer: ((Player) -> ())?,
}

export type Deps = {
	hooks: Hooks,
	loadTrackData: (key: string) -> any,
	-- Builds (or restores) the map for td inside the instance's scope; false when it failed.
	buildMap: (key: string, td: any) -> boolean,
	destroyMap: (trackId: string) -> (),
	publishZone: (td: any) -> (),
	newInstance: (key: string, td: any, mode: string, field: number) -> Inst,
	-- Seats a player on the current scope's grid (FlightServer.spawnOrResetPlane through CarServer's wrapper).
	spawn: (player: Player, slot: number) -> (),
	-- Puts these players back on the plaza, in the hub scope, in front of the arch of `zone` (nil: the plaza).
	hubReturn: (players: { Player }, zone: string?) -> (),
	records: () -> { [Player]: any }, -- FlightServer.records
	serverNow: () -> number,
	clock: () -> number,
	send: (player: Player, event: string, data: any) -> (),
	delay: (seconds: number, fn: () -> ()) -> (),
	spawnTask: (fn: () -> ()) -> (),
	afk: ((Player) -> boolean)?,
	funnel: ((event: string, player: Player?, data: any) -> ())?,
	log: (line: string) -> (),
	hubTrackId: string,
}

type Group = {
	inst: Inst,
	key: string,
	td: any,
	mode: string,
	goTime: number?, -- server time of GO for the race on the grid
	returnAt: number?,
	dnfAt: number?,
	allFinishedAt: number?,
	votes: { [Player]: RaceFlowRules.Choice },
	lastVote: { [Player]: number },
	loaded: boolean,
}

local deps: Deps? = nil
local groups: { [number]: Group } = {}

local function D(): Deps
	return assert(deps, "RaceGroups.init has not run")
end

local function log(fmt: string, ...: any)
	D().log("[SkyRally][GROUPS] " .. string.format(fmt, ...))
end

local function idOf(g: Group): number
	return g.inst.rules.id
end

-- The scope interface ItemService / kit/ItemEffects take (their enableScopes): shared/RaceScope plus the instance's
-- race attributes.
function RaceGroups.scopeApi(): any
	return {
		current = RaceScope.current,
		liveIds = RaceScope.liveIds,
		instanceOf = RaceScope.instanceOf,
		run = RaceScope.run,
		state = RaceScope.state,
		filter = RaceScope.filter,
		attr = RaceAttr.here,
	}
end

-- The live instances, as RaceInstanceRules.admit reads them.
function RaceGroups.liveList(): { RaceInstanceRules.LiveInst }
	local out: { RaceInstanceRules.LiveInst } = {}
	for _, id in RaceScope.liveIds() do
		local g = groups[id]
		if g then
			local r = g.inst.rules
			local row: RaceInstanceRules.LiveInst = { trackId = r.trackId, state = r.state :: string, count = r.count, field = r.field }
			table.insert(out, row)
		end
	end
	return out
end

-- Economy v3 phase 3 (TrackDirector's portal queue): the race each track runs now, for its arch's label and the
-- queue's start rule: state (RaceInstanceRules State), goAt (server time of GO), endAt (ReturnToHubAt, server time,
-- once its results run).
function RaceGroups.trackRaces(): { [string]: { state: string, goAt: number?, endAt: number? } }
	local out: { [string]: { state: string, goAt: number?, endAt: number? } } = {}
	for _, id in RaceScope.liveIds() do
		local g = groups[id]
		if g then
			local r = g.inst.rules
			local endAt = g.inst:getAttr("ReturnToHubAt")
			out[r.trackId] = { state = r.state :: string, goAt = g.goTime, endAt = if type(endAt) == "number" then endAt else nil }
		end
	end
	return out
end

function RaceGroups.groupOf(player: Player): Group?
	local id = RaceScope.instanceOf(player)
	return if id ~= RaceScope.DEFAULT then groups[id] else nil
end

function RaceGroups.group(id: number): Group?
	return groups[id]
end

-- Humans present in this group that the flow waits for (AFK players who have not voted are left out).
local function humansOf(g: Group): { Player }
	local out: { Player } = {}
	local afk = D().afk
	for p in g.inst.players do
		if p.Parent and not (afk and afk(p) and g.votes[p] == nil) then
			table.insert(out, p)
		end
	end
	table.sort(out, function(a: Player, b: Player): boolean
		return a.UserId < b.UserId
	end)
	return out
end

local function publishVotes(g: Group)
	local humans = #humansOf(g)
	local group = RaceFlowRules.isGroup(humans)
	local present: { any } = {}
	for p in g.inst.players do
		table.insert(present, p)
	end
	local again, hub = RaceFlowRules.tally(g.votes, present)
	g.inst:setAttr("VoteHumans", if group then humans else nil)
	g.inst:setAttr("VotesAgain", if group then again else nil)
	g.inst:setAttr("VotesHub", if group then hub else nil)
end

-- The grid hold before GO for this mode.
local function holdFor(mode: string): number
	return RaceGroups.COUNTDOWN + 1.2 + (if mode == "boss" or mode == "rematch" then RaceGroups.BOSS_INTRO else 0)
end

-- A seat on a grid that is already forming: a rear-half seat nobody holds (GridOrder.lateJoinSlot, the same rule as a
-- late joiner on the single-race path), then the field trims the bot that sat there.
local function seatLate(g: Group, player: Player)
	local d = D()
	local used: { [number]: boolean } = {}
	for p in g.inst.players do
		local s = p:GetAttribute("GridSlot")
		if p ~= player and type(s) == "number" then
			used[s] = true
		end
	end
	local botsAt = d.hooks.botSlots
	local seed = g.inst.rules.seq * 7919 + player.UserId
	local slot, position = GridOrder.lateJoinSlot(used, if botsAt then botsAt() else {}, g.inst.rules.field, seed)
	player:SetAttribute("GridSlot", slot)
	player:SetAttribute("GridPosition", position)
	player:SetAttribute("GridField", g.inst.rules.field)
	player:SetAttribute("GridReason", "late")
	d.spawn(player, slot)
	local refresh = d.hooks.refreshField
	if refresh then
		refresh("join", nil)
	end
end

local function closeGroup(g: Group, why: string)
	local d = D()
	local id = idOf(g)
	if groups[id] == nil then
		return
	end
	groups[id] = nil
	pcall(RaceScope.run, id, function()
		local stopMode = d.hooks.stopMode
		if stopMode then
			stopMode()
		end
		d.hooks.despawnBots()
		d.hooks.clearItems()
	end)
	local trackId = g.inst.rules.trackId
	g.inst:close()
	RaceScope.close(id)
	-- The map goes when no other group races on it (never the hub's).
	local still = false
	for _, other in groups do
		if other.inst.rules.trackId == trackId then
			still = true
		end
	end
	if not still and trackId ~= d.hubTrackId then
		d.destroyMap(trackId)
	end
	log("close %d %s (%s)", id, trackId, why)
end

-- Return to the hub for ONE instance: its players give up their seats first (their clients show the hub again), then
-- after RETURN_UNHIDE they are set down on the plaza at this zone's arch; the instance closes. Other groups race on.
function RaceGroups.returnToHub(g: Group, why: string)
	local d = D()
	local list: { Player } = {}
	for p in g.inst.players do
		table.insert(list, p)
	end
	table.sort(list, function(a: Player, b: Player): boolean
		return a.UserId < b.UserId
	end)
	for _, p in list do
		g.inst:leave(p)
	end
	local zone = g.inst.rules.zone
	log("return %d %s to hub (%s) players=%d", idOf(g), g.inst.rules.trackId, why, #list)
	closeGroup(g, "returned: " .. why)
	d.delay(RaceInstanceRules.RETURN_UNHIDE, function()
		local present: { Player } = {}
		for _, p in list do
			if p.Parent and RaceScope.instanceOf(p) == RaceScope.DEFAULT then
				table.insert(present, p)
			end
		end
		if #present > 0 then
			d.hubReturn(present, zone)
		end
	end)
end

-- A load that failed or timed out: its players hear why (client/TrackFlow "GroupLoadFailed"), then go back to the hub
-- (their seats go first, which lifts their curtain).
local function failLoad(g: Group, why: string)
	local d = D()
	for p in g.inst.players do
		d.send(p, "GroupLoadFailed", { id = g.td.id, why = why })
	end
	RaceGroups.returnToHub(g, "load " .. why)
end

-- One group's map load and first grid, inside its scope. Yields (map build) are safe: the scope is the thread's.
local function load(g: Group)
	local d = D()
	local id = idOf(g)
	local h = d.hooks
	local ok, err = pcall(RaceScope.run, id, function()
		local root = g.inst.root
		-- The group's own curtain (client/TrackFlow reads these on the instance root, never workspace).
		root:SetAttribute("NextTrackId", g.td.id)
		root:SetAttribute("NextZone", g.td.zone)
		root:SetAttribute("NextMode", g.mode)
		root:SetAttribute("Loading", true)
		h.suspendRace(true)
		local t0 = d.clock()
		if not d.buildMap(g.key, g.td) then
			error("map build failed for " .. tostring(g.key))
		end
		if groups[id] ~= g then
			return -- everyone left while the map built: closeGroup ran; the clean-up below takes the map back
		end
		d.publishZone(g.td)
		g.inst:setAttr("RaceMode", g.mode)
		g.inst:setAttr("ActiveTrackId", g.td.id)
		g.inst:setAttr("ActiveZone", g.td.zone)
		g.inst:setAttr("CurrentTrackKey", g.key)
		g.inst:setAttr("TotalLaps", PlaneConfig.TOTAL_LAPS)
		g.inst:setAttr("ActiveVehicle", if type(g.td.vehicle) == "string" then g.td.vehicle else "plane")
		g.inst:setAttr("BotPace", g.td.botPace)
		h.onTrackChanged()
		h.spawnBots(true)
		local goTime = d.serverNow() + holdFor(g.mode)
		g.goTime = goTime
		g.inst:transition("grid")
		h.resetRace(goTime)
		h.startMode(g.mode, g.td)
		h.suspendRace(false)
		g.loaded = true
		root:SetAttribute("Loading", false)
		log("load %d %s mode=%s players=%d in %.1fs", id, tostring(g.td.id), g.mode, g.inst.rules.count, d.clock() - t0)
	end)
	if groups[id] ~= g then
		-- The group closed during a yield of its load (its last player left the server): closeGroup could not take
		-- what the load built after it ran (the map, the bots spawned in this scope, the state tables the steps re-made),
		-- so take them now. Nothing is left stepping or standing for an instance nobody races in.
		pcall(RaceScope.run, id, function()
			local stopMode = h.stopMode
			if stopMode then
				stopMode()
			end
			h.despawnBots()
			h.clearItems()
		end)
		RaceScope.close(id)
		local trackId = g.inst.rules.trackId
		local still = false
		for _, other in groups do
			if other.inst.rules.trackId == trackId then
				still = true
			end
		end
		if not still and trackId ~= d.hubTrackId then
			d.destroyMap(trackId)
		end
		log("load %d %s abandoned (empty)", id, tostring(trackId))
		return
	end
	if not ok then
		warn("[SkyRally][GROUPS] load " .. tostring(g.key) .. " failed: " .. tostring(err))
		failLoad(g, "failed")
	end
end

-- A race request from these players (a portal crossing, a board pick). Returns "open", "join", "busy" or "refused".
function RaceGroups.request(players: { Player }, key: string, mode: string, reason: string): string
	local d = D()
	local td = d.loadTrackData(key)
	-- Only players on the plaza ask: one already seated in a race is never moved by a request.
	local asking: { Player } = {}
	for _, p in players do
		if RaceScope.instanceOf(p) == RaceScope.DEFAULT then
			table.insert(asking, p)
		end
	end
	players = asking
	if not td or #players == 0 then
		return "refused"
	end
	-- The hub's own loop (the final boss) would rebuild the live hub under everyone: not per group yet, nor battles,
	-- Storm Cups or coin challenges (RaceInstanceRules.groupModeOk).
	if not RaceInstanceRules.groupModeOk(mode) or td.id == d.hubTrackId then
		for _, p in players do
			d.send(p, "PortalLocked", { key = key, id = td.id, why = "coming soon" })
		end
		return "refused"
	end
	-- One mode per track at a time: a storm field's track takes storm joins only (server/StormRace picks a free one),
	-- and a battle never joins a race grid on the same map, nor a race a battle (the arena and the race line share the
	-- map, its pods and its checkpoints; systems audit v32 T0-2). The asker waits, as for a racing track.
	for _, other in groups do
		if other.inst.rules.trackId == td.id and other.mode ~= mode then
			for _, p in players do
				d.send(p, "RaceBusy", { id = td.id })
			end
			log("request %s %s by %d player(s) (%s): busy (a %s race holds the track)", tostring(td.id), mode, #players, reason, other.mode)
			return "busy"
		end
	end
	local verdict = RaceInstanceRules.admit(RaceGroups.liveList(), td.id)
	if verdict == "busy" then
		for _, p in players do
			d.send(p, "RaceBusy", { id = td.id })
		end
		log("request %s %s by %d player(s) (%s): busy", tostring(td.id), mode, #players, reason)
		return "busy"
	end
	if verdict == "join" then
		for _, g in groups do
			if g.inst.rules.trackId == td.id then
				for _, p in players do
					RaceGroups.join(g, p)
				end
				return "join"
			end
		end
	end
	local inst = d.newInstance(key, td, mode, PlaneConfig.AI_FIELD_SIZE)
	local g: Group = {
		inst = inst,
		key = key,
		td = td,
		mode = mode,
		goTime = nil,
		returnAt = nil,
		dnfAt = nil,
		allFinishedAt = nil,
		votes = {},
		lastVote = {},
		loaded = false,
	}
	local id = idOf(g)
	groups[id] = g
	RaceScope.open(id, td.id)
	-- No race step for this instance until its map is built and its grid formed (load lifts it).
	RaceScope.run(id, d.hooks.suspendRace, true)
	for _, p in players do
		RaceGroups.join(g, p)
	end
	log("open %d %s %s by %d player(s) (%s)", id, tostring(td.id), mode, #players, reason)
	local funnel = d.funnel
	if funnel then
		for _, p in players do
			pcall(funnel, "pick", p, { track = td.id, mode = mode, via = reason })
		end
	end
	d.spawnTask(function()
		load(g)
	end)
	-- Watchdog: a build that never returns must not hold its players under the curtain.
	d.delay(RaceGroups.LOAD_TIMEOUT, function()
		if groups[id] == g and not g.loaded then
			warn(string.format("[SkyRally][GROUPS] load %d %s timed out after %d s", id, tostring(td.id), RaceGroups.LOAD_TIMEOUT))
			failLoad(g, "timeout")
		end
	end)
	return "open"
end

-- A player takes a seat: while the map loads his seat is waiting (the first reset seats everyone); on a forming grid he
-- is seated at once. A player already in another race is not moved.
function RaceGroups.join(g: Group, player: Player): boolean
	local cur = RaceScope.instanceOf(player)
	if cur ~= RaceScope.DEFAULT and cur ~= idOf(g) then
		return false
	end
	if not g.inst:join(player) then
		D().send(player, "RaceBusy", { id = g.inst.rules.trackId })
		return false
	end
	if g.loaded and g.inst.rules.state == "grid" and cur == RaceScope.DEFAULT then
		RaceScope.run(idOf(g), seatLate, g, player)
	end
	return true
end

-- A player left the server: his seat goes; the last one out closes the instance (bots, items, map).
function RaceGroups.onLeave(player: Player)
	local g = RaceGroups.groupOf(player)
	if not g then
		return
	end
	local d = D()
	local id = idOf(g)
	g.votes[player] = nil
	g.lastVote[player] = nil
	local drop = d.hooks.dropRacer
	if drop then
		pcall(RaceScope.run, id, drop, player)
	end
	g.inst:leave(player)
	if RaceInstanceRules.empty(g.inst.rules) then
		closeGroup(g, "empty")
		return
	end
	RaceScope.run(id, publishVotes, g)
	-- His seat in the field: refilled (open grid) or left empty until the next grid, after he is gone from Players.
	local refresh = d.hooks.refreshField
	if refresh then
		d.delay(0, function()
			if groups[id] then
				pcall(RaceScope.run, id, refresh, "leave", player)
			end
		end)
	end
end

-- FLY AGAIN on the same map: a fresh grid for the same group.
local function replay(g: Group): boolean
	local d = D()
	local r = g.inst.rules
	if r.state == "racing" then
		g.inst:transition("results")
	end
	if not g.inst:transition("grid") then
		return false
	end
	g.returnAt = nil
	g.allFinishedAt = nil
	g.dnfAt = nil
	table.clear(g.votes)
	RaceScope.run(idOf(g), function()
		g.inst:setAttr("ReturnToHubAt", nil)
		g.inst:setAttr("DnfAt", nil)
		publishVotes(g)
		local goTime = d.serverNow() + RaceGroups.COUNTDOWN + 0.6
		g.goTime = goTime
		d.hooks.resetRace(goTime)
		d.hooks.startMode(g.mode, g.td)
	end)
	log("replay %d %s", idOf(g), r.trackId)
	return true
end

local function resolveVotes(g: Group, expired: boolean): boolean
	local present: { any } = {}
	for p in g.inst.players do
		table.insert(present, p)
	end
	local again, hub = RaceFlowRules.tally(g.votes, present)
	local humans = #humansOf(g)
	local decision = RaceFlowRules.decide(again, hub, humans, expired)
	if not decision then
		return false
	end
	log("exit %d %s (again %d, hub %d of %d humans%s)", idOf(g), decision, again, hub, humans, if expired then ", timer" else "")
	table.clear(g.votes)
	if decision == "again" and replay(g) then
		return true
	end
	RaceGroups.returnToHub(g, if expired then "all finished" else "vote")
	return true
end

-- FLY AGAIN / HUB from a player in a group: solo at once, 2+ humans a vote from a player who is done (the same rules
-- as TrackDirector.requestExit, counted over this group only).
function RaceGroups.requestExit(player: Player, choice: RaceFlowRules.Choice): string
	local d = D()
	local g = RaceGroups.groupOf(player)
	if not g or not g.loaded then
		return "refused"
	end
	local now = d.clock()
	if now - (g.lastVote[player] or -math.huge) < RaceFlowRules.VOTE_COOLDOWN then
		return "throttled"
	end
	g.lastVote[player] = now
	local funnel = d.funnel
	if not RaceFlowRules.isGroup(#humansOf(g)) then
		if funnel then
			pcall(funnel, "next", player, { choice = choice })
		end
		if choice == "again" and not RaceFlowRules.canReplay(g.mode) then
			d.send(player, "VoteRefused", { why = "No replay in a storm race" })
			return "refused"
		elseif choice == "again" then
			replay(g)
		else
			RaceGroups.returnToHub(g, "player " .. player.Name)
		end
		return "done"
	end
	local rec = d.records()[player]
	local done = rec ~= nil and (rec.finished == true or rec.dnf == true)
	if not RaceFlowRules.canVote(choice, done, g.mode) then
		d.send(player, "VoteRefused", { why = if not done then "Finish first - the others are still racing" elseif g.mode == "stormrace" then "No replay in a storm race" else "No replay in a Storm Cup" })
		return "refused"
	end
	g.votes[player] = choice
	if funnel then
		pcall(funnel, "next", player, { choice = choice })
	end
	RaceScope.run(idOf(g), publishVotes, g)
	resolveVotes(g, false)
	return "counted"
end

-- FLY AGAIN for the group whose scope the calling thread runs in (BattleCore's "a player is back, restart the battle"
-- path per group, through the boot script's replay hook). false outside a group or when the replay is refused.
function RaceGroups.replayScope(): boolean
	local g = groups[RaceScope.current()]
	if not g or not g.loaded then
		return false
	end
	return replay(g)
end

-- One group's race end (5 Hz, in its scope): GO, then the DNF deadline from its first human finish, the return timer
-- once all its humans are done, the votes when the timer ends. Exactly TrackDirector's single-race step, per group.
local function stepGroup(g: Group)
	local d = D()
	if not g.loaded then
		return
	end
	local r = g.inst.rules
	if r.state == "grid" and g.goTime and d.serverNow() >= g.goTime then
		g.inst:transition("racing")
	end
	if r.state ~= "racing" then
		if g.returnAt and d.clock() >= g.returnAt then
			g.returnAt = nil
			g.allFinishedAt = nil
			g.inst:setAttr("ReturnToHubAt", nil)
			resolveVotes(g, true)
		end
		return
	end
	local now = d.clock()
	local recs = RaceScope.filter(d.records())
	local anyDone = false
	for p, rec in recs do
		if p.Parent and rec.finished == true then
			anyDone = true
			break
		end
	end
	local battle = g.mode == "battle"
	local step = RaceFlowRules.raceEndStep(d.hooks.allPlayersFinished(), anyDone, now, g.dnfAt, battle)
	if step == "wait" or step == "dnf" then
		local afk = d.afk
		local active = 0
		for p, rec in recs do
			if p.Parent and rec.finished ~= true and rec.dnf ~= true and not (afk and afk(p)) then
				active += 1
			end
		end
		local fieldDone = d.hooks.fieldDone
		if RaceFlowRules.abandoned(fieldDone ~= nil and fieldDone(), active, battle) then
			step = "timeout"
			log("race %d abandoned: the field finished, no human racing", idOf(g))
		end
	end
	if step == "dnf" then
		g.dnfAt = now + RaceFlowRules.DNF_SECONDS
		g.inst:setAttr("DnfAt", d.serverNow() + RaceFlowRules.DNF_SECONDS)
	elseif step == "timeout" then
		local markDnf = d.hooks.markDnf
		for p, rec in recs do
			if p.Parent and rec.finished ~= true and rec.dnf ~= true and markDnf then
				markDnf(p)
			end
		end
	end
	if step == "return" or step == "timeout" then
		g.dnfAt = nil
		g.inst:setAttr("DnfAt", nil)
		g.allFinishedAt = now
		g.returnAt = now + RaceGroups.RETURN_AFTER_FINISH
		g.inst:setAttr("ReturnToHubAt", d.serverNow() + RaceGroups.RETURN_AFTER_FINISH)
		g.inst:transition("results")
		publishVotes(g)
		resolveVotes(g, false)
	end
end

-- Every live group, each in its own scope (TrackDirector's 5 Hz Heartbeat calls this next to the hub step).
function RaceGroups.step()
	for _, id in RaceScope.liveIds() do
		local g = groups[id]
		if g then
			local ok, err = pcall(RaceScope.run, id, stepGroup, g)
			if not ok then
				warn(string.format("[SkyRally][GROUPS] step %d error %s", id, tostring(err)))
			end
		end
	end
end

-- The live groups racing this mode (storm race v2: its fields, the hub storm while any races), oldest first.
function RaceGroups.liveOf(mode: string): { { id: number, trackId: string, key: string, state: string, count: number, field: number } }
	local out = {}
	for _, id in RaceScope.liveIds() do
		local g = groups[id]
		if g and g.mode == mode then
			local r = g.inst.rules
			table.insert(out, { id = id, trackId = r.trackId, key = g.key, state = r.state :: string, count = r.count, field = r.field })
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- Whether the player is in no race (the hub): the requests TrackDirector takes from the plaza.
function RaceGroups.inHub(player: Player): boolean
	return RaceScope.instanceOf(player) == RaceScope.DEFAULT
end

function RaceGroups.init(d: Deps)
	deps = d
end

-- Spec helper: forget every group (several scenarios share one Lune process).
function RaceGroups.resetForSpec()
	table.clear(groups)
	deps = nil
end

return RaceGroups
