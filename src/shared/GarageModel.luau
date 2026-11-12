--!strict
-- Pure Garage and cosmetic logic (MONETIZATION_PROPOSAL section 3 UX; TEST_LIST_LAUNCH L50, L53, L56, L59). No services,
-- no Instances: the Garage panel (client/Garage), the cosmetic players (client/Cosmetics, Vfx) and the server painter
-- (server/kit/LiveryPaint) read these, and tools/tests/garage_spec.luau drives them under Lune.
-- * layout(): the panel inside a TV-safe 5% inset (below the top bar), 44 px targets, one or two columns of rows;
--   readable at 740x360 and 844x390 (L59).
-- * rows for each tab from the server's GetState/GetShop replies: owned / equipped / buyable / where it comes from.
-- * when the Garage may open (never in a race, countdown or boss intro), countdown and Gears formatting, reject copy.
-- * cosmetic recipes: livery colours per vehicle part, trail look, horn beeps, finish-flourish poses.
local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig"))
local EconomyRules = require(script.Parent:WaitForChild("EconomyRules"))
local LadderRules = require(script.Parent:WaitForChild("LadderRules"))
local AvatarConfig = require(script.Parent:WaitForChild("AvatarConfig")) -- economy v3 phase 6: the VEHICLES tab

local GarageModel = {}

type Cosmetic = MonetizationConfig.Cosmetic
type RGB = { number }

export type Tab = { id: string, label: string, kind: string?, feature: string? }

-- Every tab; `feature` names the LAUNCH_HIDE feature a tab belongs to (EconomyRules.featureOn). VEHICLES (phase 6)
-- follows AvatarConfig.ENABLED instead.
GarageModel.ALL_TABS = {
	{ id = "vehicles", label = "VEHICLES" },
	{ id = "liveries", label = "TINTS", kind = "livery" },
	{ id = "trails", label = "TRAILS", kind = "trail" },
	{ id = "horns", label = "HORNS", kind = "horn" },
	{ id = "emotes", label = "EMOTES", kind = "emote" },
	{ id = "shop", label = "SHOP" },
	{ id = "winpass", label = "WIN PASS" },
	{ id = "daily", label = "DAILY", feature = "daily" },
} :: { Tab }

-- The tabs a build shows: a tab whose feature is hidden at launch is left out (layout widths follow the count).
function GarageModel.visibleTabs(featureOn: (name: string) -> boolean): { Tab }
	local out: { Tab } = {}
	for _, t in ipairs(GarageModel.ALL_TABS) do
		if t.id == "vehicles" and not AvatarConfig.ENABLED then
			continue
		end
		if t.feature == nil or featureOn(t.feature) then
			table.insert(out, t)
		end
	end
	return out
end

GarageModel.TABS = GarageModel.visibleTabs(EconomyRules.default.featureOn)

-- What players call each cosmetic kind (vocabulary ruling 2026-10-20: the "livery" kind shows as TINT).
GarageModel.KIND_LABEL = { livery = "TINT", trail = "TRAIL", horn = "HORN", emote = "EMOTE" } :: { [string]: string }
function GarageModel.kindLabel(kind: string): string
	return GarageModel.KIND_LABEL[kind] or string.upper(kind)
end

GarageModel.MIN_TARGET = 44 -- px, every tappable thing (MONETIZATION_PROPOSAL section 3)
GarageModel.SAFE_INSET = 0.05 -- TV-safe margin on every edge
GarageModel.HORN_COOLDOWN = 2.5 -- seconds between horns (client and server agree)
GarageModel.RARITY_ORDER = { common = 1, rare = 2, epic = 3, exclusive = 4 } :: { [string]: number }
GarageModel.RARITY_RGB = {
	common = { 226, 220, 206 },
	rare = { 110, 200, 255 },
	epic = { 200, 140, 255 },
	exclusive = { 255, 214, 90 },
} :: { [string]: RGB }

-- Livery slots per kind, in the order the row's buttons show them.
GarageModel.KIND_SLOTS = {
	livery = { "planeLivery", "carLivery" },
	trail = { "trail" },
	horn = { "horn" },
	emote = { "emote" },
} :: { [string]: { string } }
GarageModel.SLOT_LABEL = { planeLivery = "PLANE", carLivery = "CAR", trail = "EQUIP", horn = "EQUIP", emote = "EQUIP" } :: { [string]: string }

---------------------------------------------------------------------------------------------------- catalog lookups

local byKey: { [string]: Cosmetic } = {}
for _, c in ipairs(MonetizationConfig.COSMETICS) do
	byKey[c.key] = c
end

function GarageModel.cosmetic(key: string?): Cosmetic?
	return if key then byKey[key] else nil
end

---------------------------------------------------------------------------------------------------- layout

export type Rect = { x: number, y: number, w: number, h: number }
export type Layout = {
	panel: Rect, -- screen px (ScreenGui with IgnoreGuiInset)
	pad: number,
	gap: number,
	header: Rect, -- panel-local
	tabs: Rect,
	tabW: number, -- every tab on a wide panel
	tabUnit: number, -- compact: the icon-only tabs
	tabWide: number, -- compact: the selected tab (icon + label)
	content: Rect,
	stage: Rect, -- content-local: the big preview column (UI v2)
	grid: Rect, -- content-local: the card grid right of the stage
	cols: number, -- cards per grid row
	cardW: number,
	cardH: number,
	columns: number, -- full-width lists (win pass tiers)
	rowW: number,
	rowH: number,
	dailyCellW: number,
	compact: boolean,
}

-- Panel geometry for a viewport (UI v2 Garage, docs/design/UI_V2.md section 2). topInset is the core top bar
-- (GuiService:GetGuiInset().Y): the panel starts below it so the menu and chat buttons never cover the header. A wide
-- panel (capped 1280x760) has a header band, a row of icon + label tabs, then the stage (the selected thing, large,
-- with its actions) on the left and the card grid on the right. A phone-height panel is compact: 44 px header and tabs,
-- the tabs are icons with only the selected one labelled (tabUnit / tabWide).
function GarageModel.layout(vw: number, vh: number, topInset: number?): Layout
	local t = GarageModel.MIN_TARGET
	local insetX = math.floor(vw * GarageModel.SAFE_INSET + 0.5)
	local insetY = math.floor(vh * GarageModel.SAFE_INSET + 0.5)
	local top = math.max(insetY, topInset or 0)
	local availW = math.max(0, vw - 2 * insetX)
	local availH = math.max(0, vh - top - insetY)
	-- v38-flow round 2: the panel fills ~84 % of a desktop screen (it was capped at 1280x760, a small window in 1080p)
	local w = math.min(availW, math.max(1280, math.floor(vw * 0.84)))
	local h = math.min(availH, math.max(760, math.floor(vh * 0.86)))
	local x = math.floor((vw - w) / 2)
	local y = top + math.floor((availH - h) / 2)
	local compact = h < 420
	local pad = if compact then 6 else 14
	local gap = if compact then 6 else 10
	local nTabs = #GarageModel.TABS
	local header = { x = pad, y = pad, w = w - 2 * pad, h = if compact then t else 56 }
	local tabs = { x = pad, y = header.y + header.h + gap, w = w - 2 * pad, h = if compact then t else 58 }
	local contentY = tabs.y + tabs.h + gap
	local content = { x = pad, y = contentY, w = w - 2 * pad, h = math.max(0, h - contentY - pad) }
	local stageW = math.floor(content.w * (if compact then 0.36 else 0.38)) -- the hero vehicle gets the room
	local stage = { x = 0, y = 0, w = stageW, h = content.h }
	local grid = { x = stageW + gap, y = 0, w = content.w - stageW - gap, h = content.h }
	local scrollBar = 6
	local cardMin = if compact then 104 else math.max(150, math.floor(w * 0.13)) -- desktop: 3-4 big picture cards a row
	local cols = math.max(2, math.floor((grid.w - scrollBar + gap) / (cardMin + gap)))
	local cardW = math.floor((grid.w - scrollBar - gap * (cols - 1)) / cols)
	local tabAvail = tabs.w - gap * (nTabs - 1)
	local unit = math.floor(tabAvail / (nTabs - 1 + 2.6))
	local columns = if w >= 880 then 2 else 1
	return {
		panel = { x = x, y = y, w = w, h = h },
		pad = pad,
		gap = gap,
		header = header,
		tabs = tabs,
		tabW = math.floor(tabAvail / nTabs),
		tabUnit = unit,
		tabWide = tabAvail - unit * (nTabs - 1),
		content = content,
		stage = stage,
		grid = grid,
		cols = cols,
		cardW = cardW,
		-- Compact: a card row (under the 48 px class bar) always fits whole, so names are never cut at the bottom.
		cardH = if compact then math.min(math.floor(cardW * 1.1), content.h - 56) else math.floor(cardW * 1.16),
		columns = columns,
		rowW = math.floor((content.w - scrollBar - gap * (columns - 1)) / columns),
		rowH = t + 8,
		-- Seven cells inside the section (content less the 6 px scroll bar lane), so DAY 7 is never clipped.
		dailyCellW = math.floor((content.w - scrollBar - gap * 6) / 7),
		compact = compact,
	}
end

-- TrackFlow's Storm Cup line hangs under the ADVENTURE bar: 4 px below it, STORM_LINE_SCALE of the bar's height.
GarageModel.STORM_LINE_SCALE = 0.6

-- Where the hub's GARAGE button sits: under TrackFlow's ADVENTURE bar (top right), same right margin, below the
-- Storm Cup line (always reserved, so the button never jumps when the line appears).
-- rightMargin and top default to the old 14 / 10; with HUD layout v2 the callers pass the safe rect's (client/HudMetrics: the
-- hub bar sits in the top-right slot at xr, yTop, insets included).
function GarageModel.hubButtonRect(vw: number, vh: number, rightMargin: number?, top: number?): Rect
	-- TrackFlow hubBar: 30% x 13% of the viewport, clamped to 240x52 .. 520x96, at (right - rightMargin, top).
	local rm = rightMargin or 14
	local t = top or 10
	local barH = math.clamp(vh * 0.13, 52, 96)
	local stormBottom = t + barH + 4 + barH * GarageModel.STORM_LINE_SCALE
	local w = if vh >= 600 then 210 else 156
	return { x = vw - rm - w, y = math.ceil(stormBottom) + 4, w = w, h = GarageModel.MIN_TARGET }
end

-- Plain names for the Storm Cup modifiers (hub line, curtain, Garage DAILY tab).
GarageModel.STORM_MODIFIER_LABEL = { night = "NIGHT", doubleItemBoxes = "DOUBLE ITEMS", mirrored = "MIRRORED" } :: { [string]: string }

---------------------------------------------------------------------------------------------------- formatting

-- "0:07", "4:12", "1:02:03", "3d 4h": the shop restock, Daily Deal, daily reset, Storm Cup and season end.
function GarageModel.formatCountdown(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	if s >= 86400 then
		return string.format("%dd %dh", s // 86400, (s % 86400) // 3600)
	elseif s >= 3600 then
		return string.format("%d:%02d:%02d", s // 3600, (s % 3600) // 60, s % 60)
	end
	return string.format("%d:%02d", s // 60, s % 60)
end

function GarageModel.formatGears(n: number): string
	local s = tostring(math.floor(math.max(0, n)))
	local out = s
	while true do
		local nextOut, k = string.gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
		out = nextOut
		if k == 0 then
			break
		end
	end
	return out
end

-- Plain copy for every reject reason Economy can answer (Economy.luau reject calls).
local REASON_TEXT: { [string]: string } = {
	disabled = "The Garage is closed right now",
	unavailable = "Not available",
	busy = "Finish your race first",
	loading = "Your save is still loading",
	owned = "You already own that",
	notOwned = "You do not own that yet",
	wrongSlot = "That does not fit there",
	badSlot = "That does not fit there",
	gears = "Not enough Cash",
	soldOut = "Sold out - restocks soon",
	notInShop = "Not in the shop right now",
	claimed = "Already claimed",
	notEnoughWins = "Win more races to unlock", -- a server on the wins-era build
	notEnoughRaces = "Finish more races to unlock",
	needsPremium = "Needs Win Pass Premium",
	seasonOver = "The season is over",
	needsGaragePlus = "Needs Garage+",
	recipientNotHere = "That racer left the server",
	recipientOwns = "They already own that",
	notGiftable = "That cannot be gifted",
	useGift = "Use the gift option",
	rateLimited = "Slow down a moment",
	noTier = "Not a Win Pass tier",
	notForSale = "Not for sale",
	badRecipient = "Pick a racer in this server",
	promptFailed = "The store could not open - try again",
	emptyOrRefused = "That slot is empty",
	-- Vehicles (economy v3 phase 6).
	earnedOnly = "Earn this one by playing",
	robuxOnly = "Coming soon",
	locked = "Keep racing this one to unlock it",
}

function GarageModel.reasonText(reason: string?): string
	return (if reason then REASON_TEXT[reason] else nil) or "Something went wrong - try again"
end

---------------------------------------------------------------------------------------------------- when it may open

export type OpenContext = {
	garageEnabled: boolean,
	mode: string?, -- workspace.RaceMode
	switching: boolean, -- workspace.TrackSwitching (curtain)
	now: number, -- server time
	goTime: number?, -- workspace.RaceGoTime (grid hold, boss intro and 3-2-1)
	finished: boolean, -- player.RaceFinished
	battleState: string?, -- workspace.BattleState
}

-- Never during a race, countdown or boss intro (the intro plays inside the RaceGoTime hold). The hub and a finished
-- player's results screen are Garage moments; a battle only once it is over.
function GarageModel.canOpen(ctx: OpenContext): (boolean, string?)
	if not ctx.garageEnabled then
		return false, "disabled"
	end
	if ctx.switching then
		return false, "loading"
	end
	if ctx.goTime and ctx.now < ctx.goTime then
		return false, "busy"
	end
	local mode = ctx.mode
	if mode == nil or mode == "" or mode == "hub" then
		return true, nil
	end
	if mode == "battle" then
		return ctx.battleState == "over", if ctx.battleState == "over" then nil else "busy"
	end
	return ctx.finished, if ctx.finished then nil else "busy"
end

---------------------------------------------------------------------------------------------------- loadout attribute

-- Decodes the player attribute Equipped (SaveService.encodeLoadout: a flat {"slot":"key"} JSON object with \uXXXX
-- escapes) without HttpService, so the server painter, Vfx and the spec share one reader. Anything else -> {}.
function GarageModel.decodeLoadout(raw: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(raw) ~= "string" then
		return out
	end
	local s = raw :: string
	local i = 1
	local n = #s
	local function skip()
		while i <= n and string.find(string.sub(s, i, i), "^%s") do
			i += 1
		end
	end
	local function readString(): string?
		if string.sub(s, i, i) ~= '"' then
			return nil
		end
		i += 1
		local parts = {}
		while i <= n do
			local c = string.sub(s, i, i)
			if c == '"' then
				i += 1
				return table.concat(parts)
			elseif c == "\\" then
				local e = string.sub(s, i + 1, i + 1)
				if e == "u" then
					local hex = string.sub(s, i + 2, i + 5)
					local code = tonumber(hex, 16)
					if not code or #hex ~= 4 then
						return nil
					end
					table.insert(parts, utf8.char(code))
					i += 6
				else
					local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
					local ch = map[e]
					if not ch then
						return nil
					end
					table.insert(parts, ch)
					i += 2
				end
			else
				table.insert(parts, c)
				i += 1
			end
		end
		return nil
	end
	skip()
	if string.sub(s, i, i) ~= "{" then
		return out
	end
	i += 1
	local result: { [string]: string } = {}
	skip()
	if string.sub(s, i, i) == "}" then
		return result
	end
	while i <= n do
		skip()
		local k = readString()
		skip()
		if not k or string.sub(s, i, i) ~= ":" then
			return out
		end
		i += 1
		skip()
		local v = readString()
		if not v then
			return out
		end
		result[k] = v
		skip()
		local c = string.sub(s, i, i)
		i += 1
		if c == "}" then
			return result
		elseif c ~= "," then
			return out
		end
	end
	return out
end

-- The cosmetic equipped in a slot, only when the row exists and is of the slot's kind.
function GarageModel.equipped(loadout: { [string]: string }, slot: string): Cosmetic?
	local item = byKey[loadout[slot] or ""]
	local kind = MonetizationConfig.SLOTS[slot]
	return if item and item.kind == kind then item else nil
end

---------------------------------------------------------------------------------------------------- tab rows

-- What the client knows: GetState (owned list, loadout, gears) and GetShop (current slots), both server answers.
export type View = {
	owned: { [string]: boolean },
	loadout: { [string]: string },
	gears: number,
	shop: { any }?, -- GetShop slots
	amulet: LadderRules.AmuletProgress?, -- keys and battle fragments held (player attributes Keys, BattleFragments), for the amulet's how-to line
}

export type ItemRow = {
	key: string,
	name: string,
	kind: string,
	rarity: string,
	owned: boolean,
	equipped: { [string]: boolean }, -- slot -> on
	anyEquipped: boolean,
	buyPrice: number?, -- in the shop now with stock left
	deal: boolean,
	soldOut: boolean,
	affordable: boolean,
	note: string?, -- where an unowned item comes from
	cosmetic: Cosmetic,
}

local SOURCE_NOTE: { [string]: string } = {
	shop = "IN THE SHOP ROTATION",
	set = "SEASON 1 SET",
	pack = "PACK ONLY",
	daily = "DAILY CLAIM DAY 7",
	winpass = "WIN PASS REWARD",
	amulet = "BATTLE AMULET REWARD",
	product = "STORE",
	storm = "STORM VENDOR (STORM SHARDS)",
}

-- Amulet-source rows that list before they are earned (with a how-to note).
GarageModel.SHOW_UNEARNED = { Livery_BattleAmulet = true } :: { [string]: boolean }

function GarageModel.ownedSet(list: { string }?): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, k in ipairs(list or {}) do
		set[k] = true
	end
	return set
end

-- Cheapest live offer per key in the shop (a Daily Deal under its rotating twin wins), as the server picks it in Buy.
local function shopOffers(shop: { any }?): { [string]: any }
	local best: { [string]: any } = {}
	for _, s in ipairs(shop or {}) do
		local live = s.soldOut ~= true
		local cur = best[s.key]
		if cur == nil or (live and (cur.soldOut or s.price < cur.price)) then
			best[s.key] = s
		end
	end
	return best
end

-- Rows for one cosmetic tab: equipped first, then owned, then buyable now (cheapest first), then the rest by rarity.
function GarageModel.itemRows(kind: string, view: View): { ItemRow }
	local offers = shopOffers(view.shop)
	local rows: { ItemRow } = {}
	for _, c in ipairs(MonetizationConfig.COSMETICS) do
		if c.kind == kind then
			local owned = view.owned[c.key] == true
			-- Progression rewards are hidden until earned, except the Battle Amulet tint: its row shows from the start with a "how to
			-- get" line (economy v3 phase 8). The duck horn stays a secret.
			if c.source ~= "amulet" or owned or GarageModel.SHOW_UNEARNED[c.key] == true then
				local equipped: { [string]: boolean } = {}
				local any = false
				for _, slot in ipairs(GarageModel.KIND_SLOTS[kind] or {}) do
					if view.loadout[slot] == c.key then
						equipped[slot] = true
						any = true
					end
				end
				local offer = offers[c.key]
				local buyable = not owned and offer ~= nil and offer.soldOut ~= true
				table.insert(rows, ({
					key = c.key,
					name = c.name,
					kind = c.kind,
					rarity = c.rarity,
					owned = owned,
					equipped = equipped,
					anyEquipped = any,
					buyPrice = if buyable then offer.price else nil,
					deal = buyable and offer.kind == "deal",
					soldOut = not owned and offer ~= nil and offer.soldOut == true,
					affordable = buyable and view.gears >= offer.price,
					note = if owned or buyable then nil
						elseif offer ~= nil then "SOLD OUT - RESTOCKS SOON"
						elseif GarageModel.SHOW_UNEARNED[c.key] == true then LadderRules.amuletHowTo(view.amulet)
						else (if c.source == "shop" or (c.source == "set" and c.gearsPrice) then "NOT IN THE SHOP NOW" else SOURCE_NOTE[c.source]),
					cosmetic = c,
				} :: any))
			end
		end
	end
	local function band(r: ItemRow): number
		return if r.anyEquipped then 0 elseif r.owned then 1 elseif r.buyPrice then 2 else 3
	end
	table.sort(rows, function(a: ItemRow, b: ItemRow): boolean
		local ba, bb = band(a), band(b)
		if ba ~= bb then
			return ba < bb
		end
		if ba == 2 and a.buyPrice ~= b.buyPrice then
			return (a.buyPrice :: number) < (b.buyPrice :: number)
		end
		local ra, rb = GarageModel.RARITY_ORDER[a.rarity] or 9, GarageModel.RARITY_ORDER[b.rarity] or 9
		if ra ~= rb then
			return ra < rb
		end
		return a.name < b.name
	end)
	return rows
end

export type ShopRow = {
	slot: string,
	key: string,
	name: string,
	kind: string,
	rarity: string,
	price: number,
	basePrice: number,
	deal: boolean,
	stockText: string,
	soldOut: boolean,
	owned: boolean,
	affordable: boolean,
	cosmetic: Cosmetic?,
}

-- The Shop tab in server order (A1-A4 always, R1.. rotating, DEAL), with the stock line players read.
function GarageModel.shopRows(shop: { any }?, gears: number): { ShopRow }
	local rows: { ShopRow } = {}
	for _, s in ipairs(shop or {}) do
		local c = byKey[s.key]
		local stockText = if s.owned then "OWNED"
			elseif s.soldOut then "SOLD OUT"
			elseif s.stock == nil then "ALWAYS IN STOCK"
			else string.format("%d LEFT", s.stock)
		table.insert(rows, ({
			slot = s.slot,
			key = s.key,
			name = if c then c.name else s.key,
			kind = if c then c.kind else "?",
			rarity = if c then c.rarity else "common",
			price = s.price,
			basePrice = s.basePrice or s.price,
			deal = s.kind == "deal",
			stockText = stockText,
			soldOut = s.soldOut == true,
			owned = s.owned == true,
			affordable = gears >= s.price,
			cosmetic = c,
		} :: any))
	end
	return rows
end

export type WinPassCell = { key: string, name: string, kind: string, status: string } -- claim|claimed|locked|premium|over
export type WinPassRow = { tier: number, reached: boolean, free: WinPassCell?, premium: WinPassCell? }

-- Tiers advance on races finished (GetState.winPass.races); claimed maps arrive keyed by the current tiers.
function GarageModel.winPassRows(wp: any): { WinPassRow }
	local cfg = MonetizationConfig.WIN_PASS
	local races = if type(wp) == "table" and type(wp.races) == "number" then wp.races else 0
	local premium = type(wp) == "table" and wp.premium == true
	local over = type(wp) ~= "table" or wp.season == nil
	local claimedFree = if type(wp) == "table" and type(wp.claimedFree) == "table" then wp.claimedFree else {}
	local claimedPremium = if type(wp) == "table" and type(wp.claimedPremium) == "table" then wp.claimedPremium else {}
	local rows: { WinPassRow } = {}
	for _, tier in ipairs(cfg.tiers) do
		local tk = tostring(tier)
		local function cell(key: string?, column: string): WinPassCell?
			local c = byKey[key or ""]
			if not c then
				return nil
			end
			local claimed = if column == "free" then claimedFree[tk] == true else claimedPremium[tk] == true
			local status = if claimed then "claimed"
				elseif over then "over"
				elseif races < tier then "locked"
				elseif column == "premium" and not premium then "premium"
				else "claim"
			return ({ key = c.key, name = c.name, kind = c.kind, status = status } :: any)
		end
		table.insert(rows, { tier = tier, reached = races >= tier, free = cell(cfg.free[tk], "free"), premium = cell(cfg.premium[tk], "premium") })
	end
	return rows
end

export type DailyCell = { day: number, gears: number, trail: string?, state: string } -- claimed|today|upcoming

-- The 7-day strip from GetState.daily: {claimedToday, streak, nextDay}.
function GarageModel.dailyCells(daily: any): { DailyCell }
	local table7 = MonetizationConfig.GEARS.daily
	local streak = if type(daily) == "table" and type(daily.streak) == "number" then daily.streak else 0
	local claimedToday = type(daily) == "table" and daily.claimedToday == true
	local nextDay = if type(daily) == "table" and type(daily.nextDay) == "number" then daily.nextDay else nil
	local cells: { DailyCell } = {}
	for day = 1, #table7 do
		local state = "upcoming"
		if claimedToday then
			state = if day <= streak then "claimed" else "upcoming"
		elseif nextDay then
			state = if day < nextDay then "claimed" elseif day == nextDay then "today" else "upcoming"
		end
		table.insert(cells, {
			day = day,
			gears = table7[day],
			trail = if day == #table7 then MonetizationConfig.GEARS.dailyTrail else nil,
			state = state,
		})
	end
	return cells
end

---------------------------------------------------------------------------------------------------- cosmetic recipes

local function lerpRGB(a: RGB, b: RGB, t: number): RGB
	return {
		math.floor(a[1] + (b[1] - a[1]) * t + 0.5),
		math.floor(a[2] + (b[2] - a[2]) * t + 0.5),
		math.floor(a[3] + (b[3] - a[3]) * t + 0.5),
	}
end
GarageModel.lerpRGB = lerpRGB

-- Paint recipe for a livery: the textured hero mesh is tinted (primary lifted 35% toward white keeps the baked panel
-- detail readable, the same lift the AI racers use), the solid parts take the flat colours. Material names are
-- Enum.Material items; the finish only touches the solid trim pieces so a Neon livery never glows all over.
export type LiveryPaint = {
	meshTint: RGB,
	primary: RGB,
	accent: RGB,
	trim: RGB,
	material: string, -- body panels of the fallback model
	trimMaterial: string, -- propeller hub, wheel hubs, spoiler
}

local FINISH_MATERIAL = { Matte = "SmoothPlastic", Gloss = "SmoothPlastic", Metal = "Metal", Neon = "SmoothPlastic" }
local FINISH_TRIM = { Matte = "SmoothPlastic", Gloss = "SmoothPlastic", Metal = "Metal", Neon = "Neon" }

function GarageModel.liveryPaint(style: MonetizationConfig.LiveryStyle): LiveryPaint
	return {
		meshTint = lerpRGB(style.primary, { 255, 255, 255 }, 0.35),
		primary = style.primary,
		accent = style.accent,
		trim = style.trim,
		material = FINISH_MATERIAL[style.finish] or "SmoothPlastic",
		trimMaterial = FINISH_TRIM[style.finish] or "SmoothPlastic",
	}
end

-- Which paint each named vehicle part takes (PlaneBuilder / CarBuilder part names). "mesh" = the textured hero mesh.
GarageModel.PART_ROLES = {
	TripoHeroPlaneMesh = "mesh",
	TripoHeroCarMesh = "mesh",
	MainWingL = "primary",
	MainWingR = "primary",
	TailFin = "accent",
	PropHub = "accent", -- PlaneBuilder's welded rotor (2026-10-19; was the loose PropSpinner/PropBlade1/PropBlade2)
	PropBladeA = "trim",
	PropBladeB = "trim",
	ThrusterGlow = "accent",
	Fallback_Chassis = "primary",
	Fallback_Seat = "accent",
	Fallback_Spoiler = "accent",
	Fallback_Bumper = "trim",
} :: { [string]: string }

-- Wheel hubs/spokes are named "<wheel>_Hub" / "<wheel>_Spoke".
function GarageModel.partRole(name: string): string?
	local role = GarageModel.PART_ROLES[name]
	if role then
		return role
	end
	if string.match(name, "_Hub$") then
		return "accent"
	elseif string.match(name, "_Spoke$") then
		return "trim"
	end
	return nil
end

-- Wingtip (plane) or rear-corner (car) ribbon for an equipped trail. The local player's ribbon stays short so it
-- fades before the chase camera (the Vfx restraint rule, 14 studs back); rivals see a longer one. OURS tuning.
export type TrailLook = {
	color0: RGB,
	color1: RGB,
	texture: string,
	lifetime: number,
	width: number, -- WidthScale at the head
	lightEmission: number,
	offsetX: number, -- hull-local attachment x (mirrored)
	offsetY: number,
	offsetZ: number,
	halfSpan: number, -- attachment separation / 2 (ribbon width in studs)
}

function GarageModel.trailLook(style: MonetizationConfig.TrailStyle, isLocal: boolean, isCar: boolean): TrailLook
	return {
		color0 = style.color0,
		color1 = style.color1,
		texture = style.texture,
		lifetime = if isLocal then 0.12 else 0.45,
		width = math.clamp(style.width, 0.5, 2),
		lightEmission = math.clamp(style.lightEmission, 0, 1),
		offsetX = if isCar then 2.3 else 7.7,
		offsetY = if isCar then 0.2 else 0.3,
		offsetZ = if isCar then 4.6 else 0.8,
		halfSpan = 0.35 * math.clamp(style.width, 0.5, 2),
	}
end

-- Horn beeps from SoundJuice's loaded sounds: one beep per pitch, gap apart. length = how long each beep sounds before
-- it is cut (nil = let the sample play out: a single fanfare). Pitches clamp to a sane range.
export type Beep = { at: number, speed: number, length: number? }

function GarageModel.hornBeeps(style: MonetizationConfig.HornStyle): { Beep }
	local out: { Beep } = {}
	local n = #style.pitches
	local gap = math.max(0, style.gap)
	for i, p in ipairs(style.pitches) do
		table.insert(out, {
			at = (i - 1) * gap,
			speed = math.clamp(p, 0.3, 3),
			length = if n > 1 then math.clamp(gap * 0.9, 0.08, 0.35) else nil,
		})
	end
	return out
end

-- Sound per horn cue: the Sound SoundJuice loads under SoundService.SkyRallySounds (cloned, so its effects come along:
-- PickupChime is the boost sample with SoundJuice's crystal pitch shift) and its base PlaybackSpeed.
GarageModel.HORN_CUES = {
	pickupChime = { sound = "PickupChime", speed = 1.35 },
	lapFanfare = { sound = "LapFanfare", speed = 1.0 },
	boostWhoosh = { sound = "BoostWhoosh", speed = 1.0 },
	-- REMARKABLE item 22: the Golden Quack's own sample (client/DuckMoments adds it to SkyRallySounds).
	goldenQuack = { sound = "GoldenQuack", speed = 1.0 },
} :: { [string]: { sound: string, speed: number } }

-- Finish flourish pose at progress t (0..1): rotations in radians about the vehicle's own axes and a lift in studs,
-- applied to a stand-in of the hero mesh while the real hull keeps its line. Cars spin and hop instead of rolling.
export type Pose = { roll: number, pitch: number, yaw: number, lift: number }

local function ease(t: number): number
	local x = math.clamp(t, 0, 1)
	return x * x * (3 - 2 * x)
end

function GarageModel.emotePose(flourish: string, isCar: boolean, t: number): Pose
	local e = ease(t)
	local tau = 2 * math.pi
	local hop = math.sin(math.clamp(t, 0, 1) * math.pi)
	if flourish == "barrelRoll" or flourish == "lightning" then
		if isCar then
			return { roll = 0, pitch = 0, yaw = tau * e, lift = 3 * hop }
		end
		return { roll = tau * e, pitch = 0, yaw = 0, lift = 1.5 * hop }
	elseif flourish == "loop" then
		if isCar then
			return { roll = 0, pitch = tau * e, yaw = 0, lift = 4 * hop }
		end
		local a = tau * e
		return { roll = 0, pitch = a, yaw = 0, lift = 6 * (1 - math.cos(a)) / 2 }
	end
	-- confetti: a happy wiggle that settles
	local w = 0.35 * math.sin(4 * math.pi * t) * (1 - math.clamp(t, 0, 1))
	return { roll = if isCar then 0 else w, pitch = 0, yaw = if isCar then w else 0, lift = 1.2 * hop }
end

-- Vfx bursts during a flourish: at = fraction of the emote's seconds, preset = a Vfx PRESETS name.
function GarageModel.emoteBursts(flourish: string): { { at: number, preset: string } }
	if flourish == "confetti" then
		return { { at = 0, preset = "confetti" }, { at = 0.35, preset = "confetti" }, { at = 0.7, preset = "confetti" } }
	elseif flourish == "lightning" then
		return { { at = 0, preset = "overcharge" }, { at = 0.5, preset = "overcharge" }, { at = 0.9, preset = "finish" } }
	elseif flourish == "loop" then
		return { { at = 0.5, preset = "boost" }, { at = 1, preset = "confetti" } }
	end
	return { { at = 0.85, preset = "confetti" } }
end

---------------------------------------------------------------------------------------------------- vehicles (phase 6)

GarageModel.AVATAR_RARITY_RGB = {
	common = { 226, 220, 206 },
	rare = { 110, 200, 255 },
	epic = { 200, 140, 255 },
	legendary = { 255, 214, 90 },
} :: { [string]: RGB }

export type AvatarAction = { label: string, action: string?, tone: string }

-- The one button on a VEHICLES row (and on a pre-race pick card) for an AvatarRules.View. tone: "on" (the pick), "go",
-- "buy", "dim" (cannot afford, or earned only), "robux". action: "select", "buy", "robux" or nil (status only).
function GarageModel.avatarAction(v: any): AvatarAction
	if v.owned then
		if v.selected then
			return { label = "SELECTED", action = nil, tone = "on" }
		end
		return { label = "SELECT", action = "select", tone = "go" }
	end
	if v.acquire == "cash" and type(v.price) == "number" then
		return { label = "BUY " .. GarageModel.formatGears(v.price), action = "buy", tone = if v.affordable then "buy" else "dim" }
	end
	if v.acquire == "robux" then
		return { label = if type(v.robux) == "number" then "R$ " .. tostring(v.robux) else "ROBUX", action = "robux", tone = "robux" }
	end
	return { label = "EARN", action = nil, tone = "dim" }
end

-- The row's second line: rarity, where it comes from or OWNED, a model-not-in-yet note, and the next ladder step.
function GarageModel.avatarSub(v: any): string
	local parts = { string.upper(tostring(v.rarity)), tostring(v.note) }
	if v.built == false then
		table.insert(parts, "MODEL SOON")
	end
	if v.owned and type(v.ladder) == "table" then
		for _, step in ipairs(v.ladder) do
			if not step.unlocked then
				table.insert(parts, string.format("NEXT %s: %s", string.upper(step.name), step.need))
				break
			end
		end
	end
	return table.concat(parts, "  -  ")
end

-- Unlocked steps out of the ladder ("2/5 LOOKS").
function GarageModel.ladderCount(v: any): (number, number)
	local n, total = 0, 0
	for _, step in ipairs(if type(v.ladder) == "table" then v.ladder else {}) do
		total += 1
		if step.unlocked then
			n += 1
		end
	end
	return n, total
end

return GarageModel
