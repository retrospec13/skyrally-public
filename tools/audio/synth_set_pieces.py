#!/usr/bin/env python3
"""Set-piece cues synthesised in code (docs/REMARKABLE.md Batch 2 items 13, 21, 25; original, licence-free, no samples
except where a recipe says it layers this project's own Higgsfield take):
  cannon_fuse    0.9 s fuse: band-passed crackle (2-7 kHz) with random spark pops, brightening as it burns down
  cannon_boom    a punchy cartoon cannon: a 25 ms high-passed crack, a sine thump falling 95 -> 38 Hz, a low-passed
                 noise body, and the Higgsfield take assets/audio/set_pieces/raw/cannon_boom.mp3 (job in jobs.json)
                 layered 8 dB under it from 60 ms as the rolling echo
  slide_whistle  1.6 s slide whistle over the cannon arc: up 520 -> 1650 Hz, then down to 430 Hz, breathy, 5 Hz vibrato
  dizzy_tweets   1.4 s of little birds circling a dizzy boss: chirps sweeping 2.6 -> 4.2 kHz in threes
  retire_poof    0.7 s puff of smoke with a sparkle: low noise breath and a two-note glass ping (E6, B6)
  monorail_win   the "you beat the train" bell fanfare: G5 G5 G5 C6 on a bright two-partial bell
Writes 44.1 kHz WAVs into <out_dir> (default assets/audio/set_pieces/raw); tools/audio/prep_set_pieces.sh makes the
.ogg files. Usage: synth_set_pieces.py [out_dir]"""
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

SR = 44100
ROOT = Path(__file__).resolve().parents[2]
rng = np.random.default_rng(20261019)


def t_axis(sec):
    return np.arange(int(SR * sec)) / SR


def lowpass(x, fc, order=4):
    f = np.fft.rfftfreq(len(x), 1 / SR)
    return np.fft.irfft(np.fft.rfft(x) / np.sqrt(1 + (f / fc) ** (2 * order)), len(x))


def highpass(x, fc, order=4):
    f = np.fft.rfftfreq(len(x), 1 / SR)
    g = 1 - 1 / np.sqrt(1 + (f / fc) ** (2 * order))
    return np.fft.irfft(np.fft.rfft(x) * g, len(x))


def bandpass(x, lo, hi):
    f = np.fft.rfftfreq(len(x), 1 / SR)
    g = 1 / np.sqrt(1 + (f / hi) ** 8) * (1 - 1 / np.sqrt(1 + (f / lo) ** 8))
    return np.fft.irfft(np.fft.rfft(x) * g, len(x))


def sine_sweep(freq_curve):
    return np.sin(2 * np.pi * np.cumsum(freq_curve) / SR)


def norm(x):
    return x / (np.abs(x).max() + 1e-9)


def fuse():
    dur = 0.9
    t = t_axis(dur)
    hiss = bandpass(rng.standard_normal(len(t)), 2000, 7000) * (0.35 + 0.4 * t / dur)
    pops = np.zeros_like(t)
    at = 0.01
    k = int(SR * 0.006)
    while at < dur - 0.02:
        i = int(at * SR)
        n = min(k, len(t) - i)
        pops[i:i + n] += rng.uniform(0.5, 1.0) * np.exp(-np.arange(n) / (SR * 0.0012)) * rng.standard_normal(n)
        at += rng.uniform(0.012, 0.05)
    pops = highpass(pops, 1500) * 1.6
    env = np.clip(t / 0.02, 0, 1) * np.clip((dur - t) / 0.05, 0, 1)
    return (hiss + pops) * env


def boom():
    dur = 2.6
    t = t_axis(dur)
    crack = highpass(rng.standard_normal(len(t)), 900) * np.exp(-t / 0.012) * 1.4
    thump_f = 38 + 57 * np.exp(-t / 0.09)
    thump = sine_sweep(thump_f) * np.exp(-t / 0.42) * 1.6
    body = lowpass(rng.standard_normal(len(t)), 420) * np.exp(-t / 0.55) * 2.2
    x = norm(crack + thump + body)
    take = ROOT / "assets" / "audio" / "set_pieces" / "raw" / "cannon_boom.mp3"
    if take.exists():
        from prep_audio import decode
        echo = decode(take).mean(axis=1)
        echo = norm(echo) * 10 ** (-8 / 20)
        i = int(0.06 * SR)
        n = min(len(echo), len(x) - i)
        fade = np.ones(n)
        tail = int(0.4 * SR)
        fade[-tail:] = np.linspace(1, 0, tail)
        x[i:i + n] += echo[:n] * fade
    return x


def slide_whistle():
    dur = 1.6
    t = t_axis(dur)
    up = 0.62
    rise = np.clip(t / up, 0, 1)
    fall = np.clip((t - up) / (dur - up), 0, 1)
    f = np.where(t < up, 520 + (1650 - 520) * rise ** 0.7, 1650 - (1650 - 430) * fall ** 1.3)
    f = f * (1 + 0.018 * np.sin(2 * np.pi * 5 * t))
    tone = sine_sweep(f) + 0.12 * sine_sweep(2 * f)
    breath = bandpass(rng.standard_normal(len(t)), 900, 4000) * 0.12
    env = np.clip(t / 0.04, 0, 1) * np.clip((dur - t) / 0.12, 0, 1)
    return (tone + breath) * env


def tweets():
    out = np.zeros(int(SR * 1.4))
    for start in (0.0, 0.46, 0.92):
        for j in range(3):
            d = 0.07
            t = t_axis(d)
            f = 2600 + 1600 * (t / d) ** 0.6 + j * 150
            c = sine_sweep(f) * np.sin(np.pi * t / d) ** 2
            i = int((start + j * 0.1) * SR)
            out[i:i + len(c)] += c * (0.9 - 0.15 * j)
    return out


def bell(freq, dur, decay=2.5):
    t = t_axis(dur)
    x = np.sin(2 * np.pi * freq * t) + 0.35 * np.sin(2 * np.pi * freq * 2.76 * t) * np.exp(-t * 3)
    return x * np.exp(-t * decay) * np.clip(t / 0.003, 0, 1)


def poof():
    t = t_axis(0.7)
    breath = lowpass(rng.standard_normal(len(t)), 500) * np.clip(t / 0.02, 0, 1) * np.exp(-t / 0.14) * 2.4
    out = breath
    for at, f in ((0.08, 1318.5), (0.16, 1975.5)):
        b = bell(f, 0.7 - at, 6)
        i = int(at * SR)
        n = min(len(b), len(out) - i)
        out[i:i + n] += b[:n] * 0.35
    return out


def monorail_win():
    out = np.zeros(int(SR * 1.7))
    for at, f, dur in ((0.0, 783.99, 0.2), (0.16, 783.99, 0.2), (0.32, 783.99, 0.2), (0.5, 1046.5, 1.2)):
        b = bell(f, dur + 0.4, 3.0 if dur < 1 else 1.6)
        i = int(at * SR)
        n = min(len(b), len(out) - i)
        out[i:i + n] += b[:n]
    return out


def write(path, x):
    x = x / (np.abs(x).max() + 1e-9) * 0.9
    fade = int(SR * 0.02)
    x[-fade:] *= np.linspace(1, 0, fade)
    pcm = (np.stack([x, x], axis=1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print("SYNTH", path, f"{len(x) / SR:.2f}s")


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "assets" / "audio" / "set_pieces" / "raw"
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in (("cannon_fuse", fuse), ("cannon_boom_mix", boom), ("slide_whistle", slide_whistle),
                     ("dizzy_tweets", tweets), ("retire_poof", poof), ("monorail_win", monorail_win)):
        write(out / f"{name}.wav", fn())


if __name__ == "__main__":
    main()
