# Frosthorn editable animation source

`src/shared/bossclips/Frosthorn.luau` is the authoritative editable animation source for this release. It contains the complete shipped frame data, not an asset ID or an opaque compiled animation. `BossAnimator` samples it with `bossclips/ClipMath.luau` and applies the resulting transforms to the baked Frosthorn rig.

## Export mismatch, not a missing runtime animation

The historical module header recorded animation GLB SHA1 prefix `95189f72abd3`. That exact historical export has not been recovered. A later recovered animation GLB has SHA1 `12050daca90c4954696de71f5240909e31acb237` and differs on the six attack wing channels (`WingL1` through `WingL3`, `WingR1` through `WingR3`). It is included only as `assets/models/bosses/snow_boss/anim/out/historical-anim.glb`, not as a matching source export. The neighboring `rigged.glb` supplies the recovered geometry, skin and textures. Do not substitute it or claim it reproduces the shipped attack.

The release preserves every shipped clip value, bone name, frame count and timing. Only the source-policy comment changed. The historical GLB is not required to play or edit these Luau clips. A round-trippable Blender project or matching animation GLB is not promised.

## Edit and validate

- Edit the existing Luau data module directly. Preserve its bone ordering, which matches the baked rig.
- `fps` is samples per second. `channels[i]` belongs to `bones[i]`.
- `q` stores flat unit-quaternion rows `(x, y, z, w)` in bone-local rest-relative space. One row means constant; otherwise supply one row per frame. Keep adjacent quaternions in the same hemisphere.
- Optional `t` stores flat translation rows `(x, y, z)` in glTF units. `BossAnimator` multiplies these by `BossScale`; omitted translation is zero.
- Loop clips wrap; a one-shot lasts `(frames - 1) / fps` and holds the last pose. Preserve masks and speed references when present.
- Run `lune run tools/tests/bossclip_spec.luau`, then test the baked Frosthorn model in Studio with `BossAnimator`. Inspect the wings at several attack phases, not just bone counts.
- The baker refuses to overwrite a module marked `AUTHORITATIVE EDITABLE RELEASE SOURCE`. For a comparison export, use `--out` pointing to a separate scratch file, compare the complete clip body and visually review before adopting it. There is no bypass switch that silently overwrites this source.

This source policy resolves the editable-animation deliverable. It does not establish public access to Roblox mesh/texture IDs or certify standalone game operation. Owned animation/art is covered by the release's approved CC BY 4.0 grant; player/tool code is MIT. See `LICENSING.md` for exclusions.
