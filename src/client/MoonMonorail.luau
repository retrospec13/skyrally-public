--!strict
-- Race the Moon Monorail (docs/REMARKABLE.md item 25), client only. The SPACE-4 monorail is no longer parked: the west
-- train shuttles along the viaduct between the two stations (the east train is the same train on its way back, so it
-- is hidden on this client). Its position is a pure function of server time (shared/SetPieceRules.monorailAt): every
-- client sees the same train in the same place with no network traffic. During a race the cycle is anchored to the
-- countdown: the train pulls out of the west station on the "3" with a departure chime and is level with the grid as
-- it passes over the start straight, so the whole field races it.
-- * The race: pass under the viaduct on the start straight (crossing A) while the eastbound train is near it and the
--   banner says "RACE THE MOON MONORAIL!". Reach the east crossing (B) before the train passes over it: "YOU BEAT THE
--   MOON MONORAIL! (+n s)" with a chime and confetti. If the train gets there first: two cheeky toots and "THE MOON MONORAIL WINS"
--   (toast). Judged on this client only (the Station attribute and server time); nothing is saved,
--   nothing is paid, no race state changes.
-- * Phone budget: one PivotTo per frame within 700 studs, 10 Hz to 2000, frozen beyond; nothing allocated per frame.
-- QA (Studio): workspace.MonorailTest = true starts a race against the train from where it is now.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Rules = require(Shared:WaitForChild("SetPieceRules"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local Kit = require(script.Parent:WaitForChild("MomentKit"))

local LocalPlayer = Players.LocalPlayer
local M = Rules.MONORAIL

local MoonMonorail = {}

local TrackFlow: any = nil
local RaceUI: any = nil

local RACE_MODES = { race = true, quickrace = true, timetrial = true, coin = true, stormcup = true }

local train: Model? = nil
local trainBase = CFrame.identity -- the parked west train's pivot (at M.restX)
local parked: Model? = nil
local conn: RBXScriptConnection? = nil
local pending = 0
local lastDir = 0

type Race = { trainAtB: number, startedAt: number }
local race: Race? = nil
local lastStation: number? = nil

local function epoch(): number
	local mode = RaceAttr.mine("RaceMode")
	local go = RaceAttr.mine("RaceGoTime")
	return Rules.monorailEpoch(if RACE_MODES[mode] and type(go) == "number" then go else nil)
end

local function trainCF(x: number, dir: number): CFrame
	-- the cyan-lit end (+X in the model) always leads
	local face = if dir < 0 then CFrame.Angles(0, math.pi, 0) else CFrame.identity
	return CFrame.new(x - M.restX, 0, 0) * trainBase * face
end

local function stamp(msg: string, color: Color3)
	if RaceUI and type(RaceUI.stamp) == "function" then
		pcall(RaceUI.stamp, msg, color, 1.6)
	end
end

local function toast(msg: string, color: Color3)
	if TrackFlow and type(TrackFlow.toast) == "function" then
		pcall(TrackFlow.toast, msg, color, 4)
	end
end

local function finishRace(won: boolean, margin: number)
	race = nil
	local now = workspace:GetServerTimeNow()
	local x = Rules.monorailAt(now, epoch())
	local where = Vector3.new(x, M.trainY + 4, M.viaductZ)
	if won then
		Kit.ui("monorail_win", "monorail_win", 0.9, 1)
		Kit.burst("duck", Kit.up(Kit.focus() + Vector3.yAxis * 6), 1)
		toast(Rules.monorailToast(true, margin), Color3.fromRGB(150, 240, 255))
	else
		Kit.sfx("monorail_toot", "monorail_toot", where, 1, 1, 1400)
		toast(Rules.monorailToast(false, margin), Color3.fromRGB(255, 170, 220))
	end
	print(string.format("[SkyRally][SETPIECE] monorail race %s margin=%.2f", if won then "won" else "lost", margin))
end

local function startRace(now: number, ep: number)
	local tB = Rules.monorailEastboundAt(M.crossB.x, now, ep)
	if not tB or tB <= now then
		return
	end
	race = { trainAtB = tB, startedAt = now }
	-- uifix: an upper-lane banner, not hero text over the road (owner rule: brief centre text, nothing over the road)
	toast("Race the monorail!", Color3.fromRGB(150, 240, 255))
	local x = Rules.monorailAt(now, ep)
	Kit.sfx("monorail_toot", "monorail_toot", Vector3.new(x, M.trainY + 4, M.viaductZ), 1, 1.1, 1400)
end

local function onStation()
	local st = LocalPlayer:GetAttribute("Station")
	local cur = if type(st) == "number" then st else nil
	local prev = lastStation
	lastStation = cur
	if not train or LocalPlayer:GetAttribute("RaceFinished") == true or not RACE_MODES[RaceAttr.mine("RaceMode")] then
		return
	end
	local now = workspace:GetServerTimeNow()
	local ep = epoch()
	if not race and Rules.crossedStation(prev, cur, M.crossA.station) then
		local x, dir = Rules.monorailAt(now, ep)
		if Rules.monorailRaceOn(x, dir) then
			startRace(now, ep)
		end
	elseif race and Rules.crossedStation(prev, cur, M.crossB.station) then
		local won, margin = Rules.monorailVerdict(now, race.trainAtB)
		finishRace(won, margin)
	end
end

local function step(dt: number)
	local t = train
	if not t or not t.Parent then
		return
	end
	local now = workspace:GetServerTimeNow()
	local ep = epoch()
	local x, dir = Rules.monorailAt(now, ep)
	-- departures chime from the train (heard near the stations and the start straight)
	if dir ~= 0 and lastDir == 0 then
		Kit.sfx("monorail_chime", "monorail_chime", Vector3.new(x, M.trainY + 4, M.viaductZ), 0.9, 1, 900)
	end
	lastDir = dir
	if race and now > race.trainAtB then
		finishRace(false, now - race.trainAtB)
	end
	pending += dt
	local d = (Vector3.new(x, M.trainY, M.viaductZ) - Kit.camPos()).Magnitude
	if d > 2000 or (d > 700 and pending < 0.1) then
		return
	end
	pending = 0
	t:PivotTo(trainCF(x, dir))
end

local function find(): (Model?, Model?)
	local root = TrackRegistry.getRoot()
	local first = root and root:FindFirstChild("MonorailTrain", true)
	if not first or not first.Parent then
		return nil, nil
	end
	local west: Model?, east: Model? = nil, nil
	for _, c in first.Parent:GetChildren() do
		if c.Name == "MonorailTrain" and c:IsA("Model") then
			if not west or c:GetPivot().X < west:GetPivot().X then
				if west then
					east = west
				end
				west = c
			else
				east = c
			end
		end
	end
	return west, east
end

local function stop()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	if parked and parked.Parent then
		Kit.hideModel(parked, false)
	end
	train, parked, race = nil, nil, nil
end

local token = 0
local function refresh()
	token += 1
	local my = token
	stop()
	if RaceAttr.mine("ActiveTrackId") ~= M.trackId or workspace:GetAttribute("TrackSwitching") == true then
		return
	end
	task.spawn(function()
		for _ = 1, 40 do
			if my ~= token then
				return
			end
			local west, east = find()
			if west then
				train = west
				trainBase = west:GetPivot()
				parked = east
				if east then
					Kit.hideModel(east, true)
				end
				lastDir = 0
				conn = RunService.Heartbeat:Connect(function(dt: number)
					local ok, err = pcall(function()
						step(dt)
					end)
					if not ok then
						warn("[SkyRally][SETPIECE] monorail: " .. tostring(err))
					end
				end)
				print(string.format("[SkyRally][SETPIECE] moon monorail running (period %.1f s, run %.1f s)", Rules.monorailPeriod(), Rules.monorailRunTime()))
				return
			end
			task.wait(0.5)
		end
	end)
end

function MoonMonorail.init(trackFlow: any, raceUI: any)
	TrackFlow = trackFlow
	RaceUI = raceUI
	RaceAttr.changed("ActiveTrackId", refresh)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(refresh)
	RaceAttr.changed("RaceGoTime", function()
		race = nil
	end)
	LocalPlayer:GetAttributeChangedSignal("Station"):Connect(onStation)
	workspace:GetAttributeChangedSignal("MonorailTest"):Connect(function()
		if workspace:GetAttribute("MonorailTest") == true then
			workspace:SetAttribute("MonorailTest", nil)
			startRace(workspace:GetServerTimeNow(), epoch())
		end
	end)
	refresh()
end

return MoonMonorail
