--!strict
-- The hub PAINT SHOP kiosk (economy v3 section 4): a small block-built stand on the plaza (ART_BAR: painted wood panels, a plum
-- body, teal awning panels, honey trim; no outlines, no uploads) with a warm MapLight lamp, a swatch rack and two prompts:
-- PAINT SHOP opens the Garage on the TINTS tab (turntable preview of the player's own vehicle), VEHICLES opens the VEHICLES tab.
-- The prompts only carry the Garage tab id (PaintShopConfig.TAB_ATTR); client/PaintShop opens the panel, so no remote is needed.
-- Where it stands is one constant, PaintShopConfig.STAND. Like the Storm stand and the board it exists only while the server is in
-- the hub (RaceMode "hub"). Every part is CanCollide = false and CanQuery = false: visual only, never a wall or a trap (owner
-- rule: wall / mountain driving, adhesion, barriers, kill volumes and rescue are never changed; nothing is built in the cliffs).
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("PaintShopConfig"))

local PaintShopStand = {}

local PLUM = Color3.fromRGB(104, 58, 96)
local PLUM_DARK = Color3.fromRGB(66, 36, 64)
local TEAL = Color3.fromRGB(46, 150, 148)
local TEAL_DARK = Color3.fromRGB(28, 96, 100)
local HONEY = Color3.fromRGB(240, 180, 72)
local CREAM = Color3.fromRGB(246, 236, 210)
local SWATCHES = {
	Color3.fromRGB(220, 84, 78),
	Color3.fromRGB(240, 180, 72),
	Color3.fromRGB(96, 176, 110),
	Color3.fromRGB(70, 140, 214),
	Color3.fromRGB(150, 96, 200),
}

local model: Model? = nil
local started = false

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	if shape then
		p.Shape = shape
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function groundY(): number
	local S = Config.STAND
	local params = RaycastParams.new()
	params.RespectCanCollide = true
	local ok, hit = pcall(function()
		return workspace:Raycast(Vector3.new(S.pos.X, S.pos.Y + 80, S.pos.Z), Vector3.new(0, -160, 0), params)
	end)
	if ok and hit and math.abs(hit.Position.Y - S.pos.Y) <= S.groundTolerance then
		return hit.Position.Y
	end
	return S.pos.Y
end

local function addPrompt(parent: Part, spec: Config.PromptSpec, distance: number, offsetY: number)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = Config.promptName(spec.action)
	prompt.ActionText = spec.action
	prompt.ObjectText = spec.object
	prompt.KeyboardKeyCode = (Enum.KeyCode :: any)[spec.key]
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = distance
	prompt.RequiresLineOfSight = false
	prompt.UIOffset = Vector2.new(0, offsetY)
	prompt:SetAttribute(Config.TAB_ATTR, spec.tab)
	prompt.Parent = parent
end

local function signFace(sign: Part, text: string, color: Color3)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = color
	label.Parent = gui
end

local function build(y: number): Model
	local S = Config.STAND
	local m = Instance.new("Model")
	m.Name = Config.NAME
	local base = CFrame.lookAt(Vector3.new(S.pos.X, y, S.pos.Z), Vector3.new(S.faceToward.X, y, S.faceToward.Z))
	-- Counter (front), painted panel trim, back wall, posts, two-panel awning.
	local counter = part(m, "Counter", Vector3.new(11, 3.4, 2.8), base * CFrame.new(0, 1.7, 0), PLUM, Enum.Material.WoodPlanks)
	part(m, "CounterTop", Vector3.new(11.6, 0.4, 3.4), base * CFrame.new(0, 3.6, 0), PLUM_DARK, Enum.Material.Wood)
	part(m, "CounterTrim", Vector3.new(11.2, 0.35, 0.2), base * CFrame.new(0, 2.9, -1.45), HONEY, Enum.Material.WoodPlanks)
	part(m, "BackWall", Vector3.new(11, 8, 0.6), base * CFrame.new(0, 4, 4.6), TEAL_DARK, Enum.Material.WoodPlanks)
	for _, x in { -5.4, 5.4 } do
		part(m, "Post", Vector3.new(0.8, 9, 0.8), base * CFrame.new(x, 4.5, -1.1), PLUM_DARK, Enum.Material.Wood)
	end
	for i, x in { -3.3, 3.3 } do
		part(m, "AwningPanel" .. i, Vector3.new(6.5, 0.4, 7), base * CFrame.new(x, 9.3, 1.7) * CFrame.Angles(math.rad(-9), 0, 0), if i == 1 then TEAL else HONEY, Enum.Material.WoodPlanks)
	end
	part(m, "AwningEdge", Vector3.new(13.2, 0.4, 0.3), base * CFrame.new(0, 8.75, -1.75), PLUM_DARK, Enum.Material.Wood)
	-- A swatch rack to the right (the vehicle rack: a painted board with colour chips), the VEHICLES prompt sits on it.
	local rack = part(m, "VehicleRack", Vector3.new(3.4, 5.6, 0.5), base * CFrame.new(8.2, 2.8, 0.6) * CFrame.Angles(0, math.rad(-18), 0), PLUM_DARK, Enum.Material.WoodPlanks)
	for i, c in SWATCHES do
		part(m, "Swatch" .. i, Vector3.new(0.9, 0.9, 0.2), rack.CFrame * CFrame.new(-1 + ((i - 1) % 2) * 2, 1.7 - math.floor((i - 1) / 2) * 1.5, -0.3), c, Enum.Material.SmoothPlastic)
	end
	-- Paint pots on the counter top.
	for i, c in { SWATCHES[1], SWATCHES[3], SWATCHES[4] } do
		part(m, "PaintPot" .. i, Vector3.new(0.9, 0.9, 0.9), base * CFrame.new(-3.5 + i * 1.5, 4.25, 0), c, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	end
	-- Sign board over the awning (cream on plum, no outline).
	local sign = part(m, "Sign", Vector3.new(8.4, 2, 0.3), base * CFrame.new(0, 11.4, -1.7), PLUM_DARK, Enum.Material.WoodPlanks)
	signFace(sign, Config.TITLE, CREAM)
	-- Warm lamp on a post at the left (MapLight: LightLod keeps only the nearest decor lights on).
	part(m, "LampPost", Vector3.new(0.5, Config.STAND.lampHeight, 0.5), base * CFrame.new(-8, Config.STAND.lampHeight / 2, 0.4), PLUM_DARK, Enum.Material.Wood)
	local head = part(m, "LampHead", Vector3.new(1.4, 1.4, 1.4), base * CFrame.new(-8, Config.STAND.lampHeight + 0.7, 0.4), Color3.fromRGB(255, 214, 140), Enum.Material.Neon, Enum.PartType.Ball)
	head.CastShadow = false
	local light = Instance.new("PointLight")
	light.Name = "PaintShopLamp"
	light.Color = Color3.fromRGB(255, 196, 120)
	light.Brightness = 1.4
	light.Range = 26
	light.Shadows = false
	light:SetAttribute("MapLight", true)
	light.Parent = head
	-- Prompts: PAINT SHOP on the counter, VEHICLES on the rack.
	addPrompt(counter, Config.PROMPTS.paint, S.promptDistance, 0)
	addPrompt(rack, Config.PROMPTS.vehicles, S.promptDistance, 70)
	m.PrimaryPart = counter
	return m
end

function PaintShopStand.start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		task.wait(2)
		while true do
			local ok, err = pcall(function(): any
				local hub = workspace:GetAttribute("RaceMode") == "hub" and workspace:GetAttribute("TrackSwitching") ~= true
				if not hub then
					if model and model.Parent then
						model.Parent = nil
					end
				elseif not model then
					local m = build(groundY())
					model = m
					m.Parent = workspace
				elseif not model.Parent then
					model.Parent = workspace
				end
				return nil
			end)
			if not ok then
				warn("[SkyRally][PAINT_SHOP] stand failed: " .. tostring(err))
			end
			task.wait(1)
		end
	end)
end

function PaintShopStand.model(): Model?
	return model
end

return PaintShopStand
