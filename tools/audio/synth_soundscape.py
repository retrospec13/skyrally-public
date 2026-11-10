#!/usr/bin/env python3
"""Soundscape cues synthesised in code (docs/REMARKABLE.md Batch 2 items 26 and 29). Original and licence-free: this
source is the record of how every sound was made (ASSETS section 7). Seeded (20261019), so a re-run is identical.

Engine loops are built so they loop with no seam by construction: every engine cycle, every whine and every noise band
is periodic in the loop length (circular FFT convolution and FFT-domain filtering), so a Looped Sound wraps with no
click and no crossfade smear. Each engine is a firing pattern (where each cylinder fires inside one engine cycle), a
per-cylinder level (real engines are never perfectly even: that unevenness is the "voice"), an exhaust pulse (damped
resonances plus a short noise crack, convolved with the firing train), combustion hiss gated by the firing, and for
some a whine (turbo, gears) or a propeller's blade pass.

  eng_car_low      local car, low band: 4-cylinder at 2400 rpm, warm exhaust, a little lope        (2.0 s loop)
  eng_car_high     local car, high band: the same engine at 4200 rpm, intake howl, gear whine     (2.0 s loop)
  eng_plane_low    local plane, low band: 7-cylinder radial at 1500 rpm, 2-blade prop beat        (2.0 s loop)
  eng_plane_high   local plane, high band: the radial at 2500 rpm, prop buzz and blade whistle     (2.0 s loop)
  eng_voice_putt   rival voice: bratty single-cylinder two-stroke kart, raspy, ring-ding         (2.0 s loop)
  eng_voice_twin   rival voice: lumpy V-twin (uneven firing, "potato" lope), deep and chesty     (2.0 s loop)
  eng_voice_turbo  rival voice: smooth inline-6 with a turbo whistle on top                       (2.0 s loop)
  eng_voice_prop   rival voice (planes): 5-cylinder radial with a 3-blade prop drone              (2.0 s loop)
  wind_rush        speed wind: pink noise in two slowly breathing bands                          (4.0 s loop)
  flyby_whoosh     a racer tearing past: noise band swept 2.6 kHz -> 420 Hz around a swell       (1.0 s)
  eng_backfire     lift-off backfire: pop, pop, crackle-crackle                                   (0.6 s)
  clock_tick       wooden game-show clock tick (2.9 / 4.6 kHz click on a 1.1 kHz block)          (0.12 s)
  clock_tock       the lower tock (2.1 / 3.3 kHz click on a 760 Hz block)                         (0.12 s)
  clock_last       last three seconds: a hard tick with a bright 1760 Hz ping                       (0.45 s)
  sfx_airhorn      the buzzer: two raspy reeds on G4, a squeal into pitch, then the can runs out and sputters (1.75 s)

Usage: synth_soundscape.py <out_dir> [cue ...]     (writes <out_dir>/<cue>.ogg, game-ready, loudness set per cue)"""
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prep_audio import SR, encode  # noqa: E402

SEED = 20261019


def rng_for(name: str) -> np.random.Generator:
    return np.random.default_rng(SEED + sum(ord(c) * (i + 1) for i, c in enumerate(name)))


# --------------------------------------------------------------------------------------------- circular building blocks

def circ_conv(x: np.ndarray, k: np.ndarray) -> np.ndarray:
    """Circular convolution of x (loop length) with kernel k (zero-padded): the pulse tails wrap past the loop end
    onto its head, so the loop has no seam."""
    n = len(x)
    kk = np.zeros(n)
    kk[: min(n, len(k))] = k[:n]
    return np.fft.irfft(np.fft.rfft(x) * np.fft.rfft(kk), n)


def band_mask(n: int, lo: float, hi: float, slope_oct: float = 0.6) -> np.ndarray:
    """Smooth band-pass gain over rfft bins (log-frequency raised-cosine shoulders, slope_oct octaves wide)."""
    f = np.fft.rfftfreq(n, 1 / SR)
    f = np.maximum(f, 1.0)
    lf = np.log2(f)
    g = np.ones_like(f)
    a, b = math.log2(lo), math.log2(hi)
    g = np.where(lf < a, np.cos(np.clip((a - lf) / slope_oct, 0, 1) * math.pi / 2) ** 2, g)
    g = np.where(lf > b, np.cos(np.clip((lf - b) / slope_oct, 0, 1) * math.pi / 2) ** 2, g)
    return g


def circ_band(x: np.ndarray, lo: float, hi: float, slope_oct: float = 0.6) -> np.ndarray:
    return np.fft.irfft(np.fft.rfft(x) * band_mask(len(x), lo, hi, slope_oct), len(x))


def pink(n: int, rng: np.random.Generator) -> np.ndarray:
    """Periodic pink noise (1/f power), built in the frequency domain so it loops."""
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / SR)
    spec[1:] /= np.sqrt(f[1:] / 100.0)
    spec[0] = 0
    y = np.fft.irfft(spec, n)
    return y / (np.abs(y).max() + 1e-9)


def periodic_lfo(n: int, rng: np.random.Generator, cycles=(1, 2, 3), depth: float = 1.0) -> np.ndarray:
    """A slow wobble made of whole cycles per loop (seamless)."""
    t = np.arange(n) / n
    out = np.zeros(n)
    for c in cycles:
        out += math.sin(rng.uniform(0, 2 * math.pi)) * 0 + np.sin(2 * math.pi * c * t + rng.uniform(0, 2 * math.pi)) / c
    return depth * out / (np.abs(out).max() + 1e-9)


def damped(freq: float, decay_s: float, length_s: float, phase: float = 0.0) -> np.ndarray:
    t = np.arange(int(SR * length_s)) / SR
    return np.sin(2 * math.pi * freq * t + phase) * np.exp(-t / decay_s)


# ------------------------------------------------------------------------------------------------------- engine core

def engine(name: str, seconds: float, rpm: float, strokes: int, firing: list, cyl_gain: list, resonances: list,
           crack: float, crack_hz: tuple, hiss: float, hiss_band: tuple, whine: list = (), prop: tuple | None = None,
           jitter_amp: float = 0.07, lope: float = 0.0, drive: float = 1.6, rms_db: float = -17.0) -> np.ndarray:
    """One seamless engine loop.
    rpm, strokes (2 or 4): one engine cycle = strokes/2 revolutions; the loop holds a whole number of cycles (rpm is
    nudged to fit). firing: fractions of a cycle where each cylinder fires; cyl_gain: per-cylinder level.
    resonances: [(hz, decay_s, gain)] exhaust pipe modes rung by every firing. crack: level of a 3 ms noise crack per
    firing (crack_hz band). hiss: combustion/intake noise gated by the firing, in hiss_band. whine: [(order, gain)]
    sines at order x the revolution rate (gears, turbo). prop: (blades, depth, buzz_gain) blade-pass modulation and a
    blade buzz. lope: slow per-cycle level wobble (a lumpy cam). drive: tanh grit."""
    rng = rng_for(name)
    n = int(SR * seconds)
    rev_hz = rpm / 60.0
    cycle_hz = rev_hz * 2 / strokes
    cycles = max(1, round(seconds * cycle_hz))
    cycle_hz = cycles / seconds
    rev_hz = cycle_hz * strokes / 2
    # Firing train: fractional-sample impulses, per-cylinder level, per-event jitter, a lope across cycles.
    train = np.zeros(n)
    lope_curve = periodic_lfo(cycles, rng, cycles=(1, 2), depth=1.0) if cycles >= 4 else np.zeros(cycles)
    for c in range(cycles):
        for cyl, frac in enumerate(firing):
            pos = (c + frac) / cycle_hz * SR
            pos += rng.normal(0, 0.0004 * SR / cycle_hz)  # tiny timing scatter: a real engine never fires on the grid
            amp = cyl_gain[cyl] * (1 + rng.normal(0, jitter_amp)) * (1 + lope * lope_curve[c])
            i = int(math.floor(pos)) % n
            w = pos - math.floor(pos)
            train[i] += amp * (1 - w)
            train[(i + 1) % n] += amp * w
    # Exhaust pulse: damped pipe modes plus a short noise crack.
    klen = 0.12
    kernel = np.zeros(int(SR * klen))
    for hz, dec, g in resonances:
        kernel += g * damped(hz, dec, klen, rng.uniform(0, math.pi))
    ck = np.zeros_like(kernel)
    cn = int(SR * 0.003)
    burst = rng.standard_normal(cn) * np.exp(-np.arange(cn) / (cn / 3))
    ck[:cn] = burst
    kernel += crack * ck
    body = circ_conv(train, kernel)
    body = body + circ_band(circ_conv(train, ck), *crack_hz) * crack * 0.6
    # Combustion / intake hiss gated by a smoothed firing envelope.
    env = circ_conv(np.abs(train), np.exp(-np.arange(int(SR * 0.012)) / (SR * 0.004)))
    env /= env.max() + 1e-9
    noise = circ_band(rng.standard_normal(n), *hiss_band)
    noise /= np.abs(noise).max() + 1e-9
    body = body / (np.abs(body).max() + 1e-9) + hiss * noise * (0.35 + 0.65 * env)
    t = np.arange(n) / SR
    for order, g in whine:
        f = round(order * rev_hz * seconds) / seconds  # whole cycles per loop
        body += g * np.sin(2 * math.pi * f * t) * (0.85 + 0.15 * env)
    if prop:
        blades, depth, buzz = prop
        bp = round(blades * rev_hz * seconds) / seconds
        beat = 0.5 + 0.5 * np.cos(2 * math.pi * bp * t)
        body *= (1 - depth) + depth * beat ** 2
        saw = sum(np.sin(2 * math.pi * k * bp * t) / k for k in range(1, 12))
        body += buzz * saw * (0.6 + 0.4 * beat)
    y = np.tanh(drive * body / (np.abs(body).max() + 1e-9)) / math.tanh(drive)
    y -= y.mean()
    return level(rotate_quiet(y), rms_db)


def rotate_quiet(y: np.ndarray) -> np.ndarray:
    """A periodic loop can start anywhere: start it on an upward zero crossing in its quietest 5 ms, so the file edge
    (where the Vorbis encoder is least exact) falls between firings and the wrap cannot click."""
    w = int(SR * 0.005)
    env = np.convolve(np.abs(np.concatenate([y, y[:w]])), np.ones(w) / w, "valid")[: len(y)]
    i = int(np.argmin(env))
    for j in range(i, i + w * 4):
        a, b = y[j % len(y)], y[(j + 1) % len(y)]
        if a <= 0 < b:
            i = (j + 1) % len(y)
            break
    return np.roll(y, -i)


def level(mono: np.ndarray, rms_db: float) -> np.ndarray:
    rms = float(np.sqrt(np.mean(mono ** 2)) + 1e-12)
    y = mono * (10 ** (rms_db / 20) / rms)
    peak = float(np.abs(y).max())
    if peak > 0.89:
        y = np.tanh(y / 0.89) * 0.89
    return y


# ------------------------------------------------------------------------------------------------------- the engines

def eng_car_low():
    return engine("eng_car_low", 2.0, 2400, 4, [0, 0.25, 0.5, 0.75], [1.0, 0.86, 0.95, 0.8],
                  [(118, 0.020, 1.0), (236, 0.010, 0.55), (610, 0.004, 0.35)], crack=0.25, crack_hz=(900, 3500),
                  hiss=0.10, hiss_band=(300, 1800), whine=[(6, 0.035)], lope=0.10, drive=1.8)


def eng_car_high():
    return engine("eng_car_high", 2.0, 4200, 4, [0, 0.25, 0.5, 0.75], [1.0, 0.9, 0.96, 0.86],
                  [(150, 0.014, 0.9), (420, 0.007, 0.7), (1150, 0.003, 0.45)], crack=0.4, crack_hz=(1500, 6000),
                  hiss=0.22, hiss_band=(700, 4200), whine=[(8, 0.06), (13, 0.03)], lope=0.04, drive=2.4)


def eng_plane_low():
    return engine("eng_plane_low", 2.0, 1500, 4, [i / 7 for i in (0, 2, 4, 6, 1, 3, 5)],
                  [1.0, 0.9, 0.97, 0.88, 0.95, 0.85, 0.92], [(95, 0.022, 1.0), (260, 0.010, 0.45), (700, 0.004, 0.2)],
                  crack=0.18, crack_hz=(800, 3000), hiss=0.12, hiss_band=(200, 1400), prop=(2, 0.55, 0.12),
                  lope=0.05, drive=1.6)


def eng_plane_high():
    return engine("eng_plane_high", 2.0, 2500, 4, [i / 7 for i in (0, 2, 4, 6, 1, 3, 5)],
                  [1.0, 0.92, 0.97, 0.9, 0.95, 0.88, 0.94], [(130, 0.016, 0.9), (380, 0.007, 0.6), (980, 0.003, 0.35)],
                  crack=0.3, crack_hz=(1200, 5000), hiss=0.24, hiss_band=(500, 5000), prop=(2, 0.45, 0.2),
                  whine=[(14, 0.03)], lope=0.02, drive=2.0)


def eng_voice_putt():
    # Single-cylinder two-stroke: one firing per revolution, 7800 rpm, a tinny expansion-chamber ring and lots of rasp.
    return engine("eng_voice_putt", 2.0, 7800, 2, [0], [1.0], [(260, 0.008, 1.0), (780, 0.004, 0.8), (1900, 0.002, 0.5)],
                  crack=0.6, crack_hz=(2000, 7000), hiss=0.3, hiss_band=(1200, 6000), jitter_amp=0.12, drive=3.0)


def eng_voice_twin():
    # 45-degree V-twin: fires at 0 and 405 degrees of a 720-degree cycle, so the gap is long-short ("potato").
    return engine("eng_voice_twin", 2.0, 1900, 4, [0, 405 / 720], [1.0, 0.82], [(70, 0.03, 1.0), (180, 0.012, 0.6),
                  (520, 0.004, 0.3)], crack=0.3, crack_hz=(700, 2800), hiss=0.08, hiss_band=(200, 1200),
                  jitter_amp=0.1, lope=0.18, drive=2.2)


def eng_voice_turbo():
    # Inline-6 (firing 1-5-3-6-2-4, even), smooth and quick, with a turbo whistle at a fixed high order.
    return engine("eng_voice_turbo", 2.0, 4800, 4, [0, 1 / 6, 2 / 6, 3 / 6, 4 / 6, 5 / 6], [1.0, 0.95, 0.97, 0.93, 0.98, 0.94],
                  [(170, 0.012, 0.8), (480, 0.006, 0.6), (1300, 0.003, 0.3)], crack=0.2, crack_hz=(1500, 5000),
                  hiss=0.18, hiss_band=(800, 5000), whine=[(46, 0.09), (23, 0.03)], jitter_amp=0.04, drive=1.5)


def eng_voice_prop():
    return engine("eng_voice_prop", 2.0, 2100, 4, [i / 5 for i in (0, 2, 4, 1, 3)], [1.0, 0.9, 0.95, 0.86, 0.93],
                  [(110, 0.018, 1.0), (330, 0.008, 0.5), (820, 0.003, 0.25)], crack=0.22, crack_hz=(1000, 4000),
                  hiss=0.16, hiss_band=(400, 3500), prop=(3, 0.5, 0.18), lope=0.04, drive=1.8)


def wind_rush():
    rng = rng_for("wind_rush")
    n = int(SR * 4.0)
    a = circ_band(pink(n, rng), 250, 900, 0.8)
    b = circ_band(pink(n, rng), 1200, 4000, 0.8)
    la = 0.6 + 0.4 * periodic_lfo(n, rng, cycles=(1, 3))
    lb = 0.5 + 0.5 * periodic_lfo(n, rng, cycles=(2, 5))
    y = a / np.abs(a).max() * la + 0.55 * b / np.abs(b).max() * lb
    return level(rotate_quiet(y - y.mean()), -20.0)


# --------------------------------------------------------------------------------------------------------- one-shots

def svf_bp(x: np.ndarray, centre: np.ndarray, q: float) -> np.ndarray:
    """Chamberlin state-variable band-pass with a per-sample centre (a sweeping whoosh)."""
    f = 2 * np.sin(np.pi * np.clip(centre, 30, SR / 6) / SR)
    damp = 1.0 / q
    low = band = 0.0
    y = np.empty_like(x)
    for i in range(len(x)):
        low += f[i] * band
        high = x[i] - low - damp * band
        band += f[i] * high
        y[i] = band
    return y


def flyby_whoosh():
    rng = rng_for("flyby_whoosh")
    n = int(SR * 1.0)
    t = np.arange(n) / SR
    peak = 0.34
    # Amplitude: an inverse-square-ish swell to the closest point, then a quicker fall (the car is already gone).
    d = np.where(t < peak, (peak - t) / peak, (t - peak) / (1 - peak) * 1.6)
    amp = 1 / (1 + 9 * d ** 2)
    centre = 420 + (2600 - 420) / (1 + np.exp((t - peak) / 0.06))  # high while it comes, low as it goes
    y = svf_bp(rng.standard_normal(n), centre, 2.2) * amp
    y += 0.4 * svf_bp(rng.standard_normal(n), centre * 2.1, 3.0) * amp ** 1.5
    fade = np.minimum(1, (1 - t) / 0.12)
    return level(y * fade, -15.0)


def eng_backfire():
    rng = rng_for("eng_backfire")
    n = int(SR * 0.6)
    y = np.zeros(n)

    def pop(at, gain, dur=0.03, thump_hz=110):
        i = int(at * SR)
        m = int(dur * SR)
        tt = np.arange(m) / SR
        burst = rng.standard_normal(m) * np.exp(-tt / (dur / 4))
        thump = np.sin(2 * math.pi * thump_hz * tt * (1 - tt * 4)) * np.exp(-tt / (dur / 2.5))
        seg = gain * (0.7 * burst + 1.0 * thump)
        y[i: i + m] += seg[: n - i]

    pop(0.0, 1.0, 0.035, 120)
    pop(0.13, 0.8, 0.03, 100)
    for k, at in enumerate((0.27, 0.31, 0.36, 0.40, 0.47)):  # the crackle tail
        pop(at + rng.uniform(-0.008, 0.008), 0.35 - 0.05 * k, 0.012, 300)
    y = np.tanh(2.2 * y / (np.abs(y).max() + 1e-9))
    return level(y, -16.0)


def clock_click(n: int, hi: tuple, body_hz: float, rng: np.random.Generator) -> np.ndarray:
    t = np.arange(n) / SR
    y = 0.9 * np.sin(2 * math.pi * hi[0] * t) * np.exp(-t / 0.006)
    y += 0.6 * np.sin(2 * math.pi * hi[1] * t) * np.exp(-t / 0.004)
    y += 1.0 * np.sin(2 * math.pi * body_hz * t) * np.exp(-t / 0.018)  # the hollow wooden block under the click
    m = int(SR * 0.0015)
    y[:m] += rng.standard_normal(m) * 0.8
    return y


def clock_tick():
    return level(clock_click(int(SR * 0.12), (2900, 4600), 1100, rng_for("clock_tick")), -14.0)


def clock_tock():
    return level(clock_click(int(SR * 0.12), (2100, 3300), 760, rng_for("clock_tock")), -14.0)


def clock_last():
    n = int(SR * 0.45)
    t = np.arange(n) / SR
    y = 1.3 * clock_click(n, (3200, 5100), 1250, rng_for("clock_last"))
    ping = np.sin(2 * math.pi * 1760 * t) + 0.35 * np.sin(2 * math.pi * 1760 * 2.76 * t) * np.exp(-t / 0.05)
    y += 0.55 * ping * np.exp(-t / 0.14) * np.minimum(1, t / 0.002)
    return level(y, -13.0)


def sfx_airhorn():
    """The buzzer (generated takes were unusable: a 0.3 s blip and then silence). A handheld stadium horn is one harsh
    reed note: two reeds 12 cents apart (the beating gives it the rasp), all harmonics with a brassy bump at 1.1-2.6 kHz
    from the bell, a squeal up into pitch, a 1.25 s blast, then the can runs out of puff: the pitch sags three semitones
    and the tone sputters for a quarter second (the comic bit)."""
    n = int(SR * 1.75)
    t = np.arange(n) / SR
    f0 = 392.0  # G4
    hold = 1.3
    sag = np.where(t > hold, -3 * np.clip((t - hold) / 0.3, 0, 1) ** 1.5, 0.0)
    scoop = -1.2 * np.exp(-t / 0.04)
    semis = sag + scoop
    y = np.zeros(n)
    for detune, g in ((0.0, 1.0), (12.0, 0.8)):
        f = f0 * 2 ** ((semis + detune / 100) / 12)
        ph = 2 * math.pi * np.cumsum(f) / SR
        for k in range(1, 30):
            hk = np.clip((9000 - k * f) / 1500, 0, 1)
            y += g * hk * np.sin(k * ph) / k ** 0.55
    spec = np.fft.rfft(y)
    fr = np.fft.rfftfreq(n, 1 / SR)
    bell = 1 + 1.6 * np.exp(-((np.log2(np.maximum(fr, 1)) - math.log2(1700)) / 0.6) ** 2)
    spec *= bell * band_mask(n, 300, 7000, 0.7)
    y = np.fft.irfft(spec, n)
    sputter = np.where(t > hold + 0.08, 0.55 + 0.45 * np.sign(np.sin(2 * math.pi * 17 * t)), 1.0)
    env = np.minimum(1, t / 0.02) * sputter * np.clip((1.75 - t) / 0.12, 0, 1)
    y = np.tanh(2.6 * y / np.abs(y).max()) * env
    return level(y, -12.0)


RECIPES = {
    "eng_car_low": eng_car_low,
    "eng_car_high": eng_car_high,
    "eng_plane_low": eng_plane_low,
    "eng_plane_high": eng_plane_high,
    "eng_voice_putt": eng_voice_putt,
    "eng_voice_twin": eng_voice_twin,
    "eng_voice_turbo": eng_voice_turbo,
    "eng_voice_prop": eng_voice_prop,
    "wind_rush": wind_rush,
    "flyby_whoosh": flyby_whoosh,
    "eng_backfire": eng_backfire,
    "clock_tick": clock_tick,
    "clock_tock": clock_tock,
    "clock_last": clock_last,
    "sfx_airhorn": sfx_airhorn,
}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    want = sys.argv[2:] or list(RECIPES)
    for name in want:
        mono = RECIPES[name]().astype(np.float32)
        encode(np.stack([mono, mono], axis=1), out / f"{name}.ogg")
        print(f"SYNTH {name} seconds={len(mono) / SR:.2f} rms_db={20 * np.log10(np.sqrt(np.mean(mono ** 2)) + 1e-9):.1f}")


if __name__ == "__main__":
    main()
