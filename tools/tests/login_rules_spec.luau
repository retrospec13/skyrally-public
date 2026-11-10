-- shared/LoginRules (economy v3 step 7): once-per-day logic, theme lookup by month, Storm countdown math, the show gate, the view.
return function(h)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local R = h.require("src/shared/LoginRules.luau")
	local Config = h.require("src/shared/MonetizationConfig.luau")
	local Spec = h.require("src/shared/NotifySpec.luau")
	local SaveService = h.require("src/server/SaveService.luau")

	local DAY = 86400
	-- 2026-11-01 00:00:00 UTC
	local NOV1 = 1793491200

	h.test("monthOf: known UTC dates, month ends, leap day, year change", function()
		h.eq(R.monthOf(0), 1) -- 1970-01-01
		h.eq(R.monthOf(NOV1), 11)
		h.eq(R.monthOf(NOV1 - 1), 10, "last second of October")
		h.eq(R.monthOf(NOV1 + 30 * DAY), 12) -- Dec 1
		h.eq(R.monthOf(NOV1 + 61 * DAY), 1) -- Jan 1 2027
		h.eq(R.monthOf(1709164800), 2) -- 2024-02-29
		h.eq(R.monthOf(1709164800 + DAY), 3) -- 2024-03-01
		h.eq(R.monthOf(1767225599), 12) -- 2025-12-31 23:59:59
		h.eq(R.monthOf(1767225600), 1) -- 2026-01-01
	end)

	h.test("theme: every month 1-12 has a complete entry; Nov is Lantern Rally, Oct is Haunted Skies", function()
		for m = 1, 12 do
			local row = Config.THEME_CALENDAR[m]
			h.ok(row ~= nil, "month " .. m)
			h.ok(#row.name > 0 and #row.pitch > 0, "text " .. m)
			h.eq(#row.accent, 3)
			for _, c in row.accent do
				h.ok(c >= 0 and c <= 255, "accent range " .. m)
			end
		end
		h.eq(R.theme(NOV1).name, "Lantern Rally")
		h.eq(R.theme(NOV1 - 1).name, "Haunted Skies")
		h.eq(R.theme(NOV1 + 30 * DAY).name, "Snow Squadron")
		h.eq(R.theme(NOV1).month, 11)
	end)

	h.test("theme: copy stays plain (no comic words, no 'livery')", function()
		for m = 1, 12 do
			local row = Config.THEME_CALENDAR[m]
			for _, text in { string.lower(row.name), string.lower(row.pitch) } do
				for _, bad in { "livery", "yay", "wow", "oops", "awesome", "amazing" } do
					h.ok(not string.find(text, bad, 1, true), "month " .. m .. " says " .. bad)
				end
			end
		end
	end)

	h.test("theme: a missing month falls back to the nearest earlier one, an empty table to a plain entry", function()
		local cfg = { THEME_CALENDAR = { [10] = { name = "Only", pitch = "p", accent = { 1, 2, 3 } } } }
		h.eq(R.theme(NOV1, cfg).name, "Only") -- November missing -> October
		h.eq(R.theme(NOV1 + 100 * DAY, cfg).name, "Only")
		h.eq(R.theme(NOV1, { THEME_CALENDAR = {} }).name, "SkyRally")
	end)

	h.test("due: once per UTC day; never shown, wrong type and an older day are due", function()
		local today = math.floor(NOV1 / DAY)
		h.ok(R.due(0, today), "default for old profiles")
		h.ok(R.due(nil, today))
		h.ok(R.due("x", today), "wrong type resets")
		h.ok(R.due(today - 1, today))
		h.ok(not R.due(today, today))
		h.ok(R.due(today, today + 1), "next UTC day is due again")
	end)

	h.test("stormCountdown: next :00 / :30 UTC, strictly after now", function()
		h.eq(select(1, R.stormCountdown(NOV1)), 1800, "exactly on a start: the next one is a full period away")
		h.eq(select(1, R.stormCountdown(NOV1 + 1)), 1799)
		h.eq(select(1, R.stormCountdown(NOV1 + 1799)), 1)
		h.eq(select(1, R.stormCountdown(NOV1 + 1800)), 1800)
		local left, at = R.stormCountdown(NOV1 + 7 * 60 + 12.5)
		h.eq(at, NOV1 + 1800)
		h.eq(left, 1800 - 432.5)
		h.eq(select(1, R.stormCountdown(NOV1 + 100, 600)), 500, "explicit period")
		-- :00 and :30 only
		for off = 0, 7200, 137 do
			local _, nextAt = R.stormCountdown(NOV1 + off)
			h.ok((nextAt % 3600 == 0) or (nextAt % 3600 == 1800), "start on the half hour")
		end
	end)

	h.test("formatClock: m:ss under an hour, h:mm:ss above, rounds up, never negative", function()
		h.eq(R.formatClock(0), "0:00")
		h.eq(R.formatClock(0.2), "0:01")
		h.eq(R.formatClock(432.5), "7:13")
		h.eq(R.formatClock(1800), "30:00")
		h.eq(R.formatClock(3723), "1:02:03")
		h.eq(R.formatClock(-5), "0:00")
	end)

	h.test("canShowNow: hub and calm only; never racing, in a lobby, before onboarding, over the Garage or another modal", function()
		local ok = { hold = nil, raceMode = "hub", onboarded = true, garageOpen = false, modalOpen = false }
		h.ok(R.canShowNow(ok))
		local function with(k, v)
			local g = table.clone(ok)
			g[k] = v
			return R.canShowNow(g)
		end
		h.ok(not with("raceMode", "race"), "race")
		h.ok(not with("raceMode", ""), "not ready")
		h.ok(not with("raceMode", nil), "no mode yet")
		for _, why in { "race", "lobby", "switching", "storm", "loading" } do
			h.ok(not with("hold", why), why)
		end
		h.ok(not with("onboarded", false), "first-timer finishes onboarding first")
		h.ok(not with("garageOpen", true))
		h.ok(not with("modalOpen", true))
	end)

	h.test("view: claimable shows the Claim card with the reward and day-7 trail; claimed shows the info card", function()
		local t = NOV1 + 7 * 60
		local v = R.view({ claimable = true, day = 3, cash = 70 }, t)
		h.eq(v.specId, "login_reward")
		h.eq(v.vars.reward, "+70 Cash")
		h.eq(v.vars.day, 3)
		h.eq(v.vars.theme, "Lantern Rally")
		h.eq(v.vars.time, "23:00")
		h.eq(v.accent, Config.THEME_CALENDAR[11].accent)
		local seven = R.view({ claimable = true, day = 7, cash = 150, trail = "Comet Streak" }, t)
		h.eq(seven.vars.reward, "+150 Cash and Comet Streak")
		local done = R.view({ claimable = false, day = 3, cash = 0 }, t)
		h.eq(done.specId, "login_info")
		h.ok(not done.claimable)
		h.eq(R.view(nil, t).specId, "login_info", "a bad reply never breaks the card")
		-- Every placeholder the rows use is supplied.
		for _, view in { v, done } do
			local text = Spec.format(Spec.get(view.specId).copy, view.vars)
			h.ok(not string.find(text, "{", 1, true), "all placeholders filled: " .. text)
			for _, name in Spec.get(view.specId).vars do
				h.ok(view.vars[name] ~= nil, "var " .. name)
			end
		end
	end)

	h.test("save: a profile from before the popup keeps its streak and defaults loginShownDay to 0 (due); a wrong type resets", function()
		local old = SaveService.migrate({ version = 2, tokens = {}, streak = { dailyDay = 20379, dailyCount = 4, lastClaimAt = 77 } })
		h.eq(old.streak, { dailyDay = 20379, dailyCount = 4, lastClaimAt = 77, loginShownDay = 0 })
		h.ok(R.due(old.streak.loginShownDay, 20380))
		local bad = SaveService.migrate({ version = 2, tokens = {}, streak = { dailyDay = 5, dailyCount = 1, lastClaimAt = 1, loginShownDay = "x" } })
		h.eq(bad.streak.loginShownDay, 0)
		local fresh = SaveService.migrate({ version = 2, tokens = {} })
		h.eq(fresh.streak.loginShownDay, 0)
	end)

	h.test("D2: a race taking the screen suspends an open unanswered modal; an answered one or a calm hub keeps it", function()
		for _, hold in { "race", "lobby", "switching" } do
			h.ok(R.raceTakesOver(hold), hold .. " takes the screen")
			h.eq(R.modalFate(true, hold, false), "suspend", hold .. ": an open unanswered card is closed (and offered again)")
			h.eq(R.modalFate(true, hold, true), "keep", hold .. ": an answered card is the player's own")
			h.eq(R.modalFate(false, hold, false), "keep", hold .. ": nothing open, nothing to close")
		end
		for _, hold in { "storm", "loading", "resume" } do
			h.ok(not R.raceTakesOver(hold), hold .. " is not a race")
		end
		h.ok(not R.raceTakesOver(nil))
		h.eq(R.modalFate(true, nil, false), "keep", "calm hub: the card stays")
		-- Re-offer: once suspended, the same gate that opened it (canShowNow) decides the next moment.
		local g = { hold = "race", raceMode = "race", onboarded = true, garageOpen = false, modalOpen = false }
		h.ok(not R.canShowNow(g), "not offered during the race")
		g.hold, g.raceMode = nil, "hub"
		h.ok(R.canShowNow(g), "offered again at the next calm hub moment")
	end)
end
