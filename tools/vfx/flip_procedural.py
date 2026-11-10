#!/usr/bin/env python3
"""Procedural (numpy shader) flipbooks for SkyRally VFX v2: the emissive, line-like effects where a 2D shader is the
right tool (crisp cores, controllable glow, mathematically seamless loops). Original work, deterministic seeds.

Every generator returns straight-alpha RGBA float32 frames (N, S, S, 4) in display space [0, 1].
Emissive frames are authored bright-on-transparent: colour carries the hue, alpha carries the soft falloff.
"""
import math

import numpy as np
from PIL import Image, ImageDraw

TAU = 2 * math.pi


# ------------------------------------------------------------------ primitives

def blur(img, sigma):
    """Gaussian blur of a 2D float array via FFT (wrap-free thanks to padding)."""
    if sigma <= 0:
        return img
    p = int(3 * sigma) + 1
    a = np.pad(img, p)
    h, w = a.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.rfftfreq(w)[None, :]
    g = np.exp(-2 * (math.pi * sigma) ** 2 * (fx * fx + fy * fy))
    out = np.fft.irfft2(np.fft.rfft2(a) * g, s=a.shape)
    return out[p:-p, p:-p]


def glow_stack(core, sigmas, weights):
    return sum(w * blur(core, s) for s, w in zip(sigmas, weights))


def downsample(a, k):
    if k == 1:
        return a
    h, w = a.shape[:2]
    return a.reshape(h // k, k, w // k, k, *a.shape[2:]).mean((1, 3))


def coords(S):
    y, x = np.mgrid[0:S, 0:S].astype(np.float32)
    c = (S - 1) / 2
    return (x - c) / (S / 2), (y - c) / (S / 2)   # [-1, 1], y down


def draw_polyline(S, pts, widths, ss=1):
    """Rasterise a polyline with per-segment widths (in px of S) into a float mask, anti-aliased by supersampling."""
    big = Image.new("L", (S * ss, S * ss), 0)
    d = ImageDraw.Draw(big)
    for (p, q), w in zip(zip(pts[:-1], pts[1:]), widths):
        w2 = max(1, int(round(w * ss)))
        d.line([(p[0] * ss, p[1] * ss), (q[0] * ss, q[1] * ss)], fill=255, width=w2)
        r = w2 / 2
        d.ellipse([q[0] * ss - r, q[1] * ss - r, q[0] * ss + r, q[1] * ss + r], fill=255)
    a = np.asarray(big, np.float32) / 255
    return downsample(a, ss)


def emissive_rgba(intensity, ramp, alpha_k=1.0):
    """intensity (H, W) >= 0 -> straight RGBA. ramp: list of (pos, (r, g, b)) mapping intensity to colour; alpha is a
    soft function of intensity so the outer glow fades to 0."""
    I = np.clip(intensity, 0, None)
    pos = np.array([p for p, _ in ramp], np.float32)
    cols = np.array([c for _, c in ramp], np.float32)
    t = np.clip(I, pos[0], pos[-1])
    rgb = np.stack([np.interp(t, pos, cols[:, k]) for k in range(3)], -1)
    a = 1 - np.exp(-I * alpha_k)
    return np.concatenate([rgb, a[..., None]], -1).astype(np.float32)


# ------------------------------------------------------------------ noise

def value_noise3(shape, cells, seed, periodic_t=None):
    """Smooth 3D value noise on a (T, H, W) grid with cells=(ct, cy, cx) lattice cells; all axes periodic (so the
    texture tiles and loops)."""
    T, H, W = shape
    ct, cy, cx = cells
    rng = np.random.default_rng(seed)
    g = rng.random((ct, cy, cx)).astype(np.float32)
    t = np.arange(T, dtype=np.float32) / T * ct
    y = np.arange(H, dtype=np.float32) / H * cy
    x = np.arange(W, dtype=np.float32) / W * cx

    def axis(v, n):
        i0 = np.floor(v).astype(int)
        f = v - i0
        f = f * f * f * (f * (f * 6 - 15) + 10)
        return i0 % n, (i0 + 1) % n, f

    t0, t1, ft = axis(t, ct)
    y0, y1, fy = axis(y, cy)
    x0, x1, fx = axis(x, cx)
    out = np.zeros(shape, np.float32)
    for ti, wt in ((t0, 1 - ft), (t1, ft)):
        for yi, wy in ((y0, 1 - fy), (y1, fy)):
            for xi, wx in ((x0, 1 - fx), (x1, fx)):
                out += g[ti][:, yi][:, :, xi] * wt[:, None, None] * wy[None, :, None] * wx[None, None, :]
    return out


def fbm3(shape, cells, seed, octaves=4, gain=0.5):
    out = np.zeros(shape, np.float32)
    amp, tot = 1.0, 0.0
    ct, cy, cx = cells
    for o in range(octaves):
        out += amp * value_noise3(shape, (ct, cy * 2 ** o, cx * 2 ** o), seed + 17 * o)
        tot += amp
        amp *= gain
    return out / tot


# ------------------------------------------------------------------ bolts

def bolt_path(rng, p0, p1, depth=7, rough=0.22):
    """Midpoint displacement between p0 and p1 -> list of points."""
    pts = [np.array(p0, float), np.array(p1, float)]
    disp = rough * np.linalg.norm(np.subtract(p1, p0))
    for _ in range(depth):
        new = [pts[0]]
        for a, b in zip(pts[:-1], pts[1:]):
            m = (a + b) / 2
            d = b - a
            n = np.array([-d[1], d[0]]) / (np.linalg.norm(d) + 1e-9)
            new += [m + n * rng.normal(0, disp), b]
        pts = new
        disp *= 0.55
    return pts


def lightning_bolt(S=512, seed=11, variant=0, ss=2):
    """One branching bolt (top -> bottom) with a hot white core and a blue-violet glow."""
    rng = np.random.default_rng(seed + 101 * variant)
    m = S * 0.1
    top = (S / 2 + rng.normal(0, S * 0.06), m)
    bot = (S / 2 + rng.normal(0, S * 0.1), S - m)
    core = np.zeros((S, S), np.float32)

    def stroke(pts, w0, w1, energy):
        n = len(pts) - 1
        widths = [w0 + (w1 - w0) * i / n for i in range(n)]
        return draw_polyline(S, [tuple(p) for p in pts], widths, ss) * energy

    main = bolt_path(rng, top, bot, depth=8, rough=0.19)
    core = np.maximum(core, stroke(main, S * 0.016, S * 0.006, 1.0))  # thinner trunk: crisp zigzag, not a noodle
    # branches: fork off the main path heading down/out, thinner, dimmer; some sub-branches
    nb = rng.integers(3, 6)
    for _ in range(nb):
        i = rng.integers(len(main) // 8, int(len(main) * 0.75))
        p = main[i]
        ang = math.radians(90 + rng.choice([-1, 1]) * rng.uniform(20, 55))
        L = S * rng.uniform(0.18, 0.38)
        q = p + np.array([math.cos(ang), math.sin(ang)]) * L
        q[0] = np.clip(q[0], m, S - m)
        q[1] = np.clip(q[1], m, S - m)
        br = bolt_path(rng, p, q, depth=6, rough=0.22)
        core = np.maximum(core, stroke(br, S * 0.009, S * 0.003, 0.8))
        if rng.random() < 0.6:
            j = rng.integers(len(br) // 4, len(br) * 3 // 4)
            ang2 = ang + rng.choice([-1, 1]) * rng.uniform(0.3, 0.8)
            q2 = br[j] + np.array([math.cos(ang2), math.sin(ang2)]) * L * 0.5
            q2[0] = np.clip(q2[0], m, S - m)
            q2[1] = np.clip(q2[1], m, S - m)
            core = np.maximum(core, stroke(bolt_path(rng, br[j], q2, depth=5, rough=0.25), S * 0.005, S * 0.002, 0.6))
    I = core * 3.0 + glow_stack(core, (S * 0.006, S * 0.022, S * 0.07), (1.25, 1.0, 0.55))
    ramp = [(0.0, (0.42, 0.22, 1.0)), (0.3, (0.32, 0.5, 1.0)), (0.8, (0.6, 0.85, 1.0)), (1.8, (0.95, 0.98, 1.0)),
            (3.0, (1, 1, 1))]
    return emissive_rgba(I, ramp, alpha_k=1.6)


def lightning_bolt_2x2(S=512, seed=11):
    return np.stack([lightning_bolt(S, seed, v) for v in range(4)])


def electric_arc(N=16, S=256, seed=23):
    """Looping crackle: 3-4 jagged arcs from a hot centre to random points on a ring, re-rolled every frame, with a
    pulsing core; arcs are anchored to slowly orbiting endpoints so the motion reads continuous, and the orbit is a
    whole number of turns over N frames (seamless loop)."""
    rng = np.random.default_rng(seed)
    frames = []
    c = np.array([S / 2, S / 2])
    narcs = 4
    base = rng.random(narcs) * TAU
    turns = rng.choice([-1, 1], narcs)
    for f in range(N):
        t = f / N
        core = np.zeros((S, S), np.float32)
        for k in range(narcs):
            ang = base[k] + turns[k] * TAU * t + 0.35 * math.sin(TAU * (2 * t + k / narcs))
            r = S * (0.30 + 0.08 * math.sin(TAU * (t * 3 + k * 0.37)))
            end = c + np.array([math.cos(ang), math.sin(ang)]) * r
            # arcs between centre and end, plus occasional arc between two ends (a "jump")
            pts = bolt_path(rng, c + (end - c) * 0.06, end, depth=6, rough=0.28)
            core = np.maximum(core, draw_polyline(S, [tuple(p) for p in pts],
                                                  [S * (0.018 - 0.011 * i / len(pts)) for i in range(len(pts))], 2))
            if rng.random() < 0.5:
                i = rng.integers(len(pts) // 3, len(pts) - 2)
                a2 = ang + rng.choice([-1, 1]) * rng.uniform(0.4, 1.0)
                q = pts[i] + np.array([math.cos(a2), math.sin(a2)]) * S * rng.uniform(0.08, 0.16)
                core = np.maximum(core, 0.7 * draw_polyline(S, [tuple(p) for p in bolt_path(rng, pts[i], q, 4, 0.3)],
                                                            [S * 0.005] * 16, 2))
        x, y = coords(S)
        rr = np.sqrt(x * x + y * y)
        pulse = 0.85 + 0.15 * math.sin(TAU * 2 * t)
        ball = np.exp(-(rr / 0.10) ** 2) * 1.6 * pulse + np.exp(-(rr / 0.28) ** 2) * 0.35 * pulse
        I = core * 2.6 + glow_stack(core, (S * 0.008, S * 0.03, S * 0.07), (1.4, 0.8, 0.35)) + ball
        ramp = [(0.0, (0.4, 0.25, 1.0)), (0.35, (0.25, 0.6, 1.0)), (1.0, (0.65, 0.92, 1.0)), (2.2, (1, 1, 1))]
        frames.append(emissive_rgba(I, ramp, alpha_k=1.5))
    return np.stack(frames)


# ------------------------------------------------------------------ sparkle

def sparkle_star(N=16, S=256, seed=5):
    """Looping 4-point star burst: long tapered cross rays + short diagonal rays, twinkle pulse (2 beats per loop),
    slow 45-degree swing, soft halo and a few orbiting glints. All motion periodic in N frames."""
    x, y = coords(S)
    r = np.sqrt(x * x + y * y) + 1e-6
    th = np.arctan2(y, x)
    frames = []
    for f in range(N):
        t = f / N
        beat = 0.5 + 0.5 * math.cos(TAU * 2 * t)            # 1 at t=0, 0.5, ...
        beat2 = 0.5 + 0.5 * math.cos(TAU * 2 * t + math.pi)
        rot = math.radians(8) * math.sin(TAU * t)
        a = th - rot
        L1 = 0.55 + 0.33 * beat                               # cross ray length
        L2 = 0.22 + 0.14 * beat2                              # diagonal ray length
        # ray profile: width shrinks with distance (sharp tips)
        def rays(n, L, w0, phase=0.0):
            ang = np.abs(((a - phase) * n / 2 / math.pi * 2 % 2) - 1)   # 0 on rays -> 1 between (n/2-fold)
            ang = np.abs(np.sin((a - phase) * n / 2))                     # 0 on ray axis
            width = w0 * np.clip(1 - r / L, 0, 1) ** 1.3 + 1e-4
            return np.exp(-(ang * r / width) ** 2) * np.clip(1 - r / L, 0, 1) ** 0.8
        cross = rays(4, L1, 0.06)
        diag = rays(4, L2, 0.045, math.pi / 4) * 0.7
        core = np.exp(-(r / (0.07 + 0.03 * beat)) ** 2) * 1.8
        halo = np.exp(-(r / 0.22) ** 2) * (0.18 + 0.14 * beat)
        I = cross * (1.2 + 0.8 * beat) + diag * (0.8 + 0.6 * beat2) + core + halo
        # orbiting glints
        for k in range(3):
            ga = TAU * (t + k / 3) + 0.4
            gx, gy = 0.42 * math.cos(ga), 0.42 * math.sin(ga) * 0.9
            gr = np.sqrt((x - gx) ** 2 + (y - gy) ** 2)
            tw = 0.5 + 0.5 * math.cos(TAU * (3 * t + k * 0.33))
            I = I + np.exp(-(gr / 0.025) ** 2) * 1.2 * tw + np.exp(-(gr / 0.07) ** 2) * 0.25 * tw
        I = I + blur(I, S * 0.012) * 0.35
        ramp = [(0.0, (1.0, 0.72, 0.3)), (0.4, (1.0, 0.86, 0.5)), (1.0, (1.0, 0.96, 0.82)), (2.0, (1, 1, 1))]
        frames.append(emissive_rgba(I, ramp, alpha_k=1.8))
    return np.stack(frames)


# ------------------------------------------------------------------ shockwave

def shockwave(N=64, S=256, seed=3):
    """One-shot: a bright thin leading ring expands with ease-out, a softer trailing band thins and fades, the ring edge
    wobbles with angular noise (distortion), a quick central flash at the start; ends fully transparent."""
    rng = np.random.default_rng(seed)
    x, y = coords(S)
    r = np.sqrt(x * x + y * y)
    th = np.arctan2(y, x)
    # angular noise: sum of a few harmonics with random phases (seamless around the circle)
    harm = [(k, rng.uniform(0, TAU), rng.uniform(0.3, 1) / k) for k in range(3, 14)]

    def ang_noise(phase_t):
        return sum(a * np.sin(k * th + p + phase_t * (1 + k * 0.1)) for k, p, a in harm)

    frames = []
    for f in range(N):
        t = f / (N - 1)
        e = 1 - (1 - t) ** 3
        R = 0.08 + 0.80 * e
        width = 0.035 + 0.05 * e
        wob = ang_noise(t * 3) * (0.012 + 0.03 * e)
        d = r - (R + wob)
        lead = np.exp(-(d / (width * 0.35)) ** 2)
        trail = np.exp(-(np.clip(-d, 0, None) / (width * 2.2)) ** 1.5) * (d < 0) * 0.45
        streaks = 0.75 + 0.25 * np.sin(23 * th + 3 * np.sin(5 * th)) * np.sin(11 * th + 1.7)
        I = (lead * 1.6 + trail) * streaks
        fade = (1 - t) ** 1.4
        flash = math.exp(-t * 14) * (np.exp(-(r / 0.22) ** 2) * 2.0)
        I = I * fade * (1.2 if t < 0.1 else 1.0) + flash
        I = I + blur(I, S * 0.015) * 0.6
        ramp = [(0.0, (0.35, 0.7, 1.0)), (0.5, (0.6, 0.86, 1.0)), (1.2, (0.92, 0.97, 1.0)), (2.0, (1, 1, 1))]
        frames.append(emissive_rgba(I, ramp, alpha_k=1.7))
    frames[-1][..., 3] = 0
    return np.stack(frames)


# ------------------------------------------------------------------ speed streak

def speed_streak(W=256, H=1024):
    """Single vertical streak: hot thin core, soft glow, long tapered tail (bottom) and short rounded head (top)."""
    y, x = np.mgrid[0:H, 0:W].astype(np.float32)
    u = (x - (W - 1) / 2) / (W / 2)
    v = y / (H - 1)                                           # 0 top (head) .. 1 bottom (tail)
    head, tail = 0.06, 0.94
    along = np.clip((v - head) / 0.08, 0, 1) ** 0.7 * np.clip((tail - v) / (tail - head - 0.08), 0, 1) ** 1.6
    w = 0.06 + 0.10 * np.clip((tail - v) / (tail - head), 0, 1)  # widest near the head
    core = np.exp(-(u / (w * 0.25)) ** 2) * along
    glow = np.exp(-(u / (w * 1.1)) ** 2) * along * 0.6 + np.exp(-(u / (w * 3)) ** 2) * along * 0.18
    I = core * 1.8 + glow
    ramp = [(0.0, (0.85, 0.93, 1.0)), (0.6, (0.95, 0.98, 1.0)), (1.2, (1, 1, 1))]
    out = emissive_rgba(I, ramp, alpha_k=2.2)
    return out[None]


# ------------------------------------------------------------------ magic swirl

def magic_swirl(N=64, S=256, seed=9, ss=2):
    """Looping vortex of glowing wisps: wisps are born on the outer rim of a tilted disc, spiral inward along a
    log-spiral while brightening, and dissolve into a pulsing core. Each wisp's life is a whole fraction of the loop
    and the whole pattern repeats every N frames (seamless). Comet trails are drawn from the wisp's own past path;
    depth (front/back of the tilted disc) scales width and brightness. Colour runs violet (rim) -> magenta -> cyan-white
    (core) so it reads on bright skies under normal blending and glows under LightEmission."""
    rng = np.random.default_rng(seed)
    x, y = coords(S)
    r = np.sqrt(x * x + y * y)
    tilt = 0.72                                    # disc squash (view from ~46 deg)
    arms = 3
    per_arm = 4
    wisps = []
    for a in range(arms):
        for k in range(per_arm):
            wisps.append(dict(phase=(k + rng.uniform(-0.15, 0.15)) / per_arm, arm=a / arms + rng.uniform(-0.04, 0.04),
                              w=rng.uniform(0.8, 1.2), b=rng.uniform(0.75, 1.0)))
    motes = [(rng.uniform(0, 1), rng.uniform(0.2, 0.85), rng.uniform(0, 1)) for _ in range(26)]
    R0, R1 = 0.86, 0.06
    turns_in = 0.85                                # turns travelled from rim to core

    def wpos(w, life):
        """life 0 (rim) .. 1 (core); returns screen x, y, depth (1 = front), radius."""
        rad = R0 * (R1 / R0) ** (life ** 0.85)
        ang = TAU * (w["arm"] + turns_in * life)
        X = rad * math.cos(ang)
        Zd = rad * math.sin(ang)
        return X, Zd * tilt - 0.04, 0.5 + 0.5 * (Zd / max(rad, 1e-6)) * min(1, rad * 3), rad

    def colour(life):
        stops = [(0.0, (0.55, 0.30, 1.0)), (0.45, (0.95, 0.40, 0.95)), (0.8, (0.55, 0.85, 1.0)), (1.0, (0.9, 0.97, 1.0))]
        for (p0, c0), (p1, c1) in zip(stops[:-1], stops[1:]):
            if life <= p1:
                f = (life - p0) / (p1 - p0)
                return np.array(c0) * (1 - f) + np.array(c1) * f
        return np.array(stops[-1][1])

    frames = []
    for fi in range(N):
        t = fi / N
        acc = np.zeros((S, S, 3), np.float32)
        for w in wisps:
            life = (t + w["phase"]) % 1.0
            # fade in over the first 18% of life (quarter-sine: 0 -> 1, monotonic), fade out over the last 15%
            env = math.sin(0.5 * math.pi * min(1, life / 0.18)) if life < 0.18 else 1.0
            env *= 1 - max(0, (life - 0.85) / 0.15) ** 2
            pts = []
            for j in range(48):
                lj = life - j * 0.0085
                if lj < 0:
                    break
                pts.append((*wpos(w, lj), j / 47))
            # max-composite the trail segments of one wisp (summing them doubled the overlapping round caps and
            # beaded the trail into dots)
            trail = np.zeros((S, S), np.float32)
            for (X0, Y0, d0, r0, s0), (X1, Y1, d1, r1, s1) in zip(pts[:-1], pts[1:]):
                width = (0.055 * (1 - s0) ** 1.2 + 0.004) * (0.55 + 0.6 * d0) * w["w"] * (0.6 + r0)
                p0 = ((X0 + 1) * S / 2, (Y0 + 1) * S / 2)
                p1 = ((X1 + 1) * S / 2, (Y1 + 1) * S / 2)
                m = draw_polyline(S, [p0, p1], [max(1.0, width * S / 2)], ss)
                e = 1.35 * env * w["b"] * (1 - s0) ** 1.6 * (0.45 + 0.75 * d0)  # 1.35: max-composite is dimmer than the old sum
                trail = np.maximum(trail, m * e)
            acc += trail[..., None] * colour(min(1, life))[None, None]
            if pts:
                X, Y, d, rr, _ = pts[0]
                hr = np.sqrt((x - X) ** 2 + (y - Y) ** 2)
                acc += (np.exp(-(hr / 0.022) ** 2) * 1.3 * env * (0.5 + 0.7 * d))[..., None] * \
                    (0.4 + 0.6 * colour(min(1, life)))[None, None]
        for (ph, rad0, tw) in motes:
            life = (t * 2 + ph) % 1.0
            rad = rad0 * (1 - 0.6 * life)
            a = TAU * (ph * 3 + 0.5 * life)
            mx, my = rad * math.cos(a), rad * math.sin(a) * tilt - 0.04
            mr = np.sqrt((x - mx) ** 2 + (y - my) ** 2)
            bb = math.sin(math.pi * life) ** 2 * (0.5 + 0.5 * math.cos(TAU * (4 * t + tw)))
            acc += (np.exp(-(mr / 0.014) ** 2) * 1.4 * bb)[..., None] * np.array([1.0, 0.92, 1.0])
        pulse = 0.85 + 0.15 * math.cos(TAU * 2 * t)
        ry = np.sqrt(x * x + ((y + 0.04) / tilt) ** 2)
        core = np.exp(-(r / 0.07) ** 2) * 0.9 * pulse + np.exp(-(ry / 0.3) ** 2) * 0.16
        acc += core[..., None] * np.array([0.75, 0.85, 1.0])
        glow = np.stack([blur(acc[..., k], S * 0.018) for k in range(3)], -1)
        glow2 = np.stack([blur(acc[..., k], S * 0.05) for k in range(3)], -1)
        L = acc + glow * 0.8 + glow2 * 0.45
        lum = L.max(-1)
        a = 1 - np.exp(-lum * 1.6)
        hue = L / np.maximum(lum, 1e-4)[..., None]
        hot = np.clip((lum - 0.9) / 1.4, 0, 1)[..., None]
        rgb = hue * (1 - hot) + hot
        frames.append(np.concatenate([np.clip(rgb, 0, 1), a[..., None]], -1).astype(np.float32))
    return np.stack(frames)


def lattice(cells, seed):
    return np.random.default_rng(seed).random(cells).astype(np.float32)


def noise_at(g, t, y, x):
    """Periodic 3D value noise of lattice g (ct, cy, cx) at float lattice coords (broadcastable arrays)."""
    ct, cy, cx = g.shape
    t, y, x = np.broadcast_arrays(t, y, x)

    def axis(v, n):
        i0 = np.floor(v).astype(int)
        f = v - i0
        f = f * f * f * (f * (f * 6 - 15) + 10)
        return i0 % n, (i0 + 1) % n, f

    t0, t1, ft = axis(t, ct)
    y0, y1, fy = axis(y, cy)
    x0, x1, fx = axis(x, cx)
    out = 0
    for ti, wt in ((t0, 1 - ft), (t1, ft)):
        for yi, wy in ((y0, 1 - fy), (y1, fy)):
            for xi, wx in ((x0, 1 - fx), (x1, fx)):
                out = out + g[ti, yi, xi] * wt * wy * wx
    return out


def fire_loop(N=64, S=256, seed=31):
    """Looping stylised flame tongue: a teardrop body eroded by upward-scrolling, domain-warped fbm. The noise is
    periodic in time and the scroll covers a whole number of lattice periods per loop, so frame N wraps to frame 0
    exactly. Colour ramps white-yellow core -> orange -> red edge; alpha follows the eroded intensity."""
    x, y = coords(S)
    u = x * 1.0                              # [-1, 1]
    v = (1 - (y + 1) / 2)                    # 0 bottom .. 1 top
    v = (v - 0.06) / 0.9
    gs = [lattice((8, 8, 8), seed + i) for i in range(4)]
    frames = []
    for f in range(N):
        tt = f / N
        # scroll up: y lattice coord increases with time by whole periods (4 cells per loop per octave base)
        def fbm(xx, yy, oct_=4, base=(3.0, 3.0), scroll=2, tc=0.0):
            acc, amp, tot = 0, 1.0, 0
            for o in range(oct_):
                fx, fy = base[0] * 2 ** o, base[1] * 2 ** o
                # whole lattice periods (8 cells) of scroll per loop, same screen speed for every octave
                acc = acc + amp * noise_at(gs[o], tc * 8 + o * 1.7, yy * fy - tt * 8 * scroll * 2 ** o, xx * fx)
                tot += amp
                amp *= 0.5
            return acc / tot
        wx = fbm(u * 0.6 + 0.3, v * 0.6, 3, (2, 2), 1, tt) - 0.5
        wy = fbm(u * 0.6 + 5.1, v * 0.6, 3, (2, 2), 1, tt) - 0.5
        vc = np.clip(v, 0, None)
        uu = u + wx * 0.9 * vc ** 1.1 + 0.05 * math.sin(TAU * tt * 2) * vc ** 2
        vv = v + wy * 0.2 * vc
        lobes = fbm(uu * 0.8 + 9.0, vv * 0.4, 2, (3, 2), 1, tt)
        width = (0.36 + 0.22 * (lobes - 0.5)) * np.clip(1 - vv, 0, 1) ** 0.6 * np.clip(vv * 5 + 0.3, 0, 1) ** 0.5
        body = np.clip(1 - np.abs(uu) / np.maximum(width, 1e-3), 0, 1)
        body = body * np.clip((vv + 0.06) / 0.1, 0, 1)
        n = fbm(uu * 1.2, vv * 1.0, 4, (2.5, 2.0), 2, tt)
        n = np.clip((n - 0.5) * 2.2 + 0.5, 0, 1)
        I = body ** 0.7 * 1.5 - (1 - n) * (0.25 + 1.5 * np.clip(vv, 0, 1) ** 1.2)
        I = np.clip(I, 0, None) * np.clip(body * 6, 0, 1)
        ramp = [(0.0, (0.7, 0.06, 0.02)), (0.2, (0.95, 0.22, 0.03)), (0.5, (1.0, 0.5, 0.07)), (0.85, (1.0, 0.78, 0.25)),
                (1.3, (1.0, 0.95, 0.7))]
        rgba = emissive_rgba(I, ramp, alpha_k=3.0)
        glow = blur(I, S * 0.025) * 0.6
        rgba[..., 3] = np.clip(rgba[..., 3] + glow * (1 - rgba[..., 3]), 0, 1)
        frames.append(rgba)
    return np.stack(frames)


GENERATORS = {
    "lightning_bolt_2x2": lambda: lightning_bolt_2x2(512),
    "electric_arc_4x4": lambda: electric_arc(16, 256),
    "sparkle_star_4x4": lambda: sparkle_star(16, 256),
    "shockwave_8x8": lambda: shockwave(64, 256),
    "speed_streak": lambda: speed_streak(256, 1024),
    "magic_swirl_8x8": lambda: magic_swirl(64, 256),
    "fire_loop_proc": lambda: fire_loop(64, 256),
}
