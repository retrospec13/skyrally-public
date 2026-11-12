--!strict
-- Lune spec for items v4 (docs/design/ITEMS_V4.md; owner pick board 2026-10-20):
--   * the per-race ROTATION: drawPool is deterministic per seed, the core is always in it, every special shows within
--     ceil(#SPECIALS / size) races in a row, the attribute text round-trips, rolls / ghosts / the roulette only use the
--     pool, Storm Bolt rarity (final lap, one out at a time), Rocket Rush only for the back of the pack;
--   * ItemService rolls from the pool it was given (players and bots share it).
-- Run: tools/tests/run_lune_tests.sh tools/tests/items_v4_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local ItemRules = h.require("src/shared/ItemRules.luau")
	local ItemService = h.require("src/server/ItemService.luau")

	local R = ItemRules.ROTATION
	local N = #ItemRules.LIVE_SPECIALS -- v38: retired specials (ItemRules.RETIRED) never rotate

	local function has(list: { string }, id: string): boolean
		return table.find(list, id) ~= nil
	end

	------------------------------------------------------------------------------------------------------------------
	-- Rotation
	------------------------------------------------------------------------------------------------------------------

	h.test("rotation: nine specials, a four-item core, magnet nowhere", function()
		h.eq(N, 9, "nine specials")
		h.eq(#R.core, 4, "core size")
		for _, c in { "red", "blue", "yellow", "green" } do
			h.ok(has(R.core, c), c .. " in the core")
		end
		h.ok(not has(R.core, "rainbow") and not has(ItemRules.SPECIALS, "rainbow"), "the magnet stays out")
		for _, id in ItemRules.SPECIALS do
			h.ok(ItemRules.isColor(id), id .. " is an item id")
			h.eq(ItemRules.KIND_OF[id], id, id .. " is its own kind")
			h.ok(ItemRules.SPECIAL[id] ~= nil and #ItemRules.SPECIAL[id] == 3, id .. " has three levels")
			h.ok(ItemRules.COLOR_RGB[id] ~= nil and ItemRules.DISPLAY_NAME[id] ~= nil and ItemRules.SHORT_NAME[id] ~= nil, id .. " has HUD data")
			local icon = ItemRules.iconOf(id)
			h.ok(icon ~= nil and #icon.glyph > 0, id .. " has an in-engine icon glyph")
		end
	end)

	h.test("drawPool: deterministic per seed, core always, size specials, no repeats", function()
		for seed = 1, 40 do
			for m = 0, 12 do
				local a = ItemRules.drawPool(seed * 7919, m)
				local b = ItemRules.drawPool(seed * 7919, m)
				h.eq(ItemRules.poolText(a), ItemRules.poolText(b), "same seed and race, same pool")
				h.eq(#a, #R.core + R.size, "pool size")
				for i, c in R.core do
					h.eq(a[i], c, "core first, in order")
				end
				local seen = {}
				for i = #R.core + 1, #a do
					h.ok(ItemRules.isSpecial(a[i]), a[i] .. " is a special")
					h.ok(not seen[a[i]], "no special twice in one pool")
					seen[a[i]] = true
				end
			end
		end
	end)

	h.test("drawPool: every special shows within ceil(9/4) = 3 races in a row, for any seed and start", function()
		local window = math.ceil(N / R.size)
		h.eq(window, 3)
		for seed = 1, 60 do
			for start = 0, 20 do
				local seen = {}
				for m = start, start + window - 1 do
					for _, id in ItemRules.drawPool(seed * 104729 + 13, m) do
						seen[id] = true
					end
				end
				for _, id in ItemRules.LIVE_SPECIALS do
					h.ok(seen[id], string.format("seed %d races %d..%d include %s", seed, start, start + window - 1, id))
				end
			end
		end
	end)

	-- Studio V9 (i1b consoles): race -> hub -> race advances RaceResetSeq by 2 per race, so the old index
	-- (RaceResetSeq * 4) % 9 shifted each pool by -1 and three races showed 6 distinct specials. RaceManager now draws
	-- from its own race counter (+1 per non-hub race start).
	h.test("drawPool: realistic RaceResetSeq sequences (race, hub, race) missed specials; the race counter covers all nine", function()
		local function distinct(indices: { number }, seed: number): number
			local seen, n = {}, 0
			for _, m in indices do
				for _, id in ItemRules.drawPool(seed, m) do
					if ItemRules.isSpecial(id) and not seen[id] then
						seen[id] = true
						n += 1
					end
				end
			end
			return n
		end
		local worst = N
		for seed = 1, 40 do
			for first = 1, 8, 1 do
				-- RaceResetSeq of three races with a hub between each: first, first + 2, first + 4.
				worst = math.min(worst, distinct({ first, first + 2, first + 4 }, seed * 104729 + 13))
			end
		end
		h.ok(worst < N, "the RaceResetSeq index really lost specials in some window (the bug this fixes), worst " .. worst)
		for seed = 1, 60 do
			for start = 1, 30 do
				h.eq(distinct({ start, start + 1, start + 2 }, seed * 104729 + 13), N, string.format("seed %d races %d..%d cover all nine", seed, start, start + 2))
			end
		end
		local src = h.readFile("src/server/RaceManager.luau")
		h.contains(src, "st.itemRaceCount += 1")
		h.contains(src, "ItemRules.drawPool(gridSalt, st.itemRaceCount)")
		h.contains(src, "itemRaceCount = 0,") -- per scope (newRaceState), not a module-global shared by every group
		h.ok(not string.find(src, "\nlocal itemRaceCount", 1, true), "no server-wide counter")
	end)

	h.test("bots: a refused use backs off (rate limit waits the window, others 1/2/4 s) and logs once", function()
		h.ok(ItemRules.botRetryDelay("rate_limited", 1) > ItemService.USE_MIN_INTERVAL, "waits out the server's window")
		h.ok(ItemRules.botRetryDelay("rate_limited", 9) > ItemService.USE_MIN_INTERVAL)
		h.eq(ItemRules.botRetryDelay("no_item", 1), 1)
		h.eq(ItemRules.botRetryDelay("no_item", 2), 2)
		h.eq(ItemRules.botRetryDelay("no_item", 3), 4)
		h.eq(ItemRules.botRetryDelay("no_item", 30), 4, "capped")
		h.ok(ItemRules.botShouldLogRefusal(1) and not ItemRules.botShouldLogRefusal(2), "one log line per streak")
		local src = h.readFile("src/server/AIRacers.luau")
		h.contains(src, "ItemRules.botRetryDelay(reason, bot.itemFailures)")
	end)

	h.test("drawPool: seeds differ, so servers do not all run the same rotation", function()
		local texts = {}
		for seed = 1, 20 do
			texts[ItemRules.poolText(ItemRules.drawPool(seed * 31337, 0))] = true
		end
		local n = 0
		for _ in texts do
			n += 1
		end
		h.ok(n >= 5, "at least five different first pools over 20 seeds: " .. n)
		local custom = ItemRules.drawPool(5, 0, 2)
		h.eq(#custom, #R.core + 2, "size override")
		h.eq(#ItemRules.drawPool(5, 0, 0), #R.core, "size 0: the classic core only")
	end)

	h.test("pool text: round trip, junk dropped, core always back in", function()
		local pool = ItemRules.drawPool(99, 3)
		local back = ItemRules.parsePool(ItemRules.poolText(pool))
		h.eq(#back, #pool)
		for _, id in pool do
			h.ok(has(back, id), id .. " survives the attribute")
		end
		local junk = ItemRules.parsePool("storm_bolt,purple,,rainbow;ink_splat,bubble_guard")
		h.ok(has(junk, "storm_bolt") and has(junk, "ink_splat"), "known specials kept")
		h.ok(not has(junk, "purple") and not has(junk, "rainbow") and not has(junk, "bubble_guard"), "unknown and retired ids dropped")
		h.ok(has(junk, "red") and has(junk, "green"), "core put back")
		h.eq(ItemRules.poolText(ItemRules.parsePool(nil)), "red,blue,yellow,green", "missing attribute: classic")
		h.eq(ItemRules.poolLine(ItemRules.parsePool("rocket_rush,item_steal")), "Rocket, Steal")
		h.eq(ItemRules.poolLine(ItemRules.parsePool("")), "", "classic pool: no line")
		h.ok(#("This race: " .. ItemRules.poolLine(ItemRules.parsePool("golden_wings,orbit_missiles,item_steal,coin_pouch"))) <= 44, "the toast fits a phone lane")
	end)

	h.test("roll: only pool items, position weighting, nil pool is the classic table", function()
		local pool = ItemRules.parsePool("rocket_rush,storm_bolt,ink_splat,coin_pouch")
		local counts = {}
		for rank = 1, 8 do
			for i = 0, 199 do
				local c = ItemRules.rollMystery(rank, 8, (i + 0.5) / 200, pool)
				h.ok(has(pool, c), c .. " is in the pool")
				counts[rank] = counts[rank] or {}
				counts[rank][c] = (counts[rank][c] or 0) + 1
			end
		end
		h.ok((counts[1].rocket_rush or 0) == 0 and (counts[1].storm_bolt or 0) == 0, "the leader never rolls Rocket Rush or Storm Bolt")
		h.ok((counts[1].ink_splat or 0) == 0, "v38: the leader never rolls Ink Splat (nobody ahead)")
		for rank = 1, 5 do
			h.ok((counts[rank].rocket_rush or 0) == 0, "Rocket Rush is back-of-pack only (rank " .. rank .. ")")
		end
		h.ok((counts[8].rocket_rush or 0) > 0, "last place can roll Rocket Rush")
		h.ok((counts[1].coin_pouch or 0) > (counts[8].coin_pouch or 0), "v38: Coin Pouch leans to the front")
		-- nil pool: exactly the old behaviour
		for rank = 1, 8 do
			for i = 0, 49 do
				local c = ItemRules.rollMystery(rank, 8, (i + 0.5) / 50)
				h.ok(has(ItemRules.COLORS, c) and c ~= "rainbow", "classic roll stays classic")
			end
		end
		-- blocked
		for i = 0, 199 do
			h.ok(ItemRules.rollMystery(8, 8, (i + 0.5) / 200, pool, { storm_bolt = true }) ~= "storm_bolt", "a blocked id never rolls")
		end
	end)

	h.test("storm bolt rarity rule", function()
		h.ok(ItemRules.stormAllowed(false, false))
		h.ok(not ItemRules.stormAllowed(true, false), "never on the final lap")
		h.ok(not ItemRules.stormAllowed(false, true), "one out at a time")
	end)

	h.test("ghosts and roulette: only what the race can give", function()
		local text = "red,blue,yellow,green,golden_wings,gift_box,frost_shot,coin_burst"
		local pool = ItemRules.parsePool(text)
		local g = ItemRules.ghostFor(8, 8, nil, text)
		for _, c in g.colors do
			h.ok(has(pool, c), "ghost " .. c .. " is in the pool")
		end
		h.ok(has(g.colors, "golden_wings"), "a special ghosts in its band")
		h.ok(ItemRules.ghostFor(8, 8, nil, text) == g, "cached per band and pool")
		h.ok(ItemRules.ghostFor(8, 8, nil, nil) ~= g, "classic schedule separate")
		local held = ItemRules.ghostFor(8, 8, "frost_shot", text)
		h.eq(held.colors, { "frost_shot" }, "holding: the cube only upgrades it")
		for _, final in pool do
			local frames = ItemRules.rouletteFrames(1.2, final, 3, pool)
			h.eq(frames[#frames].color, final, "lands on the roll")
			h.ok(frames[#frames - 1].color ~= final, "the reveal is a change")
			for _, f in frames do
				h.ok(has(pool, f.color), "spin shows " .. f.color .. " from the pool")
			end
		end
	end)

	------------------------------------------------------------------------------------------------------------------
	-- ItemService: the pool
	------------------------------------------------------------------------------------------------------------------

	local function newService(randSeq: { number }?, finalLap: boolean?): (any, any)
		local w = { t = 100, logs = {}, published = {}, rank = 8, field = 8, i = 0 }
		local svc = ItemService.new({
			now = function(): number
				return w.t
			end,
			racerPosition = function(): any
				return Vector3.zero
			end,
			findPod = function(name: string): any
				return { position = Vector3.zero, podType = "Red", respawnSeconds = 0, mystery = string.sub(name, 1, 4) == "Cube" }
			end,
			publish = function(racerId: string, state: any)
				w.published[racerId] = state
			end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
			standing = function(): (number, number)
				return w.rank, w.field
			end,
			random = function(): number
				w.i += 1
				local seq = randSeq or { 0.5 }
				return seq[((w.i - 1) % #seq) + 1]
			end,
			finalLap = function(): boolean
				return finalLap == true
			end,
		} :: any, ItemService.loggingHooks(function() end))
		return svc, w
	end

	h.test("service: mystery rolls come from the race's pool; nil pool is classic", function()
		local seq = {}
		for i = 0, 39 do
			table.insert(seq, (i + 0.5) / 40)
		end
		local svc, w = newService(seq)
		local pool = ItemRules.parsePool("rocket_rush,golden_wings,gift_box,coin_burst")
		svc.setPool(pool)
		h.eq(ItemRules.poolText(svc.getPool()), ItemRules.poolText(pool))
		local specials = 0
		for i = 1, 40 do
			svc.resetAll()
			w.t += 2
			local ok = svc.requestPickup("bot:" .. i, "Cube" .. i)
			h.ok(ok, "pickup " .. i)
			local c = svc.getState("bot:" .. i).color
			h.ok(has(pool, c), c .. " from the pool")
			if ItemRules.isSpecial(c) then
				specials += 1
			end
		end
		h.ok(specials > 0, "the back of the pack rolls specials")
		svc.setPool(nil)
		svc.resetAll()
		w.t += 2
		svc.requestPickup("bot:99", "Cube99")
		h.ok(has(ItemRules.COLORS, svc.getState("bot:99").color), "classic without a pool")
	end)

	h.test("service: Storm Bolt never rolls on the final lap", function()
		local seq = {}
		for i = 0, 59 do
			table.insert(seq, (i + 0.5) / 60)
		end
		local svc, w = newService(seq, true)
		svc.setPool(ItemRules.parsePool("storm_bolt,frost_shot,boom_bomb,gift_box"))
		for i = 1, 60 do
			svc.resetAll()
			w.t += 2
			svc.requestPickup("bot:" .. i, "Cube" .. i)
			h.ok(svc.getState("bot:" .. i).color ~= "storm_bolt", "no Storm Bolt on the last lap")
		end
	end)

	h.test("service: one Storm Bolt held or out at a time", function()
		local seq = {}
		for i = 0, 59 do
			table.insert(seq, (i + 0.5) / 60)
		end
		local svc, w = newService(seq)
		svc.setPool(ItemRules.parsePool("storm_bolt,frost_shot,boom_bomb,gift_box"))
		h.ok(svc.qaGive("bot:1", "storm_bolt", 1))
		for i = 2, 61 do
			w.t += 2
			svc.removeRacer("bot:" .. i)
			svc.requestPickup("bot:" .. i, "Cube" .. i)
			h.ok(svc.getState("bot:" .. i).color ~= "storm_bolt", "a second Storm Bolt never rolls while one is held")
		end
	end)

	------------------------------------------------------------------------------------------------------------------
	-- Pure rules of the specials
	------------------------------------------------------------------------------------------------------------------

	h.test("charges: orbit and gift spend one per press and stay held; a cube adds the next level's charge", function()
		local s1 = ItemRules.held("orbit_missiles", 1)
		h.eq(s1.charges, 1)
		local s2 = ItemRules.pickupMystery(s1, "red")
		h.eq(s2.level, 2)
		h.eq(s2.charges, 2, "level two: two orbiters")
		local after, effect = ItemRules.use(s2)
		h.eq(after.color, "orbit_missiles", "still held after one shot")
		h.eq(after.charges, 1)
		h.eq(effect.kind, "orbit_missiles")
		local up = ItemRules.pickupMystery(after, "red")
		h.eq(up.level, 3)
		h.eq(up.charges, 2, "a spent orbiter is not refilled, the new level's one is added")
		local last = ItemRules.use(ItemRules.use(up))
		h.ok(not ItemRules.isHolding(last), "the last charge empties the slot")
		-- gifts
		local g = ItemRules.held("gift_box", 3)
		h.eq(g.charges, 5)
		local kinds = {}
		local st = g
		for _ = 1, 5 do
			local e
			st, e = ItemRules.use(st)
			h.ok(e.gift == true, "a gift")
			table.insert(kinds, e.color)
		end
		h.eq(kinds, { "red", "blue", "yellow", "green", "golden_wings" }, "gift order, the bonus rare last")
		h.ok(not ItemRules.isHolding(st))
		h.eq(ItemRules.held("gift_box", 1).charges, 3)
		h.eq(ItemRules.held("frost_shot", 2).charges, nil, "uncharged items have no charges")
		local _, frost = ItemRules.use(ItemRules.held("frost_shot", 2))
		h.eq(frost.special.freeze, 1.0, "frost level two freezes")
		local mini = ItemRules.giftEffect(2)
		h.ok(mini.boost ~= nil and mini.boost.seconds < ItemRules.PARAMS.boost[1].seconds, "a gift is a lesser item")
	end)

	h.test("absorbHit: one orbiter per hit; other items never absorb", function()
		local s = ItemRules.held("orbit_missiles", 2)
		local a, ok1 = ItemRules.absorbHit(s)
		h.ok(ok1)
		h.eq(a.charges, 1)
		local b, ok2 = ItemRules.absorbHit(a)
		h.ok(ok2)
		h.ok(not ItemRules.isHolding(b), "the last orbiter gone")
		local _, no = ItemRules.absorbHit(ItemRules.held("red", 3))
		h.ok(not no)
		local _, none = ItemRules.absorbHit(ItemRules.newState())
		h.ok(not none)
	end)

	h.test("slow cap, rocket cap, coin and orbit layouts", function()
		local S = ItemRules.SLOW
		local f, left = ItemRules.combineSlow(1, 0, 0.6, 2)
		h.eq(f, 0.6)
		h.eq(left, 2)
		f, left = ItemRules.combineSlow(0.6, 1.5, 0.3, 9)
		h.eq(f, S.floor, "never slower than the floor")
		h.eq(left, S.maxSeconds, "never longer than the cap")
		f, left = ItemRules.combineSlow(0.6, 2, 0.75, 1)
		h.eq(f, 0.6, "the stronger slow stays")
		h.eq(left, 2, "the later end stays")
		-- rocket
		local L3 = ItemRules.SPECIAL.rocket_rush[3]
		h.eq(ItemRules.rocketSeconds(L3.seconds, L3.speed, 2000), L3.seconds, "far behind: the full rocket")
		local near = ItemRules.rocketSeconds(L3.seconds, L3.speed, 0)
		h.ok(near < L3.seconds and near >= ItemRules.ROCKET.minSeconds, "level with the leader: cut short")
		h.ok(math.abs(near * (L3.speed - 110) - 3 * 110) < 1e-6, "ends 3 s of cruise past P1")
		-- coins
		local offs = ItemRules.coinOffsets(15)
		h.eq(#offs, 15)
		for _, o in offs do
			local r = math.sqrt(o[1] * o[1] + o[2] * o[2])
			h.ok(r > ItemRules.COIN.radius and r <= ItemRules.COIN.spread + 1e-6, "coins land outside the victim's own reach")
		end
		h.eq(#ItemRules.orbitOffsets(3, 0.5), 3)
		local o = ItemRules.orbitOffsets(1, 0)[1]
		h.ok(math.abs(math.sqrt(o[1] * o[1] + o[2] * o[2]) - ItemRules.ORBIT_FX.radius) < 1e-6)
	end)

	------------------------------------------------------------------------------------------------------------------
	-- The engine (kit/ItemEffects) with stubs: racers on a straight course along -Z, leader first in `order`
	------------------------------------------------------------------------------------------------------------------

	local ItemEffects = h.require("src/server/kit/ItemEffects.luau")
	local NORTH = Vector3.new(0, 0, -1)

	local function world(order: { string }): any
		local w: any = { t = 100, racers = {}, order = order, fx = {}, sent = {}, logs = {}, shielded = {}, rolls = {}, orbit = {}, guards = {}, payloads = {} }
		function w.add(id: string, z: number, botId: number?, vehicle: string?, speed: number?)
			w.racers[id] = {
				pos = Vector3.new(0, 0, z),
				forward = NORTH,
				station = -z,
				progress = -z,
				active = true,
				isPlayer = botId == nil,
				botId = botId,
				plane = "Model_" .. id,
				vehicle = vehicle or "plane",
				vel = NORTH * (speed or 0),
			}
		end
		local ctx = {
			now = function(): number
				return w.t
			end,
			order = function(): { string }
				return w.order
			end,
			racer = function(id: string): any
				return w.racers[id]
			end,
			course = function(st: number): (Vector3, Vector3)
				return Vector3.new(0, 0, -st), NORTH
			end,
			isShielded = function(id: string): boolean
				local g = w.shielded[id]
				return g == true or (type(g) == "number" and w.t < g)
			end,
			sendPlayer = function(id: string, kind: string, p: any)
				table.insert(w.sent, id .. ":" .. kind)
				table.insert(w.payloads, { id = id, kind = kind, p = p })
			end,
			broadcast = function(name: string, payload: any)
				table.insert(w.fx, { name = name, payload = payload })
			end,
			notifyUsed = function() end,
			applyToBot = function(botId: number, effect: any)
				table.insert(w.sent, "bot" .. botId .. ":" .. effect.kind)
			end,
			spawnVisual = function(kind: string): any
				return kind
			end,
			moveVisual = function() end,
			destroyVisual = function() end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
			rolledAt = function(id: string): number?
				return w.rolls[id]
			end,
			random = function(): number
				return 0.99
			end,
			guard = function(id: string, seconds: number)
				w.shielded[id] = w.t + seconds
				table.insert(w.guards, id .. ":" .. string.format("%.1f", seconds))
			end,
			absorb = function(id: string): boolean
				local n = w.orbit[id] or 0
				if n > 0 then
					w.orbit[id] = n - 1
					return true
				end
				return false
			end,
			-- v38 Item Steal
			holdsStealable = function(id: string): boolean
				return w.held[id] ~= nil
			end,
			steal = function(thief: string, victim: string): string?
				local x = w.held[victim]
				if not x then
					return nil
				end
				w.held[victim] = nil
				w.held[thief] = x
				return x
			end,
		}
		w.held = {}
		w.engine = ItemEffects.new(ctx :: any)
		function w.run(seconds: number)
			for _ = 1, math.floor(seconds * 30 + 0.5) do
				w.t += 1 / 30
				for _, r in w.racers do
					if r.vel.Magnitude > 0 then
						r.pos += r.vel / 30
						r.station = -r.pos.Z
						r.progress = -r.pos.Z
					end
				end
				w.engine.step(1 / 30)
			end
		end
		function w.has(entry: string): boolean
			return table.find(w.sent, entry) ~= nil
		end
		function w.fxNamed(name: string): { any }
			local out = {}
			for _, f in w.fx do
				if f.name == name then
					table.insert(out, f.payload)
				end
			end
			return out
		end
		function w.payload(id: string, kind: string): any
			for _, x in w.payloads do
				if x.id == id and x.kind == kind then
					return x.p
				end
			end
			return nil
		end
		function w.use(id: string, kind: string, level: number)
			local p = if kind == "horn" then ItemRules.PARAMS.horn[level] else ItemRules.SPECIAL[kind][level]
			w.engine.hooks.special(id, kind, p, level)
		end
		return w
	end

	h.test("Rocket Rush: invulnerable, boost with autopilot, cut short near P1; level two shoves", function()
		local w = world({ "lead", "me", "rival" })
		w.add("lead", -3000)
		w.add("me", 0)
		w.add("rival", -6)
		w.use("me", "rocket_rush", 2)
		local b = w.payload("me", "boost")
		h.ok(b ~= nil and b.speed == 215 and b.auto > 0 and b.item == "rocket_rush", "the boost carries its autopilot")
		h.eq(w.guards[1], "me:4.5", "invulnerable for the whole rocket (far behind P1)")
		w.run(0.1)
		h.ok(w.has("rival:hit"), "a rival in the way is shoved (spins)")
		-- near the leader it is cut short
		local w2 = world({ "lead", "me" })
		w2.add("lead", -10)
		w2.add("me", 0)
		w2.use("me", "rocket_rush", 3)
		local b2 = w2.payload("me", "boost")
		h.ok(b2.seconds < 5.5 and b2.seconds >= ItemRules.ROCKET.minSeconds, "never carries the racer far past P1: " .. b2.seconds)
		h.ok(b2.auto <= b2.seconds - 1 + 1e-6, "level three hands the wheel back for the last second")
	end)

	h.test("Golden Wings: invulnerable, factor boost, a ram spins once", function()
		local w = world({ "me", "rival" })
		w.add("me", 0)
		w.add("rival", -5)
		w.use("me", "golden_wings", 3)
		local b = w.payload("me", "boost")
		h.ok(b.factor == 1.30 and b.seconds == 8, "cruise factor boost")
		h.ok(w.shielded.me > w.t, "guarded")
		w.run(0.2)
		local hits = 0
		for _, e in w.sent do
			if e == "rival:hit" then
				hits += 1
			end
		end
		h.eq(hits, 1, "one spin per pass (hit grace)")
		h.ok(#w.fxNamed("explode") >= 1)
		-- a shielded rival alongside is met once a second, not every step
		local w2 = world({ "me", "rival" })
		w2.add("me", 0)
		w2.add("rival", -5)
		w2.shielded.rival = true
		w2.use("me", "golden_wings", 1)
		w2.run(0.5)
		h.eq(#w2.fxNamed("blocked"), 1, "one block, no spam")
	end)

	h.test("Orbit Missiles: an orbiter soaks a hit before any stun; a press fires one homing shot", function()
		local w = world({ "target", "me" })
		w.add("target", -80)
		w.add("me", 0)
		w.orbit.target = 1
		w.engine.hooks.spawnMissile("me", ItemRules.PARAMS.missile[1], 1)
		w.run(1)
		h.ok(not w.has("target:hit"), "the orbiter took it")
		h.eq(w.orbit.target, 0, "one orbiter spent")
		local blocked = w.fxNamed("blocked")
		h.ok(#blocked >= 1 and blocked[1].orbit == true, "everyone sees the orbiter pop")
		-- now the shooter fires an orbiter of its own
		w.use("me", "orbit_missiles", 2)
		w.run(1)
		h.ok(w.has("target:hit"), "an orbit shot homes in and hits")
	end)

	h.test("Storm Bolt: telegraph, strike on the leader, shield blocks, roll dodges, chain and splash", function()
		local w = world({ "lead", "near", "me" })
		w.add("lead", -500)
		w.add("near", -488)
		w.add("me", 0)
		w.use("me", "storm_bolt", 2)
		h.eq(#w.fxNamed("stormCloud"), 1, "the cloud shows over the leader at once")
		w.run(1.9)
		h.ok(not w.has("lead:stormWarn"), "no siren before travel - warn")
		w.run(0.2)
		h.ok(w.has("lead:stormWarn"), "the siren sounds warn seconds before")
		h.ok(not w.has("lead:hit"))
		w.run(2)
		h.ok(w.has("lead:hit"), "the bolt strikes the leader")
		h.ok(w.has("near:slow"), "level two splash slows the racer beside the leader")
		h.eq(#w.fxNamed("stormStrike"), 1)
		-- shield blocks, and level three chains to the next racer
		local w2 = world({ "lead", "second", "me" })
		w2.add("lead", -500)
		w2.add("second", -300)
		w2.add("me", 0)
		w2.shielded.lead = true
		w2.use("me", "storm_bolt", 3)
		w2.run(4.1)
		h.ok(not w2.has("lead:hit"), "a shield beats it")
		h.eq(#w2.fxNamed("stormCloud"), 2, "level three: a new cloud over the next racer")
		w2.run(2.7)
		h.ok(w2.has("second:hit"), "the chained bolt strikes the next racer")
		-- a plane's roll inside the dodge window
		local w3 = world({ "lead", "me" })
		w3.add("lead", -500)
		w3.add("me", 0)
		w3.use("me", "storm_bolt", 1)
		w3.run(3.8)
		w3.rolls.lead = w3.t
		w3.run(0.4)
		h.ok(not w3.has("lead:hit"), "a timed barrel roll dodges the bolt")
		h.eq(#w3.fxNamed("dodge"), 1)
		-- an early roll does not
		local w4 = world({ "lead", "me" })
		w4.add("lead", -500)
		w4.add("me", 0)
		w4.use("me", "storm_bolt", 1)
		w4.run(1)
		w4.rolls.lead = w4.t
		w4.run(3.2)
		h.ok(w4.has("lead:hit"), "a roll before the siren does not count")
		-- the leader holding one has nobody to hit
		local w5 = world({ "me", "other" })
		w5.add("me", -100)
		w5.add("other", 0)
		w5.use("me", "storm_bolt", 1)
		h.eq(#w5.fxNamed("stormCloud"), 1, "the leader's bolt hunts the next racer instead")
	end)

	-- v38 (owner 2026-11-10: no passive shields, not every item a missile): the new verbs.
	h.test("v38 Horn: spins racers in its ring, clears traps in reach, breaks a Storm Bolt inside its warning", function()
		local w = world({ "me", "close", "far" })
		w.add("me", 0)
		w.add("close", 10)
		w.add("far", 200)
		w.engine.hooks.spawnTrap("close", ItemRules.PARAMS.trap[2], 2) -- dropped 14 behind "close": right at "me"
		local _, trapsBefore = w.engine.counts()
		h.ok(trapsBefore == 1, "a trap is down")
		w.use("me", "horn", 1)
		h.ok(w.has("close:hit"), "a racer inside the ring spins")
		h.ok(not w.has("far:hit"), "a racer outside it does not")
		local _, trapsAfter = w.engine.counts()
		h.eq(trapsAfter, 0, "the trap in reach is destroyed")
		h.eq(#w.fxNamed("horn"), 1, "everyone sees the shockwave")
		-- Storm Bolt: a horn after the siren breaks it; before the siren it does not count
		local w2 = world({ "me", "x" })
		w2.add("me", -500)
		w2.add("x", 0)
		w2.use("x", "storm_bolt", 1)
		w2.run(2.2)
		h.ok(w2.has("me:stormWarn"), "the siren sounded")
		w2.use("me", "horn", 1)
		w2.run(2.5)
		h.ok(not w2.has("me:hit"), "a horn inside the warning breaks the bolt")
		local w3 = world({ "me", "x" })
		w3.add("me", -500)
		w3.add("x", 0)
		w3.use("x", "storm_bolt", 1)
		w3.run(0.5)
		w3.use("me", "horn", 1)
		w3.run(4)
		h.ok(w3.has("me:hit"), "a horn long before the siren is wasted")
	end)

	h.test("v38 Storm Bolt: an item boost inside the warning outruns it", function()
		local w = world({ "lead", "me" })
		w.add("lead", -500)
		w.add("me", 0)
		w.use("me", "storm_bolt", 1)
		w.run(2.3)
		w.engine.hooks.applyBoost("lead", ItemRules.PARAMS.boost[1], 1)
		w.run(2)
		h.ok(not w.has("lead:hit"), "the boost outran the strike")
		local d = w.fxNamed("dodge")
		h.ok(#d == 1 and d[1].how == "boost", "a dodge by boost")
	end)

	h.test("v38 Ink Splat: everyone ahead is inked (players on screen, bots slowed); nobody behind", function()
		local w = world({ "a", "b", "me", "c" })
		w.add("a", -300)
		w.add("b", -200, 2)
		w.add("me", 0)
		w.add("c", 100)
		w.use("me", "ink_splat", 2)
		h.ok(w.has("a:ink"), "the player ahead gets ink")
		h.eq(w.payload("a", "ink").seconds, ItemRules.SPECIAL.ink_splat[2].seconds)
		h.ok(w.has("bot2:slow"), "the bot ahead drives slow and loose")
		h.ok(not w.has("c:ink") and not w.has("me:ink"), "nobody behind, never the user")
	end)

	h.test("v38 Item Steal: takes the nearest held item ahead (level 2: the furthest ahead); nothing to take = coins", function()
		local w = world({ "a", "b", "me" })
		w.add("a", -300)
		w.add("b", -100)
		w.add("me", 0)
		w.held.a = "storm_bolt:1"
		w.held.b = "red:2"
		w.use("me", "item_steal", 1)
		h.eq(w.held.me, "red:2", "level one robs the nearest holder ahead")
		h.eq(w.held.b, nil)
		w.held.me = nil
		w.use("me", "item_steal", 2)
		h.eq(w.held.me, "storm_bolt:1", "level two robs the furthest ahead")
		local w2 = world({ "a", "me" })
		w2.add("a", -100)
		w2.add("me", 0)
		w2.use("me", "item_steal", 1)
		h.ok(w2.has("me:coins"), "nobody holding anything: coins instead")
	end)

	h.test("v38 Coin Pouch: coins into the user's count and a short kick", function()
		local w = world({ "me" })
		w.add("me", 0)
		w.use("me", "coin_pouch", 3)
		h.eq(w.payload("me", "coins").count, 7)
		h.ok(w.has("me:boost"), "a short kick")
	end)

	h.test("v38 roster: two projectiles at most among the live items; no live item grants a shield", function()
		local projectiles = 0
		for _, id in ItemRules.LIVE_COLORS do
			local e = ItemRules.effectFor(id, 1)
			h.ok(e.shield == nil, id .. " grants no shield")
			if e.missile then
				projectiles += 1
			end
		end
		for _, id in ItemRules.LIVE_SPECIALS do
			h.ok(id ~= "bubble_guard" and id ~= "frost_shot" and id ~= "coin_burst", id .. " is live")
			if id == "orbit_missiles" then
				projectiles += 1
			end
		end
		h.eq(projectiles, 2, "missile and orbit missiles are the only shots")
		h.eq(ItemRules.chargesFor("blue", 3), 3, "a level-three boost is three taps")
		h.eq(ItemRules.KIND_OF.yellow, "horn")
	end)

	h.test("Boom Bomb: lands ahead, blows after its fuse, stuns inside the radius only; level three leaves a patch", function()
		local w = world({ "far", "inside", "me" })
		w.add("far", -100)
		w.add("inside", -66)
		w.add("me", 0)
		w.use("me", "boom_bomb", 3)
		w.run(1.5)
		h.ok(not w.has("inside:hit"), "the fuse burns first")
		w.run(0.2)
		h.ok(w.has("inside:hit"), "the blast catches a racer inside the radius")
		h.ok(not w.has("far:hit"), "and nobody outside it")
		h.eq(#w.fxNamed("bombBlast"), 1)
		w.racers.far.pos = Vector3.new(0, 0, -62)
		w.run(0.6)
		h.ok(w.has("far:slow"), "the level-three patch slows a racer driving through")
	end)

	h.test("Frost Shot: a straight shot slows; level two freezes first; a shield stops it", function()
		local w = world({ "target", "me" })
		w.add("target", -60)
		w.add("me", 0)
		w.use("me", "frost_shot", 1)
		w.run(0.6)
		h.ok(w.has("target:slow"), "slowed")
		h.ok(w.has("target:hit"), "v37: level one freezes too")
		local p = w.payload("target", "slow")
		h.ok(p.factor == 0.6 and p.seconds == ItemRules.SLOW.maxSeconds, "40 percent, freeze + 2.5 s capped at the slow cap: " .. tostring(p.seconds))
		local w2 = world({ "target", "me" })
		w2.add("target", -60)
		w2.add("me", 0)
		w2.use("me", "frost_shot", 2)
		w2.run(0.6)
		h.ok(w2.has("target:hit") and w2.has("target:slow"), "level two: freeze, then slow")
		h.ok(w2.payload("target", "slow").seconds <= ItemRules.SLOW.maxSeconds, "capped")
		local w3 = world({ "target", "me" })
		w3.add("target", -60)
		w3.add("me", 0)
		w3.shielded.target = true
		w3.use("me", "frost_shot", 3)
		w3.run(0.6)
		h.ok(not w3.has("target:slow"), "a shield stops it")
	end)

	h.test("Coin Burst: slows the target and spills coins the racers behind scoop", function()
		local w = world({ "target", "me", "chaser" })
		w.add("target", -60)
		w.add("me", 0)
		w.add("chaser", 30, nil, nil, 0)
		w.use("me", "coin_burst", 1)
		w.run(0.6)
		h.ok(w.has("target:slow"), "the hit slows")
		h.ok(not w.has("target:boost"), "the victim does not scoop its own spill at once")
		w.racers.chaser.pos = Vector3.new(0, 0, -60 + ItemRules.COIN.spread * 0.55)
		w.run(0.5)
		h.ok(w.has("chaser:boost"), "a racer driving through scoops a coin")
		h.ok(#w.fxNamed("coinTake") >= 1)
	end)

	h.test("Bubble Guard: inside the window a missile goes back at its shooter; after it, a plain block", function()
		local w = world({ "target", "me" })
		w.add("target", -60)
		w.add("me", 0)
		w.use("target", "bubble_guard", 1)
		h.ok(w.shielded.target > w.t, "a bubble is a shield")
		w.engine.hooks.spawnMissile("me", ItemRules.PARAMS.missile[1], 1)
		w.run(1.2)
		h.eq(#w.fxNamed("reflect"), 1, "sent back")
		h.ok(w.has("me:hit"), "the shooter is hit by their own missile")
		h.ok(not w.has("target:hit"))
		-- after the window
		local w2 = world({ "target", "me" })
		w2.add("target", -60)
		w2.add("me", 0)
		w2.use("target", "bubble_guard", 1)
		w2.run(1.0)
		w2.engine.hooks.spawnMissile("me", ItemRules.PARAMS.missile[1], 1)
		w2.run(1.0)
		h.eq(#w2.fxNamed("reflect"), 0, "outside the window: no reflect")
		h.ok(not w2.has("target:hit") and not w2.has("me:hit"), "just a block")
	end)

	h.test("review fixes: no orbiter spent in hit grace; a reflected bolt does not also chain", function()
		local w = world({ "target", "me" })
		w.add("target", -80)
		w.add("me", 0)
		w.engine.hooks.spawnMissile("me", ItemRules.PARAMS.missile[1], 1)
		w.run(0.6)
		h.ok(w.has("target:hit"), "the first shot hits")
		w.orbit.target = 1
		w.engine.hooks.spawnMissile("me", ItemRules.PARAMS.missile[1], 1)
		w.run(0.6)
		h.eq(w.orbit.target, 1, "a racer still spinning keeps its orbiter (the shot passes through)")
		-- a level-three Bubble Guard sends a level-three bolt back; it must not chain on to the next racer too
		local w2 = world({ "lead", "second", "me" })
		w2.add("lead", -500)
		w2.add("second", -300)
		w2.add("me", 0)
		w2.use("me", "storm_bolt", 3)
		w2.run(3.0)
		w2.use("lead", "bubble_guard", 3)
		w2.run(1.1)
		h.eq(#w2.fxNamed("reflect"), 1, "the bubble sends the bolt back")
		h.eq(#w2.fxNamed("stormCloud"), 2, "one cloud back over the caller, no chained cloud")
		w2.run(3.0)
		h.ok(w2.has("me:hit"), "the caller eats its own bolt")
		h.ok(not w2.has("second:hit"), "the next racer is left alone")
	end)

	h.test("clear() removes every special in flight", function()
		local w = world({ "lead", "me" })
		w.add("lead", -500)
		w.add("me", 0)
		w.use("me", "storm_bolt", 1)
		w.use("me", "boom_bomb", 1)
		w.engine.clear()
		w.run(5)
		h.ok(not w.has("lead:hit") and #w.fxNamed("bombBlast") == 0, "nothing lands after a race reset")
	end)

	------------------------------------------------------------------------------------------------------------------
	-- ItemService: specials, charges, absorb, guard
	------------------------------------------------------------------------------------------------------------------

	h.test("service: a special goes to the special hook; charged items stay held; absorb and guard", function()
		local calls = {}
		local hooks = ItemService.loggingHooks(function() end) :: any
		hooks.special = function(racerId: string, kind: string, params: any, level: number)
			table.insert(calls, racerId .. ":" .. kind .. ":" .. level .. ":" .. tostring(params ~= nil))
		end
		local w = { t = 100 }
		local svc = ItemService.new({
			now = function(): number
				return w.t
			end,
			racerPosition = function(): any
				return Vector3.zero
			end,
			findPod = function(): any
				return nil
			end,
			publish = function() end,
			log = function() end,
		} :: any, hooks)
		h.ok(svc.qaGive("player:1", "orbit_missiles", 3))
		h.eq(svc.getState("player:1").charges, 3)
		h.ok((svc.requestUse("player:1")))
		h.eq(calls[1], "player:1:orbit_missiles:3:true")
		h.eq(svc.getState("player:1").charges, 2, "still held")
		h.ok(svc.absorbHit("player:1"), "an orbiter soaks a hit")
		h.eq(svc.getState("player:1").charges, 1)
		w.t += 1
		h.ok((svc.requestUse("player:1")))
		h.ok(not ItemRules.isHolding(svc.getState("player:1")), "spent")
		h.ok(not svc.absorbHit("player:1"), "nothing left to absorb")
		svc.guard("player:2", 2)
		h.ok(svc.isShielded("player:2"))
		w.t += 2.1
		h.ok(not svc.isShielded("player:2"), "the guard ends")
		h.ok(svc.qaGive("player:3", "gift_box", 1))
		w.t += 1
		local _, _, e = svc.requestUse("player:3")
		h.ok(e and e.gift and e.color == "red", "the first gift is a missile through the classic hook")
	end)

	-- Bots' rules for the specials: tools/tests/field_spec.luau (AIRacers.decideItemUse needs its fakes).
end
