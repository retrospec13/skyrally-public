--!strict
-- DINO-BATTLE egg battle scoring (LAUNCH_PROGRESSION section 2b; TEST_LIST_LAUNCH L71). Pure: no services, no
-- instances, no yields. The server mode (server/battle/modes/Egg) feeds it positions every Heartbeat and landed hits,
-- and turns the events it returns into visuals, toasts and the HUD; tools/tests/egg_spec.luau specs every rule.
--
-- Rules (section 2b; numbers marked OURS are launch defaults):
-- * One egg sits in the centre nest. Flying through it (CENTRE_RADIUS of the egg) takes it; the centre lays its next
--   egg RESPAWN_SECONDS (OURS 3) after one is taken. An entrant carries at most one egg.
-- * Flying through your own nest ring (NEST_RADIUS of the ring centre) with an egg drops it there. An egg hatches
--   HATCH_SECONDS (10) after it entered the nest it sits in; a hatched egg is a point and can never be taken.
-- * Flying through an opponent's nest ring while carrying nothing steals its unhatched egg nearest to hatching (the
--   oldest); the thief carries it, and its hatch clock starts again in the thief's nest.
-- * A landed item hit on a carrier knocks the egg loose (OURS): it hangs where the hit landed for LOOSE_SECONDS (10)
--   and anyone flying through it (LOOSE_RADIUS) takes it, except the entrant who dropped it during REGRAB_SECONDS (2);
--   untaken, it crumbles. A respawn drops it where the plane was, so a crash never carries an egg home: the server's
--   respawn signal (EggRules.respawned: a crash completed, or a boundary return), or a jump past JUMP_DROP in one step
--   when that signal is late or missing. A player who leaves drops its egg the same way; the eggs in its nest stay
--   (stealable) but no longer hatch.
-- * First to TO_WIN (3) hatched wins at once (two reaching it on one step: the earlier hatch time, then a player over
--   a bot, then the lower seat). At the 3-minute cap the most hatched wins; ties go to the one that reached its count
--   first, then more unhatched eggs in its nest, then the egg nearest to hatching, then carrying an egg, then a player
--   over a bot, then the lower seat. Never random. An entrant who left ranks below everyone still in the battle. The
--   cap names no winner when nobody hatched an egg (the tie rule ranks, it never hands out a win on its own).
-- * Fly-through checks test the segment between an entrant's last two positions, so a fast pass between Heartbeats
--   still counts; a jump longer than SEGMENT_MAX (a respawn, a boundary return) tests only where it landed.

local EggRules = {}

EggRules.HATCH_SECONDS = 10 -- section 2b
EggRules.TO_WIN = 3 -- section 2b: first to 3 hatched
EggRules.RESPAWN_SECONDS = 3 -- OURS: the centre lays its next egg this long after one is taken
EggRules.LOOSE_SECONDS = 10 -- OURS: a knocked-loose egg hangs this long, then crumbles
EggRules.REGRAB_SECONDS = 2 -- OURS: the entrant who dropped an egg cannot take it back before this
EggRules.NEST_RADIUS = 20 -- OURS: fly-through radius of a nest ring (the ring is drawn at 16)
EggRules.CENTRE_RADIUS = 18 -- OURS: fly-through radius of the centre egg
EggRules.LOOSE_RADIUS = 16 -- OURS: fly-through radius of a loose egg
EggRules.SEGMENT_MAX = 60 -- a position jump longer than this (a respawn) tests only its end point; shorter ones are lag
EggRules.JUMP_DROP = 150 -- OURS: a carrier that jumps farther in one step (crash respawn) drops its egg; a network
-- stall that long would take 0.7 s at the 210 studs/s overcharge, so ordinary lag does not drop one
EggRules.RESPAWN_WINDOW = 1.5 -- a respawn signal this soon after a carrier's teleport jump belongs to that jump
-- Bot choices (OURS): a steal costs this much extra over the same distance to the centre egg, an egg's hatch progress
-- (0..1) is worth up to STEAL_URGENCY studs, and a target another bot has picked and is closer to (by CONTEST_MARGIN)
-- costs CONTEST.
EggRules.STEAL_BIAS = 40
EggRules.STEAL_URGENCY = 140
EggRules.CONTEST_MARGIN = 25
EggRules.CONTEST = 180

export type Where = "centre" | "carried" | "nest" | "loose"

export type Egg = {
	id: number,
	at: Where,
	holder: string?, -- "carried": who carries it
	owner: string?, -- "nest": whose nest it sits in
	placedAt: number?, -- "nest": when it entered that nest (its hatch clock)
	hatched: boolean,
	hatchedAt: number?,
	pos: Vector3?, -- "loose": where it hangs
	looseUntil: number?,
	noGrabId: string?, -- "loose": the entrant who dropped it ...
	noGrabUntil: number?, -- ... cannot take it back before this
}

export type Seat = {
	id: string,
	isPlayer: boolean,
	slot: number,
}

export type Entry = {
	id: string,
	isPlayer: boolean,
	slot: number,
	nest: number?, -- index into geometry.nests (nil: no nest free for this seat)
	carrying: number?, -- egg id
	hatched: number,
	reachedAt: number?, -- when its hatched count last went up
	delivered: number,
	steals: number,
	drops: number,
	left: boolean,
	-- Its last teleport-sized jump (past SEGMENT_MAX) while carrying: where from, when, and the egg it carried. The
	-- server's respawn signal can arrive after the jump; the egg then falls where the plane was before it.
	jumpFrom: Vector3?,
	jumpAt: number?,
	jumpEgg: number?,
}

export type Geometry = {
	centre: Vector3, -- where the centre egg sits
	nests: { Vector3 }, -- nest ring centres, one per seat
}

export type Rules = {
	hatchSeconds: number?,
	toWin: number?,
	respawnSeconds: number?,
	looseSeconds: number?,
}

export type EventKind = "lay" | "pickup" | "deposit" | "steal" | "hatch" | "drop" | "crumble" | "win"

export type Event = {
	kind: EventKind,
	egg: number?,
	id: string?, -- the entrant it happened to (picker, depositor, thief, hatcher, dropper, winner)
	victim: string?, -- "steal": whose nest it came from
	from: string?, -- "pickup": "centre" | "loose"; "drop": "hit" | "jump" | "respawn" | "leave"
	count: number?, -- "hatch" / "win": the entrant's hatched count
	t: number,
}

export type State = {
	hatchSeconds: number,
	toWin: number,
	respawnSeconds: number,
	looseSeconds: number,
	geometry: Geometry,
	entries: { [string]: Entry },
	ids: { string }, -- seat order
	eggs: { [number]: Egg },
	nextEgg: number,
	centreEgg: number?, -- egg id waiting in the centre nest
	respawnAt: number?, -- when the centre lays its next egg
	prev: { [string]: Vector3 }, -- last position seen per entrant (segment tests)
	winner: string?,
	wonAt: number?,
}

export type Outcome = {
	over: boolean,
	winner: string?,
	reason: string, -- "first to 3" | "time" | "running"
}

export type Target = {
	pos: Vector3,
	reason: string, -- "home" | "centre" | "loose" | "steal" | "chase" | "wait" | "carry"
	attack: string?, -- an opponent carrying an egg, for the bot's missiles
	egg: number?,
}

local function posNum(v: number?, default: number): number
	return if type(v) == "number" and v > 0 then v else default
end

-- Eggs in id order (deterministic iteration whatever the table's layout).
local function eggList(state: State): { Egg }
	local out: { Egg } = {}
	for _, egg in state.eggs do
		table.insert(out, egg)
	end
	table.sort(out, function(a: Egg, b: Egg): boolean
		return a.id < b.id
	end)
	return out
end

local function layEgg(state: State): Egg
	local egg: Egg = { id = state.nextEgg, at = "centre", hatched = false }
	state.nextEgg += 1
	state.eggs[egg.id] = egg
	state.centreEgg = egg.id
	state.respawnAt = nil
	return egg
end

-- New battle state. Seats take the nest with their slot number when it exists and is free, else the first free nest
-- (a seat past the last nest gets none). The first egg is laid in the centre at once (visible through the countdown).
function EggRules.new(seats: { Seat }, geometry: Geometry, rules: Rules?): State
	local r: Rules = rules or {}
	local state: State = {
		hatchSeconds = posNum(r.hatchSeconds, EggRules.HATCH_SECONDS),
		toWin = math.floor(posNum(r.toWin, EggRules.TO_WIN)),
		respawnSeconds = posNum(r.respawnSeconds, EggRules.RESPAWN_SECONDS),
		looseSeconds = posNum(r.looseSeconds, EggRules.LOOSE_SECONDS),
		geometry = geometry,
		entries = {},
		ids = {},
		eggs = {},
		nextEgg = 1,
		centreEgg = nil,
		respawnAt = nil,
		prev = {},
		winner = nil,
		wonAt = nil,
	}
	local taken: { [number]: boolean } = {}
	for _, s in seats do
		if not state.entries[s.id] then
			local nest: number? = nil
			if s.slot >= 1 and s.slot <= #geometry.nests and not taken[s.slot] then
				nest = s.slot
			end
			state.entries[s.id] = {
				id = s.id,
				isPlayer = s.isPlayer,
				slot = s.slot,
				nest = nest,
				carrying = nil,
				hatched = 0,
				reachedAt = nil,
				delivered = 0,
				steals = 0,
				drops = 0,
				left = false,
				jumpFrom = nil,
				jumpAt = nil,
				jumpEgg = nil,
			}
			if nest then
				taken[nest] = true
			end
			table.insert(state.ids, s.id)
		end
	end
	for _, id in state.ids do
		local e = state.entries[id]
		if not e.nest then
			for i = 1, #geometry.nests do
				if not taken[i] then
					e.nest = i
					taken[i] = true
					break
				end
			end
		end
	end
	layEgg(state)
	return state
end

function EggRules.nestPos(state: State, id: string): Vector3?
	local e = state.entries[id]
	local i = if e then e.nest else nil
	return if i then state.geometry.nests[i] else nil
end

-- Who owns nest i (nil when no seat has it).
function EggRules.nestOwner(state: State, index: number): string?
	for _, id in state.ids do
		if state.entries[id].nest == index then
			return id
		end
	end
	return nil
end

-- Eggs sitting in id's nest (hatched and not), oldest first.
function EggRules.nestEggs(state: State, ownerId: string): { Egg }
	local out: { Egg } = {}
	for _, egg in state.eggs do
		if egg.at == "nest" and egg.owner == ownerId then
			table.insert(out, egg)
		end
	end
	table.sort(out, function(a: Egg, b: Egg): boolean
		local pa, pb = a.placedAt or 0, b.placedAt or 0
		if pa ~= pb then
			return pa < pb
		end
		return a.id < b.id
	end)
	return out
end

function EggRules.unhatchedIn(state: State, ownerId: string): { Egg }
	local out: { Egg } = {}
	for _, egg in EggRules.nestEggs(state, ownerId) do
		if not egg.hatched then
			table.insert(out, egg)
		end
	end
	return out
end

-- Hatch progress 0..1 of an egg in a nest (0 anywhere else, 1 once hatched).
function EggRules.progress(state: State, egg: Egg, t: number): number
	if egg.hatched then
		return 1
	end
	if egg.at ~= "nest" or not egg.placedAt then
		return 0
	end
	return math.clamp((t - egg.placedAt) / state.hatchSeconds, 0, 1)
end

-- Whether the segment a -> b passes within radius of centre (b alone when a is nil or the jump is a teleport).
function EggRules.passes(a: Vector3?, b: Vector3, centre: Vector3, radius: number): boolean
	if (b - centre).Magnitude <= radius then
		return true
	end
	if not a or (b - a).Magnitude > EggRules.SEGMENT_MAX then
		return false
	end
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-9 then
		return false
	end
	local k = math.clamp((centre - a):Dot(ab) / len2, 0, 1)
	return ((a + ab * k) - centre).Magnitude <= radius
end

local function inPlay(e: Entry?): boolean
	return e ~= nil and not e.left
end

local function looseAt(state: State, egg: Egg, dropper: string, pos: Vector3, t: number)
	egg.at = "loose"
	egg.holder = nil
	egg.owner = nil
	egg.placedAt = nil
	egg.pos = pos
	egg.looseUntil = t + state.looseSeconds
	egg.noGrabId = dropper
	egg.noGrabUntil = t + EggRules.REGRAB_SECONDS
end

local function carry(egg: Egg, id: string)
	egg.at = "carried"
	egg.holder = id
	egg.owner = nil
	egg.placedAt = nil
	egg.pos = nil
	egg.looseUntil = nil
	egg.noGrabId = nil
	egg.noGrabUntil = nil
end

-- Winner among entrants at or past toWin: earliest to reach it, then a player, then the lower seat.
local function pickWinner(state: State): string?
	local best: Entry? = nil
	for _, id in state.ids do
		local e = state.entries[id]
		if inPlay(e) and e.hatched >= state.toWin then
			local b = best
			if not b then
				best = e
			else
				local ra, rb = e.reachedAt or math.huge, b.reachedAt or math.huge
				if ra < rb or (ra == rb and ((e.isPlayer and not b.isPlayer) or (e.isPlayer == b.isPlayer and e.slot < b.slot))) then
					best = e
				end
			end
		end
	end
	return if best then best.id else nil
end

-- One Heartbeat at battle time t. positions: where each entrant in play is now (missing = not moving this step).
-- Returns the events in the order they happened.
function EggRules.step(state: State, t: number, positions: { [string]: Vector3 }): { Event }
	local events: { Event } = {}
	if state.winner then
		return events
	end
	-- Loose eggs nobody took crumble.
	for _, egg in eggList(state) do
		if egg.at == "loose" and egg.looseUntil and t >= egg.looseUntil then
			state.eggs[egg.id] = nil
			table.insert(events, { kind = "crumble", egg = egg.id, t = t })
		end
	end
	-- The centre lays its next egg.
	if not state.centreEgg and state.respawnAt and t >= state.respawnAt then
		local egg = layEgg(state)
		table.insert(events, { kind = "lay", egg = egg.id, t = t })
	end
	local geo = state.geometry
	for _, id in state.ids do
		local e = state.entries[id]
		local p = positions[id]
		if inPlay(e) and p then
			local a = state.prev[id]
			local carrying = if e.carrying then state.eggs[e.carrying] else nil
			if carrying and a and (p - a).Magnitude > EggRules.SEGMENT_MAX then
				e.jumpFrom, e.jumpAt, e.jumpEgg = a, t, carrying.id
			end
			if carrying and a and (p - a).Magnitude > EggRules.JUMP_DROP then
				-- A crash respawn or a boundary return: the egg falls where the plane was.
				e.carrying = nil
				e.drops += 1
				looseAt(state, carrying, id, a, t)
				table.insert(events, { kind = "drop", egg = carrying.id, id = id, from = "jump", t = t })
				carrying = nil
			end
			if carrying then
				local nestPos = if e.nest then geo.nests[e.nest] else nil
				if nestPos and EggRules.passes(a, p, nestPos, EggRules.NEST_RADIUS) then
					carrying.at = "nest"
					carrying.holder = nil
					carrying.owner = id
					carrying.placedAt = t
					e.carrying = nil
					e.delivered += 1
					table.insert(events, { kind = "deposit", egg = carrying.id, id = id, t = t })
				end
			else
				local took = false
				local centreEgg = if state.centreEgg then state.eggs[state.centreEgg] else nil
				if centreEgg and EggRules.passes(a, p, geo.centre, EggRules.CENTRE_RADIUS) then
					carry(centreEgg, id)
					e.carrying = centreEgg.id
					state.centreEgg = nil
					state.respawnAt = t + state.respawnSeconds
					took = true
					table.insert(events, { kind = "pickup", egg = centreEgg.id, id = id, from = "centre", t = t })
				end
				if not took then
					for _, egg in eggList(state) do
						local blocked = egg.noGrabId == id and egg.noGrabUntil ~= nil and t < egg.noGrabUntil
						if egg.at == "loose" and egg.pos and not blocked and EggRules.passes(a, p, egg.pos, EggRules.LOOSE_RADIUS) then
							carry(egg, id)
							e.carrying = egg.id
							took = true
							table.insert(events, { kind = "pickup", egg = egg.id, id = id, from = "loose", t = t })
							break
						end
					end
				end
				if not took then
					for i, nestPos in geo.nests do
						if i ~= e.nest and EggRules.passes(a, p, nestPos, EggRules.NEST_RADIUS) then
							local owner = EggRules.nestOwner(state, i)
							local list = if owner then EggRules.unhatchedIn(state, owner) else {}
							local egg = list[1]
							if owner and egg then
								carry(egg, id)
								e.carrying = egg.id
								e.steals += 1
								table.insert(events, { kind = "steal", egg = egg.id, id = id, victim = owner, t = t })
								break
							end
						end
					end
				end
			end
		end
		if p then
			state.prev[id] = p
		end
	end
	-- Hatching, in hatch-time order (an owner who left no longer hatches).
	local due: { Egg } = {}
	for _, egg in state.eggs do
		if egg.at == "nest" and not egg.hatched and egg.placedAt and t - egg.placedAt >= state.hatchSeconds then
			if inPlay(state.entries[egg.owner :: string]) then
				table.insert(due, egg)
			end
		end
	end
	table.sort(due, function(a: Egg, b: Egg): boolean
		local pa, pb = a.placedAt :: number, b.placedAt :: number
		if pa ~= pb then
			return pa < pb
		end
		return a.id < b.id
	end)
	for _, egg in due do
		local owner = state.entries[egg.owner :: string]
		egg.hatched = true
		egg.hatchedAt = (egg.placedAt :: number) + state.hatchSeconds
		owner.hatched += 1
		owner.reachedAt = egg.hatchedAt
		table.insert(events, { kind = "hatch", egg = egg.id, id = owner.id, count = owner.hatched, t = t })
	end
	local winner = pickWinner(state)
	if winner then
		state.winner = winner
		state.wonAt = t
		table.insert(events, { kind = "win", id = winner, count = state.entries[winner].hatched, t = t })
	end
	return events
end

-- A landed item hit on victim at t (pos = where the egg is knocked loose). Returns the drop event, or nil when the
-- victim carried nothing.
function EggRules.hit(state: State, victimId: string, t: number, pos: Vector3): Event?
	local e = state.entries[victimId]
	if not inPlay(e) or state.winner then
		return nil
	end
	local entry = e :: Entry
	local egg = if entry.carrying then state.eggs[entry.carrying] else nil
	if not egg then
		return nil
	end
	entry.carrying = nil
	entry.drops += 1
	looseAt(state, egg, victimId, pos, t)
	return { kind = "drop", egg = egg.id, id = victimId, from = "hit", t = t }
end

-- The server's respawn signal for id at t (a crash completed, or a boundary return put it back on a pad): a carried
-- egg falls where the plane was. That is where it jumped from when the teleport jump reached the rules first (within
-- RESPAWN_WINDOW), else where the rules last saw it (a crashed plane tumbles in place until it respawns). An egg taken
-- after that jump stays: it was picked up at the respawn point. Returns the drop event, or nil.
function EggRules.respawned(state: State, id: string, t: number): Event?
	local e = state.entries[id]
	if not inPlay(e) or state.winner then
		return nil
	end
	local entry = e :: Entry
	local egg = if entry.carrying then state.eggs[entry.carrying] else nil
	if not egg then
		return nil
	end
	local at: Vector3? = state.prev[id]
	local jumpAt = entry.jumpAt
	if jumpAt and t - jumpAt >= 0 and t - jumpAt <= EggRules.RESPAWN_WINDOW then
		if entry.jumpEgg ~= egg.id then
			return nil
		end
		at = entry.jumpFrom
	end
	local spot = at
	if not spot then
		return nil
	end
	entry.carrying = nil
	entry.drops += 1
	entry.jumpFrom, entry.jumpAt, entry.jumpEgg = nil, nil, nil
	looseAt(state, egg, id, spot, t)
	return { kind = "drop", egg = egg.id, id = id, from = "respawn", t = t }
end

-- A player left: out of the battle; a carried egg drops loose where it was (crumbles when pos is unknown).
function EggRules.leave(state: State, id: string, t: number, pos: Vector3?): { Event }
	local events: { Event } = {}
	local e = state.entries[id]
	if not e or e.left then
		return events
	end
	e.left = true
	local egg = if e.carrying then state.eggs[e.carrying] else nil
	e.carrying = nil
	if egg then
		if pos then
			looseAt(state, egg, id, pos, t)
			egg.noGrabId = nil
			egg.noGrabUntil = nil
			table.insert(events, { kind = "drop", egg = egg.id, id = id, from = "leave", t = t })
		else
			state.eggs[egg.id] = nil
			table.insert(events, { kind = "crumble", egg = egg.id, t = t })
		end
	end
	return events
end

-- Best unhatched progress in id's nest (0 when empty).
local function bestProgress(state: State, id: string, t: number): number
	local best = 0
	for _, egg in EggRules.unhatchedIn(state, id) do
		best = math.max(best, EggRules.progress(state, egg, t))
	end
	return best
end

-- true when a ranks above b (see the tie rule in the header). t only matters for hatch progress.
function EggRules.better(state: State, a: string, b: string, t: number?): boolean
	local ea, eb = state.entries[a], state.entries[b]
	if not ea or not eb then
		return ea ~= nil
	end
	if ea.left ~= eb.left then
		return not ea.left
	end
	if ea.hatched ~= eb.hatched then
		return ea.hatched > eb.hatched
	end
	if ea.hatched > 0 then
		local ra, rb = ea.reachedAt or math.huge, eb.reachedAt or math.huge
		if ra ~= rb then
			return ra < rb
		end
	end
	local na, nb = #EggRules.unhatchedIn(state, a), #EggRules.unhatchedIn(state, b)
	if na ~= nb then
		return na > nb
	end
	local now = t or 0
	local pa, pb = bestProgress(state, a, now), bestProgress(state, b, now)
	if pa ~= pb then
		return pa > pb
	end
	local ca, cb = ea.carrying ~= nil, eb.carrying ~= nil
	if ca ~= cb then
		return ca
	end
	if ea.isPlayer ~= eb.isPlayer then
		return ea.isPlayer
	end
	return ea.slot < eb.slot
end

-- Every entrant, best first.
function EggRules.ranking(state: State, t: number?): { string }
	local ids = table.clone(state.ids)
	table.sort(ids, function(a: string, b: string): boolean
		return EggRules.better(state, a, b, t)
	end)
	return ids
end

function EggRules.checkEnd(state: State): Outcome
	if state.winner then
		return { over = true, winner = state.winner, reason = "first to " .. tostring(state.toWin) }
	end
	return { over = false, winner = nil, reason = "running" }
end

-- The 3-minute cap: most hatched wins, ties by the tie rule. Nobody hatched an egg: no winner (the player would
-- otherwise take the battle, and its fragment, on the "player over a bot" tie alone).
function EggRules.resolveCap(state: State, t: number?): Outcome
	local first = EggRules.ranking(state, t)[1]
	local best = if first then state.entries[first] else nil
	local winner = if best and not best.left and best.hatched > 0 then best.id else nil
	return { over = true, winner = winner, reason = "time" }
end

-- Board value (the HUD board orders by it, higher first): the entrant's place in EggRules.ranking at t, so the live
-- board always shows the order the cap would give and the results never contradict the board they replace.
-- `ranking`: EggRules.ranking(state, t), when the caller scores the whole field at once.
function EggRules.boardScore(state: State, id: string, t: number?, ranking: { string }?): number
	local order = ranking or EggRules.ranking(state, t)
	local i = table.find(order, id)
	return if i then #order - i else -1
end

-- Raw standing: hatched, then eggs in the nest, then carrying (the board uses boardScore).
function EggRules.scoreValue(state: State, id: string): number
	local e = state.entries[id]
	if not e then
		return 0
	end
	return e.hatched * 100 + #EggRules.unhatchedIn(state, id) * 10 + (if e.carrying then 1 else 0)
end

-- Board / results text: "2 HATCHED + 1 NEST + EGG".
function EggRules.scoreText(state: State, id: string): string
	local e = state.entries[id]
	if not e then
		return ""
	end
	if e.left then
		return string.format("%d HATCHED (LEFT)", e.hatched)
	end
	local text = string.format("%d HATCHED", e.hatched)
	local inNest = #EggRules.unhatchedIn(state, id)
	if inNest > 0 then
		text ..= string.format(" + %d NEST", inNest)
	end
	if e.carrying then
		text ..= " + EGG"
	end
	return text
end

-- The player's objective line. nestName names its nest ("BLUE").
function EggRules.hudText(state: State, id: string, t: number, nestName: string?): string
	local e = state.entries[id]
	if not e then
		return ""
	end
	local head = string.format("HATCHED %d/%d", e.hatched, state.toWin)
	local nest = if nestName then nestName .. " nest" else "your nest"
	if e.carrying then
		if not e.nest then
			return head .. "  -  carrying an egg (no nest free)"
		end
		return string.format("%s  -  EGG! fly through your %s", head, nest)
	end
	local mine = EggRules.unhatchedIn(state, id)
	if #mine > 0 then
		local left = state.hatchSeconds - (t - (mine[1].placedAt or t))
		return string.format("%s  -  hatching in %d s, guard the %s", head, math.max(0, math.ceil(left)), nest)
	end
	if state.centreEgg then
		return head .. "  -  grab the egg at the centre nest"
	end
	for _, other in state.ids do
		if other ~= id and #EggRules.unhatchedIn(state, other) > 0 then
			return head .. "  -  steal an egg from a rival nest"
		end
	end
	for _, egg in state.eggs do
		if egg.at == "loose" then
			return head .. "  -  grab the dropped egg"
		end
	end
	local wait = if state.respawnAt then math.max(0, math.ceil(state.respawnAt - t)) else 0
	return string.format("%s  -  next egg in %d s", head, wait)
end

local function horizontal(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

type Option = {
	key: string,
	pos: Vector3,
	reason: string,
	egg: number,
	factor: number, -- cost per stud of distance
	extra: number, -- cost on top of the distance
}

-- What entrant forId could go and take now: the centre egg, loose eggs it may grab, and the egg nearest to hatching in
-- every rival nest (cost: distance, a loose egg cheaper, a steal dearer but cheaper the nearer it is to hatching).
local function optionsFor(state: State, forId: string, t: number): { Option }
	local e = state.entries[forId]
	local geo = state.geometry
	local out: { Option } = {}
	if state.centreEgg then
		table.insert(out, { key = "centre", pos = geo.centre, reason = "centre", egg = state.centreEgg, factor = 1, extra = 0 })
	end
	for _, egg in eggList(state) do
		local blocked = egg.noGrabId == forId and egg.noGrabUntil ~= nil and t < egg.noGrabUntil
		if egg.at == "loose" and egg.pos and not blocked then
			table.insert(out, { key = "loose:" .. tostring(egg.id), pos = egg.pos, reason = "loose", egg = egg.id, factor = 0.8, extra = 0 })
		end
	end
	for i, nestPos in geo.nests do
		if not e or i ~= e.nest then
			local owner = EggRules.nestOwner(state, i)
			local egg = if owner then EggRules.unhatchedIn(state, owner)[1] else nil
			if egg then
				local p = EggRules.progress(state, egg, t)
				table.insert(out, {
					key = "nest:" .. tostring(i),
					pos = nestPos,
					reason = "steal",
					egg = egg.id,
					factor = 1,
					extra = EggRules.STEAL_BIAS - EggRules.STEAL_URGENCY * p,
				})
			end
		end
	end
	return out
end

local function costOf(o: Option, from: Vector3): number
	return (o.pos - from).Magnitude * o.factor + o.extra
end

-- Where a bot (id at pos) should head now. others: live positions of every entrant in play; bots: ids that are bots.
-- Carrying: its own nest. Otherwise the cheapest option (see optionsFor); an option another free bot has picked as its
-- own cheapest and is clearly closer to (CONTEST_MARGIN) costs CONTEST more, so bots spread over the eggs instead of
-- queueing for one (the player is always worth racing). Nothing to take: chase the nearest carrier. Every target aims
-- the bot's items at the nearest opponent carrying an egg (attack).
function EggRules.botTarget(
	state: State,
	id: string,
	pos: Vector3,
	t: number,
	others: { [string]: Vector3 },
	bots: { [string]: boolean }
): Target
	local e = state.entries[id]
	local geo = state.geometry
	local carrier: string? = nil
	local carrierD = math.huge
	for _, other in state.ids do
		local o = state.entries[other]
		local op = others[other]
		if other ~= id and inPlay(o) and o.carrying and op then
			local d = (op - pos).Magnitude
			if d < carrierD then
				carrier, carrierD = other, d
			end
		end
	end
	if not e then
		return { pos = geo.centre, reason = "wait" }
	end
	if e.carrying then
		local home = EggRules.nestPos(state, id)
		return { pos = home or geo.centre, reason = if home then "home" else "carry", egg = e.carrying }
	end
	-- Claims: each other free bot's own cheapest option and how far it is from it.
	local claims: { [string]: number } = {}
	for _, other in state.ids do
		local o = state.entries[other]
		local op = others[other]
		if other ~= id and bots[other] and op and inPlay(o) and not o.carrying then
			local pick: Option? = nil
			local pickCost = math.huge
			for _, opt in optionsFor(state, other, t) do
				local c = costOf(opt, op)
				if c < pickCost then
					pick, pickCost = opt, c
				end
			end
			if pick then
				local d = (pick.pos - op).Magnitude
				claims[pick.key] = math.min(claims[pick.key] or math.huge, d)
			end
		end
	end
	local best: Target? = nil
	local bestCost = math.huge
	for _, opt in optionsFor(state, id, t) do
		local d = (opt.pos - pos).Magnitude
		local claim = claims[opt.key]
		local c = costOf(opt, pos) + (if claim and claim + EggRules.CONTEST_MARGIN < d then EggRules.CONTEST else 0)
		if c < bestCost then
			bestCost = c
			best = { pos = opt.pos, reason = opt.reason, attack = carrier, egg = opt.egg }
		end
	end
	if best then
		return best
	end
	if carrier and others[carrier] then
		return { pos = others[carrier], reason = "chase", attack = carrier }
	end
	-- Nothing to take: guard an egg in its own nest, else circle back to the centre for the next egg.
	local home = EggRules.nestPos(state, id)
	if home and #EggRules.unhatchedIn(state, id) > 0 and horizontal(home, pos) > 60 then
		return { pos = home, reason = "guard" }
	end
	return { pos = geo.centre, reason = "wait" }
end

-- A plane turning at most `turnRadius` cannot fly through a point inside either turning circle beside it; steering
-- at it would orbit it forever. When target is inside one, aim straight on and a little away until the turn fits
-- ("line up"). A target behind (more than 90 degrees off the nose) is steered at through a level point square to the
-- nose on its side ("turn"): aimed straight at, the bots' turn (BattleRules.turnToward, a slerp toward a nearly
-- opposite direction) swings through a steep dive or climb, the pitch limit then stalls the turn, and the plane skims
-- the floor (on DINO-4 it flew through the altar tiers). Returns the point to steer at, whether it was replaced, and
-- why ("line up" | "turn").
function EggRules.approach(pos: Vector3, forward: Vector3, target: Vector3, turnRadius: number): (Vector3, boolean, string?)
	local f = Vector3.new(forward.X, 0, forward.Z)
	if f.Magnitude < 1e-3 or turnRadius <= 0 then
		return target, false, nil
	end
	f = f.Unit
	local right = Vector3.new(-f.Z, 0, f.X)
	local to = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
	for _, side in { 1, -1 } do
		local centre = right * (side * turnRadius)
		if (to - centre).Magnitude < turnRadius * 0.95 then
			local away = pos + f * (turnRadius * 2) - right * (side * turnRadius * 0.6)
			return Vector3.new(away.X, target.Y, away.Z), true, "line up"
		end
	end
	if to:Dot(f) < 0 then
		local side = if to:Dot(right) >= 0 then 1 else -1
		local beside = pos + right * (side * turnRadius * 2)
		return Vector3.new(beside.X, target.Y, beside.Z), true, "turn"
	end
	return target, false, nil
end

return EggRules
