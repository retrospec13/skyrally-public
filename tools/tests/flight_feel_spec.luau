--!strict
-- Lune spec for the flight feel pass (docs/audits/flight_feel.md): the pure curves in shared/PlaneConfig that
-- FlightController applies to plane steering. Car handling is not touched (guarded at the end).
--   1. Turn radii: cruise, sharp and the boosted radius against the bends after rings (C4).
--   2. Touch pad: dead zones (a sideways drag does not pitch) and the expo curve (C2).
--   3. Gamepad stick: radial dead zone, direction kept, expo (C2).
--   4. Keyboard ramp: a tap is a nudge, a hold reaches full lock, release and reversal (C2).
--   5. Pitch: auto-level scaled by the stick's headroom, settle pitches, release overshoot, never against the assist (C1).
--   6. Assist blend: full deflection is the player's, partial input gets a headroom share, idle gets all (C3).
--   7. Ring magnetism: the simulated catch widens from ~23 to ~29 studs (C6).
--   8. Camera turn lead and the gentler leash (C5, C7).
--   9. Source guards: FlightController uses the curves; CarController untouched.
-- Run: tools/tests/run_lune_tests.sh tools/tests/flight_feel_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local P = h.require("src/shared/PlaneConfig.luau")

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	h.test("1. turn radii: boosting no longer turns wider than the bends after rings", function()
		h.ok(near(P.turnRadius(110, P.YAW_RATE), 84.0, 0.1), "cruise R 84")
		h.ok(near(P.turnRadius(110, P.SHARP_YAW_RATE), 43.5, 0.1), "sharp R 43.5")
		local boosted = P.turnRadius(P.BOOST_SPEED, P.BOOST_YAW_RATE)
		h.ok(near(boosted, 111.2, 0.1), string.format("boosted R %.1f (was 145.4 at 65 deg/s)", boosted))
		h.ok(boosted > P.turnRadius(110, P.YAW_RATE), "a boost still turns wider than cruise (a commitment)")
		-- Bends right after rings (flight_feel.md table): R 114 DINO-4 st 1900, R 131 SNOW-1 st 4520. The outer corridor
		-- edge is the bend radius + 34: a boosted plane now fits inside both with room to spare.
		h.ok(boosted + 0 <= 114 + 34 - 30, "DINO-4 hairpin after BoosterRing st 1835 fits with >= 30 studs spare")
		h.ok(boosted <= 131, "SNOW-1 st 4520 bend after the st 4385 ring is takeable on the line")
		h.ok(P.BOOST_YAW_RATE < P.SHARP_YAW_RATE, "sharp bank still turns tighter while boosting")
	end)

	h.test("2. touch pad: dead zones and expo", function()
		h.eq({ P.shapeTouch(0, 0) }, { 0, 0 })
		h.eq({ P.shapeTouch(0.05, 0.05) }, { 0, 0 }, "inside the radial dead zone")
		-- A sideways drag with a 15 degree thumb drift: was (0.97, 0.26) of steer, the pitch half of it climbing.
		local x, y = P.shapeTouch(math.cos(math.rad(15)), math.sin(math.rad(15)))
		h.eq(y, 0, "a drifting sideways drag does not pitch")
		h.ok(x > 0.9, string.format("and still turns nearly fully (%.2f)", x))
		local fx, fy = P.shapeTouch(1, 1)
		h.ok(near(fx, 1) and near(fy, 1), "full deflection is full steer on both axes")
		local _, upOnly = P.shapeTouch(0, 0.6)
		h.ok(upOnly > 0.2 and upOnly < 0.6, string.format("a deliberate pitch still pitches, softened (%.2f)", upOnly))
		-- Expo: a small correction is smaller than linear, monotonic, and continuous at the dead zone.
		local small = P.shapeTouch(0.3, 0)
		h.ok(small < 0.3 * 0.9, string.format("0.3 of pad -> %.2f of steer", small))
		local last = -1
		for i = 0, 100 do
			local v = P.shapeAxis(i / 100, P.TOUCH_DEADZONE, P.TOUCH_EXPO)
			h.ok(v >= last - 1e-9, "monotonic")
			last = v
		end
		h.ok(near(P.shapeAxis(P.TOUCH_DEADZONE + 1e-6, P.TOUCH_DEADZONE, P.TOUCH_EXPO), 0, 1e-4), "no step at the dead zone")
		h.ok(near(P.shapeAxis(-0.5, 0.1, 0.4), -P.shapeAxis(0.5, 0.1, 0.4)), "odd")
	end)

	h.test("3. gamepad stick: radial dead zone, direction kept, expo", function()
		h.eq({ P.shapeStick(0.1, 0.1) }, { 0, 0 }, "inside 0.15")
		local x, y = P.shapeStick(0.6, 0.8)
		h.ok(near(x / y, 0.75, 1e-6), "direction kept")
		h.ok(near(math.sqrt(x * x + y * y), 1, 1e-6), "full magnitude stays full")
		local hx = P.shapeStick(0.5, 0)
		local linear = (0.5 - 0.15) / 0.85
		h.ok(hx < linear and hx > linear * 0.6, string.format("half stick %.2f (linear was %.2f)", hx, linear))
	end)

	h.test("4. keyboard ramp: tap nudges, hold reaches full lock, release and reversal", function()
		local dt = 1 / 60
		local v = 0
		for _ = 1, 3 do -- a 50 ms tap
			v = P.rampKey(v, 1, dt)
		end
		h.ok(v > 0.25 and v < 0.4, string.format("50 ms tap -> %.2f (was 1)", v))
		local t = 0.05
		while v < 1 do
			v = P.rampKey(v, 1, dt)
			t += dt
		end
		h.ok(near(t, P.KEY_RISE_S, dt * 1.5), string.format("full lock after %.2f s", t))
		local r = 0
		while v > 0 do
			v = P.rampKey(v, 0, dt)
			r += dt
		end
		h.ok(near(r, P.KEY_FALL_S, dt * 1.5), string.format("released in %.2f s", r))
		h.eq(v, 0, "lands on zero exactly")
		v = 1
		v = P.rampKey(v, -1, dt)
		h.ok(near(v, 1 - dt / P.KEY_FALL_S), "a reversal first unwinds at the fall rate")
		h.eq(P.rampKey(0.5, 0.5, dt), 0.5, "steady")
	end)

	h.test("5. pitch: auto-level scales with the stick's headroom", function()
		local dt = 1 / 60
		local function settle(y: number): number
			local p = 0
			for _ = 1, 60 * 8 do
				p = P.pitchStep(p, y, P.PITCH_RATE, P.MAX_PITCH_DEG, dt, 1)
			end
			return p
		end
		h.ok(near(settle(0), P.PITCH_LEVEL_TARGET, 1e-3), "idle levels to the target")
		local p3, p5 = settle(0.3), settle(0.5)
		h.ok(p3 > 6 and p3 < 12, string.format("0.3 held settles at %.1f deg (was a climb to 52)", p3))
		h.ok(p5 > 19 and p5 < 27, string.format("0.5 held settles at %.1f deg", p5))
		h.eq(settle(1), P.MAX_PITCH_DEG, "full deflection still climbs to the limit")
		h.eq(settle(-1), -P.MAX_PITCH_DEG, "and dives")
		-- Release from a 30 degree climb at 110 studs/s: the rise before level was ~32 studs (1.4/s); now ~17.
		local function overshoot(levelRate: number): number
			local p, rise = 30, 0
			for _ = 1, 60 * 4 do
				p += (P.PITCH_LEVEL_TARGET - p) * math.clamp(dt * levelRate, 0, 1)
				rise += math.max(0, 110 * math.sin(math.rad(p)) * dt)
			end
			return rise
		end
		local before, after = overshoot(1.4), overshoot(P.PITCH_LEVEL_RATE)
		local p, rise = 30, 0
		for _ = 1, 60 * 4 do
			p = P.pitchStep(p, 0, P.PITCH_RATE, P.MAX_PITCH_DEG, dt, 1)
			rise += math.max(0, 110 * math.sin(math.rad(p)) * dt)
		end
		h.ok(near(rise, after, 1e-6), "pitchStep is that release")
		h.ok(before > 30 and before < 36, string.format("old release rise %.1f studs (above the 30 of corridor over the line)", before))
		h.ok(after < 20, string.format("new release rise %.1f studs", after)); print(string.format("release rise %.1f -> %.1f", before, after))
		-- level = 0 (the assist holds the pitch axis): no levelling at all.
		h.eq(P.pitchStep(10, 0, P.PITCH_RATE, P.MAX_PITCH_DEG, dt, 0), 10, "never against the course assist")
		h.eq(P.pitchStep(0, 1, P.PITCH_RATE, 5, 1, 1), 5, "clamped")
	end)

	h.test("6. assist blend: full deflection is the player's; partial gets a headroom share; idle gets all", function()
		h.eq({ P.assistAxis(1, -0.9, 0) }, { 1, 0 }, "full lock: the player's value unchanged (L03)")
		h.eq({ P.assistAxis(-1, 0.9, 1) }, { -1, 0 }, "either side")
		local v, share = P.assistAxis(0.4, 0.8, 0)
		h.ok(near(share, P.ASSIST_UNDER_INPUT * 0.6), "share = UNDER x headroom while held")
		h.ok(near(v, 0.4 + 0.8 * share), string.format("partial input helped: %.2f", v))
		h.ok(P.assistAxis(0.4, -0.8, 0) > 0, "the assist never overturns a held stick")
		local idle0 = P.assistAxis(0, 0.8, 0)
		h.ok(near(idle0, 0.8 * P.ASSIST_UNDER_INPUT), "just released: the under-input share, no gap (was 0)")
		h.ok(near(P.assistAxis(0, 0.8, 1), 0.8), "idle: all of it")
		h.ok(near(P.assistAxis(0.051, 0.8, 0), idle0, 0.05), "continuous at the input threshold")
		h.ok(P.ASSIST_RELEASE_S < 0.6, "the idle assist returns sooner than before (0.6 s)")
		-- Pursuit: a shorter lookahead pulls a drifted plane back faster (cross-track time constant lookahead / speed).
		h.ok(near(P.assistLookahead(110), 99), "99 studs at cruise (was 114.5)")
		h.ok(P.assistLookahead(110) / 110 < 0.95, "cross-track time constant under 0.95 s")
		h.ok(P.assistLookahead(165) > 2 * 165 * (P.ASSIST_YAW_GAIN_DEG / P.YAW_RATE) * 0.5,
			"lookahead well past the yaw response distance (no weave)")
	end)

	h.test("7. ring magnetism: simulated catch widens", function()
		-- A plane flying straight at 110 studs/s toward a ring; returns the widest starting offset that still passes
		-- inside RING_TRIGGER_RADIUS, for a pull model.
		local function catch(pull: (number, number) -> number, dist: number): number
			local best = 0
			for start = 0, 40, 0.5 do
				local lat, fwd, dt = start, dist + 20, 1 / 60
				local hit = false
				while fwd > -6 do
					local d = math.sqrt(lat * lat + fwd * fwd)
					if d <= P.RING_TRIGGER_RADIUS then
						hit = true
						break
					end
					lat = math.max(0, lat - pull(fwd, lat) * dt)
					fwd -= 110 * dt
				end
				if hit then
					best = start
				end
			end
			return best
		end
		local function old(fwd: number, lat: number): number
			if fwd > -4 and fwd < 55 and lat < 30 then
				return 18 * (1 - fwd / 55)
			end
			return 0
		end
		local before = catch(old, 55)
		local after = catch(P.ringPull, P.RING_PULL_DISTANCE)
		h.ok(before >= 21 and before <= 25, string.format("old catch %.1f studs", before))
		h.ok(after >= 27, string.format("new catch %.1f studs", after))
		h.eq(P.ringPull(P.RING_PULL_DISTANCE + 1, 0), 0, "nothing beyond the window")
		h.eq(P.ringPull(10, P.RING_PULL_RADIUS), 0, "nothing outside the radius")
		h.ok(P.ringPull(-3, 0) <= P.RING_PULL_STRENGTH, "capped at full strength")
	end)

	h.test("8. camera turn lead and the gentler leash", function()
		h.eq(P.camLeadDeg(0), 0)
		h.ok(near(P.camLeadDeg(P.YAW_RATE), P.YAW_RATE * P.CAM_TURN_LEAD_S), "cruise turn: 12 deg of lead")
		h.eq(P.camLeadDeg(1000), P.CAM_TURN_LEAD_MAX_DEG, "capped")
		h.eq(P.camLeadDeg(-1000), -P.CAM_TURN_LEAD_MAX_DEG, "both ways")
		h.ok(P.CAM_TURN_LEAD_MAX_DEG < P.CAM_BASE_FOV / 4, "the plane stays well inside the view")
		h.ok(near(P.leashWeight(P.LEASH_WARN + 0.001), P.LEASH_MIN_PULL, 1e-3), "leash starts at its minimum")
		h.ok(P.LEASH_MIN_PULL <= 0.2, "a nudge, not a yank (was 0.35)")
		h.eq(P.leashWeight(P.LEASH_FULL), 1, "still all of it at LEASH_FULL")
	end)

	h.test("9. source guards: FlightController uses the curves; car handling untouched", function()
		local fc = h.readFile("src/client/FlightController.luau")
		for _, needle in { "PlaneConfig.shapeTouch(", "PlaneConfig.shapeStick(", "PlaneConfig.rampKey(", "PlaneConfig.pitchStep(",
			"PlaneConfig.assistAxis(", "PlaneConfig.assistLookahead(", "PlaneConfig.ringPull(", "PlaneConfig.camLeadDeg(" } do
			h.ok(string.find(fc, needle, 1, true) ~= nil, needle)
		end
		h.ok(string.find(fc, "local ASSIST_RELEASE_S", 1, true) == nil, "the release time lives in PlaneConfig")
		local car = h.readFile("src/client/CarController.luau")
		h.ok(string.find(car, "PlaneConfig.shape", 1, true) == nil and string.find(car, "pitchStep", 1, true) == nil,
			"the car controller does not use the plane curves")
	end)
end
