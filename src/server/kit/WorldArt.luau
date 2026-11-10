--!strict
-- Server-side loader for the world_v1 / fx_v1 and art v3 meshes (assets/models/world_v1, fx_v1, foliage_v3, arches_v3,
-- props_v3). Each id in Shared.WorldModelAssets / FxModelAssets / FoliageV3Assets / ArchV3Assets / PropV3Assets is
-- a Model wrapping one MeshPart with a validated Use grant. (The owner rejected the art v2 meshes: FoliageModelAssets,
-- ArchModelAssets and PropModelAssets stay in the repo but are not searched, so no v2 mesh can load.) LoadAsset yields
-- and only the server may call it, so every template loads once, is cleaned up (anchored, no collision, no scripts) and is
-- cached; callers clone it. Clients get the gull templates through ReplicatedStorage.SkyRallyBirdTemplates.
local ModelBakes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ModelBakes"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WorldModelAssets = require(Shared:WaitForChild("WorldModelAssets"))
local FxModelAssets = require(Shared:WaitForChild("FxModelAssets"))
local FoliageV3Assets = require(Shared:WaitForChild("FoliageV3Assets"))
local ArchV3Assets = require(Shared:WaitForChild("ArchV3Assets"))
local PropV3Assets = require(Shared:WaitForChild("PropV3Assets"))
local FxTexAssets = require(Shared:WaitForChild("FxTexAssets"))
local ToolboxTempAssets = require(Shared:WaitForChild("ToolboxTempAssets"))

local WorldArt = {}

-- The tables WorldArt.world reads, in lookup order. Keys are unique across them (artswap_spec guards it).
local WORLD_TABLES: { { [string]: number } } = { WorldModelAssets, FoliageV3Assets, ArchV3Assets, PropV3Assets, ToolboxTempAssets.MESHES }

WorldArt.BIRD_FOLDER = "SkyRallyBirdTemplates"
WorldArt.GULL_USE_PALETTE = false
-- template name in the folder -> FxModelAssets key
local BIRD_PARTS: { [string]: string } = { GullBody = "gull_body", GullWingL = "gull_wing_L", GullWingR = "gull_wing_R" }

type Slot = { loading: boolean, value: Instance? }
local slots: { [string]: Slot } = {}

-- One load per key. A second caller during the yield waits for the first instead of reading "no template yet".
local function cached(key: string, load: () -> Instance?): Instance?
	local existing = slots[key]
	if existing then
		while existing.loading do
			task.wait()
		end
		return existing.value
	end
	local slot: Slot = { loading = true, value = nil }
	slots[key] = slot
	local ok, res = pcall(load)
	if ok then
		slot.value = res
	else
		warn(string.format("[SkyRally][ASSETS] world art %s FAILED: %s", key, tostring(res)))
	end
	slot.loading = false
	return slot.value
end

local function firstMesh(container: Instance): MeshPart?
	local found: MeshPart? = nil
	for _, d in container:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		elseif d:IsA("MeshPart") and not found then
			found = d
		end
	end
	return found
end

-- keepLook: a Creator Store stand-in (ToolboxTempAssets.MESHES) keeps the restyle baked into it (flat colour, Grass material)
-- instead of the neutral white SmoothPlastic of the vertex-coloured v3 meshes.
local function loadMesh(id: number, name: string, keepLook: boolean?): MeshPart?
	local container = ModelBakes.load(id)
	local mesh = firstMesh(container)
	local out: MeshPart? = nil
	if mesh then
		local m = mesh:Clone()
		for _, d in m:GetDescendants() do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			end
		end
		m.Name = name
		m.Anchored = true
		m.CanCollide = false
		m.CanQuery = false
		m.CanTouch = false
		m.Massless = true
		if keepLook then
			m.Transparency = 0
		else
			-- Vertex-coloured meshes (IgnoreVertexColors stays at its default, false): the colour comes from COLOR_0 times Color, so the part stays neutral plastic.
			m.Material = Enum.Material.SmoothPlastic
			m.Transparency = 0
			-- A MeshPart defaults to medium-stone-grey, which would multiply (and dull) the vertex colours; white is neutral.
			m.Color = Color3.new(1, 1, 1)
		end
		out = m
	end
	container:Destroy()
	return out
end

-- Template MeshPart for a world_v1 key (bush, stone_arch, portal_arch, ring_frame, ring_glow, ...) or an art v3 key (poplar,
-- round_oak, portal_gate, cavern_arch, windmill_tower, sign_post, ...). Every table in WORLD_TABLES is prewarmed through the
-- same call (kit/Prewarm -> loadAll -> world), so a new table only needs adding to WORLD_TABLES.
function WorldArt.world(name: string): MeshPart?
	local id: number? = nil
	for _, ids in WORLD_TABLES do
		id = ids[name]
		if id then
			break
		end
	end
	if not id then
		return nil
	end
	local meshId: number = id
	local keepLook = ToolboxTempAssets.MESHES[name] ~= nil
	local res = cached("world:" .. name, function()
		return loadMesh(meshId, name, keepLook)
	end)
	return if res then res :: MeshPart else nil
end

-- Model id and bounding box of a prop key: PropLibrary first, then the Creator Store stand-ins (ToolboxTempAssets.PROPS).
export type PropInfo = { model: number?, size: Vector3, ownPivot: boolean }
function WorldArt.propInfo(key: string): PropInfo?
	local PropLibrary = require(Shared:WaitForChild("PropLibrary")) :: any
	local info = PropLibrary[key]
	if info then
		return { model = tonumber(info.model), size = info.size, ownPivot = false }
	end
	local tb = ToolboxTempAssets.PROPS[key]
	if tb then
		return { model = tb.model, size = tb.size, ownPivot = tb.ownPivot }
	end
	return nil
end

-- Template Model of a prop (PropLibrary or Creator Store stand-in; every BasePart of the asset, scripts stripped), nil when
-- not uploaded or on failure. A stand-in with ownPivot keeps the pivot its bake was authored with (the base of the trunk / pole).
function WorldArt.prop(key: string): Model?
	local info = WorldArt.propInfo(key)
	local id = if info then info.model else nil
	if not id then
		return nil
	end
	local ownPivot = (info :: PropInfo).ownPivot
	local res = cached("prop:" .. key, function()
		local container = ModelBakes.load(id :: number)
		local pivot = if ownPivot and container:IsA("Model") then (container :: Model):GetPivot() else nil
		local m = Instance.new("Model")
		m.Name = key
		for _, d in container:GetDescendants() do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			end
		end
		for _, d in container:GetDescendants() do
			if d:IsA("BasePart") then
				d.Parent = m
			end
		end
		container:Destroy()
		if #m:GetChildren() == 0 then
			m:Destroy()
			error("asset has no parts")
		end
		if pivot then
			m.WorldPivot = pivot
		end
		return m
	end)
	return if res then res :: Model else nil
end

-- Loads every named world mesh and prop template at once (one thread per load; perf pass 2026-10-19: the art swap used
-- to fetch its templates one after another, ~0.3 s each, on the critical path of a first build) and returns when all
-- have finished. Already cached keys return at once; keys another thread is loading are waited for, never loaded twice.
function WorldArt.loadAll(meshes: { string }, props: { string })
	local pending = 0
	local function run(f: () -> ())
		pending += 1
		task.spawn(function()
			pcall(f)
			pending -= 1
		end)
	end
	for _, name in meshes do
		run(function()
			WorldArt.world(name)
		end)
	end
	for _, key in props do
		run(function()
			WorldArt.prop(key)
		end)
	end
	local deadline = os.clock() + 60
	while pending > 0 and os.clock() < deadline do
		task.wait()
	end
end

-- Parks the gull body and wings in ReplicatedStorage.SkyRallyBirdTemplates for client/Vfx (clients cannot LoadAsset).
-- Idempotent and threaded; the folder's Ready attribute flips true when all three loaded. The meshes are vertex-coloured
-- (MeshPart vertex colours stay on, the default). TODO(Studio): if the birds import white/untextured, set GULL_USE_PALETTE = true so the UVs
-- index the owned gull_palette strip instead (manifest fallback).
local birdStarted = false
function WorldArt.publishBirdTemplates()
	if birdStarted then
		return
	end
	birdStarted = true
	local folder = ReplicatedStorage:FindFirstChild(WorldArt.BIRD_FOLDER)
	if not (folder and folder:IsA("Folder")) then
		local f = Instance.new("Folder")
		f.Name = WorldArt.BIRD_FOLDER
		f.Parent = ReplicatedStorage
		folder = f
	end
	task.spawn(function()
		local n, pending = 0, 0
		for name, key in BIRD_PARTS do
			pending += 1
			task.spawn(function() -- the three loads in parallel
				local id = FxModelAssets[key]
				local mesh = cached("fx:" .. key, function()
					return loadMesh(id, name)
				end)
				if mesh then
					local c = (mesh :: MeshPart):Clone()
					c.Name = name
					c.CastShadow = true
					if WorldArt.GULL_USE_PALETTE then
						c.TextureID = FxTexAssets.gull_palette
					end
					c.Parent = folder
					n += 1
				end
				pending -= 1
			end)
		end
		local deadline = os.clock() + 60
		while pending > 0 and os.clock() < deadline do
			task.wait()
		end
		;(folder :: Folder):SetAttribute("Ready", n == 3)
		print(string.format("[SkyRally][ASSETS] bird templates %d/3 state=%s", n, if n == 3 then "mesh" else "INCOMPLETE"))
	end)
end

return WorldArt
