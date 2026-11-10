--!strict
-- Per-group races on one server (economy v3 phase 2, docs/design/PER_GROUP_RACES.md, Option A in
-- docs/design/ECONOMY_V3_PLAN.md). Pure: no Instances, no clock, specced in tools/tests/race_instance_spec.luau.
-- Shared by server/RaceInstance (the object a group's race lives in), server/TrackDirector (what a load keeps),
-- server/RaceManager (bots per field) and client/ZoneLighting (which zone the local player is in).
--
-- Everything here is inert while RaceFlowRules.PER_GROUP is false: the single-race path reads and writes the old
-- workspace attributes, destroys the old map on a load and counts every player on the server as the field, exactly as
-- before this module existed.
local RaceInstanceRules = {}

-- Lifecycle of one group's race. loading: the map is building or restoring; grid: players seated, 3-2-1 running;
-- racing: GO passed; results: every racer is done (the finish card and votes); closed: the instance is gone (its
-- players are back in the hub). Any state may close (a failed load, everyone left).
export type State = "loading" | "grid" | "racing" | "results" | "closed"

RaceInstanceRules.NEXT = {
	loading = { grid = true, closed = true },
	grid = { racing = true, closed = true },
	racing = { results = true, closed = true },
	-- FLY AGAIN on the same map: results go back to the grid without a rebuild.
	results = { grid = true, closed = true },
	closed = {},
} :: { [string]: { [string]: boolean } }

export type RaceInst = {
	id: number,
	key: string, -- the TrackData key ("snow1")
	trackId: string, -- "SNOW-1"
	zone: string, -- "SNOW"
	mode: string, -- "race", "boss", ...
	field: number, -- entrants per race (humans + bots)
	state: State,
	seq: number, -- race resets in this instance (the per-instance RaceResetSeq)
	humans: { [number]: boolean }, -- UserId set
	count: number,
	attrs: { [string]: any }, -- the shimmed attributes this instance publishes on its root
}

function RaceInstanceRules.new(id: number, key: string, trackId: string, zone: string, mode: string, field: number): RaceInst
	return {
		id = id,
		key = key,
		trackId = trackId,
		zone = zone,
		mode = mode,
		field = math.max(1, math.floor(field)),
		state = "loading",
		seq = 0,
		humans = {},
		count = 0,
		attrs = {},
	}
end

function RaceInstanceRules.canTransition(from: string, to: string): boolean
	local row = RaceInstanceRules.NEXT[from]
	return row ~= nil and row[to] == true
end

-- Moves the instance on; false (and no change) for a step the lifecycle does not have. Entering the grid starts a new
-- race in this instance (seq + 1).
function RaceInstanceRules.transition(inst: RaceInst, to: State): boolean
	if not RaceInstanceRules.canTransition(inst.state, to) then
		return false
	end
	inst.state = to
	if to == "grid" then
		inst.seq += 1
	end
	return true
end

-- A human may enter while the map loads or the grid forms, never mid-race (that is the next lobby, phase 3), and
-- never past the field. Joining twice is a no-op that still answers true.
function RaceInstanceRules.join(inst: RaceInst, userId: number): boolean
	if inst.humans[userId] then
		return true
	end
	if inst.state ~= "loading" and inst.state ~= "grid" then
		return false
	end
	if inst.count >= inst.field then
		return false
	end
	inst.humans[userId] = true
	inst.count += 1
	return true
end

function RaceInstanceRules.leave(inst: RaceInst, userId: number): boolean
	if not inst.humans[userId] then
		return false
	end
	inst.humans[userId] = nil
	inst.count -= 1
	return true
end

-- An instance with nobody left in it closes (its map may stay cached, the race does not).
function RaceInstanceRules.empty(inst: RaceInst): boolean
	return inst.count <= 0
end

-- Bots one field needs: the field size minus the humans IN THAT FIELD (at least one seat is a human's, so a solo race
-- and an empty field both get field - 1), never more than the roster holds. Same arithmetic as AIRacers.botsNeeded.
function RaceInstanceRules.botsNeeded(humansInField: number, field: number, roster: number): number
	return math.clamp(field - math.max(humansInField, 1), 0, math.max(roster, 0))
end

-- How many humans a race reset counts for its bots. The single-race path keeps counting every player on the server
-- (RaceManager before phase 2, byte for byte); per group, only the humans seated in that field.
function RaceInstanceRules.fieldHumans(perGroup: boolean, serverPlayers: number, seatedHumans: number): number
	return if perGroup then seatedHumans else serverPlayers
end

------------------------------------------------------------------------------------------------------------------
-- Attribute shim. These workspace attributes describe "the" race today; per group each instance publishes them on its
-- own root instead, and a reader that knows its instance asks the root. The old workspace attributes stay the source
-- on the single-race path (plan sub-step a: old attributes kept).

RaceInstanceRules.SHIMMED = {
	RaceMode = true,
	ActiveTrackId = true,
	ActiveZone = true,
	CurrentTrackKey = true,
	RaceGoTime = true,
	RaceResetSeq = true,
	RaceStartCF = true,
	TotalLaps = true,
	ReturnToHubAt = true,
	DnfAt = true,
	-- Phase 2b: what a racer's HUD and finish card read per race (position N of M, checkpoints, the vote line), the
	-- race's vehicle and the per-track bot pace.
	TotalRacers = true,
	TotalCheckpoints = true,
	VoteHumans = true,
	VotesAgain = true,
	VotesHub = true,
	ActiveVehicle = true,
	BotPace = true,
	-- Items v4: the race's item rotation pool (ItemRules.ROTATION.poolAttribute).
	ItemPool = true,
	-- Systems audit v32 T0-2 (per-group mode systems, shared/ModeScopeRules): the coin challenge's coin count and the
	-- battle overlay's arena, phase, clock and board are the race's own, so two groups' coins and battles never mix.
	CoinsTotal = true,
	BattleKind = true,
	BattleTitle = true,
	BattleState = true,
	BattleEndsAt = true,
	BattleBoard = true,
	BattleZone = true,
	BattleCenter = true,
	BattleRadius = true,
	BattleReturnRadius = true,
	BattlePullStart = true,
	BattleCeiling = true,
} :: { [string]: boolean }

function RaceInstanceRules.shimmed(name: string): boolean
	return RaceInstanceRules.SHIMMED[name] == true
end

-- Reads one race attribute. rootGet is the instance root's getter (nil when the reader has no instance: the hub, a
-- player between races); worldGet reads workspace. Per group, a shimmed name on a known instance comes from its root
-- only (another group's race must never leak in through workspace); anything else reads workspace as before.
function RaceInstanceRules.read(name: string, perGroup: boolean, rootGet: ((string) -> any)?, worldGet: (string) -> any): any
	if perGroup and rootGet and RaceInstanceRules.shimmed(name) then
		return rootGet(name)
	end
	return worldGet(name)
end

-- Where a write of this attribute goes: "world" (workspace, the single-race path and every unshimmed name) or "root"
-- (the instance root, per group).
function RaceInstanceRules.writeTarget(name: string, perGroup: boolean): string
	return if perGroup and RaceInstanceRules.shimmed(name) then "root" else "world"
end

------------------------------------------------------------------------------------------------------------------
-- What a map load keeps (plan sub-step b). Single race: every map under workspace.Maps goes and Terrain is cleared
-- (except on the boot load, which has nothing to clear). Per group: other zones' maps and Terrain stay (every zone sits
-- at its own coordinates); only a stale copy of the map being loaded is replaced.

function RaceInstanceRules.keepMap(perGroup: boolean, childKey: string?, loadingKey: string, loadingTrackId: string?): boolean
	if not perGroup then
		return false
	end
	return childKey ~= loadingKey and (loadingTrackId == nil or childKey ~= loadingTrackId)
end

function RaceInstanceRules.clearTerrain(perGroup: boolean, first: boolean): boolean
	return not perGroup and not first
end

-- A plan's "Clear" shell op (DINO-4's plan opens with one: build/dino4/TrackData.luau shells[1]) ran
-- workspace.Terrain:Clear() inside MapAdapter.build. Single race that is harmless (TrackDirector.load cleared Terrain
-- already). Per group the hub's baked plaza shares that Terrain, so the first DINO-4 group build wiped it on server and
-- clients: back on the plaza every car fell through (Studio V6 on b05b627, reason=Fell, killY -54.2). Per group the op
-- now touches only the map's own terrain box:
--   "all"    single race: Terrain:Clear(), exactly as before.
--   "skip"   per group, the first write of this map on this server (its box is still empty: every zone sits at its own
--            coordinates), no known box, or a box that overlaps terrain another map wrote (never touch the hub).
--   "region" per group, a rebuild of a map whose terrain is already there (a cache miss: MapCacheOff, an eviction, a
--            failed paste): Air over its own box only, in chunks (clearChunks).
-- box: the map's MapCacheRules.terrainBox (lo/hi in studs); others: the box of every other map that wrote terrain on
-- this server (per group a closed group's terrain stays, so "others" is not only the live maps).
export type TerrainBox = { lo: Vector3, hi: Vector3, empty: boolean? }

function RaceInstanceRules.boxesOverlap(a: TerrainBox, b: TerrainBox): boolean
	if a.empty or b.empty then
		return false
	end
	return a.lo.X < b.hi.X and b.lo.X < a.hi.X and a.lo.Y < b.hi.Y and b.lo.Y < a.hi.Y and a.lo.Z < b.hi.Z and b.lo.Z < a.hi.Z
end

function RaceInstanceRules.shellClear(perGroup: boolean, wroteBefore: boolean, box: TerrainBox?, others: { TerrainBox }): string
	if not perGroup then
		return "all"
	end
	if not wroteBefore or box == nil or box.empty then
		return "skip"
	end
	for _, o in others do
		if RaceInstanceRules.boxesOverlap(box, o) then
			return "skip"
		end
	end
	return "region"
end

-- One map load's decision over the server's ledger of terrain writers (TrackDirector keeps `written`, track id ->
-- box): shellClear for `id` against every other writer, then `id` is recorded (a nil box records an empty one, so a
-- later load still counts as a rewrite but never region-clears an unknown box). A single-race Terrain:Clear() empties
-- the ledger (TrackDirector.load).
function RaceInstanceRules.planShellClear(perGroup: boolean, written: { [string]: TerrainBox }, id: string, box: TerrainBox?): string
	local others = {}
	for k, b in written do
		if k ~= id then
			table.insert(others, b)
		end
	end
	local mode = RaceInstanceRules.shellClear(perGroup, written[id] ~= nil, box, others)
	written[id] = box or { lo = Vector3.zero, hi = Vector3.zero, empty = true }
	return mode
end

RaceInstanceRules.CLEAR_CHUNK = 512 -- studs per edge of one Air FillBlock in a region clear (128 voxels)

-- The box split into blocks no wider than `edge` studs on any axis that tile it exactly (no gap, no overlap, nothing
-- outside it). Empty for an empty or degenerate box.
function RaceInstanceRules.clearChunks(box: TerrainBox, edge: number?): { { lo: Vector3, hi: Vector3 } }
	local e = edge or RaceInstanceRules.CLEAR_CHUNK
	local out = {}
	if box.empty or e <= 0 then
		return out
	end
	local lo, hi = box.lo, box.hi
	if hi.X <= lo.X or hi.Y <= lo.Y or hi.Z <= lo.Z then
		return out
	end
	local x = lo.X
	while x < hi.X do
		local x2 = math.min(x + e, hi.X)
		local y = lo.Y
		while y < hi.Y do
			local y2 = math.min(y + e, hi.Y)
			local z = lo.Z
			while z < hi.Z do
				local z2 = math.min(z + e, hi.Z)
				table.insert(out, { lo = Vector3.new(x, y, z), hi = Vector3.new(x2, y2, z2) })
				z = z2
			end
			y = y2
		end
		x = x2
	end
	return out
end

-- Lighting, Sky, Atmosphere, MaterialService overrides and water are one global set per client. Single race: the server
-- writes them for the loaded map (MapAdapter), as before. Per group: the server leaves them alone and each client
-- applies its own zone's set (client/ZoneLighting).
function RaceInstanceRules.serverWritesLighting(perGroup: boolean): boolean
	return not perGroup
end

------------------------------------------------------------------------------------------------------------------
-- Zone boxes on the XZ plane (every zone map sits at disjoint coordinates; height never decides the zone, so a plane
-- climbing above its terrain stays in its zone).

export type Box = { zone: string, profile: string, minX: number, minZ: number, maxX: number, maxZ: number }

RaceInstanceRules.ZONE_PAD = 300 -- studs around a route's waypoints when the plan has no terrain bounds (DINO-4)

-- A zone's box from its TrackData: terrainBounds when present, grown to cover every waypoint plus ZONE_PAD (planes
-- leave the terrain). nil when the plan has neither.
function RaceInstanceRules.zoneBox(td: any): Box?
	if type(td) ~= "table" or type(td.zone) ~= "string" then
		return nil
	end
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	local tb = td.terrainBounds
	if type(tb) == "table" and typeof(tb.min) == "Vector3" and typeof(tb.max) == "Vector3" then
		minX, minZ = math.min(tb.min.X, tb.max.X), math.min(tb.min.Z, tb.max.Z)
		maxX, maxZ = math.max(tb.min.X, tb.max.X), math.max(tb.min.Z, tb.max.Z)
	end
	local pad = RaceInstanceRules.ZONE_PAD
	for _, w in (if type(td.waypoints) == "table" then td.waypoints else {}) :: { any } do
		local p = if type(w) == "table" then w.pos else nil
		if typeof(p) == "Vector3" then
			minX, minZ = math.min(minX, p.X - pad), math.min(minZ, p.Z - pad)
			maxX, maxZ = math.max(maxX, p.X + pad), math.max(maxZ, p.Z + pad)
		end
	end
	if minX > maxX then
		return nil
	end
	local profile = if type(td.lighting) == "string" then td.lighting else (if type(td.id) == "string" then td.id else td.zone)
	return { zone = td.zone, profile = profile, minX = minX, minZ = minZ, maxX = maxX, maxZ = maxZ }
end

local function inside(b: Box, x: number, z: number): boolean
	return x >= b.minX and x <= b.maxX and z >= b.minZ and z <= b.maxZ
end

-- The zone box a position is in. Boxes should not overlap; if they do, the smaller box wins (a zone set inside a larger
-- one). Outside every box the current zone holds (no flicker between maps, nothing applied over open sky).
function RaceInstanceRules.zoneAt(pos: Vector3, boxes: { Box }, current: Box?): Box?
	local best: Box? = nil
	local bestArea = math.huge
	for _, b in boxes do
		if inside(b, pos.X, pos.Z) then
			local area = (b.maxX - b.minX) * (b.maxZ - b.minZ)
			if area < bestArea then
				best, bestArea = b, area
			end
		end
	end
	return best or current
end

------------------------------------------------------------------------------------------------------------------
-- Phase 2b: the per-group engine (server/RaceGroups) and the client's map visibility (client/ZoneVisibility).

-- A group asks for a track. "open": no instance races there, start one. "join": an instance on that track still forms
-- its grid (loading or grid) and has a seat: the asker joins it (that is his choice: he drove through the arch or picked
-- the board). "busy": the instance on that track is racing, showing results or full: the asker waits for it (one map per
-- track, so two groups never share pods and checkpoints).
export type LiveInst = { trackId: string, state: string, count: number, field: number }

function RaceInstanceRules.admit(liveList: { LiveInst }, trackId: string): string
	for _, inst in liveList do
		if inst.trackId == trackId and inst.state ~= "closed" then
			if (inst.state == "loading" or inst.state == "grid") and inst.count < inst.field then
				return "join"
			end
			return "busy"
		end
	end
	return "open"
end

-- Modes a group may race in its own instance. The mode systems (BossRace hazards, CoinChallenge coins, KeyPickup,
-- DuckHunt, the galleon cannons, VolcanoVents, BattleCore) keep one state per RaceScope scope (shared/ModeScopeRules,
-- systems audit v32 T0-2), so a group's load or replay starts and stops only its own, and coin challenges, boss races
-- with their hazards and battles run per group. Storm Cup v1 takes the whole server by design: per group a storm is
-- storm race v2 ("stormrace", server/StormRace), so a "stormcup" pick is refused. ModeScopeRules.GROUP_MODES lists the
-- modes a group runs; tools/tests/per_group_modes_spec.luau keeps the two in step.
RaceInstanceRules.GROUP_REFUSED_MODES = { stormcup = true } :: { [string]: boolean }

function RaceInstanceRules.groupModeOk(mode: string): boolean
	return RaceInstanceRules.GROUP_REFUSED_MODES[mode] ~= true
end

-- Which map roots a client renders (by map name = track id). Single race: every map (there is only one). Per group:
-- the map of the player's own instance, or the hub while he is in none; every other zone's map is hidden on this client
-- only (server physics untouched). The hub also stays visible while the player's race map has not replicated yet or
-- his instance is still loading (he is still driving on the plaza until the grid seats him), so a seat change never
-- leaves him over nothing.
function RaceInstanceRules.visibleMaps(perGroup: boolean, myTrack: string?, hubTrack: string, mapIds: { string }, loading: boolean?): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if not perGroup then
		for _, id in mapIds do
			out[id] = true
		end
		return out
	end
	local have = myTrack ~= nil and table.find(mapIds, myTrack) ~= nil and loading ~= true
	for _, id in mapIds do
		if id == myTrack or (id == hubTrack and not have) then
			out[id] = true
		end
	end
	return out
end

-- Return to the hub for one instance: the seat is given up first (the client un-hides the hub), the respawn on the
-- plaza follows after RETURN_UNHIDE seconds, so the car never lands on a map the client still hides.
RaceInstanceRules.RETURN_UNHIDE = 0.4

return RaceInstanceRules
