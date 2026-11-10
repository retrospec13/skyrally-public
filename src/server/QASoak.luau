--!strict
-- Studio-only soak harness (audit T1-12): loops hub -> race -> results -> hub across maps for N cycles and samples the
-- server and every client at each step, so tools/soak.py can look for memory, instance and error growth that no
-- single-map check shows (MP-3: terrain left behind after a map switch). Pure rules: shared/SoakRules; documented in
-- docs/STUDIO_ROUND_V22.md section 1 (soak). Everything is behind RunService:IsStudio(): in a live server start()
-- returns before creating anything, so there is no attribute listener and no remote to find or abuse. It only asks the
-- TrackDirector for races and the hub the way the board does; it changes no driving or race rule and no map geometry,
-- and it leaves every feature switch as it is.
--   Solo / lane window (Play):  workspace attribute QASoakRun = '{"cycles":3}' (JSON, set from a Server-context command by
--       tools/soak.py). Progress goes to QASoakProgress, each sample to QASoakS<n> (JSON), then QASoakProgress = "done".
--   Multiplayer test: server/QAMultiplayer scenario "soak" calls QASoak.run itself with the real clients connected.
-- Client side: client/QAMultiplayerClient answers each workspace.QASoakSeq bump with frame times, memory and error counts
-- over the QASoakLog RemoteEvent.
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Stats = game:GetService("Stats")

local SoakRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoakRules"))

local QASoak = {}

type Deps = { TrackDirector: any }
type Sink = (sample: any) -> ()

local LOG = "[SkyRally][SOAK] "
local TAGS = { "Script", "LuaHeap", "Signals", "Instances", "PhysicsParts", "GraphicsTerrain", "TerrainVoxels", "GraphicsMeshParts", "GraphicsTexture", "Sounds" }

local running = false
local remote: RemoteEvent? = nil
local replies: { [number]: { [string]: any } } = {}

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

-- Error and warning lines since the last drain (the soak's own lines and Studio plugin stacks are not the game's).
local errCount, warnCount = 0, 0
local errLines: { string } = {}
local logConn: RBXScriptConnection? = nil
local function watchLog()
	if logConn then
		return
	end
	logConn = LogService.MessageOut:Connect(function(msg: string, kind: Enum.MessageType)
		if string.find(msg, LOG, 1, true) or string.find(msg, "Stack Begin", 1, true) then
			return
		end
		local name = string.match(msg, "Script '([^']+)'")
		if name and (string.find(name, "^user_") or string.find(name, "^s?a?builtin_")) then
			return
		end
		if kind == Enum.MessageType.MessageError then
			errCount += 1
			if #errLines < 20 then
				table.insert(errLines, msg)
			end
		elseif kind == Enum.MessageType.MessageWarning then
			warnCount += 1
		end
	end)
end

local function serverSample(): any
	local ws = 0
	for _ in workspace:GetDescendants() do
		ws += 1
	end
	local maps = workspace:FindFirstChild("Maps")
	local s: { [string]: any } = {
		memMb = Stats:GetTotalMemoryUsageMb(),
		instances = stat("InstanceCount"),
		wsInstances = ws,
		wsChildren = #workspace:GetChildren(),
		mapRoots = if maps then #maps:GetChildren() else 0,
		players = #Players:GetPlayers(),
		heartbeatMs = stat("HeartbeatTimeMs"),
		sendKbps = stat("DataSendKbps"),
		recvKbps = stat("DataReceiveKbps"),
		errors = errCount,
		warnings = warnCount,
		errorTail = SoakRules.errorTail(errLines),
	}
	for _, t in TAGS do
		s["tag_" .. t] = tagMb(t)
	end
	errCount, warnCount = 0, 0
	table.clear(errLines)
	return s
end

-- One sample point: bump workspace.QASoakSeq, sample the server, wait for every present client's reply.
local seq = 0
local function samplePoint(cfg: any, base: any): any
	seq += 1
	local mine = seq
	replies[mine] = {}
	local expected = {}
	for _, p in Players:GetPlayers() do
		table.insert(expected, p.Name)
	end
	workspace:SetAttribute("QASoakFrameSecs", cfg.frameSecs)
	workspace:SetAttribute(SoakRules.SEQ_ATTR, mine)
	local server = serverSample()
	local deadline = os.clock() + cfg.clientWait + cfg.frameSecs
	while os.clock() < deadline do
		local got: { [string]: boolean } = {}
		for name in replies[mine] do
			got[name] = true
		end
		if #SoakRules.missing(expected, got) == 0 then
			break
		end
		task.wait(0.25)
	end
	local rec = table.clone(base)
	rec.seq = mine
	rec.server = server
	rec.clients = replies[mine]
	rec.clientsMissing = SoakRules.missing(expected, (function()
		local got: { [string]: boolean } = {}
		for name in replies[mine] do
			got[name] = true
		end
		return got
	end)())
	replies[mine] = nil
	return rec
end

local function inHub(TD: any): boolean
	return TD.currentKey == TD.HUB_KEY and not TD.switching and workspace:GetAttribute("RaceMode") == "hub"
end

local function waitFor(cond: () -> boolean, timeout: number): boolean
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if cond() then
			return true
		end
		task.wait(0.5)
	end
	return false
end

-- The loop. Yields for the whole run; returns (ok, why). sink gets one record per sample point plus a final summary.
function QASoak.run(deps: Deps, cfg: any, sink: Sink): (boolean, string)
	if running then
		return false, "already_running"
	end
	running = true
	watchLog()
	local TD = deps.TrackDirector
	local ok, why = true, "ok"
	local t0 = os.clock()
	xpcall(function()
		if workspace:GetAttribute("PerGroupLive") == true then
			error("PER_GROUP is on: the soak drives the single-race server (RaceFlowRules.PER_GROUP is Studio-proven first)")
		end
		local steps = SoakRules.plan(cfg)
		print(string.format("%ssoak start: %d cycles x %d maps = %d steps", LOG, cfg.cycles, #cfg.maps, #steps))
		if not waitFor(function()
			return inHub(TD)
		end, cfg.hubWait) then
			error("the server is not in the hub at the start")
		end
		task.wait(5)
		sink(samplePoint(cfg, { step = 0, cycle = 0, map = "hub0", phase = "baseline", t = os.clock() - t0 }))
		local trackData = ServerStorage:FindFirstChild("TrackData")
		for _, step in steps do
			local base = { step = step.n, cycle = step.cycle, map = step.key }
			if trackData and not trackData:FindFirstChild(step.key) then
				sink({ step = step.n, cycle = step.cycle, map = step.key, phase = "skipped", note = "no TrackData for this key", t = os.clock() - t0 })
				continue
			end
			if not inHub(TD) then
				TD.returnToHub("soak")
				waitFor(function()
					return inHub(TD)
				end, cfg.hubWait)
			end
			local reqAt = os.clock()
			local asked = TD.requestRace(nil, step.key, "soak", "race")
			if not asked then
				local first = Players:GetPlayers()[1]
				asked = if first then TD.requestRace(first, step.key, "soak", "race") else false
			end
			local loaded = asked
				and waitFor(function()
					return TD.currentKey == step.key and not TD.switching
				end, 180)
			if not loaded then
				sink({ step = step.n, cycle = step.cycle, map = step.key, phase = "failed", note = "race did not load", t = os.clock() - t0 })
				continue
			end
			base.loadSecs = os.clock() - reqAt
			waitFor(function()
				local go = workspace:GetAttribute("RaceGoTime")
				return type(go) == "number" and go <= workspace:GetServerTimeNow()
			end, 60)
			task.wait(if cfg.raceSecs > 0 then math.min(15, cfg.raceSecs) else 15)
			base.phase = "race"
			base.t = os.clock() - t0
			sink(samplePoint(cfg, base))
			-- Results: the race ends by itself (AutoPilot) or after raceSecs; either way the hub follows.
			local timedOut = false
			if cfg.raceSecs > 0 then
				task.wait(math.max(0, cfg.raceSecs - 15))
			else
				timedOut = not waitFor(function()
					return TD.allFinishedAt ~= nil or TD.currentKey ~= step.key
				end, cfg.raceTimeout)
				if TD.allFinishedAt ~= nil and TD.currentKey == step.key then
					task.wait(3)
					local r = table.clone(base)
					r.phase = "results"
					r.t = os.clock() - t0
					sink(samplePoint(cfg, r))
				end
			end
			if not inHub(TD) then
				TD.returnToHub("soak")
			end
			local home = waitFor(function()
				return inHub(TD)
			end, cfg.hubWait)
			task.wait(5)
			local h = table.clone(base)
			h.phase = "hub"
			h.t = os.clock() - t0
			h.timedOut = timedOut
			h.home = home
			sink(samplePoint(cfg, h))
			print(string.format("%sstep %d/%d %s done (cycle %d)", LOG, step.n, #steps, step.key, step.cycle))
			if not home then
				error("the hub did not come back after " .. step.key)
			end
		end
	end, function(e: any)
		ok, why = false, tostring(e)
	end)
	running = false
	print(LOG .. "soak end: " .. why)
	return ok, why
end

function QASoak.ensureRemote()
	if remote then
		return
	end
	local r = Instance.new("RemoteEvent")
	r.Name = SoakRules.REMOTE_NAME
	r.Parent = ReplicatedStorage
	r.OnServerEvent:Connect(function(player: Player, msg: any)
		if type(msg) ~= "string" or #msg > 4000 then
			return
		end
		local okD, data = pcall(HttpService.JSONDecode, HttpService, msg)
		if okD and type(data) == "table" and type(data.seq) == "number" and replies[data.seq] then
			replies[data.seq][player.Name] = SoakRules.shape(data)
		end
	end)
	remote = r
end

local function encode(sample: any): string
	local json = HttpService:JSONEncode(SoakRules.shape(sample))
	if #json > SoakRules.MAX_JSON and type(sample) == "table" then
		local lean = table.clone(sample)
		lean.clients = nil
		lean.clientsDropped = true
		json = HttpService:JSONEncode(SoakRules.shape(lean))
	end
	return json
end

function QASoak.start(deps: Deps)
	if not SoakRules.allowed(RunService:IsStudio()) then
		return
	end
	QASoak.ensureRemote()
	workspace:GetAttributeChangedSignal(SoakRules.RUN_ATTR):Connect(function()
		local v = workspace:GetAttribute(SoakRules.RUN_ATTR)
		if type(v) ~= "string" then
			return
		end
		workspace:SetAttribute(SoakRules.RUN_ATTR, nil)
		local okD, raw = pcall(HttpService.JSONDecode, HttpService, v)
		local cfg, reason = SoakRules.parseConfig(if okD then raw else nil)
		if not cfg then
			workspace:SetAttribute(SoakRules.PROGRESS_ATTR, "error:config_" .. reason)
			return
		end
		task.spawn(function()
			local total = #SoakRules.plan(cfg)
			local n = 0
			workspace:SetAttribute(SoakRules.PROGRESS_ATTR, string.format("running 0/%d", total))
			local ok, why = QASoak.run(deps, cfg, function(sample: any)
				n += 1
				workspace:SetAttribute(SoakRules.sampleAttr(n), encode(sample))
				workspace:SetAttribute(SoakRules.PROGRESS_ATTR, string.format("running %d/%d samples=%d", sample.step or 0, total, n))
			end)
			workspace:SetAttribute(SoakRules.PROGRESS_ATTR, if ok then "done samples=" .. tostring(n) else "error:" .. string.sub(why, 1, 200))
		end)
	end)
	print(LOG .. "Studio soak harness on (workspace attribute " .. SoakRules.RUN_ATTR .. ")")
end

return QASoak
