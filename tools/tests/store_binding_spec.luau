--!strict
-- Lune spec for Robux id binding: src/shared/StoreBinding.luau (name matching, pure) and src/server/StoreBinder.luau
-- (rounds, verification, logging) with MarketplaceService mocked (docs/STORE_PRODUCTS_TO_CREATE.md; L50-L51).
-- Run: tools/tests/run_lune_tests.sh tools/tests/store_binding_spec.luau
-- Ids below are spec fixtures standing in for what GetDeveloperProductsAsync would list; none is a real product.

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

return function(h: Harness)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local StoreBinding = h.require("src/shared/StoreBinding.luau")
	local StoreBinder = h.require("src/server/StoreBinder.luau")
	local StorePassIds = h.require("src/shared/StorePassIds.luau")
	local MonetizationConfig = h.require("src/shared/MonetizationConfig.luau")
	local EconomyRules = h.require("src/shared/EconomyRules.luau")

	local ROWS = {
		{ key = "x2Gears", kind = "Pass", label = "2x Cash" },
		{ key = "gearsPack1", kind = "DevProduct", label = "500 Cash" },
		{ key = "gearsPack2", kind = "DevProduct", label = "1,200 Cash" },
		{ key = "founderPack1", kind = "DevProduct", label = "Founder Pack", storeName = "Founder Pack S1" },
	}

	local function inputIds(listed: { any }): { [number]: boolean }
		local set = {}
		for _, e in ipairs(listed) do
			if type(e.ProductId) == "number" then
				set[e.ProductId] = true
			end
			if type(e.DeveloperProductId) == "number" then
				set[e.DeveloperProductId] = true
			end
		end
		return set
	end

	h.test("match: exact names bind to the listed ProductId; storeName overrides the label", function()
		local listed = {
			{ Name = "500 Cash", ProductId = 111, DeveloperProductId = 911, PriceInRobux = 49 },
			{ Name = "Founder Pack S1", ProductId = 333, PriceInRobux = 199 },
			{ Name = "Founder Pack", ProductId = 444 }, -- the label, not the storeName: ignored
		}
		local r = StoreBinding.match(ROWS, listed)
		h.eq(r.bound.gearsPack1, { id = 111, altId = 911, name = "500 Cash", price = 49 })
		h.eq(r.bound.founderPack1.id, 333)
		h.eq(r.unbound, { "gearsPack2" })
		h.eq(r.ambiguous, {})
		h.eq(r.bound.x2Gears, nil, "passes never bind by name")
	end)

	h.test("match: trims, collapses spaces and ignores case; a near-miss name does not bind", function()
		local r = StoreBinding.match(ROWS, {
			{ Name = "  500   CASH ", ProductId = 111 },
			{ Name = "1,200 Gear", ProductId = 222 }, -- missing s
			{ Name = "1200 Cash", ProductId = 223 }, -- missing comma
		})
		h.eq(r.bound.gearsPack1.id, 111)
		h.eq(r.bound.gearsPack2, nil)
		h.eq(StoreBinding.normalize("\t a  B\n"), "a b")
		h.eq(StoreBinding.normalize(nil), "")
	end)

	h.test("match: two listed products with one name are ambiguous and bind neither", function()
		local r = StoreBinding.match(ROWS, {
			{ Name = "500 Cash", ProductId = 111 },
			{ Name = "500 cash ", ProductId = 112 },
			{ Name = "1,200 Cash", ProductId = 222 },
		})
		h.eq(r.bound.gearsPack1, nil)
		h.eq(r.ambiguous, { "gearsPack1" })
		h.eq(r.bound.gearsPack2.id, 222)
	end)

	h.test("match: unknown names and malformed entries are ignored; every id returned is from the input", function()
		local listed: { any } = {
			{ Name = "Mystery Box", ProductId = 777 },
			{ Name = "500 Cash", ProductId = "111" }, -- string id: unusable
			{ Name = "1,200 Cash", ProductId = 1.5 },
			{ Name = 42, ProductId = 5 },
			"junk",
			{ Name = "Founder Pack S1", ProductId = 333, DeveloperProductId = 333 },
		}
		local r = StoreBinding.match(ROWS, listed)
		h.eq(r.bound.gearsPack1, nil)
		h.eq(r.bound.gearsPack2, nil)
		h.eq(r.bound.founderPack1.altId, nil, "alt equal to the id is dropped")
		local ids = inputIds(listed)
		for key, m in pairs(r.bound) do
			h.ok(ids[m.id], key .. " id not from input")
		end
		h.eq(next(StoreBinding.match(ROWS, {}).bound), nil, "empty universe binds nothing")
		-- Fuzz: random listings never yield an id that is not in them.
		local seed = 7
		local function int(lo: number, hi: number): number
			seed = (seed * 48271) % 2147483647
			return lo + seed % (hi - lo + 1)
		end
		for _ = 1, 200 do
			local l = {}
			for _ = 1, int(0, 6) do
				local names = { "500 Cash", "1,200 Cash", "founder pack s1", "2x Cash", "other" }
				table.insert(l, { Name = names[int(1, #names)], ProductId = int(1, 50), DeveloperProductId = int(1, 50) })
			end
			local set = inputIds(l)
			for _, m in pairs(StoreBinding.match(ROWS, l).bound) do
				h.ok(set[m.id] and (m.altId == nil or set[m.altId]), "fuzz id from input")
			end
		end
	end)

	h.test("passIds: only well-formed ids for Pass rows; the shipping table is all nil", function()
		h.eq(StoreBinding.passIds(ROWS, { x2Gears = 55, gearsPack1 = 66 }), { x2Gears = 55 })
		h.eq(StoreBinding.passIds(ROWS, { x2Gears = -1 }), {})
		h.eq(StoreBinding.passIds(ROWS, { x2Gears = "55" }), {})
		h.eq(next(StorePassIds.PASS_IDS), nil, "no pass id pasted yet (never invented)")
	end)

	h.test("catalog: every shipping row has a unique store name", function()
		local seen = {}
		for _, p in ipairs(MonetizationConfig.PRODUCTS) do
			local n = StoreBinding.normalize(StoreBinding.storeName(p))
			h.ok(n ~= "" and not seen[n], p.key .. " store name")
			seen[n] = true
		end
		local c = table.clone(MonetizationConfig)
		c.PRODUCTS = table.clone(MonetizationConfig.PRODUCTS)
		table.insert(c.PRODUCTS, { key = "dupe", kind = "DevProduct", label = " 500 cash", grants = { gears = 1 }, defaultPriceLabel = "1" })
		h.contains(EconomyRules.new(c).validate(), "dupe shares its store name with gearsPack1")
	end)

	local function binder(listings: { any }, verifyFails: { [number]: boolean }?, infoNames: { [number]: string }?, isLive: ((any) -> boolean)?, slowRounds: number?): any
		local w: any = { logs = {}, warns = {}, binds = {}, published = {}, sleeps = {}, lists = 0, verified = {} }
		-- GetProductInfo answers with the listed name of whichever entry carries the id (either field) unless overridden.
		local names: { [number]: string } = {}
		for _, l in ipairs(listings) do
			if type(l) == "table" then
				for _, e in ipairs(l) do
					names[e.ProductId] = e.Name
					if e.DeveloperProductId then
						names[e.DeveloperProductId] = e.Name
					end
				end
			end
		end
		for id, n in pairs(infoNames or {}) do
			names[id] = n
		end
		w.result = StoreBinder.run({
			products = ROWS,
			passIds = { x2Gears = 5550 },
			list = function(): { any }
				w.lists += 1
				local l = listings[math.min(w.lists, #listings)]
				if l == "error" then
					error("HTTP 500 (simulated)")
				end
				return l
			end,
			verify = function(id: number): any
				table.insert(w.verified, id)
				if verifyFails and verifyFails[id] then
					error("GetProductInfo failed (simulated)")
				end
				return { Name = names[id], PriceInRobux = id % 1000 }
			end,
			bind = function(key: string, id: number): (boolean, string?)
				table.insert(w.binds, key .. "=" .. id)
				return true, nil
			end,
			isLive = isLive,
			slowRounds = slowRounds or 0, -- the fast-round cases stop after round 10 (the slow rounds have their own case)
			publish = function(key: string, id: number)
				w.published[key] = id
			end,
			sleep = function(s: number)
				table.insert(w.sleeps, s)
			end,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
			warn = function(line: string)
				table.insert(w.warns, line)
			end,
		})
		return w
	end

	h.test("binder: binds the pass, then retries every 60 s until every developer product binds", function()
		local first = { { Name = "500 Cash", ProductId = 1111 } }
		local all = {
			{ Name = "500 Cash", ProductId = 1111 },
			{ Name = "1,200 Cash", ProductId = 2222 },
			{ Name = "Founder Pack S1", ProductId = 3333 },
		}
		local w = binder({ "error", first, all })
		h.eq(w.lists, 3)
		h.eq(w.sleeps, { 60, 60 })
		h.eq(w.result, { x2Gears = 5550, gearsPack1 = 1111, gearsPack2 = 2222, founderPack1 = 3333 })
		h.eq(w.published, w.result, "mirrored to clients")
		h.contains(w.logs, "[SkyRally][Store] bound x2Gears -> 5550 (? R$)")
		h.contains(w.logs, "[SkyRally][Store] bound gearsPack1 -> 1111 (111 R$)")
		h.contains(w.logs, "unbound [gearsPack2")
		h.contains(w.warns, "GetDeveloperProductsAsync failed (round 1/10)")
		local n = 0
		for _, id in ipairs(w.verified) do
			if id == 1111 then
				n += 1
			end
		end
		h.eq(n, 1, "each bound id verified once")
	end)

	h.test("binder (T2-4): after the 10 fast rounds it keeps listing every 300 s, logs quietly, and binds a late product", function()
		local partial = { { Name = "500 Cash", ProductId = 1111 }, { Name = "1,200 Cash", ProductId = 2222 } }
		local all = {
			{ Name = "500 Cash", ProductId = 1111 },
			{ Name = "1,200 Cash", ProductId = 2222 },
			{ Name = "Founder Pack S1", ProductId = 3333 },
		}
		-- The founder pack is created in Creator Hub after round 10 + 14 slow rounds (about 80 minutes in).
		local listings: { any } = {}
		for _ = 1, 24 do
			table.insert(listings, partial)
		end
		table.insert(listings, all)
		local w = binder(listings, nil, nil, nil, 100)
		h.eq(w.lists, 25, "stops listing once everything is bound")
		h.eq(w.result.founderPack1, 3333, "the late product binds on this long-running server")
		h.eq(w.published.founderPack1, 3333, "and reaches the clients")
		local fast, slow = 0, 0
		for _, s in ipairs(w.sleeps) do
			if s == 60 then
				fast += 1
			elseif s == 300 then
				slow += 1
			end
		end
		h.eq(fast, 9)
		h.eq(slow, 15)
		h.contains(w.logs, "still unbound after 10 rounds; retrying every 300 s")
		h.contains(w.logs, "slow round 12: 3 bound, 1 of 3 developer products unbound [founderPack1]", "a quiet slow round logs once an hour")
		h.contains(w.logs, "slow round 15: 4 bound, 0 of 3 developer products unbound", "the round that binds logs")
		h.eq(h.count(w.logs, "slow round"), 2, "no line for the other quiet slow rounds")
		local failed = binder({ "error" }, nil, nil, nil, 3)
		h.eq(failed.lists, 13, "a failing list keeps being retried on the slow cadence")
		h.eq(#failed.warns, 10, "slow-round list failures do not warn again")
	end)

	h.test("binder: gives up after 10 rounds; a failed verify falls back to DeveloperProductId, else stays unbound", function()
		local listing = {
			{ Name = "500 Cash", ProductId = 1111, DeveloperProductId = 9111 },
			{ Name = "1,200 Cash", ProductId = 2222 },
		}
		local w = binder({ listing }, { [1111] = true, [2222] = true })
		h.eq(w.lists, 10)
		h.eq(#w.sleeps, 9)
		h.eq(w.result.gearsPack1, 9111, "alt id verified")
		h.eq(w.result.gearsPack2, nil, "never verified -> never bound")
		h.contains(w.logs, "founderPack1")
		h.contains(w.logs, "round 10/10")
		local roundLines = 0
		for _, l in ipairs(w.logs) do
			if string.find(l, "unbound", 1, true) then
				roundLines += 1
			end
		end
		h.eq(roundLines, 10, "one summary line per round, not one per product per round")
	end)

	h.test("binder: an id whose GetProductInfo names another product is never bound", function()
		local listing = { { Name = "500 Cash", ProductId = 1111, DeveloperProductId = 9111 } }
		local w = binder({ listing }, { [1111] = true }, { [9111] = "Someone Else's Sword" })
		h.eq(w.result.gearsPack1, nil, "alt id resolved to a different product")
		h.contains(w.warns, "GetProductInfo(9111) failed for gearsPack1: names Someone Else's Sword")
	end)

	h.test("binder: an ambiguous name warns once and binds nothing for that row", function()
		local listing = {
			{ Name = "500 Cash", ProductId = 1111 },
			{ Name = "500 Cash", ProductId = 1112 },
		}
		local w = binder({ listing })
		h.eq(w.result.gearsPack1, nil)
		h.eq(h.count(w.warns, "unbound gearsPack1: two products share its name"), 1)
	end)

	---------------------------------------------------------------------------------------------- LAUNCH_HIDE (economy v3)

	-- The shipping rule over the spec rows: founderPack1 is not in the v3 live set.
	local function launchLive(p: any): boolean
		return p.key ~= "founderPack1"
	end

	h.test("binder: LAUNCH_HIDE holds a listed hidden row server-side only (bound for receipts, never mirrored)", function()
		local all = {
			{ Name = "500 Cash", ProductId = 1111 },
			{ Name = "1,200 Cash", ProductId = 2222 },
			{ Name = "Founder Pack S1", ProductId = 3333 },
		}
		local w = binder({ all }, nil, nil, launchLive)
		h.eq(w.result.founderPack1, 3333, "held: Economy grants its receipt")
		h.contains(w.binds, "founderPack1=3333")
		h.eq(w.published.founderPack1, nil, "never mirrored to clients")
		h.eq(w.published.gearsPack1, 1111, "live rows mirror as before")
		h.contains(w.logs, "[SkyRally][Store] held founderPack1 -> 3333 (hidden at launch)")
		h.eq(h.count(w.logs, "bound founderPack1"), 0)
		h.contains(w.logs, "round 1/10: 3 bound, 0 of 2 developer products unbound, 1 hidden at launch")
		h.eq(w.lists, 1, "every live row bound: no retry")
	end)

	h.test("binder: an unlisted hidden row never keeps the binder retrying", function()
		local live = {
			{ Name = "500 Cash", ProductId = 1111 },
			{ Name = "1,200 Cash", ProductId = 2222 },
		}
		local w = binder({ live }, nil, nil, launchLive)
		h.eq(w.lists, 1)
		h.eq(w.sleeps, {})
		h.eq(w.result.founderPack1, nil)
		-- Without the switch the same listing retries for the missing Founder Pack (private builds: everything live).
		local all = binder({ live })
		h.eq(all.lists, 10)
	end)

	h.test("binder: Economy.init passes the LAUNCH_HIDE rule to the binder", function()
		h.contains(h.readFile("src/server/Economy.luau"), "StoreBinder.start(svc.bindId, MonetizationConfig.PRODUCTS, svc.rules.productLive)")
	end)
end
