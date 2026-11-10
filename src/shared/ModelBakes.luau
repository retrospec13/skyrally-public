--!strict
-- Model bakes (texpack fix 2026-10-19, docs/ASSETS.md "Model bakes"). A SurfaceAppearance carries a hidden saved
-- property TexturePack that Studio generates from its colour/normal/roughness/metalness maps, and a live client loads
-- PBR maps only through that pack. Models uploaded as GLB through Open Cloud come back from InsertService:LoadAsset with
-- an EMPTY pack, so on a published server the hero car, the hero plane, their split parts and the bosses drew untextured
-- ("Failed to load ...SurfaceAppearance. PBR textures may not be visible in game"). tools/bake_models.py loads each
-- model in the lane Studio, waits for Studio to generate every pack, and writes the result to
-- build/model_bakes/<id>.rbxm; default.project.json mounts each as ServerStorage.ModelBakes.<id>.
--
-- load(id) is the one place the game turns a model asset id into instances: a clone of the bake when one is mounted,
-- otherwise InsertService:LoadAsset(id) exactly as before (so nothing changes until a bake exists, and an id that was
-- never baked keeps working). It yields only on the LoadAsset path and errors like LoadAsset, so callers keep their
-- pcall. Server only in practice: clients cannot see ServerStorage (and cannot LoadAsset).
local ModelBakes = {}

local folderOverride: Instance? = nil
local loaderOverride: ((number) -> Instance)? = nil
local reported: { [number]: boolean } = {}

local function key(id: number): string
	return string.format("%d", id)
end

-- The mounted bakes folder (ServerStorage.ModelBakes), or nil (client, Lune, or a build without it).
function ModelBakes.folder(): Instance?
	if folderOverride then
		return folderOverride
	end
	local ok, ss = pcall(function()
		return game:GetService("ServerStorage")
	end)
	if not ok or not ss then
		return nil
	end
	return (ss :: Instance):FindFirstChild("ModelBakes")
end

-- Server only: appends "<id>=<source>" to the ReplicatedStorage attribute ModelBakeSources (a compact proof of which
-- models were baked, readable from the client and the Studio properties panel). pcall'd: Lune stand-ins have no
-- RunService, and a client or stand-in game just skips it.
local function recordSource(id: number, source: string)
	pcall(function()
		if not game:GetService("RunService"):IsServer() then
			return
		end
		local rs = game:GetService("ReplicatedStorage")
		local prev = rs:GetAttribute("ModelBakeSources")
		local entry = key(id) .. "=" .. source
		rs:SetAttribute("ModelBakeSources", if type(prev) == "string" and prev ~= "" then prev .. "," .. entry else entry)
	end)
end

-- The baked container for `id` (not a clone; never parent or edit it), or nil.
function ModelBakes.find(id: number): Instance?
	local f = ModelBakes.folder()
	if not f then
		return nil
	end
	return f:FindFirstChild(key(id))
end

function ModelBakes.has(id: number): boolean
	return ModelBakes.find(id) ~= nil
end

-- A fresh container for `id`, like InsertService:LoadAsset(id): the bake's clone when mounted, else LoadAsset.
function ModelBakes.load(id: number): Instance
	local bake = ModelBakes.find(id)
	local source = if bake then "bake" else "insert"
	if not reported[id] then
		reported[id] = true
		print(string.format("[SkyRally][ASSETS] model=%s source=%s", key(id), source))
		recordSource(id, source)
	end
	if bake then
		return bake:Clone()
	end
	if loaderOverride then
		return loaderOverride(id)
	end
	return game:GetService("InsertService"):LoadAsset(id)
end

-- Tests only: a stand-in bakes folder and LoadAsset. Pass nil to restore the real ones.
function ModelBakes._inject(folder: Instance?, loader: ((number) -> Instance)?)
	folderOverride = folder
	loaderOverride = loader
	table.clear(reported)
end

return ModelBakes
