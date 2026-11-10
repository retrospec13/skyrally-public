--!strict
-- Lune spec for the launch side loops (LAUNCH_PROGRESSION 2b and 3; TEST_LIST_LAUNCH L70, L72, L75):
--   1. BattleRules (src/shared/battle): arenas from the REAL TrackData of SNOW-1, FOREST-1 and ISLAND-2, soft boundary
--      zones, seats, bot count, pods from the plan's pickups / anchors, nearest-opponent targeting, bot steering and
--      item decisions.
--   2. SurvivalRules: lives, out, last standing, every-player-out end, cap resolution and the tie rule.
--   3. Keys: KeyPickup eligibility (key tracks and modes only, never SPACE-4 or the hub) and its proximity check, then
--      the key -> battle unlock -> battle fragment chain through a REAL SaveService over a memory store (idempotent,
--      thresholds unchanged).
--   4. ItemEffects arena mode: shots fly free and curve to the arena's target, hits come from the arena's order and
--      reach onHit; setArena(nil) restores the race behaviour.
-- Run: tools/tests/run_lune_tests.sh tools/tests/battle_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
	logs: { string },
	newScheduler: (number?) -> any,
	fakePlayer: (number, string?) -> any,
	stubs: any,
}

return function(h: Harness)
	local BattleRules = h.require("src/shared/battle/BattleRules.luau")
	local SurvivalRules = h.require("src/shared/battle/SurvivalRules.luau")
	local PlaneConfig = h.require("src/shared/PlaneConfig.luau")
	local Progression = h.require("src/shared/Progression.luau")
	local SaveService = h.require("src/server/SaveService.luau")
	local KeyPickup = h.require("src/server/KeyPickup.luau")
	local ItemEffects = h.require("src/server/kit/ItemEffects.luau")
	local ItemRules = h.require("src/shared/ItemRules.luau")

	local snow = h.require("build/snow1/TrackData.luau")
	local forest = h.require("build/forest1/TrackData.luau")
	local island = h.require("build/island2/TrackData.luau")
	local dino = h.require("build/dino4/TrackData.luau")
	local space = h.require("build/space4/TrackData.luau")
	local hub = h.require("build/hub0/TrackData.luau")

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	---------------------------------------------------------------- 1. BattleRules

	-- SNOW-1 numbers from docs/audits/traps_snow1.md SN-01/SN-08: play radius 200 (was 250), ceiling 32 + 260 (was 172)
	h.test("arena: SNOW-1 boundary cylinder (radius 200 play, 280 boundary, ceiling from height)", function()
		local a = BattleRules.arena(snow.modes.battle)
		h.ok(a, "arena")
		h.eq(a.radius, 200)
		h.eq(a.returnRadius, 280, "boundary radius past the play radius: no extra soft band")
		h.ok(near(a.ceiling, 32 + 260), "ceiling = boundary centre Y + height")
		h.eq(a.floor, -math.huge)
		h.eq(#a.spawns, 4)
		h.eq(a.center, Vector3.new(-8240, 46, 600))
	end)

	h.test("arena: FOREST-1 floor/ceiling and ISLAND-2 softBoundary band", function()
		local f = BattleRules.arena(forest.modes.battle)
		h.eq(f.radius, 250)
		h.eq(f.returnRadius, 270)
		h.ok(near(f.floor, 53.5) and near(f.ceiling, 233.5), "explicit floor and ceiling")
		local i = BattleRules.arena(island.modes.battle)
		h.eq(i.radius, 250, "the whole drivable cove (owner 2026-10-21: the 150 disc was too tiny)")
		h.eq(i.returnRadius, 275, "softBoundary radius + softWidth 25")
		h.eq(i.ceiling, math.huge)
		h.eq(#i.spawns, BattleRules.FIELD, "a sand pad per seat of the eight-car field, none on the galleon")
		h.eq(BattleRules.arena(nil), nil)
		h.eq(BattleRules.arena({ kind = "survival" }), nil, "no centre or radius: no arena")
		-- DINO-4's block lands with the egg mode (another lane); when present it is the egg battle with a usable arena.
		local dinoBattle = dino.modes.battle
		if dinoBattle ~= nil then
			h.eq(dinoBattle.kind, "egg", "DINO-4 runs the egg battle")
			h.ok(BattleRules.arena(dinoBattle) ~= nil, "DINO-4 egg arena normalises")
		end
	end)

	h.test("arena zones: inside, warn band, out past the band or above the ceiling", function()
		local a = BattleRules.arena(snow.modes.battle)
		local c = a.center
		h.eq(BattleRules.zoneOf(a, c), "inside")
		h.eq(BattleRules.zoneOf(a, c + Vector3.new(190, 0, 0)), "inside")
		h.eq(BattleRules.zoneOf(a, c + Vector3.new(240, 0, 0)), "warn")
		h.eq(BattleRules.zoneOf(a, c + Vector3.new(0, 0, 265)), "warn")
		h.eq(BattleRules.zoneOf(a, c + Vector3.new(-290, 0, 0)), "out")
		h.eq(BattleRules.zoneOf(a, Vector3.new(c.X, a.ceiling + 1, c.Z)), "out")
		local f = BattleRules.arena(forest.modes.battle)
		h.eq(BattleRules.zoneOf(f, Vector3.new(f.center.X, 50, f.center.Z)), "out", "below the FOREST floor")
	end)

	h.test("seats: a player keeps the pad it spawned on, bots take the free pads, extra seats ring the centre", function()
		local a = BattleRules.arena(snow.modes.battle)
		local cf2 = BattleRules.spawnCFrame(a, 2)
		h.eq(cf2.Position, a.spawns[2])
		local look = cf2.LookVector
		h.ok(look.X < -0.99, "pad 2 (east) faces the centre (west)")
		local players, bots = BattleRules.assignSlots(a, { cf2.Position }, 3)
		h.eq(players, { 2 })
		h.eq(bots, { 1, 3, 4 })
		local five = { a.spawns[1], a.spawns[2], a.spawns[3], a.spawns[4], a.center }
		local p5, b5 = BattleRules.assignSlots(a, five, 0)
		h.eq(p5, { 1, 2, 3, 4, 5 })
		h.eq(b5, {})
		local ring = BattleRules.spawnPosition(a, 5)
		h.ok(near(BattleRules.horizontal(ring, a.center), a.radius * BattleRules.SPAWN_RING, 1e-3), "ring seat radius")
		-- Ring seats sit at the pads' height: FOREST-1's centre (Y 63.5) is about 30 studs under its pads.
		local f = BattleRules.arena(forest.modes.battle)
		local lowest = math.huge
		for _, s in f.spawns do
			lowest = math.min(lowest, s.Y)
		end
		local fRing = BattleRules.spawnPosition(f, #f.spawns + 1)
		h.ok(fRing.Y >= lowest, string.format("FOREST ring seat Y %.1f is not under the pads (lowest %.1f)", fRing.Y, lowest))
		h.ok(BattleRules.zoneOf(f, fRing) == "inside", "and inside the arena (above its floor)")
		h.eq(BattleRules.spawnPosition(BattleRules.arena({ center = Vector3.new(0, 30, 0), radius = 100 }), 1).Y, 30, "no pads: centre height")
		-- Owner 2026-10-21: battles fill to the race field (8 entrants), like races.
		h.eq(BattleRules.FIELD, PlaneConfig.AI_FIELD_SIZE, "a battle field is a race field")
		h.eq(BattleRules.botCount(1), 7)
		h.eq(BattleRules.botCount(0), 7, "an empty server still seats seven bots")
		h.eq(BattleRules.botCount(2), 6, "a second client takes a bot's seat")
		h.eq(BattleRules.botCount(6), 2)
		h.eq(BattleRules.botCount(8), 0)
		h.eq(BattleRules.botCount(12), 0)
		for humans = 1, 8 do
			h.eq(humans + BattleRules.botCount(humans), 8, "players + bots = 8")
		end
		-- a mode with fewer seats (egg: one nest per seat) caps the field at its seats
		h.eq(BattleRules.fieldSize(4), 4)
		h.eq(BattleRules.botCount(1, 4), 3)
		h.eq(BattleRules.botCount(4, 4), 0)
		h.eq(BattleRules.fieldSize(12), 8, "seats past the race field do not grow it")
		h.eq(BattleRules.fieldSize(-1), 8, "no cap: the race field")
		h.eq(BattleRules.botCount(1, -1), 7)
		-- L71/L75: 8 humans, 4 nests -> 4 seat, 4 watch; last round's watchers sit first next time.
		local seat, over = BattleRules.splitSeats({ 8, 3, 5, 1, 7, 2, 6, 4 }, {}, 4)
		h.eq(table.concat(seat, ","), "1,2,3,4")
		h.eq(table.concat(over, ","), "5,6,7,8")
		local seat2, over2 = BattleRules.splitSeats({ 1, 2, 3, 4, 5, 6, 7, 8 }, { [5] = true, [6] = true, [7] = true, [8] = true }, 4)
		h.eq(table.concat(seat2, ","), "5,6,7,8")
		h.eq(table.concat(over2, ","), "1,2,3,4")
		h.eq(#select(2, BattleRules.splitSeats({ 1, 2, 3 }, {}, -1)), 0, "no cap seats everyone")
	end)

	h.test("seat headings: ISLAND-2's authored spawnLooks (trap audit I2-02 / I2-04); pads without one face the centre", function()
		local i = BattleRules.arena(island.modes.battle)
		local looks = island.modes.battle.spawnLooks
		h.ok(looks ~= nil and #looks == #i.spawns, "one authored heading per ISLAND-2 pad")
		for slot = 1, #i.spawns do
			local cf = BattleRules.spawnCFrame(i, slot)
			local p = i.spawns[slot]
			h.eq(cf.Position, p, "seat " .. slot .. " on its pad")
			local want = CFrame.lookAt(p, p + Vector3.new(looks[slot].X, 0, looks[slot].Z).Unit).LookVector
			h.ok((cf.LookVector - want).Magnitude < 1e-4, "seat " .. slot .. " faces its authored heading")
		end
		local s = BattleRules.arena(snow.modes.battle)
		h.eq(next(s.looks), nil, "SNOW-1 authors none")
		local ring = BattleRules.spawnCFrame(i, #i.spawns + 1)
		local toCentre = Vector3.new(i.center.X - ring.Position.X, 0, i.center.Z - ring.Position.Z).Unit
		h.ok(ring.LookVector:Dot(CFrame.lookAt(ring.Position, ring.Position + toCentre).LookVector) > 0.999, "a ring seat still faces the centre")
	end)

	h.test("edge pull band and ceiling band (trap audit G6): one turn radius wide, a warn band under the ceiling", function()
		local s = BattleRules.arena(snow.modes.battle)
		local start = BattleRules.pullStart(s, "plane")
		h.ok(s.returnRadius - start >= BattleRules.PLANE_TURN_RADIUS - 1e-6, "SNOW-1: a plane's turn fits between the pull and the return line")
		h.ok(start <= s.radius * BattleRules.PULL_FRACTION + 1e-6, "never later than the old 90 % rule")
		local f = BattleRules.arena(forest.modes.battle)
		h.eq(BattleRules.pullStart(f, "plane"), f.returnRadius - BattleRules.PLANE_TURN_RADIUS, "FOREST-1: 270 - 93")
		local d = dino.modes.battle and BattleRules.arena(dino.modes.battle)
		if d then
			h.ok(d.returnRadius - BattleRules.pullStart(d, "plane") >= BattleRules.PLANE_TURN_RADIUS - 1e-6, "DINO-4 too")
		end
		local i = BattleRules.arena(island.modes.battle)
		h.ok(i.returnRadius - BattleRules.pullStart(i, "car") >= BattleRules.CAR_TURN_RADIUS - 1e-6, "ISLAND-2 for a car")
		local c = s.center
		h.eq(BattleRules.tooHigh(s, Vector3.new(c.X, s.ceiling - 10, c.Z)), true, "10 under the ceiling: too high")
		h.eq(BattleRules.tooHigh(s, Vector3.new(c.X, s.ceiling - BattleRules.CEILING_WARN - 1, c.Z)), false, "under the band: fine")
		h.eq(BattleRules.tooHigh(s, Vector3.new(c.X, s.ceiling + 1, c.Z)), false, "past the ceiling it is out, not a warning")
		h.eq(BattleRules.tooHigh(i, Vector3.new(i.center.X, 5000, i.center.Z)), false, "no ceiling (ISLAND-2): never")
	end)

	h.test("respawn frames from another map are not this arena's (the stale-respawn fix)", function()
		local i = BattleRules.arena(island.modes.battle)
		for slot = 1, #i.spawns do
			h.ok(BattleRules.ownsFrame(i, i.spawns[slot]), "every seat is the arena's")
		end
		h.ok(BattleRules.ownsFrame(i, i.center + Vector3.new(i.returnRadius + 30, 0, 0)), "just past the band (a boundary return) still is")
		h.eq(BattleRules.ownsFrame(i, Vector3.new(-8162, 30, 8028)), false, "the hub plaza (the Studio stale frame) is not")
		local s = BattleRules.arena(snow.modes.battle)
		h.eq(BattleRules.ownsFrame(s, Vector3.new(s.center.X, s.ceiling + 200, s.center.Z)), false, "far over the ceiling is not")
		-- Seats ignore a stale frame: the player takes the pads in order instead of the pad nearest the old map.
		local players = BattleRules.assignSlots(i, { BattleRules.spawnPosition(i, 1) }, 3)
		h.eq(players[1], 1, "crest B")
	end)

	h.test("pods: SNOW-1 pickups keep their colours and 12 s respawn; anchors cycle the mode's colours", function()
		local specs = BattleRules.podSpecs(snow.modes.battle)
		h.eq(#specs, 8)
		local counts = { Red = 0, Green = 0, Yellow = 0 }
		for _, s in specs do
			counts[s.podType] += 1
			h.eq(s.respawn, 12)
		end
		h.eq(counts, { Red = 3, Green = 2, Yellow = 3 })
		local isl = BattleRules.podSpecs(island.modes.battle, { "Red", "Green", "Yellow" })
		h.eq(#isl, 14, "14 pods on the dry sand loop, none on the galleon")
		h.eq({ isl[1].podType, isl[2].podType, isl[3].podType, isl[4].podType }, { "Red", "Green", "Yellow", "Red" })
		local def = BattleRules.podSpecs(forest.modes.battle)
		h.eq(def[5].podType, "Red", "default cycle is the level-one race set (magnet retired: four colours)")
		for _, s in def do
			h.ok(s.podType ~= "Rainbow", "no Rainbow pod while the magnet is retired")
		end
		for _, s in def do
			h.eq(ItemRules.classifyPod(s.podType), "item")
		end
	end)

	h.test("targeting: nearest opponent, forward cone and range; never itself", function()
		local list = {
			{ id = "me", pos = Vector3.new(0, 0, 0) },
			{ id = "behind", pos = Vector3.new(0, 0, 30) },
			{ id = "ahead", pos = Vector3.new(0, 0, -80) },
			{ id = "far", pos = Vector3.new(0, 0, -900) },
		}
		local id, d = BattleRules.nearestOpponent("me", Vector3.new(0, 0, 0), list)
		h.eq(id, "behind")
		h.eq(d, 30)
		h.eq((BattleRules.nearestOpponent("me", Vector3.new(0, 0, 0), list, Vector3.new(0, 0, -1), 0.5)), "ahead", "cone")
		h.eq((BattleRules.nearestOpponent("me", Vector3.new(0, 0, 0), list, Vector3.new(1, 0, 0), 0.5)), nil, "nobody to the right")
		h.eq((BattleRules.nearestOpponent("me", Vector3.new(0, 0, -880), list, nil, nil, 50)), "far")
		h.eq((BattleRules.nearestOpponent("me", Vector3.new(0, 0, 400), list, nil, nil, 50)), nil, "out of range")
	end)

	h.test("bot steering: turn rate bounded, pulled inside the arena, flat for cars, apart from neighbours", function()
		local f = BattleRules.turnToward(Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), math.rad(30))
		h.ok(near(math.deg(math.acos(f:Dot(Vector3.new(0, 0, -1)))), 30, 1e-3), "30 degrees this step")
		h.ok(near(f.Magnitude, 1, 1e-6), "unit")
		local back = BattleRules.turnToward(Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), math.rad(20))
		h.ok(near(math.deg(math.acos(back:Dot(Vector3.new(0, 0, -1)))), 20, 1e-3), "reversal swings round")
		h.eq(BattleRules.turnToward(Vector3.new(0, 0, -1), Vector3.new(0, 0, -5), 0.1), Vector3.new(0, 0, -1))
		local a = BattleRules.arena(snow.modes.battle)
		local c = a.center
		-- At the play radius with a goal further out, the pull toward the centre wins.
		local edgePos = c + Vector3.new(a.radius, 0, 0)
		local dir = BattleRules.steerDirection(edgePos, edgePos + Vector3.new(100, 0, 0), a, {}, 28, false)
		h.ok(dir.X < 0, "edge: heads back in")
		local inner = BattleRules.steerDirection(c, c + Vector3.new(0, 30, -100), a, {}, 28, true)
		h.eq(inner.Y, 0, "cars stay flat")
		local apart = BattleRules.steerDirection(c, c + Vector3.new(0, 0, -100), a, { c + Vector3.new(5, 0, 0) }, 28, true)
		h.ok(apart.X < 0, "a neighbour on the right pushes it left")
	end)

	h.test("bot items: fire when aimed, drop traps on chasers, shield on threats, idle timeouts", function()
		h.eq(BattleRules.decideItem("missile", { targetDist = 150, targetDot = 0.95, heldFor = 1 }), true)
		h.eq(BattleRules.decideItem("missile", { targetDist = 150, targetDot = 0.2, heldFor = 1 }), false)
		h.eq(BattleRules.decideItem("missile", { targetDist = 300, targetDot = 0.7, heldFor = 10 }), true, "impatient")
		h.eq(BattleRules.decideItem("trap", { behindDist = 50, heldFor = 1 }), true)
		h.eq(BattleRules.decideItem("trap", { heldFor = 8 }), true)
		h.eq(BattleRules.decideItem("shield", { threatDist = 100, heldFor = 1 }), true)
		h.eq(BattleRules.decideItem("shield", { threatDist = 400, heldFor = 1 }), false)
		h.eq(BattleRules.decideItem("boost", { targetDist = 200, targetDot = 0.9, heldFor = 1 }), true)
		h.eq(BattleRules.decideItem("magnet", { targetDist = 120, heldFor = 1, magnetRange = 250 }), true)
		h.eq(BattleRules.decideItem("magnet", { targetDist = 30, heldFor = 1, magnetRange = 250 }), false, "already close")
		h.eq(BattleRules.formatClock(180), "3:00")
		h.eq(BattleRules.formatClock(0.2), "0:01")
		h.eq(BattleRules.timeLeft(100, 140), 0)
	end)

	---------------------------------------------------------------- 2. SurvivalRules

	local function field(): any
		return SurvivalRules.new({
			{ id = "player:1", isPlayer = true, slot = 2 },
			{ id = "bot:101", isPlayer = false, slot = 1 },
			{ id = "bot:102", isPlayer = false, slot = 3 },
			{ id = "bot:103", isPlayer = false, slot = 4 },
		}, 3)
	end

	h.test("survival: a landed hit costs one life; 0 lives is out; hits on the out change nothing", function()
		local st = field()
		h.eq(SurvivalRules.livesOf(st, "player:1"), 3)
		h.eq({ SurvivalRules.hit(st, "bot:101", "player:1", 10) }, { true, false })
		h.eq(SurvivalRules.livesOf(st, "bot:101"), 2)
		h.eq(st.entries["player:1"].hitsLanded, 1)
		SurvivalRules.hit(st, "bot:101", "player:1", 20)
		h.eq({ SurvivalRules.hit(st, "bot:101", "bot:102", 30) }, { true, true }, "third hit: out")
		h.ok(SurvivalRules.isOut(st, "bot:101"))
		h.eq(SurvivalRules.scoreText(st, "bot:101"), "OUT")
		h.eq({ SurvivalRules.hit(st, "bot:101", "player:1", 40) }, { false, false }, "out entrants take no hits")
		h.eq(SurvivalRules.livesOf(st, "bot:101"), 0)
		h.eq({ SurvivalRules.hit(st, "nobody", "player:1", 40) }, { false, false })
		-- A trap the victim dropped itself costs the life but credits nobody.
		SurvivalRules.hit(st, "bot:103", "bot:103", 50)
		h.eq(st.entries["bot:103"].hitsLanded, 0)
		h.eq(SurvivalRules.scoreText(st, "player:1"), "3 LIVES")
		SurvivalRules.hit(st, "player:1", "bot:102", 60)
		SurvivalRules.hit(st, "player:1", "bot:102", 61)
		h.eq(SurvivalRules.scoreText(st, "player:1"), "1 LIFE")
	end)

	h.test("survival: last entrant with lives wins at once", function()
		local st = field()
		h.eq(SurvivalRules.checkEnd(st, true).over, false)
		for k, id in { "bot:101", "bot:102" } do
			for t = 1, 3 do
				SurvivalRules.hit(st, id, "player:1", k * 10 + t) -- bot:101 out at 13, bot:102 at 23
			end
		end
		h.eq(SurvivalRules.checkEnd(st, true).over, false, "player and bot:103 still in")
		for t = 31, 33 do
			SurvivalRules.hit(st, "bot:103", "player:1", t)
		end
		local o = SurvivalRules.checkEnd(st, true)
		h.eq(o.over, true)
		h.eq(o.winner, "player:1")
		h.eq(o.reason, "last standing")
		h.eq(SurvivalRules.ranking(st), { "player:1", "bot:103", "bot:102", "bot:101" }, "later exits rank higher")
	end)

	h.test("survival: every player out ends it; the bots are ranked by the cap rule", function()
		local st = field()
		SurvivalRules.hit(st, "bot:102", "bot:101", 5)
		for t = 10, 12 do
			SurvivalRules.hit(st, "player:1", "bot:101", t)
		end
		h.eq(SurvivalRules.checkEnd(st, false).over, false, "without the flag the bots fight on")
		local o = SurvivalRules.checkEnd(st, true)
		h.eq(o.over, true)
		h.eq(o.reason, "no players left")
		h.eq(o.winner, "bot:101", "3 lives and 4 hits landed beats bot:103 on hits landed")
	end)

	h.test("survival cap: most lives wins; ties go to the longest hit-free, then hits landed, player, slot", function()
		local st = field()
		-- Everyone at 2 lives; the player lost its life first (t=5): hit-free the longest.
		SurvivalRules.hit(st, "player:1", "bot:101", 5)
		SurvivalRules.hit(st, "bot:101", "bot:102", 20)
		SurvivalRules.hit(st, "bot:102", "bot:103", 30)
		SurvivalRules.hit(st, "bot:103", "player:1", 40)
		local o = SurvivalRules.resolveCap(st)
		h.eq(o.winner, "player:1")
		h.eq(o.reason, "time")
		h.eq(SurvivalRules.ranking(st), { "player:1", "bot:101", "bot:102", "bot:103" })
		-- More lives beats any tie-break.
		local st2 = field()
		SurvivalRules.hit(st2, "player:1", "bot:101", 1)
		h.eq(SurvivalRules.resolveCap(st2).winner, "bot:101", "never hit, then hits landed (1) over bot:102/103")
		-- Never hit beats hit; equal records fall to player-over-bot, then the lower slot.
		local st3 = field()
		h.eq(SurvivalRules.resolveCap(st3).winner, "player:1", "all clean and equal: the player")
		local st4 = SurvivalRules.new({
			{ id = "bot:102", isPlayer = false, slot = 3 },
			{ id = "bot:101", isPlayer = false, slot = 1 },
		}, 3)
		h.eq(SurvivalRules.resolveCap(st4).winner, "bot:101", "lower slot")
	end)

	h.test("survival: a player who leaves forfeits (out, nobody credited) and can end the battle", function()
		local st = SurvivalRules.new({
			{ id = "player:1", isPlayer = true, slot = 1 },
			{ id = "player:2", isPlayer = true, slot = 2 },
		}, 3)
		h.ok(SurvivalRules.eliminate(st, "player:2", 15))
		h.eq(SurvivalRules.eliminate(st, "player:2", 16), false, "already out")
		local o = SurvivalRules.checkEnd(st, true)
		h.eq(o.over, true)
		h.eq(o.winner, "player:1")
		h.eq(st.entries["player:1"].hitsLanded, 0)
	end)

	---------------------------------------------------------------- 3. Keys and the battle unlock

	h.test("keys: one per chain zone track in race / quick race / time trial; never SPACE-4, the hub or other modes", function()
		h.ok(KeyPickup.eligible(snow, "race"))
		h.ok(KeyPickup.eligible(snow, "quickrace"))
		h.ok(KeyPickup.eligible(forest, "timetrial"))
		h.ok(KeyPickup.eligible(island, "race"))
		for _, mode in { "boss", "rematch", "coin", "battle", "hub" } do
			h.ok(not KeyPickup.eligible(snow, mode), "no key in " .. mode)
		end
		h.ok(not KeyPickup.eligible(space, "race"), "no key on SPACE-4 (no fifth battle)")
		h.ok(not KeyPickup.eligible(hub, "race"), "no key on the hub")
		-- DINO-4 takes the key wherever the plan places it.
		h.eq(KeyPickup.eligible(dino, "race"), dino.hiddenKey ~= nil)
		local fakeDino = table.clone(dino)
		fakeDino.hiddenKey = { pos = Vector3.new(0, 100, 0) }
		h.ok(KeyPickup.eligible(fakeDino, "race"))
		h.eq(KeyPickup.radiusFor("plane"), KeyPickup.RADIUS_PLANE)
		h.eq(KeyPickup.radiusFor("car"), KeyPickup.RADIUS_CAR)
		h.ok(KeyPickup.RADIUS_PLANE > KeyPickup.RADIUS_CAR, "planes pass faster: larger radius")
	end)

	local function newSave(): any
		local sched = h.newScheduler()
		local svc = SaveService.new({
			store = SaveService.newMemoryStore({}),
			sessionId = "battle-spec",
			newToken = function(): string
				return "battle-spec-token"
			end,
			now = sched.clock,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = function(_line: string) end,
			random = function(): number
				return 0.5
			end,
			config = { writeCooldown = 0 },
		})
		return { sched = sched, svc = svc }
	end

	h.test("keys: pickup inside the radius saves the key once, opens the battle, never touches tokens", function()
		local env = newSave()
		local p = h.fakePlayer(4242, "KeyFinder")
		env.sched.run(function()
			return env.svc.load(p)
		end)
		-- SNOW needs one token for its portal: win DINO-4 first (a legal profile).
		h.eq(env.svc.award(p, "token", "race:DINO-4", "race_finish"), "awarded")
		local awards, notes = {}, {}
		local st = KeyPickup.start(nil, snow, "race", "plane", {
			records = function()
				return {}
			end,
			award = function(player: any, zone: string, source: string): (string, { string })
				table.insert(awards, zone .. "|" .. source)
				return env.svc.award(player, "key", zone, source)
			end,
			notify = function(_player: any, payload: any)
				table.insert(notes, payload)
			end,
			log = function(_line: string) end,
		})
		h.ok(st, "a key is placed on SNOW-1")
		h.eq(st.zone, "SNOW")
		h.eq(st.radius, KeyPickup.RADIUS_PLANE)
		local before = env.svc.get(p)
		h.ok(not Progression.isModeUnlocked(before, "SNOW-1", "battle"), "battle hidden before the key")
		h.eq(KeyPickup.check(st, p, st.pos + Vector3.new(KeyPickup.RADIUS_PLANE + 1, 0, 0)), nil, "out of reach")
		h.eq(KeyPickup.check(st, p, st.pos + Vector3.new(5, 0, 0)), "awarded")
		h.eq(awards, { "SNOW|key_pickup:SNOW-1" })
		h.eq(#notes, 1)
		h.eq(notes[1].zone, "SNOW")
		h.contains(notes[1].unlocked, "mode:SNOW-1:battle")
		h.eq(KeyPickup.check(st, p, st.pos), nil, "collected once per session")
		h.eq(#awards, 1)
		local after = env.svc.get(p)
		h.ok(after.keys.SNOW, "saved on pickup")
		h.ok(Progression.isModeUnlocked(after, "SNOW-1", "battle"), "battle opens with the key alone")
		h.eq(Progression.tokenCount(after), 1, "a key is not a token")
		h.ok(not Progression.isPortalOpen(after, "ISLAND"), "thresholds unchanged by keys")
		-- A held key on a fresh load: the save says noop and nothing is announced.
		local st2 = KeyPickup.start(nil, snow, "timetrial", "plane", {
			records = function()
				return {}
			end,
			award = function(player: any, zone: string, source: string): (string, { string })
				return env.svc.award(player, "key", zone, source)
			end,
			notify = function(_player: any, payload: any)
				table.insert(notes, payload)
			end,
			log = function(_line: string) end,
		})
		h.eq(KeyPickup.check(st2, p, st2.pos), "noop")
		h.eq(#notes, 1, "no second toast")
		KeyPickup.stop()
		h.ok(not KeyPickup.isActive())
	end)

	h.test("keys: a fast pass between two 10 Hz checks still collects; a teleport across does not; a save error asks once", function()
		local calls = 0
		local fail = false
		local function start(): any
			return KeyPickup.start(nil, snow, "race", "plane", {
				records = function()
					return {}
				end,
				award = function(_player: any, _zone: string, _source: string): (string, { string })
					calls += 1
					if fail then
						error("store down")
					end
					return "awarded", {}
				end,
				notify = function() end,
				log = function(_line: string) end,
			})
		end
		local p = h.fakePlayer(9001, "Streak")
		local st = start()
		-- Overcharge pace (210 studs/s) is 21 studs per check; this pass is 36 studs long, 5 studs off the key, and both
		-- samples sit outside the radius.
		local a, b = st.pos + Vector3.new(-18, 0, 5), st.pos + Vector3.new(18, 0, 5)
		h.ok((a - st.pos).Magnitude > st.radius and (b - st.pos).Magnitude > st.radius, "both samples out of reach")
		h.eq(KeyPickup.check(st, p, a, nil), nil, "first sample alone: out of reach")
		h.eq(KeyPickup.check(st, p, b, a), "awarded", "the path between the samples passed the key")
		h.eq(calls, 1)
		-- A respawn teleport across the key is not a flown path: only where it lands counts.
		local q = h.fakePlayer(9002, "Warp")
		local st2 = start()
		h.eq(KeyPickup.check(st2, q, st2.pos + Vector3.new(40, 0, 5), st2.pos + Vector3.new(-100, 0, 5)), nil, "teleport")
		h.eq(calls, 1)
		-- A save that throws is asked once per load, not every tick while the plane sits at the key.
		fail = true
		local r = h.fakePlayer(9003, "Parked")
		local st3 = start()
		h.eq(KeyPickup.check(st3, r, st3.pos), nil, "error: no result")
		h.eq(KeyPickup.check(st3, r, st3.pos), nil)
		h.eq(calls, 2, "one save call for the error")
		KeyPickup.stop()
	end)

	h.test("battle fragment: needs the key, awards once, four complete the Battle Amulet", function()
		local env = newSave()
		local p = h.fakePlayer(777, "Amulet")
		env.sched.run(function()
			return env.svc.load(p)
		end)
		h.eq(env.svc.award(p, "battle", "DINO", "battle_win:DINO-4"), "rejected", "no key, no battle")
		local opened: { string } = {}
		for _, zone in Progression.CHAIN_ZONES do
			h.eq(env.svc.award(p, "key", zone, "key_pickup"), if zone == "DINO" then "awarded" else "rejected", zone .. " key needs its portal")
		end
		h.eq(env.svc.award(p, "battle", "DINO", "battle_win:DINO-4"), "awarded")
		h.eq(env.svc.award(p, "battle", "DINO", "battle_win:DINO-4"), "noop", "a replay win gives no second fragment")
		h.eq(env.svc.get(p).battleFragments, 1)
		-- Open every portal the legal way, then the other three keys and battles.
		for _, track in { "DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1" } do
			env.svc.award(p, "token", "race:" .. track, "race_finish")
		end
		for _, find in Progression.HUB_FINDS do
			env.svc.award(p, "hubFind", find, "hub")
		end
		local tokensBefore = Progression.tokenCount(env.svc.get(p))
		h.ok(Progression.isPortalOpen(env.svc.get(p), "FOREST"), "four tokens open FOREST")
		for _, zone in { "SNOW", "ISLAND", "FOREST" } do
			h.eq(env.svc.award(p, "key", zone, "key_pickup"), "awarded", zone)
			local result, unlocked = env.svc.award(p, "battle", zone, "battle_win")
			h.eq(result, "awarded", zone)
			opened = unlocked
		end
		h.contains(opened, "battleAmulet", "the fourth fragment completes the amulet")
		local prof = env.svc.get(p)
		h.ok(prof.battleAmulet)
		h.eq(prof.battleFragments, 4)
		h.eq(prof.cosmetics.owned[Progression.BATTLE_AMULET_LIVERY], true, "exclusive livery granted")
		h.eq(Progression.tokenCount(prof), tokensBefore, "keys and battle fragments are not tokens")
	end)

	---------------------------------------------------------------- 4. ItemEffects arena mode

	local function arenaWorld(): any
		local w: any = { t = 100, racers = {}, hits = {}, logs = {}, sent = {} }
		function w.add(id: string, pos: Vector3, forward: Vector3, botId: number?)
			w.racers[id] = { pos = pos, forward = forward, station = 0, progress = 0, active = true, isPlayer = botId == nil, botId = botId, plane = nil }
		end
		w.ctx = {
			now = function(): number
				return w.t
			end,
			order = function(): { string }
				return { "race:only" }
			end,
			racer = function(id: string): any
				return w.racers[id]
			end,
			course = function(st: number): (Vector3, Vector3)
				return Vector3.new(0, 0, -st), Vector3.new(0, 0, -1)
			end,
			isShielded = function(_id: string): boolean
				return false
			end,
			sendPlayer = function(id: string, kind: string, _payload: any)
				table.insert(w.sent, id .. ":" .. kind)
			end,
			broadcast = function() end,
			notifyUsed = function() end,
			applyToBot = function(botId: number, effect: any)
				table.insert(w.sent, "bot" .. botId .. ":" .. effect.kind)
			end,
			spawnVisual = function(): any
				return nil
			end,
			moveVisual = function() end,
			destroyVisual = function() end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
		}
		w.fx = ItemEffects.new(w.ctx)
		return w
	end

	-- The target sits 22 studs off the line of fire, 160 ahead: a straight shot (seekDeg 0) passes it by.
	local function fireAtOffsetTarget(seekDeg: number?): any
		local w = arenaWorld()
		w.add("player:1", Vector3.new(0, 50, 0), Vector3.new(0, 0, -1))
		w.add("bot:101", Vector3.new(22, 50, -160), Vector3.new(0, 0, 1), 101)
		local targeted = {}
		w.targeted = targeted
		w.fx.setArena({
			seekDeg = seekDeg,
			order = function(): { string }
				return { "player:1", "bot:101" }
			end,
			target = function(id: string): string?
				table.insert(targeted, id)
				return if id == "player:1" then "bot:101" else "player:1"
			end,
			onHit = function(victim: string, attacker: string, source: string, _pos: Vector3)
				table.insert(w.hits, victim .. "<" .. attacker .. ":" .. source)
			end,
		})
		w.fx.hooks.spawnMissile("player:1", ItemRules.effectFor("red", 1).missile, 1)
		for _ = 1, 60 do
			w.t += 1 / 30
			w.fx.step(1 / 30)
		end
		return w
	end

	h.test("arena items: a level-one missile curves to the arena's target and the hit reaches onHit", function()
		h.eq(ItemRules.effectFor("red", 1).missile.freeHoming, false, "level one is the unguided arena shot (v2 rule kept in arenas)")
		local straight = fireAtOffsetTarget(0)
		h.eq(straight.hits, {}, "no seek: the straight shot misses")
		local w = fireAtOffsetTarget(nil)
		h.eq(w.targeted, { "player:1" }, "the arena picked the target at the press")
		h.eq(w.hits, { "bot:101<player:1:missile" })
		h.contains(w.sent, "bot101:hit")
		h.eq((w.fx.counts()), 0, "the missile is spent")
	end)

	h.test("arena items: entrants outside the arena order are never hit; setArena(nil) is the race again", function()
		local w = arenaWorld()
		w.add("player:1", Vector3.new(0, 50, 0), Vector3.new(0, 0, -1))
		w.add("bot:101", Vector3.new(0, 50, -120), Vector3.new(0, 0, 1), 101)
		local onHits = 0
		w.fx.setArena({
			order = function(): { string }
				return { "player:1" } -- bot:101 is out of the battle
			end,
			target = function(_id: string): string?
				return nil
			end,
			onHit = function()
				onHits += 1
			end,
		})
		w.fx.hooks.spawnMissile("player:1", ItemRules.effectFor("red", 1).missile, 1)
		for _ = 1, 45 do
			w.t += 1 / 30
			w.fx.step(1 / 30)
		end
		h.eq(onHits, 0, "an out entrant is not in the order: the shot passes through")
		h.eq(#w.sent, 0)
		w.fx.clear()
		w.fx.setArena(nil)
		h.contains(w.logs, "arena=off")
		-- Race behaviour again: a direct hit() never reports to the old arena.
		h.eq(w.fx.hit("bot:101", "player:1", "missile", 1.2, Vector3.new(0, 50, -120)), "hit")
		h.eq(onHits, 0)
	end)

	h.test("ItemEffects.turnToward: bounded, unit, no flip on a reversal", function()
		local v = ItemEffects.turnToward(Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), math.rad(10))
		h.ok(near(v.Magnitude, 1, 1e-6))
		h.ok(near(math.deg(math.acos(v:Dot(Vector3.new(0, 0, -1)))), 10, 1e-3))
		h.eq(ItemEffects.turnToward(Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), 0.2), Vector3.new(0, 0, -1))
	end)
end
