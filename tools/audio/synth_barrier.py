#!/usr/bin/env python3
"""ISLAND-2 cavern-mouth battle barrier cue, synthesised in code (original, licence-free; trap I2-05 fun layer):
  barrier_snore  4.4 s seamless loop: a giant sleeping sea creature in the dark cave behind the battle barrier.
                 A low rattling snort on the in-breath (62-70 Hz buzz plus a 40 Hz sub, gated by a 26 Hz palate
                 flutter), a lip "puh", a long breathy whistle on the out-breath, then a beat of quiet; all of it
                 through a circular cave echo (comb + allpass network run over three tiled copies, middle copy kept), so
                 the Looped Sound wraps with no seam and no click.
Writes assets/audio/battle_barrier/src/barrier_snore.wav and runs tools/audio/prep_audio.py into
assets/audio/battle_barrier/upload/barrier_snore.ogg (the folder tools/vfx/upload_set.py uploads; generated table
src/shared/BarrierAudio.luau, read by server/battle/BattleBarriers).
Usage: python3 tools/audio/synth_barrier.py"""
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets" / "audio" / "battle_barrier" / "src"
UP = ROOT / "assets" / "audio" / "battle_barrier" / "upload"
SR = 44100
LOOP = 4.4
SEED = 20261019


def band_noise(n: int, lo: float, hi: float, rng: np.random.Generator) -> np.ndarray:
    """White noise shaped to lo..hi Hz in the frequency domain (circular, so it loops)."""
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / SR)
    mask = np.clip((f - lo * 0.7) / (lo * 0.3 + 1e-9), 0, 1) * np.clip((hi * 1.3 - f) / (hi * 0.3), 0, 1)
    x = np.fft.irfft(spec * mask, n)
    return x / (np.abs(x).max() + 1e-9)


def lowpass(x: np.ndarray, fc: float) -> np.ndarray:
    """Soft circular low-pass (frequency-domain, raised-cosine roll-off over fc..2 fc)."""
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    roll = np.clip((f - fc) / fc, 0, 1)
    return np.fft.irfft(spec * (0.5 + 0.5 * np.cos(np.pi * roll)), len(x))


def env(t: np.ndarray, a: float, b: float, rise: float, fall: float) -> np.ndarray:
    """0 outside a..b, smooth (raised-cosine) rise and fall inside."""
    e = np.zeros_like(t)
    up = np.clip((t - a) / rise, 0, 1)
    down = np.clip((b - t) / fall, 0, 1)
    e = np.minimum(up, down)
    return 0.5 - 0.5 * np.cos(np.pi * e)


def snore() -> np.ndarray:
    rng = np.random.default_rng(SEED)
    n = int(SR * LOOP)
    t = np.arange(n) / SR
    out = np.zeros(n)

    # in-breath: rattling snort, pitch sliding up a little, swelling to the middle
    e_in = env(t, 0.05, 1.75, 0.35, 0.18) * (0.75 + 0.25 * np.sin(np.pi * np.clip((t - 0.05) / 1.7, 0, 1)))
    f0 = 62 + 8 * np.clip((t - 0.05) / 1.7, 0, 1)
    ph = np.cumsum(f0) / SR
    buzz = 2 * (ph % 1.0) - 1  # saw
    buzz += 0.5 * np.sin(2 * np.pi * 2 * ph)
    buzz = lowpass(buzz, 520.0)  # a throat, not a synth: only the low harmonics
    flutter = (0.5 + 0.5 * np.sin(2 * np.pi * 26 * t + 0.6 * np.sin(2 * np.pi * 3 * t))) ** 2
    rasp = band_noise(n, 90, 600, rng)
    out += e_in * flutter * (0.55 * buzz + 0.45 * rasp)
    out += 0.35 * e_in * np.sin(2 * np.pi * 40 * t)  # the size of the thing

    # lip "puh" at the turn of the breath
    pop = env(t, 1.92, 2.02, 0.004, 0.08)
    out += 0.7 * pop * band_noise(n, 60, 400, rng)

    # out-breath: long breathy whoosh with a wobbling whistle on top, fading away
    e_out = env(t, 1.98, 3.55, 0.12, 0.9)
    whoosh = band_noise(n, 280, 1400, rng)
    fw = 1150 - 300 * np.clip((t - 2.0) / 1.5, 0, 1) + 25 * np.sin(2 * np.pi * 5.5 * t)
    whistle = np.sin(2 * np.pi * np.cumsum(fw) / SR)
    out += e_out * (0.42 * whoosh + 0.16 * whistle * env(t, 2.1, 3.3, 0.2, 0.5))
    return out / (np.abs(out).max() + 1e-9)


def cave(x: np.ndarray, delays_ms, gain: float) -> np.ndarray:
    """Circular echo: feedback combs plus two allpasses over three tiled copies; the middle copy is the loop."""
    n = len(x)
    y3 = np.tile(x, 3)
    wet = np.zeros_like(y3)
    for d_ms in delays_ms:
        d = int(SR * d_ms / 1000)
        # block recursion: c[k] = x[k] + g * c[k - d], done d samples at a time
        c = y3.copy()
        for s in range(d, len(c), d):
            e = min(s + d, len(c))
            c[s:e] += gain * c[s - d:e - d]
        wet += c
    wet /= len(delays_ms)
    for d_ms, g in ((5.0, 0.6), (1.7, 0.6)):
        d = int(SR * d_ms / 1000)
        a = wet.copy()
        out = np.zeros_like(a)
        for s in range(0, len(a), d):
            e = min(s + d, len(a))
            prev_out = out[s - d:e - d] if s >= d else np.zeros(e - s)
            prev_in = a[s - d:e - d] if s >= d else np.zeros(e - s)
            out[s:e] = -g * a[s:e] + prev_in + g * prev_out
        wet = out
    return wet[n:2 * n]


def build() -> np.ndarray:
    dry = snore()
    left = 0.62 * dry + 0.55 * cave(dry, (47.0, 61.0, 79.0, 97.0), 0.72)
    right = 0.62 * dry + 0.55 * cave(dry, (43.0, 67.0, 83.0, 101.0), 0.72)
    st = np.stack([left, right], axis=1)
    return st / (np.abs(st).max() + 1e-9) * 0.9


def write_wav(path: Path, x: np.ndarray):
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main():
    SRC.mkdir(parents=True, exist_ok=True)
    UP.mkdir(parents=True, exist_ok=True)
    wav = SRC / "barrier_snore.wav"
    x = build()
    # a seamless loop: the last sample runs into the first
    assert np.abs(x[-1] - x[0]).max() < 0.05, np.abs(x[-1] - x[0]).max()
    write_wav(wav, x)
    subprocess.run([sys.executable, str(ROOT / "tools" / "audio" / "prep_audio.py"), str(wav), str(UP / "barrier_snore.ogg"),
                    "--rms", "-21"], check=True)
    print("SYNTH barrier_snore", f"{len(x) / SR:.2f}s")


if __name__ == "__main__":
    main()
