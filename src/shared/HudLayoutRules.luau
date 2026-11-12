--!strict
-- HUD layout v2 rules (pure, no Roblox globals; tools/tests/hud_layout_spec.luau runs it under Lune). docs/design/HUD_LAYOUT.md
-- is the spec; section numbers below point into it.
--  * scale / metrics: ONE number S (viewport height / 1080, clamped 0.6..1) and the safe rect (3.1), replacing the plaqueScale table.
--  * compute: every HUD element's rectangle for a viewport, the safe-area insets, the Roblox nav reserve and the input kind
--    (touch or desktop), so no two elements, the nav, the centre road band or a thumb zone can ever share pixels (4.1).
--  * bubbleClear / reserved: the screen-space guard for world-space speech bubbles (7.1).
--  * positionParts / ordinal: the position readout's text pieces (3rd, /8).
--  * glyphMode / ignoreMouse: when key badges may show and when a mouse must not flip a touch device out of touch (5, 8).
local HudLayoutRules = {}

export type Rect = { x: number, y: number, w: number, h: number }
export type Insets = { left: number, top: number, right: number, bottom: number }
export type Kind = "touch" | "desktop"
export type Glyphs = "none" | "keyboard" | "gamepad"
export type Options = {
	battle: boolean?, -- lane B starts below TrackFlow's top-centre battle plaque
	rightLimit: number?, -- right edge (px) the right column must stay left of (a Roblox control on the right of the top bar)
	minimap: boolean?, -- a race minimap is up (client/Minimap): rect `minimap` is added; on touch the left column makes room for it
}
export type Metrics = { S: number, M: number, topM: number, bottomM: number, x0: number, xr: number, yTop: number, yBot: number }

HudLayoutRules.MIN_BUTTON = 44 -- touch target floor (px)
HudLayoutRules.MIN_TEXT = 12 -- body text floor (px)
HudLayoutRules.PHONE_CLASS_Y = 450 -- a viewport this short or shorter is a phone (the Studio phone emulator included)
HudLayoutRules.BOARD_PAD2 = 10 -- the battle board's panel padding, top plus bottom (px)
HudLayoutRules.BATTLE_GAP = 8 -- air between the battle timer plaque and lane B (spec floor 6)
HudLayoutRules.NAV_GAP = 8 -- air between the Roblox nav's bottom edge and the left column
HudLayoutRules.VEHICLE_MIN_TOUCH = 36 -- the docked vehicle chip's touch height floor on the shortest phones (see compute)
HudLayoutRules.THUMB_GROW = 16 -- the steer pad and the right zone keep this much air around them

-- Base text sizes at S = 1 (3.2); the text actually drawn is textSize(base, S).
-- Race minimap (docs/design/HUD_MK_LAYOUT.md): a square, 23 percent of the screen height on a phone (844x390 = 90 px), 22 percent
-- on a desktop up to 220 px. Touch: top-left under the nav, where the Mario Kart Tour reference has it (the item frame moves
-- right of it). Desktop: left edge under the token chip.
-- Compact phones (safe width 700 px or less: 740x360 with device insets is 652): 64 px, and compute() stacks the gear and "?" in a column
-- so the message lanes keep about 200 px. safeW is optional (nil = not compact).
HudLayoutRules.COMPACT_SAFE_W = 700
HudLayoutRules.MINIMAP_COMPACT = 64
-- UI v2 race HUD (docs/design/UI_V2.md): the item box side and the desktop hero position numeral at S = 1, and the share of
-- the width the message lanes keep when the item box moves top-left.
HudLayoutRules.ITEM_BOX = 150
HudLayoutRules.POS_HERO_W = 260
HudLayoutRules.POS_HERO_H = 170
HudLayoutRules.RING_PULSE = 1.25 -- client/TrickJuice: the start ring's pop on the "1"
HudLayoutRules.POS_PULSE = 1.3 -- client/RaceUI: the position badge's pop on a place change
HudLayoutRules.ITEM_LANE_MIN = 0.18

function HudLayoutRules.minimapCompact(kind: Kind, safeW: number?): boolean
	return kind == "touch" and safeW ~= nil and safeW <= HudLayoutRules.COMPACT_SAFE_W
end

function HudLayoutRules.minimapSize(vpY: number, kind: Kind, safeW: number?): number
	if HudLayoutRules.minimapCompact(kind, safeW) then
		return HudLayoutRules.MINIMAP_COMPACT
	end
	if kind == "touch" then
		return math.clamp(math.floor(0.23 * vpY + 0.5), 72, 110)
	end
	return math.clamp(math.floor(0.22 * vpY + 0.5), 90, 220)
end

HudLayoutRules.TEXT_BASE = {
	positionNumeral = 64,
	positionSuffix = 26,
	positionTotal = 20,
	lapRow = 28,
	combo = 24,
	token = 26,
	toast = 20,
	notice = 18,
	respawnHint = 18,
	returnBtn = 18,
	glyph = 18,
	autoPill = 18,
} :: { [string]: number }

local function round(x: number): number
	return math.floor(x + 0.5)
end

-- 3.1: S = clamp(vpY / 1080, 0.6, 1.0). A desktop kind on a window taller than a phone gets a floor of DESKTOP_MIN_S
-- (1.25 x the phone's 0.6): a 1366x768 window read 0.71 and drew 110-130 px chips on a big monitor frame. A phone-class
-- viewport in desktop mode (the emulator after a key press) keeps the phone scale: nothing fits at 0.75 there.
HudLayoutRules.DESKTOP_MIN_S = 0.75
function HudLayoutRules.scale(vpY: number, kind: Kind?): number
	local lo = if kind == "desktop" and not HudLayoutRules.isPhoneClass(vpY) then HudLayoutRules.DESKTOP_MIN_S else 0.6
	return math.clamp(vpY / 1080, lo, 1.0)
end

-- A base size at S = 1 as pixels.
function HudLayoutRules.px(base: number, S: number): number
	return round(base * S)
end

-- A button side: never under the touch floor.
function HudLayoutRules.button(base: number, S: number): number
	return math.max(HudLayoutRules.MIN_BUTTON, round(base * S))
end

-- Body text: never under the readable floor.
function HudLayoutRules.textSize(base: number, S: number): number
	return math.max(HudLayoutRules.MIN_TEXT, round(base * S))
end

function HudLayoutRules.isPhoneClass(vpY: number): boolean
	return vpY <= HudLayoutRules.PHONE_CLASS_Y
end

-- 3.1: side margin, top margin, bottom margin and the safe rect from the SafeArea insets.
function HudLayoutRules.metrics(vpX: number, vpY: number, ins: Insets, kind: Kind?): Metrics
	local S = HudLayoutRules.scale(vpY, kind)
	local M = math.max(12, round(24 * S))
	local topM = round(8 * S)
	local bottomM = if S <= 0.65 then 10 else round(22 * S)
	return {
		S = S,
		M = M,
		topM = topM,
		bottomM = bottomM,
		x0 = ins.left + M,
		xr = vpX - ins.right - M,
		yTop = ins.top + topM,
		yBot = vpY - ins.bottom - bottomM,
	}
end

-- 3.1 fallbacks when GuiService.TopbarInset is unavailable: the phone emulation measured 190x76, a desktop top bar 200x58.
function HudLayoutRules.fallbackNav(vpX: number, vpY: number): Rect
	if HudLayoutRules.isPhoneClass(vpY) then
		return { x = 0, y = 0, w = 190, h = 76 }
	end
	return { x = 0, y = 0, w = 200, h = 58 }
end

-- A live TopbarInset reading as the nav reserve (the strip beside the nav: Min.X is the nav's right edge, Max.Y its bottom).
-- Anything implausible (missing, zero, or bigger than a third of the screen) falls back; the second result is true when
-- the live reading was used.
function HudLayoutRules.navFromTopbar(minX: number?, maxY: number?, vpX: number, vpY: number): (Rect, boolean)
	if type(minX) == "number" and type(maxY) == "number" and minX >= 40 and maxY >= 20 and minX <= vpX / 3 and maxY <= vpY / 3 then
		return { x = 0, y = 0, w = round(minX), h = round(maxY) }, true
	end
	return HudLayoutRules.fallbackNav(vpX, vpY), false
end

-- TopbarInset.Max.X as the right column's limit (10): only a reading that leaves at least 60 percent of the width and does
-- not exceed the viewport counts, and one at the screen edge changes nothing (compute takes min with xr).
function HudLayoutRules.rightLimitFromTopbar(maxX: number?, vpX: number): number?
	if type(maxX) == "number" and maxX >= 0.6 * vpX and maxX <= vpX then
		return round(maxX)
	end
	return nil
end

-- The Roblox leaderboard (CoreGui PlayerList) is top-right on desktop, 166 px wide with a 4 px margin at 1365 wide (measured
-- in Studio: x 1195..1361, y 4..212 below the top bar for one player, taller with more): neither TopbarInset.Max.X nor
-- GetInsetArea knows about it, so the right column would sit under it. When it is enabled on a desktop-kind layout the
-- right limit is pulled left of it (180 px). On touch the list is a collapsed icon, so nothing is reserved.
HudLayoutRules.PLAYER_LIST_W = 180
function HudLayoutRules.rightLimitWithPlayerList(limit: number?, vpX: number, kind: Kind, listShown: boolean): number?
	if kind ~= "desktop" or not listShown then
		return limit
	end
	local lim = vpX - HudLayoutRules.PLAYER_LIST_W
	if limit then
		return math.min(limit, lim)
	end
	return lim
end

-- 5 and RaceUI's size classes (kept exactly as built): steer pad side, right zone w and h, GAS!/TAP! ring side.
-- Controls v2 (docs/research/MOBILE_CONTROLS_AND_REVERSE.md): the BRAKE / REV pedal's width, 56 px floor (the research's
-- 56 dp minimum for a held control), 84 at S = 1; BRAKE_GAP of air to the TURN stone; STONE_H = the stones' height share of
-- the zone (RaceUI builds TURN / ITEM at 0.78 with the caption under them).
HudLayoutRules.BRAKE_MIN = 56
HudLayoutRules.BRAKE_GAP = 8
HudLayoutRules.STONE_H = 0.78
function HudLayoutRules.brakeSize(S: number): number
	return math.max(HudLayoutRules.BRAKE_MIN, round(84 * S))
end

function HudLayoutRules.thumbSizes(vpY: number): (number, number, number, number)
	if vpY >= 600 then
		return 226, 308, 184, 110
	elseif vpY <= 375 then
		return 126, 176, 108, 76
	end
	return 146, 198, 120, 84
end

function HudLayoutRules.overlap(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

function HudLayoutRules.grow(r: Rect, n: number): Rect
	return { x = r.x - n, y = r.y - n, w = r.w + 2 * n, h = r.h + 2 * n }
end

-- inner lies fully inside outer (a pixel of slack for rounding).
function HudLayoutRules.contains(outer: Rect, inner: Rect): boolean
	return inner.x >= outer.x - 1e-6
		and inner.y >= outer.y - 1e-6
		and inner.x + inner.w <= outer.x + outer.w + 1e-6
		and inner.y + inner.h <= outer.y + outer.h + 1e-6
end

-- 2.1: nothing HUD below y = 55% inside x 30-70% of the screen.
function HudLayoutRules.roadBand(vpX: number, vpY: number): Rect
	return { x = 0.30 * vpX, y = 0.55 * vpY, w = 0.40 * vpX, h = 0.45 * vpY }
end

-- Names of the HUD elements the collision obligations (4.1) cover. The touch controls themselves (steerPad, rightZone,
-- startRing) are the thing the rest keeps away from, so they are not in the road-band test, only in the pairwise one.
HudLayoutRules.HUD_ELEMENTS = {
	"position", "lapChip", "combo", "item", "gear", "help", "token", "respawn", "returnBtn", "laneA", "laneB", "noticeStack", "hintChip", "minimap", "assistChip",
} :: { string }
HudLayoutRules.TOUCH_ELEMENTS = { "autoPill", "steerPad", "rightZone", "startRing" } :: { string }

HudLayoutRules.HUB_BAR_MARGIN = 12

-- Where TrackFlow puts the hub's ADVENTURE bar (right-anchored, so `right` is its right edge) given rects.hubBar and the real
-- ScreenGui size (guiX / guiY, 0 while the gui has not been laid out). The gui can be smaller than the camera's ViewportSize
-- (a DPI-scaled client such as the 2048x1088 published v21 one): the bar is then sized and pinned inside the gui, a 12 px margin
-- (plus the right inset) from its edge, never wider than 45 percent of it, and never left of rects.hubBar's own left edge unless
-- the gui is too small for that (the hub lanes stop at that edge).
function HudLayoutRules.hubBarPlacement(hb: Rect, vpX: number, vpY: number, guiX: number, guiY: number, insRight: number): { right: number, y: number, w: number, h: number }
	local gx = if guiX > 0 then math.min(guiX, vpX) else vpX
	local gy = if guiY > 0 then math.min(guiY, vpY) else vpY
	local safeRight = gx - insRight - HudLayoutRules.HUB_BAR_MARGIN
	local right = math.min(hb.x + hb.w, safeRight)
	local w = math.min(hb.w, math.max(160, gx * 0.45))
	w = math.min(w, math.max(0, right - 8))
	local h = math.clamp(0.13 * gy, 52, 96)
	return { right = right, y = hb.y, w = w, h = h }
end

-- The rectangle of every element, in px from the screen's top-left (insets already applied). nav = the Roblox top-left
-- reserve (HudMetrics supplies the live one); kind = "touch" adds the thumb controls and the AUTO pill, "desktop" the
-- respawn hint chip and the controls hint chip (hintChip: bottom-left, left of the road band, keyboard / gamepad only). Rect keys: position, lapChip, combo, item, gear, help, token, respawn, returnBtn, hintChip, startRing, laneA, laneB,
-- noticeStack, leftColumn, hubBar (bar + Storm line), hubLaneA / hubLaneB, nav, plus (touch) autoPill, steerPad, rightZone, plus (opts.battle) battleHud and battleBoard. In a battle
-- the position readout and the lap chip are hidden by the phase table, so their rects are absent and the field board
-- (TrackFlow's entrant list) takes the top-right on touch (the combo panel drops under it) or the left column on desktop.
function HudLayoutRules.compute(vpX: number, vpY: number, ins: Insets, nav: Rect, kind: Kind, opts: Options?): { [string]: Rect }
	local o: Options = opts or {}
	local m = HudLayoutRules.metrics(vpX, vpY, ins, kind)
	local S = m.S
	local touch = kind == "touch"
	local xr = m.xr
	if o.rightLimit then
		xr = math.min(xr, o.rightLimit)
	end
	local px = HudLayoutRules.px
	local r: { [string]: Rect } = {}
	r.nav = { x = nav.x, y = nav.y, w = nav.w, h = nav.h }

	-- Right column (top-right): position, lap/time chip, combo; right-aligned on xr, 4 px apart.
	-- UI v2 (docs/design/UI_V2.md, Mario Kart 8 placement): racing on a desktop the position numeral is the bottom-right hero
	-- (placed further down, above the respawn row) and the lap / time chip takes the top-right slot.
	local racingDesk = o.minimap == true and not o.battle and not touch and vpY >= 600
	local posW, posH = px(150, S), px(84, S)
	r.position = { x = xr - posW, y = m.yTop, w = posW, h = posH }
	local chipW, chipH = px(190, S), px(76, S)
	r.lapChip = { x = xr - chipW, y = if racingDesk then m.yTop else r.position.y + posH + 4, w = chipW, h = chipH }
	local comboW, comboH = px(170, S), px(44, S)
	r.combo = { x = xr - comboW, y = r.lapChip.y + chipH + 4, w = comboW, h = comboH }

	-- Left column under the Roblox nav. Not racing: item frame, the system cluster beside it, the token chip under it.
	-- Racing (opts.minimap, HUD_MK_LAYOUT.md section 3, the Mario Kart Tour reference): the minimap owns the nav-side corner, the token
	-- chip sits under it and (touch) the AUTO pill right of it; the item display, the gear and the "?" form one column at the top,
	-- directly left of the right column (position / lap chip / combo), so the left column shrinks to the minimap and the lanes widen.
	local itemS = px(120, S)
	local itemY = math.max(nav.y + nav.h + HudLayoutRules.NAV_GAP, m.yTop)
	local safeW = vpX - ins.left - ins.right
	local mapS = if o.minimap and not o.battle then HudLayoutRules.minimapSize(vpY, kind, safeW) else 0
	local mk = mapS > 0
	local compact = mk and HudLayoutRules.minimapCompact(kind, safeW)
	local sys = HudLayoutRules.button(56, S)
	if mk and touch then
		itemS = math.min(itemS, if compact then 52 else 60) -- display-only on touch (the ITEM stone mirrors it); UI v2: a bigger box
	end
	local leftMax: number
	local laneLeft: number
	if mk then
		r.minimap = { x = m.x0, y = itemY, w = mapS, h = mapS }
		-- Touch: the token chip sits right of the minimap and the AUTO pill under it (the strip under the minimap is the steer pad's air).
		-- Desktop: the token chip under the minimap.
		if touch then
			r.token = { x = m.x0 + mapS + 8, y = itemY, w = math.min(px(160, S), 96), h = px(46, S) }
		else
			r.token = { x = m.x0, y = itemY + mapS + 4, w = px(160, S), h = px(46, S) }
		end
		-- The item / gear / "?" column: right edge 8 px left of the right column's left edge, from the top margin down.
		local colRight = r.combo.x
		for _, k in (if racingDesk then { "lapChip" } else { "position", "lapChip" }) :: { string } do
			local rr = r[k]
			if rr then
				colRight = math.min(colRight, rr.x)
			end
		end
		colRight -= 8
		local gap = if touch then 4 else 8
		-- UI v2: the item box is the big framed box at the top, centre-left (right of the nav and the minimap), Mario Kart 8
		-- style, when the message lanes keep their room (ITEM_LANE_MIN of the width). Touch keeps it at the top of the column
		-- beside the right column (the ITEM stone under the right thumb mirrors it; top-left it cost the lanes half their width).
		local boxS = if touch then (if compact then 56 else 64) else px(HudLayoutRules.ITEM_BOX, S)
		local boxX = math.max(nav.x + nav.w, if touch then r.token.x + math.max(r.token.w, math.max(104, px(112, S))) else r.minimap.x + mapS) + (if touch then 8 else 12) -- touch: right of the token chip and the ASSIST pill under it
		local boxY = m.yTop
		local laneEdge = math.max(boxX + boxS, r.token.x + r.token.w, r.minimap.x + mapS) + 8
		local need = if compact then 100 else math.floor(HudLayoutRules.ITEM_LANE_MIN * vpX / 2)
		if not touch and vpX / 2 - laneEdge >= need then
			r.item = { x = boxX, y = boxY, w = boxS, h = boxS }
			r.gear = { x = colRight - sys, y = m.yTop, w = sys, h = sys }
		else
			r.item = { x = colRight - itemS, y = m.yTop, w = itemS, h = itemS }
			r.gear = { x = colRight - sys, y = r.item.y + itemS + gap, w = sys, h = sys }
		end
		r.help = { x = colRight - sys, y = r.gear.y + sys + gap, w = sys, h = sys }
		if not touch then
			-- Desktop / gamepad ASSIST chip (key T): under the "?", right edge on the column's, within the item frame's width.
			local aw, ah = if vpY >= 600 then px(170, S) else math.min(itemS, px(150, S)), if vpY >= 600 then math.max(34, px(40, S)) else math.max(30, px(36, S)) -- UI v2: an icon key wide enough for "ASSIST ON [T]" on one line
			r.assistChip = { x = colRight - aw, y = r.help.y + sys + gap, w = aw, h = ah }
			if HudLayoutRules.overlap(r.assistChip, HudLayoutRules.roadBand(vpX, vpY)) or r.assistChip.y + ah > m.yBot then
				-- A short window: the column reaches the road band, so the chip stands left of the gear instead.
				r.assistChip = { x = r.gear.x - 8 - aw, y = r.gear.y + math.floor((sys - ah) / 2), w = aw, h = ah }
			end
		end
		leftMax = math.max(r.minimap.x + mapS, r.token.x + r.token.w)
		laneLeft = if r.item.x < vpX / 2 then math.max(leftMax, r.item.x + r.item.w) else leftMax
	else
		r.item = { x = m.x0, y = itemY, w = itemS, h = itemS }
		r.gear = { x = m.x0 + itemS + 8, y = itemY, w = sys, h = sys }
		r.help = { x = r.gear.x + sys + 8, y = itemY, w = sys, h = sys }
		r.token = { x = m.x0, y = itemY + itemS + 4, w = px(160, S), h = px(46, S) }
		leftMax = math.max(r.help.x + sys, r.token.x + r.token.w)
		laneLeft = leftMax
	end
	-- Thumb controls and the bottom-right corner.
	local padS, zoneW, zoneH, ringS = HudLayoutRules.thumbSizes(vpY)
	if touch then
		r.steerPad = { x = m.x0, y = m.yBot - padS, w = padS, h = padS }
		-- Controls v2: the right zone grows left by the BRAKE / REV pedal (brakeSize + BRAKE_GAP): [BRAKE][TURN][ITEM]. The
		-- pedal is part of the zone (one thumb cluster, one exclusion rect); r.brake is its rect inside the zone, stone-high.
		local bs = HudLayoutRules.brakeSize(S)
		local zoneW2 = zoneW + bs + HudLayoutRules.BRAKE_GAP
		r.rightZone = { x = xr - zoneW2, y = m.yBot - zoneH, w = zoneW2, h = zoneH }
		r.brake = { x = r.rightZone.x, y = r.rightZone.y, w = bs, h = math.floor(zoneH * HudLayoutRules.STONE_H + 0.5) }
		-- The ASSIST pill (the one-tap switch, shown in countdown / race). Racing: under the token chip, right of the minimap.
		-- Otherwise right of the token chip, under the system cluster: the only free spot above the steer pad's air at 844x390.
		local pillW = math.max(104, px(112, S)) -- "ASSIST OFF" at the 12 px text floor
		if mk then
			r.autoPill = { x = r.token.x, y = r.token.y + r.token.h + 4, w = pillW, h = HudLayoutRules.MIN_BUTTON }
			laneLeft = math.max(laneLeft, r.autoPill.x + pillW, r.token.x + r.token.w)
			leftMax = laneLeft
		else
			r.autoPill = { x = r.token.x + r.token.w + 8, y = itemY + sys + 8, w = pillW, h = HudLayoutRules.MIN_BUTTON }
			leftMax = math.max(leftMax, r.autoPill.x + pillW)
			laneLeft = leftMax
		end
		local rs = math.max(48, HudLayoutRules.button(56, S))
		r.respawn = { x = xr - rs, y = r.rightZone.y - HudLayoutRules.THUMB_GROW - rs, w = rs, h = rs }
		r.startRing = { x = r.rightZone.x - 12 - ringS, y = m.yBot - ringS, w = ringS, h = ringS }
		if mk and r.help.y + r.help.h > r.respawn.y - 4 then
			-- A short screen with big insets: the column would reach the RETURN / respawn row, so the "?" stands left of the gear instead.
			r.help = { x = r.gear.x - 4 - sys, y = r.gear.y, w = sys, h = sys }
		end
	else
		local rw, rh = px(170, S), math.max(28, px(36, S))
		r.respawn = { x = xr - rw, y = m.yBot - rh, w = rw, h = rh }
		-- The keyboard / gamepad controls hint: a compact chip in the bottom-left corner, kept left of the road band.
		-- Two lines of 13+ px fit (the sentence is about 65 characters): 44 px at S = 1, never under 34.
		local hintW = math.min(px(420, S), math.floor(0.30 * vpX) - m.x0 - 8)
		local hintH = math.max(34, px(44, S))
		r.hintChip = { x = m.x0, y = m.yBot - hintH, w = hintW, h = hintH }
		r.startRing = { x = xr - ringS, y = r.respawn.y - 8 - ringS, w = ringS, h = ringS }
		if not o.battle and vpY >= 600 then
			-- UI v2 hero numeral (racing): bottom-right, right of the road band, above the respawn row; the start ring
			-- (grid only) stands above it.
			local hw, hh = px(HudLayoutRules.POS_HERO_W, S), px(HudLayoutRules.POS_HERO_H, S)
			local hero = { x = xr - hw, y = r.respawn.y - 8 - hh, w = hw, h = hh }
			if racingDesk then
				r.position = hero
			end
			-- v39: the ring keeps clear of the hero slot even while the minimap (and with it the hero numeral) is not on
			-- yet, so a layout that flips to the racing one at GO never lands the numeral on the disc. The gap also covers
			-- both pulses (the ring pops to RING_PULSE on the "1", the badge to POS_PULSE on a place change, both about
			-- their centres), so the GAS disc never touches the numeral, even mid-pulse.
			local gap = 8 + math.ceil(ringS * (HudLayoutRules.RING_PULSE - 1) / 2) + math.ceil(hh * (HudLayoutRules.POS_PULSE - 1) / 2)
			r.startRing = { x = xr - ringS, y = hero.y - gap - ringS, w = ringS, h = ringS }
		end
	end
	-- RETURN to course (planes, off course; docs/design/FLIGHT_GUIDE.md 4.3): on the respawn row, directly left of it and
	-- right of the centre road band (x 70 percent). Touch: a 48 px tall pill; desktop / gamepad: a chip like the respawn
	-- hint. Where that row is too narrow (a short desktop window) it stacks above the start ring instead (the ring only
	-- shows on the grid, RETURN only in the race, but the two never share pixels).
	local bandRight = math.ceil(0.70 * vpX)
	local rp = r.respawn
	if touch then
		local rw = math.max(HudLayoutRules.MIN_BUTTON, math.min(px(220, S), rp.x - 8 - bandRight))
		r.returnBtn = { x = rp.x - 8 - rw, y = rp.y, w = rw, h = rp.h }
	else
		local want = px(190, S)
		local room = rp.x - 8 - bandRight
		if room >= math.min(want, px(150, S)) then
			local rw = math.min(want, room)
			r.returnBtn = { x = rp.x - 8 - rw, y = rp.y, w = rw, h = rp.h }
		else
			local ring = r.startRing :: Rect
			r.returnBtn = { x = xr - want, y = ring.y - 8 - rp.h, w = want, h = rp.h }
		end
	end

	if o.battle then
		-- Row pitch (name column + score column): 20 px on touch, 34 px at S = 1 on desktop (26 at the 0.75 floor, text about 18).
		-- The board is 8 rows plus its panel padding (BOARD_PAD2).
		local rowH = math.max(17, px(if touch then 20 else 34, S))
		local pad = HudLayoutRules.BOARD_PAD2
		local boardH = 8 * rowH + pad
		if touch then
			-- The combo panel drops under the board and both stay above the respawn icon: fewer rows on a short screen.
			boardH = math.max(3 * rowH + pad, math.min(boardH, r.respawn.y - 8 - r.combo.h - 4 - m.yTop))
		end
		(r :: any).position = nil
		(r :: any).lapChip = nil
		-- v21 (hud critic 2): on a full-size desktop the board moved from the left column (a 270 px box whose rows shrank to
		-- 11 px) to the top-right, where a battle has no position or lap chip: wider, so the rows keep their 16 px text.
		-- A small desktop-kind screen (740x360 TV) keeps the old left-column box.
		if touch or vpY >= 600 then
			local bw = if touch
				then math.max(204, px(210, S)) -- "maintainer  0 HATCHED + EGG" needs about 200 px at the 12 px text floor, so the own row is not cut
				else math.clamp(round(0.27 * vpX), 260, 420)
			if not touch then
				boardH = math.max(3 * rowH + pad, math.min(boardH, r.respawn.y - 8 - r.combo.h - 4 - m.yTop))
			end
			r.battleBoard = { x = xr - bw, y = m.yTop, w = bw, h = boardH }
			r.combo.y = m.yTop + boardH + 4
		else
			local bw = math.min(math.clamp(round(0.2 * vpX), 170, 300), math.floor(0.30 * vpX) - m.x0 - 2) -- stays left of the road band
			local by = r.token.y + r.token.h + 8
			boardH = math.max(3 * rowH + pad, math.min(boardH, (r.hintChip :: Rect).y - 8 - by))
			r.battleBoard = { x = m.x0, y = by, w = bw, h = boardH }
			r.combo.y = m.yTop
			leftMax = math.max(leftMax, m.x0 + bw)
			laneLeft = math.max(laneLeft, m.x0 + bw) -- merge v21+v22: the lanes keep clear of the left-column board as before
		end
	end

	-- The whole left column as one box (item frame down to the token chip, out to the cluster / AUTO pill / battle board):
	-- the results card and the polaroid keep clear of it (it stays up in results, 6), as does the hub's lane A.
	r.leftColumn = { x = m.x0, y = itemY, w = leftMax - m.x0, h = math.max(r.token.y + r.token.h, if r.autoPill then r.autoPill.y + r.autoPill.h else 0, if r.battleBoard and r.battleBoard.x < 0.3 * vpX then r.battleBoard.y + r.battleBoard.h else 0, if r.minimap then r.minimap.y + r.minimap.h else 0) - itemY }

	-- Hub: the ADVENTURE bar (30 percent of the width, 240..520 px, 13 percent of the height, 52..96 px) in the top-right
	-- slot plus the Storm Cup line hanging 4 px under it (GarageModel.STORM_LINE_SCALE = 0.6 of the bar). TrackFlow places
	-- the bar from this rect.
	local hubW = math.clamp(0.3 * vpX, 240, 520)
	local hubBarH = math.clamp(0.13 * vpY, 52, 96)
	r.hubBar = { x = xr - hubW, y = m.yTop, w = hubW, h = hubBarH + 4 + 0.6 * hubBarH }

	-- Message lanes (7), centred on the vertical axis, narrowed so they keep 8 px from the nav and both columns.
	local cx = vpX / 2
	local rightMin = r.combo.x
	for _, k in { "position", "lapChip", "battleBoard", "item", "gear", "help", "assistChip" } do
		local rr = r[k]
		if rr and rr.x > cx and (mk or (k ~= "item" and k ~= "gear" and k ~= "help")) then
			rightMin = math.min(rightMin, rr.x)
		end
	end
	local navRight = nav.x + nav.w
	local clear = math.min(cx - (math.max(laneLeft, navRight) + 8), (rightMin - 8) - cx)
	local halfB = math.max(0, math.min(0.17 * vpX, clear))
	local laneBy = m.yTop
	if o.battle then
		local bh = math.clamp(round(0.10 * vpY), 40, 120) -- TrackFlow's plaque is never under 40 px: the lane below starts from its real height
		r.battleHud = { x = cx - halfB, y = m.yTop, w = 2 * halfB, h = bh }
		laneBy = m.yTop + bh + HudLayoutRules.BATTLE_GAP
	end
	-- v39: on a tall screen the toast chip grows with the type scale (UiSkinRules.typeScale, vpY / 540 in 1..2) so its
	-- bigger text (NotifyKit lineTextSize) has room: 48 px at 1080p, phones keep 34.
	local toastH = math.max(34, px(40, S), round(24 * math.clamp(vpY / 540, 1, 2)))
	r.laneB = { x = cx - halfB, y = laneBy, w = 2 * halfB, h = toastH }
	local noticeH = math.max(28, px(32, S))
	r.noticeStack = { x = cx - halfB, y = laneBy + toastH + 4, w = 2 * halfB, h = noticeH }
	local halfA = math.max(0, math.min(0.20 * vpX, clear))
	local aBottom = 0.30 * vpY + 0.11 * vpY
	local aTop = math.max(0.30 * vpY - 0.11 * vpY, r.noticeStack.y + noticeH + 4)
	if o.battle then
		-- Under the battle plaque, toast and notices lane A was 15 px tall on a phone (hero text unreadable): it may reach 50 percent of the height (the road band starts at 55).
		aBottom = math.min(0.50 * vpY, math.max(aBottom, aTop + 40))
	end
	r.laneA = { x = cx - halfA, y = aTop, w = 2 * halfA, h = math.max(0, aBottom - aTop) }
	-- Hub variants: lane A (lobby banner, countdown) and lane B (toast) stop 8 px short of the bar and its Storm line.
	r.hubLaneA = { x = r.laneA.x, y = r.laneA.y, w = math.max(0, math.min(r.laneA.x + r.laneA.w, r.hubBar.x - 8) - r.laneA.x), h = r.laneA.h }
	r.hubLaneB = { x = r.laneB.x, y = r.laneB.y, w = math.max(0, math.min(r.laneB.x + r.laneB.w, r.hubBar.x - 8) - r.laneB.x), h = r.laneB.h }
	-- Hub declutter (owner 2026-10-21): the pre-race vehicle pick docks at the bottom-left, left of the road band (so never over
	-- the kart) and above the steer pad / controls hint chip: a one-line chip by default, a one-row strip when expanded
	-- (client/VehiclePick). Both share the bottom edge; only one is shown at a time.
	do
		local base = if touch and r.steerPad then r.steerPad.y else (r.hintChip :: Rect).y
		local stripW = math.max(120, math.floor(0.30 * vpX) - 8 - m.x0)
		local chipH = HudLayoutRules.MIN_BUTTON
		-- Touch: the free gap between the left column and the steer pad is only 46 px at 844x390 and 36 px at 740x360, so the
		-- strip is flush (no padding, no gap to the pad), and shrinks to the gap on the shortest phones (floor
		-- VEHICLE_MIN_TOUCH = 36 px, a deliberate exception to MIN_BUTTON for this transient hub chip); desktop has room for
		-- 6 px padding and an 8 px gap.
		local pad = if touch then 0 else 6
		local gap = if touch then 0 else 8
		if touch then
			local lc = r.leftColumn
			chipH = math.clamp(base - gap - (lc.y + lc.h), HudLayoutRules.VEHICLE_MIN_TOUCH, chipH)
		end
		local stripH = chipH + 2 * pad
		r.vehicleChip = { x = m.x0, y = base - gap - chipH, w = math.min(stripW, px(230, S)), h = chipH }
		r.vehicleStrip = { x = m.x0, y = base - gap - stripH, w = stripW, h = stripH }
	end
	return r
end

-- Countdown numeral (v22 HUD polish): while the 3-2-1 / GO! runs lane A is empty, so the numeral may outgrow it. Its glyph size
-- is NUMERAL_PHONE (22 percent of the viewport height) on a phone, NUMERAL_DESKTOP (18 percent) elsewhere, centred on the
-- vertical axis with its box centre NUMERAL_CY of the height down (above the road band, so the kart stays clear). The box is
-- the glyph extent ("GO!" is the widest string, about 2.1 em wide, 1.05 em tall); it may overflow lane A sideways but never
-- overlaps the nav, minimap, token chip, item / gear / "?" column, the position / lap chips, the combo panel or the touch
-- controls: when it would, the size shrinks 6 percent at a time (down to NUMERAL_MIN) until it is clear.
HudLayoutRules.NUMERAL_PHONE = 0.22
HudLayoutRules.NUMERAL_DESKTOP = 0.18
HudLayoutRules.NUMERAL_CY = 0.33
HudLayoutRules.NUMERAL_MIN = 0.12
HudLayoutRules.NUMERAL_AVOID = {
	"nav", "minimap", "token", "item", "gear", "help", "position", "lapChip", "combo", "battleHud", "battleBoard", "respawn", "returnBtn",
	"hintChip", "autoPill", "assistChip", "steerPad", "rightZone", "startRing",
} :: { string }
function HudLayoutRules.countdownNumeral(vpX: number, vpY: number, rects: { [string]: Rect }): (number, Rect)
	local frac = if HudLayoutRules.isPhoneClass(vpY) then HudLayoutRules.NUMERAL_PHONE else HudLayoutRules.NUMERAL_DESKTOP
	local size = math.floor(frac * vpY)
	local floorSize = math.floor(HudLayoutRules.NUMERAL_MIN * vpY)
	local function box(sz: number): Rect
		local w, h = 2.1 * sz, 1.05 * sz
		local cy = HudLayoutRules.NUMERAL_CY * vpY
		local top = math.min(cy - h / 2, 0.55 * vpY - 4 - h) -- never into the road band
		return { x = vpX / 2 - w / 2, y = math.max(0, top), w = w, h = h }
	end
	local function clear(b: Rect): boolean
		for _, k in HudLayoutRules.NUMERAL_AVOID do
			local r = rects[k]
			if r and HudLayoutRules.overlap(b, r) then
				return false
			end
		end
		return true
	end
	local b = box(size)
	while size > floorSize and not clear(b) do
		size = math.max(floorSize, math.floor(size * 0.94))
		b = box(size)
	end
	return size, b
end

-- The keep-clear rects for speech bubbles (7.1 rule 3): the nav, the left and right columns, lane A while a hero message
-- is up, and the bottom-centre kart band.
function HudLayoutRules.reserved(vpX: number, vpY: number, rects: { [string]: Rect }, heroUp: boolean): { Rect }
	local out: { Rect } = { rects.nav }
	if rects.minimap then
		-- Racing (MK layout): the minimap and the token chip under it on the left, the item / gear / "?" column beside the right column.
		table.insert(out, rects.minimap)
		table.insert(out, rects.token)
		local x1 = math.min(rects.item.x, rects.gear.x, rects.help.x)
		local x2 = math.max(rects.item.x + rects.item.w, rects.gear.x + rects.gear.w, rects.help.x + rects.help.w)
		table.insert(out, { x = x1, y = rects.item.y, w = x2 - x1, h = rects.help.y + rects.help.h - rects.item.y })
	else
		local left = rects.item
		local lx2 = math.max(rects.help.x + rects.help.w, rects.token.x + rects.token.w)
		table.insert(out, { x = left.x, y = left.y, w = lx2 - left.x, h = rects.token.y + rects.token.h - left.y })
	end
	-- The right column: whatever of position / lap chip / combo / battle board exists, as one bounding rect.
	local rx1, ry1, rx2, ry2 = math.huge, math.huge, -math.huge, -math.huge
	for _, k in { "position", "lapChip", "combo", "battleBoard" } do
		local rr = rects[k]
		if rr and (k ~= "battleBoard" or rr.x > vpX / 2) then
			rx1, ry1 = math.min(rx1, rr.x), math.min(ry1, rr.y)
			rx2, ry2 = math.max(rx2, rr.x + rr.w), math.max(ry2, rr.y + rr.h)
		end
	end
	table.insert(out, { x = rx1, y = ry1, w = rx2 - rx1, h = ry2 - ry1 })
	if rects.battleBoard and rects.battleBoard.x <= vpX / 2 then
		table.insert(out, rects.battleBoard) -- the small-desktop board lives in the left column
	end
	if heroUp then
		table.insert(out, rects.laneA)
	end
	table.insert(out, { x = 0.35 * vpX, y = 0.62 * vpY, w = 0.30 * vpX, h = 0.38 * vpY })
	return out
end

-- True when the bubble rect touches none of the reserved rects.
function HudLayoutRules.bubbleClear(rect: Rect, reserved: { Rect }): boolean
	for _, r in reserved do
		if HudLayoutRules.overlap(rect, r) then
			return false
		end
	end
	return true
end

-- 7.1 rule 4: of the name labels on screen at most maxShown show, nearest first, and a label whose rect is within `gap` px
-- of a nearer shown label's rect is hidden. cands[i] = { dist, rect } (screen rect of the label); returns shown[i].
-- stay[i] (optional) marks a label that was shown last time: it ranks as STAY_BIAS of its distance, so a rival has to be
-- clearly nearer to take its slot and the set does not flicker as distances cross.
HudLayoutRules.STAY_BIAS = 0.8
function HudLayoutRules.pickLabels(cands: { { dist: number, rect: Rect } }, maxShown: number, gap: number, stay: { boolean }?): { boolean }
	local order: { number } = {}
	for i = 1, #cands do
		order[i] = i
	end
	table.sort(order, function(a: number, b: number): boolean
		local da, db = cands[a].dist, cands[b].dist
		if stay then
			da = if stay[a] then da * HudLayoutRules.STAY_BIAS else da
			db = if stay[b] then db * HudLayoutRules.STAY_BIAS else db
		end
		if da ~= db then
			return da < db
		end
		return a < b
	end)
	local shown: { boolean } = {}
	local kept: { Rect } = {}
	for _, i in order do
		local ok = #kept < maxShown
		if ok then
			local grown = HudLayoutRules.grow(cands[i].rect, gap)
			for _, k in kept do
				if HudLayoutRules.overlap(grown, k) then
					ok = false
					break
				end
			end
		end
		shown[i] = ok
		if ok then
			table.insert(kept, cands[i].rect)
		end
	end
	return shown
end

-- The thumb exclusion rects on touch (4.1): steer pad and right zone grown by THUMB_GROW, the start ring as is.
function HudLayoutRules.thumbExclusion(rects: { [string]: Rect }): { Rect }
	local out: { Rect } = {}
	if rects.steerPad then
		table.insert(out, HudLayoutRules.grow(rects.steerPad, HudLayoutRules.THUMB_GROW))
	end
	if rects.rightZone then
		table.insert(out, HudLayoutRules.grow(rects.rightZone, HudLayoutRules.THUMB_GROW))
	end
	if rects.startRing and rects.rightZone then
		table.insert(out, rects.startRing)
	end
	return out
end

------------------------------------------------------------------------------------------------------------------------
-- Position readout text
------------------------------------------------------------------------------------------------------------------------

-- 1 -> "ST", 2 -> "ND", 3 -> "RD", else "TH" (11, 12, 13 are TH).
function HudLayoutRules.ordinal(n: number): string
	local last, last2 = n % 10, n % 100
	if last2 >= 11 and last2 <= 13 then
		return "TH"
	elseif last == 1 then
		return "ST"
	elseif last == 2 then
		return "ND"
	elseif last == 3 then
		return "RD"
	end
	return "TH"
end

-- GridOrder.plankText ("3/8", or "-/8" on the grid before a seat is known) as (numeral, suffix, "/8").
function HudLayoutRules.positionParts(text: string): (string, string, string)
	local num, total = string.match(text, "^(.-)/(%d+)$")
	if not num or not total then
		return text, "", ""
	end
	local n = tonumber(num)
	return num, if n then HudLayoutRules.ordinal(n) else "", "/" .. total
end

------------------------------------------------------------------------------------------------------------------------
-- Input glyph rule (8)
------------------------------------------------------------------------------------------------------------------------

local function family(inputType: string): string
	if string.find(inputType, "Gamepad", 1, true) then
		return "gamepad"
	elseif inputType == "Touch" then
		return "touch"
	elseif inputType == "Keyboard" then
		return "keyboard"
	elseif string.find(inputType, "Mouse", 1, true) then
		return "mouse"
	end
	return "other"
end

-- A mouse on a touch-enabled device that has no keyboard, or on a phone-class viewport (the Studio phone emulator
-- delivers mouse events), is not evidence of a desktop.
function HudLayoutRules.touchLike(touchEnabled: boolean, keyboardEnabled: boolean, vpY: number): boolean
	return touchEnabled and (not keyboardEnabled or HudLayoutRules.isPhoneClass(vpY))
end

-- Whether a mouse event may switch InputMode away from Touch (5 and 8: mouse movement alone never does on a touch device).
function HudLayoutRules.ignoreMouse(inputType: string, touchEnabled: boolean, keyboardEnabled: boolean, vpY: number): boolean
	return family(inputType) == "mouse" and HudLayoutRules.touchLike(touchEnabled, keyboardEnabled, vpY)
end

-- Which key badges to draw, from the last input type name.
function HudLayoutRules.glyphMode(lastInput: string, touchEnabled: boolean, keyboardEnabled: boolean, vpY: number): Glyphs
	local f = family(lastInput)
	if f == "gamepad" then
		return "gamepad"
	elseif f == "keyboard" then
		return "keyboard"
	elseif f == "mouse" then
		return if HudLayoutRules.touchLike(touchEnabled, keyboardEnabled, vpY) then "none" else "keyboard"
	end
	return "none"
end

return HudLayoutRules
