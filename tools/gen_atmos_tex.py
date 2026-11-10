#!/usr/bin/env python3
"""Procedural atmosphere textures (assets/vfx/atmos/*.png) + contact sheet. White RGB with all shape in alpha, so the
emitter's Color tints each one per map (premultiply-safe: no dark fringes). Deterministic (fixed seeds)."""
import os

import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "vfx", "atmos")
os.makedirs(OUT, exist_ok=True)


def sm(a, b, v):
    t = np.clip((v - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def grid(n):
    y, x = np.mgrid[0:n, 0:n].astype(np.float64)
    c = (n - 1) / 2
    return (x - c) / (n / 2), (y - c) / (n / 2)


def save(name, alpha):
    n = alpha.shape[0]
    img = np.zeros((n, n, 4), np.uint8)
    img[..., :3] = 255
    img[..., 3] = (np.clip(alpha, 0, 1) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(img, "RGBA").save(os.path.join(OUT, name))
    return img


def ash_flake(n=128):
    # an irregular curled flake: an ellipse with a noisy rim, brighter along one edge (a lit, charred curl), soft edge
    dx, dy = grid(n)
    rng = np.random.default_rng(7)
    th = np.arctan2(dy, dx)
    rim = 0.62 + sum(rng.uniform(0.03, 0.08) * np.cos(k * th + rng.uniform(0, 6.28)) for k in (2, 3, 5, 7))
    r = np.hypot(dx * 1.0, dy * 1.45)
    body = 1 - sm(rim - 0.12, rim, r)
    lit = 0.55 + 0.45 * sm(-0.5, 0.5, -(dx * 0.7 + dy * 0.7))
    return body * lit


def god_ray(n=256):
    # a tall soft light shaft: narrow gaussian across, long fade along (both ends), faint banding so it reads as dusty air
    dx, dy = grid(n)
    across = np.exp(-((dx / 0.16) ** 2))
    along = sm(-1.0, -0.55, dy) * (1 - sm(0.45, 1.0, dy))
    band = 0.85 + 0.15 * np.cos(dx * 14 + dy * 3)
    return across * along * band * 0.9


def star_streak(n=256):
    # a thin horizontal streak (VelocityParallel stretches it along travel): bright core, tapered ends, faint halo
    dx, dy = grid(n)
    core = np.exp(-((dy / 0.035) ** 2)) * (1 - sm(0.55, 1.0, np.abs(dx)))
    halo = np.exp(-((dy / 0.12) ** 2)) * 0.25 * (1 - sm(0.2, 0.9, np.abs(dx)))
    head = np.exp(-(((dx - 0.35) / 0.18) ** 2 + (dy / 0.09) ** 2)) * 0.5
    return np.clip(core + halo + head, 0, 1)


sheet = Image.new("RGBA", (3 * 260, 260), (28, 36, 60, 255))
for i, (name, fn) in enumerate((("ash_flake.png", ash_flake), ("god_ray.png", god_ray), ("star_streak.png", star_streak))):
    img = Image.fromarray(save(name, fn()), "RGBA")
    sheet.alpha_composite(img.resize((256, 256)), (i * 260 + 2, 2))
sheet.convert("RGB").save(os.path.join(OUT, "contact_sheet.png"))
print("ok")
