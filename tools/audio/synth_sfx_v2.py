#!/usr/bin/env python3
"""SFX coverage pass (sfx_v2): the gameplay sounds the game had silent, or covered with an unrelated sample, plus
replacements for the three crude 2026-10-18 procedural WAVs (boost whoosh, crash thud, lap fanfare). Original sounds
synthesised in code (numpy + scipy), no samples and no external model, so there is no licence to carry. This file is the
record of how every sound was made; the table is in assets/audio/sfx_v2/README.md. Seeded per role: a re-run is identical.

Technique (why they should not sound like beeps): every sound is several layers (a low-frequency body, a mid "meat"
layer, a bright transient or sparkle), each with its own exponential envelope and a raised-cosine attack so nothing
clicks; noise layers go through swept resonant filters (moving centre frequency = movement); pitched layers glide and
carry inharmonic partials (bells, metal) or detuned harmonics (brass, synth); everything is lightly saturated (tanh)
for density, and the pitched / magic ones get a short synthetic room (noise-IR convolution) for space. 2D cues are
stereo (decorrelated noise per channel); 3D cues are written mono (Roblox spatialises them). Loops are periodic by
construction (integer cycles, circular FFT filtering) or equal-power crossfaded.

Usage: synth_sfx_v2.py <out_dir> [role ...]     writes <out_dir>/<role>.ogg (game-ready) and <out_dir>/measure.json
Needs: numpy, scipy, imageio-ffmpeg (the repo's other audio tools use the same ffmpeg)."""
import json
import math
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

import numpy as np
from scipy.signal import butter, fftconvolve, lfilter, sosfilt

SR = 44100
RNG = np.random.default_rng(1)


def seed(role):
    global RNG
    RNG = np.random.default_rng(zlib.crc32(role.encode()) ^ 20261019)


# ---------------------------------------------------------------------------------------------------- primitives
def T(sec):
    return np.arange(int(round(sec * SR))) / SR


def dec(t, tau):
    return np.exp(-t / tau)


def rc_attack(n, ms):
    """Raised-cosine fade-in over `ms` (never a click)."""
    a = max(1, int(SR * ms / 1000))
    env = np.ones(n)
    a = min(a, n)
    env[:a] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    return env


def rc_release(n, ms):
    a = max(1, int(SR * ms / 1000))
    env = np.ones(n)
    a = min(a, n)
    env[n - a:] = 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, a))
    return env


def noise(n, ch=2):
    return RNG.standard_normal((n, ch)) if ch > 1 else RNG.standard_normal(n)


def pink(n, ch=2):
    out = []
    for _ in range(ch):
        spec = np.fft.rfft(RNG.standard_normal(n))
        f = np.maximum(np.arange(len(spec)), 1)
        out.append(np.fft.irfft(spec / np.sqrt(f), n))
    y = np.stack(out, axis=1)
    return y / (np.abs(y).max() + 1e-9) * 3.0


def sos_filter(x, kind, fc, order=2):
    fc = float(np.clip(fc, 20, SR * 0.45))
    if kind == "bp":  # fc = centre; about +-0.6 octave
        wn = [fc / 1.5 / (SR / 2), min(fc * 1.5, SR * 0.47) / (SR / 2)]
    else:
        wn = fc / (SR / 2)
    sos = butter(order, wn, btype={"lp": "low", "hp": "high", "bp": "band"}[kind], output="sos")
    return sosfilt(sos, x, axis=0)


def _biquad(kind, f, q):
    w0 = 2 * math.pi * min(max(f, 20.0), SR * 0.45) / SR
    cw, sw = math.cos(w0), math.sin(w0)
    al = sw / (2 * q)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
    elif kind == "hp":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
    else:  # bp, constant 0 dB peak
        b = [al, 0.0, -al]
    a = [1 + al, -2 * cw, 1 - al]
    return np.array(b) / a[0], np.array(a) / a[0]


def tv(x, kind, fc, q=0.9, block=32):
    """Time-varying resonant biquad (fc: scalar or per-sample array), state carried across blocks. x: (n,) or (n, ch)."""
    n = len(x)
    fcs = np.broadcast_to(np.asarray(fc, dtype=np.float64), (n,))
    y = np.empty_like(x, dtype=np.float64)
    zi = np.zeros((2,) + x.shape[1:])
    for s in range(0, n, block):
        e = min(n, s + block)
        b, a = _biquad(kind, float(fcs[(s + e) // 2]), q)
        y[s:e], zi = lfilter(b, a, x[s:e], axis=0, zi=zi)
    return y


def glide(f0, f1, t, dur, curve="exp"):
    k = np.clip(t / dur, 0, 1)
    if curve == "exp":
        return f0 * (f1 / f0) ** k
    return f0 + (f1 - f0) * k


def phase(freq):
    return 2 * np.pi * np.cumsum(freq) / SR


def harm(ph, n=8, rolloff=1.0, odd=False):
    """Band-limited-ish harmonic stack of a phase array (saw-like, or odd-only square-like)."""
    y = np.zeros_like(ph)
    for k in range(1, n + 1):
        if odd and k % 2 == 0:
            continue
        y += np.sin(k * ph) / (k ** rolloff)
    return y


def saw(freq, n=10):
    return harm(phase(freq), n, 1.0) * 0.6


def bell_partials(f, t, tau, partials=((1, 1.0, 1.0), (2.76, 0.45, 0.55), (5.4, 0.22, 0.3), (8.93, 0.1, 0.18))):
    y = np.zeros_like(t)
    for ratio, g, tr in partials:
        if f * ratio < SR * 0.45:
            y += g * np.sin(2 * np.pi * f * ratio * t) * np.exp(-t / (tau * tr))
    return y * rc_attack(len(t), 0.8)


def marimba(f, dur=0.6, tau=0.16):
    t = T(dur)
    y = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * 4 * f * t) * np.exp(-t / 0.03) + 0.08 * np.sin(2 * np.pi * 9.2 * f * t) * np.exp(-t / 0.01)
    return y * dec(t, tau) * rc_attack(len(t), 1.5)


def sat(x, drive=1.5):
    return np.tanh(x * drive) / math.tanh(drive)


def place(dst, src, at):
    i = int(round(SR * at))
    if i >= len(dst):
        return
    e = min(len(dst), i + len(src))
    seg = src[: e - i]
    rel = rc_release(len(seg), min(25.0, 1000.0 * len(seg) / SR / 4))  # a finite layer never ends on a step
    dst[i:e] += seg * (rel[:, None] if seg.ndim == 2 else rel)


def m2(x):
    """mono layer -> stereo"""
    return np.stack([x, x], axis=1)


def pan(x, p):
    return np.stack([x * math.cos(p * math.pi / 2), x * math.sin(p * math.pi / 2)], axis=1)


def reverb(x, rt60=0.4, wet=0.15, predelay=0.006, damp=5500):
    """Small synthetic room: decorrelated noise IRs per channel, low-passed, mixed in parallel."""
    n = int(SR * rt60 * 1.1)
    t = np.arange(n) / SR
    ir = np.stack([RNG.standard_normal(n), RNG.standard_normal(n)], axis=1) * np.exp(-6.9 * t / rt60)[:, None]
    ir = sos_filter(ir, "lp", damp, 2)
    ir[: int(SR * 0.002)] *= np.linspace(0, 1, int(SR * 0.002))[:, None]
    ir = np.concatenate([np.zeros((int(SR * predelay), 2)), ir])
    ir /= np.sqrt((ir ** 2).sum()) + 1e-9
    if x.ndim == 1:
        x = m2(x)
    w = np.stack([fftconvolve(x[:, c], ir[:, c])[: len(x)] for c in range(2)], axis=1)
    return x + wet * w * 3.0


def sparkle(n_total, times, freqs, gain=0.2, tau=0.12, bellish=True):
    out = np.zeros(n_total)
    for at, f in zip(times, freqs):
        t = T(min(0.6, tau * 6))
        s = bell_partials(f, t, tau) if bellish else np.sin(2 * np.pi * f * t) * dec(t, tau)
        place(out, s * gain, at)
    return out


def circ_noise(n, lo, hi, ch=2, slope=0.0):
    """Seamlessly periodic band-limited noise (FFT-domain filter): loops with no seam by construction."""
    out = []
    for _ in range(ch):
        spec = np.fft.rfft(RNG.standard_normal(n))
        f = np.fft.rfftfreq(n, 1 / SR)
        win = np.zeros_like(f)
        band = (f >= lo) & (f <= hi)
        win[band] = 1.0
        # soft edges (one octave of raised-cosine roll-off each side)
        lo_e = (f < lo) & (f > lo / 2)
        win[lo_e] = 0.5 - 0.5 * np.cos(np.pi * (np.log2(f[lo_e]) - np.log2(lo / 2)))
        hi_e = (f > hi) & (f < hi * 2)
        win[hi_e] = 0.5 + 0.5 * np.cos(np.pi * (np.log2(f[hi_e]) - np.log2(hi)))
        if slope:
            win = win / np.maximum(f, 1.0) ** slope
        out.append(np.fft.irfft(spec * win, n))
    y = np.stack(out, axis=1)
    return y / (np.sqrt((y ** 2).mean()) + 1e-9)


def band(x, lo, hi, order=2):
    sos = butter(order, [lo / (SR / 2), hi / (SR / 2)], btype="band", output="sos")
    return sosfilt(sos, x, axis=0)


def exciter(x, amount=0.9):
    """Phone speakers cannot play < 150 Hz: add 2nd/3rd harmonics of the 40-220 Hz band (psychoacoustic bass) so a boom
    still reads on a handset, then drop the sub that only eats headroom."""
    low = band(x, 40, 220)
    ex = sat(low * 3.0, 2.5)
    ex = sos_filter(ex, "hp", 150, 2)
    y = x + ex * amount
    return sos_filter(y, "hp", 45, 2)


# ---------------------------------------------------------------------------------------------------- mastering
def master(x, rms_db=-16.0, ceil_db=-2.0, fade_ms=12, trim=True, loop=False, mono=False, bass=False):
    x = np.asarray(x, dtype=np.float64)
    if x.ndim == 1:
        x = m2(x)
    x = x - x.mean(axis=0)  # no DC
    if not loop:
        x = sos_filter(x, "hp", 24.0, 2)  # a loop must stay periodic: no start-up transient
    if trim and not loop:
        lv = np.abs(x).max(axis=1)
        on = np.where(lv > 10 ** (-60 / 20) * lv.max())[0]
        x = x[on[0]: on[-1] + 1]
        n = len(x)
        x = x * (rc_attack(n, 1.0) * rc_release(n, fade_ms))[:, None]
    if bass:
        x = exciter(x)
    if mono:
        x = np.repeat(x.mean(axis=1, keepdims=True), 2, axis=1)
    rms = math.sqrt((x ** 2).mean()) + 1e-12
    x = x * (10 ** (rms_db / 20) / rms)
    # look-ahead peak limiter down to the ceiling (smooth gain reduction, never hard clipping)
    ceil = 10 ** (ceil_db / 20)
    env = np.abs(x).max(axis=1)
    k = int(SR * 0.004)
    from scipy.ndimage import maximum_filter1d, uniform_filter1d
    env = maximum_filter1d(env, size=2 * k + 1)
    g = np.minimum(1.0, ceil / np.maximum(env, 1e-9))
    g = uniform_filter1d(g, size=2 * k + 1, mode="nearest")
    g = np.minimum(g, np.minimum(1.0, ceil / np.maximum(np.abs(x).max(axis=1), 1e-9)))
    x = x * g[:, None]
    return x.astype(np.float32)


def make_loop(x, xfade=0.15):
    """Equal-power crossfade of the tail onto the head: the Looped Sound wraps with no seam."""
    L = int(SR * xfade)
    n = len(x)
    head, tail = x[:L], x[n - L:]
    t = np.linspace(0, 1, L)[:, None]
    y = x[: n - L].copy()
    y[:L] = head * np.sin(t * np.pi / 2) + tail * np.cos(t * np.pi / 2)
    return y


def encode(x, path, mono=False):
    with tempfile.NamedTemporaryFile(suffix=".f32") as f:
        f.write(np.ascontiguousarray(x, dtype=np.float32).tobytes())
        f.flush()
        import imageio_ffmpeg
        cmd = [imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-y", "-f", "f32le", "-ac", "2", "-ar", str(SR), "-i", f.name]
        if mono:
            cmd += ["-ac", "1"]
        subprocess.run(cmd + ["-c:a", "libvorbis", "-q:a", "5", str(path)], check=True)


# ---------------------------------------------------------------------------------------------------- the sounds
# Every builder returns raw (n,2) audio; ROLES below says how to master it.

def boost_kick():
    """BOOST! (pad, ring, item boost, drift release): thump + rising turbine + swept air whoosh + sparkle, 0.95 s."""
    n = int(SR * 0.95)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    # air whoosh: resonant band sweeping up fast then bleeding away
    fc = np.where(t < 0.2, glide(260, 4200, t, 0.2), glide(4200, 700, t - 0.2, 0.7))
    w = tv(noise(n), "bp", fc, q=1.3)
    w *= (rc_attack(n, 6) * np.where(t < 0.14, t / 0.14, dec(t - 0.14, 0.26)))[:, None]
    out += w * 1.5
    # hiss on top of the whoosh
    h = sos_filter(noise(n), "hp", 5200, 2) * (dec(t, 0.12) * rc_attack(n, 2))[:, None]
    out += h * 0.35
    # body thump: pitch-dropping sine + short click
    th = np.sin(phase(glide(135, 46, t, 0.2))) * dec(t, 0.1) * rc_attack(n, 1.5)
    out += m2(th) * 1.2
    out += m2(sos_filter(RNG.standard_normal(n), "lp", 900, 2) * dec(t, 0.012)) * 0.8
    # turbine: detuned saw stack climbing, filter opening, then the pitch settles
    tf = np.where(t < 0.38, glide(170, 760, t, 0.38), 760 * np.exp(-(t - 0.38) * 1.2))
    sw = saw(tf, 10) + saw(tf * 1.006, 10)
    sw = tv(sw, "lp", glide(420, 6500, t, 0.35), q=1.4)
    sw *= rc_attack(n, 18) * np.where(t < 0.34, 1.0, dec(t - 0.34, 0.16))
    out += pan(sw, 0.5) * 0.28
    # cartoon sparkle: two bell notes + a quick glide
    sp = sparkle(n, [0.05, 0.1], [2093.0, 3136.0], 0.2, 0.2)
    out += m2(sp)
    return reverb(out, 0.35, 0.10)


def boost_overcharge():
    """OVERCHARGE: the same hit but bigger: double thump, crackle, a higher turbine and a three-note sparkle, 1.15 s."""
    n = int(SR * 1.15)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    fc = np.where(t < 0.26, glide(200, 6000, t, 0.26), glide(6000, 900, t - 0.26, 0.85))
    w = tv(noise(n), "bp", fc, q=1.1)
    w *= (rc_attack(n, 5) * np.where(t < 0.18, t / 0.18, dec(t - 0.18, 0.3)))[:, None]
    out += w * 1.7
    for at, g in ((0.0, 1.3), (0.13, 0.9)):
        tt = np.arange(n - int(SR * at)) / SR
        th = np.sin(phase(glide(150, 42, tt, 0.22))) * dec(tt, 0.11) * rc_attack(len(tt), 1.5)
        place(out, m2(th) * g, at)
    out += m2(sos_filter(RNG.standard_normal(n), "lp", 1100, 2) * dec(t, 0.015)) * 0.9
    tf = np.where(t < 0.5, glide(190, 1250, t, 0.5), 1250 * np.exp(-(t - 0.5) * 1.5))
    sw = saw(tf, 12) + saw(tf * 1.008, 12) + 0.5 * saw(tf * 0.5, 8)
    sw = tv(sw, "lp", glide(500, 9000, t, 0.45), q=1.6)
    sw *= rc_attack(n, 14) * np.where(t < 0.46, 1.0, dec(t - 0.46, 0.2))
    out += pan(sw, 0.5) * 0.3
    # electrical crackle: sparse clicks through a bright band-pass, thinning out
    cr = np.zeros(n)
    k = int(SR * 0.55)
    idx = RNG.choice(k, 70, replace=False)
    cr[idx] = RNG.uniform(-1, 1, 70) * np.linspace(1, 0.1, 70)[np.argsort(idx)]
    cr = tv(cr, "bp", 4300, q=1.2)
    out += m2(cr) * 1.1
    sp = sparkle(n, [0.06, 0.12, 0.18, 0.26], [2093.0, 2637.0, 3136.0, 4186.0], 0.2, 0.25)
    out += m2(sp)
    return reverb(out, 0.45, 0.12)


def boost_loop():
    """While boosting: nozzle roar, 1.5 s loop. Periodic by construction (circular noise, integer-Hz flutter)."""
    n = int(SR * 1.5)
    t = np.arange(n) / SR
    body = circ_noise(n, 300, 2600)
    flutter = 1 + 0.28 * np.sin(2 * np.pi * 22 * t) + 0.1 * np.sin(2 * np.pi * 46 * t + 1.0)  # 33/69 cycles in 1.5 s: integer
    air = circ_noise(n, 3200, 9000) * 0.25
    rum = circ_noise(n, 55, 200) * 0.9
    tone = m2(np.sin(2 * np.pi * 112 * t) * 0.25 + np.sin(2 * np.pi * 224 * t + 0.6) * 0.1)
    return body * flutter[:, None] * 0.8 + air + rum + tone


def ring_pass():
    """Boost ring: airy pass-through whoosh and a three-note magic glissando, 0.85 s."""
    n = int(SR * 0.85)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    fc = np.where(t < 0.16, glide(700, 3400, t, 0.16), glide(3400, 1100, t - 0.16, 0.5))
    w = tv(noise(n), "bp", fc, q=1.8)
    w *= (np.sin(np.pi * np.clip(t / 0.5, 0, 1)) ** 2 * rc_attack(n, 4))[:, None]
    out += w * 1.2
    for i, f in enumerate((1046.5, 1318.5, 1568.0, 2093.0)):
        b = bell_partials(f, T(0.7), 0.3)
        place(out, pan(b, 0.35 + 0.1 * i) * 0.45, 0.03 + i * 0.05)
    place(out, m2(np.sin(phase(glide(300, 900, T(0.12), 0.1))) * dec(T(0.12), 0.05)) * 0.3, 0.0)
    return reverb(out, 0.5, 0.18)


def pad_zip():
    """Ground boost pad: a fast 'zzzip' sweep with a snap, 0.5 s."""
    n = int(SR * 0.5)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    f = glide(280, 2600, t, 0.16)
    z = saw(f, 12) + 0.7 * saw(f * 1.5, 8)
    z = tv(z, "lp", glide(500, 7000, t, 0.16), q=2.0)
    z *= rc_attack(n, 4) * np.where(t < 0.17, 1.0, dec(t - 0.17, 0.05))
    out += pan(z, 0.5) * 0.7
    sw = tv(noise(n), "bp", glide(900, 7500, t, 0.2), q=1.4) * (rc_attack(n, 3) * np.where(t < 0.18, 1, dec(t - 0.18, 0.08)))[:, None]
    out += sw * 0.9
    out += m2(np.sin(phase(glide(160, 70, t, 0.12))) * dec(t, 0.07)) * 0.6
    sn = np.zeros(n)
    place(sn, bell_partials(3136, T(0.35), 0.12) * 0.25, 0.15)
    out += m2(sn)
    return reverb(out, 0.25, 0.08)


def pod_pickup():
    """Item pod / pickup (replaces the pitched boost whoosh): a bubble 'bloop' into a bright marimba ding, 0.55 s."""
    n = int(SR * 0.55)
    out = np.zeros((n, 2))
    tb = T(0.14)
    bl = np.sin(phase(glide(420, 1250, tb, 0.09))) * dec(tb, 0.05) * rc_attack(len(tb), 1.5)
    place(out, pan(bl, 0.45) * 0.9, 0.0)
    place(out, pan(marimba(1318.5, 0.5, 0.12), 0.55) * 0.7, 0.045)
    place(out, pan(marimba(1975.5, 0.45, 0.1), 0.45) * 0.45, 0.08)
    place(out, pan(bell_partials(3951.0, T(0.4), 0.14), 0.6) * 0.18, 0.09)
    return reverb(out, 0.3, 0.10)


def pod_pop():
    """Item balloon pops (3D): rubber snap, thump, deflating flutter and a few confetti ticks, 0.4 s."""
    n = int(SR * 0.4)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    snap = sos_filter(noise(n), "hp", 400, 2) * (dec(t, 0.012) * rc_attack(n, 0.3))[:, None]
    out += snap * 1.7
    out += m2(np.sin(phase(glide(210, 85, t, 0.05))) * dec(t, 0.035)) * 1.0
    fl = tv(noise(n), "bp", glide(2600, 1100, t, 0.18), q=2.5) * (dec(t, 0.07) * (0.6 + 0.4 * np.sin(2 * np.pi * 70 * t)))[:, None]
    out += fl * 0.9
    ticks = np.zeros(n)
    for _ in range(9):
        at = RNG.uniform(0.04, 0.3)
        f = RNG.uniform(3500, 8000)
        tt = T(0.025)
        place(ticks, np.sin(2 * np.pi * f * tt) * dec(tt, 0.006) * RNG.uniform(0.2, 0.5) * (1 - at), at)
    out += pan(ticks, 0.5)
    return out


def countdown_v2():
    """3-2-1-GO, drop-in for jingle_countdown (same 4.2 s timing: pips at 0, 1, 2 s, GO at 3 s)."""
    n = int(SR * 4.2)
    out = np.zeros((n, 2))
    for k in range(3):
        tt = T(0.42)
        f = 784.0
        s = (np.sin(2 * np.pi * f * tt) + 0.28 * np.sin(4 * np.pi * f * tt) * dec(tt, 0.05)) * dec(tt, 0.085)
        s = s + 0.2 * bell_partials(f * 2.0, tt, 0.18)
        s = s * rc_attack(len(tt), 2.0)
        click = sos_filter(RNG.standard_normal(len(tt)), "bp", 3000, 2) * dec(tt, 0.004) * 0.35
        thump = np.sin(2 * np.pi * 98 * tt) * dec(tt, 0.05) * 0.5
        place(out, pan(s + click + thump, 0.5) * 0.75, k * 1.0)
    # GO at 3.0: whoosh up into a bright major stab (C6 E6 G6 C7 over C4 G4) with a shimmer tail
    tg = T(1.15)
    g = np.zeros(len(tg))
    for f, gain in ((261.63, 0.5), (392.0, 0.45), (523.25, 0.45), (1046.5, 0.5), (1318.5, 0.45), (1568.0, 0.4), (2093.0, 0.25)):
        g += gain * (saw(np.full(len(tg), f), 6) + saw(np.full(len(tg), f * 1.004), 6))
    g = tv(g, "lp", np.where(tg < 0.12, glide(1200, 9000, tg, 0.12), 9000 * np.exp(-(tg - 0.12) * 1.6)), q=1.0)
    g *= rc_attack(len(tg), 3) * (0.55 + 0.45 * dec(tg, 0.25)) * dec(tg, 0.55)
    place(out, pan(g, 0.5) * 0.9, 3.0)
    sw = tv(noise(len(tg)), "bp", np.where(tg < 0.3, glide(500, 6000, tg, 0.3), 6000.0), q=1.2) * (np.sin(np.pi * np.clip(tg / 0.5, 0, 1)) * dec(tg, 0.4) * rc_attack(len(tg), 3))[:, None]
    place(out, sw * 1.2, 2.9)
    place(out, m2(np.sin(phase(glide(190, 70, tg, 0.2))) * dec(tg, 0.12)) * 1.3, 3.0)
    sp = sparkle(n, [3.02, 3.07, 3.12, 3.18], [3136.0, 3951.0, 4699.0, 6272.0], 0.17, 0.25)
    out += m2(sp)
    return reverb(out, 0.6, 0.10)


def lap_ding():
    """Lap complete (replaces LapFanfare for laps): marimba arpeggio G5-B5-D6-G6 and a bell, 1.1 s."""
    n = int(SR * 1.1)
    out = np.zeros((n, 2))
    for i, f in enumerate((783.99, 987.77, 1174.66, 1567.98)):
        place(out, pan(marimba(f, 0.7, 0.2), 0.35 + 0.1 * i) * 0.6, i * 0.065)
        place(out, pan(bell_partials(f * 2, T(0.7), 0.25), 0.6 - 0.08 * i) * 0.17, i * 0.065 + 0.01)
    chord = np.zeros(n)
    tt = T(0.9)
    for f in (392.0, 587.33, 783.99):
        chord_part = (saw(np.full(len(tt), f), 6) + saw(np.full(len(tt), f * 1.005), 6)) * 0.3
        chord_part = tv(chord_part, "lp", 2400, q=0.8) * rc_attack(len(tt), 20) * np.exp(-tt / 0.35)
        place(chord, chord_part, 0.2)
    out += m2(chord) * 0.5
    return reverb(out, 0.55, 0.13)


def finish_tada():
    """Race finished / award landed (replaces LapFanfare for finishes): two brass hits, cymbal swell and glock run, 1.9 s."""
    n = int(SR * 1.9)
    out = np.zeros((n, 2))

    def brass(freqs, dur, at, gain, attack_ms=10, cut0=900, cut1=4200, tau=None):
        tt = T(dur)
        s = np.zeros(len(tt))
        for f in freqs:
            s += saw(np.full(len(tt), f), 9) + saw(np.full(len(tt), f * 1.005), 9) + saw(np.full(len(tt), f * 0.995), 9)
        s = tv(s, "lp", glide(cut0, cut1, tt, min(0.18, dur)), q=1.1)
        env = rc_attack(len(tt), attack_ms) * (np.exp(-tt / tau) if tau else rc_release(len(tt), 120))
        place(out, pan(s * env, 0.5) * gain, at)

    brass((196.0, 246.94, 293.66), 0.2, 0.0, 0.2, 8, tau=0.1)       # G major stab
    brass((196.0, 261.63, 329.63, 392.0, 523.25), 1.5, 0.22, 0.22, 12, 800, 5200, tau=0.65)  # held C major
    cy = sos_filter(noise(int(SR * 1.65)), "hp", 6000, 2) * (dec(T(1.65), 0.33) * rc_attack(int(SR * 1.65), 3))[:, None]
    place(out, cy * 0.22, 0.22)
    place(out, m2(np.sin(phase(glide(120, 45, T(0.3), 0.25))) * dec(T(0.3), 0.12)) * 1.0, 0.22)
    sp = sparkle(n, [0.3, 0.36, 0.42, 0.48, 0.56], [1046.5, 1318.5, 1568.0, 2093.0, 2637.0], 0.2, 0.3)
    out += m2(sp)
    return reverb(out, 0.8, 0.14)


def place_up():
    """Gained a place (HUD ping): two quick rising marimba pips, 0.2 s."""
    n = int(SR * 0.22)
    out = np.zeros((n, 2))
    place(out, pan(marimba(1046.5, 0.2, 0.05), 0.4), 0.0)
    place(out, pan(marimba(1568.0, 0.2, 0.06), 0.6), 0.055)
    place(out, pan(bell_partials(3136.0, T(0.18), 0.05), 0.55) * 0.15, 0.055)
    return out


def place_down():
    """Lost a place: a soft falling 'bwoop', 0.22 s (quieter and rounder than place_up so it informs, not scolds)."""
    n = int(SR * 0.24)
    t = np.arange(n) / SR
    f = glide(660, 380, t, 0.18)
    s = (np.sin(phase(f)) + 0.2 * np.sin(2 * phase(f))) * dec(t, 0.07) * rc_attack(n, 3)
    return m2(s * 0.8)


def respawn_pop():
    """Back on course: a reversed-air swell, a bubble pop and a descending sparkle, 0.75 s."""
    n = int(SR * 0.75)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    fc = glide(350, 5200, np.minimum(t, 0.34), 0.34)
    sw = tv(noise(n), "bp", fc, q=1.4) * (np.where(t < 0.34, (t / 0.34) ** 2.0, 0) * rc_attack(n, 6))[:, None]
    out += sw * 1.3
    tp = T(0.4)
    pop = np.sin(phase(glide(380, 1500, tp, 0.03))) * dec(tp, 0.05) * rc_attack(len(tp), 0.5)
    place(out, m2(pop) * 1.0, 0.34)
    place(out, m2(sos_filter(RNG.standard_normal(int(SR * 0.05)), "hp", 1500, 2) * dec(T(0.05), 0.008)) * 0.8, 0.34)
    for i, f in enumerate((2637.0, 2093.0, 1568.0, 1318.5)):
        place(out, pan(bell_partials(f, T(0.45), 0.2), 0.7 - 0.13 * i) * 0.3, 0.38 + 0.05 * i)
    return reverb(out, 0.45, 0.14)


def land_thud():
    """Car touches down from the air: suspension thump, spring 'boing' and gravel, 0.42 s."""
    n = int(SR * 0.42)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    out += m2(np.sin(phase(glide(96, 48, t, 0.12))) * dec(t, 0.09) * rc_attack(n, 1.5)) * 1.4
    out += m2(sos_filter(RNG.standard_normal(n), "lp", 500, 2) * dec(t, 0.05)) * 0.9
    sp = np.sin(phase(glide(230, 125, t, 0.2) * (1 + 0.04 * np.sin(2 * np.pi * 22 * t)))) * dec(t, 0.09) * rc_attack(n, 4)
    out += m2(sp) * 0.35
    g = tv(noise(n), "bp", 1600, q=0.8) * (dec(t, 0.07) * rc_attack(n, 2))[:, None]
    out += g * 0.6
    return out


def wall_scrape():
    """Scraping along a wall: resonant metal/stone rasp with a few sparks, 0.5 s."""
    n = int(SR * 0.5)
    t = np.arange(n) / SR
    base = noise(n)
    out = np.zeros((n, 2))
    # rasp: noise through three resonances, modulated by a ragged random envelope
    rag = np.abs(sos_filter(RNG.standard_normal(n), "lp", 45, 2))
    rag = rag / rag.max()
    rag = 0.45 + 0.55 * rag
    for fc, q, g in ((1150, 5.0, 1.0), (2350, 6.0, 0.7), (3900, 6.0, 0.5)):
        out += tv(base, "bp", fc * (1 + 0.04 * np.sin(2 * np.pi * 9 * t)), q=q) * g
    out *= (rag * rc_attack(n, 14) * rc_release(n, 180))[:, None]
    # screech partial
    sc = np.sin(phase(1750 * (1 + 0.03 * np.sin(2 * np.pi * 7 * t)))) * 0.12 * rag * rc_attack(n, 30) * rc_release(n, 200)
    out += m2(sc)
    # sparks
    sk = np.zeros(n)
    idx = RNG.choice(int(SR * 0.4), 55, replace=False)
    sk[idx] = RNG.uniform(0.3, 1.0, 55)
    sk = tv(sk, "bp", 6200, q=1.6)
    out += m2(sk) * 1.2
    out += m2(sos_filter(RNG.standard_normal(n), "lp", 260, 2) * rag * 0.4 * rc_attack(n, 20) * rc_release(n, 150))
    return out


def wall_bump():
    """Head-on bump: dull thunk, metal clank and a short rattle, 0.45 s."""
    n = int(SR * 0.45)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    out += m2(np.sin(phase(glide(150, 64, t, 0.1))) * dec(t, 0.07) * rc_attack(n, 1)) * 1.4
    out += m2(sos_filter(RNG.standard_normal(n), "lp", 1800, 2) * dec(t, 0.02)) * 1.1
    cl = np.zeros(n)
    for f, g, tau in ((283, 1.0, 0.1), (651, 0.7, 0.07), (1187, 0.55, 0.05), (2210, 0.35, 0.03)):
        cl += g * np.sin(2 * np.pi * f * t) * dec(t, tau)
    out += m2(cl * rc_attack(n, 0.6)) * 0.5
    for at in (0.1, 0.16):
        tt = T(0.05)
        place(out, m2(sos_filter(RNG.standard_normal(len(tt)), "bp", 1700, 2) * dec(tt, 0.01)) * 0.35, at)
    return out


def crash_hit():
    """Crash (replaces CrashThud): boom, crunch, metal clang, flying debris and a cartoon wobble, 0.95 s."""
    n = int(SR * 0.95)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    out += m2(np.sin(phase(glide(95, 32, t, 0.3))) * dec(t, 0.2) * rc_attack(n, 1.5)) * 1.5
    cr = tv(noise(n), "lp", glide(7000, 500, t, 0.5), q=0.8) * (dec(t, 0.16) * rc_attack(n, 0.6))[:, None]
    out += sat(cr, 2.0) * 1.2
    cl = np.zeros(n)
    for ratio, g, tau in ((1.0, 1.0, 0.28), (2.41, 0.7, 0.2), (3.93, 0.5, 0.14), (5.72, 0.35, 0.1), (8.1, 0.2, 0.06)):
        cl += g * np.sin(2 * np.pi * 187 * ratio * t) * dec(t, tau)
    out += m2(cl * rc_attack(n, 0.6)) * 0.4
    deb = np.zeros(n)
    for _ in range(22):
        at = RNG.uniform(0.12, 0.7)
        f = RNG.uniform(900, 4200)
        tt = T(0.05)
        place(deb, np.sin(2 * np.pi * f * tt) * dec(tt, 0.012) * RNG.uniform(0.1, 0.4) * (1 - at), at)
    out += pan(deb, 0.5) * 0.7
    wob = np.sin(phase(glide(260, 80, t, 0.55) * (1 + 0.05 * np.sin(2 * np.pi * 9 * t)))) * dec(t, 0.22) * rc_attack(n, 20)
    out += m2(wob) * 0.3
    return reverb(out, 0.4, 0.08)


def splash_big():
    """Sinking / drowning: a big plunge with a cavity 'bloop', rising bubbles and spray, 1.0 s."""
    n = int(SR * 1.0)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    pl = tv(noise(n), "lp", glide(2600, 380, t, 0.3), q=0.7) * (dec(t, 0.17) * rc_attack(n, 3))[:, None]
    out += pl * 1.6
    for at, f0, f1, g in ((0.0, 320, 95, 1.0), (0.13, 260, 80, 0.6)):
        tt = T(0.35)
        place(out, m2(np.sin(phase(glide(f0, f1, tt, 0.18))) * dec(tt, 0.1) * rc_attack(len(tt), 2)) * g, at)
    bub = np.zeros(n)
    for _ in range(26):
        at = RNG.uniform(0.1, 0.9) ** 1.3
        f0 = RNG.uniform(350, 900)
        tt = T(0.05)
        place(bub, np.sin(phase(glide(f0, f0 * 2.1, tt, 0.04))) * dec(tt, 0.014) * RNG.uniform(0.15, 0.4) * (1 - 0.7 * at), at)
    out += pan(bub, 0.5) * 0.8
    sp = sos_filter(noise(n), "hp", 3800, 2) * (dec(t, 0.28) * rc_attack(n, 4))[:, None]
    out += sp * 0.45
    return reverb(out, 0.35, 0.07)


def splash_small():
    """Driving into shallow water: a light splish with a few bubble chirps, 0.5 s."""
    n = int(SR * 0.5)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    sp = tv(noise(n), "bp", glide(1400, 5200, t, 0.1), q=0.9) * (dec(t, 0.09) * rc_attack(n, 2))[:, None]
    out += sp * 1.4
    out += m2(np.sin(phase(glide(240, 110, t, 0.1))) * dec(t, 0.05)) * 0.6
    bub = np.zeros(n)
    for at in (0.03, 0.07, 0.12, 0.2, 0.27):
        f0 = RNG.uniform(500, 1000)
        tt = T(0.05)
        place(bub, np.sin(phase(glide(f0, f0 * 2.0, tt, 0.04))) * dec(tt, 0.012) * RNG.uniform(0.25, 0.5), at)
    out += pan(bub, 0.55)
    return out


def missile_launch():
    """Missile leaves the rail (3D): 'foomp' of gas, rising whistle and exhaust hiss, 0.8 s."""
    n = int(SR * 0.8)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    out += m2(np.sin(phase(glide(165, 58, t, 0.12))) * dec(t, 0.08) * rc_attack(n, 1.5)) * 1.3
    gas = tv(noise(n), "lp", glide(3200, 700, t, 0.4), q=0.8) * (dec(t, 0.16) * rc_attack(n, 2))[:, None]
    out += gas * 1.3
    hs = tv(noise(n), "bp", glide(1000, 5200, t, 0.5), q=1.1) * (np.minimum(1, t / 0.08) * dec(t, 0.35) * rc_attack(n, 8))[:, None]
    out += hs * 1.0
    wh = np.sin(phase(glide(380, 1700, t, 0.55))) * (rc_attack(n, 40) * dec(t, 0.25))
    out += m2(wh) * 0.12
    out += m2(sos_filter(RNG.standard_normal(n), "hp", 2000, 2) * dec(t, 0.01)) * 0.5
    return out


def missile_loop():
    """Missile in flight (3D, attach to the missile): rocket hiss with a crackly 37 Hz flutter, 1.0 s loop."""
    n = SR
    t = np.arange(n) / SR
    hiss = circ_noise(n, 1200, 7000)
    flut = 1 + 0.35 * np.sin(2 * np.pi * 37 * t) + 0.15 * np.sin(2 * np.pi * 74 * t + 0.8)
    rum = circ_noise(n, 70, 330, slope=0.0) * 0.9
    whine = m2(np.sin(2 * np.pi * 612 * t) * 0.05 + np.sin(2 * np.pi * 1224 * t + 0.4) * 0.025)
    return hiss * flut[:, None] * 0.75 + rum + whine


def missile_explode():
    """Missile blast (3D): crack, big low boom, swept crunch, debris and a short metal ring, 0.95 s."""
    n = int(SR * 0.95)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    out += sos_filter(noise(n), "hp", 700, 2) * (dec(t, 0.01) * rc_attack(n, 0.2))[:, None] * 1.8
    out += m2(np.sin(phase(glide(118, 46, t, 0.35))) * dec(t, 0.2) * rc_attack(n, 2)) * 1.0
    out += m2(np.sin(phase(glide(230, 110, t, 0.2))) * dec(t, 0.09) * rc_attack(n, 1.5)) * 0.8
    cr = tv(noise(n), "lp", glide(7500, 280, t, 0.55), q=0.8) * (dec(t, 0.2) * rc_attack(n, 1))[:, None]
    out += sat(cr, 2.5) * 1.2
    rm = np.sin(2 * np.pi * 311 * t) * dec(t, 0.14) + 0.5 * np.sin(2 * np.pi * 743 * t) * dec(t, 0.08)
    out += m2(rm * rc_attack(n, 1)) * 0.2
    deb = np.zeros(n)
    for _ in range(30):
        at = RNG.uniform(0.1, 0.75)
        f = RNG.uniform(700, 3800)
        tt = T(0.05)
        place(deb, np.sin(2 * np.pi * f * tt) * dec(tt, 0.012) * RNG.uniform(0.1, 0.35) * (1 - at), at)
    out += pan(deb, 0.5) * 0.7
    out += sos_filter(m2(np.sin(2 * np.pi * 74 * t) * dec(t, 0.35)), "lp", 160, 2) * 0.2
    return reverb(out, 0.5, 0.10)


def trap_drop():
    """A trap is dropped (3D): 'plop' bloop, a soft thud and a rubbery boing, 0.42 s."""
    n = int(SR * 0.42)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    out += m2(np.sin(phase(glide(640, 180, t, 0.06))) * dec(t, 0.04) * rc_attack(n, 1)) * 1.0
    out += m2(np.sin(phase(glide(110, 60, t, 0.08))) * dec(t, 0.07)) * 0.8
    f = glide(190, 330, np.minimum(t, 0.1), 0.1) * np.where(t < 0.1, 1, glide(1.0, 0.76, t - 0.1, 0.25))
    bo = (np.sin(phase(f * (1 + 0.03 * np.sin(2 * np.pi * 15 * t)))) + 0.3 * np.sin(2 * phase(f))) * dec(t, 0.13) * rc_attack(n, 8)
    out += m2(bo) * 0.4
    out += m2(sos_filter(RNG.standard_normal(n), "bp", 1200, 2) * dec(t, 0.012)) * 0.4
    return out


def oil_splat():
    """Oil slick dropped or driven into: gooey 'splorch' of glops and squelch, 0.55 s."""
    n = int(SR * 0.55)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    for at, f0, g in ((0.0, 260, 1.0), (0.07, 210, 0.8), (0.15, 170, 0.6), (0.24, 140, 0.4)):
        tt = T(0.2)
        mod = np.sin(phase(glide(f0, f0 * 0.45, tt, 0.12)) + 2.6 * dec(tt, 0.05) * np.sin(phase(glide(f0 * 1.5, f0 * 0.7, tt, 0.12))))
        place(out, m2(mod * dec(tt, 0.07) * rc_attack(len(tt), 1.5)) * g, at)
    sq = tv(noise(n), "bp", glide(900, 380, t, 0.3), q=3.0) * (dec(t, 0.12) * (0.55 + 0.45 * np.sin(2 * np.pi * 26 * t)) * rc_attack(n, 3))[:, None]
    out += sq * 0.9
    out += m2(sos_filter(RNG.standard_normal(n), "lp", 700, 2) * dec(t, 0.02)) * 0.8
    return out


def oil_slip():
    """Hit the slick: tyre squeal that wobbles up and down with a skid hiss, 0.8 s."""
    n = int(SR * 0.8)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    f = 880 * (1 + 0.55 * np.sin(2 * np.pi * 1.4 * t - 0.6)) * (1 + 0.025 * np.sin(2 * np.pi * 8 * t))
    sq = (np.sin(phase(f)) + 0.5 * np.sin(2 * phase(f)) + 0.25 * np.sin(3 * phase(f)))
    sq = tv(sq, "bp", f * 1.3, q=2.5)
    env = rc_attack(n, 25) * np.where(t < 0.55, 1.0, dec(t - 0.55, 0.08))
    out += m2(sq * env) * 0.9
    sk = tv(noise(n), "bp", 2400, q=0.7) * (env * (0.6 + 0.4 * np.sin(2 * np.pi * 11 * t)))[:, None]
    out += sk * 0.7
    out += m2(sos_filter(RNG.standard_normal(n), "lp", 400, 2) * env * 0.25)
    return out


def mine_blast():
    """A mine or bubble trap goes off (3D): a comic 'bwump' with a pop, less than a missile, 0.6 s."""
    n = int(SR * 0.6)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    out += m2(np.sin(phase(glide(135, 52, t, 0.14))) * dec(t, 0.1) * rc_attack(n, 1.5)) * 0.9
    out += m2(np.sin(phase(glide(260, 120, t, 0.1))) * dec(t, 0.07) * rc_attack(n, 1.5)) * 0.9
    pop = tv(noise(n), "bp", glide(3800, 900, t, 0.1), q=0.9) * (dec(t, 0.05) * rc_attack(n, 0.4))[:, None]
    out += sat(pop, 1.8) * 1.5
    bub = np.zeros(n)
    for at in (0.06, 0.11, 0.17, 0.24):
        f0 = RNG.uniform(600, 1100)
        tt = T(0.06)
        place(bub, np.sin(phase(glide(f0, f0 * 1.9, tt, 0.04))) * dec(tt, 0.015) * RNG.uniform(0.3, 0.5), at)
    out += pan(bub, 0.5)
    out += m2(np.sin(2 * np.pi * 440 * t) * dec(t, 0.1) * 0.15 * rc_attack(n, 1))
    return reverb(out, 0.3, 0.06)


def trap_arm():
    """The trap arms (3D, quiet): two woody ticks, 0.18 s."""
    n = int(SR * 0.18)
    out = np.zeros((n, 2))
    for at, f in ((0.0, 2000.0), (0.085, 2900.0)):
        tt = T(0.07)
        s = (np.sin(2 * np.pi * f * tt) * 0.7 + np.sin(2 * np.pi * f * 2.4 * tt) * 0.3) * dec(tt, 0.012)
        s += sos_filter(RNG.standard_normal(len(tt)), "bp", f * 1.2, 2) * dec(tt, 0.004) * 0.5
        place(out, m2(s * rc_attack(len(tt), 0.3)), at)
    return out


def shield_up():
    """Shield switches on: glass-bell rising shimmer, airy sweep and a soft low swell, 0.9 s."""
    n = int(SR * 0.9)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    f = glide(330, 990, t, 0.5)
    for k, (r, g) in enumerate(((1.0, 0.5), (1.5, 0.35), (2.0, 0.3), (3.0, 0.15))):
        s = np.sin(phase(f * r) + 0.4 * np.sin(2 * np.pi * (5 + k) * t))
        out += pan(s * g * (np.sin(np.pi * np.clip(t / 0.9, 0, 1)) ** 1.2 * rc_attack(n, 40)), 0.3 + 0.13 * k)
    aw = tv(noise(n), "bp", glide(500, 6500, t, 0.5), q=1.8) * (np.sin(np.pi * np.clip(t / 0.7, 0, 1)) ** 2 * rc_attack(n, 20))[:, None]
    out += aw * 0.8
    place(out, pan(bell_partials(2637.0, T(0.6), 0.25), 0.5) * 0.5, 0.42)
    place(out, pan(bell_partials(3951.0, T(0.5), 0.2), 0.55) * 0.25, 0.46)
    out += m2(np.sin(phase(glide(90, 130, t, 0.4))) * np.sin(np.pi * np.clip(t / 0.8, 0, 1)) ** 2) * 0.5
    return reverb(out, 0.5, 0.15)


def shield_loop():
    """Shield hum (3D, quiet): detuned glassy sines with a slow tremolo, 1.0 s loop (integer Hz: periodic)."""
    n = SR
    t = np.arange(n) / SR
    s = np.zeros(n)
    for f, g in ((220, 0.6), (221, 0.5), (330, 0.35), (331, 0.3), (440, 0.25), (660, 0.1)):
        s += g * np.sin(2 * np.pi * f * t + f * 0.37)
    s *= 1 + 0.25 * np.sin(2 * np.pi * 4 * t)
    air = circ_noise(n, 1800, 7000) * 0.07 * (1 + 0.5 * np.sin(2 * np.pi * 2 * t))[:, None]
    return pan(s, 0.5) * 0.4 + air


def shield_block():
    """Shield absorbs a hit (3D): glass 'ting', energy zap and a bubble thump, 0.55 s."""
    n = int(SR * 0.55)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    gl = bell_partials(1760.0, t, 0.2, ((1, 1.0, 1.0), (2.32, 0.6, 0.6), (4.1, 0.45, 0.4), (6.7, 0.25, 0.25)))
    out += pan(gl, 0.5) * 0.7
    zap = tv(noise(n), "bp", glide(7500, 900, t, 0.09), q=2.0) * (dec(t, 0.04) * rc_attack(n, 0.5))[:, None]
    out += zap * 1.3
    out += m2(np.sin(phase(glide(210, 95, t, 0.06))) * dec(t, 0.05)) * 0.9
    return reverb(out, 0.3, 0.10)


def shield_break():
    """Shield runs out or shatters (3D): dense glass tinkle, a crack and a deflating sweep, 0.75 s."""
    n = int(SR * 0.75)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    out += sos_filter(noise(n), "hp", 2500, 2) * (dec(t, 0.015) * rc_attack(n, 0.3))[:, None] * 1.2
    gl = np.zeros(n)
    for _ in range(140):
        at = RNG.uniform(0.0, 0.6) ** 1.5
        f = RNG.uniform(2200, 9500)
        tt = T(0.08)
        place(gl, np.sin(2 * np.pi * f * tt) * dec(tt, RNG.uniform(0.008, 0.03)) * RNG.uniform(0.08, 0.35) * (1 - 0.8 * at / 0.6), at)
    out += pan(gl, 0.5) * 1.1
    de = np.sin(phase(glide(980, 190, t, 0.45))) * dec(t, 0.14) * rc_attack(n, 6)
    out += m2(de) * 0.35
    out += m2(np.sin(phase(glide(160, 70, t, 0.1))) * dec(t, 0.06)) * 0.5
    return reverb(out, 0.4, 0.10)


def magnet_lock():
    """Magnet locks on: an electric buzz and rising whine ending in a metal 'clunk', 1.0 s."""
    n = int(SR * 1.0)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    bz = saw(np.full(n, 118.0) * (1 + 0.02 * np.sin(2 * np.pi * 9 * t)), 14)
    bz = tv(bz, "bp", glide(900, 3200, t, 0.65), q=1.5)
    gate = np.where(t < 0.68, 0.55 + 0.45 * np.sign(np.sin(2 * np.pi * 31 * t)) * 0.5 + 0.2, 0)
    out += m2(bz * gate * rc_attack(n, 20) * rc_release(n, 40) * np.clip(t / 0.3, 0.3, 1)) * 0.8
    wh = np.sin(phase(glide(300, 1500, t, 0.66))) * rc_attack(n, 60) * np.where(t < 0.66, 1.0, 0)
    out += m2(wh) * 0.2
    zz = np.zeros(n)
    idx = RNG.choice(int(SR * 0.66), 60, replace=False)
    zz[idx] = RNG.uniform(-1, 1, 60)
    out += m2(tv(zz, "bp", 3600, q=1.2)) * 0.9
    tt = T(0.32)
    cl = (np.sin(2 * np.pi * 230 * tt) * dec(tt, 0.1) + 0.6 * np.sin(2 * np.pi * 590 * tt) * dec(tt, 0.06) + 0.4 * np.sin(2 * np.pi * 1330 * tt) * dec(tt, 0.04)) * rc_attack(len(tt), 0.6)
    place(out, m2(cl) * 0.8, 0.68)
    place(out, m2(np.sin(phase(glide(120, 55, tt, 0.1))) * dec(tt, 0.08)) * 0.9, 0.68)
    return reverb(out, 0.3, 0.07)


def coin_pickup():
    """Silver coin (pitch it up per coin collected): bright metallic 'ching', 0.45 s."""
    n = int(SR * 0.45)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    f = 1318.5 * (1 + 0.03 * dec(t, 0.02))
    y = np.sin(phase(f)) * dec(t, 0.16) + 0.7 * np.sin(2 * np.pi * 1975.5 * t) * dec(t, 0.2) + 0.28 * np.sin(2 * np.pi * 5210.0 * t) * dec(t, 0.09) + 0.14 * np.sin(2 * np.pi * 7320.0 * t) * dec(t, 0.05)
    y *= rc_attack(n, 0.7)
    out += pan(y, 0.5) * 0.8
    tk = sos_filter(RNG.standard_normal(n), "hp", 4000, 2) * dec(t, 0.006) * 0.4
    out += m2(tk)
    return reverb(out, 0.25, 0.07)


def coin_all():
    """All eight coins: a rising coin cascade into a shimmering major chord, 1.1 s."""
    n = int(SR * 1.1)
    out = np.zeros((n, 2))
    notes = (1046.5, 1174.66, 1318.5, 1568.0, 1760.0, 2093.0, 2349.3, 2637.0)
    for i, f in enumerate(notes):
        tt = T(0.4)
        y = (np.sin(2 * np.pi * f * tt) * dec(tt, 0.12) + 0.6 * np.sin(2 * np.pi * f * 1.5 * tt) * dec(tt, 0.14) + 0.25 * np.sin(2 * np.pi * f * 3.95 * tt) * dec(tt, 0.06)) * rc_attack(len(tt), 0.7)
        place(out, pan(y, 0.25 + 0.07 * i) * 0.5, i * 0.055)
    for f, g in ((2093.0, 0.4), (2637.0, 0.35), (3136.0, 0.3), (4186.0, 0.2)):
        place(out, pan(bell_partials(f, T(0.7), 0.3), 0.5) * g, 0.46)
    return reverb(out, 0.55, 0.14)


def unlock_fanfare():
    """Something unlocked: harp glissando up, a warm brass stab and a bell shimmer, 1.5 s."""
    n = int(SR * 1.5)
    out = np.zeros((n, 2))
    scale = [523.25, 587.33, 659.25, 783.99, 880.0, 1046.5, 1174.66, 1318.5, 1568.0, 1760.0, 2093.0, 2349.3]
    for i, f in enumerate(scale):
        tt = T(0.5)
        y = (np.sin(2 * np.pi * f * tt) + 0.35 * np.sin(4 * np.pi * f * tt) * dec(tt, 0.05)) * dec(tt, 0.2) * rc_attack(len(tt), 1.2)
        place(out, pan(y, 0.15 + 0.07 * i) * 0.4, i * 0.04)
    tt = T(1.0)
    s = np.zeros(len(tt))
    for f in (261.63, 329.63, 392.0, 523.25):
        s += saw(np.full(len(tt), f), 8) + saw(np.full(len(tt), f * 1.004), 8)
    s = tv(s, "lp", glide(700, 3800, tt, 0.2), q=1.0) * rc_attack(len(tt), 12) * dec(tt, 0.45)
    place(out, pan(s, 0.5) * 0.3, 0.46)
    for f, g, at in ((2093.0, 0.4, 0.5), (2637.0, 0.35, 0.54), (3136.0, 0.3, 0.58)):
        place(out, pan(bell_partials(f, T(0.9), 0.4), 0.5) * g, at)
    place(out, m2(np.sin(phase(glide(110, 55, T(0.3), 0.2))) * dec(T(0.3), 0.1)) * 0.6, 0.46)
    return reverb(out, 0.8, 0.16)


def vote_pip():
    """Another racer voted: one soft marimba pip, 0.14 s."""
    n = int(SR * 0.14)
    out = np.zeros((n, 2))
    place(out, pan(marimba(987.77, 0.14, 0.035), 0.5), 0.0)
    return out


def wrong_way():
    """WRONG WAY warning: a cartoon two-note 'bwomp-bwoomp' honk falling a major third (replaces the leash_warn beep), 0.55 s."""
    n = int(SR * 0.55)
    out = np.zeros((n, 2))
    for at, f, dur in ((0.0, 311.0, 0.2), (0.23, 247.0, 0.3)):
        tt = T(dur)
        fr = f * (1 + 0.012 * np.sin(2 * np.pi * 6.5 * tt)) * (1 - 0.07 * np.clip(tt / dur, 0, 1))
        sw = saw(fr, 14) + saw(fr * 1.007, 14) + 0.5 * saw(fr * 0.5, 8)
        sw = tv(sw, "lp", 1500 + 3500 * dec(tt, 0.07), q=1.6)
        sw = sat(sw, 1.6) * rc_attack(len(tt), 7) * rc_release(len(tt), 70) * (0.75 + 0.25 * dec(tt, 0.1))
        place(out, pan(sw, 0.5), at)
        place(out, m2(np.sin(phase(glide(f * 0.5 * 1.6, f * 0.5, tt, 0.05))) * dec(tt, 0.06)) * 0.4, at)
    return reverb(out, 0.25, 0.06)


def grid_rev():
    """Revving on the grid: an engine blip that climbs and falls back, 0.9 s."""
    n = int(SR * 0.9)
    t = np.arange(n) / SR
    out = np.zeros((n, 2))
    k = np.clip(t / 0.4, 0, 1)
    f0 = np.where(t < 0.4, 52 + 118 * k ** 1.4, 170 * np.exp(-(t - 0.4) * 2.0))
    s = saw(f0, 14) + saw(f0 * 2.003, 8) * 0.4
    s = tv(s, "lp", 300 + 3800 * (f0 - 50) / 130 * 1.0, q=1.2)
    s = sat(s, 2.0)
    env = rc_attack(n, 30) * np.where(t < 0.45, 1.0, dec(t - 0.45, 0.13))
    out += m2(s * env) * 0.8
    pulse = 0.5 + 0.5 * np.sin(phase(f0 / 2))
    out += tv(noise(n), "bp", 900, q=0.8) * (env * pulse)[:, None] * 0.35
    out += m2(sos_filter(RNG.standard_normal(n), "hp", 2500, 2) * env * 0.04)
    return reverb(out, 0.25, 0.05)


# role: (builder, class, rms_dbfs, ceiling_dbfs, mono, loop_xfade or None, event, gain_db, notes)
ROLES = {
    "boost_kick": (boost_kick, "boost", -15.0, -2.0, False, None, "Boost pad / ring / item boost / drift release start (SoundJuice 'medium' Boost)", -2.5, "Replaces BoostWhoosh (the crude 10-18 WAV). Also stands in as the preview sound for the EFFECTS slider."),
    "boost_overcharge": (boost_overcharge, "boost", -15.0, -2.0, False, None, "Overcharge boost start (SoundJuice 'medium' Overcharge)", -2.0, "Bigger sibling of boost_kick (double thump, crackle, higher turbine)."),
    "boost_loop": (boost_loop, "loop", -22.0, -3.0, False, "none", "While boostState ~= None: nozzle roar under the engine", -9.0, "Looped. Fade the Volume in 0.1 s and out 0.25 s with the boost; PlaybackSpeed 0.9..1.15 with speed."),
    "ring_pass": (ring_pass, "boost", -16.0, -2.0, False, None, "Boost ring passed (plane and car)", -4.0, "Layered under boost_kick (ring only), airy pass + three-note magic glissando."),
    "pad_zip": (pad_zip, "boost", -15.0, -2.0, False, None, "Ground boost pad hit", -4.0, "A quick 'zzzip' that sits on top of boost_kick."),
    "pod_pickup": (pod_pickup, "pickup", -16.0, -2.0, False, None, "Item pod collected / speed pickup / checkpoint chime", -5.0, "Replaces the pitched boost whoosh that used to stand in as PickupChime. Pitch 0.92..1.12 per pickup."),
    "pod_pop": (pod_pop, "impact", -16.0, -2.0, True, None, "Item balloon pops (3D at the pod)", -4.0, "Replaces confetti_pop for the pod pop (confetti_pop stays for the podium)."),
    "countdown_v2": (countdown_v2, "jingle", -19.0, -2.0, False, None, "3-2-1-GO (replaces music jingle_countdown, same 4.2 s timing)", -3.0, "Drop-in id swap for AudioAssets.jingle_countdown: pips land at 0, 1, 2 s, GO stab at 3.0 s."),
    "lap_ding": (lap_ding, "jingle", -16.0, -2.0, False, None, "Lap completed (LapCompleted)", -4.0, "Replaces LapFanfare for laps."),
    "finish_tada": (finish_tada, "jingle", -16.0, -2.0, False, None, "Finish line / award landed (SoundJuice 'large' Finish)", -3.0, "Replaces LapFanfare for finishes; the place jingle (Music) still plays on top and ducks this."),
    "place_up": (place_up, "ui", -17.0, -2.0, False, None, "Race position improves (HUD rank pulse)", -8.0, "Quiet HUD ping, <= 0.25 s."),
    "place_down": (place_down, "ui", -18.0, -2.0, False, None, "Race position gets worse (HUD rank pulse)", -11.0, "Deliberately softer than place_up."),
    "respawn_pop": (respawn_pop, "boost", -16.0, -2.0, False, None, "Respawn complete / rescue (Vfx.onRespawn)", -5.0, "Replaces trick_whoosh as the respawn sound."),
    "land_thud": (land_thud, "impact", -15.0, -2.0, False, None, "Car touches down from real air (Vfx.onLand)", -4.0, "Scale Volume with the landing strength s (0.25..1) and pitch 1.15 .. 0.85."),
    "wall_scrape": (wall_scrape, "impact", -17.0, -2.0, False, None, "Glancing wall scrape (car Deflect / plane slide)", -6.0, "Rate limited by the caller (bumpCooldown 0.12 s); pitch 0.9..1.1."),
    "wall_bump": (wall_bump, "impact", -15.0, -2.0, False, None, "Steep wall bump (car bump / plane no-crash touch)", -4.0, "Volume scales with impact."),
    "crash_hit": (crash_hit, "impact", -14.0, -2.0, False, None, "Crash / spin-out / wall spin (SoundJuice 'large' Crash)", -2.0, "Replaces CrashThud (the crude 10-18 WAV)."),
    "splash_big": (splash_big, "impact", -15.0, -2.0, False, None, "Sink / drown (Vfx.onSplash)", -3.0, "Plays at the drown point; 2D is fine, 3D is better for other racers."),
    "splash_small": (splash_small, "impact", -17.0, -2.0, False, None, "Shallow water entry (Vfx.onWaterEntry)", -6.0, "Pitch 0.9..1.2 with entry speed."),
    "missile_launch": (missile_launch, "item3d", -15.0, -2.0, True, None, "Missile launched (3D at the missile)", -3.0, "Replaces the boost whoosh that ItemClient.onItemUsed borrowed."),
    "missile_loop": (missile_loop, "loop", -20.0, -3.0, True, "none", "Missile in flight (3D loop on the missile body)", -5.0, "Looped, attach to the missile copy; RollOff 12..140. Stop and destroy with the missile."),
    "missile_explode": (missile_explode, "item3d", -13.0, -2.0, True, None, "Missile (and wall blast) explosion (3D at the blast)", -1.5, "Loudest item cue; ItemClient 'explode' fx."),
    "trap_drop": (trap_drop, "item3d", -16.0, -2.0, True, None, "Trap dropped (3D at the dropper)", -5.0, "Used for slick, mine and bubble drops."),
    "oil_splat": (oil_splat, "item3d", -16.0, -2.0, True, None, "Oil slick laid / burst (3D)", -4.0, "Slick form only."),
    "oil_slip": (oil_slip, "item3d", -17.0, -2.0, False, None, "Own car hits a slick (2D)", -5.0, "The tyre squeal that rides under the BONK."),
    "mine_blast": (mine_blast, "item3d", -14.0, -2.0, True, None, "Mine or bubble trap goes off (3D)", -3.0, "Smaller than missile_explode."),
    "trap_arm": (trap_arm, "ui", -20.0, -3.0, True, None, "Trap finishes arming (3D, quiet)", -12.0, "Two woody ticks; only for traps within 40 studs."),
    "shield_up": (shield_up, "item3d", -17.0, -2.0, False, None, "Shield item used (own: 2D, others: 3D)", -4.0, "Glass shimmer swell."),
    "shield_loop": (shield_loop, "loop", -26.0, -4.0, True, "none", "Shield active (3D hum on the hull)", -12.0, "Looped quiet hum; fade out over the last second with the bubble blink."),
    "shield_block": (shield_block, "item3d", -15.0, -2.0, True, None, "Shield absorbs a hit (fx 'blocked')", -3.0, "Glass ting + zap."),
    "shield_break": (shield_break, "item3d", -16.0, -2.0, True, None, "Shield expires / is destroyed (3D)", -5.0, "Dense glass tinkle."),
    "magnet_lock": (magnet_lock, "item3d", -16.0, -2.0, False, None, "Magnet item locks on (fx 'magnet')", -4.0, "Buzz, rising whine, lock clunk."),
    "coin_pickup": (coin_pickup, "pickup", -16.0, -2.0, False, None, "Challenge coin collected (Coins attribute rises)", -4.0, "PlaybackSpeed climbs a major pentatonic per coin: 1, 1.125, 1.25, 1.5, 1.667, 2 ..."),
    "coin_all": (coin_all, "jingle", -16.0, -2.0, False, None, "All coins collected (Coins == CoinsTotal)", -4.0, "Plays after the last coin_pickup."),
    "unlock_fanfare": (unlock_fanfare, "jingle", -16.0, -2.0, False, None, "Vehicle / cosmetic / track unlocked", -3.0, "Harp run, brass stab, bells."),
    "vote_pip": (vote_pip, "ui", -17.0, -2.0, False, None, "A vote count changed (FLY AGAIN / HUB / lobby)", -9.0, "Pitch 1.0 + 0.06 per vote."),
    "wrong_way": (wrong_way, "pickup", -16.0, -2.0, False, None, "Course leash WRONG WAY arrow shows / repeats (CourseArrow)", -5.0, "Replaces the leash_warn beep (a -13 dBFS peak, a plain beep); pitch 1 + 0.08 x urgency."),
    "grid_rev": (grid_rev, "boost", -17.0, -2.0, False, None, "Engine rev blip on the grid (on the '2' of the countdown)", -6.0, "Optional polish: the engine bands are already running."),
}

LIMITS = {"ui": 0.25, "impact": 1.0, "item3d": 1.2}  # seconds (the brief: short UI <= 0.25 s, impacts <= 1 s)


def decoded_true_peak_db(path):
    """True peak (4x oversampled) of the encoded file as the engine will decode it."""
    import imageio_ffmpeg
    from scipy.signal import resample_poly
    raw = subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-i", str(path), "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"], capture_output=True, check=True).stdout
    y = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).astype(np.float64)
    return 20 * math.log10(np.abs(resample_poly(y, 4, 1, axis=0)).max() + 1e-9)


def build(role, ceil_trim=0.0):
    fn, cls, rms, ceil, mono, loopx, *_ = ROLES[role]
    seed(role)
    raw = fn()
    x = master(raw, rms_db=rms, ceil_db=ceil - ceil_trim, loop=loopx is not None, mono=mono, fade_ms=14, bass=cls in ("impact", "item3d"))
    return x, mono


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    only = sys.argv[2:] or list(ROLES)
    for role in only:
        trim = 0.0
        for _ in range(4):  # Vorbis overshoots the limiter by up to ~1 dB: lower the ceiling until the DECODED true peak is <= -1.5 dBFS
            x, mono = build(role, trim)
            encode(x, out / f"{role}.ogg", mono=mono)
            tp = decoded_true_peak_db(out / f"{role}.ogg")
            if tp <= -1.5:
                break
            trim += (tp + 1.5) + 0.2
        print(f"{role:18s} {len(x) / SR:5.2f}s  true peak {tp:5.2f} dBFS")


if __name__ == "__main__":
    main()
