--!strict
-- Input mode (D20: mobile landscape, desktop, console-ready). Tracks the active input family, shows the touch
-- controls only for Touch, and gives a short non-modal controls hint at join and whenever the family changes.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
-- L28 / L82: the hint keeps clear of the home bar and the TV overscan (HudMetrics' hintChip rect has the insets applied).
local HudMetrics = require(script.Parent.HudMetrics)
-- HUD layout v2, section 8: when key badges may show, and when a mouse must not flip a touch device out of Touch.
local HudLayoutRules = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("HudLayoutRules"))

local InputMode = {}

export type Mode = "Touch" | "Gamepad" | "KeyboardMouse"

-- Touch has no hint: the pad and zones teach themselves, and the chip is keyboard / gamepad only (HUD_LAYOUT section 4.2).
local HINTS: { [string]: string } = {
	Touch = "",
	Gamepad = "Stick steer · A gas · B brake · R1 bank",
	KeyboardMouse = "A/D steer · W gas · S brake · Shift bank",
}
local HINT_SHOW_S = 6 -- seconds the chip stays after the loading screen leaves, then it fades over HINT_FADE_S
local HINT_FADE_S = 0.8

InputMode.current = "KeyboardMouse" :: Mode

local function viewportY(): number
	local cam = workspace.CurrentCamera
	return if cam then cam.ViewportSize.Y else 720
end

-- The last REAL input family's name (Touch, Keyboard, Gamepad1, MouseMovement ...); Focus, TextInput and the like do
-- not count. Starts from what the engine reports.
local lastInputName = "Keyboard"
local lastGlyphs: string? = nil -- nil until the first refresh, so GlyphMode is always set ("none" before any input)

-- Which key badges to draw (spec section 8): "gamepad" after a pad, "keyboard" after a key, or after a mouse on a
-- device that is not touch-like (touch-only, or a phone-class viewport such as the Studio phone emulator); else "none".
-- QA's ForceInputMode wins. HudExtras redraws its badges when the GlyphMode player attribute changes.
function InputMode.showGlyphs(): HudLayoutRules.Glyphs
	local forced = Players.LocalPlayer:GetAttribute("ForceInputMode")
	if forced == "Touch" then
		return "none"
	elseif forced == "KeyboardMouse" then
		return "keyboard"
	elseif forced == "Gamepad" then
		return "gamepad"
	end
	return HudLayoutRules.glyphMode(lastInputName, UserInputService.TouchEnabled, UserInputService.KeyboardEnabled, viewportY())
end

local function refreshGlyphs()
	local g = InputMode.showGlyphs()
	if g ~= lastGlyphs then
		lastGlyphs = g
		Players.LocalPlayer:SetAttribute("GlyphMode", g)
	end
end

local function classify(t: Enum.UserInputType): Mode?
	if t == Enum.UserInputType.Touch then
		return "Touch"
	elseif string.find(t.Name, "Gamepad") then
		return "Gamepad"
	elseif t == Enum.UserInputType.Keyboard or string.find(t.Name, "Mouse") then
		return "KeyboardMouse"
	end
	return nil
end

local function initialMode(): Mode
	if HudLayoutRules.touchLike(UserInputService.TouchEnabled, UserInputService.KeyboardEnabled, viewportY()) then
		return "Touch" -- touch-only, or a phone-class viewport (the Studio phone emulator reports a keyboard)
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Gamepad"
	end
	return classify(UserInputService:GetLastInputType()) or (if UserInputService.TouchEnabled then "Touch" else "KeyboardMouse")
end

local hintLabel: TextLabel? = nil
local hintToken = 0

local function applyMode(mode: Mode, showHint: boolean)
	InputMode.current = mode
	local lp = Players.LocalPlayer
	lp:SetAttribute("InputMode", mode)
	local hud = lp.PlayerGui:FindFirstChild("SkyRallyHUD")
	if hud then
		for _, name in { "LeftSteerZone", "RightThrottleZone" } do
			local z = hud:FindFirstChild(name, true)
			if z and z:IsA("GuiObject") then
				z.Visible = mode == "Touch" and z:GetAttribute("PhaseHudOn") ~= false -- HudPhase: TouchControls row
			end
		end
	end
	if mode == "Touch" and hintLabel then
		hintToken += 1 -- a pending fade belongs to the old mode
		hintLabel.Visible = false
	elseif showHint and hintLabel then
		hintToken += 1
		local my = hintToken
		local chip = hintLabel
		local rect = HudMetrics.rects().hintChip
		if not rect then
			chip.Visible = false
			return
		end
		chip.Position = UDim2.fromOffset(rect.x, rect.y)
		chip.Size = UDim2.fromOffset(rect.w, rect.h)
		chip.Text = HINTS[mode]
		chip.BackgroundTransparency = 0.35
		chip.TextTransparency = 0
		chip.Visible = true
		-- L27: the clock starts when the loading screen (display order 1000) leaves, not at join.
		task.spawn(function()
			local waited = 0
			while Players.LocalPlayer:GetAttribute("LoadingDone") ~= true and waited < 35 do
				waited += task.wait(0.25)
			end
			task.wait(HINT_SHOW_S)
			if hintToken ~= my then
				return
			end
			local info = TweenInfo.new(HINT_FADE_S)
			TweenService:Create(chip, info, { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
			task.wait(HINT_FADE_S)
			if hintToken == my then
				chip.Visible = false
			end
		end)
	end
end

function InputMode.init()
	local lp = Players.LocalPlayer
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyControlsHint"
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 40
	sg.ScreenInsets = Enum.ScreenInsets.None -- placed from HudMetrics rects (insets already applied): a DeviceSafe gui would add the notch twice
	local t = Instance.new("TextLabel")
	t.Name = "Hint"
	t.AnchorPoint = Vector2.zero -- bottom-left corner chip (HudMetrics hintChip), never bottom-centre under the kart
	t.BackgroundTransparency = 0.35
	t.BackgroundColor3 = Color3.fromRGB(42, 26, 18)
	t.TextColor3 = Color3.fromRGB(255, 240, 210)
	t.Font = Enum.Font.GothamBold
	t.TextScaled = true
	t.Visible = false
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = t
	local lim = Instance.new("UITextSizeConstraint")
	lim.MaxTextSize = 16
	lim.Parent = t
	t.Parent = sg
	sg.Parent = lp:WaitForChild("PlayerGui")
	hintLabel = t
	HudMetrics.onChanged(function()
		local rect = HudMetrics.rects().hintChip
		if rect then
			t.Position = UDim2.fromOffset(rect.x, rect.y)
			t.Size = UDim2.fromOffset(rect.w, rect.h)
		else
			t.Visible = false -- the layout went touch-class
		end
	end)

	task.spawn(function()
		-- The HUD is built by RaceUI; wait for it so the touch zones can be toggled.
		lp.PlayerGui:WaitForChild("SkyRallyHUD", 15)
		applyMode(initialMode(), true)
	end)
	lastInputName = UserInputService:GetLastInputType().Name
	if classify(UserInputService:GetLastInputType()) == nil then
		lastInputName = if HudLayoutRules.touchLike(UserInputService.TouchEnabled, UserInputService.KeyboardEnabled, viewportY())
			then "Touch"
			else "Keyboard"
	end
	refreshGlyphs()
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(refreshGlyphs)
	end
	UserInputService.LastInputTypeChanged:Connect(function(t2: Enum.UserInputType)
		if classify(t2) ~= nil then
			lastInputName = t2.Name
			refreshGlyphs()
		end
		-- Mouse movement alone never takes a touch device out of Touch (the phone emulator delivers mouse events).
		if HudLayoutRules.ignoreMouse(t2.Name, UserInputService.TouchEnabled, UserInputService.KeyboardEnabled, viewportY()) then
			return
		end
		local forced = lp:GetAttribute("ForceInputMode")
		local m: Mode? = if type(forced) == "string" and HINTS[forced] then (forced :: any) :: Mode else classify(t2)
		if m and m ~= InputMode.current then
			applyMode(m, true)
		end
	end)
	-- QA only: Studio's phone emulator delivers mouse clicks, not touches; ForceInputMode = "Touch" keeps the touch
	-- controls visible so a real mouse drag can exercise them. It changes visibility only, never the input values.
	lp:GetAttributeChangedSignal("ForceInputMode"):Connect(function()
		local forced = lp:GetAttribute("ForceInputMode")
		if type(forced) == "string" and HINTS[forced] then
			applyMode(forced :: Mode, false)
		end
		refreshGlyphs()
	end)
end

return InputMode
