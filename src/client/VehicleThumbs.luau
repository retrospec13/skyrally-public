--!strict
-- 3D vehicle thumbnails for the Garage cards and the big preview (UI v2). Each thumbnail is a ViewportFrame holding a
-- display copy (client/DisplayCars) of the REAL model: ReplicatedStorage.SkyRallyShowroom.<avatarKey> when that avatar
-- has its own mesh, else the class hero (<"plane" | "car">) every unbuilt avatar races as, else (the showroom not
-- published yet) this player's live vehicle of that class. Cost: one copy per thumbnail, built when the card is built;
-- a ViewportFrame re-renders only when its camera moves, and only thumbnails marked spinning (the selected card and the
-- big preview) move their camera, one RenderStepped loop for all of them, skipped while none is on screen.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DisplayCars = require(script.Parent:WaitForChild("DisplayCars"))
local ArcadeUi = require(script.Parent:WaitForChild("ArcadeUi"))

local VehicleThumbs = {}

type Spin = { vpf: ViewportFrame, cam: Camera, target: Vector3, dist: number, pitch: number, yaw: number, speed: number }
local spinning: { [ViewportFrame]: Spin } = {}
local loop: RBXScriptConnection? = nil

local function showroom(): Instance?
	return ReplicatedStorage:FindFirstChild("SkyRallyShowroom")
end

-- The model a thumbnail clones (see the header), or nil while nothing is available yet.
function VehicleThumbs.template(avatarKey: string?, class: string): Model?
	local f = showroom()
	if f then
		local own = avatarKey and f:FindFirstChild(avatarKey)
		if own and own:IsA("Model") then
			return own
		end
		local hero = f:FindFirstChild(class)
		if hero and hero:IsA("Model") then
			return hero
		end
	end
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		local me = game:GetService("Players").LocalPlayer
		for _, m in planes:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("OwnerUserId") == me.UserId and (m:GetAttribute("IsCar") == true) == (class == "car") then
				if m:GetAttribute("AvatarMesh") ~= "creature" and m:GetAttribute("AvatarMesh") ~= "own" then
					return m
				end
			end
		end
	end
	return nil
end

local function ensureLoop()
	if loop then
		return
	end
	loop = RunService.RenderStepped:Connect(function(dt: number)
		local any = false
		for vpf, s in spinning do
			if not vpf.Parent then
				spinning[vpf] = nil
			elseif vpf.Visible and vpf.AbsoluteSize.X > 0 then
				any = true
				s.yaw += dt * s.speed
				local cp = math.cos(s.pitch)
				local off = Vector3.new(math.sin(s.yaw) * cp, math.sin(s.pitch), -math.cos(s.yaw) * cp) * s.dist
				s.cam.CFrame = CFrame.lookAt(s.target + off, s.target)
			end
		end
		if not any and next(spinning) == nil and loop then
			loop:Disconnect()
			loop = nil
		end
	end)
end

export type ViewOpts = {
	name: string?,
	spin: boolean?,
	yaw: number?, -- degrees from the nose (0 = head on)
	silhouette: Color3?, -- an avatar whose own model is not in yet: a dark tinted shape of what it races as
	zoom: number?,
}

-- Fills `holder` (any GuiObject) with a ViewportFrame of the vehicle. Returns the ViewportFrame; when no model is
-- available yet it draws the class icon and retries once the showroom publishes.
function VehicleThumbs.view(holder: GuiObject, avatarKey: string?, class: string, o: ViewOpts?): ViewportFrame
	local opts: ViewOpts = o or {}
	local vpf = Instance.new("ViewportFrame")
	vpf.Name = opts.name or "Thumb"
	vpf.BackgroundTransparency = 1
	vpf.Size = UDim2.fromScale(1, 1)
	vpf.Active = false
	-- Showroom light (UI v2 round 2): near-white ambient and a bright key light from the front-top (the camera side), so
	-- the model pops on the navy card instead of reading as a dark blob.
	vpf.Ambient = Color3.fromRGB(225, 228, 238)
	vpf.LightColor = Color3.fromRGB(255, 255, 255)
	vpf.LightDirection = Vector3.new(0.45, -0.85, -0.6)
	if opts.silhouette then
		vpf.ImageColor3 = opts.silhouette
	end
	vpf.Parent = holder
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.Parent = vpf
	vpf.CurrentCamera = cam

	local function fill(): boolean
		local tpl = VehicleThumbs.template(avatarKey, class)
		if not tpl then
			return false
		end
		local copy, size = DisplayCars.copy(tpl, 20)
		if not copy then
			return false
		end
		if opts.silhouette then
			-- A clean bright silhouette: every surface flat white (no textures), tinted by the frame's ImageColor3.
			for _, d in copy:GetDescendants() do
				if d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture") then
					d:Destroy()
				elseif d:IsA("MeshPart") then
					d.TextureID = ""
				end
				if d:IsA("BasePart") then
					d.Color = Color3.new(1, 1, 1)
					d.Material = Enum.Material.SmoothPlastic
				end
			end
		end
		local fallback = vpf:FindFirstChild("ClassIcon")
		if fallback then
			fallback:Destroy()
		end
		copy.Parent = vpf
		local longest = math.max(size.X, size.Y, size.Z)
		local target = Vector3.new(0, size.Y * 0.42, 0)
		local dist = longest * 1.3 / (opts.zoom or 1)
		local yaw = math.rad(opts.yaw or 215)
		local pitch = math.rad(24)
		local cp = math.cos(pitch)
		cam.CFrame = CFrame.lookAt(target + Vector3.new(math.sin(yaw) * cp, math.sin(pitch), -math.cos(yaw) * cp) * dist, target)
		if opts.spin then
			spinning[vpf] = { vpf = vpf, cam = cam, target = target, dist = dist, pitch = pitch, yaw = yaw, speed = 0.7 }
			ensureLoop()
		end
		return true
	end

	if not fill() then
		local ic = ArcadeUi.icon(vpf, class, { name = "ClassIcon", size = UDim2.fromScale(0.6, 0.6), position = UDim2.fromScale(0.5, 0.5), anchor = Vector2.new(0.5, 0.5) }, 48)
		ic.Parent = holder
		ic.Name = "ClassIcon"
		task.spawn(function()
			local f = ReplicatedStorage:WaitForChild("SkyRallyShowroom", 60)
			for _ = 1, 40 do
				if not vpf.Parent then
					return
				end
				if f and (f:FindFirstChild(class) or (avatarKey and f:FindFirstChild(avatarKey))) then
					if fill() then
						ic:Destroy()
					end
					return
				end
				task.wait(1)
			end
		end)
	end
	return vpf
end

-- Starts or stops a thumbnail's turntable spin.
function VehicleThumbs.setSpin(vpf: ViewportFrame, on: boolean)
	local cam = vpf.CurrentCamera
	if not on then
		spinning[vpf] = nil
		return
	end
	if spinning[vpf] or not cam then
		return
	end
	local model = vpf:FindFirstChildOfClass("Model")
	if not model then
		return
	end
	local _, size = model:GetBoundingBox()
	local target = Vector3.new(0, size.Y * 0.42, 0)
	local rel = cam.CFrame.Position - target
	local dist = rel.Magnitude
	local pitch = math.asin(math.clamp(rel.Y / math.max(dist, 1e-3), -1, 1))
	local yaw = math.atan2(rel.X, -rel.Z)
	spinning[vpf] = { vpf = vpf, cam = cam, target = target, dist = dist, pitch = pitch, yaw = yaw, speed = 0.7 }
	ensureLoop()
end

return VehicleThumbs
