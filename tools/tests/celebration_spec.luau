-- Celebration FX rules: phone-scaled counts, distance cull, fixed shell and chain counts, GO fov pop stays small.
return function(h)
	local R = h.require("src/shared/CelebrationRules.luau")

	h.test("count: scaled, at least 1, 0 only when the scale is 0", function()
		h.eq(R.count(20, 1), 20)
		h.eq(R.count(20, 0.5), 10)
		h.eq(R.count(1, 0.3), 1)
		h.eq(R.count(20, 0), 0)
	end)

	h.test("cullScale: full near, linear between, zero far", function()
		h.eq(R.cullScale(10), 1)
		h.eq(R.cullScale(R.CULL_FAR), 0)
		h.eq(R.cullScale(R.CULL_FAR + 100), 0)
		local mid = R.cullScale((R.CULL_NEAR + R.CULL_FAR) / 2)
		h.ok(math.abs(mid - 0.5) < 1e-9, "midpoint is 0.5")
	end)

	h.test("shellPlan: 4..6 shells, ordered, alternating sides, never random", function()
		h.eq(#R.shellPlan(1), 4)
		h.eq(#R.shellPlan(5), 5)
		h.eq(#R.shellPlan(99), 6)
		local a, b = R.shellPlan(6), R.shellPlan(6)
		local last = -1
		for i, s in a do
			h.ok(s.delay > last, "delays strictly increase")
			last = s.delay
			h.ok(math.abs(s.side) <= 0.9 and math.abs(s.side) >= 0.4, "shells stay over the verges, not the road centre")
			h.ok(s.height >= 30 and s.height <= 45, "shells open high")
			h.eq(s.delay, b[i].delay)
			h.ok(s.color >= 1 and s.color <= #R.SHELL_COLORS)
			if i > 1 then
				h.ok(s.side * a[i - 1].side < 0, "sides alternate")
			end
		end
		h.ok(last < 1.6, "the whole launch fits well inside two seconds")
	end)

	h.test("bossChain: 3..6 bursts down the body, last is biggest, short", function()
		h.eq(#R.bossChain(0), 3)
		h.eq(#R.bossChain(5), 5)
		h.eq(#R.bossChain(50), 6)
		local c = R.bossChain(5)
		for i, e in c do
			h.ok(e.along >= -0.5 and e.along <= 0.5)
			h.ok(e.size <= c[#c].size)
			if i > 1 then
				h.ok(e.delay > c[i - 1].delay and e.along > c[i - 1].along)
			end
		end
		h.ok(c[#c].delay < 1, "the chain is under a second")
	end)

	h.test("bossBurstSize and fovPop stay small", function()
		h.eq(R.bossBurstSize(1), 7)
		h.eq(R.bossBurstSize(1000), 15)
		h.ok(R.fovPop(false) <= 5 and R.fovPop(true) < R.fovPop(false))
	end)

	h.test("countdown colours and ring sizes: GO is the biggest, labels differ", function()
		h.ok(R.countdownRingSize("GO!") > R.countdownRingSize("1"))
		h.ok(R.countdownColor("3")[1] == 255 and R.countdownColor("3")[2] < 120, "3 is red")
		h.ok(R.countdownColor("GO!")[2] == 255 and R.countdownColor("GO!")[1] < 150, "GO is green")
	end)

	h.test("aura plan: ember rate scales, ribbon only on a thick particle budget", function()
		local full, thin = R.auraPlan(1), R.auraPlan(0.5)
		h.eq(full.emberRate, R.AURA_EMBER_RATE)
		h.ok(full.trail and not thin.trail)
		h.eq(thin.emberRate, R.AURA_EMBER_RATE * 0.5)
		h.eq(R.auraPlan(0).emberRate, 0)
	end)

	h.test("aura ribbon: speed gate with hysteresis", function()
		local top = 100
		h.ok(not R.auraTrailOn(60, top, false))
		h.ok(R.auraTrailOn(70, top, false))
		h.ok(R.auraTrailOn(58, top, true), "stays on just under the edge")
		h.ok(not R.auraTrailOn(50, top, true))
	end)

	h.test("aura lasts from the final lap until the finish", function()
		h.ok(R.auraActive(true, false, true))
		h.ok(not R.auraActive(false, false, true))
		h.ok(not R.auraActive(true, true, true))
		h.ok(not R.auraActive(true, false, false))
	end)
end
