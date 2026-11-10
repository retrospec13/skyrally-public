--!strict
-- Lune spec for the map cache rules (shared/MapCacheRules; TEST_LIST L42, also L41: every track switch rebuilt the whole
-- map and its terrain from scratch):
--   1. The Studio-only MapCacheOff bypass, and only clean finished builds are cached.
--   2. The terrain box holds every voxel a build can write: each shell op's box holds the op's real fills (the corners
--      of each FillBlock MapAdapter's route ops place, computed the same way), the builder's height-grid box from
--      TrackData.terrainBounds, voxel alignment with a one-cell pad, int16 cell range.
--   3. Every shipped TrackData carries terrainBounds and gives a box (so every map, the hub first, is cacheable).
--   4. Least-recently-used eviction never drops the hub.
--   5. Source guards: TrackDirector.load restores before running the builder and snapshots right after the build;
--      MapAdapter.activate redoes everything a build does outside the map root; MapCache honours the bypass.
-- Run: tools/tests/run_lune_tests.sh tools/tests/mapcache_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/MapCacheRules.luau")

	local function inside(p: Vector3, lo: Vector3, hi: Vector3): boolean
		local e = 1e-2 -- Vector3 is float32
		return p.X >= lo.X - e and p.Y >= lo.Y - e and p.Z >= lo.Z - e and p.X <= hi.X + e and p.Y <= hi.Y + e and p.Z <= hi.Z + e
	end

	local function blockCorners(cf: CFrame, size: Vector3): { Vector3 }
		local out = {}
		for _, sx in { -0.5, 0.5 } do
			for _, sy in { -0.5, 0.5 } do
				for _, sz in { -0.5, 0.5 } do
					table.insert(out, (cf * CFrame.new(size.X * sx, size.Y * sy, size.Z * sz)).Position)
				end
			end
		end
		return out
	end

	local function allInside(points: { Vector3 }, lo: Vector3, hi: Vector3): boolean
		for _, p in points do
			if not inside(p, lo, hi) then
				return false
			end
		end
		return true
	end

	-- A pitched, turning route (the case a flat box estimate would miss).
	local route = {}
	for i = 0, 20 do
		local a = i * 0.3
		table.insert(route, { pos = Vector3.new(math.cos(a) * 400, 50 + i * 12, math.sin(a) * 400), station = i * 120 })
	end

	h.test("enabled: MapCacheOff bypasses only in Studio; cacheable: a finished build with no errors", function()
		h.ok(R.enabled(false, nil) and R.enabled(true, nil) and R.enabled(true, false))
		h.ok(not R.enabled(true, true), "Studio QA bypass")
		h.ok(R.enabled(false, true), "a live server ignores the attribute")
		h.ok(R.cacheable(true, 0))
		h.ok(not R.cacheable(false, 0), "builder timed out: partial map")
		h.ok(not R.cacheable(true, 2), "a failed asset load gets another full build")
	end)

	h.test("opBox: plain fills hold their rotated corners; removals and colours add no box; unknown ops refuse", function()
		local cf = CFrame.new(100, 20, -50) * CFrame.Angles(0.4, 1.1, -0.3)
		local size = Vector3.new(300, 40, 120)
		for _, kind in { "FillBlock", "FillWedge" } do
			local lo, hi = R.opBox({ op = kind, cf = cf, size = size }, route)
			h.ok(allInside(blockCorners(cf, size), lo, hi), kind)
		end
		local lo, hi = R.opBox({ op = "FillBall", center = Vector3.new(1, 2, 3), r = 10 }, route)
		h.eq({ lo.X, lo.Y, hi.Z }, { -9, -8, 13 })
		local ccf = CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, math.rad(90))
		lo, hi = R.opBox({ op = "FillCylinder", cf = ccf, h = 60, r = 25 }, route)
		h.ok(allInside(blockCorners(ccf, Vector3.new(50, 60, 50)), lo, hi), "cylinder within its bounding block")
		for _, kind in { "Clear", "SetMaterialColor", "CarveRouteTube" } do
			local l2, h2 = R.opBox({ op = kind }, route)
			h.ok(l2 == nil and h2 == nil, kind)
		end
		h.ok(not pcall(R.opBox, { op = "Smooth" }, route), "unknown op")
		h.ok(not pcall(R.opBox, { op = "FillBlock", cf = { 0, 0, 0 }, size = size }, route), "untyped cf")
	end)

	h.test("opBox RouteCavern: every wall and roof FillBlock MapAdapter.routeCavern places is inside", function()
		local op = { op = "RouteCavern", every = 1, wallOffset = 150, wallSize = { 60, 140 }, roofSize = { 300, 50 } }
		local lo, hi = R.opBox(op, route)
		local corners = {}
		for i = 1, #route - 1 do -- MapAdapter.routeCavern's placement, every segment
			local p1, p2 = route[i].pos, route[i + 1].pos
			local arch = CFrame.lookAt((p1 + p2) * 0.5, p2)
			local span = (p2 - p1).Magnitude * 4.2
			for _, c in blockCorners(arch * CFrame.new(-150, 34, 0), Vector3.new(60, 140, span)) do
				table.insert(corners, c)
			end
			for _, c in blockCorners(arch * CFrame.new(150, 34, 0), Vector3.new(60, 140, span)) do
				table.insert(corners, c)
			end
			for _, c in blockCorners(arch * CFrame.new(0, 146, 0), Vector3.new(300, 50, span + 24)) do
				table.insert(corners, c)
			end
		end
		h.ok(allInside(corners, lo, hi))
	end)

	h.test("opBox RouteFloorFill and FillRouteBounds: the floor slabs, crust discs and the route mass are inside", function()
		local op = { op = "RouteFloorFill", depth = 44, width = 230, thickness = 10, crustMat = "Basalt", crustRadius = 22 }
		local lo, hi = R.opBox(op, route)
		local corners = {}
		for i = 1, #route - 1 do -- MapAdapter.routeFloorFill
			local a, b = route[i].pos, route[i + 1].pos
			local len = (b - a).Magnitude
			local cf = CFrame.lookAt((a + b) * 0.5, b, Vector3.yAxis)
			for _, c in blockCorners(cf * CFrame.new(0, -44, 0), Vector3.new(230, 10, len + 40)) do
				table.insert(corners, c)
			end
			-- the widest crust disc at the extreme of its placement range
			for _, side in { -1, 1 } do
				for _, along in { -0.5, 0.5 } do
					local r = 22 * 1.4
					local dcf = cf * CFrame.new(side * 230 * 0.42, -44 + 5 + 1, along * len)
					for _, c in blockCorners(dcf, Vector3.new(2 * r, 4, 2 * r)) do
						table.insert(corners, c)
					end
				end
			end
		end
		h.ok(allInside(corners, lo, hi))
		local blo, bhi = R.opBox({ op = "FillRouteBounds", margin = 280, yMin = 0, above = 310 }, route)
		h.eq({ blo.Y, bhi.Y }, { 0, 50 + 20 * 12 + 310 })
		local minX, maxX = math.huge, -math.huge
		for _, w in route do
			minX, maxX = math.min(minX, w.pos.X), math.max(maxX, w.pos.X)
		end
		h.ok(math.abs(blo.X - (minX - 280)) < 1e-2 and math.abs(bhi.X - (maxX + 280)) < 1e-2)
	end)

	h.test("terrainBox: needs terrainBounds; unions the grid and the ops; aligned to 4 studs with a one-cell pad", function()
		local none, why = R.terrainBox(nil, {}, route)
		h.ok(none == nil and type(why) == "string" and string.find(why, "terrainBounds") ~= nil, "old TrackData: no cache")
		local bad, why2 = R.terrainBox({ empty = true }, { { op = "Smooth" } }, route)
		h.ok(bad == nil and string.find(why2 :: string, "shells%[1%]") ~= nil, "an op it cannot bound: no cache")
		local empty = R.terrainBox({ empty = true }, { { op = "SetMaterialColor" } }, route)
		h.ok(empty and empty.empty == true, "no terrain at all")
		local box = R.terrainBox({ min = Vector3.new(-101, -50, 3), max = Vector3.new(97, 190, 801) }, { ops = { { op = "FillBall", center = Vector3.new(0, 300, 0), r = 10 } } }, route)
		h.eq({ box.lo.X, box.lo.Y, box.lo.Z }, { -108, -56, -16 })
		h.eq({ box.hi.X, box.hi.Y, box.hi.Z }, { 104, 316, 808 })
		local cells = R.cells(box)
		h.eq(cells.min, { -27, -14, -4 })
		h.eq(cells.max, { 26, 79, 202 })
		h.eq(cells.count, 53 * 93 * 206)
		h.eq(R.cells({ lo = Vector3.new(0, 0, 0), hi = Vector3.new(140000, 8, 8) }), nil, "past int16")
	end)

	h.test("every shipped map: terrainBounds present, a box that holds the grid and every op, inside int16", function()
		for _, key in { "hub0", "snow1", "island2", "forest1", "space4", "dino4", "teststrip" } do
			local td = h.require("build/" .. key .. "/TrackData.luau")
			h.ok(type(td.terrainBounds) == "table", key .. " has terrainBounds (tools/map/adapt.py)")
			local box, why = R.terrainBox(td.terrainBounds, td.shells, td.waypoints)
			h.ok(box ~= nil, key .. ": " .. tostring(why))
			if box and not box.empty then
				if td.terrainBounds.min then
					h.ok(inside(td.terrainBounds.min, box.lo, box.hi) and inside(td.terrainBounds.max, box.lo, box.hi), key .. " grid")
				end
				for i, op in td.shells do
					local lo, hi = R.opBox(op, td.waypoints)
					if lo and hi then
						h.ok(inside(lo, box.lo, box.hi) and inside(hi, box.lo, box.hi), key .. " shells[" .. i .. "]")
					end
				end
				local cells = R.cells(box)
				h.ok(cells ~= nil, key .. " cells in int16")
				for _, v in { box.lo.X, box.lo.Y, box.lo.Z, box.hi.X, box.hi.Y, box.hi.Z } do
					h.eq(v % 4, 0, key .. " aligned")
				end
			end
		end
		-- The hub's builder grid alone (tools/map30 buildTerrain: x0 -9080, 271 x 8-stud nodes; floor -48; top 188).
		local hub = h.require("build/hub0/TrackData.luau").terrainBounds
		h.eq({ hub.min.X, hub.min.Y, hub.max.X, hub.max.Y }, { -9080, -52, -6920, 196 })
	end)

	h.test("touch / evictions: least recently used first, the hub is never evicted", function()
		local order = {}
		for _, k in { "hub0", "snow1", "island2", "forest1" } do
			R.touch(order, k)
		end
		R.touch(order, "snow1")
		h.eq(order, { "hub0", "island2", "forest1", "snow1" })
		h.eq(R.evictions(order, "hub0", 2), { "island2", "forest1" })
		h.eq(R.evictions(order, "hub0", 6), {})
		h.eq(R.evictions({ "hub0", "a" }, "hub0", 1), { "a" })
		h.ok(R.MAX_MAPS >= 6, "the hub and the five race zones all fit")
	end)

	h.test("source guards: restore before the builder, snapshot right after the build, activate covers the globals", function()
		local director = h.readFile("src/server/TrackDirector.luau")
		local loadAt = string.find(director, "MapCache.load(key, td)", 1, true)
		local builderAt = string.find(director, "pcall(require, clone)", 1, true)
		local buildAt = string.find(director, "report = MapAdapter.build(td, buildOpts)", 1, true)
		local storeAt = string.find(director, "MapCache.store(key, td, report, TrackDirector.HUB_KEY)", 1, true)
		local findsAt = string.find(director, "TrackDirector.buildFindMarkers(root, td.hub)", 1, true)
		h.ok(loadAt and builderAt and buildAt and storeAt and findsAt, "all present")
		h.ok((loadAt :: number) < (builderAt :: number), "a cached load skips the builder")
		h.ok((buildAt :: number) < (storeAt :: number) and (storeAt :: number) < (findsAt :: number), "snapshot before the hub finds")
		-- Nothing may yield between the build and the snapshot (the map would change under it).
		local between = string.sub(director, buildAt :: number, storeAt :: number)
		h.ok(string.find(between, "task.wait", 1, true) == nil and string.find(between, "WaitForChild", 1, true) == nil)

		local adapter = h.readFile("src/server/MapAdapter.luau")
		local activate = string.sub(adapter, (string.find(adapter, "function MapAdapter.activate", 1, true)) :: number)
		for _, needle in { "applyLighting(td, id)", "applyTerrainOverrides(td.materials)", "publishGlobals(", "registerTrack(", 'SetAttribute("TrackReady", true)' } do
			h.ok(string.find(activate, needle, 1, true) ~= nil, "activate: " .. needle)
		end
		-- The build path uses the same helpers, so the two cannot drift.
		local build = string.sub(adapter, (string.find(adapter, "function MapAdapter.build", 1, true)) :: number, (string.find(adapter, "function MapAdapter.activate", 1, true)) :: number)
		for _, needle in { "applyLighting(td, id)", "applyTerrainOverrides(m)", "publishGlobals(", "registerTrack(" } do
			h.ok(string.find(build, needle, 1, true) ~= nil, "build: " .. needle)
		end

		local cache = h.readFile("src/server/MapCache.luau")
		h.ok(string.find(cache, 'MapCacheRules.enabled(RunService:IsStudio(), workspace:GetAttribute("MapCacheOff"))', 1, true) ~= nil)
		h.ok(string.find(cache, "CopyRegion", 1, true) ~= nil and string.find(cache, "PasteRegion", 1, true) ~= nil)
		h.ok(string.find(cache, "Server memory", 1, true) ~= nil, "the memory cost is written down")
	end)
end
