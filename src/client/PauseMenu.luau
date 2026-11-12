--!strict
-- v38-flow: the in-race pause / options screen (Mario Kart 8's + menu, in the UI v2 look). Online play never stops the
-- world, so the race keeps running underneath, and the card says so in one short line. Reachable in any race from the
-- HUD gear, P or O on a keyboard, and both bumpers on a gamepad (client/Settings routes them here while a race runs).
--   RESUME (go, focused)       closes the card
--   RESTART (sky)              FlightController.requestPlayAgain(): the server decides (solo only; refused in a group)
--   OPTIONS (sky)              the Settings plaque (volume bars and toggles) over this card
--   CONTROLS (sky)             the real bindings for the active input family and vehicle (InputMode / VehicleKind)
--   QUIT TO HUB (danger)       TrackFlowRemote "RequestHub": the server decides (solo, or a cup's own quit)
-- RESTART and QUIT show dimmed with one reason line when other racers share the race (the server would refuse them).
-- Presentation only: every action is a request the server already validates.
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local TrackInfo = require(Shared:WaitForChild("TrackInfo"))
local UiSkinRules = require(Shared:WaitForChild("UiSkinRules"))
local UiSkin = require(script.Parent:WaitForChild("UiSkin"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local UiMotion = require(script.Parent:WaitForChild("UiMotion"))

local LocalPlayer = Players.LocalPlayer

local PauseMenu = {}

local W, H = 440, 384 -- panel units at scale 1 (fits 844x390 at about 0.91)
local BTN_H = 54 -- touch floor 44; tall keys fill the card at 1080p

-- The real bindings (CarController / FlightController / ItemClient): action, then the key words per input family.
-- (FlightController is not required here: it requires Settings, which requires this module.)
type Row = { action: string, keys: { [string]: string } }
local CAR_ROWS: { Row } = {
	{ action = "STEER", keys = { KeyboardMouse = "A / D", Gamepad = "LEFT STICK", Touch = "LEFT PAD" } },
	{ action = "GAS", keys = { KeyboardMouse = "W", Gamepad = "A / RT", Touch = "AUTO" } },
	{ action = "BRAKE", keys = { KeyboardMouse = "S", Gamepad = "B / LT", Touch = "BRAKE" } },
	{ action = "DRIFT / HOP", keys = { KeyboardMouse = "SHIFT", Gamepad = "R1", Touch = "TURN" } },
	{ action = "ITEM", keys = { KeyboardMouse = "F", Gamepad = "X", Touch = "ITEM" } },
	{ action = "RESPAWN", keys = { KeyboardMouse = "BACKSPACE", Gamepad = "VIEW", Touch = "RESPAWN" } },
}
local PLANE_ROWS: { Row } = {
	{ action = "STEER", keys = { KeyboardMouse = "A / D", Gamepad = "LEFT STICK", Touch = "LEFT PAD" } },
	{ action = "CLIMB / DIVE", keys = { KeyboardMouse = "E / Q", Gamepad = "STICK UP / DOWN", Touch = "PAD UP / DOWN" } },
	{ action = "GAS", keys = { KeyboardMouse = "W", Gamepad = "A / RT", Touch = "AUTO" } },
	{ action = "SHARP BANK", keys = { KeyboardMouse = "SHIFT", Gamepad = "R1", Touch = "TURN" } },
	{ action = "ITEM", keys = { KeyboardMouse = "F", Gamepad = "X", Touch = "ITEM" } },
	{ action = "RESPAWN", keys = { KeyboardMouse = "BACKSPACE", Gamepad = "VIEW", Touch = "RESPAWN" } },
}
PauseMenu.CAR_ROWS = CAR_ROWS
PauseMenu.PLANE_ROWS = PLANE_ROWS

local built = false
local isOpen = false
local gui: ScreenGui
local scrim: TextButton
local holder: Frame
local panel: Frame
local fit: UIScale
local menuPage: Frame
local controlsPage: Frame
local controlsList: Frame
local controlsTitle: TextLabel
local resumeBtn: GuiButton
local restartBtn: GuiButton
local optionsBtn: GuiButton
local controlsBtn: GuiButton
local quitBtn: GuiButton
local backBtn: GuiButton
local reasonLabel: TextLabel
local promptLabel: TextLabel
local openSettings: (() -> ())? = nil
local prevSelection: GuiObject? = nil

local function family(): string
	local m = LocalPlayer:GetAttribute("InputMode")
	return if m == "Touch" or m == "Gamepad" then m :: string else "KeyboardMouse"
end

local function vehicleKind(): string
	local info = TrackInfo.get(RaceAttr.mine("ActiveTrackId") :: string?)
	return if info and info.vehicle == "plane" then "plane" else "car"
end

-- Other humans share the race: the server refuses a mid-race restart or quit (RaceFlowRules.canVote).
local function shared(): boolean
	local n = RaceAttr.mine("VoteHumans")
	if type(n) == "number" and n >= 2 then
		return true
	end
	return #Players:GetPlayers() >= 2
end

local function fitScale()
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(844, 390)
	fit.Scale = math.clamp(math.min(vp.X * 0.9 / W, vp.Y * 0.9 / H), 0.6, 1.5)
end

local function selectFirst(b: GuiObject)
	if LocalPlayer:GetAttribute("InputMode") == "Gamepad" or UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		UiSound.hush()
		GuiService.SelectedObject = b
	end
end

local function fillControls()
	for _, ch in controlsList:GetChildren() do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	local fam = family()
	local rows: { Row } = if vehicleKind() == "plane" then PLANE_ROWS else CAR_ROWS
	controlsTitle.Text = if fam == "Gamepad" then "CONTROLLER" elseif fam == "Touch" then "TOUCH" else "KEYBOARD"
	for i, r in rows do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.BackgroundTransparency = 1
		row.LayoutOrder = i
		row.Size = UDim2.new(1, 0, 0, 28)
		row.Parent = controlsList
		local chip, chipLabel = UiSkin.chip(row, r.keys[fam] or r.keys.KeyboardMouse, nil, {
			name = "Key",
			variant = "sky",
			size = UDim2.new(0.44, 0, 1, -4),
			position = UDim2.new(0, 0, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			S = 1,
		})
		chipLabel.FontFace = UiSkin.font("button")
		local _ = chip
		UiSkin.text(row, r.action, "body", {
			name = "Action",
			size = UDim2.new(0.54, 0, 1, 0),
			position = UDim2.new(1, 0, 0, 0),
			anchor = Vector2.new(1, 0),
			align = "left",
			maxText = 20,
			S = 1,
		})
	end
end

local function showControls(on: boolean)
	if on then
		fillControls()
	end
	UiSound.play(UiSkinRules.cueFor("swipe") or "swipe", nil, 0.7)
	local inP, outP = if on then controlsPage else menuPage, if on then menuPage else controlsPage
	outP.Visible = false
	UiMotion.show(inP, "swooshIn", { side = if on then "right" else "left", silent = true })
	selectFirst(if on then backBtn else controlsBtn)
end

local function paintPrompt()
	local fam = family()
	promptLabel.Text = if fam == "Gamepad" then "A  SELECT     B  BACK" elseif fam == "KeyboardMouse" then "P  RESUME" else ""
	promptLabel.Visible = promptLabel.Text ~= ""
end

local function paintAvailability()
	local lock = shared()
	local gp = workspace:GetAttribute("GPActive") == true
	local storm = RaceAttr.mine("RaceMode") == "stormcup" or RaceAttr.mine("RaceMode") == "stormrace"
	local canRestart = not lock and not gp and not storm
	UiSkin.setEnabled(restartBtn, canRestart)
	UiSkin.setEnabled(quitBtn, not lock or gp)
	reasonLabel.Text = if lock and not gp then "Others are racing: finish to leave" elseif gp then "No restart in a cup" elseif storm then "No restart in a storm race" else ""
	reasonLabel.Visible = reasonLabel.Text ~= ""
end

local function key(name: string, text: string, variant: string, order: number, glyph: string?): GuiButton
	local b = UiSkin.button(menuPage, "btn_" .. variant, text, {
		name = name,
		variant = variant,
		size = UDim2.new(1, 0, 0, BTN_H),
		layoutOrder = order,
		maxText = 24,
		glyph = glyph,
		S = 1,
		sound = if variant == "danger" then "back" else "tap",
	})
	return b
end

local function build()
	if built then
		return
	end
	built = true
	gui = Instance.new("ScreenGui")
	gui.Name = "SkyRallyPause"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 29 -- under the Settings plaque (30), over the HUD and the Garage
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	scrim = Instance.new("TextButton")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = UiSkin.color("ink")
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	scrim.Text = ""
	scrim.AutoButtonColor = false
	scrim.Selectable = false
	scrim.Parent = gui
	scrim.Activated:Connect(function()
		PauseMenu.close()
	end)
	UiSkin.wedge(scrim, { zIndex = 1, alpha = 0.25 })

	holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(W, H)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	panel = UiSkin.panel(holder, "panel", {
		name = "PausePanel",
		variant = "panel",
		size = UDim2.fromScale(1, 1),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		S = 1,
		active = true,
	})
	-- the viewport fit lives on the panel; UiMotion's pop scales the holder (one UIScale each, or the pop resets the fit)
	fit = Instance.new("UIScale")
	fit.Parent = panel
	panel.SelectionGroup = true
	panel.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
	panel.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	panel.ClipsDescendants = false

	local band = UiSkin.header(panel, "PAUSE", {
		name = "Band",
		size = UDim2.new(0.62, 0, 0, 46),
		position = UDim2.new(0.5, 0, 0, -18),
		anchor = Vector2.new(0.5, 0),
		S = 1,
		maxText = 30,
	})
	band.Rotation = -2
	local live = UiSkin.text(panel, "THE RACE KEEPS GOING", "body", {
		name = "Live",
		size = UDim2.new(1, -32, 0, 18),
		position = UDim2.new(0.5, 0, 0, 34),
		anchor = Vector2.new(0.5, 0),
		color = UiSkin.color("gold"),
		maxText = 15,
		S = 1,
	})
	local _ = live

	menuPage = Instance.new("Frame")
	menuPage.Name = "Menu"
	menuPage.BackgroundTransparency = 1
	menuPage.Position = UDim2.fromOffset(40, 58)
	menuPage.Size = UDim2.new(1, -80, 1, -70)
	menuPage.Parent = panel
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 10)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Parent = menuPage

	resumeBtn = key("Resume", "RESUME", "go", 1, "play")
	-- RESTART and QUIT share one row (both the server's call), so the column stays inside a phone's height.
	local pair = Instance.new("Frame")
	pair.Name = "Pair"
	pair.BackgroundTransparency = 1
	pair.Size = UDim2.new(1, 0, 0, BTN_H)
	pair.LayoutOrder = 2
	pair.Parent = menuPage
	restartBtn = key("Restart", "RESTART", "sky", 0, "rematch")
	restartBtn.Parent = pair
	restartBtn.Size = UDim2.new(0.5, -3, 1, 0)
	optionsBtn = key("Options", "OPTIONS", "sky", 3, "gear")
	controlsBtn = key("Controls", "CONTROLS", "sky", 4, nil)
	quitBtn = key("Quit", "QUIT", "danger", 0, nil)
	quitBtn.Parent = pair
	quitBtn.Size = UDim2.new(0.5, -3, 1, 0)
	quitBtn.Position = UDim2.fromScale(1, 0)
	quitBtn.AnchorPoint = Vector2.new(1, 0)
	reasonLabel = UiSkin.text(menuPage, "", "body", {
		name = "Reason",
		size = UDim2.new(1, 0, 0, 18),
		layoutOrder = 5,
		color = Color3.fromRGB(255, 190, 170),
		maxText = 14,
		S = 1,
	})

	-- Input-aware prompt line along the bottom edge (gamepad / keyboard words; touch needs none).
	promptLabel = UiSkin.text(panel, "", "body", {
		name = "Prompt",
		size = UDim2.new(1, -32, 0, 16),
		position = UDim2.new(0.5, 0, 1, -6),
		anchor = Vector2.new(0.5, 1),
		color = UiSkin.color("white"),
		maxText = 13,
		S = 1,
	})

	UiSkin.listCursor(panel, { resumeBtn, restartBtn, quitBtn, optionsBtn, controlsBtn })

	-- Gamepad path: a straight column, the pair left / right.
	resumeBtn.NextSelectionDown = restartBtn
	restartBtn.NextSelectionUp = resumeBtn
	quitBtn.NextSelectionUp = resumeBtn
	restartBtn.NextSelectionRight = quitBtn
	quitBtn.NextSelectionLeft = restartBtn
	restartBtn.NextSelectionDown = optionsBtn
	quitBtn.NextSelectionDown = optionsBtn
	optionsBtn.NextSelectionUp = restartBtn
	optionsBtn.NextSelectionDown = controlsBtn
	controlsBtn.NextSelectionUp = optionsBtn

	controlsPage = Instance.new("Frame")
	controlsPage.Name = "ControlsPage"
	controlsPage.BackgroundTransparency = 1
	controlsPage.Position = UDim2.fromOffset(24, 56)
	controlsPage.Size = UDim2.new(1, -48, 1, -80) -- clear of the prompt line
	controlsPage.Visible = false
	controlsPage.Parent = panel
	controlsTitle = UiSkin.text(controlsPage, "KEYBOARD", "title", {
		name = "Family",
		size = UDim2.new(0.6, 0, 0, 22),
		align = "left",
		maxText = 20,
		S = 1,
	})
	controlsList = UiSkin.inset(controlsPage, {
		name = "List",
		size = UDim2.new(1, 0, 1, -24 - BTN_H - 8),
		position = UDim2.fromOffset(0, 26),
		S = 1,
	})
	local cl = Instance.new("UIListLayout")
	cl.Padding = UDim.new(0, 2)
	cl.SortOrder = Enum.SortOrder.LayoutOrder
	cl.Parent = controlsList
	local cp = Instance.new("UIPadding")
	cp.PaddingLeft = UDim.new(0, 10)
	cp.PaddingRight = UDim.new(0, 10)
	cp.PaddingTop = UDim.new(0, 6)
	cp.Parent = controlsList
	backBtn = UiSkin.button(controlsPage, "btn_sky", "BACK", {
		name = "Back",
		variant = "sky",
		size = UDim2.new(0.5, 0, 0, BTN_H),
		position = UDim2.new(0.5, 0, 1, 0),
		anchor = Vector2.new(0.5, 1),
		maxText = 22,
		S = 1,
		sound = "back",
	})

	resumeBtn.Activated:Connect(function()
		PauseMenu.close()
	end)
	restartBtn.Activated:Connect(function()
		if restartBtn:GetAttribute("SkinDisabled") == true then
			return
		end
		PauseMenu.close(true)
		-- The same request as the results card's RACE AGAIN (FlightController.requestPlayAgain); the server decides.
		local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
		local r = remotes and remotes:FindFirstChild("FlightStateRemote")
		if r and r:IsA("RemoteEvent") then
			r:FireServer("RequestPlayAgain")
		end
	end)
	quitBtn.Activated:Connect(function()
		if quitBtn:GetAttribute("SkinDisabled") == true then
			return
		end
		PauseMenu.close(true)
		local remotes = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
		local r = remotes and remotes:FindFirstChild("TrackFlowRemote")
		if r and r:IsA("RemoteEvent") then
			r:FireServer("RequestHub")
		end
	end)
	optionsBtn.Activated:Connect(function()
		local f = openSettings
		if f then
			f()
		end
	end)
	controlsBtn.Activated:Connect(function()
		showControls(true)
	end)
	backBtn.Activated:Connect(function()
		showControls(false)
	end)

	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale)
	end
	LocalPlayer:GetAttributeChangedSignal("InputMode"):Connect(function()
		if isOpen then
			paintPrompt()
			if controlsPage.Visible then
				fillControls()
			end
		end
	end)
	-- A track switch or the race ending takes the card away (results and the hub own the screen then).
	workspace:GetAttributeChangedSignal("TrackSwitching"):Connect(function()
		if workspace:GetAttribute("TrackSwitching") == true then
			PauseMenu.close(true)
		end
	end)
	RaceAttr.changed("RaceMode", function()
		if RaceAttr.mine("RaceMode") == "hub" then
			PauseMenu.close(true)
		end
	end)
end

function PauseMenu.isOpen(): boolean
	return isOpen
end

-- Settings registers how OPTIONS opens its plaque (it sits over this card).
function PauseMenu.setOptions(fn: () -> ())
	openSettings = fn
end

local function backAction(_n: string, state: Enum.UserInputState, _o: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin or not isOpen then
		return Enum.ContextActionResult.Pass
	end
	if controlsPage.Visible then
		showControls(false)
	else
		PauseMenu.close()
	end
	return Enum.ContextActionResult.Sink
end

function PauseMenu.open()
	build()
	if isOpen then
		return
	end
	isOpen = true
	LocalPlayer:SetAttribute("PauseOpen", true) -- round 3: NotifyKit keeps its toasts / banners off the card meanwhile
	fitScale()
	paintAvailability()
	paintPrompt()
	controlsPage.Visible = false
	menuPage.Visible = true
	local sel = GuiService.SelectedObject
	prevSelection = if sel and not sel:IsDescendantOf(gui) and sel:IsA("GuiObject") then sel else nil
	gui.Enabled = true
	TweenService:Create(scrim, TweenInfo.new(UiSkinRules.SCRIM.fadeIn), { BackgroundTransparency = UiSkinRules.SCRIM.alpha }):Play()
	UiMotion.show(holder, "popIn")
	ContextActionService:BindActionAtPriority("SkyRallyPauseBack", backAction, false, Enum.ContextActionPriority.High.Value + 25, Enum.KeyCode.ButtonB)
	selectFirst(resumeBtn)
end

function PauseMenu.close(silent: boolean?)
	if not built or not isOpen then
		return
	end
	isOpen = false
	LocalPlayer:SetAttribute("PauseOpen", nil)
	ContextActionService:UnbindAction("SkyRallyPauseBack")
	TweenService:Create(scrim, TweenInfo.new(UiSkinRules.SCRIM.fadeOut), { BackgroundTransparency = 1 }):Play()
	UiMotion.hide(holder, "popOut", function()
		if not isOpen then
			gui.Enabled = false
		end
	end, { silent = silent == true })
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(gui) then
		local prev = prevSelection
		GuiService.SelectedObject = if prev and prev.Parent and prev.Visible then prev else nil
	end
	prevSelection = nil
end

function PauseMenu.toggle()
	if isOpen then
		UiSound.play("back")
		PauseMenu.close()
	else
		UiSound.play("tab")
		PauseMenu.open()
	end
end

return PauseMenu
