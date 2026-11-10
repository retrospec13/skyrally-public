--!strict
-- Pure economy rules over MonetizationConfig: shop stock by restock window, Storm Cup and Festival schedules, Win Pass
-- seasons and claims, race payouts, multipliers, the daily streak, and the public-release hide list (LAUNCH_HIDE). No services and no clocks of its own: every function takes the
-- UTC time it answers for, so two servers (and the client's countdowns) given the same second agree exactly, and the
-- Lune specs drive it without stubs. The shop's draw uses its own Park-Miller generator rather than Random so the
-- sequence is the same on every server, every client and under Lune.
local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig"))
local StoreBinding = require(script.Parent:WaitForChild("StoreBinding"))

type Config = typeof(MonetizationConfig)
type Cosmetic = MonetizationConfig.Cosmetic
type Product = MonetizationConfig.Product

export type ShopSlot = {
	slot: string, -- "A1".."A4" always, "R1".. rotating, "DEAL"
	kind: "always" | "rotating" | "deal",
	key: string,
	price: number, -- Gears
	basePrice: number,
	stock: number?, -- starting stock this window; nil = unlimited
}

export type ShopView = {
	window: number, -- floor(utc / restockSeconds)
	rotation: boolean, -- false under LAUNCH_HIDE: every Cash item always in stock, no Daily Deal, nothing restocks
	endsAt: number, -- next restock (utc)
	day: number, -- UTC day of the Daily Deal
	dealEndsAt: number,
	slots: { ShopSlot },
}

export type StormCup = {
	index: number, -- floor(startsAt / period)
	startsAt: number,
	lobbyOpensAt: number,
	trackId: string,
	modifier: string,
}

export type Festival = {
	name: string,
	startsAt: number,
	endsAt: number,
	multiplier: number,
	goldenCoin: boolean,
}

export type Season = { id: number, name: string, startUtc: number, endUtc: number }

export type RaceInfo = {
	mode: string,
	rank: number,
	trackId: string?,
	laps: number?,
	rings: number?,
	coins: number?,
	repeatWin: boolean?, -- boss/final boss: the win's token or boss flag was already held (a replay)
}

export type Payout = {
	source: string, -- earn source for analytics and MULTIPLIED_SOURCES
	base: number,
	parts: { [string]: number },
}

export type Rules = {
	cfg: Config,
	featureOn: (name: string) -> boolean,
	productLive: (p: Product) -> boolean,
	cosmetic: (key: string) -> Cosmetic?,
	product: (key: string) -> Product?,
	productById: (id: number) -> Product?,
	bindId: (key: string, id: number) -> (boolean, string?),
	baseProduct: (p: Product) -> Product,
	repeatOnceGears: (base: Product, oneTime: { [string]: boolean }) -> number?,
	sameIntent: (used: any, current: any) -> boolean,
	giftTwin: (key: string) -> Product?,
	setLiveries: (setId: string) -> { string },
	utcDay: (t: number) -> number,
	weekday: (t: number) -> number,
	restockIndex: (t: number) -> number,
	shopAt: (t: number) -> ShopView,
	stormCup: (index: number) -> StormCup,
	stormCupCurrent: (t: number) -> StormCup,
	stormCupNext: (t: number) -> StormCup,
	festivalAt: (t: number) -> Festival?,
	festivalNext: (t: number) -> Festival?,
	seasonAt: (t: number) -> Season?,
	raceGears: (info: RaceInfo) -> Payout,
	multiplier: (flags: { x2: boolean?, festival: number?, streak: boolean? }) -> number,
	dailyStreak: (lastDay: number, lastCount: number, today: number) -> number?,
	dailyReward: (streakDay: number) -> number,
	winPassReward: (tier: number, column: string) -> string?,
	winPassClaimKey: (tier: number) -> string,
	winPassClaimed: (claimed: any, tier: number) -> boolean,
	winPassClaimedView: (claimed: any) -> { [string]: boolean },
	validate: () -> { string },
}

local EconomyRules = {}

local DAY = 86400
local PM_M = 2147483647 -- Park-Miller modulus (2^31 - 1)
local PM_A = 48271 -- 48271 * (2^31 - 1) < 2^53, so the product is exact in a double

local function prng(seed: number): () -> number
	local state = (math.floor(seed) % (PM_M - 1)) + 1
	return function(): number
		state = (state * PM_A) % PM_M
		return state
	end
end

local function roundTo5(n: number): number
	return math.floor(n / 5 + 0.5) * 5
end

local FORBIDDEN_GRANT_WORDS = { "token", "fragment", "speed", "accel", "handling", "item", "odds", "luck", "headstart", "boost" }
local ALLOWED_GRANTS = { gears = true, cosmetics = true, effect = true, winPassPremium = true, chooseFromSet = true, count = true }

function EconomyRules.new(cfg: Config?): Rules
	local c: Config = cfg or MonetizationConfig
	local rules = {} :: Rules
	rules.cfg = c

	-- LAUNCH_HIDE (MonetizationConfig header): one switch for the public release. A feature listed in
	-- LAUNCH_HIDDEN_FEATURES is off while it is on; a product sells then only when liveAtLaunch.
	function rules.featureOn(name: string): boolean
		return not (c.LAUNCH_HIDE == true and c.LAUNCH_HIDDEN_FEATURES[name] == true)
	end
	-- Listed, promptable and bound for sale. Hidden rows keep their receipts (Economy grants any bound product).
	function rules.productLive(p: Product): boolean
		return c.LAUNCH_HIDE ~= true or p.liveAtLaunch == true
	end

	local cosmeticsByKey: { [string]: Cosmetic } = {}
	for _, item in ipairs(c.COSMETICS) do
		cosmeticsByKey[item.key] = item
	end
	local productsByKey: { [string]: Product } = {}
	local productsById: { [number]: Product } = {}
	local twinOf: { [string]: Product } = {}
	for _, p in ipairs(c.PRODUCTS) do
		productsByKey[p.key] = p
		if p.id ~= nil then
			productsById[p.id] = p
		end
		if p.giftTwinOf then
			twinOf[p.giftTwinOf] = p
		end
	end

	function rules.cosmetic(key: string): Cosmetic?
		return cosmeticsByKey[key]
	end
	function rules.product(key: string): Product?
		return productsByKey[key]
	end
	function rules.productById(id: number): Product?
		return productsById[id]
	end
	-- Live binding (server/StoreBinder): sets a row's id to one read from the owner's universe and indexes it for
	-- receipts. Refuses an unknown key, a malformed id and an id another row already holds. The shipping config keeps
	-- every id nil; only this call, fed by the API or StorePassIds, ever fills one in.
	function rules.bindId(key: string, id: number): (boolean, string?)
		local p = productsByKey[key]
		if not p then
			return false, "unknown product"
		end
		if type(id) ~= "number" or id ~= id or id <= 0 or id ~= math.floor(id) or id >= 2 ^ 53 then
			return false, "malformed id"
		end
		local holder = productsById[id]
		if holder and holder ~= p then
			return false, "id already bound to " .. holder.key
		end
		if p.id ~= nil and p.id ~= id then
			productsById[p.id] = nil
		end
		p.id = id
		productsById[id] = p
		return true, nil
	end
	-- A gift twin grants what its original grants.
	function rules.baseProduct(p: Product): Product
		local twin = p.giftTwinOf
		return if twin and productsByKey[twin] then productsByKey[twin] else p
	end
	-- A oncePerAccount product whose flag is already set grants only Gears at the standard pack rate, whatever the
	-- prompt gate said (the receipt is the authority, L51/L57). nil = grant normally.
	function rules.repeatOnceGears(base: Product, oneTime: { [string]: boolean }): number?
		if not base.oncePerAccount or oneTime[base.key] ~= true then
			return nil
		end
		return c.ONCE_REPEAT_GEARS
	end
	-- Is the stored intent still the one a receipt read? A later prompt (a quick second gift) replaces the intent and
	-- must survive the earlier receipt's cleanup (L58). `used` is what the receipt read, `current` what is stored now.
	function rules.sameIntent(used: any, current: any): boolean
		if type(used) ~= "table" or type(current) ~= "table" then
			return false
		end
		return used.at == current.at and used.nonce == current.nonce
	end
	function rules.giftTwin(key: string): Product?
		return twinOf[key]
	end
	function rules.setLiveries(setId: string): { string }
		local list = {}
		for _, item in ipairs(c.COSMETICS) do
			if item.set == setId then
				table.insert(list, item.key)
			end
		end
		return list
	end

	function rules.utcDay(t: number): number
		return math.floor(t / DAY)
	end
	-- 1970-01-01 was a Thursday; 0 = Sunday.
	function rules.weekday(t: number): number
		return (math.floor(t / DAY) + 4) % 7
	end
	function rules.restockIndex(t: number): number
		return math.floor(t / c.SHOP.restockSeconds)
	end

	function rules.shopAt(t: number): ShopView
		local shop = c.SHOP
		local window = rules.restockIndex(t)
		local day = rules.utcDay(t)
		local slots: { ShopSlot } = {}
		for i, key in ipairs(shop.always) do
			local item = cosmeticsByKey[key]
			local price = if item then item.gearsPrice or 0 else 0
			table.insert(slots, { slot = "A" .. i, kind = "always", key = key, price = price, basePrice = price, stock = nil })
		end
		-- Rotation hidden (LAUNCH_HIDE): the rotating pool joins the always rows at full price with no stock limit, so
		-- every Cash item stays buyable; no Daily Deal. The window and day still advance (nothing reads them then).
		if not rules.featureOn("shopRotation") then
			for _, key in ipairs(shop.rotating) do
				local item = cosmeticsByKey[key]
				local price = if item then item.gearsPrice or 0 else 0
				table.insert(slots, { slot = "A" .. (#slots + 1), kind = "always", key = key, price = price, basePrice = price, stock = nil })
			end
			return { window = window, rotation = false, endsAt = (window + 1) * shop.restockSeconds, day = day, dealEndsAt = (day + 1) * DAY, slots = slots }
		end
		-- Weighted draw without replacement, seeded by the window alone.
		local nextRand = prng(window * 7919 + 17)
		nextRand()
		nextRand()
		local pool = table.clone(shop.rotating)
		for i = 1, math.min(shop.rotatingSlots, #pool) do
			local total = 0
			for _, key in ipairs(pool) do
				local item = cosmeticsByKey[key]
				total += shop.weight[if item then item.rarity else "common"] or 1
			end
			local pick = (nextRand() / PM_M) * total
			local chosen = #pool
			for j, key in ipairs(pool) do
				local item = cosmeticsByKey[key]
				pick -= shop.weight[if item then item.rarity else "common"] or 1
				if pick < 0 then
					chosen = j
					break
				end
			end
			local key = table.remove(pool, chosen) :: string
			local item = cosmeticsByKey[key]
			local price = if item then item.gearsPrice or 0 else 0
			local rarity = if item then item.rarity else "common"
			table.insert(slots, { slot = "R" .. i, kind = "rotating", key = key, price = price, basePrice = price, stock = shop.stock[rarity] or 1 })
		end
		-- Daily Deal: uniform over the whole Gears shop, seeded by the UTC day.
		local dealPool = table.clone(shop.always)
		for _, key in ipairs(shop.rotating) do
			table.insert(dealPool, key)
		end
		local dealRand = prng(day * 104729 + 3)
		dealRand()
		dealRand()
		local dealKey = dealPool[(dealRand() % #dealPool) + 1]
		local dealItem = cosmeticsByKey[dealKey]
		local dealBase = if dealItem then dealItem.gearsPrice or 0 else 0
		table.insert(slots, {
			slot = "DEAL",
			kind = "deal",
			key = dealKey,
			price = roundTo5(dealBase * (1 - shop.dealDiscount)),
			basePrice = dealBase,
			stock = shop.dealStock,
		})
		return {
			window = window,
			rotation = true,
			endsAt = (window + 1) * shop.restockSeconds,
			day = day,
			dealEndsAt = (day + 1) * DAY,
			slots = slots,
		}
	end

	function rules.stormCup(index: number): StormCup
		local sc = c.STORM_CUP
		local startsAt = index * sc.periodSeconds
		return {
			index = index,
			startsAt = startsAt,
			lobbyOpensAt = startsAt - sc.lobbySeconds,
			trackId = sc.tracks[(index % #sc.tracks) + 1],
			modifier = sc.modifiers[(index % #sc.modifiers) + 1],
		}
	end
	-- The cup whose start is the latest at or before t.
	function rules.stormCupCurrent(t: number): StormCup
		return rules.stormCup(math.floor(t / c.STORM_CUP.periodSeconds))
	end
	-- The first cup starting strictly after t.
	function rules.stormCupNext(t: number): StormCup
		return rules.stormCup(math.floor(t / c.STORM_CUP.periodSeconds) + 1)
	end

	local function windowOn(dayIndex: number, w: any): Festival
		local startsAt = dayIndex * DAY + w.startMinute * 60
		return { name = w.name, startsAt = startsAt, endsAt = startsAt + w.minutes * 60, multiplier = w.multiplier, goldenCoin = w.goldenCoin == true }
	end

	function rules.festivalAt(t: number): Festival?
		local fest = c.FESTIVAL
		if fest.override == false or not rules.featureOn("festival") then
			return nil
		elseif fest.override == true then
			return { name = "Festival", startsAt = t, endsAt = t + 3600, multiplier = 2, goldenCoin = true }
		end
		-- A window may cross midnight, so yesterday's windows are checked too.
		local today = rules.utcDay(t)
		for dayIndex = today - 1, today do
			local wd = (dayIndex + 4) % 7
			for _, w in ipairs(fest.windows) do
				if w.weekday == wd then
					local f = windowOn(dayIndex, w)
					if t >= f.startsAt and t < f.endsAt then
						return f
					end
				end
			end
		end
		return nil
	end

	-- The next scheduled window after t. A forced Festival (override true or false) or a hidden one has no schedule: nil,
	-- so the Garage never counts down to a window festivalAt would refuse.
	function rules.festivalNext(t: number): Festival?
		if c.FESTIVAL.override ~= nil or not rules.featureOn("festival") then
			return nil
		end
		local today = rules.utcDay(t)
		local best: Festival? = nil
		for dayIndex = today, today + 7 do
			local wd = (dayIndex + 4) % 7
			for _, w in ipairs(c.FESTIVAL.windows) do
				if w.weekday == wd then
					local f = windowOn(dayIndex, w)
					if f.startsAt > t and (best == nil or f.startsAt < best.startsAt) then
						best = f
					end
				end
			end
		end
		return best
	end

	-- The season open at t. Before the first season starts, season 1 is open (private builds count wins into it);
	-- after the last season ends and before a new one is listed, nothing is open (no counting, no claims).
	function rules.seasonAt(t: number): Season?
		local seasons = c.WIN_PASS.seasons
		local first = seasons[1]
		if first and t < first.startUtc then
			return first
		end
		for _, s in ipairs(seasons) do
			if t >= s.startUtc and t < s.endUtc then
				return s
			end
		end
		return nil
	end

	function rules.raceGears(info: RaceInfo): Payout
		local g = c.GEARS
		local rank = math.max(1, math.floor(info.rank or 99))
		local laps = math.clamp(math.floor(info.laps or 0), 0, 10)
		local rings = math.clamp(math.floor(info.rings or 0), 0, g.ringCap)
		local coins = math.clamp(math.floor(info.coins or 0), 0, 8)
		local parts: { [string]: number } = {}
		local source = info.mode
		local function placement(tbl: { number }): number
			return tbl[math.min(rank, #tbl)]
		end
		if info.mode == "race" or info.mode == "quickrace" or info.mode == "coin" then
			parts.placement = placement(g.placement)
			parts.laps = laps * g.perLap
			parts.rings = rings * g.perRing
			if info.mode == "coin" then
				parts.coins = coins * g.perCoin
			end
		elseif info.mode == "stormcup" or info.mode == "stormrace" then -- storm race v2 pays the cup's table
			parts.placement = placement(g.stormCup)
			parts.laps = laps * g.perLap
			parts.rings = rings * g.perRing
		elseif info.mode == "timetrial" then
			parts.finish = g.timeTrialFinish
			parts.laps = laps * g.perLap
			parts.rings = rings * g.perRing
		elseif info.mode == "boss" or info.mode == "rematch" then
			local final = info.mode == "boss" and info.trackId == "HUB-0"
			if final then
				source = "finalBoss"
			end
			if rank == 1 then
				-- A replayed boss win pays the rematch rate: full boss pay every time made a final-boss farm worth ~5 races.
				parts.win = if info.repeatWin == true then g.rematchWin
					elseif final then g.finalBossWin
					elseif info.mode == "boss" then g.bossWin
					else g.rematchWin
			else
				parts.finish = g.bossFinish
			end
			parts.laps = laps * g.perLap
		else
			return { source = info.mode, base = 0, parts = parts }
		end
		local base = 0
		for _, v in pairs(parts) do
			base += v
		end
		return { source = source, base = base, parts = parts }
	end

	function rules.multiplier(flags: { x2: boolean?, festival: number?, streak: boolean? }): number
		local g = c.GEARS
		local m = 1
		if flags.x2 then
			m *= g.x2Multiplier
		end
		if flags.festival and flags.festival > 1 then
			m *= flags.festival
		end
		if flags.streak and rules.featureOn("rallyStreak") then
			m *= g.rallyStreak.multiplier
		end
		return math.min(m, g.maxMultiplier)
	end

	-- The streak day a claim on `today` would be (1-7, wrapping after 7), or nil when today is already claimed.
	function rules.dailyStreak(lastDay: number, lastCount: number, today: number): number?
		if lastDay == today then
			return nil
		end
		if lastDay == today - 1 and lastCount >= 1 then
			return (lastCount % #c.GEARS.daily) + 1
		end
		return 1
	end

	function rules.dailyReward(streakDay: number): number
		local d = c.GEARS.daily
		return d[math.clamp(streakDay, 1, #d)]
	end

	function rules.winPassReward(tier: number, column: string): string?
		local wp = c.WIN_PASS
		local tbl = if column == "free" then wp.free elseif column == "premium" then wp.premium else nil
		return if tbl then tbl[tostring(tier)] else nil
	end

	-- Win Pass claims (MonetizationConfig.WIN_PASS header). The races-era key is "r<tier>"; the wins-era key was the bare
	-- tier number and still counts for the tier at the same position, so no old claim is lost and nothing is rewritten.
	function rules.winPassClaimKey(tier: number): string
		return "r" .. tostring(tier)
	end
	function rules.winPassClaimed(claimed: any, tier: number): boolean
		if type(claimed) ~= "table" then
			return false
		end
		if claimed[rules.winPassClaimKey(tier)] == true then
			return true
		end
		local wp = c.WIN_PASS
		for i, t in ipairs(wp.tiers) do
			if t == tier then
				local legacy = wp.legacyTiers[i]
				return legacy ~= nil and claimed[tostring(legacy)] == true
			end
		end
		return false
	end
	-- The claimed map keyed by the current tiers ("5" = true), as the Garage reads it.
	function rules.winPassClaimedView(claimed: any): { [string]: boolean }
		local view: { [string]: boolean } = {}
		for _, tier in ipairs(c.WIN_PASS.tiers) do
			if rules.winPassClaimed(claimed, tier) then
				view[tostring(tier)] = true
			end
		end
		return view
	end

	-- Every structural rule the catalog must keep (spec L50/L57): returns the list of violations.
	function rules.validate(): { string }
		local errors: { string } = {}
		local function bad(msg: string)
			table.insert(errors, msg)
		end
		local seen: { [string]: boolean } = {}
		local names: { [string]: string } = {} -- normalized store name -> key (StoreBinding binds by name)
		for _, p in ipairs(c.PRODUCTS) do
			if seen[p.key] then
				bad("duplicate product " .. p.key)
			end
			seen[p.key] = true
			local name = StoreBinding.normalize(StoreBinding.storeName(p))
			if name == "" then
				bad(p.key .. " has no store name")
			elseif names[name] then
				bad(p.key .. " shares its store name with " .. names[name])
			else
				names[name] = p.key
			end
			if p.id ~= nil and (type(p.id) ~= "number" or p.id <= 0 or p.id ~= math.floor(p.id)) then
				bad(p.key .. " has a malformed id")
			end
			for field in pairs(p.grants :: any) do
				if not ALLOWED_GRANTS[field] then
					bad(p.key .. " grants unknown field " .. tostring(field))
				end
				local lower = string.lower(tostring(field))
				for _, word in ipairs(FORBIDDEN_GRANT_WORDS) do
					if string.find(lower, word, 1, true) then
						bad(p.key .. " grants forbidden " .. tostring(field))
					end
				end
			end
			for _, key in ipairs(p.grants.cosmetics or {}) do
				local item = cosmeticsByKey[key]
				if not item then
					bad(p.key .. " grants unknown cosmetic " .. key)
				elseif item.source == "amulet" then
					bad(p.key .. " sells the Battle Amulet livery")
				elseif item.source == "storm" then
					bad(p.key .. " sells a Storm vendor item (Storm Shards only)")
				end
			end
			if p.kind == "Pass" and not p.grants.effect then
				bad(p.key .. " is a pass with no effect")
			elseif p.kind == "DevProduct" and p.grants.effect then
				bad(p.key .. " is a developer product with a pass effect")
			end
			if p.grants.chooseFromSet and #rules.setLiveries(p.grants.chooseFromSet) < (p.grants.count or 1) then
				bad(p.key .. " grants more liveries than its set holds")
			end
			if p.giftTwinOf then
				local base = productsByKey[p.giftTwinOf]
				if not base then
					bad(p.key .. " twins a missing product")
				elseif base.giftTwinOf or base.kind ~= "DevProduct" or base.oncePerAccount then
					bad(p.key .. " twins a product that cannot be gifted")
				elseif base.defaultPriceLabel ~= p.defaultPriceLabel then
					bad(p.key .. " is not priced like its original")
				end
			end
		end
		for _, item in ipairs(c.COSMETICS) do
			local style = (item :: any)[item.kind]
			if type(style) ~= "table" then
				bad(item.key .. " has no " .. item.kind .. " style")
			end
			if item.gearsPrice ~= nil and item.source ~= "shop" and item.source ~= "set" then
				bad(item.key .. " (" .. item.source .. ") has a Cash price")
			end
			if item.source == "shop" and not item.gearsPrice then
				bad(item.key .. " is a shop item with no price")
			end
		end
		local stocked: { [string]: boolean } = {}
		for _, list in ipairs({ c.SHOP.always, c.SHOP.rotating }) do
			for _, key in ipairs(list) do
				local item = cosmeticsByKey[key]
				if not item or not item.gearsPrice then
					bad("shop lists " .. key .. " with no Cash price")
				elseif item.source == "amulet" or item.source == "winpass" or item.source == "storm" then
					bad("shop stocks " .. key .. " (" .. item.source .. ")")
				end
				if stocked[key] then
					bad("shop lists " .. key .. " twice")
				end
				stocked[key] = true
			end
		end
		for _, column in ipairs({ "free", "premium" }) do
			for _, tier in ipairs(c.WIN_PASS.tiers) do
				local key = rules.winPassReward(tier, column)
				local item = if key then cosmeticsByKey[key] else nil
				if not item or item.source ~= "winpass" then
					bad(string.format("win pass %s tier %d has no win pass cosmetic", column, tier))
				end
			end
		end
		local wp = c.WIN_PASS
		if #wp.legacyTiers > #wp.tiers then
			bad("win pass has more legacy tiers than tiers")
		end
		for i = 2, #wp.tiers do
			if wp.tiers[i] <= wp.tiers[i - 1] then
				bad("win pass tiers must rise")
			end
		end
		for _, p in ipairs(c.PRODUCTS) do
			local base = if p.giftTwinOf then productsByKey[p.giftTwinOf] else nil
			if p.liveAtLaunch and base and not base.liveAtLaunch then
				bad(p.key .. " is live at launch but gifts a hidden product")
			end
		end
		local daily = cosmeticsByKey[c.GEARS.dailyTrail]
		if not daily or daily.kind ~= "trail" then
			bad("daily trail missing")
		end
		return errors
	end

	return rules
end

EconomyRules.default = EconomyRules.new(MonetizationConfig)

return EconomyRules
