--!strict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local PlaneGuardRules = require(Shared:WaitForChild("PlaneGuardRules")) -- minimum lap time (L30, L53)
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local SailGateRules = require(Shared:WaitForChild("SailGateRules")) -- FOREST-1 sail-gap ring: the server re-checks the clock
local RemoteGuardRules = require(Shared:WaitForChild("RemoteGuardRules")) -- T1-9: ring/pad claims, rate limit
local TriggerRules = require(Shared:WaitForChild("TriggerRules"))
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local Progression = require(Shared:WaitForChild("Progression"))
-- Who beat the boss with 2+ humans (L13, L16, L30): shared/RaceFlowRules, specced in tools/tests/raceflow_spec.luau.
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
-- Starting grid order (docs/design/GRID_ORDER.md): shared/GridOrder, specced in tools/tests/grid_order_spec.luau.
local GridOrder = require(Shared:WaitForChild("GridOrder"))
-- Economy v3 phase 2: bots per field count the humans in that field (shared/RaceInstanceRules; the single-race path
-- still counts every player on the server while RaceFlowRules.PER_GROUP is false).
local RaceInstanceRules = require(Shared:WaitForChild("RaceInstanceRules"))
-- Phase 2b: per-race state per RaceInstance (shared/RaceScope) and the race attributes of the scope a step runs in
-- (shared/RaceAttr: workspace on the single-race path, the instance root per group).
local RaceScope = require(Shared:WaitForChild("RaceScope"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local FlightServer = require(script.Parent.FlightServer)
-- Plane checkpoint rule (FLIGHT_GUIDE.md 12): Free driving must not skip the course.
local FlightGuideRules = require(Shared:WaitForChild("FlightGuideRules"))
local RouteBranch = require(Shared:WaitForChild("RouteBranch"))
local AIRacers = require(script.Parent.AIRacers)
local StormFlowRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StormFlowRules"))
local VolcanoVents = require(script.Parent.VolcanoVents)
local ItemService = require(script.Parent.ItemService)
local SaveService = require(script.Parent.SaveService)
local ItemEffects = require(script.Parent.kit.ItemEffects)
-- REMARKABLE item 11: the once-per-race Sauropod Sneeze pose on top of the sway below (server/SauropodSneeze).
local SauropodSneeze = require(script.Parent.SauropodSneeze)

-- Race loop: checkpoints, laps, finish order, standings, pod pickups (validated here, granted by ItemService) and the
-- finish awards (LAUNCH_PROGRESSION sections 3-5). The server awards only from its own finish event; the client
-- never sends a result. A race that is left or reset before the finish awards nothing.
local RaceManager = {}

-- Modes whose finish is a real time on the track, so it may set the per-track best time (bestTimes{trackId:ms}).
-- Only "race" (the standard race) awards the race token. Coin, boss and battle award through their own events (L4).
-- "stormcup" (server/StormCup) is deliberately not timed: its modifiers (night, double item boxes) change the course, so
-- a cup time is not comparable with the track record; it awards no token either, only Gears and Win Pass (Economy).
local TIMED_MODES: { [string]: boolean } = { race = true, timetrial = true, quickrace = true }

export type FinishInfo = {
	trackId: string,
	mode: string,
	rank: number,
	time: number, -- seconds
	finished: boolean,
	simulated: boolean?, -- TriggerSimulateFinish (QA): never sets a best time, awards only in Studio
	-- Boss, rematch and final boss (L13, L16, L30): this human crossed the line before the boss bot. nil (old callers,
	-- the spec's hand-built infos) falls back to rank 1.
	beatBoss: boolean?,
	-- Storm race v2 (mode "stormrace"): this human crossed the line before the storm dragon (shared/StormFlowRules.beatDragon);
	-- nil in every other mode (server/StormShards then falls back to its own rule).
	beatDragon: boolean?,
}

export type AwardSummary = {
	trackId: string,
	mode: string,
	token: string?,
	tokenResult: string, -- SaveService AwardResult, or "skip" when the rules give nothing
	bestTimeMs: number?,
	bestTimeResult: string,
	tokens: number?, -- SkyTokens after the award (HUD)
	unlocked: { string },
}

-- What awardFinish needs from SaveService; the Lune spec injects a SaveService.new() over a memory store here.
export type Saver = {
	award: (player: Player, kind: any, id: string, sourceEvent: string, value: number?) -> (string, { string }),
}
RaceManager.saver = nil :: Saver?
-- Studio check, injectable for the spec (simulated finishes award only in Studio).
RaceManager.isStudio = function(): boolean
	return RunService:IsStudio()
end

export type CheckpointInfo = {
	index: number,
	station: number,
	part: BasePart,
	respawnCF: CFrame,
}

RaceManager.checkpoints = {} :: { CheckpointInfo }
RaceManager.raceStartClock = os.clock()
RaceManager.finishOrder = {} :: { { name: string, isPlayer: boolean, time: number, rank: number, isBoss: boolean? } }

-- The replicated Station attribute is a hint for the owner's client (SplineUtils.projectPosition window, MoonMonorail's
-- crossing judge), so it is written at 10 Hz like the bots' (AIRacers), not every Heartbeat: 8 players x 60 writes/s
-- went to every client (perf review v21 PF-08). rec.station stays exact on the server every step.
local STATION_ATTR_INTERVAL = 0.1
local stationAttrAt: { [Player]: number } = {}
-- The cliff line (RouteBranch.cliffProgress) each car was on last step, for its enter/stay hysteresis (weak keys).
local cliffHeld: { [Player]: string? } = setmetatable({}, { __mode = "k" }) :: any
local raceEventRemote: RemoteEvent? = nil
-- TrackDirector: no race steps while a map switch tears down and rebuilds the world.
RaceManager.suspended = false

-- Economy v3 phase 2b (docs/design/PER_GROUP_RACES.md): everything below that belongs to ONE race lives in a per-race
-- state table from shared/RaceScope. On the single-race path (RaceFlowRules.PER_GROUP false) there is exactly one such
-- table for the life of the server, so every read and write lands where the old module locals did. Per group, each
-- RaceInstance steps inside RaceScope.run(id, ...) and gets its own: finish order, checkpoints, lap clocks, rings, grid
-- history, start clock. finishOrder, checkpoints, raceStartClock and suspended stay readable as RaceManager fields
-- (PhotoFinish, SelfTest, the specs) through the metatable at the end of this block.
type RaceState = {
	finishOrder: { { name: string, isPlayer: boolean, time: number, rank: number, isBoss: boolean? } },
	checkpoints: { CheckpointInfo },
	raceStartClock: number,
	suspended: boolean,
	lapStartClocks: { [Player]: number },
	bestLapTimes: { [Player]: number },
	hudTickAccumulator: number,
	-- Rings and boost pads touched this race (client-reported, so Economy caps what it pays for them).
	ringCounts: { [Player]: number },
	-- Mode of the race the last reset started, so the next reset knows whether an unfinished racer abandoned a race.
	lastResetMode: string?,
	-- Grid order, this server's memory only (no DataStore): each human's place and grid position in the last gridded
	-- race (GridOrder.harvest; dropped on leave, ignored after GridOrder.HISTORY_TTL), that race's human DNFs, and the
	-- grid positions of the race now running.
	gridHistory: { [number]: { place: number, grid: number?, at: number } },
	gridLastDnf: number,
	raceGrid: { [number]: number },
	dinoPatrolAngle: number,
	-- The plane checkpoint rule's cache: the must-pass checkpoint indices, and the lines and count they were built for.
	planeCPLines: { any }?,
	planeCPTotal: number,
	planeCPMust: { number },
	-- The track's cliff lines (RouteBranch.cliffOnly of the lines above); a car on one is on course (see the step).
	cliffLines: { any },
	-- kit/Gameplay paints Yellow/Green/Rainbow pods red; repaint every item pod once per built Boosts folder.
	paintedBoosts: Instance?,
	-- Item rotation index: non-hub races started in this scope (per group, like RaceResetSeq; see the pool draw).
	itemRaceCount: number,
}
local function newRaceState(): RaceState
	return {
		finishOrder = {},
		checkpoints = {},
		raceStartClock = os.clock(),
		suspended = false,
		lapStartClocks = {},
		bestLapTimes = {},
		hudTickAccumulator = 0,
		ringCounts = {},
		lastResetMode = nil,
		gridHistory = {},
		gridLastDnf = 0,
		raceGrid = {},
		dinoPatrolAngle = 0,
		planeCPLines = nil,
		planeCPTotal = -1,
		planeCPMust = {},
		cliffLines = {},
		paintedBoosts = nil,
		itemRaceCount = 0,
	}
end
local function S(): RaceState
	return RaceScope.state("RaceManager", newRaceState)
end
local ROUTED: { [string]: boolean } = { finishOrder = true, checkpoints = true, raceStartClock = true, suspended = true }
for k in ROUTED do
	(RaceManager :: any)[k] = nil
end
setmetatable(RaceManager :: any, {
	__index = function(_: any, k: string): any
		return if ROUTED[k] then (S() :: any)[k] else nil
	end,
	__newindex = function(t: any, k: string, v: any)
		if ROUTED[k] then
			(S() :: any)[k] = v
		else
			rawset(t, k, v)
		end
	end,
})
-- Coin challenge: whether this player holds every coin (set by the boot script from CoinChallenge).
RaceManager.coinsComplete = nil :: ((Player) -> boolean)?
-- Economy (set by the boot script to the Economy module): Gears and Win Pass progress on a real finish, Rally Streak
-- reset when a racer leaves a running race unfinished. Separate from awardFinish, so race results and token logic
-- never depend on it; nil (Lune loop spec) pays nothing.
export type EconomyHook = {
	raceFinished: (player: Player, info: any) -> any,
	raceAbandoned: (player: Player) -> (),
}
RaceManager.economy = nil :: EconomyHook?
-- L27 / audit M3: analytics funnel events (server/Funnels.hook, set by the boot script; nil in the Lune specs and when
-- analytics is off): "countdown" when a race loads or replays, "finish" for a real finish. Never throws, never gates a race.
RaceManager.funnelHook = nil :: ((event: string, player: Player?, data: any) -> ())?
-- Social lane: called with (player, FinishInfo, AwardSummary?, { totalLen, laps }) after the saved award of a real finish
-- (server/Leaderboards posts the time and stars, server/BadgeAwards judges the badges). Set by the boot script; nil in the
-- Lune specs. It never gates or changes the race result.
RaceManager.finishHook = nil :: ((player: Player, info: FinishInfo, award: AwardSummary?, ctx: { totalLen: number, laps: number }) -> ())?
local function funnel(event: string, player: Player?, data: any)
	local hook = RaceManager.funnelHook
	if hook then
		pcall(hook, event, player, data)
	end
end
-- Rings and boost pads per racer per race (RaceState.ringCounts) are capped here.
local RING_COUNT_CAP = 60
-- Per-server salt for the grid seed, so race 1 on every server does not draw the same grid (RaceResetSeq restarts at
-- 1 on each server). The seed (salt + RaceResetSeq) is logged with each grid line.
local gridSalt = (os.time() % 100000) * 1000 + math.floor((os.clock() % 1) * 1000)

-- Legacy DINO-4 finish arch, used until the active track registers its own finish.
local LEGACY_FINISH_POS = Vector3.new(0, 152, 0)
local LEGACY_FINISH_RADIUS = 58

-- A track switch must not keep gating laps on the previous track's parts; stepRace reloads an empty list. (Per group the
-- workspace ActiveTrackId is the hub's; each instance loads its own list in its scope and keeps it.)
workspace:GetAttributeChangedSignal("ActiveTrackId"):Connect(function()
	table.clear(RaceManager.checkpoints)
end)

function RaceManager.loadCheckpoints()
	table.clear(RaceManager.checkpoints)
	local cpFolder = TrackRegistry.getCheckpointsFolder()
	if not cpFolder then
		return
	end
	-- MapAdapter builds Checkpoints before it publishes the spline (mesh loads yield in between); respawn frames
	-- sampled now would all sit at the sampleAtStation default and never reload, so stay empty until it exists.
	local wps = SplineUtils.loadWaypoints()
	if #wps < 2 then
		return
	end

	for _, child in ipairs(cpFolder:GetChildren()) do
		if child:IsA("BasePart") then
			local idx = (child:GetAttribute("CheckpointIndex") :: number?) or 1
			local st = (child:GetAttribute("Station") :: number?) or 0
			local pos, tan, bank = SplineUtils.sampleAtStation(st)
			local spawnPos = pos + Vector3.new(0, 12, 0)
			local respawnCF = CFrame.lookAt(spawnPos, spawnPos + tan) * CFrame.Angles(0, 0, math.rad(bank * 0.3))
			table.insert(RaceManager.checkpoints, {
				index = idx,
				station = st,
				part = child,
				respawnCF = respawnCF,
			})
		end
	end

	table.sort(RaceManager.checkpoints, function(a: CheckpointInfo, b: CheckpointInfo): boolean
		return a.index < b.index
	end)
	RaceAttr.set("TotalCheckpoints", #RaceManager.checkpoints)
end

local function countPassedCheckpoints(map: { [number]: boolean }): (number, number)
	local count = 0
	local highest = 1
	for idx, passed in pairs(map) do
		if passed then
			count = count + 1
			if idx > highest then
				highest = idx
			end
		end
	end
	return count, highest
end

local function stepSauropodHazard(dt: number)
	local landmarks = TrackRegistry.getLandmarks()
	if not landmarks then
		return
	end
	local dino = landmarks:FindFirstChild("RoamingGreenSauropod")
	if not dino or not dino:IsA("Model") then
		return
	end
	S().dinoPatrolAngle = (S().dinoPatrolAngle + dt * 0.45) % (math.pi * 2)
	local swayYaw = math.sin(S().dinoPatrolAngle) * 3.5
	local basePos = (dino:GetAttribute("BasePivotPos") :: Vector3?) or Vector3.new(20, 139, -158)
	local baseYaw = (dino:GetAttribute("BaseYawDeg") :: number?) or 0
	local swayCF = CFrame.new(basePos) * CFrame.Angles(0, math.rad(baseYaw + swayYaw), 0)
	-- REMARKABLE item 11: SauropodSneeze adds the sneeze pose (visual only) once per race; elsewhere it returns swayCF.
	local racing = not RaceManager.isHub() and not RaceManager.isBattle() and os.clock() >= RaceManager.raceStartClock
	dino:PivotTo(SauropodSneeze.apply(dino, swayCF, RaceManager.raceStartClock, racing))
end

type StandingEntry = {
	name: string,
	racerId: string, -- ItemService racer id, so item targeting uses the same order the HUD shows
	rank: number,
	lap: number,
	progress: number,
	finished: boolean,
	finishTime: number,
	isPlayer: boolean,
}

local function buildStandingsPayload(totalLen: number): { StandingEntry }
	local entries: { StandingEntry } = {}

	for player, rec in pairs(RaceScope.filter(FlightServer.records)) do
		local prog = (rec.lap - 1) * totalLen + rec.station
		if rec.finished then
			prog = PlaneConfig.TOTAL_LAPS * totalLen + (10000 - rec.finishRank * 100)
		end
		table.insert(entries, {
			name = player.Name,
			racerId = ItemService.playerRacerId(player.UserId),
			rank = 1,
			lap = rec.lap,
			progress = prog,
			finished = rec.finished,
			finishTime = rec.finishTime,
			isPlayer = true,
		})
	end

	for _, bot in ipairs(AIRacers.bots) do
		local botProgress = if bot.lap == 1 and bot.station > totalLen - 350 then (bot.station - totalLen) else ((bot.lap - 1) * totalLen + bot.station)
		local prog = botProgress
		if bot.finished then
			prog = PlaneConfig.TOTAL_LAPS * totalLen + (10000 - bot.finishRank * 100)
		end
		table.insert(entries, {
			name = bot.name,
			racerId = ItemService.botRacerId(bot.id),
			rank = 1,
			lap = bot.lap,
			progress = prog,
			finished = bot.finished,
			finishTime = bot.finishTime,
			isPlayer = false,
		})
	end

	table.sort(entries, function(a, b): boolean
		if a.finished and b.finished then
			return a.finishTime < b.finishTime
		elseif a.finished ~= b.finished then
			return a.finished
		end
		return a.progress > b.progress
	end)

	for r, item in ipairs(entries) do
		item.rank = r
	end

	return entries
end

-- (economy v3 phase 4, PlaneConfig.BOT_DISGUISE) What a client is told about the standings: rows copied with isPlayer true
-- only for the recipient's own row (the results card highlights "you"), and no racerId (it spells "bot:<n>"). Bots and
-- other humans are then indistinguishable on the card. Server-side logic keeps the full entries.
local function standingsFor(player: Player, standings: { StandingEntry }): { any }
	if not PlaneConfig.BOT_DISGUISE then
		return standings
	end
	local out = {}
	for i, entry in ipairs(standings) do
		local row = table.clone(entry) :: any
		row.isPlayer = entry.isPlayer and entry.name == player.Name
		row.racerId = nil
		out[i] = row
	end
	return out
end

-- Every racer id, leader first (finished racers included). ItemEffects picks "the racer ahead" from this.
function RaceManager.racerOrder(): { string }
	local _, totalLen = SplineUtils.loadWaypoints()
	local out: { string } = {}
	for _, entry in ipairs(buildStandingsPayload(totalLen)) do
		table.insert(out, entry.racerId)
	end
	return out
end

function RaceManager.getMode(): string
	-- Mode layer (PLAN L2) not in the registry yet: the mode is a workspace attribute, standard race by default.
	local mode = RaceAttr.here("RaceMode")
	return if type(mode) == "string" and mode ~= "" then mode else "race"
end

-- Finish awards (LAUNCH_PROGRESSION sections 3 and 5). Rank 1 in a standard race -> the track's race token; any timed
-- finish -> best time in ms. SaveService makes repeats a logged no-op (double finish, retry after a win, rejoin), so
-- this never needs its own "already awarded" memory. Returns what happened for the results screen.
function RaceManager.awardFinish(player: Player, info: FinishInfo): AwardSummary
	local save: Saver = RaceManager.saver or (SaveService :: any)
	local summary: AwardSummary = {
		trackId = info.trackId,
		mode = info.mode,
		token = nil,
		tokenResult = "skip",
		bestTimeMs = nil,
		bestTimeResult = "skip",
		tokens = nil,
		unlocked = {},
	}
	local function log(kind: string, id: string, result: string, note: string?)
		print(string.format(
			"[SkyRally][AWARD] user=%d player=%s kind=%s id=%s track=%s mode=%s rank=%d result=%s%s",
			player.UserId,
			player.Name,
			kind,
			id,
			info.trackId,
			info.mode,
			info.rank,
			result,
			if note then " (" .. note .. ")" else ""
		))
	end

	local trackInfo = Progression.TRACKS[info.trackId]
	-- A second human who finishes ahead of the boss beats it too: friends progress together (L30).
	local beatBoss = if info.beatBoss ~= nil then info.beatBoss else info.rank == 1
	-- The final boss runs on the hub loop, which has no zone and no race token.
	if info.finished and info.trackId == Progression.HUB_TRACK and info.mode == "boss" and not (info.simulated and not RaceManager.isStudio()) then
		if beatBoss then
			local result, unlocked = save.award(player, "finalBoss", "HUB-BOSS-1", "boss_finish")
			summary.tokenResult = result
			summary.unlocked = unlocked
			log("finalBoss", "HUB-BOSS-1", result)
		else
			log("finalBoss", "HUB-BOSS-1", "skip", "rank " .. tostring(info.rank))
		end
		return summary
	end
	if not info.finished then
		log("finish", "-", "skip", "not finished: abandoned races award nothing")
		return summary
	elseif not trackInfo or not trackInfo.zone then
		log("finish", "-", "skip", "no race rewards on this track")
		return summary
	elseif info.simulated and not RaceManager.isStudio() then
		log("finish", "-", "skip", "simulated finish outside Studio")
		return summary
	end

	if info.mode == "race" then
		local tokenId = Progression.raceTokenId(info.trackId)
		summary.token = tokenId
		if info.rank == 1 then
			local result, unlocked = save.award(player, "token", tokenId, "race_finish")
			summary.tokenResult = result
			summary.unlocked = unlocked
			log("token", tokenId, result, if #unlocked > 0 then "unlocked " .. table.concat(unlocked, ",") else nil)
		else
			log("token", tokenId, "skip", "rank " .. tostring(info.rank) .. " is not a win")
		end
	end

	if info.mode == "boss" or info.mode == "rematch" then
		local kind = if info.mode == "boss" then "bossFirst" else "bossRematch"
		if beatBoss then
			local result, unlocked = save.award(player, kind :: any, info.trackId, "boss_finish")
			summary.tokenResult = result
			summary.unlocked = unlocked
			log(kind, info.trackId, result, if #unlocked > 0 then "unlocked " .. table.concat(unlocked, ",") else nil)
		else
			log(kind, info.trackId, "skip", "the boss won")
		end
	elseif info.mode == "coin" then
		local tokenId = Progression.coinTokenId(info.trackId)
		summary.token = tokenId
		local allCoins = RaceManager.coinsComplete ~= nil and RaceManager.coinsComplete(player)
		if info.rank == 1 and allCoins then
			local result, unlocked = save.award(player, "token", tokenId, "coin_finish")
			summary.tokenResult = result
			summary.unlocked = unlocked
			log("token", tokenId, result)
		else
			log("token", tokenId, "skip", if info.rank ~= 1 then "not a win" else "coins missing")
		end
	end

	if TIMED_MODES[info.mode] then
		if info.simulated then
			log("bestTime", info.trackId, "skip", "simulated finish time is not a real time")
		elseif info.time > 0 and info.time == info.time and info.time < math.huge then
			local ms = math.floor(info.time * 1000 + 0.5)
			local result = save.award(player, "bestTime", info.trackId, "race_finish", ms)
			summary.bestTimeMs = ms
			summary.bestTimeResult = result
			log("bestTime", info.trackId, result, string.format("%d ms", ms))
		end
	end

	local tokens = player:GetAttribute("SkyTokens")
	summary.tokens = if type(tokens) == "number" then tokens else nil
	return summary
end

function RaceManager.completePlayerLap(rec: FlightServer.PlayerFlightRecord, now: number, totalLen: number, simulated: boolean?)
	local player = rec.player
	local lapStart = S().lapStartClocks[player] or RaceManager.raceStartClock
	local lapDuration = math.max(1.0, now - lapStart)
	local prevBest = S().bestLapTimes[player]
	if not prevBest or lapDuration < prevBest then
		S().bestLapTimes[player] = lapDuration
		player:SetAttribute("BestLapTime", lapDuration)
	end

	FlightServer.guideNewLap(rec) -- RETURN's best progress restarts from the line
	if rec.lap < PlaneConfig.TOTAL_LAPS then
		rec.lap = rec.lap + 1
		rec.passedCheckpoints = { [1] = true }
		rec.lastCheckpointIdx = 1
		-- X-04 (docs/audits/traps_summary.md): CP1 is marked passed here and never passed again this lap, so the
		-- respawn frame stayed at the previous lap's last checkpoint until CP2 and a crash between the line and CP2 sent
		-- the racer back behind the line. Move the frame to CP1 and tell the client (planes respawn from their own cache).
		for _, cp in RaceManager.checkpoints do
			if cp.index == 1 then
				rec.lastCheckpointCF = cp.respawnCF
				if raceEventRemote then
					raceEventRemote:FireClient(player, "CheckpointPassed", {
						checkpoint = 1,
						totalCheckpoints = #RaceManager.checkpoints,
						respawnCFrame = cp.respawnCF,
					})
				end
				break
			end
		end
		S().lapStartClocks[player] = now
		player:SetAttribute("Lap", rec.lap)
		player:SetAttribute("Checkpoint", 1)

		if raceEventRemote then
			raceEventRemote:FireClient(player, "LapCompleted", {
				lap = rec.lap,
				totalLaps = PlaneConfig.TOTAL_LAPS,
				lapTime = lapDuration,
				bestLap = S().bestLapTimes[player] or lapDuration,
			})
		end
	elseif not rec.finished and not rec.dnf then
		-- L30: a racer the DNF deadline caught keeps flying until the reset, but a late crossing is no finish.
		rec.finished = true
		rec.finishTime = math.max(1.0, now - RaceManager.raceStartClock)
		local rank = #RaceManager.finishOrder + 1
		local beatBoss = RaceFlowRules.botsAhead(RaceManager.finishOrder) == 0
		local beatDragon: boolean? = nil
		if RaceManager.getMode() == "stormrace" then
			local dragon = false
			for _, b in AIRacers.bots do
				if b.isBoss then
					dragon = true
				end
			end
			beatDragon = StormFlowRules.beatDragon(RaceManager.finishOrder, dragon)
		end
		rec.finishRank = rank
		table.insert(RaceManager.finishOrder, {
			name = player.Name,
			isPlayer = true,
			time = rec.finishTime,
			rank = rank,
		})
		print(string.format("[SkyRally][RACE] finish rank=%d name=%s player=true time=%.2f", rank, player.Name, rec.finishTime))

		local orbAwarded = 0
		if rank == 1 then
			orbAwarded = 1
			rec.orbs = rec.orbs + 1
			player:SetAttribute("Orbs", rec.orbs)
			player:SetAttribute("NextTrackUnlocked", true)
		end

		player:SetAttribute("RaceFinished", true)
		player:SetAttribute("FinishRank", rank)
		player:SetAttribute("FinishTime", rec.finishTime)

		-- Awards never yield (SaveService queues the write), so the results screen gets the outcome in this payload.
		local finishInfo: FinishInfo = {
			trackId = TrackRegistry.getActiveId(),
			mode = RaceManager.getMode(),
			rank = rank,
			time = rec.finishTime,
			finished = true,
			simulated = simulated == true,
			beatBoss = beatBoss,
			beatDragon = beatDragon,
		}
		local okAward, awardOrErr = pcall(RaceManager.awardFinish, player, finishInfo)
		local award: AwardSummary? = if okAward then awardOrErr else nil
		if not okAward then
			print(string.format("[SkyRally][AWARD] error user=%d: %s", player.UserId, tostring(awardOrErr)))
		end
		-- Social lane (leaderboards, badges): after the saved award, never part of the result.
		local finishHook = RaceManager.finishHook
		if finishHook then
			local okHook, hookErr = pcall(function(): any
				finishHook(player, finishInfo, award, { totalLen = totalLen, laps = PlaneConfig.TOTAL_LAPS })
				return nil
			end)
			if not okHook then
				print(string.format("[SkyRally][RACE] finish hook error user=%d: %s", player.UserId, tostring(hookErr)))
			end
		end
		funnel("finish", player, {
			track = TrackRegistry.getActiveId(),
			mode = RaceManager.getMode(),
			token = award ~= nil and award.tokenResult == "awarded",
			rank = finishInfo.rank,
		})

		-- Gears for the results screen; an economy failure never touches the race result above.
		local gears: any = nil
		local econ = RaceManager.economy
		if econ then
			local mode = RaceManager.getMode()
			local coins = player:GetAttribute("Coins")
			local okEcon, econOrErr = pcall(econ.raceFinished, player, {
				trackId = TrackRegistry.getActiveId(),
				mode = mode,
				rank = rank,
				laps = PlaneConfig.TOTAL_LAPS,
				rings = S().ringCounts[player] or 0,
				coins = if mode == "coin" and type(coins) == "number" then coins else 0,
				simulated = simulated == true,
				repeatWin = (mode == "boss" or mode == "rematch") and beatBoss and not (award ~= nil and award.tokenResult == "awarded"),
			})
			if okEcon then
				gears = econOrErr
			else
				print(string.format("[SkyRally][ECON] finish hook error user=%d: %s", player.UserId, tostring(econOrErr)))
			end
		end

		local standings = buildStandingsPayload(totalLen)
		if raceEventRemote then
			raceEventRemote:FireClient(player, "RaceFinished", {
				rank = rank,
				totalTime = rec.finishTime,
				bestLap = S().bestLapTimes[player] or lapDuration,
				orbAwarded = orbAwarded,
				totalOrbs = rec.orbs,
				standings = standingsFor(player, standings),
				trackId = TrackRegistry.getActiveId(),
				award = award,
				gears = gears,
				beatBoss = beatBoss, -- BossRetirement's defeat gag and the card's "BOSS BEATEN" with 2+ humans
				beatDragon = finishInfo.beatDragon, -- storm race v2: the card's "DRAGON BEATEN" (after the Shards hook)
			})
		end
	end
end

local function ensurePodsPainted()
	local boosts = TrackRegistry.getBoostsFolder()
	if boosts and boosts ~= S().paintedBoosts then
		S().paintedBoosts = boosts
		ItemEffects.paintPods(boosts)
	end
end

-- A new map is live (TrackDirector.load): forget everything that belonged to the previous track.
function RaceManager.onTrackChanged()
	table.clear(RaceManager.finishOrder)
	table.clear(S().lapStartClocks)
	table.clear(S().bestLapTimes)
	table.clear(S().ringCounts)
	S().paintedBoosts = nil
	SplineUtils.loadWaypoints(true)
	RaceManager.loadCheckpoints()
	ensurePodsPainted()
end

function RaceManager.isHub(): boolean
	return RaceAttr.here("RaceMode") == "hub"
end

-- Battle overlays (server/battle/BattleCore) score their own objective: no checkpoints, laps or finish line there.
function RaceManager.isBattle(): boolean
	return RaceAttr.here("RaceMode") == "battle"
end

-- True when at least one player is in the race and every player in it has finished (or timed out as DNF, L30).
function RaceManager.allPlayersFinished(): boolean
	local any = false
	for player, rec in pairs(RaceScope.filter(FlightServer.records)) do
		if player.Parent then
			any = true
			if not rec.finished and not rec.dnf then
				return false
			end
		end
	end
	return any
end

-- L30: the DNF deadline passed with this player still racing (TrackDirector, 2+ humans). No award and no Gears (no
-- finish), the Rally Streak survives the next reset; the client shows a DNF card ("RaceDNF") where it can vote.
function RaceManager.markDnf(player: Player)
	local rec = FlightServer.records[player]
	if not rec or rec.finished or rec.dnf then
		return
	end
	rec.dnf = true
	print(string.format("[SkyRally][RACE] dnf name=%s lap=%d (deadline passed: no award, streak kept)", player.Name, rec.lap))
	if raceEventRemote then
		local _, totalLen = SplineUtils.loadWaypoints()
		raceEventRemote:FireClient(player, "RaceDNF", {
			dnf = true,
			standings = standingsFor(player, buildStandingsPayload(totalLen)),
			trackId = TrackRegistry.getActiveId(),
			lap = rec.lap,
		})
	end
end

-- goTime (server time, workspace:GetServerTimeNow()) starts a countdown: bots hold and clients hold their vehicles on
-- the grid until it passes (workspace.RaceGoTime). nil starts at once (hub, QA resets).
function RaceManager.resetRaceForAll(goTime: number?)
	-- Grid order: the race now ending is next grid's "last race" (gridded modes that had started only; the hub between
	-- two races keeps it). Read before the records reset.
	if S().lastResetMode and GridOrder.isGridded(S().lastResetMode) and os.clock() > RaceManager.raceStartClock then
		local results: { GridOrder.Result } = {}
		for player, rec in pairs(RaceScope.filter(FlightServer.records)) do
			table.insert(results, {
				userId = player.UserId,
				finished = rec.finished,
				rank = rec.finishRank,
				dnf = rec.dnf,
				grid = S().raceGrid[player.UserId],
			})
		end
		local hist, dnf = GridOrder.harvest(results, PlaneConfig.AI_FIELD_SIZE)
		table.clear(S().gridHistory)
		for uid, e in hist do
			S().gridHistory[uid] = { place = e.place, grid = e.grid, at = os.clock() }
		end
		S().gridLastDnf = dnf
	end
	-- Rally Streak: a racer still unfinished when a race that had started is reset (replay, back to the hub, map
	-- switch) breaks their streak. Checked before raceStartClock moves.
	local econ = RaceManager.economy
	if econ and S().lastResetMode and S().lastResetMode ~= "hub" and S().lastResetMode ~= "battle" and os.clock() > RaceManager.raceStartClock then
		for player, rec in pairs(RaceScope.filter(FlightServer.records)) do
			-- L30: a DNF by the deadline is not quitting; only an unfinished racer who did not time out loses the streak.
			if not rec.finished and not rec.dnf then
				pcall(econ.raceAbandoned, player)
			end
		end
	end
	S().lastResetMode = RaceManager.getMode()
	table.clear(S().ringCounts)
	local holdFor = if goTime then math.max(0, goTime - workspace:GetServerTimeNow()) else 0
	RaceAttr.set("RaceGoTime", goTime)
	RaceManager.raceStartClock = os.clock() + holdFor
	table.clear(RaceManager.finishOrder)
	local seq = ((RaceAttr.here("RaceResetSeq") :: number?) or 0) + 1
	-- Grid order (GRID_ORDER.md section 3): humans in a fixed order (by UserId, never pairs()), each with this
	-- server's last result; the plan seats humans and bots, seeded by gridSalt + this race's RaceResetSeq.
	local mode = RaceManager.getMode()
	local ordered: { Player } = {}
	for player in pairs(RaceScope.filter(FlightServer.records)) do
		table.insert(ordered, player)
	end
	table.sort(ordered, function(a: Player, b: Player): boolean
		return a.UserId < b.UserId
	end)
	local humans: { GridOrder.Human } = {}
	local nowClock = os.clock()
	for _, player in ordered do
		local hist = S().gridHistory[player.UserId]
		local fresh = hist ~= nil and nowClock - hist.at <= GridOrder.HISTORY_TTL
		table.insert(humans, {
			userId = player.UserId,
			lastPlace = if fresh and hist then hist.place else nil,
			lastGrid = if fresh and hist then hist.grid else nil,
		})
	end
	local fieldHumans = RaceInstanceRules.fieldHumans(RaceFlowRules.PER_GROUP, #Players:GetPlayers(), #humans)
	local plan = GridOrder.assign(humans, AIRacers.botsNeeded(fieldHumans), PlaneConfig.AI_FIELD_SIZE, gridSalt + seq, mode, S().gridLastDnf)
	AIRacers.resetBots(plan)
	-- Held items, shields, pod ledger and every projectile/trap belong to the race that just ended.
	ItemService.reset()
	local effects = ItemEffects.active
	if effects then
		effects.clear()
	end
	-- Items v4 rotation (ItemRules.ROTATION): this race's pool, drawn once from the server salt and the race number. The
	-- hub's free-roam cubes keep the classic set. Clients read the pool from the race attribute (ghosts, roulette,
	-- the countdown's "This race:" toast); the bots roll through the same ItemService pool.
	-- A dedicated race counter per scope (not RaceResetSeq: race -> hub -> race advances that by 2, so the pools skipped
	-- specials; not module-global either: groups on one server would interleave it). It counts this group's races only,
	-- so any ceil(9/4) = 3 consecutive races of a group cover all nine specials.
	local pool = nil
	if mode ~= "hub" then
		local st = S()
		st.itemRaceCount += 1
		pool = ItemRules.drawPool(gridSalt, st.itemRaceCount)
	end
	ItemService.setPool(pool)
	RaceAttr.set(ItemRules.ROTATION.poolAttribute, if pool then ItemRules.poolText(pool) else "")

	if goTime then
		funnel("countdown", nil, { track = TrackRegistry.getActiveId(), mode = RaceManager.getMode(), hold = holdFor })
	end

	RaceAttr.set("RaceStartCF", FlightServer.getStartCFrame(1))
	RaceAttr.set("RaceResetSeq", seq)

	table.clear(S().raceGrid)
	for i, player in ordered do
		local uid = player.UserId
		local slot = plan.humanSlots[uid] or i
		local newRec = FlightServer.spawnOrResetPlane(player, slot)
		-- Countdown HUD line (client TrackFlow, GridOrder.hudLine); no line on the fixed grids.
		player:SetAttribute("GridSlot", slot)
		player:SetAttribute("GridPosition", if plan.exempt then nil else plan.humanPositions[uid])
		player:SetAttribute("GridField", if plan.exempt then nil else plan.field)
		player:SetAttribute("GridReason", if plan.exempt then nil else plan.reasons[uid])
		player:SetAttribute("GridLastPlace", if plan.exempt then nil else plan.lastPlaces[uid])
		if not plan.exempt then
			S().raceGrid[uid] = plan.humanPositions[uid]
			print(string.format(
				"[SkyRally][GRID] seed=%d mode=%s name=%s position=%d/%d slot=%d reason=%s last=%s",
				gridSalt + seq,
				mode,
				player.Name,
				plan.humanPositions[uid] or 0,
				plan.field,
				slot,
				tostring(plan.reasons[uid]),
				tostring(plan.lastPlaces[uid])
			))
		end
		S().lapStartClocks[player] = RaceManager.raceStartClock
		S().bestLapTimes[player] = nil
		player:SetAttribute("RaceElapsed", 0)
		player:SetAttribute("LapElapsed", 0)
		if raceEventRemote then
			raceEventRemote:FireClient(player, "RaceReset", {
				startCFrame = newRec.lastCheckpointCF,
			})
		end
	end
end

-- Hides a pod for its RespawnSeconds for every racer (cubes v3: shared like Mario Kart, 1.0 s for race pods). Only the
-- visual and the client trigger gate (OnCooldown); the item grant gate is ItemService's own ledger. The taker's client
-- has already popped it (client/PodLocal), every other client pops it when OnCooldown arrives; all regrow on its return.
function RaceManager.startPodCooldown(pod: BasePart)
	if pod:GetAttribute("OnCooldown") == true then
		return
	end
	pod:SetAttribute("OnCooldown", true)
	local core = pod:FindFirstChild(pod.Name .. "_CoreVisual") :: BasePart?
	-- Restore whatever each visual part had (the balloon art is opaque, the mystery cube's glass translucent and its
	-- frame parts are children of the glass, so the whole subtree hides and comes back).
	local shown: { [BasePart]: number } = {}
	if core then
		shown[core] = core.Transparency
		for _, d in core:GetDescendants() do
			if d:IsA("BasePart") then
				shown[d] = d.Transparency
			end
		end
		for part in shown do
			part.Transparency = 1
		end
	end
	local respawnSec = (pod:GetAttribute("RespawnSeconds") :: number?) or 4
	task.delay(respawnSec, function()
		if pod and pod.Parent then
			pod:SetAttribute("OnCooldown", false)
			for part, tr in shown do
				if part.Parent then
					part.Transparency = tr
				end
			end
		end
	end)
end

local function findPod(podName: string): BasePart?
	local boosts = TrackRegistry.getBoostsFolder()
	local pod = if boosts then boosts:FindFirstChild(podName) else nil
	if pod and pod:IsA("BasePart") and pod:GetAttribute("ItemPodSpawn") == true then
		return pod
	end
	return nil
end

local lastPickupRejectLog: { [Player]: number } = {}
local function logPickupReject(player: Player, reason: string, detail: string)
	local now = os.clock()
	local last = lastPickupRejectLog[player]
	if last and now - last < 1 then
		return -- one line per player per second; a spamming client must not flood the log
	end
	lastPickupRejectLog[player] = now
	print(string.format("[SkyRally][RACE] pickup reject user=%d reason=%s %s", player.UserId, reason, detail))
end

-- Client "PickupCollected" is only a claim. Item pods go to ItemService, which re-checks the distance from the
-- server's view of the hull, its pod ledger and the race phase before granting (the pod-taken handler then hides it).
-- Speed/Air pods are client effects, but the shared visual only flips after the same distance and cooldown check.
function RaceManager.handlePickup(player: Player, rec: FlightServer.PlayerFlightRecord, podName: any)
	if type(podName) ~= "string" or #podName == 0 or #podName > 64 or string.find(podName, "%c") then
		logPickupReject(player, "bad_pod_name", "")
		return
	end
	local pod = findPod(podName)
	if not pod then
		logPickupReject(player, "unknown_pod", "pod=" .. podName)
		return
	end
	local podClass = ItemRules.classifyPod(pod:GetAttribute("PodType"))
	if podClass == "item" then
		ItemService.pickup(ItemService.playerRacerId(player.UserId), podName)
		return
	elseif podClass == "unknown" then
		logPickupReject(player, "unknown_pod_type", "pod=" .. podName)
		return
	end
	if pod:GetAttribute("OnCooldown") == true then
		return -- another racer took it this instant; not suspicious
	end
	if not rec.hull or not rec.hull.Parent then
		logPickupReject(player, "no_vehicle", "pod=" .. podName)
		return
	end
	-- Plane-map Speed/Air pods carry PickupLift (cubes v2): the same tall capsule the client tests, with the server's
	-- own lag-tolerant radius around it.
	local lift = pod:GetAttribute("PickupLift")
	local d = rec.hull.Position - pod.Position
	local dist = ItemRules.liftedDistance(d.X, d.Y, d.Z, if type(lift) == "number" then lift else 0)
	if dist > ItemService.PICKUP_RADIUS then
		logPickupReject(player, "too_far", string.format("pod=%s dist=%.1f max=%.1f", podName, dist, ItemService.PICKUP_RADIUS))
		return
	end
	RaceManager.startPodCooldown(pod)
end

-- kit/Gameplay paints Yellow/Green/Rainbow pods red; repaint every item pod once per built Boosts folder.

-- QA (workspace.TriggerSimulateFinish): every racer of this scope completes the remaining laps at once.
local function simulateFinish(now: number, totalLen: number)
	for _, rec in pairs(RaceScope.filter(FlightServer.records)) do
		for lap = rec.lap, PlaneConfig.TOTAL_LAPS do
			for _, cp in ipairs(RaceManager.checkpoints) do
				rec.passedCheckpoints[cp.index] = true
			end
			rec.lastCheckpointIdx = #RaceManager.checkpoints
			RaceManager.completePlayerLap(rec, now + lap * 42, totalLen, true)
		end
	end
end

local function stepRace(dt: number)
	if RaceManager.suspended then
		return
	end
	local now = os.clock()
	local raceElapsed = now - RaceManager.raceStartClock
	local _, totalLen = SplineUtils.loadWaypoints()
	if #RaceManager.checkpoints == 0 then
		RaceManager.loadCheckpoints()
		if #RaceManager.checkpoints > 0 then
			-- Checkpoints load only once the spline exists, which MapAdapter publishes after every gameplay object.
			ensurePodsPainted()
		end
	end
	local totalCP = #RaceManager.checkpoints
	local requiredCP = math.max(3, math.floor(totalCP * PlaneConfig.CHECKPOINT_GATE_FRACTION))
	-- Planes (FLIGHT_GUIDE.md 12): every checkpoint an alternate line does not bypass (less one of slack), so a
	-- Free-driving chord across the map cannot skip the course. Cars keep the old fraction (owner rule: car driving
	-- untouched). Rebuilt only when the checkpoints or the published lines change (RouteBranch.load is cached).
	local lines = RouteBranch.load(TrackRegistry.getRoot(), RouteBranch.PLANE_LIFT)
	if lines ~= S().planeCPLines or totalCP ~= S().planeCPTotal then
		S().planeCPLines, S().planeCPTotal = lines, totalCP
		-- A cliff line is car progress only: it bypasses no plane gate.
		S().planeCPMust = FlightGuideRules.mustPassCheckpoints(RaceManager.checkpoints, RouteBranch.withoutCliff(lines))
		S().cliffLines = RouteBranch.cliffOnly(lines)
	end
	local cliffLines = S().cliffLines

	stepSauropodHazard(dt)

	if workspace:GetAttribute("TriggerRaceReset") == true then
		workspace:SetAttribute("TriggerRaceReset", false)
		RaceManager.resetRaceForAll()
	end

	-- A battle has no laps to simulate; its own QA trigger is workspace.TriggerBattleEnd (BattleCore).
	if workspace:GetAttribute("TriggerSimulateFinish") == true and not RaceManager.isBattle() then
		workspace:SetAttribute("TriggerSimulateFinish", false)
		simulateFinish(now, totalLen)
	end

	local leadPlayerDist = 0
	for player, rec in pairs(RaceScope.filter(FlightServer.records)) do
		if not S().lapStartClocks[player] then
			S().lapStartClocks[player] = RaceManager.raceStartClock
		end

		-- A car whose last replicated move was corrected as impossible earns no progress until it is trusted again
		-- (car review: the server copy of the hull keeps the bad position for a round trip).
		local trusted = not (rec.plane and rec.plane:GetAttribute("PositionTrusted") == false)
		if rec.hull and rec.hull.Parent and trusted then
			local prevStation = rec.station
			local st, ribbonPoint, _, distToSpline = SplineUtils.projectPosition(rec.hull.Position, prevStation)
			-- ISLAND-2 Alt2 (RouteBranch cliff line): a car riding the headland wall is on course. The main spline lies
			-- 100+ studs under it, so its station comes from the line (join..rejoin by distance along it), and the
			-- 240-stud course gate below counts it as near. Cars only: planes keep the plane rules. Never moves the car.
			if #cliffLines > 0 and rec.plane:GetAttribute("VehicleType") == "car" then
				local lift = Vector3.new(0, RouteBranch.PLANE_LIFT, 0)
				local line, lineSt = RouteBranch.cliffProgress(cliffLines, rec.hull.Position + lift, distToSpline, cliffHeld[player])
				local id = if line then line.id else nil
				if id ~= cliffHeld[player] then
					player:SetAttribute("CliffLine", id) -- QA: the server's view (the client RouteBranch never picks a cliff line)
				end
				cliffHeld[player] = id
				if line then
					st, distToSpline = lineSt, 0
				end
			end
			rec.station = st
			if now >= (stationAttrAt[player] or 0) then
				stationAttrAt[player] = now + STATION_ATTR_INTERVAL
				player:SetAttribute("Station", math.floor(st))
			end
			-- Flight-path guide (FLIGHT_GUIDE.md 4.6): the server's off-course clock and best progress for RETURN.
			FlightServer.stepGuide(rec, st, ribbonPoint, dt)

			local pDist = (rec.lap - 1) * totalLen + st
			if pDist > leadPlayerDist then
				leadPlayerDist = pDist
			end

			-- FTUE Start Straight Arch Check ("one straight with rings -> cross the finish arch = I can fly moment")
			if not rec.ftueCleared and (st >= 295 and st <= 650) then
				rec.ftueCleared = true
				player:SetAttribute("FTUECleared", true)
				if raceEventRemote then
					raceEventRemote:FireClient(player, "FTUEArchCleared", {
						elapsed = now - rec.spawnTime,
					})
				end
			end

				-- Checkpoints evaluation (supports main cavern and Alt1/Alt2 branches; enforces forward route progression)
				local isForwardMove = (st >= prevStation - 45) or (prevStation > totalLen - 450 and st < 450)
				local racing = raceElapsed >= 0 and not RaceManager.isHub() and not RaceManager.isBattle()
				if racing and not rec.finished and distToSpline < 240 and isForwardMove then
					local _, highestPassed = countPassedCheckpoints(rec.passedCheckpoints)
					local isPlane = rec.plane:GetAttribute("VehicleType") ~= "car"
					local courseDist, inPocket = 0, false
					if isPlane then
						courseDist, inPocket = FlightServer.courseFix(rec)
					end
					for _, cp in ipairs(RaceManager.checkpoints) do
						if not rec.passedCheckpoints[cp.index] then
							local dPos = (rec.hull.Position - cp.part.Position).Magnitude
							local dSt = math.abs(st - cp.station)
							-- A plane gets a gate by station only while on the course (FlightGuideRules.checkpointCounts).
							local counts = if isPlane
								then FlightGuideRules.checkpointCounts(dPos <= FlightGuideRules.CP_GATE, dSt <= 110, courseDist, inPocket)
								else (dPos <= 85 or dSt <= 110)
							if counts and cp.index <= highestPassed + 3 then
								rec.passedCheckpoints[cp.index] = true
								if cp.index > highestPassed then
									highestPassed = cp.index
								end
								if cp.index >= rec.lastCheckpointIdx then
									rec.lastCheckpointIdx = cp.index
									rec.lastCheckpointCF = cp.respawnCF
									player:SetAttribute("Checkpoint", cp.index)
									if raceEventRemote then
										raceEventRemote:FireClient(player, "CheckpointPassed", {
											checkpoint = cp.index,
											totalCheckpoints = totalCP,
											respawnCFrame = cp.respawnCF,
										})
									end
								end
							end
						end
					end

					-- Check Finish Line crossing when gated by checkpoints (requires forward crossing and >=75% ordered checkpoints)
					local passedCount, maxIdx = countPassedCheckpoints(rec.passedCheckpoints)
					local lapElapsed = now - (S().lapStartClocks[player] or RaceManager.raceStartClock)
					-- A lap no legal flight can match is not credited, whatever the position says (L30, L53: the backstop
					-- behind CarServer's displacement check).
					local minLapOk = PlaneGuardRules.lapTimeOk(lapElapsed, totalLen, workspace:GetAttribute("FastLapTest") == true)
					local planeCPMust = S().planeCPMust
					local gatesOk = not isPlane or FlightGuideRules.planeGatesOk(rec.passedCheckpoints, planeCPMust)
					if minLapOk and gatesOk and passedCount >= requiredCP and maxIdx >= math.floor(totalCP * 0.75) then
						local fin = TrackRegistry.finish()
						local finishPos = if fin then fin.pos else LEGACY_FINISH_POS
						local finishRadius = if fin then fin.radius else LEGACY_FINISH_RADIUS
						local nearGate = (rec.hull.Position - finishPos).Magnitude <= finishRadius and (prevStation > totalLen * 0.70 or st < 320)
						local wrappedFinish = (prevStation > totalLen - 320 and st < 320)
						if nearGate or wrappedFinish then
							RaceManager.completePlayerLap(rec, now, totalLen)
						end
					end
				end
		end
	end

	if leadPlayerDist == 0 then
		leadPlayerDist = raceElapsed * PlaneConfig.BASE_SPEED
	end

	if raceElapsed < 0 then
		return -- countdown: the field holds on the grid
	end
	AIRacers.step(dt, leadPlayerDist, raceElapsed, function(bot: AIRacers.BotRacer)
		local rank = #RaceManager.finishOrder + 1
		bot.finishRank = rank
		table.insert(RaceManager.finishOrder, {
			name = bot.name,
			isPlayer = false,
			time = bot.finishTime,
			rank = rank,
			isBoss = bot.isBoss == true, -- the storm dragon's crossing (StormFlowRules.beatDragon)
		})
		print(string.format("[SkyRally][RACE] finish rank=%d name=%s player=false time=%.2f", rank, bot.name, bot.finishTime))
	end)

	S().hudTickAccumulator = S().hudTickAccumulator + dt
	if S().hudTickAccumulator >= 0.15 then
		S().hudTickAccumulator = 0
		local standings = buildStandingsPayload(totalLen)
		RaceAttr.set("TotalRacers", #standings)
		-- Rival sting (client/RivalBubbles): is the solo player's rival ahead of them? nil when there is no rival.
		local rivalName = AIRacers.rivalName()
		local rivalRank: number? = nil
		if rivalName then
			for _, entry in ipairs(standings) do
				if not entry.isPlayer and entry.name == rivalName then
					rivalRank = entry.rank
					break
				end
			end
		end
		for _, entry in ipairs(standings) do
			if entry.isPlayer then
				local p = Players:FindFirstChild(entry.name)
				if p and p:IsA("Player") then
					p:SetAttribute("Rank", entry.rank)
					p:SetAttribute("RivalAhead", if rivalRank then rivalRank < entry.rank else nil)
					p:SetAttribute("RaceElapsed", math.floor(raceElapsed * 10) / 10)
					local ls = S().lapStartClocks[p] or RaceManager.raceStartClock
					p:SetAttribute("LapElapsed", math.floor((now - ls) * 10) / 10)
				end
			end
		end
	end
end

-- FOREST-1 sail-gap ring: the client times the crossing on the shared clock; the server re-checks the same clock (with
-- SailGateRules.SERVER_GRACE_S for the report's trip over the network), so a crossing while a sail covered the ring gives
-- nothing. Every other ring (no SailGateRing attribute) is unchanged.
local function sailGateRefuses(payload: any): boolean
	if type(payload) ~= "table" or type(payload.ringName) ~= "string" then
		return false
	end
	local folder = TrackRegistry.getBoostsFolder()
	local ring = if folder then folder:FindFirstChild(payload.ringName) else nil
	if not ring or ring:GetAttribute("SailGateRing") ~= true then
		return false
	end
	local disc = ring:FindFirstChild(payload.ringName .. "_BoostTriggerDisc")
	local cfg = if disc then SailGateRules.configOf(disc) else nil
	return cfg ~= nil and not SailGateRules.liveWithin(workspace:GetServerTimeNow(), cfg, SailGateRules.SERVER_GRACE_S)
end

-- T1-9 (systems audit v32, MP-4/MP-8): "RingTriggered" / "PadTriggered" are claims. The server keeps its own 20 Hz
-- history of every racer's hull (RemoteGuardRules.record) and pays a claim only when the named trigger exists, that
-- history came within reach of it (3D distance, segments between samples, so a full-speed pass and a wall-driving or
-- climbing line count like the road) and the same trigger was not paid inside RemoteGuardRules.TRIGGER.cooldown.
-- A refused claim only skips the server's bookkeeping (ring count, BoostState, speed floor); the client already boosted.
local guardTrails: { [Player]: RemoteGuardRules.Trail } = {}
local triggerPaidAt: { [Player]: { [string]: number } } = {}
local raceEventLimiter = RemoteGuardRules.newLimiter(RemoteGuardRules.LIMITS.raceEvent)
local lastGuardLog: { [Player]: number } = {}
local function guardLog(player: Player, line: string)
	local now = os.clock()
	if now - (lastGuardLog[player] or -math.huge) < 1 then
		return -- one line per player per second: a spamming client must not flood the log
	end
	lastGuardLog[player] = now
	print(string.format("%suser=%d %s", RemoteGuardRules.LOG, player.UserId, line))
end

local function sampleGuardTrails()
	local now = os.clock()
	for player, rec in pairs(FlightServer.records) do
		local hull = rec.hull
		if hull and hull.Parent then
			local tr = guardTrails[player]
			if not tr then
				tr = RemoteGuardRules.newTrail()
				guardTrails[player] = tr
			end
			RemoteGuardRules.record(tr :: RemoteGuardRules.Trail, now, hull.Position)
		end
	end
end

-- Every trigger part of this type the name can mean: the map's BoostsAndPods child of that name (the part itself or
-- inside its model), any tagged trigger named so or inside a model named so (every loaded map, so per group the
-- racer's own zone is among them), and on an untagged legacy map a recursive find under the map root.
local function triggerCandidates(name: string, triggerType: string): { BasePart }
	local out: { BasePart } = {}
	local seen: { [Instance]: boolean } = {}
	local function consider(inst: Instance)
		if not seen[inst] and inst:IsA("BasePart") and inst:GetAttribute("TriggerType") == triggerType then
			seen[inst] = true
			table.insert(out, inst)
		end
	end
	local boosts = TrackRegistry.getBoostsFolder()
	if boosts then
		for _, child in boosts:GetChildren() do
			if child.Name == name then
				consider(child)
				for _, d in child:GetDescendants() do
					consider(d)
				end
			end
		end
	end
	for _, inst in game:GetService("CollectionService"):GetTagged(TriggerRules.TAG) do
		local parent = inst.Parent
		if inst.Name == name or (parent and parent.Name == name) then
			consider(inst)
		end
	end
	if #out == 0 then
		local root = TrackRegistry.getRoot()
		local found = if root then root:FindFirstChild(name, true) else nil
		if found then
			consider(found)
			for _, d in found:GetDescendants() do
				consider(d)
			end
		end
	end
	return out
end

-- True when the claim is paid; logs an [ANTICHEAT] line otherwise.
local function triggerClaimOk(player: Player, rec: FlightServer.PlayerFlightRecord, eventType: string, payload: any): boolean
	local triggerType = RemoteGuardRules.KINDS[eventType]
	local field = if eventType == "RingTriggered" then "ringName" else "padName"
	local name = if type(payload) == "table" then RemoteGuardRules.name(payload[field]) else nil
	if not triggerType or not name then
		guardLog(player, string.format("trigger reject kind=%s reason=bad_payload", RemoteGuardRules.shown(eventType)))
		return false
	end
	local now = os.clock()
	local tr = guardTrails[player]
	if not tr then
		tr = RemoteGuardRules.newTrail()
		guardTrails[player] = tr
	end
	local live = if rec.hull and rec.hull.Parent then rec.hull.Position else nil
	local isRing = eventType == "RingTriggered"
	local best, bestRadius = math.huge, if isRing then RemoteGuardRules.TRIGGER.ringRadius else RemoteGuardRules.TRIGGER.padRadius
	local candidates = triggerCandidates(name, triggerType)
	for _, part in candidates do
		local radius = if isRing then RemoteGuardRules.TRIGGER.ringRadius else RemoteGuardRules.TRIGGER.padRadius
		local lift = part:GetAttribute("PickupLift")
		if not isRing and RemoteGuardRules.finite(lift) then
			radius += math.max(lift :: number, 0)
		end
		local d = RemoteGuardRules.nearest(tr :: RemoteGuardRules.Trail, part.Position, live, now) - radius
		if d < best then
			best, bestRadius = d, radius
		end
	end
	local okPing, ping = pcall(function(): number
		return player:GetNetworkPing()
	end)
	local paid = triggerPaidAt[player]
	if not paid then
		paid = {}
		triggerPaidAt[player] = paid
	end
	local key = triggerType .. ":" .. name
	local distance = if best == math.huge then nil else best + bestRadius
	local ok, why = RemoteGuardRules.triggerVerdict({
		found = #candidates > 0,
		distance = distance,
		radius = bestRadius,
		ping = if okPing then ping else nil,
		lastAt = (paid :: { [string]: number })[key],
		now = now,
	})
	if not ok then
		if why ~= "cooldown" then
			guardLog(player, string.format("trigger reject kind=%s name=%s reason=%s dist=%s reach=%.0f", triggerType, name, why,
				if distance then string.format("%.0f", distance) else "none", RemoteGuardRules.reach(bestRadius, if okPing then ping else nil)))
		end
		return false
	end
	(paid :: { [string]: number })[key] = now
	return true
end

function RaceManager.init()
	RaceManager.loadCheckpoints()
	AIRacers.spawnBots()
	RaceManager.raceStartClock = os.clock()

	local remotesFolder = ReplicatedStorage:WaitForChild("SkyRallyRemotes", 10)
	if remotesFolder then
		raceEventRemote = remotesFolder:WaitForChild("RaceEventRemote", 5) :: RemoteEvent?
	end

	if raceEventRemote then
		local function onRaceEvent(player: Player, eventType: string, payload: any)
			local rec = FlightServer.records[player]
			if not rec then
				return
			end
			if eventType == "RingTriggered" and sailGateRefuses(payload) then
				return
			elseif eventType == "RingTriggered" or eventType == "PadTriggered" then
				if not triggerClaimOk(player, rec, eventType, payload) then
					return
				end
				if not rec.finished and not RaceManager.isHub() then
					S().ringCounts[player] = math.min((S().ringCounts[player] or 0) + 1, RING_COUNT_CAP)
				end
				local overcharged = type(payload) == "table" and payload.overcharged == true
				local newSpeed = if overcharged then PlaneConfig.OVERCHARGE_SPEED else PlaneConfig.BOOST_SPEED
				rec.speed = math.max(rec.speed, newSpeed)
				rec.plane:SetAttribute("BoostState", if overcharged then "Overcharge" else "Standard")
				rec.plane:SetAttribute("Speed", rec.speed)
				player:SetAttribute("Speed", rec.speed)
			elseif eventType == "GeyserTriggered" then
				-- DINO-4 Alt1 updraft (server/VolcanoVents): the standard boost, only inside an active column.
				if not rec.finished and not RaceManager.isHub() and VolcanoVents.onTriggered(player, rec.hull.Position, payload, nil, rec.speed) then
					rec.speed = math.max(rec.speed, PlaneConfig.BOOST_SPEED)
					rec.plane:SetAttribute("BoostState", "Standard")
					rec.plane:SetAttribute("Speed", rec.speed)
					player:SetAttribute("Speed", rec.speed)
				end
			elseif eventType == "PickupCollected" and type(payload) == "table" then
				RaceManager.handlePickup(player, rec, payload.podName)
			end
		end
		raceEventRemote.OnServerEvent:Connect(function(player: Player, eventType: any, payload: any)
			if type(eventType) ~= "string" or not raceEventLimiter.allow(player, os.clock()) then
				return
			end
			-- Per group the event belongs to the sender's race (his RaceScope); a plain call on the single-race path.
			RaceScope.run(RaceScope.instanceOf(player), onRaceEvent, player, eventType, payload)
		end)
	end

	-- Bots and players take pods through ItemService.pickup; one handler hides the pod for everyone.
	ItemService.setPodTakenHandler(function(podName: string, _racerId: string)
		local pod = findPod(podName)
		if pod then
			RaceManager.startPodCooldown(pod)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastPickupRejectLog[player] = nil
		guardTrails[player] = nil
		triggerPaidAt[player] = nil
		lastGuardLog[player] = nil
		raceEventLimiter.forget(player)
		VolcanoVents.forget(player)
		stationAttrAt[player] = nil
		-- Every race's copy (one on the single-race path; one per instance per group).
		RaceScope.each("RaceManager", function(_id: number, st: RaceState)
			st.ringCounts[player] = nil
			-- Grid order: a leaver's result leaves with him (a rejoin starts fresh; quitting never buys a front seat).
			st.gridHistory[player.UserId] = nil
			st.raceGrid[player.UserId] = nil
		end)
		-- Leaving mid-race awards nothing: awards happen only inside completePlayerLap (L22).
	end)

	FlightServer.onPlayAgainRequested = function(_player: Player)
		RaceManager.resetRaceForAll()
	end

	RunService.Heartbeat:Connect(function(dt: number)
		sampleGuardTrails()
		if not RaceFlowRules.PER_GROUP then
			stepRace(dt)
			return
		end
		RaceManager.stepAll(dt)
	end)
end

-- Per group (phase 2b): the hub scope (free roam, players in no instance), then every live RaceInstance in its own
-- scope. The QA triggers (workspace TriggerRaceReset / TriggerSimulateFinish) act on every live instance.
function RaceManager.stepAll(dt: number)
	local resetAll = workspace:GetAttribute("TriggerRaceReset") == true
	local simAll = workspace:GetAttribute("TriggerSimulateFinish") == true
	if resetAll then
		workspace:SetAttribute("TriggerRaceReset", false)
	end
	if simAll then
		workspace:SetAttribute("TriggerSimulateFinish", false)
	end
	local ok, err = pcall(function()
		stepRace(dt)
	end)
	if not ok then
		warn("[SkyRally][RACE] hub step error " .. tostring(err))
	end
	for _, id in RaceScope.liveIds() do
		local okI, errI = pcall(RaceScope.run, id, function()
			if resetAll then
				RaceManager.resetRaceForAll()
			end
			if simAll and not RaceManager.isBattle() and not RaceManager.suspended then
				local _, totalLen = SplineUtils.loadWaypoints()
				simulateFinish(os.clock(), totalLen)
			end
			stepRace(dt)
		end)
		if not okI then
			warn(string.format("[SkyRally][RACE] instance %d step error %s", id, tostring(errI)))
		end
	end
end

return RaceManager
