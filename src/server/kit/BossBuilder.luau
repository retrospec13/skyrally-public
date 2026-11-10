--!strict
-- Builds a boss racer (BossConfig): an invisible anchored Hull that AIRacers drives like any bot, the boss mesh welded
-- to it (uploaded rigged boss model fitted to BossConfig.length with Model:ScaleTo, turned by yawOffset and, for flyers,
-- leaned nose-down by BossConfig.pitch), a glow and a name plate. For the client clip player (BossAnimator) the model
-- carries the attribute BossScale (the ScaleTo factor: baked clip translations are in glTF units) and the hull an
-- Attachment "RigFrame" at the lean offset (the creature frame: forward -Z, up +Y, right +X).
-- Without an uploaded model the zone vehicle stands in, in the boss colours and scaled up, so a boss race always runs.
local ModelBakes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ModelBakes"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BossConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BossConfig"))
local CarConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CarConfig"))
local PlaneBuilder = require(script.Parent.Parent.PlaneBuilder)
local CarBuilder = require(script.Parent.CarBuilder)

local BossBuilder = {}

local templates: { [number]: Model | false } = {}

local function loadTemplate(assetId: number): Model?
	local cached = templates[assetId]
	if cached == false then
		return nil
	elseif cached then
		return cached :: Model
	end
	local ok, res = pcall(function()
		return ModelBakes.load(assetId)
	end)
	if not ok or not res then
		warn(string.format("[SkyRally][BOSS] model %d failed to load: %s", assetId, tostring(res)))
		templates[assetId] = false
		return nil
	end
	local m = Instance.new("Model")
	for _, d in (res :: Instance):GetDescendants() do
		if d:IsA("BasePart") then
			d.Parent = m
		end
	end
	res:Destroy()
	if #m:GetChildren() == 0 then
		templates[assetId] = false
		return nil
	end
	templates[assetId] = m
	return m
end

local function aura(hull: BasePart, boss: BossConfig.Boss)
	local light = Instance.new("PointLight")
	light.Name = "BossGlow"
	light.Color = boss.accent
	light.Range = 22
	light.Brightness = 1.6
	light.Shadows = false
	light.Parent = hull
	local bb = Instance.new("BillboardGui")
	bb.Name = "BossPlate"
	bb.Size = UDim2.new(0, 200, 0, 40)
	bb.StudsOffsetWorldSpace = Vector3.new(0, boss.length * 0.45 + 4, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 400
	bb.LightInfluence = 0
	bb.Parent = hull
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextColor3 = boss.accent
	t.Text = string.upper(boss.name)
	t.Parent = bb
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(30, 18, 10)
	s.Thickness = 2
	s.Parent = t
end

-- Fits a loaded template to `length` studs and welds it to the hull.
local function attachMesh(model: Model, hull: BasePart, template: Model, boss: BossConfig.Boss)
	local mesh = template:Clone()
	local _, size = mesh:GetBoundingBox()
	local longest = math.max(size.X, size.Y, size.Z)
	if longest > 0 then
		mesh:ScaleTo(boss.length / longest * boss.modelScale)
	end
	model:SetAttribute("BossScale", mesh:GetScale())
	-- Flying bosses lean nose-down into the course (BossConfig.pitch, default 14 deg).
	local lean = if boss.vehicle == "plane" then CFrame.Angles(math.rad(-(boss.pitch or 14)), 0, 0) else CFrame.identity
	local rigFrame = Instance.new("Attachment")
	rigFrame.Name = "RigFrame"
	rigFrame.CFrame = lean
	rigFrame.Parent = hull
	mesh:PivotTo(hull.CFrame * lean * CFrame.Angles(0, math.rad(boss.yawOffset), 0))
	-- Walkers and karts stand on the road: the hull rides CarConfig.RIDE_HEIGHT above the ground (AIRacers renderCar), so
	-- the mesh's lowest point goes there instead of hanging around the hull centre.
	if boss.vehicle == "car" then
		local bcf, bsize = mesh:GetBoundingBox()
		local bottom = bcf.Position.Y - bsize.Y * 0.5
		local target = hull.Position.Y - CarConfig.RIDE_HEIGHT
		mesh:PivotTo(mesh:GetPivot() + Vector3.new(0, target - bottom, 0))
	end
	for _, d in mesh:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			local w = Instance.new("WeldConstraint")
			w.Part0 = hull
			w.Part1 = d
			w.Parent = d
		end
	end
	mesh.Name = "BossMesh"
	mesh.Parent = model
end

function BossBuilder.create(boss: BossConfig.Boss, startCF: CFrame): Model
	local name = "BOSS_" .. boss.name
	local template = if boss.model then loadTemplate(boss.model) else nil
	local model: Model
	if template then
		model = Instance.new("Model")
		model.Name = name
		local hull = Instance.new("Part")
		hull.Name = "Hull"
		hull.Size = Vector3.new(6, 3, 12)
		hull.Transparency = 1
		hull.Anchored = true
		hull.CanCollide = false
		hull.CanQuery = false
		hull.CanTouch = false
		hull.CFrame = startCF
		hull.Parent = model
		model.PrimaryPart = hull
		attachMesh(model, hull, template, boss)
	elseif boss.vehicle == "car" then
		model = CarBuilder.createCar(name, boss.color, boss.accent, startCF, true)
		model:ScaleTo(1.6)
	else
		model = PlaneBuilder.createPlane(name, boss.color, boss.accent, startCF, true)
		model:ScaleTo(1.6)
	end
	model:SetAttribute("IsBoss", true)
	model:SetAttribute("BossName", boss.name)
	model:SetAttribute("BossZone", boss.zone)
	local hull = model.PrimaryPart
	if hull then
		aura(hull, boss)
	end
	print(string.format("[SkyRally][BOSS] built %s model=%s", boss.name, if template then tostring(boss.model) else "fallback"))
	return model
end

return BossBuilder
