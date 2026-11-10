--!strict
-- Lune spec for the Shared Curtain Kart (docs/REMARKABLE.md item 28) and the battle-only barriers (trap I2-05):
--   * src/shared/CurtainKartNet.luau   wire packing, server-side sanitising, rate gate, overtake hysteresis, ranking;
--   * src/server/CurtainKartRelay.luau samples -> CKPos / CKState / CKBest only while the curtain is up;
--   * src/server/battle/BattleBarriers.luau world placement of ISLAND-2's cavern-mouth barrier from the built
--     TrackData (build/island2/TrackData.luau, tools/map/adapt.py output).
-- Run: tools/tests/run_lune_tests.sh tools/tests/curtain_kart_net_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	fakePlayer: (number, string?) -> any,
}

return function(h: Harness)
	local Net = h.require("src/shared/CurtainKartNet.luau")
	local Sim = h.require("src/shared/CurtainKartSim.luau")
	local Tracks = h.require("src/shared/CurtainTracks.luau")

	h.test("state packs laps, lap fraction and the wheel flag losslessly enough to rank", function()
		local s = Net.packState(3, 0.5, true)
		local laps, frac, manual = Net.unpackState(s)
		h.eq(laps, 3)
		h.ok(math.abs(frac - 0.5) < 0.002, tostring(frac))
		h.eq(manual, true)
		local _, _, auto = Net.unpackState(Net.packState(0, 0.99, false))
		h.eq(auto, false)
		-- monotonic: further along the loop always ranks higher, across the line too
		h.ok(Net.progress(Net.packState(1, 0.02, false)) > Net.progress(Net.packState(0, 0.98, false)))
		h.ok(Net.progress(Net.packState(2, 0.4, true)) > Net.progress(Net.packState(2, 0.3, false)))
		-- clamped, never out of the sanitiser's range
		h.ok(Net.packState(500, 2, true) <= Net.STATE_MAX)
		h.ok(Net.packState(-3, -1, false) >= 0)
	end)

	h.test("sanitize keeps sane samples, wraps the heading, and drops garbage", function()
		local v, s, b = Net.sanitize(Vector3.new(0.4, 0.3, 7), Net.packState(1, 0.2, true), 6.43)
		h.ok(v ~= nil and s ~= nil)
		h.ok(math.abs((v :: any).Z - (7 - 2 * math.pi)) < 1e-6, "heading wrapped to -pi..pi")
		h.eq(b, 6.4)
		local bad = {
			{ "x", 1, nil },
			{ Vector3.new(0 / 0, 0.2, 0), 1, nil },
			{ Vector3.new(0.2, math.huge, 0), 1, nil },
			{ Vector3.new(3, 0.2, 0), 1, nil },
			{ Vector3.new(0.2, -1, 0), 1, nil },
			{ Vector3.new(0.2, 0.2, 0), -1, nil },
			{ Vector3.new(0.2, 0.2, 0), 1.5, nil },
			{ Vector3.new(0.2, 0.2, 0), Net.STATE_MAX + 1, nil },
			{ Vector3.new(0.2, 0.2, 0), "3", nil },
		}
		for i, c in bad do
			local bv = Net.sanitize(c[1], c[2], c[3])
			h.eq(bv, nil, "case " .. i)
		end
		-- an impossible or malformed best is dropped on its own; the position still goes through
		local v2, _, b2 = Net.sanitize(Vector3.new(0.5, 0.5, 0), 0, 0.2)
		h.ok(v2 ~= nil)
		h.eq(b2, nil)
		local _, _, b3 = Net.sanitize(Vector3.new(0.5, 0.5, 0), 0, 0 / 0)
		h.eq(b3, nil)
	end)

	h.test("rate gate admits 5 Hz and refuses a flood", function()
		h.ok(Net.accept(nil, 10))
		h.ok(Net.accept(10, 10.2))
		h.ok(not Net.accept(10, 10.05))
		h.ok(Net.MIN_GAP < 1 / Net.SEND_HZ, "the gate must not drop an honest 5 Hz sender")
	end)

	h.test("overtakes flip only past the gap: no flicker side by side, one event per pass", function()
		local side, ev = Net.overtake(0, 1.0, 0.9)
		h.eq({ side, ev }, { 1, 0 }, "first sighting sets the side without an event")
		side, ev = Net.overtake(side, 1.0, 1.005)
		h.eq({ side, ev }, { 1, 0 }, "inside the gap: still ahead")
		side, ev = Net.overtake(side, 1.0, 1.02)
		h.eq({ side, ev }, { -1, -1 }, "they passed me")
		side, ev = Net.overtake(side, 1.0, 1.03)
		h.eq({ side, ev }, { -1, 0 }, "no repeat")
		side, ev = Net.overtake(side, 1.1, 1.03)
		h.eq({ side, ev }, { 1, 1 }, "I passed them back")
		-- a pass across the start line counts too (laps carry the order)
		local s1 = Net.progress(Net.packState(2, 0.01, true))
		local s2 = Net.progress(Net.packState(1, 0.99, true))
		local _, e2 = Net.overtake(-1, s1, s2)
		h.eq(e2, 1)
	end)

	h.test("position counts rivals ahead; ties go to me", function()
		local r = { 1.2, 0.8, 1.5, 0 }
		h.eq(Net.position(1.0, r, 3), 3)
		h.eq(Net.position(2.0, r, 3), 1)
		h.eq(Net.position(0.8, { 0.8 }, 1), 1)
		h.eq(Net.position(0.5, r, 0), 1, "alone")
	end)

	h.test("angle lerp takes the short way round", function()
		local a = Net.lerpAngle(math.rad(170), math.rad(-170), 0.5)
		h.ok(math.abs(math.abs((a + math.pi) % (2 * math.pi) - math.pi) - math.pi) < 1e-6, tostring(a))
		h.ok(math.abs(Net.lerpAngle(0, 1, 0.25) - 0.25) < 1e-9)
	end)

	h.test("a real curtain lap stays inside the sanitiser's box and state range", function()
		for id, data in Tracks do
			local tr = Sim.prepare(data.points, data.w, data.h)
			local k = Sim.newKart(tr, data.startIndex or 1)
			for _ = 1, 60 * 30 do
				Sim.step(tr, k, 1 / 60, Sim.autoSteer(tr, k))
				local v = Net.sanitize(Vector3.new(k.x, k.y, k.heading), Net.packState(k.laps, k.station / tr.total, false), k.best)
				if not v then
					error(string.format("%s: sample (%.3f, %.3f, %.2f) laps %d refused", id, k.x, k.y, k.heading, k.laps))
				end
			end
			h.ok(k.laps >= 3, id .. " autopilot laps in 30 s")
			h.ok(k.best == nil or (k.best :: number) >= Net.BEST_MIN, id .. " best above BEST_MIN")
		end
	end)

	h.test("relay publishes only during the curtain, rate-limited, best only improving", function()
		local Relay = h.require("src/server/CurtainKartRelay.luau")
		local p = h.fakePlayer(7, "Racer")
		h.eq(Relay.receive(p, Vector3.new(0.3, 0.3, 0), 0, nil, false, 100), false, "no curtain, no publish")
		h.eq(p:GetAttribute("CKPos"), nil)
		h.eq(Relay.receive(p, Vector3.new(0.3, 0.3, 0), Net.packState(0, 0.1, true), 7.25, true, 100), true)
		h.eq(p:GetAttribute("CKPos"), Vector3.new(0.3, 0.3, 0))
		h.eq(p:GetAttribute("CKBest"), 7.3)
		h.eq(Relay.receive(p, Vector3.new(0.31, 0.3, 0), 0, nil, true, 100.05), false, "too soon")
		h.eq(Relay.receive(p, "teleport", 0, nil, true, 100.3), false, "garbage")
		h.eq(Relay.receive(p, Vector3.new(0.32, 0.3, 0), 0, 9.0, true, 100.4), true)
		h.eq(p:GetAttribute("CKBest"), 7.3, "a slower best never replaces a faster one")
		h.eq(Relay.receive(p, Vector3.new(0.33, 0.3, 0), 0, 6.1, true, 100.6), true)
		h.eq(p:GetAttribute("CKBest"), 6.1)
		Relay.forget(p)
		h.eq(Relay.receive(p, Vector3.new(0.34, 0.3, 0), 0, nil, true, 100.61), true, "a leaver's gate is forgotten")
	end)

	h.test("ISLAND-2 cavern-mouth barrier: placed across the road at the mouth, from the built TrackData", function()
		local BB = h.require("src/server/battle/BattleBarriers.luau")
		local td = h.require("build/island2/TrackData.luau")
		local battle = td.modes.battle
		local plans = BB.plan(battle)
		h.eq(#plans, 1)
		local b = plans[1]
		h.eq(b.name, "CavernMouthBarrier")
		h.ok(b.colliderCf ~= nil and b.colliderSize ~= nil, "collider")
		local cpos = (b.colliderCf :: CFrame).Position
		local centre: Vector3 = battle.center
		local flat = Vector3.new(cpos.X - centre.X, 0, cpos.Z - centre.Z).Magnitude
		-- inside the return radius (never a teleport line). Since the arena covers the whole cove (owner 2026-10-21) the
		-- wall stands inside the play radius: it closes the cavern road, the arena's one way under the headland.
		h.ok(flat < battle.radius + battle.softBoundary.softWidth, tostring(flat))
		-- the wall faces the arena: its +Z (toward the arena) points back toward the centre
		local back = (b.cf :: CFrame).LookVector * -1
		local toCentre = Vector3.new(centre.X - cpos.X, 0, centre.Z - cpos.Z).Unit
		h.ok(back:Dot(toCentre) > 0.5, "barrier faces the arena")
		h.ok((b.colliderSize :: Vector3).X >= 67, "jamb to jamb")
		h.ok(#b.parts >= 10 and #b.parts <= BB.MAX_PARTS, "dressed")
		h.ok(#b.signs >= 1 and b.snore ~= nil, "sign and kraken")
		-- every sign points at a real part
		for _, s in b.signs do
			h.ok(b.parts[s.part] ~= nil, "sign part " .. tostring(s.part))
		end
		-- a battle block without barriers builds nothing
		h.eq(#BB.plan({ kind = "survival" }), 0)
		h.eq(#BB.plan(nil), 0)
	end)

	h.test("barrier rows: Euler order matches the map builder (YXZ degrees)", function()
		local BB = h.require("src/server/battle/BattleBarriers.luau")
		local cf = BB.rowCFrame({ "B", 1, 2, 3, 1, 1, 1, 0, 90, 0, "#ffffff", "Wood" })
		h.ok((cf.Position - Vector3.new(1, 2, 3)).Magnitude < 1e-6)
		-- yaw 90: local +X turns to world -Z
		h.ok((cf.RightVector - Vector3.new(0, 0, -1)).Magnitude < 1e-6, tostring(cf.RightVector))
	end)
end
