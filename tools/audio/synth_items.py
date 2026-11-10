#!/usr/bin/env python3
"""Item feedback cues for REMARKABLE Batch 2 items 14, 18 and 19, synthesised in code (original, licence-free: this
source is the record of how each sound was made). Writes 44.1 kHz stereo WAVs to <out_dir>; run
tools/audio/prep_items.sh to get the game-ready .ogg files (prep_audio.py --trim-silence --rms -16).

  item_beep     lock-on blip: 70 ms soft square at 1760 Hz with a 2 ms click edge (client pitches it up as the shot closes)
  item_bonk     comic head-bonk: a wood-block knock, then a hollow inharmonic "pan" tone at 330 Hz bending down 22 %
                with a decaying 17 Hz wobble (the cartoon "doyng"), 0.6 s
  item_dizzy    three little bird chirps circling the head: sine sweeps 2.6 -> 3.4 -> 2.9 kHz with vibrato, panned
                left, right, left 0.2 s apart, 1.0 s
  item_gotcha   your shot landed: marimba G5 then C6 70 ms apart and a 4186 Hz sparkle bell, 0.8 s
  item_revenge  REVENGE!: three rising filtered-saw chord stabs (C, D, E major) then a held E major chord with the
                low-pass opening and a soft noise crash, 1.5 s
  item_flyby    DODGED!: a shot whistling past, band-passed noise and a tone falling 1.9 kHz -> 520 Hz (Doppler drop)
                panned left to right, 0.55 s
  taunt_pop     speech bubble pop: sine chirp 380 -> 1500 Hz in 45 ms with a tiny click, 0.12 s

Usage: synth_items.py <out_dir>"""
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from synth_tricks import SR, attack, bell, biquad, marimba, mono, phase_of, place, t_axis, write_wav  # noqa: E402

RNG = np.random.default_rng(20261019)


def pan(sig, p):
    """p: scalar or array, 0 = left, 1 = right (equal power)."""
    p = np.broadcast_to(np.asarray(p, dtype=np.float64), sig.shape)
    return np.stack([sig * np.cos(p * math.pi / 2), sig * np.sin(p * math.pi / 2)], axis=1)


def item_beep():
    t = t_axis(0.09)
    f = 1760.0
    ph = 2 * math.pi * f * t
    # A soft square: odd harmonics rolled off, so it reads as "electronic" without being harsh on phone speakers.
    sq = np.sin(ph) + np.sin(3 * ph) / 3 * 0.6 + np.sin(5 * ph) / 5 * 0.3
    env = attack(len(t), 2) * np.where(t < 0.06, 1.0, np.exp(-(t - 0.06) * 120))
    return mono(sq * env * 0.55)


def item_bonk():
    out = np.zeros(int(SR * 0.7))
    # The knock: a wood-block click (band-passed noise burst) and a short 1.1 kHz damped sine.
    k_t = t_axis(0.05)
    knock = biquad(RNG.standard_normal(len(k_t)), "bp", 1800, 1.4) * np.exp(-k_t * 90) * attack(len(k_t), 0.5)
    knock += np.sin(2 * math.pi * 1100 * k_t) * np.exp(-k_t * 70) * 0.8
    place(out, knock * 0.9, 0)
    # The "doyng": inharmonic pan partials, pitch bending down, with a wobble that dies away.
    t = t_axis(0.62)
    bend = 330 * (1 - 0.22 * np.minimum(1, t / 0.35))
    wob = 1 + 0.035 * np.sin(2 * math.pi * 17 * t) * np.exp(-t * 5)
    base = bend * wob
    sig = np.zeros(len(t))
    for ratio, gain, decay in ((1.0, 1.0, 5.5), (2.76, 0.45, 9), (5.4, 0.22, 16), (0.5, 0.35, 7)):
        sig += np.sin(phase_of(base * ratio)) * gain * np.exp(-t * decay)
    sig *= attack(len(t), 1.5)
    place(out, sig * 0.75, 0.008)
    return mono(out)


def chirp(seconds=0.11):
    t = t_axis(seconds)
    k = t / seconds
    f = np.where(k < 0.45, 2600 + 800 * (k / 0.45), 3400 - 500 * ((k - 0.45) / 0.55))
    f = f * (1 + 0.025 * np.sin(2 * math.pi * 38 * t))
    env = np.sin(math.pi * np.minimum(1, k)) ** 1.3
    return np.sin(phase_of(f)) * env


def item_dizzy():
    out = np.zeros((int(SR * 1.0), 2))
    for i, (at, p) in enumerate(((0.0, 0.15), (0.2, 0.85), (0.4, 0.3), (0.62, 0.7))):
        c = chirp(0.1 + 0.015 * (i % 2)) * (0.6 - 0.08 * i)
        st = pan(c, p)
        i0 = int(SR * at)
        out[i0:i0 + len(st)] += st[: len(out) - i0]
    return out


def item_gotcha():
    out = np.zeros(int(SR * 0.85))
    place(out, marimba(783.99) * 0.55, 0.0)  # G5
    place(out, marimba(1046.5) * 0.6, 0.07)  # C6
    place(out, bell(4186.0, 0.7, 0.25) * 0.22, 0.09)
    return mono(out)


def saw_chord(freqs, seconds, cutoff_from, cutoff_to, decay=None):
    t = t_axis(seconds)
    sig = np.zeros(len(t))
    for f in freqs:
        for detune in (0.997, 1.003):
            ph = phase_of(np.full(len(t), f * detune))
            sig += 2 * ((ph / (2 * math.pi)) % 1.0) - 1
    sig /= len(freqs) * 2
    cutoff = cutoff_from * (cutoff_to / cutoff_from) ** np.minimum(1, t / max(seconds * 0.6, 1e-3))
    sig = biquad(sig, "lp", cutoff, 1.1)
    env = attack(len(t), 4)
    if decay:
        env = env * np.exp(-t * decay)
    return sig * env


def item_revenge():
    out = np.zeros(int(SR * 1.55))
    stabs = (
        (261.63, 329.63, 392.0),  # C major
        (293.66, 369.99, 440.0),  # D major
        (329.63, 415.30, 493.88),  # E major
    )
    for i, chord in enumerate(stabs[:2]):
        place(out, saw_chord(chord, 0.14, 900, 2600, decay=14) * 0.85, i * 0.13)
    held = saw_chord(stabs[2] + (164.81,), 1.25, 700, 5200)
    held *= np.where(t_axis(1.25) < 0.9, 1.0, np.exp(-(t_axis(1.25) - 0.9) * 9))
    place(out, held * 0.95, 0.26)
    c_t = t_axis(1.1)
    crash = biquad(RNG.standard_normal(len(c_t)), "bp", 6500, 0.6) * np.exp(-c_t * 4.2) * attack(len(c_t), 1)
    place(out, crash * 0.25, 0.26)
    return mono(out)


def item_flyby():
    t = t_axis(0.55)
    k = t / 0.55
    f = 1900 * (520 / 1900) ** np.clip((k - 0.25) / 0.5, 0, 1)
    tone = np.sin(phase_of(f)) * 0.35
    noise = biquad(RNG.standard_normal(len(t)), "bp", f * 1.4, 2.0) * 0.9
    env = np.exp(-((k - 0.42) ** 2) / 0.035)
    sig = (tone + noise) * env
    return pan(sig, 0.2 + 0.6 * k) * 1.2  # whistles past from left to right


def taunt_pop():
    out = np.zeros(int(SR * 0.12))
    t = t_axis(0.06)
    f = 380 * (1500 / 380) ** np.minimum(1, t / 0.045)
    pop = np.sin(phase_of(f)) * attack(len(t), 1) * np.exp(-t * 35)
    place(out, pop * 0.7, 0)
    c_t = t_axis(0.006)
    place(out, RNG.standard_normal(len(c_t)) * np.exp(-c_t * 900) * 0.2, 0)
    return mono(out)


CUES = {
    "item_beep": item_beep,
    "item_bonk": item_bonk,
    "item_dizzy": item_dizzy,
    "item_gotcha": item_gotcha,
    "item_revenge": item_revenge,
    "item_flyby": item_flyby,
    "taunt_pop": taunt_pop,
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
