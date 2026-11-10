--!strict
-- Race minimap rules (pure, no Roblox globals; tools/tests/minimap_spec.luau runs it under Lune). docs/design/HUD_MK_LAYOUT.md.
--  * fit: the course centreline (world x / z, height ignored, so planes and cars share one path) -> a uniform scale and offset
--    that centres it in a square frame, NORTH-UP (world -Z is up): a fixed map shows the whole course shape at a glance and
--    costs nothing per frame, while a rotating track-fixed one would turn the outline every frame and swing on switchbacks.
--  * simplify: Ramer-Douglas-Peucker on the frame-space polyline, so a 300-point spline is ~60 segments (2 Frames each, built once).
--  * segment: a polyline segment as the centre / length / angle of the rotated Frame that draws it.
--  * place / clampInside: a racer's frame position (px) from its world x / z, kept inside the frame.
--  * step: the unwrapped lap + fraction progress of one racer from its nearest waypoint index, to find the leader without
--    touching the server's standings; nearest: that index search in a small window around the last one (no full scan).
--  * due: the update throttle (10-15 Hz) from a frame clock.
local MinimapRules = {}

export type Pt = { x: number, y: number }
export type Fit = { scale: number, ox: number, oy: number }

MinimapRules.HZ = 12 -- marker update rate
MinimapRules.PAD = 0.12 -- fraction of the frame kept empty around the outline (room for the marker radius and the dark edge)
MinimapRules.TOLERANCE_PX = 0.7 -- simplify tolerance in frame px
MinimapRules.WINDOW = 24 -- waypoints searched either side of a racer's last index

-- pts = { {x = world x, y = world z} }, frame = square side in px. Returns nil for fewer than two distinct points.
function MinimapRules.fit(pts: { Pt }, frame: number): Fit?
	if #pts < 2 then
		return nil
	end
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for _, p in pts do
		minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
		minY, maxY = math.min(minY, p.y), math.max(maxY, p.y)
	end
	local w, hgt = maxX - minX, maxY - minY
	local span = math.max(w, hgt)
	if span < 1e-6 then
		return nil
	end
	local inner = frame * (1 - 2 * MinimapRules.PAD)
	local scale = inner / span
	return {
		scale = scale,
		ox = (frame - w * scale) / 2 - minX * scale,
		oy = (frame - hgt * scale) / 2 - minY * scale,
	}
end

function MinimapRules.place(fit: Fit, wx: number, wz: number): (number, number)
	return wx * fit.scale + fit.ox, wz * fit.scale + fit.oy
end

-- Keeps a marker's centre inside the frame (a racer far off the course must not leave the map).
function MinimapRules.clampInside(x: number, y: number, frame: number, margin: number): (number, number)
	return math.clamp(x, margin, frame - margin), math.clamp(y, margin, frame - margin)
end

local function distToSeg(p: Pt, a: Pt, b: Pt): number
	local dx, dy = b.x - a.x, b.y - a.y
	local l2 = dx * dx + dy * dy
	local t = 0
	if l2 > 1e-12 then
		t = math.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0, 1)
	end
	local ex, ey = a.x + dx * t - p.x, a.y + dy * t - p.y
	return math.sqrt(ex * ex + ey * ey)
end

-- Ramer-Douglas-Peucker, iterative (no recursion depth on a long spline). Keeps the first and last point and returns a new list.
function MinimapRules.simplify(pts: { Pt }, tol: number): { Pt }
	local n = #pts
	if n <= 2 then
		return table.clone(pts)
	end
	local keep: { boolean } = table.create(n, false)
	keep[1], keep[n] = true, true
	local stack: { number } = { 1, n }
	while #stack >= 2 do
		local hi = table.remove(stack) :: number
		local lo = table.remove(stack) :: number
		local worst, at = 0, 0
		for i = lo + 1, hi - 1 do
			local d = distToSeg(pts[i], pts[lo], pts[hi])
			if d > worst then
				worst, at = d, i
			end
		end
		if at > 0 and worst > tol then
			keep[at] = true
			table.insert(stack, lo)
			table.insert(stack, at)
			table.insert(stack, at)
			table.insert(stack, hi)
		end
	end
	local out: { Pt } = {}
	for i = 1, n do
		if keep[i] then
			table.insert(out, pts[i])
		end
	end
	return out
end

-- The rotated Frame (anchor 0.5, 0.5) that draws a -> b: centre, length (grown by `cap` so round ends join), angle in degrees.
function MinimapRules.segment(a: Pt, b: Pt, cap: number): (number, number, number, number)
	local dx, dy = b.x - a.x, b.y - a.y
	return (a.x + b.x) / 2, (a.y + b.y) / 2, math.sqrt(dx * dx + dy * dy) + cap, math.deg(math.atan2(dy, dx))
end

-- Course points (waypoint list with pos.X / pos.Z) -> frame-space simplified polyline for this frame size, plus the fit.
-- `closed` repeats the first point so a circuit's outline joins up.
function MinimapRules.outline(points: { Pt }, frame: number, closed: boolean): ({ Pt }?, Fit?)
	local fit = MinimapRules.fit(points, frame)
	if not fit then
		return nil, nil
	end
	local mapped: { Pt } = table.create(#points + 1)
	for i, p in points do
		local x, y = MinimapRules.place(fit, p.x, p.y)
		mapped[i] = { x = x, y = y }
	end
	if closed then
		local f = mapped[1]
		table.insert(mapped, { x = f.x, y = f.y })
	end
	return MinimapRules.simplify(mapped, MinimapRules.TOLERANCE_PX), fit
end

-- True when the end of the course meets its start (a circuit): the gap is under 6 percent of the larger span.
function MinimapRules.isClosed(points: { Pt }): boolean
	local n = #points
	if n < 3 then
		return false
	end
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for _, p in points do
		minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
		minY, maxY = math.min(minY, p.y), math.max(maxY, p.y)
	end
	local span = math.max(maxX - minX, maxY - minY)
	local dx, dy = points[n].x - points[1].x, points[n].y - points[1].y
	return math.sqrt(dx * dx + dy * dy) < 0.06 * span
end

-- Index of the waypoint nearest (x, z) among `hint` +- WINDOW (wrapping on a closed course); a nil hint scans all of them.
-- xs / zs are parallel arrays of waypoint world x / z. Returns the index.
function MinimapRules.nearest(xs: { number }, zs: { number }, x: number, z: number, hint: number?, closed: boolean): number
	local n = #xs
	local best, bestD = 1, math.huge
	local lo, hi = 1, n
	if hint then
		lo, hi = hint - MinimapRules.WINDOW, hint + MinimapRules.WINDOW
		if not closed then
			lo, hi = math.max(1, lo), math.min(n, hi)
		end
	end
	for i = lo, hi do
		local k = i
		if k < 1 then
			k += n
		elseif k > n then
			k -= n
		end
		local dx, dz = xs[k] - x, zs[k] - z
		local d = dx * dx + dz * dz
		if d < bestD then
			best, bestD = k, d
		end
	end
	return best
end

export type Progress = { lap: number, frac: number, idx: number? }

function MinimapRules.newProgress(): Progress
	return { lap = 0, frac = 0, idx = nil }
end

-- Advances a racer's progress to waypoint `idx` of `n`: lap counts crossings of the start line (index wraps) in either direction,
-- and a racer that starts just behind the line (frac > 0.75 on its first sample) begins at lap -1 + frac, i.e. behind everyone
-- on the line. Returns lap + frac, comparable across racers.
function MinimapRules.step(p: Progress, idx: number, n: number): number
	local frac = (idx - 1) / n
	local last = p.idx
	if last == nil then
		p.lap = if frac > 0.75 then -1 else 0
	else
		local lastFrac = (last - 1) / n
		if lastFrac > 0.75 and frac < 0.25 then
			p.lap += 1
		elseif lastFrac < 0.25 and frac > 0.75 then
			p.lap -= 1
		end
	end
	p.idx, p.frac = idx, frac
	return p.lap + frac
end

-- Throttle: due(state, now) is true at most HZ times a second; state = { next = 0 }.
function MinimapRules.due(state: { next: number }, now: number): boolean
	if now < state.next then
		return false
	end
	state.next = now + 1 / MinimapRules.HZ
	return true
end

-- Marker diameter (px) for a frame side: others, and the local racer (larger).
function MinimapRules.dotSizes(frame: number): (number, number)
	local other = math.clamp(math.floor(frame * 0.085 + 0.5), 6, 16)
	local own = math.clamp(math.floor(frame * 0.125 + 0.5), 9, 24)
	return other, own
end

return MinimapRules
