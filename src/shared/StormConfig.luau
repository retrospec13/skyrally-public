--!strict
-- Storm Shards, Storm reputation tiers and the Storm vendor as data (economy v3 phase 5; SKYRALLY_ECONOMY_V3 section 3,
-- docs/proposals/DECISIONS_V3_PROPOSED.md D23 / O6 / O7, docs/design/STORM_SHARDS.md). Pure tables, no services: the
-- server (server/StormShards), the vendor panel (client/StormVendor), the hub storm (client/HubStorm) and BadgeRules read
-- the same rows; shared/StormRules turns them into payouts, tiers and purchase answers.
-- * Storm Shards are an event reputation counter, not a wallet currency: earned ONLY by finishing storm races, spent
--   ONLY at the Storm vendor, NEVER sold for Robux and NEVER multiplied by 2x Cash, Festival or Rally Streak (they have
--   their own payout path; nothing in MonetizationConfig.MULTIPLIED_SOURCES or PRODUCTS touches them).
-- * Two saved numbers: `shards` (what the vendor spends) and `lifetime` (every Shard ever earned; spending never lowers
--   it). The tier comes from lifetime, so buying never drops a player's rank.
-- * Vendor rows of the four kinds the Garage already draws (tint, trail, horn, finish emote) point at a
--   MonetizationConfig.COSMETICS row with source "storm" (`cosmetic`), so an owned one is equipped in the Garage and
--   drawn by the existing code today. The other kinds are new: owned and equipped in the profile's `storm` slot,
--   replicated as the StormLoadout attribute; their looks are DATA NOW, art later (`needsArt = true` marks every row whose
--   look is a placeholder until the owner's art lands; docs/design/STORM_SHARDS.md lists the briefs).
-- * Additive: Enabled = false hides the vendor and stops new Shards; nothing saved is ever removed.
local StormConfig = {}

-- Owner ruling 2026-10-20: private builds run with everything on. The public release reads MonetizationConfig.LAUNCH_HIDE
-- like every other feature; Shards are not on the hide list.
StormConfig.Enabled = true

-- RaceModes that are storm races. "stormcup" is today's whole-server Storm Cup (its launch path is unchanged); "stormrace"
-- is the per-group storm race of the flow phase (RaceFlowRules.PER_GROUP). Both pay Shards on a finish.
StormConfig.MODES = { stormcup = true, stormrace = true } :: { [string]: boolean }

-- Storm race v2 (economy v3 phase 5 flow; docs/design/STORM_RACE_V2.md). true: the whole-server Storm Cup launch is OFF and the
-- storm race runs per group: ~60 s before :00 / :30 UTC every hub player gets a popup with JOIN (nobody is pulled; closing it
-- changes nothing), joiners are slotted into fields of 8 in join order, each field races in its own RaceInstance with the storm
-- dragon and bots filling the rest, and only the hub turns stormy. Needs RaceFlowRules.PER_GROUP: with PER_GROUP false the
-- server logs a warning and keeps the old Storm Cup. false (default): the Storm Cup behaves exactly as before.
StormConfig.RACE_V2 = false

-- The v2 flow's numbers (server/StormRace, shared/StormFlowRules). OURS, unverified on device.
StormConfig.FLOW = {
	mode = "stormrace", -- the RaceMode a storm field races under (StormConfig.MODES)
	announceSeconds = 60, -- the popup and the JOIN window open this long before :00 / :30 UTC
	lateJoinSeconds = 20, -- after the start a JOIN still gets a seat (the last field while its grid forms, else a new field)
	fieldSize = 8, -- racers per field: humans + the storm dragon + bots
	qaWindowMin = 10, -- Studio StormQAWindow is clamped to this range (seconds)
	qaWindowMax = 300,
}

-- Rows whose look is not drawn yet (every kind outside the Garage four: titles, borders, flags, effects, sounds, outfits,
-- hub emotes) are sold with a "LOOK COMING SOON" line while this is true (private builds: everything on). false lists them
-- but refuses the buy ("comingSoon") until their renderer lands. Owned rows are never taken away either way.
StormConfig.SELL_PENDING_LOOKS = true

-- Earn table (O6). A finish pays `finish`, plus `place[rank]` (8th and below = the last entry), plus `dragon` when this
-- racer crossed the line ahead of the storm dragon, plus `firstOfDay` on the first storm finish of the UTC day.
--   1st 40, 2nd 36, 3rd 32, 4th 28, 5th 24, 6th 20, 7th 16, 8th 12 (before the dragon and daily bonuses).
-- Pace to the top tier (spec'd in tools/tests/storm_spec.luau): a mid-field racer (4th/5th, no dragon) on 4 storm races
-- a day earns (26 x 4 + 10) / 4 = 28.5 a race, so Eye of the Storm (4,200) takes ~147 races, ~37 days, ~5.3 weeks.
StormConfig.EARN = {
	finish = 12,
	place = { 28, 24, 20, 16, 12, 8, 4, 0 },
	dragon = 30,
	firstOfDay = 10,
}

-- Reputation tiers by LIFETIME Shards (O6; names are the agent's proposal, owner may rename). Each unlocks a vendor page.
export type Tier = { id: string, name: string, at: number, color: { number } }
StormConfig.TIERS = {
	{ id = "squall", name = "Squall", at = 0, color = { 150, 170, 200 } },
	{ id = "gale", name = "Gale", at = 250, color = { 90, 220, 210 } },
	{ id = "tempest", name = "Tempest", at = 1200, color = { 170, 120, 255 } },
	{ id = "eye", name = "Eye of the Storm", at = 4200, color = { 255, 222, 110 } },
} :: { Tier }

-- Storm badges (O7): the dragon-win counts behind the three ladder badges. BadgeRules reads these.
StormConfig.BADGE_DRAGON_WINS = { dragon_hunter = 5, dragon_bane = 25, stormbreaker = 100 } :: { [string]: number }

-- Vendor kinds (12 types). `slot` = where an owned item is equipped: "garage" = an existing Garage slot (the
-- MonetizationConfig cosmetic is equipped there), anything else = a profile.storm.loadout slot of that name.
export type KindDef = { id: string, label: string, slot: string, garageKind: string? }
StormConfig.KINDS = {
	{ id = "tint", label = "Tint + glow", slot = "garage", garageKind = "livery" },
	{ id = "trail", label = "Trail", slot = "garage", garageKind = "trail" },
	{ id = "horn", label = "Horn", slot = "garage", garageKind = "horn" },
	{ id = "emote", label = "Finish emote", slot = "garage", garageKind = "emote" },
	{ id = "outfit", label = "Pilot outfit", slot = "outfit" },
	{ id = "title", label = "Hub title", slot = "title" },
	{ id = "border", label = "Nameplate border", slot = "border" },
	{ id = "flag", label = "Vehicle flag", slot = "flag" },
	{ id = "boost", label = "Boost effect", slot = "boost" },
	{ id = "landing", label = "Landing effect", slot = "landing" },
	{ id = "engine", label = "Engine sound", slot = "engine" },
	{ id = "hubEmote", label = "Hub emote", slot = "hubEmote" },
	{ id = "avatar", label = "Avatar", slot = "avatar" },
} :: { KindDef }

-- A vendor row. look: the placeholder look data the renderer will read (colours {r,g,b}, a VfxAssets texture key for
-- particles, a sound cue, title text); every effect look is PARTICLES (ParticleEmitter), never a mesh over the camera.
-- comingSoon: listed but not buyable yet (the top-tier avatars wait for the phase 6 vehicle picker and the owner's picks).
export type Item = {
	key: string,
	kind: string,
	name: string,
	tier: string,
	price: number,
	cosmetic: string?, -- MonetizationConfig.COSMETICS key (source "storm") for the Garage kinds
	look: { [string]: any }?,
	needsArt: boolean?,
	comingSoon: boolean?,
	note: string?, -- what the art is waiting on
}

local function item(row: Item): Item
	return row
end

-- Prices: Squall 60-120 (2-4 races), Gale 180-280, Tempest 500-800, Eye of the Storm 1,000-2,000. Buying everything
-- costs well over 4,200, so the top page is a goal even after the rank is reached.
StormConfig.VENDOR = {
	-- Squall (0)
	item({ key = "Storm_Tint_Squall", kind = "tint", name = "Squall Grey", tier = "squall", price = 80, cosmetic = "Livery_Storm_Squall" }),
	item({ key = "Storm_Trail_Drizzle", kind = "trail", name = "Drizzle Trail", tier = "squall", price = 100, cosmetic = "Trail_Storm_Drizzle" }),
	item({ key = "Storm_Horn_Gust", kind = "horn", name = "Gust Horn", tier = "squall", price = 90, cosmetic = "Horn_Storm_Gust" }),
	item({ key = "Storm_Title_Squall", kind = "title", name = "Squall Rider", tier = "squall", price = 60, look = { text = "Squall Rider", color = { 190, 205, 225 } } }),
	item({ key = "Storm_Flag_Squall", kind = "flag", name = "Squall Pennant", tier = "squall", price = 80, needsArt = true,
		look = { color = { 120, 140, 170 }, accent = { 230, 236, 245 } }, note = "pennant decal on a short mast, hub only" }),
	item({ key = "Storm_HubEmote_Wave", kind = "hubEmote", name = "Storm Wave", tier = "squall", price = 70, needsArt = true,
		look = { pose = "wave", seconds = 2 }, note = "seated pilot wave animation" }),

	-- Gale (250)
	item({ key = "Storm_Tint_Gale", kind = "tint", name = "Gale Teal", tier = "gale", price = 220, cosmetic = "Livery_Storm_Gale" }),
	item({ key = "Storm_Trail_Gale", kind = "trail", name = "Gale Streak", tier = "gale", price = 260, cosmetic = "Trail_Storm_Gale" }),
	item({ key = "Storm_Emote_GaleRoll", kind = "emote", name = "Gale Roll", tier = "gale", price = 240, cosmetic = "Emote_Storm_GaleRoll" }),
	item({ key = "Storm_Title_Gale", kind = "title", name = "Gale Chaser", tier = "gale", price = 180, look = { text = "Gale Chaser", color = { 120, 230, 220 } } }),
	item({ key = "Storm_Border_Gale", kind = "border", name = "Gale Border", tier = "gale", price = 200, needsArt = true,
		look = { color = { 90, 220, 210 }, thickness = 2 }, note = "9-slice nameplate frame, wind-swirl corners" }),
	item({ key = "Storm_Landing_Gust", kind = "landing", name = "Gust Landing", tier = "gale", price = 240,
		look = { texture = "smoke_puff_4x4", color = { 200, 240, 240 }, count = 14, speed = 18 } }),
	item({ key = "Storm_Engine_Whistle", kind = "engine", name = "Gale Whistle", tier = "gale", price = 280, needsArt = true,
		look = { cue = "wind_rush", pitch = 1.2 }, note = "engine loop: airy whistle over the base engine" }),

	-- Tempest (1,200)
	item({ key = "Storm_Tint_Tempest", kind = "tint", name = "Tempest Violet", tier = "tempest", price = 600, cosmetic = "Livery_Storm_Tempest" }),
	item({ key = "Storm_Trail_Tempest", kind = "trail", name = "Tempest Arc", tier = "tempest", price = 700, cosmetic = "Trail_Storm_Tempest" }),
	item({ key = "Storm_Horn_Thunderclap", kind = "horn", name = "Thunderclap Horn", tier = "tempest", price = 650, cosmetic = "Horn_Storm_Thunderclap" }),
	item({ key = "Storm_Title_Tempest", kind = "title", name = "Tempest Ace", tier = "tempest", price = 500, look = { text = "Tempest Ace", color = { 190, 150, 255 } } }),
	item({ key = "Storm_Boost_Static", kind = "boost", name = "Static Boost", tier = "tempest", price = 750,
		look = { texture = "spark_streak", color0 = { 220, 200, 255 }, color1 = { 140, 90, 255 }, rate = 40, lightEmission = 0.8 } }),
	item({ key = "Storm_Flag_Tempest", kind = "flag", name = "Tempest Banner", tier = "tempest", price = 600, needsArt = true,
		look = { color = { 60, 40, 110 }, accent = { 200, 170, 255 } }, note = "banner decal with a lightning fork" }),
	item({ key = "Storm_Outfit_Tempest", kind = "outfit", name = "Tempest Flight Suit", tier = "tempest", price = 800, needsArt = true,
		look = { color = { 70, 50, 130 }, accent = { 180, 150, 255 } }, note = "pilot jacket, goggles and scarf (pilot outfits ship month 2)" }),

	-- Eye of the Storm (4,200): the best-looking things in the game (storm_spec checks they out-shine every other row).
	item({ key = "Storm_Tint_Eye", kind = "tint", name = "Eye of the Storm", tier = "eye", price = 1500, cosmetic = "Livery_Storm_Eye" }),
	item({ key = "Storm_Trail_Eye", kind = "trail", name = "Eye of the Storm Trail", tier = "eye", price = 1600, cosmetic = "Trail_Storm_Eye" }),
	item({ key = "Storm_Emote_EyeStrike", kind = "emote", name = "Eye Strike", tier = "eye", price = 1400, cosmetic = "Emote_Storm_EyeStrike" }),
	item({ key = "Storm_Title_Eye", kind = "title", name = "Eye of the Storm", tier = "eye", price = 1000, look = { text = "Eye of the Storm", color = { 255, 222, 110 }, glow = true } }),
	item({ key = "Storm_Border_Eye", kind = "border", name = "Eye of the Storm Border", tier = "eye", price = 1200, needsArt = true,
		look = { color = { 255, 222, 110 }, thickness = 3, animated = true }, note = "animated gold-and-violet frame with crackling corners" }),
	item({ key = "Storm_Boost_Eye", kind = "boost", name = "Eye Lightning Boost", tier = "eye", price = 1800,
		look = { texture = "lightning_beam", color0 = { 255, 245, 200 }, color1 = { 150, 110, 255 }, rate = 60, lightEmission = 1 } }),
	item({ key = "Storm_Landing_Eye", kind = "landing", name = "Thunder Landing", tier = "eye", price = 1500,
		look = { texture = "shockwave_ring", color = { 255, 230, 140 }, count = 1, speed = 0, ring = true, sparks = "spark_streak" } }),
	item({ key = "Storm_Engine_Eye", kind = "engine", name = "Storm Engine", tier = "eye", price = 1600, needsArt = true,
		look = { cue = "amb_storm", pitch = 0.9 }, note = "engine loop with a low thunder rumble" }),
	item({ key = "Storm_Outfit_Eye", kind = "outfit", name = "Eye of the Storm Suit", tier = "eye", price = 2000, needsArt = true,
		look = { color = { 30, 26, 60 }, accent = { 255, 222, 110 } }, note = "storm-cloak flight suit with gold trim (month 2)" }),
	item({ key = "Storm_HubEmote_Eye", kind = "hubEmote", name = "Call the Lightning", tier = "eye", price = 1400, needsArt = true,
		look = { pose = "raise", seconds = 2.5, particles = "lightning_beam" }, note = "pilot raises a fist, a particle bolt answers (never over the camera)" }),
	item({ key = "Storm_Avatar_OctoFlyer", kind = "avatar", name = "Octopus Flyer", tier = "eye", price = 3000, needsArt = true, comingSoon = true,
		note = "plane_octo_flyer (docs/design/AVATAR_ROSTER_V3.md #20): owner pick, then mesh; needs the phase 6 picker" }),
	item({ key = "Storm_Avatar_CrownChariot", kind = "avatar", name = "Crown Chariot", tier = "eye", price = 3000, needsArt = true, comingSoon = true,
		note = "car_crown_chariot (docs/design/AVATAR_ROSTER_V3.md #20): owner pick, then mesh; needs the phase 6 picker" }),
} :: { Item }

-- Where the Storm vendor stands in the hub (HUB-0 plaza terrace, beside the leaderboard sign). OURS, unverified in Studio:
-- one constant so a Studio pass can move it. Every part of the stall is CanCollide = false (it can never become a wall
-- or a traversal trap), the prompt sits on the counter.
StormConfig.STAND = {
	-- Counter front centre at the paving (ground found by a ray, like the board). South-east of the spawn, off every sight line from
	-- the spawn / fountain to the portal arches in the north (it stood at z 8024 and hid the NEON MOON label); 18+ studs clear of the
	-- plaza dressing, 45+ from the leaderboard board, nowhere near the hub boss loop road or the cliffs.
	pos = Vector3.new(-8122, 26, 8102),
	faceToward = Vector3.new(-8180, 26, 8066), -- the spawn
	groundTolerance = 6,
	promptDistance = 14,
	markerHeight = 17, -- studs above the paving for the hub storm marker (v29 B8: was 26; from the spawn it projected onto the HUD STORM CUP line under ADVENTURE)
}

-- Hub storm (client/HubStorm): while a storm race runs the hub sky turns to storm (HUB-0-STORM lighting), lightning
-- flashes (a short Lighting flash and a particle bolt far out over the sea, never between the camera and the vehicle),
-- a thunder stand-in plays (SoundscapeAudio amb_storm; a real thunder clap needs the owner's OK before any spend), and
-- the marker over the vendor stand reads STORM RACE IN PROGRESS, otherwise the countdown to the next one.
StormConfig.HUB = {
	lightningMin = 6, -- seconds between flashes
	lightningMax = 14,
	flashSeconds = 0.18,
	flashBrightness = 1.6, -- added to Lighting.Brightness for the flash
	boltDistance = 900, -- studs from the hub centre, out over the sea
	boltHeight = 260,
	thunderVolume = 0.35,
	periodFallback = 1800, -- next storm at :00/:30 UTC when StormCupAt is not published
}

return StormConfig
