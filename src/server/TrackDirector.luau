--!strict
-- Track director (PLAN L4, LAUNCH_PROGRESSION sections 1-3): one place, one active map at a time.
-- The server boots into HUB-0 in hub mode (no bots, no laps, free driving). A player opens a zone by driving through
-- its portal arch on the plaza or by picking it on the Adventure board; the whole server then switches to that race:
-- curtain up, old map and Terrain cleared, the zone's compiled builder re-run from a fresh clone (a ModuleScript only
-- runs once per require), MapAdapter.build, bots for the field, players respawned on the grid, then a 3-2-1-GO hold.
-- When every player has finished, the server returns to the hub after RETURN_AFTER_FINISH (FLY AGAIN replays instead).
-- Portal gates are Progression.isPortalOpen on the player's saved tokens; Studio may set workspace.UnlockAll for QA.
-- Storm Cup (server/StormCup) switches the server with requestRace(nil, key, ..., "stormcup") on its UTC slot, applies its
-- modifier through Hooks.prepareMode and holds players' new races during its lobby minute (holdRequests).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteGuardRules = require(Shared:WaitForChild("RemoteGuardRules")) -- T1-9: BattleIntroSeen rate limit
local Progression = require(Shared:WaitForChild("Progression"))
local LadderRules = require(Shared:WaitForChild("LadderRules"))
local BattleAccessRules = require(Shared:WaitForChild("BattleAccessRules"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
-- Hub rescue frames and the vehicle exchange pads (trap audit H0-05 and G4: the pure rules, specced under Lune).
local RespawnRules = require(Shared:WaitForChild("RespawnRules"))
-- Portal Plunge (REMARKABLE Batch 2 item 20, trap audit H0-09): an arch counts only when driven THROUGH, then a 1.5 s
-- warp the player can cancel by backing out (shared/PortalRules, specced in tools/tests/portal_spec.luau).
local PortalRules = require(Shared:WaitForChild("PortalRules"))
-- 2+ humans (L16, L19, L28, L30-L32): the DNF deadline, FLY AGAIN / HUB votes, the portal lobby and the return frame
-- at the zone's arch (shared/RaceFlowRules, specced in tools/tests/raceflow_spec.luau).
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
-- Owner admin (DECISIONS D22): the admin's runtime flags (map access bypass, lobby, cup hold) branch at the top of the gates.
local AdminRules = require(Shared:WaitForChild("AdminRules"))
-- Economy v3 phase 3: the portal IS the queue (per-arch OPEN / FILLING / RACING, shared/PortalQueueRules, specced in
-- tools/tests/portal_queue_spec.luau). Per group every arch gathers its own lobby; the single path publishes its one
-- server-wide lobby on the arch labels too (workspace ArchStates).
local PortalQueueRules = require(Shared:WaitForChild("PortalQueueRules"))
-- Economy v3 phase 2: what a load keeps per group (shared/RaceInstanceRules) and the zone a map publishes for the
-- client's zone lighting (server/RaceInstance). Both inert while RaceFlowRules.PER_GROUP is false.
local RaceInstanceRules = require(Shared:WaitForChild("RaceInstanceRules"))
local RaceInstance = require(script.Parent.RaceInstance)
-- Phase 2b: with PER_GROUP true the hub stays loaded and every race request goes to server/RaceGroups (one
-- RaceInstance per group, stepped in its own shared/RaceScope); the race attributes a reader needs come through
-- shared/RaceAttr. Every branch below that uses them is gated on RaceFlowRules.PER_GROUP.
local RaceGroups = require(script.Parent.RaceGroups)
local RaceScope = require(Shared:WaitForChild("RaceScope"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
-- Social lane (server/AfkService, shared/AfkRules): AFK players are not humans the flow waits for.
local AfkRules = require(Shared:WaitForChild("AfkRules"))
local FidelityRules = require(Shared:WaitForChild("FidelityRules"))
local HubBossPads = require(script.Parent.HubBossPads)
local MapAdapter = require(script.Parent.MapAdapter)
-- L42: a map built once on this server is restored on later loads instead of rebuilt (server/MapCache).
local MapCache = require(script.Parent.MapCache)
local MapCacheRules = require(Shared:WaitForChild("MapCacheRules"))
local DirectorFailsafeRules = require(Shared:WaitForChild("DirectorFailsafeRules"))
local Prewarm = require(script.Parent.kit.Prewarm)

local TrackDirector = {}

TrackDirector.HUB_KEY = "hub0"
TrackDirector.COUNTDOWN = 3.6 -- 3, 2, 1 at one second each, GO at 0.6 s before release
TrackDirector.BOSS_INTRO = 3.5 -- extra grid hold in boss races for the intro camera sweep and title card
TrackDirector.RETURN_AFTER_FINISH = 22
TrackDirector.PORTAL_RADIUS = 15 -- no longer the trigger (H0-09): PortalRules.crossed; kept for tools that read it
TrackDirector.FIND_RADIUS = 14
TrackDirector.LOAD_TIMEOUT = DirectorFailsafeRules.LOAD_TIMEOUT -- T1-2 watchdog for one whole load (s)
TrackDirector.currentKey = nil :: string?
TrackDirector.currentId = nil :: string?
TrackDirector.switching = false
-- Storm Cup (server/StormCup): why the hub refuses a player's new race right now (the cup's lobby minute), or nil.
TrackDirector.holdRequests = nil :: (() -> string?)?
-- Owner admin (DECISIONS D22; set by server/AdminService): the admin's runtime flags (AdminRules.Flags), nil for every other
-- player. nil hook (the Lune specs, a server without AdminService) = nobody is admin and every gate below is unchanged.
TrackDirector.adminFlags = nil :: ((Player) -> any)?
-- T1-5 live kill switches (server/LiveOps sets it): why `mode` on track id may not open now (battles or that map paused,
-- or the server closing for an update), nil otherwise. nil hook = every mode as usual (fail open). Never blocks the hub.
TrackDirector.liveBlock = nil :: ((trackId: string, mode: string) -> string?)?
-- L27 / audit M3: analytics funnel events (server/Funnels.hook, set by the boot script; nil in the Lune specs). "pick" is a
-- portal crossing, a lobby opened or a board pick; "next" is FLY AGAIN or HUB. It never throws and never changes the flow.
TrackDirector.funnelHook = nil :: ((event: string, player: Player?, data: any) -> ())?
-- Social lane (set by the boot script from server/AfkService): whether a player is AFK, and a note that a player just acted.
-- An AFK player is left out of the humans the flow waits for (FLY AGAIN / HUB votes, the portal lobby's group rule) until
-- he votes or acts; the DNF deadline for an AFK racer is unchanged. nil (the Lune specs) means nobody is AFK.
TrackDirector.afkCheck = nil :: ((Player) -> boolean)?
TrackDirector.afkTouch = nil :: ((Player) -> ())?
-- os.clock() when every player had finished the current race (the return-to-hub timer started); nil while racing.
-- A due Storm Cup starts from here once the results have shown, instead of waiting for the trip back to the hub.
TrackDirector.allFinishedAt = nil :: number?
-- Studio QA: the boot map came from the ActiveTrackKey Edit attribute (set by the boot script). That race is the lane's
-- own test: a joiner or an idle autopilot never ends it as abandoned. Cleared by the next load.
TrackDirector.qaBoot = false

export type Hooks = {
	suspendRace: (boolean) -> (),
	onTrackChanged: () -> (),
	despawnBots: () -> (),
	spawnBots: (enabled: boolean) -> (),
	clearItems: () -> (),
	resetRace: (goTime: number?) -> (),
	playerRecords: () -> { [Player]: any },
	allPlayersFinished: () -> boolean,
	startMode: (mode: string, td: any) -> (), -- boss hazards, coin challenge; called after every load
	-- Storm Cup modifiers (server/StormCup): after the map is built, before RaceManager and the bots read it.
	prepareMode: ((mode: string, td: any) -> ())?,
	-- FLY AGAIN's replay (the boot script's replayCurrent); false when refused (Storm Cup), so a vote falls back to HUB.
	replay: (() -> boolean)?,
	-- L30: the DNF deadline passed with this player still racing (RaceManager.markDnf: no award, streak kept).
	markDnf: ((Player) -> ())?,
	-- Every bot of the field has finished (false with no bots): with no human still racing, the race is over.
	fieldDone: (() -> boolean)?,
}

local hooks: Hooks? = nil
local keyById: { [string]: string } = {}
local remote: RemoteEvent? = nil
local returnAt: number? = nil
local lastPortalToast: { [Player]: number } = {}
-- REMARKABLE 20 / H0-09: each player's hull at the last hub check (the crossing test needs the path) and a running
-- warp (the portal driven through, the key to load, when the countdown ends).
-- portal-load: hubPrev is each player's crossing watch (PortalRules.watchStep) for the hull it was sampled on.
type PortalWatch = { hull: BasePart, w: PortalRules.Watch }
local hubPrev: { [Player]: PortalWatch } = {}
-- The results card's BATTLE with 2+ humans (BattleAccessRules.cardRoute "hub"): the battle this player asked for, started
-- once the hub has loaded (drainPendingBattles). Server-held so no client timer or second request can lose it (V9).
local pendingBattles: { [Player]: { key: string, at: number } } = {}
local warps: { [Player]: { key: string, cf: CFrame, at: number, zone: string, track: string } } = {}
-- Hub vehicle exchange (G4): os.clock() a player's vehicle first sat on a pad that swaps it, and of his last swap.
local exchangeSince: { [Player]: number } = {}
local exchangeAt: { [Player]: number } = {}
-- L30/L31: with 2+ humans FLY AGAIN and HUB are votes ("again" / "hub") from players who are done, rate limited per
-- player; the DNF deadline (os.clock) runs from the first human finish until everyone is done.
local votes: { [Player]: RaceFlowRules.Choice } = {}
local lastVote: { [Player]: number } = {}
local dnfAt: number? = nil
-- LAUNCH_PROGRESSION section 6, L31/L32: one server-wide lobby at a time (2+ humans). cf is the arch the opener drove
-- through (nil for a board pick); goAt is os.clock(); warped once the opener's plunge was sent.
type Lobby = { opener: Player, key: string, mode: string, track: string, zone: string, cf: CFrame?, goAt: number, warped: boolean, adminHoldLogged: boolean? }
local lobby: Lobby? = nil
-- Economy v3 phase 3 (PER_GROUP true): one lobby per arch, keyed by track id, run on server time. queueCf is the arch
-- a joined player drove through (nil for a JOIN on the board: backing out only counts at the arch), queuePlunged the
-- players whose plunge was sent for the lobby's last WARP_SECONDS.
local queue = PortalQueueRules.new(RaceFlowRules.LOBBY_SECONDS, PlaneConfig.AI_FIELD_SIZE)
local queueCf: { [Player]: CFrame } = {}
local queuePlunged: { [Player]: boolean } = {}
local lastArchStates = ""
-- Owner 2026-10-20: who dropped out of a running race, by UserId (server memory only, never saved). A joiner gets back
-- into that race only within RaceFlowRules.REJOIN_GRACE on this server; otherwise a race nobody else plays ends.
local leftRace: { [number]: { jobId: string, raceId: number?, at: number } } = {}
local JOB_ID = if game.JobId ~= "" then game.JobId else "studio"

local function log(fmt: string, ...: any)
	print("[SkyRally][DIRECTOR] " .. string.format(fmt, ...))
end

local function funnel(event: string, player: Player?, data: any)
	local hook = TrackDirector.funnelHook
	if hook then
		pcall(hook, event, player, data)
	end
end

-- Humans the multiplayer flow counts: everyone present except AFK players who have not voted.
local function humanCount(): number
	local all = Players:GetPlayers()
	local check = TrackDirector.afkCheck
	if not check then
		return #all
	end
	return AfkRules.effectiveHumans(all, check, function(p: any): boolean
		return votes[p] ~= nil
	end)
end

local function noteAction(player: Player)
	local touch = TrackDirector.afkTouch
	if touch then
		touch(player)
	end
end

local function trackDataModule(key: string): ModuleScript?
	local folder = ServerStorage:FindFirstChild("TrackData")
	local m = folder and folder:FindFirstChild(key)
	return if m and m:IsA("ModuleScript") then m else nil
end

-- Every map that wrote terrain on this server (track id -> its MapCacheRules.terrainBox): per group a plan's "Clear"
-- shell op may only clear its own map's box, never the live hub's plaza or another zone (RaceInstanceRules.shellClear).
local terrainWritten: { [string]: RaceInstanceRules.TerrainBox } = {}

-- The build options for a map about to be built or restored: how its "Clear" shell op runs and the box it may clear.
local function buildOptions(td: any, perGroup: boolean): MapAdapter.Options
	local clearBox: RaceInstanceRules.TerrainBox? = MapCacheRules.terrainBox(td.terrainBounds, td.shells, td.waypoints or {})
	local mode = RaceInstanceRules.planShellClear(perGroup, terrainWritten, tostring(td.id), clearBox)
	return { activate = true, shellClear = mode, clearBox = clearBox }
end

local function loadTrackData(key: string): any
	local m = trackDataModule(key)
	return if m then (require :: any)(m) else nil
end

-- Track id ("SNOW-1") -> mounted key ("snow1"), read from the TrackData modules themselves.
local function indexTracks()
	local folder = ServerStorage:FindFirstChild("TrackData")
	if not folder then
		return
	end
	for _, m in folder:GetChildren() do
		if m:IsA("ModuleScript") then
			local ok, td = pcall(require, m)
			if ok and type(td) == "table" and type(td.id) == "string" then
				keyById[td.id] = m.Name
			end
		end
	end
end

function TrackDirector.currentTrackData(): any
	return if TrackDirector.currentKey then loadTrackData(TrackDirector.currentKey) else nil
end

function TrackDirector.keyForId(trackId: string): string?
	return keyById[trackId]
end

-- The TrackData of the race the calling thread runs in (systems audit v32 T0-2): per group a RaceInstance's own track
-- (RaceScope.track), else the server's current track (currentTrackData: the single path and the hub scope, unchanged).
-- The mode systems read it (BattleCore's arena seats and its replay).
function TrackDirector.scopeTrackData(): any
	local trackId = RaceScope.track()
	local key = if trackId then keyById[trackId] else nil
	if key then
		return loadTrackData(key)
	end
	return TrackDirector.currentTrackData()
end

local function zoneOfKey(key: string): string?
	local td = loadTrackData(key)
	return if td then td.zone else nil
end

local function profileOf(player: Player): any
	local ok, SaveService = pcall(require, script.Parent.SaveService)
	if not ok then
		return nil
	end
	return (SaveService :: any).get(player)
end

-- D22: the admin's flags, or nil (every other player, or no AdminService).
local function adminOf(player: Player?): any
	local hook = TrackDirector.adminFlags
	if not player or not hook then
		return nil
	end
	return hook(player)
end

-- D22: one kind=admin line when the admin's flags change what the server does for him (and so for everyone switched along).
local function adminLog(player: Player, action: string, detail: string)
	print(string.format("%s action=%s user=%d result=applied %s", AdminRules.LOG, action, player.UserId, detail))
end

local function unlockAll(): boolean
	return RunService:IsStudio() and workspace:GetAttribute("UnlockAll") == true
end

-- Modes the Adventure board offers per track, in order (Progression.MODES minus side modes that are not built yet).
-- "battle" shows only on the four key tracks (Progression.TRACKS[id].hasKey) and opens once the player has finished that
-- map's race (any placing) or found its hidden key (Progression.battleAccess).
-- "quickrace" is the same 3-lap field race on any open track, for fun: it never awards the race token (RaceManager),
-- but keys and best times count (LAUNCH_PROGRESSION section 5).
TrackDirector.BOARD_MODES = { "race", "quickrace", "boss", "coin", "rematch", "timetrial", "battle" }

local LOCK_REASON: { [string]: string } = {
	boss = "win the race first",
	coin = "beat the boss first",
	rematch = "win the coin challenge first",
	timetrial = "open the zone first",
	quickrace = "open the zone first",
	battle = "finish the map first", -- canOpen words it per map: "Finish <map> to unlock"
}

-- Battle kinds the server can run (server/battle/BattleCore.kinds(), set by the boot script). A track whose
-- TrackData has no modes.battle block, or a kind with no mode module yet, keeps its battle locked as "coming soon".
TrackDirector.battleKinds = {} :: { [string]: boolean }

function TrackDirector.hasBattle(td: any): boolean
	local battle = type(td) == "table" and type(td.modes) == "table" and td.modes.battle
	return type(battle) == "table" and type(battle.kind) == "string" and TrackDirector.battleKinds[battle.kind] == true
end

-- Whether `player` may open `mode` (default race) on `key`. Returns a short reason when not.
function TrackDirector.canOpen(player: Player, key: string, mode: string?): (boolean, string)
	local m = mode or "race"
	local td = loadTrackData(key)
	if not td then
		return false, "unknown track"
	end
	if key == TrackDirector.HUB_KEY and m == "hub" then
		return true, "hub"
	end
	if m == "battle" and not TrackDirector.hasBattle(td) then
		return false, "coming soon"
	end
	local live = TrackDirector.liveBlock
	local paused = if live then live(td.id, m) else nil
	if paused then
		return false, paused
	end
	-- D22 owner admin: his runtime map-access bypass opens every mode the map has (a bypass, not a grant: nothing is saved).
	if AdminRules.portalsOpen(adminOf(player)) and Progression.isModeUnlocked({} :: any, td.id, m, true) then
		return true, "admin"
	end
	if unlockAll() then
		return true, "UnlockAll"
	end
	local profile = profileOf(player)
	if not profile then
		-- No profile yet (loading or a save error): only the first zone's race is open.
		return td.zone == "DINO" and m == "race", "no profile"
	end
	if Progression.isModeUnlocked(profile, td.id, m) then
		return true, "open"
	end
	if td.zone == "HUB" then
		return false, "needs all four boss wins"
	end
	if not Progression.isPortalOpen(profile, td.zone) then
		local need = Progression.PORTAL_THRESHOLD[td.zone]
		return false, if need then string.format("needs %d Sky Token%s", need, if need == 1 then "" else "s") else "opens after the final boss"
	end
	if m == "battle" then
		local info = TrackInfo.get(td.id)
		return false, BattleAccessRules.lockReason(if info then info.trackName else tostring(td.id))
	end
	return false, LOCK_REASON[m] or "locked"
end

-- Per-player portal states for the Adventure board, the hub finds and the hidden keys this player already holds,
-- replicated as JSON attributes (PortalStates, HubFindsHeld, KeysHeld) so clients can gate the board and hide
-- collected markers.
local function publishPortalStates(player: Player)
	local HttpService = game:GetService("HttpService")
	local profile = profileOf(player)
	local held = {}
	for _, findId in Progression.HUB_FINDS do
		if profile and profile.tokens and profile.tokens[findId] == true then
			table.insert(held, findId)
		end
	end
	player:SetAttribute("HubFindsHeld", HttpService:JSONEncode(held))
	local keys = {}
	for _, zone in Progression.CHAIN_ZONES do
		if profile and profile.keys and profile.keys[zone] == true then
			table.insert(keys, zone)
		end
	end
	player:SetAttribute("KeysHeld", HttpService:JSONEncode(keys))
	local states: { any } = {}
	local tokensHeld = if profile then Progression.tokenCount(profile) else 0
	for _, trackId in Progression.RACE_TRACKS do
		local key = keyById[trackId]
		if key then
			local ok, why = TrackDirector.canOpen(player, key, "race")
			local modes = {}
			local info = Progression.TRACKS[trackId]
			for _, m in TrackDirector.BOARD_MODES do
				local listed = if m == "boss" or m == "rematch"
					then info ~= nil and info.hasBoss
					elseif m == "battle" then info ~= nil and info.hasKey
					else true
				if listed then
					local mo, mw = TrackDirector.canOpen(player, key, m)
					table.insert(modes, { mode = m, open = mo, why = mw })
				end
			end
			-- Phase 8: the ladder numbers for the locked arch / board (have, need; need nil = opens on the final boss) and the
			-- sources line, so every surface prints the same words (LadderRules).
			local zoneId = zoneOfKey(key) or ""
			local lrow = LadderRules.row(zoneId, tokensHeld, profile ~= nil and profile.finalBoss == true)
			table.insert(states, {
				id = trackId, key = key, zone = zoneId, open = ok, why = why, modes = modes,
				have = lrow.have, need = lrow.need, sources = LadderRules.hintText(lrow),
			})
		end
	end
	-- The final boss on the hub loop, once four boss wins open it.
	local hubKey = keyById["HUB-0"]
	if hubKey then
		local fo, fw = TrackDirector.canOpen(player, hubKey, "boss")
		table.insert(states, { id = "HUB-0", key = hubKey, zone = "HUB", open = fo, why = fw, modes = { { mode = "boss", open = fo, why = fw } } })
	end
	player:SetAttribute("PortalStates", HttpService:JSONEncode(states))
end

local function setCurtain(on: boolean, nextId: string?, nextZone: string?, nextMode: string?, nextBattleKind: string?)
	workspace:SetAttribute("NextTrackId", nextId)
	workspace:SetAttribute("NextZone", nextZone)
	workspace:SetAttribute("NextMode", nextMode)
	workspace:SetAttribute("NextBattleKind", nextBattleKind) -- the curtain names the battle mode (survival, egg, ...)
	workspace:SetAttribute("TrackSwitching", on)
end

-- L30: the vote counts the finish card shows ("AGAIN 1/3"); nil on a solo server and in the hub.
local function publishVotes()
	local present = Players:GetPlayers()
	local humans = humanCount()
	local group = RaceFlowRules.isGroup(humans) and workspace:GetAttribute("RaceMode") ~= "hub"
	local again, hub = RaceFlowRules.tally(votes, present)
	workspace:SetAttribute("VoteHumans", if group then humans else nil)
	workspace:SetAttribute("VotesAgain", if group then again else nil)
	workspace:SetAttribute("VotesHub", if group then hub else nil)
end

local function clearRaceEnd()
	table.clear(votes)
	dnfAt = nil
	workspace:SetAttribute("DnfAt", nil)
	publishVotes()
end

-- Closes the lobby; why (a short reason) tells every client it was cancelled, nil closes it quietly (it went, or the
-- server is switching anyway).
local function closeLobby(why: string?)
	local l = lobby
	if not l then
		return
	end
	lobby = nil
	for _, attr in { "LobbyTrack", "LobbyMode", "LobbyOpener", "LobbyOpenerId", "LobbyGoAt" } do
		workspace:SetAttribute(attr, nil)
	end
	for _, p in Players:GetPlayers() do
		p:SetAttribute("LobbyGuest", nil)
	end
	if why then
		log("lobby %s by %s cancelled (%s)", l.track, l.opener.Name, why)
		if remote then
			remote:FireAllClients("LobbyCancel", { userId = l.opener.UserId, name = l.opener.DisplayName, id = l.track, why = why })
		end
	end
end

-- L19: the return frame in front of the arch of the zone the server just left, on the paving under it (the hub
-- spawn's height when the ray finds nothing close), facing out of the arch. nil for the plaza (first boot, the final
-- boss on the hub loop, a zone with no arch).
local function hubReturnFrame(hub: any, zone: any): CFrame?
	if type(zone) ~= "string" or zone == "HUB" or type(hub) ~= "table" then
		return nil
	end
	for _, portal in hub.portals or {} do
		if tostring(portal.zone) == zone and typeof(portal.cf) == "CFrame" then
			local spawnCf = hub.spawn and hub.spawn.cf
			local groundY = if typeof(spawnCf) == "CFrame" then spawnCf.Y - RaceFlowRules.RETURN_GROUND_LIFT else portal.cf.Y - 11
			local probe = RaceFlowRules.returnFrame(portal.cf, groundY).Position
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			local maps = workspace:FindFirstChild("Maps")
			params.FilterDescendantsInstances = if maps then { maps, workspace.Terrain } else { workspace.Terrain }
			local hit = workspace:Raycast(Vector3.new(probe.X, groundY + 10, probe.Z), Vector3.new(0, -40, 0), params)
			if hit and math.abs(hit.Position.Y - groundY) < 8 then
				groundY = hit.Position.Y
			end
			return RaceFlowRules.returnFrame(portal.cf, groundY)
		end
	end
	return nil
end

-- Sets these hub players down on the plaza (hub scope) on the grid in front of the arch of `zone` (L19), each on a seat
-- no other hub player holds. A group back from its race (RaceGroups hubReturn) and a LEAVE from a portal lobby
-- (economy v3 phase 3: back to the hub apron) both land here.
local function returnToApron(list: { Player }, zone: string?)
	local fs = require(script.Parent.FlightServer) :: any
	local hubTd = TrackDirector.currentTrackData()
	local backAt = if hubTd then hubReturnFrame(hubTd.hub, zone) else nil
	fs.hubReturnCF = backAt
	local used: { [number]: boolean } = {}
	for _, p in Players:GetPlayers() do
		local s = p:GetAttribute("GridSlot")
		if RaceScope.instanceOf(p) == RaceScope.DEFAULT and not table.find(list, p) and type(s) == "number" then
			used[s] = true
		end
	end
	for _, p in list do
		local slot = RaceFlowRules.freeSlot(used)
		used[slot] = true
		p:SetAttribute("GridSlot", slot)
		p:SetAttribute("GridReason", nil)
		local ok, err = pcall(fs.spawnOrResetPlane, p, slot)
		if not ok then
			warn("[SkyRally][GROUPS] hub return failed for " .. p.Name .. ": " .. tostring(err))
		end
		hubPrev[p] = nil -- a set-down is never a drive through an arch
		publishPortalStates(p)
	end
	fs.hubReturnCF = nil
end

-- T1-2: what the guarded load body leaves for the failure path to clean up.
type LoadCtx = { clone: Instance?, builderOk: boolean?, builderErr: string? }

-- The load itself (TrackDirector.load runs it under DirectorFailsafeRules.runGuarded). Returns true when the map is
-- live, or false and a reason when the fresh build is not usable (builder error, MapBuilt never set); a throw or a
-- yield past the watchdog is caught by the caller.
local function loadBody(key: string, mode: string?, td: any, builder: ModuleScript, ctx: LoadCtx, isFallback: boolean?): (boolean, string?, string?)
	HubBossPads.stop() -- M-2: the old map's timed pads end with it
	local h = hooks
	local t0 = os.clock()
	-- Perf pass 2026-10-19: every network template this load will need (art swap meshes and props, ring meshes, item
	-- art, set dressing, both vehicles) starts loading now, in parallel, while the old map goes and the builder runs.
	Prewarm.forTrack(td)
	local first = TrackDirector.currentKey == nil
	if not first then
		TrackDirector.qaBoot = false
	end
	-- L19: the zone being left, so the hub lands the players at its arch.
	local prevZone = workspace:GetAttribute("ActiveZone")
	closeLobby(nil)
	local battleKind = if mode == "battle" and type(td.modes) == "table" and type(td.modes.battle) == "table" then td.modes.battle.kind else nil
	setCurtain(true, td.id, td.zone, mode or (if key == TrackDirector.HUB_KEY then "hub" else "race"), battleKind)
	returnAt = nil
	TrackDirector.allFinishedAt = nil
	workspace:SetAttribute("ReturnToHubAt", nil)
	table.clear(votes)
	dnfAt = nil
	workspace:SetAttribute("DnfAt", nil)
	if not first then
		task.wait(0.7) -- the client curtain fades in before the world disappears under it
	end
	if h then
		h.suspendRace(true)
		h.despawnBots()
		h.clearItems()
	end
	-- Economy v3 phase 2 (sub-step b): per group, the hub and other zones' maps and their Terrain stay (every zone sits
	-- at its own coordinates); only a stale copy of this map goes. Single race (PER_GROUP false): everything, as before.
	local perGroup = RaceFlowRules.PER_GROUP
	local maps = workspace:FindFirstChild("Maps")
	if maps then
		for _, c in maps:GetChildren() do
			if not RaceInstanceRules.keepMap(perGroup, c.Name, key, td.id) then
				c:Destroy()
			end
		end
	end
	if RaceInstanceRules.clearTerrain(perGroup, first) then
		workspace.Terrain:Clear()
		table.clear(terrainWritten)
	end
	workspace:SetAttribute(MapAdapter.readyAttribute(td.id), nil)
	workspace:SetAttribute(MapAdapter.failedAttribute(td.id), nil)
	local buildOpts = buildOptions(td, perGroup)

	-- L42: a map this server built before comes back from MapCache (terrain pasted, parts cloned, MapAdapter.activate);
	-- nil (first visit, Studio MapCacheOff, a failed paste) builds it as before. Everything below runs either way.
	local cached = MapCache.load(key, td)
	local report: MapAdapter.Report
	if cached then
		report = cached
	else
		-- A ModuleScript runs once per require: run a fresh clone so a revisited map builds again.
		local runs = ServerStorage:FindFirstChild("BuilderRuns") or Instance.new("Folder")
		runs.Name = "BuilderRuns"
		runs.Parent = ServerStorage
		local clone = builder:Clone()
		clone.Parent = runs
		ctx.clone = clone
		ctx.builderOk = true
		local readyAttr = MapAdapter.readyAttribute(td.id)
		local failedAttr = MapAdapter.failedAttribute(td.id)
		task.spawn(function()
			local ok, err = pcall(require, clone)
			if not ok then
				ctx.builderOk = false
				ctx.builderErr = tostring(err)
				warn("[SkyRally][DIRECTOR] builder " .. key .. " failed: " .. tostring(err))
				-- T1-2: wakes MapAdapter's MapBuilt wait at once instead of after its 60 s timeout. Its own attribute: every
				-- compiled builder sets MapBuilt_<id> = false when it STARTS, so false there means "building", not "threw".
				if workspace:GetAttribute(readyAttr) ~= true then
					workspace:SetAttribute(failedAttr, true)
				end
			end
		end)
		report = MapAdapter.build(td, buildOpts)
		clone:Destroy()
		ctx.clone = nil
		-- T1-2: a partial build (builder threw, MapBuilt never set) is not raceable and is never cached.
		local usable, why = DirectorFailsafeRules.buildVerdict({ cached = false, builderOk = ctx.builderOk, mapBuilt = report.mapBuilt })
		if not usable and not DirectorFailsafeRules.keepPartial(key, TrackDirector.HUB_KEY, isFallback) then
			return false, why, ctx.builderErr or string.format("%d adapter errors", #(report.errors or {}))
		end
		if usable then
			-- Snapshot now, before the hub finds, keys, coins or set pieces below change the map (no yield in between).
			MapCache.store(key, td, report, TrackDirector.HUB_KEY)
		else
			warn("[SkyRally][DIRECTOR] partial " .. key .. " (" .. tostring(why) .. ") kept live, not cached: no fallback")
		end
	end

	local m = mode or (if key == TrackDirector.HUB_KEY then "hub" else "race")
	TrackDirector.currentKey = key
	TrackDirector.currentId = td.id
	workspace:SetAttribute("ActiveZone", td.zone)
	workspace:SetAttribute("CurrentTrackKey", key)
	workspace:SetAttribute("RaceMode", m)
	-- REMARKABLE 3: the race's lap count for the client's final-lap surge (Music, RaceUI). RaceManager counts laps with
	-- PlaneConfig.TOTAL_LAPS (every plan has laps = 3), so the attribute publishes that same number until laps vary.
	workspace:SetAttribute("TotalLaps", PlaneConfig.TOTAL_LAPS)
	local root = TrackRegistry.getRoot()
	if root and perGroup then
		RaceInstance.publishZone(root, td) -- client/ZoneLighting lights this map for whoever is in it
	end
	local hubSpawn = td.hub and td.hub.spawn and td.hub.spawn.cf
	workspace:SetAttribute("HubSpawnCF", if m == "hub" and typeof(hubSpawn) == "CFrame" then hubSpawn else nil)
	if root and m == "hub" then
		root:SetAttribute("CarOffTrackDrop", 0) -- free driving: the plaza and beaches are far off the loop road
		TrackDirector.buildFindMarkers(root, td.hub)
	end
	-- Final boss on the hub loop: storm lighting from the plan's boss block.
	if m == "boss" and td.zone == "HUB" and td.boss and type(td.boss.lighting) == "string" then
		local LightingProfiles = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LightingProfiles")) :: any
		LightingProfiles.apply(td.boss.lighting)
	end
	if m == "boss" and td.zone == "HUB" then
		HubBossPads.start(td) -- M-2: timed boost pads (td.boss.timedPads) switch on and off by server time
	end
	-- M-5: optional per-track bot pace multiplier (absent = 1.0); AIRacers reads it when it makes a bot.
	workspace:SetAttribute(FidelityRules.BOT_PACE_ATTRIBUTE, td.botPace)
	local prepare: ((string, any) -> ())? = if h then h.prepareMode else nil
	if prepare then
		local okPrep, prepErr = pcall(function(): boolean
			prepare(m, td)
			return true
		end)
		if not okPrep then
			warn("[SkyRally][DIRECTOR] prepareMode " .. m .. " failed: " .. tostring(prepErr))
		end
	end
	if h then
		h.onTrackChanged()
		h.spawnBots(m ~= "hub")
		-- Boss races hold BOSS_INTRO longer on the grid so the client's intro sweep (BossIntro) plays before the 3-2-1.
		local hold = TrackDirector.COUNTDOWN + 1.2 + (if m == "boss" or m == "rematch" then TrackDirector.BOSS_INTRO else 0)
		local goTime = if m == "hub" then nil else workspace:GetServerTimeNow() + hold
		-- L19: back from a zone, the grid forms in front of that zone's arch (FlightServer.getStartCFrame, this reset only).
		local backAt = if m == "hub" then hubReturnFrame(td.hub, prevZone) else nil
		local okF, flightServer = pcall(require, script.Parent.FlightServer)
		local FS: any = if okF then flightServer else nil
		if FS and backAt then
			FS.hubReturnCF = backAt
			log("return grid at the %s arch", tostring(prevZone))
		end
		local resetRace = h.resetRace
		local okReset, resetErr = pcall(function()
			resetRace(goTime)
		end)
		if FS then
			FS.hubReturnCF = nil
		end
		if not okReset then
			warn("[SkyRally][DIRECTOR] resetRace failed: " .. tostring(resetErr))
		end
		h.startMode(m, td)
		h.suspendRace(false)
	end
	for _, p in Players:GetPlayers() do
		publishPortalStates(p)
	end
	publishVotes()
	TrackDirector.switching = false
	setCurtain(false, nil, nil, nil)
	local loadSeconds = os.clock() - t0
	log("load %s (%s) mode=%s ok=%s errors=%d %s in %.1fs", key, tostring(td.id), m, tostring(report.ok), #(report.errors or {}), if cached then "cached" else "built", loadSeconds)
	if DirectorFailsafeRules.overBudget(loadSeconds, cached ~= nil) then
		-- V1 D1: the "[MAP] <id> steps build wait=..." line above says where the time went (wait = the compiled builder).
		warn(string.format("[SkyRally][DIRECTOR] build_budget over key=%s built=%.1fs budget=%ds", key, loadSeconds, DirectorFailsafeRules.BUILD_BUDGET))
	end
	if m == "hub" and next(pendingBattles) ~= nil then
		task.defer(TrackDirector.drainPendingBattles)
	end
	return true, nil, nil
end

-- T1-2: after a failed load, put the server back in a state where portals step and prompts show: no partial map of
-- `key`, no builder clone, the flag and the curtain down, the race loop running. Every step is pcalled: this path must
-- finish whatever the world looks like.
local function releaseAfterFailure(key: string, td: any, ctx: LoadCtx, step: string)
	local function try(what: string, fn: () -> ())
		local ok, err = pcall(function(): boolean
			fn()
			return true
		end)
		if not ok then
			warn("[SkyRally][DIRECTOR] load_fail cleanup " .. what .. ": " .. tostring(err))
		end
	end
	try("clone", function()
		if ctx.clone then
			ctx.clone:Destroy()
			ctx.clone = nil
		end
	end)
	try("partial map", function()
		local maps = workspace:FindFirstChild("Maps")
		if maps and key ~= TrackDirector.HUB_KEY then
			for _, c in maps:GetChildren() do
				if c.Name == key or c.Name == tostring(td.id) then
					c:Destroy()
				end
			end
		end
	end)
	TrackDirector.switching = false
	setCurtain(false, nil, nil, nil)
	if step == "release" then
		-- Nothing to fall back to: let the race loop and the hub portals run on whatever is live.
		local h = hooks
		if h then
			try("suspendRace", function()
				h.suspendRace(false)
			end)
		end
		try("portal states", function()
			for _, p in Players:GetPlayers() do
				publishPortalStates(p)
			end
		end)
	end
end

-- Builds `key` as the only map. Boot calls this with no previous map; a switch clears the old one first. T1-2: the body
-- runs under a watchdog; a builder error, a partial build, a throw or a hang falls back to the hub (or, if the hub itself
-- failed, releases the switching flag and the curtain) with a toast and a "[DIRECTOR] load_fail" log line.
function TrackDirector.load(key: string, mode: string?, isFallback: boolean?): boolean
	if TrackDirector.switching then
		return false
	end
	local td = loadTrackData(key)
	local builder = ServerScriptService:FindFirstChild("Maps") and (ServerScriptService :: any).Maps:FindFirstChild(key)
	if not td or not (builder and builder:IsA("ModuleScript")) then
		warn("[SkyRally][DIRECTOR] no TrackData or builder for " .. tostring(key))
		-- V1 D8: with no map live (boot on an unknown ActiveTrackKey) fall back to the hub instead of staying on map nil.
		local missing = DirectorFailsafeRules.missingStep(key, TrackDirector.HUB_KEY, isFallback, TrackDirector.currentKey ~= nil)
		if missing == "hub" then
			warn("[SkyRally][DIRECTOR] " .. DirectorFailsafeRules.logLine(key, mode, "missing", "no TrackData or builder", 0, missing))
			if remote then
				remote:FireAllClients("LoadFailed", { key = key, id = if td then td.id else nil, reason = "missing", text = DirectorFailsafeRules.toastText(missing) })
			end
			TrackDirector.load(TrackDirector.HUB_KEY, "hub", true)
		end
		return false
	end
	TrackDirector.switching = true
	local ctx: LoadCtx = {}
	local t0 = os.clock()
	local ok, reason, detail = DirectorFailsafeRules.runGuarded(function()
		return loadBody(key, mode, td, builder :: ModuleScript, ctx, isFallback)
	end, {
		spawn = task.spawn,
		cancel = task.cancel,
		clock = os.clock,
		wait = task.wait,
		timeout = TrackDirector.LOAD_TIMEOUT,
	})
	if ok then
		return true
	end
	local step = DirectorFailsafeRules.nextStep(key, TrackDirector.HUB_KEY, isFallback)
	warn("[SkyRally][DIRECTOR] " .. DirectorFailsafeRules.logLine(key, mode, reason, detail, os.clock() - t0, step))
	releaseAfterFailure(key, td, ctx, step)
	if remote then
		remote:FireAllClients("LoadFailed", { key = key, id = td.id, reason = reason, text = DirectorFailsafeRules.toastText(step) })
	end
	if step == "hub" and not TrackDirector.load(TrackDirector.HUB_KEY, "hub", true) and not TrackDirector.switching then
		-- The hub fallback could not even start (no hub TrackData or builder): at least run the race loop again.
		local h = hooks
		if h then
			pcall(h.suspendRace, false)
		end
	end
	return false
end

-- A floating Sky Token over each hub find (shared by every player; each client hides the ones it already holds).
function TrackDirector.buildFindMarkers(root: Instance, hub: any)
	local folder = Instance.new("Folder")
	folder.Name = "HubFinds"
	folder.Parent = root
	for _, find in (hub and hub.finds) or {} do
		if typeof(find.pos) == "Vector3" then
			local m = Instance.new("Model")
			m.Name = find.id
			m:SetAttribute("FindId", find.id)
			m:SetAttribute("SpinRPM", 40)
			m:SetAttribute("SpinAxis", "PivotUpVector")
			local coin = Instance.new("Part")
			coin.Name = "Token"
			coin.Shape = Enum.PartType.Cylinder
			coin.Size = Vector3.new(0.9, 6, 6)
			coin.Material = Enum.Material.Neon
			coin.Color = Color3.fromRGB(255, 206, 64)
			coin.Anchored = true
			coin.CanCollide = false
			coin.CanQuery = false
			coin.CanTouch = false
			-- Cylinder faces point along local X: identity keeps the coin upright, spinning about the world vertical.
			coin.CFrame = CFrame.new(find.pos + Vector3.new(0, 4, 0))
			coin.Parent = m
			local star = Instance.new("Part")
			star.Name = "Inlay"
			star.Shape = Enum.PartType.Cylinder
			star.Size = Vector3.new(1.0, 3.4, 3.4)
			star.Material = Enum.Material.SmoothPlastic
			star.Color = Color3.fromRGB(255, 246, 200)
			star.Anchored = true
			star.CanCollide = false
			star.CanQuery = false
			star.CanTouch = false
			star.CFrame = coin.CFrame
			star.Parent = m
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 214, 120)
			light.Range = 16
			light.Brightness = 1.6
			light.Parent = coin
			m.PrimaryPart = coin
			m.Parent = folder
		end
	end
end

-- Whether a player's new race may start now: the Storm Cup lobby minute holds it, a locked mode refuses it (each with
-- its toast).
local function admit(player: Player, key: string, m: string): boolean
	-- D22: the admin's "hold off" lets his race through the Storm Cup lobby minute.
	local hold = if TrackDirector.holdRequests and not AdminRules.skipsHold(adminOf(player)) then TrackDirector.holdRequests() else nil
	if hold then
		-- Storm Cup lobby: no new race now (the portal check repeats every 0.2 s, so the toast is throttled).
		local now = os.clock()
		if remote and now - (lastPortalToast[player] or 0) > 4 then
			lastPortalToast[player] = now
			remote:FireClient(player, "StormCupHold", { why = hold })
		end
		return false
	end
	local ok, why = TrackDirector.canOpen(player, key, m)
	if not ok then
		if remote then
			local td = loadTrackData(key)
			remote:FireClient(player, "PortalLocked", { key = key, id = if td then td.id else nil, why = why })
		end
		log("request %s by %s refused: %s", key, player.Name, why)
		return false
	end
	-- D22: a start the admin's flags let through (cup hold off, map-access bypass) logs on the kind=admin stream.
	local af = adminOf(player)
	if af then
		local holdActive = AdminRules.skipsHold(af) and TrackDirector.holdRequests ~= nil and TrackDirector.holdRequests() ~= nil
		local what = AdminRules.admitBypass(af, holdActive, why)
		if what then
			adminLog(player, what, string.format("key=%s mode=%s players=%d", key, m, #Players:GetPlayers()))
		end
	end
	return true
end

function TrackDirector.requestRace(player: Player?, key: string, reason: string, mode: string?): boolean
	if TrackDirector.switching then
		return false
	end
	local m = mode or "race"
	if player and not admit(player, key, m) then
		return false
	end
	if RaceFlowRules.PER_GROUP then
		-- Per group: only this player goes (a new instance, or the grid of the one already forming on that track); a
		-- request with no player (a Storm Cup slot) would move the whole server and is not per-group yet.
		if not player then
			log("request %s %s (%s) skipped: per-group races take player requests only", key, m, reason)
			return false
		end
		warps[player] = nil
		return RaceGroups.request({ player }, key, m, reason) ~= "refused"
	end
	log("request %s %s by %s (%s)", key, m, if player then player.Name else "server", reason)
	if player and reason == "board" then
		-- A portal pick was counted at the crossing and a lobby pick when it opened; the board's solo pick is counted here.
		local td = loadTrackData(key)
		funnel("pick", player, { track = if td then td.id else key, mode = m, via = "board" })
	end
	table.clear(warps) -- REMARKABLE 20: the server is switching; every other countdown is moot
	table.clear(hubPrev)
	closeLobby(if reason == "lobby" then nil else "switching") -- a Storm Cup start overrides a running lobby
	task.spawn(TrackDirector.load, key, m)
	return true
end

-- LAUNCH_PROGRESSION section 6 (L31, L32): with 2+ humans a portal crossing or a board pick opens ONE server-wide
-- lobby for LOBBY_SECONDS instead of switching everyone after 1.5 s. Every hub client shows the banner and countdown
-- (workspace LobbyTrack, LobbyMode, LobbyOpener, LobbyGoAt); a player who has not unlocked that track hears up front
-- that it is a guest race (player attribute LobbyGuest). Another request while it runs is refused with a toast.
-- portalCf is the arch driven through (backing out of it cancels), nil for a board pick.
function TrackDirector.openLobby(player: Player, key: string, mode: string?, portalCf: CFrame?): boolean
	if TrackDirector.switching or workspace:GetAttribute("RaceMode") ~= "hub" then
		return false
	end
	local m = mode or "race"
	local td = loadTrackData(key)
	if not td then
		return false
	end
	local l = lobby
	if l then
		if l.opener ~= player and remote then
			local now = os.clock()
			if now - (lastPortalToast[player] or 0) > 2 then
				lastPortalToast[player] = now
				remote:FireClient(player, "LobbyBusy", {
					name = l.opener.DisplayName,
					id = l.track,
					mode = l.mode,
					same = l.key == key and l.mode == m,
					seconds = math.max(0, l.goAt - now),
				})
			end
		end
		return false
	end
	if not admit(player, key, m) then
		return false
	end
	-- D22: the admin's lobby setting (normal / short / skip). skip switches at once, like a solo warp, past the group rule.
	local lobbySeconds = RaceFlowRules.LOBBY_SECONDS
	local af = adminOf(player)
	if af then
		lobbySeconds = AdminRules.lobbySeconds(af.lobby, lobbySeconds)
		if lobbySeconds <= 0 then
			log("lobby %s %s by %s skipped (admin)", tostring(td.id), m, player.Name)
			adminLog(player, "lobbySkip", string.format("track=%s mode=%s players=%d", tostring(td.id), m, #Players:GetPlayers()))
			return TrackDirector.requestRace(player, key, "admin lobby skip", m)
		elseif lobbySeconds < RaceFlowRules.LOBBY_SECONDS then
			adminLog(player, "lobbyShort", string.format("track=%s mode=%s seconds=%d players=%d", tostring(td.id), m, lobbySeconds, #Players:GetPlayers()))
		end
	end
	local now = os.clock()
	lobby = {
		opener = player,
		key = key,
		mode = m,
		track = tostring(td.id),
		zone = tostring(td.zone),
		cf = portalCf,
		goAt = now + lobbySeconds,
		warped = false,
	}
	workspace:SetAttribute("LobbyTrack", td.id)
	workspace:SetAttribute("LobbyMode", m)
	workspace:SetAttribute("LobbyOpener", player.DisplayName)
	workspace:SetAttribute("LobbyOpenerId", player.UserId) -- phase 6: only the opener's pre-race pick strip follows the lobby
	workspace:SetAttribute("LobbyGoAt", workspace:GetServerTimeNow() + lobbySeconds)
	for _, p in Players:GetPlayers() do
		local open = p == player or (TrackDirector.canOpen(p, key, m))
		p:SetAttribute("LobbyGuest", if open then nil else true)
	end
	if remote then
		remote:FireAllClients("LobbyOpen", {
			userId = player.UserId,
			name = player.DisplayName,
			id = td.id,
			zone = tostring(td.zone),
			mode = m,
			seconds = lobbySeconds,
			portal = portalCf ~= nil,
		})
	end
	log("lobby %s %s by %s (%.0f s, %s)", tostring(td.id), m, player.Name, lobbySeconds, if portalCf then "portal" else "board")
	funnel("pick", player, { track = td.id, mode = m, via = if portalCf then "portal" else "board" })
	return true
end

-- One hub step of the lobby: the opener left or backed out of the arch, a Storm Cup hold began (cancel); the opener's
-- plunge for the last WARP_SECONDS; the switch when the countdown ends.
local function stepLobby(now: number, recs: { [Player]: any })
	local l = lobby
	if not l then
		return
	end
	if not l.opener.Parent then
		closeLobby("left")
		return
	end
	if TrackDirector.holdRequests and not AdminRules.skipsHold(adminOf(l.opener)) and TrackDirector.holdRequests() then
		closeLobby("storm cup")
		return
	end
	-- D22: the admin's lobby runs on through the cup lobby minute; logged once per lobby.
	if not l.adminHoldLogged and TrackDirector.holdRequests and adminOf(l.opener) and TrackDirector.holdRequests() then
		l.adminHoldLogged = true
		adminLog(l.opener, "holdBypass", string.format("lobby=%s mode=%s players=%d", l.track, l.mode, #Players:GetPlayers()))
	end
	local rec = recs[l.opener]
	local hull = rec and rec.hull
	if l.cf and hull and hull.Parent and not RaceFlowRules.lobbyHolds(PortalRules.side(hull.Position, l.cf), PortalRules.CANCEL_BACK) then
		closeLobby("backed out")
		return
	end
	if l.cf and not l.warped and now >= l.goAt - PortalRules.WARP_SECONDS then
		l.warped = true
		if remote then
			remote:FireAllClients("PortalWarp", {
				userId = l.opener.UserId,
				name = l.opener.DisplayName,
				id = l.track,
				zone = l.zone,
				seconds = math.max(0.2, l.goAt - now),
			})
		end
	end
	if now >= l.goAt then
		closeLobby(nil)
		if not TrackDirector.requestRace(l.opener, l.key, "lobby", l.mode) and remote then
			remote:FireAllClients("LobbyCancel", { userId = l.opener.UserId, name = l.opener.DisplayName, id = l.track, why = "refused" })
		end
	end
end

-- Economy v3 phase 3: the arch labels and the Adventure board read workspace ArchStates (JSON: track id -> the
-- PortalQueueRules entry, times in server time). Per group: every arch's own lobby and race; single path: the one
-- server-wide lobby on its arch (everyone present goes), every other arch OPEN. Written only when it changes.
local function publishArchStates()
	local now = workspace:GetServerTimeNow()
	local out: { [string]: PortalQueueRules.Entry } = {}
	if RaceFlowRules.PER_GROUP then
		local races = RaceGroups.trackRaces()
		for _, trackId in Progression.RACE_TRACKS do
			local r = races[trackId]
			PortalQueueRules.setRace(queue, trackId, if r then r.state else nil, if r then r.goAt else nil, if r then r.endAt else nil)
		end
		out = PortalQueueRules.snapshot(queue, now)
	else
		local l = lobby
		local goAt = workspace:GetAttribute("LobbyGoAt")
		if l and type(goAt) == "number" then
			out[l.track] = PortalQueueRules.singleEntry(goAt, humanCount(), PlaneConfig.AI_FIELD_SIZE, l.mode)
		end
	end
	local HttpService = game:GetService("HttpService")
	local ok, json = pcall(HttpService.JSONEncode, HttpService, out)
	if ok and json ~= lastArchStates then
		lastArchStates = json
		workspace:SetAttribute("ArchStates", json)
	end
end

local function sendTo(player: Player, event: string, data: any)
	if remote then
		remote:FireClient(player, event, data)
	end
end

-- A player's lobby attributes (his client's "Waiting for racers" line reads ArchStates[LobbyArch]); nil clears them.
local function markQueued(player: Player, trackId: string?, via: string?)
	player:SetAttribute("LobbyArch", trackId)
	player:SetAttribute("LobbyVia", via)
end

-- Phase 3 (PER_GROUP true): a crossing of an open arch (via "portal", cf = that arch) or a pick on the Adventure board
-- (via "board") joins that track's lobby: FILLING opens it or joins it, RACING joins the next one. Nobody else hears
-- about it; the arch label carries the count.
local function queueJoin(player: Player, key: string, mode: string, via: string, cf: CFrame?): string
	local td = loadTrackData(key)
	if not td or not RaceGroups.inHub(player) then
		return "refused"
	end
	if not admit(player, key, mode) then
		return "refused"
	end
	local trackId = tostring(td.id)
	if not RaceInstanceRules.groupModeOk(mode) or trackId == Progression.HUB_TRACK then
		sendTo(player, "PortalLocked", { key = key, id = trackId, why = "coming soon" })
		return "refused"
	end
	local now = workspace:GetServerTimeNow()
	local verdict, moved = PortalQueueRules.join(queue, trackId, player.UserId, mode, via, now)
	if verdict == "full" or verdict == "mode" then
		local held = PortalQueueRules.arch(queue, trackId).lobby
		sendTo(player, "LobbyRefused", { id = trackId, why = verdict, mode = if held then held.mode else mode })
		return verdict
	end
	if verdict == "already" then
		return verdict
	end
	if queuePlunged[player] then
		sendTo(player, "PortalWarpCancel", { userId = player.UserId })
	end
	queuePlunged[player] = nil
	if cf then
		queueCf[player] = cf
	else
		queueCf[player] = nil -- a JOIN on the board: no arch to back out of
	end
	markQueued(player, trackId, via)
	publishArchStates()
	local a = PortalQueueRules.arch(queue, trackId)
	sendTo(player, "LobbyJoined", {
		id = trackId,
		zone = tostring(td.zone),
		mode = mode,
		portal = cf ~= nil,
		queued = verdict == "queued",
		goAt = PortalQueueRules.startAt(a, now),
	})
	log("queue %s %s: %s %s (%s, %d in lobby%s)", trackId, mode, player.Name, verdict, via, PortalQueueRules.count(a), if moved then ", left " .. moved else "")
	return verdict
end

-- Takes a player out of his lobby (LEAVE, backed out of the arch, left the server). toApron: LEAVE from an arch lobby
-- sets him back on the plaza in front of that arch.
local function queueLeave(player: Player, why: string, toApron: boolean)
	local trackId = PortalQueueRules.leave(queue, player.UserId)
	local cf = queueCf[player]
	queueCf[player] = nil
	if queuePlunged[player] then
		sendTo(player, "PortalWarpCancel", { userId = player.UserId })
	end
	queuePlunged[player] = nil
	if not trackId then
		return
	end
	markQueued(player, nil, nil)
	publishArchStates()
	log("queue %s: %s left (%s)", trackId, player.Name, why)
	if not player.Parent then
		return
	end
	sendTo(player, "LobbyLeft", { id = trackId, why = why })
	if toApron and cf and RaceGroups.inHub(player) then
		local key = keyById[trackId]
		returnToApron({ player }, if key then zoneOfKey(key) else nil)
	end
end

-- Storm race v2 (server/StormRace): a player who joins a storm field leaves his portal lobby (one race at a time), quietly
-- and where he stands (no set-down on the apron).
function TrackDirector.leaveQueue(player: Player, why: string)
	if RaceFlowRules.PER_GROUP then
		queueLeave(player, why, false)
	end
end

-- Phase 3, one hub step (5 Hz, PER_GROUP true): the arches' races, a Storm Cup hold (every lobby drops), joined
-- players backing out of their arch, the plunge for the last WARP_SECONDS, and the lobbies that go now. Only the
-- joined players of a lobby leave the hub; the field fills with bots (RaceGroups).
local function stepQueue(recs: { [Player]: any })
	publishArchStates()
	local now = workspace:GetServerTimeNow()
	local byId: { [number]: Player } = {}
	for _, p in Players:GetPlayers() do
		byId[p.UserId] = p
	end
	if TrackDirector.holdRequests and TrackDirector.holdRequests() then
		for trackId, a in queue.arches do
			if a.lobby then
				for _, uid in PortalQueueRules.cancel(queue, trackId) do
					local p = byId[uid]
					if p then
						queueCf[p] = nil
						queuePlunged[p] = nil
						markQueued(p, nil, nil)
						sendTo(p, "LobbyLeft", { id = trackId, why = "storm cup" })
					end
				end
				log("queue %s dropped (storm cup)", trackId)
			end
		end
		publishArchStates()
		return
	end
	for p, cf in queueCf do
		local rec = recs[p]
		local hull = rec and rec.hull
		if p.Parent and hull and hull.Parent and not RaceFlowRules.lobbyHolds(PortalRules.side(hull.Position, cf), PortalRules.CANCEL_BACK) then
			queueLeave(p, "backed out", false)
		end
	end
	for trackId, a in queue.arches do
		local l = a.lobby
		if l and PortalQueueRules.goingIn(a, now, PortalRules.WARP_SECONDS) then
			local key = keyById[trackId]
			local zone = if key then zoneOfKey(key) else nil
			for _, uid in l.order do
				local p = byId[uid]
				if p and queueCf[p] and not queuePlunged[p] then
					queuePlunged[p] = true
					sendTo(p, "PortalWarp", {
						userId = p.UserId,
						name = p.DisplayName,
						id = trackId,
						zone = tostring(zone or ""),
						seconds = math.max(0.2, l.goAt - now),
					})
				end
			end
		end
	end
	for _, d in PortalQueueRules.due(queue, now) do
		local list: { Player } = {}
		for _, uid in d.players do
			local p = byId[uid]
			if p then
				queueCf[p] = nil
				queuePlunged[p] = nil
				markQueued(p, nil, nil)
				if RaceGroups.inHub(p) then
					table.insert(list, p)
				end
			end
		end
		local key = keyById[d.trackId]
		if key and #list > 0 then
			local result = RaceGroups.request(list, key, d.mode, "lobby")
			log("queue %s %s goes with %d player(s): %s", d.trackId, d.mode, #list, result)
			if result == "refused" then
				for _, p in list do
					sendTo(p, "LobbyLeft", { id = d.trackId, why = "refused" })
				end
			end
		end
	end
	publishArchStates()
end

-- D22 owner admin: his solo start ("/admin solo", the panel's START). Instantly from the hub with the bot field, past the
-- group lobby rule; the mode's gates (canOpen) and the cup hold still apply through admit, where his flags branch first.
-- Whole-server engine (PER_GROUP false): the switch takes every hub player along, as any race start does. Per group:
-- RaceGroups starts his own instance. Returns ok and a short reply.
function TrackDirector.adminStart(player: Player, key: string, mode: string): (boolean, string)
	if not adminOf(player) then
		return false, "not available"
	end
	if TrackDirector.switching then
		return false, "a map is loading"
	end
	if RaceAttr.get("RaceMode", player) ~= "hub" then
		return false, "start it from the hub"
	end
	if not loadTrackData(key) then
		return false, "unknown map"
	end
	-- Name the fix when the cup's lobby minute is what would refuse him (his CUP HOLD is still on).
	if TrackDirector.holdRequests and not AdminRules.skipsHold(adminOf(player)) and TrackDirector.holdRequests() then
		return false, "the cup lobby holds races, set CUP HOLD off"
	end
	local ok = TrackDirector.requestRace(player, key, "admin solo", mode)
	return ok, if ok then "starting" else "refused, try again in a moment"
end

-- D22: re-publishes one player's board states and BattlesOpen (the admin toggled his map-access bypass). Writes no save.
function TrackDirector.republish(player: Player)
	publishPortalStates(player)
	local profile = profileOf(player)
	if profile then
		local open = AdminRules.portalsOpen(adminOf(player))
		player:SetAttribute(BattleAccessRules.ATTR, BattleAccessRules.encode(Progression.battleZones(profile, open)))
	end
end

function TrackDirector.returnToHub(reason: string)
	if RaceFlowRules.PER_GROUP then
		return -- per group the hub never switches; each instance returns its own players (RaceGroups.returnToHub)
	end
	-- L16: the final boss runs on the hub map in boss mode; only the hub in hub mode is "already home".
	if TrackDirector.switching or (TrackDirector.currentKey == TrackDirector.HUB_KEY and workspace:GetAttribute("RaceMode") == "hub") then
		return
	end
	log("return to hub (%s)", reason)
	task.spawn(TrackDirector.load, TrackDirector.HUB_KEY, "hub")
end

-- L30: what the votes decide now (expired: the return timer ran out). Every human present voting the same way acts at
-- once; at the timer AGAIN needs more than half of the humans present, otherwise HUB. A refused replay (Storm Cup)
-- goes to the hub. Returns whether anything happened.
local function resolveVotes(expired: boolean): boolean
	local h = hooks
	if not h or TrackDirector.switching or workspace:GetAttribute("RaceMode") == "hub" then
		return false
	end
	local present = Players:GetPlayers()
	local again, hub = RaceFlowRules.tally(votes, present)
	local humans = humanCount()
	local decision = RaceFlowRules.decide(again, hub, humans, expired)
	if not decision then
		return false
	end
	log("exit %s (again %d, hub %d of %d humans%s)", decision, again, hub, humans, if expired then ", timer" else "")
	table.clear(votes)
	publishVotes()
	local replay = h.replay
	if decision == "again" and replay and replay() then
		return true
	end
	TrackDirector.returnToHub(if expired then "all finished" else "vote")
	return true
end

-- FLY AGAIN (choice "again", FlightServer's RequestPlayAgain) and HUB ("hub", this remote) from one player (L30, L31).
-- Solo: exactly the old flow, at once. 2+ humans: a vote from a player who is done (finished, or DNF); a racer still
-- flying is refused with a toast, so one tap never ends a race the others are still in. 1 request/s per player.
function TrackDirector.requestExit(player: Player, choice: RaceFlowRules.Choice): string
	if RaceFlowRules.PER_GROUP then
		noteAction(player)
		return RaceGroups.requestExit(player, choice) -- this player's group only
	end
	local h = hooks
	local mode = workspace:GetAttribute("RaceMode")
	if not h or TrackDirector.switching or mode == "hub" then
		return "refused"
	end
	if choice == "again" then
		pendingBattles[player] = nil -- FLY AGAIN after BATTLE: a later hub trip must not start the battle
	end
	local now = os.clock()
	if now - (lastVote[player] or -math.huge) < RaceFlowRules.VOTE_COOLDOWN then
		return "throttled"
	end
	lastVote[player] = now
	noteAction(player) -- asking to leave or replay is activity: he counts as a human again before the group check below
	if not RaceFlowRules.isGroup(humanCount()) then
		funnel("next", player, { choice = choice })
		if choice == "again" then
			local replay = h.replay
			if replay then
				replay()
			end
		else
			TrackDirector.returnToHub("player " .. player.Name)
		end
		return "done"
	end
	local rec = h.playerRecords()[player]
	local done = rec ~= nil and (rec.finished == true or rec.dnf == true)
	if not RaceFlowRules.canVote(choice, done, if type(mode) == "string" then mode else nil) then
		if remote then
			remote:FireClient(player, "VoteRefused", {
				why = if not done then "Finish first - the others are still racing" else "No replay in a Storm Cup",
			})
		end
		return "refused"
	end
	votes[player] = choice
	funnel("next", player, { choice = choice })
	log("vote %s by %s", choice, player.Name)
	publishVotes()
	resolveVotes(false)
	return "counted"
end

-- The results card's BATTLE (RequestBattle): this map's battle, deterministically (BattleAccessRules.cardRoute). Solo it
-- loads straight from the finished race (no hub trip, no second request); with 2+ humans it casts the HUB vote and the
-- battle waits here until the hub has loaded. canOpen re-checks the unlock either way (admit, with its toast).
function TrackDirector.requestBattle(player: Player, key: string, trackId: string?): string
	local mode = RaceAttr.get("RaceMode", player)
	local route = BattleAccessRules.cardRoute(mode, RaceFlowRules.isGroup(humanCount()), RaceFlowRules.PER_GROUP, TrackDirector.switching)
	log("battle request %s by %s from %s: %s", key, player.Name, tostring(mode), route)
	pendingBattles[player] = nil
	if route == "now" then
		if RaceFlowRules.PER_GROUP then
			queueJoin(player, key, "battle", "board", nil) -- per group: that arch's battle lobby, this player only
		elseif mode == "hub" and RaceFlowRules.isGroup(humanCount()) then
			TrackDirector.openLobby(player, key, "battle", nil)
		else
			TrackDirector.requestRace(player, key, "card", "battle")
		end
	elseif route == "hub" then
		-- Armed before the vote: the last vote can switch to the hub at once.
		pendingBattles[player] = { key = key, at = os.clock() }
		local vote = TrackDirector.requestExit(player, "hub")
		if vote ~= "counted" and vote ~= "done" then
			pendingBattles[player] = nil
		end
	elseif route == "refused" and remote then
		remote:FireClient(player, "PortalLocked", { key = key, id = trackId, why = "pick BATTLE on the Adventure board" })
	end
	return route
end

-- After a hub load: the first pending card BATTLE still in time opens its battle (the board's lobby path with 2+ humans).
function TrackDirector.drainPendingBattles()
	local now = os.clock()
	local list = pendingBattles
	pendingBattles = {}
	for player, pb in list do
		if player.Parent and BattleAccessRules.pendingStep(pb.at, now, "hub") == "go" and RaceAttr.get("RaceMode", player) == "hub" then
			log("battle pending %s by %s: open", pb.key, player.Name)
			local ok = if RaceFlowRules.isGroup(humanCount())
				then TrackDirector.openLobby(player, pb.key, "battle", nil)
				else TrackDirector.requestRace(player, pb.key, "card", "battle")
			if ok then
				return
			end
		end
	end
end

-- Social lane: a player went AFK or came back (server/AfkService.onChange). The vote counts the finish card shows are
-- recounted, and during the return timer the humans left may now all agree, so the votes are resolved again.
function TrackDirector.afkChanged()
	publishVotes()
	if returnAt ~= nil then
		resolveVotes(false)
	end
end

-- Hub rescue frame (trap audit H0-05): free roam never passes a checkpoint, so a drown, a fall or a manual respawn
-- used to land on the plaza, up to 900 studs from the crash. CarServer's RequestRespawn asks here instead: the nearest
-- of the plan's hub.respawns anchors and the route frame under the car (within RespawnRules.HUB_ROUTE_REACH), by
-- horizontal distance. Returns the frame and its name, or nil outside the hub (the caller keeps its checkpoint).
-- reason "Stuck" (the client's watchdog): the rescue keeps RespawnRules.HUB_STUCK_CLEAR from the stuck car, and a car
-- stuck on the route is set down HUB_STUCK_ADVANCE further along it (never back on the same kerb).
function TrackDirector.hubRespawnFrame(pos: Vector3, reason: string?): (CFrame?, string?)
	if RaceAttr.here("RaceMode") ~= "hub" then
		return nil, nil
	end
	local td = TrackDirector.currentTrackData()
	local hub = td and td.hub
	if not hub then
		return nil, nil
	end
	local anchors: { RespawnRules.Anchor } = {}
	for _, a in hub.respawns or {} do
		if typeof(a.cf) == "CFrame" then
			table.insert(anchors, { cf = a.cf, name = if type(a.name) == "string" then a.name else nil })
		end
	end
	if #anchors == 0 and hub.spawn and typeof(hub.spawn.cf) == "CFrame" then
		table.insert(anchors, { cf = hub.spawn.cf, name = "Plaza" })
	end
	local wps = SplineUtils.loadWaypoints()
	local point: Vector3? = nil
	local tangent: Vector3? = nil
	if #wps >= 2 then
		local station, p, t = SplineUtils.projectPosition(pos)
		point, tangent = p, t
		local advance = RespawnRules.stuckRouteAdvance(reason, Vector3.new(pos.X - p.X, 0, pos.Z - p.Z).Magnitude)
		if advance > 0 then
			local ap, at = SplineUtils.sampleAtStation(station + advance)
			point, tangent = ap, at
		end
	end
	return RespawnRules.pickHubFrame(pos, anchors, point, tangent, RespawnRules.hubClear(reason))
end

local function vehicleOf(rec: any): string
	return if rec.plane and rec.plane:GetAttribute("VehicleType") == "car" then "car" else "plane"
end

-- Hub vehicle exchange (trap audit H0-01, H0-02, G4): driving onto the glowing PLANE pad swaps that player's car for a
-- plane (climbing out of the bay), flying low over the CAR pad swaps it back. Server-authoritative and per player:
-- the hub's own vehicle (CarServer.activeVehicle) does not change, so every reset path (the next map load, the hub
-- reload, a ForceVehicle switch) puts the player back in the hub default through CarServer's spawn wrapper. The new
-- vehicle spawns through the normal spawn functions with FlightServer.startOverride briefly answering the pad frame,
-- so the record, the validator's expected teleport, the client's CarMounted / PlaneMounted frame and the cached
-- checkpoint all name the pad. Clients get RaceEventRemote "VehicleExchange" for the pop (FlightController).
function TrackDirector.exchangeVehicle(player: Player, pad: RespawnRules.Pad): boolean
	local okC, carServer = pcall(require, script.Parent.CarServer)
	local okF, flightServer = pcall(require, script.Parent.FlightServer)
	if not okC or not okF then
		return false
	end
	local CarServer = carServer :: any
	local FlightServer = flightServer :: any
	local rec = FlightServer.records[player]
	if not rec then
		return false
	end
	local from = vehicleOf(rec)
	local cf = RespawnRules.exchangeFrame(pad)
	local slot = CarServer.slots[player] or 1
	local prevOverride = FlightServer.startOverride
	FlightServer.startOverride = function(i: number): CFrame?
		if i == slot then
			return cf
		end
		return if prevOverride then prevOverride(i) else nil
	end
	local ok, err = pcall(function()
		if pad.vehicle == "car" then
			-- Plane -> car: spawnOrResetCar drops the plane and builds the car itself.
			CarServer.spawnOrResetCar(player, slot)
		else
			-- Car -> plane: the same switch CarServer's spawn wrapper makes when a track changes car -> plane (drop the
			-- car and its record and validator state), then the original plane spawn.
			if rec.plane and rec.plane.Parent then
				rec.plane:Destroy()
			end
			FlightServer.records[player] = nil
			CarServer.states[player] = nil
			player:SetAttribute("MountedInCar", false)
			player:SetAttribute("VehicleType", "plane")
			CarServer.spawnPlane(player, slot)
		end
	end)
	FlightServer.startOverride = prevOverride
	if not ok then
		-- Never leave the player with no vehicle: put him back in the hub default at his plaza slot.
		warn("[SkyRally][DIRECTOR] exchange failed for " .. player.Name .. ": " .. tostring(err))
		exchangeAt[player] = os.clock()
		pcall(FlightServer.spawnOrResetPlane, player, slot)
		return false
	end
	exchangeAt[player] = os.clock()
	local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("SkyRallyRemotes")
	local raceRemote = remotes and remotes:FindFirstChild("RaceEventRemote")
	if raceRemote and raceRemote:IsA("RemoteEvent") then
		raceRemote:FireClient(player, "VehicleExchange", { vehicle = pad.vehicle, from = from, cframe = cf })
	end
	log("exchange %s %s -> %s at (%.0f,%.0f,%.0f)", player.Name, from, pad.vehicle, cf.Position.X, cf.Position.Y, cf.Position.Z)
	return true
end

-- One hub step of the exchange for one player: dwell on a pad that swaps this vehicle, then swap (once per cooldown).
local function stepExchange(player: Player, rec: any, hub: any, now: number)
	if now - (exchangeAt[player] or -math.huge) < RespawnRules.EXCHANGE_COOLDOWN then
		exchangeSince[player] = nil
		return
	end
	local vehicle = vehicleOf(rec)
	local pos = rec.hull.Position
	for _, pad in hub.exchange or {} do
		if typeof(pad.cf) == "CFrame" and type(pad.radius) == "number" and (pad.vehicle == "car" or pad.vehicle == "plane") then
			if RespawnRules.exchangeHit(vehicle, pos, pad) then
				local since = exchangeSince[player]
				if not since then
					exchangeSince[player] = now
				elseif RespawnRules.exchangeReady(vehicle, rec.hull.AssemblyLinearVelocity.Magnitude, now - since) then
					exchangeSince[player] = nil
					TrackDirector.exchangeVehicle(player, pad)
				end
				return
			end
		end
	end
	exchangeSince[player] = nil
end

-- Hub: portal arches, hub finds and the exchange pads, checked a few times a second against each player's vehicle.
local function stepHub()
	local h = hooks
	if not h then
		return
	end
	local td = TrackDirector.currentKey and loadTrackData(TrackDirector.currentKey)
	local hub = td and td.hub
	if not hub then
		return
	end
	local now = os.clock()
	local swaps: { () -> () } = {}
	local recs = h.playerRecords()
	stepLobby(now, recs)
	if RaceFlowRules.PER_GROUP then
		stepQueue(recs) -- phase 3: every arch's own lobby
	else
		publishArchStates() -- phase 3: the server-wide lobby on its arch's label
	end
	if TrackDirector.switching then
		return
	end
	for player, rec in recs do
		local hull = rec.hull
		if hull and hull.Parent then
			-- A swap replaces the record this loop iterates: run it after the loop.
			table.insert(swaps, function()
				stepExchange(player, rec, hub, now)
			end)
			local pos = hull.Position
			-- L20/L21: a find this player already holds is never asked for again (5 Hz award calls flooded the pending
			-- queue while the profile loaded and buried the noop evidence).
			local prof = profileOf(player)
			local held = if prof and type(prof.tokens) == "table" then prof.tokens else nil
			for _, find in hub.finds or {} do
				local fpos = find.pos
				if typeof(fpos) == "Vector3" and not (held and held[find.id] == true) and (pos - fpos).Magnitude < TrackDirector.FIND_RADIUS then
					local ok, SaveService = pcall(require, script.Parent.SaveService)
					if ok then
						local result = (SaveService :: any).award(player, "hubFind", find.id, "hub:" .. find.id)
						if result == "awarded" then
							log("hub find %s by %s", find.id, player.Name)
							if remote then
								remote:FireClient(player, "HubFind", { id = find.id, pos = fpos })
							end
							publishPortalStates(player)
						end
					end
				end
			end
		end
	end
	for _, swap in swaps do
		swap()
	end
end

-- Hub, every Heartbeat (portal-load): each vehicle's swept crossing watch against the arches (PortalRules.watchStep), and
-- the running 1.5 s warps. Per frame, not in the 5 Hz step: the server sees a pass within a frame of replication, so
-- the client's local plunge is confirmed in time, and no boosted pass is judged from two far-apart samples.
local function stepPortals()
	local h = hooks
	if not h or TrackDirector.switching then
		return
	end
	local td = TrackDirector.currentKey and loadTrackData(TrackDirector.currentKey)
	local hub = td and td.hub
	if not hub then
		return
	end
	local portals: { any } = {}
	local cfs: { CFrame } = {}
	for _, portal in hub.portals or {} do
		if typeof(portal.cf) == "CFrame" then
			table.insert(portals, portal)
			table.insert(cfs, portal.cf)
		end
	end
	local now = os.clock()
	for player, rec in h.playerRecords() do
		local hull = rec.hull
		if hull and hull.Parent then
			local pos = hull.Position
			local watch: PortalWatch? = hubPrev[player]
			if not watch or watch.hull ~= hull then
				-- A new vehicle (swap, respawn): a new path, never a jump through an arch.
				local fresh: PortalWatch = { hull = hull :: BasePart, w = PortalRules.newWatch() }
				hubPrev[player] = fresh
				watch = fresh
			end
			assert(watch, "portal watch")
			local hit = PortalRules.watchStep(watch.w, pos, now, cfs)
			local w = warps[player]
			if w then
				-- REMARKABLE 20 / H0-09: the warp switches the server unless the player backs out onto the plaza first.
				if not PortalRules.warpHolds(pos, w.cf) then
					warps[player] = nil
					log("warp to %s by %s cancelled (backed out)", w.track, player.Name)
					if remote then
						remote:FireAllClients("PortalWarpCancel", { userId = player.UserId, why = "backed out" })
					end
				elseif now >= w.at then
					warps[player] = nil
					TrackDirector.requestRace(player, w.key, "portal")
					if not RaceFlowRules.PER_GROUP then
						return -- the server is switching; per group only this player left the plaza
					end
				end
			elseif hit then
				local portal = portals[hit]
				local cf = cfs[hit]
				local key = keyById[portal.track]
				if not key then
					log("crossing of %s by %s: no track data mounted", tostring(portal.track), player.Name)
				else
					local ok, why = TrackDirector.canOpen(player, key)
					local hold = if ok and TrackDirector.holdRequests and not AdminRules.skipsHold(adminOf(player)) then TrackDirector.holdRequests() else nil
					local group = ok and not hold and RaceFlowRules.isGroup(humanCount())
					-- Phase 3 fallback (config): a lone human per group may keep the 1.5 s warp instead of the lobby.
					local soloWarp = RaceFlowRules.SOLO_QUICK_WARP and #Players:GetPlayers() <= 1
					if ok and hold then
						if remote and now - (lastPortalToast[player] or 0) > 4 then
							lastPortalToast[player] = now
							remote:FireClient(player, "StormCupHold", { why = hold })
						end
						log("crossing of %s by %s held: %s", tostring(portal.track), player.Name, tostring(hold))
					elseif ok and group and not RaceFlowRules.PER_GROUP then
						-- L31/L32: 2+ humans gather in a lobby; the solo warp below stays as it was.
						TrackDirector.openLobby(player, key, "race", cf)
					elseif ok and RaceFlowRules.PER_GROUP and not soloWarp then
						-- Phase 3: the arch is the queue (solo too: the same lobby, bots fill).
						queueJoin(player, key, "race", "portal", cf)
					elseif ok then
						warps[player] = { key = key, cf = cf, at = now + PortalRules.WARP_SECONDS, zone = tostring(portal.zone), track = portal.track }
						log("warp to %s by %s (%.1f s)", portal.track, player.Name, PortalRules.WARP_SECONDS)
						funnel("pick", player, { track = portal.track, via = "portal" })
						if remote then
							local warpData = {
								userId = player.UserId,
								name = player.DisplayName,
								id = portal.track,
								zone = tostring(portal.zone),
								seconds = PortalRules.WARP_SECONDS,
							}
							if RaceFlowRules.PER_GROUP then
								-- Per group nobody else is moved: no server-wide line, only his own plunge.
								remote:FireClient(player, "PortalWarp", warpData)
							else
								remote:FireAllClients("PortalWarp", warpData)
							end
						end
					elseif remote and now - (lastPortalToast[player] or 0) > 1.2 then
						lastPortalToast[player] = now
						remote:FireClient(player, "PortalLocked", { key = key, id = portal.track, why = why })
					end
				end
			end
		end
	end
end

-- After a race: when every human is done, the return timer (ReturnToHubAt) runs; when it ends the votes decide (no
-- votes: the hub, as before). L30: from the first human finish the others get DNF_SECONDS (workspace DnfAt, server
-- time, the unfinished HUD's countdown); then whoever is still flying is DNF (no award, Rally Streak kept) and the
-- return timer starts, so one AFK racer never holds the server.
local function stepRaceEnd()
	local h = hooks
	if not h or workspace:GetAttribute("RaceMode") == "hub" then
		return
	end
	local now = os.clock()
	if returnAt == nil then
		local recs = h.playerRecords()
		local anyDone = false
		for p, rec in recs do
			if p.Parent and rec.finished == true then
				anyDone = true
				break
			end
		end
		local battle = workspace:GetAttribute("RaceMode") == "battle"
		local step = RaceFlowRules.raceEndStep(h.allPlayersFinished(), anyDone, now, dnfAt, battle)
		if step == "wait" or step == "dnf" then
			-- Owner 2026-10-20: the field is home and no human is still racing (left, AFK): the race is over.
			local check = TrackDirector.afkCheck
			local active = 0
			for p, rec in recs do
				if p.Parent and rec.finished ~= true and rec.dnf ~= true and not (check and check(p)) then
					active += 1
				end
			end
			local fieldDone = h.fieldDone
			if not TrackDirector.qaBoot and RaceFlowRules.abandoned(fieldDone ~= nil and fieldDone(), active, battle) then
				step = "timeout"
				log("race abandoned: the field finished, no human racing")
			end
		end
		if step == "dnf" then
			dnfAt = now + RaceFlowRules.DNF_SECONDS
			workspace:SetAttribute("DnfAt", workspace:GetServerTimeNow() + RaceFlowRules.DNF_SECONDS)
			log("first finish: DNF deadline in %d s", RaceFlowRules.DNF_SECONDS)
		elseif step == "timeout" then
			local markDnf = h.markDnf
			for p, rec in recs do
				if p.Parent and rec.finished ~= true and rec.dnf ~= true and markDnf then
					markDnf(p)
				end
			end
			log("DNF deadline passed")
		end
		if step == "return" or step == "timeout" then
			dnfAt = nil
			workspace:SetAttribute("DnfAt", nil)
			TrackDirector.allFinishedAt = now
			returnAt = now + TrackDirector.RETURN_AFTER_FINISH
			workspace:SetAttribute("ReturnToHubAt", workspace:GetServerTimeNow() + TrackDirector.RETURN_AFTER_FINISH)
			resolveVotes(false) -- everyone may already have voted the same way while the last racer flew
		end
	elseif now >= returnAt then
		returnAt = nil
		TrackDirector.allFinishedAt = nil
		workspace:SetAttribute("ReturnToHubAt", nil)
		resolveVotes(true)
	end
end

-- FLY AGAIN on the finish screen replays the same race and cancels the return to the hub (and the votes, the DNF
-- deadline: a fresh race).
function TrackDirector.onReplay()
	returnAt = nil
	TrackDirector.allFinishedAt = nil
	workspace:SetAttribute("ReturnToHubAt", nil)
	clearRaceEnd()
end

-- Phase 2b (PER_GROUP true only): a group's map, built or restored next to the live hub inside the group's RaceScope
-- (MapAdapter registers it and TrackRegistry.setActive gives the scope its track; the hub's workspace ActiveTrackId
-- stays the hub's). Same steps as load() above minus everything server-wide (curtain, Terrain clear, other maps).
local function buildGroupMap(key: string, td: any): boolean
	local builder = ServerScriptService:FindFirstChild("Maps") and (ServerScriptService :: any).Maps:FindFirstChild(key)
	if not (builder and builder:IsA("ModuleScript")) then
		warn("[SkyRally][DIRECTOR] no builder for " .. tostring(key))
		return false
	end
	Prewarm.forTrack(td)
	local maps = workspace:FindFirstChild("Maps")
	if maps then
		for _, c in maps:GetChildren() do
			if not RaceInstanceRules.keepMap(true, c.Name, key, td.id) then
				c:Destroy() -- a stale copy of this map only
			end
		end
	end
	workspace:SetAttribute(MapAdapter.readyAttribute(td.id), nil)
	workspace:SetAttribute(MapAdapter.failedAttribute(td.id), nil)
	-- The hub's plaza and every other zone share this Terrain: a "Clear" shell op clears this map's own box at most.
	local buildOpts = buildOptions(td, true)
	local cached = MapCache.load(key, td)
	if cached then
		return true
	end
	local runs = ServerStorage:FindFirstChild("BuilderRuns") or Instance.new("Folder")
	runs.Name = "BuilderRuns"
	runs.Parent = ServerStorage
	local clone = builder:Clone()
	clone.Parent = runs
	task.spawn(function()
		local ok, err = pcall(require, clone)
		if not ok then
			warn("[SkyRally][DIRECTOR] builder " .. key .. " failed: " .. tostring(err))
		end
	end)
	local report = MapAdapter.build(td, buildOpts)
	clone:Destroy()
	MapCache.store(key, td, report, TrackDirector.HUB_KEY)
	return report.ok ~= false
end

-- Phase 2b: the live wiring of server/RaceGroups (PER_GROUP true only).
local function initGroups(h: Hooks)
	local function FS(): any
		return require(script.Parent.FlightServer) :: any
	end
	local function AI(): any
		return require(script.Parent.AIRacers) :: any
	end
	RaceGroups.init({
		hooks = {
			suspendRace = h.suspendRace,
			onTrackChanged = h.onTrackChanged,
			spawnBots = h.spawnBots,
			despawnBots = function()
				AI().despawnAll() -- this group's field only (its scope); battles are not per group yet
			end,
			clearItems = function()
				local ItemService = require(script.Parent.ItemService) :: any
				local ItemEffects = require(script.Parent.kit.ItemEffects) :: any
				ItemService.reset()
				local effects = ItemEffects.active
				if effects then
					effects.clear()
				end
			end,
			resetRace = h.resetRace,
			allPlayersFinished = h.allPlayersFinished,
			-- The mode systems behind h.startMode (BossRace, CoinChallenge, KeyPickup, DuckHunt, the cannons, VolcanoVents,
			-- BattleCore) keep one state per RaceScope scope (shared/ModeScopeRules, systems audit v32 T0-2): RaceGroups
			-- calls this inside the group's scope, so a group's load or replay starts and stops only its own, never another
			-- group's coins or the hub's set pieces. stopMode takes them down before the instance's scope closes.
			startMode = h.startMode,
			stopMode = function()
				h.startMode("hub", nil) -- every system's stop, in this scope; nil td starts nothing
			end,
			markDnf = h.markDnf,
			fieldDone = h.fieldDone,
			refreshField = function(reason: string, leaving: Player?)
				AI().refreshField(reason, leaving)
			end,
			botSlots = function(): { [number]: boolean }
				return AI().heldSlots()
			end,
			dropRacer = function(player: Player)
				local ItemService = require(script.Parent.ItemService) :: any
				local svc = ItemService.active
				if svc then
					svc.removeRacer(ItemService.playerRacerId(player.UserId))
				end
			end,
		},
		loadTrackData = loadTrackData,
		buildMap = buildGroupMap,
		destroyMap = function(trackId: string)
			local maps = workspace:FindFirstChild("Maps")
			local root = maps and maps:FindFirstChild(trackId)
			if root then
				root:Destroy()
			end
			workspace:SetAttribute(MapAdapter.readyAttribute(trackId), nil)
			workspace:SetAttribute(MapAdapter.failedAttribute(trackId), nil)
		end,
		publishZone = function(td: any)
			local root = TrackRegistry.getRoot()
			if root then
				RaceInstance.publishZone(root, td)
			end
		end,
		newInstance = function(key: string, td: any, mode: string, field: number): any
			return RaceInstance.new(key, td, mode, field)
		end,
		spawn = function(player: Player, slot: number)
			FS().spawnOrResetPlane(player, slot)
		end,
		-- Back on the plaza (hub scope), the grid in front of the arch of the zone they left (L19), each on a seat no
		-- hub player holds.
		hubReturn = returnToApron,
		records = function(): { [Player]: any }
			return FS().records
		end,
		serverNow = function(): number
			return workspace:GetServerTimeNow()
		end,
		clock = os.clock,
		send = function(player: Player, event: string, data: any)
			if remote then
				remote:FireClient(player, event, data)
			end
		end,
		delay = function(seconds: number, fn: () -> ())
			task.delay(seconds, fn)
		end,
		spawnTask = function(fn: () -> ())
			task.spawn(fn)
		end,
		afk = function(p: Player): boolean
			local check = TrackDirector.afkCheck
			return check ~= nil and check(p)
		end,
		funnel = funnel,
		log = function(line: string)
			print(line)
		end,
		hubTrackId = Progression.HUB_TRACK,
	})
end

function TrackDirector.init(h: Hooks)
	hooks = h
	indexTracks()
	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "SkyRallyRemotes"
		remotes.Parent = ReplicatedStorage
	end
	local r = remotes:FindFirstChild("TrackFlowRemote") :: RemoteEvent?
	if not r then
		local nr = Instance.new("RemoteEvent")
		nr.Name = "TrackFlowRemote"
		nr.Parent = remotes
		r = nr
	end
	remote = r
	if RaceFlowRules.PER_GROUP then
		initGroups(h)
	end
	local lastRequest: { [Player]: number } = {}
	local introLimiter = RemoteGuardRules.newLimiter(RemoteGuardRules.LIMITS.battleIntro)
	Players.PlayerRemoving:Connect(introLimiter.forget)
	-- Phase 3: LEAVE has its own short throttle, so a LEAVE right after a board JOIN is never dropped (leaving is always
	-- allowed; queueLeave is a no-op for a player in no lobby).
	local lastLeave: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
	(r :: RemoteEvent).OnServerEvent:Connect(function(player: Player, action: any, arg: any, arg2: any)
		local now = os.clock()
		if action == "LeaveLobby" then
			if RaceFlowRules.PER_GROUP and now - (lastLeave[player] or 0) >= RaceFlowRules.LEAVE_THROTTLE then
				lastLeave[player] = now
				-- Phase 3: LEAVE on the "Waiting for racers" line or the board row; from an arch lobby, back to the apron.
				noteAction(player)
				queueLeave(player, "leave", true)
			end
			return
		end
		if action == "BattleIntroSeen" then
			-- The first-unlock explainer was shown: save the flag (idempotent; SaveService.edit coalesces its writes).
			-- T1-9: it writes the save, so a looping client is held to RemoteGuardRules.LIMITS.battleIntro.
			if not introLimiter.allow(player, now) then
				return
			end
			local ok, SaveService = pcall(require, script.Parent.SaveService)
			if ok then
				pcall((SaveService :: any).markBattleIntro, player)
			end
			return
		end
		if now - (lastRequest[player] or 0) < 1.5 then
			return
		end
		lastRequest[player] = now
		if action == "RequestRace" and type(arg) == "string" and keyById[arg] then
			local mode = if type(arg2) == "string" and table.find(TrackDirector.BOARD_MODES, arg2) then arg2 else "race"
			if arg == "HUB-0" then
				mode = "boss"
			end
			-- Per group the board answers from the hub only (a player in a race picks again from the finish card).
			if RaceAttr.get("RaceMode", player) == "hub" then
				noteAction(player)
				if RaceFlowRules.isGroup(humanCount()) and not RaceFlowRules.PER_GROUP then
					TrackDirector.openLobby(player, keyById[arg], mode, nil) -- L31/L32: the board opens the lobby too
				elseif RaceFlowRules.PER_GROUP and not (RaceFlowRules.SOLO_QUICK_WARP and #Players:GetPlayers() <= 1) then
					-- Phase 3: the board's JOIN (and every mode button) joins that track's lobby like a drive through.
					queueJoin(player, keyById[arg], mode, "board", nil)
				else
					TrackDirector.requestRace(player, keyById[arg], "board", mode)
				end
			end
		elseif action == "RequestHub" then
			TrackDirector.requestExit(player, "hub") -- L30: a vote with 2+ humans
		elseif action == "RequestBattle" and type(arg) == "string" and keyById[arg] then
			noteAction(player)
			TrackDirector.requestBattle(player, keyById[arg], arg) -- the results card's BATTLE
		end
	end)
	-- SaveService replicates SkyTokens and Keys on every award: a token or a hidden key changes what the board opens.
	local function watchProgress(p: Player)
		for _, attr in { "SkyTokens", "Keys", BattleAccessRules.ATTR } do
			p:GetAttributeChangedSignal(attr):Connect(function()
				publishPortalStates(p)
			end)
		end
	end
	-- Owner 2026-10-20: a joiner is never dropped into a race nobody else is playing (an idle racer, a finished field,
	-- an empty server kept the old race's map). Deferred, after FlightServer seated him: "hub" ends the race.
	local function checkJoin(p: Player)
		local left = leftRace[p.UserId]
		leftRace[p.UserId] = nil
		-- Per group a joiner always lands in the live hub and no race is ended for him.
		if not p.Parent or TrackDirector.qaBoot or RaceFlowRules.PER_GROUP then
			return
		end
		local check = TrackDirector.afkCheck
		local others = 0
		for _, o in Players:GetPlayers() do
			if o ~= p and not (check and check(o)) then
				others += 1
			end
		end
		local mode = workspace:GetAttribute("RaceMode")
		local decision = RaceFlowRules.joinStep({
			mode = if type(mode) == "string" then mode else nil,
			switching = TrackDirector.switching,
			ended = returnAt ~= nil,
			othersActive = others,
			left = left,
			jobId = JOB_ID,
			raceId = workspace:GetAttribute("RaceResetSeq") :: number?,
			now = os.time(),
		})
		if decision == "hub" then
			TrackDirector.returnToHub("joiner " .. p.Name .. ": nobody else in this race")
		end
	end
	Players.PlayerAdded:Connect(function(p: Player)
		task.defer(checkJoin, p)
		task.delay(3, publishPortalStates, p)
		watchProgress(p)
		publishVotes()
		local l = lobby
		if l then
			p:SetAttribute("LobbyGuest", if (TrackDirector.canOpen(p, l.key, l.mode)) then nil else true)
		end
	end)
	for _, p in Players:GetPlayers() do
		task.defer(publishPortalStates, p)
		watchProgress(p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		if RaceFlowRules.PER_GROUP then
			RaceGroups.onLeave(p)
			queueLeave(p, "left the server", false)
		end
		queueCf[p] = nil
		queuePlunged[p] = nil
		local mode = workspace:GetAttribute("RaceMode")
		if mode ~= "hub" and not TrackDirector.switching and returnAt == nil then
			leftRace[p.UserId] = { jobId = JOB_ID, raceId = workspace:GetAttribute("RaceResetSeq") :: number?, at = os.time() }
		else
			leftRace[p.UserId] = nil
		end
		lastPortalToast[p] = nil
		hubPrev[p] = nil
		warps[p] = nil
		lastRequest[p] = nil
		pendingBattles[p] = nil
		exchangeSince[p] = nil
		exchangeAt[p] = nil
		votes[p] = nil
		lastVote[p] = nil
		local l = lobby
		if l and l.opener == p then
			closeLobby("left")
		end
		-- The leaver is still listed during PlayerRemoving: recount after, and the rest may now agree.
		task.defer(function()
			publishVotes()
			if returnAt ~= nil then
				resolveVotes(false)
			end
		end)
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		if not TrackDirector.switching and workspace:GetAttribute("RaceMode") == "hub" then
			stepPortals() -- portal-load: every frame (swept crossings, warps)
		end
		acc += dt
		if acc < 0.2 or TrackDirector.switching then
			return
		end
		acc = 0
		if workspace:GetAttribute("RaceMode") == "hub" then
			stepHub()
		else
			stepRaceEnd()
		end
		if RaceFlowRules.PER_GROUP then
			RaceGroups.step() -- every group's race end in its own scope, next to the hub
		end
	end)
end

return TrackDirector
