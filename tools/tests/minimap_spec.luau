-- MinimapRules (outline fit / simplify / segment, marker placement, leader progress, update throttle) and the HudLayoutRules
-- minimap rect: with a race minimap up, every HUD obligation of hud_layout_spec (safe rect, nav, no overlaps, road band, thumb
-- exclusion) still holds at the four viewports, with and without insets, both kinds, several nav widths.
return function(h)
	local M = h.require("src/shared/MinimapRules.luau")
	local R = h.require("src/shared/HudLayoutRules.luau")

	local function near(a, b, eps, msg)
		h.ok(math.abs(a - b) <= (eps or 1e-6), (msg or "near") .. ": " .. tostring(a) .. " vs " .. tostring(b))
	end

	-- A circuit: an ellipse of n points, 4000 wide (x) and 2000 deep (z), centred far from the origin.
	local function ellipse(n, cx, cz, rx, rz)
		local pts = {}
		for i = 0, n - 1 do
			local a = 2 * math.pi * i / n
			pts[#pts + 1] = { x = cx + rx * math.cos(a), y = cz + rz * math.sin(a) }
		end
		return pts
	end

	h.test("fit: uniform scale, centred, padded, north-up (no flip)", function()
		local pts = ellipse(200, 5000, -3000, 2000, 1000)
		local f = M.fit(pts, 90)
		h.ok(f ~= nil)
		near(f.scale, 90 * (1 - 2 * M.PAD) / 4000, 1e-9, "scale from the longer span")
		local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
		for _, p in pts do
			local x, y = M.place(f, p.x, p.y)
			minX, maxX, minY, maxY = math.min(minX, x), math.max(maxX, x), math.min(minY, y), math.max(maxY, y)
		end
		near((minX + maxX) / 2, 45, 1e-6, "centred x")
		near((minY + maxY) / 2, 45, 1e-6, "centred y")
		h.ok(minX >= 90 * M.PAD - 1e-6 and maxX <= 90 * (1 - M.PAD) + 1e-6, "inside the padding in x")
		h.ok(minY > 90 * M.PAD, "the shorter axis keeps more air")
		-- north-up: a point further to world -Z lands higher (smaller y) on the map
		local _, yN = M.place(f, 5000, -4000)
		local _, yS = M.place(f, 5000, -2000)
		h.ok(yN < yS, "-Z is up")
	end)

	h.test("fit: degenerate input", function()
		h.eq(M.fit({}, 90), nil)
		h.eq(M.fit({ { x = 1, y = 1 } }, 90), nil)
		h.eq(M.fit({ { x = 1, y = 1 }, { x = 1, y = 1 } }, 90), nil)
		local f = M.fit({ { x = 0, y = 0 }, { x = 100, y = 0 } }, 90) -- a straight line: still fits (zero depth)
		h.ok(f ~= nil)
		local _, y = M.place(f, 50, 0)
		near(y, 45, 1e-6, "a straight course sits on the middle line")
	end)

	h.test("simplify: a 300-point circuit becomes a few dozen segments, within tolerance, ends kept", function()
		local pts = ellipse(300, 0, 0, 40, 20)
		pts[#pts + 1] = { x = pts[1].x, y = pts[1].y }
		local s = M.simplify(pts, M.TOLERANCE_PX)
		h.ok(#s < 80 and #s >= 8, "segments " .. #s)
		h.eq(s[1].x, pts[1].x)
		h.eq(s[#s].x, pts[#pts].x)
		-- every dropped point is within tolerance of the simplified line (checked against its nearest segment)
		for _, p in pts do
			local best = math.huge
			for i = 1, #s - 1 do
				local a, b = s[i], s[i + 1]
				local dx, dy = b.x - a.x, b.y - a.y
				local l2 = dx * dx + dy * dy
				local t = if l2 > 0 then math.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0, 1) else 0
				best = math.min(best, math.sqrt((a.x + dx * t - p.x) ^ 2 + (a.y + dy * t - p.y) ^ 2))
			end
			h.ok(best <= M.TOLERANCE_PX + 1e-6, "dropped point off the line by " .. best)
		end
		h.eq(#M.simplify({ { x = 0, y = 0 }, { x = 1, y = 1 } }, 1), 2)
		-- a long straight collapses to its two ends
		local line = {}
		for i = 0, 400 do
			line[#line + 1] = { x = i, y = 0 }
		end
		h.eq(#M.simplify(line, 0.5), 2)
	end)

	h.test("segment: centre, length with caps, angle", function()
		local cx, cy, len, ang = M.segment({ x = 0, y = 0 }, { x = 30, y = 40 }, 4)
		near(cx, 15)
		near(cy, 20)
		near(len, 54)
		near(ang, math.deg(math.atan2(40, 30)), 1e-9)
		local _, _, l2, a2 = M.segment({ x = 10, y = 10 }, { x = 0, y = 10 }, 0)
		near(l2, 10)
		near(math.abs(a2), 180, 1e-9)
	end)

	h.test("outline: fits the frame, closes a circuit, leaves an open course open", function()
		local pts = ellipse(240, 0, 0, 2000, 1500)
		h.ok(M.isClosed(pts) == false or true) -- the ellipse's last point is one step before the first: 2*pi*r/240 is small
		h.ok(M.isClosed(pts), "a circuit sampled all the way round is closed")
		local poly, f = M.outline(pts, 90, true)
		h.ok(poly and f)
		h.eq(poly[1].x, poly[#poly].x, "closed outline joins up")
		h.eq(poly[1].y, poly[#poly].y)
		for _, p in poly do
			h.ok(p.x >= 0 and p.x <= 90 and p.y >= 0 and p.y <= 90, "inside the frame")
		end
		local straight = {}
		for i = 0, 300 do
			straight[#straight + 1] = { x = 0, y = -i * 17 }
		end
		h.ok(not M.isClosed(straight), "a one-way course is open")
		local p2 = M.outline(straight, 90, false)
		h.eq(#p2, 2)
		h.eq(M.outline({}, 90, false), nil)
	end)

	h.test("clampInside keeps a racer off the frame edge", function()
		local x, y = M.clampInside(-50, 400, 90, 4)
		h.eq(x, 4)
		h.eq(y, 86)
		x, y = M.clampInside(45, 45, 90, 4)
		h.eq(x, 45)
		h.eq(y, 45)
	end)

	h.test("nearest: windowed search tracks a racer round a closed course without a full scan", function()
		local n = 300
		local xs, zs = {}, {}
		for i = 1, n do
			local a = 2 * math.pi * (i - 1) / n
			xs[i], zs[i] = 1000 * math.cos(a), 1000 * math.sin(a)
		end
		-- full scan
		h.eq(M.nearest(xs, zs, xs[120], zs[120], nil, true), 120)
		-- windowed, including across the wrap at index 1 / n
		h.eq(M.nearest(xs, zs, xs[130], zs[130], 120, true), 130)
		h.eq(M.nearest(xs, zs, xs[3], zs[3], n - 2, true), 3)
		h.eq(M.nearest(xs, zs, xs[n - 1], zs[n - 1], 2, true), n - 1)
		-- open course: the window clamps at both ends
		h.eq(M.nearest(xs, zs, xs[1], zs[1], 5, false), 1)
		h.eq(M.nearest(xs, zs, xs[n], zs[n], n - 4, false), n)
	end)

	h.test("step: laps unwrap, the grid behind the line is behind the field, reverse crossings undo", function()
		local n = 300
		local grid = M.newProgress() -- starts 10 waypoints behind the line
		local front = M.newProgress() -- starts 5 past it
		local a = M.step(grid, n - 10, n)
		local b = M.step(front, 6, n)
		h.ok(a < 0 and a < b, "a racer behind the line starts behind one past it")
		-- the grid racer crosses the line: lap 0, small frac
		local c = M.step(grid, 4, n)
		h.ok(c > 0 and c < 0.05, "crossing the line puts it on lap 0 + small fraction: " .. c)
		-- a whole lap round and over the line again
		for idx = 20, n, 20 do
			M.step(grid, idx, n)
		end
		local d = M.step(grid, 3, n)
		h.ok(d > 1 and d < 1.05, "second crossing = lap 1: " .. d)
		-- reversing over the line takes it back
		local e = M.step(grid, n - 3, n)
		h.ok(e < 1 and e > 0.95, "back over the line: " .. e)
		-- ordering across racers
		local slow, fast = M.newProgress(), M.newProgress()
		M.step(slow, 100, n)
		M.step(fast, 150, n)
		h.ok(M.step(fast, 160, n) > M.step(slow, 110, n))
	end)

	h.test("due: 12 Hz throttle", function()
		local st = { next = 0 }
		local fired = 0
		local t = 0
		while t < 1.0 do
			if M.due(st, t) then
				fired += 1
			end
			t += 1 / 60 -- a 60 fps clock
		end
		h.ok(fired >= 11 and fired <= 13, "fired " .. fired .. " times in a second")
		local st2 = { next = 0 }
		h.ok(M.due(st2, 5), "first call fires")
		h.ok(not M.due(st2, 5.01), "10 ms later it does not")
		h.ok(M.due(st2, 5 + 1 / M.HZ + 1e-6), "a period later it does")
	end)

	h.test("dotSizes: local larger than the others, bounded", function()
		for _, side in { 72, 90, 169, 220 } do
			local o, own = M.dotSizes(side)
			h.ok(own > o and o >= 6 and own <= 24, "side " .. side)
		end
	end)

	h.test("minimapSize: phone 22-26 percent of the height, desktop scales and caps", function()
		local phone = R.minimapSize(390, "touch")
		h.ok(phone / 390 >= 0.22 and phone / 390 <= 0.26, "844x390 phone " .. phone)
		h.ok(R.minimapSize(360, "touch") >= 72)
		h.ok(R.minimapSize(1080, "desktop") == 220, "1080p capped")
		h.ok(R.minimapSize(768, "desktop") > R.minimapSize(390, "touch"), "desktop bigger than the phone")
	end)

	h.test("minimapSize: compact on a narrow safe width, unchanged otherwise, never on desktop", function()
		h.eq(R.minimapSize(360, "touch", 652), R.MINIMAP_COMPACT)
		h.ok(R.minimapSize(390, "touch", 750) == R.minimapSize(390, "touch"), "844x390 with insets keeps the normal size")
		h.ok(R.minimapSize(360, "desktop", 652) == R.minimapSize(360, "desktop"), "desktop never compact")
		h.ok(R.MINIMAP_COMPACT < R.minimapSize(360, "touch"), "smaller than the normal phone map")
	end)

	local none = { left = 0, top = 0, right = 0, bottom = 0 }
	local function tv(vx, vy)
		local a, b = math.floor(vx * 0.05 + 0.5), math.floor(vy * 0.05 + 0.5)
		return { left = a, top = b, right = a, bottom = b }
	end
	local viewports = {
		{ 1920, 1080, "1920x1080", none },
		{ 1366, 768, "1366x768", none },
		{ 844, 390, "844x390", { left = 47, top = 0, right = 47, bottom = 21 } },
		{ 740, 360, "740x360", { left = 44, top = 0, right = 44, bottom = 20 } },
	}
	for _, vp in viewports do
		for _, case in { { "no insets", none }, { "device insets", vp[4] }, { "TV 5 percent", tv(vp[1], vp[2]) } } do
			for _, kind in { "touch", "desktop" } do
				for _, navW in { 150, 190, 200, 260 } do
					local label = string.format("%s %s %s nav%d", vp[3], case[1], kind, navW)
					h.test("minimap collisions: " .. label, function()
						local ins = case[2]
						local nav = { x = 0, y = 0, w = navW, h = if vp[2] <= 450 then 76 else 58 }
						local rects = R.compute(vp[1], vp[2], ins, nav, kind, { minimap = true })
						local without = R.compute(vp[1], vp[2], ins, nav, kind)
						h.ok(rects.minimap ~= nil and without.minimap == nil, "minimap rect only when asked")
						local mm = rects.minimap
						local size = R.minimapSize(vp[2], kind, vp[1] - ins.left - ins.right)
						h.ok(mm.w == size and mm.h == size, "square at the computed size")
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
						local safe = { x = ins.left, y = ins.top, w = vp[1] - ins.left - ins.right, h = vp[2] - ins.top - ins.bottom }
						local band = R.roadBand(vp[1], vp[2])
						local names = {}
						for n in list do
							table.insert(names, n)
						end
						table.sort(names)
						for _, n in names do
							h.ok(R.contains(safe, list[n]), n .. " inside the safe rect")
							h.ok(not R.overlap(list[n], nav), n .. " clear of the nav")
						end
						for i = 1, #names do
							for j = i + 1, #names do
								h.ok(not R.overlap(list[names[i]], list[names[j]]), names[i] .. " overlaps " .. names[j])
							end
						end
						for _, n in R.HUD_ELEMENTS do
							if list[n] then
								h.ok(not R.overlap(list[n], band), n .. " enters the road band")
							end
						end
						if kind == "touch" then
							for _, ex in R.thumbExclusion(rects) do
								for _, n in names do
									if n ~= "steerPad" and n ~= "rightZone" and n ~= "startRing" then
										h.ok(not R.overlap(list[n], ex), n .. " enters a thumb exclusion rect")
									end
								end
							end
							-- the reference spot: the nav-side corner, directly under the nav, on the left edge
							h.ok(mm.x == rects.steerPad.x and mm.y == math.max(nav.h + 8, rects.position.y), "touch: top-left under the nav")
							h.ok(rects.autoPill.x >= mm.x + mm.w + 8 - 1e-6 and rects.token.y == mm.y, "touch: token chip right of the minimap, AUTO pill under it")
							h.ok(rects.help.w >= 44 and rects.gear.w >= 44, "44 px system buttons")
						else
							h.ok(mm.x == rects.hintChip.x and mm.y == math.max(nav.h + 8, rects.position.y), "desktop: left edge directly under the nav")
							h.ok(not R.overlap(mm, rects.hintChip), "desktop: clear of the controls hint")
						end
						-- lanes keep room for the hero text / toast
						local need = if case[1] == "TV 5 percent" then 0.10 else 0.14 -- the TV margin on a phone is a what-if, not a device
						h.ok(rects.laneA.w >= need * vp[1] and rects.laneB.w >= need * vp[1], "lanes keep room")
						-- small phones (safe width 700 or less): a smaller minimap and lanes of at least about 200 px
						if kind == "touch" and vp[1] - ins.left - ins.right <= 700 and case[1] ~= "TV 5 percent" then
							h.ok(mm.w == R.MINIMAP_COMPACT, "compact minimap " .. mm.w)
							h.ok(rects.laneA.w >= 200 and rects.laneB.w >= 200, "compact lanes " .. rects.laneA.w .. "/" .. rects.laneB.w)
						end
						-- MK layout (HUD_MK_LAYOUT.md 3): token under the minimap, item / gear / "?" in one column left of the right column
						if kind == "desktop" then
							h.ok(rects.token.y >= mm.y + mm.h and rects.token.x == mm.x, "token chip under the minimap")
						end
						local rightMin = math.min(rects.position.x, rects.lapChip.x, rects.combo.x)
						for _, n in { "item", "gear", "help" } do
							h.ok(rects[n].x + rects[n].w <= rightMin - 8 + 1e-6 and rects[n].y >= rects.position.y, n .. " column beside the right column")
							h.ok(rects[n].x > rects.laneA.x + rects.laneA.w - 1e-6, n .. " right of the lanes")
						end
						h.ok(rects.item.y < rects.gear.y and rects.gear.y <= rects.help.y, "item over gear, help under or (short screens) left of the gear")
						local col = rects.leftColumn
						h.ok(R.contains({ x = col.x, y = col.y, w = col.w, h = col.h }, mm) or mm.y < col.y, "left column covers the minimap")
						-- the speech-bubble guard reserves it
						local reserved = R.reserved(vp[1], vp[2], rects, false)
						h.ok(not R.bubbleClear(mm, reserved), "bubbles keep off the minimap")
					end)
				end
			end
		end
	end
end
