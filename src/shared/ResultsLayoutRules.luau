--!strict
-- Where the photo-finish polaroid docks next to the results card (UI polish: it used to hang 22 px over the card's left
-- edge and cover a row). Pure: no Instances; specced in tools/tests/results_layout_spec.luau. client/Polaroid feeds it
-- the viewport, the card's width and top edge and client/SafeArea's insets, and applies the answer in card coordinates.
local ResultsLayoutRules = {}

ResultsLayoutRules.CARD_W = 118 -- the polaroid at scale 1 (client/Polaroid CARD_W / CARD_H)
ResultsLayoutRules.CARD_H = 140
ResultsLayoutRules.TILT_DEG = 7 -- its resting rotation; the layout budgets the tilted bounding box
ResultsLayoutRules.GAP = 8 -- clear space between the card and the polaroid's tilted box, and to the screen edge
ResultsLayoutRules.MIN_SCALE = 0.6 -- smaller than this the photo is unreadable: it stays away rather than overlap
ResultsLayoutRules.MAX_SCALE = 1.7
ResultsLayoutRules.BASE_HEIGHT = 400 -- scale 1 at this viewport height; 680 and up hit MAX_SCALE

export type Insets = { left: number, top: number, right: number, bottom: number }
export type Placement = {
	side: string, -- "left" | "right" | "none"
	scale: number,
	x: number, -- offset from the results card's left edge to the polaroid's NEAR edge (negative = left of the card)
	y: number, -- offset from the results card's top edge to the polaroid's top
}

-- Width and height of the tilted polaroid's bounding box at this scale.
function ResultsLayoutRules.tiltedBox(scale: number): (number, number)
	local r = math.rad(ResultsLayoutRules.TILT_DEG)
	local w, h = ResultsLayoutRules.CARD_W * scale, ResultsLayoutRules.CARD_H * scale
	return w * math.cos(r) + h * math.sin(r), h * math.cos(r) + w * math.sin(r)
end

-- Desktop results card scale (v22 HUD polish): the card's contents are laid out for a 420 x 252 design size (phones show it 1:1);
-- on a desktop-class viewport (height >= 600) RaceUI applies this as a UIScale so the card is about 30% of the viewport width
-- (420 px up to MAX_DESKTOP_W) with row text near 18 px at 1080p, and it also grows with the height. 1.0 on phones.
ResultsLayoutRules.DESKTOP_MIN_H = 600
ResultsLayoutRules.DESKTOP_W_SHARE = 0.30
ResultsLayoutRules.DESIGN_W = 420
ResultsLayoutRules.MAX_DESKTOP_K = 1.52 -- 420 * 1.52 = 638 px
function ResultsLayoutRules.desktopScale(vpW: number, vpH: number): number
	if vpH < ResultsLayoutRules.DESKTOP_MIN_H then
		return 1
	end
	return math.clamp(math.max(ResultsLayoutRules.DESKTOP_W_SHARE * vpW / ResultsLayoutRules.DESIGN_W, vpH / 720), 1, ResultsLayoutRules.MAX_DESKTOP_K)
end

-- The results card's rectangle for this viewport (client/RaceUI sizes it from this; client/TrackFlow places the return
-- countdown from it): width, top edge (px from the viewport top), height and the centre x. plaqueScale mirrors RaceUI's.
-- leftReserve = the right edge (px) of the HUD's left column (HudLayoutRules rects.leftColumn: item, gear, "?", token, AUTO
-- pill), which stays up in results (HUD_LAYOUT 6): the card keeps GAP clear of it, shifting right of centre (never narrower
-- than 300) instead of covering the gear and "?". Without it the card is centred, as before.
function ResultsLayoutRules.cardRect(vpW: number, vpH: number, insets: Insets, leftReserve: number?): (number, number, number, number, number)
	local k = ResultsLayoutRules.desktopScale(vpW, vpH)
	local plaque = if vpH >= 600 then 1.85 elseif vpH <= 375 then 1.05 else 1.18
	local w = math.clamp(vpW - 64, 300, 420) * k
	-- 240 px is the least the card's contents need (rows end at 184, the buttons take the bottom 50): a 220 px card had its fourth
	-- row under FLY AGAIN / HUB on a 340 px high viewport (the Studio phone emulator's 360 less its status strip).
	local h = math.clamp(vpH - 110, 240, 252) * k
	-- ... and on a short screen the card rises so that the return countdown still fits under it.
	local top = math.min(math.floor(58 * plaque) + insets.top, vpH - insets.bottom - ResultsLayoutRules.GAP - ResultsLayoutRules.COUNTDOWN_H - ResultsLayoutRules.GAP - h)
	top = math.max(top, insets.top)
	local left = (vpW - w) / 2
	if leftReserve then
		local G = ResultsLayoutRules.GAP
		local rightBound = vpW - insets.right - G
		left = math.max(left, leftReserve + G)
		w = math.clamp(rightBound - left, 300 * k, w)
		left = math.max(leftReserve + G, math.min(left, rightBound - w))
	end
	return w, top, h, left + w / 2, k
end

ResultsLayoutRules.COUNTDOWN_H = 22 -- the return countdown's line height under the card

-- Top edge (px) of the "Back to Central Island in N" line while the results card is up: just under the card, so it
-- never crosses the FLY AGAIN / HUB buttons (they sit in the card's bottom 50 px), pulled up only if the viewport
-- bottom (and its inset) would clip it.
function ResultsLayoutRules.countdownTop(vpH: number, cardTop: number, cardH: number, insets: Insets): number
	local G = ResultsLayoutRules.GAP
	return math.min(cardTop + cardH + G, vpH - insets.bottom - G - ResultsLayoutRules.COUNTDOWN_H)
end

-- vpW, vpH: viewport. cardW: the results card's width, cardTop: its top edge in px from the viewport top. cardLeftX: the
-- card's left edge (default: centred); leftReserve: the HUD left column's right edge, which the photo keeps clear of too.
function ResultsLayoutRules.place(vpW: number, vpH: number, cardW: number, cardTop: number, insets: Insets, cardLeftX: number?, leftReserve: number?): Placement
	local G = ResultsLayoutRules.GAP
	local cardLeft = cardLeftX or (vpW - cardW) / 2
	local leftRoom = cardLeft - math.max(insets.left, leftReserve or 0) - 2 * G
	local rightRoom = (vpW - cardLeft - cardW) - insets.right - 2 * G
	local side = if leftRoom >= rightRoom then "left" else "right"
	local room = math.max(leftRoom, rightRoom)
	local bw1, bh1 = ResultsLayoutRules.tiltedBox(1)
	local roomH = vpH - cardTop - insets.bottom - G
	local s = math.min(math.clamp(vpH / ResultsLayoutRules.BASE_HEIGHT, 0.85, ResultsLayoutRules.MAX_SCALE), room / bw1, roomH / bh1)
	if s < ResultsLayoutRules.MIN_SCALE then
		return { side = "none", scale = 0, x = 0, y = 0 }
	end
	local bw, bh = ResultsLayoutRules.tiltedBox(s)
	local pad = (bw - ResultsLayoutRules.CARD_W * s) / 2 -- the tilt's overhang beside the polaroid
	local x = if side == "left" then -(G + pad) else cardW + G + pad
	local y = (bh - ResultsLayoutRules.CARD_H * s) / 2 -- the tilt's overhang above it, so the box top sits on the card top
	return { side = side, scale = s, x = x, y = y }
end

return ResultsLayoutRules
