#!/usr/bin/env python3
"""Horn-answer cues synthesised in code (docs/REMARKABLE.md item 10; original, licence-free, no samples):
  ans_foghorn  two detuned 73 Hz saws, 4-pole low-pass at 400 Hz, 1.6 s swell and decay with a small pitch sag at the
               tail, over a rigging rattle (band-passed wooden clicks thinning out)
  ans_cuckoo   two cuckoo calls (E5 then C5, 0.22 s each, a breathy chiff on every note), the second call a beat later
  ans_chime    a two-tone station bell, G5 then E5 (inharmonic bell partials, long ring)
  ans_puff     a soft chimney "pff-pop" (low noise breath and a round thump) for the smoke ring
Writes 44.1 kHz WAVs into <out_dir> (default assets/audio/world_moments/raw); prep_audio.py makes the .ogg files.
Usage: synth_world_moments.py [out_dir]"""
import sys
import wave
from pathlib import Path

import numpy as np

SR = 44100
rng = np.random.default_rng(20261018)


def t_axis(sec):
    return np.arange(int(SR * sec)) / SR


def lowpass(x, fc, order=4):
    f = np.fft.rfftfreq(len(x), 1 / SR)
    return np.fft.irfft(np.fft.rfft(x) / np.sqrt(1 + (f / fc) ** (2 * order)), len(x))


def bandpass(x, lo, hi):
    f = np.fft.rfftfreq(len(x), 1 / SR)
    g = 1 / np.sqrt(1 + (f / hi) ** 8) * (1 - 1 / np.sqrt(1 + (f / lo) ** 8))
    return np.fft.irfft(np.fft.rfft(x) * g, len(x))


def saw(freq_curve):
    phase = np.cumsum(freq_curve) / SR
    return 2 * (phase % 1.0) - 1


def foghorn():
    dur = 2.0
    t = t_axis(dur)
    sag = 1 - 0.035 * np.clip((t - 1.2) / 0.6, 0, 1) ** 2  # the horn runs out of breath at the end
    x = saw(73.0 * sag) + saw(73.0 * 1.012 * sag) + 0.5 * saw(146.4 * sag)
    x = lowpass(x, 400)
    env = np.clip(t / 0.28, 0, 1) ** 1.5 * np.where(t < 1.25, 1, np.exp(-(t - 1.25) * 4.5))
    horn = x * env
    # rigging rattle: short wooden knocks, dense at first and thinning out
    rattle = np.zeros_like(t)
    k = int(SR * 0.025)
    click_env = np.exp(-np.arange(k) / (SR * 0.004))
    at = 0.18
    while at < 1.4:
        i = int(at * SR)
        n = min(k, len(rattle) - i)
        rattle[i:i + n] += rng.uniform(0.4, 1.0) * click_env[:n] * rng.standard_normal(n)
        at += rng.uniform(0.03, 0.06) * (1 + 2.5 * (at - 0.18))
    rattle = bandpass(rattle, 900, 3800) * 0.55
    return horn / np.abs(horn).max() + rattle


def pipe_note(freq, dur):
    t = t_axis(dur)
    tone = np.sin(2 * np.pi * freq * t) + 0.18 * np.sin(4 * np.pi * freq * t) + 0.06 * np.sin(6 * np.pi * freq * t)
    env = np.clip(t / 0.015, 0, 1) * np.where(t < dur - 0.06, 1, np.clip((dur - t) / 0.06, 0, 1))
    chiff = bandpass(rng.standard_normal(len(t)), 2500, 7000) * np.exp(-t / 0.02) * 0.35
    return tone * env * 0.8 + chiff


def cuckoo():
    out = np.zeros(int(SR * 1.45))
    for start in (0.0, 0.62):
        for off, f in ((0.0, 659.25), (0.26, 523.25)):
            n = pipe_note(f, 0.22)
            i = int((start + off) * SR)
            out[i:i + len(n)] += n
    return out


def bell(freq, dur):
    t = t_axis(dur)
    partials = ((1.0, 1.0, 2.2), (2.0, 0.45, 3.0), (2.76, 0.3, 4.2), (5.4, 0.12, 7.0), (0.5, 0.25, 1.6))
    x = sum(a * np.sin(2 * np.pi * freq * r * t) * np.exp(-t * d) for r, a, d in partials)
    return x * np.clip(t / 0.003, 0, 1)


def chime():
    out = np.zeros(int(SR * 2.1))
    for at, f in ((0.0, 783.99), (0.42, 659.25)):
        b = bell(f, 1.6)
        i = int(at * SR)
        out[i:i + len(b)] += b
    return out


def puff():
    t = t_axis(0.6)
    breath = lowpass(rng.standard_normal(len(t)), 320) * np.clip(t / 0.03, 0, 1) * np.exp(-t / 0.12)
    thump = np.sin(2 * np.pi * (95 + 60 * np.exp(-t / 0.03)) * t) * np.exp(-t / 0.07)
    return breath * 2.5 + thump * 0.8


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
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "assets" / "audio" / "world_moments" / "raw"
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in (("ans_foghorn", foghorn), ("ans_cuckoo", cuckoo), ("ans_chime", chime), ("ans_puff", puff)):
        write(out / f"{name}.wav", fn())


if __name__ == "__main__":
    main()
