--!strict
-- Notification kit (economy v3 phase 3b): the ONE place toasts, persistent banners, modal popups and world arch labels are drawn.
-- Rules (queue, priority, dedupe, layout) are shared/NotifyRules; look is shared/NotifySkin (one skin per kind, optional image
-- fields for the owner's UI art); copy is shared/NotifySpec (fromSpec). Logic never reads a colour or an asset id.
--   toast(text, opts)           lane B caption, queued by priority; opts: key, kind, priority, seconds, color, sound, gate (a HudPhase
--                               name: dropped while the phase hides it, as RaceUI's captions always were), rect (override, e.g. the
--                               Garage plank), tag (dismissTag clears every toast with it)
--   banner(key, text, opts) / clearBanner(key)   persistent line under lane B (the notice-stack row); opts.action =
--                               { label, onActivated } adds one button at the line's right end (the portal lobby's LEAVE)
--   modal(key, spec) / closeModal()   centre card; spec: title, body, primary, close, kind, icon, onPrimary, onClose, sound
--   archLabel(adornee, text, kind)    BillboardGui on a portal arch; returns {setText, setKind, setState, destroy}; setState
--                               ("open" / "filling" / "racing") applies NotifySkin.ARCH_STATES: kind, glow light, rim pulse
--   fromSpec(id, vars, extra)   look up shared/NotifySpec and dispatch to the surface above
-- TrackFlow.toast, RaceUI.showBanner and the Garage toast are thin wrappers over toast().
-- Layout: HudMetrics rects (laneB / hubLaneB, noticeStack, safe-area metrics) through NotifyRules; ScreenGui sits above the Garage
-- (26) and Settings (30), under the controls hint (40). Gamepad: the modal takes selection and B closes it.
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HudLayoutRules = require(Shared:WaitForChild("HudLayoutRules"))
local NotifyRules = require(Shared:WaitForChild("NotifyRules"))
local NotifySkin = require(Shared:WaitForChild("NotifySkin"))
local NotifySpec = require(Shared:WaitForChild("NotifySpec"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))
local HudPhase = require(script.Parent:WaitForChild("HudPhase"))
local UiSound = require(script.Parent:WaitForChild("UiSound"))
local PayoffSound = require(script.Parent:WaitForChild("PayoffSound"))

local LocalPlayer = Players.LocalPlayer

local NotifyKit = {}

local UI_SOUNDS = { unlock = true, confirm = true, back = true, deny = true, purchase = true }
local BACK_ACTION = "NotifyKitModalBack"

local toasts = NotifyRules.newToasts()
local banners = NotifyRules.newBanners()
local modals = NotifyRules.newModals()

local gui: ScreenGui? = nil
local hubProbe: (() -> boolean)? = nil -- TrackFlow: is the ADVENTURE bar up (toast lane stops short of it)

type Panel = { frame: Frame, bar: Frame, icon: TextLabel, iconImage: ImageLabel, label: TextLabel, rim: UIStroke, corner: UICorner, bg: ImageLabel, scale: UIScale }
local toastPanel: Panel? = nil
local bannerPanel: Panel? = nil
local shownToastGen = -1
local shownBannerKey = ""

type ModalUi = { scrim: Frame, card: Frame, bg: ImageLabel, rim: UIStroke, corner: UICorner, icon: TextLabel, iconImage: ImageLabel, title: TextLabel, body: TextLabel, primary: TextButton, close: TextButton }
local modalUi: ModalUi? = nil
local shownModalGen = -1
local modalPrevSelection: GuiObject? = nil

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function fontOf(name: string): Enum.Font
	local ok, f = pcall(function()
		return (Enum.Font :: any)[name]
	end)
	return if ok and f then f else Enum.Font.GothamBold
end

local function addCorner(p: Instance): UICorner
	local c = Instance.new("UICorner")
	c.Parent = p
	return c
end

local function addRim(p: Instance): UIStroke
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = p
	return s
end

-- Optional 9-slice art behind a panel: shown only when the skin names an image.
local function makeBg(parent: Instance): ImageLabel
	local bg = Instance.new("ImageLabel")
	bg.Name = "SkinArt"
	bg.BackgroundTransparency = 1
	bg.Size = UDim2.fromScale(1, 1)
	bg.ZIndex = 0
	bg.ScaleType = Enum.ScaleType.Slice
	bg.Visible = false
	bg.Active = false
	bg.Parent = parent
	return bg
end

local function applyArt(bg: ImageLabel, skin: NotifySkin.Skin)
	local img = skin.panel.image
	bg.Visible = img ~= nil and img ~= ""
	if bg.Visible then
		bg.Image = img :: string
		local s = skin.panel.slice
		if s then
			bg.SliceCenter = Rect.new(s[1], s[2], s[3], s[4])
		end
	end
end

local function applyIcon(glyph: TextLabel, image: ImageLabel, skin: NotifySkin.Skin, override: string?)
	local img = override or skin.icon.image
	image.Visible = img ~= nil and img ~= ""
	glyph.Visible = not image.Visible
	if image.Visible then
		image.Image = img :: string
	else
		glyph.Text = skin.icon.glyph
		glyph.TextColor3 = rgb(skin.accent)
	end
end

local function ensureGui(): ScreenGui
	if gui and gui.Parent then
		return gui
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "NotifyKit"
	sg.DisplayOrder = 31 -- over the Garage (26), Settings (30) and TrackFlow (20); under the controls hint (40)
	sg.IgnoreGuiInset = true
	sg.ResetOnSpawn = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		sg.ScreenInsets = Enum.ScreenInsets.None
		sg.ClipToDeviceSafeArea = false
	end)
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	gui = sg
	return sg
end

-- A one-line panel: accent bar, icon slot, text. Used for the toast and the banner.
local function makePanel(name: string): Panel
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.Visible = false
	f.Active = false
	f.Parent = ensureGui()
	local c = addCorner(f)
	local rim = addRim(f)
	local bg = makeBg(f)
	local bar = Instance.new("Frame")
	bar.Name = "Accent"
	bar.BorderSizePixel = 0
	bar.Active = false
	bar.Parent = f
	local icon = Instance.new("TextLabel")
	icon.Name = "IconGlyph"
	icon.BackgroundTransparency = 1
	icon.TextScaled = true
	icon.Active = false
	icon.Parent = f
	local iconImage = Instance.new("ImageLabel")
	iconImage.Name = "IconImage"
	iconImage.BackgroundTransparency = 1
	iconImage.Visible = false
	iconImage.Parent = f
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Active = false
	label.Parent = f
	local lim = Instance.new("UITextSizeConstraint")
	lim.MinTextSize = HudLayoutRules.MIN_TEXT
	lim.Parent = label
	local sc = Instance.new("UIScale")
	sc.Parent = f
	return { frame = f, bar = bar, icon = icon, iconImage = iconImage, label = label, rim = rim, corner = c, bg = bg, scale = sc }
end

-- Skin and size a panel for a rect. Position and size come from the caller's rect; everything inside scales from it.
local function styleLine(p: Panel, surface: string, kind: string?, text: string, textColor: Color3?, r: NotifyRules.Rect, iconOverride: string?)
	local skin = NotifySkin.get(kind)
	local sh = NotifySkin.SURFACES[surface]
	local S = HudMetrics.S()
	local pad = HudLayoutRules.px(sh.pad, S)
	local f = p.frame
	f.Position = UDim2.fromOffset(math.floor(r.x), math.floor(r.y))
	f.Size = UDim2.fromOffset(math.floor(r.w), math.floor(r.h))
	f.BackgroundColor3 = rgb(skin.panel.color)
	f.BackgroundTransparency = skin.panel.alpha
	p.corner.CornerRadius = UDim.new(0, HudLayoutRules.px(sh.corner, S))
	p.rim.Color = rgb(skin.accent)
	p.rim.Thickness = skin.rimWidth
	applyArt(p.bg, skin)
	local barW = HudLayoutRules.px(sh.accentBar, S)
	p.bar.BackgroundColor3 = rgb(skin.accent)
	p.bar.Size = UDim2.new(0, barW, 1, -2 * pad // 2)
	p.bar.Position = UDim2.new(0, pad // 2, 0.5, 0)
	p.bar.AnchorPoint = Vector2.new(0, 0.5)
	p.bar.Visible = barW > 0
	local iconPx = math.min(HudLayoutRules.px(skin.icon.size, S), math.floor(r.h) - pad)
	local x = pad // 2 + barW + pad
	p.icon.Font = fontOf(skin.font)
	for _, o in { p.icon :: GuiObject, p.iconImage :: GuiObject } do
		o.AnchorPoint = Vector2.new(0, 0.5)
		o.Position = UDim2.new(0, x, 0.5, 0)
		o.Size = UDim2.fromOffset(iconPx, iconPx)
	end
	applyIcon(p.icon, p.iconImage, skin, iconOverride)
	x += iconPx + pad
	p.label.Font = fontOf(skin.font)
	p.label.Position = UDim2.new(0, x, 0, 2)
	p.label.Size = UDim2.new(1, -(x + pad), 1, -4)
	p.label.Text = text
	p.label.TextColor3 = textColor or rgb(skin.text)
	local lim = p.label:FindFirstChildOfClass("UITextSizeConstraint")
	if lim then
		lim.MaxTextSize = HudLayoutRules.textSize(sh.textBase, S)
	end
end

local function pop(p: Panel)
	p.scale.Scale = 0.9
	TweenService:Create(p.scale, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function playSound(name: string?)
	if not name then
		return
	end
	if UI_SOUNDS[name] then
		UiSound.play(name, nil, nil, false)
	else
		PayoffSound.play(name, nil, 0.6)
	end
end

local function hubUp(): boolean
	local probe = hubProbe
	return probe ~= nil and probe()
end

-- Toast ---------------------------------------------------------------------------------------------------------------

function NotifyKit.setHubProbe(fn: () -> boolean)
	hubProbe = fn
end

export type ToastOpts = {
	key: string?, kind: string?, priority: any?, seconds: number?, color: Color3?, sound: string?, gate: string?,
	rect: NotifyRules.Rect?, tag: string?, icon: string?,
}

function NotifyKit.toast(text: string, opts: ToastOpts?): string
	NotifyKit.init()
	local o: ToastOpts = opts or {}
	if o.gate and not HudPhase.allows(o.gate) then
		return "gated"
	end
	local res = NotifyRules.push(toasts, {
		key = o.key,
		text = text,
		priority = o.priority,
		seconds = o.seconds,
		kind = o.kind,
		opts = o,
	}, os.clock())
	NotifyKit.step()
	return res
end

function NotifyKit.dismissTag(tag: string)
	local keep = {}
	for _, n in toasts.queue do
		if not (n.opts and n.opts.tag == tag) then
			table.insert(keep, n)
		end
	end
	toasts.queue = keep
	local act = toasts.active
	if act and act.opts and act.opts.tag == tag then
		toasts.active = nil
		toasts.gen += 1
	end
	NotifyKit.step()
end

local function stepToast()
	local act = NotifyRules.tick(toasts, os.clock())
	if not act and not toastPanel then
		shownToastGen = toasts.gen
		return
	end
	if not toastPanel then
		toastPanel = makePanel("NotifyToast")
	end
	local p = toastPanel :: Panel
	-- A caption whose phase gate closed while it was up goes with the gate (the last lap chip into the podium).
	if act and act.opts and act.opts.gate and not HudPhase.allows(act.opts.gate) then
		toasts.active = nil
		toasts.gen += 1
		act = NotifyRules.tick(toasts, os.clock())
	end
	if not act then
		p.frame.Visible = false
		shownToastGen = toasts.gen
		return
	end
	local o = act.opts or {}
	local rects = HudMetrics.rects()
	local r = NotifyRules.toastRect(rects, hubUp(), o.rect)
	local fresh = shownToastGen ~= toasts.gen
	-- Text is restyled every step (cheap, and the rect follows rotation / the hub bar); the pop and the sound play once per toast.
	styleLine(p, "toast", act.kind or "info", act.text, o.color, r, o.icon)
	if fresh then
		shownToastGen = toasts.gen
		p.frame.Visible = true
		pop(p)
		playSound(o.sound)
	end
end

-- Banner --------------------------------------------------------------------------------------------------------------

export type BannerAction = { label: string, onActivated: () -> () }
export type BannerOpts = { kind: string?, priority: any?, color: Color3?, gate: string?, icon: string?, action: BannerAction? }

-- The banner's one optional button (economy v3 phase 3: LEAVE on "Waiting for racers"), skinned like a modal primary.
local bannerButton: TextButton? = nil
local bannerAction: BannerAction? = nil

local function ensureBannerButton(p: Panel): TextButton
	local b = bannerButton
	if b and b.Parent then
		return b
	end
	local nb = Instance.new("TextButton")
	nb.Name = "Action"
	nb.AutoButtonColor = true
	nb.BorderSizePixel = 0
	nb.Selectable = true
	nb.TextScaled = true
	nb.AnchorPoint = Vector2.new(1, 0.5)
	nb.Parent = p.frame
	addCorner(nb)
	UiSound.bind(nb, "back")
	local lim = Instance.new("UITextSizeConstraint")
	lim.MinTextSize = HudLayoutRules.MIN_TEXT
	lim.Parent = nb
	nb.Activated:Connect(function()
		local a = bannerAction
		if a then
			a.onActivated()
		end
	end)
	bannerButton = nb
	return nb
end

function NotifyKit.banner(key: string, text: string, opts: BannerOpts?)
	NotifyKit.init()
	local o: BannerOpts = opts or {}
	NotifyRules.setBanner(banners, key, text, o.priority, o.kind, o)
	NotifyKit.step()
end

function NotifyKit.clearBanner(key: string)
	if NotifyRules.clearBanner(banners, key) then
		NotifyKit.step()
	end
end

local function stepBanner()
	local top = NotifyRules.topBanner(banners)
	if not top and not bannerPanel then
		return
	end
	if not bannerPanel then
		bannerPanel = makePanel("NotifyBanner")
	end
	local p = bannerPanel :: Panel
	if top and top.opts and top.opts.gate and not HudPhase.allows(top.opts.gate) then
		top = nil
	end
	if not top then
		p.frame.Visible = false
		shownBannerKey = ""
		return
	end
	local o = top.opts or {}
	local r = NotifyRules.bannerRect(HudMetrics.rects(), hubUp())
	styleLine(p, "banner", top.kind or "info", top.text, o.color, r, o.icon)
	local action = o.action :: BannerAction?
	bannerAction = action
	if action then
		-- A button at the right end, as tall as the line allows and never under 44 px wide (touch target); the text
		-- stops short of it.
		local skin = NotifySkin.get(top.kind or "info")
		local S = HudMetrics.S()
		local pad = HudLayoutRules.px(NotifySkin.SURFACES.banner.pad, S)
		local bh = math.max(24, math.floor(r.h) - pad)
		local bw = math.max(44, math.floor(bh * 2.4))
		local b = ensureBannerButton(p)
		b.Text = action.label
		b.Font = fontOf(skin.font)
		b.BackgroundColor3 = rgb(skin.primary)
		b.TextColor3 = rgb(skin.primaryText)
		b.Size = UDim2.fromOffset(bw, bh)
		b.Position = UDim2.new(1, -pad // 2, 0.5, 0)
		b.Visible = true
		local lsz = p.label.Size
		p.label.Size = UDim2.new(lsz.X.Scale, lsz.X.Offset - bw - pad, lsz.Y.Scale, lsz.Y.Offset)
	elseif bannerButton then
		(bannerButton :: TextButton).Visible = false
	end
	if not p.frame.Visible or shownBannerKey ~= top.key then
		p.frame.Visible = true
		pop(p)
	end
	shownBannerKey = top.key
end

-- Modal ---------------------------------------------------------------------------------------------------------------

local function makeLabel(parent: Instance, name: string): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.Active = false
	l.Parent = parent
	return l
end

local function makeButton(parent: Instance, name: string, uiSound: string): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AutoButtonColor = true
	b.BorderSizePixel = 0
	b.Selectable = true
	b.Parent = parent
	addCorner(b)
	UiSound.bind(b, uiSound)
	return b
end

local function closeCurrent(viaPrimary: boolean)
	local cur = modals.current
	if not cur then
		return
	end
	local spec = cur.spec
	local nextModal = NotifyRules.closeModal(modals)
	local cb = if viaPrimary then spec.onPrimary else spec.onClose
	if cb then
		task.spawn(cb)
	end
	if not nextModal then
		ContextActionService:UnbindAction(BACK_ACTION)
		local prev = modalPrevSelection
		modalPrevSelection = nil
		if prev and prev.Parent then
			GuiService.SelectedObject = prev
		elseif GuiService.SelectedObject and modalUi and GuiService.SelectedObject:IsDescendantOf(modalUi.scrim) then
			GuiService.SelectedObject = nil
		end
	end
	NotifyKit.step()
end

local function ensureModalUi(): ModalUi
	if modalUi then
		return modalUi
	end
	local scrim = Instance.new("Frame")
	scrim.Name = "NotifyModal"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 0.45
	scrim.BorderSizePixel = 0
	scrim.Active = true -- sinks taps so nothing behind the card is pressed
	scrim.Visible = false
	scrim.Parent = ensureGui()
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.BorderSizePixel = 0
	card.Parent = scrim
	local corner = addCorner(card)
	local rim = addRim(card)
	local bg = makeBg(card)
	local icon = Instance.new("TextLabel")
	icon.Name = "IconGlyph"
	icon.BackgroundTransparency = 1
	icon.TextScaled = true
	icon.Parent = card
	local iconImage = Instance.new("ImageLabel")
	iconImage.Name = "IconImage"
	iconImage.BackgroundTransparency = 1
	iconImage.Visible = false
	iconImage.Parent = card
	local title = makeLabel(card, "Title")
	title.TextWrapped = false
	title.TextYAlignment = Enum.TextYAlignment.Center
	local body = makeLabel(card, "Body")
	body.TextScaled = true
	local bl = Instance.new("UITextSizeConstraint")
	bl.MinTextSize = HudLayoutRules.MIN_TEXT
	bl.Parent = body
	local primary = makeButton(card, "Primary", "confirm")
	local close = makeButton(card, "Close", "back")
	local ui: ModalUi = { scrim = scrim, card = card, bg = bg, rim = rim, corner = corner, icon = icon, iconImage = iconImage, title = title, body = body, primary = primary, close = close }
	modalUi = ui
	primary.Activated:Connect(function()
		closeCurrent(true)
	end)
	close.Activated:Connect(function()
		closeCurrent(false)
	end)
	return ui
end

local function layoutModal(ui: ModalUi, spec: any)
	local snap = HudMetrics.get()
	local vp = snap.viewport
	local hasClose = type(spec.close) == "string"
	local skin = NotifySkin.get(spec.kind)
	-- spec.fit: size the card to its body text (login popup) instead of the fixed card height.
	local bodyNeed: number? = nil
	if spec.fit == true then
		local S = snap.metrics.S
		local pad = math.max(10, math.floor(16 * S + 0.5))
		local wide = math.min(snap.metrics.xr - snap.metrics.x0, math.max(280, math.floor(520 * S + 0.5)))
		local ok, size = pcall(function(): Vector2
			return TextService:GetTextSize(tostring(spec.body or ""), NotifyRules.bodySizeFor(S), fontOf(skin.font), Vector2.new(wide - 2 * pad, 10000))
		end)
		if ok then
			bodyNeed = size.Y
		end
	end
	local L = NotifyRules.modalLayout(vp.X, vp.Y, snap.metrics, hasClose, bodyNeed)
	local c = L.card
	ui.card.Position = UDim2.fromOffset(c.x, c.y)
	ui.card.Size = UDim2.fromOffset(c.w, c.h)
	ui.card.BackgroundColor3 = rgb(skin.panel.color)
	ui.card.BackgroundTransparency = skin.panel.alpha
	ui.corner.CornerRadius = UDim.new(0, HudLayoutRules.px(NotifySkin.SURFACES.modal.corner, snap.metrics.S))
	-- spec.accent ({r, g, b}): a per-popup accent (the month's theme colour) over the kind's rim, title and button colours.
	local accent = if type(spec.accent) == "table" then rgb(spec.accent) else rgb(skin.accent)
	ui.rim.Color = accent
	ui.rim.Thickness = skin.rimWidth + 1
	applyArt(ui.bg, skin)
	local font = fontOf(skin.font)
	local ix = L.pad
	for _, o in { ui.icon :: GuiObject, ui.iconImage :: GuiObject } do
		o.Position = UDim2.fromOffset(ix, L.pad)
		o.Size = UDim2.fromOffset(L.iconSize, L.iconSize)
	end
	ui.icon.Font = font
	applyIcon(ui.icon, ui.iconImage, skin, spec.icon)
	local tx = ix + L.iconSize + L.pad
	ui.title.Font = font
	ui.title.Text = tostring(spec.title or "")
	ui.title.TextColor3 = if type(spec.accent) == "table" then accent else rgb(skin.title)
	ui.title.TextSize = L.titleSize
	ui.title.Position = UDim2.fromOffset(tx, L.pad)
	ui.title.Size = UDim2.fromOffset(c.w - tx - L.pad, math.max(L.titleH, L.iconSize))
	ui.body.Font = font
	ui.body.Text = tostring(spec.body or "")
	ui.body.TextColor3 = rgb(skin.text)
	local bodyY = L.pad + math.max(L.titleH, L.iconSize) + 4
	ui.body.Position = UDim2.fromOffset(L.pad, bodyY)
	ui.body.Size = UDim2.fromOffset(c.w - 2 * L.pad, math.max(0, c.h - bodyY - L.pad - L.buttonH - L.pad // 2))
	local bl = ui.body:FindFirstChildOfClass("UITextSizeConstraint")
	if bl then
		bl.MaxTextSize = L.bodySize
	end
	local function place(b: TextButton, r: NotifyRules.Rect, text: string, fill: Color3, textColor: Color3)
		b.Position = UDim2.fromOffset(r.x - c.x, r.y - c.y)
		b.Size = UDim2.fromOffset(r.w, r.h)
		b.Text = text
		b.Font = font
		b.TextSize = L.buttonSize
		b.BackgroundColor3 = fill
		b.TextColor3 = textColor
	end
	place(ui.primary, L.buttons.primary, tostring(spec.primary or "OK"), if type(spec.accent) == "table" then accent else rgb(skin.primary), rgb(skin.primaryText))
	ui.close.Visible = hasClose and L.buttons.close ~= nil
	if hasClose and L.buttons.close then
		place(ui.close, L.buttons.close, spec.close, Color3.fromRGB(60, 64, 72), rgb(skin.text))
	end
end

-- spec.anim = "storm" (the storm race popup): the card drops in with a Back ease and a lightning flash (a white
-- overlay that blinks twice and fades) runs over it. UI only, nothing in the world; the card is centred, never over the
-- vehicle's lane beyond the modal scrim every popup has.
local function animateModal(ui: ModalUi, anim: any)
	if anim ~= "storm" then
		return
	end
	local scale = ui.card:FindFirstChild("AnimScale") :: UIScale?
	if not scale then
		local made = Instance.new("UIScale")
		made.Name = "AnimScale"
		made.Parent = ui.card
		scale = made
	end
	local sc = scale :: UIScale
	sc.Scale = 0.55
	TweenService:Create(sc, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	local flash = ui.card:FindFirstChild("AnimFlash") :: Frame?
	if not flash then
		local f = Instance.new("Frame")
		f.Name = "AnimFlash"
		f.Size = UDim2.fromScale(1, 1)
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.fromRGB(225, 225, 255)
		f.ZIndex = 50
		f.Active = false
		f.Parent = ui.card
		addCorner(f)
		flash = f
	end
	local fl = flash :: Frame
	fl.BackgroundTransparency = 0.15
	fl.Visible = true
	local t1 = TweenService:Create(fl, TweenInfo.new(0.12), { BackgroundTransparency = 0.85 })
	t1.Completed:Connect(function()
		fl.BackgroundTransparency = 0.35
		local t2 = TweenService:Create(fl, TweenInfo.new(0.5), { BackgroundTransparency = 1 })
		t2.Completed:Connect(function()
			fl.Visible = false
		end)
		t2:Play()
	end)
	t1:Play()
end

local function stepModal()
	local cur = modals.current
	if not cur and not modalUi then
		shownModalGen = modals.gen
		return
	end
	local ui = ensureModalUi()
	if not cur then
		ui.scrim.Visible = false
		shownModalGen = modals.gen
		return
	end
	layoutModal(ui, cur.spec)
	if shownModalGen ~= modals.gen then
		shownModalGen = modals.gen
		ui.scrim.Visible = true
		playSound(cur.spec.sound)
		animateModal(ui, cur.spec.anim)
		-- Gamepad: take selection (remember what had it), and B closes when there is a close button.
		local sel = GuiService.SelectedObject
		if sel and not sel:IsDescendantOf(ui.scrim) then
			modalPrevSelection = sel
		end
		if UserInputService.GamepadEnabled or GuiService:IsTenFootInterface() then
			GuiService.SelectedObject = ui.primary
		end
		ContextActionService:BindActionAtPriority(BACK_ACTION, function(_, state)
			if state == Enum.UserInputState.Begin and type(cur.spec.close) == "string" then
				closeCurrent(false)
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 10, Enum.KeyCode.ButtonB)
	end
end

function NotifyKit.modal(key: string, spec: {
	title: string?, body: string?, primary: string?, close: string?, kind: string?, icon: string?, sound: string?,
	accent: { number }?, fit: boolean?, priority: any?, onPrimary: (() -> ())?, onClose: (() -> ())?, anim: string?,
}): string
	NotifyKit.init()
	local res = NotifyRules.pushModal(modals, key, spec, spec.priority)
	NotifyKit.step()
	return res
end

-- Live text for the open card (a countdown): changes the body of the modal that has this key; the next step redraws it.
function NotifyKit.setModalBody(key: string, body: string)
	local cur = modals.current
	if cur and cur.key == key then
		cur.spec.body = body
	end
end

function NotifyKit.closeModal()
	closeCurrent(false)
end

-- Closes the open card only when it is this key's (a timed popup whose window ended: the storm race JOIN); a copy still
-- waiting in the queue behind another card goes too, so it never shows after its window.
function NotifyKit.closeModalIf(key: string)
	for i = #modals.queue, 1, -1 do
		if modals.queue[i].key == key then
			table.remove(modals.queue, i)
		end
	end
	local cur = modals.current
	if cur and cur.key == key then
		closeCurrent(false)
	end
end

function NotifyKit.modalOpen(): boolean
	return modals.current ~= nil
end

-- Arch label (world) --------------------------------------------------------------------------------------------------

type ArchHandle = { setText: (string) -> (), setKind: (string) -> (), setState: (string) -> (), destroy: () -> () }
type ArchEntry = { label: TextLabel, bar: Frame, panel: Frame, rim: UIStroke, adornee: BasePart, pulse: number, rimBase: number, light: PointLight? }
local archLabels: { [BillboardGui]: ArchEntry } = {}
local archClock = 0

local function archStyle(entry: ArchEntry, kind: string)
	local skin = NotifySkin.get(kind)
	entry.panel.BackgroundColor3 = rgb(skin.panel.color)
	entry.panel.BackgroundTransparency = skin.panel.alpha
	entry.rim.Color = rgb(skin.accent)
	entry.rim.Thickness = skin.rimWidth
	entry.rimBase = skin.rimWidth
	entry.bar.BackgroundColor3 = rgb(skin.accent)
	entry.label.Font = fontOf(skin.font)
	entry.label.TextColor3 = rgb(skin.text)
end

-- A label hung over a portal arch, sized by camera distance with the same rule the battle labels use (WorldLabelRules, arch factor).
function NotifyKit.archLabel(adornee: BasePart, text: string, kind: string?, offsetStuds: number?): ArchHandle
	local bb = Instance.new("BillboardGui")
	bb.Name = "NotifyArchLabel"
	bb.Adornee = adornee
	bb.AlwaysOnTop = false
	bb.LightInfluence = 0
	bb.MaxDistance = 400
	bb.StudsOffsetWorldSpace = Vector3.new(0, offsetStuds or 0, 0)
	bb.Size = UDim2.fromOffset(NotifyRules.archLabelSize(0, 1))
	bb.Parent = adornee
	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromScale(1, 1)
	panel.BorderSizePixel = 0
	panel.Parent = bb
	local corner = addCorner(panel)
	corner.CornerRadius = UDim.new(0, NotifySkin.SURFACES.arch.corner)
	local rim = addRim(panel)
	local bar = Instance.new("Frame")
	bar.BorderSizePixel = 0
	bar.Size = UDim2.new(1, -12, 0, 3)
	bar.Position = UDim2.new(0, 6, 1, -6)
	bar.Parent = panel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -12, 1, -10)
	label.Position = UDim2.fromOffset(6, 3)
	label.TextScaled = true
	label.TextWrapped = true
	label.Text = text
	label.Parent = panel
	local lim = Instance.new("UITextSizeConstraint")
	lim.MinTextSize = HudLayoutRules.MIN_TEXT
	lim.MaxTextSize = NotifySkin.SURFACES.arch.textBase
	lim.Parent = label
	local entry: ArchEntry = { label = label, bar = bar, panel = panel, rim = rim, adornee = adornee, pulse = 0, rimBase = 2, light = nil }
	archStyle(entry, kind or "portal")
	archLabels[bb] = entry
	return {
		setText = function(t: string)
			label.Text = t
		end,
		setKind = function(k: string)
			archStyle(entry, k)
		end,
		-- The arch's queue state (economy v3 phase 3): the state's kind, a soft glow light on the adornee in the kind's
		-- accent (a light, never a mesh in front of the camera) and an optional rim pulse.
		setState = function(state: string)
			local st = NotifySkin.archState(state)
			archStyle(entry, st.kind)
			entry.pulse = st.pulse
			local light = entry.light
			if not light then
				local nl = Instance.new("PointLight")
				nl.Name = "NotifyArchGlow"
				nl.Shadows = false
				nl.Parent = adornee
				entry.light = nl
				light = nl
			end
			local l = light :: PointLight
			l.Color = rgb(NotifySkin.get(st.kind).accent)
			l.Brightness = st.glow
			l.Range = st.range
			l.Enabled = st.glow > 0
		end,
		destroy = function()
			archLabels[bb] = nil
			if entry.light then
				(entry.light :: PointLight):Destroy()
			end
			bb:Destroy()
		end,
	}
end

local function stepArch()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local S = HudMetrics.S()
	for bb, e in archLabels do
		if not bb.Parent then
			archLabels[bb] = nil
		else
			local d = (cam.CFrame.Position - e.adornee.Position).Magnitude
			local w, h = NotifyRules.archLabelSize(d, S)
			bb.Size = UDim2.fromOffset(w, h)
			if e.pulse > 0 then
				e.rim.Thickness = e.rimBase + e.pulse * (1 + math.sin(os.clock() * 4)) -- FILLING breathes
			end
		end
	end
end

-- Spec dispatch -------------------------------------------------------------------------------------------------------

-- extra: overrides for onPrimary / onClose / rect / color, and `key` (default: the row id).
function NotifyKit.fromSpec(id: string, vars: { [string]: any }?, extra: any?): string
	local row = NotifySpec.get(id)
	if not row then
		warn("[NotifyKit] unknown spec row " .. id)
		return "unknown"
	end
	local x = extra or {}
	local text = NotifySpec.format(row.copy, vars)
	local key = x.key or row.id
	if row.surface == "toast" then
		return NotifyKit.toast(text, { key = key, kind = row.kind, priority = row.priority, seconds = row.seconds, sound = row.sound, color = x.color, rect = x.rect, gate = x.gate })
	elseif row.surface == "banner" then
		-- A banner row's title leads its line ("Waiting for racers 0:14 - 3/8"); extra.action adds its button.
		local line = if row.title then NotifySpec.format(row.title, vars) .. " " .. text else text
		NotifyKit.banner(key, line, { kind = row.kind, priority = row.priority, color = x.color, gate = x.gate, action = x.action })
		return "shown"
	elseif row.surface == "modal" then
		return NotifyKit.modal(key, {
			title = if row.title then NotifySpec.format(row.title, vars) else nil,
			body = text,
			primary = row.primary,
			close = row.close,
			kind = row.kind,
			priority = row.priority,
			sound = row.sound,
			accent = x.accent,
			fit = x.fit,
			onPrimary = x.onPrimary,
			onClose = x.onClose,
		})
	end
	return "arch" -- arch rows are drawn by the portal code through archLabel (it owns the adornee)
end

-- Per-frame driver ----------------------------------------------------------------------------------------------------

function NotifyKit.step()
	stepToast()
	stepBanner()
	stepModal()
end

local started = false
function NotifyKit.init()
	if started then
		return
	end
	started = true
	HudMetrics.onChanged(function()
		NotifyKit.step()
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		archClock += 1
		NotifyKit.step()
		if archClock % 2 == 0 then
			stepArch()
		end
	end)
end

return NotifyKit
