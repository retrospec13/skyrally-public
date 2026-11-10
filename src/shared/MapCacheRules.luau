--!strict
-- Map cache rules (TEST_LIST L42, also L41): a map is built once per server and reused on every later load of its key
-- (server/MapCache). Pure: no Instances, specced in tools/tests/mapcache_spec.luau.
--
-- The cached terrain is one TerrainRegion over a box that must hold every voxel the first build wrote: the compiled
-- builder's height grid (TrackData.terrainBounds, emitted by tools/map/adapt.py from the plan) unioned with the box of
-- every terrain-adding shell op (MapAdapter.applyShellOp), snapped outward to the 4-stud voxel grid plus one cell. The
-- corridor carve and CarveRouteTube only remove terrain, so they never grow the box. When any part of the box cannot be
-- known (no terrainBounds, an unknown op, an untyped value) the map is not cached and every load stays a full build.
local MapCacheRules = {}

MapCacheRules.RES = 4 -- studs per terrain voxel
MapCacheRules.PAD_CELLS = 1 -- extra voxels around the box: a fill's edge voxel is partly filled
-- Maps kept at once (the hub is never evicted). Six covers the hub and the five race zones, so in practice nothing is
-- evicted; the cap only guards a server against a map list that grows.
MapCacheRules.MAX_MAPS = 6
local INT16_MIN, INT16_MAX = -32768, 32767

-- empty: the map writes no terrain (nothing to copy; a cached load only clears).
export type Box = { lo: Vector3, hi: Vector3, empty: boolean? }

-- QA (L42): in Studio, workspace attribute MapCacheOff = true makes every load a full build. Live servers ignore it.
function MapCacheRules.enabled(isStudio: boolean, offAttr: any): boolean
	return not (isStudio and offAttr == true)
end

-- Only a clean, finished build is cached: a builder that timed out (mapBuilt false) leaves a partial map, and a build
-- with adapter errors (a failed asset load) gets another full build next time instead of keeping the failure.
function MapCacheRules.cacheable(mapBuilt: boolean, errors: number): boolean
	return mapBuilt == true and errors == 0
end

local function cube(c: Vector3, r: number): (Vector3, Vector3)
	return Vector3.new(c.X - r, c.Y - r, c.Z - r), Vector3.new(c.X + r, c.Y + r, c.Z + r)
end

-- The world-axis box of a block of `size` at `cf` (its eight corners), as tight as the rotation allows.
local function blockBox(cf: CFrame, size: Vector3): (Vector3, Vector3)
	local h = size * 0.5
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local p = cf * Vector3.new(h.X * sx, h.Y * sy, h.Z * sz)
				lo = Vector3.new(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z))
				hi = Vector3.new(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z))
			end
		end
	end
	return lo, hi
end

local function union(lo: Vector3?, hi: Vector3?, l: Vector3, h: Vector3): (Vector3, Vector3)
	if not (lo and hi) then
		return l, h
	end
	return Vector3.new(math.min(lo.X, l.X), math.min(lo.Y, l.Y), math.min(lo.Z, l.Z)), Vector3.new(math.max(hi.X, h.X), math.max(hi.Y, h.Y), math.max(hi.Z, h.Z))
end

local function num(v: any, default: number): number
	return if type(v) == "number" then v else default
end

local function pairOf(v: any, a: number, b: number): (number, number)
	if typeof(v) == "Vector2" then
		return v.X, v.Y
	elseif type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" then
		return v[1], v[2]
	end
	return a, b
end

-- Route ops place blocks per segment along CFrame.lookAt(mid, next) exactly as MapAdapter does; `blocks` returns each
-- segment's blocks. The station and `every` filters are ignored (every segment counted: a wider box).
type Block = { cf: CFrame, size: Vector3 }
local function perSegment(waypoints: { any }, minLen: number, blocks: (CFrame, number) -> { Block }): (Vector3?, Vector3?)
	local lo: Vector3?, hi: Vector3? = nil, nil
	for i = 1, #waypoints - 1 do
		local a, b = waypoints[i].pos, waypoints[i + 1].pos
		if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then
			error("waypoint " .. i .. " has no position")
		end
		local len = (b - a).Magnitude
		if len > minLen then
			for _, blk in blocks(CFrame.lookAt((a + b) * 0.5, b, Vector3.yAxis), len) do
				local l, h = blockBox(blk.cf, blk.size)
				lo, hi = union(lo, hi, l, h)
			end
		end
	end
	return lo, hi
end

-- The box one shell op can write terrain in, or nil for an op that adds none. Defaults and placement are MapAdapter's
-- (applyShellOp, routeCavern, fillRouteBounds, routeFloorFill). Errors on an op it cannot bound.
function MapCacheRules.opBox(op: any, waypoints: { any }): (Vector3?, Vector3?)
	local kind = op.op
	if kind == "Clear" or kind == "SetMaterialColor" or kind == "CarveRouteTube" then
		return nil, nil -- removes terrain or only recolours it
	elseif kind == "FillBlock" or kind == "FillWedge" then
		if typeof(op.cf) ~= "CFrame" or typeof(op.size) ~= "Vector3" then
			error(kind .. " without a CFrame cf and a Vector3 size")
		end
		return blockBox(op.cf, op.size) -- a wedge is half of its block
	elseif kind == "FillBall" then
		if typeof(op.center) ~= "Vector3" or type(op.r) ~= "number" then
			error("FillBall without a Vector3 center and a number r")
		end
		return cube(op.center, op.r)
	elseif kind == "FillCylinder" then
		if typeof(op.cf) ~= "CFrame" or type(op.h) ~= "number" or type(op.r) ~= "number" then
			error("FillCylinder without a CFrame cf, a number h and a number r")
		end
		-- Terrain:FillCylinder's axis is the CFrame's Y: the cylinder sits inside a (2r, h, 2r) block.
		return blockBox(op.cf, Vector3.new(2 * op.r, op.h, 2 * op.r))
	elseif kind == "RouteCavern" then
		local wallOffset, wallY = num(op.wallOffset, 142), num(op.wallY, 34)
		local wallW, wallH = pairOf(op.wallSize, 48, 136)
		local lenFactor = num(op.wallLenFactor, 4.2)
		local roofOffset = num(op.roofOffset, 146)
		local roofW, roofH = pairOf(op.roofSize, 256, 40)
		local roofExtra = num(op.roofExtraLen, 24)
		return perSegment(waypoints, 0.1, function(arch: CFrame, len: number): { Block }
			local span = len * lenFactor
			return {
				{ cf = arch * CFrame.new(-wallOffset, wallY, 0), size = Vector3.new(wallW, wallH, span) },
				{ cf = arch * CFrame.new(wallOffset, wallY, 0), size = Vector3.new(wallW, wallH, span) },
				{ cf = arch * CFrame.new(0, roofOffset, 0), size = Vector3.new(roofW, roofH, span + roofExtra) },
			}
		end)
	elseif kind == "FillRouteBounds" then
		-- MapAdapter.fillRouteBounds: the waypoints' own box (not segment midpoints), widened.
		local lo, hi = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
		for i, w in waypoints do
			local p = w.pos
			if typeof(p) ~= "Vector3" then
				error("waypoint " .. i .. " has no position")
			end
			lo = Vector3.new(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z))
			hi = Vector3.new(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z))
		end
		if #waypoints == 0 then
			return nil, nil
		end
		local margin = num(op.margin, 280)
		local yMin = num(op.yMin, 0)
		local top = hi.Y + num(op.above, 230)
		return Vector3.new(lo.X - margin, math.min(yMin, top), lo.Z - margin), Vector3.new(hi.X + margin, math.max(yMin, top), hi.Z + margin)
	elseif kind == "RouteFloorFill" then
		local depth, width, thick = num(op.depth, 44), num(op.width, 230), num(op.thickness, 10)
		local crust = num(op.crustRadius, 22) * 1.4 -- a crust cylinder's radius is at most 1.4 x crustRadius
		return perSegment(waypoints, 0.5, function(cf: CFrame, len: number): { Block }
			local out = { { cf = cf * CFrame.new(0, -depth, 0), size = Vector3.new(width, thick, len + 40) } }
			if op.crustMat then
				-- crust discs (4 studs tall) sit within +-0.42 width across and +-len/2 along the segment
				table.insert(out, { cf = cf * CFrame.new(0, -depth + thick * 0.5 + 1, 0), size = Vector3.new(width * 0.84 + 2 * crust, 4, len + 2 * crust) })
			end
			return out
		end)
	end
	error("unknown shell op " .. tostring(kind))
end

-- The world box (studs, voxel-aligned, padded) the cache copies for one map, or nil and the reason it cannot be known.
-- terrainBounds is TrackData.terrainBounds ({min, max}, or {empty = true} for a plan without a height grid); shellOps is
-- the op list (TrackData.shells, or its {ops = ...} form).
function MapCacheRules.terrainBox(terrainBounds: any, shellOps: any, waypoints: { any }): (Box?, string?)
	if type(terrainBounds) ~= "table" then
		return nil, "TrackData has no terrainBounds (rerun tools/map/adapt.py)"
	end
	local lo: Vector3?, hi: Vector3? = nil, nil
	local function add(l: Vector3?, h: Vector3?)
		if l and h then
			lo = if lo then Vector3.new(math.min(lo.X, l.X), math.min(lo.Y, l.Y), math.min(lo.Z, l.Z)) else l
			hi = if hi then Vector3.new(math.max(hi.X, h.X), math.max(hi.Y, h.Y), math.max(hi.Z, h.Z)) else h
		end
	end
	if terrainBounds.empty ~= true then
		if typeof(terrainBounds.min) ~= "Vector3" or typeof(terrainBounds.max) ~= "Vector3" then
			return nil, "terrainBounds without Vector3 min/max"
		end
		add(terrainBounds.min, terrainBounds.max)
	end
	local ops = if type(shellOps) == "table" and type(shellOps.ops) == "table" then shellOps.ops else shellOps
	for i, op in (if type(ops) == "table" then ops else {}) :: { any } do
		local ok, l, h = pcall(MapCacheRules.opBox, op, waypoints)
		if not ok then
			return nil, string.format("shells[%d]: %s", i, tostring(l))
		end
		add(l, h)
	end
	if not (lo and hi) then
		return { lo = Vector3.zero, hi = Vector3.zero, empty = true }, nil
	end
	return MapCacheRules.align(lo :: Vector3, hi :: Vector3), nil
end

-- Snaps a box outward to the voxel grid and pads it by PAD_CELLS voxels.
function MapCacheRules.align(lo: Vector3, hi: Vector3): Box
	local r, pad = MapCacheRules.RES, MapCacheRules.RES * MapCacheRules.PAD_CELLS
	local function down(v: number): number
		return math.floor(v / r) * r - pad
	end
	local function up(v: number): number
		return math.ceil(v / r) * r + pad
	end
	return { lo = Vector3.new(down(lo.X), down(lo.Y), down(lo.Z)), hi = Vector3.new(up(hi.X), up(hi.Y), up(hi.Z)) }
end

export type Cells = { min: { number }, max: { number }, count: number }

-- The voxel-cell corners of an aligned box for Region3int16 (min corner cell, max = the cell at hi, so the region
-- covers [lo, hi] whether Roblox reads Max as inclusive or exclusive). nil when the box is empty or past int16.
function MapCacheRules.cells(box: Box): Cells?
	local r = MapCacheRules.RES
	local mn = { box.lo.X // r, box.lo.Y // r, box.lo.Z // r }
	local mx = { box.hi.X // r, box.hi.Y // r, box.hi.Z // r }
	local count = 1
	for i = 1, 3 do
		if mx[i] <= mn[i] or mn[i] < INT16_MIN or mx[i] > INT16_MAX then
			return nil
		end
		count *= mx[i] - mn[i]
	end
	return { min = mn, max = mx, count = count }
end

-- Least recently used first: `order` is updated in place so `key` is the newest.
function MapCacheRules.touch(order: { string }, key: string)
	local i = table.find(order, key)
	if i then
		table.remove(order, i)
	end
	table.insert(order, key)
end

-- Keys to drop (oldest first, never `pinned`) so at most `max` maps stay cached.
function MapCacheRules.evictions(order: { string }, pinned: string, max: number): { string }
	local out = {}
	local over = #order - max
	for _, k in order do
		if over <= 0 then
			break
		end
		if k ~= pinned then
			table.insert(out, k)
			over -= 1
		end
	end
	return out
end

return MapCacheRules
