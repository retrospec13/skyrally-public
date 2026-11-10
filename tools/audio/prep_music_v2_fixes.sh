#!/bin/bash
# Prep-only fixes of round 1/2 takes using the critic's loop points (evidence/L24/audio_critic_v2_loops_r1.md): cut the build
# intro so the cue slams in on beat one, loop inside the groove, tame the 2.5-4 kHz fizz. Output: upload/fix_<name>.ogg
cd "$(dirname "$0")/../.."
T=assets/audio/music_v2/takes; U=assets/audio/music_v2/upload
F=$(python3 -c "import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())")
fix() {  # name src start dur eq
  $F -v error -y -i $T/$2.m4a -ss $3 -t $4 -af "$5" $T/fix_$1.wav
  python3 tools/audio/prep_audio.py $T/fix_$1.wav $U/fix_$1.ogg --loop --align --xfade 1.0 --rms -19
}
EQ="equalizer=f=3200:width_type=o:width=2:g=-2.5,highpass=f=40"
fix boss_snow_t2 music_boss_snow_r1_t2 11.1 44.7 "$EQ"
fix boss_island_t3 music_boss_island_r1_t3 11.2 40.9 "$EQ"
fix boss_hub_t2 music_boss_hub_r1_t2 21.3 25.5 "$EQ"
fix stormcup_t3 music_stormcup_r1_t3 13 41 "$EQ"
fix forest_r2t1 music_forest_r2_t1 1 42 "$EQ"
# Second pass, loop points from the round 2 critic notes (audio_critic_v2_loops_r23.md)
fix boss_hub_r2t2 music_boss_hub_r2_t2 11.0 19.2 "$EQ"
fix stormcup_r2t1 music_stormcup_r2_t1 3.5 35.3 "$EQ"
