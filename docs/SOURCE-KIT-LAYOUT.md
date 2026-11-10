# Source-kit layout and download size

This is a source-and-assets kit, not a preconfigured independent game. Follow [model import and remapping](MODEL-SOURCE-IMPORT.md), including serialized bakes and generated code, before testing in your own experience. The optional boss RBXM is a model pack, not a complete place.

## Cleanup boundary

The claimed 680 rejected/raw files was not reproducible from tracked paths. A case-insensitive path search for `reject`, `raw` or `intermediate` found 142 files totaling 238,826,536 bytes. Only the 105 files inside explicitly rejected directories (90,376,523 bytes) were removed. Exact paths and original hashes are in `../EXCLUDED_FILES.json`. No code/config/test consumer of these rejected folders was found; all parsed GLB images/buffers were embedded. Non-rejected editable GLBs remain in every affected asset family. Inventory-only references were removed from the local-model and rights manifests.

Raw inputs outside rejected folders remain: a raw filename does not prove redundancy. Final boss rigs, all authoritative Luau clip tables, Frosthorn's explicitly historical animation source, useful textures, fixtures and tests are retained. No accepted art was regenerated or changed.

## Four large source models retained

| Source | Bytes | Finding |
|---|---:|---|
| `assets/models/hero_car/model_url.glb` | 64,364,580 | Listed editable source; current car code refers to v2/v3 derivatives, not this exact file. |
| `assets/models/hero_hovercraft/model_url.glb` | 64,776,996 | Listed editable source; no direct runtime/tool consumer of this exact path found. |
| `assets/models/hero_plane/model_url.glb` | 65,008,876 | Listed editable source; current plane code refers to v3 parts, not this exact file. |
| `assets/models/stone_sauropod/model_url.glb` | 62,768,044 | Listed editable source; no direct runtime/tool consumer of this exact path found. |

These are not proven active runtime inputs or proven disposable duplicates. Retaining them preserves editable source rather than guessing from age, size or indirect model names. The current checkout is about 1.20 GB; Git history still contains deleted files. This ordinary forward commit neither rewrites history nor reduces prior packed objects. No broken LFS pointers or optional remote asset downloads were substituted.

## Tool locations and compatibility

- Legacy forest/snow builders moved to `tools/legacy-builders/`. They are not Rojo map entrypoints; the optional lane sync list follows their new locations.
- The supplied keyboard pilot moved from `win/key_pilot.js` to `tools/windows/key_pilot.js`. Python launchers, test input, descriptive references and lane sync paths follow the move. It stays disabled by default. No Windows/Studio session was launched for this cleanup.
- `builder_dino4.luau` deliberately remains at the root. It is a real input to the DINO author, extractor, route parity fixtures and compiler check, and its path appears in provenance-bearing plans/extracted data. Moving it would require regenerating map plan hashes and compiled map outputs, beyond presentation cleanup. Rojo uses `build/dino4/builder_module.luau`, not this legacy root script.
- Other `win/` references belong to optional, externally supplied deployment/capture/upload helpers, not tracked files moved here. Their operational protocol was not renamed or claimed to be a shipped end-to-end production workflow.

## Preview gap

No verified plane-boost or boss-fight recording is included in this release copy. The tracked GIFs are VFX asset previews, not gameplay footage. No gameplay GIF was fabricated, substituted or generated for the README.

## Validation compatibility

Rojo 7.7.0 builds this source kit. On the cleanup host, Lune 0.10.5 reports model-bake SurfaceAppearance/TexturePack failures on both the untouched initial release commit and the cleaned tree, with identical failure lines. The cleanup does not repair or regenerate those bakes. This environment is not a new all-green Lune certification; prior release validation used its own tool environment. Run the full suite in your setup and check actual imported materials separately.

The rooftop Git-history test ignores the parentless source-import commit, which adds every file at once. It still checks every subsequent commit touching rooftop geometry for forbidden physics-file changes.
