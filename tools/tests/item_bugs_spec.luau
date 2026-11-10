--!strict
-- Lune spec for the item bugs audit (docs/audits/item_bugs.md; owner playtest 2026-10-20: "i hit the boost/item boxes a
-- few times and then nothing appeared in my inventory to use", "when I had a missle and used it, it hit the opponent but
-- never did any damage"):
--   A. HudPhaseRules shows the item slot in the hub (the hub has mystery cubes and ItemService grants them there).
--   B. ItemService.pickupInReach allows for the server's late view of a client-owned hull (the pod lies ahead along the
--      velocity), still refuses a pod behind or beside the hull; the service grants with reach=lead and answers the
--      player ("ItemPickup") for a capped upgrade, a cube already taken and a refusal; bots are never told.
--   C. ItemRules.clientTakesPod (no pop for an item pod after the finish) and pickupNotice (the caption per answer).
--   D. kit/ItemEffects: offCourse / freeTarget, and a shot from the hub plaza or from a car up a wall flies free at the
--      racer in front of it and lands, where the course shot was yanked onto the course line and missed.
--   E. A missile eaten by a shield or a respawn bubble tells the shooting player ("blocked"); a bot shooter is not told.
-- Run: tools/tests/run_lune_tests.sh tools/tests/item_bugs_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
}

return function(h: Harness)
	local ItemRules = h.require("src/shared/ItemRules.luau")
	local ItemService = h.require("src/server/ItemService.luau")
	local ItemEffects = h.require("src/server/kit/ItemEffects.luau")
	local HudPhaseRules = h.require("src/shared/HudPhaseRules.luau")
	local MissileRules = h.require("src/shared/MissileRules.luau")

	local MISSILE1 = ItemRules.effectFor("red", 1).missile
	local MISSILE2 = ItemRules.effectFor("red", 2).missile
	local NORTH = Vector3.new(0, 0, -1)
	local TUNING = ItemRules.TUNING

	---------------------------------------------------------------- A. the hub shows the slot

	h.test("A: the item slot is allowed in the hub (cubes there); still hidden on finish, results and podium", function()
		h.eq(HudPhaseRules.visible("ItemSlot", "hub"), true, "hub")
		h.eq(HudPhaseRules.visible("ItemSlot", "race"), true, "race")
		h.eq(HudPhaseRules.visible("ItemSlot", "finish"), false, "finish")
		h.eq(HudPhaseRules.visible("ItemSlot", "podium"), false, "podium")
	end)

	---------------------------------------------------------------- B. pickup reach and answers

	h.test("B: pickupInReach: the plain radius, a lagging hull with the pod ahead, never a pod behind or beside", function()
		local R = ItemService.PICKUP_RADIUS
		local pod = Vector3.new(0, 5, -100)
		-- Inside the sphere, no velocity needed.
		local ok, dist, how = ItemService.pickupInReach(Vector3.new(0, 2, -60), nil, pod, R)
		h.eq({ ok, how }, { true, "radius" }, "40 studs")
		h.ok(math.abs(dist - math.sqrt(40 * 40 + 9)) < 1e-6, "plain distance reported")
		-- The server sees the car 0.5 s late at 165 studs/s: 82 studs short of the pod it has just driven through.
		local lagging = Vector3.new(0, 2, -100 + 82)
		h.eq({ (ItemService.pickupInReach(lagging, nil, pod, R)) }, { false }, "without velocity: too far (the old refusal)")
		local ok2, _, how2 = ItemService.pickupInReach(lagging, NORTH * 165, pod, R)
		h.eq({ ok2, how2 }, { true, "lead" }, "with its velocity: in reach")
		-- The same gap with the pod BEHIND the hull (driving away from it) is no pickup.
		h.eq({ (ItemService.pickupInReach(lagging, -NORTH * 165, pod, R)) }, { false }, "driving away")
		-- Beside the lead line by more than the slack.
		local beside = Vector3.new(ItemService.PICKUP_LEAD_SLACK + 6, 2, -100 + 82)
		h.eq({ (ItemService.pickupInReach(beside, NORTH * 165, pod, R)) }, { false }, "beside the line")
		-- A forged claim across the map, even pointed at the pod: past the lead window.
		h.eq({ (ItemService.pickupInReach(Vector3.new(0, 2, 900), NORTH * 9999, pod, R)) }, { false }, "across the map")
		-- A parked hull never reaches further than the sphere.
		h.eq({ (ItemService.pickupInReach(lagging, Vector3.zero, pod, R)) }, { false }, "stopped")
	end)

	type SvcWorld = { t: number, told: { { racer: string, event: string, payload: any } }, logs: { string }, pos: { [string]: Vector3 }, vel: { [string]: Vector3 } }

	local function newService(pods: { [string]: any }): (any, SvcWorld)
		local w: SvcWorld = { t = 100, told = {}, logs = {}, pos = {}, vel = {} }
		local svc = ItemService.new({
			now = function(): number
				return w.t
			end,
			racerPosition = function(id: string): Vector3?
				return w.pos[id]
			end,
			racerVelocity = function(id: string): Vector3?
				return w.vel[id]
			end,
			findPod = function(name: string): any
				return pods[name]
			end,
			publish = function() end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
			notify = function(racerId: string, event: string, payload: any)
				table.insert(w.told, { racer = racerId, event = event, payload = payload })
			end,
			random = function(): number
				return 0.01 -- always the first colour of the band
			end,
		}, ItemService.loggingHooks(function() end))
		return svc, w
	end

	local function cube(z: number): any
		return { position = Vector3.new(0, 5, z), podType = "Red", respawnSeconds = 4, mystery = true }
	end

	h.test("B: a lagging car gets the cube (reach=lead) and is told; a refusal and a taken cube are told too", function()
		local svc, w = newService({ CubeA = cube(-100), CubeB = cube(-400) })
		w.pos["player:1"] = Vector3.new(0, 2, -100 + 80)
		w.vel["player:1"] = NORTH * 160
		h.eq({ svc.requestPickup("player:1", "CubeA") }, { true, "new" }, "granted")
		h.ok(h.count(w.logs, "reach=lead") == 1, "logged as a lead-window pickup")
		h.eq(w.told[#w.told].event, "ItemPickup")
		h.eq(w.told[#w.told].payload.outcome, "new")
		-- A second racer reaches the same cube a moment later: told it was taken.
		w.pos["player:2"] = Vector3.new(0, 2, -100)
		h.eq({ svc.requestPickup("player:2", "CubeA") }, { false, "pod_cooldown" })
		h.eq(w.told[#w.told].racer, "player:2")
		h.eq(w.told[#w.told].payload.reason, "pod_cooldown")
		-- Out of reach even with the lead: refused and told (the client logs the reason).
		h.eq({ svc.requestPickup("player:2", "CubeB") }, { false, "too_far" })
		h.eq(w.told[#w.told].payload.reason, "too_far")
	end)

	h.test("B: a capped upgrade still uses the cube and answers capped; bots are never told", function()
		local pods = { C1 = cube(-10), C2 = cube(-20), C3 = cube(-30), C4 = cube(-40), C5 = cube(-50) }
		local svc, w = newService(pods)
		w.pos["player:1"] = Vector3.new(0, 2, -30)
		for _, name in { "C1", "C2", "C3" } do
			svc.requestPickup("player:1", name)
		end
		h.eq(svc.getState("player:1").level, 3, "level three")
		h.eq({ svc.requestPickup("player:1", "C4") }, { true, "capped" })
		local last = w.told[#w.told]
		h.eq(last.payload.outcome, "capped")
		h.eq(last.payload.level, 3)
		local before = #w.told
		w.pos["bot:2"] = Vector3.new(0, 2, -50)
		h.eq({ svc.requestPickup("bot:2", "C5") }, { true, "new" })
		h.eq(#w.told, before, "a bot has no client")
	end)

	---------------------------------------------------------------- C. client gate and captions

	h.test("C: clientTakesPod: no item pod after the finish; Speed/Air always; everything before the finish", function()
		h.eq(ItemRules.clientTakesPod("Red", false), true)
		h.eq(ItemRules.clientTakesPod("Red", nil), true)
		h.eq(ItemRules.clientTakesPod("Red", true), false, "finished: the server refuses item pods")
		h.eq(ItemRules.clientTakesPod("Rainbow", true), false)
		h.eq(ItemRules.clientTakesPod("Speed", true), true, "speed pods are client effects")
		h.eq(ItemRules.clientTakesPod("Air", true), true)
	end)

	h.test("C: pickupNotice: MAXED for a capped cube, CUBE TAKEN! for a lost race to it, nothing otherwise", function()
		h.eq(ItemRules.pickupNotice("capped", nil, "MISSILE"), "MISSILE MAXED")
		h.eq(ItemRules.pickupNotice("capped", nil, nil), "ITEM MAXED")
		h.eq(ItemRules.pickupNotice(nil, "pod_cooldown", nil), "CUBE TAKEN!")
		h.eq(ItemRules.pickupNotice("new", nil, "BOOST"), nil, "the roulette speaks for a new item")
		h.eq(ItemRules.pickupNotice("upgrade", nil, "BOOST"), nil, "the pips speak for an upgrade")
		h.eq(ItemRules.pickupNotice(nil, "too_far", nil), nil, "logged, not captioned")
	end)

	---------------------------------------------------------------- D. free shots off the course

	h.test("D: offCourse: inside the corridor (and its margins) is the course; a wall, a dip or the plaza is not", function()
		h.eq(ItemEffects.offCourse(0, 14), false, "plane line")
		h.eq(ItemEffects.offCourse(0, 4.5), false, "car hull over the ribbon")
		h.eq(ItemEffects.offCourse(TUNING.corridorHalfWidth + 5, 10), false, "a wide line")
		h.eq(ItemEffects.offCourse(TUNING.corridorHalfWidth + ItemEffects.OFF_COURSE_LAT_MARGIN + 1, 10), true, "up a wall")
		h.eq(ItemEffects.offCourse(-300, 24), true, "the hub plaza")
		h.eq(ItemEffects.offCourse(0, ItemEffects.OFF_COURSE_BELOW - 1), true, "under the road")
		h.eq(ItemEffects.offCourse(0, TUNING.corridorCeiling + ItemEffects.OFF_COURSE_ABOVE_MARGIN + 1), true, "on a mountain top")
	end)

	h.test("D: freeTarget: the nearest active racer in the forward cone and range; never self, behind or inactive", function()
		local from = Vector3.new(0, 0, 0)
		local c = {
			{ id = "me", pos = Vector3.new(0, 0, -5), active = true },
			{ id = "behind", pos = Vector3.new(0, 0, 30), active = true },
			{ id = "far", pos = Vector3.new(0, 0, -(ItemEffects.FREE_TARGET_RANGE + 10)), active = true },
			{ id = "side", pos = Vector3.new(80, 0, -10), active = true },
			{ id = "gone", pos = Vector3.new(0, 0, -20), active = false },
			{ id = "ahead2", pos = Vector3.new(10, 0, -150), active = true },
			{ id = "ahead1", pos = Vector3.new(-15, 0, -90), active = true },
		}
		h.eq(ItemEffects.freeTarget("me", from, NORTH, c), "ahead1")
		h.eq(ItemEffects.freeTarget("me", from, -NORTH, { c[1], c[2] }), "behind", "turned around")
		h.eq(ItemEffects.freeTarget("me", from, NORTH, { c[2], c[3], c[4], c[5] }), nil, "nobody in front")
	end)

	type World = { t: number, racers: { [string]: any }, sent: { string }, logs: { string }, fx: { any }, engine: any, shielded: { [string]: boolean }, add: (string, Vector3, Vector3, number?) -> (), run: (number) -> () }

	-- Course along -Z on y = 0 (station = -z); free roam on or off; ids hit in order.
	local function newWorld(freeRoam: boolean): World
		local w: World = { t = 100, racers = {}, sent = {}, logs = {}, fx = {}, shielded = {} } :: any
		function w.add(id: string, pos: Vector3, forward: Vector3, botId: number?)
			w.racers[id] = { pos = pos, forward = forward, station = -pos.Z, progress = -pos.Z, active = true, isPlayer = botId == nil, botId = botId, plane = "Model_" .. id }
		end
		local ctx = {
			now = function(): number
				return w.t
			end,
			order = function(): { string }
				local ids = {}
				for id in w.racers do
					table.insert(ids, id)
				end
				table.sort(ids)
				return ids
			end,
			racer = function(id: string): any
				return w.racers[id]
			end,
			course = function(st: number): (Vector3, Vector3)
				return Vector3.new(0, 0, -st), NORTH
			end,
			isShielded = function(id: string): boolean
				return w.shielded[id] == true
			end,
			sendPlayer = function(id: string, kind: string, _payload: any)
				table.insert(w.sent, id .. ":" .. kind)
			end,
			broadcast = function(name: string, payload: any)
				table.insert(w.fx, { name = name, payload = payload })
			end,
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
			freeRoam = function(): boolean
				return freeRoam
			end,
		}
		w.engine = ItemEffects.new(ctx)
		function w.run(seconds: number)
			for _ = 1, math.floor(seconds * 30 + 0.5) do
				w.t += 1 / 30
				w.engine.step(1 / 30)
			end
		end
		return w
	end

	h.test("D: hub plaza (300 studs off the loop): a level-1 shot flies free at the player in front and lands", function()
		local w = newWorld(true)
		w.add("player:1", Vector3.new(300, 24, -100), NORTH)
		w.add("player:2", Vector3.new(306, 24, -220), NORTH)
		w.engine.hooks.spawnMissile("player:1", MISSILE1, 1)
		w.run(2)
		h.eq(w.sent, { "player:2:hit" }, "the opponent spins out")
		h.ok(h.count(w.logs, "missile free racer=player:1") == 1, "logged as a free shot")
		h.ok(h.count(w.logs, "target=player:2") >= 1, "aimed at the player in front")
	end)

	h.test("D: in a race, a shooter inside the corridor keeps the course shot (unchanged)", function()
		local w = newWorld(false)
		w.add("player:1", Vector3.new(30, 24, -100), NORTH) -- lat 30: still the course corridor
		w.add("player:2", Vector3.new(30, 24, -220), NORTH)
		w.engine.hooks.spawnMissile("player:1", MISSILE1, 1)
		w.run(2)
		h.eq(w.sent, { "player:2:hit" }, "in the corridor the course shot still lands")
		h.eq(h.count(w.logs, "missile free"), 0, "a course shot")
	end)

	h.test("D: a car up a wall (lat 70, kept as is by the owner) shoots the bot ahead on the same wall and lands", function()
		local w = newWorld(false)
		w.add("player:1", Vector3.new(70, 30, -100), NORTH)
		w.add("bot:3", Vector3.new(72, 31, -200), NORTH, 3)
		w.engine.hooks.spawnMissile("player:1", MISSILE1, 1)
		w.run(2)
		h.eq(w.sent, { "bot3:hit" }, "hit; the course shot flew at lat 34, 36 studs off")
	end)

	h.test("D: a free homing shot turns onto a target that is off to the side", function()
		local w = newWorld(true)
		w.add("player:1", Vector3.new(0, 10, 0), NORTH)
		w.add("player:2", Vector3.new(60, 10, -220), Vector3.new(1, 0, 0)) -- 15 degrees off the nose, 228 out
		w.engine.hooks.spawnMissile("player:1", MISSILE2, 2)
		w.run(3)
		h.eq(w.sent, { "player:2:hit" })
	end)

	h.test("D (v6 minor review): in the hub a free shot never falls back to the progress lock behind the nose", function()
		h.eq(MissileRules.freeLock(nil, "player:2", true), nil, "hub: the cone alone")
		h.eq(MissileRules.freeLock("player:3", "player:2", true), "player:3")
		h.eq(MissileRules.freeLock(nil, "player:2", false), "player:2", "race, off the line: the progress lock stands")
		local w = newWorld(true)
		w.add("player:1", Vector3.new(300, 24, -100), -NORTH) -- turned around on the plaza
		w.add("player:2", Vector3.new(300, 24, -300), NORTH) -- "ahead" by the loop's progress, behind the nose
		w.engine.hooks.spawnMissile("player:1", MISSILE2, 2)
		h.eq(h.count(w.logs, "missile free racer=player:1"), 1)
		h.eq(h.count(w.logs, "target=none"), 1, "no lock on the player behind")
		w.run(3)
		h.eq(w.sent, {}, "the shot never turns around onto them")
	end)

	---------------------------------------------------------------- E. blocks are told

	h.test("E: a shield or a respawn bubble that eats a player's missile tells the shooter; a bot shooter is not told", function()
		local w = newWorld(false)
		w.add("player:1", Vector3.new(0, 14, -100), NORTH)
		w.add("bot:2", Vector3.new(0, 14, -200), NORTH, 2)
		w.shielded["bot:2"] = true
		w.engine.hooks.spawnMissile("player:1", MISSILE1, 1)
		w.run(1.5)
		h.eq(w.sent, { "player:1:blocked" }, "BLOCKED! for the shooter, no hit")
		-- Respawn bubble on a player victim, shot by a bot: the bot has no client, the victim just pops it.
		local w2 = newWorld(false)
		w2.add("bot:1", Vector3.new(0, 14, -100), NORTH, 1)
		w2.add("player:3", Vector3.new(0, 14, -200), NORTH)
		w2.engine.grantImmunity("player:3", 5, false)
		w2.engine.hooks.spawnMissile("bot:1", MISSILE1, 1)
		w2.run(1.5)
		h.eq(w2.sent, {}, "nobody told, nobody hit")
		-- A player shooting a protected player: told, with respawn = true on the wire (not checked here).
		local w3 = newWorld(false)
		w3.add("player:1", Vector3.new(0, 14, -100), NORTH)
		w3.add("player:3", Vector3.new(0, 14, -200), NORTH)
		w3.engine.grantImmunity("player:3", 5, false)
		w3.engine.hooks.spawnMissile("player:1", MISSILE1, 1)
		w3.run(1.5)
		h.eq(w3.sent, { "player:1:blocked" })
	end)
end
