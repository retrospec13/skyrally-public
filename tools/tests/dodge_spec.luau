--!strict
-- Lune spec for the dodge input (shared/DodgeRules; owner 2026-10-21: "the dodge is double tap left or right"): a double tap
-- within the window dodges to that side; a single tap, a held steer, slow taps and alternating sides never do. Source guards
-- pin the wiring: raw (pre-ramp) input, the touch pad side, the old sharp-bank double press gone, the hint text.
-- Run: tools/tests/run_lune_tests.sh tools/tests/dodge_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
	contains: (string, string, string?) -> (),
}

return function(h: Harness)
	local D = h.require("src/shared/DodgeRules.luau")
	local DT = 1 / 60

	-- Feeds {raw, seconds} segments at 60 Hz; returns the dodge sides fired.
	local function feed(segments: { { number } }): { number }
		local f = D.new()
		local now = 0
		local out = {}
		for _, seg in segments do
			local t = 0
			while t < seg[2] - 1e-9 do
				local d = D.step(f, seg[1], now)
				if d ~= 0 then
					table.insert(out, d)
				end
				now += DT
				t += DT
			end
		end
		return out
	end

	h.test("double tap right dodges right, double tap left dodges left", function()
		h.eq(feed({ { 0, 0.2 }, { 1, 0.08 }, { 0, 0.08 }, { 1, 0.08 }, { 0, 0.3 } }), { 1 })
		h.eq(feed({ { 0, 0.2 }, { -1, 0.08 }, { 0, 0.1 }, { -1, 0.08 }, { 0, 0.3 } }), { -1 })
	end)

	h.test("a very quick tap (shorter than the key ramp) still counts, via the raw input", function()
		h.eq(feed({ { 1, 0.05 }, { 0, 0.05 }, { 1, 0.05 }, { 0, 0.2 } }), { 1 })
	end)

	h.test("stick and touch flicks: partial deflection above PRESS counts, hysteresis band does not release", function()
		h.eq(feed({ { 0.7, 0.1 }, { 0, 0.1 }, { 0.6, 0.1 }, { 0, 0.2 } }), { 1 })
		h.eq(feed({ { -0.9, 0.1 }, { -0.3, 0.05 }, { -0.9, 0.1 }, { 0, 0.2 } }), {}, "never fell under RELEASE: one long push")
		h.eq(feed({ { 0.4, 0.1 }, { 0, 0.1 }, { 0.4, 0.1 } }), {}, "under PRESS is not a tap")
	end)

	h.test("a single tap never dodges", function()
		h.eq(feed({ { 1, 0.1 }, { 0, 2 } }), {})
	end)

	h.test("held steering never dodges, even with a later tap or release", function()
		h.eq(feed({ { 1, 3 }, { 0, 0.1 } }), {})
		h.eq(feed({ { 1, 1.5 }, { 0, 0.1 }, { 1, 0.1 }, { 0, 0.3 } }), {}, "held, released, one tap")
		h.eq(feed({ { 1, 0.5 }, { 0, 0.05 }, { 1, 0.1 }, { 0, 0.3 } }), {}, "first press longer than MAX_TAP")
	end)

	h.test("slow taps (second press after the window) never dodge", function()
		h.eq(feed({ { 1, 0.08 }, { 0, 0.4 }, { 1, 0.08 }, { 0, 0.3 } }), {})
		-- just inside the window still dodges
		h.eq(feed({ { 1, 0.08 }, { 0, D.WINDOW - 0.08 - 0.05 }, { 1, 0.08 }, { 0, 0.3 } }), { 1 })
	end)

	h.test("alternating sides never dodge (slalom, left-right-left taps)", function()
		h.eq(feed({ { -1, 0.08 }, { 0, 0.08 }, { 1, 0.08 }, { 0, 0.08 }, { -1, 0.08 }, { 0, 0.08 }, { 1, 0.08 }, { 0, 0.3 } }), {})
		h.eq(feed({ { -1, 0.08 }, { 1, 0.08 }, { -1, 0.08 }, { 1, 0.08 }, { 0, 0.3 } }), {}, "pushed straight through")
	end)

	h.test("a left tap then a right double tap dodges right once", function()
		h.eq(feed({ { -1, 0.08 }, { 0, 0.08 }, { 1, 0.08 }, { 0, 0.08 }, { 1, 0.08 }, { 0, 0.3 } }), { 1 })
	end)

	h.test("the fire is consumed: holding the second press or a third tap does not fire again", function()
		h.eq(feed({ { 1, 0.08 }, { 0, 0.08 }, { 1, 1.0 }, { 0, 0.3 } }), { 1 }, "second press held")
		h.eq(feed({ { 1, 0.08 }, { 0, 0.08 }, { 1, 0.08 }, { 0, 0.08 }, { 1, 0.08 }, { 0, 0.3 } }), { 1 }, "the third quick tap does not fire a second dodge")
	end)

	h.test("window and tap length are the owner's 0.25 to 0.3 s feel", function()
		h.ok(D.WINDOW >= 0.25 and D.WINDOW <= 0.3)
		h.ok(D.MAX_TAP < D.WINDOW)
		h.ok(D.RELEASE < D.PRESS)
	end)

	h.test("pick takes the strongest raw source; padSide reads the side of the pad a finger is on", function()
		h.eq(D.pick(0, 0, 0, 0), 0)
		h.eq(D.pick(1, -0.4, 0, 0), 1)
		h.eq(D.pick(0, 0.3, -0.8, 0), -0.8)
		h.eq(D.pick(-2, 0, 0, 0), -1, "clamped")
		h.ok(D.padSide(160, 100, 200) >= D.PRESS, "right of centre is a right press")
		h.ok(D.padSide(40, 100, 200) <= -D.PRESS, "left of centre is a left press")
		h.ok(math.abs(D.padSide(102, 100, 200)) < D.RELEASE, "centre is neutral")
	end)

	h.test("wiring: FlightController dodges from the raw double tap, the sharp-bank double press and the 0.85 flick are gone", function()
		local fc = h.readFile("src/client/FlightController.luau")
		h.contains(fc, "DodgeRules.step(rollTap, rawDodgeX", "uses the double-tap detector")
		h.contains(fc, "rawDodgeX = DodgeRules.pick(kbSteerX, rawStickX", "raw keys / stick / touch, set before the ramp")
		h.ok(not string.find(fc, "tapRoll", 1, true) and not string.find(fc, "stepFlick", 1, true), "old binding removed")
		h.ok(not string.find(fc, "lastTouchBank", 1, true), "no sharp-bank double press")
		local ra = h.readFile("src/client/RaceUI.luau")
		h.contains(ra, "FlightController.padSideX = DodgeRules.padSide", "touch pad side feeds the dodge")
		local tr = h.readFile("src/shared/TrickRules.luau")
		h.ok(not string.find(tr, "ROLL_FLICK", 1, true), "flick constants gone")
	end)

	h.test("hint text describes the double tap", function()
		local n = h.readFile("src/shared/NotifySpec.luau")
		h.contains(n, "Double-tap left/right to dodge")
		h.ok(not string.find(n, "Roll to dodge", 1, true))
		h.contains(h.readFile("src/shared/MissileRules.luau"), "DOUBLE-TAP TO DODGE")
	end)
end
