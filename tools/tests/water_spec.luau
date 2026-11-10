--!strict
-- Lune spec for the ISLAND water battle rules (LAUNCH_PROGRESSION 2b ISLAND-BATTLE; TEST_LIST_LAUNCH L73):
--   1. Tide from the REAL ISLAND-2 TrackData: levels over time, the smooth climb, phases, HUD text, warn / rise /
--      settled marks, the HIGH GROUND nudge, and which ground each step closes (shallows, sandbars, dune, decks).
--   2. Drowning: the grace sample, immunity after a drown, and the lives composed from SurvivalRules (a drown costs a
--      life and credits nobody; out and last standing are survival's).
--   3. Spawn choice: the highest dry pad (the REAL pads' ground), fallbacks, an arena bot passing over the deck pad;
--      the safe spawn (trap audit G1: never the deck, away from the drown point and the rivals, near a boundary
--      exit), respawn headings with an authored look; the stuck watchdog.
--   4. Ground grid: dry share shrinking per level, dry paths, the dry-goal picker, regroup cells, respawn headings.
--   5. Gangways and decks from the REAL data, the Dubins line-up and a kinematic car bot (BattleBots cruise speed and
--      turn rate, BattleRules steering) boarding both gangways from many poses without leaving the ramp.
--   6. Bot goals: flee, pods on dry ground, hunt, patrol, stay on the decks, board on a ramp; at launch a beach bot
--      plans nothing onto the galleon (deck pods up a gangway only with Course.board); regroup instead of the centre.
-- Run: tools/tests/run_lune_tests.sh tools/tests/water_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
	logs: { string },
}

return function(h: Harness)
	local BattleRules = h.require("src/shared/battle/BattleRules.luau")
	local SurvivalRules = h.require("src/shared/battle/SurvivalRules.luau")
	local WaterRules = h.require("src/shared/battle/WaterRules.luau")
	local island = h.require("build/island2/TrackData.luau")
	-- The rules run on the v27 arena (deck pad last, deck pods, the 150 disc): the live arena has neither since owner
	-- 2026-10-21 (tools/tests/fixtures/island2_v27_battle.luau); section 7 checks the LIVE data.
	local LIVE = island.modes.battle
	local battle = h.require("tools/tests/fixtures/island2_v27_battle.luau")(LIVE)
	local arena = BattleRules.arena(battle)
	-- The REAL deck pad: the last spawn (tools/map/author_island2.py, trap audit G1 seat order).
	local DECK_PAD = #battle.spawns

	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-6)
	end

	-- Ground under the REAL ISLAND-2 pads (deck, gangway sandbar, shallows, dune), as the plan authored them
	-- (tools/map/author_island2.py: main deck y 32, sandbar +0.7, the shallows' terrain 18.98, the dune 23.25).
	local PAD_GROUND = { 32.0, 20.7, 18.98, 23.25 }

	-- A synthetic ground grid: height = f(x, z) over a 150-stud arena at the ISLAND-2 centre.
	local function gridOf(f: (number, number) -> number?, cell: number?): any
		local g = WaterRules.newGrid(arena.center, arena.radius + 12, cell or 6)
		for _, c in WaterRules.cells(g) do
			WaterRules.setHeight(g, c.index, f(c.x, c.z))
		end
		return g
	end
	local cx, cz = arena.center.X, arena.center.Z
	-- A beach: shallows (19) on the west, rising to a dry crest (25) on the east half.
	local function beach(x: number, _z: number): number
		return 19 + math.clamp((x - cx + 20) / 40, 0, 1) * 6
	end

	---------------------------------------------------------------- 1. Tide

	h.test("tide: ISLAND-2 base 20, three steps 50/100/140 s to 21.5/23/24.5, drown depth 2.2", function()
		local tide = WaterRules.tide(battle)
		h.eq(tide.base, 20)
		h.eq(#tide.steps, 3)
		h.eq({ tide.steps[1].at, tide.steps[2].at, tide.steps[3].at }, { 50, 100, 140 })
		h.eq({ tide.steps[1].level, tide.steps[2].level, tide.steps[3].level }, { 21.5, 23, 24.5 })
		h.eq(tide.drownDepth, 2.2)
		h.eq(tide.rise, WaterRules.RISE_SECONDS)
	end)

	h.test("tide: normalised (sorted, renumbered, never falling, defaults)", function()
		local tide = WaterRules.tide({
			center = Vector3.new(0, 7, 0),
			tideSteps = { { atSeconds = 90, level = 9, step = 7 }, { at = 30, level = 12 }, { atSeconds = 60 }, "junk" },
		})
		h.eq(tide.base, 7, "no baseLevel: the arena centre height")
		h.eq(#tide.steps, 2, "a step without a level is dropped")
		h.eq(tide.steps[1].at, 30)
		h.eq(tide.steps[1].step, 1)
		h.eq(tide.steps[2].step, 2)
		h.eq(tide.steps[2].level, 12, "a later step never lowers the water")
		h.eq(tide.drownDepth, WaterRules.DEFAULT_DROWN)
		local none = WaterRules.tide(nil)
		h.eq(#none.steps, 0)
		h.eq(WaterRules.levelAt(none, 500), none.base)
		h.eq(WaterRules.tideText(none, 10), "")
	end)

	h.test("tide level: base until a step, a smooth monotonic climb over the rise, then the step's level", function()
		local tide = WaterRules.tide(battle)
		h.eq(WaterRules.levelAt(tide, -3), 20)
		h.eq(WaterRules.levelAt(tide, 50), 20)
		h.ok(near(WaterRules.levelAt(tide, 52), 20.75), "halfway through the climb: halfway up")
		h.eq(WaterRules.levelAt(tide, 54), 21.5)
		h.eq(WaterRules.levelAt(tide, 99), 21.5)
		h.eq(WaterRules.levelAt(tide, 104), 23)
		h.eq(WaterRules.levelAt(tide, 144), 24.5)
		h.eq(WaterRules.levelAt(tide, 180), 24.5)
		local prev = -math.huge
		for t = 0, 180, 0.25 do
			local l = WaterRules.levelAt(tide, t)
			h.ok(l >= prev - 1e-9, "never falls at t=" .. t)
			prev = l
		end
		h.eq(WaterRules.levelAhead(tide, 45, 10), 21.5, "a bot 5 s before step 1 plans for the risen water")
		local instant = WaterRules.tide(battle, 0)
		h.eq(WaterRules.levelAt(instant, 50), 21.5, "no rise time: the step is up at once")
	end)

	h.test("tide phases and HUD text: countdown, rising, next step, high tide", function()
		local tide = WaterRules.tide(battle)
		h.eq(WaterRules.tideText(tide, 0), "TIDE 1/3 IN 0:50")
		h.eq(WaterRules.tideText(tide, 49.2), "TIDE 1/3 IN 0:01")
		h.eq(WaterRules.tideText(tide, 51), "TIDE 1/3 RISING")
		h.eq(WaterRules.tideText(tide, 54), "TIDE 2/3 IN 0:46")
		h.eq(WaterRules.tideText(tide, 139), "TIDE 3/3 IN 0:01")
		h.eq(WaterRules.tideText(tide, 150), "HIGH TIDE")
		local ph = WaterRules.phaseAt(tide, 101)
		h.eq(ph.started, 2)
		h.ok(ph.rising and ph.rising.step == 2, "step 2 rising")
		h.ok(ph.nextStep and ph.nextStep.step == 3, "step 3 next")
		h.ok(near(ph.untilNext, 39))
		h.eq(WaterRules.hudText(3, "TIDE 1/3 IN 0:50", false), "LIVES 3  -  TIDE 1/3 IN 0:50")
		h.eq(WaterRules.hudText(1, "HIGH TIDE", true), "LIVES 1  -  HIGH TIDE  -  HIGH GROUND!")
		h.eq(WaterRules.hudText(2, "", false), "LIVES 2")
	end)

	h.test("tide marks: warn 8 s ahead, rise, settled; each once across incremental windows, in order", function()
		local tide = WaterRules.tide(battle)
		local all = WaterRules.events(tide, 0, 200)
		local seq = {}
		for _, ev in all do
			table.insert(seq, string.format("%s%d@%g", ev.kind, ev.step.step, ev.at))
		end
		h.eq(seq, { "warn1@42", "rise1@50", "settled1@54", "warn2@92", "rise2@100", "settled2@104", "warn3@132", "rise3@140", "settled3@144" })
		local n, t = 0, 0
		while t < 200 do
			n += #WaterRules.events(tide, t, t + 1 / 60)
			t += 1 / 60
		end
		h.eq(n, 9, "frame by frame, every mark fires exactly once")
		h.eq(#WaterRules.events(tide, 54, 54), 0, "an empty window")
		local quiet = WaterRules.events(tide, 10, 10 + 1 / 60)
		h.ok(quiet == WaterRules.events(tide, 60, 60 + 1 / 60) and #quiet == 0, "a frame without a mark allocates nothing (one shared empty list)")
		h.ok(table.isfrozen(quiet), "and nobody can add to it")
		h.ok(WaterRules.events(tide, 99, 101) ~= quiet, "a frame with a mark gets its own list")
		local early = WaterRules.tide({ baseLevel = 0, tideSteps = { { atSeconds = 5, level = 2 } } })
		local marks = WaterRules.events(early, 0, 10)
		h.eq(#marks, 2, "a warn mark at or before GO is skipped")
		h.eq(marks[1].kind, "rise")
	end)

	h.test("tide closes the ground step by step: shallows, then sandbars, never the dune or the decks", function()
		local tide = WaterRules.tide(battle)
		local dd = tide.drownDepth
		local shallows, sandbar, dune, deck = PAD_GROUND[3], PAD_GROUND[2], PAD_GROUND[4], PAD_GROUND[1]
		h.ok(WaterRules.isDry(shallows, 20, dd), "the shallows are drivable at the base level (bed 1 stud under)")
		h.ok(not WaterRules.isDry(shallows, 21.5, dd), "step 1 closes the shallows")
		h.ok(WaterRules.isDry(sandbar, 21.5, dd), "the sandbars hold at step 1")
		h.ok(not WaterRules.isDry(sandbar, 23, dd), "step 2 closes the sandbars (and the gangway feet)")
		h.ok(WaterRules.isDry(dune, 24.5, dd), "the dune crest stays dry at high tide")
		h.ok(WaterRules.isDry(deck, 24.5, dd), "the decks stay dry")
		h.ok(WaterRules.isDry(20, 22.2, 2.2), "exactly the drown depth is still drivable")
		h.ok(not WaterRules.isDry(20, 22.21, 2.2))
		h.ok(not WaterRules.isDry(20, 21.9, 2.2, 0.4), "a margin asks for more")
		h.ok(not WaterRules.inDanger(tide, 30, shallows), "no step near: no nudge")
		h.ok(WaterRules.inDanger(tide, 43, shallows), "inside the warn window for the step that floods it")
		h.ok(WaterRules.inDanger(tide, 51, shallows), "while that step rises")
		h.ok(not WaterRules.inDanger(tide, 43, sandbar), "the sandbar survives step 1")
		h.ok(WaterRules.inDanger(tide, 93, sandbar), "but not step 2")
		h.ok(not WaterRules.inDanger(tide, 139, dune), "the dune never")
		h.ok(WaterRules.inDanger(tide, 10, 15), "ground already under water")
	end)

	---------------------------------------------------------------- 2. Drowning and lives

	h.test("drown watch: a short dip is no drown; under for the grace is; immune after; surfacing resets", function()
		local w = WaterRules.newWatch()
		local dd = 2.2
		h.ok(not WaterRules.sample(w, "p", 2.5, dd, 10.0), "first sample under")
		h.ok(not WaterRules.sample(w, "p", 2.5, dd, 10.1), "under for 0.1 s")
		h.ok(not WaterRules.sample(w, "p", 1.0, dd, 10.12), "surfaced: the clock resets")
		h.ok(not WaterRules.sample(w, "p", 2.5, dd, 10.2))
		h.ok(WaterRules.sample(w, "p", 2.5, dd, 10.35), "under for the grace: drowned")
		h.eq(w.drowns.p, 1)
		local free = 10.35 + WaterRules.IMMUNE
		h.ok(not WaterRules.sample(w, "p", 5, dd, 11), "immune while the respawn replicates")
		h.ok(not WaterRules.sample(w, "p", 5, dd, free - 0.05))
		h.ok(not WaterRules.sample(w, "p", 5, dd, free + 0.05), "immunity over: a fresh grace starts")
		h.ok(WaterRules.sample(w, "p", 5, dd, free + 0.25))
		h.eq(w.drowns.p, 2)
		-- CarController drops a CheckpointRespawn to the pad it respawned on within LATE_REPLY_WINDOW (3 s) as a stale
		-- reply: a second tide respawn to the same pad must come later than that, or the car would stay in the water.
		h.ok(WaterRules.IMMUNE + WaterRules.GRACE >= 3 + 0.5, "immunity clears the client's late-reply window")
		h.ok(not WaterRules.sample(w, "p", 2.2, dd, 20), "exactly the drown depth is shallow")
		h.ok(WaterRules.sample(w, "q", 3, dd, 1, 0), "grace 0: at once")
		WaterRules.shield(w, "r", 50)
		h.ok(not WaterRules.sample(w, "r", 9, dd, 49, 0), "shielded")
		h.ok(WaterRules.sample(w, "r", 9, dd, 50, 0), "shield over")
	end)

	h.test("drown lives are SurvivalRules: one life each, nobody credited, out at zero, last standing wins", function()
		local lives = SurvivalRules.new({
			{ id = "player:1", isPlayer = true, slot = 3 },
			{ id = "bot:101", isPlayer = false, slot = 1 },
			{ id = "bot:102", isPlayer = false, slot = 2 },
		}, 3)
		local lost, out = WaterRules.drown(lives, "player:1", 54)
		h.ok(lost and not out)
		h.eq(SurvivalRules.livesOf(lives, "player:1"), 2)
		SurvivalRules.hit(lives, "bot:101", "player:1", 60) -- an item hit, credited
		h.eq(lives.entries["player:1"].hitsLanded, 1, "the item hit is credited")
		WaterRules.drown(lives, "bot:101", 61)
		h.eq(lives.entries["player:1"].hitsLanded, 1, "a drown credits nobody")
		WaterRules.drown(lives, "bot:101", 104)
		h.ok(SurvivalRules.isOut(lives, "bot:101"), "item hit + two drowns = out")
		h.eq(select(1, WaterRules.drown(lives, "bot:101", 105)), false, "the out lose nothing more")
		h.ok(not SurvivalRules.checkEnd(lives, true).over)
		WaterRules.drown(lives, "bot:102", 140)
		WaterRules.drown(lives, "bot:102", 141)
		local _, out3 = WaterRules.drown(lives, "bot:102", 144)
		h.ok(out3)
		local outcome = SurvivalRules.checkEnd(lives, true)
		h.ok(outcome.over and outcome.winner == "player:1" and outcome.reason == "last standing")
	end)

	---------------------------------------------------------------- 3. Spawns

	h.test("spawn after a drown: the highest dry pad (the deck); ties keep order; nothing dry -> highest", function()
		h.eq(WaterRules.pickSpawn(PAD_GROUND, 21.5, 2.2), 1, "the deck pad")
		h.eq(WaterRules.pickSpawn(PAD_GROUND, 24.5, 2.2), 1)
		h.eq(WaterRules.pickSpawn({ 20.7, 18.98, 23.25 }, 24.5, 2.2), 3, "without the deck: the dune")
		h.eq(WaterRules.pickSpawn({ 20.7, 18.98, 20.9 }, 24.5, 2.2), 3, "none dry: the highest anyway")
		h.eq(WaterRules.pickSpawn({ 23, 23 }, 21, 2.2), 1, "a tie keeps the lower pad")
		h.eq(WaterRules.pickSpawn({ 19, 23, 21 }, 21.5, 2.2), 2)
		h.eq(WaterRules.pickSpawn({}, 21.5, 2.2), nil)
	end)

	h.test("spawn for an arena bot: the deck pad is passed over while a beach pad is dry", function()
		local deck = { [1] = true }
		h.eq(WaterRules.pickSpawn(PAD_GROUND, 20, 2.2, deck), 4, "base level: the dune, the highest beach pad")
		h.eq(WaterRules.pickSpawn(PAD_GROUND, 24.5, 2.2, deck), 4, "high tide: the dune stays dry")
		h.eq(WaterRules.pickSpawn(PAD_GROUND, 26, 2.2, deck), 1, "no beach pad dry: the deck after all")
		h.eq(WaterRules.pickSpawn(PAD_GROUND, 24.5, 2.2, { [1] = true, [4] = true }), 1, "nothing else dry: an avoided dry pad")
		h.eq(WaterRules.pickSpawn(PAD_GROUND, 21.5, 2.2, { [1] = true, [4] = true }), 2, "the sandbar before step 2")
		h.eq(WaterRules.pickSpawn({ 18, 19 }, 24.5, 2.2, { [2] = true }), 2, "none dry: the highest anyway")
	end)

	-- The REAL pads and their ground (TrackData spawns, ground as the plan authors it: crest B, the Plank Dune, the
	-- shallows, the beach dune, spit pad A, the deck), for the safe-spawn rule (trap audit G1 / I2-01, I2-10).
	local PADS = arena.spawns
	local GROUNDS = { 23.96, 24.6, 18.98, 23.25, 24.6, 32.0 }
	local DECK_AVOID = { [DECK_PAD] = true }

	h.test("safe spawn: dry through the step, never the deck, at least SAFE_CLEAR from the drown point", function()
		h.eq(#PADS, #GROUNDS, "one ground per REAL pad")
		for _, level in { 20, 21.5, 23, 24.5 } do
			local slot = WaterRules.pickSafeSpawn(PADS, GROUNDS, level, 2.2, { avoid = DECK_AVOID, from = PADS[3] })
			h.ok(slot ~= nil and slot ~= DECK_PAD, "never the deck at " .. level)
			h.ok(WaterRules.isDry(GROUNDS[slot :: number], level, 2.2), "dry at " .. level)
			h.ok(BattleRules.horizontal(PADS[slot :: number], PADS[3]) >= WaterRules.SAFE_CLEAR, "away from the drown point at " .. level)
		end
		-- Drowned right on the Plank Dune pad: never handed straight back to it.
		local again = WaterRules.pickSafeSpawn(PADS, GROUNDS, 24.5, 2.2, { avoid = DECK_AVOID, from = PADS[2] })
		h.ok(again ~= 2, "not the pad it drowned on")
		-- Nothing off the deck dry (a hypothetical flood over everything but the decks): the deck after all.
		h.eq(WaterRules.pickSafeSpawn(PADS, GROUNDS, 27, 2.2, { avoid = DECK_AVOID }), DECK_PAD, "no beach pad dry: the deck")
		h.eq(WaterRules.pickSafeSpawn({}, {}, 21.5, 2.2, nil), nil, "no pads")
		-- Every other pad within SAFE_CLEAR of the drown point: the clearance gives way rather than the dryness.
		h.eq(WaterRules.pickSafeSpawn({ PADS[1], PADS[1] + Vector3.new(5, 0, 0) }, { 24, 19 }, 21.5, 2.2, { from = PADS[1] }), 1, "the only dry pad, even close")
	end)

	h.test("safe spawn: farthest from the live rivals, so drowned bots never stack on one pad (I2-10)", function()
		-- Three bots on the beach dune: the Plank Dune (139 studs off) beats crest B (86) and spit pad A (81).
		local dune = PADS[4]
		local slot = WaterRules.pickSafeSpawn(PADS, GROUNDS, 21.5, 2.2, { avoid = DECK_AVOID, from = PADS[3], rivals = { dune, dune, dune } })
		h.eq(slot, 2, "the Plank Dune")
		-- Someone now waits there: the next drown goes elsewhere.
		local second = WaterRules.pickSafeSpawn(PADS, GROUNDS, 21.5, 2.2, { avoid = DECK_AVOID, from = PADS[3], rivals = { dune, PADS[2] } })
		h.ok(second ~= 2 and second ~= 4, "not onto a pad someone stands on")
		-- Far rivals all count the same (RIVAL_CAP): the higher ground decides.
		local far = Vector3.new(cx + 5000, 20, cz)
		local high = WaterRules.pickSafeSpawn(PADS, GROUNDS, 21.5, 2.2, { avoid = DECK_AVOID, rivals = { far } })
		h.ok(high == 2 or high == 5, "a tie on rivals goes to the highest beach pad (24.6)")
	end)

	h.test("safe spawn for a boundary return: the safe pad nearest where the car left (I2-05)", function()
		-- Out past the SE beach band: the nearest safe pad, never the flooded shallows pad beside it at 21.5.
		local out = Vector3.new(-5260, 22, 4395)
		local slot = WaterRules.pickSafeSpawn(PADS, GROUNDS, 21.5, 2.2, { avoid = DECK_AVOID, near = out }) :: number
		h.ok(slot ~= 3 and slot ~= DECK_PAD, "not the shallows (flooded) nor the deck")
		h.eq(slot, 4, "the beach dune, the nearest dry pad")
		-- Out at the cavern mouth road (st 270): crest B, not a pad across the cove.
		local cavern = Vector3.new(-5172, 28, 4100)
		h.eq(WaterRules.pickSafeSpawn(PADS, GROUNDS, 24.5, 2.2, { avoid = DECK_AVOID, near = cavern }), 1, "crest B")
	end)

	h.test("respawn headings: the authored look while dry ground runs along it, else the longest dry run", function()
		local g = gridOf(beach)
		local from = Vector3.new(cx + 40, 25, cz)
		local east = Vector3.new(1, 0, 0)
		local west = Vector3.new(-1, 0, 0)
		local list = WaterRules.respawnHeadings(g, from, 20, 2.2, 60, arena.center, nil, Vector3.new(0, 0, 1))
		h.ok((list[1] - Vector3.new(0, 0, 1)).Magnitude < 1e-6, "along the crest (dry): the authored look first")
		h.eq(#list, 17, "then the 16 directions as fallbacks")
		-- 10 studs up the beach from its middle: west, dry ground at 22 ends ~17 studs on (under LOOK_RUN).
		local low = Vector3.new(cx + 10, 25, cz)
		local wet = WaterRules.respawnHeadings(g, low, 22, 2.2, 60, arena.center, nil, west)
		h.ok((wet[1] - west).Magnitude > 0.5, "an authored look into the shallows is dropped")
		local onward = low + wet[1] * 50
		h.ok(WaterRules.isDry(WaterRules.heightAt(g, onward.X, onward.Z) :: number, 22, 2.2, WaterRules.SAFE_MARGIN), "the longest dry run instead (50 studs on is dry)")
		h.ok(list[1]:Dot(east) < 0.5, "(the authored look was not simply east)")
		h.ok((WaterRules.dryHeading(g, low, 22, 2.2, 60, arena.center) - wet[1]).Magnitude < 1e-6, "dryHeading is the best of the 16")
	end)

	h.test("stuck watchdog: a bot that stays within STUCK_MOVE for STUCK_SECONDS is reported, a moving one never", function()
		local m = WaterRules.newMotion()
		local p = Vector3.new(cx, 21, cz)
		h.ok(not WaterRules.stuck(m, "bot:101", p, 10), "the first sample opens the window")
		for t = 10.1, 10 + WaterRules.STUCK_SECONDS - 0.05, 0.1 do
			h.ok(not WaterRules.stuck(m, "bot:101", p + Vector3.new(3 * math.sin(t), 0, 0), t), "jittering in place, not yet")
		end
		h.ok(WaterRules.stuck(m, "bot:101", p, 10 + WaterRules.STUCK_SECONDS), "wedged")
		h.ok(not WaterRules.stuck(m, "bot:101", p, 10 + WaterRules.STUCK_SECONDS + 0.1), "the window restarts")
		h.ok(WaterRules.stuck(m, "bot:101", p, 10 + 2 * WaterRules.STUCK_SECONDS + 0.1), "still wedged: again")
		local pos = p
		for t = 20, 30, 1 / 30 do
			pos += Vector3.new(72 / 30, 0, 0) -- cruising
			h.ok(not WaterRules.stuck(m, "bot:102", pos, t), "a cruising bot")
		end
		local up = p + Vector3.new(0, 30, 0)
		WaterRules.stuck(m, "bot:103", p, 40)
		h.ok(WaterRules.stuck(m, "bot:103", up, 43.5), "only flat moves count: bobbing up and down in place is wedged")
		WaterRules.resetMotion(m, "bot:103")
		h.ok(not WaterRules.stuck(m, "bot:103", p, 50), "a reset opens a fresh window")
		h.ok(not WaterRules.stuck(m, "bot:103", p, 50 + WaterRules.STUCK_SECONDS - 0.01))
	end)

	---------------------------------------------------------------- 4. Ground grid

	h.test("grid: cells inside the radius, nearest-cell heights, the dry share shrinking with every step", function()
		local g = gridOf(beach)
		local cells = WaterRules.cells(g)
		h.ok(#cells > 1500 and #cells < 3000, "about pi r^2 / 36 cells: " .. #cells)
		for _, c in cells do
			h.ok(BattleRules.horizontal(Vector3.new(c.x, 0, c.z), arena.center) <= g.radius + 1e-6)
		end
		h.eq(WaterRules.heightAt(g, cx - 100, cz), 19)
		h.eq(WaterRules.heightAt(g, cx + 100, cz), 25)
		h.eq(WaterRules.heightAt(g, cx + 400, cz), nil, "outside the grid")
		local tide = WaterRules.tide(battle)
		local shares = {}
		for _, level in { tide.base, 21.5, 23, 24.5 } do
			local dry, total = WaterRules.dryShare(g, level, tide.drownDepth, arena.radius)
			h.ok(total > 0)
			table.insert(shares, dry / total)
		end
		h.eq(shares[1], 1, "all dry at the base level")
		for i = 2, #shares do
			h.ok(shares[i] < shares[i - 1], string.format("step %d shrinks the dry area (%.2f < %.2f)", i - 1, shares[i], shares[i - 1]))
		end
		h.ok(shares[4] > 0.3, "the crest stays")
		local mast = gridOf(function(x: number, z: number): number
			return if math.abs(x - cx) < 4 and math.abs(z - cz) < 4 then 110 else beach(x, z)
		end)
		local _, withMast = WaterRules.dryShare(mast, 20, 2.2, arena.radius)
		local _, noMast = WaterRules.dryShare(mast, 20, 2.2, arena.radius, 44)
		h.ok(noMast < withMast, "the ceiling leaves mast tops and cliffs out of the playable area")
		local _, inner = WaterRules.dryShare(g, 20, 2.2, 50)
		h.ok(inner < noMast, "within limits the radius")
	end)

	h.test("dry paths: flooded strips, walls and unknown ground block; gentle slopes do not", function()
		local g = gridOf(beach)
		local west, east = Vector3.new(cx - 80, 19, cz), Vector3.new(cx + 80, 25, cz)
		h.ok(WaterRules.pathClear(g, west, east, 20, 2.2), "base level: the beach slope is drivable")
		h.ok(not WaterRules.pathClear(g, west, east, 21.5, 2.2), "step 1: the start is under water")
		h.ok(WaterRules.pathClear(g, Vector3.new(cx + 30, 25, cz - 60), Vector3.new(cx + 30, 25, cz + 60), 24.5, 2.2), "along the crest")
		local wall = gridOf(function(x: number, z: number): number
			return if x > cx + 10 and x < cx + 40 then 32 else 23
		end)
		h.ok(not WaterRules.pathClear(wall, Vector3.new(cx - 40, 23, cz), Vector3.new(cx + 80, 23, cz), 20, 2.2), "a hull side is a wall")
		local holes = gridOf(function(x: number, _z: number): number?
			return if math.abs(x - cx) < 6 then nil else 23
		end)
		h.ok(not WaterRules.pathClear(holes, Vector3.new(cx - 40, 23, cz), Vector3.new(cx + 40, 23, cz), 20, 2.2), "no ground found = no way")
	end)

	h.test("dry goals: nearest dry ground when fleeing, ahead when patrolling, nil when nothing is dry", function()
		local g = gridOf(beach)
		local tide = WaterRules.tide(battle)
		local from = Vector3.new(cx - 40, 19, cz)
		local east = Vector3.new(1, 0, 0)
		h.eq(WaterRules.pickDryGoal(g, from, east, 19, 23, 21.5, tide.drownDepth, WaterRules.FLEE), nil, "no way out through deeper water")
		local flee = WaterRules.pickDryGoal(g, from, east, 19, 23, 20, tide.drownDepth, WaterRules.FLEE)
		h.ok(flee, "somewhere dry")
		h.ok(WaterRules.isDry((flee :: Vector3).Y, 23, tide.drownDepth, WaterRules.FLEE.margin), "dry at the planned level")
		h.ok((flee :: Vector3).X > from.X, "uphill, toward the crest")
		h.ok(BattleRules.horizontal(flee :: Vector3, from) < 70, "the nearest dry ground, not the far crest")
		local west = Vector3.new(-1, 0, 0)
		local flee2 = WaterRules.pickDryGoal(g, from, west, 19, 23, 20, tide.drownDepth, WaterRules.FLEE)
		h.ok(flee2 and (flee2 :: Vector3).X > from.X, "facing away it still turns for the dry side")
		local crest = Vector3.new(cx + 40, 25, cz)
		local north = Vector3.new(0, 0, 1)
		local patrol = WaterRules.pickDryGoal(g, crest, north, 25, 24.5, 24.5, tide.drownDepth, WaterRules.PATROL, arena.radius * 0.85)
		h.ok(patrol, "patrol ground")
		local p = patrol :: Vector3
		local d = BattleRules.horizontal(p, crest)
		h.ok(d >= WaterRules.PATROL.minDist and d <= WaterRules.PATROL.maxDist, "inside the patrol band: " .. d)
		h.ok(p.Z > crest.Z, "ahead of the bot")
		h.ok(WaterRules.pathClear(g, crest, p, 24.5, tide.drownDepth), "with a dry way there")
		h.ok(BattleRules.horizontal(p, arena.center) <= arena.radius * 0.85 + 1e-6, "inside the edge pull")
		local sea = gridOf(function(): number
			return 10
		end)
		h.eq(WaterRules.pickDryGoal(sea, from, east, 10, 21.5, 21.5, 2.2, WaterRules.FLEE), nil)
		local deck = gridOf(function(x: number, z: number): number
			return if x > cx - 20 and x < cx + 20 then 32 else 19
		end)
		h.eq(WaterRules.pickDryGoal(deck, from, east, 19, 23, 21.5, 2.2, WaterRules.FLEE), nil, "a deck 13 studs up is not a car's next step")
		local skipped = WaterRules.pickDryGoal(g, crest, north, 25, 24.5, 24.5, tide.drownDepth, WaterRules.PATROL, arena.radius * 0.85, function(_x: number, z: number): boolean
			return z > crest.Z
		end)
		h.ok(skipped and (skipped :: Vector3).Z <= crest.Z, "skipped cells are never picked")
	end)

	h.test("regroup: the nearest dry cell, path or not, inside the limit; nil when nothing is dry", function()
		local g = gridOf(beach)
		local from = Vector3.new(cx - 60, 19, cz)
		local dry = WaterRules.nearestDry(g, from, 21.5, 2.2, 0) :: Vector3
		h.ok(dry and WaterRules.isDry(WaterRules.heightAt(g, dry.X, dry.Z) :: number, 21.5, 2.2), "dry at the level")
		h.ok(dry.X > from.X and BattleRules.horizontal(dry, from) < 50, "the near edge of the dry side (42 studs), not the far crest")
		local inside = WaterRules.nearestDry(g, Vector3.new(cx + 160, 25, cz), 21.5, 2.2, 0, 100) :: Vector3
		h.ok(inside and BattleRules.horizontal(inside, arena.center) <= 100 + 1e-6, "inside the limit")
		h.eq(WaterRules.nearestDry(gridOf(function(): number
			return 10
		end), from, 21.5, 2.2, 0), nil)
	end)

	h.test("respawn heading: along the longest dry run, the arena centre on a tie", function()
		local g = gridOf(beach)
		local tide = WaterRules.tide(battle)
		-- On the crest at high tide the flood lies 25 studs west (toward the centre): the car faces dry ground.
		local crest = Vector3.new(cx + 30, 25, cz)
		local dir = WaterRules.dryHeading(g, crest, 24.5, tide.drownDepth, 60, arena.center)
		h.ok(dir.X > -0.9, string.format("not straight into the flood: (%.2f, %.2f)", dir.X, dir.Z))
		local ahead = crest + dir * 50
		h.ok(WaterRules.isDry(WaterRules.heightAt(g, ahead.X, ahead.Z) :: number, 24.5, tide.drownDepth), "50 studs on is still dry")
		h.ok(near(dir.Magnitude, 1, 1e-6) and dir.Y == 0, "flat unit")
		-- All dry: every direction runs the full reach, the centre wins the tie.
		local open = WaterRules.dryHeading(g, crest, 20, tide.drownDepth, 30, arena.center)
		h.ok(open.X < -0.99, "toward the centre on a tie")
		-- A deck strip 20 wide along Z: the car faces along it, not across into the drop.
		local strip = gridOf(function(x: number, _z: number): number
			return if math.abs(x - cx) <= 10 then 32 else 5
		end)
		local along = WaterRules.dryHeading(strip, Vector3.new(cx, 32, cz), 20, 2.2, 50, Vector3.new(cx + 100, 0, cz))
		h.ok(math.abs(along.Z) > 0.9, string.format("along the deck: (%.2f, %.2f)", along.X, along.Z))
	end)

	---------------------------------------------------------------- 5. Gangways, decks, boarding

	local course = WaterRules.course(battle, arena.center, arena.radius * 0.85, nil)
	local gws = course.gangways

	h.test("gangways and decks from the plan: two 48-stud ramps, the main deck at 32, deck pads and pods", function()
		h.eq(#gws, 2)
		for _, g in gws do
			h.ok(near(g.length, 48, 1e-3), "ramp run 48")
			h.ok(near(g.axis.Magnitude, 1, 1e-6) and g.axis.Y == 0)
			h.ok(near(g.top.Y, 32))
			-- The feet stand on the Plank Dune (trap audit G1), above the last tide step: never cut off by the tide.
			h.ok(g.foot.Y < g.top.Y - 4 and WaterRules.isDry(g.foot.Y, 24.5, 2.2, WaterRules.SAFE_MARGIN), "foot on the dune")
		end
		h.eq(gws[1].name, "GalleonGangwayFore")
		h.eq(course.deckY, 32)
		h.eq(WaterRules.deckY({}), nil)
		-- Since the trap audit (G1) the deck pad is the last: seats 1-4 (a 1 + 3 field) are never on the galleon.
		h.ok(WaterRules.onDeck(course, battle.spawns[DECK_PAD], 32), "the last pad is on the main deck")
		for i = 1, DECK_PAD - 1 do
			h.ok(not WaterRules.onDeck(course, battle.spawns[i], battle.spawns[i].Y - 4), "pad " .. i .. " is on the sand")
		end
		local quarter = battle.pickupAnchors[2]
		h.ok(WaterRules.onDeck(course, quarter, 40), "the quarterdeck pod")
		h.ok(not WaterRules.onDeck(course, battle.pickupAnchors[5], 19), "a beach pod")
		h.ok(not WaterRules.onDeck(course, Vector3.new(cx + 140, 40, cz), 40), "high ground far from the galleon is not the decks")
		local fore = gws[1]
		local mid = fore.foot:Lerp(fore.top, 0.5)
		local g, up = WaterRules.rampOf(course, mid, fore.axis)
		h.ok(g == fore and up, "half way up the fore gangway, heading up")
		local g2, up2 = WaterRules.rampOf(course, mid, -fore.axis)
		h.ok(g2 == fore and not up2, "heading down")
		h.eq((WaterRules.rampOf(course, mid + Vector3.new(-fore.axis.Z, 0, fore.axis.X) * 12, fore.axis)), nil, "beside the ramp")
	end)

	h.test("Dubins line-up: starts where the car is, ends on the pose and runs on along its heading", function()
		local p0, p1 = Vector3.new(0, 0, 0), Vector3.new(200, 0, 50)
		local a = WaterRules.dubinsPoint(p0, 0, p1, math.pi / 2, 40, 0)
		h.ok((a - p0).Magnitude < 1e-6, "distance 0 is the start")
		local prev = p0
		for d = 4, 400, 4 do
			local p = WaterRules.dubinsPoint(p0, 0, p1, math.pi / 2, 40, d)
			h.ok((p - prev).Magnitude <= 4 + 1e-3, "continuous at " .. d)
			h.ok((p - p0).Magnitude <= d + 1e-3, "never further than the distance driven")
			prev = p
		end
		local far = WaterRules.dubinsPoint(p0, 0, p1, math.pi / 2, 40, 2000)
		h.ok(near(far.X, 200, 1e-3) and far.Z > 50, "past the end: straight on along the pose heading")
		local straight = WaterRules.dubinsPoint(p0, 0, Vector3.new(100, 0, 0), 0, 40, 30)
		h.ok(near(straight.X, 30, 1e-3) and near(straight.Z, 0, 1e-3), "already lined up: straight ahead")
		local behind = WaterRules.dubinsPoint(p0, 0, Vector3.new(-100, 0, 0), math.pi, 40, 40 * math.pi)
		h.ok(behind.X < 1 and near(math.abs(behind.Z), 80, 1), "a goal behind: a U-turn on the turn radius")
	end)

	-- A kinematic car bot as BattleBots drives it (cruise 72 studs/s, 95 deg/s, BattleRules steering, a wall = hold
	-- and swing toward the centre): the basin beside the raised ramp and the hull side are walls.
	local function driveBoard(g: any, pos: Vector3, fwd: Vector3, seconds: number): (boolean, number, boolean)
		local function wall(p: Vector3): boolean
			local s, lat = WaterRules.rampCoords(g, p)
			return (s >= 30 and s <= g.length - 1 and lat > 4.5) or (s > g.length - 1 and s < g.length + 1.5 and lat > 5)
		end
		local dt = 1 / 30
		local t, speed = 0, 72
		local avoid, avoidDir = 0, Vector3.new(0, 0, 0)
		local leftRamp = false
		while t < seconds do
			t += dt
			local s, lat = WaterRules.rampCoords(g, pos)
			if s >= g.length + 4 and lat <= 6 then
				return true, t, leftRamp
			end
			local goal = WaterRules.routeStep(g, pos, fwd, true)
			local desired = BattleRules.steerDirection(pos, goal, arena, {}, 16, true)
			if avoid > 0 then
				avoid -= dt
				local b = desired + avoidDir * 1.6
				if b.Magnitude > 0.01 then
					desired = b.Unit
				end
			end
			fwd = BattleRules.turnToward(fwd, desired, math.rad(95) * dt)
			fwd = Vector3.new(fwd.X, 0, fwd.Z).Unit
			speed += (72 - speed) * math.clamp(dt * 4, 0, 1)
			local nextPos = pos + fwd * speed * dt
			if wall(nextPos) then
				local ns, nlat = WaterRules.rampCoords(g, nextPos)
				if ns >= 30 and ns <= g.length - 1 and nlat <= 6 then
					leftRamp = true -- slid off the ramp's side, not a wall met from the sand
				end
				avoidDir = Vector3.new(arena.center.X - pos.X, 0, arena.center.Z - pos.Z).Unit
				avoid = 0.8
				speed *= 0.5
			else
				pos = nextPos
			end
		end
		return false, t, leftRamp
	end

	h.test("boarding: a car bot lines up and drives up either gangway from 300+ poses, staying on the ramp", function()
		local runs, boarded, slid, worst = 0, 0, 0, 0
		for _, g in gws do
			local side = Vector3.new(-g.axis.Z, 0, g.axis.X)
			for lat0 = -60, 60, 30 do
				for back = -10, 130, 35 do
					for hd = 0, 315, 45 do
						local pos = g.foot - g.axis * back + side * lat0
						pos = Vector3.new(pos.X, 21, pos.Z)
						local s, lat = WaterRules.rampCoords(g, pos)
						local onBasin = s >= 30 and s <= g.length and lat > 4.5
						if not onBasin and BattleRules.horizontal(pos, arena.center) < arena.radius * 0.95 then
							local a = math.rad(hd)
							local ok, t, left = driveBoard(g, pos, Vector3.new(math.cos(a), 0, math.sin(a)), 30)
							runs += 1
							if ok then
								boarded += 1
								worst = math.max(worst, t)
							end
							if left then
								slid += 1
							end
						end
					end
				end
			end
		end
		h.ok(runs > 300, "poses tried: " .. runs)
		h.eq(boarded, runs, "every pose boards")
		h.ok(worst < 25, "within 25 s (worst " .. string.format("%.1f", worst) .. ")")
		h.ok(slid <= runs // 20, "the ramp is rarely brushed from on it (" .. slid .. ")")
	end)

	h.test("route waypoints: inside the lane they run up the ramp line, past the top onto the deck", function()
		local g = gws[2]
		local onLine = g.foot - g.axis * 20
		local wp = WaterRules.routeStep(g, onLine, g.axis, true)
		local s, lat = WaterRules.rampCoords(g, wp)
		h.ok(near(s, 2, 1e-3) and lat < 1e-3, "on the line, CARROT ahead")
		local top = WaterRules.routeStep(g, g.foot + g.axis * 40, g.axis, true)
		local st = WaterRules.rampCoords(g, top)
		h.ok(near(st, g.length + WaterRules.EXIT_DECK, 1e-3), "capped past the top")
		h.ok(near(top.Y, 32), "deck height")
		local down = WaterRules.routeStep(g, g.foot + g.axis * 30, -g.axis, false)
		local sd = WaterRules.rampCoords(g, down)
		h.ok(sd < 30, "heading down: toward the foot")
	end)

	---------------------------------------------------------------- 6. Bot goals

	-- The REAL gangways and decks, over a synthetic beach (shallows west, crest east) with the galleon deck at 32.
	local ground = gridOf(function(x: number, z: number): number
		if WaterRules.onDeck(course, Vector3.new(x, 32, z), 32) and math.abs(x - battle.spawns[DECK_PAD].X) < 16 and math.abs(z - battle.spawns[DECK_PAD].Z) < 30 then
			return 32
		end
		return beach(x, z)
	end)
	local bcourse = WaterRules.course(battle, arena.center, arena.radius * 0.85, ground)
	local function view(pos: Vector3, groundY: number, t: number, holding: boolean, pods: any, rivals: any, fwd: Vector3?): any
		return { pos = pos, forward = fwd or Vector3.new(1, 0, 0), ground = groundY, holding = holding, t = t, pods = pods or {}, rivals = rivals or {} }
	end

	h.test("bot goal: caught by a rising step in the shallows it still finds the way out", function()
		local pos = Vector3.new(cx - 30, 19 + 1.9, cz)
		local goal = WaterRules.botGoal(bcourse, view(pos, 19, 52, false))
		h.eq(goal.reason, "flee")
		h.ok(goal.pos.X > pos.X, "toward the crest")
	end)

	h.test("bot goal: ground that floods within the look-ahead -> flee to ground that stays dry", function()
		local pos = Vector3.new(cx - 40, 19 + 1.9, cz + 40)
		local goal = WaterRules.botGoal(bcourse, view(pos, 19, 45, false, { { pos = Vector3.new(cx - 60, 22, cz + 40), ground = 19 } }))
		h.eq(goal.reason, "flee")
		local g = WaterRules.heightAt(ground, goal.pos.X, goal.pos.Z) :: number
		h.ok(WaterRules.isDry(g, 21.5, 2.2, WaterRules.SAFE_MARGIN), "the flee point holds at step 1")
		local calm = WaterRules.botGoal(bcourse, view(pos, 19, 10, false, { { pos = Vector3.new(cx - 60, 22, cz + 40), ground = 19 } }))
		h.eq(calm.reason, "pod", "far from a step the same spot is fine")
	end)

	h.test("bot goal: the nearest pod on ground that stays dry (a closer flooding pod is skipped)", function()
		local pos = Vector3.new(cx + 30, 25 + 1.9, cz)
		local wet = { pos = Vector3.new(cx - 15, 22, cz), ground = 19.6 }
		local dry = { pos = Vector3.new(cx + 30, 28, cz + 70), ground = 25 }
		local early = WaterRules.botGoal(bcourse, view(pos, 25, 5, false, { wet, dry }))
		h.eq(early.reason, "pod")
		h.ok(early.pos == wet.pos, "early on the closer pod is fine")
		local late = WaterRules.botGoal(bcourse, view(pos, 25, 45, false, { wet, dry }))
		h.eq(late.reason, "pod")
		h.ok(late.pos == dry.pos, "before step 1 only the dry one")
	end)

	h.test("bot goal: holding an item it hunts a rival on dry ground; a rival on flooding ground is shot at, not chased", function()
		local pos = Vector3.new(cx + 30, 25 + 1.9, cz)
		local dryRival = { id = "player:1", pos = Vector3.new(cx + 40, 26.9, cz + 50), ground = 25 }
		local hunt = WaterRules.botGoal(bcourse, view(pos, 25, 60, true, {}, { dryRival }))
		h.eq(hunt.reason, "hunt")
		h.eq(hunt.attack, "player:1")
		local wetRival = { id = "bot:102", pos = Vector3.new(cx - 60, 20.9, cz), ground = 19 }
		local patrol = WaterRules.botGoal(bcourse, view(pos, 25, 60, true, {}, { wetRival }))
		h.eq(patrol.reason, "patrol")
		h.eq(patrol.attack, "bot:102", "its items still aim at the nearest rival")
		local pg = WaterRules.heightAt(ground, patrol.pos.X, patrol.pos.Z) :: number
		h.ok(WaterRules.isDry(pg, 21.5, 2.2), "patrolling dry ground")
	end)

	h.test("bot goal: a human rival is weighed PREFER_PLAYER times closer for aim and hunt", function()
		local pos = Vector3.new(cx + 30, 25 + 1.9, cz)
		local bot = { id = "bot:102", pos = Vector3.new(cx + 40, 26.9, cz + 30), ground = 25 }
		local near = { id = "player:1", pos = Vector3.new(cx + 40, 26.9, cz + 70), ground = 25, isPlayer = true }
		local g = WaterRules.botGoal(bcourse, view(pos, 25, 60, true, {}, { bot, near }))
		h.eq(g.attack, "player:1", "the human ~2.3x as far is still the one")
		h.eq(g.reason, "hunt")
		local far = { id = "player:1", pos = Vector3.new(cx + 40, 26.9, cz - 140), ground = 25, isPlayer = true }
		h.eq(WaterRules.botGoal(bcourse, view(pos, 25, 60, true, {}, { bot, far })).attack, "bot:102", "past the weighting the nearer bot")
	end)

	h.test("bot goal: a human it may not lock (on the decks, or inside HUMAN_SHOT_GAP) is never its target (I2-07)", function()
		local pos = Vector3.new(cx + 30, 25 + 1.9, cz)
		local human = { id = "player:1", pos = Vector3.new(cx + 40, 26.9, cz + 40), ground = 25, isPlayer = true, noAttack = true }
		local g = WaterRules.botGoal(bcourse, view(pos, 25, 60, true, {}, { human }))
		h.eq(g.attack, WaterRules.HOLD_FIRE, "only an off-limits human in range: hold fire, no fallback to him")
		h.ok(g.reason ~= "hunt", "and no chase")
		local bot = { id = "bot:102", pos = Vector3.new(cx + 40, 26.9, cz + 120), ground = 25 }
		local g2 = WaterRules.botGoal(bcourse, view(pos, 25, 60, true, {}, { human, bot }))
		h.eq(g2.attack, "bot:102", "a rival it may lock instead, even a farther bot")
		h.eq(WaterRules.botGoal(bcourse, view(pos, 25, 60, true, {}, {})).attack, nil, "nobody in range: no target, as before")
	end)

	h.test("bot goal: on the decks it stays there (deck pods, deck rivals, deck patrol)", function()
		local deckPos = battle.spawns[DECK_PAD] - Vector3.new(0, 2.6, 0)
		local beachPod = { pos = Vector3.new(cx + 20, 28, cz), ground = 25 }
		local deckPod = { pos = battle.pickupAnchors[1], ground = 32 }
		local g1 = WaterRules.botGoal(bcourse, view(deckPos, 32, 20, false, { beachPod, deckPod }))
		h.eq(g1.reason, "pod")
		h.ok(g1.pos == deckPod.pos, "the deck pod, not the beach one")
		local g2 = WaterRules.botGoal(bcourse, view(deckPos, 32, 20, false, { beachPod }))
		h.ok(g2.reason ~= "pod", "a beach pod is not worth leaving the deck")
		local beachRival = { id = "player:1", pos = Vector3.new(cx + 40, 26.9, cz), ground = 25 }
		local g3 = WaterRules.botGoal(bcourse, view(deckPos, 32, 20, true, {}, { beachRival }))
		h.ok(g3.reason ~= "hunt", "no chase off the deck")
		h.eq(g3.attack, "player:1", "but it shoots at the beach")
	end)

	-- The gangway trips, for a car bot that can hold a 9-stud ramp (Course.board; off at launch, see the next test).
	local boarding = table.clone(bcourse)
	boarding.board = true

	h.test("bot goal (boarding on): a deck pod up a gangway while its foot stays dry; the Plank Dune keeps it dry", function()
		local pos = Vector3.new(cx + 10, 25 + 1.9, cz + 60)
		local deckPod = { pos = battle.pickupAnchors[1], ground = 32 }
		local g1 = WaterRules.botGoal(boarding, view(pos, 25, 10, false, { deckPod }))
		h.eq(g1.reason, "pod deck")
		h.ok(g1.gangway ~= nil and g1.up == true, "a gangway trip")
		-- The gangway feet used to stand on sandbars that flooded at step 2 (and the decks became an island, trap audit
		-- I2-01); they stand on the Plank Dune now, dry at every step, so the trip stays on.
		local g2 = WaterRules.botGoal(boarding, view(pos, 25, 95, false, { deckPod }))
		h.eq(g2.reason, "pod deck", "step 2 is coming: the gangway feet stay dry")
		-- With a foot under the tide the trip is off (the rule itself, on a gangway lowered into the water).
		local sunk = table.clone(boarding)
		sunk.gangways = {}
		for _, g in boarding.gangways do
			local lowered = table.clone(g)
			lowered.foot = Vector3.new(g.foot.X, 20.6, g.foot.Z)
			table.insert(sunk.gangways, lowered)
		end
		local g3 = WaterRules.botGoal(sunk, view(pos, 25, 95, false, { deckPod }))
		h.ok(g3.reason ~= "pod deck", "a sandbar foot going under at step 2: no trip")
		local bare = WaterRules.course(battle, arena.center, arena.radius * 0.85, nil)
		bare.board = true
		local flee = WaterRules.botGoal(bare, view(Vector3.new(cx - 40, 20.9, cz), 19, 45, false))
		h.eq(flee.reason, "flee deck", "no grid: up a gangway")
	end)

	-- BattleBots holds a car bot at deep water and swings it toward the arena centre, which from the galleon lies across
	-- the basin: a car bot that slides off a ramp edge or meets a deck rail freezes. At launch beach bots keep off it.
	h.test("bot goal at launch (no boarding): a beach bot never plans onto the galleon", function()
		h.eq(bcourse.board, false, "WaterRules.BOTS_BOARD")
		local pos = Vector3.new(cx + 10, 25 + 1.9, cz + 60)
		local deckPod = { pos = battle.pickupAnchors[1], ground = 32 }
		local g1 = WaterRules.botGoal(bcourse, view(pos, 25, 10, false, { deckPod }))
		h.ok(g1.reason ~= "pod deck" and g1.gangway == nil, "a deck pod is left alone: " .. g1.reason)
		-- Flee, patrol and regroup cells from poses all round the beach and at every stage: beach ground only.
		local n = 0
		for _, t in { 10, 45, 95, 135, 170 } do
			for k = 0, 15 do
				local a = k * math.pi / 8
				for _, r in { 30, 70, 110 } do
					local px, pz = cx + r * math.cos(a), cz + r * math.sin(a)
					local gy = WaterRules.heightAt(ground, px, pz)
					if gy and gy < 29 then
						local fwd = Vector3.new(-math.sin(a), 0, math.cos(a))
						local goal = WaterRules.botGoal(bcourse, view(Vector3.new(px, gy + 1.9, pz), gy, t, true, {}, {}, fwd))
						if goal.reason ~= "centre" and goal.reason ~= "board" and goal.reason ~= "disembark" then
							n += 1
							local cellY = WaterRules.heightAt(ground, goal.pos.X, goal.pos.Z) :: number
							h.ok(not WaterRules.offBeach(bcourse, goal.pos.X, goal.pos.Z, cellY), string.format("%s goal off the galleon at t=%d", goal.reason, t))
							h.ok(goal.gangway == nil, "no gangway trip")
						end
					end
				end
			end
		end
		h.ok(n > 100, "goals checked: " .. n)
		-- The barely raised foot of a ramp is beach; up the raised part a bot finishes the trip it is on.
		local g = gws[1]
		local foot = g.foot + g.axis * (WaterRules.RAMP_COMMIT - 6)
		local low = WaterRules.botGoal(bcourse, view(foot, foot.Y, 30, false, {}, {}, g.axis))
		h.ok(low.reason ~= "board" and low.gangway == nil, "at the foot it does not board: " .. low.reason)
		local high = g.foot:Lerp(g.top, (WaterRules.RAMP_COMMIT + 4) / g.length)
		h.eq(WaterRules.botGoal(bcourse, view(high, high.Y, 30, false, {}, {}, g.axis)).reason, "board", "high on the ramp: up")
		-- The same X-Z on the sand under the raised ramp is not the ramp.
		local under = Vector3.new(high.X, 21 + 1.9, high.Z)
		local ug = WaterRules.botGoal(bcourse, view(under, 21, 30, false, {}, {}, g.axis))
		h.ok(ug.reason ~= "board" and ug.gangway == nil, "under the ramp it does not board: " .. ug.reason)
		-- A rival up a gangway is shot at, never chased up it.
		local onRamp = g.foot:Lerp(g.top, 0.3)
		local rival = { id = "player:1", pos = onRamp, ground = onRamp.Y }
		local hunter = Vector3.new(cx + 30, 26.9, cz)
		local g3 = WaterRules.botGoal(bcourse, view(hunter, 25, 60, true, {}, { rival }))
		h.ok(g3.reason ~= "hunt", "no chase up the ramp: " .. g3.reason)
		h.eq(g3.attack, "player:1", "its items still aim there")
		h.eq(WaterRules.botGoal(boarding, view(hunter, 25, 60, true, {}, { rival })).reason, "hunt", "boarding on: the chase")
		-- No grid and nothing dry within reach: stranded, never up a gangway.
		local bare = WaterRules.course(battle, arena.center, arena.radius * 0.85, nil)
		h.eq(WaterRules.botGoal(bare, view(Vector3.new(cx - 40, 20.9, cz), 19, 45, false)).reason, "stranded")
	end)

	h.test("bot goal: with nothing to plan it regroups on the nearest dry ground, never the flooded centre", function()
		-- Out in the boundary band past the grid: no path can be checked, so no patrol or flee cell is plannable.
		local band = Vector3.new(cx + 170, 26.9, cz)
		local goal = WaterRules.botGoal(bcourse, view(band, 25, 60, true, {}, {}, Vector3.new(1, 0, 0)))
		h.eq(goal.reason, "regroup")
		local gy = WaterRules.heightAt(ground, goal.pos.X, goal.pos.Z) :: number
		h.ok(WaterRules.isDry(gy, 21.5, 2.2), "dry ground")
		h.ok(BattleRules.horizontal(goal.pos, arena.center) <= bcourse.within + 1e-6, "inside the edge pull")
		h.ok(BattleRules.horizontal(goal.pos, arena.center) > 30, "not the centre (flooded since step 1)")
	end)

	h.test("bot goal: on a ramp it finishes the climb (or the way down)", function()
		local g = gws[1]
		local mid = g.foot:Lerp(g.top, 0.4)
		local up = WaterRules.botGoal(bcourse, view(mid, mid.Y, 30, false, {}, {}, g.axis))
		h.eq(up.reason, "board")
		h.ok(up.gangway and up.gangway.name == g.name and up.up == true, "a fresh waypoint up this gangway every frame")
		local down = WaterRules.botGoal(bcourse, view(mid, mid.Y, 30, false, {}, {}, -g.axis))
		h.eq(down.reason, "disembark")
	end)

	h.test("bot goal: without a grid it still decides (centre as the last resort)", function()
		local bare = WaterRules.course(battle, arena.center, arena.radius * 0.85, nil)
		local pos = Vector3.new(cx + 30, 26.9, cz)
		local g = WaterRules.botGoal(bare, view(pos, 25, 60, true, {}, {}))
		h.eq(g.reason, "centre")
		local flee = WaterRules.botGoal(bare, view(Vector3.new(cx - 40, 20.9, cz), 19, 45, false))
		h.ok(flee.reason == "flee deck" or flee.reason == "stranded", "no grid: up a gangway or nowhere")
	end)
end
