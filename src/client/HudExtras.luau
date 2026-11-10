--!strict
-- HUD extras (TEST_LIST_LAUNCH L07, L26, L28; ART_BAR UI polish; HUD layout v2, docs/design/HUD_LAYOUT.md): the held-item
-- frame, the Sky Token chip with its award moment, the save-error banner, non-modal notices (disconnect/reconnect, lobby
-- timeout, the L30 DNF countdown "Finish in 32 s or DNF" from workspace DnfAt while this racer is still flying), the
-- RESPAWN control (trap audit G5: a way out from anywhere, in every mode) and the touch AUTO pill. v2 look: small rounded
-- wood chips with outlined numerals (principle 7), no plank art; every rectangle comes from client/HudMetrics
-- (shared/HudLayoutRules), so nothing here keeps a size table of its own. Icons use the owned item textures and VfxAssets.
-- Nothing here blocks input except the two buttons (Active=false everywhere else): an error is a banner, never a modal.
-- The HUD only displays: tokens come from SaveService's replicated attributes (SkyTokens, SaveState, SaveMessage),
-- the item from the server's ItemState events (via ItemClient). Nothing here awards or decides anything.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Prof = require(Shared:WaitForChild("Prof")) -- MicroProfiler labels (perf review v21 PF-10)
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local HudLayoutRules = require(Shared:WaitForChild("HudLayoutRules"))
local ItemTexAssets = require(Shared:WaitForChild("ItemTexAssets")) :: { [string]: string }
local Progression = require(Shared:WaitForChild("Progression"))
local VfxAssets = require(Shared:WaitForChild("VfxAssets"))
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules")) -- the DNF countdown line (L30)
local Sfx = require(script.Parent:WaitForChild("Sfx"))
local HudMetrics = require(script.Parent:WaitForChild("HudMetrics"))
local HudPhase = require(script.Parent:WaitForChild("HudPhase"))
-- L27: the first item balloon pickup earns the "how to fire" tip (client/Onboarding decides whether it shows).
local Onboarding = require(script.Parent:WaitForChild("Onboarding"))

local LocalPlayer = Players.LocalPlayer

local HudExtras = {}

export type Skin = {
	creamText: Color3,
	darkInk: Color3,
	toast: ((msg: string, color: Color3?, duration: number?, always: boolean?) -> ())?,
}

-- The layout is a HudMetrics snapshot (viewport, insets, nav, kind, scale, every rect).
export type Layout = HudMetrics.Snapshot

export type Tone = "error" | "info" | "ok"

local GOLD = Color3.fromRGB(255, 214, 90)
local EMPTY_GEM = Color3.fromRGB(96, 82, 70)
local TONE_STROKE: { [string]: Color3 } = {
	error = Color3.fromRGB(232, 96, 64),
	info = Color3.fromRGB(224, 190, 120),
	ok = Color3.fromRGB(140, 220, 110),
}
local KEY_GLYPH: { [string]: string } = { keyboard = "F", gamepad = "X" } -- keyed by InputMode.showGlyphs()
local RESPAWN_GLYPH: { [string]: string } = { keyboard = "BKSP", gamepad = "VIEW" }
local RETURN_GLYPH: { [string]: string } = { keyboard = "ENTER", gamepad = "Y" } -- FlightController's SkyRallyCourseReturn binds
-- Item id -> ItemTexAssets icon and glyph (ItemRules.ICON: the classic pairing the pods and the mystery cube use, and
-- items v4's in-engine icons, "icon art pending" in docs/design/ITEMS_V4.md).
local CHIP_WOOD = Color3.fromRGB(96, 60, 34)
local CHIP_SAND = Color3.fromRGB(188, 168, 142)
local CHIP_OFF = Color3.fromRGB(70, 62, 56) -- ASSIST OFF: dimmed wood
local CHIP_TEXT_ON = Color3.fromRGB(250, 242, 222)
local CHIP_OFF_TEXT = Color3.fromRGB(190, 176, 156)
local CHIP_ALPHA = 0.12 -- chip background transparency (principle 7); v21: 0.35 read grey and weak over a busy tunnel, now 88 percent opaque
local RESPAWN_BG = Color3.fromRGB(52, 32, 18) -- the respawn chip is darker and more opaque than the other chips: it must read over bright sky
local RESPAWN_ALPHA = 0.1
local RESPAWN_IDLE = 0.65 -- touch: share of full opacity while not offered (was 0.35)
local COIN_MIN = 22 -- the token coin icon is never smaller than this (px)
local COIN_GOLD = Color3.fromRGB(255, 200, 56)
local COIN_RIM = Color3.fromRGB(150, 92, 14)
local TOKEN_IDLE_T = 0.04 -- the token chip idles at 88 percent alpha until it changes (was 70: the count was faint over bright sky)
local SPINNER_DOTS = 8

local function tex(name: string): string
	local e = (VfxAssets :: any)[name]
	return if e then e.id else ""
end

local function rgb(t: { number }?): Color3
	if not t then
		return EMPTY_GEM
	end
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function corner(parent: Instance, radius: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number, border: boolean): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	if border then
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	end
	s.Parent = parent
	return s
end

local function scaleOf(obj: GuiObject): UIScale
	local existing = obj:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	local s = Instance.new("UIScale")
	s.Parent = obj
	return s
end

local function punch(obj: GuiObject, peak: number, seconds: number)
	local s = scaleOf(obj)
	s.Scale = peak
	TweenService:Create(s, TweenInfo.new(seconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function label(parent: Instance, name: string, skin: Skin): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBlack
	t.TextColor3 = skin.creamText
	t.Active = false
	t.Parent = parent
	stroke(t, skin.darkInk, 1.8, false)
	return t
end

-- GothamBlack caps run wider than the plaque columns at some scales ("MISSILE" ~57 px at 12 px in a 50 px column at
-- 740x360): scale down to fit, never past the layout's size and never below a readable floor.
local function fitText(t: TextLabel, maxSize: number)
	t.TextScaled = true
	local limit: UITextSizeConstraint
	local existing = t:FindFirstChildOfClass("UITextSizeConstraint")
	if existing then
		limit = existing
	else
		limit = Instance.new("UITextSizeConstraint")
		limit.Parent = t
	end
	limit.MinTextSize = math.min(9, maxSize)
	limit.MaxTextSize = maxSize
end

------------------------------------------------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------------------------------------------------

local skin: Skin? = nil
local root: Frame? = nil
local current: Layout? = nil

-- item frame
local slot: Frame? = nil
local gem: Frame? = nil
local gemIcon: ImageLabel? = nil
local gemCaption: TextLabel? = nil -- "ITEM" on an empty slot (v21: an empty grey disc read as a dead widget)
local gemGlyph: TextLabel? = nil -- items v4: the special's glyph (ItemRules.ICON), corner badge or the whole icon
local gemFlash: Frame? = nil
local fireRing: ImageLabel? = nil
local pips: { Frame } = {}
local keyBadge: Frame? = nil
local keyText: TextLabel? = nil
local heldColor: string? = nil
local heldLevel = 0
local heldCharges: number? = nil -- items v4: shots or gifts left in a charged item (the pips show these)
local lastFiredAt = -math.huge
local rouletteToken = 0 -- bumps on every setItem, so a newer state ends a spin in progress
local rollingUntil = 0 -- os.clock() when the current roulette lands (0: none)

-- tokens
local tokenPlaque: Frame? = nil
local tokenStar: ImageLabel? = nil
local tokenCoin: Frame? = nil -- the solid gold disc behind the star
local tokenText: TextLabel? = nil
local tokenStroke: UIStroke? = nil
local tokensKnown: number? = nil
local tokensShown = 0
local countUpFrom = 0
local countUpTo = 0
local countUpStart = 0
local COUNT_UP_SECONDS = 0.6
local tokenAlphaToken = 0

-- respawn control (G5): an icon button on touch, a key-hint chip on desktop / gamepad
local respawnBtn: TextButton? = nil
local respawnWipe: Frame? = nil
local respawnPress: (() -> ())? = nil
local respawnStatus: (() -> (boolean, number, boolean))? = nil
local respawnOffered = false
local respawnPulse = 0
local respawnAlpha = 0.65 -- touch: RESPAWN_IDLE until offered, then a 3 s fade-in to full
local respawnIsTouch = true

-- RETURN to course (planes off course, docs/design/FLIGHT_GUIDE.md 4.3)
local returnBtn: TextButton? = nil
local returnPress: (() -> ())? = nil
local returnStatus: (() -> (boolean, number))? = nil
local returnAlpha = 0
local returnPulse = 0
local returnFailSeen = 0

-- ASSIST pill / chip (touch pill, desktop chip): the one-tap ASSIST switch in countdown and race
local autoPill: TextButton? = nil
local assistPlaced = false -- the layout has a rect for it (race layouts only)
local assistHandler: ((on: boolean) -> ())? = nil

-- notices
local noticeStack: Frame? = nil
type Notice = { frame: Frame, text: TextLabel, spinner: Frame, dots: { Frame }, token: number }
local notices: { [string]: Notice } = {}
local noticeOrder = 0
local saveHadError = false
local loadingToken = 0

------------------------------------------------------------------------------------------------------------------------
-- Item slot
------------------------------------------------------------------------------------------------------------------------

local function refreshKeyBadge()
	local badge, text = keyBadge, keyText
	if not badge or not text then
		return
	end
	-- Key badges ONLY after a real keyboard or gamepad input (InputMode.showGlyphs): never on a phone or its emulator.
	local mode = LocalPlayer:GetAttribute("GlyphMode")
	local glyph = if type(mode) == "string" then KEY_GLYPH[mode] else nil
	badge.Visible = glyph ~= nil
	text.Text = glyph or ""
end

-- The gem backs the icon: item colour, or a faint grey disc while empty (no caption text at all).
local function paintGem(color: string?)
	local g, icon = gem, gemIcon
	if not g or not icon then
		return
	end
	if gemCaption then
		gemCaption.Visible = color == nil
	end
	local glyph = gemGlyph
	if color then
		local ic = ItemRules.iconOf(color)
		local tex = if ic then ItemTexAssets[ic.tex] else nil
		g.BackgroundColor3 = rgb(ItemRules.colorRgb(color))
		g.BackgroundTransparency = 0
		icon.Image = tex or ""
		icon.Visible = tex ~= nil
		if glyph then
			local mark = if ic then ic.glyph else ""
			glyph.Text = mark
			glyph.Visible = mark ~= ""
			-- No texture: the glyph is the whole icon, centred and big; else a badge in the lower right.
			glyph.Position = if tex then UDim2.fromScale(0.74, 0.74) else UDim2.fromScale(0.5, 0.5)
			glyph.Size = if tex then UDim2.fromScale(0.5, 0.38) else UDim2.fromScale(0.8, 0.62)
		end
	else
		g.BackgroundColor3 = EMPTY_GEM
		g.BackgroundTransparency = 0.35
		icon.Visible = false
		if glyph then
			glyph.Visible = false
		end
	end
end

local function paintSlot()
	local color = heldColor
	paintGem(color)
	-- Items v4: a charged item's pips count what is left in it (orbiters, gifts), up to the three pips there are.
	local lit = if heldCharges then math.min(heldCharges, #pips) else heldLevel
	for i, pip in ipairs(pips) do
		pip.Visible = color ~= nil
		pip.BackgroundColor3 = if i <= lit then GOLD else Color3.fromRGB(70, 52, 38)
		pip.BackgroundTransparency = if i <= lit then 0 else 0.3
	end
end

local function flashGem(color: Color3)
	local f = gemFlash
	if not f then
		return
	end
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 0.05
	TweenService:Create(f, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
end

-- Mystery cube roulette (ItemRules.rouletteFrames): the gem and its icon flick through the item colours with a tick,
-- slowing down, then land on the rolled item. The pips stay dark until the reveal. A newer state cancels the spin.
local function spinRoulette(final: string, seconds: number)
	rouletteToken += 1
	local token = rouletteToken
	local g, icon = gem, gemIcon
	if not g or not icon then
		return
	end
	for _, pip in ipairs(pips) do
		pip.Visible = false
	end
	-- Items v4: the spin walks this race's pool (RaceAttr ItemPool), so it only flashes what the race can give.
	local poolText = RaceAttr.mine(ItemRules.ROTATION.poolAttribute)
	local pool = if type(poolText) == "string" and poolText ~= "" then ItemRules.parsePool(poolText) else nil
	local frames = ItemRules.rouletteFrames(seconds, final :: ItemRules.Color, math.random(0, 4), pool)
	rollingUntil = os.clock() + seconds
	task.spawn(function()
		local start = os.clock()
		for i, f in frames do
			local wait = f.t - (os.clock() - start)
			if wait > 0 then
				task.wait(wait)
			end
			if token ~= rouletteToken then
				return
			end
			if i == #frames then
				rollingUntil = 0
			end
			if i == #frames then
				break
			end
			paintGem(f.color)
			Sfx.play("vote_pip", 1 + 0.5 * (i / #frames), 0.5)
		end
		paintSlot()
		Sfx.play("pod_pickup", 1.1, 0.7)
		local s = slot
		if s then
			punch(s, 1.22, 0.24)
		end
		punch(g, 1.4, 0.28)
		flashGem(Color3.new(1, 1, 1))
	end)
end

-- From the server's ItemState. Animates pickup (new/replace), upgrade (a pip pops) and the empty state. roulette: a
-- fresh mystery roll; the slot spins that many seconds before showing what it is (the server holds the use as long).
function HudExtras.setItem(color: string?, level: number, roulette: number?, charges: number?)
	local newColor = if color and ItemRules.isColor(color) then color else nil
	local newLevel = if newColor then math.clamp(math.floor(level), 1, ItemRules.MAX_LEVEL) else 0
	local prevColor, prevLevel = heldColor, heldLevel
	local prevCharges = heldCharges
	heldCharges = if newColor and type(charges) == "number" and charges > 0 then math.floor(charges) else nil
	-- Cubes v3: a second cube during the spin (ItemRules.cubeTake) keeps the spin going; the reveal paints the new
	-- level's pips (spinRoulette ends on paintSlot). A small gold kick says the cube counted without revealing the item.
	if ItemRules.rouletteQueued(HudExtras.itemRolling(), prevColor, newColor, roulette) then
		heldLevel = newLevel
		local s = slot
		if s and newLevel > prevLevel then
			punch(s, 1.1, 0.16)
			flashGem(GOLD)
			Sfx.play("vote_pip", 1.8, 0.6)
		end
		return
	end
	heldColor, heldLevel = newColor, newLevel
	rouletteToken += 1
	rollingUntil = 0
	paintSlot()
	if newColor and newColor ~= prevColor then
		Onboarding.event("item")
	end
	local s, g = slot, gem
	if not s or not g then
		return
	end
	if newColor and type(roulette) == "number" and roulette > 0 then
		punch(s, 1.12, 0.2)
		spinRoulette(newColor, math.min(roulette, 3))
	elseif newColor and newColor ~= prevColor then
		punch(s, 1.22, 0.24)
		punch(g, 1.35, 0.26)
		flashGem(Color3.new(1, 1, 1))
	elseif newColor and newLevel > prevLevel then
		punch(g, 1.2, 0.2)
		local pip = pips[newLevel]
		if pip then
			punch(pip, 1.9, 0.22)
		end
		flashGem(GOLD)
	elseif newColor and heldCharges and prevCharges and heldCharges < prevCharges then
		-- Items v4: one charge spent (a press or an orbiter that took a hit); the item stays.
		punch(g, 0.86, 0.16)
	elseif not newColor and prevColor and os.clock() - lastFiredAt > 0.4 then
		-- Emptied without a fire (race reset, battle switch): a quiet shrink, not the fire burst.
		punch(g, 0.7, 0.18)
	end
end

-- True while the item slot's roulette is still spinning (the touch ITEM button keeps its neutral look meanwhile).
-- The race is over while the results card is up: the held-item slot has nothing to show and, at phone size, sat under the
-- photo-finish polaroid's caption. RaceUI calls this every frame with the card's visibility.
function HudExtras.setResultsShown(shown: boolean)
	local s = slot
	if s then
		-- Item bugs audit: the hub has mystery cube rows, so the slot shows there too, but only while an item is held or
		-- rolling (the hub HUD stays clean otherwise). Hidden there before, a hub pickup filled an invisible slot.
		local hubEmpty = heldColor == nil and RaceAttr.mine("RaceMode") == "hub"
		local want = not shown and not hubEmpty and s:GetAttribute("PhaseHudOn") ~= false -- HudPhase: hidden on the podium too
		if s.Visible ~= want then
			s.Visible = want
		end
	end
end

-- The held item (ItemRules colour or nil) and its level: the touch ITEM stone mirrors them (RaceUI).
function HudExtras.held(): (string?, number)
	return heldColor, heldLevel
end

function HudExtras.itemRolling(): boolean
	return rollingUntil > 0 and os.clock() < rollingUntil
end

-- A capped pickup (ItemRules.pickupNotice "<ITEM> MAXED"): the gem and its full pips flash gold, so the cube visibly
-- went somewhere.
function HudExtras.itemMaxed()
	local g = gem
	if not g or not heldColor then
		return
	end
	punch(g, 1.25, 0.22)
	for _, pip in ipairs(pips) do
		punch(pip, 1.6, 0.2)
	end
	flashGem(GOLD)
end

-- Seconds the roulette still spins (0 when it is not spinning); FlightController holds an early fire press this long.
function HudExtras.rollLeft(): number
	if rollingUntil <= 0 then
		return 0
	end
	return math.max(0, rollingUntil - os.clock())
end

-- From the server's ItemUsed: the slot kicks and a ring of the item's colour leaves the gem.
function HudExtras.itemFired(color: string?)
	lastFiredAt = os.clock()
	local s, g, ring = slot, gem, fireRing
	if not s or not g or not ring then
		return
	end
	local c = rgb(ItemRules.colorRgb(color))
	punch(s, 0.86, 0.16)
	flashGem(c)
	ring.ImageColor3 = c
	ring.ImageTransparency = 0.05
	ring.Size = UDim2.fromScale(0.9, 0.9)
	local info = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ring, info, { Size = UDim2.fromScale(2.6, 2.6), ImageTransparency = 1 }):Play()
end

local function buildItemSlot(parent: Frame, sk: Skin)
	local frame = Instance.new("Frame")
	frame.Name = "ItemSlot"
	frame.BackgroundColor3 = CHIP_WOOD
	frame.BackgroundTransparency = CHIP_ALPHA
	frame.BorderSizePixel = 0
	frame.Active = false
	frame.Parent = parent
	corner(frame, UDim.new(0, 12))
	stroke(frame, CHIP_SAND, 2, true)
	slot = frame

	local g = Instance.new("Frame")
	g.Name = "ItemGem"
	g.AnchorPoint = Vector2.new(0.5, 0.5)
	g.Position = UDim2.fromScale(0.5, 0.45)
	g.Size = UDim2.fromScale(0.72, 0.72) -- the roulette / icon takes 80 percent of the frame with its rim
	g.BorderSizePixel = 0
	g.Parent = frame
	corner(g, UDim.new(0.5, 0))
	stroke(g, sk.darkInk, 2, true)
	local icon = Instance.new("ImageLabel")
	icon.Name = "ItemIcon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.74, 0.74)
	icon.BackgroundTransparency = 1
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 2
	icon.Active = false
	icon.Visible = false
	icon.Parent = g
	gemIcon = icon
	local cap = Instance.new("TextLabel")
	cap.Name = "EmptyCaption"
	cap.AnchorPoint = Vector2.new(0.5, 0.5)
	cap.Position = UDim2.fromScale(0.5, 0.5)
	cap.Size = UDim2.fromScale(0.9, 0.34)
	cap.BackgroundTransparency = 1
	cap.Font = Enum.Font.GothamBlack
	cap.Text = "ITEM"
	cap.TextScaled = true
	cap.TextColor3 = Color3.fromRGB(236, 224, 200)
	cap.ZIndex = 2
	cap.Active = false
	cap.Parent = g
	stroke(cap, sk.darkInk, 1.6, false)
	gemCaption = cap
	local glyph = Instance.new("TextLabel")
	glyph.Name = "ItemGlyph"
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.74, 0.74)
	glyph.Size = UDim2.fromScale(0.5, 0.38)
	glyph.BackgroundTransparency = 1
	glyph.Font = Enum.Font.GothamBlack
	glyph.Text = ""
	glyph.TextScaled = true
	glyph.TextColor3 = Color3.new(1, 1, 1)
	glyph.ZIndex = 3
	glyph.Active = false
	glyph.Visible = false
	glyph.Parent = g
	stroke(glyph, sk.darkInk, 1.6, false)
	gemGlyph = glyph
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.AnchorPoint = Vector2.new(0.5, 0.5)
	shine.Position = UDim2.fromScale(0.3, 0.28)
	shine.Size = UDim2.fromScale(0.22, 0.22)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.5
	shine.BorderSizePixel = 0
	shine.ZIndex = 3
	shine.Parent = g
	corner(shine, UDim.new(0.5, 0))
	gem = g

	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.ZIndex = 4
	flash.Parent = g
	corner(flash, UDim.new(0.5, 0))
	gemFlash = flash

	local ring = Instance.new("ImageLabel")
	ring.Name = "FireRing"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(0.9, 0.9)
	ring.BackgroundTransparency = 1
	ring.Image = tex("shockwave_ring")
	ring.ImageTransparency = 1
	ring.ZIndex = 5
	ring.Parent = g
	fireRing = ring

	local row = Instance.new("Frame")
	row.Name = "LevelPips"
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.9)
	row.BackgroundTransparency = 1
	row.Parent = frame
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = row
	for i = 1, ItemRules.MAX_LEVEL do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. i
		pip.LayoutOrder = i
		pip.BorderSizePixel = 0
		pip.Parent = row
		corner(pip, UDim.new(0.5, 0))
		stroke(pip, sk.darkInk, 1.2, true)
		table.insert(pips, pip)
	end

	-- The key glyph rides the frame's bottom-right corner, only after a real keyboard / gamepad input.
	local badge = Instance.new("Frame")
	badge.Name = "KeyBadge"
	badge.AnchorPoint = Vector2.new(1, 1)
	badge.Position = UDim2.new(1, 3, 1, 3)
	badge.BackgroundColor3 = Color3.fromRGB(46, 34, 26)
	badge.BorderSizePixel = 0
	badge.ZIndex = 6
	badge.Active = false
	badge.Parent = frame
	corner(badge, UDim.new(0.25, 0))
	stroke(badge, sk.creamText, 1.5, true)
	local kt = label(badge, "Key", sk)
	kt.Size = UDim2.fromScale(1, 1)
	kt.ZIndex = 7
	keyBadge, keyText = badge, kt

	paintSlot()
	refreshKeyBadge()
	LocalPlayer:GetAttributeChangedSignal("GlyphMode"):Connect(refreshKeyBadge)
end

------------------------------------------------------------------------------------------------------------------------
-- RESPAWN control (trap audit G5, X-06) and the touch AUTO pill
------------------------------------------------------------------------------------------------------------------------
-- Touch: a 48 px circular-arrow icon button above the TURN / ITEM stones' right end, at 35 percent alpha until the stuck
-- watchdog offers it, then a 3 s fade-in. Desktop / gamepad: a tiny "[BKSP] RESPAWN" hint chip shown only when useful (the
-- offer, or while the cooldown runs). Display only: a press calls the handler RaceUI installs
-- (FlightController.requestManualRespawn, the car's while one is bound), which decides; the status function says whether
-- to show it, how much cooldown is left (a dark wipe draining downward) and whether the stuck watchdog offers it (the
-- control pulses gold and a one-line hint appears).

local function respawnGlyph(): string?
	local mode = LocalPlayer:GetAttribute("GlyphMode")
	return if type(mode) == "string" then RESPAWN_GLYPH[mode] else nil
end

local function refreshRespawnLabel()
	local b = respawnBtn
	if not b then
		return
	end
	if respawnIsTouch then
		b.Text = "R" -- plain letter: no dependence on a font having the circular-arrow glyph (the keyboard hint names the key)
	else
		local glyph = respawnGlyph()
		b.Text = if glyph then string.format("[%s] RESPAWN", glyph) else "RESPAWN"
	end
end

local function buildRespawnButton(parent: Frame, sk: Skin)
	local b = Instance.new("TextButton")
	b.Name = "RespawnButton"
	b.BackgroundColor3 = RESPAWN_BG
	b.BackgroundTransparency = RESPAWN_ALPHA
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamBlack
	b.TextColor3 = sk.creamText
	b.TextScaled = true
	b.Selectable = false
	b.Visible = false
	b.ZIndex = 3
	b.Parent = parent
	corner(b, UDim.new(0, 10))
	stroke(b, CHIP_SAND, 2, true)
	stroke(b, sk.darkInk, 2.4, false) -- the text outline
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 3)
	pad.PaddingBottom = UDim.new(0, 3)
	pad.Parent = b
	respawnBtn = b

	local wipe = Instance.new("Frame")
	wipe.Name = "Cooldown"
	wipe.AnchorPoint = Vector2.new(0.5, 1)
	wipe.Position = UDim2.fromScale(0.5, 1)
	wipe.Size = UDim2.fromScale(1, 0)
	wipe.BackgroundColor3 = Color3.fromRGB(28, 20, 16)
	wipe.BackgroundTransparency = 0.35
	wipe.BorderSizePixel = 0
	wipe.ZIndex = 5
	wipe.Active = false
	wipe.Parent = b
	corner(wipe, UDim.new(0, 10))
	respawnWipe = wipe

	b.Activated:Connect(function()
		local press = respawnPress
		if press then
			punch(b, 0.9, 0.18)
			press()
		end
	end)
	refreshRespawnLabel()
	LocalPlayer:GetAttributeChangedSignal("GlyphMode"):Connect(refreshRespawnLabel)
end

-- RaceUI wires the button: onPress asks for the respawn, status() -> (shown, cooldown fraction 0..1, offered).
function HudExtras.setRespawnHandler(onPress: () -> (), status: () -> (boolean, number, boolean))
	respawnPress = onPress
	respawnStatus = status
end

local function stepRespawn(dt: number)
	local b, wipe = respawnBtn, respawnWipe
	local status = respawnStatus
	if not b or not wipe or not status then
		return
	end
	local shown, cooldown, offered = status()
	local phaseOn = b:GetAttribute("PhaseHudOn") ~= false
	-- Desktop / gamepad: the hint chip is only useful during an offer or a cooldown (and when a glyph is known).
	local useful = respawnIsTouch or offered or cooldown > 0
	b.Visible = shown and phaseOn and useful
	if not shown then
		respawnOffered = false
		return
	end
	wipe.Size = UDim2.fromScale(1, math.clamp(cooldown, 0, 1))
	-- Touch alpha: 35 percent idle, a 3 s fade-in once offered, back down quickly after.
	local target = if offered then 1 else RESPAWN_IDLE
	if respawnAlpha < target then
		respawnAlpha = math.min(target, respawnAlpha + dt * (0.65 / 3))
	else
		respawnAlpha = math.max(target, respawnAlpha - dt * 2)
	end
	local alpha = if respawnIsTouch then respawnAlpha else 1
	b.BackgroundTransparency = 1 - (1 - RESPAWN_ALPHA) * alpha
	b.TextTransparency = 1 - alpha
	-- Stuck watchdog offer: a gold pulse and, once per offer, a hint naming the control to use.
	if offered then
		respawnPulse += dt
		b.BackgroundColor3 = RESPAWN_BG:Lerp(GOLD, 0.35 + 0.35 * math.sin(respawnPulse * 9))
		scaleOf(b).Scale = 1 + 0.08 * math.abs(math.sin(respawnPulse * 4.5))
		if not respawnOffered then
			respawnOffered = true
			local mode = LocalPlayer:GetAttribute("GlyphMode")
			local how = if mode == "gamepad" then "press VIEW" elseif mode == "keyboard" then "press BACKSPACE" else "tap the respawn button"
			HudExtras.showNotice("stuck", "Stuck? " .. how .. " to get back on track", "info", false, 3)
		end
	else
		if respawnOffered then
			respawnOffered = false
			respawnPulse = 0
			b.BackgroundColor3 = RESPAWN_BG
			scaleOf(b).Scale = 1
			HudExtras.hideNotice("stuck")
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- RETURN to course (docs/design/FLIGHT_GUIDE.md 4.3)
------------------------------------------------------------------------------------------------------------------------
-- A pill left of RESPAWN, in the same chip style as RESPAWN (v22), pulsing gold, shown only while FlightController offers RETURN (Free driving, 2 s off course), with
-- a 0.2 s fade in and a soft pulse. No off-course caption (FLIGHT_GUIDE.md 12: no slowdown to explain, and the
-- default mode never says anything). Display only: the press calls the handler RaceUI installs
-- (FlightController.requestCourseReturn), and the server decides.

local function refreshReturnLabel()
	local b = returnBtn
	if not b then
		return
	end
	local mode = LocalPlayer:GetAttribute("GlyphMode")
	local glyph = if respawnIsTouch or type(mode) ~= "string" then nil else RETURN_GLYPH[mode]
	b.Text = if glyph then string.format("[%s] RETURN", glyph) else "RETURN"
end

local function buildReturnButton(parent: Frame, sk: Skin)
	local b = Instance.new("TextButton")
	b.Name = "ReturnButton"
	b.BackgroundColor3 = RESPAWN_BG -- v22: the same chip as RESPAWN (backing, stroke, opacity)
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamBlack
	b.TextColor3 = sk.creamText
	b.TextTransparency = 1
	b.TextScaled = true
	b.Selectable = false
	b.Visible = false
	b.ZIndex = 3
	b.Parent = parent
	corner(b, UDim.new(0, 10))
	stroke(b, CHIP_SAND, 2, true)
	stroke(b, sk.darkInk, 2.4, false)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = b
	returnBtn = b
	b.Activated:Connect(function()
		local press = returnPress
		if press then
			punch(b, 0.9, 0.18)
			press()
		end
	end)
	refreshReturnLabel()
	LocalPlayer:GetAttributeChangedSignal("GlyphMode"):Connect(refreshReturnLabel)
end

-- RaceUI wires RETURN: onPress asks for it, status() -> (offered, failure counter).
function HudExtras.setReturnHandler(onPress: () -> (), status: () -> (boolean, number))
	returnPress = onPress
	returnStatus = status
end

local function stepReturn(dt: number)
	local b = returnBtn
	local status = returnStatus
	if not b or not status then
		return
	end
	local offered, failSeq = status()
	offered = offered and b:GetAttribute("PhaseHudOn") ~= false
	-- A refused / unanswered press: say so for a moment.
	if failSeq ~= returnFailSeen then
		returnFailSeen = failSeq
		HudExtras.showNotice("offcourse", "Couldn't return, try RESPAWN", "info", false, 2.5)
	end
	returnAlpha = if offered then math.min(1, returnAlpha + dt / 0.2) else math.max(0, returnAlpha - dt / 0.15)
	b.Visible = returnAlpha > 0
	b.Active = offered
	if not b.Visible then
		returnPulse = 0
		return
	end
	returnPulse += dt
	b.BackgroundTransparency = 1 - (1 - RESPAWN_ALPHA) * returnAlpha
	b.TextTransparency = 1 - returnAlpha
	b.BackgroundColor3 = RESPAWN_BG:Lerp(GOLD, 0.2 + 0.2 * math.sin(returnPulse * 5))
end

-- ASSIST pill (touch) / chip (desktop, key T): shown in countdown and race, a tap flips ASSIST through RaceUI's handler.
-- The label is the state ("ASSIST ON" / "ASSIST OFF", plus the key on desktop). ASSIST lives in the gear panel too.
function HudExtras.setAssistHandler(fn: (on: boolean) -> ())
	assistHandler = fn
end

local function buildAutoPill(parent: Frame, sk: Skin)
	local b = Instance.new("TextButton")
	b.Name = "AutoPill"
	b.BackgroundColor3 = CHIP_WOOD
	b.BackgroundTransparency = CHIP_ALPHA
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamBlack
	b.TextColor3 = sk.creamText
	b.TextScaled = true
	b.Text = "ASSIST ON"
	b.Selectable = false
	b.Visible = false
	b.Parent = parent
	corner(b, UDim.new(0.5, 0))
	stroke(b, CHIP_SAND, 2, true)
	stroke(b, sk.darkInk, 1.8, false)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = b
	b.Activated:Connect(function()
		local fn = assistHandler
		if fn then
			punch(b, 0.9, 0.18)
			fn(LocalPlayer:GetAttribute("AutoThrottle") == false)
		end
	end)
	autoPill = b
end

------------------------------------------------------------------------------------------------------------------------
-- Sky Token counter
------------------------------------------------------------------------------------------------------------------------

local function renderTokens(n: number)
	local t = tokenText
	if t then
		t.Text = string.format("%d/%d", n, Progression.TOKENS_TOTAL)
	end
end

-- The chip idles at 70 percent alpha; a change snaps it to full, pops it to 1.25 and settles over 1.2 s with a gold flash.
local function setTokenAlpha(transparency: number)
	local plaque, star, t, st = tokenPlaque, tokenStar, tokenText, tokenStroke
	if not plaque or not star or not t or not st then
		return
	end
	plaque.BackgroundTransparency = 1 - (1 - CHIP_ALPHA) * (1 - transparency)
	star.ImageTransparency = transparency
	t.TextTransparency = transparency
	st.Transparency = transparency
end

local function popToken()
	local plaque, star, t, st = tokenPlaque, tokenStar, tokenText, tokenStroke
	if not plaque or not star or not t or not st then
		return
	end
	tokenAlphaToken += 1
	local my = tokenAlphaToken
	setTokenAlpha(0)
	plaque.BackgroundColor3 = GOLD
	local sc = scaleOf(plaque)
	sc.Scale = 1.25
	local info = TweenInfo.new(1.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	TweenService:Create(sc, info, { Scale = 1 }):Play()
	TweenService:Create(plaque, info, { BackgroundColor3 = CHIP_WOOD, BackgroundTransparency = 1 - (1 - CHIP_ALPHA) * (1 - TOKEN_IDLE_T) }):Play()
	-- Back to the idle alpha after the hold (a newer pop cancels this one).
	task.delay(0.5, function()
		if my ~= tokenAlphaToken then
			return
		end
		local fade = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		TweenService:Create(star, fade, { ImageTransparency = TOKEN_IDLE_T }):Play()
		TweenService:Create(t, fade, { TextTransparency = TOKEN_IDLE_T }):Play()
		TweenService:Create(st, fade, { Transparency = TOKEN_IDLE_T }):Play()
	end)
end

-- Eight stars fly out of the counter and fade; GUI-only, so it never covers the route.
local function starBurst()
	local plaque, star = tokenPlaque, tokenStar
	if not plaque or not star then
		return
	end
	local starSize = star.AbsoluteSize.X
	for i = 1, 8 do
		local s = Instance.new("ImageLabel")
		s.Name = "AwardStar"
		s.BackgroundTransparency = 1
		s.Image = tex("star_twinkle")
		s.ImageColor3 = GOLD
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.Position = star.Position
		s.Size = UDim2.fromOffset(starSize * 0.7, starSize * 0.7)
		s.ZIndex = 8
		s.Parent = plaque
		local a = (i - 1) / 8 * math.pi * 2
		local dist = starSize * 2.2
		local info = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(s, info, {
			Position = star.Position + UDim2.fromOffset(math.cos(a) * dist, math.sin(a) * dist),
			ImageTransparency = 1,
			Rotation = 120,
			Size = UDim2.fromOffset(starSize * 0.25, starSize * 0.25),
		}):Play()
		task.delay(0.6, function()
			s:Destroy()
		end)
	end
end

-- REMARKABLE 24 (Token Homecoming): an award's count-up waits for the token flying home (client/TokenHomecoming), which
-- holds it (holdTokenAward) and lands it (releaseTokenAward). An award nobody claims within 0.3 s plays as before; a
-- held one plays at the latest when the hold runs out (step).
local holdUntil = 0
local pendingAward: { before: number, n: number }? = nil
local graceToken = 0

local function playAward(before: number, n: number)
	-- An award landed: count up, burst, pulse, toast.
	countUpFrom, countUpTo, countUpStart = tokensShown, n, os.clock()
	local star = tokenStar
	popToken()
	if star then
		star.ImageColor3 = Color3.new(1, 1, 1)
		TweenService:Create(star, TweenInfo.new(0.5), { ImageColor3 = COIN_RIM, Rotation = star.Rotation + 360 }):Play()
	end
	starBurst()
	Sfx.play("coin_all", 1, 0.56) -- the award is a coin run, not a second finish fanfare
	local sk = skin
	if sk and sk.toast then
		local gained = n - before
		sk.toast(string.format("+%d SKY TOKEN%s!", gained, if gained == 1 then "" else "S"), GOLD, 2.4, true) -- lands under the results card too
	end
end

function HudExtras.holdTokenAward(seconds: number)
	holdUntil = math.max(holdUntil, os.clock() + seconds)
end

function HudExtras.releaseTokenAward()
	holdUntil = 0
	local p = pendingAward
	pendingAward = nil
	if p then
		playAward(p.before, p.n)
	end
end

-- Where a flying token lands (the counter's star).
function HudExtras.tokenTarget(): GuiObject?
	return tokenStar
end

local function onTokensChanged()
	local raw = LocalPlayer:GetAttribute("SkyTokens")
	if type(raw) ~= "number" then
		return
	end
	local n = math.floor(raw)
	local before = tokensKnown
	tokensKnown = n
	if before == nil or n <= before then
		-- First value after the profile loads (or a reset): show it, no award moment.
		pendingAward = nil
		countUpFrom, countUpTo, countUpStart = n, n, 0
		local changed = before ~= nil and n ~= before
		tokensShown = n
		renderTokens(n)
		if changed then
			popToken() -- a reset or a spend: the chip still says "this changed"
		end
		return
	end
	local p = pendingAward
	if p then
		p.n = n
	else
		pendingAward = { before = before, n = n }
	end
	if os.clock() < holdUntil then
		return -- a token is (about to be) flying home: it lands the count
	end
	-- The award event (RaceFinished, HubFind) can land just after the attribute: give it 0.3 s to claim the count.
	graceToken += 1
	local my = graceToken
	task.delay(0.3, function()
		if my == graceToken and os.clock() >= holdUntil then
			HudExtras.releaseTokenAward()
		end
	end)
end

local function buildTokenCounter(parent: Frame, sk: Skin)
	local plaque = Instance.new("Frame")
	plaque.Name = "SkyTokenCounter"
	plaque.BackgroundColor3 = CHIP_WOOD
	plaque.BorderSizePixel = 0
	plaque.Active = false
	plaque.Parent = parent
	corner(plaque, UDim.new(0, 10))
	tokenStroke = stroke(plaque, CHIP_SAND, 2, true)
	tokenPlaque = plaque

	-- A solid coin (the soft twinkle sprite alone read as a smudge at 12-20 px): an opaque gold disc with a dark amber rim,
	-- the star on it. layout() sizes both (never under COIN_MIN px).
	local coin = Instance.new("Frame")
	coin.Name = "TokenCoin"
	coin.AnchorPoint = Vector2.new(0.5, 0.5)
	coin.Position = UDim2.fromScale(0.2, 0.5)
	coin.Size = UDim2.fromOffset(COIN_MIN, COIN_MIN)
	coin.BackgroundColor3 = COIN_GOLD
	coin.BorderSizePixel = 0
	coin.ZIndex = 2
	coin.Active = false
	coin.Parent = plaque
	corner(coin, UDim.new(0.5, 0))
	stroke(coin, COIN_RIM, 2, true)
	tokenCoin = coin
	-- The coin's face: an inner ring, so it reads as a coin and not a flat dot even where the star sprite is faint.
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.fromScale(0.62, 0.62)
	face.BackgroundTransparency = 1
	face.BorderSizePixel = 0
	face.Active = false
	face.Parent = coin
	corner(face, UDim.new(0.5, 0))
	stroke(face, COIN_RIM, 1.5, true)

	local star = Instance.new("ImageLabel")
	star.Name = "TokenStar"
	star.AnchorPoint = Vector2.new(0.5, 0.5)
	star.Position = UDim2.fromScale(0.2, 0.5)
	star.BackgroundTransparency = 1
	star.Image = tex("star_twinkle")
	star.ImageColor3 = COIN_RIM
	star.ZIndex = 3
	star.Parent = plaque
	tokenStar = star

	local t = label(plaque, "TokenCount", sk)
	t.AnchorPoint = Vector2.new(1, 0.5)
	t.Position = UDim2.new(1, -8, 0.5, 0)
	t.Size = UDim2.fromScale(0.62, 0.8)
	t.TextXAlignment = Enum.TextXAlignment.Right
	tokenText = t
	renderTokens(0)
	setTokenAlpha(TOKEN_IDLE_T)

	onTokensChanged()
	LocalPlayer:GetAttributeChangedSignal("SkyTokens"):Connect(onTokensChanged)
end

------------------------------------------------------------------------------------------------------------------------
-- Notices (save error, loading, disconnect, lobby timeout)
------------------------------------------------------------------------------------------------------------------------

local function makeNotice(id: string, sk: Skin): Notice
	local frame = Instance.new("Frame")
	frame.Name = "Notice_" .. id
	frame.Size = UDim2.new(1, 0, 0, 28) -- one line: sizeNotice sets the real height from rects.noticeStack
	frame.BackgroundColor3 = Color3.fromRGB(42, 26, 18)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	frame.Active = false
	frame.Visible = false
	frame.Parent = noticeStack
	corner(frame, UDim.new(0, 10))
	local st = stroke(frame, TONE_STROKE.info, 2, true)
	st.Name = "ToneStroke"
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = frame

	local spinner = Instance.new("Frame")
	spinner.Name = "Spinner"
	spinner.AnchorPoint = Vector2.new(0, 0.5)
	spinner.Position = UDim2.fromScale(0, 0.5)
	spinner.Size = UDim2.fromOffset(20, 20)
	spinner.BackgroundTransparency = 1
	spinner.Parent = frame
	local dots: { Frame } = {}
	for i = 1, SPINNER_DOTS do
		local a = (i - 1) / SPINNER_DOTS * math.pi * 2
		local d = Instance.new("Frame")
		d.Name = "Dot" .. i
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Position = UDim2.new(0.5, math.cos(a) * 7, 0.5, math.sin(a) * 7)
		d.Size = UDim2.fromOffset(4, 4)
		d.BackgroundColor3 = sk.creamText
		d.BorderSizePixel = 0
		d.Parent = spinner
		corner(d, UDim.new(0.5, 0))
		table.insert(dots, d)
	end

	local text = Instance.new("TextLabel")
	text.Name = "Message"
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextColor3 = sk.creamText
	text.TextWrapped = false -- a notice is ONE line (the stack is one row tall in HudLayoutRules); long text is cut with ...
	text.TextTruncate = Enum.TextTruncate.AtEnd
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Active = false
	text.Parent = frame
	stroke(text, sk.darkInk, 1.2, false)

	return { frame = frame, text = text, spinner = spinner, dots = dots, token = 0 }
end

local function sizeNotice(n: Notice)
	local l = current
	local S = if l then l.metrics.S else 0.6
	local textSize = HudLayoutRules.textSize(HudLayoutRules.TEXT_BASE.notice, S)
	n.text.TextSize = textSize
	local spinW = if n.spinner.Visible then 28 else 0
	local rowH = if l and l.rects.noticeStack then l.rects.noticeStack.h else 28
	n.frame.Size = UDim2.new(1, 0, 0, rowH)
	n.text.Position = UDim2.fromOffset(spinW, 0)
	n.text.Size = UDim2.new(1, -spinW, 1, 0)
	n.text.TextYAlignment = Enum.TextYAlignment.Center
end

-- Shows (or updates) a banner. seconds = nil keeps it until hideNotice(id); spinner marks "still trying".
function HudExtras.showNotice(id: string, text: string, tone: Tone, spinner: boolean, seconds: number?)
	local sk, stack = skin, noticeStack
	if not sk or not stack then
		return
	end
	local n = notices[id]
	if not n then
		n = makeNotice(id, sk)
		notices[id] = n
	end
	local notice = n :: Notice
	noticeOrder += 1
	notice.token += 1
	local myToken = notice.token
	notice.frame.LayoutOrder = -noticeOrder -- newest on top: the stack is one row and clips the rest
	notice.text.Text = text
	notice.spinner.Visible = spinner
	local st = notice.frame:FindFirstChild("ToneStroke") :: UIStroke?
	if st then
		st.Color = TONE_STROKE[tone] or TONE_STROKE.info
	end
	sizeNotice(notice)
	local wasVisible = notice.frame.Visible
	notice.frame.Visible = true
	if not wasVisible then
		notice.frame.BackgroundTransparency = 0.6
		TweenService:Create(notice.frame, TweenInfo.new(0.12), { BackgroundTransparency = 0.1 }):Play()
		punch(notice.frame, 0.9, 0.14)
	end
	if seconds then
		task.delay(seconds, function()
			if notice.token == myToken then
				notice.frame.Visible = false
			end
		end)
	end
end

function HudExtras.hideNotice(id: string)
	local n = notices[id]
	if n then
		n.token += 1
		n.frame.Visible = false
	end
end

function HudExtras.showDisconnect(detail: string?)
	local text = "Connection lost. Reconnecting..." -- one line (notices are single-line); the saved progress is safe
	if detail and detail ~= "" then
		warn("[HudExtras] disconnect detail: " .. string.sub(detail, 1, 80))
	end
	HudExtras.showNotice("connection", text, "error", true, nil)
end

function HudExtras.showReconnected()
	HudExtras.showNotice("connection", "Reconnected.", "ok", false, 2.5)
end

function HudExtras.showLobbyTimeout(seconds: number?)
	local text = "No race started in time. Back to the hub; nothing was lost."
	HudExtras.showNotice("lobby", text, "info", false, seconds or 6)
end

local function onSaveState()
	local state = LocalPlayer:GetAttribute("SaveState")
	local msg = LocalPlayer:GetAttribute("SaveMessage")
	local message = if type(msg) == "string" and msg ~= "" then msg else nil
	loadingToken += 1
	if state == "error" then
		saveHadError = true
		HudExtras.showNotice("save", message or "Progress not saved yet. Retrying.", "error", true, nil)
	elseif state == "loading" then
		-- Most loads finish in well under a second; only a slow one earns a banner.
		local my = loadingToken
		task.delay(2.5, function()
			if loadingToken == my and LocalPlayer:GetAttribute("SaveState") == "loading" then
				HudExtras.showNotice("save", message or "Loading your progress", "info", true, nil)
			end
		end)
	elseif state == "ok" then
		if saveHadError then
			saveHadError = false
			HudExtras.showNotice("save", "Progress saved.", "ok", false, 2.5)
		else
			HudExtras.hideNotice("save")
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Layout and frame step
------------------------------------------------------------------------------------------------------------------------

function HudExtras.layout(l: Layout)
	current = l
	local S = l.metrics.S
	local rects = l.rects
	local TB = HudLayoutRules.TEXT_BASE
	local function place(obj: GuiObject?, r: HudLayoutRules.Rect?)
		if obj and r then
			obj.Position = UDim2.fromOffset(r.x, r.y)
			obj.Size = UDim2.fromOffset(r.w, r.h)
		end
	end
	place(slot, rects.item)
	local item = slot
	if item then
		local pipPx = math.max(6, math.floor(8 * S + 0.5))
		for _, pip in ipairs(pips) do
			pip.Size = UDim2.fromOffset(pipPx, pipPx)
		end
		local row = item:FindFirstChild("LevelPips") :: Frame?
		if row then
			row.Size = UDim2.new(1, 0, 0, pipPx + 2)
			local list = row:FindFirstChildOfClass("UIListLayout")
			if list then
				list.Padding = UDim.new(0, math.max(2, math.floor(3 * S)))
			end
		end
		local badge, kt = keyBadge, keyText
		if badge and kt then
			local b = math.max(18, math.floor(26 * S + 0.5)) -- key glyph: 18-26 px
			badge.Size = UDim2.fromOffset(b, b)
			kt.TextSize = HudLayoutRules.textSize(TB.glyph, S)
			fitText(kt, kt.TextSize)
		end
	end
	place(tokenPlaque, rects.token)
	local star, t = tokenStar, tokenText
	if star and t and rects.token then
		local d = math.max(COIN_MIN, math.floor(rects.token.h * 0.72))
		local cx = math.floor(d / 2) + 6
		local coin = tokenCoin
		if coin then
			coin.Size = UDim2.fromOffset(d, d)
			coin.Position = UDim2.new(0, cx, 0.5, 0)
		end
		local st = math.floor(d * 0.78)
		star.Size = UDim2.fromOffset(st, st)
		star.Position = UDim2.new(0, cx, 0.5, 0)
		t.TextSize = HudLayoutRules.textSize(TB.token, S)
		fitText(t, t.TextSize) -- "14/14" fills the column at desktop scale
	end
	-- RESPAWN: an icon button above the right zone on touch, the hint chip in the bottom-right corner on desktop.
	respawnIsTouch = l.kind == "touch"
	place(respawnBtn, rects.respawn)
	if respawnBtn then
		fitText(respawnBtn :: any, HudLayoutRules.textSize(if respawnIsTouch then 30 else TB.respawnHint, S))
		refreshRespawnLabel()
	end
	place(returnBtn, rects.returnBtn)
	if returnBtn then
		fitText(returnBtn :: any, HudLayoutRules.textSize(if respawnIsTouch then 22 else TB.returnBtn, S))
		refreshReturnLabel()
	end
	-- The ASSIST pill rides the left column on touch; on desktop the chip sits under the "?".
	place(autoPill, rects.autoPill or rects.assistChip)
	assistPlaced = (rects.autoPill or rects.assistChip) ~= nil
	if autoPill then
		fitText(autoPill :: any, HudLayoutRules.textSize(TB.autoPill, S))
	end
	-- Lane B below the toast: the notice stack.
	local stack = noticeStack
	local ns = rects.noticeStack
	if stack and ns then
		stack.Size = UDim2.fromOffset(ns.w, ns.h)
		stack.Position = UDim2.fromOffset(ns.x, ns.y)
	end
	for _, n in pairs(notices) do
		sizeNotice(n)
	end
end

local spinClock = 0
local hueClock = 0
local lastDnfText = ""

-- L30: with 2+ humans, from the first finish the others have until workspace DnfAt (server time); the line turns red
-- for the last 10 s and goes once this racer finishes or the deadline is gone.
local function stepDnf()
	local at = RaceAttr.mine("DnfAt")
	local left = if type(at) == "number" then at - workspace:GetServerTimeNow() else 0
	local text = ""
	if left > 0 and LocalPlayer:GetAttribute("RaceFinished") ~= true and RaceAttr.mine("RaceMode") ~= "hub" then
		text = RaceFlowRules.dnfText(left)
	end
	if text == lastDnfText then
		return
	end
	lastDnfText = text
	if text == "" then
		HudExtras.hideNotice("dnf")
	else
		HudExtras.showNotice("dnf", text, if left <= 10 then "error" else "info", false, nil)
	end
end

local function step(dt: number)
	spinClock += dt
	stepDnf()
	if pendingAward and holdUntil > 0 and os.clock() > holdUntil then
		HudExtras.releaseTokenAward() -- REMARKABLE 24: a held award whose token never landed still counts up
	end
	stepRespawn(dt)
	stepReturn(dt)
	local pill = autoPill
	if pill then
		local on = LocalPlayer:GetAttribute("AutoThrottle") ~= false
		pill.Visible = HudPhase.allows("AssistChip") and assistPlaced
		pill.Text = (if on then "ASSIST ON" else "ASSIST OFF") .. (if respawnIsTouch then "" else " [T]")
		pill.BackgroundColor3 = if on then CHIP_WOOD else CHIP_OFF
		pill.TextColor3 = if on then CHIP_TEXT_ON else CHIP_OFF_TEXT
	end
	hueClock = (hueClock + dt * 0.35) % 1
	-- Rainbow item: the gem cycles hue so it reads as "rainbow", not purple.
	local g = gem
	if g and heldColor == "rainbow" and not HudExtras.itemRolling() then
		g.BackgroundColor3 = Color3.fromHSV(hueClock, 0.65, 1)
	end
	-- Count-up after an award.
	if countUpStart > 0 then
		local t = math.clamp((os.clock() - countUpStart) / COUNT_UP_SECONDS, 0, 1)
		local shown = math.floor(countUpFrom + (countUpTo - countUpFrom) * t + 0.0001)
		if shown ~= tokensShown then
			tokensShown = shown
			renderTokens(shown)
			local plaque = tokenPlaque
			if plaque then
				punch(plaque, 1.12, 0.12)
			end
		end
		if t >= 1 then
			countUpStart = 0
			tokensShown = countUpTo
			renderTokens(countUpTo)
		end
	end
	-- Chasing-dot spinners (no rotation: rotated GUI children are not reliable on every device).
	local head = math.floor(spinClock * 12) % SPINNER_DOTS
	for _, n in pairs(notices) do
		if n.frame.Visible and n.spinner.Visible then
			for i, d in ipairs(n.dots) do
				local age = (head - (i - 1)) % SPINNER_DOTS
				d.BackgroundTransparency = math.clamp(age / SPINNER_DOTS, 0, 0.85)
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------------------------------------------------------

function HudExtras.init(parent: ScreenGui, sk: Skin)
	if root then
		root:Destroy()
		table.clear(pips)
		table.clear(notices)
	end
	skin = sk
	local r = Instance.new("Frame")
	r.Name = "HudExtras"
	r.Size = UDim2.fromScale(1, 1)
	r.BackgroundTransparency = 1
	r.Active = false
	r.ZIndex = 2
	r.Parent = parent
	root = r

	buildItemSlot(r, sk)
	buildTokenCounter(r, sk)
	buildRespawnButton(r, sk)
	buildReturnButton(r, sk)
	buildAutoPill(r, sk)

	local stack = Instance.new("Frame")
	stack.Name = "NoticeStack"
	stack.AnchorPoint = Vector2.zero
	stack.BackgroundTransparency = 1
	stack.ClipsDescendants = true -- never taller than its rect: lane A starts right below it
	stack.Active = false
	stack.Parent = r
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 4)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = stack
	noticeStack = stack

	onSaveState()
	LocalPlayer:GetAttributeChangedSignal("SaveState"):Connect(onSaveState)
	LocalPlayer:GetAttributeChangedSignal("SaveMessage"):Connect(function()
		-- T1-14: the "Saving paused ... back in about N s" countdown updates while the load waits on another server's lock.
		local state = LocalPlayer:GetAttribute("SaveState")
		if state == "error" or state == "loading" then
			onSaveState()
		end
	end)

	-- Disconnect: Roblox raises its own prompt too; ours says what it means for progress, in the game's voice.
	pcall(function()
		GuiService.ErrorMessageChanged:Connect(function()
			local msg = GuiService:GetErrorMessage()
			if msg ~= "" then
				HudExtras.showDisconnect(msg)
			end
		end)
	end)
	pcall(function()
		local networkClient = game:GetService("NetworkClient")
		networkClient.ChildRemoved:Connect(function()
			HudExtras.showDisconnect(nil)
		end)
	end)

	RunService.RenderStepped:Connect(Prof.wrap("SR_HudExtras", step))
end

return HudExtras
