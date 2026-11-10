--!strict
-- Lune spec for vehicle avatars (economy v3 phase 6): src/shared/AvatarConfig.luau, AvatarRules.luau, VehiclePickRules.luau,
-- the GarageModel VEHICLES rows, and the server paths in src/server/Economy.luau + SaveService.luau (real services over
-- memory stores). Covers ownership, Cash purchase, the per-avatar ladder, stat neutrality and old profiles.
-- Run: tools/tests/run_lune_tests.sh tools/tests/avatar_spec.luau

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

local SUNDAY_10 = 1794009600 + 86400 + 10 * 3600 -- inside Win Pass season 1

return function(h: Harness)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	-- Synthetic server policy for authorized-admin behavior; public defaults tested separately.
	h.fake("src/server/AdminConfig.luau", h.require("src/server/AdminConfig.luau").forUserId(90000001))
	local AvatarConfig = h.require("src/shared/AvatarConfig.luau")
	local AvatarRules = h.require("src/shared/AvatarRules.luau")
	local VehiclePickRules = h.require("src/shared/VehiclePickRules.luau")
	local GarageModel = h.require("src/shared/GarageModel.luau")
	local HudLayoutRules = h.require("src/shared/HudLayoutRules.luau")
	local MonetizationConfig = h.require("src/shared/MonetizationConfig.luau")
	local SaveService = h.require("src/server/SaveService.luau")
	local Economy = h.require("src/server/Economy.luau")

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

	local function cfgCopy(): any
		local c = deepCopy(AvatarConfig)
		c.register = nil
		return c
	end

	local function rowsBy(fn: (any) -> boolean, class: string?): { any }
		local out = {}
		for _, r in ipairs(AvatarConfig.ROWS) do
			if (class == nil or r.class == class) and fn(r) then
				table.insert(out, r)
			end
		end
		return out
	end

	-- One server: SaveService + Economy over memory stores (economy_spec pattern).
	local function newServer(opts: { [string]: any }?): any
		local o: any = opts or {}
		local w: any = {}
		w.sched = h.newScheduler()
		w.backing = o.backing or {}
		w.logs = {} :: { string }
		w.fired = {} :: { any }
		w.cfg = deepCopy(MonetizationConfig)
		w.cfg.Enabled = if o.enabled == nil then true else o.enabled
		if o.launchHide then
			w.cfg.LAUNCH_HIDE = true
		end
		local function log(line: string)
			table.insert(w.logs, line)
		end
		local tokens = 0
		w.save = SaveService.new({
			store = SaveService.newMemoryStore(w.backing),
			sessionId = "server-A",
			newToken = function(): string
				tokens += 1
				return "tok" .. tokens
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
			purchaseStore = SaveService.newMemoryStore({}),
			giftStore = SaveService.newMemoryStore({}),
			market = {
				ownsPass = function(): boolean
					return false
				end,
				promptPass = function() end,
				promptProduct = function() end,
				priceOf = function(): number?
					return nil
				end,
			},
			policy = function(): any
				return { ArePaidRandomItemsRestricted = false, IsPaidItemTradingAllowed = false }
			end,
			config = w.cfg,
			now = function(): number
				return SUNDAY_10
			end,
			clock = w.sched.clock,
			sleep = w.sched.sleep,
			spawn = w.sched.spawn,
			log = log,
			isStudio = function(): boolean
				return true
			end,
			fire = function(player: any, kind: string, payload: any)
				table.insert(w.fired, { user = player.UserId, kind = kind, payload = payload })
			end,
		})
		w.save.onLoaded(w.econ.playerLoaded)
		function w.join(userId: number): any
			local p = h.fakePlayer(userId)
			w.econ.playerAdded(p)
			w.sched.run(function()
				w.save.load(p)
			end)
			w.sched.advance(0)
			return p
		end
		function w.give(p: any, gears: number)
			assert(w.save.edit(p, "specGrant", function(d: any)
				d.gears += gears
			end))
		end
		function w.finish(p: any, rank: number, extra: { [string]: any }?): any
			local info: any = { trackId = "DINO-4", mode = "race", rank = rank, laps = 3, rings = 8, coins = 0 }
			for k, v in pairs(extra or {}) do
				info[k] = v
			end
			return w.econ.raceFinished(p, info)
		end
		return w
	end

	---------------------------------------------------------------------------------------------- roster

	h.test("roster: valid; 20 avatars per class; first playable = starter + 2 Cash + 1 Robux per class; hovercraft hidden", function()
		h.eq(AvatarRules.validate(), {}, "AvatarRules.validate")
		h.eq(AvatarConfig.ENABLED, true, "picker on in private builds")
		h.eq(AvatarConfig.SELL_UNBUILT, true, "everything on in private builds")
		for _, class in ipairs({ "plane", "car" }) do
			-- The AVATAR_ROSTER_V3 twenty, plus rows from the owner's own art (2026-10-21: plane_void_dragon).
			local ownerArt = { plane_void_dragon = true }
			local all = rowsBy(function(r)
				return r.acquire.kind ~= "starter" and not ownerArt[r.key]
			end, class)
			h.eq(#all, 20, class .. ": 20 roster avatars besides the hero starter")
			local fp = rowsBy(function(r)
				return r.fp == true
			end, class)
			local kinds = {}
			for _, r in ipairs(fp) do
				kinds[r.acquire.kind] = (kinds[r.acquire.kind] or 0) + 1
			end
			h.eq(kinds.starter, 1, class .. " FP starter")
			h.eq(kinds.cash, 2, class .. " FP Cash")
			h.eq(kinds.robux, 1, class .. " FP Robux mid")
			h.eq(AvatarRules.row(AvatarConfig.STARTER[class]).class, class)
			h.ok(AvatarRules.built(AvatarConfig.STARTER[class]), class .. " starter is the existing hero model")
		end
		h.ok(not AvatarRules.isClass("hovercraft"), "hovercraft picker slots hidden by config")
	end)

	h.test("roster: O8 pricing - common 1,500-2,500 Cash, rare 4,000-6,500, Robux mid 399/599/799 with nil ids, top tier earned only", function()
		for _, r in ipairs(AvatarConfig.ROWS) do
			local a = r.acquire
			if a.kind == "cash" then
				local band = AvatarConfig.CASH_BANDS[r.rarity]
				h.ok(band ~= nil and a.price >= band[1] and a.price <= band[2], r.key .. " Cash price in band")
			elseif a.kind == "robux" then
				h.ok(a.robux == 399 or a.robux == 599 or a.robux == 799, r.key .. " Robux label")
				h.eq(a.productId, nil, r.key .. " id stays nil (bound at runtime, never invented)")
				h.eq(a.liveAtLaunch, true, r.key .. " Robux-direct avatars are in the v3 live set")
				h.ok(r.rarity ~= "legendary", r.key)
			end
			if r.rarity == "legendary" then
				h.eq(a.kind, "earned", r.key .. " legendary is earned only")
			end
		end
		h.eq(AvatarRules.cashPrice("plane_hero"), nil, "starter is free")
		-- A forged row is caught.
		local bad = cfgCopy()
		table.insert(bad.ROWS, { key = "car_bad", class = "car", name = "Bad", rarity = "rare", acquire = { kind = "cash", price = 99999 } })
		table.insert(bad.ROWS, { key = "car_gold", class = "car", name = "Gold", rarity = "legendary", acquire = { kind = "robux", productKey = "x", robux = 799 } })
		local errs = AvatarRules.validate(bad)
		h.ok(#errs >= 2, "bad price and a sold legendary are rejected")
	end)

	---------------------------------------------------------------------------------------------- stat neutrality

	h.test("stat neutral: validate rejects any tuning field on a row, its acquire, ladder or mesh entry", function()
		for _, field in ipairs({ "speed", "topSpeed", "handling", "accel", "boostPower", "mass", "grip", "turnRate" }) do
			local c = cfgCopy()
			local r = c.ROWS[3]
			r[field] = 1.1
			h.ok(#AvatarRules.validate(c) > 0, field .. " on a row is rejected")
			local c2 = cfgCopy()
			c2.ROWS[3].acquire[field] = 2
			h.ok(#AvatarRules.validate(c2) > 0, field .. " inside acquire is rejected")
			local c3 = cfgCopy()
			c3.MESHES.car_hero[field] = 3
			h.ok(#AvatarRules.validate(c3) > 0, field .. " on a mesh entry is rejected")
		end
		local c4 = cfgCopy()
		c4.ROWS[2].ladder = { { id = "r1", kind = "reskin", name = "x", need = { races = 1 }, speedBonus = 1 } }
		h.ok(#AvatarRules.validate(c4) > 0, "a ladder step cannot carry power")
	end)

	h.test("stat neutral: handling code never reads the avatar; the builders' hull is built before and without it", function()
		for _, path in ipairs({
			"src/shared/PlaneConfig.luau",
			"src/shared/CarConfig.luau",
			"src/client/FlightController.luau",
			"src/client/CarController.luau",
			"src/server/AIRacers.luau",
			"src/server/ItemService.luau",
		}) do
			local src = h.readFile(path)
			h.ok(string.find(src, "Avatar", 1, true) == nil, path .. " does not mention avatars")
		end
		for _, path in ipairs({ "src/server/PlaneBuilder.luau", "src/server/kit/CarBuilder.luau" }) do
			local src = h.readFile(path)
			local a = string.find(src, 'hull.Name = "Hull"', 1, true)
			local b = string.find(src, "model.PrimaryPart = hull", 1, true)
			h.ok(a ~= nil and b ~= nil and b > a, path .. " hull block found")
			local hullBlock = string.sub(src, a :: number, b :: number)
			h.ok(string.find(string.lower(hullBlock), "avatar", 1, true) == nil, path .. " hull block never reads the avatar")
			local look = string.find(src, "AvatarRules.meshFor", 1, true)
			h.ok(look ~= nil and look > (b :: number), path .. " the avatar lookup comes after the hull")
		end
		-- A mesh descriptor only ever carries look fields.
		local _, m = AvatarRules.meshFor("plane_space_shark", "plane")
		h.eq(m.hero, true, "unbuilt avatar renders the hero model")
		local key, m2 = AvatarRules.meshFor("car_hero", "plane")
		h.eq(key, "plane_hero", "a car key on a plane falls back to the plane starter")
		h.eq(m2.hero, true)
		local key3 = AvatarRules.meshFor(nil, "car")
		h.eq(key3, "car_hero")
	end)

	h.test("registry hook: a registered mesh is used for that avatar only; validate keeps it to look fields", function()
		local c = cfgCopy()
		c.MESHES.plane_space_shark = { modelId = 123, length = 15, yaw = -90, offset = { 0, 0.3, 0 }, prop = false }
		local key, m = AvatarRules.meshFor("plane_space_shark", "plane", c)
		h.eq(key, "plane_space_shark")
		h.eq(m.modelId, 123)
		h.ok(AvatarRules.built("plane_space_shark", c))
		h.eq(AvatarRules.validate(c), {}, "a look-only mesh entry is valid")
		h.eq(AvatarRules.botAvatar("plane", function()
			return 0.99
		end, c), "plane_space_shark", "bots pick from built, non-earned rows (wired later)")
		h.eq(AvatarRules.botAvatar("car", function()
			return 0.5
		end), "car_hero", "with no new meshes, bots keep the hero")
	end)

	---------------------------------------------------------------------------------------------- ownership

	h.test("ownership: defaults own the starters and free rows and select the starters", function()
		local s = AvatarRules.defaultState()
		h.eq(s.selected, { plane = "plane_hero", car = "car_hero" })
		h.eq(s.owned.plane_hero, true)
		h.eq(s.owned.car_hero, true)
		h.eq(s.owned.plane_duck_biplane, true, "free rows owned by everyone")
		h.eq(s.owned.plane_space_shark, nil)
		h.eq(s.owned.plane_glow_moth, nil, "earned rows are not owned by default")
	end)

	h.test("ownership: settle repairs bad picks, keeps unknown owned keys, follows earned sources exactly", function()
		local s: any = {
			owned = { plane_space_shark = true, plane_future_thing = true, car_slime_monster = "yes", plane_glow_moth = true },
			selected = { plane = "car_slime_monster", car = "car_toy_tank" },
			progress = { plane_space_shark = { races = -3, wins = 2.7, keys = "x" }, [5] = {} },
			skin = { plane_space_shark = "r1", car_hero = "nope" },
		}
		AvatarRules.settle(s, { campaign = false, amulet = true })
		h.eq(s.selected.plane, "plane_hero", "a car key in the plane slot falls back")
		h.eq(s.selected.car, "car_hero", "an unowned pick falls back")
		h.eq(s.owned.plane_future_thing, true, "a row a newer build added is kept")
		h.eq(s.owned.car_slime_monster, nil, "a non-true value is dropped")
		h.eq(s.owned.plane_glow_moth, nil, "campaign row removed while the final boss is not beaten")
		h.eq(s.owned.plane_lantern_fly, true, "amulet rows owned with the amulet")
		h.eq(s.owned.car_thunder_beetle, true)
		h.eq(s.progress.plane_space_shark, { races = 0, wins = 2, keys = 0 })
		h.eq(s.skin.plane_space_shark, nil, "a locked step cannot be worn")
		h.eq(s.skin.car_hero, nil)
		local fresh = AvatarRules.settle(nil)
		h.eq(fresh.selected, { plane = "plane_hero", car = "car_hero" }, "nil settles to the defaults")
	end)

	---------------------------------------------------------------------------------------------- ladder

	h.test("ladder: counted per avatar; any one condition unlocks; tints after every reskin; reports each unlock once", function()
		local s = AvatarRules.defaultState()
		s.owned.plane_space_shark = true
		local got = {}
		for i = 1, 10 do
			for _, u in ipairs(AvatarRules.recordRace(s, "plane_space_shark", false)) do
				table.insert(got, i .. ":" .. u.step)
			end
		end
		h.eq(got, { "10:r1" }, "10 races unlock the first reskin, once")
		h.eq(AvatarRules.progressOf(s, "plane_hero"), { races = 0, wins = 0, keys = 0 }, "another avatar's ladder does not move")
		-- r2 by wins: 3 wins.
		local u2 = {}
		for _ = 1, 3 do
			for _, u in ipairs(AvatarRules.recordRace(s, "plane_space_shark", true)) do
				table.insert(u2, u.step)
			end
		end
		h.eq(u2, { "r2" }, "3 wins unlock Pro before 30 races")
		-- keys: 2 keys unlock r3.
		AvatarRules.recordKey(s, "plane_space_shark")
		local u3 = AvatarRules.recordKey(s, "plane_space_shark")
		h.eq(#u3, 1)
		h.eq(u3[1].step, "r3")
		h.eq(u3[1].kind, "reskin")
		h.eq(AvatarRules.recordRace(s, "plane_taco_jet", true), {}, "an unowned avatar never counts")
		h.eq(AvatarRules.recordRace(s, "nope", true), {}, "an unknown key never counts")
		local kinds = {}
		for _, step in ipairs(AvatarConfig.LADDER) do
			table.insert(kinds, step.kind)
		end
		h.eq(kinds, { "reskin", "reskin", "reskin", "tint", "tint" })
		local _, need = AvatarRules.nextStep("plane_space_shark", AvatarRules.progressOf(s, "plane_space_shark"))
		h.eq(need, "13/100 races or 3/15 wins or 2/3 keys")
		-- validate: a tint before a reskin is refused.
		local c = cfgCopy()
		c.ROWS[2].ladder = { { id = "t", kind = "tint", name = "T", need = { races = 1 } }, { id = "r", kind = "reskin", name = "R", need = { races = 2 } } }
		h.ok(#AvatarRules.validate(c) > 0)
	end)

	---------------------------------------------------------------------------------------------- server: purchase, pick, ladder

	h.test("purchase: Cash buys an avatar once, the ladder starts at zero, and the pick persists", function()
		local w = newServer()
		local p = w.join(701)
		local profile = w.save.get(p)
		h.eq(profile.avatars.selected, { plane = "plane_hero", car = "car_hero" })
		h.eq(p:GetAttribute("AvatarPlane"), "plane_hero")
		local r0 = w.econ.handleRequest(p, "BuyAvatar", "plane_space_shark")
		h.eq(r0.reason, "gears", "not enough Cash")
		w.give(p, 5000)
		local r1 = w.econ.handleRequest(p, "BuyAvatar", "plane_space_shark")
		h.ok(r1.ok, "bought")
		h.eq(r1.data.gears, 1000)
		h.eq(w.save.get(p).gears, 1000)
		h.eq(w.save.get(p).avatars.owned.plane_space_shark, true)
		h.eq(w.econ.handleRequest(p, "BuyAvatar", "plane_space_shark").reason, "owned", "never twice")
		h.eq(AvatarRules.progressOf(w.save.get(p).avatars, "plane_space_shark"), { races = 0, wins = 0, keys = 0 })
		local sel = w.econ.handleRequest(p, "SelectAvatar", "plane_space_shark")
		h.ok(sel.ok)
		h.eq(sel.data.class, "plane")
		h.eq(p:GetAttribute("AvatarPlane"), "plane_space_shark")
		h.eq(w.save.get(p).avatars.selected.car, "car_hero", "the other class keeps its pick")
		w.sched.advance(10)
		h.eq(w.backing.u_701.profile.avatars.selected.plane, "plane_space_shark", "saved")
		h.contains(w.logs, "buyAvatar user=701 key=plane_space_shark price=4000")
	end)

	h.test("purchase: refusals - unowned pick, earned, Robux-direct, unknown, store off, launch hide on an unbuilt row", function()
		local w = newServer()
		local p = w.join(702)
		w.give(p, 100000)
		h.eq(w.econ.handleRequest(p, "SelectAvatar", "car_toy_tank").reason, "notOwned")
		h.eq(w.econ.handleRequest(p, "BuyAvatar", "plane_glow_moth").reason, "earnedOnly")
		h.eq(w.econ.handleRequest(p, "BuyAvatar", "plane_galaxy_cat").reason, "robuxOnly")
		h.eq(w.econ.handleRequest(p, "BuyAvatar", "plane_nope").reason, "unknown")
		h.eq(w.econ.handleRequest(p, "BuyAvatar", 42).reason, "badRequest")
		h.eq(w.econ.handleRequest(p, "SelectAvatar", "plane_hero").ok, true, "re-selecting the pick is fine")
		h.eq(w.save.get(p).gears, 100000, "nothing charged")
		local off = newServer({ enabled = false })
		local q = off.join(703)
		h.eq(off.econ.handleRequest(q, "BuyAvatar", "plane_space_shark").reason, "disabled")
		h.ok(off.econ.handleRequest(q, "GetAvatars").ok, "the pick works with the store off")
		local hidden = newServer({ launchHide = true })
		local r = hidden.join(704)
		hidden.give(r, 100000)
		h.eq(hidden.econ.handleRequest(r, "BuyAvatar", "plane_space_shark").reason, "unavailable", "LAUNCH_HIDE hides unbuilt rows")
		local view = hidden.econ.handleRequest(r, "GetAvatars").data.classes.plane
		local keys = {}
		for _, v in ipairs(view) do
			table.insert(keys, v.key)
		end
		h.eq(keys, { "plane_hero", "plane_duck_biplane", "plane_void_dragon" }, "under LAUNCH_HIDE only built or owned rows list (the Void Dragon is built: VehicleV4Assets)")
	end)

	h.test("ladder: race finishes count on the avatar raced (spawn attribute), fire AvatarLadder, and wearing needs the unlock", function()
		local w = newServer()
		local p = w.join(705)
		p:SetAttribute("AvatarKey", "plane_hero")
		for _ = 1, 9 do
			w.finish(p, 5)
		end
		h.eq(w.econ.handleRequest(p, "WearSkin", "plane_hero", "r1").reason, "locked")
		local g = w.finish(p, 1)
		h.ok(g.avatarUnlocks ~= nil and g.avatarUnlocks[1].step == "r1", "the 10th finish unlocks Rally")
		local fired = nil
		for _, f in ipairs(w.fired) do
			if f.kind == "AvatarLadder" then
				fired = f.payload
			end
		end
		h.ok(fired ~= nil and fired.unlocks[1].avatarName == "Rally Biplane", "client told")
		h.eq(AvatarRules.progressOf(w.save.get(p).avatars, "plane_hero"), { races = 10, wins = 1, keys = 0 })
		h.ok(w.econ.handleRequest(p, "WearSkin", "plane_hero", "r1").ok)
		h.eq(w.save.get(p).avatars.skin.plane_hero, "r1")
		h.ok(w.econ.handleRequest(p, "WearSkin", "plane_hero", "").ok, "base look")
		h.eq(w.save.get(p).avatars.skin.plane_hero, nil)
		-- A solo time trial (always rank 1) counts the race but never a win, like the Win Pass countsModes.
		w.finish(p, 1, { mode = "timetrial" })
		h.eq(AvatarRules.progressOf(w.save.get(p).avatars, "plane_hero"), { races = 11, wins = 1, keys = 0 }, "time trial: race, no win")
		-- An attribute naming an avatar the player does not own counts nothing.
		p:SetAttribute("AvatarKey", "plane_toy_ptero")
		w.finish(p, 1)
		h.eq(AvatarRules.progressOf(w.save.get(p).avatars, "plane_toy_ptero"), { races = 0, wins = 0, keys = 0 })
		-- Keys: one per new key, on the avatar driven.
		p:SetAttribute("AvatarKey", "plane_hero")
		w.econ.avatarKeyFound(p)
		h.eq(AvatarRules.progressOf(w.save.get(p).avatars, "plane_hero").keys, 1)
	end)

	---------------------------------------------------------------------------------------------- old profiles

	h.test("old profiles: a v2 record with no avatars loads with starters owned and selected; its data is untouched", function()
		local backing: any = {}
		local old: any = SaveService.newProfile()
		old.avatars = nil
		old.gears = 777
		old.cosmetics.owned.Livery_Sunset = true
		backing.u_706 = { profile = old }
		local w = newServer({ backing = backing })
		local p = w.join(706)
		local prof = w.save.get(p)
		h.eq(prof.gears, 777)
		h.eq(prof.cosmetics.owned.Livery_Sunset, true)
		h.eq(prof.avatars.selected, { plane = "plane_hero", car = "car_hero" })
		h.eq(prof.avatars.owned.plane_hero, true)
		h.eq(prof.avatars.owned.car_ladybug_kart, true)
		h.eq(prof.avatars.progress, {})
		h.eq(prof.version, SaveService.CURRENT_VERSION, "no version bump needed")
	end)

	h.test("old profiles: pre-versioned and malformed avatars records are repaired, never fatal; earned rows follow progression", function()
		local m0 = SaveService.migrate({ tokens = { ["DINO-4"] = true } })
		h.eq(m0.avatars.selected.plane, "plane_hero", "v0 record")
		local raw: any = SaveService.newProfile()
		raw.avatars = { owned = "lots", selected = { plane = 5 }, progress = { car_hero = { races = "10" } }, skin = 3 }
		local m1 = SaveService.migrate(raw)
		h.eq(m1.avatars.owned.car_hero, true)
		h.eq(m1.avatars.selected.plane, "plane_hero")
		h.eq(m1.avatars.progress.car_hero, { races = 0, wins = 0, keys = 0 })
		h.eq(m1.avatars.skin, {})
		local won: any = SaveService.newProfile()
		won.finalBoss = true
		local m2 = SaveService.migrate(won)
		h.eq(m2.avatars.owned.plane_glow_moth, true, "the final-boss avatar is owned with the final boss")
		-- An economy edit can neither grant nor strip an earned avatar.
		local w = newServer()
		local p = w.join(707)
		h.ok(w.save.edit(p, "forge", function(d: any)
			d.avatars.owned.plane_glow_moth = true
		end))
		h.eq(w.save.get(p).avatars.owned.plane_glow_moth, nil, "derive takes it back")
	end)

	---------------------------------------------------------------------------------------------- UI rules

	h.test("garage: VEHICLES is the first tab; row buttons by ownership and acquisition", function()
		h.eq(GarageModel.TABS[1].id, "vehicles")
		h.eq(GarageModel.TABS[1].label, "VEHICLES")
		local s = AvatarRules.defaultState()
		s.owned.car_slime_monster = true
		local rows = AvatarRules.view(s, "car", 4200, false)
		local by = {}
		for _, v in ipairs(rows) do
			by[v.key] = v
		end
		h.eq(GarageModel.avatarAction(by.car_hero), { label = "SELECTED", action = nil, tone = "on" })
		h.eq(GarageModel.avatarAction(by.car_slime_monster).action, "select")
		h.eq(GarageModel.avatarAction(by.car_neon_skater), { label = "BUY 4,500", action = "buy", tone = "dim" })
		h.eq(GarageModel.avatarAction(by.car_pizza_van).tone, "buy")
		h.eq(GarageModel.avatarAction(by.car_retro_rocket), { label = "R$ 399", action = "robux", tone = "robux" })
		h.eq(GarageModel.avatarAction(by.car_crown_chariot), { label = "EARN", action = nil, tone = "dim" })
		h.contains({ GarageModel.avatarSub(by.car_slime_monster) }, "NEXT RALLY: 0/10 races")
		h.contains({ GarageModel.avatarSub(by.car_crown_chariot) }, "STORM VENDOR")
		h.contains({ GarageModel.avatarSub(by.car_neon_skater) }, "MODEL SOON")
		for _, v in ipairs(rows) do
			for _, word in ipairs({ "livery", "Livery", "LIVERY" }) do
				h.ok(string.find(GarageModel.avatarSub(v), word, 1, true) == nil, v.key .. " never says livery")
			end
		end
	end)

	h.test("pre-race pick: hub only, lobby or slowed on an apron, owned of the track's class, needs two to swap", function()
		local base = { enabled = true, mode = "hub", switching = false, lobbyClass = nil, apronClass = "plane", speed = 10, owned = 2 }
		local show, class = VehiclePickRules.decide(base)
		h.eq({ show, class }, { true, "plane" })
		local fast = table.clone(base)
		fast.speed = 90
		h.eq((VehiclePickRules.decide(fast)), false, "a drive-through never pops it")
		local lobby = table.clone(fast)
		lobby.lobbyClass = "car"
		h.eq((VehiclePickRules.decide(lobby)), false, "another player's lobby never pops the strip")
		lobby.lobbyMine = true
		h.eq({ VehiclePickRules.decide(lobby) }, { true, "car" }, "own lobby wins, at any speed")
		local client = h.readFile("src/client/VehiclePick.luau")
		h.contains(client, "LobbyOpenerId", "the client gates the lobby strip on the opener")
		h.contains(h.readFile("src/server/TrackDirector.luau"), "\"LobbyOpenerId\", player.UserId", "the server publishes the opener id")
		local race = table.clone(base)
		race.mode = "race"
		h.eq((VehiclePickRules.decide(race)), false, "never in a race")
		local one = table.clone(base)
		one.owned = 1
		h.eq((VehiclePickRules.decide(one)), false, "nothing to swap")
		local closed = table.clone(base)
		closed.dismissed = true
		h.eq((VehiclePickRules.decide(closed)), false)
		local arch = CFrame.new(0, 11, 0) -- LookVector -Z points out of the plaza: the plaza is +Z
		h.ok(VehiclePickRules.onApron(Vector3.new(4, 3, 30), arch), "in front of the arch")
		h.ok(not VehiclePickRules.onApron(Vector3.new(4, 3, -30), arch), "beyond the veil")
		h.ok(not VehiclePickRules.onApron(Vector3.new(60, 3, 30), arch), "off to the side")
		h.ok(not VehiclePickRules.onApron(Vector3.new(0, 3, 120), arch), "far back on the plaza")
	end)

	h.test("pre-race pick: docked chip and strip clear of the road band, the hub bar, the left column and the controls", function()
		local VIEWPORTS = { { 1920, 1080, "desktop" }, { 1366, 768, "desktop" }, { 844, 390, "touch" }, { 740, 360, "touch" } }
		for _, vp in ipairs(VIEWPORTS) do
			local vw, vh, kind = vp[1], vp[2], vp[3]
			local ins = { left = 0, right = 0, top = 0, bottom = 0 }
			local nav = HudLayoutRules.fallbackNav(vw, vh)
			local rects = HudLayoutRules.compute(vw, vh, ins, nav, kind)
			local S = HudLayoutRules.scale(vh, kind)
			for _, key in ipairs({ "vehicleChip", "vehicleStrip" }) do
				local r = rects[key]
				local tag = string.format("%dx%d %s", vw, vh, key)
				h.ok(r ~= nil and r.h >= HudLayoutRules.VEHICLE_MIN_TOUCH and (kind == "touch" or r.h >= 44), tag .. " is a touch target (44 px; 36 on the shortest phones)")
				h.ok(r.x >= 0 and r.y >= 0 and r.x + r.w <= vw and r.y + r.h <= vh, tag .. " on screen")
				h.ok(r.x + r.w <= 0.30 * vw, tag .. " left of the road band (never over the kart)")
				h.ok(not HudLayoutRules.overlap(r, HudLayoutRules.roadBand(vw, vh)), tag .. " clear of the road band")
				for _, other in ipairs({ "nav", "leftColumn", "hubBar", "hubLaneA", "hubLaneB", "respawn", "steerPad", "rightZone", "hintChip", "autoPill", "position", "lapChip" }) do
					local o = rects[other]
					if o and o.w > 0 and o.h > 0 then
						h.ok(not HudLayoutRules.overlap(r, o), tag .. " clear of " .. other)
					end
				end
			end
			local cw, ch = VehiclePickRules.cardSize(rects.vehicleStrip, S)
			h.ok(cw >= 88 and ch >= HudLayoutRules.VEHICLE_MIN_TOUCH, "cards are touch targets")
			h.ok(ch <= rects.vehicleStrip.h, "cards fit the strip")
		end
		local hidden = { enabled = true, mode = "hub", switching = false, apronClass = "plane", speed = 10, owned = 2, overlay = true }
		h.eq((VehiclePickRules.decide(hidden)), false, "hidden while the Garage is open")
		local ownLobby = { enabled = true, mode = "hub", switching = false, lobbyClass = "plane", lobbyMine = true, speed = 90, owned = 2, overlay = false }
		h.eq((VehiclePickRules.decide(ownLobby)), true, "the player's own filling lobby still offers the pick")
		local vpSrc = h.readFile("src/client/VehiclePick.luau")
		h.ok(not string.find(vpSrc, "local overlay = type(goAt)", 1, true), "a lobby / countdown never hides the pick (that would kill the own-lobby pick)")
		h.ok(VehiclePickRules.shouldCollapse(0, 1, true), "folds after a pick")
		h.ok(VehiclePickRules.shouldCollapse(0, VehiclePickRules.COLLAPSE_SECONDS, false), "folds after the timeout")
		h.ok(not VehiclePickRules.shouldCollapse(0, 1, false), "stays open meanwhile")
		local client = h.readFile("src/client/VehiclePick.luau")
		h.contains(client, "VEHICLE: %s", "collapsed chip reads VEHICLE: <name>")
	end)

	---------------------------------------------------------------------------------------------- owner art: Void Dragon

	h.test("void dragon: legendary plane row earned from the Storm vendor, stat-neutral, MODEL SOON until its id lands", function()
		local r = AvatarRules.row("plane_void_dragon")
		h.ok(r ~= nil, "row exists")
		h.eq(r.class, "plane")
		h.eq(r.name, "VOID DRAGON")
		h.eq(r.rarity, "legendary")
		h.eq(r.acquire, { kind = "earned", source = "storm" })
		h.eq(AvatarRules.validate(), {}, "validate passes with the row")
		-- The creature entry carries look fields only; validate scans it when registered.
		local c = cfgCopy()
		local entry = table.clone(AvatarConfig.VOID_DRAGON)
		entry.modelId = 1234
		c.MESHES.plane_void_dragon = entry
		h.eq(AvatarRules.validate(c), {}, "the creature mesh entry has no tuning field")
		h.eq(entry.kind, "creature")
		h.eq(entry.clips, "VoidDragon")
		h.eq(entry.yaw, 180, "rigged GLBs import yawed 180")
		h.eq(entry.prop, false, "no propeller")
		h.ok(type(entry.seat) == "table" and #entry.seat == 3, "seat offset")
		local key, mesh = AvatarRules.meshFor("plane_void_dragon", "plane", c)
		h.eq(key, "plane_void_dragon")
		h.eq(mesh.kind, "creature")
		-- Without the art lane's id (no VehicleV4Assets module / no void_dragon id) the row is unbuilt: hero plane.
		if AvatarConfig.MESHES.plane_void_dragon == nil then
			h.eq(AvatarRules.built("plane_void_dragon"), false, "MODEL SOON")
			local k2, m2 = AvatarRules.meshFor("plane_void_dragon", "plane")
			h.eq(k2, "plane_void_dragon")
			h.eq(m2.hero, true, "renders the hero plane until the mesh lands")
		end
		h.eq((AvatarRules.meshFor("plane_void_dragon", "car")), "car_hero", "never on a car track")
		local defaults = AvatarRules.settle(AvatarRules.defaultState(), { storm = false })
		h.eq(defaults.owned.plane_void_dragon, nil, "nobody owns it by default")
		h.eq(AvatarRules.settle(AvatarRules.defaultState(), { storm = true }).owned.plane_void_dragon, true, "the storm source grants it")
	end)

	h.test("admin vehicles switch (D22a): owns() branches first; overlay is a copy, the saved table is untouched", function()
		local saved = AvatarRules.defaultState()
		h.eq(AvatarRules.owns(saved, "plane_void_dragon", false), false)
		h.eq(AvatarRules.owns(saved, "plane_void_dragon", nil), false)
		h.eq(AvatarRules.owns(saved, "plane_void_dragon", true), true, "switch on: owned")
		h.eq(AvatarRules.owns(saved, "plane_nope", true), false, "unknown rows never")
		h.eq(AvatarRules.owns(saved, "plane_hero", false), true)
		local before = deepCopy(saved)
		h.ok(AvatarRules.overlay(saved, false) == saved, "switch off: the saved table itself")
		local ov = AvatarRules.overlay(saved, true, { plane = "plane_void_dragon", car = "plane_hero" })
		h.ok(ov ~= saved)
		h.eq(ov.owned.plane_void_dragon, true)
		h.eq(ov.owned.car_crown_chariot, true)
		h.eq(ov.selected.plane, "plane_void_dragon", "runtime pick over the saved pick")
		h.eq(ov.selected.car, "car_hero", "a pick of the wrong class is ignored")
		h.eq(saved, before, "the saved state is unchanged")
		h.eq((AvatarRules.canSelect(ov, "plane_void_dragon")), true)
		h.eq(select(2, AvatarRules.canSelect(saved, "plane_void_dragon")), "notOwned")
	end)

	h.test("admin vehicles switch (D22a): the admin owns and selects plane_void_dragon for a plane track; a non-admin does not; nothing saved", function()
		local TrackInfo = h.require("src/shared/TrackInfo.luau")
		-- Every flying track uses the plane class, so the plane picker (and this row) serves all of them.
		local flying = 0
		for id, info in pairs(TrackInfo.BY_ID) do
			if info.vehicle == "plane" then
				flying += 1
				h.eq((AvatarRules.meshFor("plane_void_dragon", info.vehicle)), "plane_void_dragon", id .. " offers the dragon")
			end
		end
		h.ok(flying >= 3, "DINO-4, SNOW-1, FOREST-1 fly")
		local AdminService = h.require("src/server/AdminService.luau")
		local AdminConfig = h.require("src/server/AdminConfig.luau")
		local AvatarSelect = h.require("src/server/AvatarSelect.luau")
		local w = newServer()
		local admin = w.join(AdminConfig.ADMIN_USER_ID)
		local other = w.join(705)
		local players = { [admin.UserId] = admin, [other.UserId] = other }
		local adminLogs: { string } = {}
		local svc = AdminService.new({
			isStudio = function(): boolean
				return false
			end,
			attr = function(): any
				return nil
			end,
			playerByUserId = function(id: number): any
				return players[id]
			end,
			award = function(): string
				return "noop"
			end,
			economy = function(): any
				return w.econ
			end,
			keyForId = function(): string?
				return nil
			end,
			adminStart = function(): (boolean, string)
				return false, "spec"
			end,
			republish = function() end,
			stormForce = function(): (boolean, string)
				return false, "spec"
			end,
			clock = w.sched.clock,
			log = function(line: string)
				table.insert(adminLogs, line)
			end,
			vehiclesChanged = function(p: any, on: boolean)
				if not on then
					AvatarSelect.clearRuntime(p)
				end
			end,
		})
		local savedLog = AvatarSelect.log
		local savedGet = SaveService.get
		AvatarSelect.adminVehicles = svc.vehiclesOpen
		AvatarSelect.log = function(line: string)
			table.insert(adminLogs, line)
		end
		SaveService.get = function(p: any): any
			return w.save.get(p)
		end
		local ok, err = pcall(function()
			h.eq(svc.flagsOf(admin).vehicles, true, "ON by default for him")
			-- Admin: listed as owned, selectable, and the spawn builds it on a plane track.
			local view = w.econ.handleRequest(admin, "GetAvatars")
			h.ok(view.ok)
			local row
			for _, v in ipairs(view.data.classes.plane) do
				if v.key == "plane_void_dragon" then
					row = v
				end
			end
			h.ok(row ~= nil and row.owned == true, "admin: listed as owned")
			local sel = w.econ.handleRequest(admin, "SelectAvatar", "plane_void_dragon")
			h.ok(sel.ok, "admin: selectable")
			h.eq(sel.data.runtime, true, "kept at runtime")
			h.eq(AvatarSelect.forPlayer(admin, "plane"), "plane_void_dragon", "admin: his plane spawns as the dragon")
			h.eq(AvatarSelect.forPlayer(admin, "car"), "car_hero", "the car pick is untouched")
			h.eq(w.econ.handleRequest(admin, "GetAvatars").data.selected.plane, "plane_void_dragon")
			h.eq(w.save.get(admin).avatars.owned.plane_void_dragon, nil, "never written to the save")
			h.eq(w.save.get(admin).avatars.selected.plane, "plane_hero", "the saved pick is unchanged")
			w.sched.advance(10)
			local stored = w.backing["u_" .. admin.UserId]
			h.ok(stored == nil or stored.profile.avatars.owned.plane_void_dragon == nil, "nothing in the store")
			h.contains(adminLogs, "[SkyRally][ADMIN] kind=admin action=vehicle user=" .. admin.UserId .. " result=select key=plane_void_dragon class=plane saved=false")
			-- A saved (owned) pick takes the normal path and drops the runtime pick.
			h.ok(w.econ.handleRequest(admin, "SelectAvatar", "plane_duck_biplane").ok)
			h.eq(w.save.get(admin).avatars.selected.plane, "plane_duck_biplane", "owned pick saved as usual")
			h.eq(admin:GetAttribute("AvatarPlane"), "plane_duck_biplane", "the picks cue left the runtime key")
			h.eq(AvatarSelect.forPlayer(admin, "plane"), "plane_duck_biplane")
			h.ok(w.econ.handleRequest(admin, "SelectAvatar", "plane_void_dragon").ok)
			-- Switch off: his saved garage again, the runtime pick gone.
			local r = svc.handle(admin, "/admin vehicles off")
			h.eq(r.ok, true)
			h.eq(r.state.vehicles, false)
			h.contains(adminLogs, "[SkyRally][ADMIN] kind=admin action=vehicles user=" .. admin.UserId .. " result=set on=false")
			h.eq(AvatarSelect.forPlayer(admin, "plane"), "plane_duck_biplane", "off: the saved pick")
			h.eq(admin:GetAttribute("AvatarPlane"), "plane_duck_biplane", "off: the picks cue is back on the saved pick")
			h.eq(w.econ.handleRequest(admin, "SelectAvatar", "plane_void_dragon").reason, "notOwned", "off: not owned")
			-- Non-admin: not owned, not selectable, spawns his own pick; the switch command answers nil.
			h.eq(svc.vehiclesOpen(other), false)
			h.eq(svc.handle(other, "/admin vehicles on"), nil)
			local oview = w.econ.handleRequest(other, "GetAvatars")
			for _, v in ipairs(oview.data.classes.plane) do
				if v.key == "plane_void_dragon" then
					h.eq(v.owned, false, "non-admin: not owned")
					h.eq(v.note, "STORM VENDOR")
				end
			end
			h.eq(w.econ.handleRequest(other, "SelectAvatar", "plane_void_dragon").reason, "notOwned", "non-admin: refused")
			h.eq(AvatarSelect.forPlayer(other, "plane"), "plane_hero")
		end)
		AvatarSelect.adminVehicles = nil
		AvatarSelect.log = savedLog
		SaveService.get = savedGet
		if not ok then
			error(err, 0)
		end
	end)
end
