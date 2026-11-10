#!/usr/bin/env python3
"""Music v3: SEQUENCED music in the late-90s way. Every cue is composed note by note below as plain Python data (tempo,
key, chord progression, melody phrases, bass, drums, countermelody, arrangement) and rendered through a General MIDI
SoundFont (GeneralUser GS v2.0.3, licence and hashes in assets/audio/music_v3/SOUNDFONT.md) with TinySoundFont, then mixed
and mastered in numpy (reverb send, 40 Hz high-pass, gentle bus compression, soft limiter to -1 dBFS, about -16 LUFS) and
cut as a seamless loop. All melodies are original to this file; none quotes or paraphrases an existing tune.

Outputs per cue: <out>/<cue>.ogg (44.1 kHz stereo Vorbis), <out>/<cue>.mid (one loop, GM), <out>/<cue>.json (metrics).
Setup (first run, or --setup): downloads the SoundFont and the TinySoundFont sdist (pinned URLs, sha256-verified, into a
fresh cache folder outside the repo), extracts only tsf.h from the sdist and compiles it with the system C compiler into
libtsf.so (loaded with ctypes; no Python headers needed). Nothing downloaded is executed.

Usage: compose_v3.py [--cache DIR] [--out DIR] [--setup] [--seed N] [cue ...]   (default: all cues)
Needs: numpy, scipy, soundfile (libsndfile with Vorbis), mido, pyloudnorm (optional; RMS fallback), a C compiler."""
import argparse
import ctypes
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "audio" / "music_v3"
SR = 44100

SOUNDFONT = {
    "file": "GeneralUser-GS.sf2",
    "url": "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/684543d5e5efaef08d02be50dcda8d552478fa60/GeneralUser-GS.sf2",
    "sha256": "9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe",
}
TSF_SDIST = {
    "file": "tinysoundfont-0.3.7.tar.gz",
    "url": "https://files.pythonhosted.org/packages/0d/c9/96ef50b61a0c39fb7dbafff61ee759e0eb60e87f98eb04860579672127c8/tinysoundfont-0.3.7.tar.gz",
    "sha256": "13b560f35469303064d7b597c1584ec35f18193fd915c502c29fcba90ac11d31",
    "member": "tinysoundfont-0.3.7/src/_tinysoundfont/tsf/tsf.h",
}

# ----------------------------------------------------------------------------------------------------------------------
# Cues. Notation: melody tokens "<note><octave>:<beats>" (C5:1.5, Bb4:.5, F#5:1/3), "r:<beats>" rest, suffix ">" accent,
# "~" ghost; "|" marks a bar line and is checked. Chords: one or more symbols per bar, split evenly ("Gm7 C7").
# Drum grooves: 16 steps per 4/4 bar, X accent, x normal, o ghost, . rest. Bass degrees: R 5 8 3 b7 -5 (fifth below),
# A (approach to the next chord root by a semitone). Patterns are (beat, what, duration in beats, velocity scale).
# ----------------------------------------------------------------------------------------------------------------------

HUB = {
    "name": "music_hub", "bpm": 116, "swing": 0.22, "swing_unit": 0.25, "transpose": 0,
    "reverb": {"rt60": 1.4, "wet": 0.7},
    "tracks": {
        "lead":  dict(bank=0, prog=114, pan=0.0, lvl=0.0, rev=0.18, gate=0.95, hum=7, jit=0.004, lp=7000,
                     peq=[(3200, -3.0, 1.0)]),   # steel drums
        "mar":   dict(bank=0, prog=12, pan=0.35, lvl=-2.0, rev=0.16, gate=0.9, hum=8, jit=0.005, peq=[(3200, -2.0, 1.0)]),
        "vib":   dict(bank=0, prog=11, pan=-0.40, lvl=-10.0, rev=0.25, gate=0.9, hum=6, jit=0.006),          # harmony
        "uke":   dict(bank=8, prog=24, pan=-0.28, lvl=-6.0, rev=0.12, gate=0.9, hum=8, jit=0.004, hp=150),
        "gtr":   dict(bank=0, prog=24, pan=0.32, lvl=-14.0, rev=0.12, gate=0.9, hum=8, jit=0.004, hp=200),
        "pad":   dict(bank=0, prog=49, pan=0.0, lvl=-17.0, rev=0.35, gate=1.0, hum=0, jit=0.0, hp=200),
        "bass":  dict(bank=0, prog=32, pan=0.0, lvl=-4.0, rev=0.02, gate=0.85, hum=6, jit=0.003),
        "kit":   dict(drums=True, kit=0, pan=0.0, lvl=-5.0, rev=0.08, hum=9, jit=0.002),
        "perc":  dict(drums=True, kit=0, pan=-0.20, lvl=-6.0, rev=0.12, hum=10, jit=0.004),
    },
    "phrases": {
        # hook: repeated-note pickup "C C A" then a pushed long note; the D7 bar bends it with F#; bar 4 holds C high
        "hook":   "C6:.5> C6:.5 A5:.5 C6:1> D6:.5 C6:1 | C6:.5> C6:.5 A5:.5 F#5:1> A5:.5 D6:1 |"
                  " Bb5:.5> Bb5:.5 G5:.5 D5:1> F5:.5 G5:1 | E5:1> G5:.5 C6:2.5>",
        "answer": "C6:.5> C6:.5 A5:.5 C6:1> D6:.5 C6:1 | C6:.5> C6:.5 A5:.5 F#5:1> A5:.5 D6:1 |"
                  " Bb5:.5> A5:.5 G5:.5 D6:1> C6:.5 Bb5:.5 G5:.5 | A5:1.5> F5:.5 r:2",
        # marimba fills in the hook's holes (bar 4 and bar 8)
        "fills":  "r:4 | r:4 | r:4 | r:1.5 G4:.5 A4:.5 Bb4:.5 C5:.5 E5:.5 | r:4 | r:4 | r:4 | r:2 C5:.5 A4:.5 F4:1",
        # C: steel drums and marimba trade the hook's "C C A" cell, then a turnaround walks up into bar 1
        "c_steel": "D6:.5> D6:.5 Bb5:.5 D6:1> F6:.5 D6:1 | r:4 | C6:.5> C6:.5 A5:.5 E6:1> D6:.5 C6:1 | r:4 |"
                   " Bb5:.5> Bb5:.5 G5:.5 D6:1> C6:.5 Bb5:1 | r:4 | A5:.5> C6:.5 F6:1> D6:.5 C6:.5 A5:.5 F#5:.5 |"
                   " G5:.5> Bb5:.5 D6:.5 F6:.5 E6:.5> C6:.5 Bb5:.5 B5:.5",
        "c_mar":   "r:4 | E5:.5> G5:.5 Bb5:.5 C6:1> Bb5:.5 G5:1 | r:4 | A5:.5> F5:.5 D5:.5 F5:1> A5:.5 C6:1 |"
                   " r:4 | G5:.5> E5:.5 C5:.5 E5:1> G5:.5 Bb5:1 | r:4 | r:4",
        # B: long-short sighs over the minor iv, marimba lead; steel drums brings the pickup back to the hook
        "b_mel":  "D6:1.5> C6:.5 Bb5:.5 F5:1.5 | Db6:1.5> C6:.5 Bb5:.5 F5:1.5 | A5:.5> C6:.5 E6:1> D6:.5 C6:.5 A5:1 |"
                  " C6:1.5> A5:.5 F#5:.5 D5:1.5 | D6:1.5> C6:.5 Bb5:.5 G5:1.5 | Bb5:1.5> A5:.5 G5:.5 E5:1.5 |"
                  " A5:1.5> G5:.5 F5:.5 C5:1.5 | r:4",
        "b_pickup": "r:4 | r:4 | r:4 | r:4 | r:4 | r:4 | r:4 | r:2 G5:.5> A5:.5 Bb5:.5 B5:.5",
    },
    "chords": {
        "A":      "F | D7 | Gm7 | C7 | F | D7 | Gm7 C7 | F",
        "B":      "Bb | Bbm6 | Am7 | D7 | Gm7 | C7 | F | C7",
        "C":      "Bb | C7 | Am7 | Dm7 | Gm7 | C7 | F D7 | Gm7 C7",
    },
    "patterns": {
        "calypso": [(0, "R", 1.2, 1.0), (1.5, "5", .45, .75), (2, "8", .9, .85), (3, "5", .45, .7), (3.5, "A", .45, .8)],
        "calypso_half": [(0, "R", 1.4, 1.0), (1.5, "5", .45, .7), (2, "R", 1.4, .85), (3.5, "A", .45, .75)],
        "island":  {"range": (60, 72), "hits": [(0, "D", .85), (1, "D", .7), (1.5, "U", .55), (2.5, "U", .6), (3, "D", .75), (3.5, "U", .55)]},
        "island_half": {"range": (60, 72), "hits": [(0, "D", .8), (1.5, "U", .5), (2, "D", .7), (3.5, "U", .5)]},
        "offbeat": {"range": (55, 67), "hits": [(.5, "D", .7), (1.5, "D", .6), (2.5, "D", .7), (3.5, "D", .6)], "spread": 0.0, "dur": .3},
        "pad":     {"range": (53, 67)},
    },
    "grooves": {
        "island": {"kick": "X.....x.X.....x.", "rim": "....x.......x...", "shaker": "xoXoxoXoxoXoxoXo"},
        "island_b": {"kick": "X.......X.......", "rim": "....x.......x...", "shaker": "xoXoxoXoxoXoxoXo"},
        "congas": {"conga_mute": "..o...o...o...o.", "conga_hi": "x.......x.x.....", "conga_lo": "......X.......X."},
        "congas_b": {"conga_mute": "..o...o...o...o.", "conga_hi": "x..x....x..x....", "conga_lo": "......X.......X.", "bongo_hi": "..x...x...x...x."},
        "fill_kit": {"kick": "X.....x.X.......", "rim": "....x...........", "shaker": "xoXoxoXo........"},
        "fill_perc": {"conga_lo": "......X.........", "timb_hi": "........X..xX.x.", "timb_lo": "..........X..X.X"},
        "fill_perc_big": {"conga_hi": "x.......", "timb_hi": "........XxX.X.x.", "timb_lo": "..........X.XxXX"},
    },
    "form": [
        {"bars": 8, "chords": "A", "parts": {
            "lead": ["hook", "answer"], "mar": ["fills"], "uke": ("strum", "island"), "gtr": ("strum", "offbeat"),
            "bass": ("bass", "calypso"), "kit": ("drums", "island", "fill_kit"), "perc": ("drums", "congas", "fill_perc")}},
        {"bars": 8, "chords": "B", "parts": {
            "mar": ["b_mel"], "vib": ("harm", ["b_mel"]), "lead": ["b_pickup"], "gtr": ("strum", "offbeat"),
            "uke": ("strum", "island_half"), "bass": ("bass", "calypso_half"), "kit": ("drums", "island_b", "fill_kit"),
            "perc": ("drums", "congas_b", "fill_perc")}},
        {"bars": 8, "chords": "A", "parts": {
            "lead": ["hook", "answer"], "vib": ("harm", ["hook", "answer"]), "mar": ["fills"], "uke": ("strum", "island"),
            "gtr": ("strum", "offbeat"), "bass": ("bass", "calypso"), "kit": ("drums", "island", "fill_kit"),
            "perc": ("drums", "congas", "fill_perc")}},
        {"bars": 8, "chords": "C", "parts": {
            "lead": ["c_steel"], "mar": ["c_mar"], "vib": ("harm", ["c_steel"]), "uke": ("strum", "island"),
            "gtr": ("strum", "offbeat"), "bass": ("bass", "calypso"), "kit": ("drums", "island_b", "fill_kit"),
            "perc": ("drums", "congas_b", "fill_perc_big")}},
    ],
}

DINO = {
    "name": "music_dino", "bpm": 145, "swing": 0.0, "swing_unit": 0.25, "transpose": -2,
    "reverb": {"rt60": 1.1, "wet": 0.6},
    "tracks": {
        "tpt":    dict(bank=0, prog=56, pan=0.08, lvl=0.0, rev=0.16, gate=0.85, hum=6, jit=0.003),
        "bone":   dict(bank=0, prog=57, pan=-0.12, lvl=-5.0, rev=0.16, gate=0.85, hum=6, jit=0.003, shift=-12),
        "xylo":   dict(bank=0, prog=13, pan=0.22, lvl=-1.0, rev=0.14, gate=0.9, hum=7, jit=0.003),
        "xylo2":  dict(bank=0, prog=13, pan=-0.30, lvl=-9.0, rev=0.14, gate=0.9, hum=7, jit=0.003),
        "stabs":  dict(bank=0, prog=61, pan=-0.25, lvl=-10.0, rev=0.14, gate=0.6, hum=6, jit=0.003, hp=180),
        "gtr":    dict(bank=0, prog=28, pan=-0.40, lvl=-13.0, rev=0.06, gate=0.6, hum=8, jit=0.003, hp=180),
        "bass":   dict(bank=0, prog=36, pan=0.0, lvl=-4.0, rev=0.02, gate=0.8, hum=7, jit=0.002),
        "kit":    dict(drums=True, kit=16, pan=0.0, lvl=-3.0, rev=0.10, hum=9, jit=0.002),
    },
    "phrases": {
        # hook: leap of a fifth, a cheeky chromatic turn, run back down; three times (C, Bb, F) then a high half cadence
        "hook":   "C5:.5> G5:1> F#5:.25 G5:.25 A5:.5 G5:.5 E5:.5 C5:.5 | D5:.5> F5:1> E5:.25 F5:.25 G5:.5 F5:.5 D5:.5 Bb4:.5 |"
                  " C5:.5> A5:1> G#5:.25 A5:.25 C6:.5 A5:.5 F5:.5 A5:.5 | G5:.5> B5:.5 D6:1> C6:.5 B5:.5 G5:1",
        # xylophone answer: the same turn figure, an octave of sparkle, then a clean cadence
        "answer": "A5:.5> E6:1> D#6:.25 E6:.25 C6:.5 A5:.5 E5:.5 A5:.5 | F5:.5> C6:1> B5:.25 C6:.25 A5:.5 F5:.5 C5:.5 F5:.5 |"
                  " D6:.5> C6:.5 A5:.5 F5:.5 G5:.5> B5:.5 D6:.5 F6:.5 | E6:1> C6:.5 G5:.5 C6:1> r:1",
        "answer_loop": "A5:.5> E6:1> D#6:.25 E6:.25 C6:.5 A5:.5 E5:.5 A5:.5 | F5:.5> C6:1> B5:.25 C6:.25 A5:.5 F5:.5 C5:.5 F5:.5 |"
                       " D6:.5> C6:.5 A5:.5 F5:.5 A5:.5 C6:.5 D6:.5 F6:.5 | G6:1> F6:.5 D6:.5 B5:1 r:1",
        # brass answer when the xylophone has the hook (role swap in the third A)
        "answer_brass": "A4:.5> E5:1> D#5:.25 E5:.25 C5:.5 A4:.5 E4:.5 A4:.5 | F4:.5> C5:1> B4:.25 C5:.25 A4:.5 F4:.5 C4:.5 F4:.5 |"
                        " D5:.5> C5:.5 A4:.5 F4:.5 G4:.5> B4:.5 D5:.5 F5:.5 | E5:1> C5:.5 G4:.5 C5:1> r:1",
        # B: brass riff in A minor with a Lydian B over F, xylophone runs answer in the second half of each bar
        "b_brass": "E5:.5> A5:.5 r:.5 A5:.5 C6:.5> B5:.5 A5:1 | E5:.5> A5:.5 r:.5 A5:.5 E6:1> D6:.5 C6:.5 |"
                   " F5:.5> A5:.5 r:.5 A5:.5 C6:.5> B5:.5 A5:1 | B5:1.5> A5:.5 G5:1 D5:1 |"
                   " E5:.5> A5:.5 r:.5 A5:.5 C6:.5> B5:.5 A5:1 | E5:.5> A5:.5 r:.5 A5:.5 E6:1> D6:.5 C6:.5 |"
                   " C6:.5> A5:.5 F5:.5 A5:.5 C6:.5> D6:.5 C6:.5 A5:.5 | G#5:1> B5:1 D6:1 E6:1>",
        "b_xylo":  "r:2 E6:.25 C6:.25 A5:.25 C6:.25 E6:.5 r:.5 | r:2 A6:.25 E6:.25 C6:.25 E6:.25 A6:.5 r:.5 |"
                   " r:2 F6:.25 C6:.25 A5:.25 C6:.25 F6:.5 r:.5 | r:2 G6:.25 D6:.25 B5:.25 D6:.25 G6:.5 r:.5 |"
                   " r:2 E6:.25 C6:.25 A5:.25 C6:.25 E6:.5 r:.5 | r:2 A6:.25 E6:.25 C6:.25 E6:.25 A6:.5 r:.5 |"
                   " r:2 F6:.25 C6:.25 A5:.25 C6:.25 F6:.5 r:.5 | r:4",
    },
    "chords": {
        "A":      "C | Bb | F | G | Am | F | Dm7 G | C",
        "A_loop": "C | Bb | F | G | Am | F | Dm7 | G7",
        "B":      "Am | Am | F | G | Am | Am | F | E7",
    },
    "patterns": {
        "slap":   [(0, "R", .45, 1.0), (.5, "8", .25, .75), (1, "R", .45, .85), (1.5, "8", .25, .75),
                   (2, "R", .45, .95), (2.5, "8", .25, .75), (3, "5", .45, .85), (3.5, "A", .3, .85)],
        "slap_b": [(0, "R", .45, 1.0), (.75, "R", .25, .7), (1.5, "8", .45, .85), (2, "R", .25, .8),
                   (2.5, "b7", .25, .75), (3, "5", .45, .85), (3.5, "8", .3, .8)],
        "stab":   {"range": (60, 72), "hits": [(1.5, "D", .9, .35), (3, "D", .8, .5)], "spread": 0.0},
        "chug":   {"range": (48, 60), "power": True, "hits": [(i * .5, "D", .75 if i % 2 else .9, .3) for i in range(8)], "spread": .004},
    },
    "grooves": {
        "rock":    {"kick": "X.....x.X.x.....", "snare": "....X.......X..o", "hat": "X.x.X.x.X.x.X.x."},
        "rock_b":  {"kick": "X..x..x...x..x..", "snare": "....X.......X...", "hat": "x.x.x.x.x.x.x.x.", "tom_lo": "..............x."},
        "toms":    {"kick": "X...X...X...X...", "snare": "....X.......X...", "tom_lo": "..x...x...x...x.", "ride": "x.x.x.x.x.x.x.x."},
        "fill":    {"kick": "X.....x.X.......", "snare": "....X...xxXx....", "hat": "X.x.X.x.........", "tom_hi": "............Xx..", "tom_lo": "..............XX"},
        "fill_big": {"kick": "X.....x.X.......", "snare": "....X...XxXx....", "tom_hi": "............Xx..", "tom_mid": "..............X.", "tom_lo": "...............X"},
    },
    "form": [
        {"bars": 8, "chords": "A", "parts": {
            "tpt": ["hook", "rest4"], "bone": ["hook", "rest4"], "xylo": ["rest4", "answer"], "stabs": ("strum", "stab", {"bars": "5-8"}),
            "gtr": ("strum", "chug"), "bass": ("bass", "slap"), "kit": ("drums", "rock", "fill", {"crash": True})}},
        {"bars": 8, "chords": "A", "parts": {
            "tpt": ["hook", "answer"], "bone": ["hook", "answer"], "xylo": ["hook", "answer"], "xylo2": ("harm", ["hook", "answer"]),
            "gtr": ("strum", "chug"), "bass": ("bass", "slap"), "kit": ("drums", "rock", "fill_big", {"crash": True})}},
        {"bars": 8, "chords": "B", "parts": {
            "tpt": ["b_brass"], "bone": ["b_brass"], "xylo": ["b_xylo"], "gtr": ("strum", "chug"), "bass": ("bass", "slap_b"),
            "kit": ("drums", "rock_b", "fill", {"crash": True})}},
        {"bars": 8, "chords": "A", "parts": {
            "xylo": ["hook", "rest4"], "xylo2": ("harm", ["hook"]), "tpt": ["rest4", "answer_brass"], "bone": ["rest4", "answer_brass"],
            "stabs": ("strum", "stab", {"bars": "1-4"}), "bass": ("bass", "slap"), "kit": ("drums", "toms", "fill_big", {"crash": True})}},
        {"bars": 8, "chords": "A_loop", "parts": {
            "tpt": ["hook", "rest4"], "bone": ["hook", "rest4"], "xylo": ["rest4", "answer_loop"], "stabs": ("strum", "stab", {"bars": "5-8"}),
            "gtr": ("strum", "chug"), "bass": ("bass", "slap"), "kit": ("drums", "rock", "fill_big", {"crash": True})}},
    ],
}

SNOW = {
    "name": "music_snow", "bpm": 145, "swing": 0.0, "swing_unit": 0.25, "transpose": 0,
    "reverb": {"rt60": 1.5, "wet": 0.7},
    "tracks": {
        "synth":  dict(bank=0, prog=80, pan=-0.05, lvl=0.0, rev=0.18, gate=0.85, hum=5, jit=0.003, peq=[(3500, -3.0, 1.0)]),
        "glock":  dict(bank=0, prog=9, pan=0.15, lvl=-3.0, rev=0.22, gate=0.9, hum=6, jit=0.003, peq=[(4000, -2.0, 1.0)]),
        "celesta": dict(bank=0, prog=8, pan=0.35, lvl=-7.0, rev=0.22, gate=0.9, hum=6, jit=0.004),
        "pizz":   dict(bank=0, prog=45, pan=-0.35, lvl=-7.0, rev=0.18, gate=0.6, hum=8, jit=0.004, hp=150),
        "pad":    dict(bank=0, prog=94, pan=0.0, lvl=-18.0, rev=0.30, gate=1.0, hum=0, jit=0.0, hp=250),
        "bass":   dict(bank=0, prog=38, pan=0.0, lvl=-5.0, rev=0.02, gate=0.7, hum=6, jit=0.002),
        "kit":    dict(drums=True, kit=0, pan=0.0, lvl=-1.0, rev=0.08, hum=9, jit=0.002),
        "bells":  dict(drums=True, kit=0, pan=0.30, lvl=-9.0, rev=0.12, hum=12, jit=0.004),
    },
    "phrases": {
        # D Mixolydian rock. Hook cell: third, root, fifth below, root, then a pushed fourth that leans back to the
        # third (3 1 5 1 4-3-2); the same cell on C with its own fourth (F), then the leap to G6 and an open half cadence
        "hook":   "F#6:.5> D6:.5 A5:.5 D6:.5 G6:1> F#6:.5 E6:.5 | E6:.5> C6:.5 G5:.5 C6:.5 F6:1> E6:.5 D6:.5 |"
                  " B5:.5> D6:.5 G6:1> F#6:.5 E6:.5 D6:.5 B5:.5 | C#6:.5> D6:.5 E6:1> r:.5 A5:.5 C#6:.5 E6:.5",
        "answer": "F#6:.5> D6:.5 A5:.5 D6:.5 G6:1> F#6:.5 E6:.5 | E6:.5> C6:.5 G5:.5 C6:.5 F6:1> E6:.5 D6:.5 |"
                  " B5:.5> D6:.5 G6:.5 F#6:.5 E6:.5> C#6:.5 A5:.5 C#6:.5 | D6:1.5> A5:.5 D6:1> r:1",
        "b_mel":  "G5:.5> B5:.5 D6:.5 B5:.5 E6:1> D6:1 | A5:.5> C#6:.5 E6:.5 C#6:.5 F#6:1> E6:1 |"
                  " F#6:.5> E6:.5 C#6:.5 A5:.5 C#6:1> A5:1 | B5:.5> C#6:.5 D6:.5 F#6:.5 E6:1> D6:1 |"
                  " G5:.5> B5:.5 D6:.5 B5:.5 E6:1> D6:1 | A5:.5> C#6:.5 E6:.5 C#6:.5 F#6:1> E6:1 |"
                  " F6:1> D6:.5 Bb5:.5 D6:1> F6:1 | G6:1> E6:.5 C6:.5 E6:1> G6:1",
        # C: a soaring bridge in long notes, then the turnaround (A7) walks up into the hook
        "c_mel":  "B5:1> E6:1 G6:2> | E6:1.5> C#6:.5 A5:2 | A5:1> D6:1 F#6:2> | F#6:1.5> E6:.5 D6:2 |"
                  " B5:1> D6:1 G6:2> | A6:1.5> G6:.5 E6:2 | F6:1> D6:1 G6:1> E6:1 | C#6:1> E6:.5 G6:.5 r:.5 A5:.5 C#6:.5 E6:.5",
    },
    "chords": {
        "A":      "D | C | G | A | D | C | G A | D",
        "B":      "G | A | F#m | Bm | G | A | Bb | C",
        "C":      "Em7 | A | D | Bm | G | A | Bb C | A7",
    },
    "patterns": {
        "drive":  [(0, "R", .4, 1.0), (.5, "R", .35, .7), (1, "8", .4, .85), (1.5, "R", .35, .7),
                   (2, "R", .4, .95), (2.5, "R", .35, .7), (3, "5", .4, .85), (3.5, "A", .35, .8)],
        "pizz":   {"range": (57, 69), "hits": [(i * .5, "D", (.9, .6, .75, .6, .85, .6, .75, .6)[i], .25) for i in range(8)], "spread": 0.0},
        "pad":    {"range": (57, 71)},
    },
    "grooves": {
        "drive":  {"kick": "X.....x.X.x.....", "snare": "....X.......X...", "clap": "....x.......x...", "hat": "x.x.X.x.x.x.X.x."},
        "drive_b": {"kick": "X.....x...x.....", "snare": "....X.......X..o", "clap": "....x.......x...", "ride": "x.x.x.x.x.x.x.x."},
        "four":   {"kick": "X...X...X...X...", "snare": "....X.......X...", "clap": "....x.......x...", "ohat": "..x...x...x...x."},
        "bells":  {"jingle": "o.x.o.x.o.x.o.x."},
        "fill":   {"kick": "X.....x.X.......", "snare": "....X...xxXx....", "hat": "x.x.X.x.........", "tom_hi": "............Xx..", "tom_lo": "..............XX"},
        "fill_big": {"kick": "X.....x.X.......", "snare": "....X...XxXx....", "tom_hi": "............Xx..", "tom_mid": "..............X.", "tom_lo": "...............X"},
        "bells_fill": {"jingle": "o.x.o.x.o.x....."},
    },
    "form": [
        {"bars": 8, "chords": "A", "parts": {
            "synth": ["hook", "answer"], "glock": ["hook", "answer"], "pizz": ("strum", "pizz"), "pad": ("pad", "pad"),
            "bass": ("bass", "drive"), "kit": ("drums", "drive", "fill", {"crash": True}), "bells": ("drums", "bells", "bells_fill")}},
        {"bars": 8, "chords": "A", "parts": {
            "synth": ["hook", "answer"], "glock": ["hook", "answer"], "celesta": ("harm", ["hook", "answer"]), "pizz": ("strum", "pizz"),
            "pad": ("pad", "pad"), "bass": ("bass", "drive"), "kit": ("drums", "drive", "fill_big", {"crash": True}),
            "bells": ("drums", "bells", "bells_fill")}},
        {"bars": 8, "chords": "B", "parts": {
            "synth": ["b_mel"], "celesta": ["b_mel"], "pizz": ("strum", "pizz"), "pad": ("pad", "pad"), "bass": ("bass", "drive"),
            "kit": ("drums", "drive_b", "fill", {"crash": True}), "bells": ("drums", "bells", "bells_fill")}},
        {"bars": 8, "chords": "A", "parts": {
            "glock": ["hook", "answer"], "synth": ("harm", ["hook", "answer"]), "celesta": ["hook", "answer"], "pizz": ("strum", "pizz"),
            "pad": ("pad", "pad"), "bass": ("bass", "drive"), "kit": ("drums", "four", "fill_big", {"crash": True}),
            "bells": ("drums", "bells", "bells_fill")}},
        {"bars": 8, "chords": "C", "parts": {
            "synth": ["c_mel"], "glock": ["c_mel"], "pizz": ("strum", "pizz"), "pad": ("pad", "pad"), "bass": ("bass", "drive"),
            "kit": ("drums", "drive_b", "fill_big", {"crash": True}), "bells": ("drums", "bells", "bells_fill")}},
    ],
}

CUES = {c["name"]: c for c in (HUB, DINO, SNOW)}

DRUM = {"kick": 36, "kick2": 35, "snare": 38, "rim": 37, "clap": 39, "hat": 42, "phat": 44, "ohat": 46, "crash": 49,
        "ride": 51, "splash": 55, "tom_hi": 50, "tom_mid": 47, "tom_lo": 45, "tom_floor": 43, "conga_mute": 62,
        "conga_hi": 63, "conga_lo": 64, "bongo_hi": 60, "bongo_lo": 61, "timb_hi": 65, "timb_lo": 66, "shaker": 70,
        "cabasa": 69, "tamb": 54, "cowbell": 56, "claves": 75, "jingle": 83, "woodblock": 76}
STEP_VEL = {"X": 1.0, "x": 0.78, "o": 0.45}

# ----------------------------------------------------------------------------------------------------------------------
# Theory helpers
# ----------------------------------------------------------------------------------------------------------------------
PC = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
NOTE_RE = re.compile(r"^([A-G])([#b]?)(-?\d)$")
QUAL = {"": (0, 4, 7), "m": (0, 3, 7), "7": (0, 4, 7, 10), "m7": (0, 3, 7, 10), "maj7": (0, 4, 7, 11),
        "6": (0, 4, 7, 9), "m6": (0, 3, 7, 9), "9": (0, 4, 7, 10, 14), "add9": (0, 4, 7, 14), "sus4": (0, 5, 7),
        "sus2": (0, 2, 7), "7sus4": (0, 5, 7, 10), "dim": (0, 3, 6), "m7b5": (0, 3, 6, 10), "aug": (0, 4, 8), "5": (0, 7)}
CHORD_RE = re.compile(r"^([A-G][#b]?)(maj7|m7b5|m7|m6|7sus4|sus4|sus2|add9|dim|aug|m|7|6|9|5)?(?:/([A-G][#b]?))?$")


def pc_of(name):
    return (PC[name[0]] + (1 if name[1:] == "#" else -1 if name[1:] == "b" else 0)) % 12


def midi_of(tok):
    m = NOTE_RE.match(tok)
    if not m:
        raise ValueError(f"bad note {tok!r}")
    return 12 * (int(m.group(3)) + 1) + PC[m.group(1)] + (1 if m.group(2) == "#" else -1 if m.group(2) == "b" else 0)


def parse_dur(s):
    if "/" in s:
        a, b = s.split("/")
        return float(a) / float(b)
    return float(s)


def parse_melody(text):
    """-> list of (beat, dur, midi, velscale); checks bar lines land on whole bars."""
    out, t = [], 0.0
    for tok in text.split():
        if tok == "|":
            if abs(t / 4 - round(t / 4)) > 1e-6:
                raise ValueError(f"bar line at beat {t} in {text[:60]!r}")
            continue
        vs = 1.0
        if tok.endswith(">"):
            vs, tok = 1.15, tok[:-1]
        elif tok.endswith("~"):
            vs, tok = 0.6, tok[:-1]
        n, d = tok.split(":")
        d = parse_dur(d)
        if n != "r":
            out.append((t, d, midi_of(n), vs))
        t += d
    return out, t


def parse_chord(sym, transpose):
    m = CHORD_RE.match(sym)
    if not m:
        raise ValueError(f"bad chord {sym!r}")
    root = (pc_of(m.group(1)) + transpose) % 12
    ivs = QUAL[m.group(2) or ""]
    bass = (pc_of(m.group(3)) + transpose) % 12 if m.group(3) else root
    return {"root": root, "pcs": sorted({(root + i) % 12 for i in ivs}), "ivs": ivs, "bass": bass, "sym": sym}


def chord_timeline(text, start_bar, transpose, bpb=4):
    bars = [b.split() for b in text.split("|")]
    tl = []
    for i, syms in enumerate(bars):
        seg = bpb / len(syms)
        for j, s in enumerate(syms):
            tl.append(((start_bar + i) * bpb + j * seg, seg, parse_chord(s, transpose)))
    return tl, len(bars)


def chord_at(tl, beat):
    cur = tl[0][2]
    for b, _, c in tl:
        if b <= beat + 1e-6:
            cur = c
    return cur


def voicing(chord, lo, hi, power=False):
    pcs = [chord["root"], (chord["root"] + 7) % 12] if power else chord["pcs"]
    notes = [n for n in range(lo, hi + 1) if n % 12 in pcs]
    if power:
        r = min(n for n in notes if n % 12 == chord["root"])
        return [r, r + 7, r + 12] if r + 12 <= hi + 5 else [r, r + 7]
    return notes


def bass_root(pc, lo=31, hi=42):
    for n in range(lo, hi + 1):
        if n % 12 == pc:
            return n
    return lo + (pc - lo) % 12


# ----------------------------------------------------------------------------------------------------------------------
# Arrangement -> note list
# ----------------------------------------------------------------------------------------------------------------------
def bars_filter(spec, nbars):
    if not spec:
        return set(range(nbars))
    a, b = spec.split("-")
    return set(range(int(a) - 1, int(b)))


def phrase_notes(cue, names, t0):
    """Concatenate named phrases (or inline notation; "rest<N>" = N bars of rest) from beat t0."""
    out, t = [], t0
    for ph in names:
        if re.fullmatch(r"rest\d+", ph):
            t += int(ph[4:]) * 4
            continue
        mel, length = parse_melody(cue["phrases"].get(ph, ph))
        out += [(t + bt, d, k, vs) for bt, d, k, vs in mel]
        t += length
    return out, t


def compile_cue(cue):
    """-> (notes, total_beats). note = dict(track, beat, dur, key, vel)."""
    tr = cue["transpose"]
    notes = []
    bar = 0
    all_tl = []
    sections = []
    for sec in cue["form"]:
        tl, n = chord_timeline(cue["chords"][sec["chords"]], bar, tr)
        if n != sec["bars"]:
            raise ValueError(f"{cue['name']}: chords {sec['chords']} has {n} bars, section wants {sec['bars']}")
        all_tl += tl
        sections.append((bar, sec, tl))
        bar += sec["bars"]
    total_beats = bar * 4

    def add(track, beat, dur, key, vel):
        key += cue["tracks"][track].get("shift", 0)  # e.g. a trombone doubling an octave below
        notes.append({"track": track, "beat": beat, "dur": dur, "key": int(key), "vel": float(min(127, max(1, vel)))})

    for start, sec, tl in sections:
        b0 = start * 4
        for track, spec in sec["parts"].items():
            if isinstance(spec, list):  # melody phrases
                mel, end = phrase_notes(cue, spec, b0)
                for bt, d, k, vs in mel:
                    add(track, bt, d, k + tr, 96 * vs)
                if end - b0 > sec["bars"] * 4 + 1e-6:
                    raise ValueError(f"{cue['name']} {track}: phrases overrun section ({end - b0} beats)")
                continue
            if spec[0] == "harm":  # harmony under a melody: the nearest chord tone 3 to 9 semitones below each note
                mel, _ = phrase_notes(cue, spec[1], b0)
                for bt, d, k, vs in mel:
                    k += tr
                    c = chord_at(tl, bt)
                    cands = [n for n in range(k - 9, k - 2) if n % 12 in c["pcs"]]
                    if cands:
                        add(track, bt, d, max(cands), 88 * vs)
                continue
            kind, what = spec[0], spec[1]
            opts = spec[3] if kind == "drums" and len(spec) > 3 else (spec[2] if kind != "drums" and len(spec) > 2 else {})
            keep = bars_filter(opts.get("bars"), sec["bars"])
            pat = cue["patterns"].get(what) if kind != "drums" else None
            for i in range(sec["bars"]):
                if i not in keep:
                    continue
                bb = b0 + i * 4
                if kind == "bass":
                    for pos, deg, d, vs in pat:
                        c = chord_at(tl, bb + pos)
                        lo, hi = (40, 52) if track == "timp" else (31, 42)
                        r = bass_root(c["bass"] if deg == "R" else c["root"], lo, hi)
                        if deg == "A":
                            nxt = chord_at(all_tl + [(total_beats, 4, all_tl[0][2])], bb + pos + 0.5 + 1e-3)
                            nr = bass_root(nxt["bass"], lo, hi)
                            key = nr - 1 if nr % 12 != r % 12 else r + 7
                        else:
                            third = 3 if 3 in c["ivs"] else 4
                            key = r + {"R": 0, "5": 7, "8": 12, "3": third, "b7": 10, "-5": -5}[deg]
                        add(track, bb + pos, d, key, 100 * vs)
                elif kind == "strum":
                    lo, hi = pat["range"]
                    for h in pat["hits"]:
                        pos, direction, vs = h[0], h[1], h[2]
                        d = h[3] if len(h) > 3 else pat.get("dur", 0.45)
                        c = chord_at(tl, bb + pos)
                        v = voicing(c, lo, hi, pat.get("power", False))
                        if direction == "U":
                            v = v[::-1][:3]
                        sp = pat.get("spread", 0.012)
                        for j, k in enumerate(v):
                            add(track, bb + pos + j * sp * cue["bpm"] / 60, d, k, 92 * vs * (0.92 ** j if direction == "U" else 1))
                elif kind == "arp":
                    lo, hi = pat["range"]
                    for pos, idx in pat["steps"]:
                        v = voicing(chord_at(tl, bb + pos), lo, hi)
                        add(track, bb + pos, pat["dur"], v[idx % len(v)] + 12 * (idx // len(v)), 100 * pat["vel"])
                elif kind == "pad":
                    lo, hi = pat["range"]
                    for cb, cd, c in tl:
                        if bb <= cb < bb + 4:
                            for k in voicing(c, lo, hi):
                                add(track, cb, cd, k, 70)
                elif kind == "drums":
                    fill = spec[2] if len(spec) > 2 else None
                    grooves = cue["grooves"]
                    is_fill = fill and (start + i + 1) % 8 == 0
                    g = grooves[fill] if is_fill else grooves[what]
                    for inst, steps in g.items():
                        for s, ch in enumerate(steps):
                            if ch in STEP_VEL:
                                add(track, bb + s * 0.25, 0.25, DRUM[inst], 104 * STEP_VEL[ch])
                    if opts.get("crash") and (start + i) % 8 == 0:
                        add(track, bb, 1.0, DRUM["crash"], 96)
                else:
                    raise ValueError(f"unknown part kind {kind}")
    return notes, total_beats


def swing_beat(b, amount, unit):
    if amount <= 0:
        return b
    k = b / unit
    if abs(k - round(k)) < 1e-6 and int(round(k)) % 2 == 1:
        return b + amount * unit
    return b


def to_events(cue, notes, passes, seed):
    """Humanised note-on/off events in samples for `passes` back-to-back copies (identical per pass)."""
    spb = 60.0 / cue["bpm"]
    per_track = {}
    for idx, n in enumerate(notes):
        t = cue["tracks"][n["track"]]
        rnd = random.Random(seed * 1000003 + idx)
        b0 = swing_beat(n["beat"], cue["swing"], cue["swing_unit"])
        b1 = swing_beat(n["beat"] + n["dur"] * t.get("gate", 1.0), cue["swing"], cue["swing_unit"])
        jit = rnd.uniform(-1, 1) * t.get("jit", 0.0)
        if n["beat"] < 1e-6:
            jit = abs(jit)  # nothing may start before the loop point, or its onset lands at the end of the file
        vel = n["vel"] + rnd.uniform(-1, 1) * t.get("hum", 0)
        on = b0 * spb + jit
        off = max(on + 0.03, b1 * spb + jit)
        per_track.setdefault(n["track"], []).append((on, off, n["key"], vel))
    return per_track


# ----------------------------------------------------------------------------------------------------------------------
# Resemblance guard: well-known tunes (opening phrases, pitch only, from memory) that a winter or island cue could
# drift towards. Every phrase of every cue is compared transposition-free (interval runs, rhythm ignored, so it is
# stricter than a listener). A run of 5+ identical consecutive intervals (6 notes) is reported as a warning.
# ----------------------------------------------------------------------------------------------------------------------
REFERENCE_TUNES = {
    "Jingle Bells (chorus)": "E4 E4 E4 E4 E4 E4 E4 G4 C4 D4 E4 F4 F4 F4 F4 F4 E4 E4 E4 E4 D4 D4 E4 D4 G4",
    "Jingle Bells (verse)": "D4 B4 A4 G4 D4 D4 B4 A4 G4 E4 E4 C5 B4 A4 F#4 D5 D5 C5 A4 B4",
    "We Wish You a Merry Christmas": "D4 G4 G4 A4 G4 F#4 E4 E4 E4 A4 A4 B4 A4 G4 F#4 D4 D4 B4 B4 C5 B4 A4 G4 E4 D4 D4 E4 A4 F#4 G4",
    "Carol of the Bells": "Bb4 A4 Bb4 G4 Bb4 A4 Bb4 G4 Bb4 A4 Bb4 G4 Bb4 A4 Bb4 G4",
    "God Rest Ye Merry Gentlemen": "E4 E4 B4 B4 A4 G4 F#4 E4 D4 E4 F#4 G4 A4 B4",
    "Deck the Halls": "C5 Bb4 A4 G4 F4 G4 A4 F4 G4 A4 Bb4 G4 A4 G4 F4 E4 F4",
    "Joy to the World": "C5 B4 A4 G4 F4 E4 D4 C4 G4 A4 A4 B4 B4 C5",
    "Silent Night": "G4 A4 G4 E4 G4 A4 G4 E4 D5 D5 B4 C5 C5 G4",
    "O Christmas Tree": "D4 G4 G4 G4 A4 B4 B4 B4 B4 A4 B4 C5 F#4 A4 G4",
    "Hark the Herald Angels Sing": "D4 G4 G4 F#4 G4 B4 B4 A4 D5 D5 D5 C5 B4 A4 B4",
    "O Come All Ye Faithful": "G4 G4 D4 G4 A4 D4 B4 A4 B4 C5 B4 A4 G4",
    "Frosty the Snowman": "G4 E4 F4 G4 C5 B4 C5 D5 C5 B4 A4 G4",
    "Rudolph the Red-Nosed Reindeer": "G4 A4 G4 E4 C5 A4 G4 G4 A4 G4 A4 G4 C5 B4",
    "Twinkle Twinkle Little Star": "C4 C4 G4 G4 A4 A4 G4 F4 F4 E4 E4 D4 D4 C4",
    "Ode to Joy": "E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 E4 D4 D4",
    "Happy Birthday": "C4 C4 D4 C4 F4 E4 C4 C4 D4 C4 G4 F4",
}


def intervals(keys):
    return [b - a for a, b in zip(keys, keys[1:])]


def longest_common_run(a, b):
    best = 0
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0] * (len(b) + 1)
        for j, y in enumerate(b):
            if x == y:
                cur[j + 1] = prev[j] + 1
                best = max(best, cur[j + 1])
        prev = cur
    return best


def fold(iv):
    """Octave-blind interval: 5 1 2 3 matches whether the 5 is above or below the 1."""
    return [((i + 6) % 12) - 6 for i in iv]


def resemblance_guard(cue):
    refs = {k: intervals([midi_of(n) for n in v.split()]) for k, v in REFERENCE_TUNES.items()}
    out = {}
    for name, text in cue["phrases"].items():
        mel, _ = parse_melody(text)
        iv = intervals([k for _, _, k, _ in mel])
        run, ref = max((longest_common_run(iv, r), k) for k, r in refs.items())
        frun, fref = max((longest_common_run(fold(iv), fold(r)), k) for k, r in refs.items())
        out[name] = {"longest_interval_run": run, "closest": ref, "octave_blind_run": frun, "octave_blind_closest": fref,
                     "warn": max(run, frun) >= 5}
    return out


# ----------------------------------------------------------------------------------------------------------------------
# Setup: soundfont + TinySoundFont
# ----------------------------------------------------------------------------------------------------------------------
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(spec, folder):
    """Download spec['url'] into a fresh folder and verify sha256. Downloads are data only."""
    folder.mkdir(parents=True, exist_ok=True)
    dest = folder / spec["file"]
    if dest.exists() and sha256(dest) == spec["sha256"]:
        return dest
    tmp = folder / (spec["file"] + ".part")
    print(f"downloading {spec['url']}", flush=True)
    with urllib.request.urlopen(spec["url"], timeout=300) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    got = sha256(tmp)
    if got != spec["sha256"]:
        tmp.unlink()
        raise SystemExit(f"sha256 mismatch for {spec['file']}: {got}")
    tmp.rename(dest)
    return dest


def setup(cache):
    sf2 = fetch(SOUNDFONT, cache / "soundfont")
    lib = cache / "tsf" / "libtsf.so"
    if not lib.exists():
        sd = fetch(TSF_SDIST, cache / "tsf_sdist")
        build = cache / "tsf"
        build.mkdir(parents=True, exist_ok=True)
        with tarfile.open(sd) as tf:
            data = tf.extractfile(tf.getmember(TSF_SDIST["member"])).read()
        (build / "tsf.h").write_bytes(data)
        (build / "tsf_impl.c").write_text('#define TSF_IMPLEMENTATION\n#include "tsf.h"\n')
        cc = os.environ.get("CC", "cc")
        subprocess.run([cc, "-O2", "-shared", "-fPIC", "-o", str(lib), str(build / "tsf_impl.c"), "-lm"], check=True)
    return sf2, lib


class TSF:
    def __init__(self, lib, sf2):
        L = ctypes.CDLL(str(lib))
        vp, ci, cf = ctypes.c_void_p, ctypes.c_int, ctypes.c_float
        L.tsf_load_filename.restype = vp
        L.tsf_load_filename.argtypes = [ctypes.c_char_p]
        L.tsf_copy.restype = vp
        L.tsf_copy.argtypes = [vp]
        L.tsf_close.argtypes = [vp]
        L.tsf_set_output.argtypes = [vp, ci, ci, cf]
        L.tsf_set_max_voices.argtypes = [vp, ci]
        L.tsf_channel_set_bank_preset.argtypes = [vp, ci, ci, ci]
        L.tsf_channel_set_presetnumber.argtypes = [vp, ci, ci, ci]
        L.tsf_channel_set_pan.argtypes = [vp, ci, cf]
        L.tsf_channel_note_on.argtypes = [vp, ci, ci, cf]
        L.tsf_channel_note_off.argtypes = [vp, ci, ci]
        L.tsf_render_float.argtypes = [vp, vp, ci, ci]
        self.L = L
        self.base = L.tsf_load_filename(str(sf2).encode())
        if not self.base:
            raise SystemExit(f"cannot load soundfont {sf2}")

    def render(self, events, nsamp, tdef):
        """events: list of (on_s, off_s, key, vel). Returns (nsamp, 2) float32."""
        L = self.L
        f = L.tsf_copy(self.base)
        L.tsf_set_output(f, 0, SR, 0.0)  # TSF_STEREO_INTERLEAVED
        L.tsf_set_max_voices(f, 256)
        ch = 9 if tdef.get("drums") else 0
        ok = (L.tsf_channel_set_presetnumber(f, ch, tdef.get("kit", 0), 1) if tdef.get("drums")
              else L.tsf_channel_set_bank_preset(f, ch, tdef.get("bank", 0), tdef["prog"]))
        if not ok:
            raise SystemExit(f"preset missing: {tdef}")
        L.tsf_channel_set_pan(f, ch, 0.5 + 0.5 * tdef.get("pan", 0.0))
        ev = []
        for on, off, key, vel in events:
            ev.append((int(round(on * SR)), 1, key, vel))
            ev.append((int(round(off * SR)), 0, key, 0))
        ev.sort(key=lambda e: (e[0], e[1]))
        buf = np.zeros(nsamp * 2, dtype=np.float32)
        base = buf.ctypes.data
        pos = 0
        for s, kind, key, vel in ev:
            s = min(max(s, 0), nsamp)
            if s > pos:
                L.tsf_render_float(f, base + pos * 8, s - pos, 0)
                pos = s
            if kind:
                L.tsf_channel_note_on(f, ch, key, max(0.01, min(1.0, vel / 127.0)))
            else:
                L.tsf_channel_note_off(f, ch, key)
        if nsamp > pos:
            L.tsf_render_float(f, base + pos * 8, nsamp - pos, 0)
        L.tsf_close(f)
        return buf.reshape(-1, 2).astype(np.float64)


# ----------------------------------------------------------------------------------------------------------------------
# Mix + master
# ----------------------------------------------------------------------------------------------------------------------
def make_ir(rt60, seed=7):
    from scipy.signal import butter, sosfilt
    n = int(rt60 * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(seed)
    ir = np.zeros((n + int(0.018 * SR), 2))
    lo = butter(2, 5000, "lp", fs=SR, output="sos")
    hi = butter(2, 5000, "hp", fs=SR, output="sos")
    for c in range(2):
        nz = rng.standard_normal(n)
        body = sosfilt(lo, nz) * 10 ** (-3 * t / rt60)
        air = sosfilt(hi, nz) * 10 ** (-3 * t / (rt60 * 0.35))
        ir[int(0.018 * SR):, c] = body + 0.5 * air
    ir /= np.sqrt(np.sum(ir ** 2) / 2)
    return ir


def peaking(f0, gain_db, q):
    """RBJ peaking biquad as one sos section."""
    a = 10 ** (gain_db / 40)
    w = 2 * np.pi * f0 / SR
    al = np.sin(w) / (2 * q)
    b = np.array([1 + al * a, -2 * np.cos(w), 1 - al * a])
    d = np.array([1 + al / a, -2 * np.cos(w), 1 - al / a])
    return np.concatenate([b / d[0], d / d[0]])[None, :]


def loudness(x):
    try:
        import pyloudnorm
        return pyloudnorm.Meter(SR).integrated_loudness(x)
    except ImportError:
        return 10 * np.log10(np.mean(x ** 2) + 1e-12) - 0.691 + 3.0  # rough RMS proxy


def limiter(x, ceil_db=-1.0):
    from scipy.ndimage import minimum_filter1d, uniform_filter1d
    c = 10 ** (ceil_db / 20)
    peak = np.max(np.abs(x), axis=1)
    g = np.minimum(1.0, c / np.maximum(peak, 1e-9))
    r = int(0.006 * SR)
    g = minimum_filter1d(g, 2 * r + 1)
    g = uniform_filter1d(g, r)
    g = minimum_filter1d(g, 2 * r + 1)  # second pass keeps the smoothed curve under every peak
    g = uniform_filter1d(g, r)
    return x * g[:, None]


def master(mix, loop_start, loop_len, target=-16.0):
    from scipy.signal import butter, lfilter, sosfilt
    x = sosfilt(butter(2, 40, "hp", fs=SR, output="sos"), mix, axis=0)
    seg = slice(loop_start, loop_start + loop_len)
    x *= 10 ** ((-18 - 10 * np.log10(np.mean(x[seg] ** 2) + 1e-12)) / 20)  # RMS -18 dBFS before the bus compressor
    # gentle bus compression: RMS detector 30 ms, 2:1 above -16 dBFS RMS, gain smoothed 120 ms
    a = 1 / (0.03 * SR)
    p = lfilter([a], [1, -(1 - a)], np.mean(x ** 2, axis=1))
    lvl = 10 * np.log10(np.maximum(p, 1e-12))
    gr = np.maximum(0.0, lvl + 16.0) * (1 - 1 / 2.0)
    b = 1 / (0.12 * SR)
    gr = lfilter([b], [1, -(1 - b)], gr)
    x = x * (10 ** (-gr / 20))[:, None]
    gain = 0.0
    for _ in range(4):
        y = limiter(x * 10 ** (gain / 20))
        lu = loudness(y[seg])
        if abs(lu - target) < 0.2:
            break
        gain += target - lu
    return y, lu, gain


def seam_check(y):
    """The wrap step (last sample -> first) must look like any other step around it: compare it with the largest step
    within 10 ms either side of the seam, and the slope across the wrap with the slopes there."""
    w = int(0.01 * SR)
    around = np.concatenate([y[-w:], y[:w]], axis=0)
    d = np.abs(np.diff(around, axis=0))
    d = np.delete(d, w - 1, axis=0)  # drop the wrap step itself
    jump = np.max(np.abs(y[0] - y[-1]))
    slope = np.max(np.abs((y[1] - y[0]) - (y[-1] - y[-2])))
    curv = np.max(np.abs(np.diff(around, 2, axis=0)))
    return {"wrap_step": float(jump), "max_local_step": float(np.max(d)), "wrap_slope_change": float(slope),
            "max_local_slope_change": float(curv), "seam_ok": bool(jump <= np.max(d) and slope <= curv)}


def write_midi(cue, notes, path):
    import mido
    mf = mido.MidiFile(type=1, ticks_per_beat=480)
    meta = mido.MidiTrack()
    meta.append(mido.MetaMessage("track_name", name=cue["name"], time=0))
    meta.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(cue["bpm"]), time=0))
    meta.append(mido.MetaMessage("time_signature", numerator=4, denominator=4, time=0))
    mf.tracks.append(meta)
    chans = iter([c for c in range(16) if c != 9])
    for name, t in cue["tracks"].items():
        ns = [n for n in notes if n["track"] == name]
        if not ns:
            continue
        ch = 9 if t.get("drums") else next(chans)
        tk = mido.MidiTrack()
        tk.append(mido.MetaMessage("track_name", name=name, time=0))
        if not t.get("drums"):
            tk.append(mido.Message("control_change", channel=ch, control=0, value=t.get("bank", 0), time=0))
            tk.append(mido.Message("program_change", channel=ch, program=t["prog"], time=0))
        tk.append(mido.Message("control_change", channel=ch, control=10, value=int(round(64 + 63 * t.get("pan", 0))), time=0))
        ev = []
        for n in ns:
            b0 = swing_beat(n["beat"], cue["swing"], cue["swing_unit"])
            b1 = swing_beat(n["beat"] + n["dur"] * t.get("gate", 1.0), cue["swing"], cue["swing_unit"])
            ev.append((int(round(b0 * 480)), 1, n["key"], int(n["vel"])))
            ev.append((max(int(round(b0 * 480)) + 1, int(round(b1 * 480))), 0, n["key"], 0))
        ev.sort(key=lambda e: (e[0], e[1]))
        now = 0
        for tick, on, key, vel in ev:
            tk.append(mido.Message("note_on" if on else "note_off", channel=ch, note=key, velocity=vel if on else 0, time=tick - now))
            now = tick
        mf.tracks.append(tk)
    mf.save(str(path))


def render_cue(cue, synth, out, seed):
    import soundfile as sf
    from scipy.signal import butter, fftconvolve, sosfilt
    notes, beats = compile_cue(cue)
    loop_s = beats * 60.0 / cue["bpm"]
    L = int(round(loop_s * SR))
    passes = 3
    nsamp = passes * L + 3 * SR
    per_track = to_events(cue, notes, passes, seed)
    dry = np.zeros((nsamp, 2))
    send = np.zeros((nsamp, 2))
    stem_rms = {}
    for name, evs in per_track.items():
        t = cue["tracks"][name]
        allev = []
        for p in range(passes):
            off = p * L / SR
            allev += [(on + off, of + off, k, v) for on, of, k, v in evs]
        stem = synth.render(allev, nsamp, t)
        if "lvl" in t:  # balance by loudness: the stem's K-weighted loudness lands at -20 LUFS + lvl
            stem *= 10 ** ((-20.0 + t["lvl"] - loudness(stem[L:2 * L])) / 20)
        else:
            stem *= 10 ** (t.get("gain", 0) / 20)
        if t.get("hp"):
            stem = sosfilt(butter(2, t["hp"], "hp", fs=SR, output="sos"), stem, axis=0)
        if t.get("lp"):
            stem = sosfilt(butter(2, t["lp"], "lp", fs=SR, output="sos"), stem, axis=0)
        for f0, gdb, q in t.get("peq", ()):
            stem = sosfilt(peaking(f0, gdb, q), stem, axis=0)
        dry += stem
        send += stem * t.get("rev", 0.0)
        stem_rms[name] = loudness(stem[L:2 * L])
    rv = cue["reverb"]
    ir = make_ir(rv["rt60"])
    wet = np.stack([fftconvolve(send[:, 0] + 0.25 * send[:, 1], ir[:, 0])[:nsamp],
                    fftconvolve(send[:, 1] + 0.25 * send[:, 0], ir[:, 1])[:nsamp]], axis=1)
    mix = dry + rv["wet"] * wet
    m, lu, gain = master(mix, L, L)
    n_x = 2048
    y = m[L:2 * L].copy()
    w = np.linspace(0, 1, n_x)[:, None]
    y[:n_x] = m[2 * L:2 * L + n_x] * (1 - w) + m[L:L + n_x] * w  # wrap continues exactly from the last sample
    pass_diff = float(np.max(np.abs(m[2 * L:2 * L + n_x] - m[L:L + n_x])))
    seam = seam_check(y)
    out.mkdir(parents=True, exist_ok=True)
    ogg = out / f"{cue['name']}.ogg"
    with sf.SoundFile(str(ogg), "w", SR, 2, format="OGG", subtype="VORBIS") as fh:
        for i in range(0, L, 32768):  # chunked: libsndfile's Vorbis writer crashes on one huge write
            fh.write(y[i:i + 32768].astype(np.float32))
    dec, sr2 = sf.read(str(ogg))
    write_midi(cue, notes, out / f"{cue['name']}.mid")
    rep = {"cue": cue["name"], "bpm": cue["bpm"], "bars": beats // 4, "seconds": round(L / SR, 3), "samples": L,
           "lufs": round(lu, 2), "peak_dbfs": round(20 * np.log10(np.max(np.abs(y))), 2),
           "ogg_peak_dbfs": round(20 * np.log10(np.max(np.abs(dec))), 2), "ogg_samples": len(dec),
           "limiter_pre_gain_db": round(gain, 2), "pass_to_pass_max_diff": pass_diff, "seam": seam,
           "ogg_seam": seam_check(dec), "soundfont": SOUNDFONT["file"], "soundfont_sha256": SOUNDFONT["sha256"],
           "notes": len(notes), "seed": seed, "resemblance_guard": resemblance_guard(cue),
           "stem_lufs_rel": {k: round(v - max(stem_rms.values()), 1) for k, v in stem_rms.items()}}
    (out / f"{cue['name']}.json").write_text(json.dumps(rep, indent=1))
    return rep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.environ.get("SKYRALLY_MUSIC_CACHE", str(Path.home() / ".cache" / "skyrally_music_v3")))
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--setup", action="store_true")
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("cues", nargs="*")
    a = ap.parse_args()
    sf2, lib = setup(Path(a.cache))
    if a.setup:
        print(sf2, lib)
        return
    synth = TSF(lib, sf2)
    for name in a.cues or list(CUES):
        rep = render_cue(CUES[name], synth, Path(a.out), a.seed)
        print(json.dumps(rep), flush=True)


if __name__ == "__main__":
    main()
