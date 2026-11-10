--!strict
-- Map cache (TEST_LIST L42, also L41): every track switch, each return to the hub included, used to re-run the map's
-- compiled builder (3-4M terrain voxels, 4-7k prefab parts) and the whole MapAdapter.build, 10-22 s on the server
-- before any client saw the map. Now the first build of a key is kept and every later load of that key restores it:
--   store (right after the first clean build, before anything else touches the map): a TerrainRegion copied from the
--     plan's terrain box (MapCacheRules.terrainBox: the builder's height grid plus every shell op, voxel-aligned), the
--     Terrain properties a region does not hold (water look, material colours), and a Clone() of Workspace.Maps.<id>.
--   load (TrackDirector.load, after the old map is destroyed and Terrain cleared): paste the region, restore the
--     properties, parent a clone of the stored root, set the builder's MapBuilt_<id> flag, then MapAdapter.activate
--     (lighting, terrain material overrides, _G route data, registry, TrackReady). Everything TrackDirector.load does
--     after the build (hub finds, StormCup prepareMode, RaceManager, bots, items, keys, coins, ducks, set pieces,
--     bosses, battles) runs on a cached load exactly as after a build, on a fresh clone each time.
-- Server memory: each entry holds one TerrainRegion (compressed voxels, the size of the map's terrain: roughly 5-15 MB
-- for a 3-4M solid-voxel map) and one unparented copy of the map's instances (5-9k parts, roughly 5-15 MB), so the six
-- shipped maps cost on the order of 100-200 MB of server memory for the life of the server; MapCacheRules.MAX_MAPS caps
-- the count (least recently used first, never the hub). The stored copies live in ServerStorage.MapCache, which never
-- replicates; their CollectionService tags stay on them, and no server code reads the trigger tag (clients do).
-- Clients still download the whole map on each switch (StreamingEnabled is off, L43): this cache cuts the server half.
-- QA: in Studio, workspace attribute MapCacheOff = true bypasses the cache (every load is a full build, nothing stored).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local MapCacheRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapCacheRules"))
-- Economy v3 phase 2b: per group the hub and other groups' maps share Terrain, so a failed paste never clears it.
local RaceFlowRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceFlowRules"))
local RaceInstanceRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RaceInstanceRules"))
local MapAdapter = require(script.Parent.MapAdapter)

local MapCache = {}

type TerrainProps = { water: { [string]: any }, colors: { [Enum.Material]: Color3 } }
type Entry = {
	folder: Folder, -- ServerStorage.MapCache.<key>: the stored root and the TerrainRegion
	root: Instance, -- pristine clone of Workspace.Maps.<id>, never parented to Workspace itself
	terrain: TerrainRegion?, -- nil for a map with no terrain
	corner: Vector3int16?,
	props: TerrainProps,
	adapterParts: number,
}

local entries: { [string]: Entry } = {}
local order: { string } = {} -- least recently used first

-- Terrain properties a build sets that are not voxels (the builder's water look and palette colours, the shell ops'
-- SetMaterialColor, the materials step's tints): a TerrainRegion does not carry them.
local WATER_PROPS = { "WaterColor", "WaterTransparency", "WaterReflectance", "WaterWaveSize", "WaterWaveSpeed", "Decoration" }

local function log(fmt: string, ...: any)
	print("[SkyRally][MAPCACHE] " .. string.format(fmt, ...))
end

function MapCache.enabled(): boolean
	return MapCacheRules.enabled(RunService:IsStudio(), workspace:GetAttribute("MapCacheOff"))
end

function MapCache.has(key: string): boolean
	return entries[key] ~= nil
end

local function cacheFolder(): Instance
	local f = ServerStorage:FindFirstChild("MapCache")
	if not f then
		f = Instance.new("Folder")
		f.Name = "MapCache"
		f.Parent = ServerStorage
	end
	return f :: Instance
end

local function snapshotTerrainProps(): TerrainProps
	local t = workspace.Terrain :: any
	local water = {}
	for _, name in WATER_PROPS do
		local ok, v = pcall(function()
			return t[name]
		end)
		if ok then
			water[name] = v
		end
	end
	local colors = {}
	for _, mat in Enum.Material:GetEnumItems() do
		local ok, c = pcall(function(): Color3
			return workspace.Terrain:GetMaterialColor(mat)
		end)
		if ok then -- only terrain materials have a colour; the rest error
			colors[mat] = c
		end
	end
	return { water = water, colors = colors }
end

local function restoreTerrainProps(p: TerrainProps)
	local t = workspace.Terrain :: any
	for name, v in p.water do
		pcall(function()
			t[name] = v
		end)
	end
	for mat, c in p.colors do
		pcall(function()
			workspace.Terrain:SetMaterialColor(mat, c)
		end)
	end
end

function MapCache.drop(key: string)
	local e = entries[key]
	if e then
		entries[key] = nil
		e.folder:Destroy()
	end
	local i = table.find(order, key)
	if i then
		table.remove(order, i)
	end
end

-- Keeps the map TrackDirector.load just built for `key`. Called right after MapAdapter.build, in the same synchronous
-- stretch (no yield before the snapshot), so nothing that runs after a load (find markers, keys, coins, set pieces)
-- is in the copy. Returns true when stored; a refusal is logged and that key simply keeps building.
function MapCache.store(key: string, td: any, report: MapAdapter.Report, pinned: string): boolean
	if not MapCache.enabled() then
		return false
	end
	local root = report.root
	if not MapCacheRules.cacheable(report.mapBuilt, #report.errors) or not root or not root.Parent then
		log("%s not cached: mapBuilt=%s errors=%d (the next load builds again)", key, tostring(report.mapBuilt), #report.errors)
		return false
	end
	local t0 = os.clock()
	local box, why = MapCacheRules.terrainBox(td.terrainBounds, td.shells, td.waypoints or {})
	if not box then
		log("%s not cached: %s", key, tostring(why))
		return false
	end
	local region: TerrainRegion? = nil
	local corner: Vector3int16? = nil
	local cellCount = 0
	if not box.empty then
		local cells = MapCacheRules.cells(box)
		if not cells then
			log("%s not cached: terrain box %s..%s is outside the int16 voxel range", key, tostring(box.lo), tostring(box.hi))
			return false
		end
		local r16 = Region3int16.new(
			Vector3int16.new(cells.min[1], cells.min[2], cells.min[3]),
			Vector3int16.new(cells.max[1], cells.max[2], cells.max[3])
		)
		local ok, res = pcall(function(): TerrainRegion
			return workspace.Terrain:CopyRegion(r16)
		end)
		if not ok then
			log("%s not cached: CopyRegion failed: %s", key, tostring(res))
			return false
		end
		region, corner, cellCount = res, r16.Min, cells.count
	end
	local okClone, copy = pcall(function(): Instance?
		return root:Clone()
	end)
	if not okClone or not copy then
		log("%s not cached: Clone failed: %s", key, tostring(copy))
		if region then
			region:Destroy()
		end
		return false
	end
	MapCache.drop(key)
	local folder = Instance.new("Folder")
	folder.Name = key
	copy.Parent = folder
	if region then
		region.Name = "Terrain"
		region.Parent = folder
	end
	folder.Parent = cacheFolder()
	entries[key] = {
		folder = folder,
		root = copy,
		terrain = region,
		corner = corner,
		props = snapshotTerrainProps(),
		adapterParts = report.adapterParts,
	}
	MapCacheRules.touch(order, key)
	for _, old in MapCacheRules.evictions(order, pinned, MapCacheRules.MAX_MAPS) do
		log("evict %s (least recently used, cap %d)", old, MapCacheRules.MAX_MAPS)
		MapCache.drop(old)
	end
	log("stored %s (%s) parts=%d terrainCells=%d box=%s..%s in %.2fs", key, tostring(td.id), report.parts, cellCount, tostring(box.lo), tostring(box.hi), os.clock() - t0)
	return true
end

-- Restores `key` as the only map. Expects Workspace.Maps emptied and Terrain cleared (TrackDirector.load). Returns the
-- activation report, or nil when there is no usable entry (not stored, MapCacheOff, a failed paste): the caller then
-- builds as usual.
function MapCache.load(key: string, td: any): MapAdapter.Report?
	local e = entries[key]
	if not e or not MapCache.enabled() then
		return nil
	end
	local t0 = os.clock()
	local region, corner = e.terrain, e.corner
	if region and corner then
		-- Single race: Terrain was cleared just before, so the empty cells need no paste. Per group: pasting without the
		-- empty cells never writes Air outside this map's own solid voxels (the hub's plaza and other zones stay).
		local ok, err = pcall(function()
			workspace.Terrain:PasteRegion(region, corner, false)
		end)
		if not ok then
			warn("[SkyRally][MAPCACHE] " .. key .. " PasteRegion failed, building instead: " .. tostring(err))
			if RaceInstanceRules.clearTerrain(RaceFlowRules.PER_GROUP, false) then
				workspace.Terrain:Clear()
			end
			MapCache.drop(key)
			return nil
		end
	end
	restoreTerrainProps(e.props)
	local maps = workspace:FindFirstChild("Maps")
	if not maps then
		maps = Instance.new("Folder")
		maps.Name = "Maps"
		maps.Parent = workspace
	end
	local root = e.root:Clone()
	-- A restored root must not read as ready before activate has registered it (clients and SelfTest wait on it).
	root:SetAttribute("TrackReady", false)
	root:SetAttribute("MapCache", "hit") -- QA: this map came from the cache (WorldProbe / Explorer)
	root.Parent = maps
	-- The compiled builder's finish flag, as a build leaves it.
	workspace:SetAttribute(MapAdapter.readyAttribute(tostring(td.id)), true)
	local report = MapAdapter.activate(td, root, { activate = true, adapterParts = e.adapterParts })
	MapCacheRules.touch(order, key)
	log("load %s (%s) from cache parts=%d errors=%d in %.2fs", key, tostring(td.id), report.parts, #report.errors, os.clock() - t0)
	return report
end

return MapCache
