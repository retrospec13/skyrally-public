--!strict
-- ISLAND water battle rules (LAUNCH_PROGRESSION section 2b, ISLAND-BATTLE; TEST_LIST_LAUNCH L73). Pure data and pure
-- functions (it only requires its sibling rule modules): no instances, no yields, so the server mode
-- (server/battle/modes/Water) and the Lune specs (tools/tests/water_spec.luau, water_flow_spec.luau) evaluate one rule
-- set.
--
-- The lives half is SurvivalRules as-is ("3 lives, item combat as SNOW"): an item hit and a drown both cost one life
-- through SurvivalRules.hit, so out / last standing / the cap and its tie rule are the survival ones. This module adds
-- what the water battle has on top:
-- * Tide (TrackData.modes.battle baseLevel / tideSteps / drownDepth): the water stands at baseLevel until a step's
--   atSeconds (seconds after GO), then climbs to that step's level over RISE_SECONDS. A step never lowers the water.
--   levelAt(t) is the one level every check reads (the visible water plane, drowning, the HUD, the bots).
-- * Drowning (the car rule, CarController WATER_SINK_DEPTH): a car whose bottom (hull minus ride height) sits more than
--   drownDepth under the tide level is caught. One replicated sample is not enough (GRACE), and a respawned car is
--   immune for IMMUNE seconds while its teleport replicates. A drown is a life lost that credits nobody; the car comes
--   back on a safe pad (pickSafeSpawn: dry through the coming step, never the decks, away from the drown point and from
--   live rivals), facing its authored heading or the longest dry run.
-- * Shrinking area: a ground-height grid sampled over the arena (the server raycasts it once at the start) gives the
--   dry share per tide level (log and toasts) and lets bots plan on dry ground only.
-- * Bots (botGoal): flee ground that floods within LOOKAHEAD seconds; otherwise take the nearest ready pod on ground
--   that stays dry, hunt the nearest rival on dry ground they can reach, or patrol dry ground ahead.
-- * Car bots keep off the galleon at launch (Course.board = BOTS_BOARD = false). The decks and the upper gangways are
--   ringed by the deep basin, and BattleBots meets water deeper than maxWaterDepth (the tide included) by holding still
--   and swinging toward open ground: a bot that slides off a ramp edge or reaches a deck rail can freeze there (a
--   31-stud deck is narrower than its ~43-stud turn). So a beach bot never targets deck pods, deck or ramp cells, or
--   rivals on a ramp, never plans a way across a raised ramp, and never flees up a gangway; one already high on a ramp
--   (its ground on the ramp surface, RAMP_SNAP) finishes the trip it is on. With board = true the gangway trips below
--   run (routeStep: a turn-straight-turn line-up onto the ramp line, then up it) and a bot on the decks stays there.
-- * Stuck watchdog (stuck): an arena bot that stays within STUCK_MOVE studs for STUCK_SECONDS (cruising it covers
--   ~200) is wedged; the server sets it down on a dry beach pad, no life lost.
-- Numbers marked OURS are launch defaults (section 2b: the N64 battle values are unmeasured).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local battleShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("battle")
local SurvivalRules = require(battleShared:WaitForChild("SurvivalRules"))
local BattleRules = require(battleShared:WaitForChild("BattleRules"))

local WaterRules = {}

WaterRules.DEFAULT_DROWN = 2.2 -- CarConfig.WATER_SINK_DEPTH: the plan's drownDepth when it gives none
WaterRules.RISE_SECONDS = 4 -- OURS: each step's water climbs over this long, so a car on the edge can still drive out
WaterRules.WARN_SECONDS = 8 -- OURS: toast and HUD warning this long before a step starts
WaterRules.GRACE = 0.15 -- OURS: seconds continuously under before a drown counts (one replicated sample is not enough)
-- OURS: seconds after a tide respawn with no second drown (the respawn teleport replicates). Kept clear of the car
-- client's 3 s LATE_REPLY_WINDOW: a second CheckpointRespawn to the same pad inside it reads as a stale reply and is
-- dropped, which would cost a life and leave the car in the water.
WaterRules.IMMUNE = 3.5
-- Bot planning (OURS).
WaterRules.LOOKAHEAD = 10 -- bots plan against the tide this many seconds ahead
-- Bots call ground dry only this far above the drown line (was 0.4). The Studio drowns at the steps turned out not to
-- be grid error (the 6-stud grid matches the car's solid ground within ~0.3 on the beach): the car bots ignored the
-- tide, rode up non-colliding parts and swung wide turns into the deep (fixed in BattleBots / WALL_DEPTH below). The
-- wider margin stays as slack for the bots' turning arcs off the planned straight lines.
WaterRules.SAFE_MARGIN = 1.2
WaterRules.CLIMB = 4 -- largest height change between path samples a car drives (more is a hull side or a drop)
-- OURS: car bots treat water deeper than WALL_DEPTH (under the drown depth) as a wall (BattleBots), measured against
-- the tide WALL_AHEAD seconds on (Water.waterLevel), so a bot never drives onto ground a rising or imminent step is
-- about to take (Studio: bots swung onto 19.6-21.8 ground in the second before a step and drowned in the rise).
WaterRules.WALL_DEPTH = 2.0
WaterRules.WALL_AHEAD = 2
-- OURS: a planned way (pod, hunt, patrol) keeps this much shallower than the drown depth, inside the wall with room
-- for the 6-stud grid cells (a way planned to within the last 0.2 studs stopped bots at its first deep cell).
WaterRules.PATH_MARGIN = 0.4
WaterRules.DECK_TOLERANCE = 3 -- ground this far under the main deck still counts as the decks
WaterRules.DECK_REACH = 70 -- the decks lie within this many studs (flat) of a gangway top
WaterRules.ATTACK_RANGE = 420 -- BattleCore's item target range: a bot aims at the nearest rival inside it
-- OURS: a human rival counts as this many times closer when a bot picks whom to aim at and whom to hunt. With plain
-- nearest-rival targeting the three bots shot and trapped each other out in 20-60 s (Studio) and a player parked on
-- the decks won by default; now the bots' fire leans on the human while he is within reach.
WaterRules.PREFER_PLAYER = 3
WaterRules.TURN_RADIUS = 48 -- car bots turn on ~43 studs at cruise (BattleBots: 72 studs/s, 95 deg/s); plan a little wider
WaterRules.APPROACH = 30 -- line-up pose: this far before a ramp end, heading along the ramp
WaterRules.APPROACH_DECK = 8 -- the decks are narrow: the line-up pose inboard of a gangway top
WaterRules.CARROT = 22 -- the waypoint runs this far ahead along the planned path
WaterRules.CONE = 0.5 -- the lane behind a ramp end: lateral offset up to LANE + CONE x distance behind it
WaterRules.LANE = 4 -- ramp half-width a bot keeps to (the gangway is 9 wide)
WaterRules.EXIT_DECK = 14 -- past the top: onto the main deck through the bulwark opening
WaterRules.EXIT_SAND = 20 -- past the foot: off the sandbar
WaterRules.BOTS_BOARD = false -- car bots plan no gangway trips (see the header)
WaterRules.RAMP_FOOT = 4 -- a ramp's first studs (barely raised) are beach for planning; past them it is off limits
WaterRules.RAMP_COMMIT = 14 -- this far up a ramp (studs from the foot, ~3.3 high) a bot finishes the trip it is on
-- OURS: ... but only with its ground within this of the ramp's surface there: a bot on the sand UNDER a raised gangway
-- (same X-Z as the ramp) was sent "up" it and sat wedged against the underside (ISLAND-2 Studio trace).
WaterRules.RAMP_SNAP = 2.5
WaterRules.STUCK_MOVE = 10 -- watchdog: a bot that stays within this many studs (flat) ...
WaterRules.STUCK_SECONDS = 3 -- ... for this long is wedged
WaterRules.UNSTICK_CLEAR = 25 -- a wedged bot is set down on a pad at least this far from where it froze
-- Safe respawns (trap audit G1 / I2-01, I2-10). A drowned car comes back on a pad that stays dry through the coming step,
-- off the decks, at least SAFE_CLEAR from where it went under and as far from live rivals as the pads allow (rivals
-- past RIVAL_CAP all count the same, so the far pads tie and the higher ground decides). A boundary return also prefers
-- pads near where the car left (NEAR_WEIGHT studs of rival distance per stud), so it is never sent across the cove.
WaterRules.SAFE_CLEAR = 25
WaterRules.RIVAL_CAP = 120
WaterRules.NEAR_WEIGHT = 0.5
-- An authored pad heading (the plan's spawnLooks) is kept while at least this much dry run lies along it at the level.
WaterRules.LOOK_RUN = 24
-- Bots and a human on the galleon (trap audit I2-07): a beach bot never locks a human on the decks (it cannot reach
-- him there; he could only be farmed), and any bot locks a given human at most once per HUMAN_SHOT_GAP seconds. A bot
-- whose every rival in range is off limits aims at HOLD_FIRE, an id no entrant carries, so it holds its missile
-- (BattleBots aims at Goal.attack when set and only falls back to the nearest rival when it is nil).
WaterRules.HUMAN_SHOT_GAP = 12
WaterRules.HOLD_FIRE = "hold"

export type Step = {
	step: number, -- 1-based, in time order
	at: number, -- seconds after GO when the water starts climbing
	level: number, -- world height of the water when the step has settled
}

export type Tide = {
	base: number,
	steps: { Step },
	drownDepth: number,
	rise: number,
}

export type Phase = {
	started: number, -- steps whose rise has begun
	total: number,
	rising: Step?, -- the step climbing right now
	nextStep: Step?, -- the next step not begun yet
	untilNext: number, -- seconds to nextStep (math.huge when none)
}

export type TideEvent = {
	kind: string, -- "warn" | "rise" | "settled"
	step: Step,
	at: number,
}

export type Watch = {
	since: { [string]: number }, -- when the entrant was first seen under (continuous)
	immuneUntil: { [string]: number },
	drowns: { [string]: number },
}

export type Grid = {
	center: Vector3,
	radius: number,
	cell: number,
	n: number, -- cells per side
	x0: number, -- world X of the centre of cell column 1
	z0: number,
	heights: { [number]: number }, -- cell index -> ground height (sampled cells only)
	list: { GridCell }, -- cells inside the radius (built once)
}

export type GridCell = {
	index: number,
	x: number,
	z: number,
}

export type GoalOptions = {
	minDist: number,
	maxDist: number,
	prefDist: number, -- distance the score likes best
	forward: number, -- weight of "ahead of the bot" (dot with its forward)
	distance: number, -- weight of |d - prefDist| / maxDist
	dry: number, -- weight of how far above the drown line the cell is (capped at 2 studs)
	margin: number, -- the cell must be dry by this much
	maxRise: number, -- |cell height - bot ground| at most this (skips masts, cliff tops, the decks from the sand)
	pathMargin: number?, -- the way there must be dry by this much at the path level (default 0)
}

export type Gangway = {
	name: string,
	foot: Vector3,
	top: Vector3,
	axis: Vector3, -- flat unit vector foot -> top
	length: number, -- flat foot -> top
}

export type Course = {
	tide: Tide,
	grid: Grid?,
	gangways: { Gangway },
	deckY: number?,
	center: Vector3,
	within: number, -- bots pick dry ground no further than this from the centre (inside the edge pull)
	board: boolean, -- beach bots may plan gangway trips onto the decks (BOTS_BOARD)
}

export type Motion = {
	anchor: { [string]: Vector3 }, -- where the entrant was when the window started
	since: { [string]: number },
}

export type PodView = { pos: Vector3, ground: number }
-- noAttack: a human this bot may not lock now (on the decks while the bot is not, or locked inside HUMAN_SHOT_GAP).
export type RivalView = { id: string, pos: Vector3, ground: number, isPlayer: boolean?, noAttack: boolean? }

-- What pickSafeSpawn weighs besides the tide (all optional).
export type SpawnOptions = {
	avoid: { [number]: boolean }?, -- pads passed over while another is dry (the decks)
	from: Vector3?, -- where the car went under or froze: pads within SAFE_CLEAR (flat) are passed over
	rivals: { Vector3 }?, -- live rivals: the pad farthest from the nearest one wins
	near: Vector3?, -- a boundary return: pads near here are preferred (NEAR_WEIGHT)
}

export type BotView = {
	pos: Vector3,
	forward: Vector3,
	ground: number, -- under the bot (hull minus ride height)
	holding: boolean,
	t: number, -- seconds since GO
	pods: { PodView }, -- ready pods only
	rivals: { RivalView }, -- entrants still in play, itself excluded
}

export type Goal = {
	pos: Vector3,
	attack: string?,
	reason: string,
	gangway: Gangway?, -- set on a gangway trip: the waypoint is routeStep(gangway, pos, forward, up), fresh every frame
	up: boolean?,
}

-- Flee: the nearest dry ground, a little in favour of what lies ahead. Patrol: dry ground well ahead, so a car bot
-- keeps rolling over dry land instead of circling a point. Deck patrol: shorter hops on the narrow decks.
WaterRules.FLEE = table.freeze({
	minDist = 0,
	maxDist = 170,
	prefDist = 0,
	forward = 0.35,
	distance = 1,
	dry = 0.3,
	margin = 0.4,
	maxRise = 8,
	-- The way out is checked at the wall's level: as shallow as the bot wall allows (WALL_DEPTH, not the drown depth).
	pathMargin = WaterRules.DEFAULT_DROWN - WaterRules.WALL_DEPTH,
}) :: GoalOptions
WaterRules.PATROL = table.freeze({
	minDist = 35,
	maxDist = 110,
	prefDist = 70,
	forward = 1,
	distance = 0.5,
	dry = 0.4,
	margin = 0.6,
	maxRise = 6,
	pathMargin = WaterRules.PATH_MARGIN,
}) :: GoalOptions
WaterRules.PATROL_DECK = table.freeze({
	minDist = 14,
	maxDist = 60,
	prefDist = 34,
	forward = 1,
	distance = 0.5,
	dry = 0,
	margin = 0,
	maxRise = 9,
}) :: GoalOptions

local function num(v: any): number?
	return if type(v) == "number" and v == v then v else nil
end

local function vec(v: any): Vector3?
	return if typeof(v) == "Vector3" then v else nil
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatUnit(v: Vector3, fallback: Vector3): Vector3
	local f = flat(v)
	return if f.Magnitude > 1e-4 then f.Unit else fallback
end

------------------------------------------------------------------------------------------------------------------------
-- Tide
------------------------------------------------------------------------------------------------------------------------

-- Normalised tide from TrackData.modes.battle: steps sorted by time, renumbered 1..n, levels never falling.
function WaterRules.tide(battle: any, rise: number?): Tide
	local b: any = if type(battle) == "table" then battle else {}
	local center = vec(b.center)
	local base = num(b.baseLevel) or num(b.seaLevel) or (if center then center.Y else 0)
	local steps: { Step } = {}
	if type(b.tideSteps) == "table" then
		for _, s in b.tideSteps do
			if type(s) == "table" then
				local at, level = num(s.atSeconds) or num(s.at), num(s.level)
				if at and level then
					table.insert(steps, { step = 0, at = at, level = level })
				end
			end
		end
	end
	table.sort(steps, function(x: Step, y: Step): boolean
		return x.at < y.at
	end)
	local prev = base
	for i, s in steps do
		s.step = i
		s.level = math.max(s.level, prev)
		prev = s.level
	end
	local depth = num(b.drownDepth)
	return {
		base = base,
		steps = steps,
		drownDepth = if depth and depth > 0 then depth else WaterRules.DEFAULT_DROWN,
		rise = math.max(0, rise or WaterRules.RISE_SECONDS),
	}
end

-- Water height t seconds after GO (smooth climb over each step's rise).
function WaterRules.levelAt(tide: Tide, t: number): number
	local level = tide.base
	for _, s in tide.steps do
		if t >= s.at + tide.rise then
			level = s.level
		elseif t > s.at then
			local k = math.clamp((t - s.at) / math.max(tide.rise, 1e-6), 0, 1)
			k = k * k * (3 - 2 * k)
			return level + (s.level - level) * k
		else
			break
		end
	end
	return level
end

-- The level the tide will have reached `ahead` seconds from t (levels never fall, so this is the highest until then).
function WaterRules.levelAhead(tide: Tide, t: number, ahead: number): number
	return WaterRules.levelAt(tide, t + math.max(0, ahead))
end

function WaterRules.phaseAt(tide: Tide, t: number): Phase
	local ph: Phase = { started = 0, total = #tide.steps, rising = nil, nextStep = nil, untilNext = math.huge }
	for _, s in tide.steps do
		if t >= s.at then
			ph.started = s.step
			if t < s.at + tide.rise then
				ph.rising = s
			end
		elseif not ph.nextStep then
			ph.nextStep = s
			ph.untilNext = s.at - t
		end
	end
	return ph
end

local NO_EVENTS: { TideEvent } = table.freeze({}) :: any

local function mark(out: { TideEvent }?, kind: string, s: Step, at: number, t0: number, t1: number): { TideEvent }?
	if at > t0 and at <= t1 and not (kind == "warn" and at <= 0) then
		local list: { TideEvent } = out or {}
		local ev: TideEvent = { kind = kind, step = s, at = at }
		table.insert(list, ev)
		return list
	end
	return out
end

-- Tide marks crossed in (t0, t1]: "warn" (warnSeconds before a step), "rise" (it starts), "settled" (it is up), in
-- time order. A warn mark at or before GO is skipped (the step is announced by its rise). Polled every Heartbeat: a
-- window without a mark allocates nothing (a shared, frozen empty list).
function WaterRules.events(tide: Tide, t0: number, t1: number, warnSeconds: number?): { TideEvent }
	local w = warnSeconds or WaterRules.WARN_SECONDS
	local out: { TideEvent }? = nil
	for _, s in tide.steps do
		if s.at - w <= t1 and s.at + tide.rise > t0 then
			out = mark(out, "warn", s, s.at - w, t0, t1)
			out = mark(out, "rise", s, s.at, t0, t1)
			out = mark(out, "settled", s, s.at + tide.rise, t0, t1)
		end
	end
	local list = out
	if list == nil then
		return NO_EVENTS
	end
	table.sort(list, function(a: TideEvent, b: TideEvent): boolean
		return a.at < b.at
	end)
	return list
end

-- HUD part: "TIDE 1/3 IN 0:42", "TIDE 2/3 RISING", "HIGH TIDE" ("" without steps).
function WaterRules.tideText(tide: Tide, t: number): string
	local ph = WaterRules.phaseAt(tide, t)
	if ph.total == 0 then
		return ""
	end
	local rising = ph.rising
	if rising then
		return string.format("TIDE %d/%d RISING", rising.step, ph.total)
	end
	local nextStep = ph.nextStep
	if nextStep then
		return string.format("TIDE %d/%d IN %s", nextStep.step, ph.total, BattleRules.formatClock(ph.untilNext))
	end
	return "HIGH TIDE"
end

-- The player's objective line: lives, the tide, and a nudge when the ground under them is about to go under.
function WaterRules.hudText(lives: number, tideText: string, danger: boolean): string
	local text = string.format("LIVES %d", lives)
	if tideText ~= "" then
		text ..= "  -  " .. tideText
	end
	if danger then
		text ..= "  -  HIGH GROUND!"
	end
	return text
end

------------------------------------------------------------------------------------------------------------------------
-- Drowning
------------------------------------------------------------------------------------------------------------------------

function WaterRules.isDry(groundY: number, level: number, drownDepth: number, margin: number?): boolean
	return level - groundY <= drownDepth - (margin or 0)
end

-- True when ground at groundY is under water now, or will be once the step that is rising or due within warnSeconds
-- has settled (the HUD's HIGH GROUND nudge).
function WaterRules.inDanger(tide: Tide, t: number, groundY: number, warnSeconds: number?): boolean
	local ph = WaterRules.phaseAt(tide, t)
	local level = WaterRules.levelAt(tide, t)
	local rising, nextStep = ph.rising, ph.nextStep
	if rising then
		level = math.max(level, rising.level)
	elseif nextStep and ph.untilNext <= (warnSeconds or WaterRules.WARN_SECONDS) then
		level = math.max(level, nextStep.level)
	end
	return not WaterRules.isDry(groundY, level, tide.drownDepth)
end

function WaterRules.newWatch(): Watch
	return { since = {}, immuneUntil = {}, drowns = {} }
end

-- One sample for one entrant at time t: depth = how far its car bottom sits under the tide. Returns true when this
-- sample completes a drown (under for `grace` seconds and not immune); the watch then starts its immunity and counts
-- the drown, and the caller costs the life and respawns it.
function WaterRules.sample(w: Watch, id: string, depth: number, drownDepth: number, t: number, grace: number?, immune: number?): boolean
	if t < (w.immuneUntil[id] or -math.huge) or depth <= drownDepth then
		w.since[id] = nil
		return false
	end
	local since = w.since[id]
	if not since then
		since = t
		w.since[id] = t
	end
	if t - since >= (grace or WaterRules.GRACE) then
		w.since[id] = nil
		w.immuneUntil[id] = t + (immune or WaterRules.IMMUNE)
		w.drowns[id] = (w.drowns[id] or 0) + 1
		return true
	end
	return false
end

-- Extra immunity (e.g. any respawn the mode orders).
function WaterRules.shield(w: Watch, id: string, untilT: number)
	w.immuneUntil[id] = math.max(w.immuneUntil[id] or -math.huge, untilT)
	w.since[id] = nil
end

-- A drown costs one life exactly like an item hit nobody landed (SurvivalRules). Returns (lifeLost, nowOut).
function WaterRules.drown(lives: SurvivalRules.State, id: string, t: number): (boolean, boolean)
	return SurvivalRules.hit(lives, id, nil, t)
end

-- Spawn pad for a drowned (or wedged) car: the highest pad whose ground stays dry at `level` (ties keep the lower
-- index), passing over the pads in `avoid` (an arena bot skips the deck pad) while another pad is dry; with no dry
-- pad, the highest pad. nil without pads.
function WaterRules.pickSpawn(grounds: { number }, level: number, drownDepth: number, avoid: { [number]: boolean }?): number?
	local best: number? = nil
	local bestRank = 0
	for i, g in grounds do
		local dry = WaterRules.isDry(g, level, drownDepth)
		local rank = if dry and not (avoid and avoid[i]) then 3 elseif dry then 2 else 1
		local b = best
		if b == nil or rank > bestRank or (rank == bestRank and g > grounds[b]) then
			best, bestRank = i, rank
		end
	end
	return best
end

-- The safe respawn pad (see SAFE_CLEAR): among the pads dry at `level` and not avoided, the ones at least SAFE_CLEAR
-- (flat) from opts.from (all of them when none is that far), the pad whose nearest live rival is farthest away (capped at
-- RIVAL_CAP), less NEAR_WEIGHT x its distance to opts.near; ties go to the higher ground, then the lower index. With no
-- dry pad off the avoid list it is pickSpawn's answer (an avoided dry pad, else the highest). `pads` are the pad
-- positions, `grounds` their ground heights (same indices). nil without pads.
function WaterRules.pickSafeSpawn(pads: { Vector3 }, grounds: { number }, level: number, drownDepth: number, opts: SpawnOptions?): number?
	local o: SpawnOptions = opts or {}
	local avoid, from, near = o.avoid, o.from, o.near
	local rivals: { Vector3 } = o.rivals or {}
	local dry: { number } = {}
	local clear: { number } = {}
	for i, g in grounds do
		local p = pads[i]
		if p and WaterRules.isDry(g, level, drownDepth) and not (avoid and avoid[i]) then
			table.insert(dry, i)
			if from == nil or BattleRules.horizontal(p, from) >= WaterRules.SAFE_CLEAR then
				table.insert(clear, i)
			end
		end
	end
	local pool: { number } = if #clear > 0 then clear else dry
	if #pool == 0 then
		return WaterRules.pickSpawn(grounds, level, drownDepth, avoid)
	end
	local best: number? = nil
	local bestScore = -math.huge
	for _, i in pool do
		local p = pads[i]
		local nearest = WaterRules.RIVAL_CAP
		for _, r in rivals do
			nearest = math.min(nearest, BattleRules.horizontal(p, r))
		end
		local score = nearest - (if near then WaterRules.NEAR_WEIGHT * BattleRules.horizontal(p, near) else 0)
		local b = best
		if b == nil or score > bestScore + 1e-6 or (math.abs(score - bestScore) <= 1e-6 and grounds[i] > grounds[b]) then
			best, bestScore = i, score
		end
	end
	return best
end

------------------------------------------------------------------------------------------------------------------------
-- Stuck watchdog
------------------------------------------------------------------------------------------------------------------------

function WaterRules.newMotion(): Motion
	return { anchor = {}, since = {} }
end

-- Forget an entrant's window (it was moved, or it is stunned and allowed to crawl).
function WaterRules.resetMotion(m: Motion, id: string)
	m.anchor[id] = nil
	m.since[id] = nil
end

-- One sample: true when the entrant has stayed within `move` studs (flat) of one spot for `seconds`; the window then
-- restarts, so a bot that stays wedged is reported again `seconds` later.
function WaterRules.stuck(m: Motion, id: string, pos: Vector3, t: number, move: number?, seconds: number?): boolean
	local anchor: Vector3? = m.anchor[id]
	local since: number? = m.since[id]
	if not anchor or not since or BattleRules.horizontal(anchor, pos) > (move or WaterRules.STUCK_MOVE) then
		m.anchor[id] = pos
		m.since[id] = t
		return false
	end
	if t - since >= (seconds or WaterRules.STUCK_SECONDS) then
		m.anchor[id] = pos
		m.since[id] = t
		return true
	end
	return false
end

------------------------------------------------------------------------------------------------------------------------
-- Ground grid
------------------------------------------------------------------------------------------------------------------------

function WaterRules.newGrid(center: Vector3, radius: number, cell: number): Grid
	local c = math.max(cell, 0.5)
	local n = math.max(1, math.ceil(2 * radius / c) + 1)
	local half = (n - 1) * c / 2
	local grid: Grid = { center = center, radius = radius, cell = c, n = n, x0 = center.X - half, z0 = center.Z - half, heights = {}, list = {} }
	for j = 1, n do
		for i = 1, n do
			local x, z = grid.x0 + (i - 1) * c, grid.z0 + (j - 1) * c
			local dx, dz = x - center.X, z - center.Z
			if dx * dx + dz * dz <= radius * radius then
				table.insert(grid.list, { index = (j - 1) * n + i, x = x, z = z })
			end
		end
	end
	return grid
end

-- Cells inside the grid radius (what the server samples).
function WaterRules.cells(grid: Grid): { GridCell }
	return grid.list
end

-- Records a sampled cell; nil (no ground found) clears it.
function WaterRules.setHeight(grid: Grid, index: number, h: number?)
	(grid.heights :: { [number]: number? })[index] = h
end

-- Ground height of the cell nearest (x, z); nil outside the grid or where no ground was found.
function WaterRules.heightAt(grid: Grid, x: number, z: number): number?
	local i = math.floor((x - grid.x0) / grid.cell + 0.5) + 1
	local j = math.floor((z - grid.z0) / grid.cell + 0.5) + 1
	if i < 1 or j < 1 or i > grid.n or j > grid.n then
		return nil
	end
	return grid.heights[(j - 1) * grid.n + i]
end

-- Dry cells and sampled cells inside `within` studs of the centre (default the grid radius), counting only land at or
-- under `ceiling` (cliff tops and masts are not playable area).
function WaterRules.dryShare(grid: Grid, level: number, drownDepth: number, within: number?, ceiling: number?): (number, number)
	local r = within or grid.radius
	local top = ceiling or math.huge
	local dry, total = 0, 0
	for _, c in WaterRules.cells(grid) do
		local h = grid.heights[c.index]
		local dx, dz = c.x - grid.center.X, c.z - grid.center.Z
		if h and h <= top and dx * dx + dz * dz <= r * r then
			total += 1
			if WaterRules.isDry(h, level, drownDepth) then
				dry += 1
			end
		end
	end
	return dry, total
end

-- Whether a car can drive the straight line a -> b at `level`: every sample (half a cell apart, the start excluded)
-- has known ground, dry (by `margin`, default 0), not `skip`ped (off limits), and no step bigger than CLIMB from the
-- sample before it.
function WaterRules.pathClear(
	grid: Grid,
	a: Vector3,
	b: Vector3,
	level: number,
	drownDepth: number,
	margin: number?,
	skip: ((x: number, z: number, h: number) -> boolean)?
): boolean
	local d = flat(b - a)
	local len = d.Magnitude
	local stepLen = grid.cell * 0.5
	local n = math.max(1, math.ceil(len / stepLen))
	local prev: number? = nil
	for k = 1, n do
		local f = k / n
		local x, z = a.X + d.X * f, a.Z + d.Z * f
		local h = WaterRules.heightAt(grid, x, z)
		if h == nil or not WaterRules.isDry(h, level, drownDepth, margin) or (skip ~= nil and skip(x, z, h)) then
			return false
		end
		if prev and math.abs(h - prev) > WaterRules.CLIMB then
			return false
		end
		prev = h
	end
	return true
end

-- Best dry cell for a bot at `from` (ground groundY, heading `forward`): dry at destLevel by opts.margin, within the
-- distance band and `within` of the grid centre, on its own level (opts.maxRise), not `skip`ped (off limits), with a
-- clear path at pathLevel. Returns the cell centre at its ground height, or nil.
function WaterRules.pickDryGoal(
	grid: Grid,
	from: Vector3,
	forward: Vector3,
	groundY: number,
	destLevel: number,
	pathLevel: number,
	drownDepth: number,
	opts: GoalOptions,
	within: number?,
	skip: ((x: number, z: number, h: number) -> boolean)?
): Vector3?
	local fwd = flatUnit(forward, Vector3.new(0, 0, -1))
	local r = within or grid.radius
	local scored: { { pos: Vector3, score: number } } = {}
	for _, c in WaterRules.cells(grid) do
		local h = grid.heights[c.index]
		if
			h
			and math.abs(h - groundY) <= opts.maxRise
			and WaterRules.isDry(h, destLevel, drownDepth, opts.margin)
			and not (skip and skip(c.x, c.z, h))
		then
			local cx, cz = c.x - grid.center.X, c.z - grid.center.Z
			local to = Vector3.new(c.x - from.X, 0, c.z - from.Z)
			local d = to.Magnitude
			if cx * cx + cz * cz <= r * r and d >= opts.minDist and d <= opts.maxDist then
				local dot = if d > 1e-3 then fwd:Dot(to / d) else 1
				local dryBy = math.min(drownDepth - (destLevel - h), 2) / 2
				local score = opts.forward * dot
					- opts.distance * math.abs(d - opts.prefDist) / math.max(opts.maxDist, 1)
					+ opts.dry * dryBy
				table.insert(scored, { pos = Vector3.new(c.x, h, c.z), score = score })
			end
		end
	end
	table.sort(scored, function(x, y): boolean
		return x.score > y.score
	end)
	for i = 1, math.min(#scored, 12) do
		local p = scored[i].pos
		if WaterRules.pathClear(grid, from, p, pathLevel, drownDepth, opts.pathMargin, skip) then
			return p
		end
	end
	return nil
end

-- The nearest cell (flat) that is dry at `level` by `margin`, inside `within` of the grid centre and not `skip`ped,
-- path or not: where a bot with no plannable goal regroups instead of the arena centre (flooded from the first step).
function WaterRules.nearestDry(
	grid: Grid,
	from: Vector3,
	level: number,
	drownDepth: number,
	margin: number,
	within: number?,
	skip: ((x: number, z: number, h: number) -> boolean)?
): Vector3?
	local r = within or grid.radius
	local best: GridCell? = nil
	local bestH = 0
	local bestD = math.huge
	for _, c in WaterRules.cells(grid) do
		local h = grid.heights[c.index]
		if h and WaterRules.isDry(h, level, drownDepth, margin) and not (skip and skip(c.x, c.z, h)) then
			local cx, cz = c.x - grid.center.X, c.z - grid.center.Z
			local dx, dz = c.x - from.X, c.z - from.Z
			local d = dx * dx + dz * dz
			if cx * cx + cz * cz <= r * r and d < bestD then
				best, bestH, bestD = c, h, d
			end
		end
	end
	local b = best
	return if b then Vector3.new(b.x, bestH, b.z) else nil
end

-- Heading for a car set down at `from` (a tide or watchdog respawn): of 16 directions, the one with the longest run
-- that pathClear would drive (known ground, dry at `level` by SAFE_MARGIN, no step over CLIMB, not `skip`ped) up to
-- `reach` studs; ties go to the direction nearest `prefer` (the arena centre, the old spawn facing). A bot faces dry
-- ground instead of the flooded centre, a player faces along the deck instead of its rail.
function WaterRules.dryHeading(
	grid: Grid,
	from: Vector3,
	level: number,
	drownDepth: number,
	reach: number,
	prefer: Vector3,
	skip: ((x: number, z: number, h: number) -> boolean)?
): Vector3
	return WaterRules.respawnHeadings(grid, from, level, drownDepth, reach, prefer, skip, nil)[1]
end

-- How far a car set down at `from` drives along flat unit (dx, dz) before the run ends (dryHeading's rule).
local function dryRun(
	grid: Grid,
	from: Vector3,
	dx: number,
	dz: number,
	level: number,
	drownDepth: number,
	reach: number,
	skip: ((x: number, z: number, h: number) -> boolean)?
): number
	local stepLen = grid.cell * 0.5
	local run = 0
	local prev = WaterRules.heightAt(grid, from.X, from.Z)
	local d = stepLen
	while d <= reach do
		local x, z = from.X + dx * d, from.Z + dz * d
		local h = WaterRules.heightAt(grid, x, z)
		if
			h == nil
			or not WaterRules.isDry(h, level, drownDepth, WaterRules.SAFE_MARGIN)
			or (prev ~= nil and math.abs(h - prev) > WaterRules.CLIMB)
			or (skip ~= nil and skip(x, z, h))
		then
			break
		end
		run, prev = d, h
		d += stepLen
	end
	return run
end

-- Respawn headings for a pad, best first: the pad's authored `look` (the plan's spawnLooks, trap audit I2-04) while
-- at least LOOK_RUN (or the whole reach) of dry run lies along it, then the 16 dryHeading directions by run (ties
-- nearest `prefer`). The server takes the first one a car-sized Blockcast finds clear of walls (Water.respawnFrame):
-- the 6-stud grid alone cannot see a mast or a capstan.
function WaterRules.respawnHeadings(
	grid: Grid,
	from: Vector3,
	level: number,
	drownDepth: number,
	reach: number,
	prefer: Vector3,
	skip: ((x: number, z: number, h: number) -> boolean)?,
	look: Vector3?
): { Vector3 }
	local pref = flatUnit(prefer - from, Vector3.new(0, 0, -1))
	local ranked: { { dir: Vector3, run: number, dot: number, k: number } } = {}
	for k = 0, 15 do
		local a = k / 16 * 2 * math.pi
		local dx, dz = math.cos(a), math.sin(a)
		table.insert(ranked, {
			dir = Vector3.new(dx, 0, dz),
			run = dryRun(grid, from, dx, dz, level, drownDepth, reach, skip),
			dot = dx * pref.X + dz * pref.Z,
			k = k,
		})
	end
	table.sort(ranked, function(a, b): boolean
		if math.abs(a.run - b.run) > 1e-6 then
			return a.run > b.run
		elseif math.abs(a.dot - b.dot) > 1e-9 then
			return a.dot > b.dot
		end
		return a.k < b.k
	end)
	local out: { Vector3 } = {}
	if look then
		local l = flatUnit(look, pref)
		if dryRun(grid, from, l.X, l.Z, level, drownDepth, reach, skip) >= math.min(WaterRules.LOOK_RUN, reach) - 1e-6 then
			table.insert(out, l)
		end
	end
	for _, r in ranked do
		table.insert(out, r.dir)
	end
	return out
end

------------------------------------------------------------------------------------------------------------------------
-- Decks and gangways
------------------------------------------------------------------------------------------------------------------------

function WaterRules.gangways(battle: any): { Gangway }
	local out: { Gangway } = {}
	if type(battle) ~= "table" or type(battle.gangways) ~= "table" then
		return out
	end
	for i, g in battle.gangways do
		local foot = if type(g) == "table" then vec(g.foot) else nil
		local top = if type(g) == "table" then vec(g.top) else nil
		if foot and top and flat(top - foot).Magnitude > 1 then
			table.insert(out, {
				name = if type(g.name) == "string" then g.name else "Gangway" .. tostring(i),
				foot = foot,
				top = top,
				axis = flat(top - foot).Unit,
				length = flat(top - foot).Magnitude,
			})
		end
	end
	return out
end

-- Main deck height (TrackData.modes.battle.decks.main.y), nil when the plan has no decks.
function WaterRules.deckY(battle: any): number?
	local decks = if type(battle) == "table" then battle.decks else nil
	local main = if type(decks) == "table" then decks.main else nil
	return if type(main) == "table" then num(main.y) else nil
end

function WaterRules.course(battle: any, center: Vector3, within: number, grid: Grid?, rise: number?): Course
	return {
		tide = WaterRules.tide(battle, rise),
		grid = grid,
		gangways = WaterRules.gangways(battle),
		deckY = WaterRules.deckY(battle),
		center = center,
		within = within,
		board = WaterRules.BOTS_BOARD,
	}
end

-- On the galleon: at deck height and within DECK_REACH of a gangway top.
function WaterRules.onDeck(course: Course, pos: Vector3, groundY: number): boolean
	local y = course.deckY
	if not y or groundY < y - WaterRules.DECK_TOLERANCE then
		return false
	end
	for _, g in course.gangways do
		if BattleRules.horizontal(pos, g.top) <= WaterRules.DECK_REACH then
			return true
		end
	end
	return false
end

-- Ramp coordinates of pos along a gangway: s (flat studs from the foot toward the top) and the lateral offset.
function WaterRules.rampCoords(g: Gangway, pos: Vector3): (number, number)
	local rel = flat(pos - g.foot)
	local s = rel:Dot(g.axis)
	return s, (rel - g.axis * s).Magnitude
end

-- Whether (x, z) lies on a gangway's lane at least `fromFoot` studs up from its foot, through the bulwark opening.
local function onRampXZ(course: Course, x: number, z: number, fromFoot: number): boolean
	for _, g in course.gangways do
		local rx, rz = x - g.foot.X, z - g.foot.Z
		local s = rx * g.axis.X + rz * g.axis.Z
		local lx, lz = rx - g.axis.X * s, rz - g.axis.Z * s
		if s >= fromFoot and s <= g.length + 2 and lx * lx + lz * lz <= (WaterRules.LANE + 2) ^ 2 then
			return true
		end
	end
	return false
end

-- Off limits to a beach bot that may not board (Course.board false): deck-height ground and the raised gangways.
function WaterRules.offBeach(course: Course, x: number, z: number, h: number): boolean
	local y = course.deckY
	if y and h >= y - WaterRules.DECK_TOLERANCE then
		return true
	end
	return onRampXZ(course, x, z, WaterRules.RAMP_FOOT)
end

-- The gangway whose ramp pos is on (between foot and top, inside the lane), and whether its heading points up it.
function WaterRules.rampOf(course: Course, pos: Vector3, forward: Vector3): (Gangway?, boolean)
	for _, g in course.gangways do
		local s, lat = WaterRules.rampCoords(g, pos)
		if s >= 0 and s <= g.length and lat <= WaterRules.LANE + 2 then
			return g, flatUnit(forward, g.axis):Dot(g.axis) >= 0
		end
	end
	return nil, false
end

local TAU = 2 * math.pi

-- Rotation by angle a in the X-Z plane (counter-clockwise in (X, Z) coordinates); dirOf/angleOf convert headings.
local function rotXZ(v: Vector3, a: number): Vector3
	local c, s = math.cos(a), math.sin(a)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function dirOf(phi: number): Vector3
	return Vector3.new(math.cos(phi), 0, math.sin(phi))
end

local function angleOf(v: Vector3): number
	return math.atan2(v.Z, v.X)
end

local function wrapAngle(a: number): number
	local t = a % TAU
	return if t > TAU - 1e-6 then 0 else t
end

type Dubins = { turn0: number, turn1: number, c0: Vector3, c1: Vector3, a0: number, a1: number, psi: number, straight: number, length: number }

-- One CSC path (turn0/turn1: +1 counter-clockwise, -1 clockwise, in (X, Z)); nil when the circles are too close for it.
local function cscPath(p0: Vector3, phi0: number, p1: Vector3, phi1: number, r: number, turn0: number, turn1: number): Dubins?
	local c0 = p0 + rotXZ(dirOf(phi0), turn0 * math.pi / 2) * r
	local c1 = p1 + rotXZ(dirOf(phi1), turn1 * math.pi / 2) * r
	local between = c1 - c0
	local d = between.Magnitude
	local psi, straight
	if turn0 == turn1 then
		psi = if d > 1e-6 then angleOf(between) else phi0
		straight = d
	else
		if d < 2 * r then
			return nil
		end
		straight = math.sqrt(d * d - 4 * r * r)
		psi = angleOf(between) + turn0 * math.atan2(2 * r, straight)
	end
	local a0 = wrapAngle(turn0 * (psi - phi0))
	local a1 = wrapAngle(turn1 * (phi1 - psi))
	return { turn0 = turn0, turn1 = turn1, c0 = c0, c1 = c1, a0 = a0, a1 = a1, psi = psi, straight = straight, length = r * (a0 + a1) + straight }
end

-- The point `dist` studs along the shortest turn-straight-turn path (Dubins CSC) for a car turning on radius r, from
-- p0 heading phi0 to p1 heading phi1 (flat, angles in the X-Z plane); past the path's end it runs on along phi1.
function WaterRules.dubinsPoint(p0: Vector3, phi0: number, p1: Vector3, phi1: number, r: number, dist: number): Vector3
	local a = flat(p0)
	local b = flat(p1)
	local best: Dubins? = nil
	for _, turns in { { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } } do
		local path = cscPath(a, phi0, b, phi1, r, turns[1], turns[2])
		if path and (best == nil or path.length < (best :: Dubins).length) then
			best = path
		end
	end
	local path = best
	if not path then
		return b
	end
	local arc0 = r * path.a0
	if dist <= arc0 then
		return path.c0 + rotXZ(a - path.c0, path.turn0 * dist / r)
	end
	local t0 = path.c0 + rotXZ(a - path.c0, path.turn0 * path.a0)
	if dist <= arc0 + path.straight then
		return t0 + dirOf(path.psi) * (dist - arc0)
	end
	local t1 = t0 + dirOf(path.psi) * path.straight
	if dist <= path.length then
		return path.c1 + rotXZ(t1 - path.c1, path.turn1 * (dist - arc0 - path.straight) / r)
	end
	return b + dirOf(phi1) * (dist - path.length)
end

-- Next waypoint along a gangway, up (sand -> deck) or down. A car bot cannot turn onto a 9-stud ramp from close by,
-- so it plans the shortest turn-straight-turn path (dubinsPoint) to a line-up pose APPROACH studs before the ramp end,
-- heading along the ramp, and steers at a point CARROT ahead on it. Inside the lane (a cone behind the end, heading
-- along it, or on the ramp itself) it chases a point on the ramp line instead, ending past the far end (onto the
-- deck, or off the sandbar). tools/tests/water_spec.luau drives a kinematic bot through it from many poses.
function WaterRules.routeStep(g: Gangway, pos: Vector3, forward: Vector3, up: boolean): Vector3
	local u = if up then g.axis else -g.axis
	local from = if up then g.foot else g.top
	local to = if up then g.top else g.foot
	local approach = if up then WaterRules.APPROACH else WaterRules.APPROACH_DECK
	local exit = if up then WaterRules.EXIT_DECK else WaterRules.EXIT_SAND
	local rel = flat(pos - from)
	local s = rel:Dot(u)
	local lat = (rel - u * s).Magnitude
	local fwd = flatUnit(forward, u)
	local heading = fwd:Dot(u)
	local inLane: boolean
	if s < 0 then
		inLane = s >= -(approach + 10) and lat <= WaterRules.LANE + WaterRules.CONE * -s and heading >= 0.85
	else
		inLane = lat <= WaterRules.LANE + 2 and heading >= 0.2
	end
	local goal: Vector3
	if inLane then
		goal = flat(from) + u * math.min(s + WaterRules.CARROT, g.length + exit)
	else
		local pose = flat(from) - u * approach
		goal = WaterRules.dubinsPoint(pos, angleOf(fwd), pose, angleOf(u), WaterRules.TURN_RADIUS, WaterRules.CARROT)
	end
	local k = math.clamp(flat(goal - from):Dot(u) / g.length, 0, 1)
	return Vector3.new(goal.X, from.Y + (to.Y - from.Y) * k, goal.Z)
end

-- Nearest gangway (flat distance from pos to its foot or top) whose foot stays dry at `level`.
function WaterRules.nearestGangway(course: Course, pos: Vector3, level: number, fromTop: boolean): Gangway?
	local best: Gangway? = nil
	local bestD = math.huge
	for _, g in course.gangways do
		if WaterRules.isDry(g.foot.Y, level, course.tide.drownDepth, WaterRules.SAFE_MARGIN) then
			local d = BattleRules.horizontal(pos, if fromTop then g.top else g.foot)
			if d < bestD then
				best, bestD = g, d
			end
		end
	end
	return best
end

------------------------------------------------------------------------------------------------------------------------
-- Bots
------------------------------------------------------------------------------------------------------------------------

-- How a bot at v gets to `target` (on the decks or not) with the water at `level`: the waypoint, a cost (studs; a
-- gangway trip weighs extra) and the gangway it boards, or nil when it cannot (flooded path or gangway foot, decks to
-- sand).
local function reach(
	course: Course,
	v: BotView,
	fromDeck: boolean,
	target: Vector3,
	toDeck: boolean,
	level: number,
	skip: ((x: number, z: number, h: number) -> boolean)?
): (Vector3?, number, Gangway?)
	local dd = course.tide.drownDepth
	local d = BattleRules.horizontal(v.pos, target)
	if fromDeck then
		-- A bot on the galleon stays there (the decks are too narrow for a car bot to line up on a gangway down).
		return if toDeck then target else nil, d, nil
	end
	if not toDeck then
		local grid = course.grid
		if grid and not WaterRules.pathClear(grid, v.pos, target, level, dd, WaterRules.PATH_MARGIN, skip) then
			return nil, math.huge, nil
		end
		return target, d, nil
	end
	local g = WaterRules.nearestGangway(course, v.pos, level, false)
	if not g then
		return nil, math.huge, nil
	end
	local cost = BattleRules.horizontal(v.pos, g.foot) + BattleRules.horizontal(g.top, target) + 60
	return WaterRules.routeStep(g, v.pos, v.forward, true), cost, g
end

-- Where an arena bot heads (see the header). Pure: the server builds the view from the battle context.
function WaterRules.botGoal(course: Course, v: BotView): Goal
	local tide = course.tide
	local dd = tide.drownDepth
	local now = WaterRules.levelAt(tide, v.t)
	local soon = WaterRules.levelAhead(tide, v.t, WaterRules.LOOKAHEAD)
	local margin = WaterRules.SAFE_MARGIN
	local deck = WaterRules.onDeck(course, v.pos, v.ground)

	-- Distance as the bot weighs a rival (a human counts PREFER_PLAYER times closer).
	local function weighed(r: RivalView): number
		return (r.pos - v.pos).Magnitude / (if r.isPlayer then WaterRules.PREFER_PLAYER else 1)
	end
	local nearest: RivalView? = nil
	local nearestD = math.huge
	local heldBack = false -- a rival in range this bot may not lock (see HUMAN_SHOT_GAP)
	for _, r in v.rivals do
		local d = weighed(r)
		if (r.pos - v.pos).Magnitude <= WaterRules.ATTACK_RANGE then
			if r.noAttack then
				heldBack = true
			elseif d < nearestD then
				nearest, nearestD = r, d
			end
		end
	end
	local attack = if nearest then nearest.id elseif heldBack then WaterRules.HOLD_FIRE else nil
	local board = course.board
	-- A beach bot that may not board plans over beach ground only (see the header).
	local skip: ((number, number, number) -> boolean)? = nil
	if not deck and not board then
		skip = function(x: number, z: number, h: number): boolean
			return WaterRules.offBeach(course, x, z, h)
		end
	end

	-- On a gangway ramp: finish the climb (or the way down) the heading points along. Without boarding only once it is
	-- up the raised part (it cannot turn round on a 9-stud ramp); on the barely raised foot it is still on the beach.
	local ramp, upRamp = WaterRules.rampOf(course, v.pos, v.forward)
	local rampS = if ramp then (WaterRules.rampCoords(ramp, v.pos)) else 0
	local onRamp = ramp ~= nil
		and math.abs(v.ground - (ramp.foot.Y + (ramp.top.Y - ramp.foot.Y) * math.clamp(rampS / ramp.length, 0, 1))) <= WaterRules.RAMP_SNAP
	if ramp and onRamp and not deck and (board or rampS >= WaterRules.RAMP_COMMIT) then
		return {
			pos = WaterRules.routeStep(ramp, v.pos, v.forward, upRamp),
			attack = attack,
			reason = if upRamp then "board" else "disembark",
			gangway = ramp,
			up = upRamp,
		}
	end

	local grid = course.grid
	-- 1. The ground under it floods within the look-ahead: the nearest ground that stays dry, else (boarding) up a
	--    gangway whose foot is still dry now, else the highest ground still dry now. The way out may cross water as deep
	--    as where it already is (a bot caught by a rising step has no drier path).
	if not deck and not WaterRules.isDry(v.ground, soon, dd, margin) then
		-- The way out at the level the car bots' wall sees (WALL_AHEAD; FLEE.pathMargin keeps it WALL_DEPTH deep at most),
		-- or, for a bot already deeper than that, ground no lower than where it is (BattleBots lets it drive on there).
		local wayOut = math.min(WaterRules.levelAhead(tide, v.t, WaterRules.WALL_AHEAD), v.ground + WaterRules.WALL_DEPTH)
		if grid then
			local cell = WaterRules.pickDryGoal(grid, v.pos, v.forward, v.ground, soon, wayOut, dd, WaterRules.FLEE, course.within, skip)
			if cell then
				return { pos = cell, attack = attack, reason = "flee" }
			end
		end
		local g = if board then WaterRules.nearestGangway(course, v.pos, now, false) else nil
		if g then
			return { pos = WaterRules.routeStep(g, v.pos, v.forward, true), attack = attack, reason = "flee deck", gangway = g, up = true }
		end
		if grid then
			local cell = WaterRules.pickDryGoal(grid, v.pos, v.forward, v.ground, now, wayOut, dd, WaterRules.FLEE, course.within, skip)
				or WaterRules.nearestDry(grid, v.pos, now, dd, 0, course.within, skip)
			if cell then
				return { pos = cell, attack = attack, reason = "stranded" }
			end
		end
		return { pos = course.center, attack = attack, reason = "stranded" }
	end

	-- 2. Nothing held: the cheapest ready pod on ground that stays dry (deck pods only for a bot that may board, or one
	--    already on the decks).
	if not v.holding then
		local bestWp: Vector3? = nil
		local bestCost = math.huge
		local bestGangway: Gangway? = nil
		for _, p in v.pods do
			local podDeck = WaterRules.onDeck(course, p.pos, p.ground)
			if WaterRules.isDry(p.ground, soon, dd, margin) and (deck or board or not podDeck) then
				local wp, cost, g = reach(course, v, deck, p.pos, podDeck, soon, skip)
				if wp and cost < bestCost then
					bestWp, bestCost, bestGangway = wp, cost, g
				end
			end
		end
		if bestWp then
			return { pos = bestWp, attack = attack, reason = if bestGangway then "pod deck" else "pod", gangway = bestGangway, up = if bestGangway then true else nil }
		end
	end

	-- 3. Hunt the nearest rival (a human weighed closer) on dry ground on its own level with a dry way there (a beach
	--    bot that may not board leaves a rival on a gangway to its items).
	local rivals = table.clone(v.rivals)
	table.sort(rivals, function(a: RivalView, b: RivalView): boolean
		return weighed(a) < weighed(b)
	end)
	for _, r in rivals do
		if not r.noAttack and (r.pos - v.pos).Magnitude <= WaterRules.ATTACK_RANGE and WaterRules.isDry(r.ground, soon, dd, margin) then
			local rDeck = WaterRules.onDeck(course, r.pos, r.ground)
			local reachable = rDeck == deck and not (skip and skip(r.pos.X, r.pos.Z, r.ground))
			if reachable and (deck or grid == nil or WaterRules.pathClear(grid :: Grid, v.pos, r.pos, soon, dd, WaterRules.PATH_MARGIN, skip)) then
				return { pos = r.pos, attack = r.id, reason = "hunt" }
			end
		end
	end

	-- 4. Patrol dry ground ahead; items still aim at the nearest rival.
	if grid then
		local opts = if deck then WaterRules.PATROL_DECK else WaterRules.PATROL
		local cell = WaterRules.pickDryGoal(grid, v.pos, v.forward, v.ground, soon, soon, dd, opts, course.within, skip)
		if cell then
			return { pos = cell, attack = attack, reason = "patrol" }
		end
		-- Nothing plannable (out in the soft band, or boxed in): regroup on the nearest dry ground, never the centre
		-- once the first step has flooded it.
		local dry = if deck then nil else WaterRules.nearestDry(grid, v.pos, soon, dd, margin, course.within, skip)
		if dry then
			return { pos = dry, attack = attack, reason = "regroup" }
		end
	end
	return { pos = course.center, attack = attack, reason = "centre" }
end

return WaterRules
