--!strict
-- Lune spec for the DINO-BATTLE egg battle rules (LAUNCH_PROGRESSION 2b; TEST_LIST_LAUNCH L71):
--   1. The DINO-4 overlay data (REAL build/dino4/TrackData.luau): arena, soft boundary, spawn pads, one nest per seat,
--      the centre nest over the altar, item pods.
--   2. EggRules: carry from the centre (one at a time, the next egg after 3 s), drop in your own nest, hatch after
--      10 s, steal an unhatched egg from a rival nest, knock-loose on a hit, crash drops (a long jump, or the server's
--      respawn signal before or after the jump), first to 3, the cap and its tie rule (no winner without a hatch),
--      leaving, the board order (the cap ranking) and the board and objective text.
--   3. Bots: objective choice (home, centre, steal, loose, chase), claimed targets, the turning-circle line-up that
--      makes a plane with the bots' turn limit fly through a nest instead of orbiting it, and the level turn for a
--      target behind (straight at it, the bots' slerp dives through the floor).
-- Run: tools/tests/run_lune_tests.sh tools/tests/egg_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
}

return function(h: Harness)
	local BattleRules = h.require("src/shared/battle/BattleRules.luau")
	local EggRules = h.require("src/shared/battle/EggRules.luau")
	local dino = h.require("build/dino4/TrackData.luau")

	local V = Vector3.new
	local battle = dino.modes.battle
	local CENTRE: Vector3 = battle.centerNest.pos
	local NESTS: { Vector3 } = {}
	for _, n in battle.nests do
		table.insert(NESTS, n.pos)
	end
	local GEO = { centre = CENTRE, nests = NESTS }
	local HATCH = EggRules.HATCH_SECONDS

	-- player:1 on seat 1, bot:100..bot:102 on seats 2..4 (nest i is seat i's).
	local function seats(): { any }
		local out = {}
		for i = 1, 4 do
			table.insert(out, { id = if i == 1 then "player:1" else "bot:" .. tostring(98 + i), isPlayer = i == 1, slot = i })
		end
		return out
	end

	-- One step at time t: the entrants in `moves` go there, everyone else stays where it was (parked far away at first).
	local FAR = V(0, 500, 0)
	local function at(st: any, t: number, moves: { [string]: Vector3 }): { any }
		local positions: { [string]: Vector3 } = {}
		for _, id in st.ids do
			positions[id] = moves[id] or (st.prev[id] or FAR)
		end
		return EggRules.step(st, t, positions)
	end

	-- Event kinds in order; the centre's own "lay" is left out unless asked for.
	local function kinds(events: { any }, withLay: boolean?): string
		local out = {}
		for _, e in events do
			if withLay or e.kind ~= "lay" then
				table.insert(out, e.kind)
			end
		end
		return table.concat(out, ",")
	end

	-- Flies id to `to`, arriving at time t. A free entrant appears 30 studs short of it and flies in; a carrier flies
	-- the whole way from where it is in 25-stud hops (a longer jump would drop its egg). Hops are 1 ms apart, the last
	-- at t. Returns every event of the trip.
	local function travel(st: any, t: number, id: string, to: Vector3): { any }
		local from: Vector3 = st.prev[id] or FAR
		local path: { Vector3 } = {}
		if from == FAR or not st.entries[id].carrying then
			local dir = if (from - to).Magnitude > 1 then (from - to).Unit else V(1, 0, 0)
			from = to + dir * 30
			table.insert(path, from)
		end
		local hops = math.max(1, math.ceil((to - from).Magnitude / 25))
		for k = 1, hops do
			table.insert(path, from:Lerp(to, k / hops))
		end
		local events = {}
		for i, p in path do
			for _, ev in at(st, t - (#path - i) * 0.001, { [id] = p }) do
				table.insert(events, ev)
			end
		end
		return events
	end

	local function grabCentre(st: any, t: number, id: string): { any }
		return travel(st, t, id, CENTRE)
	end

	local function find(events: { any }, kind: string): any
		for _, e in events do
			if e.kind == kind then
				return e
			end
		end
		return nil
	end

	---------------------------------------------------------------- 1. DINO-4 overlay data

	h.test("DINO-4 overlay: soft-bounded arena round the altar, four pads, centre nest over the altar top", function()
		h.eq(battle.kind, "egg")
		h.eq(battle.vehicle, "plane")
		local a = BattleRules.arena(battle)
		h.ok(a, "arena")
		h.eq(a.radius, 230)
		h.eq(a.returnRadius, 270, "boundary 240 + soft band 30")
		h.eq(a.floor, 10)
		h.eq(a.ceiling, 232)
		h.eq(#a.spawns, 4)
		h.eq(#battle.nests, 4, "one nest per seat of the four-entrant field")
		-- the egg field is capped by its nests (Egg.capacity), never seated past the last nest
		h.eq(BattleRules.fieldSize(#battle.nests), #battle.nests)
		h.eq(BattleRules.botCount(1, #battle.nests), #battle.nests - 1)
		h.ok(CENTRE.Y - battle.centerNest.ground >= 20, "the centre egg hangs well over the altar top")
		h.eq(battle.rules.hatchSeconds, EggRules.HATCH_SECONDS)
		h.eq(battle.rules.eggsToWin, EggRules.TO_WIN)
		h.eq(battle.rules.timeCapSeconds, BattleRules.CAP_SECONDS)
	end)

	h.test("DINO-4 overlay: pad i beside nest i, nest rings face the centre, everything inside the play radius", function()
		local a = BattleRules.arena(battle)
		for i, n in battle.nests do
			h.ok(BattleRules.horizontal(n.pos, a.center) < a.radius - n.radius, "nest inside the play radius")
			h.ok(n.pos.Y - n.radius - n.ground >= 12, "the ring stands clear of the floor")
			local look = CFrame.Angles(0, math.rad(n.yaw), 0).LookVector
			local toCentre = Vector3.new(a.center.X - n.pos.X, 0, a.center.Z - n.pos.Z).Unit
			h.ok(look:Dot(toCentre) > 0.999, "ring axis toward the centre: " .. n.name)
			local pad = a.spawns[i]
			h.eq(BattleRules.nearestIndex(NESTS, pad), i, "pad " .. i .. " is beside nest " .. i)
			h.ok((pad - n.pos).Magnitude > n.radius + EggRules.NEST_RADIUS, "the pad is outside the nest's fly-through")
			-- The first straight run from the pad at the centre egg clears the seat's own ring.
			local run = CENTRE - pad
			local k = math.clamp((n.pos - pad):Dot(run) / run:Dot(run), 0, 1)
			h.ok(((pad + run * k) - n.pos).Magnitude > EggRules.NEST_RADIUS, "pad " .. i .. "'s line to the centre clears its ring")
		end
		local pods = BattleRules.podSpecs(battle)
		h.eq(#pods, 8, "eight pods")
		h.eq(pods[1].podType, "Red")
		h.eq(pods[5].podType, "Red", "the level-one set cycles (four colours: the magnet is retired)")
		for _, p in pods do
			h.ok(BattleRules.horizontal(p.pos, a.center) < a.radius, "pod inside")
		end
	end)

	---------------------------------------------------------------- 2. Rules

	h.test("seats take their slot's nest; a taken or missing slot gets the first free nest; past the nests none", function()
		local st = EggRules.new({
			{ id = "a", isPlayer = true, slot = 2 },
			{ id = "b", isPlayer = false, slot = 2 },
			{ id = "c", isPlayer = false, slot = 7 },
			{ id = "d", isPlayer = false, slot = 4 },
			{ id = "e", isPlayer = true, slot = 5 },
		}, GEO)
		h.eq(st.entries.a.nest, 2)
		h.eq(st.entries.d.nest, 4)
		h.eq(st.entries.b.nest, 1, "slot 2 taken: first free")
		h.eq(st.entries.c.nest, 3)
		h.eq(st.entries.e.nest, nil, "four nests, five seats")
		h.eq(EggRules.nestOwner(st, 3), "c")
		h.ok(st.centreEgg ~= nil, "the first egg waits in the centre from the start")
	end)

	h.test("centre: flying through takes the egg; one egg carried at a time; the next egg comes 3 s later", function()
		local st = EggRules.new(seats(), GEO)
		local first = st.centreEgg
		local ev = grabCentre(st, 1, "player:1")
		h.eq(kinds(ev), "pickup")
		h.eq(ev[1].from, "centre")
		local took = ev[1].t
		h.eq(st.entries["player:1"].carrying, first)
		h.eq(st.centreEgg, nil)
		h.eq(st.respawnAt, took + EggRules.RESPAWN_SECONDS)
		h.eq(kinds(at(st, took + 2.9, { ["player:1"] = CENTRE + V(0, 1, 0) }), true), "", "not yet")
		local laid = at(st, took + 3.05, { ["player:1"] = CENTRE })
		h.eq(kinds(laid, true), "lay", "the next egg; the carrier inside the centre cannot take a second")
		h.eq(st.entries["player:1"].carrying, first)
		h.eq(kinds(grabCentre(st, took + 4, "bot:100")), "pickup", "a free entrant takes it")
	end)

	h.test("your own nest: carry in to drop; it hatches 10 s later and counts; hatched eggs are never stolen", function()
		local st = EggRules.new(seats(), GEO)
		grabCentre(st, 1, "player:1")
		h.eq(kinds(travel(st, 3, "player:1", NESTS[2])), "", "a rival's nest takes no delivery")
		local ev = travel(st, 6, "player:1", NESTS[1])
		h.eq(kinds(ev), "deposit")
		local placed = find(ev, "deposit").t
		local egg = EggRules.nestEggs(st, "player:1")[1]
		h.eq(egg.placedAt, placed)
		h.ok(math.abs(EggRules.progress(st, egg, placed + 5) - 0.5) < 1e-9, "half way after 5 s")
		h.eq(kinds(at(st, placed + HATCH - 0.01, {})), "")
		local hatch = at(st, placed + HATCH, {})
		h.eq(kinds(hatch), "hatch")
		h.eq(find(hatch, "hatch").count, 1)
		h.eq(st.entries["player:1"].hatched, 1)
		h.eq(st.entries["player:1"].reachedAt, placed + HATCH)
		h.eq(kinds(travel(st, placed + 12, "bot:100", NESTS[1])), "", "a hatched egg cannot be stolen")
		h.eq(kinds(travel(st, placed + 14, "player:1", NESTS[1])), "", "your own nest empty-handed does nothing")
	end)

	h.test("steal: the rival egg nearest to hatching; its clock restarts in the thief's nest; carriers cannot steal", function()
		local st = EggRules.new(seats(), GEO)
		grabCentre(st, 1, "player:1")
		local a = find(travel(st, 3, "player:1", NESTS[1]), "deposit").t
		grabCentre(st, 5, "player:1")
		local b = find(travel(st, 7, "player:1", NESTS[1]), "deposit").t
		h.eq(#EggRules.unhatchedIn(st, "player:1"), 2)
		local oldest = EggRules.unhatchedIn(st, "player:1")[1].id
		grabCentre(st, 8.5, "bot:101")
		h.eq(kinds(travel(st, 9.5, "bot:101", NESTS[1])), "", "a carrier passes a rival nest without stealing")
		local ev = find(travel(st, 10, "bot:100", NESTS[1]), "steal")
		h.ok(ev, "steal")
		h.eq(ev.egg, oldest, "the oldest (nearest to hatching) goes")
		h.eq(ev.victim, "player:1")
		h.eq(st.entries["bot:100"].steals, 1)
		h.eq(#EggRules.unhatchedIn(st, "player:1"), 1)
		local d = find(travel(st, 12, "bot:100", NESTS[2]), "deposit")
		h.ok(d, "deposit")
		local stolen = st.eggs[oldest]
		h.eq(stolen.owner, "bot:100")
		h.eq(stolen.placedAt, d.t, "the hatch clock restarts")
		h.ok(d.t > a, "")
		h.eq(kinds(at(st, b + HATCH, {})), "hatch", "the player's second egg hatches on its own clock")
		h.eq(st.entries["player:1"].hatched, 1)
		h.eq(kinds(at(st, d.t + HATCH, {})), "hatch", "the stolen one 10 s after it reached the thief's nest")
		h.eq(st.entries["bot:100"].hatched, 1)
	end)

	h.test("fly-through: a fast pass between two steps counts; a teleport jump tests only where it landed", function()
		h.ok(EggRules.passes(V(-18, 0, 0), V(18, 0, 0), V(0, 5, 0), 10), "segment crosses the sphere")
		h.ok(not EggRules.passes(V(-18, 0, 0), V(18, 0, 0), V(0, 15, 0), 10), "passes over it")
		h.ok(not EggRules.passes(V(-300, 0, 0), V(300, 0, 0), V(0, 0, 0), 10), "a jump longer than SEGMENT_MAX is a teleport")
		h.ok(EggRules.passes(nil, V(3, 0, 0), V(0, 0, 0), 10), "end point inside")
		local st = EggRules.new(seats(), GEO)
		at(st, 1, { ["player:1"] = CENTRE + V(-15, 0, 19) })
		h.eq(kinds(at(st, 1.1, { ["player:1"] = CENTRE + V(15, 0, 19) })), "", "19 studs off the egg: no")
		at(st, 1.5, { ["player:1"] = FAR })
		at(st, 2, { ["player:1"] = CENTRE + V(-19, 0, 6) })
		h.eq(kinds(at(st, 2.02, { ["player:1"] = CENTRE + V(19, 0, 6) })), "pickup", "both ends outside, the path inside")
	end)

	h.test("hit: the egg hangs where it fell; the dropper cannot snatch it back for 2 s; it crumbles after 10 s", function()
		local st = EggRules.new(seats(), GEO)
		grabCentre(st, 1, "player:1")
		local spot = V(-500, 70, -1300)
		h.eq(EggRules.hit(st, "bot:100", 2, spot), nil, "no egg, nothing to drop")
		local ev = EggRules.hit(st, "player:1", 2, spot)
		h.ok(ev and ev.kind == "drop" and ev.from == "hit", "drop event")
		h.eq(st.entries["player:1"].carrying, nil)
		local egg = st.eggs[ev.egg]
		h.eq(egg.at, "loose")
		h.eq(egg.pos, spot)
		h.eq(kinds(at(st, 2.5, { ["player:1"] = spot })), "", "the dropper is still inside: no regrab")
		h.eq(kinds(travel(st, 4.2, "player:1", spot)), "pickup", "after 2 s it may take it back")
		EggRules.hit(st, "player:1", 5, spot)
		h.eq(kinds(travel(st, 5.5, "bot:102", spot)), "pickup", "anyone else at once")
		EggRules.hit(st, "bot:102", 6, spot + V(0, 0, 80))
		h.eq(kinds(at(st, 15.9, {})), "", "still hanging")
		h.eq(kinds(at(st, 16.1, {})), "crumble", "untaken for 10 s")
	end)

	h.test("a crash respawn (a jump past JUMP_DROP) drops the carried egg where the plane was; lag-sized jumps do not", function()
		local st = EggRules.new(seats(), GEO)
		grabCentre(st, 1, "player:1")
		local crash = CENTRE + V(20, -10, 15)
		at(st, 2, { ["player:1"] = crash })
		local ev = at(st, 4, { ["player:1"] = battle.spawns[1] })
		h.eq(kinds(ev), "drop")
		local drop = find(ev, "drop")
		h.eq(drop.from, "jump")
		h.eq(st.eggs[drop.egg].pos, crash, "hangs at the crash site, not at the pad")
		h.eq(st.entries["player:1"].carrying, nil)
		local lag = EggRules.new(seats(), GEO)
		grabCentre(lag, 1, "player:1")
		at(lag, 2, { ["player:1"] = CENTRE + V(0, 0, 10) })
		h.eq(kinds(at(lag, 2.6, { ["player:1"] = CENTRE + V(0, 0, 10 + EggRules.JUMP_DROP - 5) })), "", "a stall-sized jump keeps the egg")
		h.ok(lag.entries["player:1"].carrying ~= nil, "still carrying")
	end)

	h.test("respawn signal: the egg falls where the plane was, whether the signal or the jump reaches the rules first", function()
		local crash = CENTRE + V(60, -20, 40)
		local pad = crash + V(70, 10, 0) -- respawned near the crash site: no JUMP_DROP-sized jump to go by
		-- Signal first: the crashed plane is still tumbling at the crash site.
		local st = EggRules.new(seats(), GEO)
		grabCentre(st, 1, "player:1")
		travel(st, 2, "player:1", crash)
		local ev = EggRules.respawned(st, "player:1", 3)
		h.ok(ev ~= nil and ev.kind == "drop" and ev.from == "respawn", "drop event")
		h.eq(st.eggs[(ev :: any).egg].pos, crash, "hangs at the crash site")
		h.eq(st.entries["player:1"].carrying, nil)
		h.eq(st.entries["player:1"].drops, 1)
		h.eq(kinds(at(st, 3.05, { ["player:1"] = pad })), "", "the jump arriving after changes nothing")
		h.eq(EggRules.respawned(st, "player:1", 3.1), nil, "nothing left to drop")
		h.eq(EggRules.respawned(st, "bot:100", 3.1), nil, "a respawn without an egg drops nothing")
		-- Jump first (shorter than JUMP_DROP, so it alone keeps the egg), the signal a moment later.
		local late = EggRules.new(seats(), GEO)
		grabCentre(late, 1, "player:1")
		travel(late, 2, "player:1", crash)
		h.eq(kinds(at(late, 3, { ["player:1"] = pad })), "", "a 70-stud jump alone keeps the egg")
		h.ok(late.entries["player:1"].carrying ~= nil, "still carried until the signal")
		local d = EggRules.respawned(late, "player:1", 3.2)
		h.ok(d ~= nil and d.from == "respawn", "the signal drops it")
		h.eq(late.eggs[(d :: any).egg].pos, crash, "where the plane jumped from, not at the pad")
		-- A long jump dropped the egg and the plane took the next centre egg where it landed: that one stays.
		local far = EggRules.new(seats(), GEO)
		local took = find(grabCentre(far, 1, "player:1"), "pickup").t
		-- out past nest 3, so the jump back to the centre stays longer than JUMP_DROP whatever the nest radius
		local site = NESTS[3] + (NESTS[3] - CENTRE).Unit * 50 + V(0, 0, 40)
		travel(far, 2, "player:1", site)
		local landed = CENTRE + V(0, 0, 30)
		local jump = at(far, took + EggRules.RESPAWN_SECONDS + 0.1, { ["player:1"] = landed })
		h.eq(kinds(jump), "drop", "a JUMP_DROP-sized jump drops it at once")
		h.eq(find(jump, "drop").from, "jump")
		h.eq(kinds(at(far, took + 3.2, { ["player:1"] = CENTRE })), "pickup", "the new centre egg")
		h.eq(EggRules.respawned(far, "player:1", took + 3.5), nil, "the egg taken after the respawn stays")
		h.ok(far.entries["player:1"].carrying ~= nil, "")
		-- A stale jump (lag, long before the signal) does not move the drop: it falls where the plane is.
		local stale = EggRules.new(seats(), GEO)
		grabCentre(stale, 1, "player:1")
		at(stale, 2, { ["player:1"] = CENTRE + V(0, 0, 20) })
		at(stale, 2.1, { ["player:1"] = CENTRE + V(0, 0, 100) })
		at(stale, 5, { ["player:1"] = CENTRE + V(0, 0, 110) })
		local s = EggRules.respawned(stale, "player:1", 5 + EggRules.RESPAWN_WINDOW)
		h.eq(stale.eggs[(s :: any).egg].pos, CENTRE + V(0, 0, 110))
		-- After the win nothing changes.
		local won = EggRules.new(seats(), GEO)
		grabCentre(won, 1, "player:1")
		won.winner = "bot:100"
		h.eq(EggRules.respawned(won, "player:1", 2), nil)
	end)

	h.test("first to 3 hatched wins at once; two on one step: the earlier hatch time", function()
		local st = EggRules.new(seats(), GEO)
		local last = 0
		for k = 1, 3 do
			grabCentre(st, k * 4, "player:1")
			last = find(travel(st, k * 4 + 2, "player:1", NESTS[1]), "deposit").t
		end
		h.eq(EggRules.checkEnd(st).over, false)
		local ev = at(st, last + HATCH, {})
		h.eq(kinds(ev), "hatch,hatch,hatch,win")
		h.eq(st.winner, "player:1")
		local out = EggRules.checkEnd(st)
		h.ok(out.over and out.winner == "player:1" and out.reason == "first to 3", "outcome")
		h.eq(#at(st, last + 20, {}), 0, "nothing happens after the win")

		local tie = EggRules.new(seats(), GEO)
		for k, id in { "bot:100", "player:1" } do
			tie.entries[id].hatched = 2
			tie.eggs[90 + k] = { id = 90 + k, at = "nest", owner = id, placedAt = 10 + k * 0.01, hatched = false }
		end
		h.eq(kinds(at(tie, 21, {})), "hatch,hatch,win")
		h.eq(tie.winner, "bot:100", "its egg went in (and hatched) first")
	end)

	h.test("cap: most hatched; ties by who got there first, eggs in the nest, hatch progress, carrying, player, seat", function()
		local st = EggRules.new(seats(), GEO)
		local e = st.entries
		e["bot:100"].hatched, e["bot:100"].reachedAt = 2, 50
		e["bot:101"].hatched, e["bot:101"].reachedAt = 2, 40
		e["player:1"].hatched = 1
		local r = EggRules.resolveCap(st, 180)
		h.eq(r.winner, "bot:101", "2 hatched, reached first")
		h.eq(r.reason, "time")
		h.eq(EggRules.ranking(st, 180), { "bot:101", "bot:100", "player:1", "bot:102" })
		local z = EggRules.new(seats(), GEO)
		z.eggs[50] = { id = 50, at = "nest", owner = "bot:102", placedAt = 175, hatched = false }
		z.eggs[51] = { id = 51, at = "nest", owner = "bot:101", placedAt = 172, hatched = false }
		z.eggs[52] = { id = 52, at = "nest", owner = "bot:101", placedAt = 179, hatched = false }
		z.eggs[53] = { id = 53, at = "nest", owner = "bot:100", placedAt = 171, hatched = false }
		h.eq(EggRules.ranking(z, 180)[1], "bot:101", "two eggs in the nest beat one")
		h.eq(EggRules.ranking(z, 180)[2], "bot:100", "then the egg nearest to hatching")
		local c = EggRules.new(seats(), GEO)
		c.entries["bot:102"].carrying = c.centreEgg
		h.eq(EggRules.ranking(c, 180)[1], "bot:102", "carrying beats nothing")
		local p = EggRules.new(seats(), GEO)
		h.eq(EggRules.ranking(p, 180), { "player:1", "bot:100", "bot:101", "bot:102" }, "all level: player, then seat")
	end)

	h.test("cap: nobody hatched an egg, nobody wins (the tie rule ranks, it awards nothing); one hatch wins it", function()
		local st = EggRules.new(seats(), GEO)
		h.eq(EggRules.resolveCap(st, 180).winner, nil, "all level: no winner, though the player ranks first")
		h.eq(EggRules.ranking(st, 180)[1], "player:1")
		grabCentre(st, 1, "player:1")
		st.eggs[60] = { id = 60, at = "nest", owner = "bot:100", placedAt = 175, hatched = false }
		local r = EggRules.resolveCap(st, 180)
		h.eq(r.winner, nil, "carrying or an unhatched egg wins nothing")
		h.eq(r.reason, "time")
		st.entries["bot:101"].hatched, st.entries["bot:101"].reachedAt = 1, 100
		h.eq(EggRules.resolveCap(st, 180).winner, "bot:101", "one hatched egg is the most")
		st.entries["bot:101"].left = true
		h.eq(EggRules.resolveCap(st, 180).winner, nil, "its only hatcher left: ranked last, no winner")
	end)

	h.test("board: scores are places in the cap ranking, so the board shows the order the results will give", function()
		local st = EggRules.new(seats(), GEO)
		local e = st.entries
		e["bot:100"].hatched, e["bot:100"].reachedAt = 2, 40
		e["player:1"].hatched, e["player:1"].reachedAt = 2, 60
		st.eggs[70] = { id = 70, at = "nest", owner = "player:1", placedAt = 170, hatched = false }
		h.ok(EggRules.scoreValue(st, "player:1") > EggRules.scoreValue(st, "bot:100"), "the raw standing puts the player on top")
		local ranking = EggRules.ranking(st, 175)
		h.eq(ranking[1], "bot:100", "the cap gives it to the one that reached 2 first")
		for i, id in ranking do
			h.eq(EggRules.boardScore(st, id, 175, ranking), #ranking - i, id)
		end
		h.ok(EggRules.boardScore(st, "bot:100", 175) > EggRules.boardScore(st, "player:1", 175), "the board agrees")
		h.eq(EggRules.boardScore(st, "nobody", 175), -1)
	end)

	h.test("leaving: the carried egg drops; the nest's eggs stay stealable but never hatch; the leaver ranks last", function()
		local st = EggRules.new(seats(), GEO)
		grabCentre(st, 1, "bot:100")
		travel(st, 3, "bot:100", NESTS[2])
		grabCentre(st, 5, "bot:100")
		st.entries["bot:100"].isPlayer = true -- a second client in that seat
		local ev = EggRules.leave(st, "bot:100", 6, V(-600, 80, -1300))
		h.eq(kinds(ev), "drop")
		h.eq(ev[1].from, "leave")
		h.eq(st.eggs[ev[1].egg].noGrabId, nil, "anyone may take it at once")
		h.eq(kinds(at(st, 14, {})), "", "no hatch for a leaver")
		h.eq(kinds(travel(st, 15, "player:1", NESTS[2])), "steal", "still stealable")
		h.eq(EggRules.ranking(st, 20)[4], "bot:100")
		h.eq(#EggRules.leave(st, "bot:100", 21, nil), 0, "leaving twice changes nothing")
		local gone = EggRules.new(seats(), GEO)
		grabCentre(gone, 1, "player:1")
		h.eq(kinds(EggRules.leave(gone, "player:1", 2, nil)), "crumble", "no last position: the egg is gone")
	end)

	h.test("board and objective text", function()
		local st = EggRules.new(seats(), GEO)
		h.eq(EggRules.scoreText(st, "player:1"), "0 HATCHED")
		h.eq(EggRules.hudText(st, "player:1", 0, "BLUE"), "HATCHED 0/3  -  grab the egg at the centre nest")
		local took = find(grabCentre(st, 1, "player:1"), "pickup").t
		h.eq(EggRules.scoreText(st, "player:1"), "0 HATCHED + EGG")
		h.eq(EggRules.hudText(st, "player:1", 1.1, "BLUE"), "HATCHED 0/3  -  EGG! fly through your BLUE nest")
		h.eq(EggRules.hudText(st, "bot:100", took, "RED"), "HATCHED 0/3  -  next egg in 3 s")
		local placed = find(travel(st, 2, "player:1", NESTS[1]), "deposit").t
		h.eq(EggRules.hudText(st, "player:1", placed + 4, "BLUE"), "HATCHED 0/3  -  hatching in 6 s, guard the BLUE nest")
		h.eq(EggRules.hudText(st, "bot:100", placed, "RED"), "HATCHED 0/3  -  steal an egg from a rival nest")
		h.eq(EggRules.scoreText(st, "player:1"), "0 HATCHED + 1 NEST")
		h.eq(EggRules.scoreValue(st, "player:1"), 10)
		at(st, placed + HATCH, {})
		h.eq(EggRules.scoreText(st, "player:1"), "1 HATCHED")
		h.eq(EggRules.scoreValue(st, "player:1"), 100)
		EggRules.leave(st, "bot:101", 13, nil)
		h.eq(EggRules.scoreText(st, "bot:101"), "0 HATCHED (LEFT)")
	end)

	---------------------------------------------------------------- 3. Bots

	h.test("bot targets: home when carrying; else the cheapest of centre, loose and steal; chase a carrier; aim at it", function()
		local st = EggRules.new(seats(), GEO)
		local bots = { ["bot:100"] = true, ["bot:101"] = true, ["bot:102"] = true }
		local here = NESTS[2] + V(0, 10, 0)
		local others = { ["player:1"] = NESTS[1], ["bot:100"] = here, ["bot:101"] = NESTS[3], ["bot:102"] = NESTS[4] }
		local tg = EggRules.botTarget(st, "bot:100", here, 0, others, bots)
		h.eq(tg.reason, "centre")
		h.eq(tg.pos, CENTRE)
		h.eq(tg.attack, nil, "nobody carries")
		-- The player takes the egg: nothing to take, chase it and aim at it.
		grabCentre(st, 1, "player:1")
		others["player:1"] = CENTRE
		tg = EggRules.botTarget(st, "bot:100", here, 1.1, others, bots)
		h.eq(tg.reason, "chase", "centre empty, nothing to steal: chase the carrier")
		h.eq(tg.attack, "player:1")
		-- Its egg in its nest: steal it.
		local placed = find(travel(st, 2, "player:1", NESTS[1]), "deposit").t
		others["player:1"] = NESTS[1]
		tg = EggRules.botTarget(st, "bot:100", here, placed + 0.1, others, bots)
		h.eq(tg.reason, "steal")
		h.eq(tg.pos, NESTS[1])
		-- Carrying: home, whatever else is on offer.
		at(st, placed + 3, {})
		grabCentre(st, placed + 3.5, "bot:100")
		tg = EggRules.botTarget(st, "bot:100", CENTRE, placed + 3.6, others, bots)
		h.eq(tg.reason, "home")
		h.eq(tg.pos, NESTS[2])
		-- A loose egg near by beats the far centre.
		local loose = EggRules.new(seats(), GEO)
		local took = find(grabCentre(loose, 1, "player:1"), "pickup").t
		EggRules.hit(loose, "player:1", 1.5, NESTS[3] + V(30, 20, 0))
		at(loose, 1.6, { ["player:1"] = FAR })
		at(loose, took + 3.1, {})
		h.ok(loose.centreEgg ~= nil, "a new centre egg")
		tg = EggRules.botTarget(loose, "bot:101", NESTS[3], took + 3.2, { ["bot:101"] = NESTS[3] }, bots)
		h.eq(tg.reason, "loose")
	end)

	h.test("bot targets: an egg another free bot has picked and is closer to is left to it; the player is raced", function()
		local st = EggRules.new(seats(), GEO)
		local bots = { ["bot:100"] = true, ["bot:101"] = true, ["bot:102"] = true }
		local took = find(grabCentre(st, 1, "player:1"), "pickup").t
		local placed = find(travel(st, 2, "player:1", NESTS[1]), "deposit").t
		at(st, took + 3.1, {}) -- a new centre egg
		h.ok(st.centreEgg ~= nil, "centre egg")
		local near = CENTRE + V(40, 0, 0)
		local far = NESTS[3] + V(0, 0, 60)
		local others = { ["player:1"] = CENTRE + V(5, 0, 0), ["bot:100"] = near, ["bot:101"] = far }
		local t = placed + 2
		h.eq(EggRules.botTarget(st, "bot:100", near, t, others, bots).reason, "centre", "the near bot races the player")
		h.eq(EggRules.botTarget(st, "bot:101", far, t, others, bots).reason, "steal", "the far bot leaves the centre to bot:100")
		-- Alone, the far bot would have gone for the centre.
		h.eq(EggRules.botTarget(st, "bot:101", far, t, { ["bot:101"] = far }, bots).reason, "centre")
	end)

	h.test("approach: a target inside the turning circle is lined up from straight on, so a plane flies through", function()
		local R = 102 / math.rad(80) * 1.1
		local aim, swung = EggRules.approach(V(0, 50, 0), V(0, 0, -1), V(40, 50, -10), R)
		h.ok(swung, "40 studs to the right, nearly abeam: inside the right turning circle")
		h.ok(aim.Z < -100, "aims straight on")
		h.eq(aim.Y, 50, "keeps the target's height")
		local straight, ok2 = EggRules.approach(V(0, 50, 0), V(0, 0, -1), V(0, 50, -300), R)
		h.ok(not ok2 and straight == V(0, 50, -300), "ahead: unchanged")
		-- A point plane with the bots' limits (102 studs/s, 80 deg/s) from a bad start beside a nest: pure pursuit
		-- orbits it for the whole minute; with the line-up it passes through within seconds.
		local function fly(lineUp: boolean): number?
			local nest = V(0, 50, 0)
			local pos, fwd = V(45, 50, 30), V(0, 0, -1)
			local dt = 1 / 30
			for i = 1, 30 * 60 do
				local goal = nest
				if lineUp then
					goal = EggRules.approach(pos, fwd, nest, R)
				end
				fwd = BattleRules.turnToward(fwd, goal - pos, math.rad(80) * dt)
				local nextPos = pos + fwd * 102 * dt
				if EggRules.passes(pos, nextPos, nest, EggRules.NEST_RADIUS) then
					return i * dt
				end
				pos = nextPos
			end
			return nil
		end
		h.eq(fly(false), nil, "pure pursuit orbits")
		local t = fly(true)
		h.ok(t ~= nil and t < 12, "lined up: through the nest in " .. tostring(t))
	end)

	h.test("approach: a target behind is turned to level, square to the nose, instead of slerped through a dive", function()
		local R = 102 / math.rad(80) * 1.1
		local aim, swung, why = EggRules.approach(V(0, 50, 0), V(0, 0, -1), V(-30, 60, 200), R)
		h.ok(swung and why == "turn", "behind: replaced")
		h.ok(math.abs(aim.Z) < 1e-6 and aim.X < -R, "square to the nose on the target's side (left)")
		h.eq(aim.Y, 60, "at the target's height")
		h.eq(select(3, EggRules.approach(V(0, 50, 0), V(0, 0, -1), V(40, 50, -10), R)), "line up", "inside a circle: line up")
		-- A plane flown like an arena bot (BattleBots: 80 deg/s slerp toward the goal, then the 32-degree pitch limit)
		-- from a shallow dive, its target behind. Returns the lowest height and when it passed through (nil: never).
		local function fly(useApproach: boolean, target: Vector3, dive: number): (number, number?)
			local pos = V(0, 60, 0)
			local fwd = V(0, -math.sin(math.rad(dive)), -math.cos(math.rad(dive)))
			local low = pos.Y
			local dt = 1 / 30
			for i = 1, 30 * 8 do
				local goal = if useApproach then (EggRules.approach(pos, fwd, target, R)) else target
				local f = BattleRules.turnToward(fwd, goal - pos, math.rad(80) * dt)
				local flatF = V(f.X, 0, f.Z)
				local pitch = math.clamp(math.atan2(f.Y, flatF.Magnitude), -math.rad(32), math.rad(32))
				fwd = (flatF.Unit * math.cos(pitch) + V(0, 1, 0) * math.sin(pitch)).Unit
				local nextPos = pos + fwd * 102 * dt
				if EggRules.passes(pos, nextPos, target, EggRules.NEST_RADIUS) then
					return math.min(low, nextPos.Y), i * dt
				end
				pos = nextPos
				low = math.min(low, pos.Y)
			end
			return low, nil
		end
		local behind = V(0, 60, 200)
		local lowS, tS = fly(false, behind, 10)
		h.ok(tS == nil and lowS < -100, string.format("straight at it: dives through the floor (lowest %.0f)", lowS))
		local lowA, tA = fly(true, behind, 10)
		h.ok(tA ~= nil and 60 - lowA < 25, string.format("turned level: through it in %s s, %.0f studs lost", tostring(tA), 60 - lowA))
		local offset = V(20, 60, 260)
		local steepS = fly(false, offset, 30)
		local steepA = fly(true, offset, 30)
		h.ok(steepA > steepS + 30, string.format("out of a 30-degree dive: lowest %.0f turned vs %.0f straight", steepA, steepS))
	end)
end
