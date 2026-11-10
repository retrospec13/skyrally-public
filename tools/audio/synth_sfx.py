#!/usr/bin/env python3
"""Short cues synthesised in code (original and licence-free: the source below IS the record of originality, ASSETS
section 7). One function per recipe; each returns a stereo float32 array at 44.1 kHz. Output is OGG Vorbis through
prep_audio.encode, peak-limited to about -1 dBFS.
Usage: synth_sfx.py <recipe> <out.ogg>        synth_sfx.py --list
Recipes (REMARKABLE.md Batch 1): last_place -> jingle_last (item 2). Other lanes add their recipes to RECIPES."""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prep_audio import SR, encode  # noqa: E402


def midi_hz(n: float) -> float:
    return 440.0 * 2 ** ((n - 69) / 12)


def band_saw(freq: np.ndarray, top_hz: float = 7000.0, harmonics: int = 40) -> np.ndarray:
    """Additive (band-limited) sawtooth that follows a per-sample frequency curve: no aliasing hash on the slide."""
    phase = 2 * np.pi * np.cumsum(freq) / SR
    out = np.zeros_like(freq)
    for k in range(1, harmonics + 1):
        # Fade a harmonic out as it approaches top_hz instead of switching it off (no clicks while the pitch bends).
        g = np.clip((top_hz - k * freq) / 800.0, 0.0, 1.0)
        if not g.any():
            break
        out += g * np.sin(k * phase) / k
    return out * (2 / np.pi)


def svf_lowpass(x: np.ndarray, cutoff: np.ndarray, q: float) -> np.ndarray:
    """Two-pole state-variable low-pass with a per-sample cutoff (Chamberlin), so a cutoff sweep makes the wah."""
    f = 2 * np.sin(np.pi * np.clip(cutoff, 20, SR / 6) / SR)
    damp = 1.0 / q
    low = band = 0.0
    y = np.empty_like(x)
    for i in range(len(x)):
        low += f[i] * band
        high = x[i] - low - damp * band
        band += f[i] * high
        y[i] = low
    return y


def one_pole_highpass(x: np.ndarray, hz: float) -> np.ndarray:
    a = np.exp(-2 * np.pi * hz / SR)
    y = np.empty_like(x)
    prev_x = prev_y = 0.0
    for i in range(len(x)):
        prev_y = a * (prev_y + x[i] - prev_x)
        prev_x = x[i]
        y[i] = prev_y
    return y


def last_place() -> np.ndarray:
    """jingle_last: a comic wah-wah trombone, four descending notes Bb3 A3 Ab3 G3 (0.45 s each, the last 1.2 s with a
    6 Hz vibrato), each through a two-pole low-pass swept 400 -> 1800 Hz (the plunger mute opening), then a soft
    cymbal tap. Every note scoops up from 40 cents flat like a slide trombone landing on the note."""
    notes = [(58, 0.45), (57, 0.45), (56, 0.45), (55, 1.2)]  # Bb3 A3 Ab3 G3
    gap = 0.03
    total = sum(d for _, d in notes) + gap * len(notes) + 0.55
    out = np.zeros(int(SR * total))
    t0 = 0.0
    for idx, (n, dur) in enumerate(notes):
        N = int(SR * dur)
        t = np.arange(N) / SR
        last = idx == len(notes) - 1
        cents = -40 * np.exp(-t / 0.035)  # scoop into the note
        if last:
            # Vibrato fades in after 0.15 s, so the sad last note "wobbles" like the player is shrugging.
            depth = np.clip((t - 0.15) / 0.25, 0, 1) * 38
            cents = cents + depth * np.sin(2 * np.pi * 6.0 * t)
        freq = midi_hz(n) * 2 ** (cents / 1200)
        raw = band_saw(freq)
        # Wah: the cutoff opens 400 -> 1800 Hz over the first 55 % of the note, then closes a little (plunger back in).
        u = t / dur
        open_ = np.where(u < 0.55, np.sin(np.clip(u / 0.55, 0, 1) * np.pi / 2), 1 - 0.35 * ((u - 0.55) / 0.45))
        cutoff = 400 + 1400 * open_
        if last:
            cutoff = cutoff + 260 * np.sin(2 * np.pi * 6.0 * t) * np.clip((t - 0.15) / 0.25, 0, 1)  # wah-wah-wah
        y = svf_lowpass(raw, cutoff, q=2.4)
        # Brassy envelope: 25 ms attack, a slight swell, 70 ms release (the last note fades over 0.45 s).
        rel = 0.45 if last else 0.07
        env = np.minimum(1, t / 0.025) * (0.85 + 0.15 * np.minimum(1, t / 0.2))
        env *= np.clip((dur - t) / rel, 0, 1)
        i = int(SR * t0)
        out[i:i + N] += y * env
        t0 += dur + gap
    # Soft cymbal tap just as the last note dies: high-passed noise, 0.3 s decay.
    rng = np.random.default_rng(1998)
    Nc = int(SR * 0.5)
    tc = np.arange(Nc) / SR
    cym = one_pole_highpass(rng.uniform(-1, 1, Nc), 5500) * np.exp(-tc / 0.3) * np.minimum(1, tc / 0.002)
    i = int(SR * (t0 - 0.25))
    out[i:i + Nc] += 0.22 * cym
    out = out / (np.abs(out).max() + 1e-9) * 0.85
    # A touch of width: the right channel 9 ms late reads as a room around a mono horn.
    d = int(SR * 0.009)
    right = np.concatenate([np.zeros(d), out[:-d]])
    return np.stack([out, 0.85 * out + 0.15 * right], axis=1).astype(np.float32)


RECIPES = {
    "last_place": last_place,
}


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--list":
        print("\n".join(RECIPES))
        return
    if len(sys.argv) != 3 or sys.argv[1] not in RECIPES:
        sys.exit(__doc__)
    x = RECIPES[sys.argv[1]]()
    encode(x, Path(sys.argv[2]))
    print(f"SYNTH {sys.argv[1]} -> {sys.argv[2]} seconds={len(x) / SR:.2f}")


if __name__ == "__main__":
    main()
