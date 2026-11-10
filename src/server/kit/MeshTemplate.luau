--!strict
-- Part templates for the split vehicle meshes (owner, 2026-10-19: wheels that turn, a propeller that spins). The hero
-- car and plane are single Tripo meshes with the wheels and the propeller baked in; the Blender split delivers a body
-- without them plus separate wheel and propeller meshes. Their asset ids are config fields that stay nil until the
-- integrator uploads them (CarBuilder.WHEEL_FRONT_MODEL_ID / WHEEL_REAR_MODEL_ID / HERO_CAR_BODY_MODEL_ID, PlaneBuilder.PROP_MODEL_ID /
-- HERO_PLANE_BODY_MODEL_ID). get() loads a model once per server, keeps its first MeshPart as a quiet, unanchored,
-- massless template and logs "[SkyRally][ASSETS] part=<label> ..." the same way the hero loaders report mesh vs fallback.
local ModelBakes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ModelBakes"))

local MeshTemplate = {}

local cache: { [number]: MeshPart } = {}
local tried: { [number]: boolean } = {}
local loading: { [number]: boolean } = {}

function MeshTemplate.get(id: number?, label: string): MeshPart?
	if type(id) ~= "number" or id <= 0 then
		return nil
	end
	-- LoadAsset yields: a second vehicle built meanwhile waits for this load instead of reading "no template".
	while loading[id] do
		task.wait()
	end
	if tried[id] then
		return cache[id]
	end
	loading[id] = true
	local found: MeshPart? = nil
	local ok, container = pcall(function()
		return ModelBakes.load(id)
	end)
	if ok and container then
		for _, d in container:GetDescendants() do
			if d:IsA("MeshPart") and not found then
				local c = d:Clone()
				for _, sub in c:GetDescendants() do
					if sub:IsA("LuaSourceContainer") then
						sub:Destroy()
					end
				end
				c.Anchored = false
				c.CanCollide = false
				c.CanTouch = false
				c.CanQuery = false
				c.Massless = true
				found = c
			end
		end
		container:Destroy()
	end
	if found then
		cache[id] = found
	end
	tried[id] = true
	loading[id] = false
	local size = if found then found.Size else Vector3.zero
	print(string.format("[SkyRally][ASSETS] part=%s model=%d state=%s loadOk=%s rawSize=(%.3f,%.3f,%.3f)", label, id, if found then "mesh" else "FALLBACK", tostring(ok), size.X, size.Y, size.Z))
	return found
end

-- Texture memory (perf pass 2026-10-19): the split wheels and propeller use the SAME 4096 px UV atlas as their body
-- (assets/models/hero_car_v3, hero_plane_v3 manifests), but each GLB was uploaded with its own copy of the three maps,
-- so a client held them three times for the car and twice for the plane. The part template takes a clone of the body's
-- SurfaceAppearance instead (once per template; every vehicle built afterwards clones the shared one), so the client
-- fetches and keeps one set of maps per vehicle kind.
local shared: { [MeshPart]: boolean } = setmetatable({}, { __mode = "k" }) :: any
function MeshTemplate.shareSurface(source: MeshPart?, part: MeshPart?)
	if not (source and part) or shared[part] then
		return
	end
	local sa = source:FindFirstChildOfClass("SurfaceAppearance")
	if not sa then
		return
	end
	for _, old in part:GetChildren() do
		if old:IsA("SurfaceAppearance") then
			old:Destroy()
		end
	end
	sa:Clone().Parent = part
	shared[part] = true
end

return MeshTemplate
