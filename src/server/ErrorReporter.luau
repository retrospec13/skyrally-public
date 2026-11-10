--!strict
-- Server error, memory and heartbeat telemetry (docs/audits/systems_audit_v32.md T1-4, error/memory part; rules:
-- shared/ErrorReporterRules, specced in tools/tests/error_reporter_spec.luau).
--   * ScriptContext.Error on the server: scrubbed, fingerprinted, de-duplicated and budgeted; a first sighting logs one
--     "[SkyRally][ERR] server <build> <kind> <source> <fp> x1: <msg>" line and one AnalyticsService custom event
--     (server_error; fields build, source, kind); repeats go out as one counted report per FLUSH_EVERY.
--   * Client relay (SkyRallyRemotes.ErrorRemote, sent by client/ErrorReporter): cleaned again, budgeted per player
--     (own budget per player, so one client cannot spend another's budget), logged as "client" lines and as
--     client_error events for that player.
--   * LogService warnings are counted only (in the summary line).
--   * Memory and heartbeat: Stats:GetTotalMemoryUsageMb every second and every Heartbeat dt; every SUMMARY_EVERY one
--     "[SkyRally][MEM] server ..." line with the memory peak/p95 and heartbeat p50/p95, plus server_mem_p95_mb and
--     server_heartbeat_p95_ms events.
-- Analytics custom events need a player: server-wide events (server errors, server memory) are logged against one
-- player present in the server (the oldest), or skipped when it is empty; the log line always prints. No event carries
-- a name, a user id or free text: the fields are the build label, a script name and a kind word.
-- Every handler is pcall-wrapped and re-entry guarded: telemetry never breaks the server.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BuildInfo = require(Shared:WaitForChild("BuildInfo"))
local GraphicsLodRules = require(Shared:WaitForChild("GraphicsLodRules"))
local Rules = require(Shared:WaitForChild("ErrorReporterRules"))

local ErrorReporter = {}

local SUMMARY_EVERY = 300 -- seconds between server memory / heartbeat summaries
local FIELD_KEYS = { "CustomField01", "CustomField02", "CustomField03" }

local build = "v0-dev"
local tracker: Rules.Tracker? = nil
local perPlayer: { [Player]: Rules.Budget } = {}
local warnCount = 0
local inHandler = false
local started = false

local function playerNames(): { string }
	local out = {}
	for _, p in Players:GetPlayers() do
		table.insert(out, p.Name)
		if p.DisplayName ~= p.Name then
			table.insert(out, p.DisplayName)
		end
	end
	return out
end

local function fields(a: string?, b: string?, c: string?): { [string]: any }?
	local out: { [string]: any } = {}
	for i, v in { a, b, c } do
		if v ~= nil then
			local key = (Enum.AnalyticsCustomFieldKeys :: any)[FIELD_KEYS[i]]
			if key then
				out[key.Name] = v
			end
		end
	end
	return out
end

local function custom(player: Player?, name: string, value: number, f: { [string]: any }?)
	local p = player or Players:GetPlayers()[1]
	if not p then
		return
	end
	-- T1-5 telemetry kill switch (server/LiveOps; fail open: before it is up, or if it errors, events still go).
	local okLive, on = pcall(function(): boolean
		return (require(script.Parent.LiveOps) :: any).isOn("telemetry")
	end)
	if okLive and on == false then
		return
	end
	pcall(function()
		game:GetService("AnalyticsService"):LogCustomEvent(p, name, value, f)
	end)
end

local function emit(origin: string, player: Player?, r: Rules.Report)
	print(Rules.line(origin, build, r))
	custom(player, if origin == "client" then Rules.EVENT_CLIENT else Rules.EVENT_SERVER, r.count, fields(build, r.source, r.kind))
end

local function onServerError(message: string, _trace: string, scr: Instance?)
	local t = tracker
	if not t or inHandler then
		return
	end
	inHandler = true
	pcall(function()
		local source = "unknown"
		if scr then
			source = Rules.sourceName((scr :: Instance):GetFullName())
		end
		local r = t.note("error", source, Rules.scrub(message, playerNames()))
		if r then
			emit("server", nil, r)
		end
	end)
	inHandler = false
end

local function onClientReport(player: Player, kind: any, source: any, fp: any, count: any, msg: any)
	pcall(function()
		local r = Rules.cleanClient(kind, source, fp, count, msg, playerNames())
		if not r then
			return
		end
		local b = perPlayer[player]
		if not b then
			b = Rules.newBudget({ now = os.clock })
			perPlayer[player] = b
		end
		-- The client already fingerprinted and de-duplicated (first sightings, then counted repeat flushes); the relay only
		-- enforces this player's window budget and session cap. (A tracker here would fold the fingerprint's digits and
		-- the count, so every repeat flush, and distinct errors whose fingerprints differ only in digits, were dropped.)
		if (b :: Rules.Budget).take() then
			emit("client", player, r)
		end
	end)
end

local function flushLoop()
	while true do
		task.wait(Rules.FLUSH_EVERY)
		local t = tracker
		if t then
			pcall(function()
				for _, r in t.flush() do
					emit("server", nil, r)
				end
			end)
		end
	end
end

local function statsLoop()
	local Stats = game:GetService("Stats")
	local mem = Rules.newMem()
	local hist = GraphicsLodRules.newHist()
	local sinceSample, sinceSummary = 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		GraphicsLodRules.addFrame(hist, dt)
		sinceSample += dt
		sinceSummary += dt
		if sinceSample >= 1 then
			sinceSample = 0
			pcall(function()
				Rules.addMem(mem, Stats:GetTotalMemoryUsageMb())
			end)
		end
		if sinceSummary < SUMMARY_EVERY then
			return
		end
		sinceSummary = 0
		pcall(function()
			local peak, p95 = Rules.memSummary(mem)
			local hb50 = GraphicsLodRules.percentile(hist, 0.5)
			local hb95 = GraphicsLodRules.percentile(hist, 0.95)
			local st = if tracker then (tracker :: Rules.Tracker).stats() else nil
			print(string.format("%sserver %s mem_peak=%s mem_p95=%s hb_p50=%dms hb_p95=%dms players=%d errors=%d sent=%d dropped=%d warns=%d",
				Rules.MEM_TAG, build, tostring(peak), tostring(p95), hb50, hb95, #Players:GetPlayers(),
				st and st.seen or 0, st and st.sent or 0, st and st.dropped or 0, warnCount))
			if p95 then
				custom(nil, Rules.EVENT_SERVER_MEM_P95, p95, fields(build, nil, nil))
			end
			if hist.n > 0 then
				custom(nil, Rules.EVENT_SERVER_FRAME_P95, hb95, fields(build, nil, nil))
			end
			Rules.clearMem(mem)
			GraphicsLodRules.clearHist(hist)
		end)
	end)
end

-- The build label every report carries ("v29-abc1234").
function ErrorReporter.build(): string
	return build
end

function ErrorReporter.init()
	if started then
		return
	end
	started = true
	build = Rules.buildLabel(BuildInfo.Commit, game.PlaceVersion)
	tracker = Rules.newTracker({ now = os.clock })

	game:GetService("ScriptContext").Error:Connect(onServerError)
	game:GetService("LogService").MessageOut:Connect(function(_message: string, kind: Enum.MessageType)
		if kind == Enum.MessageType.MessageWarning then
			warnCount += 1
		end
	end)

	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not remotes then
		local folder = Instance.new("Folder")
		folder.Name = "SkyRallyRemotes"
		folder.Parent = ReplicatedStorage
		remotes = folder
	end
	local remote = (remotes :: Instance):FindFirstChild(Rules.REMOTE) :: RemoteEvent?
	if not remote then
		local r = Instance.new("RemoteEvent")
		r.Name = Rules.REMOTE
		r.Parent = remotes
		remote = r
	end
	(remote :: RemoteEvent).OnServerEvent:Connect(onClientReport)
	Players.PlayerRemoving:Connect(function(p: Player)
		perPlayer[p] = nil
	end)

	task.spawn(flushLoop)
	statsLoop()
	print(string.format("%sreporter on, build %s", Rules.TAG, build))
end

return ErrorReporter
