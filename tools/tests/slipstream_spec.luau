--!strict
-- Lune spec for src/shared/SlipstreamRules.luau (v37 slipstream payoff) and the v37 bot start grade
-- (src/shared/BotPaceRules.luau startGrade). Run: tools/tests/run_lune_tests.sh tools/tests/slipstream_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
}

return function(h: Harness)
	local S = h.require("src/shared/SlipstreamRules.luau")
	local C = h.require("src/shared/CarConfig.luau")
	local P = h.require("src/shared/PlaneConfig.luau")
	local B = h.require("src/shared/BotPaceRules.luau")
	local DT = 1 / 60

	h.test("wake: straight behind a moving rival counts; too close, too far, off the cone, above, or slower does not", function()
		h.ok(S.inWake(0, 0, -25, 125, 120), "25 studs behind")
		h.ok(not S.inWake(0, 0, -4, 125, 120), "bumping")
		h.ok(not S.inWake(0, 0, -80, 125, 120), "too far")
		h.ok(not S.inWake(14, 0, -25, 125, 120), "off to the side")
		h.ok(not S.inWake(0, 20, -25, 125, 120), "on a deck above")
		h.ok(not S.inWake(0, 0, -25, 125, 40), "rival crawling")
		h.ok(not S.inWake(0, 0, -25, 60, 120), "falling behind")
	end)

	h.test("charge: CHARGE_TIME in the wake fires once, then cools down; a short wobble out keeps most of it", function()
		local st = S.new()
		local fired, t = 0, 0
		while t < S.CHARGE_TIME + 0.2 do
			if S.step(st, true, DT) then
				fired += 1
			end
			t += DT
		end
		h.eq(fired, 1, "one slingshot")
		for _ = 1, 60 do
			h.ok(not S.step(st, true, DT), "cooling down")
		end
		local st2 = S.new()
		for _ = 1, 50 do
			S.step(st2, true, DT)
		end
		local before = st2.charge
		for _ = 1, 10 do
			S.step(st2, false, DT)
		end
		h.ok(st2.charge > before * 0.5, "a 1/6 s wobble keeps the charge")
	end)

	h.test("slingshot speeds are speeds the validators already allow", function()
		h.ok(S.CAR_SPEED <= C.maxHorizontalSpeed() and S.CAR_SPEED <= C.PAD_BOOST_SPEED, "car under the pad boost")
		h.ok(S.CAR_SECONDS <= C.PAD_BOOST_DURATION and S.PLANE_SECONDS <= P.BOOST_DURATION, "shorter than a pad / ring")
	end)

	h.test("bot start grade: better rolls rocket more and burn less", function()
		local function share(frac: number): (number, number)
			local seed = 1
			local function rng(): number
				seed = (seed * 16807) % 2147483647
				return seed / 2147483647
			end
			local r, b = 0, 0
			for _ = 1, 4000 do
				local g = B.startGrade(rng, frac)
				if g == "rocket" then
					r += 1
				elseif g == "burnt" then
					b += 1
				end
			end
			return r / 4000, b / 4000
		end
		local rLo, bLo = share(0)
		local rHi, bHi = share(1)
		h.ok(rHi > rLo + 0.25 and bHi < bLo, "skill matters")
		h.ok(rHi < 0.7 and rLo > 0.08, "never all or nothing")
		h.eq(B.skillFrac(B.SKILL_MIN), 0)
		h.eq(B.skillFrac(B.SKILL_MAX), 1)
	end)
end
