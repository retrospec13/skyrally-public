#!/usr/bin/env python3
"""Payoff cues for REMARKABLE Batch 2 items 20, 23, 24, 27 and 30 (Portal Plunge, photo finish, Token Homecoming,
Garage turntable, podium ceremony), synthesised in code: original and licence-free, this source is the record of how
each sound was made (seed 20261019). Writes 44.1 kHz stereo WAVs to <out_dir>; tools/audio/prep_payoffs.sh runs
tools/audio/prep_audio.py on each to make the game-ready .ogg in assets/audio/payoffs_v1/upload.

  portal_suck    1.6 s: wind band rising 300 -> 3000 Hz, a 110 -> 880 Hz glide with growing vibrato, an
                 accelerating C6-E6-G6-C7 sparkle and a swirling pan (the FOV stretch)
  portal_plunge  0.9 s: sine drop 160 -> 45 Hz "bwoomp" with a low thump, then a G5 + C6 chime (the iris shuts)
  portal_spit    0.9 s: an 85 Hz raspberry fluttering at 28 Hz, a "ptoo" pop (2 kHz noise + 900 -> 250 Hz blip) and a
                 falling cartoon boing (locked arch spits the car out)
  portal_cancel  0.5 s: a "whew" glide 1100 -> 320 Hz with a breathy noise band (warp cancelled)
  iris_open      0.45 s: fast rising "fwip": noise band 800 -> 5000 Hz and a 600 -> 1600 Hz sine
  portal_wake    2.6 s: stone grinding rumble swelling into a C major choir-like chord with sparkles and a C6 bell
  token_whoosh   0.8 s: rising whistle 700 -> 2600 Hz with vibrato and thickening sparkle ticks (token in flight)
  token_land     1.0 s: thump, metal click and an E6 + A6 bell pair: a coin-box "ka-ching"
  photo_shutter  0.5 s: flash charge whine, shutter click, mirror clack, second click
  photo_develop  1.1 s: instant-camera motor whirr and a paper slide
  podium_drop    0.45 s: wooden thump with a small spring tail (a car lands on its step)
  confetti_pop   0.5 s: party-popper crack and paper crackle
  crate_whistle  1.0 s: falling whistle 2200 -> 500 Hz (the crate drops in)
  crate_thud     0.65 s: heavy wooden crate thud and a creak
  crate_kazoo    1.2 s: kazoo "ta-daa", G4 then C5 with vibrato, after a tiny pop (the lid comes off)
  drumroll       1.6 s: snare roll speeding up 18 -> 30 Hz into a cymbal splash
  garage_rev     1.7 s: engine blip: firing harmonics 38 -> 120 -> 45 Hz through an rpm-following low-pass, two
                 backfire pops
  garage_redline 2.0 s: the same to 160 Hz bouncing on the limiter, three pops and a bang (fast double REV)
  garage_honk    0.7 s: two bulb-horn honks (reed saw 330 Hz with an onset dip, 900 Hz formant)
  garage_paint   0.7 s: spray-can "psssht" and an E6-G6-C7 sparkle (a livery tried on)

Usage: synth_payoffs.py <out_dir>"""
import math
import sys
import wave
from pathlib import Path

import numpy as np

SR = 44100
RNG = np.random.default_rng(20261019)


def t_axis(seconds):
    return np.arange(int(SR * seconds)) / SR


def biquad(x, kind, freqs, q):
    """RBJ biquad with a per-sample centre/cutoff (freqs: array or scalar). kind: 'lp' | 'bp' | 'hp'."""
    n = len(x)
    f = np.broadcast_to(np.asarray(freqs, dtype=np.float64), (n,))
    y = np.zeros(n)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(n):
        w0 = 2 * math.pi * min(max(f[i], 10.0), SR * 0.45) / SR
        cw, sw = math.cos(w0), math.sin(w0)
        alpha = sw / (2 * q)
        if kind == "lp":
            b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
        elif kind == "hp":
            b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
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


def saw_of(freq):
    ph = phase_of(freq)
    return 2 * ((ph / (2 * math.pi)) % 1.0) - 1


def attack(n, ms):
    a = int(SR * ms / 1000)
    env = np.ones(n)
    if a > 0:
        env[:min(a, n)] = np.linspace(0, 1, min(a, n))
    return env


def noise(seconds):
    return RNG.standard_normal(int(SR * seconds))


def bell(freq, seconds=0.9, decay_s=0.5):
    t = t_axis(seconds)
    env = np.exp(-t / decay_s) * attack(len(t), 1.5)
    sig = np.sin(2 * math.pi * freq * t) + 0.35 * np.sin(2 * math.pi * freq * 2.76 * t) * np.exp(-t * 6) \
        + 0.15 * np.sin(2 * math.pi * freq * 5.4 * t) * np.exp(-t * 12)
    return sig * env


def place(dst, src, at):
    i = int(SR * at)
    if i >= len(dst):
        return
    end = min(len(dst), i + len(src))
    dst[i:end] += src[: end - i]


def mono(x):
    return np.stack([x, x], axis=1)


def pan(x, p):
    """p: scalar or array 0 (left) .. 1 (right), equal power."""
    p = np.broadcast_to(np.asarray(p, dtype=np.float64), x.shape)
    return np.stack([x * np.cos(p * math.pi / 2), x * np.sin(p * math.pi / 2)], axis=1)


def sparkle(seconds, rate_from, rate_to, lo=2600.0, hi=6000.0, gain=0.18, decay=0.12):
    """Random high bell ticks whose rate climbs from rate_from to rate_to per second."""
    out = np.zeros(int(SR * seconds))
    t = 0.0
    while t < seconds:
        k = t / seconds
        rate = rate_from + (rate_to - rate_from) * k
        f = lo * (hi / lo) ** RNG.random()
        place(out, bell(f, 0.25, decay) * gain * (0.6 + 0.4 * RNG.random()), t)
        t += 1.0 / max(1.0, rate) * (0.6 + 0.8 * RNG.random())
    return out


# ------------------------------------------------------------------------------------------------- Portal Plunge (20)

def portal_suck():
    dur = 1.6
    t = t_axis(dur)
    k = np.minimum(1, t / 1.5)
    centre = 300 * (3000 / 300) ** (k ** 1.6)
    wind = biquad(noise(dur), "bp", centre, 2.2) * (0.15 + 0.85 * k ** 2)
    vib = 1 + (0.01 + 0.05 * k) * np.sin(2 * math.pi * (5 + 9 * k) * t)
    glide = 110 * (880 / 110) ** (k ** 1.3) * vib
    tone = np.sin(phase_of(glide)) * 0.35 * k ** 1.5 + 0.12 * np.sin(2 * phase_of(glide)) * k
    body = wind * 1.4 + tone
    cut = np.where(t < 1.5, 1.0, np.exp(-(t - 1.5) * 40))
    body *= cut * attack(len(t), 60)
    swirl = 0.5 + 0.45 * np.sin(2 * math.pi * np.cumsum(1.5 + 6 * k) / SR)
    out = pan(body, swirl)
    notes = [1046.5, 1318.5, 1568.0, 2093.0]
    at, gap, i = 0.35, 0.22, 0
    while at < 1.48:
        b = bell(notes[i % 4] * (2 if i >= 8 else 1), 0.3, 0.12) * 0.16
        place(out[:, 0], b * (0.4 + 0.3 * (i % 2)), at)
        place(out[:, 1], b * (0.7 - 0.3 * (i % 2)), at)
        at += gap
        gap = max(0.05, gap * 0.82)
        i += 1
    return out


def portal_plunge():
    out = np.zeros(int(SR * 0.9))
    t = t_axis(0.42)
    f = 160 * (45 / 160) ** np.minimum(1, t / 0.3)
    boom = np.sin(phase_of(f)) * np.exp(-t * 6) * attack(len(t), 3)
    place(out, boom * 0.9, 0)
    th = biquad(noise(0.12), "lp", 400, 0.8) * np.exp(-t_axis(0.12) * 30)
    place(out, th * 0.7, 0)
    place(out, bell(783.99, 0.6, 0.3) * 0.22, 0.12)
    place(out, bell(1046.5, 0.6, 0.35) * 0.2, 0.16)
    return mono(out)


def portal_spit():
    out = np.zeros(int(SR * 0.9))
    t = t_axis(0.3)
    flutter = 0.5 + 0.5 * np.sign(np.sin(2 * math.pi * 28 * t))
    rasp = biquad(saw_of(85 + 10 * np.sin(2 * math.pi * 7 * t)), "lp", 900, 2.5) * flutter
    rasp += biquad(noise(0.3), "bp", 700, 1.5) * flutter * 0.4
    place(out, rasp * attack(len(t), 10) * np.where(t < 0.26, 1.0, np.exp(-(t - 0.26) * 60)) * 0.8, 0)
    pt = t_axis(0.09)
    blip = np.sin(phase_of(900 * (250 / 900) ** (pt / 0.09))) * np.exp(-pt * 18)
    burst = biquad(noise(0.03), "bp", 2000, 1.2) * np.exp(-t_axis(0.03) * 90)
    place(out, burst * 1.1, 0.28)
    place(out, blip * 0.8, 0.29)
    bt = t_axis(0.42)
    bf = 520 * (180 / 520) ** np.minimum(1, bt / 0.3) * (1 + 0.07 * np.sin(2 * math.pi * 16 * bt))
    boing = (np.sin(phase_of(bf)) + 0.25 * np.sin(2 * phase_of(bf))) * np.exp(-bt * 6) * attack(len(bt), 4)
    place(out, boing * 0.5, 0.36)
    return mono(out)


def portal_cancel():
    t = t_axis(0.5)
    f = 1100 * (320 / 1100) ** np.minimum(1, t / 0.42)
    tone = np.sin(phase_of(f)) * np.sin(math.pi * np.minimum(1, t / 0.48)) ** 0.8
    breath = biquad(noise(0.5), "bp", 1500, 1.0) * np.exp(-t * 6) * 0.35
    return mono((tone * 0.5 + breath) * attack(len(t), 8))


def iris_open():
    t = t_axis(0.45)
    k = np.minimum(1, t / 0.3)
    band = biquad(noise(0.45), "bp", 800 * (5000 / 800) ** k, 2.5)
    tone = np.sin(phase_of(600 * (1600 / 600) ** k)) * 0.3
    env = np.sin(math.pi * np.minimum(1, t / 0.42)) ** 1.5
    return pan((band + tone) * env, 0.3 + 0.4 * k)


def portal_wake():
    dur = 2.6
    out = np.zeros((int(SR * dur), 2))
    t = t_axis(1.5)
    grind = 0.6 + 0.4 * np.sin(2 * math.pi * 9 * t) * np.sin(2 * math.pi * 2.3 * t)
    rumble = (biquad(noise(1.5), "lp", 140, 0.9) * 2.0 + np.sin(2 * math.pi * 45 * t) * 0.4) * grind
    rumble *= np.minimum(1, t / 0.6) * np.where(t < 1.1, 1.0, np.exp(-(t - 1.1) * 5))
    place(out[:, 0], rumble * 0.8, 0)
    place(out[:, 1], rumble * 0.8, 0)
    ct = t_axis(1.7)
    env = np.minimum(1, ct / 0.3) * np.exp(-np.maximum(0, ct - 0.3) * 1.6)
    chord = np.zeros(len(ct))
    for i, f in enumerate((261.63, 329.63, 392.0, 523.25, 659.25)):
        vib = 1 + 0.004 * np.sin(2 * math.pi * (5 + i * 0.4) * ct + i)
        ph = phase_of(f * vib)
        chord += (np.sin(ph) + 0.3 * np.sin(2 * ph) + 0.12 * np.sin(3 * ph)) / (1 + 0.15 * i)
    chord *= env * 0.22
    place(out[:, 0], chord * 0.9, 0.85)
    place(out[:, 1], chord, 0.87)
    place(out[:, 0], bell(1046.5, 1.2, 0.6) * 0.25, 0.95)
    place(out[:, 1], bell(1046.5, 1.2, 0.6) * 0.25, 0.95)
    sp = sparkle(1.4, 6, 16, gain=0.12)
    place(out[:, 0], sp, 0.95)
    place(out[:, 1], sparkle(1.4, 6, 16, gain=0.12), 0.97)
    return out


# ---------------------------------------------------------------------------------------------- Token Homecoming (24)

def token_whoosh():
    t = t_axis(0.8)
    k = np.minimum(1, t / 0.78)
    f = 700 * (2600 / 700) ** (k ** 1.2) * (1 + 0.02 * np.sin(2 * math.pi * 11 * t))
    whistle = np.sin(phase_of(f)) * np.sin(math.pi * k) ** 0.7 * 0.35
    air = biquad(noise(0.8), "bp", 1500 + 2500 * k, 3.0) * np.sin(math.pi * k) * 0.5
    sig = whistle + air
    out = pan(sig, 0.25 + 0.5 * k)
    sp = sparkle(0.75, 8, 30, gain=0.14)
    place(out[:, 0], sp * 0.7, 0.03)
    place(out[:, 1], sp, 0.03)
    return out


def token_land():
    out = np.zeros(int(SR * 1.0))
    tt = t_axis(0.06)
    place(out, np.sin(2 * math.pi * 120 * tt) * np.exp(-tt * 50) * 0.8, 0)
    click = biquad(noise(0.012), "hp", 3000, 0.8) * np.exp(-t_axis(0.012) * 300)
    place(out, click * 0.8, 0.005)
    for f, at, g in ((1318.5, 0.02, 0.45), (1760.0, 0.08, 0.5), (2637.0, 0.08, 0.12)):
        place(out, bell(f, 0.9, 0.38) * g, at)
    return mono(out)


# ------------------------------------------------------------------------------------------------ photo finish (23)

def photo_shutter():
    out = np.zeros(int(SR * 0.5))
    wt = t_axis(0.12)
    whine = np.sin(phase_of(2000 * (5000 / 2000) ** (wt / 0.12))) * np.minimum(1, wt / 0.1) * 0.08
    place(out, whine, 0)
    for at, g in ((0.12, 1.0), (0.23, 0.7)):
        c = biquad(noise(0.004), "hp", 2500, 0.7) * np.exp(-t_axis(0.004) * 900)
        place(out, c * g, at)
    clack = biquad(noise(0.03), "bp", 1200, 1.6) * np.exp(-t_axis(0.03) * 120)
    place(out, clack * 0.9, 0.17)
    return mono(out)


def photo_develop():
    out = np.zeros(int(SR * 1.1))
    t = t_axis(0.8)
    f = 140 * (1 + 0.04 * np.sin(2 * math.pi * 30 * t))
    motor = biquad(saw_of(f) + 0.5 * saw_of(2 * f), "lp", 1200, 1.0) * (0.75 + 0.25 * np.sin(2 * math.pi * 30 * t))
    motor *= attack(len(t), 30) * np.where(t < 0.7, 1.0, np.exp(-(t - 0.7) * 30)) * 0.4
    place(out, motor, 0)
    slide = biquad(noise(0.7), "bp", 3000, 1.2) * np.sin(math.pi * np.minimum(1, t_axis(0.7) / 0.7)) * 0.25
    place(out, slide, 0.05)
    flap = biquad(noise(0.05), "lp", 900, 0.8) * np.exp(-t_axis(0.05) * 60)
    place(out, flap * 0.6, 0.82)
    return mono(out)


# ----------------------------------------------------------------------------------------------- podium ceremony (30)

def podium_drop():
    out = np.zeros(int(SR * 0.45))
    t = t_axis(0.12)
    place(out, np.sin(2 * math.pi * 95 * t) * np.exp(-t * 28) * 0.9, 0)
    place(out, biquad(noise(0.12), "lp", 600, 0.9) * np.exp(-t * 35) * 0.8, 0)
    bt = t_axis(0.3)
    bf = (300 + 120 * np.minimum(1, bt / 0.12)) * (1 + 0.05 * np.sin(2 * math.pi * 18 * bt))
    place(out, np.sin(phase_of(bf)) * np.exp(-bt * 10) * 0.2, 0.05)
    return mono(out)


def confetti_pop():
    out = np.zeros((int(SR * 0.5), 2))
    crack = biquad(noise(0.02), "bp", 1800, 0.9) * np.exp(-t_axis(0.02) * 140)
    place(out[:, 0], crack, 0)
    place(out[:, 1], crack, 0)
    for _ in range(26):
        at = 0.03 + RNG.random() * 0.4
        c = biquad(noise(0.006), "hp", 4000, 0.7) * np.exp(-t_axis(0.006) * 600) * (0.15 + 0.2 * RNG.random())
        ch = int(RNG.random() * 2)
        place(out[:, ch], c, at)
    return out


def crate_whistle():
    t = t_axis(1.0)
    k = np.minimum(1, t / 0.95)
    f = 2200 * (500 / 2200) ** k * (1 + 0.01 * np.sin(2 * math.pi * 7 * t))
    sig = np.sin(phase_of(f)) * np.minimum(1, t / 0.05) * (0.5 + 0.5 * k) * np.where(t < 0.95, 1.0, np.exp(-(t - 0.95) * 60))
    return mono(sig * 0.4)


def crate_thud():
    out = np.zeros(int(SR * 0.65))
    t = t_axis(0.2)
    place(out, np.sin(2 * math.pi * 70 * t) * np.exp(-t * 16) * 1.0, 0)
    place(out, biquad(noise(0.2), "lp", 400, 0.9) * np.exp(-t * 22) * 1.1, 0)
    place(out, biquad(noise(0.05), "bp", 1600, 1.4) * np.exp(-t_axis(0.05) * 70) * 0.5, 0.004)
    ct = t_axis(0.3)
    jitter = 200 * (1 + 0.15 * np.sin(2 * math.pi * 23 * ct) + 0.1 * RNG.standard_normal(len(ct)).cumsum() / 400)
    creak = biquad(saw_of(jitter), "bp", 1100, 3.0) * np.sin(math.pi * np.minimum(1, ct / 0.3)) * 0.35
    place(out, creak, 0.16)
    return mono(out)


def kazoo_note(freq, seconds, vib_depth):
    t = t_axis(seconds)
    f = freq * (1 + vib_depth * np.sin(2 * math.pi * 6 * t) * np.minimum(1, t / 0.2))
    src = saw_of(f) + 0.3 * RNG.standard_normal(len(t)) * (0.5 + 0.5 * np.sign(np.sin(phase_of(f))))
    v = biquad(src, "bp", 620, 2.0) * 1.2 + biquad(src, "bp", 1450, 3.0) * 0.9 + biquad(src, "lp", 3000, 0.7) * 0.15
    return v * attack(len(t), 15) * np.where(t < seconds - 0.06, 1.0, np.exp(-(t - (seconds - 0.06)) * 50))


def crate_kazoo():
    out = np.zeros(int(SR * 1.2))
    pop = biquad(noise(0.02), "bp", 1500, 0.9) * np.exp(-t_axis(0.02) * 160)
    place(out, pop * 0.8, 0)
    place(out, kazoo_note(392.0, 0.2, 0.0) * 0.5, 0.06)
    place(out, kazoo_note(523.25, 0.85, 0.025) * 0.55, 0.28)
    return mono(out)


def drumroll():
    dur = 1.6
    out = np.zeros(int(SR * dur))
    at = 0.0
    while at < 1.05:
        k = at / 1.05
        g = 0.25 + 0.75 * k ** 1.5
        hit = biquad(noise(0.04), "bp", 1800, 0.9) * np.exp(-t_axis(0.04) * 70) + np.sin(2 * math.pi * 190 * t_axis(0.04)) * np.exp(-t_axis(0.04) * 80) * 0.4
        place(out, hit * g * (0.85 + 0.3 * RNG.random()), at)
        at += 1.0 / (18 + 12 * k)
    crash = biquad(noise(0.6), "hp", 4000, 0.7) * np.exp(-t_axis(0.6) * 6) * 0.7
    place(out, crash, 1.06)
    place(out, np.sin(2 * math.pi * 80 * t_axis(0.15)) * np.exp(-t_axis(0.15) * 25) * 0.8, 1.06)
    return mono(out)


# -------------------------------------------------------------------------------------------- Garage turntable (27)

def engine(curve_t, curve_f, dur, pops, lp_lo=500, lp_hi=3200):
    t = t_axis(dur)
    f0 = np.interp(t, curve_t, curve_f)
    ph = phase_of(f0)
    firing = np.zeros(len(t))
    for h, g in ((1, 1.0), (2, 0.7), (3, 0.45), (4, 0.3), (6, 0.15)):
        firing += g * np.sin(h * ph + 0.3 * h)
    firing += 0.5 * (2 * ((ph / (2 * math.pi)) % 1.0) - 1)
    k = (f0 - min(curve_f)) / max(1e-6, (max(curve_f) - min(curve_f)))
    sig = biquad(firing, "lp", lp_lo + (lp_hi - lp_lo) * k, 0.9)
    sig += biquad(noise(dur), "bp", 900 + 1500 * k, 1.0) * (0.08 + 0.15 * k)
    sig *= attack(len(t), 20) * np.where(t < dur - 0.08, 1.0, np.exp(-(t - (dur - 0.08)) * 40))
    out = sig * 0.5
    for at, g in pops:
        p = biquad(noise(0.05), "bp", 1100, 0.8) * np.exp(-t_axis(0.05) * 70) + np.sin(2 * math.pi * 70 * t_axis(0.05)) * np.exp(-t_axis(0.05) * 50)
        place(out, p * g, at)
    return mono(out)


def garage_rev():
    return engine([0, 0.08, 0.45, 0.75, 1.2, 1.7], [38, 40, 120, 118, 45, 40], 1.7, [(1.22, 0.8), (1.36, 0.55)])


def garage_redline():
    ct = [0.0, 0.08, 0.4]
    cf = [38, 40, 150]
    x = 0.4
    while x < 1.2:
        ct += [x + 0.04, x + 0.08]
        cf += [160, 148]
        x += 0.08
    ct += [1.5, 2.0]
    cf += [50, 40]
    return engine(ct, cf, 2.0, [(1.25, 0.7), (1.37, 0.6), (1.46, 0.5), (1.58, 1.2)], lp_hi=4200)


def honk(seconds):
    t = t_axis(seconds)
    f = 330 * (1 + 0.09 * np.exp(-t * 30)) * (1 + 0.006 * np.sin(2 * math.pi * 31 * t))
    reed = saw_of(f) + 0.35 * saw_of(f * 1.5)
    v = biquad(reed, "bp", 900, 2.0) * 1.3 + biquad(reed, "lp", 2200, 0.7) * 0.3
    return v * attack(len(t), 8) * np.where(t < seconds - 0.04, 1.0, np.exp(-(t - (seconds - 0.04)) * 70))


def garage_honk():
    out = np.zeros(int(SR * 0.7))
    place(out, honk(0.2) * 0.6, 0)
    place(out, honk(0.26) * 0.6, 0.3)
    return mono(out)


def garage_paint():
    out = np.zeros((int(SR * 0.7), 2))
    t = t_axis(0.38)
    spray = biquad(noise(0.38), "bp", 6000, 0.8) * np.minimum(1, t / 0.03) * np.where(t < 0.3, 1.0, np.exp(-(t - 0.3) * 40))
    place(out[:, 0], spray * 0.45, 0)
    place(out[:, 1], spray * 0.5, 0)
    for i, f in enumerate((1318.5, 1568.0, 2093.0)):
        b = bell(f, 0.5, 0.25) * 0.22
        place(out[:, 0], b * (0.8 - 0.2 * i), 0.3 + i * 0.05)
        place(out[:, 1], b * (0.6 + 0.2 * i), 0.3 + i * 0.05)
    return out


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
    "portal_suck": portal_suck,
    "portal_plunge": portal_plunge,
    "portal_spit": portal_spit,
    "portal_cancel": portal_cancel,
    "iris_open": iris_open,
    "portal_wake": portal_wake,
    "token_whoosh": token_whoosh,
    "token_land": token_land,
    "photo_shutter": photo_shutter,
    "photo_develop": photo_develop,
    "podium_drop": podium_drop,
    "confetti_pop": confetti_pop,
    "crate_whistle": crate_whistle,
    "crate_thud": crate_thud,
    "crate_kazoo": crate_kazoo,
    "drumroll": drumroll,
    "garage_rev": garage_rev,
    "garage_redline": garage_redline,
    "garage_honk": garage_honk,
    "garage_paint": garage_paint,
}


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    only = set(sys.argv[2:])
    for name, fn in CUES.items():
        if only and name not in only:
            continue
        p = out / f"{name}.wav"
        write_wav(p, fn())
        print("SYNTH", p)


if __name__ == "__main__":
    main()
