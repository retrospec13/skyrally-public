--!strict
-- Per-group terrain (RaceFlowRules.PER_GROUP true only; Studio V6 on b05b627): after a DINO-4 group race the hub's
-- baked plaza terrain was gone on server and clients (0 of 43160 voxels), so every car fell through the plaza and
-- respawned in a loop (reason=Fell, killY -54.2). Root cause: DINO-4's plan opens its shells with { op = "Clear" },
-- and MapAdapter.applyShellOp ran workspace.Terrain:Clear() for it, wiping every map's terrain, the live hub's
-- included. Pinned here:
--   1. shellClear / planShellClear: single race keeps Terrain:Clear(); per group a first build skips the op (its box is
--      empty), a rebuild clears only its own box, and a box that overlaps another writer's terrain is never cleared.
--   2. clearChunks tiles the box exactly, every block inside it and no wider than CLEAR_CHUNK.
--   3. The shipped maps: every race map's terrain box is disjoint from the hub's, and a group's DINO-4 load never
--      clears the hub's box on any load, first or later.
--   4. Wiring: the Clear op goes through the decision, both TrackDirector build paths pass it, and no other server code
--      clears the whole Terrain except the single-race load and MapCache's failed paste (both behind clearTerrain).
-- Run: tools/tests/run_lune_tests.sh tools/tests/pergroup_terrain_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (string, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/RaceInstanceRules.luau")
	local MapCacheRules = h.require("src/shared/MapCacheRules.luau")

	local function box(lx: number, ly: number, lz: number, hx: number, hy: number, hz: number): any
		return { lo = Vector3.new(lx, ly, lz), hi = Vector3.new(hx, hy, hz) }
	end

	local function terrainBoxOf(key: string): any
		local td = h.require("build/" .. key .. "/TrackData.luau")
		local b, why = MapCacheRules.terrainBox(td.terrainBounds, td.shells, td.waypoints or {})
		assert(b, key .. ": " .. tostring(why))
		return b, td
	end

	h.test("shellClear: single race clears all; per group skips a first write, region-clears only a clean rewrite", function()
		local mine = box(0, 0, 0, 100, 100, 100)
		local far = box(500, 0, 500, 600, 100, 600)
		local near = box(90, 0, 90, 200, 100, 200)
		h.eq(R.shellClear(false, false, nil, {}), "all", "single race: Terrain:Clear() as before")
		h.eq(R.shellClear(false, true, mine, { far }), "all")
		h.eq(R.shellClear(true, false, mine, { far }), "skip", "first write: the box is still empty")
		h.eq(R.shellClear(true, true, mine, { far }), "region", "rewrite: Air over its own box only")
		h.eq(R.shellClear(true, true, mine, { far, near }), "skip", "never clear over another map's terrain")
		h.eq(R.shellClear(true, true, nil, {}), "skip", "unknown box: never clear")
		h.eq(R.shellClear(true, true, { lo = Vector3.zero, hi = Vector3.zero, empty = true }, {}), "skip")
		h.ok(R.boxesOverlap(mine, near) and R.boxesOverlap(near, mine))
		h.ok(not R.boxesOverlap(mine, far))
		h.ok(not R.boxesOverlap(mine, box(100, 0, 0, 200, 100, 100)), "touching faces do not overlap")
	end)

	h.test("planShellClear: the ledger over a server's loads (hub boot, two DINO-4 group loads, a single-race clear)", function()
		local written = {}
		local hub, dino = box(-9704, -56, 6496, -6296, 200, 9504), box(-1584, -8, -2356, 824, 456, 492)
		h.eq(R.planShellClear(true, written, "HUB-0", hub), "skip", "boot: the hub's first write")
		h.eq(R.planShellClear(true, written, "DINO-4", dino), "skip", "first DINO-4 group build: the hub stays")
		h.ok(written["DINO-4"] == dino and written["HUB-0"] == hub, "both recorded")
		h.eq(R.planShellClear(true, written, "DINO-4", dino), "region", "rebuild: its own box only")
		h.eq(R.planShellClear(true, written, "X", nil), "skip")
		h.ok(written.X.empty == true, "a nil box is recorded as empty, never region-cleared")
		h.eq(R.planShellClear(false, written, "DINO-4", dino), "all", "single race unchanged")
	end)

	h.test("clearChunks: tiles the box exactly, every block inside it and at most CLEAR_CHUNK wide", function()
		h.eq(R.CLEAR_CHUNK, 512)
		local function check(b: any, edge: number?)
			local e = edge or R.CLEAR_CHUNK
			local vol, want = 0, (b.hi.X - b.lo.X) * (b.hi.Y - b.lo.Y) * (b.hi.Z - b.lo.Z)
			for _, c in R.clearChunks(b, edge) do
				local s = c.hi - c.lo
				h.ok(s.X > 0 and s.Y > 0 and s.Z > 0 and s.X <= e and s.Y <= e and s.Z <= e, "block size " .. tostring(s))
				h.ok(c.lo.X >= b.lo.X and c.lo.Y >= b.lo.Y and c.lo.Z >= b.lo.Z, "inside (lo)")
				h.ok(c.hi.X <= b.hi.X and c.hi.Y <= b.hi.Y and c.hi.Z <= b.hi.Z, "inside (hi)")
				vol += s.X * s.Y * s.Z
			end
			h.ok(math.abs(vol - want) <= want * 1e-6, string.format("volume %.0f vs %.0f", vol, want))
		end
		check(box(0, 0, 0, 1000, 300, 1100))
		check(box(-10, -10, -10, 10, 10, 10), 8)
		local dino = terrainBoxOf("dino4")
		check(dino)
		h.eq(#R.clearChunks(dino), 30, "DINO-4: 5 x 1 x 6 blocks of 512")
		h.eq(#R.clearChunks({ lo = Vector3.zero, hi = Vector3.zero, empty = true }), 0)
		h.eq(#R.clearChunks(box(0, 0, 0, 0, 10, 10)), 0, "degenerate")
	end)

	h.test("shipped maps: every race map's terrain box is disjoint from the hub's; DINO-4 never clears the hub", function()
		local hub = terrainBoxOf("hub0")
		local clears = {}
		for _, key in { "snow1", "island2", "forest1", "space4", "dino4", "teststrip" } do
			local b, td = terrainBoxOf(key)
			h.ok(not R.boxesOverlap(b, hub), key .. "'s terrain box overlaps the hub's plaza")
			for _, op in (if td.shells.ops then td.shells.ops else td.shells) :: { any } do
				if op.op == "Clear" then
					table.insert(clears, key)
				end
			end
		end
		h.eq(clears, { "dino4" }, "the plans with a Clear shell op (each one must stay per-group safe)")
		-- A per-group server: boot hub, then DINO-4 three times (first build, cached, rebuilt): never "all", and a
		-- region clear stays out of the hub's box.
		local written = {}
		R.planShellClear(true, written, "HUB-0", hub)
		local dino = terrainBoxOf("dino4")
		for i = 1, 3 do
			local mode = R.planShellClear(true, written, "DINO-4", dino)
			h.ok(mode ~= "all", "load " .. i .. ": " .. mode)
			if mode == "region" then
				for _, c in R.clearChunks(dino) do
					h.ok(not R.boxesOverlap({ lo = c.lo, hi = c.hi }, hub), "a region block reaches the hub")
				end
			end
		end
	end)

	h.test("wiring: the Clear op goes through shellClear on both build paths; no other whole-Terrain clear", function()
		local ma = h.readFile("src/server/MapAdapter.luau")
		h.contains(ma, 'if kind == "Clear" then\n\t\treturn applyClear(t, clearMode, clearBox)')
		h.contains(ma, "pcall(MapAdapter.applyShellOp, op, waypoints, terrain, o.shellClear, o.clearBox)")
		h.contains(ma, "for _, c in RaceInstanceRules.clearChunks(box) do")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, "local mode = RaceInstanceRules.planShellClear(perGroup, terrainWritten, tostring(td.id), clearBox)")
		h.contains(td, "local buildOpts = buildOptions(td, perGroup)")
		h.contains(td, "local buildOpts = buildOptions(td, true)")
		h.contains(td, "report = MapAdapter.build(td, buildOpts)")
		h.contains(td, "local report = MapAdapter.build(td, buildOpts)")
		h.ok(not string.find(td, "MapAdapter.build(td, { activate = true })", 1, true), "a build without the Clear decision")
		h.contains(td, "\t\tworkspace.Terrain:Clear()\n\t\ttable.clear(terrainWritten)")
		-- Every whole-Terrain clear in server code, by file: the single-race load, MapCache's failed paste (both behind
		-- RaceInstanceRules.clearTerrain) and applyClear's "all".
		local counts: { [string]: number } = {}
		for _, f in { "TrackDirector", "MapCache", "MapAdapter", "CourseCarve", "RaceGroups", "RaceInstance" } do
			local src = h.readFile("src/server/" .. f .. ".luau")
			local n = 0
			for _ in string.gmatch(src, ":Clear%(%)") do
				n += 1
			end
			counts[f] = n
		end
		h.eq(counts, { TrackDirector = 1, MapCache = 1, MapAdapter = 1, CourseCarve = 0, RaceGroups = 0, RaceInstance = 0 })
		h.contains(h.readFile("src/server/MapCache.luau"), "if RaceInstanceRules.clearTerrain(RaceFlowRules.PER_GROUP, false) then\n\t\t\t\tworkspace.Terrain:Clear()")
		h.contains(ma, 'if mode == nil or mode == "all" then\n\t\tt:Clear()')
	end)
end
