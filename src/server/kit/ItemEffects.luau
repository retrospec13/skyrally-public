--!strict
-- Live item effects behind ItemService's hooks (LAUNCH_PROGRESSION section 4; TEST_LIST_LAUNCH L07).
-- ItemService decides WHO may fire WHAT (held item, level, rate, race phase); this module decides what the shot does in
-- the world, all server-side:
--   red    missile: server-simulated projectile(s). Unguided shots (S5 levels 1 and 3) follow the course line forward
--          from the shooter's lane, because a straight shot in a cavern track hits the first wall; the homing shot
--          (level 2) locks the racer directly ahead, slides across the corridor toward its lane and chases the hull
--          once close. Any racer it touches (not the shooter) spins out for stunSeconds; a shield blocks it.
--   blue   boost: the shooter's client applies the speed (it owns the hull); bots through ItemService.applyToBot.
--   yellow shield: ItemService keeps the timer (isShielded); this module shows the bubble to everyone.
--   green  trap: an aerial mine dropped behind the racer; arms after trapArmSeconds; touch = spin-out.
--   rainbow magnet (v2): locks the CLOSEST other racer within range (ItemRules.magnetPick, a near-tie going to the one
--          in front) and carries the user to it for up to N s (the client applies the pull and the steering to its own
--          hull; bots get added speed). Contact ends it with a pop and no stun. Nobody in range: fizzle + "magnetMiss".
-- Clients only render: "ItemEffect" goes to the affected player (boost, hit, magnet, shield), "ItemFx" to everyone
-- (explosions, bubble, beam), "ItemUsed" to the shooter (HUD fire animation). Projectiles and traps are anchored,
-- non-colliding, non-queryable parts under workspace.SkyRallyItemFX (CanQuery=false: FlightController's step raycast
-- stops at the first part it meets, so a queryable missile would read as a wall).
--
-- Battle arenas (LAUNCH_PROGRESSION 2b) have no course line and no race order: setArena(rules) makes every shot fly
-- free (unguided shots curve gently toward the opponent rules.target picks, the nearest one; homing shots turn at their
-- own rate), takes the hittable racers from rules.order and reports every landed hit to rules.onHit (the mode scores
-- it). setArena(nil) restores race behaviour. server/battle/BattleCore owns the call.
--
-- Respawn protection (trap audit G2; "then I exploded because I got hit"): every respawn grants the racer
-- RESPAWN_IMMUNE_SECONDS of item and hazard immunity on the server (grantImmunity; start() wires it to the
-- LastRespawnClock stamp FlightServer.respawnAtLastCheckpoint writes on every respawn path: crash, drown, boundary
-- return, battle ctx.respawn). A hit inside the window returns "immune" with no "explode", no stun and no onHit (no
-- life, egg or sack lost); the missile or trap pops on the bubble ("blocked" with respawn = true) and every client
-- shows the bubble ("respawnShield"). A respawn the player's own client asked for (a crash, the RESPAWN button, the
-- stuck watchdog: FlightServer's LastRespawnAsked) starts a new window only RESPAWN_IMMUNE_REARM seconds after the last
-- one began, so pressing respawn as a missile comes in, or a client firing RequestRespawn on a loop, is never a
-- standing shield; a respawn the server orders (a drown, a boundary return, a seat) always gets one.
--
-- World collision (trap audit X-01): a free-flying shot (arena shots, and a race homing shot once it chases the hull)
-- sweeps each step against the world through ctx.castWorld. A wall, rock, hull or roof stops it there ("explode" with
-- wall = true and no victim), so cover is cover; gentle ground (normal Y >= SKIM_NORMAL_Y) is skimmed instead, so a
-- shot over dunes or up a ramp is not wasted on the sand. Course-following race shots stay in the carved flight
-- corridor and are not swept. Traps do not move and are unaffected.
--
-- REMARKABLE item 14 (incoming warning): every INCOMING.tick the engine works out, for each player racer, the soonest
-- shot on its way (an unguided course shot in its lane, a homing shot locked on it, a free shot heading at it) and
-- sends the ETA through ctx.warnIncoming; the client beeps faster as it closes. A racer warned inside closeCallEta that
-- the shot then passes, or that it misses (a wall, another racer, a fizzle), gets {dodged = true}: DODGED!. Information
-- only; shots, hits and speeds are unchanged. Item 18 (getting even): every landed hit goes through ctx.noteHit (the
-- grudge book) and the "explode" broadcast carries no comic word (hits show ring, sparks, smoke and sound only).
--
-- Item bugs audit (docs/audits/item_bugs.md), "it hit the opponent but never did any damage": a race shot follows the
-- course line in the shooter's lane, clamped to the flight corridor. A shooter far off that line (hub free roam, where
-- the plaza sits 300 studs from the hub loop; a car up a wall or a mountain, which the owner wants kept) had its shot
-- yanked sideways onto the course inside missileBlendSeconds, nowhere near the racer in front of it. Such a shot now
-- flies FREE (as in an arena): straight from the nose, swept against the world, curving gently (a homing shot at its
-- own turn rate) toward the nearest racer in front of the shooter (freeTarget). ctx.freeRoam says every shot is free
-- (the hub); offCourse says one shooter is. A shot the target's shield or respawn bubble eats tells the shooter
-- ("blocked" ItemEffect: BLOCKED!), so a block never reads as a hit that did nothing.
--
-- Missile v3 (owner 2026-10-20: "too many times I feel like the missles dont ever reach an enemy or go off shooting
-- nothing"; shared/MissileRules has the root causes). Every race shot is a Mario Kart red shell: at its launch it locks
-- the nearest racer AHEAD within MissileRules lockRange (MissileRules.pickTarget; players and bots alike, preferring one
-- that can be hit now so a volley moves on), flies the course path faster than its target (chaseSpeed) while sliding
-- into its lane, and homes on the hull once close (MissileRules.phase) while the line to it is open. A terminal shot
-- that meets a wall goes back to the course path instead of exploding there (a free/arena shot still blasts). With
-- nobody ahead in reach it flies the course in the shooter's lane and expires. A shot that loses its target (dodged,
-- the target crashed or is still spinning) overshoots: straight on for overshootSeconds, then it fizzles.
-- Counterplay, decided here (MissileRules.evasion), checked when a shot reaches a racer who has no shield, bubble or
-- hit grace: a player plane that rolled (ItemRemote "Roll" -> ctx.rolledAt) inside dodgeWindow after the shot left
-- dodges it (overshoot, DODGED!); a racer dragging a trap (ItemRemote "Drag") blocks it and the trap is spent
-- (ctx.consumeDrag, BLOCKED!); a bot evades with botEvadeChance once per shot (plane: roll, car: block). The warning
-- payload now carries the shot's flat offset (dx, dz) and lock = true, so the HUD can point at it.
--
-- Items v4 (docs/design/ITEMS_V4.md; ItemRules.SPECIAL has the numbers): hooks.special runs the nine specials, all
-- decided here on the server. Rocket Rush: invulnerable (ctx.guard), an item boost with `auto` seconds of line-follow
-- autopilot for the player's client, ended early so it never carries the racer more than 3 s past P1; level two and up
-- shove (ram) rivals in the way. Golden Wings: invulnerable, a cruise-factor boost, contact spins a rival (ram), level
-- three drops a coin per ram. Orbit Missiles: each held orbiter soaks one hit (ctx.absorb, before the shield), a press
-- fires one homing shot. Storm Bolt: a cloud over the leader for `travel` s, a siren `warn` s before the strike (the
-- target's client); a shield, an orbiter, a level-three Bubble Guard or a plane's barrel roll inside the dodge window
-- beats it; level two slows the racers near the leader, level three jumps a blocked bolt to the next racer. Boom Bomb:
-- lobbed ahead onto the ground below (or hanging in the air), blows after its fuse, stuns everyone in the radius; level
-- three leaves a slow patch. Frost Shot / Coin Burst: straight unguided shots on the missile engine (Missile.status);
-- a hit slows (ItemRules.combineSlow caps it), Frost level two freezes first and level three leaves an ice patch, Coin
-- Burst spills coins anyone can scoop for a small lift. Bubble Guard: invulnerable for its seconds; a missile, frost or
-- coin shot (a bolt at level three) reaching it inside the window flies back at whoever fired it. Gift Box gifts are
-- classic items at GIFT_MINI strength (ItemService dispatches them to the classic hooks). Clients get "slow",
-- "stormWarn" and boost flags as ItemEffect; "rocket", "golden", "stormCloud", "stormStrike", "bombBlast", "coinTake",
-- "reflect", "slow" as ItemFx (client ItemsV4Fx draws them with particles only). Nothing here touches walls, adhesion,
-- barriers, kill volumes or rescue.
--
-- Everything world-facing comes in through Context, so the Lune spec (tools/tests/loop_spec.luau) drives the whole
-- pickup -> use -> hit flow with stubs; only liveContext/start touch Roblox instances.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local MissileRules = require(Shared:WaitForChild("MissileRules"))
local RespawnRules = require(Shared:WaitForChild("RespawnRules"))

local ItemEffects = {}

local TUNING = ItemRules.TUNING
local UP = Vector3.new(0, 1, 0)

type RacerId = string

export type RacerInfo = {
	pos: Vector3,
	forward: Vector3,
	station: number, -- course station on the current lap
	progress: number, -- unwrapped: (lap - 1) * length + station
	active: boolean, -- has a vehicle, not finished, not crashing: can be hit and can be targeted
	isPlayer: boolean,
	botId: number?,
	plane: Instance?, -- the racer's Model, sent to clients so they can anchor visuals to it
	vehicle: string?, -- "plane" | "car" (missile v3: only a plane can roll a shot off); nil = unknown
}

-- Same shape as ItemService.BotEffect (kept local so this module loads without the service).
export type BotEffect = {
	kind: string,
	seconds: number,
	source: string?,
	speed: number?,
	pull: number?,
	targetRacerId: RacerId?,
	attackerRacerId: RacerId?,
	level: number?,
	factor: number?, -- items v4 "slow": the speed factor (and a "boost" from a cruise-factor special)
}

export type Context = {
	now: () -> number,
	-- Every racer id in race order, leader first (finished racers included; racer().active filters them).
	order: () -> { RacerId },
	racer: (racerId: RacerId) -> RacerInfo?,
	-- Course line sample at an (unwrapped) station: position and unit tangent.
	course: (station: number) -> (Vector3, Vector3),
	isShielded: (racerId: RacerId) -> boolean,
	sendPlayer: (racerId: RacerId, kind: string, payload: { [string]: any }) -> (),
	broadcast: (fx: string, payload: { [string]: any }) -> (),
	notifyUsed: (racerId: RacerId, payload: { [string]: any }) -> (),
	applyToBot: (botId: number, effect: BotEffect) -> (),
	spawnVisual: (kind: string, cf: CFrame, info: { [string]: any }) -> any,
	moveVisual: (visual: any, cf: CFrame) -> (),
	destroyVisual: (visual: any) -> (),
	log: (line: string) -> (),
	-- First solid world surface on the segment from -> to (position, normal), or nil. Optional: without it shots
	-- fly through the world (the Lune specs' open sky).
	castWorld: ((from: Vector3, to: Vector3) -> (Vector3?, Vector3?))?,
	-- Item 18: records a landed hit (ItemService.noteHit) and returns its kind and chain. Optional.
	noteHit: ((victim: RacerId, attacker: RacerId, source: string) -> (string, number))?,
	-- Item 14: one ETA update for a player racer ({eta, homing, count} or {eta = -1, dodged?}). Optional.
	warnIncoming: ((racerId: RacerId, payload: { [string]: any }) -> ())?,
	-- Item bugs audit: true where there is no race line to follow (the hub's free roam); every shot flies free. Optional.
	freeRoam: (() -> boolean)?,
	-- Missile v3 counterplay (optional; absent = no dodge / no drag block): the server time of the racer's last accepted
	-- barrel roll (ItemService.lastRoll), spending a dragged trap on a shot (ItemService.consumeDrag), the bots' dice.
	rolledAt: ((racerId: RacerId) -> number?)?,
	consumeDrag: ((racerId: RacerId) -> boolean)?,
	random: (() -> number)?,
	-- Items v4 (optional): invulnerability for a special (ItemService.guard), and an orbiter soaking up a hit
	-- (ItemService.absorbHit: true when one was spent).
	guard: ((racerId: RacerId, seconds: number) -> ())?,
	absorb: ((racerId: RacerId) -> boolean)?,
}

type Missile = {
	id: number,
	owner: RacerId,
	level: number,
	target: RacerId?,
	homing: boolean,
	arena: boolean, -- launched under setArena: flies free, steering toward target at turnDeg
	turnDeg: number,
	speed: number,
	lateralRate: number,
	stun: number,
	born: number,
	expires: number,
	progress: number,
	lat: number,
	vert: number,
	launchPos: Vector3,
	launchDir: Vector3,
	blendStart: number, -- missile v3: the course blend runs from (launchPos, launchDir) at this time
	pos: Vector3,
	dir: Vector3,
	pursuing: boolean,
	visual: any,
	baseExpires: number, -- missile v3: end of life without a lock (born + params.lifetime)
	tLastPos: Vector3?, -- the target's position last step (its speed for chaseSpeed)
	tSpeed: number?,
	overshoot: boolean?, -- lost its target: flying straight on until it fizzles
	ignore: RacerId?, -- the racer it just missed (no hit on them during the overshoot)
	fizzled: boolean?, -- v6 minor D3: lost its target with nobody else in reach; removed with the fizzle fx
	evaded: { [RacerId]: boolean }?, -- bots' dice already thrown for this shot
	closeCalls: { [RacerId]: boolean }?, -- item 14: players warned inside closeCallEta (DODGED! if it misses them)
	struck: RacerId?, -- the racer that used this shot up
	status: string?, -- items v4: "frost_shot" | "coin_burst": a status shot (statusHit), not a stun
	statusParams: { [string]: any }?,
}

type Trap = {
	id: number,
	owner: RacerId,
	level: number,
	form: string,
	pos: Vector3,
	stun: number,
	armAt: number,
	ownerSafeUntil: number,
	expires: number,
	visual: any,
}

type PendingShot = {
	at: number,
	owner: RacerId,
	params: ItemRules.MissileParams,
	level: number,
	index: number,
	target: RacerId?,
	spread: { [RacerId]: number }?, -- a bot's volley: shots sent at each racer so far (shared by the volley), see pickTarget
	relock: boolean?, -- missile v3: a volley shot picks its own target when it leaves
	status: string?, -- items v4 (see Missile)
	statusParams: { [string]: any }?,
	forceFree: boolean?, -- items v4: a reflected shot flies free at shot.target (who may be behind)
}

export type HitResult = "hit" | "blocked" | "immune" | "inactive"

-- Battle arena rules (setArena). order: every racer that can be hit or targeted (entrants still in the battle).
-- target: whom a shot or magnet from racerId locks (BattleCore: the nearest opponent, preferring one ahead).
-- onHit: called after every landed hit ("hit" result; not blocks or immune passes). seekDeg: turn rate in deg/s of an
-- unguided arena shot toward its target (homing shots use their own turnRateDeg).
export type ArenaRules = {
	order: () -> { RacerId },
	target: (racerId: RacerId) -> RacerId?,
	onHit: ((victim: RacerId, attacker: RacerId, source: string, pos: Vector3) -> ())?,
	seekDeg: number?,
}

export type Effects = {
	hooks: {
		applyBoost: (racerId: RacerId, params: ItemRules.BoostParams, level: number) -> (),
		spawnMissile: (racerId: RacerId, params: ItemRules.MissileParams, level: number) -> (),
		spawnTrap: (racerId: RacerId, params: ItemRules.TrapParams, level: number) -> (),
		setShield: (racerId: RacerId, params: ItemRules.ShieldParams, level: number) -> (),
		magnetPull: (racerId: RacerId, params: ItemRules.MagnetParams, level: number) -> (),
		dragTrap: (racerId: RacerId, on: boolean) -> (),
		-- Items v4: the nine specials (kind = the special's id, params = its ItemRules.SPECIAL level row).
		special: (racerId: RacerId, kind: string, params: { [string]: any }, level: number) -> (),
	},
	step: (dt: number) -> (),
	clear: () -> (),
	-- Applies one hit (shield check, immunity window, player/bot dispatch, fx, log). Exposed for tests and battle modes.
	hit: (victim: RacerId, attacker: RacerId, source: string, stunSeconds: number, pos: Vector3) -> HitResult,
	-- Battle arena mode (see ArenaRules); nil restores the race behaviour.
	setArena: (rules: ArenaRules?) -> (),
	counts: () -> (number, number, number), -- missiles in flight, traps armed or arming, shots still queued
	-- Respawn protection: no item or hazard lands on racerId for `seconds` (default RESPAWN_IMMUNE_SECONDS; extends a
	-- running window, never shortens it); every client is told to show the bubble. asked: the player's own client asked
	-- for this respawn (held to RESPAWN_IMMUNE_REARM).
	grantImmunity: (racerId: RacerId, seconds: number?, asked: boolean?) -> (),
	-- True while racerId's respawn protection runs (bots read it to hold fire at a bubble).
	isImmune: (racerId: RacerId) -> boolean,
}

------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (no Roblox instances; Lune-tested)
------------------------------------------------------------------------------------------------------------------------

-- The nearest racer ahead of racerId in race order that passes isActive; nil for the leader or an unknown racer.
function ItemEffects.targetAhead(order: { RacerId }, racerId: RacerId, isActive: ((RacerId) -> boolean)?): RacerId?
	for i, id in ipairs(order) do
		if id == racerId then
			for j = i - 1, 1, -1 do
				local candidate = order[j]
				if not isActive or isActive(candidate) then
					return candidate
				end
			end
			return nil
		end
	end
	return nil
end

local function rightOf(tangent: Vector3): Vector3
	local r = tangent:Cross(UP)
	if r.Magnitude < 0.01 then
		return Vector3.new(1, 0, 0)
	end
	return r.Unit
end

-- Lane of a world point relative to the course line: lateral (along the course's right vector) and vertical studs.
function ItemEffects.courseOffset(pos: Vector3, coursePos: Vector3, tangent: Vector3): (number, number)
	local d = pos - coursePos
	return d:Dot(rightOf(tangent)), d.Y
end

function ItemEffects.coursePoint(coursePos: Vector3, tangent: Vector3, lat: number, vert: number): Vector3
	return coursePos + rightOf(tangent) * lat + Vector3.new(0, vert, 0)
end

-- Keeps a course-following shot inside the flight corridor (MAP_PLAN_SCHEMA flight.corridor).
function ItemEffects.clampCorridor(lat: number, vert: number): (number, number)
	return math.clamp(lat, -TUNING.corridorHalfWidth, TUNING.corridorHalfWidth),
		math.clamp(vert, TUNING.corridorFloor, TUNING.corridorCeiling)
end

-- Distance from p to the segment a-b: a hit test that cannot tunnel through a racer on a slow server frame.
function ItemEffects.segmentDistance(a: Vector3, b: Vector3, p: Vector3): number
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-6 then
		return (p - a).Magnitude
	end
	local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return (p - (a + ab * t)).Magnitude
end

local function approach(value: number, target: number, maxDelta: number): number
	if value < target then
		return math.min(target, value + maxDelta)
	end
	return math.max(target, value - maxDelta)
end

-- OURS (item bugs audit): a shooter this far outside the flight corridor flies its shot free instead of along the course.
-- The margins keep a racer brushing the corridor edge (a wide line, a hop) on the course shot.
ItemEffects.OFF_COURSE_LAT_MARGIN = 12 -- studs past corridorHalfWidth
ItemEffects.OFF_COURSE_BELOW = -8 -- studs under the course line (a car in a dip under the road)
ItemEffects.OFF_COURSE_ABOVE_MARGIN = 16 -- studs past corridorCeiling
-- OURS: whom a free shot curves toward: the nearest active racer inside this cone in front of the shooter and range.
ItemEffects.FREE_TARGET_DOT = 0.5 -- cos 60 degrees
ItemEffects.FREE_TARGET_RANGE = 320

-- Pure: whether a racer at (lat, vert) from the course line is off it (its shot flies free, not along the course).
function ItemEffects.offCourse(lat: number, vert: number): boolean
	return math.abs(lat) > TUNING.corridorHalfWidth + ItemEffects.OFF_COURSE_LAT_MARGIN
		or vert < ItemEffects.OFF_COURSE_BELOW
		or vert > TUNING.corridorCeiling + ItemEffects.OFF_COURSE_ABOVE_MARGIN
end

export type Candidate = { id: RacerId, pos: Vector3, active: boolean }

-- Pure: the nearest active candidate (never `self`) in the shooter's forward cone within range; nil when nobody is.
function ItemEffects.freeTarget(self: RacerId, from: Vector3, forward: Vector3, candidates: { Candidate }): RacerId?
	local fwd = if forward.Magnitude > 0.01 then forward.Unit else Vector3.new(0, 0, -1)
	local best: RacerId? = nil
	local bestD = ItemEffects.FREE_TARGET_RANGE
	for _, c in candidates do
		if c.id ~= self and c.active then
			local to = c.pos - from
			local d = to.Magnitude
			if d > 0.5 and d <= bestD and fwd:Dot(to / d) >= ItemEffects.FREE_TARGET_DOT then
				best, bestD = c.id, d
			end
		end
	end
	return best
end

-- OURS: an unguided arena shot curves this many deg/s toward its target, enough to forgive a phone player's aim at
-- 100-200 studs without turning a level-one missile into the level-two homing one (90 deg/s).
ItemEffects.ARENA_SEEK_DEG = 40

-- OURS (trap audit G2): respawn protection, counted from the server's respawn stamp. A car's stamp lands when its
-- RequestRespawn reaches the server, before the reply and the 0.35 s fade-in, so 2.5 s leaves about 2 s of visible,
-- protected driving on the respawn frame (the audit's "about 2 s"). One value with the client (RespawnRules.RESPAWN_GRACE),
-- which drops only stale hits inside it (RespawnRules.clientIgnoresHit).
ItemEffects.RESPAWN_IMMUNE_SECONDS = RespawnRules.RESPAWN_GRACE
-- OURS (review of G2): a respawn the client asked for starts a new protection window only this long after the last
-- window began. The car's manual floor is 2.5 s and a plane's RequestRespawn has none, so without it a held RESPAWN
-- button (or a cheat client) kept a battle player shielded most of the time, sitting on its pad and firing.
ItemEffects.RESPAWN_IMMUNE_REARM = 6
-- OURS (trap audit X-01): a swept shot that meets ground flatter than this (normal Y; 0.7 is about 45 degrees) skims
-- over it at SKIM_HEIGHT instead of exploding: a dune, a ramp or a bump is not cover, a wall, rock face or hull is.
ItemEffects.SKIM_NORMAL_Y = 0.7
ItemEffects.SKIM_HEIGHT = 1.5

-- Unit vector `from` turned toward `to` by at most maxAngle radians (slerp; no turn when they are opposite).
function ItemEffects.turnToward(from: Vector3, to: Vector3, maxAngle: number): Vector3
	local f, t = from.Unit, to.Unit
	local angle = math.acos(math.clamp(f:Dot(t), -1, 1))
	if angle <= maxAngle or angle < 1e-5 then
		return t
	elseif angle > math.pi - 1e-3 then
		return f
	end
	local s = maxAngle / angle
	return ((f * math.sin((1 - s) * angle) + t * math.sin(s * angle)) / math.sin(angle)).Unit
end

------------------------------------------------------------------------------------------------------------------------
-- Effects engine
------------------------------------------------------------------------------------------------------------------------

function ItemEffects.new(ctx: Context): Effects
	local missiles: { Missile } = {}
	local traps: { Trap } = {}
	local pending: { PendingShot } = {}
	local immuneUntil: { [RacerId]: number } = {}
	local nextId = 0
	local arena: ArenaRules? = nil
	-- Magnet v2: running pulls by holder, so arrival (contact) ends a bot's pull and pops on every client.
	local magnets: { [RacerId]: { target: RacerId, untilT: number } } = {}
	-- A magnet used with nobody in range keeps looking for TUNING.magnetPulseSeconds (stepPulses, set with the hooks).
	local pulses: { [RacerId]: { params: ItemRules.MagnetParams, level: number, untilT: number } } = {}
	local stepPulses: (now: number) -> () = function() end
	-- Items v4: Bubble Guard reflect windows; the shot (or bolt) sent back is fired by reflectBack (set with the hooks).
	local reflects: { [RacerId]: { untilT: number, left: number, bolts: boolean } } = {}
	local reflectBack: (from: RacerId, to: RacerId, source: string) -> () = function() end
	local stepSpecials: (now: number) -> () = function() end
	local clearSpecials: () -> () = function() end

	local function newId(): number
		nextId += 1
		return nextId
	end

	local function isActive(racerId: RacerId): boolean
		local info = ctx.racer(racerId)
		return info ~= nil and info.active
	end

	local function botIdOf(racerId: RacerId): number?
		local kind, num = string.match(racerId, "^(%a+):(%-?%d+)$")
		if kind == "bot" then
			return tonumber(num)
		end
		return nil
	end

	local function used(racerId: RacerId, kind: ItemRules.Kind, level: number)
		local color = ItemRules.COLOR_OF_KIND[kind]
		ctx.notifyUsed(racerId, { color = color, kind = kind, level = level })
	end

	-- Respawn protection windows (grantImmunity), apart from immuneUntil (the post-hit grace): a projectile passes
	-- through a racer still spinning from a hit, but pops on a respawn bubble.
	local respawnUntil: { [RacerId]: number } = {}
	local respawnGranted: { [RacerId]: number } = {} -- when the last window was granted (RESPAWN_IMMUNE_REARM)
	local rearmLogged: { [RacerId]: number } = {} -- the window whose refusals were logged (one line per window)

	local function respawnProtected(racerId: RacerId, now: number): boolean
		local untilT = respawnUntil[racerId]
		return untilT ~= nil and now < untilT
	end

	-- Item 14: a racer that was hit, blocked or popped a shot on its bubble did not dodge the rest of a volley.
	local function forgetCloseCalls(racerId: RacerId)
		for _, m in missiles do
			local calls = m.closeCalls
			if calls then
				calls[racerId] = nil
			end
		end
	end

	-- Item bugs audit: the shooter of a missile that a shield or a respawn bubble ate hears about it (BLOCKED!), so a
	-- block never reads as a hit that did no damage. Players only (a bot has no client); never for an own goal.
	local function tellBlocked(attacker: RacerId, victim: RacerId, source: string, respawn: boolean)
		if source ~= "missile" or attacker == victim or botIdOf(attacker) ~= nil then
			return
		end
		ctx.sendPlayer(attacker, "blocked", { source = source, respawn = respawn, victim = victim })
	end

	-- One hit; the second value is true when the projectile or trap is used up by it (a hit, a block, a pop on a
	-- respawn bubble) rather than passing through. form: the trap's form ("slick", "mine", "bubble") for a trap hit, so the
	-- client can sound an oil slip against a mine blast.
	-- Items v4: sources a Bubble Guard sends back, and the item sources the grudge book records.
	local REFLECTABLE: { [string]: boolean } = { missile = true, frost_shot = true, coin_burst = true, storm = true }
	local GRUDGE_SOURCES: { [string]: boolean } = { missile = true, trap = true, frost_shot = true, coin_burst = true, storm = true, bomb = true, ram = true }

	-- items v4: onLand runs on a landed hit (the status of a frost or coin shot); with stunSeconds 0 there is no
	-- spin-out, no hit grace and no "explode", only onLand.
	local function strike(victim: RacerId, attacker: RacerId, source: string, stunSeconds: number, pos: Vector3, form: string?, onLand: ((info: RacerInfo) -> ())?): (HitResult, boolean)
		local info = ctx.racer(victim)
		if not info or not info.active then
			return "inactive", false
		end
		local now = ctx.now()
		if respawnProtected(victim, now) then
			-- No explosion, no stun, no onHit: the bubble eats it and says so.
			ctx.broadcast("blocked", { pos = pos, plane = info.plane, source = source, respawn = true })
			forgetCloseCalls(victim)
			tellBlocked(attacker, victim, source, true)
			ctx.log(string.format("[SkyRally][ITEM] hit racer=%s by=%s source=%s result=immune why=respawn", victim, attacker, source))
			return "immune", true
		end
		-- Items v4: a Bubble Guard's window sends a shot back at whoever fired it (a bolt only at level three).
		local rf = reflects[victim]
		if rf and now < rf.untilT and rf.left > 0 and attacker ~= victim and REFLECTABLE[source] and (source ~= "storm" or rf.bolts) then
			rf.left -= 1
			ctx.broadcast("reflect", { pos = pos, plane = info.plane, source = source })
			forgetCloseCalls(victim)
			tellBlocked(attacker, victim, if source == "storm" then source else "missile", false)
			ctx.log(string.format("[SkyRally][ITEM] hit racer=%s by=%s source=%s result=reflected", victim, attacker, source))
			reflectBack(victim, attacker, source)
			return "blocked", true
		end
		if ctx.isShielded(victim) then
			ctx.broadcast("blocked", { pos = pos, plane = info.plane, source = source })
			forgetCloseCalls(victim)
			tellBlocked(attacker, victim, source, false)
			ctx.log(string.format("[SkyRally][ITEM] hit racer=%s by=%s source=%s result=blocked", victim, attacker, source))
			return "blocked", true
		end
		-- A stunning hit on a racer still in its post-hit grace passes through (checked before the orbiters, so a spinning
		-- racer never spends one on a shot that could not have hit anyway).
		if stunSeconds > 0 then
			local immune = immuneUntil[victim]
			if immune and now < immune then
				return "immune", false
			end
		end
		-- Items v4: an orbiter of a held Orbit Missiles soaks it up (after the shield, so a shield never wastes one).
		local absorb = ctx.absorb
		if absorb and attacker ~= victim and absorb(victim) then
			ctx.broadcast("blocked", { pos = pos, plane = info.plane, source = source, orbit = true })
			forgetCloseCalls(victim)
			tellBlocked(attacker, victim, source, false)
			ctx.log(string.format("[SkyRally][ITEM] hit racer=%s by=%s source=%s result=blocked why=orbit", victim, attacker, source))
			return "blocked", true
		end
		local botId = info.botId
		if stunSeconds > 0 then
			immuneUntil[victim] = now + stunSeconds + TUNING.hitGraceSeconds
			forgetCloseCalls(victim)
			if info.isPlayer then
				ctx.sendPlayer(victim, "hit", { seconds = stunSeconds, source = source, form = form })
			elseif botId then
				ctx.applyToBot(botId, { kind = "hit", seconds = stunSeconds, source = source, attackerRacerId = attacker })
			end
		else
			forgetCloseCalls(victim)
		end
		if onLand then
			onLand(info)
		end
		-- Item 18: the grudge book (who owes whom a hit), for item hits only: a boss or battle hazard (source "boss_*",
		-- or a BattleCore hazard passing the victim as its own attacker) is nobody's grudge and never a self-hit. A fault
		-- in the book must never stop the hit itself.
		local note = ctx.noteHit
		if note and GRUDGE_SOURCES[source] then
			pcall(function(): string
				local k = note(victim, attacker, source)
				return k
			end)
		end
		if stunSeconds > 0 then
			ctx.broadcast("explode", { pos = pos, plane = info.plane, source = source, seconds = stunSeconds, form = form })
		end
		ctx.log(string.format(
			"[SkyRally][ITEM] hit racer=%s by=%s source=%s stun=%.1f result=hit",
			victim,
			attacker,
			source,
			stunSeconds
		))
		local rules = arena
		local onHit = if rules then rules.onHit else nil
		if onHit then
			-- The mode's scoring must not take the effects loop down with it.
			local ok, err = pcall(function()
				onHit(victim, attacker, source, pos)
			end)
			if not ok then
				ctx.log(string.format("[SkyRally][ITEM] arena onHit error racer=%s err=%s", victim, tostring(err)))
			end
		end
		return "hit", true
	end

	local function hit(victim: RacerId, attacker: RacerId, source: string, stunSeconds: number, pos: Vector3): HitResult
		return (strike(victim, attacker, source, stunSeconds, pos))
	end

	-- Moves a free-flying shot heading `dir` from `from` toward `to` through the world (X-01). Returns where it ends
	-- this step, whether it struck a wall there, and its heading. Gentle ground is skimmed: the shot rides SKIM_HEIGHT
	-- over the surface with its heading laid along it, and the rest of the step goes on from there (one more sweep, so
	-- a wall just past a ramp still stops it).
	local function sweepWorld(dir: Vector3, from: Vector3, to: Vector3): (Vector3, boolean, Vector3)
		local cast = ctx.castWorld
		if not cast then
			return to, false, dir
		end
		local hitPos, normal = cast(from, to)
		if not hitPos then
			return to, false, dir
		end
		local n = normal or -dir
		if n.Y < ItemEffects.SKIM_NORMAL_Y then
			return hitPos, true, dir
		end
		local along = dir - n * dir:Dot(n)
		local heading = if along.Magnitude > 0.05 then along.Unit else dir
		local lifted = hitPos + n * ItemEffects.SKIM_HEIGHT
		local rest = math.max(0, (to - from).Magnitude - (hitPos - from).Magnitude)
		local goal = lifted + heading * rest
		local hit2, n2 = cast(lifted, goal)
		if not hit2 then
			return goal, false, heading
		end
		local nn = n2 or -heading
		if nn.Y < ItemEffects.SKIM_NORMAL_Y then
			return hit2, true, heading
		end
		return hit2 + nn * ItemEffects.SKIM_HEIGHT, false, heading
	end

	-- A shot that met a wall: the blast plays where it struck, with no victim (clients add the debris and the thunk).
	local function wallBlast(owner: RacerId, level: number, at: Vector3)
		ctx.broadcast("explode", { pos = at, source = "missile", wall = true })
		ctx.log(string.format("[SkyRally][ITEM] missile wall racer=%s level=%d at=(%.0f,%.0f,%.0f)", owner, level, at.X, at.Y, at.Z))
	end

	-- The hit radius (9) is wider than a bulwark or a rock lip is thick: a racer in reach of the shot's path still
	-- needs open air between that path and its hull, or a blast on the outside of the galleon's hull would stun the
	-- player standing behind it on the deck.
	local function reachable(a: Vector3, b: Vector3, target: Vector3): boolean
		local cast = ctx.castWorld
		if not cast then
			return true
		end
		local ab = b - a
		local len2 = ab:Dot(ab)
		local t = if len2 < 1e-6 then 0 else math.clamp((target - a):Dot(ab) / len2, 0, 1)
		if (target - (a + ab * t)).Magnitude < 0.5 then
			return true
		end
		-- From half a stud back along the path: a shot stopped by a wall ends on its face, and a ray that starts on a
		-- surface may not report it.
		local back = if len2 < 1e-6 then 0 else math.max(0, t - 0.5 / math.sqrt(len2))
		local blocked = cast(a + ab * back, target)
		return blocked == nil
	end

	-- Missile v3: a shot that lost its target flies straight on (free, swept against the world) and fizzles soon.
	-- ignore: the racer it just missed, never hit during the overshoot.
	local function overshoot(m: Missile, now: number, ignore: RacerId?)
		m.target = nil
		m.homing = false
		m.pursuing = false
		m.arena = true
		m.overshoot = true
		m.ignore = ignore
		m.expires = math.min(m.expires, now + MissileRules.TUNING.overshootSeconds)
	end

	-- Missile v3: the nearest racer ahead of `owner` (at `progress`) a race shot locks; nil when nobody is in reach.
	local function pickAhead(owner: RacerId, progress: number, strict: boolean?, taken: { [RacerId]: number }?): RacerId?
		local now = ctx.now()
		local cands: { MissileRules.Candidate } = {}
		for _, id in ipairs(ctx.order()) do
			if id ~= owner then
				local r = ctx.racer(id)
				if r then
					local grace = immuneUntil[id]
					table.insert(cands, {
						id = id,
						progress = r.progress,
						active = r.active,
						targetable = not respawnProtected(id, now) and not (grace ~= nil and now < grace),
					})
				end
			end
		end
		return MissileRules.pickTarget(owner, progress, cands, nil, strict, taken)
	end

	-- v6 minor D3: is racerId spinning from a hit right now (the post-hit grace; a shot locked on it is wasted)? A respawn
	-- bubble is not this: that shot still pops on the bubble and the shooter hears BLOCKED!.
	local function spinning(racerId: RacerId, now: number): boolean
		local grace = immuneUntil[racerId]
		return grace ~= nil and now < grace
	end

	-- v6 minor D3: a race shot lost its target (hit, spinning, crashed). It retargets the next racer ahead of the SHOT
	-- within range that can be hit, as the design says; with none it fizzles in the air. true: retargeted, the shot
	-- lives on; false: remove it ("fizzle").
	local function retargetOrFizzle(m: Missile, now: number): boolean
		local nextTarget = pickAhead(m.owner, m.progress, true)
		if MissileRules.lostTargetFate(nextTarget) == "fizzle" then
			return false
		end
		m.target = nextTarget
		m.homing = true
		if m.pursuing then
			-- It was on the hull: back onto the course path blended from where it is, never a snap to a stale lane.
			local cpos, tan = ctx.course(m.progress)
			local lat, vert = ItemEffects.courseOffset(m.pos, cpos, tan)
			m.lat, m.vert = ItemEffects.clampCorridor(lat, vert)
			m.launchPos, m.launchDir, m.blendStart = m.pos, m.dir, now
		end
		m.pursuing = false
		m.tLastPos, m.tSpeed = nil, nil
		m.expires = math.max(m.expires, now + MissileRules.TUNING.lockedLifetime)
		return true
	end

	-- Missile v3 counterplay for a shot reaching racerId: "roll" (dodged), "block" (a dragged trap or a bot ate it), or
	-- nil (strike() decides: hit, shield, bubble, grace). A shield, bubble or grace goes to strike() untouched, so a
	-- dragged trap is never spent on a shot that could not have hurt anyway.
	local function evasionOf(m: Missile, racerId: RacerId, info: RacerInfo): string?
		local now = ctx.now()
		local grace = immuneUntil[racerId]
		if respawnProtected(racerId, now) or ctx.isShielded(racerId) or (grace ~= nil and now < grace) then
			return nil
		end
		if not info.isPlayer then
			local dice = ctx.random
			if not dice then
				return nil -- no dice wired (the Lune specs): bots never evade
			end
			local seen = m.evaded
			if not seen then
				seen = {}
				m.evaded = seen
			end
			local book = seen :: { [RacerId]: boolean }
			if book[racerId] ~= nil then
				return nil -- one throw per shot per bot; a failed throw stays failed
			end
			local how = MissileRules.evasion({ vehicle = info.vehicle, isBot = true, now = now, random = dice() })
			book[racerId] = how ~= nil
			return how
		end
		local rolled = ctx.rolledAt
		local consume = ctx.consumeDrag
		local how = MissileRules.evasion({
			vehicle = info.vehicle,
			isBot = false,
			now = now,
			rolledAt = if rolled then rolled(racerId) else nil,
			since = m.born,
			dragging = consume ~= nil,
		})
		if how == "block" and not (consume and consume(racerId)) then
			return nil -- not dragging a trap after all
		end
		return how
	end

	local function evade(m: Missile, how: string, racerId: RacerId, info: RacerInfo, at: Vector3)
		local calls = m.closeCalls
		if calls then
			calls[racerId] = nil -- told below; no second DODGED! when the shot leaves
		end
		local warn = ctx.warnIncoming
		if how == "roll" then
			overshoot(m, ctx.now(), racerId)
			ctx.broadcast("dodge", { pos = at, plane = info.plane, how = "roll" })
			if info.isPlayer and warn then
				warn(racerId, { eta = -1, dodged = true, how = "roll" })
			end
			ctx.log(string.format("[SkyRally][ITEM] dodged racer=%s shot_by=%s how=roll", racerId, m.owner))
		else
			m.struck = racerId
			ctx.broadcast("blocked", { pos = at, plane = info.plane, source = "missile", trap = true })
			tellBlocked(m.owner, racerId, "missile", false)
			if info.isPlayer and warn then
				warn(racerId, { eta = -1, blocked = true, how = "trap" })
			end
			ctx.log(string.format("[SkyRally][ITEM] hit racer=%s by=%s source=missile result=blocked why=%s", racerId, m.owner, if info.isPlayer then "trap" else "bot"))
		end
	end

	-- Items v4: slows. One record per racer (ItemRules.combineSlow: never stacking past SLOW.floor or maxSeconds); the
	-- player's client and the bots apply the speed cap, everyone sees frost on the victim.
	local slows: { [RacerId]: { factor: number, untilT: number } } = {}
	local function applySlow(racerId: RacerId, factor: number, seconds: number, source: string): boolean
		local info = ctx.racer(racerId)
		local now = ctx.now()
		if not info or not info.active or respawnProtected(racerId, now) or ctx.isShielded(racerId) then
			return false
		end
		local cur = slows[racerId]
		local curLeft = if cur then math.max(0, cur.untilT - now) else 0
		local f, left = ItemRules.combineSlow(if cur then cur.factor else 1, curLeft, factor, seconds)
		if left <= 0 then
			return false
		end
		slows[racerId] = { factor = f, untilT = now + left }
		local botId = info.botId
		if info.isPlayer then
			ctx.sendPlayer(racerId, "slow", { factor = f, seconds = left, source = source })
		elseif botId then
			ctx.applyToBot(botId, { kind = "slow", seconds = left, factor = f, source = source })
		end
		ctx.broadcast("slow", { plane = info.plane, seconds = left, source = source })
		return true
	end

	-- Slow patches (Boom Bomb level three, Frost Shot level three): anyone inside is slowed a little, re-applied every
	-- SLOW.patchTick while they stay in it.
	type Zone = { pos: Vector3, radius: number, factor: number, untilT: number, source: string, visual: any }
	local zones: { Zone } = {}
	local zoneTickAt: { [RacerId]: number } = {}
	local function addZone(pos: Vector3, radius: number, seconds: number, source: string)
		local z: Zone = {
			pos = pos,
			radius = radius,
			factor = ItemRules.SLOW.patchFactor,
			untilT = ctx.now() + seconds,
			source = source,
			visual = ctx.spawnVisual("patch", CFrame.new(pos), { radius = radius, source = source, seconds = seconds }),
		}
		table.insert(zones, z)
	end

	-- Coins (Coin Burst, Golden Wings level three): anyone scoops one within COIN.radius for a small lift.
	type Coin = { pos: Vector3, untilT: number, readyAt: number, visual: any }
	local coins: { Coin } = {}
	local coinMagnet: { [RacerId]: number } = {} -- Coin Burst level three: the shooter's wide scoop until then
	local coinLiftUntil: { [RacerId]: number } = {}
	local function spawnCoins(center: Vector3, n: number)
		local C = ItemRules.COIN
		local now = ctx.now()
		for _, off in ItemRules.coinOffsets(n) do
			local pos = center + Vector3.new(off[1], 1.5, off[2])
			table.insert(coins, { pos = pos, untilT = now + C.lifetime, readyAt = now + C.armSeconds, visual = ctx.spawnVisual("coin", CFrame.new(pos), {}) })
			if #coins > C.maxCoins then
				local old = table.remove(coins, 1)
				if old and old.visual ~= nil then
					ctx.destroyVisual(old.visual)
				end
			end
		end
	end

	-- Frost Shot / Coin Burst land: a freeze (a short spin) first when the level has one, then the slow; a coin shot
	-- spills its coins round the victim; a level-three frost shot leaves an ice patch on the spot.
	local function statusHit(m: Missile, victim: RacerId, at: Vector3): (HitResult, boolean)
		local status = m.status
		local p = m.statusParams
		if not status or not p then
			return strike(victim, m.owner, "missile", m.stun, at)
		end
		return strike(victim, m.owner, status, m.stun, at, nil, function(info: RacerInfo)
			applySlow(victim, p.slow, (p.freeze or 0) + p.slowSeconds, status)
			if status == "coin_burst" then
				spawnCoins(info.pos, p.coins)
				if (p.magnet or 0) > 0 then
					coinMagnet[m.owner] = ctx.now() + p.magnet
				end
			elseif status == "frost_shot" and (p.patch or 0) > 0 then
				addZone(info.pos, ItemRules.SLOW.patchRadius, p.patch, "frost_shot")
			end
		end)
	end

	-- Tests the racers on the segment a -> b. Returns false (remove the shot) when one used it up.
	local function sweepRacers(m: Missile, a: Vector3, b: Vector3, racers: { RacerId }): boolean
		for _, racerId in ipairs(racers) do
			if racerId ~= m.owner and racerId ~= m.ignore then
				local info = ctx.racer(racerId)
				if info and info.active and ItemEffects.segmentDistance(a, b, info.pos) <= TUNING.missileHitRadius and reachable(a, b, info.pos) then
					local how = evasionOf(m, racerId, info)
					if how == "roll" then
						evade(m, how, racerId, info, b)
						return true -- it flies on past them
					elseif how == "block" then
						evade(m, how, racerId, info, b)
						return false
					end
					local _, usedUp = statusHit(m, racerId, b)
					if usedUp then
						m.struck = racerId
						return false -- strike() already broadcast the explosion or the block
					end
					-- "immune" (post-hit grace): the shot passes through a racer still spinning from an earlier hit. A
					-- race shot locked on them overshoots rather than circling back for a second pass (missile v3).
					if racerId == m.target and m.homing and not m.arena then
						if retargetOrFizzle(m, ctx.now()) then
							return true
						end
						m.fizzled = true
						return false -- nobody else ahead in reach: it fizzles in the air (D3)
					end
				end
			end
		end
		return true
	end

	-- Item 14: a shot that leaves the world after a close call on a player who was not the one it struck was dodged.
	local function settleCloseCalls(m: Missile)
		local calls = m.closeCalls
		local warn = ctx.warnIncoming
		if not calls or not warn then
			return
		end
		for racerId in calls do
			if racerId ~= m.struck then
				warn(racerId, { eta = -1, dodged = true })
				ctx.log(string.format("[SkyRally][ITEM] dodged racer=%s shot_by=%s", racerId, m.owner))
			end
		end
		m.closeCalls = nil
	end

	local function removeMissile(index: number, fx: string?)
		local m = table.remove(missiles, index)
		if not m then
			return
		end
		settleCloseCalls(m)
		if fx then
			ctx.broadcast(fx, { pos = m.pos, source = "missile" })
		end
		if m.visual ~= nil then
			ctx.destroyVisual(m.visual)
		end
	end

	local function removeTrap(index: number, fx: string?)
		local t = table.remove(traps, index)
		if not t then
			return
		end
		if fx then
			ctx.broadcast(fx, { pos = t.pos, source = "trap" })
		end
		if t.visual ~= nil then
			ctx.destroyVisual(t.visual)
		end
	end

	local function launchMissile(shot: PendingShot)
		local info = ctx.racer(shot.owner)
		if not info then
			ctx.log(string.format("[SkyRally][ITEM] missile dropped racer=%s reason=no_vehicle", shot.owner))
			return
		end
		local params = shot.params
		local inArena = arena ~= nil
		local lat, vert = 0, 0
		local tan = Vector3.new(0, 0, -1)
		local free = false -- item bugs audit: off the course line (or the hub's free roam) the shot flies free
		local roaming = false -- the hub's free roam: no race line, the cone alone aims a free shot
		local target = shot.target
		if not inArena then
			local cpos, ctan = ctx.course(info.station)
			tan = ctan
			lat, vert = ItemEffects.courseOffset(info.pos, cpos, tan)
			local roam = ctx.freeRoam
			roaming = roam ~= nil and roam()
			free = roaming or ItemEffects.offCourse(lat, vert) or shot.forceFree == true
			if params.count > 1 then
				-- Three lanes (left, centre, right) so a ten-shot volley reads as a spread at phone size.
				lat += TUNING.missileVolleySpread * (((shot.index - 1) % 3) - 1)
			end
			lat, vert = ItemEffects.clampCorridor(lat, vert)
		end
		local forward = if info.forward.Magnitude > 0.01 then info.forward.Unit else tan
		if free then
			-- The race order's "racer ahead" means nothing off the line: aim at whoever is in front of the nose.
			local cands: { Candidate } = {}
			for _, id in ipairs(ctx.order()) do
				local r = ctx.racer(id)
				if r then
					table.insert(cands, { id = id, pos = r.pos, active = r.active })
				end
			end
			if not shot.forceFree then
				target = MissileRules.freeLock(ItemEffects.freeTarget(shot.owner, info.pos, forward, cands), shot.target, roaming)
			elseif target then
				-- A reflected shot turns round toward whoever fired it (it may be behind).
				local t = ctx.racer(target)
				if t and (t.pos - info.pos).Magnitude > 0.5 then
					forward = (t.pos - info.pos).Unit
				end
			end
			if shot.index == 1 then
				ctx.log(string.format(
					"[SkyRally][ITEM] missile free racer=%s lat=%.0f vert=%.0f target=%s",
					shot.owner,
					lat,
					vert,
					target or "none"
				))
			end
		end
		if not inArena and not free and shot.relock and params.homing then
			-- Missile v3: each shot of a volley locks at its own launch (the first target may be spinning by now).
			target = pickAhead(shot.owner, info.progress, nil, shot.spread)
			if shot.spread and target then
				shot.spread[target] = (shot.spread[target] or 0) + 1
			end
		end
		local launchPos = info.pos + forward * TUNING.missileLaunchAhead
		local now = ctx.now()
		if shot.forceFree then
			inArena = true -- items v4: a reflected shot flies free like an arena shot (homing at its own turn rate)
		end
		if inArena or free then
			-- Nose against a wall or a hull: the shot leaves the launcher and meets it point blank (a cast that starts
			-- inside the wall would never see it). Ground in the way is skimmed like in flight.
			local start, struck, heading = sweepWorld(forward, info.pos, launchPos)
			if struck then
				wallBlast(shot.owner, shot.level, start)
				return
			end
			launchPos, forward = start, heading
		end
		local m: Missile = {
			id = newId(),
			owner = shot.owner,
			level = shot.level,
			target = target,
			-- Race shots: a lock needs a target (an unlocked shot is the plain course shot). Arena/free: the v2 rule.
			homing = if inArena or free then params.freeHoming else (params.homing and target ~= nil),
			arena = inArena or free,
			turnDeg = if params.freeHoming then params.turnRateDeg else ((if arena then arena.seekDeg else nil) or ItemEffects.ARENA_SEEK_DEG),
			speed = params.speed,
			lateralRate = TUNING.missileLateralRate * (params.turnRateDeg / 90),
			stun = params.stunSeconds,
			born = now,
			-- Missile v3: a locked race shot lives until it can have caught its target (lockRange / catchUp).
			expires = now + (if not (inArena or free) and params.homing and target ~= nil
				then math.max(params.lifetime, MissileRules.TUNING.lockedLifetime)
				else params.lifetime),
			baseExpires = now + params.lifetime,
			progress = info.progress + TUNING.missileLaunchAhead,
			lat = lat,
			vert = vert,
			launchPos = launchPos,
			launchDir = forward,
			blendStart = now,
			pos = launchPos,
			dir = forward,
			pursuing = false,
			visual = nil,
			status = shot.status,
			statusParams = shot.statusParams,
		}
		m.visual = ctx.spawnVisual("missile", CFrame.lookAt(launchPos, launchPos + forward), {
			owner = shot.owner,
			level = shot.level,
			homing = target ~= nil,
			target = target, -- item 14: the locked racer's client blinks this shot in time with its beeps
			status = shot.status, -- items v4: a frost or coin shot is tinted its item colour
		})
		table.insert(missiles, m)
		if #missiles > TUNING.maxMissiles then
			removeMissile(1, "fizzle")
		end
	end

	-- Moves one missile; returns false when it must be removed (fx name as the second value).
	local function stepMissile(m: Missile, dt: number, now: number, racers: { RacerId }): (boolean, string?)
		if now >= m.expires then
			return false, "fizzle"
		end
		local prev = m.pos
		local target = m.target
		local tInfo = if target then ctx.racer(target) else nil
		if m.arena then
			-- Arena: no course to follow. Fly straight, curving toward a live target at turnDeg, stopped by walls.
			if tInfo and tInfo.active then
				local to = tInfo.pos - m.pos
				if to.Magnitude > 0.5 then
					m.dir = ItemEffects.turnToward(m.dir, to, math.rad(m.turnDeg) * dt)
				end
			end
			m.progress += m.speed * dt
			local arenaPos, struck, heading = sweepWorld(m.dir, prev, m.pos + m.dir * (m.speed * dt))
			m.dir = heading
			m.pos = arenaPos
			if m.visual ~= nil then
				ctx.moveVisual(m.visual, CFrame.lookAt(arenaPos, arenaPos + m.dir))
			end
			if not sweepRacers(m, prev, arenaPos, racers) then
				return false, nil
			end
			if struck then
				if m.overshoot then
					return false, "fizzle" -- v6 minor D3: a shot that lost its target never blows up on a wall
				end
				wallBlast(m.owner, m.level, arenaPos)
				return false, nil
			end
			return true, nil
		end
		if m.homing and target and (not tInfo or not tInfo.active) then
			-- The locked racer finished, crashed or left: nothing left to chase.
			if m.pursuing then
				if retargetOrFizzle(m, now) then
					return true, nil
				end
				return false, "fizzle"
			end
			m.homing = false
			m.target = nil
			m.expires = math.min(m.expires, math.max(m.baseExpires, now + MissileRules.TUNING.overshootSeconds))
			tInfo = nil
		end
		if m.homing and target and tInfo and not m.pursuing and spinning(target, now) then
			-- v6 minor D3: the target was hit (by this salvo's earlier shot, say) or is spinning: next racer ahead, or fizzle.
			if not retargetOrFizzle(m, now) then
				return false, "fizzle"
			end
			target = m.target
			tInfo = if target then ctx.racer(target) else nil
		end
		local speed = m.speed
		if m.homing and tInfo then
			-- Missile v3: gain on the target along the course (its speed from the last step; a teleport is no sample).
			local tPos = tInfo.pos
			local last = m.tLastPos
			if last and dt > 0 and (tPos - last).Magnitude <= TUNING.trapSweepMax then
				local v = math.min((tPos - last).Magnitude / dt, 400)
				local was = m.tSpeed
				m.tSpeed = if was then was + (v - was) * math.min(1, dt * 4) else v
			end
			m.tLastPos = tPos
			speed = MissileRules.chaseSpeed(m.speed, m.tSpeed)
		end
		m.progress += speed * dt
		local newPos: Vector3
		if m.homing and tInfo then
			local tPos = tInfo.pos
			if not m.pursuing then
				local gap = tInfo.progress - m.progress
				local dist = (tPos - m.pos).Magnitude
				local T = MissileRules.TUNING
				if dist <= T.terminalRange or gap <= T.terminalGap then
					-- One line-of-sight cast, only once it is close: never home through a wall or a ridge.
					local cast = ctx.castWorld
					local clear = cast == nil or cast(m.pos, tPos) == nil
					m.pursuing = MissileRules.phase(gap, dist, clear) == "terminal"
				end
			end
			if m.pursuing then
				local to = tPos - m.pos
				local stepLen = speed * dt
				newPos = if to.Magnitude <= stepLen then tPos else m.pos + to.Unit * stepLen
			else
				local tpos, ttan = ctx.course(tInfo.station)
				local tLat, tVert = ItemEffects.courseOffset(tPos, tpos, ttan)
				tLat, tVert = ItemEffects.clampCorridor(tLat, tVert)
				m.lat = approach(m.lat, tLat, m.lateralRate * dt)
				m.vert = approach(m.vert, tVert, m.lateralRate * dt)
			end
		end
		if not m.pursuing then
			local cpos, tan = ctx.course(m.progress)
			local coursePt = ItemEffects.coursePoint(cpos, tan, m.lat, m.vert)
			local age = now - m.blendStart
			local blend = math.clamp(age / TUNING.missileBlendSeconds, 0, 1)
			local launchPt = m.launchPos + m.launchDir * (m.speed * age)
			newPos = launchPt:Lerp(coursePt, blend)
		end
		-- Chasing the hull it leaves the corridor, so from here the world matters. Missile v3: a wall between the shot
		-- and the hull sends it back onto the course path (blended from where it is), never into the rock.
		if m.pursuing then
			local heading = if (newPos - prev).Magnitude > 0.01 then (newPos - prev).Unit else m.dir
			local swept, struck = sweepWorld(heading, prev, newPos)
			if struck then
				m.pursuing = false
				local cpos, tan = ctx.course(m.progress)
				local lat, vert = ItemEffects.courseOffset(prev, cpos, tan)
				m.lat, m.vert = ItemEffects.clampCorridor(lat, vert)
				m.launchPos, m.launchDir, m.blendStart = prev, m.dir, now
				newPos = prev
			else
				newPos = swept
			end
		end
		local moved = newPos - prev
		if moved.Magnitude > 0.01 then
			m.dir = moved.Unit
		end
		m.pos = newPos
		if m.visual ~= nil then
			ctx.moveVisual(m.visual, CFrame.lookAt(newPos, newPos + m.dir))
		end
		if not sweepRacers(m, prev, newPos, racers) then
			return false, if m.fizzled then "fizzle" else nil
		end
		return true, nil
	end

	-- Each racer's position at the previous step, so a trap tests the path flown since then, not one sample: at 210
	-- studs/s a 10 Hz server step is 21 studs, longer than the trap's chord a few studs off its centre. Cleared while
	-- nothing is in the world, so a stale position never sweeps a racer across the map.
	local lastRacerPos: { [RacerId]: Vector3 } = {}

	local function sweptDistance(racerId: RacerId, pos: Vector3, point: Vector3): number
		local last = lastRacerPos[racerId]
		if last and (pos - last).Magnitude <= TUNING.trapSweepMax then
			return ItemEffects.segmentDistance(last, pos, point)
		end
		-- First sample, or a teleport (respawn, reset): the jump line is not a flown path.
		return (pos - point).Magnitude
	end

	local function stepTrap(t: Trap, now: number, racers: { RacerId }): (boolean, string?)
		if now >= t.expires then
			return false, "fizzle"
		end
		if now < t.armAt then
			return true, nil
		end
		for _, racerId in ipairs(racers) do
			if racerId ~= t.owner or now >= t.ownerSafeUntil then
				local info = ctx.racer(racerId)
				if info and info.active and sweptDistance(racerId, info.pos, t.pos) <= TUNING.trapHitRadius then
					local _, usedUp = strike(racerId, t.owner, "trap", t.stun, t.pos, t.form)
					if usedUp then
						return false, nil -- hit, blocked by a shield, or popped on a respawn bubble
					end
				end
			end
		end
		return true, nil
	end

	------------------------------------------------------------------------------------------------------------------
	-- Item 14: incoming warnings (5 Hz; tables reused, one small payload per warned player per tick)
	------------------------------------------------------------------------------------------------------------------
	local INCOMING = ItemRules.INCOMING
	local warnClock = 0
	local warnLastPos: { [RacerId]: Vector3 } = {}
	local warned: { [RacerId]: boolean } = {}

	-- Seconds until shot m reaches racerId, or nil when it is not coming for them. lat/vert: the racer's lane on the
	-- course (race shots only); vel: its velocity from the last tick (nil on the first sample).
	-- Missile v3: the speed a shot really flies this step (stepMissile): a locked race shot gains on its target
	-- (MissileRules.chaseSpeed), so the warning ETA (and the beep trill a dodge is timed on) must use it too.
	local function shotSpeed(m: Missile): number
		if m.homing and m.target ~= nil and not m.arena then
			return MissileRules.chaseSpeed(m.speed, m.tSpeed)
		end
		return m.speed
	end

	local function etaFor(m: Missile, racerId: RacerId, info: RacerInfo, vel: Vector3?, lat: number, vert: number, tan: Vector3): number?
		if m.owner == racerId then
			return nil
		end
		local gap, closing
		if not m.arena and not m.pursuing then
			if m.homing and m.target ~= racerId then
				return nil -- locked on someone else
			end
			gap = info.progress - m.progress
			if gap <= 0 then
				return nil
			end
			if not m.homing and (math.abs(lat - m.lat) > INCOMING.laneRadius or math.abs(vert - m.vert) > INCOMING.laneRadius) then
				return nil -- an unguided shot in another lane flies past: that is the dodge
			end
			closing = shotSpeed(m) - (if vel then vel:Dot(tan) else INCOMING.assumedSpeed)
		else
			if m.homing and m.target ~= nil and m.target ~= racerId then
				return nil
			end
			local to = info.pos - m.pos
			gap = to.Magnitude
			if gap < 0.01 then
				return 0
			end
			local u = to / gap
			local heading = m.dir:Dot(u)
			if heading < INCOMING.coneDot then
				return nil
			end
			closing = shotSpeed(m) * heading - (if vel then vel:Dot(u) else 0)
		end
		if m.homing and m.target == racerId then
			-- Missile v3: a locked shot closes slowly (catchUp), so the hit radius it lands at is a real share of the ETA.
			gap = math.max(0.01, gap - TUNING.missileHitRadius)
		end
		return ItemRules.incomingEta(gap, closing)
	end

	-- True once shot m has gone by the racer (a close call that ends here is a dodge).
	local function hasPassed(m: Missile, info: RacerInfo): boolean
		if not m.arena and not m.pursuing then
			return m.progress > info.progress + INCOMING.passMargin
		end
		return (info.pos - m.pos):Dot(m.dir) < -INCOMING.passMargin
	end

	local function scanIncoming(dt: number)
		local warn = ctx.warnIncoming
		if not warn then
			return
		end
		warnClock += dt
		if warnClock < INCOMING.tick then
			return
		end
		local tickDt = warnClock
		warnClock = 0
		if #missiles == 0 and next(warned) == nil then
			table.clear(warnLastPos)
			return
		end
		local now = ctx.now()
		local rules = arena
		local racers = if rules then rules.order() else ctx.order()
		for _, racerId in ipairs(racers) do
			local info = ctx.racer(racerId)
			if info and info.isPlayer then
				local last = warnLastPos[racerId]
				local vel: Vector3? = nil
				if last and (info.pos - last).Magnitude <= TUNING.trapSweepMax * 2 then
					vel = (info.pos - last) / tickDt
				end
				warnLastPos[racerId] = info.pos
				local best: number? = nil
				local bestShot: Missile? = nil
				local homing, count = false, 0
				local grace = immuneUntil[racerId]
				local exposed = info.active
					and not respawnProtected(racerId, now)
					and not (grace ~= nil and now < grace)
					and not ctx.isShielded(racerId)
				if exposed then
					local lat, vert, tan = 0, 0, Vector3.new(0, 0, -1)
					if not rules then
						local cpos, ctan = ctx.course(info.station)
						tan = ctan
						lat, vert = ItemEffects.courseOffset(info.pos, cpos, ctan)
					end
					for _, m in missiles do
						local calls = m.closeCalls
						if calls and calls[racerId] and hasPassed(m, info) then
							calls[racerId] = nil
							warn(racerId, { eta = -1, dodged = true })
							ctx.log(string.format("[SkyRally][ITEM] dodged racer=%s shot_by=%s", racerId, m.owner))
						end
						local eta = etaFor(m, racerId, info, vel, lat, vert, tan)
						if eta then
							count += 1
							if best == nil or eta < best then
								best = eta
								bestShot = m
								homing = m.homing
							end
							if eta <= INCOMING.closeCallEta then
								local cc = m.closeCalls
								if not cc then
									cc = {}
									m.closeCalls = cc
								end
								(cc :: { [RacerId]: boolean })[racerId] = true
							end
						end
					end
				else
					forgetCloseCalls(racerId) -- crashed, finished, shielded or spinning: no DODGED! for this one
				end
				if best then
					warned[racerId] = true
					-- Missile v3: where it comes from (flat studs from the racer) and whether it is locked on them.
					local shot = bestShot :: Missile
					local off = shot.pos - info.pos
					warn(racerId, {
						eta = math.floor(best * 100 + 0.5) / 100,
						homing = homing,
						count = count,
						dx = math.floor(off.X + 0.5),
						dz = math.floor(off.Z + 0.5),
						lock = shot.target == racerId,
					})
				elseif warned[racerId] then
					warned[racerId] = nil
					warn(racerId, { eta = -1 })
				end
			end
		end
	end

	local effects = {} :: Effects

	effects.hit = hit

	-- Magnet arrival: holder within magnetArrive (+ a few studs of server lag) of its target. Everyone sees the pop; a
	-- bot's pull ends here (a player's client ends its own pull on contact). No stun, no speed change for the target.
	local function stepMagnets(now: number)
		stepPulses(now)
		if next(magnets) == nil then
			return
		end
		for holder, m in magnets do
			local a, b = ctx.racer(holder), ctx.racer(m.target)
			if now >= m.untilT or not a or not b then
				magnets[holder] = nil
			elseif (a.pos - b.pos).Magnitude <= TUNING.magnetArrive + 6 then
				magnets[holder] = nil
				ctx.broadcast("magnetArrive", { from = a.plane, to = b.plane, pos = b.pos })
				local botId = botIdOf(holder)
				if botId then
					ctx.applyToBot(botId, { kind = "magnetEnd", seconds = 0 })
				end
				ctx.log(string.format("[SkyRally][ITEM] magnet arrive racer=%s target=%s", holder, m.target))
			end
		end
	end

	function effects.step(dt: number)
		local now = ctx.now()
		if #pending > 0 then
			local due: { PendingShot } = {}
			for i = #pending, 1, -1 do
				if pending[i].at <= now then
					table.insert(due, 1, table.remove(pending, i) :: PendingShot)
				end
			end
			for _, shot in ipairs(due) do
				launchMissile(shot)
			end
		end
		scanIncoming(dt) -- item 14 (throttled inside; a no-op without ctx.warnIncoming)
		stepMagnets(now)
		stepSpecials(now) -- items v4: rams, storms, bombs, patches, coins
		if #missiles == 0 and #traps == 0 then
			table.clear(lastRacerPos)
			return
		end
		local rules = arena
		local racers = if rules then rules.order() else ctx.order()
		for i = #missiles, 1, -1 do
			local m = missiles[i]
			local alive, fx = stepMissile(m, dt, now, racers)
			if not alive then
				removeMissile(i, fx)
			end
		end
		for i = #traps, 1, -1 do
			local alive, fx = stepTrap(traps[i], now, racers)
			if not alive then
				removeTrap(i, fx)
			end
		end
		if #traps > 0 then
			for _, racerId in ipairs(racers) do
				local info = ctx.racer(racerId)
				if info then
					lastRacerPos[racerId] = info.pos
				else
					lastRacerPos[racerId] = nil :: any
				end
			end
		else
			table.clear(lastRacerPos)
		end
	end

	function effects.clear()
		for i = #missiles, 1, -1 do
			removeMissile(i, nil)
		end
		for i = #traps, 1, -1 do
			removeTrap(i, nil)
		end
		table.clear(pending)
		table.clear(magnets)
		table.clear(pulses)
		clearSpecials()
		table.clear(immuneUntil)
		table.clear(respawnUntil)
		table.clear(respawnGranted)
		table.clear(rearmLogged)
		table.clear(lastRacerPos)
		table.clear(warnLastPos)
		table.clear(warned)
		warnClock = 0
	end

	function effects.counts(): (number, number, number)
		return #missiles, #traps, #pending
	end

	function effects.grantImmunity(racerId: RacerId, seconds: number?, asked: boolean?)
		local now = ctx.now()
		local secs = math.max(0, seconds or ItemEffects.RESPAWN_IMMUNE_SECONDS)
		local untilT = now + secs
		local current = respawnUntil[racerId]
		if current and current >= untilT then
			return
		end
		local granted = respawnGranted[racerId]
		if asked and granted and now - granted < ItemEffects.RESPAWN_IMMUNE_REARM then
			-- Asked for again inside the rearm time: what runs keeps running, nothing new starts.
			if rearmLogged[racerId] ~= granted then
				rearmLogged[racerId] = granted
				ctx.log(string.format("[SkyRally][ITEM] respawn shield racer=%s skipped=rearm last=%.1fs", racerId, now - granted))
			end
			return
		end
		local fresh = current == nil or now >= current
		respawnUntil[racerId] = untilT
		respawnGranted[racerId] = now
		-- Re-sent on an extension (clients keep the later end); logged once per window (a server-ordered respawn inside
		-- a running window, e.g. a drown answered while the client's own request is on its way, extends it).
		local info = ctx.racer(racerId)
		ctx.broadcast("respawnShield", { plane = if info then info.plane else nil, seconds = untilT - now })
		if fresh then
			ctx.log(string.format("[SkyRally][ITEM] respawn shield racer=%s seconds=%.1f", racerId, secs))
		end
	end

	function effects.isImmune(racerId: RacerId): boolean
		return respawnProtected(racerId, ctx.now())
	end

	function effects.setArena(rules: ArenaRules?)
		arena = rules
		ctx.log(string.format("[SkyRally][ITEM] arena=%s", if rules then "on" else "off"))
	end

	-- Whom a shot from racerId locks: the arena's pick in a battle; in a race (missile v3) the nearest racer ahead in
	-- reach (MissileRules.pickTarget), not merely the next one in race order.
	local function lockTarget(racerId: RacerId, homing: boolean): RacerId?
		local rules = arena
		if rules then
			return rules.target(racerId)
		end
		if not homing then
			return nil
		end
		local info = ctx.racer(racerId)
		return if info then pickAhead(racerId, info.progress) else nil
	end

	local hooks = {}

	-- The missile launch shared by red missiles, Orbit Missiles and the status shots (items v4: extra carries status).
	local function fireShots(racerId: RacerId, params: ItemRules.MissileParams, level: number, extra: { status: string, statusParams: { [string]: any } }?)
		local target = lockTarget(racerId, params.homing)
		local now = ctx.now()
		-- A bot's salvo fans out over the racers ahead (MK-style fairness); a player's keeps the nearest-ahead lock.
		local me = ctx.racer(racerId)
		local spread: { [RacerId]: number }? = nil
		if me and not me.isPlayer and arena == nil and params.homing and params.count > 1 then
			local tally: { [RacerId]: number } = {}
			if target then
				tally[target] = 1
			end
			spread = tally
		end
		for i = 1, params.count do
			local shot: PendingShot = {
				at = now + (i - 1) * params.burstInterval,
				owner = racerId,
				params = params,
				level = level,
				index = i,
				target = target,
				relock = i > 1,
				spread = spread,
				status = if extra then extra.status else nil,
				statusParams = if extra then extra.statusParams else nil,
			}
			if i == 1 then
				launchMissile(shot) -- the first shot leaves on the press, never a frame later
			else
				table.insert(pending, shot)
			end
		end
		ctx.log(string.format(
			"[SkyRally][ITEM] fx missile racer=%s level=%d count=%d target=%s%s",
			racerId,
			level,
			params.count,
			target or "none",
			if extra then " status=" .. extra.status else ""
		))
	end

	function hooks.spawnMissile(racerId: RacerId, params: ItemRules.MissileParams, level: number)
		used(racerId, "missile", level)
		fireShots(racerId, params, level, nil)
	end

	-- Missile v3: a trap held behind the racer (ItemService "Drag"); every client draws it trailing that vehicle.
	function hooks.dragTrap(racerId: RacerId, on: boolean)
		local info = ctx.racer(racerId)
		ctx.broadcast("trapDrag", { plane = if info then info.plane else nil, on = on, racer = racerId })
	end

	function hooks.applyBoost(racerId: RacerId, params: ItemRules.BoostParams, level: number)
		used(racerId, "boost", level)
		local info = ctx.racer(racerId)
		local botId = botIdOf(racerId)
		if botId then
			ctx.applyToBot(botId, { kind = "boost", seconds = params.seconds, speed = params.speed, level = level })
		else
			ctx.sendPlayer(racerId, "boost", { seconds = params.seconds, speed = params.speed, level = level })
		end
		if info then
			ctx.broadcast("boost", { plane = info.plane, level = level })
		end
		ctx.log(string.format("[SkyRally][ITEM] fx boost racer=%s level=%d speed=%d seconds=%.1f", racerId, level, params.speed, params.seconds))
	end

	function hooks.setShield(racerId: RacerId, params: ItemRules.ShieldParams, level: number)
		used(racerId, "shield", level)
		local info = ctx.racer(racerId)
		local botId = botIdOf(racerId)
		if botId then
			ctx.applyToBot(botId, { kind = "shield", seconds = params.seconds, level = level })
		else
			ctx.sendPlayer(racerId, "shield", { seconds = params.seconds, level = level })
		end
		if info then
			ctx.broadcast("shield", { plane = info.plane, seconds = params.seconds, level = level })
		end
		ctx.log(string.format("[SkyRally][ITEM] fx shield racer=%s level=%d seconds=%.1f", racerId, level, params.seconds))
	end

	function hooks.spawnTrap(racerId: RacerId, params: ItemRules.TrapParams, level: number)
		used(racerId, "trap", level)
		local info = ctx.racer(racerId)
		if not info then
			ctx.log(string.format("[SkyRally][ITEM] trap dropped racer=%s reason=no_vehicle", racerId))
			return
		end
		local now = ctx.now()
		local forward = if info.forward.Magnitude > 0.01 then info.forward.Unit else Vector3.new(0, 0, -1)
		local pos = info.pos - forward * TUNING.trapDropBehind
		for _ = 1, math.max(1, params.count) do
			local t: Trap = {
				id = newId(),
				owner = racerId,
				level = level,
				form = params.form,
				pos = pos,
				stun = params.stunSeconds,
				armAt = now + TUNING.trapArmSeconds,
				ownerSafeUntil = now + TUNING.trapOwnerGrace,
				expires = now + params.lifetime,
				visual = nil,
			}
			t.visual = ctx.spawnVisual("trap", CFrame.lookAt(pos, pos + forward), {
				owner = racerId,
				level = level,
				form = params.form,
				armSeconds = TUNING.trapArmSeconds,
			})
			table.insert(traps, t)
			if #traps > TUNING.maxTraps then
				removeTrap(1, "fizzle")
			end
		end
		ctx.log(string.format("[SkyRally][ITEM] fx trap racer=%s level=%d form=%s", racerId, level, params.form))
	end

	-- Magnet v2 (owner 2026-10-20): the closest other racer within range (ItemRules.magnetPick, the rule the holder's
	-- HUD previews), not "the racer directly ahead in race order", which was usually out of range or the wrong one. The
	-- server picks and checks the range (plus magnetRangeSlack for replication lag); the client never names a target.
	-- A battle keeps its arena pick (nearest opponent, preferring one ahead) under the same range check. The target
	-- gets no stun: arrival (effects.step) is a pop on both hulls and nothing else.
	-- Whom a magnet from racerId would lock right now: the arena's pick in a battle, else ItemRules.magnetPick; nil when
	-- nobody is within reach. Second result: the straight distance (math.huge when none).
	local function magnetTarget(racerId: RacerId, info: RacerInfo, reach: number): (RacerId?, number)
		local rules = arena
		if rules then
			local target = rules.target(racerId)
			local t = if target then ctx.racer(target) else nil
			local dist = if t then (t.pos - info.pos).Magnitude else math.huge
			if dist > reach then
				return nil, dist -- the arena pick is held to the same range
			end
			return target, dist
		end
		local cands: { ItemRules.MagnetCandidate } = {}
		for _, id in ipairs(ctx.order()) do
			local r = if id ~= racerId then ctx.racer(id) else nil
			if r and r.active then
				table.insert(cands, { id = id, pos = r.pos })
			end
		end
		local target, dist, inRange = ItemRules.magnetPick(info.pos, info.forward, cands, reach)
		if not inRange then
			return nil, dist
		end
		return target, dist
	end

	-- Locks target for the pull. False (nothing sent) when a bot's pull would run backward: it rides its racing line, so
	-- its pull is added speed and a target behind it would make that a free boost.
	local function lockMagnet(racerId: RacerId, info: RacerInfo, target: RacerId, dist: number, params: ItemRules.MagnetParams, level: number): boolean
		local tInfo = ctx.racer(target)
		local botId = botIdOf(racerId)
		if not tInfo or (botId ~= nil and tInfo.progress < info.progress) then
			return false
		end
		if botId then
			ctx.applyToBot(botId, {
				kind = "magnet",
				seconds = params.seconds,
				pull = params.pull,
				targetRacerId = target,
				level = level,
			})
		else
			ctx.sendPlayer(racerId, "magnet", {
				target = tInfo.plane,
				seconds = params.seconds,
				pull = params.pull,
				range = params.range,
				level = level,
			})
		end
		magnets[racerId] = { target = target, untilT = ctx.now() + params.seconds }
		ctx.broadcast("magnet", { from = info.plane, to = tInfo.plane, seconds = params.seconds, level = level })
		ctx.log(string.format("[SkyRally][ITEM] fx magnet racer=%s level=%d target=%s dist=%.0f range=%d", racerId, level, target, dist, params.range))
		return true
	end

	-- A pulse in flight: lock the first racer to come into reach (ItemRules.magnetDecision), else end it with the
	-- holder's "magnetMiss" once its time is up. A holder who left the race drops it silently.
	function stepPulses(now: number)
		if next(pulses) == nil then
			return
		end
		for holder, p in pulses do
			local info = ctx.racer(holder)
			if not info then
				pulses[holder] = nil
			else
				local target, dist = magnetTarget(holder, info, p.params.range + TUNING.magnetRangeSlack)
				local verdict = ItemRules.magnetDecision(target ~= nil, p.untilT - now)
				if verdict == "lock" and target and lockMagnet(holder, info, target, dist, p.params, p.level) then
					pulses[holder] = nil
				elseif p.untilT <= now then
					pulses[holder] = nil
					if not botIdOf(holder) then
						ctx.sendPlayer(holder, "magnetMiss", { range = p.params.range })
					end
					ctx.log(string.format("[SkyRally][ITEM] fx magnet racer=%s level=%d pulse ended target=none", holder, p.level))
				end
			end
		end
	end

	-- Magnet v2 (owner 2026-10-20): the closest other racer within range (ItemRules.magnetPick, the rule the holder's
	-- HUD previews), not "the racer directly ahead in race order", which was usually out of range or the wrong one. The
	-- server picks and checks the range (plus magnetRangeSlack for replication lag); the client never names a target.
	-- A battle keeps its arena pick (nearest opponent, preferring one ahead) under the same range check. The target
	-- gets no stun: arrival (effects.step) is a pop on both hulls and nothing else. A press is always spent (owner
	-- 2026-10-20: it must go like the other items): with nobody in range it fires a short pulse (fizzle burst now,
	-- stepPulses) that locks a racer who comes into range, then ends with "magnetMiss".
	function hooks.magnetPull(racerId: RacerId, params: ItemRules.MagnetParams, level: number)
		used(racerId, "magnet", level)
		local info = ctx.racer(racerId)
		if not info then
			return
		end
		local target, dist = magnetTarget(racerId, info, params.range + TUNING.magnetRangeSlack)
		if ItemRules.magnetDecision(target ~= nil, TUNING.magnetPulseSeconds) == "lock" and target and lockMagnet(racerId, info, target, dist, params, level) then
			return
		end
		ctx.broadcast("fizzle", { pos = info.pos, source = "magnet" })
		pulses[racerId] = { params = params, level = level, untilT = ctx.now() + TUNING.magnetPulseSeconds }
		ctx.log(string.format(
			"[SkyRally][ITEM] fx magnet racer=%s level=%d target=none dist=%s range=%d pulse=%.1fs",
			racerId,
			level,
			if dist < math.huge then string.format("%.0f", dist) else "-",
			params.range,
			TUNING.magnetPulseSeconds
		))
	end

	------------------------------------------------------------------------------------------------------------------
	-- Items v4: the nine specials (ItemRules.SPECIAL rows; the header has the rules)
	------------------------------------------------------------------------------------------------------------------

	-- The first active racer in race order other than `racerId` and `skip` (the leader a Storm Bolt hunts), or nil.
	local function leaderOther(racerId: RacerId, skip: RacerId?): RacerId?
		for _, id in ipairs(ctx.order()) do
			if id ~= racerId and id ~= skip then
				local r = ctx.racer(id)
				if r and r.active then
					return id
				end
			end
		end
		return nil
	end

	local function guard(racerId: RacerId, seconds: number)
		local g = ctx.guard
		if g then
			g(racerId, seconds)
		end
	end

	-- A boost from a special: a plane speed (rocket) or a cruise factor (Golden Wings, coins). auto: seconds of
	-- line-follow autopilot for a player's client (Rocket Rush). Bots get the speed (their line is their own).
	local function specialBoost(racerId: RacerId, info: RacerInfo?, seconds: number, speed: number, factor: number?, level: number, auto: number?, tag: string)
		local botId = botIdOf(racerId)
		if botId then
			ctx.applyToBot(botId, { kind = "boost", seconds = seconds, speed = speed, factor = factor, level = level })
		else
			ctx.sendPlayer(racerId, "boost", { seconds = seconds, speed = speed, factor = factor, level = level, auto = auto, item = tag })
		end
	end

	-- Ram windows (Golden Wings, Rocket Rush level two and up): a rival within RAM_RADIUS spins `spin` s (hit grace
	-- keeps it to one spin per pass); coinTrail drops a coin where it hit.
	type Ram = { untilT: number, spin: number, coinTrail: boolean, met: { [RacerId]: number } }
	local rams: { [RacerId]: Ram } = {}
	local RAM_REPEAT = 1.0 -- s before the same rival can be rammed again (a shield or an orbiter is met once, not per step)

	type Storm = {
		owner: RacerId,
		target: RacerId,
		level: number,
		p: { [string]: any },
		warnAt: number,
		strikeAt: number,
		warned: boolean,
		chained: boolean,
		reflected: boolean,
	}
	local storms: { Storm } = {}

	type Bomb = { owner: RacerId, level: number, pos: Vector3, fuseAt: number, p: { [string]: any }, visual: any }
	local bombs: { Bomb } = {}

	local function startStorm(owner: RacerId, target: RacerId, level: number, p: { [string]: any }, travel: number, chained: boolean, reflected: boolean)
		local now = ctx.now()
		local warnFor = math.min(p.warn, travel)
		local st: Storm = {
			owner = owner,
			target = target,
			level = level,
			p = p,
			warnAt = now + travel - warnFor,
			strikeAt = now + travel,
			warned = false,
			chained = chained,
			reflected = reflected,
		}
		table.insert(storms, st)
		local tInfo = ctx.racer(target)
		ctx.broadcast("stormCloud", { plane = if tInfo then tInfo.plane else nil, seconds = travel, warn = warnFor, racer = target })
		ctx.log(string.format("[SkyRally][ITEM] fx storm racer=%s level=%d target=%s travel=%.1f chained=%s", owner, level, target, travel, tostring(chained)))
	end

	-- A reflected shot or bolt goes back at whoever sent it (Bubble Guard).
	function reflectBack(from: RacerId, to: RacerId, source: string)
		if source == "storm" then
			local p = ItemRules.SPECIAL.storm_bolt[1]
			startStorm(from, to, 1, p, p.warn, true, true)
			return
		end
		launchMissile({
			at = ctx.now(),
			owner = from,
			params = ItemRules.PARAMS.missile[2],
			level = 1,
			index = 1,
			target = to,
			forceFree = true,
		})
	end

	local function stepStorms(now: number)
		for i = #storms, 1, -1 do
			local st = storms[i]
			local tInfo = ctx.racer(st.target)
			if not tInfo or not tInfo.active then
				-- The target finished or left: the bolt fizzles in its cloud.
				table.remove(storms, i)
				ctx.broadcast("fizzle", { pos = if tInfo then tInfo.pos else Vector3.zero, source = "storm" })
				ctx.log(string.format("[SkyRally][ITEM] storm fizzled racer=%s target=%s", st.owner, st.target))
			elseif not st.warned and now >= st.warnAt then
				st.warned = true
				if tInfo.isPlayer then
					ctx.sendPlayer(st.target, "stormWarn", { seconds = math.max(0, st.strikeAt - now), vehicle = tInfo.vehicle })
				end
			elseif now >= st.strikeAt then
				table.remove(storms, i)
				ctx.broadcast("stormStrike", { pos = tInfo.pos, plane = tInfo.plane })
				-- A plane's barrel roll inside the dodge window beats it (missile v3 rule; a bot throws its dice).
				local dice = ctx.random
				local rolled = ctx.rolledAt
				local how = MissileRules.evasion({
					vehicle = tInfo.vehicle,
					isBot = not tInfo.isPlayer,
					now = now,
					rolledAt = if rolled and tInfo.isPlayer then rolled(st.target) else nil,
					since = st.warnAt,
					random = if dice and not tInfo.isPlayer then dice() else 1,
				})
				if how == "roll" and not ctx.isShielded(st.target) then
					ctx.broadcast("dodge", { pos = tInfo.pos, plane = tInfo.plane, how = "roll" })
					local warn = ctx.warnIncoming
					if tInfo.isPlayer and warn then
						warn(st.target, { eta = -1, dodged = true, how = "roll" })
					end
					ctx.log(string.format("[SkyRally][ITEM] storm dodged racer=%s by=%s", st.target, st.owner))
				else
					-- A Bubble Guard that sends the bolt back also stops it chaining on (one bolt, one answer).
					local rf = reflects[st.target]
					local reflectsBefore = if rf then rf.left else 0
					local result = strike(st.target, st.owner, "storm", st.p.stun, tInfo.pos)
					local wasReflected = rf ~= nil and rf.left < reflectsBefore
					if result == "hit" and (st.p.splash or 0) > 0 then
						for _, id in ipairs(ctx.order()) do
							if id ~= st.target and id ~= st.owner then
								local r = ctx.racer(id)
								if r and r.active and (r.pos - tInfo.pos).Magnitude <= st.p.splash then
									applySlow(id, 0.6, st.p.splashSlow, "storm")
								end
							end
						end
					elseif result == "blocked" and st.p.chain and not st.chained and not st.reflected and not wasReflected then
						local nextTarget = leaderOther(st.owner, st.target)
						if nextTarget then
							startStorm(st.owner, nextTarget, st.level, st.p, st.p.warn + 0.5, true, false)
						end
					end
				end
			end
		end
	end

	local function stepBombs(now: number, racers: { RacerId }, look: (RacerId) -> RacerInfo?)
		for i = #bombs, 1, -1 do
			local b = bombs[i]
			if now >= b.fuseAt then
				table.remove(bombs, i)
				if b.visual ~= nil then
					ctx.destroyVisual(b.visual)
				end
				ctx.broadcast("bombBlast", { pos = b.pos, radius = b.p.radius })
				local hits = 0
				for _, id in ipairs(racers) do
					local r = look(id)
					if r and r.active and (r.pos - b.pos).Magnitude <= b.p.radius then
						local result = strike(id, b.owner, "bomb", b.p.stun, r.pos)
						if result == "hit" then
							hits += 1
						end
					end
				end
				if (b.p.patch or 0) > 0 then
					addZone(b.pos, b.p.radius * 0.6, b.p.patch, "boom_bomb")
				end
				ctx.log(string.format("[SkyRally][ITEM] bomb blast racer=%s level=%d radius=%d hits=%d", b.owner, b.level, b.p.radius, hits))
			end
		end
	end

	local function stepRams(now: number, racers: { RacerId }, look: (RacerId) -> RacerInfo?)
		for holder, ram in rams do
			local hInfo = look(holder)
			if now >= ram.untilT or not hInfo or not hInfo.active then
				rams[holder] = nil
			else
				for _, id in ipairs(racers) do
					if id ~= holder then
						local r = look(id)
						if r and r.active and (r.pos - hInfo.pos).Magnitude <= ItemRules.RAM_RADIUS and not spinning(id, now) and now >= (ram.met[id] or 0) then
							ram.met[id] = now + RAM_REPEAT
							local result = strike(id, holder, "ram", ram.spin, r.pos)
							if result == "hit" and ram.coinTrail then
								spawnCoins(r.pos, 1)
							end
						end
					end
				end
			end
		end
	end

	local function coinLift(racerId: RacerId, info: RacerInfo)
		local C = ItemRules.COIN
		local now = ctx.now()
		local untilT = math.min(now + C.maxSeconds, math.max(now, coinLiftUntil[racerId] or now) + C.boostSeconds)
		coinLiftUntil[racerId] = untilT
		specialBoost(racerId, info, untilT - now, ItemRules.ROCKET.cruise * C.boostFactor, C.boostFactor, 1, nil, "coin")
	end

	local function stepCoinsAndZones(now: number, racers: { RacerId }, look: (RacerId) -> RacerInfo?)
		for i = #coins, 1, -1 do
			local c = coins[i]
			if now >= c.untilT then
				table.remove(coins, i)
				if c.visual ~= nil then
					ctx.destroyVisual(c.visual)
				end
			elseif now >= c.readyAt then
				for _, id in ipairs(racers) do
					local r = look(id)
					local reach = if (coinMagnet[id] or 0) > now then ItemRules.COIN.magnetRadius else ItemRules.COIN.radius
					if r and r.active and (r.pos - c.pos).Magnitude <= reach then
						table.remove(coins, i)
						if c.visual ~= nil then
							ctx.destroyVisual(c.visual)
						end
						ctx.broadcast("coinTake", { pos = c.pos, plane = r.plane })
						coinLift(id, r)
						break
					end
				end
			end
		end
		for i = #zones, 1, -1 do
			local z = zones[i]
			if now >= z.untilT then
				table.remove(zones, i)
				if z.visual ~= nil then
					ctx.destroyVisual(z.visual)
				end
			else
				for _, id in ipairs(racers) do
					local r = look(id)
					if r and r.active and (now >= (zoneTickAt[id] or 0)) and (r.pos - z.pos).Magnitude <= z.radius then
						zoneTickAt[id] = now + ItemRules.SLOW.patchTick
						applySlow(id, z.factor, ItemRules.SLOW.patchTick + 0.15, z.source)
					end
				end
			end
		end
	end

	function stepSpecials(now: number)
		if next(rams) == nil and #storms == 0 and #bombs == 0 and #coins == 0 and #zones == 0 and next(reflects) == nil then
			return
		end
		local rules = arena
		local racers = if rules then rules.order() else ctx.order()
		-- One ctx.racer per racer per step (each call builds a table): up to maxCoins coins times the field otherwise.
		local seen: { [RacerId]: RacerInfo } = {}
		local missing: { [RacerId]: boolean } = {}
		local function look(id: RacerId): RacerInfo?
			local v: RacerInfo? = seen[id]
			if v == nil and not missing[id] then
				v = ctx.racer(id)
				if v then
					seen[id] = v
				else
					missing[id] = true
				end
			end
			return v
		end
		stepRams(now, racers, look)
		stepStorms(now)
		stepBombs(now, racers, look)
		stepCoinsAndZones(now, racers, look)
		for id, rf in reflects do
			if now >= rf.untilT then
				reflects[id] = nil
			end
		end
	end

	function clearSpecials()
		table.clear(rams)
		table.clear(storms)
		table.clear(reflects)
		table.clear(slows)
		table.clear(zoneTickAt)
		table.clear(coinMagnet)
		table.clear(coinLiftUntil)
		for _, b in bombs do
			if b.visual ~= nil then
				ctx.destroyVisual(b.visual)
			end
		end
		table.clear(bombs)
		for _, c in coins do
			if c.visual ~= nil then
				ctx.destroyVisual(c.visual)
			end
		end
		table.clear(coins)
		for _, z in zones do
			if z.visual ~= nil then
				ctx.destroyVisual(z.visual)
			end
		end
		table.clear(zones)
	end

	-- Where a Boom Bomb comes down: `throw` studs ahead, onto the first ground under that point within 80 studs (1.5
	-- above it), or hanging where it is as an air mine when there is none (planes over a void).
	local function bombLanding(info: RacerInfo, throw: number): Vector3
		local forward = if info.forward.Magnitude > 0.01 then info.forward.Unit else Vector3.new(0, 0, -1)
		local flat = Vector3.new(forward.X, 0, forward.Z)
		local dir = if flat.Magnitude > 0.05 then flat.Unit else forward
		local ahead = info.pos + dir * throw
		local cast = ctx.castWorld
		if cast then
			local hitPos = cast(ahead + UP * 12, ahead - UP * 80)
			if hitPos then
				return hitPos + UP * 1.5
			end
		end
		return ahead
	end

	function hooks.special(racerId: RacerId, kind: string, p: { [string]: any }, level: number)
		local info = ctx.racer(racerId)
		local now = ctx.now()
		ctx.notifyUsed(racerId, { color = kind, kind = kind, level = level })
		if not info then
			ctx.log(string.format("[SkyRally][ITEM] special dropped racer=%s kind=%s reason=no_vehicle", racerId, kind))
			return
		end
		if kind == "rocket_rush" then
			local leader = leaderOther(racerId)
			local lInfo = if leader then ctx.racer(leader) else nil
			local gap = if lInfo then lInfo.progress - info.progress else 0
			local seconds = ItemRules.rocketSeconds(p.seconds, p.speed, gap)
			guard(racerId, seconds)
			specialBoost(racerId, info, seconds, p.speed, nil, level, math.max(0, seconds - (p.freeSteer or 0)), kind)
			if p.shove then
				rams[racerId] = { untilT = now + seconds, spin = p.shoveSpin, coinTrail = false, met = {} }
			end
			ctx.broadcast("rocket", { plane = info.plane, seconds = seconds, level = level })
			ctx.log(string.format("[SkyRally][ITEM] fx rocket racer=%s level=%d seconds=%.1f gap=%.0f", racerId, level, seconds, gap))
		elseif kind == "golden_wings" then
			guard(racerId, p.seconds)
			specialBoost(racerId, info, p.seconds, ItemRules.ROCKET.cruise * p.factor, p.factor, level, nil, kind)
			rams[racerId] = { untilT = now + p.seconds, spin = p.spin, coinTrail = p.coinTrail == true, met = {} }
			ctx.broadcast("golden", { plane = info.plane, seconds = p.seconds, level = level })
			ctx.log(string.format("[SkyRally][ITEM] fx golden racer=%s level=%d seconds=%.1f", racerId, level, p.seconds))
		elseif kind == "orbit_missiles" then
			fireShots(racerId, ItemRules.orbitShot(level), level, nil)
		elseif kind == "storm_bolt" then
			local target = leaderOther(racerId)
			if not target then
				ctx.broadcast("fizzle", { pos = info.pos, source = "storm" })
				ctx.log(string.format("[SkyRally][ITEM] fx storm racer=%s level=%d target=none", racerId, level))
				return
			end
			startStorm(racerId, target, level, p, p.travel, false, false)
		elseif kind == "boom_bomb" then
			local land = bombLanding(info, p.throw)
			table.insert(bombs, {
				owner = racerId,
				level = level,
				pos = land,
				fuseAt = now + p.fuse,
				p = p,
				visual = ctx.spawnVisual("bomb", CFrame.new(land), { fuse = p.fuse, radius = p.radius, owner = racerId, from = info.pos }),
			})
			ctx.log(string.format("[SkyRally][ITEM] fx bomb racer=%s level=%d at=(%.0f,%.0f,%.0f) fuse=%.1f", racerId, level, land.X, land.Y, land.Z, p.fuse))
		elseif kind == "frost_shot" or kind == "coin_burst" then
			fireShots(racerId, ItemRules.statusShot(kind, level), level, { status = kind :: string, statusParams = p } :: any)
		elseif kind == "bubble_guard" then
			guard(racerId, p.seconds)
			reflects[racerId] = { untilT = now + p.window, left = p.reflects, bolts = p.bolts == true }
			local botId = botIdOf(racerId)
			if botId then
				ctx.applyToBot(botId, { kind = "shield", seconds = p.seconds, level = level })
			else
				ctx.sendPlayer(racerId, "shield", { seconds = p.seconds, level = level, bubble = true, window = p.window })
			end
			ctx.broadcast("shield", { plane = info.plane, seconds = p.seconds, level = level, bubble = true, window = p.window })
			ctx.log(string.format("[SkyRally][ITEM] fx bubble racer=%s level=%d seconds=%.1f window=%.1f", racerId, level, p.seconds, p.window))
		else
			ctx.log(string.format("[SkyRally][ITEM] special unknown racer=%s kind=%s", racerId, kind))
		end
	end

	effects.hooks = hooks
	return effects
end

------------------------------------------------------------------------------------------------------------------------
-- Live wiring (server only)
------------------------------------------------------------------------------------------------------------------------

ItemEffects.active = nil :: Effects?
ItemEffects.FX_FOLDER = "SkyRallyItemFX"

local function rgb(t: { number }?): Color3
	if not t then
		return Color3.fromRGB(255, 255, 255)
	end
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function plainPart(name: string, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function fxFolder(): Folder
	local existing = workspace:FindFirstChild(ItemEffects.FX_FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = ItemEffects.FX_FOLDER
	f.Parent = workspace
	return f
end

-- Server body of a missile: visible on its own (neon bolt) so a client without ItemClient still sees it; ItemClient
-- hides it locally and renders a smoothed copy with a trail and flame.
local function makeMissile(cf: CFrame, info: { [string]: any }): Part
	local status = if type(info.status) == "string" then info.status else nil
	local tint = if status then ItemRules.COLOR_RGB[status] else nil
	local p = plainPart("ItemMissile", Enum.PartType.Block, Vector3.new(1.1, 1.1, 3.4), cf, rgb(tint or ItemRules.COLOR_RGB.red), Enum.Material.Neon, nil)
	-- Attributes before parenting: the client classifies the part from them the moment it replicates.
	p:SetAttribute("Kind", "missile")
	if status then
		p:SetAttribute("Status", status) -- items v4: ItemClient tints its copy (frost blue, coin gold)
	end
	p:SetAttribute("Owner", tostring(info.owner))
	p:SetAttribute("Level", info.level)
	p:SetAttribute("Homing", info.homing == true)
	-- Item 14: the racer a homing shot is locked on ("" otherwise); that racer's client blinks it with the beeps.
	p:SetAttribute("Target", if info.homing == true and type(info.target) == "string" then info.target else "")
	p.Parent = fxFolder()
	return p
end

-- Where a trap visual sits and how it faces. Slicks lie flat on the ground when there is solid ground within reach under
-- the drop point (cars); a slick dropped in mid-air (planes) tilts toward the racers coming up behind so it reads as a
-- puddle rather than an edge-on sliver. The trap's hit volume stays at the drop point either way (ItemRules.TUNING).
local SLICK_SIZE = 11
local SLICK_REACH = 9 -- ground further than this under the drop point is not "on the ground"
local function slickFrame(cf: CFrame): (CFrame, boolean)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip: { Instance } = { fxFolder() }
	local planes = workspace:FindFirstChild("Planes")
	if planes then
		table.insert(skip, planes)
	end
	params.FilterDescendantsInstances = skip
	params.RespectCanCollide = true
	params.IgnoreWater = true -- a slick over the sea belongs in the air, not on the water
	local pos = cf.Position
	local hit = workspace:Raycast(pos + UP * 4, -UP * (SLICK_REACH + 4), params)
	-- Paved tracks drive on a collidable deck under a non-colliding skin (the hub's TrackRibbon pavers sit 1.1 studs
	-- higher): a slick laid on the deck was buried under the stones (Studio 2026-10-19). Lie on a visible upward skin
	-- just above the collidable ground instead.
	if hit and hit.Normal.Y > 0.5 then
		params.RespectCanCollide = false
		local skin = workspace:Raycast(pos + UP * 4, -UP * (SLICK_REACH + 4), params)
		if skin and skin.Normal.Y > 0.5 and skin.Position.Y > hit.Position.Y and skin.Position.Y - hit.Position.Y < 2.5 then
			hit = skin
		end
	end
	if hit and hit.Normal.Y > 0.5 then
		local n = hit.Normal
		local forward = cf.LookVector - n * cf.LookVector:Dot(n)
		if forward.Magnitude < 0.05 then
			forward = Vector3.new(0, 0, -1) - n * -n.Z
		end
		return CFrame.lookAt(hit.Position + n * 0.15, hit.Position + n * 0.15 + forward, n), true
	end
	local n = (-cf.LookVector * 0.8 + UP * 0.6)
	local right = UP:Cross(n)
	if n.Magnitude < 0.05 or right.Magnitude < 0.1 then
		return cf, false
	end
	return CFrame.fromMatrix(pos, right.Unit, n.Unit), false
end

-- Slick (level one): a flat oil puddle, the owned oil_slick texture on a SurfaceGui of an invisible plate (a Decal would
-- vanish with the plate's Transparency). Both faces show it so the tilted mid-air one reads from either side.
local function buildSlick(m: Model, cf: CFrame, ItemTexAssets: { [string]: string }): (Part, boolean)
	local frame, grounded = slickFrame(cf)
	local plate = plainPart("Body", Enum.PartType.Block, Vector3.new(SLICK_SIZE, 0.1, SLICK_SIZE), frame, Color3.new(0, 0, 0), Enum.Material.SmoothPlastic, m)
	plate.Transparency = 1
	for _, face in { Enum.NormalId.Top, Enum.NormalId.Bottom } do
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Oil" .. face.Name
		gui.Face = face
		gui.LightInfluence = 0.4
		gui.ResetOnSpawn = false
		gui.Parent = plate
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.fromScale(1, 1)
		img.BackgroundTransparency = 1
		img.Image = ItemTexAssets.oil_slick
		img.Parent = gui
	end
	return plate, grounded
end

-- Mine (levels two and three): the navy naval-mine mesh (assets/models/items_v1, nose-less ball, any spin is fine) with a
-- neon tip-light ball above the top lug that ItemClient blinks (blinking on the client keeps it off the network).
-- Level three adds a bubble shell. Falls back to the old faceted mine until the mesh cache has loaded.
local function buildMine(m: Model, cf: CFrame, scale: number, green: Color3, mesh: MeshPart?): Part
	local body: Part
	if mesh then
		local mp = mesh:Clone()
		mp.Name = "Body"
		mp.Size = mesh.Size * 1.15 * scale
		mp.CFrame = cf
		mp.Parent = m
		body = mp :: any
	else
		body = plainPart("Body", Enum.PartType.Block, Vector3.new(2.6, 2.6, 2.6) * scale, cf * CFrame.Angles(math.rad(45), math.rad(45), 0), green:Lerp(Color3.new(0, 0, 0), 0.35), Enum.Material.Metal, m)
		plainPart("Facet", Enum.PartType.Block, Vector3.new(2.3, 2.3, 2.3) * scale, cf * CFrame.Angles(0, math.rad(45), math.rad(45)), green, Enum.Material.SmoothPlastic, m)
		for i = 0, 3 do
			local a = math.rad(i * 90)
			plainPart("Spike" .. i, Enum.PartType.Block, Vector3.new(0.5, 0.5, 1.6) * scale, cf * CFrame.Angles(0, a, 0) * CFrame.new(0, 0, -1.7 * scale), Color3.fromRGB(70, 60, 50), Enum.Material.Metal, m)
		end
	end
	local lift = if mesh then 1.9 else 1.7
	local light = plainPart("Light", Enum.PartType.Ball, Vector3.new(0.9, 0.9, 0.9) * scale, cf * CFrame.new(0, lift * scale, 0), Color3.fromRGB(255, 60, 40), Enum.Material.Neon, m)
	local pl = Instance.new("PointLight")
	pl.Name = "Blink"
	pl.Color = Color3.fromRGB(255, 70, 50)
	pl.Range = 10
	pl.Brightness = 2
	pl.Shadows = false
	pl.Parent = light
	return body
end

local function makeTrap(cf: CFrame, info: { [string]: any }): Model
	local ItemArt = require(Shared:WaitForChild("ItemArt"))
	local ItemTexAssets = require(Shared:WaitForChild("ItemTexAssets")) :: { [string]: string }
	local form = tostring(info.form)
	local m = Instance.new("Model")
	m.Name = "ItemTrap"
	local green = rgb(ItemRules.COLOR_RGB.green)
	local body: Part
	local grounded = false
	if form == "slick" then
		body, grounded = buildSlick(m, cf, ItemTexAssets)
	else
		body = buildMine(m, cf, 1.0, green, ItemArt.peek("mine"))
		if form == "bubble" then
			local shell = plainPart("Bubble", Enum.PartType.Ball, Vector3.new(7, 7, 7), cf, green, Enum.Material.ForceField, m)
			shell.Transparency = 0.15
		end
	end
	m.PrimaryPart = body
	-- Pivot on the upright drop frame (not a rotated body), so the client's spin and bob turn about world up. The slick's
	-- own frame already is its plate (flat on the ground, or tilted in the air); the mesh mine (whose own pivot is the
	-- upload's) and the fallback's 45-degree body are put back on the drop frame.
	if form ~= "slick" then
		body.PivotOffset = body.CFrame:ToObjectSpace(cf)
	end
	m:SetAttribute("Kind", "trap")
	m:SetAttribute("Form", form)
	m:SetAttribute("Grounded", grounded)
	m:SetAttribute("Owner", tostring(info.owner))
	m:SetAttribute("ArmSeconds", info.armSeconds)
	m:SetAttribute("SpawnedAt", workspace:GetServerTimeNow())
	m.Parent = fxFolder()
	return m
end

-- Items v4 world pieces, all anchored, non-colliding and non-queryable (FlightController's step raycast must never meet
-- them). The look is particles on a small core; none sits over the chase camera (they stay where they were placed).
local function sparkEmitter(parent: Instance, color: Color3, rate: number, size: number, speed: number)
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(color)
	pe.LightEmission = 1
	pe.Rate = rate
	pe.Lifetime = NumberRange.new(0.25, 0.5)
	pe.Speed = NumberRange.new(speed * 0.5, speed)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new(size, 0)
	pe.Transparency = NumberSequence.new(0.1, 1)
	pe.Parent = parent
	return pe
end

-- Boom Bomb: a dark round bomb with a sparking fuse (Fuse attribute: the seconds left at the drop, for the client blink).
local function makeBomb(cf: CFrame, info: { [string]: any }): Model
	local m = Instance.new("Model")
	m.Name = "ItemBomb"
	local body = plainPart("Body", Enum.PartType.Ball, Vector3.new(3.2, 3.2, 3.2), cf, rgb(ItemRules.COLOR_RGB.boom_bomb), Enum.Material.SmoothPlastic, m)
	local fuse = plainPart("Fuse", Enum.PartType.Ball, Vector3.new(0.7, 0.7, 0.7), cf * CFrame.new(0, 1.9, 0), Color3.fromRGB(255, 170, 60), Enum.Material.Neon, m)
	sparkEmitter(fuse, Color3.fromRGB(255, 200, 90), 40, 0.6, 6)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 60)
	light.Range = 12
	light.Brightness = 2
	light.Shadows = false
	light.Parent = fuse
	m.PrimaryPart = body
	m:SetAttribute("Kind", "bomb")
	m:SetAttribute("Owner", tostring(info.owner))
	m:SetAttribute("Fuse", info.fuse)
	m:SetAttribute("Radius", info.radius)
	m:SetAttribute("SpawnedAt", workspace:GetServerTimeNow())
	m.Parent = fxFolder()
	return m
end

-- A coin: a small gold disc standing up with a glint.
local function makeCoin(cf: CFrame): Part
	local p = plainPart("ItemCoin", Enum.PartType.Cylinder, Vector3.new(0.4, 2.4, 2.4), cf * CFrame.Angles(0, 0, 0), rgb(ItemRules.COLOR_RGB.coin_burst), Enum.Material.Metal, nil)
	p.Reflectance = 0.2
	sparkEmitter(p, Color3.fromRGB(255, 236, 150), 4, 0.5, 2)
	p:SetAttribute("Kind", "coin")
	p.Parent = fxFolder()
	return p
end

-- A slow patch: a thin see-through disc on the spot (ice blue for frost, smoke grey for a bomb), with a few motes.
local function makePatch(cf: CFrame, info: { [string]: any }): Part
	local r = if type(info.radius) == "number" then info.radius else 10
	local frost = info.source == "frost_shot"
	local color = if frost then rgb(ItemRules.COLOR_RGB.frost_shot) else Color3.fromRGB(90, 90, 100)
	local disc = plainPart("ItemPatch", Enum.PartType.Cylinder, Vector3.new(0.3, r * 2, r * 2), cf * CFrame.Angles(0, 0, math.rad(90)), color, if frost then Enum.Material.Ice else Enum.Material.SmoothPlastic, nil)
	disc.Transparency = 0.55
	sparkEmitter(disc, color, 6, 0.8, 1.5)
	disc:SetAttribute("Kind", "patch")
	disc:SetAttribute("Source", tostring(info.source))
	disc.Parent = fxFolder()
	return disc
end

-- Repaints item pods from ItemRules.POD_RGB (kit/Gameplay paints Yellow/Green/Rainbow red). Idempotent.
function ItemEffects.paintPods(boosts: Instance)
	local ItemArt = require(Shared:WaitForChild("ItemArt"))
	for _, pod in ipairs(boosts:GetChildren()) do
		if pod:IsA("BasePart") and pod:GetAttribute("ItemPodSpawn") == true then
			local podType = pod:GetAttribute("PodType")
			local podClass = ItemRules.classifyPod(podType)
			local color = ItemRules.podRgb(podType)
			local core = pod:FindFirstChild(pod.Name .. "_CoreVisual")
			-- A mystery cube's glass never takes its plan colour: the colour is the secret (ItemRules MYSTERY).
			if podClass == "item" and color and core and core:IsA("BasePart") and core:GetAttribute("PodArt") ~= "mystery" then
				-- Balloon art tints (and keeps the rainbow balloon white) through ItemArt; the plain fallback ball just takes
				-- the pod colour as before.
				if not ItemArt.paintCore(core, podType) then
					core.Color = rgb(color)
				end
			end
		end
	end
end

-- Context over FlightServer records, AIRacers bots and the active spline. Modules load lazily so the pure engine
-- above loads under Lune without them.
function ItemEffects.liveContext(order: () -> { RacerId }): Context
	local Players = game:GetService("Players")
	local server = (script.Parent :: Instance).Parent :: Instance
	local ItemService = (require :: any)(server:WaitForChild("ItemService"))
	local FlightServer = (require :: any)(server:WaitForChild("FlightServer"))
	local AIRacers = (require :: any)(server:WaitForChild("AIRacers"))
	local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
	local remote: RemoteEvent = ItemService.ensureRemote()

	-- Race bots first, then the battle arena's own bots (ItemService.setArena; ids never overlap).
	local function findBot(botId: number): any
		for _, bot in ipairs(AIRacers.bots) do
			if bot.id == botId then
				return bot
			end
		end
		local arenaHooks = ItemService.arena()
		return if arenaHooks then arenaHooks.findBot(botId) else nil
	end

	-- In a battle an eliminated entrant (or everyone once it is over) can be neither hit nor targeted.
	local function arenaAllows(racerId: RacerId): boolean
		local arenaHooks = ItemService.arena()
		if not arenaHooks then
			return true
		end
		local ok = arenaHooks.canAct(racerId)
		return ok
	end

	-- Same start-line rule as RaceManager's standings: a lap-1 racer still behind the line (station near the end of the
	-- loop) is just behind the start, not nearly a lap ahead.
	local function progressOf(lap: number, station: number, len: number): number
		if lap == 1 and station > len - 350 then
			return station - len
		end
		return (lap - 1) * len + station
	end

	local function playerOf(racerId: RacerId): Player?
		local kind, num = ItemService.parseRacerId(racerId)
		if kind ~= "player" or not num then
			return nil
		end
		return Players:GetPlayerByUserId(num)
	end

	-- X-01 world sweeps: only what a vehicle would hit stops a shot. Vehicles (players and bots), item fx, boss hazards
	-- and characters are left out; non-collidable decor, pods, rings and triggers are passed by RespectCanCollide; the
	-- terrain sea and the battle tide (a CanQuery-off part) never stop one. The exclude list is rebuilt once a second.
	local worldParams = RaycastParams.new()
	worldParams.FilterType = Enum.RaycastFilterType.Exclude
	worldParams.RespectCanCollide = true
	worldParams.IgnoreWater = true
	local worldFilterAt = -math.huge
	local function castWorld(from: Vector3, to: Vector3): (Vector3?, Vector3?)
		local d = to - from
		if d.Magnitude < 1e-3 then
			return nil, nil
		end
		local now = os.clock()
		if now - worldFilterAt >= 1 then
			worldFilterAt = now
			local list: { Instance } = {}
			for _, name in { "Planes", ItemEffects.FX_FOLDER, "BossHazards" } do
				local f = workspace:FindFirstChild(name)
				if f then
					table.insert(list, f)
				end
			end
			for _, p in Players:GetPlayers() do
				if p.Character then
					table.insert(list, p.Character)
				end
			end
			worldParams.FilterDescendantsInstances = list
		end
		local r = workspace:Raycast(from, d, worldParams)
		if r then
			return r.Position, r.Normal
		end
		return nil, nil
	end

	local ctx: Context = {
		now = os.clock,
		order = order,
		racer = function(racerId: RacerId): RacerInfo?
			local kind, num = ItemService.parseRacerId(racerId)
			if not num then
				return nil
			end
			local _, len = SplineUtils.loadWaypoints()
			if kind == "player" then
				local player = Players:GetPlayerByUserId(num)
				local rec = if player then FlightServer.records[player] else nil
				if not player or not rec or not rec.hull or not rec.hull.Parent then
					return nil
				end
				return {
					pos = rec.hull.Position,
					forward = rec.hull.CFrame.LookVector,
					station = rec.station,
					progress = progressOf(rec.lap, rec.station, len),
					-- A crashing plane is mid-tumble/respawn on the client; hitting it would stack two failures.
					active = not rec.finished and player:GetAttribute("Crashing") ~= true and arenaAllows(racerId),
					isPlayer = true,
					botId = nil,
					plane = rec.plane,
					vehicle = if rec.plane and rec.plane:GetAttribute("VehicleType") == "car" then "car" else "plane",
				}
			end
			local bot = findBot(num)
			if not bot or not bot.hull or not bot.hull.Parent then
				return nil
			end
			return {
				pos = bot.hull.Position,
				forward = bot.hull.CFrame.LookVector,
				station = bot.station,
				progress = progressOf(bot.lap, bot.station, len),
				active = not bot.finished and arenaAllows(racerId),
				isPlayer = false,
				botId = num,
				plane = bot.plane,
				vehicle = if bot.isCar then "car" else "plane",
			}
		end,
		course = function(station: number): (Vector3, Vector3)
			local pos, tan = SplineUtils.sampleAtStation(station)
			return pos, tan
		end,
		isShielded = function(racerId: RacerId): boolean
			return ItemService.isShielded(racerId)
		end,
		sendPlayer = function(racerId: RacerId, kind: string, payload: { [string]: any })
			local player = playerOf(racerId)
			if player then
				remote:FireClient(player, "ItemEffect", kind, payload)
			end
		end,
		broadcast = function(fx: string, payload: { [string]: any })
			remote:FireAllClients("ItemFx", fx, payload)
		end,
		notifyUsed = function(racerId: RacerId, payload: { [string]: any })
			local player = playerOf(racerId)
			if player then
				remote:FireClient(player, "ItemUsed", payload)
			end
		end,
		applyToBot = function(botId: number, effect: BotEffect)
			-- Looked up per call: AIRacers may replace ItemService.applyToBot after this context was built.
			ItemService.applyToBot(botId, effect)
		end,
		spawnVisual = function(kind: string, cf: CFrame, info: { [string]: any }): any
			if kind == "missile" then
				return makeMissile(cf, info)
			elseif kind == "bomb" then
				return makeBomb(cf, info)
			elseif kind == "coin" then
				return makeCoin(cf)
			elseif kind == "patch" then
				return makePatch(cf, info)
			end
			return makeTrap(cf, info)
		end,
		moveVisual = function(visual: any, cf: CFrame)
			if typeof(visual) == "Instance" and visual:IsA("BasePart") then
				visual.CFrame = cf
			end
		end,
		destroyVisual = function(visual: any)
			if typeof(visual) == "Instance" then
				visual:Destroy()
			end
		end,
		log = function(line: string)
			print(line)
		end,
		castWorld = castWorld,
		-- Items 14 and 18 go out through ItemService's remote (looked up per call, like applyToBot).
		noteHit = function(victim: RacerId, attacker: RacerId, source: string): (string, number)
			return ItemService.noteHit(victim, attacker, source)
		end,
		warnIncoming = function(racerId: RacerId, payload: { [string]: any })
			ItemService.sendIncoming(racerId, payload)
		end,
		-- The hub is free roam: its loop is a road, not a race line, and players spend their time on the plaza.
		-- Per group (phase 2b) the mode is the stepping instance's (ItemEffects.scopeMode), never the hub's workspace one.
		freeRoam = function(): boolean
			local scopeMode = ItemEffects.scopeMode
			if scopeMode then
				return scopeMode() == "hub"
			end
			return workspace:GetAttribute("RaceMode") == "hub"
		end,
		-- Missile v3 counterplay (looked up per call).
		rolledAt = function(racerId: RacerId): number?
			return ItemService.lastRoll(racerId)
		end,
		consumeDrag = function(racerId: RacerId): boolean
			return ItemService.consumeDrag(racerId)
		end,
		random = math.random,
		-- Items v4 (looked up per call).
		guard = function(racerId: RacerId, seconds: number)
			ItemService.guard(racerId, seconds)
		end,
		absorb = function(racerId: RacerId): boolean
			return ItemService.absorbHit(racerId)
		end,
	}
	return ctx
end

-- Fallback bot reactions until AIRacers registers its own (ItemService.setBotHitHandler / setBotEffectHandler):
-- a hit lowers baseSpeed for the stun (AIRacers eases toward it, so the bot visibly drops back) and cancels its
-- boost; boost and magnet reuse the bot's own boost timer. Restored by tick() or clear().
local function makeBotFallback(): ((number, BotEffect) -> (), () -> (), (boolean) -> ())
	local server = (script.Parent :: Instance).Parent :: Instance
	local AIRacers = (require :: any)(server:WaitForChild("AIRacers"))
	type SlowEntry = { bot: any, base: number, untilT: number }
	local slowed: { [number]: SlowEntry } = {}

	local function findBot(botId: number): any
		for _, bot in ipairs(AIRacers.bots) do
			if bot.id == botId then
				return bot
			end
		end
		return nil
	end

	local function apply(botId: number, effect: BotEffect)
		local bot = findBot(botId)
		if not bot then
			return
		end
		if effect.kind == "hit" then
			local entry = slowed[botId]
			if entry == nil or entry.bot ~= bot then
				-- First hit (or a respawned bot table): remember the real pace once, so overlapping hits never
				-- compound the slow-down or restore a slowed value.
				local fresh: SlowEntry = { bot = bot, base = bot.baseSpeed, untilT = 0 }
				slowed[botId] = fresh
				bot.baseSpeed = fresh.base * TUNING.botHitSpeedFactor
				entry = fresh
			end
			local e = entry :: SlowEntry
			e.untilT = math.max(e.untilT, os.clock() + effect.seconds)
			bot.boostTimer = 0
		elseif effect.kind == "boost" or effect.kind == "magnet" then
			bot.boostTimer = math.max(bot.boostTimer, effect.seconds)
		end
	end

	local function restore(all: boolean)
		local now = os.clock()
		for botId, entry in pairs(slowed) do
			if all or now >= entry.untilT then
				entry.bot.baseSpeed = entry.base
				slowed[botId] = nil
			end
		end
	end

	return apply, function()
		restore(false)
	end, restore
end

-- One live engine with its own bot fallback (slowed bots are per engine): the started one, and per group one per
-- RaceInstance (enableScopes).
type Built = { engine: Effects, fallback: (number, BotEffect) -> (), tick: () -> () }
local function buildEngine(order: () -> { RacerId }): Built
	local engine = ItemEffects.new(ItemEffects.liveContext(order))
	local fallback, tick, restore = makeBotFallback()
	local baseClear = engine.clear
	engine.clear = function()
		baseClear()
		restore(true)
	end
	return { engine = engine, fallback = fallback, tick = tick }
end

-- Phase 2b: per-group scoping (nil on the single-race path). scopeMode is the stepping instance's RaceMode.
ItemEffects.scopeMode = nil :: (() -> any)?
ItemEffects.routeImmunity = nil :: ((player: Player, asked: boolean) -> ())?

export type ScopeApi = {
	current: () -> number,
	liveIds: () -> { number },
	instanceOf: (player: Player) -> number,
	run: (id: number, fn: (...any) -> ...any, ...any) -> ...any,
	state: (name: string, factory: () -> any) -> any,
	attr: (name: string) -> any,
}

-- Per group (docs/design/PER_GROUP_RACES.md, phase 2b): ItemEffects.active answers the running scope's engine (the
-- started one in the hub scope; one per RaceInstance, made on first use), each live instance's engine steps in its
-- own scope every Heartbeat, a bot hit uses the fallback of the engine that landed it, and a respawn shield goes to
-- the engine of the player's instance. Only called by the boot script when RaceFlowRules.PER_GROUP is true.
function ItemEffects.enableScopes(api: ScopeApi, order: () -> { RacerId })
	local base: Effects? = rawget(ItemEffects :: any, "active")
	rawset(ItemEffects :: any, "active", nil)
	local baseFallback = ItemEffects.baseFallback
	local function scoped(): Built
		return api.state("ItemEffects", function(): any
			return buildEngine(order)
		end)
	end
	setmetatable(ItemEffects :: any, {
		__index = function(_: any, k: string): any
			if k ~= "active" then
				return nil
			end
			if api.current() == 0 then
				return base
			end
			return scoped().engine
		end,
		__newindex = function(t: any, k: string, v: any)
			if k == "active" and api.current() == 0 then
				base = v
			elseif k ~= "active" then
				rawset(t, k, v)
			end
		end,
	})
	ItemEffects.scopeMode = function(): any
		return api.attr("RaceMode")
	end
	local server = (script.Parent :: Instance).Parent :: Instance
	local ItemService = (require :: any)(server:WaitForChild("ItemService"))
	ItemService.setBotFallback(function(botId: number, effect: BotEffect)
		if api.current() == 0 then
			if baseFallback then
				baseFallback(botId, effect)
			end
		else
			scoped().fallback(botId, effect)
		end
	end)
	ItemEffects.routeImmunity = function(player: Player, asked: boolean)
		api.run(api.instanceOf(player), function()
			local e = ItemEffects.active
			if e then
				e.grantImmunity(ItemService.playerRacerId(player.UserId), ItemEffects.RESPAWN_IMMUNE_SECONDS, asked)
			end
		end)
	end
	game:GetService("RunService").Heartbeat:Connect(function(dt: number)
		for _, id in api.liveIds() do
			local ok, err = pcall(api.run, id, function()
				local built = scoped()
				built.engine.step(dt)
				built.tick()
			end)
			if not ok then
				print(string.format("[SkyRally][ITEM] instance %d effects step error %s", id, tostring(err)))
			end
		end
	end)
end

-- The started engine's bot fallback (enableScopes keeps it for the hub scope).
ItemEffects.baseFallback = nil :: ((number, BotEffect) -> ())?

-- Builds the live effects once, installs the bot fallback, and steps on Heartbeat. Returns the running effects; pass
-- effects.hooks to ItemService.start.
function ItemEffects.start(order: () -> { RacerId }): Effects
	local running = ItemEffects.active
	if running then
		return running
	end
	local RunService = game:GetService("RunService")
	local server = (script.Parent :: Instance).Parent :: Instance
	local ItemService = (require :: any)(server:WaitForChild("ItemService"))
	local built = buildEngine(order)
	local engine = built.engine
	local fallback, tick = built.fallback, built.tick
	ItemService.setBotFallback(fallback)
	ItemEffects.baseFallback = fallback
	-- G2: every respawn path ends in FlightServer.respawnAtLastCheckpoint, which stamps the player's LastRespawnClock
	-- (client- and server-driven: a crash, a drown, a boundary return, a battle ctx.respawn). Each stamp is a fresh
	-- respawn protection; the attribute is the one signal all of them share. LastRespawnAsked, written just before it,
	-- says whether the player's own client asked (held to RESPAWN_IMMUNE_REARM).
	local Players = game:GetService("Players")
	local function watchRespawns(player: Player)
		player:GetAttributeChangedSignal("LastRespawnClock"):Connect(function()
			local asked = player:GetAttribute("LastRespawnAsked") == true
			local route = ItemEffects.routeImmunity
			if route then
				route(player, asked) -- per group: the engine of the player's instance
				return
			end
			engine.grantImmunity(ItemService.playerRacerId(player.UserId), ItemEffects.RESPAWN_IMMUNE_SECONDS, asked)
		end)
	end
	Players.PlayerAdded:Connect(watchRespawns)
	for _, player in Players:GetPlayers() do
		watchRespawns(player)
	end
	RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(function()
			engine.step(dt)
		end)
		if not ok then
			-- One bad frame must not stop every later projectile; log and keep stepping.
			print("[SkyRally][ITEM] effects step error " .. tostring(err))
		end
		tick()
	end)
	fxFolder()
	-- Warm the item mesh cache (mine) off the race thread; makeTrap only peeks and uses the old faceted mine until it is in.
	task.spawn(function()
		require(Shared:WaitForChild("ItemArt")).prepare()
	end)
	ItemEffects.active = engine
	print("[SkyRally][ITEM] effects started (missile, boost, shield, trap, magnet, items v4 specials)")
	return engine
end

return ItemEffects
