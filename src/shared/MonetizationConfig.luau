--!strict
-- Shared economy data. Configure with tools/configure_release.py before local builds.
local MonetizationConfig = {}

MonetizationConfig.Enabled = false
MonetizationConfig.CURRENCY = "Cash"

-- The public-release hide list (SKYRALLY_ECONOMY_V3 sections 6 and 8) as ONE switch. Owner ruling 2026-10-20: private
-- builds run with everything on, so this stays false there and turns true only for the public release. When true:
-- * only products with liveAtLaunch = true are listed, promptable and bound for sale (4 Cash packs, 2x Cash, Win Pass
--   Premium; Robux-direct avatars join when they exist). Every other row stays in the catalog: StoreBinder holds its id
--   server-side only, so a paid receipt for it (bought before the switch, or prompted by a client directly) is still
--   granted. A paid receipt is never refused.
-- * every feature in LAUNCH_HIDDEN_FEATURES is off: the shop shows every Cash item always in stock (no 5-min rotation,
--   no Daily Deal), no Rally Streak bonus, no Festival windows, no daily claim (the DAILY tab hides).
-- Additive: nothing is deleted; false brings every row and feature back.
MonetizationConfig.LAUNCH_HIDE = true
-- Explicit opt-in for legacy receipt/pass binding while new sales remain disabled.
MonetizationConfig.ReceiptRecoveryEnabled = false
MonetizationConfig.LAUNCH_HIDDEN_FEATURES = {
	shopRotation = true,
	rallyStreak = true,
	festival = true,
	daily = true,
} :: { [string]: boolean }

export type Rarity = "common" | "rare" | "epic" | "exclusive"
export type CosmeticKind = "livery" | "trail" | "horn" | "emote"
-- Where a cosmetic comes from. Only "shop" items carry a gearsPrice; "set" liveries listed in SHOP.rotating get one too.
-- "storm": bought ONLY with Storm Shards at the Storm vendor (shared/StormConfig.VENDOR); never sold for Cash or Robux,
-- never granted by a product or gift (EconomyRules.validate, Economy.grantCosmetic).
export type Source = "shop" | "winpass" | "pack" | "set" | "daily" | "amulet" | "product" | "storm"
export type RGB = { number } -- {r, g, b} 0-255; the builders turn it into Color3

export type LiveryStyle = {
	primary: RGB, -- wings / body panels (plane and car)
	accent: RGB, -- wingtips / wheels and trim pieces
	trim: RGB, -- stripes
	finish: "Matte" | "Gloss" | "Metal" | "Neon", -- material family for the painted parts
	glow: number?, -- 0..1 emissive glow on top of the finish (storm tints; nil = none). Drawn later: data now
}
export type TrailStyle = {
	color0: RGB,
	color1: RGB,
	texture: string, -- VfxAssets texture key
	width: number, -- multiplier on the rig's wingtip trail width
	lightEmission: number,
}
-- Procedural horn from SoundJuice's loaded sounds: one beep per pitch, gap seconds apart.
export type HornStyle = {
	cue: "pickupChime" | "lapFanfare" | "boostWhoosh" | "goldenQuack",
	pitches: { number },
	gap: number,
}
-- A named finish flourish the client plays on the player's vehicle after crossing the line.
export type EmoteStyle = {
	flourish: "barrelRoll" | "loop" | "confetti" | "lightning",
	seconds: number,
}

export type Cosmetic = {
	key: string,
	kind: CosmeticKind,
	name: string,
	rarity: Rarity,
	source: Source,
	gearsPrice: number?, -- nil: not sold for Gears
	set: string?, -- "S1": the Season 1 livery set
	livery: LiveryStyle?,
	trail: TrailStyle?,
	horn: HornStyle?,
	emote: EmoteStyle?,
}

-- What a product does. Only these fields exist; validate() rejects anything else (tokens, fragments, speed...).
export type Grants = {
	gears: number?,
	cosmetics: { string }?,
	effect: ("x2Gears" | "garagePlus")?, -- passes: read at earn/request time, re-verified with the API
	winPassPremium: number?, -- season id
	chooseFromSet: string?, -- livery set id; the buyer picks `count` liveries before the prompt
	count: number?,
}

export type Product = {
	key: string,
	kind: "Pass" | "DevProduct",
	id: number?, -- nil until bound from the owner's universe; never invented
	label: string,
	storeName: string?, -- exact Creator Hub name the binder matches; nil = label
	grants: Grants,
	defaultPriceLabel: string, -- DEFAULT Robux label (MONETIZATION_PROPOSAL 2d); not a price
	giftTwinOf: string?, -- this product gifts the named product to a racer in the server
	oncePerAccount: boolean?,
	liveAtLaunch: boolean?, -- in the v3 live set: still sold while LAUNCH_HIDE is on (nil = hidden then)
}

---------------------------------------------------------------------------------------------------- cosmetics

local function livery(key: string, name: string, rarity: Rarity, source: Source, gearsPrice: number?, style: LiveryStyle, set: string?): Cosmetic
	return { key = key, kind = "livery", name = name, rarity = rarity, source = source, gearsPrice = gearsPrice, livery = style, set = set }
end
local function trail(key: string, name: string, rarity: Rarity, source: Source, gearsPrice: number?, style: TrailStyle): Cosmetic
	return { key = key, kind = "trail", name = name, rarity = rarity, source = source, gearsPrice = gearsPrice, trail = style }
end
local function horn(key: string, name: string, rarity: Rarity, source: Source, gearsPrice: number?, style: HornStyle): Cosmetic
	return { key = key, kind = "horn", name = name, rarity = rarity, source = source, gearsPrice = gearsPrice, horn = style }
end
local function emote(key: string, name: string, rarity: Rarity, source: Source, gearsPrice: number?, style: EmoteStyle): Cosmetic
	return { key = key, kind = "emote", name = name, rarity = rarity, source = source, gearsPrice = gearsPrice, emote = style }
end

-- Prices follow the earn arithmetic under GEARS: common ~5 races (300), rare ~15 (900), epic/top ~40 (2400).
MonetizationConfig.COSMETICS = {
	-- Gears shop (17 rows incl. the two S1 set liveries that rotate in)
	livery("Livery_SunsetCoral", "Sunset Coral", "common", "shop", 300, { primary = { 236, 112, 92 }, accent = { 255, 196, 120 }, trim = { 250, 238, 214 }, finish = "Gloss" }),
	livery("Livery_MintBreeze", "Mint Breeze", "common", "shop", 300, { primary = { 120, 206, 178 }, accent = { 46, 86, 98 }, trim = { 240, 232, 210 }, finish = "Matte" }),
	livery("Livery_StormSlate", "Storm Slate", "common", "shop", 300, { primary = { 72, 82, 104 }, accent = { 255, 210, 75 }, trim = { 200, 210, 226 }, finish = "Matte" }),
	livery("Livery_CherryLacquer", "Cherry Lacquer", "rare", "shop", 900, { primary = { 176, 28, 52 }, accent = { 30, 24, 28 }, trim = { 255, 230, 200 }, finish = "Gloss" }),
	livery("Livery_ChromeComet", "Chrome Comet", "epic", "shop", 2400, { primary = { 214, 222, 232 }, accent = { 110, 245, 255 }, trim = { 60, 70, 90 }, finish = "Metal" }),
	trail("Trail_Ember", "Ember Trail", "common", "shop", 400, { color0 = { 255, 220, 140 }, color1 = { 255, 96, 40 }, texture = "trail_soft", width = 1, lightEmission = 0.6 }),
	trail("Trail_Frost", "Frost Trail", "rare", "shop", 800, { color0 = { 230, 250, 255 }, color1 = { 120, 190, 255 }, texture = "trail_soft", width = 1.1, lightEmission = 0.5 }),
	trail("Trail_Prism", "Prism Trail", "rare", "shop", 1500, { color0 = { 255, 120, 220 }, color1 = { 120, 255, 200 }, texture = "trail_soft", width = 1.2, lightEmission = 0.8 }),
	trail("Trail_Aurora", "Aurora Trail", "epic", "shop", 2400, { color0 = { 120, 255, 170 }, color1 = { 150, 90, 255 }, texture = "trail_soft", width = 1.4, lightEmission = 1 }),
	horn("Horn_Toot", "Toot Horn", "common", "shop", 250, { cue = "pickupChime", pitches = { 1.0, 1.0 }, gap = 0.14 }),
	horn("Horn_Duck", "Duck Horn", "rare", "shop", 600, { cue = "pickupChime", pitches = { 0.62, 0.7 }, gap = 0.12 }),
	horn("Horn_Fanfare", "Fanfare Horn", "rare", "shop", 900, { cue = "lapFanfare", pitches = { 1.2 }, gap = 0 }),
	emote("Emote_BarrelRoll", "Barrel Roll", "common", "shop", 350, { flourish = "barrelRoll", seconds = 1.2 }),
	emote("Emote_Loop", "Victory Loop", "rare", "shop", 900, { flourish = "loop", seconds = 2 }),
	emote("Emote_Confetti", "Confetti Burst", "epic", "shop", 1800, { flourish = "confetti", seconds = 2.5 }),

	-- Season 1 Livery Set (direct-buy, season-limited); Aurora and Lagoon also rotate into the Gears shop
	livery("Livery_S1_Aurora", "S1 Aurora", "rare", "set", 1200, { primary = { 70, 200, 170 }, accent = { 150, 90, 255 }, trim = { 230, 255, 245 }, finish = "Gloss" }, "S1"),
	livery("Livery_S1_Glacier", "S1 Glacier", "rare", "set", nil, { primary = { 200, 230, 250 }, accent = { 60, 120, 200 }, trim = { 255, 255, 255 }, finish = "Gloss" }, "S1"),
	livery("Livery_S1_Ember", "S1 Ember", "rare", "set", nil, { primary = { 200, 70, 30 }, accent = { 255, 196, 60 }, trim = { 40, 30, 30 }, finish = "Metal" }, "S1"),
	livery("Livery_S1_Lagoon", "S1 Lagoon", "rare", "set", 1200, { primary = { 40, 170, 200 }, accent = { 250, 220, 150 }, trim = { 255, 250, 240 }, finish = "Gloss" }, "S1"),
	livery("Livery_S1_Canopy", "S1 Canopy", "rare", "set", nil, { primary = { 60, 120, 60 }, accent = { 200, 160, 80 }, trim = { 240, 232, 210 }, finish = "Matte" }, "S1"),
	livery("Livery_S1_Nebula", "S1 Nebula", "rare", "set", nil, { primary = { 40, 30, 80 }, accent = { 255, 120, 220 }, trim = { 180, 220, 255 }, finish = "Neon" }, "S1"),

	-- Packs (Founder liveries rotate into the shop in a later update; MONETIZATION_PROPOSAL 2d)
	livery("Livery_FounderGold", "Founder Gold", "exclusive", "pack", nil, { primary = { 228, 172, 48 }, accent = { 60, 40, 30 }, trim = { 255, 244, 214 }, finish = "Metal" }),
	livery("Livery_FounderNavy", "Founder Navy", "exclusive", "pack", nil, { primary = { 30, 44, 90 }, accent = { 228, 172, 48 }, trim = { 240, 232, 210 }, finish = "Gloss" }),
	horn("Horn_FounderBrass", "Founder Brass", "exclusive", "pack", nil, { cue = "lapFanfare", pitches = { 0.9, 1.2 }, gap = 0.22 }),
	trail("Trail_RookieSpark", "Rookie Spark", "common", "pack", nil, { color0 = { 255, 255, 220 }, color1 = { 255, 210, 75 }, texture = "trail_soft", width = 0.9, lightEmission = 0.7 }),

	-- Daily claim day 7
	trail("Trail_DailyComet", "Comet Streak", "rare", "daily", nil, { color0 = { 255, 255, 255 }, color1 = { 110, 245, 255 }, texture = "trail_soft", width = 1.1, lightEmission = 0.9 }),

	-- Win Pass season 1, free column (retired at season end, never re-issued)
	livery("Livery_WP1_Rookie", "S1 Rookie", "exclusive", "winpass", nil, { primary = { 250, 240, 220 }, accent = { 236, 112, 92 }, trim = { 46, 86, 98 }, finish = "Matte" }),
	livery("Livery_WP1_Bronze", "S1 Bronze", "exclusive", "winpass", nil, { primary = { 176, 110, 60 }, accent = { 60, 40, 30 }, trim = { 240, 200, 150 }, finish = "Metal" }),
	livery("Livery_WP1_Silver", "S1 Silver", "exclusive", "winpass", nil, { primary = { 200, 206, 214 }, accent = { 70, 80, 100 }, trim = { 255, 255, 255 }, finish = "Metal" }),
	livery("Livery_WP1_Gold", "S1 Gold", "exclusive", "winpass", nil, { primary = { 236, 190, 60 }, accent = { 120, 70, 30 }, trim = { 255, 248, 220 }, finish = "Metal" }),
	livery("Livery_WP1_Storm", "S1 Stormbreaker", "exclusive", "winpass", nil, { primary = { 40, 50, 80 }, accent = { 110, 245, 255 }, trim = { 255, 220, 90 }, finish = "Neon" }),
	-- Win Pass season 1, premium column
	trail("Trail_WP1_Premium", "S1 Victory Trail", "exclusive", "winpass", nil, { color0 = { 255, 236, 160 }, color1 = { 255, 140, 60 }, texture = "trail_soft", width = 1.2, lightEmission = 0.9 }),
	horn("Horn_Thunder", "Thunder Horn", "exclusive", "winpass", nil, { cue = "boostWhoosh", pitches = { 0.7, 0.55 }, gap = 0.18 }),
	emote("Emote_Lightning", "Lightning Barrel", "exclusive", "winpass", nil, { flourish = "lightning", seconds = 2 }),
	livery("Livery_WP1P_Gilded", "S1 Gilded", "exclusive", "winpass", nil, { primary = { 250, 230, 160 }, accent = { 176, 28, 52 }, trim = { 255, 255, 255 }, finish = "Gloss" }),
	livery("Livery_WP1P_Tempest", "S1 Tempest", "exclusive", "winpass", nil, { primary = { 20, 24, 40 }, accent = { 150, 90, 255 }, trim = { 110, 245, 255 }, finish = "Neon" }),

	-- Progression reward (LAUNCH_PROGRESSION section 3): SaveService.derive owns it; never sold, never stocked.
	livery("Livery_BattleAmulet", "Battle Amulet", "exclusive", "amulet", nil, { primary = { 90, 40, 120 }, accent = { 255, 210, 75 }, trim = { 240, 232, 210 }, finish = "Metal" }),
	-- REMARKABLE item 22: all six Lost Squeaky Ducks. Same "amulet" source = a progression reward SaveService.derive
	-- owns: never sold, never stocked, hidden in the Garage until earned. One fat brass quack.
	horn("Horn_GoldenQuack", "Golden Quack", "exclusive", "amulet", nil, { cue = "goldenQuack", pitches = { 1.0 }, gap = 0 }),

	-- Storm vendor (economy v3 phase 5; shared/StormConfig.VENDOR): Storm Shards only, by reputation tier. No Cash price,
	-- never stocked, never in a product. The Eye of the Storm rows out-shine every other row of their kind
	-- (tools/tests/storm_spec.luau).
	livery("Livery_Storm_Squall", "Squall Grey", "rare", "storm", nil, { primary = { 96, 108, 128 }, accent = { 200, 214, 232 }, trim = { 150, 170, 200 }, finish = "Gloss" }),
	livery("Livery_Storm_Gale", "Gale Teal", "rare", "storm", nil, { primary = { 30, 120, 130 }, accent = { 110, 240, 230 }, trim = { 230, 250, 250 }, finish = "Metal", glow = 0.2 }),
	livery("Livery_Storm_Tempest", "Tempest Violet", "epic", "storm", nil, { primary = { 52, 30, 100 }, accent = { 170, 120, 255 }, trim = { 220, 200, 255 }, finish = "Neon", glow = 0.5 }),
	livery("Livery_Storm_Eye", "Eye of the Storm", "exclusive", "storm", nil, { primary = { 22, 20, 48 }, accent = { 255, 222, 110 }, trim = { 150, 230, 255 }, finish = "Neon", glow = 1 }),
	trail("Trail_Storm_Drizzle", "Drizzle Trail", "common", "storm", nil, { color0 = { 220, 230, 245 }, color1 = { 120, 140, 170 }, texture = "trail_soft", width = 0.9, lightEmission = 0.4 }),
	trail("Trail_Storm_Gale", "Gale Streak", "rare", "storm", nil, { color0 = { 200, 255, 250 }, color1 = { 60, 200, 200 }, texture = "trail_soft", width = 1.2, lightEmission = 0.7 }),
	trail("Trail_Storm_Tempest", "Tempest Arc", "epic", "storm", nil, { color0 = { 240, 220, 255 }, color1 = { 140, 80, 255 }, texture = "trail_soft", width = 1.45, lightEmission = 1 }),
	trail("Trail_Storm_Eye", "Eye of the Storm Trail", "exclusive", "storm", nil, { color0 = { 255, 248, 210 }, color1 = { 120, 90, 255 }, texture = "trail_soft", width = 1.6, lightEmission = 1 }),
	horn("Horn_Storm_Gust", "Gust Horn", "common", "storm", nil, { cue = "boostWhoosh", pitches = { 1.1 }, gap = 0 }),
	horn("Horn_Storm_Thunderclap", "Thunderclap Horn", "epic", "storm", nil, { cue = "lapFanfare", pitches = { 0.6, 0.5 }, gap = 0.2 }),
	emote("Emote_Storm_GaleRoll", "Gale Roll", "rare", "storm", nil, { flourish = "barrelRoll", seconds = 1.6 }),
	emote("Emote_Storm_EyeStrike", "Eye Strike", "exclusive", "storm", nil, { flourish = "lightning", seconds = 3 }),
} :: { Cosmetic }

-- Equip slots -> the cosmetic kind each takes. A livery fits both vehicles; each vehicle keeps its own.
MonetizationConfig.SLOTS = {
	planeLivery = "livery",
	carLivery = "livery",
	trail = "trail",
	horn = "horn",
	emote = "emote",
} :: { [string]: CosmeticKind }

-- Gears paid back when a pack or gift hands over a cosmetic already owned.
MonetizationConfig.DUPLICATE_GEARS = { common = 100, rare = 300, epic = 800, exclusive = 500 } :: { [Rarity]: number }

-- A oncePerAccount product bought again anyway (the client can call PromptProductPurchase itself) pays this many Gears
-- instead of its first-time bundle: the standard pack rate (500 Gears for 49 R$, about 10 per Robux) for the 1 R$ Rookie
-- Pack. Raise it with that product's price (L51, L57).
MonetizationConfig.ONCE_REPEAT_GEARS = 10

---------------------------------------------------------------------------------------------------- products

local function product(row: Product): Product
	return row
end

-- Launch catalog (MONETIZATION_PROPOSAL 2d): 2 passes, 14 developer products, 5 gift twins. Every id nil (StoreBinder
-- binds them at runtime; docs/STORE_PRODUCTS_TO_CREATE.md lists the names to create). liveAtLaunch marks the v3 live set
-- (6 rows) that stays on sale under LAUNCH_HIDE.
MonetizationConfig.PRODUCTS = {
	product({ key = "x2Gears", kind = "Pass", id = nil, label = "2x Cash", grants = { effect = "x2Gears" }, defaultPriceLabel = "399", liveAtLaunch = true }),
	product({ key = "garagePlus", kind = "Pass", id = nil, label = "Garage+", grants = { effect = "garagePlus" }, defaultPriceLabel = "249" }),
	product({
		key = "rookiePack",
		kind = "DevProduct",
		id = nil,
		label = "Rookie Pack",
		grants = { gears = 100, cosmetics = { "Trail_RookieSpark" } },
		defaultPriceLabel = "1",
		oncePerAccount = true,
	}),
	product({
		key = "founderPack1",
		kind = "DevProduct",
		id = nil,
		label = "Founder Pack",
		grants = { gears = 500, cosmetics = { "Livery_FounderGold", "Livery_FounderNavy", "Horn_FounderBrass" } },
		defaultPriceLabel = "199",
	}),
	product({ key = "gearsPack1", kind = "DevProduct", id = nil, label = "500 Cash", grants = { gears = 500 }, defaultPriceLabel = "49", liveAtLaunch = true }),
	product({ key = "gearsPack2", kind = "DevProduct", id = nil, label = "1,200 Cash", grants = { gears = 1200 }, defaultPriceLabel = "99", liveAtLaunch = true }),
	product({ key = "gearsPack3", kind = "DevProduct", id = nil, label = "3,500 Cash", grants = { gears = 3500 }, defaultPriceLabel = "249", liveAtLaunch = true }),
	product({ key = "gearsPack4", kind = "DevProduct", id = nil, label = "8,000 Cash", grants = { gears = 8000 }, defaultPriceLabel = "499", liveAtLaunch = true }),
	product({ key = "winPassPremiumS1", kind = "DevProduct", id = nil, label = "Win Pass Premium", grants = { winPassPremium = 1 }, defaultPriceLabel = "199", liveAtLaunch = true }),
	product({ key = "liverySetS1_1", kind = "DevProduct", id = nil, label = "Season 1 Tint", grants = { chooseFromSet = "S1", count = 1 }, defaultPriceLabel = "149" }),
	product({ key = "liverySetS1_3", kind = "DevProduct", id = nil, label = "Season 1 Tints x3", grants = { chooseFromSet = "S1", count = 3 }, defaultPriceLabel = "429" }),
	product({ key = "liverySetS1_all", kind = "DevProduct", id = nil, label = "Season 1 Set (all 6)", grants = { chooseFromSet = "S1", count = 6 }, defaultPriceLabel = "1249" }),
	-- Trails ladder: cosmetic only, no earn bonus; every rung is also sold for Gears in the shop.
	product({ key = "trailEmber", kind = "DevProduct", id = nil, label = "Ember Trail", grants = { cosmetics = { "Trail_Ember" } }, defaultPriceLabel = "19" }),
	product({ key = "trailFrost", kind = "DevProduct", id = nil, label = "Frost Trail", grants = { cosmetics = { "Trail_Frost" } }, defaultPriceLabel = "49" }),
	product({ key = "trailPrism", kind = "DevProduct", id = nil, label = "Prism Trail", grants = { cosmetics = { "Trail_Prism" } }, defaultPriceLabel = "99" }),
	product({ key = "trailAurora", kind = "DevProduct", id = nil, label = "Aurora Trail", grants = { cosmetics = { "Trail_Aurora" } }, defaultPriceLabel = "199" }),
	-- [GIFT] twins: same grants and price as the original, delivered to a racer picked from this server's list.
	product({ key = "giftFounderPack1", kind = "DevProduct", id = nil, label = "Gift: Founder Pack", grants = {}, giftTwinOf = "founderPack1", defaultPriceLabel = "199" }),
	product({ key = "giftLiverySetS1_1", kind = "DevProduct", id = nil, label = "Gift: Season 1 Tint", grants = {}, giftTwinOf = "liverySetS1_1", defaultPriceLabel = "149" }),
	product({ key = "giftLiverySetS1_3", kind = "DevProduct", id = nil, label = "Gift: Season 1 Tints x3", grants = {}, giftTwinOf = "liverySetS1_3", defaultPriceLabel = "429" }),
	product({ key = "giftLiverySetS1_all", kind = "DevProduct", id = nil, label = "Gift: Season 1 Set", grants = {}, giftTwinOf = "liverySetS1_all", defaultPriceLabel = "1249" }),
	product({ key = "giftWinPassPremiumS1", kind = "DevProduct", id = nil, label = "Gift: Win Pass Premium", grants = {}, giftTwinOf = "winPassPremiumS1", defaultPriceLabel = "199" }),
} :: { Product }

---------------------------------------------------------------------------------------------------- earning

-- Gears earn table (OURS tuning; TEST_LIST_LAUNCH L57). The arithmetic the prices rest on:
--   typical race = 4th of 8 (36) + 3 laps x 5 (15) + ~8 rings/pads (8)      = 59, call it 60 Gears
--   common livery 300 / 60 = 5 races        rare 900 / 60 = 15 races        top Gears item 2400 / 60 = 40 races
--   a winner earns 60 + 15 + 8 = 83 (~3.6 wins for a common); a last place still earns 20 + 15 = 35 for finishing.
--   Rally Streak (x1.5 on every third finish) lifts the average to ~70 and the daily claim adds 50-150 a day, so a
--   regular player gets there a little sooner; x2 Gears and Festival double the race payout (cap MAX_MULTIPLIER).
MonetizationConfig.GEARS = {
	placement = { 60, 50, 42, 36, 30, 26, 22, 20 }, -- race / quick race / coin challenge finish by rank (8+ = last)
	perLap = 5,
	perRing = 1, -- rings and boost pads touched; client-reported, so capped
	ringCap = 12,
	perCoin = 3, -- coin challenge: coins held at the finish (8 max)
	timeTrialFinish = 30, -- solo run: no placement, plus laps
	bossWin = 150,
	rematchWin = 100,
	finalBossWin = 300,
	bossFinish = 25, -- finished a boss race but the boss won
	stormCup = { 120, 100, 85, 75, 65, 58, 52, 46 }, -- every finisher is paid
	daily = { 50, 60, 70, 80, 90, 100, 150 }, -- streak day 1-7; day 7 also grants DAILY_TRAIL
	dailyTrail = "Trail_DailyComet",
	rallyStreak = { every = 3, multiplier = 1.5 }, -- the third consecutive finish in one server pays x1.5
	x2Multiplier = 2,
	maxMultiplier = 4, -- x2 pass, Festival and Rally Streak stack multiplicatively up to this
}

-- Sources whose payout the x2 pass, Festival and Rally Streak multiply. Daily claims, packs and gifts are fixed.
MonetizationConfig.MULTIPLIED_SOURCES = {
	race = true,
	quickrace = true,
	timetrial = true,
	coin = true,
	boss = true,
	rematch = true,
	finalBoss = true,
	stormcup = true,
	stormrace = true, -- storm race v2: Cash only; Storm Shards have their own path and are never multiplied
} :: { [string]: boolean }

---------------------------------------------------------------------------------------------------- shop

-- Garage shop (MONETIZATION_PROPOSAL 2b): four always-stocked items, ROTATING_SLOTS drawn from the rotating pool every
-- RESTOCK_SECONDS (seeded by floor(utc/300), so every server shows the same items and the same starting stock) and a
-- Daily Deal by UTC day. Stock counts are per server per window: buying takes one, "Sold out" at zero, the restock
-- refills. Everything is a fixed Gears price: no paid random outcome anywhere.
MonetizationConfig.SHOP = {
	restockSeconds = 300,
	always = { "Livery_SunsetCoral", "Livery_MintBreeze", "Trail_Ember", "Horn_Toot" },
	rotating = {
		"Livery_StormSlate",
		"Livery_CherryLacquer",
		"Livery_ChromeComet",
		"Livery_S1_Aurora",
		"Livery_S1_Lagoon",
		"Trail_Frost",
		"Trail_Prism",
		"Trail_Aurora",
		"Horn_Duck",
		"Horn_Fanfare",
		"Emote_BarrelRoll",
		"Emote_Loop",
		"Emote_Confetti",
	},
	rotatingSlots = 3,
	weight = { common = 6, rare = 3, epic = 1 } :: { [string]: number }, -- draw weight by rarity
	stock = { common = 5, rare = 3, epic = 1 } :: { [string]: number }, -- per server per window
	dealDiscount = 0.3, -- Daily Deal price = gearsPrice x (1 - discount), rounded to 5
	dealStock = 3,
}

---------------------------------------------------------------------------------------------------- schedules

-- Storm Cup: a server-wide race at :00 and :30 UTC (os.time() modulo 1800), identical on every server without
-- MessagingService. Map and modifier both step with the cup index; 5 maps x 2 modifiers are coprime, so all 10
-- combinations come round every 5 hours. "mirrored" (reverse direction) is DEFERRED: the track pipeline has no reverse
-- route support (checkpoint order, grid, finish arch, one-way ramps and jumps, pad facing, bot splines), so it stays
-- out of the rotation until it does (server/StormCup header). Adding it back makes 5 x 3 = 15 combinations.
MonetizationConfig.STORM_CUP = {
	periodSeconds = 1800,
	lobbySeconds = 60, -- the hub announces and gathers racers this long before the start
	tracks = { "DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1", "SPACE-4" },
	modifiers = { "night", "doubleItemBoxes" },
	mode = "stormcup", -- RaceMode the Storm Cup race runs under; Economy pays GEARS.stormCup and counts it for the Win Pass
}

-- This month's theme, shown in the login popup (economy v3 step 7; source: mon-review/THEME_CALENDAR.md, SkyRally column).
-- Keyed by UTC month (1 = January). accent is {r, g, b} 0-255 (the popup's rim, title and button); pitch is one plain line.
-- The cosmetics themselves ship separately; this table only names the month. Edit text here, nothing else reads it.
export type Theme = { name: string, pitch: string, accent: { number } }
MonetizationConfig.THEME_CALENDAR = {
	[11] = { name = "Lantern Rally", pitch = "Paper lanterns light the hub. Marigold trails.", accent = { 255, 150, 40 } },
	[12] = { name = "Snow Squadron", pitch = "Candy-stripe planes and a snowflake trail.", accent = { 150, 215, 255 } },
	[1] = { name = "Fireworks Finale", pitch = "Firework bursts and a countdown clock.", accent = { 255, 215, 90 } },
	[2] = { name = "Dragon Dance", pitch = "Red and gold dragon skins. Gold-coin trail.", accent = { 230, 60, 50 } },
	[3] = { name = "Colour Burst", pitch = "Powder trails and a paint-splat wall.", accent = { 235, 90, 190 } },
	[4] = { name = "Splash Week", pitch = "Water-balloon trail. Blue and white skins.", accent = { 70, 170, 240 } },
	[5] = { name = "Crescent Skies", pitch = "Gold crescent trail and lantern lights.", accent = { 230, 190, 80 } },
	[6] = { name = "Midsummer Cup", pitch = "Flower-crown skins and a sun trail.", accent = { 255, 195, 60 } },
	[7] = { name = "Star Festival", pitch = "Paper streamers and star props on the hub.", accent = { 120, 140, 255 } },
	[8] = { name = "Lantern Float", pitch = "A drifting-lantern trail.", accent = { 255, 170, 90 } },
	[9] = { name = "Moon Rally", pitch = "A full moon over the hub. Mooncake-gold trail.", accent = { 245, 225, 120 } },
	[10] = { name = "Haunted Skies", pitch = "Ghost-plane skins, a bat trail, pumpkins.", accent = { 255, 120, 30 } },
} :: { [number]: Theme }

-- Festival windows (UTC; weekday 0 = Sunday): double Gears and a golden coin on every track. Saturday's hour leads into
-- the weekly update slot; Wednesday is the mid-week mini window. Override: true forces on, false forces off (later
-- admin use), nil follows the table.
MonetizationConfig.FESTIVAL = {
	windows = {
		{ weekday = 6, startMinute = 15 * 60, minutes = 60, multiplier = 2, goldenCoin = true, name = "Saturday Festival" },
		{ weekday = 3, startMinute = 22 * 60, minutes = 30, multiplier = 2, goldenCoin = true, name = "Midweek Festival" },
	},
	override = nil :: boolean?,
}

---------------------------------------------------------------------------------------------------- Win Pass

-- Tiers advance on RACES FINISHED (owner ruling 2026-10-20, SKYRALLY_ECONOMY_V3 section 6): every finish in a
-- racesModes mode counts, any place, so the top tier is about 4 races a day over the 4-week season. Only a real
-- player's finish reaches Economy.raceFinished (bots have no profile; a simulated finish counts only in Studio), and a
-- battle is not a race. First places in countsModes still add to the saved winPass.wins (kept for stats and for servers
-- on an older build); the tiers read winPass.races. Claims save under "r<tier>"; a claim made under the wins-era tiers
-- (legacyTiers, saved under the bare number) marks the tier at the same position claimed, so an old profile keeps every
-- tier it took. Neither counter can be bought. Season = 4 weeks; the free column's exclusives retire at season end.
-- Season dates are DEFAULTS (Saturday 2026-11-07 00:00 UTC + 28 days) for the owner to set at the release decision;
-- before the first start, races count into season 1 so private builds show progress.
MonetizationConfig.WIN_PASS = {
	racesModes = { race = true, quickrace = true, coin = true, stormcup = true, stormrace = true, boss = true, rematch = true, timetrial = true } :: { [string]: boolean },
	countsModes = { race = true, quickrace = true, stormcup = true, stormrace = true } :: { [string]: boolean }, -- first places -> wins
	tiers = { 5, 20, 45, 80, 120 }, -- races finished
	legacyTiers = { 1, 5, 15, 25, 40 }, -- the wins-era tiers, position for position (old claims only)
	free = {
		["5"] = "Livery_WP1_Rookie",
		["20"] = "Livery_WP1_Bronze",
		["45"] = "Livery_WP1_Silver",
		["80"] = "Livery_WP1_Gold",
		["120"] = "Livery_WP1_Storm",
	} :: { [string]: string },
	premium = {
		["5"] = "Trail_WP1_Premium",
		["20"] = "Horn_Thunder",
		["45"] = "Emote_Lightning",
		["80"] = "Livery_WP1P_Gilded",
		["120"] = "Livery_WP1P_Tempest",
	} :: { [string]: string },
	premiumProduct = "winPassPremiumS1",
	seasons = {
		{ id = 1, name = "Season 1", startUtc = 1794009600, endUtc = 1794009600 + 28 * 86400 },
	},
}

---------------------------------------------------------------------------------------------------- service tuning

MonetizationConfig.SERVICE = {
	joinPromptGraceSeconds = 10, -- no purchase prompt in a player's first 10 s (L59)
	deliveredToastWindow = 8, -- grants landing this soon after the profile loads share one "Delivered" toast
	requestBurst = 8, -- remote requests: token bucket size per player
	requestRefillPerSecond = 2,
	passCheckAttempts = 3,
	receiptFlushTimeout = 20, -- seconds ProcessReceipt waits for the durable save before NotProcessedYet
	priceCacheSeconds = 600, -- a GetProductInfo price is reused this long
	priceRetrySeconds = 20, -- a failed GetProductInfo is retried after this long, not cached for the full 600 s (L50)
	receiptsKept = 64, -- PurchaseIds a profile remembers once the ledger holds them
	purchaseStoreName = "SkyRallyPurchaseHistory",
	giftStoreName = "SkyRallyPendingGifts",
}

return MonetizationConfig
