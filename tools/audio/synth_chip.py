#!/usr/bin/env python3
"""Secret Stinger chiptune (REMARKABLE item 9), synthesised in code: an original 8-bit fanfare composed for SkyRally.
The note lists below are the composition (MIDI note numbers, lengths in sixteenths at 120 BPM); they are the record of
originality for ASSETS section 7. Channels follow a late-80s handheld sound chip: a 12.5 % pulse lead (with a fake
echo, as the old games did with a spare channel), a 25 % pulse harmony, a 4-bit stepped triangle bass, a
triangle-sweep kick and a noise channel (closed hat, snare, crash).
Usage: synth_chip.py secret|find <out.ogg>
  secret -> chip_secret (4 s, hidden key found), find -> chip_find (1.5 s, hub find)"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prep_audio import SR, encode  # noqa: E402

BPM = 120
SIXTEENTH = 60 / BPM / 4  # 0.125 s
R = None  # rest

# --- the composition ------------------------------------------------------------------------------------------------
# chip_secret, D major, two bars: a sparkle pickup up the D chord, a hop to the octave and a skip down (D), a turn
# around F# (A), a stepwise run up (G), a reach to the high E that falls home to D (A -> D).
SECRET = {
    "lead": [(69, 1), (74, 1), (78, 1), (81, 1), (86, 2), (81, 1), (83, 1),
             (79, 2), (78, 1), (76, 1), (78, 4),
             (83, 2), (81, 2), (79, 1), (81, 1), (83, 2),
             (85, 2), (88, 2), (86, 4)],
    "harmony": [(R, 4), (78, 2), (78, 1), (79, 1),
                (76, 2), (74, 1), (73, 1), (69, 4),
                (79, 2), (78, 2), (74, 1), (78, 1), (79, 2),
                (81, 2), (85, 2), (81, 4)],
    "bass": [(50, 2), (62, 2), (50, 2), (62, 2), (45, 2), (57, 2), (45, 2), (57, 2),
             (43, 2), (55, 2), (43, 2), (55, 2), (45, 2), (57, 2), (50, 4)],
    "kick": [0, 8, 16, 24, 28],
    "snare": [4, 12, 20, 25, 26, 27],
    "hat": [2, 6, 10, 14, 18, 22],
    "crash": [28],
    "steps": 32,
}

# chip_find: the same idea in 1.5 s, a three-note chirp up to the octave and the high E falling home to D.
FIND = {
    "lead": [(78, 1), (81, 1), (86, 2), (85, 1), (88, 1), (86, 6)],
    "harmony": [(R, 2), (78, 2), (81, 2), (81, 6)],
    "bass": [(50, 2), (57, 2), (45, 2), (50, 6)],
    "kick": [0, 6],
    "snare": [4, 5],
    "hat": [2],
    "crash": [6],
    "steps": 12,
}
# ---------------------------------------------------------------------------------------------------------------------


def hz(n: float) -> float:
    return 440.0 * 2 ** ((n - 69) / 12)


def polyblep(t: np.ndarray, dt: float) -> np.ndarray:
    y = np.zeros_like(t)
    a = t < dt
    x = t[a] / dt
    y[a] = 2 * x - x * x - 1
    b = t > 1 - dt
    x = (t[b] - 1) / dt
    y[b] = x * x + 2 * x + 1
    return y


def pulse(freq: np.ndarray, duty: float) -> np.ndarray:
    """Band-limited pulse (difference of two polyBLEP saws): keeps the hollow chip timbre without aliasing hash."""
    ph = np.cumsum(freq / SR) % 1.0
    dt = float(np.mean(freq)) / SR
    saw1 = 2 * ph - 1 - polyblep(ph, dt)
    ph2 = (ph + 1 - duty) % 1.0
    saw2 = 2 * ph2 - 1 - polyblep(ph2, dt)
    out = saw1 - saw2
    return out - out.mean()


def triangle4(freq: np.ndarray) -> np.ndarray:
    """The chip's 4-bit triangle: 16 volume steps, the slightly buzzy bass people remember."""
    ph = np.cumsum(freq / SR) % 1.0
    tri = 1 - 4 * np.abs(ph - 0.5)
    return np.round((tri + 1) * 7.5) / 7.5 - 1


def render_voice(notes, steps: int, kind: str, gain: float) -> np.ndarray:
    total = int(SR * (steps * SIXTEENTH + 0.6))
    out = np.zeros(total)
    pos = 0
    for i, (n, length) in enumerate(notes):
        dur = length * SIXTEENTH
        last = i == len(notes) - 1
        if n is not None:
            hold = dur + (0.45 if last else 0.0)  # the final note rings out past the bar line
            N = int(SR * hold)
            t = np.arange(N) / SR
            f = np.full(N, hz(n))
            if length >= 4 and kind != "bass":
                # Delayed vibrato on held notes, the chip-music signature.
                f *= 2 ** (np.clip((t - 0.12) / 0.15, 0, 1) * 0.25 * np.sin(2 * np.pi * 6.5 * t) / 12)
            if kind == "lead":
                wave = pulse(f, 0.125)
                env = np.minimum(1, t / 0.002) * (0.72 + 0.28 * np.exp(-t / 0.07))
            elif kind == "harmony":
                wave = pulse(f, 0.25)
                env = np.minimum(1, t / 0.002) * (0.6 + 0.4 * np.exp(-t / 0.05))
            else:
                wave = triangle4(f)
                env = np.ones(N)
            # Articulation: a 12 ms gap before the next note (the chip re-triggering), longer release on the last.
            rel = 0.4 if last else 0.012
            env *= np.clip((hold - t) / rel, 0, 1)
            i0 = int(SR * pos * SIXTEENTH)
            seg = wave * env * gain
            out[i0:i0 + len(seg)] += seg[: total - i0]
        pos += length
    return out


def lfsr_noise(N: int, period: int, seed: int) -> np.ndarray:
    """Sample-and-hold noise at a chip clock-divider rate (period in samples): short = hiss, long = crunchy."""
    rng = np.random.default_rng(seed)
    v = rng.choice([-1.0, 1.0], size=N // period + 1)
    return np.repeat(v, period)[:N]


def drums(spec, total: int) -> np.ndarray:
    out = np.zeros(total)

    def put(at_step: float, sig: np.ndarray):
        i0 = int(SR * at_step * SIXTEENTH)
        out[i0:i0 + len(sig)] += sig[: total - i0]

    for s in spec["kick"]:
        N = int(SR * 0.09)
        t = np.arange(N) / SR
        f = 55 + 120 * np.exp(-t / 0.018)
        put(s, triangle4(f) * np.exp(-t / 0.05) * 0.55)
    for k, s in enumerate(spec["snare"]):
        N = int(SR * 0.12)
        t = np.arange(N) / SR
        put(s, lfsr_noise(N, 3, 10 + k) * np.exp(-t / 0.045) * 0.32)
    for k, s in enumerate(spec["hat"]):
        N = int(SR * 0.03)
        t = np.arange(N) / SR
        put(s, lfsr_noise(N, 1, 40 + k) * np.exp(-t / 0.008) * 0.12)
    for k, s in enumerate(spec["crash"]):
        N = int(SR * 0.9)
        t = np.arange(N) / SR
        put(s, lfsr_noise(N, 2, 70 + k) * np.exp(-t / 0.28) * 0.16)
    return out


def render(spec) -> np.ndarray:
    steps = spec["steps"]
    lead = render_voice(spec["lead"], steps, "lead", 0.30)
    harm = render_voice(spec["harmony"], steps, "harmony", 0.17)
    bass = render_voice(spec["bass"], steps, "bass", 0.34)
    total = len(lead)
    dr = drums(spec, total)
    # Fake echo on the lead: three sixteenths late at 28 %, the trick the old games played with a spare channel.
    d = int(SR * 3 * SIXTEENTH)
    echo = np.concatenate([np.zeros(d), lead[:-d]]) * 0.28
    left = lead + 0.8 * harm + bass + dr + 0.4 * echo
    right = 0.85 * lead + harm + bass + dr + echo
    x = np.stack([left, right], axis=1)
    # Gentle output filter (the console's DAC and speaker): one-pole low-pass near 9 kHz, DC blocked.
    a = np.exp(-2 * np.pi * 9000 / SR)
    for c in range(2):
        y = x[:, c]
        acc = 0.0
        for i in range(len(y)):
            acc = (1 - a) * y[i] + a * acc
            y[i] = acc
        x[:, c] = y - y.mean()
    # Trim the silent tail and normalise to a -1 dBFS peak.
    lvl = np.abs(x).max(axis=1)
    on = np.where(lvl > 1e-3)[0]
    x = x[: on[-1] + 1]
    return (x / (np.abs(x).max() + 1e-9) * 0.88).astype(np.float32)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("secret", "find"):
        sys.exit(__doc__)
    x = render(SECRET if sys.argv[1] == "secret" else FIND)
    encode(x, Path(sys.argv[2]))
    print(f"SYNTH chip_{sys.argv[1]} -> {sys.argv[2]} seconds={len(x) / SR:.2f}")


if __name__ == "__main__":
    main()
