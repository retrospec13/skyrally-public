#!/usr/bin/env bash
# REMARKABLE Batch 2 items 14, 18 and 19: synthesise the item feedback cues and make them game-ready in one place.
# Re-runnable. Upload (needs the owner's per-task order under the publish / Open Cloud policy) with
#   python3 tools/vfx/upload_set.py assets/audio/items_v1/upload SkyRally_ src/shared/ItemAudio.luau ItemAudio audio
# which regenerates src/shared/ItemAudio.luau; until then client/ItemJuice runs silent (the BONK falls back to the
# old crash thud).
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$(mktemp -d) # the WAVs are intermediates (the synth script is the source record)
trap 'rm -rf "$SRC"' EXIT
UP=assets/audio/items_v1/upload
mkdir -p "$UP"
python3 tools/audio/synth_items.py "$SRC"
P="python3 tools/audio/prep_audio.py"
for c in item_beep item_bonk item_dizzy item_gotcha item_revenge item_flyby taunt_pop; do
  $P "$SRC/$c.wav" "$UP/$c.ogg" --trim-silence --rms -16
done
ls -l "$UP"
