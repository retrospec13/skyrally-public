--!strict
-- Art swap rules (owner: "many of the arches are just 6-7 blocks with spaces between them", trees are blocky): which
-- compiled-builder prefab models (build/<map>/builder_module.luau: one Model per instance, Name = prefab key without the
-- "#n" suffix, attribute Prefab = the full key) are replaced at runtime by the uploaded art, and the pure maths that fits a
-- mesh to the original's bounding box. Pure data and functions (no services, no yields): server/kit/ArtSwap does the Instance
-- work, tools/tests/artswap_spec.luau runs this module under Lune.
--
-- The art is art v3 (assets/models/{foliage_v3,props_v3,arches_v3}/manifest.json; the owner rejected the v2 meshes, so no v2
-- id is referenced at runtime) plus the world_v1 meshes that v3 does not replace (the bush, and the DINO course arches:
-- portal_gate's opening is narrower than theirs). v3 meshes are textured (the albedo is in the upload; MeshPart.Color stays
-- white, no tint, no vertex colours). Trees and arches are authored in the prefab's own frame, so arches sit at a fixed scale
-- on the prefab origin; foliage fits by height as the oaks do.
--
-- Pending art: a rule whose mesh has no ASSETS entry yet stays in RULES but never matches (ArtSwapRules.ready), so the prefab stays as built. When the
-- redone mesh is judged and uploaded, adding its id to the V3 id table and its manifest numbers to ASSETS switches the rule on.
--
-- Left alone on purpose (no matching mesh, or the shape is not worth a swap): snow pines (PropLibrary snow_pine_cluster
-- already), the HUB shrubs and planters (round, not blocks), aqueduct, bridges, ring gates and the alcove arch (the prefab
-- also holds the key plinth), DINO ruin arches and fossil ribs (PropLibrary), the far HorizonPalm scenery, the FOREST tunnel
-- portal, the SPACE vault and sign gantries, the HUB promenade lamps and the DINO cliff ferns (v3 has no replacement for
-- them). Boost pads are placed by kit/Gameplay (boost_pad mesh, the game's own Neon chevrons, BasePlate stays the trigger); the cannon sign is code-built
-- (WorldSetPieces) and loads sign_post itself.

local ArtSwapRules = {}

export type Asset = {
	size: Vector3, -- mesh bounding box at scale 1 (manifest size_studs_xyz)
	centre: Vector3, -- bounding box centre in the mesh's own origin frame (manifest bbox_min/max midpoint)
	bury: number, -- how far the bbox reaches below the mesh's ground plane (y = 0), studs at scale 1
	-- Height the fit divides the original's height by, when the mesh is not the prefab's height: the windmill tower is 78.47
	-- tall against the prefab's 78, and the sails' hub must stay on the axle, so each instance takes its own scale.
	fitHeight: number?,
	-- Invisible colliders for arches that collided originally, in the mesh origin frame at scale 1: centre and size, plus an
	-- optional turn about Y in degrees (the windmill's octagon sections are four boxes at 0/45/90/135).
	colliders: { { centre: Vector3, size: Vector3, yaw: number? } }?,
	pierFront: number?, -- z of the pier shaft's front face (studs at scale 1), where hung banners are re-seated
}

-- Manifest numbers, verbatim. world_v1 portal_arch: opening 18 wide x 18.65 high, shafts at |x| 9.4..13, feet to 15.4.
-- world_v1 stone_arch: opening 32 wide x 15 high, towers |x| 16..22.6 and 13.25 high.
ArtSwapRules.ASSETS = {
	bush = { size = Vector3.new(9.17, 5.07, 8.47), centre = Vector3.new(-0.07, 2.345, 0.035), bury = 0.19 },
	portal_arch = {
		size = Vector3.new(30.84, 22.27, 8.44),
		centre = Vector3.new(0, 11.115, 0.005),
		bury = 0.02,
		pierFront = 3.0,
		colliders = {
			{ centre = Vector3.new(-12.2, 4.5, 0), size = Vector3.new(6.4, 9, 8.4) },
			{ centre = Vector3.new(12.2, 4.5, 0), size = Vector3.new(6.4, 9, 8.4) },
			{ centre = Vector3.new(0, 20.5, 0), size = Vector3.new(26, 3.6, 6.2) },
		},
	},
	stone_arch = {
		size = Vector3.new(45.22, 18.78, 8.63),
		centre = Vector3.new(-0.005, 9.37, 0.004),
		bury = 0.02,
		colliders = {
			{ centre = Vector3.new(-19.3, 6.6, 0), size = Vector3.new(6.6, 13.25, 8.6) },
			{ centre = Vector3.new(19.3, 6.6, 0), size = Vector3.new(6.6, 13.25, 8.6) },
			{ centre = Vector3.new(0, 16.9, 0), size = Vector3.new(24, 3.8, 6.4) },
		},
	},
	-- art v3 (manifest numbers, verbatim). foliage_v3: origin = trunk centre at the ground (the bbox is not centred on it). arches_v3
	-- and the windmill/sign/lamp props are authored in their prefab's own frame; props_v3 GLBs are pre-turned 180 degrees about Y
	-- for the importer's turn, so after import the mesh frame is the prefab frame (front = -Z). Colliders are boxes outside the
	-- clear opening (the opening checks in tools/check_arch_openings.py) and only exist where the original collided.
	poplar = { size = Vector3.new(9.23, 33, 10.4), centre = Vector3.new(0.028, 16.15, 0.637), bury = 0.35 },
	round_oak = { size = Vector3.new(13.86, 18.3, 12.79), centre = Vector3.new(0.179, 8.8, -0.554), bury = 0.35 },
	stone_arch_v3 = { size = Vector3.new(109, 83.483, 16), centre = Vector3.new(-0.136, 40.242, 0), bury = 1.5,
		colliders = {
			{ centre = Vector3.new(-33.136, 2.233, 0), size = Vector3.new(4, 7.5, 13.6) },
			{ centre = Vector3.new(50.864, 2.608, 0), size = Vector3.new(4, 8.25, 13.6) },
			{ centre = Vector3.new(34.864, 3.608, 0), size = Vector3.new(4, 10.25, 13.6) },
			{ centre = Vector3.new(-37.136, 13.108, 0), size = Vector3.new(4, 29.25, 13.6) },
			{ centre = Vector3.new(-49.136, 20.483, 0), size = Vector3.new(4, 44, 13.6) },
			{ centre = Vector3.new(46.864, 23.983, 0), size = Vector3.new(4, 51, 13.6) },
			{ centre = Vector3.new(-45.136, 27.233, 0), size = Vector3.new(4, 57.5, 13.6) },
			{ centre = Vector3.new(42.864, 28.733, 0), size = Vector3.new(4, 60.5, 13.6) },
			{ centre = Vector3.new(-41.136, 29.858, 0), size = Vector3.new(4, 62.75, 13.6) },
			{ centre = Vector3.new(38.864, 30.858, 0), size = Vector3.new(4, 64.75, 13.6) },
			{ centre = Vector3.new(50.864, 32.358, 0), size = Vector3.new(4, 7.25, 13.6) },
			{ centre = Vector3.new(-37.136, 47.233, 0), size = Vector3.new(4, 36.5, 13.6) },
			{ centre = Vector3.new(34.864, 54.983, 0), size = Vector3.new(4, 25, 13.6) },
			{ centre = Vector3.new(-33.136, 58.858, 0), size = Vector3.new(4, 21.75, 13.6) },
			{ centre = Vector3.new(30.864, 60.983, 0), size = Vector3.new(4, 21, 13.6) },
			{ centre = Vector3.new(-29.136, 62.358, 0), size = Vector3.new(4, 19.75, 13.6) },
			{ centre = Vector3.new(26.864, 63.733, 0), size = Vector3.new(4, 18.5, 13.6) },
			{ centre = Vector3.new(-25.136, 65.108, 0), size = Vector3.new(4, 17.25, 13.6) },
			{ centre = Vector3.new(22.864, 66.483, 0), size = Vector3.new(4, 16, 13.6) },
			{ centre = Vector3.new(-21.136, 67.358, 0), size = Vector3.new(4, 16.25, 13.6) },
			{ centre = Vector3.new(18.864, 68.108, 0), size = Vector3.new(4, 16.25, 13.6) },
			{ centre = Vector3.new(-5.136, 70.983, 0), size = Vector3.new(4, 20.5, 13.6) },
			{ centre = Vector3.new(2.864, 71.108, 0), size = Vector3.new(4, 20.75, 13.6) },
			{ centre = Vector3.new(-1.136, 71.233, 0), size = Vector3.new(4, 21, 13.6) },
			{ centre = Vector3.new(-17.136, 68.983, 0), size = Vector3.new(4, 16, 13.6) },
			{ centre = Vector3.new(14.864, 69.733, 0), size = Vector3.new(4, 16, 13.6) },
			{ centre = Vector3.new(6.864, 71.483, 0), size = Vector3.new(4, 19, 13.6) },
			{ centre = Vector3.new(-13.136, 70.483, 0), size = Vector3.new(4, 16, 13.6) },
			{ centre = Vector3.new(10.864, 71.358, 0), size = Vector3.new(4, 17.25, 13.6) },
			{ centre = Vector3.new(-9.136, 71.858, 0), size = Vector3.new(4, 18.25, 13.6) },
		},
	},
	portal_gate = { size = Vector3.new(50.328, 44.956, 9), centre = Vector3.new(-0.048, 21.978, 0), bury = 0.5, pierFront = 4.5,
		colliders = {
			{ centre = Vector3.new(16.288, 1.081, 0), size = Vector3.new(4, 3.25, 7.65) },
			{ centre = Vector3.new(-19.712, 16.581, 0), size = Vector3.new(4, 34.25, 7.65) },
			{ centre = Vector3.new(20.288, 17.706, 0), size = Vector3.new(4, 36.5, 7.65) },
			{ centre = Vector3.new(0.288, 36.706, 0), size = Vector3.new(4, 11.5, 7.65) },
			{ centre = Vector3.new(-3.712, 36.956, 0), size = Vector3.new(4, 12, 7.65) },
			{ centre = Vector3.new(16.288, 32.081, 0), size = Vector3.new(4, 1.75, 7.65) },
			{ centre = Vector3.new(-9.712, 35.331, 0), size = Vector3.new(8, 8.25, 7.65) },
			{ centre = Vector3.new(10.288, 35.331, 0), size = Vector3.new(8, 8.25, 7.65) },
			{ centre = Vector3.new(4.288, 37.831, 0), size = Vector3.new(4, 13.25, 7.65) },
			{ centre = Vector3.new(-15.712, 32.331, 0), size = Vector3.new(4, 1.75, 7.65) },
			{ centre = Vector3.new(20.288, 37.831, 0), size = Vector3.new(4, 3.25, 7.65) },
			{ centre = Vector3.new(-19.712, 37.956, 0), size = Vector3.new(4, 3, 7.65) },
			{ centre = Vector3.new(16.288, 38.081, 0), size = Vector3.new(4, 2.25, 7.65) },
			{ centre = Vector3.new(-15.712, 38.331, 0), size = Vector3.new(4, 2.25, 7.65) },
		},
	},
	snow_finish_gantry = { size = Vector3.new(125.142, 82.455, 11), centre = Vector3.new(0, 38.227, 0), bury = 3,
		colliders = {
			{ centre = Vector3.new(-57.071, 1.705, 0), size = Vector3.new(4, 9.5, 9.35) },
			{ centre = Vector3.new(58.929, 31.83, 0), size = Vector3.new(4, 69.75, 9.35) },
			{ centre = Vector3.new(26.929, 54.33, 0), size = Vector3.new(4, 14.25, 9.35) },
			{ centre = Vector3.new(22.929, 54.455, 0), size = Vector3.new(4, 14.5, 9.35) },
			{ centre = Vector3.new(50.929, 54.455, 0), size = Vector3.new(4, 14.5, 9.35) },
			{ centre = Vector3.new(18.929, 54.58, 0), size = Vector3.new(4, 14.75, 9.35) },
			{ centre = Vector3.new(30.929, 54.58, 0), size = Vector3.new(4, 14.75, 9.35) },
			{ centre = Vector3.new(46.929, 54.58, 0), size = Vector3.new(4, 14.75, 9.35) },
			{ centre = Vector3.new(-29.071, 54.705, 0), size = Vector3.new(12, 15, 9.35) },
			{ centre = Vector3.new(-15.071, 54.705, 0), size = Vector3.new(8, 15, 9.35) },
			{ centre = Vector3.new(42.929, 54.705, 0), size = Vector3.new(4, 15, 9.35) },
			{ centre = Vector3.new(54.929, 54.705, 0), size = Vector3.new(4, 15, 9.35) },
			{ centre = Vector3.new(-37.071, 54.83, 0), size = Vector3.new(4, 15.25, 9.35) },
			{ centre = Vector3.new(-3.071, 54.83, 0), size = Vector3.new(16, 15.25, 9.35) },
			{ centre = Vector3.new(14.929, 54.83, 0), size = Vector3.new(4, 15.25, 9.35) },
			{ centre = Vector3.new(-41.071, 54.955, 0), size = Vector3.new(4, 15.5, 9.35) },
			{ centre = Vector3.new(8.929, 54.955, 0), size = Vector3.new(8, 15.5, 9.35) },
			{ centre = Vector3.new(36.929, 54.955, 0), size = Vector3.new(8, 15.5, 9.35) },
			{ centre = Vector3.new(-55.071, 55.205, 0), size = Vector3.new(8, 16, 9.35) },
			{ centre = Vector3.new(-45.071, 55.205, 0), size = Vector3.new(4, 16, 9.35) },
			{ centre = Vector3.new(-49.071, 55.455, 0), size = Vector3.new(4, 16.5, 9.35) },
			{ centre = Vector3.new(-21.071, 54.83, 0), size = Vector3.new(4, 14.75, 9.35) },
			{ centre = Vector3.new(58.929, 69.33, 0), size = Vector3.new(4, 1.75, 9.35) },
			{ centre = Vector3.new(58.929, 74.705, 0), size = Vector3.new(4, 5.5, 9.35) },
		},
	},
	cavern_arch = { size = Vector3.new(91.039, 77.619, 13), centre = Vector3.new(-0.074, 37.309, 0), bury = 1.5,
		colliders = {
			{ centre = Vector3.new(-40.093, 5.119, 0), size = Vector3.new(4, 13, 11.05) },
			{ centre = Vector3.new(39.907, 7.619, 0), size = Vector3.new(4, 18, 11.05) },
			{ centre = Vector3.new(-36.093, 21.994, 0), size = Vector3.new(4, 46.75, 11.05) },
			{ centre = Vector3.new(35.907, 22.119, 0), size = Vector3.new(4, 47, 11.05) },
			{ centre = Vector3.new(-40.093, 21.119, 0), size = Vector3.new(4, 7.5, 11.05) },
			{ centre = Vector3.new(39.907, 21.244, 0), size = Vector3.new(4, 7.75, 11.05) },
			{ centre = Vector3.new(39.907, 33.619, 0), size = Vector3.new(4, 15, 11.05) },
			{ centre = Vector3.new(-40.093, 33.744, 0), size = Vector3.new(4, 14.75, 11.05) },
			{ centre = Vector3.new(-32.093, 45.619, 0), size = Vector3.new(4, 12.5, 11.05) },
			{ centre = Vector3.new(31.907, 40.869, 0), size = Vector3.new(4, 1.5, 11.05) },
			{ centre = Vector3.new(31.907, 46.869, 0), size = Vector3.new(4, 10, 11.05) },
			{ centre = Vector3.new(-28.093, 51.869, 0), size = Vector3.new(4, 7.5, 11.05) },
			{ centre = Vector3.new(27.907, 51.994, 0), size = Vector3.new(4, 7.25, 11.05) },
			{ centre = Vector3.new(-24.093, 56.619, 0), size = Vector3.new(4, 8, 11.05) },
			{ centre = Vector3.new(23.907, 57.369, 0), size = Vector3.new(4, 9, 11.05) },
			{ centre = Vector3.new(-20.093, 61.619, 0), size = Vector3.new(4, 11.5, 11.05) },
			{ centre = Vector3.new(19.907, 61.869, 0), size = Vector3.new(4, 11.5, 11.05) },
			{ centre = Vector3.new(-16.093, 64.369, 0), size = Vector3.new(4, 12.5, 11.05) },
			{ centre = Vector3.new(15.907, 64.494, 0), size = Vector3.new(4, 12.75, 11.05) },
			{ centre = Vector3.new(-12.093, 66.494, 0), size = Vector3.new(4, 12.75, 11.05) },
			{ centre = Vector3.new(11.907, 66.994, 0), size = Vector3.new(4, 12.25, 11.05) },
			{ centre = Vector3.new(-4.093, 68.369, 0), size = Vector3.new(4, 15, 11.05) },
			{ centre = Vector3.new(3.907, 68.369, 0), size = Vector3.new(4, 15, 11.05) },
			{ centre = Vector3.new(-0.093, 68.619, 0), size = Vector3.new(4, 15, 11.05) },
			{ centre = Vector3.new(7.907, 68.744, 0), size = Vector3.new(4, 14.25, 11.05) },
			{ centre = Vector3.new(-8.093, 68.744, 0), size = Vector3.new(4, 13.75, 11.05) },
		},
	},
	mine_portal = { size = Vector3.new(67.928, 51.727, 12), centre = Vector3.new(-0.007, 23.863, 0), bury = 2,
		colliders = {
			{ centre = Vector3.new(-28.471, 2.852, 0), size = Vector3.new(4, 9.75, 10.2) },
			{ centre = Vector3.new(27.529, 21.727, 0), size = Vector3.new(4, 47.5, 10.2) },
			{ centre = Vector3.new(-28.471, 27.727, 0), size = Vector3.new(4, 34, 10.2) },
			{ centre = Vector3.new(-24.471, 30.352, 0), size = Vector3.new(4, 1.25, 10.2) },
			{ centre = Vector3.new(23.529, 38.352, 0), size = Vector3.new(4, 14.75, 10.2) },
			{ centre = Vector3.new(-20.471, 40.227, 0), size = Vector3.new(4, 13.5, 10.2) },
			{ centre = Vector3.new(19.529, 40.602, 0), size = Vector3.new(4, 14.25, 10.2) },
			{ centre = Vector3.new(15.529, 40.977, 0), size = Vector3.new(4, 15, 10.2) },
			{ centre = Vector3.new(-24.471, 39.602, 0), size = Vector3.new(4, 11.75, 10.2) },
			{ centre = Vector3.new(-12.471, 41.102, 0), size = Vector3.new(12, 14.75, 10.2) },
			{ centre = Vector3.new(9.529, 41.227, 0), size = Vector3.new(8, 15, 10.2) },
			{ centre = Vector3.new(-4.471, 41.352, 0), size = Vector3.new(4, 15.25, 10.2) },
			{ centre = Vector3.new(3.529, 41.477, 0), size = Vector3.new(4, 15.5, 10.2) },
			{ centre = Vector3.new(-0.471, 41.602, 0), size = Vector3.new(4, 15.75, 10.2) },
			{ centre = Vector3.new(31.529, 41.477, 0), size = Vector3.new(4, 3, 10.2) },
		},
	},
	windmill_tower = { size = Vector3.new(36.902, 78.471, 37.869), centre = Vector3.new(0, 35.236, 0.207), bury = 4,
		fitHeight = 78,
		colliders = {
			{ centre = Vector3.new(0, 3.847, 0), size = Vector3.new(35.796, 15.694, 14.827) },
			{ centre = Vector3.new(0, 3.847, 0), size = Vector3.new(35.796, 15.694, 14.827), yaw = 45 },
			{ centre = Vector3.new(0, 3.847, 0), size = Vector3.new(35.796, 15.694, 14.827), yaw = 90 },
			{ centre = Vector3.new(0, 3.847, 0), size = Vector3.new(35.796, 15.694, 14.827), yaw = 135 },
			{ centre = Vector3.new(0, 19.541, 0), size = Vector3.new(36.568, 15.694, 15.147) },
			{ centre = Vector3.new(0, 19.541, 0), size = Vector3.new(36.568, 15.694, 15.147), yaw = 45 },
			{ centre = Vector3.new(0, 19.541, 0), size = Vector3.new(36.568, 15.694, 15.147), yaw = 90 },
			{ centre = Vector3.new(0, 19.541, 0), size = Vector3.new(36.568, 15.694, 15.147), yaw = 135 },
			{ centre = Vector3.new(0, 35.236, 0), size = Vector3.new(30.369, 15.694, 12.579) },
			{ centre = Vector3.new(0, 35.236, 0), size = Vector3.new(30.369, 15.694, 12.579), yaw = 45 },
			{ centre = Vector3.new(0, 35.236, 0), size = Vector3.new(30.369, 15.694, 12.579), yaw = 90 },
			{ centre = Vector3.new(0, 35.236, 0), size = Vector3.new(30.369, 15.694, 12.579), yaw = 135 },
			{ centre = Vector3.new(0, 50.93, 0), size = Vector3.new(32.251, 15.694, 13.359) },
			{ centre = Vector3.new(0, 50.93, 0), size = Vector3.new(32.251, 15.694, 13.359), yaw = 45 },
			{ centre = Vector3.new(0, 50.93, 0), size = Vector3.new(32.251, 15.694, 13.359), yaw = 90 },
			{ centre = Vector3.new(0, 50.93, 0), size = Vector3.new(32.251, 15.694, 13.359), yaw = 135 },
			{ centre = Vector3.new(0, 66.624, 0), size = Vector3.new(32.645, 15.694, 13.522) },
			{ centre = Vector3.new(0, 66.624, 0), size = Vector3.new(32.645, 15.694, 13.522), yaw = 45 },
			{ centre = Vector3.new(0, 66.624, 0), size = Vector3.new(32.645, 15.694, 13.522), yaw = 90 },
			{ centre = Vector3.new(0, 66.624, 0), size = Vector3.new(32.645, 15.694, 13.522), yaw = 135 },
		},
	},
	windmill_sails = { size = Vector3.new(77.023, 77.023, 7.1), centre = Vector3.new(0, 0, -4.65), bury = 38.511 },
	lamp_post = { size = Vector3.new(4.06, 17.96, 4.08), centre = Vector3.new(0, 8.98, 0), bury = 0,
		colliders = {
			{ centre = Vector3.new(0, 0.95, 0), size = Vector3.new(3.6, 1.9, 3.6) },
			{ centre = Vector3.new(0, 7.3, 0), size = Vector3.new(1.1, 10.8, 1.1) },
			{ centre = Vector3.new(0, 15.2, 0), size = Vector3.new(3.4, 4.6, 3.4) },
		},
	},
	-- art round 7 (Hunyuan3D LowPoly via Higgsfield; manifest numbers, verbatim). start_gantry: authored in the prefab frame (opening
	-- centred on x = 0, front = -Z), colliders are the two post boxes outside the opening; hedge: 32 long tile, long axis X; autumn_tree:
	-- origin = trunk axis at the ground; tiki_torch: origin = stone base footprint at the ground (the flame is particles, not baked).
	start_gantry = { size = Vector3.new(90.969, 42.84, 11), centre = Vector3.new(0, 21.12, 0), bury = 0.3,
		colliders = {
			{ centre = Vector3.new(39.64, 13.1, 0), size = Vector3.new(11.69, 26.8, 9) },
			{ centre = Vector3.new(-39.64, 13.1, 0), size = Vector3.new(11.69, 26.8, 9) },
		},
	},
	hedge = { size = Vector3.new(32, 7.99, 7.25), centre = Vector3.new(-0.028, 3.687, 0), bury = 0.31,
		colliders = { { centre = Vector3.new(0, 3.6, 0), size = Vector3.new(32, 7.6, 7.2) } },
	},
	autumn_tree = { size = Vector3.new(16.5, 22, 19.02), centre = Vector3.new(-0.0325, 10.6495, -0.0595), bury = 0.351 },
	tiki_torch = { size = Vector3.new(3.49, 9.48, 3.54), centre = Vector3.new(0.024, 4.467, -0.208), bury = 0.273,
		colliders = { { centre = Vector3.new(0, 4.7, 0), size = Vector3.new(3.2, 9.4, 3.2) } },
	},
	cypress = { size = Vector3.new(9.16, 31, 9.77), centre = Vector3.new(0.0265, 15.15, 0.144), bury = 0.35 },
	space_arch = { size = Vector3.new(77.13, 54.444, 10), centre = Vector3.new(0, 26.422, 0), bury = 0.8 },
	mesa_portal = { size = Vector3.new(69.57, 54.409, 10), centre = Vector3.new(0, 25.304, 0), bury = 1.9,
		colliders = {
			{ centre = Vector3.new(27.7, 16.3, 0), size = Vector3.new(14.2, 36.4, 8.5) },
			{ centre = Vector3.new(-27.7, 16.3, 0), size = Vector3.new(14.2, 36.4, 8.5) },
			{ centre = Vector3.new(0, 43.5, 0), size = Vector3.new(69.6, 18, 8.5) },
		},
	},
	-- banner_pole's crossbar runs to prefab +X (the manifest bbox is in the prefab frame; file_bbox_* is the GLB's own).
	banner_pole = { size = Vector3.new(8.81, 15.2, 4.56), centre = Vector3.new(1.998, 7.4, -0.241), bury = 0.2 },
	boost_pad = { size = Vector3.new(16.1, 1.2, 24.2), centre = Vector3.new(0, 0.6, 0), bury = 0 },
	sign_post = { size = Vector3.new(8.17, 8.45, 1.78), centre = Vector3.new(0, 3.624, 0.003), bury = 0.602,
		colliders = {
			{ centre = Vector3.new(-3.3, 3.7, 0), size = Vector3.new(1.3, 8, 1.3) },
			{ centre = Vector3.new(3.3, 3.7, 0), size = Vector3.new(1.3, 8, 1.3) },
		},
	},
} :: { [string]: Asset }

-- Fit numbers of the Creator Store stand-ins' meshes (src/shared/ToolboxTempAssets MESHES keys; the bake report in
-- build/model_bakes/manifest.json): kept apart from ASSETS, which the manifests of the in-house art are checked against.
ArtSwapRules.STOPGAP_ASSETS = {
	-- empty: the hedge stand-in was replaced by the in-house hedge (art round 7)
} :: { [string]: Asset }

-- A mesh's fit numbers: the in-house art's (ASSETS), else a Creator Store stand-in's.
function ArtSwapRules.asset(name: string): Asset?
	return ArtSwapRules.ASSETS[name] or ArtSwapRules.STOPGAP_ASSETS[name]
end

export type Rule = {
	id: string,
	kind: string, -- "tree" | "hedge" | "palm" | "arch" | "portal" | "prop"
	prefabs: { string }, -- Lua patterns on the full Prefab key (anchored)
	zones: { string }?, -- TrackData.zone filter; nil = every map
	meshes: { string }?, -- ASSETS keys: trees pick by position hash, arches by best aspect match
	prop: string?, -- PropLibrary key (palm clusters)
	align: string, -- "origin": mesh sits on the prefab's local origin; "bbox": centred on the original's bbox
	slack: number, -- the mesh may be this much wider than the original bbox (height still limits)
	scale: number?, -- fixed scale (art v3 arches: 1, the cavern mouth 1.07)
	stretch: number?, -- tileable modules: X spans the original's X extent times this overlap, Y and Z fit by height
	varyYaw: boolean?, -- turn the mesh about its own origin by a stable per-position angle (one tree model, many looks)
	trim: string?, -- ASSETS key of a Neon trim placed with the same transform
	keepMaterials: { [string]: boolean }?, -- original parts of these materials stay (veils, banners, neon strips)
	keepLights: boolean?, -- original parts carrying a Light stay
	tint: boolean?, -- tint the grey stone mesh to the original's dominant stone colour
	collider: string?, -- "trunk": box under a swapped tree; "orig": the original colliding parts stay, invisible; "arch": mesh colliders
	keepShift: Vector3?, -- kept non-Fabric parts move by this much in the prefab frame (the banner pole's flag hangs from the new crossbar)
	hideFabric: boolean?, -- kept Fabric parts (hung banners) turn invisible, collision untouched (the hub portals: they read as dark slabs beside the opening)
	veilTransparency: number?, -- kept Glass parts (the portal veil) are set to this Transparency (the client PortalFill disc is the portal now)
	trunk: { w: number, h: number }?, -- trunk box as fractions of the fitted mesh height
	-- The mesh is not placed: the rule still removes the original's blocks (keeping what keepMaterials/keepLights keep) and
	-- places the mesh's colliders exactly as with the mesh, while the visual is a separate block-built prefab of the plan
	-- (HUB tunnel mouths: the carved CliffTunnelCollar, critic v29 Wave 2), so collision is unchanged and no mesh is
	-- loaded only to be hidden (ART_BAR). Its mesh is never fetched (ArtSwapRules.placesMesh).
	collidersOnly: boolean?,
	flameFx: boolean?, -- kept light parts (the builder's yellow Neon flame block) turn invisible with no collision/query/touch, keep their Light, and carry a small particle flame + embers (swap time; the bake is untouched)
	stopgap: boolean?, -- a Creator Store stand-in (docs/ASSETS_TOOLBOX_TEMP.md): placed after the rule for the in-house mesh it holds the place of; delete both together
}

local ROUND_OAK = { "round_oak" }
local TREE_TRUNK = { w = 0.17, h = 0.4 } -- manifest: a 3.1 x 7.3 x 3.1 trunk box under an 18.3 tall oak
local POPLAR_TRUNK = { w = 0.055, h = 0.48 } -- manifest: a 1.8 x 15.8 x 1.8 trunk box under a 33 tall poplar

ArtSwapRules.RULES = {
	-- One round_oak model for every oak; the variety is the yaw (stable per position) and the scale (each tree's own height).
	{ id = "oak_round", kind = "tree", prefabs = { "^RoundTree_%d+$" }, meshes = ROUND_OAK, align = "origin", slack = 1.15,
		varyYaw = true, collider = "trunk", trunk = TREE_TRUNK },
	{ id = "oak_broadleaf", kind = "tree", prefabs = { "^BroadleafTree#%d+$" }, meshes = ROUND_OAK, align = "origin", slack = 1.15,
		varyYaw = true, collider = "trunk", trunk = TREE_TRUNK },
	{ id = "bush", kind = "tree", prefabs = { "^Bush_%d+$" }, meshes = { "bush" }, align = "origin", slack = 1.15,
		collider = "trunk", trunk = { w = 0.45, h = 0.6 } },
	-- Palms: the uploaded 3-palm clusters when their template loads. The originals' colliding parts (the low trunk) stay,
	-- invisible, so the collision is exactly today's. HorizonPalm# is far scenery and stays as built.
	{ id = "palm_hub", kind = "palm", prefabs = { "^PalmTree#%d+$" }, zones = { "HUB" }, prop = "hub_palm_cluster", align = "origin",
		slack = 1.1, collider = "orig" },
	{ id = "palm_island", kind = "palm", prefabs = { "^PalmTree#%d+$" }, zones = { "ISLAND" }, prop = "island_palm_cluster", align = "origin",
		slack = 1.1, collider = "orig" },
	-- DINO-4 course arches (all non-colliding): the world_v1 portal arch is the closer aspect for these tall landmark arches;
	-- the wide stone arch wins automatically for a low arch (pickArch). arches_v3 portal_gate was tried here and refused:
	-- scaled to the course arches its piers stand inside their opening (tools/check_arch_openings.py dino_arch).
	{ id = "dino_arch", kind = "arch", prefabs = { "^StoneArchway_S%d+$", "^StartForegroundArch$", "^FTUEFinishArch$", "^StartFinishGate$" },
		zones = { "DINO" }, meshes = { "portal_arch", "stone_arch" }, align = "bbox", slack = 1.12, tint = true,
		keepMaterials = { Neon = true, Glass = true }, keepLights = true, collider = "arch" },
	-- HUB zone portals: portal_gate (a flat lintel over a 30 wide open window, no masonry below y 30.96). The veil glass and its
	-- cap, the banner cloth and the light stay; TrackFlow.labelPortals hangs the zone sign (26 x 5.5, centre y 26) and its
	-- "needs N Sky" label in that window, clear of the piers and 2.2 under the lintel, so the crown no longer hides them.
	{ id = "hub_portal", kind = "portal", prefabs = { "^PortalArch_%u+$" }, zones = { "HUB" }, meshes = { "portal_gate" }, align = "origin",
		slack = 1, scale = 1, keepMaterials = { Glass = true, Fabric = true }, keepLights = true, collider = "arch", hideFabric = true, veilTransparency = 0.94 },

	-- Art v3 foliage (foliage_v3). Canopies do not collide (the oak precedent); a trunk box stands where the original collided.
	{ id = "poplar", kind = "tree", prefabs = { "^Poplar_%d+$" }, zones = { "FOREST" }, meshes = { "poplar" }, align = "origin", slack = 1.15,
		varyYaw = true, collider = "trunk", trunk = POPLAR_TRUNK },
	-- The HUB cypress, the hedge rows (the v3 hedge is native 32 long; stretch 1.02 is its manifest's pitch overlap) and the FOREST
	-- autumn oaks are live (art round 7). Trunk fractions are the manifests'.
	{ id = "cypress", kind = "tree", prefabs = { "^CypressTree#%d+$" }, zones = { "HUB" }, meshes = { "cypress" }, align = "origin", slack = 1.15,
		varyYaw = true, collider = "trunk", trunk = { w = 0.065, h = 0.18 } },
	{ id = "autumn_oak", kind = "tree", prefabs = { "^AutumnTree_%d+$" }, zones = { "FOREST" }, meshes = { "autumn_tree" }, align = "origin",
		slack = 1.15, varyYaw = true, collider = "trunk", trunk = { w = 0.2, h = 0.34 } },
	{ id = "hedge", kind = "hedge", prefabs = { "^Hedge_%d+$" }, zones = { "FOREST" }, meshes = { "hedge" }, align = "origin", slack = 1.15,
		stretch = 1.02, collider = "arch" },
	-- The Creator Store hedge and autumn tree stand-ins were replaced by these rules (art round 7, docs/ASSETS_TOOLBOX_TEMP.md).

	-- Art v3 arches and gantries (arches_v3): authored in the prefab's own frame, so a fixed scale on the prefab origin. Neon
	-- gems, lanterns with their lights and lantern brackets stay (they sit in slots the mesh leaves); the mesh carries
	-- everything else, and its colliders stand outside the original's opening, only where the original collided.
	-- v29 Wave 2: the HUB tunnel mouths show the carved block collar (plan prefab CliffTunnelCollar); stone_arch_v3 keeps
	-- only its colliders here (collidersOnly), so the mouths collide exactly as before (owner: wall driving untouched).
	{ id = "cliff_tunnel_arch", kind = "arch", prefabs = { "^CliffTunnelArch$" }, zones = { "HUB" }, meshes = { "stone_arch_v3" },
		align = "origin", slack = 1, scale = 1, keepMaterials = { Neon = true }, keepLights = true, collider = "arch",
		collidersOnly = true },
	{ id = "mine_portal", kind = "arch", prefabs = { "^MineTunnelPortal$" }, zones = { "SNOW" }, meshes = { "mine_portal" }, align = "origin",
		slack = 1, scale = 1, keepMaterials = { Neon = true }, keepLights = true, collider = "arch" },
	-- The finish gantry keeps its blue sign plate (it sits on the new beam); the lanterns stand at x 52, inside the wider new
	-- posts' opening, so they go with the old blocks.
	{ id = "snow_finish_gantry", kind = "arch", prefabs = { "^FinishGantry$" }, zones = { "SNOW" }, meshes = { "snow_finish_gantry" },
		align = "origin", slack = 1, scale = 1, keepMaterials = { SmoothPlastic = true }, collider = "arch" },
	-- One cavern_arch for the ten ribs (scale 1, opening 63.4) and the mouth / exit arches (scale 1.07, opening 67.8).
	-- v28 critic 1.16: the wall torches' Neon cubes read as placeholders, so the kept flame block turns into the tiki torch's
	-- particle flame (flameFx) over the kept iron bracket and bronze cup (Metal); the PointLight stays.
	{ id = "cavern_rib", kind = "arch", prefabs = { "^CavernArchRib$" }, zones = { "ISLAND" }, meshes = { "cavern_arch" }, align = "origin",
		slack = 1, scale = 1, keepMaterials = { Metal = true }, keepLights = true, collider = "arch", flameFx = true },
	{ id = "cavern_mouth", kind = "arch", prefabs = { "^CavernMouthArch$", "^CavernExitArch$" }, zones = { "ISLAND" }, meshes = { "cavern_arch" },
		align = "origin", slack = 1, scale = 1.07, keepMaterials = { Metal = true }, keepLights = true, collider = "arch", flameFx = true },
	-- SPACE skyway arches (space_arch, bbox-aligned, non-colliding) and the SPACE mesa portal are live. The ISLAND / HUB start
	-- gantries (art round 7) (one start_gantry for both; its beam takes the volume the Fabric banner hung in, so drop Fabric from the keep).
	{ id = "skyway_arch", kind = "arch", prefabs = { "^SkywayArch_%d+$" }, zones = { "SPACE" }, meshes = { "space_arch" }, align = "bbox",
		slack = 1, scale = 1, keepLights = true },
	{ id = "mesa_portal", kind = "arch", prefabs = { "^MesaTunnelPortal$" }, zones = { "SPACE" }, meshes = { "mesa_portal" }, align = "origin",
		slack = 1, scale = 1, keepMaterials = { Neon = true }, keepLights = true, collider = "arch" },
	{ id = "island_start_gantry", kind = "arch", prefabs = { "^StartFinishArch$" }, zones = { "ISLAND" }, meshes = { "start_gantry" },
		align = "origin", slack = 1, scale = 1, keepLights = true, collider = "arch" },
	{ id = "hub_start_gantry", kind = "arch", prefabs = { "^StartFinishGantry$" }, zones = { "HUB" }, meshes = { "start_gantry" },
		align = "origin", slack = 1, scale = 1, keepLights = true, collider = "arch" },

	-- Art v3 props (props_v3). Windmills: the tower is 78.47 tall against the prefab's 78 (Asset.fitHeight), so the fit returns
	-- each instance's own scale (0.85-1.22) and the sails' hub still meets the axle; its footprint is 37 against 31, so the
	-- width cap is off (slack 1.25). The sails keep the Model and its SpinRPM attributes, so the client WorldAnim spins the new
	-- mesh about the same hub (the mesh origin); the original sails never collided and neither does the mesh.
	{ id = "windmill_tower", kind = "prop", prefabs = { "^Windmill$", "^Windmill#far$" }, zones = { "FOREST" }, meshes = { "windmill_tower" },
		align = "origin", slack = 1.25, collider = "arch" },
	{ id = "windmill_sails", kind = "prop", prefabs = { "^WindmillSails$" }, zones = { "FOREST" }, meshes = { "windmill_sails" },
		align = "origin", slack = 1.02 },
	-- The lamp's lantern is baked lit; the original's Neon block with its PointLight stays inside the closed mesh as the light.
	{ id = "plaza_lamp", kind = "prop", prefabs = { "^PlazaLamp$" }, zones = { "HUB" }, meshes = { "lamp_post" },
		align = "origin", slack = 1, scale = 1, keepLights = true, collider = "arch" },
	-- HUB banner poles: the coloured flag stays but moves out and down to hang from the new, longer crossbar (flag x 0.9..3.5 ->
	-- 3.4..6.0 under the iron rings at 3.8 / 4.8 / 5.65, top y 14.2 -> 11.2). ISLAND tiki torches (art round 7): the pole's collider stays, the flame is particles (flameFx) at the kept block, 1 stud lower to sit on the new bowl.
	{ id = "banner_pole", kind = "prop", prefabs = { "^BannerPole#%d+$" }, zones = { "HUB" }, meshes = { "banner_pole" }, align = "origin",
		slack = 1, scale = 1, keepMaterials = { SmoothPlastic = true }, keepShift = Vector3.new(2.5, -3, 0) },
	{ id = "tiki_torch", kind = "prop", prefabs = { "^TikiTorch$" }, zones = { "ISLAND" }, meshes = { "tiki_torch" },
		align = "origin", slack = 1, scale = 1, keepLights = true, collider = "orig", keepShift = Vector3.new(0, -1, 0), flameFx = true },
} :: { Rule }

-- Tiki flame stand-in particles (v22 polish: the yellow Neon block on the thin pole read cheap, so the block is invisible and
-- these emitters sit at its centre). Small, warm, slow: the torches line the road, never the chase camera's view.
ArtSwapRules.FLAME_FX = {
	flame = { rate = 9, life = { 0.4, 0.7 }, speed = { 1.2, 2.2 }, size = { 0.9, 1.2, 0 }, spread = 10, light = 1 },
	embers = { rate = 2.5, life = { 0.9, 1.6 }, speed = { 1.5, 3 }, size = { 0.18, 0.1, 0 }, spread = 25, light = 1 },
}

ArtSwapRules.STONE_BASE = 0.8 -- the world_v1 arch meshes' vertex colour is about 0.8 grey; MeshPart.Color multiplies it

local function hasValue(list: { string }?, v: string): boolean
	if not list then
		return true
	end
	for _, s in list do
		if s == v then
			return true
		end
	end
	return false
end

-- Is every mesh the rule places in ASSETS? A pending rule (its art is still being redone) is not ready and never matches.
function ArtSwapRules.ready(rule: Rule): boolean
	local meshes = rule.meshes
	if meshes then
		for _, name in meshes do
			if ArtSwapRules.asset(name) == nil then
				return false
			end
		end
	end
	if rule.trim and ArtSwapRules.asset(rule.trim) == nil then
		return false
	end
	return true
end

-- Whether a swap under this rule places (and so needs to load) its mesh: false for collidersOnly rules.
function ArtSwapRules.placesMesh(rule: Rule): boolean
	return rule.collidersOnly ~= true
end

-- First ready rule whose prefab pattern and zone match. prefab is the full key ("PalmTree#2"); falls back to the model name.
-- `pending` (specs only) also lets rules without art match, to check what they will cover.
function ArtSwapRules.match(prefab: string, zone: string?, pending: boolean?): Rule?
	for _, rule in ArtSwapRules.RULES do
		if zone ~= nil and rule.zones and not hasValue(rule.zones, zone) then
			continue
		end
		if not pending and not ArtSwapRules.ready(rule) then
			continue
		end
		for _, pat in rule.prefabs do
			if string.find(prefab, pat) then
				return rule
			end
		end
	end
	return nil
end

-- Stable 0..1 hash of a position, rounded to 0.5 stud so the same tree always gets the same oak across rebuilds.
function ArtSwapRules.hash(x: number, z: number): number
	local ix, iz = math.floor(x * 2 + 0.5), math.floor(z * 2 + 0.5)
	local h = (ix * 73856093 + iz * 19349663) % 2147483647
	h = (h * 48271 + 11) % 2147483647
	return h / 2147483647
end

function ArtSwapRules.pickMesh(meshes: { string }, x: number, z: number): string
	local i = math.floor(ArtSwapRules.hash(x, z) * #meshes) + 1
	return meshes[math.min(i, #meshes)]
end

-- Stable turn about Y (radians, 0..2 pi) for a rule with varyYaw: a different hash than the mesh pick, so they are independent.
function ArtSwapRules.yawFor(x: number, z: number): number
	return ArtSwapRules.hash(x + 41.5, z - 17.5) * math.pi * 2
end

-- Arches: the candidate whose width:height ratio is closest (in log terms) to the original bbox's.
function ArtSwapRules.pickArch(meshes: { string }, width: number, height: number): string
	local want = math.log(math.max(width, 0.01) / math.max(height, 0.01))
	local best, bestD = meshes[1], math.huge
	for _, name in meshes do
		local a = ArtSwapRules.ASSETS[name]
		local d = math.abs(math.log(a.size.X / a.size.Y) - want)
		if d < bestD then
			best, bestD = name, d
		end
	end
	return best
end

-- Uniform scale of `mesh` into an original bbox of `size` (pivot-local extents): the height decides, the horizontal
-- footprint may exceed the original by `slack` (arches: X width; trees: the larger of X and Z).
function ArtSwapRules.fitScale(rule: Rule, a: Asset, size: Vector3): number
	if rule.scale then
		return rule.scale
	end
	local byHeight = size.Y / (a.fitHeight or a.size.Y)
	local origW, meshW
	if rule.kind == "arch" or rule.kind == "portal" then
		origW, meshW = size.X, a.size.X
	else
		origW, meshW = math.max(size.X, size.Z), math.max(a.size.X, a.size.Z)
	end
	return math.max(0.05, math.min(byHeight, rule.slack * origW / meshW))
end

-- Uniform scale (a number) or a per-axis scale (a Vector3: stretched hedges), as one Vector3.
export type Scale = number | Vector3

function ArtSwapRules.scaleVec(s: Scale): Vector3
	if type(s) == "number" then
		return Vector3.new(s, s, s)
	end
	return s
end

-- Stretched modules (hedges): X spans the original's X extent times rule.stretch (the neighbours overlap, never gap), Y and Z
-- follow the height fit. The mesh's own X is its tiling axis.
function ArtSwapRules.stretchScale(rule: Rule, a: Asset, size: Vector3): Vector3
	local s = math.max(0.05, size.Y / a.size.Y)
	return Vector3.new(math.max(0.05, size.X * (rule.stretch or 1) / a.size.X), s, s)
end

-- Pivot-local position of the mesh's own origin frame (not its bbox centre) so the mesh stands on the original's ground:
-- "origin" rules stand on the prefab origin (y = 0), "bbox" rules centre on the bbox and sit on its bottom. A stretched
-- module is centred on the original's X extent (the prefab pivot of a hedge sits up to half a stud off its middle).
function ArtSwapRules.originPosition(rule: Rule, a: Asset, scale: number, bboxMin: Vector3, bboxMax: Vector3): Vector3
	if rule.align == "origin" then
		return Vector3.new(if rule.stretch then (bboxMin.X + bboxMax.X) * 0.5 else 0, 0, 0)
	end
	local cx = (bboxMin.X + bboxMax.X) * 0.5 - a.centre.X * scale
	local cz = (bboxMin.Z + bboxMax.Z) * 0.5 - a.centre.Z * scale
	-- bbox centre -> origin: the mesh's lowest point (bury below its y = 0) rests on the original's lowest point.
	return Vector3.new(cx, bboxMin.Y + a.bury * scale, cz)
end

-- Where the MeshPart's centre goes, pivot-local, given the mesh-origin position.
function ArtSwapRules.partCentre(a: Asset, scale: Scale, origin: Vector3): Vector3
	return origin + a.centre * ArtSwapRules.scaleVec(scale)
end

-- The MeshPart's pivot-local CFrame: partCentre, with the mesh turned `yaw` radians about its own origin (a tree's trunk), not
-- about its bbox centre, which sits off the trunk.
function ArtSwapRules.partCFrame(a: Asset, scale: Scale, origin: Vector3, yaw: number): CFrame
	return CFrame.new(origin) * CFrame.Angles(0, yaw, 0) * CFrame.new(a.centre * ArtSwapRules.scaleVec(scale))
end

-- Pivot-local AABB of a part with the given pivot-local CFrame and size (|R| * half-size), for the original's bbox.
function ArtSwapRules.localExtents(cf: CFrame, size: Vector3): (Vector3, Vector3)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
	local ex = math.abs(r00) * hx + math.abs(r01) * hy + math.abs(r02) * hz
	local ey = math.abs(r10) * hx + math.abs(r11) * hy + math.abs(r12) * hz
	local ez = math.abs(r20) * hx + math.abs(r21) * hy + math.abs(r22) * hz
	return Vector3.new(x - ex, y - ey, z - ez), Vector3.new(x + ex, y + ey, z + ez)
end

-- Colliders of a swapped arch as pivot-local boxes: the asset's boxes (mesh origin frame) scaled and moved by `origin`,
-- with their turn about Y in degrees (0 when the asset gives none).
function ArtSwapRules.archColliders(a: Asset, scale: Scale, origin: Vector3): { { centre: Vector3, size: Vector3, yaw: number } }
	local out = {}
	local list = a.colliders
	if list then
		local k = ArtSwapRules.scaleVec(scale)
		for _, c in list do
			table.insert(out, { centre = origin + c.centre * k, size = c.size * k, yaw = c.yaw or 0 })
		end
	end
	return out
end

-- Trunk box under a swapped tree: pivot-local centre and size from the fitted mesh height.
function ArtSwapRules.trunkBox(rule: Rule, a: Asset, scale: number, origin: Vector3): { centre: Vector3, size: Vector3 }
	local t = rule.trunk or TREE_TRUNK
	local height = a.size.Y * scale
	local w, h = t.w * height, t.h * height
	return { centre = origin + Vector3.new(0, h * 0.5, 0), size = Vector3.new(w, h, w) }
end

-- Name of the swapped-in MeshPart under the prefab Model.
function ArtSwapRules.partName(rule: Rule): string
	if rule.kind == "tree" then
		return "Tree"
	elseif rule.kind == "hedge" then
		return "Hedge"
	elseif rule.kind == "prop" then
		return "Prop"
	end
	return "Arch"
end

-- Does an original part stay (veil glass, banner cloth, light carriers, neon strips) rather than make way for the mesh?
function ArtSwapRules.keepPart(rule: Rule, material: string, hasLight: boolean): boolean
	if rule.keepLights and hasLight then
		return true
	end
	return rule.keepMaterials ~= nil and rule.keepMaterials[material] == true
end

-- PropLibrary props (pivot at the base centre, size = QC'd bbox) as an Asset, so the same fit maths applies.
function ArtSwapRules.propAsset(size: Vector3): Asset
	return { size = size, centre = Vector3.new(0, size.Y * 0.5, 0), bury = 0 }
end

-- Colour that dominates a set of {color, weight}: the colour with the largest summed weight (same hex counts together).
function ArtSwapRules.dominantColour(entries: { { color: Color3, weight: number } }): Color3?
	local sums: { [number]: number } = {}
	local colours: { [number]: Color3 } = {}
	local bestKey: number? = nil
	local bestW = -1
	for _, e in entries do
		local key = math.floor(e.color.R * 255 + 0.5) * 65536 + math.floor(e.color.G * 255 + 0.5) * 256 + math.floor(e.color.B * 255 + 0.5)
		sums[key] = (sums[key] or 0) + e.weight
		colours[key] = e.color
		if sums[key] > bestW then
			bestKey, bestW = key, sums[key]
		end
	end
	return if bestKey then colours[bestKey] else nil
end

-- MeshPart.Color for the grey stone meshes so their rendered stone matches the original's dominant colour.
function ArtSwapRules.stoneTint(original: Color3): Color3
	local base = ArtSwapRules.STONE_BASE
	return Color3.new(math.min(1, original.R / base), math.min(1, original.G / base), math.min(1, original.B / base))
end

-- Hung banners (kept Fabric parts) are re-seated in front of the new pier face: returns the new pivot-local z.
function ArtSwapRules.bannerZ(a: Asset, scale: number, origin: Vector3, oldZ: number, thickness: number): number
	local front = a.pierFront
	if not front then
		return oldZ
	end
	local clear = origin.Z - front * scale - thickness * 0.5 - 0.05
	return math.min(oldZ, clear)
end

return ArtSwapRules
