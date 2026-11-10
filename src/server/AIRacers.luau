--!strict
-- AI racers (TEST_LIST_LAUNCH L08; LAUNCH_PROGRESSION section 4 "eight entrants, bots fill").
-- Bots fill every empty seat so a race has PlaneConfig.AI_FIELD_SIZE entrants (players + bots; with no player one seat
-- stays open for the first joiner). They start on the grid slots after the players, fly the course spline with light
-- rubber banding, boost at the same rings and pads a player uses, take item pods and fire items through ItemService's
-- public API, and spin out when an item hits them. Server-authoritative: bot planes are anchored server parts; the
-- client only renders them.
--
-- RaceManager contract (unchanged names/signatures): spawnBots() at init, resetBots() on every race reset (it recomputes
-- the field from the current players), step(dt, leadPlayerDist, raceElapsed, onBotFinished) every Heartbeat, and
-- AIRacers.bots for standings. Joins and leaves between resets are handled here (Players events -> refreshField).
--
-- Pure helpers (botsNeeded, botSlots, legacyGridSlot, crossed, nearestGaps, decideItemUse, requiredLift, solveLifts,
-- parseHitArgs, validateRoster, ...) touch no Roblox instance, so tools/tests/field_spec.luau runs them under Lune.
--
-- Per-step cost per bot is O(boost stations + item pods) plus O(bots) for separation (7 at most); track marks are
-- scanned once per track (GetDescendants never runs per frame) and item decisions run 4 times a second.
--
-- REMARKABLE item 19 (rival bots with personalities and taunt bubbles; rules and lines in Shared.BotPersonality,
-- loaded lazily so the field specs run without it): at the item cadence the field watches for passes on a player,
-- hits on and by bots (ItemService.setHitListener) and finishes, and a bot with something to say sends "BotTaunt"
-- {plane, text, rival, bucket} to every client on the ItemRemote (client/RivalBubbles draws it). With exactly one
-- player in a race (not a boss race) one of the three fastest bots is that player's RIVAL: plane attribute Rival = true,
-- more lines, and AIRacers.rubberFactor holds it in a tighter band around the player that never exceeds the
-- RUBBER_BAND_MAX_BOOST / RUBBER_BAND_MAX_SLOW ceilings (no new speed source; skill rewards stay player-only).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaneConfig = require(Shared:WaitForChild("PlaneConfig"))
local SplineUtils = require(Shared:WaitForChild("SplineUtils"))
local TrackRegistry = require(Shared:WaitForChild("TrackRegistry"))
local ItemRules = require(Shared:WaitForChild("ItemRules"))
local FidelityRules = require(Shared:WaitForChild("FidelityRules")) -- PadLive (M-2) and the per-track bot pace (M-5)
local TriggerRules = require(Shared:WaitForChild("TriggerRules")) -- botBoost: an alternate line's rings are not the bots'
local SailGateRules = require(Shared:WaitForChild("SailGateRules")) -- FOREST-1 sail-gap ring: lit only while the gap lines up
local PlaneBuilder = require(script.Parent.PlaneBuilder)
local CarConfig = require(Shared:WaitForChild("CarConfig"))
local CarBuilder = require(script.Parent.kit.CarBuilder)
local RacerPaint = require(script.Parent.kit.RacerPaint)
local BossConfig = require(Shared:WaitForChild("BossConfig"))
local GridOrder = require(Shared:WaitForChild("GridOrder")) -- grid-order plan: row-mate fan (docs/design/GRID_ORDER.md)
local RacerViewRules = require(Shared:WaitForChild("RacerViewRules")) -- the fixed bot step the clients' view counts on
local BotPaceRules = require(Shared:WaitForChild("BotPaceRules")) -- economy v3 phase 4: per-race skill, start delay, slips
local BotDisguise = require(script.Parent.kit.BotDisguise) -- generated username, pilot outfit, livery and trail
-- Economy v3 phase 2b: one field per RaceInstance (shared/RaceScope) and the race attributes of that field's instance
-- (shared/RaceAttr). Both read exactly what they read before while RaceFlowRules.PER_GROUP is false.
local RaceScope = require(Shared:WaitForChild("RaceScope"))
local RaceAttr = require(Shared:WaitForChild("RaceAttr"))
local RaceFlowRules = require(Shared:WaitForChild("RaceFlowRules"))

local AIRacers = {}

local UP = Vector3.new(0, 1, 0)
local GRID = PlaneConfig.AI_GRID
local WEAVE = PlaneConfig.AI_WEAVE
local AVOID = PlaneConfig.AI_AVOID
local ITEMS = PlaneConfig.AI_ITEMS
local HIT = PlaneConfig.AI_HIT
local LANES = PlaneConfig.AI_LANES

-- Car maps (CarServer.activeVehicle() == "car"): bots are cars on the road. Same pacing, items and lanes as the plane
-- field; the render follows the ground under the lane with a down ray and keeps the last ride offset over jump gaps.
-- Vertical separation (lift) becomes a sideways step, since cars cannot stack.
-- "Opponent behind you appears in the air" (owner 2026-10-19): the down ray only left out workspace.Planes, so it
-- landed on the players' seated avatars (characters live outside Planes) and on item/boss fx. The server sees each
-- player's car ~0.1-0.2 s late, so a bot just BEHIND a player on that player's screen sat on the server copy of the
-- player's avatar and drove ~4 studs up in the air. The ray now leaves out every character and fx folder, ignores
-- wall-steep hits, and refuses a one-frame rise steeper than a 45 degree ramp (a stray part in the 10 studs above the
-- road) unless it persists for stepUpHold seconds. The hull is also placed AT its station and ride height each frame
-- (only its rotation is eased): the old whole-CFrame lerp trailed ~9 studs and averaged heights across crests and dips.
local CAR_BOT = {
	paceFactor = 0.97, -- road bots: corners cost the player more on the ground than in the air
	laneScale = 1.25, -- spread the plane lanes (+-12) across the 44-wide road
	maxLateral = 16,
	liftToSide = 0.7,
	rayUp = 10,
	rayDown = 30,
	maxDropBelowLine = 8, -- a ground hit further below the line than this is a gap: keep the last ride offset
	minNormalY = 0.35, -- a hit steeper than ~70 degrees is a wall or a kerb face, not road
	stepUpSlack = 1, -- studs a frame's rise may exceed a 45 degree ramp at the bot's speed
	stepUpHold = 0.3, -- s a higher ground must persist before the car takes it (a real raised deck)
	rideResponse = 25, -- 1/s the ride offset follows the road (paver seams without a pop)
	turnResponse = 14, -- 1/s the heading and tilt follow the road
	filterRefresh = 1, -- s between rebuilds of the ray's exclude list (characters come and go)
}

local function activeVehicle(): string
	local ok, v = pcall(function()
		return require(script.Parent.CarServer).activeVehicle()
	end)
	return if ok and type(v) == "string" then v else "plane"
end

-- RaceManager scores a lap-1 racer this close behind the line as negative progress (it has not crossed yet).
local BEHIND_LINE_WINDOW = 350

export type BotRacer = {
	id: number, -- index into PlaneConfig.AI_BOTS; stable for the race, ItemService/ItemEffects find bots by it
	racerId: string, -- ItemService racer id "bot:<id>"
	name: string, -- what the standings, bubbles and name tags show: a generated username (PlaneConfig.BOT_DISGUISE) or the roster name
	key: string, -- the roster name (PlaneConfig.AI_BOTS): personality, palette and taunt lookups; never shown
	isBoss: boolean,
	rosterSpeed: number, -- baseSpeed before this race's skill roll
	startDelay: number, -- s after GO before the bot leaves the grid (BotPaceRules)
	slipLeft: number,
	slipFactor: number,
	nextSlipAt: number,
	recoverLeft: number,
	plane: Model,
	hull: BasePart,
	isCar: boolean, -- drives the road (car maps) instead of flying the line
	groundOffset: number, -- car: last ride height above the line, carried over gaps
	baseSpeed: number,
	currentSpeed: number,
	laneOffset: number,
	heightOffset: number,
	station: number,
	lap: number,
	finished: boolean,
	finishTime: number,
	finishRank: number,
	weavePhase: number,
	boostTimer: number,
	boostFactor: number,
	-- grid and lane
	slot: number,
	gridLateral: number,
	gridHeight: number,
	travelled: number, -- studs flown since the last reset (grid merge, SelfTest "moving")
	lateral: number, -- current lateral offset from the line, weave included, lift excluded
	height: number, -- current height above the line, weave included, lift excluded
	weaveScale: number, -- 0 on the grid, 1 once merged into the lane (scales the weave and the separation margin)
	gridLift: number, -- start height above the slot beside a player, faded out by the merge
	lift: number, -- extra height from separation, eased toward liftTarget
	liftTarget: number,
	liftVel: number, -- studs/s of lift (the separation spring's state)
	liftUrgent: boolean, -- this frame's climb may not wait for the eased rate (contact is too near)
	laneLateral: number, -- lane centre: lateral without weave or side step (grid merge included)
	side: number, -- extra lateral from separation (a planned side step), eased toward sideTarget
	sideTarget: number,
	sideVel: number,
	-- items and hits
	itemBoostTimer: number,
	itemBoostSpeed: number,
	magnetTimer: number,
	magnetPull: number,
	slowTimer: number, -- items v4: a slow (Frost Shot, Coin Burst, patches) caps the target speed at slowFactor
	slowFactor: number,
	stunTimer: number,
	stunTotal: number,
	heldColor: string?,
	heldLevel: number,
	heldSince: number,
	itemRetryAt: number, -- os.clock before which the bot does not ask to use its item again (refusal back-off)
	itemFailures: number, -- refused uses in a row (ItemRules.botRetryDelay)
	-- attribute throttling (replication cost on phones)
	boostState: string,
	attrTimer: number,
	lastLapAttr: number,
	steer: number, -- car: front-wheel steer -1..1 from the road's curve ahead (the Steer attribute, wheels on clients)
	stepUpFor: number, -- car: seconds a higher ground hit has been refused (CAR_BOT.stepUpHold)
}

export type GridSpec = {
	station: number,
	rowSpacing: number,
	laneOffset: number,
	height: number,
}

export type RosterEntry = {
	name: string,
	color: Color3,
	accent: Color3,
	baseSpeed: number,
	boostFactor: number,
	laneOffset: number,
	heightOffset: number,
}

export type ItemContext = {
	aheadGap: number?, -- course studs to the nearest active rival ahead
	behindGap: number?, -- course studs to the nearest active rival behind
	threatBehind: boolean, -- a rival behind within AI_ITEMS.shieldThreatBehind holds a missile
	onStraight: boolean,
	boosting: boolean,
	heldFor: number,
	magnetRange: number?,
	leading: boolean?, -- items v4: this bot is first on the road (Storm Bolt has nobody to hit)
}

export type FieldInfo = {
	players: number,
	bots: number,
	need: number,
	open: boolean,
	pendingRefill: boolean,
	items: string, -- "on" | "off"
	handlers: string, -- "registered" | "missing" | "pending"
}

AIRacers.bots = {} :: { BotRacer }

------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (no Roblox instances; tools/tests/field_spec.luau)
------------------------------------------------------------------------------------------------------------------------

-- Bots for a field: every seat a player does not hold, capped by the roster. With no player, one seat stays open so an
-- empty server flies the same field a solo player gets and the first joiner needs no re-grid.
function AIRacers.botsNeeded(playerCount: number, fieldSize: number?, rosterSize: number?): number
	-- Modes (TrackDirector): the hub and time trials have no field; a boss race is 1v1 against the zone boss; a battle
	-- brings its own arena bots (server/battle/BattleBots), never route-following racers.
	if fieldSize == nil and typeof(workspace) == "Instance" then
		local mode = RaceAttr.here("RaceMode")
		if mode == "hub" or mode == "timetrial" or mode == "battle" then
			return 0
		elseif mode == "boss" or mode == "rematch" then
			return 1
		end
	end
	local field = fieldSize or PlaneConfig.AI_FIELD_SIZE
	local roster = rosterSize or #PlaneConfig.AI_BOTS
	return math.clamp(field - math.max(playerCount, 1), 0, math.max(roster, 0))
end

-- Fixed start slots for a full field rebuild, by roster index: players hold 1..playerCount, bots take the next botCount
-- slots. The grid runs forward from the line (slot 1 at the line = the BACK of the grid, higher slots further down the
-- route) and the roster is fastest first, so the fastest bot gets the frontmost slot. Since the grid-order rule
-- (shared/GridOrder, docs/design/GRID_ORDER.md) RaceManager hands resetBots a plan with the real slots; this layout is
-- the fallback (spawnBots before the first reset) and the exempt modes' grid (boss, rematch, time trial, battle, hub).
function AIRacers.botSlots(playerCount: number, botCount: number): { number }
	local first = math.max(playerCount, 1) + 1
	local slots = {}
	for i = 1, botCount do
		slots[i] = first + botCount - i
	end
	return slots
end

-- (station, lateral) of 1-based slot k on a station-based grid; the same formula as tools/map/adapt.py grid_slot.
function AIRacers.legacyGridSlot(slot: number, grid: GridSpec): (number, number)
	if slot <= 1 then
		return grid.station, 0
	end
	local row = math.floor((slot - 1) / 2)
	local lateral = if slot % 2 == 0 then grid.laneOffset else -grid.laneOffset
	return grid.station + row * grid.rowSpacing, lateral
end

-- True when a racer moving forward from prevSt to newSt (both in [0, totalLen)) passed mark this step. A mark equal to
-- prevSt was already counted on the step that reached it.
function AIRacers.crossed(prevSt: number, newSt: number, mark: number, totalLen: number): boolean
	if newSt >= prevSt then
		return mark > prevSt and mark <= newSt
	end
	-- wrapped past the line this step
	return mark > prevSt or mark <= newSt % totalLen
end

-- Signed course distance from `from` to `to`, wrapped into (-totalLen/2, totalLen/2]: positive = `to` is ahead.
function AIRacers.signedGap(from: number, to: number, totalLen: number): number
	local d = (to - from) % totalLen
	if d > totalLen * 0.5 then
		d -= totalLen
	end
	return d
end

-- Race progress in the same terms RaceManager's standings use (a lap-1 racer just behind the line is negative).
function AIRacers.progressOf(lap: number, station: number, totalLen: number): number
	if lap == 1 and station > totalLen - BEHIND_LINE_WINDOW then
		return station - totalLen
	end
	return (lap - 1) * totalLen + station
end

-- Item 19: the tighter band the race's rival flies in (OURS). It reaches the SAME ceilings sooner in both directions:
-- catches up from closer behind and eases off from closer ahead, so it stays in the player's mirror. Never above
-- 1 + RUBBER_BAND_MAX_BOOST, never below 1 - RUBBER_BAND_MAX_SLOW.
AIRacers.RIVAL_BAND = table.freeze({ behindDist = 150, behindRamp = 450, aheadDist = 120, aheadRamp = 400 })

-- Light rubber banding: the pace factor for a bot distBehind studs behind the lead player (negative: ahead of it).
function AIRacers.rubberFactor(distBehind: number, rival: boolean?): number
	local behindDist, behindRamp = PlaneConfig.RUBBER_BAND_BEHIND_DIST, 850
	local aheadDist, aheadRamp = PlaneConfig.RUBBER_BAND_AHEAD_DIST, 700
	if rival then
		local band = AIRacers.RIVAL_BAND
		behindDist, behindRamp = math.min(behindDist, band.behindDist), band.behindRamp
		aheadDist, aheadRamp = math.min(aheadDist, band.aheadDist), band.aheadRamp
	end
	if distBehind > behindDist then
		local t = math.clamp((distBehind - behindDist) / behindRamp, 0, 1)
		return 1.0 + t * PlaneConfig.RUBBER_BAND_MAX_BOOST
	elseif distBehind < -aheadDist then
		local t = math.clamp((-distBehind - aheadDist) / aheadRamp, 0, 1)
		return 1.0 - t * PlaneConfig.RUBBER_BAND_MAX_SLOW
	end
	return 1.0
end

-- Nearest rival ahead and behind along the course (physical gap, laps ignored: a missile hits whoever is in front).
-- skipIndex leaves the racer itself out; a rival exactly alongside is neither.
function AIRacers.nearestGaps(selfStation: number, stations: { number }, totalLen: number, skipIndex: number?): (number?, number?)
	local ahead: number? = nil
	local behind: number? = nil
	for i, st in stations do
		if i ~= skipIndex then
			local g = AIRacers.signedGap(selfStation, st, totalLen)
			if g > 0 then
				if ahead == nil or g < ahead then
					ahead = g
				end
			elseif g < 0 then
				if behind == nil or -g < behind then
					behind = -g
				end
			end
		end
	end
	return ahead, behind
end

function AIRacers.podInReach(dLat: number, dHeight: number, reach: number?): boolean
	local r = reach or ITEMS.podReach
	return dLat * dLat + dHeight * dHeight <= r * r
end

-- Bots take a pod when they hold nothing or when it upgrades what they hold; they never swap a held item for a
-- different colour (the item they hold is still waiting for its moment). podColor nil is a mystery cube (race pods):
-- it always upgrades what is held, so only a capped item passes it by.
function AIRacers.wantsPod(heldColor: string?, heldLevel: number, podColor: string?, maxLevel: number): boolean
	if heldColor == nil or heldLevel <= 0 then
		return true
	end
	if podColor == nil then
		return heldLevel < maxLevel
	end
	return heldColor == podColor and heldLevel < maxLevel
end

-- Course tangents now, half way and at the lookahead all within minDot of each other.
function AIRacers.isStraight(t0: Vector3, t1: Vector3, t2: Vector3, minDot: number?): boolean
	local m = minDot or ITEMS.straightMinDot
	return t0:Dot(t1) >= m and t0:Dot(t2) >= m and t1:Dot(t2) >= m
end

-- Whether to fire the held item now, and why (logged).
function AIRacers.decideItemUse(kind: string, level: number, ctx: ItemContext): (boolean, string)
	if ctx.heldFor < ITEMS.minHold then
		return false, "settling"
	end
	local ahead = ctx.aheadGap
	local behind = ctx.behindGap
	if kind == "missile" then
		if ahead and ahead >= ITEMS.missileMinAhead and ahead <= ITEMS.missileMaxAhead then
			return true, "rival_ahead"
		end
	elseif kind == "trap" then
		if behind and behind <= ITEMS.trapMaxBehind then
			return true, "rival_behind"
		end
	elseif kind == "boost" then
		if ctx.onStraight and not ctx.boosting then
			return true, "straight"
		end
	elseif kind == "shield" then
		if ctx.threatBehind then
			return true, "missile_threat"
		end
	elseif kind == "magnet" then
		-- Magnet v2: ItemEffects locks the CLOSEST racer (ItemRules.magnetPick: one in front wins a near-tie by
		-- magnetAheadTie) and a bot's pull is only added speed, so fire when that closest racer is the one ahead.
		local range = ctx.magnetRange or ItemRules.PARAMS.magnet[1].range
		local aheadWins = behind == nil or (ahead ~= nil and ahead <= behind + ItemRules.TUNING.magnetAheadTie)
		if ahead and aheadWins and ahead >= ITEMS.magnetMinAhead and ahead <= range then
			return true, "pull_rival"
		end
	-- Items v4 (docs/design/ITEMS_V4.md): one rule per special, the same thresholds as the classic items they echo.
	elseif kind == "rocket_rush" then
		if not ctx.boosting then
			return true, "rocket" -- a comeback item: fire it now, the line follower is the bot's own
		end
	elseif kind == "golden_wings" then
		if (ahead and ahead <= ITEMS.ramReach) or (behind and behind <= ITEMS.ramReach) then
			return true, "ram_rival"
		elseif ctx.onStraight and not ctx.boosting then
			return true, "straight"
		end
	elseif kind == "orbit_missiles" then
		-- The ring is a shield while held: fire one only at a rival ahead in missile reach.
		if ahead and ahead >= ITEMS.missileMinAhead and ahead <= ITEMS.missileMaxAhead then
			return true, "rival_ahead"
		end
	elseif kind == "storm_bolt" then
		if not ctx.leading then
			return true, "leader_hit"
		end
	elseif kind == "boom_bomb" then
		if ahead and ahead >= ITEMS.bombMinAhead and ahead <= ITEMS.bombMaxAhead then
			return true, "bomb_ahead"
		end
	elseif kind == "frost_shot" or kind == "coin_burst" then
		if ahead and ahead >= ITEMS.missileMinAhead and ahead <= ITEMS.shotMaxAhead then
			return true, "shot_ahead"
		end
	elseif kind == "gift_box" then
		if ahead and ahead >= ITEMS.missileMinAhead and ahead <= ITEMS.missileMaxAhead then
			return true, "gift_ahead"
		elseif ctx.onStraight and not ctx.boosting then
			return true, "straight"
		end
	elseif kind == "bubble_guard" then
		if ctx.threatBehind then
			return true, "missile_threat"
		end
	else
		return false, "unknown_kind"
	end
	if ctx.heldFor >= ITEMS.maxHold then
		return true, "hold_timeout"
	end
	return false, "wait"
end

-- Cross-section clearance of two planes at the same course station (AI_AVOID envelope).
function AIRacers.planesClear(dLat: number, dHeight: number): boolean
	return math.abs(dLat) >= AVOID.span or math.abs(dHeight) >= AVOID.clearHeight
end

-- Lift the upper plane needs so it clears the lower one (whose own lift is already applied), clamped to maxLift.
function AIRacers.requiredLift(dLat: number, upperHeight: number, lowerHeight: number, lowerLift: number): number
	if math.abs(dLat) >= AVOID.span then
		return 0
	end
	local need = AVOID.clearHeight - (upperHeight - (lowerHeight + lowerLift))
	return math.clamp(need, 0, AVOID.maxLift)
end

-- Sets sideTarget and liftTarget on every bot (planned passes; owner 2026-10-19: bots "constantly bumping").
-- A pair conflicts when it overlaps along the course, follows within AI_AVOID.near once merged, or closes inside the
-- look-ahead (the static `lookahead`, or `planSeconds` of gap closure for a fast closure: a boosted bot onto a slower
-- one starts its pass well out, not 45 studs out), and its lane CENTRES (weave excluded, so the test does not flicker
-- with the weave) are within span plus both planes' weave swing.
-- Side first: two merged bots on different lanes step apart sideways (each up to maxSide, the higher lane to the
-- right), which clears most pairs with no climb at all. A pair the side step cannot clear (the same lane, or a bot
-- squeezed from both sides) gets the higher-tier plane lifted. The climber is fixed by its lane tier (heightOffset,
-- then id), never by the current lift: the order is acyclic, so one pass from the lowest tier up settles a whole
-- stack. While a side step is still easing in and contact is nearer than the step can finish, the CURRENT side counts
-- (the lift covers the rest). Separating pairs (a faster bot ahead, the grid at the start) are left alone.
-- O(bots^2), bots <= 7.
local liftOrder: { BotRacer } = {}
local pairUpper: { BotRacer } = {}
local pairLower: { BotRacer } = {}
local pairContact: { number } = {}
local sidePlus: { [BotRacer]: number } = {}
local sideMinus: { [BotRacer]: number } = {}

local function tierBelow(a: BotRacer, b: BotRacer): boolean
	if a.heightOffset ~= b.heightOffset then
		return a.heightOffset < b.heightOffset
	end
	return a.id < b.id
end

-- Lateral of a bot's lane centre (the bare lateral for callers that track no lane centre).
local function laneOf(bot: BotRacer): number
	return bot.laneLateral or bot.lateral
end

-- Lane-centre separation of a pair (upper minus lower). While either is still merging off the grid, the closer of
-- the current and the final lane separation: a row whose lanes converge plans its climb from the first metre, since
-- row-mates already overlap along the course and there is no look-ahead left to ease it in.
local function laneGap(upper: BotRacer, lower: BotRacer): number
	local now = laneOf(upper) - laneOf(lower)
	if (upper.weaveScale < 1 or lower.weaveScale < 1) and upper.laneOffset and lower.laneOffset then
		local final = upper.laneOffset - lower.laneOffset
		if math.abs(final) < math.abs(now) then
			return final
		end
	end
	return now
end

-- Seconds until two bots `absGap` course studs apart (centre to centre) touch along the course at `closing` studs/s:
-- 0 when they already overlap, math.huge when they are not closing.
function AIRacers.contactTime(absGap: number, closing: number): number
	if absGap < AVOID.length then
		return 0
	elseif closing <= 1e-3 then
		return math.huge
	end
	return (absGap - AVOID.length) / closing
end

-- Course window inside which a pair closing at `closing` studs/s is a conflict (the planned look-ahead).
function AIRacers.planWindow(closing: number): number
	return AVOID.length + math.max(AVOID.lookahead, math.max(closing, 0) * AVOID.planSeconds)
end

-- Side step each of two lanes `dLane` apart takes so they clear span plus `swing` (0 when already clear; nil when two
-- steps of maxSide cannot do it, or the lanes coincide and there is no side to step to).
function AIRacers.sideStepFor(dLane: number, swing: number): number?
	local need = AVOID.span + swing + AVOID.sideMargin - math.abs(dLane)
	if need <= 0 then
		return 0
	end
	if math.abs(dLane) < 0.5 or need > 2 * AVOID.maxSide then
		return nil
	end
	return need / 2
end

function AIRacers.solveLifts(list: { BotRacer }, totalLen: number)
	table.clear(liftOrder)
	table.clear(pairUpper)
	table.clear(pairLower)
	table.clear(pairContact)
	table.clear(sidePlus)
	table.clear(sideMinus)
	for _, bot in list do
		bot.liftTarget = 0
		bot.liftUrgent = false
		table.insert(liftOrder, bot)
	end
	table.sort(liftOrder, tierBelow)
	-- Pass 1: conflicting pairs (in tier order of the upper plane) and their side steps.
	for u = 2, #liftOrder do
		local upper = liftOrder[u]
		for l = 1, u - 1 do
			local lower = liftOrder[l]
			local gap = AIRacers.signedGap(lower.station, upper.station, totalLen) -- > 0: upper is ahead
			local absGap = math.abs(gap)
			local trailer, leader = if gap > 0 then lower else upper, if gap > 0 then upper else lower
			local closing = trailer.currentSpeed - leader.currentSpeed
			-- Merged bots in close file keep their stagger whatever their speeds: a spin-out one length ahead closes in
			-- under 0.1 s, faster than any eased pass could start. Not on the grid, where rows sit exactly one length apart.
			local merged = upper.weaveScale >= 1 and lower.weaveScale >= 1
			local close = absGap < AVOID.length or (merged and absGap < AVOID.length + AVOID.near)
			local conflict = close or (absGap < AIRacers.planWindow(closing) and closing > 0)
			if conflict then
				local swing = WEAVE.lateral * (upper.weaveScale + lower.weaveScale)
				local dLane = laneGap(upper, lower)
				if math.abs(dLane) < AVOID.span + swing then
					table.insert(pairUpper, upper)
					table.insert(pairLower, lower)
					table.insert(pairContact, if close then 0 else AIRacers.contactTime(absGap, closing))
					-- Only merged bots step aside: on the grid the merge itself is moving them to their lanes.
					local step = if merged then AIRacers.sideStepFor(dLane, swing) else nil
					if step and step > 0 then
						local hi, lo = if dLane > 0 then upper else lower, if dLane > 0 then lower else upper
						sidePlus[hi] = math.max(sidePlus[hi] or 0, step)
						sideMinus[lo] = math.max(sideMinus[lo] or 0, step)
					end
				end
			end
		end
	end
	for _, bot in list do
		bot.sideTarget = (sidePlus[bot] or 0) - (sideMinus[bot] or 0)
	end
	-- Pass 2: lifts for the pairs the side steps do not clear, in tier order (a lower plane's target is final first).
	for i, upper in pairUpper do
		local lower = pairLower[i]
		local swing = WEAVE.lateral * (upper.weaveScale + lower.weaveScale)
		local dLane = laneGap(upper, lower)
		local planned = math.abs(dLane + upper.sideTarget - lower.sideTarget)
		local current = math.abs(dLane + (upper.side or 0) - (lower.side or 0))
		local easing = math.max(math.abs(upper.sideTarget - (upper.side or 0)), math.abs(lower.sideTarget - (lower.side or 0)))
		local ready = pairContact[i] > easing / AVOID.sideRate + AVOID.settleSeconds
		local sep = if ready then planned else math.min(planned, current)
		if sep < AVOID.span + swing then
			local need = AIRacers.requiredLift(0, upper.height, lower.height, math.max(lower.lift, lower.liftTarget))
			if need > 0 then
				need = math.min(need + AVOID.liftMargin, AVOID.maxLift)
			end
			if need > upper.liftTarget then
				upper.liftTarget = need
			end
			-- Contact sooner than the eased climb can finish (a spin-out or a ring boost right behind, a converging
			-- grid row): this climb may go at urgentClimbRate. Rare by design; the field spec counts it.
			local deficit = need - upper.lift
			if deficit > AVOID.urgentDeficit and pairContact[i] < deficit / AVOID.climbRate + AVOID.settleSeconds then
				upper.liftUrgent = true
			end
		end
	end
end

-- One frame of a critically damped spring toward `target` (natural rate AVOID.response, or `rate`), its speed capped
-- at `upCap` rising and `downCap` falling and its acceleration at AVOID.accel (or `accel`): no step in position or
-- speed, no overshoot, never faster than a plane plausibly climbs or slides.
function AIRacers.springStep(
	x: number,
	v: number,
	target: number,
	dt: number,
	upCap: number,
	downCap: number,
	rate: number?,
	accel: number?
): (number, number)
	local h = math.clamp(dt, 0, 0.1)
	local w = rate or AVOID.response
	local cap = accel or AVOID.accel
	local a = math.clamp(w * w * (target - x) - 2 * w * v, -cap, cap)
	local nv = math.clamp(v + a * h, -downCap, upCap)
	return x + nv * h, nv
end

-- Eases lift and side step toward their targets: climbs at most climbRate, sinks at most fallRate, slides at most
-- sideRate (studs/s). Passes are planned seconds out, so the eased climb is done before the planes meet.
function AIRacers.approachLift(bot: BotRacer, dt: number)
	local urgent = bot.liftUrgent == true
	local lift, liftVel = AIRacers.springStep(
		bot.lift,
		bot.liftVel or 0,
		bot.liftTarget,
		dt,
		if urgent then AVOID.urgentClimbRate else AVOID.climbRate,
		AVOID.fallRate,
		if urgent then AVOID.urgentResponse else AVOID.response,
		if urgent then AVOID.urgentAccel else AVOID.accel
	)
	if lift < 0 then
		lift, liftVel = 0, 0
	end
	bot.lift, bot.liftVel = lift, liftVel
	bot.side, bot.sideVel = AIRacers.springStep(bot.side or 0, bot.sideVel or 0, bot.sideTarget or 0, dt, AVOID.sideRate, AVOID.sideRate)
end

-- The bot that gives up its seat when a player joins mid-race: the last-placed bot still racing (fewest standings
-- changes for everyone else); with every bot finished, the last-placed one.
-- The bots a field trim may take: every bot but the boss, unless the boss is all that is left.
function AIRacers.trimCandidates(list: { BotRacer }): { BotRacer }
	local out: { BotRacer } = {}
	for _, bot in list do
		if not bot.isBoss then
			table.insert(out, bot)
		end
	end
	return if #out > 0 then out else list
end

function AIRacers.pickTrimVictim(list: { BotRacer }, totalLen: number): BotRacer?
	local best: BotRacer? = nil
	local bestProgress = math.huge
	local bestFinished = true
	for _, bot in list do
		local p = AIRacers.progressOf(bot.lap, bot.station, totalLen)
		local better = if bestFinished and not bot.finished then true
			elseif bot.finished and not bestFinished then false
			else p < bestProgress
		if best == nil or better then
			best = bot
			bestProgress = p
			bestFinished = bot.finished
		end
	end
	return best
end

local function parseBotRacerId(s: string): number?
	local num = string.match(s, "^bot:(%-?%d+)$")
	return if num then tonumber(num) else nil
end

local function isRacerId(s: string): boolean
	return string.match(s, "^%a+:%-?%d+$") ~= nil
end

-- Hit arguments as ItemService documents them, fn(botId, stunSeconds, source), with tolerance for a racer id string or
-- an effect table ({botId|racerId, stunSeconds|seconds, source|kind}) so a later signature tweak cannot drop hits.
-- Returns botId (nil when none found), stun seconds (default AI_HIT.defaultStun) and the source label.
-- A hit that names a non-bot racer first ("player:<id>") is not a bot hit: the number after it is never read as a bot
-- id (that would spin out bot <stunSeconds>), and a racer id after the target (an attacker) is neither target nor source.
function AIRacers.parseHitArgs(...: any): (number?, number, string)
	local botId: number? = nil
	local foreign = false
	local seconds: number? = nil
	local source: string? = nil
	local args = table.pack(...)
	for i = 1, args.n do
		local v = args[i]
		if type(v) == "number" then
			if botId == nil and not foreign then
				botId = v
			elseif seconds == nil then
				seconds = v
			end
		elseif type(v) == "string" then
			if isRacerId(v) then
				if botId == nil and not foreign then
					local id = parseBotRacerId(v)
					if id then
						botId = id
					else
						foreign = true
					end
				end
			elseif source == nil then
				source = v
			end
		elseif type(v) == "table" then
			local t = v :: { [string]: any }
			if botId == nil and not foreign then
				if type(t.botId) == "number" then
					botId = t.botId
				elseif type(t.racerId) == "string" then
					botId = parseBotRacerId(t.racerId)
					foreign = botId == nil
				end
			end
			if seconds == nil then
				if type(t.stunSeconds) == "number" then
					seconds = t.stunSeconds
				elseif type(t.seconds) == "number" then
					seconds = t.seconds
				end
			end
			if source == nil then
				if type(t.source) == "string" then
					source = t.source
				elseif type(t.kind) == "string" then
					source = t.kind
				end
			end
		end
	end
	local s = if seconds and seconds > 0 then seconds else HIT.defaultStun
	return botId, math.clamp(s, HIT.minStun, HIT.maxStun), source or "item"
end

local function rgbDistance(a: Color3, b: Color3): number
	local dr, dg, db = (a.R - b.R) * 255, (a.G - b.G) * 255, (a.B - b.B) * 255
	return math.sqrt(dr * dr + dg * dg + db * db)
end

-- Roster sanity for SelfTest and the spec: unique names, distinct colours, unique lanes inside the AI_LANES box,
-- positive pace. Also returns the static spread: the smallest pairwise max(|dLat|/span, |dHeight|/clearHeight).
function AIRacers.validateRoster(roster: { RosterEntry }): (boolean, string, number)
	local problems: { string } = {}
	local spread = math.huge
	for i, a in roster do
		if a.name == "" then
			table.insert(problems, string.format("#%d unnamed", i))
		end
		if math.abs(a.laneOffset) > LANES.maxLateral then
			table.insert(problems, string.format("%s lane %.1f outside +-%d", a.name, a.laneOffset, LANES.maxLateral))
		end
		if a.heightOffset < LANES.minHeight or a.heightOffset > LANES.maxHeight then
			table.insert(problems, string.format("%s height %.1f outside %d..%d", a.name, a.heightOffset, LANES.minHeight, LANES.maxHeight))
		end
		if not (a.baseSpeed > 0 and a.boostFactor > 0) then
			table.insert(problems, a.name .. " pace not positive")
		end
		for j = i + 1, #roster do
			local b = roster[j]
			if a.name == b.name then
				table.insert(problems, "duplicate name " .. a.name)
			end
			if a.laneOffset == b.laneOffset then
				table.insert(problems, string.format("%s and %s share lane %.1f", a.name, b.name, a.laneOffset))
			end
			if rgbDistance(a.color, b.color) < 60 then
				table.insert(problems, string.format("%s and %s colours too close", a.name, b.name))
			end
			local s = math.max(math.abs(a.laneOffset - b.laneOffset) / AVOID.span, math.abs(a.heightOffset - b.heightOffset) / AVOID.clearHeight)
			spread = math.min(spread, s)
		end
	end
	return #problems == 0, if #problems == 0 then "ok" else table.concat(problems, "; "), spread
end

------------------------------------------------------------------------------------------------------------------------
-- ItemService access (lazy: ItemService requires this module from inside its functions, so neither side may require
-- the other at load time; every call is guarded so bots still race when items are not wired)
------------------------------------------------------------------------------------------------------------------------

local itemServiceModule: any = nil
local itemServiceTried = false
local itemsOffLogged = false
local handlersState = "pending"
local handlersCheckAt = -math.huge

local function itemService(): any
	if itemServiceTried then
		return itemServiceModule
	end
	itemServiceTried = true
	local inst = script.Parent:FindFirstChild("ItemService")
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok then
			itemServiceModule = mod
		else
			print("[SkyRally][AI] ItemService failed to load; bots race without items: " .. tostring(mod))
		end
	else
		print("[SkyRally][AI] ItemService not found; bots race without items")
	end
	return itemServiceModule
end

-- Items are live once ItemService.start has run (init.server starts it after RaceManager.init).
local function itemsLive(): boolean
	local IS = itemService()
	local live = IS ~= nil and IS.active ~= nil and type(IS.pickup) == "function" and type(IS.use) == "function"
		and type(IS.getState) == "function"
	if not live and not itemsOffLogged then
		itemsOffLogged = true
		print("[SkyRally][AI] items off until ItemService.start runs (bots skip pods and never fire)")
	end
	return live
end

local function heldState(racerId: string): (string?, number)
	local IS = itemService()
	if not IS or type(IS.getState) ~= "function" then
		return nil, 0
	end
	local ok, state = pcall(IS.getState, racerId)
	if ok and type(state) == "table" and type(state.level) == "number" then
		return state.color, state.level
	end
	return nil, 0
end

local function levelOneOnly(): boolean
	local IS = itemService()
	local svc = if IS then IS.active else nil
	if svc and type(svc.isLevelOneOnly) == "function" then
		return svc.isLevelOneOnly() == true
	end
	return false
end

local function racerIdForBot(botId: number): string
	local IS = itemService()
	if IS and type(IS.botRacerId) == "function" then
		return IS.botRacerId(botId)
	end
	return "bot:" .. tostring(botId)
end

local function racerIdForPlayer(userId: number): string
	local IS = itemService()
	if IS and type(IS.playerRacerId) == "function" then
		return IS.playerRacerId(userId)
	end
	return "player:" .. tostring(userId)
end

local function findBot(botId: number): BotRacer?
	for _, bot in AIRacers.bots do
		if bot.id == botId then
			return bot
		end
	end
	return nil
end

------------------------------------------------------------------------------------------------------------------------
-- Item effects on bots (registered with ItemService; also callable directly, e.g. by battle modes)
------------------------------------------------------------------------------------------------------------------------

-- Spin-out: speed cut to AI_HIT.speedFactor, boosts cancelled, a barrel roll over the stun. A shielded or finished bot
-- ignores it. Returns true when the hit took.
function AIRacers.applyHit(botId: number, stunSeconds: number?, source: string?): boolean
	local bot = findBot(botId)
	if not bot or bot.finished or not (bot.hull and bot.hull.Parent) then
		return false
	end
	local IS = itemService()
	if IS and type(IS.isShielded) == "function" and IS.isShielded(bot.racerId) == true then
		return false
	end
	local s = math.clamp(if stunSeconds and stunSeconds > 0 then stunSeconds else HIT.defaultStun, HIT.minStun, HIT.maxStun)
	bot.stunTimer = math.max(bot.stunTimer, s)
	bot.stunTotal = bot.stunTimer
	bot.boostTimer = 0
	bot.itemBoostTimer = 0
	bot.magnetTimer = 0
	bot.plane:SetAttribute("Stunned", true)
	print(string.format("[SkyRally][AI] hit bot=%s source=%s stun=%.2f", bot.name, source or "item", bot.stunTimer))
	return true
end

-- Item boost (blue) a bot fired: same pace scaling as its ring boosts (boostFactor, rubber band).
function AIRacers.applyBoost(botId: number, seconds: number, speed: number?)
	local bot = findBot(botId)
	if not bot or seconds <= 0 then
		return
	end
	local s = speed or PlaneConfig.BOOST_SPEED
	-- A second boost while one runs keeps the stronger speed and the longer time.
	bot.itemBoostSpeed = if bot.itemBoostTimer > 0 then math.max(bot.itemBoostSpeed, s) else s
	bot.itemBoostTimer = math.max(bot.itemBoostTimer, seconds)
end

-- Magnet (rainbow) a bot fired: ItemEffects already checked the closest racer is ahead and in range; the pull is added
-- speed until the time runs out or ItemEffects reports contact ("magnetEnd").
function AIRacers.applyMagnet(botId: number, seconds: number, pull: number)
	local bot = findBot(botId)
	if not bot or seconds <= 0 then
		return
	end
	bot.magnetTimer = math.max(bot.magnetTimer, seconds)
	bot.magnetPull = math.max(0, pull)
end

local function onBotHit(...: any)
	local botId, seconds, source = AIRacers.parseHitArgs(...)
	if botId then
		AIRacers.applyHit(botId, seconds, source)
	end
end

local function onBotEffect(botId: any, effect: any)
	if type(botId) ~= "number" or type(effect) ~= "table" then
		return
	end
	local seconds = if type(effect.seconds) == "number" then effect.seconds else 0
	if effect.kind == "hit" then
		AIRacers.applyHit(botId, seconds, if type(effect.source) == "string" then effect.source else "item")
	elseif effect.kind == "boost" then
		AIRacers.applyBoost(botId, seconds, if type(effect.speed) == "number" then effect.speed else nil)
	elseif effect.kind == "magnet" then
		AIRacers.applyMagnet(botId, seconds, if type(effect.pull) == "number" then effect.pull else 0)
	elseif effect.kind == "slow" then
		-- Items v4: ItemEffects already combined it (ItemRules.combineSlow); the bot just runs it.
		local bot = findBot(botId)
		if bot and seconds > 0 then
			bot.slowTimer = seconds
			bot.slowFactor = math.clamp(if type(effect.factor) == "number" then effect.factor else 1, ItemRules.SLOW.floor, 1)
		end
	elseif effect.kind == "magnetEnd" then
		-- Magnet v2: ItemEffects saw the bot reach its target (contact); the pull stops there.
		local bot = findBot(botId)
		if bot then
			bot.magnetTimer = 0
		end
	end
	-- "shield": ItemService keeps the timer and ItemEffects draws the bubble; nothing changes in bot motion.
end

-- Registers the hit and effect handlers once ItemService offers them; rechecked every 2 s, logged once if missing.
local function ensureItemHandlers(now: number)
	if handlersState == "registered" or now < handlersCheckAt then
		return
	end
	handlersCheckAt = now + 2
	local IS = itemService()
	if not IS then
		return
	end
	local setHit = IS.setBotHitHandler
	if type(setHit) == "function" then
		setHit(onBotHit)
		local setEffect = IS.setBotEffectHandler
		local effectOk = type(setEffect) == "function"
		if effectOk then
			setEffect(onBotEffect)
		end
		-- Item 19: bots answer hits on them and by them with a taunt bubble.
		if type(IS.setHitListener) == "function" then
			IS.setHitListener(function(victim: string, attacker: string, kind: string, chain: number)
				AIRacers.onHitTaunt(victim, attacker, kind, chain)
			end)
		end
		handlersState = "registered"
		print(string.format("[SkyRally][AI] item handlers registered hit=yes effect=%s", if effectOk then "yes" else "missing"))
	elseif handlersState ~= "missing" then
		handlersState = "missing"
		print("[SkyRally][AI] ItemService.setBotHitHandler missing; bots ignore item hits until it exists")
	end
end

------------------------------------------------------------------------------------------------------------------------
-- Track marks: boost triggers and item pods projected to stations once per track
------------------------------------------------------------------------------------------------------------------------

type PodMark = {
	name: string,
	station: number,
	lateral: number,
	height: number,
	color: string,
	mystery: boolean, -- a race mystery cube: `color` is plan data only, the item is rolled on pickup
	part: BasePart,
}

-- Economy v3 phase 2b (docs/design/PER_GROUP_RACES.md): one field's state (the bots, the race clock, the rival and
-- taunts, the item and taunt cadences, the fixed-step clock and the track marks). shared/RaceScope keeps one table per
-- field: on the single-race path that is a single table for the life of the server (the old module locals); per group
-- each RaceInstance's field is stepped inside RaceScope.run(id, ...) and has its own. AIRacers.bots reads the running
-- field's list (metatable below), so RaceManager, ItemService and ItemEffects see only their own field's bots.
type FieldState = {
	bots: { BotRacer },
	raceClock: number, -- raceElapsed of the latest step since the last spawn/reset
	fieldOpenOverride: boolean?,
	pendingRefill: boolean,
	rivalId: number?, -- roster id of the solo player's rival this race
	rivalSeq: number, -- races since server start: rotates which bot is the rival
	tauntVoice: any,
	tauntStartSaid: boolean,
	tauntSides: { [number]: { [any]: number } }, -- bot id -> player -> +1 bot ahead / -1 behind
	tauntFinished: { [number]: boolean },
	itemTimer: number,
	tauntTimer: number,
	stepClock: RacerViewRules.ServerClock,
	boostStations: { number },
	boostPadAt: { [number]: Instance }, -- ground pad model by station; its PadLive attribute can switch it off (M-2)
	boostGateAt: { [number]: SailGateRules.Config }, -- FOREST-1 sail-gap ring by station: gives nothing while a sail covers it
	podMarks: { PodMark },
	marksKey: string,
	marksScanAt: number,
}
local function newFieldState(): FieldState
	return {
		bots = {},
		raceClock = 0,
		fieldOpenOverride = nil,
		pendingRefill = false,
		rivalId = nil,
		rivalSeq = 0,
		tauntVoice = nil,
		tauntStartSaid = false,
		tauntSides = {},
		tauntFinished = {},
		itemTimer = 0,
		tauntTimer = 0,
		stepClock = RacerViewRules.newServerClock(),
		boostStations = {},
		boostPadAt = {},
		boostGateAt = {},
		podMarks = {},
		marksKey = "",
		marksScanAt = -math.huge,
	}
end
local function F(): FieldState
	return RaceScope.state("AIRacers", newFieldState)
end
;(AIRacers :: any).bots = nil
setmetatable(AIRacers :: any, {
	__index = function(_: any, k: string): any
		return if k == "bots" then F().bots else nil
	end,
	__newindex = function(t: any, k: string, v: any)
		if k == "bots" then
			F().bots = v
		else
			rawset(t, k, v)
		end
	end,
})

-- A track whose Boosts folder is not built yet is rescanned at this interval, never every frame.
local MARKS_RESCAN_EMPTY = 2.0

local function rightOf(tan: Vector3): Vector3
	local r = tan:Cross(UP)
	return if r.Magnitude > 0.01 then r.Unit else Vector3.new(1, 0, 0)
end

local function refreshTrackMarks(totalLen: number)
	local key = TrackRegistry.getActiveId() .. ":" .. string.format("%.1f", totalLen)
	local now = os.clock()
	if key == F().marksKey and (#F().boostStations + #F().podMarks > 0 or now - F().marksScanAt < MARKS_RESCAN_EMPTY) then
		return
	end
	F().marksKey = key
	F().marksScanAt = now
	table.clear(F().boostStations)
	table.clear(F().boostPadAt)
	table.clear(F().boostGateAt)
	table.clear(F().podMarks)
	local folder = TrackRegistry.getBoostsFolder()
	if not folder then
		return
	end
	-- Bots get the same 1.8 s boost a player gets from flying through rings and pads, so pace stays comparable.
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			local tt = d:GetAttribute("TriggerType")
			if TriggerRules.botBoost(tt, d:GetAttribute(TriggerRules.LINE_ATTR)) then
				local st = SplineUtils.projectPosition(d.Position)
				table.insert(F().boostStations, st)
				if tt == "GroundBoostPad" and d.Parent then
					F().boostPadAt[st] = d.Parent
				end
				local gate = if tt == "BoosterRing" then SailGateRules.configOf(d) else nil
				if gate then
					F().boostGateAt[st] = gate
				end
			elseif d:GetAttribute("ItemPodSpawn") == true then
				local podClass, color = ItemRules.classifyPod(d:GetAttribute("PodType"))
				if podClass == "item" and color then
					local st = SplineUtils.projectPosition(d.Position)
					local pos, tan = SplineUtils.sampleAtStation(st)
					local rel = d.Position - pos
					table.insert(F().podMarks, {
						name = d.Name,
						station = st,
						lateral = rel:Dot(rightOf(tan)),
						height = rel.Y,
						color = color,
						mystery = d:GetAttribute("MysteryCube") == true,
						part = d,
					})
				end
			end
		end
	end
	table.sort(F().boostStations)
	table.sort(F().podMarks, function(a: PodMark, b: PodMark): boolean
		return a.station < b.station
	end)
	print(string.format("[SkyRally][AI] track marks %s boosts=%d itemPods=%d", key, #F().boostStations, #F().podMarks))
end

------------------------------------------------------------------------------------------------------------------------
-- Field: seats, grid, joins and leaves
------------------------------------------------------------------------------------------------------------------------

type Pose = { station: number, lateral: number, height: number }


------------------------------------------------------------------------------------------------------------------------
-- Item 19: personalities, the rival and taunts (state; the per-step watcher is next to AIRacers.step)
------------------------------------------------------------------------------------------------------------------------

-- Shared.BotPersonality, loaded on first use; nil (and taunts and the rival off) when it cannot load.
local personalityModule: any = nil
local personalityTried = false
local function personality(): any
	if not personalityTried then
		personalityTried = true
		local ok, mod = pcall(function(): any
			return (require :: any)(Shared:WaitForChild("BotPersonality"))
		end)
		personalityModule = if ok and type(mod) == "table" then mod else nil
		if not personalityModule then
			print("[SkyRally][AI] BotPersonality unavailable; bots race without taunts or a rival")
		end
	end
	return personalityModule
end


-- The standings name of this race's rival bot (nil when the solo rivalry is off); RaceManager publishes who is ahead.
function AIRacers.rivalName(): string?
	local rid = F().rivalId
	local r = if rid then findBot(rid) else nil
	return if r then r.name else nil
end

-- Picks (or keeps) the rival and tags every bot's model with its personality and the Rival flag.
local function assignRival(playerCount: number, keep: boolean)
	local BP = personality()
	if not BP then
		F().rivalId = nil
		return
	end
	local prev = F().rivalId
	F().rivalId = nil
	local mode = RaceAttr.here("RaceMode")
	if playerCount == 1 and mode ~= "boss" and mode ~= "rematch" then
		local ids: { number } = {}
		for _, bot in AIRacers.bots do
			if not bot.isBoss then -- the storm dragon is the field's boss, never its rival
				table.insert(ids, bot.id)
			end
		end
		if keep and prev and table.find(ids, prev) then
			F().rivalId = prev
		else
			F().rivalId = BP.pickRival(ids, F().rivalSeq)
		end
	end
	for _, bot in AIRacers.bots do
		if bot.plane then
			bot.plane:SetAttribute("Rival", bot.id == F().rivalId)
			bot.plane:SetAttribute("Personality", BP.forName(bot.key))
			bot.plane:SetAttribute("RivalTitle", BP.TITLE[BP.forName(bot.key)] or "")
		end
	end
	if F().rivalId ~= prev then
		local r = findBot(F().rivalId or -1)
		print(string.format("[SkyRally][AI] rival=%s", if r then r.name else "none"))
	end
end
local listenersConnected = false

local function countPlayers(excluding: Player?): number
	local n = 0
	-- Per group: the humans of this field only (RaceScope.players); every player on the single-race path.
	for _, p in RaceScope.players(Players:GetPlayers()) do
		if p ~= excluding then
			n += 1
		end
	end
	return n
end

-- A lobby/countdown (L6) can hold the field open while players gather and close it at "go"; without it the field is
-- open for the first AI_FIELD_OPEN_SECONDS of each race.
function AIRacers.setFieldOpen(open: boolean?)
	F().fieldOpenOverride = open
end

function AIRacers.isFieldOpen(): boolean
	local override = F().fieldOpenOverride
	if override ~= nil then
		return override
	end
	return F().raceClock < PlaneConfig.AI_FIELD_OPEN_SECONDS
end

function AIRacers.fieldInfo(): FieldInfo
	local players = countPlayers(nil)
	return {
		players = players,
		bots = #AIRacers.bots,
		need = AIRacers.botsNeeded(players),
		open = AIRacers.isFieldOpen(),
		pendingRefill = F().pendingRefill,
		items = if itemServiceModule ~= nil and itemServiceModule.active ~= nil then "on" else "off",
		handlers = handlersState,
	}
end

-- Slot -> course pose: the registered start CFrame projected onto the spline, else the station-based grid.
local function slotPose(slot: number, totalLen: number): Pose
	local cf = TrackRegistry.startCFrame(slot)
	if cf then
		local st = SplineUtils.projectPosition(cf.Position)
		local pos, tan = SplineUtils.sampleAtStation(st)
		local rel = cf.Position - pos
		return { station = st, lateral = rel:Dot(rightOf(tan)), height = rel.Y }
	end
	local st, lat = AIRacers.legacyGridSlot(slot, GRID)
	return { station = st % totalLen, lateral = lat, height = GRID.height }
end

local function poseCFrame(station: number, lateral: number, height: number): CFrame
	local pos, tan, bank = SplineUtils.sampleAtStation(station)
	local p = pos + rightOf(tan) * lateral + Vector3.new(0, height, 0)
	return CFrame.lookAt(p, p + tan) * CFrame.Angles(0, 0, math.rad(bank))
end

local function slotCFrame(slot: number, totalLen: number): CFrame
	local pose = slotPose(slot, totalLen)
	return poseCFrame(pose.station, pose.lateral, pose.height)
end

local function getPlanesFolder(): Folder
	local existing = workspace:FindFirstChild("Planes")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "Planes"
	f.Parent = workspace
	return f
end

local function resetRaceState(bot: BotRacer)
	bot.lap = 1
	bot.finished = false
	bot.finishTime = 0
	bot.finishRank = 0
	-- Economy v3 phase 4: a fresh skill roll, start delay and first slip each race (the boss keeps its own pace)
	if bot.isBoss or not PlaneConfig.BOT_DISGUISE then
		bot.baseSpeed = bot.rosterSpeed
		bot.startDelay = 0
		bot.nextSlipAt = math.huge
	else
		bot.baseSpeed = bot.rosterSpeed * BotPaceRules.skill(math.random)
		bot.startDelay = BotPaceRules.startDelay(math.random)
		bot.nextSlipAt = BotPaceRules.nextSlipAt(math.random, 0)
	end
	bot.slipLeft = 0
	bot.slipFactor = 1
	bot.recoverLeft = 0
	bot.currentSpeed = bot.baseSpeed
	bot.boostTimer = 0
	bot.itemBoostTimer = 0
	bot.itemBoostSpeed = 0
	bot.magnetTimer = 0
	bot.magnetPull = 0
	bot.slowTimer = 0
	bot.slowFactor = 1
	bot.stunTimer = 0
	bot.stunTotal = 0
	bot.heldColor = nil
	bot.heldLevel = 0
	bot.heldSince = 0
	bot.itemRetryAt, bot.itemFailures = 0, 0
	bot.lift = 0
	bot.liftTarget = 0
	bot.liftVel = 0
	bot.side = 0
	bot.sideTarget = 0
	bot.sideVel = 0
	bot.travelled = 0
	bot.weaveScale = 0
	bot.gridLift = 0
	bot.weavePhase = bot.id * 2.0
	bot.lastLapAttr = 0
	bot.attrTimer = 0
	bot.boostState = "None"
	bot.plane:SetAttribute("BoostState", "None")
	bot.plane:SetAttribute("Stunned", false)
end

-- Economy v3 phase 4: the start delays rolled in resetRaceState, dealt front of the grid first (shortest to the
-- frontmost bot), so no bot is still parked while the one behind it is already moving: a random order put a launching bot
-- wing through wing into a waiting one in the first half second (field spec, real-step separation).
local function orderStartDelays(totalLen: number)
	local waiting: { BotRacer } = {}
	local delays: { number } = {}
	for _, bot in AIRacers.bots do
		if bot.startDelay > 0 then
			table.insert(waiting, bot)
			table.insert(delays, bot.startDelay)
		end
	end
	if #waiting < 2 then
		return
	end
	table.sort(delays)
	table.sort(waiting, function(a: BotRacer, b: BotRacer): boolean
		return AIRacers.signedGap(b.station, a.station, totalLen) > 0 -- a ahead of b
	end)
	for i, bot in waiting do
		bot.startDelay = delays[i]
	end
end

-- Puts a bot on its slot. A bot slot sharing a row with a player slot (slot 2 beside the pole) would put wing through
-- wing, so it starts one clearance higher; that grid lift fades with the merge (not the faster separation decay)
-- because the player beside it is still level with it until the bot has moved out to its lane.
local function placeOnGrid(bot: BotRacer, slot: number, totalLen: number, playerPoses: { Pose })
	local pose = slotPose(slot, totalLen)
	local gridLift = 0
	local boss = if bot.plane:GetAttribute("IsBoss") == true then BossConfig.forZone(bot.plane:GetAttribute("BossZone") :: string?) else nil
	if boss then
		-- A boss is up to ~28 studs long: on slot 2 it sat through the pole player. It waits centred on the course just
		-- ahead of the line instead, in full view of the intro camera, and the race starts as a chase.
		local pole = slotPose(1, totalLen)
		pose = { station = (pole.station + boss.length * 1.1 + 12) % totalLen, lateral = 0, height = pole.height }
	else
		for _, pp in playerPoses do
			if math.abs(AIRacers.signedGap(pose.station, pp.station, totalLen)) < AVOID.length then
				gridLift = math.max(gridLift, AIRacers.requiredLift(pose.lateral - pp.lateral, pose.height, pp.height, 0))
			end
		end
	end
	bot.slot = slot
	bot.station = pose.station
	bot.gridLateral = pose.lateral
	bot.gridHeight = pose.height
	bot.gridLift = gridLift
	bot.lateral = pose.lateral
	bot.laneLateral = pose.lateral
	bot.height = pose.height + gridLift
	bot.lift = 0
	bot.liftTarget = 0
	bot.liftVel = 0
	bot.side = 0
	bot.sideTarget = 0
	bot.sideVel = 0
	if bot.hull and bot.hull.Parent then
		bot.hull.CFrame = poseCFrame(pose.station, pose.lateral, pose.height + gridLift)
	end
end

-- The zone boss in a boss race or rematch (BossConfig), the storm dragon in a storm race (v2: one per field, in roster
-- slot 1, the rest of the field are normal bots), else nil.
local function activeBoss(): (BossConfig.Boss?, boolean)
	local mode = RaceAttr.here("RaceMode")
	if mode == "stormrace" then
		return BossConfig.stormDragon(activeVehicle()), false
	end
	if mode ~= "boss" and mode ~= "rematch" then
		return nil, false
	end
	return BossConfig.forZone(RaceAttr.here("ActiveZone") :: string?), mode == "rematch"
end

local function createBot(rosterIndex: number, startCF: CFrame): BotRacer?
	local cfg: any = PlaneConfig.AI_BOTS[rosterIndex]
	if not cfg then
		return nil
	end
	local isCar = activeVehicle() == "car"
	local boss, rematch = activeBoss()
	local plane: Model
	local isBoss = boss ~= nil and rosterIndex == 1
	local disguise = PlaneConfig.BOT_DISGUISE and not isBoss
	local rosterName: string = cfg.name
	local displayName: string = cfg.name
	local look: BotDisguise.Look? = nil
	local nameChecked = true
	if disguise then
		displayName, look, nameChecked = BotDisguise.deal(AIRacers.bots)
	end
	if boss and rosterIndex == 1 then
		-- Same roster slot and lanes as the fastest bot, the boss's own pace, name and model.
		cfg = table.clone(cfg)
		cfg.name = boss.name
		cfg.baseSpeed = if rematch then boss.rematchPace else boss.pace
		cfg.laneOffset = 0
		-- the boss shows (and keys on) its own name, never the roster slot's
		rosterName = cfg.name
		displayName = cfg.name
		plane = (require(script.Parent.kit.BossBuilder) :: any).create(boss, startCF)
	else
		-- Disguised: the model is named like a player's vehicle with a token no username can contain (the clients match
		-- their own vehicle by username), never "AI_<roster name>".
		local botName = if disguise then (if isCar then "Car_-" else "Plane_-") .. tostring(rosterIndex) else "AI_" .. (string.gsub(cfg.name, " ", "_"))
		plane = if isCar
			then CarBuilder.createCar(botName, cfg.color, cfg.accent, startCF, true)
			else PlaneBuilder.createPlane(botName, cfg.color, cfg.accent, startCF, true)
	end
	-- M-5: optional per-track bot pace from the track data (workspace BotPace, set by TrackDirector); absent = 1.0.
	local trackPace = if RaceFlowRules.PER_GROUP
		then FidelityRules.botPace(RaceAttr.here(FidelityRules.BOT_PACE_ATTRIBUTE))
		else FidelityRules.botPace(workspace:GetAttribute(FidelityRules.BOT_PACE_ATTRIBUTE))
	BotDisguise.setNames(plane, displayName, rosterName)
	if not isBoss then
		-- signature palette + pennant (the boss keeps its own model); a disguised bot also wears a Garage livery, maybe a trail
		RacerPaint.paintBot(plane, rosterName, if look then look.livery else nil)
	end
	if look then
		BotDisguise.setLook(plane, look)
	end
	plane:SetAttribute("BotId", rosterIndex)
	-- Rides the road (client/RacerView keeps its drawn height on the server's and never extrapolates it upward).
	plane:SetAttribute("GroundRacer", isCar)
	plane.Parent = getPlanesFolder()
	local function part(name: string): BasePart?
		local p = plane:FindFirstChild(name)
		return if p and p:IsA("BasePart") then p else nil
	end
	local bot: BotRacer = {
		id = rosterIndex,
		racerId = racerIdForBot(rosterIndex),
		name = displayName,
		key = rosterName,
		isBoss = isBoss,
		rosterSpeed = (if isCar then cfg.baseSpeed * CAR_BOT.paceFactor else cfg.baseSpeed) * trackPace,
		startDelay = 0,
		slipLeft = 0,
		slipFactor = 1,
		nextSlipAt = math.huge,
		recoverLeft = 0,
		plane = plane,
		hull = plane.PrimaryPart :: BasePart,
		isCar = isCar,
		groundOffset = CarConfig.RIDE_HEIGHT + 2.7,
		stepUpFor = 0,
		baseSpeed = (if isCar then cfg.baseSpeed * CAR_BOT.paceFactor else cfg.baseSpeed) * trackPace,
		currentSpeed = (if isCar then cfg.baseSpeed * CAR_BOT.paceFactor else cfg.baseSpeed) * trackPace,
		laneOffset = if isCar then math.clamp(cfg.laneOffset * CAR_BOT.laneScale, -CAR_BOT.maxLateral, CAR_BOT.maxLateral) else cfg.laneOffset,
		heightOffset = cfg.heightOffset,
		station = 0,
		lap = 1,
		finished = false,
		finishTime = 0,
		finishRank = 0,
		weavePhase = rosterIndex * 2.0,
		boostTimer = 0,
		boostFactor = cfg.boostFactor,
		slot = 0,
		gridLateral = 0,
		gridHeight = 0,
		travelled = 0,
		lateral = 0,
		height = 0,
		weaveScale = 0,
		gridLift = 0,
		lift = 0,
		liftTarget = 0,
		liftVel = 0,
		liftUrgent = false,
		laneLateral = 0,
		side = 0,
		sideTarget = 0,
		sideVel = 0,
		itemBoostTimer = 0,
		itemBoostSpeed = 0,
		magnetTimer = 0,
		magnetPull = 0,
		slowTimer = 0,
		slowFactor = 1,
		stunTimer = 0,
		stunTotal = 0,
		heldColor = nil,
		heldLevel = 0,
		heldSince = 0,
		itemRetryAt = 0,
		itemFailures = 0,
		boostState = "None",
		attrTimer = 0,
		lastLapAttr = 0,
		steer = 0,
	}
	if disguise and not nameChecked then
		-- The pool was dry, so this name is not vouched for: check it in the background and rename in place if it is
		-- somebody's account (standings read bot.name each tick; clients read the BotName attribute).
		BotDisguise.recheck(displayName, function(fresh: string)
			bot.name = fresh
			if bot.plane and bot.plane.Parent then
				bot.plane:SetAttribute("BotName", fresh)
			end
		end)
	end
	return bot
end

local function destroyBot(bot: BotRacer)
	local IS = itemService()
	local svc = if IS then IS.active else nil
	if svc and type(svc.removeRacer) == "function" then
		svc.removeRacer(bot.racerId)
	end
	if bot.plane and bot.plane.Parent then
		bot.plane:Destroy()
	end
end

-- Slots the humans hold on this grid (player attribute GridSlot, set by RaceManager at each reset and by FlightServer
-- for a joiner). With nobody slotted yet (spawnBots before the first reset) the fixed layout's 1..playerCount.
local function humanSlots(playerCount: number, leaving: Player?): { number }
	local slots: { number } = {}
	for _, p in RaceScope.players(Players:GetPlayers()) do
		local s = p:GetAttribute("GridSlot")
		if p ~= leaving and type(s) == "number" then
			table.insert(slots, s)
		end
	end
	if #slots == 0 then
		for k = 1, math.max(playerCount, 1) do
			table.insert(slots, k)
		end
	end
	return slots
end

-- Poses of the human slots, for the grid lift of a bot sharing a row with one (any slot, not just 1..N).
local function playerSlotPoses(slots: { number }, totalLen: number): { Pose }
	local poses = {}
	for _, k in slots do
		table.insert(poses, slotPose(k, totalLen))
	end
	return poses
end

-- Slots the bots hold on the grid (FlightServer.botSlots: a joiner's seat choice). Empty once the field has left the
-- grid, where a joiner's seat is free whatever a bot once held.
function AIRacers.heldSlots(): { [number]: boolean }
	local held: { [number]: boolean } = {}
	if AIRacers.isFieldOpen() then
		for _, bot in AIRacers.bots do
			if bot.slot > 0 then
				held[bot.slot] = true
			end
		end
	end
	return held
end

local function sortById()
	table.sort(AIRacers.bots, function(a: BotRacer, b: BotRacer): boolean
		return a.id < b.id
	end)
end

local function logField(reason: string, players: number, detail: string?)
	print(string.format(
		"[SkyRally][AI] field players=%d bots=%d entrants=%d/%d open=%s reason=%s%s",
		players,
		#AIRacers.bots,
		players + #AIRacers.bots,
		PlaneConfig.AI_FIELD_SIZE,
		tostring(AIRacers.isFieldOpen()),
		reason,
		if detail then " " .. detail else ""
	))
end

-- Free slot for a bot added between resets: the leaver's seat when it is empty, else the lowest slot with no plane on
-- it and no human's GridSlot (humans sit anywhere on the grid-order grid, so this looks at the planes as well as the
-- slot bookkeeping).
local function freeSlot(totalLen: number, prefer: number?, humanHeld: { number }): number
	local planes = workspace:FindFirstChild("Planes")
	local hulls: { Vector3 } = {}
	if planes then
		for _, m in planes:GetChildren() do
			if m:IsA("Model") and m.PrimaryPart then
				table.insert(hulls, m.PrimaryPart.Position)
			end
		end
	end
	local function empty(slot: number): boolean
		if table.find(humanHeld, slot) then
			return false
		end
		local at = slotCFrame(slot, totalLen).Position
		for _, h in hulls do
			if (h - at).Magnitude < AVOID.length then
				return false
			end
		end
		return true
	end
	if prefer and prefer >= 1 and prefer <= PlaneConfig.AI_FIELD_SIZE and empty(prefer) then
		return prefer
	end
	for slot = 1, PlaneConfig.AI_FIELD_SIZE do
		if empty(slot) then
			return slot
		end
	end
	return PlaneConfig.AI_FIELD_SIZE
end

local function connectFieldListeners()
	if listenersConnected then
		return
	end
	listenersConnected = true
	-- Deferred so FlightServer's own PlayerAdded/PlayerRemoving handlers (plane spawn/destroy) have run first.
	-- Per group (phase 2b) a joiner lands in the hub (no field there) and a leaver frees a seat in his own instance's
	-- field: his instance is read now, before the per-group director clears his seat, and the refresh runs in it.
	Players.PlayerAdded:Connect(function(_player: Player)
		task.defer(AIRacers.refreshField, "join", nil)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		if not RaceFlowRules.PER_GROUP then
			task.defer(AIRacers.refreshField, "leave", player)
			return
		end
		local id = RaceScope.instanceOf(player)
		task.defer(function()
			if id == RaceScope.DEFAULT or table.find(RaceScope.liveIds(), id) then
				RaceScope.run(id, AIRacers.refreshField, "leave", player)
			end
		end)
	end)
end

-- Resizes the field after a join or leave. While the field is open (grid, first seconds) seats change at once: a
-- joiner takes the seat of the bot on the slot FlightServer handed him (GridOrder.lateJoinSlot: a rear-half seat; the
-- slowest bot when no bot sits on a human's slot) and a leaver's seat gets the next roster bot. Mid-race a joiner takes
-- the last-placed bot's seat so the field never exceeds AI_FIELD_SIZE; a leaver's seat stays empty until resetBots
-- refills it (a bot appearing mid-lap would race a different race).
function AIRacers.refreshField(reason: string?, leaving: Player?)
	local why = reason or "refresh"
	local players = countPlayers(leaving)
	local need = AIRacers.botsNeeded(players)
	local have = #AIRacers.bots
	if need == have then
		return
	end
	local _, totalLen = SplineUtils.loadWaypoints()
	local open = AIRacers.isFieldOpen()
	local removed: { string } = {}
	local added: { string } = {}
	while #AIRacers.bots > need do
		local victim: BotRacer? = nil
		-- The boss (the storm dragon in a storm race v2 field) is never the trimmed bot while another bot can go: a late
		-- joiner's seat may carry the boss's grid slot number, and the dragon races in every storm field.
		local candidates = AIRacers.trimCandidates(AIRacers.bots)
		if open then
			local onHuman: { [number]: boolean } = {}
			for _, s in humanSlots(players, leaving) do
				onHuman[s] = true
			end
			for _, bot in candidates do
				if onHuman[bot.slot] then
					victim = bot
					break
				end
			end
			if victim == nil then
				for _, bot in candidates do
					if victim == nil or bot.id > (victim :: BotRacer).id then
						victim = bot
					end
				end
			end
		else
			victim = AIRacers.pickTrimVictim(candidates, totalLen)
		end
		if not victim then
			break
		end
		local idx = table.find(AIRacers.bots, victim)
		if idx then
			table.remove(AIRacers.bots, idx)
		end
		destroyBot(victim)
		table.insert(removed, victim.name)
	end
	if #AIRacers.bots < need then
		if open then
			-- Same grid lift as a reset: a refill into the slot beside a player's slot must not start wing through wing.
			local held = humanSlots(players, leaving)
			local playerPoses = playerSlotPoses(held, totalLen)
			local leaverSlot = if leaving then leaving:GetAttribute("GridSlot") else nil
			for id = 1, #PlaneConfig.AI_BOTS do
				if #AIRacers.bots >= need then
					break
				end
				if not findBot(id) then
					local slot = freeSlot(totalLen, if type(leaverSlot) == "number" then leaverSlot else nil, held)
					leaverSlot = nil
					local bot = createBot(id, slotCFrame(slot, totalLen))
					if bot then
						resetRaceState(bot)
						placeOnGrid(bot, slot, totalLen, playerPoses)
						table.insert(AIRacers.bots, bot)
						table.insert(added, bot.name)
					end
				end
			end
			if F().raceClock <= 0 then
				orderStartDelays(totalLen) -- still parked on the grid; once moving, nobody's delay is dealt again
			end
			sortById()
		else
			F().pendingRefill = true
		end
	end
	logField(why, players, string.format(
		"need=%d removed=[%s] added=[%s]%s",
		need,
		table.concat(removed, ","),
		table.concat(added, ","),
		if F().pendingRefill then " refill=next_reset" else ""
	))
	assignRival(players, true) -- item 19: a second player joining ends the solo rivalry (and its tighter band)
end

-- The grid RaceManager decided for this reset (shared/GridOrder.Plan, the fields resetBots reads).
export type GridPlan = {
	exempt: boolean,
	humanSlots: { [number]: number },
	botSlots: { number },
}

-- Full field rebuild on the grid (every race reset): the first botsNeeded roster entries, reusing their planes. plan
-- (RaceManager, shared/GridOrder) gives every bot's slot and the humans' slots; without it the fixed layout (botSlots).
function AIRacers.resetBots(plan: GridPlan?)
	connectFieldListeners()
	ensureItemHandlers(os.clock())
	local _, totalLen = SplineUtils.loadWaypoints()
	local players = countPlayers(nil)
	local need = AIRacers.botsNeeded(players)
	local keep: { [number]: BotRacer } = {}
	for _, bot in AIRacers.bots do
		if bot.id <= need and bot.hull and bot.hull.Parent and keep[bot.id] == nil then
			keep[bot.id] = bot
		else
			destroyBot(bot)
		end
	end
	table.clear(AIRacers.bots)
	F().raceClock = 0
	F().pendingRefill = false
	local slots = AIRacers.botSlots(players, need)
	local occupied: { number } = {}
	for k = 1, math.max(players, 1) do
		table.insert(occupied, k)
	end
	if plan then
		occupied = {}
		for _, s in plan.humanSlots do
			table.insert(occupied, s)
		end
		local lanes: { number } = {}
		for i, cfg in PlaneConfig.AI_BOTS do
			lanes[i] = (cfg :: any).laneOffset or 0
		end
		-- Row-mates fan outward from the grid (exempt grids keep their fixed layout, already fanned).
		local planned = if plan.exempt then plan.botSlots else GridOrder.fanRowMates(plan.botSlots, lanes)
		local taken: { [number]: boolean } = {}
		for _, s in occupied do
			taken[s] = true
		end
		for i = 1, need do
			local s = planned[i]
			if s == nil or taken[s] then
				-- More bots than the plan seated (a join between the plan and this rebuild): the lowest open slot.
				s = 1
				while taken[s] do
					s += 1
				end
			end
			slots[i] = s
			taken[s] = true
		end
	end
	local playerPoses = playerSlotPoses(occupied, totalLen)
	for i = 1, need do
		local bot = keep[i] or createBot(i, slotCFrame(slots[i], totalLen))
		if bot then
			resetRaceState(bot)
			placeOnGrid(bot, slots[i], totalLen, playerPoses)
			table.insert(AIRacers.bots, bot)
		end
	end
	orderStartDelays(totalLen)
	local slotList: { string } = {}
	for i = 1, need do
		table.insert(slotList, tostring(slots[i]))
	end
	logField("reset", players, if need > 0 then "slots=" .. table.concat(slotList, ",") .. (if plan then " grid=plan" else " grid=fixed") else "slots=none")
	-- Item 19: a fresh race, a fresh rival and a quiet voice.
	F().rivalSeq += 1
	F().tauntVoice = nil
	F().tauntStartSaid = false
	table.clear(F().tauntSides)
	table.clear(F().tauntFinished)
	assignRival(players, false)
end

-- Destroys every bot (track switch: the next track may use the other vehicle).
function AIRacers.despawnAll()
	for _, bot in AIRacers.bots do
		destroyBot(bot)
	end
	table.clear(AIRacers.bots)
	F().marksKey = ""
end

-- Studio QA only (server/QATools, behind RunService:IsStudio()): puts a bot `studs` ahead of `fromPos` on the line (lateral
-- off the line), merged and moving at once, so a missile, trap or shield has a target without waiting for the field. Takes
-- the named bot, else the bot nearest the player behind it. Returns (ok, botName or reason). Changes the bot's own station
-- only: no collision, no course, adhesion, wall or rescue logic.
function AIRacers.qaPlaceAhead(fromPos: Vector3, studs: number, lateral: number, botId: number?): (boolean, string)
	local okStudio, studio = pcall(function(): boolean
		return game:GetService("RunService"):IsStudio()
	end)
	if not okStudio or not studio then
		return false, "not_studio"
	end
	local _, totalLen = SplineUtils.loadWaypoints()
	if #AIRacers.bots == 0 or totalLen <= 0 then
		return false, "no_bots"
	end
	local bot: BotRacer? = nil
	for _, b in AIRacers.bots do
		if (botId == nil or b.id == botId) and not b.finished and not b.isBoss then
			bot = b
			break
		end
	end
	if not bot then
		return false, "no_bot"
	end
	local st = SplineUtils.projectPosition(fromPos)
	local target = (st + studs) % totalLen
	bot.station = target
	bot.lateral = lateral
	bot.laneLateral = lateral
	bot.side = 0
	bot.sideTarget = 0
	bot.stunTimer = 0
	bot.startDelay = 0
	bot.travelled = math.max(bot.travelled, GRID.mergeDistance)
	bot.weaveScale = 1
	bot.gridLift = 0
	bot.lift = 0
	bot.liftTarget = 0
	bot.liftVel = 0
	if bot.hull and bot.hull.Parent then
		bot.hull.CFrame = poseCFrame(target, lateral, bot.height)
	end
	return true, bot.name
end

-- Destroys every bot plane and builds the field fresh (server start).
function AIRacers.spawnBots()
	for _, bot in AIRacers.bots do
		destroyBot(bot)
	end
	table.clear(AIRacers.bots)
	AIRacers.resetBots()
end

------------------------------------------------------------------------------------------------------------------------
-- Per-step: motion, triggers, items, separation, render
------------------------------------------------------------------------------------------------------------------------

local racerIds: { string } = {}
local racerStations: { number } = {}

local function smoothstep(t: number): number
	local x = math.clamp(t, 0, 1)
	return x * x * (3 - 2 * x)
end

local function tryPickup(bot: BotRacer, pod: PodMark, now: number)
	local maxLevel = ItemRules.maxLevel(levelOneOnly())
	if not AIRacers.wantsPod(bot.heldColor, bot.heldLevel, if pod.mystery then nil else pod.color, maxLevel) then
		return
	end
	-- The visual state doubles as the client trigger gate; skipping it here keeps bots off the ledger's reject log.
	if pod.part:GetAttribute("OnCooldown") == true then
		return
	end
	if not AIRacers.podInReach(bot.lateral + bot.side - pod.lateral, bot.height + bot.lift - pod.height) then
		return
	end
	local IS = itemService()
	local ok, outcome = IS.pickup(bot.racerId, pod.name)
	if ok then
		if pod.mystery and outcome == "new" then
			-- A fresh roll spins for rouletteSeconds and the server refuses a use until then: the hold clock starts
			-- at the reveal, like a player's.
			bot.heldSince = now + ItemRules.MYSTERY.rouletteSeconds
		elseif outcome == "new" or outcome == "replace" or (not pod.mystery and bot.heldColor ~= pod.color) then
			bot.heldSince = now
		end
		bot.heldColor, bot.heldLevel = heldState(bot.racerId)
	end
end

local function stepMotion(
	bot: BotRacer,
	dt: number,
	leadPlayerDist: number,
	raceElapsed: number,
	totalLen: number,
	onBotFinished: ((BotRacer) -> ())?,
	items: boolean,
	now: number
)
	-- Leaves the grid a moment after GO (BotPaceRules.startDelay), a ramp from rest rather than an instant full-speed jump.
	if raceElapsed < bot.startDelay and not bot.finished then
		bot.currentSpeed = 0
		return
	end
	local botTotalDist = (bot.lap - 1) * totalLen + bot.station
	local distBehindPlayer = leadPlayerDist - botTotalDist

	-- Light rubber-banding around bot.baseSpeed (the rival's band is tighter, same ceilings: item 19)
	local rubberFactor = AIRacers.rubberFactor(distBehindPlayer, F().rivalId ~= nil and bot.id == F().rivalId)

	bot.boostTimer = math.max(0, bot.boostTimer - dt)
	bot.itemBoostTimer = math.max(0, bot.itemBoostTimer - dt)
	bot.magnetTimer = math.max(0, bot.magnetTimer - dt)
	bot.slowTimer = math.max(0, (bot.slowTimer or 0) - dt)
	if bot.stunTimer > 0 then
		bot.stunTimer = math.max(0, bot.stunTimer - dt)
		if bot.stunTimer == 0 then
			bot.plane:SetAttribute("Stunned", false)
			if not bot.isBoss and PlaneConfig.BOT_DISGUISE then
				bot.recoverLeft = BotPaceRules.HIT_RECOVER_SECONDS -- a short easing after a spin-out, like a driver regathering
			end
		end
	end
	-- Small mistakes: now and then a slip (a clipped corner), spaced by BotPaceRules; never in the boss
	if not bot.isBoss and not bot.finished then
		bot.recoverLeft = math.max(0, bot.recoverLeft - dt)
		if bot.slipLeft > 0 then
			bot.slipLeft = math.max(0, bot.slipLeft - dt)
		elseif raceElapsed >= bot.nextSlipAt and bot.stunTimer <= 0 then
			bot.slipLeft, bot.slipFactor = BotPaceRules.slip(math.random)
			bot.nextSlipAt = BotPaceRules.nextSlipAt(math.random, raceElapsed + bot.slipLeft)
		end
	end

	local cruise = bot.baseSpeed * rubberFactor * BotPaceRules.factor(bot.slipLeft, bot.slipFactor, bot.recoverLeft)
	local targetSpeed = cruise
	if bot.finished then
		targetSpeed = bot.baseSpeed * 0.75
	elseif bot.stunTimer > 0 then
		targetSpeed = bot.baseSpeed * HIT.speedFactor
	else
		if bot.boostTimer > 0 then
			targetSpeed = math.max(targetSpeed, PlaneConfig.BOOST_SPEED * bot.boostFactor * rubberFactor)
		end
		if bot.itemBoostTimer > 0 then
			targetSpeed = math.max(targetSpeed, bot.itemBoostSpeed * bot.boostFactor * rubberFactor)
		end
		if bot.magnetTimer > 0 then
			targetSpeed += bot.magnetPull
		end
		if bot.slowTimer > 0 then
			targetSpeed *= bot.slowFactor -- items v4: frost, coins, patches
		end
	end
	-- same approach rates as the player's plane (faster up than down); a spin-out brakes harder
	local rate = if targetSpeed > bot.currentSpeed then 9 elseif bot.stunTimer > 0 then HIT.brakeRate else 4.5
	bot.currentSpeed = bot.currentSpeed + (targetSpeed - bot.currentSpeed) * math.clamp(dt * rate, 0, 1)

	local prevStation = bot.station
	local advance = bot.currentSpeed * dt
	bot.station = bot.station + advance
	bot.travelled += advance
	if not bot.finished then
		local p, n = prevStation % totalLen, bot.station % totalLen
		for _, bs in F().boostStations do
			if AIRacers.crossed(p, n, bs, totalLen) then
				local padModel = F().boostPadAt[bs]
				-- A timed hub-boss pad that is off gives nothing (nil = live, every other map unchanged); neither does a
				-- sail-gap ring with a sail across it (the same server clock the sails and the players use).
				if
					FidelityRules.padIsLive(if padModel then padModel:GetAttribute("PadLive") else nil)
					and (F().boostGateAt[bs] == nil or SailGateRules.live(workspace:GetServerTimeNow(), F().boostGateAt[bs]))
				then
					bot.boostTimer = PlaneConfig.BOOST_DURATION
					break
				end
			end
		end
		if items then
			for _, pod in F().podMarks do
				if AIRacers.crossed(p, n, pod.station, totalLen) then
					tryPickup(bot, pod, now)
				end
			end
		end
	end

	while bot.station >= totalLen do
		local prevSt = bot.station - bot.currentSpeed * dt
		bot.station = bot.station - totalLen
		-- Do not increment lap when a bot that spawned slightly behind the start line (e.g., totalLen - 22) crosses the start line for the first time at the start of Lap 1
		if not (bot.lap == 1 and raceElapsed < 12.0 and prevSt > totalLen - BEHIND_LINE_WINDOW) then
			if not bot.finished then
				if bot.lap < PlaneConfig.TOTAL_LAPS then
					bot.lap = bot.lap + 1
				else
					bot.finished = true
					bot.finishTime = raceElapsed
					if onBotFinished then
						onBotFinished(bot)
					end
				end
			end
		end
	end

	-- Grid -> lane merge, weave faded in with it so the start stays in formation.
	local m = smoothstep(bot.travelled / GRID.mergeDistance)
	bot.weaveScale = m
	bot.weavePhase = bot.weavePhase + dt * WEAVE.rate
	local weaveX = math.sin(bot.weavePhase) * WEAVE.lateral * m
	local weaveY = math.cos(bot.weavePhase * 0.8) * WEAVE.vertical * m
	bot.laneLateral = bot.gridLateral + (bot.laneOffset - bot.gridLateral) * m
	bot.lateral = bot.laneLateral + weaveX
	bot.height = bot.gridHeight + (bot.heightOffset - bot.gridHeight) * m + weaveY + bot.gridLift * (1 - m)
	if bot.isCar then
		bot.height = 4.5 -- on the road: pod reach is lateral only (car-map pods sit 4.5 over the line)
	end
end

local carRayParams: RaycastParams? = nil
local carFilterAt = -math.huge

-- What a bot car's down ray must never stand on: vehicles, every player's avatar, item and world fx, boss hazards.
local function carRayExcludes(): { Instance }
	local list: { Instance } = {}
	for _, name in { "Planes", "SkyRallyItemFX", "SkyRallyVfx", "BossHazards" } do
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
	return list
end

-- Ride offset (hull height above the course line) a bot car takes from this frame's ground hit. Pure:
-- tools/tests/field_spec.luau. `hitY` nil (no ground, or a hit the caller rejected) keeps `current`; a hit further
-- than maxDropBelowLine under the line is a jump gap (keep); a rise steeper than a 45 degree ramp at `speed` plus
-- stepUpSlack is refused until it has persisted stepUpHold seconds. Returns (target offset, new stepUpFor).
function AIRacers.carRideTarget(
	current: number,
	lineY: number,
	hitY: number?,
	speed: number,
	dt: number,
	stepUpFor: number
): (number, number)
	if hitY == nil or hitY <= lineY - CAR_BOT.maxDropBelowLine then
		return current, 0
	end
	local target = hitY + CarConfig.RIDE_HEIGHT - lineY
	local maxRise = math.abs(speed) * dt + CAR_BOT.stepUpSlack
	if target - current > maxRise then
		local held = stepUpFor + dt
		if held < CAR_BOT.stepUpHold then
			return current, held
		end
	end
	return target, 0
end

local function renderCar(bot: BotRacer, dt: number)
	if not carRayParams then
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.RespectCanCollide = false -- pavers are non-colliding visuals on top of the deck
		rp.IgnoreWater = false
		carRayParams = rp
	end
	local params = carRayParams :: RaycastParams
	local clock = os.clock()
	if clock - carFilterAt >= CAR_BOT.filterRefresh then
		carFilterAt = clock
		params.FilterDescendantsInstances = carRayExcludes()
	end
	-- The box-filtered path, not the raw waypoint chords (RacerViewRules.pathFrame; plane_stutter.md "Car bots"): the
	-- chord tangent turns in one step at every waypoint, and with the hull placed at pos + right * lateral each step
	-- (no position ease) a side-lane bot hopped sideways by lateral x corner angle there. Bot rendering only.
	local pos, tan, _ = RacerViewRules.pathFrame(SplineUtils.sampleAtStation, bot.station)
	local aheadPos, aheadTan, _ = RacerViewRules.pathFrame(SplineUtils.sampleAtStation, bot.station + 12)
	local right = rightOf(tan)
	local side = if bot.laneOffset >= 0 then 1 else -1
	local lateral = math.clamp(bot.lateral + bot.side + side * bot.lift * CAR_BOT.liftToSide, -CAR_BOT.maxLateral - 2, CAR_BOT.maxLateral + 2)
	local base = pos + right * lateral
	local aheadBase = aheadPos + rightOf(aheadTan) * lateral
	local hit = workspace:Raycast(base + UP * CAR_BOT.rayUp, -UP * (CAR_BOT.rayUp + CAR_BOT.rayDown), params)
	local normal = UP
	local hitY: number? = nil
	if hit and hit.Normal.Y >= CAR_BOT.minNormalY then
		hitY = hit.Position.Y
	end
	local target, held = AIRacers.carRideTarget(bot.groundOffset, pos.Y, hitY, bot.currentSpeed, dt, bot.stepUpFor)
	bot.stepUpFor = held
	if hit and hitY and held == 0 and hitY > pos.Y - CAR_BOT.maxDropBelowLine then
		normal = hit.Normal
	end
	bot.groundOffset += (target - bot.groundOffset) * math.clamp(dt * CAR_BOT.rideResponse, 0, 1)
	local p = Vector3.new(base.X, pos.Y + bot.groundOffset, base.Z)
	local fwd = aheadBase - base
	fwd = fwd - normal * fwd:Dot(normal)
	if fwd.Magnitude < 0.05 then
		fwd = tan
	end
	local spin = 0
	if bot.stunTimer > 0 and bot.stunTotal > 0 then
		local k = 1 - bot.stunTimer / bot.stunTotal
		spin = HIT.spinTurns * 2 * math.pi * (1 - (1 - k) * (1 - k))
	end
	local goalCF = CFrame.lookAt(p, p + fwd.Unit, normal) * CFrame.Angles(0, spin, 0)
	-- At its station and ride height every frame; only heading and tilt are eased (road seams, the spin-out roll).
	local turned = bot.hull.CFrame.Rotation:Lerp(goalCF.Rotation, math.clamp(dt * CAR_BOT.turnResponse, 0, 1))
	bot.hull.CFrame = CFrame.new(p) * turned
	-- Front-wheel steer for the clients' wheel rigs: the heading change to the point 12 studs ahead (sin of the angle,
	-- positive = left), scaled so a hairpin is full lock. Replicated at the attribute rate in render().
	local turn = tan:Cross(aheadTan).Y
	bot.steer = math.clamp(-turn * 4, -1, 1)
end

local function renderPlane(bot: BotRacer, dt: number)
	-- The box-filtered path, not the raw waypoint chords (RacerViewRules.pathFrame, plane_stutter.md C5).
	local pos, tan, bank = RacerViewRules.pathFrame(SplineUtils.sampleAtStation, bot.station)
	local aheadPos, aheadTan, _ = RacerViewRules.pathFrame(SplineUtils.sampleAtStation, bot.station + 28)
	local right = rightOf(tan)
	local up = Vector3.new(0, bot.height + bot.lift, 0)

	local worldPos = pos + right * (bot.lateral + bot.side) + up
	local lookTarget = aheadPos + right * (bot.lateral + bot.side) + up
	local diff = lookTarget - worldPos
	local lookDir = if diff.Magnitude > 0.05 then diff.Unit else aheadTan

	-- Compute dynamic roll from curvature + track bank; a spin-out adds an easing barrel roll over the stun.
	local turnCross = tan:Cross(aheadTan).Y
	local dynamicBank = math.clamp(bank - turnCross * 180, -52, 52)
	local spin = 0
	if bot.stunTimer > 0 and bot.stunTotal > 0 then
		local p = 1 - bot.stunTimer / bot.stunTotal
		spin = HIT.spinTurns * 2 * math.pi * (1 - (1 - p) * (1 - p))
	end
	local goalCF = CFrame.lookAt(worldPos, worldPos + lookDir) * CFrame.Angles(0, 0, math.rad(dynamicBank) + spin)

	bot.hull.CFrame = bot.hull.CFrame:Lerp(goalCF, math.clamp(dt * 12, 0, 1))

	-- The propeller is a welded rotor on a Motor6D that every client turns from the replicated Speed
	-- (client/VehicleMotion): no per-frame propeller writes here (audit H1/H3).
end

local function render(bot: BotRacer, dt: number)
	if bot.isCar then
		renderCar(bot, dt)
	else
		renderPlane(bot, dt)
	end
	-- Attributes replicate to every client: Lap/BoostState only on change (Vfx bursts on a BoostState change), Station
	-- and Speed at 10 Hz instead of every frame.
	if bot.lap ~= bot.lastLapAttr then
		bot.lastLapAttr = bot.lap
		bot.plane:SetAttribute("Lap", bot.lap)
	end
	local boosting = bot.stunTimer <= 0 and (bot.boostTimer > 0 or bot.itemBoostTimer > 0)
	local state = if boosting then "Standard" else "None"
	if state ~= bot.boostState then
		bot.boostState = state
		bot.plane:SetAttribute("BoostState", state)
	end
	bot.attrTimer -= dt
	if bot.attrTimer <= 0 then
		bot.attrTimer = 0.1
		bot.plane:SetAttribute("Station", math.floor(bot.station))
		bot.plane:SetAttribute("Speed", math.floor(bot.currentSpeed))
		if bot.isCar then
			local steer = math.floor(bot.steer * 10 + 0.5) / 10
			if bot.plane:GetAttribute("Steer") ~= steer then
				bot.plane:SetAttribute("Steer", steer)
			end
		end
	end
end

-- FlightServer holds the player records (station is projected by RaceManager each step). Lazy like ItemService.
local flightServerModule: any = nil
local flightServerTried = false
local function flightRecords(): any
	if not flightServerTried then
		flightServerTried = true
		local inst = script.Parent:FindFirstChild("FlightServer")
		if inst and inst:IsA("ModuleScript") then
			local ok, mod = pcall(require, inst)
			flightServerModule = if ok then mod else nil
		end
	end
	-- Per group: this field's players only (RaceScope.filter); the whole record map on the single-race path.
	return if flightServerModule then RaceScope.filter(flightServerModule.records) else nil
end

-- Active racers (players with a plane, bots), not finished, for item targeting. Rebuilt once per item tick.
local function collectRacers()
	table.clear(racerIds)
	table.clear(racerStations)
	local records = flightRecords()
	if type(records) == "table" then
		for player, rec in records do
			if typeof(player) == "Instance" and rec.hull and rec.hull.Parent and not rec.finished then
				table.insert(racerIds, racerIdForPlayer((player :: Player).UserId))
				table.insert(racerStations, rec.station)
			end
		end
	end
	for _, bot in AIRacers.bots do
		if bot.hull and bot.hull.Parent and not bot.finished then
			table.insert(racerIds, bot.racerId)
			table.insert(racerStations, bot.station)
		end
	end
end

local function thinkItems(bot: BotRacer, now: number, totalLen: number)
	local color, level = heldState(bot.racerId)
	if color == nil or level <= 0 then
		bot.heldColor, bot.heldLevel = nil, 0
		return
	end
	if color ~= bot.heldColor then
		bot.heldSince = now
		bot.itemRetryAt, bot.itemFailures = 0, 0
	end
	bot.heldColor, bot.heldLevel = color, level
	local kind = ItemRules.KIND_OF[color :: ItemRules.Color]
	if not kind then
		return
	end
	if os.clock() < bot.itemRetryAt then
		return
	end
	local selfIndex = table.find(racerIds, bot.racerId)
	local ahead, behind = AIRacers.nearestGaps(bot.station, racerStations, totalLen, selfIndex)
	local ctx: ItemContext = {
		aheadGap = ahead,
		behindGap = behind,
		threatBehind = false,
		onStraight = false,
		boosting = bot.boostTimer > 0 or bot.itemBoostTimer > 0,
		heldFor = now - bot.heldSince,
		magnetRange = nil,
	}
	if kind == "shield" or kind == "bubble_guard" then
		-- ItemEffects aims a homing missile at the racer directly ahead, so an armed rival close behind is the threat
		-- (items v4: any shooter: Orbit Missiles, Frost Shot, Coin Burst too).
		for i, st in racerStations do
			if i ~= selfIndex then
				local g = AIRacers.signedGap(bot.station, st, totalLen)
				local theirs = heldState(racerIds[i])
				if g < 0 and -g <= ITEMS.shieldThreatBehind and (theirs == "red" or theirs == "orbit_missiles" or theirs == "frost_shot" or theirs == "coin_burst") then
					ctx.threatBehind = true
					break
				end
			end
		end
	elseif kind == "storm_bolt" then
		ctx.leading = ahead == nil
	elseif kind == "boost" or kind == "golden_wings" or kind == "gift_box" then
		local _, t0 = SplineUtils.sampleAtStation(bot.station)
		local _, t1 = SplineUtils.sampleAtStation(bot.station + ITEMS.straightLookahead * 0.5)
		local _, t2 = SplineUtils.sampleAtStation(bot.station + ITEMS.straightLookahead)
		ctx.onStraight = AIRacers.isStraight(t0, t1, t2)
	elseif kind == "magnet" then
		local params = ItemRules.PARAMS.magnet[math.clamp(level, 1, #ItemRules.PARAMS.magnet)]
		ctx.magnetRange = params.range
	end
	local use, why = AIRacers.decideItemUse(kind, level, ctx)
	if not use then
		return
	end
	local IS = itemService()
	local ok, reason = IS.use(bot.racerId)
	if ok then
		bot.itemFailures = 0
	else
		bot.itemFailures += 1
		bot.itemRetryAt = os.clock() + ItemRules.botRetryDelay(reason, bot.itemFailures)
		if not ItemRules.botShouldLogRefusal(bot.itemFailures) then
			return
		end
	end
	print(string.format(
		"[SkyRally][AI] item bot=%s use=%s level=%d why=%s ahead=%s behind=%s ok=%s%s",
		bot.name,
		kind,
		level,
		why,
		if ahead then string.format("%.0f", ahead) else "-",
		if behind then string.format("%.0f", behind) else "-",
		tostring(ok),
		if ok then "" else " reason=" .. tostring(reason)
	))
	bot.heldColor, bot.heldLevel = heldState(bot.racerId)
end

------------------------------------------------------------------------------------------------------------------------
-- Item 19: taunts. Events -> BotPersonality.decide -> "BotTaunt" to every client (RivalBubbles draws the bubble).
------------------------------------------------------------------------------------------------------------------------

-- Studs either side of a player inside which a change of order counts as a pass worth a line.
local TAUNT_PASS_RANGE = 70
-- No pass lines while the field fans out from the grid.
local TAUNT_QUIET_START = 4

local function tauntsLive(): boolean
	if not personality() then
		return false
	end
	local mode = RaceAttr.here("RaceMode")
	return mode ~= "boss" and mode ~= "rematch" and mode ~= "battle" and mode ~= "hub" and mode ~= "timetrial"
end

local function displayNameOf(racerId: string): string?
	local kind, num = string.match(racerId, "^(%a+):(%-?%d+)$")
	if kind ~= "player" then
		return nil
	end
	local player = Players:GetPlayerByUserId(tonumber(num) or 0)
	return if player then player.DisplayName else nil
end

local function botForRacer(racerId: string): BotRacer?
	local id = parseBotRacerId(racerId)
	return if id then findBot(id) else nil
end

-- One taunt: decide, format, send, log. targetName: the player's display name for "{name}".
function AIRacers.taunt(bot: BotRacer, bucket: string, targetName: string?): boolean
	local BP = personality()
	if not BP or not bot.plane or not bot.plane.Parent then
		return false
	end
	F().tauntVoice = F().tauntVoice or BP.newVoice()
	local rival = F().rivalId ~= nil and bot.id == F().rivalId
	local line = BP.decide(F().tauntVoice, bot.id, BP.forName(bot.key), bucket, os.clock(), rival, math.random)
	if not line then
		return false
	end
	local text = BP.format(line, targetName)
	local IS = itemService()
	local ok = pcall(function()
		local remote = IS.ensureRemote()
		remote:FireAllClients("BotTaunt", { plane = bot.plane, text = text, rival = rival, bucket = bucket })
	end)
	print(string.format("[SkyRally][AI] taunt bot=%s bucket=%s rival=%s sent=%s text=%q", bot.name, bucket, tostring(rival), tostring(ok), text))
	return ok
end

-- Hits on and by bots (ItemService.noteHit -> setHitListener). Bot-on-bot hits stay quiet.
function AIRacers.onHitTaunt(victim: string, attacker: string, kind: string, _chain: number)
	if not tauntsLive() then
		return
	end
	local vBot, aBot = botForRacer(victim), botForRacer(attacker)
	if vBot and not aBot then
		local name = displayNameOf(attacker)
		if name then
			AIRacers.taunt(vBot, "hitBy", name)
		end
	elseif aBot and not vBot then
		local name = displayNameOf(victim)
		if name then
			AIRacers.taunt(aBot, if kind == "revenge" then "revenge" else "hitPlayer", name)
		end
	end
end

-- Passes and finishes, at the item cadence. Cost: bots x players comparisons, 4 times a second.
local function watchTaunts(raceElapsed: number, totalLen: number)
	if not tauntsLive() or #AIRacers.bots == 0 then
		return
	end
	local records = flightRecords()
	if type(records) ~= "table" then
		return
	end
	local soloName: string? = nil
	local anyFinished = false
	for player, rec in records do
		if typeof(player) == "Instance" then
			soloName = soloName or (player :: Player).DisplayName
			if rec.finished then
				anyFinished = true
			end
		end
	end
	if not F().tauntStartSaid and raceElapsed > 0.6 then
		F().tauntStartSaid = true
		if raceElapsed < TAUNT_QUIET_START then
			local speaker = findBot(F().rivalId or -1) or AIRacers.bots[math.random(1, #AIRacers.bots)]
			AIRacers.taunt(speaker, "start", soloName)
		end
	end
	for _, bot in AIRacers.bots do
		if bot.finished then
			if not F().tauntFinished[bot.id] then
				F().tauntFinished[bot.id] = true
				AIRacers.taunt(bot, if anyFinished then "finishBehind" else "finishAhead", soloName)
			end
		elseif bot.hull and bot.hull.Parent then
			local sides = F().tauntSides[bot.id]
			if not sides then
				sides = {}
				F().tauntSides[bot.id] = sides
			end
			local botProg = AIRacers.progressOf(bot.lap, bot.station, totalLen)
			for player, rec in records do
				if typeof(player) == "Instance" and rec.hull and rec.hull.Parent and not rec.finished then
					local gap = botProg - AIRacers.progressOf(rec.lap, rec.station, totalLen)
					local side = if gap >= 0 then 1 else -1
					local prev = (sides :: any)[player]
					if prev and prev ~= side and math.abs(gap) <= TAUNT_PASS_RANGE and raceElapsed > TAUNT_QUIET_START and bot.stunTimer <= 0 then
						AIRacers.taunt(bot, if side > 0 then "pass" else "passed", (player :: Player).DisplayName)
					end
					(sides :: any)[player] = side
				end
			end
		end
	end
end

local function stepOnce(dt: number, leadPlayerDist: number, raceElapsed: number, onBotFinished: ((BotRacer) -> ())?)
	F().raceClock = raceElapsed
	local wps, totalLen = SplineUtils.loadWaypoints()
	if #wps < 2 or totalLen <= 0 then
		return
	end
	refreshTrackMarks(totalLen)
	local now = os.clock()
	ensureItemHandlers(now)
	local items = itemsLive()

	for _, bot in AIRacers.bots do
		if bot.hull and bot.hull.Parent then
			stepMotion(bot, dt, leadPlayerDist, raceElapsed, totalLen, onBotFinished, items, now)
		end
	end

	AIRacers.solveLifts(AIRacers.bots, totalLen)
	for _, bot in AIRacers.bots do
		if bot.hull and bot.hull.Parent then
			AIRacers.approachLift(bot, dt)
			render(bot, dt)
		end
	end

	if items then
		F().itemTimer -= dt
		if F().itemTimer <= 0 then
			F().itemTimer = ITEMS.thinkInterval
			collectRacers()
			for _, bot in AIRacers.bots do
				if bot.hull and bot.hull.Parent and not bot.finished and bot.stunTimer <= 0 then
					thinkItems(bot, now, totalLen)
				end
			end
		end
	end
	-- Item 19: taunts at the same 4 Hz cadence (own clock: they run with items off too).
	F().tauntTimer -= dt
	if F().tauntTimer <= 0 then
		F().tauntTimer = ITEMS.thinkInterval
		local ok, err = pcall(function()
			watchTaunts(raceElapsed, totalLen)
		end)
		if not ok then
			print("[SkyRally][AI] taunt watcher error " .. tostring(err))
		end
	end
end

-- Fixed step (docs/audits/opponent_jitter.md): the field advances in whole RacerViewRules.SERVER_STEP steps, so every
-- hull pose the clients receive sits on a uniform sim-time grid and their view can time it exactly (Shared.RacerViewRules
-- "Server fixed step"). A Heartbeat shorter than a step runs none (the hull is untouched and nothing replicates), a long
-- one runs two or more; each step sees the race clock at its own sim time. Same work per second as one step per Heartbeat.

local function collectHulls(): { BasePart }
	local parts = {}
	for _, bot in AIRacers.bots do
		local hull = bot.hull
		if hull and hull.Parent then
			table.insert(parts, hull)
		end
	end
	return parts
end

function AIRacers.step(dt: number, leadPlayerDist: number, raceElapsed: number, onBotFinished: ((BotRacer) -> ())?)
	local stepClock = F().stepClock -- this field's fixed-step clock (one per RaceInstance per group)
	local n, stepDt = RacerViewRules.serverSteps(stepClock, dt)
	for i = 1, n do
		stepOnce(stepDt, leadPlayerDist, raceElapsed - stepClock.acc - (n - i) * stepDt, onBotFinished)
	end
	if n > 0 then
		-- The clients draw these poses from the stamped stream (Shared.RacerStreamRules, server/RacerStream).
		RacerViewRules.publish(1, stepClock, collectHulls)
	end
end

return AIRacers
