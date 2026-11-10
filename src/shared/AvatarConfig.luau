--!strict
-- Vehicle avatars as data (economy v3 phase 6; SKYRALLY_ECONOMY_V3 section 4; docs/design/AVATAR_ROSTER_V3.md; DECISIONS
-- D13 / D24 proposed; pricing O8). Pure tables, no services: the server (Economy, SaveService, the builders), the Garage
-- VEHICLES tab and the pre-race pick read the same rows; AvatarRules turns them into ownership, prices and the ladder.
-- Vocabulary (owner): an AVATAR is a whole vehicle model, a RESKIN is a texture swap on one avatar, a TINT is a colour /
-- glow finish. Players never read "livery".
-- * STAT-NEUTRAL BY CONSTRUCTION: a row has no tuning field. The builders keep the fixed invisible hull and the
--   controllers read PlaneConfig / CarConfig only, never the avatar; AvatarRules.validate fails the spec if a row ever
--   carries a speed, handling, mass or boost key (tools/tests/avatar_spec.luau).
-- * The track still picks the class (plane / car); the player picks the avatar inside that class.
-- * Meshes come after the owner picks concepts. Until a row has a MESHES entry it renders the class's hero model. The
--   two hero models (PlaneBuilder.HERO_PLANE_*, HERO_CAR_*) are the starter avatars.
-- * Additive: hide with the switches below, never delete a row (a saved profile may own it).
local AvatarConfig = {}

-- The VEHICLES Garage tab and the pre-race pick. false hides both; every racer then gets the class starter.
AvatarConfig.ENABLED = true
-- Private builds run with everything on (owner ruling 2026-10-20): avatars whose mesh has not landed yet are listed,
-- buyable and selectable, and render the class's hero model with a "MODEL SOON" note. MonetizationConfig.LAUNCH_HIDE
-- (the single launch switch) hides every unbuilt row regardless of this.
AvatarConfig.SELL_UNBUILT = true

export type Class = "plane" | "car"
export type Rarity = "common" | "rare" | "epic" | "legendary"
-- starter: owned by every profile, the default pick. free: owned by every profile. cash: bought in the Garage.
-- robux: a developer product (productKey; the id is bound by StoreBinder when the owner creates it, never invented).
-- earned: never sold; owned exactly while its source holds (SaveService.derive).
export type AcquireKind = "starter" | "free" | "cash" | "robux" | "earned"
export type EarnedSource = "campaign" | "amulet" | "storm"

export type Acquire = {
	kind: AcquireKind,
	price: number?, -- Cash, for kind = "cash"
	productKey: string?, -- kind = "robux": the MonetizationConfig-style product key
	productId: number?, -- always nil here; bound at runtime
	robux: number?, -- DEFAULT Robux label for the owner's yes/no (O8), never shown as a price
	liveAtLaunch: boolean?, -- robux rows: stays on sale under LAUNCH_HIDE once the product exists
	source: EarnedSource?, -- kind = "earned"
}

export type Need = { races: number?, wins: number?, keys: number? } -- ANY one condition unlocks the step
export type TintStyle = { finish: "Matte" | "Gloss" | "Metal" | "Neon", glow: number? } -- glow 0..1 emissive (later)
export type Step = {
	id: string,
	kind: "reskin" | "tint",
	name: string,
	need: Need,
	texture: string?, -- reskin ColorMap asset; nil until the owner's picks are meshed and painted
	tint: TintStyle?,
}

export type Row = {
	key: string,
	class: Class,
	name: string,
	rarity: Rarity,
	acquire: Acquire,
	fp: boolean?, -- first-playable set (4 per class)
	ladder: { Step }?, -- nil: LADDER below
}

-- How the builders place a mesh. hero = the class's existing hero model (the starters). Others load modelId through
-- server/kit/MeshTemplate, scale the longest side to `length` studs and weld at offset * yaw on the hull's body root.
export type Mesh = {
	hero: boolean?,
	modelId: number?,
	length: number?,
	yaw: number?, -- degrees about +Y that put the mesh's nose on -Z
	offset: { number }?, -- {x, y, z} studs, body-local
	prop: boolean?, -- plane: keep the hero's turning propeller rotor (false: the mesh has its own look)
	wheels: boolean?, -- car: the mesh is wheel-less; the turning wheel meshes show
	-- Creature avatars (a rigged, animated mount; plane_void_dragon). kind = "creature": PlaneBuilder loads the whole
	-- rigged model (server/kit/CreatureMesh), fits it with Model:ScaleTo (length, times scale, clamped by the chase
	-- camera bound in VehicleCreatureRules.fitLength), welds every part at the same invisible hull and seats the
	-- rider at `seat`; client/VehicleCreatureAnimator plays Shared.vehicleclips.<clips> on its bones.
	kind: string?, -- "creature" (nil: a static mesh)
	clips: string?, -- clip module name under ReplicatedStorage.Shared.vehicleclips (baked like the boss clips)
	scale: number?, -- extra factor on the length fit (1 = exactly `length` studs on the longest side)
	seat: { number }?, -- {x, y, z} hull-local HumanoidRootPart anchor of the seated rider (PilotSeat SeatAnchor)
	riderScale: number?, -- the seated avatar's scale (PilotSeat PilotScale)
	reach: { number }?, -- {back, up}: how far the animated model reaches behind / above its centre, as fractions of length
}

AvatarConfig.CLASSES = { "plane", "car" } :: { Class }
-- Picker slots for later classes stay hidden by config (D13: hovercraft is U2).
AvatarConfig.HIDDEN_CLASSES = { hovercraft = true } :: { [string]: boolean }
AvatarConfig.CLASS_LABEL = { plane = "PLANES", car = "CARS" } :: { [string]: string }

AvatarConfig.EARNED_SOURCES = { campaign = true, amulet = true, storm = true } :: { [string]: boolean }

AvatarConfig.STARTER = { plane = "plane_hero", car = "car_hero" } :: { [string]: string }

-- Pricing (DECISIONS_V3_PROPOSED O8): starter free; common 1,500-2,500 Cash; rare 4,000-6,500 Cash; Robux-direct mid
-- tier only at 399 / 599 / 799 R$; epic and legendary earned rows are never sold.
AvatarConfig.CASH_BANDS = {
	common = { 1500, 2500 },
	rare = { 4000, 6500 },
} :: { [string]: { number } }
AvatarConfig.ROBUX_POINTS = { 399, 599, 799 } :: { number }

-- The default reskin ladder, counted per avatar (D24): races finished, wins and hidden keys found WITH that avatar.
-- Any one condition of a step unlocks it. Tints come after every reskin. Buying an avatar starts its ladder at zero;
-- playing it fills it. Nothing on the ladder is sold.
AvatarConfig.LADDER = {
	{ id = "r1", kind = "reskin", name = "Rally", need = { races = 10 } },
	{ id = "r2", kind = "reskin", name = "Pro", need = { races = 30, wins = 3 } },
	{ id = "r3", kind = "reskin", name = "Champion", need = { races = 75, wins = 10, keys = 2 } },
	{ id = "t1", kind = "tint", name = "Gloss", need = { races = 100, wins = 15, keys = 3 }, tint = { finish = "Gloss" } },
	{ id = "t2", kind = "tint", name = "Glow", need = { races = 150, wins = 25, keys = 4 }, tint = { finish = "Neon", glow = 0.6 } },
} :: { Step }

local function starter(key: string, class: Class, name: string): Row
	return { key = key, class = class, name = name, rarity = "common", acquire = { kind = "starter" }, fp = true }
end
local function free(key: string, class: Class, name: string, fp: boolean?): Row
	return { key = key, class = class, name = name, rarity = "common", acquire = { kind = "free" }, fp = fp }
end
local function cash(key: string, class: Class, name: string, rarity: Rarity, price: number, fp: boolean?): Row
	return { key = key, class = class, name = name, rarity = rarity, acquire = { kind = "cash", price = price }, fp = fp }
end
local function robux(key: string, class: Class, name: string, rarity: Rarity, label: number, fp: boolean?): Row
	-- liveAtLaunch: a Robux-direct avatar is in the v3 live set once its product exists (MonetizationConfig header).
	return {
		key = key,
		class = class,
		name = name,
		rarity = rarity,
		acquire = { kind = "robux", productKey = "avatar_" .. key, productId = nil, robux = label, liveAtLaunch = true },
		fp = fp,
	}
end
local function earned(key: string, class: Class, name: string, rarity: Rarity, source: EarnedSource): Row
	return { key = key, class = class, name = name, rarity = rarity, acquire = { kind = "earned", source = source } }
end

-- The roster (AVATAR_ROSTER_V3; names are proposals pending the owner's concept picks). Order = picker order.
AvatarConfig.ROWS = {
	-- Planes
	starter("plane_hero", "plane", "Rally Biplane"),
	free("plane_duck_biplane", "plane", "Duck Biplane", true),
	cash("plane_candy_rocket", "plane", "Candy Rocket", "common", 2500, true),
	cash("plane_space_shark", "plane", "Space Shark", "rare", 4000, true),
	robux("plane_galaxy_cat", "plane", "Galaxy Cat", "rare", 399, true),
	cash("plane_robot_dino", "plane", "Robot Dino", "rare", 5000),
	cash("plane_pizza_saucer", "plane", "Pizza Saucer", "common", 1500),
	cash("plane_jelly_glider", "plane", "Jelly Glider", "rare", 5000),
	cash("plane_paper_crane", "plane", "Paper Crane", "common", 1500),
	cash("plane_taco_jet", "plane", "Taco Jet", "common", 2000),
	robux("plane_cloud_whale", "plane", "Cloud Whale", "rare", 599),
	cash("plane_pixel_bee", "plane", "Pixel Bee", "common", 1500),
	cash("plane_donut_ring", "plane", "Donut Ring", "common", 2000),
	cash("plane_toy_ptero", "plane", "Toy Ptero", "rare", 6500),
	cash("plane_skate_wing", "plane", "Skate Wing", "rare", 6000),
	cash("plane_cactus_prop", "plane", "Cactus Prop", "common", 2000),
	cash("plane_banana_boom", "plane", "Banana Boom", "common", 1500),
	robux("plane_arcade_claw", "plane", "Arcade Jet", "epic", 799),
	earned("plane_glow_moth", "plane", "Glow Moth", "epic", "campaign"),
	earned("plane_lantern_fly", "plane", "Lantern Fly", "epic", "amulet"),
	earned("plane_octo_flyer", "plane", "Octo Flyer", "legendary", "storm"),
	-- Owner-supplied art (2026-10-21, assets/concepts/owner/void_dragon_sheet.png): a rigged, animated dragon mount.
	-- Top tier, earned from the Storm vendor (economy v3 section 4); the owner's admin switch unlocks it for him (D22a).
	earned("plane_void_dragon", "plane", "VOID DRAGON", "legendary", "storm"),
	-- Cars
	starter("car_hero", "car", "Rally Kart"),
	free("car_ladybug_kart", "car", "Ladybug Kart", true),
	cash("car_slime_monster", "car", "Slime Monster", "rare", 4000, true),
	cash("car_neon_skater", "car", "Neon Skater", "rare", 4500, true),
	robux("car_retro_rocket", "car", "Retro Rocket", "rare", 399, true),
	cash("car_pizza_van", "car", "Pizza Van", "common", 1500),
	cash("car_gelato_truck", "car", "Gelato Truck", "common", 2000),
	cash("car_sneaker_kart", "car", "Sneaker Kart", "common", 2000),
	cash("car_bumper_cloud", "car", "Bumper Cloud", "rare", 5000),
	cash("car_cardboard_box", "car", "Cardboard Racer", "common", 1500),
	cash("car_teapot_racer", "car", "Teapot Racer", "common", 1500),
	cash("car_bathtub_buggy", "car", "Bathtub Buggy", "common", 2000),
	cash("car_pinball_pod", "car", "Pinball Pod", "rare", 5000),
	cash("car_crab_buggy", "car", "Crab Buggy", "rare", 5500),
	robux("car_boombox_cruiser", "car", "Boombox Cruiser", "rare", 599),
	cash("car_melon_wagon", "car", "Melon Wagon", "common", 2500),
	cash("car_toy_tank", "car", "Toy Tank", "rare", 6000),
	cash("car_dino_egg", "car", "Dino Egg", "rare", 6500),
	robux("car_lava_rod", "car", "Lava Rod", "epic", 799),
	earned("car_thunder_beetle", "car", "Thunder Beetle", "epic", "amulet"),
	earned("car_crown_chariot", "car", "Crown Chariot", "legendary", "storm"),
} :: { Row }

-- Registry of built meshes, keyed by avatar key. The hero rows are the two existing hero models; every other row joins
-- here when its mesh is uploaded (AvatarConfig.register or a line below). No new meshes in phase 6.
AvatarConfig.MESHES = {
	plane_hero = { hero = true, prop = true },
	car_hero = { hero = true },
} :: { [string]: Mesh }

-- Hook for future meshes (and for specs): adds or replaces one registry entry.
function AvatarConfig.register(key: string, mesh: Mesh)
	AvatarConfig.MESHES[key] = mesh
end

-- The Void Dragon's creature entry (owner's sheet). The art lane delivers the rigged model id in
-- Shared.VehicleV4Assets (key void_dragon, the upload_models.py { [name]: modelId } shape) and the baked clips in
-- Shared.vehicleclips.VoidDragon (hover, fly, glide, boost, bankL, bankR, hit). Until the id lands the row has no mesh
-- entry and renders the hero plane with the "MODEL SOON" note. Measured values replace these after the Studio check.
AvatarConfig.VOID_DRAGON = {
	kind = "creature",
	clips = "VoidDragon",
	length = 24, -- nose to tail tip, 1.5x the first cut (16; the hero plane is 16.5): wingspan about 24 vs the plane's 15
	scale = 1,
	yaw = 180, -- Roblox imports rigged GLBs yawed 180 (Studio-verified on the bosses)
	offset = { 0, 0.3, 0.9 },
	seat = { 0, 3.6, -1.8 }, -- neck base / shoulders, in front of the wing roots (the 16-stud seat times 1.5)
	riderScale = 0.75, -- proportionate to the bigger body (was 0.7 on the 16-stud dragon)
	reach = { 0.55, 0.3 }, -- tail tip about 0.55 L behind the centre, wing tips about 0.3 L above it at the top of a flap
	prop = false,
} :: Mesh

-- The dragon joins the registry when the art lane's asset module carries its id (absent module or id = no entry).
local function v4Id(name: string): number?
	local folder = (script :: any).Parent
	local ms = if folder then folder:FindFirstChild("VehicleV4Assets") else nil
	if not ms then
		return nil
	end
	local ok, assets = pcall((require :: any), ms)
	local id = if ok and type(assets) == "table" then (assets :: any)[name] else nil
	return if type(id) == "number" and id > 0 then id else nil
end
local dragonId = v4Id("void_dragon")
if dragonId then
	local entry = table.clone(AvatarConfig.VOID_DRAGON)
	entry.modelId = dragonId
	AvatarConfig.register("plane_void_dragon", entry)
end

-- Fields a row may carry. AvatarRules.validate rejects anything else, so no tuning key can ever ride on an avatar.
AvatarConfig.ROW_FIELDS = { key = true, class = true, name = true, rarity = true, acquire = true, fp = true, ladder = true } :: { [string]: boolean }

return AvatarConfig
