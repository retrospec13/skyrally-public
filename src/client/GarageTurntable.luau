--!strict
-- Garage turntable (REMARKABLE Batch 2 item 27): a ViewportFrame toy with character-select energy at the top of the
-- Garage's cosmetic tabs. Client only, display only: it shows a display copy of YOUR vehicle (client/DisplayCars) on a
-- slowly turning wooden turntable under a spotlight.
--   * It drops in on a bounce the first time the panel shows it ("boing"), name plate sliding in.
--   * Drag (finger or mouse) to spin it; let go and it coasts back to the idle spin (FinaleRules.turnStep).
--   * TRY on a livery row: a quick spin, a spray-can "psssht" and sparkles, and the copy wears that livery (painted
--     with the shared livery palette, shared/LiveryPaint; the server still paints the real car only on EQUIP).
--   * REV: the engine blips, the body squats and shakes; tap REV again quickly and it climbs to the limiter: a wheelie,
--     backfire pops (FinaleRules.revLevel). UI v2: no comic words (owner tone rule); the sparkles and sound carry it.
--   * HONK (and every horn's PLAY): the car hops on its springs ; your equipped horn plays (the
--     Garage's own preview), or a bulb-horn honk when none is equipped.
-- Cost: one copy and one turntable part, built when the Garage opens on a cosmetic tab; a RenderStepped camera orbit
-- only while the toy is on screen; the copy is freed when the Garage closes.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FinaleRules = require(Shared:WaitForChild("FinaleRules"))
local GarageModel = require(Shared:WaitForChild("GarageModel"))
local LiveryPaint = require(Shared:WaitForChild("LiveryPaint"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local PayoffSound = require(script.Parent:WaitForChild("PayoffSound"))
local DisplayCars = require(script.Parent:WaitForChild("DisplayCars"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local ArcadeUi = require(script.Parent:WaitForChild("ArcadeUi")) -- UI v2 look (navy stage, key buttons)

local LocalPlayer = Players.LocalPlayer

local GarageTurntable = {}

local CREAM = Color3.fromRGB(250, 242, 222)
local INK = Color3.fromRGB(40, 22, 12)
local WOOD = Color3.fromRGB(108, 76, 52)
local WOOD_DARK = Color3.fromRGB(62, 40, 24)
local ORANGE = Color3.fromRGB(196, 120, 24)
local GREEN = Color3.fromRGB(78, 148, 58)
local GOLD = Color3.fromRGB(255, 214, 90)
local CAR_MAX = 9

local root: Frame? = nil
local vpf: ViewportFrame
local vcam: Camera
local plate: TextLabel
local comic: TextLabel
local sparks: { ImageLabel } = {}
local copy: Model? = nil
local copyBase = CFrame.new()
local disc: Part? = nil
local angle = 0
local vel = FinaleRules.TURN_AUTO
local dragging = false
local dragX = 0
local loop: RBXScriptConnection? = nil
local dropped = false
local shownKey: string? = nil
local lastRevAt: number? = nil
local revLevel = 0
local anim: { kind: string, t0: number, seconds: number, level: number }? = nil

local function tex(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

local function corner(p: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = p
end

local function equippedLivery(): string?
	local loadout = GarageModel.decodeLoadout(LocalPlayer:GetAttribute("Equipped"))
	local car = copy and copy:GetAttribute("IsCar") == true
	local item = GarageModel.equipped(loadout, if car then "carLivery" else "planeLivery")
	return if item then item.key else nil
end

local function plateText(prefix: string, key: string?)
	local item = GarageModel.cosmetic(key)
	plate.Text = if item then string.format("%s: %s", prefix, string.upper(item.name)) else "YOUR RIDE"
end

-- UI v2 (owner: no comic words): the motion, sparkles and sound carry the moment; no text pops.
local function popComic(_text: string, _color: Color3) end

local function sparkle(color: Color3)
	for i, s in sparks do
		local a = (i - 1) / #sparks * math.pi * 2
		s.ImageColor3 = color
		s.Position = UDim2.fromScale(0.5, 0.55)
		s.Size = UDim2.fromOffset(22, 22)
		s.ImageTransparency = 0
		TweenService:Create(s, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, math.cos(a) * 90, 0.55, math.sin(a) * 45),
			ImageTransparency = 1,
			Rotation = 180,
		}):Play()
	end
end

local function pose(offset: CFrame)
	local c = copy
	if c and c.Parent then
		c:PivotTo(offset * copyBase)
	end
end

local function stepLoop(dt: number)
	local r = root
	if not r or not r.Parent or not r.Visible then
		return
	end
	if dragging then
		vel *= math.exp(-8 * dt) -- a held finger that stops moving stops the table
	end
	angle, vel = FinaleRules.turnStep(angle, vel, dt, dragging)
	local a = math.rad(angle)
	local dist = 15
	vcam.CFrame = CFrame.lookAt(Vector3.new(math.sin(a) * dist, 4.2, math.cos(a) * dist), Vector3.new(0, 1.4, 0))
	local an = anim
	if not an then
		return
	end
	local t = os.clock() - an.t0
	if t >= an.seconds then
		anim = nil
		pose(CFrame.new())
		return
	end
	local k = t / an.seconds
	if an.kind == "drop" then
		local y = 14 * (1 - TweenService:GetValue(k, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out))
		pose(CFrame.new(0, y, 0))
	elseif an.kind == "rev" then
		local env = math.sin(math.min(1, k * 1.6) * math.pi)
		local shake = 0.08 * env * math.sin(t * 190)
		local pitch = if an.level >= 3 then math.rad(20) * math.sin(math.min(1, k * 1.3) * math.pi) else math.rad(3.5) * env
		-- Pivot on the rear axle for the wheelie (copies face -Z: the rear is +Z).
		local rear = 0.42 * CAR_MAX
		pose(CFrame.new(shake, math.abs(shake), rear) * CFrame.Angles(pitch, 0, 0) * CFrame.new(0, 0, -rear))
	elseif an.kind == "hop" then
		local h = 1.4 * math.sin(k * math.pi)
		local squash = if k < 0.15 then -0.05 else 0
		pose(CFrame.new(0, h + squash, 0) * CFrame.Angles(math.rad(6) * math.sin(k * math.pi * 2), 0, 0))
	end
end

local function buildCopy()
	if copy then
		copy:Destroy()
		copy = nil
	end
	local live = DisplayCars.localVehicle()
	if not live then
		plate.Text = "HOP IN A VEHICLE TO SEE IT HERE"
		return
	end
	local c = DisplayCars.copy(live, CAR_MAX)
	if not c then
		return
	end
	c:SetAttribute("IsCar", live:GetAttribute("IsCar") == true)
	c.Parent = vpf
	copy = c
	copyBase = c:GetPivot()
	shownKey = equippedLivery()
	plateText("EQUIPPED", shownKey)
end

local function startAnim(kind: string, seconds: number, level: number?)
	anim = { kind = kind, t0 = os.clock(), seconds = seconds, level = level or 1 }
end

local function build(): Frame
	-- UI v2: a navy inset stage; the copy turns on a dark disc with a gold rim, the name plate along the bottom.
	local f = ArcadeUi.card(nil, { name = "Showroom", inset = true, radius = 12 })
	local glow = Instance.new("ImageLabel")
	glow.Name = "Spotlight"
	glow.BackgroundTransparency = 1
	glow.Image = tex("glow_soft")
	glow.ImageColor3 = Color3.fromRGB(120, 190, 255)
	glow.ImageTransparency = 0.35
	glow.Position = UDim2.fromScale(0.05, -0.15)
	glow.Size = UDim2.fromScale(0.9, 1.1)
	glow.Parent = f
	vpf = Instance.new("ViewportFrame")
	vpf.Name = "Turntable"
	vpf.BackgroundTransparency = 1
	vpf.Position = UDim2.fromOffset(0, 0)
	vpf.Size = UDim2.new(1, 0, 1, -48)
	vpf.Ambient = Color3.fromRGB(225, 228, 238) -- UI v2: showroom light (bright ambient, a front-top key)
	vpf.LightColor = Color3.fromRGB(255, 255, 255)
	vpf.LightDirection = Vector3.new(0.4, -0.85, -0.6)
	vpf.Active = true
	vpf.Parent = f
	vcam = Instance.new("Camera")
	vcam.FieldOfView = 38
	vcam.Parent = vpf
	vpf.CurrentCamera = vcam
	local d = Instance.new("Part")
	d.Name = "Disc"
	d.Shape = Enum.PartType.Cylinder
	d.Anchored = true
	d.Size = Vector3.new(0.6, 13, 13)
	d.CFrame = CFrame.new(0, -0.3, 0) * CFrame.Angles(0, 0, math.rad(90))
	d.Color = Color3.fromRGB(30, 44, 96)
	d.Material = Enum.Material.SmoothPlastic
	d.Parent = vpf
	disc = d
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.Size = Vector3.new(0.5, 13.8, 13.8)
	ring.CFrame = CFrame.new(0, -0.38, 0) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = GOLD
	ring.Material = Enum.Material.Metal
	ring.Parent = vpf
	for i = 1, 8 do
		local s = Instance.new("ImageLabel")
		s.Name = "Spark" .. i
		s.BackgroundTransparency = 1
		s.Image = tex("star_twinkle")
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.ImageTransparency = 1
		s.ZIndex = 3
		s.Parent = vpf
		table.insert(sparks, s)
	end
	comic = Instance.new("TextLabel")
	comic.Name = "Comic"
	comic.BackgroundTransparency = 1
	comic.AnchorPoint = Vector2.new(0.5, 0.5)
	comic.Position = UDim2.fromScale(0.33, 0.2)
	comic.Size = UDim2.fromScale(0.4, 0.3)
	comic.Font = Enum.Font.Bangers
	comic.TextScaled = true
	comic.Visible = false
	comic.ZIndex = 4
	comic.Parent = f
	local cs = Instance.new("UIStroke")
	cs.Color = INK
	cs.Thickness = 3
	cs.Parent = comic
	Instance.new("UIScale").Parent = comic
	plate = ArcadeUi.text(f, { name = "Plate", text = "YOUR RIDE", font = ArcadeUi.FONT.display, maxSize = 20, minSize = 12, color = GOLD })
	plate.Position = UDim2.new(0, 10, 1, -46)
	plate.Size = UDim2.new(1, -124, 0, 40)
	plate.TextTruncate = Enum.TextTruncate.AtEnd
	-- REV and HONK: two 44 px icon keys in the bottom-right corner of the stage.
	local function bigButton(name: string, icon: string, variant: string, slot: number, onTap: () -> ())
		local b = ArcadeUi.button(f, variant, "", { name = name, icon = icon, iconOnly = true, size = UDim2.fromOffset(48, 44), anchor = Vector2.new(1, 1), position = UDim2.new(1, -6 - (slot - 1) * 54, 1, -4), radius = 10 })
		b.Activated:Connect(onTap)
	end
	bigButton("Honk", "horn", "go", 1, function()
		GarageTurntable.honk(nil, true)
	end)
	bigButton("Rev", "boost", "orange", 2, function()
		GarageTurntable.rev()
	end)
	vpf.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragX = input.Position.X
			vel = 0
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local dx = input.Position.X - dragX
			dragX = input.Position.X
			vel = -dx * 30 -- deg/s from px per frame-ish: a flick spins it
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	return f
end

-- Puts the toy at the top of the Garage content (`section`: Garage's first section frame), sized to the content width.
function GarageTurntable.mount(section: Frame, width: number, compact: boolean)
	local r = root or build()
	root = r
	section.AutomaticSize = Enum.AutomaticSize.None
	section.Size = UDim2.new(1, -6, 0, if compact then 116 else 170)
	r.Size = UDim2.fromScale(1, 1)
	r.Visible = true
	r.Parent = section
	if not copy or not copy.Parent then
		buildCopy()
		dropped = false
	end
	if not loop then
		loop = RunService.RenderStepped:Connect(stepLoop)
	end
	if not dropped and copy then
		dropped = true
		startAnim("drop", 0.7)
		task.delay(0.12, function()
			PayoffSound.play("hop_boing", 0.9)
		end)
		plate.Position = UDim2.new(-0.6, 10, 1, -46)
		TweenService:Create(plate, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.new(0, 10, 1, -46) }):Play()
	end
end

-- Garage.render is about to destroy the content: keep the toy alive by lifting it out first.
function GarageTurntable.detach()
	local r = root
	if r then
		r.Parent = nil
	end
end

-- TRY a livery on the copy (nil = what is equipped).
function GarageTurntable.preview(key: string?)
	local c = copy
	if not c or not c.Parent then
		return
	end
	local want = if key == nil then equippedLivery() elseif key == "" then nil else key -- "" = the builder's default paint
	vel = 720
	PayoffSound.play("garage_paint")
	task.delay(0.15, function()
		if copy ~= c then
			return
		end
		LiveryPaint.apply(c, want)
		shownKey = want
		local item = GarageModel.cosmetic(want)
		local tint = if item and item.livery then Color3.fromRGB(item.livery.accent[1], item.livery.accent[2], item.livery.accent[3]) else GOLD
		sparkle(tint)
		plateText(if want == equippedLivery() then "EQUIPPED" else "TRYING", want)
	end)
end

function GarageTurntable.rev()
	if not copy then
		return
	end
	local now = os.clock()
	revLevel = FinaleRules.revLevel(lastRevAt, now, revLevel)
	lastRevAt = now
	if revLevel >= 3 then
		PayoffSound.play("garage_redline")
		startAnim("rev", 1.6, 3)
		task.delay(1.2, function()
			popComic("BANG!", Color3.fromRGB(255, 120, 60))
		end)
	else
		PayoffSound.play("garage_rev", if revLevel == 2 then 1.12 else 1)
		startAnim("rev", 1.1, revLevel)
		popComic(if revLevel == 2 then "VROOOM!" else "VROOM!", GOLD)
	end
end

-- HONK button (playSound) or a horn row's PLAY (the Garage plays that horn itself): the car hops with a bubble.
function GarageTurntable.honk(_hornKey: string?, playSound: boolean?)
	if not copy then
		return
	end
	if playSound then
		local loadout = GarageModel.decodeLoadout(LocalPlayer:GetAttribute("Equipped"))
		local horn = GarageModel.equipped(loadout, "horn")
		if horn then
			local Cosmetics = require(script.Parent:WaitForChild("Cosmetics")) :: any
			Cosmetics.previewHorn(horn.key)
		else
			PayoffSound.play("garage_honk")
		end
	end
	startAnim("hop", 0.42)
	popComic("HONK!", CREAM)
end

-- The Garage closed: stop the orbit and free the copy (the next open builds a fresh one, livery and all).
function GarageTurntable.close()
	if loop then
		loop:Disconnect()
		loop = nil
	end
	if copy then
		copy:Destroy()
		copy = nil
	end
	anim = nil
	dragging = false
	local r = root
	if r then
		r.Parent = nil
	end
end

return GarageTurntable
