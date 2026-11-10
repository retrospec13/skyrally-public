--!strict
-- Lune spec for the boost / speed VFX rules (shared/BoostRules), the phone tier (shared/SettingsRules) and the wiring that
-- keeps the boost look mesh-free and camera-safe (client/Vfx, BoostPadFx, the two camera controllers).
-- Run: tools/tests/run_lune_tests.sh tools/tests/boost_spec.luau
return function(h)
	local R = h.require("src/shared/BoostRules.luau")
	local S = h.require("src/shared/SettingsRules.luau")

	h.test("ignite punch: +4 degrees for about 0.15 s, then settles to 0 and never goes negative", function()
		h.eq(R.fovKick(-1), 0)
		h.eq(R.fovKick(0), 0)
		h.eq(R.fovKick(R.FOV_HOLD - 0.01), R.FOV_KICK)
		h.ok(R.fovKick(R.FOV_HOLD + 0.1) < R.FOV_KICK and R.fovKick(R.FOV_HOLD + 0.1) > 0)
		h.eq(R.fovKick(R.punchDuration() + 0.01), 0)
		h.ok(R.fovKick(0.02) > 0 and R.fovKick(0.02) < R.FOV_KICK, "rises")
		h.ok(R.fovKick(0.1, true) > R.fovKick(0.1, false), "overcharge kicks harder")
		for i = 0, 100 do
			h.ok(R.fovKick(i * 0.01) >= 0)
		end
	end)

	h.test("ignite punch: trauma 0.12-0.18, tint at most 2 frames", function()
		h.ok(R.trauma(false) >= 0.12 and R.trauma(false) <= 0.18)
		h.ok(R.trauma(true) >= 0.12 and R.trauma(true) <= 0.18)
		h.ok(R.TINT_FRAMES <= 2)
	end)

	h.test("wind streaks: none when slow, grow with speed, more when boosting, capped", function()
		h.eq(R.windRate(R.speedFrac(60), false), 0)
		h.eq(R.windRate(0.5, false), 0) -- v28: not below 90% of top speed unless boosting
		local a, b = R.windRate(0.9, false), R.windRate(1, false)
		h.ok(a > 0 and b > a)
		h.ok(R.windRate(0.5, true) > 0)
		h.ok(R.windRate(1, true) > b)
		h.ok(R.windRate(1, true) <= R.WIND_MAX)
		h.eq(R.speedFrac(R.SPEED_HI + 50), 1)
		h.eq(R.speedFrac(0), 0)
	end)

	h.test("vignette: invisible at cruise, faint at the top, never above the cap, edges only", function()
		h.eq(R.vignette(0.5, false), 0)
		h.ok(R.vignette(1, true) <= R.VIGNETTE_MAX and R.VIGNETTE_MAX <= 0.45)
		h.ok(R.vignette(1, false) > R.vignette(0.7, false))
		h.ok(R.EDGE_WIDTH <= 0.15, "the centre route stays clear")
	end)

	h.test("pads: only near ones, nearest first, capped, pulse stays in 0..1", function()
		local picks = R.pickPads({ 200, 40, 10, 149, 151, 90 }, 3)
		h.eq(picks, { 3, 2, 6 })
		h.eq(#R.pickPads({}, 6), 0)
		for i = 0, 50 do
			local p = R.padPulse(i * 0.13, 1.7)
			h.ok(p >= 0 and p <= 1)
		end
		h.ok(R.padLight(0, 1) > R.padLight(1, 0), "a touch flare outshines the idle pulse")
	end)

	h.test("boost ribbons stay shorter than the chase camera distance at the top pace", function()
		h.ok(R.TRAIL_LIFE * 170 < 14.5)
	end)

	h.test("phone tier: touch-only gets 0.6, LOW GRAPHICS 0.4 on any device, heavy smoke off on phone/low", function()
		h.eq(S.isPhoneTier(true, false), true)
		h.eq(S.isPhoneTier(true, true), false)
		h.eq(S.isPhoneTier(false, true), false)
		h.eq(S.particleScale(false, false), 1)
		h.eq(S.particleScale(false), 1)
		h.eq(S.particleScale(false, true), 0.6)
		h.eq(S.particleScale(true, true), 0.4)
		h.eq(S.particleScale(true, false), 0.4)
		h.eq(S.heavySmoke(false, false), true)
		h.eq(S.heavySmoke(false, true), false)
		h.eq(S.heavySmoke(true, false), false)
	end)

	h.test("wind streaks: a few thin tapered beams, far from the lens, none at cruise", function()
		local R = h.require("src/shared/BoostRules.luau")
		h.eq(R.windBeams(0, 1), 0)
		h.ok(R.windBeams(R.windRate(1, true), 1) <= R.WIND_BEAMS and R.windBeams(R.windRate(1, true), 1) >= 1)
		h.ok(R.windBeams(R.windRate(1, true), 0.4) <= R.windBeams(R.windRate(1, true), 1), "phones / low graphics get fewer")
		h.ok(R.WIND_BEAMS <= 6 and R.WIND_WIDTH <= 0.2, "few and thin")
		h.ok(R.WIND_NEAR >= 30, "the nearest end of a streak stays far from the camera")
		for _, side in { -1, 1 } do
			for _, u in { 0, 0.5, 1 } do
				local x, y, len = R.windSlot(side, u, u, u)
				h.ok(math.abs(x) >= R.WIND_X0 and math.abs(x) <= R.WIND_X1 and x * side > 0, "outer screen edge")
				h.ok(y >= R.WIND_Y0 and y <= R.WIND_Y1 and len >= R.WIND_LEN0 and len <= R.WIND_LEN1)
			end
		end
		local h0, e0 = R.windHead(0)
		local h1, e1 = R.windHead(1)
		local _, em = R.windHead(0.5)
		h.eq(h0, R.WIND_FAR)
		h.eq(h1, R.WIND_NEAR)
		h.ok(e0 < 1e-9 and e1 < 1e-6 and em > 0.99, "fades in and out")
		local vfx = h.readFile("src/client/Vfx.luau")
		h.ok(not string.find(vfx, 'tex = "speed_streak", count = 0', 1, true), "no speed_streak card emitters left on vehicles or the wind")
		h.contains(vfx, "Instance.new(\"Beam\")")
	end)

	h.test("wiring: no mesh ring in Vfx or FxTemplates, flash is not between camera and car, particles scale", function()
		local vfx = h.readFile("src/client/Vfx.luau")
		h.ok(not string.find(vfx, "ringTpl", 1, true) and not string.find(vfx, "ringT ", 1, true))
		h.ok(not string.find(vfx, ':FindFirstChild("shock_ring")', 1, true))
		-- the boost flash is placed forward (-Z) of the hull, the camera is behind (+Z)
		h.ok(string.find(vfx, "hullCF * CFrame.new(0, 3.2, -7)", 1, true) ~= nil)
		h.ok(string.find(vfx, "BoostRules.windBeams(BoostRules.windRate(frac, boosting), scale)", 1, true) ~= nil)
		local fx = h.readFile("src/server/kit/FxTemplates.luau")
		h.ok(not string.find(fx, '"flame_core", "flame_outer"', 1, true))
		for _, f in { "src/client/FlightController.luau", "src/client/CarController.luau" } do
			local src = h.readFile(f)
			h.ok(string.find(src, "Vfx.fovKick()", 1, true) ~= nil, f)
			h.ok(string.find(src, "Vfx.takeTrauma()", 1, true) ~= nil, f)
		end
	end)
end
