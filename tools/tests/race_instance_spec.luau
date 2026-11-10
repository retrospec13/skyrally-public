-- Per-group races (economy v3 phase 2, shared/RaceInstanceRules; docs/design/PER_GROUP_RACES.md): the RaceInstance
-- lifecycle and seats, bots per field (humans in that field, not players on the server), the attribute shim's reads and
-- write targets, what a map load keeps, zone lookup by position over the real maps' boxes, and the flags that keep the
-- single-race path exactly as before (PER_GROUP false, server size and field size both 8).
return function(h)
	local R = h.require("src/shared/RaceInstanceRules.luau")
	local RaceFlowRules = h.require("src/shared/RaceFlowRules.luau")
	local PlaneConfig = h.require("src/shared/PlaneConfig.luau")

	h.test("defaults: PER_GROUP off; server 8 and field 8 as separate numbers; hub seats their own", function()
		h.eq(RaceFlowRules.PER_GROUP, false, "per-group races stay off until measured")
		h.eq(PlaneConfig.SERVER_SIZE, 8)
		h.eq(PlaneConfig.AI_FIELD_SIZE, 8)
		h.eq(PlaneConfig.HUB_SEATS, 8)
		h.ok(R.serverWritesLighting(RaceFlowRules.PER_GROUP), "single race: the server still lights the map")
	end)

	h.test("lifecycle: loading -> grid -> racing -> results -> grid (again) / closed; no skipped steps", function()
		local inst = R.new(1, "snow1", "SNOW-1", "SNOW", "race", 8)
		h.eq(inst.state, "loading")
		h.ok(not R.transition(inst, "racing"), "cannot race before the grid")
		h.eq(inst.state, "loading")
		h.ok(R.transition(inst, "grid"))
		h.eq(inst.seq, 1, "entering the grid starts race 1")
		h.ok(R.transition(inst, "racing"))
		h.ok(not R.transition(inst, "grid"), "no grid mid-race")
		h.ok(R.transition(inst, "results"))
		h.ok(R.transition(inst, "grid"), "FLY AGAIN on the same map")
		h.eq(inst.seq, 2)
		h.ok(R.transition(inst, "closed"))
		h.ok(not R.transition(inst, "grid"), "closed is final")
		local failed = R.new(2, "dino4", "DINO-4", "DINO", "race", 8)
		h.ok(R.transition(failed, "closed"), "a failed load closes straight from loading")
	end)

	h.test("seats: join while loading or on the grid, never mid-race or past the field; leave frees a seat", function()
		local inst = R.new(1, "snow1", "SNOW-1", "SNOW", "race", 3)
		h.ok(R.join(inst, 101) and R.join(inst, 102))
		h.ok(R.join(inst, 101), "joining twice is a no-op")
		h.eq(inst.count, 2)
		h.ok(R.join(inst, 103))
		h.ok(not R.join(inst, 104), "field of 3 is full")
		h.ok(R.leave(inst, 102) and not R.leave(inst, 102))
		R.transition(inst, "grid")
		h.ok(R.join(inst, 104), "a freed seat on the grid")
		R.transition(inst, "racing")
		R.leave(inst, 104)
		h.ok(not R.join(inst, 105), "mid-race joins wait for the next lobby")
		R.leave(inst, 101)
		R.leave(inst, 103)
		h.ok(R.empty(inst))
		h.eq(R.new(9, "k", "K", "Z", "race", 0).field, 1, "a field always has a seat")
	end)

	h.test("botsNeeded per field: field minus the humans IN THAT FIELD, capped by the roster", function()
		h.eq(R.botsNeeded(1, 8, 7), 7, "solo")
		h.eq(R.botsNeeded(0, 8, 7), 7, "empty field counts one seat as human")
		h.eq(R.botsNeeded(3, 8, 7), 5)
		h.eq(R.botsNeeded(8, 8, 7), 0)
		h.eq(R.botsNeeded(12, 8, 7), 0, "never negative")
		h.eq(R.botsNeeded(1, 8, 4), 4, "roster cap")
		-- Two groups on a 16-player server: 3 humans in one field, 1 in the other; the server count never enters.
		h.eq(R.botsNeeded(R.fieldHumans(true, 16, 3), 8, 7), 5)
		h.eq(R.botsNeeded(R.fieldHumans(true, 16, 1), 8, 7), 7)
		-- Single race: every player on the server counts, exactly as RaceManager did before phase 2.
		h.eq(R.fieldHumans(false, 5, 4), 5)
		h.eq(R.fieldHumans(RaceFlowRules.PER_GROUP, 6, 2), 6, "default path unchanged")
	end)

	h.test("attribute shim: single race reads and writes workspace; per group a shimmed name lives on the root", function()
		local world = { RaceMode = "hub", RaceGoTime = 10, Unshimmed = "w" }
		local root = { RaceMode = "race", RaceGoTime = 42 }
		local function worldGet(n)
			return world[n]
		end
		local function rootGet(n)
			return root[n]
		end
		h.eq(R.read("RaceMode", false, rootGet, worldGet), "hub", "single race ignores any root")
		h.eq(R.read("RaceMode", true, rootGet, worldGet), "race", "per group: the instance's mode")
		h.eq(R.read("RaceGoTime", true, rootGet, worldGet), 42)
		h.eq(R.read("RaceResetSeq", true, rootGet, worldGet), nil, "never falls back to another race's workspace value")
		h.eq(R.read("Unshimmed", true, rootGet, worldGet), "w", "unshimmed names stay on workspace")
		h.eq(R.read("RaceMode", true, nil, worldGet), "hub", "no instance (the hub): workspace")
		for _, name in { "RaceMode", "ActiveTrackId", "ActiveZone", "RaceGoTime", "RaceResetSeq" } do
			h.ok(R.shimmed(name), name .. " is shimmed")
			h.eq(R.writeTarget(name, false), "world")
			h.eq(R.writeTarget(name, true), "root")
		end
		h.ok(not R.shimmed("TrackSwitching"), "server-wide flags stay on workspace")
		h.eq(R.writeTarget("TrackSwitching", true), "world")
	end)

	h.test("map load: single race clears every map and Terrain (not on boot); per group keeps the others", function()
		h.ok(not R.keepMap(false, "HUB-0", "snow1", "SNOW-1"), "single race: the hub goes")
		h.ok(not R.keepMap(false, "SNOW-1", "snow1", "SNOW-1"))
		h.ok(R.clearTerrain(false, false) and not R.clearTerrain(false, true), "boot load has nothing to clear")
		h.ok(R.keepMap(true, "HUB-0", "snow1", "SNOW-1"), "per group: the hub stays live")
		h.ok(R.keepMap(true, "DINO-4", "snow1", "SNOW-1"), "another group's map stays")
		h.ok(not R.keepMap(true, "SNOW-1", "snow1", "SNOW-1"), "a stale copy of this map is replaced")
		h.ok(not R.keepMap(true, "snow1", "snow1", nil))
		h.ok(not R.clearTerrain(true, false), "per group never clears Terrain")
		h.ok(not R.serverWritesLighting(true), "per group: clients light their own zone")
	end)

	-- The real plans' boxes (build/*/TrackData.luau terrainBounds and waypoints), read as text so the spec needs no map
	-- module: every zone a group can race in must have a box, and no two zones' boxes may overlap.
	local function planBox(key)
		local src = h.readFile("build/" .. key .. "/TrackData.luau")
		local zone = string.match(src, '\n\tzone = "([^"]+)"')
		local lighting = string.match(src, '\n\tlighting = "([^"]+)"')
		local tb = string.match(src, "\n\tterrainBounds = (%b{})")
		local td = { zone = zone, lighting = lighting, waypoints = {} }
		local a, b, c, d, e, f = string.match(tb or "", "min = Vector3%.new%(([%-%d%.]+), ([%-%d%.]+), ([%-%d%.]+)%), max = Vector3%.new%(([%-%d%.]+), ([%-%d%.]+), ([%-%d%.]+)%)")
		if a then
			td.terrainBounds = { min = Vector3.new(tonumber(a), tonumber(b), tonumber(c)), max = Vector3.new(tonumber(d), tonumber(e), tonumber(f)) }
		end
		local wps = string.match(src, "\n\twaypoints = (%b{})") or ""
		for x, y, z in string.gmatch(wps, "pos = Vector3%.new%(([%-%d%.]+), ([%-%d%.]+), ([%-%d%.]+)%)") do
			table.insert(td.waypoints, { pos = Vector3.new(tonumber(x), tonumber(y), tonumber(z)) })
		end
		return R.zoneBox(td)
	end

	h.test("zone lookup by position: every real map has a box, boxes are disjoint, height never decides", function()
		local keys = { "hub0", "dino4", "snow1", "island2", "forest1", "space4" }
		local boxes = {}
		for _, k in keys do
			local b = planBox(k)
			h.ok(b ~= nil, k .. " has a zone box")
			if b then
				table.insert(boxes, b)
			end
		end
		for i = 1, #boxes do
			for j = i + 1, #boxes do
				local p, q = boxes[i], boxes[j]
				local overlap = p.minX < q.maxX and q.minX < p.maxX and p.minZ < q.maxZ and q.minZ < p.maxZ
				h.ok(not overlap, p.zone .. " and " .. q.zone .. " boxes are disjoint")
			end
		end
		local function find(zone)
			for _, b in boxes do
				if b.zone == zone then
					return b
				end
			end
			return nil
		end
		h.eq(R.zoneAt(Vector3.new(-8150, 37, 7882), boxes, nil).zone, "HUB", "the plaza's ISLAND arch")
		h.eq(R.zoneAt(Vector3.new(-8150, 5000, 7882), boxes, nil).zone, "HUB", "high above still the hub")
		h.eq(R.zoneAt(Vector3.new(0, 140, 0), boxes, nil).zone, "DINO", "DINO-4 start (no terrain bounds: route box)")
		h.eq(R.zoneAt(Vector3.new(-8000, 100, 0), boxes, nil).zone, "SNOW")
		h.eq(R.zoneAt(Vector3.new(7600, 0, 7000), boxes, nil).zone, "SPACE")
		local hub = find("HUB")
		h.eq(R.zoneAt(Vector3.new(40000, 0, 40000), boxes, hub), hub, "open sky keeps the current zone")
		h.eq(R.zoneAt(Vector3.new(40000, 0, 40000), boxes, nil), nil)
		h.eq(hub and hub.profile, "HUB-0", "the box carries the plan's lighting profile")
	end)

	h.test("zone lookup: overlapping boxes pick the smaller one; boxes from plans without data are nil", function()
		local big = { zone = "BIG", profile = "B", minX = 0, minZ = 0, maxX = 100, maxZ = 100 }
		local small = { zone = "SMALL", profile = "S", minX = 40, minZ = 40, maxX = 60, maxZ = 60 }
		h.eq(R.zoneAt(Vector3.new(50, 0, 50), { big, small }, nil).zone, "SMALL")
		h.eq(R.zoneAt(Vector3.new(10, 0, 10), { small, big }, nil).zone, "BIG")
		h.eq(R.zoneBox({ zone = "X", terrainBounds = { empty = true } }), nil, "no bounds and no route")
		h.eq(R.zoneBox(nil), nil)
		local b = R.zoneBox({ zone = "X", id = "X-1", waypoints = { { pos = Vector3.new(10, 0, -10) } } }) :: any
		h.eq(b.profile, "X-1", "profile falls back to the track id")
		h.eq(b.minX, 10 - R.ZONE_PAD)
		h.eq(b.maxZ, -10 + R.ZONE_PAD)
	end)

	h.test("wiring: the default path's call sites go through the rules with PER_GROUP", function()
		local rm = h.readFile("src/server/RaceManager.luau")
		h.contains(rm, "RaceInstanceRules.fieldHumans(RaceFlowRules.PER_GROUP, #Players:GetPlayers(), #humans)")
		local td = h.readFile("src/server/TrackDirector.luau")
		h.contains(td, "RaceInstanceRules.keepMap(perGroup, c.Name, key, td.id)")
		h.contains(td, "RaceInstanceRules.clearTerrain(perGroup, first)")
		local fsrc = h.readFile("src/server/FlightServer.luau")
		h.contains(fsrc, "(slotIndex - 1) % PlaneConfig.HUB_SEATS")
		local ma = h.readFile("src/server/MapAdapter.luau")
		h.contains(ma, "if not RaceInstanceRules.serverWritesLighting(RaceFlowRules.PER_GROUP) then")
		h.contains(ma, "or not RaceInstanceRules.serverWritesLighting(RaceFlowRules.PER_GROUP) then")
		h.contains(h.readFile("src/client/ZoneLighting.luau"), "if not RaceFlowRules.PER_GROUP then")
	end)
end
