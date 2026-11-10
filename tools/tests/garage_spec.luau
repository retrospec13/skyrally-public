--!strict
-- Lune spec for the Garage's pure logic: src/shared/GarageModel.luau (layout at the launch viewports, formatting, the
-- open guard, tab rows from server replies, loadout decoding, cosmetic recipes) plus static checks on the Garage client
-- and the cosmetic modules (TEST_LIST_LAUNCH L50, L53, L56, L59 UI halves).
-- Run: tools/tests/run_lune_tests.sh tools/tests/garage_spec.luau

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

local S1_START = 1794009600 -- Saturday 2026-11-07 00:00 UTC

return function(h: Harness)
	local testCommerce = table.clone(h.require("src/shared/MonetizationConfig.luau"))
	testCommerce.Enabled = true
	testCommerce.LAUNCH_HIDE = false
	h.fake("src/shared/MonetizationConfig.luau", testCommerce)
	local GarageModel = h.require("src/shared/GarageModel.luau")
	local MonetizationConfig = h.require("src/shared/MonetizationConfig.luau")
	local EconomyRules = h.require("src/shared/EconomyRules.luau")
	local SaveService = h.require("src/server/SaveService.luau")

	local function inside(r: any, x0: number, y0: number, x1: number, y1: number, msg: string)
		h.ok(r.x >= x0 and r.y >= y0 and r.x + r.w <= x1 and r.y + r.h <= y1, string.format("%s: %d,%d %dx%d outside %d,%d-%d,%d", msg, r.x, r.y, r.w, r.h, x0, y0, x1, y1))
	end

	---------------------------------------------------------------------------------------------- layout (L59)

	h.test("layout: 740x360 and 844x390 phones fit the TV-safe inset below the top bar with 44 px targets", function()
		for _, vp in { { 740, 360 }, { 844, 390 }, { 1440, 900 }, { 1920, 1080 }, { 1280, 720 } } do
			local vw, vh = vp[1], vp[2]
			for _, topBar in { 0, 36, 58 } do
				local L = GarageModel.layout(vw, vh, topBar)
				local tag = string.format("%dx%d top=%d", vw, vh, topBar)
				local insetX, insetY = math.floor(vw * 0.05 + 0.5), math.floor(vh * 0.05 + 0.5)
				inside(L.panel, insetX, math.max(insetY, topBar), vw - insetX, vh - insetY, tag .. " panel")
				h.ok(L.header.h >= 44 and L.tabs.h >= 44, tag .. " header/tabs are 44 px targets")
				h.ok(L.rowH >= 44 + 8, tag .. " rows hold a 44 px button")
				h.ok(L.tabW >= 60, tag .. " eight tabs readable (" .. L.tabW .. " px)")
				-- Content sits under the tabs and inside the panel.
				h.ok(L.content.y >= L.tabs.y + L.tabs.h, tag .. " content under tabs")
				h.ok(L.content.y + L.content.h <= L.panel.h, tag .. " content inside panel")
				-- Eight tabs (VEHICLES joined in economy v3 phase 6) and their gaps fit the tab row.
				h.ok(#GarageModel.TABS * L.tabW + (#GarageModel.TABS - 1) * L.gap <= L.tabs.w, tag .. " tabs fit")
				-- A row's right-hand buttons (two livery buttons + FAV, or BUY) and the name column fit one row.
				h.ok(L.rowW >= 54 + 2 * 80 + 64 + 100, tag .. " row width " .. L.rowW)
				h.ok(L.dailyCellW >= 60, tag .. " daily cells")
				-- Seven cells and their gaps fit the section (content less the scroll bar lane).
				h.ok(7 * L.dailyCellW + 6 * L.gap <= L.content.w - 6, tag .. " daily strip fits")
			end
		end
	end)

	h.test("layout: the 740x360 phone still shows three rows of content at once", function()
		local L = GarageModel.layout(740, 360, 58)
		h.ok(L.content.h >= 3 * L.rowH, "content " .. L.content.h .. " < 3 rows")
		h.eq(L.columns, 1)
		local D = GarageModel.layout(1920, 1080, 58)
		h.eq(D.columns, 2, "desktop uses two columns")
		h.ok(D.panel.w <= 960 and D.panel.h <= 560, "desktop panel capped")
	end)

	h.test("layout: the hub GARAGE button sits under ADVENTURE, inside the screen, 44 px tall", function()
		for _, vp in { { 740, 360 }, { 844, 390 }, { 1920, 1080 } } do
			local r = GarageModel.hubButtonRect(vp[1], vp[2])
			local barBottom = 10 + math.clamp(vp[2] * 0.13, 52, 96)
			h.ok(r.y >= barBottom, "below the adventure bar")
			-- TrackFlow's Storm Cup line (4 px under the bar, STORM_LINE_SCALE of its height) stays clear.
			local barH = math.clamp(vp[2] * 0.13, 52, 96)
			h.ok(r.y >= barBottom + 4 + barH * GarageModel.STORM_LINE_SCALE, "below the Storm Cup line")
			-- The Gears chip (20 px under the button) stays inside the bottom TV-safe inset.
			h.ok(r.y + r.h + 22 <= vp[2] * 0.95, "gears chip on screen")
			h.ok(r.h >= 44 and r.w >= 120, "target size")
			inside(r, 0, 0, vp[1], vp[2], "on screen")
		end
	end)

	---------------------------------------------------------------------------------------------- formatting

	h.test("formatCountdown: shop restock, daily reset and season end read plainly", function()
		h.eq(GarageModel.formatCountdown(0), "0:00")
		h.eq(GarageModel.formatCountdown(-5), "0:00")
		h.eq(GarageModel.formatCountdown(7), "0:07")
		h.eq(GarageModel.formatCountdown(252), "4:12")
		h.eq(GarageModel.formatCountdown(299.2), "5:00", "rounds up so 0:00 means now")
		h.eq(GarageModel.formatCountdown(3723), "1:02:03")
		h.eq(GarageModel.formatCountdown(86399), "23:59:59")
		h.eq(GarageModel.formatCountdown(3 * 86400 + 4 * 3600 + 59), "3d 4h")
	end)

	h.test("formatGears: thousands separators, no negatives", function()
		h.eq(GarageModel.formatGears(0), "0")
		h.eq(GarageModel.formatGears(300), "300")
		h.eq(GarageModel.formatGears(1240), "1,240")
		h.eq(GarageModel.formatGears(1234567), "1,234,567")
		h.eq(GarageModel.formatGears(-3), "0")
		h.eq(GarageModel.formatGears(59.7), "59")
	end)

	h.test("reasonText: every reason Economy rejects with has plain copy", function()
		local src = h.readFile("src/server/Economy.luau")
		local reasons: { [string]: boolean } = {}
		for r in string.gmatch(src, 'reject%([%w_]+, [^,]+, "(%w+)"') do
			reasons[r] = true
		end
		for _, r in { "notEnoughWins", "needsPremium", "claimed", "soldOut", "notInShop", "rateLimited" } do
			reasons[r] = true
		end
		-- Internal-only reasons fall back to the generic line on purpose.
		local internal = { badRequest = true, unknown = true, unknownAction = true, error = true, saveRefused = true }
		local generic = GarageModel.reasonText("definitely-not-a-reason")
		local n = 0
		for r in pairs(reasons) do
			n += 1
			if not internal[r] then
				h.ok(GarageModel.reasonText(r) ~= generic, "no copy for " .. r)
			end
		end
		h.ok(n >= 20, "found the reject reasons in Economy.luau (" .. n .. ")")
	end)

	---------------------------------------------------------------------------------------------- open guard (L59)

	h.test("canOpen: hub and finished results only; never in a race, countdown, boss intro or curtain", function()
		local base = { garageEnabled = true, mode = "hub", switching = false, now = 1000, goTime = nil, finished = false, battleState = nil }
		local function with(over: any): any
			local c = table.clone(base)
			for k, v in pairs(over) do
				c[k] = v
			end
			return c
		end
		h.eq(GarageModel.canOpen(base), true)
		h.eq(select(2, GarageModel.canOpen(with({ garageEnabled = false }))), "disabled")
		h.eq(GarageModel.canOpen(with({ garageEnabled = false })), false, "Enabled=false hides the Garage")
		h.eq(GarageModel.canOpen(with({ switching = true })), false, "curtain")
		-- Grid hold / boss intro / 3-2-1: RaceGoTime still ahead, even for a 'finished' flag left over.
		h.eq(GarageModel.canOpen(with({ mode = "race", goTime = 1005, finished = true })), false, "countdown")
		h.eq(GarageModel.canOpen(with({ mode = "boss", goTime = 1003.5 })), false, "boss intro inside the hold")
		h.eq(GarageModel.canOpen(with({ mode = "race", goTime = 990 })), false, "racing")
		h.eq(GarageModel.canOpen(with({ mode = "stormcup", goTime = 990 })), false, "storm cup racing")
		h.eq(GarageModel.canOpen(with({ mode = "race", goTime = 990, finished = true })), true, "results screen")
		h.eq(GarageModel.canOpen(with({ mode = "battle", goTime = 990, finished = true, battleState = "running" })), false, "battle running")
		h.eq(GarageModel.canOpen(with({ mode = "battle", goTime = 990, battleState = "over" })), true, "battle over")
		h.eq(GarageModel.canOpen(with({ mode = nil })), true, "no mode yet = hub")
	end)

	---------------------------------------------------------------------------------------------- loadout attribute

	h.test("decodeLoadout: reads SaveService.encodeLoadout exactly, rejects junk", function()
		local loadout = { planeLivery = "Livery_SunsetCoral", carLivery = "Livery_MintBreeze", trail = "Trail_Ember", horn = "Horn_Toot", emote = "Emote_Loop" }
		h.eq(GarageModel.decodeLoadout(SaveService.encodeLoadout(loadout)), loadout)
		h.eq(GarageModel.decodeLoadout(SaveService.encodeLoadout({})), {})
		local odd = { planeLivery = 'we"ird\\key\n' }
		h.eq(GarageModel.decodeLoadout(SaveService.encodeLoadout(odd)), odd, "escapes round-trip")
		h.eq(GarageModel.decodeLoadout(' { "a" : "b" , "c":"d" } '), { a = "b", c = "d" }, "whitespace")
		for _, junk in { nil, 5, "", "[]", '{"a":1}', '{"a":"b"', '{"a" "b"}', "not json", '{"a":"b",}' } do
			h.eq(GarageModel.decodeLoadout(junk), {}, "junk " .. tostring(junk))
		end
	end)

	h.test("equipped: only a real row of the slot's kind counts", function()
		h.eq(GarageModel.equipped({ trail = "Trail_Ember" }, "trail").key, "Trail_Ember")
		h.eq(GarageModel.equipped({ trail = "Horn_Toot" }, "trail"), nil, "wrong kind")
		h.eq(GarageModel.equipped({ trail = "Trail_Nope" }, "trail"), nil, "unknown key")
		h.eq(GarageModel.equipped({ planeLivery = "Livery_StormSlate" }, "carLivery"), nil, "other vehicle")
		h.eq(GarageModel.equipped({ carLivery = "Livery_StormSlate" }, "carLivery").key, "Livery_StormSlate")
	end)

	---------------------------------------------------------------------------------------------- tab rows (L50, L53, L56)

	-- A GetShop-shaped reply built from the same rules the server uses.
	local function shopReply(t: number, sold: { [string]: number }?, owned: { [string]: boolean }?): { any }
		local view = EconomyRules.default.shopAt(t)
		local slots = {}
		for _, s in ipairs(view.slots) do
			local left = if s.stock == nil then nil else math.max(0, s.stock - ((sold or {})[s.slot] or 0))
			table.insert(slots, { slot = s.slot, kind = s.kind, key = s.key, price = s.price, basePrice = s.basePrice, stock = left, soldOut = left == 0, owned = (owned or {})[s.key] == true })
		end
		return slots
	end

	h.test("itemRows: equipped, owned, buyable (cheapest first), then the rest; one row per cosmetic", function()
		local t = S1_START + 3600
		local slots = shopReply(t)
		local view = {
			owned = GarageModel.ownedSet({ "Livery_StormSlate", "Livery_CherryLacquer", "Trail_Ember" }),
			loadout = { planeLivery = "Livery_CherryLacquer" },
			gears = 350,
			shop = slots,
		}
		local rows = GarageModel.itemRows("livery", view)
		local count = 0
		for _, c in ipairs(MonetizationConfig.COSMETICS) do
			if c.kind == "livery" and (c.source ~= "amulet" or GarageModel.SHOW_UNEARNED[c.key]) then
				count += 1
			end
		end
		h.eq(#rows, count, "every livery listed (the unearned amulet tint included)")
		h.eq(rows[1].key, "Livery_CherryLacquer")
		h.ok(rows[1].equipped.planeLivery and not rows[1].equipped.carLivery, "equipped on the plane only")
		h.eq(rows[2].key, "Livery_StormSlate")
		h.ok(rows[2].owned and not rows[2].anyEquipped, "owned, not equipped")
		-- Sunset Coral and Mint Breeze are always stocked at 300 Gears: buyable, affordable with 350.
		local coral
		for _, r in ipairs(rows) do
			if r.key == "Livery_SunsetCoral" then
				coral = r
			end
		end
		h.eq(coral.buyPrice, 300)
		h.ok(coral.affordable, "350 Gears buys a 300 livery")
		local lastBand = 0
		for _, r in ipairs(rows) do
			local band = if r.anyEquipped then 0 elseif r.owned then 1 elseif r.buyPrice then 2 else 3
			h.ok(band >= lastBand, "sorted by band at " .. r.key)
			lastBand = band
			if r.owned then
				h.eq(r.buyPrice, nil, "owned rows never offer a buy")
			end
		end
	end)

	h.test("itemRows: sources say where an item comes from; the amulet livery only shows once earned", function()
		local rows = GarageModel.itemRows("livery", { owned = {}, loadout = {}, gears = 0, shop = {} })
		local notes: { [string]: string } = {}
		for _, r in ipairs(rows) do
			notes[r.key] = r.note
		end
		h.eq(notes.Livery_BattleAmulet, "FIND HIDDEN KEYS, WIN BATTLES, COLLECT 4 FRAGMENTS", "the amulet tint shows its how-to before it is owned")
		local prog = GarageModel.itemRows("livery", { owned = {}, loadout = {}, gears = 0, shop = {}, amulet = { keys = 1, fragments = 0 } })
		for _, r in ipairs(prog) do
			if r.key == "Livery_BattleAmulet" then
				h.eq(r.note, "HIDDEN KEYS 1/4 - FRAGMENTS 0/4")
				h.ok(not r.owned and r.buyPrice == nil, "never buyable")
			end
		end
		for _, k in ipairs({ "horn" }) do
			for _, r in ipairs(GarageModel.itemRows(k, { owned = {}, loadout = {}, gears = 0, shop = {} })) do
				h.ok(r.key ~= "Horn_GoldenQuack", "the duck horn stays a secret until earned")
			end
		end
		h.eq(notes.Livery_WP1_Gold, "WIN PASS REWARD")
		h.eq(notes.Livery_FounderGold, "PACK ONLY")
		h.eq(notes.Livery_S1_Glacier, "SEASON 1 SET")
		h.eq(notes.Livery_S1_Aurora, "NOT IN THE SHOP NOW", "set livery that rotates into the shop")
		h.eq(notes.Livery_ChromeComet, "NOT IN THE SHOP NOW")
		local trails = GarageModel.itemRows("trail", { owned = {}, loadout = {}, gears = 0, shop = {} })
		for _, r in ipairs(trails) do
			if r.key == "Trail_DailyComet" then
				h.eq(r.note, "DAILY CLAIM DAY 7")
			end
		end
		local withAmulet = GarageModel.itemRows("livery", { owned = { Livery_BattleAmulet = true }, loadout = {}, gears = 0, shop = {} })
		local seen = false
		for _, r in ipairs(withAmulet) do
			seen = seen or r.key == "Livery_BattleAmulet"
		end
		h.ok(seen, "an earned amulet livery is listed")
		for _, r in ipairs(withAmulet) do
			if r.key == "Livery_BattleAmulet" then
				h.eq(r.note, nil, "owned: no how-to note")
			end
		end
	end)

	h.test("itemRows: a sold-out slot is not buyable and says it restocks", function()
		local t = S1_START + 3600
		local view = EconomyRules.default.shopAt(t)
		local rotating
		for _, s in ipairs(view.slots) do
			if s.kind == "rotating" then
				rotating = s
				break
			end
		end
		local slots = shopReply(t, { [rotating.slot] = 99 })
		-- If the same key is also the Daily Deal with stock left, the deal is the live offer; otherwise it is sold out.
		local dealSame = false
		for _, s in ipairs(slots) do
			if s.kind == "deal" and s.key == rotating.key then
				dealSame = true
			end
		end
		local item = GarageModel.cosmetic(rotating.key)
		local rows = GarageModel.itemRows(item.kind, { owned = {}, loadout = {}, gears = 99999, shop = slots })
		for _, r in ipairs(rows) do
			if r.key == rotating.key then
				if dealSame then
					h.ok(r.deal and r.buyPrice ~= nil, "deal still live")
				else
					h.eq(r.buyPrice, nil)
					h.ok(r.soldOut, "sold out flag")
					h.eq(r.note, "SOLD OUT - RESTOCKS SOON")
				end
			end
		end
	end)

	h.test("shopRows: server order, stock line, deal, owned and sold-out states", function()
		local t = S1_START + 7 * 3600
		local view = EconomyRules.default.shopAt(t)
		local firstRot
		for _, s in ipairs(view.slots) do
			if s.kind == "rotating" then
				firstRot = s.slot
				break
			end
		end
		local slots = shopReply(t, { [firstRot] = 99 }, { Livery_SunsetCoral = true })
		local rows = GarageModel.shopRows(slots, 500)
		h.eq(#rows, #view.slots)
		for i, r in ipairs(rows) do
			h.eq(r.slot, view.slots[i].slot, "order")
			if r.key == "Livery_SunsetCoral" then
				h.eq(r.stockText, "OWNED")
			elseif r.slot == firstRot then
				h.eq(r.stockText, "SOLD OUT")
				h.ok(r.soldOut)
			elseif view.slots[i].stock == nil then
				h.eq(r.stockText, "ALWAYS IN STOCK")
			else
				h.eq(r.stockText, string.format("%d LEFT", view.slots[i].stock))
			end
			if r.deal then
				h.ok(r.price < r.basePrice, "deal is cheaper than its base price")
			end
			h.eq(r.affordable, 500 >= r.price)
		end
		local deals = 0
		for _, r in ipairs(rows) do
			if r.deal then
				deals += 1
			end
		end
		h.eq(deals, 1, "one Daily Deal")
	end)

	h.test("winPassRows: tiers on races finished; locked / claim / claimed / premium-gated / season over", function()
		h.eq(MonetizationConfig.WIN_PASS.tiers, { 5, 20, 45, 80, 120 }, "owner ruling 2026-10-20: races finished")
		local rows = GarageModel.winPassRows({ season = 1, wins = 0, races = 20, premium = false, claimedFree = { ["5"] = true }, claimedPremium = {} })
		h.eq(#rows, #MonetizationConfig.WIN_PASS.tiers)
		h.eq(rows[1].free.status, "claimed")
		h.eq(rows[2].free.status, "claim", "tier 20 reached on races alone (no wins)")
		h.eq(rows[3].free.status, "locked", "tier 45 not reached")
		h.eq(rows[1].premium.status, "premium", "premium column needs the product")
		h.eq(rows[1].free.key, MonetizationConfig.WIN_PASS.free["5"])
		h.eq(rows[1].premium.key, MonetizationConfig.WIN_PASS.premium["5"])
		local winsOnly = GarageModel.winPassRows({ season = 1, wins = 40, premium = false, claimedFree = {}, claimedPremium = {} })
		h.eq(winsOnly[1].free.status, "locked", "wins no longer move the tiers")
		local prem = GarageModel.winPassRows({ season = 1, races = 120, premium = true, claimedFree = {}, claimedPremium = { ["120"] = true } })
		h.eq(prem[1].premium.status, "claim")
		h.eq(prem[5].premium.status, "claimed")
		local over = GarageModel.winPassRows({ season = nil, races = 0 })
		h.eq(over[1].free.status, "over")
		h.eq(GarageModel.winPassRows(nil)[1].free.status, "over", "no data = nothing claimable")
		h.eq(GarageModel.reasonText("notEnoughRaces"), "Finish more races to unlock")
		local garage = h.readFile("src/client/Garage.luau")
		h.contains(garage, "%d/%d RACES")
		h.contains(garage, "%d RACES  -  ENDS IN")
		h.ok(not string.find(garage, "WINS", 1, true), "Garage copy says RACES, never WINS")
	end)

	h.test("dailyCells: streak strip for today, claimed and broken streaks", function()
		local fresh = GarageModel.dailyCells({ claimedToday = false, streak = 0, nextDay = 1 })
		h.eq(#fresh, 7)
		h.eq(fresh[1].state, "today")
		h.eq(fresh[2].state, "upcoming")
		h.eq(fresh[7].trail, MonetizationConfig.GEARS.dailyTrail)
		h.eq(fresh[7].gears, MonetizationConfig.GEARS.daily[7])
		local mid = GarageModel.dailyCells({ claimedToday = false, streak = 3, nextDay = 4 })
		h.eq({ mid[1].state, mid[3].state, mid[4].state, mid[5].state }, { "claimed", "claimed", "today", "upcoming" })
		local done = GarageModel.dailyCells({ claimedToday = true, streak = 4, nextDay = nil })
		h.eq({ done[4].state, done[5].state }, { "claimed", "upcoming" })
		local broken = GarageModel.dailyCells({ claimedToday = false, streak = 5, nextDay = 1 })
		h.eq(broken[1].state, "today", "a missed day restarts at day 1")
		h.eq(broken[2].state, "upcoming")
	end)

	---------------------------------------------------------------------------------------------- cosmetic recipes

	h.test("liveryPaint: every livery paints plane and car parts; Neon only glows on trim", function()
		local n = 0
		for _, c in ipairs(MonetizationConfig.COSMETICS) do
			if c.kind == "livery" then
				n += 1
				local p = GarageModel.liveryPaint(c.livery)
				for _, k in { "meshTint", "primary", "accent", "trim" } do
					local v = (p :: any)[k]
					h.ok(#v == 3 and v[1] >= 0 and v[1] <= 255 and v[2] >= 0 and v[2] <= 255 and v[3] >= 0 and v[3] <= 255, c.key .. " " .. k)
				end
				-- The tint keeps the mesh's baked detail readable: never darker than the primary.
				for i = 1, 3 do
					h.ok(p.meshTint[i] >= c.livery.primary[i], c.key .. " tint lifted")
				end
				h.ok(p.material ~= "Neon", c.key .. " body never neon")
				if c.livery.finish == "Neon" then
					h.eq(p.trimMaterial, "Neon")
				end
			end
		end
		h.ok(n >= 12, "liveries checked")
	end)

	h.test("partRole: the builders' part names map to livery roles", function()
		local plane = h.readFile("src/server/PlaneBuilder.luau")
		local car = h.readFile("src/server/kit/CarBuilder.luau")
		for name, role in pairs(GarageModel.PART_ROLES) do
			h.ok(string.find(plane, '"' .. name .. '"', 1, true) or string.find(car, '"' .. name .. '"', 1, true), name .. " exists in a builder")
			h.eq(GarageModel.partRole(name), role)
		end
		h.eq(GarageModel.partRole("Wheel_FL_Hub"), "accent")
		h.eq(GarageModel.partRole("Wheel_RR_Spoke"), "trim")
		h.eq(GarageModel.partRole("Hull"), nil, "the physics hull is never painted")
		h.eq(GarageModel.partRole("BotPilotHead"), nil)
	end)

	h.test("trailLook: the owner's ribbon fades before the chase camera, rivals see more; values clamp", function()
		local style = { color0 = { 1, 2, 3 }, color1 = { 4, 5, 6 }, texture = "trail_soft", width = 9, lightEmission = 3 }
		local mine = GarageModel.trailLook(style, true, false)
		local theirs = GarageModel.trailLook(style, false, false)
		h.ok(mine.lifetime * 160 < 30, "local ribbon at 160 studs/s stays short")
		h.ok(theirs.lifetime > mine.lifetime)
		h.eq(mine.width, 2)
		h.eq(mine.lightEmission, 1)
		h.eq(mine.offsetX, 7.7, "plane wingtips")
		h.ok(GarageModel.trailLook(style, true, true).offsetX < 3, "car rear corners")
		local vfx = h.readFile("src/shared/VfxAssets.luau")
		for _, c in ipairs(MonetizationConfig.COSMETICS) do
			if c.kind == "trail" then
				h.ok(string.find(vfx, c.trail.texture, 1, true) ~= nil, c.key .. " texture is an owned VfxAssets key")
			end
		end
	end)

	h.test("hornBeeps: one beep per pitch on SoundJuice's loaded samples", function()
		local sj = h.readFile("src/client/SoundJuice.luau")
		for _, c in ipairs(MonetizationConfig.COSMETICS) do
			if c.kind == "horn" then
				local beeps = GarageModel.hornBeeps(c.horn)
				h.eq(#beeps, #c.horn.pitches, c.key)
				for i, b in ipairs(beeps) do
					h.eq(b.at, (i - 1) * c.horn.gap)
					h.ok(b.speed >= 0.3 and b.speed <= 3)
					if #beeps > 1 then
						h.ok(b.length ~= nil and b.length <= 0.35, "multi-beep horns cut each beep")
					end
				end
				local cue = GarageModel.HORN_CUES[c.horn.cue]
				h.ok(cue ~= nil, c.key .. " cue mapped")
				-- REMARKABLE item 22: the Golden Quack's sample is added to SkyRallySounds by client/DuckMoments.
				local loaded = string.find(sj, '"' .. cue.sound .. '"', 1, true) ~= nil
					or string.find(h.readFile("src/client/DuckMoments.luau"), 's.Name = "' .. cue.sound .. '"', 1, true) ~= nil
				h.ok(loaded, cue.sound .. " is a sound SoundJuice (or DuckMoments) loads")
			end
		end
		h.ok(GarageModel.HORN_COOLDOWN >= 1, "cooldown")
	end)

	h.test("emotePose and bursts: full turns that land level; presets exist in Vfx", function()
		local vfx = h.readFile("src/client/Vfx.luau")
		for _, c in ipairs(MonetizationConfig.COSMETICS) do
			if c.kind == "emote" then
				for _, isCar in { false, true } do
					local p0 = GarageModel.emotePose(c.emote.flourish, isCar, 0)
					local p1 = GarageModel.emotePose(c.emote.flourish, isCar, 1)
					for _, k in { "roll", "pitch", "yaw" } do
						h.ok(math.abs(p0[k]) < 1e-6, c.key .. " starts level " .. k)
						local r = p1[k] % (2 * math.pi)
						h.ok(r < 1e-6 or math.abs(r - 2 * math.pi) < 1e-6, c.key .. " ends level " .. k)
					end
					h.ok(math.abs(p1.lift) < 1e-6, c.key .. " lands")
					local mid = GarageModel.emotePose(c.emote.flourish, isCar, 0.5)
					h.ok(math.abs(mid.roll) + math.abs(mid.pitch) + math.abs(mid.yaw) + math.abs(mid.lift) > 0.1, c.key .. " moves")
				end
				for _, b in ipairs(GarageModel.emoteBursts(c.emote.flourish)) do
					h.ok(b.at >= 0 and b.at <= 1)
					h.ok(string.find(vfx, "\t" .. b.preset .. " = ", 1, true) ~= nil, b.preset .. " is a Vfx preset")
				end
			end
		end
		h.eq(GarageModel.emotePose("barrelRoll", true, 0.5).roll, 0, "cars spin, never roll")
	end)

	---------------------------------------------------------------------------------------------- static guards (L50)

	h.test("client never prices from DEFAULT labels or invents ids; prompts only go through the server", function()
		for _, path in { "src/client/Garage.luau", "src/client/Cosmetics.luau", "src/shared/GarageModel.luau", "src/server/CosmeticService.luau", "src/server/kit/LiveryPaint.luau" } do
			local src = h.readFile(path)
			h.ok(string.find(src, "defaultPriceLabel", 1, true) == nil, path .. " reads defaultPriceLabel")
			h.ok(string.find(src, "PromptProductPurchase", 1, true) == nil and string.find(src, "PromptGamePassPurchase", 1, true) == nil, path .. " prompts directly")
			h.ok(string.find(src, "id%s*=%s*%d%d%d%d%d") == nil, path .. " has a numeric id literal")
		end
		local garage = h.readFile("src/client/Garage.luau")
		-- Robux rows come from GetState.products (the server lists only Enabled + real-id rows with GetProductInfo prices).
		h.contains(garage, "st.products")
		h.contains(garage, '"PromptProduct"')
		h.contains(garage, "GarageEnabled")
		h.eq(MonetizationConfig.Enabled, true, "store on for private testing (owner order 2026-10-20)")
		h.contains(garage, "COMING SOON")
		h.contains(garage, "SkyRallyStore")
	end)

	h.test("tabs: the eight Garage tabs in order (VEHICLES first, phase 6); LAUNCH_HIDE leaves DAILY out", function()
		local ids = {}
		for _, t in ipairs(GarageModel.TABS) do
			table.insert(ids, t.id)
		end
		h.eq(MonetizationConfig.LAUNCH_HIDE, false, "private builds run with everything on (owner ruling 2026-10-20)")
		h.eq(ids, { "vehicles", "liveries", "trails", "horns", "emotes", "shop", "winpass", "daily" })
		local hidden = {}
		local cfg = table.clone(MonetizationConfig)
		cfg.LAUNCH_HIDE = true
		for _, t in ipairs(GarageModel.visibleTabs(EconomyRules.new(cfg).featureOn)) do
			table.insert(hidden, t.id)
		end
		h.eq(hidden, { "vehicles", "liveries", "trails", "horns", "emotes", "shop", "winpass" })
		for kind, slots in pairs(GarageModel.KIND_SLOTS) do
			for _, slot in ipairs(slots) do
				h.eq(MonetizationConfig.SLOTS[slot], kind, slot)
			end
		end
	end)
end
