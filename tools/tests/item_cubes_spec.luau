--!strict
-- Lune spec for item cubes v3 (docs/design/ITEM_BOXES.md section 11): the staggered set layout of every launch plan
-- against tools/map/item_cubes.json (ranks, depth, the chain line, budget, boost blocks away from the sets), the shared
-- pod ledger in ItemService (1.0 s for everyone, a simultaneous take goes to exactly one racer, bots on the same
-- ledger), the rank lock, the DKR level-up (second cube, roulette queue, MAXED), the ghost cycle's weighting
-- (ItemRules.ghostFor / ghostSchedule / ghostAt), pod heights (podHoverY, coinHover), the plane pickup capsule
-- (liftedDistance, planeLift) and the static wiring (Gameplay attributes, RaceManager, client triggers, ItemArt looks,
-- the HUD queue, ItemClient's cheap shared clock).
-- Usage: lune run tools/tests/item_cubes_spec.luau   (any cwd). Errors on the first failed check.
local fs = require("@lune/fs") :: any
local luau = require("@lune/luau") :: any
local process = require("@lune/process") :: any
local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde") :: any

local ItemRules = require("../../src/shared/ItemRules")

local V3 = roblox.Vector3

local checks = 0
local function check(cond: any, msg: string)
	checks += 1
	if not cond then
		error("FAIL " .. msg, 2)
	end
end
local function near(a: number, b: number, tol: number, msg: string)
	checks += 1
	if math.abs(a - b) > tol then
		error(string.format("FAIL %s: expected %.4f, got %.4f", msg, b, a), 2)
	end
end

local selfPath = debug.info(1, "s")
local root = string.match(selfPath, "^(.*)/tools/tests/[^/]+$") or process.cwd
local function read(rel: string): string
	return fs.readFile(root .. "/" .. rel)
end

local function loadItemService(): any
	local token = newproxy(false)
	local shared = {
		WaitForChild = function(_self: any, _name: string): any
			return token
		end,
	}
	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_self: any, _name: string): any
				return shared
			end,
		},
		Players = {},
	}
	local env = {
		game = {
			GetService = function(_self: any, name: string): any
				return assert(services[name], "unexpected service " .. name)
			end,
		},
		require = function(target: any): any
			assert(target == token, "ItemService required something other than Shared.ItemRules at load")
			return ItemRules
		end,
		Vector3 = V3,
	}
	local chunk = luau.load(read("src/server/ItemService.luau"), { debugName = "ItemService", environment = env })
	return chunk()
end
local ItemService = loadItemService()

------------------------------------------------------------------------------------------------------------------------
-- 1. Staggered set layout of every launch plan (the same rules tools/map/item_rows.py enforces at author time)
------------------------------------------------------------------------------------------------------------------------

local RULES = serde.decode("json", read("tools/map/item_cubes.json"))
local ITEM: { [string]: boolean } = {}
for _, t in RULES.itemTypes do
	ITEM[t] = true
end
local SINGLE: { [string]: boolean } = {}
for _, t in RULES.singleTypes do
	SINGLE[t] = true
end
local TAN = math.tan(math.rad(RULES.maxChainAngleDeg))

local MAPS = { "hub0", "island2", "space4", "dino4", "forest1", "snow1" }
for _, key in MAPS do
	local plan = serde.decode("json", read("map/" .. key .. "/plan.json"))
	local sk = plan.skyrally
	local L = sk.route.targetLength
	local vr = if sk.vehicle == "car" then RULES.car else RULES.plane
	local ranks = vr.ranks[key] or vr.ranks.default
	local pods = sk.gameplay.pods
	local bySet: { [string]: { any } } = {}
	local sets: { { any } } = {}
	local cubes = 0
	for _, p in pods do
		if ITEM[p.type] then
			cubes += 1
			check(type(p.cubeSet) == "string" and (p.cubeRank == 1 or p.cubeRank == 2), key .. ": cube " .. p.name .. " has a set and rank")
			local s = bySet[p.cubeSet]
			if not s then
				s = {}
				bySet[p.cubeSet] = s
				table.insert(sets, s)
			end
			table.insert(s, p)
		else
			check(SINGLE[p.type], key .. ": pod " .. p.name .. " is a cube or a Speed/Air single")
		end
	end
	local function front(s: { any }): number
		local m = math.huge
		for _, p in s do
			m = math.min(m, p.station)
		end
		return m
	end
	table.sort(sets, function(x, y)
		return front(x) < front(y)
	end)
	check(cubes <= RULES.maxCubesPerMap, string.format("%s: %d cubes within the budget %d", key, cubes, RULES.maxCubesPerMap))
	check(cubes * RULES.cubeParts <= RULES.maxCubeParts, key .. ": cube parts within maxCubeParts")
	check(#sets >= vr.setsPerLap[1] and #sets <= vr.setsPerLap[2], string.format("%s: %d sets per lap", key, #sets))
	if sk.vehicle == "plane" then
		check(cubes > 21, key .. ": more plane cubes than v2's 21 (owner ask)")
	end
	for _, s in sets do
		local f, b = {}, {}
		for _, p in s do
			table.insert(if p.cubeRank == 1 then f else b, p)
		end
		local tag = key .. " " .. s[1].cubeSet
		check(#f == #ranks[1] and #b == #ranks[2], tag .. ": 2 + 3")
		local depth = b[1].station - f[1].station
		check(depth >= RULES.rankDepthRange[1] and depth <= RULES.rankDepthRange[2], tag .. ": ranks 25-40 studs apart")
		check(depth / 128 < ItemRules.CUBES.rankLockSeconds, tag .. ": the chained cube comes after the rank's own")
		for _, x in f do
			check(x.station == f[1].station, tag .. ": front rank at one station")
			local best = math.huge
			for _, y in b do
				best = math.min(best, math.sqrt((x.lateral - y.lateral) ^ 2 + (x.height - y.height) ^ 2))
			end
			check(best <= TAN * depth, tag .. ": " .. x.name .. " chains to a back cube on a gentle line")
		end
		for _, y in b do
			check(y.station == b[1].station, tag .. ": back rank at one station")
			for _, x in f do
				check(math.abs(y.lateral - x.lateral) >= 4, tag .. ": staggered, no back cube dead behind a front one")
			end
		end
		local seen: { [string]: boolean } = {}
		for _, p in s do
			check(not seen[p.type], tag .. ": five glass colours")
			seen[p.type] = true
		end
	end
	check(front(sets[1]) >= vr.firstRowMin, key .. ": first set clear of the start")
	local lastBack = 0
	for _, p in sets[#sets] do
		lastBack = math.max(lastBack, p.station)
	end
	check(lastBack <= L - vr.lastRowMargin, key .. ": last set clear of the finish")
	for i, s in sets do
		local nextSt = if i < #sets then front(sets[i + 1]) else front(sets[1]) + L
		local gap = nextSt - front(s)
		check(gap >= vr.minGap and gap <= vr.maxGap, string.format("%s: gap %.0f after %.0f within %d..%d", key, gap, front(s), vr.minGap, vr.maxGap))
	end
	for _, p in pods do
		if SINGLE[p.type] then
			for _, q in pods do
				if ITEM[q.type] then
					local d = math.abs(p.station - q.station)
					check(math.min(d, L - d) >= RULES.singleClearOfSet, key .. ": " .. p.name .. " is not next to a cube set")
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- 2. Shared ledger, simultaneous take, rank lock, DKR level-up (ItemService + ItemRules)
------------------------------------------------------------------------------------------------------------------------

local function harness(pods: { [string]: any }): any
	local h = { clock = { t = 100 }, positions = {}, pods = pods, logs = {}, published = {}, told = {} }
	local function hook()
		return function() end
	end
	local hooks = { applyBoost = hook(), spawnMissile = hook(), spawnTrap = hook(), setShield = hook(), magnetPull = hook() }
	local world = {
		now = function(): number
			return h.clock.t
		end,
		racerPosition = function(racer: string): any
			return h.positions[racer]
		end,
		findPod = function(name: string): any
			return h.pods[name]
		end,
		publish = function(racer: string, state: any)
			h.published[racer] = state
		end,
		notify = function(racer: string, event: string, payload: any)
			h.told[racer] = { event = event, payload = payload }
		end,
		log = function(line: string)
			table.insert(h.logs, line)
		end,
		random = function(): number
			return 0.5
		end,
	}
	h.service = ItemService.new(world :: any, hooks :: any)
	return h
end

local P1 = ItemService.playerRacerId(101)
local P2 = ItemService.playerRacerId(202)
local BOT = ItemService.botRacerId(3)
local R = ItemRules.CUBES.respawn
local SPIN = ItemRules.MYSTERY.rouletteSeconds

do -- the owner's numbers
	check(R == 1.0, "shared respawn is the owner's 1.0 s")
	near(ItemRules.podRetrigger(R), R, 1e-9, "the client re-arms a pod when it is back")
	near(ItemRules.podRetrigger(nil), R, 1e-9, "missing attribute: the race respawn")
	near(ItemRules.podRetrigger(0), 0.25, 1e-9, "never a zero throttle")
	check(ItemRules.CUBES.perRacerRespawn == nil and ItemRules.CUBES.sharedRetrigger == nil, "the v2 per-racer numbers are retired")
end

do -- shared: a taken cube is gone for everyone and back for everyone 1.0 s later; exactly one of two racers gets it
	local h = harness({
		Cube = { position = V3.new(0, 10, 0), podType = "Red", respawnSeconds = R, mystery = true },
	})
	local s = h.service
	for _, r in { P1, P2, BOT } do
		h.positions[r] = V3.new(3, 10, 0)
	end
	-- Same frame (same clock): the first request wins, the second is refused and told so.
	local ok1 = s.requestPickup(P1, "Cube")
	local ok2, why2 = s.requestPickup(P2, "Cube")
	check(ok1 and not ok2 and why2 == "pod_cooldown", "two racers, same frame: exactly one gets the cube")
	check(h.told[P2] and h.told[P2].payload.reason == "pod_cooldown", "the loser is told (CUBE TAKEN!)")
	check(ItemRules.pickupNotice(nil, "pod_cooldown") == "CUBE TAKEN!", "and the caption says so")
	check(h.published[P2] == nil, "the loser got nothing")
	local okBot, whyBot = s.requestPickup(BOT, "Cube")
	check(not okBot and whyBot == "pod_cooldown", "bots read the same ledger: gone for the bot too")
	h.clock.t += R - 0.05
	check(not (s.requestPickup(BOT, "Cube")), "still gone for everyone just before 1.0 s")
	h.clock.t += 0.1
	check((s.requestPickup(BOT, "Cube")), "back for everyone after 1.0 s: the bot takes it")
	local okP, whyP = s.requestPickup(P1, "Cube")
	check(not okP and whyP == "pod_cooldown", "and now it is gone for the player the bot beat")

	-- A refused pickup (too far) starts nobody's timer.
	h.clock.t += 5
	h.positions[P2] = V3.new(0, 10, 5000)
	local ok, why = s.requestPickup(P2, "Cube")
	check(not ok and why == "too_far", "far pickup refused")
	h.positions[P2] = V3.new(3, 10, 0)
	check((s.requestPickup(P2, "Cube")), "the refusal did not empty the cube")
	s.resetAll()
	check((s.requestPickup(P1, "Cube")), "reset clears the ledger")
end

do -- rank lock: one cube per rank per pass; the chained back-rank cube is a level-up
	local pods = {
		F1 = { position = V3.new(-8, 10, 0), podType = "Red", respawnSeconds = R, mystery = true, cubeRank = "S#1" },
		F2 = { position = V3.new(8, 10, 0), podType = "Blue", respawnSeconds = R, mystery = true, cubeRank = "S#1" },
		B1 = { position = V3.new(0, 10, 32), podType = "Yellow", respawnSeconds = R, mystery = true, cubeRank = "S#2" },
		B2 = { position = V3.new(16, 10, 32), podType = "Green", respawnSeconds = R, mystery = true, cubeRank = "S#2" },
	}
	local h = harness(pods)
	local s = h.service
	h.positions[P1] = V3.new(4, 10, 0)
	h.positions[P2] = V3.new(4, 10, 0)
	check((s.requestPickup(P1, "F2")), "P1 takes a front cube")
	local ok, why = s.requestPickup(P1, "F1")
	check(not ok and why == "same_rank", "a second front cube in the same pass is left standing")
	check(#h.logs == 1, "same_rank is normal play: no reject line in the log")
	check((s.requestPickup(P2, "F1")), "and the racer behind can take it")
	h.clock.t += 32 / 128 -- the back rank a quarter second later at racing speed
	h.positions[P1] = V3.new(4, 10, 32)
	local okB, outcome = s.requestPickup(P1, "B1")
	check(okB and outcome == "upgrade", "the chained back-rank cube levels the held item up")
	local okB2, whyB2 = s.requestPickup(P1, "B2")
	check(not okB2 and whyB2 == "same_rank", "but only one back-rank cube")
	check(s.getState(P1).level == 2, "one pass through a set: an item and one level-up")
	-- The lock is per racer and runs out.
	check(ItemRules.rankLocked("S#2", 10, "S#2", 10 + ItemRules.CUBES.rankLockSeconds - 0.01), "locked inside rankLockSeconds")
	check(not ItemRules.rankLocked("S#2", 10, "S#2", 10 + ItemRules.CUBES.rankLockSeconds), "free after it")
	check(not ItemRules.rankLocked("S#1", 10, "S#2", 10), "another rank is never locked")
	check(not ItemRules.rankLocked(nil, nil, "S#2", 10), "a first cube is never locked")
	check(not ItemRules.rankLocked("", 10, nil, 10) and not ItemRules.rankLocked("x", 10, "", 10), "pods without a rank never are")
	s.removeRacer(P1)
	h.clock.t += 5
	check((s.requestPickup(P1, "B2")), "removeRacer clears the rank memory")
end

do -- DKR level-up: roulette queue and max
	-- Pure rule.
	local empty = ItemRules.newState()
	local a, o, spin = ItemRules.cubeTake(empty, "red", nil)
	check(o == "new" and a.level == 1 and spin == SPIN, "first cube: a new item and a full spin")
	local b, o2, spin2 = ItemRules.cubeTake(a, "blue", 0.7)
	check(o2 == "upgrade" and b.color == "red" and b.level == 2 and spin2 == 0.7, "second cube mid-spin: queued level-up, the spin goes on for what is left")
	local c, o3, spin3 = ItemRules.cubeTake(b, "green", nil)
	check(o3 == "upgrade" and c.level == 3 and spin3 == nil, "after the reveal: a plain level-up, no spin")
	local d, o4, spin4 = ItemRules.cubeTake(c, "green", nil)
	check(o4 == "capped" and d.level == ItemRules.MAX_LEVEL and spin4 == nil, "at max: capped, the item stays")
	check(ItemRules.pickupNotice(o4, nil, "MISSILE") == "MISSILE MAXED", "MAXED feedback at max")
	local _, o5 = ItemRules.cubeTake(ItemRules.newState(), "red", nil, true)
	local e = { color = "red", level = 1 } :: any
	local _, o6 = ItemRules.cubeTake(e, "blue", nil, true)
	check(o5 == "new" and o6 == "capped", "level-one-only modes cap at once")
	-- HUD side.
	check(ItemRules.rouletteQueued(true, "red", "red", 0.7), "HUD: same colour mid-spin with a roulette left keeps spinning")
	check(not ItemRules.rouletteQueued(false, "red", "red", 0.7), "HUD: not spinning, nothing to queue")
	check(not ItemRules.rouletteQueued(true, "red", "red", nil), "HUD: no roulette in the state, a fresh state")
	check(not ItemRules.rouletteQueued(true, nil, "red", SPIN), "HUD: a fresh roll is a spin, not a queue")

	-- Service: the reveal time does not move, the use gate holds until it, the queued level is there at the reveal.
	local h = harness({
		C1 = { position = V3.new(0, 10, 0), podType = "Red", respawnSeconds = R, mystery = true, cubeRank = "A#1" },
		C2 = { position = V3.new(0, 10, 32), podType = "Blue", respawnSeconds = R, mystery = true, cubeRank = "A#2" },
		C3 = { position = V3.new(0, 10, 400), podType = "Green", respawnSeconds = R, mystery = true, cubeRank = "B#1" },
		C4 = { position = V3.new(0, 10, 800), podType = "Green", respawnSeconds = R, mystery = true, cubeRank = "C#1" },
	})
	local s = h.service
	h.positions[P1] = V3.new(0, 10, 0)
	check((s.requestPickup(P1, "C1")), "first cube")
	check(h.published[P1].roulette == SPIN, "a fresh roll publishes the full spin")
	h.clock.t += 0.25
	h.positions[P1] = V3.new(0, 10, 32)
	local ok, outcome = s.requestPickup(P1, "C2")
	check(ok and outcome == "upgrade", "second cube during the spin is taken")
	near(h.published[P1].roulette, SPIN - 0.25, 1e-9, "the HUD keeps spinning for what is left")
	check(h.published[P1].level == 2, "the queued level rides along to the reveal")
	local okUse, whyUse = s.requestUse(P1)
	check(not okUse and whyUse == "rolling", "still no fire before the reveal")
	h.clock.t += SPIN
	h.positions[P1] = V3.new(0, 10, 400)
	check((s.requestPickup(P1, "C3")), "third cube after the reveal")
	check(h.published[P1].level == 3 and h.published[P1].roulette == nil, "a plain level-up after the reveal: no spin")
	h.clock.t += 3
	h.positions[P1] = V3.new(0, 10, 800)
	local okMax, outMax = s.requestPickup(P1, "C4")
	check(okMax and outMax == "capped", "a cube at max is still consumed")
	check(h.told[P1].payload.outcome == "capped", "and the client is told (MAXED)")
	local okAgain, whyAgain = s.requestPickup(P2, "C4")
	check(not okAgain, "the capped cube went: gone for the next racer too (" .. tostring(whyAgain) .. ")")
end

------------------------------------------------------------------------------------------------------------------------
-- 3. Ghost cycle: honest, weighted by roll chance
------------------------------------------------------------------------------------------------------------------------

do
	local C = ItemRules.CUBES
	for band, weights in ItemRules.MYSTERY_WEIGHTS :: any do
		local s = ItemRules.ghostSchedule(weights)
		local sum = 0
		for _, w in weights do
			sum += w
		end
		local seen: { [string]: number } = {}
		local prevEnd = 0
		for i, c in s.colors do
			seen[c] = s.ends[i] - prevEnd
			prevEnd = s.ends[i]
		end
		for c, w in weights do
			if w <= 0 then
				check(seen[c] == nil, band .. ": a colour it cannot roll never shows (" .. c .. ")")
			else
				local want = math.max(C.ghostMinDwell, C.ghostPeriod * w / sum)
				near(seen[c] or 0, want, 1e-9, band .. ": " .. c .. " dwell follows its roll chance")
			end
		end
		near(s.total, prevEnd, 1e-9, band .. ": total is the last dwell end")
		check(s.total >= C.ghostPeriod and s.total <= C.ghostPeriod + 5 * C.ghostMinDwell, band .. ": cycle about ghostPeriod")
	end
	-- Lead (rank 1 of 8) never hints a magnet; the back band hints it the longest after the boost.
	local lead = ItemRules.ghostFor(1, 8, nil)
	check(table.find(lead.colors, "rainbow") == nil, "the leader's cubes never show a magnet")
	local back = ItemRules.ghostFor(8, 8, nil)
	check(table.find(back.colors, "rainbow") == nil and table.find(back.colors, "blue") ~= nil, "the back hints boost, never the retired magnet")
	check(ItemRules.ghostFor(8, 8, nil) == back, "schedules are cached (no allocation per frame)")
	-- Holding an item: a cube only upgrades it, so only that item shows.
	local held = ItemRules.ghostFor(8, 8, "red")
	check(#held.colors == 1 and held.colors[1] == "red", "holding red: the cubes ghost red only")
	-- Time share over many samples equals the dwell share.
	local counts: { [string]: number } = {}
	local N = 4000
	for i = 0, N - 1 do
		local c = ItemRules.ghostAt(back, i * back.total / N)
		counts[c] = (counts[c] or 0) + 1
	end
	local w = ItemRules.MYSTERY_WEIGHTS.back :: any
	near(counts.blue / N, math.max(C.ghostMinDwell, C.ghostPeriod * w.blue / 100) / back.total, 0.002, "blue shows for its share")
	near(counts.yellow / N, C.ghostMinDwell / back.total, 0.002, "a 5 % item still flashes for ghostMinDwell")
	-- Crossfade: none mid-dwell, rising to 1 at the end of a dwell, toward the next colour.
	local c1, n1, b1 = ItemRules.ghostAt(back, back.ends[1] / 2)
	check(c1 == back.colors[1] and n1 == back.colors[2] and b1 == 0, "mid-dwell: no blend")
	local _, _, b2 = ItemRules.ghostAt(back, back.ends[1] - C.ghostFade / 2)
	near(b2, 0.5, 1e-6, "half way through the crossfade")
	local cw, nw = ItemRules.ghostAt(back, back.total - 0.01)
	check(cw == back.colors[#back.colors] and nw == back.colors[1], "the cycle wraps")
	local _, _, bh = ItemRules.ghostAt(held, 3.9)
	check(bh == 0, "a single-colour cycle never blends")
end

------------------------------------------------------------------------------------------------------------------------
-- 4. Heights: road snap for Speed/Air pods, the plane pickup capsule, retrigger
------------------------------------------------------------------------------------------------------------------------

do
	local C = ItemRules.CUBES
	local M = ItemRules.MYSTERY
	-- The bug: a coin planned 1.8 over the road stayed there while cubes sat at +5.5. Now both snap on road maps.
	near(ItemRules.podHoverY(11.8, 10, true, C.coinHover), 10 + C.coinHover, 1e-9, "road coin snaps to coinHover")
	near(ItemRules.cubeHoverY(11.8, 10, true), 10 + M.hover, 1e-9, "road cube still snaps to MYSTERY.hover")
	near(ItemRules.podHoverY(10 + M.roadSnapMax + 5, 10, true, C.coinHover), 10 + M.roadSnapMax + 5, 1e-9, "over a jump gap: left alone")
	near(ItemRules.podHoverY(50, nil, true, C.coinHover), 50, 1e-9, "nothing under it: left alone")
	check(math.abs((10 + M.hover) - (10 + C.coinHover)) <= 1.5, "coin and cube centres within 1.5 studs: one row look")
	-- Plane capsule: horizontal reach unchanged, vertical reach planeLift taller, nothing below changes.
	local r = 14 -- PlaneConfig.PICKUP_TRIGGER_RADIUS
	check(ItemRules.liftedDistance(0, C.planeLift + r - 0.1, 0, C.planeLift) <= r, "straight over the pod, near the capsule top: taken")
	check(ItemRules.liftedDistance(0, C.planeLift + r + 0.5, 0, C.planeLift) > r, "higher than that: not taken (not crazy high)")
	near(ItemRules.liftedDistance(r, 10, 0, C.planeLift), r, 1e-9, "horizontal radius unchanged at any capsule height")
	near(ItemRules.liftedDistance(3, -4, 0, C.planeLift), 5, 1e-9, "below the pod: the plain sphere")
	near(ItemRules.liftedDistance(3, 4, 0, 0), 5, 1e-9, "lift 0 is the plain sphere")
	check(12 + C.planeLift + r >= 44 and 12 + C.planeLift + r <= 50, "reach tops out at the corridor ceiling (+44), not far above")
	check(C.planeLift >= 18 and C.planeLift <= 25, "planeLift in the owner's 'higher, not crazy high' band")
end

------------------------------------------------------------------------------------------------------------------------
-- 5. Static wiring
------------------------------------------------------------------------------------------------------------------------

do
	local gameplay = read("src/server/kit/Gameplay.luau")
	check(string.find(gameplay, "PerRacer", 1, true) == nil, "no pod is per racer any more")
	check(string.find(gameplay, "ItemRules.CUBES.respawn", 1, true) ~= nil, "race pods respawn on the shared 1.0 s")
	check(string.find(gameplay, 'SetAttribute("CubeRank", o.cubeRank)', 1, true) ~= nil, "cubes carry their rank")
	check(string.find(gameplay, 'pod.cubeSet .. "#" .. tostring(pod.cubeRank)', 1, true) ~= nil, "the rank comes from the plan")
	check(string.find(gameplay, "ItemArt.buildMysteryCube(name, pos, spawnPart, podType)", 1, true) ~= nil, "the glass family follows the plan colour")
	check(string.find(gameplay, "ItemRules.CUBES.coinHover", 1, true) ~= nil, "Speed/Air pods snap on road maps")
	check(string.find(gameplay, 'SetAttribute("PickupLift", ItemRules.CUBES.planeLift)', 1, true) ~= nil, "plane pods and pads get PickupLift")
	local adapt = read("tools/map/adapt.py")
	check(string.find(adapt, 'pod["cubeSet"], pod["cubeRank"]', 1, true) ~= nil, "MapAdapter data carries the set and rank")
	local td = read("build/hub0/TrackData.luau")
	check(string.find(td, 'cubeSet = "Promenade"', 1, true) ~= nil, "regenerated TrackData carries them")
	local race = read("src/server/RaceManager.luau")
	check(string.find(race, "PerRacer", 1, true) == nil, "RaceManager hides every taken pod for everyone")
	check(string.find(race, "ItemRules.liftedDistance", 1, true) ~= nil, "the server re-check uses the same capsule")
	local service = read("src/server/ItemService.luau")
	check(string.find(service, "racerReadyAt", 1, true) == nil, "the per-racer ledger is gone")
	check(string.find(service, "ItemRules.cubeTake(", 1, true) ~= nil, "the service queues mid-spin level-ups")
	local flight = read("src/client/FlightController.luau")
	check(select(2, string.gsub(flight, "ItemRules.liftedDistance", "")) == 2, "plane pods and pads use the capsule")
	check(string.find(flight, "PodLocal.take(trig, now)", 1, true) ~= nil, "plane claims through PodLocal (instant pop, rank lock)")
	local car = read("src/client/CarController.luau")
	check(string.find(car, "PodLocal.take(trig, now)", 1, true) ~= nil, "car claims through PodLocal (instant pop, rank lock)")
	check(string.find(car, "now - last > 3.5", 1, true) == nil, "car retrigger follows podRetrigger")
	local podLocal = read("src/client/PodLocal.luau")
	check(string.find(podLocal, "ItemRules.rankLocked(", 1, true) ~= nil, "the client applies the server's rank rule")
	local hud = read("src/client/HudExtras.luau")
	check(string.find(hud, "ItemRules.rouletteQueued(HudExtras.itemRolling()", 1, true) ~= nil, "the HUD keeps a spin going for a queued level-up")
	check(string.find(hud, "LevelPips", 1, true) ~= nil, "the HUD slot shows the level")
	local art = read("src/shared/ItemArt.luau")
	for _, fam in { "gold", "blue", "green", "red" } do
		check(string.find(art, "\t" .. fam .. " = { glass = ", 1, false) ~= nil, "the mockup's " .. fam .. " glass family")
	end
	check(string.find(art, "ItemArt.CUBE_FRAME_PARTS = 13", 1, true) ~= nil, "13 frame parts (14 a cube with the glass)")
	check(RULES.cubeParts == 14, "item_cubes.json counts 14 parts a cube")
	check(string.find(art, 'mesh = "pickup_speed"', 1, true) == nil, "the Speed pod is no longer the winged coin")
	check(string.find(art, 'block:SetAttribute("PodArt", "boost")', 1, true) ~= nil, "the Speed pod is the boost block")
	local client = read("src/client/ItemClient.luau")
	check(string.find(client, "PodLocal.isTaken(pod, now)", 1, true) ~= nil, "ItemClient pops the taker's cube before the server flip")
	check(string.find(client, 'core:GetAttribute("PodArt") == "boost"', 1, true) ~= nil, "ItemClient animates the boost block")
	check(string.find(client, "ItemRules.ghostFor(", 1, true) ~= nil, "ItemClient cycles the honest ghost schedule")
	check(string.find(client, "cube.parts[1].Color", 1, true) == nil, "the glass keeps its family colour")
	-- stepCube (per cube, per frame) allocates nothing: no instances, no new colours.
	local a = string.find(client, "local function stepCube", 1, true)
	local b = string.find(client, "local function step(dt", 1, true)
	check(a ~= nil and b ~= nil and b > a, "stepCube found")
	local body = string.sub(client, a :: number, b :: number)
	check(string.find(body, "Instance.new", 1, true) == nil, "stepCube creates no instances")
	check(string.find(body, "Color3.", 1, true) == nil and string.find(body, ":Lerp(", 1, true) == nil, "stepCube builds no colours")
	check(string.find(body, "cubeNearAmount(nearD, B.fadeStart, B.fadeEnd)", 1, true) ~= nil, "the ghost fades near the camera")
end

print(string.format("item_cubes_spec: %d checks passed", checks))
