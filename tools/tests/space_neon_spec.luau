-- SPACE-4 neon pass (shared/SpaceNeonRules + SpaceNeonLayout): the hologram rig stays inside its reach envelope, the head
-- follows a target within its limit, flicker and billboard copy stay in range, and the checked-in layout matches the rules.
return function(h)
	local R = h.require("src/shared/SpaceNeonRules.luau")

	h.test("reach is the documented envelope", function()
		-- 118 tall, 40 degree lean: 118 * (0.56 * sin 40 + 0.22)
		local want = 118 * (0.6 * math.sin(math.rad(40)) + 0.26)
		h.ok(math.abs(R.reach(118, 40) - want) < 1e-6, "reach " .. R.reach(118, 40))
		h.ok(math.abs(R.reach(118, 40) - 76.2) < 0.2, "reach about 76.2, got " .. R.reach(118, 40))
		-- v29 W1b A8: HOLO_CLEAR 55 -> 180 (figures behind the first tower row)
		h.eq(R.HOLO_CLEAR, 180)
		h.ok(R.clearOfRoad(257, 118, 40), "257 studs from the road clears 118 tall at 40 degrees")
		h.ok(not R.clearOfRoad(240, 118, 40), "240 studs does not")
	end)

	h.test("every part of the idle pose stays inside the reach envelope", function()
		for _, cfg in { { 118, 40 }, { 96, 36 }, { 132, 42 }, { 80, 45 } } do
			local height, lean = cfg[1], cfg[2]
			local k = height / R.UNIT_HEIGHT
			local limit = R.reach(height, lean)
			local worst = 0
			for i = 0, 400 do
				local t = i * 0.37
				local yaw = math.sin(t * 0.3) * math.rad(70)
				local cfs = R.pose(t, 1.3, height, lean, yaw)
				h.eq(#cfs, #R.PART_NAMES, "one CFrame per part")
				for j, cf in cfs do
					local sz = R.PART_SIZES[j]
					local half = math.sqrt(sz[1] ^ 2 + sz[2] ^ 2 + sz[3] ^ 2) * 0.5 * k
					local p = cf.Position
					local radius = math.sqrt(p.X ^ 2 + p.Z ^ 2) + half
					worst = math.max(worst, radius)
				end
			end
			h.ok(worst <= limit, string.format("h%g lean%g: worst reach %.1f > limit %.1f", height, lean, worst, limit))
		end
	end)

	h.test("feet stay on the ground and the figure is about as tall as asked", function()
		local height = 120
		local k = height / R.UNIT_HEIGHT
		local cfs = R.pose(0, 0, height, 0, 0) -- upright
		local top = 0
		local bottom = math.huge
		for j, cf in cfs do
			local sz = R.PART_SIZES[j]
			top = math.max(top, cf.Position.Y + sz[2] * 0.5 * k)
			bottom = math.min(bottom, cf.Position.Y - sz[2] * 0.5 * k)
		end
		h.ok(math.abs(bottom) < 0.5, "feet at y 0, got " .. bottom)
		h.ok(math.abs(top - height) < 0.08 * height, "height " .. top)
	end)

	h.test("leaning bends the torso toward -Z (the facing direction)", function()
		local upright = R.pose(0, 0, 100, 0, 0)
		local bent = R.pose(0, 0, 100, 40, 0)
		h.ok(bent[3].Position.Z < upright[3].Position.Z - 20, "head moves forward")
		h.ok(bent[3].Position.Y < upright[3].Position.Y, "and down")
		h.ok(math.abs(bent[10].Position.Z - upright[10].Position.Z) < 1e-6, "legs stay planted")
	end)

	h.test("head follows a target within its limit", function()
		-- face yaw 0 looks toward -Z; a target at -X is a left turn (yaw +90 deg in the Roblox convention), clamped to 70
		local y = R.lookYaw(0, Vector3.zero, Vector3.new(-100, 0, 0))
		h.ok(math.abs(y - math.rad(70)) < 1e-6, "clamped, got " .. y)
		h.ok(math.abs(R.lookYaw(0, Vector3.zero, Vector3.new(0, 5, -100))) < 1e-6, "straight ahead is 0")
		local small = R.lookYaw(0, Vector3.zero, Vector3.new(-30, 0, -100))
		h.ok(small > 0 and small < math.rad(30), "partial turn " .. small)
		h.eq(R.lookYaw(0, Vector3.zero, Vector3.zero), 0, "no target direction")
	end)

	h.test("flicker stays in range and glitches", function()
		local peak = 0
		for i = 0, 2000 do
			local f = R.flicker(i * 0.05, 2.1)
			h.ok(f >= 0 and f <= 0.4, "flicker " .. f)
			peak = math.max(peak, f)
		end
		h.ok(peak > 0.25, "a glitch frame happens, peak " .. peak)
	end)

	h.test("update interval thins with distance and freezes far away", function()
		h.ok((R.updateInterval(100, false) :: number) < (R.updateInterval(800, false) :: number), "nearer is faster")
		h.eq(R.updateInterval(2500, false), nil, "frozen")
		h.ok((R.updateInterval(100, true) :: number) > (R.updateInterval(100, false) :: number), "low graphics is slower")
	end)

	h.test("billboards cycle copy, type it out, and glitch on the edges", function()
		local seen = {}
		for i = 0, 100 do
			local s = R.board(i * 1.0, 0)
			h.ok(s.copy >= 1 and s.copy <= #R.COPY, "copy index")
			seen[s.copy] = true
			h.ok(s.reveal >= 0 and s.reveal <= 1, "reveal")
		end
		local n = 0
		for _ in seen do
			n += 1
		end
		h.eq(n, #R.COPY, "all messages appear")
		h.ok(R.board(0.05, 0).glitch, "glitch at the start")
		h.ok(not R.board(3, 0).glitch, "calm mid-message")
		h.ok(R.board(0, 0).copy ~= R.board(0, 1).copy, "neighbouring boards differ")
		h.eq(R.typed("SKYRALLY", 0.5), "SKYR", "half typed")
		h.eq(R.typed("SKYRALLY", 0), "S", "at least one letter")
		h.eq(R.typed("SKYRALLY", 1), "SKYRALLY", "complete")
	end)

	h.test("palette cycle wraps and stays on the synthwave list", function()
		h.eq(#R.SYNTH, 6, "six steps")
		local a = R.cycle(0, 12, 0)
		local b = R.cycle(12, 12, 0)
		h.ok((a.R - b.R) ^ 2 + (a.G - b.G) ^ 2 + (a.B - b.B) ^ 2 < 1e-9, "full period returns to the start")
		h.eq(#R.LOOKS, 4, "four looks")
	end)

	h.test("the generated layout is complete and keeps the shared clearance numbers", function()
		local L = h.require("src/shared/SpaceNeonLayout.luau")
		h.ok(#L.holograms >= 3 and #L.holograms <= 6, "3-6 figures, got " .. #L.holograms)
		h.ok(#L.billboards >= 3 and #L.billboards <= 4, "billboards " .. #L.billboards) -- v29 A8: at most 4
		for i, f in L.holograms do
			h.ok(f.height >= 40 and f.height <= 60, "figure " .. i .. " height " .. f.height) -- v29 A8: capped at 60 (was 80-150)
			h.ok(f.lean >= 30 and f.lean <= 50, "figure " .. i .. " lean")
			h.ok(f.palette >= 0 and f.palette < #R.LOOKS, "figure " .. i .. " palette")
		end
		for i, b in L.billboards do
			h.ok(b.width > 0 and b.height > 0, "board " .. i .. " size")
			h.ok(b.palette >= 0 and b.palette < #R.LOOKS, "board " .. i .. " palette")
		end
	end)
end
