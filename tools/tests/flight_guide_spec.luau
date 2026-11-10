--!strict
-- Lune spec for the two flight modes, RETURN to course and the Free-driving bead mist (shared/FlightGuideRules,
-- docs/design/FLIGHT_GUIDE.md section 12, the owner's note of 2026-10-20):
--   modes. The server-owned FlightMode attribute decides; the default is Mario Kart; FREE DRIVING is off by default.
--   1-1b. Default mode bounds (130 for 0.3 s, once), allow-pockets (spheres / capsules, publish / read).
--   2-3. Free driving: the 2 s RETURN offer, the lost return (200 studs, no progress for 15 s).
--   4. stepMode: the default mode never offers, Free driving never resets near the path; grace after a return.
--   5. No off-path slowdown in either mode, no forces added, the phone auto-throttle rule.
--   6-8. Server: return station (never ahead of best progress), best progress that cannot leap, the per-reason return
--        gate (reason belongs to the mode, bounds resets have their own clock floor and cooldown), the return frame.
--   9-12. Visual guide (Free driving): grid-anchored node stations, per-tier budgets, fade, preset table, the bead mist.
--   13. Source guards: the client and server wiring the design needs (and no car path touched).
--   14. WRONG WAY in both modes; the plane checkpoint rule that keeps Free driving from skipping the course.
-- Run: tools/tests/run_lune_tests.sh tools/tests/flight_guide_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local G = h.require("src/shared/FlightGuideRules.luau")
	local PlaneConfig = h.require("src/shared/PlaneConfig.luau")
	local PlaneGuardRules = h.require("src/shared/PlaneGuardRules.luau")
	local RouteBranch = h.require("src/shared/RouteBranch.luau")
	local CarConfig = h.require("src/shared/CarConfig.luau")
	local SettingsRules = h.require("src/shared/SettingsRules.luau")

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	h.test("constants agree with the code they mirror", function()
		h.eq(G.RETURN_SPEED, PlaneConfig.BASE_SPEED, "return speed = completeRespawn's BASE_SPEED")
		h.eq(G.RETURN_GRACE, PlaneConfig.RESPAWN_INVULN, "grace = respawn protection")
		h.eq(G.RETURN_LIFT, RouteBranch.PLANE_LIFT, "flown line height")
		h.eq(G.SPEED_CEILING, PlaneGuardRules.SPEED_CEILING, "best-progress ceiling = the plane validator's")
		h.eq(G.RESPAWN_FLOOR, CarConfig.RESPAWN_MIN_INTERVAL, "shared respawn floor")
		h.eq(G.LOST_DIST, PlaneConfig.LEASH_WARN, "lost = the old WRONG WAY line")
		h.eq(G.LOST_CLEAR, PlaneConfig.LEASH_CLEAR_MARGIN)
		h.ok(G.OUT_ENTER < G.BOUND and G.BOUND < G.LOST_DIST and G.LOST_DIST < PlaneConfig.LEASH_RESPAWN,
			"RETURN offer (80) < default bounds (130) < lost (200) < the far rescue (380)")
		h.ok(G.SERVER_OUT < G.OUT_EXIT and G.SERVER_IN < G.SERVER_OUT, "the server's clock never trails the client's")
		h.ok(G.RETURN_MIN_OFF < G.RETURN_OFFER, "a press the client offers is one the server's clock allows")
		h.ok(G.BOUND_MIN_OFF < G.BOUND_HOLD + (G.BOUND - G.SERVER_OUT) / PlaneConfig.FULL_THROTTLE_SPEED,
			"a bounds reset always finds the server's clock past its floor")
		h.ok(G.BOUND_COOLDOWN > G.RETURN_GRACE and G.BOUND_COOLDOWN < G.RETURN_COOLDOWN, "bounds resets are never refused for spam")
		h.eq(G.MODE_ATTR, SettingsRules.FLIGHT_MODE_ATTR, "client and server read the same attribute")
	end)

	h.test("modes: the server attribute decides, the default is Mario Kart", function()
		h.eq(G.modeOf("free"), "free")
		h.eq(G.modeOf("mk"), "mk")
		h.eq(G.modeOf(nil), "mk", "unset (settings not loaded yet): the default")
		h.eq(G.modeOf(true), "mk", "junk: the default")
		h.eq(G.modeOf("FREE"), "mk")
		h.eq(G.modeOf(SettingsRules.flightModeOf(true)), "free", "the setting maps onto the mode")
		h.eq(G.modeOf(SettingsRules.flightModeOf(false)), "mk")
		h.eq(SettingsRules.def("freeDriving").default, false, "Free driving is off by default")
	end)

	h.test("1. default mode bounds: 130 from the course for 0.3 s resets once, an allow-pocket never resets", function()
		h.ok(near(G.BOUND, 34 + PlaneConfig.turnRadius(PlaneConfig.FULL_THROTTLE_SPEED, PlaneConfig.YAW_RATE), 3),
			"bounds = corridor half-width + one full-throttle turn radius, got " .. G.BOUND)
		local s = G.newOff()
		for _ = 1, 100 do
			h.ok(not G.stepBounds(s, 129, false, 0.05), "129 studs: never reset (secret routes a little off the path)")
		end
		h.ok(not G.stepBounds(s, 140, false, 0.25), "past the bounds for 0.25 s: not yet")
		h.ok(G.stepBounds(s, 140, false, 0.05), "0.3 s: reset")
		for _ = 1, 40 do
			h.ok(not G.stepBounds(s, 160, false, 0.05), "once per excursion")
		end
		G.stepBounds(s, 100, false, 0.05)
		h.ok(not G.stepBounds(s, 140, false, 0.1), "back in bounds re-arms it, with a fresh hold")
		-- a dip back inside restarts the hold
		local d = G.newOff()
		G.stepBounds(d, 140, false, 0.2)
		G.stepBounds(d, 120, false, 0.05)
		h.ok(not G.stepBounds(d, 140, false, 0.2), "the hold restarted after the dip")
		-- allow-pockets: the same flight inside a pocket never resets
		local p = G.newOff()
		for _ = 1, 200 do
			h.ok(not G.stepBounds(p, 250, true, 0.05), "inside an allow-pocket: never reset")
		end
		h.ok(not G.stepBounds(p, 250, false, 0.1), "leaving the pocket starts the hold from zero")
		h.ok(G.stepBounds(p, 250, false, 0.2))
	end)

	h.test("1b. allow-pockets: spheres and capsules, malformed entries dropped, publish / read round trip", function()
		local pk = G.cleanPockets({
			{ kind = "sphere", center = { 0, 100, 0 }, radius = 50 },
			{ kind = "capsule", a = Vector3.new(500, 80, 0), b = { 900, 80, 0 }, radius = 30, note = "secret ledge" },
			{ kind = "sphere", center = { 0, 0 }, radius = 10 }, -- 2 numbers
			{ kind = "cube", center = { 0, 0, 0 }, radius = 10 },
			{ kind = "sphere", center = { 0, 0, 0 }, radius = 0 },
			{ kind = "sphere", center = { 0, 0, 0 }, radius = 500 }, -- over POCKET_MAX_R
			"junk",
		})
		h.eq(#pk, 2, "only the two well-formed pockets")
		h.ok(G.inPocket(pk, Vector3.new(30, 120, 0)), "inside the sphere")
		h.ok(not G.inPocket(pk, Vector3.new(60, 100, 0)), "outside the sphere")
		h.ok(G.inPocket(pk, Vector3.new(700, 100, 10)), "inside the capsule's middle")
		h.ok(G.inPocket(pk, Vector3.new(920, 80, 0)), "inside its rounded end")
		h.ok(not G.inPocket(pk, Vector3.new(700, 80, 40)), "outside its radius")
		h.ok(not G.inPocket({}, Vector3.zero), "no pockets: nothing is inside")
		h.eq(#G.cleanPockets(nil), 0)
		local many = {}
		for i = 1, 30 do
			many[i] = { kind = "sphere", center = { i, 0, 0 }, radius = 5 }
		end
		h.eq(#G.cleanPockets(many), G.POCKET_MAX, "capped")
		-- publish (MapAdapter) and read (client, server) through attributes
		local attrs: { [string]: any } = {}
		local root = {
			SetAttribute = function(_self: any, k: string, v: any)
				attrs[k] = v
			end,
			GetAttribute = function(_self: any, k: string): any
				return attrs[k]
			end,
		}
		h.eq(#G.readPockets(root), 0, "nothing published yet")
		h.eq(G.publishPockets(root, { { kind = "capsule", a = { 500, 80, 0 }, b = { 900, 80, 0 }, radius = 30 } }), 1)
		local back = G.readPockets(root)
		h.eq(#back, 1)
		h.ok(G.inPocket(back, Vector3.new(700, 100, 10)), "the round trip keeps the volume")
		h.eq(G.publishPockets(root, {}), 0, "every plane map ships an empty list")
		h.eq(#G.readPockets(root), 0)
		h.eq(#G.readPockets(nil), 0)
	end)

	h.test("2. Free driving RETURN: offered at 2.0 s past 80, re-entry restarts it, a flicker above 60 does not", function()
		local s = G.newOff()
		for _ = 1, 100 do
			h.eq(G.stepOff(s, 70, 0.05), "inside", "70 studs is inside")
		end
		G.stepOff(s, 90, 0.125)
		G.stepOff(s, 90, 0.125)
		h.ok(s.out, "out after the 0.25 s debounce")
		for _ = 1, 15 do
			h.eq(G.stepOff(s, 90, 0.125), "out", "no offer before 2 s")
		end
		h.eq(G.stepOff(s, 90, 0.1), "out", "1.975 s: no offer yet")
		h.eq(G.stepOff(s, 90, 0.025), "offer", "2.0 s: offered")
		local s2 = G.newOff()
		G.stepOff(s2, 85, 0.3)
		G.stepOff(s2, 70, 0.9)
		G.stepOff(s2, 85, 0.9)
		h.eq(G.stepOff(s2, 70, 0.25), "offer", "70 is not a re-entry, the clock ran through it")
		G.stepOff(s2, 50, 0.45)
		h.ok(not s2.out and s2.outTime == 0, "back inside after 0.4 s under 60")
		G.stepOff(s2, 90, 0.3)
		h.eq(G.stepOff(s2, 90, 0.5), "out", "the offer restarts from zero")
	end)

	h.test("3. Free driving lost return: far (200) with no progress for 15 s, once; progress or coming back clears it", function()
		local L = 5450
		local function runLost(s: any, dist: number, st0: number, speedAlong: number, seconds: number): number
			local t, firedAt = 0, -1
			local st = st0
			while t < seconds - 1e-9 do
				t += 0.1
				st = (st + speedAlong * 0.1) % L
				if G.stepLost(s, dist, st, L, 0.1) and firedAt < 0 then
					firedAt = t
				end
			end
			return firedAt
		end
		local s = G.newOff()
		h.eq(runLost(s, 199, 1000, 0, 60), -1, "199 studs: never lost (any secret route is nearer)")
		local a = G.newOff()
		local at = runLost(a, 260, 1000, 0, 30)
		h.ok(near(at, G.LOST_TIME + 0.1, 0.11), "circling 260 studs away: returned after 15 s, got " .. at)
		h.ok(a.lostFired, "once")
		h.eq(runLost(a, 260, 1000, 0, 30), -1, "no second return in the same spell")
		-- flying along the course far off is going somewhere: never lost
		local b = G.newOff()
		h.eq(runLost(b, 300, 1000, 110, 60), -1, "300 studs off but moving along the course at 110: not lost")
		-- across the lap line the progress still counts (wrap)
		local w = G.newOff()
		h.eq(runLost(w, 300, L - 200, 110, 30), -1, "progress across the line wraps")
		-- flying backwards is no progress
		local r = G.newOff()
		h.ok(runLost(r, 300, 3000, -110, 30) > 0, "flying back along the course far off: lost")
		-- coming back inside 180 clears; the 180..200 band keeps the clock running (hysteresis)
		local c = G.newOff()
		runLost(c, 260, 1000, 0, 10)
		runLost(c, 190, 1000, 0, 2)
		h.ok(near(c.lostT, 12, 0.11), "the 180..200 band keeps counting, got " .. c.lostT)
		runLost(c, 150, 1000, 0, 0.1)
		h.eq(c.lostT, 0, "inside 180: cleared")
		h.eq(c.lostAnchor, nil)
		h.eq(G.progress(5400, 50, L), 100, "wrap forward")
		h.eq(G.progress(50, 5400, L), -100, "wrap back")
	end)

	h.test("4. stepMode: the default mode resets without an offer, Free driving offers RETURN and never resets near", function()
		local function sample(dist: number, inPocket: boolean?, yawErr: number?): any
			return { dist = dist, inPocket = inPocket == true, station = 1000, trackLength = 5450, yawErr = yawErr or 0 }
		end
		-- default: no offer ever, a reset past the bounds
		local m = G.newOff()
		local verdicts: { [string]: number } = {}
		for _ = 1, 200 do
			local v = G.stepMode(m, "mk", sample(120), 0.05)
			verdicts[v] = (verdicts[v] or 0) + 1
		end
		h.eq(verdicts.inside, 200, "120 studs for 10 s in the default mode: nothing at all (no caption, no button)")
		local fired = 0
		for _ = 1, 20 do
			if G.stepMode(m, "mk", sample(150), 0.05) == "bounds" then
				fired += 1
			end
		end
		h.eq(fired, 1, "past the bounds: one reset")
		h.eq(G.stepMode(G.newOff(), "mk", sample(400, true), 1), "inside", "in a pocket: no reset")
		-- Free: the same flight is free; RETURN offered, no reset
		local f = G.newOff()
		local last = ""
		for _ = 1, 200 do
			last = G.stepMode(f, "free", sample(150), 0.05)
			h.ok(last ~= "bounds", "Free driving never resets at the bounds")
		end
		h.eq(last, "offer", "RETURN is offered")
		local lost = 0
		local g = G.newOff()
		for _ = 1, 400 do
			if G.stepMode(g, "free", sample(260), 0.05) == "lost" then
				lost += 1
			end
		end
		h.eq(lost, 1, "Free driving far and lost for 20 s: one gentle return")
		-- grace after a return: nothing arms in either mode
		for _, mode in { "mk", "free" } do
			local q = G.newOff()
			G.startGrace(q)
			h.eq((G.stepMode(q, mode, sample(400, false, 170), 1.0)), "inside", mode .. ": grace")
			local v, ww = G.stepMode(q, mode, sample(400, false, 170), 0.5)
			h.ok(v == "inside" and not ww, mode .. ": still in grace at 1.5 s")
			G.stepMode(q, mode, sample(400, false, 170), 0.1)
			h.ok(q.grace < 1e-9, mode .. ": grace over")
		end
	end)

	h.test("5. no off-path slowdown and no forces: the drag and the hint are gone, the throttle rule for phones", function()
		h.eq(G.dragBlend, nil, "no drag toward 78 in either mode")
		h.eq(G.OFF_SPEED_CAP, nil)
		h.eq(G.stepHint, nil, "no drift hint")
		h.eq(G.guideAlpha, nil, "no on-path whisper")
		h.eq(G.LEASH_PULL_IN_RACE, false, "no pull toward the path in a race")
		local fc = h.readFile("src/client/FlightController.luau")
		h.ok(string.find(fc, "dragBlend", 1, true) == nil, "the speed target is never dragged")
		h.ok(string.find(fc, "dragT", 1, true) == nil)
		-- The auto throttle acts only with ASSIST on AND a race running; the player's switch wins on every device.
		h.eq(G.idleThrottle(true, true), G.AUTO_THROTTLE, "ASSIST on, racing: cruise")
		h.eq(G.idleThrottle(false, true), 0, "ASSIST off: no auto throttle, touch or not")
		h.eq(G.idleThrottle(true, false), 0, "hub / lobby / battle / results: no auto throttle")
		h.eq(G.idleThrottle(false, false), 0)
		h.ok(G.AUTO_THROTTLE > 0 and G.AUTO_THROTTLE < 1, "a cruise, not full throttle")
		h.ok(string.find(fc, "FlightGuideRules.idleThrottle(FlightController.autoThrottle, racing)", 1, true) ~= nil,
			"readCombinedInputs uses the rule")
	end)

	h.test("6. returnStation: at or behind best - 30, never ahead of the nearest point, never below 0", function()
		h.eq(G.returnStation(1500, 1200), 1170, "ahead of best: best - 30")
		h.eq(G.returnStation(1000, 1200), 970, "behind best: nearest - 30")
		h.eq(G.returnStation(20, 5420), 0, "just over the line with the lap not yet credited: clamps at 0")
		h.eq(G.returnStation(10, 20), 0, "lap start")
		h.eq(G.returnStation(800, nil), 770, "no best yet: nearest - 30")
		for _ = 1, 200 do
			local n, b = math.random() * 6000, math.random() * 6000
			local r = G.returnStation(n, b)
			h.ok(r <= b - 30 + 1e-9 or r == 0, "never past best - 30")
			h.ok(r <= n, "never ahead of the nearest point")
		end
	end)

	h.test("7. advanceBest: normal flight advances, a teleport does not, a chord back catches up, laps restart it", function()
		local g = G.newServerGuide()
		h.ok(G.advanceBest(g, 100, 0.1, true), "first sample sets best")
		for i = 1, 10 do
			G.advanceBest(g, 100 + i * 12, 0.1, true) -- 120 studs/s
		end
		h.eq(g.best, 220)
		h.ok(not G.advanceBest(g, 1120, 0.1, true), "a 900-stud jump in 0.1 s is rejected")
		h.eq(g.best, 220)
		h.ok(not G.advanceBest(g, 240, 0.1, false), "never advances off course")
		-- 4 s off course flying a chord, rejoining 600 further on: plausible at the ceiling, accepted
		for _ = 1, 40 do
			G.advanceBest(g, 300, 0.1, false)
		end
		h.ok(G.advanceBest(g, 820, 0.1, true), "a chord rejoin within what a plane can fly is accepted")
		-- wrap: the lap is credited, best restarts from the line
		local w = G.newServerGuide()
		G.advanceBest(w, 5400, 0.1, true)
		h.ok(not G.advanceBest(w, 20, 0.1, true), "a wrapped station is not progress on the old lap")
		G.newLap(w)
		h.ok(G.advanceBest(w, 20, 0.1, true) and w.best == 20, "after the lap reset it advances")
	end)

	h.test("8. canReturn: every refusal and the accept edge; the server clock holds and clears", function()
		local function ctx(over: { [string]: any }): any
			local c: { [string]: any } = { mode = "race", started = true, switching = false, battleOut = false, finished = false,
				trusted = true, isCar = false, offTime = 1.5, sinceReturn = 8, sinceRespawn = 5, reason = "Button", flightMode = "free" }
			for k, v in over do
				c[k] = v
			end
			return c
		end
		h.ok((G.canReturn(ctx({}))), "accepted at 1.5 s off and 8 s since the last return")
		local cases = {
			{ { offTime = 1.4 }, "onCourse" },
			{ { sinceReturn = 7 }, "cooldown" },
			{ { mode = "hub" }, "mode" },
			{ { mode = "battle" }, "mode" },
			{ { finished = true }, "finished" },
			{ { trusted = false }, "untrusted" },
			{ { isCar = true }, "car" },
			{ { started = false }, "notRacing" },
			{ { switching = true }, "notRacing" },
			{ { battleOut = true }, "battleOut" },
			{ { sinceRespawn = 0.5 }, "respawnFloor" },
			{ { reason = "Auto" }, "reason" },
			{ { reason = 7 }, "reason" },
			{ { reason = "Button", flightMode = "mk" }, "flightMode" },
			{ { reason = "Lost", flightMode = "mk" }, "flightMode" },
			{ { reason = "Bounds", flightMode = "free" }, "flightMode" },
			{ { reason = "Bounds", flightMode = "mk", offTime = 0.2 }, "onCourse" },
			{ { reason = "Bounds", flightMode = "mk", sinceReturn = 1.9 }, "cooldown" },
		}
		-- each reason in its own mode
		h.ok((G.canReturn(ctx({ reason = "Lost" }))), "Free driving: lost return")
		h.ok((G.canReturn(ctx({ reason = "Far", flightMode = "mk" }))), "the far rescue in the default mode")
		h.ok((G.canReturn(ctx({ reason = "Far", flightMode = "free" }))), "and in Free driving")
		h.ok((G.canReturn(ctx({ reason = "Bounds", flightMode = "mk", offTime = 0.3, sinceReturn = 2 }))),
			"a bounds reset: 0.3 s on the server clock and 2 s since the last one are enough")
		for _, c in cases do
			local ok, why = G.canReturn(ctx(c[1]))
			h.ok(not ok, "refused: " .. c[2])
			h.eq(why, c[2])
		end
		-- the server clock: runs past 55, holds in the 40..55 band, clears after 0.4 s inside 40
		local g = G.newServerGuide()
		for _ = 1, 20 do
			G.stepServer(g, 70, 0, 0.1)
		end
		h.ok(near(g.offTime, 2, 1e-6), "2 s off")
		G.stepServer(g, 50, 0, 1)
		h.ok(near(g.offTime, 2, 1e-6), "held in the band")
		G.stepServer(g, 30, 0, 0.3)
		h.ok(g.offTime > 0, "not cleared before 0.4 s")
		G.stepServer(g, 30, 0, 0.1)
		h.eq(g.offTime, 0, "cleared")
		-- 30 requests in 5 s: only the first passes the cooldown
		local accepted = 0
		local last = -math.huge
		for i = 0, 29 do
			local now = i * (5 / 30)
			if G.canReturn(ctx({ sinceReturn = now - last })) then
				accepted += 1
				last = now
			end
		end
		h.eq(accepted, 1, "one return per cooldown")
		-- the default mode's resets every 2.6 s (grace + flying out again) are never refused
		local resets = 0
		last = -math.huge
		for i = 0, 9 do
			local now = i * 2.6
			if G.canReturn(ctx({ reason = "Bounds", flightMode = "mk", offTime = 0.6, sinceReturn = now - last })) then
				resets += 1
				last = now
			end
		end
		h.eq(resets, 10, "every bounds reset passes")
	end)

	h.test("8b. returnFrame: lifted 14 over the ribbon, level, looking along the course", function()
		local cf = G.returnFrame(Vector3.new(100, 50, 200), Vector3.new(0.6, 0.3, -0.8))
		h.ok((cf.Position - Vector3.new(100, 64, 200)).Magnitude < 1e-4, "lifted")
		local look = cf.LookVector
		h.ok(math.abs(look.Y) < 1e-4, "level")
		local flat = Vector3.new(0.6, 0, -0.8).Unit
		h.ok(look:Dot(flat) > 0.9999, "along the tangent")
		h.ok(cf.UpVector.Y > 0.9999, "upright")
		local degenerate = G.frameAt(Vector3.zero, Vector3.new(0, 1, 0))
		h.ok(degenerate.LookVector.Magnitude > 0.99, "a vertical tangent still gives a frame")
	end)

	h.test("9. nodeStations: strictly ahead of near, spaced exactly, grid-anchored, capped", function()
		local buf = {}
		local _, n = G.nodeStations(1000, 48, 70, 560, 10, buf)
		h.ok(n == 10, "10 nodes")
		h.ok(buf[1] > 1070, "first node past near")
		for i = 2, n do
			h.eq(buf[i] - buf[i - 1], 48, "spacing")
		end
		for i = 1, n do
			h.eq(buf[i] % 48, 0, "on the grid")
			h.ok(buf[i] <= 1560, "inside far")
		end
		local first = buf[1]
		G.nodeStations(1010, 48, 70, 560, 10, buf)
		h.eq(buf[1], first, "same grid cell, same nodes (they do not swim)")
		local _, m = G.nodeStations(1000, 150, 70, 560, 10, buf)
		h.ok(m <= 4 and buf[m + 1] == nil, "short window: the buffer tail is cleared")
	end)

	h.test("10. budgets: every preset fits every tier (particles 90 / 54 / 30, Instances 40 / 26 / 18)", function()
		h.eq(#G.ORDER, 11, "the ten mockup styles and the bead mist")
		for _, id in G.ORDER do
			local p = G.PRESETS[id]
			h.ok(p ~= nil and p.id == id, "preset " .. id)
			for _, tier in { "desktop", "phone", "low" } do
				local plan = G.plan(p, tier)
				h.ok(plan.particles <= G.BUDGET[tier] + 1e-6, string.format("%s %s particles %.1f", id, tier, plan.particles))
				h.ok(plan.instances <= G.INSTANCE_CAP[tier], string.format("%s %s instances %d", id, tier, plan.instances))
				h.ok(plan.nodes >= 2, id .. " draws something on " .. tier)
				h.ok(plan.rateMul > 0 and plan.rateMul <= 1, id .. " rate multiplier")
			end
		end
		h.eq(G.plan(G.PRESETS.motes, "desktop").particles, 90, "motes use the desktop budget exactly")
		h.eq(G.tierOf(false, false), "desktop")
		h.eq(G.tierOf(false, true), "phone")
		h.eq(G.tierOf(true, false), "low")
		for _, tier in { "desktop", "phone", "low" } do
			h.eq(G.presetFor(nil, tier).id, "bead_mist", "Free driving draws the bead mist on " .. tier)
		end
		h.eq(G.presetFor("gates", "phone").id, "gates", "the pick-board attribute wins")
		h.eq(G.presetFor("off", "desktop"), nil, "off")
		h.eq(G.presetFor("nonsense", "desktop").id, "bead_mist", "an unknown id falls back")
		h.ok(G.PRESETS[G.DEFAULT_PRESET] and G.PRESETS[G.PHONE_PRESET], "named presets exist")
		-- the bead mist is cheap and LOD'd: well under every budget, fewer nodes on phones, no mist on LOW GRAPHICS
		local bm = G.PRESETS.bead_mist
		local d, ph, lo = G.plan(bm, "desktop"), G.plan(bm, "phone"), G.plan(bm, "low")
		h.ok(d.particles <= G.BUDGET.desktop / 2, string.format("desktop %.1f live particles, half the budget at most", d.particles))
		h.ok(ph.particles <= G.BUDGET.phone / 2 and ph.nodes < d.nodes, "phone: fewer nodes, under half its budget")
		h.eq(#G.layersFor(bm, "low"), 1, "LOW GRAPHICS: beads only")
		h.eq(#G.layersFor(bm, "desktop"), 2, "beads and mist")
		h.ok(lo.instances <= G.INSTANCE_CAP.low and lo.particles <= ph.particles, "low tier cheapest")
		h.eq(d.rateMul, 1, "no rate trimming needed")
	end)

	h.test("11. alphaAt: nothing at the camera or outside the window, monotone ramps, transparency floors", function()
		h.eq(G.alphaAt(300, 10), 0, "inside CAM_CLEAR")
		h.eq(G.alphaAt(60, 200), 0, "before near")
		h.eq(G.alphaAt(600, 200), 0, "past far")
		h.eq(G.alphaAt(300, 200), 1, "mid window")
		local prev = -1
		for d = 70, 150, 5 do
			local a = G.alphaAt(d, 200)
			h.ok(a >= prev, "fade in monotone")
			prev = a
		end
		prev = 2
		for d = 400, 560, 5 do
			local a = G.alphaAt(d, 200)
			h.ok(a <= prev, "fade out monotone")
			prev = a
		end
		for a = 0, 1, 0.1 do
			h.ok(G.transparencyAt(a, G.MIN_T_PARTICLE) >= 0.55 - 1e-9, "particles never under 0.55")
			h.ok(G.transparencyAt(a, G.MIN_T_BEAM) >= 0.7 - 1e-9, "beams never under 0.7")
		end
		h.eq(G.level(0), 0)
		h.eq(G.level(1), G.LEVELS)
		-- "more transparent than the mockup": the beads at best 0.78, the mist at best 0.89 (the mockup drew 0.55)
		local bm = G.PRESETS.bead_mist
		local function best(l: any): number
			return G.transparencyAt(G.level(G.FREE_ALPHA) / G.LEVELS, G.layerFloor(l))
		end
		h.ok(G.FREE_ALPHA > 0 and G.FREE_ALPHA <= 0.5, "Free driving draws at half the visibility at most")
		h.ok(G.level(G.FREE_ALPHA) >= 1, "and still draws after quantising")
		h.ok(best(bm.layers[1]) >= 0.75, string.format("beads at best %.3f transparent", best(bm.layers[1])))
		h.ok(best(bm.layers[2]) >= 0.85, string.format("mist at best %.3f transparent", best(bm.layers[2])))
		h.ok(best(G.PRESETS.beads.layers[1]) > 0.55, "fainter than the mockup's 0.55 floor")
	end)

	h.test("12. preset table: kinds, spacing, layers, colours never fully saturated, beads below the eye line", function()
		local kinds = { emit = true, chain = true, ring = true, gate = true, chevron = true }
		for id, p in G.PRESETS do
			h.ok(p.spacing > 0 and p.nodes > 0 and #p.layers > 0, id .. " shape")
			h.ok(p.spacing * 2 <= G.FAR - G.NEAR, id .. " fits at least two nodes in the window")
			for _, l in p.layers do
				h.ok(kinds[l.kind], id .. " kind " .. tostring(l.kind))
				if l.kind == "emit" then
					h.ok(l.rate > 0 and l.life > 0 and (l.size or 0) <= 4, id .. " emitter sane (size <= 4 studs)")
					h.ok(l.spiral ~= nil or (type(l.offsets) == "table" and #l.offsets > 0), id .. " emitter has a place")
					if l.spiral then
						h.ok(l.radius >= G.R_IN and l.radius <= G.R_OUT, id .. " spiral in the annulus")
					end
				end
				if l.kind == "ring" then
					h.ok(l.radius >= G.R_IN and l.radius <= G.R_OUT, id .. " ring in the annulus")
				end
				-- anything on the line itself stays below the plane's eye line, and thin
				if l.offset and math.abs(l.offset[1]) < 3 then
					h.ok(l.offset[2] < 0, id .. " below the eye line")
				end
				if l.offsets then
					for _, o in l.offsets do
						if math.abs(o[1]) < 3 then
							h.ok(o[2] < 0, id .. " emitter on the line sits below the eye line")
						end
					end
				end
				if l.width then
					h.ok(l.width <= 0.6, id .. " beams stay thin")
				end
			end
		end
		local function soft(c: { number })
			return math.max(c[1], c[2], c[3]) - math.min(c[1], c[2], c[3]) <= 200
		end
		h.ok(soft(G.TINT_DEFAULT.core) and soft(G.TINT_DEFAULT.edge))
		for id, t in G.TINTS do
			h.ok(soft(t.core) and soft(t.edge), id .. " tint not fully saturated")
		end
		h.eq(G.tintFor("SNOW-1"), G.TINTS["SNOW-1"])
		h.eq(G.tintFor("nope"), G.TINT_DEFAULT)
	end)

	h.test("13. source guards: the wiring the design needs, planes only, wall driving untouched", function()
		local fc = h.readFile("src/client/FlightController.luau")
		local function has(src: string, needle: string, what: string)
			h.ok(string.find(src, needle, 1, true) ~= nil, what)
		end
		local function hasnt(src: string, needle: string, what: string)
			h.ok(string.find(src, needle, 1, true) == nil, what)
		end
		has(fc, [[_reason == "Return"]], "Return is a rescue reason (short poof, no tumble)")
		has(fc, [[completeRespawn(cf, true)]], "a return lands on the server's frame without RequestRespawn")
		has(fc, [[if flightStateRemote and not serverPlaced then]], "completeRespawn skips RequestRespawn for a return")
		has(fc, [[eventType == "CourseReturn"]], "the client applies CourseReturn")
		has(fc, [[Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter, Enum.KeyCode.ButtonY]], "Enter / gamepad Y")
		has(fc, [[FlightGuideRules.stepMode(offState, mode, offSample, clampedDt)]], "one mode-aware step")
		has(fc, [[FlightGuideRules.modeOf(LocalPlayer:GetAttribute(FlightGuideRules.MODE_ATTR))]], "the mode is the server attribute")
		has(fc, [[CourseArrow.set(wrongWay or (leash.warn and not guiding), -yawErr, w)]], "WRONG WAY only; no off-course arrow in a race")
		has(fc, [[and flightMode() == FlightGuideRules.MODE_FREE and]], "RETURN is offered in Free driving only")
		has(fc, [[if mode == FlightGuideRules.MODE_FREE then
				FlightGuide.step(clampedDt, here, sampleStation, sampleLine, sampleAlong)
			else
				FlightGuide.hide()]], "the bead mist draws in Free driving only, nothing in the default mode")
		has(fc, [[local reason = if far then "Far" elseif auto == "bounds" then "Bounds" else "Lost"]], "reasons per verdict")
		has(fc, [[if why == "Lost" or why == "Far" then]], "a bounds reset says nothing (no BACK YOU GO!)")
		has(fc, [[offSample.inPocket = dist > FlightGuideRules.BOUND and FlightGuideRules.inPocket(pockets(), here)]],
			"pockets are only looked up past the bounds, at the simulated position (plane_stutter.md C3)")
		has(fc, [[local pullW = if guiding and not FlightGuideRules.LEASH_PULL_IN_RACE then 0 else w]], "no leash pull in a race")
		hasnt(fc, "* w, steer.Y", "the steering blend uses pullW, never the raw leash weight")
		hasnt(fc, "stepHint", "no drift hint")
		has(fc, [[return leashActive() and LocalPlayer:GetAttribute("RaceFinished") ~= true]], "the modes run where the leash does")
		-- the CourseReturn handler must not move the checkpoint frame
		local s0, e0 = string.find(fc, [[eventType == "CourseReturn"]], 1, true)
		local handler = string.sub(fc, s0 :: number, (e0 :: number) + 1100)
		local stop = string.find(handler, "elseif eventType", 30, true)
		handler = string.sub(handler, 1, stop or #handler)
		hasnt(handler, "lastCheckpointCF", "CourseReturn never touches lastCheckpointCF")
		local fg = h.readFile("src/client/FlightGuide.luau")
		hasnt(fg, "funnel", "no drift funnel")
		has(fg, [[local vis = FlightGuideRules.FREE_ALPHA]], "the mist is drawn at FREE_ALPHA")
		local hud = h.readFile("src/client/HudExtras.luau")
		hasnt(hud, [[showNotice("offcourse", "Off course"]], "no Off course caption in either mode")
		local fs = h.readFile("src/server/FlightServer.luau")
		has(fs, [[action == "RequestCourseReturn"]], "server handler")
		has(fs, [[FlightGuideRules.canReturn(]], "server gate")
		has(fs, [[flightMode = FlightGuideRules.modeOf(player:GetAttribute(FlightGuideRules.MODE_ATTR))]], "the gate knows the mode")
		has(fs, [[FlightServer.teleportHook(player, cf)]], "the validator is told of the return frame")
		has(fs, [["CourseReturnRefused"]], "refusals are answered")
		local ss = h.readFile("src/server/SettingsService.luau")
		has(ss, [[player:SetAttribute(SettingsRules.FLIGHT_MODE_ATTR, SettingsRules.flightModeOf(update.freeDriving))]],
			"the server publishes the validated mode")
		local rm = h.readFile("src/server/RaceManager.luau")
		has(rm, [[FlightServer.stepGuide(rec, st, ribbonPoint, dt)]], "the server clock steps with progress")
		has(rm, [[FlightServer.guideNewLap(rec)]], "best progress restarts each lap")
		has(rm, [[FlightGuideRules.checkpointCounts(dPos <= FlightGuideRules.CP_GATE, dSt <= 110, courseDist, inPocket)]],
			"planes earn a gate by station only on the course")
		has(rm, [[local gatesOk = not isPlane or FlightGuideRules.planeGatesOk(rec.passedCheckpoints, planeCPMust)]], "planes need every non-bypassed gate")
		has(rm, [[else (dPos <= 85 or dSt <= 110)]], "cars keep the old gate rule")
		local ma = h.readFile("src/server/MapAdapter.luau")
		has(ma, [[publishPockets(root, if type(fl) == "table" then fl.allowPockets else nil)]], "MapAdapter publishes the pockets")
		-- Owner rule 2026-10-20: car adhesion, wall / slope climbing, barriers and car rescue are not touched.
		for _, path in { "src/client/CarController.luau", "src/server/CarServer.luau" } do
			local src = h.readFile(path)
			hasnt(src, "FlightGuide", path .. " does not know the guide")
			hasnt(src, "CourseReturn", path .. " has no course return")
			hasnt(src, "FlightMode", path .. " has no flight mode")
		end
		-- Bots never run the client guide or the modes.
		local ai = h.readFile("src/server/AIRacers.luau")
		hasnt(ai, "FlightGuide", "bots unaffected")
		hasnt(ai, "FlightMode", "bots have no mode")
	end)

	h.test("14. WRONG WAY in both modes; the plane checkpoint rule keeps Free driving on the course", function()
		-- WRONG WAY: 3 s heading away, a tight bend never counts, facing the line clears it at once
		local w = G.newOff()
		local wrongAt, t = -1, 0
		while t < 4 - 1e-9 do
			t += 0.05
			if G.stepWrongWay(w, 170, 0.05) and wrongAt < 0 then
				wrongAt = t
			end
		end
		h.ok(near(wrongAt, G.WRONG_WAY_S, 1e-6), "WRONG WAY at 3 s, got " .. wrongAt)
		h.ok(not G.stepWrongWay(w, 20, 0.05) and w.awayT == 0, "facing the line again clears it")
		local hp = G.newOff()
		for _ = 1, 100 do
			h.ok(not G.stepWrongWay(hp, 35, 0.05), "a hairpin's yaw error is not away")
		end
		for _, mode in { "mk", "free" } do
			local m = G.newOff()
			local ww = false
			for _ = 1, 70 do
				_, ww = G.stepMode(m, mode, { dist = 20, inPocket = false, station = 0, trackLength = 5450, yawErr = 175 }, 0.05)
			end
			h.ok(ww, mode .. ": flying backwards on the path raises WRONG WAY")
		end
		-- checkpoints: near the gate always, by station only on the course (or in a pocket)
		h.ok(G.checkpointCounts(true, false, 999, false), "through the gate itself, from anywhere")
		h.ok(G.checkpointCounts(false, true, 120, false), "by station on the course")
		h.ok(not G.checkpointCounts(false, true, 200, false), "by station 200 studs off the course: no")
		h.ok(G.checkpointCounts(false, true, 200, true), "by station inside an allow-pocket: yes")
		h.ok(not G.checkpointCounts(false, false, 0, false))
		h.eq(G.CP_COURSE_DIST, G.BOUND, "the same corridor the default mode flies in")
		-- the lap needs every gate an alternate does not bypass (DINO-4's real numbers)
		local dino = { 0, 109, 216, 815, 1270, 1598, 1824, 2059, 2380, 2883, 3444, 4040, 4519, 5042, 5290 }
		local cps = {}
		for i, st in dino do
			cps[i] = { index = i, station = st }
		end
		local lines = { { join = 130, rejoin = 1420 }, { join = 2380, rejoin = 3240 }, { join = nil, rejoin = nil } }
		local must = G.mustPassCheckpoints(cps, lines)
		h.eq(#must, 11, "all but 216, 815, 1270 (Alt1) and 2883 (Alt2); 2380 sits on the join, not inside")
		local function passedExcept(skip: { [number]: boolean }): { [number]: boolean }
			local p = {}
			for i, st in dino do
				if not skip[st] then
					p[i] = true
				end
			end
			return p
		end
		h.ok(G.planeGatesOk(passedExcept({}), must), "a clean lap")
		h.ok(G.planeGatesOk(passedExcept({ [216] = true, [815] = true, [1270] = true }), must), "Alt1 bypasses three gates legally")
		h.ok(G.planeGatesOk(passedExcept({ [2883] = true, [3444] = true }), must), "Alt2 plus one missed gate (the slack)")
		h.ok(not G.planeGatesOk(passedExcept({ [3444] = true, [4040] = true }), must), "two real gates missing: no lap")
		-- a chord over the far side of the loop: the gates it skips are 300 studs from any course line
		local passed: { [number]: boolean } = {}
		local count = 0
		for i, st in dino do
			local onChord = st > 2059 and st < 4519
			if G.checkpointCounts(false, true, if onChord then 300 else 20, false) then
				passed[i] = true
				count += 1
			end
		end
		h.ok(not G.planeGatesOk(passed, must), "a chord past " .. (#dino - count) .. " gates is not a lap")
		h.ok(count >= math.max(3, math.floor(#dino * PlaneConfig.CHECKPOINT_GATE_FRACTION)),
			"(the old 55 percent rule alone would have credited it)")
	end)
end
