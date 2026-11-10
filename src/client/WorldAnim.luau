--!strict
-- Client-only world motion for map props (MAP_PLAN_SCHEMA modelAttributes): every Model under the active map root with
-- a SpinRPM attribute turns about its pivot (SpinAxis "PivotLookVector", the default, spins about the pivot's
-- LookVector; "PivotUpVector" about its UpVector). Windmill sails on FOREST-1 are the first users. Local-only CFrame
-- changes on anchored parts cost no replication; models farther than SPIN_RANGE from the camera are skipped.
local RunService = game:GetService("RunService")
local Prof = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
-- Economy v3 phase 2b: this client's race attributes (shared/RaceAttr; workspace while PER_GROUP is false).
local RaceAttr = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("RaceAttr"))
local SailGateRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SailGateRules"))

local WorldAnim = {}

local SPIN_RANGE = 1600

-- clock: the model turns on the shared server clock (SailGateRules.spinDeg), so every client and the server agree on the
-- angle at any instant; the FOREST-1 gate mill needs that, the other spinners keep their local timer.
type Spinner = { model: Model, base: CFrame, axis: Vector3, rate: number, clock: boolean, rpm: number, phase: number }

local spinners: { Spinner } = {}
local angle = 0
-- A model's rest pivot, captured the first time it is scanned. The map is scanned again a few seconds later while the
-- models are already turning; re-reading the pivot then would bake the current angle into the base.
local restPivot: { [Model]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local function scan(root: Instance)
	table.clear(spinners)
	for _, d in root:GetDescendants() do
		if d:IsA("Model") then
			local rpm = d:GetAttribute("SpinRPM")
			if type(rpm) == "number" and rpm ~= 0 then
				local axis = if d:GetAttribute("SpinAxis") == "PivotUpVector" then Vector3.yAxis else Vector3.zAxis
				local base = restPivot[d] or d:GetPivot()
				restPivot[d] = base
				local phase = d:GetAttribute(SailGateRules.ATTR_SAIL_PHASE)
				table.insert(spinners, {
					model = d,
					base = base,
					axis = axis,
					rate = rpm * math.pi / 30,
					clock = d:GetAttribute(SailGateRules.ATTR_CLOCK) == true,
					rpm = rpm,
					phase = if type(phase) == "number" then phase else 0,
				})
			end
		end
	end
	if #spinners > 0 then
		print(string.format("[SkyRally][WORLDANIM] spinners=%d", #spinners))
	end
end

local function activeRoot(): Instance?
	local maps = workspace:FindFirstChild("Maps")
	local id = RaceAttr.mine("ActiveTrackId")
	return if maps and type(id) == "string" then maps:FindFirstChild(id) else nil
end

local scanToken = 0

-- Waits for the active map to be ready, then scans it (again a few seconds later: streaming and post-build objects
-- such as the hub find markers arrive after TrackReady). Runs again on every track switch.
local function watchActive()
	scanToken += 1
	local my = scanToken
	table.clear(spinners)
	task.spawn(function()
		local root: Instance? = nil
		for _ = 1, 240 do
			if my ~= scanToken then
				return
			end
			root = activeRoot()
			if root and root:GetAttribute("TrackReady") == true then
				break
			end
			task.wait(0.5)
		end
		if root and my == scanToken then
			scan(root)
			for _, t in { 3, 8 } do
				task.delay(t, function()
					if my == scanToken and root.Parent then
						scan(root)
					end
				end)
			end
		end
	end)
end

function WorldAnim.init()
	RaceAttr.changed("ActiveTrackId", watchActive)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()
		if workspace:GetAttribute("TrackSwitching") ~= true then
			watchActive()
		end
	end)
	watchActive()
	do
		RunService.RenderStepped:Connect(Prof.wrap("SR_WorldAnim", function(dt: number)
			if #spinners == 0 then
				return
			end
			angle += dt
			local cam = workspace.CurrentCamera
			local camPos = if cam then cam.CFrame.Position else Vector3.zero
			local serverNow = workspace:GetServerTimeNow()
			for _, s in spinners do
				if s.model.Parent and (s.base.Position - camPos).Magnitude < SPIN_RANGE then
					local turn = if s.clock
						then math.rad(SailGateRules.spinDeg(serverNow, s.rpm, s.phase))
						else (angle * s.rate) % (2 * math.pi)
					s.model:PivotTo(s.base * CFrame.fromAxisAngle(s.axis, turn))
				end
			end
		end))
	end
end

return WorldAnim
