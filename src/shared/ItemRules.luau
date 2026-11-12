--!strict
-- Race item rules (LAUNCH_PROGRESSION section 4). Pure data and state transitions: ItemService applies them
-- authoritatively, a client HUD may read them for display. No Roblox API is touched, so the rules run under Lune.
--
-- N64 FACT S5 (CONTENT "Racers and items"): five colours with fixed roles; picking up the colour already held
-- upgrades it up to level three; a different colour replaces the held item. The per-level FORMS below that cite S5
-- (single/homing/ten-shot missile, slick/mine/third-form trap) come from that row. Every other NUMBER is OURS: N64 durations,
-- speeds and damage are unmeasured (CONTENT), so these are launch defaults tuned in play under TEST_LIST_LAUNCH L07.
--
-- PodType mapping (attribute written by builder_dino4.luau and kit/Gameplay.buildItemPodSpawn):
--   "Red"  -> red item (missile)
--   "Blue" -> blue item (boost)
--   "Yellow", "Green", "Rainbow" -> yellow/green/rainbow items. Map plans place them like Red/Blue
--     (`skyrally.gameplay.pods[].type`); kit/Gameplay paints any unlisted PodType red, so ItemEffects.paintPods
--     repaints every item pod from POD_RGB below once the track is built (one colour table for server and HUD).
--   "Speed" -> "speed": NOT an item. FlightController stacks SpeedPickups (up to PlaneConfig.MAX_SPEED_PICKUPS).
--   "Air"   -> "air":   NOT an item. FlightController fires an instant boost on contact.
--   anything else -> "unknown", grants nothing.
-- Held items are race-session state and are never saved (LAUNCH_PROGRESSION section 5).
--
-- MYSTERY CUBES (owner, 2026-10-19: "each one should be in a 3D cube that rotates ... you dont know what you're going to
-- get until you hit it just like in mario kart/diddy kong racing"). Every RACE item pod is built as a mystery cube
-- (kit/Gameplay sets the MysteryCube attribute; its PodType colour stays only as plan data). Taking one with empty hands
-- rolls the item on the server from MYSTERY_WEIGHTS by race position (leaders get defensive items, trailers the
-- catch-up ones); taking one while holding an item upgrades that item one level up to three (the S5 level-up kept,
-- without the colour match). Battle pods (server/battle) keep their colours and the colour rules above.

local ItemRules = {}

-- Items v4 (docs/design/ITEMS_V4.md): an item id is either a classic colour or one of the nine SPECIALS below. The field
-- is still called `color` everywhere (ItemState, the ItemColor attribute, the remotes) so every reader keeps working;
-- for a special the id doubles as its kind.
export type Special = "rocket_rush" | "golden_wings" | "orbit_missiles" | "storm_bolt" | "boom_bomb" | "gift_box" | "frost_shot" | "coin_burst" | "bubble_guard" | "ink_splat" | "item_steal" | "coin_pouch"
export type Color = "red" | "blue" | "yellow" | "green" | "rainbow" | Special
export type Kind = "missile" | "boost" | "shield" | "horn" | "trap" | "magnet" | Special
export type PodClass = "item" | "speed" | "air" | "unknown"
export type PickupOutcome = "new" | "upgrade" | "capped" | "replace"
export type RollBand = "lead" | "front" | "middle" | "back" | "far"
export type TrapForm = "slick" | "mine" | "crate"

-- level is 0 exactly when color is nil. lastHitBy (REMARKABLE item 18, "getting even"): the racer id whose item last hit
-- this racer while that grudge is still open (ItemService fills it from its grudge book; pickup/use never set it).
export type ItemState = {
	color: Color?,
	level: number,
	lastHitBy: string?,
	-- Items v4: shots or gifts still in a charged item (orbit_missiles, gift_box: CHARGES); nil for every other item.
	charges: number?,
	-- Set only on the publish of a fresh mystery roll: seconds the HUD roulette spins before it shows the item (the
	-- server refuses a use for that long). Never stored in the held state.
	roulette: number?,
}

export type MissileParams = {
	count: number,
	homing: boolean, -- race shots: locks the racer ahead (missile v3: every level)
	freeHoming: boolean, -- battle arenas and free-flying shots: steers at turnRateDeg (else the gentle arena seek); v2 rule
	speed: number, -- studs/s
	turnRateDeg: number, -- deg/s steering while homing; 0 when unguided
	lifetime: number, -- s before an unhit missile expires
	burstInterval: number, -- s between shots when count > 1
	stunSeconds: number, -- spin-out on an unshielded hit
}

export type BoostParams = {
	seconds: number,
	speed: number, -- studs/s target speed while the boost lasts
	charges: number?, -- v38: presses one held boost gives at this level
}

export type ShieldParams = {
	seconds: number,
}

export type TrapParams = {
	count: number,
	form: TrapForm,
	lifetime: number, -- s a dropped trap stays armed
	stunSeconds: number,
}

export type MagnetParams = {
	seconds: number, -- longest pull; it ends sooner on contact (TUNING.magnetArrive)
	pull: number, -- studs/s toward the target: added to a plane's velocity, added to a car's top speed (capped)
	range: number, -- studs at the moment of use; nobody nearer means no lock (the HUD greys the marker)
}

-- Exactly one of the parameter tables is set, the one named by kind.
export type Effect = {
	color: Color,
	kind: Kind,
	level: number,
	missile: MissileParams?,
	boost: BoostParams?,
	shield: ShieldParams?,
	trap: TrapParams?,
	magnet: MagnetParams?,
	-- Items v4: a special's per-level table (SPECIAL below); kind is then the special's id.
	special: { [string]: any }?,
	-- Items v4: this effect is one gift out of a gift_box (a lesser classic item, GIFT_MINI).
	gift: boolean?,
}

ItemRules.MAX_LEVEL = 3 -- N64 FACT S5
-- LAUNCH DEFAULT (sections 2b and 4): battle overlays use the level-one set, so the same colour never upgrades there.
ItemRules.BATTLE_MAX_LEVEL = 1

local COLORS: { Color } = { "red", "blue", "yellow", "green", "rainbow" }
local KIND_OF: { [Color]: Kind } = {
	red = "missile",
	blue = "boost",
	-- v38 (owner 2026-11-10: "I don't like the shields and bubbles those are not fun interactions"): yellow is the HORN, a
	-- timed shockwave that destroys the shots and traps about to reach you and spins racers in its ring. The ShieldParams
	-- table stays for the code paths that read it; no item grants a shield any more.
	yellow = "horn",
	green = "trap",
	rainbow = "magnet",
}
-- Items v4: the nine specials the owner picked (pick board 2026-10-20) from docs/design/ITEM_OPTIONS_V2.md.
local SPECIALS: { Color } = {
	"rocket_rush",
	"golden_wings",
	"orbit_missiles",
	"storm_bolt",
	"boom_bomb",
	"gift_box",
	"frost_shot",
	"coin_burst",
	"bubble_guard",
	-- v38 (owner: "not every item needs to be some missile thing"): three new verbs.
	"ink_splat", -- everyone ahead gets ink on the screen; a boost clears it
	"item_steal", -- take the held item of a racer ahead
	"coin_pouch", -- a handful of coins at once (top speed) plus a little kick
}
for _, id in SPECIALS do
	(KIND_OF :: any)[id] = id
end
local POD_COLOR: { [string]: Color } = {
	Red = "red",
	Blue = "blue",
	Yellow = "yellow",
	Green = "green",
	Rainbow = "rainbow",
}
table.freeze(COLORS)
table.freeze(KIND_OF)
table.freeze(POD_COLOR)
table.freeze(SPECIALS)
-- The five classic colours (pods, battles and the colour rules keep exactly these).
ItemRules.COLORS = COLORS
ItemRules.SPECIALS = SPECIALS
local ALL_ITEMS: { Color } = {}
for _, c in COLORS do
	table.insert(ALL_ITEMS, c)
end
for _, c in SPECIALS do
	table.insert(ALL_ITEMS, c)
end
table.freeze(ALL_ITEMS)
-- Every item id, classic first (the roll and ghost tables walk this order).
ItemRules.ALL_ITEMS = ALL_ITEMS

function ItemRules.isSpecial(id: any): boolean
	return type(id) == "string" and table.find(SPECIALS, id :: any) ~= nil
end

-- v38: items out of play (owner 2026-11-10: passive shields/bubbles are not fun; two straight status shots made the
-- roster "all missiles"). Kept in the tables like the magnet (nothing deleted): no roll, rotation, gift or bot hands them
-- out. Their effect code still runs if a stale state ever fires one.
ItemRules.RETIRED = table.freeze({ frost_shot = true, coin_burst = true, bubble_guard = true }) :: { [string]: boolean }
local LIVE_SPECIALS: { Color } = {}
for _, id in SPECIALS do
	if not ItemRules.RETIRED[id] then
		table.insert(LIVE_SPECIALS, id)
	end
end
table.freeze(LIVE_SPECIALS)
-- The specials play can hand out (the per-race rotation draws from these).
ItemRules.LIVE_SPECIALS = LIVE_SPECIALS

-- Magnet retired from play (owner 2026-10-20: "And I thought we were getting rid of the magnet??"). Hidden by config,
-- never deleted: no roll table hands it out (MYSTERY_WEIGHTS rainbow = 0), the HUD roulette and the cube ghosts never
-- show it (LIVE_COLORS), battle arenas place no Rainbow pod (BattleRules.LEVEL_ONE_SET) and a Rainbow pod a map still
-- carries grants MAGNET_STANDIN instead (classifyPod). Set MAGNET_ENABLED = true (and give rainbow weights back) to
-- bring it back; the magnet code paths (ItemEffects.magnetPull, MagnetAim, the bots' magnet AI) are untouched.
ItemRules.MAGNET_ENABLED = false
local MAGNET_STANDIN: Color = "blue" -- the catch-up item that covers the magnet's share
ItemRules.MAGNET_STANDIN = MAGNET_STANDIN
local LIVE_COLORS: { Color } = {}
for _, c in COLORS do
	if c ~= "rainbow" or ItemRules.MAGNET_ENABLED then
		table.insert(LIVE_COLORS, c)
	end
end
table.freeze(LIVE_COLORS)
-- The colours play can hand out (the roulette and the cube ghosts walk these).
ItemRules.LIVE_COLORS = LIVE_COLORS

-- A colour as play grants it: a retired item maps to its stand-in.
function ItemRules.liveColor(color: Color): Color
	if color == "rainbow" and not ItemRules.MAGNET_ENABLED then
		return MAGNET_STANDIN
	end
	return color
end
ItemRules.KIND_OF = KIND_OF
ItemRules.POD_COLOR = POD_COLOR

-- Plane speeds these are set against: BASE 110, ring boost 165 for 1.8 s, overcharge 210 for 2.6 s (PlaneConfig).
-- Missile v3 (owner 2026-10-20: "too many times I feel like the missles dont ever reach an enemy"; shared/MissileRules):
-- every level now locks the nearest racer ahead at fire time, Mario Kart red-shell style. This departs from S5's
-- unguided level-one and ten-shot forms on purpose; the counts, the volley and the level ladder are kept. homing = false
-- (the v2 unguided course shot) stays supported by kit/ItemEffects and is what a shot with nobody ahead flies anyway.
-- lifetime: an unlocked shot's life; a locked one may live MissileRules.TUNING.lockedLifetime.
local MISSILE: { MissileParams } = table.freeze({
	-- S5 "single": one missile. OURS numbers; speed outruns an overcharged plane.
	table.freeze({ count = 1, homing = true, freeHoming = false, speed = 320, turnRateDeg = 90, lifetime = 3.0, burstInterval = 0, stunSeconds = 1.5 }),
	-- S5 "homing": one guided missile, faster across lanes. OURS numbers.
	table.freeze({ count = 1, homing = true, freeHoming = true, speed = 320, turnRateDeg = 120, lifetime = 4.0, burstInterval = 0, stunSeconds = 1.5 }),
	-- S5 "ten-shot": ten missiles as a burst (N64 firing cadence is unmeasured); each locks at its own launch, going on
	-- to the next racer ahead once its first target is spinning (MissileRules.pickTarget).
	table.freeze({ count = 10, homing = true, freeHoming = false, speed = 320, turnRateDeg = 90, lifetime = 3.0, burstInterval = 0.15, stunSeconds = 1.5 }),
})

-- S5 "progressively stronger". OURS: level one equals a ring boost, level three equals an overcharge, so an item never
-- out-boosts the skill route.
-- v38 (Mario Kart triple boost): the boost is charged, one boost per press, `charges` of them by level (a cube raises
-- the level and adds a charge, DKR style). Each charge is a ring boost; a little hotter at higher levels.
local BOOST: { BoostParams } = table.freeze({
	table.freeze({ seconds = 1.8, speed = 165, charges = 1 }),
	table.freeze({ seconds = 1.8, speed = 175, charges = 2 }),
	table.freeze({ seconds = 1.8, speed = 185, charges = 3 }),
})

-- S5 "progressively longer". OURS seconds.
local SHIELD: { ShieldParams } = table.freeze({
	table.freeze({ seconds = 3.0 }),
	table.freeze({ seconds = 5.0 }),
	table.freeze({ seconds = 8.0 }),
})

-- S5 forms slick, mine and a third form by level. OURS counts, lifetimes and stun. v39 (owner 2026-11-10: "I don't like
-- the shields and bubbles"): the level-three form is a spiked TNT crate (block-built, ItemEffects makeTrap), not a
-- bubble; its hit also pops the victim's car into a short hop (TRAP_KNOCK_VY) on top of the spin-out.
local TRAP: { TrapParams } = table.freeze({
	table.freeze({ count = 1, form = "slick" :: TrapForm, lifetime = 15, stunSeconds = 1.0 }),
	table.freeze({ count = 1, form = "mine" :: TrapForm, lifetime = 20, stunSeconds = 1.5 }),
	table.freeze({ count = 1, form = "crate" :: TrapForm, lifetime = 20, stunSeconds = 2.0 }),
})

-- v39: the upward kick (studs/s, the car's own gravity is CarConfig.GRAVITY 140) a trap form adds to its victim's car on
-- a hit: 40 is a ~5.7 stud pop and ~0.57 s of air on flat road. Only the crate kicks; the client applies it (visual
-- feel, its own physics), the server already decided the hit and the stun.
ItemRules.TRAP_KNOCK_VY = table.freeze({ crate = 40 }) :: { [string]: number }
function ItemRules.trapKnockVy(form: any): number
	return if type(form) == "string" then ItemRules.TRAP_KNOCK_VY[form] or 0 else 0
end

-- S5 "stronger levels". OURS (magnet v2, owner 2026-10-20: "it should just take the player to the closest person"):
-- longer, harder pull with a longer reach per level. Each range is about pull x seconds, so a target holding the same
-- speed is still reached before the pull runs out (a plane closes at `pull` plus its own steering toward the target).
local MAGNET: { MagnetParams } = table.freeze({
	table.freeze({ seconds = 2.5, pull = 55, range = 140 }),
	table.freeze({ seconds = 3.0, pull = 70, range = 210 }),
	table.freeze({ seconds = 3.5, pull = 85, range = 300 }),
})

-- v38 HORN (yellow): radius: racers inside spin `spin` s; clear: shots, traps, bombs inside are destroyed, and a Storm
-- Bolt over the holder is broken when the horn sounds inside its warning (the timed answer to the first-place threat).
local HORN: { { [string]: number } } = table.freeze({
	table.freeze({ radius = 18, spin = 1.0, clear = 30 }),
	table.freeze({ radius = 24, spin = 1.2, clear = 38 }),
	table.freeze({ radius = 30, spin = 1.4, clear = 46 }),
}) :: any

ItemRules.PARAMS = table.freeze({
	missile = MISSILE,
	boost = BOOST,
	horn = HORN,
	shield = SHIELD,
	trap = TRAP,
	magnet = MAGNET,
})

------------------------------------------------------------------------------------------------------------------------
-- Items v4: the nine specials (docs/design/ITEMS_V4.md has every number and why; ITEM_OPTIONS_V2.md the specs). OURS
-- numbers, tuned in play. Speeds are plane studs/s (BASE 110, ring boost 165, overcharge 210); `factor` boosts scale
-- the racer's own cruise (plane BASE_SPEED, car TOP_SPEED) so a car and a plane gain alike. Server: kit/ItemEffects.
------------------------------------------------------------------------------------------------------------------------

local function frozenLevels(levels: { { [string]: any } }): { { [string]: any } }
	for _, t in levels do
		table.freeze(t)
	end
	return table.freeze(levels)
end

ItemRules.SPECIAL = table.freeze({
	-- Comeback self buff: autopilot down the racing line (client pure pursuit, the AutoPilot follower), invulnerable,
	-- traps ignored. shove: racers in the way spin briefly. freeSteer: the last seconds hand the wheel back.
	rocket_rush = frozenLevels({
		-- v37 (owner: specials "boring as all get out"): a real comet, longer and faster than any boost.
		{ seconds = 3.5, speed = 200, shove = true, shoveSpin = 0.8, freeSteer = 0 },
		{ seconds = 4.5, speed = 215, shove = true, shoveSpin = 1.0, freeSteer = 0 },
		{ seconds = 5.5, speed = 230, shove = true, shoveSpin = 1.0, freeSteer = 1.0 },
	}),
	-- Power fantasy: invulnerable, a little faster, contact spins a rival. coinTrail: each ram drops a coin.
	golden_wings = frozenLevels({
		-- v37: "a little faster" was not felt; a fifth faster, longer, harder rams.
		{ seconds = 5.0, factor = 1.20, spin = 1.2, coinTrail = false },
		{ seconds = 7.0, factor = 1.25, spin = 1.4, coinTrail = false },
		{ seconds = 8.0, factor = 1.30, spin = 1.5, coinTrail = true },
	}),
	-- Defensive ring, then fire: each orbiter blocks one hit while held; Use fires one homing shot (CHARGES).
	orbit_missiles = frozenLevels({
		{ orbiters = 1, turnRateDeg = 90, lockSeconds = 3.0 },
		{ orbiters = 2, turnRateDeg = 90, lockSeconds = 3.0 },
		{ orbiters = 3, turnRateDeg = 130, lockSeconds = 3.0 },
	}),
	-- Leader hit with a telegraph: a cloud over the leader for `travel` s, the siren `warn` s before the strike. A
	-- shield, an orbiter, a bubble or a plane's barrel roll inside the warning beats it. splash: racers this near the
	-- leader are slowed splashSlow s. chain: a blocked bolt jumps to the next racer (with its own warning).
	storm_bolt = frozenLevels({
		-- v37: the race's biggest moment lands like one (longer stun, a wider splash).
		{ travel = 4.0, warn = 2.0, stun = 2.2, splash = 0, splashSlow = 0, chain = false },
		{ travel = 4.0, warn = 2.0, stun = 2.2, splash = 30, splashSlow = 1.2, chain = false },
		{ travel = 4.0, warn = 2.0, stun = 2.2, splash = 30, splashSlow = 1.2, chain = true },
	}),
	-- Area blast: lobbed `throw` studs ahead, lands on the ground below (or hangs as an air mine), blows after `fuse`.
	-- patch: seconds a slow patch stays where it blew (level three).
	boom_bomb = frozenLevels({
		-- v37: a 12-stud blast in a 68-stud corridor almost never caught anyone; bigger and harder.
		{ throw = 60, fuse = 1.6, radius = 20, stun = 1.4, patch = 0 },
		{ throw = 60, fuse = 1.6, radius = 26, stun = 1.7, patch = 0 },
		{ throw = 60, fuse = 1.6, radius = 32, stun = 2.0, patch = 4 },
	}),
	-- Cluster: `gifts` lesser items fired in GIFT_SEQUENCE order, one per Use (CHARGES).
	gift_box = frozenLevels({
		{ gifts = 3 },
		{ gifts = 4 },
		{ gifts = 5 },
	}),
	-- Status shot: straight, unguided, dodgeable. slow: speed factor for slowSeconds; freeze: a short stop first
	-- (a spin-out); patch: seconds an ice patch stays on the line where it hit (level three).
	frost_shot = frozenLevels({
		-- v37: at 200 studs/s it could never catch a boosted plane (210) and flew blind in the shooter's lane; now it
		-- flies 300 and locks the racer ahead like a missile (statusShot), and every level freezes first.
		{ speed = 300, lifetime = 3.0, slow = 0.6, slowSeconds = 2.5, freeze = 0.8, patch = 0 },
		{ speed = 300, lifetime = 3.0, slow = 0.6, slowSeconds = 2.5, freeze = 1.0, patch = 0 },
		{ speed = 300, lifetime = 3.0, slow = 0.6, slowSeconds = 2.5, freeze = 1.2, patch = 8 },
	}),
	-- Risk-reward: a straight shot that slows the racer it hits and spills `coins` around them; anyone may scoop them
	-- (COIN). magnet: seconds the shooter scoops from COIN.magnetRadius instead (level three).
	coin_burst = frozenLevels({
		-- v37: same as Frost Shot: fast enough to land, locked on the racer ahead, a bigger fountain.
		{ speed = 300, lifetime = 3.0, slow = 0.7, slowSeconds = 1.5, coins = 8, magnet = 0 },
		{ speed = 300, lifetime = 3.0, slow = 0.7, slowSeconds = 1.5, coins = 12, magnet = 0 },
		{ speed = 300, lifetime = 3.0, slow = 0.7, slowSeconds = 1.5, coins = 16, magnet = 2.0 },
	}),
	-- Skill defence: a bubble for `seconds`; inside the first `window` s a missile, frost or coin shot is sent back at
	-- whoever fired it (up to `reflects`); after it, a plain block. bolts: a storm bolt is reflected too (to its
	-- caller). The windows are wider than the spec's 0.5/0.7/1.0 s on purpose: phone latency.
	bubble_guard = frozenLevels({
		{ seconds = 2.5, window = 0.8, reflects = 1, bolts = false },
		{ seconds = 3.0, window = 1.0, reflects = 2, bolts = false },
		{ seconds = 3.5, window = 1.3, reflects = 9, bolts = true },
	}),
	-- v38 Ink Splat: every racer AHEAD of the user gets ink over the screen for `seconds` (any boost wipes it at once);
	-- a bot ahead drives a little slow and loose for botSeconds. Nobody behind is touched.
	ink_splat = frozenLevels({
		{ seconds = 3.5, botSeconds = 2.0, botSlow = 0.88 },
		{ seconds = 4.5, botSeconds = 2.5, botSlow = 0.86 },
		{ seconds = 5.5, botSeconds = 3.0, botSlow = 0.84 },
	}),
	-- v38 Item Steal: take the held item of a racer ahead (level 1: the nearest one ahead holding something within
	-- `reach` course studs; level 2+: anyone ahead, the furthest ahead first). Nobody to rob: `fallback` coins.
	item_steal = frozenLevels({
		{ reach = 600, furthest = false, fallback = 3 },
		{ reach = 1e6, furthest = true, fallback = 4 },
		{ reach = 1e6, furthest = true, fallback = 5 },
	}),
	-- v38 Coin Pouch: `coins` race coins at once (the same coins the Speed pods give, capped as they are) and a short kick.
	coin_pouch = frozenLevels({
		{ coins = 3, kick = 0.8 },
		{ coins = 5, kick = 1.0 },
		{ coins = 7, kick = 1.2 },
	}),
}) :: { [string]: { { [string]: any } } }

-- Charged items: how many presses one held item gives at a level. Each press fires one; picking up a cube while
-- holding adds the next level's extra charge. Everything else is spent whole on one press.
local CHARGED: { [string]: string } = { orbit_missiles = "orbiters", gift_box = "gifts" }
function ItemRules.isCharged(id: any): boolean
	return type(id) == "string" and (CHARGED[id] ~= nil or id == "blue")
end

function ItemRules.chargesFor(id: any, level: number): number?
	if id == "blue" then
		return BOOST[math.clamp(math.floor(level), 1, ItemRules.MAX_LEVEL)].charges
	end
	local field = if type(id) == "string" then CHARGED[id] else nil
	if not field then
		return nil
	end
	local lv = math.clamp(math.floor(level), 1, ItemRules.MAX_LEVEL)
	return ItemRules.SPECIAL[id][lv][field]
end

-- Gift box: what each gift is, in firing order (the fifth, level three only, is the bonus rare), and the lesser
-- parameters each one fires with.
ItemRules.GIFT_SEQUENCE = (table.freeze({ "red", "blue", "yellow", "green", "golden_wings" }) :: any) :: { Color }
ItemRules.GIFT_MINI = table.freeze({
	red = MISSILE[1],
	blue = table.freeze({ seconds = 1.2, speed = 150 }),
	yellow = table.freeze({ radius = 14, spin = 0.8, clear = 24 }), -- v38: a small horn
	green = TRAP[1],
	golden_wings = table.freeze({ seconds = 2.5, factor = 1.10, spin = 0.8, coinTrail = false }),
}) :: { [string]: any }

-- Orbit Missiles: the homing shot one orbiter fires (missile v3 lock, MissileRules), by the level held at the press.
function ItemRules.orbitShot(level: number): MissileParams
	local lv = math.clamp(math.floor(level), 1, ItemRules.MAX_LEVEL)
	local o = ItemRules.SPECIAL.orbit_missiles[lv]
	return {
		count = 1,
		homing = true,
		freeHoming = lv >= 3,
		speed = 320,
		turnRateDeg = o.turnRateDeg,
		lifetime = o.lockSeconds,
		burstInterval = 0,
		stunSeconds = 1.5,
	}
end

-- Frost Shot / Coin Burst: the straight, unguided shot they fly (missile engine; homing = false is the course shot).
function ItemRules.statusShot(id: string, level: number): MissileParams
	local lv = math.clamp(math.floor(level), 1, ItemRules.MAX_LEVEL)
	local p = ItemRules.SPECIAL[id][lv]
	return {
		count = 1,
		homing = true, -- v37: locks the racer ahead (it flew blind in the shooter's lane and almost never landed)
		freeHoming = false,
		speed = p.speed,
		turnRateDeg = 60, -- a gentler lane slide than a missile's (missileLateralRate x 60/90)
		lifetime = p.lifetime,
		burstInterval = 0,
		stunSeconds = if type(p.freeze) == "number" then p.freeze else 0,
	}
end

-- Slow status (Frost Shot, Coin Burst, Storm Bolt splash, slow patches). A slow never stacks: a new slow keeps the
-- stronger factor (never below floor) and the later end, and no slow runs longer than maxSeconds from now.
ItemRules.SLOW = table.freeze({
	floor = 0.55, -- the slowest a racer is ever made (speed factor)
	maxSeconds = 3.0, -- cap on a slow's remaining time
	patchTick = 0.5, -- s a slow patch re-applies while a racer sits in it
	patchFactor = 0.7, -- a patch's speed factor
	patchRadius = 10, -- studs
})

-- Combines a running slow (factor, seconds left; 0 when none) with a new one. Returns (factor, seconds left).
function ItemRules.combineSlow(curFactor: number, curLeft: number, newFactor: number, newSeconds: number): (number, number)
	local S = ItemRules.SLOW
	local nf = math.clamp(newFactor, S.floor, 1)
	if curLeft <= 0 then
		return nf, math.clamp(newSeconds, 0, S.maxSeconds)
	end
	return math.max(S.floor, math.min(curFactor, nf)), math.clamp(math.max(curLeft, newSeconds), 0, S.maxSeconds)
end

-- Coins (Coin Burst, Golden Wings level three): scattered around a point; anyone within `radius` scoops one for a tiny
-- speed lift (boostSeconds at boostFactor, a racer's coin lift capped at maxSeconds).
ItemRules.COIN = table.freeze({
	radius = 8, -- studs from a hull to scoop a coin
	magnetRadius = 26, -- the Coin Burst level-three shooter's reach while its magnet runs
	spread = 18, -- studs: the outer ring of a burst (the inner ring at 0.55 of it, outside the victim's own reach)
	armSeconds = 0.6, -- a fresh coin cannot be scooped yet (the victim drives on; the racers behind find them)
	lifetime = 10, -- s a coin stays
	boostSeconds = 0.4,
	boostFactor = 1.12,
	maxSeconds = 2.5,
	maxCoins = 60, -- in the world at once (oldest go first)
})

-- v38 (Mario Kart 8): race coins (the "Speed" pods, PlaneConfig/CarConfig MAX_SPEED_PICKUPS, SPEED_PICKUP_BONUS top
-- speed each) a racer drops when an item hits it. Client-side: the coin bonus is the racer's own top speed.
ItemRules.COIN_HIT_LOSS = 3

-- Where the n coins of a burst land around `center` (flat offsets, two rings, spread studs at most). Pure.
function ItemRules.coinOffsets(n: number): { { number } }
	local out: { { number } } = {}
	local count = math.max(0, math.floor(n))
	local inner = math.min(count, 6)
	for i = 1, count do
		local ring = if i <= inner then 1 else 2
		local k = if ring == 1 then inner else count - inner
		local j = if ring == 1 then i else i - inner
		local a = (j - 1) / math.max(1, k) * math.pi * 2 + (if ring == 2 then math.pi / math.max(1, k) else 0)
		local r = if ring == 1 then ItemRules.COIN.spread * 0.55 else ItemRules.COIN.spread
		table.insert(out, { math.cos(a) * r, math.sin(a) * r })
	end
	return out
end

-- Rocket Rush: how long the rocket runs for a racer `gap` studs behind the leader (0 or less: the racer leads). It ends
-- early rather than carry the racer more than passLeadSeconds past P1 (the leader assumed at cruise): never under
-- minSeconds, never over the level's seconds.
ItemRules.ROCKET = table.freeze({ passLeadSeconds = 3, cruise = 110, minSeconds = 1.0 })
function ItemRules.rocketSeconds(seconds: number, speed: number, gap: number): number
	local R = ItemRules.ROCKET
	local closing = speed - R.cruise
	if closing <= 0 then
		return seconds
	end
	local reach = (math.max(0, gap) + R.passLeadSeconds * R.cruise) / closing
	return math.clamp(reach, math.min(R.minSeconds, seconds), seconds)
end

-- Ram (Golden Wings, Rocket Rush level two and up): a rival whose hull comes this close spins.
ItemRules.RAM_RADIUS = 11

-- Client look of the charged items' ring (Orbit Missiles orbiters, Gift Box gifts; client ItemsV4Fx): sparks circling
-- the hull at `radius` studs, `height` over it, one turn per `period` s. Low and level, so the ring never sits between
-- the chase camera and the route.
ItemRules.ORBIT_FX = table.freeze({ radius = 5.5, height = 1.2, period = 1.4, scan = 0.3 })

-- Flat offsets (x, z) of n ring members at time t, evenly spaced and turning. Pure.
function ItemRules.orbitOffsets(n: number, t: number): { { number } }
	local F = ItemRules.ORBIT_FX
	local out: { { number } } = {}
	local count = math.max(0, math.floor(n))
	local base = (t % F.period) / F.period * math.pi * 2
	for i = 1, count do
		local a = base + (i - 1) / count * math.pi * 2
		table.insert(out, { math.cos(a) * F.radius, math.sin(a) * F.radius })
	end
	return out
end

-- Every PodType a map plan may place, in menu/debug order. The first five are items; Speed and Air are not.
ItemRules.POD_TYPES = table.freeze({ "Red", "Blue", "Yellow", "Green", "Rainbow", "Speed", "Air" }) :: { string }

-- Colours as 0-255 RGB triples, not Color3, so this module stays free of Roblox types and runs under Lune.
-- Red, Blue, Speed and Air equal kit/Gameplay's existing pod colours. Yellow is paler than the gold Air pod and Green
-- deeper than the mint Speed pod so a non-item pod never reads as an item at phone size; Rainbow is the base hue the
-- client cycles from.
ItemRules.POD_RGB = table.freeze({
	Red = table.freeze({ 255, 75, 65 }),
	Blue = table.freeze({ 65, 215, 245 }),
	Yellow = table.freeze({ 255, 240, 130 }),
	Green = table.freeze({ 40, 165, 60 }),
	Rainbow = table.freeze({ 205, 110, 255 }),
	Speed = table.freeze({ 95, 245, 130 }),
	Air = table.freeze({ 255, 200, 55 }),
}) :: { [string]: { number } }

-- HUD slot, shield bubble, trails: the held item's colour.
ItemRules.COLOR_RGB = table.freeze({
	red = table.freeze({ 255, 82, 64 }),
	blue = table.freeze({ 70, 205, 255 }),
	yellow = table.freeze({ 255, 226, 80 }),
	green = table.freeze({ 60, 190, 80 }),
	rainbow = table.freeze({ 205, 110, 255 }),
	-- Items v4 gem colours: each apart from the classic four and from each other at phone size (the glyph in
	-- ICON carries the rest).
	rocket_rush = table.freeze({ 255, 128, 36 }),
	golden_wings = table.freeze({ 255, 184, 0 }),
	orbit_missiles = table.freeze({ 255, 70, 150 }),
	storm_bolt = table.freeze({ 120, 92, 225 }),
	boom_bomb = table.freeze({ 78, 82, 104 }),
	gift_box = table.freeze({ 255, 128, 205 }),
	frost_shot = table.freeze({ 160, 232, 255 }),
	coin_burst = table.freeze({ 212, 164, 44 }),
	bubble_guard = table.freeze({ 70, 228, 200 }),
	ink_splat = table.freeze({ 70, 40, 120 }),
	item_steal = table.freeze({ 150, 160, 190 }),
	coin_pouch = table.freeze({ 255, 206, 60 }),
}) :: { [string]: { number } }

-- Short HUD caption per colour (readable at 740x360).
ItemRules.DISPLAY_NAME = table.freeze({
	red = "MISSILE",
	blue = "BOOST",
	yellow = "HORN",
	green = "TRAP",
	rainbow = "MAGNET",
	rocket_rush = "ROCKET RUSH",
	golden_wings = "GOLDEN WINGS",
	orbit_missiles = "ORBIT MISSILES",
	storm_bolt = "STORM BOLT",
	boom_bomb = "BOOM BOMB",
	gift_box = "GIFT BOX",
	frost_shot = "FROST SHOT",
	coin_burst = "COIN BURST",
	bubble_guard = "BUBBLE GUARD",
	ink_splat = "INK SPLAT",
	item_steal = "ITEM STEAL",
	coin_pouch = "COIN POUCH",
}) :: { [string]: string }

-- Items v4 HUD icons, drawn in engine with no new upload (docs/design/ITEMS_V4.md "icon art pending"): `tex` is an
-- existing ItemTexAssets key ("" = none) shown on the gem in COLOR_RGB, `glyph` a short GothamBlack mark in the gem's
-- lower right so two specials sharing a texture still read apart. Classic items keep their textures and no glyph.
export type Icon = { tex: string, glyph: string }
ItemRules.ICON = table.freeze({
	red = table.freeze({ tex = "missile", glyph = "" }),
	blue = table.freeze({ tex = "boost", glyph = "" }),
	yellow = table.freeze({ tex = "shield", glyph = "))" }), -- v38 horn: placeholder until the icon lane redraws it
	green = table.freeze({ tex = "trap", glyph = "" }),
	rainbow = table.freeze({ tex = "magnet", glyph = "" }),
	rocket_rush = table.freeze({ tex = "boost", glyph = ">>" }),
	golden_wings = table.freeze({ tex = "shield", glyph = "W" }),
	orbit_missiles = table.freeze({ tex = "missile", glyph = "O" }),
	storm_bolt = table.freeze({ tex = "missile", glyph = "1ST" }),
	boom_bomb = table.freeze({ tex = "trap", glyph = "B" }),
	gift_box = table.freeze({ tex = "", glyph = "+" }),
	frost_shot = table.freeze({ tex = "missile", glyph = "*" }),
	coin_burst = table.freeze({ tex = "missile", glyph = "C" }),
	bubble_guard = table.freeze({ tex = "shield_hex", glyph = "R" }),
	-- v38: placeholder icons (existing textures + a glyph) until the icon lane draws them.
	ink_splat = table.freeze({ tex = "", glyph = "INK" }),
	item_steal = table.freeze({ tex = "", glyph = "?" }),
	coin_pouch = table.freeze({ tex = "", glyph = "$" }),
}) :: { [string]: Icon }

-- v38: UiV2Icons keys standing in for an item whose own item_<id> art does not exist yet (or no longer fits: the yellow
-- art is a shield). The icon lane replaces these; until then every HUD reads them through iconKey.
ItemRules.ICON_KEY = table.freeze({
}) :: { [string]: string }

function ItemRules.iconKey(id: string): string
	return ItemRules.ICON_KEY[id] or ("item_" .. id)
end

function ItemRules.iconOf(id: any): Icon?
	if type(id) ~= "string" then
		return nil
	end
	return ItemRules.ICON[id]
end

local COLOR_OF_KIND: { [Kind]: Color } = table.freeze({
	missile = "red" :: Color,
	boost = "blue" :: Color,
	shield = "yellow" :: Color,
	horn = "yellow" :: Color,
	trap = "green" :: Color,
	magnet = "rainbow" :: Color,
	rocket_rush = "rocket_rush" :: Color,
	golden_wings = "golden_wings" :: Color,
	orbit_missiles = "orbit_missiles" :: Color,
	storm_bolt = "storm_bolt" :: Color,
	boom_bomb = "boom_bomb" :: Color,
	gift_box = "gift_box" :: Color,
	frost_shot = "frost_shot" :: Color,
	coin_burst = "coin_burst" :: Color,
	bubble_guard = "bubble_guard" :: Color,
	ink_splat = "ink_splat" :: Color,
	item_steal = "item_steal" :: Color,
	coin_pouch = "coin_pouch" :: Color,
})
ItemRules.COLOR_OF_KIND = COLOR_OF_KIND

-- OURS: world tuning for the effects (server kit/ItemEffects) and the client spin-out (FlightController). One table so
-- the playtest under TEST_LIST_LAUNCH L07 tunes one place. Distances are studs, times seconds.
ItemRules.TUNING = table.freeze({
	missileHitRadius = 9, -- plane hull is about 16 wide; a hit inside the wingspan reads as a hit at phone size
	missileLaunchAhead = 10, -- spawn in front of the nose so the shooter never sees it pass through the cockpit
	missileFacingMinDot = 0.7, -- v37: a race shot from a vehicle facing further than ~45 deg off the course leaves along it
	missileLaunchLead = 0.12, -- v37: s of the player's own velocity added to the spawn (server hull lag; see ItemEffects)
	missileBlendSeconds = 0.35, -- launch line -> course line blend, so a shot from an alternate route stays readable
	missilePursuitRange = 70, -- a homing missile flies the course until this close, then chases the hull directly
	missileLateralRate = 70, -- studs/s a homing missile slides across the corridor per 90 deg/s of turn rate
	missileVolleySpread = 2.5, -- lateral spacing of the level-three ten-shot burst
	maxMissiles = 48,
	trapHitRadius = 11,
	trapArmSeconds = 0.6,
	trapOwnerGrace = 1.5, -- the dropper cannot trip their own trap this soon after dropping it
	trapDropBehind = 14,
	trapSweepMax = 80, -- a racer moving further than this in one server step teleported; never sweep that line
	maxTraps = 24,
	hitGraceSeconds = 0.4, -- immune for stun + this after a hit, so a ten-shot volley cannot stun-lock one racer
	stunSpeedFactor = 0.45, -- client: plane speed cap during a spin-out, times PlaneConfig.BASE_SPEED
	botHitSpeedFactor = 0.4, -- fallback bot slow-down while stunned (AIRacers may register its own handler)
	corridorHalfWidth = 34, -- MAP_PLAN_SCHEMA flight.corridor; course-following shots stay inside it
	corridorFloor = 5, -- map/dino4/plan.json flight.corridor.floor (the compile gate keeps this band free of parts)
	corridorCeiling = 44,
	-- Magnet v2 (ItemRules.magnetPick; server kit/ItemEffects, client MagnetAim / FlightController / CarController).
	magnetAheadTie = 20, -- a racer in front of the nose wins over a nearer one behind by up to this many studs
	magnetRangeSlack = 12, -- server: replication lag between the HUD's "in range" and the server's positions
	magnetArrive = 16, -- hull to hull: the pull ends here (contact) with a pop, no stun for the target
	magnetSteerBlend = 0.6, -- car: share of the steering the pull takes (the player still steers the rest)
	magnetPulseSeconds = 1.2, -- a magnet used with nobody in range keeps looking this long, then ends (the slot is spent)
	magnetYawRate = 80, -- plane: deg/s the heading turns toward the target on top of the player's own steering
})

function ItemRules.podRgb(podType: any): { number }?
	if type(podType) ~= "string" then
		return nil
	end
	return ItemRules.POD_RGB[podType]
end

function ItemRules.colorRgb(color: any): { number }?
	if type(color) ~= "string" then
		return nil
	end
	return ItemRules.COLOR_RGB[color]
end

export type MagnetCandidate = { id: string, pos: Vector3 }

-- Magnet v2 target rule, shared by the server (who it locks), the holder's HUD (who it WILL lock) and the bots: the
-- closest other racer, straight-line studs. A racer in front of `forward` (the flat heading) is preferred over a nearer
-- one behind by up to TUNING.magnetAheadTie studs, so a near-tie goes forward (a catch-up item should not drag you back
-- for a two-stud difference). Racers within `range` win over any out of it; with nobody in range the closest overall is
-- still returned (inRange false: the HUD greys that marker). Returns id, straight distance, inRange.
function ItemRules.magnetPick(selfPos: Vector3, forward: Vector3, candidates: { MagnetCandidate }, range: number): (string?, number, boolean)
	-- Flat heading by components (no Vector3 constructor: this module also loads under plain Lune).
	local fx, fz = forward.X, forward.Z
	local tie = ItemRules.TUNING.magnetAheadTie
	local bestId: string?, bestScore, bestD, bestIn = nil, math.huge, math.huge, false
	for _, c in candidates do
		local to = c.pos - selfPos
		local d = to.Magnitude
		local inRange = d <= range
		local score = d + (if to.X * fx + to.Z * fz > 0 then 0 else tie)
		if (inRange and not bestIn) or (inRange == bestIn and score < bestScore) then
			bestId, bestScore, bestD, bestIn = c.id, score, d, inRange
		end
	end
	return bestId, if bestId then bestD else math.huge, bestIn
end

-- Magnet use decision, shared by the press (pulseLeft = TUNING.magnetPulseSeconds) and each server step of a pulse:
-- "lock" a racer is within reach, "pulse" nobody is but the pulse still has time, "end" the pulse has run out. The item
-- is spent on every outcome.
function ItemRules.magnetDecision(hasTarget: boolean, pulseLeft: number): "lock" | "pulse" | "end"
	if hasTarget then
		return "lock"
	end
	return if pulseLeft > 0 then "pulse" else "end"
end

function ItemRules.isColor(value: any): boolean
	return type(value) == "string" and KIND_OF[value :: Color] ~= nil
end

function ItemRules.newState(): ItemState
	return { color = nil, level = 0 }
end

function ItemRules.isHolding(state: ItemState): boolean
	return state.color ~= nil and state.level > 0
end

-- Short form for log lines and HUD debug: "none" or "red:2".
function ItemRules.label(state: ItemState): string
	local color = state.color
	if color == nil or state.level <= 0 then
		return "none"
	end
	return color .. ":" .. tostring(state.level)
end

function ItemRules.classifyPod(podType: any): (PodClass, Color?)
	if type(podType) ~= "string" then
		return "unknown", nil
	end
	local color: Color? = POD_COLOR[podType]
	if color then
		return "item", ItemRules.liveColor(color)
	elseif podType == "Speed" then
		return "speed", nil
	elseif podType == "Air" then
		return "air", nil
	end
	return "unknown", nil
end

-- Item bugs audit (docs/audits/item_bugs.md): whether a client should trigger a pod at all. After the local racer has
-- finished, the server refuses item pods (canAct "finished"), so the client must not pop and chime for them: that was a
-- pickup that gave nothing. Speed and Air pods stay client effects and always trigger.
function ItemRules.clientTakesPod(podType: any, raceFinished: any): boolean
	if raceFinished ~= true then
		return true
	end
	return ItemRules.classifyPod(podType) ~= "item"
end

-- What the pickup answer ("ItemPickup" {outcome | reason}) shows the player: a short caption, or nil for nothing extra
-- (a fresh item or an upgrade already speak through the HUD slot and its roulette). label: the held item's caption.
function ItemRules.pickupNotice(outcome: any, reason: any, label: string?): string?
	if outcome == "capped" then
		return string.format("%s MAXED", label or "ITEM")
	elseif reason == "pod_cooldown" then
		return "CUBE TAKEN!"
	end
	return nil
end

function ItemRules.maxLevel(levelOneOnly: boolean?): number
	return if levelOneOnly then ItemRules.BATTLE_MAX_LEVEL else ItemRules.MAX_LEVEL
end

-- Returns a new state; the input is never mutated. "capped" still consumes the pod: the item just stays at the cap.
function ItemRules.pickup(state: ItemState, color: Color, levelOneOnly: boolean?): (ItemState, PickupOutcome)
	local cap = ItemRules.maxLevel(levelOneOnly)
	if not ItemRules.isHolding(state) then
		return ItemRules.held(color, 1), "new"
	elseif state.color ~= color then
		return ItemRules.held(color, 1), "replace"
	elseif state.level >= cap then
		return ItemRules.raised(state, math.min(state.level, cap)), "capped"
	end
	return ItemRules.raised(state, state.level + 1), "upgrade"
end

-- A fresh held item at `level` (a charged one full).
function ItemRules.held(color: Color, level: number): ItemState
	return { color = color, level = level, charges = ItemRules.chargesFor(color, level) }
end

-- `state` raised (or kept) at `level`: a charged item gains the charges the new level adds, never losing any it has.
function ItemRules.raised(state: ItemState, level: number): ItemState
	local color = state.color :: Color
	local out: ItemState = { color = color, level = level } :: any
	local full = ItemRules.chargesFor(color, level)
	if full then
		local before = ItemRules.chargesFor(color, state.level) or full
		local left = if type(state.charges) == "number" then state.charges else before
		out.charges = math.clamp(left + (full - before), 1, full)
	end
	return out
end

-- Clamps the level into 1..MAX_LEVEL; the returned parameter tables are frozen shared data.
function ItemRules.effectFor(color: Color, level: number): Effect
	local lv = math.clamp(math.floor(level), 1, ItemRules.MAX_LEVEL)
	local kind: Kind = KIND_OF[color]
	local effect: Effect = { color = color, kind = kind, level = lv }
	local special = ItemRules.SPECIAL[color]
	if special then
		effect.special = special[lv]
		return effect
	end
	if kind == "missile" then
		effect.missile = MISSILE[lv]
	elseif kind == "boost" then
		effect.boost = BOOST[lv]
	elseif kind == "horn" then
		effect.special = HORN[lv] -- v38: routed as a special (ItemEffects hooks.special "horn")
	elseif kind == "shield" then
		effect.shield = SHIELD[lv]
	elseif kind == "trap" then
		effect.trap = TRAP[lv]
	else
		effect.magnet = MAGNET[lv]
	end
	return effect
end

-- One gift out of a gift box: the classic (or bonus) item it is, at its lesser GIFT_MINI parameters.
function ItemRules.giftEffect(index: number): Effect
	local seq = ItemRules.GIFT_SEQUENCE
	local id: Color = seq[math.clamp(math.floor(index), 1, #seq)]
	local mini = ItemRules.GIFT_MINI[id]
	local effect: Effect = { color = id, kind = KIND_OF[id], level = 1, gift = true }
	if id == "red" then
		effect.missile = mini
	elseif id == "blue" then
		effect.boost = mini
	elseif id == "green" then
		effect.trap = mini
	else
		effect.special = mini
	end
	return effect
end

-- Consumes the whole held item (every level, every missile of a ten-shot) and returns its effect, or nil when empty.
-- Items v4: a charged item (orbit_missiles, gift_box) spends one charge per press and stays held until the last.
function ItemRules.use(state: ItemState): (ItemState, Effect?)
	local color: Color? = state.color
	if color == nil or state.level <= 0 then
		return ItemRules.newState(), nil
	end
	local full = ItemRules.chargesFor(color, state.level)
	if full then
		local left = math.clamp(if type(state.charges) == "number" then state.charges else full, 1, full)
		local effect: Effect
		if color == "gift_box" then
			effect = ItemRules.giftEffect(full - left + 1)
		else
			effect = ItemRules.effectFor(color, state.level)
		end
		if left > 1 then
			return { color = color, level = state.level, charges = left - 1 }, effect
		end
		return ItemRules.newState(), effect
	end
	return ItemRules.newState(), ItemRules.effectFor(color, state.level)
end

-- Items v4: an orbiter of a held orbit_missiles soaks up one hit. Returns the state after (the same table when there
-- is nothing to spend) and whether a hit was absorbed.
function ItemRules.absorbHit(state: ItemState): (ItemState, boolean)
	if state.color ~= "orbit_missiles" or state.level <= 0 then
		return state, false
	end
	local full = ItemRules.chargesFor(state.color, state.level) or 1
	local left = math.clamp(if type(state.charges) == "number" then state.charges else full, 0, full)
	if left <= 0 then
		return state, false
	end
	if left > 1 then
		return { color = state.color, level = state.level, charges = left - 1 }, true
	end
	return ItemRules.newState(), true
end

------------------------------------------------------------------------------------------------------------------------
-- Mystery cubes (race pods). OURS numbers throughout, tuned in play under TEST_LIST_LAUNCH L07.
------------------------------------------------------------------------------------------------------------------------

ItemRules.MYSTERY = table.freeze({
	rouletteSeconds = 1.2, -- HUD spin before the reveal; the item cannot be fired until it ends (bots wait too)
	cubeSize = 4.4, -- studs, frame outside to outside
	hover = 5.5, -- studs from the ground to the cube centre: a tumbling corner (half-diagonal 3.8) plus the 0.35 bob
	-- still clears the ground by about 1.3, and a car (bot pod height 4.5) drives straight through it
	probeUp = 3.5, -- the build raycast starts this far above the planned centre, so a pod sunk into a ramp finds its top
	probeDown = 40, -- and looks this far under it
	roadSnapMax = 20, -- car maps: ground within this gap is the road the pod belongs on (further: a jump gap, left alone)
})

-- Roll weights per colour and band (any positive scale; rollMystery normalises). Leader: defence and traps. Back: boosts
-- and missiles to catch up, almost no shields. Magnet retired (MAGNET_ENABLED): rainbow is 0 everywhere and its share
-- went to the catch-up items (v2 -> v3: front red 30->32 blue 20->23; middle red 30->36 blue 25->32 yellow 15->16
-- green 15->16; back red 25->38 blue 35->52). Every band still sums to 100.
ItemRules.MYSTERY_WEIGHTS = table.freeze({
	lead = table.freeze({ red = 25, blue = 10, yellow = 35, green = 30, rainbow = 0 }),
	front = table.freeze({ red = 32, blue = 23, yellow = 25, green = 20, rainbow = 0 }),
	middle = table.freeze({ red = 36, blue = 32, yellow = 16, green = 16, rainbow = 0 }),
	back = table.freeze({ red = 38, blue = 52, yellow = 5, green = 5, rainbow = 0 }),
	-- v38: a racer far off the leader's pace (CATCHUP.farSeconds) whatever its place: boosts first, then shots.
	far = table.freeze({ red = 30, blue = 62, yellow = 4, green = 4, rainbow = 0 }),
}) :: { [RollBand]: { [Color]: number } }

-- v38 (Mario Kart 8 rolls by distance to the leader, not only by place): the gap to the leader, in seconds at
-- `cruise`, can push a racer's band back. A P2 a long way behind a runaway leader rolls catch-up items; a pack that is
-- nose to tail rolls by place as before. The leader always rolls from "lead".
ItemRules.CATCHUP = table.freeze({
	cruise = 130, -- studs/s that convert a course gap to seconds (about a racer's cruise on cars and planes)
	middleSeconds = 2.0, -- at least the middle band this far behind the leader
	backSeconds = 4.0, -- at least the back band
	farSeconds = 7.0, -- the far band: the strongest catch-up table
})

-- Seconds behind the leader for a course gap in studs (nil / negative / NaN: 0).
function ItemRules.gapSeconds(gapStuds: number?): number
	if type(gapStuds) ~= "number" or gapStuds ~= gapStuds or gapStuds <= 0 then
		return 0
	end
	return math.min(gapStuds, 1e7) / ItemRules.CATCHUP.cruise
end

------------------------------------------------------------------------------------------------------------------------
-- Items v4: per-race item ROTATION (owner 2026-10-20: "maybe a random selection of rotated ones per match"). Each race
-- draws its pool once (RaceManager, at the reset): the classic core is always on, plus ROTATION.size specials taken
-- from a seeded order of SPECIALS, a window that moves ROTATION.size along per race, so every special shows within
-- ceil(#SPECIALS / size) races in a row. Rolls, cube ghosts, the HUD roulette and the bots all use the race's pool.
-- The magnet stays out (MAGNET_ENABLED).
------------------------------------------------------------------------------------------------------------------------

ItemRules.ROTATION = table.freeze({
	core = table.freeze({ "red", "blue", "yellow", "green" }) :: { string },
	specials = LIVE_SPECIALS, -- v38: retired items never rotate in
	size = 4, -- specials per race
	poolAttribute = "ItemPool", -- the race's pool for clients (RaceAttr, comma separated ids)
	announceSeconds = 4.0, -- the countdown toast "This race: ..."
})

-- Roll weights for the specials, per band, added to MYSTERY_WEIGHTS for the specials in the race's pool. Position
-- weighting in the specs' spirit: Rocket Rush only for the back of the pack, Golden Wings mid/back (rare up front),
-- Storm Bolt never for the leader, Bubble Guard and Orbit Missiles lean to the front (defence), the rest even.
ItemRules.SPECIAL_WEIGHTS = table.freeze({
	-- v38: the retired items (RETIRED) weigh 0; Ink Splat never for the leader (nobody ahead), Coin Pouch leans front
	-- (the leader's consolation, MK style), Item Steal mid-pack.
	lead = table.freeze({ rocket_rush = 0, golden_wings = 0, orbit_missiles = 14, storm_bolt = 0, boom_bomb = 12, gift_box = 10, frost_shot = 0, coin_burst = 0, bubble_guard = 0, ink_splat = 0, item_steal = 6, coin_pouch = 18 }),
	front = table.freeze({ rocket_rush = 0, golden_wings = 4, orbit_missiles = 14, storm_bolt = 4, boom_bomb = 12, gift_box = 10, frost_shot = 0, coin_burst = 0, bubble_guard = 0, ink_splat = 8, item_steal = 10, coin_pouch = 12 }),
	middle = table.freeze({ rocket_rush = 0, golden_wings = 10, orbit_missiles = 12, storm_bolt = 8, boom_bomb = 12, gift_box = 12, frost_shot = 0, coin_burst = 0, bubble_guard = 0, ink_splat = 12, item_steal = 12, coin_pouch = 6 }),
	back = table.freeze({ rocket_rush = 24, golden_wings = 16, orbit_missiles = 10, storm_bolt = 12, boom_bomb = 8, gift_box = 12, frost_shot = 0, coin_burst = 0, bubble_guard = 0, ink_splat = 12, item_steal = 10, coin_pouch = 2 }),
	far = table.freeze({ rocket_rush = 36, golden_wings = 22, orbit_missiles = 6, storm_bolt = 16, boom_bomb = 6, gift_box = 8, frost_shot = 0, coin_burst = 0, bubble_guard = 0, ink_splat = 10, item_steal = 6, coin_pouch = 0 }),
}) :: { [RollBand]: { [string]: number } }

-- Bots: how long to wait before asking ItemService to use the held item again after a refused use. A rate limited use
-- waits out the server's window (ItemService.USE_MIN_INTERVAL 0.3 s, plus a margin); any other refusal backs off
-- 1, 2, 4 s (capped) by the number of refusals in a row, so a bot never spams the same refused request (the console
-- showed "[AI] item ... ok=false reason=rate_limited" over and over). Also: only the first refusal of a streak is logged.
ItemRules.BOT_USE = table.freeze({ rateLimitedWait = 0.45, backoffBase = 1, backoffCap = 4 })

function ItemRules.botRetryDelay(reason: string?, failures: number): number
	local B = ItemRules.BOT_USE
	if reason == "rate_limited" then
		return B.rateLimitedWait
	end
	local n = math.max(1, math.floor(failures))
	return math.min(B.backoffCap, B.backoffBase * 2 ^ (n - 1))
end

function ItemRules.botShouldLogRefusal(failures: number): boolean
	return failures <= 1
end

-- A deterministic shuffle of SPECIALS for a seed (Fisher-Yates over a small LCG; the same seed always gives the same
-- order on every machine).
function ItemRules.rotationOrder(seed: number): { Color }
	local order = table.clone(LIVE_SPECIALS)
	local x = math.floor(math.abs(seed)) % 2147483647
	if x == 0 then
		x = 1
	end
	for i = #order, 2, -1 do
		x = (x * 48271) % 2147483647
		local j = (x % i) + 1
		order[i], order[j] = order[j], order[i]
	end
	return order
end

-- The pool of race number `matchIndex` (any integer; RaceResetSeq) for a server `seed`: the core, then `size`
-- specials. Pure and deterministic.
function ItemRules.drawPool(seed: number, matchIndex: number, size: number?): { string }
	local order = ItemRules.rotationOrder(seed)
	local n = #order
	local k = math.clamp(math.floor(size or ItemRules.ROTATION.size), 0, n)
	local pool: { string } = table.clone(ItemRules.ROTATION.core)
	local start = (math.floor(matchIndex) * k) % n
	for i = 0, k - 1 do
		table.insert(pool, order[((start + i) % n) + 1])
	end
	return pool
end

-- Pool <-> attribute text ("red,blue,...,storm_bolt"). parsePool keeps known live ids only, in ALL_ITEMS order, and
-- always puts the core back in: a bad or missing attribute is the classic set.
function ItemRules.poolText(pool: { string }): string
	return table.concat(pool, ",")
end

function ItemRules.parsePool(text: any): { string }
	local seen: { [string]: boolean } = {}
	if type(text) == "string" then
		for id in string.gmatch(text, "[%w_]+") do
			seen[id] = true
		end
	end
	for _, c in ItemRules.ROTATION.core do
		seen[c] = true
	end
	local out: { string } = {}
	for _, id in ALL_ITEMS do
		if seen[id] and (id ~= "rainbow" or ItemRules.MAGNET_ENABLED) and not ItemRules.RETIRED[id] then
			table.insert(out, id)
		end
	end
	return out
end

-- One-word names for the countdown's "This race:" toast (it must fit a phone's toast lane).
ItemRules.SHORT_NAME = table.freeze({
	rocket_rush = "Rocket",
	golden_wings = "Wings",
	orbit_missiles = "Orbit",
	storm_bolt = "Storm",
	boom_bomb = "Bomb",
	gift_box = "Gift",
	frost_shot = "Frost",
	coin_burst = "Coins",
	bubble_guard = "Bubble",
	ink_splat = "Ink",
	item_steal = "Steal",
	coin_pouch = "Coins",
}) :: { [string]: string }

-- The specials of a pool, for the "This race:" toast ("Rocket, Orbit, Frost, Bubble"); "" when the pool is classic.
function ItemRules.poolLine(pool: { string }): string
	local out: { string } = {}
	for _, id in pool do
		if ItemRules.isSpecial(id) then
			table.insert(out, ItemRules.SHORT_NAME[id] or id)
		end
	end
	return table.concat(out, ", ")
end

-- Storm Bolt rarity (spec: never in the last lap, at most one in flight): false while one is out or held, or the
-- racer is on the final lap.
function ItemRules.stormAllowed(finalLap: boolean, stormOut: boolean): boolean
	return not finalLap and not stormOut
end

-- Roll weights for a band over a pool (nil pool: the classic colours, exactly the pre-v4 table). blocked: ids this
-- roll may not give (Storm Bolt rarity). Zero-weight ids are left out.
function ItemRules.rollWeights(band: RollBand, pool: { string }?, blocked: { [string]: boolean }?): { [string]: number }
	local classic: { [string]: number } = ItemRules.MYSTERY_WEIGHTS[band] :: any
	local specials: { [string]: number } = ItemRules.SPECIAL_WEIGHTS[band] :: any
	local out: { [string]: number } = {}
	if pool == nil then
		for _, c in COLORS do
			local w = math.max(0, classic[c] or 0)
			if w > 0 then
				out[c] = w
			end
		end
		return out
	end
	for _, id in pool do
		if not (blocked and blocked[id]) then
			local w = math.max(0, classic[id] or specials[id] or 0)
			if w > 0 then
				out[id] = w
			end
		end
	end
	return out
end

-- 1 = leading. A field of one (time trial, a lone player) rolls from the middle band. v38: gapStuds (optional, course
-- studs behind the leader) can only push the band back (CATCHUP), never forward; the leader stays "lead".
local BAND_ORDER: { [string]: number } = { lead = 0, front = 1, middle = 2, back = 3, far = 4 }
function ItemRules.rollBand(rank: number, fieldSize: number, gapStuds: number?): RollBand
	local n = math.max(1, math.floor(fieldSize))
	local r = math.clamp(math.floor(rank), 1, n)
	if n <= 1 then
		return "middle"
	elseif r == 1 then
		return "lead"
	end
	local f = (r - 1) / (n - 1)
	local band: RollBand = "back"
	if f <= 1 / 3 then
		band = "front"
	elseif f < 2 / 3 then
		band = "middle"
	end
	local secs = ItemRules.gapSeconds(gapStuds)
	local C = ItemRules.CATCHUP
	local byGap: RollBand? = if secs >= C.farSeconds
		then "far"
		elseif secs >= C.backSeconds then "back"
		elseif secs >= C.middleSeconds then "middle"
		else nil
	if byGap and BAND_ORDER[byGap] > BAND_ORDER[band] then
		band = byGap
	end
	return band
end

-- r in [0, 1) (the caller's random number, so the roll is deterministic under test). Walks ALL_ITEMS in order.
-- Items v4: pool (the race's rotation; nil = the classic colours) and blocked (ids this roll may not give).
-- v38: gapStuds, the racer's course gap to the leader (rollBand).
function ItemRules.rollMystery(rank: number, fieldSize: number, r: number, pool: { string }?, blocked: { [string]: boolean }?, gapStuds: number?): Color
	local weights = ItemRules.rollWeights(ItemRules.rollBand(rank, fieldSize, gapStuds), pool, blocked)
	local total = 0
	for _, c in ALL_ITEMS do
		total += weights[c] or 0
	end
	local pick = math.clamp(r, 0, 0.999999) * total
	local last: Color = COLORS[1]
	for _, c: Color in ALL_ITEMS do
		local w = weights[c :: string] or 0
		if w > 0 then
			last = c
			if pick < w then
				return c
			end
			pick -= w
		end
	end
	return last
end

-- A mystery cube taken. Holding something: that item goes up one level (capped at the mode's maximum; "capped" still
-- uses the cube up). Empty: the rolled colour at level one. Returns a new state; the input is never mutated.
function ItemRules.pickupMystery(state: ItemState, rolled: Color, levelOneOnly: boolean?): (ItemState, PickupOutcome)
	if state.color == nil or state.level <= 0 then
		return ItemRules.held(rolled, 1), "new"
	end
	local cap = ItemRules.maxLevel(levelOneOnly)
	if state.level >= cap then
		return ItemRules.raised(state, math.min(state.level, cap)), "capped"
	end
	return ItemRules.raised(state, state.level + 1), "upgrade"
end

-- Cubes v3 (owner 2026-10-20: "Second cube levels up the held item (Diddy Kong Racing)"): pickupMystery plus the HUD
-- spin to publish. A fresh roll spins rouletteSeconds. A second cube while that spin still runs (rollingLeft > 0) is a
-- queued level-up: the level goes up now on the server, the HUD keeps spinning for what is left and reveals the item
-- at the new level (no early reveal, no second spin). Otherwise an upgrade or a cap publishes no spin.
function ItemRules.cubeTake(state: ItemState, rolled: Color, rollingLeft: number?, levelOneOnly: boolean?): (ItemState, PickupOutcome, number?)
	local after: ItemState, outcome: PickupOutcome = ItemRules.pickupMystery(state, rolled, levelOneOnly)
	if outcome == "new" then
		return after, "new", ItemRules.MYSTERY.rouletteSeconds
	end
	if rollingLeft and rollingLeft > 0 then
		return after, outcome, rollingLeft
	end
	return after, outcome, nil
end

-- HUD side of the same rule: an ItemState for the colour already spinning, with a roulette still to run, keeps the spin
-- going and only raises the level the reveal will show.
function ItemRules.rouletteQueued(spinning: boolean, prevColor: string?, newColor: string?, roulette: number?): boolean
	return spinning and newColor ~= nil and newColor == prevColor and type(roulette) == "number" and roulette > 0
end

-- 1-based place of `progress` among every racer's progress (its own value included once in `all`); ties share the
-- better place. fieldSize is #all.
function ItemRules.rankIn(progress: number, all: { number }): (number, number)
	local ahead = 0
	for _, p in all do
		if p > progress then
			ahead += 1
		end
	end
	return ahead + 1, math.max(1, #all)
end

-- v38: course studs between `progress` and the furthest racer still racing (finite progress) in `all`; 0 when
-- `progress` leads that group or is not finite (a finished racer).
function ItemRules.leaderGap(progress: number, all: { number }): number
	if progress ~= progress or progress == math.huge then
		return 0
	end
	local best = progress
	for _, p in all do
		if p ~= math.huge and p == p and p > best then
			best = p
		end
	end
	return best - progress
end

-- Cube centre height after the build raycast. groundY nil: nothing under it (an air pod over a void), unchanged.
-- onRoad (car maps): ground within roadSnapMax puts the cube at hover over it, whether it floated too high or clipped.
-- Air pods (plane maps) fly at their planned height and are only lifted when they would clip into what is under them.
function ItemRules.cubeHoverY(podY: number, groundY: number?, onRoad: boolean): number
	return ItemRules.podHoverY(podY, groundY, onRoad, ItemRules.MYSTERY.hover)
end

-- The same rule for any pod with its own hover (cubes v2: Speed/Air pods on road maps use CUBES.coinHover, so a row of
-- pickups reads as one height instead of a coin skimming the road beside cubes at +5.5).
function ItemRules.podHoverY(podY: number, groundY: number?, onRoad: boolean, hover: number): number
	if groundY == nil then
		return podY
	end
	local gap = podY - groundY
	if onRoad then
		return if gap <= ItemRules.MYSTERY.roadSnapMax then groundY + hover else podY
	end
	return if gap < hover then groundY + hover else podY
end

-- The HUD roulette: when (seconds after the pickup) each frame shows, and which colour. Ticks start fast and slow down
-- (quadratic ease), the colours walk LIVE_COLORS from `seed`, the second-to-last frame is never the final colour (so the
-- reveal is a change), and the last frame, at exactly `seconds`, is `final`.
export type RouletteFrame = { t: number, color: Color }
function ItemRules.rouletteFrames(seconds: number, final: Color, seed: number?, pool: { string }?): { RouletteFrame }
	local frames: { RouletteFrame } = {}
	local total = math.max(0, seconds)
	local steps = math.max(2, math.floor(total / 0.075))
	-- A retired item never flashes in the spin; items v4: the race's pool when there is one.
	local walk: { any } = if pool and #pool > 1 then pool else LIVE_COLORS
	local start = math.floor(seed or 0) % #walk
	for i = 0, steps - 2 do
		local u = i / (steps - 1)
		local color: Color = walk[((start + i) % #walk) + 1]
		table.insert(frames, { t = total * u * u, color = color } :: RouletteFrame)
	end
	local prev = frames[#frames]
	if prev and prev.color == final then
		local idx = table.find(walk, final) or 1
		prev.color = walk[(idx % #walk) + 1]
	end
	table.insert(frames, { t = total, color = final } :: RouletteFrame)
	return frames
end

------------------------------------------------------------------------------------------------------------------------
-- REMARKABLE item 14: incoming-missile warning (server ETA -> client beeps). Information only: nothing here changes a
-- missile, a hit or a speed. OURS numbers, tuned for "panic, then a fair chance to change lanes".
------------------------------------------------------------------------------------------------------------------------

ItemRules.INCOMING = table.freeze({
	warnSeconds = 2.5, -- no warning for a shot further out than this (seconds to impact)
	minClosing = 12, -- studs/s; a shot closing slower than this is not "incoming" (it is pacing you)
	laneRadius = 15, -- an unguided course shot warns a racer whose lane is this close to the shot's lane (hit radius 9)
	tick = 0.2, -- s between server ETA updates (5 Hz; one small remote per warned player)
	closeCallEta = 0.8, -- a warned racer this close to impact who is then passed or missed gets DODGED!
	passMargin = 6, -- studs past the racer before a shot counts as having gone by
	assumedSpeed = 120, -- studs/s: the racer's speed on the first sample, before a second position exists
	coneDot = 0.6, -- a free-flying shot must head within ~53 degrees of the racer to warn it
})

-- Seconds until a shot `gap` studs away, closing at `closing` studs/s, reaches the racer; nil when it is not a threat
-- (behind the racer, too slow to catch it, or further out than maxSeconds).
function ItemRules.incomingEta(gap: number, closing: number, maxSeconds: number?, minClosing: number?): number?
	local cap = maxSeconds or ItemRules.INCOMING.warnSeconds
	local floor = minClosing or ItemRules.INCOMING.minClosing
	if gap <= 0 or closing < floor then
		return nil
	end
	local eta = gap / closing
	if eta > cap then
		return nil
	end
	return eta
end

-- Beep cadence for an ETA: 0.5 s apart at the edge of the warning, accelerating to a 0.07 s trill on impact. Eased, so
-- the last second is where the panic lives.
function ItemRules.beepInterval(eta: number): number
	local k = math.clamp((eta - 0.25) / (ItemRules.INCOMING.warnSeconds - 0.25), 0, 1)
	return 0.07 + (0.5 - 0.07) * (k ^ 1.4)
end

-- Beep pitch rises as the shot closes (1.0 far, 1.45 at impact); a homing lock sits a little higher.
function ItemRules.beepPitch(eta: number, homing: boolean?): number
	local k = 1 - math.clamp(eta / ItemRules.INCOMING.warnSeconds, 0, 1)
	return (if homing then 1.08 else 1.0) + 0.45 * k
end

------------------------------------------------------------------------------------------------------------------------
-- REMARKABLE item 18: getting even. A grudge book per race: who last hit whom. Hitting back the racer who hit you
-- inside REVENGE_WINDOW is a revenge (banner "EVEN"); answering that escalates the chain ("EVEN x2", ...). Pure; ItemService owns
-- the live book.
------------------------------------------------------------------------------------------------------------------------

export type Grudge = { by: string, at: number, chain: number }
export type GrudgeBook = { [string]: Grudge }
export type HitKind = "hit" | "revenge" | "self"

ItemRules.REVENGE_WINDOW = 60 -- s a grudge stays open (about a lap)

function ItemRules.newGrudgeBook(): GrudgeBook
	return {}
end

-- The open grudge racerId holds (whom they owe a hit), or nil.
function ItemRules.grudgeOf(book: GrudgeBook, racerId: string, now: number): Grudge?
	local g = book[racerId]
	if g and now - g.at <= ItemRules.REVENGE_WINDOW then
		return g
	end
	return nil
end

-- Records a landed hit and classifies it. "self": your own trap (no grudge). "revenge": the attacker held a grudge
-- against this victim; chain 1 = REVENGE, 2 = RE-REVENGE, 3+ = a feud. Either way the victim now holds a grudge against
-- the attacker carrying the chain forward, so answering a revenge escalates it.
function ItemRules.recordHit(book: GrudgeBook, victim: string, attacker: string, now: number): (HitKind, number)
	if victim == attacker then
		return "self", 0
	end
	local kind: HitKind = "hit"
	local chain = 0
	local owed = ItemRules.grudgeOf(book, attacker, now)
	if owed and owed.by == victim then
		kind = "revenge"
		chain = owed.chain + 1
		book[attacker] = nil
	end
	book[victim] = { by = attacker, at = now, chain = chain }
	return kind, chain
end

-- The PAYBACK tag over the racer who hit you is a toast, not a marker: it pops in (back-out overshoot), holds, fades,
-- and is gone (<= 1.8 s on screen), though the grudge itself stays open for REVENGE_WINDOW. A repeat hit by the same
-- racer re-pops it at most once per repop seconds.
ItemRules.NEMESIS_TOAST = table.freeze({ popIn = 0.15, hold = 1.2, fadeOut = 0.3, repop = 4 })

-- Toast look at age seconds since it popped: (scale 0..1.15, transparency 0..1), or nil once it is over. Pure.
function ItemRules.nemesisToast(age: number): (number?, number?)
	local T = ItemRules.NEMESIS_TOAST
	if age < 0 or age >= T.popIn + T.hold + T.fadeOut then
		return nil, nil
	end
	if age < T.popIn then
		local x = age / T.popIn - 1
		return math.max(0, 1 + x * x * (2.7 * x + 1.7)), 0
	elseif age < T.popIn + T.hold then
		return 1, 0
	end
	return 1, (age - T.popIn - T.hold) / T.fadeOut
end

-- Whether a hit may re-pop the toast: a different racer always, the same one once per repop seconds.
function ItemRules.nemesisRepop(sameRacer: boolean, sinceLastPop: number): boolean
	return not sameRacer or sinceLastPop >= ItemRules.NEMESIS_TOAST.repop
end

-- Banner word for the avenger: brief and informational (owner tone rule, v38-flow: no "REVENGE!" comic callouts).
-- chain 1 = "EVEN", 2+ = "EVEN x2", "EVEN x3" ...; the banner reads "EVEN  NAME".
function ItemRules.revengeLabel(chain: number): string
	if chain <= 1 then
		return "EVEN"
	end
	return string.format("EVEN x%d", math.floor(chain))
end

-- A display name cut to fit the banner plank at phone size (never mid-way through a multi-byte character).
function ItemRules.shortName(name: any, maxChars: number?): string
	if type(name) ~= "string" or name == "" then
		return "SOMEONE"
	end
	local cap = maxChars or 14
	local n = utf8.len(name)
	if not n or n <= cap then
		return name
	end
	local cut = utf8.offset(name, cap)
	return if cut then string.sub(name, 1, cut - 1) .. "." else name
end

-- Mystery cube readability (client ItemClient + ItemArt): the glowing core's pulse, its fade near the camera (cubes are
-- driven through; the core must never white out the screen) and the ground ring's cadence.
ItemRules.CUBE_FX = table.freeze({
	coreSize = 0.52, -- core edge as a fraction of the glass edge
	coreTransparencyMin = 0.12, -- brightest point of the pulse
	coreTransparencyMax = 0.42, -- dimmest point
	pulseSeconds = 1.8, -- one core pulse
	-- v29 W1b A1 (critic v29: forest1/snow1 V12 frames still had full cubes 9-15 studs from the lens: a 4.4-stud tumbling
	-- cube passed at that range half fills a phone frame, and the old 22 -> 9 window left it 0-50 % faded there):
	-- everything about a cube is gone under 18 studs and thins out from 30, beside the camera as well as ahead.
	nearFadeStart = 30, -- v29: was 25 -- studs from the camera: the core starts to fade
	nearFadeEnd = 18, -- v29: was 10 -- ... and is gone (also the "?" faces and the inner icon switch off)
	ringPeriod = 1.2, -- seconds between ground rings
	ringRange = 200, -- studs from the camera: the ring only pulses this close
	ringSize = 11, -- studs across at the end of the ring
	ringMinScale = 0.25, -- below this particleScale the ring is skipped entirely
	-- Point-blank (a drive-through): the Neon frame bars and the soft halo bloom to a wall of yellow when the lens is a
	-- stud or two from them, so both thin out over the last few studs (Studio 2026-10-20: bars filled half the screen).
	-- v22: old -> new: frameFadeStart 8 -> 9, frameFadeEnd 4.5 -> 6, frameFadeMax 0.92 -> 1 (the bars are hidden entirely within 6 studs;
	-- at 3.5 studs they still covered large parts of the screen)
	frameFadeStart = 30, -- v29: was 22 -- studs from the camera: the frame starts to turn see-through
	frameFadeEnd = 18, -- v29: was 9 -- ... fully hidden (frameFadeMax) here and closer
	frameFadeMax = 1, -- LocalTransparencyModifier at frameFadeEnd (fully invisible; the cube's collision and glow core are separate)
	haloFadeStart = 30, -- v29: was 24 -- the halo billboard starts to fade out
	haloFadeEnd = 18, -- v29: was 10 -- ... and is gone
	haloBase = 0.55, -- the halo's ImageTransparency when the camera is away
})

-- v31 cube-camera (visual_critic_v29 A1, Studio V14 dino4/forest1: cubes still read as big frames near the lens): the
-- chase camera sits up to ~21 studs from a car (CAM_DISTANCE + speed and reverse pullback, CAM_HEIGHT) and ~22 from a
-- boosting plane (CAM_DISTANCE + the speed trail; items_spec derives both from the configs), and a pickup passes through the vehicle, so the
-- cube is at least that far from the lens when it is collected. The fade and a visible shrink therefore finish BEYOND
-- the camera-to-vehicle distance (planes earlier than cars); the pickup trigger (server, hitbox) is never touched.
-- shrinkStart/shrinkEnd: visible scale 1 -> shrinkMin. fadeStart/fadeEnd: core, glass, frame, halo, "?" and ghost go.
ItemRules.CUBE_CAMERA_BANDS = table.freeze({
	car = table.freeze({ shrinkStart = 46, shrinkEnd = 27, fadeStart = 38, fadeEnd = 25 }),
	plane = table.freeze({ shrinkStart = 58, shrinkEnd = 34, fadeStart = 48, fadeEnd = 31 }),
	shrinkMin = 0.18,
})

function ItemRules.cubeBand(isPlane: boolean)
	return if isPlane then ItemRules.CUBE_CAMERA_BANDS.plane else ItemRules.CUBE_CAMERA_BANDS.car
end

-- box-range (owner 2026-10-21: boxes vanished before the vehicle reached them): the lens-side fade, shrink and "?" /
-- halo / ghost switch-off may only act on a cube that is NOT beyond the vehicle. `dist` = lens to cube, `vehDist` = lens
-- to the own vehicle (math.huge: no vehicle). A cube the vehicle has yet to reach lies farther from the lens than the
-- vehicle does (dist >= vehDist) and gets math.huge here = no fade, full scale. Pure presentation; the pickup trigger
-- (CarConfig 10 / PlaneConfig 14 studs) and the server checks never read it.
function ItemRules.cubeLensDist(dist: number, vehDist: number): number
	if dist >= vehDist then
		return math.huge
	end
	return dist
end

-- Visible scale of a cube `dist` studs from the lens: 1 far away (readable), shrinking linearly to shrinkMin by shrinkEnd.
function ItemRules.cubeNearScale(dist: number, isPlane: boolean): number
	local B = ItemRules.cubeBand(isPlane)
	local u = math.clamp((B.shrinkStart - dist) / (B.shrinkStart - B.shrinkEnd), 0, 1)
	return 1 - (1 - ItemRules.CUBE_CAMERA_BANDS.shrinkMin) * u
end

-- Core Transparency at time t for a camera dist studs away: a gentle pulse, fading to 1 as the camera nears the cube.
function ItemRules.cubeCoreTransparency(t: number, dist: number, isPlane: boolean?): number
	local F = ItemRules.CUBE_FX
	local B = ItemRules.cubeBand(isPlane == true)
	local wave = 0.5 + 0.5 * math.sin(t * math.pi * 2 / F.pulseSeconds)
	local pulse = F.coreTransparencyMin + (F.coreTransparencyMax - F.coreTransparencyMin) * wave
	local u = math.clamp((dist - B.fadeEnd) / (B.fadeStart - B.fadeEnd), 0, 1)
	return 1 - (1 - pulse) * u
end

-- 0 when the camera is `startD` or more studs away, 1 at `endD` or nearer, linear between (startD > endD).
function ItemRules.cubeNearAmount(dist: number, startD: number, endD: number): number
	return math.clamp((startD - dist) / (startD - endD), 0, 1)
end

-- Seconds between ground rings for a particleScale k (phones emit less often); nil: no ring at all.
function ItemRules.cubeRingPeriod(k: number): number?
	local F = ItemRules.CUBE_FX
	if k < F.ringMinScale then
		return nil
	end
	return F.ringPeriod / math.min(k, 1)
end

------------------------------------------------------------------------------------------------------------------------
-- Item cubes v2 (docs/design/ITEM_BOXES.md; owner 2026-10-20: "mirror Mario Kart (the latest one) in terms of quantity
-- and the speed in which they return to the map so that other players in the back dont lose out", and "Make the ?
-- boost/item boxes rotating different colors of and have a ghost siluhouette of the items as they rotate through").
-- The runtime numbers live here; the row layout numbers (rows per lap, gaps, widths, budget) in tools/map/item_cubes.json,
-- which the author scripts and the Lune spec both read.
------------------------------------------------------------------------------------------------------------------------

ItemRules.CUBES = table.freeze({
	-- Cubes v3 (owner 2026-10-20: "Shared like Mario Kart, back for everyone in 1.0 s"; the v2 per-racer 1.5 s regrow is
	-- retired). A race pod (cube, Speed, Air) taken by anyone, player or bot, is gone for every racer and back for
	-- everyone this long after: one server ledger entry per pod (ItemService), one OnCooldown flip (RaceManager).
	respawn = 1.0,
	battleRespawn = 4, -- the default for a coloured battle pod (BattleCore then sets the arena's own RespawnSeconds)
	-- DKR level-up across a staggered set (tools/map/item_cubes.json): a set is a front rank of 2 cubes and a back rank
	-- of 3. One pass takes at most one cube per rank: a second cube of the rank this racer just took, within this long,
	-- is left standing for the racers behind (ItemRules.rankLocked; the server ledger and the client prediction agree).
	-- So a pass through a set is one item plus at most one level-up, chained on purpose from the front rank to the back.
	rankLockSeconds = 1.0,
	-- Speed/Air pods on road maps: centre height over the road. The cube centre is MYSTERY.hover (5.5); the coin is
	-- smaller (about 3 studs), so 4.5 puts its middle on the cubes' lower third and the row reads as one height.
	coinHover = 4.5,
	-- Plane maps (owner: "when players fly over the speed boosts on the map we should probably allow a higher altitude
	-- for them to be at to get the boost but obviously not crazy high"): Speed/Air pods and ground boost pads take a
	-- plane anywhere in a vertical capsule from the pickup up to this many studs above it, horizontal radius unchanged.
	-- Pods fly at +12 over the ribbon, so the capsule's axis tops out at +32 and with the 14 stud pickup radius the
	-- reach ends at +46: the corridor ceiling (+44) plus a little, never above the flight band.
	planeLift = 20,
	-- Ghost silhouettes inside a cube: one cycle through what this racer could roll right now, each item shown for a
	-- share of ghostPeriod equal to its roll chance (ghostMinDwell floor, so a 5 % item still flashes), crossfading the
	-- cube colour over the last ghostFade seconds of each dwell.
	ghostPeriod = 4.0,
	ghostMinDwell = 0.3,
	ghostFade = 0.35,
	ghostTransparency = 0.5, -- the icon's ImageTransparency at range (a hint, not a reveal)
	ghostTint = 0.35, -- icon ImageColor3 = white lerped this far to the item colour
	-- Cubes v3: the glass and frame keep their own colour (ItemArt.cubeFamily, the owner's multicolour glass mockup); the
	-- cycling item colour drives the glowing core, the halo, the light and the ghost icon.
	animRange = 340, -- studs: cubes further than this hold still (two sets ahead at most; about 10-12 animating)
})

-- Client trigger throttle for a pod: it re-arms when the pod is back (its RespawnSeconds; OnCooldown gates it as well).
function ItemRules.podRetrigger(respawn: any): number
	return math.max(if type(respawn) == "number" then respawn else ItemRules.CUBES.respawn, 0.25)
end

-- Whether a pickup of a cube in rank `rank` (the CubeRank attribute, "<set>#<rank>") is held back because this racer
-- took a cube of the same rank `lastAt` (same clock as now) ago. Pods without a rank (Speed, Air, battle) never are.
function ItemRules.rankLocked(lastRank: string?, lastAt: number?, rank: any, now: number): boolean
	if type(rank) ~= "string" or rank == "" or rank ~= lastRank or lastAt == nil then
		return false
	end
	return now - lastAt < ItemRules.CUBES.rankLockSeconds
end

-- Distance from a vehicle to a pickup whose volume is a vertical capsule: the axis runs from the pickup up `lift`
-- studs. dy is the vehicle's height minus the pickup's. lift 0 is the plain sphere.
function ItemRules.liftedDistance(dx: number, dy: number, dz: number, lift: number): number
	local v = dy
	if v > lift then
		v -= lift
	elseif v > 0 then
		v = 0
	end
	return math.sqrt(dx * dx + v * v + dz * dz)
end

export type GhostSchedule = {
	colors: { string }, -- item colours (ItemRules.Color)
	ends: { number }, -- cumulative end time of each colour's dwell
	total: number,
}

-- One ghost cycle from roll weights (any positive scale): zero-weight colours never show; the rest in COLORS order.
function ItemRules.ghostSchedule(weights: { [string]: number }, period: number?, minDwell: number?): GhostSchedule
	local P = period or ItemRules.CUBES.ghostPeriod
	local floor = minDwell or ItemRules.CUBES.ghostMinDwell
	local sum = 0
	for _, c in ALL_ITEMS do
		sum += math.max(0, weights[c] or 0)
	end
	local colors: { string } = {}
	local ends: { number } = {}
	local t = 0
	if sum > 0 then
		for _, c in ALL_ITEMS do
			local w = math.max(0, weights[c] or 0)
			if w > 0 then
				t += math.max(floor, P * w / sum)
				table.insert(colors, c)
				table.insert(ends, t)
			end
		end
	end
	if #colors == 0 then
		colors = { COLORS[1] }
		ends = { P }
		t = P
	end
	return table.freeze({ colors = table.freeze(colors), ends = table.freeze(ends), total = t }) :: GhostSchedule
end

-- The ghost at time t (seconds on any clock): the colour showing, the one after it, and how far the cube colour has
-- crossfaded toward the next (0 for most of the dwell, rising to 1 over the last `fade` seconds). No allocation.
function ItemRules.ghostAt(s: GhostSchedule, t: number, fade: number?): (string, string, number)
	local f = fade or ItemRules.CUBES.ghostFade
	local n = #s.colors
	local u = t % s.total
	local i = 1
	while i < n and u >= s.ends[i] do
		i += 1
	end
	local nextC = s.colors[(i % n) + 1]
	local left = s.ends[i] - u
	local blend = if n > 1 and left < f then 1 - left / f else 0
	return s.colors[i], nextC, math.clamp(blend, 0, 1)
end

local ghostCache: { [string]: GhostSchedule } = {}

-- What a cube can honestly hint for this racer: holding an item, a cube only upgrades it (that one colour); empty
-- hands, the roll table of the racer's band (rank 1 = leading, of fieldSize). Cached; the result is frozen.
-- Items v4: poolKey is the race's ItemPool text (nil: the classic table); the ghosts show only what the race can roll.
-- v38: gapStuds as in rollBand (the client reads its own LeaderGap attribute), so the ghosts stay honest.
function ItemRules.ghostFor(rank: number, fieldSize: number, heldColor: string?, poolKey: string?, gapStuds: number?): GhostSchedule
	local key: string
	local weights: { [string]: number }
	if heldColor ~= nil and KIND_OF[heldColor :: Color] ~= nil then
		key = "held:" .. heldColor
		weights = { [heldColor] = 1 }
	else
		local band = ItemRules.rollBand(rank, fieldSize, gapStuds)
		if poolKey and poolKey ~= "" then
			key = band .. "|" .. poolKey
			weights = ItemRules.rollWeights(band :: any, ItemRules.parsePool(poolKey), nil)
		else
			key = band
			weights = (ItemRules.MYSTERY_WEIGHTS :: any)[band]
		end
	end
	local cached = ghostCache[key]
	if cached then
		return cached
	end
	local s = ItemRules.ghostSchedule(weights)
	ghostCache[key] = s
	return s
end

return ItemRules
