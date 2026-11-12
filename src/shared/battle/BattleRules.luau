--!strict
-- Battle framework rules (LAUNCH_PROGRESSION section 2b; TEST_LIST_LAUNCH L71-L75). Pure data and pure functions: no
-- services, no instances, no yields, so the server (server/battle/BattleCore, BattleBots and every mode), the client HUD
-- and the Lune spec (tools/tests/battle_spec.luau) evaluate one rule set. Mode scoring lives beside this file
-- (SurvivalRules for lives; the egg, water and hoard rules in their own modules).
--
-- Arena data comes straight from TrackData.modes.battle (tools/map/adapt.py, from the plan's skyrally.gameplay.modes).
-- The plans name the bound differently (SNOW-1 `boundary` cylinder with a height, FOREST-1 `boundary` with floor and
-- ceiling, ISLAND-2 `softBoundary` with a softWidth), so arena() normalises them once:
--   radius        the play radius (`battle.radius`); past it the HUD warns "arena edge"
--   returnRadius  the boundary radius plus its soft band; a vehicle past it is put back on the nearest spawn pad
--   floor/ceiling world heights from the boundary (a cylinder `height` counts up from the boundary centre)
-- Numbers marked OURS are launch defaults (section 2b says the N64 battle values are unmeasured).

local BattleRules = {}

BattleRules.CAP_SECONDS = 180 -- section 2b: every battle mode resolves at three minutes
-- Owner 2026-10-21 ("it's got 3 people in it only"): battles fill to the race field (PlaneConfig.AI_FIELD_SIZE 8),
-- players plus bots; each human takes a bot's seat. A mode with fewer seats (egg: one nest per seat) caps it.
BattleRules.FIELD = 8
BattleRules.MAX_BOTS = 7
BattleRules.DEFAULT_LIVES = 3
BattleRules.SOFT_WIDTH = 30 -- OURS: band past the boundary when the plan gives none
BattleRules.POD_RESPAWN = 12 -- OURS seconds; a plan pickup may carry its own `respawn`
-- Section 4: battles use the level-one race set. Anchors without their own types cycle this list. The magnet is retired
-- (owner 2026-10-20; ItemRules.MAGNET_ENABLED): the Rainbow pod is out of the cycle, kept below for a return.
BattleRules.LEVEL_ONE_SET_WITH_MAGNET = table.freeze({ "Red", "Green", "Yellow", "Blue", "Rainbow" }) :: { string }
BattleRules.LEVEL_ONE_SET = table.freeze({ "Red", "Green", "Yellow", "Blue" }) :: { string }
BattleRules.SPAWN_RING = 0.6 -- OURS: seats past the plan's pads sit on a ring at this fraction of the play radius
BattleRules.EDGE_PULL = 0.8 -- OURS: bots start curving back toward the centre past this fraction of the play radius
-- Trap audit G6: the client's edge pull must start at least one turn radius inside the return line, so a vehicle flying
-- straight out can still turn round before it is put back. Cruise turn radii from the audit's flight and drive sims:
-- a plane at 121 studs/s and 75 deg/s yaw, a car at touch auto-gas.
BattleRules.PLANE_TURN_RADIUS = 93
BattleRules.CAR_TURN_RADIUS = 85
BattleRules.PULL_FRACTION = 0.9 -- the pull never starts later than this fraction of the play radius (the old rule)
BattleRules.CEILING_WARN = 30 -- OURS: a "TOO HIGH" warning and a nose-down pull this far under the ceiling (G6)
-- A respawn frame further than this outside the boundary band is not this arena's: a frame left over from the previous
-- map or mode (the stale hub frame seen in Studio), never somewhere to put a car or plane back.
BattleRules.STALE_MARGIN = 60

export type Arena = {
	center: Vector3,
	radius: number,
	returnRadius: number,
	floor: number,
	ceiling: number,
	spawns: { Vector3 },
	looks: { [number]: Vector3 }, -- authored seat headings (flat unit vectors) by seat, from the plan's spawnLooks
}

export type Zone = "inside" | "warn" | "out"

export type PodSpec = {
	pos: Vector3,
	podType: string, -- ItemRules PodType ("Red", "Green", ...)
	respawn: number,
}

export type Candidate = {
	id: string,
	pos: Vector3,
}

-- What a bot knows when it decides whether to fire the item it holds (decideItem).
export type ItemSense = {
	targetDist: number?, -- studs to the opponent it is chasing
	targetDot: number?, -- its forward vector dotted with the unit direction to that opponent
	behindDist: number?, -- studs to the nearest opponent behind it (dot < -0.3)
	threatDist: number?, -- studs to the nearest opponent holding a missile
	heldFor: number, -- seconds since it picked the item up
	magnetRange: number?,
	-- Trap audit X-01: false when the world stands between the bot and that opponent (one ray, BattleBots); nil when
	-- not measured (counts as clear).
	clearShot: boolean?,
	-- Trap audit G2: true while that opponent's respawn protection runs (a missile would only pop on the bubble).
	targetProtected: boolean?,
}

local function num(v: any): number?
	return if type(v) == "number" and v == v then v else nil
end

local function vec(v: any): Vector3?
	return if typeof(v) == "Vector3" then v else nil
end

function BattleRules.horizontal(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Normalised arena from TrackData.modes.battle, or nil when the block is missing or has no centre/radius.
function BattleRules.arena(battle: any): Arena?
	if type(battle) ~= "table" then
		return nil
	end
	local bound: any = if type(battle.boundary) == "table"
		then battle.boundary
		elseif type(battle.softBoundary) == "table" then battle.softBoundary
		else {}
	local center = vec(battle.center) or vec(bound.center)
	local radius = num(battle.radius) or num(bound.radius)
	if not center or not radius or radius <= 0 then
		return nil
	end
	local boundRadius = math.max(num(bound.radius) or radius, radius)
	local soft = num(bound.softWidth) or (if boundRadius > radius then 0 else BattleRules.SOFT_WIDTH)
	local ceiling = num(bound.ceiling)
	if not ceiling then
		local height = num(bound.height)
		local base = vec(bound.center) or center
		ceiling = if height then base.Y + height else math.huge
	end
	local spawns: { Vector3 } = {}
	local looks: { [number]: Vector3 } = {}
	local authored = if type(battle.spawnLooks) == "table" then battle.spawnLooks else {}
	if type(battle.spawns) == "table" then
		for i, s in battle.spawns do
			local v = vec(s) or (if type(s) == "table" then vec(s.pos) else nil)
			if v then
				table.insert(spawns, v)
				-- ISLAND-2 authors a heading per pad (trap audit I2-02 / I2-04: down the gangway, along the crest), checked
				-- clear of walls by the map tests; a pad without one faces the arena centre as before.
				local look = vec(authored[i]) or (if type(s) == "table" then vec(s.look) else nil)
				local flatLook = if look then Vector3.new(look.X, 0, look.Z) else nil
				if flatLook and flatLook.Magnitude > 0.01 then
					looks[#spawns] = flatLook.Unit
				end
			end
		end
	end
	return {
		center = center,
		radius = radius,
		returnRadius = boundRadius + soft,
		floor = num(bound.floor) or -math.huge,
		ceiling = ceiling :: number,
		spawns = spawns,
		looks = looks,
	}
end

-- Where the client's edge pull starts for a vehicle (workspace BattlePullStart, trap audit G6): one turn radius inside
-- the return line, or the old 90 % of the play radius when that leaves a wider band.
function BattleRules.pullStart(arena: Arena, vehicle: string): number
	local turn = if vehicle == "car" then BattleRules.CAR_TURN_RADIUS else BattleRules.PLANE_TURN_RADIUS
	return math.max(0, math.min(arena.radius * BattleRules.PULL_FRACTION, arena.returnRadius - turn))
end

-- In the vertical warn band under the ceiling (a "TOO HIGH" toast and the client's nose-down pull), not yet out.
function BattleRules.tooHigh(arena: Arena, pos: Vector3): boolean
	return arena.ceiling < math.huge and pos.Y > arena.ceiling - BattleRules.CEILING_WARN and pos.Y <= arena.ceiling
end

-- Whether a respawn frame's position belongs to this arena: inside the boundary band (plus STALE_MARGIN) and between
-- floor and ceiling (with the same margin). A frame from the previous map fails it.
function BattleRules.ownsFrame(arena: Arena, pos: Vector3): boolean
	local m = BattleRules.STALE_MARGIN
	if pos.Y > arena.ceiling + m or pos.Y < arena.floor - m then
		return false
	end
	return BattleRules.horizontal(pos, arena.center) <= arena.returnRadius + m
end

-- "inside" the play radius, "warn" in the band up to returnRadius, "out" past it or above/below the bound.
function BattleRules.zoneOf(arena: Arena, pos: Vector3): Zone
	if pos.Y > arena.ceiling or pos.Y < arena.floor then
		return "out"
	end
	local d = BattleRules.horizontal(pos, arena.center)
	if d > arena.returnRadius then
		return "out"
	elseif d > arena.radius then
		return "warn"
	end
	return "inside"
end

function BattleRules.nearestIndex(points: { Vector3 }, pos: Vector3, taken: { [number]: boolean }?): number?
	local best: number? = nil
	local bestD = math.huge
	for i, p in points do
		if not (taken and taken[i]) then
			local d = (p - pos).Magnitude
			if d < bestD then
				best, bestD = i, d
			end
		end
	end
	return best
end

-- Seat `slot` (1-based): the plan's spawn pads first, then ring seats inside the play radius between the pads. Ring
-- seats (a fifth player, a spectator joining mid-battle with a later FlightServer slot) sit at the pads' mean height:
-- the arena centre can be far below the field (FOREST-1: centre Y 63.5, pads Y 93-102) and would seat them underground.
function BattleRules.spawnPosition(arena: Arena, slot: number): Vector3
	local pad = arena.spawns[slot]
	if pad then
		return pad
	end
	local n = #arena.spawns
	local y = arena.center.Y
	if n > 0 then
		local sum = 0
		for _, s in arena.spawns do
			sum += s.Y
		end
		y = sum / n
	end
	local k = slot - n
	local a = (k - 0.5) / 8 * 2 * math.pi
	local r = arena.radius * BattleRules.SPAWN_RING
	return Vector3.new(arena.center.X + math.cos(a) * r, y, arena.center.Z + math.sin(a) * r)
end

-- Spawn frame for a seat: level, along the pad's authored heading when the plan gives one, else facing the arena centre.
function BattleRules.spawnCFrame(arena: Arena, slot: number): CFrame
	local p = BattleRules.spawnPosition(arena, slot)
	local authored = arena.looks and arena.looks[slot]
	if authored then
		return CFrame.lookAt(p, p + authored)
	end
	local look = Vector3.new(arena.center.X, p.Y, arena.center.Z)
	if (look - p).Magnitude < 1 then
		look = p + Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(p, look)
end

-- Players take the pad nearest where they stand (their start frame, so a player keeps the seat the spawn gave them),
-- in input order; bots take the free pads in order, then ring seats. Returns player slots (input order) and bot slots.
function BattleRules.assignSlots(arena: Arena, playerPositions: { Vector3 }, botCount: number): ({ number }, { number })
	local taken: { [number]: boolean } = {}
	local playerSlots: { number } = {}
	local nextRing = #arena.spawns + 1
	for _, pos in playerPositions do
		local i = BattleRules.nearestIndex(arena.spawns, pos, taken)
		if i then
			taken[i] = true
			table.insert(playerSlots, i)
		else
			table.insert(playerSlots, nextRing)
			nextRing += 1
		end
	end
	local botSlots: { number } = {}
	for i = 1, #arena.spawns do
		if #botSlots >= botCount then
			break
		end
		if not taken[i] then
			taken[i] = true
			table.insert(botSlots, i)
		end
	end
	while #botSlots < botCount do
		table.insert(botSlots, nextRing)
		nextRing += 1
	end
	return playerSlots, botSlots
end

-- Who gets a seat when a mode has fewer seats than humans (egg: one nest per seat; L71, L75, L30). Players who sat out
-- the last round (`waiting`, by UserId) come first so FLY AGAIN rotates them in; the rest go by UserId. cap < 0 = no limit.
function BattleRules.splitSeats(userIds: { number }, waiting: { [number]: boolean }, cap: number): ({ number }, { number })
	local order = table.clone(userIds)
	table.sort(order, function(x: number, y: number): boolean
		local wx, wy = waiting[x] == true, waiting[y] == true
		if wx ~= wy then
			return wx
		end
		return x < y
	end)
	local seated: { number } = {}
	local overflow: { number } = {}
	for _, id in order do
		if cap < 0 or #seated < cap then
			table.insert(seated, id)
		else
			table.insert(overflow, id)
		end
	end
	return seated, overflow
end

-- Bots fill the field to FIELD entrants (never more than MAX_BOTS); with no player the field still gets seven.
-- `seats`: the mode's seat count when it has one (Mode.capacity: egg has one nest per seat); the field never outgrows
-- it, so no bot is seated without a nest. nil or < 1 = no mode limit.
function BattleRules.fieldSize(seats: number?): number
	if seats and seats >= 1 then
		return math.min(BattleRules.FIELD, seats)
	end
	return BattleRules.FIELD
end

function BattleRules.botCount(players: number, seats: number?): number
	return math.clamp(BattleRules.fieldSize(seats) - math.max(players, 1), 0, BattleRules.MAX_BOTS)
end

function BattleRules.timeLeft(endsAt: number, now: number): number
	return math.max(0, endsAt - now)
end

-- "2:59" for the HUD timer.
function BattleRules.formatClock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- Stable ranking: ids sorted with better(a, b) (true when a ranks above b); ties keep the input order.
function BattleRules.rankIds(ids: { string }, better: (string, string) -> boolean): { string }
	local index: { [string]: number } = {}
	for i, id in ids do
		index[id] = i
	end
	local out = table.clone(ids)
	table.sort(out, function(a: string, b: string): boolean
		if better(a, b) then
			return true
		elseif better(b, a) then
			return false
		end
		return index[a] < index[b]
	end)
	return out
end

-- Battle item targeting (race order means nothing in an arena): the nearest other candidate, optionally only inside a
-- forward cone (dot of `forward` with the unit direction >= minDot) and within maxRange. Returns id and distance.
function BattleRules.nearestOpponent(
	selfId: string,
	selfPos: Vector3,
	candidates: { Candidate },
	forward: Vector3?,
	minDot: number?,
	maxRange: number?
): (string?, number)
	local best: string? = nil
	local bestD = maxRange or math.huge
	for _, c in candidates do
		if c.id ~= selfId then
			local to = c.pos - selfPos
			local d = to.Magnitude
			if d <= bestD then
				local inCone = true
				if forward and minDot and d > 0.01 and forward.Magnitude > 0.01 then
					inCone = forward.Unit:Dot(to / d) >= minDot
				end
				if inCone then
					best, bestD = c.id, d
				end
			end
		end
	end
	return best, if best then bestD else math.huge
end

-- Rotates unit vector `from` toward `to` by at most maxAngle radians (exact slerp; the opposite case turns about a
-- horizontal perpendicular, so a bot reversing course swings round instead of flipping).
function BattleRules.turnToward(from: Vector3, to: Vector3, maxAngle: number): Vector3
	if from.Magnitude < 1e-6 then
		return if to.Magnitude > 1e-6 then to.Unit else Vector3.new(0, 0, -1)
	end
	if to.Magnitude < 1e-6 then
		return from.Unit
	end
	local f, t = from.Unit, to.Unit
	local angle = math.acos(math.clamp(f:Dot(t), -1, 1))
	if angle <= maxAngle or angle < 1e-5 then
		return t
	end
	if angle > math.pi - 1e-3 then
		local axis = f:Cross(Vector3.new(0, 1, 0))
		if axis.Magnitude < 1e-3 then
			axis = f:Cross(Vector3.new(1, 0, 0))
		end
		local k = axis.Unit
		return (f * math.cos(maxAngle) + k:Cross(f) * math.sin(maxAngle)).Unit
	end
	local s = maxAngle / angle
	return ((f * math.sin((1 - s) * angle) + t * math.sin(s * angle)) / math.sin(angle)).Unit
end

-- Desired travel direction for an arena bot (unit vector): seek `goal`; past EDGE_PULL of the play radius a pull
-- toward the centre grows until it outweighs any goal outside the radius; neighbours closer than `separation` push it
-- away; near the ceiling it levels off downward. `flat` (cars) keeps the result horizontal.
function BattleRules.steerDirection(
	pos: Vector3,
	goal: Vector3,
	arena: Arena,
	neighbours: { Vector3 },
	separation: number,
	flat: boolean
): Vector3
	local seek = goal - pos
	if flat then
		seek = Vector3.new(seek.X, 0, seek.Z)
	end
	local dir = if seek.Magnitude > 0.01 then seek.Unit else Vector3.new(0, 0, 0)
	local d = BattleRules.horizontal(pos, arena.center)
	local edge = arena.radius * BattleRules.EDGE_PULL
	local inward = Vector3.new(arena.center.X - pos.X, 0, arena.center.Z - pos.Z)
	if d > edge and inward.Magnitude > 0.01 then
		local w = math.clamp((d - edge) / math.max(arena.radius - edge, 1), 0, 1.5) * 2
		dir += inward.Unit * w
	end
	for _, n in neighbours do
		local away = pos - n
		if flat then
			away = Vector3.new(away.X, 0, away.Z)
		end
		local m = away.Magnitude
		if m > 0.01 and m < separation then
			dir += away.Unit * (1 - m / separation) * 1.5
		end
	end
	if not flat and arena.ceiling < math.huge and pos.Y > arena.ceiling - 12 then
		dir += Vector3.new(0, -1, 0)
	end
	if flat then
		dir = Vector3.new(dir.X, 0, dir.Z)
	end
	if dir.Magnitude < 0.01 then
		return if inward.Magnitude > 0.01 then inward.Unit else Vector3.new(0, 0, -1)
	end
	return dir.Unit
end

-- Whether a bot fires what it holds now, and why (log line). Kinds as ItemRules.KIND_OF. OURS thresholds.
function BattleRules.decideItem(kind: string, s: ItemSense): (boolean, string)
	local dist, dot = s.targetDist, s.targetDot
	if kind == "missile" then
		-- Missiles stop at walls and pop on respawn bubbles: a bot holds fire until it can see a target it can hurt.
		if s.clearShot == false then
			return false, "no line of sight"
		elseif s.targetProtected == true then
			return false, "target protected"
		end
		if dist and dot and dist <= 220 and dot >= 0.85 then
			return true, "aimed"
		elseif dist and dot and s.heldFor > 9 and dist <= 320 and dot >= 0.6 then
			return true, "impatient"
		end
		return false, "no shot"
	elseif kind == "trap" then
		if s.behindDist and s.behindDist <= 70 then
			return true, "chaser"
		elseif s.heldFor > 7 then
			return true, "drop"
		end
		return false, "hold"
	elseif kind == "shield" then
		if s.threatDist and s.threatDist <= 140 then
			return true, "threat"
		elseif s.heldFor > 10 then
			return true, "idle"
		end
		return false, "hold"
	elseif kind == "horn" then
		-- v38: the horn (yellow) clears a shot about to land and spins a rival alongside.
		if (s.threatDist and s.threatDist <= 60) or (dist and dist <= 22) then
			return true, "horn"
		elseif s.heldFor > 10 then
			return true, "idle"
		end
		return false, "hold"
	elseif kind == "boost" then
		if dist and dot and dist > 150 and dot >= 0.7 then
			return true, "chase"
		elseif s.heldFor > 6 then
			return true, "idle"
		end
		return false, "hold"
	elseif kind == "magnet" then
		local range = s.magnetRange or 250
		if dist and dist <= range and dist > 60 then
			return true, "pull"
		end
		return false, "out of range"
	end
	return false, "unknown"
end

-- Item pods for the arena from the plan: SNOW-style `pickups` ({pos, types, respawn}) first, else `pickupAnchors`
-- (plain positions) cycling `types` (default LEVEL_ONE_SET). A mode may pass its own types or skip anchors entirely.
function BattleRules.podSpecs(battle: any, types: { string }?): { PodSpec }
	local out: { PodSpec } = {}
	if type(battle) ~= "table" then
		return out
	end
	local cycle = if types and #types > 0 then types else BattleRules.LEVEL_ONE_SET
	if type(battle.pickups) == "table" and #battle.pickups > 0 then
		for i, p in battle.pickups do
			local pos = if type(p) == "table" then vec(p.pos) else vec(p)
			if pos then
				local list = if type(p) == "table" and type(p.types) == "table" and #p.types > 0 then p.types else cycle
				local podType = list[((i - 1) % #list) + 1]
				table.insert(out, {
					pos = pos,
					podType = if type(podType) == "string" then podType else "Red",
					respawn = (if type(p) == "table" then num(p.respawn) else nil) or BattleRules.POD_RESPAWN,
				})
			end
		end
	elseif type(battle.pickupAnchors) == "table" then
		for i, a in battle.pickupAnchors do
			local pos = vec(a)
			if pos then
				table.insert(out, { pos = pos, podType = cycle[((i - 1) % #cycle) + 1], respawn = BattleRules.POD_RESPAWN })
			end
		end
	end
	return out
end

return BattleRules
