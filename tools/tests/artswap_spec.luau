--!strict
-- Lune spec for the world art swap (shared/ArtSwapRules): which compiled-builder prefabs are swapped for the art v3 meshes
-- (and the world_v1 bush / DINO course arches that v3 does not replace): the rules' prefab patterns against the real
-- build/<map>/builder_module.luau keys, the bounding-box fit maths (scale, placement, tint, colliders, banner re-seat, hedge
-- stretch, collider yaw, tree yaw), the art v3 arches' openings (fixed scale on the prefab origin, colliders outside the
-- required clear opening), pending rules (art still being redone: no ASSETS entry, never match), and drift guards: the ASSETS
-- table against the four manifests (assets/models/{world_v1,foliage_v3,arches_v3,props_v3}/manifest.json), every ready rule's
-- mesh against the uploaded id tables, no art v2 id table searched, and the wiring of MapAdapter / ArtSwap / WorldArt /
-- WorldSetPieces (Studio-only ArtSwapOff, 20-wide trigger disc, sign mesh, windmill sails spun by WorldAnim).
-- Run: tools/tests/run_lune_tests.sh tools/tests/artswap_spec.luau

type Harness = {
	test: (string, () -> ()) -> (),
	eq: (any, any, string?) -> (),
	ok: (any, string?) -> (),
	contains: (any, string, string?) -> (),
	require: (string) -> any,
	readFile: (string) -> string,
}

return function(h: Harness)
	local R = h.require("src/shared/ArtSwapRules.luau")
	local WorldModelAssets = h.require("src/shared/WorldModelAssets.luau")
	local PropLibrary = h.require("src/shared/PropLibrary.luau")

	local function near(a: number, b: number, eps: number?, msg: string?)
		h.ok(math.abs(a - b) <= (eps or 1e-3), string.format("%s: %.4f vs %.4f", msg or "near", a, b))
	end

	local ZONES = { "FOREST", "SPACE", "HUB", "ISLAND", "SNOW", "DINO" }

	local function rule(id: string): any
		for _, r in R.RULES do
			if r.id == id then
				return r
			end
		end
		error("no rule " .. id)
	end

	h.test("rules match the intended prefabs and nothing else", function()
		h.eq((R.match("RoundTree_3", "FOREST") :: any).id, "oak_round")
		h.eq((R.match("BroadleafTree#2", "HUB") :: any).id, "oak_broadleaf")
		h.eq((R.match("Bush_4", "FOREST") :: any).id, "bush")
		h.eq((R.match("PalmTree#2", "HUB") :: any).id, "palm_hub")
		h.eq((R.match("PalmTree#0", "ISLAND") :: any).id, "palm_island")
		h.eq((R.match("StoneArchway_S1050", "DINO") :: any).id, "dino_arch")
		h.eq((R.match("StartFinishGate", "DINO") :: any).id, "dino_arch")
		h.eq((R.match("PortalArch_SNOW", "HUB") :: any).id, "hub_portal")
		-- art v3: foliage, arches and gantries, props (each in its own zone only)
		h.eq((R.match("Poplar_2", "FOREST") :: any).id, "poplar")
		h.eq((R.match("CliffTunnelArch", "HUB") :: any).id, "cliff_tunnel_arch")
		h.eq((R.match("MineTunnelPortal", "SNOW") :: any).id, "mine_portal")
		h.eq((R.match("FinishGantry", "SNOW") :: any).id, "snow_finish_gantry")
		h.eq((R.match("CavernArchRib", "ISLAND") :: any).id, "cavern_rib")
		h.eq((R.match("CavernExitArch", "ISLAND") :: any).id, "cavern_mouth")
		h.eq((R.match("Windmill#far", "FOREST") :: any).id, "windmill_tower")
		h.eq((R.match("WindmillSails", "FOREST") :: any).id, "windmill_sails")
		h.eq((R.match("PlazaLamp", "HUB") :: any).id, "plaza_lamp")
		h.eq((R.match("CypressTree#2", "HUB") :: any).id, "cypress")
		h.eq((R.match("SkywayArch_1", "SPACE") :: any).id, "skyway_arch")
		h.eq((R.match("MesaTunnelPortal", "SPACE") :: any).id, "mesa_portal")
		h.eq((R.match("BannerPole#4", "HUB") :: any).id, "banner_pole")
		-- art round 7 (hedge, autumn tree, start gantries, tiki torch) is uploaded: its rules are ready and match
		for _, p in { { "Hedge_3", "FOREST", "hedge" }, { "AutumnTree_1", "FOREST", "autumn_oak" }, { "StartFinishArch", "ISLAND", "island_start_gantry" },
			{ "StartFinishGantry", "HUB", "hub_start_gantry" }, { "TikiTorch", "ISLAND", "tiki_torch" } } do
			h.eq((R.match(p[1], p[2]) :: any).id, p[3], p[1] .. " matches")
			h.ok(R.ready(rule(p[3])), p[3] .. " is ready")
		end
		-- left alone: no rule, ready or pending (v3 has no replacement, or the shape is not worth a swap)
		for _, name in { "HorizonPalm#1", "DressRuinArch", "RingGate#0", "KeyAlcoveArch", "ShrubCluster#1", "PlazaPlanter#1", "StoneArchBridge", "BridgeArch_1", "MesaTunnelChevron", "StartFinishLine", "TunnelPortal", "GlassVaultRib", "GlassVaultPortal", "NeonSignGantry_Amber", "PromenadeLamp", "LeftCliffFoliage_1", "RightCliffFoliage_2" } do
			for _, zone in ZONES do
				h.eq(R.match(name, zone, true), nil, name .. " in " .. zone)
			end
		end
		-- the same key in another zone is not swapped: FOREST's poplar is no HUB tree, SNOW's gantry is not the hub's
		h.eq(R.match("Poplar_1", "HUB"), nil)
		h.eq(R.match("FinishGantry", "HUB"), nil)
		h.eq(R.match("StartFinishArch", "HUB", true), nil)
		h.eq(R.match("TikiTorch", "SPACE", true), nil)
		-- zone filter: a palm is a hub cluster only in the hub, an island cluster only on ISLAND, never in FOREST
		h.eq(R.match("PalmTree#1", "FOREST"), nil)
		h.eq(R.match("StoneArchway_S2100", "ISLAND"), nil)
		h.eq(R.match("PortalArch_DINO", "DINO"), nil)
	end)

	h.test("every oak is one model: round_oak, varied by a stable yaw and by each tree's own height", function()
		h.eq(rule("oak_round").meshes, { "round_oak" })
		h.eq(rule("oak_broadleaf").meshes, { "round_oak" })
		h.eq(R.pickMesh({ "round_oak" }, -683.94, 7048.66), "round_oak")
		local a = R.hash(-683.94, 7048.66)
		h.eq(R.hash(-683.94, 7048.66), a)
		-- the mesh pick still spreads over a list (kept for multi-model rules)
		local counts: { [string]: number } = {}
		for i = 1, 1500 do
			local v = R.hash(i * 13.37, i * -7.91)
			h.ok(v >= 0 and v < 1, "hash range")
			local m = R.pickMesh({ "a", "b", "c" }, i * 13.37, i * -7.91)
			counts[m] = (counts[m] or 0) + 1
		end
		for _, m in { "a", "b", "c" } do
			h.ok((counts[m] or 0) > 1500 * 0.25 and (counts[m] or 0) < 1500 * 0.42, m .. " share " .. tostring(counts[m]))
		end
		-- yaw: stable, in [0, 2 pi), and spread over the circle (eight sectors all used)
		h.eq(R.yawFor(12.5, -40), R.yawFor(12.5, -40))
		local sectors: { [number]: number } = {}
		for i = 1, 400 do
			local yaw = R.yawFor(i * 11.3, i * -5.7)
			h.ok(yaw >= 0 and yaw < math.pi * 2, "yaw range")
			local k = math.floor(yaw / (math.pi / 4))
			sectors[k] = (sectors[k] or 0) + 1
		end
		for k = 0, 7 do
			h.ok((sectors[k] or 0) > 20, "yaw sector " .. k .. " has " .. tostring(sectors[k]))
		end
		for _, id in { "oak_round", "oak_broadleaf", "poplar" } do
			h.eq(rule(id).varyYaw, true, id)
		end
		-- yaw turns the mesh about its own origin (the trunk), not about its bbox centre
		local a0 = R.ASSETS.round_oak
		h.eq(R.partCFrame(a0, 1.5, Vector3.zero, 0).Position, R.partCentre(a0, 1.5, Vector3.zero))
		local turned = R.partCFrame(a0, 1, Vector3.new(5, 0, 7), math.pi / 2)
		near(turned.Position.X, 5 + a0.centre.Z, 1e-4, "quarter turn: x takes z")
		near(turned.Position.Y, a0.centre.Y, 1e-4, "height unchanged")
		near(turned.Position.Z, 7 - a0.centre.X, 1e-4, "quarter turn: z takes -x")
	end)

	h.test("arches pick the closer aspect: tall landmark arch -> portal, low wide arch -> stone", function()
		h.eq(R.pickArch({ "portal_arch", "stone_arch" }, 138, 153), "portal_arch")
		h.eq(R.pickArch({ "portal_arch", "stone_arch" }, 72.4, 71.2), "portal_arch")
		h.eq(R.pickArch({ "portal_arch", "stone_arch" }, 70, 27), "stone_arch")
	end)

	h.test("scale: trees by height with a width cap, the DINO arches by height with a width cap, the hub gate fixed", function()
		local round = R.match("RoundTree_1", "FOREST") :: any
		near(R.fitScale(round, R.ASSETS.round_oak, Vector3.new(29.2, 32.2, 29.1)), 32.2 / 18.3, 1e-3, "oak by height")
		-- a squat wide bush: the footprint (1.15 x 11.7 / 9.17) caps it below the height ratio 7.7/5.07
		local bush = R.match("Bush_1", "FOREST") :: any
		near(R.fitScale(bush, R.ASSETS.bush, Vector3.new(11.7, 7.7, 11.7)), 1.15 * 11.7 / 9.17, 1e-3, "bush by width")
		-- poplars: 9-9.8 wide and 30-35.2 tall originals against a 33 tall, 10.4 (z) wide mesh
		local poplar = R.match("Poplar_1", "FOREST") :: any
		near(R.fitScale(poplar, R.ASSETS.poplar, Vector3.new(9.83, 30.04, 9.62)), 30.04 / 33, 1e-4, "short poplar by height")
		near(R.fitScale(poplar, R.ASSETS.poplar, Vector3.new(9, 35.22, 8.91)), 1.15 * 9 / 10.4, 1e-4, "tall narrow poplar by width")
		local dino = R.match("StoneArchway_S1050", "DINO") :: any
		near(R.fitScale(dino, R.ASSETS.portal_arch, Vector3.new(138, 153.1, 22)), 1.12 * 138 / 30.84, 1e-3, "dino arch width cap")
		-- the swapped mesh stays inside the original's height
		h.ok(R.ASSETS.portal_arch.size.Y * R.fitScale(dino, R.ASSETS.portal_arch, Vector3.new(138, 153.1, 22)) <= 153.1)
		-- the hub portals take portal_gate at scale 1, whatever the bbox: its window (30.6 wide) is the sign's room, not the veil's
		local portal = R.match("PortalArch_FOREST", "HUB") :: any
		h.eq(R.fitScale(portal, R.ASSETS.portal_gate, Vector3.new(47.2, 46.3, 10.4)), 1)
	end)

	h.test("placement: trees on the prefab origin, DINO arches centred on the bbox and standing on its bottom", function()
		local round = R.match("RoundTree_1", "FOREST") :: any
		h.eq(R.originPosition(round, R.ASSETS.round_oak, 1.76, Vector3.new(-14, 0, -14), Vector3.new(14, 32, 14)), Vector3.zero)
		local dino = R.match("StoneArchway_S1050", "DINO") :: any
		local s = 5.0
		local o = R.originPosition(dino, R.ASSETS.portal_arch, s, Vector3.new(-69, -76.5, -11), Vector3.new(69, 76.6, 11))
		near(o.X, 0, 1e-6, "x")
		near(o.Y, -76.5 + 0.02 * s, 1e-4, "y: lowest point on the original's lowest point")
		local c = R.partCentre(R.ASSETS.portal_arch, s, o)
		near(c.Y, o.Y + 11.115 * s, 1e-4, "part centre")
		-- the whole mesh fits under the original's top
		h.ok(c.Y + R.ASSETS.portal_arch.size.Y * s * 0.5 <= 76.6)
		-- an off-centre bbox moves the mesh with it
		local o2 = R.originPosition(dino, R.ASSETS.portal_arch, s, Vector3.new(-20, 0, -5), Vector3.new(60, 10, 5))
		near(o2.X, 20, 1e-6)
	end)

	h.test("localExtents: a quarter turn about Y swaps the X and Z extents", function()
		local lo, hi = R.localExtents(CFrame.new(10, 5, 0), Vector3.new(4, 2, 6))
		h.eq({ lo.X, lo.Y, lo.Z, hi.X, hi.Y, hi.Z }, { 8, 4, -3, 12, 6, 3 })
		local lo2, hi2 = R.localExtents(CFrame.new(0, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(4, 2, 6))
		near(hi2.X, 3, 1e-4)
		near(hi2.Z, 2, 1e-4)
		near(lo2.Y, -1, 1e-4)
	end)


	h.test("colliders: arch boxes scale with the fit, a trunk box rises from the ground", function()
		local cols = R.archColliders(R.ASSETS.portal_arch, 2, Vector3.zero)
		h.eq(#cols, 3)
		near(cols[2].centre.X, 12.2 * 2, 1e-6)
		near(cols[2].size.Y, 9 * 2, 1e-6)
		-- the piers stand clear of the 36 wide opening (inner face at 9 x 2 = 18)
		h.ok(cols[2].centre.X - cols[2].size.X * 0.5 >= 9 * 2 - 1e-6)
		h.ok(cols[3].centre.Y - cols[3].size.Y * 0.5 >= 18.65 * 2 - 1e-4, "top bar above the apex")
		-- an origin offset moves every box, a scale 1.07 (the cavern mouth) scales centres and sizes
		local moved = R.archColliders(R.ASSETS.cavern_arch, 1.07, Vector3.new(0, 3, 0))
		h.eq(#moved, 26)
		near(moved[1].centre.Y, 3 + (R.ASSETS.cavern_arch.colliders :: any)[1].centre.Y * 1.07, 1e-6)
		near(moved[1].size.X, (R.ASSETS.cavern_arch.colliders :: any)[1].size.X * 1.07, 1e-6)
		h.eq(#R.archColliders(R.ASSETS.round_oak, 1, Vector3.zero), 0)
		local round = R.match("RoundTree_1", "FOREST") :: any
		local t = R.trunkBox(round, R.ASSETS.round_oak, 1, Vector3.zero)
		near(t.size.X, 0.17 * 18.3, 1e-6)
		near(t.size.Y, 0.4 * 18.3, 1e-6)
		near(t.centre.Y, t.size.Y * 0.5, 1e-6)
		h.ok(t.size.Y < R.ASSETS.round_oak.size.Y * 0.6, "trunk only, not the canopy")
		local p = R.trunkBox(R.match("Poplar_1", "FOREST") :: any, R.ASSETS.poplar, 1, Vector3.zero)
		near(p.size.X, 0.055 * 33, 1e-6)
		near(p.size.Y, 0.48 * 33, 1e-6)
	end)

	h.test("what stays on a portal: veil glass, banner cloth and lights; stone and the crest orb go", function()
		local portal = R.match("PortalArch_DINO", "HUB") :: any
		h.ok(R.keepPart(portal, "Glass", false))
		h.ok(R.keepPart(portal, "Fabric", false))
		h.ok(R.keepPart(portal, "SmoothPlastic", true), "a light carrier stays")
		h.ok(not R.keepPart(portal, "Sandstone", false))
		h.ok(not R.keepPart(portal, "Neon", false), "the orb crest is replaced by the crown block")
		h.eq(portal.trim, nil, "portal_gate has no Neon trim")
		h.eq(portal.tint, nil, "v3 meshes are textured: no stone tint")
		local dino = R.match("StartFinishGate", "DINO") :: any
		h.ok(R.keepPart(dino, "Neon", false), "the gate's neon strip stays")
		h.ok(not R.keepPart(dino, "Sandstone", false))
	end)

	h.test("banners are re-seated in front of the new pier face, never pulled back", function()
		-- portal_gate: the front face of the piers is at z -4.5
		local z = R.bannerZ(R.ASSETS.portal_gate, 1, Vector3.zero, -3.9, 0.8)
		near(z, -4.5 - 0.4 - 0.05, 1e-6)
		h.ok(z < -3.9)
		h.eq(R.bannerZ(R.ASSETS.portal_gate, 1, Vector3.zero, -9, 0.8), -9)
		h.eq(R.bannerZ(R.ASSETS.round_oak, 1, Vector3.zero, -3.9, 0.8), -3.9)
		-- the world_v1 DINO arch re-seats as before
		near(R.bannerZ(R.ASSETS.portal_arch, 1.35, Vector3.zero, -3.9, 0.8), -(3.0 * 1.35) - 0.4 - 0.05, 1e-6)
	end)

	h.test("stone tint: dominant colour by volume, divided by the mesh's 0.8 grey and clamped", function()
		local a, b = Color3.fromRGB(156, 135, 114), Color3.fromRGB(185, 166, 144)
		local dom = R.dominantColour({ { color = a, weight = 10 }, { color = b, weight = 4 }, { color = b, weight = 4 }, { color = b, weight = 4 } }) :: Color3
		near(dom.R, b.R, 1e-3, "three small parts of one colour outweigh one bigger part")
		h.eq(R.dominantColour({}), nil)
		local t = R.stoneTint(Color3.new(0.4, 0.8, 0.96))
		near(t.R, 0.5, 1e-6)
		near(t.G, 1, 1e-6)
		near(t.B, 1, 1e-6, "clamped at white")
	end)


	-- Manifest reading: the four pretty-printed manifests, one entry per mesh (world_v1: from its "file" key to the next; v3: from
	-- its "name" key to the next).
	local NUM = "([%-%d%.eE%+]+)"
	local MANIFESTS = { "world_v1", "foliage_v3", "arches_v3", "props_v3" }
	local UPLOADED: { [string]: { [string]: number } } = {
		world_v1 = WorldModelAssets,
		foliage_v3 = h.require("src/shared/FoliageV3Assets.luau"),
		arches_v3 = h.require("src/shared/ArchV3Assets.luau"),
		props_v3 = h.require("src/shared/PropV3Assets.luau"),
	}
	local manifestText: { [string]: string } = {}
	for _, f in MANIFESTS do
		manifestText[f] = h.readFile("assets/models/" .. f .. "/manifest.json")
	end

	local function num(s: string): number
		return tonumber(s) :: number
	end

	-- (folder, entry text) of the manifest entry for a mesh name
	local function manifestEntry(name: string): (string, string)
		for _, f in MANIFESTS do
			local text = manifestText[f]
			local key = if f == "world_v1" then '"file": "' .. name .. '.glb"' else '"name": "' .. name .. '"'
			local at = string.find(text, key, 1, true)
			if at then
				local nextAt = string.find(text, if f == "world_v1" then '"file": "' else '"name": "', at + 10, true)
				return f, string.sub(text, at, (nextAt or #text + 1) - 1)
			end
		end
		error(name .. " is in no manifest")
	end

	local function manifestVec(body: string, key: string): { number }
		local x, y, z = string.match(body, '"' .. key .. '": %[%s*' .. NUM .. ',%s*' .. NUM .. ',%s*' .. NUM .. '%s*%]')
		h.ok(x ~= nil, key .. " in the manifest entry")
		return { num(x), num(y), num(z) }
	end

	type ManifestBox = { centre: { number }, size: { number }, yaw: number }
	local function manifestColliders(body: string): { ManifestBox }
		local out: { ManifestBox } = {}
		local at = string.find(body, '"colliders": ', 1, true)
		if not at then
			return out
		end
		local arr = string.match(string.sub(body, at + #'"colliders": '), "^%b[]") :: string
		for obj in string.gmatch(arr, "%b{}") do
			table.insert(out, { centre = manifestVec(obj, "centre"), size = manifestVec(obj, "size"), yaw = tonumber((string.match(obj, '"yaw": ' .. NUM))) or 0 })
		end
		return out
	end

	h.test("drift guard: ASSETS match the manifests (size, centre, bury, colliders) and every rule target has an uploaded id", function()
		for name, a in R.ASSETS do
			local folder, body = manifestEntry(name)
			local size = manifestVec(body, "size_studs_xyz")
			near(a.size.X, size[1], 0.011, name .. " size x")
			near(a.size.Y, size[2], 0.011, name .. " size y")
			near(a.size.Z, size[3], 0.011, name .. " size z")
			local lo, hi = manifestVec(body, "bbox_min"), manifestVec(body, "bbox_max")
			near(a.centre.X, (lo[1] + hi[1]) * 0.5, 0.011, name .. " centre x")
			near(a.centre.Y, (lo[2] + hi[2]) * 0.5, 0.011, name .. " centre y")
			near(a.centre.Z, (lo[3] + hi[3]) * 0.5, 0.011, name .. " centre z")
			near(a.bury, -lo[2], 0.011, name .. " bury")
			h.ok(UPLOADED[folder][name] ~= nil, name .. " has an uploaded Model id")
			h.ok(folder ~= "arches_v2" and folder ~= "foliage_v2" and folder ~= "props_v2", name .. " is not an art v2 mesh")
			-- world_v1's arch colliders are the integrator's (pier boxes + top bar); the v3 manifests list their own
			if folder ~= "world_v1" then
				local cols = manifestColliders(body)
				local mine = a.colliders or {}
				h.eq(#mine, #cols, name .. " collider count")
				for i, c in cols do
					local m = mine[i]
					near(m.centre.X, c.centre[1], 0.011, name .. " collider " .. i .. " x")
					near(m.centre.Y, c.centre[2], 0.011, name .. " collider " .. i .. " y")
					near(m.centre.Z, c.centre[3], 0.011, name .. " collider " .. i .. " z")
					near(m.size.X, c.size[1], 0.011, name .. " collider " .. i .. " sx")
					near(m.size.Y, c.size[2], 0.011, name .. " collider " .. i .. " sy")
					near(m.size.Z, c.size[3], 0.011, name .. " collider " .. i .. " sz")
					near(m.yaw or 0, c.yaw, 1e-6, name .. " collider " .. i .. " yaw")
				end
			end
		end
		-- the portal_gate manifest's pier face (where the banners hang) and the windmill's prefab height
		h.eq(R.ASSETS.portal_gate.pierFront, 4.5)
		h.eq(R.ASSETS.windmill_tower.fitHeight, 78)
		for _, r in R.RULES do
			if r.stopgap then
				continue -- Creator Store stand-ins have their own checks (ToolboxTempAssets / STOPGAP_ASSETS, below)
			end
			for _, m in r.meshes or {} do
				-- a rule is ready exactly when every mesh it places has an uploaded id (ASSETS entry and id arrive together)
				local uploaded = false
				for _, ids in UPLOADED do
					uploaded = uploaded or ids[m] ~= nil
				end
				h.eq(R.ASSETS[m] ~= nil, uploaded, r.id .. " mesh " .. m .. ": ASSETS entry iff uploaded")
			end
			if r.trim then
				h.ok(R.ASSETS[r.trim] ~= nil, r.id .. " trim")
			end
			if r.prop then
				local p = (PropLibrary :: any)[r.prop]
				h.ok(p ~= nil and p.model ~= nil, r.id .. " prop uploaded: " .. r.prop)
			end
			h.ok(r.align == "origin" or r.align == "bbox", r.id .. " align")
			h.ok(r.kind == "tree" or r.kind == "hedge" or r.kind == "palm" or r.kind == "arch" or r.kind == "portal" or r.kind == "prop", r.id .. " kind")
		end
	end)

	h.test("drift guard: WorldArt.world finds every key in exactly one uploaded v3 / world_v1 table, and never an art v2 one; trunk boxes follow the manifest fractions", function()
		local seen: { [string]: string } = {}
		for folder, ids in UPLOADED do
			for key in ids do
				h.ok(seen[key] == nil, key .. " is in both " .. tostring(seen[key]) .. " and " .. folder)
				seen[key] = folder
			end
		end
		-- the pending art is in the manifests (and judged-failed or still being redone), but has no id yet
		for _, name in { "hedge", "autumn_tree", "start_gantry", "tiki_torch" } do
			h.ok(seen[name] ~= nil, name .. " is uploaded (art round 7)")
		end
		for _, name in { "cypress", "space_arch", "mesa_portal", "banner_pole", "boost_pad" } do
			h.ok(seen[name] ~= nil, name .. " is uploaded")
		end
		for _, id in { "poplar", "cypress", "autumn_oak", "oak_round" } do
			local r = rule(id)
			for _, mesh in r.meshes do
				local _, body = manifestEntry(mesh)
				local w, hh = string.match(body, '"fractions_of_mesh_height": {%s*"w": ' .. NUM .. ',%s*"h": ' .. NUM)
				near(r.trunk.w, num(w), 1e-6, mesh .. " trunk w")
				near(r.trunk.h, num(hh), 1e-6, mesh .. " trunk h")
			end
		end
		local worldArt = h.readFile("src/server/kit/WorldArt.luau")
		for _, mod in { "WorldModelAssets", "FoliageV3Assets", "ArchV3Assets", "PropV3Assets" } do
			h.contains(worldArt, 'require(Shared:WaitForChild("' .. mod .. '"))')
		end
		for _, mod in { "FoliageModelAssets", "ArchModelAssets", "PropModelAssets" } do
			h.eq(string.find(worldArt, mod .. '"))', 1, true), nil, "WorldArt must not read the rejected art v2 table " .. mod)
		end
		h.contains(worldArt, "WORLD_TABLES: { { [string]: number } } = { WorldModelAssets, FoliageV3Assets, ArchV3Assets, PropV3Assets, ToolboxTempAssets.MESHES }")
		-- nothing that places art at runtime reaches an art v2 id table
		for _, file in { "src/shared/ArtSwapRules.luau", "src/server/kit/ArtSwap.luau", "src/server/kit/Prewarm.luau", "src/server/kit/Gameplay.luau", "src/server/WorldSetPieces.luau" } do
			local text = h.readFile(file)
			for _, mod in { "FoliageModelAssets", "ArchModelAssets", "PropModelAssets" } do
				h.eq(string.find(text, mod, 1, true), nil, file .. " must not reference " .. mod)
			end
		end
	end)

	-- Prefab keys of the real compiled builders: every rule must match exactly the keys it was written for.
	local ZONE_MAP: { [string]: string } = { DINO = "dino4", FOREST = "forest1", HUB = "hub0", ISLAND = "island2", SNOW = "snow1", SPACE = "space4" }
	local keyCache: { [string]: { string } } = {}
	local function builderKeys(zone: string): { string }
		local cached = keyCache[zone]
		if cached then
			return cached
		end
		local text = h.readFile("build/" .. ZONE_MAP[zone] .. "/builder_module.luau")
		local out: { string } = {}
		local seen: { [string]: boolean } = {}
		for k in string.gmatch(text, '"key":"([^"]+)"') do
			if not seen[k] then
				seen[k] = true
				table.insert(out, k)
			end
		end
		table.sort(out)
		keyCache[zone] = out
		return out
	end

	local EXPECT: { [string]: { zone: string, keys: { string } } } = {
		poplar = { zone = "FOREST", keys = { "Poplar_1", "Poplar_2", "Poplar_3" } },
		autumn_oak = { zone = "FOREST", keys = { "AutumnTree_1", "AutumnTree_2" } },
		hedge = { zone = "FOREST", keys = { "Hedge_1", "Hedge_2", "Hedge_3" } },
		cypress = { zone = "HUB", keys = { "CypressTree#1", "CypressTree#2" } },
		hub_portal = { zone = "HUB", keys = { "PortalArch_DINO", "PortalArch_FOREST", "PortalArch_ISLAND", "PortalArch_SNOW", "PortalArch_SPACE" } },
		skyway_arch = { zone = "SPACE", keys = { "SkywayArch_0", "SkywayArch_1", "SkywayArch_2" } },
		mesa_portal = { zone = "SPACE", keys = { "MesaTunnelPortal" } },
		island_start_gantry = { zone = "ISLAND", keys = { "StartFinishArch" } },
		hub_start_gantry = { zone = "HUB", keys = { "StartFinishGantry" } },
		cavern_rib = { zone = "ISLAND", keys = { "CavernArchRib" } },
		cavern_mouth = { zone = "ISLAND", keys = { "CavernExitArch", "CavernMouthArch" } },
		cliff_tunnel_arch = { zone = "HUB", keys = { "CliffTunnelArch" } },
		mine_portal = { zone = "SNOW", keys = { "MineTunnelPortal" } },
		snow_finish_gantry = { zone = "SNOW", keys = { "FinishGantry" } },
		windmill_tower = { zone = "FOREST", keys = { "Windmill", "Windmill#far" } },
		windmill_sails = { zone = "FOREST", keys = { "WindmillSails" } },
		plaza_lamp = { zone = "HUB", keys = { "PlazaLamp" } },
		banner_pole = { zone = "HUB", keys = { "BannerPole#1", "BannerPole#2", "BannerPole#3", "BannerPole#4", "BannerPole#5" } },
		tiki_torch = { zone = "ISLAND", keys = { "TikiTorch" } },
	}

	h.test("art v3 rules (ready and pending) match exactly their prefab keys in the compiled builders, in their own zone", function()
		local rulesSeen = 0
		for _, r in R.RULES do
			local want = EXPECT[r.id]
			if not want then
				continue
			end
			rulesSeen += 1
			local got: { string } = {}
			for _, key in builderKeys(want.zone) do
				local m = R.match(key, want.zone, true)
				if m and m.id == r.id then
					table.insert(got, key)
				end
			end
			h.eq(got, want.keys, r.id .. " matches in " .. want.zone)
			-- and no other zone's builder contains a key this rule would swap
			for zone in ZONE_MAP do
				if zone ~= want.zone then
					for _, key in builderKeys(zone) do
						local m = R.match(key, zone, true)
						h.ok(not (m and m.id == r.id), r.id .. " must not match " .. key .. " in " .. zone)
					end
				end
			end
		end
		local n = 0
		for _ in EXPECT do
			n += 1
		end
		h.eq(rulesSeen, n, "every expected rule exists")
	end)

	h.test("art v3 fit: windmills at their instance scale, lamps fixed", function()
		-- windmills: the tower is 78.47 tall against the prefab's 78 and 37 wide against 31, so the fit divides by the prefab
		-- height and the width cap never bites: each instance's own scale (the sails' hub still meets the axle)
		local tower = R.match("Windmill", "FOREST") :: any
		local sails = R.match("WindmillSails", "FOREST") :: any
		for _, s in { 0.85, 1, 1.1, 1.22 } do
			near(R.fitScale(tower, R.ASSETS.windmill_tower, Vector3.new(31 * s, 78 * s, 31 * s)), s, 1e-4, "tower at " .. s)
			near(R.fitScale(R.match("Windmill#far", "FOREST") :: any, R.ASSETS.windmill_tower, Vector3.new(32.24 * s, 78 * s, 32.24 * s)), s, 1e-4, "far tower at " .. s)
			near(R.fitScale(sails, R.ASSETS.windmill_sails, Vector3.new(77 * s, 77 * s, 4.1 * s)), s * 77 / 77.023, 1e-4, "sails at " .. s)
		end
		-- the axle: the mesh's axle centre (y 61 at scale 1, the sails hub) stays at 61 x scale
		near(61 * R.fitScale(tower, R.ASSETS.windmill_tower, Vector3.new(31 * 1.22, 78 * 1.22, 31 * 1.22)), 61 * 1.22, 1e-4, "axle height")
		-- the sails' mesh origin is the hub: the spin axis is local Z through it
		h.eq(R.originPosition(sails, R.ASSETS.windmill_sails, 1, Vector3.new(-38.5, -38.5, -2.5), Vector3.new(38.5, 38.5, 1.6)), Vector3.zero)
		near(R.partCentre(R.ASSETS.windmill_sails, 0.9, Vector3.zero).Z, -4.65 * 0.9, 1e-6, "sail mesh centre z")
		-- the plaza lamp is a scale-1 instance
		local lamp = rule("plaza_lamp")
		h.eq(R.fitScale(lamp, R.ASSETS.lamp_post, Vector3.new(3, 10, 3)), 1)
		h.eq(lamp.trim, nil, "the lantern is baked lit: no glow shell")
	end)

	h.test("pending hedges stretch along their long axis: never shorter than the blocks, centred on them, height fit on Y and Z", function()
		local hedge = rule("hedge")
		h.eq(hedge.stretch, 1.02)
		-- the redone hedge's manifest numbers (not in ASSETS until it has an id): 32 x 7.95 x 7.4, long axis X, collider (0,3.6,0) 32 x 7.6 x 7.2
		local _, body = manifestEntry("hedge")
		local size = manifestVec(body, "size_studs_xyz")
		local lo, hi = manifestVec(body, "bbox_min"), manifestVec(body, "bbox_max")
		local a: any = {
			size = Vector3.new(size[1], size[2], size[3]),
			centre = Vector3.new((lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2),
			bury = -lo[2],
			colliders = { { centre = Vector3.new(0, 3.6, 0), size = Vector3.new(32, 7.6, 7.2) } },
		}
		for _, orig in { Vector3.new(32.67, 8.14, 9.45), Vector3.new(35.82, 7.74, 10.24), Vector3.new(32.9, 8.55, 8.4) } do
			local k = R.stretchScale(hedge, a, orig)
			near(a.size.X * k.X, orig.X * 1.02, 1e-3, "length")
			h.ok(a.size.X * k.X >= orig.X, "never shorter than the original blocks")
			near(a.size.Y * k.Y, orig.Y, 1e-3, "height")
			near(k.Y, k.Z, 1e-9, "Y and Z share the height fit")
		end
		-- the prefab pivot sits up to half a stud off the middle of the blocks: the module follows the blocks
		local o = R.originPosition(hedge, a, 1, Vector3.new(-18.38, -0.5, -4.58), Vector3.new(17.44, 7.24, 5.67))
		near(o.X, -0.47, 1e-6, "origin x")
		h.eq({ o.Y, o.Z }, { 0, 0 })
		-- colliders and the part centre scale per axis: the body box spans the stretched length
		local k = R.stretchScale(hedge, a, Vector3.new(35.82, 7.74, 10.24))
		local cols = R.archColliders(a, k, o)
		h.eq(#cols, 1)
		near(cols[1].size.X, 32 * k.X, 1e-6, "body box length")
		near(cols[1].centre.X, o.X, 1e-6, "body box centred")
		near(R.partCentre(a, k, o).Y, a.centre.Y * k.Y, 1e-6, "mesh centre y")
		-- number scales still work as before
		h.eq(R.scaleVec(2), Vector3.new(2, 2, 2))
		h.eq(R.scaleVec(Vector3.new(1, 2, 3)), Vector3.new(1, 2, 3))
		-- and every other rule leaves stretch off
		for _, r in R.RULES do
			h.ok((r.stretch ~= nil) == (r.id == "hedge"), r.id .. " stretch")
		end
	end)

	h.test("art v3 arches: fixed scale on the prefab origin, the mesh's own frame is the prefab's, colliders carry their yaw", function()
		local arches = h.require("src/shared/ArchV3Assets.luau")
		local SCALES: { [string]: number } = { hub_portal = 1, cliff_tunnel_arch = 1, mine_portal = 1, snow_finish_gantry = 1, cavern_rib = 1, cavern_mouth = 1.07, skyway_arch = 1, mesa_portal = 1, island_start_gantry = 1, hub_start_gantry = 1 }
		local ruled = 0
		for _, r in R.RULES do
			local mesh = (r.meshes or {})[1]
			if mesh and (arches :: any)[mesh] ~= nil then
				ruled += 1
				local a = R.ASSETS[mesh]
				h.ok(r.kind == "arch" or r.kind == "portal", r.id)
				h.eq(r.scale, SCALES[r.id], r.id .. " fixed scale")
				-- the skyway arches centre on the original's bbox at the fixed scale (their prefab origin is not the arch's)
				h.eq(r.align, if r.id == "skyway_arch" then "bbox" else "origin", r.id)
				h.eq(r.tint, nil, r.id .. " is textured: no stone tint")
				h.eq(r.trim, nil, r.id)
				-- whatever bbox the prefab has, the fit does not move or scale the mesh: the opening is as authored
				for _, size in { Vector3.new(60, 48, 8), Vector3.new(190, 90, 15) } do
					h.eq(R.fitScale(r, a, size), r.scale, r.id)
				end
				if r.align == "origin" then
					h.eq(R.originPosition(r, a, 1, Vector3.new(-50, 7, -4), Vector3.new(50, 55, 4)), Vector3.zero, r.id)
				else
					local o = R.originPosition(r, a, 1, Vector3.new(-50, 7, -4), Vector3.new(50, 55, 4))
					near(o.X, 0, 1e-6, r.id .. " centred on the bbox")
					near(o.Y, 7 + a.bury, 1e-6, r.id .. " sits on the bbox bottom")
				end
				h.eq(R.partCentre(a, 1, Vector3.zero), a.centre, r.id)
				-- colliders are created only where the original collided (r.collider = "arch" is applied by ArtSwap on `collided`)
				h.eq(r.collider, if r.id == "skyway_arch" then nil else "arch", r.id)
			end
		end
		h.eq(ruled, 10, "the ten ready arch rules (eight meshes) are placed by a rule")
		-- the windmill octagon: four boxes per section at 0/45/90/135 degrees, every corner within the octagon's circumradius
		local scale = 1.22
		local mill = R.ASSETS.windmill_tower
		local cols = R.archColliders(mill, scale, Vector3.zero)
		h.eq(#cols, 20)
		local yaws: { [number]: number } = {}
		local half = math.max(mill.size.X, mill.size.Z) * 0.5 * scale
		for _, c in cols do
			yaws[c.yaw] = (yaws[c.yaw] or 0) + 1
			local rad = math.rad(c.yaw)
			for _, sx in { -0.5, 0.5 } do
				for _, sz in { -0.5, 0.5 } do
					local lx, lz = c.size.X * sx, c.size.Z * sz
					local wx = c.centre.X + lx * math.cos(rad) + lz * math.sin(rad)
					local wz = c.centre.Z - lx * math.sin(rad) + lz * math.cos(rad)
					h.ok(math.max(math.abs(wx), math.abs(wz)) <= half + 1e-3, "inside the mesh footprint")
					h.ok(math.sqrt(wx * wx + wz * wz) <= half / math.cos(math.rad(22.5)) + 1e-3, "inside the octagon's circumradius")
				end
			end
		end
		h.eq({ yaws[0], yaws[45], yaws[90], yaws[135] }, { 5, 5, 5, 5 })
		-- no yaw given = 0
		h.eq(R.archColliders(R.ASSETS.portal_arch, 1, Vector3.zero)[1].yaw, 0)
	end)

	-- The clear opening each art v3 arch must keep, as a predicate in the prefab's XY plane: measured from the original prefabs
	-- by tools/check_arch_openings.py, which also checks the actual mesh vertices and the scaled cavern mouth. A point is inside
	-- when the car, plane or sign passes there.
	local OPENINGS: { [string]: (number, number) -> boolean } = {
		-- hub portal: the veil is 24 wide x 20 tall and its zone sign (26 x 5.5, centre y 26) hangs under the lintel
		portal_gate = function(x, y)
			return math.abs(x) < 14 and y > 0 and y < 30.5
		end,
		-- original hub cliff arch: |x| < 29.5 up to y 30, then a round arch r 29.8 about (0, 30)
		stone_arch_v3 = function(x, y)
			return y > 0 and ((math.abs(x) < 29.5 and y <= 30) or (y > 30 and x * x + (y - 30) ^ 2 < 29.8 ^ 2))
		end,
		-- snow finish gantry: the river bed to the banner, |x| < 49.5
		snow_finish_gantry = function(x, y)
			return math.abs(x) < 49.5 and y > 0 and y < 44.5
		end,
		-- start gantry (ISLAND + HUB): the original opening |x| < 29.9 to y 26 (open.json: required profile)
		start_gantry = function(x, y)
			return math.abs(x) < 29.9 and y > 0 and y <= 26
		end,
		mine_portal = function(x, y)
			return math.abs(x) < 19 and y > 0 and y < 33
		end,
		-- SPACE mesa portal: straight jambs |x| < 20 to y 34 (the original prefab's clear opening, check_arch_openings)
		mesa_portal = function(x, y)
			return math.abs(x) < 20 and y > 0 and y < 34
		end,
		-- SPACE skyway arch (never collided): the elliptical ring a 23.95 x b 35.75 about y 4 over a pedestal |x| < 22.9 to y 9
		space_arch = function(x, y)
			return y > 0 and ((math.abs(x) < 22.9 and y <= 9) or (y > 9 and (x / 23.95) ^ 2 + ((y - 4) / 35.75) ^ 2 < 1))
		end,
		-- original cavern rib: jambs |x| < 31.25 to y 30, then a round arch r 31.5 about (0, 30) clamped at the crown, y 60.5
		cavern_arch = function(x, y)
			return y > 0 and y < 60.5 and ((math.abs(x) < 31.25 and y <= 30) or (y > 30 and x * x + (y - 30) ^ 2 < 31.5 ^ 2))
		end,
	}

	h.test("art v3 arches keep their opening: no collider box reaches into the required clear opening", function()
		local arches = h.require("src/shared/ArchV3Assets.luau")
		local withColliders = 0
		for name in arches :: { [string]: number } do
			local a = R.ASSETS[name]
			local inOpening = OPENINGS[name]
			h.ok(inOpening ~= nil, name .. " has a declared opening")
			local hits, samples = 0, 0
			for _, c in a.colliders or {} do
				-- sample the box (shrunk 0.25 each side) against the opening
				local px = c.centre.X - c.size.X * 0.5 + 0.25
				while px <= c.centre.X + c.size.X * 0.5 - 0.25 do
					local py = c.centre.Y - c.size.Y * 0.5 + 0.25
					while py <= c.centre.Y + c.size.Y * 0.5 - 0.25 do
						samples += 1
						if inOpening(px, py) then
							hits += 1
						end
						py += 0.5
					end
					px += 0.5
				end
			end
			-- the opening lies inside the mesh's own width, so the mesh is the frame around it
			h.ok(inOpening(0, 5) and not inOpening(a.size.X * 0.5, 5), name .. " opening within the mesh width")
			h.eq(hits, 0, name .. " collider samples inside the opening")
			if a.colliders and #a.colliders > 0 then
				withColliders += 1
				h.ok(samples > 100, name .. " colliders sampled")
			end
		end
		h.eq(withColliders, 7, "the seven arches whose originals collided get colliders")
	end)

	h.test("what stays on the art v3 arches and props: gems, lanterns, brackets, the finish sign; the blocks go", function()
		h.ok(R.keepPart(rule("cliff_tunnel_arch"), "Neon", false), "keystone gems")
		h.ok(not R.keepPart(rule("cliff_tunnel_arch"), "Slate", false))
		h.ok(R.keepPart(rule("mine_portal"), "Neon", true), "hanging lantern with its light")
		h.ok(not R.keepPart(rule("mine_portal"), "WoodPlanks", false))
		h.ok(R.keepPart(rule("snow_finish_gantry"), "SmoothPlastic", false), "the finish sign plate")
		h.ok(not R.keepPart(rule("snow_finish_gantry"), "Neon", true), "the x 52 lanterns would hang in the new opening")
		h.ok(R.keepPart(rule("cavern_mouth"), "Metal", false), "lantern brackets")
		h.ok(R.keepPart(rule("cavern_mouth"), "Neon", true), "lantern with its light")
		h.ok(not R.keepPart(rule("cavern_mouth"), "Slate", false))
		h.ok(R.keepPart(rule("cavern_rib"), "Metal", false) and R.keepPart(rule("cavern_rib"), "Neon", true))
		h.ok(R.keepPart(rule("plaza_lamp"), "Neon", true), "the neon block and its PointLight stay inside the closed mesh")
		h.ok(not R.keepPart(rule("plaza_lamp"), "Metal", false) and not R.keepPart(rule("plaza_lamp"), "Sandstone", false))
		h.ok(not R.keepPart(rule("windmill_sails"), "Fabric", false) and not R.keepPart(rule("windmill_tower"), "Plaster", false), "windmills are wholly replaced")
		h.ok(R.keepPart(rule("banner_pole"), "SmoothPlastic", false), "the coloured flag stays")
		h.eq(rule("banner_pole").keepShift, Vector3.new(2.5, -3, 0), "and hangs from the longer crossbar")
		h.ok(R.keepPart(rule("mesa_portal"), "Neon", true) and R.keepPart(rule("skyway_arch"), "Neon", true), "space arch lights stay")
		-- pending rules keep the flame light
		h.ok(R.keepPart(rule("tiki_torch"), "Neon", true))
	end)

	h.test("collidersOnly (v29 Wave 2): the HUB tunnel mouths keep the stone_arch_v3 colliders, place and load no mesh", function()
		local r = rule("cliff_tunnel_arch")
		h.eq(r.collidersOnly, true)
		h.eq(R.placesMesh(r), false, "the carved CliffTunnelCollar prefab is the visual")
		h.eq(r.collider, "arch", "collision exactly as with the mesh")
		h.ok(R.ready(r), "still ready: its colliders come from the stone_arch_v3 ASSETS entry")
		h.eq(#((R.asset("stone_arch_v3") :: any).colliders), 30)
		h.ok(R.match("CliffTunnelCollar", "HUB") == nil, "the collar itself is never swapped")
		local others = 0
		for _, x in R.RULES do
			if x.id ~= "cliff_tunnel_arch" then
				h.ok(R.placesMesh(x), x.id .. " still places its art")
				others += 1
			end
		end
		h.ok(others > 10)
		local swap = h.readFile("src/server/kit/ArtSwap.luau")
		h.contains(swap, "if Rules.placesMesh(rule) then", "the swap only needs a template when it places the mesh")
		h.contains(swap, "local names = if Rules.placesMesh(rule) then rule.meshes else nil", "the prewarm skips it")
		h.contains(swap, "local meshes = if Rules.placesMesh(rule) then rule.meshes else nil", "the run's loads skip it")
		h.contains(swap, "elseif propTpl then", "no mesh and no prop: nothing is placed, the colliders still are")
	end)

	h.test("part names: tree, hedge, arch, prop", function()
		h.eq(R.partName(R.match("RoundTree_1", "FOREST") :: any), "Tree")
		h.eq(R.partName(R.match("Hedge_1", "FOREST", true) :: any), "Hedge")
		h.eq(R.partName(R.match("MineTunnelPortal", "SNOW") :: any), "Arch")
		h.eq(R.partName(R.match("PortalArch_SNOW", "HUB") :: any), "Arch")
		h.eq(R.partName(R.match("PlazaLamp", "HUB") :: any), "Prop")
	end)

	h.test("wiring: ArtSwap carries stretch, tree yaw and collider yaw; the sign mesh is placed by code; WorldAnim spins the sails", function()
		local swap = h.readFile("src/server/kit/ArtSwap.luau")
		h.contains(swap, "Rules.stretchScale(rule, asset, size)")
		h.contains(swap, "Rules.partCFrame(asset, fit, origin, yaw)")
		h.contains(swap, "Rules.yawFor(pivot.Position.X, pivot.Position.Z)")
		h.contains(swap, "box(\"Collider\" .. tostring(i), pivot, c.centre, c.size, model, c.yaw)")
		h.contains(swap, "Rules.partName(rule)")
		h.contains(swap, "model.WorldPivot = pivot", "the Model keeps its pivot and attributes")
		h.contains(swap, "and Rules.ready(rule) then", "templatesFor (the prewarm) skips pending rules")
		local gameplay = h.readFile("src/server/kit/Gameplay.luau")
		h.contains(gameplay, 'WorldArt.world("boost_pad")', "boost pads place the boost_pad mesh")
		h.contains(gameplay, "base.Transparency = 1", "the slab turns invisible under the mesh; BasePlate stays the trigger")
		h.contains(gameplay, "Enum.Material.Neon", "the game's own Neon chevrons are the glow")
		h.contains(h.readFile("src/server/kit/Prewarm.luau"), '"boost_pad"', "the pad mesh is prewarmed")
		h.contains(swap, "p.CFrame = pivot * CFrame.new(rule.keepShift :: Vector3) * (inv * p.CFrame)", "kept parts follow keepShift")
		h.contains(gameplay, 'base:SetAttribute("TriggerType", "GroundBoostPad")', "the trigger plate stays")
		local sp = h.readFile("src/server/WorldSetPieces.luau")
		h.contains(sp, 'WorldArt.world("sign_post")')
		h.contains(sp, "board.Transparency = 1", "the SignBoard stays as the invisible SurfaceGui carrier")
		h.contains(sp, "local SIGN_BOARD_Y = 4.7")
		-- the sails keep their Model: every one of the 42 has a plan modelAttributes row that MapAdapter applies after the swap
		local plan = h.readFile("map/forest1/plan.json")
		local rows = 0
		for _ in string.gmatch(plan, '/WindmillSails",') do
			rows += 1
		end
		h.eq(rows, 42) -- v28 Wave 1: 20 + 13 farm mills + 8 ridge mills + the hero mill
		h.contains(plan, '"SpinAxis": "PivotLookVector"')
		local adapter = h.readFile("src/server/MapAdapter.luau")
		local swapAt = string.find(adapter, 'step("artSwap"', 1, true) :: number
		local attrAt = string.find(adapter, 'step("modelAttributes"', 1, true) :: number
		h.ok(swapAt < attrAt, "sails are swapped before their SpinRPM row is applied")
		local anim = h.readFile("src/client/WorldAnim.luau")
		h.contains(anim, 'd:GetAttribute("SpinRPM")')
		h.contains(anim, "d:GetPivot()")
	end)

	h.test("wiring: the swap is a MapAdapter step before decorQuery, Studio-only off switch, ring trigger fits the opening", function()
		local adapter = h.readFile("src/server/MapAdapter.luau")
		h.contains(adapter, 'step("artSwap"')
		local swapAt = string.find(adapter, 'step("artSwap"', 1, true) :: number
		local decorAt = string.find(adapter, 'step("decorQuery"', 1, true) :: number
		-- Activation lives in the registerTrack helper (shared with MapCache's cached load); its call inside build comes last.
		local activateAt = string.find(adapter, "registerTrack(id, td, root", decorAt, true) :: number
		h.ok(swapAt < decorAt and decorAt < activateAt, "artSwap runs after the builder and before decorQuery and activation")
		local swap = h.readFile("src/server/kit/ArtSwap.luau")
		h.contains(swap, 'RunService:IsStudio() and workspace:GetAttribute("ArtSwapOff") == true')
		local gameplay = h.readFile("src/server/kit/Gameplay.luau")
		h.contains(gameplay, "local RING_OPENING_DIAMETER = 20")
		h.contains(gameplay, 'name .. "_BoostTriggerDisc"')
		h.contains(gameplay, 'trigger:SetAttribute("TriggerType", "BoosterRing")')
		h.contains(gameplay, 'trigger:SetAttribute("BoostPower", 135)')
	end)

	-- Creator Store stand-ins (docs/ASSETS_TOOLBOX_TEMP.md, src/shared/ToolboxTempAssets, tools/bake_toolbox.py): the hedge, autumn tree and
	-- tiki torch stand-ins were replaced by the in-house art round 7 meshes (their rules, ids and fit numbers are deleted).
	h.test("toolbox stand-ins: all replaced (no stand-in rule, id or fit numbers left); the tiki torch flame is particles on the kept block", function()
		local TB = h.require("src/shared/ToolboxTempAssets.luau")
		h.eq(next(TB.MESHES), nil, "no stand-in meshes")
		h.eq(next(TB.PROPS), nil, "no stand-in props")
		h.eq(next(R.STOPGAP_ASSETS), nil, "no stand-in fit numbers")
		for _, r in R.RULES do
			h.ok(not r.stopgap, r.id .. " is not a stand-in")
			local torchLit = r.id == "tiki_torch" or r.id == "cavern_rib" or r.id == "cavern_mouth" -- v28 1.16: the cavern wall torches too
			h.eq(r.flameFx == true, torchLit, r.id .. " flameFx only on the torches")
		end
		h.eq((R.match("Hedge_1", "FOREST") :: any).id, "hedge")
		h.eq((R.match("AutumnTree_2", "FOREST") :: any).id, "autumn_oak")
		h.eq((R.match("TikiTorch", "ISLAND") :: any).id, "tiki_torch")
		h.eq(R.match("Hedge_1", "HUB"), nil)
		h.eq(R.match("AutumnTree_1", "ISLAND"), nil)
		h.eq(R.match("TikiTorch", "FOREST"), nil)
		-- the torch: prefab pole stays as the (invisible) collision, the Neon flame block stays for its light and carries the particles
		local tiki = rule("tiki_torch")
		h.eq(tiki.collider, "orig")
		h.eq(tiki.keepLights, true)
		h.eq(tiki.flameFx, true)
		h.eq(tiki.keepShift, Vector3.new(0, -1, 0))
		h.eq(R.fitScale(tiki, R.ASSETS.tiki_torch, Vector3.new(1.8, 10.8, 1.8)), 1)
		h.ok(R.keepPart(tiki, "Neon", true) and not R.keepPart(tiki, "Wood", false), "the light-carrying flame block stays, the wood goes")
		h.ok(R.FLAME_FX.flame.rate <= 12 and R.FLAME_FX.embers.rate <= 4, "torch flame stays small")
		local swapSrc = h.readFile("src/server/kit/ArtSwap.luau")
		h.contains(swapSrc, "if rule.flameFx and p:FindFirstChildWhichIsA(\"Light\") then")
		h.contains(swapSrc, "p.Transparency = 1")
		-- the hedge keeps its stretch, the autumn tree its trunk box
		h.eq(rule("hedge").stretch, 1.02)
		h.eq(rule("autumn_oak").collider, "trunk")
		-- the three Creator Store stand-ins are gone from the ledger, the bakes and the project mounts (audit D5)
		local ledger = h.readFile("docs/ASSETS_TOOLBOX_TEMP.md")
		local project = h.readFile("default.project.json")
		local bakes = h.readFile("build/model_bakes/manifest.json")
		for _, id in { "12182258755", "241615822", "89148106" } do
			h.ok(string.match(ledger, "\n| " .. id .. " |") == nil, id .. " has no ledger row")
			h.ok(string.find(project, id, 1, true) == nil, id .. " is not mounted in default.project.json")
			h.ok(string.find(bakes, id, 1, true) == nil, id .. " is not in the model bake manifest")
		end
	end)
end
