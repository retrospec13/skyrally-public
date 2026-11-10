#!/usr/bin/env python3
"""Curtain Kart chip cues, synthesised in code (original, licence-free; docs/REMARKABLE.md item 8):
  chip_blip    square wave 880 Hz, 40 ms (a lap), short tail
  chip_engine  1.2 s seamless loop of 30 ms square-wave putts (40 per loop); client/CurtainKart pitches it by speed
  chip_go      two-note start chirp (660 Hz then 1320 Hz) when the kart drops onto the line
  chip_best    rising 8-bit arpeggio (C6 E6 G6 C7, held with vibrato) for a new curtain record
  chip_pass    shared curtain (item 28): you overtake a rival kart - a 25 % pulse "zip" sliding up an octave into a
               bright two-note ding (D6 then A6)
  chip_passed  shared curtain: a rival overtakes you - a sagging two-note "wah-wah" (square, pitch bending down,
               slow wobble on the second note)
Writes raw WAVs to assets/audio/curtain_kart/src and runs tools/audio/prep_audio.py into
assets/audio/curtain_kart/upload/<cue>.ogg (the folder tools/vfx/upload_set.py uploads).
Usage: python3 tools/audio/synth_curtain_chip.py [cue ...]   (no cue: all of them; naming cues leaves the rest
of the folder byte-identical, so tools/vfx/upload_set.py does not re-upload them)"""
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets" / "audio" / "curtain_kart" / "src"
UP = ROOT / "assets" / "audio" / "curtain_kart" / "upload"
SR = 44100


def square(freq, dur, duty=0.5, phase0=0.0):
    t = np.arange(int(SR * dur)) / SR
    ph = (t * freq + phase0) % 1.0
    return np.where(ph < duty, 1.0, -1.0).astype(np.float32)


def env(n, attack=0.002, release=0.01):
    e = np.ones(n, dtype=np.float32)
    a, r = max(1, int(attack * SR)), max(1, int(release * SR))
    e[:a] = np.linspace(0, 1, a)
    e[-r:] *= np.linspace(1, 0, r)
    return e


def place(buf, start, sig):
    i = int(start * SR)
    buf[i:i + len(sig)] += sig[: max(0, len(buf) - i)]


def blip():
    x = np.zeros(int(SR * 0.12), dtype=np.float32)
    s = square(880, 0.04)
    place(x, 0, 0.5 * s * env(len(s), 0.001, 0.006))
    return x


def engine():
    # 40 putts of 30 ms = exactly 1.2 s; each putt is an 18 ms burst of a 110 Hz pulse wave (an integer number of
    # cycles is not needed: every putt restarts its phase, so the loop wraps on a silent gap with no seam).
    x = np.zeros(int(SR * 1.2), dtype=np.float32)
    for k in range(40):
        s = square(110, 0.018, duty=0.25)
        e = np.exp(-np.arange(len(s)) / SR * 90).astype(np.float32) * env(len(s), 0.001, 0.003)
        place(x, k * 0.03, (0.55 if k % 2 == 0 else 0.4) * s * e)
    return x


def go():
    x = np.zeros(int(SR * 0.32), dtype=np.float32)
    a = square(660, 0.07)
    b = square(1320, 0.16)
    place(x, 0.0, 0.45 * a * env(len(a), 0.001, 0.01))
    place(x, 0.09, 0.45 * b * env(len(b), 0.001, 0.06))
    return x


def best():
    notes = [1046.5, 1318.5, 1568.0, 2093.0]
    x = np.zeros(int(SR * 0.75), dtype=np.float32)
    for i, f in enumerate(notes[:3]):
        s = square(f, 0.06, duty=0.25)
        place(x, i * 0.065, 0.4 * s * env(len(s), 0.001, 0.008))
    # held top note with a quick vibrato and a fade
    n = int(SR * 0.5)
    t = np.arange(n) / SR
    ph = np.cumsum(notes[3] * (1 + 0.012 * np.sin(2 * np.pi * 9 * t)) / SR)
    s = np.where((ph % 1.0) < 0.25, 1.0, -1.0).astype(np.float32)
    place(x, 0.195, 0.4 * s * np.exp(-t * 4).astype(np.float32) * env(n, 0.001, 0.04))
    return x


def bend(f0, f1, dur, duty=0.5, wobble=0.0, wob_hz=0.0):
    """Pulse wave whose pitch glides f0 -> f1 (exponential) with an optional vibrato depth (fraction) at wob_hz."""
    n = int(SR * dur)
    t = np.arange(n) / SR
    f = f0 * (f1 / f0) ** (t / dur) * (1 + wobble * np.sin(2 * np.pi * wob_hz * t))
    ph = np.cumsum(f) / SR
    return np.where((ph % 1.0) < duty, 1.0, -1.0).astype(np.float32)


def pass_():
    x = np.zeros(int(SR * 0.42), dtype=np.float32)
    z = bend(587.3, 1174.7, 0.07, duty=0.25)
    place(x, 0.0, 0.32 * z * env(len(z), 0.001, 0.005))
    a = square(1174.7, 0.06, duty=0.25)
    place(x, 0.075, 0.4 * a * env(len(a), 0.001, 0.008))
    n = int(SR * 0.26)
    t = np.arange(n) / SR
    b = square(1760.0, 0.26, duty=0.25)
    place(x, 0.14, 0.4 * b * np.exp(-t * 9).astype(np.float32) * env(n, 0.001, 0.02))
    return x


def passed():
    x = np.zeros(int(SR * 0.62), dtype=np.float32)
    a = bend(392.0, 370.0, 0.16)
    place(x, 0.0, 0.38 * a * env(len(a), 0.002, 0.02))
    n = int(SR * 0.38)
    b = bend(349.2, 261.6, 0.38, wobble=0.03, wob_hz=7.0)
    place(x, 0.19, 0.38 * b * np.linspace(1, 0.25, n).astype(np.float32) * env(n, 0.002, 0.06))
    return x


CUES = {"chip_blip": blip, "chip_engine": engine, "chip_go": go, "chip_best": best, "chip_pass": pass_,
        "chip_passed": passed}
# Loudness per cue for prep_audio (RMS dBFS over the whole file, tails included).
RMS = {"chip_blip": -17.0, "chip_engine": -24.0, "chip_go": -17.0, "chip_best": -17.0, "chip_pass": -18.0,
       "chip_passed": -19.0}


def write_wav(path, x):
    x = np.clip(x, -1, 1)
    pcm = (np.stack([x, x], axis=1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main():
    SRC.mkdir(parents=True, exist_ok=True)
    UP.mkdir(parents=True, exist_ok=True)
    only = set(sys.argv[1:])
    unknown = only - set(CUES)
    if unknown:
        raise SystemExit(f"unknown cue(s): {sorted(unknown)}")
    for name, fn in CUES.items():
        if only and name not in only:
            continue
        wav = SRC / f"{name}.wav"
        write_wav(wav, fn())
        subprocess.run([sys.executable, str(ROOT / "tools" / "audio" / "prep_audio.py"), str(wav), str(UP / f"{name}.ogg"),
                        "--rms", str(RMS[name]), "--fade-out", "0.01"], check=True)
        print("SYNTH", name)


if __name__ == "__main__":
    main()
