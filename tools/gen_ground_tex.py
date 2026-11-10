#!/usr/bin/env python3
"""Procedural ground-FX textures for the car lane (assets/vfx/ground/*.png) + a contact sheet.
White RGB with alpha (premultiply-safe, tinted by Trail.Color); all shape lives in alpha.
  skid_strip  256x256 tyre mark ribbon: U runs ALONG the trail (tiles seamlessly), V across (soft edges, two tread
              ribs, ragged break-up so a long mark is not a flat bar).
  wake_foam   256x256 foam streak for the water V-wake: U along the trail, V across; bright ragged crest on both
              edges, thin broken centre (reads as a wedge once Trail.WidthScale widens it)."""
import os

import numpy as np
from PIL import Image

N = 256
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "vfx", "ground")
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(11)
v, u = np.mgrid[0:N, 0:N].astype(np.float64)
u /= N
v = (v - (N - 1) / 2) / (N / 2)  # -1..1 across the ribbon


def sm(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def tile_noise(cells_u, cells_v, seed):
    """Value noise tileable along U (wraps), bilinear-smoothed."""
    r = np.random.default_rng(seed)
    g = r.random((cells_v + 1, cells_u))
    gu = (u * cells_u)
    gv = (v * 0.5 + 0.5) * cells_v
    iu = np.floor(gu).astype(int)
    iv = np.floor(gv).astype(int)
    fu, fv = gu - iu, gv - iv
    fu, fv = fu * fu * (3 - 2 * fu), fv * fv * (3 - 2 * fv)
    a = g[iv, iu % cells_u]
    b = g[iv, (iu + 1) % cells_u]
    c = g[np.minimum(iv + 1, cells_v), iu % cells_u]
    d = g[np.minimum(iv + 1, cells_v), (iu + 1) % cells_u]
    return (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv


def save(name, alpha):
    a = np.clip(alpha, 0, 1)
    img = np.zeros((N, N, 4), np.uint8)
    img[..., :3] = 255
    img[..., 3] = (a * 255 + 0.5).astype(np.uint8)
    Image.fromarray(img, "RGBA").save(os.path.join(OUT, name))
    return img


# skid: body with soft edges, two darker tread ribs, ragged break-up along the length
edge = 1 - sm(0.62, 0.98, np.abs(v))
ribs = 0.72 + 0.28 * (np.exp(-(((np.abs(v) - 0.38) / 0.12) ** 2)) + np.exp(-((v / 0.1) ** 2)) * 0.4)
rag = 0.55 + 0.45 * tile_noise(16, 6, 3)
fine = 0.8 + 0.2 * tile_noise(48, 16, 5)
skid = edge * ribs * rag * fine
skid = np.clip(skid * 1.25, 0, 1) * (0.9)
a = save("skid_strip.png", skid)

# wake: bright ragged edges and a broken centre line
crest = np.exp(-(((np.abs(v) - 0.78) / 0.16) ** 2))
core = np.exp(-((v / 0.14) ** 2)) * (0.35 + 0.65 * tile_noise(10, 4, 9))
body = (1 - sm(0.55, 1.0, np.abs(v))) * 0.25
foam = (crest * (0.55 + 0.45 * tile_noise(20, 8, 4)) + core * 0.6 + body) * (1 - sm(0.9, 1.0, np.abs(v)))
b = save("wake_foam.png", foam)

# contact sheet: both over a grey road and a blue water square, tiled 2x along U
sheet = np.zeros((N * 2, N * 4, 3), np.uint8)
sheet[:, : N * 2] = (96, 98, 104)
sheet[:, N * 2 :] = (40, 120, 190)
for i, img in enumerate((a, b)):
    for k in range(2):
        x0 = (i * 2 + k) * N
        al = img[..., 3:4] / 255.0
        tint = np.array([20, 20, 22] if i == 0 else [235, 250, 255], np.float64)
        blk = sheet[0:N, x0 : x0 + N].astype(np.float64)
        sheet[0:N, x0 : x0 + N] = (blk * (1 - al) + tint * al).astype(np.uint8)
Image.fromarray(sheet).save(os.path.join(OUT, "_contact_sheet.png"))
print("wrote", OUT)
