--!strict
-- Lune spec for ASSIST (shared/AssistRules; owner 2026-10-20 items 3 and 4): the auto throttle acts only in a running race,
-- never creeps when the player stands still, and the player's switch always wins. Source guards pin the wiring.
-- Run: tools/tests/run_lune_tests.sh tools/tests/assist_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local A = h.require("src/shared/AssistRules.luau")

	local function run(s: any, from: number, seconds: number, enabled: boolean, racing: boolean, steering: boolean, braking: boolean, speed: number): (boolean, number)
		local t, out = from, false
		for _ = 1, math.floor(seconds * 60) do
			t += 1 / 60
			out = A.step(s, t, enabled, racing, steering, braking, speed)
		end
		return out, t
	end

	h.test("assist: only the race phase counts as racing", function()
		h.ok(A.racingPhase("race"))
		for _, p in { "hub", "countdown", "finish", "results", "podium", "battle" } do
			h.ok(not A.racingPhase(p), p)
		end
	end)

	h.test("assist: off or not racing never drives, on and racing drives", function()
		local s = A.newState()
		h.ok(A.step(s, 0.1, true, true, false, false, 0), "on, racing, hands off at the start: drives")
		h.ok(not A.step(s, 0.2, false, true, false, false, 50), "the switch wins: ASSIST off, hands off, no drive")
		h.ok(not A.step(s, 0.3, true, false, false, false, 50), "hub / lobby / results: no auto drive")
		h.ok(A.step(s, 0.4, false, true, true, false, 50), "ASSIST off: hold-to-drive while a finger is on the pad")
		h.ok(A.step(s, 0.5, true, false, true, false, 50), "hub: hold-to-drive on the pad")
		h.ok(not A.step(s, 0.6, false, false, true, true, 50), "the brake wins")
	end)

	h.test("assist: stopped and hands off for IDLE_STOP_S lets the car sit still until the player touches the pad", function()
		local s = A.newState()
		local out, t = run(s, 0, A.IDLE_STOP_S - 0.3, true, true, false, false, 0)
		h.ok(out, "still pushing before the timeout")
		out, t = run(s, t, 0.5, true, true, false, false, 0)
		h.ok(not out, "no creep after the timeout")
		out, t = run(s, t, 5, true, true, false, false, 0)
		h.ok(not out, "stays still")
		out, t = run(s, t, 0.05, true, true, true, false, 0)
		h.ok(out, "a steer / drift touch resumes the auto throttle")
	end)

	h.test("assist: holding the brake while stopped counts as standing still and does not resume on release", function()
		local s = A.newState()
		local out, t = run(s, 0, A.IDLE_STOP_S + 0.5, true, true, false, true, 0)
		h.ok(not out, "braking: no auto throttle")
		out, t = run(s, t, 0.1, true, true, false, false, 0)
		h.ok(not out, "brake released with no other input: the car sits still")
	end)

	h.test("assist: a moving car never trips the idle clock, and a long frame cannot either", function()
		local s = A.newState()
		local out, t = run(s, 0, 10, true, true, false, false, 80)
		h.ok(out, "rolling hands-off keeps driving (Mario Kart Tour)")
		s = A.newState()
		out = A.step(s, 100, true, true, false, false, 0)
		h.ok(out and s.idle <= A.MAX_DT + 1e-9, "one 100 s frame adds at most MAX_DT")
	end)

	h.test("assist: leaving the race resets the clock", function()
		local s = A.newState()
		local _, t = run(s, 0, A.IDLE_STOP_S + 1, true, true, false, false, 0)
		A.step(s, t + 0.1, true, false, false, false, 0)
		h.ok(A.step(s, t + 0.2, true, true, false, false, 0), "the next race starts fresh")
	end)

	h.test("assist: banner text", function()
		h.eq(A.bannerText(true), "ASSIST ON")
		h.eq(A.bannerText(false), "ASSIST OFF")
		h.ok(A.BANNER_S <= 1.2)
	end)

	h.test("assist: the switch is big enough to tap and exists in a race layout on 844x390 and 740x360", function()
		local L = h.require("src/shared/HudLayoutRules.luau")
		for _, vp in { { 844, 390 }, { 740, 360 } } do
			local ins = { left = 0, top = 0, right = 0, bottom = 0 }
			local nav = { x = 0, y = 0, w = 120, h = 44 }
			local touch = L.compute(vp[1], vp[2], ins, nav, "touch", { minimap = true })
			local p = touch.autoPill
			h.ok(p ~= nil and p.h >= L.MIN_BUTTON and p.w >= 100, "touch pill >= 100 x 44 at " .. vp[1])
			local desk = L.compute(vp[1], vp[2], ins, nav, "desktop", { minimap = true })
			h.ok(desk.assistChip ~= nil and desk.assistChip.h >= 30, "desktop chip at " .. vp[1])
			h.ok(desk.autoPill == nil and touch.assistChip == nil, "one switch per input kind")
		end
	end)

	h.test("assist: wiring guards (throttle and the flag only)", function()
		local car = h.readFile("src/client/CarController.luau")
		h.ok(string.find(car, "AssistRules.step(", 1, true) ~= nil, "the car asks the rule")
		h.ok(string.find(car, "throttle = CarConfig.AUTO_THROTTLE\n", 1, true) ~= nil)
		h.ok(string.find(car, 'InputMode.current == "Touch" then\n\t\tthrottle = CarConfig.AUTO_THROTTLE', 1, true) == nil, "no unconditional touch auto-gas")
		local ui = h.readFile("src/client/RaceUI.luau")
		h.ok(string.find(ui, "Settings.set(AssistRules.KEY", 1, true) ~= nil, "the switch is saved through Settings")
		h.ok(string.find(ui, "AssistRules.bannerText(on)", 1, true) ~= nil)
		h.ok(string.find(ui, "Enum.KeyCode.T", 1, true) ~= nil, "T toggles on desktop")
	end)
end
