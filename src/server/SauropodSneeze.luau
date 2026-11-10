--!strict
-- The Sauropod Sneeze (docs/REMARKABLE.md item 11), server half. RaceManager's stepSauropodHazard hands its sway
-- pivot to apply() every Heartbeat and pivots the statue to what comes back, so this module owns only the sneeze:
-- * once per race (not the hub, not battles), when the race leader (players and bots) first passes the sneeze station
--   on lap random(2, 3), the statue inhales (1.2 s, head back 8 degrees), sneezes (0.25 s, snap forward 14 degrees and a
--   3-stud lunge) and recovers (1.5 s damped wobble). Pose math: shared/WorldMomentsRules.
-- * workspace attributes for every client (client/WorldMoments plays the sound, ash, embers, shake and hatchling):
--   SauropodHatchling (bool, rolled 1 in 20 and set at the inhale, before the snap), SauropodInhaleAt and
--   SauropodSneezeAt (workspace:GetServerTimeNow() at the inhale and at the snap).
-- * HeadOffset on the statue model (pivot space): from the plan if it sets one, else measured from the mesh once it has
--   loaded (the nose of StoneSauropodV2, WorldMomentsRules.NOSE_FRACTION), else from the highest fallback part.
-- * ReplicatedStorage.SauropodHatchlingTemplate: the Cinderwing boss mesh (BossConfig DINO model, already uploaded) at
--   0.15 scale, loaded once per server, for the 1-in-20 hatchling. If it cannot load, clients build a tiny stand-in.
-- Visual only: the statue and its pedestal never collide and nothing here touches a racer, so lap times are unchanged.
-- QA: workspace.TriggerSauropodSneeze = true (or "hatchling" to force the hatchling) sneezes now, in any mode.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("WorldMomentsRules"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local BossConfig = require(Shared:WaitForChild("BossConfig"))
local FlightServer = require(script.Parent.FlightServer)
local AIRacers = require(script.Parent.AIRacers)

local SauropodSneeze = {}

local TEMPLATE_NAME = "SauropodHatchlingTemplate"
local HATCHLING_SCALE = 0.15
local HEAD_RECHECK_SEC = 1

local plan: Rules.SneezePlan? = nil
local planKey: number? = nil
local planStatue: Model? = nil
local sequenceStart: number? = nil -- os.clock() of the running inhale
local snapped = false

local headStatue: Model? = nil
local headOffset: Vector3? = nil
local headSource = "none" -- "plan" | "mesh" | "fallback" | "none"
local headCheckedAt = -math.huge
local headDir = Vector3.new(-1, 0, 0)
local pitchAxis = Vector3.zAxis

local templateState = "none" -- "none" | "loading" | "ready" | "failed"

-- Measures the nose from the mesh, falling back to the highest part until a mesh appears (MapAdapter loads meshes after
-- the statue's fallback parts). A plan HeadOffset skips this (ensureHead).
local function measureHead(statue: Model): (Vector3?, string)
	local pivot = statue:GetPivot()
	for _, c in statue:GetChildren() do
		if c:IsA("MeshPart") then
			return pivot:PointToObjectSpace(c.CFrame:PointToWorldSpace(Rules.noseLocal(c.Size))), "mesh"
		end
	end
	local best: BasePart? = nil
	local bestTop = -math.huge
	for _, d in statue:GetDescendants() do
		if d:IsA("BasePart") then
			local top = d.Position.Y + d.Size.Y * 0.5
			if top > bestTop then
				best, bestTop = d, top
			end
		end
	end
	if best then
		return pivot:PointToObjectSpace(best.Position), "fallback"
	end
	return nil, "none"
end

local function ensureHead(statue: Model)
	if headStatue ~= statue then
		headStatue = statue
		headOffset = nil
		headSource = "none"
		headCheckedAt = -math.huge
		-- On first sight, a HeadOffset already on the model came from the plan (modelAttributes): it wins.
		local planned = statue:GetAttribute("HeadOffset")
		if typeof(planned) == "Vector3" then
			headOffset = planned
			headSource = "plan"
			headDir, pitchAxis = Rules.headFrame(planned)
			print(string.format("[SkyRally][SNEEZE] head offset (%.1f, %.1f, %.1f) from plan", planned.X, planned.Y, planned.Z))
		end
	end
	if headSource == "plan" or headSource == "mesh" then
		return
	end
	local now = os.clock()
	if now - headCheckedAt < HEAD_RECHECK_SEC then
		return
	end
	headCheckedAt = now
	local off, source = measureHead(statue)
	if off and source ~= headSource then
		headOffset = off
		headSource = source
		headDir, pitchAxis = Rules.headFrame(off)
		statue:SetAttribute("HeadOffset", off)
		print(string.format("[SkyRally][SNEEZE] head offset (%.1f, %.1f, %.1f) from %s", off.X, off.Y, off.Z, source))
	end
end

local function loadTemplate()
	if templateState ~= "none" or ReplicatedStorage:FindFirstChild(TEMPLATE_NAME) then
		return
	end
	templateState = "loading"
	task.spawn(function()
		local boss = BossConfig.BY_ZONE.DINO
		local ok, res = pcall(function()
			-- Looked up here, not at load: the Lune harness loads RaceManager (and so this module) without it.
			return require(Shared:WaitForChild("ModelBakes")).load(boss.model :: number)
		end)
		if not ok or not res then
			templateState = "failed"
			warn(string.format("[SkyRally][SNEEZE] hatchling mesh %s failed to load: %s (clients use the stand-in)", tostring(boss.model), tostring(res)))
			return
		end
		local m = Instance.new("Model")
		m.Name = TEMPLATE_NAME
		for _, d in (res :: Instance):GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.CastShadow = false
				d.Massless = true
				d.Parent = m
			end
		end
		res:Destroy()
		if #m:GetChildren() == 0 then
			m:Destroy()
			templateState = "failed"
			return
		end
		local _, size = m:GetBoundingBox()
		local longest = math.max(size.X, size.Y, size.Z)
		if longest > 0 then
			m:ScaleTo(boss.length * HATCHLING_SCALE / longest)
		end
		m:SetAttribute("YawOffsetDeg", boss.yawOffset)
		m.Parent = ReplicatedStorage
		templateState = "ready"
		print("[SkyRally][SNEEZE] hatchling template ready")
	end)
end

-- Lap and station of the race leader among unfinished racers (players, then bots on the same progress scale as
-- RaceManager's standings), or nil when nobody is racing.
local function leader(totalLen: number): (number?, number?)
	local bestProg, bestLap, bestSt = -math.huge, nil :: number?, nil :: number?
	for _, rec in pairs(FlightServer.records) do
		if not rec.finished then
			local prog = (rec.lap - 1) * totalLen + rec.station
			if prog > bestProg then
				bestProg, bestLap, bestSt = prog, rec.lap, rec.station
			end
		end
	end
	for _, bot in ipairs(AIRacers.bots) do
		-- A bot still behind the start line on lap 1 has not started its lap (RaceManager's standings rule).
		if not bot.finished and not (bot.lap == 1 and bot.station > totalLen - 350) then
			local prog = (bot.lap - 1) * totalLen + bot.station
			if prog > bestProg then
				bestProg, bestLap, bestSt = prog, bot.lap, bot.station
			end
		end
	end
	return bestLap, bestSt
end

local function start(reason: string, forceHatchling: boolean?, lap: number?, station: number?)
	local hatchling = forceHatchling == true or math.random(Rules.HATCHLING_ODDS) == 1
	-- The hatchling flag goes out first so every client has it before the snap.
	workspace:SetAttribute("SauropodHatchling", hatchling)
	workspace:SetAttribute("SauropodInhaleAt", workspace:GetServerTimeNow())
	sequenceStart = os.clock()
	snapped = false
	print(string.format("[SkyRally][SNEEZE] inhale reason=%s lap=%s station=%s hatchling=%s head=%s", reason,
		tostring(lap), if station then string.format("%.0f", station) else "-", tostring(hatchling), headSource))
end

-- This race's plan: the lap (random 2..3) and the route station where the leader starts the sneeze.
local function newPlan(statue: Model, swayCF: CFrame): Rules.SneezePlan
	local base = statue:GetAttribute("BasePivotPos")
	local statueStation = SplineUtils.projectPosition(if typeof(base) == "Vector3" then base else swayCF.Position)
	local override = statue:GetAttribute("SneezeStation")
	local station = Rules.sneezeStation(statueStation, if type(override) == "number" then override else nil)
	local fresh = Rules.newPlan(PlaneConfig.TOTAL_LAPS, station, math.random)
	print(string.format("[SkyRally][SNEEZE] planned lap=%d station=%.0f (statue station %.0f)", fresh.lap, fresh.station, statueStation))
	return fresh
end

-- Called by RaceManager.stepSauropodHazard every Heartbeat with the sway pivot. `raceKey` changes on every race reset
-- (RaceManager.raceStartClock); `racing` is false in the hub, in battles and during the countdown.
function SauropodSneeze.apply(statue: Model, swayCF: CFrame, raceKey: number, racing: boolean): CFrame
	ensureHead(statue)
	loadTemplate()

	local trigger = workspace:GetAttribute("TriggerSauropodSneeze")
	if trigger ~= nil and trigger ~= false then
		workspace:SetAttribute("TriggerSauropodSneeze", false)
		if not sequenceStart then
			start("qa", trigger == "hatchling")
		end
	end

	if raceKey ~= planKey or statue ~= planStatue then
		planKey = raceKey
		planStatue = statue
		plan = nil
	end
	if racing and not sequenceStart then
		local wps, totalLen = SplineUtils.loadWaypoints()
		if #wps >= 2 and totalLen > 0 then
			local p = plan or newPlan(statue, swayCF)
			plan = p
			local lap, station = leader(totalLen)
			if lap and station and Rules.planDue(p, lap, station, totalLen) then
				p.done = true
				start("race", nil, lap, station)
			end
		end
	end

	local t0 = sequenceStart
	if not t0 then
		return swayCF
	end
	local elapsed = os.clock() - t0
	if not snapped and elapsed >= Rules.INHALE_SEC then
		snapped = true
		workspace:SetAttribute("SauropodSneezeAt", workspace:GetServerTimeNow())
	end
	if elapsed >= Rules.sequenceSec() then
		sequenceStart = nil
		return swayCF
	end
	local pitch, lunge = Rules.pose(elapsed)
	return swayCF * CFrame.new(headDir * lunge) * CFrame.fromAxisAngle(pitchAxis, math.rad(pitch))
end

return SauropodSneeze
