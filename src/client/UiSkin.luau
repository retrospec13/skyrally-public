--!strict
-- UI skin factories. Every panel, button, tab, card, chip and icon is made here, so one file sets the look of the game.
--   * art set:   shared/UiImages has an id for the slot: the look is a 9-slice "SkinArt" ImageLabel (UI overhaul phase A;
--                slice rules in shared/UiSkinRules).
--   * art nil:   the UI v2 native theme (docs/design/UI_V2.md section 1), built only from Roblox UI objects: a top ->
--                bottom UIGradient fill (shared/UiSkinRules.VARIANT), a 3 px ink UIStroke, UICorner, and on buttons a
--                lighter gloss band over the top half plus a darker bottom lip, both painted into the same gradient
--                (UIGradient multiplies BackgroundColor3, so a retint keeps the shading). Button text is a "Label"
--                TextLabel child (white, ink stroke, the display face); the TextButton keeps .Text (mirrored) for code
--                and tools that read it. Legacy callers pass wood / brass / green fills: the rules classify them into
--                the theme's variants (go / sky / orange / danger / disabled; panels -> the blue panel).
-- Sizes stay the caller's (HudMetrics / HudLayoutRules.px); outlines, corners and lips follow S.
-- Existing tweens on BackgroundColor3 / BackgroundTransparency go through retint / setAlpha / tweenTarget / tween.
-- API (stable; add, do not rename): panel, style, button, styleButton, setText, getText, setEnabled, setVariant, tab,
-- setTab, card, chip, inset, header, iconSlot, icon, glyph, text / title / body / numeral, checker, font, color,
-- tweenTarget, retint, setAlpha, tween, artFor, hasArt.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("UiSkinRules"))
local UiImages = require(Shared:WaitForChild("UiImages")) :: { [string]: string? }
local UiV2Icons = require(Shared:WaitForChild("UiV2Icons")) :: { [string]: string? }
-- UI direction v3 frame ids (uploaded by the orchestrator); absent until then, and the native flat look stands in.
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
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))

local UiSkin = {}

-- Fetch the UI v2 icon set and the course art once at boot, so the first open of a surface does not show empty icons
-- while the images stream in.
task.spawn(function()
	local ids: { string } = {}
	for _, id in UiV2Icons do
		if type(id) == "string" then
			table.insert(ids, id)
		end
	end
	for _, id in V3 do
		if type(id) == "string" then
			table.insert(ids, id)
		end
	end
	local ok, art = pcall(function(): any
		return require(Shared:WaitForChild("CourseArt"))
	end)
	if ok and type(art) == "table" then
		for _, id in art do
			if type(id) == "string" then
				table.insert(ids, id)
			end
		end
	end
	-- v38-flow: three parallel batches (frames; course art; icons), so one slow batch never holds the others back
	local frames, rest = {}, {}
	for _, id in ids do
		local isFrame = false
		for _, f in V3 do
			if f == id then
				isFrame = true
			end
		end
		table.insert(if isFrame then frames else rest, id)
	end
	for _, batch in { frames, rest } do
		task.spawn(function()
			pcall(function()
				game:GetService("ContentProvider"):PreloadAsync(batch)
			end)
		end)
	end
end)

local SLOT_ATTR = "SkinSlot"
local ART_ATTR = "SkinArt" -- true on an ImageButton whose own Image is the art
local TINT_ATTR = "SkinTint" -- the base tint (before the state tint) of an art button
local S_ATTR = "SkinS"
local VAR_ATTR = "SkinVariant" -- native theme: the variant a control draws as
local ALPHA_ATTR = "SkinAlpha" -- native theme: the control's transparency (fill, outline and text)

export type Opts = {
	name: string?,
	-- look
	variant: string?, -- native theme variant (go, sky, orange, danger, disabled, purple, panel, card, inset, header, tab)
	color: Color3?, -- legacy fill: the art tint source, classified into a variant by the native theme
	alpha: number?, -- transparency (native: fill, outline and text; art: ImageTransparency)
	corner: (number | boolean)?, -- UICorner px at S = 1 (native default from the shape rules); false = none
	stroke: Color3?, -- outline colour override (native default: ink)
	strokeWidth: number?,
	strokeAlpha: number?,
	tint: Color3?, -- art tint source (defaults to color)
	image: string?, -- per-call art override (e.g. NotifySkin per-kind panel.image)
	slice: { number }?, -- SliceCenter override {l, t, r, b} for the override image
	S: number?, -- hud scale (default HudMetrics.S())
	-- geometry
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	zIndex: number?,
	layoutOrder: number?,
	visible: boolean?,
	active: boolean?,
	-- text (buttons)
	textColor: Color3?, -- art buttons only; the native theme writes white (ink on header / selected tabs)
	font: Enum.Font?, -- art buttons only; the native theme uses its display face
	textSize: number?,
	textScaled: boolean?,
	minText: number?, -- adds a UITextSizeConstraint
	maxText: number?,
	-- buttons
	sound: (string | boolean)?, -- UiSound kind (default "tap"); false = no UiSound.bind
	selectable: boolean?,
	glyph: string?, -- native buttons / tabs: a drawn icon left of the text (UiSkin.glyph name)
}

local function c3(rgb: { number }): Color3
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function toRgb(c: Color3): { number }
	return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
end

local Sh = Rules.SHAPE
local INK = c3(Rules.INK)
local STEEL = c3(Rules.STEEL) -- v3: the frame edge
local WHITE = Color3.new(1, 1, 1)

-- v3: an uploaded direction-v3 image id by key (frame_dark, stripe_tile, cursor_tri ...), or nil before the upload.
function UiSkin.v3Art(key: string): string?
	return V3[key]
end

-- v3: a label band along the bottom of a picture card: dark, a faint diagonal hazard-stripe texture, a steel top rule.
-- Returns the band (content goes in it).
function UiSkin.stripeBand(parent: Instance, opts: { size: UDim2?, position: UDim2?, anchor: Vector2?, zIndex: number?, alpha: number? }?): Frame
	local o: { size: UDim2?, position: UDim2?, anchor: Vector2?, zIndex: number?, alpha: number? } = opts or {} :: any
	local f = Instance.new("Frame")
	f.Name = "LabelBand"
	f.BorderSizePixel = 0
	f.BackgroundColor3 = c3(Rules.VARIANT.inset.top)
	f.BackgroundTransparency = o.alpha or 0.12
	f.Size = o.size or UDim2.fromScale(1, 0.3)
	f.Position = o.position or UDim2.fromScale(0, 1)
	f.AnchorPoint = o.anchor or Vector2.new(0, 1)
	f.ZIndex = o.zIndex or 1
	local tile = V3.stripe_tile
	if tile then
		local t = Instance.new("ImageLabel")
		t.Name = "Stripes"
		t.BackgroundTransparency = 1
		t.Image = tile
		t.ScaleType = Enum.ScaleType.Tile
		t.TileSize = UDim2.fromOffset(24, 24)
		t.Size = UDim2.fromScale(1, 1)
		t.ZIndex = f.ZIndex
		t.Parent = f
	end
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.BorderSizePixel = 0
	rule.BackgroundColor3 = STEEL
	rule.Size = UDim2.new(1, 0, 0, 2)
	rule.ZIndex = f.ZIndex
	rule.Parent = f
	f.Parent = parent
	return f
end

-- v3: "COURSE SELECT" as two colours ("COURSE" yellow, the rest white) with a trailing chevron (RichText).
function UiSkin.twoTone(text: string): string
	local first, rest = string.match(text, "^(%S+)%s*(.*)$")
	if not first then
		return text
	end
	local y = Rules.GOLD
	local hexy = string.format("#%02X%02X%02X", y[1], y[2], y[3])
	local tail: string = rest or ""
	return string.format('<font color="%s">%s</font>%s', hexy, first, if tail ~= "" then " " .. tail else "")
end

-- v3: a name with its LAST word in yellow ("RALLY <yellow>BIPLANE</yellow>"); one word stays white.
function UiSkin.twoToneLast(text: string): string
	local head, last = string.match(text, "^(.-)%s+(%S+)$")
	if not head or head == "" then
		return text
	end
	local y = Rules.GOLD
	return string.format('%s <font color="#%02X%02X%02X">%s</font>', head, y[1], y[2], y[3], last :: string)
end

-- v3 type over a picture or the live world: a soft drop shadow (an offset dark copy) instead of a thick ink stroke.
-- The shadow follows the label's text and its size cap.
function UiSkin.dropShadow(l: TextLabel, px: number?): TextLabel
	-- a sibling under the label (a child would draw over its parent with Sibling ZIndexBehavior)
	local old = l.Parent and l.Parent:FindFirstChild(l.Name .. "Shadow")
	if old then
		old:Destroy()
	end
	local d = px or 3
	local sh = Instance.new("TextLabel")
	sh.Name = l.Name .. "Shadow"
	sh.BackgroundTransparency = 1
	sh.Active = false
	sh.FontFace = l.FontFace
	sh.TextScaled = l.TextScaled
	sh.TextSize = l.TextSize
	sh.TextWrapped = l.TextWrapped
	sh.TextXAlignment = l.TextXAlignment
	sh.TextYAlignment = l.TextYAlignment
	sh.TextTruncate = l.TextTruncate
	local function geo()
		sh.AnchorPoint = l.AnchorPoint
		sh.Position = l.Position + UDim2.fromOffset(d, d)
		sh.Size = l.Size
		sh.Visible = l.Visible
	end
	geo()
	for _, prop in { "Position", "Size", "Visible", "AnchorPoint" } do
		l:GetPropertyChangedSignal(prop):Connect(geo)
	end
	sh.TextColor3 = INK
	sh.TextTransparency = 0.3
	-- RichText colour tags would paint the shadow yellow: strip them
	local function sync()
		sh.Text = string.gsub(l.Text, "<[^>]+>", "")
	end
	sync()
	local lc = l:FindFirstChildOfClass("UITextSizeConstraint")
	if lc then
		local nc = Instance.new("UITextSizeConstraint")
		nc.MinTextSize = lc.MinTextSize
		nc.MaxTextSize = lc.MaxTextSize
		nc.Parent = sh
		lc:GetPropertyChangedSignal("MaxTextSize"):Connect(function()
			nc.MaxTextSize = lc.MaxTextSize
		end)
	end
	l:GetPropertyChangedSignal("Text"):Connect(sync)
	l:GetPropertyChangedSignal("Parent"):Connect(function()
		if l.Parent == nil then
			sh:Destroy()
		end
	end)
	l.ZIndex = math.max(l.ZIndex, 2)
	sh.ZIndex = l.ZIndex - 1
	sh.Parent = l.Parent
	return sh
end

-- v38-flow round 3: one key feel for both kits (docs/design/UI_V2.md section 4 motion). Hover / gamepad focus lays the
-- pale version of the key's own 9-slice over it (the edge and face brighten), idle keys sit a touch dimmer; the scale
-- lift, the press dip and the click sound are UiSound.bind's. Gamepad focus also draws the shared focus ring.
local LIGHT_OF: { [string]: string } = { bar = "bar_light", frame = "frame_light", tab = "tab_light", chip = "bar_light" }
function UiSkin.hoverGlow(b: GuiObject, on: boolean)
	local fr = b:FindFirstChild("SkinFrame")
	if not (fr and fr:IsA("ImageLabel")) then
		return
	end
	local glow = b:FindFirstChild("HoverGlow")
	if on and b:GetAttribute("SkinDisabled") ~= true and b:GetAttribute("KeyOn") ~= false then
		if not (glow and glow:IsA("ImageLabel")) then
			local key = ""
			for k, v in V3 do
				if v == fr.Image then
					key = k
				end
			end
			local kind = string.match(key, "^(%a+)_") or "bar"
			local id = V3[LIGHT_OF[kind] or "bar_light"]
			if not id then
				return
			end
			local g = Instance.new("ImageLabel")
			g.Name = "HoverGlow"
			g.BackgroundTransparency = 1
			g.Active = false
			g.Image = id
			g.ScaleType = Enum.ScaleType.Slice
			g.SliceCenter = fr.SliceCenter
			g.SliceScale = fr.SliceScale
			g.Size = fr.Size
			g.Position = fr.Position
			g.ImageTransparency = 1
			g.ZIndex = fr.ZIndex
			g.Parent = b
			glow = g
		end
		local g = glow :: ImageLabel
		g.SliceScale = fr.SliceScale
		TweenService:Create(g, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { ImageTransparency = 0.72 }):Play()
		fr.ImageColor3 = WHITE
	elseif glow and glow:IsA("ImageLabel") then
		TweenService:Create(glow, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { ImageTransparency = 1 }):Play()
		fr.ImageColor3 = Color3.fromRGB(232, 232, 232)
	else
		fr.ImageColor3 = Color3.fromRGB(232, 232, 232)
	end
end

-- The gamepad focus ring every kit key uses (GuiObject.SelectionImageObject): a yellow edge and the triangle cursor.
local focusRing: Frame? = nil
function UiSkin.focusRing(): Frame
	local r = focusRing
	if r then
		return r
	end
	local f = Instance.new("Frame")
	f.Name = "FocusRing"
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 8, 1, 8)
	f.Position = UDim2.fromOffset(-4, -4)
	local s = Instance.new("UIStroke")
	s.Color = c3(Rules.GOLD)
	s.Thickness = 3
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = f
	if V3.cursor_tri then
		local c = Instance.new("ImageLabel")
		c.Name = "Cursor"
		c.BackgroundTransparency = 1
		c.Image = V3.cursor_tri :: string
		c.ImageColor3 = c3(Rules.GOLD)
		c.AnchorPoint = Vector2.new(1, 0.5)
		c.Position = UDim2.new(0, -2, 0.5, 0)
		c.Size = UDim2.fromScale(0.5, 0.5)
		c.SizeConstraint = Enum.SizeConstraint.RelativeYY
		c.Parent = f
	end
	focusRing = f
	return f
end

-- v3: the bottom input legend ("[A] SELECT   [B] BACK"), in the active device's words; hidden on touch. entries:
-- { gamepad = "A", keyboard = "ENTER", label = "SELECT" } ... Returns the row (place it with size / position).
export type LegendEntry = { gamepad: string, keyboard: string, label: string }
function UiSkin.legend(parent: Instance, entries: { LegendEntry }, opts: { size: UDim2?, position: UDim2?, anchor: Vector2?, zIndex: number? }?): Frame
	local o: { size: UDim2?, position: UDim2?, anchor: Vector2?, zIndex: number? } = opts or {} :: any
	local lp = game:GetService("Players").LocalPlayer
	local row = Instance.new("Frame")
	row.Name = "Legend"
	row.BackgroundTransparency = 1
	row.Size = o.size or UDim2.new(1, 0, 0, 22)
	row.Position = o.position or UDim2.fromScale(0.5, 1)
	row.AnchorPoint = o.anchor or Vector2.new(0.5, 1)
	row.ZIndex = o.zIndex or 1
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 14)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = row
	local function paint()
		for _, c in row:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local mode = lp:GetAttribute("InputMode")
		row.Visible = mode ~= "Touch"
		for i, e in entries do
			local key = if mode == "Gamepad" then e.gamepad else e.keyboard
			local item = Instance.new("Frame")
			item.Name = "Entry" .. i
			item.BackgroundTransparency = 1
			item.AutomaticSize = Enum.AutomaticSize.X
			item.Size = UDim2.fromScale(0, 1)
			item.LayoutOrder = i
			item.ZIndex = row.ZIndex
			item.Parent = row
			local il = Instance.new("UIListLayout")
			il.FillDirection = Enum.FillDirection.Horizontal
			il.VerticalAlignment = Enum.VerticalAlignment.Center
			il.Padding = UDim.new(0, 6)
			il.Parent = item
			local badge = Instance.new("TextLabel")
			badge.Name = "Key"
			badge.AutomaticSize = Enum.AutomaticSize.X
			badge.Size = UDim2.fromScale(0, 1)
			badge.BackgroundColor3 = if mode == "Gamepad" then c3(Rules.VARIANT.go.top) else STEEL
			badge.TextColor3 = INK
			badge.FontFace = UiSkin.font("display")
			badge.TextScaled = false
			UiSkin.liveSize(badge, 13) -- round 3: grows with the screen (was a fixed 14 px at 1080p)
			badge.Text = key
			badge.ZIndex = row.ZIndex
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 6)
			pad.PaddingRight = UDim.new(0, 6)
			pad.Parent = badge
			local uc = Instance.new("UICorner")
			uc.CornerRadius = UDim.new(0, if mode == "Gamepad" then 99 else 3)
			uc.Parent = badge
			badge.Parent = item
			local t = Instance.new("TextLabel")
			t.Name = "Label"
			t.AutomaticSize = Enum.AutomaticSize.X
			t.Size = UDim2.fromScale(0, 1)
			t.BackgroundTransparency = 1
			t.TextColor3 = WHITE
			t.FontFace = UiSkin.font("display")
			UiSkin.liveSize(t, 13)
			t.Text = e.label
			t.ZIndex = row.ZIndex
			t.Parent = item
		end
	end
	paint()
	lp:GetAttributeChangedSignal("InputMode"):Connect(paint)
	row.Parent = parent
	return row
end

-- v3: the large diagonal navy wedge a menu sits on (over the live world). Put it first in a full-screen gui.
function UiSkin.wedge(parent: Instance, opts: { zIndex: number?, alpha: number? }?): Frame
	local o: { zIndex: number?, alpha: number? } = opts or {} :: any
	local w = Instance.new("Frame")
	w.Name = "Wedge"
	w.Active = false
	w.BorderSizePixel = 0
	w.BackgroundColor3 = c3(Rules.INK)
	w.BackgroundTransparency = o.alpha or 0.18
	w.AnchorPoint = Vector2.new(0.5, 0.5)
	w.Position = UDim2.fromScale(0.42, 0.5)
	w.Size = UDim2.fromScale(0.95, 2.2)
	w.Rotation = 18
	w.ZIndex = o.zIndex or 0
	local g = Instance.new("UIGradient")
	g.Rotation = 0
	g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.85, 0.35), NumberSequenceKeypoint.new(1, 1) })
	g.Parent = w
	w.Parent = parent
	return w
end

-- v3: the triangle cursor that slides to the focused (hovered / gamepad-selected) row of a list. rows: the buttons;
-- the cursor sits just left of the row, vertically centred, and moves in 90 ms.
function UiSkin.listCursor(parent: GuiObject, rows: { GuiObject }): ImageLabel?
	local id = V3.cursor_tri
	if not id then
		return nil
	end
	local c = Instance.new("ImageLabel")
	c.Name = "Cursor"
	c.BackgroundTransparency = 1
	c.Image = id
	c.ImageColor3 = c3(Rules.GOLD)
	c.Size = UDim2.fromOffset(22, 22)
	c.AnchorPoint = Vector2.new(1, 0.5)
	c.Visible = false
	c.ZIndex = 50
	c.Parent = parent
	local function goTo(r: GuiObject)
		if not r.Visible then
			return
		end
		local rel = r.AbsolutePosition - parent.AbsolutePosition
		local sc = parent.AbsoluteSize.X / math.max(1, parent.Size.X.Offset)
		if parent.Size.X.Offset <= 0 then
			sc = 1
		end
		local target = UDim2.fromOffset(rel.X / sc - 4, (rel.Y + r.AbsoluteSize.Y / 2) / sc)
		if not c.Visible then
			c.Position = target
			c.Visible = true
		end
		TweenService:Create(c, TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = target }):Play()
	end
	for _, r in rows do
		if r:IsA("GuiButton") then
			r.MouseEnter:Connect(function()
				goTo(r)
			end)
			r.SelectionGained:Connect(function()
				goTo(r)
			end)
		end
	end
	return c
end

-- The art for a slot (an override wins), or nil for the native theme.
function UiSkin.artFor(slot: string?, override: string?): string?
	if override and override ~= "" then
		return override
	end
	if not slot then
		return nil
	end
	local id = UiImages[slot] or UiV2Icons[slot]
	return if id and id ~= "" then id else nil
end

function UiSkin.hasArt(slot: string): boolean
	return UiSkin.artFor(slot) ~= nil
end

-- A theme colour by name: a variant's top ("go", "panel", ...), or "ink", "gold", "white", "rarity_<r>", "place_<n>".
function UiSkin.color(name: string): Color3
	if name == "ink" then
		return INK
	elseif name == "gold" then
		return c3(Rules.GOLD)
	elseif name == "white" then
		return WHITE
	end
	local r = string.match(name, "^rarity_(%a+)$")
	if r and Rules.RARITY[r] then
		return c3(Rules.RARITY[r])
	end
	local p = string.match(name, "^place_(%d+)$")
	if p then
		return c3(Rules.placeColor(tonumber(p) or 0))
	end
	local v = Rules.VARIANT[name]
	return if v then c3(v.top) else WHITE
end

-- The viewport type scale (UiSkinRules.typeScale): multiplies every text cap the kit sets.
function UiSkin.typeScale(): number
	local cam = workspace.CurrentCamera
	return Rules.typeScale(if cam then cam.ViewportSize.Y else 720)
end
local function capT(n: number): number
	return math.floor(n * UiSkin.typeScale() + 0.5)
end

-- v38-flow round 3: text caps follow the viewport LIVE. A cap was computed once at creation, so a surface built while
-- the camera was still phone-sized (boot, a device switch) kept phone-small labels at 1080p (Garage tabs read 18 px).
-- Every kit cap registers here with its phone-size base and is recomputed when the viewport changes.
-- strong tables (a weak Instance key can be collected while the Instance lives on); entries leave on Destroying
local liveCaps: { [UITextSizeConstraint]: number } = {}
local liveSizes: { [TextLabel]: number } = {}
local liveWired = false
local function relive()
	for c, base in liveCaps do
		if c.Parent then
			c.MaxTextSize = capT(base)
		end
	end
	for l, base in liveSizes do
		if l.Parent then
			l.TextSize = capT(base)
		end
	end
end
local function wireLive()
	if liveWired then
		return
	end
	liveWired = true
	local camConn: RBXScriptConnection? = nil
	local function bindCam()
		if camConn then
			camConn:Disconnect()
		end
		local cam = workspace.CurrentCamera
		if cam then
			camConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(relive)
		end
		relive()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCam)
	bindCam()
end
-- Sets c.MaxTextSize from a phone-size base and keeps it scaled with the viewport.
function UiSkin.liveCap(c: UITextSizeConstraint, base: number)
	wireLive()
	if liveCaps[c] == nil then
		c.Destroying:Connect(function()
			liveCaps[c] = nil
		end)
	end
	liveCaps[c] = base
	c.MaxTextSize = capT(base)
end
-- A fixed TextSize label (no TextScaled) that should still grow with the screen: base is its phone size.
function UiSkin.liveSize(l: TextLabel, base: number)
	wireLive()
	if liveSizes[l] == nil then
		l.Destroying:Connect(function()
			liveSizes[l] = nil
		end)
	end
	liveSizes[l] = base
	l.TextSize = capT(base)
end

local fontCache: { [string]: Font } = {}
-- The theme's faces: "display" (heavy italic: titles, numerals), "button", "body" (rounded bold), "bodyHeavy".
function UiSkin.font(kind: string?): Font
	local k = kind or "body"
	local cached = fontCache[k]
	if cached then
		return cached
	end
	local d = Rules.FONT[k] or Rules.FONT.body
	local f = Font.new(d.family, (Enum.FontWeight :: any)[d.weight], (Enum.FontStyle :: any)[d.style])
	fontCache[k] = f
	return f
end

local function scaleOf(g: Instance): number
	local s = g:GetAttribute(S_ATTR)
	return if type(s) == "number" then s else HudMetrics.S()
end

-- Pixel size the frame is laid out at (offset sizes are known before the first layout pass; scale sizes are not).
local function sizeOf(g: GuiObject): (number, number)
	local s = g.Size
	local w = if s.X.Scale == 0 then s.X.Offset else g.AbsoluteSize.X
	local h = if s.Y.Scale == 0 then s.Y.Offset else g.AbsoluteSize.Y
	return w, h
end

local function applySlice(target: any, holder: GuiObject, slot: string, image: string, slice: { number }?)
	local S = (holder:GetAttribute(S_ATTR) :: number?) or 1
	local rule = Rules.SLICE[slot]
	target.Image = image
	if rule and rule.kind == "icon" then
		target.ScaleType = Enum.ScaleType.Fit
		return
	end
	target.ScaleType = Enum.ScaleType.Slice
	local c = slice or (if rule then rule.center else nil)
	if c then
		target.SliceCenter = Rect.new(c[1], c[2], c[3], c[4])
	end
	local w, h = sizeOf(holder)
	target.SliceScale = Rules.sliceScale(slot, S, w, h)
end

-- SliceScale depends on the laid-out size: recompute when a scale-sized frame changes size. One hook per object.
local watched: { [GuiObject]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function ensureCorner(g: GuiObject, px: (number | boolean)?)
	local found = g:FindFirstChildOfClass("UICorner")
	if px == false then
		if found then
			found:Destroy()
		end
		return
	end
	local uc: UICorner
	if found then
		uc = found
	else
		uc = Instance.new("UICorner")
		uc.Parent = g
	end
	if type(px) == "number" then
		uc.CornerRadius = UDim.new(0, px)
	end
end

-- The control's border UIStroke (never a text stroke: those live on Label children).
local function borderStroke(g: GuiObject, create: boolean): UIStroke?
	for _, ch in g:GetChildren() do
		if ch:IsA("UIStroke") and ch.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
			return ch
		end
	end
	if not create then
		return nil
	end
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = g
	return s
end

local function artChild(g: GuiObject): ImageLabel?
	local a = g:FindFirstChild("SkinArt")
	return if a and a:IsA("ImageLabel") then a else nil
end

local function tintOf(slot: string, opts: Opts): Color3
	local src = opts.tint or opts.color
	return c3(Rules.artTint(slot, if src then toRgb(src) else nil))
end

local function applyGeometry(g: GuiObject, opts: Opts)
	if opts.name then
		g.Name = opts.name
	end
	if opts.size then
		g.Size = opts.size
	end
	if opts.position then
		g.Position = opts.position
	end
	if opts.anchor then
		g.AnchorPoint = opts.anchor
	end
	if opts.zIndex then
		g.ZIndex = opts.zIndex
	end
	if opts.layoutOrder then
		g.LayoutOrder = opts.layoutOrder
	end
	if opts.visible ~= nil then
		g.Visible = opts.visible
	end
	if opts.active ~= nil then
		g.Active = opts.active
	end
end

---------------------------------------------------------------------------------------------------- native theme

-- Text on colour: white (or ink), the ink text stroke and the theme face. Used by labels and button Labels.
local function inkText(l: TextLabel | TextButton, S: number, thick: number?)
	local st: UIStroke? = nil
	for _, ch in l:GetChildren() do
		if ch:IsA("UIStroke") and ch.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
			st = ch
		end
	end
	if not st then
		local s = Instance.new("UIStroke")
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		s.LineJoinMode = Enum.LineJoinMode.Round
		s.Parent = l
		st = s
	end
	local s = st :: UIStroke
	s.Color = INK
	-- v3: a soft dark outline (drop-shadow feel), never the old fat ink stroke; legacy callers asking for 2-3 px get ~1.2.
	s.Thickness = math.max(1, math.min(thick or Sh.textStroke, Sh.textStroke) * math.clamp(S, 0.6, 1.6))
	s.Transparency = 0.25
end

local function gradientOf(g: GuiObject): UIGradient
	local gr = g:FindFirstChild("SkinGradient")
	if gr and gr:IsA("UIGradient") then
		return gr
	end
	local n = Instance.new("UIGradient")
	n.Name = "SkinGradient"
	n.Rotation = 90
	n.Parent = g
	return n
end

local function attrColor(g: Instance, name: string, default: Color3): Color3
	local v = g:GetAttribute(name)
	return if typeof(v) == "Color3" then v else default
end

local function attrNum(g: Instance, name: string, default: number): number
	local v = g:GetAttribute(name)
	return if type(v) == "number" then v else default
end

-- Paints the face gradient from the stored top / bottom colours, gloss band and lip (lip px over the laid-out height).
local function paintFace(g: GuiObject)
	local top = attrColor(g, "SkinTop", WHITE)
	local bottom = attrColor(g, "SkinBottom", top)
	local gloss = attrNum(g, "SkinGloss", 0)
	local lipPx = attrNum(g, "SkinLipNow", attrNum(g, "SkinLip", 0))
	if g:GetAttribute("SkinHover") == true then
		top = top:Lerp(WHITE, Sh.hoverLift)
		bottom = bottom:Lerp(WHITE, Sh.hoverLift * 0.6)
	end
	local _, h = sizeOf(g)
	if h <= 0 then
		h = 44
	end
	local base, stops = Rules.faceStops(toRgb(top), toRgb(bottom), gloss, if lipPx > 0 then lipPx / h else 0)
	g.BackgroundColor3 = c3(base)
	local kps = {}
	for _, st in stops do
		table.insert(kps, ColorSequenceKeypoint.new(st.t, Color3.new(st.mul[1], st.mul[2], st.mul[3])))
	end
	gradientOf(g).Color = ColorSequence.new(kps)
	local label = g:FindFirstChild("Label")
	if label and label:IsA("TextLabel") then
		label.Size = UDim2.new(1, 0, 1, -math.floor(attrNum(g, "SkinLip", 0) + 0.5))
		label.Position = UDim2.fromOffset(0, math.floor(attrNum(g, "SkinLip", 0) - lipPx + 0.5))
	end
end

local faceWatched: { [GuiObject]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function setFace(g: GuiObject, top: Color3, bottom: Color3, gloss: number, lipPx: number)
	g:SetAttribute("SkinTop", top)
	g:SetAttribute("SkinBottom", bottom)
	g:SetAttribute("SkinGloss", gloss)
	g:SetAttribute("SkinLip", lipPx)
	g:SetAttribute("SkinLipNow", nil)
	paintFace(g)
	if not faceWatched[g] then
		faceWatched[g] = true
		g:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if attrNum(g, "SkinLip", 0) > 0 then
				paintFace(g)
			end
		end)
	end
end

local function variantColors(v: string): (Color3, Color3, Rules.Variant)
	local d = Rules.VARIANT[v] or Rules.VARIANT.sky
	return c3(d.top), c3(d.bottom), d
end

-- The transparency of everything a native control draws (fill, outline, label text and its stroke).
local function applyAlpha(g: GuiObject, alpha: number)
	g:SetAttribute(ALPHA_ATTR, alpha)
	local role = g:GetAttribute("SkinRole")
	local fillAlpha = alpha
	if role == "inset" or g:GetAttribute(VAR_ATTR) == "inset" then
		fillAlpha = 1 - (1 - alpha) * (1 - Rules.INSET_ALPHA)
	end
	g.BackgroundTransparency = fillAlpha -- a framed control mirrors this onto its SkinFrame image (nativeLook)
	local st = borderStroke(g, false)
	if st then
		st.Transparency = math.clamp(attrNum(g, "SkinStrokeAlpha", 0) + alpha * (1 - attrNum(g, "SkinStrokeAlpha", 0)), 0, 1)
	end
	local l = g:FindFirstChild("Label")
	if l and l:IsA("TextLabel") then
		local dim = if g:GetAttribute(VAR_ATTR) == "disabled" then (Rules.VARIANT.disabled.textAlpha or 0.4) else 0
		local a = 1 - (1 - alpha) * (1 - dim)
		l.TextTransparency = a
		local ts = l:FindFirstChildOfClass("UIStroke")
		if ts then
			ts.Transparency = 0.25 + 0.75 * a
		end
	end
end

local ROLE_LOOK = {
	panel = { gloss = 0, lip = 0, corner = Sh.panelCorner, outline = Sh.panelOutline },
	card = { gloss = 0, lip = 0, corner = Sh.corner, outline = Sh.outline },
	chip = { gloss = 0, lip = 0, corner = Sh.chipCorner, outline = 2 },
	inset = { gloss = 0, lip = 0, corner = Sh.chipCorner, outline = 0 },
	header = { gloss = 0.5, lip = 0, corner = Sh.chipCorner, outline = Sh.outline },
	button = { gloss = Sh.gloss, lip = Sh.lip, corner = Sh.corner, outline = Sh.outline },
	tab = { gloss = Sh.gloss, lip = 3, corner = Sh.chipCorner, outline = Sh.outline },
}

-- The native look for a role + variant on any GuiObject (frame or button). Safe to call every step.
local function nativeLook(g: GuiObject, role: string, variant: string, o: Opts)
	local S = scaleOf(g)
	local look = ROLE_LOOK[role] or ROLE_LOOK.panel
	local drawRole = if variant == "inset" then "inset" else role
	if variant == "inset" then
		look = ROLE_LOOK.inset
	end
	g:SetAttribute("SkinRole", drawRole)
	g:SetAttribute(VAR_ATTR, variant)
	local top, bottom = variantColors(variant)
	if variant == "custom" and o.color then
		top = o.color
		bottom = c3(Rules.bottomFor(toRgb(o.color)))
	end
	setFace(g, top, bottom, look.gloss, if look.lip > 0 then math.max(2, math.floor(look.lip * S + 0.5)) else 0)
	if variant == "inset" then
		local gr = g:FindFirstChild("SkinGradient")
		if gr and gr:IsA("UIGradient") then
			gr.Color = ColorSequence.new(WHITE, Color3.new(0.85, 0.85, 0.85))
		end
		g.BackgroundColor3 = top
	end
	local corner = o.corner
	if corner ~= false then
		corner = math.floor(look.corner * math.clamp(S, 0.7, 1.6) + 0.5)
	end
	ensureCorner(g, corner)
	local width = look.outline
	if width > 0 then
		local st = borderStroke(g, true) :: UIStroke
		st.Enabled = true
		-- A legacy rim (sand, wood) is replaced by ink; a saturated caller outline (a gold selection rim) is kept.
		local keep = false
		if o.stroke then
			local _, sat = Rules.hsv(toRgb(o.stroke))
			keep = sat >= 0.45
		end
		-- v3: the edge is pale steel (a saturated caller rim, e.g. a gold focus ring, still wins).
		st.Color = if keep and o.stroke then o.stroke else STEEL
		st.Thickness = math.max(1, (o.strokeWidth or width) * math.clamp(S, 0.7, 1.6))
		g:SetAttribute("SkinStrokeAlpha", o.strokeAlpha or 0)
	else
		local st = borderStroke(g, false)
		if st then
			st.Enabled = false
		end
	end
	-- v3: the shared 9-slice frame for this role + variant over a transparent fill (the steel edge is in the art).
	-- a square tile drawn with a key role (course-select mode tiles) asks for the chamfer frame: SkinShape = "frame"
	local artRole = if g:GetAttribute("SkinShape") == "frame" then "card" else drawRole
	local key = Rules.v3Frame(artRole, variant)
	-- An AutomaticSize host would grow to fit a full-size image child, which grows with it (the guide card ran 600 px
	-- tall at 844x390): those keep the flat look.
	local id = if key and g.AutomaticSize == Enum.AutomaticSize.None then V3[key] else nil
	local art = g:FindFirstChild("SkinFrame")
	if id and key then
		local im: ImageLabel
		if art and art:IsA("ImageLabel") then
			im = art
		else
			im = Instance.new("ImageLabel")
			im.Name = "SkinFrame"
			im.BackgroundTransparency = 1
			im.Size = UDim2.fromScale(1, 1)
			im.Active = false
			im.ScaleType = Enum.ScaleType.Slice
			im.Parent = g
			g:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
				local k = g:GetAttribute("SkinFrameKey")
				local sl2 = if type(k) == "string" then Rules.V3_SLICE[Rules.v3Kind(k)] else nil
				if sl2 and im.Parent then
					local b2 = sl2.center[2] + (sl2.size[2] - sl2.center[4])
					local h2 = g.AbsoluteSize.Y
					im.SliceScale = math.clamp(math.min(math.clamp(scaleOf(g), 0.6, 1.4), if h2 > 0 then h2 / b2 else 1), 0.2, 1.4)
				end
			end)
		end
		g:SetAttribute("SkinFrameKey", key)
		local sl = Rules.V3_SLICE[Rules.v3Kind(key)]
		im.Image = id
		im.SliceCenter = Rect.new(sl.center[1], sl.center[2], sl.center[3], sl.center[4])
		local _, hh = sizeOf(g)
		-- edges stay ~ the source px at S = 1, shrunk on short controls so top + bottom borders never overlap
		local bord = sl.center[2] + (sl.size[2] - sl.center[4])
		im.SliceScale = math.clamp(math.min(math.clamp(S, 0.6, 1.4), if hh > 0 then hh / bord else 1), 0.2, 1.4)
		im.ZIndex = -1 -- under every sibling whatever their ZIndex (Sibling behaviour: children draw over the parent)
		im.ImageColor3 = if g:GetAttribute("SkinHover") == true then Color3.new(1, 1, 1) else Color3.fromRGB(232, 232, 232)
		-- The flat fill is hidden through its gradient (not BackgroundTransparency), so a caller that fades or hides the
		-- control through BackgroundTransparency still does: the frame image mirrors it.
		gradientOf(g).Transparency = NumberSequence.new(1)
		im.ImageTransparency = g.BackgroundTransparency
		if g:GetAttribute("SkinFramed") ~= true then
			g:GetPropertyChangedSignal("AutomaticSize"):Connect(function()
				local f3 = g:FindFirstChild("SkinFrame")
				if f3 and g.AutomaticSize ~= Enum.AutomaticSize.None then
					f3:Destroy()
					g:SetAttribute("SkinFramed", nil)
					gradientOf(g).Transparency = NumberSequence.new(0)
					local bs = borderStroke(g, false)
					if bs then
						bs.Enabled = true
					end
				end
			end)
			g:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function()
				local f2 = g:FindFirstChild("SkinFrame")
				if f2 and f2:IsA("ImageLabel") and g:GetAttribute("SkinFramed") == true then
					f2.ImageTransparency = g.BackgroundTransparency
				end
			end)
		end
		g:SetAttribute("SkinFramed", true)
		local st = borderStroke(g, false)
		if st then
			st.Enabled = false
		end
	elseif art then
		art:Destroy()
		g:SetAttribute("SkinFramed", nil)
		gradientOf(g).Transparency = NumberSequence.new(0)
	end
	applyAlpha(g, o.alpha or attrNum(g, ALPHA_ATTR, 0))
end

local function variantOf(slot: string, role: string, o: Opts): string
	if o.variant then
		return o.variant
	end
	if role == "tab" then
		if slot == "tab_selected" then
			return "header"
		end
		if o.color then
			local cls = Rules.classify(toRgb(o.color))
			return if cls == "orange" then "header" else "tab"
		end
		return "tab"
	end
	if role == "header" then
		return "header"
	end
	return Rules.variantFor(slot, if o.color then toRgb(o.color) else nil, role)
end

-- (Re)skins a frame for a slot; safe to call every step (children are reused). Art when the slot (or opts.image) has an
-- id, the native theme otherwise.
function UiSkin.style(g: GuiObject, slot: string, opts: Opts?)
	local o: Opts = opts or {}
	g:SetAttribute(SLOT_ATTR, slot)
	g:SetAttribute(S_ATTR, o.S or HudMetrics.S())
	g.BorderSizePixel = 0
	local img = UiSkin.artFor(slot, o.image)
	local art = artChild(g)
	if img then
		if not art then
			local a = Instance.new("ImageLabel")
			a.Name = "SkinArt"
			a.BackgroundTransparency = 1
			a.Size = UDim2.fromScale(1, 1)
			a.ZIndex = 0 -- under the panel's other children (Sibling ZIndexBehavior)
			a.Active = false
			a.Parent = g
			art = a
		end
		local a = art :: ImageLabel
		a.Visible = true
		applySlice(a, g, slot, img, if o.image then o.slice else nil)
		a.ImageColor3 = tintOf(slot, o)
		a.ImageTransparency = o.alpha or 0
		g.BackgroundTransparency = 1
		if o.color then
			g.BackgroundColor3 = o.color -- kept as the colour retint / tweens read back
		end
		ensureCorner(g, o.corner)
		local st = borderStroke(g, false)
		if st then
			st.Enabled = false
		end
		local gr = g:FindFirstChild("SkinGradient")
		if gr then
			gr:Destroy()
		end
		if not watched[g] then
			watched[g] = true
			g:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
				local cur = artChild(g)
				local s = g:GetAttribute(SLOT_ATTR)
				if cur and cur.Visible and type(s) == "string" then
					local w, h = sizeOf(g)
					cur.SliceScale = Rules.sliceScale(s, (g:GetAttribute(S_ATTR) :: number?) or 1, w, h)
				end
			end)
		end
	else
		if art then
			art.Visible = false
		end
		local role = Rules.roleOf(slot)
		nativeLook(g, role, variantOf(slot, role, o), o)
	end
end

-- A skinned Frame (card, chip, toast, row) parented to `parent`.
function UiSkin.panel(parent: Instance?, slot: string, opts: Opts?): Frame
	local o: Opts = opts or {}
	local f = Instance.new("Frame")
	f.Name = o.name or "Panel"
	applyGeometry(f, o)
	UiSkin.style(f, slot, o)
	f.Parent = parent
	return f
end

---------------------------------------------------------------------------------------------------- buttons

local function isArtButton(b: GuiObject): boolean
	return b:IsA("ImageButton") and b:GetAttribute(ART_ATTR) == true
end

-- The object that carries a button's text: its "Label" child (art and native), else the button itself.
local function textHost(b: GuiObject): any -- TextButton | TextLabel (Luau cannot write through that union)
	local l = b:FindFirstChild("Label")
	if l and l:IsA("TextLabel") then
		return l
	end
	if b:IsA("TextButton") or b:IsA("TextLabel") then
		return b
	end
	return nil
end

local function sizeConstraint(t: Instance, minText: number?, maxText: number?)
	if not minText and not maxText then
		return
	end
	local found = t:FindFirstChildOfClass("UITextSizeConstraint")
	local l: UITextSizeConstraint
	if found then
		l = found
	else
		l = Instance.new("UITextSizeConstraint")
		l.Parent = t
	end
	if minText then
		l.MinTextSize = minText
	end
	if maxText then
		UiSkin.liveCap(l, maxText)
	end
end

local function applyText(b: GuiObject, o: Opts)
	local t = textHost(b)
	if not t then
		return
	end
	local native = t ~= b and not isArtButton(b)
	if not native then
		if o.textColor then
			t.TextColor3 = o.textColor
		end
		if o.font then
			t.Font = o.font
		end
	end
	if o.textSize then
		t.TextSize = o.textSize
		if native and o.textScaled == nil then
			t.TextScaled = false
		end
	end
	if o.textScaled ~= nil then
		t.TextScaled = o.textScaled
	end
	sizeConstraint(t, o.minText, o.maxText)
end

-- The native button's Label: white display-face text with the ink stroke; mirrors the TextButton's Text.
local function ensureLabel(b: TextButton): TextLabel
	local found = b:FindFirstChild("Label")
	if found and found:IsA("TextLabel") then
		return found
	end
	local l = Instance.new("TextLabel")
	l.Name = "Label"
	l.BackgroundTransparency = 1
	l.Active = false
	l.Size = UDim2.fromScale(1, 1)
	l.FontFace = UiSkin.font("button")
	l.TextColor3 = WHITE
	l.TextScaled = true
	l.Text = b.Text
	l.ZIndex = b.ZIndex
	l.RichText = b.RichText
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.06, 0)
	pad.PaddingRight = UDim.new(0.06, 0)
	pad.PaddingTop = UDim.new(0.16, 0)
	pad.PaddingBottom = UDim.new(0.14, 0)
	pad.Parent = l
	local c = Instance.new("UITextSizeConstraint")
	UiSkin.liveCap(c, 48)
	c.MinTextSize = 9
	c.Parent = l
	inkText(l, scaleOf(b))
	l.Parent = b
	b.TextTransparency = 1
	-- A text stroke a legacy caller puts on the button itself would outline the hidden button text: off.
	local function muteStroke(c: Instance)
		if c:IsA("UIStroke") and c.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
			c.Enabled = false
		end
	end
	for _, c in b:GetChildren() do
		muteStroke(c)
	end
	b.ChildAdded:Connect(muteStroke)
	b:GetPropertyChangedSignal("Text"):Connect(function()
		l.Text = b.Text
	end)
	b:GetPropertyChangedSignal("ZIndex"):Connect(function()
		l.ZIndex = b.ZIndex
	end)
	b:GetPropertyChangedSignal("RichText"):Connect(function()
		l.RichText = b.RichText
	end)
	b:GetPropertyChangedSignal("TextTransparency"):Connect(function()
		if b.TextTransparency ~= 1 then
			b.TextTransparency = 1 -- the Label shows the text
		end
	end)
	return l
end

local function stateTint(b: ImageButton, state: string)
	local base = b:GetAttribute(TINT_ATTR)
	local baseRgb = if typeof(base) == "Color3" then toRgb(base) else { 255, 255, 255 }
	local st = Rules.STATE[if b:GetAttribute("SkinDisabled") == true then "disabled" else state] or Rules.STATE.idle
	b.ImageColor3 = c3(Rules.multiply(baseRgb, st.tint))
	b.ImageTransparency = st.alpha
	local t = textHost(b)
	if t then
		t.TextTransparency = st.alpha
	end
end

local function hookStates(b: ImageButton)
	b.MouseEnter:Connect(function()
		stateTint(b, "hover")
	end)
	b.MouseLeave:Connect(function()
		stateTint(b, "idle")
	end)
	b.SelectionGained:Connect(function()
		stateTint(b, "hover")
	end)
	b.SelectionLost:Connect(function()
		stateTint(b, "idle")
	end)
	b.MouseButton1Down:Connect(function()
		stateTint(b, "pressed")
	end)
	b.MouseButton1Up:Connect(function()
		stateTint(b, "hover")
	end)
end

-- Native buttons: hover lifts the face, press collapses the lip (the key goes down), release springs it back.
local function hookNative(b: GuiButton)
	local function hover(on: boolean)
		b:SetAttribute("SkinHover", on and b:GetAttribute("SkinDisabled") ~= true)
		b:SetAttribute("SkinLipNow", nil)
		paintFace(b)
		UiSkin.hoverGlow(b, b:GetAttribute("SkinHover") == true)
	end
	b.SelectionImageObject = UiSkin.focusRing()
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
	b.MouseButton1Down:Connect(function()
		if b:GetAttribute("SkinDisabled") == true then
			return
		end
		b:SetAttribute("SkinLipNow", math.max(0, Sh.pressedLip * scaleOf(b)))
		paintFace(b)
		local at = os.clock()
		b:SetAttribute("SkinDownAt", at)
		task.delay(0.35, function()
			if b:GetAttribute("SkinDownAt") == at and b:GetAttribute("SkinLipNow") ~= nil then
				b:SetAttribute("SkinLipNow", nil)
				paintFace(b)
			end
		end)
	end)
	b.MouseButton1Up:Connect(function()
		b:SetAttribute("SkinLipNow", nil)
		paintFace(b)
	end)
end

-- A drawn icon left of a native button's text.
local function setButtonGlyph(b: GuiButton, glyph: string?)
	local old = b:FindFirstChild("Glyph")
	if old then
		old:Destroy()
	end
	local l = b:FindFirstChild("Label")
	if not glyph or glyph == "" then
		if l and l:IsA("TextLabel") then
			local pad = l:FindFirstChildOfClass("UIPadding")
			if pad then
				pad.PaddingLeft = UDim.new(0.06, 0)
			end
		end
		return
	end
	local g = UiSkin.glyph(b, glyph, {
		name = "Glyph",
		size = UDim2.new(0.62, 0, 0.62, 0),
		position = UDim2.new(0, 8, 0.46, 0),
		anchor = Vector2.new(0, 0.5),
		zIndex = b.ZIndex + 1,
	})
	g.SizeConstraint = Enum.SizeConstraint.RelativeYY
	if l and l:IsA("TextLabel") then
		local pad = l:FindFirstChildOfClass("UIPadding")
		-- Layout px, not AbsoluteSize: under a UIScale (the results card's CardScale) the absolute size is scaled.
		local function fit()
			local _, h = sizeOf(b)
			if pad and b:FindFirstChild("Glyph") then
				pad.PaddingLeft = UDim.new(0, math.floor(h * 0.62 + 12))
			end
		end
		fit()
		b:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	end
end

-- A skinned button. Native: a TextButton (its Text kept, shown by the "Label" child) with the gloss + lip face; with art
-- an ImageButton whose Image is the 9-slice and whose text sits in a "Label" child. Sound + squash via UiSound.bind.
function UiSkin.button(parent: Instance?, slot: string, text: string, opts: Opts?): GuiButton
	local o: Opts = opts or {}
	local img = UiSkin.artFor(slot, o.image)
	local b: GuiButton
	if img then
		local ib = Instance.new("ImageButton")
		ib.AutoButtonColor = false -- the rules' state tints instead
		ib.BackgroundTransparency = 1
		ib:SetAttribute(ART_ATTR, true)
		ib:SetAttribute(S_ATTR, o.S or HudMetrics.S())
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Active = false
		label.Text = text
		label.Parent = ib
		b = ib
	else
		local tb = Instance.new("TextButton")
		tb.AutoButtonColor = false -- hover / press are drawn (lift, lip)
		tb.Text = text
		tb:SetAttribute(S_ATTR, o.S or HudMetrics.S())
		b = tb
	end
	b.Name = o.name or "Button"
	b.BorderSizePixel = 0
	b.Selectable = if o.selectable == nil then true else o.selectable
	applyGeometry(b, o)
	b:SetAttribute(SLOT_ATTR, slot)
	if b:IsA("ImageButton") then
		hookStates(b)
		b:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			local w, h = sizeOf(b)
			b.SliceScale = Rules.sliceScale(slot, (b:GetAttribute(S_ATTR) :: number?) or 1, w, h)
		end)
	else
		ensureLabel(b :: TextButton)
		hookNative(b)
	end
	UiSkin.styleButton(b, o)
	if o.glyph and not img then
		setButtonGlyph(b, o.glyph)
	end
	if o.sound ~= false then
		UiSound.bind(b, if type(o.sound) == "string" then o.sound else "tap")
	end
	b.Parent = parent
	return b
end

local function labelInk(b: GuiObject, variant: string)
	local l = b:FindFirstChild("Label")
	if l and l:IsA("TextLabel") then
		local v = Rules.VARIANT[variant]
		local dark = v and v.text ~= nil
		l.TextColor3 = if dark and v.text then c3(v.text) else WHITE
		local ts = l:FindFirstChildOfClass("UIStroke")
		if ts then
			ts.Enabled = not dark
		end
	end
end

-- Restyles a button made by UiSkin.button (variant / legacy fill, text size, outline). Safe to call every step.
function UiSkin.styleButton(b: GuiButton, opts: Opts?)
	local o: Opts = opts or {}
	local slot = b:GetAttribute(SLOT_ATTR)
	local s = if type(slot) == "string" then slot else "btn_wood"
	local gb = b :: GuiButton
	if o.S then
		b:SetAttribute(S_ATTR, o.S)
	end
	if isArtButton(gb) then
		local ib = b :: any
		applySlice(ib, gb, s, UiSkin.artFor(s, o.image) or ib.Image, if o.image then o.slice else nil)
		gb:SetAttribute(TINT_ATTR, tintOf(s, o))
		stateTint(ib, "idle")
	else
		local role = Rules.roleOf(s)
		if role ~= "tab" then
			role = "button"
		end
		local variant: string
		if o.variant or o.color or b:GetAttribute(VAR_ATTR) == nil then
			variant = variantOf(s, role, o)
		else
			variant = b:GetAttribute(VAR_ATTR) :: string
		end
		if b:GetAttribute("SkinDisabled") == true then
			b:SetAttribute("SkinEnabledVariant", variant)
			variant = "disabled"
		end
		nativeLook(gb, role, variant, o)
		labelInk(gb, variant)
	end
	applyText(b, o)
end

-- Switches a native button to a theme variant (go, sky, orange, danger, disabled, purple, header, tab).
function UiSkin.setVariant(b: GuiButton, variant: string)
	if isArtButton(b) then
		return
	end
	UiSkin.styleButton(b, { variant = variant })
end

function UiSkin.setText(b: GuiObject, text: string)
	if b:IsA("TextButton") then
		b.Text = text -- the Label mirrors it
	end
	local t = textHost(b)
	if t then
		t.Text = text
	end
end

function UiSkin.getText(b: GuiObject): string
	if b:IsA("TextButton") then
		return b.Text
	end
	local t = textHost(b)
	return if t then t.Text else ""
end

-- Greys a button out (native: the disabled variant with faded text; art: the disabled tint) and stops it taking presses
-- (Active / Selectable). Handlers should still check their own state.
function UiSkin.setEnabled(b: GuiButton, on: boolean)
	local was = b:GetAttribute("SkinDisabled") == true
	b.Active = on
	b.Selectable = on
	if isArtButton(b) then
		b:SetAttribute("SkinDisabled", not on)
		b.AutoButtonColor = false
		stateTint(b :: any, "idle")
		return
	end
	b.AutoButtonColor = false
	if on == not was then
		return
	end
	if not on then
		local cur = b:GetAttribute(VAR_ATTR)
		b:SetAttribute("SkinEnabledVariant", if type(cur) == "string" and cur ~= "disabled" then cur else "sky")
		b:SetAttribute("SkinDisabled", true)
		b:SetAttribute("SkinHover", false)
		local role = if b:GetAttribute("SkinRole") == "tab" then "tab" else "button"
		nativeLook(b, role, "disabled", {})
		labelInk(b, "disabled")
	else
		b:SetAttribute("SkinDisabled", false)
		local v = b:GetAttribute("SkinEnabledVariant")
		UiSkin.styleButton(b, { variant = if type(v) == "string" then v else "sky" })
	end
end

-- A tab button: idle = dark navy key, selected = the gold header key with ink text. setTab flips it.
function UiSkin.tab(parent: Instance?, text: string, selected: boolean, opts: Opts?): GuiButton
	local o: Opts = table.clone(opts or {}) :: any
	o.variant = if selected then "header" else "tab"
	o.sound = if o.sound == nil then "tab" else o.sound
	local b = UiSkin.button(parent, "tab_idle", text, o)
	b:SetAttribute("SkinSelected", selected)
	return b
end

function UiSkin.setTab(b: GuiButton, selected: boolean)
	b:SetAttribute("SkinSelected", selected)
	UiSkin.styleButton(b, { variant = if selected then "header" else "tab" })
end

---------------------------------------------------------------------------------------------------- text

export type TextOpts = {
	name: string?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	zIndex: number?,
	layoutOrder: number?,
	color: Color3?,
	textSize: number?, -- fixed size; nil = TextScaled with maxText
	maxText: number?,
	minText: number?,
	align: string?, -- "left" | "center" | "right"
	valign: string?, -- "top" | "center" | "bottom"
	stroke: number?, -- ink stroke px at S = 1 (0 = none)
	S: number?,
	wrap: boolean?,
	rich: boolean?,
	font: string?, -- a UiSkin.font kind
	rotation: number?,
}

local TEXT_KIND = {
	title = { font = "display", stroke = 3 },
	numeral = { font = "display", stroke = 3.5 },
	body = { font = "body", stroke = 2 },
	caption = { font = "bodyHeavy", stroke = 1.5 },
	button = { font = "button", stroke = 2.5 },
}

-- A theme TextLabel: white with the ink stroke in the kind's face (title / numeral: heavy italic display; body / caption:
-- rounded bold).
function UiSkin.text(parent: Instance?, text: string, kind: string?, opts: TextOpts?): TextLabel
	local o: TextOpts = opts or {}
	local k = TEXT_KIND[kind or "body"] or TEXT_KIND.body
	local S = o.S or HudMetrics.S()
	local l = Instance.new("TextLabel")
	l.Name = o.name or "Text"
	l.BackgroundTransparency = 1
	l.Active = false
	l.Text = text
	l.FontFace = UiSkin.font(o.font or k.font)
	l.TextColor3 = o.color or WHITE
	l.RichText = o.rich == true
	l.TextWrapped = o.wrap == true
	l.Size = o.size or UDim2.fromScale(1, 1)
	if o.position then
		l.Position = o.position
	end
	if o.anchor then
		l.AnchorPoint = o.anchor
	end
	if o.zIndex then
		l.ZIndex = o.zIndex
	end
	if o.layoutOrder then
		l.LayoutOrder = o.layoutOrder
	end
	if o.rotation then
		l.Rotation = o.rotation
	end
	l.TextXAlignment = if o.align == "left" then Enum.TextXAlignment.Left elseif o.align == "right" then Enum.TextXAlignment.Right else Enum.TextXAlignment.Center
	l.TextYAlignment = if o.valign == "top" then Enum.TextYAlignment.Top elseif o.valign == "bottom" then Enum.TextYAlignment.Bottom else Enum.TextYAlignment.Center
	if o.textSize then
		l.TextSize = o.textSize
		l.TextScaled = false
	else
		l.TextScaled = true
		local c = Instance.new("UITextSizeConstraint")
		UiSkin.liveCap(c, o.maxText or 40)
		c.MinTextSize = o.minText or 10
		c.Parent = l
	end
	local stroke = if o.stroke ~= nil then o.stroke else k.stroke
	if stroke > 0 then
		inkText(l, S, stroke)
	end
	l.Parent = parent
	return l
end

function UiSkin.title(parent: Instance?, text: string, opts: TextOpts?): TextLabel
	return UiSkin.text(parent, text, "title", opts)
end

function UiSkin.body(parent: Instance?, text: string, opts: TextOpts?): TextLabel
	return UiSkin.text(parent, text, "body", opts)
end

function UiSkin.numeral(parent: Instance?, text: string, opts: TextOpts?): TextLabel
	local o: TextOpts = table.clone(opts or {}) :: any
	o.color = o.color or c3(Rules.GOLD)
	return UiSkin.text(parent, text, "numeral", o)
end

---------------------------------------------------------------------------------------------------- containers

-- A card: the lighter blue gradient with the ink outline; opts.variant tints it; rarity adds a coloured edge strip.
function UiSkin.card(parent: Instance?, opts: Opts?, rarity: string?): Frame
	local f = UiSkin.panel(parent, "card", opts)
	if rarity and Rules.RARITY[rarity] then
		local strip = Instance.new("Frame")
		strip.Name = "RarityStrip"
		strip.BackgroundColor3 = c3(Rules.RARITY[rarity])
		strip.BorderSizePixel = 0
		strip.Size = UDim2.new(1, 0, 0, math.max(4, math.floor(6 * scaleOf(f) + 0.5)))
		strip.Position = UDim2.new(0, 0, 1, 0)
		strip.AnchorPoint = Vector2.new(0, 1)
		strip.ZIndex = f.ZIndex + 1
		local uc = Instance.new("UICorner")
		uc.CornerRadius = UDim.new(0, 4)
		uc.Parent = strip
		strip.Parent = f
	end
	return f
end

-- An inset well (lists, stat blocks inside a panel): #0E1B45 at 55 %.
function UiSkin.inset(parent: Instance?, opts: Opts?): Frame
	local o: Opts = table.clone(opts or {}) :: any
	o.variant = "inset"
	return UiSkin.panel(parent, "inset", o)
end

-- A chip: a small dark pill with an optional drawn icon and a text (progress strip, counters). Returns (frame, label).
function UiSkin.chip(parent: Instance?, text: string, glyph: string?, opts: Opts?): (Frame, TextLabel)
	local o: Opts = table.clone(opts or {}) :: any
	o.variant = o.variant or "inset"
	local f = UiSkin.panel(parent, "chip", o)
	local hasGlyph = glyph ~= nil and glyph ~= ""
	if hasGlyph then
		local g = UiSkin.glyph(f, glyph :: string, {
			name = "Glyph",
			size = UDim2.fromScale(0.78, 0.78),
			position = UDim2.new(0, 4, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			zIndex = f.ZIndex + 1,
		})
		g.SizeConstraint = Enum.SizeConstraint.RelativeYY
	end
	local l = UiSkin.text(f, text, "button", { name = "Label", maxText = o.maxText or 26, zIndex = f.ZIndex + 1, align = if hasGlyph then "left" else "center", S = o.S })
	if hasGlyph then
		local function fit()
			local _, h = sizeOf(f) -- layout px (a UIScale above would inflate AbsoluteSize)
			l.Position = UDim2.new(0, math.floor(h * 0.78 + 10), 0, 0)
			l.Size = UDim2.new(1, -math.floor(h * 0.78 + 18), 1, 0)
		end
		fit()
		f:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	end
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.14, 0)
	pad.PaddingBottom = UDim.new(0.14, 0)
	pad.Parent = l
	return f, l
end

-- A header band: the gold gradient key with slanted heavy ink title text (title bands, selected things).
function UiSkin.header(parent: Instance?, text: string, opts: Opts?): (Frame, TextLabel)
	local o: Opts = table.clone(opts or {}) :: any
	o.variant = o.variant or "header"
	local f = UiSkin.panel(parent, "header", o)
	local v = Rules.VARIANT[o.variant or "header"]
	local dark = v and v.text
	local l = UiSkin.text(f, text, "title", {
		name = "Title",
		maxText = o.maxText or 40,
		zIndex = f.ZIndex + 1,
		color = if dark then c3(dark) else WHITE,
		stroke = if dark then 0 else 3,
		S = o.S,
	})
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.14, 0)
	pad.PaddingBottom = UDim.new(0.1, 0)
	pad.PaddingLeft = UDim.new(0.04, 0)
	pad.PaddingRight = UDim.new(0.04, 0)
	pad.Parent = l
	return f, l
end

-- A start / finish checker strip (course select header, results): two rows of `cells` squares.
function UiSkin.checker(parent: Instance?, opts: { size: UDim2?, position: UDim2?, anchor: Vector2?, cells: number?, zIndex: number?, name: string?, alpha: number? }?): Frame
	local o: any = opts or {}
	local f = Instance.new("Frame")
	f.Name = o.name or "Checker"
	f.BackgroundColor3 = WHITE
	f.BackgroundTransparency = o.alpha or 0
	f.BorderSizePixel = 0
	f.Size = o.size or UDim2.new(1, 0, 0, 16)
	f.Position = o.position or UDim2.new()
	f.AnchorPoint = o.anchor or Vector2.zero
	f.ClipsDescendants = true
	if o.zIndex then
		f.ZIndex = o.zIndex
	end
	local n = o.cells or 24
	for row = 0, 1 do
		for i = 0, n - 1 do
			if (i + row) % 2 == 0 then
				local sq = Instance.new("Frame")
				sq.BorderSizePixel = 0
				sq.BackgroundColor3 = INK
				sq.BackgroundTransparency = o.alpha or 0
				sq.Size = UDim2.new(1 / n, 1, 0.5, 0)
				sq.Position = UDim2.new(i / n, 0, row * 0.5, 0)
				sq.ZIndex = f.ZIndex
				sq.Parent = f
			end
		end
	end
	f.Parent = parent
	return f
end

---------------------------------------------------------------------------------------------------- icons

export type IconOpts = { name: string?, size: UDim2?, position: UDim2?, anchor: Vector2?, color: Color3?, font: Enum.Font?, zIndex: number?, tintArt: boolean?, layoutOrder: number? }

-- Drawn glyphs (the native fallback for the icon slots until the icon set lands): each draws into a square frame from
-- Roblox UI objects, ink-outlined, readable at 16 px. Names: coin, lock, key, trophy, check, star, flag, clock, boss,
-- battle, race, coins, quick, rematch, timetrial, medal_1..3, info, alert, close, gear, play, back, cart, gift.
local function part(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	for k, v in props do
		if k ~= "corner" and k ~= "ink" and k ~= "inkAlpha" then
			(f :: any)[k] = v
		end
	end
	if props.corner then
		local uc = Instance.new("UICorner")
		uc.CornerRadius = if typeof(props.corner) == "UDim" then props.corner else UDim.new(0, props.corner)
		uc.Parent = f
	end
	if props.ink then
		local st = Instance.new("UIStroke")
		st.Color = INK
		st.Thickness = props.ink
		st.Transparency = props.inkAlpha or 0
		st.LineJoinMode = Enum.LineJoinMode.Round
		st.Parent = f
	end
	f.Parent = parent
	return f
end

local GLYPH_COLOR = {
	coin = Rules.GOLD,
	lock = { 255, 214, 90 },
	key = { 255, 214, 90 },
	trophy = { 255, 205, 60 },
	check = { 92, 230, 110 },
	star = Rules.GOLD,
	clock = { 120, 210, 255 },
	boss = { 255, 110, 110 },
	battle = { 255, 150, 60 },
	coins = Rules.GOLD,
	quick = { 120, 210, 255 },
	rematch = { 200, 140, 255 },
	timetrial = { 120, 210, 255 },
	race = { 255, 255, 255 },
	info = { 92, 200, 255 },
	alert = { 255, 190, 50 },
	close = { 255, 100, 100 },
	gear = { 220, 228, 245 },
	play = { 92, 230, 110 },
	back = { 220, 228, 245 },
	gift = { 255, 120, 160 },
	cart = { 255, 181, 46 },
	flag = { 255, 255, 255 },
	plane = { 255, 255, 255 },
	car = { 255, 255, 255 },
}

local function drawGlyph(f: Frame, name: string, color: Color3, z: number)
	local ink = math.max(1.5, f.AbsoluteSize.Y / 16)
	local function P(props: { [string]: any }): Frame
		props.ZIndex = props.ZIndex or z
		props.BackgroundColor3 = props.BackgroundColor3 or color
		return part(f, props)
	end
	local function ring(cx: number, cy: number, d: number, th: number, col: Color3?)
		local r = P({ Size = UDim2.fromScale(d, d), Position = UDim2.fromScale(cx, cy), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, corner = UDim.new(1, 0) })
		local st = Instance.new("UIStroke")
		st.Color = col or color
		st.Thickness = th
		st.Parent = r
		return r
	end
	local medal = string.match(name, "^medal_(%d)$")
	if name == "coin" or name == "coins" then
		P({ Size = UDim2.fromScale(0.9, 0.9), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), ink = ink })
		P({ Size = UDim2.fromScale(0.58, 0.58), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), BackgroundColor3 = color:Lerp(Color3.fromRGB(200, 120, 0), 0.45), ZIndex = z + 1 })
		P({ Size = UDim2.fromScale(0.16, 0.36), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), corner = 2, BackgroundColor3 = color:Lerp(WHITE, 0.55), ZIndex = z + 2 })
		if name == "coins" then
			f:FindFirstChildOfClass("Frame") -- a second coin peeking behind
			P({ Size = UDim2.fromScale(0.62, 0.62), Position = UDim2.fromScale(0.86, 0.2), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), ink = ink, ZIndex = z - 1 })
		end
	elseif medal then
		local p = tonumber(medal) or 1
		local col = c3(Rules.placeColor(p))
		P({ Size = UDim2.fromScale(0.34, 0.4), Position = UDim2.fromScale(0.33, 0), BackgroundColor3 = Color3.fromRGB(230, 60, 60), ink = ink * 0.7, ZIndex = z - 1 })
		P({ Size = UDim2.fromScale(0.34, 0.4), Position = UDim2.fromScale(0.5, 0), BackgroundColor3 = Color3.fromRGB(60, 120, 230), ink = ink * 0.7, ZIndex = z - 1 })
		P({ Size = UDim2.fromScale(0.78, 0.78), Position = UDim2.fromScale(0.5, 0.6), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), BackgroundColor3 = col, ink = ink })
		local t = UiSkin.text(f, tostring(p), "numeral", { size = UDim2.fromScale(0.6, 0.6), position = UDim2.fromScale(0.5, 0.62), anchor = Vector2.new(0.5, 0.5), color = Rules.INK and INK, stroke = 0, zIndex = z + 1, maxText = 60 })
		t.Name = "Num"
	elseif name == "lock" then
		ring(0.5, 0.36, 0.46, ink * 1.6, INK)
		ring(0.5, 0.36, 0.46, ink * 0.9, color:Lerp(WHITE, 0.3))
		P({ Size = UDim2.fromScale(0.74, 0.5), Position = UDim2.fromScale(0.5, 0.92), AnchorPoint = Vector2.new(0.5, 1), corner = 4, ink = ink, ZIndex = z + 1 })
		P({ Size = UDim2.fromScale(0.14, 0.2), Position = UDim2.fromScale(0.5, 0.7), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), BackgroundColor3 = INK, ZIndex = z + 2 })
	elseif name == "key" then
		P({ Size = UDim2.fromScale(0.44, 0.44), Position = UDim2.fromScale(0.3, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), ink = ink })
		P({ Size = UDim2.fromScale(0.16, 0.16), Position = UDim2.fromScale(0.3, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), BackgroundColor3 = INK, ZIndex = z + 1 })
		P({ Size = UDim2.fromScale(0.48, 0.14), Position = UDim2.fromScale(0.48, 0.5), AnchorPoint = Vector2.new(0, 0.5), ink = ink, ZIndex = z - 1 })
		P({ Size = UDim2.fromScale(0.1, 0.2), Position = UDim2.fromScale(0.78, 0.52), ink = ink, ZIndex = z - 1 })
		P({ Size = UDim2.fromScale(0.1, 0.14), Position = UDim2.fromScale(0.62, 0.52), ink = ink, ZIndex = z - 1 })
	elseif name == "trophy" then
		P({ Size = UDim2.fromScale(0.6, 0.46), Position = UDim2.fromScale(0.5, 0.08), AnchorPoint = Vector2.new(0.5, 0), corner = UDim.new(0.4, 0), ink = ink, ZIndex = z + 1 })
		ring(0.22, 0.3, 0.26, ink * 1.2)
		ring(0.78, 0.3, 0.26, ink * 1.2)
		P({ Size = UDim2.fromScale(0.14, 0.24), Position = UDim2.fromScale(0.5, 0.52), AnchorPoint = Vector2.new(0.5, 0), ink = ink })
		P({ Size = UDim2.fromScale(0.5, 0.16), Position = UDim2.fromScale(0.5, 0.94), AnchorPoint = Vector2.new(0.5, 1), corner = 3, ink = ink, ZIndex = z + 1 })
	elseif name == "check" then
		P({ Size = UDim2.fromScale(0.2, 0.42), Position = UDim2.fromScale(0.32, 0.6), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = -45, corner = 3, ink = ink })
		P({ Size = UDim2.fromScale(0.2, 0.78), Position = UDim2.fromScale(0.6, 0.46), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 40, corner = 3, ink = ink })
	elseif name == "close" then
		P({ Size = UDim2.fromScale(0.2, 0.86), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45, corner = 3, ink = ink })
		P({ Size = UDim2.fromScale(0.2, 0.86), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = -45, corner = 3, ink = ink })
	elseif name == "clock" or name == "timetrial" then
		P({ Size = UDim2.fromScale(0.86, 0.86), Position = UDim2.fromScale(0.5, 0.54), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), BackgroundColor3 = WHITE, ink = ink })
		P({ Size = UDim2.fromScale(0.24, 0.12), Position = UDim2.fromScale(0.5, 0.02), AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = color, ink = ink * 0.8 })
		P({ Size = UDim2.fromScale(0.09, 0.32), Position = UDim2.fromScale(0.5, 0.56), AnchorPoint = Vector2.new(0.5, 1), BackgroundColor3 = INK, corner = 2, ZIndex = z + 1 })
		P({ Size = UDim2.fromScale(0.26, 0.09), Position = UDim2.fromScale(0.48, 0.54), AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = color:Lerp(INK, 0.2), corner = 2, Rotation = -30, ZIndex = z + 1 })
	elseif name == "star" or name == "rematch" or name == "quick" then
		local t = UiSkin.text(f, if name == "quick" then "»" elseif name == "rematch" then "↻" else "★", "numeral", { color = color, stroke = 3, zIndex = z, maxText = 200, font = "bodyHeavy" })
		t.Size = UDim2.fromScale(1.15, 1.15)
		t.Position = UDim2.fromScale(0.5, 0.5)
		t.AnchorPoint = Vector2.new(0.5, 0.5)
	elseif name == "flag" or name == "race" then
		P({ Size = UDim2.fromScale(0.1, 0.92), Position = UDim2.fromScale(0.14, 0.04), BackgroundColor3 = Color3.fromRGB(220, 228, 245), ink = ink * 0.8 })
		local cloth = P({ Size = UDim2.fromScale(0.68, 0.5), Position = UDim2.fromScale(0.24, 0.06), BackgroundColor3 = WHITE, ink = ink, ZIndex = z + 1 })
		for r = 0, 2 do
			for c = 0, 3 do
				if (r + c) % 2 == 0 then
					part(cloth, { Size = UDim2.fromScale(0.25, 1 / 3), Position = UDim2.fromScale(c * 0.25, r / 3), BackgroundColor3 = INK, ZIndex = z + 2 })
				end
			end
		end
	elseif name == "boss" then
		P({ Size = UDim2.fromScale(0.82, 0.72), Position = UDim2.fromScale(0.5, 0.44), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(0.45, 0), BackgroundColor3 = WHITE, ink = ink })
		P({ Size = UDim2.fromScale(0.52, 0.3), Position = UDim2.fromScale(0.5, 0.92), AnchorPoint = Vector2.new(0.5, 1), corner = 3, BackgroundColor3 = WHITE, ink = ink, ZIndex = z - 1 })
		P({ Size = UDim2.fromScale(0.22, 0.22), Position = UDim2.fromScale(0.32, 0.46), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), BackgroundColor3 = color, ZIndex = z + 1 })
		P({ Size = UDim2.fromScale(0.22, 0.22), Position = UDim2.fromScale(0.68, 0.46), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), BackgroundColor3 = color, ZIndex = z + 1 })
		for i = 0, 2 do
			P({ Size = UDim2.fromScale(0.06, 0.2), Position = UDim2.fromScale(0.36 + i * 0.14, 0.9), AnchorPoint = Vector2.new(0.5, 1), BackgroundColor3 = INK, ZIndex = z + 1 })
		end
	elseif name == "battle" then
		P({ Size = UDim2.fromScale(0.16, 0.9), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45, corner = 3, BackgroundColor3 = Color3.fromRGB(220, 228, 245), ink = ink })
		P({ Size = UDim2.fromScale(0.16, 0.9), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = -45, corner = 3, BackgroundColor3 = Color3.fromRGB(220, 228, 245), ink = ink })
		P({ Size = UDim2.fromScale(0.42, 0.13), Position = UDim2.fromScale(0.26, 0.72), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = -45, corner = 3, ink = ink, ZIndex = z + 1 })
		P({ Size = UDim2.fromScale(0.42, 0.13), Position = UDim2.fromScale(0.74, 0.72), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45, corner = 3, ink = ink, ZIndex = z + 1 })
	elseif name == "info" or name == "alert" then
		P({ Size = UDim2.fromScale(0.9, 0.9), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), ink = ink })
		local t = UiSkin.text(f, if name == "info" then "i" else "!", "numeral", { color = WHITE, stroke = 2, zIndex = z + 1, maxText = 200 })
		t.Size = UDim2.fromScale(0.8, 0.8)
		t.Position = UDim2.fromScale(0.5, 0.5)
		t.AnchorPoint = Vector2.new(0.5, 0.5)
	elseif name == "gear" then
		for i = 0, 3 do
			P({ Size = UDim2.fromScale(0.2, 0.94), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = i * 45, corner = 3, ink = ink })
		end
		P({ Size = UDim2.fromScale(0.66, 0.66), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), ink = ink, ZIndex = z + 1 })
		P({ Size = UDim2.fromScale(0.26, 0.26), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), BackgroundColor3 = INK, ZIndex = z + 2 })
	elseif name == "play" or name == "back" then
		-- a chevron from two bars
		local flip = if name == "back" then -1 else 1
		P({ Size = UDim2.fromScale(0.62, 0.2), Position = UDim2.fromScale(0.5, 0.33), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 40 * flip, corner = 3, ink = ink })
		P({ Size = UDim2.fromScale(0.62, 0.2), Position = UDim2.fromScale(0.5, 0.67), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = -40 * flip, corner = 3, ink = ink })
	elseif name == "gift" then
		P({ Size = UDim2.fromScale(0.84, 0.56), Position = UDim2.fromScale(0.5, 0.94), AnchorPoint = Vector2.new(0.5, 1), corner = 3, ink = ink })
		P({ Size = UDim2.fromScale(0.94, 0.22), Position = UDim2.fromScale(0.5, 0.3), AnchorPoint = Vector2.new(0.5, 0), corner = 3, ink = ink, ZIndex = z + 1 })
		P({ Size = UDim2.fromScale(0.16, 0.7), Position = UDim2.fromScale(0.5, 0.94), AnchorPoint = Vector2.new(0.5, 1), BackgroundColor3 = c3(Rules.GOLD), ZIndex = z + 2 })
	elseif name == "plane" or name == "car" then
		local t = UiSkin.text(f, if name == "plane" then "✈" else "▶", "numeral", { color = color, stroke = 2, zIndex = z, maxText = 200, font = "bodyHeavy" })
		t.Size = UDim2.fromScale(1.1, 1.1)
		t.Position = UDim2.fromScale(0.5, 0.5)
		t.AnchorPoint = Vector2.new(0.5, 0.5)
	else
		P({ Size = UDim2.fromScale(0.8, 0.8), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), corner = UDim.new(1, 0), ink = ink })
	end
end

-- A drawn glyph (native icon) in a square frame; the art icon "icon_<name>" wins when it is uploaded.
function UiSkin.glyph(parent: Instance?, name: string, opts: IconOpts?): GuiObject
	local o: IconOpts = opts or {}
	local art = UiSkin.artFor("icon_" .. name)
	if art then
		return UiSkin.icon(parent, "icon_" .. name, "", o)
	end
	local f = Instance.new("Frame")
	f.Name = o.name or "Glyph"
	f.BackgroundTransparency = 1
	f.Active = false
	f.Size = o.size or UDim2.fromOffset(24, 24)
	if o.position then
		f.Position = o.position
	end
	if o.anchor then
		f.AnchorPoint = o.anchor
	end
	if o.layoutOrder then
		f.LayoutOrder = o.layoutOrder
	end
	f.ZIndex = o.zIndex or 1
	f:SetAttribute(SLOT_ATTR, "icon_" .. name)
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.Parent = f
	f.Parent = parent
	local col = o.color or c3(GLYPH_COLOR[name] or Rules.WHITE)
	local drawn = false
	local function draw()
		if drawn or f.AbsoluteSize.Y <= 0 then
			return
		end
		drawn = true
		drawGlyph(f, name, col, f.ZIndex)
	end
	if f.AbsoluteSize.Y > 0 then
		draw()
	else
		local conn: RBXScriptConnection
		conn = f:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if f.AbsoluteSize.Y > 0 then
				conn:Disconnect()
				draw()
			end
		end)
		task.defer(function()
			if not drawn and f.Parent then
				drawn = true
				drawGlyph(f, name, col, f.ZIndex)
			end
		end)
	end
	return f
end

-- An icon: an ImageLabel (ScaleType Fit) when the slot has art; else a drawn glyph when the slot names one
-- ("icon_lock" -> glyph "lock"), else a TextLabel showing fallbackGlyph (plain text, never an emoji).
function UiSkin.icon(parent: Instance?, name: string, fallbackGlyph: string, opts: IconOpts?): GuiObject
	local o: IconOpts = opts or {}
	local img = UiSkin.artFor(name)
	local g: GuiObject
	if img then
		local il = Instance.new("ImageLabel")
		il.Image = img
		il.ScaleType = Enum.ScaleType.Fit
		il.BackgroundTransparency = 1
		if o.tintArt and o.color then
			il.ImageColor3 = o.color
		end
		g = il
	else
		local gname = string.match(name, "^icon_(.+)$")
		if gname and GLYPH_COLOR[gname] or (gname and string.match(gname, "^medal_%d$")) then
			return UiSkin.glyph(parent, gname :: string, o)
		end
		local tl = Instance.new("TextLabel")
		tl.Text = fallbackGlyph
		tl.TextScaled = true
		tl.BackgroundTransparency = 1
		tl.FontFace = UiSkin.font("display")
		tl.TextColor3 = o.color or WHITE
		inkText(tl, 1, 2)
		g = tl
	end
	g.Name = o.name or "Icon"
	g.Active = false
	g:SetAttribute(SLOT_ATTR, name)
	if o.size then
		g.Size = o.size
	end
	if o.position then
		g.Position = o.position
	end
	if o.anchor then
		g.AnchorPoint = o.anchor
	end
	if o.zIndex then
		g.ZIndex = o.zIndex
	end
	if o.layoutOrder then
		g.LayoutOrder = o.layoutOrder
	end
	g.Parent = parent
	return g
end

-- An icon slot: a rounded inset square holding an icon (art "icon_<name>" or the drawn glyph).
function UiSkin.iconSlot(parent: Instance?, name: string, opts: Opts?): Frame
	local o: Opts = table.clone(opts or {}) :: any
	o.variant = o.variant or "inset"
	local f = UiSkin.panel(parent, "chip", o)
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.Parent = f
	UiSkin.glyph(f, name, { name = "Glyph", size = UDim2.fromScale(0.72, 0.72), position = UDim2.fromScale(0.5, 0.5), anchor = Vector2.new(0.5, 0.5), zIndex = f.ZIndex + 1 })
	return f
end

---------------------------------------------------------------------------------------------------- tween redirects

-- Where a colour / alpha write should land: (object, colour property, transparency property). The art when it shows,
-- the frame's own background otherwise. Use it to redirect an existing BackgroundColor3 / BackgroundTransparency tween.
function UiSkin.tweenTarget(g: GuiObject): (GuiObject, string, string)
	if isArtButton(g) then
		return g, "ImageColor3", "ImageTransparency"
	end
	local art = artChild(g)
	if art and art.Visible then
		return art, "ImageColor3", "ImageTransparency"
	end
	return g, "BackgroundColor3", "BackgroundTransparency"
end

local function slotOf(g: GuiObject): string
	local s = g:GetAttribute(SLOT_ATTR)
	return if type(s) == "string" then s else ""
end

-- The colour a fill should show: the colour itself natively, the slot's tint of it on the art.
local function shownColor(g: GuiObject, prop: string, color: Color3): Color3
	if prop == "ImageColor3" then
		return c3(Rules.artTint(slotOf(g), toRgb(color)))
	end
	return color
end

-- Sets a skinned object's fill: natively the legacy colour is classified into the theme variant for the object's role
-- (so wood / green / brass callers keep their meaning in the new look); on art the slot's tint of it.
function UiSkin.retint(g: GuiObject, color: Color3)
	if isArtButton(g) then
		g:SetAttribute(TINT_ATTR, shownColor(g, "ImageColor3", color))
		stateTint(g :: any, "idle")
		return
	end
	local target, colorProp = UiSkin.tweenTarget(g)
	if colorProp == "ImageColor3" then
		g.BackgroundColor3 = color; -- remembered for a later fallback / read-back
		(target :: any)[colorProp] = shownColor(g, colorProp, color)
		return
	end
	local slot = slotOf(g)
	local role = g:GetAttribute("SkinRole")
	if type(role) ~= "string" then
		g.BackgroundColor3 = color
		return
	end
	if g:IsA("GuiButton") then
		if g:GetAttribute("SkinDisabled") == true then
			return
		end
		UiSkin.styleButton(g :: GuiButton, { color = color })
		return
	end
	local baseRole = Rules.roleOf(slot)
	nativeLook(g, baseRole, Rules.variantFor(slot, toRgb(color), baseRole), {})
end

-- Sets a skinned object's transparency: natively the fill, outline and text together; ImageTransparency on the art.
function UiSkin.setAlpha(g: GuiObject, alpha: number)
	local target, _, alphaProp = UiSkin.tweenTarget(g)
	if alphaProp == "BackgroundTransparency" and g:GetAttribute("SkinRole") ~= nil then
		applyAlpha(g, alpha)
		return
	end
	(target :: any)[alphaProp] = alpha
end

-- Tweens a skinned object's fill colour and / or transparency on whichever object shows it. Returns the playing tween.
function UiSkin.tween(g: GuiObject, info: TweenInfo, goal: { color: Color3?, alpha: number? }): Tween
	local target, colorProp, alphaProp = UiSkin.tweenTarget(g)
	local props: { [string]: any } = {}
	if goal.color then
		props[colorProp] = shownColor(g, colorProp, goal.color)
	end
	if goal.alpha then
		props[alphaProp] = goal.alpha
		if alphaProp == "BackgroundTransparency" then
			g:SetAttribute(ALPHA_ATTR, goal.alpha)
		end
	end
	local tw = TweenService:Create(target, info, props)
	tw:Play()
	return tw
end

return UiSkin
