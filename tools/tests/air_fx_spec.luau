--!strict
-- Lune spec for the plane air effects (shared/AirFxRules): wall-scrape spark cadence, wingtip vortex gating and rates,
-- the slipstream test and its fade, the water-skim window, and the wiring in client/Vfx and client/FlightController.
-- Run: tools/tests/run_lune_tests.sh tools/tests/air_fx_spec.luau
return function(h)
	local R = h.require("src/shared/AirFxRules.luau")

	h.test("scrape sparks are rate limited", function()
		h.ok(R.scrapeDue(1.0, 0.0))
		h.ok(not R.scrapeDue(1.05, 1.0))
		h.ok(R.scrapeDue(1.12, 1.0))
		h.ok(R.SCRAPE_SPARKS <= 10 and R.SCRAPE_TRAUMA <= 0.05)
	end)

	h.test("vortex: nothing below the speed threshold, grows with speed and bank", function()
		h.ok(R.vortexRate(149, 1, true, true, 1) == 0)
		local slow = R.vortexRate(150, 0, false, false, 1)
		local fast = R.vortexRate(230, 0, false, false, 1)
		local banked = R.vortexRate(230, 1, false, false, 1)
		h.ok(slow > 0 and fast > slow and banked > fast)
		h.ok(R.vortexRate(300, 1, true, true, 1) <= R.VORTEX_RATE_MAX)
	end)

	h.test("vortex: phone and LOW GRAPHICS scale the rate down", function()
		local full = R.vortexRate(200, 0.5, false, false, 1)
		local phone = R.vortexRate(200, 0.5, false, false, 0.6)
		h.ok(phone < full and phone > 0)
	end)

	h.test("vortex: remote planes are range, lens, cap and tier gated", function()
		h.ok(R.remoteVortexAllowed(60, 1, 0))
		h.ok(not R.remoteVortexAllowed(8, 1, 0))
		h.ok(not R.remoteVortexAllowed(400, 1, 0))
		h.ok(not R.remoteVortexAllowed(60, 1, R.VORTEX_MAX_REMOTE))
		h.ok(not R.remoteVortexAllowed(60, 0.6, 0))
		h.ok(not R.remoteVortexAllowed(60, 0.4, 0))
	end)

	h.test("vortex lifetime stays about one second", function()
		h.ok(R.VORTEX_LIFE >= 0.8 and R.VORTEX_LIFE <= 1.2)
	end)

	h.test("slipstream: ahead, in the cone, similar speed", function()
		h.ok(R.inSlipstream(0, 0, -20, 150, 150))
		h.ok(not R.inSlipstream(0, 0, -5, 150, 150)) -- too close
		h.ok(not R.inSlipstream(0, 0, -60, 150, 150)) -- too far
		h.ok(not R.inSlipstream(0, 0, 20, 150, 150)) -- behind us
		h.ok(not R.inSlipstream(15, 0, -20, 150, 150)) -- outside the 20 degree cone
		h.ok(R.inSlipstream(5, 2, -20, 150, 150))
		h.ok(not R.inSlipstream(0, 0, -20, 90, 150)) -- we are much slower
		h.ok(not R.inSlipstream(0, 0, -20, 150, 60)) -- rival barely moving
	end)

	h.test("slipstream fade: rises, holds, then falls", function()
		local level, hold = 0, 0
		for _ = 1, 10 do
			level, hold = R.draftStep(level, hold, true, 0.05)
		end
		h.ok(level == 1 and hold == R.DRAFT_HOLD)
		level, hold = R.draftStep(level, hold, false, 0.2)
		h.ok(level == 1 and hold > 0)
		level, hold = R.draftStep(level, hold, false, 0.3)
		h.ok(hold == 0 and level == 1)
		level, hold = R.draftStep(level, hold, false, 0.15)
		h.ok(level < 1 and level > 0)
	end)

	h.test("slipstream rates and trails respect the tier", function()
		h.ok(R.draftRate(1, 1) == R.DRAFT_RATE_MAX)
		h.ok(R.draftRate(0, 1) == 0)
		h.ok(R.draftRate(1, 0.6) < R.draftRate(1, 1))
		h.ok(R.draftTrails(1) and not R.draftTrails(0.6) and not R.draftTrails(0.4))
	end)

	h.test("water skim window and intensity", function()
		h.ok(R.skimActive(8, 150))
		h.ok(not R.skimActive(1, 150) and not R.skimActive(20, 150) and not R.skimActive(8, 50))
		h.ok(R.skimIntensity(R.SKIM_MIN) > R.skimIntensity(R.SKIM_MAX))
		h.ok(R.skimIntensity(R.SKIM_MAX) > 0.49)
		h.ok(R.skimTrail(1) and not R.skimTrail(0.6) and not R.skimTrail(0.4))
	end)

	h.test("wiring: particles only, reused textures, scrape through GroundFx", function()
		local vfx = h.readFile("src/client/Vfx.luau")
		local fc = h.readFile("src/client/FlightController.luau")
		h.ok(string.find(vfx, "AirFxRules.vortexRate", 1, true) ~= nil)
		h.ok(string.find(vfx, "AirFxRules.inSlipstream", 1, true) ~= nil)
		h.ok(string.find(vfx, "AirFxRules.skimActive", 1, true) ~= nil)
		h.ok(string.find(vfx, "skimSpray = {", 1, true) ~= nil and string.find(vfx, "water_splash_8x8", 1, true) ~= nil)
		h.ok(string.find(vfx, "GroundTexAssets", 1, true) ~= nil)
		h.ok(string.find(fc, 'GroundFx.sparkSpray(hit.Position, hit.Normal, AirFxRules.SCRAPE_SPARKS, "wall")', 1, true) ~= nil)
	end)
end
