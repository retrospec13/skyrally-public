--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Boot timeline (perf pass 2026-10-19): "[SkyRally][BOOT] phase=... t=..." from here on (server/BootClock).
require(script.BootLog).attach() -- Studio QA: bounded boot-line ring (tools/map_boot_check.py reads workspace BootLog)
-- Error, memory and heartbeat telemetry (audit T1-4; server/ErrorReporter): up before any other module so their errors
-- are counted; guarded so a reporter fault never stops the boot.
do
	local okReporter, errReporter = pcall(function()
		require(script.ErrorReporter).init()
	end)
	if not okReporter then
		warn("[SkyRally][ERR] reporter failed to start: " .. tostring(errReporter))
	end
end
local BootClock = require(script.BootClock)
BootClock.mark("start", string.format("gameTime=%.2f", time()))
-- Studio QA: the server's longest frames during the first 15 s (a stalled server holds replication to joiners too).
if game:GetService("RunService"):IsStudio() then
	local frames: { string } = {}
	local hb: RBXScriptConnection
	hb = game:GetService("RunService").Heartbeat:Connect(function(dt: number)
		if dt > 0.2 then
			table.insert(frames, string.format("%.2f@%.2f", dt, BootClock.now()))
			workspace:SetAttribute("BootServerStalls", table.concat(frames, " "))
		end
		if BootClock.now() > 15 then
			hb:Disconnect()
		end
	end)
end
-- The first joiner and the moment its vehicle is mounted (the loading screen's "vehicle" milestone).
do
	local function watch(player: Player)
		BootClock.mark("first_player", "player=" .. player.Name)
		local conn: RBXScriptConnection? = nil
		local function check()
			if player:GetAttribute("MountedInPlane") == true then
				BootClock.mark("first_vehicle", "player=" .. player.Name)
				if conn then
					conn:Disconnect()
				end
			end
		end
		conn = player:GetAttributeChangedSignal("MountedInPlane"):Connect(check)
		check()
	end
	Players.PlayerAdded:Once(watch)
	local present = Players:GetPlayers()
	if present[1] then
		watch(present[1])
	end
end

-- 00. The race remotes exist before anything else runs. CarController, FlightController and RaceUI wait only 5 s for
-- FlightStateRemote and RaceEventRemote once SkyRallyRemotes appears (CosmeticService makes the folder at once), but
-- FlightServer and CarServer used to create them only after the boot map build (15-70 s in a loaded Studio). A client
-- that joined during the build then never heard CarMounted, RaceReset, CheckpointRespawn or RequestCorrection: its
-- cached respawn frame stayed the hub spawn, so the first respawn in a battle dropped the car at the old hub plaza
-- (-8162, 8028) on another map, into the void (water fixer's Studio run, 2026-10-18). FlightServer.init and
-- CarServer.init reuse these by name.
do
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not remotes then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		remotes = f
	end
	for _, name in { "FlightStateRemote", "RaceEventRemote" } do
		local existing = (remotes :: Instance):FindFirstChild(name)
		if not (existing and existing:IsA("RemoteEvent")) then
			local r = Instance.new("RemoteEvent")
			r.Name = name
			r.Parent = remotes
		end
	end
end
-- REMARKABLE 28: Shared Curtain Kart relay (CurtainKartPos remote -> CKPos/CKState/CKBest player attributes). Before the
-- boot build, so players already race each other on the first curtain; it never touches the load itself.
require(script.CurtainKartRelay).init()
-- Opponent pose stream (Shared.RacerStreamRules): bots and boss hazards reach the clients as stamped 60 Hz poses.
require(script.RacerStream).init()

-- 0. Saves first (LAUNCH_PROGRESSION section 5): profiles start loading while the map builds, so a player's tokens and
-- best times are in place before the first finish can award anything. Studio without DataStore API access uses the
-- in-memory mock (SaveService logs the backend); a live load failure shows the error state, never a fresh profile.
local SaveService = require(script.SaveService)
SaveService.init()
-- First-session funnels and the saved "onboarded" flag (L27, audit M3): before the boot map build, so a player who joins
-- during it is counted from the moment the profile loads. The race hooks are wired below, next to RaceManager.economy.
local Funnels = require(script.Funnels)
Funnels.init()
-- Economy (MONETIZATION_PROPOSAL; D16/D18): Gears, Garage requests, receipts. MonetizationConfig.Enabled is on for
-- private testing (owner order 2026-10-20); Robux ids bind from the owner's universe at start (server/StoreBinder).
local Economy = require(script.Economy)
Economy.init()
-- Garage cosmetics in the world: liveries repainted on equip, horns relayed to every client (trails and finish
-- emotes are client-side reads of the replicated loadout).
require(script.CosmeticService).init()
-- Seated bot pilots (server/kit/PilotSeat): build the HumanoidDescription presets while the map builds, so the first
-- race's bots are seated as they spawn instead of after the catalog items load.
task.spawn(require(script.kit.PilotSeat).preload)
-- Player settings (audit H13): SettingsEvent relay into the profile's non-progression settings table (validated,
-- rate-limited), and the saved values published as player attributes on load.
require(script.SettingsService).init()
-- Economy v3 phase 4: the pool of bot usernames checked to be nobody's account fills in the background from boot, so the
-- first race has vouched names (an empty pool never blocks a race; AIRacers rechecks a fallback name).
do
	local okPool, errPool = pcall(function()
		require(script.BotNamePool).start()
	end)
	if not okPool then
		warn("[SkyRally][NAMES] pool did not start: " .. tostring(errPool))
	end
end
-- Vehicle exhaust art (client/Vfx layered flame): the server loads the flame and shock-ring meshes once into
-- ReplicatedStorage (clients cannot LoadAsset). Threaded, so it never delays the boot build.
require(script.kit.FxTemplates).init()
BootClock.mark("services")

-- 1. Build the first map through the 30MAPS pipeline (TRACK_PIPELINE P3/P4) via the track director (L4): the compiled
-- builder under ServerScriptService.Maps places the art; MapAdapter waits for it, then builds shells, deck, gameplay,
-- meshes, fx, the corridor and the waypoint data, and registers the track. Launch boots into the hub (HUB-0, hub mode);
-- QA: an ActiveTrackKey workspace attribute set in the Edit DataModel boots straight into that track's race.
local TrackDirector = require(script.TrackDirector)
local qaKey = workspace:GetAttribute("ActiveTrackKey") :: string?
local BOOT_KEY = qaKey or TrackDirector.HUB_KEY
-- QA: ActiveTrackMode (Edit attribute) picks the mode for that boot, e.g. "boss" for a boss race.
-- The hub key with a mode (hub0 + boss: the final boss on the hub loop) boots that mode; the hub key alone stays the hub.
local qaMode = workspace:GetAttribute("ActiveTrackMode") :: string?
BootClock.mark("map_load_start", "key=" .. tostring(BOOT_KEY))
TrackDirector.qaBoot = qaKey ~= nil
TrackDirector.load(BOOT_KEY, if qaKey and (qaKey ~= TrackDirector.HUB_KEY or qaMode) then (qaMode or "race") else nil)
BootClock.mark("map_loaded", "map=" .. tostring(TrackDirector.currentId))
print(string.format("[SkyRally][BOOT] map %s mode=%s", tostring(TrackDirector.currentId), tostring(workspace:GetAttribute("RaceMode"))))

-- Enforce 8 players max per server at runtime as well as place settings
Players.CharacterAutoLoads = true

-- 2. Initialize Flight, Race Loop, AI Bots, Items and SelfTest
local FlightServer = require(script.FlightServer)
local RaceManager = require(script.RaceManager)
local ItemService = require(script.ItemService)
local ItemEffects = require(script.kit.ItemEffects)
local SelfTest = require(script.SelfTest)

-- Car tracks spawn cars through the same records (CarServer wraps FlightServer.spawnOrResetPlane).
local CarServer = require(script.CarServer)
CarServer.init()
FlightServer.init()
RaceManager.init()
-- Items (L07): ItemService owns who holds what and validates every pickup/use; ItemEffects is what a fired item does
-- (projectiles, traps, shield, boost, magnet) and needs the race order from RaceManager to find "the racer ahead".
local itemEffects = ItemEffects.start(RaceManager.racerOrder)
ItemService.start(itemEffects.hooks)
-- Economy v3 phase 2b (docs/design/PER_GROUP_RACES.md): per group each RaceInstance gets its own item ledger and
-- effects engine (server/RaceGroups.scopeApi over shared/RaceScope). Not called while RaceFlowRules.PER_GROUP is false.
local PerGroupFlow = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceFlowRules"))
if PerGroupFlow.PER_GROUP then
	local RaceGroups = require(script.RaceGroups)
	-- Clients compare their own read of the flag (the Studio QA switch is read once per DataModel) with this one.
	workspace:SetAttribute("PerGroupLive", true)
	print(string.format("[SkyRally][GROUPS] per-group races ON (%s)", if PerGroupFlow.QA_PER_GROUP then "Studio QA switch QAPerGroup" else "source"))
	local scopeApi = RaceGroups.scopeApi()
	ItemEffects.enableScopes(scopeApi, RaceManager.racerOrder)
	ItemService.enableScopes(scopeApi, function(): any
		local effects = ItemEffects.active
		return if effects then effects.hooks else itemEffects.hooks
	end)
end
SelfTest.init()
-- REMARKABLE item 23: photo finish, server half (reads RaceManager.finishOrder, sends "PhotoFinish" to close finishers).
require(script.PhotoFinish).init()
BootClock.mark("systems")

-- 3. Track director hooks: switching maps reuses the same systems (no second init).
local AIRacers = require(script.AIRacers)
-- Grid order (docs/design/GRID_ORDER.md): a joiner's seat choice sees which grid slots the bots hold.
FlightServer.botSlots = AIRacers.heldSlots
local BossRace = require(script.BossRace)
local CoinChallenge = require(script.CoinChallenge)
local KeyPickup = require(script.KeyPickup)
-- REMARKABLE items 13, 21, 22: galleon cannons, retired-boss templates, Lost Squeaky Ducks (server/WorldSetPieces).
local WorldSetPieces = require(script.WorldSetPieces)
local VolcanoVents = require(script.VolcanoVents) -- DINO-4 Alt1 geyser updrafts (TRACK_VARIETY 5a)
-- Per group (systems audit v32 T0-2, shared/ModeScopeRules) every system below keeps one state per RaceScope scope and
-- startMode runs inside the scope it is for (RaceGroups calls it in the group's scope): records are that race's
-- (RaceScope.filter: the same table on the single path), hits go to that race's item engine (ItemEffects.active per
-- scope; the started engine on the single path).
local ModeRaceScope = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceScope"))
local function scopedRecords(): { [Player]: any }
	return ModeRaceScope.filter(FlightServer.records :: any)
end
local function scopedEffects(): any
	if ModeRaceScope.enabled() then
		return ItemEffects.active or itemEffects
	end
	return itemEffects
end

WorldSetPieces.init({
	records = scopedRecords,
	isCar = CarServer.isCar,
	activeVehicle = CarServer.activeVehicle,
	expectLaunch = CarServer.expectLaunch,
})
local BattleCore = require(script.battle.BattleCore)
local StormCup = require(script.StormCup)
local TrackRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TrackRegistry"))

-- Per-mode systems after every load and every replay: boss hazards (hits go through the item system, so shields
-- block them), the coin challenge's coins, the battle overlay (server/battle) and the track's hidden key.
local function startMode(mode: string, td: any)
	BossRace.stop()
	CoinChallenge.stop()
	KeyPickup.stop()
	WorldSetPieces.stop() -- REMARKABLE 13/22: cannons disarmed, duck check stopped until start() below
	VolcanoVents.stop()
	BattleCore.stop()
	if not td then
		return
	end
	if mode == "boss" or mode == "rematch" then
		BossRace.start(td.zone, mode == "rematch", {
			hit = function(player: Player, hazard: string, pos: Vector3)
				scopedEffects().hit(ItemService.playerRacerId(player.UserId), ItemService.botRacerId(1), "boss_" .. hazard, 1.3, pos)
			end,
			records = scopedRecords,
			bossHull = function(): BasePart?
				local b = AIRacers.bots[1]
				return if b then b.hull else nil
			end,
			bossStation = function(): number?
				local b = AIRacers.bots[1]
				return if b then b.station else nil
			end,
			-- Respawn protection (G2) as the item engine keeps it, rearm time included.
			immune = function(player: Player): boolean
				return scopedEffects().isImmune(ItemService.playerRacerId(player.UserId))
			end,
		})
	elseif mode == "coin" then
		local root = TrackRegistry.getRoot()
		if root then
			CoinChallenge.start(root, td.coins or {}, td.vehicle, scopedRecords)
		end
	elseif mode == "battle" then
		BattleCore.start(td)
	end
	-- Hidden keys (L70): in a standard race, quick race or time trial on a key track; saved on pickup, never part of
	-- the race result. Any other mode removes the key model (KeyPickup.start returns nil there).
	KeyPickup.start(TrackRegistry.getRoot(), td, mode, CarServer.activeVehicle(), {
		records = scopedRecords,
	})
	-- REMARKABLE items 13, 21, 22 (server/WorldSetPieces): ISLAND-2 cannons (armed in the water battle), this map's
	-- Lost Squeaky Duck, the retired-boss templates when the hub loads.
	WorldSetPieces.start(td, mode)
	VolcanoVents.start(td, mode)
end

-- FLY AGAIN / battle AGAIN: the same mode with a fresh countdown, cancelling the trip back to the hub. Refused in a
-- Storm Cup (a replay would pay the cup's placement table again) and while a cup waits for this race to end.
-- Returns false when refused, so an AGAIN vote falls back to the hub (TrackDirector, L30).
-- T1-5: FLY AGAIN (alone or by vote, and BattleCore's replay) must not restart a mode the live kill switches paused
-- (battles, that map) or a race on a server closing for an update (server/LiveOps sets TrackDirector.liveBlock). nil
-- hook or nothing paused = the replay exactly as before (fail open).
local function liveReplayBlock(): string?
	local live = TrackDirector.liveBlock
	if not live then
		return nil
	end
	local td = TrackDirector.currentTrackData()
	if not td then
		return nil
	end
	return live(td.id, tostring(workspace:GetAttribute("RaceMode")))
end

local function replayCurrent(): boolean
	if workspace:GetAttribute("RaceMode") == StormCup.MODE or StormCup.holdReason() ~= nil then
		return false
	end
	local paused = liveReplayBlock()
	if paused then
		print("[SkyRally][LIVEOPS] replay refused (" .. paused .. "): back to the hub")
		TrackDirector.returnToHub("live: " .. paused)
		return true
	end
	TrackDirector.onReplay()
	RaceManager.resetRaceForAll(workspace:GetServerTimeNow() + TrackDirector.COUNTDOWN + 0.6)
	startMode(tostring(workspace:GetAttribute("RaceMode")), TrackDirector.currentTrackData())
	return true
end

-- Battles (LAUNCH_PROGRESSION 2b): every mode under server/battle/modes registers by kind; the board opens a battle
-- only for a kind that exists. The spawn override seats players on the arena pads at each reset.
BattleCore.init({
	itemEffects = itemEffects,
	-- The calling scope's track (a group's own map per group; the server's current track on the single path).
	trackData = TrackDirector.scopeTrackData,
	replay = function()
		-- Per group a battle in a RaceInstance replays that group only (RaceGroups.replayScope, in its scope); the hub
		-- scope and the single path replay the server's battle as before.
		if ModeRaceScope.enabled() and ModeRaceScope.current() ~= ModeRaceScope.DEFAULT then
			local RaceGroups = require(script.RaceGroups) :: any
			RaceGroups.replayScope()
			return
		end
		if not TrackDirector.switching then
			replayCurrent()
		end
	end,
})
TrackDirector.battleKinds = BattleCore.kinds()
RaceManager.coinsComplete = CoinChallenge.allCollected
RaceManager.economy = Economy
TrackDirector.funnelHook = Funnels.hook
RaceManager.funnelHook = Funnels.hook

-- Social lane (docs/BADGES.md): AFK detection (45 s without input marks a player AFK: tagged over the vehicle, left out of
-- FLY AGAIN / HUB votes and the portal lobby's group rule, never kicked), the hub leaderboards (OrderedDataStore best times
-- per track and total stars, a physical board in the hub plaza) and Roblox badges (ids unset until the owner creates them).
local AfkService = require(script.AfkService)
local Leaderboards = require(script.Leaderboards)
local HubBoard = require(script.HubBoard)
local BadgeAwards = require(script.BadgeAwards)
AfkService.hullOf = function(player: Player): BasePart?
	local rec = FlightServer.records[player]
	return if rec then rec.hull else nil
end
AfkService.onChange = function()
	TrackDirector.afkChanged()
end
TrackDirector.afkCheck = AfkService.isAfk
TrackDirector.afkTouch = AfkService.touch
AfkService.init()
Leaderboards.init(SaveService.get, SaveService.onLoaded)
HubBoard.start(function()
	local svc = Leaderboards.service()
	return if svc then svc.pages() else {}
end, function(): number
	local svc = Leaderboards.service()
	return if svc then svc.version() else 0
end)
-- T1-10 / T1-4: a really awarded badge shows the client toast (BadgeEarned remote) and logs a progression event; a portal or
-- mode a real award newly opened logs one too. All no-ops while a badge id is nil.
BadgeAwards.onAwarded = function(player: Player, key: string, id: number)
	BadgeAwards.toastHook(player, key, id)
	Funnels.progression("badge", player, { key = key })
end
SaveService.unlockHook = function(player: Player, key: string)
	Funnels.progression("unlock", player, { key = key })
end
BadgeAwards.init(SaveService.get, SaveService.onLoaded)
-- Storm Shards and the Storm vendor (economy v3 phase 5; docs/design/STORM_SHARDS.md): Shards from storm-race finishes
-- only (never multiplied, never sold), the vendor stand in the hub and its remotes.
local StormShards = require(script.StormShards)
StormShards.init(SaveService.service() :: any)
-- Hub PAINT SHOP kiosk (economy v3 section 4): a block-built stand on the plaza whose prompts open the Garage (client/PaintShop).
require(script.PaintShopStand).start()
-- UI v2 Garage: one stripped display copy per vehicle look in ReplicatedStorage.SkyRallyShowroom (the cards' 3D thumbnails).
require(script.ShowroomModels).start()
-- Hub plaza floor bands (visual critic v28 1.18): flat painted slabs on the paving, CanQuery false so no ground ray reads them.
require(script.PlazaBands).start()
-- One hook for all after a real finish's saved award (RaceManager.completePlayerLap); none can change the result.
-- Shards first, so the storm badges below judge the counters this finish just raised (and the dragon flag it set).
RaceManager.finishHook = function(player: Player, info: any, award: any, ctx: any)
	AfkService.touch(player) -- crossing the line is proof of play: the idle clock restarts while the results show
	Leaderboards.onFinish(player, info, award, ctx)
	info.beatDragon = StormShards.onFinish(player, info)
	BadgeAwards.onFinish(player, info)
end
TrackDirector.init({
	suspendRace = function(on: boolean)
		RaceManager.suspended = on
	end,
	onTrackChanged = RaceManager.onTrackChanged,
	despawnBots = function()
		AIRacers.despawnAll()
		-- Battle bots and the battle's item hooks go before the map they fight on does.
		BattleCore.stop()
	end,
	spawnBots = function(_enabled: boolean)
		AIRacers.spawnBots()
	end,
	clearItems = function()
		ItemService.reset()
		itemEffects.clear()
	end,
	resetRace = RaceManager.resetRaceForAll,
	playerRecords = function(): { [Player]: any }
		if PerGroupFlow.PER_GROUP then
			-- Per group the hub step sees only the players in no race (shared/RaceScope, hub scope).
			local RaceScope = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceScope"))
			return RaceScope.filter(FlightServer.records) :: any
		end
		return FlightServer.records :: any
	end,
	allPlayersFinished = RaceManager.allPlayersFinished,
	startMode = startMode,
	prepareMode = StormCup.prepareMode,
	replay = replayCurrent, -- FLY AGAIN, alone or by vote (L30)
	markDnf = RaceManager.markDnf, -- the DNF deadline (L30)
	fieldDone = function(): boolean -- the abandoned-race end (owner 2026-10-20)
		local any = false
		for _, bot in AIRacers.bots do
			any = true
			if not bot.finished then
				return false
			end
		end
		return any
	end,
})
-- Grand Prix (v37, server/GrandPrix): a cup of the unlocked race tracks, solo with the bot field; owns the race end
-- through TrackDirector.grandPrix while one runs.
require(script.GrandPrix).init({
	TrackDirector = TrackDirector,
	RaceManager = RaceManager,
	AIRacers = AIRacers,
	FlightServer = FlightServer,
	SaveService = SaveService,
	Economy = Economy,
})
-- Storm Cup at :00/:30 UTC and the Festival banner attributes (MONETIZATION_PROPOSAL; L54). Studio runs the cup only
-- with workspace.StormCupQA = true. Storm race v2 (StormConfig.RACE_V2 + PER_GROUP; server/StormRace) replaces the
-- whole-server cup launch with the per-group storm race; RACE_V2 without PER_GROUP warns and keeps the cup.
require(script.StormRace).boot(StormCup)
-- Live kill switches and soft shutdown (audit T1-5; server/LiveOps, docs/RUNBOOK.md section 4): after StormCup so its
-- closing hold chains onto the cup's hold. Guarded: if it fails, every feature stays ON (fail open) and the boot goes on.
do
	local okLive, errLive = pcall(function()
		require(script.LiveOps).init()
	end)
	if not okLive then
		warn("[SkyRally][LIVEOPS] init failed (all features ON): " .. tostring(errLive))
	end
end
-- Owner admin (DECISIONS D22): one hard-coded UserId gets the admin panel and /admin commands; every call is re-checked on
-- the server, every grant targets his own profile, and every other player's gates are unchanged (server/AdminService).
require(script.AdminService).init()
-- The boot load ran before these hooks existed: arm the boot mode's systems (QA boss/coin boots) now.
startMode(tostring(workspace:GetAttribute("RaceMode")), TrackDirector.currentTrackData())

-- FLY AGAIN (and the battle results' AGAIN) replays the current mode with a fresh countdown and cancels the trip back
-- to the hub. Solo it acts at once; with 2+ humans it is a vote from a player who is done, rate limited per player
-- (TrackDirector.requestExit, L30/L31): one player's tap never restarts a race the others are still flying.
FlightServer.onPlayAgainRequested = function(player: Player)
	if RaceManager.isHub() or TrackDirector.switching then
		return
	end
	TrackDirector.requestExit(player, "again")
end

-- QA (Studio only): Player attribute QARespawnAt (CFrame) sets the player down there through the normal server respawn
-- path (checkpoint frame, the car validator's expected teleport, respawn shield), so probes can start from a pose.
if game:GetService("RunService"):IsStudio() then
	local function watchQA(player: Player)
		player:GetAttributeChangedSignal("QARespawnAt"):Connect(function()
			local cf = player:GetAttribute("QARespawnAt")
			local rec = FlightServer.records[player]
			if typeof(cf) ~= "CFrame" or not rec then
				return
			end
			player:SetAttribute("QARespawnAt", nil) -- one-shot: consumed whether or not it is accepted
			-- V4-1: refuse a point with no ground under it (it would become the checkpoint and the car would fall forever)
			local rp = RaycastParams.new()
			rp.FilterType = Enum.RaycastFilterType.Exclude
			rp.IgnoreWater = true
			local ex = {}
			local planes = workspace:FindFirstChild("Planes")
			if planes then
				table.insert(ex, planes)
			end
			if player.Character then
				table.insert(ex, player.Character)
			end
			rp.FilterDescendantsInstances = ex
			local QR = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("QASteerRules"))
			local hit = workspace:Raycast(cf.Position + Vector3.new(0, QR.RESPAWN_RAY_UP, 0), Vector3.new(0, -QR.RESPAWN_RAY_LEN, 0), rp)
			if not QR.respawnGroundOk(hit and hit.Position.Y or nil) then
				warn(string.format("[SkyRally][QA] respawn REFUSED for %s: no ground under (%.0f,%.0f,%.0f)", player.Name, cf.X, cf.Y, cf.Z))
				return
			end
			rec.lastCheckpointCF = cf
			if CarServer.isCar(rec.plane) then
				CarServer.expectTeleport(player, cf)
			end
			FlightServer.respawnAtLastCheckpoint(player, false)
			print(string.format("[SkyRally][QA] respawn at (%.0f,%.0f,%.0f) for %s", cf.X, cf.Y, cf.Z, player.Name))
		end)
	end
	Players.PlayerAdded:Connect(watchQA)
	for _, p in Players:GetPlayers() do
		watchQA(p)
	end
end
-- Studio-only QA steering attributes (QAFollowLine / QASteer / QAThrottle, shared/QASteerRules): a live server clears them
-- and keeps clearing them, so a stray attribute can never steer anything outside Studio.
do
	local QASteerRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("QASteerRules"))
	local studio = game:GetService("RunService"):IsStudio()
	if not studio then
		QASteerRules.guard(studio, workspace)
		for _, a in { QASteerRules.FOLLOW_ATTR, QASteerRules.STEER_ATTR, QASteerRules.THROTTLE_ATTR } do
			workspace:GetAttributeChangedSignal(a):Connect(function()
				QASteerRules.guard(studio, workspace)
			end)
		end
	end
end
-- Studio-only QA helpers (give an item, put a bot ahead): nothing is created unless RunService:IsStudio().
require(script.QATools).start({
	ItemService = ItemService,
	AIRacers = AIRacers,
	FlightServer = FlightServer,
})
-- Studio-only QA UTC clock + schedule signature dump (TG-6): inert unless RunService:IsStudio().
require(script.QAClock).start()
-- Studio-only soak harness (audit T1-12, tools/soak.py): inert unless RunService:IsStudio() and workspace.QASoakRun is set.
require(script.QASoak).start({
	TrackDirector = TrackDirector,
})
-- Studio-only two-client QA (TEST_LIST L30-L32): inert unless StudioTestService started this session with
-- { qa = "mp" } (tools/mp_check.py); real client DataModels race on AutoPilot and the result comes back through EndTest.
require(script.QAMultiplayer).start({
	TrackDirector = TrackDirector,
	FlightServer = FlightServer,
	RaceManager = RaceManager,
	CarServer = CarServer,
})

local BuildInfo = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BuildInfo"))
workspace:SetAttribute("BuildCommit", BuildInfo.Commit)
print(string.format("[SkyRally][BUILD] server commit=%s place=%d version=%d", tostring(BuildInfo.Commit), game.PlaceId, game.PlaceVersion))

workspace:SetAttribute("SkyRallyReady", true)
BootClock.mark("ready")
print(string.format("[SkyRally][BOOT] Server initialized on %s (mode %s, field of 8)", tostring(TrackDirector.currentId), tostring(workspace:GetAttribute("RaceMode"))))
