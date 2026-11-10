--!strict
-- The Storm vendor's stand in the hub (economy v3 phase 5): a small cream-and-timber stall with slate-blue accents (Paint Shop kiosk kit) with an awning, a counter and a
-- hooded vendor figure (placeholder blocks until the owner's NPC art lands; docs/design/STORM_SHARDS.md), a
-- ProximityPrompt on the counter that opens the vendor panel (client/StormVendor), and the MarkerAnchor the hub storm
-- marker hangs from (client/HubStorm). Where it stands is one constant, StormConfig.STAND.
-- Like the leaderboard sign (server/HubBoard) the stand exists only while the server is in the hub (RaceMode "hub").
-- Every part is CanCollide = false and CanQuery = false: the stall can never become a wall, a barrier or a traversal trap
-- (owner rule: wall/mountain driving, barriers and rescue are never changed).
local StormConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("StormConfig"))

local StormVendorStand = {}

StormVendorStand.NAME = "StormVendorStand"

-- v29 B4: the Paint Shop stall kit (cream walls, striped canvas awning, timber counter, hanging plank sign); the storm
-- identity lives in accents only (slate-blue stripe, brass lightning emblem, warm lantern). No purple, no navy box.
local SLATE = Color3.fromRGB(74, 106, 154) -- #4a6a9a accent
local SLATE_DARK = Color3.fromRGB(94, 58, 36) -- dark timber (named for the old palette; used for posts and trim)
local TIMBER = Color3.fromRGB(150, 104, 66)
local CREAM = Color3.fromRGB(239, 224, 194)
local CANVAS = Color3.fromRGB(246, 238, 220)
local BRASS = Color3.fromRGB(214, 168, 70)
local GOLD = Color3.fromRGB(255, 222, 110)
local CLOAK = Color3.fromRGB(64, 78, 112)

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
	local S = StormConfig.STAND
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

local function build(y: number, onOpen: (Player) -> ()): Model
	local S = StormConfig.STAND
	local m = Instance.new("Model")
	m.Name = StormVendorStand.NAME
	local base = CFrame.lookAt(Vector3.new(S.pos.X, y, S.pos.Z), Vector3.new(S.faceToward.X, y, S.faceToward.Z))
	-- Counter (front), back wall, posts, awning.
	local counter = part(m, "Counter", Vector3.new(12, 3.6, 3), base * CFrame.new(0, 1.8, 0), TIMBER, Enum.Material.WoodPlanks)
	part(m, "CounterTop", Vector3.new(12.6, 0.4, 3.6), base * CFrame.new(0, 3.8, 0), SLATE_DARK, Enum.Material.Wood)
	-- Slate-blue stripe along the counter front and two inset timber panels.
	part(m, "CounterTrim", Vector3.new(12.2, 0.6, 0.2), base * CFrame.new(0, 2.9, -1.55), SLATE, Enum.Material.WoodPlanks)
	for _, x in { -3, 3 } do
		part(m, "CounterPanel", Vector3.new(4.6, 1.6, 0.15), base * CFrame.new(x, 1.5, -1.55), SLATE_DARK, Enum.Material.WoodPlanks)
	end
	part(m, "BackWall", Vector3.new(12, 9, 0.6), base * CFrame.new(0, 4.5, 5), CREAM, Enum.Material.Plaster)
	for _, x in { -5.8, 5.8 } do
		part(m, "Post", Vector3.new(0.8, 10, 0.8), base * CFrame.new(x, 5, -1.2), SLATE_DARK, Enum.Material.Wood)
	end
	for i = 1, 6 do -- striped canvas awning: six cream / slate-blue strips, low edge to the front
		part(m, "AwningStripe" .. i, Vector3.new(2.2, 0.4, 7.6), base * CFrame.new(-5.5 + (i - 1) * 2.2, 10.2, 1.6) * CFrame.Angles(math.rad(-10), 0, 0), if i % 2 == 1 then CANVAS else SLATE, Enum.Material.Fabric)
	end
	part(m, "AwningEdge", Vector3.new(13.4, 0.4, 0.3), base * CFrame.new(0, 9.6, -2.2), SLATE_DARK, Enum.Material.Wood)
	-- Placeholder vendor (needs art): a hooded figure behind the counter.
	part(m, "VendorBody", Vector3.new(2.6, 4.6, 1.8), base * CFrame.new(0, 4.4, 2.6), CLOAK, Enum.Material.Fabric)
	part(m, "VendorHood", Vector3.new(2.4, 2.4, 2.4), base * CFrame.new(0, 7.6, 2.6), CLOAK, Enum.Material.Fabric, Enum.PartType.Ball)
	part(m, "VendorEyes", Vector3.new(1.2, 0.25, 0.2), base * CFrame.new(0, 7.7, 1.4), GOLD, Enum.Material.SmoothPlastic)
	-- Warm lantern on a post at the left (MapLight: LightLod keeps only the nearest decor lights on).
	part(m, "LampPost", Vector3.new(0.5, 9, 0.5), base * CFrame.new(-7.6, 4.5, 0.4), SLATE_DARK, Enum.Material.Wood)
	local head = part(m, "LampHead", Vector3.new(1.4, 1.4, 1.4), base * CFrame.new(-7.6, 9.7, 0.4), Color3.fromRGB(255, 214, 140), Enum.Material.Neon, Enum.PartType.Ball)
	local lamp = Instance.new("PointLight")
	lamp.Name = "StormVendorLamp"
	lamp.Color = Color3.fromRGB(255, 196, 120)
	lamp.Brightness = 1.2
	lamp.Range = 24
	lamp.Shadows = false
	lamp:SetAttribute("MapLight", true)
	lamp.Parent = head
	-- Hanging plank sign over the awning, on two chains, with a brass lightning emblem (two slanted bars).
	local sign = part(m, "Sign", Vector3.new(9, 2.2, 0.3), base * CFrame.new(0, 12.6, -1.6), TIMBER, Enum.Material.WoodPlanks)
	for _, x in { -3.6, 3.6 } do
		part(m, "SignChain", Vector3.new(0.2, 1.6, 0.2), base * CFrame.new(x, 11.3, -1.6), SLATE_DARK, Enum.Material.Metal)
	end
	part(m, "EmblemA", Vector3.new(0.35, 1.5, 0.2), base * CFrame.new(-3.6, 12.7, -1.8) * CFrame.Angles(0, 0, math.rad(-25)), BRASS, Enum.Material.Metal)
	part(m, "EmblemB", Vector3.new(0.35, 1.0, 0.2), base * CFrame.new(-3.3, 12.4, -1.8) * CFrame.Angles(0, 0, math.rad(25)), BRASS, Enum.Material.Metal)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.8, 1)
	label.Position = UDim2.fromScale(0.17, 0)
	label.Text = "STORM VENDOR"
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = CREAM
	label.Parent = gui
	-- The hub storm marker hangs from this (client/HubStorm).
	local anchor = part(m, "MarkerAnchor", Vector3.new(1, 1, 1), base * CFrame.new(0, S.markerHeight, 0), SLATE, Enum.Material.SmoothPlastic)
	anchor.Transparency = 1
	-- The prompt on the counter.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StormVendorPrompt"
	prompt.ActionText = "Storm vendor"
	prompt.ObjectText = "Storm Shards"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = S.promptDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = counter
	prompt.Triggered:Connect(function(player: Player)
		onOpen(player)
	end)
	m.PrimaryPart = counter
	return m
end

-- onOpen(player): the prompt fired for that player (StormShards fires "OpenVendor" to them).
function StormVendorStand.start(onOpen: (Player) -> ())
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
					local m = build(groundY(), onOpen)
					model = m
					m.Parent = workspace
				elseif not model.Parent then
					model.Parent = workspace
				end
				return nil
			end)
			if not ok then
				warn("[SkyRally][STORM_SHARDS] stand failed: " .. tostring(err))
			end
			task.wait(1)
		end
	end)
end

function StormVendorStand.model(): Model?
	return model
end

return StormVendorStand
