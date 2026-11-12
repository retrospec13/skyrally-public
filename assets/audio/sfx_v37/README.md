# SkyRally V2 sound effects

These 19 OGG sound effects were created with ElevenLabs for SkyRally. They are included under CC BY 4.0, credited **Waku Worldwide**, with the project owner's approval. You can edit and reuse the licensed copies. Retain attribution and identify changes. Other excluded recordings and Roblox library sounds are not covered by this grant.

`SOURCES.json` maps each cue to its local file, SHA-256, duration and original Roblox ID. `uploaded.json` preserves the original ID/hash receipt. No access to the original Roblox uploads is promised.

## Files

- `bomb_fuse.ogg`
- `burnt_sputter.ogg`
- `count_beep.ogg`
- `gift_pop.ogg`
- `go_beep.ogg`
- `golden_loop.ogg`
- `gp_fanfare.ogg`
- `ice_crack.ogg`
- `missile_whoosh.ogg`
- `orbit_hum.ogg`
- `placement_slam.ogg`
- `pos_gain.ogg`
- `pos_loss.ogg`
- `rocket_loop.ogg`
- `rs_burst.ogg`
- `rs_charge.ogg`
- `tally_tick.ogg`
- `trophy_sting.ogg`
- `ui_big_confirm.ogg`

## Upload and remap

1. Import the OGG files with Roblox Studio's Asset Manager under your own account or group.
2. Check moderation and grant your experience the access it needs.
3. Replace the matching values in `src/shared/SfxV37Assets.luau` with your new `rbxassetid://` IDs. Keep the cue keys unchanged.
4. Rebuild or sync the project with Rojo. Editing loose source files does not change a previously built place.
5. Test the sounds in your own experience, including from an account without uploader privileges.

The source-to-cue names match the filenames. Existing call sites in `src/client/` select the cue. `src/client/Sfx37.luau` provides playback and follows the EFFECTS volume setting.

## Playback contract

- `Sfx37.play(name, volume?, pitch?)` plays a local 2D one-shot.
- `Sfx37.at(name, position, volume?, pitch?)` plays a positional one-shot with automatic cleanup.
- `Sfx37.loopOn(name, parent, volume, maxSeconds, range?)` creates an explicitly looped positional Sound. It fades out after `maxSeconds`; at most six loops are active. The caller can stop it earlier with `Sfx37.fadeStop(sound, seconds?)`.
- A cue without an ID is silent. `play` and `at` return false; `loopOn` returns nil.
- A filename containing `loop` does not make a Sound loop by itself. The call site selects the playback mode.

Example from a sibling client ModuleScript, after importing and remapping:

```luau
local Sfx37 = require(script.Parent:WaitForChild("Sfx37"))
Sfx37.play("count_beep", 0.6, 1)
```

Suggested credit: "SkyRally sound effects by Waku Worldwide, CC BY 4.0. Changes: [describe changes]."
