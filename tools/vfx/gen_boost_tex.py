#!/usr/bin/env python3
"""Procedural boost-lane textures (assets/vfx/boost/*.png) + a contact sheet. White RGB with alpha so the emitter's Color
tints it (premultiply-safe: no dark fringes); all shape lives in alpha. Deterministic, numpy + PIL only.

pad_chevron.png  256x256  an upward double chevron (two stacked ^ arrows) with a hot core and a soft halo, for the idle
                          boost-pad rising-arrow emitter (client/BoostPadFx). Sprite faces the camera, apex up.
"""
import os

import numpy as np
from PIL import Image

N = 256
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "vfx", "boost")
os.makedirs(OUT, exist_ok=True)


def sm(a, b, v):
    t = np.clip((v - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def seg_dist(px, py, ax, ay, bx, by):
    """Distance from every pixel to the segment a-b (all in unit coordinates)."""
    vx, vy = bx - ax, by - ay
    t = np.clip(((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy), 0, 1)
    return np.hypot(px - (ax + t * vx), py - (ay + t * vy))


def chevron(px, py, apex_y, half_w, drop, width):
    """One ^ (apex up) as two thick segments; returns the distance field."""
    ax = 0.0
    d1 = seg_dist(px, py, ax, apex_y, -half_w, apex_y + drop)
    d2 = seg_dist(px, py, ax, apex_y, half_w, apex_y + drop)
    return np.minimum(d1, d2)


def make_pad_chevron():
    ys, xs = np.mgrid[0:N, 0:N].astype(np.float64)
    px = (xs - (N - 1) / 2) / (N / 2)  # -1..1
    py = (ys - (N - 1) / 2) / (N / 2)  # -1 top .. 1 bottom
    d = np.minimum(chevron(px, py, -0.55, 0.62, 0.55, 0), chevron(px, py, -0.02, 0.62, 0.55, 0))
    core = 1 - sm(0.045, 0.085, d)  # crisp bar
    halo = (1 - sm(0.08, 0.30, d)) * 0.45  # soft glow
    a = np.clip(np.maximum(core, halo), 0, 1)
    # lower chevron a touch fainter so the pair reads as motion upwards
    a *= 1 - 0.28 * sm(-0.1, 0.7, py)
    a *= 1 - sm(0.9, 1.0, np.hypot(px, py))  # nothing touches the sprite border
    return a


def save(name, alpha):
    a = np.clip(alpha, 0, 1)
    img = np.zeros(a.shape + (4,), np.uint8)
    img[..., :3] = 255
    img[..., 3] = (a * 255 + 0.5).astype(np.uint8)
    Image.fromarray(img, "RGBA").save(os.path.join(OUT, name))
    return img


def contact(imgs):
    tiles = []
    for bg in ((24, 28, 44), (120, 190, 235)):
        for img, tint in imgs:
            base = np.zeros(img.shape, np.float64)
            base[..., :3] = bg
            al = img[..., 3:4] / 255.0
            rgb = base[..., :3] * (1 - al) + np.array(tint) * al
            tiles.append(rgb.astype(np.uint8))
    sheet = np.concatenate(tiles, axis=1)
    Image.fromarray(sheet, "RGB").save(os.path.join(OUT, "contact_sheet.png"))


if __name__ == "__main__":
    img = save("pad_chevron.png", make_pad_chevron())
    contact([(img, (255, 214, 70)), (img, (110, 232, 255))])
    print("wrote", os.path.abspath(OUT))
