#!/usr/bin/env python3
"""Style-lane cues for REMARKABLE Batch 2 items 15, 16 and 17 and the plane course leash (trap audit G5.4),
synthesised in code (original, licence-free: this source is the record of how each sound was made). Writes 44.1 kHz
stereo WAVs to <out_dir>; tools/audio/prep_audio.py makes the game-ready .ogg (see PREP below).

  drift_tier1   sparse electric crackle through a 3.5 kHz band + a 1760 Hz tick (mini-turbo tier 1 charged)
  drift_tier2   denser crackle + a two-note tick 1760 -> 2349 Hz (tier 2)
  drift_tier3   rising zap (saw 300 -> 2400 Hz through a band-pass) + crackle swept 2 -> 6 kHz + a C6-E6-G6 bell
                shimmer (the ZONE TURBO)
  near_miss     doppler "zwip": a whistle falling 1900 -> 700 Hz + a noise band falling 4 -> 1.2 kHz, panned across
  lava_sizzle   seamless 2 s bed: hiss, random crackle pops and a soft 55 Hz rumble (looped under a lava skim)
  style_tick    C5 marimba pluck with a woodblock click (pitched up the pentatonic per chain move in game)
  style_zone    bright C5-E5-G5-C6 marimba run + a C7 bell + an upward shimmer (chain milestones, zone callouts)
  style_break   comic "bwomp": a wobbling tone sliding 330 -> 140 Hz through a closing low-pass (chain lost)
  leash_warn    friendly two-tone "bee-boo" 784 / 587 Hz (WRONG WAY arrow)

Usage: synth_style.py <out_dir>
PREP (per cue): prep_audio.py <wav> <ogg> --trim-silence --rms -16; lava_sizzle: --loop --xfade 0.4 --rms -21."""
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from synth_tricks import SR, attack, bell, biquad, marimba, mono, phase_of, place, t_axis, write_wav  # noqa: E402

RNG = np.random.default_rng(20261019)


def crackle(seconds, rate, centre, q=1.6, decay=900.0):
    """Poisson impulse train (rate per second, random amplitude) rung through a band-pass at `centre` (scalar or
    per-sample array): an electric spark crackle."""
    n = int(SR * seconds)
    x = np.zeros(n)
    count = RNG.poisson(rate * seconds)
    idx = RNG.integers(0, n, count)
    x[idx] = RNG.uniform(0.3, 1.0, count) * RNG.choice([-1, 1], count)
    # Each impulse gets a few ms of noisy tail so it reads as a spark, not a click.
    tail = np.exp(-np.arange(int(SR * 0.006)) / SR * decay) * RNG.standard_normal(int(SR * 0.006))
    x = np.convolve(x, tail)[:n]
    return biquad(x, "bp", centre, q)


def drift_tier1():
    t = t_axis(0.3)
    out = crackle(0.3, 420, 3500) * np.exp(-t * 7) * 1.6
    tick = np.sin(2 * math.pi * 1760 * t) * np.exp(-t * 22) * attack(len(t), 1)
    out += tick * 0.45
    return mono(out)


def drift_tier2():
    t = t_axis(0.38)
    out = crackle(0.38, 950, 3800) * np.exp(-t * 5.5) * 1.6
    for i, f in enumerate((1760.0, 2349.3)):
        tt = t_axis(0.3)
        place(out, np.sin(2 * math.pi * f * tt) * np.exp(-tt * 18) * attack(len(tt), 1) * 0.42, i * 0.045)
    return mono(out)


def drift_tier3():
    out = np.zeros(int(SR * 0.95))
    t = t_axis(0.2)
    freq = 300 * (2400 / 300) ** np.minimum(1, t / 0.18)
    ph = phase_of(freq)
    saw = 2 * ((ph / (2 * math.pi)) % 1.0) - 1
    zap = biquad(saw, "bp", freq * 1.5, 1.2) * attack(len(t), 2) * np.where(t < 0.16, 1.0, np.exp(-(t - 0.16) * 60))
    place(out, zap * 0.9, 0)
    tc = t_axis(0.55)
    centre = 2000 + 4000 * np.minimum(1, tc / 0.4)
    place(out, crackle(0.55, 1600, centre, 1.4) * np.exp(-tc * 4) * 1.5, 0.02)
    for i, f in enumerate((1046.5, 1318.5, 1568.0)):
        place(out, bell(f, 0.7, 0.4) * 0.22, 0.12 + i * 0.03)
    return mono(out)


def near_miss():
    t = t_axis(0.36)
    k = np.minimum(1, t / 0.3)
    freq = 1900 * (700 / 1900) ** k
    whistle = np.sin(phase_of(freq)) * np.sin(np.pi * k) ** 1.5
    band = biquad(RNG.standard_normal(len(t)), "bp", 4000 * (1200 / 4000) ** k, 2.0) * np.sin(np.pi * k) ** 1.2
    tt = t_axis(0.08)
    tick = np.sin(2 * math.pi * 3136 * tt) * np.exp(-tt * 60) * attack(len(tt), 0.5)
    sig = whistle * 0.45 + band * 1.1
    place(sig, tick * 0.3, 0.0)
    pan = 0.25 + 0.5 * k  # drifts left of centre to right of centre as it passes
    return np.stack([sig * np.cos(pan * math.pi / 2), sig * np.sin(pan * math.pi / 2)], axis=1)


def lava_sizzle():
    seconds = 2.4  # prep_audio --loop crossfades the tail onto the head
    t = t_axis(seconds)
    hiss = biquad(RNG.standard_normal(len(t)), "bp", 4200, 0.7) * (0.55 + 0.15 * np.sin(2 * math.pi * 0.9 * t))
    pops = crackle(seconds, 28, 2600, 1.1, 500) * 3.2
    rumble = np.sin(2 * math.pi * 55 * t) * (0.25 + 0.1 * np.sin(2 * math.pi * 0.6 * t))
    left = hiss * 0.5 + pops + rumble
    right = biquad(RNG.standard_normal(len(t)), "bp", 4200, 0.7) * 0.5 * (0.55 + 0.15 * np.sin(2 * math.pi * 0.7 * t)) + pops * 0.8 + rumble
    return np.stack([left, right], axis=1)


def style_tick():
    out = np.zeros(int(SR * 0.45))
    place(out, marimba(523.25, 0.45, 10) * 0.8, 0)
    tt = t_axis(0.02)
    click = biquad(RNG.standard_normal(len(tt)), "bp", 1800, 2.5) * np.exp(-tt * 300)
    place(out, click * 0.6, 0)
    return mono(out)


def style_zone():
    out = np.zeros(int(SR * 1.1))
    for i, f in enumerate((523.25, 659.25, 783.99, 1046.5)):
        place(out, marimba(f, 0.6, 7) * 0.45, i * 0.035)
    place(out, bell(2093.0, 0.9, 0.55) * 0.3, 0.14)
    ts = t_axis(0.5)
    shimmer = biquad(RNG.standard_normal(len(ts)), "bp", 3000 + 5000 * np.minimum(1, ts / 0.45), 3.0)
    place(out, shimmer * np.sin(np.pi * np.minimum(1, ts / 0.5)) * 0.5, 0.1)
    return mono(out)


def style_break():
    t = t_axis(0.55)
    freq = (330 - 190 * np.minimum(1, t / 0.4)) * (1 + 0.035 * np.sin(2 * math.pi * 7 * t))
    ph = phase_of(freq)
    saw = 2 * ((ph / (2 * math.pi)) % 1.0) - 1
    cutoff = 1600 * (300 / 1600) ** np.minimum(1, t / 0.45)
    tone = biquad(saw, "lp", cutoff, 1.8) * attack(len(t), 6) * np.exp(-np.maximum(0, t - 0.25) * 6)
    return mono(tone * 0.9)


def leash_warn():
    out = np.zeros(int(SR * 0.5))
    for i, f in enumerate((784.0, 587.3)):
        tt = t_axis(0.2)
        env = np.minimum(1, tt / 0.01) * np.minimum(1, (0.2 - tt) / 0.03)
        tone = np.sin(2 * math.pi * f * tt) + 0.3 * np.sin(2 * math.pi * 3 * f * tt)
        place(out, biquad(tone, "lp", 3000, 0.7) * env * 0.6, i * 0.22)
    return mono(out)


CUES = {
    "drift_tier1": drift_tier1,
    "drift_tier2": drift_tier2,
    "drift_tier3": drift_tier3,
    "near_miss": near_miss,
    "lava_sizzle": lava_sizzle,
    "style_tick": style_tick,
    "style_zone": style_zone,
    "style_break": style_break,
    "leash_warn": leash_warn,
}


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in CUES.items():
        p = out / f"{name}.wav"
        write_wav(p, fn())
        print("SYNTH", p)


if __name__ == "__main__":
    main()
