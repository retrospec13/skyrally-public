--!strict
-- WRONG WAY arrow for the plane's course leash (trap audit G5.4; FlightController drives it, PlaneConfig holds the
-- numbers). A fat chevron near the top of the screen turns to point the way back to the course, pulses harder the
-- further out the plane is, and a cheerful two-tone "bee-boo" sounds when it appears and every few seconds while it
-- stays. Built from plain Frames (no image asset), created once and reused; hidden costs nothing.
-- HUD layout v2: it is a lane A hero message (centred at 30 percent of the screen height, HUD_LAYOUT.md 7); the player
-- attribute HudArrowUp tells RivalBubbles to keep its bubbles out of that lane while it shows.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local StyleChain = require(script.Parent:WaitForChild("StyleChain"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local LocalPlayer = Players.LocalPlayer

local CourseArrow = {}

local gui: ScreenGui? = nil
local spinner: Frame? = nil
local scale: UIScale? = nil
local text: TextLabel? = nil
local shown = false
local beepClock = -math.huge
local appearClock = -math.huge
local BEEP_EVERY = 2.6

-- The hero is built at 150x110 (text 26 px tall); a UIScale base makes it a readable lane A hero on every screen (about 7 percent
-- of the height on desktop, 1.3x on a phone, where lane A is narrow and the road band starts at 55 percent of the height).
local function baseScale(): number
	local cam = workspace.CurrentCamera
	local vpY = if cam then cam.ViewportSize.Y else 390
	local g = gui
	if g and g.AbsoluteSize.Y > 0 then
		vpY = math.min(vpY, g.AbsoluteSize.Y) -- the screen the arrow is drawn on (an emulated device reports a taller camera)
	end
	-- v21 (hud critic 5): the hero was 24-30 percent of the height at y 0.28 and sat on the road ahead and the kart's wings;
	-- now about 14-16 percent of the height, centred at y 0.2 (above the road band, HUD_LAYOUT 2).
	if vpY <= 450 then
		return 0.65
	end
	return math.clamp(vpY * 0.0015, 1.0, 1.7)
end

local ORANGE = Color3.fromHex("FFB52E") -- UI v2 orange
local INK = Color3.fromHex("0B1533") -- UI v2 ink

local function bar(parent: Instance, rot: number, x: number)
	local b = Instance.new("Frame")
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.fromScale(0.5 + x, 0.42)
	b.Size = UDim2.fromScale(0.62, 0.2)
	b.Rotation = rot
	b.BackgroundColor3 = ORANGE
	b.BorderSizePixel = 0
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = b
	local s = Instance.new("UIStroke")
	s.Color = INK
	s.Thickness = 2.5
	s.Parent = b
	b.Parent = parent
end

local function build()
	if gui and gui.Parent then
		return
	end
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SkyRallyCourseArrow"
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 7
	sg.Enabled = false
	local h = Instance.new("Frame")
	h.Name = "Holder"
	h.AnchorPoint = Vector2.new(0.5, 0) -- v21: pinned by its top edge (the UIScale grows it downward from there)
	h.Position = UDim2.fromScale(0.5, 0.04) -- v21: lane A top; at a 0.28 centre it covered the road ahead and the kart
	h.Size = UDim2.fromOffset(150, 110)
	h.BackgroundTransparency = 1
	local sc = Instance.new("UIScale")
	sc.Parent = h
	-- The chevron (two rounded bars making a "^"), rotated as one.
	local sp = Instance.new("Frame")
	sp.Name = "Chevron"
	sp.AnchorPoint = Vector2.new(0.5, 0.5)
	sp.Position = UDim2.fromScale(0.5, 0.36)
	sp.Size = UDim2.fromOffset(70, 70)
	sp.BackgroundTransparency = 1
	sp.Parent = h
	bar(sp, -45, -0.16)
	bar(sp, 45, 0.16)
	local t = Instance.new("TextLabel")
	t.Name = "WrongWay"
	t.AnchorPoint = Vector2.new(0.5, 1)
	t.Position = UDim2.fromScale(0.5, 1)
	t.Size = UDim2.new(1.8, 0, 0, 34)
	t.BackgroundTransparency = 1
	-- UI v2 hero text: the heavy italic display face, a red-to-orange gradient, a heavy ink outline.
	t.FontFace = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Heavy, Enum.FontStyle.Italic)
	t.TextScaled = true
	t.TextColor3 = Color3.new(1, 1, 1)
	t.Text = "WRONG WAY!"
	local tg = Instance.new("UIGradient")
	tg.Rotation = 90
	tg.Color = ColorSequence.new(Color3.fromHex("FFB0A0"), Color3.fromHex("E0281E"))
	tg.Parent = t
	local ts = Instance.new("UIStroke")
	ts.Color = Color3.fromHex("0B1533")
	ts.Thickness = 3.5
	ts.LineJoinMode = Enum.LineJoinMode.Round
	ts.Parent = t
	t.Parent = h
	h.Parent = sg
	sg.Parent = pg
	gui, spinner, scale, text = sg, sp, sc, t
end

-- Every frame while the plane flies a race. show: the leash is warning; angleDeg: screen rotation of the way back
-- (0 = straight ahead/up, 90 = turn right, 180 = behind); urgency 0..1 (the pull weight).
function CourseArrow.set(show: boolean, angleDeg: number, urgency: number)
	if not show then
		if shown then
			shown = false
			LocalPlayer:SetAttribute("HudArrowUp", false)
			local sg = gui
			if sg then
				sg.Enabled = false
			end
		end
		return
	end
	build()
	local sg, sp, sc = gui, spinner, scale
	if not sg or not sp or not sc then
		return
	end
	local now = os.clock()
	if not shown then
		shown = true
		LocalPlayer:SetAttribute("HudArrowUp", true)
		sg.Enabled = true
		sc.Scale = 1.6 * baseScale()
		TweenService:Create(sc, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = baseScale() }):Play()
		beepClock = -math.huge
		appearClock = now
		if text then
			text.Text = "WRONG WAY!"
		end
	end
	if now - beepClock >= BEEP_EVERY then
		beepClock = now
		-- The sfx_v2 cue; the old beep only while it has no id.
		if not Sfx.play("wrong_way", 1 + 0.08 * urgency, 0.56) and not Sfx.has("wrong_way") then
			StyleChain.sfx("leash_warn", 1 + 0.08 * urgency)
		end
	end
	sp.Rotation = angleDeg
	-- Pulse faster and bigger as the pull grows (the tween above settles within 0.25 s, then this takes over).
	if now - appearClock > 0.25 then
		sc.Scale = baseScale() * (1 + (0.06 + 0.1 * urgency) * math.sin(now * (6 + 6 * urgency)))
	end
end

-- The leash put the plane back: a last word on the way out.
function CourseArrow.rescued()
	local t = text
	if t then
		t.Text = "BACK YOU GO!"
	end
end

return CourseArrow
