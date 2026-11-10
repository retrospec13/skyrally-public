-- Car ground-FX rules (shared/GroundFxRules): tier scaling, tyre-mark gating, surface kinds, culling, bump severity.
return function(h)
	local R = h.require("src/shared/GroundFxRules.luau")

	h.test("tiers grow, arcs only on the top tier", function()
		for i = 2, #R.TIERS do
			h.ok(R.TIERS[i].sparks > R.TIERS[i - 1].sparks)
			h.ok(R.TIERS[i].ringSize > R.TIERS[i - 1].ringSize)
		end
		h.ok(not R.TIERS[1].arcs and not R.TIERS[2].arcs and R.TIERS[3].arcs)
		h.ok(R.TIERS[3].sparks >= 50 and R.TIERS[3].sparks <= 80)
		h.ok(R.tier(0) == R.TIERS[1] and R.tier(9) == R.TIERS[3])
	end)

	h.test("flash stays small: ring under 9 studs", function()
		for _, t in R.TIERS do
			h.ok(t.ringSize < 9 and t.flameSize < 3)
		end
	end)

	h.test("scaled counts never vanish for a requested burst", function()
		h.ok(R.scaled(30, 1) == 30)
		h.ok(R.scaled(30, 0.4) == 12)
		h.ok(R.scaled(1, 0.1) == 1)
		h.ok(R.scaled(0, 1) == 0)
		h.ok(R.rate(100, 0.5) == 50 and R.rate(0, 1) == 0)
	end)

	h.test("tyre marks: only a grounded dry slide at speed", function()
		h.ok(R.skidActive(true, false, 100, true, 0))
		h.ok(R.skidActive(true, false, 100, false, 15))
		h.ok(not R.skidActive(true, false, 100, false, 3))
		h.ok(not R.skidActive(false, false, 100, true, 0))
		h.ok(not R.skidActive(true, true, 100, true, 0))
		h.ok(not R.skidActive(true, false, 10, true, 0))
	end)

	h.test("mark colours: dark on road, none on grass or leaves", function()
		local a = R.markColor("Asphalt")
		h.ok(a ~= nil and (a :: any)[1] < 60)
		h.ok(R.markColor("Grass") == nil and R.markColor("LeafyGrass") == nil and R.markColor("Water") == nil)
	end)

	h.test("surface kinds", function()
		h.ok(R.surfaceKind("Grass", true) == "water")
		h.ok(R.surfaceKind("Snow", false) == "snow")
		h.ok(R.surfaceKind("Ice", false) == "snow")
		h.ok(R.surfaceKind("Asphalt", false) == "none")
	end)

	h.test("spray strength: zero when slow, full at top speed", function()
		h.ok(R.sprayStrength(5, 150) == 0)
		h.ok(R.sprayStrength(150, 150) == 1)
		h.ok(R.sprayStrength(-80, 150) > 0)
	end)

	h.test("culling: remote cars cull sooner", function()
		h.ok(R.inRange(300, true) and not R.inRange(300, false))
		h.ok(R.inRange(100, false))
	end)

	h.test("bumps: overlap box, severity and trauma bounds", function()
		h.ok(R.overlaps(1, 0, 2, 3.15, 5.25))
		h.ok(not R.overlaps(9, 0, 0, 3.15, 5.25))
		h.ok(not R.overlaps(0, 6, 0, 3.15, 5.25))
		local lo, hi = R.bumpSeverity(0, 0), R.bumpSeverity(500, 300)
		h.ok(lo >= 0.2 and hi == 1 and lo < hi)
		h.ok(R.bumpTrauma(1) <= 0.1 and R.bumpTrauma(0) >= 0.03)
		h.ok(R.bumpSparks(1) > R.bumpSparks(0))
	end)

	h.test("tier pop: small, within the 14-particle budget, smaller than the release ring", function()
		for lv = 1, 3 do
			local p = R.tierPop(lv, 1)
			h.ok(2 * (1 + p.stars + p.streaks) <= R.POP_MAX_TOTAL, "tier " .. lv .. " over budget")
			h.ok(p.ring < R.tier(lv).ringSize and p.ring < 9)
		end
		h.ok(R.tierPop(3, 1).streaks > R.tierPop(1, 1).streaks)
		h.ok(R.tierPop(3, 1).stars >= R.tierPop(1, 1).stars)
	end)

	h.test("tier pop on phone: no star layer, streaks thinned but never zero", function()
		for lv = 1, 3 do
			local p = R.tierPop(lv, 0.4)
			h.eq(p.stars, 0)
			h.ok(p.streaks >= 1 and p.streaks <= R.tierPop(lv, 1).streaks)
		end
		h.eq(R.tierPop(0, 1).ring, R.tierPop(1, 1).ring)
		h.eq(R.tierPop(9, 1).ring, R.tierPop(3, 1).ring)
	end)
	h.test("v21: remote cars throw a fraction of the local mini-turbo spark rate; tier 3 ember is capped", function()
		h.ok(R.sparkRate(170, 1, true) == 170)
		h.ok(R.sparkRate(170, 1, false) == 170 * R.REMOTE_SPARK_FRAC and R.REMOTE_SPARK_FRAC < 0.5)
		h.ok(R.sparkRate(100, 0.5, false) < R.sparkRate(100, 1, false))
		h.ok(R.TIERS[3].emberLight <= 0.6 and R.TIERS[3].ember <= 3.2 and R.TIERS[3].emberMax <= 4)
		h.ok(R.TIERS[1].ember > 3 and R.TIERS[1].emberRate > 50 and R.TIERS[1].emberLight < 0.4) -- bigger, denser, blended
		h.ok(R.TIER1_FX_RGB[3] > R.TIER1_FX_RGB[1] and R.TIER1_FX_RGB[1] < 70) -- a deeper blue than the HUD sky blue
	end)
end
