--!strict
-- Photo finish, polaroid first (REMARKABLE Batch 2 item 23). Client only, display only.
--
--   * The photo cam: right after the LOCAL player crosses the line (their own RaceFinished), if the racer just ahead
--     finished within 0.6 s (the server's finish times in the standings) or a rival's car is within 0.6 s behind at
--     the finisher's speed (FinaleRules.shouldTakeover), the camera cuts side-on to the line for 1.3 s with a
--     viewfinder frame, a blinking REC dot, a flash and a shutter click. Never before crossing; never anyone else's.
--   * The polaroid: when the SERVER says it was close (server/PhotoFinish "PhotoFinish": the gap it measured, the
--     rival, who got there first), a polaroid slides in beside the results card (docked clear of it, scaled with the viewport, ResultsLayoutRules) and develops from milky
--     white over 2 s (motor whirr): the two real cars (display copies, liveries and all) staged nose to nose at the
--     server's gap at race speed, a checkered line, the verdict stamped across ("BY A NOSE!") and a handwritten
--     caption ("You pipped Pip by 0.08 s"). The notice can come after the card is up (the rival finished later): it
--     pins on whenever it arrives, until the card closes.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local FinaleRules = require(Shared:WaitForChild("FinaleRules"))
local ResultsLayoutRules = require(Shared:WaitForChild("ResultsLayoutRules"))
local SafeArea = require(script.Parent:WaitForChild("SafeArea"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))
local PayoffSound = require(script.Parent:WaitForChild("PayoffSound"))
local DisplayCars = require(script.Parent:WaitForChild("DisplayCars"))
local CarController = require(script.Parent:WaitForChild("CarController"))
local FlightController = require(script.Parent:WaitForChild("FlightController"))

local LocalPlayer = Players.LocalPlayer

local Polaroid = {}

local CAM_SECONDS = 1.3
local PAPER = Color3.fromRGB(250, 248, 238)
local INK = Color3.fromRGB(36, 30, 26)
local STAMP = Color3.fromRGB(214, 48, 40)
local CARD_W = ResultsLayoutRules.CARD_W
local CARD_H = ResultsLayoutRules.CARD_H
local SLIDE_FROM = 260 -- px the polaroid starts beyond its docked spot (it slides in from its own side)
local SLIDE_TIME = 0.45

local camGui: ScreenGui? = nil
local flashFrame: Frame
local recDot: Frame
local card: Frame? = nil
local cardSide = "left"
local cardDocked = false -- false while the slide-in tween owns the position
local cardConn: RBXScriptConnection? = nil
local pending: any = nil -- the server's notice, waiting for the results card
local modalRef: GuiObject? = nil
local snapshot: { pos: Vector3, look: Vector3, speed: number, isCar: boolean }? = nil
local photoModels: { Model } = {}

local function myHull(): (BasePart?, boolean)
	if CarController.car and CarController.hull and CarController.hull.Parent then
		return CarController.hull, true
	end
	local h = FlightController.hull
	return (if h and h.Parent then h else nil), false
end

local function mySpeed(isCar: boolean): number
	return if isCar then math.abs(CarController.speed) else math.abs(FlightController.currentSpeed)
end

local function buildCamGui(): ScreenGui
	local g = camGui
	if g and g.Parent then
		return g
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyPhotoCam"
	sg.IgnoreGuiInset = true
	sg.ScreenInsets = Enum.ScreenInsets.None -- placed from HudMetrics rects (insets already applied): a DeviceSafe gui would add the notch twice
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 24
	sg.Enabled = false
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	-- viewfinder corners
	for i, spec in { { 0.06, 0.1, 0, 0 }, { 0.94, 0.1, 1, 0 }, { 0.06, 0.9, 0, 1 }, { 0.94, 0.9, 1, 1 } } do
		local c = Instance.new("Frame")
		c.Name = "Corner" .. i
		c.BackgroundTransparency = 1
		c.AnchorPoint = Vector2.new(spec[3], spec[4])
		c.Position = UDim2.fromScale(spec[1], spec[2])
		c.Size = UDim2.fromOffset(46, 46)
		c.Parent = sg
		for _, hz in { true, false } do
			local bar = Instance.new("Frame")
			bar.BorderSizePixel = 0
			bar.BackgroundColor3 = PAPER
			bar.Size = if hz then UDim2.new(1, 0, 0, 4) else UDim2.new(0, 4, 1, 0)
			bar.Position = UDim2.fromScale(if hz then 0 else spec[3], if hz then spec[4] else 0)
			bar.AnchorPoint = Vector2.new(spec[3], spec[4])
			bar.Parent = c
		end
	end
	recDot = Instance.new("Frame")
	recDot.Name = "Rec"
	recDot.BackgroundColor3 = STAMP
	recDot.BorderSizePixel = 0
	recDot.Position = UDim2.fromScale(0.09, 0.14)
	recDot.Size = UDim2.fromOffset(16, 16)
	recDot.Parent = sg
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0.5, 0)
	rc.Parent = recDot
	local label = Instance.new("TextLabel")
	label.Name = "PhotoLabel"
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0.09, 24, 0.14, -4)
	label.Size = UDim2.fromOffset(220, 24)
	label.Font = Enum.Font.GothamBlack
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextScaled = true
	label.TextColor3 = PAPER
	label.Text = "PHOTO FINISH?"
	label.Parent = sg
	flashFrame = Instance.new("Frame")
	flashFrame.Name = "Flash"
	flashFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	flashFrame.BackgroundTransparency = 1
	flashFrame.BorderSizePixel = 0
	flashFrame.Size = UDim2.fromScale(1, 1)
	flashFrame.Parent = sg
	camGui = sg
	return sg
end

local function flash()
	flashFrame.BackgroundTransparency = 0.05
	TweenService:Create(flashFrame, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	PayoffSound.play("photo_shutter")
end

-- The rival's car nearest behind the finisher (distance along the finisher's heading), or nil.
local function behindDistance(pos: Vector3, look: Vector3): number?
	local folder = workspace:FindFirstChild("Planes")
	if not folder then
		return nil
	end
	local best: number? = nil
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("OwnerUserId") ~= LocalPlayer.UserId then
			local h = m.PrimaryPart
			if h then
				local rel = h.Position - pos
				local along = -rel:Dot(look)
				if along > 0 and along < 90 and (rel + look * along).Magnitude < 30 then
					if not best or along < best then
						best = along
					end
				end
			end
		end
	end
	return best
end

-- RaceFinished for the local player. Returns how long the photo cam holds the screen (0 = no takeover).
function Polaroid.onFinish(payload: any): number
	local hull, isCar = myHull()
	if not hull or type(payload) ~= "table" then
		snapshot = nil
		return 0
	end
	local look = hull.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = if flatLook.Magnitude > 1e-3 then flatLook.Unit else Vector3.new(0, 0, -1)
	local speed = mySpeed(isCar)
	snapshot = { pos = hull.Position, look = flatLook, speed = speed, isCar = isCar }
	if not FinaleRules.PHOTO_MODES[tostring(RaceAttr.mine("RaceMode"))] then
		return 0
	end
	local ahead = if type(payload.standings) == "table" and type(payload.rank) == "number" then FinaleRules.aheadGap(payload.standings, payload.rank) else nil
	local behind = behindDistance(hull.Position, flatLook)
	if not FinaleRules.shouldTakeover(ahead, behind, speed) then
		return 0
	end
	-- A sports photographer beside the line: a telephoto pan on the finisher, swinging back to the line for the rival
	-- behind as it arrives (its estimated crossing, the second flash).
	local sg = buildCamGui()
	sg.Enabled = true
	local right = flatLook:Cross(Vector3.yAxis)
	local p0 = hull.Position
	local camPos = p0 + right * 18 + Vector3.yAxis * 3 - flatLook * 2
	local line = p0 - flatLook * 3 + Vector3.yAxis
	local t0 = os.clock()
	local secondShot = if behind and speed > 1 then math.clamp(behind / speed, 0.25, 0.9) else nil
	local shots = 0
	RunService:BindToRenderStep("SkyRallyPhotoCam", Enum.RenderPriority.Last.Value + 4, function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local t = os.clock() - t0
		local follow = if hull.Parent then hull.Position + Vector3.yAxis else line
		local back = if secondShot then math.clamp((t - (secondShot - 0.3)) / 0.25, 0, 1) else 0
		cam.CFrame = CFrame.lookAt(camPos, follow:Lerp(line, back))
		cam.FieldOfView = 34
		recDot.BackgroundTransparency = if (t * 3) % 1 < 0.5 then 0 else 1
		if shots == 0 and t > 0.12 then
			shots = 1
			flash()
		elseif shots == 1 and secondShot and t > secondShot then
			shots = 2
			flash()
		end
	end)
	task.delay(CAM_SECONDS, function()
		RunService:UnbindFromRenderStep("SkyRallyPhotoCam")
		sg.Enabled = false
	end)
	return CAM_SECONDS
end

local function clearPhoto()
	for _, m in photoModels do
		m:Destroy()
	end
	table.clear(photoModels)
	local c = card
	if c then
		c:Destroy()
		card = nil
	end
	if cardConn then
		cardConn:Disconnect()
		cardConn = nil
	end
end

-- Where the polaroid docks beside the results card right now (shared/ResultsLayoutRules: never over the card, scaled
-- with the viewport, inside SafeArea's insets).
local function dockPlacement(modal: GuiObject): ResultsLayoutRules.Placement
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local col = HudMetrics.get().rects.leftColumn -- the gear / "?" / token cluster stays up in results (HUD_LAYOUT 6)
	local reserve = if col then col.x + col.w else nil
	local p = ResultsLayoutRules.place(vp.X, vp.Y, modal.AbsoluteSize.X, modal.AbsolutePosition.Y, SafeArea.get(), modal.AbsolutePosition.X, reserve)
	-- The card is a child of the (desktop UIScale'd) results card: its on-screen answer is divided by that scale.
	local ks = modal:FindFirstChild("CardScale")
	local k = if ks and ks:IsA("UIScale") and ks.Scale > 0 then ks.Scale else 1
	if k ~= 1 then
		p = { side = p.side, scale = p.scale / k, x = p.x / k, y = p.y / k }
	end
	return p
end

-- The staged photo: both cars side-on at the line, the leader's nose `stage` studs ahead.
local function stagePhoto(vpf: ViewportFrame, note: any)
	local mine = DisplayCars.localVehicle()
	local rival = DisplayCars.findRacer(tostring(note.rivalName or note.rival), note.rivalIsPlayer == true)
	local snap = snapshot
	local speed = if snap and snap.speed > 1 then snap.speed else 100
	local stage = FinaleRules.photoStage(tonumber(note.gap) or 0.1, speed)
	local world = Instance.new("Folder")
	world.Name = "Scene"
	world.Parent = vpf
	-- ground strip and the checkered line
	local ground = Instance.new("Part")
	ground.Anchored = true
	ground.Size = Vector3.new(70, 1, 30)
	ground.CFrame = CFrame.new(0, -0.5, 0)
	ground.Color = Color3.fromRGB(96, 92, 84)
	ground.Material = Enum.Material.SmoothPlastic
	ground.Parent = world
	for i = 0, 11 do
		for j = 0, 1 do
			local sq = Instance.new("Part")
			sq.Anchored = true
			sq.Size = Vector3.new(1.2, 0.1, 2.5)
			sq.CFrame = CFrame.new(-0.6 + j * 1.2, 0.02, -13.75 + i * 2.5)
			sq.Color = if (i + j) % 2 == 0 then Color3.new(1, 1, 1) else Color3.new(0.08, 0.08, 0.08)
			sq.Material = Enum.Material.SmoothPlastic
			sq.Parent = world
		end
	end
	local post = Instance.new("Part")
	post.Anchored = true
	post.Size = Vector3.new(0.6, 9, 0.6)
	post.CFrame = CFrame.new(0, 4.5, -12)
	post.Color = Color3.new(1, 1, 1)
	post.Parent = world
	-- Cars face +X (left to right across the frame); the leader's nose sits `stage` ahead of the other's.
	local won = note.won == true
	local function put(m: Model?, lane: number, noseX: number)
		if not m then
			return
		end
		local copy, size = DisplayCars.copy(m, 14)
		if not copy then
			return
		end
		DisplayCars.place(copy, CFrame.new(noseX - size.Z / 2, 0, lane) * CFrame.Angles(0, -math.pi / 2, 0))
		copy.Parent = world
		table.insert(photoModels, copy)
	end
	local leadX, trailX = 1.0, 1.0 - stage
	-- The finisher's own car in the near lane, the rival beyond it.
	put(mine, 3.2, if won then leadX else trailX)
	put(rival, -3.2, if won then trailX else leadX)
	local cam = Instance.new("Camera")
	cam.FieldOfView = 34
	local cx = 1.0 - stage / 2 - 4
	cam.CFrame = CFrame.lookAt(Vector3.new(cx, 3.2, 30), Vector3.new(cx, 1.6, 0))
	cam.Parent = vpf
	vpf.CurrentCamera = cam
	vpf.Ambient = Color3.fromRGB(150, 140, 125)
	vpf.LightColor = Color3.fromRGB(255, 240, 215)
	vpf.LightDirection = Vector3.new(-0.4, -1, -0.6)
end

local function buildCard(modal: GuiObject, note: any)
	clearPhoto()
	local place = dockPlacement(modal)
	if place.side == "none" then
		print("[SkyRally][PHOTO] polaroid skipped: no room beside the results card")
		return
	end
	cardSide = place.side
	local slideDir = if place.side == "left" then -1 else 1
	local c = Instance.new("Frame")
	c.Name = "PhotoFinishPolaroid"
	c.AnchorPoint = Vector2.new(if place.side == "left" then 1 else 0, 0)
	c.Position = UDim2.fromOffset(place.x + slideDir * SLIDE_FROM * place.scale, place.y)
	c.Size = UDim2.fromOffset(CARD_W, CARD_H)
	c.BackgroundColor3 = PAPER
	c.BorderSizePixel = 0
	c.Rotation = -7
	c.ZIndex = 8
	c.Parent = modal
	card = c
	local sc = Instance.new("UIScale")
	sc.Scale = place.scale
	sc.Parent = c
	cardDocked = false
	-- A resize / rotation while the card is up re-docks the photo (the slide-in owns the position until it lands).
	cardConn = modal:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if card ~= c or not cardDocked then
			return
		end
		local np = dockPlacement(modal)
		if np.side ~= cardSide or np.side == "none" then
			return -- the side flipping mid-card would jump; the next card picks it up
		end
		sc.Scale = np.scale
		c.Position = UDim2.fromOffset(np.x, np.y)
	end)
	local shadow = Instance.new("UIStroke")
	shadow.Color = Color3.fromRGB(120, 100, 80)
	shadow.Thickness = 1.5
	shadow.Parent = c
	local vpf = Instance.new("ViewportFrame")
	vpf.Name = "Photo"
	vpf.Position = UDim2.fromOffset(7, 7)
	vpf.Size = UDim2.new(1, -14, 0, CARD_W - 14)
	vpf.BackgroundColor3 = Color3.fromRGB(150, 196, 230)
	vpf.BorderSizePixel = 0
	vpf.ZIndex = 9
	vpf.Parent = c
	local sky = Instance.new("UIGradient")
	sky.Rotation = 90
	sky.Color = ColorSequence.new(Color3.fromRGB(176, 214, 240), Color3.fromRGB(236, 222, 190))
	sky.Parent = vpf
	stagePhoto(vpf, note)
	local milk = Instance.new("Frame")
	milk.Name = "Developing"
	milk.Position = vpf.Position
	milk.Size = vpf.Size
	milk.BackgroundColor3 = Color3.fromRGB(236, 238, 232)
	milk.BorderSizePixel = 0
	milk.ZIndex = 10
	milk.Parent = c
	local verdict = Instance.new("TextLabel")
	verdict.Name = "Verdict"
	verdict.BackgroundTransparency = 1
	verdict.AnchorPoint = Vector2.new(0.5, 0.5)
	verdict.Position = UDim2.new(0.5, 0, 0, 7 + (CARD_W - 14) * 0.5)
	verdict.Size = UDim2.new(1, -6, 0, 26)
	verdict.Rotation = -12
	verdict.Font = Enum.Font.GothamBlack
	verdict.TextScaled = true
	verdict.TextColor3 = STAMP
	verdict.TextTransparency = 1
	verdict.Text = FinaleRules.photoVerdict(tonumber(note.gap) or 0)
	verdict.ZIndex = 11
	verdict.Parent = c
	local vs = Instance.new("UIStroke")
	vs.Color = PAPER
	vs.Thickness = 2
	vs.Transparency = 1
	vs.Parent = verdict
	local vsc = Instance.new("UIScale")
	vsc.Parent = verdict
	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.BackgroundTransparency = 1
	caption.Position = UDim2.new(0, 5, 0, CARD_W - 4)
	caption.Size = UDim2.new(1, -10, 0, CARD_H - CARD_W)
	caption.Font = Enum.Font.PermanentMarker
	caption.TextScaled = true
	caption.TextWrapped = true
	caption.TextColor3 = INK
	caption.Text = FinaleRules.photoCaption(note.won == true, tonumber(note.gap) or 0, tostring(note.rival or "?"))
	caption.ZIndex = 9
	caption.Parent = c
	-- slide in, develop, stamp
	PayoffSound.play("photo_develop")
	TweenService:Create(c, TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(place.x, place.y) }):Play()
	task.delay(SLIDE_TIME + 0.05, function()
		if card == c then
			cardDocked = true
		end
	end)
	TweenService:Create(milk, TweenInfo.new(2.0, Enum.EasingStyle.Sine, Enum.EasingDirection.In, 0, false, 0.5), { BackgroundTransparency = 1 }):Play()
	task.delay(2.4, function()
		if card ~= c then
			return
		end
		vsc.Scale = 2.4
		verdict.TextTransparency = 0
		vs.Transparency = 0
		TweenService:Create(vsc, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		PayoffSound.play("podium_drop", 1.4, 0.8) -- the stamp thunk
		TweenService:Create(c, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 1, true), { Rotation = -9 }):Play()
	end)
	print(string.format("[SkyRally][PHOTO] polaroid gap=%.3f won=%s rival=%s", tonumber(note.gap) or -1, tostring(note.won), tostring(note.rival)))
end

-- The server's "PhotoFinish" notice (RaceEventRemote).
function Polaroid.onNotice(data: any)
	if type(data) ~= "table" or type(data.gap) ~= "number" then
		return
	end
	pending = data
	local m = modalRef
	if m and m.Parent and m.Visible then
		pending = nil
		buildCard(m, data)
	end
end

-- The results card is up: pin a waiting polaroid on it (and any that arrives while it stays up).
function Polaroid.attachTo(modal: GuiObject)
	modalRef = modal
	local note = pending
	if note then
		pending = nil
		buildCard(modal, note)
	end
end

-- A replay, a reset or a track switch: the photo goes.
function Polaroid.reset()
	pending = nil
	modalRef = nil
	snapshot = nil
	clearPhoto()
end

return Polaroid
