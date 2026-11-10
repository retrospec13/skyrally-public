# SkyRally by Waku Worldwide

A Roblox racing-game source release candidate with editable owned models, including all five bosses. Local preparation only; public publication awaits owner approval.

Start with [model source/import instructions](docs/MODEL-SOURCE-IMPORT.md) and the exact [boss roster](models/BOSS-SOURCES.json). Actual GLB geometry, rigs and embedded textures are included locally. Creator Store listings are not needed to share these sources. The optional RBXM/RBXMX and complete game still reference online Roblox assets; a Rojo build is not standalone gameplay acceptance.

## Explore

- `src/`: client/server game code and shared rules.
- `map/`: editable source plans. `docs/CONTENT.md` and `docs/guides/` explain the content.
- `build/`: generated maps, TrackData and model/terrain bakes.
- `assets/`: retained owned models, textures and VFX; audio catalogs/tooling and notices remain, but the raw recordings listed in `EXCLUDED_FILES.json` are omitted. `assets/DEPENDENCIES.json` inventories existing ID candidates; `assets/RIGHTS-INVENTORY.json` lists owned visual files under the approved art grant.
- `tools/map/` and `tools/map30/`: map authoring, validation and compiler, with provenance in `tools/map30/SOURCE.txt`.
- `tools/tests/`: offline Luau/Python tests. Optional Studio bridge helpers have no personal targets and are disabled until explicitly configured.

## Configure locally

Default production administrator: **disabled**. Default commerce: **disabled**. No credentials are included.

Copy `config.example.json` to an untracked local file, edit it, then run:

```sh
python3 tools/configure_release.py config.local.json
```

This command validates the configuration and writes the actual `AdminConfig.luau` and `MonetizationConfig.luau` modules packaged by Rojo. It is not a documentation-only template. To restore safe defaults, run it against `config.example.json`.

- `adminUserId`: zero disables production admin; a positive integer selects exactly one administrator. The Studio-only override still requires Studio and an explicit QA attribute; live clients cannot enable it.
- `commerceEnabled`: false hides the Garage and refuses new Robux prompts. True enables configured economy behavior. Products still need a match in your universe; pass IDs are configured separately in `src/shared/StorePassIds.luau`.
- `launchHide`: true hides non-launch products/features. Do not disable it unintentionally.
- `receiptRecoveryEnabled`: explicit opt-in for legacy developer-product/pass binding while sales are disabled. This binds existing catalog matches server-side without mirroring sale IDs. Existing paid receipts still use the unchanged durable/idempotent receipt path. Before migrating a live universe with outstanding purchases, enable recovery, preserve the catalog, and validate its bindings. Do not deploy the unconfigured template as a live commerce migration.

Configuration is a build-time source change. Keep real identifiers/configuration private as appropriate, and restore defaults before redistributing a reusable template. It never uploads, grants, creates products or publishes a place.

## Local validation

Install Python with pytest, pytest-subtests, NumPy and Pillow, plus Lune and Rojo on PATH:

```sh
python3 -m pytest -q -p no:cacheprovider tools
bash tools/tests/run_lune_tests.sh
rojo build default.project.json -o /path/outside/repository/skyrally.rbxlx
```

Rebuild a map's derived code after changing its plan:

```sh
python3 tools/map/adapt.py map/forest1/plan.json
```

Headless tests and Rojo packaging are not Studio gameplay/permission/visual acceptance. The model-bake decoder and checks use `SurfaceAppearance.TexturePackContent.Uri` for current Lune reflection; all 12 serialized model bakes pass. Owner-session instance loads succeed. The earlier direct mesh-URI probe requested texture representations and returned `AssetDelivery403IncorrectAssetType`; it was not a valid public-permission verdict. Roblox documents that `PreloadAsync` does not support SurfaceAppearance or MaterialVariant texture-pack preloading. Check actual rendered materials and non-owner reuse separately.

Recovered boss animation sources for Cinderwing, Clattershell, Emberbeetle and Thunderwright match the shipped clip modules. **Frosthorn's shipped Luau clip module is the authoritative editable source**; its functional animation data is preserved. The recovered animation GLB differs on six attack wing channels and is not represented as a matching export. A historical Blender/GLB round-trip is not required for Luau editing or runtime playback. See `docs/FROSTHORN-ANIMATION.md` for editing and validation, and `assets/RECOVERED-BOSS-SOURCES.json` for source status.

## Models and licensing

Owned project code is MIT. Owned art/models are CC BY 4.0, credited **Waku Worldwide**. Read `LICENSING.md` for exact scope, attribution and named third-party exclusions. Existing font, compiler and SoundFont notices remain separate. A model being present here or available from Roblox does not establish standalone redistribution rights.

GLBs remain in their existing folders to preserve references and avoid duplicating the asset tree. They are ordinary tracked binary files, not LFS pointers. No individual payload file exceeds GitHub's 100 MiB limit. Use the hydrated source ZIP for a large download, or the future approved history-free repository. The exact external manifest is the explicit staging allowlist; nested boss `anim/out/` sources are not ignored. See `docs/MODEL-SOURCE-IMPORT.md` for import, preview and remapping instructions.

Public Waku Worldwide association and existing asset identity are intentional. IDs are retained as online dependency references; recipients may import local sources under their own creator and remap across plans, generated builders, serialized bakes, materials, animation, UI, sky and audio. No uploads, permission grants or publication were performed. Runtime permissions must be checked in a separate Studio experience and from an account without the original uploader's privileges.
