--!strict
-- Lune spec for the FOREST hoard rules (LAUNCH_PROGRESSION 2b; TEST_LIST_LAUNCH L74): src/shared/battle/HoardRules over
-- the REAL FOREST-1 TrackData (anchors, home rings, rules) and small hand-made fields:
--   1. setup: config from the plan, ring axes from the plan yaw, seat i -> ring i (pad i beside ring i), pod spots.
--   2. play: sweep pickups, the carry cap, regrowth, banking through the own ring only (disc, core, teleports), hit drops
--      (half rounded up), dropped acorns (fall, takeable by anyone once landed, rot), leaving.
--   3. results: first to 20, the cap ranking and its tie rule, texts.
--   4. bot helpers: when to fly home, turning-circle test, ring approach point, acorn choice.
-- The server mode end to end (real BattleCore, bots, visuals) is tools/tests/hoard_flow_spec.luau.
-- Run: tools/tests/run_lune_tests.sh tools/tests/hoard_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
}

return function(h: Harness)
	local HoardRules = h.require("src/shared/battle/HoardRules.luau")
	local BattleRules = h.require("src/shared/battle/BattleRules.luau")
	local forest = h.require("build/forest1/TrackData.luau")
	local battle = forest.modes.battle

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	local function forestRings(): { any }
		local out = {}
		for i, r in battle.homeRings do
			table.insert(out, HoardRules.ringFromPlan(r, i))
		end
		return out
	end

	local function seats(): { any }
		return {
			{ id = "player:1", isPlayer = true, slot = 2 },
			{ id = "bot:101", isPlayer = false, slot = 1 },
			{ id = "bot:102", isPlayer = false, slot = 3 },
			{ id = "bot:103", isPlayer = false, slot = 4 },
		}
	end

	-- A flat test field: ring 1 at the origin facing -Z, ring 2 far east; two anchors on the X axis.
	local function field(anchors: { Vector3 }?, cfg: any?): any
		local rings = {
			{ name = "R1", pos = Vector3.new(0, 50, 0), axis = Vector3.new(0, 0, -1), radius = 14 },
			{ name = "R2", pos = Vector3.new(500, 50, 0), axis = Vector3.new(0, 0, -1), radius = 14 },
		}
		return HoardRules.new({
			{ id = "a", isPlayer = true, slot = 1 },
			{ id = "b", isPlayer = false, slot = 2 },
		}, anchors or { Vector3.new(100, 50, 0), Vector3.new(130, 50, 0) }, rings, cfg or HoardRules.config(battle.rules))
	end

	---------------------------------------------------------------- 1. setup

	h.test("config: FOREST-1 rules (carry 10, win 20, half on a hit) and OURS defaults", function()
		local cfg = HoardRules.config(battle.rules)
		h.eq(cfg.carryMax, 10)
		h.eq(cfg.depositToWin, 20)
		h.eq(cfg.hitDropFraction, 0.5)
		h.eq(cfg.respawn, HoardRules.DEFAULTS.respawn)
		h.eq(battle.kind, "hoard")
		h.eq(battle.vehicle, "plane")
		local d = HoardRules.config(nil)
		h.eq(d.carryMax, 10)
		h.eq(HoardRules.config({ carryMax = 0, depositToWin = -3, hitDropFraction = 4 }).carryMax, 10, "nonsense falls back")
		h.eq(HoardRules.config({ hitDropFraction = 4 }).hitDropFraction, 1, "clamped")
		h.eq(HoardRules.config({ acornRespawn = 4 }).respawn, 4)
	end)

	h.test("rings: plan yaw gives the fly-through axis; seat i flies home through ring i (pad i beside it)", function()
		local rings = forestRings()
		h.eq(#rings, 4)
		local arena = BattleRules.arena(battle)
		for i, ring in rings do
			h.eq(ring.radius, 14)
			h.ok(near(ring.axis.Magnitude, 1, 1e-9) and ring.axis.Y == 0, "unit horizontal axis")
			local yaw = math.rad(battle.homeRings[i].yaw)
			local look = CFrame.Angles(0, yaw, 0).LookVector
			h.ok((look - ring.axis).Magnitude < 1e-6, "axis = CFrame.Angles(0, yaw, 0).LookVector")
			-- The plan puts pad i 40 studs from ring i toward the yard: ring i is the nearest ring to pad i.
			local best, bestD = 0, math.huge
			for j, other in rings do
				local d = BattleRules.horizontal(other.pos, arena.spawns[i])
				if d < bestD then
					best, bestD = j, d
				end
			end
			h.eq(best, i, "pad " .. i .. " sits beside ring " .. i)
			h.ok(bestD < 45, "pad within 45 studs of its ring")
			-- The fly-through is radial: the natural line home from the field (the yard) meets the disc square, and
			-- flying on carries you past the windmill instead of into it (docs/audits/traps_forest1.md F1).
			local toCentre = Vector3.new(arena.center.X - ring.pos.X, 0, arena.center.Z - ring.pos.Z).Unit
			h.ok(math.abs(toCentre:Dot(ring.axis)) > 0.99, "axis along the line from the yard")
		end
		h.eq(HoardRules.ringFor(1, 4), 1)
		h.eq(HoardRules.ringFor(4, 4), 4)
		h.eq(HoardRules.ringFor(5, 4), 1, "extra seats share rings in turn")
		h.eq(HoardRules.ringFor(0, 4), 1)
		h.eq(HoardRules.ringFromPlan({ name = "x" }, 1), nil, "no position: no ring")
		local st = HoardRules.new(seats(), {}, rings, HoardRules.config(battle.rules))
		h.eq(st.entries["player:1"].ring, 2)
		h.eq(st.entries["bot:103"].ring, 4)
	end)

	h.test("anchors: all 18 FOREST-1 acorns ready at GO; pods ride every third anchor under the ceiling", function()
		local st = HoardRules.new(seats(), battle.pickupAnchors, forestRings(), HoardRules.config(battle.rules))
		h.eq(#st.acorns, 18)
		for i, a in st.acorns do
			h.eq(a.state, "ready")
			h.eq(a.anchor, i)
			h.eq(a.id, i)
		end
		local arena = BattleRules.arena(battle)
		local pods = HoardRules.podSpots(battle.pickupAnchors, 3, 22, arena.ceiling)
		h.eq(#pods, 6)
		h.eq(pods[1], battle.pickupAnchors[3] + Vector3.new(0, 22, 0))
		for _, p in pods do
			h.ok(p.Y <= arena.ceiling - 12, "under the ceiling")
			h.ok(BattleRules.horizontal(p, arena.center) <= arena.radius, "inside the play radius")
		end
		local capped = HoardRules.podSpots({ Vector3.new(0, 95, 0) }, 1, 22, 100)
		h.eq(capped[1].Y, 88, "clamped under ceiling - margin")
	end)

	---------------------------------------------------------------- 2. play

	h.test("pickup: passing within 14 studs takes it; the path between checks counts; a teleport does not sweep", function()
		local st = field()
		h.eq(#HoardRules.collect(st, "a", nil, Vector3.new(100, 50, 20), 1), 0, "20 studs off")
		local got = HoardRules.collect(st, "a", nil, Vector3.new(100, 50, 10), 1)
		h.eq(#got, 1)
		h.eq(got[1].id, 1)
		h.eq(st.entries.a.carried, 1)
		h.eq(st.acorns[1].state, "growing")
		h.eq(st.acorns[1].readyAt, 1 + st.cfg.respawn)
		-- Fast pass: both checks 40 studs either side of acorn 2, the path between them runs through it.
		local swept = HoardRules.collect(st, "b", Vector3.new(130, 50, -40), Vector3.new(130, 52, 40), 2)
		h.eq(#swept, 1, "swept")
		-- A respawn teleport (path longer than maxStep) only checks where it lands.
		local st2 = field()
		h.eq(#HoardRules.collect(st2, "a", Vector3.new(100, 50, -200), Vector3.new(100, 50, 200), 1), 0, "teleport")
	end)

	h.test("carry cap: 10 at most, a full sack leaves acorns hanging; anchors regrow on their timer", function()
		local anchors = {}
		for i = 1, 12 do
			table.insert(anchors, Vector3.new(i * 5, 50, 0))
		end
		local st = field(anchors)
		local got = HoardRules.collect(st, "a", Vector3.new(0, 50, 0), Vector3.new(65, 50, 0), 3)
		h.eq(#got, 10, "stops at the cap")
		h.eq(st.entries.a.carried, 10)
		h.eq(#HoardRules.collect(st, "a", Vector3.new(0, 50, 0), Vector3.new(65, 50, 0), 4), 0, "full: takes nothing")
		local left = 0
		for _, a in st.acorns do
			if a.state == "ready" then
				left += 1
			end
		end
		h.eq(left, 2, "two still hang there for someone else")
		h.eq(#HoardRules.tick(st, 3 + st.cfg.respawn - 0.1), 0, "not yet")
		local ev = HoardRules.tick(st, 3 + st.cfg.respawn)
		h.eq(#ev, 10, "ten regrow")
		h.eq(ev[1].kind, "ready")
		h.eq(#st.acorns, 12, "anchors are never removed")
	end)

	h.test("bank: through the own ring's disc banks the sack; outside the rim, a foreign ring or empty does nothing", function()
		local st = field()
		st.entries.a.carried = 7
		-- Square pass, 10 studs off centre (inside radius 14).
		h.eq(HoardRules.deposit(st, "a", Vector3.new(10, 50, 20), Vector3.new(10, 50, -20), 30), 7)
		h.eq(st.entries.a.deposited, 7)
		h.eq(st.entries.a.carried, 0)
		h.eq(st.entries.a.reachedAt, 30)
		h.eq(HoardRules.deposit(st, "a", Vector3.new(0, 50, 20), Vector3.new(0, 50, -20), 31), 0, "empty sack")
		st.entries.a.carried = 3
		h.eq(HoardRules.deposit(st, "a", Vector3.new(25, 50, 20), Vector3.new(25, 50, -20), 32), 0, "outside the rim + slack")
		h.eq(HoardRules.deposit(st, "a", Vector3.new(17, 50, 20), Vector3.new(17, 50, -20), 32), 3, "on the rim (radius + slack)")
		-- Edge-on through the middle (along the disc) counts through the core.
		st.entries.a.carried = 2
		h.eq(HoardRules.deposit(st, "a", Vector3.new(-30, 50, 0), Vector3.new(30, 50, 0), 33), 2, "edge-on through the centre")
		-- b's ring is R2: flying through R1 banks nothing for b, and foreignRing reports it.
		st.entries.b.carried = 4
		h.eq(HoardRules.deposit(st, "b", Vector3.new(0, 50, 20), Vector3.new(0, 50, -20), 34), 0, "not b's ring")
		h.eq(HoardRules.foreignRing(st, "b", Vector3.new(0, 50, 20), Vector3.new(0, 50, -20)), 1)
		h.eq(HoardRules.foreignRing(st, "a", Vector3.new(0, 50, 20), Vector3.new(0, 50, -20)), nil, "own ring is not foreign")
		h.eq(HoardRules.deposit(st, "b", Vector3.new(500, 50, 20), Vector3.new(500, 50, -20), 35), 4, "b banks at R2")
		-- A teleport across the disc is not a pass.
		st.entries.a.carried = 1
		h.eq(HoardRules.deposit(st, "a", Vector3.new(5, 50, 300), Vector3.new(5, 50, -300), 36), 0, "teleport")
		-- Both senses of the axis count.
		h.eq(HoardRules.deposit(st, "a", Vector3.new(0, 55, -20), Vector3.new(0, 55, 20), 37), 1, "reverse pass")
	end)

	h.test("motion: flight sweeps from the last check; a crash respawn (still, then a jump) sweeps nothing", function()
		local cfg = HoardRules.config(battle.rules)
		local m = HoardRules.newMotion()
		local dt = 1 / 60
		h.eq(HoardRules.advance(cfg, m, Vector3.new(0, 50, 0), 10), nil, "first check: only where it is")
		h.eq(HoardRules.advance(cfg, m, Vector3.new(0, 50, -2), 10 + dt), Vector3.new(0, 50, 0), "flying: the path counts")
		-- A remote hull seen in bursts: a few frozen frames, then the catch-up step is still flight.
		h.eq(HoardRules.advance(cfg, m, Vector3.new(0, 50, -2), 10 + 2 * dt), Vector3.new(0, 50, -2), "held frame")
		h.eq(HoardRules.advance(cfg, m, Vector3.new(0, 50, -2), 10 + 3 * dt), Vector3.new(0, 50, -2), "held frame")
		h.eq(HoardRules.advance(cfg, m, Vector3.new(0, 50, -10), 10 + 4 * dt), Vector3.new(0, 50, -2), "burst after a short hold")
		-- Stunned but flying (40 studs/s) is moving.
		h.eq(HoardRules.advance(cfg, m, Vector3.new(0, 50, -10 - 40 * dt), 10 + 5 * dt), Vector3.new(0, 50, -10), "slow flight")
		-- The FOREST-1 crash: a wreck on ring 2's run-out (just past the ring, away from the yard) tumbles in place (a
		-- slow sink) for RESPAWN_DELAY, then the plane appears on pad 2, on the ring's axis toward the yard, across the
		-- ring: a jump well under maxStep that the path test would read as a pass.
		local ring = forestRings()[2]
		local arena = BattleRules.arena(battle)
		local out = Vector3.new(ring.pos.X - arena.center.X, 0, ring.pos.Z - arena.center.Z).Unit
		local wreck = ring.pos + out * 35
		local pad = battle.spawns[2]
		h.ok((pad - wreck).Magnitude < cfg.maxStep, "the jump is shorter than maxStep")
		h.ok(HoardRules.ringPass(cfg, ring, wreck, pad), "and the path test alone reads it as a pass")
		local t = 20
		local m2 = HoardRules.newMotion()
		HoardRules.advance(cfg, m2, wreck + out * 30, t)
		h.eq(HoardRules.advance(cfg, m2, wreck, t + 0.2), wreck + out * 30, "flying in")
		local p = wreck
		for k = 1, 60 do
			p -= Vector3.new(0, 0.05, 0)
			HoardRules.advance(cfg, m2, p, t + 0.2 + k * dt)
		end
		h.eq(HoardRules.advance(cfg, m2, pad, t + 1.2 + dt), nil, "the respawn jump sweeps nothing")
		h.eq(HoardRules.advance(cfg, m2, pad + Vector3.new(0, 0, -2), t + 1.2 + 2 * dt), pad, "flying again from the pad")
		-- A short stop (under stillFor) still sweeps the next step.
		local m3 = HoardRules.newMotion()
		HoardRules.advance(cfg, m3, Vector3.new(0, 0, 0), 0)
		HoardRules.advance(cfg, m3, Vector3.new(0, 0, 0), cfg.stillFor * 0.5)
		h.eq(HoardRules.advance(cfg, m3, Vector3.new(0, 0, 10), cfg.stillFor * 0.5 + dt), Vector3.new(0, 0, 0), "short hold")
	end)

	h.test("ring pass geometry on a FOREST-1 ring: square through the centre yes, past the rim no", function()
		local cfg = HoardRules.config(battle.rules)
		local ring = forestRings()[1]
		local a, b = ring.pos + ring.axis * 30, ring.pos - ring.axis * 30
		h.ok(HoardRules.ringPass(cfg, ring, a, b), "through the centre")
		local side = ring.axis:Cross(Vector3.new(0, 1, 0)).Unit
		h.ok(HoardRules.ringPass(cfg, ring, a + side * 12, b + side * 12), "12 off centre")
		h.ok(not HoardRules.ringPass(cfg, ring, a + side * 30, b + side * 30), "30 off: past the ring")
		h.ok(not HoardRules.ringPass(cfg, ring, a, ring.pos + ring.axis * 20), "stopped short")
		h.ok(HoardRules.ringPass(cfg, ring, nil, ring.pos + side * 3), "first check inside the ring")
	end)

	h.test("hit: drops half of the sack rounded up, credits the attacker; an empty sack drops nothing", function()
		local expect = { [0] = 0, [1] = 1, [2] = 1, [3] = 2, [7] = 4, [10] = 5 }
		for carried, drop in expect do
			h.eq(HoardRules.dropCount(carried, 0.5), drop, "carry " .. carried)
		end
		h.eq(HoardRules.dropCount(5, 0), 0)
		h.eq(HoardRules.dropCount(5, 1), 5)
		local st = field()
		st.entries.a.carried = 7
		h.eq(HoardRules.hit(st, "a", "b", 10), 4)
		h.eq(st.entries.a.carried, 3)
		h.eq(st.entries.a.dropped, 4)
		h.eq(st.entries.b.hitsLanded, 1)
		h.eq(HoardRules.hit(st, "b", nil, 11), 0, "empty sack, no attacker")
		h.eq(HoardRules.hit(st, "a", "a", 12), 2, "a self-hit (own trap) still drops")
		h.eq(st.entries.a.hitsLanded, 0, "but credits nobody")
		h.eq(HoardRules.hit(st, "nobody", "b", 13), 0)
	end)

	h.test("dropped acorns: fall first, then anyone takes them (reach above the grass), and they rot", function()
		local st = field({})
		local spots = HoardRules.scatter(Vector3.new(0, 10, 0), 4, 14)
		h.eq(#spots, 4)
		for i, p in spots do
			h.ok(BattleRules.horizontal(p, Vector3.new(0, 10, 0)) <= 14 + 1e-6, "within the spread")
			for j = i + 1, #spots do
				h.ok((p - spots[j]).Magnitude > 3, "distinct spots")
			end
		end
		h.eq(HoardRules.scatter(Vector3.new(0, 10, 0), 4, 14), spots, "deterministic")
		-- Four acorns knocked loose at t=20 that land 1.2 s later, well apart, and one far off landing at once.
		local landing = { Vector3.new(0, 10, 0), Vector3.new(100, 10, 0), Vector3.new(200, 10, 0), Vector3.new(300, 10, 0) }
		local loose = HoardRules.addLoose(st, landing, 20, 1.2)
		h.eq(#loose, 4)
		h.eq(loose[1].id, HoardRules.LOOSE_ID_BASE + 1)
		h.eq(loose[1].state, "falling")
		h.eq(loose[1].readyAt, 21.2)
		h.eq(HoardRules.addLoose(st, { Vector3.new(300, 0, 300) }, 20, 0.1)[1].readyAt, 20 + st.cfg.dropDelay, "never before dropDelay")
		h.eq(#HoardRules.collect(st, "b", nil, landing[1], 21), 0, "still falling")
		h.eq(#HoardRules.tick(st, 20.9), 1, "the far one has landed")
		h.eq(#HoardRules.tick(st, 21.2), 4, "the four have landed")
		-- b skims 10 studs over the grass right above the first one: taken (reach above a landed acorn).
		local got = HoardRules.collect(st, "b", nil, landing[1] + Vector3.new(0, 10, 0), 21.3)
		h.eq(#got, 1)
		h.eq(st.entries.b.carried, 1)
		h.eq(HoardRules.find(st, got[1].id), nil, "a taken dropped acorn is gone (it does not regrow)")
		h.eq(#HoardRules.collect(st, "a", nil, landing[2] + Vector3.new(0, 25, 0), 21.3), 0, "25 studs up is too high")
		-- The rest rot at dropLifetime.
		local rot = HoardRules.tick(st, 20 + st.cfg.dropLifetime)
		local expired = 0
		for _, e in rot do
			if e.kind == "expired" then
				expired += 1
			end
		end
		h.eq(expired, 4, "three left from the hit plus the far one")
		h.eq(#st.acorns, 0)
	end)

	h.test("leave: the sack drops, the leaver is out and ranks last; out entrants take and bank nothing", function()
		local st = field()
		st.entries.a.deposited = 15
		st.entries.a.carried = 6
		h.eq(HoardRules.leave(st, "a", 40), 6)
		h.eq(HoardRules.leave(st, "a", 41), 0, "once")
		h.eq(st.entries.a.out, true)
		h.eq(#HoardRules.collect(st, "a", nil, Vector3.new(100, 50, 0), 42), 0)
		st.entries.a.carried = 2
		h.eq(HoardRules.deposit(st, "a", Vector3.new(0, 50, 20), Vector3.new(0, 50, -20), 43), 0)
		h.eq(HoardRules.ranking(st), { "b", "a" }, "b (0 banked) above the leaver (15)")
		h.eq(HoardRules.scoreText(st, "a"), "LEFT")
		h.eq(HoardRules.boardScore(st, "a"), -1)
		h.eq((HoardRules.resolveCap(st)), nil, "b banked nothing: no winner")
	end)

	---------------------------------------------------------------- 3. results

	h.test("win: first to 20 banked; the winner tops the ranking", function()
		local st = HoardRules.new(seats(), {}, forestRings(), HoardRules.config(battle.rules))
		local ring = st.rings[2]
		st.entries["player:1"].deposited = 12
		st.entries["player:1"].carried = 7
		st.entries["bot:101"].deposited = 18
		HoardRules.deposit(st, "player:1", ring.pos + ring.axis * 20, ring.pos - ring.axis * 20, 90)
		h.eq(HoardRules.winner(st), nil, "19: not yet")
		st.entries["player:1"].carried = 1
		HoardRules.deposit(st, "player:1", ring.pos - ring.axis * 20, ring.pos + ring.axis * 20, 95)
		h.eq(st.entries["player:1"].deposited, 20)
		h.eq(HoardRules.winner(st), "player:1")
		h.eq(HoardRules.ranking(st)[1], "player:1")
		h.eq(HoardRules.ranking(st)[2], "bot:101")
	end)

	h.test("cap: most banked; ties go to who reached the total first, then carried, hits, player, slot", function()
		local st = HoardRules.new(seats(), {}, forestRings(), HoardRules.config(battle.rules))
		local e = st.entries
		e["player:1"].deposited, e["player:1"].reachedAt = 9, 120
		e["bot:101"].deposited, e["bot:101"].reachedAt = 9, 80
		e["bot:102"].deposited, e["bot:102"].reachedAt = 12, 150
		e["bot:103"].deposited = 0
		e["player:1"].carried = 4 -- carried only breaks a tie on the same moment
		local winner, ranking = HoardRules.resolveCap(st)
		h.eq(winner, "bot:102")
		h.eq(ranking, { "bot:102", "bot:101", "player:1", "bot:103" }, "bot:101 reached 9 first")
		-- The live board orders by boardScore: exactly the cap's order (no "9 +4" above the "9" that wins the tie).
		local board = table.clone(st.ids)
		table.sort(board, function(x: string, y: string): boolean
			return HoardRules.boardScore(st, x, ranking) > HoardRules.boardScore(st, y, ranking)
		end)
		h.eq(board, ranking, "board order = cap order")
		-- Same total at the same moment: more carried, then hits landed, then the player, then the lower slot.
		local t = HoardRules.new(seats(), {}, forestRings(), HoardRules.config(battle.rules))
		for _, id in t.ids do
			t.entries[id].deposited = 5
			t.entries[id].reachedAt = 60
		end
		t.entries["bot:103"].carried = 2
		t.entries["bot:102"].hitsLanded = 1
		h.eq(HoardRules.ranking(t), { "bot:103", "bot:102", "player:1", "bot:101" })
		-- Nobody banked: no winner, ranking by carried.
		local z = HoardRules.new(seats(), {}, forestRings(), HoardRules.config(battle.rules))
		z.entries["bot:101"].carried = 3
		local w, r = HoardRules.resolveCap(z)
		h.eq(w, nil)
		h.eq(r[1], "bot:101")
	end)

	h.test("texts: board '12 +4', results '12 BANKED', objective line names the ring and the next step", function()
		local longest = 0
		local st = field()
		local a = st.entries.a
		h.eq(HoardRules.scoreText(st, "a"), "0")
		h.eq(HoardRules.hudText(st, "a", "BLUE"), "GRAB ACORNS  -  YOUR HOME: BLUE RING")
		a.deposited, a.carried = 12, 4
		h.eq(HoardRules.scoreText(st, "a"), "12 +4")
		h.eq(HoardRules.boardScore(st, "a"), 1, "a leads b (2 entrants): one above the last")
		h.eq(HoardRules.boardScore(st, "b"), 0)
		h.eq(HoardRules.hudText(st, "a", "BLUE"), "BANKED 12/20 - CARRY 4/10 - BLUE RING")
		a.carried = 10
		h.eq(HoardRules.hudText(st, "a", "BLUE"), "SACK FULL - FLY THROUGH THE BLUE RING")
		a.carried = 0
		h.eq(HoardRules.hudText(st, "a", "BLUE"), "BANKED 12/20  -  GRAB ACORNS")
		h.eq(HoardRules.resultText(st, "a"), "12 BANKED")
		for _, carried in { 0, 4, 10 } do
			for _, banked in { 0, 19 } do
				a.carried, a.deposited = carried, banked
				longest = math.max(longest, #HoardRules.hudText(st, "a", "PURPLE"))
			end
		end
		h.ok(longest <= 40, "objective lines fit the plank (" .. longest .. " chars)")
		a.carried, a.deposited = 0, 12
		HoardRules.leave(st, "a", 1)
		h.eq(HoardRules.resultText(st, "a"), "LEFT (12 banked)")
		h.eq(HoardRules.hudText(st, "a", "BLUE"), "OUT - spectating")
	end)

	---------------------------------------------------------------- 4. bot helpers

	h.test("bots fly home: full, winning, clock, nothing left, far acorns, passing home; otherwise collect", function()
		local cfg = HoardRules.config(battle.rules)
		local function e(carried: number, deposited: number): any
			return { carried = carried, deposited = deposited }
		end
		local base = { nearestAcorn = 50, homeDist = 200, timeLeft = 120, speed = 100 }
		local function sense(over: any): any
			local s = table.clone(base)
			for k, v in over do
				s[k] = v
			end
			return s
		end
		h.eq({ HoardRules.botWantsHome(e(0, 0), cfg, base) }, { false, "empty" })
		h.eq({ HoardRules.botWantsHome(e(10, 0), cfg, base) }, { true, "full" })
		h.eq({ HoardRules.botWantsHome(e(3, 17), cfg, base) }, { true, "winning" })
		h.eq({ HoardRules.botWantsHome(e(2, 0), cfg, sense({ timeLeft = 7 })) }, { true, "clock" })
		local none = sense({})
		none.nearestAcorn = nil
		h.eq({ HoardRules.botWantsHome(e(1, 0), cfg, none) }, { true, "none left" })
		h.eq({ HoardRules.botWantsHome(e(6, 0), cfg, sense({ nearestAcorn = 150 })) }, { true, "far" })
		h.eq({ HoardRules.botWantsHome(e(3, 0), cfg, sense({ homeDist = 50, nearestAcorn = 80 })) }, { true, "passing" })
		h.eq({ HoardRules.botWantsHome(e(5, 0), cfg, base) }, { false, "collect" })
	end)

	h.test("turning circle: a point beside the nose inside the circle is blocked; ahead or far is not", function()
		local pos, fwd, r = Vector3.new(0, 0, 0), Vector3.new(0, 0, -1), 75
		h.ok(HoardRules.turnBlocked(pos, fwd, Vector3.new(60, 0, 0), r), "60 studs to the right: orbits it")
		h.ok(HoardRules.turnBlocked(pos, fwd, Vector3.new(-60, 0, 10), r), "left and a little behind")
		h.ok(not HoardRules.turnBlocked(pos, fwd, Vector3.new(0, 0, -100), r), "straight ahead")
		h.ok(not HoardRules.turnBlocked(pos, fwd, Vector3.new(200, 0, 0), r), "beyond the diameter")
		h.ok(not HoardRules.turnBlocked(pos, fwd, Vector3.new(0, 0, 200), r), "far behind: a U-turn reaches it")
		local open = HoardRules.openTurn(pos, fwd, Vector3.new(60, 30, 0))
		h.eq(open, Vector3.new(0, 30, -90), "fly on, at the target's height")
	end)

	h.test("ring approach: aim on the axis on the bot's side, sliding to the centre as it closes", function()
		local ring = { name = "R", pos = Vector3.new(0, 50, 0), axis = Vector3.new(0, 0, -1), radius = 14 }
		h.eq(HoardRules.ringAim(ring, Vector3.new(30, 60, -200)), Vector3.new(0, 50, -40), "far out on the -Z side")
		h.eq(HoardRules.ringAim(ring, Vector3.new(30, 60, 40)), Vector3.new(0, 50, 20), "+Z side, half way")
		h.eq(HoardRules.ringAim(ring, Vector3.new(120, 50, 0)), Vector3.new(0, 50, 0), "beside the ring: the centre")
	end)

	h.test("acorn choice: near and ahead first; avoids ones a closer bot is taking, skips, inside-circle ones; sticky", function()
		local st = field({ Vector3.new(0, 0, -100), Vector3.new(0, 0, 90), Vector3.new(40, 0, -10) })
		local pos, fwd = Vector3.new(0, 0, 0), Vector3.new(0, 0, -1)
		local opts = { turnRadius = 75 }
		h.eq(HoardRules.pickAcorn(st, pos, fwd, 0, opts).id, 1, "ahead beats behind and the one inside the turn")
		h.eq(HoardRules.pickAcorn(st, pos, fwd, 0, { turnRadius = 75, claims = { [1] = 20 } }).id, 3, "a closer bot has #1")
		h.eq(HoardRules.pickAcorn(st, pos, fwd, 0, { turnRadius = 75, claims = { [1] = 300 } }).id, 1, "a farther claimant does not")
		h.eq(HoardRules.pickAcorn(st, pos, fwd, 0, { turnRadius = 75, skip = { [1] = true } }).id, 3, "skipped")
		h.eq(HoardRules.pickAcorn(st, pos, fwd, 0, { turnRadius = 75, skip = { [1] = true, [3] = true } }).id, 2, "only the one behind left")
		h.eq(HoardRules.pickAcorn(st, pos, fwd, 0, { turnRadius = 1 }).id, 3, "a tight turner takes the near one")
		-- Sticky: chasing #2 (110 away) keeps it against #1 (100 away): the current target gets a 25 % discount.
		local sticky = field({ Vector3.new(0, 0, -100), Vector3.new(0, 0, -110) })
		h.eq(HoardRules.pickAcorn(sticky, pos, fwd, 0, { turnRadius = 75, current = 2 }).id, 2, "keeps its target")
		-- Growing anchors and far-off falling acorns are not candidates; one landing within 1.5 s is.
		local g = field({ Vector3.new(0, 0, -50) })
		HoardRules.collect(g, "a", nil, Vector3.new(0, 0, -50), 0)
		h.eq(HoardRules.pickAcorn(g, pos, fwd, 1, opts), nil, "regrowing")
		HoardRules.addLoose(g, { Vector3.new(0, 0, -60) }, 1, 3)
		h.eq(HoardRules.pickAcorn(g, pos, fwd, 1, opts), nil, "lands in 3 s")
		h.eq(HoardRules.pickAcorn(g, pos, fwd, 3, opts).id, HoardRules.LOOSE_ID_BASE + 1, "lands within 1.5 s")
	end)
end
