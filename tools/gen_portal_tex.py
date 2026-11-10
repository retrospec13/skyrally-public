#!/usr/bin/env python3
"""Procedural hub-portal textures (assets/vfx/portal/*.png) + previews. White RGB with alpha so ImageColor3 tints per zone.
Colour channels are constant white (premultiply-safe: no dark fringes); all shape lives in alpha."""
import os

import numpy as np
from PIL import Image

N = 512
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "vfx", "portal")
os.makedirs(OUT, exist_ok=True)
y, x = np.mgrid[0:N, 0:N].astype(np.float64)
cx = (N - 1) / 2
dx, dy = (x - cx) / (N / 2), (y - cx) / (N / 2)
r = np.hypot(dx, dy)
th = np.arctan2(dy, dx)


def sm(a, b, v):
    t = np.clip((v - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def save(name, alpha):
    a = np.clip(alpha, 0, 1)
    img = np.zeros((N, N, 4), np.uint8)
    img[..., :3] = 255
    img[..., 3] = (a * 255 + 0.5).astype(np.uint8)
    Image.fromarray(img, "RGBA").save(os.path.join(OUT, name))


def spiral(arms, tight, seed, width):
    # log spiral: phase = arms*(theta - tight*ln r); soft raised-cosine arm plus a faint finer filament between arms.
    lr = np.log(np.maximum(r, 1e-3))
    ph = arms * (th - tight * lr) + seed
    arm = (0.5 + 0.5 * np.cos(ph)) ** width
    fil = (0.5 + 0.5 * np.cos(ph * 3 + 1.3)) ** 6 * 0.18
    v = np.maximum(arm, fil)
    env = sm(0.04, 0.55, r) * (1 - sm(0.93, 1.0, r))  # fades into the centre, soft at the outer edge
    bright = 0.35 + 0.65 * sm(0.2, 0.9, r)
    return v * env * bright


# (a) vortex: A has 4 arms, B has 3 arms the other way round (counter-rotation reads as depth)
save("vortex_a.png", spiral(5, 0.95, 0.0, 7.0) * 1.3)
save("vortex_b.png", spiral(4, -1.2, 1.0, 5.0) * 1.3)
# (b) depth core: dense in the middle, soft edge (tinted dark client side)
save("core.png", (1 - sm(0.0, 1.0, r)) ** 0.6 * 0.5 + (1 - sm(0.7, 1.0, r)) * 0.5)
# (c) rim: crisp ring at r ~ 0.9, inner glow falling toward the centre, faint outer halo
ring = np.exp(-(((r - 0.9) / 0.028) ** 2))
inner = np.exp(-np.maximum(0.9 - r, 0) / 0.12) * (r < 0.93) * 0.55
halo = np.exp(-np.maximum(r - 0.9, 0) / 0.035) * (r >= 0.9) * 0.5
save("rim.png", np.clip(ring + inner * (1 - ring) + halo, 0, 1) * (1 - sm(0.97, 1.0, r)))
# (d) inward speed lines: radial streaks, longer near the rim, none at the centre
rng = np.random.default_rng(7)
ns = 46
ang_off = rng.random(ns) * 2 * np.pi
ln = 0.35 + 0.5 * rng.random(ns)
w = 0.012 + 0.02 * rng.random(ns)
st = np.zeros_like(r)
for i in range(ns):
    d = np.angle(np.exp(1j * (th - ang_off[i])))
    across = np.exp(-((d * np.maximum(r, 0.05) / w[i]) ** 2))
    rad = sm(0.92 - ln[i], 0.92 - ln[i] * 0.2, r) * (1 - sm(0.9, 0.97, r))
    st = np.maximum(st, across * rad * (0.5 + 0.5 * rng.random()))
save("streaks.png", st)


def load(name):
    return np.asarray(Image.open(os.path.join(OUT, name)), np.float64)[..., 3] / 255


core, va, vb, rm, sk = (load(n) for n in ("core.png", "vortex_a.png", "vortex_b.png", "rim.png", "streaks.png"))


def rot(a, deg, scale=1.0):
    im = Image.fromarray((a * 255).astype(np.uint8)).rotate(deg, resample=Image.BICUBIC)
    if scale != 1.0:
        s = int(N * scale)
        im = im.resize((s, s), Image.BICUBIC)
        c = Image.new("L", (N, N), 0)
        c.paste(im, ((N - s) // 2, (N - s) // 2))
        im = c
    return np.asarray(im, np.float64) / 255


def over(dst, col, a):
    return dst * (1 - a[..., None]) + np.array(col, np.float64) * a[..., None]


ZONES = {"dino": (240, 122, 42), "forest": (63, 200, 52), "island": (30, 220, 230), "snow": (130, 205, 255), "space": (150, 90, 255)}
WHITE = np.array([255, 255, 255.0])
previews = []
for zn, acc in ZONES.items():
    acc = np.array(acc, np.float64)
    im = np.zeros((N, N, 3)) + np.array([205, 190, 150.0])
    im[:, : N // 8] = im[:, -N // 8:] = [150, 135, 105]  # stone pillars either side
    im = over(im, acc * 0.22, core)
    im = over(im, acc * 0.7 + WHITE * 0.3, rot(vb, 40, 0.72) * 0.75)
    im = over(im, acc * 0.55 + WHITE * 0.45, rot(va, 25) * 0.9)
    im = over(im, acc * 0.5 + WHITE * 0.5, sk * 0.28)
    im = over(im, acc * 0.75 + WHITE * 0.25, rm)
    img = Image.fromarray(np.clip(im, 0, 255).astype(np.uint8))
    img.save(os.path.join(OUT, f"preview_{zn}.png"))
    previews.append(img)

sheet = Image.new("RGB", (N * 5, N * 2))
for i, n in enumerate(("vortex_a.png", "vortex_b.png", "core.png", "rim.png", "streaks.png")):
    a = (load(n) * 255).astype(np.uint8)
    sheet.paste(Image.fromarray(np.stack([a] * 3, -1)), (i * N, 0))
for i, p in enumerate(previews):
    sheet.paste(p, (i * N, N))
sheet.resize((N * 5 // 2, N)).save(os.path.join(OUT, "preview_sheet.png"))
