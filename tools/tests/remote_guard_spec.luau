--!strict
-- Remote hardening (systems audit v32 T1-9, MP-4/MP-8): shared/RemoteGuardRules (enum / finite / name checks, token
-- buckets, the hull position history and the ring / boost-pad claim verdict) and the static wiring in RaceManager,
-- FlightServer, CarServer, ItemService and TrackDirector. The legitimate cases come first: a full-speed pass between two
-- history samples, a pass the replicated hull has not shown yet, a wall-driving climb, a lifted pad; then the forged
-- ones: a claim from across the map, a repeat inside the cooldown, a claim spanning a respawn teleport, junk strings.
-- remote_inventory_spec.luau checks that every server remote handler is on the audited list.
-- Run: tools/tests/run_lune_tests.sh tools/tests/remote_guard_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local G = h.require("src/shared/RemoteGuardRules.luau")
	local PlaneConfig = h.require("src/shared/PlaneConfig.luau")
	local CarConfig = h.require("src/shared/CarConfig.luau")

	---------------------------------------------------------------------------------------------- value checks

	h.test("BoostState: only None / Standard / Overcharge; anything else (or any other type) is refused", function()
		for _, v in { "None", "Standard", "Overcharge" } do
			h.eq(G.boostState(v), v)
		end
		for _, v in { "Hacked", "", "standard", "Overcharge ", string.rep("x", 5000), 1, true, {}, nil } do
			h.eq(G.boostState(v), nil, "refused " .. tostring(v))
		end
		-- The client and every server writer use names from this set.
		local fc = h.readFile("src/client/FlightController.luau")
		h.contains(fc, '"None" | "Standard" | "Overcharge"')
		for _, b in CarConfig.DRIFT_LEVELS do
			h.ok(G.BOOST_STATES[b.boostState], "drift level boostState " .. b.boostState .. " is in the enum")
		end
	end)

	h.test("numbers: NaN, +-inf and non-numbers refused; finite values clamped", function()
		h.eq(G.num(0 / 0, 0, 260), nil)
		h.eq(G.num(math.huge, 0, 260), nil)
		h.eq(G.num(-math.huge, 0, 260), nil)
		h.eq(G.num("100", 0, 260), nil)
		h.eq(G.num(nil, 0, 260), nil)
		h.eq(G.num(9999, 0, 260), 260)
		h.eq(G.num(-5, 0, 260), 0)
		h.eq(G.num(0.5, -1, 1), 0.5)
		h.ok(G.finite(1) and not G.finite(0 / 0) and not G.finite("1"))
	end)

	h.test("names: non-empty, at most 64 chars, no control characters", function()
		h.eq(G.name("Ring_12"), "Ring_12")
		h.eq(G.name(""), nil)
		h.eq(G.name(string.rep("a", 65)), nil)
		h.eq(G.name("Ring\n12"), nil)
		h.eq(G.name("Ring\0"), nil)
		h.eq(G.name(12), nil)
		h.eq(G.shown("a\nb"), "a?b")
		h.eq(#G.shown(string.rep("x", 100)), 24)
	end)

	---------------------------------------------------------------------------------------------- rate limits

	h.test("token bucket: burst, then limited, refills at perSec; forget drops the bucket", function()
		local L = { burst = 3, perSec = 2 }
		local lim = G.newLimiter(L)
		h.ok(lim.allow("p", 0) and lim.allow("p", 0) and lim.allow("p", 0))
		h.ok(not lim.allow("p", 0), "4th in the same instant refused")
		h.ok(not lim.allow("p", 0.4), "0.8 token after 0.4 s: still refused")
		h.ok(lim.allow("p", 0.5), "one token back after 0.5 s")
		h.ok(lim.allow("q", 0), "buckets are per key")
		h.eq(lim.size(), 2)
		lim.forget("p")
		h.eq(lim.size(), 1)
		h.ok(lim.allow("p", 0.5), "a forgotten key starts full")
	end)

	h.test("limits are at least twice the honest peak of each remote", function()
		local sync = math.max(1 / 0.08, 1 / CarConfig.SYNC_INTERVAL) -- SyncTransform Hz (plane 0.08 s, car)
		h.ok(G.LIMITS.flightState.perSec >= 2 * sync, "flightState covers SyncTransform x2")
		-- An honest SyncTransform stream for a minute is never limited.
		local lim = G.newLimiter(G.LIMITS.flightState)
		local refused = 0
		for i = 0, 60 * 12.5 do
			if not lim.allow("p", i * 0.08) then
				refused += 1
			end
		end
		h.eq(refused, 0)
		-- A looping client is: 1000 events in one second leave at most burst + perSec through.
		local through = 0
		for i = 1, 1000 do
			if lim.allow("x", 100 + i / 1000) then
				through += 1
			end
		end
		h.ok(through <= G.LIMITS.flightState.burst + G.LIMITS.flightState.perSec + 1, "flood capped: " .. through)
		-- Rings and pads: one per 1.2 s per trigger on the client; a dense line of 6 triggers plus pods in a second.
		h.ok(G.LIMITS.raceEvent.burst >= 12 and G.LIMITS.raceEvent.perSec >= 6)
		h.ok(G.LIMITS.item.burst >= 6)
	end)

	---------------------------------------------------------------------------------------------- history + claims

	local function v(x: number, y: number, z: number): Vector3
		return Vector3.new(x, y, z)
	end

	-- A straight run along +X at `speed` studs/s, sampled every heartbeat (1/60 s) from t0 to t1.
	local function run(tr: any, from: Vector3, dir: Vector3, speed: number, t0: number, t1: number)
		local t = t0
		while t <= t1 + 1e-9 do
			G.record(tr, t, from + dir * (speed * (t - t0)))
			t += 1 / 60
		end
	end

	local function verdict(tr: any, ring: Vector3, live: Vector3?, now: number, ping: number?, lastAt: number?, radius: number?): (boolean, string)
		return G.triggerVerdict({
			found = true,
			distance = G.nearest(tr, ring, live, now),
			radius = radius or G.TRIGGER.ringRadius,
			ping = ping,
			lastAt = lastAt,
			now = now,
		})
	end

	h.test("radii cover both vehicles; reach grows with ping up to pingMax", function()
		h.ok(G.TRIGGER.ringRadius >= PlaneConfig.RING_TRIGGER_RADIUS and G.TRIGGER.ringRadius >= CarConfig.RING_TRIGGER_RADIUS)
		h.ok(G.TRIGGER.padRadius >= PlaneConfig.PAD_TRIGGER_RADIUS and G.TRIGGER.padRadius >= CarConfig.PAD_TRIGGER_RADIUS)
		h.ok(G.TRAIL.maxSpeed >= PlaneConfig.OVERCHARGE_SPEED and G.TRAIL.maxSpeed >= CarConfig.ITEM_BOOST_MAX_SPEED)
		h.ok(G.reach(19, 0.2) > G.reach(19, 0))
		h.eq(G.reach(19, 5), G.reach(19, G.TRIGGER.pingMax), "ping capped")
		h.eq(G.reach(19, 0 / 0), G.reach(19, G.TRIGGER.pingMax), "unknown ping = the cap")
	end)

	h.test("legit: a full-speed (Overcharge 210) pass straight through the ring is paid, samples or not", function()
		local tr = G.newTrail()
		local ring = v(500, 80, 0)
		run(tr, v(0, 80, 0), v(1, 0, 0), PlaneConfig.OVERCHARGE_SPEED, 0, 3) -- passes x=500 at t=2.38
		local ok, why = verdict(tr, ring, v(630, 80, 0), 3, 0.08)
		h.ok(ok, why)
		-- The 20 Hz trail puts samples ~10 studs apart at 210 studs/s; the segment still passes the centre exactly.
		h.ok(G.nearest(tr, ring, nil, 3) < 0.5, "segment distance through the centre")
	end)

	h.test("legit: the event arrives before the replicated hull reaches the ring (lag) and is still paid", function()
		local tr = G.newTrail()
		local ring = v(500, 80, 0)
		-- The server has seen the plane up to 0.2 s short of the ring (42 studs at 210) when the claim lands.
		run(tr, v(0, 80, 0), v(1, 0, 0), 210, 0, (500 - 42) / 210)
		local now = (500 - 42) / 210
		local ok, why = verdict(tr, ring, v(458, 80, 0), now, 0.1)
		h.ok(ok, why)
	end)

	h.test("legit: wall driving / climbing (vertical and upside-down lines) and a lifted plane pad are paid", function()
		-- A car climbing a cliff face straight up past a pad on the wall: 3D distance only, no ground or up vector.
		local tr = G.newTrail()
		local pad = v(10, 300, 0)
		run(tr, v(12, 0, 0), v(0, 1, 0), 120, 0, 3)
		h.ok((verdict(tr, pad, v(12, 360, 0), 3, 0.05, nil, G.TRIGGER.padRadius)))
		-- Across a ceiling (y constant, moving -X), ring hanging 6 studs below the path.
		local tr2 = G.newTrail()
		run(tr2, v(400, 900, 50), v(-1, 0, 0), 165, 0, 2)
		h.ok((verdict(tr2, v(200, 894, 50), nil, 2, 0.05)))
		-- Cubes v2 plane pad: PickupLift 20 widens the pad's radius (RaceManager adds it); 30 studs above the plate.
		local tr3 = G.newTrail()
		run(tr3, v(0, 30, 0), v(1, 0, 0), 165, 0, 1.5)
		h.ok((verdict(tr3, v(100, 0, 0), nil, 1.5, 0.05, nil, G.TRIGGER.padRadius + 20)))
	end)

	h.test("forged: a claim from across the map is refused (too_far)", function()
		local tr = G.newTrail()
		run(tr, v(0, 80, 0), v(1, 0, 0), 165, 0, 1.5)
		local ok, why = verdict(tr, v(2000, 80, 900), v(247, 80, 0), 1.5, 0.08)
		h.eq(ok, false)
		h.eq(why, "too_far")
		-- Sitting still on the grid 300 studs from the first ring: refused even at the worst ping.
		local still = G.newTrail()
		for i = 0, 60 do
			G.record(still, i / 60, v(0, 5, 0))
		end
		h.eq(select(2, verdict(still, v(300, 5, 0), v(0, 5, 0), 1, 5)), "too_far")
	end)

	h.test("forged: the same trigger again inside the cooldown is refused; after it, paid again", function()
		local tr = G.newTrail()
		run(tr, v(0, 80, 0), v(1, 0, 0), 30, 0, 1) -- loitering at the ring
		local ring = v(15, 80, 0)
		h.eq(select(2, verdict(tr, ring, nil, 1, 0.05, 0.5)), "cooldown")
		h.eq(select(2, verdict(tr, ring, nil, 1, 0.05, 1 - G.TRIGGER.cooldown + 0.01)), "cooldown")
		h.ok((verdict(tr, ring, nil, 1, 0.05, 1 - G.TRIGGER.cooldown - 0.01)))
		h.ok(G.TRIGGER.cooldown < 1.2, "under the clients' 1.2 s so network bunching never refuses an honest repeat")
	end)

	h.test("forged: a respawn or teleport jump is not a segment (a ring between the two spots is not passed)", function()
		local tr = G.newTrail()
		for i = 0, 10 do
			G.record(tr, i * 0.05, v(0, 50, 0))
		end
		for i = 11, 20 do
			G.record(tr, i * 0.05, v(3000, 50, 0)) -- the respawn frame
		end
		h.eq(select(2, verdict(tr, v(1500, 50, 0), v(3000, 50, 0), 1, 0.05)), "too_far")
		-- The live position also never joins the last sample across a jump.
		local tr2 = G.newTrail()
		G.record(tr2, 0, v(0, 0, 0))
		h.eq(select(2, verdict(tr2, v(1500, 0, 0), v(3000, 0, 0), 0.1, 0.05)), "too_far")
	end)

	h.test("unknown trigger and no history are refused; the history keeps ~1.6 s at 20 Hz", function()
		h.eq(select(2, G.triggerVerdict({ found = false, distance = 0, radius = 19, now = 1 })), "unknown_trigger")
		h.eq(select(2, G.triggerVerdict({ found = true, distance = nil, radius = 19, now = 1 })), "no_history")
		h.eq(G.nearest(G.newTrail(), v(0, 0, 0), nil, 0), math.huge)
		local tr = G.newTrail()
		run(tr, v(0, 0, 0), v(1, 0, 0), 100, 0, 10)
		local n = #tr.samples
		h.ok(n <= math.ceil(G.TRAIL.keep / G.TRAIL.sampleGap) + 2 and n >= 20, "bounded: " .. n)
		h.ok(10 - tr.samples[1].t <= G.TRAIL.keep + 1e-6)
		G.clear(tr)
		h.eq(#tr.samples, 0)
	end)

	---------------------------------------------------------------------------------------------- wiring (static)

	h.test("RaceManager: ring / pad claims pass triggerClaimOk before any payout; remote rate limited and typed", function()
		local rm = h.readFile("src/server/RaceManager.luau")
		local claim = string.find(rm, "if not triggerClaimOk(player, rec, eventType, payload) then", 1, true)
		local pay = string.find(rm, "S().ringCounts[player] = math.min(", 1, true)
		h.ok(claim and pay and claim < pay, "the check comes before the ring count / speed / BoostState")
		h.contains(rm, 'if type(eventType) ~= "string" or not raceEventLimiter.allow(player, os.clock()) then')
		h.contains(rm, "sampleGuardTrails()")
		h.contains(rm, "RemoteGuardRules.triggerVerdict({")
		h.contains(rm, "raceEventLimiter.forget(player)")
		-- Adhesion, climbing, barriers, kill volumes and rescue are not touched by this check (owner rule).
		h.ok(not string.find(rm, "RemoteGuardRules.*Adhesion"), "no adhesion coupling")
	end)

	h.test("FlightServer / CarServer: SyncTransform is finite-only, BoostState from the enum, both rate limited", function()
		local fs = h.readFile("src/server/FlightServer.luau")
		h.ok(not string.find(fs, 'SetAttribute("BoostState", payload.boostState)', 1, true), "no raw client string")
		h.contains(fs, "RemoteGuardRules.boostState(payload.boostState)")
		h.contains(fs, "RemoteGuardRules.num(payload.speed, 0, RemoteGuardRules.TRAIL.maxSpeed)")
		h.contains(fs, "flightLimiter.allow(player, os.clock())")
		local cs = h.readFile("src/server/CarServer.luau")
		for _, f in { "speed", "steer", "driftLevel", "trick", "gridHop" } do
			h.contains(cs, "RemoteGuardRules.num(payload." .. f, "car " .. f .. " finite-only")
		end
		h.contains(cs, "carLimiter.allow(player, os.clock())")
	end)

	h.test("ItemService / TrackDirector: ItemRemote and BattleIntroSeen are rate limited", function()
		h.contains(h.readFile("src/server/ItemService.luau"), "itemLimiter.allow(player, os.clock())")
		h.contains(h.readFile("src/server/TrackDirector.luau"), "introLimiter.allow(player, now)")
	end)
end
