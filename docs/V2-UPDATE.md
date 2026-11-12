# V2 source update

V2 updates the existing source kit. It does not replace the earlier Git history or turn this kit into a ready-to-play standalone game.

## Included changes

- Grand Prix server rules, client screens, class trophies and saved best scores.
- Course selection, a new shared UI skin, menu motion, vehicle previews, Garage and Settings changes.
- Pause menu, lap splits, next-unlock bar and longer podium scenes.
- Race-start effects, slipstream feedback and revised handling and bot pacing.
- Revised item rules and effects, including the horn, ink splat, item steal, coin pouch and charged boost. The level-three trap uses a TNT crate.
- Map-ready countdown checks, course arrows, missile fixes and route and battle-reach changes in FOREST-1, ISLAND-2, SNOW-1 and SPACE-4.
- Time-trial ghost source. Its visible operation is not certified by this update.
- New regression tests and the UI frame generator in `tools/ui/`.

## New visual sources

The update includes 57 icon images, six course images, four source sheets and 19 frame images. Slice settings and public ID/hash maps are included. `assets/V2-ASSETS.json` lists these files. The existing model sources, rigs, animation tables and trailer remain in place. No new 3D model family is needed for this update.

Provider job metadata was removed from the four source sheets. Their decoded pixels are unchanged. Existing third-party font notices remain intact.

## Included ElevenLabs sound effects

The 19 ElevenLabs-created source sound effects are included under CC BY 4.0, credited Waku Worldwide, with the project owner's approval. Their source files, hashes, runtime ID mapping and upload/playback instructions are in [the sound-effects folder](../assets/audio/sfx_v37/README.md). Other historical recording exclusions remain unchanged. Hosted sound IDs do not grant access to the original Roblox uploads; upload your own copies and replace the IDs before using the kit in your experience.

## Public defaults

Production admin and new payments remain disabled. Local setup still uses `config.example.json` and `tools/configure_release.py`. Existing receipt recovery stays opt-in. The update does not restore creator-specific admin IDs, machine paths, SSH targets, account logs, generation jobs or rejected assets.

The optional review helper reads `OPENROUTER_API_KEY` from the environment only. It does not read an agent credential file. Windows capture helpers remain optional. They require your own local configuration and do not form a complete Studio deployment system.

## Validation scope

Use the full Python suite, Lune suite and Rojo build commands in the main README. Compile the changed plans with `tools/map/adapt.py` after editing them. Headless tests do not establish phone layout quality, joined-client behavior, gamepad support or non-owner Roblox asset access.

The development lane reported Studio checks for its original build. Those reports do not certify a recipient's remapped copy. This update makes no new phone or public-client acceptance claim.

## Open gameplay review findings

- The Grand Prix rules have tests, but the Grand Prix server service lacks direct integration tests. Its race-end logic still considers all human records. A player who joins mid-cup may affect the cup owner's DNF timer. This is a source-level concern, not a reproduced Studio fault.
- Time-trial ghost recording has no sample or duration cap. A long unfinished trial can keep adding frames in client memory.
- Grand Prix selection does not check the optional per-group mode, although the server refuses cups in that mode. Per-group mode is off by default.

These findings are retained for follow-up. The public import does not change the development lane's game rules to conceal them.
