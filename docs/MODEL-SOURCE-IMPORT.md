# Source models and import/remap guide

The repository contains actual editable geometry, skin rigs, materials and embedded textures, not just hosted mesh IDs. No Creator Store listing is required to share or inspect these source files. Import into Roblox for a new experience is a separate operation that normally creates online assets under your own creator and permissions. Nothing here automatically uploads or grants access.

## Five-boss roster

| Boss | Folder below `assets/models/bosses/` | Zone | Shipped animation |
|---|---|---|---|
| Cinderwing | `dino_boss/anim/out/` | DINO-4 | `src/shared/bossclips/Cinderwing.luau` |
| Frosthorn | `snow_boss/anim/out/` | SNOW-1 | `src/shared/bossclips/Frosthorn.luau` |
| Clattershell | `island_boss/anim/out/` | ISLAND-2 | `src/shared/bossclips/Clattershell.luau` |
| Emberbeetle | `forest_boss/anim/out/` | FOREST-1 | `src/shared/bossclips/Emberbeetle.luau` |
| Thunderwright | `hub_boss/anim/out/` | HUB-0 | `src/shared/bossclips/Thunderwright.luau` |

Each folder contains `rigged.glb` with geometry, joints/skin and embedded images. Four also contain `anim.glb` whose recovered animation rebakes matched the shipped frame tables. Frosthorn instead includes explicitly named `historical-anim.glb`: its six attack wing channels differ, and it MUST NOT replace the shipped animation. See `FROSTHORN-ANIMATION.md`. `models/BOSS-SOURCES.json` is the exact named roster. Other owned editable models remain under `assets/models/`; `models/LOCAL-MODEL-SOURCES.json` inventories them and their image dependencies.

## Inspect/edit locally

1. Clone this repository. These GLBs are ordinary tracked files, not LFS pointers. The model and rights inventories record the supplied sources.
2. In Blender use File > Import > glTF 2.0 and select the desired `rigged.glb`. Preserve node/bone names, parent hierarchy, bind/rest transforms, skin weights and material images. The GLBs embed their images; they do not require a private workstation texture directory.
3. For four bosses, the matching `anim.glb` is an animation reference. For Frosthorn, edit the Luau tables directly or deliberately author a replacement as your own changed version. Do not rebake the historical GLB over its authoritative source. The protected baker refuses that overwrite.
4. For Roblox, import the rig through Studio's 3D Importer into an isolated, unpublished working place. Use the GLB if supported by your Studio version; otherwise import it in Blender and export an FBX with armature/mesh and embedded or adjacent copied images. Verify exported bone names and rest pose before adopting it. Do not merge bones or bake a different rest pose silently.
5. Review scale/orientation and all PBR channels in the importer. Import only to a creator you control and only when you intend the associated Roblox asset creation. This repository does not perform that action.

## Preview authoritative Luau motion

The game uses the unchanged `src/client/BossAnimator.luau` with `src/shared/bossclips/ClipMath.luau`. The optional pack also contains a smaller standalone `ClipPlayer`, extracted verbatim at `models/boss-pack-source/ClipPlayer.luau`.

For a scratch Studio preview, put sibling ModuleScripts `ClipMath` and `ClipPlayer` inside a folder. Put the boss model beside them, with a child ModuleScript named `BakedClips` containing that boss's authoritative data (`models/boss-pack-source/<Boss>.luau` is the exact pack data). The model must have the same named Bone descendants and bind pose. Set `BossScale` to the conversion factor from the original glTF units to your current model scale if it differs from the default `GetScale()`.

Call `require(folder.ClipPlayer).Apply(model, "idle", elapsedSeconds)` on a local frame loop; use the clip names present in the table for attacks. `Apply` samples a pose only; it does not create a loop, schedule combat or drive the racer. Call `Reset(model)` when ending a preview. In the complete game retain `BossAnimator` instead of installing a competing player.

## Optional Roblox pack

`models/WakuPublicBossPack.rbxm` and `.rbxmx` are optional existing assemblies with online mesh/map/TexturePack dependencies. They are not offline geometry exports. The exact XML contains **seven ModuleScripts**: five `BakedClips`, `ClipMath`, and `ClipPlayer`, with no Script or LocalScript. `models/BOSS-PACK-SCRIPTS.json` records instance paths, Source property type, byte counts and extracted-file hashes. XML Source is stored as `string` here; readers must also support `ProtectedString`. Missing files or missing Source do not prove absence of scripts.

## Integrate your own imported rig into the game

1. Build the repository with Rojo and open the output in an isolated Studio place. Locate `ServerStorage.ModelBakes` and the target boss's `model` value in `src/shared/BossConfig.luau`.
2. Save your verified imported model container as a new `.rbxm` under `build/model_bakes/`. Preserve the exact skin/rest hierarchy, not just bone names. You may retain the existing numeric lookup key locally when replacing its bake, since `ModelBakes.load` first clones that local container; do not represent that key as your new Roblox upload ID.
3. Update the explicit `ServerStorage.ModelBakes` mapping in `default.project.json` to your new bake path. If adopting a new model ID, update the corresponding `BossConfig.model` and the mapped key consistently. Update `build/model_bakes/manifest.json` with the actual new bake hash and its actual dependencies. Do not leave a stale row claiming it verifies your replacement.
4. Make sure imported SurfaceAppearance maps and processed TexturePacks are generated and accessible under your intended creator/experience. A local RBXM does not embed the hosted mesh geometry or bypass asset access rules. Never global-search/replace arbitrary numbers in compressed binary models.
5. Rebuild and run `lune run tools/tests/bossclip_spec.luau` and the model-bake tests. In Studio inspect idle and attack at multiple phases with `BossBuilder`/`BossAnimator`, especially Frosthorn wings. Check `BossScale`, yaw/pitch and bounds. Test with a non-owner account separately.
6. For other game references, consult `assets/DEPENDENCIES.json`, plans, generated builders, shared asset tables and serialized bakes. Recompile changed plans with `tools/map/adapt.py`; preserve pinned compiler provenance. Sound, sky, UI and non-boss models have their own references. A successful source import or Rojo build alone does not make the entire game standalone.

## Payload policy

Model sources are tracked in this repository, including `assets/` and nested `anim/out/`. The root-only `/out/` ignore rule does not hide boss sources. No payload file exceeds GitHub's 100 MiB limit; larger ordinary files can trigger the 50 MiB warning. This update preserves the existing public Git history. Private development history, account logs, personal configuration and credentials are not imported.
