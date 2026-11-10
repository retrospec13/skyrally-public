--!strict
-- Lune spec for the eight-entrant field (TEST_LIST_LAUNCH L08) and the bot logic in server AIRacers: seat filling for
-- 0..9 players, start slots, roster lanes and colours, trigger crossing, pod reach, item heuristics, hit-argument
-- parsing, trim choice and the separation lift (a simulated seven-bot field must never put wing through wing).
-- Usage: lune run tools/tests/field_spec.luau   (any cwd; also picked up by tools/tests/run_lune_tests.sh).
-- AIRacers is loaded from source twice: with bare stubs for the pure helpers, then over fake instances (planes, pods,
-- Players, FlightServer records) and the REAL ItemService for whole races (spawn, joins/leaves, step, pickups, item use,
-- hits, finishes, resets). Rendering, replication and real ItemEffects projectiles are proven in Studio only.
local fs = require("@lune/fs") :: any
local luau = require("@lune/luau") :: any
local process = require("@lune/process") :: any
local roblox = require("@lune/roblox") :: any

local V3 = roblox.Vector3

-- Economy v3 phase 4 rolls bot pace per race (shared/BotPaceRules via math.random): a fixed seed keeps the whole-race
-- checks below (a missile lands within 40 s, lanes at the 40 s mark) repeatable. FIELD_SPEC_SEED=<n> runs another seed.
math.randomseed(tonumber(process.env.FIELD_SPEC_SEED) or 20261020)

local checks = 0
local failures = 0
local function check(cond: any, msg: string)
	checks += 1
	if not cond then
		failures += 1
		print("FAIL " .. msg)
	end
end
local function eq(actual: any, expected: any, msg: string)
	checks += 1
	if actual ~= expected then
		failures += 1
		print(string.format("FAIL %s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
	end
end
local function near(actual: number, expected: number, tol: number, msg: string)
	checks += 1
	if math.abs(actual - expected) > tol then
		failures += 1
		print(string.format("FAIL %s: expected %.3f +- %.3f, got %.3f", msg, expected, tol, actual))
	end
end

local selfPath = debug.info(1, "s")
local root = string.match(selfPath, "^(.*)/tools/tests/[^/]+$") or process.cwd

local function loadWithEnv(rel: string, env: { [string]: any }): any
	local chunk = luau.load(fs.readFile(root .. "/" .. rel), { debugName = rel, environment = env })
	return chunk()
end

local PlaneConfig = loadWithEnv("src/shared/PlaneConfig.luau", { Color3 = roblox.Color3 })
local ItemRules = loadWithEnv("src/shared/ItemRules.luau", {})
local FidelityRules = loadWithEnv("src/shared/FidelityRules.luau", {})
local TriggerRules = loadWithEnv("src/shared/TriggerRules.luau", {})
local GridOrder = loadWithEnv("src/shared/GridOrder.luau", {})
local RacerViewRules = loadWithEnv("src/shared/RacerViewRules.luau", { Vector3 = roblox.Vector3, CFrame = roblox.CFrame })
local BotPaceRules = loadWithEnv("src/shared/BotPaceRules.luau", {})
-- Economy v3 phase 2b: AIRacers keeps its field in the real RaceScope (PER_GROUP false here: one field for the life of
-- the server, as before) and reads race attributes through RaceAttr (stubbed to workspace below, its default path).
local RaceFlowRules = loadWithEnv("src/shared/RaceFlowRules.luau", { Vector3 = roblox.Vector3, CFrame = roblox.CFrame })
local function loadRaceScope(): any
	return loadWithEnv("src/shared/RaceScope.luau", {
		script = { Parent = { WaitForChild = function(): any
			return "RaceFlowRules"
		end } },
		require = function(): any
			return RaceFlowRules
		end,
	})
end

local function loadAIRacers(): any
	local tokens: { [string]: any } = {}
	local function token(name: string): any
		local t = tokens[name]
		if not t then
			t = { __token = name }
			tokens[name] = t
		end
		return t
	end
	local modules: { [string]: any } = {
		PlaneConfig = PlaneConfig,
		ItemRules = ItemRules,
		FidelityRules = FidelityRules,
		TriggerRules = TriggerRules,
		SailGateRules = {},
		-- Only called from instance paths, never by the pure helpers under test.
		SplineUtils = {},
		TrackRegistry = {},
		PlaneBuilder = {},
		CarConfig = { RIDE_HEIGHT = 1.9 },
		CarBuilder = {},
		RacerPaint = { paintBot = function() end },
		GridOrder = GridOrder,
		RacerViewRules = RacerViewRules,
		BotPaceRules = BotPaceRules,
		BotDisguise = {},
		BossConfig = { forZone = function(_z: any): any
			return nil
		end },
		RaceScope = loadRaceScope(),
		RaceAttr = { here = function(_n: string): any
			return nil
		end },
		RaceFlowRules = RaceFlowRules,
	}
	local shared = {
		WaitForChild = function(_self: any, name: string): any
			assert(modules[name] ~= nil, "AIRacers header asked Shared for " .. name)
			return token(name)
		end,
	}
	local services: { [string]: any } = {
		Players = {},
		ReplicatedStorage = {
			WaitForChild = function(_self: any, name: string): any
				assert(name == "Shared", "AIRacers header asked ReplicatedStorage for " .. name)
				return shared
			end,
		},
	}
	local env = {
		game = {
			GetService = function(_self: any, name: string): any
				return assert(services[name], "unexpected service " .. name)
			end,
		},
		script = { Parent = { PlaneBuilder = token("PlaneBuilder"), kit = { CarBuilder = token("CarBuilder"), RacerPaint = token("RacerPaint"), BotDisguise = token("BotDisguise") } } },
		require = function(target: any): any
			assert(type(target) == "table" and target.__token, "AIRacers required a non-token at load")
			return modules[target.__token]
		end,
		Vector3 = V3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
	}
	return loadWithEnv("src/server/AIRacers.luau", env)
end

local AIRacers = loadAIRacers()
local AVOID = PlaneConfig.AI_AVOID
local ITEMS = PlaneConfig.AI_ITEMS
local FIELD = PlaneConfig.AI_FIELD_SIZE

------------------------------------------------------------------------------------------------------------------------
-- Seats: 8 entrants, bots fill every empty seat
------------------------------------------------------------------------------------------------------------------------
do
	eq(FIELD, 8, "field size")
	eq(#PlaneConfig.AI_BOTS, 7, "roster of seven bots")
	eq(PlaneConfig.AI_COUNT, #PlaneConfig.AI_BOTS, "AI_COUNT is the roster size")
	eq(AIRacers.botsNeeded(0), 7, "no player: seven bots, one seat open for the first joiner")
	for players = 1, 8 do
		local bots = AIRacers.botsNeeded(players)
		eq(bots, 8 - players, string.format("%d players -> %d bots", players, 8 - players))
		eq(players + bots, 8, string.format("%d players: eight entrants", players))
	end
	eq(AIRacers.botsNeeded(9), 0, "over-full server: no bots, never negative")
	eq(AIRacers.botsNeeded(1, 8, 3), 3, "capped by a short roster")
	eq(AIRacers.botsNeeded(2, 4, 7), 2, "smaller field size")
end

------------------------------------------------------------------------------------------------------------------------
-- Start slots: after the players, unique, fastest bot frontmost
------------------------------------------------------------------------------------------------------------------------
do
	for players = 0, 8 do
		local bots = AIRacers.botsNeeded(players)
		local slots = AIRacers.botSlots(players, bots)
		eq(#slots, bots, string.format("%d players: one slot per bot", players))
		local seen: { [number]: boolean } = {}
		for i, s in slots do
			check(not seen[s], string.format("%d players: slot %d unique", players, s))
			seen[s] = true
			check(s > math.max(players, 1), string.format("%d players: bot %d slot %d after the players", players, i, s))
			check(s <= FIELD, string.format("%d players: bot %d slot %d on the grid", players, i, s))
			if i > 1 then
				check(s < slots[i - 1], string.format("%d players: faster bot %d ahead of bot %d", players, i - 1, i))
			end
		end
		if bots > 0 then
			eq(slots[1], FIELD, string.format("%d players: fastest bot on the front slot", players))
			eq(slots[bots], math.max(players, 1) + 1, string.format("%d players: slowest bot right after the players", players))
		end
	end

	-- Legacy station grid = tools/map/adapt.py grid_slot with DINO-4's plan numbers.
	local grid = PlaneConfig.AI_GRID
	local expected = { { 18, 0 }, { 18, 12 }, { 46, -12 }, { 46, 12 }, { 74, -12 }, { 74, 12 }, { 102, -12 }, { 102, 12 } }
	local poses: { [string]: boolean } = {}
	for slot, e in expected do
		local st, lat = AIRacers.legacyGridSlot(slot, grid)
		eq(st, e[1], "legacy slot " .. slot .. " station")
		eq(lat, e[2], "legacy slot " .. slot .. " lateral")
		local key = st .. ":" .. lat
		check(not poses[key], "legacy slot " .. slot .. " distinct pose")
		poses[key] = true
		check(st >= 0, "legacy slot " .. slot .. " never behind the line")
	end
	-- Bot i lands in slot 9 - i whatever the player count, and its lane is on that slot's side (or the centre), so
	-- row-mates fan outward off the grid and never cross each other.
	for players = 0, 7 do
		local slotsN = AIRacers.botSlots(players, AIRacers.botsNeeded(players))
		for i, sl in slotsN do
			eq(sl, 9 - i, string.format("%d players: bot %d always in slot %d", players, i, 9 - i))
		end
	end
	for i, b in PlaneConfig.AI_BOTS do
		local _, lat = AIRacers.legacyGridSlot(9 - i, grid)
		check(b.laneOffset == 0 or (b.laneOffset > 0) == (lat > 0), b.name .. " lane on its slot's side")
		if 9 - i == 2 then
			check(math.abs(b.laneOffset) >= math.abs(lat), b.name .. " beside the pole moves away from the player")
		end
	end
	-- Rows are one plane length apart and row-mates a full span apart, so the grid itself never overlaps.
	check(grid.rowSpacing >= AVOID.length, "grid rows at least one plane length apart")
	check(2 * grid.laneOffset >= AVOID.span, "grid row-mates at least one span apart")
end

------------------------------------------------------------------------------------------------------------------------
-- Roster: names, colours, pace, lanes
------------------------------------------------------------------------------------------------------------------------
do
	local bots = PlaneConfig.AI_BOTS
	eq(bots[1].name, "Ace Aero", "first bot")
	eq(bots[1].baseSpeed, 139, "Ace Aero pace (L14)")
	eq(bots[1].boostFactor, 1.10, "Ace Aero boost (L14)")
	eq(bots[2].name, "Blaze Wing", "second bot")
	eq(bots[2].baseSpeed, 134, "Blaze Wing pace (L14)")
	eq(bots[2].boostFactor, 1.07, "Blaze Wing boost (L14)")
	eq(bots[3].name, "Nova Sky", "third bot")
	eq(bots[3].baseSpeed, 129, "Nova Sky pace (L14)")
	eq(bots[3].boostFactor, 1.04, "Nova Sky boost (L14)")
	for i = 2, #bots do
		check(bots[i].baseSpeed < bots[i - 1].baseSpeed, bots[i].name .. " slower than " .. bots[i - 1].name)
		check(bots[i].boostFactor <= bots[i - 1].boostFactor, bots[i].name .. " boost not above " .. bots[i - 1].name)
	end
	check(bots[7].baseSpeed >= PlaneConfig.BASE_SPEED, "slowest bot still at least the player's base speed")

	-- Original names: no Diddy Kong Racing character in any bot name.
	local dkr = { "diddy", "banjo", "conker", "krunch", "timber", "pipsy", "bumper", "tiptup", "drumstick", "t.t", "wizpig", "taj", "dixie" }
	for _, b in bots do
		local lower = string.lower(b.name)
		for _, n in dkr do
			check(not string.find(lower, n, 1, true), b.name .. " is not a DKR character (" .. n .. ")")
		end
	end

	local ok, why, spread = AIRacers.validateRoster(bots)
	check(ok, "validateRoster: " .. tostring(why))
	check(spread >= 0.75, string.format("static lane spread %.2f >= 0.75 (12 studs sideways or 3.75 up)", spread))

	local lanes: { [number]: boolean } = {}
	for _, b in bots do
		check(not lanes[b.laneOffset], b.name .. " lane unique")
		lanes[b.laneOffset] = true
		check(math.abs(b.laneOffset) <= 12, b.name .. " lane within +-12")
		check(b.heightOffset >= 8 and b.heightOffset <= 17, b.name .. " height within 8..17")
	end

	-- validateRoster really rejects what it claims to.
	local C = roblox.Color3
	local bad = {
		{ name = "A", color = C.fromRGB(255, 0, 0), accent = C.fromRGB(0, 0, 0), baseSpeed = 120, boostFactor = 1, laneOffset = 0, heightOffset = 10 },
		{ name = "A", color = C.fromRGB(250, 5, 5), accent = C.fromRGB(0, 0, 0), baseSpeed = 110, boostFactor = 1, laneOffset = 0, heightOffset = 20 },
	}
	local okBad, whyBad = AIRacers.validateRoster(bad)
	check(not okBad, "validateRoster rejects a bad roster")
	check(string.find(whyBad, "duplicate name", 1, true) ~= nil, "duplicate name reported")
	check(string.find(whyBad, "share lane", 1, true) ~= nil, "shared lane reported")
	check(string.find(whyBad, "colours too close", 1, true) ~= nil, "close colours reported")
	check(string.find(whyBad, "outside 8..17", 1, true) ~= nil, "height out of box reported")
end

------------------------------------------------------------------------------------------------------------------------
-- Trigger crossing (boost rings/pads and item pods use the same test)
------------------------------------------------------------------------------------------------------------------------
do
	local L = 5450
	check(AIRacers.crossed(100, 110, 105, L), "mark inside the step")
	check(AIRacers.crossed(100, 110, 110, L), "mark at the new station counts")
	check(not AIRacers.crossed(100, 110, 100, L), "mark at the old station was counted last step")
	check(not AIRacers.crossed(100, 110, 99, L), "mark behind is not crossed")
	check(not AIRacers.crossed(100, 110, 111, L), "mark ahead is not crossed yet")
	check(AIRacers.crossed(5445, 3, 5448, L), "wrap: mark before the line")
	check(AIRacers.crossed(5445, 3, 2, L), "wrap: mark after the line")
	check(AIRacers.crossed(5445, 3, 0, L), "wrap: mark on the line")
	check(not AIRacers.crossed(5445, 3, 4, L), "wrap: mark past the new station")
	check(not AIRacers.crossed(5445, 3, 5440, L), "wrap: mark behind the old station")
	check(not AIRacers.crossed(200, 200, 200, L), "standing still crosses nothing")

	-- Every mark is crossed exactly once per lap at any frame rate (no double boost, no missed pod).
	local marks = { 0, 130.6, 206.6, 1834.9, 5215.5, 5449.9 }
	for _, step in { 1.9, 2.3, 7.7, 33.3 } do
		local counts: { number } = {}
		local st = 5000.0
		for _ = 1, math.ceil(L / step) do
			local nxt = (st + step) % L
			for i, m in marks do
				if AIRacers.crossed(st, nxt, m, L) then
					counts[i] = (counts[i] or 0) + 1
				end
			end
			st = nxt
		end
		for i, m in marks do
			eq(counts[i] or 0, 1, string.format("step %.1f: mark %.1f crossed once per lap", step, m))
		end
	end

	eq(AIRacers.signedGap(100, 180, L), 80, "gap ahead")
	eq(AIRacers.signedGap(180, 100, L), -80, "gap behind")
	near(AIRacers.signedGap(5400, 30, L), 80, 1e-9, "gap ahead across the line")
	near(AIRacers.signedGap(30, 5400, L), -80, 1e-9, "gap behind across the line")
	eq(AIRacers.progressOf(1, 5420, L), -30, "lap 1 just behind the line scores negative (RaceManager standings)")
	eq(AIRacers.progressOf(2, 100, L), L + 100, "lap 2 progress")
end

------------------------------------------------------------------------------------------------------------------------
-- Pods: reach and want
------------------------------------------------------------------------------------------------------------------------
do
	eq(ITEMS.podReach, 14, "pod reach is the player's pickup trigger radius")
	check(AIRacers.podInReach(0, 0), "pod on the bot")
	check(AIRacers.podInReach(9, 9), "pod 12.7 studs off")
	check(not AIRacers.podInReach(12, 9), "pod 15 studs off")
	check(not AIRacers.podInReach(-21.8, 0), "slope pod 21.8 sideways from a centre-lane bot")
	check(AIRacers.podInReach(12 - 21.3, 8 - 11.1), "a +12 lane at 8 reaches SlopePod_BlueRight (21.3, 11.1)")
	-- DINO-4 item pods where the adapter builds them: the plan's lateral/height above the ribbon (tools/map/adapt.py
	-- build_trackdata pods; builtOffset is the legacy build and is not used). Read from the plan so it cannot go stale.
	local serde = require("@lune/serde") :: any
	local plan = serde.decode("json", fs.readFile(root .. "/map/dino4/plan.json"))
	local pods: { { any } } = {}
	for _, p in plan.skyrally.gameplay.pods do
		local podClass = ItemRules.classifyPod(p.type)
		if podClass == "item" then
			table.insert(pods, { p.name, p.lateral or 0, p.height or 0 })
		end
	end
	eq(#pods, 35, "DINO-4 plan has 35 item cubes (cubes v3: seven two-deep clusters of 2 + 3)")
	local reachable = 0
	local perBot: { number } = {}
	for _, pod in pods do
		local any = false
		for i, b in PlaneConfig.AI_BOTS do
			if AIRacers.podInReach(b.laneOffset - pod[2], b.heightOffset - pod[3]) then
				any = true
				perBot[i] = (perBot[i] or 0) + 1
			end
		end
		check(any, tostring(pod[1]) .. " is in some bot's reach")
		if any then
			reachable += 1
		end
	end
	eq(reachable, #pods, "every DINO-4 item pod is in some bot's reach")
	local spread: { string } = {}
	for i, b in PlaneConfig.AI_BOTS do
		check((perBot[i] or 0) >= 1, b.name .. " can reach at least one DINO-4 item pod")
		table.insert(spread, string.format("%s=%d", b.name, perBot[i] or 0))
	end
	print("  DINO-4 item pods in lane reach per bot (of " .. #pods .. "): " .. table.concat(spread, " "))

	check(AIRacers.wantsPod(nil, 0, "red", 3), "empty bot takes any pod")
	check(AIRacers.wantsPod("red", 1, "red", 3), "same colour upgrades")
	check(AIRacers.wantsPod("red", 2, "red", 3), "same colour upgrades to three")
	check(not AIRacers.wantsPod("red", 3, "red", 3), "capped item is not upgraded")
	check(not AIRacers.wantsPod("red", 1, "blue", 3), "different colour does not replace a held item")
	check(not AIRacers.wantsPod("red", 1, "red", ItemRules.maxLevel(true)), "battle level-one-only: no upgrade")
	-- Mystery cubes (podColor nil): always worth taking unless the held item is capped.
	check(AIRacers.wantsPod(nil, 0, nil, 3), "empty bot takes a cube")
	check(AIRacers.wantsPod("red", 1, nil, 3), "a cube upgrades any held item")
	check(AIRacers.wantsPod("blue", 2, nil, 3), "a cube upgrades to three")
	check(not AIRacers.wantsPod("blue", 3, nil, 3), "a capped item passes cubes by")
end

------------------------------------------------------------------------------------------------------------------------
-- Item heuristics
------------------------------------------------------------------------------------------------------------------------
do
	local function ctx(over: { [string]: any }?): any
		local c: { [string]: any } = { threatBehind = false, onStraight = false, boosting = false, heldFor = 2 }
		for k, v in (over or {}) :: any do
			c[k] = v
		end
		return c
	end
	local function decide(kind: string, over: { [string]: any }?): (boolean, string)
		return AIRacers.decideItemUse(kind, 1, ctx(over))
	end

	-- missile: a rival 20-150 ahead
	check(select(1, decide("missile", { aheadGap = 20 })), "missile at 20 ahead")
	check(select(1, decide("missile", { aheadGap = 84 })), "missile at 84 ahead")
	check(select(1, decide("missile", { aheadGap = 150 })), "missile at 150 ahead")
	check(not select(1, decide("missile", { aheadGap = 12 })), "no missile point blank (12)")
	check(not select(1, decide("missile", { aheadGap = 200 })), "no missile at 200")
	check(not select(1, decide("missile", { behindGap = 40 })), "no missile with only a rival behind")
	eq(select(2, decide("missile", { aheadGap = 60 })), "rival_ahead", "missile reason")

	-- trap: a rival close behind
	check(select(1, decide("trap", { behindGap = 25 })), "trap with a rival 25 behind")
	check(select(1, decide("trap", { behindGap = 60 })), "trap with a rival 60 behind")
	check(not select(1, decide("trap", { behindGap = 90 })), "no trap with the rival 90 behind")
	check(not select(1, decide("trap", { aheadGap = 30 })), "no trap with only a rival ahead")

	-- boost: on straights, not on top of a running boost
	check(select(1, decide("boost", { onStraight = true })), "boost on a straight")
	check(not select(1, decide("boost", { onStraight = false })), "no boost in a bend")
	check(not select(1, decide("boost", { onStraight = true, boosting = true })), "no boost while boosting")

	-- shield: incoming missile threat
	check(select(1, decide("shield", { threatBehind = true })), "shield on a missile threat")
	check(not select(1, decide("shield", { behindGap = 30 })), "no shield without a threat")

	-- magnet: a rival in range ahead
	check(AIRacers.decideItemUse("magnet", 1, ctx({ aheadGap = 200, magnetRange = 250 })), "magnet at 200 with range 250")
	check(not AIRacers.decideItemUse("magnet", 1, ctx({ aheadGap = 300, magnetRange = 250 })), "no magnet beyond range")
	check(not AIRacers.decideItemUse("magnet", 1, ctx({ aheadGap = 10, magnetRange = 250 })), "no magnet on a rival alongside")
	-- magnet v2: the server locks the CLOSEST racer, so a bot fires only when the closest one is ahead (near-tie ahead wins)
	check(not AIRacers.decideItemUse("magnet", 1, ctx({ aheadGap = 120, behindGap = 40, magnetRange = 250 })), "no magnet when a rival behind is much closer")
	check(AIRacers.decideItemUse("magnet", 1, ctx({ aheadGap = 50, behindGap = 40, magnetRange = 250 })), "near-tie: the rival ahead wins")

	-- hold timing
	local fresh, freshWhy = decide("missile", { aheadGap = 60, heldFor = 0.2 })
	check(not fresh, "a fresh pickup waits minHold")
	eq(freshWhy, "settling", "settling reason")
	local hoard, hoardWhy = decide("trap", { heldFor = ITEMS.maxHold + 0.1 })
	check(hoard, "an item held past maxHold is used")
	eq(hoardWhy, "hold_timeout", "hold timeout reason")
	check(not select(1, decide("trap", { heldFor = ITEMS.maxHold - 1 })), "no timeout before maxHold")
	check(not select(1, decide("sparkle", { heldFor = 99 })), "unknown kind never fires")

	-- items v4 specials (docs/design/ITEMS_V4.md): one sensible rule each
	check(select(1, decide("rocket_rush", {})), "rocket at once")
	check(not select(1, decide("rocket_rush", { boosting = true })), "no rocket on top of a boost")
	check(select(1, decide("golden_wings", { aheadGap = 20 })), "golden wings rams a rival in reach")
	check(select(1, decide("golden_wings", { onStraight = true })), "golden wings on a straight")
	check(not select(1, decide("orbit_missiles", { aheadGap = 400 })), "the orbit ring is kept as a shield with nobody in reach")
	check(select(1, decide("orbit_missiles", { aheadGap = 60 })), "an orbiter at a rival ahead")
	check(select(1, decide("storm_bolt", {})), "a bolt flies when someone leads")
	check(not select(1, decide("storm_bolt", { leading = true })), "the leader keeps its bolt")
	check(select(1, decide("boom_bomb", { aheadGap = 60 })), "a bomb where a rival will be")
	check(not select(1, decide("boom_bomb", { aheadGap = 10 })), "no bomb on a rival right on the nose")
	check(select(1, decide("frost_shot", { aheadGap = 50 })), "frost at a rival ahead")
	check(select(1, decide("coin_burst", { aheadGap = 50 })), "coins at a rival ahead")
	check(not select(1, decide("frost_shot", { aheadGap = 300 })), "no straight shot at a far rival")
	check(select(1, decide("gift_box", { onStraight = true })), "a gift on a straight")
	check(select(1, decide("bubble_guard", { threatBehind = true })), "bubble on a threat")
	check(not select(1, decide("bubble_guard", {})), "a bubble waits for a threat")

	-- every ItemRules kind has a rule
	for _, kind in ItemRules.KIND_OF do
		local _, why = AIRacers.decideItemUse(kind, 1, ctx({ heldFor = 1 }))
		check(why ~= "unknown_kind", "a rule exists for " .. kind)
	end

	-- nearest gaps: physical, laps ignored, self skipped, wrap aware
	local L = 5450
	local ahead, behind = AIRacers.nearestGaps(5400, { 5400, 30, 5300, 2000 }, L, 1)
	near(ahead or -1, 80, 1e-9, "nearest ahead across the line")
	near(behind or -1, 100, 1e-9, "nearest behind")
	local a2, b2 = AIRacers.nearestGaps(100, { 100 }, L, 1)
	check(a2 == nil and b2 == nil, "alone: no gaps")

	-- straights
	local fwd = V3.new(0, 0, -1)
	check(AIRacers.isStraight(fwd, fwd, fwd), "three equal tangents are straight")
	check(not AIRacers.isStraight(fwd, V3.new(0.5, 0, -0.866), V3.new(1, 0, 0)), "a 90 degree bend is not straight")
end

------------------------------------------------------------------------------------------------------------------------
-- Hits and seat trimming
------------------------------------------------------------------------------------------------------------------------
do
	local id, s, src = AIRacers.parseHitArgs(3, 1.5, "missile")
	eq(id, 3, "documented signature: bot id")
	eq(s, 1.5, "documented signature: stun")
	eq(src, "missile", "documented signature: source")
	id, s, src = AIRacers.parseHitArgs("bot:4", "trap", 1.0)
	eq(id, 4, "racer id string")
	eq(s, 1.0, "stun after a string")
	eq(src, "trap", "source string")
	id, s, src = AIRacers.parseHitArgs({ racerId = "bot:2", seconds = 0.8, kind = "hit" })
	eq(id, 2, "effect table racer id")
	eq(s, 0.8, "effect table seconds")
	eq(src, "hit", "effect table kind")
	id, s = AIRacers.parseHitArgs(5)
	eq(id, 5, "id only")
	eq(s, PlaneConfig.AI_HIT.defaultStun, "default stun ~1.2 s")
	eq(PlaneConfig.AI_HIT.defaultStun, 1.2, "default stun is 1.2 s")
	id, s = AIRacers.parseHitArgs(6, 99)
	eq(s, PlaneConfig.AI_HIT.maxStun, "stun clamped")
	-- A player racer id names the target: the number after it is the stun, never bot #<stun>.
	id, s = AIRacers.parseHitArgs("player:77", 1)
	eq(id, nil, "a player racer id is not a bot hit (the number after it is not read as a bot id)")
	eq(s, 1, "a player hit's number is the stun")
	id = AIRacers.parseHitArgs("player:77")
	eq(id, nil, "no bot id at all")
	id = AIRacers.parseHitArgs({ racerId = "player:5", seconds = 1 })
	eq(id, nil, "effect table for a player is not a bot hit")
	id, s, src = AIRacers.parseHitArgs(3, 1.5, "missile", "player:9")
	eq(id, 3, "an attacker id after the target leaves the target alone")
	eq(s, 1.5, "an attacker id after the target leaves the stun alone")
	eq(src, "missile", "an attacker id is not the source")

	local L = 5450
	local function b(i: number, lap: number, st: number, fin: boolean): any
		return { id = i, lap = lap, station = st, finished = fin }
	end
	local victim = AIRacers.pickTrimVictim({ b(1, 2, 300, false), b(2, 1, 4000, false), b(3, 2, 100, false) }, L)
	eq(victim and victim.id, 2, "last-placed racing bot gives its seat")
	victim = AIRacers.pickTrimVictim({ b(1, 3, 10, true), b(2, 1, 50, true), b(3, 3, 900, false) }, L)
	eq(victim and victim.id, 3, "a racing bot before any finished one")
	victim = AIRacers.pickTrimVictim({ b(1, 3, 10, true), b(2, 3, 5, true) }, L)
	eq(victim and victim.id, 2, "all finished: last placed")
	victim = AIRacers.pickTrimVictim({ b(1, 1, 5440, false), b(2, 1, 20, false) }, L)
	eq(victim and victim.id, 1, "behind the line on lap 1 is last")
	eq(AIRacers.pickTrimVictim({}, L), nil, "no bots, no victim")
end

------------------------------------------------------------------------------------------------------------------------
-- Separation: static lift rule and a simulated full field
------------------------------------------------------------------------------------------------------------------------
do
	check(AIRacers.planesClear(AVOID.span, 0), "a full span sideways is clear")
	check(AIRacers.planesClear(0, AVOID.clearHeight), "a full clearance up is clear")
	check(not AIRacers.planesClear(12, 4.5), "12 sideways, 4.5 up still touches")
	eq(AIRacers.requiredLift(0, 8, 8, 0), AVOID.clearHeight, "stacked: lift one clearance")
	eq(AIRacers.requiredLift(AVOID.span, 8, 8, 0), 0, "a span apart: no lift")
	near(AIRacers.requiredLift(6, 12.5, 8, 0), 0.5, 1e-9, "mid tier over low tier: small lift")
	eq(AIRacers.requiredLift(0, 17, 8, 0), 0, "already clear")
	near(AIRacers.requiredLift(0, 12.5, 8, 6), AVOID.clearHeight + 1.5, 1e-9, "lower plane's own lift counts")
	eq(AIRacers.requiredLift(0, 8, 8, 40), AVOID.maxLift, "lift is clamped")

	-- Bot car ride height (owner 2026-10-19 "the opponent behind you appears in the air"): a hit on something in the
	-- 10 studs over the road (the server copy of a player's seated avatar, a stray part) must not lift the car.
	do
		local lineY, ride = 100, 1.9
		local road = lineY + 2.7
		local cur = road + ride - lineY -- 4.6: riding the road
		local t, held = AIRacers.carRideTarget(cur, lineY, road, 130, 1 / 60, 0)
		near(t, cur, 1e-9, "flat road: same ride offset")
		eq(held, 0, "flat road: nothing held")
		-- An avatar head ~4.5 studs over the road under the ray: refused, and still refused a few frames on.
		t, held = AIRacers.carRideTarget(cur, lineY, road + 4.5, 130, 1 / 60, 0)
		near(t, cur, 1e-9, "a 4.5 stud step in one frame is refused")
		check(held > 0, "the refusal is timed")
		local h2 = held
		for _ = 1, 10 do
			t, h2 = AIRacers.carRideTarget(cur, lineY, road + 4.5, 130, 1 / 60, h2)
		end
		near(t, cur, 1e-9, "still refused after 11 frames (a player passing over the same spot)")
		local frames = 11
		while h2 > 0 and frames < 120 do
			t, h2 = AIRacers.carRideTarget(cur, lineY, road + 4.5, 130, 1 / 60, h2)
			frames += 1
		end
		near(t, road + 4.5 + ride - lineY, 1e-9, "a raised deck that persists past stepUpHold is taken")
		check(frames <= 19, string.format("taken after stepUpHold, 0.3 s (%d frames)", frames))
		-- A 45 degree ramp at 130 studs/s rises ~2.2 studs a frame: taken at once.
		t = AIRacers.carRideTarget(cur, lineY, road + 2.1, 130, 1 / 60, 0)
		near(t, cur + 2.1, 1e-9, "a ramp is followed frame by frame")
		-- Down is always taken (crests, landings); a jump gap or no hit keeps the last ride offset.
		t = AIRacers.carRideTarget(cur, lineY, road - 3, 130, 1 / 60, 0)
		near(t, cur - 3, 1e-9, "dropping ground is followed")
		t = AIRacers.carRideTarget(cur, lineY, lineY - 20, 130, 1 / 60, 0)
		near(t, cur, 1e-9, "a hit far under the line is a gap: hold")
		t = AIRacers.carRideTarget(cur, lineY, nil, 130, 1 / 60, 0)
		near(t, cur, 1e-9, "no hit: hold")
	end

	-- Planned passes: look-ahead grows with the closure, contact time, side steps, and the capped spring.
	eq(AIRacers.planWindow(0), AVOID.length + AVOID.lookahead, "no closure: the static look-ahead")
	near(AIRacers.planWindow(100), AVOID.length + 100 * AVOID.planSeconds, 1e-9, "fast closure: planSeconds of closure")
	eq(AIRacers.contactTime(AVOID.length - 1, 0), 0, "overlapping: contact now")
	eq(AIRacers.contactTime(100, 0), math.huge, "not closing: no contact")
	near(AIRacers.contactTime(AVOID.length + 50, 25), 2, 1e-9, "50 studs at 25 studs/s: 2 s")
	eq(AIRacers.sideStepFor(30, 5), 0, "lanes already a span plus swing apart: no step")
	near(AIRacers.sideStepFor(12, 5) :: number, (AVOID.span + 5 + AVOID.sideMargin - 12) / 2, 1e-9, "lanes 12 apart: each steps half the shortfall")
	check(AVOID.span + 5 + AVOID.sideMargin - 12 <= 2 * AVOID.maxSide, "the +-6 lanes clear by a side step alone")
	eq(AIRacers.sideStepFor(0, 5), nil, "the same lane: no side to step to (lift)")
	eq(AIRacers.sideStepFor(3, 5), nil, "shortfall over two maxSide steps: lift")
	do
		local x, v, peak, maxRate = 0, 0, 0, 0
		for _ = 1, 180 do
			local nx, nv = AIRacers.springStep(x, v, 10, 1 / 60, AVOID.climbRate, AVOID.fallRate)
			maxRate = math.max(maxRate, math.abs(nx - x) * 60)
			x, v = nx, nv
			peak = math.max(peak, x)
		end
		check(maxRate <= AVOID.climbRate + 1e-6, "spring climb capped at climbRate")
		check(peak <= 10 + 0.05, string.format("spring does not overshoot (peak %.3f)", peak))
		near(x, 10, 0.05, "spring settles on its target in 3 s")
		local _, v1 = AIRacers.springStep(0, 0, 10, 1 / 60, AVOID.climbRate, AVOID.fallRate)
		check(v1 > 0 and v1 < 2, "spring starts gently (no first-frame jump)")
	end

	-- Every pair of roster lanes is either clear or resolved by one lift inside maxLift.
	for i, a in PlaneConfig.AI_BOTS do
		for j, c in PlaneConfig.AI_BOTS do
			if j > i then
				local upper, lower = if a.heightOffset >= c.heightOffset then a else c, if a.heightOffset >= c.heightOffset then c else a
				local lift = AIRacers.requiredLift(a.laneOffset - c.laneOffset, upper.heightOffset, lower.heightOffset, 0)
				check(lift < AVOID.maxLift, a.name .. "/" .. c.name .. " resolvable")
				check(
					AIRacers.planesClear(a.laneOffset - c.laneOffset, upper.heightOffset + lift - lower.heightOffset),
					a.name .. "/" .. c.name .. " clear after lift"
				)
			end
		end
	end

	-- Seven bots from the grid for 3 laps at 60 Hz with weave, random ring boosts and spin-outs (the worst closing
	-- speeds). Wherever two planes overlap along the course and their wings overlap sideways, their heights must be at
	-- least a clearance apart (0.5 stud tolerance for the per-frame lerp).
	local L = 5450
	local dt = 1 / 60
	local seed = 12345
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local grid = PlaneConfig.AI_GRID
	local weave = PlaneConfig.AI_WEAVE
	local hit = PlaneConfig.AI_HIT
	local slots = AIRacers.botSlots(1, 7)
	local field: { any } = {}
	for i, cfg in PlaneConfig.AI_BOTS do
		local st, lat = AIRacers.legacyGridSlot(slots[i], grid)
		table.insert(field, {
			id = i,
			station = st,
			lateral = lat,
			height = grid.height,
			gridLateral = lat,
			gridHeight = grid.height,
			laneOffset = cfg.laneOffset,
			heightOffset = cfg.heightOffset,
			baseSpeed = cfg.baseSpeed,
			boostFactor = cfg.boostFactor,
			currentSpeed = cfg.baseSpeed,
			boostTimer = 0,
			stunTimer = 0,
			travelled = 0,
			weavePhase = i * 2.0,
			weaveScale = 0,
			lift = 0,
			liftTarget = 0,
		})
	end
	local TOL = 0.5 -- studs; the hull lerp alone moves a plane this much per frame at speed
	local worst = -math.huge
	local worstAt = ""
	local overlaps = 0
	local maxLiftSeen = 0
	local maxClimb = 0 -- studs/s of separation lift (the pop the owner saw as bots "bumping")
	local maxSideRate = 0 -- studs/s of separation side step
	local liftEvents = 0 -- a bot's lift target switching on
	local urgentEvents = 0 -- a climb that could not wait for the eased rate
	local popFrames = 0 -- bot-frames climbing faster than 25 studs/s
	local steps = math.floor(3 * L / 120 / dt)
	for n = 1, steps do
		local t = n * dt
		for _, bot in field do
			bot.boostTimer = math.max(0, bot.boostTimer - dt)
			bot.stunTimer = math.max(0, bot.stunTimer - dt)
			-- Rings and pods start at station ~130, so boosts and hits begin after the first second.
			local r = rand()
			if t > 1 and r < 0.004 then
				bot.boostTimer = PlaneConfig.BOOST_DURATION
			elseif t > 1 and r < 0.0055 then
				bot.stunTimer = hit.defaultStun
				bot.boostTimer = 0
			end
			-- Rubber banding is neutral on the grid (every bot within RUBBER_BAND_*_DIST of the player) and then swings
			-- each bot slowly through its full +14%/-12% range, so packs form, break up and re-form.
			local swing = math.sin(0.07 * t * (1 + 0.3 * bot.id) + bot.id)
			local ramp = math.clamp((t - 5) / 10, 0, 1)
			local rubber = 1 + ramp * (if swing > 0 then swing * PlaneConfig.RUBBER_BAND_MAX_BOOST else swing * PlaneConfig.RUBBER_BAND_MAX_SLOW)
			local target = bot.baseSpeed * rubber
			if bot.stunTimer > 0 then
				target = bot.baseSpeed * hit.speedFactor
			elseif bot.boostTimer > 0 then
				target = math.max(target, PlaneConfig.BOOST_SPEED * bot.boostFactor * rubber)
			end
			local rate = if target > bot.currentSpeed then 9 elseif bot.stunTimer > 0 then hit.brakeRate else 4.5
			bot.currentSpeed += (target - bot.currentSpeed) * math.clamp(dt * rate, 0, 1)
			local adv = bot.currentSpeed * dt
			bot.station = (bot.station + adv) % L
			bot.travelled += adv
			local m = math.clamp(bot.travelled / grid.mergeDistance, 0, 1)
			m = m * m * (3 - 2 * m)
			bot.weaveScale = m
			bot.weavePhase += dt * weave.rate
			bot.laneLateral = bot.gridLateral + (bot.laneOffset - bot.gridLateral) * m
			bot.lateral = bot.laneLateral + math.sin(bot.weavePhase) * weave.lateral * m
			bot.height = bot.gridHeight + (bot.heightOffset - bot.gridHeight) * m + math.cos(bot.weavePhase * 0.8) * weave.vertical * m
		end
		for _, bot in field do
			bot.wasLifting = bot.liftTarget > 0.5
		end
		AIRacers.solveLifts(field, L)
		for _, bot in field do
			local lift0, side0 = bot.lift, bot.side or 0
			AIRacers.approachLift(bot, dt)
			maxLiftSeen = math.max(maxLiftSeen, bot.lift)
			maxClimb = math.max(maxClimb, math.abs(bot.lift - lift0) / dt)
			maxSideRate = math.max(maxSideRate, math.abs((bot.side or 0) - side0) / dt)
			if bot.liftTarget > 0.5 and not bot.wasLifting then
				liftEvents += 1
			end
			if bot.liftUrgent and not bot.wasUrgent then
				urgentEvents += 1
			end
			bot.wasUrgent = bot.liftUrgent
			if math.abs(bot.lift - lift0) / dt > 25 then
				popFrames += 1
			end
		end
		for i = 1, #field - 1 do
			for j = i + 1, #field do
				local a, c = field[i], field[j]
				if math.abs(AIRacers.signedGap(a.station, c.station, L)) < AVOID.length then
					-- Penetration depth in each axis of the cross-section envelope; both must exceed the tolerance
					-- for wing to go through wing (a 0.01 stud wingtip touch on the grid is not an overlap).
					local sideways = AVOID.span - math.abs((a.lateral + (a.side or 0)) - (c.lateral + (c.side or 0)))
					local vertical = AVOID.clearHeight - math.abs((a.height + a.lift) - (c.height + c.lift))
					local depth = math.min(sideways, vertical)
					if depth > worst then
						worst = depth
						worstAt = string.format("t=%.2f %d/%d gap=%.1f dLat=%.1f", n * dt, a.id, c.id, AIRacers.signedGap(a.station, c.station, L), a.lateral - c.lateral)
					end
					if depth > TOL then
						overlaps += 1
					end
				end
			end
		end
	end
	print(string.format("  field sim: %d steps, worst penetration %.2f studs (%s), max lift %.2f, overlap frames %d", steps, worst, worstAt, maxLiftSeen, overlaps))
	local botMinutes = #field * steps * dt / 60
	print(
		string.format(
			"  field sim: lift events %d (%.2f per bot per minute), urgent climbs %d (%.2f per bot per minute), frames climbing > 25 studs/s %d, max climb %.1f studs/s, max side step %.1f studs/s",
			liftEvents,
			liftEvents / botMinutes,
			urgentEvents,
			urgentEvents / botMinutes,
			popFrames,
			maxClimb,
			maxSideRate
		)
	)
	eq(overlaps, 0, "simulated field: no frame with wing through wing")
	-- Planned passes (owner 2026-10-19 "constantly bumping"): before, the 0.1 s lag climbed at up to 84 studs/s in this
	-- sim (245 bot-frames over 25 studs/s); the eased spring stays under climbRate except for climbs that cannot wait,
	-- which are capped at urgentClimbRate.
	check(maxClimb <= AVOID.urgentClimbRate + 1e-6, string.format("climb capped at urgentClimbRate (%.1f)", maxClimb))
	check(maxSideRate <= AVOID.sideRate + 1e-6, string.format("side step capped at sideRate (%.1f)", maxSideRate))
	check(popFrames < 150, string.format("fewer bot-frames climbing over 25 studs/s than the old lag's 245 (%d)", popFrames))
	check(maxLiftSeen <= AVOID.maxLift + 1e-9, "lift never exceeds maxLift")
	-- Line of sight: lanes plus the largest lift stay inside the flight corridor (MAP_PLAN_SCHEMA flight.corridor
	-- ceiling 44 above the line).
	check(PlaneConfig.AI_LANES.maxHeight + weave.vertical + AVOID.maxLift <= ItemRules.TUNING.corridorCeiling, "lifted bots stay under the corridor ceiling")

	-- Start: the grid with the fastest bots in front separates, so nobody lifts off the grid.
	local start: { any } = {}
	for i = 1, 7 do
		local st, lat = AIRacers.legacyGridSlot(slots[i], grid)
		local cfg = PlaneConfig.AI_BOTS[i]
		table.insert(start, {
			id = i,
			station = st,
			lateral = lat,
			height = grid.height,
			heightOffset = cfg.heightOffset,
			weaveScale = 0,
			lift = 0,
			liftTarget = 0,
			currentSpeed = cfg.baseSpeed,
		})
	end
	AIRacers.solveLifts(start, L)
	local lifted = 0
	for _, s0 in start do
		if s0.liftTarget > 0 then
			lifted += 1
		end
	end
	eq(lifted, 0, "no bot lifts on a separating grid")
end

------------------------------------------------------------------------------------------------------------------------
-- Integration: AIRacers over fake instances and the REAL ItemService (stand-in hooks for kit/ItemEffects)
-- Drives spawnBots/resetBots/refreshField/step through whole races: seats on join/leave, grid placement, ring boosts,
-- pod pickups, item use, missile hits through setBotHitHandler, laps and finishes, attribute throttling, and that the
-- Boosts folder is scanned once per track instead of every frame. Runtime errors here would be Studio errors.
------------------------------------------------------------------------------------------------------------------------
do
	local L = 5450
	local fakeNow = 1000.0
	local logs: { string } = {}
	local deferred: { () -> () } = {}

	local function newSignal(): any
		local sig = { handlers = {} }
		function sig:Connect(fn: any): any
			table.insert(self.handlers, fn)
			return { Disconnect = function() end }
		end
		function sig:Fire(...: any)
			for _, fn in self.handlers do
				fn(...)
			end
		end
		return sig
	end

	-- Minimal instance: attributes, children (Parent assignment re-parents), IsA by class list, Destroy.
	local function newInst(className: string, name: string, isA: { string }?): any
		local raw: { [string]: any } = { ClassName = className, Name = name, __isInstance = true, attrs = {}, children = {} }
		local classes: { [string]: boolean } = { [className] = true, Instance = true }
		local extra: { string } = isA or {}
		for _, c in extra do
			classes[c] = true
		end
		local inst: any
		local methods = {}
		function methods.IsA(_self: any, c: string): boolean
			return classes[c] == true
		end
		function methods.GetAttribute(_self: any, k: string): any
			return raw.attrs[k]
		end
		function methods.SetAttribute(_self: any, k: string, v: any)
			raw.attrs[k] = v
			raw.attrWrites = (raw.attrWrites or 0) + 1
		end
		function methods.FindFirstChild(_self: any, n: string): any
			for _, c in raw.children do
				if c.Name == n then
					return c
				end
			end
			return nil
		end
		function methods.GetChildren(_self: any): { any }
			return table.clone(raw.children)
		end
		function methods.GetDescendants(_self: any): { any }
			raw.descendantScans = (raw.descendantScans or 0) + 1
			local out = {}
			local function walk(i: any)
				for _, c in i.children do
					table.insert(out, c)
					walk(c)
				end
			end
			walk(raw)
			return out
		end
		function methods.Destroy(self: any)
			self.Parent = nil
			raw.destroyed = true
		end
		inst = setmetatable({}, {
			__index = function(_t: any, k: string): any
				if k == "Position" and raw.CFrame then
					return raw.CFrame.Position
				end
				local m = (methods :: any)[k]
				if m then
					return m
				end
				return raw[k]
			end,
			__newindex = function(_t: any, k: string, v: any)
				if k == "Parent" then
					local old = raw.Parent
					if old then
						local idx = table.find(old.children, inst)
						if idx then
							table.remove(old.children, idx)
						end
					end
					raw.Parent = v
					if v then
						table.insert(v.children, inst)
					end
				else
					raw[k] = v
				end
			end,
		})
		return inst
	end

	local workspaceFake = newInst("Workspace", "Workspace")
	local planesFolder = newInst("Folder", "Planes")
	planesFolder.Parent = workspaceFake
	local boosts = newInst("Folder", "BoostsAndPods")

	-- Straight course along -Z (right = +X): station s sits at (0, 100, -s).
	local function courseAt(st: number): any
		return V3.new(0, 100, -(st % L))
	end
	local function addMark(name: string, station: number, lateral: number, height: number, attrs: { [string]: any })
		local part = newInst("Part", name, { "BasePart" })
		part.CFrame = roblox.CFrame.new(courseAt(station) + V3.new(lateral, height, 0))
		for k, v in attrs do
			part:SetAttribute(k, v)
		end
		part.Parent = boosts
		local core = newInst("Part", name .. "_CoreVisual", { "BasePart" })
		core.Parent = part
	end
	addMark("BoosterRing_Start_1", 130, 0, 14, { TriggerType = "BoosterRing" })
	addMark("GroundBoost_Start", 496, 0, 1, { TriggerType = "GroundBoostPad" })
	addMark("BoosterRing_5_Final", 5215, 0, 14, { TriggerType = "BoosterRing" })
	-- One pod per colour, each inside some roster lane's reach; a Speed pod bots must ignore.
	addMark("Pod_Red_Mid", 400, 4, 11, { ItemPodSpawn = true, PodType = "Red", RespawnSeconds = 4 })
	addMark("Pod_Red_Left", 405, -10, 9, { ItemPodSpawn = true, PodType = "Red", RespawnSeconds = 4 })
	addMark("Pod_Blue_Right", 1650, 10, 10, { ItemPodSpawn = true, PodType = "Blue", RespawnSeconds = 4 })
	addMark("Pod_Green_High", 2500, -8, 16, { ItemPodSpawn = true, PodType = "Green", RespawnSeconds = 4 })
	addMark("Pod_Yellow_Mid", 3000, 0, 12, { ItemPodSpawn = true, PodType = "Yellow", RespawnSeconds = 4 })
	addMark("Pod_Rainbow_Right", 3500, 8, 13, { ItemPodSpawn = true, PodType = "Rainbow", RespawnSeconds = 4 })
	addMark("Pod_Speed", 600, 0, 12, { ItemPodSpawn = true, PodType = "Speed", RespawnSeconds = 4 })

	local waypoints = { { station = 0 }, { station = L } }
	local SplineFake = {
		loadWaypoints = function(): (any, number)
			return waypoints, L
		end,
		sampleAtStation = function(st: number): (any, any, number)
			return courseAt(st), V3.new(0, 0, -1), 0
		end,
		projectPosition = function(p: any): (number, any, any, number)
			local st = (-p.Z) % L
			return st, courseAt(st), V3.new(0, 0, -1), math.sqrt(p.X * p.X + (p.Y - 100) ^ 2)
		end,
	}
	local TrackFake = {
		getActiveId = function(): string
			return "TEST-1"
		end,
		getBoostsFolder = function(): any
			return boosts
		end,
		startCFrame = function(_slot: number): any
			return nil -- legacy station grid
		end,
	}
	local created = 0
	local PlaneBuilderFake = {
		createPlane = function(name: string, _color: any, _accent: any, cf: any, isAI: boolean): any
			created += 1
			assert(isAI == true, "bots are built as AI planes")
			local model = newInst("Model", name)
			local hull = newInst("Part", "Hull", { "BasePart" })
			hull.CFrame = cf
			hull.Parent = model
			model.PrimaryPart = hull
			return model
		end,
	}

	local PlayersFake = { list = {}, PlayerAdded = newSignal(), PlayerRemoving = newSignal() }
	function PlayersFake:GetPlayers(): { any }
		return table.clone(self.list)
	end
	local function newPlayer(userId: number): any
		local p = newInst("Player", "P" .. userId)
		p.UserId = userId
		return p
	end
	local records: { [any]: any } = {}
	local FlightServerFake = { records = records }
	-- economy v3 phase 4: the disguise is a server module (name pool, catalog); the field sim only needs distinct names
	local disguiseCount = 0
	local botDisguiseFake = {
		deal = function(_bots: any): (string, any, boolean)
			disguiseCount += 1
			return "Racer" .. tostring(disguiseCount) .. "x", { outfit = "o:none0:4047884046:382537569", skin = roblox.Color3.new(1, 1, 1) }, true
		end,
		setNames = function() end,
		setLook = function() end,
		recheck = function() end,
	}

	-- REAL ItemService, loaded the way items_spec loads it, with a world over the fake bots and pods.
	local itemTok = { __token = "ItemRules" }
	local ItemService = loadWithEnv("src/server/ItemService.luau", {
		game = {
			GetService = function(_self: any, name: string): any
				if name == "ReplicatedStorage" then
					return { WaitForChild = function(): any
						return { WaitForChild = function(): any
							return itemTok
						end }
					end }
				end
				return {}
			end,
		},
		require = function(t: any): any
			assert(t == itemTok, "ItemService header required something other than ItemRules")
			return ItemRules
		end,
		Vector3 = V3,
		print = function(line: any)
			table.insert(logs, tostring(line))
		end,
	})

	-- Fresh AIRacers with the rich fakes.
	local tokens: { [string]: any } = {}
	local function tok(name: string): any
		tokens[name] = tokens[name] or { __token = name, Name = name, IsA = function(_s: any, c: string): boolean
			return c == "ModuleScript"
		end }
		return tokens[name]
	end
	local mods: { [string]: any } = {
		PlaneConfig = PlaneConfig,
		ItemRules = ItemRules,
		FidelityRules = FidelityRules,
		TriggerRules = TriggerRules,
		SailGateRules = {
			configOf = function(_i: any): any
				return nil
			end,
			live = function(_t: number, _c: any): boolean
				return true
			end,
		},
		SplineUtils = SplineFake,
		TrackRegistry = TrackFake,
		PlaneBuilder = PlaneBuilderFake,
		ItemService = ItemService,
		FlightServer = FlightServerFake,
		CarConfig = { RIDE_HEIGHT = 1.9 },
		CarBuilder = {},
		RacerPaint = { paintBot = function() end },
		GridOrder = GridOrder,
		RacerViewRules = RacerViewRules,
		BotPaceRules = BotPaceRules,
		BotDisguise = botDisguiseFake,
		BossConfig = { forZone = function(_z: any): any
			return nil
		end },
		RaceScope = loadRaceScope(),
		-- RaceAttr's single-race path: workspace:GetAttribute, unchanged.
		RaceAttr = { here = function(n: string): any
			return workspaceFake:GetAttribute(n)
		end },
		RaceFlowRules = RaceFlowRules,
	}
	local sharedFake = { WaitForChild = function(_s: any, n: string): any
		return tok(n)
	end }
	local parentFake = { PlaneBuilder = tok("PlaneBuilder"), kit = { CarBuilder = tok("CarBuilder"), RacerPaint = tok("RacerPaint"), BotDisguise = tok("BotDisguise") }, FindFirstChild = function(_s: any, n: string): any
		return if mods[n] then tok(n) else nil
	end }
	local AI = loadWithEnv("src/server/AIRacers.luau", {
		game = {
			GetService = function(_self: any, name: string): any
				if name == "Players" then
					return PlayersFake
				elseif name == "ReplicatedStorage" then
					return { WaitForChild = function(): any
						return sharedFake
					end }
				end
				error("unexpected service " .. name)
			end,
		},
		script = { Parent = parentFake },
		require = function(t: any): any
			return assert(mods[t.__token], "no fake for " .. tostring(t.__token))
		end,
		workspace = workspaceFake,
		Instance = { new = function(c: string): any
			return newInst(c, c)
		end },
		task = { defer = function(fn: any, ...: any)
			local args = table.pack(...)
			table.insert(deferred, function()
				fn(table.unpack(args, 1, args.n))
			end)
		end },
		os = { clock = function(): number
			return fakeNow
		end },
		typeof = function(v: any): string
			if type(v) == "table" and v.__isInstance then
				return "Instance"
			end
			return typeof(v)
		end,
		print = function(line: any)
			table.insert(logs, tostring(line))
		end,
		Vector3 = V3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
	})
	-- workspace:FindFirstChild("Planes") must find the folder
	workspaceFake.Planes = nil

	local function flush()
		while #deferred > 0 do
			local fn = table.remove(deferred, 1)
			if fn then
				fn()
			end
		end
	end
	local function logged(needle: string): number
		local n = 0
		for _, line in logs do
			if string.find(line, needle, 1, true) then
				n += 1
			end
		end
		return n
	end
	local function botById(id: number): any
		for _, b in AI.bots do
			if b.id == id then
				return b
			end
		end
		return nil
	end

	-- Live item service: pods from the fake folder, positions from the fake hulls; hooks stand in for ItemEffects
	-- (boost/magnet to the bot handlers, a missile hits the nearest racer ahead through applyToBot).
	local used: { [string]: number } = {}
	local function bump(k: string)
		used[k] = (used[k] or 0) + 1
	end
	local function botOf(racerId: string): number?
		local kind, num = ItemService.parseRacerId(racerId)
		return if kind == "bot" then num else nil
	end
	local world = {
		now = function(): number
			return fakeNow
		end,
		racerPosition = function(racerId: string): any
			local id = botOf(racerId)
			local b = if id then botById(id) else nil
			return if b and b.hull then b.hull.Position else nil
		end,
		findPod = function(name: string): any
			local pod = boosts:FindFirstChild(name)
			if not pod or pod:GetAttribute("ItemPodSpawn") ~= true then
				return nil
			end
			return { position = pod.Position, podType = pod:GetAttribute("PodType"), respawnSeconds = pod:GetAttribute("RespawnSeconds") }
		end,
		publish = function() end,
		log = function(line: string)
			table.insert(logs, line)
		end,
		canAct = function(racerId: string): (boolean, string?)
			local id = botOf(racerId)
			local b = if id then botById(id) else nil
			return b ~= nil and not b.finished, "finished"
		end,
	}
	local hooks = {
		applyBoost = function(racerId: string, params: any, level: number)
			bump("boost")
			ItemService.applyToBot(botOf(racerId) :: number, { kind = "boost", seconds = params.seconds, speed = params.speed, level = level })
		end,
		spawnMissile = function(racerId: string, params: any, _level: number)
			bump("missile")
			local shooter = botById(botOf(racerId) :: number)
			local best, bestGap = nil, math.huge
			for _, b in AI.bots do
				local g = AI.signedGap(shooter.station, b.station, L)
				if b ~= shooter and g > 0 and g < bestGap then
					best, bestGap = b, g
				end
			end
			if best then
				ItemService.applyToBot(best.id, { kind = "hit", seconds = params.stunSeconds, source = "missile" })
			end
		end,
		spawnTrap = function()
			bump("trap")
		end,
		setShield = function(racerId: string, params: any, level: number)
			bump("shield")
			ItemService.applyToBot(botOf(racerId) :: number, { kind = "shield", seconds = params.seconds, level = level })
		end,
		magnetPull = function(racerId: string, params: any, level: number)
			bump("magnet")
			ItemService.applyToBot(botOf(racerId) :: number, { kind = "magnet", seconds = params.seconds, pull = params.pull, level = level })
		end,
	}
	local podTaken = 0
	ItemService.setPodTakenHandler(function(podName: string)
		podTaken += 1
		boosts:FindFirstChild(podName):SetAttribute("OnCooldown", true)
	end)

	-- 1. Boot with no player: seven bots, slots 8..2, items not started yet.
	AI.spawnBots()
	eq(#AI.bots, 7, "boot: seven bots with no player")
	eq(created, 7, "boot: seven planes built")
	eq(#planesFolder:GetChildren(), 7, "boot: planes parented under workspace.Planes")
	check(logged("[SkyRally][AI] field players=0 bots=7 entrants=7/8") == 1, "boot: field line logged")
	check(logged("[SkyRally][AI] item handlers registered hit=yes effect=yes") == 1, "boot: hit and effect handlers registered with ItemService")
	for i, b in AI.bots do
		eq(b.id, i, "boot: bots in roster order")
		eq(b.slot, 9 - i, "boot: bot " .. i .. " slot")
		eq(b.racerId, "bot:" .. i, "boot: racer id")
		-- The propeller is a welded rotor every client turns (client/VehicleMotion): the server keeps no prop state.
		check((b :: any).spinner == nil and (b :: any).propAngle == nil, "boot: no server-side propeller state")
	end
	-- Sunny (slot 2) sits beside the pole: starts one clearance up; nobody else does.
	local sunny = botById(7)
	near(sunny.hull.Position.Y, 100 + PlaneConfig.AI_GRID.height + AVOID.clearHeight, 1e-6, "slot-2 bot starts lifted beside the pole")
	near(botById(1).hull.Position.Y, 100 + PlaneConfig.AI_GRID.height, 1e-6, "front bot starts at grid height")
	near(botById(1).hull.Position.X, 12, 1e-6, "front bot on the right slot")
	near(-botById(1).hull.Position.Z, 102, 1e-6, "front bot at the front row")

	-- 2. First player joins in the open window: field stays seven (the reserved seat).
	local p1 = newPlayer(101)
	table.insert(PlayersFake.list, p1)
	PlayersFake.PlayerAdded:Fire(p1)
	flush()
	eq(#AI.bots, 7, "first joiner takes the reserved seat")
	records[p1] = { hull = { Position = V3.new(0, 111, -18), Parent = true }, station = 18, finished = false, lap = 1 }

	-- 3. Items start (init.server order), then fly 40 s.
	ItemService.active = ItemService.new(world, hooks)
	local dt = 1 / 30
	-- Separation on the REAL step path (grid lift, rubber band against the player, item boosts and spin-outs from real
	-- pickups and hits), not only the spec's own motion model above: wing-through-wing frames between bots.
	local realWorst = -math.huge
	local realWorstAt = ""
	local realOverlaps = 0
	-- MEASUREMENT, not asserted (review 2026-10-18, known open issue): the pole player flying level at BASE_SPEED from
	-- slot 1 (station 18, centre line, grid height) while the field merges. Bots do not see player planes; the slot-2
	-- bot's grid lift fades with the merge while it is still alongside, so it drops through the pole player's wing on
	-- the way to a low-tier lane. Turn this into eq(poleOverlaps, 0) once bots treat player planes as obstacles.
	local poleStart: number? = nil
	local poleWorst = -math.huge
	local poleWorstAt = ""
	local poleOverlaps = 0
	local function checkPole()
		local t0 = poleStart
		if not t0 then
			return
		end
		local poleSt = PlaneConfig.AI_GRID.station + (fakeNow - t0) * PlaneConfig.BASE_SPEED
		for _, b in AI.bots do
			local gap = AI.signedGap(poleSt, b.station, L)
			if math.abs(gap) < AVOID.length then
				local depth = math.min(
					AVOID.span - math.abs(b.lateral + (b.side or 0)),
					AVOID.clearHeight - math.abs(b.height + b.lift - PlaneConfig.AI_GRID.height)
				)
				if depth > poleWorst then
					poleWorst = depth
					poleWorstAt = string.format("%s t=%.2f gap=%.1f dLat=%.1f h=%.1f", b.name, fakeNow - t0, gap, b.lateral, b.height + b.lift)
				end
				if depth > 0.5 then
					poleOverlaps += 1
				end
			end
		end
	end
	-- Lift motion on the real step path (owner 2026-10-19: bots "constantly bumping" were these separation climbs).
	local realPrevLift: { [any]: number } = {}
	local realPrevTarget: { [any]: number } = {}
	local realMaxClimb = 0
	local realLiftEvents = 0
	local realPopFrames = 0
	local realFrames = 0
	local function checkSeparation()
		checkPole()
		local list = AI.bots
		realFrames += 1
		for _, b in list do
			local prev = realPrevLift[b]
			if prev then
				local climb = math.abs(b.lift - prev) / dt
				realMaxClimb = math.max(realMaxClimb, climb)
				if climb > 25 then
					realPopFrames += 1
				end
			end
			if b.liftTarget > 0.5 and (realPrevTarget[b] or 0) <= 0.5 then
				realLiftEvents += 1
			end
			realPrevLift[b] = b.lift
			realPrevTarget[b] = b.liftTarget
		end
		for i = 1, #list - 1 do
			for j = i + 1, #list do
				local a, c = list[i], list[j]
				local gap = AI.signedGap(a.station, c.station, L)
				if math.abs(gap) < AVOID.length then
					local depth = math.min(
						AVOID.span - math.abs((a.lateral + (a.side or 0)) - (c.lateral + (c.side or 0))),
						AVOID.clearHeight - math.abs((a.height + a.lift) - (c.height + c.lift))
					)
					if depth > realWorst then
						realWorst = depth
						realWorstAt = string.format("%s/%s gap=%.1f dLat=%.1f", a.name, c.name, gap, a.lateral - c.lateral)
					end
					if depth > 0.5 then
						realOverlaps += 1
					end
				end
			end
		end
	end
	local function run(seconds: number, raceStart: number)
		for _ = 1, math.floor(seconds / dt) do
			fakeNow += dt
			local elapsed = fakeNow - raceStart
			records[p1].station = (18 + elapsed * 118) % L
			AI.step(dt, elapsed * 118, elapsed, function(bot: any)
				table.insert(logs, "finished " .. bot.name)
			end)
			checkSeparation()
			flush()
		end
	end
	local raceStart = fakeNow
	local scansBefore = boosts.descendantScans or 0
	local sawBoost = false
	poleStart = raceStart
	for _ = 1, 30 do
		run(0.1, raceStart)
		for _, b in AI.bots do
			if b.plane:GetAttribute("BoostState") == "Standard" then
				sawBoost = true
			end
		end
	end
	poleStart = nil
	print(string.format("  pole player (level, BASE_SPEED) vs bots in the first 3 s: worst penetration %.2f (%s), overlap frames %d", poleWorst, poleWorstAt, poleOverlaps))
	run(37, raceStart)
	check(sawBoost, "ring at 130 boosts bots (BoostState replicated)")
	eq((boosts.descendantScans or 0) - scansBefore, 1, "Boosts folder scanned once, not per frame")
	check(logged("[SkyRally][AI] track marks TEST-1:5450.0 boosts=3 itemPods=6") == 1, "track marks: 3 boosts, 6 item pods (Speed pod ignored)")
	for _, b in AI.bots do
		check(b.travelled > 3000, b.name .. " flew the course")
		check(b.weaveScale == 1, b.name .. " merged into its lane")
		-- (economy v3 phase 4: bot pace is rolled per race, so a bot can be at the lap seam at this instant) the fake
		-- course is a straight line whose end jumps back to its start: the eased hull is still crossing that jump just past
		-- the line, which a real (closed) course never has, so the lane check skips that window
		local nearSeam = b.station < 120 or b.station > L - 20
		check(nearSeam or math.abs(b.hull.Position.X - (b.lateral + (b.side or 0))) < 3, b.name .. " hull follows its lane")
	end
	check(logged("[SkyRally][ITEM] pickup racer=bot:") >= 4, "bots picked up item pods through ItemService.pickup")
	eq(logged("[SkyRally][ITEM] pickup racer=bot:"), podTaken, "every bot pickup ran the pod-taken handler")
	eq(logged("Pod_Speed"), 0, "bots never request a Speed pod")
	eq(logged("[SkyRally][ITEM] reject"), 0, "no pickup or use rejected for a bot")
	check(logged("[SkyRally][AI] item bot=") >= 3, "bots fired items")
	check((used.missile or 0) >= 1, "a bot fired a missile")
	check(logged("[SkyRally][AI] hit bot=") >= 1, "a missile hit spun a bot out through setBotHitHandler")
	local attrWrites = 0
	for _, b in AI.bots do
		attrWrites += (b.plane.attrWrites or 0)
	end
	check(attrWrites < 7 * 40 * 25, string.format("attribute writes throttled (%d over 40 s for 7 bots)", attrWrites))

	-- 4. A direct hit reaction: ~1.2 s spin-out, slowed, recovers.
	local victim = botById(2)
	local before = victim.currentSpeed
	ItemService.applyToBot(2, { kind = "hit", seconds = 1.2, source = "trap" })
	near(victim.stunTimer, 1.2, 1e-9, "hit: 1.2 s stun")
	eq(victim.plane:GetAttribute("Stunned"), true, "hit: Stunned attribute")
	run(0.6, raceStart)
	check(victim.currentSpeed < before * 0.7, "hit: bot slowed while spinning")
	run(0.8, raceStart)
	eq(victim.stunTimer, 0, "hit: stun over after ~1.2 s")
	eq(victim.plane:GetAttribute("Stunned"), false, "hit: Stunned cleared")

	-- 5. Mid-race join: the last-placed bot gives its seat; mid-race leave: the seat waits for the reset.
	local p2 = newPlayer(202)
	table.insert(PlayersFake.list, p2)
	local lastPlaced = AI.pickTrimVictim(AI.bots, L)
	PlayersFake.PlayerAdded:Fire(p2)
	flush()
	eq(#AI.bots, 6, "mid-race join: six bots for two players")
	check(botById(lastPlaced.id) == nil, "mid-race join: the last-placed bot left")
	check(lastPlaced.plane.destroyed == true, "mid-race join: its plane destroyed")
	check(logged("reason=join need=6 removed=[" .. lastPlaced.name .. "]") == 1, "mid-race join logged")
	table.remove(PlayersFake.list, table.find(PlayersFake.list, p2))
	PlayersFake.PlayerRemoving:Fire(p2)
	flush()
	eq(#AI.bots, 6, "mid-race leave: no bot appears mid-lap")
	eq(AI.fieldInfo().pendingRefill, true, "mid-race leave: refill pending")

	-- 6. Three laps: every bot finishes once, in order.
	run(140, raceStart)
	eq(logged("finished "), 6, "every racing bot finished once")
	for _, b in AI.bots do
		check(b.finished and b.lap == PlaneConfig.TOTAL_LAPS, b.name .. " finished lap 3")
	end

	-- 7. Reset: back to eight entrants on the grid.
	AI.resetBots()
	eq(#AI.bots, 7, "reset: seven bots for one player")
	eq(AI.fieldInfo().pendingRefill, false, "reset: refill done")
	for i, b in AI.bots do
		eq(b.id, i, "reset: roster order")
		eq(b.slot, 9 - i, "reset: slot")
		check(not b.finished and b.lap == 1 and b.travelled == 0 and b.stunTimer == 0, b.name .. " reset to the grid")
	end

	-- 8. Open window (first seconds after a reset): a joiner takes the slowest bot's seat, a leaver's seat refills.
	local p3 = newPlayer(303)
	table.insert(PlayersFake.list, p3)
	PlayersFake.PlayerAdded:Fire(p3)
	flush()
	eq(#AI.bots, 6, "open join: six bots")
	eq(botById(7), nil, "open join: the slowest bot gave its seat")
	table.remove(PlayersFake.list, table.find(PlayersFake.list, p3))
	PlayersFake.PlayerRemoving:Fire(p3)
	flush()
	eq(#AI.bots, 7, "open leave: seat refilled at once")
	check(botById(7) ~= nil, "open leave: the roster bot came back")

	-- 9. Full server: no bots, and step still runs; then back to one player.
	for uid = 400, 406 do
		table.insert(PlayersFake.list, newPlayer(uid))
	end
	AI.resetBots()
	eq(#AI.bots, 0, "eight players: no bots")
	run(1, fakeNow)
	PlayersFake.list = { p1 }
	AI.resetBots()
	eq(#AI.bots, 7, "back to one player: seven bots")

	check(logged("setBotHitHandler missing") == 0, "handler API present: no missing line")

	print(string.format("  real-step field: worst penetration %.2f studs (%s), overlap frames %d", realWorst, realWorstAt, realOverlaps))
	local realBotMinutes = #AI.bots * realFrames * dt / 60
	print(
		string.format(
			"  real-step field: lift events %d (%.2f per bot per minute), frames climbing > 25 studs/s %d, max climb %.1f studs/s",
			realLiftEvents,
			realLiftEvents / math.max(realBotMinutes, 1e-6),
			realPopFrames,
			realMaxClimb
		)
	)
	eq(realOverlaps, 0, "real AIRacers.step: no frame with wing through wing between bots")
	check(realMaxClimb <= AVOID.urgentClimbRate + 1e-6, string.format("real step: climb capped (%.1f studs/s, was 118)", realMaxClimb))

	-- A refill in the open window into the slot beside the pole player starts lifted, like a reset does.
	AI.resetBots()
	local p4 = newPlayer(404)
	table.insert(PlayersFake.list, p4)
	PlayersFake.PlayerAdded:Fire(p4)
	flush()
	eq(botById(7), nil, "open join before the refill check: the slowest bot gave its seat")
	table.remove(PlayersFake.list, table.find(PlayersFake.list, p4))
	PlayersFake.PlayerRemoving:Fire(p4)
	flush()
	local refilled = botById(7)
	check(refilled ~= nil and refilled.slot == 2, "open leave refill takes slot 2 beside the pole")
	if refilled then
		near(refilled.hull.Position.Y, 100 + PlaneConfig.AI_GRID.height + AVOID.clearHeight, 1e-6, "open refill beside the pole starts lifted")
	end

	-- Grid order (shared/GridOrder): RaceManager hands resetBots a plan. The human sits anywhere, the bots take the
	-- plan's slots (row-mates fanned), nobody shares a slot, and the lift follows the human's real slot: on slot 2 the
	-- bot on slot 1 beside it starts lifted (the old "slots 1..N" poses missed it); mid-grid nobody overlaps.
	PlayersFake.list = { p1 }
	for _, target in { 2, 5 } do
		local plan: any = nil
		for seed = 1, 2000 do
			local try = GridOrder.assign({ { userId = 101 } }, 7, 8, seed, "race")
			if try.humanSlots[101] == target then
				plan = try
				break
			end
		end
		check(plan ~= nil, "a seed puts the human on slot " .. target)
		if plan then
			p1:SetAttribute("GridSlot", target)
			AI.resetBots(plan)
			eq(#AI.bots, 7, "plan reset: seven bots")
			local lanes: { number } = {}
			for i, cfg in PlaneConfig.AI_BOTS do
				lanes[i] = cfg.laneOffset
			end
			local fanned = GridOrder.fanRowMates(plan.botSlots, lanes)
			local held: { [number]: boolean } = { [target] = true }
			for _, b in AI.bots do
				eq(b.slot, fanned[b.id], "plan reset: bot " .. b.id .. " on its planned slot")
				check(not held[b.slot], "plan reset: slot " .. b.slot .. " held once")
				held[b.slot] = true
				local lifted = target == 2 and b.slot == 1
				local expectY = 100 + PlaneConfig.AI_GRID.height + (if lifted then AVOID.clearHeight else 0)
				near(b.hull.Position.Y, expectY, 1e-6, string.format("human on slot %d: bot on slot %d lift", target, b.slot))
			end
			p1:SetAttribute("GridSlot", nil)
		end
	end
	check(logged("grid=plan") >= 2, "plan reset logged")
end

print(string.format("field_spec: %d checks, %d failed", checks, failures))
if failures > 0 then
	process.exit(1)
end
