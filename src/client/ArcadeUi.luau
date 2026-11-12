--!strict
-- UI v2 arcade-racer look (docs/design/UI_V2.md section 1) for the surfaces this lane owns: the Garage, the race HUD and the
-- hub buttons. One place for the tokens (colours, fonts), the chunky glossy pieces (card, key button with a 3D lip, gold
-- header band, checker strip, hero numerals) and a small procedural icon set (no image to load: every icon is a few
-- rounded Frames with one shared ink outline, so it reads at 16 px on a phone and at 64 px on a monitor).
-- The central theme lives in client/UiSkin + shared/UiSkinRules (owned by the course-select lane); where it gains the same
-- factories this module forwards to them. Nothing here decides anything: it only builds and styles instances.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
-- The uploaded glossy icon set (play-v37, tools/vfx/upload_set.py); a kind with art draws it, the rest stay procedural.
local UiV2Icons = require(Shared:WaitForChild("UiV2Icons")) :: { [string]: string }
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local UiSkin = require(script.Parent:WaitForChild("UiSkin")) -- live type scale (UiSkin.liveCap)

local Rules = require(Shared:WaitForChild("UiSkinRules"))
-- UI direction v3 frames (same table client/UiSkin reads): present once uploaded, flat native look until then.
local V3: { [string]: string? } = {}
do
	local mod = Shared:FindFirstChild("UiV3Frames") or Shared:WaitForChild("UiV3Frames", 5)
	if mod and mod:IsA("ModuleScript") then
		local ok, t = pcall(require, mod)
		if ok and type(t) == "table" then
			V3 = t :: any
		end
	end
end

-- Puts the shared v3 9-slice (UiSkinRules.v3Frame) on `host` and clears the flat fills listed in `clear`; returns false
-- when the art is not uploaded yet (the caller keeps its flat look).
local function v3Frame(host: GuiObject, role: string, variant: string, clear: { GuiObject }): boolean
	local key = Rules.v3Frame(role, variant)
	local id = if key and host.AutomaticSize == Enum.AutomaticSize.None then V3[key] else nil
	local im = host:FindFirstChild("SkinFrame")
	if not id or not key then
		if im then
			im:Destroy()
		end
		return false
	end
	if not (im and im:IsA("ImageLabel")) then
		local n = Instance.new("ImageLabel")
		n.Name = "SkinFrame"
		n.BackgroundTransparency = 1
		n.Size = UDim2.fromScale(1, 1)
		n.Active = false
		n.ScaleType = Enum.ScaleType.Slice
		n.ZIndex = -1 -- under every sibling (labels, glyphs, the Face) whatever their ZIndex
		n.Parent = host
		im = n
	end
	local img = im :: ImageLabel
	local sl = Rules.V3_SLICE[Rules.v3Kind(key)]
	img.Image = id
	img.SliceCenter = Rect.new(sl.center[1], sl.center[2], sl.center[3], sl.center[4])
	local function fit()
		local bord = sl.center[2] + (sl.size[2] - sl.center[4])
		local h = host.AbsoluteSize.Y
		img.SliceScale = math.clamp(if h > 0 then math.min(1, h / bord) else 1, 0.2, 1)
	end
	fit()
	if host:GetAttribute("V3Fit") ~= true then
		host:SetAttribute("V3Fit", true)
		host:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	end
	-- a card mirrors its own fill transparency; a key (its host is a clear TextButton) mirrors its Face
	local src: GuiObject = if host:IsA("GuiButton") and #clear > 0 then clear[#clear] else host
	img.ImageTransparency = if src == host and host:IsA("GuiButton") then 0 else src.BackgroundTransparency
	for _, c in clear do
		-- hide the flat fill through its gradient: a caller fading BackgroundTransparency still fades the frame
		local gr = c:FindFirstChildOfClass("UIGradient")
		if gr then
			gr.Transparency = NumberSequence.new(1)
		elseif c ~= host then
			c.BackgroundTransparency = 1
		end
		local st = c:FindFirstChildOfClass("UIStroke")
		if st then
			st.Enabled = false
		end
	end
	return true
end

local ArcadeUi = {}

-- v38-flow: ONE source of truth. Every colour, face and shape number below is read from shared/UiSkinRules (the same
-- table client/UiSkin paints from), so a Garage key, a HUD chip and a course-select button are the same object. This
-- module only keeps its own factory layout (Lip + Face children, which Garage / HudExtras read).
local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end
local function hex(s: string): Color3
	return Color3.fromHex(s)
end
local V = Rules.VARIANT
local Sh = Rules.SHAPE
ArcadeUi.SHAPE = Sh

-- Theme tokens (UI_V2 section 1).
ArcadeUi.C = {
	ink = rgb(Rules.INK),
	panelTop = rgb(V.panel.top),
	panelBot = rgb(V.panel.bottom),
	inset = rgb(V.inset.top),
	headerTop = rgb(V.header.top),
	headerBot = rgb(V.header.bottom),
	gold = rgb(Rules.GOLD),
	steel = rgb(Rules.STEEL),
	white = Color3.new(1, 1, 1),
	dim = hex("AFC0E8"), -- secondary text on the navy panel
	cream = hex("FFF4D6"),
}
ArcadeUi.INSET_ALPHA = Rules.INSET_ALPHA

-- Button / chip variants: top and bottom of the face gradient; the lip is the bottom darkened. The theme variants come
-- from UiSkinRules; navy (the tab / neutral key) and robux are this kit's extras.
local function pair(v: any): { Color3 }
	return { rgb(v.top), rgb(v.bottom) }
end
ArcadeUi.VARIANT = {
	go = pair(V.go),
	sky = pair(V.sky),
	orange = pair(V.orange),
	danger = pair(V.danger),
	disabled = pair(V.disabled),
	header = pair(V.header),
	purple = pair(V.purple),
	navy = pair(V.card),
	robux = { hex("35D0B0"), hex("128A74") },
} :: { [string]: { Color3 } }

ArcadeUi.RARITY = {
	common = rgb(Rules.RARITY.common),
	rare = rgb(Rules.RARITY.rare),
	epic = rgb(Rules.RARITY.epic),
	legendary = rgb(Rules.RARITY.legendary),
	exclusive = rgb(Rules.RARITY.legendary),
} :: { [string]: Color3 }

-- Position numerals: 1st gold, 2nd silver, 3rd bronze, the rest white.
ArcadeUi.PLACE = { rgb(Rules.PLACE[1]), rgb(Rules.PLACE[2]), rgb(Rules.PLACE[3]) } :: { Color3 }
function ArcadeUi.placeColor(n: number?): Color3
	return (n and ArcadeUi.PLACE[n]) or ArcadeUi.C.white
end

-- The faces are UiSkinRules.FONT (display: heavy italic for titles, numerals and keys; body: rounded bold).
local function face(d: any): Font
	return Font.new(d.family, (Enum.FontWeight :: any)[d.weight], (Enum.FontStyle :: any)[d.style])
end
local DISPLAY = face(Rules.FONT.display)
local DISPLAY_UPRIGHT = Font.new(Rules.FONT.display.family, Enum.FontWeight.Heavy, Enum.FontStyle.Normal)
local BODY = face(Rules.FONT.body)
local BODY_HEAVY = face(Rules.FONT.bodyHeavy)
ArcadeUi.FONT = { display = DISPLAY, upright = DISPLAY_UPRIGHT, body = BODY, bodyHeavy = BODY_HEAVY }

local function darken(c: Color3, k: number): Color3
	return Color3.new(c.R * k, c.G * k, c.B * k)
end
ArcadeUi.darken = darken

---------------------------------------------------------------------------------------------------- primitives

function ArcadeUi.corner(g: Instance, r: number | UDim)
	local c = g:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	-- v3: angular frames; a numeric radius is capped at the theme's corner (pills and circles, 100+ or a UDim, stay round)
	local px = r :: number
	c.CornerRadius = if typeof(r) == "UDim" then r elseif px >= 100 then UDim.new(0, px) else UDim.new(0, math.min(px, Sh.panelCorner))
	c.Parent = g
end

function ArcadeUi.stroke(g: Instance, thickness: number, color: Color3?, border: boolean?): UIStroke
	local s = Instance.new("UIStroke")
	-- v3: frame edges are pale steel, text outlines stay ink (UiSkinRules.STEEL / INK)
	local isText = g:IsA("TextLabel") or g:IsA("TextButton")
	s.Color = color or (if isText and border ~= true then ArcadeUi.C.ink else ArcadeUi.C.steel)
	s.Thickness = thickness
	s.LineJoinMode = Enum.LineJoinMode.Round
	if border ~= false and not g:IsA("TextLabel") and not g:IsA("TextButton") then
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	elseif border == true then
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	end
	s.Parent = g
	return s
end

-- A vertical gradient (top -> bottom) on a white-filled object.
function ArcadeUi.gradient(g: GuiObject, top: Color3, bottom: Color3, rotation: number?): UIGradient
	local gr = g:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	gr.Color = ColorSequence.new(top, bottom)
	gr.Rotation = rotation or 90
	gr.Parent = g
	g.BackgroundColor3 = Color3.new(1, 1, 1)
	return gr
end

-- The lighter top highlight strip (white 22 percent over the top 40 percent, fading out).
function ArcadeUi.shine(g: GuiObject, radius: number?, inset: number?)
	if Sh.gloss <= 0 then
		return -- v3: flat faces, no gloss strip
	end
	local i = inset or 3
	local s = Instance.new("Frame")
	s.Name = "Shine"
	s.Active = false
	s.BorderSizePixel = 0
	s.BackgroundColor3 = Color3.new(1, 1, 1)
	s.BackgroundTransparency = 0
	s.Position = UDim2.fromOffset(i, i)
	s.Size = UDim2.new(1, -2 * i, 0.42, -i)
	s.Parent = g
	ArcadeUi.corner(s, math.max(0, (radius or 12) - i))
	local t = Instance.new("UIGradient")
	t.Rotation = 90
	t.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 1) })
	t.Parent = s
end

export type TextOpts = {
	name: string?,
	text: string?,
	font: Font?,
	size: number?, -- fixed TextSize (else TextScaled with maxSize)
	maxSize: number?,
	minSize: number?,
	color: Color3?,
	stroke: number?, -- ink outline px (0 = none)
	strokeColor: Color3?,
	align: Enum.TextXAlignment?,
	valign: Enum.TextYAlignment?,
	position: UDim2?,
	sizeUDim: UDim2?,
	anchor: Vector2?,
	z: number?,
	wrap: boolean?,
}

-- White text with an ink outline (UI_V2: everything on colour).
function ArcadeUi.text(parent: Instance?, o: TextOpts): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = o.name or "Text"
	l.BackgroundTransparency = 1
	l.Active = false
	l.FontFace = o.font or BODY_HEAVY
	l.Text = o.text or ""
	l.TextColor3 = o.color or ArcadeUi.C.white
	l.TextXAlignment = o.align or Enum.TextXAlignment.Left
	l.TextYAlignment = o.valign or Enum.TextYAlignment.Center
	l.TextWrapped = o.wrap == true
	if o.size then
		l.TextSize = o.size
	else
		l.TextScaled = true
		local c = Instance.new("UITextSizeConstraint")
		UiSkin.liveCap(c, o.maxSize or 22) -- follows the viewport live (round 3)
		c.MinTextSize = o.minSize or 10
		c.Parent = l
	end
	local sw = if o.stroke == nil then Sh.textStroke else math.min(o.stroke, Sh.textStroke + 0.6)
	if sw > 0 then
		local s = Instance.new("UIStroke")
		s.Color = o.strokeColor or ArcadeUi.C.ink
		s.Transparency = 0.25
		s.Thickness = sw
		s.LineJoinMode = Enum.LineJoinMode.Round
		s.Parent = l
	end
	if o.position then
		l.Position = o.position
	end
	if o.sizeUDim then
		l.Size = o.sizeUDim
	end
	if o.anchor then
		l.AnchorPoint = o.anchor
	end
	if o.z then
		l.ZIndex = o.z
	end
	l.Parent = parent
	return l
end

export type CardOpts = {
	name: string?,
	position: UDim2?,
	size: UDim2?,
	anchor: Vector2?,
	radius: number?,
	inset: boolean?, -- a well inside a panel (flat navy at 55 percent, no outline)
	top: Color3?,
	bottom: Color3?,
	strokeWidth: number?,
	strokeColor: Color3?,
	shine: boolean?,
	alpha: number?,
	layoutOrder: number?,
	z: number?,
	clip: boolean?,
}

-- The navy panel card (gradient, ink outline, top highlight) or an inset well.
function ArcadeUi.card(parent: Instance?, o: CardOpts): Frame
	local f = Instance.new("Frame")
	f.Name = o.name or "Card"
	f.BorderSizePixel = 0
	if o.position then
		f.Position = o.position
	end
	if o.size then
		f.Size = o.size
	end
	if o.anchor then
		f.AnchorPoint = o.anchor
	end
	if o.layoutOrder then
		f.LayoutOrder = o.layoutOrder
	end
	if o.z then
		f.ZIndex = o.z
	end
	f.ClipsDescendants = o.clip == true
	local r = math.min(o.radius or Sh.panelCorner, Sh.panelCorner)
	ArcadeUi.corner(f, r)
	if o.inset then
		f.BackgroundColor3 = ArcadeUi.C.inset
		f.BackgroundTransparency = o.alpha or ArcadeUi.INSET_ALPHA
	else
		ArcadeUi.gradient(f, o.top or ArcadeUi.C.panelTop, o.bottom or ArcadeUi.C.panelBot)
		f.BackgroundTransparency = o.alpha or 0
		local sw = o.strokeWidth or 3
		if sw > 0 then
			ArcadeUi.stroke(f, sw, o.strokeColor)
		end
		if o.shine ~= false then
			ArcadeUi.shine(f, r)
		end
		if not o.top then
			v3Frame(f, "card", "card", { f })
		end
	end
	f.Parent = parent
	return f
end

---------------------------------------------------------------------------------------------------- key buttons

export type ButtonOpts = {
	name: string?,
	position: UDim2?,
	size: UDim2?,
	anchor: Vector2?,
	radius: number?,
	lip: number?, -- px of the darker bottom lip (4 at S = 1)
	sound: string?, -- UiSound kind ("none" keeps the feel without a press sound)
	maxText: number?,
	minText: number?,
	font: Font?,
	textColor: Color3?,
	icon: string?, -- ArcadeUi.icon kind drawn left of the label
	iconOnly: boolean?,
	layoutOrder: number?,
	selectable: boolean?,
	z: number?,
	visible: boolean?,
}

local function faceOf(b: GuiObject): Frame?
	return b:FindFirstChild("Face") :: Frame?
end

-- The label inside a key button.
function ArcadeUi.labelOf(b: GuiObject): TextLabel?
	local face = faceOf(b)
	local l = face and face:FindFirstChild("Label")
	return if l and l:IsA("TextLabel") then l else nil
end

function ArcadeUi.setText(b: GuiObject, text: string)
	local l = ArcadeUi.labelOf(b)
	if l and l.Text ~= text then
		l.Text = text
	end
end

-- Recolour a key button (go / sky / orange / danger / disabled / header / navy / robux).
function ArcadeUi.setVariant(b: GuiObject, variant: string)
	if b:GetAttribute("Variant") == variant then
		return
	end
	local v = ArcadeUi.VARIANT[variant] or ArcadeUi.VARIANT.navy
	b:SetAttribute("Variant", variant)
	local lip = b:FindFirstChild("Lip") :: Frame?
	if lip then
		lip.BackgroundColor3 = darken(v[2], 0.62)
	end
	local face = faceOf(b)
	if face then
		ArcadeUi.gradient(face, v[1], v[2])
	end
	-- v3: the shared skewed bar art (navy = the dark tab look) over clear fills
	local clear: { GuiObject } = {}
	if lip then
		table.insert(clear, lip)
	end
	if face then
		table.insert(clear, face)
	end
	v3Frame(b, if variant == "navy" then "tab" else "button", if variant == "navy" then "tab" else variant, clear)
	local l = ArcadeUi.labelOf(b)
	if l then
		-- Gold header keys carry ink text (UI_V2: header band, selected tab); every other key white on colour.
		local onGold = variant == "header"
		l.TextColor3 = if onGold then ArcadeUi.C.ink else ArcadeUi.C.white
		local s = l:FindFirstChildOfClass("UIStroke")
		if s then
			s.Transparency = if onGold then 1 else 0
		end
		l.TextTransparency = if variant == "disabled" then 0.4 else 0
	end
end

local function pressLook(b: GuiButton)
	local face = faceOf(b)
	local lipPx = b:GetAttribute("LipPx")
	if not face or type(lipPx) ~= "number" then
		return
	end
	local down = b.GuiState == Enum.GuiState.Press
	face.Position = UDim2.fromOffset(0, if down then math.max(0, lipPx - 1) else 0)
end

-- A chunky key: ink outline, a gradient face, a lighter top strip and a darker lip under it that collapses on press.
-- The feel (hover 1.05-ish, press squash, release bounce) and the cue come from UiSound.bind.
function ArcadeUi.button(parent: Instance?, variant: string, text: string, o: ButtonOpts?): TextButton
	local opts: ButtonOpts = o or {}
	local r = math.min(opts.radius or Sh.corner, Sh.corner)
	local lipPx = opts.lip or Sh.lip
	local b = Instance.new("TextButton")
	b.Name = opts.name or "Button"
	b.Text = ""
	b.AutoButtonColor = false
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.Selectable = opts.selectable ~= false
	if opts.position then
		b.Position = opts.position
	end
	if opts.size then
		b.Size = opts.size
	end
	if opts.anchor then
		b.AnchorPoint = opts.anchor
	end
	if opts.layoutOrder then
		b.LayoutOrder = opts.layoutOrder
	end
	if opts.z then
		b.ZIndex = opts.z
	end
	if opts.visible == false then
		b.Visible = false
	end
	b:SetAttribute("LipPx", lipPx)
	local lip = Instance.new("Frame")
	lip.Name = "Lip"
	lip.Active = false
	lip.BorderSizePixel = 0
	lip.Size = UDim2.fromScale(1, 1)
	lip.Parent = b
	ArcadeUi.corner(lip, r)
	ArcadeUi.stroke(lip, Sh.outline)
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Active = false
	face.BorderSizePixel = 0
	face.Size = UDim2.new(1, 0, 1, -lipPx)
	face.Parent = b
	ArcadeUi.corner(face, r)
	ArcadeUi.shine(face, r)
	local iconW = 0
	if opts.icon then
		local ic = ArcadeUi.icon(face, opts.icon, { name = "Glyph" })
		if opts.iconOnly then
			ic.AnchorPoint = Vector2.new(0.5, 0.5)
			ic.Position = UDim2.fromScale(0.5, 0.5)
			ic.Size = UDim2.fromScale(0.66, 0.66)
		else
			ic.AnchorPoint = Vector2.new(0, 0.5)
			ic.Position = UDim2.new(0, 8, 0.5, 0)
			ic.Size = UDim2.new(0.62, 0, 0.62, 0)
			local ar = Instance.new("UIAspectRatioConstraint")
			ar.AspectRatio = 1
			ar.Parent = ic
			iconW = 1
		end
	end
	local l = ArcadeUi.text(face, {
		name = "Label",
		text = text,
		font = opts.font or DISPLAY,
		maxSize = opts.maxText or 22,
		minSize = opts.minText or 10,
		align = Enum.TextXAlignment.Center,
		stroke = Sh.textStroke,
		color = opts.textColor,
	})
	l.Size = UDim2.new(1, -12, 0.7, 0)
	l.Position = UDim2.fromScale(0.5, 0.5)
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	if iconW > 0 then
		-- Icon on the left: the label takes the rest (the icon is about the face height wide).
		l.Size = UDim2.new(1, -12, 0.7, 0)
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0.0, 0)
		pad.Parent = l
		b:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			local h = face.AbsoluteSize.Y
			pad.PaddingLeft = UDim.new(0, math.floor(h * 0.62 + 6))
		end)
	end
	if opts.iconOnly then
		l.Visible = false
	end
	b:SetAttribute("Variant", nil)
	ArcadeUi.setVariant(b, variant)
	b:GetPropertyChangedSignal("GuiState"):Connect(function()
		pressLook(b)
	end)
	-- Hover / gamepad focus lifts the face toward white (UiSkinRules.SHAPE.hoverLift), as UiSkin's native keys do.
	local function hover(on: boolean)
		b:SetAttribute("KeyHover", on)
		local v = ArcadeUi.VARIANT[(b:GetAttribute("Variant") :: string?) or "navy"] or ArcadeUi.VARIANT.navy
		if on and b:GetAttribute("KeyOn") ~= false then
			ArcadeUi.gradient(face, v[1]:Lerp(ArcadeUi.C.white, Sh.hoverLift), v[2]:Lerp(ArcadeUi.C.white, Sh.hoverLift * 0.6))
		else
			ArcadeUi.gradient(face, v[1], v[2])
		end
		-- round 3: the 9-slice key brightens its edge and face (the gradient above is hidden under the frame art)
		UiSkin.hoverGlow(b, on and b:GetAttribute("KeyOn") ~= false and b:GetAttribute("Variant") ~= "disabled")
	end
	b.SelectionImageObject = UiSkin.focusRing()
	task.defer(hover, false) -- idle keys sit a touch dimmer than a hovered one
	b.MouseEnter:Connect(function()
		hover(true)
	end)
	b.MouseLeave:Connect(function()
		hover(false)
	end)
	b.SelectionGained:Connect(function()
		hover(true)
	end)
	b.SelectionLost:Connect(function()
		hover(false)
	end)
	UiSound.bind(b, opts.sound or "tap")
	b.Parent = parent
	return b
end

-- Fades a whole key (0 = solid, 1 = gone): faces, outline, label and glyph art together.
function ArcadeUi.setAlpha(b: GuiObject, a: number)
	for _, d in b:GetDescendants() do
		if d:IsA("Frame") and (d.Name == "Lip" or d.Name == "Face") then
			d.BackgroundTransparency = a
		elseif d:IsA("Frame") and d.Name == "Shine" then
			d.BackgroundTransparency = a
		elseif d:IsA("TextLabel") then
			d.TextTransparency = a
		elseif d:IsA("ImageLabel") then
			d.ImageTransparency = a
		elseif d:IsA("UIStroke") then
			d.Transparency = a
		end
	end
end

-- Dims a key (status buttons: OWNED, LOCKED). It still takes a press so the deny knock plays.
function ArcadeUi.setEnabled(b: GuiButton, on: boolean, offVariant: string?)
	b:SetAttribute("KeyOn", on)
	if not on then
		ArcadeUi.setVariant(b, offVariant or "disabled")
	end
	b.Selectable = on
	UiSound.setKind(b, if on then "tap" else "deny")
end

---------------------------------------------------------------------------------------------------- header band, checker, pills

export type BoxOpts = { name: string?, position: UDim2?, size: UDim2?, anchor: Vector2?, maxText: number?, z: number? }

-- The gold title band with ink text (slanted face, chevrons trailing it).
function ArcadeUi.band(parent: Instance?, text: string, o: BoxOpts?): (Frame, TextLabel)
	local opts: BoxOpts = o or {}
	local f = Instance.new("Frame")
	f.Name = opts.name or "Band"
	f.BorderSizePixel = 0
	if opts.position then
		f.Position = opts.position
	end
	if opts.size then
		f.Size = opts.size
	end
	if opts.z then
		f.ZIndex = opts.z
	end
	ArcadeUi.corner(f, 10)
	ArcadeUi.gradient(f, ArcadeUi.C.headerTop, ArcadeUi.C.headerBot)
	ArcadeUi.stroke(f, 3)
	ArcadeUi.shine(f, 10)
	local l = ArcadeUi.text(f, {
		name = "Title",
		text = text,
		font = DISPLAY,
		maxSize = opts.maxText or 34,
		color = ArcadeUi.C.ink,
		stroke = 0,
	})
	l.Position = UDim2.fromOffset(14, 0)
	l.Size = UDim2.new(1, -28, 1, 0)
	f.Parent = parent
	return f, l
end

-- A checker strip (start / finish things only): cols x rows squares of white and ink.
function ArcadeUi.checker(parent: Instance?, cols: number, rows: number, o: BoxOpts?): Frame
	local opts: BoxOpts = o or {}
	local f = Instance.new("Frame")
	f.Name = opts.name or "Checker"
	f.BackgroundColor3 = ArcadeUi.C.ink
	f.BorderSizePixel = 0
	f.ClipsDescendants = true
	if opts.position then
		f.Position = opts.position
	end
	if opts.size then
		f.Size = opts.size
	end
	if opts.anchor then
		f.AnchorPoint = opts.anchor
	end
	for cx = 0, cols - 1 do
		for cy = 0, rows - 1 do
			if (cx + cy) % 2 == 0 then
				local sq = Instance.new("Frame")
				sq.BorderSizePixel = 0
				sq.BackgroundColor3 = Color3.new(1, 1, 1)
				sq.Position = UDim2.fromScale(cx / cols, cy / rows)
				sq.Size = UDim2.fromScale(1 / cols, 1 / rows)
				sq.Parent = f
			end
		end
	end
	f.Parent = parent
	return f
end

-- A small rounded status pill (OWNED, x2 CASH).
function ArcadeUi.pill(parent: Instance?, variant: string, text: string, o: BoxOpts?): Frame
	local opts: BoxOpts = o or {}
	local v = ArcadeUi.VARIANT[variant] or ArcadeUi.VARIANT.navy
	local f = Instance.new("Frame")
	f.Name = opts.name or "Pill"
	f.BorderSizePixel = 0
	if opts.position then
		f.Position = opts.position
	end
	if opts.size then
		f.Size = opts.size
	end
	if opts.anchor then
		f.AnchorPoint = opts.anchor
	end
	if opts.z then
		f.ZIndex = opts.z
	end
	ArcadeUi.corner(f, UDim.new(0.5, 0))
	ArcadeUi.gradient(f, v[1], v[2])
	ArcadeUi.stroke(f, 2)
	local l = ArcadeUi.text(f, { name = "Label", text = text, font = DISPLAY, maxSize = opts.maxText or 14, minSize = 8, align = Enum.TextXAlignment.Center, stroke = 1.5 })
	l.Size = UDim2.new(1, -10, 1, -4)
	l.Position = UDim2.fromOffset(5, 2)
	f.Parent = parent
	return f
end

---------------------------------------------------------------------------------------------------- motion helpers

local function uiScale(g: GuiObject): UIScale
	local s = g:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	local n = Instance.new("UIScale")
	n.Parent = g
	return n
end
ArcadeUi.uiScale = uiScale

-- A punch: scale to peak, settle back with an overshoot.
function ArcadeUi.punch(g: GuiObject, peak: number, seconds: number?)
	local s = uiScale(g)
	s.Scale = peak
	TweenService:Create(s, TweenInfo.new(seconds or 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- Children pop in one after another (UI_V2: stagger 30-50 ms).
function ArcadeUi.stagger(children: { GuiObject }, step: number?, from: number?)
	for i, c in children do
		local s = uiScale(c)
		s.Scale = from or 0.6
		task.delay((i - 1) * (step or 0.035), function()
			if c.Parent then
				TweenService:Create(s, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end)
	end
end

---------------------------------------------------------------------------------------------------- icons

export type IconOpts = { name: string?, size: UDim2?, position: UDim2?, anchor: Vector2?, z: number?, color: Color3? }

type Shape = {
	k: string, -- "box" (rounded rect), "ring" (stroked circle), "bar" (a segment p1 -> p2), "img"
	x: number,
	y: number,
	w: number,
	h: number,
	c: Color3,
	r: number?, -- corner as a fraction of the shorter side (0.5 = round)
	rot: number?,
	t: number?, -- ring thickness as a fraction of the icon side
	a: number?, -- transparency
	img: string?,
	noInk: boolean?,
}

local C = ArcadeUi.C
local GOLD_COIN = hex("FFC53D")
local GOLD_DEEP = hex("E8961C")
local SILVER = hex("D9E2F2")

local function box(x: number, y: number, w: number, h: number, c: Color3, r: number?, rot: number?): Shape
	return { k = "box", x = x, y = y, w = w, h = h, c = c, r = r, rot = rot }
end
local function ring(x: number, y: number, d: number, t: number, c: Color3): Shape
	return { k = "ring", x = x, y = y, w = d, h = d, c = c, t = t }
end
local function bar(x1: number, y1: number, x2: number, y2: number, thick: number, c: Color3): Shape
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	return { k = "bar", x = (x1 + x2) / 2, y = (y1 + y2) / 2, w = len + thick, h = thick, c = c, r = 0.5, rot = math.deg(math.atan2(dy, dx)) }
end

local function tex(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

-- Shape lists in unit coordinates (0..1 of the icon square), centres.
local ICONS: { [string]: (Color3?) -> { Shape } } = {
	coin = function()
		return {
			box(0.5, 0.5, 0.9, 0.9, GOLD_DEEP, 0.5),
			box(0.5, 0.46, 0.84, 0.82, GOLD_COIN, 0.5),
			box(0.5, 0.47, 0.5, 0.5, GOLD_DEEP, 0.5),
			box(0.5, 0.47, 0.4, 0.4, hex("FFE27A"), 0.5),
			box(0.36, 0.3, 0.16, 0.12, Color3.new(1, 1, 1), 0.5),
		}
	end,
	token = function()
		return {
			box(0.5, 0.5, 0.9, 0.9, hex("2F7BE0"), 0.5),
			box(0.5, 0.47, 0.82, 0.8, hex("5CCBFF"), 0.5),
			{ k = "img", x = 0.5, y = 0.48, w = 0.8, h = 0.8, c = Color3.new(1, 1, 1), img = tex("star_twinkle"), noInk = true },
		}
	end,
	flag = function()
		local s: { Shape } = { box(0.17, 0.52, 0.09, 0.9, C.white, 0.5) }
		local x0, y0, cw, ch = 0.25, 0.1, 0.62 / 4, 0.48 / 3
		table.insert(s, box(x0 + 0.31, y0 + 0.24, 0.62, 0.48, C.ink, 0.08))
		for cx = 0, 3 do
			for cy = 0, 2 do
				if (cx + cy) % 2 == 0 then
					local sq = box(x0 + cw * (cx + 0.5), y0 + ch * (cy + 0.5), cw, ch, C.white, 0)
					sq.noInk = true
					table.insert(s, sq)
				end
			end
		end
		return s
	end,
	lock = function()
		return {
			ring(0.5, 0.36, 0.46, 0.1, SILVER),
			box(0.5, 0.66, 0.72, 0.52, GOLD_COIN, 0.22),
			box(0.5, 0.61, 0.16, 0.16, C.ink, 0.5),
			box(0.5, 0.72, 0.08, 0.18, C.ink, 0.3),
		}
	end,
	check = function()
		return {
			box(0.5, 0.5, 0.92, 0.92, hex("1FA83A"), 0.5),
			box(0.5, 0.47, 0.84, 0.84, hex("4BE06A"), 0.5),
			bar(0.29, 0.5, 0.44, 0.66, 0.13, C.white),
			bar(0.44, 0.66, 0.73, 0.33, 0.13, C.white),
		}
	end,
	star = function(col: Color3?)
		return { { k = "img", x = 0.5, y = 0.5, w = 1.1, h = 1.1, c = col or C.gold, img = tex("star_twinkle"), noInk = true } }
	end,
	trophy = function()
		return {
			ring(0.22, 0.34, 0.26, 0.07, GOLD_COIN),
			ring(0.78, 0.34, 0.26, 0.07, GOLD_COIN),
			box(0.5, 0.36, 0.56, 0.48, GOLD_COIN, 0.4),
			box(0.5, 0.2, 0.56, 0.16, GOLD_COIN, 0.1),
			box(0.5, 0.68, 0.14, 0.18, GOLD_DEEP, 0.2),
			box(0.5, 0.84, 0.52, 0.13, GOLD_DEEP, 0.35),
			box(0.4, 0.32, 0.1, 0.22, hex("FFE27A"), 0.5),
		}
	end,
	calendar = function()
		return {
			box(0.5, 0.56, 0.84, 0.72, C.white, 0.18),
			box(0.5, 0.3, 0.84, 0.22, hex("FF6464"), 0.18),
			box(0.32, 0.17, 0.08, 0.18, C.ink, 0.4),
			box(0.68, 0.17, 0.08, 0.18, C.ink, 0.4),
			box(0.34, 0.58, 0.14, 0.12, hex("1E8CE8"), 0.2),
			box(0.54, 0.58, 0.14, 0.12, hex("1E8CE8"), 0.2),
			box(0.34, 0.76, 0.14, 0.12, hex("1E8CE8"), 0.2),
			box(0.54, 0.76, 0.14, 0.12, hex("4BE06A"), 0.2),
		}
	end,
	shop = function()
		return {
			ring(0.5, 0.34, 0.4, 0.08, SILVER),
			box(0.5, 0.64, 0.78, 0.58, hex("FFB52E"), 0.18),
			box(0.5, 0.5, 0.78, 0.1, hex("F57C00"), 0.1),
			box(0.5, 0.7, 0.2, 0.2, C.white, 0.5),
		}
	end,
	paint = function()
		return {
			box(0.5, 0.54, 0.92, 0.74, hex("F2D9B0"), 0.5),
			box(0.3, 0.42, 0.18, 0.18, hex("FF6464"), 0.5),
			box(0.52, 0.34, 0.18, 0.18, hex("FFD83D"), 0.5),
			box(0.73, 0.44, 0.18, 0.18, hex("4FC3FF"), 0.5),
			box(0.62, 0.68, 0.18, 0.18, hex("4BE06A"), 0.5),
			box(0.32, 0.68, 0.14, 0.14, hex("B9946A"), 0.5),
		}
	end,
	trail = function()
		return {
			box(0.6, 0.28, 0.66, 0.13, hex("5CCBFF"), 0.5),
			box(0.52, 0.5, 0.82, 0.13, C.white, 0.5),
			box(0.62, 0.72, 0.62, 0.13, hex("B76BFF"), 0.5),
			box(0.84, 0.5, 0.2, 0.2, C.gold, 0.5),
		}
	end,
	horn = function()
		return {
			box(0.16, 0.5, 0.24, 0.3, hex("FF6464"), 0.5),
			box(0.4, 0.5, 0.4, 0.16, GOLD_COIN, 0.3),
			box(0.72, 0.5, 0.34, 0.7, GOLD_COIN, 0.5),
			box(0.76, 0.5, 0.16, 0.42, GOLD_DEEP, 0.5),
		}
	end,
	emote = function()
		return {
			{ k = "img", x = 0.38, y = 0.6, w = 0.9, h = 0.9, c = hex("FFD83D"), img = tex("star_twinkle"), noInk = true },
			{ k = "img", x = 0.72, y = 0.3, w = 0.6, h = 0.6, c = hex("5CCBFF"), img = tex("star_twinkle"), noInk = true },
		}
	end,
	car = function(col: Color3?)
		return {
			box(0.5, 0.56, 0.9, 0.3, col or hex("FF6464"), 0.45),
			box(0.46, 0.38, 0.44, 0.24, hex("5CCBFF"), 0.4),
			box(0.26, 0.72, 0.24, 0.24, C.ink, 0.5),
			box(0.74, 0.72, 0.24, 0.24, C.ink, 0.5),
			box(0.26, 0.72, 0.1, 0.1, SILVER, 0.5),
			box(0.74, 0.72, 0.1, 0.1, SILVER, 0.5),
		}
	end,
	plane = function(col: Color3?)
		return {
			box(0.5, 0.5, 0.2, 0.92, col or hex("FF6464"), 0.5),
			box(0.5, 0.42, 0.9, 0.2, hex("5CCBFF"), 0.45),
			box(0.5, 0.86, 0.42, 0.12, hex("5CCBFF"), 0.45),
			box(0.5, 0.1, 0.14, 0.08, SILVER, 0.5),
		}
	end,
	question = function()
		return { box(0.5, 0.5, 0.9, 0.9, hex("1E8CE8"), 0.5), box(0.5, 0.46, 0.82, 0.82, hex("5CCBFF"), 0.5) }
	end,
	close = function()
		return { bar(0.26, 0.26, 0.74, 0.74, 0.16, C.white), bar(0.74, 0.26, 0.26, 0.74, 0.16, C.white) }
	end,
	respawn = function()
		return {
			ring(0.5, 0.52, 0.66, 0.13, C.white),
			box(0.5, 0.18, 0.3, 0.3, C.white, 0.08, 45),
			box(0.36, 0.18, 0.2, 0.3, hex("1E8CE8"), 0, 0),
		}
	end,
	wheel = function()
		return {
			ring(0.5, 0.5, 0.8, 0.12, C.white),
			box(0.5, 0.5, 0.24, 0.24, C.white, 0.5),
			bar(0.5, 0.5, 0.16, 0.42, 0.1, C.white),
			bar(0.5, 0.5, 0.84, 0.42, 0.1, C.white),
			bar(0.5, 0.5, 0.5, 0.86, 0.1, C.white),
		}
	end,
	clock = function()
		return {
			box(0.5, 0.5, 0.88, 0.88, C.white, 0.5),
			bar(0.5, 0.5, 0.5, 0.24, 0.09, C.ink),
			bar(0.5, 0.5, 0.7, 0.6, 0.09, C.ink),
		}
	end,
	key = function()
		return {
			ring(0.3, 0.5, 0.38, 0.11, GOLD_COIN),
			box(0.64, 0.5, 0.5, 0.12, GOLD_COIN, 0.3),
			box(0.8, 0.62, 0.08, 0.16, GOLD_COIN, 0.2),
			box(0.66, 0.62, 0.08, 0.13, GOLD_COIN, 0.2),
		}
	end,
	gift = function()
		return {
			box(0.5, 0.62, 0.76, 0.56, hex("FF6464"), 0.15),
			box(0.5, 0.36, 0.86, 0.2, hex("FF6464"), 0.15),
			box(0.5, 0.56, 0.14, 0.7, C.gold, 0),
			ring(0.38, 0.2, 0.22, 0.07, C.gold),
			ring(0.62, 0.2, 0.22, 0.07, C.gold),
		}
	end,
	turn = function()
		-- A hard-turn arrow: up the left, across the top, a pointed head on the right.
		return {
			bar(0.3, 0.84, 0.3, 0.42, 0.16, C.white),
			bar(0.3, 0.42, 0.62, 0.42, 0.16, C.white),
			box(0.68, 0.42, 0.3, 0.3, C.white, 0.08, 45),
		}
	end,
	boost = function()
		return {
			box(0.5, 0.5, 0.9, 0.9, hex("F57C00"), 0.5),
			box(0.5, 0.47, 0.82, 0.82, hex("FFB52E"), 0.5),
			bar(0.34, 0.66, 0.5, 0.3, 0.14, C.white),
			bar(0.5, 0.3, 0.66, 0.66, 0.14, C.white),
		}
	end,
}

-- One shape as a Frame / ImageLabel; ink: draw the ink copy (o px bigger all round) instead.
local function shapeFrame(parent: Instance, s: Shape, side: number, ink: boolean, o: number)
	local grow = if ink then 2 * o else 0
	if s.k == "img" then
		if ink then
			return
		end
		local im = Instance.new("ImageLabel")
		im.Name = "Img"
		im.BackgroundTransparency = 1
		im.Image = s.img or ""
		im.ImageColor3 = s.c
		im.ScaleType = Enum.ScaleType.Fit
		im.AnchorPoint = Vector2.new(0.5, 0.5)
		im.Position = UDim2.fromScale(s.x, s.y)
		im.Size = UDim2.fromScale(s.w, s.h)
		im.Active = false
		im.Parent = parent
		return
	end
	local f = Instance.new("Frame")
	f.Name = if ink then "Ink" else "Shape"
	f.Active = false
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(s.x, s.y)
	f.Size = UDim2.new(s.w, grow, s.h, grow)
	f.Rotation = s.rot or 0
	if s.k == "ring" then
		f.BackgroundTransparency = 1
		local st = Instance.new("UIStroke")
		st.Color = if ink then C.ink else s.c
		st.Thickness = math.max(1, (s.t or 0.1) * side + (if ink then 2 * o else 0))
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
		ArcadeUi.corner(f, UDim.new(0.5, 0))
		f.Size = UDim2.new(s.w, 0, s.h, 0)
	else
		f.BackgroundColor3 = if ink then C.ink else s.c
		f.BackgroundTransparency = s.a or 0
		local r = s.r or 0.2
		if r > 0 then
			local px = r * math.min(s.w, s.h) * side + (if ink then o else 0)
			ArcadeUi.corner(f, UDim.new(0, math.floor(px + 0.5)))
		end
	end
	f.Parent = parent
end

-- Icon kind -> uploaded art key (shared/UiV2Icons). Kinds without art (car, plane, wheel) are drawn from Frames.
ArcadeUi.ART = {
	coin = "icon_coin", coins = "icon_coins", cash = "icon_cash", token = "icon_star", star = "icon_star", flag = "icon_flag",
	lock = "icon_lock", check = "icon_check", trophy = "icon_trophy", calendar = "icon_daily", shop = "icon_shop",
	paint = "icon_paint", trail = "icon_trail", horn = "icon_horn", emote = "icon_emote", question = "icon_help",
	close = "icon_close", respawn = "icon_return", clock = "icon_stopwatch", key = "icon_key", gift = "item_gift_box",
	boost = "icon_quick", gear = "icon_gear", pass = "icon_pass", wrench = "icon_wrench", race = "icon_race", hub = "icon_hub",
	info = "icon_info", alert = "icon_alert", medal1 = "icon_medal_1", medal2 = "icon_medal_2", medal3 = "icon_medal_3",
	mystery = "item_mystery", battle = "icon_battle", boss = "icon_boss",
} :: { [string]: string }

-- The uploaded image for an item id (item_red, item_rocket_rush, ...), or nil.
function ArcadeUi.itemImage(id: string?): string?
	if not id then
		return nil
	end
	return UiV2Icons["item_" .. id]
end

function ArcadeUi.artOf(kind: string): string?
	local key = ArcadeUi.ART[kind]
	return if key then UiV2Icons[key] else nil
end

-- A procedural icon (see ICONS) in a square Frame. `px` is its pixel side (sets the outline and ring widths); size the
-- frame with opts.size or leave the default px square.
function ArcadeUi.icon(parent: Instance?, kind: string, opts: IconOpts?, px: number?): Frame
	local o: IconOpts = opts or {}
	local side = px or 32
	local f = Instance.new("Frame")
	f.Name = o.name or ("Icon_" .. kind)
	f.BackgroundTransparency = 1
	f.Active = false
	f.Size = o.size or UDim2.fromOffset(side, side)
	if o.position then
		f.Position = o.position
	end
	if o.anchor then
		f.AnchorPoint = o.anchor
	end
	if o.z then
		f.ZIndex = o.z
	end
	f:SetAttribute("IconKind", kind)
	local art = ArcadeUi.artOf(kind)
	if art then
		local im = Instance.new("ImageLabel")
		im.Name = "Art"
		im.BackgroundTransparency = 1
		im.Image = art
		im.ImageColor3 = Color3.new(1, 1, 1)
		im.ScaleType = Enum.ScaleType.Fit
		im.Size = UDim2.fromScale(1, 1)
		im.Active = false
		im.Parent = f
		f.Parent = parent
		return f
	end
	local make = ICONS[kind] or ICONS.question
	local shapes = make(o.color)
	local inkPx = math.max(1.5, side * 0.06)
	for _, s in shapes do
		if not s.noInk then
			shapeFrame(f, s, side, true, inkPx)
		end
	end
	for _, s in shapes do
		shapeFrame(f, s, side, false, inkPx)
	end
	if kind == "question" then
		local q = ArcadeUi.text(f, { name = "Q", text = "?", font = DISPLAY_UPRIGHT, maxSize = 200, stroke = 2, align = Enum.TextXAlignment.Center })
		q.Size = UDim2.fromScale(0.8, 0.8)
		q.Position = UDim2.fromScale(0.5, 0.48)
		q.AnchorPoint = Vector2.new(0.5, 0.5)
	end
	f.Parent = parent
	return f
end

-- Rebuilds an icon in place at a new pixel side (ring and outline widths follow the size).
function ArcadeUi.resizeIcon(icon: Frame, px: number)
	local kind = icon:GetAttribute("IconKind")
	if type(kind) ~= "string" then
		return
	end
	if ArcadeUi.artOf(kind) or icon:GetAttribute("IconPx") == px then
		return
	end
	icon:SetAttribute("IconPx", px)
	for _, c in icon:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local tmp = ArcadeUi.icon(nil, kind, nil, px)
	for _, c in tmp:GetChildren() do
		c.Parent = icon
	end
	tmp:Destroy()
end

return ArcadeUi
