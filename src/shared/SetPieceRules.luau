--!strict
-- Pure rules for the Batch 2 set pieces (docs/REMARKABLE.md items 13, 21, 22 and 25). No services, no Instances
-- beyond Vector3/CFrame values: the server (server/WorldSetPieces, server/DuckHunt), the clients (client/GalleonMoments,
-- BossRetirement, DuckMoments, MoonMonorail) and tools/tests/setpieces_spec.luau all read the same numbers.
-- * LAUNCHERS (item 13): the ISLAND-2 galleon cannons (CrestCannon on the beach crest fires a car back aboard,
--   DeckCannon on the forecastle fires it ashore onto sand above the last tide). A ride is load -> fuse -> a ballistic
--   arc -> set down. The server announces the landing once per trigger (CarServer.expectLaunch); the ride stays inside
--   the announced grace window. Only the names in LAUNCHER_NAMES exist.
-- * GULL (item 13): the Splashdown rescue reads a teleport out of the tide as "a gull plucked that car out".
-- * DUCKS (item 22): one Lost Squeaky Duck per launch map, on that map's alternate line; all six own the Golden Quack
--   horn (a progression reward like the Battle Amulet livery: never sold, never stocked).
-- * MONORAIL (item 25): the SPACE-4 Moon Monorail is a deterministic shuttle on the viaduct, driven by server time
--   (anchored to RaceGoTime while a race runs), and the race against it is judged on each client only.
-- * BOSSES (item 21): the defeat gag of each zone boss as keyframes in the frame of the winner's vehicle, and where a
--   retired boss hangs out in the hub.
local SetPieceRules = {}

local function smooth(x: number): number
	local t = math.clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
end
SetPieceRules.smooth = smooth

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unit(v: Vector3, fallback: Vector3): Vector3
	local m = v.Magnitude
	return if m > 1e-6 then v / m else fallback
end

---------------------------------------------------------------------------------------------------- launchers (13)

-- The only launchers the server accepts (plan modes.battle.launchers rows with any other name are ignored).
SetPieceRules.LAUNCHER_NAMES = table.freeze({ CrestCannon = true, DeckCannon = true }) :: { [string]: boolean }
SetPieceRules.TRIGGER_RADIUS = 6.5 -- horizontal reach from the cradle centre
SetPieceRules.TRIGGER_HEIGHT = 5 -- |hull y - cradle y| (the cradle sits at hull height over the floor)
SetPieceRules.TRIGGER_MIN_SPEED = 4 -- studs/s along the barrel's way in: a car must drive INTO the cannon
SetPieceRules.COOLDOWN = 4 -- seconds after a landing before the same player can be fired again
SetPieceRules.LOAD_TIME = 0.35 -- the car slides up into the breech
SetPieceRules.FUSE_TIME = 0.55 -- fuse fizz, barrel shiver
SetPieceRules.FLIGHT_TIME = 1.55 -- muzzle to the landing frame
SetPieceRules.LAND_SPEED = 16 -- studs/s the car keeps along landLook when it is set down
SetPieceRules.INSIDE = 4.5 -- how far up the bore the loaded car sits
SetPieceRules.GRACE_PAD = 1.0 -- network slack added to the ride for the validator's grace window
SetPieceRules.GRACE_MAX = 3.6 -- never a longer grace than this, whatever the data says
SetPieceRules.ROLLS = 1 -- full barrel rolls in the air (the car's own body; the camera keeps the horizon)
SetPieceRules.FINAL_TIDE_MARGIN = 0 -- a sand landing must be at least this far above the last tide level

export type Launcher = {
	name: string,
	cradle: Vector3, -- hull position that loads the cannon (the car's centre in the cradle)
	breech: Vector3, -- bore centre at the breech
	axis: Vector3, -- unit barrel axis (breech -> muzzle)
	length: number, -- barrel length
	land: Vector3, -- hull position where the car is set down
	landLook: Vector3, -- unit heading the car is set down with
	ground: number, -- surface y under `land`
	surface: string, -- "deck" | "sand"
}

-- One launcher row from plan data (modes.battle.launchers). Returns nil for an unknown name or malformed data.
function SetPieceRules.parseLauncher(row: any): Launcher?
	if type(row) ~= "table" or type(row.name) ~= "string" or not SetPieceRules.LAUNCHER_NAMES[row.name] then
		return nil
	end
	for _, k in { "cradle", "breech", "axis", "land", "landLook" } do
		if typeof(row[k]) ~= "Vector3" then
			return nil
		end
	end
	if type(row.length) ~= "number" or type(row.ground) ~= "number" then
		return nil
	end
	return {
		name = row.name,
		cradle = row.cradle,
		breech = row.breech,
		axis = unit(row.axis, Vector3.yAxis),
		length = row.length,
		land = row.land,
		landLook = unit(flat(row.landLook), Vector3.new(0, 0, -1)),
		ground = row.ground,
		surface = if row.surface == "deck" then "deck" else "sand",
	}
end

function SetPieceRules.muzzle(l: Launcher): Vector3
	return l.breech + l.axis * l.length
end

function SetPieceRules.rideTime(): number
	return SetPieceRules.LOAD_TIME + SetPieceRules.FUSE_TIME + SetPieceRules.FLIGHT_TIME
end

-- Grace window the server gives the one announced landing (CarServer.expectLaunch).
function SetPieceRules.graceSeconds(): number
	return math.min(SetPieceRules.rideTime() + SetPieceRules.GRACE_PAD, SetPieceRules.GRACE_MAX)
end

-- Height of the arc over the straight muzzle -> land line, chosen so the car leaves along the barrel:
-- p(u) = muzzle + (land - muzzle) u + up 4 H u (1 - u)  =>  p'(0) = d + up 4H, parallel to the axis.
function SetPieceRules.arcHeight(l: Launcher): number
	local m = SetPieceRules.muzzle(l)
	local d = l.land - m
	local dh = flat(d).Magnitude
	local ah = flat(l.axis).Magnitude
	local slope = if ah > 1e-4 then l.axis.Y / ah else 1
	return math.max(2, (dh * slope - d.Y) / 4)
end

-- Whether a hull position (and its velocity estimate) loads this cannon.
function SetPieceRules.inCradle(l: Launcher, pos: Vector3, vel: Vector3?): boolean
	local d = pos - l.cradle
	if flat(d).Magnitude > SetPieceRules.TRIGGER_RADIUS or math.abs(d.Y) > SetPieceRules.TRIGGER_HEIGHT then
		return false
	end
	if vel then
		local way = unit(flat(l.axis), Vector3.new(0, 0, -1))
		return flat(vel):Dot(way) >= SetPieceRules.TRIGGER_MIN_SPEED
	end
	return true
end

-- Per-player cooldown book: lastAt[key] = time the last ride for that player started.
export type Cooldowns = { [any]: number }

function SetPieceRules.canFire(book: Cooldowns, key: any, now: number): boolean
	local last = book[key]
	return last == nil or now - last >= SetPieceRules.rideTime() + SetPieceRules.COOLDOWN
end

function SetPieceRules.noteFire(book: Cooldowns, key: any, now: number)
	book[key] = now
end

local function lookUp(pos: Vector3, look: Vector3, up: Vector3): CFrame
	local z = -unit(look, Vector3.new(0, 0, -1))
	local x = unit(up:Cross(z), Vector3.xAxis)
	local y = z:Cross(x)
	return CFrame.fromMatrix(pos, x, y, z)
end
SetPieceRules.lookUp = lookUp

-- The hull frame `t` seconds into a ride that started at `start` (the hull frame when the cannon took the car).
-- Returns the frame and the phase ("load" | "fuse" | "flight" | "done"). Pure and continuous: load ends at the bore,
-- fuse holds there, the flight starts at the muzzle along the axis and ends exactly on the landing frame.
function SetPieceRules.rideFrame(l: Launcher, start: CFrame, t: number): (CFrame, string)
	local L, F, T = SetPieceRules.LOAD_TIME, SetPieceRules.FUSE_TIME, SetPieceRules.FLIGHT_TIME
	local barrelUp = unit(Vector3.yAxis - l.axis * l.axis.Y, Vector3.zAxis)
	local inside = l.breech + l.axis * SetPieceRules.INSIDE
	local seated = lookUp(inside, l.axis, barrelUp)
	if t < L then
		local k = smooth(t / L)
		return start:Lerp(seated, k), "load"
	elseif t < L + F then
		-- the barrel shivers with the fuse (a few tenths of a stud, faster as it burns down)
		local u = (t - L) / F
		local shake = 0.12 + 0.25 * u
		local o = Vector3.new(math.sin(t * 71) * shake, math.sin(t * 53 + 1) * shake * 0.6, 0)
		return seated * CFrame.new(o), "fuse"
	elseif t < L + F + T then
		local u = (t - L - F) / T
		local m = SetPieceRules.muzzle(l)
		local d = l.land - m
		local H = SetPieceRules.arcHeight(l)
		local pos = m + d * u + Vector3.yAxis * (4 * H * u * (1 - u))
		local vel = d + Vector3.yAxis * (4 * H * (1 - 2 * u))
		-- the nose follows the arc, levels out over the last fifth, and the body rolls ROLLS turns
		local level = smooth((u - 0.8) / 0.2)
		local look = unit(vel:Lerp(flat(l.landLook) * vel.Magnitude, level), l.landLook)
		local roll = 2 * math.pi * SetPieceRules.ROLLS * smooth(u / 0.85)
		local up = unit(Vector3.yAxis - look * look.Y, Vector3.yAxis)
		return lookUp(pos, look, up) * CFrame.Angles(0, 0, roll), "flight"
	end
	return lookUp(l.land, l.landLook, Vector3.yAxis), "done"
end

-- Data checks shared by the spec and the server (a launcher that fails is never armed).
function SetPieceRules.validateLauncher(l: Launcher, finalTide: number): (boolean, string?)
	if math.abs(l.axis.Magnitude - 1) > 1e-3 then
		return false, "axis not unit"
	end
	if l.axis.Y < 0.2 or l.axis.Y > 0.85 then
		return false, "barrel elevation out of range"
	end
	local way = unit(flat(l.axis), Vector3.zAxis)
	local toLand = unit(flat(l.land - SetPieceRules.muzzle(l)), Vector3.zAxis)
	if way:Dot(toLand) < 0.97 then
		return false, "barrel not aimed at the landing"
	end
	if l.surface == "sand" and l.ground < finalTide + SetPieceRules.FINAL_TIDE_MARGIN then
		return false, string.format("sand landing at %.2f is under the last tide %.2f", l.ground, finalTide)
	end
	if l.land.Y < l.ground then
		return false, "landing below its ground"
	end
	if (l.cradle - l.land).Magnitude < 3 * SetPieceRules.TRIGGER_RADIUS then
		return false, "landing inside its own cradle"
	end
	if SetPieceRules.graceSeconds() < SetPieceRules.rideTime() then
		return false, "ride longer than the grace window"
	end
	return true, nil
end

---------------------------------------------------------------------------------------------------- gull (13)

SetPieceRules.GULL_TELEPORT_MIN = 35 -- a jump this long in one look is a respawn, not driving
SetPieceRules.GULL_WET = 0.8 -- the car was in the tide: hull bottom less than this over the water (or under it)
SetPieceRules.GULL_DIVE = 0.45
SetPieceRules.GULL_CARRY = 0.95
SetPieceRules.GULL_DROP = 0.4
SetPieceRules.GULL_LOCAL = 1.1 -- the rescued player's own view: the gull lets go as the fade clears
SetPieceRules.GULL_RANGE = 520 -- clients farther than this from both ends skip it
-- Outside the water battle the gull also fishes cars out of the open sea on ISLAND-2 (map sea level, author_island2
-- ORIGIN y): a race respawn after a splash off the boardwalk or the bridge.
SetPieceRules.GULL_SEA = table.freeze({ ["ISLAND-2"] = 20.0 }) :: { [string]: number }

function SetPieceRules.gullTotal(): number
	return SetPieceRules.GULL_DIVE + SetPieceRules.GULL_CARRY + SetPieceRules.GULL_DROP
end

-- A hull that moved `from` -> `to` between two looks: was that a rescue out of the water?
function SetPieceRules.isWaterRescue(from: Vector3, to: Vector3, waterY: number?, rideHeight: number): boolean
	if not waterY or (to - from).Magnitude < SetPieceRules.GULL_TELEPORT_MIN then
		return false
	end
	return from.Y - rideHeight < waterY + SetPieceRules.GULL_WET and to.Y - rideHeight >= waterY - 0.5
end

-- Arc height of the carry, from the horizontal distance.
function SetPieceRules.gullArcHeight(from: Vector3, to: Vector3): number
	return math.clamp(14 + flat(to - from).Magnitude * 0.16, 14, 42)
end

-- Where the carried car hangs at carry progress u (0..1).
function SetPieceRules.gullCarry(from: Vector3, to: Vector3, u: number): Vector3
	local k = smooth(u)
	return from:Lerp(to, k) + Vector3.yAxis * (4 * SetPieceRules.gullArcHeight(from, to) * k * (1 - k))
end

-- Wing angle (radians, up positive) at time t: fast strokes while carrying, a lazy beat otherwise.
function SetPieceRules.gullFlap(t: number, carrying: boolean): number
	local hz = if carrying then 7 else 3.5
	return math.sin(t * hz * 2 * math.pi) * (if carrying then 0.75 else 0.5)
end

---------------------------------------------------------------------------------------------------- ducks (22)

SetPieceRules.DUCK_TRACKS = table.freeze({ "DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1", "SPACE-4", "HUB-0" }) :: { string }
SetPieceRules.GOLDEN_QUACK = "Horn_GoldenQuack"
-- Modes a duck sits in: never a battle or a boss race (a hunt is a free moment, not a duel).
SetPieceRules.DUCK_MODES = table.freeze({ race = true, quickrace = true, timetrial = true, coin = true, hub = true }) :: { [string]: boolean }
SetPieceRules.DUCK_RADIUS_CAR = 11
SetPieceRules.DUCK_RADIUS_PLANE = 15
SetPieceRules.DUCK_LIFT_PLANE = 0 -- plane alternates are flight lines: the duck floats on the line
SetPieceRules.DUCK_LIFT_CAR = 2.2 -- a car duck sits this far over the surface found under the line

-- Where each map's duck hides: along which alternate, at which fraction of its length (OURS; picked clear of the
-- hidden key, the coins and the hub finds by tools/map/tests/test_set_pieces.py).
SetPieceRules.DUCK_SPOTS = table.freeze({
	["DINO-4"] = { alt = "Alt2", t = 0.8, note = "near the end of the ledge shortcut (the hidden key sits mid-ledge)" },
	["SNOW-1"] = { alt = "Alt1", t = 0.5, note = "halfway down the ice tunnel" },
	["ISLAND-2"] = { alt = "Alt1", t = 0.3, note = "on the boardwalk over the shallows" },
	["FOREST-1"] = { alt = "Alt1", t = 0.45, note = "on the ledge line through the trees" },
	["SPACE-4"] = { alt = "Alt1", t = 0.55, note = "deep in the shortcut tube" },
	["HUB-0"] = { alt = "AltCove", t = 0.15, note = "at the start of the cove boardwalk, well before the hidden beach" },
}) :: { [string]: { alt: string, t: number, note: string } }

function SetPieceRules.isDuckTrack(id: any): boolean
	return type(id) == "string" and SetPieceRules.DUCK_SPOTS[id] ~= nil
end

-- Point at fraction t of a polyline's length.
function SetPieceRules.alongPolyline(points: { Vector3 }, t: number): Vector3?
	local n = #points
	if n == 0 then
		return nil
	elseif n == 1 then
		return points[1]
	end
	local total = 0
	for i = 1, n - 1 do
		total += (points[i + 1] - points[i]).Magnitude
	end
	local want = math.clamp(t, 0, 1) * total
	for i = 1, n - 1 do
		local seg = (points[i + 1] - points[i]).Magnitude
		if want <= seg or i == n - 1 then
			return points[i]:Lerp(points[i + 1], if seg > 0 then math.clamp(want / seg, 0, 1) else 0)
		end
		want -= seg
	end
	return points[n]
end

-- The duck anchor for a track from its TrackData alternates (nil: no duck on this load).
function SetPieceRules.duckAnchor(trackId: string, alternates: any): Vector3?
	local spot = SetPieceRules.DUCK_SPOTS[trackId]
	if not spot or type(alternates) ~= "table" then
		return nil
	end
	for _, alt in alternates do
		if type(alt) == "table" and alt.id == spot.alt and type(alt.points) == "table" then
			return SetPieceRules.alongPolyline(alt.points, spot.t)
		end
	end
	return nil
end

function SetPieceRules.duckEligible(trackId: any, mode: string): boolean
	return SetPieceRules.isDuckTrack(trackId) and SetPieceRules.DUCK_MODES[mode] == true
end

function SetPieceRules.duckCount(ducks: any): number
	local n = 0
	if type(ducks) == "table" then
		for _, id in SetPieceRules.DUCK_TRACKS do
			if ducks[id] == true then
				n += 1
			end
		end
	end
	return n
end

function SetPieceRules.hasAllDucks(ducks: any): boolean
	return SetPieceRules.duckCount(ducks) == #SetPieceRules.DUCK_TRACKS
end

-- Held list for the DucksHeld attribute, in DUCK_TRACKS order.
function SetPieceRules.duckList(ducks: any): { string }
	local out = {}
	if type(ducks) == "table" then
		for _, id in SetPieceRules.DUCK_TRACKS do
			if ducks[id] == true then
				table.insert(out, id)
			end
		end
	end
	return out
end

-- The hunt's toast line.
function SetPieceRules.duckToast(count: number): string
	local total = #SetPieceRules.DUCK_TRACKS
	if count >= total then
		return "ALL DUCKS HOME! GOLDEN QUACK HORN UNLOCKED"
	end
	return string.format("LOST DUCK %d/%d", count, total)
end

---------------------------------------------------------------------------------------------------- monorail (25)

-- SPACE-4 viaduct (tools/map/author_space4.py; checked against the plan by tools/map/tests/test_set_pieces.py): it
-- runs along world X at VIADUCT_Z between the two stations; the route passes under it at CROSS_A (start straight,
-- heading north) and CROSS_B (east side).
SetPieceRules.MONORAIL = table.freeze({
	trackId = "SPACE-4",
	viaductZ = 7150.004,
	trainY = 121.4, -- the train model's pivot height (beam top + 0.4)
	restX = 7012.0, -- where the map parks the west train (the moving train is placed relative to that pivot)
	westX = 6730.0, -- station pivots: the train stops centred on them
	eastX = 8634.11,
	crossA = { station = 150.0, x = 7000.0 },
	crossB = { station = 2622.2, x = 8364.11 },
	cruise = 68, -- studs/s: crossing A -> B in about 20 s, a close race for a good line at 128 with the boosts
	accel = 30,
	dwell = 8,
	departBeforeGo = 2.9, -- leaves the west station on the countdown, abreast of the grid at crossing A ~2 s after GO
	windowBehind = 220, -- a race starts at crossing A if the eastbound train is this far behind ...
	windowAhead = 320, -- ... to this far ahead of the crossing
	stationJump = 400, -- a Station change larger than this is a lap wrap or a respawn, never a crossing
}) :: any

local function runDistance(): number
	return SetPieceRules.MONORAIL.eastX - SetPieceRules.MONORAIL.westX
end

-- Trapezoid run: (time, distance covered) helpers.
function SetPieceRules.monorailRunTime(): number
	local m = SetPieceRules.MONORAIL
	local D = runDistance()
	local ta = m.cruise / m.accel
	local da = 0.5 * m.accel * ta * ta
	if 2 * da >= D then
		return 2 * math.sqrt(D / m.accel)
	end
	return 2 * ta + (D - 2 * da) / m.cruise
end

function SetPieceRules.monorailPeriod(): number
	return 2 * (SetPieceRules.monorailRunTime() + SetPieceRules.MONORAIL.dwell)
end

-- Distance covered `tau` seconds into a run (0 .. runDistance).
local function runAt(tau: number): number
	local m = SetPieceRules.MONORAIL
	local D = runDistance()
	local T = SetPieceRules.monorailRunTime()
	local ta = m.cruise / m.accel
	local da = 0.5 * m.accel * ta * ta
	tau = math.clamp(tau, 0, T)
	if tau < ta then
		return 0.5 * m.accel * tau * tau
	elseif tau > T - ta then
		local r = T - tau
		return D - 0.5 * m.accel * r * r
	end
	return da + (tau - ta) * m.cruise
end

-- Cycle origin (server time of an eastbound departure): anchored to the race's GO while one runs, else free running.
function SetPieceRules.monorailEpoch(goTime: number?): number
	if type(goTime) == "number" then
		return goTime - SetPieceRules.MONORAIL.departBeforeGo
	end
	return 0
end

-- Train centre x on the viaduct at server time `now`, its direction (+1 east, -1 west, 0 parked) and speed.
function SetPieceRules.monorailAt(now: number, epoch: number): (number, number, number)
	local m = SetPieceRules.MONORAIL
	local T = SetPieceRules.monorailRunTime()
	local P = SetPieceRules.monorailPeriod()
	local tau = (now - epoch) % P
	local function speedAt(s: number): number
		local ta = m.cruise / m.accel
		if s < ta then
			return m.accel * s
		elseif s > T - ta then
			return m.accel * (T - s)
		end
		return m.cruise
	end
	if tau < T then
		return m.westX + runAt(tau), 1, speedAt(tau)
	elseif tau < T + m.dwell then
		return m.eastX, 0, 0
	elseif tau < 2 * T + m.dwell then
		local s = tau - T - m.dwell
		return m.eastX - runAt(s), -1, speedAt(s)
	end
	return m.westX, 0, 0
end

-- Server time at which the eastbound train of the cycle that contains `now` passes x (nil if x is off the viaduct).
function SetPieceRules.monorailEastboundAt(x: number, now: number, epoch: number): number?
	local m = SetPieceRules.MONORAIL
	if x < m.westX or x > m.eastX then
		return nil
	end
	local P = SetPieceRules.monorailPeriod()
	local T = SetPieceRules.monorailRunTime()
	local cycleStart = now - ((now - epoch) % P)
	-- bisection on the monotonic run
	local lo, hi = 0, T
	local want = x - m.westX
	for _ = 1, 40 do
		local mid = (lo + hi) / 2
		if runAt(mid) < want then
			lo = mid
		else
			hi = mid
		end
	end
	return cycleStart + (lo + hi) / 2
end

-- Did a Station change prev -> cur cross `mark` going forward (no lap wrap, no respawn jump)?
function SetPieceRules.crossedStation(prev: number?, cur: number?, mark: number): boolean
	if type(prev) ~= "number" or type(cur) ~= "number" then
		return false
	end
	return prev < mark and cur >= mark and cur - prev < SetPieceRules.MONORAIL.stationJump
end

-- A race against the train starts when a player passes crossing A while the eastbound train is near it.
function SetPieceRules.monorailRaceOn(trainX: number, dir: number): boolean
	local m = SetPieceRules.MONORAIL
	return dir > 0 and trainX >= m.crossA.x - m.windowBehind and trainX <= m.crossA.x + m.windowAhead
end

-- Verdict for a player who reached crossing B at server time `playerAt` against the train's own time there.
function SetPieceRules.monorailVerdict(playerAt: number, trainAt: number): (boolean, number)
	return playerAt < trainAt, trainAt - playerAt
end

function SetPieceRules.monorailToast(won: boolean, margin: number): string
	if won then
		return string.format("YOU BEAT THE MOON MONORAIL! (+%.1f s)", math.max(0, margin))
	end
	return "THE MOON MONORAIL WINS"
end

---------------------------------------------------------------------------------------------------- bosses (21)

-- One keyframe of a defeat gag, in the anchor frame (x right, y up, -z ahead of the winner, like a CFrame's own
-- axes): offset studs, yaw / pitch / roll degrees about the boss's own axes (yaw 180 faces the winner).
export type Key = { t: number, p: Vector3, yaw: number, pitch: number, roll: number, ease: string? }
export type Gag = {
	seconds: number,
	keys: { Key },
	events: { { at: number, kind: string } },
	clips: { { from: number, clip: string, rate: number? } },
	ahead: number, -- anchor distance ahead of the winner, in boss lengths
}

local function K(t: number, x: number, y: number, z: number, yaw: number, pitch: number, roll: number, ease: string?): Key
	return { t = t, p = Vector3.new(x, y, z), yaw = yaw, pitch = pitch, roll = roll, ease = ease }
end

-- Ease of a segment by name.
function SetPieceRules.ease(name: string?, x: number): number
	local t = math.clamp(x, 0, 1)
	if name == "in" then
		return t * t
	elseif name == "out" then
		return 1 - (1 - t) * (1 - t)
	elseif name == "linear" then
		return t
	elseif name == "back" then
		local c1, c3 = 1.70158, 2.70158
		local u = t - 1
		return 1 + c3 * u * u * u + c1 * u * u
	elseif name == "bounce" then
		-- lands at t = 1 after a drop: a falling arc then two small hops
		if t < 0.6 then
			local u = t / 0.6
			return u * u
		elseif t < 0.85 then
			local u = (t - 0.72) / 0.13
			return 1 - 0.12 * (1 - u * u)
		end
		local u = (t - 0.925) / 0.075
		return 1 - 0.04 * (1 - u * u)
	end
	return smooth(t)
end

-- Gags (OURS). Every one ends with the boss leaving ahead in a poof. Times in seconds.
SetPieceRules.GAGS = table.freeze(({
	-- Cinderwing: spirals down smoking, belly-flops, lies dizzy under circling stars, roars a squeak, flaps off.
	DINO = {
		seconds = 3.7,
		ahead = 1.4,
		keys = {
			K(0.0, 18, 70, -20, 180, -35, 0),
			K(1.0, 0, 3, 0, 180, -10, 720, "in"),
			K(1.25, 0, 7, 0, 180, 0, 700),
			K(1.5, 0, 0, 0, 180, 5, 700, "bounce"),
			K(2.5, 0, 0, 0, 200, 8, 700),
			K(2.9, 0, 1, 0, 180, -10, 720, "back"),
			K(3.7, 0, 50, -120, 0, -25, 720, "in"),
		},
		events = { { at = 0.05, kind = "smoke" }, { at = 1.0, kind = "slam" }, { at = 1.5, kind = "slam_small" }, { at = 1.6, kind = "dizzy" },
			{ at = 2.55, kind = "roar" }, { at = 3.6, kind = "poof" } },
		clips = { { from = 0, clip = "hit", rate = 1.4 }, { from = 1.5, clip = "glide", rate = 0.25 }, { from = 2.55, clip = "roar", rate = 1 }, { from = 3.0, clip = "fly", rate = 1.6 } },
	},
	-- Frosthorn: glides in, freezes solid mid-air, drops and spins away like a puck, shatters out, shakes off, flies.
	SNOW = {
		seconds = 3.8,
		ahead = 1.4,
		keys = {
			K(0.0, -30, 26, -10, 150, -10, 20),
			K(0.8, 0, 6, 0, 180, 0, 0, "out"),
			K(1.2, 0, 0, 0, 180, 0, 0, "in"),
			K(2.3, 14, 0, -10, 180 + 900, 0, 0, "out"),
			K(2.6, 14, 1.5, -10, 180 + 900, 0, 0, "back"),
			K(3.0, 14, 2, -10, 180 + 900, 0, 0),
			K(3.8, 30, 46, -120, 900, -20, 0, "in"),
		},
		events = { { at = 0.8, kind = "freeze" }, { at = 1.2, kind = "slam_small" }, { at = 2.3, kind = "shatter" }, { at = 2.6, kind = "roar" },
			{ at = 3.7, kind = "poof" } },
		clips = { { from = 0, clip = "glide", rate = 0.8 }, { from = 0.8, clip = "hit", rate = 0.0 }, { from = 2.3, clip = "hit", rate = 1.5 },
			{ from = 2.6, clip = "roar", rate = 1 }, { from = 3.0, clip = "fly", rate = 1.6 } },
	},
	-- Clattershell: scuttles in sideways, trips onto its shell, spins on its back like a top, boings upright, legs it.
	ISLAND = {
		seconds = 3.8,
		ahead = 1.6,
		keys = {
			K(0.0, -40, 0, 0, 180, 0, 0),
			K(0.7, 0, 0, 0, 180, 0, 0, "linear"),
			K(1.0, 0, 9, 0, 180, 0, 180, "out"),
			K(1.25, 0, 0, 0, 180, 0, 180, "in"),
			K(2.4, 0, 0, 0, 180 + 1080, 0, 180, "out"),
			K(2.7, 0, 8, 0, 180 + 1080, 0, 360, "out"),
			K(2.9, 0, 0, 0, 180 + 1080, 0, 360, "in"),
			K(3.8, 70, 0, -30, 90 + 1080, 0, 360, "in"),
		},
		events = { { at = 0.75, kind = "flip" }, { at = 1.25, kind = "slam" }, { at = 1.3, kind = "dizzy" }, { at = 2.7, kind = "boing" },
			{ at = 3.0, kind = "roar" }, { at = 3.7, kind = "poof" } },
		clips = { { from = 0, clip = "walk", rate = 2.2 }, { from = 0.75, clip = "hit", rate = 1.8 }, { from = 3.0, clip = "roar", rate = 1 },
			{ from = 3.2, clip = "walk", rate = 2.2 } },
	},
	-- Emberbeetle: hovering, the rotor sputters and smokes, it drops and bounces to its back, legs kick, it rights
	-- itself and wobbles off.
	FOREST = {
		seconds = 3.8,
		ahead = 1.5,
		keys = {
			K(0.0, 0, 22, -10, 180, 0, 0),
			K(0.6, 0, 20, -5, 180, 5, -15),
			K(1.3, 6, 16, 0, 170, 10, 20),
			K(2.0, 0, 0, 0, 180, 0, 180, "bounce"),
			K(2.7, 0, 0, 0, 220, 0, 180),
			K(3.0, 0, 5, 0, 180, 0, 360, "back"),
			K(3.8, -20, 40, -120, 0, -15, 360, "in"),
		},
		events = { { at = 0.6, kind = "sputter" }, { at = 1.0, kind = "sputter" }, { at = 1.4, kind = "sputter" }, { at = 2.0, kind = "slam" },
			{ at = 2.1, kind = "dizzy" }, { at = 2.75, kind = "roar" }, { at = 3.7, kind = "poof" } },
		clips = { { from = 0, clip = "hover", rate = 1 }, { from = 0.6, clip = "hit", rate = 1.2 }, { from = 2.75, clip = "roar", rate = 1 }, { from = 3.0, clip = "fly", rate = 1.5 } },
	},
	-- Thunderwright: the wheels pop off one by one, the chassis drops and skids on sparks, a little white flag goes up,
	-- the engine coughs out a squeaky roar and the kart limps off.
	HUB = {
		seconds = 3.8,
		ahead = 2.0,
		keys = {
			K(0.0, 0, 0, 10, 180, 0, 0),
			K(0.6, 0, 0, 0, 180, 0, 0, "linear"),
			K(0.9, 0, -1.2, -4, 180, 4, 3, "in"),
			K(1.9, 0, -1.2, -24, 200, 4, -4, "out"),
			K(3.0, 0, -1.2, -24, 200, 4, -4),
			K(3.8, -10, -1.2, -110, 20, 4, -4, "in"),
		},
		events = { { at = 0.6, kind = "wheels" }, { at = 0.9, kind = "sparks" }, { at = 2.0, kind = "flag" }, { at = 2.6, kind = "roar" },
			{ at = 3.7, kind = "poof" } },
		clips = { { from = 0, clip = "drive", rate = 1.5 }, { from = 0.9, clip = "hit", rate = 1.0 }, { from = 2.6, clip = "roar", rate = 1 },
			{ from = 3.0, clip = "idle", rate = 1.0 } },
	},
} :: any)) :: { [string]: Gag }

-- The boss pose `t` seconds into its gag: anchor-local offset and the yaw / pitch / roll in radians.
function SetPieceRules.gagPose(gag: Gag, t: number): (Vector3, number, number, number)
	local keys = gag.keys
	if t <= keys[1].t then
		local k = keys[1]
		return k.p, math.rad(k.yaw), math.rad(k.pitch), math.rad(k.roll)
	end
	for i = 2, #keys do
		local b = keys[i]
		if t <= b.t then
			local a = keys[i - 1]
			local span = b.t - a.t
			local e = SetPieceRules.ease(b.ease, if span > 0 then (t - a.t) / span else 1)
			local function lerp(x: number, y: number): number
				return x + (y - x) * e
			end
			return a.p:Lerp(b.p, e), math.rad(lerp(a.yaw, b.yaw)), math.rad(lerp(a.pitch, b.pitch)), math.rad(lerp(a.roll, b.roll))
		end
	end
	local k = keys[#keys]
	return k.p, math.rad(k.yaw), math.rad(k.pitch), math.rad(k.roll)
end

-- Which clip plays at `t` (the last entry that has started) and its playback rate.
function SetPieceRules.gagClip(gag: Gag, t: number): (string?, number)
	local name: string? = nil
	local rate = 1
	for _, c in gag.clips do
		if t >= c.from then
			name = c.clip
			rate = c.rate or 1
		end
	end
	return name, rate
end

-- Events whose time falls in (from, to].
function SetPieceRules.gagEvents(gag: Gag, from: number, to: number): { string }
	local out = {}
	for _, e in gag.events do
		if e.at > from and e.at <= to then
			table.insert(out, e.kind)
		end
	end
	return out
end

-- The squeaky version of each boss's roar (Batch 1 roar cue, played fast).
SetPieceRules.SQUEAK_SPEED = 1.85

-- Retired bosses in the hub: where each one hangs out relative to its zone's portal arch (HUB-0 PortalArch_<ZONE>;
-- the final boss beside the SPACE arch it guarded), and how. Offsets: `out` studs beyond the arch away from the
-- plaza, `side` studs to the arch's right, `up` studs over the ground. style: circle (flyers circling overhead),
-- hover (bobbing in place), patrol (walking side to side), park (sitting still).
SetPieceRules.RETIRE = table.freeze({
	DINO = { portal = "DINO", style = "circle", out = 30, side = 0, up = 46, radius = 30, period = 14, base = "glide", roarEvery = 13 },
	SNOW = { portal = "SNOW", style = "circle", out = 30, side = 0, up = 38, radius = 24, period = 12, base = "glide", roarEvery = 15 },
	ISLAND = { portal = "ISLAND", style = "patrol", out = 26, side = 0, up = 0, radius = 9, period = 9, base = "walk", roarEvery = 11 },
	FOREST = { portal = "FOREST", style = "hover", out = 26, side = 0, up = 16, radius = 0, period = 4, base = "hover", roarEvery = 14 },
	HUB = { portal = "SPACE", style = "park", out = 16, side = 22, up = 0, radius = 0, period = 1, base = "idle", roarEvery = 12 },
}) :: { [string]: any }

SetPieceRules.RETIRE_FULL = 160 -- studs: animate every frame inside this
SetPieceRules.RETIRE_LOD = 420 -- 10 Hz to here, frozen beyond
SetPieceRules.RETIRE_LOD_STEP = 0.1

-- Animation step for a retired boss at distance d from the camera: 0 = every frame, -1 = frozen.
function SetPieceRules.retireStep(d: number): number
	if d <= SetPieceRules.RETIRE_FULL then
		return 0
	elseif d <= SetPieceRules.RETIRE_LOD then
		return SetPieceRules.RETIRE_LOD_STEP
	end
	return -1
end

-- A retired boss's pose at hub time t around its home point: offset from home and the heading (unit, flat).
function SetPieceRules.retirePose(zone: string, t: number): (Vector3, Vector3)
	local r = SetPieceRules.RETIRE[zone]
	if not r then
		return Vector3.zero, Vector3.new(0, 0, -1)
	end
	local w = 2 * math.pi / r.period
	if r.style == "circle" then
		local a = t * w
		local off = Vector3.new(math.cos(a) * r.radius, math.sin(t * 0.7) * 2, math.sin(a) * r.radius)
		local dir = Vector3.new(-math.sin(a), 0, math.cos(a))
		return off, dir
	elseif r.style == "patrol" then
		local s = math.sin(t * w)
		local dir = if math.cos(t * w) >= 0 then Vector3.xAxis else -Vector3.xAxis
		return Vector3.new(s * r.radius, 0, 0), dir
	elseif r.style == "hover" then
		return Vector3.new(0, math.sin(t * w) * 1.5, 0), Vector3.new(math.sin(t * 0.3), 0, -math.cos(t * 0.3))
	end
	return Vector3.zero, Vector3.new(0, 0, -1)
end

-- Zones whose boss the player has beaten, from the BossesBeaten attribute (JSON list) decoded by the caller.
function SetPieceRules.retiredZones(list: any): { string }
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	local seen: { [string]: boolean } = {}
	for _, z in list do
		if type(z) == "string" and SetPieceRules.RETIRE[z] and not seen[z] then
			seen[z] = true
			table.insert(out, z)
		end
	end
	table.sort(out)
	return out
end

-- BossesBeaten from a profile (boss[zone].first for the chain bosses, finalBoss for the hub engineer).
function SetPieceRules.bossesBeaten(profile: any): { string }
	local out = {}
	if type(profile) ~= "table" then
		return out
	end
	local boss = profile.boss
	if type(boss) == "table" then
		for _, zone in { "DINO", "SNOW", "ISLAND", "FOREST" } do
			local b = boss[zone]
			if type(b) == "table" and b.first == true then
				table.insert(out, zone)
			end
		end
	end
	if profile.finalBoss == true then
		table.insert(out, "HUB")
	end
	return out
end

return SetPieceRules
