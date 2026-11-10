--!strict
-- Lune spec for reverse v2 (shared/ReverseRules; owner 2026-10-21 "going in reverse is an awful experience"): the brake /
-- hold / reverse state machine (MK rule: stop, keep holding, then back up), the reverse speed curve and cap, the reverse turn
-- rate and its sign, quick three-point turns, the camera's calmer reverse framing, and the car WRONG WAY sign. Source guards
-- pin the CarController wiring and the OWNER RULE: adhesion, walls, barriers, kill volumes and rescue timings are untouched.
-- Run: tools/tests/run_lune_tests.sh tools/tests/reverse_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
	contains: (string, string, string?) -> (),
}

return function(h: Harness)
	local R = h.require("src/shared/ReverseRules.luau")
	local C = h.require("src/shared/CarConfig.luau")
	local DT = 1 / 60

	-- Drive the state machine and the speed curve like CarController's ground branch (no slope, no boost).
	local function run(s: any, speed: number, throttle: number, seconds: number): (number, string, number)
		local mode = "drive"
		local firstNeg = -1
		local t = 0
		for _ = 1, math.floor(seconds * 60 + 0.5) do
			t += DT
			mode = R.step(s, throttle, speed, DT)
			if mode ~= "drive" then
				speed = R.stepSpeed(mode, speed, -throttle, DT)
			end
			if firstNeg < 0 and speed < 0 then
				firstNeg = t
			end
		end
		return speed, mode, firstNeg
	end

	h.test("state machine: brake while rolling, hold at the stop, reverse only after REVERSE_DELAY, release drives", function()
		local s = R.newState()
		h.eq(R.step(s, 0, 50, DT), "drive", "no input")
		h.eq(R.step(s, 1, 50, DT), "drive", "gas")
		h.eq(R.step(s, -1, 50, DT), "brake", "brake while rolling forward")
		h.eq(R.step(s, -1, 0, DT), "hold", "stopped: the delay starts")
		local t = DT
		local mode = "hold"
		while t < R.REVERSE_DELAY - DT * 0.5 do
			mode = R.step(s, -1, 0, DT)
			t += DT
			if t < R.REVERSE_DELAY - 1e-6 then
				h.eq(mode, "hold", string.format("still holding at %.2f s", t))
			end
		end
		h.eq(R.step(s, -1, 0, DT), "reverse", "after the delay")
		h.eq(R.step(s, -1, -10, DT), "reverse", "stays in reverse while held")
		h.eq(R.step(s, 0, -10, DT), "drive", "let go: drive (coast / gas)")
		h.eq(R.step(s, -1, -10, DT), "reverse", "already rolling backwards: brake = reverse at once")
	end)

	h.test("a hard brake from top speed stops and stays stopped (no accidental roll-back), then reverses", function()
		local s = R.newState()
		local speed, _, firstNeg = run(s, C.TOP_SPEED, -1, 0.85 + 0.2)
		h.ok(speed >= 0, "still not rolling back 0.2 s after the stop")
		h.eq(firstNeg, -1)
		local s2 = R.newState()
		local _, mode2, firstNeg2 = run(s2, C.TOP_SPEED, -1, 2.5)
		h.eq(mode2, "reverse")
		local stopAt = C.TOP_SPEED / C.BRAKE_DECEL
		h.ok(firstNeg2 >= stopAt + R.REVERSE_DELAY - 0.05, string.format("first backwards motion at %.2f s (stop %.2f + delay)", firstNeg2, stopAt))
	end)

	h.test("a brake tap at a stop never reverses (v27 rolled back at once)", function()
		local s = R.newState()
		local speed, mode = run(s, 0, -1, R.REVERSE_DELAY - 0.08)
		h.eq(speed, 0)
		h.eq(mode, "hold")
	end)

	h.test("a long frame never fills the delay by itself", function()
		local s = R.newState()
		h.eq(R.step(s, -1, 0, 1.0), "hold")
	end)

	h.test("brake never overshoots into reverse inside one frame", function()
		for _, v in { 0.5, 2.5, 5, 40, 128 } do
			local out = R.stepSpeed("brake", v, 1, 0.05)
			h.ok(out >= 0, "brake from " .. v)
		end
		h.eq(R.stepSpeed("hold", 1.5, 1, DT), math.max(0, 1.5 - C.BRAKE_DECEL * DT))
		h.eq(R.stepSpeed("hold", -1.5, 1, 0.05), 0)
	end)

	h.test("reverse curve: cap REVERSE_DRIVE_SPEED, quick pick-up, a part pull still backs up at MIN_REVERSE_MAG", function()
		h.ok(C.REVERSE_DRIVE_SPEED >= 45 and C.REVERSE_DRIVE_SPEED <= 55, "about 48-55 studs/s (research item 3)")
		h.ok(C.REVERSE_DRIVE_SPEED < C.TOP_SPEED * 0.5, "well under forward top speed")
		local v, t = 0, 0
		while v > -30 and t < 3 do
			v = R.stepSpeed("reverse", v, 1, DT)
			t += DT
		end
		h.ok(t <= 0.5, string.format("0 -> 30 backwards in %.2f s", t))
		for _ = 1, 600 do
			v = R.stepSpeed("reverse", v, 1, DT)
		end
		h.ok(v >= -C.REVERSE_DRIVE_SPEED - 1e-6 and v <= -C.REVERSE_DRIVE_SPEED + 0.5, "settles at the cap: " .. v)
		local p = 0
		for _ = 1, 600 do
			p = R.stepSpeed("reverse", p, 0.2, DT)
		end
		h.ok(math.abs(p + C.REVERSE_DRIVE_SPEED * R.MIN_REVERSE_MAG) < 0.5, "a 20 percent pull backs up at the floor: " .. p)
		-- Faster backwards than the target (a released pull, a downhill): eased back to it, never a jump.
		local fast = R.stepSpeed("reverse", -60, 1, DT)
		h.ok(fast > -60 and fast <= -C.REVERSE_DRIVE_SPEED, "eases toward the cap: " .. fast)
	end)

	h.test("portal spit cap is still the v27 reverse top speed (locked arches unchanged)", function()
		h.eq(C.REVERSE_SPEED, 34)
		h.contains(h.readFile("src/client/PortalPlunge.luau"), "CarConfig.REVERSE_SPEED", "PortalPlunge still caps the spit at REVERSE_SPEED")
	end)

	h.test("reverse turn rate: 0 at a standstill, floored once rolling, never below v27", function()
		h.eq(R.turnRate(0), 0, "no turning on the spot")
		local floorRate = C.TURN_RATE_MAX * R.TURN_FLOOR * R.TURN_FACTOR
		for v = R.FLOOR_SPEED, C.REVERSE_DRIVE_SPEED, 2 do
			h.ok(R.turnRate(-v) >= floorRate - 1e-6, "floor at " .. v)
		end
		for v = 1, C.REVERSE_DRIVE_SPEED do
			h.ok(R.turnRate(-v) >= C.turnRate(v) * C.REVERSE_STEER_FACTOR - 1e-9, "at least v27 at " .. v)
			h.ok(R.turnRate(-v) <= C.TURN_RATE_MAX, "never above the forward peak at " .. v)
		end
		h.ok(R.turnRate(-10) > C.turnRate(10) * C.REVERSE_STEER_FACTOR * 1.3, "much sharper at a three-point-turn speed")
	end)

	h.test("steering sign: forward unchanged; reversing keeps the v27 / real-car sign (tail follows the wheel)", function()
		for _, v in { 5, 20, 60, 128 } do
			h.eq(R.gripYaw(0.7, v), 0.7 * C.turnRate(v), "forward is v27 exactly at " .. v)
		end
		for _, st in { 1, -1, 0.4 } do
			for _, v in { 5, 20, 45 } do
				local v27 = -(st * C.turnRate(-v)) * C.REVERSE_STEER_FACTOR
				local now = R.gripYaw(st, -v)
				h.ok(math.sign(now) == math.sign(v27) and now ~= 0, string.format("same sign as v27 (steer %.1f, %d)", st, v))
			end
		end
		h.eq(R.gripYaw(1, 0), 0)
	end)

	h.test("three-point turn: full lock backwards swings the nose 90 degrees in about 1.5 s, sooner than v27", function()
		-- v27 (CarController before reverse v2): reverse at once, REVERSE_ACCEL 45 to REVERSE_SPEED 34, yaw turnRate * 0.7.
		local function v27(): (number, number)
			local speed, heading, t, at05 = 0, 0, 0, -1
			while heading < 90 and t < 8 do
				speed = math.max(-C.REVERSE_SPEED, speed - C.REVERSE_ACCEL * DT)
				heading += C.turnRate(speed) * C.REVERSE_STEER_FACTOR * DT
				t += DT
				if at05 < 0 and t >= 0.8 then
					at05 = heading
				end
			end
			return t, at05
		end
		-- v2: the hold delay first, then the new curve and turn rate.
		local function v2(): (number, number)
			local s = R.newState()
			local speed, heading, t, rolling, at05 = 0, 0, 0, -1, -1
			while heading < 90 and t < 8 do
				local mode = R.step(s, -1, speed, DT)
				speed = R.stepSpeed(mode, speed, 1, DT)
				heading += math.abs(R.gripYaw(1, speed)) * DT
				t += DT
				if rolling < 0 and speed < 0 then
					rolling = t
				end
				if at05 < 0 and rolling >= 0 and t - rolling >= 0.8 then
					at05 = heading
				end
			end
			return t - (rolling - DT), at05
		end
		local tNew, early = v2()
		local tOld, earlyOld = v27()
		h.ok(tNew <= 1.6, string.format("v2: 90 degrees %.2f s after rolling back", tNew))
		h.ok(tNew < tOld * 0.75, string.format("v2 %.2f s vs v27 %.2f s", tNew, tOld))
		h.ok(early > earlyOld * 1.5, string.format("swings early, not late: %.0f vs %.0f degrees after 0.8 s", early, earlyOld))
	end)

	h.test("camera: forward framing is v27; reversing follows calmer and pulls back a little, ramped by speed", function()
		local r0, d0 = R.camera(50)
		h.eq(r0, C.CAM_YAW_RESPONSE)
		h.eq(d0, 0)
		local r1, d1 = R.camera(-C.REVERSE_DRIVE_SPEED)
		h.eq(r1, R.CAM_YAW_RESPONSE)
		h.eq(d1, R.CAM_PULLBACK)
		h.ok(R.CAM_YAW_RESPONSE < C.CAM_YAW_RESPONSE, "calmer heading follow in reverse (no whip)")
		local rh, dh = R.camera(-C.REVERSE_DRIVE_SPEED / 2)
		h.ok(rh < r0 and rh > r1 and dh > 0 and dh < d1, "ramps")
		h.ok(R.CAM_PULLBACK <= 4, "a small pull-back")
	end)

	h.test("yawErrDeg: + when the course is to the left, 0 aligned, 180 opposite", function()
		h.ok(math.abs(R.yawErrDeg(0, -1, 0, -1)) < 1e-9)
		h.ok(math.abs(R.yawErrDeg(0, -1, -1, 0) - 90) < 1e-9, "facing -Z, course -X (left): +90")
		h.ok(math.abs(R.yawErrDeg(0, -1, 1, 0) + 90) < 1e-9, "course to the right: -90")
		h.ok(math.abs(math.abs(R.yawErrDeg(0, -1, 0, 1)) - 180) < 1e-9)
	end)

	h.test("WRONG WAY: 3 s moving the wrong way; a stop or a slow three-point turn holds the clock; facing right clears", function()
		local s = R.newState()
		for _ = 1, 8 do
			h.ok(not R.stepWrongWay(s, 170, 40, 0.25))
		end
		for _ = 1, 20 do
			h.ok(not R.stepWrongWay(s, 170, 0, 0.25), "stopped: the clock holds")
			h.ok(not R.stepWrongWay(s, 170, 5, 0.25), "a slow turn: the clock holds")
		end
		for _ = 1, 3 do
			h.ok(not R.stepWrongWay(s, 170, 40, 0.25))
		end
		h.ok(R.stepWrongWay(s, 170, 40, 0.25), "3 s moving away")
		h.ok(not R.stepWrongWay(s, 20, 40, 0.25), "facing the course clears at once")
		local q = R.newState()
		for _ = 1, 40 do -- a reversing car with its tail down the course is going the right way
			h.ok(not R.stepWrongWay(q, 10, -30, 0.25))
		end
		h.ok(not R.stepWrongWay(R.newState(), 170, 40, 30), "one long tick never trips it")
	end)

	h.test("pedal caption", function()
		h.eq(R.brakeCaption("reverse"), "REV")
		for _, m in { "drive", "brake", "hold" } do
			h.eq(R.brakeCaption(m), "BRAKE")
		end
	end)

	h.test("source: CarController drives speed, yaw and camera through ReverseRules; adhesion, walls, rescue untouched", function()
		local src = h.readFile("src/client/CarController.luau")
		h.contains(src, "ReverseRules.step(reverseState, throttle, speed, dt)")
		h.contains(src, "speed = ReverseRules.stepSpeed(revMode, speed, -throttle, dt)")
		h.contains(src, "yawDeg = ReverseRules.gripYaw(steer, speed)")
		h.contains(src, "ReverseRules.camera(CarController.speed)")
		h.ok(not src:find("CarConfig.REVERSE_ACCEL", 1, true), "the v27 instant roll-back branch is gone")
		h.ok(not src:find("speed > 1 then", 1, true), "no reverse at 1 stud/s")
		for _, path in { "src/shared/ReverseRules.luau", "src/shared/TouchSteerRules.luau" } do
			local code = h.readFile(path):gsub("%-%-[^\n]*", "")
			for _, banned in { "Raycast", "workspace", "RespawnRules", "STUCK_", "WALL_", "killY", "Adhes", "adhes", "upVector", "CFrame" } do
				h.ok(not code:find(banned, 1, true), path .. " never touches " .. banned)
			end
		end
		local RR = h.require("src/shared/RespawnRules.luau")
		h.eq(RR.STUCK_OFFER, 3, "rescue offer timing unchanged")
		h.eq(RR.STUCK_AUTO, 6, "auto rescue timing unchanged")
	end)

	h.test("source: a respawn clears the car WRONG WAY verdict (no flash or beep when the respawn shield ends)", function()
		local src = h.readFile("src/client/CarController.luau")
		local a = src:find("local function completeRespawn()", 1, true)
		h.ok(a ~= nil, "completeRespawn exists")
		local b = src:find("\nend\n", a, true)
		local body = src:sub(a, b)
		h.contains(body, "reverseState.awayT = 0")
		h.contains(body, "wrongWayShown = false")
	end)
end
