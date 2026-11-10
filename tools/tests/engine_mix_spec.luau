--!strict
-- Lune spec for src/shared/EngineMixRules.luau (audio-v2): the engine is silent at idle, a subtle low layer while driving
-- (never louder than the ceiling), accents are short and capped, and the ENGINE SOUND setting gates everything.
-- Run: tools/tests/run_lune_tests.sh tools/tests/engine_mix_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/EngineMixRules.luau")
	local S = h.require("src/shared/SettingsRules.luau")

	h.test("engine mix: idle (stopped, off the throttle) is exactly silent", function()
		h.eq(R.target(0, 0, false, true), 0)
		h.eq(R.target(R.IDLE_SPEED, R.IDLE_THROTTLE, false, true), 0)
		h.eq(R.target(2, -1, false, true), 0, "braking or reversing input is not a throttle")
	end)

	h.test("engine mix: driving is a subtle layer under the ceiling and grows with speed and throttle", function()
		local cruise = R.target(60, 1, false, true)
		local fast = R.target(200, 1, false, true)
		h.ok(cruise > 0, "something is audible while driving")
		h.ok(fast >= cruise, "faster is not quieter")
		h.ok(fast <= R.CEILING + 1e-9, "full speed never passes the ceiling")
		h.ok(R.CEILING <= 0.4, "well under the old constant drone")
		h.ok(R.target(100, 0, false, true) < R.target(100, 1, false, true), "coasting is quieter than on the gas")
		h.ok(R.target(100, 0, false, true) > 0, "coasting at speed is still faintly present")
		h.ok(R.target(0, 1, false, true) > 0 and R.target(0, 1, false, true) < cruise, "the launch rev is a quiet blip")
	end)

	h.test("engine mix: boost lifts the layer by the boost gain and stays under the cap", function()
		local plain = R.target(150, 1, false, true)
		local boost = R.target(150, 1, true, true)
		h.ok(boost > plain)
		h.ok(boost <= R.MAX_LEVEL)
	end)

	h.test("engine mix: a full level fades to silence within half a second of stopping", function()
		local level = R.target(200, 1, false, true)
		local t = 0
		while t < R.FADE_SECONDS - 1e-9 do
			level = R.ease(level, R.target(0, 0, false, true), 1 / 60)
			t += 1 / 60
		end
		h.eq(level, 0, "silent at 0.5 s")
	end)

	h.test("engine mix: the level rises toward a target without overshoot", function()
		local level, target = 0, R.target(120, 1, false, true)
		for _ = 1, 600 do
			level = R.ease(level, target, 1 / 60)
			h.ok(level <= target + 1e-9)
		end
		h.ok(math.abs(level - target) < 1e-3)
	end)

	h.test("engine mix: accents swell and end; unknown kinds add nothing; the cap holds", function()
		for kind, a in R.ACCENTS do
			h.eq(R.accentLevel(kind, -0.1), 0)
			h.eq(R.accentLevel(kind, a.seconds), 0)
			h.ok(R.accentLevel(kind, a.seconds / 2) > 0.99 * a.amp)
			h.ok(a.seconds <= 0.6, kind .. " is a short accent")
		end
		h.eq(R.accentLevel("nope", 0.1), 0)
		h.ok(R.final(0.5, 0.2, true) <= R.MAX_LEVEL)
		h.eq(R.final(0.1, 0.1, false), 0, "the setting off silences accents too")
	end)

	h.test("engine mix: throttle-up fires on a press from rest, once per cooldown", function()
		h.eq(R.throttleUp(0, 1, 5), true)
		h.eq(R.throttleUp(0.5, 1, 5), false, "already on the gas")
		h.eq(R.throttleUp(0, 0.3, 5), false, "not firm enough")
		h.eq(R.throttleUp(0, 1, 0.5), false, "inside the cooldown")
	end)

	h.test("engine mix: an engine nobody steps (curtain, respawn fade, out of a vehicle) is stale and fades", function()
		h.eq(R.stale(10, 10), false)
		h.eq(R.stale(10 + R.STALE_SECONDS * 0.5, 10), false, "a normal frame gap is not stale")
		h.eq(R.stale(10 + R.STALE_SECONDS + 0.01, 10), true)
		h.ok(R.STALE_SECONDS <= 0.25, "the watchdog starts the fade well inside the half second")
	end)

	h.test("engine mix: the grid hold (held still, level speed 0) is silent off the throttle and a quiet rev on it", function()
		h.eq(R.target(0, 0, false, true), 0, "sitting on the grid off the throttle is silent")
		h.ok(R.target(0, 1, false, true) <= R.LAUNCH_SHARE * R.CEILING + 1e-9, "a full rev on the grid is the quiet launch blip")
	end)

	h.test("engine mix: ENGINE SOUND is a saved toggle, on by default (on = subtle, off = none)", function()
		local d = S.def("engineSound")
		h.ok(d ~= nil)
		h.eq(d.kind, "toggle")
		h.eq(d.default, true)
		h.eq(d.attr, "EngineSound")
		h.eq(R.target(150, 1, true, d.default), R.target(150, 1, true, true))
		h.eq(R.target(150, 1, true, false), 0)
	end)
end
