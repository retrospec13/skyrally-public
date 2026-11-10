--!strict
-- Alternate lines for the course assist and the leash (trap audit G8: D4-05, F3, SN-06, SN-11, S4-01, S4-03).
--
-- The course assist used to pursue only the main spline, so a player who took a shortcut tunnel or ledge and let go
-- of the stick was turned 40-90 degrees into the tube wall (FOREST-1 bore, DINO-4 Alt1/Alt2, SNOW-1 mine), and the
-- only branch-aware code was a dead block of DINO-4 world coordinates. Here the server publishes every
-- TrackData.alternates polyline (plus FOREST-1's hiddenKey.gallery, a "hidden" line) under the track root, and the
-- client picks the line the vehicle is actually on:
--   enter  the vehicle is within the line's tube radius of it AND closer to it than to the main line
--   stay   while within STAY_FACTOR x that radius and not clearly closer to the main line, until the line's end
--   leave  past the end of the polyline: the pursuit point runs on along the main spline from the rejoin station
--
-- Server: RouteBranch.publish(root, alternates, hiddenKey) from MapAdapter's waypoints step (Folder "AltRoutes",
-- one child Folder per line with Vector3 attributes P1..Pn; attributes only, no per-point instances).
-- Client: RouteBranch.load() (cached per track root) and the pure helpers below, which only do Vector3 maths
-- (tools/tests/style_spec.luau runs them under Lune with @lune/roblox Vector3s).
local RouteBranch = {}

RouteBranch.FOLDER = "AltRoutes"
-- Tube radius per line style: how close the vehicle must be to count as "on" it. Tunnels are 26 wide (CourseCarve
-- halfWidth 13), ledges 40 (halfWidth 20), the hidden key gallery is a tight bore. A cliff line (ISLAND-2 Alt2, the
-- headland wall-ride) has no built road: the cliff is the road, so it is a wide corridor over the rock. A "span" is a
-- raised line whose geometry the plan owns (SPACE-4's rooftop shortcut): 28 wide like a ledge, nothing built or carved.
RouteBranch.RADIUS = { tunnel = 18, ledge = 26, hidden = 14, cliff = 36, span = 26 } :: { [string]: number }
RouteBranch.CLIFF_STYLE = "cliff"
RouteBranch.DEFAULT_RADIUS = 20
RouteBranch.STAY_FACTOR = 1.8
RouteBranch.MAIN_MARGIN_ENTER = 4 -- enter only when the line is at least this much closer than the main line
RouteBranch.MAIN_MARGIN_STAY = 12 -- stay until the main line is this much closer
RouteBranch.STATION_SLACK = 150 -- a line counts only near its join..rejoin stretch of the main route
-- Planes fly the main line 14 above the ribbon (the assist aims at +14); alternate points are deck level like the
-- ribbon, the key gallery is already at flight height.
RouteBranch.PLANE_LIFT = 14

export type Line = {
	id: string,
	style: string,
	points: { Vector3 },
	cum: { number }, -- distance along the line at each point
	length: number,
	join: number?, -- main-route station of the line's start
	rejoin: number?, -- main-route station of its end
	radius: number,
}

-- ================================================================ server
local function toV3(p: any): Vector3?
	if typeof(p) == "Vector3" then
		return p
	elseif type(p) == "table" and type(p[1]) == "number" then
		return Vector3.new(p[1], p[2], p[3])
	end
	return nil
end

local function publishLine(parent: Instance, id: string, style: string, pts: { any }, join: number?, rejoin: number?)
	local f = Instance.new("Folder")
	f.Name = id
	f:SetAttribute("Style", style)
	if join then
		f:SetAttribute("Join", join)
	end
	if rejoin then
		f:SetAttribute("Rejoin", rejoin)
	end
	local n = 0
	for _, p in pts do
		local v = toV3(p)
		if v then
			n += 1
			f:SetAttribute("P" .. n, v)
		end
	end
	f:SetAttribute("Count", n)
	f.Parent = parent
end

-- alternates: TrackData.alternates ({id, style, points, joinStation, rejoinStation}); hiddenKey: TrackData.hiddenKey
-- (its optional `gallery` polyline becomes the "hidden" line "KeyGallery"). Replaces any earlier copy. Returns the
-- number of lines published.
function RouteBranch.publish(root: Instance, alternates: any, hiddenKey: any): number
	local old = root:FindFirstChild(RouteBranch.FOLDER)
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = RouteBranch.FOLDER
	local n = 0
	for i, alt in (if type(alternates) == "table" then alternates else {}) :: { any } do
		if type(alt) == "table" and type(alt.points) == "table" and #alt.points >= 2 then
			local id = if type(alt.id) == "string" then alt.id else ("Alt" .. i)
			publishLine(folder, id, if type(alt.style) == "string" then alt.style else "ledge", alt.points,
				if type(alt.joinStation) == "number" then alt.joinStation else nil,
				if type(alt.rejoinStation) == "number" then alt.rejoinStation else nil)
			n += 1
		end
	end
	if type(hiddenKey) == "table" and type(hiddenKey.gallery) == "table" and #hiddenKey.gallery >= 2 then
		publishLine(folder, "KeyGallery", "hidden", hiddenKey.gallery, nil, nil)
		n += 1
	end
	folder.Parent = root
	return n
end

-- ================================================================ pure geometry
-- Builds a Line from points (already lifted for the vehicle).
function RouteBranch.makeLine(id: string, style: string, points: { Vector3 }, join: number?, rejoin: number?): Line
	local cum = { 0 }
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
		cum[i] = total
	end
	return {
		id = id,
		style = style,
		points = points,
		cum = cum,
		length = total,
		join = join,
		rejoin = rejoin,
		radius = RouteBranch.RADIUS[style] or RouteBranch.DEFAULT_RADIUS,
	}
end

-- Nearest point on a line: distance, distance along the line, and the point.
function RouteBranch.nearest(line: Line, pos: Vector3): (number, number, Vector3)
	local pts = line.points
	local bestD, bestAlong, bestP = math.huge, 0, pts[1]
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local seg = b - a
		local len2 = seg:Dot(seg)
		local t = if len2 > 1e-6 then math.clamp((pos - a):Dot(seg) / len2, 0, 1) else 0
		local p = a + seg * t
		local d = (pos - p).Magnitude
		if d < bestD then
			bestD = d
			bestAlong = line.cum[i] + (line.cum[i + 1] - line.cum[i]) * t
			bestP = p
		end
	end
	return bestD, bestAlong, bestP
end

-- The point `along` studs from the start (clamped to the line). Returns the point and how far past the end the
-- request was (0 inside the line).
function RouteBranch.pointAt(line: Line, along: number): (Vector3, number)
	local pts = line.points
	if along <= 0 then
		return pts[1], 0
	end
	if along >= line.length then
		return pts[#pts], along - line.length
	end
	local lo, hi = 1, #pts
	while lo < hi - 1 do
		local mid = (lo + hi) // 2
		if line.cum[mid] <= along then
			lo = mid
		else
			hi = mid
		end
	end
	local span = math.max(1e-6, line.cum[hi] - line.cum[lo])
	return pts[lo]:Lerp(pts[hi], math.clamp((along - line.cum[lo]) / span, 0, 1)), 0
end

-- Station distance on a looped track (nil length = no wrap).
local function stationGap(a: number, b: number, trackLength: number?): number
	local d = math.abs(a - b)
	if trackLength and trackLength > 0 then
		d = d % trackLength
		d = math.min(d, trackLength - d)
	end
	return d
end

-- Whether a main-route station lies on the line's join..rejoin stretch (with STATION_SLACK). Lines without stations
-- (the key gallery) always pass.
function RouteBranch.inStretch(line: Line, station: number?, trackLength: number?): boolean
	if not station or not line.join or not line.rejoin then
		return true
	end
	local join, rejoin = line.join :: number, line.rejoin :: number
	local slack = RouteBranch.STATION_SLACK
	if stationGap(station, join, trackLength) <= slack or stationGap(station, rejoin, trackLength) <= slack then
		return true
	end
	if join <= rejoin then
		return station >= join and station <= rejoin
	end
	return station >= join or station <= rejoin -- the stretch wraps past the finish line
end

-- Picks the line the vehicle is on. current = the id picked last time (hysteresis), mainDist = the vehicle's
-- distance to the main line (at the same lift), station = its main-route station. Returns the line (nil = main),
-- its distance, the distance along it, and the distance to the nearest course line of any kind (main or any
-- alternate, whatever its stretch: what the plane's leash measures). Cliff lines are skipped: they are server progress
-- only (cliffProgress). Picking one would move the car's stranded-test reference onto the rock face it climbs and so
-- change the off-track rescue on wall driving (owner rule), and would steer the plane assist over the headland.
function RouteBranch.pick(lines: { Line }, pos: Vector3, mainDist: number, current: string?, station: number?, trackLength: number?): (Line?, number, number, number)
	local best: Line? = nil
	local bestD, bestAlong = math.huge, 0
	local held = false
	local course = mainDist
	for _, line in lines do
		if #line.points >= 2 and line.style ~= RouteBranch.CLIFF_STYLE then
			local d, along = RouteBranch.nearest(line, pos)
			if d < course then
				course = d
			end
			if not held and RouteBranch.inStretch(line, station, trackLength) then
				local stay = line.id == current
				local ok
				if stay then
					ok = d <= line.radius * RouteBranch.STAY_FACTOR and d < mainDist + RouteBranch.MAIN_MARGIN_STAY and along < line.length - 2
				else
					ok = d <= line.radius and d < mainDist - RouteBranch.MAIN_MARGIN_ENTER and along < line.length - 2
				end
				-- The line held last time wins, so two overlapping lines never flicker.
				if ok and (d < bestD or stay) then
					best, bestD, bestAlong = line, d, along
					held = stay
				end
			end
		end
	end
	return best, bestD, bestAlong, course
end

-- Pursuit target on a picked line: `lookahead` studs ahead of `along`. Returns the point and the overflow past the
-- line's end (> 0: the caller continues on the main spline from line.rejoin + overflow).
function RouteBranch.target(line: Line, along: number, lookahead: number): (Vector3, number)
	-- Tunnels and the gallery bend inside rock: pursue nearer so the chord never cuts through a wall.
	local la = if line.style == "ledge" or line.style == "span" then lookahead else math.max(35, lookahead * 0.6)
	return RouteBranch.pointAt(line, along + la)
end

-- ================================================================ cliff lines (server progress)
-- A cliff line leaves and rejoins the main route like any alternate, but in between it climbs a rock face and crosses
-- the roof of a mass the main route tunnels through: the nearest main-spline point is 100+ studs below and can be a
-- long way along the course, so the plain projection would drop the racer's station, checkpoints and ranking for the
-- whole ride. RaceManager asks cliffProgress instead and, while the racer is on the line, uses the station the line
-- maps to (join + (rejoin - join) * along / length), and counts the racer as on course.
-- Nothing here moves, steers or limits a vehicle: wall and slope driving are untouched.
-- The lines without the cliff lines: what the plane rules (must-pass checkpoints, the server off-course clock) see,
-- so a cliff line leaves them exactly as before.
function RouteBranch.withoutCliff(lines: { Line }): { Line }
	local out: { Line } = {}
	for _, line in lines do
		if line.style ~= RouteBranch.CLIFF_STYLE then
			table.insert(out, line)
		end
	end
	return out
end

function RouteBranch.cliffOnly(lines: { Line }): { Line }
	local out: { Line } = {}
	for _, line in lines do
		if line.style == RouteBranch.CLIFF_STYLE and #line.points >= 2 and line.join and line.rejoin then
			table.insert(out, line)
		end
	end
	return out
end

-- The cliff line a vehicle is on (nil: none) and its mapped main-route station. `pos` and `mainDist` are in the
-- frame the lines were loaded in (RaceManager passes the plane-lifted hull and distance); `current` is the id held
-- last time (hysteresis, as pick: enter close and clearly nearer than the main line, stay while within STAY_FACTOR x
-- the radius and not clearly closer to the main line). Past the end of the line it hands back to the main spline.
function RouteBranch.cliffProgress(cliffLines: { Line }, pos: Vector3, mainDist: number, current: string?): (Line?, number)
	local best: Line? = nil
	local bestD, bestAlong = math.huge, 0
	for _, line in cliffLines do
		local d, along = RouteBranch.nearest(line, pos)
		local stay = line.id == current
		local ok
		if stay then
			ok = d <= line.radius * RouteBranch.STAY_FACTOR and d < mainDist + RouteBranch.MAIN_MARGIN_STAY and along < line.length - 2
		else
			ok = d <= line.radius and d < mainDist - RouteBranch.MAIN_MARGIN_ENTER and along < line.length - 2
		end
		if ok and (d < bestD or stay) then
			best, bestD, bestAlong = line, d, along
		end
	end
	if not best then
		return nil, 0
	end
	local join, rejoin = best.join :: number, best.rejoin :: number
	local frac = if best.length > 1e-6 then math.clamp(bestAlong / best.length, 0, 1) else 0
	return best, join + (rejoin - join) * frac
end

-- ================================================================ client loader
local cacheRoot: Instance? = nil
local cacheLift = -1
local cacheCount = -1
local cacheCheck = -math.huge
local cacheLines: { Line } = {}
local EMPTY: { Line } = {}
RouteBranch.RECHECK_S = 2 -- a cached set is re-counted this often (the server may publish after the client looks)

-- Lines for the active track (TrackRegistry root), lifted for the vehicle: lift = PLANE_LIFT for planes (the key
-- gallery is already at flight height), 0 for cars. Cached per root and lift; called every frame by the assist, so
-- the cached path allocates nothing and the folder is only re-counted every RECHECK_S.
function RouteBranch.load(root: Instance?, lift: number): { Line }
	if not root then
		return EMPTY
	end
	local now = os.clock()
	if root == cacheRoot and lift == cacheLift and now - cacheCheck < RouteBranch.RECHECK_S then
		return cacheLines
	end
	cacheCheck = now
	local folder = root:FindFirstChild(RouteBranch.FOLDER)
	local count = if folder then #folder:GetChildren() else 0
	if root == cacheRoot and lift == cacheLift and count == cacheCount then
		return cacheLines
	end
	cacheRoot, cacheLift, cacheCount = root, lift, count
	local lines: { Line } = {}
	if folder then
		for _, f in folder:GetChildren() do
			local n = f:GetAttribute("Count")
			local style = f:GetAttribute("Style")
			if type(n) == "number" and n >= 2 then
				local up = if style == "hidden" then 0 else lift
				local pts: { Vector3 } = {}
				for i = 1, n do
					local v = f:GetAttribute("P" .. i)
					if typeof(v) == "Vector3" then
						table.insert(pts, v + Vector3.new(0, up, 0))
					end
				end
				if #pts >= 2 then
					local join = f:GetAttribute("Join")
					local rejoin = f:GetAttribute("Rejoin")
					table.insert(lines, RouteBranch.makeLine(f.Name, if type(style) == "string" then style else "ledge", pts,
						if type(join) == "number" then join else nil, if type(rejoin) == "number" then rejoin else nil))
				end
			end
		end
	end
	cacheLines = lines
	return lines
end

return RouteBranch
