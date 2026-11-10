-- Bot pilot outfits, cosmetics and pace (shared/BotLookRules, shared/BotPaceRules; economy v3 phase 4).
return function(h)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local L = h.require("src/shared/BotLookRules.luau")
	local P = h.require("src/shared/BotPaceRules.luau")
	local N = h.require("src/shared/BotNames.luau")
	local Mon = h.require("src/shared/MonetizationConfig.luau")

	h.test("outfits: a key parses back, anything off-catalogue does not", function()
		local k = L.outfitKey(L.HEADS[2], L.SHIRTS[1], L.PANTS[3])
		local o = L.parseOutfit(k)
		h.ok(o ~= nil)
		h.eq(o.hat, L.HEADS[2].id)
		h.eq(o.shirt, L.SHIRTS[1])
		h.eq(o.pants, L.PANTS[3])
		local bare = L.parseOutfit(L.outfitKey(L.HEADS[1], L.SHIRTS[2], L.PANTS[1]))
		h.ok(bare ~= nil and bare.hat == nil and bare.hair == nil)
		local hair = L.parseOutfit(L.outfitKey(L.HEADS[5], L.SHIRTS[2], L.PANTS[1]))
		h.eq(hair.hair, L.HEADS[5].id)
		h.eq(L.parseOutfit("o:hat999:1:2"), nil)
		h.eq(L.parseOutfit("o:hat48474313:1:382537569"), nil, "unknown shirt id")
		h.eq(L.parseOutfit("nonsense"), nil)
		h.eq(L.parseOutfit(5), nil)
		h.ok(L.OUTFIT_COUNT >= 100, "a large outfit space: " .. L.OUTFIT_COUNT)
	end)

	h.test("outfits: every catalog id is one PilotSeat already uses (no new, unchecked item)", function()
		local seat = h.readFile("src/server/kit/PilotSeat.luau")
		for _, head in L.HEADS do
			if head.id ~= 0 then
				h.ok(string.find(seat, tostring(head.id), 1, true) ~= nil, "head " .. head.id)
			end
		end
		for _, id in L.SHIRTS do
			h.ok(string.find(seat, tostring(id), 1, true) ~= nil, "shirt " .. id)
		end
		for _, id in L.PANTS do
			h.ok(string.find(seat, tostring(id), 1, true) ~= nil, "pants " .. id)
		end
	end)

	h.test("wearable: bots wear only shop or set liveries and trails of common or rare rarity, never earned rows", function()
		local liv = L.wearable(Mon.COSMETICS, "livery")
		local tr = L.wearable(Mon.COSMETICS, "trail")
		h.ok(#liv >= 5 and #tr >= 3, #liv .. " liveries " .. #tr .. " trails")
		local banned = { Livery_FounderGold = true, Livery_FounderNavy = true, Livery_WP1_Rookie = true, Trail_DailyComet = true, Trail_RookieSpark = true, Livery_ChromeComet = true, Trail_Aurora = true }
		for _, k in liv do
			h.ok(not banned[k], k)
		end
		for _, k in tr do
			h.ok(not banned[k], k)
		end
		h.ok(table.find(liv, "Livery_SunsetCoral") ~= nil and table.find(tr, "Trail_Ember") ~= nil)
	end)

	h.test("deal: 7 looks per field never repeat an outfit, vary skins, and only use wearable cosmetics", function()
		local liv = L.wearable(Mon.COSMETICS, "livery")
		local tr = L.wearable(Mon.COSMETICS, "trail")
		local rng = N.rng(77)
		local withLivery, withTrail, skins = 0, 0, {}
		for field = 1, 200 do
			local looks = L.deal(rng, 7, liv, tr)
			h.eq(#looks, 7)
			local outfits, liveries = {}, {}
			for _, look in looks do
				h.ok(not outfits[look.outfit], "outfit repeated in field " .. field)
				outfits[look.outfit] = true
				h.ok(L.parseOutfit(look.outfit) ~= nil)
				if look.livery then
					withLivery += 1
					h.ok(table.find(liv, look.livery) ~= nil)
					h.ok(not liveries[look.livery], "livery repeated in a field")
					liveries[look.livery] = true
				end
				if look.trail then
					withTrail += 1
					h.ok(table.find(tr, look.trail) ~= nil)
				end
				skins[tostring(look.skin)] = true
			end
		end
		local ratioL, ratioT = withLivery / 1400, withTrail / 1400
		h.ok(ratioL > 0.35 and ratioL < 0.75, "livery share " .. ratioL)
		h.ok(ratioT > 0.25 and ratioT < 0.55, "trail share " .. ratioT)
		local ns = 0
		for _ in skins do
			ns += 1
		end
		h.ok(ns >= 10, "skin tones: " .. ns)
		-- empty cosmetic lists are fine
		for _, look in L.deal(N.rng(1), 7, {}, {}) do
			h.ok(look.livery == nil and look.trail == nil)
		end
	end)

	h.test("pace: skill stays in 0.96-1.03, centres near 1.0, and a slot is not the same speed every race", function()
		local rng = N.rng(2024)
		local sum, lo, hi, n = 0, 9, 0, 4000
		local prev, same = nil, 0
		for _ = 1, n do
			local s = P.skill(rng)
			h.ok(s >= P.SKILL_MIN and s <= P.SKILL_MAX, "skill " .. s)
			sum += s
			lo, hi = math.min(lo, s), math.max(hi, s)
			if prev and math.abs(prev - s) < 0.001 then
				same += 1
			end
			prev = s
		end
		local mean = sum / n
		h.ok(math.abs(mean - 0.995) < 0.004, "mean " .. mean)
		h.ok(hi - lo > 0.05, "spread " .. (hi - lo))
		h.ok(same < n * 0.1, "consecutive races repeat too often: " .. same)
	end)

	h.test("pace: the skill spread can swap neighbours in the roster order (fastest is not always first)", function()
		-- roster bases 139 / 134 / 129 / 126 (PlaneConfig.AI_BOTS); a race's order is by base * skill
		local base = { 139, 134, 129, 126, 124, 121, 118 }
		local rng = N.rng(31)
		local firstWins, swaps = 0, 0
		for _ = 1, 500 do
			local best, bestV = 0, 0
			local last = 1e9
			local inOrder = true
			for i, b in base do
				local v = b * P.skill(rng)
				if v > bestV then
					best, bestV = i, v
				end
				if v > last then
					inOrder = false
				end
				last = v
			end
			if best == 1 then
				firstWins += 1
			end
			if not inOrder then
				swaps += 1
			end
		end
		h.ok(firstWins > 100 and firstWins < 495, "the fastest slot wins " .. firstWins .. " of 500")
		h.ok(swaps > 50, "order changes between races: " .. swaps)
	end)

	h.test("pace: start delay 0.1-0.4 s, slips are short and spaced, the first not in the opening seconds", function()
		local rng = N.rng(5)
		for _ = 1, 500 do
			local d = P.startDelay(rng)
			h.ok(d >= P.DELAY_MIN and d <= P.DELAY_MAX)
			local secs, factor = P.slip(rng)
			h.ok(secs >= P.SLIP_SECONDS_MIN and secs <= P.SLIP_SECONDS_MAX)
			h.ok(factor >= P.SLIP_FACTOR_MIN and factor <= P.SLIP_FACTOR_MAX)
			local at = P.nextSlipAt(rng, 0)
			h.ok(at >= P.FIRST_SLIP_MIN + P.SLIP_GAP_MIN and at <= P.FIRST_SLIP_MIN + P.SLIP_GAP_MAX)
			local later = P.nextSlipAt(rng, 100)
			h.ok(later >= 100 + P.SLIP_GAP_MIN and later <= 100 + P.SLIP_GAP_MAX)
		end
		-- a slip costs at most ~10% for about a second: under 1.5% of a 90 s race's distance per slip
		h.ok((1 - P.SLIP_FACTOR_MIN) * P.SLIP_SECONDS_MAX / 90 < 0.0016)
	end)

	h.test("pace: slip and hit recovery never stack below the lower of the two", function()
		h.eq(P.factor(0, 0.92, 0), 1)
		h.eq(P.factor(0.5, 0.92, 0), 0.92)
		h.eq(P.factor(0, 0.92, 0.5), P.HIT_RECOVER_FACTOR)
		h.eq(P.factor(0.5, 0.92, 0.5), math.min(0.92, P.HIT_RECOVER_FACTOR))
	end)

	h.test("wiring: the disguise is one config switch; personalities and palettes still key on the roster name", function()
		local cfg = h.require("src/shared/PlaneConfig.luau")
		h.eq(cfg.BOT_DISGUISE, true, "private builds run with it on")
		local ai = h.readFile("src/server/AIRacers.luau")
		h.contains(ai, "PlaneConfig.BOT_DISGUISE and not isBoss", "race bots")
		h.contains(ai, "BP.forName(bot.key)", "taunts and the rival use the roster key")
		h.eq(select(2, string.gsub(ai, "BP.forName%\(bot.name%\)", "")), 0, "no personality lookup by the shown name")
		h.contains(ai, '"AI_" .. (string.gsub(cfg.name', "the legacy name stays behind the switch")
		-- the boss keeps its own name (flag on or off): the shown name and key are taken after the boss's cfg.name is set
		local bossAt = string.find(ai, "cfg.name = boss.name", 1, true)
		local nameAt = string.find(ai, "displayName = cfg.name\n", (bossAt or 0) + 1, true)
		h.ok(bossAt ~= nil and nameAt ~= nil and nameAt > bossAt, "boss name set after the boss clone")
		h.contains(h.readFile("src/server/battle/BattleBots.luau"), "PlaneConfig.BOT_DISGUISE", "battle bots")
		local rm = h.readFile("src/server/RaceManager.luau")
		h.contains(rm, "standingsFor(player, standings)", "results payload")
		h.contains(rm, "row.racerId = nil")
		h.contains(h.readFile("src/server/init.server.luau"), "require(script.BotNamePool).start()", "the pool starts at boot")
	end)
end
