-- shared/LadderRules (economy v3 phase 8): the map-unlock ladder progress and the key / fragment / amulet copy.
-- Run: tools/tests/run_lune_tests.sh tools/tests/ladder_spec.luau
return function(h)
	local R = h.require("src/shared/LadderRules.luau")
	local Progression = h.require("src/shared/Progression.luau")
	local Spec = h.require("src/shared/NotifySpec.luau")

	local function name(zone: string): string?
		return ({ DINO = "Dino Ridge", SNOW = "Frostpeak", ISLAND = "Sunreef Isles", FOREST = "Windmill Vale", SPACE = "Neon Moon" })[zone]
	end

	h.test("ladder: D15 thresholds, in order, from Progression", function()
		local l = R.ladder(0, false)
		h.eq(#l, 5)
		local need = {}
		for _, r in ipairs(l) do
			need[r.zone] = r.need
		end
		h.eq(need.DINO, 0)
		h.eq(need.SNOW, 1)
		h.eq(need.ISLAND, 2)
		h.eq(need.FOREST, 4)
		h.eq(need.SPACE, nil)
		for zone, n in pairs(Progression.PORTAL_THRESHOLD) do
			h.eq(need[zone], n, zone .. " follows Progression")
		end
	end)

	h.test("row: open exactly at the threshold, SPACE only on the final boss", function()
		h.ok(R.row("DINO", 0, false).open)
		h.ok(not R.row("SNOW", 0, false).open)
		h.ok(R.row("SNOW", 1, false).open)
		h.ok(not R.row("ISLAND", 1, false).open)
		h.eq(R.row("ISLAND", 1, false).remaining, 1)
		h.ok(not R.row("FOREST", 3, false).open)
		h.ok(R.row("FOREST", 4, false).open)
		h.ok(not R.row("SPACE", 14, false).open, "tokens never open SPACE")
		h.ok(R.row("SPACE", 0, true).open)
		h.eq(R.row("SNOW", -3, false).have, 0, "negative clamps")
	end)

	h.test("arch text: locked shows x/y TOKENS, open shows nothing", function()
		h.eq(R.archText(R.row("ISLAND", 1, false)), "LOCKED - 1/2 TOKENS")
		h.eq(R.archText(R.row("SNOW", 0, false)), "LOCKED - 0/1 TOKENS")
		h.eq(R.archText(R.row("FOREST", 3, false)), "LOCKED - 3/4 TOKENS")
		h.eq(R.archText(R.row("SNOW", 1, false)), nil)
		h.eq(R.archText(R.row("SPACE", 14, false)), "LOCKED - FINAL BOSS")
		h.eq(R.archText(R.row("SPACE", 0, true)), nil)
		h.eq(R.progressText(R.row("ISLAND", 9, false)), "2/2 TOKENS", "capped at the need")
	end)

	h.test("hint: one line on how to get there; none when open", function()
		h.eq(R.hintText(R.row("ISLAND", 0, false)), R.SOURCES_LINE)
		h.eq(R.hintText(R.row("SPACE", 0, false)), R.BOSS_LINE)
		h.eq(R.hintText(R.row("DINO", 0, false)), nil)
		h.ok(#R.SOURCES_LINE <= 60 and #R.BOSS_LINE <= 60, "short enough for a phone sign")
		h.ok(string.find(R.SOURCES_LINE, "races", 1, true) and string.find(R.SOURCES_LINE, "coin", 1, true) and string.find(R.SOURCES_LINE, "hub", 1, true), "names all three sources")
	end)

	h.test("nextGoal / nextLine: the next shut token gate", function()
		h.eq(R.nextGoal(0).zone, "SNOW")
		h.eq(R.nextLine(0, name), "1 more for FROSTPEAK")
		h.eq(R.nextLine(1, name), "1 more for SUNREEF ISLES")
		h.eq(R.nextLine(2, name), "2 more for WINDMILL VALE")
		h.eq(R.nextLine(3, name), "1 more for WINDMILL VALE")
		h.eq(R.nextLine(4, name), nil)
		h.eq(R.nextLine(1, nil), "1 more for ISLAND", "falls back to the zone id")
	end)

	h.test("crossed / delta: a threshold fires once, a baseline fires nothing", function()
		h.eq(#R.crossed(0, 1), 1)
		h.eq(R.crossed(0, 1)[1], "SNOW")
		h.eq(#R.crossed(1, 2), 1)
		h.eq(R.crossed(1, 2)[1], "ISLAND")
		h.eq(#R.crossed(2, 3), 0)
		local both = R.crossed(0, 2)
		h.eq(#both, 2)
		h.eq(both[2], "ISLAND")
		h.eq(R.crossed(3, 4)[1], "FOREST")
		h.eq(#R.crossed(2, 2), 0)
		h.eq(#R.crossed(5, 2), 0, "a drop opens nothing")
		local gained, crossed = R.delta(nil, 3)
		h.eq(gained, 0, "first value is a baseline")
		h.eq(#crossed, 0)
		gained, crossed = R.delta(1, 2)
		h.eq(gained, 1)
		h.eq(crossed[1], "ISLAND")
		gained = R.delta(2, 2)
		h.eq(gained, 0)
	end)

	h.test("tokenVars: fill token_progress; nil once every gate is open", function()
		local v = R.tokenVars(1, name)
		h.eq(Spec.format(Spec.get("token_progress").copy, v), "Sky Tokens 1/2 for Sunreef Isles")
		h.eq(Spec.format(Spec.get("token_progress").copy, R.tokenVars(0, name)), "Sky Tokens 0/1 for Frostpeak")
		h.eq(R.tokenVars(4, name), nil)
		h.eq(Spec.get("token_gain").copy, "+1 Sky Token")
		h.eq(Spec.format(Spec.get("map_unlock").copy, { zone = "Frostpeak" }), "Frostpeak is open")
	end)

	h.test("keys: copy carries the 1/4 progress, first key only at 0 -> 1", function()
		h.eq(Spec.format(Spec.get("key_found").copy, { n = 1, total = 4, zone = "Frostpeak" }), "KEY 1/4: Frostpeak. Toward the Amulet")
		local v = R.keyVars(1)
		h.eq(v.n, 1)
		h.eq(v.total, 4)
		h.eq(R.keyVars(9).n, 4, "clamped")
		local body = Spec.format(Spec.get("key_first_explain").copy, v)
		h.ok(string.find(body, "Keys 1/4", 1, true), body)
		h.ok(string.find(body, "battle", 1, true) and string.find(body, "fragment", 1, true) and string.find(body, "Battle Amulet", 1, true), "explains key -> battle -> fragment -> amulet")
		h.ok(R.isFirstKey(1))
		h.ok(not R.isFirstKey(2) and not R.isFirstKey(0) and not R.isFirstKey(4))
		h.eq(Spec.get("key_first_explain").surface, "modal")
		-- Deferral: queued + not calm (race, countdown, boss intro, battle, lobby, Garage, other modal) waits; calm opens; nothing queued does nothing.
		h.eq(R.explainerStep(true, false), "wait")
		h.eq(R.explainerStep(true, true), "open")
		h.eq(R.explainerStep(false, true), "none")
		local la = h.readFile("src/client/LadderNotices.luau")
		h.contains(la, 'LadderNotices.queueTopic("keys")')
		h.contains(la, "enqueue(row)")
		local first = string.find(la, "NotifyKit.fromSpec(id, explainerVars(id)", 1, true)
		h.ok(first and not string.find(la, "NotifyKit.fromSpec(id, explainerVars(id)", first + 1, true) and first > (string.find(la, "function LadderNotices.drainExplainer", 1, true) or math.huge), "the modal opens only inside the calm drain")
		h.ok(first and not string.find(la, 'NotifyKit.fromSpec("key_first_explain"', first + 1, true) and first > (string.find(la, "function LadderNotices.drainExplainer", 1, true) or math.huge), "the modal opens only inside the calm drain")
	end)

	h.test("fragments and amulet: toast copy, modal, Garage how-to", function()
		h.eq(Spec.format(Spec.get("fragment_found").copy, R.fragmentVars(2)), "Battle fragment 2/4")
		h.eq(Spec.get("amulet_found").surface, "modal")
		h.eq(R.amuletHowTo(nil), "FIND HIDDEN KEYS, WIN BATTLES, COLLECT 4 FRAGMENTS")
		h.eq(R.amuletHowTo({ keys = 2, fragments = 1 }), "HIDDEN KEYS 2/4 - FRAGMENTS 1/4")
		h.eq(R.amuletHowTo({ keys = 0, fragments = 0 }), "HIDDEN KEYS 0/4 - FRAGMENTS 0/4")
		h.eq(R.KEYS_TOTAL, Progression.KEYS_TOTAL)
		h.eq(R.FRAGMENTS_TOTAL, Progression.BATTLE_FRAGMENTS_TOTAL)
	end)

	h.test("no toddler words in the copy", function()
		local bad = { "yay", "woohoo", "wow", "oopsie", "tada", "livery" }
		local texts = { R.SOURCES_LINE, R.SOURCES_SHORT, R.BOSS_LINE, R.amuletHowTo(nil) }
		for _, id in ipairs({ "key_found", "key_first_explain", "fragment_found", "amulet_found", "map_unlock", "token_progress", "token_gain" }) do
			table.insert(texts, Spec.get(id).copy)
		end
		for _, t in ipairs(texts) do
			for _, w in ipairs(bad) do
				h.ok(not string.find(string.lower(t), w, 1, true), w .. " in: " .. t)
			end
		end
	end)
end
