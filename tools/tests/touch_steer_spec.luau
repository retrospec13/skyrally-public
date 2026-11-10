--!strict
-- Lune spec for touch steering v2 (shared/TouchSteerRules; owner 2026-10-21 "excellent mobile vehicle controls"): the steer
-- dead zone and curve, the pad brake that ignores diagonal dips, the floating stick origin and the stick vector. Source guards
-- pin the CarController / RaceUI wiring and the BRAKE pedal's place in the right zone (HudLayoutRules).
-- Run: tools/tests/run_lune_tests.sh tools/tests/touch_steer_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
	contains: (string, string, string?) -> (),
}

return function(h: Harness)
	local T = h.require("src/shared/TouchSteerRules.luau")
	local L = h.require("src/shared/HudLayoutRules.luau")

	h.test("steer: dead zone, full lock at the edge, odd, monotonic, continuous at the dead zone edge", function()
		h.eq(T.steer(0), 0)
		h.eq(T.steer(T.DEADZONE), 0, "a resting thumb never steers")
		h.eq(T.steer(-T.DEADZONE * 0.9), 0)
		h.ok(math.abs(T.steer(1) - 1) < 1e-9 and math.abs(T.steer(-1) + 1) < 1e-9, "full lock at the edge")
		h.ok(T.steer(T.DEADZONE + 0.001) < 0.01, "no jump out of the dead zone")
		local prev = -1
		for i = -100, 100 do
			local x = i / 100
			local y = T.steer(x)
			h.ok(y >= prev - 1e-12, "monotonic at " .. x)
			h.ok(math.abs(y + T.steer(-x)) < 1e-12, "odd at " .. x)
			h.ok(math.abs(y) <= 1, "bounded")
			prev = y
		end
		h.ok(T.steer(0.5) < 0.5 - T.DEADZONE * 0.2, "gentle near the centre (curve), fine corrections")
	end)

	h.test("pad brake: a mostly-downward pull brakes, a diagonal steer that dips low does not", function()
		h.eq(T.padBrake(0, 0), 0)
		h.eq(T.padBrake(0, -0.5), 0, "above the threshold")
		h.ok(T.padBrake(0, -0.7) > 0 and T.padBrake(0, -0.7) < 1)
		h.eq(T.padBrake(0, -T.PAD_BRAKE_FULL), 1)
		h.eq(T.padBrake(0, -1), 1)
		h.eq(T.padBrake(0.9, -0.6), 0, "a hard turn that dips low is a turn, not a brake")
		h.eq(T.padBrake(0.7, 0.7), 0, "up never brakes")
		h.ok(T.padBrake(0.3, -0.9) > 0, "a slightly off-axis pull still brakes")
	end)

	h.test("floating origin: the landing point within ORIGIN_SLACK of the centre, clamped beyond", function()
		local ox, oy = T.origin(100, 100, 140, 110, 95)
		h.eq(ox, 110)
		h.eq(oy, 95)
		local fx, fy = T.origin(100, 100, 140, 300, 100)
		h.ok(math.abs(fx - (100 + 140 * T.ORIGIN_SLACK)) < 1e-9 and fy == 100, "clamped to the slack")
		local cx, cy = T.origin(100, 100, 140, 100, 100)
		h.eq(cx, 100)
		h.eq(cy, 100)
	end)

	h.test("stick vector: clamps to the radius, y up, the radius floor", function()
		local dx, dy, nx, ny = T.padVector(0, 0, 50, 25, 0)
		h.eq(dx, 25)
		h.eq(dy, 0)
		h.eq(nx, 0.5)
		h.eq(ny, 0)
		local _, _, _, upY = T.padVector(0, 0, 50, 0, -50)
		h.eq(upY, 1, "screen up is +y")
		local cx, cy, cnx = T.padVector(0, 0, 50, 500, 0)
		h.eq(cx, 50)
		h.eq(cy, 0)
		h.eq(cnx, 1)
		h.eq(T.radius(60), T.MIN_RADIUS, "small pads keep a usable throw")
		h.eq(T.radius(226), 226 * T.RADIUS_FRAC)
	end)

	h.test("layout: the BRAKE pedal is inside the right zone, left of the stones, at least 56 px wide; the stones keep their v27 room", function()
		local cases = {
			{ 844, 390, { left = 47, top = 0, right = 47, bottom = 21 } },
			{ 740, 360, { left = 44, top = 0, right = 44, bottom = 20 } },
			{ 1920, 1080, { left = 0, top = 0, right = 0, bottom = 0 } },
			{ 1366, 768, { left = 0, top = 0, right = 0, bottom = 0 } },
		}
		for _, c in cases do
			local r = L.compute(c[1], c[2], c[3], L.fallbackNav(c[1], c[2]), "touch")
			local b, z = r.brake, r.rightZone
			local tag = c[1] .. "x" .. c[2]
			h.ok(b ~= nil, "brake rect on touch " .. tag)
			h.ok(L.contains(z, b), "inside the right zone " .. tag)
			h.ok(b.w >= L.BRAKE_MIN and b.h >= L.BRAKE_MIN, "at least 56 px " .. tag)
			h.eq(b.x, z.x, "left edge of the zone " .. tag)
			local _, zoneW = L.thumbSizes(c[2])
			h.eq(z.w - b.w - L.BRAKE_GAP, zoneW, "TURN / ITEM keep their v27 width " .. tag)
			h.ok(z.x + z.w <= c[1] - c[3].right, "inside the safe area " .. tag)
			local d = L.compute(c[1], c[2], c[3], L.fallbackNav(c[1], c[2]), "desktop")
			h.ok(d.brake == nil, "no pedal on desktop " .. tag)
		end
	end)

	h.test("source: CarController shapes touch input through TouchSteerRules; RaceUI wires the pedal and the floating pad", function()
		local car = h.readFile("src/client/CarController.luau")
		h.contains(car, "steer += Mods.TouchSteerRules.steer(ms.X)")
		h.contains(car, "Mods.TouchSteerRules.padBrake(ms.X, ms.Y)")
		h.contains(car, "FlightController.mobileThrottle >= 0.05", "the BRAKE pedal is not a drive input for ASSIST")
		local ui = h.readFile("src/client/RaceUI.luau")
		h.contains(ui, "pedal.Name = \"BrakeButton\"")
		h.contains(ui, "FlightController.mobileThrottle = -1")
		h.contains(ui, "TouchSteerRules.origin(")
		h.contains(ui, "TouchSteerRules.padVector(")
		h.contains(ui, "LocalPlayer:GetAttribute(\"VehicleType\") == \"car\"", "the pedal shows for cars only")
		h.contains(ui, "itemBtn.Name = \"ThrottleUpButton\"", "the ITEM stone keeps its ledger path")
	end)
end
