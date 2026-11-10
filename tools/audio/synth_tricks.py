#!/usr/bin/env python3
"""Trick and start cues for REMARKABLE Batch 1 items 5, 6 and 7, synthesised in code (original, licence-free: this
source is the record of how each sound was made). Writes 44.1 kHz stereo WAVs to <out_dir>; run
tools/audio/prep_audio.py on each (--trim-silence --rms -16) to get the game-ready .ogg.

  hop_boing      sine sweep 180 -> 520 Hz over 0.18 s, 14 Hz vibrato at 6 % depth, decaying tail
  trick_whoosh   band-passed noise, centre swept 600 -> 2400 -> 900 Hz over 0.3 s
  trick_stuck    marimba arpeggio C5 E5 G5 30 ms apart plus a 2093 Hz bell (0.5 s decay)
  trick_flub     sine falling 300 -> 110 Hz over 0.35 s plus a noise puff
  start_perfect  sawtooth sweep 220 -> 880 Hz over 0.35 s through a low-pass opening 600 -> 5000 Hz, then a 1568 Hz bell
  start_flood    60 ms low-passed noise thump (300 Hz), then three sputter pops 110 ms apart at decreasing gain
  roll_whoosh_r  noise band at 1.2 kHz panned left -> right over 0.45 s with a slight pitch rise (roll right)
  roll_whoosh_l  the same panned right -> left (roll left)

Usage: synth_tricks.py <out_dir>"""
import math
import sys
import wave
from pathlib import Path

import numpy as np

SR = 44100
RNG = np.random.default_rng(20261018)


def t_axis(seconds):
    return np.arange(int(SR * seconds)) / SR


def biquad(x, kind, freqs, q):
    """RBJ biquad with a per-sample centre/cutoff (freqs: array or scalar). kind: 'lp' | 'bp'."""
    n = len(x)
    f = np.broadcast_to(np.asarray(freqs, dtype=np.float64), (n,))
    y = np.zeros(n)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(n):
        w0 = 2 * math.pi * min(f[i], SR * 0.45) / SR
        cw, sw = math.cos(w0), math.sin(w0)
        alpha = sw / (2 * q)
        if kind == "lp":
            b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
        else:  # constant 0 dB peak band-pass
            b0, b1, b2 = alpha, 0.0, -alpha
        a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
        xi = x[i]
        yi = (b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, xi, y1, yi
        y[i] = yi
    return y


def phase_of(freq):
    return 2 * math.pi * np.cumsum(freq) / SR


def attack(n, ms):
    a = int(SR * ms / 1000)
    env = np.ones(n)
    if a > 0:
        env[:a] = np.linspace(0, 1, a)
    return env


def marimba(freq, seconds=0.6, decay=9.0):
    t = t_axis(seconds)
    sig = np.sin(2 * math.pi * freq * t) + 0.3 * np.sin(2 * math.pi * 4 * freq * t) * np.exp(-t * 18)
    return sig * np.exp(-t * decay) * attack(len(t), 2)


def bell(freq, seconds=0.9, decay_s=0.5):
    t = t_axis(seconds)
    env = np.exp(-t / decay_s) * attack(len(t), 1.5)
    sig = np.sin(2 * math.pi * freq * t) + 0.35 * np.sin(2 * math.pi * freq * 2.76 * t) * np.exp(-t * 6) \
        + 0.15 * np.sin(2 * math.pi * freq * 5.4 * t) * np.exp(-t * 12)
    return sig * env


def place(dst, src, at):
    i = int(SR * at)
    end = min(len(dst), i + len(src))
    dst[i:end] += src[: end - i]


def mono(x):
    return np.stack([x, x], axis=1)


def hop_boing():
    t = t_axis(0.42)
    sweep = np.where(t < 0.18, 180 + (520 - 180) * (t / 0.18), 520 - 40 * np.minimum(1, (t - 0.18) / 0.24))
    freq = sweep * (1 + 0.06 * np.sin(2 * math.pi * 14 * t))
    ph = phase_of(freq)
    env = attack(len(t), 3) * np.where(t < 0.18, 1.0, np.exp(-(t - 0.18) * 11))
    sig = (np.sin(ph) + 0.28 * np.sin(2 * ph) + 0.1 * np.sin(3 * ph)) * env
    return mono(sig * 0.6)


def trick_whoosh():
    t = t_axis(0.34)
    k = t / 0.3
    centre = np.where(k < 0.45, 600 + (2400 - 600) * (k / 0.45), 2400 - (2400 - 900) * np.minimum(1, (k - 0.45) / 0.55))
    noise = RNG.standard_normal(len(t))
    band = biquad(noise, "bp", centre, 2.2)
    env = np.sin(np.pi * np.minimum(1, t / 0.32)) ** 1.5
    return mono(band * env * 1.4)


def trick_stuck():
    out = np.zeros(int(SR * 0.95))
    for i, f in enumerate((523.25, 659.25, 783.99)):
        place(out, marimba(f) * 0.5, i * 0.03)
    place(out, bell(2093.0) * 0.32, 0.075)
    return mono(out)


def trick_flub():
    t = t_axis(0.5)
    freq = 300 - (300 - 110) * np.minimum(1, t / 0.35)
    ph = phase_of(freq)
    env = attack(len(t), 4) * np.exp(-t * 4.5)
    tone = (np.sin(ph) + 0.35 * np.sin(2 * ph) + 0.15 * np.sign(np.sin(ph)) * 0.4) * env
    puff_t = t_axis(0.22)
    puff = biquad(RNG.standard_normal(len(puff_t)), "lp", 900, 0.7) * np.exp(-puff_t * 16) * attack(len(puff_t), 2)
    out = tone * 0.55
    place(out, puff * 0.8, 0.02)
    return mono(out)


def start_perfect():
    out = np.zeros(int(SR * 1.2))
    t = t_axis(0.38)
    freq = 220 * (880 / 220) ** np.minimum(1, t / 0.35)
    ph = phase_of(freq)
    saw = 2 * ((ph / (2 * math.pi)) % 1.0) - 1
    cutoff = 600 * (5000 / 600) ** np.minimum(1, t / 0.35)
    sweep = biquad(saw, "lp", cutoff, 1.4) * attack(len(t), 5) * np.where(t < 0.34, 1.0, np.exp(-(t - 0.34) * 40))
    place(out, sweep * 0.5, 0)
    place(out, bell(1568.0, 0.85, 0.4) * 0.38, 0.34)
    return mono(out)


def start_flood():
    out = np.zeros(int(SR * 0.62))
    th_t = t_axis(0.14)
    thump = biquad(RNG.standard_normal(len(th_t)), "lp", 300, 0.9) * np.exp(-np.maximum(0, th_t - 0.06) * 45) * attack(len(th_t), 2)
    thump += np.sin(2 * math.pi * 70 * th_t) * np.exp(-th_t * 22) * 0.6
    place(out, thump * 1.3, 0)
    for i, g in enumerate((0.85, 0.6, 0.38)):
        p_t = t_axis(0.025)
        pop = biquad(RNG.standard_normal(len(p_t)), "lp", 1400, 0.8) * np.exp(-p_t * 40) * attack(len(p_t), 1)
        pop += np.sin(2 * math.pi * 95 * p_t) * np.exp(-p_t * 60) * 0.5
        place(out, pop * g, 0.12 + i * 0.11)
    return mono(out)


def roll_whoosh(direction):
    t = t_axis(0.5)
    k = np.minimum(1, t / 0.45)
    centre = 1100 + 300 * k
    band = biquad(RNG.standard_normal(len(t)), "bp", centre, 3.0)
    env = np.sin(np.pi * k) ** 1.2
    sig = band * env * 1.5
    pan = k if direction > 0 else 1 - k  # 0 = left, 1 = right
    left = sig * np.cos(pan * math.pi / 2)
    right = sig * np.sin(pan * math.pi / 2)
    return np.stack([left, right], axis=1)


def write_wav(path, x):
    peak = float(np.abs(x).max()) or 1.0
    x = x / peak * 0.89
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


CUES = {
    "hop_boing": hop_boing,
    "trick_whoosh": trick_whoosh,
    "trick_stuck": trick_stuck,
    "trick_flub": trick_flub,
    "start_perfect": start_perfect,
    "start_flood": start_flood,
    "roll_whoosh_r": lambda: roll_whoosh(1),
    "roll_whoosh_l": lambda: roll_whoosh(-1),
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
