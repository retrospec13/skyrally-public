#!/usr/bin/env bash
# REMARKABLE Batch 2, items 12, 26 and 29: turn the generated and synthesised soundscape cues into one upload folder, so
# the id table shared/SoundscapeAudio stays a single generated file. Re-runnable. Upload (needs the owner's order:
# it runs on the PC with the Open Cloud key) with
#   python3 tools/vfx/upload_set.py assets/audio/soundscape_v1/upload SkyRally_ src/shared/SoundscapeAudio.luau SoundscapeAudio audio
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=assets/audio/soundscape_v1/raw
UP=assets/audio/soundscape_v1/upload
P="python3 tools/audio/prep_audio.py"
mkdir -p "$UP"
# Item 12: zone ambience beds. Cut any generator fade-out, then a 2 s equal-power loop crossfade (REMARKABLE spec).
# -22 dB RMS: a bed under the music; Soundscape sets the in-game level per zone.
for z in dino snow island forest space hub storm; do
  $P $SRC/amb_$z.mp3 $UP/amb_$z.ogg --cut-fade --loop --xfade 2 --rms -22
done
# Item 26: the Storm Cup theme and the battle themes, prepared like the boss chase themes (cut the fade-out, beat-align
# the seam, loop). The egg take fades to silence at 57.5 s and restarts (two renders stitched): loop the first 57.4 s.
for c in music_stormcup music_battle_survival music_battle_water music_battle_hoard; do
  $P $SRC/$c.m4a $UP/$c.ogg --cut-fade --loop --align --xfade 2.5 --rms -19
done
$P $SRC/music_battle_egg.m4a $UP/music_battle_egg.ogg --end 57.4 --loop --align --xfade 2.5 --rms -19
# Items 26 and 29, synthesised in code: engine voices, wind, fly-by, backfire, clock ticks, the air horn. (Both mirelo
# air horn takes were unusable, raw/sfx_airhorn*.mp3; the synthesised horn is the cue.)
python3 tools/audio/synth_soundscape.py $UP
