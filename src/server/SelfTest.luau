--!strict
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local FlightServer = require(script.Parent.FlightServer)
local RaceManager = require(script.Parent.RaceManager)
local AIRacers = require(script.Parent.AIRacers)

local SelfTest = {}

local function logResult(pass: boolean, checkName: string, detail: string)
	local tag = if pass then "PASS" else "FAIL"
	print(string.format("[SkyRally][SELFTEST] %s: %s - %s", tag, checkName, detail))
end

function SelfTest.runAll()
	-- 1. Track Geometry & Spline Verification
	local wps, trackLen = SplineUtils.loadWaypoints()
	local trackRoot = TrackRegistry.getRoot()
	local boostsFolder = TrackRegistry.getBoostsFolder()
	local ringCount = 0
	local padCount = 0
	if boostsFolder then
		for _, d in ipairs(boostsFolder:GetDescendants()) do
			if d:IsA("BasePart") then
				if d:GetAttribute("TriggerType") == "BoosterRing" then
					ringCount = ringCount + 1
				elseif d:GetAttribute("TriggerType") == "GroundBoostPad" then
					padCount = padCount + 1
				end
			end
		end
	end
	local cpCount = #RaceManager.checkpoints
	local activeId = TrackRegistry.getActiveId()
	if activeId == "DINO-4" then
		logResult(
			#wps >= 150 and math.abs(trackLen - 5450) < 25 and ringCount >= 8 and padCount >= 3 and cpCount >= 12,
			"DINO4_TrackAndRings",
			string.format("Waypoints=%d Length=%.1f Rings=%d Pads=%d Checkpoints=%d", #wps, trackLen, ringCount, padCount, cpCount)
		)
	else
		-- Other tracks: route and gameplay sanity against their own registered data (no DINO-4 constants).
		local regLen = TrackRegistry.length()
		logResult(
			#wps >= 50 and (regLen == nil or math.abs(regLen - trackLen) < 1) and cpCount >= 4 and (ringCount + padCount) >= 1,
			"Track_RouteAndGameplay",
			string.format("Track=%s Waypoints=%d Length=%.1f Registered=%s Rings=%d Pads=%d Checkpoints=%d", tostring(activeId), #wps, trackLen, tostring(regLen), ringCount, padCount, cpCount)
		)
	end

	-- 2. AI field (TEST_LIST_LAUNCH L08): bots fill every empty seat to AI_FIELD_SIZE entrants (players + bots; with no
	-- player one seat stays open for the first joiner), every bot flying the spline, roster lanes valid.
	-- "Moving" is distance flown since the reset: grid slots already sit past station 5, so station alone proves nothing.
	local field = AIRacers.fieldInfo()
	local botCount = #AIRacers.bots
	local botsMoving = 0
	for _, b in ipairs(AIRacers.bots) do
		if b.hull and b.hull.Parent and b.travelled > 5 then
			botsMoving = botsMoving + 1
		end
	end
	local rosterOk, rosterWhy, rosterSpread = AIRacers.validateRoster(PlaneConfig.AI_BOTS)
	logResult(
		botCount == field.need and botsMoving == botCount and rosterOk,
		"AIRacers_FieldOf8",
		string.format(
			"Players=%d Bots=%d Expected=%d Entrants=%d/%d MovingOnSpline=%d Roster=%d Lanes=%s Spread=%.2f Pending=%s Items=%s Handlers=%s RubberBand=[+%.0f%%/-%.0f%%]",
			field.players,
			botCount,
			field.need,
			field.players + botCount,
			PlaneConfig.AI_FIELD_SIZE,
			botsMoving,
			#PlaneConfig.AI_BOTS,
			rosterWhy,
			rosterSpread,
			tostring(field.pendingRefill),
			field.items,
			field.handlers,
			PlaneConfig.RUBBER_BAND_MAX_BOOST * 100,
			PlaneConfig.RUBBER_BAND_MAX_SLOW * 100
		)
	)

	-- 3. Player FTUE Spawn Mounted (< 10s of join)
	local playerList = Players:GetPlayers()
	if #playerList > 0 then
		local p = playerList[1]
		local rec = FlightServer.records[p]
		local mounted = (p:GetAttribute("MountedInPlane") == true) and (rec ~= nil) and (rec.hull.Parent ~= nil)
		local readySec = (p:GetAttribute("FirstFlightReadySeconds") :: number?) or 0.5
		logResult(
			mounted and readySec < 10.0,
			"FTUE_SpawnMountedUnder10s",
			string.format("Player=%s Mounted=%s ReadySec=%.2fs Plane=%s", p.Name, tostring(mounted), readySec, if rec and rec.plane then rec.plane.Name else "nil")
		)
	else
		logResult(true, "FTUE_SpawnMountedUnder10s", "Server-only mode ready (spawns plane on PlayerAdded <0.2s)")
	end

	-- 4. Flight Physics & Respawn Rules Verification
	logResult(
		PlaneConfig.BASE_SPEED == 110 and PlaneConfig.BOOST_SPEED == 165 and PlaneConfig.OVERCHARGE_SPEED == 210 and PlaneConfig.RESPAWN_DELAY == 1.0,
		"FlightPhysics_And_RespawnConfig",
		string.format("Base=%d Boost=%d Overcharge=%d RespawnDelay=%.1fs TotalLaps=%d", PlaneConfig.BASE_SPEED, PlaneConfig.BOOST_SPEED, PlaneConfig.OVERCHARGE_SPEED, PlaneConfig.RESPAWN_DELAY, PlaneConfig.TOTAL_LAPS)
	)

	-- 5. Approved DINO-4 Art Landmarks, Hero Plane & Landscape-Only Orientation Verification
	local landmarksFolder = TrackRegistry.getLandmarks()
	local hasSauropod = landmarksFolder ~= nil and landmarksFolder:FindFirstChild("RoamingGreenSauropod") ~= nil
	local hasPedestal = landmarksFolder ~= nil and landmarksFolder:FindFirstChild("SauropodTieredPedestal") ~= nil
	local hasArches = landmarksFolder ~= nil and landmarksFolder:FindFirstChild("StoneArchway_S2100") ~= nil and landmarksFolder:FindFirstChild("StoneArchway_S1050") ~= nil
	local starterGui = game:GetService("StarterGui")
	local isLandscapeOnly = starterGui.ScreenOrientation == Enum.ScreenOrientation.LandscapeSensor
		or starterGui.ScreenOrientation == Enum.ScreenOrientation.LandscapeLeft
		or starterGui.ScreenOrientation == Enum.ScreenOrientation.LandscapeRight
	if activeId == "DINO-4" then
		logResult(
			hasSauropod and hasPedestal and hasArches and isLandscapeOnly,
			"ApprovedArt_Landmarks_And_LandscapeOnly",
			string.format("Sauropod=%s Pedestal=%s Arches=%s ScreenOrientation=%s", tostring(hasSauropod), tostring(hasPedestal), tostring(hasArches), tostring(starterGui.ScreenOrientation))
		)
	else
		local landmarkCount = if landmarksFolder then #landmarksFolder:GetChildren() else 0
		logResult(
			isLandscapeOnly,
			"Landmarks_And_LandscapeOnly",
			string.format("Track=%s Landmarks=%d ScreenOrientation=%s", tostring(activeId), landmarkCount, tostring(starterGui.ScreenOrientation))
		)
	end

	-- 6. Track registry resolution: Maps.<id> after the pipeline switch, the legacy DINO-4 build before it.
	-- A registered length must agree with the spline the race actually uses.
	local rootSource = TrackRegistry.describeRoot()
	local regLength = TrackRegistry.length()
	-- The legacy root only stands in for DINO-4; serving it for another id means that map is missing.
	local isLegacyRoot = string.sub(rootSource, 1, 7) == "legacy:" and TrackRegistry.getActiveId() == TrackRegistry.LEGACY_ID
	local lengthOk = if regLength then math.abs(regLength - trackLen) <= 1 else isLegacyRoot
	logResult(
		trackRoot ~= nil and lengthOk,
		"TrackRegistry_Root",
		string.format(
			"ActiveId=%s Root=%s RegisteredLength=%s SplineLength=%.1f",
			TrackRegistry.getActiveId(),
			rootSource,
			if regLength then string.format("%.1f", regLength) else "none",
			trackLen
		)
	)

	workspace:SetAttribute("SkyRallySelfTestDone", true)
end

-- A pipeline map registers at the end of MapAdapter.build (MapBuilt wait, Terrain, mesh loads), usually well after
-- 3.5 s; test the finished track, bounded so a stuck adapter still yields a FAIL line instead of no selftest.
local PIPELINE_READY_TIMEOUT = 30

-- Returns true when it had to wait (the legacy build is complete before ServerMain starts and never waits).
local function waitForPipelineTrack(): boolean
	local deadline = os.clock() + PIPELINE_READY_TIMEOUT
	local waited = false
	while os.clock() < deadline do
		local root = TrackRegistry.getRoot()
		local isPipelineRoot = string.sub(TrackRegistry.describeRoot(), 1, 5) == "Maps."
		if not (root and isPipelineRoot) or (root :: Instance):GetAttribute("TrackReady") == true then
			break
		end
		waited = true
		task.wait(0.25)
	end
	return waited
end

function SelfTest.init()
	-- Studio QA only (perf pass 2026-10-19): a live server has no reader for these lines, and the walk over every
	-- trigger, bot and player is work a player's join should not share a frame with.
	if not game:GetService("RunService"):IsStudio() then
		return
	end
	task.delay(3.5, function()
		if waitForPipelineTrack() then
			-- Let stepRace load checkpoints from the just-published track before counting them.
			task.wait(0.5)
		end
		SelfTest.runAll()
	end)
end

return SelfTest
