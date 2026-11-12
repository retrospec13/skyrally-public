--!strict
-- Starting grid order (docs/design/GRID_ORDER.md, the launch rule). Pure: no Instances, no Roblox globals, its own
-- seeded generator, so tools/tests/grid_order_spec.luau runs it under Lune and the server and its logs agree per seed
-- (RaceManager seeds with workspace.RaceResetSeq).
--
-- Two numberings. A grid POSITION is what the player reads: 1 = pole (the front of the grid), field = the back. A SLOT
-- is what FlightServer.getStartCFrame / TrackRegistry.startCFrame / AIRacers place by: every track's grid is built by
-- tools/map/adapt.py grid_slot (pole slot 1 at gameplay.startGrid.station, then pairs one rowSpacing further DOWN the
-- route per row, the finish at station 0 and the route flown in rising stations), so slot 1 is the row nearest the
-- line, i.e. the BACK, and the highest slot is the front. slot = field + 1 - position.
--
-- Rules (decision table, section 3):
--   * solo, no result on this server yet: a middle-weighted random position (SOLO_WEIGHTS, 5..20 %);
--   * solo, race 2+: catch-up, the last finishing place mirrored (won -> the back, last -> the front), +-1, clamped to
--     CLAMP_SOLO so a bad race never guarantees pole and a win never guarantees last;
--   * 2+ humans, race 1 (or the last race had more than REVERSE_MAX_DNF DNFs): a fair shuffle of every position;
--   * 2+ humans, race 2+: the humans' relative order is the reverse of their last finish (winner furthest back among
--     the humans), on a randomly drawn set of positions so bots interleave, no human moving more than MAX_MOVE
--     positions from where they started last race;
--   * bots fill the other positions fastest first (front first), with a seeded adjacent swap now and then;
--   * boss / rematch / time trial / battle / hub keep the fixed grid (humans slots 1..N, bots after them).
local GridOrder = {}

-- Percent chance of positions 1..8 for a solo first race (position 1 = pole). Other field sizes use the same
-- triangle, weight min(p, field + 1 - p).
GridOrder.SOLO_WEIGHTS = { 5, 10, 15, 20, 20, 15, 10, 5 }
GridOrder.MAX_MOVE = 4
GridOrder.CLAMP_SOLO = { 2, 7 } -- for a field of 8; {2, field - 1} in general
GridOrder.CATCHUP_JITTER = 1
-- More DNFs than this in the last race and the humans' reverse is skipped (a fresh shuffle instead).
GridOrder.REVERSE_MAX_DNF = 2
-- Chance that two speed-neighbour bots swap places on the grid (each bot moves at most one place).
GridOrder.BOT_SWAP_CHANCE = 0.25
-- Seconds a last-race result stays usable (server memory only; a leaver's entry is dropped at once).
GridOrder.HISTORY_TTL = 600
-- Seconds the countdown overlay shows the grid line (it ends half a second before GO).
GridOrder.HUD_SECONDS = 2.5

-- Modes that keep the fixed grid: the boss is the challenge, a time trial has no field, battles use arena seats and
-- the hub its plaza rows.
GridOrder.EXEMPT = { boss = true, rematch = true, timetrial = true, battle = true, hub = true } :: { [string]: boolean }

export type Reason = "random" | "catchup" | "reverse" | "late" | "fixed"

export type Human = {
	userId: number,
	lastPlace: number?, -- finishing place in this server's previous race (DNF = last), nil = no result
	lastGrid: number?, -- grid position (1 = pole) this human started that race from
}

export type Plan = {
	field: number, -- entrant seats on this grid (positions and slots run 1..field)
	exempt: boolean,
	humanSlots: { [number]: number }, -- userId -> slot
	humanPositions: { [number]: number }, -- userId -> position (1 = pole)
	reasons: { [number]: Reason },
	lastPlaces: { [number]: number }, -- userId -> the place the HUD quotes (catch-up)
	botSlots: { number }, -- by roster index (1 = fastest)
}

export type Result = {
	userId: number,
	finished: boolean,
	rank: number?,
	dnf: boolean?,
	grid: number?,
}

export type History = { place: number, grid: number? }

function GridOrder.isGridded(mode: any): boolean
	return not (type(mode) == "string" and GridOrder.EXEMPT[mode] == true)
end

function GridOrder.slotOf(position: number, field: number): number
	return field + 1 - position
end

function GridOrder.positionOf(slot: number, field: number): number
	return field + 1 - slot
end

export type Rng = { unit: () -> number, int: (lo: number, hi: number) -> number }

-- Park-Miller minimal standard generator: every product stays below 2^53, so it is exact in doubles.
local MOD = 2147483647
local function newRng(seed: number): Rng
	local state = math.floor(math.abs(seed)) % MOD
	if state == 0 then
		state = 1234567
	end
	-- Warm up: neighbouring seeds (RaceResetSeq 1, 2, 3...) must not start with neighbouring draws.
	for _ = 1, 3 do
		state = (state * 48271) % MOD
	end
	local function unit(): number
		state = (state * 48271) % MOD
		return (state - 1) / (MOD - 1)
	end
	local function int(lo: number, hi: number): number
		return lo + math.min(hi - lo, math.floor(unit() * (hi - lo + 1)))
	end
	return { unit = unit, int = int }
end
GridOrder.newRng = newRng

-- Stable per-race tie break for two humans with the same last place (two DNFs): a hash of userId and the race seed.
function GridOrder.tieKey(userId: number, seed: number): number
	local rng = newRng((math.floor(math.abs(userId)) % MOD) * 31 + (math.floor(math.abs(seed)) % 65521) * 7919 + 17)
	return rng.unit()
end

local function shuffled(list: { number }, rng: Rng): { number }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = rng.int(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

local function range(n: number): { number }
	local out = {}
	for i = 1, n do
		out[i] = i
	end
	return out
end

-- Weight of grid position p in a solo first race (the SOLO_WEIGHTS triangle for any field size).
function GridOrder.soloWeight(position: number, field: number): number
	if field == 8 then
		return GridOrder.SOLO_WEIGHTS[position] or 0
	end
	if position < 1 or position > field then
		return 0
	end
	return math.min(position, field + 1 - position)
end

local function weightedPosition(field: number, rng: Rng): number
	local total = 0
	for p = 1, field do
		total += GridOrder.soloWeight(p, field)
	end
	local roll = rng.unit() * total
	for p = 1, field do
		roll -= GridOrder.soloWeight(p, field)
		if roll < 0 then
			return p
		end
	end
	return field
end

-- Solo catch-up: the last place mirrored (1st -> field, last -> 1), +-CATCHUP_JITTER, clamped to {2, field - 1}.
function GridOrder.catchUpPosition(lastPlace: number, field: number, rng: Rng): number
	local place = math.clamp(math.floor(lastPlace), 1, field)
	local mirrored = field + 1 - place
	local target = mirrored + rng.int(-GridOrder.CATCHUP_JITTER, GridOrder.CATCHUP_JITTER)
	local lo, hi = GridOrder.CLAMP_SOLO[1], GridOrder.CLAMP_SOLO[2]
	if field ~= 8 then
		lo, hi = 2, field - 1
	end
	if hi < lo then
		lo, hi = 1, field
	end
	return math.clamp(target, lo, hi)
end

local function sortedHumans(humans: { Human }): { Human }
	local list = table.clone(humans)
	table.sort(list, function(a: Human, b: Human): boolean
		return a.userId < b.userId
	end)
	return list
end

-- Fixed grid for the exempt modes: humans 1..N by userId, bots right after them, fastest furthest forward (the grid
-- AIRacers.botSlots always built; boss placement is AIRacers.placeOnGrid's own).
local function fixedPlan(humans: { Human }, botCount: number): Plan
	local list = sortedHumans(humans)
	local plan: Plan = {
		field = math.max(#list, 1) + botCount,
		exempt = true,
		humanSlots = {},
		humanPositions = {},
		reasons = {},
		lastPlaces = {},
		botSlots = {},
	}
	for i, hm in list do
		plan.humanSlots[hm.userId] = i
		plan.humanPositions[hm.userId] = plan.field + 1 - i
		plan.reasons[hm.userId] = "fixed"
	end
	local first = math.max(#list, 1) + 1
	for i = 1, botCount do
		plan.botSlots[i] = first + botCount - i
	end
	return plan
end

-- The humans' positions for 2+ humans with a last result: reverse of the last finish on a random set of positions,
-- then the MAX_MOVE cap from each human's last grid position.
local function reversePositions(list: { Human }, field: number, seed: number, rng: Rng): { [number]: number }
	local set = table.move(shuffled(range(field), rng), 1, #list, 1, {})
	table.sort(set)
	local ranked: { Human } = {}
	local fresh: { Human } = {}
	for _, hm in list do
		table.insert(if hm.lastPlace then ranked else fresh, hm)
	end
	-- Worst last place first: the front of the set goes to the back of the last race, the winner starts furthest back.
	table.sort(ranked, function(a: Human, b: Human): boolean
		if a.lastPlace ~= b.lastPlace then
			return (a.lastPlace :: number) > (b.lastPlace :: number)
		end
		return GridOrder.tieKey(a.userId, seed) < GridOrder.tieKey(b.userId, seed)
	end)
	-- Humans with no result on this server (joined since) slot in at random spots of that order.
	for _, hm in fresh do
		table.insert(ranked, rng.int(1, #ranked + 1), hm)
	end
	local pos: { [number]: number } = {}
	local held: { [number]: boolean } = {}
	local capped: { Human } = {}
	for i, hm in ranked do
		local p = set[i]
		if hm.lastGrid and math.abs(p - hm.lastGrid) > GridOrder.MAX_MOVE then
			table.insert(capped, hm)
			pos[hm.userId] = p -- the target, resolved below
		else
			pos[hm.userId] = p
			held[p] = true
		end
	end
	for _, hm in capped do
		local target = pos[hm.userId]
		local last = hm.lastGrid :: number
		local lo, hi = math.max(1, last - GridOrder.MAX_MOVE), math.min(field, last + GridOrder.MAX_MOVE)
		local want = math.clamp(target, lo, hi)
		local toward = if target >= want then 1 else -1
		local chosen: number? = nil
		-- Nearest free position to the capped target inside the window, leaning toward the reverse target; else the
		-- nearest free position anywhere (a full window: 5+ humans bunched around this one).
		for d = 0, field do
			for _, p in { want + d * toward, want - d * toward } do
				if chosen == nil and p >= lo and p <= hi and not held[p] then
					chosen = p
				end
			end
		end
		if chosen == nil then
			for d = 0, field do
				for _, p in { want + d * toward, want - d * toward } do
					if chosen == nil and p >= 1 and p <= field and not held[p] then
						chosen = p
					end
				end
			end
		end
		local c = chosen or want
		pos[hm.userId] = c
		held[c] = true
	end
	return pos
end

-- Bots on the positions the humans left, fastest at the front, an occasional seeded swap of speed neighbours. With
-- no human one seat stays open (AIRacers.botsNeeded): the rearmost, where the first joiner lands.
local function botPositions(held: { [number]: boolean }, botCount: number, field: number, rng: Rng): { number }
	local free: { number } = {}
	for p = 1, field do
		if not held[p] then
			table.insert(free, p)
		end
	end
	local out = table.move(free, 1, math.min(botCount, #free), 1, {})
	local i = 1
	while i < #out do
		if rng.unit() < GridOrder.BOT_SWAP_CHANCE then
			out[i], out[i + 1] = out[i + 1], out[i]
			i += 2
		else
			i += 1
		end
	end
	return out
end

-- The grid for one race. humans: everyone on the server (any order); botCount: AIRacers.botsNeeded; fieldSize:
-- PlaneConfig.AI_FIELD_SIZE; seed: the race's seed (RaceResetSeq); mode: RaceMode; lastDnf: DNFs among the humans in
-- the previous race (skips the reverse above REVERSE_MAX_DNF).
function GridOrder.assign(humans: { Human }, botCount: number, fieldSize: number, seed: number, mode: string?, lastDnf: number?): Plan
	if not GridOrder.isGridded(mode) then
		return fixedPlan(humans, botCount)
	end
	local list = sortedHumans(humans)
	local h = #list
	local field = math.max(h, math.min(fieldSize, math.max(h, 1) + botCount))
	local bots = math.min(botCount, field - h)
	local rng = newRng(seed)
	local plan: Plan = {
		field = field,
		exempt = false,
		humanSlots = {},
		humanPositions = {},
		reasons = {},
		lastPlaces = {},
		botSlots = {},
	}
	local pos: { [number]: number } = {}
	if h == 1 then
		local hm = list[1]
		if hm.lastPlace then
			pos[hm.userId] = GridOrder.catchUpPosition(hm.lastPlace, field, rng)
			plan.reasons[hm.userId] = "catchup"
			plan.lastPlaces[hm.userId] = math.clamp(math.floor(hm.lastPlace), 1, field)
		else
			pos[hm.userId] = weightedPosition(field, rng)
			plan.reasons[hm.userId] = "random"
		end
	elseif h >= 2 then
		local anyResult = false
		for _, hm in list do
			if hm.lastPlace then
				anyResult = true
			end
		end
		if anyResult and (lastDnf or 0) <= GridOrder.REVERSE_MAX_DNF then
			pos = reversePositions(list, field, seed, rng)
			for _, hm in list do
				plan.reasons[hm.userId] = if hm.lastPlace then "reverse" else "random"
			end
		else
			local perm = shuffled(range(field), rng)
			for i, hm in list do
				pos[hm.userId] = perm[i]
				plan.reasons[hm.userId] = "random"
			end
		end
	end
	local held: { [number]: boolean } = {}
	for _, hm in list do
		local p = pos[hm.userId]
		held[p] = true
		plan.humanPositions[hm.userId] = p
		plan.humanSlots[hm.userId] = GridOrder.slotOf(p, field)
	end
	for i, p in botPositions(held, bots, field, rng) do
		plan.botSlots[i] = GridOrder.slotOf(p, field)
	end
	return plan
end

-- Row-mates fan outward: on the adapt.py grid slot 2r+1 is the left/centre seat and 2r+2 the right seat of row r. When
-- both seats of a row hold bots, the bot with the larger lane offset takes the right seat so the two never cross
-- while they merge into their lanes (the guarantee the old fixed slots gave). Same rows, so front/back is unchanged.
-- botSlots by roster index, laneOffsets by roster index; returns a new list.
function GridOrder.fanRowMates(botSlots: { number }, laneOffsets: { number }): { number }
	local out = table.clone(botSlots)
	local bySlot: { [number]: number } = {}
	for i, s in out do
		bySlot[s] = i
	end
	for s, i in bySlot do
		if s % 2 == 1 then
			local j = bySlot[s + 1]
			if j and (laneOffsets[i] or 0) > (laneOffsets[j] or 0) then
				out[i], out[j] = out[j], out[i]
			end
		end
	end
	return out
end

-- A human joining between resets. Gridded modes: a random seat in the rear half that no human holds, an empty one
-- before one a bot holds (AIRacers.refreshField then trims the bot on a human's seat), else any seat no human holds,
-- else the first seat past the field. Returns the slot and its position.
function GridOrder.lateJoinSlot(humanHeld: { [number]: boolean }, botHeld: { [number]: boolean }, field: number, seed: number): (number, number)
	local rng = newRng(seed)
	local rearCount = math.max(1, field // 2)
	local tiers: { { number } } = { {}, {}, {} }
	for s = 1, field do
		if not humanHeld[s] then
			if s <= rearCount then
				table.insert(if botHeld[s] then tiers[2] else tiers[1], s)
			else
				table.insert(tiers[3], s)
			end
		end
	end
	for _, tier in tiers do
		if #tier > 0 then
			local s = tier[rng.int(1, #tier)]
			return s, GridOrder.positionOf(s, field)
		end
	end
	local s = field + 1
	while humanHeld[s] do
		s += 1
	end
	return s, 1
end

-- The previous race's result for the next grid: finishers keep their place, a DNF counts as last (field), anyone
-- who left or never finished is excluded (quitting never buys a front seat). Returns userId -> History and the DNFs.
function GridOrder.harvest(results: { Result }, field: number): ({ [number]: History }, number)
	local out: { [number]: History } = {}
	local dnf = 0
	for _, r in results do
		if r.finished and type(r.rank) == "number" then
			out[r.userId] = { place = math.clamp(r.rank, 1, field), grid = r.grid }
		elseif r.dnf then
			out[r.userId] = { place = field, grid = r.grid }
			dnf += 1
		end
	end
	return out, dnf
end

function GridOrder.ordinal(n: number): string
	local k = math.floor(n)
	local tens = k % 100
	local suffix = "th"
	if tens < 11 or tens > 13 then
		local ones = k % 10
		suffix = if ones == 1 then "st" elseif ones == 2 then "nd" elseif ones == 3 then "rd" else "th"
	end
	return tostring(k) .. suffix
end

-- HUD strings (client TrackFlow formats only; the server publishes GridReason / GridPosition / GridLastPlace /
-- GridField on the player).
-- v38-flow: brief, upper case, MK-like (one glance under the countdown, never a sentence).
GridOrder.TEXT = {
	random = "START %s OF %d",
	catchup = "START %s  -  LAST RACE %s",
	reverse = "WINNER STARTS LAST  -  YOU START %s",
	late = "LATE START  -  %s OF %d",
}

function GridOrder.hudLine(reason: any, position: any, lastPlace: any, field: any): string
	if type(position) ~= "number" or type(field) ~= "number" then
		return ""
	end
	local function ord(n: number): string
		return string.upper(GridOrder.ordinal(n))
	end
	if reason == "random" then
		return string.format(GridOrder.TEXT.random, ord(position), field)
	elseif reason == "catchup" and type(lastPlace) == "number" then
		return string.format(GridOrder.TEXT.catchup, ord(position), ord(lastPlace))
	elseif reason == "reverse" then
		return string.format(GridOrder.TEXT.reverse, ord(position))
	elseif reason == "late" then
		return string.format(GridOrder.TEXT.late, ord(position), field)
	end
	return ""
end

-- True while the countdown overlay shows the grid line: the HUD_SECONDS before the last half second of the hold.
function GridOrder.hudVisible(secondsToGo: number): boolean
	return secondsToGo > 0.5 and secondsToGo <= 0.5 + GridOrder.HUD_SECONDS
end

-- The position plank's text. Before GO the live rank is meaningless (it reads 1 and TotalRacers is still the standings
-- count, so the plank said "1/1"): show the grid seat out of the field the server published, "–/field" while the seat
-- is not known yet. From GO on it is the live "rank/total". fallbackField is the field size when nothing else says.
function GridOrder.plankText(started: boolean, rank: number, total: number, gridPosition: any, gridField: any, fallbackField: number): string
	if started then
		return string.format("%d/%d", rank, total)
	end
	local field = if type(gridField) == "number" and gridField >= 2 then gridField
		elseif total >= 2 then total
		else fallbackField
	if type(gridPosition) == "number" and gridPosition >= 1 and gridPosition <= field then
		return string.format("%d/%d", gridPosition, field)
	end
	return string.format("\u{2013}/%d", field)
end

return GridOrder
