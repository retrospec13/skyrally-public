--!strict
-- Lune spec for the plane position check (L30, L53): PlaneGuardRules limits fed to CarConfig's budget validator, and the
-- minimum lap time that backs it up in RaceManager. A client owns its plane's transform, so a hull set onto each
-- checkpoint and the finish arch in turn used to be credited.
-- Run: tools/tests/run_lune_tests.sh tools/tests/plane_guard_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
}

return function(h: Harness)
	local C = h.require("src/shared/CarConfig.luau")
	local G = h.require("src/shared/PlaneGuardRules.luau")
	local P = h.require("src/shared/PlaneConfig.luau")

	h.test("plane limits cover every legal speed and keep the car's untouched", function()
		local lim = G.limits()
		h.ok(lim.maxH >= P.OVERCHARGE_SPEED + P.SPEED_PICKUP_BONUS * P.MAX_SPEED_PICKUPS, "overcharge with every pickup")
		h.ok(lim.maxH >= 260, "the 260 clamp on reported speed and boost events")
		h.ok(lim.maxRise >= P.OVERCHARGE_SPEED and lim.maxFall >= P.OVERCHARGE_SPEED, "a plane dives and climbs along its heading")
		local car = C.carLimits()
		h.eq(car.maxH, C.maxHorizontalSpeed(), "car horizontal limit")
		h.eq(car.slack, C.VALIDATION_SLACK, "car slack")
		local capH = C.budgetCaps()
		local capPlane = C.budgetCaps(lim)
		h.ok(capPlane > capH, "a plane's budget cap is its own")
	end)

	h.test("a legal overcharge flight with bursty replication is never flagged", function()
		local v = C.newValidator(G.limits())
		local legal = P.OVERCHARGE_SPEED + P.SPEED_PICKUP_BONUS * P.MAX_SPEED_PICKUPS
		local t, x, y = 0, 0, 100
		C.observe(v, x, y, 0, t)
		local pattern = { 1, 1, 4, 1, 2, 7, 1, 1, 3 }
		local frame, i = 0, 0
		while t < 20 do
			i += 1
			frame += pattern[(i - 1) % #pattern + 1]
			local nt = frame / 60
			x += legal * (nt - t)
			y -= 60 * (nt - t) -- diving
			t = nt
			local verdict = C.observe(v, x, y, 0, t)
			h.ok(verdict == "ok" or verdict == "idle", string.format("t=%.2f verdict=%s", t, verdict))
		end
	end)

	h.test("a 2 s replication stall at plane speed still passes", function()
		local v = C.newValidator(G.limits())
		C.observe(v, 0, 100, 0, 0)
		local travel = 224 * 2
		h.eq((C.observe(v, travel, 100, 0, 2)), "ok", "stalled packets arriving together")
	end)

	h.test("setting the hull onto the next checkpoint is a violation and credits nothing", function()
		local v = C.newValidator(G.limits())
		local t = 0
		C.observe(v, 0, 100, 0, t)
		for i = 1, 30 do -- cruise 1 s first
			t += 1 / 30
			C.observe(v, 110 * t, 100, 0, t)
		end
		local lastX = v.x
		t += 1 / 60
		local verdict, dist, allowed = C.observe(v, lastX + 1500, 100, 0, t) -- checkpoint 1500 studs on
		h.eq(verdict, "violation")
		h.ok(dist > allowed)
		h.ok(math.abs(v.x - lastX) < 1e-6, "last valid position kept for the correction")
	end)

	h.test("teleporting a checkpoint every half second is flagged within the first hops", function()
		local v = C.newValidator(G.limits())
		local t, x = 0, 0
		C.observe(v, x, 100, 0, t)
		local flagged = 0
		for i = 1, 20 do
			t += 0.5
			x += 900 -- 1800 studs/s
			if C.observe(v, x, 100, 0, t) == "violation" then
				flagged += 1
				x = v.x -- the server puts it back
			end
		end
		h.ok(flagged >= 18, "almost every hop refused, got " .. flagged)
	end)

	h.test("sustained speed hack is bounded near the plane limit", function()
		local v = C.newValidator(G.limits())
		local t, x = 0, 0
		C.observe(v, x, 100, 0, t)
		local accepted = 0
		for _ = 1, 600 do -- 10 s at 900 studs/s
			t += 1 / 60
			local nx = x + 15
			if C.observe(v, nx, 100, 0, t) == "ok" then
				accepted += 15
				x = nx
			end
		end
		local lim = G.limits()
		h.ok(accepted <= lim.maxH * lim.slack * 10 + C.budgetCaps(lim), "accepted " .. accepted)
	end)

	h.test("a server respawn target is accepted by the plane validator (grace), a stray position is not", function()
		local v = C.newValidator(G.limits())
		C.observe(v, 0, 100, 0, 0)
		C.expectTeleport(v, 3000, 120, 0, 1)
		h.eq((C.observe(v, 5, 100, 0, 1.01)), "grace")
		h.eq((C.observe(v, 3000, 121, 0, 1.2)), "ok")
	end)

	h.test("the default validator is still the car's", function()
		local v = C.newValidator()
		h.eq(v.limits, nil)
		C.observe(v, 0, 20, 0, 0)
		h.eq((C.observe(v, 600, 20, 0, 1 / 60)), "violation")
	end)

	h.test("minimum lap time scales with the track and never drops below the floor", function()
		h.eq(G.minLapSeconds(0), G.MIN_LAP_FLOOR, "unloaded spline")
		h.eq(G.minLapSeconds(0 / 0), G.MIN_LAP_FLOOR, "nan length")
		h.eq(G.minLapSeconds(500), G.MIN_LAP_FLOOR, "short spline")
		local long = G.minLapSeconds(9000)
		h.ok(long > 20 and long < 40, "9000 studs -> " .. long)
		-- Honest play: even a flat-out overcharge lap on a shortcut-trimmed route stays above the minimum.
		h.ok(9000 * 0.85 / 224 > long, "legal fastest lap is accepted")
	end)

	h.test("lapTimeOk refuses a teleported 24 s lap, accepts a real one, honours the QA bypass", function()
		h.eq(G.lapTimeOk(24, 9000, false), false, "3 laps in 24 s on a 9000-stud track")
		h.eq(G.lapTimeOk(75, 9000, false), true, "a normal lap")
		h.eq(G.lapTimeOk(1, 9000, true), true, "FastLapTest")
		h.eq(G.lapTimeOk(7.9, 0, false), false, "floor")
	end)
end
