--!strict
-- Owner admin account (DECISIONS D22, owner maintainer 2026-10-20; TEST_LIST_LAUNCH L90-L91; tools/tests/admin_spec.luau).
-- One account (AdminConfig.ADMIN_USER_ID) gets an admin panel and /admin chat commands to test the live private place:
--  * map access bypass (runtime only, never saved): TrackDirector.canOpen opens every mode the map has for him;
--  * explicit progression grants through SaveService.award with the real AwardKind values, source "admin:grant" (the only
--    source SaveService.adminBypass opens; repeats log noop like any award);
--  * Cash (draft.gears) through Economy.adminGrantCash (the earn pattern, multiplier 1, analytics sku "admin"), the 2x Cash
--    pass as a runtime override, the Win Pass counters in his own profile;
--  * a Storm Cup on demand with his map and modifier (StormCup.adminForce), the cup still paying Cash only;
--  * lobby skip / short, an instant solo start with bots, and "hold off" for the cup's lobby minute (TrackDirector);
--  * D22a "all vehicles unlocked" (runtime only, default ON): AvatarSelect.adminVehicles answers his switch, so every
--    vehicle avatar is owned and selectable for him (picks of unowned ones stay in server memory, never in the save).
-- Security: the one AdminRequest RemoteFunction takes a command string and no target player; every call re-checks the
-- UserId on the server (the client panel is cosmetic). Anyone else gets nil and nothing is logged to them or changed.
-- Every grant targets the caller's own profile. The one exception is the documented save tools (T1-14,
-- docs/SAVE_ADMIN.md: inspect, versions, restore, erase by userId), which only the AdminConfig account itself may run. No player attribute marks the admin. Studio only (RunService:IsStudio()
-- read here, never from a client): workspace QAAdminStudio = true makes ONE test player admin (QAAdminStudioUserId, else
-- the first player to join the Studio session).
-- T1-5: "/admin live ..." reads (status) or flips (real admin account only) the live kill switches (server/LiveOps).
-- Every admin action logs one "[SkyRally][ADMIN] kind=admin action=... user=... result=..." line.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
-- Server-only: who the admin is never replicates (server/AdminConfig).
local AdminConfig = require(script.Parent.AdminConfig)
local AdminRules = require(Shared:WaitForChild("AdminRules"))
local ChatCompat = require(Shared:WaitForChild("ChatCompat"))
-- T1-14: "/admin save inspect|versions|restore|erase <userId>" (server/SaveAdmin; docs/SAVE_ADMIN.md).
local SaveAdminRules = require(Shared:WaitForChild("SaveAdminRules"))
-- T1-5: "/admin live ..." flips the live kill switches (server/LiveOps; shared/LiveOpsRules; docs/RUNBOOK.md section 4).
local LiveOpsRules = require(Shared:WaitForChild("LiveOpsRules"))

local AdminService = {}

export type Deps = {
	isStudio: () -> boolean, -- RunService:IsStudio() on the server
	attr: (name: string) -> any, -- a workspace attribute
	playerByUserId: (userId: number) -> Player?,
	award: (player: Player, kind: string, id: string, source: string) -> string,
	economy: () -> any, -- the Economy service (adminGrantCash, adminSetPass, adminSetWinPass), nil while it is off
	keyForId: (trackId: string) -> string?,
	adminStart: (player: Player, key: string, mode: string) -> (boolean, string),
	republish: (player: Player) -> (),
	stormForce: (trackId: string, modifier: string) -> (boolean, string),
	clock: () -> number,
	vehiclesChanged: ((player: Player, on: boolean) -> ())?, -- D22a: the switch flipped (drop runtime picks when off)
	log: ((string) -> ())?,
	-- T1-14: the save tools (server/SaveAdmin service: run(actorId, cmd) -> {ok, text}); nil = off on this server.
	saveAdmin: (() -> any)?,
	-- T1-5: the live flags service (server/LiveOps: command(actorId, cmd) -> ok, text); nil = off on this server.
	liveOps: (() -> any)?,
}

export type State = { portals: boolean, lobby: string, holdOff: boolean, vehicles: boolean }
export type Reply = { ok: boolean, text: string, state: State }

export type Service = {
	isAdmin: (player: Player) -> boolean,
	flagsOf: (player: Player) -> AdminRules.Flags?,
	bypass: (userId: number, source: string) -> boolean,
	portalsOpen: (userId: number) -> boolean,
	vehiclesOpen: (player: Player) -> boolean,
	handle: (player: Player, text: any) -> Reply?,
	chat: (player: Player, message: any) -> Reply?,
	noteJoin: (player: Player) -> (),
	playerRemoving: (player: Player) -> (),
}

local DENIED_LOG_GAP = 10 -- seconds between two "denied" log lines for one non-admin (a spam loop cannot flood the log)

function AdminService.new(deps: Deps): Service
	local log = deps.log or function(line: string)
		print(line)
	end
	local svc = {} :: Service
	local flags: { [Player]: AdminRules.Flags } = {}
	local lastAt: { [Player]: number } = {}
	local deniedAt: { [Player]: number } = {}
	local firstStudio: number? = nil

	local function adminLog(player: Player, action: string, result: string, detail: string?)
		log(string.format("%s action=%s user=%d result=%s%s", AdminRules.LOG, action, player.UserId, result, if detail then " " .. detail else ""))
	end

	local function studioUserId(): number?
		local a = deps.attr(AdminConfig.STUDIO_USER_ATTRIBUTE)
		if type(a) == "number" then
			return a
		end
		return firstStudio
	end

	function svc.noteJoin(player: Player)
		if firstStudio == nil and deps.isStudio() then
			firstStudio = player.UserId
		end
	end

	function svc.isAdmin(player: Player): boolean
		if AdminConfig.isAdmin(player.UserId) then
			return true
		end
		local studio = deps.isStudio() == true
		if not studio then
			return false -- live server: the Studio attributes are never read
		end
		return AdminConfig.isAdminPlayer(player.UserId, studio, deps.attr(AdminConfig.STUDIO_ATTRIBUTE), studioUserId())
	end

	function svc.flagsOf(player: Player): AdminRules.Flags?
		if not svc.isAdmin(player) then
			return nil
		end
		local existing = flags[player]
		if existing then
			return existing
		end
		local f = AdminRules.defaultFlags()
		flags[player] = f
		adminLog(player, "session", "start", AdminRules.describe(f))
		return f
	end

	function svc.bypass(userId: number, source: string): boolean
		local p = deps.playerByUserId(userId)
		if not p then
			return false
		end
		return AdminConfig.awardBypass(svc.flagsOf(p), source)
	end

	-- D22: whether this user's map-access bypass is on (SaveService republishes BattlesOpen with it). false for everyone else.
	function svc.portalsOpen(userId: number): boolean
		local p = deps.playerByUserId(userId)
		if not p then
			return false
		end
		return AdminRules.portalsOpen(svc.flagsOf(p))
	end

	-- D22a: whether this player's "all vehicles unlocked" switch is on (AvatarSelect.adminVehicles). false for everyone else.
	function svc.vehiclesOpen(player: Player): boolean
		return AdminRules.vehiclesOpen(svc.flagsOf(player))
	end

	function svc.playerRemoving(player: Player)
		flags[player] = nil
		lastAt[player] = nil
		deniedAt[player] = nil
	end

	local function stateOf(f: AdminRules.Flags): State
		return { portals = f.portals, lobby = f.lobby, holdOff = f.holdOff, vehicles = f.vehicles }
	end

	local AWARD_WORD: { [string]: string } = { awarded = "granted", noop = "already held", queued = "queued (save loading)", rejected = "refused" }

	function svc.handle(player: Player, text: any): Reply?
		if not svc.isAdmin(player) then
			local now = deps.clock()
			if text ~= AdminRules.PROBE and now - (deniedAt[player] or -math.huge) >= DENIED_LOG_GAP then
				deniedAt[player] = now
				adminLog(player, "request", "denied", "notAdmin")
			end
			return nil -- nothing for anyone else: no reply, no hint that the remote does anything
		end
		local f = svc.flagsOf(player) :: AdminRules.Flags
		local function reply(ok: boolean, line: string): Reply
			return { ok = ok, text = line, state = stateOf(f) }
		end
		local now = deps.clock()
		if now - (lastAt[player] or -math.huge) < AdminRules.REQUEST_GAP then
			return reply(false, "Too fast. Try again.")
		end
		lastAt[player] = now
		-- T1-14 save tools: they read and write OTHER players' saves, so only the real admin account (AdminConfig.isAdmin)
		-- may run them; the Studio test override never does (Studio with API access talks to the live DataStores).
		if SaveAdminRules.isSaveCommand(text) then
			if not AdminConfig.isAdmin(player.UserId) then
				adminLog(player, "save", "denied", "studioOverride")
				return reply(false, "Save tools need the admin account itself.")
			end
			local sc, swhy = SaveAdminRules.parse(text)
			if not sc then
				adminLog(player, "save", "rejected", string.format("%q", string.sub(tostring(text), 1, 60)))
				return reply(false, tostring(swhy))
			end
			local tools = if deps.saveAdmin then deps.saveAdmin() else nil
			if not tools then
				adminLog(player, "save", "rejected", "off")
				return reply(false, "Save tools are off on this server.")
			end
			local okRun, r = pcall(tools.run, player.UserId, sc)
			if not okRun or type(r) ~= "table" then
				adminLog(player, "save", "failed", string.format("op=%s target=%d %s", sc.action, sc.userId, tostring(r)))
				return reply(false, "Save tool error: " .. tostring(r))
			end
			adminLog(player, "save", if r.ok then "ok" else "refused", string.format("op=%s target=%d", sc.action, sc.userId))
			return reply(r.ok == true, tostring(r.text))
		end
		-- T1-5 live flags: they switch features off for EVERY server and player, so like the save tools only the real
		-- admin account may flip them (the Studio override never does: Studio with API access writes the live store).
		if LiveOpsRules.isLiveCommand(text) then
			local lc, lwhy = LiveOpsRules.parseCommand(text)
			if not lc then
				adminLog(player, "live", "rejected", string.format("%q", string.sub(tostring(text), 1, 60)))
				return reply(false, tostring(lwhy))
			end
			if lc.action ~= "status" and lc.action ~= "help" and not AdminConfig.isAdmin(player.UserId) then
				adminLog(player, "live", "denied", "studioOverride")
				return reply(false, "Live flags need the admin account itself.")
			end
			local live = if deps.liveOps then deps.liveOps() else nil
			if not live then
				adminLog(player, "live", "rejected", "off")
				return reply(false, "Live flags are off on this server.")
			end
			local okRun, okCmd, ltext = pcall(live.command, player.UserId, lc)
			if not okRun then
				adminLog(player, "live", "failed", tostring(okCmd))
				return reply(false, "Live flags error: " .. tostring(okCmd))
			end
			if lc.action == "set" or lc.action == "reset" then
				adminLog(
					player,
					"live",
					if okCmd then "set" else "failed",
					string.format("flag=%s on=%s", tostring(lc.flag or "all"), tostring(if lc.action == "reset" then true else lc.on))
				)
			end
			return reply(okCmd == true, tostring(ltext))
		end
		local cmd, why = AdminRules.parse(text)
		if not cmd then
			adminLog(player, "parse", "rejected", string.format("%q", string.sub(tostring(text), 1, 60)))
			return reply(false, tostring(why))
		end
		local a = cmd.action
		if a == "open" or a == "status" then
			return reply(true, AdminRules.describe(f))
		elseif a == "help" then
			return reply(true, AdminRules.HELP .. "\n" .. SaveAdminRules.HELP .. "\n" .. LiveOpsRules.HELP)
		elseif a == "portals" then
			f.portals = cmd.on == true
			deps.republish(player)
			adminLog(player, "portals", "set", "on=" .. tostring(f.portals))
			return reply(true, if f.portals then "Map access: all maps and modes open." else "Map access: your saved progress.")
		elseif a == "award" then
			local kind, id = cmd.kind :: string, cmd.id :: string
			local result = deps.award(player, kind, id, AdminConfig.AWARD_SOURCE)
			adminLog(player, "award", tostring(result), string.format("kind=%s id=%s", kind, id))
			local ok = result == "awarded" or result == "noop" or result == "queued"
			return reply(ok, string.format("%s %s: %s.", kind, id, AWARD_WORD[result] or tostring(result)))
		elseif a == "cash" or a == "pass" or a == "winpass" then
			local econ = deps.economy()
			if not econ then
				adminLog(player, a, "rejected", "economy off")
				return reply(false, "Economy is off on this server.")
			end
			if a == "cash" then
				local r = econ.adminGrantCash(player, cmd.amount)
				if not r.ok then
					return reply(false, "Cash: " .. tostring(r.reason))
				end
				return reply(true, string.format("+%d Cash. Balance %d.", r.data.granted, r.data.balance))
			elseif a == "pass" then
				local r = econ.adminSetPass(player, cmd.pass, cmd.on)
				if not r.ok then
					return reply(false, "Pass: " .. tostring(r.reason))
				end
				return reply(true, if cmd.on then "2x Cash on." else "2x Cash off.")
			else
				local r = econ.adminSetWinPass(player, cmd.field, cmd.value)
				if not r.ok then
					return reply(false, "Win Pass: " .. tostring(r.reason))
				end
				return reply(true, string.format("Win Pass %s = %s.", tostring(cmd.field), tostring(cmd.value)))
			end
		elseif a == "storm" then
			local track, modifier = cmd.track :: string, cmd.modifier :: string
			local ok, why2 = deps.stormForce(track, modifier)
			adminLog(player, "storm", if ok then "queued" else "rejected", string.format("track=%s modifier=%s %s", track, modifier, why2))
			if not ok then
				return reply(false, "Storm Cup: " .. why2)
			end
			return reply(true, string.format("Storm Cup on %s (%s): starts from the hub, or after this race.", track, modifier))
		elseif a == "vehicles" then
			f.vehicles = cmd.on == true
			if deps.vehiclesChanged then
				deps.vehiclesChanged(player, f.vehicles)
			end
			adminLog(player, "vehicles", "set", "on=" .. tostring(f.vehicles))
			return reply(true, if f.vehicles then "Vehicles: all unlocked (not saved)." else "Vehicles: your saved garage.")
		elseif a == "lobby" then
			f.lobby = cmd.mode :: string
			adminLog(player, "lobby", "set", "mode=" .. f.lobby)
			return reply(true, "Lobby: " .. f.lobby .. ".")
		elseif a == "hold" then
			f.holdOff = cmd.on == false
			adminLog(player, "hold", "set", "holdOff=" .. tostring(f.holdOff))
			return reply(true, if f.holdOff then "Cup hold off: your races start in the cup lobby minute." else "Cup hold on.")
		elseif a == "solo" then
			local track, mode = cmd.track :: string, cmd.mode :: string
			local key = deps.keyForId(track)
			if not key then
				adminLog(player, "solo", "rejected", "track=" .. track .. " not on this server")
				return reply(false, track .. " is not on this server.")
			end
			local ok, why2 = deps.adminStart(player, key, mode)
			adminLog(player, "solo", if ok then "started" else "rejected", string.format("track=%s mode=%s %s", track, mode, why2))
			return reply(ok, if ok then string.format("Starting %s %s.", track, mode) else "Solo: " .. why2 .. ".")
		end
		return reply(false, "Unknown command.")
	end

	-- A chat line (legacy chat's command hook). Everyone but the admin returns nil at once: no parse, no log, no reply,
	-- so their text stays ordinary chat. For him only "/admin ..." lines are handled; other lines are ordinary chat.
	function svc.chat(player: Player, message: any): Reply?
		if not svc.isAdmin(player) then
			return nil
		end
		if not AdminRules.isChatCommand(message) then
			return nil
		end
		return svc.handle(player, message)
	end

	return svc
end

local defaultService: Service? = nil

-- Wires the hooks (SaveService.adminBypass, Economy.adminCheck, TrackDirector.adminFlags) and the AdminRequest remote.
-- Call once from the server entry script after TrackDirector, Economy and StormCup are up.
function AdminService.init(): Service
	local existing = defaultService
	if existing then
		return existing
	end
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local SaveService = require(script.Parent.SaveService) :: any
	local Economy = require(script.Parent.Economy) :: any
	local TrackDirector = require(script.Parent.TrackDirector) :: any
	local StormCup = require(script.Parent.StormCup) :: any
	local AvatarSelect = require(script.Parent.AvatarSelect) :: any
	local saveTools: any = nil
	local svc = AdminService.new({
		isStudio = function(): boolean
			return RunService:IsStudio()
		end,
		attr = function(name: string): any
			return workspace:GetAttribute(name)
		end,
		playerByUserId = function(userId: number): Player?
			return Players:GetPlayerByUserId(userId)
		end,
		award = function(player: Player, kind: string, id: string, source: string): string
			return (SaveService.award(player, kind, id, source))
		end,
		economy = function(): any
			return Economy.service()
		end,
		keyForId = function(trackId: string): string?
			return TrackDirector.keyForId(trackId)
		end,
		adminStart = function(player: Player, key: string, mode: string): (boolean, string)
			return TrackDirector.adminStart(player, key, mode)
		end,
		republish = function(player: Player)
			pcall(TrackDirector.republish, player)
		end,
		stormForce = function(trackId: string, modifier: string): (boolean, string)
			return StormCup.adminForce(trackId, modifier)
		end,
		clock = os.clock,
		vehiclesChanged = function(player: Player, on: boolean)
			if not on then
				AvatarSelect.clearRuntime(player)
			end
		end,
		liveOps = function(): any
			return (require(script.Parent.LiveOps) :: any).service()
		end,
		saveAdmin = function(): any
			-- Created on first use: no DataStore handle for the save tools until the admin runs one.
			if saveTools == nil then
				local SaveAdmin = require(script.Parent.SaveAdmin) :: any
				local LeaderboardRules = require(Shared:WaitForChild("LeaderboardRules")) :: any
				local names = {}
				for _, board in ipairs(LeaderboardRules.boards()) do
					table.insert(names, board.store)
				end
				saveTools = SaveAdmin.live(SaveService.migrate, names)
			end
			return saveTools
		end,
	})
	defaultService = svc
	SaveService.adminBypass = svc.bypass
	SaveService.adminPortals = svc.portalsOpen
	Economy.adminCheck = svc.isAdmin
	TrackDirector.adminFlags = svc.flagsOf
	AvatarSelect.adminVehicles = svc.vehiclesOpen

	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "SkyRallyRemotes"
		remotes.Parent = ReplicatedStorage
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = AdminRules.REMOTE
	rf.OnServerInvoke = function(player: Player, text: any): any
		local ok, result = pcall(svc.handle, player, text)
		if ok then
			return result
		end
		warn("[SkyRally][ADMIN] handle error: " .. tostring(result))
		return nil
	end
	rf.Parent = remotes

	Players.PlayerAdded:Connect(svc.noteJoin)
	for _, p in Players:GetPlayers() do
		svc.noteJoin(p)
	end
	Players.PlayerRemoving:Connect(svc.playerRemoving)

	-- /admin in chat. TextChatService places: the admin's client registers a local TextChatCommand (client/AdminPanel).
	-- Legacy chat places (this place's Studio file runs LegacyChatService, Studio proof 2026-10-21): a client
	-- TextChatCommand never fires there, so the server hooks the legacy ChatService's command step instead. The hook returns
	-- true only for the admin's own "/admin ..." lines, which swallows them (never broadcast) and answers him alone with a
	-- system line; every other message from every player returns false at once and goes to chat unchanged.
	local TextChatService = game:GetService("TextChatService")
	local legacy = ChatCompat.detect(TextChatService.ChatVersion.Name) == "legacy"
	if legacy then
		task.spawn(function()
			local ServerScriptService = game:GetService("ServerScriptService")
			local runner = ServerScriptService:WaitForChild("ChatServiceRunner", 60)
			local module = if runner then runner:WaitForChild("ChatService", 10) else nil
			if not module or not module:IsA("ModuleScript") then
				print(string.format("%s action=init chat=legacy hook=none", AdminRules.LOG))
				return
			end
			local okReq, chatService = pcall(require, module)
			if not okReq or type(chatService) ~= "table" then
				print(string.format("%s action=init chat=legacy hook=failed", AdminRules.LOG))
				return
			end
			local cs = chatService :: any
			cs:RegisterProcessCommandsFunction("SkyRallyAdmin", function(speakerName: string, message: string, channelName: string): boolean
				local player = Players:FindFirstChild(speakerName)
				if not player or not player:IsA("Player") then
					return false
				end
				local okChat, reply = pcall(svc.chat, player, message)
				if not okChat or reply == nil then
					return false
				end
				local speaker = cs:GetSpeaker(speakerName)
				if speaker then
					pcall(function()
						speaker:SendSystemMessage(reply.text, channelName)
					end)
				end
				return true
			end)
			print(string.format("%s action=init chat=legacy hook=on", AdminRules.LOG))
		end)
	end
	print(string.format("%s action=init studio=%s chat=%s", AdminRules.LOG, tostring(RunService:IsStudio()), if legacy then "legacy" else "textchat"))
	return svc
end

function AdminService.service(): Service?
	return defaultService
end

return AdminService
