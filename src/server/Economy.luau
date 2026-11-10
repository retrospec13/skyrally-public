--!strict
-- Gears economy, Garage requests and Robux purchases (docs/MONETIZATION_PROPOSAL.md sections 2-3, DECISIONS D16/D18;
-- TEST_LIST_LAUNCH L50-L59). Data lives in MonetizationConfig, pure rules in EconomyRules; this module is the server.
-- * Earning: race finishes (RaceManager hook), Storm Cup, daily claim. The x2 pass (verified with the API this
--   session), Festival and Rally Streak multiply the reward being paid at that moment, never one already paid.
-- * Spending: a Garage request is validated here (catalog row, ownership, price, stock, slot) and written through
--   SaveService.edit, which can never touch progression. A forged request is rejected and logged ([SkyRally][ECON]).
-- * Robux: every prompt is refused unless MonetizationConfig.Enabled, the product has a bound id (server/StoreBinder,
--   from the owner's universe; never invented), it is live (LAUNCH_HIDE off, or the row is liveAtLaunch) and the
--   player is not in a race, countdown or boss intro (or their first seconds). A hidden row's receipt is still granted. ProcessReceipt follows the official pattern: the grant
--   is saved durably before PurchaseGranted, a PurchaseHistory DataStore keyed by PurchaseId makes a receipt delivered
--   twice (even to two servers) grant once, and an absent player or a failed write answers NotProcessedYet.
-- * Gift twins grant the recipient: live on this server, or through a PendingGifts DataStore inbox read on their next
--   join. The recipient's pendingGifts ledger makes either path land exactly once.
-- Roblox APIs sit behind Options so the Lune spec (tools/tests/economy_spec.luau) drives all of it with mocks.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceAttr = require(Shared:WaitForChild("RaceAttr")) -- T1-7: the prompt gate reads the player's own race
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))
local MonetizationConfig = require(Shared:WaitForChild("MonetizationConfig"))
local EconomyRules = require(Shared:WaitForChild("EconomyRules"))
local LoginRules = require(Shared:WaitForChild("LoginRules"))
local AvatarRules = require(Shared:WaitForChild("AvatarRules")) -- economy v3 phase 6: vehicle avatars
local PromptPolicyRules = require(Shared:WaitForChild("PromptPolicyRules"))
-- Owner admin (DECISIONS D22): Cash grant clamps and the pass key the admin may flip at runtime.
local AdminRules = require(Shared:WaitForChild("AdminRules"))
local SaveService = require(script.Parent:WaitForChild("SaveService"))
local StoreBinder = require(script.Parent:WaitForChild("StoreBinder"))
-- D22a: the owner admin's runtime "all vehicles unlocked" overlay over the saved avatars (nobody else is affected).
local AvatarSelect = require(script.Parent:WaitForChild("AvatarSelect"))

local Economy = {}

-- Owner admin (DECISIONS D22): set by server/AdminService; (player) -> the admin. nil = nobody is admin. The admin entry
-- points below re-check it themselves, so a stray call for another player changes nothing.
Economy.adminCheck = nil :: ((Player) -> boolean)?
-- T1-5 live kill switch (server/LiveOps sets it): a reason while store prompts are paused or the server is closing, nil
-- otherwise. nil hook = LiveOps not up = prompts allowed (fail open). Receipts are never refused by it.
Economy.liveCheck = nil :: (() -> string?)?

local LOG = "[SkyRally][ECON] "

type Product = MonetizationConfig.Product
type Rules = EconomyRules.Rules

-- What Economy needs from SaveService (a SaveService.new() service in the spec).
export type Saver = {
	get: (player: Player) -> any?,
	edit: (player: Player, reason: string, fn: (any) -> ()) -> boolean,
	flush: (player: Player, timeout: number?) -> boolean,
}

-- MarketplaceService behind functions that may error; Economy pcalls each one.
export type Market = {
	ownsPass: (userId: number, passId: number) -> boolean,
	promptPass: (player: Player, passId: number) -> (),
	promptProduct: (player: Player, productId: number) -> (),
	priceOf: (id: number, kind: string) -> number?,
}

export type Analytics = {
	economy: (player: Player, flow: string, amount: number, balance: number, txType: string, sku: string) -> (),
	custom: (player: Player, name: string, value: number, sku: string?) -> (),
}

export type Policy = {
	known: boolean, -- false: the API never answered; treated as the most restricted player
	paidRandomItemsRestricted: boolean,
	paidItemTradingAllowed: boolean,
}

export type Options = {
	save: Saver,
	purchaseStore: SaveService.Store, -- PurchaseHistory, key = PurchaseId
	giftStore: SaveService.Store, -- PendingGifts inbox, key = "g_<recipient userId>"
	market: Market?,
	policy: ((player: Player) -> any)?, -- GetPolicyInfoForPlayerAsync; may error
	analytics: Analytics?,
	config: any?, -- MonetizationConfig-shaped table (spec fixtures); default MonetizationConfig
	now: (() -> number)?, -- UTC wall clock (schedules, shop windows, days)
	clock: (() -> number)?, -- monotonic (rate limits, join grace, toast window)
	sleep: ((number) -> ())?,
	spawn: ((() -> ()) -> ())?,
	log: ((string) -> ())?,
	playerByUserId: ((userId: number) -> Player?)?,
	isBusy: ((player: Player) -> string?)?, -- reason the player cannot see a prompt now (race, countdown), or nil
	isStudio: (() -> boolean)?,
	garageQA: (() -> boolean)?, -- Studio-only switch that shows the Garage while Enabled is false
	fire: ((player: Player, kind: string, payload: any) -> ())?, -- EconomyEvent to one client
	isAdmin: ((player: Player) -> boolean)?, -- D22 owner admin; default Economy.adminCheck
}

export type RaceInfo = {
	trackId: string,
	mode: string,
	rank: number,
	laps: number?,
	rings: number?,
	coins: number?,
	simulated: boolean?,
	repeatWin: boolean?,
	avatarKey: string?, -- the avatar raced (phase 6); nil = read the player's AvatarKey attribute (set at spawn)
}

export type RaceGears = {
	gears: number,
	base: number,
	multiplier: number,
	x2: boolean,
	festival: boolean,
	streakBonus: boolean,
	rallyStreak: number,
	winPassWin: boolean,
	winPassWins: number,
	winPassRace: boolean, -- this finish advanced the Win Pass (tiers count races finished)
	winPassRaces: number,
	parts: { [string]: number },
	avatarUnlocks: { any }?, -- ladder steps this finish unlocked (AvatarRules.Unlock rows)
}

export type Reply = { ok: boolean, reason: string?, data: any? }

type PState = {
	player: Player,
	joinedAt: number,
	loadedAt: number?,
	passes: { [string]: boolean },
	policy: Policy?,
	rally: number,
	bucket: number,
	bucketAt: number,
	toasts: { string },
	toastScheduled: boolean,
	limitedLogged: boolean, -- this throttled streak already has its one rateLimited log line
	-- D22 owner admin: pass key -> runtime override (never saved, never a receipt). nil for everyone else.
	adminPasses: { [string]: boolean }?,
}

export type Service = {
	rules: Rules,
	playerAdded: (player: Player) -> (),
	playerLoaded: (player: Player) -> (),
	playerRemoving: (player: Player) -> (),
	garageEnabled: () -> boolean,
	bindId: (key: string, id: number) -> (boolean, string?),
	isPassActive: (player: Player, key: string) -> boolean,
	policy: (player: Player) -> Policy,
	canOfferPaidRandomItems: (player: Player) -> boolean,
	earn: (player: Player, source: string, base: number, ctx: { streak: boolean?, txType: string?, sku: string? }?) -> (number, number),
	raceFinished: (player: Player, info: RaceInfo) -> RaceGears?,
	raceAbandoned: (player: Player) -> (),
	getState: (player: Player) -> Reply,
	getShop: (player: Player) -> Reply,
	buy: (player: Player, key: any) -> Reply,
	equip: (player: Player, slot: any, key: any) -> Reply,
	claimDaily: (player: Player, viaPopup: boolean?) -> Reply,
	loginPopup: (player: Player) -> Reply,
	claimWinPass: (player: Player, tier: any, column: any) -> Reply,
	promptProduct: (player: Player, key: any, choices: any?) -> Reply,
	gift: (player: Player, key: any, recipientUserId: any, choices: any?) -> Reply,
	setFavorite: (player: Player, key: any, on: any) -> Reply,
	savePreset: (player: Player, index: any) -> Reply,
	loadPreset: (player: Player, index: any) -> Reply,
	getAvatars: (player: Player) -> Reply,
	buyAvatar: (player: Player, key: any) -> Reply,
	selectAvatar: (player: Player, key: any) -> Reply,
	wearSkin: (player: Player, key: any, stepId: any) -> Reply,
	avatarKeyFound: (player: Player) -> (),
	handleRequest: (player: Player, action: any, ...any) -> Reply,
	processReceipt: (receipt: any) -> any,
	onPassPurchaseFinished: (player: Player, passId: number, purchased: boolean) -> (),
	flushToasts: (player: Player) -> (),
	-- D22 owner admin only (each re-checks isAdmin): Cash grant, runtime pass flip, Win Pass counters.
	adminGrantCash: (player: Player, amount: any) -> Reply,
	adminSetPass: (player: Player, key: any, on: any) -> Reply,
	adminSetWinPass: (player: Player, field: any, value: any) -> Reply,
}

local MAX_KEY_LEN = 64
-- Forged arguments reach the log only this long (a remote argument can be megabytes).
local MAX_LOG_FIELD = 80

local function clip(s: string): string
	return if #s > MAX_LOG_FIELD then string.sub(s, 1, MAX_LOG_FIELD) .. "..." else s
end

local function isKey(v: any): boolean
	return type(v) == "string" and #v > 0 and #v <= MAX_KEY_LEN
end

local function isWhole(v: any): boolean
	return type(v) == "number" and v == v and v == math.floor(v) and math.abs(v) < 2 ^ 53
end

local function readStore(store: SaveService.Store, key: string): (boolean, any)
	local value: any = nil
	local ok, err = store.update(key, function(old: any): any
		value = old
		return nil -- read only: cancel the write
	end)
	return ok, if ok then value else err
end

function Economy.new(options: Options): Service
	local cfg: any = options.config or MonetizationConfig
	local rules: Rules = if options.config then EconomyRules.new(options.config) else EconomyRules.default
	local save = options.save
	local market = options.market
	local analytics = options.analytics
	local purchaseStore = options.purchaseStore
	local giftStore = options.giftStore
	local now = options.now or function(): number
		return os.time()
	end
	local clock = options.clock or function(): number
		return os.clock()
	end
	local sleep = options.sleep or function(seconds: number)
		task.wait(seconds)
	end
	local spawnTask = options.spawn or function(fn: () -> ())
		task.spawn(fn)
	end
	local log = options.log or function(line: string)
		print(line)
	end
	local playerByUserId: (number) -> Player? = options.playerByUserId or function(userId: number): Player?
		return Players:GetPlayerByUserId(userId)
	end
	local isBusy: (Player) -> string? = options.isBusy or function(_player: Player): string?
		return nil
	end
	local isStudio = options.isStudio or function(): boolean
		return RunService:IsStudio()
	end
	local garageQA = options.garageQA or function(): boolean
		return false
	end
	local fire: (Player, string, any) -> () = options.fire or function(_player: Player, _kind: string, _payload: any) end
	local isAdmin: (Player) -> boolean = options.isAdmin or function(player: Player): boolean
		local check = Economy.adminCheck
		return check ~= nil and check(player) == true
	end
	local svcCfg = cfg.SERVICE

	local states: { [Player]: PState } = {}
	local inFlight: { [string]: boolean } = {}
	-- Per-server stock: sold counts reset when the restock window (or the deal's UTC day) changes.
	local shop = { window = -1, day = -1, sold = {} :: { [string]: number }, dealSold = 0 }
	local priceCache: { [string]: { price: number?, at: number } } = {}

	local service = {} :: Service
	service.rules = rules

	local function reject(player: Player, action: string, reason: string, detail: string?): Reply
		log(string.format("%sreject user=%d action=%s reason=%s%s", LOG, player.UserId, clip(action), reason, if detail then " (" .. clip(detail) .. ")" else ""))
		return { ok = false, reason = reason }
	end

	local function stateOf(player: Player): PState
		local st = states[player]
		if not st then
			st = {
				player = player,
				joinedAt = clock(),
				loadedAt = nil,
				passes = {},
				policy = nil,
				rally = 0,
				bucket = svcCfg.requestBurst,
				bucketAt = clock(),
				toasts = {},
				toastScheduled = false,
				limitedLogged = false,
			}
			states[player] = st
		end
		return st :: PState
	end

	local function track(player: Player, flow: string, amount: number, balance: number, txType: string, sku: string)
		if analytics and amount > 0 then
			pcall(analytics.economy, player, flow, amount, balance, txType, sku)
		end
	end

	local function trackCustom(player: Player, name: string, value: number, sku: string?)
		if analytics then
			pcall(analytics.custom, player, name, value, sku)
		end
	end

	-- Win Pass season rollover inside an edit: a new season starts the counter and both columns from zero.
	local function ensureSeason(profile: any): any
		local season = rules.seasonAt(now())
		if season and profile.winPass.season ~= season.id then
			profile.winPass.season = season.id
			profile.winPass.wins = 0
			profile.winPass.races = 0
			profile.winPass.premium = false
			profile.winPass.claimedFree = {}
			profile.winPass.claimedPremium = {}
		end
		return season
	end

	local function grantCosmetic(profile: any, key: string, out: { string })
		local item = rules.cosmetic(key)
		-- Progression rewards and Storm vendor items (Storm Shards only) are never granted by a product or a gift.
		if not item or item.source == "amulet" or item.source == "storm" then
			return
		end
		if profile.cosmetics.owned[key] then
			local refund = cfg.DUPLICATE_GEARS[item.rarity] or 0
			profile.gears += refund
			table.insert(out, string.format("%d Cash (already had %s)", refund, item.name))
		else
			profile.cosmetics.owned[key] = true
			table.insert(out, item.name)
		end
	end

	-- Applies a product's grants to a profile draft (inside SaveService.edit: must not yield). Labels go to `out`.
	local function applyGrants(profile: any, p: Product, choices: any, out: { string })
		local g = p.grants
		if g.gears then
			profile.gears += g.gears
			table.insert(out, string.format("%d Cash", g.gears))
		end
		for _, key in ipairs(g.cosmetics or {}) do
			grantCosmetic(profile, key, out)
		end
		if g.winPassPremium then
			ensureSeason(profile)
			if profile.winPass.season == g.winPassPremium and not profile.winPass.premium then
				profile.winPass.premium = true
				table.insert(out, "Win Pass Premium")
			else
				-- Bought for a season that is not open (or already premium): paid back in Gears, never lost.
				local refund = cfg.DUPLICATE_GEARS.exclusive or 0
				profile.gears += refund
				table.insert(out, string.format("%d Cash (Win Pass Premium already active)", refund))
			end
		end
		if g.chooseFromSet then
			local set = rules.setLiveries(g.chooseFromSet)
			local inSet: { [string]: boolean } = {}
			for _, key in ipairs(set) do
				inSet[key] = true
			end
			local want = g.count or 1
			local picked: { [string]: boolean } = {}
			local order: { string } = {}
			-- The buyer's picks first, then the set in order, skipping what is already owned.
			if type(choices) == "table" then
				for _, key in ipairs(choices) do
					if #order < want and inSet[key] and not picked[key] and not profile.cosmetics.owned[key] then
						picked[key] = true
						table.insert(order, key)
					end
				end
			end
			for _, key in ipairs(set) do
				if #order < want and not picked[key] and not profile.cosmetics.owned[key] then
					picked[key] = true
					table.insert(order, key)
				end
			end
			for _, key in ipairs(order) do
				grantCosmetic(profile, key, out)
			end
			-- Whole set already owned: the remainder is paid back in Gears.
			for _ = #order + 1, want do
				local refund = cfg.DUPLICATE_GEARS.rare or 0
				profile.gears += refund
				table.insert(out, string.format("%d Cash (set already complete)", refund))
			end
		end
		if p.oncePerAccount then
			profile.economy.oneTime[p.key] = true
		end
	end

	-- Keeps the newest `keep` entries of a {id -> {at}} ledger; `eligible` limits which entries may go.
	local function prune(map: { [string]: any }, keep: number, eligible: ((any) -> boolean)?)
		local list = {}
		for id, entry in pairs(map) do
			if type(entry) ~= "table" or not eligible or eligible(entry) then
				table.insert(list, { id = id, at = if type(entry) == "table" then tonumber(entry.at) or 0 else 0 })
			end
		end
		if #list <= keep then
			return
		end
		table.sort(list, function(a, b)
			return a.at > b.at
		end)
		for i = keep + 1, #list do
			map[list[i].id] = nil
		end
	end

	---------------------------------------------------------------------------------------------- toasts

	local function fireToasts(st: PState)
		st.toastScheduled = false
		if #st.toasts == 0 or st.player.Parent == nil then
			table.clear(st.toasts)
			return
		end
		local text = "Delivered: " .. table.concat(st.toasts, ", ")
		table.clear(st.toasts)
		fire(st.player, "Toast", { kind = "Delivered", text = text })
		log(string.format("%stoast user=%d %s", LOG, st.player.UserId, text))
	end

	-- Grants that land in the first seconds after a join (receipts completed while disconnected, gift inbox) share
	-- one "Delivered" toast; later ones toast at once.
	local function delivered(player: Player, labels: { string })
		local st = stateOf(player)
		for _, label in ipairs(labels) do
			table.insert(st.toasts, label)
		end
		local loadedAt = st.loadedAt
		local window = svcCfg.deliveredToastWindow
		if loadedAt and clock() - loadedAt < window then
			if not st.toastScheduled then
				st.toastScheduled = true
				local wait = window - (clock() - loadedAt)
				spawnTask(function()
					sleep(wait)
					if st.toastScheduled then
						fireToasts(st)
					end
				end)
			end
		else
			fireToasts(st)
		end
	end

	function service.flushToasts(player: Player)
		local st = states[player]
		if st then
			fireToasts(st)
		end
	end

	---------------------------------------------------------------------------------------------- passes and policy

	local function passProducts(): { Product }
		local list = {}
		for _, p in ipairs(cfg.PRODUCTS) do
			if p.kind == "Pass" then
				table.insert(list, p)
			end
		end
		return list
	end

	-- true/false from the API; nil when it never answered.
	local function verifyPass(player: Player, p: Product): boolean?
		local id = p.id
		if id == nil or not market then
			return false
		end
		for attempt = 1, svcCfg.passCheckAttempts do
			local ok, owns = pcall(market.ownsPass, player.UserId, id)
			if ok then
				return owns == true
			end
			log(string.format("%spass check failed user=%d pass=%s attempt=%d: %s", LOG, player.UserId, p.key, attempt, tostring(owns)))
			if attempt < svcCfg.passCheckAttempts then
				sleep(attempt)
			end
		end
		return nil
	end

	-- The passes a player holds right now, sorted: the HUD attribute and the Garage both read this list.
	local function activePassList(st: PState): { string }
		local list = {}
		for key, on in pairs(st.passes) do
			if on then
				table.insert(list, key)
			end
		end
		local overrides = st.adminPasses
		if overrides then
			-- D22: the admin's runtime pass override (nil for everyone else) shows as isPassActive applies it.
			list = {}
			for _, p in ipairs(passProducts()) do
				if service.isPassActive(st.player, p.key) then
					table.insert(list, p.key)
				end
			end
		end
		table.sort(list)
		return list
	end

	local function publishPasses(st: PState)
		st.player:SetAttribute("Passes", table.concat(activePassList(st), ","))
	end

	local function setPass(st: PState, p: Product, owns: boolean)
		st.passes[p.key] = owns
		local profile = save.get(st.player)
		if profile and (profile.passCache[p.key] == true) ~= owns then
			save.edit(st.player, "passCache:" .. p.key, function(draft: any)
				draft.passCache[p.key] = if owns then true else nil
			end)
		end
	end

	local function checkPasses(st: PState)
		for _, p in ipairs(passProducts()) do
			local owns = verifyPass(st.player, p)
			if owns == nil then
				-- API down: keep what was last verified so an owner does not lose x2 during an outage.
				local profile = save.get(st.player)
				st.passes[p.key] = p.id ~= nil and profile ~= nil and profile.passCache[p.key] == true
				log(string.format("%spass %s unverified user=%d; using cache=%s", LOG, p.key, st.player.UserId, tostring(st.passes[p.key])))
			else
				setPass(st, p, owns)
			end
		end
		publishPasses(st)
	end

	local function checkPolicy(st: PState)
		local result: Policy = { known = false, paidRandomItemsRestricted = true, paidItemTradingAllowed = false }
		local fetch = options.policy
		if fetch then
			for attempt = 1, 3 do
				local ok, info = pcall(fetch, st.player)
				if ok and type(info) == "table" then
					result = {
						known = true,
						paidRandomItemsRestricted = info.ArePaidRandomItemsRestricted ~= false,
						paidItemTradingAllowed = info.IsPaidItemTradingAllowed == true,
					}
					break
				end
				if attempt < 3 then
					sleep(attempt)
				end
			end
		end
		st.policy = result
		log(string.format(
			"%spolicy user=%d known=%s paidRandomRestricted=%s trading=%s",
			LOG,
			st.player.UserId,
			tostring(result.known),
			tostring(result.paidRandomItemsRestricted),
			tostring(result.paidItemTradingAllowed)
		))
	end

	function service.policy(player: Player): Policy
		local st = states[player]
		return (st and st.policy) or { known = false, paidRandomItemsRestricted = true, paidItemTradingAllowed = false }
	end

	-- The launch catalog has no paid random items; this gate is what a later crate must pass (unknown = restricted).
	function service.canOfferPaidRandomItems(player: Player): boolean
		return not service.policy(player).paidRandomItemsRestricted
	end

	function service.isPassActive(player: Player, key: string): boolean
		local st = states[player]
		-- D22: the admin's runtime override branches first; for everyone else adminPasses is nil and the check is unchanged.
		local override = if st and st.adminPasses then st.adminPasses[key] else nil
		if override ~= nil and isAdmin(player) then
			return override
		end
		return st ~= nil and st.passes[key] == true
	end

	function service.garageEnabled(): boolean
		return cfg.Enabled == true or (isStudio() and garageQA())
	end

	-- StoreBinder's only way in: an id read from the owner's universe (or StorePassIds) for one catalog row. Receipts
	-- and prompts see it at once; a cached "no price" for the row is dropped so the Garage prices it on its next read.
	function service.bindId(key: string, id: number): (boolean, string?)
		local ok, why = rules.bindId(key, id)
		if ok then
			priceCache[key] = nil
		end
		return ok, why
	end

	---------------------------------------------------------------------------------------------- gift inbox

	local function giftKey(userId: number): string
		return "g_" .. tostring(userId)
	end

	local function deliverInbox(player: Player)
		local okRead, box = readStore(giftStore, giftKey(player.UserId))
		if not okRead then
			log(string.format("%sgift inbox read failed user=%d: %s", LOG, player.UserId, tostring(box)))
			return
		end
		if type(box) ~= "table" then
			return
		end
		local profile = save.get(player)
		if not profile then
			return
		end
		local done: { string } = {}
		local fresh: { { id: string, gift: any } } = {}
		for id, gift in pairs(box) do
			if profile.pendingGifts[id] then
				table.insert(done, id) -- landed earlier; only the inbox copy is left
			elseif type(gift) == "table" and rules.product(tostring(gift.key)) then
				table.insert(fresh, { id = id, gift = gift })
			else
				log(string.format("%sgift inbox entry %s for user=%d names no product; dropped", LOG, tostring(id), player.UserId))
				table.insert(done, id)
			end
		end
		if #fresh > 0 then
			local labels: { string } = {}
			local stamp = now()
			local ok = save.edit(player, "giftInbox", function(draft: any)
				for _, entry in ipairs(fresh) do
					local base = rules.product(entry.gift.key) :: Product
					applyGrants(draft, base, entry.gift.choices, labels)
					draft.pendingGifts[entry.id] = { key = base.key, from = tonumber(entry.gift.from) or 0, at = stamp }
				end
				prune(draft.pendingGifts, svcCfg.receiptsKept)
			end)
			-- The inbox copy goes only once the ledger entry is durable, so a crash in between cannot lose the gift.
			if ok and save.flush(player, svcCfg.receiptFlushTimeout) then
				for _, entry in ipairs(fresh) do
					table.insert(done, entry.id)
					local from = tostring(entry.gift.fromName or entry.gift.from)
					log(string.format("%sgift delivered user=%d purchase=%s key=%s from=%s (inbox)", LOG, player.UserId, entry.id, tostring(entry.gift.key), from))
				end
				delivered(player, labels)
			else
				log(string.format("%sgift inbox grant not saved user=%d; retried on next join", LOG, player.UserId))
			end
		end
		if #done > 0 then
			local okClear, err = giftStore.update(giftKey(player.UserId), function(old: any): any
				if type(old) ~= "table" then
					return nil
				end
				for _, id in ipairs(done) do
					old[id] = nil
				end
				return old
			end)
			if not okClear then
				log(string.format("%sgift inbox clear failed user=%d: %s", LOG, player.UserId, tostring(err)))
			end
		end
	end

	---------------------------------------------------------------------------------------------- lifecycle

	function service.playerAdded(player: Player)
		stateOf(player)
	end

	-- SaveService.onLoaded: passes, policy, gift inbox, HUD attributes.
	function service.playerLoaded(player: Player)
		local st = stateOf(player)
		st.loadedAt = clock()
		player:SetAttribute("RallyStreak", st.rally)
		checkPasses(st)
		checkPolicy(st)
		deliverInbox(player)
	end

	-- Leaving ends the Rally Streak and every session-only state.
	function service.playerRemoving(player: Player)
		states[player] = nil
	end

	---------------------------------------------------------------------------------------------- earning

	-- Pays `base` Gears from `source`. Multiplied sources get the x2 pass, Festival and (ctx.streak) Rally Streak, as
	-- they stand right now. Returns Gears granted and the multiplier used.
	function service.earn(player: Player, source: string, base: number, ctx: { streak: boolean?, txType: string?, sku: string? }?): (number, number)
		local c: { streak: boolean?, txType: string?, sku: string? } = ctx or {}
		if not isWhole(base) or base <= 0 then
			return 0, 1
		end
		local mult = 1
		if cfg.MULTIPLIED_SOURCES[source] then
			local festival = rules.festivalAt(now())
			mult = rules.multiplier({
				x2 = service.isPassActive(player, "x2Gears"),
				festival = if festival then festival.multiplier else nil,
				streak = c.streak,
			})
		end
		local amount = math.floor(base * mult + 0.5)
		local balance = 0
		local ok = save.edit(player, "earn:" .. source, function(draft: any)
			draft.gears += amount
			balance = draft.gears
		end)
		if not ok then
			return 0, mult
		end
		track(player, "Source", amount, balance, c.txType or "Gameplay", c.sku or source)
		return amount, mult
	end

	---------------------------------------------------------------------------------------------- owner admin (D22)
	-- Never on the EconomyRequest remote: server/AdminService calls these after its own UserId check, and each re-checks
	-- isAdmin first, so nothing here can reach another player's save. No receipt, purchase record or product is touched.

	local function adminLog(player: Player, action: string, result: string, detail: string)
		log(string.format("%s action=%s user=%d result=%s %s", AdminRules.LOG, action, player.UserId, result, detail))
	end

	-- A refused admin entry point logs on the kind=admin stream too (a wiring bug that lets another player's request reach
	-- here shows up there), and the reply carries a neutral reason that is never shown as Garage copy.
	local function denied(player: Player, action: string): Reply
		adminLog(player, action, "denied", "notAdmin")
		return { ok = false, reason = "notAdmin" }
	end

	-- Cash to the admin's own wallet through the earn pattern: one SaveService.edit, multiplier 1 ("admin:grant" is not a
	-- multiplied source), economy analytics as a Source labelled "admin". Clamped per call and at the wallet cap.
	function service.adminGrantCash(player: Player, raw: any): Reply
		if not isAdmin(player) then
			return denied(player, "cash")
		end
		local amount, why = AdminRules.clampCash(raw)
		if not amount then
			adminLog(player, "cash", "rejected", tostring(why))
			return { ok = false, reason = why }
		end
		local profile = save.get(player)
		if not profile then
			adminLog(player, "cash", "rejected", "profile not loaded")
			return { ok = false, reason = "profile not loaded" }
		end
		local grant = AdminRules.cashGrant(profile.gears, amount)
		if grant <= 0 then
			adminLog(player, "cash", "noop", string.format("asked=%d gears=%d (wallet cap)", amount, profile.gears))
			return { ok = true, data = { granted = 0, balance = profile.gears } }
		end
		local granted, mult = service.earn(player, "admin:grant", grant, { txType = "Gameplay", sku = "admin" })
		local after = save.get(player)
		local balance = if after then after.gears else 0
		adminLog(player, "cash", if granted > 0 then "granted" else "failed", string.format("asked=%d granted=%d mult=%d gears=%d", amount, granted, mult, balance))
		if granted <= 0 then
			return { ok = false, reason = "save refused" }
		end
		return { ok = true, data = { granted = granted, balance = balance } }
	end

	-- Runtime pass flip for the admin (x2 Cash): an override isPassActive reads first. Never saved, never a receipt; the
	-- verified ownership in st.passes and the profile's passCache stay as the API left them.
	function service.adminSetPass(player: Player, key: any, on: any): Reply
		if not isAdmin(player) then
			return denied(player, "pass")
		end
		-- Only the pass keys the owner put in scope (AdminRules.PASS_KEYS: the 2x Cash pass), and only if it is a real Pass.
		local found = false
		if table.find(AdminRules.passKeys(), key) then
			for _, p in ipairs(passProducts()) do
				if p.key == key then
					found = true
				end
			end
		end
		if not found or type(on) ~= "boolean" then
			adminLog(player, "pass", "rejected", "key=" .. clip(tostring(key)))
			return { ok = false, reason = "unknown pass" }
		end
		local st = stateOf(player)
		local overrides = st.adminPasses or {}
		st.adminPasses = overrides
		overrides[key :: string] = on
		publishPasses(st)
		adminLog(player, "pass", "set", string.format("key=%s on=%s", tostring(key), tostring(on)))
		return { ok = true, data = { key = key, on = on } }
	end

	-- Win Pass counters in the admin's own profile draft (wins, races, premium), clamped. Logged admin; no claim is made.
	function service.adminSetWinPass(player: Player, field: any, raw: any): Reply
		if not isAdmin(player) then
			return denied(player, "winpass")
		end
		local value, why = AdminRules.clampWinPass(field, raw)
		if value == nil then
			adminLog(player, "winpass", "rejected", tostring(why))
			return { ok = false, reason = why }
		end
		local ok = save.edit(player, "admin:winpass:" .. tostring(field), function(draft: any)
			ensureSeason(draft)
			draft.winPass[field] = value
		end)
		adminLog(player, "winpass", if ok then "set" else "failed", string.format("%s=%s", tostring(field), tostring(value)))
		if not ok then
			return { ok = false, reason = "save refused" }
		end
		return { ok = true, data = { field = field, value = value } }
	end

	-- RaceManager calls this once per real finish (not for abandoned races; bots never reach it). Pays the race,
	-- advances the Rally Streak, counts the finish for the Win Pass tiers (racesModes, any place) and a first place in a
	-- countsModes mode into the kept wins counter.
	function service.raceFinished(player: Player, info: RaceInfo): RaceGears?
		if info.simulated and not isStudio() then
			return nil
		end
		local payout = rules.raceGears({ mode = info.mode, rank = info.rank, trackId = info.trackId, laps = info.laps, rings = info.rings, coins = info.coins, repeatWin = info.repeatWin })
		if payout.base <= 0 then
			return nil
		end
		local st = stateOf(player)
		-- The streak advances only with a saved payout (a refused edit pays nothing and counts nothing).
		local rally = st.rally + 1
		local every = cfg.GEARS.rallyStreak.every
		local streakBonus = rally % every == 0 and rules.featureOn("rallyStreak")
		local festival = rules.festivalAt(now())
		local x2 = service.isPassActive(player, "x2Gears")
		local mult = rules.multiplier({ x2 = x2, festival = if festival then festival.multiplier else nil, streak = streakBonus })
		local amount = math.floor(payout.base * mult + 0.5)
		local seasonOpen = rules.seasonAt(now()) ~= nil
		local countsWin = info.rank == 1 and cfg.WIN_PASS.countsModes[info.mode] == true and seasonOpen
		local countsRace = cfg.WIN_PASS.racesModes[info.mode] == true and seasonOpen
		local balance, wins, races = 0, 0, 0
		-- Phase 6: the avatar's own ladder counts the same finishes the Win Pass does (any place) and first places in the
		-- Win Pass countsModes (a solo time trial or boss run is always rank 1 and never a win), season or not; a key read
		-- from the vehicle at spawn, so a pick made after the grid never counts.
		local avatarKey = info.avatarKey
		if avatarKey == nil then
			local attr = player:GetAttribute("AvatarKey")
			avatarKey = if type(attr) == "string" then attr else nil
		end
		local countsAvatar = cfg.WIN_PASS.racesModes[info.mode] == true and avatarKey ~= nil
		local avatarWin = info.rank == 1 and cfg.WIN_PASS.countsModes[info.mode] == true
		local unlocks: { any } = {}
		local ok = save.edit(player, "race:" .. info.mode, function(draft: any)
			draft.gears += amount
			balance = draft.gears
			ensureSeason(draft)
			if countsWin then
				draft.winPass.wins += 1
			end
			if countsRace then
				draft.winPass.races += 1
			end
			wins = draft.winPass.wins
			races = draft.winPass.races
			unlocks = if countsAvatar then AvatarRules.recordRace(draft.avatars, avatarKey, avatarWin) else {}
		end)
		if not ok then
			log(string.format("%sraceFinished user=%d mode=%s not saved (no writable profile)", LOG, player.UserId, info.mode))
			return nil
		end
		if #unlocks > 0 then
			fire(player, "AvatarLadder", { unlocks = unlocks })
		end
		st.rally = rally
		player:SetAttribute("RallyStreak", rally)
		track(player, "Source", amount, balance, "Gameplay", payout.source)
		if streakBonus then
			trackCustom(player, "RallyStreak", st.rally, nil)
		end
		log(string.format(
			"%searn user=%d source=%s rank=%d base=%d mult=%.2f gears=%d x2=%s festival=%s streak=%d winPass=%s races=%d",
			LOG,
			player.UserId,
			payout.source,
			info.rank,
			payout.base,
			mult,
			amount,
			tostring(x2),
			tostring(festival ~= nil),
			st.rally,
			tostring(countsWin),
			races
		))
		return {
			gears = amount,
			base = payout.base,
			multiplier = mult,
			x2 = x2,
			festival = festival ~= nil,
			streakBonus = streakBonus,
			rallyStreak = st.rally,
			winPassWin = countsWin,
			winPassWins = wins,
			winPassRace = countsRace,
			winPassRaces = races,
			parts = payout.parts,
			avatarUnlocks = if #unlocks > 0 then unlocks else nil,
		}
	end

	function service.raceAbandoned(player: Player)
		local st = states[player]
		if st and st.rally > 0 then
			st.rally = 0
			player:SetAttribute("RallyStreak", 0)
		end
	end

	---------------------------------------------------------------------------------------------- shop

	local function currentShop(): EconomyRules.ShopView
		local view = rules.shopAt(now())
		if shop.window ~= view.window then
			shop.window = view.window
			shop.sold = {}
		end
		if shop.day ~= view.day then
			shop.day = view.day
			shop.dealSold = 0
		end
		return view
	end

	local function remaining(slot: EconomyRules.ShopSlot): number?
		if slot.stock == nil then
			return nil
		end
		local sold = if slot.kind == "deal" then shop.dealSold else (shop.sold[slot.slot] or 0)
		return math.max(0, slot.stock - sold)
	end

	function service.getShop(player: Player): Reply
		if not service.garageEnabled() then
			return { ok = false, reason = "disabled" }
		end
		local view = currentShop()
		local profile = save.get(player)
		local owned = if profile then profile.cosmetics.owned else {}
		local slots = {}
		for _, s in ipairs(view.slots) do
			local left = remaining(s)
			table.insert(slots, {
				slot = s.slot,
				kind = s.kind,
				key = s.key,
				price = s.price,
				basePrice = s.basePrice,
				stock = left, -- nil = always in stock
				soldOut = left == 0,
				owned = owned[s.key] == true,
			})
		end
		return {
			ok = true,
			data = { window = view.window, rotation = view.rotation, restockAt = view.endsAt, dealEndsAt = view.dealEndsAt, serverTime = now(), slots = slots },
		}
	end

	function service.buy(player: Player, key: any): Reply
		if not service.garageEnabled() then
			return reject(player, "Buy", "disabled")
		end
		if not isKey(key) then
			return reject(player, "Buy", "badRequest")
		end
		local item = rules.cosmetic(key)
		if not item then
			return reject(player, "Buy", "unknown", key)
		end
		local profile = save.get(player)
		if not profile then
			return reject(player, "Buy", "loading", key)
		end
		if profile.cosmetics.owned[key] then
			return reject(player, "Buy", "owned", key)
		end
		local view = currentShop()
		local best: EconomyRules.ShopSlot? = nil
		local listed = false
		for _, s in ipairs(view.slots) do
			if s.key == key then
				listed = true
				local left = remaining(s)
				if (left == nil or left > 0) and (best == nil or s.price < best.price) then
					best = s
				end
			end
		end
		if not best then
			return reject(player, "Buy", if listed then "soldOut" else "notInShop", key)
		end
		local slot = best :: EconomyRules.ShopSlot
		local price = slot.price
		if price <= 0 then
			return reject(player, "Buy", "notForSale", key)
		end
		if profile.gears < price then
			return reject(player, "Buy", "gears", string.format("%s costs %d, has %d", key, price, profile.gears))
		end
		local balance = 0
		local ok = save.edit(player, "buy:" .. key, function(draft: any)
			-- Re-checked on the draft: the edit is the only write, so this is the authoritative test.
			if draft.cosmetics.owned[key] or draft.gears < price then
				error("state changed", 0)
			end
			draft.gears -= price
			draft.cosmetics.owned[key] = true
			balance = draft.gears
		end)
		if not ok then
			return reject(player, "Buy", "saveRefused", key)
		end
		if slot.kind == "deal" then
			shop.dealSold += 1
		elseif slot.stock ~= nil then
			shop.sold[slot.slot] = (shop.sold[slot.slot] or 0) + 1
		end
		track(player, "Sink", price, balance, "Shop", key)
		log(string.format("%sbuy user=%d key=%s slot=%s price=%d gears=%d", LOG, player.UserId, key, slot.slot, price, balance))
		return { ok = true, data = { key = key, price = price, gears = balance, slot = slot.slot } }
	end

	---------------------------------------------------------------------------------------------- loadout

	function service.equip(player: Player, slot: any, key: any): Reply
		if not service.garageEnabled() then
			return reject(player, "Equip", "disabled")
		end
		if type(slot) ~= "string" or cfg.SLOTS[slot] == nil then
			return reject(player, "Equip", "badSlot", tostring(slot))
		end
		local unequip = key == nil or key == ""
		if not unequip then
			if not isKey(key) then
				return reject(player, "Equip", "badRequest")
			end
			local item = rules.cosmetic(key)
			if not item then
				return reject(player, "Equip", "unknown", key)
			end
			if item.kind ~= cfg.SLOTS[slot] then
				return reject(player, "Equip", "wrongSlot", key .. " -> " .. slot)
			end
			local profile = save.get(player)
			if not profile then
				return reject(player, "Equip", "loading")
			end
			if not profile.cosmetics.owned[key] then
				return reject(player, "Equip", "notOwned", key)
			end
		end
		local ok = save.edit(player, "equip:" .. slot, function(draft: any)
			if unequip then
				draft.cosmetics.loadout[slot] = nil
			elseif draft.cosmetics.owned[key] then
				draft.cosmetics.loadout[slot] = key
			else
				error("not owned", 0)
			end
		end)
		if not ok then
			return reject(player, "Equip", "saveRefused")
		end
		return { ok = true, data = { slot = slot, key = if unequip then nil else key } }
	end

	local function requireGaragePlus(player: Player, action: string): Reply?
		if not service.garageEnabled() then
			return reject(player, action, "disabled")
		end
		if not service.isPassActive(player, "garagePlus") then
			return reject(player, action, "needsGaragePlus")
		end
		return nil
	end

	function service.setFavorite(player: Player, key: any, on: any): Reply
		local refused = requireGaragePlus(player, "SetFavorite")
		if refused then
			return refused
		end
		if not isKey(key) or not rules.cosmetic(key) or type(on) ~= "boolean" then
			return reject(player, "SetFavorite", "badRequest")
		end
		local ok = save.edit(player, "favorite", function(draft: any)
			draft.economy.favorites[key] = if on then true else nil
		end)
		return if ok then { ok = true } else reject(player, "SetFavorite", "saveRefused")
	end

	local PRESET_SLOTS = 3

	function service.savePreset(player: Player, index: any): Reply
		local refused = requireGaragePlus(player, "SavePreset")
		if refused then
			return refused
		end
		if not isWhole(index) or index < 1 or index > PRESET_SLOTS then
			return reject(player, "SavePreset", "badRequest")
		end
		local ok = save.edit(player, "savePreset", function(draft: any)
			draft.economy.presets[tostring(index)] = table.clone(draft.cosmetics.loadout)
		end)
		return if ok then { ok = true } else reject(player, "SavePreset", "saveRefused")
	end

	function service.loadPreset(player: Player, index: any): Reply
		local refused = requireGaragePlus(player, "LoadPreset")
		if refused then
			return refused
		end
		if not isWhole(index) or index < 1 or index > PRESET_SLOTS then
			return reject(player, "LoadPreset", "badRequest")
		end
		local ok = save.edit(player, "loadPreset", function(draft: any)
			local preset = draft.economy.presets[tostring(index)]
			if type(preset) ~= "table" then
				error("empty preset", 0)
			end
			local loadout = {}
			for slot, key in pairs(preset) do
				-- Only what is still owned and still fits its slot comes back.
				local item = rules.cosmetic(key)
				if cfg.SLOTS[slot] and item and item.kind == cfg.SLOTS[slot] and draft.cosmetics.owned[key] then
					loadout[slot] = key
				end
			end
			draft.cosmetics.loadout = loadout
		end)
		return if ok then { ok = true } else reject(player, "LoadPreset", "emptyOrRefused")
	end

	---------------------------------------------------------------------------------------------- daily and Win Pass

	-- viaPopup: the login popup's CLAIM (economy v3 step 7). It is the one path that survives LAUNCH_HIDE, when the Garage DAILY
	-- tab is hidden; the streak, reward and once-per-UTC-day check are the same either way, so the two stay in sync.
	function service.claimDaily(player: Player, viaPopup: boolean?): Reply
		if not service.garageEnabled() then
			return reject(player, "ClaimDaily", "disabled")
		end
		if not rules.featureOn("daily") and viaPopup ~= true then
			return reject(player, "ClaimDaily", "unavailable", "hidden at launch")
		end
		local profile = save.get(player)
		if not profile then
			return reject(player, "ClaimDaily", "loading")
		end
		local t = now()
		local today = rules.utcDay(t)
		local day = rules.dailyStreak(profile.streak.dailyDay, profile.streak.dailyCount, today)
		if not day then
			return reject(player, "ClaimDaily", "claimed")
		end
		local streakDay = day :: number
		local gears = rules.dailyReward(streakDay)
		local trailKey = if streakDay == #cfg.GEARS.daily then cfg.GEARS.dailyTrail else nil
		local labels: { string } = {}
		local balance = 0
		local ok = save.edit(player, "daily", function(draft: any)
			if draft.streak.dailyDay == today then
				error("already claimed", 0)
			end
			draft.gears += gears
			if trailKey and not draft.cosmetics.owned[trailKey] then
				draft.cosmetics.owned[trailKey] = true
				local item = rules.cosmetic(trailKey)
				table.insert(labels, if item then item.name else trailKey)
			end
			draft.streak.dailyDay = today
			draft.streak.dailyCount = streakDay
			draft.streak.lastClaimAt = t
			balance = draft.gears
		end)
		if not ok then
			return reject(player, "ClaimDaily", "saveRefused")
		end
		track(player, "Source", gears, balance, "TimedReward", "daily" .. streakDay)
		trackCustom(player, "DailyStreak", streakDay, nil)
		return { ok = true, data = { day = streakDay, gears = gears, cosmetics = labels, balance = balance } }
	end

	-- The login popup's data (economy v3 step 7). Answers show = true at most once per UTC day: the day is stamped in the same
	-- save edit, so a rejoin, a second server or a repeated request gets show = false. Nothing here claims; the popup's Claim
	-- button calls ClaimLoginDaily. A refused save shows nothing (better a missed popup than a repeated one).
	function service.loginPopup(player: Player): Reply
		if not service.garageEnabled() then
			return { ok = true, data = { show = false } }
		end
		local profile = save.get(player)
		if not profile then
			return { ok = false, reason = "loading" }
		end
		local t = now()
		local today = rules.utcDay(t)
		if not LoginRules.due(profile.streak.loginShownDay, today) then
			return { ok = true, data = { show = false, serverTime = t } }
		end
		local stamped = save.edit(player, "loginShown", function(draft: any)
			if not LoginRules.due(draft.streak.loginShownDay, today) then
				error("already shown", 0)
			end
			draft.streak.loginShownDay = today
		end)
		if not stamped then
			return { ok = true, data = { show = false, serverTime = t } }
		end
		local day = rules.dailyStreak(profile.streak.dailyDay, profile.streak.dailyCount, today)
		local trailKey = if day == #cfg.GEARS.daily then cfg.GEARS.dailyTrail else nil
		local trail = if trailKey then rules.cosmetic(trailKey) else nil
		return {
			ok = true,
			data = {
				show = true,
				serverTime = t,
				claimable = day ~= nil,
				day = day or profile.streak.dailyCount,
				cash = if day then rules.dailyReward(day) else 0,
				trail = if trail and not profile.cosmetics.owned[trailKey :: string] then trail.name else nil,
			},
		}
	end

	function service.claimWinPass(player: Player, tier: any, column: any): Reply
		if not service.garageEnabled() then
			return reject(player, "ClaimWinPass", "disabled")
		end
		if not isWhole(tier) or (column ~= "free" and column ~= "premium") then
			return reject(player, "ClaimWinPass", "badRequest")
		end
		local reward = rules.winPassReward(tier, column)
		if not reward then
			return reject(player, "ClaimWinPass", "noTier", tostring(tier))
		end
		if rules.seasonAt(now()) == nil then
			return reject(player, "ClaimWinPass", "seasonOver")
		end
		local profile = save.get(player)
		if not profile then
			return reject(player, "ClaimWinPass", "loading")
		end
		local tierKey = tostring(tier)
		local failure: string? = nil
		local ok = save.edit(player, "winPass:" .. column .. tierKey, function(draft: any)
			ensureSeason(draft)
			local wp = draft.winPass
			local claimed = if column == "free" then wp.claimedFree else wp.claimedPremium
			if rules.winPassClaimed(claimed, tier) then
				failure = "claimed" -- includes a wins-era claim at the same position, whatever the races count
			elseif wp.races < tier then
				failure = "notEnoughRaces"
			elseif column == "premium" and not wp.premium then
				failure = "needsPremium"
			end
			if failure then
				error(failure, 0)
			end
			claimed[rules.winPassClaimKey(tier)] = true
			draft.cosmetics.owned[reward] = true
		end)
		if not ok then
			return reject(player, "ClaimWinPass", failure or "saveRefused", string.format("tier=%s column=%s", tierKey, column))
		end
		log(string.format("%swinPass claim user=%d tier=%s column=%s reward=%s", LOG, player.UserId, tierKey, column, reward))
		return { ok = true, data = { tier = tier, column = column, key = reward } }
	end

	---------------------------------------------------------------------------------------------- Robux prompts

	local function priceOf(p: Product): number?
		local id = p.id
		if id == nil or not market then
			return nil
		end
		local cached = priceCache[p.key]
		-- A failed lookup is retried soon: caching nil for the full TTL would disable the button for 10 minutes (L50).
		if cached and clock() - cached.at < (if cached.price ~= nil then svcCfg.priceCacheSeconds else svcCfg.priceRetrySeconds) then
			return cached.price
		end
		local ok, price = pcall(market.priceOf, id, p.kind)
		local value = if ok and type(price) == "number" then price else nil
		priceCache[p.key] = { price = value, at = clock() }
		return value
	end

	-- Products a client may show: only with the store enabled, a real id and the row live (LAUNCH_HIDE). Prices from
	-- GetProductInfo, never from defaultPriceLabel.
	local function visibleProducts(): { any }
		local list = {}
		if cfg.Enabled ~= true then
			return list
		end
		for _, p in ipairs(cfg.PRODUCTS) do
			if p.id ~= nil and rules.productLive(p) then
				table.insert(list, { key = p.key, kind = p.kind, label = p.label, price = priceOf(p), giftTwinOf = p.giftTwinOf })
			end
		end
		return list
	end

	-- Shared gate for every prompt: store on, a real id, the row live, a loaded profile, not busy. A hidden row is
	-- refused here only: processReceipt grants any bound product, so nothing already paid for is ever lost.
	local function promptGate(player: Player, action: string, key: any): (Product?, Reply?)
		if not isKey(key) then
			return nil, reject(player, action, "badRequest")
		end
		if cfg.Enabled ~= true then
			return nil, reject(player, action, "disabled", key)
		end
		local live = Economy.liveCheck
		local paused = if live then live() else nil
		if paused then
			return nil, reject(player, action, "disabled", key .. " (live: " .. paused .. ")")
		end
		local p = rules.product(key)
		if not p or p.id == nil then
			return nil, reject(player, action, "unavailable", key)
		end
		if not rules.productLive(p) then
			return nil, reject(player, action, "unavailable", key .. " (hidden at launch)")
		end
		local st = stateOf(player)
		local joinBlock = PromptPolicyRules.joinBlock(clock() - st.joinedAt, svcCfg.joinPromptGraceSeconds)
		if joinBlock then
			return nil, reject(player, action, "busy", joinBlock)
		end
		local busy = isBusy(player)
		if busy then
			return nil, reject(player, action, "busy", busy)
		end
		if not save.get(player) then
			return nil, reject(player, action, "loading", key)
		end
		return p, nil
	end

	local function sanitizeChoices(choices: any): { string }?
		if type(choices) ~= "table" then
			return nil
		end
		local out = {}
		for i = 1, math.min(#choices, 6) do
			if isKey(choices[i]) and rules.cosmetic(choices[i]) then
				table.insert(out, choices[i])
			end
		end
		return out
	end

	-- Would this product give `profile` anything new? Packs always do (duplicates pay Gears); these do not when owned.
	local function alreadyHas(profile: any, base: Product): boolean
		local g = base.grants
		if base.oncePerAccount and profile.economy.oneTime[base.key] then
			return true
		end
		if g.winPassPremium then
			local season = rules.seasonAt(now())
			return season == nil or season.id ~= g.winPassPremium or (profile.winPass.season == season.id and profile.winPass.premium)
		end
		if g.chooseFromSet then
			for _, key in ipairs(rules.setLiveries(g.chooseFromSet)) do
				if not profile.cosmetics.owned[key] then
					return false
				end
			end
			return true
		end
		if g.cosmetics and not g.gears and #g.cosmetics == 1 then
			return profile.cosmetics.owned[g.cosmetics[1]] == true
		end
		return false
	end

	-- Tells two prompts in the same second apart, so a receipt only clears the intent it read (L58).
	local intentSeq = 0
	local function nextNonce(): string
		intentSeq += 1
		return string.format("%s:%d", game.JobId, intentSeq)
	end

	local function doPrompt(player: Player, p: Product, intent: any): Reply
		local id = p.id :: number
		if not market then
			return reject(player, "Prompt", "unavailable", p.key)
		end
		if intent then
			-- Read back by ProcessReceipt (possibly on another server after a rejoin), so it is saved, not session state.
			local ok = save.edit(player, "intent:" .. p.key, function(draft: any)
				draft.economy.intents[p.key] = intent
			end)
			if not ok then
				return reject(player, "Prompt", "saveRefused", p.key)
			end
		end
		local ok, err = pcall(if p.kind == "Pass" then market.promptPass else market.promptProduct, player, id)
		if not ok then
			return reject(player, "Prompt", "promptFailed", tostring(err))
		end
		trackCustom(player, "PromptOpened", 1, p.key)
		log(string.format("%sprompt user=%d key=%s", LOG, player.UserId, p.key))
		return { ok = true }
	end

	function service.promptProduct(player: Player, key: any, choices: any?): Reply
		local p, refused = promptGate(player, "PromptProduct", key)
		if refused then
			return refused
		end
		local product = p :: Product
		if product.giftTwinOf then
			return reject(player, "PromptProduct", "useGift", product.key)
		end
		if product.kind == "Pass" then
			if service.isPassActive(player, product.key) then
				return reject(player, "PromptProduct", "owned", product.key)
			end
			return doPrompt(player, product, nil)
		end
		local profile = save.get(player)
		if alreadyHas(profile, product) then
			return reject(player, "PromptProduct", "owned", product.key)
		end
		local picks = if product.grants.chooseFromSet then sanitizeChoices(choices) else nil
		return doPrompt(player, product, { choices = picks, at = now(), nonce = nextNonce() })
	end

	-- Gift twin of `key` (or the twin key itself) to a racer in this server.
	function service.gift(player: Player, key: any, recipientUserId: any, choices: any?): Reply
		if not isKey(key) then
			return reject(player, "Gift", "badRequest")
		end
		local twin = rules.giftTwin(key)
		if not twin then
			local direct = rules.product(key)
			twin = if direct and direct.giftTwinOf then direct else nil
		end
		if not twin then
			return reject(player, "Gift", "notGiftable", key)
		end
		local p, refused = promptGate(player, "Gift", twin.key)
		if refused then
			return refused
		end
		if not isWhole(recipientUserId) or recipientUserId == player.UserId then
			return reject(player, "Gift", "badRecipient", tostring(recipientUserId))
		end
		local recipient = playerByUserId(recipientUserId)
		local theirs = if recipient then save.get(recipient) else nil
		if not recipient or not theirs then
			return reject(player, "Gift", "recipientNotHere", tostring(recipientUserId))
		end
		local base = rules.baseProduct(p :: Product)
		if alreadyHas(theirs, base) then
			return reject(player, "Gift", "recipientOwns", base.key)
		end
		local picks = if base.grants.chooseFromSet then sanitizeChoices(choices) else nil
		return doPrompt(player, p :: Product, { to = recipientUserId, choices = picks, at = now(), nonce = nextNonce() })
	end

	function service.onPassPurchaseFinished(player: Player, passId: number, purchased: boolean)
		local p = rules.productById(passId)
		if not p or p.kind ~= "Pass" then
			return
		end
		trackCustom(player, if purchased then "PromptCompleted" else "PromptClosed", 1, p.key)
		if not purchased then
			return
		end
		-- The client's word is not enough: ask the API before the multiplier applies (from the next reward on).
		local owns = verifyPass(player, p)
		local st = stateOf(player)
		if owns then
			setPass(st, p, true)
			publishPasses(st)
			fire(player, "Toast", { kind = "Pass", text = p.label .. " is active" })
			log(string.format("%spass verified user=%d pass=%s", LOG, player.UserId, p.key))
		else
			log(string.format("%spass purchase not verified user=%d pass=%s result=%s", LOG, player.UserId, p.key, tostring(owns)))
		end
	end

	---------------------------------------------------------------------------------------------- receipts

	-- Gift grant to the recipient: live when they are loaded on this server, else into their PendingGifts inbox.
	local function deliverGift(recipientId: number, base: Product, choices: any, purchaseId: string, buyer: Player): boolean
		local recipient = playerByUserId(recipientId)
		local theirs = if recipient then save.get(recipient) else nil
		if recipient and theirs then
			if not theirs.pendingGifts[purchaseId] then
				local labels: { string } = {}
				local stamp = now()
				local ok = save.edit(recipient, "gift:" .. base.key, function(draft: any)
					applyGrants(draft, base, choices, labels)
					draft.pendingGifts[purchaseId] = { key = base.key, from = buyer.UserId, at = stamp }
					prune(draft.pendingGifts, svcCfg.receiptsKept)
				end)
				if not ok or not save.flush(recipient, svcCfg.receiptFlushTimeout) then
					return false
				end
				fire(recipient, "Toast", { kind = "Gift", text = string.format("%s sent you %s", buyer.Name, base.label) })
				log(string.format("%sgift delivered user=%d purchase=%s key=%s from=%d (live)", LOG, recipientId, purchaseId, base.key, buyer.UserId))
			end
			return true
		end
		local ok, err = giftStore.update(giftKey(recipientId), function(old: any): any
			local box = if type(old) == "table" then old else {}
			if box[purchaseId] then
				return nil -- already in the inbox (receipt retried)
			end
			box[purchaseId] = { key = base.key, from = buyer.UserId, fromName = buyer.Name, choices = choices, at = now() }
			return box
		end, { recipientId })
		if not ok then
			log(string.format("%sgift inbox write failed to=%d purchase=%s: %s", LOG, recipientId, purchaseId, tostring(err)))
			return false
		end
		log(string.format("%sgift queued to=%d purchase=%s key=%s from=%d (PendingGifts)", LOG, recipientId, purchaseId, base.key, buyer.UserId))
		return true
	end

	local function processOnce(receipt: any, purchaseId: string): boolean
		local productId = tonumber(receipt.ProductId) or -1
		local product = rules.productById(productId)
		if not product or product.kind ~= "DevProduct" then
			log(string.format("%sreceipt %s names unknown product %s; not processed", LOG, purchaseId, tostring(receipt.ProductId)))
			return false
		end
		local buyer = playerByUserId(tonumber(receipt.PlayerId) or 0)
		local profile = if buyer then save.get(buyer) else nil
		if not buyer or not profile then
			log(string.format("%sreceipt %s buyer %s not loaded here; not processed yet", LOG, purchaseId, tostring(receipt.PlayerId)))
			return false
		end
		local okRead, entry = readStore(purchaseStore, purchaseId)
		if not okRead then
			log(string.format("%sreceipt %s ledger read failed: %s", LOG, purchaseId, tostring(entry)))
			return false
		end
		if type(entry) == "table" and entry.granted then
			log(string.format("%sreceipt %s already granted (ledger, server %s); duplicate ignored", LOG, purchaseId, tostring(entry.server)))
			return true
		end
		local labels: { string } = {}
		if not profile.economy.receipts[purchaseId] then
			local base = rules.baseProduct(product)
			local intent = profile.economy.intents[product.key]
			-- Only this intent is cleared below: a newer prompt made while the receipt waits must survive it (L58).
			local function clearIntent(draft: any)
				if rules.sameIntent(intent, draft.economy.intents[product.key]) then
					draft.economy.intents[product.key] = nil
				end
			end
			local choices = if type(intent) == "table" then intent.choices else nil
			local recipientId = if product.giftTwinOf and type(intent) == "table" then tonumber(intent.to) else nil
			local stamp = now()
			local ok: boolean
			if recipientId and recipientId ~= buyer.UserId then
				if not deliverGift(recipientId, base, choices, purchaseId, buyer) then
					return false
				end
				ok = save.edit(buyer, "receipt:" .. product.key, function(draft: any)
					draft.economy.receipts[purchaseId] = { at = stamp, ledger = false, key = product.key, to = recipientId }
					clearIntent(draft)
				end)
				table.insert(labels, string.format("gift sent (%s)", base.label))
			else
				if product.giftTwinOf then
					log(string.format("%sreceipt %s gift with no recipient; granted to the buyer", LOG, purchaseId))
				end
				ok = save.edit(buyer, "receipt:" .. product.key, function(draft: any)
					-- The prompt gate refuses a second Rookie Pack, but PromptProductPurchase is callable from a client,
					-- so the receipt checks the flag itself, atomically with the grant (L51, L57).
					local repeatGears = rules.repeatOnceGears(base, draft.economy.oneTime)
					local marker: any = { at = stamp, ledger = false, key = product.key }
					if repeatGears then
						draft.gears += repeatGears
						marker.repeatGears = repeatGears
						table.clear(labels)
						table.insert(labels, string.format("%d Cash (%s already claimed)", repeatGears, base.label))
					else
						applyGrants(draft, base, choices, labels)
					end
					draft.economy.receipts[purchaseId] = marker
					clearIntent(draft)
				end)
			end
			if not ok then
				return false
			end
		end
		-- PurchaseGranted only after the grant (or the marker of an earlier one) is durably saved.
		if not save.flush(buyer, svcCfg.receiptFlushTimeout) then
			log(string.format("%sreceipt %s grant not saved yet user=%d; not processed yet", LOG, purchaseId, buyer.UserId))
			return false
		end
		local okWrite, err = purchaseStore.update(purchaseId, function(old: any): any
			if type(old) == "table" and old.granted then
				return nil
			end
			return { granted = true, userId = buyer.UserId, productId = productId, key = product.key, at = now(), server = game.JobId }
		end, { buyer.UserId })
		if not okWrite then
			-- The profile marker stops a regrant when Roblox retries; only the ledger write is repeated.
			log(string.format("%sreceipt %s ledger write failed: %s; not processed yet", LOG, purchaseId, tostring(err)))
			return false
		end
		save.edit(buyer, "ledger", function(draft: any)
			local r = draft.economy.receipts[purchaseId]
			if type(r) == "table" then
				r.ledger = true
			end
			prune(draft.economy.receipts, svcCfg.receiptsKept, function(e: any): boolean
				return e.ledger == true
			end)
		end)
		local balance = (save.get(buyer) or profile).gears
		-- What the receipt really paid: a repeat oncePerAccount buy recorded its Gears on the receipt entry.
		local landed = (save.get(buyer) or profile).economy.receipts[purchaseId]
		local gearsGranted = if type(landed) == "table" and type(landed.repeatGears) == "number"
			then landed.repeatGears
			else rules.baseProduct(product).grants.gears or 0
		track(buyer, "Source", gearsGranted, balance, "IAP", product.key)
		trackCustom(buyer, "PromptCompleted", 1, product.key)
		log(string.format("%sreceipt %s granted user=%d key=%s", LOG, purchaseId, buyer.UserId, product.key))
		delivered(buyer, if #labels > 0 then labels else { product.label })
		return true
	end

	function service.processReceipt(receipt: any): any
		local purchaseId = tostring(receipt and receipt.PurchaseId)
		if inFlight[purchaseId] then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		inFlight[purchaseId] = true
		local ok, granted = pcall(processOnce, receipt, purchaseId)
		inFlight[purchaseId] = nil
		if not ok then
			log(string.format("%sreceipt %s error: %s", LOG, purchaseId, tostring(granted)))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return if granted then Enum.ProductPurchaseDecision.PurchaseGranted else Enum.ProductPurchaseDecision.NotProcessedYet
	end

	---------------------------------------------------------------------------------------------- client state

	function service.getState(player: Player): Reply
		if not service.garageEnabled() then
			return { ok = true, data = { enabled = false } }
		end
		local profile = save.get(player)
		if not profile then
			return { ok = false, reason = "loading" }
		end
		local t = now()
		local st = stateOf(player)
		local today = rules.utcDay(t)
		local nextDay = rules.dailyStreak(profile.streak.dailyDay, profile.streak.dailyCount, today)
		local season = rules.seasonAt(t)
		local wp = profile.winPass
		local sameSeason = season ~= nil and wp.season == season.id
		local owned = {}
		for key in pairs(profile.cosmetics.owned) do
			table.insert(owned, key)
		end
		table.sort(owned)
		local passes = activePassList(st)
		local festival = rules.festivalAt(t)
		local cup = rules.stormCupNext(t)
		return {
			ok = true,
			data = {
				enabled = true,
				storeEnabled = cfg.Enabled == true,
				serverTime = t,
				gears = profile.gears,
				owned = owned,
				loadout = table.clone(profile.cosmetics.loadout),
				favorites = table.clone(profile.economy.favorites),
				passes = passes,
				-- What LAUNCH_HIDE leaves on; the Garage hides the rest (its DAILY tab follows GarageModel.TABS).
				features = {
					shopRotation = rules.featureOn("shopRotation"),
					rallyStreak = rules.featureOn("rallyStreak"),
					festival = rules.featureOn("festival"),
					daily = rules.featureOn("daily"),
				},
				rallyStreak = if rules.featureOn("rallyStreak") then st.rally else 0,
				daily = {
					claimedToday = nextDay == nil,
					streak = profile.streak.dailyCount,
					nextDay = nextDay,
					nextReward = if nextDay then rules.dailyReward(nextDay) else nil,
					resetsAt = (today + 1) * 86400,
				},
				winPass = {
					season = if season then season.id else nil,
					seasonEndsAt = if season then season.endUtc else nil,
					wins = if sameSeason then wp.wins else 0,
					races = if sameSeason then wp.races else 0, -- the tiers' progress
					premium = sameSeason and wp.premium,
					-- Keyed by the current tiers ("5"), wins-era claims folded in (EconomyRules.winPassClaimedView).
					claimedFree = if sameSeason then rules.winPassClaimedView(wp.claimedFree) else {},
					claimedPremium = if sameSeason then rules.winPassClaimedView(wp.claimedPremium) else {},
					tiers = cfg.WIN_PASS.tiers,
				},
				festival = festival,
				nextFestival = rules.festivalNext(t),
				stormCup = cup,
				products = visibleProducts(),
			},
		}
	end

	---------------------------------------------------------------------------------------------- avatars (phase 6)

	local function launchHide(): boolean
		return cfg.LAUNCH_HIDE == true
	end

	-- The picker rows for both classes, plus the picks. Not gated on the Garage switch: the pre-race pick works with the
	-- store off (selection is not monetization); buying is.
	function service.getAvatars(player: Player): Reply
		if not AvatarRules.config.ENABLED then
			return { ok = false, reason = "disabled" }
		end
		local profile = save.get(player)
		if not profile then
			return { ok = false, reason = "loading" }
		end
		local classes = {}
		local avatars = AvatarSelect.effective(player, profile.avatars) -- D22a: the saved table unless his switch is on
		for _, class in ipairs(AvatarRules.config.CLASSES) do
			if AvatarRules.isClass(class) then
				classes[class] = AvatarRules.view(avatars, class, profile.gears, launchHide())
			end
		end
		return {
			ok = true,
			data = {
				gears = profile.gears,
				selected = table.clone(avatars.selected),
				classes = classes,
				storeEnabled = service.garageEnabled(),
			},
		}
	end

	function service.buyAvatar(player: Player, key: any): Reply
		if not service.garageEnabled() or not AvatarRules.config.ENABLED then
			return reject(player, "BuyAvatar", "disabled")
		end
		if not isKey(key) then
			return reject(player, "BuyAvatar", "badRequest")
		end
		local profile = save.get(player)
		if not profile then
			return reject(player, "BuyAvatar", "loading", key)
		end
		local can, why, price = AvatarRules.canBuy(profile.avatars, key, profile.gears, launchHide())
		if not can then
			return reject(player, "BuyAvatar", why or "refused", if price then string.format("%s costs %d, has %d", key, price, profile.gears) else key)
		end
		local balance = 0
		local ok = save.edit(player, "buyAvatar:" .. key, function(draft: any)
			-- Re-checked on the draft (AvatarRules.buy errors): the edit is the only write.
			balance = AvatarRules.buy(draft, key, launchHide())
		end)
		if not ok then
			return reject(player, "BuyAvatar", "saveRefused", key)
		end
		track(player, "Sink", price :: number, balance, "Shop", key)
		log(string.format("%sbuyAvatar user=%d key=%s price=%d gears=%d", LOG, player.UserId, key, price :: number, balance))
		local row = AvatarRules.row(key)
		return { ok = true, data = { key = key, name = if row then row.name else key, class = if row then row.class else nil, price = price, gears = balance } }
	end

	-- The pick for the avatar's class; it applies on the next spawn (race grid, or the hub after a race).
	function service.selectAvatar(player: Player, key: any): Reply
		if not AvatarRules.config.ENABLED then
			return reject(player, "SelectAvatar", "disabled")
		end
		if not isKey(key) then
			return reject(player, "SelectAvatar", "badRequest")
		end
		local profile = save.get(player)
		if not profile then
			return reject(player, "SelectAvatar", "loading", key)
		end
		local can, why = AvatarRules.canSelect(AvatarSelect.effective(player, profile.avatars), key)
		if not can then
			return reject(player, "SelectAvatar", why or "refused", key)
		end
		local row = AvatarRules.row(key) :: any
		-- D22a: a pick his save does not own (the admin switch) stays in server memory; nothing is written.
		if AvatarSelect.runtimePick(player, profile.avatars, key) then
			return { ok = true, data = { key = key, class = row.class, runtime = true } }
		end
		if profile.avatars.selected[row.class] == key then
			return { ok = true, data = { key = key, class = row.class } }
		end
		local ok = save.edit(player, "selectAvatar:" .. row.class, function(draft: any)
			local okDraft, whyDraft = AvatarRules.canSelect(draft.avatars, key)
			if not okDraft then
				error(whyDraft or "refused", 0)
			end
			draft.avatars.selected[row.class] = key
		end)
		if not ok then
			return reject(player, "SelectAvatar", "saveRefused", key)
		end
		return { ok = true, data = { key = key, class = row.class } }
	end

	-- Wear an unlocked reskin / tint step on an owned avatar ("" = the base look).
	function service.wearSkin(player: Player, key: any, stepId: any): Reply
		if not AvatarRules.config.ENABLED then
			return reject(player, "WearSkin", "disabled")
		end
		if not isKey(key) or not (stepId == nil or stepId == "" or isKey(stepId)) then
			return reject(player, "WearSkin", "badRequest")
		end
		local profile = save.get(player)
		if not profile then
			return reject(player, "WearSkin", "loading", key)
		end
		local can, why = AvatarRules.canWear(profile.avatars, key, stepId)
		if not can then
			return reject(player, "WearSkin", why or "refused", key .. ":" .. tostring(stepId))
		end
		local off = stepId == nil or stepId == ""
		local ok = save.edit(player, "wearSkin", function(draft: any)
			local okDraft, whyDraft = AvatarRules.canWear(draft.avatars, key, stepId)
			if not okDraft then
				error(whyDraft or "refused", 0)
			end
			draft.avatars.skin[key] = if off then nil else stepId
		end)
		if not ok then
			return reject(player, "WearSkin", "saveRefused", key)
		end
		return { ok = true, data = { key = key, step = if off then nil else stepId } }
	end

	-- KeyPickup calls this after a NEW key saved: one key on the ladder of the avatar being driven.
	function service.avatarKeyFound(player: Player)
		local attr = player:GetAttribute("AvatarKey")
		if type(attr) ~= "string" then
			return
		end
		local unlocks: { any } = {}
		local ok = save.edit(player, "avatarKey", function(draft: any)
			unlocks = AvatarRules.recordKey(draft.avatars, attr)
		end)
		if ok and #unlocks > 0 then
			fire(player, "AvatarLadder", { unlocks = unlocks })
		end
	end

	---------------------------------------------------------------------------------------------- remote API

	local ACTIONS: { [string]: (Player, ...any) -> Reply } = {
		GetState = function(player: Player): Reply
			return service.getState(player)
		end,
		GetShop = function(player: Player): Reply
			return service.getShop(player)
		end,
		Buy = function(player: Player, key: any): Reply
			return service.buy(player, key)
		end,
		Equip = function(player: Player, slot: any, key: any): Reply
			return service.equip(player, slot, key)
		end,
		ClaimDaily = function(player: Player): Reply
			return service.claimDaily(player)
		end,
		GetLogin = function(player: Player): Reply
			return service.loginPopup(player)
		end,
		ClaimLoginDaily = function(player: Player): Reply
			return service.claimDaily(player, true)
		end,
		ClaimWinPass = function(player: Player, tier: any, column: any): Reply
			return service.claimWinPass(player, tier, column)
		end,
		PromptProduct = function(player: Player, key: any, choices: any): Reply
			return service.promptProduct(player, key, choices)
		end,
		Gift = function(player: Player, key: any, recipientUserId: any, choices: any): Reply
			return service.gift(player, key, recipientUserId, choices)
		end,
		SetFavorite = function(player: Player, key: any, on: any): Reply
			return service.setFavorite(player, key, on)
		end,
		SavePreset = function(player: Player, index: any): Reply
			return service.savePreset(player, index)
		end,
		LoadPreset = function(player: Player, index: any): Reply
			return service.loadPreset(player, index)
		end,
		GetAvatars = function(player: Player): Reply
			return service.getAvatars(player)
		end,
		BuyAvatar = function(player: Player, key: any): Reply
			return service.buyAvatar(player, key)
		end,
		SelectAvatar = function(player: Player, key: any): Reply
			return service.selectAvatar(player, key)
		end,
		WearSkin = function(player: Player, key: any, stepId: any): Reply
			return service.wearSkin(player, key, stepId)
		end,
	}

	-- EconomyRequest:InvokeServer(action, ...) -> Reply. Token bucket per player; unknown actions and bad arguments
	-- are rejected and logged. Handlers never trust anything but the action's own arguments.
	function service.handleRequest(player: Player, action: any, ...: any): Reply
		local st = stateOf(player)
		local t = clock()
		st.bucket = math.min(svcCfg.requestBurst, st.bucket + (t - st.bucketAt) * svcCfg.requestRefillPerSecond)
		st.bucketAt = t
		if st.bucket < 1 then
			-- A flood logs once per throttled streak, not once per request.
			if st.limitedLogged then
				return { ok = false, reason = "rateLimited" }
			end
			st.limitedLogged = true
			return reject(player, tostring(action), "rateLimited")
		end
		st.bucket -= 1
		st.limitedLogged = false
		local handler = if type(action) == "string" then ACTIONS[action] else nil
		if not handler then
			return reject(player, tostring(action), "unknownAction")
		end
		local ok, reply = pcall(handler, player, ...)
		if not ok then
			return reject(player, action, "error", tostring(reply))
		end
		return reply
	end

	return service
end

------------------------------------------------------------------------------------------------ live wiring

local defaultService: Service? = nil

-- Prompts wait while the player races: during the grid countdown (boss intros play inside it) and until their own
-- finish in any non-hub mode. The results screen (RaceFinished) is a valid Garage moment. A map switch (curtain, then
-- straight into the countdown) and a due Storm Cup (the hub is pulled into a race within the StormCup tick) also
-- wait, since a prompt opened then would still be on screen at the grid.
-- Per group (systems audit v32 T1-7) the race half is this player's own race (RaceAttr.get on his instance root):
-- no prompt in his countdown, boss intro or race while the hub's workspace values say "hub", and none while his instance
-- loads (an arch lobby queue does not block). On the single-race path RaceAttr.get is workspace:GetAttribute.
local function liveBusy(player: Player): string?
	return PromptPolicyRules.sceneBlock(PromptPolicyRules.sceneState({
		perGroup = RaceFlowRules.PER_GROUP,
		world = function(name: string): any
			return workspace:GetAttribute(name)
		end,
		race = function(name: string): any
			return RaceAttr.get(name, player)
		end,
		player = function(name: string): any
			return player:GetAttribute(name)
		end,
		instanceState = function(): any
			local root = RaceAttr.rootOf(player)
			return if root then root:GetAttribute("State") else nil
		end,
		now = function(): number
			return workspace:GetServerTimeNow()
		end,
	}))
end

Economy.liveBusy = liveBusy

local function liveMarket(): Market
	local MarketplaceService = game:GetService("MarketplaceService")
	return {
		ownsPass = function(userId: number, passId: number): boolean
			return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
		end,
		promptPass = function(player: Player, passId: number)
			MarketplaceService:PromptGamePassPurchase(player, passId)
		end,
		promptProduct = function(player: Player, productId: number)
			MarketplaceService:PromptProductPurchase(player, productId)
		end,
		priceOf = function(id: number, kind: string): number?
			local info = MarketplaceService:GetProductInfo(id, if kind == "Pass" then Enum.InfoType.GamePass else Enum.InfoType.Product)
			return info and info.PriceInRobux
		end,
	}
end

-- T1-5: the telemetry kill switch (server/LiveOps; fail open when it is not up).
local function telemetryOn(): boolean
	local ok, on = pcall(function(): boolean
		return (require(script.Parent.LiveOps) :: any).isOn("telemetry")
	end)
	return not ok or on ~= false
end

local function liveAnalytics(): Analytics
	local AnalyticsService = game:GetService("AnalyticsService")
	return {
		economy = function(player: Player, flow: string, amount: number, balance: number, txType: string, sku: string)
			if not telemetryOn() then
				return
			end
			local flowType = if flow == "Sink" then Enum.AnalyticsEconomyFlowType.Sink else Enum.AnalyticsEconomyFlowType.Source
			local tx = (Enum.AnalyticsEconomyTransactionType :: any)[txType]
			-- Roblox order: (player, flowType, currencyType, amount, endingBalance, transactionType, itemSku[, customFields]).
			AnalyticsService:LogEconomyEvent(player, flowType, MonetizationConfig.CURRENCY, amount, balance, if tx then tx.Name else txType, sku)
		end,
		custom = function(player: Player, name: string, value: number, sku: string?)
			if not telemetryOn() then
				return
			end
			AnalyticsService:LogCustomEvent(player, name, value, if sku then { [Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = sku } else nil)
		end,
	}
end

local function remotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyRemotes")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "SkyRallyRemotes"
		f.Parent = ReplicatedStorage
		folder = f
	end
	return folder :: Folder
end

local function ensure(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

-- Wires the live service: remotes, SaveService.onLoaded, ProcessReceipt, pass purchases. Call once from the server
-- entry script after SaveService.init().
function Economy.init(): Service
	local existing = defaultService
	if existing then
		return existing
	end
	local MarketplaceService = game:GetService("MarketplaceService")
	local PolicyService = game:GetService("PolicyService")
	local saveService = SaveService.service()
	-- Studio without DataStore access runs on memory stores, like the profile store.
	local mock = saveService.backend == "mock"
	local folder = remotesFolder()
	local event = ensure(folder, "RemoteEvent", "EconomyEvent") :: RemoteEvent
	local request = ensure(folder, "RemoteFunction", "EconomyRequest") :: RemoteFunction
	local svc = Economy.new({
		save = saveService :: any,
		-- TG-6: real UTC in a live server; in Studio workspace.QAUtcAt moves the clock (server/QAClock).
		now = (require(script.Parent.QAClock) :: any).nowSeconds,
		purchaseStore = if mock then SaveService.newMemoryStore() else SaveService.newDataStoreStore(MonetizationConfig.SERVICE.purchaseStoreName),
		giftStore = if mock then SaveService.newMemoryStore() else SaveService.newDataStoreStore(MonetizationConfig.SERVICE.giftStoreName),
		market = liveMarket(),
		policy = function(player: Player): any
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end,
		analytics = liveAnalytics(),
		isBusy = liveBusy,
		garageQA = function(): boolean
			return workspace:GetAttribute("EconomyQA") == true
		end,
		fire = function(player: Player, kind: string, payload: any)
			event:FireClient(player, kind, payload)
		end,
	})
	defaultService = svc
	SaveService.onLoaded(svc.playerLoaded)
	Players.PlayerAdded:Connect(svc.playerAdded)
	Players.PlayerRemoving:Connect(svc.playerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		svc.playerAdded(player)
	end
	MarketplaceService.ProcessReceipt = svc.processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		svc.onPassPurchaseFinished(player, passId, purchased)
	end)
	request.OnServerInvoke = function(player: Player, action: any, ...: any): any
		return svc.handleRequest(player, action, ...)
	end
	workspace:SetAttribute("GarageEnabled", svc.garageEnabled())
	workspace:SetAttribute("StoreEnabled", MonetizationConfig.Enabled == true)
	-- Studio QA can flip EconomyQA after boot; the Garage UI reads GarageEnabled, so keep it in step.
	workspace:GetAttributeChangedSignal("EconomyQA"):Connect(function()
		workspace:SetAttribute("GarageEnabled", svc.garageEnabled())
	end)
	print(string.format("%sinit enabled=%s garage=%s backend=%s", LOG, tostring(MonetizationConfig.Enabled), tostring(svc.garageEnabled()), saveService.backend))
	-- Robux ids from the owner's universe: passes from StorePassIds now, developer products by name in the background.
	-- Hidden rows (LAUNCH_HIDE) are held server-side only, for their receipts; the prompt gate refuses them.
	StoreBinder.start(svc.bindId, MonetizationConfig.PRODUCTS, svc.rules.productLive)
	return svc
end

function Economy.service(): Service?
	return defaultService
end

-- RaceManager.economy hooks (set by the server entry script; nil-safe before init).
function Economy.raceFinished(player: Player, info: RaceInfo): RaceGears?
	local svc = defaultService
	return if svc then svc.raceFinished(player, info) else nil
end

function Economy.raceAbandoned(player: Player)
	local svc = defaultService
	if svc then
		svc.raceAbandoned(player)
	end
end

return Economy
