#!/bin/bash
# Prep v2 loop takes: generated m4a -> looped, loudness-matched ogg in assets/audio/music_v2/upload/ (same flags as v1 themes).
# Usage: prep_music_v2_loops.sh  (preps every loop take of every round)
cd "$(dirname "$0")/../.."
T=assets/audio/music_v2/takes; U=assets/audio/music_v2/upload
for f in $T/music_{stormcup,boss_snow,boss_island,boss_hub,forest}_r[123]_t*.m4a; do
  b=$(basename $f .m4a)
  python3 tools/audio/prep_audio.py $f $U/$b.ogg --cut-fade --loop --align --xfade 2.0 --rms -19
done
# Prep-only fixes of the v1 takes (critic L24 notes): island loop 6.5-66.5 s (drops the vocal shout, the drag and the outro);
# 2.5 dB dip at 3 kHz for the brass and accordion fizz.
F=$(python3 -c "import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())")
$F -v error -y -i assets/audio/music_v1/music_island.m4a -ss 6.5 -t 60 -af "equalizer=f=3000:width_type=o:width=2:g=-2.5" $T/fix_island_A.wav
python3 tools/audio/prep_audio.py $T/fix_island_A.wav $U/fix_island_A.ogg --loop --align --xfade 1.5 --rms -19
# The same loop without the EQ dip (the critic scored the un-EQ'd cut 7 hook / 8 fit, the EQ'd one 6 / 6: judge noise or a real loss)
$F -v error -y -i assets/audio/music_v1/music_island.m4a -ss 6.5 -t 60 $T/fix_island_noeq.wav
python3 tools/audio/prep_audio.py $T/fix_island_noeq.wav $U/fix_island_noeq.ogg --loop --align --xfade 1.5 --rms -19
# Forest prep fix chosen as final: v1 take cut at 77 s (drops the meandering ending), looped with a 1.5 s crossfade.
$F -v error -y -i assets/audio/music_v1/music_forest.m4a -t 77 $T/fix_forest_B.wav
python3 tools/audio/prep_audio.py $T/fix_forest_B.wav $U/fix_forest_B.ogg --loop --align --xfade 1.5 --rms -19
