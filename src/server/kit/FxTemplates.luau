--!strict
-- Server-made templates for the layered vehicle exhaust (owner: the vehicle "has a shitty looking fire flame"; art
-- pass fx_v1). Clients cannot InsertService:LoadAsset, so the server loads each FxModelAssets model once (one MeshPart per
-- Model, validated Use grants), sets it up as an anchored, non-colliding glow mesh with its owned texture and parks it in
-- ReplicatedStorage.SkyRallyFlameTemplates. client/Vfx clones these per vehicle (never per frame).
local ModelBakes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ModelBakes"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FxModelAssets = require(Shared:WaitForChild("FxModelAssets"))
local FxTexAssets = require(Shared:WaitForChild("FxTexAssets"))

local FxTemplates = {}

FxTemplates.FOLDER_NAME = "SkyRallyFlameTemplates"

-- template name -> FxModelAssets / FxTexAssets key (same key in both tables). Empty: the flame_core / flame_outer
-- meshes were retired for the particle flame and the shock_ring mesh by the shockwave_8x8 ring emitter (client/Vfx), so
-- nothing is loaded (init stays callable; the folder is still created). Add a name here only for a genuinely solid template.
local NAMES: { string } = {}

local started = false

local function prepare(name: string, mesh: MeshPart): MeshPart
	local m = mesh:Clone()
	for _, d in m:GetDescendants() do
		-- Our own validated texture (TextureID) shapes the flame; an importer SurfaceAppearance would override it.
		if d:IsA("LuaSourceContainer") or d:IsA("SurfaceAppearance") then
			d:Destroy()
		end
	end
	m.Name = name
	m.TextureID = (FxTexAssets :: any)[name]
	m.Material = Enum.Material.Neon -- glow without an additive blend; Color stays near white so the texture is not tinted
	m.Color = Color3.new(1, 1, 1)
	m.Transparency = 0
	m.Anchored = true -- client Vfx places it each frame from the hull CFrame; no physics, no joints
	m.CanCollide = false
	m.CanQuery = false
	m.CanTouch = false
	m.Massless = true
	m.CastShadow = false
	return m
end

local function load(folder: Folder, name: string)
	local id = FxModelAssets[name]
	local ok, container = pcall(function()
		return ModelBakes.load(id)
	end)
	local mesh: MeshPart? = nil
	if ok and container then
		for _, d in container:GetDescendants() do
			if d:IsA("MeshPart") then
				mesh = d
				break
			end
		end
	end
	if mesh then
		prepare(name, mesh).Parent = folder
	else
		warn(string.format("[SkyRally][ASSETS] flame template %s (model %d) FAILED to load", name, id))
	end
	if container then
		container:Destroy()
	end
end

-- Idempotent. The loads yield, so they run on their own thread and never delay boot; Vfx polls for the children.
function FxTemplates.init()
	if started then
		return
	end
	started = true
	local folder = ReplicatedStorage:FindFirstChild(FxTemplates.FOLDER_NAME)
	if not (folder and folder:IsA("Folder")) then
		local f = Instance.new("Folder")
		f.Name = FxTemplates.FOLDER_NAME
		f.Parent = ReplicatedStorage
		folder = f
	end
	task.spawn(function()
		for _, name in NAMES do
			if not (folder :: Folder):FindFirstChild(name) then
				load(folder :: Folder, name)
			end
		end
		local count = #(folder :: Folder):GetChildren()
		if #NAMES > 0 then
			print(string.format("[SkyRally][ASSETS] flame templates %d/%d state=%s", count, #NAMES, if count == #NAMES then "mesh" else "INCOMPLETE"))
		end
	end)
end

return FxTemplates
