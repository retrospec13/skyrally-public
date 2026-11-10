--!nocheck
-- Lune harness (not Roblox code, hence nocheck: @lune requires are outside the Roblox definitions).
-- Runs a generated builder.server.luau against an in-memory DataModel seeded with things the SkyRally
-- patches must not touch, runs it a second time with one injected instance failure, and prints one
-- JSON line of observations for tests/test_compile.py. --no-spawn leaves out the seeded SpawnLocation (the
-- stock template reads SpawnLocation.Position, which lune cannot serve, so the negative control needs it).
-- usage: lune run tools/map30/tests/run_builder.luau <builder.server.luau> <map name> <ready attribute> <fail x> [--no-spawn]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local builderPath, mapName, readyAttr, failXArg = process.args[1], process.args[2], process.args[3], process.args[4]
assert(builderPath and mapName and readyAttr and failXArg, "usage: run_builder.luau BUILDER NAME READY_ATTR FAIL_X")
local failX = tonumber(failXArg)
local seedSpawn = process.args[5] ~= "--no-spawn"

local Instance, CFrame, Vector3 = roblox.Instance, roblox.CFrame, roblox.Vector3

-- lune has no pivot API; this mirrors Model:PivotTo/GetPivot for a model without a PrimaryPart
local injectFailure = false
roblox.implementMethod("Model", "GetPivot", function(self)
	return self.WorldPivot
end)
roblox.implementMethod("Model", "PivotTo", function(self, target)
	if injectFailure and math.abs(target.Position.X - failX) < 1e-6 then
		error("injected PivotTo failure")
	end
	local old = self.WorldPivot
	for _, d in self:GetDescendants() do
		if d:IsA("BasePart") then
			d.CFrame = target * old:ToObjectSpace(d.CFrame)
		end
	end
	self.WorldPivot = target
end)
roblox.implementMethod("HttpService", "JSONDecode", function(_, s)
	return serde.decode("json", s)
end)

local game = Instance.new("DataModel")
local workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local ServerStorage = game:GetService("ServerStorage")

-- seeds: a stock 30MAPS root, another map, the game's spawn, the game's Lighting stack, other templates
local stockMap = Instance.new("Folder")
stockMap.Name = "Map"
stockMap:SetAttribute("Sentinel", true)
stockMap.Parent = workspace
local maps = Instance.new("Folder")
maps.Name = "Maps"
maps.Parent = workspace
local other = Instance.new("Folder")
other.Name = "OTHER"
other:SetAttribute("MapBuilt", true)
other.Parent = maps
local spawnCF = CFrame.new(1, 2, 3)
local spawnSize = Vector3.new(6, 1, 6)
local spawn = Instance.new("SpawnLocation")
spawn.Name = "GameSpawn"
spawn.CFrame = spawnCF
spawn.Size = spawnSize
if seedSpawn then
	spawn.Parent = workspace
end
Lighting.ClockTime = 14.5
Lighting.Brightness = 2.2
local atm = Instance.new("Atmosphere")
atm.Density = 0.42
atm.Parent = Lighting
local bloom = Instance.new("BloomEffect")
bloom.Parent = Lighting
local tplRoot = Instance.new("Folder")
tplRoot.Name = "30MAPS_Templates"
tplRoot.Parent = ServerStorage
local staleFolder = Instance.new("Folder")
staleFolder.Name = mapName
staleFolder.Parent = tplRoot
local stale = Instance.new("Model")
stale.Name = "Stale"
stale.Parent = staleFolder
local otherTpl = Instance.new("Folder")
otherTpl.Name = "OTHER"
otherTpl.Parent = tplRoot
local keep = Instance.new("Model")
keep.Name = "Keep"
keep.Parent = otherTpl

local logs = {}
local function capture(kind)
	return function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			table.insert(parts, tostring((select(i, ...))))
		end
		table.insert(logs, kind .. " " .. table.concat(parts, " "))
	end
end

local source = fs.readFile(builderPath)
local function runBuilder()
	local chunk = luau.load(source, {
		debugName = "builder",
		environment = {
			game = game,
			workspace = workspace,
			Instance = Instance,
			CFrame = CFrame,
			Vector3 = Vector3,
			Color3 = roblox.Color3,
			Enum = roblox.Enum,
			UDim2 = roblox.UDim2,
			Region3 = roblox.Region3,
			task = task,
			print = capture("print"),
			warn = capture("warn"),
		},
	})
	local ok, err = pcall(chunk)
	return ok, if ok then nil else tostring(err)
end

local function names(parent)
	local out = {}
	for _, c in parent:GetChildren() do
		table.insert(out, c.Name)
	end
	table.sort(out)
	return out
end

local function cf12(cf)
	return { cf:GetComponents() }
end

-- lune errors on property reads of destroyed instances; the stock template destroys some seeds
local function try(fn)
	local ok, v = pcall(fn)
	return if ok then v else nil
end

local function snapshot(ok, err)
	local root = maps:FindFirstChild(mapName)
	local s = {
		ok = ok,
		err = err,
		mapsChildren = names(maps),
		workspaceChildren = names(workspace),
		stockMapSentinel = try(function()
			return stockMap.Parent == workspace and stockMap:GetAttribute("Sentinel") == true
		end) == true,
		otherMapIntact = try(function()
			return other.Parent == maps and other:GetAttribute("MapBuilt") == true
		end) == true,
		spawnCFrame = cf12(spawn.CFrame),
		spawnSize = { spawn.Size.X, spawn.Size.Y, spawn.Size.Z },
		spawnSeeded = seedSpawn,
		spawnParented = spawn.Parent == workspace,
		lightingChildren = names(Lighting),
		atmosphereDensity = try(function()
			return if atm.Parent == Lighting then atm.Density else nil
		end),
		clockTime = Lighting.ClockTime,
		brightness = Lighting.Brightness,
		serverStorageChildren = names(ServerStorage),
		templateRootChildren = names(tplRoot),
		templatesForMap = if tplRoot:FindFirstChild(mapName) then names(tplRoot[mapName]) else nil,
		otherTemplates = names(otherTpl),
		staleTemplateParent = try(function()
			return if stale.Parent then stale.Parent.Name else nil
		end),
		ready = workspace:GetAttribute(readyAttr),
		globalMapBuilt = workspace:GetAttribute("MapBuilt"),
		logs = logs,
	}
	if root then
		s.rootClass = root.ClassName
		s.rootMapBuilt = root:GetAttribute("MapBuilt")
		s.rootErrors = root:GetAttribute("MapBuildErrors")
		s.rootChildren = names(root)
		local models = {}
		for _, d in root:GetDescendants() do
			if d:IsA("Model") then
				local parts = {}
				for _, p in d:GetChildren() do
					if p:IsA("BasePart") then
						local light = p:FindFirstChildOfClass("PointLight")
						table.insert(parts, {
							name = p.Name,
							class = p.ClassName,
							shape = if p:IsA("Part") then p.Shape.Name else nil,
							cf = cf12(p.CFrame),
							size = { p.Size.X, p.Size.Y, p.Size.Z },
							transparency = p.Transparency,
							canCollide = p.CanCollide,
							canTouch = p.CanTouch,
							material = p.Material.Name,
							light = if light
								then { range = light.Range, brightness = light.Brightness, enabled = light.Enabled, shadows = light.Shadows }
								else nil,
						})
					end
				end
				table.sort(parts, function(a, b)
					return a.name < b.name
				end)
				table.insert(models, {
					name = d.Name,
					prefab = d:GetAttribute("Prefab"),
					path = d.Parent:GetFullName(),
					pivot = cf12(d.WorldPivot),
					parts = parts,
				})
			end
		end
		table.sort(models, function(a, b)
			return a.pivot[1] < b.pivot[1]
		end)
		s.models = models
	end
	return s
end

local first = snapshot(runBuilder())
logs = {}
injectFailure = true
local second = snapshot(runBuilder())
print(serde.encode("json", { first = first, second = second }))
