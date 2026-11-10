--!strict
-- Lune spec for the camera-near fade (visual critic v29 Wave 1b C2: DINO-4 fossil ribs caged the chase camera):
-- shared/CameraNearFadeRules (radius parsing, the fade ramp, surface distance), static checks on client/CameraNearFade
-- (local transparency only: never collision, queries or the server) and its wiring, and the DINO-4 plan marking.
-- Run: tools/tests/run_lune_tests.sh tools/tests/camera_near_fade_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/CameraNearFadeRules.luau")

	h.test("radius: numbers only, clamped, non-positive and NaN ignored", function()
		h.eq(R.radius(30), 30)
		h.eq(R.radius(1), R.MIN_RADIUS)
		h.eq(R.radius(1000), R.MAX_RADIUS)
		h.eq(R.radius(0), nil)
		h.eq(R.radius(-5), nil)
		h.eq(R.radius(0 / 0), nil)
		h.eq(R.radius("30"), nil)
		h.eq(R.radius(nil), nil)
	end)

	h.test("modifier: hidden inside half the radius, drawn at the radius, monotonic between", function()
		h.eq(R.modifier(0, 30), 1)
		h.eq(R.modifier(15, 30), 1)
		h.eq(R.modifier(30, 30), 0)
		h.eq(R.modifier(80, 30), 0)
		local prev = 1
		for d = 15, 30, 0.5 do
			local m = R.modifier(d, 30)
			h.ok(m <= prev + 1e-9 and m >= 0 and m <= 1, "ramp at " .. d)
			prev = m
		end
		h.ok(math.abs(R.modifier(22.5, 30) - 0.5) < 1e-9, "midpoint")
	end)

	h.test("surface distance never negative and subtracts the half diagonal", function()
		h.eq(R.surfaceDistance(2, Vector3.new(10, 10, 10)), 0)
		local d = R.surfaceDistance(50, Vector3.new(6, 8, 0))
		h.ok(math.abs(d - 45) < 1e-6, tostring(d))
	end)

	h.test("client writes LocalTransparencyModifier only and is wired in init", function()
		local src = h.readFile("src/client/CameraNearFade.luau")
		h.contains(src, "LocalTransparencyModifier")
		for _, banned in { "CanCollide =", "CanQuery =", "CanTouch =", ".Transparency =", "RemoteEvent", "FireServer" } do
			h.ok(not string.find(src, banned, 1, true), "client fade must not touch " .. banned)
		end
		local init = h.readFile("src/shared/BootRules.luau") -- the client boot's order (audit T1-1)
		h.contains(init, '"CameraNearFade", "FrameGovernor"')
		h.contains(init, '{ name = "CameraNearFade" }')
	end)

	h.test("DINO-4 marks the fossil rib gates (and only non-colliding dressing)", function()
		local td = h.readFile("build/dino4/TrackData.luau")
		h.contains(td, "CameraNearFade")
		h.contains(td, "Dressing/Fossils")
	end)
end
