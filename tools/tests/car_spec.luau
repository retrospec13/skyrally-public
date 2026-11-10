--!strict
-- Lune spec for the launch car's pure logic in src/shared/CarConfig.luau (PLAN L2, TEST_LIST_LAUNCH L05):
-- turn-rate curve, drift charge levels and mini-turbo data, four-probe airborne/landing detection, suspension
-- correction, wall response classes, and the server's displacement validator (bounds, replication bursts,
-- teleport grace). The Roblox-facing CarController/CarServer use exactly these functions.
-- Run: tools/tests/run_lune_tests.sh tools/tests/car_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
}

return function(h: Harness)
	local C = h.require("src/shared/CarConfig.luau")
	local R = C.WHEEL_RADIUS
	local HUGE = math.huge

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	-- ------------------------------------------------------------ turn-rate curve
	h.test("turn rate is zero at standstill and peaks at FULL_TURN_SPEED", function()
		h.eq(C.turnRate(0), 0, "no turning on the spot")
		h.ok(near(C.turnRate(C.FULL_TURN_SPEED), C.TURN_RATE_MAX), "peak at FULL_TURN_SPEED")
		h.ok(C.turnRate(5) > 0 and C.turnRate(5) < C.TURN_RATE_MAX, "low speeds turn a little")
	end)

	h.test("turn rate rises to the peak, then eases to the high-speed factor and holds above top speed", function()
		local prev = -1
		for v = 0, C.FULL_TURN_SPEED, 2 do
			local r = C.turnRate(v)
			h.ok(r >= prev, string.format("non-decreasing up to the peak (v=%d)", v))
			prev = r
		end
		prev = math.huge
		for v = C.FULL_TURN_SPEED, C.TOP_SPEED, 4 do
			local r = C.turnRate(v)
			h.ok(r <= prev + 1e-9, string.format("non-increasing from the peak to top speed (v=%d)", v))
			prev = r
		end
		local atTop = C.TURN_RATE_MAX * C.HIGH_SPEED_TURN_FACTOR
		h.ok(near(C.turnRate(C.TOP_SPEED), atTop), "top speed rate = max * HIGH_SPEED_TURN_FACTOR")
		h.ok(near(C.turnRate(C.PAD_BOOST_SPEED), atTop), "boost speed keeps the top-speed rate")
	end)

	h.test("turn rate is symmetric for reverse and gives a ~94 stud radius flat out", function()
		h.ok(near(C.turnRate(-30), C.turnRate(30)), "reverse uses |speed|")
		local radius = C.TOP_SPEED / math.rad(C.turnRate(C.TOP_SPEED))
		h.ok(radius > 80 and radius < 110, string.format("flat-out radius %.1f studs", radius))
		local driftRadius = C.TOP_SPEED / math.rad(C.turnRate(C.TOP_SPEED) * C.DRIFT_TURN_MAX)
		h.ok(driftRadius < radius * 0.8, string.format("tight drift radius %.1f is well inside the grip radius", driftRadius))
	end)

	-- ------------------------------------------------------------ drift
	h.test("drift levels: thresholds strictly increase, blue then orange, each boost stronger", function()
		local levels = C.DRIFT_LEVELS
		h.ok(#levels >= 2, "at least the blue and orange mini-turbo levels")
		h.eq(levels[1].name, "Blue")
		h.eq(levels[2].name, "Orange")
		h.ok(levels[1].color[3] > levels[1].color[1], "level 1 sparks are blue")
		h.ok(levels[2].color[1] > levels[2].color[3], "level 2 sparks are orange")
		for i = 2, #levels do
			h.ok(levels[i].threshold > levels[i - 1].threshold, "thresholds increase")
			h.ok(levels[i].boostSpeed >= levels[i - 1].boostSpeed, "boost speed does not drop with level")
			h.ok(levels[i].boostDuration > levels[i - 1].boostDuration, "longer boost per level")
		end
		for _, lv in levels do
			h.ok(lv.boostState == "Standard" or lv.boostState == "Overcharge", "boost state is a Vfx/SoundJuice family")
			h.ok(lv.boostSpeed > C.TOP_SPEED, "a mini-turbo is faster than full throttle")
		end
	end)

	h.test("driftLevel maps charge to the highest reached level", function()
		local t1, t2 = C.DRIFT_LEVELS[1].threshold, C.DRIFT_LEVELS[2].threshold
		h.eq(C.driftLevel(0), 0)
		h.eq(C.driftLevel(t1 - 0.001), 0)
		h.eq(C.driftLevel(t1), 1)
		h.eq(C.driftLevel(t2 - 0.001), 1)
		h.eq(C.driftLevel(t2), 2)
		h.eq(C.driftLevel(1e6), #C.DRIFT_LEVELS)
	end)

	h.test("steering into the drift charges faster and tightens; steering out widens but still turns", function()
		local dir = 1
		h.ok(C.driftChargeRate(1, dir) > C.driftChargeRate(0, dir), "into the turn charges faster")
		h.eq(C.driftChargeRate(-1, dir), C.DRIFT_CHARGE_BASE, "counter-steer never charges below the base rate")
		h.ok(near(C.driftTurnMultiplier(1, dir), C.DRIFT_TURN_MAX), "full into = tightest")
		h.ok(near(C.driftTurnMultiplier(-1, dir), C.DRIFT_TURN_MIN), "full out = widest")
		h.ok(C.DRIFT_TURN_MIN > 0, "a drift never straightens out")
		h.ok(near(C.driftTurnMultiplier(-0.5, -1), C.driftTurnMultiplier(0.5, 1)), "mirror for left drifts")
	end)

	h.test("a held drift reaches blue then orange at the expected times (60 Hz integration)", function()
		local dt = 1 / 60
		local function timeToLevel(steer: number, level: number): number
			local charge, t = 0, 0
			while C.driftLevel(charge) < level and t < 10 do
				charge += C.driftChargeRate(steer, 1) * dt
				t += dt
			end
			return t
		end
		local blueNeutral = timeToLevel(0, 1)
		local blueTight = timeToLevel(1, 1)
		local orangeTight = timeToLevel(1, 2)
		h.ok(near(blueNeutral, C.DRIFT_LEVELS[1].threshold / C.DRIFT_CHARGE_BASE, dt * 1.01), "neutral blue time")
		h.ok(blueTight < blueNeutral, "tight drift charges blue sooner")
		h.ok(orangeTight > blueTight and orangeTight < 2.0, string.format("orange at %.2fs holding into the turn", orangeTight))
	end)

	-- ------------------------------------------------------------ ground probes
	h.test("four wheels on the road = grounded; one or none = airborne", function()
		h.eq({ C.resolveGrounded(true, { R, R, R, R }, 0) }, { true, 4 })
		h.eq({ C.resolveGrounded(true, { R, R, HUGE, HUGE }, 0) }, { true, 2 }, "two wheels still hold (ramp lip, rear on deck)")
		h.eq({ C.resolveGrounded(true, { R, HUGE, HUGE, HUGE }, 0) }, { false, 1 }, "one wheel is not enough")
		h.eq({ C.resolveGrounded(true, { HUGE, HUGE, HUGE, HUGE }, 0) }, { false, 0 }, "off the ramp into the gap")
		h.ok(C.isAirborne(true, { HUGE, HUGE, HUGE, HUGE }, 0))
	end)

	h.test("grounded cars stick over crests; airborne cars land only on real contact", function()
		local crest = R + C.SNAP_GROUNDED * 0.8 -- road dropping away under the wheels at a crest
		h.eq((C.resolveGrounded(true, { crest, crest, crest, crest }, 0)), true, "sticks over a crest")
		h.eq((C.resolveGrounded(false, { crest, crest, crest, crest }, -5)), false, "airborne: not landed yet")
		local touch = R + C.SNAP_LANDING * 0.5
		h.eq((C.resolveGrounded(false, { touch, touch, touch, touch }, -30)), true, "falling onto the road lands")
		h.eq((C.resolveGrounded(false, { touch, touch, touch, touch }, 15)), false, "still rising off a ramp: no landing")
		local beyond = R + C.SNAP_GROUNDED + 0.01
		h.eq((C.resolveGrounded(true, { beyond, beyond, beyond, beyond }, 0)), false, "a drop past the snap distance launches")
	end)

	h.test("ground correction uses the median wheel so a paver seam does not dip the car", function()
		h.eq(C.groundCorrection({ R, R, R, R + 1.1 }, true), 0, "one wheel in a seam")
		h.ok(near(C.groundCorrection({ R - 0.3, R - 0.3, R, R }, true), 0.15), "front wheels climbing a ramp lift by half")
		h.ok(near(C.groundCorrection({ R + 0.4, R + 0.4, R + 0.4, R + 0.4 }, true), -0.4), "crest: drop onto the road")
		h.eq(C.groundCorrection({ HUGE, HUGE, HUGE, HUGE }, true), 0, "no contact = no correction")
		h.ok(near(C.groundCorrection({ R - 0.2, HUGE, R - 0.4, HUGE }, true), 0.3), "two contacts average")
	end)

	h.test("ride height matches the wheel geometry", function()
		for i, w in C.WHEELS do
			h.ok(near(C.RIDE_HEIGHT, R - w[2]), "wheel " .. i .. " rests exactly on the road at RIDE_HEIGHT")
			h.ok(w[3] ~= 0, "wheels are fore or aft of the centre")
		end
		h.eq(#C.WHEELS, #C.WHEEL_NAMES)
		h.ok(C.WHEELS[1][3] < 0 and C.WHEELS[3][3] > 0, "FL is forward (-Z), RL is aft")
	end)

	-- ------------------------------------------------------------ walls
	h.test("wall hits: shallow deflects, steep bumps, hard and fast spins, moving away ignores", function()
		h.eq(C.classifyWallHit(-0.2, 120), "None")
		h.eq(C.classifyWallHit(0.2, 120), "Deflect")
		h.eq(C.classifyWallHit(C.WALL_SHALLOW_DOT - 0.01, 160), "Deflect", "just under the shallow limit")
		h.eq(C.classifyWallHit(0.6, 120), "Bump")
		h.eq(C.classifyWallHit(0.95, C.WALL_SPIN_MIN_SPEED - 1), "Bump", "head-on but slow: no spin-out")
		h.eq(C.classifyWallHit(0.95, C.WALL_SPIN_MIN_SPEED), "Spin")
		h.eq(C.classifyWallHit(0.95, -C.WALL_SPIN_MIN_SPEED), "Spin", "reversing into a wall fast counts too")
	end)

	-- ------------------------------------------------------------ displacement bounds
	h.test("legal speed bound covers every boost source", function()
		local m = C.maxHorizontalSpeed()
		h.ok(m >= C.PAD_BOOST_SPEED and m >= C.ITEM_BOOST_MAX_SPEED, "pads and items")
		for _, lv in C.DRIFT_LEVELS do
			h.ok(m >= lv.boostSpeed, "mini-turbo " .. lv.name)
		end
		h.ok(m >= C.TOP_SPEED + C.SPEED_PICKUP_BONUS * C.MAX_SPEED_PICKUPS, "speed pickups")
	end)

	h.test("checkDisplacement: allowed = maxSpeed * dt * slack + tolerance, per axis", function()
		local dt = 1 / 30
		local ok, allowedH, allowedV = C.checkDisplacement(C.maxHorizontalSpeed() * dt, 0, dt)
		h.ok(ok, "full legal speed passes")
		h.ok(near(allowedH, C.maxHorizontalSpeed() * dt * C.VALIDATION_SLACK + C.VALIDATION_TOLERANCE), "horizontal formula")
		h.ok(near(allowedV, C.MAX_RISE_SPEED * dt * C.VALIDATION_SLACK + C.VALIDATION_TOLERANCE), "vertical (rising) formula")
		h.eq((C.checkDisplacement(allowedH + 0.01, 0, dt)), false, "just over the horizontal bound")
		h.eq((C.checkDisplacement(0, -C.MAX_FALL_SPEED * dt, dt)), true, "terminal-velocity fall")
		h.eq((C.checkDisplacement(0, C.MAX_FALL_SPEED * dt * 2 + C.VALIDATION_TOLERANCE, dt)), false, "rising at fall speed is not legal")
		h.eq((C.checkDisplacement(500, 0, 60)), false, "a long stall earns at most VALIDATION_MAX_DT of travel")
	end)

	-- ------------------------------------------------------------ validator (server)
	h.test("validator accepts a legal 60 Hz drive and flags a teleport", function()
		local v = C.newValidator()
		local t, x = 100, 0
		local verdict = C.observe(v, x, 20, 0, t)
		h.eq(verdict, "ok", "first sample")
		for _ = 1, 120 do
			t += 1 / 60
			x += C.PAD_BOOST_SPEED / 60
			verdict = C.observe(v, x, 20, 0, t)
			h.eq(verdict, "ok", "boosting along the road")
		end
		t += 1 / 60
		local tv, dist, allowed = C.observe(v, x + 500, 20, 0, t)
		h.eq(tv, "violation")
		h.ok(dist > allowed, "reported distance exceeds the allowance")
		h.ok(near(v.x, x), "last valid position is kept for the correction")
	end)

	h.test("validator judges a replication burst over the whole stall, not one frame", function()
		local v = C.newValidator()
		C.observe(v, 0, 20, 0, 10)
		local t = 10
		for _ = 1, 12 do -- 0.2 s of identical replicated positions (packets delayed)
			t += 1 / 60
			h.eq((C.observe(v, 0, 20, 0, t)), "idle")
		end
		t += 1 / 60
		local moved = C.TOP_SPEED * (t - 10)
		h.eq((C.observe(v, moved, 20, 0, t)), "ok", "13 frames of travel arriving at once")
	end)

	h.test("validator teleport grace: server respawn target accepted, a stray position waits, expiry re-judges", function()
		local v = C.newValidator()
		C.observe(v, 0, 20, 0, 0)
		C.expectTeleport(v, 900, 32, 0, 1)
		h.eq((C.observe(v, 0.5, 20, 0, 1.01)), "grace", "old position before the client applied the respawn")
		h.eq((C.observe(v, 900, 20.5, 0, 1.2)), "ok", "landed on the deck under the respawn frame")
		h.ok(not v.hasGrace and near(v.x, 900), "grace cleared, respawn point is the new reference")

		local w = C.newValidator()
		C.observe(w, 0, 20, 0, 0)
		C.expectTeleport(w, 900, 32, 0, 1)
		local verdict = C.observe(w, 0.4, 20, 0, 1 + C.TELEPORT_GRACE_TIME + 0.1)
		h.eq(verdict, "violation", "a client that never applies the teleport is corrected to the target")
		h.ok(near(w.x, 900), "reference moved to the teleport target")
	end)

	h.test("validator bounds the sustained rate: 14 studs per 60 Hz sample (6x top speed) is flagged", function()
		local dt = 1 / 60
		local step = 14
		-- Each sample on its own is inside the one-gap bound; the old per-sample check accepted this forever.
		h.ok((C.checkDisplacement(step, 0, dt)), "one sample passes the one-gap bound")
		local v = C.newValidator()
		local t, x = 50, 0
		C.observe(v, x, 20, 0, t)
		local flaggedAt: number? = nil
		for i = 1, 120 do
			t += dt
			x += step
			local verdict = C.observe(v, x, 20, 0, t)
			if verdict == "violation" then
				flaggedAt = i
				break
			end
		end
		h.ok(flaggedAt ~= nil and (flaggedAt :: number) <= 60, string.format("flagged within a second (sample %s)", tostring(flaggedAt)))
	end)

	h.test("validator: legal top speed with uneven replication bursts passes for 10 s; accepted travel stays bounded", function()
		local v = C.newValidator()
		local legal = C.maxHorizontalSpeed()
		local t, x = 0, 0
		C.observe(v, x, 20, 0, t)
		local pattern = { 1, 1, 4, 1, 2, 7, 1, 1, 3 } -- frames between packets (bursty network)
		local frame = 0
		local i = 0
		while t < 10 do
			i += 1
			local frames = pattern[(i - 1) % #pattern + 1]
			for _ = 1, frames - 1 do
				frame += 1
				t = frame / 60
				h.eq((C.observe(v, x, 20, 0, t)), "idle", "no packet this frame")
			end
			frame += 1
			t = frame / 60
			x = legal * t
			local verdict = C.observe(v, x, 20, 0, t)
			h.eq(verdict, "ok", string.format("legal max speed at t=%.2f", t))
		end
		-- Any accepted path is bounded by the earn rate plus one cap, whatever the sample rate.
		local capH = C.budgetCaps()
		h.ok(x <= legal * C.VALIDATION_SLACK * t + capH, "travel bound holds")
	end)

	h.test("validator: a long stall earns at most one VALIDATION_MAX_DT of travel, then the budget is spent", function()
		local v = C.newValidator()
		C.observe(v, 0, 20, 0, 0)
		local capH = C.budgetCaps()
		h.eq((C.observe(v, capH + 1, 20, 0, 60)), "violation", "past the cap after a 60 s stall")
		h.eq((C.observe(v, capH - 1, 20, 0, 60)), "ok", "just inside the cap")
		h.eq((C.observe(v, capH + 20, 20, 0, 60 + 1 / 60)), "violation", "the cap was spent: no second burst")
	end)

	h.test("validator: arriving at a server teleport restarts the budget at the tolerance (no stored-up burst)", function()
		local v = C.newValidator()
		C.observe(v, 0, 20, 0, 0)
		C.observe(v, 0, 20, 0, 30) -- long idle: budget full
		C.expectTeleport(v, 500, 20, 0, 30)
		h.eq((C.observe(v, 505, 20, 0, 30.1)), "ok", "arrived at the respawn frame")
		h.ok(near(v.budgetH, C.VALIDATION_TOLERANCE), "budget restarts at the tolerance")
		local t = 30.1 + 1 / 60
		local allowed = C.VALIDATION_TOLERANCE + C.maxHorizontalSpeed() * C.VALIDATION_SLACK / 60
		h.eq((C.observe(v, 505 + allowed + 1, 20, 0, t)), "violation", "a jump right after the teleport is judged from zero")
	end)

	-- ------------------------------------------------------------ data contract
	h.test("controls hints cover every InputMode family and pace stays in the plane's band", function()
		for _, family in { "Touch", "Gamepad", "KeyboardMouse" } do
			h.ok(type(C.HINTS[family]) == "string" and #C.HINTS[family] > 0, "hint for " .. family)
		end
		-- PlaneConfig: cruise 110, full throttle 128, boost 165 (it builds Color3 at load, so the numbers are inlined).
		h.ok(C.TOP_SPEED >= 110 and C.TOP_SPEED <= 165, "car top speed inside the plane's race pace")
		h.eq(C.PAD_BOOST_SPEED, 165, "pad boost equals the plane's pad boost")
		h.ok(C.DRIFT_LEVELS[#C.DRIFT_LEVELS].boostSpeed <= 165, "mini-turbos never beat a pad boost")
		-- Blue is an item pod (ItemRules.classifyPod): an instant pickup boost on top of the granted item boosts twice.
		h.eq(C.BLUE_POD_INSTANT_BOOST, false, "Blue pods do not boost on pickup")
		h.ok(#C.HINTS.Touch <= 70, string.format("touch hint fits 740 px at a readable size (%d chars)", #C.HINTS.Touch))
	end)
end
