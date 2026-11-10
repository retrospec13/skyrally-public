--!strict
-- Lune spec for the launch unlock graph (src/shared/Progression.luau) and the save contract
-- (src/server/SaveService.luau): LAUNCH_PROGRESSION sections 3 and 5, TEST_LIST_LAUNCH L18, L20-L23, L53, L70, L75.
-- Run: tools/tests/run_lune_tests.sh tools/tests/save_spec.luau
-- Every SaveService case runs on the deterministic scheduler from the harness: fake seconds, no real sleeping, and
-- MemoryStore instances sharing one backing table stand in for several servers on one DataStore.

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
	local Progression = h.require("src/shared/Progression.luau")
	local SaveService = h.require("src/server/SaveService.luau")

	local CHAIN = { "DINO", "SNOW", "ISLAND", "FOREST" }

	-- Hand-built progression slice; fields default to "nothing won".
	local function progress(fields: { [string]: any }?): any
		local p: any = { tokens = {}, boss = {}, keys = {}, battles = {}, finalBoss = false }
		for k, v in pairs(fields or {}) do
			p[k] = v
		end
		return p
	end

	local function tokens(list: { string }): { [string]: boolean }
		local t = {}
		for _, id in ipairs(list) do
			t[id] = true
		end
		return t
	end

	local function newEnv(opts: { [string]: any }?): any
		local o: any = opts or {}
		local sched = o.sched or h.newScheduler()
		local backing: any = o.backing or {}
		local store = o.store or SaveService.newMemoryStore(backing)
		local sessionId = o.sessionId or "server-A"
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
				return 0.5 -- backoff jitter factor 1.0
			end,
			config = o.config or { writeCooldown = 0 },
		})
		return { sched = sched, store = store, svc = svc, logs = logs, backing = backing }
	end

	-- Wraps a store so a spec can switch a DataStore outage on and off.
	local function flaky(inner: any): any
		local f: any = { kind = "flaky", failing = false, calls = 0, failures = 0, data = inner.data }
		function f.update(key: string, transform: (any) -> any, userIds: { number }?): (boolean, string?)
			f.calls += 1
			if f.failing then
				f.failures += 1
				return false, "502: simulated DataStore outage"
			end
			return inner.update(key, transform, userIds)
		end
		return f
	end

	local function load(env: any, player: any): (any, string)
		return env.sched.run(function()
			return env.svc.load(player)
		end)
	end

	local function release(env: any, player: any): boolean
		return env.sched.run(function()
			return env.svc.release(player)
		end)
	end

	local function indexOf(list: { string }, value: string): number?
		for i, v in ipairs(list) do
			if v == value then
				return i
			end
		end
		return nil
	end

	-- Plays a whole launch run through award() in a legal order; returns the last award's newly-unlocked list.
	local function playEverything(env: any, player: any)
		local svc = env.svc
		for _, zone in ipairs(CHAIN) do
			local track = Progression.ZONE_TRACK[zone]
			h.eq(svc.award(player, "key", zone, "pickup"), "awarded", zone .. " key")
			h.eq(svc.award(player, "battle", zone, "battleWin"), "awarded", zone .. " battle")
			h.eq(svc.award(player, "token", "race:" .. track, "finish"), "awarded", zone .. " race")
			h.eq(svc.award(player, "bossFirst", zone, "bossWin"), "awarded", zone .. " boss")
			h.eq(svc.award(player, "token", "coin:" .. track, "coinWin"), "awarded", zone .. " coin")
			h.eq(svc.award(player, "bossRematch", track, "rematchWin"), "awarded", zone .. " rematch")
		end
		h.eq(svc.award(player, "finalBoss", "HUB-BOSS-1", "finalWin"), "awarded", "final boss")
		h.eq(svc.award(player, "token", "race:SPACE-4", "finish"), "awarded", "SPACE race")
		h.eq(svc.award(player, "token", "coin:SPACE-4", "coinWin"), "awarded", "SPACE coin")
		for _, find in ipairs(Progression.HUB_FINDS) do
			h.eq(svc.award(player, "hubFind", find, "hubPickup"), "awarded", find)
		end
	end

	---------------------------------------------------------------- Progression (pure)

	h.test("progression: 14 tokens (5 race, 5 coin, 4 hub finds) and launch totals", function()
		h.eq(#Progression.TOKENS, 14)
		h.eq(Progression.TOKENS_TOTAL, 14)
		local kinds = { race = 0, coin = 0, hub = 0 }
		for _, id in ipairs(Progression.TOKENS) do
			local kind = Progression.TOKEN_INFO[id].kind
			kinds[kind] += 1
		end
		h.eq(kinds, { race = 5, coin = 5, hub = 4 })
		h.eq(Progression.HUB_FINDS, { "HubFind_Ground", "HubFind_WaterEdge", "HubFind_Ledge", "HubFind_Cove" })
		h.eq(Progression.PORTAL_THRESHOLD, { DINO = 0, SNOW = 1, ISLAND = 2, FOREST = 4 })
		h.eq(Progression.KEYS_TOTAL + Progression.BOSS_FRAGMENTS_TOTAL + Progression.BATTLE_FRAGMENTS_TOTAL, 12)
	end)

	h.test("progression: a fresh profile opens only DINO (race, time trial, quick race)", function()
		local p = progress()
		h.eq(Progression.tokenCount(p), 0)
		h.ok(Progression.isPortalOpen(p, "DINO"))
		for _, zone in ipairs({ "SNOW", "ISLAND", "FOREST", "SPACE" }) do
			h.ok(not Progression.isPortalOpen(p, zone), zone .. " closed")
		end
		h.eq(Progression.modesFor(p, "DINO-4"), { "race", "timetrial", "quickrace" })
		h.eq(Progression.modesFor(p, "SNOW-1"), {})
		h.eq(Progression.modesFor(p, "HUB-0"), {})
	end)

	h.test("progression: portal thresholds DINO 0, SNOW 1, ISLAND 2, FOREST 4, SPACE on the final-boss win", function()
		local one = progress({ tokens = tokens({ "race:DINO-4" }) })
		h.ok(Progression.isPortalOpen(one, "SNOW"), "winning DINO-4 opens SNOW")
		h.ok(not Progression.isPortalOpen(one, "ISLAND"))
		local two = progress({ tokens = tokens({ "race:DINO-4", "HubFind_Ground" }) })
		h.ok(Progression.isPortalOpen(two, "ISLAND"))
		h.ok(not Progression.isPortalOpen(two, "FOREST"))
		local three = progress({ tokens = tokens({ "race:DINO-4", "coin:DINO-4", "race:SNOW-1" }) })
		h.ok(not Progression.isPortalOpen(three, "FOREST"), "3 tokens keep FOREST shut")
		local hubOnly = progress({ tokens = tokens(Progression.HUB_FINDS) })
		h.eq(Progression.tokenCount(hubOnly), 4)
		h.ok(Progression.isPortalOpen(hubOnly, "FOREST"), "hub finds alone open FOREST")
		h.ok(not Progression.isPortalOpen(hubOnly, "SPACE"), "no token count opens SPACE")
		local allButFinal = progress({ tokens = tokens(Progression.TOKENS) })
		h.ok(not Progression.isPortalOpen(allButFinal, "SPACE"), "14 tokens without the final boss keep SPACE shut")
		h.ok(Progression.isPortalOpen(progress({ finalBoss = true }), "SPACE"))
	end)

	h.test("progression: per-zone chain race -> boss -> coin -> rematch -> boss fragment", function()
		for _, zone in ipairs(CHAIN) do
			local track = Progression.ZONE_TRACK[zone]
			-- Enough hub finds that every chain portal is open, so only the chain itself gates.
			local p = progress({ tokens = tokens(Progression.HUB_FINDS) })
			p.boss[zone] = { first = false, rematch = false }
			h.ok(Progression.isModeUnlocked(p, track, "race"), zone .. " race open")
			h.ok(not Progression.isModeUnlocked(p, track, "boss"), zone .. " boss locked before race win")
			h.ok(not Progression.isModeUnlocked(p, track, "coin"), zone .. " coin locked before boss")
			p.tokens["race:" .. track] = true
			h.ok(Progression.isModeUnlocked(p, track, "boss"), zone .. " race win unlocks boss")
			h.ok(not Progression.isModeUnlocked(p, track, "coin"), zone .. " coin still locked")
			p.boss[zone].first = true
			h.ok(Progression.isModeUnlocked(p, track, "coin"), zone .. " boss win unlocks coin")
			h.ok(not Progression.isModeUnlocked(p, track, "rematch"), zone .. " rematch locked before coin")
			p.tokens["coin:" .. track] = true
			h.ok(Progression.isModeUnlocked(p, track, "rematch"), zone .. " coin win unlocks rematch")
			h.eq(Progression.bossFragmentCount(p), 0)
			p.boss[zone].rematch = true
			h.eq(Progression.bossFragmentCount(p), 1, zone .. " rematch win = one fragment")
			h.ok(Progression.isModeUnlocked(p, track, "boss"), zone .. " boss replay stays open")
		end
	end)

	h.test("progression: keys and battle fragments are a side chain that never moves thresholds (L70, L75)", function()
		local p = progress()
		h.ok(not Progression.isModeUnlocked(p, "DINO-4", "battle"), "battle hidden before the key")
		p.keys.DINO = true
		h.ok(Progression.isModeUnlocked(p, "DINO-4", "battle"), "key alone shows the battle, no race win needed")
		h.eq(Progression.modesFor(p, "DINO-4"), { "race", "timetrial", "quickrace", "battle" })
		p.battles.DINO = true
		h.eq(Progression.battleFragmentCount(p), 1)
		h.eq(Progression.tokenCount(p), 0, "keys and battles are not tokens")
		h.ok(not Progression.isPortalOpen(p, "SNOW"), "thresholds unchanged by keys/battle fragments")
		local full = progress({ keys = tokens(CHAIN), battles = tokens(CHAIN) })
		h.eq(Progression.keyCount(full), 4)
		h.ok(Progression.hasBattleAmulet(full))
		h.ok(not Progression.isPortalOpen(full, "SNOW"), "a full Battle Amulet still opens no portal")
		-- A key held for a zone whose portal is shut does not expose the battle there.
		local snowKey = progress({ keys = { SNOW = true } })
		h.ok(not Progression.isModeUnlocked(snowKey, "SNOW-1", "battle"))
		h.ok(not Progression.isModeUnlocked(progress({ keys = { SPACE = true }, finalBoss = true }), "SPACE-4", "battle"), "no SPACE battle")
	end)

	h.test("progression: four boss fragments unlock HUB-BOSS-1; its win opens SPACE race, then SPACE coin", function()
		local p = progress({ tokens = tokens(Progression.HUB_FINDS) })
		for i, zone in ipairs(CHAIN) do
			h.ok(not Progression.isFinalBossUnlocked(p), "final boss locked at " .. tostring(i - 1) .. " fragments")
			p.boss[zone] = { first = true, rematch = true }
		end
		h.ok(Progression.isFinalBossUnlocked(p))
		h.ok(Progression.isModeUnlocked(p, "HUB-0", "boss"))
		h.ok(not Progression.isModeUnlocked(p, "HUB-0", "race"), "hub loop hosts only the final boss")
		h.ok(not Progression.isModeUnlocked(p, "SPACE-4", "race"), "SPACE shut before the final-boss win")
		p.finalBoss = true
		h.ok(Progression.isModeUnlocked(p, "SPACE-4", "race"))
		h.ok(Progression.isModeUnlocked(p, "SPACE-4", "timetrial"))
		h.ok(not Progression.isModeUnlocked(p, "SPACE-4", "coin"), "SPACE coin follows the SPACE race win")
		p.tokens["race:SPACE-4"] = true
		h.ok(Progression.isModeUnlocked(p, "SPACE-4", "coin"))
		h.ok(not Progression.isModeUnlocked(p, "SPACE-4", "boss"), "SPACE-BOSS is U3")
		h.ok(not Progression.isModeUnlocked(p, "SPACE-4", "rematch"))
	end)

	h.test("progression: unknown ids, tracks and modes never unlock anything", function()
		local p = progress({ tokens = { ["DINO-4"] = true, bogus = true, ["race:MOON-9"] = true } })
		h.eq(Progression.tokenCount(p), 0, "only the 14 known ids count")
		h.ok(not Progression.isModeUnlocked(p, "MOON-9", "race"))
		h.ok(not Progression.isModeUnlocked(p, "DINO-4", "drift"))
		h.ok(not Progression.isPortalOpen(p, "MOON"))
		h.eq(Progression.zoneOf("DINO-4"), "DINO")
		h.eq(Progression.zoneOf("FOREST"), "FOREST")
		h.eq(Progression.zoneOf("HUB-0"), nil)
	end)

	h.test("progression: newlyUnlocked reports what an award opened", function()
		local before = Progression.unlockSet(progress())
		local after = Progression.unlockSet(progress({ tokens = tokens({ "race:DINO-4" }) }))
		local diff = Progression.newlyUnlocked(before, after)
		h.ok(indexOf(diff, "portal:SNOW"), "SNOW portal")
		h.ok(indexOf(diff, "mode:DINO-4:boss"), "DINO boss")
		h.ok(indexOf(diff, "mode:SNOW-1:race"), "SNOW race")
		h.ok(not indexOf(diff, "mode:DINO-4:race"), "already open before")
	end)

	h.test("progression: completion summary for the completion screen", function()
		local partial = Progression.completion(progress({ tokens = tokens({ "race:DINO-4" }), keys = { DINO = true } }))
		h.eq(partial.text, "1/14 tokens, 1/4 keys, 0/4 boss fragments, 0/4 battle fragments, final boss not yet beaten")
		h.ok(not partial.complete)
		local boss = {}
		for _, zone in ipairs(CHAIN) do
			boss[zone] = { first = true, rematch = true }
		end
		local full = Progression.completion(progress({
			tokens = tokens(Progression.TOKENS),
			boss = boss,
			keys = tokens(CHAIN),
			battles = tokens(CHAIN),
			finalBoss = true,
		}))
		h.ok(full.complete)
		h.ok(full.battleAmulet)
		h.eq(full.text, "14/14 tokens, 4/4 keys, 4/4 boss fragments, 4/4 battle fragments, final boss beaten; more worlds coming")
		h.contains(full.roadmap, "SPACE-BOSS")
		h.ok(not string.find(full.text, "game complete", 1, true))
	end)

	---------------------------------------------------------------- SaveService

	h.test("save: a new player gets the default profile, reserved economy slots and HUD attributes", function()
		local env = newEnv()
		local p = h.fakePlayer(101)
		local profile, state = load(env, p)
		h.eq(state, "ok")
		h.eq(profile.version, SaveService.CURRENT_VERSION)
		h.eq(profile.boss.DINO, { first = false, rematch = false })
		h.eq(profile.gears, 0)
		h.eq(profile.cosmetics, { owned = {}, loadout = {} })
		h.eq(profile.winPass, { season = 1, wins = 0, races = 0, premium = false, claimedFree = {}, claimedPremium = {} })
		h.eq(profile.streak, { dailyDay = 0, dailyCount = 0, lastClaimAt = 0, loginShownDay = 0 })
		h.eq(profile.pendingGifts, {})
		h.eq(profile.passCache, {})
		for name, value in pairs({ SaveState = "ok", SaveMessage = "", SkyTokens = 0, Keys = 0, BossFragments = 0, BattleFragments = 0 }) do
			h.eq(p:GetAttribute(name), value, name)
		end
		local record = env.backing.u_101
		h.eq(record.session.id, "server-A", "load takes the session lock")
		h.contains(env.logs, "new=true")
	end)

	h.test("save: idempotent double award is a logged noop and writes nothing (L21)", function()
		local env = newEnv()
		local p = h.fakePlayer(102)
		load(env, p)
		local writes = env.store.writes
		local first, opened = env.svc.award(p, "token", "race:DINO-4", "finish")
		h.eq(first, "awarded")
		h.ok(indexOf(opened, "portal:SNOW"), "award reports the SNOW portal opening")
		h.eq(env.store.writes, writes + 1, "every award saves immediately")
		h.eq(env.svc.award(p, "token", "race:DINO-4", "finish"), "noop")
		h.eq(env.store.writes, writes + 1, "noop writes nothing")
		h.eq(h.count(env.logs, "[SkyRally][SAVE] noop user=102 kind=token id=race:DINO-4"), 1)
		h.eq(p:GetAttribute("SkyTokens"), 1)
		h.eq(env.backing.u_102.profile.tokens["race:DINO-4"], true)
	end)

	h.test("save: double finish awards the token and best time once (L21)", function()
		local env = newEnv()
		local p = h.fakePlayer(103)
		load(env, p)
		-- RaceManager's finish path firing twice for one finish (trigger plus fallback) in the same frame.
		local results = {}
		for _ = 1, 2 do
			table.insert(results, (env.svc.award(p, "token", "race:DINO-4", "finish")))
			table.insert(results, (env.svc.award(p, "bestTime", "DINO-4", "finish", 71234.4)))
		end
		h.eq(results, { "awarded", "awarded", "noop", "noop" })
		local snap = env.svc.get(p)
		h.eq(Progression.tokenCount(snap), 1)
		h.eq(snap.bestTimes["DINO-4"], 71234)
		h.eq(h.count(env.logs, "[SkyRally][SAVE] noop"), 2)
	end)

	h.test("save: rejoin after award keeps progress and replays stay noops (L20, L21)", function()
		local sched = h.newScheduler()
		local backing: any = {}
		local env = newEnv({ sched = sched, backing = backing })
		local p = h.fakePlayer(104)
		load(env, p)
		env.svc.award(p, "token", "race:DINO-4", "finish")
		env.svc.award(p, "bossFirst", "DINO", "bossWin")
		p:leave()
		h.ok(release(env, p), "release saved")
		h.eq(backing.u_104.session, nil, "leave unlocks")
		-- Rejoin on another server sharing the store.
		local other = newEnv({ sched = sched, backing = backing, sessionId = "server-B" })
		local p2 = h.fakePlayer(104)
		local snap = load(other, p2)
		h.ok(snap.tokens["race:DINO-4"] and snap.boss.DINO.first)
		h.eq(other.svc.award(p2, "token", "race:DINO-4", "retryAfterFinish"), "noop")
		h.eq(other.svc.award(p2, "bossFirst", "DINO-4", "bossReplay"), "noop", "boss replay gives no second reward (L18)")
		h.eq(p2:GetAttribute("SkyTokens"), 1)
	end)

	h.test("save: a rejoin on the same server waits for the previous session's unlock", function()
		local env = newEnv({ config = { writeCooldown = 6 } })
		local p = h.fakePlayer(105)
		load(env, p)
		env.svc.award(p, "token", "race:DINO-4", "finish") -- coalesced behind the 6 s cooldown
		p:leave()
		local released, rejoined = nil, nil
		env.sched.spawn(function()
			released = env.svc.release(p)
		end)
		local p2 = h.fakePlayer(105)
		env.sched.spawn(function()
			rejoined = table.pack(env.svc.load(p2))
		end)
		h.eq(rejoined, nil, "rejoin waits while the final write is pending")
		env.sched.advance(10)
		h.eq(released, true)
		h.ok(rejoined and rejoined[2] == "ok", "rejoin loaded after the unlock")
		h.ok(rejoined and rejoined[1].tokens["race:DINO-4"], "rejoin sees the award")
		h.eq(env.backing.u_105.session.token, "server-A-load2")
	end)

	h.test("save: a same-server rejoin does not take over the lock while the previous final write is still retrying (L20)", function()
		local backing: any = {}
		local store = flaky(SaveService.newMemoryStore(backing))
		local env = newEnv({ store = store, backing = backing, config = { writeCooldown = 6, releaseWait = 10 } })
		local p = h.fakePlayer(112)
		load(env, p)
		env.svc.award(p, "token", "race:DINO-4", "finish") -- coalesced behind the 6 s cooldown
		p:leave()
		store.failing = true -- the first final write (at 6 s) fails and pushes the retry out another cooldown
		local released, rejoined = nil, nil
		env.sched.spawn(function()
			released = env.svc.release(p)
		end)
		local p2 = h.fakePlayer(112)
		env.sched.spawn(function()
			rejoined = table.pack(env.svc.load(p2))
		end)
		env.sched.advance(6.5)
		h.eq(store.failures, 1, "the first final write failed")
		store.failing = false -- the outage is over, but the retry is not due until about 12 s
		env.sched.advance(4.5) -- 11 s: past releaseWait, so the rejoin's first load attempt has run
		h.eq(rejoined, nil, "rejoin still waiting at 11 s")
		h.eq(released, nil, "final write still retrying")
		h.eq(env.backing.u_112.session.token, "server-A-load1", "the old session still holds the lock")
		env.sched.advance(20)
		h.eq(released, true, "the final write landed")
		h.ok(rejoined and rejoined[2] == "ok", "rejoin loaded after the unlock")
		h.ok(rejoined and rejoined[1].tokens["race:DINO-4"], "rejoin sees the coalesced award")
		h.eq(env.backing.u_112.session.token, "server-A-load2")
	end)

	h.test("save: leave mid-race keeps only the key saved on pickup (L22, L70)", function()
		local sched = h.newScheduler()
		local backing: any = {}
		local env = newEnv({ sched = sched, backing = backing })
		local p = h.fakePlayer(106)
		load(env, p)
		h.eq(env.svc.award(p, "key", "DINO-4", "keyPickup"), "awarded")
		h.eq(backing.u_106.profile.keys.DINO, true, "key saved on pickup, before the race ends")
		-- The race is abandoned: RaceManager awards nothing; the player leaves.
		p:leave()
		release(env, p)
		local p2 = h.fakePlayer(106)
		local snap = load(newEnv({ sched = sched, backing = backing, sessionId = "server-B" }), p2)
		h.eq(snap.keys, { DINO = true })
		h.eq(snap.tokens, {}, "nothing partial from the abandoned race")
		h.eq(snap.bestTimes, {})
		h.eq(p2:GetAttribute("Keys"), 1)
		h.eq(p2:GetAttribute("CompletionInfo"), "0/14 tokens | 1/4 keys | 0/4 boss | 0/4 battle | final boss: not yet", "J3 board line replicates")
	end)

	h.test("save: load failure shows a readable error state, never a fresh profile, and recovers (L23)", function()
		local sched = h.newScheduler()
		local existing = SaveService.newProfile()
		existing.tokens["race:DINO-4"] = true
		existing.tokens.HubFind_Ground = true
		local backing: any = { u_107 = { profile = existing } }
		local store = flaky(SaveService.newMemoryStore(backing))
		store.failing = true
		local env = newEnv({ sched = sched, backing = backing, store = store, config = { writeCooldown = 0, loadAttempts = 4 } })
		local p = h.fakePlayer(107)
		local profile, state = load(env, p)
		h.eq(profile, nil)
		h.eq(state, "error")
		h.eq(p:GetAttribute("SaveState"), "error")
		h.contains(p:GetAttribute("SaveMessage"), "Retrying")
		h.eq(env.svc.get(p), nil, "no fresh stand-in profile")
		h.eq(p:GetAttribute("SkyTokens"), nil, "HUD shows no fake zero")
		h.eq(backing.u_107.session, nil, "nothing written during the outage")
		h.eq(env.svc.award(p, "key", "DINO-4", "keyPickup"), "queued", "a key picked up meanwhile waits for the real profile")
		sched.advance(120)
		h.ok(store.failures > 4, "keeps retrying in the background")
		h.eq(p:GetAttribute("SaveState"), "error")
		store.failing = false
		sched.advance(60)
		h.eq(p:GetAttribute("SaveState"), "ok")
		local snap = env.svc.get(p)
		h.ok(snap.tokens["race:DINO-4"] and snap.tokens.HubFind_Ground, "the stored progress loaded, not a fresh profile")
		h.ok(snap.keys.DINO, "queued key applied to the real profile")
		h.eq(p:GetAttribute("SkyTokens"), 2)
		h.eq(backing.u_107.profile.keys.DINO, true, "queued key saved")
		local loading = indexOf(p.history, "SaveState=loading")
		local err = indexOf(p.history, "SaveState=error")
		local ok = indexOf(p.history, "SaveState=ok")
		h.ok(loading and err and ok and loading < err and err < ok, "loading -> error -> ok")
		h.contains(env.logs, "load recovered user=107")
	end)

	h.test("save: a save failure shows the error state, keeps the award and recovers (L23)", function()
		local backing: any = {}
		local store = flaky(SaveService.newMemoryStore(backing))
		local env = newEnv({ backing = backing, store = store, config = { writeCooldown = 0, saveAttempts = 3 } })
		local p = h.fakePlayer(108)
		load(env, p)
		store.failing = true
		h.eq(env.svc.award(p, "token", "race:DINO-4", "finish"), "awarded")
		env.sched.advance(30)
		h.eq(p:GetAttribute("SaveState"), "error")
		h.contains(p:GetAttribute("SaveMessage"), "not saved yet")
		h.ok(env.svc.get(p).tokens["race:DINO-4"], "award kept in memory")
		h.eq(backing.u_108.profile.tokens["race:DINO-4"], nil)
		store.failing = false
		env.sched.advance(60)
		h.eq(p:GetAttribute("SaveState"), "ok")
		h.eq(backing.u_108.profile.tokens["race:DINO-4"], true)
	end)

	h.test("save: a corrupt record is reported and never overwritten", function()
		local backing: any = { u_109 = { profile = "garbage" } }
		local env = newEnv({ backing = backing, config = { writeCooldown = 0, loadAttempts = 2 } })
		local p = h.fakePlayer(109)
		local _, state = load(env, p)
		h.eq(state, "error")
		h.contains(p:GetAttribute("SaveMessage"), "could not be read")
		h.eq(backing.u_109, { profile = "garbage" })
		p:leave()
		h.eq(release(env, p), true)
		h.eq(backing.u_109, { profile = "garbage" })
	end)

	h.test("save: session lock contention between two servers; only the holder writes", function()
		local sched = h.newScheduler()
		local backing: any = {}
		local cfg = { writeCooldown = 0, lockTimeout = 180, lockRetry = 5 }
		local a = newEnv({ sched = sched, backing = backing, sessionId = "server-A", config = cfg })
		local b = newEnv({ sched = sched, backing = backing, sessionId = "server-B", config = cfg })
		local pa, pb = h.fakePlayer(110), h.fakePlayer(110)
		load(a, pa)
		a.svc.award(pa, "token", "race:DINO-4", "finish")
		local bResult = nil
		sched.spawn(function()
			bResult = table.pack(b.svc.load(pb))
		end)
		sched.advance(20)
		h.eq(bResult, nil, "B waits while A holds the lock")
		h.eq(pb:GetAttribute("SaveState"), "loading")
		h.contains(pb:GetAttribute("SaveMessage"), "another server")
		h.eq(b.svc.get(pb), nil)
		h.eq(b.store.writes, 0, "B wrote nothing")
		h.eq(b.svc.award(pb, "key", "DINO", "keyPickup"), "queued")
		a.svc.award(pa, "key", "DINO", "keyPickup")
		h.eq(backing.u_110.session.id, "server-A")
		h.eq(backing.u_110.profile.keys.DINO, true, "the holder keeps writing")
		pa:leave()
		h.ok(release(a, pa))
		h.eq(backing.u_110.session, nil)
		sched.advance(6)
		h.ok(bResult and bResult[2] == "ok", "B loads on its next retry after the unlock")
		h.eq(backing.u_110.session.id, "server-B")
		local snap = b.svc.get(pb)
		h.ok(snap.tokens["race:DINO-4"] and snap.keys.DINO, "B sees everything A saved")
		h.eq(h.count(b.logs, "noop user=110 kind=key"), 1, "B's queued key is a noop on the loaded profile")
		h.eq(a.svc.award(pa, "token", "race:SNOW-1", "finish"), "rejected", "A has no session left")
	end)

	h.test("save: a stale lock is taken over and the old server can no longer write", function()
		local sched = h.newScheduler()
		local backing: any = {}
		local cfg = { writeCooldown = 0, lockTimeout = 180, lockRetry = 5 }
		local a = newEnv({ sched = sched, backing = backing, sessionId = "server-A", config = cfg })
		local b = newEnv({ sched = sched, backing = backing, sessionId = "server-B", config = cfg })
		local pa, pb = h.fakePlayer(111), h.fakePlayer(111)
		load(a, pa)
		a.svc.award(pa, "token", "race:DINO-4", "finish")
		-- Server A hangs: no heartbeat, no release.
		local bResult = nil
		sched.spawn(function()
			bResult = table.pack(b.svc.load(pb))
		end)
		sched.advance(170)
		h.eq(bResult, nil, "lock still fresh at 170 s")
		sched.advance(15)
		h.ok(bResult and bResult[2] == "ok", "B takes over once the lock is 180 s old")
		h.eq(backing.u_111.session.id, "server-B")
		h.contains(b.logs, "took over stale lock from server-A")
		h.ok(bResult and bResult[1].tokens["race:DINO-4"], "B keeps A's last saved progress")
		local writesA = a.store.writes
		a.svc.award(pa, "key", "DINO", "keyPickup")
		h.eq(a.store.writes, writesA, "A's write is refused after losing the lock")
		h.eq(backing.u_111.profile.keys.DINO, nil)
		h.eq(pa:GetAttribute("SaveState"), "error")
		h.contains(a.logs, "session lost user=111")
		h.eq(a.svc.award(pa, "key", "DINO", "keyPickup"), "rejected")
		b.svc.award(pb, "key", "DINO", "keyPickup")
		h.eq(backing.u_111.profile.keys.DINO, true, "B writes normally")
		pa:leave()
		h.eq(release(a, pa), false, "A's release reports nothing saved")
		h.eq(backing.u_111.session.id, "server-B", "A's release does not unlock B")
	end)

	h.test("save: heartbeat refreshes the lock so a long session never looks stale", function()
		local env = newEnv()
		local p = h.fakePlayer(112)
		load(env, p)
		h.eq(env.backing.u_112.session.lockedAt, 1000)
		env.sched.advance(100)
		env.svc.heartbeat()
		env.sched.advance(1)
		h.eq(env.backing.u_112.session.lockedAt, 1100)
	end)

	h.test("save: bestTime only improves; bad values are rejected (L18)", function()
		local env = newEnv()
		local p = h.fakePlayer(113)
		load(env, p)
		h.eq(env.svc.award(p, "bestTime", "DINO-4", "timeTrial", 65000), "awarded")
		h.eq(env.svc.award(p, "bestTime", "DINO-4", "timeTrial", 70000), "noop")
		h.eq(env.svc.award(p, "bestTime", "DINO-4", "timeTrial", 65000), "noop", "equal is not an improvement")
		h.eq(env.svc.award(p, "bestTime", "DINO-4", "timeTrial", 60000), "awarded")
		for _, bad in ipairs({ -5, 0, math.huge, 0 / 0 }) do
			h.eq(env.svc.award(p, "bestTime", "DINO-4", "timeTrial", bad), "rejected", "bad time " .. tostring(bad))
		end
		h.eq(env.svc.award(p, "bestTime", "DINO-4", "timeTrial"), "rejected", "missing time")
		h.eq(env.svc.award(p, "bestTime", "SNOW-1", "timeTrial", 50000), "rejected", "SNOW still locked")
		h.eq(env.svc.award(p, "bestTime", "HUB-0", "timeTrial", 50000), "rejected", "no time trial on the hub")
		h.eq(env.backing.u_113.profile.bestTimes, { ["DINO-4"] = 60000 })
		h.contains(env.logs, "is not faster than")
	end)

	h.test("save: migration from version 0", function()
		local backing: any = {
			-- v0 record: no version, no session, race win keyed by bare track id, partial boss table.
			u_114 = {
				profile = {
					tokens = { ["DINO-4"] = true, HubFind_Ground = true },
					boss = { DINO = { first = true } },
					bestTimes = { ["DINO-4"] = 71000 },
				},
			},
		}
		local env = newEnv({ backing = backing })
		local p = h.fakePlayer(114)
		local snap, state = load(env, p)
		h.eq(state, "ok")
		h.eq(snap.version, SaveService.CURRENT_VERSION)
		h.eq(snap.tokens, { ["race:DINO-4"] = true, HubFind_Ground = true })
		h.eq(snap.boss.DINO, { first = true, rematch = false })
		h.eq(snap.boss.FOREST, { first = false, rematch = false })
		h.eq(snap.bestTimes, { ["DINO-4"] = 71000 })
		h.eq(snap.gears, 0)
		h.eq(snap.winPass.season, 1)
		h.ok(Progression.isModeUnlocked(snap, "DINO-4", "coin"), "migrated boss win still unlocks the coin challenge")
		h.eq(p:GetAttribute("SkyTokens"), 2)
		h.eq(backing.u_114.profile.version, SaveService.CURRENT_VERSION, "migrated record written back with the lock")
		h.eq(backing.u_114.profile.tokens["DINO-4"], nil)
		h.contains(env.logs, "migratedFrom=0")
	end)

	h.test("save: a v2 record from the wins-era Win Pass loads with races = 0 and every claim, win and premium kept (economy v3)", function()
		local raw: any = SaveService.newProfile()
		raw.winPass = { season = 1, wins = 7, premium = true, claimedFree = { ["1"] = true, ["5"] = true }, claimedPremium = { ["1"] = true } }
		raw.cosmetics.owned = { Livery_WP1_Rookie = true, Livery_WP1_Bronze = true, Trail_WP1_Premium = true }
		local backing: any = { u_122 = { profile = raw } }
		local env = newEnv({ backing = backing })
		local p = h.fakePlayer(122)
		local snap, state = load(env, p)
		h.eq(state, "ok")
		h.eq(snap.version, SaveService.CURRENT_VERSION, "no version bump: an additive field never locks out older servers")
		h.eq(snap.winPass, { season = 1, wins = 7, races = 0, premium = true, claimedFree = { ["1"] = true, ["5"] = true }, claimedPremium = { ["1"] = true } })
		h.eq(snap.cosmetics.owned, { Livery_WP1_Rookie = true, Livery_WP1_Bronze = true, Trail_WP1_Premium = true })
		h.eq(p:GetAttribute("WinPassRaces"), 0)
		h.eq(p:GetAttribute("WinPassWins"), 7)
		-- A record a newer build wrote with races keeps the count.
		local raw2: any = SaveService.newProfile()
		raw2.winPass.races = 12
		local p2 = h.fakePlayer(123)
		local snap2 = load(newEnv({ backing = { u_123 = { profile = raw2 } } }), p2)
		h.eq(snap2.winPass.races, 12)
	end)

	h.test("save: a newer-version record is refused, never rewritten by an older server", function()
		local raw: any = SaveService.newProfile()
		raw.version = SaveService.CURRENT_VERSION + 1
		raw.gears = { soft = 500, premium = 3 } -- the newer build changed this field's type
		local backing: any = { u_115 = { profile = raw } }
		local env = newEnv({ backing = backing, config = { writeCooldown = 0, loadAttempts = 2 } })
		local p = h.fakePlayer(115)
		local snap, state = load(env, p)
		h.eq(snap, nil)
		h.eq(state, "error")
		h.contains(p:GetAttribute("SaveMessage"), "newer version")
		h.eq(env.store.writes, 0, "nothing written")
		h.eq(backing.u_115.profile.gears, { soft = 500, premium = 3 }, "newer data untouched")
		h.eq(backing.u_115.session, nil, "no lock taken")
		h.ok(not pcall(SaveService.migrate, raw), "migrate refuses it too")
	end)

	h.test("save: unknown fields in a current-version record survive a write", function()
		local raw: any = SaveService.newProfile()
		raw.futureField = { laps = 3 }
		local backing: any = { u_121 = { profile = raw } }
		local env = newEnv({ backing = backing })
		local p = h.fakePlayer(121)
		load(env, p)
		env.svc.award(p, "token", "race:DINO-4", "finish")
		h.eq(backing.u_121.profile.futureField, { laps = 3 })
		h.eq(backing.u_121.profile.tokens["race:DINO-4"], true)
	end)

	h.test("save: awards whose mode is still locked are rejected and write nothing", function()
		local env = newEnv()
		local p = h.fakePlayer(116)
		load(env, p)
		local writes = env.store.writes
		local cases = {
			{ "bossFirst", "DINO" },
			{ "bossRematch", "DINO" },
			{ "token", "coin:DINO-4" },
			{ "token", "race:SNOW-1" },
			{ "battle", "DINO" },
			{ "finalBoss", "HUB-BOSS-1" },
			{ "token", "HubFind_Ground" },
			{ "hubFind", "race:DINO-4" },
			{ "key", "SPACE" },
			{ "key", "HUB-0" },
			{ "token", "race:MOON-9" },
			{ "gems", "x" },
		}
		for _, case in ipairs(cases) do
			h.eq(env.svc.award(p, case[1], case[2], "forged"), "rejected", case[1] .. " " .. case[2])
		end
		h.eq(env.store.writes, writes)
		h.eq(Progression.tokenCount(env.svc.get(p)), 0)
	end)

	h.test("save: a full launch run derives fragments, the Battle Amulet and its livery (L75)", function()
		local env = newEnv()
		local p = h.fakePlayer(117)
		load(env, p)
		playEverything(env, p)
		local snap = env.svc.get(p)
		h.eq(snap.fragments, 4)
		h.eq(snap.battleFragments, 4)
		h.ok(snap.battleAmulet)
		h.ok(snap.finalBoss)
		h.ok(snap.cosmetics.owned[Progression.BATTLE_AMULET_LIVERY], "exclusive livery granted by progression")
		for name, value in pairs({ SkyTokens = 14, Keys = 4, BossFragments = 4, BattleFragments = 4 }) do
			h.eq(p:GetAttribute(name), value, name)
		end
		h.eq(Progression.completion(snap).text, "14/14 tokens, 4/4 keys, 4/4 boss fragments, 4/4 battle fragments, final boss beaten; more worlds coming")
		h.eq(env.svc.award(p, "battle", "DINO", "battleReplay"), "noop", "battle replay gives no second fragment")
		h.eq(env.svc.award(p, "bossRematch", "SNOW", "rematchReplay"), "noop")
		h.eq(env.svc.award(p, "finalBoss", "HUB-BOSS-1", "finalReplay"), "noop")
		h.eq(env.svc.get(p).battleFragments, 4)
		local stored = env.backing.u_117.profile
		h.eq(stored.fragments, 4)
		h.eq(stored.battleAmulet, true)
	end)

	h.test("save: the award that completes the Battle Amulet reports it", function()
		local env = newEnv()
		local p = h.fakePlayer(118)
		load(env, p)
		for _, zone in ipairs({ "DINO", "SNOW", "ISLAND", "FOREST" }) do
			-- Open each portal with hub finds and race wins first so the key award is legal.
			if zone == "SNOW" then
				env.svc.award(p, "hubFind", "HubFind_Ground", "hubPickup")
			elseif zone == "ISLAND" then
				env.svc.award(p, "hubFind", "HubFind_WaterEdge", "hubPickup")
			elseif zone == "FOREST" then
				env.svc.award(p, "hubFind", "HubFind_Ledge", "hubPickup")
				env.svc.award(p, "hubFind", "HubFind_Cove", "hubPickup")
			end
			env.svc.award(p, "key", zone, "keyPickup")
			local result, opened = env.svc.award(p, "battle", zone, "battleWin")
			h.eq(result, "awarded")
			h.eq(indexOf(opened, "battleAmulet") ~= nil, zone == "FOREST", zone)
		end
	end)

	h.test("save: every award saves, coalesced to the per-key write cooldown", function()
		local env = newEnv({ config = { writeCooldown = 6 } })
		local p = h.fakePlayer(119)
		load(env, p)
		local writes = env.store.writes
		env.svc.award(p, "hubFind", "HubFind_Ground", "hubPickup")
		env.sched.advance(1)
		env.svc.award(p, "hubFind", "HubFind_Cove", "hubPickup")
		h.eq(env.store.writes, writes, "inside the cooldown of the load write")
		env.sched.advance(6)
		h.eq(env.store.writes, writes + 1, "one write carries both awards")
		h.eq(env.backing.u_119.profile.tokens, { HubFind_Ground = true, HubFind_Cove = true })
	end)

	h.test("save: writes wait for request budget", function()
		local backing: any = {}
		local inner = SaveService.newMemoryStore(backing)
		local budgeted: any = { kind = "budgeted", remaining = 10, data = backing }
		function budgeted.update(key: string, transform: (any) -> any, userIds: { number }?): (boolean, string?)
			return inner.update(key, transform, userIds)
		end
		function budgeted.budget(): number
			return budgeted.remaining
		end
		local env = newEnv({ backing = backing, store = budgeted })
		local p = h.fakePlayer(120)
		load(env, p)
		budgeted.remaining = 0
		env.svc.award(p, "hubFind", "HubFind_Ground", "hubPickup")
		env.sched.advance(2)
		h.eq(inner.writes, 1, "only the load write so far")
		budgeted.remaining = 5
		env.sched.advance(1)
		h.eq(inner.writes, 2)
		h.contains(env.logs, "budget exhausted")
	end)

	h.test("save: BindToClose flushAll saves and unlocks everyone within the deadline", function()
		local env = newEnv({ config = { writeCooldown = 6 } })
		local players = {}
		for i = 1, 3 do
			local p = h.fakePlayer(130 + i)
			load(env, p)
			env.svc.award(p, "token", "race:DINO-4", "finish")
			players[i] = p
		end
		local start = env.sched.now
		local ok = env.sched.run(function()
			return env.svc.flushAll(25)
		end)
		h.eq(ok, true)
		h.ok(env.sched.now - start <= 25, "within the deadline")
		for i = 1, 3 do
			local record = env.backing["u_" .. tostring(130 + i)]
			h.eq(record.session, nil, "unlocked")
			h.eq(record.profile.tokens["race:DINO-4"], true, "award flushed")
			h.eq(env.svc.get(players[i]), nil)
		end
	end)

	h.test("save: flushAll gives up at its deadline when the store is down", function()
		local backing: any = {}
		local store = flaky(SaveService.newMemoryStore(backing))
		local env = newEnv({ backing = backing, store = store })
		local p = h.fakePlayer(140)
		load(env, p)
		store.failing = true
		local start = env.sched.now
		local ok = env.sched.run(function()
			return env.svc.flushAll(10)
		end)
		h.eq(ok, false)
		h.ok(env.sched.now - start <= 10.5, "returned by the deadline")
	end)

	h.test("save: economy fields round-trip; edit cannot touch progression (L53)", function()
		local sched = h.newScheduler()
		local backing: any = {}
		local env = newEnv({ sched = sched, backing = backing })
		local p = h.fakePlayer(150)
		load(env, p)
		h.ok(env.svc.edit(p, "raceGears", function(profile: any)
			profile.gears += 120
			profile.cosmetics.owned.Trail_Spark = true
			profile.cosmetics.loadout.trail = "Trail_Spark"
			profile.winPass.wins = 3
			profile.winPass.races = 9
			profile.winPass.claimedFree["1"] = true
			profile.winPass.claimedFree.r5 = true
			profile.streak.dailyDay = 20379
			profile.streak.dailyCount = 2
			profile.streak.lastClaimAt = 1760745600
			profile.settings.musicVolume = 0.4
		end))
		h.eq(env.svc.edit(p, "forged", function(profile: any)
			profile.tokens["race:DINO-4"] = true
		end), false, "progression only through award")
		h.eq(env.svc.edit(p, "broken", function(profile: any)
			profile.gears = 999999
			error("boom")
		end), false)
		h.contains(env.logs, "reject edit user=150 reason=forged")
		p:leave()
		release(env, p)
		local p2 = h.fakePlayer(150)
		local snap = load(newEnv({ sched = sched, backing = backing, sessionId = "server-B" }), p2)
		h.eq(snap.gears, 120)
		h.eq(snap.cosmetics, { owned = { Trail_Spark = true }, loadout = { trail = "Trail_Spark" } })
		h.eq(snap.winPass.wins, 3)
		h.eq(snap.winPass.races, 9)
		h.eq(snap.winPass.claimedFree, { ["1"] = true, r5 = true })
		h.eq(snap.streak, { dailyDay = 20379, dailyCount = 2, lastClaimAt = 1760745600, loginShownDay = 0 })
		h.eq(snap.settings, { musicVolume = 0.4 })
		h.eq(snap.tokens, {})
	end)

	h.test("save: an edit that DataStore cannot store is rejected and never blocks progression saves", function()
		local env = newEnv()
		local p = h.fakePlayer(151)
		load(env, p)
		h.eq(env.svc.edit(p, "sparseTiers", function(profile: any)
			profile.gears = 50
			profile.winPass.claimedFree = { [1] = true, [5] = true } -- sparse numeric keys
		end), false)
		h.contains(env.logs, "reject edit user=151 reason=sparseTiers")
		h.eq(env.svc.get(p).gears, 0, "a rejected edit leaves no partial change")
		h.eq(env.svc.award(p, "token", "race:DINO-4", "finish"), "awarded")
		env.sched.advance(1)
		h.eq(env.backing.u_151.profile.tokens["race:DINO-4"], true, "the token still saves")
	end)

	h.test("save: edit callbacks may not yield and cannot grant or remove the Battle Amulet livery", function()
		local env = newEnv()
		local p = h.fakePlayer(152)
		load(env, p)
		h.eq(env.svc.edit(p, "yields", function(profile: any)
			profile.gears = 10
			coroutine.yield()
		end), false)
		h.contains(env.logs, "must not yield")
		h.eq(env.svc.get(p).gears, 0)
		h.eq(env.svc.edit(p, "shopBug", function(profile: any)
			profile.cosmetics.owned[Progression.BATTLE_AMULET_LIVERY] = true
		end), false, "never sold")
		h.eq(env.svc.get(p).cosmetics.owned[Progression.BATTLE_AMULET_LIVERY], nil)
		playEverything(env, p)
		h.eq(env.svc.edit(p, "wipe", function(profile: any)
			profile.cosmetics.owned = {}
		end), false, "a progression reward cannot be removed by an edit")
		h.ok(env.svc.get(p).cosmetics.owned[Progression.BATTLE_AMULET_LIVERY])
	end)

	h.test("save: a player who leaves while the load waits for budget leaves no lock behind", function()
		local backing: any = {}
		local inner = SaveService.newMemoryStore(backing)
		local budgeted: any = { kind = "budgeted", remaining = 0, data = backing }
		function budgeted.update(key: string, transform: (any) -> any, userIds: { number }?): (boolean, string?)
			return inner.update(key, transform, userIds)
		end
		function budgeted.budget(): number
			return budgeted.remaining
		end
		local env = newEnv({ backing = backing, store = budgeted })
		local p = h.fakePlayer(153)
		env.sched.spawn(function()
			env.svc.load(p)
		end)
		env.sched.advance(1)
		p:leave()
		env.sched.spawn(function()
			env.svc.release(p)
		end)
		budgeted.remaining = 10
		env.sched.advance(20)
		h.eq(inner.writes, 0, "no load after the player left")
		h.eq(backing.u_153, nil)
	end)

	h.test("save: a non-number stored best time is replaced, not a crash", function()
		local raw: any = SaveService.newProfile()
		raw.bestTimes["DINO-4"] = "fast"
		local env = newEnv({ backing = { u_154 = { profile = raw } } })
		local p = h.fakePlayer(154)
		load(env, p)
		h.eq(env.svc.award(p, "bestTime", "DINO-4", "timeTrial", 60000), "awarded")
		h.eq(env.svc.get(p).bestTimes["DINO-4"], 60000)
	end)

	h.test("save: get returns a frozen snapshot detached from the live profile", function()
		local env = newEnv()
		local p = h.fakePlayer(160)
		load(env, p)
		local snap = env.svc.get(p)
		h.ok(not pcall(function()
			snap.tokens["race:DINO-4"] = true
		end), "snapshot is read-only")
		h.eq(env.svc.award(p, "token", "race:DINO-4", "finish"), "awarded", "the live profile is untouched by the attempt")
		h.eq(snap.tokens["race:DINO-4"], nil, "old snapshot does not change")
	end)

	h.test("save: the memory store rejects what DataStore cannot serialize", function()
		local store = SaveService.newMemoryStore({})
		local ok, err = store.update("k", function()
			return { tiers = { [1] = true, [5] = true } }
		end)
		h.eq(ok, false)
		h.contains(err, "mixes array and dictionary keys")
		h.eq(store.update("k", function()
			return { list = { 1, 2 }, map = { a = 1 } }
		end), true)
	end)

	h.test("save: no client path to award (no remotes in SaveService)", function()
		local source = h.readFile("src/server/SaveService.luau")
		for _, needle in ipairs({ "OnServerEvent", "OnServerInvoke", "Instance.new", "FireServer" }) do
			h.ok(not string.find(source, needle, 1, true), needle)
		end
	end)

	h.test("save: Studio without API access picks the mock and init wires join, leave and BindToClose", function()
		h.stubs.RunService.studio = true
		local service = SaveService.service()
		h.eq(service.backend, "mock")
		h.eq(h.stubs.workspace:GetAttribute("SaveBackend"), "mock")
		h.contains(h.logs, "using the in-memory mock")
		SaveService.init()
		h.eq(#h.stubs.game.closers, 1, "BindToClose registered")
		h.eq(#h.stubs.Players.PlayerAdded.handlers, 1)
		h.eq(#h.stubs.Players.PlayerRemoving.handlers, 1)
		local p = h.fakePlayer(170)
		h.stubs.Players.PlayerAdded:Fire(p)
		h.eq(p:GetAttribute("SaveState"), "ok")
		h.eq(SaveService.get(p).version, SaveService.CURRENT_VERSION)
	end)
end
