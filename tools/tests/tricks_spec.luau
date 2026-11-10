--!strict
-- Lune spec for src/shared/TrickRules.luau (REMARKABLE Batch 1 items 5, 6, 7): car Hop and Spin landing verdicts and
-- boost eligibility, the hop's arc and its fairness against plain driving, the rev-match start state machine, and the
-- barrel-roll angle (the double-tap trigger is tools/tests/dodge_spec.luau). CarController and FlightController use exactly these functions.
-- Run: tools/tests/run_lune_tests.sh tools/tests/tricks_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
}

return function(h: Harness)
	local T = h.require("src/shared/TrickRules.luau")
	local C = h.require("src/shared/CarConfig.luau")
	local P = h.require("src/shared/PlaneConfig.luau")

	local DT = 1 / 60

	-- Hop arc on flat road at 60 Hz with the car's gravity: returns the air time and apex height.
	local function hopArc(): (number, number)
		local y, vy, t, apex = 0, T.HOP_VY, 0, 0
		repeat
			vy -= C.GRAVITY * DT
			y += vy * DT
			t += DT
			apex = math.max(apex, y)
		until y <= 0
		return t, apex
	end

	-- Air left after a second tap at `at` seconds into a flat hop, and how far the spin got by touchdown.
	local function spinAtLanding(at: number, turns: number): (number, number)
		local air = hopArc()
		local target = 0
		for _ = 1, turns do
			target = T.queueSpin(target, 1)
		end
		local spun = math.min(math.abs(target), math.max(0, air - at) * T.SPIN_DEG_PER_S)
		return target, spun
	end

	-- ------------------------------------------------------------ hop and spin
	h.test("hop arc: ~0.37 s of air and ~2.4 studs apex on flat road", function()
		local air, apex = hopArc()
		h.ok(air > 0.34 and air < 0.40, string.format("air %.3f", air))
		h.ok(apex > 2.2 and apex < 2.6, string.format("apex %.2f studs (walls/rails must stay higher)", apex))
		h.ok(T.HOP_VY < C.MAX_RISE_SPEED, "hop stays inside the server's rise budget")
	end)

	h.test("a flat hop never earns the trick boost; a real ramp jump does", function()
		local air = hopArc()
		h.eq(T.trickBoostEligible(air), false, "flat hop")
		h.eq(T.trickBoostEligible(0.37), false, "0.37 s")
		h.eq(T.trickBoostEligible(0.6), true, "0.6 s ramp jump")
		h.eq(T.trickBoostEligible(T.MIN_AIR), true, "exactly MIN_AIR")
	end)

	h.test("a quick double tap on a flat hop sticks one spin; a slow one or a double spin flubs", function()
		local target, spun = spinAtLanding(0.12, 1)
		h.ok(T.trickLanded(target, spun), string.format("tap at 0.12 s: %d/%d", spun, target))
		target, spun = spinAtLanding(0.17, 1)
		h.ok(T.trickLanded(target, spun), string.format("tap at 0.17 s: %d/%d", spun, target))
		target, spun = spinAtLanding(0.27, 1)
		h.eq(T.trickLanded(target, spun), false, string.format("tap at 0.27 s: %d/%d", spun, target))
		target, spun = spinAtLanding(0.05, 2)
		h.eq(target, 720, "two taps queue a double spin")
		h.eq(T.trickLanded(target, spun), false, "a double spin on a flat hop flubs")
	end)

	h.test("landing verdicts: finished, overshoot within tolerance and short within grace stick", function()
		h.ok(T.trickLanded(360, 360), "finished")
		h.ok(T.trickLanded(-360, -360), "finished left")
		h.ok(T.trickLanded(360, 360 - T.LAND_GRACE_DEG), "short by the grace")
		h.eq(T.trickLanded(360, 360 - T.LAND_GRACE_DEG - 1), false, "short past the grace")
		h.ok(T.trickLanded(-720, -720 + 80), "left double spin nearly done")
		h.eq(T.trickLanded(-720, -400), false, "left double spin half done")
		h.ok(T.trickLanded(0, 20), "cancelled spin back within tolerance")
		h.eq(T.trickLanded(0, 120), false, "cancelled spin far off upright")
	end)

	h.test("queueSpin: needs real steer, caps at two turns either way", function()
		h.eq(T.queueSpin(0, 0.3), 0, "light steer does not spin")
		h.eq(T.queueSpin(0, 0.6), 360)
		h.eq(T.queueSpin(0, -1), -360)
		h.eq(T.queueSpin(T.queueSpin(T.queueSpin(0, 1), 1), 1), 720, "capped")
		h.eq(T.queueSpin(360, -1), 0, "a tap the other way cancels")
	end)

	h.test("canHop: stick centred, rolling, grounded, not drifting or spun out, off cooldown", function()
		h.ok(T.canHop(true, false, false, 0, 80, 0))
		h.eq(T.canHop(true, false, false, 0.4, 80, 0), false, "steering at the press = drift")
		h.eq(T.canHop(false, false, false, 0, 80, 0), false, "airborne")
		h.eq(T.canHop(true, true, false, 0, 80, 0), false, "drifting")
		h.eq(T.canHop(true, false, true, 0, 80, 0), false, "spinning out")
		h.eq(T.canHop(true, false, false, 0, 10, 0), false, "too slow")
		h.eq(T.canHop(true, false, false, 0, 80, 0.2), false, "cooldown")
		h.eq(T.HOP_STEER_MAX, C.DRIFT_STEER_START, "hop/drift split matches the drift start")
		h.eq(T.HOP_MIN_SPEED, C.DRIFT_MIN_SPEED * 0.5)
	end)

	h.test("hop spam on a straight is not faster than driving", function()
		-- Ground: throttle approach as in CarController; air: no thrust; landing keeps LAND_SPEED_KEEP.
		local function run(hops: boolean): number
			local v, x, t, cd, airLeft = C.TOP_SPEED, 0, 0, 0, 0
			local air = hopArc()
			while t < 30 do
				if airLeft > 0 then
					airLeft -= DT
					if airLeft <= 0 then
						v *= C.LAND_SPEED_KEEP
						cd = T.HOP_COOLDOWN
					end
				else
					cd = math.max(0, cd - DT)
					if v < C.TOP_SPEED then
						v = math.min(C.TOP_SPEED, v + math.max(C.ACCEL_MIN, (C.TOP_SPEED - v) * C.ACCEL_RESPONSE) * DT)
					end
					if hops and T.canHop(true, false, false, 0, v, cd) then
						airLeft = air
					end
				end
				x += v * DT
				t += DT
			end
			return x
		end
		local drive, spam = run(false), run(true)
		h.ok(spam <= drive * 1.003, string.format("spam %.0f vs drive %.0f studs", spam, drive))
	end)

	h.test("hop spam across grass or shallows is not faster than driving through (air keeps the surface's braking)", function()
		for _, factor in { C.OFFROAD_SPEED_FACTOR, C.WATER_SPEED_FACTOR } do
			local top = C.TOP_SPEED * factor
			local function brake(v: number): number
				return T.hopAirSpeed(v, top, DT, C.COAST_DECEL, C.OVERSPEED_DECAY)
			end
			local function run(hops: boolean): number
				-- Arrives at full road speed and crosses 2 s of slow ground, gas held.
				local v, x, t, cd, airLeft = C.TOP_SPEED, 0, 0, 0, 0
				local air = hopArc()
				while t < 2 do
					if airLeft > 0 then
						airLeft -= DT
						v = brake(v)
						if airLeft <= 0 then
							v *= C.LAND_SPEED_KEEP
							cd = T.HOP_COOLDOWN
						end
					else
						cd = math.max(0, cd - DT)
						v = brake(v)
						if hops and T.canHop(true, false, false, 0, v, cd) then
							airLeft = air
						end
					end
					x += v * DT
					t += DT
				end
				return x
			end
			local drive, spam = run(false), run(true)
			h.ok(spam <= drive * 1.003, string.format("factor %.2f: spam %.0f vs drive %.0f studs", factor, spam, drive))
		end
		h.eq(T.hopAirSpeed(50, 79, 0.1, 26, 1.6), 50, "below the surface top: untouched")
		h.eq(T.hopAirSpeed(80, 79, 1, 26, 1.6), 79, "never brakes below the surface top")
	end)

	h.test("trick and start rewards reuse the drift tier 1 boost and stay under the legal maximum", function()
		local tier = C.DRIFT_LEVELS[1]
		h.ok(tier.boostSpeed <= C.maxHorizontalSpeed(), "car tier 1 within the validator's bound")
		h.ok(T.BOOST_TIME <= tier.boostDuration and T.START_BOOST_TIME <= tier.boostDuration + 0.05, "no longer than a mini-turbo")
		h.ok(P.BOOST_SPEED <= 260 and P.BOOST_DURATION + T.ROLL_RING_BONUS < P.OVERCHARGE_DURATION, "THREADED stays below an overcharge")
	end)

	-- ------------------------------------------------------------ rev-match start
	local function runStart(pressAt: { { number } }, canFlood: boolean): string
		-- pressAt: list of {from, to} seconds-to-GO intervals with gas held; samples 4.0 s down to 0 at 60 Hz.
		local st = T.newStart()
		local left = 4.0
		local state = "none"
		while left > 0 do
			local pressed = false
			for _, iv in pressAt do
				if left <= iv[1] and left > iv[2] then
					pressed = true
				end
			end
			state = T.stepStart(st, pressed, left, canFlood)
			left -= DT
		end
		return state
	end

	h.test("start: gas held from the 3 floods; released and pressed on the 1 is perfect", function()
		h.eq(runStart({ { 3.0, 0 } }, true), "flooded", "held from 3")
		h.eq(runStart({ { 4.0, 0 } }, true), "flooded", "held through the intro")
		h.eq(runStart({ { 3.0, 1.6 }, { 1.02, 0 } }, true), "perfect", "released, then pressed on the 1")
		h.eq(runStart({ { 1.1, 0 } }, true), "perfect", "pressed just before the 1")
		h.eq(runStart({ { 0.9, 0 } }, true), "perfect", "pressed just after the 1")
	end)

	h.test("start: early or late presses are a normal start, a release clears a flood", function()
		h.eq(runStart({ { 1.6, 0 } }, true), "none", "pressed on the 2")
		h.eq(runStart({ { 0.6, 0 } }, true), "none", "pressed late")
		h.eq(runStart({ { 3.0, 0.4 } }, true), "none", "flooded, then released before GO")
		h.eq(runStart({}, true), "none", "no gas")
		h.eq(runStart({ { 3.0, 0 } }, false), "none", "touch cannot flood")
	end)

	h.test("start: the touch ring counts only inside the window", function()
		local st = T.newStart()
		h.eq(T.tapStart(st, 1.4), "none")
		h.eq(T.tapStart(st, 1.0), "perfect")
		local st2 = T.newStart()
		h.eq(T.tapStart(st2, 0.5), "none")
	end)

	h.test("rev pitch follows the throttle inside SoundJuice's engine range", function()
		h.eq(T.revPitch(0), 0.75)
		h.ok(math.abs(T.revPitch(1) - 1.35) < 1e-9)
		h.eq(T.revPitch(2), T.revPitch(1), "clamped")
	end)

	h.test("roll angle eases 0 -> 360 over ROLL_TIME; grid wobble decays to level", function()
		h.eq(T.rollDeg(T.ROLL_TIME, 1), 0)
		h.eq(T.rollDeg(0, 1), 360)
		h.eq(T.rollDeg(0, -1), -360)
		h.ok(math.abs(T.rollDeg(T.ROLL_TIME / 2, 1) - 180) < 1e-6, "half way at half time")
		h.eq(T.gridWobbleDeg(T.GRID_WOBBLE_TIME, 1), 0)
		h.ok(math.abs(T.gridWobbleDeg(0.08, 1)) <= T.GRID_WOBBLE_DEG, "bounded")
	end)

	h.test("wrap180 and approach", function()
		h.eq(T.wrap180(190), -170)
		h.eq(T.wrap180(-190), 170)
		h.eq(T.wrap180(720), 0)
		h.eq(T.approach(0, 10, 3), 3)
		h.eq(T.approach(9, 10, 3), 10)
		h.eq(T.approach(0, -10, 3), -3)
	end)
end
