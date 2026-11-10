# 30MAPS notes

## Plan schema (BloxMap plan.json, verified on out/fort_condor_plan.json)

Verified by reading the JSON and the BloxMap plugin builder sources
(`src/BloxMapPlugin/Builder/Prefabs.luau`, `Voxels.luau`, `Util.luau`) in the mirror.

Top-level keys: `camera, generator, groups, instances, labels, library, lighting, markers, meta, prefabs, terrain, version`.

### instances (1559)
`{g, p, pf, r, s?}`
- `g`: group id, **1-based** index into `groups` (range 1..13). `groups` is a list of
  slash paths ("Village/Sierra Village/Lodge") -> built as nested Folders under `Workspace.Map`.
- `p`: `[x, y, z]` world position of the prefab pivot (prefab origin = bottom centre).
- `pf`: key into `prefabs`.
- `r`: **three shapes**: a number = yaw degrees (1241 instances), a list `[rx, ry, rz]` degrees
  (316, e.g. `[-18, 31.22, 18]` tilted rocks/logs), or missing/null (2: `lamp#4`, `mtn-teleport`) = identity.
  Rotation order is YXZ: `CFrame.fromEulerAnglesYXZ(rad rx, rad ry, rad rz)` (= Ry*Rx*Rz).
- `s`: optional uniform scale (12 instances, pines 0.65..0.98), applied about the pivot before rotation.
- World part CFrame = `CFrame.new(p) * R(r) * [scale s] * partCF`.

### prefabs (100)
`{h, r, parts}` (`h` height, `r` footprint radius; both informational).
`parts` = list of arrays (12 or 13 fields):
`[shape, x, y, z, sx, sy, sz, rx, ry, rz, colour "#rrggbb", material name, extra?]`
- offsets/sizes in studs in prefab space; part rotation also YXZ degrees.
- shapes in this plan: S 3031 (ellipsoid: Part + SpecialMesh Sphere), C 2877 (cylinder, plan axis = local Y,
  so Roblox Size = (sy, sx, sz) and an extra `Angles(0,0,pi/2)`), K 1867 (n-sided cone), B 1254 (block),
  W 561 (WedgePart).
- `extra`: `nc` = no collision (5827), `n` = cone sides (1867, every K), `l` = PointLight
  `[range, brightness, colour, shadows?]` (20). `a` (transparency) is supported but unused here.
- materials used: SmoothPlastic, Wood, Slate, Fabric, WoodPlanks, Neon, Metal (all valid Enum.Material names).
- Cones (K) are built once per side count with `IntersectAsync` of n wedges (port of the plugin);
  fallback = 3 tapered tiers if CSG fails at runtime.

### terrain
`{nx, nz, cell, x0, z0, heights[], materials[], ceilings[], roof, ceilingMaterial, floor, top, palette[], materialColors{}, water{}}`
- Node grid 193 x 193, cell 4, origin x0 = z0 = -384 -> covers -384..384 on X and Z.
- **Row-major**: node (ix, iz) is `heights[iz * nx + ix]` (0-based), world `(x0 + ix*cell, z0 + iz*cell)`.
  Verified empirically: at the Spawn marker (y 9.83) row-major gives h 9.3, column-major 0.7; at
  Checkpoint 1 marker (y 55.09) row-major 54.3 vs column-major 64.6.
- heights -19.6..215.2. `floor` -48 = bottom of the ground. `top` 215.2.
- `materials` are **1-based** indices into `palette` (values 1..9 here). palette entries
  `{key, material, color}`; material names are Enum.Material names (Grass, LeafyGrass, Sand, Rock, Slate,
  Ground, Concrete, Mud, Snow, CrackedLava, Basalt). Unknown -> Grass.
- `ceilings` (same grid) + `roof` 190.57 + `ceilingMaterial` 4 (rock): overhead rock from the ceiling
  underside up to the roof. ceiling >= roof = none; ceiling <= height (342 nodes) = solid wall up to roof.
  Here it forms the Summit Gate rock arch.
- `water` `{level 0, color, transparency, lava false}`: water fills from ground to level.
- `materialColors` is a material->colour table; we colour from `palette` instead (most-used entry wins per material).

### markers / labels / lighting
- markers: Spawn `{p, size [12,1,12], face [fx, fz]}`, Checkpoint x4 `{index, name, altitude, p, final?}`,
  Objective, Teleport `{target}`, Bounds `{size [768,412,768]}`.
- labels: `{kind, p, text}` (floating text ~18 studs above the ground).
- lighting: flat keys map 1:1 to Lighting (clockTime, brightness, ambient, outdoorAmbient, colorShiftTop/Bottom,
  envDiffuse/Specular, exposure, shadowSoftness) plus atmosphere / bloom / correction / rays / clouds blocks.
  `sky`, `grade`, `fog`, `celestial`, `key`, `fill` need a custom skybox or post stack; skipped.

## Builder design
- `tools/build_plan.py PLAN.json [--overview-cam]` writes `build_output/builder.server.luau` and
  `default.project.json`. The plan data is packed (prefab list + compact instance tuples
  `[prefabIndex, g, x, y, z, r, s]`) and embedded as one JSON long-string, decoded at runtime with
  `HttpService:JSONDecode` (no HttpEnabled needed). ~620 KB script for 9590 parts.
- Prefabs are built once into template Models (ServerStorage) and cloned + `PivotTo` per instance
  instead of emitting one baked part list per instance: same output, ~5x smaller script, and cloning
  is faster than 9.6k Instance.new + property sets.
- Terrain: chunked (32x32 columns) `WriteVoxelChannels` (ground + water share voxels), with a
  `WriteVoxels` fallback. 4-stud voxels, bilinear heights at column centres, fractional occupancy at the
  surface, surface material in the top 8 studs and rock below (cliffs show rock).
- Skipped vs the plugin: island sea apron / open ocean (not used by layered/ceiling maps), tunnel carving
  (no tunnel data in this plan), `bottoms` (floating islands; not in this plan).
- `--overview-cam` adds a QA LocalScript that holds an orbit camera on `plan.camera.focus`; press V to
  return to the player camera. Leave it off for shipped places.

<!-- SKYRALLY PATCH: private workstation instructions omitted from public notes. -->
