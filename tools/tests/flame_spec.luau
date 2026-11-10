-- Exhaust flame tuning rules (shared/FlameRules): the particle flame stays short and low-rate, grows with throttle, boost
-- and overcharge, flickers when idle, culls by distance and under LOW GRAPHICS, and stays within 3 emitters per nozzle.
-- The retired flame meshes must no longer be referenced by client/Vfx.
return function(h)
	local R = h.require("src/shared/FlameRules.luau")

	h.test("budget: at most 3 layers per nozzle, all defined", function()
		h.ok(#R.ORDER <= 3)
		for _, n in R.ORDER do
			h.ok(R.LAYERS[n] ~= nil, n)
		end
	end)

	h.test("plane flame stays short: every layer under 6 studs in every state, core under 4.5", function()
		for _, n in R.ORDER do
			for _, st in { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 1, 1, 1 } } do
				local len = R.length(n, st[1], st[2], st[3], 1)
				h.ok(len < 6, n .. " length " .. tostring(len))
			end
		end
		h.ok(R.length("core", 1, 1, 1, 1) < 4.5)
	end)

	h.test("flame grows with throttle, then boost, then overcharge", function()
		local idle = R.length("core", 0, 0, 0, 1)
		local cruise = R.length("core", 1, 0, 0, 1)
		local boost = R.length("core", 1, 1, 0, 1)
		local over = R.length("core", 1, 1, 1, 1)
		h.ok(idle < cruise and cruise < boost and boost <= over)
	end)

	h.test("a car pipe (scale 0.55) is smaller than the plane flame", function()
		h.ok(R.look("core", 1, 1, 0, 0.55).size0 < R.look("core", 1, 1, 0, 1).size0)
		h.ok(R.length("core", 1, 1, 0, 0.55) < R.length("core", 1, 1, 0, 1))
	end)

	h.test("rates are low and never zero for the core", function()
		for _, st in { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 1, 1, 1 } } do
			for _, n in R.ORDER do
				local r = R.rate(n, st[1], st[2], st[3], 1, 0.3, 4)
				h.ok(r <= 40, n .. " rate " .. tostring(r))
			end
			h.ok(R.rate("core", st[1], st[2], st[3], 1, 0.3, 4) >= R.MIN_RATE)
		end
	end)

	h.test("idle pilot flickers; a boosted flame does not", function()
		local lo, hi = math.huge, -math.huge
		for i = 0, 40 do
			local r = R.rate("core", 0, 0, 0, 1, i * 0.037, 3)
			lo, hi = math.min(lo, r), math.max(hi, r)
		end
		h.ok(hi - lo > 0.5, "pilot rate varies")
		h.eq(R.rate("core", 1, 1, 0, 1, 0.1, 3), R.rate("core", 1, 1, 0, 1, 0.9, 3), "boost rate is steady")
	end)

	h.test("sparks are off at pilot, on at cruise", function()
		h.eq(R.rate("sparks", 0, 0, 0, 1, 0.2, 1), 0)
		h.ok(R.rate("sparks", 1, 0, 0, 1, 0.2, 1) > 0)
	end)

	h.test("colour: boost shifts the core bluer, overcharge greener", function()
		local cruise = R.look("core", 1, 0, 0, 1).c0
		local boost = R.look("core", 1, 1, 0, 1).c0
		local over = R.look("core", 1, 1, 1, 1).c0
		h.ok(boost[3] >= cruise[3] and boost[1] < cruise[1], "boost bluer")
		h.ok(over[2] > over[1] and over[2] >= boost[2] - 0.2, "overcharge green")
	end)

	h.test("cull: far away or low graphics turns the emitters off", function()
		h.ok(R.active(10, false))
		h.ok(R.active(R.CULL_DIST, false))
		h.ok(not R.active(R.CULL_DIST + 1, false))
		h.ok(not R.active(10, true))
		h.ok(R.CULL_DIST <= 300)
	end)

	h.test("Vfx no longer uses the flame meshes", function()
		local src = h.readFile("src/client/Vfx.luau")
		h.ok(not string.find(src, "flame_core", 1, true) or string.find(src, "retired", 1, true) ~= nil)
		h.ok(not string.find(src, ':FindFirstChild("flame_core")', 1, true))
		h.ok(not string.find(src, ':FindFirstChild("flame_outer")', 1, true))
		h.ok(string.find(src, "EmissionDirection = Enum.NormalId.Back", 1, true) ~= nil)
	end)
end
