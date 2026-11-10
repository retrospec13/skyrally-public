--!strict
-- Lune spec for the backdrop shells (visibility v1; shared/BackdropRules, kit/Backdrop, tools/map/backdrop.py). Owner
-- report 2026-10-20: "too much of the map is constantly not being displayed" (DINO-4 great hall far walls past the
-- client's terrain render distance). On the REAL TrackData of DINO-4, FOREST-1 and SNOW-1:
--   1. every backdrop part passes the independent Luau audit: at least 20 studs outside every Air carve (the route
--      tube at its largest radius), every route and alternate corridor sample and every battle arena; floors inside
--      their solid slab; ring parts beyond the heightfield and the plane leash; cores inside their range wedge; peaks far from the course;
--   2. part counts under 150 per map, sizes <= 2048, unique names, the other maps carry none;
--   3. coverage: from the DINO-4 owner frame, the east leg and the battle arena centre every horizontal direction meets
--      a backdrop wall past the hall's far wall, the ceiling covers the hall, the lava plane covers the hall floor;
--      FOREST-1's ridge rows ring the heightfield on every side;
--   4. purely visual properties (Anchored, CanCollide/CanQuery/CanTouch false, CastShadow false, Massless), the
--      terrain's own MaterialVariant, the Backdrop tag and never MapLight/MapFx, through kit/Backdrop with fake deps;
--   5. the audit catches a part moved into the hall, a floor above its slab, a core outside its wedge, a peak on the course.
-- Run: tools/tests/run_lune_tests.sh tools/tests/backdrop_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	count: ({ string }, string) -> number,
	require: (string) -> any,
	logs: { string },
}

return function(h: Harness)
	local R = h.require("src/shared/BackdropRules.luau")
	local Backdrop = h.require("src/server/kit/Backdrop.luau")
	local dino = h.require("build/dino4/TrackData.luau")
	local forest = h.require("build/forest1/TrackData.luau")
	local snow = h.require("build/snow1/TrackData.luau")

	local function count(td: any, kind: string?): number
		local n = 0
		for _, e in td.backdrop or {} do
			if kind == nil or e.kind == kind then
				n += 1
			end
		end
		return n
	end

	-- the first backdrop part a horizontal ray from `from` meets (10-stud steps), and how far out
	local function rayHit(td: any, from: Vector3, dir: Vector3, maxDist: number, kinds: { [string]: boolean }): (any, number)
		for d = 0, maxDist, 10 do
			local p = from + dir * d
			for _, e in td.backdrop do
				if kinds[e.kind] and R.pointBoxDistance({ cf = e.cf, half = e.size * 0.5 }, p) < 6 then
					return e, d
				end
			end
		end
		return nil, math.huge
	end

	h.test("audit: every DINO-4, FOREST-1 and SNOW-1 backdrop part keeps every clearance rule", function()
		for _, td in { dino, forest, snow } do
			local bad = R.audit(td)
			h.eq(#bad, 0, td.id .. ": " .. table.concat(bad, " | "))
		end
	end)

	h.test("counts: under 150 parts per map, the expected generators, nothing on the other maps", function()
		h.ok(count(dino) >= 30 and count(dino) < R.MAX_PARTS, "DINO-4 " .. count(dino))
		h.ok(count(dino, "shell") >= 20, "DINO-4 cave walls and ceiling")
		h.ok(count(dino, "floor") >= 6, "DINO-4 lava plane")
		h.ok(count(forest, "ring") >= 60 and count(forest) < R.MAX_PARTS, "FOREST-1 ridges " .. count(forest))
		h.ok(count(snow, "core") >= 40 and count(snow, "peak") >= 40 and count(snow) < R.MAX_PARTS, "SNOW-1 range cores and far peaks " .. count(snow))
		for _, key in { "hub0", "island2", "space4", "teststrip" } do
			local td = h.require("build/" .. key .. "/TrackData.luau")
			h.eq(count(td), 0, key .. " carries no backdrop (analysis: low risk, left alone)")
		end
	end)

	h.test("sizes and names: every axis <= 2048, unique Backdrop_ names, upright", function()
		for _, td in { dino, forest, snow } do
			local seen = {}
			for _, e in td.backdrop do
				h.ok(math.max(e.size.X, e.size.Y, e.size.Z) <= R.MAX_AXIS, e.name)
				h.ok(string.sub(e.name, 1, 9) == "Backdrop_", e.name)
				h.ok(not seen[e.name], "duplicate " .. e.name)
				seen[e.name] = true
				h.ok(e.cf.UpVector.Y > 0.999, e.name .. " upright")
			end
		end
	end)

	h.test("DINO-4 coverage: walls all round the owner frame, the east leg and the arena; ceiling and lava plane", function()
		local walls = { shell = true }
		-- hall far walls (analysis): x -880..120, z -1650..-450 (balls to -970/210, -1715/-385)
		local views = {
			{ "D1 owner frame", Vector3.new(-700, 100, -880) },
			{ "D2 east leg", Vector3.new(-110, 105, -900) },
			{ "D4 south-west leg", Vector3.new(-700, 75, -1590) },
			{ "D5 arena centre", Vector3.new(-580, 110, -1340) },
		}
		for _, v in views do
			for k = 0, 23 do
				local a = math.rad(k * 15)
				local dir = Vector3.new(math.cos(a), 0, math.sin(a))
				local e, d = rayHit(dino, v[2], dir, 2400, walls)
				h.ok(e ~= nil, string.format("%s yaw %d meets a wall", v[1], k * 15))
				-- past the carved hall: never in front of the real terrain wall
				local edge = v[2] + dir * d
				h.ok(edge.X <= -880 - 20 or edge.X >= 120 + 20 or edge.Z <= -1650 - 20 or edge.Z >= -450 + 20,
					string.format("%s yaw %d wall at %s is outside the hall", v[1], k * 15, tostring(edge)))
			end
		end
		for _, p in { Vector3.new(-380, 0, -1050), Vector3.new(-640, 0, -800), Vector3.new(-580, 0, -1340), Vector3.new(-100, 0, -1500) } do
			local ceil, dc = rayHit(dino, p + Vector3.new(0, 250, 0), Vector3.new(0, 1, 0), 300, walls)
			h.ok(ceil ~= nil and 250 + dc > 390, "ceiling above the domes over " .. tostring(p))
			local floor = rayHit(dino, p + Vector3.new(0, 30, 0), Vector3.new(0, -1, 0), 40, { floor = true })
			h.ok(floor ~= nil, "lava plane under " .. tostring(p))
			if floor then
				h.eq(floor.material, "CrackedLava")
				h.ok(floor.cf.Position.Y + floor.size.Y / 2 <= 14 - R.FLOOR_SINK, "under the lava surface (slab top 14)")
			end
		end
	end)

	h.test("FOREST-1 coverage: ridge rows on every side of the heightfield, tops under the flight high point + 100", function()
		local mn, mx = forest.terrainBounds.min, forest.terrainBounds.max
		local c = (mn + mx) * 0.5
		for k = 0, 23 do
			local a = math.rad(k * 15)
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			local e = rayHit(forest, Vector3.new(c.X, 120, c.Z), dir, 3200, { ring = true })
			h.ok(e ~= nil, "a ridge at yaw " .. k * 15)
		end
		for _, e in forest.backdrop do
			h.ok(e.cf.Position.Y + e.size.Y / 2 <= 240 + 100, e.name .. " top under 340")
		end
	end)

	h.test("SNOW-1 cores: each sits in a far Rock/Snow range wedge with its colour (the peaks never float alone)", function()
		local n = 0
		for _, e in snow.backdrop do
			if e.kind == "core" then
				n += 1
				local src = snow.shells[e.source + 1]
				h.eq(src.op, "FillWedge")
				h.eq(e.material, src.mat)
				h.eq(e.color, snow.materials.terrainColors[src.mat])
			end
		end
		h.ok(n >= 40, "cores " .. n)
	end)

	h.test("SNOW-1 peaks: snow caps are SmoothPlastic white, the rock slate blue, every part a wedge", function()
		for _, e in snow.backdrop do
			if e.kind == "peak" then
				h.eq(e.shape, "Wedge")
				if string.sub(e.name, -3) == "Cap" then
					h.eq(e.material, "SmoothPlastic")
					h.eq(e.color, "#eef3fb")
				else
					h.eq(e.material, "Rock")
				end
			else
				h.eq(e.kind, "core")
			end
		end
	end)

	h.test("properties: purely visual, terrain MaterialVariant, built by kit/Backdrop with the tag and no light attrs", function()
		local e = dino.backdrop[1]
		local p = R.props(e, dino.materials)
		h.eq(p.Anchored, true)
		h.eq(p.CanCollide, false)
		h.eq(p.CanQuery, false)
		h.eq(p.CanTouch, false)
		h.eq(p.CastShadow, false)
		h.eq(p.Massless, true)
		h.eq(p.MaterialVariant, "SR_DINO_CaveRock", "the wall wears the terrain's own rock")
		h.eq(R.props(forest.backdrop[#forest.backdrop], forest.materials).MaterialVariant, "", "SmoothPlastic far row")

		local made, tagged = {}, 0
		local deps = {
			new = function(className: string): any
				local inst = { ClassName = className, attrs = {} }
				function inst:SetAttribute(k, v)
					self.attrs[k] = v
				end
				table.insert(made, inst)
				return inst
			end,
			tag = function(_inst: any)
				tagged += 1
			end,
			material = function(name: string): any
				return "Material." .. name
			end,
			color = function(hex: string): any
				return hex
			end,
			smooth = "SurfaceType.Smooth",
		}
		for _, td in { dino, forest, snow } do
			table.clear(made)
			tagged = 0
			local folder = {}
			local n = Backdrop.build(td, folder, deps)
			h.eq(n, #td.backdrop, td.id .. " built every entry")
			h.eq(tagged, n, td.id .. " every part tagged " .. R.TAG)
			for i, inst in made do
				local src = td.backdrop[i]
				h.eq(inst.ClassName, if src.shape == "Wedge" then "WedgePart" else "Part")
				h.eq(inst.CanCollide, false)
				h.eq(inst.CanQuery, false)
				h.eq(inst.CanTouch, false)
				h.eq(inst.CastShadow, false)
				h.eq(inst.Anchored, true)
				h.eq(inst.Parent, folder)
				h.eq(inst.CFrame, src.cf)
				h.eq(inst.Size, src.size)
				h.eq(inst.Material, "Material." .. src.material)
				h.eq(inst.attrs.MapLight, nil)
				h.eq(inst.attrs.MapFx, nil)
				h.eq(inst.attrs.Backdrop, src.kind)
			end
		end
		h.eq(Backdrop.build({ backdrop = nil }, {}, deps), 0, "no list, no parts")
	end)

	h.test("audit negatives: a wall in the hall, a floor over its slab, a peak on the course are all caught", function()
		local function withEntry(td: any, e: any): any
			local copy = table.clone(td)
			copy.backdrop = { e }
			return copy
		end
		local wall = table.clone(dino.backdrop[1])
		wall.cf = CFrame.new(-380, 130, -1050)
		h.ok(#R.audit(withEntry(dino, wall)) > 0, "a wall in the middle of the hall")
		local nearTube = table.clone(dino.backdrop[1])
		nearTube.cf = CFrame.new(dino.waypoints[60].pos + Vector3.new(0, 0, 50))
		nearTube.size = Vector3.new(40, 40, 8)
		h.ok(#R.audit(withEntry(dino, nearTube)) > 0, "a wall 50 studs off the line")
		local floor = nil
		for _, e in dino.backdrop do
			if e.kind == "floor" then
				floor = table.clone(e)
				break
			end
		end
		floor.cf = floor.cf + Vector3.new(0, 6, 0)
		local bad = R.audit(withEntry(dino, floor))
		h.ok(#bad > 0 and string.find(table.concat(bad), "slab top") ~= nil, "a floor at the lava surface")
		local firstCore, firstPeak
		for _, e in snow.backdrop do
			if e.kind == "core" and not firstCore then
				firstCore = e
			elseif e.kind == "peak" and not firstPeak then
				firstPeak = e
			end
		end
		local core = table.clone(firstCore)
		core.cf = core.cf + Vector3.new(0, 40, 0)
		h.ok(string.find(table.concat(R.audit(withEntry(snow, core))), "inside its source wedge") ~= nil, "a core poking out")
		local peak = table.clone(firstPeak)
		peak.cf = CFrame.new(snow.waypoints[1].pos)
		h.ok(#R.audit(withEntry(snow, peak)) > 0, "a peak on the course")
		local ring = table.clone(forest.backdrop[1])
		ring.cf = CFrame.new(forest.waypoints[1].pos)
		h.ok(#R.audit(withEntry(forest, ring)) > 0, "a ridge on the course")
	end)

	h.test("geometry: box gap, wedge half-spaces", function()
		local a = { cf = CFrame.new(0, 0, 0), half = Vector3.new(5, 5, 5) }
		local b = { cf = CFrame.new(30, 0, 0), half = Vector3.new(5, 5, 5) }
		h.ok(math.abs(R.boxGap(a, b) - 20) < 1e-3, "axis gap")
		h.ok(R.boxGap(a, { cf = CFrame.new(8, 0, 0), half = Vector3.new(5, 5, 5) }) < 0, "overlap")
		local cf = CFrame.new(10, 20, 30) * CFrame.Angles(0, math.rad(37), 0)
		local planes, verts = R.wedge(cf, Vector3.new(40, 30, 60))
		for _, v in verts do
			for _, pl in planes do
				h.ok(pl.n:Dot(v) <= pl.d + 1e-3, "vertex inside its own wedge (float32 Vector3)")
			end
		end
		-- the slope faces local -Z: the top front edge is outside, the top back edge inside
		local function inside(p: Vector3): boolean
			for _, pl in planes do
				if pl.n:Dot(p) > pl.d + 1e-3 then
					return false
				end
			end
			return true
		end
		h.ok(not inside(cf:PointToWorldSpace(Vector3.new(0, 14, -29))), "top front is empty")
		h.ok(inside(cf:PointToWorldSpace(Vector3.new(0, 14, 29))), "top back is solid")
	end)
end
