--!strict
-- Binds the Robux catalog to the owner's own universe at server start (docs/STORE_PRODUCTS_TO_CREATE.md; TEST_LIST_LAUNCH
-- L50-L51). MonetizationConfig keeps every id nil; this is the only writer, through Economy's bindIds.
-- * Passes: StorePassIds.PASS_IDS (owner-pasted, republish to change), bound once at start.
-- * Developer products: MarketplaceService:GetDeveloperProductsAsync() lists every page; StoreBinding matches rows by
--   exact name; each match is verified once with GetProductInfo(id, Enum.InfoType.Product) (ProductId first, then
--   DeveloperProductId if that fails), and must come back with the same name, before it binds. While any developer product is unbound the listing is retried
--   every RETRY_SECONDS, up to ATTEMPTS rounds, so a product the owner creates shortly after a server starts still
--   binds there without a republish. After those rounds (T2-4) it keeps listing every SLOW_RETRY_SECONDS for as long
--   as the server lives, so a product created hours later binds on long-running servers too (one list call per
--   5 minutes per server; the round line then logs only when a slow round binds something or every SLOW_LOG_EVERY).
-- * Logs: one "[SkyRally][Store] bound <key> -> <id> (<price> R$)" line per bound product, plus ONE summary line per
--   retry round ("round N/M: B bound, U of D developer products unbound [keys]"; never a line per unbound product),
--   plus a warning for an ambiguous name. Bound ids are mirrored to clients as attributes on
--   ReplicatedStorage.SkyRallyStore (key = id) so an open Garage refreshes as soon as one binds.
-- * LAUNCH_HIDE (MonetizationConfig): a row that is not live is not bound for sale. When the owner's universe lists it
--   anyway it is held server-side only ("held <key> -> <id> (hidden at launch)"): bound so a paid receipt for it is
--   still granted and an owned pass keeps working, never mirrored to clients, and Economy's prompt gate refuses it.
--   Hidden rows never keep the binder retrying; the round line counts them apart ("H hidden at launch").
-- Every Roblox call is injected so tools/tests/store_binding_spec.luau runs it under Lune.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StoreBinding = require(Shared:WaitForChild("StoreBinding"))

local StoreBinder = {}

local LOG = "[SkyRally][Store] "
StoreBinder.ATTEMPTS = 10
StoreBinder.RETRY_SECONDS = 60
StoreBinder.SLOW_RETRY_SECONDS = 300 -- T2-4: after ATTEMPTS fast rounds; 0 stops after the fast rounds
StoreBinder.SLOW_LOG_EVERY = 12 -- a quiet slow round logs once an hour

export type Options = {
	products: { any }, -- MonetizationConfig.PRODUCTS rows (read only)
	passIds: { [string]: any }, -- StorePassIds.PASS_IDS
	list: () -> { any }, -- every listed developer product (all pages); may error
	verify: (id: number) -> any, -- GetProductInfo(id, Product); may error
	bind: (key: string, id: number) -> (boolean, string?), -- Economy.bindIds for one row
	isLive: ((product: any) -> boolean)?, -- EconomyRules.productLive; nil = every row live
	publish: ((key: string, id: number) -> ())?, -- client mirror
	sleep: (number) -> (),
	log: (string) -> (),
	warn: ((string) -> ())?,
	attempts: number?,
	retrySeconds: number?,
	slowRetrySeconds: number?, -- default SLOW_RETRY_SECONDS
	slowRounds: number?, -- cap on slow rounds (specs); nil = while the server lives
}

-- Runs to completion (yields between rounds); call it in its own task. Returns key -> bound id.
function StoreBinder.run(o: Options): { [string]: number }
	local warnFn = o.warn or o.log
	local bound: { [string]: number } = {}
	local live: { [string]: boolean } = {}
	for _, p in ipairs(o.products) do
		live[p.key] = o.isLive == nil or o.isLive(p) == true
	end
	local function commit(key: string, id: number, price: any)
		local ok, why = o.bind(key, id)
		if not ok then
			warnFn(string.format("%snot bound %s -> %d: %s", LOG, key, id, tostring(why)))
			return
		end
		bound[key] = id
		if not live[key] then
			-- Receipts only: no client mirror, so no Garage ever lists it.
			o.log(string.format("%sheld %s -> %d (hidden at launch)", LOG, key, id))
			return
		end
		if o.publish then
			o.publish(key, id)
		end
		o.log(string.format("%sbound %s -> %d (%s R$)", LOG, key, id, if type(price) == "number" then tostring(price) else "?"))
	end

	for key, id in pairs(StoreBinding.passIds(o.products, o.passIds)) do
		commit(key, id, nil)
	end

	local dev = 0
	for _, p in ipairs(o.products) do
		if p.kind == "DevProduct" then
			dev += 1
		end
	end
	local attempts = o.attempts or StoreBinder.ATTEMPTS
	local warnedAmbiguous: { [string]: boolean } = {}
	local warnedVerify: { [string]: boolean } = {}
	local slowRetry = o.slowRetrySeconds or StoreBinder.SLOW_RETRY_SECONDS
	local round = 0
	while true do
		round += 1
		local slow = round > attempts
		local boundBefore = 0
		for _ in pairs(bound) do
			boundBefore += 1
		end
		local okList, listed = pcall(o.list)
		if not okList or type(listed) ~= "table" then
			if not slow then
				warnFn(string.format("%sGetDeveloperProductsAsync failed (round %d/%d): %s", LOG, round, attempts, tostring(listed)))
			end
		else
			local result = StoreBinding.match(o.products, listed)
			for _, key in ipairs(result.ambiguous) do
				if not warnedAmbiguous[key] then
					warnedAmbiguous[key] = true
					warnFn(string.format("%sunbound %s: two products share its name; rename one in Creator Hub", LOG, key))
				end
			end
			local keys = {}
			for key in pairs(result.bound) do
				if bound[key] == nil then
					table.insert(keys, key)
				end
			end
			table.sort(keys)
			for _, key in ipairs(keys) do
				local m = result.bound[key]
				local candidates: { number } = { m.id }
				if m.altId then
					table.insert(candidates, m.altId)
				end
				for _, id in ipairs(candidates) do
					local okInfo, info = pcall(o.verify, id)
					-- Ids are global: an id that answers but names another product (the wrong id field resolving to
					-- someone else's product) is refused, never bound.
					if okInfo and type(info) == "table" and StoreBinding.normalize(info.Name) == StoreBinding.normalize(m.name) then
						commit(key, id, if type(info.PriceInRobux) == "number" then info.PriceInRobux else m.price)
						break
					end
					local why = if okInfo and type(info) == "table" then "names " .. tostring(info.Name) else tostring(info)
					if not warnedVerify[key .. id] then -- once per product id, not once per retry round
						warnedVerify[key .. id] = true
						warnFn(string.format("%sGetProductInfo(%d) failed for %s: %s", LOG, id, key, why))
					end
				end
			end
		end
		local missing = {}
		local hidden = 0
		for _, p in ipairs(o.products) do
			if p.kind == "DevProduct" and not live[p.key] then
				hidden += 1
			elseif p.kind == "DevProduct" and bound[p.key] == nil then
				table.insert(missing, p.key)
			end
		end
		-- One line per round (never one per product): QA reads the boot output through capped log buffers.
		local n = 0
		local total = 0
		for key in pairs(bound) do
			total += 1
			if live[key] then
				n += 1
			end
		end
		local slowRound = round - attempts
		if not slow or total > boundBefore or #missing == 0 or slowRound % StoreBinder.SLOW_LOG_EVERY == 0 then
			o.log(string.format(
				"%s%s: %d bound, %d of %d developer products unbound%s%s",
				LOG,
				if slow then string.format("slow round %d", slowRound) else string.format("round %d/%d", round, attempts),
				n, #missing, dev - hidden,
				if #missing > 0 then " [" .. table.concat(missing, ",") .. "]" else "",
				if hidden > 0 then string.format(", %d hidden at launch", hidden) else ""
			))
		end
		if #missing == 0 then
			break
		end
		if round >= attempts then
			if slowRetry <= 0 or (o.slowRounds ~= nil and slowRound >= o.slowRounds) then
				break
			end
			if round == attempts then
				o.log(string.format("%sstill unbound after %d rounds; retrying every %d s while this server runs", LOG, attempts, slowRetry))
			end
			o.sleep(slowRetry)
		else
			o.sleep(o.retrySeconds or StoreBinder.RETRY_SECONDS)
		end
	end
	return bound
end

-- Live wiring: Economy.init calls this after the service exists. Spawns the binder; never blocks the caller.
function StoreBinder.start(bind: (key: string, id: number) -> (boolean, string?), products: { any }, isLive: ((product: any) -> boolean)?)
	local config = require(Shared:WaitForChild("MonetizationConfig"))
	if not config.Enabled and not config.ReceiptRecoveryEnabled then return end
	local MarketplaceService = game:GetService("MarketplaceService")
	local StorePassIds = require(Shared:WaitForChild("StorePassIds"))
	local folder = ReplicatedStorage:FindFirstChild("SkyRallyStore")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "SkyRallyStore"
		folder.Parent = ReplicatedStorage
	end
	local mirror = folder :: Instance
	task.spawn(StoreBinder.run, {
		products = products,
		passIds = StorePassIds.PASS_IDS,
		list = function(): { any }
			local all = {}
			local pages = MarketplaceService:GetDeveloperProductsAsync()
			while true do
				for _, entry in ipairs(pages:GetCurrentPage()) do
					table.insert(all, entry)
				end
				if pages.IsFinished then
					break
				end
				pages:AdvanceToNextPageAsync()
			end
			return all
		end,
		verify = function(id: number): any
			return MarketplaceService:GetProductInfo(id, Enum.InfoType.Product)
		end,
		bind = bind,
		isLive = function(product)
			return config.Enabled == true and (isLive == nil or isLive(product))
		end,
		publish = function(key: string, id: number)
			mirror:SetAttribute(key, id)
		end,
		sleep = function(seconds: number)
			task.wait(seconds)
		end,
		log = function(line: string)
			print(line)
		end,
		warn = function(line: string)
			warn(line)
		end,
	} :: Options)
end

return StoreBinder
