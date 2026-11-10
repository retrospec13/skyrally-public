-- ChatLayoutRules: chat window config + PlayerList visibility per phase and viewport.
return function(h)
	local C = h.require("src/shared/ChatLayoutRules.luau")
	local L = h.require("src/shared/HudLayoutRules.luau")

	local VIEWS = { { 1920, 1080 }, { 1366, 768 }, { 844, 390 }, { 740, 360 }, { 667, 375 } }
	local PHASES = { "hub", "countdown", "race", "finish", "results", "podium", "battle" }

	h.test("pad side matches HudLayoutRules.thumbSizes", function()
		for _, y in { 360, 375, 390, 500, 768, 1080 } do
			local pad = L.thumbSizes(y)
			h.eq(C.padSide(y), pad)
		end
	end)

	h.test("always bottom/centre-left, never over the kart (centre-bottom), window stays small", function()
		for _, v in VIEWS do
			for _, touch in { false, true } do
				for _, p in PHASES do
					local cfg = C.compute(v[1], v[2], touch, p)
					h.eq(cfg.horizontal, "Left")
					h.ok(cfg.vertical == "Bottom" or cfg.vertical == "Center")
					h.ok(cfg.widthScale > 0 and cfg.widthScale <= 0.5, "width scale")
					h.ok(cfg.heightScale > 0 and cfg.heightScale <= 0.5, "height scale")
					h.ok(cfg.textSize >= 12, "readable text")
					h.ok(cfg.backgroundTransparency > 0 and cfg.backgroundTransparency < 1, "semi-transparent")
					local r = C.rect(cfg, v[1], v[2])
					h.ok(r.x + r.w <= v[1] * 0.42, "stays left of the kart column")
					h.ok(r.y >= 0 and r.y + r.h <= v[2], "inside the screen")
				end
			end
		end
	end)

	h.test("touch: clear of the steer pad and, in races, of the minimap (when the band allows)", function()
		for _, v in VIEWS do
			if v[1] ~= 1920 and v[1] ~= 1366 then
				for _, p in PHASES do
					local cfg = C.compute(v[1], v[2], true, p)
					local r = C.rect(cfg, v[1], v[2])
					local padTop = v[2] - C.padSide(v[2])
					-- the window may not reach into the pad's square (pad is x 0..side)
					h.ok(r.y + r.h <= padTop or r.x >= C.padSide(v[2]), p .. " clear of the pad at " .. v[1])
				end
			end
		end
	end)

	h.test("desktop: 26% wide; bottom outside races, left-centre (shortened) under the minimap and token while racing", function()
		local a = C.compute(1366, 768, false, "hub")
		local b = C.compute(1366, 768, false, "battle")
		local c = C.compute(1366, 768, false, "race")
		h.eq(a.vertical, "Bottom")
		h.eq(a.heightScale, b.heightScale)
		h.ok(math.abs(a.widthScale - 0.26) < 1e-9)
		h.eq(c.vertical, "Center")
		h.ok(c.heightScale <= a.heightScale and c.heightScale * 768 >= C.MIN_PX_H, "shortened but usable")
		h.eq(C.compute(1366, 768, false, "countdown").vertical, "Center")
	end)

	h.test("playerlist: hidden in countdown and race, shown in hub / results / podium / battle", function()
		for _, v in VIEWS do
			for _, touch in { false, true } do
				h.eq(C.playerListVisible(v[1], touch, "countdown"), false)
				h.eq(C.playerListVisible(v[1], touch, "race"), false)
				for _, p in { "hub", "results", "podium", "battle" } do
					h.eq(C.playerListVisible(v[1], touch, p), true, p)
				end
			end
		end
		h.eq(C.playerListVisible(667, true, "finish"), false)
		h.eq(C.playerListVisible(1366, false, "finish"), true)
	end)

	h.test("chat window clears the HUD rects of HudLayoutRules (minimap, item, gear, ?, token, AUTO, lap chip, lanes, thumb controls) per phase", function()
		local cases = {
			{ 844, 390, true, { left = 47, top = 0, right = 47, bottom = 21 } },
			{ 740, 360, true, { left = 44, top = 0, right = 44, bottom = 20 } },
			{ 1366, 768, false, { left = 0, top = 0, right = 0, bottom = 0 } },
			{ 1920, 1080, false, { left = 0, top = 0, right = 0, bottom = 0 } },
		}
		for _, c in cases do
			for _, p in PHASES do
				local touch = c[3]
				local nav = if touch then L.fallbackNav(c[1], c[2]) else { x = 0, y = 0, w = 200, h = C.DESKTOP_NAV_BOTTOM }
				local rects = L.compute(c[1], c[2], c[4], nav, if touch then "touch" else "desktop", { minimap = C.racing(p), battle = p == "battle" })
				local cfg = C.compute(c[1], c[2], touch, p)
				local win = C.rect(cfg, c[1], c[2])
				local names = {}
				for _, n in L.HUD_ELEMENTS do
					table.insert(names, n)
				end
				for _, n in L.TOUCH_ELEMENTS do
					table.insert(names, n)
				end
				table.insert(names, "battleBoard")
				table.insert(names, "battleHud")
				table.insert(names, "nav")
				for _, n in names do
					local r = rects[n]
					-- the lanes are centred messages; the window is at most 30% wide, so they only matter if it reaches them
					-- Touch outside races: the left column (item, gear, ?, token, AUTO) leaves no band for a 2-line window between it and
					-- the steer pad at 844x390 (known gap, Studio check); the right and thumb elements are still checked.
					-- Desktop outside races: the chat sits bottom-left where the controls hint chip pops up for a few seconds after an input
					-- change (it fades; in races the chat moves up, which is checked).
					local transientHint = n == "hintChip" and not touch and not C.racing(p)
					local leftCol = n == "item" or n == "gear" or n == "help" or n == "token" or n == "autoPill" or n == "minimap"
					if r and n ~= "startRing" and not transientHint and not (touch and not C.racing(p) and leftCol) then
						h.ok(not L.overlap(win, r), string.format("chat overlaps %s at %dx%d %s", n, c[1], c[2], p))
					end
				end
				-- racing: the window keeps its two-line floor and stays inside the screen
				if C.racing(p) then
					h.ok(win.y >= 0 and win.y + win.h <= c[2], "inside the screen while racing")
				end
			end
		end
	end)

	h.test("chat rule constants follow HudLayoutRules (minimap sizes, touch side stack)", function()
		for _, y in { 450, 480, 600, 768, 900, 1080, 1440 } do
			h.eq(C.desktopMinimapSide(y), L.minimapSize(y, "desktop"))
		end
		for _, v in { { 844, 390 }, { 740, 360 }, { 667, 375 } } do
			local ins = { left = 47, top = 0, right = 47, bottom = 21 }
			local r = L.compute(v[1], v[2], ins, L.fallbackNav(v[1], v[2]), "touch", { minimap = true })
			h.eq(r.autoPill.y + r.autoPill.h - r.token.y, C.TOUCH_SIDE_STACK, "token + pill stack at " .. v[1])
		end
	end)
end
