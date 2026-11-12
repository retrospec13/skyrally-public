-- HudLayoutRules: the section 4.1 collision obligations of docs/design/HUD_LAYOUT.md at the four viewports, with and without
-- insets (none, phone notch, TV 5 percent), over several nav widths and both input kinds; S bounds, size floors, the
-- bubble guard, the position text and the input glyph truth table.
return function(h)
	local R = h.require("src/shared/HudLayoutRules.luau")
	local none = { left = 0, top = 0, right = 0, bottom = 0 }
	local function tv(vx, vy)
		return {
			left = math.floor(vx * 0.05 + 0.5),
			top = math.floor(vy * 0.05 + 0.5),
			right = math.floor(vx * 0.05 + 0.5),
			bottom = math.floor(vy * 0.05 + 0.5),
		}
	end
	local viewports = {
		{ 1920, 1080, "1920x1080", { left = 0, top = 0, right = 0, bottom = 0 } },
		{ 1366, 768, "1366x768", { left = 0, top = 0, right = 0, bottom = 0 } },
		{ 844, 390, "844x390", { left = 47, top = 0, right = 47, bottom = 21 } },
		{ 740, 360, "740x360", { left = 44, top = 0, right = 44, bottom = 20 } },
	}

	-- Every inset case for a viewport: none, its device notch, the TV margin.
	local function insetCases(vp)
		return { { "no insets", none }, { "device insets", vp[4] }, { "TV 5 percent", tv(vp[1], vp[2]) } }
	end

	local function names(rects)
		local out = {}
		for n in rects do
			table.insert(out, n)
		end
		table.sort(out)
		return out
	end

	local function around(rects)
		local list = {}
		for _, n in R.HUD_ELEMENTS do
			if rects[n] then
				list[n] = rects[n]
			end
		end
		for _, n in R.TOUCH_ELEMENTS do
			if rects[n] then
				list[n] = rects[n]
			end
		end
		return list
	end

	h.test("S: clamped 0.6..1 and 1080 is 1", function()
		h.eq(R.scale(1080), 1)
		h.eq(R.scale(2160), 1)
		h.eq(R.scale(390), 0.6)
		h.eq(R.scale(100), 0.6)
		h.ok(math.abs(R.scale(768) - 0.7111) < 1e-3)
		for vy = 200, 2400, 50 do
			local s = R.scale(vy)
			h.ok(s >= 0.6 and s <= 1.0, "S in bounds at " .. vy)
		end
	end)

	h.test("S: desktop floor 0.75 (1.25 x the phone scale), phone class and touch keep 0.6", function()
		h.eq(R.scale(768, "desktop"), 0.75)
		h.eq(R.scale(600, "desktop"), 0.75)
		h.eq(R.scale(1080, "desktop"), 1)
		h.eq(R.scale(768, "touch"), R.scale(768))
		h.eq(R.scale(370, "desktop"), 0.6) -- the emulator in keyboard mode is still a phone-sized viewport
		h.eq(R.scale(450, "desktop"), 0.6)
		h.ok(R.scale(451, "desktop") >= 0.75)
		local d = R.compute(1366, 768, none, R.fallbackNav(1366, 768), "desktop")
		h.ok(d.lapChip.w >= 142 and d.item.w >= 90, "desktop chips are at least 0.75 of the 1080p size")
		h.eq(d.item.y - (d.nav.y + d.nav.h), 8) -- 8 px under the Roblox nav
	end)

	h.test("leaderboard reserve: desktop keeps the right column left of the Roblox player list, touch and a hidden list change nothing", function()
		h.eq(R.rightLimitWithPlayerList(nil, 1365, "touch", true), nil)
		h.eq(R.rightLimitWithPlayerList(nil, 1365, "desktop", false), nil)
		h.eq(R.rightLimitWithPlayerList(1365, 1365, "desktop", false), 1365)
		h.eq(R.rightLimitWithPlayerList(1365, 1365, "desktop", true), 1365 - R.PLAYER_LIST_W)
		h.eq(R.rightLimitWithPlayerList(1000, 1365, "desktop", true), 1000)
		for _, vp in viewports do
			if vp[2] > R.PHONE_CLASS_Y then
				for _, battle in { false, true } do
					local lim = R.rightLimitWithPlayerList(vp[1], vp[1], "desktop", true)
					local r = R.compute(vp[1], vp[2], vp[4], R.fallbackNav(vp[1], vp[2]), "desktop", { battle = battle, rightLimit = lim })
					local list = { x = lim, y = 0, w = vp[1] - lim, h = vp[2] }
					for _, n in { "position", "lapChip", "combo", "respawn", "startRing", "hubBar", "battleBoard" } do
						local rect = r[n]
						if rect and (n ~= "battleBoard" or false) then
							h.ok(rect.x + rect.w <= lim, n .. " left of the leaderboard at " .. vp[3])
							h.ok(not R.overlap(rect, list), n .. " clear of the leaderboard at " .. vp[3])
						end
					end
					local ns = names(around(r))
					for i = 1, #ns do
						for j = i + 1, #ns do
							h.ok(not R.overlap(r[ns[i]], r[ns[j]]), ns[i] .. " overlaps " .. ns[j] .. " with the reserve at " .. vp[3])
						end
					end
				end
			end
		end
	end)

	h.test("battle: lane B is at least 6 px under the timer plaque (which is never under 40 px)", function()
		for _, vp in viewports do
			for _, kind in { "touch", "desktop" } do
				local r = R.compute(vp[1], vp[2], vp[4], R.fallbackNav(vp[1], vp[2]), kind, { battle = true })
				h.ok(r.battleHud.h >= 40, "plaque >= 40 at " .. vp[3])
				h.ok(r.laneB.y - (r.battleHud.y + r.battleHud.h) >= 6, "gap >= 6 at " .. vp[3] .. " " .. kind)
			end
		end
	end)

	h.test("metrics: margins and the safe rect (3.1)", function()
		local m = R.metrics(1920, 1080, none)
		h.eq({ m.M, m.topM, m.bottomM, m.x0, m.xr, m.yTop, m.yBot }, { 24, 8, 22, 24, 1896, 8, 1058 })
		local p = R.metrics(844, 390, { left = 47, top = 0, right = 47, bottom = 21 })
		h.eq({ p.M, p.bottomM, p.x0, p.xr, p.yBot }, { 14, 10, 61, 783, 359 })
		h.eq(R.metrics(300, 200, none).M, 14) -- never under 12
	end)

	h.test("spec table: phone 844x390 anchors (item, gear, token, respawn)", function()
		local ins = { left = 47, top = 0, right = 47, bottom = 21 }
		local r = R.compute(844, 390, ins, R.fallbackNav(844, 390), "touch")
		h.eq({ r.position.x, r.position.w, r.lapChip.x, r.lapChip.w }, { 693, 90, 669, 114 })
		h.eq({ r.item.x, r.item.y, r.item.w }, { 61, 84, 72 })
		h.eq({ r.gear.x, r.gear.y, r.gear.w }, { 141, 84, 44 })
		h.eq({ r.token.x, r.token.y, r.token.w, r.token.h }, { 61, 160, 96, 28 })
		h.eq({ r.respawn.x, r.respawn.w }, { 735, 48 })
		local d = R.compute(1920, 1080, none, R.fallbackNav(1920, 1080), "desktop")
		h.eq({ d.position.x, d.position.y, d.position.w, d.position.h }, { 1746, 8, 150, 84 })
		h.eq({ d.item.x, d.item.y, d.item.w }, { 24, 66, 120 })
		h.eq({ d.respawn.x, d.respawn.y, d.respawn.w, d.respawn.h }, { 1726, 1022, 170, 36 })
	end)

	h.test("MK layout (HUD_MK_LAYOUT.md 3, UI_V2): racing anchors per viewport class (desktop: item box top centre-left, hero position bottom-right; touch: item / gear / ? column left of the right column; minimap in the corner)", function()
		local function nav(vp)
			return R.fallbackNav(vp[1], vp[2])
		end
		local function at(vp, kind)
			return R.compute(vp[1], vp[2], vp[4], nav(vp), kind, { minimap = true })
		end
		local t = at(viewports[3], "touch")
		h.eq({ t.minimap.x, t.minimap.y, t.minimap.w }, { 61, 84, 90 }, "844x390 minimap")
		h.eq({ t.token.x, t.token.y, t.token.w }, { 159, 84, 96 }, "844x390 token right of the minimap")
		h.eq({ t.item.x, t.item.y, t.item.w }, { 601, 5, 60 }, "844x390 item (UI v2: 60 px box)")
		h.eq({ t.gear.x, t.gear.y, t.help.x, t.help.y }, { 617, 69, 617, 117 }, "844x390 gear and help under the item")
		h.ok(t.laneA.w >= 300 and t.laneB.w >= 280, "844x390 lanes widened: " .. t.laneA.w .. "/" .. t.laneB.w)
		local c = at(viewports[4], "touch")
		h.eq({ c.minimap.w, c.item.w, c.item.x }, { 64, 52, 508 }, "740x360 compact")
		h.ok(c.laneA.w >= 200 and c.laneB.w >= 200, "740x360 lanes")
		local d = at(viewports[2], "desktop")
		h.eq({ d.minimap.x, d.minimap.y, d.minimap.w }, { 18, 66, 169 }, "1366x768 minimap directly under the nav")
		h.eq({ d.item.x, d.item.y, d.item.w }, { 212, 6, 113 }, "1366x768 item box top centre-left (UI v2)")
		h.eq({ d.position.x, d.position.y, d.position.w, d.position.h }, { 1153, 587, 195, 128 }, "1366x768 hero position bottom-right (UI v2)")
		local f = at(viewports[1], "desktop")
		h.eq({ f.minimap.y, f.item.x, f.item.y, f.item.w, f.gear.y, f.help.y }, { 66, 256, 8, 150, 8, 72 }, "1920x1080")
		h.eq({ f.position.x, f.position.y, f.position.w, f.position.h, f.lapChip.y }, { 1636, 844, 260, 170, 8 }, "1920x1080 hero position bottom-right, lap chip top-right")
		-- Not racing, nothing moved: the left column keeps the item frame, gear and ? (hub, results, battle).
		local hub = R.compute(844, 390, viewports[3][4], nav(viewports[3]), "touch")
		h.eq({ hub.item.x, hub.item.y, hub.item.w }, { 61, 84, 72 }, "left column unchanged without the minimap")
	end)

	h.test("controls hint chip (4.2): desktop only, bottom-left corner, left of the road band, clear of respawn, inside the safe rect", function()
		local function overlap(a, b)
			return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
		end
		for _, vp in viewports do
			for _, case in insetCases(vp) do
				local label = vp[3] .. " " .. case[1]
				local t = R.compute(vp[1], vp[2], case[2], R.fallbackNav(vp[1], vp[2]), "touch")
				h.ok(t.hintChip == nil, "never on touch " .. label)
				local d = R.compute(vp[1], vp[2], case[2], R.fallbackNav(vp[1], vp[2]), "desktop")
				local c = d.hintChip
				h.ok(c ~= nil and c.w >= 150 and c.h >= 34, "hint chip big enough " .. label)
				local m = R.metrics(vp[1], vp[2], case[2], "desktop")
				h.ok(c.x >= m.x0 and c.y + c.h <= m.yBot, "hint chip inside the safe rect " .. label)
				h.ok(c.x + c.w <= 0.30 * vp[1], "hint chip left of the road band " .. label)
				h.ok(c.y > vp[2] / 2, "hint chip in the lower half " .. label)
				h.ok(not overlap(c, d.respawn) and not overlap(c, d.item) and not overlap(c, d.token), "hint chip clear of respawn and the left column " .. label)
				h.ok(not overlap(c, R.roadBand(vp[1], vp[2])), "hint chip outside the road band " .. label)
			end
		end
		local d = R.compute(1920, 1080, none, R.fallbackNav(1920, 1080), "desktop")
		h.eq({ d.hintChip.x, d.hintChip.y, d.hintChip.w, d.hintChip.h }, { 24, 1014, 420, 44 })
	end)

	h.test("RETURN to course (FLIGHT_GUIDE.md 4.3): left of respawn on its row, right of the road band, a real touch target", function()
		local ins = { left = 47, top = 0, right = 47, bottom = 21 }
		local t = R.compute(844, 390, ins, R.fallbackNav(844, 390), "touch")
		h.eq({ t.returnBtn.x, t.returnBtn.y, t.returnBtn.w, t.returnBtn.h }, { 595, t.respawn.y, 132, 48 }, "phone anchor")
		local d = R.compute(1920, 1080, none, R.fallbackNav(1920, 1080), "desktop")
		h.eq({ d.returnBtn.x, d.returnBtn.y, d.returnBtn.w, d.returnBtn.h }, { 1528, 1022, 190, 36 }, "desktop anchor")
		for _, vp in viewports do
			for _, case in insetCases(vp) do
				for _, kind in { "touch", "desktop" } do
					local label = vp[3] .. " " .. case[1] .. " " .. kind
					local r = R.compute(vp[1], vp[2], case[2], R.fallbackNav(vp[1], vp[2]), kind)
					local b = r.returnBtn
					h.ok(b ~= nil, "returnBtn exists " .. label)
					h.ok(not R.overlap(b, R.roadBand(vp[1], vp[2])), "returnBtn outside the road band " .. label)
					h.ok(not R.overlap(b, r.respawn), "returnBtn clear of respawn " .. label)
					h.ok(b.x >= 0.70 * vp[1] - 1e-6, "returnBtn right of the centre band " .. label)
					if kind == "touch" then
						h.ok(b.w >= R.MIN_BUTTON and b.h >= R.MIN_BUTTON, "touch target " .. label)
						h.ok(b.y == r.respawn.y and b.x + b.w <= r.respawn.x - 8 + 1e-6, "on the respawn row, left of it " .. label)
					else
						h.ok(b.w >= 88, "desktop chip wide enough for \"[ENTER] RETURN\" " .. label)
					end
				end
			end
		end
	end)

	for _, vp in viewports do
		for _, case in insetCases(vp) do
			for _, kind in { "touch", "desktop" } do
				for _, navW in { 150, 190, 200, 260 } do
					for _, battle in { false, true } do
						local label = string.format("%s %s %s nav%d%s", vp[3], case[1], kind, navW, if battle then " battle" else "")
						h.test("collisions: " .. label, function()
							local ins = case[2]
							local nav = { x = 0, y = 0, w = navW, h = if vp[2] <= 450 then 76 else 58 }
							local rects = R.compute(vp[1], vp[2], ins, nav, kind, { battle = battle })
							local list = around(rects)
							if battle then
								list.battleHud = rects.battleHud
								list.battleBoard = rects.battleBoard
								h.ok(rects.position == nil and rects.lapChip == nil, "position and lap chip are hidden in a battle")
							else
								h.ok(rects.battleHud == nil and rects.battleBoard == nil)
							end
							local safe = { x = ins.left, y = ins.top, w = vp[1] - ins.left - ins.right, h = vp[2] - ins.top - ins.bottom }
							local band = R.roadBand(vp[1], vp[2])
							local ns = names(list)
							for _, n in ns do
								local rect = list[n]
								h.ok(rect.w > 0 and rect.h > 0, n .. " has a size: " .. rect.w .. "x" .. rect.h)
								h.ok(R.contains(safe, rect), n .. " inside the safe rect")
								h.ok(not R.overlap(rect, nav), n .. " clear of the Roblox nav")
							end
							-- no two overlap
							for i = 1, #ns do
								for j = i + 1, #ns do
									h.ok(not R.overlap(list[ns[i]], list[ns[j]]), ns[i] .. " overlaps " .. ns[j])
								end
							end
							-- nothing in the centre road band (the thumb controls and the start ring are what the band is made around)
							for _, n in R.HUD_ELEMENTS do
								local rect = list[n]
								if rect then
									h.ok(not R.overlap(rect, band), n .. " enters the centre road band")
								end
							end
							h.ok(list.battleHud == nil or not R.overlap(list.battleHud, band))
							h.ok(list.battleBoard == nil or not R.overlap(list.battleBoard, band), "battle board clear of the road band")
							-- thumb exclusion on touch
							if kind == "touch" then
								for _, ex in R.thumbExclusion(rects) do
									for _, n in R.HUD_ELEMENTS do
										if list[n] then
											h.ok(not R.overlap(list[n], ex), n .. " enters a thumb exclusion rect")
										end
									end
									h.ok(not R.overlap(list.autoPill, ex), "autoPill enters a thumb exclusion rect")
								end
							else
								h.ok(rects.steerPad == nil and rects.rightZone == nil and rects.autoPill == nil)
							end
						end)
					end
				end
			end
		end
	end

	-- Hub (bar + Storm line) and results (card + polaroid) obligations: the phases that share the screen with the left
	-- cluster (results) or the top-right slot (hub).
	local Results = h.require("src/shared/ResultsLayoutRules.luau")
	for _, vp in viewports do
		for _, case in insetCases(vp) do
			for _, kind in { "touch", "desktop" } do
				for _, navW in { 150, 190, 200, 260 } do
					h.test(string.format("hub + results: %s %s %s nav%d", vp[3], case[1], kind, navW), function()
						local ins = case[2]
						local nav = { x = 0, y = 0, w = navW, h = if vp[2] <= 450 then 76 else 58 }
						local rects = R.compute(vp[1], vp[2], ins, nav, kind)
						local safe = { x = ins.left, y = ins.top, w = vp[1] - ins.left - ins.right, h = vp[2] - ins.top - ins.bottom }
						-- hub: bar + Storm line fit the safe rect, clear of the nav and the left column; lanes stop short of it
						h.ok(R.contains(safe, rects.hubBar), "hubBar inside the safe rect")
						h.ok(not R.overlap(rects.hubBar, nav), "hubBar clear of the nav")
						h.ok(not R.overlap(rects.hubBar, rects.leftColumn), "hubBar clear of the left column")
						h.ok(not R.overlap(rects.hubLaneA, rects.hubBar), "hub lane A overlaps the bar / Storm line")
						h.ok(not R.overlap(rects.hubLaneB, rects.hubBar), "hub lane B overlaps the bar / Storm line")
						h.ok(rects.hubLaneA.w >= 160, "hub lane A not squeezed away")
						-- results: the card (and the polaroid beside it) keep clear of the left column
						local col = rects.leftColumn
						local reserve = col.x + col.w
						local cw, top, ch, cx = Results.cardRect(vp[1], vp[2], ins, reserve)
						local card = { x = cx - cw / 2, y = top, w = cw, h = ch }
						h.ok(not R.overlap(card, col), "results card overlaps the left column")
						h.ok(cw >= 300 or vp[1] < 364, "card keeps its 300 px minimum")
						h.ok(card.x + card.w <= vp[1] - ins.right + 1e-6, "card inside the right inset")
						local p = Results.place(vp[1], vp[2], cw, top, ins, card.x, reserve)
						if p.side ~= "none" then
							local bw, bh = Results.tiltedBox(p.scale)
							local pw = Results.CARD_W * p.scale
							local near = if p.side == "left" then card.x + p.x - pw else card.x + p.x
							local pad = (bw - pw) / 2
							local photo = { x = near - pad, y = top, w = bw, h = bh }
							h.ok(not R.overlap(photo, col), "polaroid overlaps the left column")
							h.ok(not R.overlap(photo, card), "polaroid overlaps the card")
							h.ok(photo.x >= ins.left - 1e-6 and photo.x + photo.w <= vp[1] - ins.right + 1e-6, "polaroid inside the insets")
						end
					end)
				end
			end
		end
	end

	-- v22: the countdown numeral is 22 percent of the height on phones (18 desktop), centred above the kart, clear of the minimap,
	-- the token chip, the item / gear / "?" column and the position / lap chips.
	for _, vp in viewports do
		for _, case in insetCases(vp) do
			for _, kind in { "touch", "desktop" } do
				for _, navW in { 150, 260 } do
					h.test(string.format("countdown numeral: %s %s %s nav%d clear of the HUD", vp[3], case[1], kind, navW), function()
						local nav = { x = 0, y = 0, w = navW, h = if vp[2] <= 450 then 76 else 58 }
						local rects = R.compute(vp[1], vp[2], case[2], nav, kind)
						local size, box = R.countdownNumeral(vp[1], vp[2], rects)
						local frac = if R.isPhoneClass(vp[2]) then R.NUMERAL_PHONE else R.NUMERAL_DESKTOP
						h.ok(size >= math.floor(R.NUMERAL_MIN * vp[2]), "numeral not shrunk away")
						h.ok(size <= math.floor(frac * vp[2]), "numeral not above its share of the height")
						h.ok(math.abs(box.x + box.w / 2 - vp[1] / 2) < 1, "centred")
						h.ok(box.y + box.h <= 0.55 * vp[2], "above the road band / kart")
						for _, n in R.NUMERAL_AVOID do
							if rects[n] then
								h.ok(not R.overlap(box, rects[n]), "numeral overlaps " .. n)
							end
						end
					end)
				end
			end
		end
	end
	h.test("countdown numeral: 22 percent of the height at the phone viewports when nothing is in the way", function()
		for _, vp in { { 844, 390 }, { 740, 360 } } do
			local rects = R.compute(vp[1], vp[2], none, R.fallbackNav(vp[1], vp[2]), "touch")
			local size = R.countdownNumeral(vp[1], vp[2], rects)
			h.ok(size >= math.floor(0.19 * vp[2]), "phone numeral at least ~19 percent: " .. size)
		end
		local rects = R.compute(1920, 1080, none, R.fallbackNav(1920, 1080), "desktop")
		h.eq((R.countdownNumeral(1920, 1080, rects)), 194)
	end)

	h.test("floors: every button 44 px on touch, every text 12 px, the lanes are not squeezed away", function()
		for _, vp in viewports do
			local S = R.scale(vp[2])
			local r = R.compute(vp[1], vp[2], vp[4], R.fallbackNav(vp[1], vp[2]), "touch")
			for _, n in { "gear", "help", "respawn", "autoPill" } do
				h.ok(r[n].w >= 44 and r[n].h >= 44, n .. " is a 44 px target at " .. vp[3])
			end
			for n, base in R.TEXT_BASE do
				h.ok(R.textSize(base, S) >= 12, n .. " text floor at " .. vp[3])
			end
			h.ok(r.laneA.w >= 0.2 * vp[1] and r.laneA.h >= 40, "lane A has room at " .. vp[3])
			h.ok(r.laneB.w >= 0.2 * vp[1], "lane B has room at " .. vp[3])
			h.ok(r.laneB.h >= 34, "toast chip 34 px")
		end
	end)

	h.test("v39: the GAS start ring clears the position numeral even mid-pulse (desktop racing and phone)", function()
		local function grown(r, k)
			local dx, dy = r.w * (k - 1) / 2, r.h * (k - 1) / 2
			return { x = r.x - dx, y = r.y - dy, w = r.w + 2 * dx, h = r.h + 2 * dy }
		end
		for _, c in { { 1920, 1080, "desktop", nil }, { 1920, 1080, "desktop", 1740 }, { 1366, 768, "desktop", nil }, { 844, 390, "touch", nil }, { 1920, 1080, "touch", nil } } do
			local r = R.compute(c[1], c[2], none, R.fallbackNav(c[1], c[2]), c[3], { minimap = true, rightLimit = c[4] })
			h.ok(not R.overlap(grown(r.startRing, R.RING_PULSE), grown(r.position, R.POS_PULSE)), "ring vs position at " .. c[1] .. "x" .. c[2] .. " " .. c[3])
			-- the grid can show the ring before the minimap is on: the ring of that layout must also clear the racing numeral
			local pre = R.compute(c[1], c[2], none, R.fallbackNav(c[1], c[2]), c[3], { minimap = false, rightLimit = c[4] })
			h.ok(not R.overlap(grown(pre.startRing, R.RING_PULSE), grown(r.position, R.POS_PULSE)), "pre-minimap ring vs racing position at " .. c[1] .. "x" .. c[2] .. " " .. c[3])
		end
	end)

	h.test("rightLimit pulls the right column left", function()
		local a = R.compute(1366, 768, none, R.fallbackNav(1366, 768), "desktop")
		local b = R.compute(1366, 768, none, R.fallbackNav(1366, 768), "desktop", { rightLimit = 1200 })
		h.ok(b.position.x + b.position.w <= 1200)
		h.ok(a.position.x > b.position.x)
	end)

	h.test("nav: the live TopbarInset or the fallbacks", function()
		h.eq(R.fallbackNav(844, 390), { x = 0, y = 0, w = 190, h = 76 })
		h.eq(R.fallbackNav(1920, 1080), { x = 0, y = 0, w = 200, h = 58 })
		h.eq(R.navFromTopbar(164, 58, 844, 390), { x = 0, y = 0, w = 164, h = 58 })
		h.eq(R.navFromTopbar(nil, nil, 844, 390), R.fallbackNav(844, 390))
		h.eq(R.navFromTopbar(0, 0, 1920, 1080), R.fallbackNav(1920, 1080))
		h.eq(R.navFromTopbar(1900, 900, 1920, 1080), R.fallbackNav(1920, 1080))
	end)

	h.test("rightLimitFromTopbar: plausible Max.X only", function()
		h.eq(R.rightLimitFromTopbar(1700, 1920), 1700)
		h.eq(R.rightLimitFromTopbar(1920, 1920), 1920)
		h.eq(R.rightLimitFromTopbar(nil, 1920), nil)
		h.eq(R.rightLimitFromTopbar(300, 1920), nil)
		h.eq(R.rightLimitFromTopbar(2500, 1920), nil)
	end)

	h.test("item frame sits under the nav at any nav height", function()
		for _, nh in { 40, 58, 76, 100 } do
			local r = R.compute(844, 390, none, { x = 0, y = 0, w = 190, h = nh }, "touch")
			h.ok(r.item.y >= nh + 8)
			h.ok(r.gear.y >= nh + 8)
		end
	end)

	h.test("bubbleClear: HUD always wins", function()
		local ins = { left = 47, top = 0, right = 47, bottom = 21 }
		local rects = R.compute(844, 390, ins, R.fallbackNav(844, 390), "touch")
		local res = R.reserved(844, 390, rects, false)
		h.ok(R.bubbleClear({ x = 330, y = 120, w = 148, h = 56 }, res), "mid-sky bubble is clear")
		h.ok(not R.bubbleClear({ x = 20, y = 10, w = 148, h = 56 }, res), "under the nav")
		h.ok(not R.bubbleClear({ x = 60, y = 100, w = 148, h = 56 }, res), "over the item column")
		h.ok(not R.bubbleClear({ x = 700, y = 30, w = 100, h = 56 }, res), "over the right column")
		h.ok(not R.bubbleClear({ x = 340, y = 280, w = 148, h = 56 }, res), "over the kart band")
		local lane = { x = rects.laneA.x + 10, y = rects.laneA.y + 5, w = 100, h = 40 }
		h.ok(R.bubbleClear(lane, R.reserved(844, 390, rects, false)), "lane A is free without a hero")
		h.ok(not R.bubbleClear(lane, R.reserved(844, 390, rects, true)), "lane A reserved while a hero is up")
	end)

	h.test("pickLabels: at most 3 nearest, nearer labels win overlaps within 24 px", function()
		local function c(d, x, y)
			return { dist = d, rect = { x = x, y = y, w = 100, h = 22 } }
		end
		-- five spread-out labels: the three nearest show
		local shown = R.pickLabels({ c(50, 0, 0), c(10, 300, 0), c(30, 600, 0), c(20, 900, 0), c(40, 1200, 0) }, 3, 24)
		h.eq(shown, { false, true, true, true, false })
		-- two overlapping: the nearer wins, the farther hides
		shown = R.pickLabels({ c(30, 100, 100), c(10, 150, 110) }, 3, 24)
		h.eq(shown, { false, true })
		-- 20 px apart vertically still counts as close (within 24 px of the nearer rect)
		shown = R.pickLabels({ c(10, 0, 0), c(20, 0, 42) }, 3, 24)
		h.eq(shown, { true, false })
		-- far enough apart: both show
		shown = R.pickLabels({ c(10, 0, 0), c(20, 0, 60) }, 3, 24)
		h.eq(shown, { true, true })
		-- hysteresis: a label shown last time keeps its slot against a slightly nearer newcomer, but not a clearly nearer one
		shown = R.pickLabels({ c(10, 0, 0), c(20, 0, 42), c(30, 0, 200) }, 1, 24, { false, true, false })
		h.eq(shown, { true, false, false }) -- 20 * 0.8 = 16 still loses to 10
		shown = R.pickLabels({ c(18, 0, 0), c(20, 0, 42) }, 1, 24, { false, true })
		h.eq(shown, { false, true }) -- 20 * 0.8 = 16 beats 18
		-- a hidden (overlapped) label does not take a slot
		shown = R.pickLabels({ c(1, 0, 0), c(2, 10, 0), c(3, 400, 0), c(4, 800, 0), c(5, 1200, 0) }, 3, 24)
		h.eq(shown, { true, false, true, true, false })
		h.eq(R.pickLabels({}, 3, 24), {})
	end)

	h.test("position text: ordinals and the readout pieces", function()
		h.eq({ R.ordinal(1), R.ordinal(2), R.ordinal(3), R.ordinal(4), R.ordinal(8) }, { "ST", "ND", "RD", "TH", "TH" })
		h.eq({ R.ordinal(11), R.ordinal(12), R.ordinal(13), R.ordinal(21), R.ordinal(22), R.ordinal(23) }, { "TH", "TH", "TH", "ST", "ND", "RD" })
		local n, s, t = R.positionParts("3/8")
		h.eq({ n, s, t }, { "3", "RD", "/8" })
		n, s, t = R.positionParts("\u{2013}/8")
		h.eq({ n, s, t }, { "\u{2013}", "", "/8" })
		n, s, t = R.positionParts("garbage")
		h.eq({ n, s, t }, { "garbage", "", "" })
	end)

	h.test("showGlyphs truth table (8)", function()
		-- touch-only phone
		h.eq(R.glyphMode("Touch", true, false, 390), "none")
		-- Studio phone emulator: touch enabled, keyboard present, mouse events, phone-class viewport
		h.eq(R.glyphMode("MouseMovement", true, true, 390), "none")
		h.eq(R.glyphMode("MouseButton1", true, true, 390), "none")
		-- desktop
		h.eq(R.glyphMode("MouseMovement", false, true, 1080), "keyboard")
		h.eq(R.glyphMode("Keyboard", false, true, 1080), "keyboard")
		-- a real key press on a phone-class viewport still counts as keyboard
		h.eq(R.glyphMode("Keyboard", true, true, 390), "keyboard")
		-- gamepad anywhere
		h.eq(R.glyphMode("Gamepad1", false, false, 1080), "gamepad")
		h.eq(R.glyphMode("Gamepad1", true, false, 390), "gamepad")
		-- hybrid laptop: touch + keyboard on a large viewport, mouse is a desktop
		h.eq(R.glyphMode("MouseMovement", true, true, 900), "keyboard")
		h.eq(R.glyphMode("Touch", true, true, 900), "none")
		-- touch tablet with no keyboard and a big viewport: mouse (a stylus) is not a desktop
		h.eq(R.glyphMode("MouseMovement", true, false, 900), "none")
		-- non-input events never produce a badge
		h.eq(R.glyphMode("Focus", false, true, 1080), "none")
		-- ignoreMouse: only the mouse family, only on touch-like devices
		h.ok(R.ignoreMouse("MouseMovement", true, true, 390))
		h.ok(R.ignoreMouse("MouseButton1", true, false, 900))
		h.ok(not R.ignoreMouse("MouseMovement", true, true, 900))
		h.ok(not R.ignoreMouse("MouseMovement", false, true, 390))
		h.ok(not R.ignoreMouse("Keyboard", true, true, 390))
		h.ok(not R.ignoreMouse("Touch", true, true, 390))
	end)

	-- Hub objective banner (ADVENTURE bar + hint): the whole bar stays on screen with a margin at desktop and phone sizes, also
	-- when the real ScreenGui is smaller than the camera viewport (DPI-scaled 2048x1088 client) or not laid out yet (0).
	local bannerVps = {
		{ 1366, 768, none }, { 1920, 1080, none }, { 2048, 1088, none }, { 2560, 1440, none },
		{ 844, 390, { left = 47, top = 0, right = 47, bottom = 21 } }, { 740, 360, { left = 44, top = 0, right = 44, bottom = 20 } },
	}
	for _, vp in bannerVps do
		local kind = if vp[1] < 900 then "touch" else "desktop"
		for _, scale in { 0, 1, 1.15, 1.25 } do
			h.test(string.format("hub banner on screen: %dx%d gui scale %s", vp[1], vp[2], tostring(scale)), function()
				local ins = vp[3]
				-- scale 0: gui not laid out yet; otherwise the gui is the viewport divided by a DPI factor
				local gx = if scale == 0 then 0 else math.floor(vp[1] / scale)
				local gy = if scale == 0 then 0 else math.floor(vp[2] / scale)
				local ex, ey = if gx > 0 then gx else vp[1], if gy > 0 then gy else vp[2]
				-- HudMetrics computes the rects for the smaller of camera and gui
				local nav = { x = 0, y = 0, w = 190, h = if ey <= 450 then 76 else 58 }
				local rects = R.compute(ex, ey, ins, nav, kind)
				local pl = R.hubBarPlacement(rects.hubBar, ex, ey, gx, gy, ins.right)
				local bar = { x = pl.right - pl.w, y = pl.y, w = pl.w, h = pl.h }
				h.ok(bar.x >= 0, "bar left edge on screen")
				h.ok(bar.x + bar.w <= ex - ins.right - 12 + 1e-6, "bar keeps a 12 px margin from the right edge / inset")
				h.ok(bar.y + bar.h <= ey, "bar bottom on screen")
				h.ok(pl.w >= 160, "bar not squeezed below 160")
				h.ok(not R.overlap(bar, nav), "bar clear of the Roblox nav")
				h.ok(not R.overlap(bar, rects.leftColumn), "bar clear of the left column")
				h.ok(not R.overlap(bar, rects.hubLaneA), "bar clear of hub lane A")
				h.ok(not R.overlap(bar, rects.hubLaneB), "bar clear of hub lane B")
				-- the desktop player-list reserve (rightLimit = gui width - 180) moves the bar left, never right
				if kind == "desktop" then
					local lr = R.compute(ex, ey, ins, nav, kind, { rightLimit = R.rightLimitWithPlayerList(nil, ex, kind, true) })
					local lp = R.hubBarPlacement(lr.hubBar, ex, ey, gx, gy, ins.right)
					h.ok(lp.right <= ex - ins.right - 12 + 1e-6, "with the player list: 12 px margin")
					h.ok(lp.right <= pl.right + 1e-6, "with the player list: not further right")
					h.ok(lp.right <= ex - R.PLAYER_LIST_W + 1e-6, "with the player list: left of the list")
				end
				-- with the old placement (rects from the camera size, no gui clamp) a smaller gui overflowed
				if scale > 1 then
					local oldR = R.compute(vp[1], vp[2], ins, nav, kind)
					h.ok(oldR.hubBar.x + oldR.hubBar.w > ex - ins.right - 12, "regression guard: the unclamped rect does overflow this gui")
				end
			end)
		end
	end

	-- v28 (Studio V10 capture B1_battle_hud 1920x857): in the DINO-4 egg battle the item slot sat on top of the scoreboard rows.
	-- Cause: RaceUI.updateResponsiveLayout indexed rects.position (absent in a battle) and threw before HudExtras.layout, so the
	-- slot stayed at its racing place (top right, left of the combo panel) under the 420 px wide board. Two guards: the layout
	-- places the item column left of the board in every battle case, and the RaceUI function no longer stops on the missing rects.
	h.test("battle: item / gear / ? / token / assist never overlap the scoreboard, the plaque or the combo panel", function()
		local sizes = { { 1920, 1080 }, { 1366, 768 }, { 1920, 857 }, { 844, 390 }, { 740, 360 } }
		for _, vp in sizes do
			for _, kind in { "desktop", "touch" } do
				for _, mini in { false, true } do
					local ins = if vp[2] <= 450 then { left = 47, top = 0, right = 47, bottom = 21 } else none
					local nav = R.fallbackNav(vp[1], vp[2])
					local label = string.format("%dx%d %s minimap=%s", vp[1], vp[2], kind, tostring(mini))
					local rects = R.compute(vp[1], vp[2], ins, nav, kind, { battle = true, minimap = mini })
					h.ok(rects.battleBoard ~= nil and rects.item ~= nil, "rects exist " .. label)
					for _, n in { "item", "gear", "help", "token", "assistChip", "autoPill", "minimap" } do
						local a = rects[n]
						if a then
							for _, o in { "battleBoard", "battleHud", "combo" } do
								h.ok(rects[o] == nil or not R.overlap(a, rects[o]), n .. " clear of " .. o .. " at " .. label)
							end
						end
					end
					h.ok(rects.minimap == nil, "no minimap in a battle " .. label)
				end
			end
		end
	end)

	h.test("battle: RaceUI's responsive layout tolerates the absent position and lap chip rects and still lays out HudExtras", function()
		local src = h.readFile("src/client/RaceUI.luau")
		h.ok(string.find(src, "local p = rects.position\n\tif p then", 1, true) ~= nil, "position rect guarded")
		h.ok(string.find(src, "local c = rects.lapChip\n\tif c then", 1, true) ~= nil, "lap chip rect guarded")
	end)
end
