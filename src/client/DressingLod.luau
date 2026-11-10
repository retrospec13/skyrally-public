--!strict
-- Dressing LOD (owner, SNOW-1 play-test 2026-10-20: floating trees, snow mounds and posts). Rules and the why:
-- shared/DressingLodRules; design and Studio recipe: docs/design/DRESSING_LOD.md.
-- The active map's set dressing (MapAdapter's SetDressing folder, plus any Model with DressingLod = true) is indexed
-- once the map is TrackReady (and again 3 s and 8 s later, the same wait as LightLod/MapFxLod), never by a per-frame
-- scan. Each prop's ground is found once with a short downward ray: terrain (or nothing) -> LOD'd on its base point;
-- another managed prop -> follows it; any other part -> never hidden (that ground stays drawn).
-- At 5 Hz every terrain-grounded prop past the radius (tied to the terrain draw distance: the graphics level when one
-- is set, the smoothed frame time under Automatic) is hidden with LocalTransparencyModifier = 1 on this client only;
-- collision, queries and the server copy are untouched. At most MAX_PARTS_PER_STEP part writes per pass.
-- Never touched: terrain, barriers, kill volumes, course parts, triggers, pods, hazards, Backdrop shells, any model
-- bigger than MAX_EXTENT. Adaptive haze (docs/design/ADAPTIVE_HAZE.md): over the last FADE studs a prop steps through
-- FADE_STEPS transparency levels into the haze client/AdaptiveHaze thickens at the same radius, and the map's
-- MAP_SCENERY folders (FOREST-1 groves, hedgerows, far windmills...) join the LOD. DressingLod.estimate() is the radius
-- estimate both modules share. Studio A/B: workspace attribute DressingLodOff = true shows everything; DressingLodRadius
-- (number) forces the radius. The LocalPlayer attribute DressingLodState reads "r=<radius> src=<source> hidden=<n>/<m>".
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("DressingLodRules"))
local TriggerRules = require(Shared:WaitForChild("TriggerRules"))
local Prof = require(Shared:WaitForChild("Prof"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local DressingLod = {}

type Group = {
	model: Model,
	items: { Instance }, -- BaseParts, Decals and Textures (everything with LocalTransparencyModifier)
	x: number,
	y: number,
	z: number,
	kind: Rules.GroupKind,
	leader: number?, -- index of the group a "follow" prop stands on
}

local groups: { Group } = {}
local want: { number } = {} -- fade level 0 (drawn) .. Rules.FADE_STEPS (hidden)
local level: { number } = {}
local cost: { number } = {}
local index: { [Model]: number } = {}
local scanToken = 0
local radius = math.huge
local source = "init"
local frameMs = 16
local mutedUntil = 0 -- os.clock(): frame samples are ignored (and the Automatic radius holds) until then
local governor = Rules.newGovernor()
local lastState = ""
local lastLogged = -1

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = false

local function gameplay(inst: Instance, root: Instance): boolean
	local a: Instance? = inst
	while a and a ~= root do
		for _, name in Rules.GAMEPLAY_ATTRS do
			if a:GetAttribute(name) ~= nil then
				return true
			end
		end
		if CollectionService:HasTag(a, TriggerRules.TAG) or a.Name == "Hazards" then
			return true
		end
		a = a.Parent
	end
	return false
end

local function managedModelOf(inst: Instance): number?
	local a = inst.Parent
	while a do
		if a:IsA("Model") and index[a :: Model] then
			return index[a :: Model]
		end
		a = a.Parent
	end
	return nil
end

-- Ground under a prop's base point: "terrain", "dressing" (with the group it stands on), "part" or "none". Invisible
-- parts (trigger volumes, helpers) are looked through.
local function ground(model: Model, base: Vector3): (string, number?)
	local attr = model:GetAttribute(Rules.GROUND_ATTR)
	if attr == "terrain" or attr == "part" or attr == "none" then
		return attr :: string, nil
	end
	local skip: { Instance } = { model }
	for _ = 1, 4 do
		rayParams.FilterDescendantsInstances = skip
		local hit = workspace:Raycast(base + Vector3.new(0, 3, 0), Vector3.new(0, -10, 0), rayParams)
		if not hit then
			return "none", nil
		end
		local inst = hit.Instance
		if inst:IsA("Terrain") then
			return "terrain", nil
		end
		if inst:IsA("BasePart") and inst.Transparency >= 0.99 then
			table.insert(skip, inst)
			continue
		end
		local leader = managedModelOf(inst)
		if leader then
			return "dressing", leader
		end
		return "part", nil
	end
	return "none", nil
end

local function addModel(model: Model, root: Instance, inDressing: boolean, maxExtent: number?)
	if index[model] then
		return
	end
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if not ok then
		return
	end
	local sz = size :: Vector3
	local maxAxis = math.max(sz.X, sz.Y, sz.Z)
	local optIn = model:GetAttribute(Rules.OPT_IN_ATTR) == true or maxExtent ~= nil
	if not Rules.eligible(inDressing, optIn, gameplay(model, root), maxAxis, maxExtent) then
		return
	end
	local items: { Instance } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") then -- Texture is a Decal subclass
			if CollectionService:HasTag(d, TriggerRules.TAG) or CollectionService:HasTag(d, "Backdrop") then
				return -- never a trigger or a backdrop shell, whatever folder it sits in
			end
			for _, name in Rules.GAMEPLAY_ATTRS do
				if d:GetAttribute(name) ~= nil then
					return -- a gameplay marker inside the prop (pod, checkpoint, hazard, kill volume): never hidden
				end
			end
			table.insert(items, d)
		end
	end
	if #items == 0 then
		return
	end
	local base = (cf :: CFrame).Position - Vector3.new(0, sz.Y * 0.5, 0)
	table.insert(groups, { model = model, items = items, x = base.X, y = base.Y, z = base.Z, kind = "own", leader = nil })
	local i = #groups
	index[model] = i
	want[i] = 0
	level[i] = 0
	cost[i] = #items
end

local function classify(from: number)
	for i = from, #groups do
		local g = groups[i]
		local kind, leader = ground(g.model, Vector3.new(g.x, g.y, g.z))
		g.kind = Rules.groupKind(kind)
		g.leader = if g.kind == "follow" and leader ~= i then leader else nil
		if g.kind == "follow" and not g.leader then
			g.kind = "own"
		end
	end
	-- A stack (a prop on a prop on terrain) follows its bottom prop; a prop on a fixed prop is fixed.
	for i = from, #groups do
		local g = groups[i]
		local hops = 0
		while g.kind == "follow" and g.leader and groups[g.leader].kind == "follow" and hops < 8 do
			g.leader = groups[g.leader].leader
			hops += 1
		end
		if g.kind == "follow" and (not g.leader or g.leader == i or groups[g.leader].kind ~= "own") then
			g.kind = if g.leader and g.leader ~= i and groups[g.leader].kind == "fixed" then "fixed" else "own"
			g.leader = nil
		end
	end
end

local function write(i: number, l: number)
	local v = Rules.levelAlpha(l)
	for _, it in groups[i].items do
		if it.Parent then
			(it :: any).LocalTransparencyModifier = v
		end
	end
	level[i] = l
end

local function readStudioLevel(): number
	local ok, v = pcall(function(): number
		return (settings() :: any).Rendering.QualityLevel.Value
	end)
	return if ok and type(v) == "number" then v else 0
end

local function readSavedLevel(): number
	local ok, v = pcall(function(): number
		return (UserSettings():GetService("UserGameSettings") :: any).SavedQualityLevel.Value
	end)
	return if ok and type(v) == "number" then v else 0
end

-- The terrain draw radius estimate (ignores DressingLodOff): the target radius and where it came from. Shared with
-- client/AdaptiveHaze so the haze thickens exactly where props fade out.
function DressingLod.estimate(): (number, string)
	local forced = workspace:GetAttribute(Rules.RADIUS_ATTR)
	local studio, saved = readStudioLevel(), readSavedLevel()
	local phone = Settings.phoneTier()
	local target = Rules.targetRadius(studio, saved, frameMs, phone, if type(forced) == "number" then forced else nil)
	local automatic = not (type(forced) == "number" and forced > 0) and studio < 1 and saved < 1
	if automatic and not phone then
		-- Pump guard (QA V5A): one QUANT step per hold, frozen while a map load or the countdown settles. Both this module
		-- and AdaptiveHaze read the governed value, so the fog and the fade never chase a spike.
		target = Rules.govern(governor, target, os.clock(), mutedUntil)
	end
	local src = if type(forced) == "number" and forced > 0 then "forced"
		elseif studio >= 1 then "studio" .. studio
		elseif saved >= 1 then "slider" .. saved
		else string.format("auto%dms%s", math.floor(frameMs + 0.5), if phone then "-phone" else "")
	return target, src
end

-- A map switch or race start: ignore frame samples for Rules.SETTLE_S (after GO when the countdown is running).
local function settle()
	local goAt = RaceAttr.mine("RaceGoTime")
	local goIn = if type(goAt) == "number" then goAt - workspace:GetServerTimeNow() else nil
	mutedUntil = Rules.settleUntil(os.clock(), if goIn and goIn > 0 and goIn < 30 then goIn else nil, mutedUntil)
end

local function updateRadius(dt: number)
	local target
	if workspace:GetAttribute(Rules.OFF_ATTR) == true then
		target, source = math.huge, "off"
	else
		target, source = DressingLod.estimate()
	end
	radius = Rules.stepRadius(radius, target, dt)
end

local function tick()
	updateRadius(Rules.TICK)
	local cam = workspace.CurrentCamera
	local n = #groups
	if not cam or n == 0 then
		return
	end
	if workspace:GetAttribute("TrackSwitching") == true then
		return
	end
	local c = cam.CFrame.Position
	local cx, cy, cz = c.X, c.Y, c.Z
	for i = 1, n do
		local g = groups[i]
		if g.kind == "own" then
			local dx, dy, dz = g.x - cx, g.y - cy, g.z - cz
			want[i] = Rules.fadeLevel(math.sqrt(dx * dx + dy * dy + dz * dz), radius, level[i])
		elseif g.kind == "fixed" then
			want[i] = 0
		end
	end
	for i = 1, n do
		local g = groups[i]
		if g.kind == "follow" and g.leader then
			want[i] = want[g.leader]
		end
	end
	for _, i in Rules.batchLevels(want, level, cost, n, Rules.MAX_PARTS_PER_STEP) do
		write(i, want[i])
	end
	local hidden = 0
	for i = 1, n do
		if level[i] >= Rules.FADE_STEPS then
			hidden += 1
		end
	end
	local r = if radius == math.huge then "inf" else tostring(math.floor(radius + 0.5))
	local state = string.format("r=%s src=%s hidden=%d/%d", r, source, hidden, n)
	if state ~= lastState then
		lastState = state
		local lp = Players.LocalPlayer
		if lp then
			lp:SetAttribute("DressingLodState", state)
		end
		local rb = if radius == math.huge then 1e9 else math.floor(radius / 100)
		if rb ~= lastLogged then
			lastLogged = rb
			print("[SkyRally][LOD] dressing " .. state)
		end
	end
end

local function scan(root: Instance)
	local from = #groups + 1
	local folder = root:FindFirstChild(Rules.FOLDER)
	if folder then
		for _, m in folder:GetChildren() do
			if m:IsA("Model") then
				addModel(m, root, true)
			end
		end
	end
	for _, d in root:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute(Rules.OPT_IN_ATTR) == true then
			addModel(d, root, false)
		end
	end
	-- The map's compiled scenery folders (Rules.MAP_SCENERY): every Model reached through folders, not into models.
	local scenery = Rules.MAP_SCENERY[root.Name]
	if scenery then
		local function walk(f: Instance)
			for _, c in f:GetChildren() do
				if c:IsA("Model") then
					addModel(c, root, false, scenery.maxExtent)
				elseif c:IsA("Folder") then
					walk(c)
				end
			end
		end
		for _, path in scenery.folders do
			local f: Instance? = root
			for seg in string.gmatch(path, "[^/]+") do
				f = f and f:FindFirstChild(seg)
			end
			if f then
				walk(f)
			end
		end
	end
	classify(from)
	tick()
end

local function restoreAll()
	for i = 1, #groups do
		if level[i] ~= 0 then
			write(i, 0)
		end
	end
end

local function activeRoot(): Instance?
	local maps = workspace:FindFirstChild("Maps")
	local id = RaceAttr.mine("ActiveTrackId")
	return if maps and type(id) == "string" then maps:FindFirstChild(id) else nil
end

local function watchActive()
	settle()
	scanToken += 1
	local my = scanToken
	restoreAll() -- a map kept loaded (hub) must not keep hidden props after a switch away
	table.clear(groups)
	table.clear(want)
	table.clear(level)
	table.clear(cost)
	table.clear(index)
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

function DressingLod.init()
	RaceAttr.changed("ActiveTrackId", watchActive)
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()
		if workspace:GetAttribute("TrackSwitching") ~= true then
			watchActive()
		end
	end)
	RunService.RenderStepped:Connect(function(dt: number)
		frameMs = Rules.sampleFrame(frameMs, dt, os.clock(), mutedUntil)
	end)
	for _, name in { "RaceMode", "RaceGoTime" } do
		RaceAttr.changed(name, settle)
	end
	settle() -- the first seconds after join are the map load
	watchActive()
	local step = Prof.wrap("SR_DressingLod", tick)
	task.spawn(function()
		while true do
			task.wait(Rules.TICK)
			step()
		end
	end)
end

return DressingLod
