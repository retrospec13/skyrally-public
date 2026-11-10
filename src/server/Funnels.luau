--!strict
-- Analytics funnels and the first-session flag, server side only (TEST_LIST_LAUNCH L27; audit M3).
--   * Onboarding funnel, first session of an account: 1 joined, 2 first move, 3 reached portal, 4 race started, 5 first
--     finish, 6 first token, 7 second race (AnalyticsService:LogOnboardingFunnelStepEvent).
--   * Repeating "race" funnel: portal or board pick -> countdown -> finish -> next action (LogFunnelStepEvent, one session
--     id per race).
--   * Load time (LogCustomEvent): seconds from join to the saved profile and to the first spawn the player saw.
--   * Frame time (LogCustomEvent, perf review v21 PF-22): one p50 and one p95 in ms per race per player, sent by
--     client/FrameGovernor at its finish, cleaned by shared/GraphicsLodRules.cleanReport, with the track, the mode and
--     the device tier word (desktop / phone, _low with LOW GRAPHICS) as the three fields.
--   * Client memory (LogCustomEvent, audit T1-4): the same finish also sends the race's peak and p95 MB ("mem"), cleaned
--     by shared/ErrorReporterRules.cleanMem, logged as client_mem_peak_mb and client_mem_p95_mb with the same fields.
-- The rules (step table, dedupe, field whitelist) are shared/OnboardingRules, specced in tools/tests/onboarding_spec.luau.
-- Events come from the server's own flow through Funnels.hook (TrackDirector and RaceManager call it); the client only
-- reports "ready" and "moved" on OnboardingRemote, which are deduped here and can only add a step to its own player.
-- Every Roblox call is pcall-wrapped (analytics never touches a race) and no event carries a name, a user id or text:
-- only a track id, a mode and one detail word, cleaned by OnboardingRules.fields.
-- The first race to reach GO also saves the "onboarded" flag (SaveService.markOnboarded, the settings slot), so the
-- guide shows once per account. The client reads the Onboarded attribute SaveService replicates.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local ErrorReporterRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ErrorReporterRules"))
local GraphicsLodRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GraphicsLodRules"))
local OnboardingRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("OnboardingRules"))
local ProgressionRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProgressionRules"))
local ExplainerRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ExplainerRules"))
-- Per group (systems audit v32 T0-2): a countdown belongs to the race whose scope fired it, so it opens and closes only
-- that race's players; a client report is tagged with the reporter's own race. Pass-throughs on the single path.
local RaceScope = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceScope"))
local RaceAttr = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceAttr"))
local ModeScopeRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ModeScopeRules"))
local SaveService = require(script.Parent.SaveService)

local Funnels = {}

local LOG = "[SkyRally][FUNNEL] "
local FIELD_KEYS = { "CustomField01", "CustomField02", "CustomField03" }
local CLIENT_GAP = 1 -- seconds between two remote events from one player
local FRAME_GAP = 30 -- seconds between two frame reports from one player (one per race; a race is longer)

local joinedAt: { [Player]: number } = {}
local lastClient: { [Player]: number } = {}
local readyLogged: { [Player]: boolean } = {}
local lastFrame: { [Player]: number } = {}
local lastMem: { [Player]: number } = {}
local countdownSeq = 0
local countdownOf: { [number]: number } = {} -- RaceScope id -> its latest countdown's seq
local lastExplain: { [Player]: number } = {}
-- Players whose race reached GO and has not finished: a Fail event when the next countdown, the hub or a leave ends it.
local openRace: { [Player]: { track: string?, mode: string? } } = {}
local EXPLAIN_GAP = 0.5
local tracker: OnboardingRules.Tracker? = nil
local progressionSink: ProgressionRules.Sink? = nil

-- Roblox allows three custom fields per event; the order is fixed (track, mode, detail) so a dashboard column keeps its
-- meaning.
local function customFields(f: OnboardingRules.Fields): { [string]: any }?
	local out: { [string]: any } = {}
	local any = false
	for i, v in { f.track, f.mode, f.detail } do
		if v ~= nil then
			local key = (Enum.AnalyticsCustomFieldKeys :: any)[FIELD_KEYS[i]]
			if key then
				out[key.Name] = v
				any = true
			end
		end
	end
	return if any then out else nil
end

-- T1-5: the telemetry kill switch (server/LiveOps; fail open when it is not up). Log lines still print.
local function telemetryOn(): boolean
	local ok, on = pcall(function(): boolean
		return (require(script.Parent.LiveOps) :: any).isOn("telemetry")
	end)
	return not ok or on ~= false
end

local function liveSink(): OnboardingRules.Sink
	local AnalyticsService = game:GetService("AnalyticsService")
	return {
		onboarding = function(player, step, name, fields)
			if not telemetryOn() then
				return
			end
			pcall(function()
				AnalyticsService:LogOnboardingFunnelStepEvent(player, step, name, customFields(fields))
			end)
		end,
		funnel = function(player, funnel, session, step, name, fields)
			if not telemetryOn() then
				return
			end
			pcall(function()
				AnalyticsService:LogFunnelStepEvent(player, funnel, session, step, name, customFields(fields))
			end)
		end,
		custom = function(player, name, value, fields)
			if not telemetryOn() then
				return
			end
			pcall(function()
				AnalyticsService:LogCustomEvent(player, name, value, customFields(fields))
			end)
		end,
	}
end

-- Roblox's LogProgression*Event(player, progressionPathName, level, levelName, customFields). The level is the 1..99 number
-- from ProgressionRules. pcall-wrapped by ProgressionRules.emit.
local function liveProgressionSink(): ProgressionRules.Sink
	local AnalyticsService = game:GetService("AnalyticsService") :: any
	return {
		start = function(player, path, level, levelName, fields)
			if not telemetryOn() then
				return
			end
			AnalyticsService:LogProgressionStartEvent(player, path, level, levelName, customFields(fields))
		end,
		complete = function(player, path, level, levelName, fields)
			if not telemetryOn() then
				return
			end
			AnalyticsService:LogProgressionCompleteEvent(player, path, level, levelName, customFields(fields))
		end,
		fail = function(player, path, level, levelName, fields)
			if not telemetryOn() then
				return
			end
			AnalyticsService:LogProgressionFailEvent(player, path, level, levelName, customFields(fields))
		end,
	}
end

-- A progression event from anywhere on the server: kind "unlock" (data.key = SaveService's newly opened id) or "badge"
-- (data.key = badge key). Never throws.
function Funnels.progression(kind: string, player: Player?, data: any)
	local sink = progressionSink
	if not sink or not player then
		return
	end
	local d: any = if type(data) == "table" then data else {}
	local ev = if kind == "unlock" then ProgressionRules.unlock(d.key) elseif kind == "badge" then ProgressionRules.badge(d.key) else nil
	ProgressionRules.emit(sink, player, ev)
end

local function failOpenRace(player: Player)
	local open = openRace[player]
	openRace[player] = nil
	local sink = progressionSink
	if open and sink then
		ProgressionRules.emit(sink, player, ProgressionRules.raceFinish(open.track, open.mode, nil, false, false))
	end
end

local function newId(): string
	local ok, id = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	return if ok then id else tostring(os.time()) .. "-" .. tostring(math.random(1, 1e9))
end

function Funnels.tracker(): OnboardingRules.Tracker?
	return tracker
end

local function markOnboarded(player: Player)
	local ok, err = pcall(SaveService.markOnboarded, player)
	if not ok then
		warn(LOG .. "onboarded flag failed: " .. tostring(err))
	end
end

-- Events from the server's own flow. event: "pick" (a portal or the board; data.track, data.mode, data.via), "countdown" (a race
-- loaded or replayed for everyone; data.track, data.mode, data.hold seconds to GO), "finish" (data.track, data.mode,
-- data.token = this finish awarded a Sky Token) and "next" (FLY AGAIN or HUB; data.choice). Never throws.
function Funnels.hook(event: string, player: Player?, data: any)
	local t = tracker
	if not t then
		return
	end
	local ok, err = pcall(function(): any
		local d: any = if type(data) == "table" then data else {}
		if event == "pick" and player then
			t.pick(player, OnboardingRules.fields(d.track, d.mode or "race", d.via))
		elseif event == "countdown" then
			local mode = d.mode
			local scopeId = RaceScope.current()
			local present = RaceScope.players(Players:GetPlayers())
			-- Whatever race was still open for a player of this race ended without a finish (DNF). Per group another
			-- group's racers are not in this countdown.
			local inThis: { [Player]: boolean }? = nil
			if RaceScope.enabled() then
				local set: { [Player]: boolean } = {}
				for _, p in present do
					set[p] = true
				end
				inThis = set
			end
			for p in openRace do
				if inThis == nil or inThis[p] then
					failOpenRace(p)
				end
			end
			-- The hub has no race, and battles are their own mode with their own results.
			if mode == "hub" or mode == "battle" then
				return nil
			end
			countdownSeq += 1
			local seq = countdownSeq
			countdownOf[scopeId] = seq
			local fields = OnboardingRules.fields(d.track, mode, nil)
			for _, p in present do
				t.countdown(p, fields)
			end
			local hold = if type(d.hold) == "number" and d.hold == d.hold then math.clamp(d.hold, 0, 30) else 0
			task.delay(hold, ModeScopeRules.bind(function()
				-- A newer countdown (replay, another switch) or a return to the hub means this race never started.
				if seq ~= countdownOf[scopeId] or RaceAttr.here("RaceMode") == "hub" then
					return
				end
				for _, p in RaceScope.players(Players:GetPlayers()) do
					t.go(p, fields)
					openRace[p] = { track = fields.track, mode = fields.mode }
					if progressionSink then
						ProgressionRules.emit(progressionSink, p, ProgressionRules.raceStart(fields.track, mode))
					end
					if OnboardingRules.marksOnboarded(mode) then
						markOnboarded(p)
					end
				end
			end))
		elseif event == "finish" and player then
			t.finish(player, OnboardingRules.fields(d.track, d.mode, nil), d.token == true)
			openRace[player] = nil
			if progressionSink then
				ProgressionRules.emit(progressionSink, player, ProgressionRules.raceFinish(d.track, d.mode, d.rank, true, d.token == true))
			end
		elseif event == "next" and player then
			local choice = if d.choice == "again" then "again" else "hub"
			t.next(player, choice, OnboardingRules.fields(d.track, d.mode, nil))
		end
		return nil
	end)
	if not ok then
		warn(LOG .. event .. " failed: " .. tostring(err))
	end
end

-- A client's per-race frame report: its own gap (it lands right at a finish, next to other client events), dropped
-- whole when any value fails the rules.
local function onFrameReport(t: OnboardingRules.Tracker, player: Player, p50: any, p95: any, tier: any)
	local now = os.clock()
	if now - (lastFrame[player] or -math.huge) < FRAME_GAP then
		return
	end
	local a, b, word = GraphicsLodRules.cleanReport(p50, p95, tier)
	if not a or not b or not word then
		return
	end
	lastFrame[player] = now
	local fields = OnboardingRules.fields(RaceAttr.get("ActiveTrackId", player), RaceAttr.get("RaceMode", player), word)
	t.custom(player, OnboardingRules.EVENT_FRAME_P50, a, fields)
	t.custom(player, OnboardingRules.EVENT_FRAME_P95, b, fields)
end

-- A client's per-race memory report: its own gap, dropped whole when any value fails the rules.
local function onMemReport(t: OnboardingRules.Tracker, player: Player, peak: any, p95: any, tier: any)
	local now = os.clock()
	if now - (lastMem[player] or -math.huge) < FRAME_GAP then
		return
	end
	local a, b = ErrorReporterRules.cleanMem(peak, p95)
	if not a or not b or type(tier) ~= "string" or not GraphicsLodRules.TIERS[tier] then
		return
	end
	lastMem[player] = now
	local fields = OnboardingRules.fields(RaceAttr.get("ActiveTrackId", player), RaceAttr.get("RaceMode", player), tier)
	t.custom(player, ErrorReporterRules.EVENT_CLIENT_MEM_PEAK, a, fields)
	t.custom(player, ErrorReporterRules.EVENT_CLIENT_MEM_P95, b, fields)
end

-- A first-time explainer was answered (T1-15): a1 = topic id (ExplainerRules.TOPICS), a2 = true when "Skip tips" was pressed.
-- Only a known id is saved, once (SaveService.markExplained skips a repeat), with its own gap; the analytics line carries
-- the id only. A forged id or a flood changes nothing.
function Funnels.onExplained(t: OnboardingRules.Tracker, player: Player, id: any, skip: any)
	if not ExplainerRules.isId(id) then
		return
	end
	local now = os.clock()
	if now - (lastExplain[player] or -math.huge) < EXPLAIN_GAP then
		return
	end
	lastExplain[player] = now
	local skipAll = skip == true
	local ok, saved = pcall(SaveService.markExplained, player, id, skipAll)
	if not ok then
		warn(LOG .. "explained flag failed: " .. tostring(saved))
		return
	end
	if saved ~= true then
		return -- no loaded profile: nothing saved, nothing logged
	end
	t.custom(player, if skipAll then "explainer_skip" else "explainer_seen", 1, OnboardingRules.fields(nil, nil, id))
	if progressionSink then
		ProgressionRules.emit(progressionSink, player, ProgressionRules.explainer(id, skipAll))
	end
end

local function onClient(player: Player, action: any, a1: any, a2: any, a3: any)
	local t = tracker
	if not t or type(action) ~= "string" then
		return
	end
	if action == "frame" then
		onFrameReport(t, player, a1, a2, a3)
		return
	elseif action == "mem" then
		onMemReport(t, player, a1, a2, a3)
		return
	end
	if action == "explained" then
		Funnels.onExplained(t, player, a1, a2)
		return
	end
	local now = os.clock()
	if now - (lastClient[player] or -math.huge) < CLIENT_GAP then
		return
	end
	lastClient[player] = now
	if action == "moved" then
		t.moved(player)
	elseif action == "ready" and not readyLogged[player] then
		readyLogged[player] = true
		t.custom(player, OnboardingRules.EVENT_READY, now - (joinedAt[player] or now))
	end
end

function Funnels.init()
	if tracker then
		return
	end
	local t = OnboardingRules.newTracker(liveSink(), newId)
	tracker = t
	progressionSink = liveProgressionSink()

	local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not remotes then
		local folder = Instance.new("Folder")
		folder.Name = "SkyRallyRemotes"
		folder.Parent = ReplicatedStorage
		remotes = folder
	end
	local remote = (remotes :: Instance):FindFirstChild("OnboardingRemote") :: RemoteEvent?
	if not remote then
		local r = Instance.new("RemoteEvent")
		r.Name = "OnboardingRemote"
		r.Parent = remotes
		remote = r
	end
	(remote :: RemoteEvent).OnServerEvent:Connect(onClient)

	local function track(player: Player)
		joinedAt[player] = os.clock()
	end
	for _, p in Players:GetPlayers() do
		track(p)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(p: Player)
		failOpenRace(p)
		t.forget(p)
		joinedAt[p] = nil
		lastExplain[p] = nil
		lastClient[p] = nil
		readyLogged[p] = nil
		lastFrame[p] = nil
		lastMem[p] = nil
	end)

	-- Step 1 waits for the saved profile: only then is it known whether this is the account's first session. A load that
	-- fails never logs (no profile, no guide, no funnel).
	SaveService.onLoaded(function(player: Player)
		if not player.Parent then
			return
		end
		t.begin(player, not SaveService.isOnboarded(SaveService.get(player)))
		t.custom(player, OnboardingRules.EVENT_PROFILE_LOAD, os.clock() - (joinedAt[player] or os.clock()))
	end)
end

return Funnels
