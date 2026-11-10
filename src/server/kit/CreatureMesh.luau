--!strict
-- Rigged creature avatars (AvatarConfig Mesh kind = "creature"; first: plane_void_dragon, the owner's dragon sheet).
-- The same load-and-weld as the bosses (kit/BossBuilder): the uploaded rigged model is loaded once per server (its
-- BaseParts, which carry the Bones, moved into one Model), fitted with Model:ScaleTo to the entry's length times scale,
-- clamped by the chase-camera bound (VehicleCreatureRules.fitLength), turned by the entry's yaw (rigged GLBs import
-- yawed 180) and welded to the vehicle's existing invisible Hull: CanCollide / CanQuery / CanTouch false, Massless, so
-- the hull, its physics, its collision and its hitbox are exactly the plane's (stat-neutral).
-- For the client clip player (client/VehicleCreatureAnimator) the vehicle model carries CreatureClips (the clip module
-- name) and CreatureScale (the ScaleTo factor: baked clip translations are glTF units), and the hull a RigFrame
-- attachment (the creature frame: forward -Z, up +Y). The rider sits at the entry's seat (SeatAnchor / PilotScale,
-- read by kit/PilotSeat for players and bots alike).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ModelBakes = require(Shared:WaitForChild("ModelBakes"))
local VehicleCreatureRules = require(Shared:WaitForChild("VehicleCreatureRules"))

local CreatureMesh = {}

local templates: { [number]: Model | false } = {}
local loading: { [number]: boolean } = {}

-- The rigged template for a model id (nil when it fails to load or holds no parts; remembered either way).
function CreatureMesh.get(id: number?, label: string): Model?
	if type(id) ~= "number" or id <= 0 then
		return nil
	end
	-- LoadAsset yields: a second racer built meanwhile waits for this load.
	while loading[id] do
		task.wait()
	end
	local cached = templates[id]
	if cached == false then
		return nil
	elseif cached then
		return cached :: Model
	end
	loading[id] = true
	local ok, res = pcall(function()
		return ModelBakes.load(id)
	end)
	local m: Model? = nil
	if ok and res then
		local model = Instance.new("Model")
		model.Name = "CreatureMesh"
		for _, d in (res :: Instance):GetDescendants() do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			end
		end
		for _, d in (res :: Instance):GetDescendants() do
			if d:IsA("BasePart") then
				d.Parent = model
			end
		end
		res:Destroy()
		if #model:GetChildren() > 0 then
			m = model
		end
	end
	templates[id] = m or false
	loading[id] = false
	local bones = 0
	if m then
		for _, d in m:GetDescendants() do
			if d:IsA("Bone") then
				bones += 1
			end
		end
	end
	print(string.format("[SkyRally][ASSETS] creature=%s model=%d state=%s loadOk=%s bones=%d", label, id, if m then "mesh" else "FALLBACK", tostring(ok), bones))
	return m
end

-- Clones the template onto the vehicle (see the header). Returns the fitted length in studs.
function CreatureMesh.attach(vehicle: Model, hull: BasePart, template: Model, mesh: any): number
	local creature = template:Clone()
	local length = VehicleCreatureRules.fitLength((mesh.length or 16) * (mesh.scale or 1), mesh.reach, mesh.offset)
	local _, size = creature:GetBoundingBox()
	local longest = math.max(size.X, size.Y, size.Z)
	if longest > 0 then
		creature:ScaleTo(length / longest)
	end
	vehicle:SetAttribute(VehicleCreatureRules.ATTR_SCALE, creature:GetScale())
	vehicle:SetAttribute(VehicleCreatureRules.ATTR_CLIPS, mesh.clips or "")
	local camDist, camHeight = VehicleCreatureRules.camera(length, mesh.reach, mesh.offset)
	local wingHalf, tailBack = VehicleCreatureRules.tips(length, mesh.reach, mesh.offset)
	vehicle:SetAttribute(VehicleCreatureRules.ATTR_CAM_DISTANCE, camDist)
	vehicle:SetAttribute(VehicleCreatureRules.ATTR_CAM_HEIGHT, camHeight)
	vehicle:SetAttribute(VehicleCreatureRules.ATTR_WING_HALF, wingHalf)
	vehicle:SetAttribute(VehicleCreatureRules.ATTR_TAIL_BACK, tailBack)
	local rigFrame = Instance.new("Attachment")
	rigFrame.Name = "RigFrame"
	rigFrame.Parent = hull
	local o = mesh.offset or { 0, 0, 0 }
	creature:PivotTo(hull.CFrame * CFrame.new(o[1] or 0, o[2] or 0, o[3] or 0) * CFrame.Angles(0, math.rad(mesh.yaw or 180), 0))
	for _, d in creature:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.CastShadow = true
			local w = Instance.new("WeldConstraint")
			w.Part0 = hull
			w.Part1 = d
			w.Parent = d
		end
	end
	creature.Name = "CreatureMesh"
	creature.Parent = vehicle
	local seat = mesh.seat
	if type(seat) == "table" then
		vehicle:SetAttribute("SeatAnchor", CFrame.new(seat[1] or 0, seat[2] or 0, seat[3] or 0))
	end
	if type(mesh.riderScale) == "number" then
		vehicle:SetAttribute("PilotScale", mesh.riderScale)
	end
	return length
end

return CreatureMesh
