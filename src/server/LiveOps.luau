--!strict
-- Live kill switches and soft shutdown (systems audit v32 T1-5; rules in shared/LiveOpsRules; docs/RUNBOOK.md section 4;
-- tools/tests/live_ops_spec.luau).
-- * Flags: one DataStore row (LiveOpsRules.STORE_NAME / KEY) read at boot, every POLL_SECONDS and on a MessagingService
--   nudge. Fail OPEN: an unreadable or damaged row means every feature ON (a recent good read is kept STALE_SECONDS).
--   Only the D22 admin account writes the row, through "/admin live ..." (server/AdminService checks AdminConfig first;
--   each change logs "[SkyRally][ADMIN] kind=admin action=live ..."). Nothing a client sends can change a flag.
-- * Hooks (each fails open when LiveOps is not up): Economy.liveCheck (store prompts), TrackDirector.liveBlock (battles,
--   single maps, and every new race while the server is closing), StormCup / StormRace enabled (stormcup),
--   AvatarSelect (avatars), Funnels / ErrorReporter / Economy analytics sinks (telemetry). LiveOps.isOn(flag) is the
--   module-level read for code that cannot take a hook.
-- * Soft shutdown: DataModel.ServerRestartScheduled (an update was published and Roblox scheduled this server's restart)
--   runs LiveOpsRules' sequence: notice, hold new races, let running races finish, final saves, TeleportAsync to the same
--   place (the Roblox sample says this lands on the latest version), friendly kick for anyone left. BindToClose (hard
--   close) toasts, saves and kicks with the same friendly text. Studio: workspace LiveOpsSoftQA = true runs the soft
--   sequence with the teleport and the kick replaced by log lines.
local LiveOpsRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("LiveOpsRules"))

local LiveOps = {}

export type Deps = {
	read: () -> (boolean, any), -- GetAsync of the flag row: ok, document (nil = no row)
	update: (transform: (old: any) -> any) -> (boolean, any), -- UpdateAsync: ok, new document or error
	publish: ((rev: number) -> ())?, -- MessagingService nudge to the other servers
	now: () -> number, -- epoch seconds
	setAttr: (name: string, value: any) -> (),
	log: ((string) -> ())?,
	onChange: ((state: LiveOpsRules.State) -> ())?,
}

export type Service = {
	refresh: (why: string) -> LiveOpsRules.State,
	nudge: (rev: any) -> boolean,
	state: () -> LiveOpsRules.State,
	source: () -> string,
	isOn: (flag: string) -> boolean,
	modeBlock: (trackId: any, mode: any) -> string?,
	storeBlock: () -> string?,
	closing: () -> boolean,
	setClosing: (on: boolean) -> (),
	command: (actorId: number, cmd: LiveOpsRules.Command) -> (boolean, string),
}

function LiveOps.new(deps: Deps): Service
	local log = deps.log or function(line: string)
		print(line)
	end
	local svc = {} :: Service
	local current = LiveOpsRules.defaultState()
	local source = "default"
	local lastGood: LiveOpsRules.State? = nil
	local lastGoodAt: number? = nil
	local isClosing = false
	local lastNudgeAt = -math.huge

	local function publishAttrs()
		deps.setAttr(LiveOpsRules.ATTR_OFF, table.concat(LiveOpsRules.offList(current), ","))
	end

	local function adopt(state: LiveOpsRules.State, src: string, why: string)
		local before = table.concat(LiveOpsRules.offList(current), ",")
		local after = table.concat(LiveOpsRules.offList(state), ",")
		local changed = before ~= after
		local srcChanged = src ~= source
		current = state
		source = src
		if changed or srcChanged then
			log(string.format("%sflags why=%s source=%s rev=%d off=%s", LiveOpsRules.LOG, why, src, state.rev, if after == "" then "-" else after))
		end
		if changed then
			publishAttrs()
			if deps.onChange then
				pcall(deps.onChange, state)
			end
		end
	end

	function svc.refresh(why: string): LiveOpsRules.State
		local okCall, ok, doc = pcall(deps.read)
		local readOk = okCall and ok == true
		if not readOk then
			log(string.format("%sread failed why=%s: %s", LiveOpsRules.LOG, why, tostring(if okCall then doc else ok)))
		end
		local now = deps.now()
		local state, src, warnings = LiveOpsRules.resolve(readOk, if readOk then doc else nil, lastGood, lastGoodAt, now)
		for _, w in warnings do
			log(LiveOpsRules.LOG .. "doc " .. w)
		end
		if src == "store" then
			lastGood = state
			lastGoodAt = now
		end
		adopt(state, src, why)
		return current
	end

	-- A MessagingService nudge: re-read unless one just ran (or the nudge is older than what we hold).
	function svc.nudge(rev: any): boolean
		if type(rev) == "number" and rev <= current.rev and source == "store" then
			return false
		end
		local now = deps.now()
		if now - lastNudgeAt < LiveOpsRules.NUDGE_GAP then
			return false
		end
		lastNudgeAt = now
		svc.refresh("nudge")
		return true
	end

	function svc.state(): LiveOpsRules.State
		return current
	end

	function svc.source(): string
		return source
	end

	function svc.isOn(flag: string): boolean
		return LiveOpsRules.isOn(current, flag)
	end

	function svc.modeBlock(trackId: any, mode: any): string?
		return LiveOpsRules.modeBlock(current, trackId, mode, isClosing)
	end

	function svc.storeBlock(): string?
		if isClosing then
			return LiveOpsRules.REASON_CLOSING
		end
		if not LiveOpsRules.isOn(current, "store") then
			return LiveOpsRules.REASON_PAUSED
		end
		return nil
	end

	function svc.closing(): boolean
		return isClosing
	end

	function svc.setClosing(on: boolean)
		if isClosing == on then
			return
		end
		isClosing = on
		log(string.format("%sclosing=%s", LiveOpsRules.LOG, tostring(on)))
		if deps.onChange then
			pcall(deps.onChange, current)
		end
	end

	-- The admin's "/admin live ..." (the caller has already checked AdminConfig). Writes the row, adopts the result at
	-- once on this server and nudges the others.
	function svc.command(actorId: number, cmd: LiveOpsRules.Command): (boolean, string)
		if cmd.action == "status" then
			return true, LiveOpsRules.describe(current, source)
		elseif cmd.action == "help" then
			return true, LiveOpsRules.HELP
		end
		local flag: string? = nil
		local on = true
		if cmd.action == "set" then
			flag = cmd.flag
			on = cmd.on == true
			if flag == nil then
				return false, "no flag"
			end
		elseif cmd.action ~= "reset" then
			return false, "unknown live command"
		end
		local now = deps.now()
		local okCall, ok, doc = pcall(deps.update, function(old: any): any
			return LiveOpsRules.apply(old, flag, on, actorId, now)
		end)
		if not okCall or ok ~= true then
			return false, "Flag store unavailable, nothing changed: " .. tostring(if okCall then doc else ok)
		end
		local state = LiveOpsRules.parse(doc)
		lastGood = state
		lastGoodAt = now
		adopt(state, "store", "admin")
		if deps.publish then
			pcall(deps.publish, state.rev)
		end
		local what = if flag then string.format("%s %s", flag, if on then "ON" else "OFF") else "all flags ON"
		return true, string.format("%s. %s Other servers follow within %ds.", what, LiveOpsRules.describe(state, "store"), LiveOpsRules.POLL_SECONDS)
	end

	publishAttrs()
	return svc
end

------------------------------------------------------------------------------------------------ shutdown

export type ShutdownDeps = {
	players: () -> { Player },
	racing: () -> boolean,
	release: (player: Player, deadline: number) -> boolean, -- final save + unlock (SaveService.release); idempotent
	teleport: (players: { Player }) -> (boolean, string?), -- TeleportAsync(game.PlaceId, players)
	kick: (player: Player, message: string) -> (),
	notify: (kind: string, text: string?) -> (), -- "banner" (text nil clears) | "toast"
	setClosing: (on: boolean) -> (),
	clock: () -> number,
	sleep: (seconds: number) -> (),
	spawn: (fn: () -> ()) -> (),
	log: ((string) -> ())?,
	dryRun: boolean?, -- Studio QA: log the teleport and the kick instead of doing them
}

export type Shutdown = {
	soft: (restartIn: number?) -> string,
	close: () -> string,
	phase: () -> string,
}

function LiveOps.newShutdown(deps: ShutdownDeps): Shutdown
	local log = deps.log or function(line: string)
		print(line)
	end
	local S = LiveOpsRules.SHUTDOWN
	local sd = {} :: Shutdown
	local phase = "idle"
	local closed = false -- BindToClose took over: a soft run still waiting stops
	local saved: { [Player]: boolean } = {}

	local function setPhase(p: string, detail: string?)
		phase = p
		log(string.format("%sshutdown phase=%s%s", LiveOpsRules.LOG, p, if detail then " " .. detail else ""))
	end

	-- Final saves for everyone present, in parallel, within `seconds`. Returns how many landed.
	local function saveAll(seconds: number): (number, number)
		local list = deps.players()
		local deadline = deps.clock() + seconds
		local remaining = #list
		local good = 0
		for _, p in list do
			deps.spawn(function()
				local okCall, r = pcall(deps.release, p, deadline)
				local ok = okCall and r == true
				saved[p] = ok
				if ok then
					good += 1
				end
				remaining -= 1
			end)
		end
		while remaining > 0 and deps.clock() < deadline do
			deps.sleep(0.1)
		end
		return good, #list
	end

	local function kickAll(why: string)
		for _, p in deps.players() do
			local msg = LiveOpsRules.kickMessage(saved[p] == true)
			if deps.dryRun then
				log(string.format("%sshutdown dryRun kick user=%d saved=%s", LiveOpsRules.LOG, p.UserId, tostring(saved[p] == true)))
			else
				pcall(deps.kick, p, msg)
			end
		end
		log(string.format("%sshutdown kicked why=%s", LiveOpsRules.LOG, why))
	end

	-- ServerRestartScheduled. restartIn = seconds until Roblox restarts this server (nil = unknown). Runs to the end
	-- (call it in its own thread). Returns the final phase.
	function sd.soft(restartIn: number?): string
		if phase ~= "idle" then
			return phase
		end
		local t0 = deps.clock()
		local restartAt = if type(restartIn) == "number" then t0 + math.max(0, restartIn) else nil
		local moveByAt = LiveOpsRules.moveBy(t0, restartAt)
		setPhase("notice", string.format("moveIn=%.0f", moveByAt - t0))
		deps.setClosing(true)
		deps.notify("banner", LiveOpsRules.TEXT.softBanner)
		deps.notify("toast", LiveOpsRules.TEXT.softToast)
		setPhase("races")
		while not LiveOpsRules.readyToMove(deps.clock(), t0, moveByAt, deps.racing()) do
			if closed then
				return phase -- BindToClose took over
			end
			deps.sleep(S.POLL)
		end
		if closed then
			return phase
		end
		setPhase("save", if deps.racing() then "raceCut=1" else "raceCut=0")
		deps.notify("toast", LiveOpsRules.TEXT.moving)
		local good, total = saveAll(S.SAVE_SECONDS)
		log(string.format("%sshutdown saved=%d/%d", LiveOpsRules.LOG, good, total))
		setPhase("move")
		local list = deps.players()
		if #list > 0 then
			if deps.dryRun then
				log(string.format("%sshutdown dryRun teleport players=%d", LiveOpsRules.LOG, #list))
			else
				local okCall, ok, err = pcall(deps.teleport, list)
				if not (okCall and ok) then
					log(string.format("%sshutdown teleport failed: %s; retry in %ds", LiveOpsRules.LOG, tostring(if okCall then err else ok), S.RETRY_GAP))
					deps.sleep(S.RETRY_GAP)
					local again = deps.players()
					if #again > 0 then
						local okCall2, ok2, err2 = pcall(deps.teleport, again)
						if not (okCall2 and ok2) then
							log(string.format("%sshutdown teleport failed again: %s", LiveOpsRules.LOG, tostring(if okCall2 then err2 else ok2)))
							setPhase("kick")
							kickAll("teleportFailed")
							setPhase("done")
							return phase
						end
					end
				end
				-- Teleports take a few seconds; anyone still here after KICK_AFTER gets the friendly kick.
				local waitUntil = deps.clock() + S.KICK_AFTER
				while #deps.players() > 0 and deps.clock() < waitUntil do
					deps.sleep(S.POLL)
				end
			end
		end
		setPhase("kick")
		kickAll("stragglers")
		setPhase("done")
		return phase
	end

	-- BindToClose: toast, final saves, friendly kick. Returns "done".
	function sd.close(): string
		if phase == "done" then
			return phase
		end
		closed = true
		setPhase("closing")
		deps.setClosing(true)
		deps.notify("toast", LiveOpsRules.TEXT.closeToast)
		local good, total = saveAll(S.CLOSE_SAVE_SECONDS)
		log(string.format("%sshutdown saved=%d/%d", LiveOpsRules.LOG, good, total))
		kickAll("close")
		setPhase("done")
		return phase
	end

	function sd.phase(): string
		return phase
	end

	return sd
end

------------------------------------------------------------------------------------------------ live wiring

local defaultService: Service? = nil

-- Module-level reads for the hooks. Fail OPEN: before init (or if init failed) every feature is ON and nothing closes.
function LiveOps.isOn(flag: string): boolean
	local svc = defaultService
	return svc == nil or svc.isOn(flag)
end

function LiveOps.closing(): boolean
	local svc = defaultService
	return svc ~= nil and svc.closing()
end

function LiveOps.service(): Service?
	return defaultService
end

-- Call once from the server entry script after TrackDirector, Economy, StormCup and SaveService are up.
function LiveOps.init(): Service
	local existing = defaultService
	if existing then
		return existing
	end
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local HttpService = game:GetService("HttpService")
	local studio = RunService:IsStudio()
	local store: any = nil
	pcall(function()
		store = game:GetService("DataStoreService"):GetDataStore(LiveOpsRules.STORE_NAME)
	end)
	local MessagingService: any = nil
	pcall(function()
		MessagingService = game:GetService("MessagingService")
	end)
	local TrackDirector = require(script.Parent.TrackDirector) :: any
	local Economy = require(script.Parent.Economy) :: any

	-- TG-2 (Studio only): without DataStore API access the flag row cannot be read or written, so every feature stays ON
	-- and "/admin live ..." answers "Flag store unavailable". In Studio the row then lives in memory instead, the same
	-- as SaveService's mock; workspace QALiveOpsMemory = true forces that even when the DataStore works (no real flag
	-- row is touched). A live server never takes this path: `memoryMode` is false unless RunService:IsStudio().
	local QAHooksRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("QAHooksRules")) :: any
	local memoryRow: any = nil
	local probeFailed = false
	if studio then
		if store then
			local okProbe = pcall(function()
				store:GetAsync(LiveOpsRules.KEY)
			end)
			probeFailed = not okProbe
		else
			probeFailed = true
		end
		if probeFailed then
			print(LiveOpsRules.LOG .. "Studio without DataStore API access; flags use an in-memory row")
		end
	end
	local function memoryMode(): boolean
		return studio and (probeFailed or workspace:GetAttribute(QAHooksRules.LIVEOPS_MEMORY_ATTR) == true)
	end
	local function copyDoc(v: any): any
		if type(v) ~= "table" then
			return v
		end
		local out = {}
		for k, x in v do
			out[k] = copyDoc(x)
		end
		return out
	end

	local svc = LiveOps.new({
		read = function(): (boolean, any)
			if memoryMode() then
				return true, copyDoc(memoryRow)
			end
			if not store then
				return false, "no DataStore"
			end
			return true, store:GetAsync(LiveOpsRules.KEY)
		end,
		update = function(transform: (any) -> any): (boolean, any)
			if memoryMode() then
				local new = transform(copyDoc(memoryRow))
				if new ~= nil then
					memoryRow = copyDoc(new)
				end
				return true, copyDoc(memoryRow)
			end
			if not store then
				return false, "no DataStore"
			end
			return true, store:UpdateAsync(LiveOpsRules.KEY, transform)
		end,
		publish = function(rev: number)
			if MessagingService then
				MessagingService:PublishAsync(LiveOpsRules.TOPIC, HttpService:JSONEncode({ rev = rev }))
			end
		end,
		now = os.time,
		setAttr = function(name: string, value: any)
			workspace:SetAttribute(name, value)
		end,
		onChange = function(_state: LiveOpsRules.State)
			-- The board's lock lines and the battle buttons follow the new flags without a rejoin.
			for _, p in Players:GetPlayers() do
				pcall(TrackDirector.republish, p)
			end
		end,
	})
	defaultService = svc
	Economy.liveCheck = svc.storeBlock
	TrackDirector.liveBlock = svc.modeBlock
	-- A closing server also holds lobby launches and FLY AGAIN (the Storm Cup hold path; its toast shows the reason).
	-- Chained after StormCup's hook, so the cup lobby minute still holds as before.
	local prevHold = TrackDirector.holdRequests
	TrackDirector.holdRequests = function(): string?
		if svc.closing() then
			return LiveOpsRules.REASON_CLOSING
		end
		return if prevHold then prevHold() else nil
	end

	svc.refresh("boot")
	if MessagingService then
		task.spawn(function()
			local ok, err = pcall(function()
				MessagingService:SubscribeAsync(LiveOpsRules.TOPIC, function(message: any)
					local rev: any = nil
					pcall(function()
						local data = HttpService:JSONDecode(message.Data)
						rev = if type(data) == "table" then data.rev else nil
					end)
					task.spawn(svc.nudge, rev)
				end)
			end)
			if not ok then
				print(string.format("%ssubscribe failed: %s (polling only)", LiveOpsRules.LOG, tostring(err)))
			end
		end)
	end
	task.spawn(function()
		while true do
			task.wait(LiveOpsRules.POLL_SECONDS)
			svc.refresh("poll")
		end
	end)

	-- Shutdown
	local SaveService = require(script.Parent.SaveService) :: any
	local toastSeq = 0
	local function shutdownDeps(dryRun: boolean): ShutdownDeps
		return {
			players = function(): { Player }
				return Players:GetPlayers()
			end,
			racing = function(): boolean
				local mode = workspace:GetAttribute("RaceMode")
				if mode == nil or mode == "hub" then
					return false
				end
				return TrackDirector.allFinishedAt == nil
			end,
			release = function(player: Player, deadline: number): boolean
				if dryRun then
					-- Studio QA keeps the session: a flush (write, lock kept) instead of the final release.
					return SaveService.flush(player, math.max(1, deadline - os.clock()))
				end
				return SaveService.service().release(player, deadline)
			end,
			teleport = function(list: { Player }): (boolean, string?)
				local TeleportService = game:GetService("TeleportService")
				local ok, err = pcall(function()
					TeleportService:TeleportAsync(game.PlaceId, list)
				end)
				return ok, if ok then nil else tostring(err)
			end,
			kick = function(player: Player, message: string)
				player:Kick(message)
			end,
			notify = function(kind: string, text: string?)
				if kind == "banner" then
					workspace:SetAttribute(LiveOpsRules.ATTR_NOTICE, text)
				else
					toastSeq += 1
					workspace:SetAttribute("ServerToast", string.format("%d|%s", toastSeq, text or ""))
				end
			end,
			setClosing = svc.setClosing,
			clock = os.clock,
			sleep = function(s: number)
				task.wait(s)
			end,
			spawn = function(fn: () -> ())
				task.spawn(fn)
			end,
			dryRun = dryRun,
		}
	end
	local shutdown = LiveOps.newShutdown(shutdownDeps(false))
	game:BindToClose(function()
		if studio then
			return -- Studio stop: SaveService's own BindToClose saves; no kick into the Studio session
		end
		shutdown.close()
	end)
	local okEvent, errEvent = pcall(function()
		(game :: any).ServerRestartScheduled:Connect(function(restartTime: any, reason: any)
			local restartIn: number? = nil
			pcall(function()
				restartIn = restartTime.UnixTimestamp - os.time()
			end)
			print(string.format("%srestart scheduled in=%s reason=%s", LiveOpsRules.LOG, tostring(restartIn), tostring(reason)))
			task.spawn(shutdown.soft, restartIn)
		end)
	end)
	if not okEvent then
		print(string.format("%sno ServerRestartScheduled (%s): BindToClose path only", LiveOpsRules.LOG, tostring(errEvent)))
	end
	if studio then
		-- Studio QA: the soft sequence with the teleport and kick logged, not done.
		workspace:GetAttributeChangedSignal("LiveOpsSoftQA"):Connect(function()
			if workspace:GetAttribute("LiveOpsSoftQA") == true then
				local qa = LiveOps.newShutdown(shutdownDeps(true))
				task.spawn(function()
					qa.soft(workspace:GetAttribute("LiveOpsSoftQARestartIn") :: number?)
					-- The QA run leaves the server playable: hold lifted, banner cleared.
					svc.setClosing(false)
					workspace:SetAttribute(LiveOpsRules.ATTR_NOTICE, nil)
					workspace:SetAttribute("LiveOpsSoftQA", nil)
				end)
			end
		end)
	end
	print(string.format("%sinit source=%s %s", LiveOpsRules.LOG, svc.source(), LiveOpsRules.describe(svc.state(), svc.source())))
	return svc
end

return LiveOps
