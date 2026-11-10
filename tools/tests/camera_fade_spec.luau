--!strict
-- Lune spec for the camera-occlusion fade (critic v29 Wave 1b A13): shared/CameraFadeRules box distance, the fade
-- radius and pre-test, and the client wiring (LocalTransparencyModifier only, never collision or queries).
-- Run: tools/tests/run_lune_tests.sh tools/tests/camera_fade_spec.luau
return function(h)
	local R = h.require("src/shared/CameraFadeRules.luau")

	h.test("box distance: zero inside, axis and corner distances outside", function()
		h.eq(R.boxDistance(0, 0, 0, 1, 12, 1), 0)
		h.eq(R.boxDistance(0.5, 11, -0.9, 1, 12, 1), 0)
		h.eq(R.boxDistance(4, 0, 0, 1, 12, 1), 3)
		h.ok(math.abs(R.boxDistance(4, 16, 0, 1, 12, 1) - 5) < 1e-9)
	end)

	h.test("fade inside the radius only; the pre-test never skips a part that could fade", function()
		h.eq(R.fadeAt(R.RADIUS - 0.01), R.FADE)
		h.eq(R.fadeAt(R.RADIUS), 0)
		h.eq(R.fadeAt(40), 0)
		h.ok(R.FADE > 0 and R.FADE < 1, "faded, never fully gone")
		h.ok(R.mayFade(20, 12) and not R.mayFade(30, 12))
		h.ok(R.FOLDERS.Gantries and R.FOLDERS.GlassVault)
	end)

	h.test("static: client applies LocalTransparencyModifier only and is wired in init", function()
		local src = h.readFile("src/client/CameraFade.luau")
		h.contains(src, "LocalTransparencyModifier")
		h.ok(not string.find(src, "CanCollide", 1, true) and not string.find(src, "CanQuery =", 1, true), "never touches collision or queries")
		h.ok(not string.find(src, ".Transparency =", 1, true), "never writes the replicated Transparency")
		h.contains(h.readFile("src/shared/BootRules.luau"), '{ name = "CameraFade" }')
	end)
end
