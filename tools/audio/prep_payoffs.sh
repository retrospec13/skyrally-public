#!/usr/bin/env bash
# REMARKABLE Batch 2 items 20, 23, 24, 27, 30: synthesise the payoff cues and make them game-ready. Re-runnable.
#   tools/audio/synth_payoffs.py writes the WAVs (seed 20261019; the source is the originality record);
#   prep_audio.py trims the silence and sets the loudness (each target sits at or under the synth's own peak-normalised
#   level, so the -1 dBFS soft knee never squashes a click); the mix level lives in client/PayoffSound VOLUMES.
# Upload (needs the owner's order under the publish / Open Cloud policy):
#   python3 tools/vfx/upload_set.py assets/audio/payoffs_v1/upload SkyRally_ src/shared/PayoffAudio.luau PayoffAudio audio
set -euo pipefail
cd "$(dirname "$0")/../.."
RAW=assets/audio/payoffs_v1/raw
UP=assets/audio/payoffs_v1/upload
mkdir -p "$UP"
python3 tools/audio/synth_payoffs.py "$RAW"
P="python3 tools/audio/prep_audio.py"
prep() { $P "$RAW/$1.wav" "$UP/$1.ogg" --trim-silence --rms "$2"; }
prep portal_suck -22
prep portal_plunge -15
prep portal_spit -18
prep portal_cancel -12
prep iris_open -17
prep portal_wake -19
prep token_whoosh -14
prep token_land -20
prep photo_shutter -30
prep photo_develop -15
prep podium_drop -19
prep confetti_pop -24
prep crate_whistle -12
prep crate_thud -20
prep crate_kazoo -14
prep drumroll -24
prep garage_rev -15
prep garage_redline -16
prep garage_honk -14
prep garage_paint -17
