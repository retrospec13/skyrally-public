--!strict
-- Hoard scoring (LAUNCH_PROGRESSION section 2b, FOREST-BATTLE; TEST_LIST_LAUNCH L74). Pure: no services, no instances,
-- no yields. The server mode (server/battle/modes/Hoard) feeds it positions, hits and the battle clock (seconds since
-- GO) and builds its visuals from what it returns; tools/tests/hoard_spec.luau specs every rule and
-- tools/tests/hoard_flow_spec.luau runs the mode end to end through the real BattleCore.
--
-- Rules (numbers from FOREST-1's modes.battle.rules where the plan gives them; OURS marks launch defaults):
-- * Acorns grow at the plan's pickup anchors: every anchor holds one at GO, and a taken acorn regrows at its anchor
--   `respawn` seconds later (OURS 10).
-- * An entrant whose vehicle passes within pickupRadius of a ready acorn takes it. The path between two checks counts
--   (a fast plane cannot skip one between server frames). At most carryMax (10) are carried; a full sack leaves
--   acorns where they are.
-- * Flying through YOUR home ring banks everything carried: the path crosses the ring's disc within radius + ringSlack,
--   or passes within radius + ringCore of its centre. Another entrant's ring does nothing. A path longer than maxStep
--   (a boundary put-back), or the first move after the vehicle stood still for stillFor (a crash respawn: the wreck
--   tumbles in place, then jumps to its pad), is a teleport: it never counts as a pass or a pickup sweep.
-- * A landed hit drops half of what the victim carries, rounded up (OURS: a hit on a carrier always costs at least one
--   acorn). Dropped acorns scatter round the victim and fall to the ground (the mode probes it); once landed anyone
--   can take them (the victim too), and they rot dropLifetime (OURS 30 s) after the drop. A player who leaves drops
--   its whole sack the same way and is out.
-- * First to depositToWin (20) banked wins at once. At the 3-minute cap the most banked wins.
-- * Tie rule (cap): equal banked -> the one that reached that total first; then more carried; then more hits landed;
--   then a player over a bot; then the lower spawn slot. Never random. Leavers rank below everyone still in (a later
--   exit higher). The cap has no winner when nobody banked an acorn.
-- The bot helpers at the end (target choice, when to fly home, ring approach, wide turns) are pure too, so the arena
-- bots' objective play is specced without Studio.

local HoardRules = {}

HoardRules.DEFAULTS = table.freeze({
	carryMax = 10, -- section 2b
	depositToWin = 20, -- section 2b
	hitDropFraction = 0.5, -- section 2b: "a hit drops half of what you carry"
	respawn = 10, -- OURS seconds for an anchor to regrow its acorn
	pickupRadius = 14, -- OURS studs (a plane passes at 100-200 studs/s; coins use 13, the key 16)
	looseReachAbove = 8, -- OURS: a landed acorn is also taken from up to this much higher (planes skim, not scrape)
	dropDelay = 0.8, -- OURS: a dropped acorn cannot be taken before this, even when it lands sooner
	dropLifetime = 30, -- OURS seconds before an untaken dropped acorn rots
	ringSlack = 4, -- OURS: the disc counts out to radius + slack (the rim is part of the ring)
	ringCore = 2, -- OURS: passing within radius + core of the centre counts from any direction
	maxStep = 90, -- OURS studs: a longer path between two checks is a teleport, not flight
	-- OURS: slower than this counts as standing still (a crashed plane tumbles in place; a plane in flight, even
	-- stunned, does 40+ studs/s) ...
	stillSpeed = 30,
	-- ... and the first move after standing still this long is a teleport (crash respawn), not flight. Short network
	-- holds (the server sees a remote hull in bursts) stay well under it.
	stillFor = 0.3,
})

-- Seat colours for the home rings (ring i is seat i's: the plan lays spawn pad i beside home ring i).
HoardRules.RING_COLOURS = table.freeze({ "BLUE", "RED", "GREEN", "PURPLE" }) :: { string }

export type Config = {
	carryMax: number,
	depositToWin: number,
	hitDropFraction: number,
	respawn: number,
	pickupRadius: number,
	looseReachAbove: number,
	dropDelay: number,
	dropLifetime: number,
	ringSlack: number,
	ringCore: number,
	maxStep: number,
	stillSpeed: number,
	stillFor: number,
}

-- One entrant's motion between checks (HoardRules.advance).
export type Motion = {
	last: Vector3?, -- position at the previous check
	lastAt: number,
	movedAt: number, -- the last check at which it was moving
}

export type Seat = {
	id: string,
	isPlayer: boolean,
	slot: number,
}

export type Ring = {
	name: string,
	pos: Vector3,
	axis: Vector3, -- unit, horizontal: the fly-through direction (either sense counts)
	radius: number,
}

export type Entry = {
	id: string,
	isPlayer: boolean,
	slot: number,
	ring: number, -- index into State.rings
	carried: number,
	deposited: number,
	reachedAt: number?, -- when `deposited` reached its current total (tie rule)
	collected: number,
	dropped: number,
	hitsLanded: number,
	out: boolean,
	outAt: number?,
}

-- "ready": visible and takeable; "growing": an anchor waiting to regrow (hidden); "falling": a dropped acorn on its
-- way down (visible, not takeable until readyAt).
export type AcornState = "ready" | "growing" | "falling"

export type Acorn = {
	id: number, -- anchor acorns use the anchor index; dropped ones count up from LOOSE_ID_BASE + 1
	pos: Vector3, -- where it hangs (anchor) or where it lands (dropped)
	anchor: number?,
	state: AcornState,
	readyAt: number,
	expiresAt: number?,
}

export type Event = {
	kind: string, -- "ready" (regrown or landed) | "expired" (a dropped acorn rotted)
	acorn: Acorn,
}

export type State = {
	cfg: Config,
	entries: { [string]: Entry },
	ids: { string }, -- seat order
	rings: { Ring },
	acorns: { Acorn }, -- anchors first, then dropped ones
	nextId: number,
}

HoardRules.LOOSE_ID_BASE = 1000

local function num(v: any): number?
	return if type(v) == "number" and v == v then v else nil
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

------------------------------------------------------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------------------------------------------------------

-- Config from TrackData.modes.battle.rules (carryMax, depositToWin, hitDropFraction, and optional acornRespawn), the
-- rest from DEFAULTS.
function HoardRules.config(rules: any?): Config
	local r: any = if type(rules) == "table" then rules else {}
	local d = HoardRules.DEFAULTS
	local carry = num(r.carryMax)
	local win = num(r.depositToWin)
	local frac = num(r.hitDropFraction)
	return {
		carryMax = if carry and carry >= 1 then math.floor(carry) else d.carryMax,
		depositToWin = if win and win >= 1 then math.floor(win) else d.depositToWin,
		hitDropFraction = if frac then math.clamp(frac, 0, 1) else d.hitDropFraction,
		respawn = num(r.acornRespawn) or d.respawn,
		pickupRadius = num(r.pickupRadius) or d.pickupRadius,
		looseReachAbove = d.looseReachAbove,
		dropDelay = d.dropDelay,
		dropLifetime = d.dropLifetime,
		ringSlack = d.ringSlack,
		ringCore = d.ringCore,
		maxStep = d.maxStep,
		stillSpeed = d.stillSpeed,
		stillFor = d.stillFor,
	}
end

-- A plan home ring ({name, pos, yaw (degrees), radius}) as a Ring. The fly-through axis is the yaw's look vector
-- (CFrame.Angles(0, yaw, 0).LookVector, the convention tools/map/tests/test_forest1 checks the pass against).
function HoardRules.ringFromPlan(r: any, index: number): Ring?
	if type(r) ~= "table" or typeof(r.pos) ~= "Vector3" then
		return nil
	end
	local yaw = math.rad(num(r.yaw) or 0)
	return {
		name = if type(r.name) == "string" then r.name else "HomeRing_" .. tostring(index),
		pos = r.pos,
		axis = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw)),
		radius = num(r.radius) or 14,
	}
end

-- Seat -> home ring: seat i flies through ring i; extra seats share rings in turn.
function HoardRules.ringFor(slot: number, ringCount: number): number
	if ringCount <= 0 then
		return 0
	end
	return ((math.max(slot, 1) - 1) % ringCount) + 1
end

function HoardRules.new(seats: { Seat }, anchors: { Vector3 }, rings: { Ring }, cfg: Config?): State
	local state: State = {
		cfg = cfg or HoardRules.config(nil),
		entries = {},
		ids = {},
		rings = rings,
		acorns = {},
		nextId = HoardRules.LOOSE_ID_BASE,
	}
	for _, s in seats do
		if not state.entries[s.id] then
			state.entries[s.id] = {
				id = s.id,
				isPlayer = s.isPlayer,
				slot = s.slot,
				ring = HoardRules.ringFor(s.slot, #rings),
				carried = 0,
				deposited = 0,
				reachedAt = nil,
				collected = 0,
				dropped = 0,
				hitsLanded = 0,
				out = false,
				outAt = nil,
			}
			table.insert(state.ids, s.id)
		end
	end
	for i, p in anchors do
		table.insert(state.acorns, { id = i, pos = p, anchor = i, state = "ready", readyAt = 0, expiresAt = nil })
	end
	return state
end

function HoardRules.entry(state: State, id: string): Entry?
	return state.entries[id]
end

function HoardRules.find(state: State, acornId: number): Acorn?
	for _, a in state.acorns do
		if a.id == acornId then
			return a
		end
	end
	return nil
end

------------------------------------------------------------------------------------------------------------------------
-- Geometry
------------------------------------------------------------------------------------------------------------------------

-- Distance from p to the segment a -> b (a nil: to the point b).
function HoardRules.segmentDistance(a: Vector3?, b: Vector3, p: Vector3): number
	if not a then
		return (p - b).Magnitude
	end
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-9 then
		return (p - b).Magnitude
	end
	local k = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return (p - (a + ab * k)).Magnitude
end

-- The path a check sweeps: nil `from` (first check) or a teleport-length step sweeps only the end point.
local function sweepFrom(cfg: Config, from: Vector3?, to: Vector3): Vector3?
	if from and (to - from).Magnitude <= cfg.maxStep then
		return from
	end
	return nil
end

function HoardRules.newMotion(): Motion
	return { last = nil, lastAt = 0, movedAt = 0 }
end

-- Records the vehicle at `pos` at time t and returns where this check's path starts (the `from` of collect, deposit
-- and foreignRing; nil: only `pos` counts). It is the previous position, except on the first check and on the first
-- move after the vehicle stood still for stillFor: a crashed plane tumbles in place for a second and then respawns on
-- its spawn pad, and on FOREST-1 that pad lies 40 studs from its home ring with the ring's windmill 46 studs the other
-- way, so the jump from a wreck at the mill crosses the ring well inside maxStep. Skipping the sweep of a short step
-- after a real stop costs nothing: both of its ends are checked.
function HoardRules.advance(cfg: Config, m: Motion, pos: Vector3, t: number): Vector3?
	local prev, prevAt = m.last, m.lastAt
	m.last, m.lastAt = pos, t
	if not prev then
		m.movedAt = t
		return nil
	end
	if (pos - prev).Magnitude <= cfg.stillSpeed * math.max(t - prevAt, 0) then
		return prev
	end
	local resumed = prevAt - m.movedAt >= cfg.stillFor
	m.movedAt = t
	return if resumed then nil else prev
end

-- Whether a vehicle moving from -> to takes this acorn. A landed (dropped) acorn's reach is centred above it, so a
-- plane skimming the grass takes it without touching the ground.
function HoardRules.touches(cfg: Config, acorn: Acorn, from: Vector3?, to: Vector3): boolean
	local a = sweepFrom(cfg, from, to)
	if acorn.anchor then
		return HoardRules.segmentDistance(a, to, acorn.pos) <= cfg.pickupRadius
	end
	local lift = cfg.looseReachAbove * 0.5
	return HoardRules.segmentDistance(a, to, acorn.pos + Vector3.new(0, lift, 0)) <= cfg.pickupRadius + lift
end

-- Whether the path from -> to flies through the ring (see the header).
function HoardRules.ringPass(cfg: Config, ring: Ring, from: Vector3?, to: Vector3): boolean
	local a = sweepFrom(cfg, from, to)
	if HoardRules.segmentDistance(a, to, ring.pos) <= ring.radius + cfg.ringCore then
		return true
	end
	if not a then
		return false
	end
	local da = (a - ring.pos):Dot(ring.axis)
	local db = (to - ring.pos):Dot(ring.axis)
	if (da > 0 and db > 0) or (da < 0 and db < 0) or da == db then
		return false
	end
	local k = da / (da - db)
	local cross = a + (to - a) * k
	return (cross - ring.pos).Magnitude <= ring.radius + cfg.ringSlack
end

------------------------------------------------------------------------------------------------------------------------
-- Play
------------------------------------------------------------------------------------------------------------------------

-- Regrows anchors and lands dropped acorns whose time has come, and rots old dropped ones. Returns what changed.
function HoardRules.tick(state: State, t: number): { Event }
	local events: { Event } = {}
	local i = 1
	while i <= #state.acorns do
		local a = state.acorns[i]
		if a.state ~= "ready" and t >= a.readyAt then
			a.state = "ready"
			table.insert(events, { kind = "ready", acorn = a })
		end
		local expires = a.expiresAt
		if a.anchor == nil and expires and t >= expires then
			table.remove(state.acorns, i)
			table.insert(events, { kind = "expired", acorn = a })
		else
			i += 1
		end
	end
	return events
end

-- Takes every ready acorn the path from -> to touches, up to the carry cap. Returns the acorns taken (anchors start
-- regrowing; dropped ones are gone).
function HoardRules.collect(state: State, id: string, from: Vector3?, to: Vector3, t: number): { Acorn }
	local taken: { Acorn } = {}
	local e = state.entries[id]
	local cfg = state.cfg
	if not e or e.out or e.carried >= cfg.carryMax then
		return taken
	end
	local i = 1
	while i <= #state.acorns do
		local a = state.acorns[i]
		if a.state == "ready" and HoardRules.touches(cfg, a, from, to) then
			e.carried += 1
			e.collected += 1
			table.insert(taken, a)
			if a.anchor then
				a.state = "growing"
				a.readyAt = t + cfg.respawn
				i += 1
			else
				table.remove(state.acorns, i)
			end
			if e.carried >= cfg.carryMax then
				break
			end
		else
			i += 1
		end
	end
	return taken
end

-- Banks the sack when the path from -> to flies through the entrant's own ring. Returns the number banked (0: no pass,
-- an empty sack, or out).
function HoardRules.deposit(state: State, id: string, from: Vector3?, to: Vector3, t: number): number
	local e = state.entries[id]
	if not e or e.out or e.carried <= 0 then
		return 0
	end
	local ring = state.rings[e.ring]
	if not ring or not HoardRules.ringPass(state.cfg, ring, from, to) then
		return 0
	end
	local n = e.carried
	e.carried = 0
	e.deposited += n
	e.reachedAt = t
	return n
end

-- The index of someone else's home ring the path flies through (nil: none, or the entrant's own).
function HoardRules.foreignRing(state: State, id: string, from: Vector3?, to: Vector3): number?
	local e = state.entries[id]
	for i, ring in state.rings do
		if (not e or i ~= e.ring) and HoardRules.ringPass(state.cfg, ring, from, to) then
			return i
		end
	end
	return nil
end

-- Half of `carried`, rounded up (at least one from a non-empty sack), never more than carried.
function HoardRules.dropCount(carried: number, fraction: number): number
	if carried <= 0 or fraction <= 0 then
		return 0
	end
	return math.clamp(math.ceil(carried * fraction - 1e-9), 1, carried)
end

-- A landed hit at time t. Returns how many acorns the victim drops (the mode scatters them with addLoose).
function HoardRules.hit(state: State, victimId: string, attackerId: string?, _t: number): number
	local v = state.entries[victimId]
	if not v or v.out then
		return 0
	end
	if attackerId and attackerId ~= victimId then
		local a = state.entries[attackerId]
		if a then
			a.hitsLanded += 1
		end
	end
	local n = HoardRules.dropCount(v.carried, state.cfg.hitDropFraction)
	v.carried -= n
	v.dropped += n
	return n
end

-- A player left: out for the rest of the battle; returns its sack (dropped where it was last seen).
function HoardRules.leave(state: State, id: string, t: number): number
	local e = state.entries[id]
	if not e or e.out then
		return 0
	end
	e.out = true
	e.outAt = t
	local n = e.carried
	e.carried = 0
	e.dropped += n
	return n
end

-- Dropped acorns landing at `spots`, takeable once landed (readyIn seconds, never before dropDelay).
function HoardRules.addLoose(state: State, spots: { Vector3 }, t: number, readyIn: number?): { Acorn }
	local out: { Acorn } = {}
	local cfg = state.cfg
	for _, p in spots do
		state.nextId += 1
		local a: Acorn = {
			id = state.nextId,
			pos = p,
			anchor = nil,
			state = "falling",
			readyAt = t + math.max(readyIn or 0, cfg.dropDelay),
			expiresAt = t + cfg.dropLifetime,
		}
		table.insert(state.acorns, a)
		table.insert(out, a)
	end
	return out
end

-- n scatter points round `center` (golden-angle spiral, flat), at most `radius` out. Deterministic.
function HoardRules.scatter(center: Vector3, n: number, radius: number): { Vector3 }
	local out: { Vector3 } = {}
	for k = 1, n do
		local a = k * 2.399963
		local r = radius * math.sqrt(k / math.max(n, 1))
		table.insert(out, center + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
	end
	return out
end

------------------------------------------------------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------------------------------------------------------

-- true when a ranks above b (see the tie rule in the header).
function HoardRules.better(state: State, a: string, b: string): boolean
	local ea, eb = state.entries[a], state.entries[b]
	if not ea or not eb then
		return ea ~= nil
	end
	if ea.out ~= eb.out then
		return eb.out
	end
	if ea.out then
		local oa, ob = ea.outAt or 0, eb.outAt or 0
		if oa ~= ob then
			return oa > ob
		end
	end
	if ea.deposited ~= eb.deposited then
		return ea.deposited > eb.deposited
	end
	local ra, rb = ea.reachedAt or math.huge, eb.reachedAt or math.huge
	if ra ~= rb then
		return ra < rb
	end
	if ea.carried ~= eb.carried then
		return ea.carried > eb.carried
	end
	if ea.hitsLanded ~= eb.hitsLanded then
		return ea.hitsLanded > eb.hitsLanded
	end
	if ea.isPlayer ~= eb.isPlayer then
		return ea.isPlayer
	end
	return ea.slot < eb.slot
end

-- Every entrant, best first.
function HoardRules.ranking(state: State): { string }
	local ids = table.clone(state.ids)
	table.sort(ids, function(a: string, b: string): boolean
		return HoardRules.better(state, a, b)
	end)
	return ids
end

-- The entrant that has banked depositToWin (nil: nobody yet).
function HoardRules.winner(state: State): string?
	for _, id in HoardRules.ranking(state) do
		local e = state.entries[id]
		if not e.out and e.deposited >= state.cfg.depositToWin then
			return id
		end
	end
	return nil
end

-- The 3-minute cap: most banked wins (tie rule); no winner when nobody banked an acorn.
function HoardRules.resolveCap(state: State): (string?, { string })
	local ranking = HoardRules.ranking(state)
	local best = if ranking[1] then state.entries[ranking[1]] else nil
	local winner = if best and not best.out and best.deposited > 0 then best.id else nil
	return winner, ranking
end

-- Board value (the HUD board orders by it, higher first): the entrant's place in the ranking, so the live board always
-- shows the order the cap would give (banked, then who reached that total first, then carried, ...) and the results
-- panel never contradicts the board it replaces. Out entrants -1. `ranking`: HoardRules.ranking(state), when the
-- caller scores the whole field at once.
function HoardRules.boardScore(state: State, id: string, ranking: { string }?): number
	local e = state.entries[id]
	if not e or e.out then
		return -1
	end
	local order = ranking or HoardRules.ranking(state)
	local i = table.find(order, id)
	return if i then #order - i else 0
end

-- Board text: "12" banked, "12 +4" with four carried.
function HoardRules.scoreText(state: State, id: string): string
	local e = state.entries[id]
	if not e then
		return ""
	elseif e.out then
		return "LEFT"
	elseif e.carried > 0 then
		return string.format("%d +%d", e.deposited, e.carried)
	end
	return tostring(e.deposited)
end

-- Results row text.
function HoardRules.resultText(state: State, id: string): string
	local e = state.entries[id]
	if not e then
		return ""
	elseif e.out then
		return string.format("LEFT (%d banked)", e.deposited)
	end
	return string.format("%d BANKED", e.deposited)
end

-- The player's objective line (TrackFlow scales it into the plank: kept under ~40 characters). ringName: the colour
-- word of the entrant's home ring ("BLUE").
function HoardRules.hudText(state: State, id: string, ringName: string): string
	local e = state.entries[id]
	local cfg = state.cfg
	if not e then
		return ""
	elseif e.out then
		return "OUT - spectating"
	elseif e.carried >= cfg.carryMax then
		return string.format("SACK FULL - FLY THROUGH THE %s RING", ringName)
	elseif e.carried > 0 then
		return string.format("BANKED %d/%d - CARRY %d/%d - %s RING", e.deposited, cfg.depositToWin, e.carried, cfg.carryMax, ringName)
	elseif e.deposited == 0 then
		return string.format("GRAB ACORNS  -  YOUR HOME: %s RING", ringName)
	end
	return string.format("BANKED %d/%d  -  GRAB ACORNS", e.deposited, cfg.depositToWin)
end

------------------------------------------------------------------------------------------------------------------------
-- Pods
------------------------------------------------------------------------------------------------------------------------

-- Item pods for the hoard: the acorn anchors belong to the acorns, so every `every`-th anchor carries a weapon pod
-- `lift` studs above its acorn (a higher line to fly for items), kept `margin` under the ceiling.
function HoardRules.podSpots(anchors: { Vector3 }, every: number, lift: number, ceiling: number?, margin: number?): { Vector3 }
	local out: { Vector3 } = {}
	local step = math.max(1, math.floor(every))
	local top = if ceiling then ceiling - (margin or 12) else math.huge
	for i = step, #anchors, step do
		local p = anchors[i]
		table.insert(out, Vector3.new(p.X, math.min(p.Y + lift, top), p.Z))
	end
	return out
end

------------------------------------------------------------------------------------------------------------------------
-- Bot helpers (server/battle/modes/Hoard.botGoal)
------------------------------------------------------------------------------------------------------------------------

export type HomeSense = {
	nearestAcorn: number?, -- studs to the acorn it would take next (nil: none worth chasing)
	homeDist: number,
	timeLeft: number,
	speed: number,
}

-- Whether a bot should fly home and bank now, and why (goal label).
function HoardRules.botWantsHome(e: Entry, cfg: Config, s: HomeSense): (boolean, string)
	if e.carried <= 0 then
		return false, "empty"
	elseif e.carried >= cfg.carryMax then
		return true, "full"
	elseif e.deposited + e.carried >= cfg.depositToWin then
		return true, "winning"
	elseif s.timeLeft <= s.homeDist / math.max(s.speed, 1) + 6 then
		return true, "clock"
	elseif s.nearestAcorn == nil then
		return true, "none left"
	elseif e.carried >= math.ceil(cfg.carryMax * 0.6) and s.nearestAcorn > 110 then
		return true, "far"
	elseif e.carried >= 3 and s.homeDist < 70 and s.nearestAcorn > 40 then
		return true, "passing"
	end
	return false, "collect"
end

-- Whether `target` lies inside the turning circle on its side (a vehicle that turns at most with `turnRadius` would
-- orbit it forever): flat test, nose `forward`.
function HoardRules.turnBlocked(pos: Vector3, forward: Vector3, target: Vector3, turnRadius: number): boolean
	local f = flat(forward)
	local to = flat(target - pos)
	if f.Magnitude < 1e-3 or to.Magnitude < 1 then
		return false
	end
	f = f.Unit
	local right = Vector3.new(-f.Z, 0, f.X)
	local side = if to:Dot(right) >= 0 then right else -right
	return (to - side * turnRadius).Magnitude < turnRadius * 0.9
end

-- A goal straight ahead (at the target's height) to open the turn before coming back round.
function HoardRules.openTurn(pos: Vector3, forward: Vector3, target: Vector3): Vector3
	local f = flat(forward)
	local dir = if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
	local ahead = pos + dir * 90
	return Vector3.new(ahead.X, target.Y, ahead.Z)
end

-- Where a bot aims to fly through its ring: a point on the ring's axis on the bot's side, half its distance along the
-- axis out (at most 40), so it curls onto the axis and crosses the disc nearly square instead of edge-on.
function HoardRules.ringAim(ring: Ring, pos: Vector3): Vector3
	local along = (pos - ring.pos):Dot(ring.axis)
	return ring.pos + ring.axis * math.clamp(along * 0.5, -40, 40)
end

export type PickOpts = {
	skip: { [number]: boolean }?, -- acorns this bot gave up on
	claims: { [number]: number }?, -- acorn id -> distance of ANOTHER bot heading for it
	current: number?, -- the acorn it is chasing (kept unless another is clearly better)
	turnRadius: number,
}

-- Cost of chasing `a` (lower is better): distance, how far off the nose, inside the turning circle, contested.
function HoardRules.acornCost(pos: Vector3, forward: Vector3, a: Acorn, opts: PickOpts): number
	local to = a.pos - pos
	local d = to.Magnitude
	local f = flat(forward)
	local dot = if d > 1e-3 and f.Magnitude > 1e-3 then f.Unit:Dot(flat(to).Unit) else 1
	local cost = d + (1 - dot) * 45
	if HoardRules.turnBlocked(pos, forward, a.pos, opts.turnRadius) then
		cost += 90
	end
	local claims = opts.claims
	local rival = if claims then claims[a.id] else nil
	if rival and rival < d then
		cost += 160
	end
	if opts.current == a.id then
		cost *= 0.75
	end
	return cost
end

-- The acorn a bot should chase: ready ones, and dropped ones landing within 1.5 s; nil when none.
function HoardRules.pickAcorn(state: State, pos: Vector3, forward: Vector3, t: number, opts: PickOpts): Acorn?
	local best: Acorn? = nil
	local bestCost = math.huge
	local skip = opts.skip
	for _, a in state.acorns do
		local usable = a.state == "ready" or (a.state == "falling" and a.readyAt - t <= 1.5)
		if usable and not (skip and skip[a.id]) then
			local c = HoardRules.acornCost(pos, forward, a, opts)
			if c < bestCost then
				best, bestCost = a, c
			end
		end
	end
	return best
end

return HoardRules
