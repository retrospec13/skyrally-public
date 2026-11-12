-- Polaroid docking beside the results card (shared/ResultsLayoutRules): at the four reference viewports the tilted
-- photo never touches the card, stays inside the safe insets and the screen, and scales with the viewport.
return function(h)
	local R = h.require("src/shared/ResultsLayoutRules.luau")
	local none = { left = 0, top = 0, right = 0, bottom = 0 }

	-- RaceUI's card: width clamp(vp.X - 64, 300, 420), top = floor(58 * plaqueScale) + inset.top
	local function card(vpX: number, vpY: number): (number, number)
		local plaque = if vpY >= 600 then 1.85 else (if vpY <= 375 then 1.05 else 1.18)
		return math.clamp(vpX - 64, 300, 420), math.floor(58 * plaque)
	end

	local sizes = { { 740, 360 }, { 844, 390 }, { 1440, 900 }, { 1920, 1080 } }
	for _, vp in sizes do
		h.test(string.format("place: %dx%d docks clear of the card, on screen", vp[1], vp[2]), function()
			local cw, top = card(vp[1], vp[2])
			local p = R.place(vp[1], vp[2], cw, top, none)
			h.ok(p.side ~= "none", "photo has room")
			h.ok(p.scale >= R.MIN_SCALE and p.scale <= R.MAX_SCALE)
			local bw, bh = R.tiltedBox(p.scale)
			local cardLeft = (vp[1] - cw) / 2
			local left, right
			if p.side == "left" then
				right = cardLeft + p.x
				left = right - R.CARD_W * p.scale
			else
				left = cardLeft + p.x
				right = left + R.CARD_W * p.scale
			end
			local pad = (bw - R.CARD_W * p.scale) / 2
			if p.side == "left" then
				h.ok(right + pad <= cardLeft - R.GAP + 1e-6, "tilted box clear of the card")
				h.ok(left - pad >= R.GAP - 1e-6, "inside the screen edge")
			else
				h.ok(left - pad >= cardLeft + cw + R.GAP - 1e-6, "tilted box clear of the card")
				h.ok(right + pad <= vp[1] - R.GAP + 1e-6, "inside the screen edge")
			end
			h.ok(top + p.y + bh <= vp[2], "inside the screen bottom")
		end)
	end

	h.test("place: scale grows with the viewport height", function()
		local small = R.place(844, 390, 420, 68, none)
		local big = R.place(1920, 1080, 420, 107, none)
		h.ok(big.scale > small.scale)
		h.ok(big.scale <= R.MAX_SCALE)
	end)

	h.test("place: safe insets shrink the room (notch on the left pushes it to the right side or smaller)", function()
		local wide = R.place(740, 360, 420, 60, none)
		local notch = R.place(740, 360, 420, 60, { left = 60, top = 0, right = 0, bottom = 0 })
		h.eq(wide.side, "left")
		h.eq(notch.side, "right")
	end)

	h.test("place: a card that leaves no room hides the photo instead of overlapping", function()
		h.eq(R.place(500, 360, 420, 60, none).side, "none")
		h.eq(R.place(1000, 360, 420, 60, { left = 300, top = 0, right = 300, bottom = 0 }).side, "none")
	end)
	h.test("cardRect: matches RaceUI's plaque tiers and adds the top inset", function()
		local w, top, ch = R.cardRect(844, 390, none)
		h.eq(w, 420)
		h.eq(top, 68)
		h.eq(ch, 252)
		local _, top2 = R.cardRect(844, 390, { left = 0, top = 10, right = 0, bottom = 0 })
		h.eq(top2, 78)
		local w3, _, h3 = R.cardRect(740, 360, none)
		h.eq(w3, 420)
		h.eq(h3, 250)
	end)

	h.test("cardRect: desktop scales the card (about 57% of the width, a taller design frame), phones stay 1:1", function()
		local _, _, _, _, kPhone = R.cardRect(844, 390, none)
		h.eq(kPhone, 1)
		local _, _, _, _, kPhone2 = R.cardRect(740, 360, none)
		h.eq(kPhone2, 1)
		local w768, _, h768, _, k768 = R.cardRect(1366, 768, none)
		h.ok(w768 >= 0.5 * 1366 and w768 <= 0.62 * 1366 and k768 > 1, "1366x768 card about 57% of the width")
		h.ok(math.abs(h768 - R.DESKTOP_DESIGN_H * k768) < 1e-6, "height scales with the width")
		h.ok(h768 + 120 <= 768, "1366x768 card and countdown fit")
		local w1080, top1080, h1080, _, k1080 = R.cardRect(1920, 1080, none)
		h.ok(w1080 >= 1000 and w1080 <= 1150, "1080p card about 55-60% wide")
		h.ok(12 * k1080 >= 17, "row text at least 17 px at 1080p")
		h.ok(top1080 + h1080 + R.COUNTDOWN_H + 2 * R.GAP <= 1080, "countdown still fits under the card")
		local _, _, _, _, kBig = R.cardRect(3840, 2160, none)
		h.ok(420 * kBig <= 420 * R.MAX_DESKTOP_K + 1e-6, "clamped at MAX_DESKTOP_K")
		for _, vp in { { 1862, 832 }, { 1600, 700 }, { 1280, 720 } } do
			local _, t, hh = R.cardRect(vp[1], vp[2], none)
			h.ok(t >= 0 and t + hh + R.COUNTDOWN_H + R.GAP <= vp[2], "short desktop window: card on screen " .. vp[1] .. "x" .. vp[2])
		end
	end)

	h.test("countdownTop: under the card, clear of the buttons, on screen, at the reference viewports", function()
		for _, vp in sizes do
			local ins = { left = 0, top = 0, right = 0, bottom = 12 }
			local _, top, ch = R.cardRect(vp[1], vp[2], ins)
			local y = R.countdownTop(vp[2], top, ch, ins)
			h.ok(y >= top + ch or y + R.COUNTDOWN_H <= vp[2] - ins.bottom, "not over the card's buttons or off screen")
			h.ok(y + R.COUNTDOWN_H <= vp[2] - ins.bottom + 1e-6, "inside the bottom inset")
		end
		local _, top, ch = R.cardRect(844, 390, none)
		h.eq(R.countdownTop(390, top, ch, none) >= top + ch, true)
	end)
end
