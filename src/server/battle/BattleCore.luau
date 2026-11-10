--!strict
-- Battle framework (LAUNCH_PROGRESSION sections 2b and 3; TEST_LIST_LAUNCH L71-L75). A battle runs when TrackDirector
-- loads a key track with mode "battle": the boot script's startMode calls BattleCore.start(td) after the race reset
-- (players already sit on the arena's spawn pads through FlightServer.startOverride, the 3-2-1-GO hold applies, race
-- bots are absent because AIRacers.botsNeeded returns 0 and RaceManager runs no laps or finish line in battle).
--
-- What the core owns, for every mode:
-- * Arena (BattleRules.arena from TrackData.modes.battle): soft boundary. Clients pull their vehicle back toward the
--   centre from BattlePullStart (at least one turn radius inside the return line, trap audit G6) and a plane noses down
--   under BattleCeiling (workspace BattleCenter/BattleRadius/BattleReturnRadius/BattlePullStart/BattleCeiling); a
--   player past the play radius gets an "arena edge" toast, one near the ceiling a "too high" toast; past the boundary
--   band it is put back on the mode's returnFrame, else on its own seat (never a rival's pad: G6), through the server
--   CheckpointRespawn. A boundary return is not a crash: BoundaryReturnClock marks it so a mode keeps a carried prize.
-- * Seats and respawn frames (the stale-respawn fix): at the start every seated player's record and client get its
--   seat as the respawn frame (a car left elsewhere is put on it), and while a battle runs FlightServer.respawnGuard
--   replaces any respawn frame outside this arena (a frame from the previous map: the car fell out of the world at
--   the hub's coordinates in Studio) with the player's seat. Nobody out of the battle (BattleOut) is respawned.
-- * Field: the players (seated on their pads) plus BattleRules.botCount arena bots (server/battle/BattleBots) on the
--   free pads. A player who joins after the start spectates; a player who leaves is out (mode.onLeave, from the
--   countdown on), never scored, and watches the rest as a spectator if it rejoins. When no seated player is left the
--   battle waits and the replay seats whoever is present.
-- * Items: race item pods are removed and battle pods built from the plan's pickups / pickup anchors (respawn timers,
--   same ItemService ledger), level-one only; ItemService.setArena routes effects to arena bots and stops out
--   entrants from acting; ItemEffects.setArena makes shots fly free at the nearest opponent (a bot's at the one its
--   Goal.attack hunts) and reports landed hits.
-- * Clock: BattleEndsAt = GO + cap (180 s); at the cap mode.resolve decides. workspace.TriggerBattleEnd (QA) resolves
--   at once.
-- * End: results to each player (TrackFlowRemote "BattleResults": winner, ranking, award), every player record marked
--   finished (items stop; TrackDirector's existing return-to-hub timer starts; AGAIN replays through FLY AGAIN), and a
--   battle fragment for a winning player (SaveService.award "battle", idempotent: a replay win is a logged no-op).
-- * HUD (no modal during play): workspace BattleKind/BattleTitle/BattleState/BattleEndsAt/BattleBoard (JSON rows) and
--   the per-player objective line (player attribute BattleHud), rendered by the client's TrackFlow.
--
-- MODE API. A mode is a ModuleScript under server/battle/modes returning a Mode table; init() registers every one by
-- its `kind` (TrackData.modes.battle.kind: "survival", "egg", "water", "hoard"), so a new mode needs no edit here or in
-- any shared file. See ModeTemplate.luau (a copyable skeleton) and modes/Survival.luau (the first real mode).
--   kind: string                         TrackData.modes.battle.kind it runs
--   title: string                        HUD and results title ("SURVIVAL")
--   start(ctx) -> state                  build visuals under ctx.folder, seed scores/HUD; return the mode's state
--   step(ctx, state, dt)?                every Heartbeat after GO while running
--   onHit(ctx, state, victim, attacker?, source, pos)?   an item (or ctx.hit hazard) hit LANDED on victim
--   onLeave(ctx, state, entrant)?        a seated player left during the countdown or the fight (already marked out)
--   botGoal(ctx, state, bot) -> Goal?    where an arena bot heads now ({pos, attack = racer id?, reason?}); nil = centre
--   resolve(ctx, state, reason) -> Result   decide the result at the cap ("time") or a QA end ("qa")
--   stop(ctx, state)?                    clean up anything outside ctx.folder (the folder itself is destroyed)
--   capSeconds?, podTypes?, itemPods(ctx)?, maxWaterDepth?   optional overrides (cap, pod colours, pod list, car bots)
--   waterLevel(ctx, state)? -> number?   the mode's own water surface (a tide); car bots keep out of it like the sea
--   botItemDelay?                        seconds an arena bot holds a missile or trap before it may use it
--   returnFrame(ctx, state, entrant, pos)? -> CFrame?   where a player past the boundary band is put back (nil: seat)
--   frameSafe(ctx, state, pos)? -> boolean  whether a respawn frame is still safe; a respawn the player's client asked
--                                        for onto an unsafe one goes through returnFrame instead (the flooded pad)
--   targetable(ctx, state, shooter, victim)? -> boolean  whether shooter's missile or magnet may lock victim now
--   locked(ctx, state, shooter, victim)?  the lock the item targeting took (a mode's per-shooter cooldown)
-- A mode ends the battle early with ctx.finish(result). Result = {winner = entrant id?, ranking = {ids best first},
-- reason = short text, texts = {[id] = results text}?}.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BattleRules = require(Shared:WaitForChild("battle"):WaitForChild("BattleRules"))
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local Progression = require(Shared:WaitForChild("Progression"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local RacerViewRules = require(Shared:WaitForChild("RacerViewRules")) -- the fixed bot step the clients' view counts on
-- Per group (systems audit v32 T0-2, shared/ModeScopeRules): one battle per RaceScope scope. Its state, bots
-- (BattleBots.bots), item arena hooks, waiting list and bot clock are that scope's; the one Heartbeat steps every
-- scope's battle inside its scope (its records, its item engine); the Battle* attributes go on the race's own root
-- (RaceAttr.set); a toast "to everyone" reaches that race's players only; the respawn guard is the player's own
-- battle's. RaceFlowRules.PER_GROUP false: one scope, workspace attributes, FireAllClients, exactly as before.
local ModeScopeRules = require(Shared:WaitForChild("ModeScopeRules"))
local RaceScope = require(Shared:WaitForChild("RaceScope"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local BattleBots = require(script.Parent.BattleBots)
-- Trap I2-05: battle-only barriers from modes.battle.barriers (ISLAND-2 cavern mouth), built into the overlay folder.
local BattleBarriers = require(script.Parent.BattleBarriers)

local server = (script.Parent :: Instance).Parent :: Instance
local FlightServer = require(server:WaitForChild("FlightServer")) :: any
local ItemService = require(server:WaitForChild("ItemService")) :: any
local CarServer = require(server:WaitForChild("CarServer")) :: any
local Gameplay = require(server:WaitForChild("kit"):WaitForChild("Gameplay")) :: any
local ItemEffectsModule = require(server:WaitForChild("kit"):WaitForChild("ItemEffects")) :: any

local BattleCore = {}

export type Phase = "waiting" | "countdown" | "running" | "over"

export type Entrant = {
	id: string, -- ItemService racer id: "player:<userId>" | "bot:<n>"
	name: string,
	isPlayer: boolean,
	player: Player?,
	bot: BattleBots.Bot?,
	slot: number, -- spawn seat; modes index nests / home rings with it
	out: boolean, -- eliminated or left: not hittable or targetable, holds and fires nothing
	spectator: boolean, -- joined after the start: watches, never scored
	left: boolean,
	score: number, -- the mode's standing (ctx.setScore); orders the HUD board, higher first
	scoreText: string,
	hud: string,
}

export type Result = {
	winner: string?,
	ranking: { string },
	reason: string,
	texts: { [string]: string }?,
}

export type Ctx = {
	td: any, -- the whole TrackData
	battle: any, -- TrackData.modes.battle (plan data as written: Vector3 anchors, rules, nests, rings, tide steps)
	rules: any, -- battle.rules or {}
	arena: BattleRules.Arena,
	folder: Folder, -- per-battle visuals (under the map root); destroyed on stop
	zone: string,
	trackId: string,
	vehicle: string, -- "plane" | "car"
	entrants: { Entrant },
	byId: { [string]: Entrant },
	now: () -> number, -- os.clock
	elapsed: () -> number, -- seconds since GO (negative during the countdown)
	timeLeft: () -> number,
	position: (id: string) -> Vector3?,
	forward: (id: string) -> Vector3?,
	alive: () -> { Entrant }, -- in the battle: not out, not spectating
	nearestOpponent: (id: string, maxRange: number?) -> (Entrant?, number),
	pods: () -> { BattleBots.Pod },
	nearestPod: (id: string) -> BattleBots.Pod?, -- nearest ready (not cooling down) pod
	holding: (id: string) -> (string?, number), -- held item colour and level
	setHud: (id: string, text: string) -> (), -- objective line for that entrant (players see it)
	setScore: (id: string, score: number, text: string) -> (),
	toast: (id: string?, text: string, tone: string?) -> (), -- nil id = everyone; tone "good" | "bad" | "info"
	eliminate: (id: string, reason: string) -> (),
	hit: (victimId: string, attackerId: string?, source: string, stunSeconds: number?, pos: Vector3?) -> string,
	respawn: (id: string, cf: CFrame?) -> (), -- back to its seat (or cf)
	finish: (result: Result) -> (),
	log: (fmt: string, ...any) -> (),
}

export type Mode = {
	kind: string,
	title: string,
	start: (ctx: Ctx) -> any,
	step: ((ctx: Ctx, state: any, dt: number) -> ())?,
	onHit: ((ctx: Ctx, state: any, victim: Entrant, attacker: Entrant?, source: string, pos: Vector3) -> ())?,
	onLeave: ((ctx: Ctx, state: any, entrant: Entrant) -> ())?,
	capacity: ((battle: any, arena: BattleRules.Arena) -> number)?, -- seats for humans (egg: one per nest); more spectate
	-- Seats the bots fill up to (BattleRules.botCount): defaults to `capacity`, else the race field (8). Hoard: one per
	-- home ring, so no two bots share a ring; humans past it still play (they share a ring in turn).
	fieldSize: ((battle: any, arena: BattleRules.Arena) -> number)?,
	botGoal: ((ctx: Ctx, state: any, bot: Entrant) -> BattleBots.Goal?)?,
	resolve: (ctx: Ctx, state: any, reason: string) -> Result,
	stop: ((ctx: Ctx, state: any) -> ())?,
	capSeconds: number?,
	podTypes: { string }?,
	itemPods: ((ctx: Ctx) -> { BattleRules.PodSpec })?,
	maxWaterDepth: number?,
	waterLevel: ((ctx: Ctx, state: any) -> number?)?,
	botItemDelay: number?,
	returnFrame: ((ctx: Ctx, state: any, entrant: Entrant, pos: Vector3) -> CFrame?)?,
	frameSafe: ((ctx: Ctx, state: any, pos: Vector3) -> boolean)?,
	targetable: ((ctx: Ctx, state: any, shooter: Entrant, victim: Entrant) -> boolean)?,
	locked: ((ctx: Ctx, state: any, shooter: Entrant, victim: Entrant) -> ())?,
}

export type Deps = {
	itemEffects: any, -- the running ItemEffects engine (setArena, hit)
	trackData: () -> any, -- TrackDirector.currentTrackData
	replay: () -> (), -- restart the current battle with a fresh countdown (the FLY AGAIN path)
}

type Active = {
	mode: Mode,
	ctx: Ctx,
	state: any,
	world: BattleBots.World?,
	arena: BattleRules.Arena,
	folder: Folder,
	pods: { BattleBots.Pod },
	entrants: { Entrant },
	byId: { [string]: Entrant },
	goTime: number,
	endsAt: number,
	phase: Phase,
	boardDirty: boolean,
	boardTimer: number,
	boundaryTimer: number,
	warnAt: { [Player]: number },
	started: number,
	replayAt: number, -- os.clock of the last restart request from "waiting" (one per 2 s while a switch is busy)
	qaTimer: number,
}

local modes: { [string]: Mode } = {}
-- UserIds that watched the last battle for want of a seat: they sit first in the next one (L71, L75). One list per
-- scope (a group's next battle seats its own watchers).
local function waiting(): { ids: { [number]: boolean } }
	return RaceScope.state("BattleWaiting", function(): any
		return { ids = {} }
	end)
end
local deps: Deps? = nil
local slot = ModeScopeRules.slot("BattleCore") :: ModeScopeRules.Slot<Active>
local conn: RBXScriptConnection? = nil

BattleCore.POD_PREFIX = "BattlePod_"
BattleCore.EDGE_TOAST_EVERY = 3

local function log(fmt: string, ...: any)
	print("[SkyRally][BATTLE] " .. string.format(fmt, ...))
end

-- Runs one mode callback: a bug in a mode is logged and never stops the battle loop or the item effects.
local function guard(what: string, fn: () -> ...any): boolean
	local ok, err = pcall(fn)
	if not ok then
		warn(string.format("[SkyRally][BATTLE] mode %s error: %s", what, tostring(err)))
	end
	return ok
end

------------------------------------------------------------------------------------------------------------------------
-- Registry
------------------------------------------------------------------------------------------------------------------------

function BattleCore.register(mode: Mode)
	if type(mode) ~= "table" or type(mode.kind) ~= "string" or type(mode.start) ~= "function" or type(mode.resolve) ~= "function" then
		warn("[SkyRally][BATTLE] mode rejected: needs kind, start and resolve")
		return
	end
	modes[mode.kind] = mode
	log("mode registered kind=%s title=%s", mode.kind, tostring(mode.title))
end

-- Battle kinds with a registered mode (TrackDirector.battleKinds: a kind without one stays "coming soon").
function BattleCore.kinds(): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for kind in modes do
		out[kind] = true
	end
	return out
end

function BattleCore.isRunning(): boolean
	return slot:get() ~= nil
end

function BattleCore.phase(): Phase?
	local a = slot:get()
	return if a then a.phase else nil
end

------------------------------------------------------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------------------------------------------------------

local function trackFlowRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	local r = remotes and remotes:FindFirstChild("TrackFlowRemote")
	return if r and r:IsA("RemoteEvent") then r else nil
end

-- This scope's records (the same table on the single path; per group only the players seated in this race).
local function records(): { [Player]: any }
	return RaceScope.filter(FlightServer.records :: any)
end

-- The running scope's item effects engine (ItemEffects.active per scope; the started one on the single path, which is
-- deps.itemEffects).
local function itemEffects(): any
	if ModeScopeRules.perGroup() then
		local scoped = ItemEffectsModule.active
		if scoped then
			return scoped
		end
	end
	return if deps then deps.itemEffects else nil
end

local function playerId(player: Player): string
	return ItemService.playerRacerId(player.UserId)
end

local function battleOf(td: any): any
	return if type(td) == "table" and type(td.modes) == "table" and type(td.modes.battle) == "table" then td.modes.battle else nil
end

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function positionOf(a: Active, id: string): Vector3?
	local e = a.byId[id]
	if not e then
		return nil
	end
	local bot = e.bot
	if bot then
		return if bot.hull.Parent then bot.pos else nil
	end
	local player = e.player
	local rec = if player then records()[player] else nil
	local hull = if rec then rec.hull else nil
	return if hull and hull.Parent then hull.Position else nil
end

local function forwardOf(a: Active, id: string): Vector3?
	local e = a.byId[id]
	if not e then
		return nil
	end
	local bot = e.bot
	if bot then
		return bot.forward
	end
	local player = e.player
	local rec = if player then records()[player] else nil
	local hull = if rec then rec.hull else nil
	return if hull and hull.Parent then hull.CFrame.LookVector else nil
end

local function inPlay(e: Entrant): boolean
	return not e.out and not e.spectator
end

local function candidates(a: Active): { BattleRules.Candidate }
	local out: { BattleRules.Candidate } = {}
	for _, e in a.entrants do
		if inPlay(e) then
			local pos = positionOf(a, e.id)
			if pos then
				table.insert(out, { id = e.id, pos = pos })
			end
		end
	end
	return out
end

local function sendToast(target: Player?, text: string, tone: string?)
	local r = trackFlowRemote()
	if not r then
		return
	end
	local payload = { text = text, tone = tone or "info" }
	if target then
		r:FireClient(target, "BattleToast", payload)
		return
	end
	local to = ModeScopeRules.audience(Players:GetPlayers())
	if to == nil then
		r:FireAllClients("BattleToast", payload)
	else
		for _, p in to do
			r:FireClient(p, "BattleToast", payload)
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Pods
------------------------------------------------------------------------------------------------------------------------

-- Race item pods would hand out items along the race line through the arena; the battle uses only its own anchors.
-- (The map is rebuilt on every load, so nothing needs restoring.) Speed and Air pods stay: they are not items.
local function removeRacePods(boosts: Instance)
	for _, pod in boosts:GetChildren() do
		if pod:IsA("BasePart") and pod:GetAttribute("ItemPodSpawn") == true and string.sub(pod.Name, 1, #BattleCore.POD_PREFIX) ~= BattleCore.POD_PREFIX then
			if ItemRules.classifyPod(pod:GetAttribute("PodType")) == "item" then
				pod:Destroy()
			end
		end
	end
end

local function clearBattlePods()
	local boosts = TrackRegistry.getBoostsFolder()
	if not boosts then
		return
	end
	for _, pod in boosts:GetChildren() do
		if string.sub(pod.Name, 1, #BattleCore.POD_PREFIX) == BattleCore.POD_PREFIX then
			pod:Destroy()
		end
	end
end

-- Battle pods go in the track's Boosts folder so the existing claim path (client trigger -> RaceManager.handlePickup
-- -> ItemService.pickup -> pod-taken cooldown) and the client pod visuals work unchanged.
local function buildPods(specs: { BattleRules.PodSpec }): { BattleBots.Pod }
	local boosts = TrackRegistry.getBoostsFolder()
	local out: { BattleBots.Pod } = {}
	if not boosts then
		return out
	end
	removeRacePods(boosts)
	clearBattlePods()
	for i, spec in specs do
		local name = BattleCore.POD_PREFIX .. tostring(i)
		-- colored: battle pods stay DKR balloons with the colour rules (race pods are mystery cubes).
		local part: BasePart = Gameplay.buildItemPodSpawn(name, spec.pos, spec.podType, 0, boosts, { colored = true })
		part:SetAttribute("RespawnSeconds", spec.respawn)
		part:SetAttribute("BattlePod", true)
		table.insert(out, { name = name, part = part, pos = spec.pos, podType = spec.podType })
	end
	ItemEffectsModule.paintPods(boosts)
	return out
end

------------------------------------------------------------------------------------------------------------------------
-- HUD board
------------------------------------------------------------------------------------------------------------------------

local function boardOrder(a: Active): { Entrant }
	local list: { Entrant } = {}
	for _, e in a.entrants do
		if not e.spectator then
			table.insert(list, e)
		end
	end
	local index: { [Entrant]: number } = {}
	for i, e in list do
		index[e] = i
	end
	table.sort(list, function(x: Entrant, y: Entrant): boolean
		if x.out ~= y.out then
			return not x.out
		end
		if x.score ~= y.score then
			return x.score > y.score
		end
		return index[x] < index[y]
	end)
	return list
end

local function publishBoard(a: Active)
	a.boardDirty = false
	local rows = {}
	for _, e in boardOrder(a) do
		table.insert(rows, {
			n = e.name,
			s = e.scoreText,
			o = e.out,
			u = if e.player then e.player.UserId else nil,
		})
	end
	RaceAttr.set("BattleBoard", HttpService:JSONEncode(rows))
end

------------------------------------------------------------------------------------------------------------------------
-- End of a battle
------------------------------------------------------------------------------------------------------------------------

local function awardWin(a: Active, player: Player): { [string]: any }
	local ok, SaveService = pcall(require, server:WaitForChild("SaveService") :: any)
	if not ok then
		return { result = "rejected" }
	end
	local okAward, result, unlocked = pcall((SaveService :: any).award, player, "battle", a.ctx.zone, "battle_win:" .. a.ctx.trackId)
	if not okAward then
		log("award error user=%d err=%s", player.UserId, tostring(result))
		return { result = "rejected" }
	end
	local list: { string } = if type(unlocked) == "table" then unlocked else {}
	local fragments = player:GetAttribute("BattleFragments")
	local amulet = table.find(list, "battleAmulet") ~= nil
	log(
		"award user=%d player=%s kind=battle zone=%s track=%s result=%s fragments=%s%s",
		player.UserId,
		player.Name,
		a.ctx.zone,
		a.ctx.trackId,
		tostring(result),
		tostring(fragments),
		if amulet then " amulet=complete" else ""
	)
	return {
		result = tostring(result),
		fragments = if type(fragments) == "number" then fragments else nil,
		total = Progression.BATTLE_FRAGMENTS_TOTAL,
		amulet = amulet,
		livery = if amulet then Progression.BATTLE_AMULET_LIVERY else nil,
	}
end

local function finish(a: Active, result: Result)
	if a.phase == "over" or slot:get() ~= a then
		return
	end
	a.phase = "over"
	RaceAttr.set("BattleState", "over")
	-- Complete the ranking with anyone the mode left out (board order), spectators excluded.
	local ranking: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, id in result.ranking do
		local e = a.byId[id]
		if e and not e.spectator and not seen[id] then
			seen[id] = true
			table.insert(ranking, id)
		end
	end
	for _, e in boardOrder(a) do
		if not seen[e.id] then
			seen[e.id] = true
			table.insert(ranking, e.id)
		end
	end
	local winner = if result.winner then a.byId[result.winner] else nil
	-- Every record finishes: ItemService stops granting and firing, TrackDirector starts the return-to-hub timer.
	for player, rec in records() do
		rec.finished = true
		player:SetAttribute("RaceFinished", true)
	end
	local rows = {}
	for i, id in ranking do
		local e = a.byId[id]
		local texts = result.texts
		table.insert(rows, {
			rank = i,
			name = e.name,
			isPlayer = e.isPlayer,
			userId = if e.player then e.player.UserId else nil,
			text = (if texts then texts[id] else nil) or e.scoreText,
		})
	end
	log(
		"over kind=%s reason=%s winner=%s ranking=%s elapsed=%.1f",
		a.mode.kind,
		result.reason,
		if winner then winner.name else "none",
		table.concat(ranking, ","),
		serverNow() - a.goTime
	)
	local remote = trackFlowRemote()
	for _, e in a.entrants do
		local player = e.player
		-- Everyone still in the server sees the results (a leaver who rejoined watches as a new Player object); only a
		-- seated winner who never left is awarded.
		if player and player.Parent then
			local award: { [string]: any } = { result = "skip" }
			local won = winner == e and not e.spectator and not e.left
			if won then
				award = awardWin(a, player)
			end
			if remote then
				remote:FireClient(player, "BattleResults", {
					kind = a.mode.kind,
					title = a.mode.title,
					zone = a.ctx.zone,
					trackId = a.ctx.trackId,
					reason = result.reason,
					winnerName = if winner then winner.name else nil,
					youWon = won,
					-- A rejoined leaver watched the end: the client words its panel like a spectator's.
					spectator = e.spectator or e.left,
					rows = rows,
					award = award,
				})
			end
		end
	end
	publishBoard(a)
end

------------------------------------------------------------------------------------------------------------------------
-- Context for modes
------------------------------------------------------------------------------------------------------------------------

local function newCtx(a: Active, td: any, battle: any, folder: Folder, vehicle: string): Ctx
	local ctx = {} :: Ctx
	ctx.td = td
	ctx.battle = battle
	ctx.rules = if type(battle.rules) == "table" then battle.rules else {}
	ctx.arena = a.arena
	ctx.folder = folder
	ctx.zone = td.zone
	ctx.trackId = td.id
	ctx.vehicle = vehicle
	ctx.entrants = a.entrants
	ctx.byId = a.byId
	ctx.now = os.clock
	function ctx.elapsed(): number
		return serverNow() - a.goTime
	end
	function ctx.timeLeft(): number
		return BattleRules.timeLeft(a.endsAt, serverNow())
	end
	function ctx.position(id: string): Vector3?
		return positionOf(a, id)
	end
	function ctx.forward(id: string): Vector3?
		return forwardOf(a, id)
	end
	function ctx.alive(): { Entrant }
		local out: { Entrant } = {}
		for _, e in a.entrants do
			if inPlay(e) then
				table.insert(out, e)
			end
		end
		return out
	end
	function ctx.nearestOpponent(id: string, maxRange: number?): (Entrant?, number)
		local pos = positionOf(a, id)
		if not pos then
			return nil, math.huge
		end
		local best, d = BattleRules.nearestOpponent(id, pos, candidates(a), nil, nil, maxRange)
		return if best then a.byId[best] else nil, d
	end
	function ctx.pods(): { BattleBots.Pod }
		return a.pods
	end
	function ctx.nearestPod(id: string): BattleBots.Pod?
		local pos = positionOf(a, id)
		if not pos then
			return nil
		end
		local best: BattleBots.Pod? = nil
		local bestD = math.huge
		for _, pod in a.pods do
			if pod.part.Parent and pod.part:GetAttribute("OnCooldown") ~= true then
				local d = (pod.pos - pos).Magnitude
				if d < bestD then
					best, bestD = pod, d
				end
			end
		end
		return best
	end
	function ctx.holding(id: string): (string?, number)
		local st = ItemService.getState(id)
		return st.color, st.level
	end
	function ctx.setHud(id: string, text: string)
		local e = a.byId[id]
		if not e or e.hud == text then
			return
		end
		e.hud = text
		local player = e.player
		if player then
			player:SetAttribute("BattleHud", text)
		end
	end
	function ctx.setScore(id: string, score: number, text: string)
		local e = a.byId[id]
		if not e then
			return
		end
		if e.score ~= score or e.scoreText ~= text then
			e.score = score
			e.scoreText = text
			a.boardDirty = true
		end
	end
	function ctx.toast(id: string?, text: string, tone: string?)
		if id == nil then
			sendToast(nil, text, tone)
			return
		end
		local e = a.byId[id]
		local player = if e then e.player else nil
		if player then
			sendToast(player, text, tone)
		end
	end
	function ctx.eliminate(id: string, reason: string)
		local e = a.byId[id]
		if not e or e.out then
			return
		end
		e.out = true
		a.boardDirty = true
		local bot = e.bot
		if bot then
			BattleBots.setOut(bot, true)
		end
		local player = e.player
		if player then
			player:SetAttribute("BattleOut", true)
		end
		log("out %s (%s) reason=%s at=%.1f", e.name, e.id, reason, serverNow() - a.goTime)
	end
	function ctx.hit(victimId: string, attackerId: string?, source: string, stunSeconds: number?, pos: Vector3?): string
		local where = pos or positionOf(a, victimId) or a.arena.center
		local effects = itemEffects()
		if not effects then
			return "inactive"
		end
		return effects.hit(victimId, attackerId or victimId, source, stunSeconds or 1.2, where)
	end
	function ctx.respawn(id: string, cf: CFrame?)
		local e = a.byId[id]
		if not e then
			return
		end
		local frame = cf or BattleRules.spawnCFrame(a.arena, e.slot)
		local bot = e.bot
		if bot then
			bot.pos = frame.Position
			bot.forward = frame.LookVector
			bot.hull.CFrame = frame
			-- A bot has no FlightServer record (no LastRespawnClock stamp): its respawn protection (G2) is granted here,
			-- so a bot set down by a drown or the unstick watchdog gets the same bubble a player does.
			local effects = itemEffects()
			if effects and type((effects :: any).grantImmunity) == "function" then
				(effects :: any).grantImmunity(id)
			end
			return
		end
		local player = e.player
		local rec = if player then records()[player] else nil
		if player and rec then
			rec.lastCheckpointCF = frame
			if CarServer.isCar(rec.plane) then
				CarServer.expectTeleport(player, frame)
			end
			FlightServer.respawnAtLastCheckpoint(player, false)
		end
	end
	function ctx.finish(result: Result)
		finish(a, result)
	end
	function ctx.log(fmt: string, ...: any)
		log(fmt, ...)
	end
	return ctx
end

------------------------------------------------------------------------------------------------------------------------
-- Hooks into ItemService / ItemEffects
------------------------------------------------------------------------------------------------------------------------

local function installItemHooks(a: Active)
	ItemService.setArena({
		findBot = function(botId: number): any
			return BattleBots.find(botId)
		end,
		applyToBot = function(botId: number, effect: any): boolean
			return BattleBots.applyEffect(botId, effect)
		end,
		canAct = function(racerId: string): (boolean, string?)
			if slot:get() ~= a then
				return true
			end
			if a.phase == "over" then
				return false, "battle_over"
			end
			local e = a.byId[racerId]
			if e and not inPlay(e) then
				return false, "out"
			end
			return true
		end,
	})
	local effects = itemEffects()
	if effects and type(effects.setArena) == "function" then
		effects.setArena({
			order = function(): { string }
				local out: { string } = {}
				for _, c in candidates(a) do
					table.insert(out, c.id)
				end
				return out
			end,
			-- An arena bot's shots and magnets lock the opponent its mode hunts (Goal.attack) while that one is in play
			-- within 420 studs; otherwise the nearest opponent ahead (60-degree cone), else the nearest anywhere.
			-- A mode may rule an opponent out for this shooter (targetable: the water battle's deck rule and human-lock
			-- cooldown, trap audit I2-07) and hears which one was locked (locked).
			target = function(racerId: string): string?
				local pos = positionOf(a, racerId)
				if not pos then
					return nil
				end
				local shooter = a.byId[racerId]
				local list = candidates(a)
				local allow = a.mode.targetable
				if allow and shooter then
					local kept: { BattleRules.Candidate } = {}
					for _, c in list do
						local victim = a.byId[c.id]
						local okCall, may = true, true
						if victim and c.id ~= racerId then
							okCall, may = pcall(allow :: any, a.ctx, a.state, shooter, victim)
						end
						if not okCall or may ~= false then
							table.insert(kept, c)
						end
					end
					list = kept
				end
				local hunted = if shooter and shooter.bot then shooter.bot.attack else nil
				local pick: string? = nil
				if hunted and hunted ~= racerId then
					for _, c in list do
						if c.id == hunted and (c.pos - pos).Magnitude <= 420 then
							pick = hunted
							break
						end
					end
				end
				pick = pick
					or BattleRules.nearestOpponent(racerId, pos, list, forwardOf(a, racerId), 0.5, 420)
					or BattleRules.nearestOpponent(racerId, pos, list, nil, nil, 420)
				local onLock = a.mode.locked
				local victim = if pick then a.byId[pick] else nil
				if onLock and shooter and victim then
					guard("locked", function()
						onLock(a.ctx, a.state, shooter, victim)
					end)
				end
				return pick
			end,
			onHit = function(victim: string, attacker: string, source: string, pos: Vector3)
				if slot:get() ~= a or a.phase ~= "running" then
					return
				end
				local v = a.byId[victim]
				if not v or not inPlay(v) then
					return
				end
				local onHit = a.mode.onHit
				if onHit then
					local att = a.byId[attacker]
					guard("onHit", function()
						onHit(a.ctx, a.state, v, if att and att ~= v then att else nil, source, pos)
					end)
				end
			end,
		})
	end
end

local function clearItemHooks()
	ItemService.setArena(nil)
	local effects = itemEffects()
	if effects and type(effects.setArena) == "function" then
		effects.setArena(nil)
	end
	ItemService.setLevelOneOnly(false)
end

------------------------------------------------------------------------------------------------------------------------
-- Step
------------------------------------------------------------------------------------------------------------------------

-- A seated human still in the server (out of lives counts: it watches its own battle end). Spectators do not: when the
-- last seated player leaves, the battle waits and the replay seats whoever is watching.
local function humansPresent(a: Active): boolean
	for _, e in a.entrants do
		if e.isPlayer and not e.left and not e.spectator then
			return true
		end
	end
	return false
end

-- A player who watches this battle without a seat (late joiner, or a leaver back as a new Player object).
local function watchOnly(a: Active, player: Player, rec: any): string
	local hud = if a.phase == "over" then "" else "SPECTATING - next battle seats you"
	player:SetAttribute("BattleOut", true)
	player:SetAttribute("BattleHud", hud)
	if a.phase == "over" then
		rec.finished = true
	end
	return hud
end

-- Per group only: a player this battle marked (BattleOut, BattleHud, BoundaryReturnClock) who is no longer seated in
-- this race (back on the plaza, his group closed) loses the marks, so a stale BattleOut never keeps his rescue / RESPAWN
-- off in the hub. A player now in another race that runs its own battle keeps them: they are that battle's. Single
-- path: never called (stop clears every player, as before).
local function releaseLeaver(player: Player?)
	if not player or not ModeScopeRules.perGroup() or player.Parent == nil then
		return
	end
	local where = RaceScope.instanceOf(player)
	if where == RaceScope.current() or table.find(slot:holders(), where) ~= nil then
		return
	end
	player:SetAttribute("BattleHud", nil)
	player:SetAttribute("BattleOut", nil)
	player:SetAttribute("BoundaryReturnClock", nil)
end

local function syncPlayers(a: Active)
	local recs = records()
	-- Leavers first, so a player who left and came back in between is seen as gone before the rejoin below.
	for _, e in a.entrants do
		local player = e.player
		if player and not e.left and (player.Parent == nil or recs[player] == nil) then
			e.left = true
			local wasIn = inPlay(e)
			e.out = true
			a.boardDirty = true
			log("left %s phase=%s", e.name, a.phase)
			releaseLeaver(player)
			local onLeave = a.mode.onLeave
			-- A leaver forfeits from the countdown on (the mode's state exists from start): otherwise it keeps its
			-- score, and a survival leaver's lives would keep the battle from ending and could top the cap ranking.
			-- The last human leaving does not end the battle for the bots: step() sets it waiting for the next player.
			if wasIn and (a.phase == "running" or a.phase == "countdown") and onLeave and humansPresent(a) then
				guard("onLeave", function()
					onLeave(a.ctx, a.state, e)
				end)
			end
		end
	end
	for player, rec in recs do
		if player.Parent then
			local id = playerId(player)
			local known = a.byId[id]
			if not known then
				-- Joined after the battle was set up: spectates this one (FLY AGAIN seats everyone present).
				local e: Entrant = {
					id = id,
					name = player.Name,
					isPlayer = true,
					player = player,
					bot = nil,
					slot = 0,
					out = true,
					spectator = true,
					left = false,
					score = 0,
					scoreText = "",
					hud = "",
				}
				table.insert(a.entrants, e)
				a.byId[id] = e
				e.hud = watchOnly(a, player, rec)
				log("spectator %s joined phase=%s", player.Name, a.phase)
			elseif known.player ~= player and known.left then
				-- Left and rejoined (a new Player object): its seat stays forfeited, it watches the rest of this battle
				-- and gets the results; the HUD line is re-sent because the new object carries no attributes.
				known.player = player
				known.hud = watchOnly(a, player, rec)
				log("rejoined %s phase=%s (spectating)", player.Name, a.phase)
			end
		end
	end
end

-- Puts a player's vehicle on `cf` through the server CheckpointRespawn (the car validator is told first). byPlayer: the
-- player brought it on himself (flying out past the boundary band), so the respawn shield's rearm time applies like
-- for a respawn he asked for (ItemEffects.RESPAWN_IMMUNE_REARM: flying out again and again is no standing shield).
local function putOn(player: Player, rec: any, cf: CFrame, byPlayer: boolean?)
	rec.lastCheckpointCF = cf
	if CarServer.isCar(rec.plane) then
		CarServer.expectTeleport(player, cf)
	end
	FlightServer.respawnAtLastCheckpoint(player, false, byPlayer == true)
end

-- Past the boundary band (trap audit G6, I2-05): back on the mode's returnFrame (the water battle's tide-safe pad), else
-- on the player's own seat, never the nearest pad (a rival's seat beside its bot, F6). The stamp FlightServer just set
-- is copied to BoundaryReturnClock, so a mode can tell this put-back from a crash and keep a carried prize (D4-01).
-- Respawn protection comes with every server respawn (FlightServer.respawnAtLastCheckpoint, trap audit G2), held to
-- its rearm time here because the player flew out himself.
local function returnToArena(a: Active, e: Entrant, player: Player, rec: any, pos: Vector3)
	local cf: CFrame? = nil
	local how = "seat"
	local modeReturn = a.mode.returnFrame
	if modeReturn then
		local ok, frame = pcall(modeReturn :: any, a.ctx, a.state, e, pos)
		if ok and typeof(frame) == "CFrame" then
			cf, how = frame, "mode"
		elseif not ok then
			warn("[SkyRally][BATTLE] mode returnFrame error: " .. tostring(frame))
		end
	end
	local frame = cf or BattleRules.spawnCFrame(a.arena, e.slot)
	putOn(player, rec, frame, true)
	player:SetAttribute("BoundaryReturnClock", player:GetAttribute("LastRespawnClock"))
	sendToast(player, "Back into the arena!", "bad")
	local p = frame.Position
	log(
		"boundary return %s from=(%.0f,%.0f,%.0f) to=(%.0f,%.0f,%.0f) via=%s seat=%d",
		player.Name,
		pos.X,
		pos.Y,
		pos.Z,
		p.X,
		p.Y,
		p.Z,
		how,
		e.slot
	)
end

local function stepBoundary(a: Active)
	local now = os.clock()
	for _, e in a.entrants do
		local player = e.player
		if player and inPlay(e) then
			local rec = records()[player]
			local hull = if rec then rec.hull else nil
			if rec and hull and hull.Parent and not hull.Anchored then
				-- A mode that welds a prop to a vehicle (a carried egg or sack) resets the assembly's owner to automatic, after
				-- which the server simulates a hull the player no longer drives: keep every seated vehicle with its pilot.
				local ok, owner = pcall(function()
					return hull:GetNetworkOwner()
				end)
				if ok and owner ~= player then
					pcall(function()
						hull:SetNetworkOwner(player)
					end)
					log("network owner restored for %s (was %s)", player.Name, tostring(owner))
				end
			end
			if rec and hull and hull.Parent and player:GetAttribute("Crashing") ~= true then
				local pos = hull.Position
				local zone = BattleRules.zoneOf(a.arena, pos)
				if zone == "inside" and BattleRules.tooHigh(a.arena, pos) then
					zone = "high" -- the vertical warn band (G6): the client noses down, the toast says why
				end
				if zone == "warn" or zone == "high" then
					if now - (a.warnAt[player] or 0) > BattleCore.EDGE_TOAST_EVERY then
						a.warnAt[player] = now
						sendToast(player, if zone == "high" then "TOO HIGH - nose down" else "ARENA EDGE - turn back", "bad")
					end
				elseif zone == "out" then
					returnToArena(a, e, player, rec, pos)
					a.warnAt[player] = now
				end
			end
		end
	end
end

local function resolveNow(a: Active, reason: string)
	local ok, result = pcall(a.mode.resolve, a.ctx, a.state, reason)
	if not ok or type(result) ~= "table" then
		warn("[SkyRally][BATTLE] mode resolve error: " .. tostring(result))
		result = { winner = nil, ranking = {}, reason = reason }
	end
	finish(a, result :: Result)
end

-- Keeps a goal inside the hard boundary: a mode's approach swing (lining up a nest ring) may use the edge band but must
-- not aim past the return radius, which sent bots out of the arena and a chasing player into the boundary return.
function BattleCore.clampGoal(arena: BattleRules.Arena, goal: BattleBots.Goal?): BattleBots.Goal?
	if not goal then
		return nil
	end
	local c = arena.center
	local off = Vector3.new(goal.pos.X - c.X, 0, goal.pos.Z - c.Z)
	local limit = arena.returnRadius - 12
	if off.Magnitude <= limit then
		return goal
	end
	local p = c + off.Unit * limit
	return { pos = Vector3.new(p.X, goal.pos.Y, p.Z), attack = goal.attack, reason = goal.reason }
end

local function botWorld(a: Active): BattleBots.World
	return {
		arena = a.arena,
		goal = function(bot: BattleBots.Bot): BattleBots.Goal?
			local e = a.byId[bot.racerId]
			local fn = a.mode.botGoal
			if not e or not fn then
				return nil
			end
			local ok, goal = pcall(fn, a.ctx, a.state, e)
			if not ok then
				warn("[SkyRally][BATTLE] mode botGoal error: " .. tostring(goal))
				return nil
			end
			return BattleCore.clampGoal(a.arena, goal)
		end,
		pods = function(): { BattleBots.Pod }
			return a.pods
		end,
		entrants = function(): { BattleRules.Candidate }
			return candidates(a)
		end,
		missileHolders = function(): { [string]: boolean }
			local out: { [string]: boolean } = {}
			for _, e in a.entrants do
				if inPlay(e) and ItemService.getState(e.id).color == "red" then
					out[e.id] = true
				end
			end
			return out
		end,
		ignore = { a.folder },
		maxWaterDepth = a.mode.maxWaterDepth,
		waterLevel = if a.mode.waterLevel
			then function(): number?
				local fn = a.mode.waterLevel
				local ok, level = pcall(fn :: any, a.ctx, a.state)
				return if ok and type(level) == "number" then level else nil
			end
			else nil,
		itemDelay = a.mode.botItemDelay,
	}
end

-- Studio QA (workspace.QAPilotGoals): publish where the mode's bot brain would send each player, so the real-key
-- pilot (tools/windows/key_pilot.js goal=qa) plays the mode with keyboard input. Player attributes QAGoal (Vector3) and QAFire
-- (holding an item with an opponent in front within 140 studs).
local function qaGoals(a: Active)
	for _, e in a.entrants do
		local player = e.player
		if player and inPlay(e) then
			local goal: BattleBots.Goal? = nil
			local fn = a.mode.botGoal
			if fn then
				local ok, g = pcall(fn, a.ctx, a.state, e)
				goal = if ok then BattleCore.clampGoal(a.arena, g) else nil
			end
			local color = ItemService.getState(e.id).color
			if not goal then
				local pod = if color == nil then a.ctx.nearestPod(e.id) else nil
				local opp = a.ctx.nearestOpponent(e.id)
				local oppPos = if opp then positionOf(a, opp.id) else nil
				goal = if pod then { pos = pod.pos } elseif oppPos then { pos = oppPos } else { pos = a.arena.center }
			end
			local pos, fwd = positionOf(a, e.id), forwardOf(a, e.id)
			local fire = false
			if color ~= nil and pos and fwd then
				for _, o in a.entrants do
					local op = if o ~= e and inPlay(o) then positionOf(a, o.id) else nil
					if op and (op - pos).Magnitude < 140 and (op - pos).Unit:Dot(fwd) > 0.75 then
						fire = true
						break
					end
				end
			end
			player:SetAttribute("QAGoal", (goal :: BattleBots.Goal).pos)
			player:SetAttribute("QAFire", fire)
		end
	end
end

-- BattleBots' fixed-step accumulator (Shared.RacerViewRules), one per scope (one for the server on the single path, kept
-- across battles as before).
local function botClockFor(): RacerViewRules.ServerClock
	return RaceScope.state("BattleBotClock", function(): any
		return RacerViewRules.newServerClock()
	end)
end

local function botHulls(): { BasePart }
	local parts = {}
	for _, bot in BattleBots.list() do
		local hull = (bot :: any).hull
		if hull and hull.Parent and hull.Anchored then
			table.insert(parts, hull)
		end
	end
	return parts
end

local function step(a: Active, dt: number)
	if not a.folder.Parent then
		BattleCore.stop() -- the map was torn down under us
		return
	end
	syncPlayers(a)
	local now = serverNow()
	if a.phase == "waiting" then
		-- Nobody was seated (QA boot, or everyone left): seat the first player present with a fresh countdown.
		for player in records() do
			if player.Parent and deps and os.clock() - a.replayAt > 2 then
				a.replayAt = os.clock()
				log("player present: restarting the battle")
				-- Off the Heartbeat thread: the restart rebuilds vehicles, which may wait on a mesh load.
				task.spawn(ModeScopeRules.bind(deps.replay))
				return
			end
		end
	elseif not humansPresent(a) and a.phase ~= "over" then
		a.phase = "waiting"
		RaceAttr.set("BattleState", "waiting")
		log("every player left: battle waits")
	elseif (a.phase :: Phase) == "countdown" and now >= a.goTime then
		a.phase = "running"
		RaceAttr.set("BattleState", "running")
		log("GO kind=%s entrants=%d cap=%.0f", a.mode.kind, #a.entrants, a.endsAt - a.goTime)
	end
	if a.phase == "running" and workspace:GetAttribute("TriggerBattleEnd") == true then
		workspace:SetAttribute("TriggerBattleEnd", false)
		resolveNow(a, "qa")
	end
	local world = a.world or botWorld(a)
	a.world = world
	-- Whole fixed steps (as AIRacers.step): the clients' bot view times every replicated pose on a uniform grid.
	local botClock = botClockFor()
	local botSteps, botDt = RacerViewRules.serverSteps(botClock, dt)
	for _ = 1, botSteps do
		BattleBots.step(botDt, world, if a.phase == "running" then "running" elseif a.phase == "over" then "over" else "countdown")
	end
	if botSteps > 0 then
		RacerViewRules.publish(2, botClock, botHulls) -- the clients' stamped pose stream (Shared.RacerStreamRules)
	end
	if a.phase == "running" and RunService:IsStudio() and workspace:GetAttribute("QAPilotGoals") == true then
		a.qaTimer -= dt
		if a.qaTimer <= 0 then
			a.qaTimer = 0.25
			qaGoals(a)
		end
	end
	if a.phase == "running" then
		a.boundaryTimer -= dt
		if a.boundaryTimer <= 0 then
			a.boundaryTimer = 0.2
			stepBoundary(a)
		end
		local modeStep = a.mode.step
		if modeStep then
			guard("step", function()
				modeStep(a.ctx, a.state, dt)
			end)
		end
		if a.phase == "running" and now >= a.endsAt then
			resolveNow(a, "time")
		end
	end
	a.boardTimer -= dt
	if a.boardDirty and a.boardTimer <= 0 then
		a.boardTimer = 0.25
		publishBoard(a)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------------------------------------

-- How far a seated vehicle may stand from its seat before the start puts it there (a teleport's arrival radius).
BattleCore.SEAT_SNAP = 30

-- Every seat sets the respawn frame on the server and on the client (the stale-respawn fix): the record's
-- lastCheckpointCF becomes the seat and FlightServer.setRespawnFrame sends it to the client's cache (CarController /
-- FlightController fall back on it when a respawn reply is late). A vehicle that is not on its seat (the race reset gave
-- another pad, or it still stands on the previous map) is put there by a server CheckpointRespawn.
local function seatPlayer(arena: BattleRules.Arena, player: Player, rec: any, slot: number)
	local cf = BattleRules.spawnCFrame(arena, slot)
	local hull = rec.hull
	local onSeat = hull ~= nil and hull.Parent ~= nil and (hull.Position - cf.Position).Magnitude <= BattleCore.SEAT_SNAP
	if onSeat then
		rec.lastCheckpointCF = cf
		FlightServer.setRespawnFrame(player, cf)
	else
		putOn(player, rec, cf)
		log("seat %s put on seat %d (was %s)", player.Name, slot, if hull and hull.Parent then string.format("(%.0f,%.0f,%.0f)", hull.Position.X, hull.Position.Y, hull.Position.Z) else "no vehicle")
	end
end

-- While a battle runs (FlightServer.respawnGuard): a respawn frame that is not this arena's is replaced by the
-- player's seat, so nothing respawns onto a previous map; a player out of the battle is not respawned at all. A
-- respawn the player's client asked for (a crash, the RESPAWN button, the stuck watchdog) onto a frame the mode no
-- longer calls safe goes through the mode's returnFrame: the water battle's last pad may have flooded since, and a
-- free rescue must never set a car down in the tide to drown and lose a life. A frame that is still safe stands, so
-- the answer matches the client's cached frame (no second teleport when the reply is late).
local function respawnGuard(a: Active, player: Player, cf: CFrame, asked: boolean?): (CFrame?, boolean)
	if slot:get() ~= a then
		return nil, false
	end
	local e = a.byId[playerId(player)]
	if e and e.player == player and e.out then
		return nil, true
	end
	local modeReturn, modeSafe = a.mode.returnFrame, a.mode.frameSafe
	local unsafe = false
	if asked and modeReturn and modeSafe and e and e.player == player and a.phase == "running" then
		local okSafe, safe = pcall(modeSafe :: any, a.ctx, a.state, cf.Position)
		unsafe = okSafe and safe == false
		if not okSafe then
			warn("[SkyRally][BATTLE] mode frameSafe error: " .. tostring(safe))
		end
	end
	if unsafe and e then
		local rec = records()[player]
		local hull = rec and rec.hull
		local pos = if hull and hull.Parent then hull.Position else cf.Position
		local ok, frame = pcall(modeReturn :: any, a.ctx, a.state, e, pos)
		if ok and typeof(frame) == "CFrame" then
			log(
				"asked respawn %s frame (%.0f,%.0f,%.0f) unsafe -> (%.0f,%.0f,%.0f) via=mode",
				player.Name,
				cf.Position.X,
				cf.Position.Y,
				cf.Position.Z,
				frame.Position.X,
				frame.Position.Y,
				frame.Position.Z
			)
			return frame, false
		elseif not ok then
			warn("[SkyRally][BATTLE] mode returnFrame error: " .. tostring(frame))
		end
	end
	if BattleRules.ownsFrame(a.arena, cf.Position) then
		return nil, false
	end
	local seat = BattleRules.spawnCFrame(a.arena, if e and e.slot > 0 then e.slot else 1)
	log("stale respawn frame for %s at (%.0f,%.0f,%.0f): seat instead", player.Name, cf.Position.X, cf.Position.Y, cf.Position.Z)
	return seat, false
end

-- FlightServer.startOverride: arena seats while RaceMode is "battle" (players spawn on the pads at the race reset).
function BattleCore.startCFrame(slotIndex: number): CFrame?
	if RaceAttr.here("RaceMode") ~= "battle" or not deps then
		return nil
	end
	local arena = BattleRules.arena(battleOf(deps.trackData()))
	return if arena then BattleRules.spawnCFrame(arena, slotIndex) else nil
end

-- Per group: one respawn guard for the server that asks the player's own race's battle (none: no guard, as when no
-- battle runs).
local function scopedRespawnGuard(player: Player, cf: CFrame, asked: boolean): (CFrame?, boolean)
	return ModeScopeRules.runFor(player, function(): (CFrame?, boolean)
		local a = slot:get()
		if not a then
			return nil, false
		end
		return respawnGuard(a, player, cf, asked)
	end)
end

function BattleCore.stop()
	local a = slot:get()
	if not a then
		return
	end
	slot:set(nil)
	if not ModeScopeRules.perGroup() then
		FlightServer.respawnGuard = nil
	elseif not slot:any() then
		FlightServer.respawnGuard = nil -- the last battle on the server went
	end
	local modeStop = a.mode.stop
	if modeStop then
		guard("stop", function()
			modeStop(a.ctx, a.state)
		end)
	end
	BattleBots.despawn()
	clearItemHooks()
	clearBattlePods()
	a.folder:Destroy()
	for _, attr in { "BattleKind", "BattleTitle", "BattleState", "BattleEndsAt", "BattleBoard", "BattleZone", "BattleCenter", "BattleRadius", "BattleReturnRadius", "BattlePullStart", "BattleCeiling" } do
		RaceAttr.set(attr, nil)
	end
	for _, p in RaceScope.players(Players:GetPlayers()) do
		p:SetAttribute("BattleHud", nil)
		p:SetAttribute("BattleOut", nil)
		p:SetAttribute("BoundaryReturnClock", nil)
	end
	-- Per group a group's close runs after its players left its scope (RaceGroups.returnToHub): clear them too.
	if ModeScopeRules.perGroup() then
		for _, e in a.entrants do
			releaseLeaver(e.player)
		end
	end
	log("stopped kind=%s phase=%s", a.mode.kind, a.phase)
end

-- No battle runs on this load (refused, or the mode failed to start): every record finishes so TrackDirector's
-- return-to-hub timer brings the players back, instead of leaving them in an empty arena with no results or exit.
local function releasePlayers()
	for player, rec in records() do
		rec.finished = true
		player:SetAttribute("RaceFinished", true)
	end
end

local function refuse(td: any, why: string)
	log("no battle on %s: %s", tostring(td and td.id), why)
	sendToast(nil, "This battle is coming soon", "info")
	releasePlayers()
end

function BattleCore.start(td: any)
	BattleCore.stop()
	local d = deps
	if not d then
		warn("[SkyRally][BATTLE] start before init")
		return
	end
	local battle = battleOf(td)
	if not battle then
		refuse(td, "no modes.battle block")
		return
	end
	local mode = modes[tostring(battle.kind)]
	if not mode then
		refuse(td, "no mode for kind " .. tostring(battle.kind))
		return
	end
	local arena = BattleRules.arena(battle)
	if not arena then
		refuse(td, "no arena centre/radius")
		return
	end
	local root = TrackRegistry.getRoot()
	local folder = Instance.new("Folder")
	folder.Name = "BattleOverlay"
	folder.Parent = root or workspace
	if root then
		root:SetAttribute("CarOffTrackDrop", 0) -- the arena is off the route: no "stranded" respawns (CarController)
	end
	local vehicle = CarServer.activeVehicle()
	local rules = if type(battle.rules) == "table" then battle.rules else {}
	ItemService.setLevelOneOnly(rules.levelOneOnly ~= false)

	-- Field: players on the pads they spawned on, bots on the free ones.
	local seated: { { player: Player, rec: any } } = {}
	for player, rec in records() do
		if player.Parent then
			table.insert(seated, { player = player, rec = rec })
		end
	end
	-- A mode with fewer seats than humans (egg: a nest per seat) seats the first `cap`; the rest watch, and sit first
	-- next round (L71, L75, L30).
	local seatCap = if mode.capacity then mode.capacity(battle, arena) else -1
	local ids: { number } = {}
	local bySeatId: { [number]: { player: Player, rec: any } } = {}
	for _, s in seated do
		table.insert(ids, s.player.UserId)
		bySeatId[s.player.UserId] = s
	end
	local held = waiting()
	local seatIds, overflowIds = BattleRules.splitSeats(ids, held.ids, seatCap)
	table.sort(seatIds)
	seated = {}
	for _, id in seatIds do
		table.insert(seated, bySeatId[id])
	end
	held.ids = {}
	for _, id in overflowIds do
		held.ids[id] = true
	end
	-- A player keeps the pad its spawn gave it. A frame that is not in this arena (a record not yet reset off the
	-- previous map) says nothing about a seat: that player takes the pads in order like a fresh spawn would, never the
	-- pad that happens to lie nearest the old map (which could be the galleon deck).
	local positions: { Vector3 } = {}
	for i, s in seated do
		local cf = s.rec.lastCheckpointCF
		local here = if typeof(cf) == "CFrame" and BattleRules.ownsFrame(arena, cf.Position) then cf.Position else nil
		table.insert(positions, here or BattleRules.spawnPosition(arena, i))
	end
	local fieldSeats = if mode.fieldSize then mode.fieldSize(battle, arena) elseif seatCap > 0 then seatCap else nil
	local botCount = BattleRules.botCount(#seated, fieldSeats)
	local playerSlots, botSlots = BattleRules.assignSlots(arena, positions, botCount)
	local entrants: { Entrant } = {}
	local byId: { [string]: Entrant } = {}
	for i, s in seated do
		local e: Entrant = {
			id = playerId(s.player),
			name = s.player.Name,
			isPlayer = true,
			player = s.player,
			bot = nil,
			slot = playerSlots[i],
			out = false,
			spectator = false,
			left = false,
			score = 0,
			scoreText = "",
			hud = "",
		}
		table.insert(entrants, e)
		byId[e.id] = e
		s.player:SetAttribute("BattleOut", false)
		s.player:SetAttribute("BattleHud", "")
		seatPlayer(arena, s.player, s.rec, e.slot)
	end
	for _, id in overflowIds do
		local o = bySeatId[id]
		local hud = "SPECTATING - all nests taken, next battle seats you"
		local e: Entrant = {
			id = playerId(o.player),
			name = o.player.Name,
			isPlayer = true,
			player = o.player,
			bot = nil,
			slot = 0,
			out = true,
			spectator = true,
			left = false,
			score = 0,
			scoreText = "",
			hud = hud,
		}
		table.insert(entrants, e)
		byId[e.id] = e
		o.player:SetAttribute("BattleOut", true)
		o.player:SetAttribute("BattleHud", hud)
	end
	for _, bot in BattleBots.spawn(botCount, botSlots, arena, vehicle) do
		local e: Entrant = {
			id = bot.racerId,
			name = bot.name,
			isPlayer = false,
			player = nil,
			bot = bot,
			slot = bot.slot,
			out = false,
			spectator = false,
			left = false,
			score = 0,
			scoreText = "",
			hud = "",
		}
		table.insert(entrants, e)
		byId[e.id] = e
	end

	local go = RaceAttr.here("RaceGoTime")
	local goTime = if type(go) == "number" then go else serverNow()
	local cap = mode.capSeconds or tonumber(rules.capSeconds) or tonumber(battle.capSeconds) or tonumber(rules.timeCapSeconds) or BattleRules.CAP_SECONDS
	local a: Active = {
		mode = mode,
		ctx = nil :: any,
		state = nil,
		world = nil,
		arena = arena,
		folder = folder,
		pods = {},
		entrants = entrants,
		byId = byId,
		goTime = goTime,
		endsAt = goTime + cap,
		phase = if #seated == 0 then "waiting" elseif serverNow() < goTime then "countdown" else "running",
		boardDirty = true,
		boardTimer = 0,
		boundaryTimer = 0,
		qaTimer = 0,
		warnAt = {},
		started = os.clock(),
		replayAt = -math.huge,
	}
	local ctx = newCtx(a, td, battle, folder, vehicle)
	a.ctx = ctx
	-- Trap I2-05: plan barriers (e.g. the ISLAND-2 cavern-mouth road) exist only while this battle runs.
	BattleBarriers.build(battle, folder)
	local specs = BattleRules.podSpecs(battle, mode.podTypes)
	local itemPods = mode.itemPods
	if itemPods then
		local okPods, custom = pcall(itemPods, ctx)
		if okPods and type(custom) == "table" then
			specs = custom
		else
			warn("[SkyRally][BATTLE] mode itemPods error: " .. tostring(custom))
		end
	end
	a.pods = buildPods(specs)
	slot:set(a)
	installItemHooks(a)
	if ModeScopeRules.perGroup() then
		FlightServer.respawnGuard = scopedRespawnGuard
	else
		FlightServer.respawnGuard = function(player: Player, cf: CFrame, asked: boolean): (CFrame?, boolean)
			return respawnGuard(a, player, cf, asked)
		end
	end

	RaceAttr.set("BattleKind", mode.kind)
	RaceAttr.set("BattleTitle", mode.title)
	-- The arena for the clients' edge pull (FlightController / CarController steer back in past the play radius; a
	-- plane from BattlePullStart, one turn radius inside the return line, and nose down under BattleCeiling).
	RaceAttr.set("BattleCenter", arena.center)
	RaceAttr.set("BattleRadius", arena.radius)
	RaceAttr.set("BattleReturnRadius", arena.returnRadius)
	RaceAttr.set("BattlePullStart", BattleRules.pullStart(arena, vehicle))
	RaceAttr.set("BattleCeiling", if arena.ceiling < math.huge then arena.ceiling else nil)
	RaceAttr.set("BattleZone", td.zone)
	RaceAttr.set("BattleEndsAt", a.endsAt)
	RaceAttr.set("BattleState", a.phase)

	local ok, state = pcall(mode.start, ctx)
	if not ok then
		warn("[SkyRally][BATTLE] mode start error: " .. tostring(state))
		BattleCore.stop()
		sendToast(nil, "The battle failed to start", "bad")
		releasePlayers()
		return
	end
	a.state = state
	publishBoard(a)
	if not conn then
		conn = RunService.Heartbeat:Connect(BattleCore.stepAll)
	end
	log(
		"start kind=%s track=%s vehicle=%s players=%d bots=%d pods=%d cap=%.0f phase=%s radius=%.0f return=%.0f",
		mode.kind,
		tostring(td.id),
		vehicle,
		#seated,
		botCount,
		#a.pods,
		cap,
		a.phase,
		arena.radius,
		arena.returnRadius
	)
end

-- Every scope's battle, each in its own scope (the single path: the one battle, as before).
function BattleCore.stepAll(dt: number)
	slot:each(function(a: Active)
		step(a, dt)
	end)
end

-- Registers every mode under server/battle/modes and wires the spawn override. Call once from the boot script.
function BattleCore.init(d: Deps)
	deps = d
	FlightServer.startOverride = BattleCore.startCFrame
	local folder = (script.Parent :: Instance):FindFirstChild("modes")
	if folder then
		for _, m in folder:GetChildren() do
			if m:IsA("ModuleScript") then
				local ok, mode = pcall(require, m)
				if ok and type(mode) == "table" then
					BattleCore.register(mode :: any)
				else
					warn("[SkyRally][BATTLE] mode " .. m.Name .. " failed to load: " .. tostring(mode))
				end
			end
		end
	end
end

return BattleCore
