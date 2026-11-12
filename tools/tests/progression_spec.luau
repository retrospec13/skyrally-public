--!strict
-- Progression analytics payloads (T1-4): src/shared/ProgressionRules.luau (what each event carries) and the wiring in
-- server/Funnels, SaveService and init.server. Cash sources and sinks stay on Economy's LogEconomyEvent (checked here too).
-- Run: tools/tests/run_lune_tests.sh tools/tests/progression_spec.luau
return function(h)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local R = h.require("src/shared/ProgressionRules.luau")

	local function recorder()
		local log: { any } = {}
		local sink = {}
		for _, kind in { "start", "complete", "fail" } do
			sink[kind] = function(player, path, level, levelName, fields)
				table.insert(log, { kind = kind, player = player, path = path, level = level, levelName = levelName, fields = fields })
			end
		end
		return sink, log
	end

	h.test("race start: path race_<mode>, level 1, the track as level name; hub and battle are not races", function()
		local ev: any = R.raceStart("DINO-4", "race")
		h.eq(ev.kind, "start")
		h.eq(ev.path, "race_race")
		h.eq(ev.level, 1)
		h.eq(ev.levelName, "DINO-4")
		h.eq(ev.fields, { track = "DINO-4", mode = "race" })
		h.eq((R.raceStart("SNOW-1", "boss") :: any).path, "race_boss")
		h.eq(R.raceStart("HUB-0", "hub"), nil)
		h.eq(R.raceStart("X", "battle"), nil)
		h.eq(R.raceStart("X", nil), nil)
	end)

	h.test("race finish: Complete with the rank as level (1..99); the token rides in the detail field; no finish = Fail", function()
		local ev: any = R.raceFinish("DINO-4", "race", 3, true, true)
		h.eq(ev.kind, "complete")
		h.eq(ev.level, 3)
		h.eq(ev.fields.detail, "token")
		local plain: any = R.raceFinish("DINO-4", "race", 1, true, false)
		h.eq(plain.fields.detail, nil)
		h.eq((R.raceFinish("DINO-4", "race", nil, true) :: any).level, 1, "unknown rank reads as 1")
		h.eq((R.raceFinish("DINO-4", "race", 0 / 0, true) :: any).level, 1, "NaN is not a rank")
		h.eq((R.raceFinish("DINO-4", "race", 5000, true) :: any).level, 99)
		h.eq((R.raceFinish("DINO-4", "race", 2.7, true) :: any).level, 2)
		local dnf: any = R.raceFinish("DINO-4", "coin", nil, false)
		h.eq(dnf.kind, "fail")
		h.eq(dnf.path, "race_coin")
		h.eq(R.raceFinish("HUB-0", "hub", 1, true), nil)
	end)

	h.test("unlock: SaveService's newly opened portal or mode ids; anything else is ignored", function()
		local p: any = R.unlock("portal:ISLAND")
		h.eq(p.path, "unlock_portal")
		h.eq(p.levelName, "ISLAND")
		h.eq(p.kind, "complete")
		local m: any = R.unlock("mode:DINO-1:coin")
		h.eq(m.path, "unlock_mode")
		h.eq(m.levelName, "DINO-1:coin")
		h.eq(R.unlock("evil:thing"), nil)
		h.eq(R.unlock("portal"), nil)
		h.eq(R.unlock(5), nil)
	end)

	h.test("badge and explainer events carry the key / topic id only", function()
		local b: any = R.badge("first_race")
		h.eq(b.path, "badge")
		h.eq(b.levelName, "first_race")
		h.eq(R.badge(""), nil)
		h.eq(R.badge(nil), nil)
		h.eq((R.explainer("items", false) :: any).level, 1)
		h.eq((R.explainer("items", true) :: any).level, 2)
		h.eq((R.explainer("items") :: any).path, "explainer")
		h.eq(R.explainer(nil), nil)
	end)

	h.test("payloads never carry names or free text: dirty input is cleaned to id characters", function()
		local ev: any = R.badge("Retro Racer <b>")
		h.eq(ev.levelName, "Retro_Racer__b_")
		local fin: any = R.raceFinish("Name With Spaces", "race", 1, true)
		h.eq(fin.levelName, "Name_With_Spaces")
	end)

	h.test("emit: routes to the matching sink function, returns false for no event, and survives a throwing sink", function()
		local sink, log = recorder()
		h.ok(R.emit(sink :: any, "P1", R.raceStart("DINO-4", "race")))
		h.ok(R.emit(sink :: any, "P1", R.raceFinish("DINO-4", "race", 2, true)))
		h.ok(R.emit(sink :: any, "P1", R.raceFinish("DINO-4", "race", nil, false)))
		h.eq(#log, 3)
		h.eq(log[1].kind, "start")
		h.eq(log[2].kind, "complete")
		h.eq(log[3].kind, "fail")
		h.eq(log[2].player, "P1")
		h.ok(not R.emit(sink :: any, "P1", nil))
		h.ok(not R.emit(sink :: any, nil, R.badge("first_race")))
		local boom = {
			start = function()
				error("analytics down")
			end,
		}
		h.ok(not R.emit(boom :: any, "P1", R.raceStart("DINO-4", "race")), "a sink error is swallowed")
		h.ok(not R.emit({} :: any, "P1", R.badge("first_race")), "a sink without the function does nothing")
	end)

	h.test("wiring: Funnels sends the events through ProgressionRules (pcall-wrapped), a left or abandoned race is a Fail, the economy keeps its own events", function()
		local fn = h.readFile("src/server/Funnels.luau")
		h.contains(fn, "LogProgressionStartEvent")
		h.contains(fn, "LogProgressionCompleteEvent")
		h.contains(fn, "LogProgressionFailEvent")
		h.contains(fn, "ProgressionRules.emit")
		h.contains(fn, "ProgressionRules.raceStart")
		h.contains(fn, "ProgressionRules.raceFinish(d.track, d.mode, d.rank, true")
		h.contains(fn, "failOpenRace(p)")
		h.ok(not string.find(fn, "DisplayName", 1, true))
		local rm = h.readFile("src/server/RaceManager.luau")
		h.contains(rm, "rank = finishInfo.rank")
		local init = h.readFile("src/server/init.server.luau")
		h.contains(init, "SaveService.unlockHook")
		h.contains(init, 'Funnels.progression("badge"')
		h.contains(init, 'Funnels.progression("unlock"')
		local sv = h.readFile("src/server/SaveService.luau")
		h.contains(sv, "SaveService.unlockHook")
		-- Cash sources and sinks: every Economy track() call is one of the five known flows.
		local eco = h.readFile("src/server/Economy.luau")
		h.contains(eco, "LogEconomyEvent(player, flowType, MonetizationConfig.CURRENCY, amount, balance")
		for _, tx in { '"Gameplay"', '"TimedReward"', '"IAP"', '"Shop"' } do
			h.contains(eco, tx)
		end
	end)

	h.test("unlock hook: a real award that opens a portal reports it, once; a no-op award reports nothing", function()
		local SaveService = h.require("src/server/SaveService.luau")
		local sched = h.newScheduler()
		local svc = SaveService.new({
			store = SaveService.newMemoryStore({}),
			sessionId = "server-A",
			newToken = function(): string
				return "tok"
			end,
			now = sched.clock,
			clock = sched.clock,
			sleep = sched.sleep,
			spawn = sched.spawn,
			log = function() end,
			random = function(): number
				return 0.5
			end,
			config = { writeCooldown = 0 },
		})
		local p = h.fakePlayer(6161)
		sched.run(function()
			return svc.load(p)
		end)
		local seen: { string } = {}
		SaveService.unlockHook = function(_, key)
			table.insert(seen, key)
		end
		h.eq(svc.award(p, "token", "race:DINO-4", "spec"), "awarded")
		h.eq(svc.award(p, "token", "race:DINO-4", "spec"), "noop")
		local afterFirst = #seen
		h.eq(svc.award(p, "key", "DINO", "spec"), "awarded")
		SaveService.unlockHook = nil
		for _, k in seen do
			h.ok(string.find(k, "^portal:") ~= nil or string.find(k, "^mode:") ~= nil, k)
		end
		h.ok(#seen > 0, "two tokens opened something")
		h.ok(#seen >= afterFirst)
		h.ok(table.find(seen, "mode:DINO-4:battle") ~= nil, "the key opened the DINO battle")
	end)
	h.test("v38 next unlock: one goal at a time, portals by tokens, then the hub boss, SPACE, all tokens", function()
		local P = h.require("src/shared/Progression.luau")
		local function profile(tokens: number, rematches: number, finalBoss: boolean)
			local t = {}
			for i = 1, tokens do
				t[P.TOKENS[i]] = true
			end
			local boss = {}
			for i = 1, rematches do
				boss[P.CHAIN_ZONES[i]] = { rematch = true }
			end
			return { tokens = t, boss = boss, keys = {}, battles = {}, finalBoss = finalBoss, bestTimes = {} } :: any
		end
		local n: any = P.nextUnlock(profile(0, 0, false))
		h.eq({ n.key, n.have, n.need }, { "portal_SNOW", 0, 1 })
		n = P.nextUnlock(profile(2, 0, false))
		h.eq({ n.key, n.have, n.need }, { "portal_FOREST", 2, 4 })
		n = P.nextUnlock(profile(5, 1, false))
		h.eq({ n.key, n.have, n.need }, { "hub_boss", 1, 4 })
		n = P.nextUnlock(profile(5, 4, false))
		h.eq(n.key, "portal_SPACE")
		n = P.nextUnlock(profile(5, 4, true))
		h.eq({ n.key, n.have, n.need }, { "all_tokens", 5, P.TOKENS_TOTAL })
		h.eq(P.nextUnlock(profile(P.TOKENS_TOTAL, 4, true)), nil)
	end)
end
