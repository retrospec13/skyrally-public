--!strict
-- Save operations (systems audit v32 save-ops: T1-14 lock ttl + "Saving paused" + owner save tools, T2-2 background
-- final save). Everything runs on the harness scheduler (fake seconds) against tools/tests/fixtures/FakeDataStore.luau:
-- per-key write throttling (6 s), a request budget, injected outages and a racing server between transform and commit.
-- Run: tools/tests/run_lune_tests.sh tools/tests/save_ops_spec.luau

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
	-- Synthetic server policy for authorized-admin behavior; public defaults tested separately.
	h.fake("src/server/AdminConfig.luau", h.require("src/server/AdminConfig.luau").forUserId(90000001))
	local SaveService = h.require("src/server/SaveService.luau")
	local SaveLockRules = h.require("src/shared/SaveLockRules.luau")
	local SaveAdminRules = h.require("src/shared/SaveAdminRules.luau")
	local SaveAdmin = h.require("src/server/SaveAdmin.luau")
	local AdminService = h.require("src/server/AdminService.luau")
	local AdminConfig = h.require("src/server/AdminConfig.luau")
	local MonetizationConfig = h.require("src/shared/MonetizationConfig.luau")
	local LeaderboardRules = h.require("src/shared/LeaderboardRules.luau")
	local Fake = h.require("tools/tests/fixtures/FakeDataStore.luau")

	local T0 = 1800000000 -- a fixed wall clock (2027-01-15) so UTC day keys are stable

	-- One server: a SaveService on a shared fake store (default config unless overridden: 90 s ttl, 30 s heartbeat).
	local function server(sched: any, store: any, sessionId: string, config: any?): any
		local logs: { string } = {}
		local issued = 0
		local svc = SaveService.new({
			store = store,
			sessionId = sessionId,
			newToken = function(): string
				issued += 1
				return sessionId .. "-load" .. tostring(issued)
			end,
			now = sched.clock,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = function(line: string)
				table.insert(logs, line)
			end,
			random = function(): number
				return 0.5
			end,
			config = config,
		})
		return { svc = svc, logs = logs, sched = sched, store = store }
	end

	-- A view of one shared fake store with its own outage switch (one server's network failing, the other's fine).
	local function view(inner: any): any
		local v: any = { kind = "view", failing = false, calls = 0 }
		function v.update(key: string, transform: (any) -> any, userIds: { number }?): (boolean, string?)
			v.calls += 1
			if v.failing then
				return false, "502: this server cannot reach DataStore (fake)"
			end
			return inner.update(key, transform, userIds)
		end
		v.budget = inner.budget
		return v
	end

	local function load(env: any, p: any): (any, string)
		return env.sched.run(function()
			return env.svc.load(p)
		end)
	end

	local function startLoad(env: any, p: any): any
		local box: any = {}
		env.sched.spawn(function()
			box.result = table.pack(env.svc.load(p))
		end)
		return box
	end

	local function release(env: any, p: any): boolean
		return env.sched.run(function()
			return env.svc.release(p)
		end)
	end

	---------------------------------------------------------------- SaveLockRules

	h.test("lock rules: holder-declared ttl, legacy 180 s, clamped, free/held/stale and clock skew", function()
		h.eq(SaveLockRules.ttl({ id = "a", lockedAt = 0 }), 180, "a lock from before T1-14 keeps 180 s")
		h.eq(SaveLockRules.ttl({ ttl = 90 }), 90)
		h.eq(SaveLockRules.ttl({ ttl = 1 }), 30, "clamped up")
		h.eq(SaveLockRules.ttl({ ttl = 1e9 }), 600, "clamped down")
		h.eq(SaveLockRules.ttl({ ttl = 0 / 0 }), 180, "NaN is legacy")
		h.eq(SaveLockRules.state(nil, 100).state, "free")
		h.eq(SaveLockRules.state({ profile = {} }, 100).state, "free")
		local held = SaveLockRules.state({ session = { id = "job1", lockedAt = 100, ttl = 90 } }, 150)
		h.eq(held, { state = "held", holder = "job1", age = 50, ttl = 90, remaining = 40 })
		h.eq(SaveLockRules.state({ session = { id = "job1", lockedAt = 100, ttl = 90 } }, 190).state, "stale")
		h.eq(SaveLockRules.state({ session = { id = "job1", lockedAt = 500, ttl = 90 } }, 100).state, "held", "a lockedAt in the future is fresh")
		h.eq(SaveService.DEFAULT_CONFIG.lockTimeout, 90)
		h.eq(SaveService.DEFAULT_CONFIG.autosaveInterval, 30)
		h.ok(SaveService.DEFAULT_CONFIG.lockTimeout >= 3 * SaveService.DEFAULT_CONFIG.autosaveInterval, "a holder may miss two heartbeats")
	end)

	---------------------------------------------------------------- T1-14: crash lock

	h.test("T1-14: a crashed server's lock clears in 90 s (not 180); the player sees Saving paused with the seconds left", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		local a = server(sched, store, "job-A")
		local b = server(sched, store, "job-B")
		local pa, pb = h.fakePlayer(201), h.fakePlayer(201)
		load(a, pa)
		h.eq(store.data.u_201.session.ttl, 90, "the holder declares its ttl")
		a.svc.award(pa, "token", "race:DINO-4", "finish")
		sched.advance(7)
		h.ok(store.data.u_201.profile.tokens["race:DINO-4"], "saved before the crash")
		-- job-A crashes: no heartbeat, no release, no BindToClose. The player rejoins on job-B 10 s later.
		sched.advance(10)
		local box = startLoad(b, pb)
		sched.advance(1)
		h.eq(pb:GetAttribute("SaveState"), "loading")
		h.contains(pb:GetAttribute("SaveMessage"), "Saving paused")
		h.contains(pb:GetAttribute("SaveMessage"), "Back in about 80 s", "79 s left (last refresh at +6 s), rounded up to 5 s")
		h.eq(pb:GetAttribute("SaveResumeIn"), 79)
		h.eq(b.svc.award(pb, "key", "DINO", "keyPickup"), "queued", "awards wait for the load")
		sched.advance(40)
		h.ok(pb:GetAttribute("SaveResumeIn") <= 40, "the countdown moves")
		h.eq(box.result, nil, "still waiting at 58 s")
		sched.advance(40)
		h.ok(box.result and box.result[2] == "ok", "taken over about 90 s after the last refresh")
		h.eq(pb:GetAttribute("SaveResumeIn"), nil, "notice data cleared")
		h.eq(store.data.u_201.session.id, "job-B")
		h.eq(store.data.u_201.lastTakeover.from, "job-A", "the takeover is recorded for inspect")
		h.contains(b.logs, "took over stale lock from job-A")
		sched.advance(7)
		h.ok(store.data.u_201.profile.keys.DINO, "the queued key landed after the takeover")
		h.eq(store.throttled, 0, "no write ever hit the per-key throttle")
	end)

	h.test("T1-14: a lock written by an older build (no ttl) keeps its 180 s, so a live old server is never robbed mid-publish", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		store.seed("u_202", { profile = SaveService.newProfile(), session = { id = "old-build", token = "t-old", lockedAt = T0 }, savedAt = T0 })
		local b = server(sched, store, "job-B")
		local pb = h.fakePlayer(202)
		local box = startLoad(b, pb)
		sched.advance(120)
		h.eq(box.result, nil, "still the old server's at 120 s (a 90 s rule would have stolen it)")
		h.contains(pb:GetAttribute("SaveMessage"), "Saving paused")
		sched.advance(70)
		h.ok(box.result and box.result[2] == "ok", "taken over once 180 s passed")
		h.contains(b.logs, "ttl 180s")
	end)

	h.test("T1-14: a live server's 30 s heartbeat keeps its lock for an hour; a second server never takes it", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		local a = server(sched, store, "job-A")
		local b = server(sched, store, "job-B")
		local pa, pb = h.fakePlayer(203), h.fakePlayer(203)
		load(a, pa)
		local box = startLoad(b, pb)
		for _ = 1, 120 do
			sched.advance(30)
			a.svc.heartbeat()
		end
		sched.advance(1)
		h.eq(store.data.u_203.session.id, "job-A")
		h.ok(box.result == nil or box.result[2] == "error", "B never loaded A's live profile")
		h.eq(b.svc.get(pb), nil)
		h.eq(store.throttled, 0)
	end)

	---------------------------------------------------------------- two servers racing

	h.test("race: the old holder's late heartbeat lands between a takeover's transform and commit -> the takeover re-reads and waits", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		local a = server(sched, store, "job-A")
		local b = server(sched, store, "job-B")
		local pa, pb = h.fakePlayer(204), h.fakePlayer(204)
		load(a, pa)
		sched.advance(95) -- A stalled past its ttl
		-- B's takeover transform runs, then A's delayed heartbeat commits first.
		store.interleave = function(key: string)
			sched.spawn(function()
				a.svc.heartbeat()
			end)
		end
		local box = startLoad(b, pb)
		sched.advance(1)
		h.eq(store.data.u_204.session.id, "job-A", "A's refresh won; B's transform re-ran and saw a fresh lock")
		h.eq(box.result, nil, "B waits")
		h.eq(a.svc.award(pa, "token", "race:DINO-4", "finish"), "awarded", "A still writes")
		sched.advance(7)
		h.ok(store.data.u_204.profile.tokens["race:DINO-4"])
		h.eq(pa:GetAttribute("SaveState"), "ok", "A never lost its session")
	end)

	h.test("race: two servers take one stale lock at the same moment -> exactly one holder, the other waits", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		store.seed("u_205", { profile = SaveService.newProfile(), session = { id = "crashed", token = "t0", lockedAt = T0 - 500, ttl = 90 }, savedAt = T0 - 500 })
		local b = server(sched, store, "job-B")
		local c = server(sched, store, "job-C")
		local pb, pc = h.fakePlayer(205), h.fakePlayer(205)
		local boxC: any = nil
		store.interleave = function(key: string)
			boxC = startLoad(c, pc) -- C's whole takeover commits inside B's UpdateAsync
		end
		local boxB = startLoad(b, pb)
		sched.advance(1)
		h.ok(boxC and boxC.result and boxC.result[2] == "ok", "C took it")
		h.eq(boxB.result, nil, "B's transform re-ran on C's record and now waits")
		h.eq(store.data.u_205.session.id, "job-C")
		h.eq(b.svc.get(pb), nil)
		h.contains(b.logs, "held by job-C")
		-- Only the holder's writes land.
		c.svc.award(pc, "key", "DINO", "keyPickup")
		sched.advance(7)
		h.ok(store.data.u_205.profile.keys.DINO)
		h.eq(b.svc.award(pb, "key", "SNOW", "keyPickup"), "queued", "B has no session to write with")
	end)

	---------------------------------------------------------------- throttling

	h.test("throttle: award bursts, edits, heartbeats and leave never write one key twice inside 6 s", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		local a = server(sched, store, "job-A")
		local p = h.fakePlayer(206)
		load(a, p)
		for i = 1, 20 do
			a.svc.edit(p, "spec", function(d: any)
				d.gears += 1
			end)
			if i % 5 == 0 then
				a.svc.heartbeat()
			end
			sched.advance(0.5)
		end
		a.svc.award(p, "token", "race:DINO-4", "finish")
		p:leave()
		h.ok(release(a, p), "final save landed")
		h.eq(store.throttled, 0, "the write cooldown kept every write 6 s apart")
		h.eq(store.data.u_206.profile.gears, 20)
		h.eq(store.data.u_206.session, nil)
	end)

	h.test("throttle: an exhausted request budget delays writes instead of losing them", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock, budgetPerMinute = 3 })
		local a = server(sched, store, "job-A")
		local p = h.fakePlayer(207)
		load(a, p) -- 1 of 3
		a.svc.award(p, "token", "race:DINO-4", "finish")
		sched.advance(7) -- 2 of 3
		a.svc.award(p, "key", "DINO", "keyPickup")
		sched.advance(7) -- 3 of 3
		a.svc.award(p, "battle", "DINO", "battleWin")
		sched.advance(70)
		h.ok(store.data.u_207.profile.battles.DINO, "the write waited for the next minute's budget")
		h.contains(a.logs, "request budget exhausted; waiting")
	end)

	---------------------------------------------------------------- T2-2: background final save

	h.test("T2-2: a final save that fails every attempt keeps retrying after the leave and lands when DataStore recovers", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		local a = server(sched, store, "job-A")
		local p = h.fakePlayer(208)
		load(a, p)
		sched.advance(7)
		store.failing = true
		a.svc.award(p, "token", "race:DINO-4", "finish")
		p:leave()
		h.eq(release(a, p), false, "the leave itself could not save")
		h.contains(a.logs, "final save queued for background retry user=208")
		h.eq(a.svc.orphans(), { 208 })
		sched.advance(120)
		h.eq(store.data.u_208.profile.tokens["race:DINO-4"], nil, "still down")
		store.failing = false
		sched.advance(60)
		h.ok(store.data.u_208.profile.tokens["race:DINO-4"], "the background retry saved it")
		h.eq(store.data.u_208.session, nil, "and unlocked")
		h.contains(a.logs, "background final save landed user=208")
		h.eq(a.svc.orphans(), {})
		-- The player's next server loads the saved award at once.
		local b = server(sched, store, "job-B")
		local pb = h.fakePlayer(208)
		local snap = load(b, pb)
		h.ok(snap and snap.tokens["race:DINO-4"])
	end)

	h.test("T2-2: a same-server rejoin while the final save is still retrying adopts the unsaved snapshot", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		local v = view(store)
		local a = server(sched, v, "job-A")
		local p = h.fakePlayer(209)
		load(a, p)
		sched.advance(7)
		v.failing = true
		a.svc.award(p, "token", "race:DINO-4", "finish")
		p:leave()
		release(a, p)
		h.eq(a.svc.orphans(), { 209 })
		v.failing = false
		local p2 = h.fakePlayer(209)
		local snap = load(a, p2)
		h.ok(snap and snap.tokens["race:DINO-4"], "the rejoin starts from the unsaved snapshot, not the older record")
		h.contains(a.logs, "adopted unsaved final snapshot user=209")
		h.ok(store.data.u_209.profile.tokens["race:DINO-4"], "and the load write persisted it")
		h.eq(a.svc.orphans(), {}, "the background retry stopped")
		sched.advance(300)
		h.eq(store.data.u_209.session.token, "job-A-load2", "nothing from the old session ever wrote over the rejoin")
		h.eq(h.count(a.logs, "DROPPED"), 0)
	end)

	h.test("T2-2: a shutdown while a same-server rejoin is still loading writes the adopted snapshot", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		local v = view(store)
		local a = server(sched, v, "job-A")
		local p = h.fakePlayer(213)
		load(a, p)
		sched.advance(7)
		v.failing = true
		a.svc.award(p, "token", "race:DINO-4", "finish")
		p:leave()
		release(a, p)
		h.eq(a.svc.orphans(), { 213 })
		local p2 = h.fakePlayer(213)
		startLoad(a, p2) -- claims the orphan, then fails while DataStore is unreachable
		sched.advance(1)
		h.eq(a.svc.orphans(), {}, "the rejoin holds the snapshot now")
		v.failing = false
		local saved = sched.run(function()
			return a.svc.flushAll(25)
		end)
		h.ok(saved, "the adopted snapshot got its shutdown write")
		h.ok(store.data.u_213.profile.tokens["race:DINO-4"], "nothing earned before the leave is lost")
		h.contains(a.logs, "shutdown final save user=213 (adopted snapshot): ok")
	end)

	h.test("T2-2: when another server takes the lock first the background retry stops (lost) and says so", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		local va = view(store)
		local a = server(sched, va, "job-A")
		local b = server(sched, store, "job-B")
		local pa = h.fakePlayer(210)
		load(a, pa)
		sched.advance(7)
		va.failing = true -- job-A alone cannot reach DataStore
		a.svc.award(pa, "token", "race:DINO-4", "finish")
		pa:leave()
		release(a, pa)
		local pb = h.fakePlayer(210)
		local snap = load(b, pb) -- waits out the 90 s ttl, then takes over
		h.ok(snap ~= nil)
		h.eq(store.data.u_210.session.id, "job-B")
		va.failing = false
		sched.advance(120)
		h.contains(a.logs, "final save DROPPED user=210")
		h.contains(a.logs, "lost (another server took the lock)")
		h.eq(store.data.u_210.session.id, "job-B", "the old server never wrote over the new holder")
	end)

	h.test("T2-2: the background retry gives up after orphanRetryWindow and BindToClose tries orphans once more", function()
		local sched = h.newScheduler(T0)
		local store = Fake.new({ clock = sched.clock })
		local a = server(sched, store, "job-A", { orphanRetryWindow = 200 })
		local p = h.fakePlayer(211)
		load(a, p)
		sched.advance(7)
		store.failing = true
		a.svc.award(p, "token", "race:DINO-4", "finish")
		p:leave()
		release(a, p)
		sched.advance(400)
		h.contains(a.logs, "final save DROPPED user=211")
		h.contains(a.logs, "window expired")
		-- A second player's retry is still running when the server shuts down.
		local q = h.fakePlayer(212)
		store.failing = false
		load(a, q)
		sched.advance(7)
		store.failing = true
		a.svc.award(q, "token", "race:DINO-4", "finish")
		q:leave()
		release(a, q)
		h.eq(a.svc.orphans(), { 212 })
		store.failing = false
		local saved = sched.run(function()
			return a.svc.flushAll(25)
		end)
		h.ok(saved, "flushAll wrote the orphan")
		h.ok(store.data.u_212.profile.tokens["race:DINO-4"])
		h.eq(store.data.u_212.session, nil)
		h.contains(a.logs, "shutdown final save user=212 (background retry): ok")
	end)

	---------------------------------------------------------------- owner save tools: rules

	h.test("save tools: command grammar, help and confirm codes", function()
		h.ok(SaveAdminRules.isSaveCommand("/admin save inspect 1"))
		h.ok(SaveAdminRules.isSaveCommand("  /ADMIN Save versions 1"))
		h.ok(not SaveAdminRules.isSaveCommand("/admin cash 10"))
		h.ok(not SaveAdminRules.isSaveCommand("save inspect 1"))
		h.eq(SaveAdminRules.parse("/admin save inspect 123"), { action = "inspect", userId = 123 })
		h.eq(SaveAdminRules.parse("/admin save versions 9"), { action = "versions", userId = 9 })
		h.eq(SaveAdminRules.parse("/admin save restore 9 v12"), { action = "restore", userId = 9, version = "v12" })
		h.eq(SaveAdminRules.parse("/admin save restore 9 v12 ABC123"), { action = "restore", userId = 9, version = "v12", code = "ABC123" })
		h.eq(SaveAdminRules.parse("/admin save erase 9 XYZ"), { action = "erase", userId = 9, code = "XYZ" })
		local bad = { "/admin save", "/admin save drop 1", "/admin save inspect", "/admin save inspect -4", "/admin save inspect abc", "/admin save inspect 1.5", "/admin save restore 9", "/admin save restore 9 v1;rm", "/admin save inspect 1 2" }
		for _, text in ipairs(bad) do
			local cmd = SaveAdminRules.parse(text)
			h.eq(cmd, nil, text)
		end
		local code = SaveAdminRules.confirmCode("erase", 9, nil, T0)
		h.eq(#code, 6)
		h.ok(SaveAdminRules.codeValid(code, "erase", 9, nil, T0 + 5))
		h.ok(SaveAdminRules.codeValid(string.lower(code), "erase", 9, nil, T0 + 5), "case does not matter")
		h.ok(not SaveAdminRules.codeValid(code, "erase", 10, nil, T0), "bound to the user")
		h.ok(not SaveAdminRules.codeValid(code, "restore", 9, nil, T0), "bound to the action")
		h.ok(not SaveAdminRules.codeValid(code, "erase", 9, nil, T0 + 3 * SaveAdminRules.CODE_WINDOW), "expires")
		h.ok(not SaveAdminRules.codeValid(nil, "erase", 9, nil, T0))
		h.ok(SaveAdminRules.codeValid(SaveAdminRules.confirmCode("restore", 9, "v1", T0), "restore", 9, "v1", T0))
		h.ok(not SaveAdminRules.codeValid(SaveAdminRules.confirmCode("restore", 9, "v1", T0), "restore", 9, "v2", T0), "bound to the version")
	end)

	h.test("save tools: store names match the stores the game writes", function()
		h.eq(SaveAdminRules.PROFILE_STORE, SaveService.STORE_NAME)
		h.eq(SaveAdminRules.PROFILE_PREFIX, SaveService.DEFAULT_CONFIG.keyPrefix)
		h.eq(SaveAdminRules.GIFT_STORE, MonetizationConfig.SERVICE.giftStoreName)
		h.eq(SaveAdminRules.PURCHASE_STORE, MonetizationConfig.SERVICE.purchaseStoreName)
		h.contains(h.readFile("src/server/Economy.luau"), 'return "g_" .. tostring(userId)', "gift inbox key")
		h.eq(SaveAdminRules.giftKey(5), "g_5")
		-- The Python tool mirrors the same names.
		local py = h.readFile("tools/save_admin/save_admin.py")
		for _, name in ipairs({ SaveService.STORE_NAME, MonetizationConfig.SERVICE.giftStoreName, MonetizationConfig.SERVICE.purchaseStoreName, LeaderboardRules.STORE_PREFIX }) do
			h.contains(py, '"' .. name, "save_admin.py names " .. name)
		end
	end)

	h.test("save tools: erasure targets cover inbox, the profile's purchase records, every board, profile last", function()
		local rec = { profile = { economy = { receipts = { ["p-2"] = { at = 1 }, ["p-1"] = { at = 1 } } } } }
		local targets = SaveAdminRules.erasureTargets(77, rec, { "LB_b", "LB_a" })
		local flat = {}
		for _, t in ipairs(targets) do
			table.insert(flat, t.kind .. ":" .. t.store .. "/" .. t.key)
		end
		h.eq(flat, {
			"standard:SkyRallyPendingGifts/g_77",
			"purchase:SkyRallyPurchaseHistory/p-1",
			"purchase:SkyRallyPurchaseHistory/p-2",
			"ordered:LB_a/77",
			"ordered:LB_b/77",
			"standard:SkyRallyProfiles/u_77",
		})
		h.eq(#SaveAdminRules.erasureTargets(77, nil, {}), 2, "no profile: inbox and profile key still tried")
		h.ok(SaveAdminRules.purchaseBelongsTo({ userId = 77 }, 77))
		h.ok(not SaveAdminRules.purchaseBelongsTo({ userId = 78 }, 77))
	end)

	---------------------------------------------------------------- owner save tools: SaveAdmin on the fake store

	local function tools(sched: any, opts: any?): any
		local o: any = opts or {}
		local w: any = { logs = {} }
		w.profiles = o.profiles or Fake.new({ clock = sched.clock, writeGap = 0 })
		w.gifts = Fake.new({ clock = sched.clock, writeGap = 0 })
		w.purchases = Fake.new({ clock = sched.clock, writeGap = 0 })
		w.audit = Fake.new({ clock = sched.clock, writeGap = 0 })
		w.boardA = Fake.ordered()
		w.boardB = Fake.ordered()
		w.admin = SaveAdmin.new({
			profiles = w.profiles,
			gifts = w.gifts,
			purchases = w.purchases,
			audit = w.audit,
			boards = { SkyRallyLB_v1_stars = w.boardA, ["SkyRallyLB_v1_best_DINO-4"] = w.boardB },
			migrate = SaveService.migrate,
			now = sched.clock,
			log = function(line: string)
				table.insert(w.logs, line)
			end,
		})
		function w.run(text: string): any
			local cmd = SaveAdminRules.parse(text)
			assert(cmd, "spec command parses: " .. text)
			return w.admin.run(AdminConfig.ADMIN_USER_ID, cmd)
		end
		return w
	end

	local function profileWith(fields: { [string]: any }): any
		local p = SaveService.newProfile()
		for k, v in pairs(fields) do
			(p :: any)[k] = v
		end
		return p
	end

	h.test("save tools: inspect and versions are read only and show lock, facts and the last takeover", function()
		local sched = h.newScheduler(T0)
		local w = tools(sched)
		w.profiles.seed("u_300", { profile = profileWith({ gears = 1234 }), session = { id = "job-X", token = "t", lockedAt = T0 - 10, ttl = 90 }, savedAt = T0 - 10, lastTakeover = { from = "job-W", by = "job-X", age = 95, at = T0 - 20 } })
		local writes = w.profiles.writes
		local r = w.run("/admin save inspect 300")
		h.ok(r.ok)
		h.contains(r.text, "lock held by job-X, refreshed 10s ago (ttl 90s)")
		h.contains(r.text, "cash=1234")
		h.contains(r.text, "last takeover")
		h.contains(w.run("/admin save inspect 999").text, "no saved profile")
		local v = w.run("/admin save versions 300")
		h.ok(v.ok)
		h.contains(v.text, "v1")
		h.eq(w.profiles.writes, writes, "nothing written")
		h.eq(w.profiles.data.u_300.session.id, "job-X", "the lock is untouched")
		h.contains(w.logs, "[SkyRally][SAVEADMIN] actor=" .. AdminConfig.ADMIN_USER_ID .. " action=inspect target=300 result=ok")
		local day = SaveAdminRules.auditKey(T0)
		h.eq(#w.audit.data[day], 3, "every action audited")
		h.eq(w.audit.data[day][1].action, "inspect")
	end)

	h.test("save tools: restore previews with a code, keeps receipts and gift ledger, refuses while online", function()
		local sched = h.newScheduler(T0)
		local w = tools(sched)
		-- v1: a good profile; v2: a bad change (cash wiped) after a purchase was granted.
		w.profiles.seed("u_301", { profile = profileWith({ gears = 5000, tokens = { ["race:DINO-4"] = true } }), savedAt = T0 - 100 })
		local bad = profileWith({ gears = 0, tokens = {} })
		bad.economy.receipts["purchase-9"] = { at = T0 - 50, ledger = true }
		bad.economy.oneTime.rookie = true
		bad.pendingGifts["gift-3"] = { key = "trail", from = 5, at = T0 - 40 }
		w.profiles.seed("u_301", { profile = bad, session = { id = "job-Y", token = "t", lockedAt = T0 - 5, ttl = 90 }, savedAt = T0 - 5 })
		local online = w.run("/admin save restore 301 v1")
		h.eq(online.ok, false)
		h.contains(online.text, "player is online")
		sched.advance(100) -- the player left (lock now stale)
		local preview = w.run("/admin save restore 301 v1")
		h.ok(preview.ok, preview.text)
		h.contains(preview.text, "cash=0")
		h.contains(preview.text, "cash=5000")
		local code = string.match(preview.text, "restore 301 v1 (%w+)$")
		h.ok(code, "the preview names the confirm line")
		h.eq(w.profiles.data.u_301.profile.gears, 0, "a preview writes nothing")
		local wrong = w.run("/admin save restore 301 v1 AAAAAA")
		h.ok(wrong.ok and string.find(wrong.text, "Confirm", 1, true), "a wrong code only previews again")
		local done = w.run("/admin save restore 301 v1 " .. code)
		h.ok(done.ok, done.text)
		local after = w.profiles.data.u_301
		h.eq(after.profile.gears, 5000)
		h.ok(after.profile.tokens["race:DINO-4"])
		h.ok(after.profile.economy.receipts["purchase-9"], "a granted purchase stays marked (no regrant)")
		h.eq(after.profile.economy.oneTime.rookie, true)
		h.ok(after.profile.pendingGifts["gift-3"], "a delivered gift stays marked")
		h.eq(after.session, nil)
		h.eq(after.restoredFrom.version, "v1")
		h.contains(w.logs, "action=restore target=301 result=done")
		h.contains(w.run("/admin save inspect 301").text, "restored")
	end)

	h.test("save tools: a server that takes the lock between preview and restore wins; the restore is cancelled", function()
		local sched = h.newScheduler(T0)
		local w = tools(sched)
		w.profiles.seed("u_302", { profile = profileWith({ gears = 10 }), savedAt = T0 - 100 })
		w.profiles.seed("u_302", { profile = profileWith({ gears = 0 }), savedAt = T0 - 50 })
		local preview = w.run("/admin save restore 302 v1")
		local code = string.match(preview.text, "restore 302 v1 (%w+)$")
		-- The player joins a server whose load commits inside the restore's UpdateAsync.
		local game = server(sched, w.profiles, "job-Z")
		local p = h.fakePlayer(302)
		w.profiles.interleave = function()
			startLoad(game, p)
		end
		local r = w.run("/admin save restore 302 v1 " .. tostring(code))
		h.eq(r.ok, false)
		h.contains(r.text, "player is online")
		h.eq(w.profiles.data.u_302.session.id, "job-Z", "the live server keeps its lock")
		h.eq(w.profiles.data.u_302.profile.gears, 0, "the restore wrote nothing")
		h.contains(w.logs, "action=restore target=302 result=refused")
	end)

	h.test("save tools: a newer-build or unreadable version is refused, never written", function()
		local sched = h.newScheduler(T0)
		local w = tools(sched)
		local newer = profileWith({})
		newer.version = SaveService.CURRENT_VERSION + 1
		w.profiles.seed("u_303", { profile = newer })
		w.profiles.seed("u_303", { profile = profileWith({}) })
		local r = w.run("/admin save restore 303 v1")
		h.eq(r.ok, false)
		h.contains(r.text, "cannot be read")
		h.eq(w.run("/admin save restore 303 v99").ok, false, "unknown version")
	end)

	h.test("save tools: erase removes inbox, the user's purchase records, board rows and the profile; refuses while online", function()
		local sched = h.newScheduler(T0)
		local w = tools(sched)
		local prof = profileWith({ gears = 7 })
		prof.economy.receipts["buy-1"] = { at = 1, ledger = true }
		prof.economy.receipts["buy-2"] = { at = 2, ledger = true }
		w.profiles.seed("u_304", { profile = prof, session = { id = "job-Q", token = "t", lockedAt = T0, ttl = 90 } })
		w.gifts.seed("g_304", { list = { 1 } })
		w.purchases.seed("buy-1", { granted = true, userId = 304 })
		w.purchases.seed("buy-2", { granted = true, userId = 999 }) -- names another buyer: never removed
		w.purchases.seed("other", { granted = true, userId = 304 })
		w.boardA.data["304"] = 12
		w.boardB.data["304"] = 61000
		w.boardB.data["305"] = 62000
		local online = w.run("/admin save erase 304")
		h.eq(online.ok, false)
		h.contains(online.text, "is online")
		sched.advance(100)
		local preview = w.run("/admin save erase 304")
		h.ok(preview.ok)
		h.contains(preview.text, "6 entries")
		h.ok(w.profiles.data.u_304 ~= nil, "a preview removes nothing")
		local code = string.match(preview.text, "erase 304 (%w+)$")
		local r = w.run("/admin save erase 304 " .. tostring(code))
		h.ok(r.ok, r.text)
		h.eq(w.profiles.data.u_304, nil)
		h.eq(w.gifts.data.g_304, nil)
		h.eq(w.purchases.data["buy-1"], nil)
		h.ok(w.purchases.data["buy-2"] ~= nil, "another buyer's record stays")
		h.ok(w.purchases.data.other ~= nil, "records the profile does not name are listed in docs/SAVE_ADMIN.md (Python --scan-purchases)")
		h.eq(w.boardA.data["304"], nil)
		h.eq(w.boardB.data["304"], nil)
		h.eq(w.boardB.data["305"], 62000, "other players' rows untouched")
		h.contains(w.logs, "action=erase target=304 result=done")
	end)

	h.test("save tools: an erase that fails midway keeps the profile and a rerun finishes it", function()
		local sched = h.newScheduler(T0)
		local w = tools(sched)
		local prof = profileWith({})
		prof.economy.receipts["buy-7"] = { at = 1 }
		w.profiles.seed("u_306", { profile = prof })
		w.purchases.seed("buy-7", { userId = 306 })
		w.boardA.failing = true
		local code = string.match(w.run("/admin save erase 306").text, "erase 306 (%w+)$")
		local r = w.run("/admin save erase 306 " .. tostring(code))
		h.eq(r.ok, false)
		h.contains(r.text, "Run the same command again")
		h.ok(w.profiles.data.u_306 ~= nil, "profile kept: it names the purchase records")
		h.contains(w.logs, "action=erase target=306 result=partial")
		w.boardA.failing = false
		local r2 = w.run("/admin save erase 306 " .. tostring(code))
		h.ok(r2.ok, r2.text)
		h.eq(w.profiles.data.u_306, nil)
	end)

	h.test("save tools: a throttled or failing DataStore answers with the error, never a partial write", function()
		local sched = h.newScheduler(T0)
		local w = tools(sched)
		w.profiles.seed("u_307", { profile = profileWith({ gears = 1 }) })
		w.profiles.seed("u_307", { profile = profileWith({ gears = 2 }) })
		w.profiles.failNext = 1
		local r = w.run("/admin save inspect 307")
		h.eq(r.ok, false)
		h.contains(r.text, "Read failed")
		local code = string.match(w.run("/admin save restore 307 v1").text, "restore 307 v1 (%w+)$")
		w.profiles.failing = true
		local r2 = w.run("/admin save restore 307 v1 " .. tostring(code))
		h.eq(r2.ok, false)
		w.profiles.failing = false
		h.eq(w.profiles.data.u_307.profile.gears, 2)
		w.audit.failing = true
		h.ok(w.run("/admin save inspect 307").ok, "a failed audit write never blocks the action")
		h.contains(w.logs, "audit write failed")
	end)

	---------------------------------------------------------------- AdminService gate

	h.test("save tools gate: only the admin account itself; the Studio override and everyone else get nothing", function()
		local ran: { any } = {}
		local fakeTools = {
			run = function(actorId: number, cmd: any): any
				table.insert(ran, { actorId, cmd.action, cmd.userId })
				return { ok = true, text = "ran" }
			end,
		}
		local players: { [number]: any } = {}
		local t = 0
		local logs: { string } = {}
		local svc = AdminService.new({
			isStudio = function(): boolean
				return true
			end,
			attr = function(name: string): any
				return if name == AdminConfig.STUDIO_ATTRIBUTE then true else nil
			end,
			playerByUserId = function(userId: number): any
				return players[userId]
			end,
			award = function(): string
				return "rejected"
			end,
			economy = function(): any
				return nil
			end,
			keyForId = function(): string?
				return nil
			end,
			adminStart = function(): (boolean, string)
				return false, "no"
			end,
			republish = function() end,
			stormForce = function(): (boolean, string)
				return false, "no"
			end,
			clock = function(): number
				t += 1
				return t
			end,
			log = function(line: string)
				table.insert(logs, line)
			end,
			saveAdmin = function(): any
				return fakeTools
			end,
		})
		local studioTester = h.fakePlayer(4242)
		players[4242] = studioTester
		svc.noteJoin(studioTester) -- the Studio override's admin
		local stranger = h.fakePlayer(5151)
		players[5151] = stranger
		local owner = h.fakePlayer(AdminConfig.ADMIN_USER_ID)
		players[AdminConfig.ADMIN_USER_ID] = owner
		h.ok(svc.isAdmin(studioTester), "the Studio override is admin for gameplay commands")
		local r = svc.handle(studioTester, "/admin save inspect 1")
		h.eq(r and r.ok, false)
		h.contains(r and r.text or "", "admin account itself")
		h.eq(svc.handle(stranger, "/admin save erase 1"), nil, "everyone else: nil")
		h.eq(#ran, 0)
		local ok = svc.handle(owner, "/admin save inspect 77")
		h.ok(ok and ok.ok)
		h.eq(ran, { { AdminConfig.ADMIN_USER_ID, "inspect", 77 } })
		local badCmd = svc.handle(owner, "/admin save inspect bob")
		h.eq(badCmd and badCmd.ok, false)
		h.contains(logs, "action=save user=" .. AdminConfig.ADMIN_USER_ID .. " result=ok op=inspect target=77")
		h.contains(svc.handle(owner, "/admin help").text, "/admin save erase <userId> [code]")
	end)
end
