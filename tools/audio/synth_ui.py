#!/usr/bin/env python3
"""Wood-and-Stone UI sound kit (REMARKABLE item 4), synthesised in code: original, licence-free, deterministic.
Writes one OGG per cue into <out_dir> (default assets/audio/ui_v1/upload), the folder tools/vfx/upload_set.py uploads:
    upload_set.py assets/audio/ui_v1/upload SkyRally_ src/shared/UiAudioAssets.luau UiAudioAssets audio
Cues (client/UiSound plays them; shared/UiSoundRules maps kinds to cues):
  ui_tap       hollow wood "tok": 3 ms 2.5 kHz band-passed noise click + 900 Hz sine (35 ms decay, small pitch drop)
               with the bar's 2.76x mode for the woodblock knock
  ui_stone     low stone "thunk": 4 ms low-passed noise + 160 Hz sine (60 ms decay) over an 80 Hz sub and a grain of
               grit, soft-saturated
  ui_marimba   C5 523.25 Hz: sine + 4x partial at 0.3, decaying 9/s, 2 ms attack, a felt-mallet tick (pitched by
               PlaybackSpeed over a major pentatonic for selection)
  ui_confirm   marimba C5 then G5, 70 ms apart (rising)
  ui_back      marimba G4 then C4, 70 ms apart (falling, softer)
  ui_deny      two stone hits 90 ms apart, the second 15 percent lower
  ui_tab       a wooden sign flipping over: an airy swish then a double clack
  ui_purchase  marimba C5-E5-G5-C6 run (55 ms steps) landing on a small bell sparkle
Usage: synth_ui.py [out_dir] [--wav]   (--wav also writes .wav previews next to the oggs, which upload_set ignores)"""
import subprocess
import sys
import tempfile
from pathlib import Path

import imageio_ffmpeg
import numpy as np

SR = 44100
ROOT = Path(__file__).resolve().parents[2]
rng = np.random.default_rng(20261018)  # fixed seed: the same bytes every run, so upload_set's sha256 skip holds


def t_axis(dur: float) -> np.ndarray:
    return np.arange(int(SR * dur)) / SR


def biquad(x: np.ndarray, kind: str, f0: float, q: float = 0.707) -> np.ndarray:
    """RBJ cookbook biquad (bandpass constant-skirt or lowpass), direct form I."""
    w0 = 2 * np.pi * f0 / SR
    alpha = np.sin(w0) / (2 * q)
    cw = np.cos(w0)
    if kind == "bp":
        b = [alpha, 0.0, -alpha]
    else:
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
    a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
    b0, b1, b2 = b[0] / a0, b[1] / a0, b[2] / a0
    a1, a2 = a1 / a0, a2 / a0
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        xi = x[i]
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        y[i] = yi
        x2, x1, y2, y1 = x1, xi, y1, yi
    return y


def attack(t: np.ndarray, sec: float) -> np.ndarray:
    return np.minimum(1.0, t / max(sec, 1e-6))


def glide_sine(t: np.ndarray, f_start: float, f_end: float, glide_s: float) -> np.ndarray:
    """Sine whose frequency eases from f_start to f_end over glide_s (phase-continuous)."""
    k = np.minimum(1.0, t / glide_s)
    f = f_end + (f_start - f_end) * (1 - k) ** 2
    return np.sin(2 * np.pi * np.cumsum(f) / SR)


def noise(dur: float) -> np.ndarray:
    return rng.uniform(-1, 1, int(SR * dur))


def place(buf: np.ndarray, sig: np.ndarray, at: float, amp: float = 1.0):
    i = int(SR * at)
    n = min(len(sig), len(buf) - i)
    buf[i:i + n] += amp * sig[:n]


def tok(freq: float = 900.0, dur: float = 0.16) -> np.ndarray:
    t = t_axis(dur)
    body = glide_sine(t, freq * 1.07, freq, 0.015) * np.exp(-t / 0.035) * attack(t, 0.0005)
    knock = np.sin(2 * np.pi * freq * 2.76 * t) * np.exp(-t / 0.010) * 0.22
    click = np.zeros_like(t)
    c = biquad(noise(0.003), "bp", 2500, 1.4) * np.hanning(int(SR * 0.003))
    click[:len(c)] = c * 2.2
    return body + knock + click


def stone(freq: float = 160.0, dur: float = 0.22) -> np.ndarray:
    t = t_axis(dur)
    body = glide_sine(t, freq * 1.25, freq, 0.012) * np.exp(-t / 0.060) * attack(t, 0.001)
    sub = np.sin(2 * np.pi * freq * 0.5 * t) * np.exp(-t / 0.050) * 0.35 * attack(t, 0.002)
    thump = np.zeros_like(t)
    th = biquad(noise(0.004), "lp", 700) * np.hanning(int(SR * 0.004))
    thump[:len(th)] = th * 3.0
    grit = np.zeros_like(t)
    g = biquad(noise(0.030), "bp", 1200, 0.9) * np.exp(-t_axis(0.030) / 0.008)
    grit[:len(g)] = g * 0.35
    return np.tanh(1.6 * (body + sub + thump + grit)) / np.tanh(1.6)


def marimba(freq: float = 523.25, dur: float = 0.7) -> np.ndarray:
    t = t_axis(dur)
    a = attack(t, 0.002)
    fund = np.sin(2 * np.pi * freq * t) * np.exp(-9 * t)
    over = 0.3 * np.sin(2 * np.pi * 4 * freq * t) * np.exp(-30 * t)
    third = 0.06 * np.sin(2 * np.pi * 9.9 * freq * t) * np.exp(-70 * t)
    tick = np.zeros_like(t)
    k = biquad(noise(0.0015), "bp", 3200, 1.0) * np.hanning(int(SR * 0.0015))
    tick[:len(k)] = k * 0.5
    return a * (fund + over + third) + tick


def bell(freq: float, dur: float = 0.9) -> np.ndarray:
    t = t_axis(dur)
    parts = [(1.0, 1.0, 3.0), (2.0, 0.45, 4.5), (3.0, 0.25, 6.0), (4.2, 0.18, 9.0), (5.4, 0.1, 12.0)]
    sig = sum(amp * np.sin(2 * np.pi * freq * r * t) * np.exp(-d * t) for r, amp, d in parts)
    shimmer = 1 + 0.18 * np.sin(2 * np.pi * 13 * t)
    return sig * shimmer * attack(t, 0.001)


C4, E4, G4, C5, E5, G5, C6 = 261.63, 329.63, 392.0, 523.25, 659.25, 783.99, 1046.5


def cue_tap():
    return tok(900.0)


def cue_stone():
    return stone(160.0)


def cue_marimba():
    return marimba(C5)


def cue_confirm():
    buf = np.zeros(int(SR * 0.85))
    place(buf, marimba(C5), 0.0, 0.85)
    place(buf, marimba(G5), 0.070, 1.0)
    return buf


def cue_back():
    buf = np.zeros(int(SR * 0.85))
    place(buf, marimba(G4), 0.0, 0.8)
    place(buf, marimba(C4), 0.070, 0.7)
    return buf


def cue_deny():
    buf = np.zeros(int(SR * 0.34))
    place(buf, stone(160.0), 0.0, 1.0)
    place(buf, stone(160.0 * 0.85), 0.090, 0.9)
    return buf


def cue_tab():
    buf = np.zeros(int(SR * 0.26))
    n = int(SR * 0.055)
    sw = noise(0.055)
    # swish: band-passed noise whose centre sweeps up (four overlapping bands, crossfaded)
    out = np.zeros(n)
    win = np.hanning(n)
    for i, f in enumerate((1500, 2300, 3300, 4500)):
        seg = biquad(sw, "bp", f, 1.2)
        w = np.clip(1 - np.abs(np.linspace(0, 3, n) - i), 0, 1)
        out += seg * w
    place(buf, out * win, 0.0, 0.5)
    place(buf, tok(1100.0), 0.045, 0.85)
    place(buf, tok(1450.0), 0.075, 0.6)
    return buf


def cue_purchase():
    buf = np.zeros(int(SR * 1.15))
    for i, (f, amp) in enumerate(((C5, 0.7), (E5, 0.75), (G5, 0.8), (C6, 0.95))):
        place(buf, marimba(f), i * 0.055, amp)
    place(buf, bell(2093.0), 0.165, 0.32)
    return buf


CUES = {
    "ui_tap": cue_tap,
    "ui_stone": cue_stone,
    "ui_marimba": cue_marimba,
    "ui_confirm": cue_confirm,
    "ui_back": cue_back,
    "ui_deny": cue_deny,
    "ui_tab": cue_tab,
    "ui_purchase": cue_purchase,
}


def finish(x: np.ndarray, peak: float = 0.8) -> np.ndarray:
    x = x - np.mean(x)
    fade = min(len(x), int(SR * 0.012))
    x[-fade:] *= np.linspace(1, 0, fade)
    # trim the silent tail (below -60 dB) so each file stays tiny
    on = np.where(np.abs(x) > 10 ** (-60 / 20) * np.abs(x).max())[0]
    if len(on):
        x = x[: on[-1] + 1]
        fade = min(len(x), int(SR * 0.006))
        x[-fade:] *= np.linspace(1, 0, fade)
    return (x * (peak / (np.abs(x).max() + 1e-9))).astype(np.float32)


def encode(x: np.ndarray, out: Path, wav: bool):
    st = np.stack([x, x], axis=1)
    ff = imageio_ffmpeg.get_ffmpeg_exe()
    with tempfile.NamedTemporaryFile(suffix=".f32") as f:
        f.write(st.tobytes())
        f.flush()
        # -map_metadata -1 and bitexact keep the container free of encoder timestamps (stable sha256 across runs)
        base = [ff, "-v", "error", "-y", "-f", "f32le", "-ac", "2", "-ar", str(SR), "-i", f.name, "-map_metadata", "-1",
                "-fflags", "+bitexact", "-flags:a", "+bitexact"]
        subprocess.run(base + ["-c:a", "libvorbis", "-q:a", "6", str(out)], check=True)
        if wav:
            subprocess.run(base + [str(out.with_suffix(".wav"))], check=True)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    wav = "--wav" in sys.argv
    out_dir = Path(args[0]) if args else ROOT / "assets/audio/ui_v1/upload"
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, fn in CUES.items():
        x = finish(fn())
        p = out_dir / f"{name}.ogg"
        encode(x, p, wav)
        print(f"SYNTH {p} {len(x) / SR * 1000:.0f} ms")


if __name__ == "__main__":
    main()
