--!strict
-- Lune spec for the launch economy: src/shared/MonetizationConfig.luau, src/shared/EconomyRules.luau and
-- src/server/Economy.luau over a REAL SaveService (docs/MONETIZATION_PROPOSAL.md; TEST_LIST_LAUNCH L50-L59 mock paths).
-- Run: tools/tests/run_lune_tests.sh tools/tests/economy_spec.luau
-- Every case runs on the harness's deterministic scheduler. Memory stores sharing one backing table stand in for one
-- DataStore seen by several servers; MarketplaceService, PolicyService and AnalyticsService are recorded mocks.
-- FIXTURE IDS: tests that need a bound product use fixture() below, which numbers a COPY of the catalog 990001.. so the
-- receipt path can run. They are spec-only stand-ins, never real ids; the shipping config keeps every id nil (test 1).

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
	readFile: (string) -> string,
	logs: { string },
	newScheduler: (number?) -> any,
	fakePlayer: (number, string?) -> any,
	stubs: any,
}

local GRANTED = "ProductPurchaseDecision.PurchaseGranted"
local NOT_YET = "ProductPurchaseDecision.NotProcessedYet"
local DAY = 86400
local S1_START = 1794009600 -- Saturday 2026-11-07 00:00 UTC
local SUNDAY_10 = S1_START + DAY + 10 * 3600 -- inside season 1, no Festival window

return function(h: Harness)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local SaveService = h.require("src/server/SaveService.luau")
	local Economy = h.require("src/server/Economy.luau")
	local EconomyRules = h.require("src/shared/EconomyRules.luau")
	local MonetizationConfig = h.require("src/shared/MonetizationConfig.luau")

	local function deepCopy(v: any): any
		if type(v) ~= "table" then
			return v
		end
		local out = {}
		for k, x in pairs(v) do
			out[k] = deepCopy(x)
		end
		return out
	end

	-- A copy of the shipping catalog with the store on and fixture ids bound (see header).
	local function fixture(enabled: boolean?, withIds: boolean?): any
		local c = deepCopy(MonetizationConfig)
		c.Enabled = if enabled == nil then true else enabled
		if withIds ~= false then
			for i, p in ipairs(c.PRODUCTS) do
				p.id = 990000 + i
			end
		end
		return c
	end

	local function idOf(cfg: any, key: string): number
		for _, p in ipairs(cfg.PRODUCTS) do
			if p.key == key then
				return p.id
			end
		end
		error("no product " .. key)
	end

	-- A flaky wrapper so a spec can switch a DataStore outage on and off.
	local function flaky(inner: any): any
		local f: any = { kind = "flaky", failing = false, data = inner.data }
		function f.update(key: string, transform: (any) -> any, userIds: { number }?): (boolean, string?)
			if f.failing then
				return false, "502: simulated DataStore outage"
			end
			return inner.update(key, transform, userIds)
		end
		return f
	end

	-- One server: its own SaveService and Economy over shared backings.
	local function newServer(opts: { [string]: any }?): any
		local o: any = opts or {}
		local w: any = {}
		w.sched = o.sched or h.newScheduler()
		w.name = o.name or "A"
		w.utc = o.utcRef or { t = SUNDAY_10 }
		w.backing = o.backing or {}
		w.purchases = o.purchases or {}
		w.gifts = o.gifts or {}
		w.logs = {} :: { string }
		w.fired = {} :: { any }
		w.prompts = {} :: { any }
		w.analytics = {} :: { any }
		w.players = {} :: { [number]: any }
		w.busy = {} :: { [any]: string }
		w.owned = o.owned or {} :: { [string]: boolean } -- "userId:passId"
		w.marketDown = 0 -- pass checks that fail before the API answers
		w.priceFailures = 0 -- GetProductInfo calls that fail before the API answers
		w.cfg = o.config or fixture()
		local function log(line: string)
			table.insert(w.logs, line)
		end
		w.profileStore = o.profileStore or flaky(SaveService.newMemoryStore(w.backing))
		w.purchaseStore = o.purchaseStore or flaky(SaveService.newMemoryStore(w.purchases))
		w.giftStore = o.giftStore or flaky(SaveService.newMemoryStore(w.gifts))
		local tokens = 0
		w.save = SaveService.new({
			store = w.profileStore,
			sessionId = "server-" .. w.name,
			newToken = function(): string
				tokens += 1
				return w.name .. "-tok" .. tokens
			end,
			now = w.sched.clock,
			clock = w.sched.clock,
			sleep = w.sched.sleep,
			spawn = w.sched.spawn,
			log = log,
			random = function(): number
				return 0.5
			end,
			config = { writeCooldown = 0, saveAttempts = 2, loadAttempts = 2 },
		})
		w.econ = Economy.new({
			save = w.save,
			purchaseStore = w.purchaseStore,
			giftStore = w.giftStore,
			market = {
				ownsPass = function(userId: number, passId: number): boolean
					if w.marketDown > 0 then
						w.marketDown -= 1
						error("HTTP 503 (simulated)")
					end
					return w.owned[userId .. ":" .. passId] == true
				end,
				promptPass = function(player: any, id: number)
					table.insert(w.prompts, { user = player.UserId, id = id, kind = "Pass" })
				end,
				promptProduct = function(player: any, id: number)
					table.insert(w.prompts, { user = player.UserId, id = id, kind = "DevProduct" })
				end,
				priceOf = function(_id: number, _kind: string): number?
					if w.priceFailures > 0 then
						w.priceFailures -= 1
						error("GetProductInfo throttled (simulated)")
					end
					return 77
				end,
			},
			policy = function(player: any): any
				if w.policyDown then
					error("policy service down")
				end
				return { ArePaidRandomItemsRestricted = player.restricted == true, IsPaidItemTradingAllowed = false }
			end,
			analytics = {
				economy = function(player: any, flow: string, amount: number, balance: number, tx: string, sku: string)
					table.insert(w.analytics, { user = player.UserId, flow = flow, amount = amount, balance = balance, tx = tx, sku = sku })
				end,
				custom = function(player: any, name: string, value: number, sku: string?)
					table.insert(w.analytics, { user = player.UserId, custom = name, value = value, sku = sku })
				end,
			},
			config = w.cfg,
			now = function(): number
				return w.utc.t
			end,
			clock = w.sched.clock,
			sleep = w.sched.sleep,
			spawn = w.sched.spawn,
			log = log,
			playerByUserId = function(userId: number): any
				return w.players[userId]
			end,
			isBusy = function(player: any): string?
				return w.busy[player]
			end,
			isStudio = function(): boolean
				return o.studio ~= false
			end,
			fire = function(player: any, kind: string, payload: any)
				table.insert(w.fired, { user = player.UserId, kind = kind, payload = payload })
			end,
		})
		w.save.onLoaded(w.econ.playerLoaded)

		function w.join(userId: number, extra: { [string]: any }?): any
			local p = h.fakePlayer(userId)
			for k, v in pairs(extra or {}) do
				p[k] = v
			end
			w.players[userId] = p
			w.econ.playerAdded(p)
			w.sched.run(function()
				w.save.load(p)
			end)
			w.sched.advance(0)
			return p
		end
		function w.leave(p: any)
			w.econ.playerRemoving(p)
			p:leave()
			w.players[p.UserId] = nil
			w.sched.run(function()
				return w.save.release(p)
			end)
		end
		-- Runs a yielding call (receipts, flushes) as a scheduler task.
		function w.run(fn: () -> any): any
			return w.sched.run(fn)
		end
		function w.receipt(purchaseId: string, player: any, key: string): any
			return w.sched.run(function()
				return w.econ.processReceipt({ PurchaseId = purchaseId, PlayerId = player.UserId, ProductId = idOf(w.cfg, key), CurrencySpent = 1 })
			end)
		end
		function w.gears(p: any): number
			return w.save.get(p).gears
		end
		function w.give(p: any, gears: number)
			assert(w.save.edit(p, "specGrant", function(d: any)
				d.gears += gears
			end))
		end
		function w.toasts(userId: number): { any }
			local list = {}
			for _, f in ipairs(w.fired) do
				if f.user == userId and f.kind == "Toast" then
					table.insert(list, f.payload)
				end
			end
			return list
		end
		function w.finish(p: any, mode: string, rank: number, extra: { [string]: any }?): any
			local info: any = { trackId = "DINO-4", mode = mode, rank = rank, laps = 3, rings = 8, coins = 0 }
			for k, v in pairs(extra or {}) do
				info[k] = v
			end
			return w.econ.raceFinished(p, info)
		end
		return w
	end

	-- Two servers on one set of DataStores and one clock.
	local function twoServers(opts: { [string]: any }?): (any, any)
		local o: any = opts or {}
		local shared = {
			sched = h.newScheduler(),
			utcRef = { t = o.utc or SUNDAY_10 },
			backing = {},
			purchases = {},
			gifts = {},
			owned = {},
			config = o.config or fixture(),
		}
		local a = newServer({ name = "A", sched = shared.sched, utcRef = shared.utcRef, backing = shared.backing, purchases = shared.purchases, gifts = shared.gifts, owned = shared.owned, config = shared.config })
		local b = newServer({ name = "B", sched = shared.sched, utcRef = shared.utcRef, backing = shared.backing, purchases = shared.purchases, gifts = shared.gifts, owned = shared.owned, config = shared.config })
		return a, b
	end

	---------------------------------------------------------------------------------------------- config (L50, L57)

	h.test("config: Enabled=true (private testing), every product id nil, catalog valid, nothing sells tokens/fragments/power (L50, L57)", function()
		h.eq(MonetizationConfig.Enabled, true, "store on for private testing by owner order 2026-10-20 (public release is a separate yes)")
		for _, p in ipairs(MonetizationConfig.PRODUCTS) do
			h.eq(p.id, nil, p.key .. " id must stay nil (never invented)")
			h.ok(p.defaultPriceLabel ~= nil and p.defaultPriceLabel ~= "", p.key .. " has a DEFAULT label")
		end
		h.eq(EconomyRules.default.validate(), {}, "catalog rules")
		local passes, dev, twins = 0, 0, 0
		for _, p in ipairs(MonetizationConfig.PRODUCTS) do
			if p.kind == "Pass" then
				passes += 1
			elseif p.giftTwinOf then
				twins += 1
			else
				dev += 1
			end
		end
		h.eq({ passes, dev, twins }, { 2, 14, 5 }, "launch catalog: 2 passes, 14 products, 5 gift twins")
		local shopItems = 0
		for _, c in ipairs(MonetizationConfig.COSMETICS) do
			if c.gearsPrice then
				shopItems += 1
			end
		end
		h.ok(shopItems >= 12 and shopItems <= 18, "12-18 Gears cosmetics, got " .. shopItems)
		-- A forged catalog row is caught by validate().
		local bad = fixture(false, false)
		table.insert(bad.PRODUCTS, { key = "speedBoost", kind = "DevProduct", id = nil, label = "x", grants = { skyTokens = 1 }, defaultPriceLabel = "9" })
		table.insert(bad.PRODUCTS, { key = "amulet", kind = "DevProduct", id = nil, label = "x", grants = { cosmetics = { "Livery_BattleAmulet" } }, defaultPriceLabel = "9" })
		local errors = EconomyRules.new(bad).validate()
		h.contains(errors, "speedBoost grants unknown field skyTokens")
		h.contains(errors, "speedBoost grants forbidden skyTokens")
		h.contains(errors, "amulet sells the Battle Amulet livery")
	end)

	h.test("config: earn arithmetic puts a common livery at ~5 races and the top Gears item at ~40 (L57)", function()
		local rules = EconomyRules.default
		local typical = rules.raceGears({ mode = "race", rank = 4, laps = 3, rings = 8 })
		h.eq(typical.base, 59, "4th of 8 + 3 laps + 8 rings")
		local common, top = math.huge, 0
		for _, c in ipairs(MonetizationConfig.COSMETICS) do
			if c.gearsPrice then
				if c.rarity == "common" and c.kind == "livery" then
					common = math.min(common, c.gearsPrice)
				end
				top = math.max(top, c.gearsPrice)
			end
		end
		local commonRaces = common / typical.base
		local topRaces = top / typical.base
		h.ok(commonRaces >= 4.5 and commonRaces <= 5.5, string.format("common livery = %.1f races", commonRaces))
		h.ok(topRaces >= 36 and topRaces <= 44, string.format("top item = %.1f races", topRaces))
		print(string.format("[SkyRally][ECON] L57 typical race=%d Gears; common=%d (%.1f races); top=%d (%.1f races)", typical.base, common, commonRaces, top, topRaces))
		-- Payout table by mode
		h.eq(rules.raceGears({ mode = "race", rank = 1, laps = 3, rings = 0 }).base, 75)
		h.eq(rules.raceGears({ mode = "race", rank = 12, laps = 3, rings = 0 }).base, 35, "past 8th pays last place")
		h.eq(rules.raceGears({ mode = "race", rank = 1, laps = 3, rings = 999 }).parts.rings, 12, "rings capped")
		h.eq(rules.raceGears({ mode = "coin", rank = 1, laps = 3, rings = 0, coins = 8 }).parts.coins, 24)
		h.eq(rules.raceGears({ mode = "timetrial", rank = 1, laps = 3 }).base, 45)
		h.eq(rules.raceGears({ mode = "boss", rank = 1, laps = 3, trackId = "SNOW-1" }).base, 165)
		h.eq(rules.raceGears({ mode = "boss", rank = 2, laps = 3, trackId = "SNOW-1" }).base, 40)
		local final = rules.raceGears({ mode = "boss", rank = 1, laps = 3, trackId = "HUB-0" })
		h.eq({ final.source, final.base }, { "finalBoss", 315 })
		h.eq(rules.raceGears({ mode = "stormcup", rank = 8, laps = 3 }).base, 61)
		h.eq(rules.raceGears({ mode = "hub", rank = 1 }).base, 0, "hub pays nothing")
		h.eq(rules.raceGears({ mode = "battle", rank = 1 }).base, 0, "battle pays nothing (yet)")
	end)

	h.test("schedules: Storm Cup at :00/:30 UTC with map and modifier rotation; Festival windows; seasons (L54)", function()
		local rules = EconomyRules.default
		local t = 1794011400 + 17 -- 00:30:17 on season day 1
		local now = rules.stormCupCurrent(t)
		h.eq(now.startsAt % 1800, 0)
		h.eq(now.startsAt, 1794011400)
		local nextCup = rules.stormCupNext(t)
		h.eq(nextCup.startsAt, 1794013200)
		h.eq(nextCup.lobbyOpensAt, 1794013200 - 60)
		local combos: { [string]: boolean } = {}
		local n = 0
		local cycle = #MonetizationConfig.STORM_CUP.tracks * #MonetizationConfig.STORM_CUP.modifiers
		for i = 0, cycle - 1 do
			local cup = rules.stormCup(now.index + i)
			local key = cup.trackId .. "/" .. cup.modifier
			if not combos[key] then
				n += 1
			end
			combos[key] = true
		end
		h.eq(n, cycle, "every map x modifier combination comes round once per cycle (5 x 2 = 10 while mirrored is deferred)")
		-- Two independent "servers" (two rule sets) agree to the second.
		local other = EconomyRules.new(deepCopy(MonetizationConfig))
		h.eq(other.stormCupNext(t), nextCup)
		-- Festival: Saturday 15:00-16:00 and Wednesday 22:00-22:30 UTC.
		h.eq(rules.weekday(S1_START), 6, "season starts on a Saturday")
		h.eq(rules.festivalAt(S1_START + 15 * 3600 - 1), nil)
		local fest = rules.festivalAt(S1_START + 15 * 3600 + 30)
		h.ok(fest and fest.multiplier == 2 and fest.goldenCoin, "Saturday festival on")
		h.eq(rules.festivalAt(S1_START + 16 * 3600), nil, "ends at 16:00")
		local wed = S1_START + 4 * DAY
		h.eq(rules.weekday(wed), 3)
		h.ok(rules.festivalAt(wed + 22 * 3600 + 60) ~= nil, "Wednesday mini window")
		h.eq(rules.festivalAt(wed + 22 * 3600 + 30 * 60), nil, "30 minutes only")
		h.eq(rules.festivalNext(S1_START).startsAt, S1_START + 15 * 3600)
		-- Seasons: before the start counts into season 1; after the end nothing is open.
		h.eq(rules.seasonAt(S1_START - 100).id, 1)
		h.eq(rules.seasonAt(S1_START + 27 * DAY).id, 1)
		h.eq(rules.seasonAt(S1_START + 28 * DAY), nil)
	end)

	---------------------------------------------------------------------------------------------- LAUNCH_HIDE (economy v3)

	local LIVE_SET = { "gearsPack1", "gearsPack2", "gearsPack3", "gearsPack4", "winPassPremiumS1", "x2Gears" }

	local function keysOf(list: { any }): { string }
		local keys = {}
		for _, p in ipairs(list) do
			table.insert(keys, p.key)
		end
		table.sort(keys)
		return keys
	end

	local function hidden(): any
		local c = fixture()
		c.LAUNCH_HIDE = true
		return c
	end

	h.test("launch hide: one switch, OFF in the shipping (private) config; liveAtLaunch marks exactly the v3 live set", function()
		h.eq(MonetizationConfig.LAUNCH_HIDE, false, "private builds run with everything on (owner ruling 2026-10-20)")
		local live = {}
		for _, p in ipairs(MonetizationConfig.PRODUCTS) do
			if p.liveAtLaunch then
				table.insert(live, p)
			end
		end
		h.eq(keysOf(live), LIVE_SET, "4 Cash packs, 2x Cash, Win Pass Premium")
		h.eq(MonetizationConfig.LAUNCH_HIDDEN_FEATURES, { shopRotation = true, rallyStreak = true, festival = true, daily = true })
		local on = EconomyRules.default
		for _, name in ipairs({ "shopRotation", "rallyStreak", "festival", "daily" }) do
			h.eq(on.featureOn(name), true, name .. " on in private builds")
		end
		for _, p in ipairs(MonetizationConfig.PRODUCTS) do
			h.ok(on.productLive(p), p.key .. " live in private builds")
		end
		-- A live gift twin of a hidden product is a catalog error.
		local bad = hidden()
		for _, p in ipairs(bad.PRODUCTS) do
			if p.key == "giftFounderPack1" then
				p.liveAtLaunch = true
			end
		end
		h.contains(EconomyRules.new(bad).validate(), "giftFounderPack1 is live at launch but gifts a hidden product")
	end)

	h.test("launch hide OFF: every bound row is listed and promptable (private builds)", function()
		local a = newServer()
		local p = a.join(1300)
		a.sched.advance(11)
		h.eq(#a.econ.getState(p).data.products, #a.cfg.PRODUCTS, "all 21 rows listed")
		h.ok(a.econ.promptProduct(p, "founderPack1").ok)
		h.ok(a.econ.promptProduct(p, "garagePlus").ok)
		h.eq(a.econ.getState(p).data.features, { shopRotation = true, rallyStreak = true, festival = true, daily = true })
	end)

	h.test("T1-5 live kill switch: Economy.liveCheck refuses every prompt while set; nil hook = prompts as usual", function()
		local a = newServer()
		local p = a.join(1310)
		a.sched.advance(11)
		Economy.liveCheck = function(): string?
			return "paused for maintenance"
		end
		local r = a.econ.promptProduct(p, "founderPack1")
		Economy.liveCheck = nil
		h.eq(r.ok, false)
		h.eq(r.reason, "disabled")
		h.contains(a.logs, "reason=disabled (founderPack1 (live: paused for maintenance))")
		h.eq(#a.prompts, 0, "no prompt opened while paused")
		h.ok(a.econ.promptProduct(p, "founderPack1").ok, "hook cleared: promptable again")
	end)

	h.test("launch hide ON: only the live set is listed and promptable; a hidden bound row is refused at the prompt", function()
		local a = newServer({ config = hidden() })
		local p = a.join(1301)
		local friend = a.join(1302)
		a.sched.advance(11)
		local state = a.econ.getState(p).data
		h.eq(keysOf(state.products), LIVE_SET)
		for _, key in ipairs(LIVE_SET) do
			h.ok(a.econ.promptProduct(p, key).ok, key .. " promptable")
		end
		for _, key in ipairs({ "founderPack1", "rookiePack", "garagePlus", "liverySetS1_1", "trailEmber" }) do
			h.eq(a.econ.promptProduct(p, key).reason, "unavailable", key .. " hidden")
		end
		h.contains(a.logs, "action=PromptProduct reason=unavailable (founderPack1 (hidden at launch))")
		h.eq(a.econ.gift(p, "founderPack1", friend.UserId).reason, "unavailable", "hidden gift twin")
		h.eq(a.econ.gift(p, "winPassPremiumS1", friend.UserId).reason, "unavailable", "the premium gift twin is not in the live set")
		h.eq(#a.prompts, #LIVE_SET, "no prompt opened for a hidden row")
	end)

	h.test("launch hide ON: a hidden row's paid receipt is still granted, once (never refuse a paid receipt)", function()
		local a = newServer({ config = hidden() })
		local p = a.join(1303)
		a.sched.advance(11)
		h.eq(a.receipt("hidden-1", p, "founderPack1"), GRANTED, "a client can prompt any product id itself")
		local snap = a.save.get(p)
		h.eq(snap.gears, 500)
		h.ok(snap.cosmetics.owned.Livery_FounderGold and snap.cosmetics.owned.Horn_FounderBrass)
		h.eq(a.receipt("hidden-1", p, "founderPack1"), GRANTED, "retried receipt")
		h.eq(a.gears(p), 500, "granted once")
		h.eq(a.receipt("hidden-2", p, "rookiePack"), GRANTED)
		h.eq(a.receipt("live-1", p, "gearsPack2"), GRANTED)
		h.eq(a.gears(p), 500 + 100 + 1200)
	end)

	h.test("launch hide ON: no shop rotation, Daily Deal, Rally Streak, Festival or daily claim", function()
		local cfg = hidden()
		local rules = EconomyRules.new(cfg)
		-- Shop: every Cash item always in stock, full price, no deal; the same at any window.
		local view = rules.shopAt(SUNDAY_10)
		h.eq(view.rotation, false)
		h.eq(#view.slots, #cfg.SHOP.always + #cfg.SHOP.rotating)
		for _, slot in ipairs(view.slots) do
			h.ok(slot.kind == "always" and slot.stock == nil and slot.price == slot.basePrice, slot.key .. " always, full price")
		end
		h.eq(rules.shopAt(SUNDAY_10 + 300).slots, view.slots, "nothing restocks")
		h.eq(EconomyRules.default.shopAt(SUNDAY_10).rotation, true, "rotation on in private builds")
		-- Festival: Saturday 15:30 is inside the window, but hidden.
		h.eq(rules.festivalAt(S1_START + 15 * 3600 + 1800), nil)
		h.eq(rules.festivalNext(S1_START), nil)
		h.eq(rules.multiplier({ streak = true }), 1, "Rally Streak bonus off")
		h.eq(rules.multiplier({ x2 = true, streak = true }), 2, "2x Cash still applies")
		local a = newServer({ config = cfg })
		local p = a.join(1304)
		a.sched.advance(11)
		a.give(p, 5000)
		local shop = a.econ.getShop(p).data
		h.eq(shop.rotation, false)
		h.ok(a.econ.buy(p, "Livery_ChromeComet").ok, "a rotating-pool item is buyable any time")
		h.eq(a.econ.claimDaily(p).reason, "unavailable")
		a.finish(p, "race", 1)
		a.finish(p, "race", 1)
		local third = a.finish(p, "race", 1)
		h.eq({ third.streakBonus, third.multiplier, third.gears }, { false, 1, 83 }, "third finish pays no streak bonus")
		local state = a.econ.getState(p).data
		h.eq(state.features, { shopRotation = false, rallyStreak = false, festival = false, daily = false })
		h.eq(state.rallyStreak, 0, "no Rally Streak chip")
		h.eq(state.nextFestival, nil)
		a.utc.t = S1_START + 15 * 3600 + 1800
		h.eq(a.finish(p, "race", 1).festival, false, "no Festival multiplier")
	end)

	h.test("festival: override false (or true) has no schedule, so festivalNext is nil (EconomyRules bug fix)", function()
		local c = deepCopy(MonetizationConfig)
		c.FESTIVAL.override = false
		local rules = EconomyRules.new(c)
		h.eq(rules.festivalAt(S1_START + 15 * 3600 + 30), nil)
		h.eq(rules.festivalNext(S1_START), nil, "no countdown to a window that will not open")
		c.FESTIVAL.override = true
		h.ok(rules.festivalAt(S1_START) ~= nil, "forced on")
		h.eq(rules.festivalNext(S1_START), nil)
		h.eq(EconomyRules.default.festivalNext(S1_START).startsAt, S1_START + 15 * 3600, "override nil follows the table")
	end)

	---------------------------------------------------------------------------------------------- earning (L52, L55, L58)

	h.test("earn: x2 pass verified mid-session applies to the next reward only and survives rejoin (L52)", function()
		local a, b = twoServers()
		local p = a.join(1001)
		a.sched.advance(11)
		local first = a.finish(p, "race", 4)
		h.eq({ first.gears, first.multiplier, first.x2 }, { 59, 1, false })
		-- The pass is bought now: the reward already paid stays 59; the client's word alone changes nothing.
		local passId = idOf(a.cfg, "x2Gears")
		a.econ.onPassPurchaseFinished(p, passId, true)
		h.eq(a.econ.isPassActive(p, "x2Gears"), false, "API says not owned -> no multiplier")
		h.contains(a.logs, "pass purchase not verified user=1001 pass=x2Gears")
		a.owned["1001:" .. passId] = true
		a.econ.onPassPurchaseFinished(p, passId, true)
		h.ok(a.econ.isPassActive(p, "x2Gears"), "verified")
		h.eq(p:GetAttribute("Passes"), "x2Gears")
		h.eq(a.gears(p), 59, "nothing retroactive")
		local second = a.finish(p, "race", 4)
		h.eq({ second.gears, second.multiplier }, { 118, 2 }, "next reward doubled")
		a.leave(p)
		local p2 = b.join(1001)
		h.ok(b.econ.isPassActive(p2, "x2Gears"), "re-verified on join on another server")
		h.eq(b.save.get(p2).passCache.x2Gears, true)
		h.eq(b.gears(p2), 177)
	end)

	h.test("earn: pass check retries on join, falls back to the last verified cache when the API stays down", function()
		local a, b = twoServers()
		local passId = idOf(a.cfg, "x2Gears")
		a.owned["1002:" .. passId] = true
		a.marketDown = 1 -- first attempt fails, the retry answers
		local p = a.join(1002)
		a.sched.advance(5)
		h.ok(a.econ.isPassActive(p, "x2Gears"))
		h.contains(a.logs, "pass check failed user=1002 pass=x2Gears attempt=1")
		a.leave(p)
		b.marketDown = 99
		local p2 = b.join(1002)
		b.sched.advance(30)
		h.ok(b.econ.isPassActive(p2, "x2Gears"), "cached ownership while the API is down")
		h.contains(b.logs, "pass x2Gears unverified user=1002; using cache=true")
		h.eq(b.econ.isPassActive(p2, "garagePlus"), false, "never-verified pass stays off")
	end)

	h.test("earn: Festival doubles race payouts; Rally Streak pays x1.5 on every third finish and resets on leave (L58)", function()
		local a = newServer()
		local p = a.join(1003)
		local r1 = a.finish(p, "race", 4)
		local r2 = a.finish(p, "quickrace", 4)
		local r3 = a.finish(p, "race", 4)
		h.eq({ r1.gears, r2.gears, r3.gears }, { 59, 59, 89 }, "third consecutive finish x1.5 (88.5 rounds to 89)")
		h.eq({ r1.rallyStreak, r3.rallyStreak, r3.streakBonus }, { 1, 3, true })
		h.eq(p:GetAttribute("RallyStreak"), 3)
		-- An abandoned race breaks the streak.
		a.econ.raceAbandoned(p)
		h.eq(p:GetAttribute("RallyStreak"), 0)
		h.eq(a.finish(p, "race", 4).rallyStreak, 1)
		-- Saturday Festival
		a.utc.t = S1_START + 7 * DAY + 15 * 3600 + 120
		local fest = a.finish(p, "race", 4)
		h.eq({ fest.gears, fest.festival, fest.multiplier }, { 118, true, 2 })
		-- Leaving resets the streak; a rejoin starts from 0.
		a.leave(p)
		local p2 = a.join(1003)
		h.eq(p2:GetAttribute("RallyStreak"), 0)
		h.eq(a.finish(p2, "race", 4).rallyStreak, 1)
		-- Multipliers stack up to the cap.
		h.eq(a.econ.rules.multiplier({ x2 = true, festival = 2, streak = true }), 4, "2 x 2 x 1.5 capped at 4")
		-- Simulated finishes pay only in Studio (isStudio mocked true here); hub and battle pay nothing.
		h.eq(a.finish(p2, "hub", 1), nil)
		h.eq(a.finish(p2, "battle", 1), nil)
	end)

	h.test("earn: a restricted PolicyService player earns, sees and pays exactly the same; unknown policy = restricted (L59)", function()
		local a = newServer()
		local free = a.join(1004)
		local restricted = a.join(1005, { restricted = true })
		h.eq(a.econ.policy(free).paidRandomItemsRestricted, false)
		h.eq(a.econ.policy(restricted).paidRandomItemsRestricted, true)
		h.eq(a.econ.canOfferPaidRandomItems(restricted), false)
		h.eq(a.finish(free, "race", 2).gears, a.finish(restricted, "race", 2).gears)
		local s1, s2 = a.econ.getShop(free), a.econ.getShop(restricted)
		h.eq(#s1.data.slots, #s2.data.slots)
		for i, slot in ipairs(s1.data.slots) do
			h.eq({ slot.key, slot.price }, { s2.data.slots[i].key, s2.data.slots[i].price })
		end
		a.policyDown = true
		local unknown = a.join(1006)
		a.sched.advance(10)
		h.eq(a.econ.policy(unknown).known, false)
		h.eq(a.econ.canOfferPaidRandomItems(unknown), false, "no answer = most restricted")
		h.contains(a.logs, "policy user=1006 known=false paidRandomRestricted=true")
	end)

	---------------------------------------------------------------------------------------------- Win Pass (L55)

	h.test("win pass: every finished race counts (any place), battles do not; first places still count wins; tiers and premium gating (L55, v3)", function()
		local a = newServer()
		local p = a.join(1010)
		a.sched.advance(11)
		local r = a.finish(p, "race", 8)
		h.eq({ r.winPassRace, r.winPassRaces, r.winPassWin }, { true, 1, false }, "last place still counts as a race")
		h.eq(a.finish(p, "timetrial", 1).winPassRaces, 2, "time trial is a finished race")
		h.eq(a.finish(p, "boss", 2, { trackId = "SNOW-1" }).winPassRaces, 3, "boss race counts, win or lose")
		h.eq(a.finish(p, "coin", 4).winPassRaces, 4)
		local win = a.finish(p, "race", 1)
		h.eq({ win.winPassRaces, win.winPassWins, win.winPassWin }, { 5, 1, true }, "wins still counted into the kept field")
		h.eq(a.finish(p, "battle", 1), nil, "a battle is not a race: no payout, no count")
		h.eq(a.save.get(p).winPass.races, 5)
		h.eq(p:GetAttribute("WinPassRaces"), 5)
		h.eq(p:GetAttribute("WinPassWins"), 1)
		h.eq(a.econ.claimWinPass(p, 20, "free").reason, "notEnoughRaces")
		local claim = a.econ.claimWinPass(p, 5, "free")
		h.ok(claim.ok)
		h.eq(claim.data.key, "Livery_WP1_Rookie")
		h.ok(a.save.get(p).cosmetics.owned.Livery_WP1_Rookie)
		h.eq(a.save.get(p).winPass.claimedFree, { r5 = true }, "races-era claims save under r<tier>")
		h.eq(a.econ.claimWinPass(p, 5, "free").reason, "claimed")
		h.eq(a.econ.claimWinPass(p, 5, "premium").reason, "needsPremium", "premium column only with the product")
		h.eq(a.econ.claimWinPass(p, 1, "free").reason, "noTier", "the wins-era tier 1 is gone")
		h.eq(a.econ.claimWinPass(p, "5", "free").reason, "badRequest", "forged tier type")
		h.eq(a.econ.claimWinPass(p, 5, "gold").reason, "badRequest", "forged column")
		-- Premium is a developer product; once granted the premium column opens.
		h.ok(a.econ.promptProduct(p, "winPassPremiumS1").ok)
		h.eq(a.receipt("wp-1", p, "winPassPremiumS1"), GRANTED)
		h.ok(a.save.get(p).winPass.premium)
		h.eq(a.econ.claimWinPass(p, 5, "premium").data.key, "Trail_WP1_Premium")
		h.eq(a.econ.promptProduct(p, "winPassPremiumS1").reason, "owned", "no second premium prompt")
		local view = a.econ.getState(p).data.winPass
		h.eq({ view.races, view.wins, view.claimedFree, view.claimedPremium }, { 5, 1, { ["5"] = true }, { ["5"] = true } })
		-- Season end: claims close and nothing counts; the next season starts both counters from zero.
		a.utc.t = S1_START + 28 * DAY + 5
		h.eq(a.econ.claimWinPass(p, 5, "free").reason, "seasonOver")
		local late = a.finish(p, "race", 1)
		h.eq({ late.winPassWin, late.winPassRace }, { false, false }, "no season open: nothing counts")
	end)

	h.test("win pass: a wins-era profile keeps every claimed tier and its rewards; races start at 0 (v3 migration)", function()
		local a = newServer()
		local p = a.join(1011)
		a.sched.advance(11)
		-- What the wins-era build saved: tiers 1 and 5 (Rookie, Bronze) claimed, premium tier 1 claimed, 7 wins.
		h.ok(a.save.edit(p, "specWinsEra", function(d: any)
			d.winPass.wins = 7
			d.winPass.races = nil
			d.winPass.premium = true
			d.winPass.claimedFree = { ["1"] = true, ["5"] = true }
			d.winPass.claimedPremium = { ["1"] = true }
			d.cosmetics.owned.Livery_WP1_Rookie = true
			d.cosmetics.owned.Livery_WP1_Bronze = true
			d.cosmetics.owned.Trail_WP1_Premium = true
		end))
		a.leave(p)
		local p2 = a.join(1011)
		a.sched.advance(11)
		local snap = a.save.get(p2)
		h.eq(snap.winPass.races, 0, "old profiles start the races counter at 0")
		h.eq(snap.winPass.wins, 7, "wins kept")
		local view = a.econ.getState(p2).data.winPass
		h.eq(view.claimedFree, { ["5"] = true, ["20"] = true }, "wins-era tiers 1 and 5 show as the first two tiers, claimed")
		h.eq(view.claimedPremium, { ["5"] = true })
		h.eq(view.races, 0)
		h.eq(a.econ.claimWinPass(p2, 5, "free").reason, "claimed", "no second Rookie for a claim made under wins")
		for _ = 1, 20 do
			a.finish(p2, "quickrace", 6)
		end
		h.eq(a.econ.claimWinPass(p2, 20, "free").reason, "claimed", "Bronze already taken under wins")
		h.eq(a.econ.claimWinPass(p2, 5, "premium").reason, "claimed")
		local prem = a.econ.claimWinPass(p2, 20, "premium")
		h.eq(prem.data.key, "Horn_Thunder", "the next unclaimed tier opens on races")
		h.eq(a.econ.claimWinPass(p2, 45, "free").reason, "notEnoughRaces")
		local after = a.save.get(p2)
		h.eq(after.winPass.claimedFree, { ["1"] = true, ["5"] = true }, "old claim keys never rewritten")
		h.eq(after.winPass.claimedPremium, { ["1"] = true, r20 = true })
		h.ok(after.cosmetics.owned.Livery_WP1_Rookie and after.cosmetics.owned.Livery_WP1_Bronze and after.cosmetics.owned.Trail_WP1_Premium, "rewards kept")
	end)

	h.test("win pass: bots cannot farm it; a simulated finish counts only in Studio", function()
		local live = newServer({ studio = false })
		local p = live.join(1012)
		live.sched.advance(11)
		h.eq(live.finish(p, "race", 1, { simulated = true }), nil, "simulated finish on a live server: nothing")
		h.eq(live.save.get(p).winPass.races, 0)
		h.eq(live.finish(p, "race", 3).winPassRaces, 1, "a real finish counts")
		-- Bots never reach Economy: RaceManager calls raceFinished only on a player's own finish.
		local rm = h.readFile("src/server/RaceManager.luau")
		h.eq(h.count({ rm }, "econ.raceFinished"), 1)
		h.contains(rm, "isPlayer = true,\n\t\t\ttime = rec.finishTime")
	end)

	---------------------------------------------------------------------------------------------- shop (L53, L56)

	h.test("shop: identical stock on two servers at one restock index; restock every 5 min; Daily Deal by UTC day (L56)", function()
		local a, b = twoServers()
		local sa, sb = a.econ.getShop(a.join(1020)), b.econ.getShop(b.join(1021))
		h.ok(sa.ok and sb.ok)
		h.eq(sa.data.slots, sb.data.slots, "same window -> same slots, prices and stock")
		h.eq(sa.data.window, math.floor(SUNDAY_10 / 300))
		local always, rotating, deal = 0, 0, 0
		for _, s in ipairs(sa.data.slots) do
			if s.kind == "always" then
				always += 1
				h.eq(s.stock, nil, "always slots never sell out")
			elseif s.kind == "rotating" then
				rotating += 1
				h.ok(s.stock and s.stock >= 1)
			else
				deal += 1
				h.ok(s.price < s.basePrice, "deal is discounted")
			end
		end
		h.eq({ always, rotating, deal }, { 4, 3, 1 })
		-- Across windows the rotation changes; within the day the deal does not.
		local rules = a.econ.rules
		local changed = false
		local dealKey = rules.shopAt(SUNDAY_10).slots[8].key
		for i = 1, 20 do
			local view = rules.shopAt(SUNDAY_10 + i * 300)
			if view.slots[5].key ~= rules.shopAt(SUNDAY_10).slots[5].key then
				changed = true
			end
			if view.day == rules.utcDay(SUNDAY_10) then
				h.eq(view.slots[8].key, dealKey, "deal fixed for the UTC day")
			end
		end
		h.ok(changed, "rotation changes across restocks")
		local deals: { [string]: boolean } = {}
		for d = 0, 13 do
			deals[rules.shopAt(SUNDAY_10 + d * DAY).slots[8].key] = true
		end
		local distinct = 0
		for _ in pairs(deals) do
			distinct += 1
		end
		h.ok(distinct >= 4, "deal rolls by UTC day (" .. distinct .. " distinct in 14 days)")
		-- Deterministic: the same window always yields the same view.
		h.eq(rules.shopAt(SUNDAY_10), rules.shopAt(SUNDAY_10 + 299 - (SUNDAY_10 % 300)))
	end)

	h.test("shop: buy validates price, stock and ownership; forged buys and equips are rejected and logged (L53)", function()
		local a, b = twoServers()
		local p = a.join(1030)
		-- Pick an epic rotating slot window so stock 1 sells out.
		local rules = a.econ.rules
		local t = SUNDAY_10
		local slot: any = nil
		for i = 0, 400 do
			for _, s in ipairs(rules.shopAt(SUNDAY_10 + i * 300).slots) do
				if s.kind == "rotating" and s.stock == 1 then
					slot = s
					t = SUNDAY_10 + i * 300
					break
				end
			end
			if slot then
				break
			end
		end
		h.ok(slot, "an epic rotating slot exists within 400 windows")
		a.utc.t = t
		h.eq(a.econ.buy(p, slot.key).reason, "gears", "cannot afford")
		h.contains(a.logs, "[SkyRally][ECON] reject user=1030 action=Buy reason=gears")
		a.give(p, 5000)
		local bought = a.econ.buy(p, slot.key)
		h.ok(bought.ok)
		h.eq(a.gears(p), 5000 - slot.price)
		h.eq(a.econ.buy(p, slot.key).reason, "owned")
		local other = a.join(1031)
		a.give(other, 5000)
		h.eq(a.econ.buy(other, slot.key).reason, "soldOut", "stock 1 per server per window")
		local shopView = a.econ.getShop(other).data
		for _, s in ipairs(shopView.slots) do
			if s.slot == slot.slot then
				h.eq({ s.stock, s.soldOut }, { 0, true })
			end
		end
		-- Another server at the same window still has its own stock.
		local q = b.join(1032)
		b.give(q, 5000)
		h.ok(b.econ.buy(q, slot.key).ok, "server B's stock is its own")
		-- The restock refills.
		a.utc.t = t + 300
		local refilled = a.econ.getShop(other).data
		h.eq(refilled.window, math.floor(t / 300) + 1)
		-- Forged requests
		local before = a.gears(other)
		h.eq(a.econ.buy(other, "Livery_BattleAmulet").reason, "notInShop", "progression reward is never sold")
		h.eq(a.econ.buy(other, "Livery_WP1_Gold").reason, "notInShop", "win pass exclusive is never sold")
		h.eq(a.econ.buy(other, "Livery_DoesNotExist").reason, "unknown")
		h.eq(a.econ.buy(other, { "Trail_Ember" }).reason, "badRequest")
		h.eq(a.econ.buy(other, string.rep("x", 200)).reason, "badRequest")
		h.eq(a.gears(other), before, "forged buys spend nothing")
		h.eq(a.econ.equip(other, "trail", "Trail_Aurora").reason, "notOwned")
		h.eq(a.econ.equip(other, "trail", "Livery_SunsetCoral").reason, "wrongSlot")
		h.eq(a.econ.equip(other, "wings", "Trail_Ember").reason, "badSlot")
		h.eq(a.econ.equip(other, "planeLivery", "Livery_BattleAmulet").reason, "notOwned")
		h.eq(a.econ.equip(other, "trail", 42).reason, "badRequest")
		h.ok(h.count(a.logs, "[SkyRally][ECON] reject user=1031") >= 10, "every rejection logged")
		h.eq(a.save.get(other).cosmetics.loadout, {}, "nothing equipped by forged requests")
	end)

	h.test("loadout: owned items equip per slot, unequip, replicate as Equipped JSON and round-trip through the save (L53)", function()
		local a, b = twoServers()
		local p = a.join(1040)
		a.give(p, 2000)
		local livery = a.econ.buy(p, "Livery_SunsetCoral")
		local trail = a.econ.buy(p, "Trail_Ember")
		h.ok(livery.ok and trail.ok)
		local spent = livery.data.price + trail.data.price -- the Daily Deal may list either at its discount
		h.ok(a.econ.equip(p, "planeLivery", "Livery_SunsetCoral").ok)
		h.ok(a.econ.equip(p, "carLivery", "Livery_SunsetCoral").ok, "one livery fits both vehicles")
		h.ok(a.econ.equip(p, "trail", "Trail_Ember").ok)
		h.eq(p:GetAttribute("Equipped"), '{"carLivery":"Livery_SunsetCoral","planeLivery":"Livery_SunsetCoral","trail":"Trail_Ember"}')
		h.eq(p:GetAttribute("Gears"), 2000 - spent)
		h.ok(a.econ.equip(p, "carLivery", "").ok, "unequip")
		h.ok(a.econ.claimDaily(p).ok)
		a.finish(p, "race", 1)
		a.leave(p)
		local p2 = b.join(1040)
		local snap = b.save.get(p2)
		h.eq(snap.cosmetics.loadout, { planeLivery = "Livery_SunsetCoral", trail = "Trail_Ember" })
		h.eq(snap.gears, 2000 - spent + 50 + 83)
		h.eq(snap.winPass.wins, 1)
		h.eq(snap.streak.dailyCount, 1)
		h.eq(p2:GetAttribute("WinPassWins"), 1)
	end)

	h.test("garage+: favorites and loadout presets need the verified pass", function()
		local a = newServer()
		local p = a.join(1045)
		a.give(p, 1000)
		a.econ.buy(p, "Trail_Ember")
		a.econ.equip(p, "trail", "Trail_Ember")
		h.eq(a.econ.savePreset(p, 1).reason, "needsGaragePlus")
		h.eq(a.econ.setFavorite(p, "Trail_Ember", true).reason, "needsGaragePlus")
		a.owned["1045:" .. idOf(a.cfg, "garagePlus")] = true
		a.econ.onPassPurchaseFinished(p, idOf(a.cfg, "garagePlus"), true)
		h.ok(a.econ.savePreset(p, 1).ok)
		h.eq(a.econ.savePreset(p, 4).reason, "badRequest")
		h.ok(a.econ.equip(p, "trail", "").ok)
		h.ok(a.econ.loadPreset(p, 1).ok)
		h.eq(a.save.get(p).cosmetics.loadout, { trail = "Trail_Ember" })
		h.eq(a.econ.loadPreset(p, 2).reason, "emptyOrRefused")
		h.ok(a.econ.setFavorite(p, "Trail_Ember", true).ok)
		h.eq(a.save.get(p).economy.favorites, { Trail_Ember = true })
	end)

	---------------------------------------------------------------------------------------------- daily (L58)

	h.test("daily: once per UTC day, streak across consecutive days, a missed day resets, day 7 grants the trail (L58)", function()
		local a = newServer()
		local p = a.join(1050)
		local day0 = math.floor(SUNDAY_10 / DAY) * DAY
		a.utc.t = day0 + 23 * 3600 + 3590 -- 23:59:50 UTC
		local c1 = a.econ.claimDaily(p)
		h.eq({ c1.data.day, c1.data.gears }, { 1, 50 })
		h.eq(a.econ.claimDaily(p).reason, "claimed", "same UTC day")
		a.utc.t = day0 + DAY + 20 -- 10 s past midnight: a new UTC day
		h.eq(a.econ.claimDaily(p).data.day, 2)
		for d = 3, 7 do
			a.utc.t = day0 + (d - 1) * DAY + 3600
			local c = a.econ.claimDaily(p)
			h.eq(c.data.day, d)
			if d == 7 then
				h.eq(c.data.gears, 150)
				h.eq(c.data.cosmetics, { "Comet Streak" })
			end
		end
		h.ok(a.save.get(p).cosmetics.owned.Trail_DailyComet)
		a.utc.t = day0 + 7 * DAY + 3600
		h.eq(a.econ.claimDaily(p).data.day, 1, "after day 7 the cycle restarts")
		a.utc.t = day0 + 9 * DAY + 3600 -- skipped a day
		h.eq(a.econ.claimDaily(p).data.day, 1, "a missed day resets the streak")
		h.eq(a.save.get(p).gears, 50 + 60 + 70 + 80 + 90 + 100 + 150 + 50 + 50)
	end)

	---------------------------------------------------------------------------------------------- login popup (economy v3 step 7)

	h.test("login popup: shows once per UTC day, claim shares the streak with the Garage claim, old profiles are due", function()
		local a = newServer()
		local p = a.join(1051)
		local day0 = math.floor(SUNDAY_10 / DAY) * DAY
		a.utc.t = day0 + 3600
		-- A profile saved before the field existed reconciles to 0 = due.
		h.eq(a.save.get(p).streak.loginShownDay, 0)
		local first = a.econ.handleRequest(p, "GetLogin")
		h.ok(first.ok and first.data.show, "first join of the day shows")
		h.eq({ first.data.claimable, first.data.day, first.data.cash }, { true, 1, 50 })
		h.eq(a.econ.handleRequest(p, "GetLogin").data.show, false, "same day: not again (rejoin, second server, repeat call)")
		h.eq(a.save.get(p).streak.loginShownDay, math.floor((day0 + 3600) / DAY))
		-- CLAIM through the popup path is the daily claim; the Garage path then sees it claimed.
		local c = a.econ.handleRequest(p, "ClaimLoginDaily")
		h.ok(c.ok and c.data.day == 1 and c.data.gears == 50)
		h.eq(a.econ.claimDaily(p).reason, "claimed", "Garage claim after the popup claim")
		h.eq(a.econ.handleRequest(p, "ClaimLoginDaily").reason, "claimed", "no second claim")
		-- Next day: due again; today's reward is day 2.
		a.utc.t = day0 + DAY + 60
		local second = a.econ.handleRequest(p, "GetLogin").data
		h.eq({ second.show, second.claimable, second.day, second.cash }, { true, true, 2, 60 })
		-- Claimed in the Garage first: the popup still shows (theme, countdown) with nothing to claim.
		h.ok(a.econ.claimDaily(p).ok)
		a.utc.t = day0 + 2 * DAY + 60
		h.ok(a.econ.claimDaily(p).ok)
		a.utc.t = day0 + 2 * DAY + 120
		local info = a.econ.handleRequest(p, "GetLogin").data
		h.eq({ info.show, info.claimable }, { true, false })
	end)

	h.test("login popup: day 7 names the Comet Streak trail; LAUNCH_HIDE keeps the popup claim, hides the Garage claim", function()
		local cfg = hidden()
		local a = newServer({ config = cfg })
		local p = a.join(1052)
		local day0 = math.floor(SUNDAY_10 / DAY) * DAY
		for d = 1, 6 do
			a.utc.t = day0 + (d - 1) * DAY + 3600
			h.ok(a.econ.loginPopup(p).data.show)
			h.eq(a.econ.claimDaily(p).reason, "unavailable", "Garage claim hidden")
			h.eq(a.econ.claimDaily(p, true).data.day, d, "popup claim works")
		end
		a.utc.t = day0 + 6 * DAY + 3600
		local seven = a.econ.loginPopup(p).data
		h.eq({ seven.day, seven.cash, seven.trail }, { 7, 150, "Comet Streak" })
		local c = a.econ.claimDaily(p, true)
		h.eq(c.data.cosmetics, { "Comet Streak" })
		h.ok(a.save.get(p).cosmetics.owned.Trail_DailyComet)
	end)

	---------------------------------------------------------------------------------------------- receipts (L51)

	h.test("receipts: one PurchaseId delivered on two servers grants once (L51)", function()
		local a, b = twoServers()
		local p = a.join(1060)
		h.eq(a.receipt("dup-1", p, "gearsPack2"), GRANTED)
		h.eq(a.gears(p), 1200)
		h.eq(a.purchases["dup-1"].granted, true, "PurchaseHistory ledger written")
		h.eq(a.receipt("dup-1", p, "gearsPack2"), GRANTED, "same server again")
		h.eq(a.gears(p), 1200, "no second grant")
		a.leave(p)
		local p2 = b.join(1060)
		h.eq(b.receipt("dup-1", p2, "gearsPack2"), GRANTED, "redelivered to server B")
		h.eq(b.gears(p2), 1200, "still exactly once")
		h.contains(b.logs, "receipt dup-1 already granted (ledger")
		local iap = 0
		for _, e in ipairs(a.analytics) do
			if e.tx == "IAP" then
				iap += 1
			end
		end
		h.eq(iap, 1, "one economy event for one purchase")
	end)

	h.test("receipts: a ledger write that fails after the durable grant answers NotProcessedYet and never regrants", function()
		local a, b = twoServers()
		local p = a.join(1061)
		a.purchaseStore.failing = false
		-- Fail only the ledger write: the read succeeds, the grant lands, then the store goes down.
		local inner = a.purchaseStore.update
		local reads = 0
		a.purchaseStore.update = function(key: string, transform: any, ids: any): (boolean, string?)
			reads += 1
			if reads >= 2 then
				return false, "502: simulated DataStore outage"
			end
			return inner(key, transform, ids)
		end
		h.eq(a.receipt("half-1", p, "gearsPack1"), NOT_YET)
		h.eq(a.gears(p), 500, "grant is in the profile")
		h.eq(a.save.get(p).economy.receipts["half-1"].ledger, false)
		a.leave(p)
		local p2 = b.join(1061)
		h.eq(b.receipt("half-1", p2, "gearsPack1"), GRANTED, "retried on another server: ledger completed")
		h.eq(b.gears(p2), 500, "profile marker stopped a second grant")
		h.eq(b.save.get(p2).economy.receipts["half-1"].ledger, true)
		h.eq(b.purchases["half-1"].granted, true)
	end)

	h.test("receipts: absent buyer -> NotProcessedYet; granted on rejoin with one Delivered toast (L51)", function()
		local a = newServer()
		local p = a.join(1062)
		a.leave(p)
		local cfg = a.cfg
		local decision = a.sched.run(function()
			return a.econ.processReceipt({ PurchaseId = "away-1", PlayerId = 1062, ProductId = idOf(cfg, "founderPack1") })
		end)
		h.eq(decision, NOT_YET)
		h.eq(a.purchases["away-1"], nil, "nothing recorded")
		h.contains(a.logs, "receipt away-1 buyer 1062 not loaded here")
		local p2 = a.join(1062)
		-- Roblox redelivers once the buyer is back.
		h.eq(a.receipt("away-1", p2, "founderPack1"), GRANTED)
		h.eq(a.receipt("away-2", p2, "gearsPack1"), GRANTED)
		h.eq(#a.toasts(1062), 0, "toasts wait for the join window")
		a.sched.advance(10)
		local toasts = a.toasts(1062)
		h.eq(#toasts, 1, "one Delivered toast for both")
		h.eq(toasts[1].kind, "Delivered")
		h.contains(toasts[1].text, "Founder Gold")
		h.contains(toasts[1].text, "500 Cash")
		h.eq(a.gears(p2), 500 + 500)
	end)

	h.test("receipts: DataStore failure (ledger or profile) -> NotProcessedYet, then granted once when it recovers (L51)", function()
		local a = newServer()
		local p = a.join(1063)
		a.purchaseStore.failing = true
		h.eq(a.receipt("ds-1", p, "gearsPack1"), NOT_YET, "ledger read fails")
		h.eq(a.gears(p), 0, "nothing granted while the ledger is unreadable")
		a.purchaseStore.failing = false
		a.profileStore.failing = true
		h.eq(a.receipt("ds-2", p, "gearsPack3"), NOT_YET, "profile write fails: no PurchaseGranted before a durable grant")
		h.contains(a.logs, "receipt ds-2 grant not saved yet user=1063")
		a.profileStore.failing = false
		h.eq(a.receipt("ds-1", p, "gearsPack1"), GRANTED)
		h.eq(a.receipt("ds-2", p, "gearsPack3"), GRANTED)
		h.eq(a.gears(p), 500 + 3500, "each once")
		h.eq(a.backing.u_1063.profile.gears, 4000, "durable")
	end)

	h.test("receipts: Rookie Pack once per account; livery set honours the buyer's picks and fills from the set", function()
		local a = newServer()
		local p = a.join(1064)
		a.sched.advance(11)
		h.ok(a.econ.promptProduct(p, "rookiePack").ok)
		h.eq(a.receipt("rk-1", p, "rookiePack"), GRANTED)
		h.ok(a.save.get(p).cosmetics.owned.Trail_RookieSpark)
		h.eq(a.econ.promptProduct(p, "rookiePack").reason, "owned", "once per account")
		h.ok(a.econ.promptProduct(p, "liverySetS1_3", { "Livery_S1_Nebula", "Livery_WP1_Gold", "Livery_S1_Nebula" }).ok)
		h.eq(a.receipt("set-1", p, "liverySetS1_3"), GRANTED)
		local owned = a.save.get(p).cosmetics.owned
		h.ok(owned.Livery_S1_Nebula, "picked")
		h.ok(owned.Livery_S1_Aurora and owned.Livery_S1_Glacier, "filled in set order")
		h.eq(owned.Livery_WP1_Gold, nil, "a pick outside the set is ignored")
		h.eq(a.save.get(p).economy.intents.liverySetS1_3, nil, "intent consumed")
	end)

	h.test("receipts: a second Rookie Pack receipt pays only the standard Gears, never the bundle again (L51, L57)", function()
		local a = newServer()
		local p = a.join(1065)
		a.sched.advance(11)
		h.eq(a.receipt("rk-a", p, "rookiePack"), GRANTED)
		h.eq(a.gears(p), 100, "first purchase: the bundle")
		-- A client calls PromptProductPurchase itself, skipping the prompt gate: the receipt must refuse the bundle.
		h.eq(a.receipt("rk-b", p, "rookiePack"), GRANTED)
		h.eq(a.gears(p), 100 + MonetizationConfig.ONCE_REPEAT_GEARS, "repeat: standard rate only (no 100 Gears + duplicate refund)")
		h.eq(a.save.get(p).economy.receipts["rk-b"].repeatGears, MonetizationConfig.ONCE_REPEAT_GEARS)
		h.eq(a.receipt("rk-b", p, "rookiePack"), GRANTED, "redelivery")
		h.eq(a.gears(p), 100 + MonetizationConfig.ONCE_REPEAT_GEARS, "once")
		local sources = {}
		for _, e in ipairs(a.analytics) do
			if e.flow == "Source" and e.sku == "rookiePack" then
				table.insert(sources, e.amount)
			end
		end
		h.eq(sources, { 100, MonetizationConfig.ONCE_REPEAT_GEARS }, "Source tracks the Gears actually paid")
	end)

	h.test("receipts: a fast double-buy of the Rookie Pack before the first receipt lands pays the bundle once", function()
		local a = newServer()
		local p = a.join(1066)
		a.sched.advance(11)
		h.ok(a.econ.promptProduct(p, "rookiePack").ok)
		h.ok(a.econ.promptProduct(p, "rookiePack").ok, "both prompts pass the gate: nothing is owned yet")
		h.eq(a.receipt("dbl-1", p, "rookiePack"), GRANTED)
		h.eq(a.receipt("dbl-2", p, "rookiePack"), GRANTED)
		h.eq(a.gears(p), 100 + MonetizationConfig.ONCE_REPEAT_GEARS)
	end)

	h.test("rules: repeatOnceGears and sameIntent are pure decisions (L57, L58)", function()
		local rules = EconomyRules.default
		local rookie = rules.product("rookiePack") :: any
		local pack = rules.product("gearsPack1") :: any
		h.eq(rules.repeatOnceGears(rookie, {}), nil, "first buy grants normally")
		h.eq(rules.repeatOnceGears(rookie, { rookiePack = true }), MonetizationConfig.ONCE_REPEAT_GEARS)
		h.eq(rules.repeatOnceGears(pack, { gearsPack1 = true }), nil, "only oncePerAccount products")
		h.ok(MonetizationConfig.ONCE_REPEAT_GEARS <= 10, "no better than the standard pack rate per Robux")
		local intent = { to = 5, at = 100, nonce = "j:1" }
		h.ok(rules.sameIntent(intent, { to = 5, at = 100, nonce = "j:1" }))
		h.eq(rules.sameIntent(intent, { to = 6, at = 100, nonce = "j:2" }), false, "same second, different prompt")
		h.eq(rules.sameIntent(intent, { to = 6, at = 101, nonce = "j:1" }), false)
		h.eq(rules.sameIntent(intent, nil), false)
		h.eq(rules.sameIntent(nil, intent), false, "a receipt that read no intent clears nothing")
	end)

	---------------------------------------------------------------------------------------------- gifts (L58)

	h.test("gifts: same-server recipient gets the item and a toast, the buyer does not (L58)", function()
		local a = newServer()
		local buyer = a.join(1070)
		local friend = a.join(1071)
		a.sched.advance(11)
		h.eq(a.econ.gift(buyer, "founderPack1", 1070).reason, "badRecipient", "not to yourself")
		h.eq(a.econ.gift(buyer, "founderPack1", 4242).reason, "recipientNotHere")
		h.eq(a.econ.gift(buyer, "gearsPack1", 1071).reason, "notGiftable")
		h.ok(a.econ.gift(buyer, "founderPack1", 1071).ok)
		h.eq(a.prompts[#a.prompts].id, idOf(a.cfg, "giftFounderPack1"), "the twin is prompted")
		h.eq(a.receipt("gift-1", buyer, "giftFounderPack1"), GRANTED)
		h.eq(a.gears(friend), 500)
		h.ok(a.save.get(friend).cosmetics.owned.Livery_FounderGold)
		h.eq(a.gears(buyer), 0, "buyer gets nothing")
		h.eq(a.save.get(buyer).cosmetics.owned.Livery_FounderGold, nil)
		h.eq(a.toasts(1071)[1].kind, "Gift")
		h.ok(a.save.get(friend).pendingGifts["gift-1"], "recipient ledger entry")
		h.eq(a.receipt("gift-1", buyer, "giftFounderPack1"), GRANTED, "duplicate")
		h.eq(a.gears(friend), 500, "once")
	end)

	h.test("gifts: a quick second gift made while the first receipt is saving keeps its own recipient (L58)", function()
		local sched = h.newScheduler()
		local backing: any = {}
		local slow: any = { kind = "slow", delay = 0, data = nil }
		local inner = SaveService.newMemoryStore(backing)
		slow.data = inner.data
		function slow.update(key: string, transform: (any) -> any, userIds: { number }?): (boolean, string?)
			if slow.delay > 0 then
				sched.sleep(slow.delay)
			end
			return inner.update(key, transform, userIds)
		end
		local a = newServer({ sched = sched, backing = backing, profileStore = slow })
		local buyer = a.join(1090)
		local bob = a.join(1091)
		local alice = a.join(1092)
		a.sched.advance(11)
		h.ok(a.econ.gift(buyer, "liverySetS1_1", 1091, { "Livery_S1_Ember" }).ok)
		slow.delay = 3 -- Bob's profile flush now takes a while
		local first = nil
		a.sched.spawn(function()
			first = a.econ.processReceipt({ PurchaseId = "q-1", PlayerId = 1090, ProductId = idOf(a.cfg, "giftLiverySetS1_1"), CurrencySpent = 1 })
		end)
		a.sched.advance(1)
		h.eq(first, nil, "receipt 1 is still saving Bob's gift")
		h.ok(a.econ.gift(buyer, "liverySetS1_1", 1092, { "Livery_S1_Aurora" }).ok, "buyer taps GIFT for Alice")
		a.sched.advance(20)
		h.eq(first, GRANTED)
		h.ok(a.save.get(bob).cosmetics.owned.Livery_S1_Ember, "Bob got the first gift")
		local kept = a.save.get(buyer).economy.intents.giftLiverySetS1_1
		h.ok(kept and kept.to == 1092, "Alice's intent survived receipt 1")
		slow.delay = 0
		h.eq(a.receipt("q-2", buyer, "giftLiverySetS1_1"), GRANTED)
		h.ok(a.save.get(alice).cosmetics.owned.Livery_S1_Aurora, "Alice got the second gift")
		h.eq(a.save.get(buyer).cosmetics.owned.Livery_S1_Aurora, nil, "the buyer did not")
		h.eq(a.save.get(buyer).economy.intents.giftLiverySetS1_1, nil, "intent consumed by receipt 2")
	end)

	h.test("gifts: offline recipient -> PendingGifts inbox; delivered once on join with one Delivered toast (L58)", function()
		local a, b = twoServers()
		local buyer = a.join(1080)
		local friend = a.join(1081)
		a.sched.advance(11)
		h.ok(a.econ.gift(buyer, "liverySetS1_1", 1081, { "Livery_S1_Ember" }).ok)
		a.leave(friend) -- leaves before the receipt arrives
		h.eq(a.receipt("gift-off", buyer, "giftLiverySetS1_1"), GRANTED)
		h.ok(a.gifts.g_1081 and a.gifts.g_1081["gift-off"], "written to PendingGifts")
		h.contains(a.logs, "gift queued to=1081 purchase=gift-off")
		h.eq(a.save.get(buyer).cosmetics.owned.Livery_S1_Ember, nil, "buyer gets nothing")
		-- The recipient joins a different server.
		local f2 = b.join(1081)
		b.sched.advance(10)
		h.ok(b.save.get(f2).cosmetics.owned.Livery_S1_Ember, "the picked livery")
		local toasts = b.toasts(1081)
		h.eq(#toasts, 1, "one Delivered toast")
		h.contains(toasts[1].text, "S1 Ember")
		h.eq(next(b.gifts.g_1081), nil, "inbox cleared")
		h.eq(b.backing.u_1081.profile.pendingGifts["gift-off"].key, "liverySetS1_1", "ledger durable")
		-- Rejoin: nothing twice. Re-seed the inbox as if the clear had failed: the ledger still stops a regrant.
		b.leave(f2)
		b.gifts.g_1081 = { ["gift-off"] = { key = "liverySetS1_1", from = 1080, choices = { "Livery_S1_Ember" }, at = 1 } }
		local f3 = a.join(1081)
		a.sched.advance(10)
		h.eq(#a.toasts(1081), 0, "no second toast")
		h.eq(a.save.get(f3).gears, 0, "no duplicate refund either: never granted twice")
		h.eq(next(a.gifts.g_1081), nil, "stale inbox copy removed")
	end)

	---------------------------------------------------------------------------------------------- prompts (L50, L59)

	h.test("prompts: Enabled=false or id=nil hides every product and refuses every prompt (L50)", function()
		local shipping = newServer({ config = fixture(false, false) })
		local p = shipping.join(1090)
		shipping.sched.advance(11)
		h.eq(shipping.econ.getState(p).data, { enabled = false }, "Garage hidden entirely")
		h.eq(shipping.econ.getShop(p).reason, "disabled")
		for _, prod in ipairs(MonetizationConfig.PRODUCTS) do
			h.eq(shipping.econ.promptProduct(p, prod.key).reason, "disabled", prod.key)
		end
		h.eq(shipping.econ.gift(p, "founderPack1", 1091).reason, "disabled")
		h.eq(shipping.econ.buy(p, "Trail_Ember").reason, "disabled")
		h.eq(shipping.econ.claimDaily(p).reason, "disabled")
		h.eq(#shipping.prompts, 0, "MarketplaceService never prompted")
		-- Gears still accrue server-side with the store off.
		h.eq(shipping.finish(p, "race", 4).gears, 59)
		-- A receipt for an id the catalog does not bind is never granted.
		local d = shipping.sched.run(function()
			return shipping.econ.processReceipt({ PurchaseId = "x", PlayerId = 1090, ProductId = 123456 })
		end)
		h.eq(d, NOT_YET)
		-- Store on but ids nil: everything still hidden and unbuyable.
		local noIds = newServer({ config = fixture(true, false) })
		local q = noIds.join(1092)
		noIds.sched.advance(11)
		h.eq(noIds.econ.getState(q).data.products, {}, "no id -> not listed")
		for _, prod in ipairs(MonetizationConfig.PRODUCTS) do
			h.eq(noIds.econ.promptProduct(q, prod.key).reason, "unavailable", prod.key)
		end
		h.eq(#noIds.prompts, 0)
		-- With fixture ids, prices come from GetProductInfo, never the DEFAULT label.
		local bound = newServer()
		local r = bound.join(1093)
		local products = bound.econ.getState(r).data.products
		h.eq(#products, #MonetizationConfig.PRODUCTS)
		h.eq(products[1].price, 77, "price from GetProductInfo")
		h.eq(products[1].defaultPriceLabel, nil, "the DEFAULT label never reaches the client")
	end)

	h.test("prices: a failed GetProductInfo is retried after 20 s, not cached for 10 minutes (L50)", function()
		local a = newServer()
		local p = a.join(1094)
		a.sched.advance(11)
		a.priceFailures = 1
		local first = a.econ.getState(p).data.products[1]
		h.eq(first.price, nil, "the throttled lookup shows no price")
		a.sched.advance(5)
		h.eq(a.econ.getState(p).data.products[1].price, nil, "still inside the short retry window")
		a.sched.advance(20)
		h.eq(a.econ.getState(p).data.products[1].price, 77, "retried and recovered")
		a.sched.advance(300)
		a.priceFailures = 5
		h.eq(a.econ.getState(p).data.products[1].price, 77, "a good price is still reused for 10 minutes")
	end)

	h.test("prompts: never in the first 10 s, during a race, countdown or boss intro; owned passes refuse (L59)", function()
		local a = newServer()
		local p = a.join(1095)
		h.eq(a.econ.promptProduct(p, "gearsPack1").reason, "busy", "first 10 s")
		a.sched.advance(11)
		a.busy[p] = "countdown"
		h.eq(a.econ.promptProduct(p, "gearsPack1").reason, "busy")
		a.busy[p] = "racing (race)"
		h.eq(a.econ.gift(p, "founderPack1", 1096).reason, "busy")
		h.contains(a.logs, "reject user=1095 action=PromptProduct reason=busy (countdown)")
		a.busy[p] = nil
		h.ok(a.econ.promptProduct(p, "gearsPack1").ok)
		h.ok(a.econ.promptProduct(p, "x2Gears").ok)
		a.owned["1095:" .. idOf(a.cfg, "x2Gears")] = true
		a.econ.onPassPurchaseFinished(p, idOf(a.cfg, "x2Gears"), true)
		h.eq(a.econ.promptProduct(p, "x2Gears").reason, "owned")
		h.eq(a.econ.promptProduct(p, "giftFounderPack1").reason, "useGift", "twins only through Gift")
		h.eq(#a.prompts, 2)
	end)

	h.test("remote API: dispatch, unknown actions and rate limiting are rejected and logged", function()
		local a = newServer()
		local p = a.join(1100)
		local state = a.econ.handleRequest(p, "GetState")
		h.ok(state.ok and state.data.enabled)
		h.eq(state.data.gears, 0)
		h.eq(state.data.winPass.tiers, { 5, 20, 45, 80, 120 })
		h.ok(state.data.stormCup.startsAt % 1800 == 0)
		h.eq(a.econ.handleRequest(p, "GrantGears", 99999).reason, "unknownAction")
		h.eq(a.econ.handleRequest(p, nil).reason, "unknownAction")
		local limited = 0
		for _ = 1, 12 do
			if a.econ.handleRequest(p, "GetShop").reason == "rateLimited" then
				limited += 1
			end
		end
		h.ok(limited >= 4, "burst of 8 then rate limited (" .. limited .. ")")
		h.contains(a.logs, "reject user=1100 action=GetShop reason=rateLimited")
		a.sched.advance(5)
		h.ok(a.econ.handleRequest(p, "GetShop").ok, "refills over time")
		h.eq(a.gears(p), 0, "no request path grants Gears")
	end)
	---------------------------------------------------------------------------------------------- adversarial probes

	h.test("probe: a flood of forged requests with huge arguments cannot flood the server log", function()
		local a = newServer()
		local p = a.join(1300)
		a.sched.advance(11)
		local huge = string.rep("A", 50000)
		local before = #a.logs
		for _ = 1, 200 do
			a.econ.handleRequest(p, huge)
			a.econ.handleRequest(p, "Gift", "founderPack1", huge)
			a.econ.handleRequest(p, "Equip", huge, "Trail_Ember")
		end
		local bytes, limited = 0, 0
		for i = before + 1, #a.logs do
			bytes += #a.logs[i]
			if string.find(a.logs[i], "reason=rateLimited", 1, true) then
				limited += 1
			end
		end
		h.ok(bytes < 8000, "log bytes for 600 forged requests: " .. bytes)
		h.ok(limited <= 1, "one rateLimited line per throttled streak, got " .. limited)
		-- Once the bucket refills a request goes through again, and the next throttled streak logs once more.
		a.sched.advance(5)
		h.ok(a.econ.handleRequest(p, "GetShop").ok)
		for _ = 1, 20 do
			a.econ.handleRequest(p, "GetShop")
		end
		h.contains(a.logs, "reject user=1300 action=GetShop reason=rateLimited")
	end)

	h.test("probe: a payout that is not saved does not advance the Rally Streak", function()
		local a = newServer()
		local p = a.join(1310)
		h.eq(a.finish(p, "race", 4).rallyStreak, 1)
		a.save.release(p) -- the session ends (leave in progress): edits are refused
		h.eq(a.finish(p, "race", 4), nil, "nothing paid")
		h.eq(a.finish(p, "race", 4), nil, "nothing paid")
		h.eq(p:GetAttribute("RallyStreak"), 1, "streak unchanged by unpaid finishes")
	end)

	h.test("probe: prompts also wait while the map switches and while a Storm Cup is due (L59)", function()
		local ws = h.stubs.workspace
		local serverNow = 1000
		ws.GetServerTimeNow = function(): number
			return serverNow
		end
		local p = h.fakePlayer(1320)
		local function clear()
			for _, k in ipairs({ "RaceGoTime", "RaceMode", "TrackSwitching", "StormCupState" }) do
				ws:SetAttribute(k, nil)
			end
		end
		clear()
		ws:SetAttribute("RaceMode", "hub")
		h.eq(Economy.liveBusy(p), nil, "hub, idle")
		ws:SetAttribute("TrackSwitching", true)
		h.ok(Economy.liveBusy(p) ~= nil, "map switch (curtain, then the countdown) is busy")
		ws:SetAttribute("TrackSwitching", false)
		ws:SetAttribute("StormCupState", "due")
		h.ok(Economy.liveBusy(p) ~= nil, "a due Storm Cup pulls the hub into a race any moment")
		ws:SetAttribute("StormCupState", "lobby")
		h.eq(Economy.liveBusy(p), nil, "lobby minute: hub races are held, the Garage is fine")
		ws:SetAttribute("RaceGoTime", serverNow + 3)
		h.ok(Economy.liveBusy(p) ~= nil, "countdown / boss intro")
		ws:SetAttribute("RaceGoTime", nil)
		ws:SetAttribute("RaceMode", "boss")
		h.ok(Economy.liveBusy(p) ~= nil, "racing")
		p:SetAttribute("RaceFinished", true)
		h.eq(Economy.liveBusy(p), nil, "results screen")
		clear()
	end)

	---------------------------------------------------------------------------------------------- receipt hardening (L51, L52)
	-- Mock receipts only: every id below comes from fixture() (990001..) or is a deliberately unknown number.

	h.test("receipts: the PurchaseHistory ledger is written only after the grant is durable in the profile store (L51, L52)", function()
		local a = newServer()
		local p = a.join(1400)
		local inner = a.purchaseStore.update
		local seen: { any } = {}
		a.purchaseStore.update = function(key: string, transform: any, ids: any): (boolean, string?)
			local rec = a.backing.u_1400
			table.insert(seen, {
				gears = rec and rec.profile.gears or 0,
				marker = rec ~= nil and rec.profile.economy.receipts[key] ~= nil,
			})
			return inner(key, transform, ids)
		end
		h.eq(a.receipt("order-1", p, "gearsPack1"), GRANTED)
		h.eq(#seen, 2, "one ledger read, one ledger write")
		h.eq(seen[1], { gears = 0, marker = false }, "nothing saved before the ledger read")
		h.eq(seen[2], { gears = 500, marker = true }, "grant and receipt marker already in the DataStore at the ledger write")
		h.eq(a.backing.u_1400.profile.gears, 500)
		h.eq(a.purchases["order-1"].granted, true)
	end)

	h.test("receipts: buyer present but save not loaded (loading or load failed) -> NotProcessedYet, nothing written (L51)", function()
		local a = newServer()
		-- Still loading: in Players and known to Economy, but SaveService never finished a load.
		local p = h.fakePlayer(1401)
		a.players[1401] = p
		a.econ.playerAdded(p)
		h.eq(a.receipt("load-1", p, "gearsPack1"), NOT_YET)
		h.contains(a.logs, "receipt load-1 buyer 1401 not loaded here")
		h.eq(a.purchases["load-1"], nil, "no ledger entry")
		h.eq(a.backing.u_1401, nil, "no profile write")
		-- Load failed: the store is down at join.
		a.profileStore.failing = true
		local q = a.join(1402)
		h.eq(a.save.get(q), nil, "load failed")
		h.eq(a.receipt("load-2", q, "gearsPack2"), NOT_YET)
		h.eq(a.purchases["load-2"], nil)
		h.eq(a.backing.u_1402, nil)
		-- Once the load succeeds, the redelivered receipt grants exactly once.
		a.profileStore.failing = false
		a.sched.run(function()
			a.save.load(p)
		end)
		h.eq(a.receipt("load-1", p, "gearsPack1"), GRANTED)
		h.eq(a.receipt("load-1", p, "gearsPack1"), GRANTED, "redelivery is a no-op")
		h.eq(a.gears(p), 500)
	end)

	h.test("receipts: the same PurchaseId arriving twice at once on one server is answered NotProcessedYet, granted once (L51)", function()
		local a = newServer()
		local p = a.join(1403)
		local inner = a.purchaseStore.update
		a.purchaseStore.update = function(key: string, transform: any, ids: any): (boolean, string?)
			a.sched.sleep(1) -- DataStore latency so both deliveries overlap
			return inner(key, transform, ids)
		end
		local cfg = a.cfg
		local receipt = { PurchaseId = "race-1", PlayerId = 1403, ProductId = idOf(cfg, "gearsPack3"), CurrencySpent = 1 }
		local first: any, second: any = nil, nil
		a.sched.spawn(function()
			first = a.econ.processReceipt(receipt)
		end)
		a.sched.spawn(function()
			second = a.econ.processReceipt(receipt)
		end)
		h.eq(second, NOT_YET, "the overlapping delivery waits")
		a.sched.advance(60)
		h.eq(first, GRANTED)
		h.eq(a.gears(p), 3500, "granted once")
		h.eq(a.receipt("race-1", p, "gearsPack3"), GRANTED, "Roblox's retry of the deferred copy is a no-op")
		h.eq(a.gears(p), 3500)
	end)

	h.test("receipts: grant not durable, buyer leaves while the store is down -> NotProcessedYet, rejoin grants exactly once (L51, L52)", function()
		local a = newServer()
		local p = a.join(1404)
		a.profileStore.failing = true
		h.eq(a.receipt("lost-1", p, "gearsPack1"), NOT_YET, "no PurchaseGranted before a durable save")
		h.eq(a.purchases["lost-1"], nil, "ledger untouched while the grant is not durable")
		h.eq(a.backing.u_1404.profile.gears, 0, "nothing reached the DataStore")
		h.eq(a.receipt("lost-1", p, "gearsPack1"), NOT_YET, "still down: Roblox's retry is deferred again")
		h.eq(a.gears(p), 500, "the in-memory grant is not doubled by the retry")
		a.leave(p) -- the final write fails too; since T2-2 it keeps retrying in the background with the grant's marker
		a.profileStore.failing = false
		a.sched.advance(120)
		h.eq(a.backing.u_1404.session, nil, "the background final save landed and unlocked")
		local p2 = a.join(1404)
		h.ok(a.save.get(p2) ~= nil, "rejoined")
		h.eq(a.gears(p2), 500, "the grant landed with its receipt marker (T2-2 background final save)")
		h.ok(a.save.get(p2).economy.receipts["lost-1"] ~= nil, "the marker stops a regrant")
		h.eq(a.receipt("lost-1", p2, "gearsPack1"), GRANTED)
		h.eq(a.receipt("lost-1", p2, "gearsPack1"), GRANTED)
		h.eq(a.gears(p2), 500, "granted exactly once in total")
		h.eq(a.backing.u_1404.profile.gears, 500)
	end)

	h.test("receipts: malformed or foreign receipts are never granted and never crash (L51)", function()
		local a = newServer()
		local p = a.join(1405)
		local cfg = a.cfg
		local function decide(r: any): any
			return a.sched.run(function()
				return a.econ.processReceipt(r)
			end)
		end
		h.eq(decide({ PurchaseId = "bad-1", PlayerId = 1405, ProductId = 123456 }), NOT_YET, "unknown product id")
		h.eq(decide({ PurchaseId = "bad-2", PlayerId = 1405, ProductId = idOf(cfg, "x2Gears") }), NOT_YET, "a pass id is not a dev product")
		h.eq(decide({ PurchaseId = "bad-3", PlayerId = 1405, ProductId = "not a number" }), NOT_YET)
		h.eq(decide({ PurchaseId = "bad-4", ProductId = idOf(cfg, "gearsPack1") }), NOT_YET, "no buyer")
		h.eq(decide({ PurchaseId = "bad-5", PlayerId = 999999, ProductId = idOf(cfg, "gearsPack1") }), NOT_YET, "buyer not on this server")
		h.eq(decide({ PurchaseId = "bad-6", PlayerId = 1405 }), NOT_YET, "no product")
		h.eq(decide(nil), NOT_YET, "nil receipt")
		h.eq(a.gears(p), 0)
		h.eq(next(a.purchases), nil, "no ledger entries")
		h.eq(next(a.save.get(p).economy.receipts), nil, "no profile markers")
		h.contains(a.logs, "receipt bad-1 names unknown product 123456")
	end)

	h.test("receipts: the store off with ids nil grants nothing for any receipt (L50, L51)", function()
		local a = newServer({ config = fixture(false, false) })
		local p = a.join(1406)
		for i, id in ipairs({ 990001, 990005, 1, 0 }) do
			local d = a.sched.run(function()
				return a.econ.processReceipt({ PurchaseId = "ship-" .. i, PlayerId = 1406, ProductId = id })
			end)
			h.eq(d, NOT_YET, "id " .. id)
		end
		h.eq(a.gears(p), 0)
		h.eq(next(a.purchases), nil)
	end)

	h.test("shipping config: store on, ids nil -> Garage, shop, daily and Win Pass work; Robux rows hidden and refused", function()
		local a = newServer({ config = deepCopy(MonetizationConfig) })
		local p = a.join(1420)
		a.sched.advance(11)
		h.ok(a.econ.garageEnabled(), "Garage visible")
		local st = a.econ.getState(p).data
		h.eq(st.enabled, true)
		h.eq(st.storeEnabled, true)
		h.eq(st.products, {}, "nothing bound yet -> no Robux rows")
		h.ok(a.econ.getShop(p).ok, "Gears shop")
		h.ok(a.econ.claimDaily(p).ok, "daily claim")
		a.give(p, 1000)
		h.ok(a.econ.buy(p, "Trail_Ember").ok, "Gears buy")
		h.ok(a.econ.equip(p, "trail", "Trail_Ember").ok, "equip")
		h.eq(a.econ.promptProduct(p, "gearsPack1").reason, "unavailable", "unbound -> refused")
		h.eq(#a.prompts, 0)
		local d = a.sched.run(function()
			return a.econ.processReceipt({ PurchaseId = "unbound-1", PlayerId = 1420, ProductId = 4242 })
		end)
		h.eq(d, NOT_YET, "a receipt for an id nothing bound is never granted")
	end)

	h.test("bindId: a bound developer product lists, prompts and grants once; bad binds are refused", function()
		local a = newServer({ config = deepCopy(MonetizationConfig) })
		h.eq(select(2, a.econ.bindId("nope", 5)), "unknown product")
		h.eq(select(2, a.econ.bindId("gearsPack1", 0)), "malformed id")
		h.eq(select(2, a.econ.bindId("gearsPack1", 1.5)), "malformed id")
		h.ok(a.econ.bindId("gearsPack1", 1234567), "bound")
		h.eq(select(2, a.econ.bindId("gearsPack2", 1234567)), "id already bound to gearsPack1")
		h.eq(MonetizationConfig.PRODUCTS[5].id, nil, "the shipping module's rows are untouched (spec bound a copy)")
		local p = a.join(1421)
		a.sched.advance(11)
		local products = a.econ.getState(p).data.products
		h.eq(#products, 1)
		h.eq(products[1].key, "gearsPack1")
		h.eq(products[1].price, 77)
		h.ok(a.econ.promptProduct(p, "gearsPack1").ok)
		h.eq(a.prompts[1].id, 1234567)
		local function receipt(): any
			return a.sched.run(function()
				return a.econ.processReceipt({ PurchaseId = "bound-1", PlayerId = 1421, ProductId = 1234567, CurrencySpent = 49 })
			end)
		end
		h.eq(receipt(), GRANTED)
		h.eq(receipt(), GRANTED, "duplicate receipt acknowledged")
		h.eq(a.gears(p), 500, "granted exactly once (PurchaseId ledger)")
	end)

	---------------------------------------------------------------------------------------------- forged remote requests (L53)

	h.test("forged remote requests: wrong types, negative and oversized values grant, spend and equip nothing (L53)", function()
		local a = newServer()
		local cfg = a.cfg
		a.owned["1410:" .. idOf(cfg, "garagePlus")] = true -- reach the argument checks behind the Garage+ gate
		local p = a.join(1410)
		local friend = a.join(1411)
		a.sched.advance(11) -- past the join prompt grace
		h.ok(a.econ.isPassActive(p, "garagePlus"), "fixture pass verified")
		a.give(p, 300)
		h.ok(a.econ.buy(p, "Trail_Ember").ok or a.econ.buy(p, "Livery_SunsetCoral").ok, "one owned item to compare against")
		local before = deepCopy(a.save.get(p))
		local promptsBefore = #a.prompts
		local nan = 0 / 0
		local huge = 2 ^ 60
		local bad: { any } = { nil, 42, -1, 0, nan, math.huge, -math.huge, huge, 1.5, true, false, {}, { "Trail_Ember" }, "", string.rep("x", 500) }
		local calls = 0
		local function send(...: any): any
			a.sched.advance(1) -- stay under the rate limit; this spec is about argument checks
			calls += 1
			local r = a.econ.handleRequest(p, ...)
			h.eq(r.ok, false, "forged call " .. calls .. " was accepted")
			return r
		end
		for i = 1, #bad + 1 do
			local v = bad[i] -- index #bad+1 is nil as well, and nil is in the list
			send("Buy", v)
			send("Equip", v, "Trail_Ember")
			send("Equip", "trail", if v == nil or v == "" then "Trail_Aurora" else v)
			send("ClaimWinPass", v, "free")
			send("ClaimWinPass", 1, v)
			send("SavePreset", v)
			send("LoadPreset", v)
			send("SetFavorite", v, true)
			send("SetFavorite", "Trail_Ember", if type(v) == "boolean" then "yes" else v)
			send("PromptProduct", v)
			send("Gift", "founderPack1", v)
			send("Gift", v, friend.UserId)
			send(v)
		end
		send("Gift", "founderPack1", p.UserId) -- to yourself
		send("Gift", "founderPack1", -friend.UserId)
		send("Gift", "founderPack1", tostring(friend.UserId))
		send("ClaimWinPass", 1, "premium") -- no wins, no premium
		send("ClaimWinPass", 40, "free")
		send("GrantGears", 1e9)
		send("Buy", "Livery_BattleAmulet", -5000)
		-- Extra amount arguments on a real action are ignored: the server decides every number.
		a.sched.advance(1)
		local daily = a.econ.handleRequest(p, "ClaimDaily", 1e9, -1e9, { gears = 1e9 })
		h.ok(daily.ok, "the daily claim itself is valid")
		local after = a.save.get(p)
		h.eq(after.gears, before.gears + daily.data.gears, "only the server's own daily amount moved Gears")
		local ownedAfter = table.clone(after.cosmetics.owned)
		for _, key in ipairs(daily.data.cosmetics) do
			ownedAfter[key] = nil
		end
		h.eq(ownedAfter, before.cosmetics.owned, "nothing new owned")
		h.eq(after.cosmetics.loadout, before.cosmetics.loadout, "nothing equipped")
		h.eq(after.winPass, before.winPass, "no Win Pass tier claimed")
		h.eq(after.economy.presets, before.economy.presets)
		h.eq(after.economy.intents, before.economy.intents, "no purchase intent recorded")
		h.eq(after.tokens, before.tokens, "progression untouched")
		h.eq(#a.prompts, promptsBefore, "no purchase prompt opened")
		h.eq(h.count(a.logs, "reason=error"), 0, "no handler crashed on a forged argument")
		h.eq(h.count(a.logs, "reason=rateLimited"), 0, "every forged call reached its handler")
		h.ok(h.count(a.logs, "[SkyRally][ECON] reject user=1410") >= calls, "every forged call logged")
		h.eq(a.gears(friend), 0, "the friend was not touched")
	end)

	h.test("policy: PolicyService is retried, a partial answer counts as restricted, and the catalog sells no paid random item (L59)", function()
		local a = newServer()
		local p = h.fakePlayer(1420)
		local calls = 0
		local answers: { any } = { "error", "error", { IsPaidItemTradingAllowed = true } }
		local function policyFor(_player: any): any
			calls += 1
			local r = answers[calls]
			if r == "error" then
				error("HTTP 500 (simulated)")
			end
			return r
		end
		local econ = Economy.new({
			save = a.save,
			purchaseStore = a.purchaseStore,
			giftStore = a.giftStore,
			policy = policyFor,
			config = a.cfg,
			now = function(): number
				return a.utc.t
			end,
			clock = a.sched.clock,
			sleep = a.sched.sleep,
			spawn = a.sched.spawn,
			log = function(line: string)
				table.insert(a.logs, line)
			end,
			isStudio = function(): boolean
				return true
			end,
		})
		a.save.onLoaded(econ.playerLoaded)
		econ.playerAdded(p)
		a.sched.run(function()
			a.save.load(p)
		end)
		a.sched.advance(10)
		h.eq(calls, 3, "two failures retried")
		local pol = econ.policy(p)
		h.eq(pol.known, true)
		h.eq(pol.paidRandomItemsRestricted, true, "a missing ArePaidRandomItemsRestricted is treated as restricted")
		h.eq(pol.paidItemTradingAllowed, true)
		h.eq(econ.canOfferPaidRandomItems(p), false)
		local catalog = a.cfg.PRODUCTS
		for _, prod in ipairs(catalog) do
			h.ok(prod.grants.random == nil and prod.grants.crate == nil, prod.key .. " is not a paid random item")
		end
	end)
end
