--!strict
-- Showroom models (UI v2 Garage): one display copy of every distinct vehicle look, built once a few seconds after boot
-- by the same builders the racers use (so the Garage cards show the REAL vehicle, not an icon) and published as
-- ReplicatedStorage.SkyRallyShowroom.<key>. Keys: "plane" and "car" (the class hero models every unbuilt avatar races
-- as) plus every avatar key whose mesh is registered (AvatarConfig.MESHES, e.g. the Void Dragon creature). Each copy is
-- stripped of scripts, sounds, emitters, constraints, lights and GUIs, anchored, non-colliding and parked far away; it
-- carries only IsCar / AvatarKey / AvatarMesh. Display only: nothing reads it on the server and no racer state is in it.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AvatarConfig = require(Shared:WaitForChild("AvatarConfig"))
local PlaneBuilder = require(script.Parent.PlaneBuilder)
local CarBuilder = require(script.Parent.kit.CarBuilder)

local ShowroomModels = {}

local STRIP = {
	"BaseScript", "Sound", "ParticleEmitter", "Trail", "Beam", "Fire", "Smoke", "Sparkles", "Constraint", "Light",
	"BillboardGui", "SurfaceGui", "ProximityPrompt", "Highlight", "ForceField", "BodyMover",
}
local KEEP_ATTRS = { IsCar = true, AvatarKey = true, AvatarMesh = true }

local function strip(m: Model)
	for _, d in m:GetDescendants() do
		for _, cls in STRIP do
			if d:IsA(cls) then
				d:Destroy()
				break
			end
		end
	end
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	for name in m:GetAttributes() do
		if not KEEP_ATTRS[name] then
			m:SetAttribute(name, nil)
		end
	end
end

local function build(key: string, class: string, avatarKey: string?): Model?
	local far = CFrame.new(0, -5000, 0)
	local ok, m = pcall(function(): Model
		if class == "car" then
			return CarBuilder.createCar("Showroom_" .. key, Color3.new(1, 1, 1), Color3.new(1, 1, 1), far, false, avatarKey)
		end
		return PlaneBuilder.createPlane("Showroom_" .. key, Color3.new(1, 1, 1), Color3.new(1, 1, 1), far, false, avatarKey)
	end)
	if not ok or not m then
		warn("[SkyRally][Showroom] build failed for " .. key .. ": " .. tostring(m))
		return nil
	end
	strip(m)
	m.Name = key
	m:SetAttribute("IsCar", class == "car")
	return m
end

function ShowroomModels.start()
	task.spawn(function()
		task.wait(6) -- after the boot's own mesh loads (the builders share their template caches)
		local folder = Instance.new("Folder")
		folder.Name = "SkyRallyShowroom"
		local jobs: { { key: string, class: string, avatar: string? } } = {
			{ key = "plane", class = "plane", avatar = AvatarConfig.STARTER.plane :: string? },
			{ key = "car", class = "car", avatar = AvatarConfig.STARTER.car :: string? },
		}
		for _, row in AvatarConfig.ROWS do
			local mesh = AvatarConfig.MESHES[row.key]
			if mesh and not mesh.hero then
				table.insert(jobs, { key = row.key, class = row.class :: string, avatar = row.key :: string? })
			end
		end
		folder.Parent = ReplicatedStorage
		for _, j in jobs do
			local m = build(j.key, j.class, j.avatar)
			if m then
				m.Parent = folder
			end
			task.wait()
		end
		folder:SetAttribute("Ready", true)
	end)
end

return ShowroomModels
