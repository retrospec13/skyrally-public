--!strict
-- Frame-time governor and per-race frame report (docs/audits/perf_review_v21.md PF-22). Rules: shared/GraphicsLodRules.
-- * Governor: every RenderStepped dt goes into a 1 ms histogram; each 8 s window is judged by its p95. Two slow windows
--   in a row (p95 above 40 ms, so a device under 25 fps for one frame in twenty for 16 s) cap Settings.particleScale()
--   at 0.4 for the rest of the session (Settings.capParticleScale: Vfx ambience and flames, AtmosphereFx, MapFxLod and
--   every burst follow at once). It never raises the scale again and never touches the saved LOW GRAPHICS setting.
--   Windows during a track switch are dropped, so a map load is never judged.
-- * Report: frames from GO to this player's finish go into a second histogram; at the finish (if at least ~10 s of
--   frames) the client sends p50 and p95 in ms and its tier word on OnboardingRemote ("frame"), once per race. The
--   server (server/Funnels) cleans it and logs two analytics custom events with the track and mode: real device
--   numbers, no name, no id.
-- * Memory (audit T1-4): from GO to the finish, Stats:GetTotalMemoryUsageMb once a second; at the same finish the client
--   sends its peak and p95 MB ("mem" on OnboardingRemote; shared/ErrorReporterRules cleans them, server/Funnels logs
--   client_mem_peak_mb and client_mem_p95_mb with the track, the mode and the tier word).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))
local Prof = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Prof"))
local Rules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GraphicsLodRules"))
local ErrRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ErrorReporterRules"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local LocalPlayer = Players.LocalPlayer

local FrameGovernor = {}

local REPORT_MODES = { race = true, quickrace = true, timetrial = true, coin = true, stormcup = true }

local window = Rules.newHist()
local windowClock = 0
local strikes = 0
local capped = false

local race = Rules.newHist()
local raceGo: number? = nil -- RaceGoTime the race histogram belongs to
local reported = false
local raceMem = ErrRules.newMem()
local memClock = 0

-- Attribute state, kept by change signals (no attribute reads per frame).
local switching = false
local goTime: number? = nil
local reportMode = false
local finished = false

local function send(p50: number, p95: number, memPeak: number?, memP95: number?)
	task.spawn(function()
		local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
		local remote = remotes and remotes:FindFirstChild("OnboardingRemote")
		if remote and remote:IsA("RemoteEvent") then
			local tier = Rules.tierWord(Settings.phoneTier(), Settings.lowGraphics())
			remote:FireServer("frame", p50, p95, tier)
			if memPeak and memP95 then
				remote:FireServer("mem", memPeak, memP95, tier)
			end
		end
	end)
end

local function sampleMem(dt: number)
	memClock += dt
	if memClock < 1 then
		return
	end
	memClock = 0
	pcall(function()
		ErrRules.addMem(raceMem, game:GetService("Stats"):GetTotalMemoryUsageMb())
	end)
end

local function stepGovernor(dt: number)
	if switching then
		Rules.clearHist(window)
		windowClock = 0
		return
	end
	Rules.addFrame(window, dt)
	windowClock += dt
	if windowClock < Rules.WINDOW then
		return
	end
	local p95 = Rules.percentile(window, 0.95)
	local act
	strikes, act = Rules.judge(strikes, p95, window.n)
	Rules.clearHist(window)
	windowClock = 0
	if act and not capped then
		capped = true
		Settings.capParticleScale(Rules.CAP_SCALE)
		print(string.format("[SkyRally][PERF] frame governor: p95 %d ms for %d windows, particle scale capped at %.1f", p95, strikes, Rules.CAP_SCALE))
	end
end

local function stepRace(dt: number)
	local go = goTime
	if not go or not reportMode then
		return
	end
	if go ~= raceGo then
		raceGo = go
		reported = false
		Rules.clearHist(race)
		ErrRules.clearMem(raceMem)
		memClock = 0
	end
	if reported or workspace:GetServerTimeNow() < go then
		return
	end
	if finished then
		reported = true
		if race.n >= Rules.MIN_RACE_FRAMES then
			local memPeak, memP95 = ErrRules.memSummary(raceMem)
			send(Rules.percentile(race, 0.5), Rules.percentile(race, 0.95), memPeak, memP95)
		end
		return
	end
	Rules.addFrame(race, dt)
	sampleMem(dt)
end

function FrameGovernor.init()
	local function refresh()
		switching = workspace:GetAttribute("TrackSwitching") == true
		local go = RaceAttr.mine("RaceGoTime")
		goTime = if type(go) == "number" then go else nil
		reportMode = REPORT_MODES[RaceAttr.mine("RaceMode")] == true
		finished = LocalPlayer:GetAttribute("RaceFinished") == true
	end
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(refresh)
	for _, name in { "RaceGoTime", "RaceMode" } do
		RaceAttr.changed(name, refresh)
	end
	LocalPlayer:GetAttributeChangedSignal("RaceFinished"):Connect(refresh)
	refresh()
	RunService.RenderStepped:Connect(Prof.wrap("SR_FrameGovernor", function(dt: number)
		stepGovernor(dt)
		stepRace(dt)
	end))
end

return FrameGovernor
