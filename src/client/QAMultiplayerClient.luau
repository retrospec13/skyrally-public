--!strict
-- Studio-only client side of the two-client QA (server/QAMultiplayer, TEST_LIST L30-L32): while workspace.QAMP is set,
-- forward this client's errors to the server so they land in the EndTest result, and leave the session when the server
-- sets this player's QALeave (the leave-mid-race scenario), and run Shared.JitterProbe when the server sets
-- workspace.QAJitterSecs (the jitter scenario), and report its loading curtain while workspace.QAMPCurtain is set (the
-- pergroup scenario), and answer the soak harness (server/QASoak, tools/soak.py): each bump of workspace.QASoakSeq makes
-- this client sample frame times, memory, instance count and error lines and send them over the QASoakLog RemoteEvent.
-- Does nothing outside Studio.
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local QAMultiplayerClient = {}

local READY = "__QAMP_READY" -- sent over QAMPLog once this client is in control

local function isRobloxPlayerScript(msg: string): boolean
	-- CoreGui and its StarterScript tag their own errors "[Roblox]..." (a test session's CreatorType 0 breaks the player list).
	return string.find(msg, "[Roblox]", 1, true) == 1
		or string.find(msg, "PlayerScripts.ChatScript", 1, true) ~= nil
		or string.find(msg, "PlayerScripts.PlayerModule", 1, true) ~= nil
		or string.find(msg, "PlayerScripts.RbxCharacterSounds", 1, true) ~= nil
end

-- The first stack line of an error raised in a Studio plugin ("Script 'user_X.rbxmx...'", "builtin_", "sabuiltin_").
local function isPluginStack(msg: string): boolean
	local name = string.match(msg, "Script '([^']+)'")
	return name ~= nil and (string.find(name, "^user_") ~= nil or string.find(name, "^s?a?builtin_") ~= nil)
end

-- Soak sample (audit T1-12): runs for workspace.QASoakFrameSecs, never blocks the caller.
local function soakClient()
	local Stats = game:GetService("Stats")
	local errs, warns = 0, 0
	local tail: { string } = {}
	LogService.MessageOut:Connect(function(msg: string, kind: Enum.MessageType)
		if string.find(msg, "[SkyRally][SOAK]", 1, true) or string.find(msg, "Stack Begin", 1, true) or isRobloxPlayerScript(msg) or isPluginStack(msg) then
			return
		end
		if kind == Enum.MessageType.MessageError then
			errs += 1
			if #tail < 3 then
				table.insert(tail, string.sub(msg, 1, 160))
			end
		elseif kind == Enum.MessageType.MessageWarning then
			warns += 1
		end
	end)
	local function stat(name: string): number
		local ok, v = pcall(function()
			return (Stats :: any)[name]
		end)
		return if ok and type(v) == "number" then v else -1
	end
	local function tagMb(name: string): number
		local ok, v = pcall(function()
			return Stats:GetMemoryUsageMbForTag((Enum.DeveloperMemoryTag :: any)[name])
		end)
		return if ok and type(v) == "number" then v else -1
	end
	local busy = false
	workspace:GetAttributeChangedSignal("QASoakSeq"):Connect(function()
		local seq = workspace:GetAttribute("QASoakSeq")
		if type(seq) ~= "number" or busy then
			return
		end
		busy = true
		task.spawn(function()
			local secs = workspace:GetAttribute("QASoakFrameSecs")
			local dts: { number } = {}
			local conn = RunService.RenderStepped:Connect(function(dt: number)
				table.insert(dts, dt)
			end)
			task.wait(if type(secs) == "number" then secs else 3)
			conn:Disconnect()
			table.sort(dts)
			local sum = 0
			for _, d in dts do
				sum += d
			end
			local n = #dts
			local ws = 0
			for _ in workspace:GetDescendants() do
				ws += 1
			end
			local remote = ReplicatedStorage:FindFirstChild("QASoakLog")
			if remote and remote:IsA("RemoteEvent") then
				local reply = {
					seq = seq,
					frames = n,
					meanMs = if n > 0 then sum / n * 1000 else -1,
					p95Ms = if n > 0 then dts[math.max(1, math.floor(n * 0.95))] * 1000 else -1,
					worstMs = if n > 0 then dts[n] * 1000 else -1,
					memMb = Stats:GetTotalMemoryUsageMb(),
					instances = stat("InstanceCount"),
					wsInstances = ws,
					sendKbps = stat("DataSendKbps"),
					recvKbps = stat("DataReceiveKbps"),
					errors = errs,
					warnings = warns,
					errorTail = tail,
					tag_Script = tagMb("Script"),
					tag_Signals = tagMb("Signals"),
					tag_Instances = tagMb("Instances"),
					tag_GraphicsTexture = tagMb("GraphicsTexture"),
					tag_GraphicsMeshParts = tagMb("GraphicsMeshParts"),
					tag_GraphicsTerrain = tagMb("GraphicsTerrain"),
					tag_Sounds = tagMb("Sounds"),
				}
				errs, warns, tail = 0, 0, {}
				;(remote :: RemoteEvent):FireServer(game:GetService("HttpService"):JSONEncode(reply))
			end
			busy = false
		end)
	end)
end

function QAMultiplayerClient.init()
	if not RunService:IsStudio() then
		return
	end
	soakClient()
	task.spawn(function()
		local deadline = os.clock() + 30
		while workspace:GetAttribute("QAMP") ~= true do
			if os.clock() > deadline then
				return
			end
			task.wait(1)
		end
		local remote = ReplicatedStorage:WaitForChild("QAMPLog", 10) :: RemoteEvent?
		if remote then
			-- An error is held until its stack shows where it came from: Studio's own plugins load into every test
			-- client (the MCP plugin logs "loadstring() is not available" there), and their errors are not the game's.
			local pending: string? = nil
			local function flush()
				if pending then
					remote:FireServer(pending)
					pending = nil
				end
			end
			LogService.MessageOut:Connect(function(msg: string, kind: Enum.MessageType)
				if pending and string.find(msg, "Stack Begin", 1, true) then
					return
				end
				if pending and isPluginStack(msg) then
					pending = nil
					return
				end
				flush()
				-- Roblox's own scripts (CoreGui, legacy chat, PlayerModule) are not the game's either: the legacy ChatScript
				-- races CoreScripts on a late join ("CoreGuiChatConnections has not been registered").
				if kind == Enum.MessageType.MessageError and not isRobloxPlayerScript(msg) then
					pending = msg
					task.delay(1, flush)
				end
			end)
		end
		local player = Players.LocalPlayer
		-- In control (the loading screen is gone): the server's scenario waits for this before it acts, so a pad or an
		-- arch is not used by a car whose client is still loading.
		if remote then
			task.spawn(function()
				local deadline = os.clock() + 90
				while player:GetAttribute("LoadingDone") ~= true and os.clock() < deadline do
					task.wait(0.5)
				end
				remote:FireServer(READY)
			end)
		end
		-- The jitter scenario: record Shared.JitterProbe for the seconds the server asks, send the summary back.
		workspace:GetAttributeChangedSignal("QAJitterSecs"):Connect(function()
			local secs = workspace:GetAttribute("QAJitterSecs")
			if type(secs) ~= "number" or not remote then
				return
			end
			local log: RemoteEvent = remote
			task.spawn(function()
				local JitterProbe = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("JitterProbe")) :: any
				local okRun, summary = pcall(JitterProbe.run, secs)
				local okJ, json = pcall(function()
					return game:GetService("HttpService"):JSONEncode(if okRun then summary else { error = tostring(summary) })
				end)
				log:FireServer("__QAMP_JITTER " .. (if okJ then json else '{"error":"json"}'))
			end)
		end)
		-- The per-group scenario: report this client's own loading curtain (client/TrackFlow's Curtain frame) and seat
		-- on every change and every 2 s, so the server can tell what EACH client saw (the MCP bridge cannot capture
		-- the client windows of a multiplayer test).
		local function curtainLoop()
			local log: RemoteEvent? = remote
			if not log then
				return
			end
			local last, lastAt = "", -math.huge
			while workspace:GetAttribute("QAMPCurtain") == true do
				local pg = player:FindFirstChildOfClass("PlayerGui")
				local tf = pg and pg:FindFirstChild("SkyRallyTrackFlow")
				local c = tf and tf:FindFirstChild("Curtain")
				local up = c ~= nil and c:IsA("GuiObject") and c.Visible and c.BackgroundTransparency < 0.5
				local seat = player:GetAttribute("RaceInstanceId")
				local state = string.format('{"up":%s,"seat":%s}', tostring(up), if type(seat) == "number" then tostring(seat) else "null")
				if state ~= last or os.clock() - lastAt > 2 then
					last, lastAt = state, os.clock()
					log:FireServer("__QAMP_CURTAIN " .. state)
				end
				task.wait(0.2)
			end
		end
		workspace:GetAttributeChangedSignal("QAMPCurtain"):Connect(function()
			if workspace:GetAttribute("QAMPCurtain") == true then
				task.spawn(curtainLoop)
			end
		end)
		if workspace:GetAttribute("QAMPCurtain") == true then
			task.spawn(curtainLoop)
		end
		-- solo_start (TG-3): the server sets QAPick = <track id>; this client sends the same RequestRace the board's JOIN
		-- sends, so the lobby/warp that follows is the shipping path, not a server-side shortcut.
		player:GetAttributeChangedSignal("QAPick"):Connect(function()
			local id = player:GetAttribute("QAPick")
			if type(id) ~= "string" or id == "" then
				return
			end
			local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
			local tf = remotes and remotes:FindFirstChild("TrackFlowRemote")
			if tf and tf:IsA("RemoteEvent") then
				tf:FireServer("RequestRace", id, "race")
			end
		end)
		player:GetAttributeChangedSignal("QALeave"):Connect(function()
			if player:GetAttribute("QALeave") ~= true then
				return
			end
			local sts = game:GetService("StudioTestService") :: any
			local ok, can = pcall(function()
				return sts:CanLeaveTest()
			end)
			if ok and can then
				sts:LeaveTest()
			end
		end)
	end)
end

return QAMultiplayerClient
