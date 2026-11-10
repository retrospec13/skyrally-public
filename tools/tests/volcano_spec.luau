--!strict
-- Lune spec for the DINO-4 launch upgrade (docs/design/TRACK_VARIETY.md 5a): shared/VolcanoRules (the fixed 4 s geyser
-- cycle, the server's verdict on a crossing, the lap-3 eruption numbers and their caps) and server/VolcanoVents (the
-- cooldown book and the refusal reasons), plus static checks that the vents are never solid and never a hazard.
-- Run: tools/tests/run_lune_tests.sh tools/tests/volcano_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
	readFile: (string) -> string,
	logs: { string },
	newScheduler: (number?) -> any,
	fakePlayer: (number, string?) -> any,
	stubs: any,
}

return function(h: Harness)
	local Rules = h.require("src/shared/VolcanoRules.luau")

	local function near(a: number, b: number, eps: number, msg: string?)
		h.ok(math.abs(a - b) <= eps, string.format("%s: %.4f vs %.4f (eps %.4f)", msg or "near", a, b, eps))
	end

	local vent = Rules.parseVent({ id = "V1", pos = Vector3.new(10, 100, -50), phase = 0 })

	h.test("the cycle is a fixed 4 seconds and the stages add up", function()
		h.eq(Rules.CYCLE, 4)
		near(Rules.DORMANT + Rules.BUILD + Rules.ACTIVE, Rules.CYCLE, 1e-9)
		h.ok(Rules.BUILD >= 1.2, "the telegraph is visible for at least 1.2 s")
		h.ok(Rules.ACTIVE >= 1 and Rules.ACTIVE <= 1.5, "a window a player can hit")
	end)

	h.test("stages follow the clock and repeat every cycle", function()
		for k = 0, 5 do
			local base = k * 4
			h.eq((Rules.stage(base + 0.1, 0)), "dormant")
			h.eq((Rules.stage(base + 1.5, 0)), "build")
			h.eq((Rules.stage(base + 3.2, 0)), "active")
			h.eq((Rules.stage(base + 3.99, 0)), "active")
		end
		h.eq((Rules.stage(-0.5, 0)), "active", "negative time wraps")
	end)

	h.test("phase staggers a second vent by half a cycle", function()
		for i = 0, 39 do
			local t = i * 0.1
			local a = Rules.isActive(t, 0)
			local b = Rules.isActive(t, 2)
			h.ok(not (a and b), "never both up at once")
		end
		h.eq(Rules.isActive(3.5, 0), true)
		h.eq(Rules.isActive(3.5, 2), false)
		h.eq(Rules.isActive(1.5, 2), true)
	end)

	h.test("the active window is ACTIVE long, and the telegraph precedes it", function()
		local up = 0
		local sawBuildFirst = true
		local prevStage = ""
		for i = 0, 3999 do
			local t = i * 0.001
			if Rules.isActive(t, 0) then
				up += 1
			end
			local s = Rules.stage(t, 0)
			if s == "active" and prevStage ~= "active" and prevStage ~= "build" and prevStage ~= "" then
				sawBuildFirst = false
			end
			prevStage = s
		end
		near(up / 1000, Rules.ACTIVE, 0.01, "active seconds per cycle")
		h.ok(sawBuildFirst, "active never starts without a build-up before it")
	end)

	h.test("glow rises through the build-up and never drops to zero", function()
		local prev = -1
		for i = 0, 15 do
			local g = Rules.glow(1.2 + i * 0.1, 0)
			h.ok(g >= prev - 1e-9, "monotonic through build")
			prev = g
		end
		for i = 0, 39 do
			local g = Rules.glow(i * 0.1, 0)
			h.ok(g > 0.05 and g <= 1, "glow within range")
		end
	end)

	h.test("steam rate is a trickle, then thickens, then the column; scale caps it", function()
		h.ok(Rules.steamRate(0.5, 0, 1) < Rules.steamRate(2.7, 0, 1))
		h.ok(Rules.steamRate(2.7, 0, 1) < Rules.steamRate(3.5, 0, 1))
		h.ok(Rules.steamRate(3.5, 0, 1) <= 60, "column stays inside the particle budget")
		near(Rules.steamRate(3.5, 0, 0.4), 0.4 * Rules.steamRate(3.5, 0, 1), 1e-9)
		h.eq(Rules.steamRate(3.5, 0, 0), 0)
	end)

	h.test("the column is a cylinder", function()
		h.ok(Rules.inColumn(vent, Vector3.new(10, 114, -50)), "flight line on the axis")
		h.ok(Rules.inColumn(vent, Vector3.new(10 + 11, 114, -50)), "inside the radius")
		h.ok(not Rules.inColumn(vent, Vector3.new(10 + 13, 114, -50)), "outside the radius")
		h.ok(not Rules.inColumn(vent, Vector3.new(10, 100 + 27, -50)), "above the top")
		h.ok(not Rules.inColumn(vent, Vector3.new(10, 99, -50)), "under the floor")
		h.ok(Rules.inColumn(vent, Vector3.new(10 + 13, 114, -50), 2), "slack widens it")
	end)

	h.test("server verdict: window, position, cooldown", function()
		local onAxis = Vector3.new(10, 114, -50)
		local ok1, why1 = Rules.validate(vent, onAxis, 3.5, nil)
		h.eq(ok1, true)
		h.eq(why1, "ok")
		local ok2, why2 = Rules.validate(vent, onAxis, 1.0, nil)
		h.eq(ok2, false)
		h.eq(why2, "dormant")
		local ok3, why3 = Rules.validate(vent, Vector3.new(80, 114, -50), 3.5, nil)
		h.eq(ok3, false)
		h.eq(why3, "far")
		local ok4, why4 = Rules.validate(vent, onAxis, 3.6, 3.5)
		h.eq(ok4, false)
		h.eq(why4, "cooldown")
		local ok5 = Rules.validate(vent, onAxis, 6.1, 3.5)
		h.eq(ok5, false, "mid build-up of the next cycle")
		local ok6 = Rules.validate(vent, onAxis, 7.5, 3.5)
		h.eq(ok6, true, "next cycle's window is open and the cooldown has passed")
	end)

	h.test("lag allowance: an honest fast crossing passes, far or teleport claims do not", function()
		local claim = Vector3.new(10 + 3, 114, -50) -- client: 3 studs from the axis
		local lagged = Vector3.new(10 + 3 - 30, 114, -50) -- server hull 30 studs behind (170 studs/s, ~0.2 s)
		local allow = Rules.lagAllowance(170, 0.3)
		h.ok(allow >= 30 and allow <= Rules.LAG_MAX, "allowance covers the trail and stays clamped")
		h.eq((Rules.validate(vent, lagged, 3.5, nil)), false, "no claim: the lagging hull alone is refused")
		h.eq((Rules.validate(vent, lagged, 3.5, nil, claim, allow)), true, "honest claim near the lagging hull")
		h.eq((Rules.validate(vent, Vector3.new(10 - 200, 114, -50), 3.5, nil, claim, allow)), false, "teleport claim")
		h.eq((Rules.validate(vent, lagged, 3.5, nil, Vector3.new(10 + 60, 114, -50), allow)), false, "claim outside the column")
		h.eq((Rules.validate(vent, lagged, 2.0, nil, claim, allow)), false, "stage still checked")
		h.eq((Rules.validate(vent, lagged, 3.6, 3.5, claim, allow)), false, "cooldown still holds")
		local studio = Rules.lagAllowance(172, 0) -- Studio play: near-zero ping, yet the hull trailed 17-35 studs (V7A)
		h.ok(studio >= 35, "zero ping still covers the replication-buffer trail")
		h.eq((Rules.validate(vent, Vector3.new(10 + 3 - 35, 114, -50), 3.5, nil, claim, studio)), true, "Studio-like trail at zero ping")
		h.ok(Rules.lagAllowance(210, 0) <= Rules.LAG_MAX, "overcharge speed stays clamped")
		h.eq(Rules.lagAllowance(1e6, 5), Rules.LAG_MAX, "clamped high")
		h.eq(Rules.lagAllowance(0, 0), Rules.LAG_FLOOR, "clamped low")
	end)

	h.test("server slack accepts a late report and still refuses the middle of the build-up", function()
		local onAxis = Vector3.new(10, 114, -50)
		h.eq((Rules.validate(vent, onAxis, 4.2, nil)), true, "a report just past the end")
		h.eq((Rules.validate(vent, onAxis, 2.5, nil)), true, "a report just before the start (clock slack)")
		h.eq((Rules.validate(vent, onAxis, 2.0, nil)), false, "mid build-up")
		h.eq((Rules.validate(vent, onAxis, 0.8, nil)), false, "dormant")
	end)

	h.test("a vent boosts once per cycle at most", function()
		h.ok(Rules.COOLDOWN < Rules.CYCLE and Rules.COOLDOWN > Rules.CYCLE - Rules.ACTIVE - 0.2)
	end)

	h.test("parseVent clamps and rejects", function()
		h.eq(Rules.parseVent({ id = 3, pos = Vector3.zero }), nil)
		h.eq(Rules.parseVent({ id = "x", pos = "no" }), nil)
		local v = Rules.parseVent({ id = "x", pos = Vector3.zero, radius = 99, height = 1, phase = 1.5 })
		h.eq(v.radius, 20)
		h.eq(v.height, 8)
		h.eq(v.phase, 1.5)
	end)

	h.test("the eruption wakes on lap 3 only", function()
		h.eq(Rules.erupting(3, nil), true)
		h.eq(Rules.erupting(2, nil), false)
		h.eq(Rules.erupting(1, 3), false)
		h.eq(Rules.erupting(2, 2), true)
		h.eq(Rules.erupting(nil, 3), false)
	end)

	h.test("eruption mood ramps in and the numbers stay inside the camera and phone caps", function()
		h.eq(Rules.level(-1), 0)
		h.eq(Rules.level(0), 0)
		h.eq(Rules.level(99), 1)
		h.ok(Rules.level(1) > 0 and Rules.level(1) < 1)
		local peakLight, peakAsh = 0, 0
		for i = 0, 600 do
			local t = i * 0.1
			local l = Rules.lavaLight(t)
			peakLight = math.max(peakLight, l)
			peakAsh = math.max(peakAsh, Rules.ashRate(t, 1))
			h.ok(l >= 0 and l <= Rules.GLOW_MAX + 1e-9, "light within cap")
			h.ok(Rules.rumbleSwell(t) >= 0 and Rules.rumbleSwell(t) <= 1 + 1e-9)
		end
		h.ok(peakLight > 0.4, "it visibly pulses")
		h.ok(peakLight <= 1.1)
		h.ok(peakAsh <= 14.01 and peakAsh > 5)
		h.ok(Rules.ashRate(30, 0.4) <= 0.4 * Rules.ASH_MAX + 1e-9, "the phone scale applies")
		h.ok(Rules.ASH_SIZE_MAX <= 1 and Rules.ASH_TRANSPARENCY_MIN >= 0.4, "ash is small and translucent")
		h.ok(Rules.SHAKE_MAX <= 0.12, "the shake stays under a boost's")
	end)

	h.test("the lava light actually pulses (not constant)", function()
		local lo, hi = math.huge, 0
		for i = 0, 100 do
			local l = Rules.lavaLight(20 + i * 0.05)
			lo, hi = math.min(lo, l), math.max(hi, l)
		end
		h.ok(hi - lo > 0.15, "swing")
	end)

	h.test("rumbles start on the beat, once each", function()
		h.eq(Rules.rumbleStarts(-1, 0.01), true, "the first at the start")
		h.eq(Rules.rumbleStarts(0.01, 0.5), false)
		h.eq(Rules.rumbleStarts(8.9, 9.05), true)
		h.eq(Rules.rumbleStarts(9.05, 9.2), false)
		local n = 0
		local prev = -1
		for i = 0, 3000 do
			local t = i * 0.01
			if Rules.rumbleStarts(prev, t) then
				n += 1
			end
			prev = t
		end
		h.eq(n, 4, "0, 9, 18, 27 in thirty seconds")
	end)

	h.test("the module never makes a vent solid or harmful", function()
		local server = h.readFile("src/server/VolcanoVents.luau")
		local client = h.readFile("src/client/VolcanoMoments.luau")
		h.contains(server, "p.CanCollide = false")
		h.contains(server, "p.CanQuery = false")
		h.contains(server, "p.CanTouch = false")
		h.ok(not server:find("HazardType", 1, true), "no hazard attribute")
		h.ok(not server:find("Humanoid", 1, true) and not server:find("TakeDamage", 1, true), "no damage")
		h.ok(not client:find("triggerCrash", 1, true) and not client:find("itemStunTimer", 1, true), "no crash or stun")
		-- every plan vent sits in the file the author writes, never in the egg hall
		local td = h.readFile("build/dino4/TrackData.luau")
		h.contains(td, "AltGeyser1")
		h.contains(td, "AltGeyser2")
	end)

	h.test("RaceManager accepts GeyserTriggered only through the server check", function()
		local rm = h.readFile("src/server/RaceManager.luau")
		local at = rm:find('eventType == "GeyserTriggered"', 1, true)
		h.ok(at ~= nil)
		local seg = rm:sub(at :: number, (at :: number) + 520)
		h.contains(seg, "VolcanoVents.onTriggered")
		h.contains(seg, "RaceManager.isHub()")
	end)
end
