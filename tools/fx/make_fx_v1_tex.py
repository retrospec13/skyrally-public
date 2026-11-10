#!/usr/bin/env python3
"""SkyRally fx_v1 textures (flame core/outer, shock ring, gull palette). Original procedural art, numpy+PIL only.
Image convention: row 0 (top) = the BASE of the flame / inner edge of the ring; u wraps around the circumference
(all noise is integer-periodic in u so the cone has no seam). Straight (non-premultiplied) RGBA with colour kept in
fully transparent texels so mip filtering never darkens the edges."""
import sys
from pathlib import Path
import numpy as np
from PIL import Image

OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "assets" / "models" / "fx_v1"
OUT.mkdir(parents=True, exist_ok=True)


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def ramp(t, stops):
    ts = np.array([s[0] for s in stops])
    out = np.zeros(t.shape + (3,))
    for c in range(3):
        out[..., c] = np.interp(t, ts, [s[1][c] for s in stops])
    return out


def streaks(u, v, seed, ku=(7, 11, 17), kv=(1.0, 2.0, 3.0)):
    """0..1 noise, periodic in u (integer ku), stretched along v (small kv) -> vertical licks."""
    rng = np.random.default_rng(seed)
    n = np.zeros_like(u)
    for a, b in zip(ku, kv):
        n += np.sin(2 * np.pi * (a * u + b * v + rng.uniform(0, 1))) * np.sin(2 * np.pi * ((a + 2) * u * 0.5 - 0.7 * b * v + rng.uniform(0, 1)))
    n = n / (len(ku) * 0.55)
    return np.clip(0.5 + 0.5 * n, 0, 1)


def save(name, rgb, a):
    arr = np.dstack([np.clip(rgb, 0, 255), np.clip(a, 0, 1) * 255]).astype(np.uint8)
    Image.fromarray(arr, "RGBA").save(OUT / name)
    return arr


def grid(w, h):
    u = (np.arange(w) + 0.5) / w
    v = (np.arange(h) + 0.5) / h
    return np.meshgrid(u, v)


# ---- flame core: white-hot -> cyan -> blue -> transparent, 256x512, v = distance along the flame from the base
U, V = grid(256, 512)
rgb = ramp(V, [(0, (255, 255, 255)), (0.12, (246, 253, 255)), (0.35, (150, 226, 255)), (0.65, (40, 150, 255)), (1.0, (20, 90, 255))])
s = streaks(U, V, 3)
a = 1 - smooth(0.38, 0.99, V) ** 1.1
a *= 1 - 0.30 * (1 - s) * smooth(0.15, 0.9, V)
a *= 0.55 + 0.45 * smooth(0.0, 0.06, V)
rgb = rgb * (0.9 + 0.14 * s[..., None])
core = save("flame_core.png", rgb, a)

# ---- flame outer: orange-gold -> deep orange, soft licks that break the tip into tongues
U, V = grid(256, 512)
rgb = ramp(V, [(0, (255, 244, 176)), (0.15, (255, 208, 84)), (0.4, (255, 152, 32)), (0.75, (242, 84, 16)), (1.0, (192, 42, 10))])
s = streaks(U, V, 11, ku=(5, 9, 14), kv=(1.5, 2.5, 4.0))
a = 0.92 * (1 - smooth(0.04, 1.0, V)) ** 1.1
tongue = np.clip(1.25 - V * 1.6 * (1 - s) ** 1.2 * 1.35, 0, 1)
a *= tongue
a *= 0.5 + 0.5 * smooth(0.0, 0.07, V)
rgb = rgb * (0.88 + 0.2 * s[..., None])
outer = save("flame_outer.png", rgb, a)

# ---- shock ring: radial band (v 0 = inner edge, 1 = outer edge), 256x256
U, V = grid(256, 256)
rgb = ramp(1 - np.abs(V - 0.52) * 2.0, [(0, (40, 110, 255)), (0.4, (110, 205, 255)), (0.8, (226, 248, 255)), (1.0, (255, 255, 255))])
s = streaks(U, V, 29, ku=(6, 10, 15), kv=(0.5, 1.0, 1.5))
band = np.exp(-(((V - 0.52) / 0.15) ** 2)) * (0.88 + 0.12 * s)
band *= 1 - 0.35 * smooth(0.55, 1.0, V)  # softer on the outside
ring = save("shock_ring.png", rgb, band)

# ---- gull palette strip (UV lookup fallback for engines that ignore vertex colours): 256x8
W = 256
x = (np.arange(W) + 0.5) / W
pal = np.zeros((W, 3))
pal[:] = (246, 244, 238)
ramp_zone = (x >= 0.08) & (x < 0.46)
t = (x[ramp_zone] - 0.08) / 0.38
pal[ramp_zone] = ramp(t, [(0, (246, 244, 238)), (0.7, (150, 156, 166)), (1.0, (58, 62, 72))])
pal[(x >= 0.46) & (x < 0.52)] = (58, 62, 72)
pal[(x >= 0.52) & (x < 0.64)] = (240, 170, 44)
pal[(x >= 0.64) & (x < 0.8)] = (216, 60, 44)
pal[x >= 0.8] = (28, 28, 34)
Image.fromarray(np.repeat(pal[None].astype(np.uint8), 8, axis=0), "RGB").save(OUT / "gull_palette.png")

# ---- Beam-ready variants: Beam textures run along the beam length on image X, so rotate 90 deg (base on the LEFT).
for name, arr in (("flame_core", core), ("flame_outer", outer)):
    Image.fromarray(np.ascontiguousarray(np.rot90(arr, 1)), "RGBA").save(OUT / f"{name}_beam.png")
print("textures ->", OUT)
