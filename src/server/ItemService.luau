--!strict
-- Server-authoritative race items for players and bots (LAUNCH_PROGRESSION section 4; rules in Shared.ItemRules).
-- Owns the held item per racer, a pod cooldown ledger, the ItemRemote ("Use" requests in; "ItemState", "ItemUsed",
-- "ItemEffect", "ItemFx" out) and the dispatch of item effects to injectable hooks. What an effect does in the world
-- (projectiles, traps, pull, speed) belongs to the hooks (live: server/kit/ItemEffects), so the Lune specs can stub it.
-- ItemService.new takes every Roblox dependency through World; only robloxWorld/start/ensureRemote touch instances.
--
-- PUBLIC API (stable; AIRacers and the race loop call only these). Racer ids are strings: playerRacerId(userId) ->
-- "player:<userId>", botRacerId(bot.id) -> "bot:<id>".
--   ItemService.pickup(racerId, podName) -> (ok, outcome|reason)   grant from a pod; the server re-checks distance
--       (PICKUP_RADIUS from the racer's live hull), pod cooldown and race phase. On success the pod-taken handler
--       runs (RaceManager registers it). Every pod is shared (cubes v3, owner: "Shared like Mario Kart, back for
--       everyone in 1.0 s"): one ready time per pod, so of two racers reaching a cube in the same frame exactly one gets
--       it (the other: "pod_cooldown"), and it is back for everyone RespawnSeconds later. A racer takes at most one cube
--       per rank of a staggered set (CubeRank, ItemRules.rankLocked): a second one is "same_rank" and stays standing.
--       Speed/Air pods return false, "not_item_pod" silently. Before start(): false, "not_started".
--       Item bugs audit (docs/audits/item_bugs.md): the reach test allows for the server's late view of a client-owned
--       hull (pickupInReach: the pod may lie ahead along the hull's velocity), and every player pickup answers its
--       client with "ItemPickup" {outcome | reason} so a capped upgrade or a lost race to the cube is shown, not silent.
--   ItemService.use(racerId) -> (ok, reason)    fire the held item (bots: the AI decides when). Players never call this;
--       their client sends one "Use" on the ItemRemote and the server runs the same path.
--   ItemService.getState(racerId) -> ItemRules.ItemState   copy of what the racer holds (bot AI reads it).
--   ItemService.isShielded(racerId) -> boolean
--   ItemService.reset()   clear every held item, shield and pod ledger (RaceManager calls it on race reset).
--   ItemService.setLevelOneOnly(enabled)   battle overlays (sections 2b and 4) on entry, false when the race returns.
--   ItemService.setArena(hooks | nil)   battle overlays: arena bots that AIRacers does not own (positions, effects) and
--       an extra act gate (eliminated entrants hold, fire and take nothing). server/battle/BattleCore sets and clears it.
-- Bot effects (what an item does TO a bot; AIRacers owns bot motion):
--   ItemService.setBotHitHandler(fn(botId, stunSeconds, source))   missile/trap hit on a bot ("missile" | "trap").
--   ItemService.setBotEffectHandler(fn(botId, effect: BotEffect))  boost / shield / magnet a bot fired itself.
--   ItemService.applyToBot(botId, effect)   the single entry ItemEffects calls. AIRacers may also replace it outright
--       (ItemService.applyToBot = function(botId, effect) ... end). With no handler registered the live fallback from
--       ItemEffects applies: a hit cuts the bot's baseSpeed for the stun, boost/magnet set its boostTimer.
-- Instance-level (ItemService.active, the running Service) keeps requestPickup/requestUse/handleRemote/getState/
-- isShielded/setLevelOneOnly/isLevelOneOnly/removeRacer/resetAll exactly as before.
-- REMARKABLE items 14 and 18 (information and feedback only; no rule, speed or validator changes):
--   ItemService.sendIncoming(racerId, payload)   kit/ItemEffects' 5 Hz missile ETA for a player: "IncomingItem"
--       {eta, homing, count} to that player's client (beeps), {eta = -1, dodged?} when the threat ends.
--   ItemService.noteHit(victim, attacker, source) -> (kind, chain)   every landed hit (kit/ItemEffects strike): the grudge
--       book (ItemRules.recordHit) says "hit", "revenge" (chain 1, 2, ...) or "self"; both players get "ItemGrudge"
--       {role, kind, chain, name (display name only), plane}; the victim's ItemState carries lastHitBy.
--   ItemService.setHitListener(fn(victim, attacker, kind, chain))   AIRacers' taunts react to hits on and by bots.
-- Missile v3 counterplay (shared/MissileRules; the server decides, the client only reports input):
--   ItemRemote "Roll"   a player's plane started a barrel roll; accepted at most once per MissileRules rollMinInterval.
--       ItemService.lastRoll(racerId) -> server time of the last accepted roll (kit/ItemEffects: the dodge window).
--   ItemRemote "Drag"   hold the item button with a trap: it trails behind the racer, still held (Hooks.dragTrap shows
--       it to everyone). The next "Use" drops it as before. ItemService.isDragging(racerId); ItemService.consumeDrag
--       (racerId) -> true when a dragged trap was there and has now eaten a missile (the trap is spent).
--
-- Items v4 (docs/design/ITEMS_V4.md): ItemService.setPool(pool | nil) at every race reset (RaceManager) sets the race's
-- item rotation; mystery rolls come from it (players and bots alike), with Storm Bolt held back on the final lap and
-- while one is held or out. Specials dispatch to Hooks.special. Charged items (Orbit Missiles, Gift Box) spend one
-- charge per Use and stay held; ItemService.absorbHit(racerId) lets an orbiter soak up a hit; ItemService.guard(racerId,
-- seconds) is the invulnerability of Rocket Rush, Golden Wings and Bubble Guard (isShielded).
--
-- Mystery cubes (race pods; ItemRules header): a pod whose PodInfo says mystery rolls the item here, weighted by the
-- racer's place (World.standing), or upgrades what the racer holds. A fresh roll is published with `roulette` seconds
-- and the racer cannot fire until they pass ("rolling"), so the HUD spin is not just decoration. Battle pods are not
-- mystery pods and keep the colour rules. Nothing here runs per frame: the roll happens once per pickup.
--
-- Rules kept from the first version: the service keeps its own per-pod ready time and ignores the OnCooldown attribute
-- (that attribute is the visual state, the ledger is the grant gate); Speed and Air pods are not items; nothing here is
-- saved (LAUNCH_PROGRESSION section 5); FlightController no longer boosts on Blue pods (the Blue item does).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local MissileRules = require(Shared:WaitForChild("MissileRules"))

local ItemService = {}

export type RacerId = string

export type PodInfo = {
	position: Vector3,
	podType: any, -- raw PodType attribute; ItemRules.classifyPod validates it
	respawnSeconds: number,
	mystery: boolean?, -- a race mystery cube (MysteryCube attribute): the colour is rolled, not read from podType
	cubeRank: string?, -- CubeRank attribute (cubes v3): "<set>#<rank>"; one cube per rank per pass
}

export type World = {
	now: () -> number,
	-- nil when the racer has no live vehicle (not spawned, left, between respawns)
	racerPosition: (racerId: RacerId) -> Vector3?,
	-- The racer's hull velocity as the server sees it (studs/s); nil -> the plain radius only (bots, the specs).
	racerVelocity: ((racerId: RacerId) -> Vector3?)?,
	findPod: (podName: string) -> PodInfo?,
	-- Called after every change of a racer's held item with a copy of the new state.
	publish: (racerId: RacerId, state: ItemRules.ItemState) -> (),
	log: (line: string) -> (),
	-- Race-phase gate (finished, countdown, crashed); nil allows everything. Returns ok and a short reason.
	canAct: ((racerId: RacerId) -> (boolean, string?))?,
	-- Item 18: a racer's display name (Player.DisplayName, a bot's roster name); nil -> the racer id.
	displayName: ((racerId: RacerId) -> string)?,
	-- Items 14 and 18: an extra client event for a player racer ("IncomingItem", "ItemGrudge"); bots ignore it.
	notify: ((racerId: RacerId, event: string, payload: { [string]: any }) -> ())?,
	-- Mystery cubes: the racer's place and the field size (1 = leading); nil -> treated as a field of one.
	standing: ((racerId: RacerId) -> (number, number, number?))?,
	-- Mystery cubes: a number in [0, 1); nil -> math.random. The specs pass a fixed sequence.
	random: (() -> number)?,
	-- Items v4 (Storm Bolt rarity): true while the racer is on the race's final lap; nil -> never.
	finalLap: ((racerId: RacerId) -> boolean)?,
}

export type Hooks = {
	applyBoost: (racerId: RacerId, params: ItemRules.BoostParams, level: number) -> (),
	spawnMissile: (racerId: RacerId, params: ItemRules.MissileParams, level: number) -> (),
	spawnTrap: (racerId: RacerId, params: ItemRules.TrapParams, level: number) -> (),
	setShield: (racerId: RacerId, params: ItemRules.ShieldParams, level: number) -> (),
	magnetPull: (racerId: RacerId, params: ItemRules.MagnetParams, level: number) -> (),
	-- Missile v3: a trap held behind the racer appears (on) or goes (off: dropped, spent or replaced). Optional.
	dragTrap: ((racerId: RacerId, on: boolean) -> ())?,
	-- Items v4: any of the nine specials (effect.kind is the special's id, params its ItemRules.SPECIAL level row).
	-- Optional: without it a special is consumed and logged only.
	special: ((racerId: RacerId, kind: string, params: { [string]: any }, level: number) -> ())?,
}

export type Options = {
	pickupRadius: number?,
	useMinInterval: number?,
	levelOneOnly: boolean?,
}

export type Service = {
	-- ok plus the ItemRules.PickupOutcome on a grant, or false plus a rejection reason.
	requestPickup: (racerId: RacerId, podName: any) -> (boolean, string),
	requestUse: (racerId: RacerId) -> (boolean, string, ItemRules.Effect?),
	-- Entry for client remote traffic: "Use", and the missile v3 counterplay "Drag" and "Roll".
	handleRemote: (racerId: RacerId, action: any) -> (boolean, string),
	getState: (racerId: RacerId) -> ItemRules.ItemState,
	isShielded: (racerId: RacerId) -> boolean,
	setLevelOneOnly: (enabled: boolean) -> (),
	isLevelOneOnly: () -> boolean,
	qaGive: (racerId: RacerId, color: string, level: number) -> (boolean, string),
	removeRacer: (racerId: RacerId) -> (),
	resetAll: () -> (),
	-- Item 18: records a landed hit in the grudge book and tells both players; returns ItemRules.HitKind and the chain.
	noteHit: (victim: RacerId, attacker: RacerId, source: string?) -> (string, number),
	-- Item 14: forwards one ETA update to a player's client.
	sendIncoming: (racerId: RacerId, payload: { [string]: any }) -> (),
	-- Missile v3 counterplay (see the header).
	requestDrag: (racerId: RacerId) -> (boolean, string),
	noteRoll: (racerId: RacerId) -> boolean,
	lastRoll: (racerId: RacerId) -> number?,
	isDragging: (racerId: RacerId) -> boolean,
	consumeDrag: (racerId: RacerId) -> boolean,
	-- Items v4 (see the header).
	setPool: (pool: { string }?) -> (),
	getPool: () -> { string }?,
	absorbHit: (racerId: RacerId) -> boolean,
	guard: (racerId: RacerId, seconds: number) -> (),
	-- v38 Item Steal: moves victim's held item (revealed, not mid-roulette) to thief; returns the label taken or nil.
	steal: (thief: RacerId, victim: RacerId) -> string?,
	-- v38: whether racerId holds a revealed item another racer could steal.
	holdsStealable: (racerId: RacerId) -> boolean,
}

-- OURS: the client trigger radius (PlaneConfig.PICKUP_TRIGGER_RADIUS 14) plus about 0.2 s of travel at overcharge speed
-- (210 studs/s). The server reads the hull position the client last synced, so a real pickup arrives up to that far
-- off; a forged pickup of a pod across the map does not.
ItemService.PICKUP_RADIUS = 60
-- Item bugs audit, root cause B: the server reads a client-owned hull late. Studio logs show granted pickups at 24-44
-- studs for a 10-stud client trigger in a car at road speed (0.2-0.35 s behind), and under a loaded 2-client Studio
-- the lag passes the 60 sphere at boost speed: the client popped the cube and the server said too_far. A pod that lies
-- within PICKUP_LEAD_SLACK of the line the hull is about to fly (velocity x PICKUP_LEAD_SECONDS ahead) is in reach too.
-- A forged claim still needs the hull pointed at the pod and inside 0.75 s of travel. OURS numbers.
ItemService.PICKUP_LEAD_SECONDS = 0.75
ItemService.PICKUP_LEAD_SLACK = 24
ItemService.PICKUP_LEAD_MAX_SPEED = 260 -- studs/s; a faster reported velocity is clamped (overcharge is 210)
-- OURS: one accepted use request per racer per 0.3 s; faster requests are rejected, never queued.
ItemService.USE_MIN_INTERVAL = 0.3
ItemService.REMOTE_NAME = "ItemRemote"
ItemService.REMOTES_FOLDER = "SkyRallyRemotes"
-- Rejections log at most once per racer per second; a spamming client must not flood the server log.
local REJECT_LOG_INTERVAL = 1.0
-- Pod names are instance names; anything longer is a forged payload.
local MAX_POD_NAME_LEN = 64

ItemService.active = nil :: Service?

-- Pure: whether a pod at podPos is in reach of a hull the server sees at pos moving at vel (nil: not known). Returns
-- the verdict, the plain distance and "radius" | "lead" (which test passed; "" when neither did).
function ItemService.pickupInReach(pos: Vector3, vel: Vector3?, podPos: Vector3, radius: number): (boolean, number, string)
	local dist = (pos - podPos).Magnitude
	if dist <= radius then
		return true, dist, "radius"
	end
	if vel then
		local speed = math.min(vel.Magnitude, ItemService.PICKUP_LEAD_MAX_SPEED)
		if speed > 1 then
			local ahead = pos + vel.Unit * (speed * ItemService.PICKUP_LEAD_SECONDS)
			local ab = ahead - pos
			local t = math.clamp((podPos - pos):Dot(ab) / ab:Dot(ab), 0, 1)
			if (podPos - (pos + ab * t)).Magnitude <= ItemService.PICKUP_LEAD_SLACK then
				return true, dist, "lead"
			end
		end
	end
	return false, dist, ""
end

-- What an item does to a bot, for AIRacers. kind "hit": seconds is the stun, source "missile" | "trap" (items v4 also
-- "storm" | "bomb" | "ram" | "frost_shot"). kind "slow" (items v4): seconds + factor (speed multiplier).
-- kind "boost": seconds + speed (studs/s). kind "shield": seconds. kind "magnet": seconds, pull (studs/s toward the
-- target), targetRacerId (the racer ahead it locked on).
export type BotEffect = {
	kind: string,
	seconds: number,
	source: string?,
	speed: number?,
	pull: number?,
	targetRacerId: RacerId?,
	attackerRacerId: RacerId?,
	level: number?,
	factor: number?, -- items v4: "slow" speed factor; a cruise-factor "boost"
}

-- Battle arena hooks (setArena). findBot: an arena bot by id with the fields the live world reads (hull, plane,
-- finished, station, lap). applyToBot: true when the arena owned that bot and applied the effect. canAct: false for
-- an entrant that is out of the battle (or everyone once it is over); also the "can be hit or targeted" gate.
export type ArenaHooks = {
	findBot: (botId: number) -> any,
	applyToBot: (botId: number, effect: BotEffect) -> boolean,
	canAct: (racerId: RacerId) -> (boolean, string?),
}

-- One battle arena per RaceScope scope (systems audit v32 T0-2: a group's battle never routes another group's hits
-- to its bots). The single path (and the hub scope per group) keeps the one slot it always had; enableScopes installs
-- arenaScoped for the instances.
local arenaSingle: { hooks: ArenaHooks? } = { hooks = nil }
local arenaScoped: (() -> { hooks: ArenaHooks? })? = nil
local function arenaBox(): { hooks: ArenaHooks? }
	local scoped = arenaScoped
	if scoped then
		return scoped()
	end
	return arenaSingle
end

function ItemService.setArena(hooks: ArenaHooks?)
	arenaBox().hooks = hooks
end

function ItemService.arena(): ArenaHooks?
	return arenaBox().hooks
end

local botHitHandler: ((botId: number, stunSeconds: number, source: string) -> ())? = nil
local botEffectHandler: ((botId: number, effect: BotEffect) -> ())? = nil
local botFallback: ((botId: number, effect: BotEffect) -> ())? = nil
local podTakenHandler: ((podName: string, racerId: RacerId) -> ())? = nil

function ItemService.setBotHitHandler(fn: ((botId: number, stunSeconds: number, source: string) -> ())?)
	botHitHandler = fn
end

function ItemService.setBotEffectHandler(fn: ((botId: number, effect: BotEffect) -> ())?)
	botEffectHandler = fn
end

-- Live fallback for bots until AIRacers registers handlers (ItemEffects.start installs it).
function ItemService.setBotFallback(fn: ((botId: number, effect: BotEffect) -> ())?)
	botFallback = fn
end

function ItemService.setPodTakenHandler(fn: ((podName: string, racerId: RacerId) -> ())?)
	podTakenHandler = fn
end

-- Item 18/19: who hears about landed hits (AIRacers' taunts). One listener; a later call replaces it.
local hitListener: ((victim: RacerId, attacker: RacerId, kind: string, chain: number) -> ())? = nil

function ItemService.setHitListener(fn: ((victim: RacerId, attacker: RacerId, kind: string, chain: number) -> ())?)
	hitListener = fn
end

-- kit/ItemEffects calls this for every landed hit ("hit" result, not blocks or immune passes). Returns the grudge kind
-- ("hit" | "revenge" | "self") and chain; "hit", 0 before start().
function ItemService.noteHit(victim: RacerId, attacker: RacerId, source: string?): (string, number)
	local svc = ItemService.active
	if not svc then
		return "hit", 0
	end
	local kind, chain = svc.noteHit(victim, attacker, source)
	local listener = hitListener
	if listener then
		local ok, err = pcall(function()
			listener(victim, attacker, kind, chain)
		end)
		if not ok then
			print(string.format("[SkyRally][ITEM] hit listener error victim=%s err=%s", victim, tostring(err)))
		end
	end
	return kind, chain
end

-- Item 14: one missile ETA update for a player (kit/ItemEffects, 5 Hz while a shot is on its way).
function ItemService.sendIncoming(racerId: RacerId, payload: { [string]: any })
	local svc = ItemService.active
	if svc then
		svc.sendIncoming(racerId, payload)
	end
end

-- Routes one effect to the registered bot handler, else the fallback. Returns true when something handled it.
-- A handler error is logged and swallowed: one broken bot must not stop the effect loop for everyone else.
local function defaultApplyToBot(botId: number, effect: BotEffect): boolean
	local ok, err = pcall(function()
		local arena = arenaBox().hooks
		local hit, any, fallback = botHitHandler, botEffectHandler, botFallback
		if arena and arena.applyToBot(botId, effect) then
			-- a battle arena bot (BattleBots): applied there
		elseif effect.kind == "hit" and hit then
			hit(botId, effect.seconds, effect.source or "item")
		elseif any then
			any(botId, effect)
		elseif fallback then
			fallback(botId, effect)
		else
			error("no bot handler")
		end
	end)
	if not ok then
		print(string.format("[SkyRally][ITEM] bot effect not applied bot=%d kind=%s err=%s", botId, effect.kind, tostring(err)))
	end
	return ok
end

-- Replaceable field (see the header); ItemEffects always calls it through the module so a replacement takes effect.
ItemService.applyToBot = defaultApplyToBot :: (botId: number, effect: BotEffect) -> boolean

function ItemService.pickup(racerId: RacerId, podName: any): (boolean, string)
	local svc = ItemService.active
	if not svc then
		return false, "not_started"
	end
	local ok, outcome = svc.requestPickup(racerId, podName)
	local onTaken = podTakenHandler
	if ok and onTaken and type(podName) == "string" then
		local okHandler, err = pcall(function()
			onTaken(podName, racerId)
		end)
		if not okHandler then
			print(string.format("[SkyRally][ITEM] pod-taken handler error pod=%s err=%s", podName, tostring(err)))
		end
	end
	return ok, outcome
end

function ItemService.use(racerId: RacerId): (boolean, string)
	local svc = ItemService.active
	if not svc then
		return false, "not_started"
	end
	local ok, reason = svc.requestUse(racerId)
	return ok, reason
end

-- Studio QA: the player holds `color` at `level` (server/QATools). Refused outside Studio whatever the caller; routed to
-- the service of the instance the player is seated in when scopes are on.
ItemService.isStudio = function(): boolean
	local ok, v = pcall(function(): boolean
		return game:GetService("RunService"):IsStudio()
	end)
	return ok and v == true
end
ItemService.routeRun = nil :: ((player: Player, fn: (Service) -> ()) -> ())?
function ItemService.qaGive(player: Player, color: string, level: number): (boolean, string)
	if not ItemService.isStudio() then
		return false, "not_studio"
	end
	local result: { boolean | string } = { false, "not_started" }
	local function run(svc: Service)
		local ok, why = svc.qaGive(ItemService.playerRacerId(player.UserId), color, level)
		result = { ok, why }
	end
	local route = ItemService.routeRun
	if route then
		route(player, run)
	else
		local svc = ItemService.active
		if svc then
			run(svc)
		end
	end
	return result[1] :: boolean, result[2] :: string
end

-- v38 Studio QA (server/QATools "botuse"): a bot of the player's instance holds `color` at `level`, then uses it. So
-- every item can be tested by BEING hit by it, not only by firing it.
function ItemService.qaBotUse(player: Player, racerId: RacerId, color: string, level: number): (boolean, string)
	if not ItemService.isStudio() then
		return false, "not_studio"
	end
	local result: { boolean | string } = { false, "not_started" }
	local function run(svc: Service)
		local ok, why = svc.qaGive(racerId, color, level)
		if ok then
			ok, why = svc.requestUse(racerId)
		end
		result = { ok, why }
	end
	local route = ItemService.routeRun
	if route then
		route(player, run)
	else
		local svc = ItemService.active
		if svc then
			run(svc)
		end
	end
	return result[1] :: boolean, result[2] :: string
end

function ItemService.getState(racerId: RacerId): ItemRules.ItemState
	local svc = ItemService.active
	return if svc then svc.getState(racerId) else ItemRules.newState()
end

function ItemService.isShielded(racerId: RacerId): boolean
	local svc = ItemService.active
	return svc ~= nil and svc.isShielded(racerId)
end

function ItemService.lastRoll(racerId: RacerId): number?
	local svc = ItemService.active
	return if svc then svc.lastRoll(racerId) else nil
end

function ItemService.isDragging(racerId: RacerId): boolean
	local svc = ItemService.active
	return svc ~= nil and svc.isDragging(racerId)
end

function ItemService.consumeDrag(racerId: RacerId): boolean
	local svc = ItemService.active
	return svc ~= nil and svc.consumeDrag(racerId)
end

-- Items v4: this race's rotation pool (RaceManager at the reset; nil = classic), and the effects' entry points.
function ItemService.setPool(pool: { string }?)
	local svc = ItemService.active
	if svc then
		svc.setPool(pool)
	end
end

function ItemService.getPool(): { string }?
	local svc = ItemService.active
	return if svc then svc.getPool() else nil
end

function ItemService.absorbHit(racerId: RacerId): boolean
	local svc = ItemService.active
	return svc ~= nil and svc.absorbHit(racerId)
end

function ItemService.steal(thief: RacerId, victim: RacerId): string?
	local svc = ItemService.active
	return if svc then svc.steal(thief, victim) else nil
end

function ItemService.holdsStealable(racerId: RacerId): boolean
	local svc = ItemService.active
	return svc ~= nil and svc.holdsStealable(racerId)
end

function ItemService.guard(racerId: RacerId, seconds: number)
	local svc = ItemService.active
	if svc then
		svc.guard(racerId, seconds)
	end
end

function ItemService.reset()
	local svc = ItemService.active
	if svc then
		svc.resetAll()
	end
end

function ItemService.setLevelOneOnly(enabled: boolean)
	local svc = ItemService.active
	if svc then
		svc.setLevelOneOnly(enabled)
	end
end

function ItemService.playerRacerId(userId: number): RacerId
	return "player:" .. tostring(userId)
end

function ItemService.botRacerId(botId: number): RacerId
	return "bot:" .. tostring(botId)
end

-- Returns ("player" | "bot", number) or nil for a malformed id.
function ItemService.parseRacerId(racerId: RacerId): (string?, number?)
	local kind, num = string.match(racerId, "^(%a+):(%-?%d+)$")
	if kind ~= "player" and kind ~= "bot" then
		return nil, nil
	end
	return kind, tonumber(num)
end

local function copyState(state: ItemRules.ItemState): ItemRules.ItemState
	return { color = state.color, level = state.level, charges = state.charges }
end

-- Stub hooks for a service started before the race loop supplies real effects: the use is still validated, consumed
-- and logged, so the remote path can be proven on its own.
function ItemService.loggingHooks(log: (string) -> ()): Hooks
	local function stub(name: string): (RacerId, any, number) -> ()
		return function(racerId: RacerId, _params: any, level: number)
			log(string.format("[SkyRally][ITEM] hook %s not wired racer=%s level=%d", name, racerId, level))
		end
	end
	return {
		applyBoost = stub("applyBoost"),
		spawnMissile = stub("spawnMissile"),
		spawnTrap = stub("spawnTrap"),
		setShield = stub("setShield"),
		magnetPull = stub("magnetPull"),
		special = function(racerId: RacerId, kind: string, _params: any, level: number)
			log(string.format("[SkyRally][ITEM] hook special not wired racer=%s kind=%s level=%d", racerId, kind, level))
		end,
	}
end

function ItemService.new(world: World, hooks: Hooks, options: Options?): Service
	local opts: Options = options or {}
	local pickupRadius = opts.pickupRadius or ItemService.PICKUP_RADIUS
	local useMinInterval = opts.useMinInterval or ItemService.USE_MIN_INTERVAL
	local levelOneOnly = opts.levelOneOnly == true

	local states: { [RacerId]: ItemRules.ItemState } = {}
	local lastUseAt: { [RacerId]: number } = {}
	local shieldUntil: { [RacerId]: number } = {}
	local lastRejectLogAt: { [RacerId]: number } = {}
	local suppressedRejects: { [RacerId]: number } = {}
	local podReadyAt: { [string]: number } = {} -- pod -> ready time, for every racer (cubes v3: shared)
	local lastRank: { [RacerId]: string } = {} -- the CubeRank of the racer's last cube, and when (rank lock)
	local lastRankAt: { [RacerId]: number } = {}
	local rollingUntil: { [RacerId]: number } = {} -- mystery roulette: no use before this time
	local grudges: ItemRules.GrudgeBook = ItemRules.newGrudgeBook() -- item 18
	local dragging: { [RacerId]: boolean } = {} -- missile v3: a held trap trailing behind the racer
	local rolledAt: { [RacerId]: number } = {} -- missile v3: last accepted barrel roll (server time)
	local pool: { string }? = nil -- items v4: this race's rotation (setPool); nil = the classic colours
	local stormUntil = -math.huge -- items v4: a Storm Bolt is out until then (one at a time)

	local function stateOf(racerId: RacerId): ItemRules.ItemState
		return states[racerId] or ItemRules.newState()
	end

	-- A copy for the outside world, with the open grudge (item 18) folded in.
	local function snapshot(racerId: RacerId, state: ItemRules.ItemState): ItemRules.ItemState
		local out = copyState(state)
		local g = ItemRules.grudgeOf(grudges, racerId, world.now())
		if g then
			out.lastHitBy = g.by
		end
		return out
	end

	local function setDrag(racerId: RacerId, on: boolean)
		if (dragging[racerId] == true) == on then
			return
		end
		if on then
			dragging[racerId] = true
		else
			dragging[racerId] = nil
		end
		local show = hooks.dragTrap
		if show then
			local ok, err = pcall(function()
				show(racerId, on)
			end)
			if not ok then
				world.log(string.format("[SkyRally][ITEM] drag hook error racer=%s err=%s", racerId, tostring(err)))
			end
		end
	end

	local function setState(racerId: RacerId, state: ItemRules.ItemState, roulette: number?)
		states[racerId] = state
		if dragging[racerId] and (state.color ~= "green" or state.level <= 0) then
			setDrag(racerId, false) -- the dragged trap was used, spent or replaced
		end
		local ok, err = pcall(function()
			local out = snapshot(racerId, state)
			out.roulette = roulette
			world.publish(racerId, out)
		end)
		if not ok then
			world.log(string.format("[SkyRally][ITEM] publish failed racer=%s err=%s", racerId, tostring(err)))
		end
	end

	local function logReject(racerId: RacerId, what: string, reason: string, detail: string?)
		local now = world.now()
		local last = lastRejectLogAt[racerId]
		if last and now - last < REJECT_LOG_INTERVAL then
			suppressedRejects[racerId] = (suppressedRejects[racerId] or 0) + 1
			return
		end
		lastRejectLogAt[racerId] = now
		local suppressed = suppressedRejects[racerId] or 0
		suppressedRejects[racerId] = nil
		world.log(string.format(
			"[SkyRally][ITEM] reject %s racer=%s reason=%s%s%s",
			what,
			racerId,
			reason,
			if detail then " " .. detail else "",
			if suppressed > 0 then string.format(" (+%d suppressed)", suppressed) else ""
		))
	end

	local function gate(racerId: RacerId): (boolean, string)
		local canAct = world.canAct
		if not canAct then
			return true, ""
		end
		local ok, why = canAct(racerId)
		if ok then
			return true, ""
		end
		return false, "blocked:" .. (why or "phase")
	end

	local function dispatch(racerId: RacerId, effect: ItemRules.Effect)
		local ok, err = pcall(function()
			local missile, boost, shield, trap, magnet = effect.missile, effect.boost, effect.shield, effect.trap, effect.magnet
			local special = effect.special
			if special then
				local hook = hooks.special
				if hook then
					hook(racerId, effect.kind, special, effect.level)
				else
					world.log(string.format("[SkyRally][ITEM] special not wired racer=%s kind=%s", racerId, effect.kind))
				end
			elseif missile then
				hooks.spawnMissile(racerId, missile, effect.level)
			elseif boost then
				hooks.applyBoost(racerId, boost, effect.level)
			elseif shield then
				hooks.setShield(racerId, shield, effect.level)
			elseif trap then
				hooks.spawnTrap(racerId, trap, effect.level)
			elseif magnet then
				hooks.magnetPull(racerId, magnet, effect.level)
			end
		end)
		if not ok then
			-- The item stays consumed: re-granting on a hook fault would let a broken effect be fired forever.
			world.log(string.format("[SkyRally][ITEM] hook error racer=%s kind=%s err=%s", racerId, effect.kind, tostring(err)))
		end
	end

	local function nameOf(racerId: RacerId): string
		local fn = world.displayName
		if fn then
			local ok, name = pcall(fn, racerId)
			if ok and type(name) == "string" and name ~= "" then
				return name
			end
		end
		return racerId
	end

	local function tell(racerId: RacerId, event: string, payload: { [string]: any })
		local notify = world.notify
		if not notify or string.sub(racerId, 1, 7) ~= "player:" then
			return
		end
		local ok, err = pcall(function()
			notify(racerId, event, payload)
		end)
		if not ok then
			world.log(string.format("[SkyRally][ITEM] notify failed racer=%s event=%s err=%s", racerId, event, tostring(err)))
		end
	end

	-- Items v4: ids a roll may not give this racer now (Storm Bolt: one out at a time, none on the final lap).
	local function rollBlocked(racerId: RacerId, now: number): { [string]: boolean }?
		if not pool or not table.find(pool, "storm_bolt") then
			return nil
		end
		local out = now < stormUntil
		if not out then
			for _, st in states do
				if st.color == "storm_bolt" and st.level > 0 then
					out = true
					break
				end
			end
		end
		local finalFn = world.finalLap
		local final = false
		if finalFn then
			local okF, v = pcall(finalFn, racerId)
			final = okF and v == true
		end
		if ItemRules.stormAllowed(final, out) then
			return nil
		end
		return { storm_bolt = true }
	end

	local service = {} :: Service

	function service.requestPickup(racerId: RacerId, podName: any): (boolean, string)
		-- Builders never put control characters in pod names; a forged name with a newline would otherwise print a
		-- second, fake "[SkyRally][ITEM]" line into the log the gate reads.
		if type(podName) ~= "string" or #podName == 0 or #podName > MAX_POD_NAME_LEN or string.find(podName, "%c") then
			logReject(racerId, "pickup", "bad_pod_name")
			return false, "bad_pod_name"
		end
		local pod = world.findPod(podName)
		if not pod then
			logReject(racerId, "pickup", "unknown_pod", "pod=" .. podName)
			return false, "unknown_pod"
		end
		local podClass: ItemRules.PodClass, podColor: ItemRules.Color? = ItemRules.classifyPod(pod.podType)
		if podClass == "unknown" then
			logReject(racerId, "pickup", "unknown_pod_type", "pod=" .. podName .. " type=" .. tostring(pod.podType))
			return false, "unknown_pod_type"
		elseif podClass ~= "item" or podColor == nil then
			-- Speed/Air pods reach here on every pass once wired; they belong to other paths, so this is not a reject.
			return false, "not_item_pod"
		end
		local allowed, why = gate(racerId)
		if not allowed then
			logReject(racerId, "pickup", why, "pod=" .. podName)
			tell(racerId, "ItemPickup", { reason = why })
			return false, why
		end
		local pos = world.racerPosition(racerId)
		if not pos then
			logReject(racerId, "pickup", "no_vehicle", "pod=" .. podName)
			tell(racerId, "ItemPickup", { reason = "no_vehicle" })
			return false, "no_vehicle"
		end
		local velFn = world.racerVelocity
		local vel: Vector3? = nil
		if velFn then
			local okVel, v = pcall(velFn, racerId)
			if okVel and typeof(v) == "Vector3" then
				vel = v
			end
		end
		local inReach, dist, reach = ItemService.pickupInReach(pos, vel, pod.position, pickupRadius)
		if not inReach then
			logReject(racerId, "pickup", "too_far", string.format("pod=%s dist=%.1f max=%.1f speed=%.0f", podName, dist, pickupRadius, if vel then vel.Magnitude else 0))
			tell(racerId, "ItemPickup", { reason = "too_far" })
			return false, "too_far"
		end
		local now = world.now()
		local readyAt = podReadyAt[podName]
		if readyAt and now < readyAt then
			logReject(racerId, "pickup", "pod_cooldown", string.format("pod=%s ready_in=%.2f", podName, readyAt - now))
			tell(racerId, "ItemPickup", { reason = "pod_cooldown" })
			return false, "pod_cooldown"
		end
		-- Normal play, not a reject worth a log line: the client (and a bot's single call per crossing) brushed a second
		-- cube of the rank it just took. The cube stays up for whoever comes next.
		local cubeRank = pod.cubeRank
		if ItemRules.rankLocked(lastRank[racerId], lastRankAt[racerId], cubeRank, now) then
			return false, "same_rank"
		end

		podReadyAt[podName] = now + math.max(0, pod.respawnSeconds)
		if type(cubeRank) == "string" and cubeRank ~= "" then
			lastRank[racerId] = cubeRank
			lastRankAt[racerId] = now
		end
		local before = stateOf(racerId)
		if pod.mystery == true then
			local rank, field, gap = 1, 1, 0
			local held = before.color
			local rolled: ItemRules.Color
			if held ~= nil and before.level > 0 then
				rolled = held :: ItemRules.Color -- an upgrade: nothing to roll
			else
				local standing = world.standing
				if standing then
					local okRank, r, n, g = pcall(standing, racerId)
					if okRank and type(r) == "number" and type(n) == "number" then
						rank, field = r, n
						gap = if type(g) == "number" then g else 0
					end
				end
				local rand = world.random
				rolled = ItemRules.rollMystery(rank, field, if rand then rand() else math.random(), pool, rollBlocked(racerId, now), gap)
			end
			-- A second cube while the first one's roulette still spins queues its level-up for the reveal
			-- (ItemRules.cubeTake): the HUD keeps spinning for what is left; the use gate stays at the same reveal.
			local rolling = rollingUntil[racerId]
			local after, outcome, roulette = ItemRules.cubeTake(before, rolled, if rolling then rolling - now else nil, levelOneOnly)
			if outcome == "new" and roulette then
				rollingUntil[racerId] = now + roulette
			end
			setState(racerId, after, roulette)
			tell(racerId, "ItemPickup", { outcome = outcome, color = after.color, level = after.level })
			world.log(string.format(
				"[SkyRally][ITEM] pickup racer=%s pod=%s mystery place=%d/%d band=%s gap=%.0f %s->%s outcome=%s dist=%.1f%s",
				racerId,
				podName,
				rank,
				field,
				ItemRules.rollBand(rank, field, gap),
				math.min(gap, 99999),
				ItemRules.label(before),
				ItemRules.label(after),
				outcome,
				dist,
				if reach == "lead" then " reach=lead" else ""
			))
			return true, outcome
		end
		local after, outcome = ItemRules.pickup(before, podColor, levelOneOnly)
		setState(racerId, after)
		tell(racerId, "ItemPickup", { outcome = outcome, color = after.color, level = after.level })
		world.log(string.format(
			"[SkyRally][ITEM] pickup racer=%s pod=%s color=%s %s->%s outcome=%s dist=%.1f%s",
			racerId,
			podName,
			podColor,
			ItemRules.label(before),
			ItemRules.label(after),
			outcome,
			dist,
			if reach == "lead" then " reach=lead" else ""
		))
		return true, outcome
	end

	function service.requestUse(racerId: RacerId): (boolean, string, ItemRules.Effect?)
		local now = world.now()
		local last = lastUseAt[racerId]
		if last and now - last < useMinInterval then
			logReject(racerId, "use", "rate_limited")
			return false, "rate_limited", nil
		end
		lastUseAt[racerId] = now

		local allowed, why = gate(racerId)
		if not allowed then
			logReject(racerId, "use", why)
			return false, why, nil
		end
		local held = stateOf(racerId)
		if not ItemRules.isHolding(held) then
			logReject(racerId, "use", "nothing_held")
			return false, "nothing_held", nil
		end
		local rolling = rollingUntil[racerId]
		if rolling and now < rolling then
			logReject(racerId, "use", "rolling", string.format("left=%.2f", rolling - now))
			return false, "rolling", nil
		end
		rollingUntil[racerId] = nil

		local after, effect = ItemRules.use(held)
		if not effect then
			return false, "nothing_held", nil
		end
		setState(racerId, after)
		local shield = effect.shield
		if shield then
			-- Never shortens a running guard (Rocket Rush, Golden Wings, Bubble Guard) or a longer shield.
			shieldUntil[racerId] = math.max(shieldUntil[racerId] or -math.huge, now + shield.seconds)
		end
		if effect.kind == "storm_bolt" and effect.special then
			local sp = effect.special
			stormUntil = now + (sp.travel or 4) * (if sp.chain then 2 else 1) + 1
		end
		world.log(string.format(
			"[SkyRally][ITEM] use racer=%s item=%s kind=%s%s",
			racerId,
			ItemRules.label(held),
			effect.kind,
			(if effect.missile then string.format(" count=%d homing=%s", effect.missile.count, tostring(effect.missile.homing)) else "")
				.. (if effect.gift then " gift=" .. effect.color else "")
				.. (if after.charges then string.format(" left=%d", after.charges) else "")
		))
		dispatch(racerId, effect)
		return true, "used", effect
	end

	function service.requestDrag(racerId: RacerId): (boolean, string)
		local allowed, why = gate(racerId)
		if not allowed then
			logReject(racerId, "drag", why)
			return false, why
		end
		local held = stateOf(racerId)
		if held.color ~= "green" or held.level <= 0 then
			logReject(racerId, "drag", "not_trap")
			return false, "not_trap"
		end
		local rolling = rollingUntil[racerId]
		if rolling and world.now() < rolling then
			logReject(racerId, "drag", "rolling")
			return false, "rolling"
		end
		if dragging[racerId] then
			return true, "dragging"
		end
		setDrag(racerId, true)
		world.log(string.format("[SkyRally][ITEM] drag racer=%s item=%s", racerId, ItemRules.label(held)))
		return true, "dragging"
	end

	function service.noteRoll(racerId: RacerId): boolean
		local now = world.now()
		if not MissileRules.acceptRoll(now, rolledAt[racerId]) then
			return false
		end
		rolledAt[racerId] = now
		return true
	end

	function service.lastRoll(racerId: RacerId): number?
		return rolledAt[racerId]
	end

	function service.isDragging(racerId: RacerId): boolean
		return dragging[racerId] == true
	end

	function service.consumeDrag(racerId: RacerId): boolean
		if not dragging[racerId] then
			return false
		end
		local held = stateOf(racerId)
		if held.color ~= "green" or held.level <= 0 then
			setDrag(racerId, false)
			return false
		end
		setState(racerId, ItemRules.newState()) -- also ends the drag
		world.log(string.format("[SkyRally][ITEM] drag spent racer=%s item=%s", racerId, ItemRules.label(held)))
		return true
	end

	function service.handleRemote(racerId: RacerId, action: any): (boolean, string)
		if action == "Drag" then
			return service.requestDrag(racerId)
		elseif action == "Roll" then
			return service.noteRoll(racerId), "roll"
		end
		if action ~= "Use" then
			local shown = string.gsub(string.sub(tostring(action), 1, 24), "%c", "?")
			logReject(racerId, "remote", "bad_action", "action=" .. shown)
			return false, "bad_action"
		end
		local ok, reason = service.requestUse(racerId)
		return ok, reason
	end

	function service.getState(racerId: RacerId): ItemRules.ItemState
		return snapshot(racerId, stateOf(racerId))
	end

	function service.noteHit(victim: RacerId, attacker: RacerId, source: string?): (string, number)
		local kind, chain = ItemRules.recordHit(grudges, victim, attacker, world.now())
		if kind == "self" then
			tell(victim, "ItemGrudge", { role = "self", kind = kind, chain = 0, source = source })
		else
			-- Display names only (never the account name); the client shortens them for the plank.
			tell(attacker, "ItemGrudge", { role = "attacker", kind = kind, chain = chain, name = nameOf(victim), other = victim, source = source })
			tell(victim, "ItemGrudge", { role = "victim", kind = kind, chain = chain, name = nameOf(attacker), other = attacker, source = source })
		end
		world.log(string.format("[SkyRally][ITEM] grudge victim=%s by=%s kind=%s chain=%d", victim, attacker, kind, chain))
		return kind, chain
	end

	function service.sendIncoming(racerId: RacerId, payload: { [string]: any })
		tell(racerId, "IncomingItem", payload)
	end

	function service.setPool(newPool: { string }?)
		pool = if newPool then table.clone(newPool) else nil
		world.log(string.format("[SkyRally][ITEM] pool=%s", if pool then ItemRules.poolText(pool) else "classic"))
	end

	function service.getPool(): { string }?
		return pool
	end

	-- An orbiter of a held Orbit Missiles soaks up one hit (kit/ItemEffects strike asks before the shield). Not while
	-- the roulette still spins: the ring shows only once the item is revealed.
	function service.absorbHit(racerId: RacerId): boolean
		local held = stateOf(racerId)
		local rolling = rollingUntil[racerId]
		if rolling and world.now() < rolling then
			return false
		end
		local after, absorbed = ItemRules.absorbHit(held)
		if absorbed then
			setState(racerId, after)
			world.log(string.format("[SkyRally][ITEM] orbit absorb racer=%s left=%s", racerId, tostring(after.charges or 0)))
		end
		return absorbed
	end

	function service.holdsStealable(racerId: RacerId): boolean
		local held = stateOf(racerId)
		local rolling = rollingUntil[racerId]
		return ItemRules.isHolding(held) and not (rolling and world.now() < rolling)
	end

	-- v38 Item Steal (ItemEffects hooks.special "item_steal"): the victim's whole held item (level and charges) goes to
	-- the thief, replacing whatever the thief holds; the victim is told who took it.
	function service.steal(thief: RacerId, victim: RacerId): string?
		if thief == victim or not service.holdsStealable(victim) then
			return nil
		end
		local held = stateOf(victim)
		local taken: ItemRules.ItemState = { color = held.color, level = held.level, charges = held.charges }
		setState(victim, ItemRules.newState())
		setState(thief, taken)
		tell(victim, "ItemGrudge", { role = "robbed", kind = "steal", chain = 0, name = nameOf(thief), other = thief, item = taken.color })
		tell(thief, "ItemGrudge", { role = "thief", kind = "steal", chain = 0, name = nameOf(victim), other = victim, item = taken.color })
		world.log(string.format("[SkyRally][ITEM] steal thief=%s victim=%s item=%s", thief, victim, ItemRules.label(taken)))
		return ItemRules.label(taken)
	end

	-- Invulnerability from a special (Rocket Rush, Golden Wings, Bubble Guard): isShielded for `seconds` from now
	-- (never shortens a running one).
	function service.guard(racerId: RacerId, seconds: number)
		local untilT = world.now() + math.max(0, seconds)
		if (shieldUntil[racerId] or -math.huge) < untilT then
			shieldUntil[racerId] = untilT
		end
	end

	function service.isShielded(racerId: RacerId): boolean
		local untilT = shieldUntil[racerId]
		return untilT ~= nil and world.now() < untilT
	end

	function service.setLevelOneOnly(enabled: boolean)
		if levelOneOnly == enabled then
			return
		end
		levelOneOnly = enabled
		if enabled then
			-- An item upgraded in the race before the switch must not carry level two or three into a battle.
			for racerId, state in pairs(states) do
				if state.level > ItemRules.BATTLE_MAX_LEVEL then
					setState(racerId, { color = state.color, level = ItemRules.BATTLE_MAX_LEVEL })
				end
			end
		end
		world.log(string.format("[SkyRally][ITEM] levelOneOnly=%s", tostring(enabled)))
	end

	function service.isLevelOneOnly(): boolean
		return levelOneOnly
	end

	-- Studio QA only (server/QATools, behind RunService:IsStudio()): the racer holds `color` at `level` now, as a pickup
	-- would have left it. Level is clamped to the mode's cap; nothing else (rolls, pods, cooldowns) is touched.
	function service.qaGive(racerId: RacerId, color: string, level: number): (boolean, string)
		if not ItemRules.isColor(color) then
			return false, "unknown_color"
		end
		local lv = math.clamp(math.floor(level), 1, ItemRules.maxLevel(levelOneOnly))
		rollingUntil[racerId] = nil
		setState(racerId, ItemRules.held(color :: ItemRules.Color, lv))
		world.log(string.format("[SkyRally][ITEM] qa give racer=%s item=%s:%d", racerId, color, lv))
		return true, "ok"
	end

	function service.removeRacer(racerId: RacerId)
		states[racerId] = nil
		lastUseAt[racerId] = nil
		shieldUntil[racerId] = nil
		rollingUntil[racerId] = nil
		lastRejectLogAt[racerId] = nil
		suppressedRejects[racerId] = nil
		grudges[racerId] = nil
		dragging[racerId] = nil
		rolledAt[racerId] = nil
		lastRank[racerId] = nil
		lastRankAt[racerId] = nil
	end

	function service.resetAll()
		local cleared = 0
		for racerId, state in pairs(states) do
			if ItemRules.isHolding(state) then
				cleared += 1
				setState(racerId, ItemRules.newState())
			end
		end
		table.clear(states)
		table.clear(lastUseAt)
		table.clear(shieldUntil)
		table.clear(podReadyAt)
		table.clear(lastRank)
		table.clear(lastRankAt)
		table.clear(rollingUntil)
		table.clear(grudges)
		for racerId in dragging do
			setDrag(racerId, false)
		end
		table.clear(rolledAt)
		stormUntil = -math.huge
		world.log(string.format("[SkyRally][ITEM] reset cleared=%d levelOneOnly=%s", cleared, tostring(levelOneOnly)))
	end

	return service
end

-- Live World: positions from FlightServer records and AIRacers bots, pods from the active track's Boosts folder, state
-- to the owning client through the remote plus ItemColor/ItemLevel attributes (on the bot's plane for bots).
-- Modules are required here, not at the top, so the pure service loads under Lune without the race modules.
function ItemService.robloxWorld(remote: RemoteEvent): World
	local FlightServer = require(script.Parent.FlightServer)
	local AIRacers = require(script.Parent.AIRacers)
	local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
	local SplineUtils = require(Shared:WaitForChild("SplineUtils")) :: any

	-- Race bots, then the battle arena's bots (ids never overlap; both expose hull, plane, finished).
	local function findBot(botId: number): any
		for _, bot in ipairs(AIRacers.bots) do
			if bot.id == botId then
				return bot
			end
		end
		local arena = arenaBox().hooks
		return if arena then arena.findBot(botId) else nil
	end

	local function findPlayer(userId: number): Player?
		return Players:GetPlayerByUserId(userId)
	end

	local world: World = {
		now = os.clock,
		log = function(line: string)
			print(line)
		end,
		racerPosition = function(racerId: RacerId): Vector3?
			local kind, num = ItemService.parseRacerId(racerId)
			if not num then
				return nil
			end
			if kind == "player" then
				local player = findPlayer(num)
				local rec = if player then FlightServer.records[player] else nil
				if rec and rec.hull and rec.hull.Parent then
					return rec.hull.Position
				end
			elseif kind == "bot" then
				local bot = findBot(num)
				if bot and bot.hull and bot.hull.Parent then
					return bot.hull.Position
				end
			end
			return nil
		end,
		-- Root cause B (item bugs audit): the hull's replicated velocity, so pickupInReach can allow for the lag.
		racerVelocity = function(racerId: RacerId): Vector3?
			local kind, num = ItemService.parseRacerId(racerId)
			if kind ~= "player" or not num then
				return nil
			end
			local player = findPlayer(num)
			local rec = if player then FlightServer.records[player] else nil
			if rec and rec.hull and rec.hull.Parent then
				return rec.hull.AssemblyLinearVelocity
			end
			return nil
		end,
		findPod = function(podName: string): PodInfo?
			local boosts = TrackRegistry.getBoostsFolder()
			local pod = if boosts then boosts:FindFirstChild(podName) else nil
			if not pod or not pod:IsA("BasePart") or pod:GetAttribute("ItemPodSpawn") ~= true then
				return nil
			end
			local respawn = pod:GetAttribute("RespawnSeconds")
			local rank = pod:GetAttribute("CubeRank")
			return {
				position = pod.Position,
				podType = pod:GetAttribute("PodType"),
				-- Same default as RaceManager; a mistyped attribute must not error inside the pickup path.
				respawnSeconds = if type(respawn) == "number" then respawn else 4,
				mystery = pod:GetAttribute("MysteryCube") == true,
				cubeRank = if type(rank) == "string" then rank else nil,
			}
		end,
		publish = function(racerId: RacerId, state: ItemRules.ItemState)
			local kind, num = ItemService.parseRacerId(racerId)
			if not num then
				return
			end
			local colorText: string = state.color or ""
			if kind == "player" then
				local player = findPlayer(num)
				if player then
					player:SetAttribute("ItemColor", colorText)
					player:SetAttribute("ItemLevel", state.level)
					player:SetAttribute("ItemCharges", state.charges or 0)
					remote:FireClient(player, "ItemState", {
						color = colorText,
						level = state.level,
						charges = state.charges, -- items v4: shots or gifts left in a charged item
						kind = if state.color then ItemRules.KIND_OF[state.color] else "",
						roulette = state.roulette, -- a fresh mystery roll: the HUD spins this long first
					})
				end
			elseif kind == "bot" then
				local bot = findBot(num)
				if bot and bot.plane then
					bot.plane:SetAttribute("ItemColor", colorText)
					bot.plane:SetAttribute("ItemLevel", state.level)
					bot.plane:SetAttribute("ItemCharges", state.charges or 0)
				end
			end
		end,
		canAct = function(racerId: RacerId): (boolean, string?)
			local kind, num = ItemService.parseRacerId(racerId)
			if not num then
				return false, "bad_racer"
			end
			local arena = arenaBox().hooks
			if arena then
				local ok, why = arena.canAct(racerId)
				if not ok then
					return false, why or "out"
				end
			end
			if kind == "player" then
				local player = findPlayer(num)
				local rec = if player then FlightServer.records[player] else nil
				if not rec then
					return false, "no_record"
				end
				return not rec.finished, "finished"
			end
			local bot = findBot(num)
			if not bot then
				return false, "no_record"
			end
			return not bot.finished, "finished"
		end,
		-- Mystery cubes: place by lap and station over every live player and bot, read once per pickup. Finished racers
		-- count as ahead of everyone still racing; a lap-1 racer still behind the start line counts as negative progress
		-- (RaceManager's standings use the same rule for bots on the grid).
		-- v38: a third result, the course gap in studs to the leader still racing (ItemRules.leaderGap; CATCHUP bands).
		standing = function(racerId: RacerId): (number, number, number)
			local _, totalLen = SplineUtils.loadWaypoints()
			local len = if type(totalLen) == "number" and totalLen > 0 then totalLen else 1
			local function progress(lap: number, station: number, finished: boolean): number
				if finished then
					return math.huge
				end
				if lap == 1 and station > len - 350 then
					return station - len
				end
				return (lap - 1) * len + station
			end
			local all: { number } = {}
			local mine: number? = nil
			local recordFilter = ItemService.recordFilter
			local records = if recordFilter then recordFilter(FlightServer.records) else FlightServer.records
			for player, rec in pairs(records) do
				if rec.hull and rec.hull.Parent then
					local p = progress(rec.lap or 1, rec.station or 0, rec.finished == true)
					table.insert(all, p)
					if ItemService.playerRacerId(player.UserId) == racerId then
						mine = p
					end
				end
			end
			for _, bot in ipairs(AIRacers.bots) do
				if bot.hull and bot.hull.Parent then
					local p = progress(bot.lap or 1, bot.station or 0, bot.finished == true)
					table.insert(all, p)
					if ItemService.botRacerId(bot.id) == racerId then
						mine = p
					end
				end
			end
			if mine == nil then
				return 1, 1, 0
			end
			local rank, field = ItemRules.rankIn(mine, all)
			return rank, field, ItemRules.leaderGap(mine, all)
		end,
		-- Items v4 (Storm Bolt rarity): the racer is on the race's last lap (RaceAttr TotalLaps of the stepping scope).
		finalLap = function(racerId: RacerId): boolean
			local RaceAttr = require(Shared:WaitForChild("RaceAttr")) :: any
			local laps = RaceAttr.here("TotalLaps")
			if type(laps) ~= "number" or laps <= 0 then
				return false
			end
			local kind, num = ItemService.parseRacerId(racerId)
			local lap: any = nil
			if kind == "player" and num then
				local player = findPlayer(num)
				local rec = if player then FlightServer.records[player] else nil
				lap = if rec then rec.lap else nil
			elseif kind == "bot" and num then
				local bot = findBot(num)
				lap = if bot then bot.lap else nil
			end
			return type(lap) == "number" and lap >= laps
		end,
		-- Item 18: display names only (Player.DisplayName; a bot's roster or boss name).
		displayName = function(racerId: RacerId): string
			local kind, num = ItemService.parseRacerId(racerId)
			if kind == "player" and num then
				local player = findPlayer(num)
				return if player then player.DisplayName else "a racer"
			elseif kind == "bot" and num then
				local bot = findBot(num)
				return if bot and type(bot.name) == "string" then bot.name else "a racer"
			end
			return "a racer"
		end,
		-- Items 14 and 18: "IncomingItem" / "ItemGrudge" to a player's client. An "other" racer id in the payload is
		-- swapped for that racer's vehicle model, so the client can mark it (the nemesis tag) without parsing ids.
		notify = function(racerId: RacerId, event: string, payload: { [string]: any })
			local kind, num = ItemService.parseRacerId(racerId)
			local player = if kind == "player" and num then findPlayer(num) else nil
			if not player then
				return
			end
			local other = payload.other
			if type(other) == "string" then
				local okind, onum = ItemService.parseRacerId(other)
				local plane: Instance? = nil
				if okind == "player" and onum then
					local op = findPlayer(onum)
					local rec = if op then FlightServer.records[op] else nil
					plane = if rec then rec.plane else nil
				elseif okind == "bot" and onum then
					local bot = findBot(onum)
					plane = if bot then bot.plane else nil
				end
				payload.plane = plane
				payload.other = nil
			end
			remote:FireClient(player, event, payload)
		end,
	}
	return world
end

-- The one ItemRemote (created on first call). ItemEffects sends its client events on it too, and may need it before
-- start() runs because start() takes ItemEffects' hooks.
function ItemService.ensureRemote(): RemoteEvent
	local folder = ReplicatedStorage:FindFirstChild(ItemService.REMOTES_FOLDER)
	if not folder then
		local f = Instance.new("Folder")
		f.Name = ItemService.REMOTES_FOLDER
		f.Parent = ReplicatedStorage
		folder = f
	end
	local existing = (folder :: Instance):FindFirstChild(ItemService.REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = ItemService.REMOTE_NAME
	remote.Parent = folder
	return remote
end

------------------------------------------------------------------------------------------------------------------------
-- Economy v3 phase 2b (docs/design/PER_GROUP_RACES.md): one item ledger per RaceInstance. Nothing here runs unless the
-- boot script calls enableScopes (RaceFlowRules.PER_GROUP true); on the single-race path ItemService.active is the one
-- started service, the remote and leave handlers call it directly, exactly as before.
------------------------------------------------------------------------------------------------------------------------

-- What the per-group engine hands in (server/RaceGroups.scopeApi over shared/RaceScope).
export type ScopeApi = {
	current: () -> number,
	instanceOf: (player: Player) -> number,
	run: (id: number, fn: (...any) -> ...any, ...any) -> ...any,
	state: (name: string, factory: () -> any) -> any,
	filter: (records: { [any]: any }) -> { [any]: any },
}

-- Set by start(): the live World and options a per-instance service is built with (same world: it reads the racers
-- of the scope it is called in).
ItemService.world = nil :: World?
ItemService.options = nil :: Options?
-- Remote "Use" and leave routing; nil on the single-race path (the started service answers).
ItemService.routeRemote = nil :: ((player: Player, action: any) -> ())?
ItemService.routeRemoving = nil :: ((player: Player) -> ())?
-- The record map a mystery cube's place is ranked over: this scope's racers only (nil: every record, as before).
ItemService.recordFilter = nil :: ((records: { [any]: any }) -> { [any]: any })?

-- Per group: ItemService.active answers the running scope's service (the started one in the hub scope, a fresh one
-- per instance made on first use with hooksFor(): that instance's ItemEffects engine), and a player's "Use" and his
-- leaving go to the service of the instance he is seated in.
function ItemService.enableScopes(api: ScopeApi, hooksFor: () -> Hooks)
	local base: Service? = rawget(ItemService :: any, "active")
	rawset(ItemService :: any, "active", nil)
	local function scoped(): { service: Service? }
		return api.state("ItemService", function(): any
			return { service = nil }
		end)
	end
	setmetatable(ItemService :: any, {
		__index = function(_: any, k: string): any
			if k ~= "active" then
				return nil
			end
			if api.current() == 0 then
				return base
			end
			local st = scoped()
			local world = ItemService.world
			if st.service == nil and world then
				st.service = ItemService.new(world, hooksFor(), ItemService.options)
			end
			return st.service
		end,
		__newindex = function(t: any, k: string, v: any)
			if k ~= "active" then
				rawset(t, k, v)
			elseif api.current() == 0 then
				base = v
			else
				scoped().service = v
			end
		end,
	})
	ItemService.recordFilter = api.filter
	arenaScoped = function(): { hooks: ArenaHooks? }
		if api.current() == 0 then
			return arenaSingle
		end
		return api.state("ItemServiceArena", function(): any
			return { hooks = nil }
		end)
	end
	ItemService.routeRemote = function(player: Player, action: any)
		api.run(api.instanceOf(player), function()
			local svc = ItemService.active
			if svc then
				svc.handleRemote(ItemService.playerRacerId(player.UserId), action)
			end
		end)
	end
	ItemService.routeRun = function(player: Player, fn: (Service) -> ())
		api.run(api.instanceOf(player), function()
			local svc = ItemService.active
			if svc then
				fn(svc)
			end
		end)
	end
	ItemService.routeRemoving = function(player: Player)
		api.run(api.instanceOf(player), function()
			local svc = ItemService.active
			if svc then
				svc.removeRacer(ItemService.playerRacerId(player.UserId))
			end
		end)
	end
end

-- Creates the remote and the live service once; later calls return the running service. Hooks default to logging
-- stubs until the race loop passes real effects.
function ItemService.start(hooks: Hooks?, options: Options?): Service
	local running = ItemService.active
	if running then
		return running
	end

	local remote = ItemService.ensureRemote()

	local world = ItemService.robloxWorld(remote)
	local service = ItemService.new(world, hooks or ItemService.loggingHooks(world.log), options)
	ItemService.active = service
	ItemService.world = world
	ItemService.options = options

	-- The payload is ignored on purpose: the server already knows what the racer holds. T1-9: a per-player bucket in
	-- front (Use / Roll / Drag; RemoteGuardRules.LIMITS.item), so a client firing in a loop costs no work and no log.
	-- Required here, not in the header: the pure-logic specs load this module with a header that offers ItemRules only.
	local RemoteGuardRules = require(Shared:WaitForChild("RemoteGuardRules")) :: any
	local itemLimiter = RemoteGuardRules.newLimiter(RemoteGuardRules.LIMITS.item)
	remote.OnServerEvent:Connect(function(player: Player, action: any)
		if not itemLimiter.allow(player, os.clock()) then
			return
		end
		local route = ItemService.routeRemote
		if route then
			route(player, action) -- per group: the sender's instance (enableScopes)
			return
		end
		service.handleRemote(ItemService.playerRacerId(player.UserId), action)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		itemLimiter.forget(player)
		local route = ItemService.routeRemoving
		if route then
			route(player)
			return
		end
		service.removeRacer(ItemService.playerRacerId(player.UserId))
	end)

	world.log(string.format(
		"[SkyRally][ITEM] service started remote=%s hooks=%s levelOneOnly=%s",
		ItemService.REMOTE_NAME,
		if hooks then "wired" else "logging",
		tostring(service.isLevelOneOnly())
	))
	return service
end

return ItemService
