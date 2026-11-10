-- Badges (shared/BadgeRules, server/BadgeAwards; social lane): which of the five badges a profile or a finish has earned,
-- the plan for ids that are nil today (logged once, skipped), and the BadgeService side with a fake service: pcall'ed
-- calls, the UserHasBadgeAsync cache, retry spacing, and Studio awarding nothing unless BadgeQA is on.
return function(h)
	local R = h.require("src/shared/BadgeRules.luau")
	local A = h.require("src/server/BadgeAwards.luau")

	local function finish(over)
		local ev = { trackId = "DINO-4", mode = "race", rank = 3, finished = true, simulated = false }
		for k, v in over or {} do
			ev[k] = v
		end
		return ev
	end

	local function has(list, key)
		return table.find(list, key) ~= nil
	end

	h.test("ten badges (five storm badges since economy v3 phase 5), in order, with titles and descriptions the owner can paste into Creator Hub", function()
		h.eq(R.KEYS, { "first_race", "first_win", "first_boss", "all_tracks", "three_star", "storm_racer", "dragon_slayer", "dragon_hunter", "dragon_bane", "stormbreaker" })
		for _, d in R.DEFS do
			h.ok(#d.title > 0 and #d.title <= 50 and #d.description > 0 and #d.description <= 200, d.key)
		end
	end)

	h.test("every BadgeIds entry is nil today (the owner creates the badges later)", function()
		for _, key in R.KEYS do
			h.eq(A.BadgeIds[key], nil, key)
		end
		h.eq(next(A.BadgeIds), nil, "no id of any kind")
	end)

	h.test("T1-10: the ids live in shared/BadgeConfig (all nil, none invented) and BadgeAwards copies them", function()
		local C = h.require("src/shared/BadgeConfig.luau")
		h.eq(next(C.IDS), nil, "the owner has not created a badge; no id of any kind")
		h.eq(R.titleOf("first_race"), "First Flight")
		h.eq(R.titleOf("nope"), nil)
		h.eq(R.titleOf(nil), nil)
		local src = h.readFile("src/server/BadgeAwards.luau")
		h.ok(not string.find(src, "first_race = %d"), "no numeric id in BadgeAwards")
	end)

	h.test("first race: any real finish, in any position; a simulated one does not count", function()
		h.eq(R.earned({}, finish()), { "first_race" })
		h.eq(R.earned({}, finish({ simulated = true })), {})
		h.eq(R.earned({}, finish({ finished = false })), {})
		h.eq(R.earned({}, nil), {})
	end)

	h.test("first win: rank 1 in a race or quick race, or a race token already saved", function()
		h.ok(has(R.earned({}, finish({ rank = 1 })), "first_win"))
		h.ok(has(R.earned({}, finish({ rank = 1, mode = "quickrace" })), "first_win"))
		h.ok(not has(R.earned({}, finish({ rank = 2 })), "first_win"))
		h.ok(not has(R.earned({}, finish({ rank = 1, mode = "coin" })), "first_win"), "coin run is not a race win")
		h.ok(has(R.earned({ tokens = { ["race:SNOW-1"] = true } }, nil), "first_win"), "retroactive from the profile")
		h.ok(not has(R.earned({ tokens = { ["coin:SNOW-1"] = true } }, nil), "first_win"))
	end)

	h.test("first boss: a boss or rematch beaten now, a saved boss win, or the final boss", function()
		h.ok(has(R.earned({}, finish({ mode = "boss", beatBoss = true })), "first_boss"))
		h.ok(not has(R.earned({}, finish({ mode = "boss", beatBoss = false })), "first_boss"), "the boss won")
		h.ok(has(R.earned({ boss = { ["SNOW-1"] = { first = true, rematch = false } } }, nil), "first_boss"))
		h.ok(not has(R.earned({ boss = { ["SNOW-1"] = { first = false, rematch = false } } }, nil), "first_boss"))
		h.ok(has(R.earned({ finalBoss = true }, nil), "first_boss"))
	end)

	h.test("all tracks raced: every one of the five race tracks, by time, token or boss; the hub loop does not count", function()
		local p = { bestTimes = { ["DINO-4"] = 90000, ["SNOW-1"] = 90000, ["ISLAND-2"] = 90000, ["FOREST-1"] = 90000 } }
		h.ok(not has(R.earned(p, nil), "all_tracks"), "four of five")
		h.ok(has(R.earned(p, finish({ trackId = "SPACE-4" })), "all_tracks"), "the finish that completes it counts at once")
		h.ok(not has(R.earned(p, finish({ trackId = "HUB-0" })), "all_tracks"))
		p.tokens = { ["race:SPACE-4"] = true }
		h.ok(has(R.earned(p, nil), "all_tracks"), "a token on the fifth counts too")
		local viaBoss = { bestTimes = {}, boss = {}, tokens = {} }
		for _, id in { "DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1" } do
			viaBoss.boss[id] = { first = true }
		end
		viaBoss.tokens["coin:SPACE-4"] = true
		h.ok(has(R.earned(viaBoss, nil), "all_tracks"))
	end)

	h.test("three stars on any one track: race token + coin token + that zone's boss", function()
		local p = { tokens = { ["race:FOREST-1"] = true, ["coin:FOREST-1"] = true }, boss = {} }
		h.ok(not has(R.earned(p, nil), "three_star"), "two stars")
		p.boss["FOREST-1"] = { first = true }
		h.ok(has(R.earned(p, nil), "three_star"))
		local space = { tokens = { ["race:SPACE-4"] = true, ["coin:SPACE-4"] = true }, finalBoss = true }
		h.ok(has(R.earned(space, nil), "three_star"), "SPACE: the final boss is its third star")
		h.ok(not has(R.earned({ tokens = { ["race:DINO-4"] = true }, boss = { ["SNOW-1"] = { first = true } } }, nil), "three_star"), "stars are per track")
	end)

	h.test("plan: nil ids are listed once for logging and skipped; set ids are awarded; handled keys are dropped", function()
		local award, unset = R.plan({ "first_race", "first_win" }, { first_race = 1234 }, {})
		h.eq(award, { { key = "first_race", id = 1234 } })
		h.eq(unset, { "first_win" })
		local award2, unset2 = R.plan({ "first_race" }, { first_race = 1234 }, { first_race = true })
		h.eq(award2, {})
		h.eq(unset2, {})
		local bad = R.plan({ "first_race" }, { first_race = -5 }, {})
		h.eq(bad, {}, "a nonsense id is not an id")
	end)

	-- ----------------------------------------------------------------------------------------- BadgeService side

	local function fakeService(script)
		local svc = { has = {}, awarded = {}, calls = { has = 0, award = 0 }, failHas = false, failAward = false }
		function svc:UserHasBadgeAsync(userId, badgeId)
			self.calls.has += 1
			if self.failHas then
				error("HTTP 429")
			end
			return self.has[userId .. ":" .. badgeId] == true
		end
		function svc:AwardBadge(userId, badgeId)
			self.calls.award += 1
			if self.failAward then
				error("badge service down")
			end
			table.insert(self.awarded, userId .. ":" .. badgeId)
			return true
		end
		return svc
	end

	local function setup()
		local sched = h.newScheduler(1000)
		A.clock = sched.clock
		A.spawn = function(fn)
			fn()
		end
		local svc = fakeService()
		A.service = svc
		local profiles = {}
		A.profileOf = function(p)
			return profiles[p]
		end
		A.resetLogs()
		for _, key in R.KEYS do
			A.BadgeIds[key] = nil
		end
		h.stubs.workspace:SetAttribute("BadgeQA", true)
		return svc, sched, profiles
	end

	local function cleanup(p)
		A.forget(p)
		for _, key in R.KEYS do
			A.BadgeIds[key] = nil
		end
		h.stubs.workspace:SetAttribute("BadgeQA", nil)
	end

	h.test("with every id nil: earned badges log once per server and nothing touches BadgeService", function()
		local svc, _, profiles = setup()
		local p = h.fakePlayer(7001, "Rookie")
		profiles[p] = { tokens = { ["race:DINO-4"] = true }, bestTimes = { ["DINO-4"] = 90000 } }
		A.onFinish(p, finish({ rank = 1 }))
		A.onFinish(p, finish({ rank = 1 }))
		h.eq(svc.calls.has + svc.calls.award, 0)
		h.eq(h.count(h.logs, "is not set yet"), 2, "first_race and first_win, once each")
		cleanup(p)
	end)

	h.test("with an id set: UserHasBadgeAsync first, AwardBadge only when missing, then never asked again", function()
		local svc, _, profiles = setup()
		A.BadgeIds.first_race = 111
		A.BadgeIds.first_win = 222
		local p = h.fakePlayer(7002, "Winner")
		profiles[p] = { tokens = { ["race:DINO-4"] = true } }
		svc.has["7002:222"] = true -- already holds the win badge
		A.onFinish(p, finish({ rank = 1 }))
		h.eq(svc.awarded, { "7002:111" }, "only the missing badge is awarded")
		h.eq(svc.calls.has, 2)
		A.onFinish(p, finish({ rank = 1 }))
		h.eq(svc.calls.has, 2, "cached: no second lookup")
		h.eq(svc.calls.award, 1)
		cleanup(p)
	end)

	h.test("failures are pcall'ed and retried no sooner than a minute later; a finish is never broken by them", function()
		local svc, sched, profiles = setup()
		A.BadgeIds.first_race = 111
		local p = h.fakePlayer(7003, "Unlucky")
		profiles[p] = {}
		svc.failHas = true
		A.onFinish(p, finish())
		h.eq(svc.calls.has, 1)
		h.ok(h.count(h.logs, "UserHasBadgeAsync failed") + h.count(h.logs, "WARN") >= 1, "logged")
		svc.failHas = false
		sched.advance(30)
		A.onFinish(p, finish())
		h.eq(svc.calls.has, 1, "inside the retry wait")
		sched.advance(31)
		A.onFinish(p, finish())
		h.eq(svc.awarded, { "7003:111" }, "retried and awarded")
		-- AwardBadge failing
		local q = h.fakePlayer(7004, "Unlucky2")
		profiles[q] = {}
		svc.failAward = true
		A.onFinish(q, finish())
		h.eq(#svc.awarded, 1, "nothing awarded")
		svc.failAward = false
		sched.advance(61)
		A.onFinish(q, finish())
		h.eq(#svc.awarded, 2)
		cleanup(p)
		cleanup(q)
	end)

	h.test("profile load awards retroactively; a profile that has not loaded still earns the first finish", function()
		local svc, _, profiles = setup()
		A.BadgeIds.first_race = 111
		A.BadgeIds.first_boss = 333
		A.BadgeIds.three_star = 444
		local vet = h.fakePlayer(7005, "Veteran")
		profiles[vet] = {
			tokens = { ["race:DINO-4"] = true, ["coin:DINO-4"] = true },
			boss = { ["DINO-4"] = { first = true } },
			bestTimes = { ["DINO-4"] = 88000 },
		}
		A.onLoaded(vet)
		table.sort(svc.awarded)
		h.eq(svc.awarded, { "7005:111", "7005:333", "7005:444" })
		local fresh = h.fakePlayer(7006, "NoProfileYet")
		A.onFinish(fresh, finish())
		h.ok(table.find(svc.awarded, "7006:111") ~= nil, "no profile: the finish itself earns the first-race badge")
		cleanup(vet)
		cleanup(fresh)
	end)

	h.test("Studio awards nothing unless workspace.BadgeQA is true", function()
		local svc, _, profiles = setup()
		A.BadgeIds.first_race = 111
		local p = h.fakePlayer(7007, "StudioTester")
		profiles[p] = {}
		h.stubs.workspace:SetAttribute("BadgeQA", nil)
		A.onFinish(p, finish())
		h.eq(svc.calls.has + svc.calls.award, 0)
		h.stubs.workspace:SetAttribute("BadgeQA", true)
		A.onFinish(p, finish())
		h.eq(svc.awarded, { "7007:111" })
		cleanup(p)
	end)

	h.test("static: the boot script hooks badges to finishes and profile loads; the docs list every badge", function()
		local boot = h.readFile("src/server/init.server.luau")
		h.contains(boot, "BadgeAwards.onFinish(player, info)")
		h.contains(boot, "BadgeAwards.init(SaveService.get, SaveService.onLoaded)")
		local docs = h.readFile("docs/BADGES.md")
		for _, d in R.DEFS do
			h.contains(docs, d.key, "docs/BADGES.md lists " .. d.key)
			h.contains(docs, d.title, "docs/BADGES.md names " .. d.title)
		end
		h.contains(docs, "BadgeIds")
	end)

	h.test("T1-10: onAwarded fires once per really awarded badge: not for a nil id, not when already held, not on a failed award", function()
		local svc, _, profiles = setup()
		local calls = {}
		A.onAwarded = function(player, key, id)
			table.insert(calls, key .. ":" .. id)
		end
		A.BadgeIds.first_race = 111
		A.BadgeIds.first_win = 222
		local p = h.fakePlayer(7010, "Toasty")
		profiles[p] = { tokens = { ["race:DINO-4"] = true } }
		svc.has["7010:222"] = true -- already holds the win badge: no toast
		A.onFinish(p, finish({ rank = 1 }))
		h.eq(calls, { "first_race:111" })
		A.onFinish(p, finish({ rank = 1 }))
		h.eq(calls, { "first_race:111" }, "a badge handled this session never toasts twice")
		cleanup(p)

		-- A nil id: earned, logged, no award, no toast.
		local svc2, _, profiles2 = setup()
		calls = {}
		A.onAwarded = function(_, key)
			table.insert(calls, key)
		end
		local q = h.fakePlayer(7011, "NoId")
		profiles2[q] = {}
		A.onFinish(q, finish())
		h.eq(calls, {})
		h.eq(svc2.calls.award, 0)
		cleanup(q)

		-- A failed award: no toast.
		local svc3, _, profiles3 = setup()
		calls = {}
		A.onAwarded = function(_, key)
			table.insert(calls, key)
		end
		A.BadgeIds.first_race = 111
		svc3.failAward = true
		local r = h.fakePlayer(7012, "Failing")
		profiles3[r] = {}
		A.onFinish(r, finish())
		h.eq(calls, {})
		cleanup(r)
		A.onAwarded = nil
	end)

	h.test("T1-10: a throwing onAwarded hook never breaks the award; the wiring is static-checked (remote, toast, no id invented)", function()
		local svc, _, profiles = setup()
		A.BadgeIds.first_race = 111
		A.onAwarded = function()
			error("toast boom")
		end
		local p = h.fakePlayer(7013, "Boom")
		profiles[p] = {}
		A.onFinish(p, finish())
		h.eq(svc.awarded, { "7013:111" })
		cleanup(p)
		A.onAwarded = nil
		local la = h.readFile("src/client/LadderNotices.luau")
		h.contains(la, '"BadgeEarned"')
		h.contains(la, 'NotifyKit.fromSpec("badge_earned"')
		h.contains(la, "BadgeRules.titleOf")
		local ba = h.readFile("src/server/BadgeAwards.luau")
		h.contains(ba, 'BadgeAwards.REMOTE = "BadgeEarned"')
		h.contains(ba, "FireClient(player, key)")
		local init = h.readFile("src/server/init.server.luau")
		h.contains(init, "BadgeAwards.onAwarded = function")
		h.contains(init, "BadgeAwards.toastHook")
	end)
end
