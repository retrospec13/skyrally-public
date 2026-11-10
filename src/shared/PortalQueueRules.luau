--!strict
-- The portal IS the queue (economy v3 phase 3, owner spec section 2; docs/design/ECONOMY_V3_PLAN.md "Phase 3").
-- Pure: no Instances, no clock, specced in tools/tests/portal_queue_spec.luau. Shared by the server (TrackDirector: who
-- is in which arch's lobby, when it goes, the ArchStates it publishes) and the client (TrackFlow: the arch labels, the
-- Adventure board rows, the "Waiting for racers" line).
--
-- Each arch (one per race track) is in one of three states:
--   OPEN     no lobby, no race from it: "RACE - drive through to start".
--   FILLING  a lobby gathers: "STARTING 0:14 - 3/8". The first player through opens it (LOBBY_SECONDS); anyone who drives
--            through (or presses JOIN on the board) joins; at 0 bots fill the field and ONLY the joined players go.
--   RACING   a race from this arch runs: "RACING - next lobby opens in 1:40". Driving through now joins the NEXT lobby,
--            which goes at max(the race frees the arch, its own LOBBY_SECONDS).
-- A player sits in at most one lobby; joining another arch leaves the first. Nobody is ever pulled in: only a crossing
-- or a JOIN press adds a player, and leaving (LEAVE, backing out of the arch, leaving the server) is always allowed.
local PortalQueueRules = {}

-- Rough length of a race from GO to its last finish, for the RACING label only (the queue itself waits for the real
-- end). Past the estimate the label says "soon".
PortalQueueRules.RACE_EST_SECONDS = 150
-- The results card's return timer (server/RaceGroups RETURN_AFTER_FINISH): a race in results frees its arch this long
-- after it entered results.
PortalQueueRules.RESULTS_SECONDS = 22
-- Spec row ids for each label (shared/NotifySpec).
PortalQueueRules.ROW = {
	open = "portal_open",
	filling = "portal_filling",
	racing = "portal_racing",
	racingSoon = "portal_racing_soon",
	queued = "portal_queued",
	queuedSoon = "portal_queued_soon",
}

export type Member = { via: string, at: number }
export type Lobby = { mode: string, openedAt: number, goAt: number, order: { number }, members: { [number]: Member } }
-- race: the state of the race instance this arch's track is running (shared/RaceInstanceRules State), nil for none.
-- raceGoAt: its GO time; raceEndAt: when its results return the players (ReturnToHubAt), when known.
export type Arch = { trackId: string, lobby: Lobby?, race: string?, raceGoAt: number?, raceEndAt: number? }
export type Queue = { arches: { [string]: Arch }, where: { [number]: string }, seconds: number, cap: number }
-- One arch as published (workspace ArchStates JSON, keyed by track id): s state, t the time its countdown reaches
-- (server time; nil = unknown, "soon"), n players in the lobby, c the cap, m the lobby's mode.
export type Entry = { s: string, t: number?, n: number, c: number, m: string? }
export type Due = { trackId: string, mode: string, players: { number }, members: { [number]: Member } }

function PortalQueueRules.new(seconds: number, cap: number): Queue
	return { arches = {}, where = {}, seconds = math.max(0, seconds), cap = math.max(1, math.floor(cap)) }
end

function PortalQueueRules.arch(q: Queue, trackId: string): Arch
	local a = q.arches[trackId]
	if not a then
		a = { trackId = trackId, lobby = nil, race = nil, raceGoAt = nil, raceEndAt = nil }
		q.arches[trackId] = a
	end
	return a :: Arch
end

-- The race the arch's track runs now (from the live instances), or nil for none.
function PortalQueueRules.setRace(q: Queue, trackId: string, state: string?, goAt: number?, endAt: number?)
	local a = PortalQueueRules.arch(q, trackId)
	local s = if state == "closed" then nil else state
	a.race = s
	a.raceGoAt = if s then goAt else nil
	a.raceEndAt = if s then endAt else nil
end

-- A race that is past its grid holds the arch: a lobby waits for it to end (or to replay onto a fresh grid).
function PortalQueueRules.blocked(a: Arch): boolean
	return a.race == "racing" or a.race == "results"
end

-- When the running race should free the arch (an estimate for the label), or nil when there is no race or the
-- estimate has passed (the label says "soon").
function PortalQueueRules.raceFreeAt(a: Arch, now: number): number?
	local r = a.race
	if r == nil then
		return nil
	end
	local at: number
	if r == "results" then
		at = a.raceEndAt or now
	else
		at = (a.raceGoAt or now) + PortalQueueRules.RACE_EST_SECONDS + PortalQueueRules.RESULTS_SECONDS
	end
	return if at > now then at else nil
end

-- The player's lobby (track id), or nil.
function PortalQueueRules.whereIs(q: Queue, userId: number): string?
	return q.where[userId]
end

function PortalQueueRules.count(a: Arch): number
	local l = a.lobby
	return if l then #l.order else 0
end

-- Takes a player out of his lobby. Returns the track id he left (nil: he was in none) and whether that lobby is now
-- empty (gone).
function PortalQueueRules.leave(q: Queue, userId: number): (string?, boolean)
	local trackId = q.where[userId]
	if not trackId then
		return nil, false
	end
	q.where[userId] = nil
	local a = q.arches[trackId]
	local l = a and a.lobby
	if not a or not l then
		return trackId, true
	end
	local i = table.find(l.order, userId)
	if i then
		table.remove(l.order, i)
	end
	l.members[userId] = nil
	if #l.order == 0 then
		a.lobby = nil
		return trackId, true
	end
	return trackId, false
end

-- A player drives through the arch (via "portal") or presses JOIN on the board (via "board"). Verdicts:
--   "open"    he opened this arch's lobby (OPEN -> FILLING);
--   "queued"  the arch is racing: he opened or joined the NEXT lobby;
--   "join"    he joined the lobby gathering here;
--   "already" he is in this lobby already (nothing changes);
--   "full"    the lobby holds cap players;
--   "mode"    the lobby here is for another mode (a board pick of BOSS while a RACE lobby gathers).
-- moved: the track id of the lobby he left to come here (a player is in one lobby at a time), or nil.
function PortalQueueRules.join(q: Queue, trackId: string, userId: number, mode: string, via: string, now: number): (string, string?)
	local a = PortalQueueRules.arch(q, trackId)
	local cur = q.where[userId]
	if cur == trackId and a.lobby then
		return "already", nil
	end
	local l = a.lobby
	if l then
		if l.mode ~= mode then
			return "mode", nil
		end
		if #l.order >= q.cap then
			return "full", nil
		end
	end
	local moved: string? = nil
	if cur then
		PortalQueueRules.leave(q, userId)
		moved = cur
	end
	local verdict = "join"
	if not l then
		l = { mode = mode, openedAt = now, goAt = now + q.seconds, order = {}, members = {} }
		a.lobby = l
		verdict = "open"
	end
	local lobby = l :: Lobby
	table.insert(lobby.order, userId)
	lobby.members[userId] = { via = via, at = now }
	q.where[userId] = trackId
	if a.race ~= nil then
		verdict = "queued"
	end
	return verdict, moved
end

-- When the lobby goes: its own goAt, or later while the race it queues behind still runs (max rule).
function PortalQueueRules.startAt(a: Arch, now: number): number?
	local l = a.lobby
	if not l then
		return nil
	end
	if not PortalQueueRules.blocked(a) then
		return l.goAt
	end
	local free = PortalQueueRules.raceFreeAt(a, now)
	return if free then math.max(l.goAt, free) else nil
end

-- True while the lobby's last `lead` seconds run and nothing holds it (the server sends the joined players' plunge).
function PortalQueueRules.goingIn(a: Arch, now: number, lead: number): boolean
	local l = a.lobby
	return l ~= nil and not PortalQueueRules.blocked(a) and now >= l.goAt - lead
end

-- The lobbies that go now: own timer done and the arch free. Each is taken off the queue (its players with it); the
-- caller seats them (only these players leave the hub).
function PortalQueueRules.due(q: Queue, now: number): { Due }
	local out: { Due } = {}
	local ids: { string } = {}
	for id in q.arches do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local a = q.arches[id]
		local l = a.lobby
		if l and now >= l.goAt and not PortalQueueRules.blocked(a) then
			a.lobby = nil
			for _, uid in l.order do
				if q.where[uid] == id then
					q.where[uid] = nil
				end
			end
			table.insert(out, { trackId = id, mode = l.mode, players = table.clone(l.order), members = l.members })
		end
	end
	return out
end

-- Drops a whole lobby (a Storm Cup hold, a refused start). Returns the players who were in it.
function PortalQueueRules.cancel(q: Queue, trackId: string): { number }
	local a = q.arches[trackId]
	local l = a and a.lobby
	if not a or not l then
		return {}
	end
	a.lobby = nil
	for _, uid in l.order do
		if q.where[uid] == trackId then
			q.where[uid] = nil
		end
	end
	return table.clone(l.order)
end

-- What an arch shows now (see the header). A race of this track in any state shows RACING (a crossing during its
-- grid already waits for the next lobby); t is when the next lobby goes (FILLING: its own countdown).
function PortalQueueRules.entry(q: Queue, a: Arch, now: number): Entry
	local l = a.lobby
	local n = PortalQueueRules.count(a)
	local mode = if l then l.mode else nil
	if a.race ~= nil then
		local t: number? = nil
		if l then
			t = PortalQueueRules.startAt(a, now)
			if t and not PortalQueueRules.blocked(a) then
				t = l.goAt
			end
		else
			t = PortalQueueRules.raceFreeAt(a, now)
		end
		return { s = "racing", t = t, n = n, c = q.cap, m = mode }
	end
	if l then
		return { s = "filling", t = l.goAt, n = n, c = q.cap, m = mode }
	end
	return { s = "open", t = nil, n = 0, c = q.cap, m = nil }
end

-- Every known arch, keyed by track id (the server JSON-encodes this into workspace ArchStates).
function PortalQueueRules.snapshot(q: Queue, now: number): { [string]: Entry }
	local out: { [string]: Entry } = {}
	for id, a in q.arches do
		out[id] = PortalQueueRules.entry(q, a, now)
	end
	return out
end

-- The single-race path (PER_GROUP false): one server-wide lobby; everyone present goes, so n is the humans present.
function PortalQueueRules.singleEntry(goAt: number, humans: number, cap: number, mode: string): Entry
	return { s = "filling", t = goAt, n = math.clamp(humans, 1, cap), c = cap, m = mode }
end

-- "0:14", "1:40": seconds left, rounded up, never negative.
function PortalQueueRules.clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- The spec row and its vars for an arch entry (nil: OPEN), now in server time. The client formats it with
-- NotifySpec.format; the arch label and the board row read the same text.
function PortalQueueRules.label(e: any, now: number): (string, { [string]: any })
	if type(e) ~= "table" or (e.s ~= "filling" and e.s ~= "racing") then
		return PortalQueueRules.ROW.open, {}
	end
	local n = if type(e.n) == "number" then e.n else 0
	local cap = if type(e.c) == "number" then e.c else 8
	local t = if type(e.t) == "number" and e.t > now then e.t else nil
	if e.s == "filling" and type(e.t) == "number" and e.t < now - 1 then
		return PortalQueueRules.ROW.open, {} -- the lobby went (a published entry the server has not cleared yet)
	end
	if e.s == "filling" then
		return PortalQueueRules.ROW.filling, { time = PortalQueueRules.clock(if t then t - now else 0), n = n, cap = cap }
	end
	if n > 0 then
		if t then
			return PortalQueueRules.ROW.queued, { time = PortalQueueRules.clock(t - now), n = n, cap = cap }
		end
		return PortalQueueRules.ROW.queuedSoon, { n = n, cap = cap }
	end
	if t then
		return PortalQueueRules.ROW.racing, { time = PortalQueueRules.clock(t - now) }
	end
	return PortalQueueRules.ROW.racingSoon, {}
end

-- The joined player's own HUD line ("Waiting for racers 0:14 - 3/8"): the spec row and vars, or nil when the entry
-- is gone. While the arch races, the line counts to the next race instead.
function PortalQueueRules.waitLine(e: any, now: number): (string?, { [string]: any })
	if type(e) ~= "table" or (e.s ~= "filling" and e.s ~= "racing") then
		return nil, {}
	end
	local n = if type(e.n) == "number" then e.n else 0
	local cap = if type(e.c) == "number" then e.c else 8
	local t = if type(e.t) == "number" and e.t > now then e.t else nil
	if e.s == "racing" and not t then
		return "portal_wait_soon", { n = n, cap = cap }
	end
	return "portal_wait_line", { time = PortalQueueRules.clock(if t then t - now else 0), n = n, cap = cap }
end

return PortalQueueRules
