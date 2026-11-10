--!strict
-- HUD safe area (TEST_LIST_LAUNCH L28 phone notch and rounded corners, L82 5 percent TV-safe area; audit H15).
-- The world stays full-bleed (the HUD ScreenGuis keep ScreenInsets.None and IgnoreGuiInset); only the HUD's frames keep
-- inside these insets: RaceUI's layout pass, HudExtras, TrackFlow's hub bar and battle plaques, the Garage's hub button,
-- the controls hint and Onboarding's cards all add them to their margins. The numbers come from
-- GuiService:GetInsetArea(DeviceSafeInsets) (notches, rounded corners, home bar) and, on a ten-foot interface
-- (GuiService:IsTenFootInterface), are raised to 5 percent of each side. The maths is shared/SafeAreaRules (specced).
-- QA, Studio only by habit: LocalPlayer attribute QASafeInsets = "left,top,right,bottom" pretends a notch, and
-- QATenFoot = true pretends a TV; both change layout only.
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SafeAreaRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafeAreaRules"))

local LocalPlayer = Players.LocalPlayer

local SafeArea = {}

export type Insets = SafeAreaRules.Insets

local current: Insets = SafeAreaRules.NONE
local handlers: { (Insets) -> () } = {}
local started = false

local function viewport(): Vector2
	local cam = workspace.CurrentCamera
	return if cam then cam.ViewportSize else Vector2.new(1280, 720)
end

local function deviceInsets(v: Vector2): Insets
	local qa = LocalPlayer:GetAttribute("QASafeInsets")
	if type(qa) == "string" then
		local l, t, r, b = string.match(qa, "^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
		if l then
			return SafeAreaRules.fromOffsets(v.X, v.Y, tonumber(l), tonumber(t), tonumber(r), tonumber(b))
		end
	end
	-- GetInsetArea rects share one origin (the CoreUI-safe frame, below the top bar): the device insets are the distance
	-- between the DeviceSafe rect and the None (whole screen) rect, never DeviceSafe against the camera viewport (that read
	-- the top bar height as a phantom bottom inset: the steer pad floated 58 px above the screen bottom).
	local ok, dev, full = pcall(function()
		return GuiService:GetInsetArea(Enum.ScreenInsets.DeviceSafeInsets), GuiService:GetInsetArea(Enum.ScreenInsets.None)
	end)
	if ok and dev and full then
		local fromRect = SafeAreaRules.fromOffsets(
			v.X,
			v.Y,
			dev.Min.X - full.Min.X,
			dev.Min.Y - full.Min.Y,
			full.Max.X - dev.Max.X,
			full.Max.Y - dev.Max.Y
		)
		if not SafeAreaRules.equal(fromRect, SafeAreaRules.NONE) then
			return fromRect
		end
	end
	-- Clients without GetInsetArea (or a platform that only reports the legacy offsets).
	local okOff, off = pcall(function()
		return GuiService:GetSafeZoneOffsets()
	end)
	if okOff and type(off) == "table" then
		return SafeAreaRules.fromOffsets(v.X, v.Y, off.left or off.Left, off.top or off.Top, off.right or off.Right, off.bottom or off.Bottom)
	end
	return SafeAreaRules.NONE
end

local function tenFoot(): boolean
	if LocalPlayer:GetAttribute("QATenFoot") == true then
		return true
	end
	local ok, ten = pcall(function()
		return GuiService:IsTenFootInterface()
	end)
	return ok and ten == true
end

local function read(): Insets
	local v = viewport()
	return SafeAreaRules.compute(v.X, v.Y, deviceInsets(v), tenFoot())
end

-- Re-reads the device and tells the listeners when the insets changed (rotation, an emulated device, a TV mode switch).
function SafeArea.refresh()
	local nextInsets = read()
	if SafeAreaRules.equal(nextInsets, current) then
		return
	end
	current = nextInsets
	for _, fn in handlers do
		task.spawn(fn, current)
	end
end

function SafeArea.get(): Insets
	if not started then
		SafeArea.init()
	end
	return current
end

-- fn runs whenever the insets change (not for the value at the time of the call: read SafeArea.get() for that).
function SafeArea.onChanged(fn: (Insets) -> ())
	table.insert(handlers, fn)
end

function SafeArea.init()
	if started then
		return
	end
	started = true
	current = read()
	pcall(function()
		GuiService.SafeZoneOffsetsChanged:Connect(SafeArea.refresh)
	end)
	local function watchCamera()
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(SafeArea.refresh)
		end
		SafeArea.refresh()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()
	LocalPlayer:GetAttributeChangedSignal("QASafeInsets"):Connect(SafeArea.refresh)
	LocalPlayer:GetAttributeChangedSignal("QATenFoot"):Connect(SafeArea.refresh)
end

return SafeArea
