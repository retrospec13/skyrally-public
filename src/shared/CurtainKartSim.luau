--!strict
-- Curtain Kart physics and lap rules (docs/REMARKABLE.md item 8), pure and allocation-free per step so
-- client/CurtainKart can run it every frame on a low-end phone and tools/tests/curtain_kart_spec.luau can drive it
-- under Lune. Units are the baked unit box of shared/CurtainTracks (the track's long side = 1); screen axes: x right,
-- y down, so a positive heading change turns clockwise (right) on screen.
--
-- Rules:
--   * auto-throttle to a per-track top speed: the spec's 0.42 units/s, raised on long outlines so a clean lap takes
--     about LAP_TARGET seconds of top speed (an autopilot lap takes 4.5..5.6 s, so a lap fits a 6 s load); steering at full lock scrubs SCRUB of it;
--   * 250 degrees per second of steering (the spec's 210 could not hold the square corners at lap pace); off the road (farther than HALF_WIDTH from the polyline) the target drops to
--     40 percent;
--   * progress = the nearest point on the polyline, searched around the last segment first so a crossover (SNOW-1's
--     figure eight) keeps you on your own branch;
--   * a lap counts when progress wraps forward over the start line after more than 80 percent of the segments were
--     visited; wrapping backward over the line voids the lap in progress.
local Sim = {}

Sim.HALF_WIDTH = 0.03
Sim.TURN_RATE = math.rad(250) -- spec 210; 250 lets the tap-steer phone kart hold SPACE-4's square corners
Sim.OFF_FACTOR = 0.4
Sim.BASE_SPEED = 0.42
Sim.MAX_SPEED = 0.85
Sim.LAP_TARGET = 4.0
Sim.SCRUB = 0.25
Sim.ACCEL = 2.5 -- top speeds per second (full speed in 0.4 s)
Sim.DECEL = 2.6
Sim.VISIT_SHARE = 0.8
Sim.BOX_MARGIN = 0.08
Sim.LOCAL_WINDOW = 3

export type Track = {
	n: number,
	xs: { number },
	ys: { number },
	seg: { number }, -- length of segment i (point i -> point i+1, wrapping)
	cum: { number }, -- station at point i
	total: number,
	w: number,
	h: number,
	top: number, -- auto-throttle speed for this outline
}

export type Kart = {
	x: number,
	y: number,
	heading: number, -- radians, screen space
	speed: number,
	segIndex: number,
	station: number,
	dist: number,
	offTrack: boolean,
	visited: { boolean },
	visitedCount: number,
	clock: number, -- seconds since spawn
	lapStart: number,
	laps: number,
	lastLap: number?,
	best: number?,
}

function Sim.prepare(points: { { number } }, w: number?, h: number?): Track
	local n = #points
	local xs, ys = table.create(n, 0), table.create(n, 0)
	local maxX, maxY = 0, 0
	for i, p in points do
		xs[i], ys[i] = p[1], p[2]
		maxX, maxY = math.max(maxX, p[1]), math.max(maxY, p[2])
	end
	local seg, cum = table.create(n, 0), table.create(n, 0)
	local total = 0
	for i = 1, n do
		local j = if i == n then 1 else i + 1
		cum[i] = total
		seg[i] = math.sqrt((xs[j] - xs[i]) ^ 2 + (ys[j] - ys[i]) ^ 2)
		total += seg[i]
	end
	local top = math.clamp(total / Sim.LAP_TARGET, Sim.BASE_SPEED, Sim.MAX_SPEED)
	return { n = n, xs = xs, ys = ys, seg = seg, cum = cum, total = total, w = w or maxX, h = h or maxY, top = top }
end

-- Distance from (x, y) to segment i, and the 0..1 position along it.
local function segDist(tr: Track, i: number, x: number, y: number): (number, number)
	local j = if i == tr.n then 1 else i + 1
	local ax, ay = tr.xs[i], tr.ys[i]
	local dx, dy = tr.xs[j] - ax, tr.ys[j] - ay
	local l2 = dx * dx + dy * dy
	local t = if l2 > 0 then math.clamp(((x - ax) * dx + (y - ay) * dy) / l2, 0, 1) else 0
	local px, py = x - ax - t * dx, y - ay - t * dy
	return math.sqrt(px * px + py * py), t
end

-- Nearest point on the loop: (segment index, t along it, distance, station). With a hint, the segments within
-- LOCAL_WINDOW of it are searched first (hint, +1, -1, +2, ...); the whole loop only when that is far off.
function Sim.project(tr: Track, x: number, y: number, hint: number?): (number, number, number, number)
	local n = tr.n
	local bestI, bestT, bestD = 1, 0, math.huge
	if hint then
		for k = 0, Sim.LOCAL_WINDOW * 2 do
			local off = if k % 2 == 1 then (k + 1) // 2 else -(k // 2)
			local i = (hint - 1 + off) % n + 1
			local d, t = segDist(tr, i, x, y)
			if d < bestD then
				bestI, bestT, bestD = i, t, d
			end
		end
	end
	if bestD > Sim.HALF_WIDTH * 3 then
		for i = 1, n do
			local d, t = segDist(tr, i, x, y)
			if d < bestD - 1e-9 then
				bestI, bestT, bestD = i, t, d
			end
		end
	end
	return bestI, bestT, bestD, tr.cum[bestI] + bestT * tr.seg[bestI]
end

-- Heading of segment i (radians, screen space).
function Sim.segHeading(tr: Track, i: number): number
	local j = if i == tr.n then 1 else i + 1
	return math.atan2(tr.ys[j] - tr.ys[i], tr.xs[j] - tr.xs[i])
end

function Sim.newKart(tr: Track, startIndex: number?): Kart
	local s = startIndex or 1
	local visited = table.create(tr.n, false)
	visited[s] = true
	return {
		x = tr.xs[s],
		y = tr.ys[s],
		heading = Sim.segHeading(tr, s),
		speed = 0,
		segIndex = s,
		station = tr.cum[s],
		dist = 0,
		offTrack = false,
		visited = visited,
		visitedCount = 1,
		clock = 0,
		lapStart = 0,
		laps = 0,
		lastLap = nil,
		best = nil,
	}
end

local function clearVisits(k: Kart, keep: number)
	table.clear(k.visited)
	k.visited[keep] = true
	k.visitedCount = 1
end

-- One step. steer in -1..1 (positive = right / clockwise). Returns the lap time when this step completed a lap.
function Sim.step(tr: Track, k: Kart, dt: number, steer: number): number?
	dt = math.clamp(dt, 0, 0.1)
	steer = math.clamp(steer, -1, 1)
	k.clock += dt
	k.heading += steer * Sim.TURN_RATE * dt
	local target = tr.top * (1 - Sim.SCRUB * math.abs(steer)) * (if k.offTrack then Sim.OFF_FACTOR else 1)
	if k.speed < target then
		k.speed = math.min(target, k.speed + Sim.ACCEL * tr.top * dt)
	else
		k.speed = math.max(target, k.speed - Sim.DECEL * tr.top * dt)
	end
	local m = Sim.BOX_MARGIN
	k.x = math.clamp(k.x + math.cos(k.heading) * k.speed * dt, -m, tr.w + m)
	k.y = math.clamp(k.y + math.sin(k.heading) * k.speed * dt, -m, tr.h + m)

	local prev = k.station
	local i, _, d, st = Sim.project(tr, k.x, k.y, k.segIndex)
	k.segIndex, k.dist, k.station = i, d, st
	k.offTrack = d > Sim.HALF_WIDTH
	if not k.visited[i] then
		k.visited[i] = true
		k.visitedCount += 1
	end
	local L = tr.total
	local lap: number? = nil
	if prev > L * 0.75 and st < L * 0.25 then
		-- Forward over the line: a lap when most of the loop was driven; either way a new lap starts here.
		if k.visitedCount >= math.ceil(tr.n * Sim.VISIT_SHARE) then
			local t = k.clock - k.lapStart
			lap = t
			k.laps += 1
			k.lastLap = t
			if k.best == nil or t < (k.best :: number) then
				k.best = t
			end
		end
		k.lapStart = k.clock
		clearVisits(k, i)
	elseif prev < L * 0.25 and st > L * 0.75 then
		-- Backward over the line: the lap in progress is void.
		clearVisits(k, i)
	end
	return lap
end

-- Attract-mode and test driver: steer toward a point `ahead` units further along the loop.
function Sim.autoSteer(tr: Track, k: Kart, ahead: number?): number
	local s = (k.station + (ahead or 0.07)) % tr.total
	-- Find the segment holding station s (walk forward from the current one; the lookahead spans a few segments).
	local i = k.segIndex
	for _ = 1, tr.n do
		local nxt = tr.cum[i] + tr.seg[i]
		if s >= tr.cum[i] and s <= nxt then
			break
		end
		i = if i == tr.n then 1 else i + 1
	end
	local t = if tr.seg[i] > 0 then math.clamp((s - tr.cum[i]) / tr.seg[i], 0, 1) else 0
	local j = if i == tr.n then 1 else i + 1
	local tx = tr.xs[i] + (tr.xs[j] - tr.xs[i]) * t
	local ty = tr.ys[i] + (tr.ys[j] - tr.ys[i]) * t
	local want = math.atan2(ty - k.y, tx - k.x)
	local diff = (want - k.heading + math.pi) % (2 * math.pi) - math.pi
	return math.clamp(diff * 4, -1, 1)
end

-- "7.2" style lap text (one decimal; minutes past 60 s).
function Sim.formatLap(t: number): string
	if t >= 60 then
		return string.format("%d:%04.1f", t // 60, t % 60)
	end
	return string.format("%.1f", t)
end

return Sim
