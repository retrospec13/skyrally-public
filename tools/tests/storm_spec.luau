--!strict
-- Storm Shards, reputation tiers, the Storm vendor, the storm badges and the hub storm state (economy v3 phase 5):
-- shared/StormConfig + shared/StormRules, server/StormShards over a REAL SaveService, BadgeRules' storm rows, and the
-- guards that keep Shards off every Cash / Robux path. Run: tools/tests/run_lune_tests.sh tools/tests/storm_spec.luau
return function(h)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local StormConfig = h.require("src/shared/StormConfig.luau")
	local R = h.require("src/shared/StormRules.luau")
	local SaveService = h.require("src/server/SaveService.luau")
	local StormShards = h.require("src/server/StormShards.luau")
	local BadgeRules = h.require("src/shared/BadgeRules.luau")
	local BadgeAwards = h.require("src/server/BadgeAwards.luau")
	local MonetizationConfig = h.require("src/shared/MonetizationConfig.luau")
	local EconomyRules = h.require("src/shared/EconomyRules.luau")
	local NotifySpec = h.require("src/shared/NotifySpec.luau")
	local SoundscapeRules = h.require("src/shared/SoundscapeRules.luau")

	local DAY = 86400
	local T0 = 1794009600 + DAY + 10 * 3600 -- a Sunday 10:00 UTC
	local D0 = math.floor(T0 / DAY)

	local function fin(over)
		local f = { mode = "stormcup", rank = 4, finished = true, simulated = false }
		for k, v in over or {} do
			f[k] = v
		end
		return f
	end

	local function has(list, key)
		return table.find(list, key) ~= nil
	end

	-------------------------------------------------------------------------------------------------- earn table

	h.test("stand: no portal arch label is hidden behind the vendor sign from the hub approach views", function()
		local plan = h.readFile("map/hub0/plan.json")
		local S = StormConfig.STAND
		local views = { { -8196, 8066 }, { -8180, 8050 }, { -8160, 8030 }, { -8150, 8010 }, { -8200, 8030 }, { -8120, 8010 } }
		local arches = 0
		for pf, x, z in string.gmatch(plan, '"pf": ?"(PortalArch_%w+)", ?"p": ?%[(%-?[%d%.]+), ?[%d%.]+, ?(%-?[%d%.]+)%]') do
			arches += 1
			for _, v in views do
				local toArch = math.atan2(tonumber(z) - v[2], tonumber(x) - v[1])
				local toStand = math.atan2(S.pos.Z - v[2], S.pos.X - v[1])
				local d = math.abs((toArch - toStand + math.pi) % (2 * math.pi) - math.pi)
				h.ok(d > math.rad(25), pf .. " is within 25 degrees of the stand from a hub approach view")
			end
		end
		h.eq(arches, 5)
	end)

	h.test("static: StormVendor refreshes its header labels in place, never appending duplicates", function()
		local src = h.readFile("src/client/StormVendor.luau")
		for _, nm in { "Title", "Rank", "Shards" } do
			h.contains(src, ', "' .. nm .. '")')
		end
		h.contains(src, 'parent:FindFirstChild(name)')
		h.contains(src, 'child.Name == "StormVendorPanel" and child ~= panel')
		h.ok(not string.find(src, "panel:Destroy()", 1, true), "the panel Frame is reused, not destroyed and rebuilt")
	end)

	h.test("earn table: 12 for finishing + place 28..0, so 1st 40 down to 8th 12; 9th+ pays as last", function()
		local st = R.defaults()
		st.bonusDay = D0 -- the daily bonus is already taken today
		local want = { 40, 36, 32, 28, 24, 20, 16, 12 }
		for rank, total in want do
			local p = R.earn(fin({ rank = rank }), st, D0)
			h.eq(p.total, total, "rank " .. rank)
			h.eq(p.parts.finish, 12)
		end
		h.eq(R.earn(fin({ rank = 12 }), st, D0).total, 12, "beyond the table = last place")
	end)

	h.test("earn table: +30 for beating the storm dragon, +10 for the first storm finish of the UTC day", function()
		local st = R.defaults()
		local p = R.earn(fin({ rank = 1, beatDragon = true }), st, D0)
		h.eq(p.total, 40 + 30 + 10)
		h.eq(p.parts, { finish = 12, place = 28, dragon = 30, firstOfDay = 10 })
		h.ok(p.firstOfDay and p.beatDragon)
		R.applyFinish(st, p, D0)
		h.eq(R.earn(fin({ rank = 1 }), st, D0).parts.firstOfDay, 0, "second race the same day: no daily bonus")
		h.eq(R.earn(fin({ rank = 1 }), st, D0 + 1).parts.firstOfDay, 10, "next UTC day: bonus again")
	end)

	h.test("earn: only a finished storm race pays; not a normal race, not a DNF, not a QA finish outside Studio", function()
		local st = R.defaults()
		h.eq(R.earn(fin({ mode = "race" }), st, D0), nil)
		h.eq(R.earn(fin({ mode = "boss" }), st, D0), nil)
		h.eq(R.earn(fin({ finished = false }), st, D0), nil)
		h.eq(R.earn(fin({ simulated = true }), st, D0), nil)
		h.ok(R.earn(fin({ simulated = true }), st, D0, true) ~= nil, "Studio QA finish counts")
		h.ok(R.earn(fin({ mode = "stormrace" }), st, D0) ~= nil, "the per-group storm race mode pays too")
	end)

	h.test("applyFinish: balance and lifetime grow together; races and dragon wins count", function()
		local st = R.defaults()
		R.applyFinish(st, R.earn(fin({ rank = 2, beatDragon = true }), st, D0), D0)
		h.eq(st.shards, 36 + 30 + 10)
		h.eq(st.lifetime, 76)
		h.eq(st.races, 1)
		h.eq(st.dragonWins, 1)
		h.eq(st.bonusDay, D0)
		R.applyFinish(st, R.earn(fin({ rank = 8 }), st, D0), D0)
		h.eq(st.races, 2)
		h.eq(st.dragonWins, 1)
		h.eq(st.lifetime, 88)
	end)

	h.test("the dragon is beaten only in a storm race with a dragon in the field and nobody of the bots ahead", function()
		h.ok(R.beatDragon("stormcup", true, true, true))
		h.ok(not R.beatDragon("stormcup", true, true, false), "no dragon in the field today (flow phase sets it)")
		h.ok(not R.beatDragon("stormcup", true, false, true), "the dragon crossed first")
		h.ok(not R.beatDragon("race", true, true, true), "not a storm race")
		h.ok(not R.beatDragon("stormcup", false, true, true), "not finished")
	end)

	h.test("Shards never ride a multiplier: no Cash source, product or shop row touches them", function()
		for src in MonetizationConfig.MULTIPLIED_SOURCES do
			h.ok(not string.find(string.lower(src), "shard", 1, true), "multiplied source " .. src)
		end
		for _, p in MonetizationConfig.PRODUCTS do
			for field in p.grants do
				h.ok(not string.find(string.lower(field), "shard", 1, true), p.key .. " grants " .. field)
				h.ok(not string.find(string.lower(field), "storm", 1, true), p.key .. " grants " .. field)
			end
		end
		-- earn takes no multiplier at all: the same finish pays the same Shards whatever the x2 / Festival state is.
		h.eq(debug.info(R.earn, "a"), 4, "earn(info, state, day, allowSimulated): no multiplier parameter")
		-- Storm cosmetics: no Cash price, never stocked, never in a product.
		h.eq(EconomyRules.default.validate(), {})
		local c = table.clone(MonetizationConfig)
		c.PRODUCTS = table.clone(MonetizationConfig.PRODUCTS)
		table.insert(c.PRODUCTS, { key = "evil", kind = "DevProduct", label = "Evil", grants = { cosmetics = { "Livery_Storm_Eye" } }, defaultPriceLabel = "99" })
		local errs = EconomyRules.new(c).validate()
		h.ok(#errs >= 1 and string.find(table.concat(errs, ";"), "Storm vendor", 1, true) ~= nil, "a product selling a storm item fails validate")
	end)

	-------------------------------------------------------------------------------------------------- tiers

	h.test("tiers: Squall 0 / Gale 250 / Tempest 1,200 / Eye of the Storm 4,200 lifetime Shards", function()
		h.eq(#StormConfig.TIERS, 4)
		h.eq(R.tierFor(0).name, "Squall")
		h.eq(R.tierFor(249).id, "squall")
		h.eq(R.tierFor(250).id, "gale")
		h.eq(R.tierFor(1199).id, "gale")
		h.eq(R.tierFor(1200).id, "tempest")
		h.eq(R.tierFor(4199).id, "tempest")
		h.eq(R.tierFor(4200).name, "Eye of the Storm")
		h.eq(R.tierFor(999999).id, "eye")
		local nxt, need = R.nextTier(1000)
		h.eq(nxt.id, "tempest")
		h.eq(need, 200)
		h.eq(R.nextTier(5000), nil, "top tier: nothing next")
	end)

	h.test("tier-ups: one per tier crossed, lowest first; spending never lowers the tier (lifetime only grows)", function()
		h.eq(#R.tierUps(240, 260), 1)
		h.eq(R.tierUps(240, 260)[1].id, "gale")
		h.eq(#R.tierUps(0, 1300), 2, "a big jump crosses two")
		h.eq(#R.tierUps(300, 400), 0)
		local profile = { cosmetics = { owned = {} }, storm = { shards = 300, lifetime = 300 } }
		R.applyBuy(profile, "Storm_Tint_Gale")
		h.eq(profile.storm.shards, 80)
		h.eq(profile.storm.lifetime, 300)
		h.eq(R.tierFor(profile.storm.lifetime).id, "gale")
	end)

	h.test("pace: a mid-field racer on 4 storm races a day reaches Eye of the Storm in ~150 races, ~5 weeks", function()
		local st = R.defaults()
		local races, day = 0, D0
		while st.lifetime < 4200 do
			for i = 1, 4 do
				local rank = if i % 2 == 0 then 4 else 5
				R.applyFinish(st, R.earn(fin({ rank = rank }), st, day), day)
				races += 1
			end
			day += 1
		end
		h.ok(races >= 140 and races <= 160, "races to the top tier: " .. races)
		local weeks = (day - D0) / 7
		h.ok(weeks >= 4.5 and weeks <= 6, "weeks: " .. weeks)
		-- a podium regular who also beats the dragon half the time gets there in about half
		local fast, fr, fd = R.defaults(), 0, D0
		while fast.lifetime < 4200 do
			for i = 1, 4 do
				R.applyFinish(fast, R.earn(fin({ rank = 2, beatDragon = i % 2 == 0 }), fast, fd), fd)
				fr += 1
			end
			fd += 1
		end
		h.ok(fr >= 60 and fr < races, "podium + dragon: " .. fr)
	end)

	-------------------------------------------------------------------------------------------------- vendor

	h.test("vendor config: valid, at least 10 cosmetic types, every tier has a page", function()
		h.eq(R.validate(), {})
		local kinds = {}
		for _, it in StormConfig.VENDOR do
			kinds[it.kind] = true
		end
		for _, k in { "tint", "trail", "horn", "emote", "outfit", "title", "border", "flag", "boost", "landing", "engine", "hubEmote" } do
			h.ok(kinds[k], "vendor sells " .. k)
		end
		for _, t in StormConfig.TIERS do
			h.ok(#R.page(t.id) >= 5, t.id .. " page has rows")
		end
	end)

	h.test("vendor: placeholder looks are marked needsArt; effects are particles (a VfxAssets texture), never meshes", function()
		local Vfx = h.require("src/shared/VfxAssets.luau")
		local needs = 0
		for _, it in StormConfig.VENDOR do
			if it.needsArt then
				needs += 1
				h.ok(type(it.note) == "string" and #it.note > 0, it.key .. " says what art it waits on")
			end
			if it.kind == "boost" or it.kind == "landing" then
				h.ok(it.look and Vfx[it.look.texture] ~= nil, it.key .. " uses a particle texture")
				h.eq(it.look.mesh, nil)
			end
		end
		h.ok(needs >= 8, "the art list is real: " .. needs)
	end)

	h.test("Eye of the Storm items are the best-looking rows of their kind in the whole game", function()
		local byKey = {}
		for _, c in MonetizationConfig.COSMETICS do
			byKey[c.key] = c
		end
		local eyeTrail = byKey.Trail_Storm_Eye.trail
		for _, c in MonetizationConfig.COSMETICS do
			if c.kind == "trail" and c.key ~= "Trail_Storm_Eye" then
				h.ok(eyeTrail.width > c.trail.width, "wider than " .. c.key)
				h.ok(eyeTrail.lightEmission >= c.trail.lightEmission, "brighter than " .. c.key)
			end
			if c.kind == "livery" and c.key ~= "Livery_Storm_Eye" then
				h.ok((byKey.Livery_Storm_Eye.livery.glow or 0) > (c.livery.glow or 0), "glows more than " .. c.key)
			end
		end
		h.eq(byKey.Livery_Storm_Eye.livery.finish, "Neon")
		local eyeBoost, eyeMax = nil, 0
		for _, it in StormConfig.VENDOR do
			if it.kind == "boost" then
				if it.tier == "eye" then
					eyeBoost = it
				else
					eyeMax = math.max(eyeMax, it.look.rate)
				end
			end
		end
		h.ok(eyeBoost and eyeBoost.look.rate > eyeMax, "the Eye boost is the densest")
		-- every Eye row costs more than every Squall row
		local squallMax, eyeMin = 0, math.huge
		for _, it in StormConfig.VENDOR do
			if it.tier == "squall" then
				squallMax = math.max(squallMax, it.price)
			elseif it.tier == "eye" then
				eyeMin = math.min(eyeMin, it.price)
			end
		end
		h.ok(eyeMin > squallMax)
	end)

	h.test("purchase: insufficient Shards, already owned, tier-locked, coming soon, unknown (in that order)", function()
		local function why(state, key, cos)
			local ok, reason = R.canBuy(R.read({ storm = state }), cos, key)
			return if ok then "ok" else reason
		end
		h.eq(why({ shards = 100, lifetime = 100 }, "Storm_Title_Squall"), "ok")
		h.eq(why({ shards = 30, lifetime = 100 }, "Storm_Title_Squall"), "short", "insufficient")
		h.eq(why({ shards = 999, lifetime = 999, owned = { Storm_Title_Squall = true } }, "Storm_Title_Squall"), "owned")
		h.eq(why({ shards = 999, lifetime = 999 }, "Storm_Tint_Squall", { Livery_Storm_Squall = true }), "owned", "the Garage already holds the tint")
		h.eq(why({ shards = 5000, lifetime = 249 }, "Storm_Tint_Gale"), "locked", "rich but not Gale yet")
		h.eq(why({ shards = 5000, lifetime = 4199 }, "Storm_Tint_Eye"), "locked")
		h.eq(why({ shards = 5000, lifetime = 4200 }, "Storm_Tint_Eye"), "ok")
		h.eq(why({ shards = 9999, lifetime = 9999 }, "Storm_Avatar_OctoFlyer"), "comingSoon")
		h.eq(why({ shards = 9999, lifetime = 9999 }, "Nope"), "unknown")
		h.eq(why({ shards = 9999, lifetime = 9999 }, 42), "unknown")
	end)

	h.test("SELL_PENDING_LOOKS off: rows with no renderer yet are listed but refused; the Garage four still sell", function()
		local was = StormConfig.SELL_PENDING_LOOKS
		StormConfig.SELL_PENDING_LOOKS = false
		local st = R.read({ storm = { shards = 999, lifetime = 999 } })
		local _, r1 = R.canBuy(st, nil, "Storm_Title_Squall")
		h.eq(r1, "comingSoon")
		h.ok((R.canBuy(st, nil, "Storm_Trail_Drizzle")))
		StormConfig.SELL_PENDING_LOOKS = was
	end)

	h.test("applyBuy: spends Shards, marks owned, and puts a Garage kind's cosmetic in cosmetics.owned; refusals error", function()
		local profile = { cosmetics = { owned = {} }, storm = { shards = 200, lifetime = 200 } }
		R.applyBuy(profile, "Storm_Trail_Drizzle")
		h.eq(profile.storm.shards, 100)
		h.ok(profile.storm.owned.Storm_Trail_Drizzle)
		h.ok(profile.cosmetics.owned.Trail_Storm_Drizzle, "equippable in the Garage")
		R.applyBuy(profile, "Storm_Title_Squall")
		h.eq(profile.cosmetics.owned.Storm_Title_Squall, nil, "storm-slot kinds stay in the storm record")
		h.ok(not pcall(R.applyBuy, profile, "Storm_Trail_Drizzle"), "owned")
		h.ok(not pcall(R.applyBuy, profile, "Storm_Tint_Tempest"), "locked")
	end)

	h.test("equip: storm-only slots, owned items only, right slot; Garage kinds are not equipped here", function()
		local st = R.read({ storm = { owned = { Storm_Title_Squall = true, Storm_Flag_Squall = true } } })
		h.ok((R.canEquip(st, "title", "Storm_Title_Squall")))
		h.ok((R.canEquip(st, "title", "")), "unequip")
		h.eq(select(2, R.canEquip(st, "flag", "Storm_Title_Squall")), "wrongSlot")
		h.eq(select(2, R.canEquip(st, "title", "Storm_Title_Gale")), "notOwned")
		h.eq(select(2, R.canEquip(st, "garage", "Storm_Title_Squall")), "badSlot")
		h.eq(select(2, R.canEquip(st, "avatar", "Storm_Avatar_OctoFlyer")), "badSlot")
		h.eq(select(2, R.canEquip(st, "nonsense", nil)), "badSlot")
		h.eq(R.encodeLoadout({ title = "Storm_Title_Squall", border = "Storm_Border_Gale" }), "border=Storm_Border_Gale,title=Storm_Title_Squall")
		h.eq(R.decodeLoadout("border=Storm_Border_Gale,title=Storm_Title_Squall"), { border = "Storm_Border_Gale", title = "Storm_Title_Squall" })
	end)

	-------------------------------------------------------------------------------------------------- old profiles

	h.test("old profiles: no storm record (or garbage) reads as zeros and empty; migrate fills the defaults", function()
		h.eq(R.read(nil), R.defaults())
		h.eq(R.read({}), R.defaults())
		h.eq(R.read({ storm = "junk" }), R.defaults())
		local bad = R.read({ storm = { shards = -5, lifetime = 0 / 0, races = "x", dragonWins = 2.7, owned = { a = true, b = 1 }, loadout = { title = 3 } } })
		h.eq(bad.shards, 0)
		h.eq(bad.lifetime, 0)
		h.eq(bad.races, 0)
		h.eq(bad.dragonWins, 2)
		h.eq(bad.owned, { a = true })
		h.eq(bad.loadout, {})
		local fresh = SaveService.newProfile()
		h.eq(fresh.storm, R.defaults())
		local old = SaveService.newProfile()
		old.storm = nil
		old.gears = 777
		local migrated = SaveService.migrate(old)
		h.eq(migrated.storm, R.defaults(), "an old record gains the storm record")
		h.eq(migrated.gears, 777, "nothing else moves")
		h.eq(migrated.version, SaveService.CURRENT_VERSION, "no version bump needed")
		local partial = SaveService.newProfile()
		partial.storm = { shards = 40 }
		local m2 = SaveService.migrate(partial)
		h.eq(m2.storm.shards, 40, "a partial record keeps what it has")
		h.eq(m2.storm.lifetime, 0)
		h.eq(m2.storm.owned, {})
	end)

	-------------------------------------------------------------------------------------------------- service

	local function newServer(opts)
		local o = opts or {}
		local w = { sched = h.newScheduler(), backing = {}, fired = {}, logs = {}, utc = { t = T0 }, dragon = false }
		local tokens = 0
		w.save = SaveService.new({
			store = SaveService.newMemoryStore(w.backing),
			sessionId = "storm-A",
			newToken = function()
				tokens += 1
				return "tok" .. tokens
			end,
			now = w.sched.clock,
			clock = w.sched.clock,
			sleep = w.sched.sleep,
			spawn = w.sched.spawn,
			log = function(l)
				table.insert(w.logs, l)
			end,
			random = function()
				return 0.5
			end,
			config = { writeCooldown = 0, saveAttempts = 2, loadAttempts = 2 },
		})
		w.svc = StormShards.new({
			save = w.save,
			now = function()
				return w.utc.t
			end,
			clock = w.sched.clock,
			isStudio = function()
				return o.studio == true
			end,
			dragonInField = function()
				return w.dragon
			end,
			fire = function(p, kind, payload)
				table.insert(w.fired, { user = p.UserId, kind = kind, payload = payload })
			end,
			log = function(l)
				table.insert(w.logs, l)
			end,
		})
		function w.join(userId)
			local p = h.fakePlayer(userId)
			w.sched.run(function()
				w.save.load(p)
			end)
			w.sched.advance(0)
			return p
		end
		function w.storm(p)
			return R.read(w.save.get(p))
		end
		return w
	end

	h.test("service: a storm finish pays Shards through the save, fires the payout, and replicates the attributes", function()
		local w = newServer()
		local p = w.join(9101)
		local res = w.svc.onFinish(p, { trackId = "DINO-4", mode = "stormcup", rank = 1, finished = true, simulated = false, beatBoss = true })
		h.eq(res.payout.total, 50, "40 + daily 10; no dragon in the field so beatBoss is not a dragon win")
		h.eq(res.beatDragon, false)
		h.eq(w.storm(p).shards, 50)
		h.eq(w.storm(p).races, 1)
		h.eq(p:GetAttribute("StormShards"), 50)
		h.eq(p:GetAttribute("StormShardsLifetime"), 50)
		h.eq(p:GetAttribute("StormTier"), "squall")
		h.eq(w.fired[1].kind, "Shards")
		h.eq(w.fired[1].payload.n, 50)
		-- a normal race pays no Shards and writes nothing
		local before = #w.logs
		h.eq(w.svc.onFinish(p, { trackId = "DINO-4", mode = "race", rank = 1, finished = true }).payout, nil)
		h.eq(h.count({ table.unpack(w.logs, before + 1) }, "edit user"), 0, "no save write")
	end)

	h.test("service: the dragon in the field + no bot ahead = dragon win (+30), counted for the badges", function()
		local w = newServer()
		w.dragon = true
		local p = w.join(9102)
		local res = w.svc.onFinish(p, { mode = "stormcup", rank = 1, finished = true, beatBoss = true })
		h.ok(res.beatDragon)
		h.eq(res.payout.parts.dragon, 30)
		h.eq(w.storm(p).dragonWins, 1)
		h.eq(p:GetAttribute("StormDragonWins"), 1)
		local lost = w.svc.onFinish(p, { mode = "stormcup", rank = 2, finished = true, beatBoss = false })
		h.eq(lost.beatDragon, false)
		h.eq(w.storm(p).dragonWins, 1)
	end)

	h.test("service: tier-up crossing fires the tier names (the client toasts shard_tier_up)", function()
		local w = newServer()
		local p = w.join(9103)
		assert(w.save.edit(p, "spec", function(d)
			d.storm.shards, d.storm.lifetime = 230, 230
		end))
		w.svc.onFinish(p, { mode = "stormcup", rank = 1, finished = true })
		local last = w.fired[#w.fired]
		h.eq(last.payload.tierUps, { "Gale" })
		h.eq(p:GetAttribute("StormTier"), "gale")
	end)

	h.test("service: a QA (simulated) finish pays only in Studio; a profile that is not loaded pays nothing", function()
		local w = newServer({ studio = false })
		local p = w.join(9104)
		h.eq(w.svc.onFinish(p, { mode = "stormcup", rank = 1, finished = true, simulated = true }).payout, nil)
		h.eq(w.storm(p).shards, 0)
		local ws = newServer({ studio = true })
		local q = ws.join(9105)
		h.ok(ws.svc.onFinish(q, { mode = "stormcup", rank = 1, finished = true, simulated = true }).payout ~= nil)
		local ghost = h.fakePlayer(9106)
		h.eq(w.svc.onFinish(ghost, { mode = "stormcup", rank = 1, finished = true }).payout, nil)
	end)

	h.test("service: buy and equip through requests; refusals leave the save alone; requests are spaced", function()
		local w = newServer()
		local p = w.join(9107)
		assert(w.save.edit(p, "spec", function(d)
			d.storm.shards, d.storm.lifetime = 300, 300
		end))
		local r = w.svc.handleRequest(p, "Buy", "Storm_Title_Gale")
		h.ok(r.ok, tostring(r.reason))
		h.eq(r.data.shards, 120)
		w.sched.advance(1)
		h.eq(w.svc.handleRequest(p, "Buy", "Storm_Title_Gale").reason, "owned")
		w.sched.advance(1)
		h.eq(w.svc.handleRequest(p, "Buy", "Storm_Tint_Tempest").reason, "locked")
		w.sched.advance(1)
		h.eq(w.svc.handleRequest(p, "Buy", "Storm_Trail_Gale").reason, "short")
		h.eq(w.storm(p).shards, 120, "refusals spend nothing")
		w.sched.advance(1)
		h.ok(w.svc.handleRequest(p, "Equip", "title", "Storm_Title_Gale").ok)
		h.eq(p:GetAttribute("StormLoadout"), "title=Storm_Title_Gale")
		h.eq(w.svc.handleRequest(p, "Equip", "title", "").reason, "rateLimited", "too soon")
		w.sched.advance(1)
		h.ok(w.svc.handleRequest(p, "Equip", "title", "").ok)
		h.eq(p:GetAttribute("StormLoadout"), "")
		w.sched.advance(1)
		h.eq(w.svc.handleRequest(p, "Buy", { "table" }).reason, "badRequest")
		w.sched.advance(1)
		h.eq(w.svc.handleRequest(p, "Hack").reason, "badAction")
		w.sched.advance(1)
		local s = w.svc.handleRequest(p, "GetState")
		h.ok(s.ok)
		h.eq(s.data.tier, "gale")
		h.eq(s.data.nextTier, "tempest")
		h.eq(s.data.need, 900)
		h.ok(has(s.data.owned, "Storm_Title_Gale"))
	end)

	h.test("service: a Garage-kind purchase is equipped by the Garage (cosmetics.owned), not by the storm slots", function()
		local w = newServer()
		local p = w.join(9108)
		assert(w.save.edit(p, "spec", function(d)
			d.storm.shards, d.storm.lifetime = 500, 500
		end))
		h.ok(w.svc.buy(p, "Storm_Trail_Gale").ok)
		h.ok(w.save.get(p).cosmetics.owned.Trail_Storm_Gale)
		h.eq(w.svc.equip(p, "trail", "Storm_Trail_Gale").reason, "badSlot")
	end)

	-------------------------------------------------------------------------------------------------- badges

	h.test("badges: Storm Racer on any storm finish; Dragon Slayer / Hunter 5 / Bane 25 / Stormbreaker 100 dragon wins", function()
		h.eq(#BadgeRules.DEFS, 10)
		local names = {}
		for _, d in BadgeRules.DEFS do
			names[d.key] = d.title
			h.eq(BadgeAwards.BadgeIds[d.key], nil, d.key .. " id stays nil until the owner creates it")
		end
		h.eq(names.storm_racer, "Storm Racer")
		h.eq(names.dragon_slayer, "Dragon Slayer")
		h.eq(names.dragon_hunter, "Dragon Hunter")
		h.eq(names.dragon_bane, "Dragon Bane")
		h.eq(names.stormbreaker, "Stormbreaker")
		local ev = { trackId = "DINO-4", mode = "stormcup", rank = 5, finished = true, simulated = false }
		h.ok(has(BadgeRules.earned({}, ev), "storm_racer"), "the finish itself")
		h.ok(not has(BadgeRules.earned({}, ev), "dragon_slayer"))
		ev.beatDragon = true
		h.ok(has(BadgeRules.earned({}, ev), "dragon_slayer"), "the dragon win itself")
		h.ok(not has(BadgeRules.earned({}, { trackId = "DINO-4", mode = "race", rank = 1, finished = true, beatDragon = true }), "dragon_slayer"), "only in a storm race")
		h.ok(not has(BadgeRules.earned({}, { trackId = "DINO-4", mode = "stormcup", rank = 1, finished = true, simulated = true }), "storm_racer"), "QA finish")
		local function at(n)
			return BadgeRules.earned({ storm = { races = n, dragonWins = n } }, nil)
		end
		h.ok(has(at(1), "storm_racer") and has(at(1), "dragon_slayer") and not has(at(1), "dragon_hunter"))
		h.ok(has(at(5), "dragon_hunter") and not has(at(4), "dragon_hunter"))
		h.ok(has(at(25), "dragon_bane") and not has(at(24), "dragon_bane"))
		h.ok(has(at(100), "stormbreaker") and not has(at(99), "stormbreaker"))
		h.ok(not has(BadgeRules.earned({}, nil), "storm_racer"), "an old profile with no storm record earns none")
	end)

	h.test("badges docs: BADGES.md lists every storm badge, says ids are nil, and that creating badges may cost Robux", function()
		local docs = h.readFile("docs/BADGES.md")
		for _, k in { "storm_racer", "dragon_slayer", "dragon_hunter", "dragon_bane", "stormbreaker" } do
			h.contains(docs, k)
		end
		h.contains(docs, "Robux")
		h.contains(docs, "Art brief")
	end)

	h.test("static: the boot script runs Shards before badges in the finish hook", function()
		local boot = h.readFile("src/server/init.server.luau")
		local a = string.find(boot, "info.beatDragon = StormShards.onFinish(player, info)", 1, true)
		local b = string.find(boot, "BadgeAwards.onFinish(player, info)", 1, true)
		h.ok(a ~= nil and b ~= nil and a < b, "Shards before badges")
		local client = h.readFile("src/shared/BootRules.luau") -- the client boot's order (audit T1-1)
		h.contains(client, '{ name = "HubStorm" }')
		h.contains(client, '{ name = "StormVendor", spawn = true }')
	end)

	-------------------------------------------------------------------------------------------------- notifications

	h.test("notifications: shard, dragon, tier-up, vendor and hub marker rows exist and read right", function()
		for _, id in { "shard_gain", "shard_tier_up", "dragon_beaten", "vendor_bought", "vendor_locked", "vendor_short", "storm_hub_live", "storm_hub_next" } do
			h.ok(NotifySpec.get(id) ~= nil, id)
		end
		h.eq(NotifySpec.format(NotifySpec.get("shard_tier_up").copy, { tier = "Gale" }), "Storm rank: Gale. New vendor page.")
		h.eq(NotifySpec.get("storm_hub_live").copy, "STORM RACE IN PROGRESS")
	end)

	-------------------------------------------------------------------------------------------------- hub

	h.test("hub state: storm on only in the hub while a storm race runs (or the QA switch); marker and countdown", function()
		local now = 1800 * 1000 + 600 -- 10 minutes past a :00/:30
		local s = R.hubState({ mode = "hub", live = true }, now)
		h.ok(s.show and s.active)
		h.eq(s.marker, "STORM RACE IN PROGRESS")
		local idle = R.hubState({ mode = "hub" }, now)
		h.ok(idle.show and not idle.active)
		h.eq(idle.nextAt, 1800 * 1001)
		h.eq(idle.marker, "NEXT STORM RACE 20:00")
		local pub = R.hubState({ mode = "hub", nextAt = now + 65 }, now)
		h.eq(pub.marker, "NEXT STORM RACE 1:05", "StormCupAt wins when published")
		h.ok(R.hubState({ mode = "hub", qa = true }, now).active, "Studio capture switch")
		local race = R.hubState({ mode = "race", live = true }, now)
		h.ok(not race.show and not race.active, "never inside a race")
		h.ok(R.lightningGap(0) >= StormConfig.HUB.lightningMin and R.lightningGap(1) <= StormConfig.HUB.lightningMax)
		h.ok(SoundscapeRules.stormLayer("hub", true), "thunder stand-in in the hub storm")
		h.ok(not SoundscapeRules.stormLayer("hub", false))
		h.ok(not SoundscapeRules.stormLayer("hub"))
		h.ok(idle.marked and s.marked, "marker shown between races while the cup is scheduled, and during a storm")
		local off = R.hubState({ mode = "hub", nextAt = now + 65, cupEnabled = false }, now)
		h.ok(off.show and not off.active and not off.marked, "no countdown to a Storm Cup that is switched off")
		h.ok(R.hubState({ mode = "hub", live = true, cupEnabled = false }, now).marked, "a live storm still shows IN PROGRESS")
		h.ok(not race.marked)
	end)

	h.test("service: the panel's re-read right after a Buy / Equip is not rate limited (reads and writes spaced apart)", function()
		local w = newServer()
		local p = w.join(9111)
		assert(w.save.edit(p, "spec", function(d)
			d.storm.shards, d.storm.lifetime = 300, 300
		end))
		h.ok(w.svc.handleRequest(p, "Buy", "Storm_Title_Squall").ok)
		local s = w.svc.handleRequest(p, "GetState")
		h.ok(s.ok, "same instant as the Buy: " .. tostring(s.reason))
		h.eq(s.data.shards, 240)
		h.ok(has(s.data.owned, "Storm_Title_Squall"))
		h.eq(w.svc.handleRequest(p, "GetState").reason, "rateLimited", "reads are still spaced")
		h.eq(w.svc.handleRequest(p, "Buy", "Storm_Tint_Squall").reason, "rateLimited", "writes are still spaced")
		w.svc.forget(p)
		h.ok(w.svc.handleRequest(p, "GetState").ok, "forget clears both clocks")
	end)

	h.test("service: the Studio QA grant raises balance and lifetime in Studio only", function()
		local live = newServer({ studio = false })
		local p = live.join(9112)
		h.eq(live.svc.qaGrant(p, 1300), false)
		h.eq(live.storm(p).shards, 0)
		local studio = newServer({ studio = true })
		local q = studio.join(9113)
		h.ok(studio.svc.qaGrant(q, 1300))
		h.eq(studio.storm(q).shards, 1300)
		h.eq(studio.storm(q).lifetime, 1300)
		h.eq(q:GetAttribute("StormTier"), "tempest")
		h.eq(studio.svc.qaGrant(q, -5), false)
		h.eq(studio.svc.qaGrant(q, 0 / 0), false)
		h.eq(studio.storm(q).shards, 1300)
	end)

	h.test("panel layout: fits a 740x360 phone and a desktop with 44 px targets", function()
		for _, v in { { 740, 360 }, { 1920, 1080 }, { 390, 844 } } do
			local L = R.panelLayout(v[1], v[2], 0)
			h.ok(L.x >= 0 and L.y >= 0 and L.x + L.w <= v[1] and L.y + L.h <= v[2], "inside " .. v[1] .. "x" .. v[2])
			h.ok(L.tabs >= 44 and L.row >= 44, "targets")
			local rowsVisible = (L.h - L.header - L.tabs - 3 * L.pad) / (L.row + 6)
			h.ok(rowsVisible >= 3, "at least three rows visible: " .. rowsVisible)
		end
	end)
end
