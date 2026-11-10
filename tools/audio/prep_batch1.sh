#!/usr/bin/env bash
# REMARKABLE Batch 1, items 1, 2, 3 and 9: turn the generated and synthesised cues into the upload folder (one place, so
# the id table shared/AudioAssets stays a single generated file). Re-runnable; upload with
#   python3 tools/vfx/upload_set.py assets/audio/music_v1/upload SkyRally_ src/shared/AudioAssets.luau AudioAssets audio
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=assets/audio/music_v1
UP=$SRC/upload
P="python3 tools/audio/prep_audio.py"
# Boss chase themes: cut the generator's fade-out (and ISLAND's ending tag at 84 s), beat-align the seam, loop.
for z in dino snow forest hub; do
  $P $SRC/music_boss_$z.m4a $UP/music_boss_$z.ogg --cut-fade --loop --align --xfade 2.5 --rms -19
done
$P $SRC/music_boss_island.m4a $UP/music_boss_island.ogg --end 84.0 --loop --align --xfade 2.5 --rms -19
# The shared fallback "music_boss" is not a second upload of the same file: MusicRules.bossThemeCandidates falls back to
# music_boss_dino by name.
# Roars: drop the quiet lead-in so the hit lands as the music cuts, loud.
# The hit lands within 0.1 s of the start, in sync with the roar clip (BossAnimator ROAR_DELAY); Clattershell keeps its two
# claw clacks before the bellow (a wider lead window).
for b in cinderwing frosthorn emberbeetle thunderwright; do
  $P $SRC/roar_$b.mp3 $UP/roar_$b.ogg --lead-rel 12 --tail 0.4 --rms -14
done
$P $SRC/roar_clattershell.mp3 $UP/roar_clattershell.ogg --lead-rel 22 --tail 0.4 --rms -14
# Finish jingles (rank 2, 3, mid-pack) and the final-lap sting (sonilo fallback take, 2.8 s with a 0.6 s tail).
for j in place2 place3 midpack; do
  $P $SRC/jingle_$j.m4a $UP/jingle_$j.ogg --trim-silence --rms -17
done
$P $SRC/jingle_finallap_sonilo.m4a $UP/jingle_finallap.ogg --trim-rel 40 --max-len 2.8 --fade-out 0.6 --rms -16
# Synthesised in code: the wah-wah last place, the secret chiptune fanfares.
python3 tools/audio/synth_sfx.py last_place $UP/jingle_last.ogg
python3 tools/audio/synth_chip.py secret $UP/chip_secret.ogg
python3 tools/audio/synth_chip.py find $UP/chip_find.ogg
