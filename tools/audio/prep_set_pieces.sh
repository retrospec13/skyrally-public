#!/usr/bin/env bash
# Prep every Batch 2 set-piece cue (docs/REMARKABLE.md items 13, 21, 22, 25) into assets/audio/set_pieces/upload/*.ogg.
# Raw Higgsfield takes come from tools/audio/gen_set_pieces.py (jobs in assets/audio/set_pieces/jobs.json); synth cues
# from tools/audio/synth_set_pieces.py (cannon_boom is the synth hit with the Higgsfield take layered as its echo).
# Then: python3 tools/vfx/upload_set.py assets/audio/set_pieces/upload SkyRally_ src/shared/SetPiecesAudio.luau SetPiecesAudio audio
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tools/audio/synth_set_pieces.py
R=assets/audio/set_pieces/raw
U=assets/audio/set_pieces/upload
mkdir -p "$U"
P="python3 tools/audio/prep_audio.py"
# synthesised
$P $R/cannon_fuse.wav $U/cannon_fuse.ogg --trim-silence --rms -19
$P $R/cannon_boom_mix.wav $U/cannon_boom.ogg --trim-silence --rms -14 --tail 0.4
$P $R/slide_whistle.wav $U/slide_whistle.ogg --rms -19
$P $R/dizzy_tweets.wav $U/dizzy_tweets.ogg --rms -21
$P $R/retire_poof.wav $U/retire_poof.ogg --trim-silence --rms -18
$P $R/monorail_win.wav $U/monorail_win.ogg --trim-silence --rms -17
# Higgsfield mirelo_text_to_audio takes
$P $R/gull_squawk.mp3 $U/gull_squawk.ogg --trim-rel 40 --rms -16 --tail 0.2
$P $R/splash_pluck.mp3 $U/splash_pluck.ogg --trim-rel 40 --rms -16 --tail 0.3
$P $R/duck_squeak.mp3 $U/duck_squeak.ogg --trim-rel 30 --rms -16 --tail 0.1
$P $R/golden_quack.mp3 $U/golden_quack.ogg --trim-rel 30 --rms -15 --tail 0.1
$P $R/boss_tumble.mp3 $U/boss_tumble.ogg --trim-rel 40 --rms -16 --tail 0.3
$P $R/wheels_off.mp3 $U/wheels_off.ogg --trim-rel 40 --rms -16 --tail 0.3
$P $R/ice_freeze.mp3 $U/ice_freeze.ogg --trim-rel 40 --rms -17 --tail 0.3
$P $R/shell_flip.mp3 $U/shell_flip.ogg --trim-rel 40 --rms -16 --tail 0.2
$P $R/monorail_chime.mp3 $U/monorail_chime.ogg --trim-rel 40 --rms -17 --tail 0.4
$P $R/monorail_toot.mp3 $U/monorail_toot.ogg --trim-rel 40 --rms -16 --tail 0.2
ls -la "$U"
