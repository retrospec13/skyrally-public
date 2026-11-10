-- Battle access (pick board 2026-10-20): a zone's battle opens when its map race was finished once (any placing) or its hidden
-- key was found; old profiles are derived from saved fields; the results card shows BATTLE only when it is open.
-- Run: tools/tests/run_lune_tests.sh tools/tests/battle_access_spec.luau
return function(h)
	local Progression = h.require("src/shared/Progression.luau")
	local R = h.require("src/shared/BattleAccessRules.luau")
	local Spec = h.require("src/shared/NotifySpec.luau")

	-- A profile as SaveService stores it (portal open for the zone under test: DINO needs 0 tokens, SNOW needs 1).
	local function profile(over: any?): any
		local p: any = { tokens = {}, boss = {}, keys = {}, battles = {}, finalBoss = false, bestTimes = {} }
		for k, v in pairs(over or {}) do
			p[k] = v
		end
		return p
	end

	h.test("access: neither a finished map nor a key keeps the battle shut", function()
		local p = profile()
		h.eq(Progression.battleAccess(p, "DINO-4"), nil)
		h.ok(not Progression.isModeUnlocked(p, "DINO-4", "battle"))
		h.eq(#Progression.battleZones(p), 0)
	end)

	h.test("access: a finished map race opens it, whatever the placing (a best time is saved for every finish)", function()
		local p = profile({ bestTimes = { ["DINO-4"] = 183500 } })
		h.eq(Progression.battleAccess(p, "DINO-4"), "complete")
		h.ok(Progression.isModeUnlocked(p, "DINO-4", "battle"), "no win, no key needed")
		h.ok(not Progression.isModeUnlocked(p, "DINO-4", "boss"), "the boss still wants the race win")
		h.eq(Progression.battleZones(p), { "DINO" })
		h.eq(Progression.modesFor(p, "DINO-4"), { "race", "timetrial", "quickrace", "battle" })
	end)

	h.test("access: the key alone still opens it (no finish needed), and the finish wins the label when both hold", function()
		local keyOnly = profile({ keys = { DINO = true } })
		h.eq(Progression.battleAccess(keyOnly, "DINO-4"), "key")
		h.ok(Progression.isModeUnlocked(keyOnly, "DINO-4", "battle"))
		local both = profile({ keys = { DINO = true }, bestTimes = { ["DINO-4"] = 90000 } })
		h.eq(Progression.battleAccess(both, "DINO-4"), "complete")
	end)

	h.test("access: each zone follows its own map; another map's finish or key opens nothing", function()
		local p = profile({ bestTimes = { ["DINO-4"] = 1000 }, keys = { ISLAND = true }, tokens = { ["race:DINO-4"] = true } })
		h.ok(Progression.isModeUnlocked(p, "DINO-4", "battle"))
		h.ok(not Progression.isModeUnlocked(p, "SNOW-1", "battle"), "SNOW portal shut and nothing finished there")
		h.ok(not Progression.isModeUnlocked(p, "ISLAND-2", "battle"), "ISLAND portal needs 2 tokens")
		local open = profile({ bestTimes = { ["DINO-4"] = 1000 }, tokens = { ["race:DINO-4"] = true, ["coin:DINO-4"] = true }, keys = { ISLAND = true } })
		h.ok(Progression.isModeUnlocked(open, "ISLAND-2", "battle"), "portal open + key")
		h.ok(not Progression.isModeUnlocked(open, "SNOW-1", "battle"), "SNOW: portal open but not finished and no key")
		h.eq(Progression.battleZones(open), { "DINO", "ISLAND" })
	end)

	h.test("access: SPACE and the hub have no battle, finished or not", function()
		local p = profile({ finalBoss = true, bestTimes = { ["SPACE-4"] = 5000, ["HUB-0"] = 5000 } })
		h.eq(Progression.battleAccess(p, "SPACE-4"), nil)
		h.ok(not Progression.isModeUnlocked(p, "SPACE-4", "battle"))
		h.ok(not Progression.isModeUnlocked(p, "HUB-0", "battle"))
		h.eq(Progression.battleAccess(p, "NOPE"), nil)
	end)

	h.test("old profiles: derived from saved fields, no migration, no stored flag", function()
		-- A record from before bestTimes existed in the type: only the race token says the map was done.
		local legacyWin = { tokens = { ["race:DINO-4"] = true }, boss = {}, keys = {}, battles = {}, finalBoss = false }
		h.ok(Progression.isModeUnlocked(legacyWin, "DINO-4", "battle"), "a race win token counts")
		-- A finish that was not a win left only a best time.
		local legacyTime = profile({ bestTimes = { ["DINO-4"] = 201000 } })
		h.ok(Progression.isModeUnlocked(legacyTime, "DINO-4", "battle"))
		-- Junk in the saved table never opens anything.
		for _, bad in { 0, -5, "fast", true } do
			h.ok(not Progression.isModeUnlocked(profile({ bestTimes = { ["DINO-4"] = bad } }), "DINO-4", "battle"), "bad time " .. tostring(bad))
		end
		h.ok(not Progression.isModeUnlocked(profile({ tokens = { ["coin:DINO-4"] = true } }), "DINO-4", "battle"), "a coin token is not a finished race")
		-- Unlock never moves a threshold or a count.
		local p = profile({ bestTimes = { ["DINO-4"] = 1 } })
		h.eq(Progression.tokenCount(p), 0)
		h.eq(Progression.keyCount(p), 0)
		h.eq(Progression.battleFragmentCount(p), 0)
	end)

	h.test("codec: BattlesOpen round-trips in chain order and ignores junk", function()
		h.eq(R.encode({ "DINO", "SNOW" }), "DINO,SNOW")
		h.eq(R.encode({}), "")
		local set = R.decode("DINO,ISLAND,BOGUS,,")
		h.ok(set.DINO and set.ISLAND and not set.BOGUS)
		h.eq(R.count(set), 2)
		h.eq(R.count(R.decode(nil)), 0)
		h.eq(R.count(R.decode(5)), 0)
	end)

	h.test("lock reason: board words", function()
		h.eq(R.lockReason("Molten Cavern"), "Finish Molten Cavern to unlock")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, "BattleAccessRules.lockReason(")
	end)

	h.test("button: shown on a standard race card of a track whose battle is open, nowhere else", function()
		local open = R.decode("DINO,SNOW")
		h.ok(R.cardButton("race", "DINO-4", open))
		h.ok(R.cardButton("quickrace", "SNOW-1", open))
		h.ok(R.cardButton("timetrial", "DINO-4", open))
		h.ok(R.cardButton("boss", "DINO-4", open))
		h.ok(not R.cardButton("race", "ISLAND-2", open), "that zone's battle is shut")
		h.ok(not R.cardButton("race", "SPACE-4", open), "no SPACE battle")
		h.ok(not R.cardButton("battle", "DINO-4", open), "the battle has its own results panel")
		h.ok(not R.cardButton("stormcup", "DINO-4", open))
		h.ok(not R.cardButton("stormrace", "DINO-4", open))
		h.ok(not R.cardButton("hub", "HUB-0", open))
		h.ok(not R.cardButton(nil, "DINO-4", open))
		h.ok(not R.cardButton("race", nil, open))
		h.ok(not R.cardButton("race", "DINO-4", R.decode("")), "nothing open")
	end)

	h.test("button: the finishing race opens the battle, so its card shows BATTLE at once", function()
		-- Finishing writes the best time; the replicated list then names the zone and the card (built after the award) offers it.
		local p = profile()
		h.ok(not R.cardButton("race", "SNOW-1", R.decode(R.encode(Progression.battleZones(p)))))
		p.tokens["race:DINO-4"] = true
		p.tokens["coin:DINO-4"] = true -- SNOW portal needs 1 token
		p.bestTimes["SNOW-1"] = 150000
		h.ok(R.cardButton("race", "SNOW-1", R.decode(R.encode(Progression.battleZones(p)))))
	end)

	h.test("button row: three buttons fill the card exactly, two keep the old split", function()
		local w3 = R.cardWeights(true)
		h.ok(math.abs(w3[1] + w3[2] + w3[3] - 1) < 1e-9)
		h.ok(w3[2] > 0)
		local w2 = R.cardWeights(false)
		h.eq(w2[2], 0)
		h.ok(math.abs(w2[1] + w2[3] - 1) < 1e-9)
	end)

	h.test("explainer: due once, only when a battle is open and the profile has loaded", function()
		local open = R.decode("DINO")
		h.ok(R.introDue(open, false))
		h.ok(not R.introDue(open, true), "already seen")
		h.ok(not R.introDue(open, nil), "profile not loaded yet")
		h.ok(not R.introDue(R.decode(""), false), "nothing open")
	end)

	h.test("explainer: 3 short lines, calm hub only, answered once", function()
		local row = Spec.get("battle_first_explain")
		h.eq(row.surface, "modal")
		local lines = string.split(row.copy, "\n")
		h.eq(#lines, 3)
		for _, l in lines do
			h.ok(#l <= 44, "short line: " .. l)
		end
		h.contains(row.copy, "Survival")
		h.contains(row.copy, "Hoard")
		h.contains(row.copy, "fragments")
		h.ok(string.find(row.copy, "%d rivals") == nil, "no fixed rival count: fields are 4 (egg, hoard) or 8")
		local la = h.readFile("src/client/LadderNotices.luau")
		h.contains(la, 'LadderNotices.queueTopic("battles")')
		h.contains(la, "BattleIntroSeen")
		local sv = h.readFile("src/server/SaveService.luau")
		h.contains(sv, "function SaveService.markBattleIntro")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, '"BattleIntroSeen"')
	end)

	h.test("keys stay meaningful: the key copy is about the Amulet and fragments, not access", function()
		local found = Spec.get("key_found").copy
		h.contains(found, "Amulet")
		h.ok(not string.find(found, "open", 1, true), found)
		local explain = Spec.get("key_first_explain").copy
		h.contains(explain, "fragment")
		h.contains(explain, "Battle Amulet")
	end)

	h.test("pending battle: goes once the hub is reached, lapses when the vote never lands", function()
		h.eq(R.pendingStep(100, 101, "race"), "wait")
		h.eq(R.pendingStep(100, 103, "hub"), "go")
		h.eq(R.pendingStep(100, 100 + R.PENDING_SECONDS + 1, "race"), "drop")
		h.eq(R.pendingStep(100, 100 + R.PENDING_SECONDS + 1, "hub"), "drop", "a late arrival no longer starts a battle")
		-- V9: the old client-timed hub trip (RequestHub, then RequestRace after a settle) started a plain race; the card now
		-- sends one RequestBattle and the server holds the pending battle (TrackDirector.drainPendingBattles).
		local tf = h.readFile("src/client/TrackFlow.luau")
		h.contains(tf, 'fire("RequestBattle", trackId)')
		h.contains(tf, "BattleFinishButton")
		h.ok(not string.find(tf, "pendingBattle", 1, true), "no client-side pending battle left")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, 'TrackDirector.drainPendingBattles')
		h.contains(td, 'BattleAccessRules.pendingStep(pb.at, now, "hub") == "go"')
	end)

	h.test("card BATTLE route: solo after a race goes straight into the battle (no hub trip)", function()
		for _, mode in { "race", "quickrace", "timetrial", "boss", "coin", "rematch" } do
			h.eq(R.cardRoute(mode, false, false, false), "now", mode)
		end
		h.eq(R.cardRoute("hub", false, false, false), "now", "pressed after the auto-return")
		h.eq(R.cardRoute("hub", true, false, false), "now", "group already in the hub: the board's lobby path")
	end)

	h.test("card BATTLE route: 2+ humans vote HUB first; busy while loading; refused elsewhere", function()
		h.eq(R.cardRoute("race", true, false, false), "hub")
		h.eq(R.cardRoute("race", false, false, true), "busy")
		h.eq(R.cardRoute("battle", false, false, false), "refused", "never from a battle")
		h.eq(R.cardRoute("stormcup", false, false, false), "refused")
		h.eq(R.cardRoute(nil, false, false, false), "refused")
		h.eq(R.cardRoute("race", false, true, false), "refused", "per group: from a race, BATTLE on the board once back")
		h.eq(R.cardRoute("hub", true, true, false), "now", "per group: from the plaza, that arch's battle lobby")
	end)

	h.test("card BATTLE wiring: one request, the battle mode, the server's unlock check", function()
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, 'action == "RequestBattle" and type(arg) == "string" and keyById[arg]')
		h.contains(td, 'TrackDirector.requestRace(player, key, "card", "battle")')
		h.contains(td, 'TrackDirector.openLobby(player, pb.key, "battle", nil)')
		h.contains(td, 'TrackDirector.requestRace(player, pb.key, "card", "battle")')
		h.contains(td, "pendingBattles[player] = nil -- FLY AGAIN after BATTLE")
	end)

	h.test("board: a shut battle names its unlock on the row", function()
		local modes = {
			{ mode = "race", open = true, why = "open" },
			{ mode = "battle", open = false, why = R.lockReason("Molten Cavern") },
		}
		h.eq(R.boardLockLine(modes), "BATTLE: Finish Molten Cavern to unlock")
		h.eq(R.boardLockLine({ { mode = "battle", open = true, why = "open" } }), nil, "open battle: no line")
		h.eq(R.boardLockLine({ { mode = "battle", open = false, why = "no profile" } }), nil, "save still loading")
		h.eq(R.boardLockLine({ { mode = "race", open = false, why = "x" } }), nil, "no battle listed")
		h.eq(R.boardLockLine(nil), nil)
		local tf = h.readFile("src/client/TrackFlow.luau")
		h.contains(tf, "BattleAccessRules.boardLockLine(st.modes)")
	end)

	h.test("the request still passes the server's unlock check", function()
		local td = h.readFile("src/server/TrackDirector.luau")
		-- requestRace -> admit -> canOpen -> Progression.isModeUnlocked; the new code adds no bypass.
		h.contains(td, "local ok, why = TrackDirector.canOpen(player, key, m)")
		local sv = h.readFile("src/server/SaveService.luau")
		-- D22: the gate gained the admin argument; adminOpen comes only from the adminBypass hook (the admin's own
		-- "admin:grant" awards), so every other player's battle award passes the unchanged gate.
		h.contains(sv, 'Progression.isModeUnlocked(profile, trackId, "battle", adminOpen)')
		h.contains(sv, "local adminOpen = adminBypass(st.userId, source)")
		h.contains(sv, "BattleAccessRules.encode(Progression.battleZones(profile))")
	end)
end
