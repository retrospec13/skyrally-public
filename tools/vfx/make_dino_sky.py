#!/usr/bin/env python3
"""DINO-4 cave skybox v2 (L61): the far side faces read as distant cave wall in violet haze instead of a near-black
void where the great hall's far walls drop out of the terrain render distance on lower graphics levels. Owned,
procedural (numpy): a vertical haze gradient (cool violet up, warm lava glow at the horizon line), two low-contrast
layers of far rock-wall shapes and faint strata bands, horizontally seamless. up/down reuse the v1 faces.
Usage: make_dino_sky.py -> assets/sky/dino_cave_v2/side.png"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "sky" / "dino_cave_v2"
N = 512
rng = np.random.default_rng(461)


def periodic_noise(octaves, amp_falloff=0.55):
    """1D horizontally periodic noise over N columns (sum of random-phase sines)."""
    x = np.arange(N) / N * 2 * np.pi
    v, a = np.zeros(N), 1.0
    for k in octaves:
        v += a * np.sin(k * x + rng.uniform(0, 2 * np.pi))
        a *= amp_falloff
    return v / np.abs(v).max()


def main():
    y = np.linspace(0, 1, N)[:, None]  # 0 top .. 1 bottom
    top = np.array([112, 100, 142], float)  # cool violet haze high in the cavern
    mid = np.array([150, 108, 118], float)  # mauve rock in haze
    low = np.array([196, 104, 62], float)  # lava glow at the horizon
    t = np.clip(y / 0.62, 0, 1)
    col = top * (1 - t)[..., None] + mid * t[..., None]
    g = np.clip((y - 0.62) / 0.38, 0, 1) ** 1.4
    col = col * (1 - g)[..., None] + low * g[..., None]
    img = np.repeat(col, N, axis=1).reshape(N, N, 3) if col.shape[1] == 1 else col
    img = np.broadcast_to(col, (N, N, 3)).copy()
    # faint strata bands across the wall
    band = 0.025 * np.sin(y * 70 + 1.3) + 0.03 * np.sin(y * 23)
    img *= (1 + band)[..., None]
    # two silhouette layers: a far ridge and a nearer, darker one with a warm rim
    for base, rough, shade, rim in ((0.42, 0.07, 0.92, 0.0), (0.58, 0.09, 0.84, 0.0)):
        h = base + rough * periodic_noise([2, 3, 5, 9, 17, 31])
        rows = (np.arange(N)[:, None] / N) > h[None, :]
        img[rows] *= shade
        if rim:
            edge = np.abs((np.arange(N)[:, None] / N) - h[None, :]) < 0.006
            img[edge] = img[edge] * 0.6 + np.array([230, 130, 70]) * 0.4
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.6))
    OUT.mkdir(parents=True, exist_ok=True)
    im.save(OUT / "side.png")
    print(OUT / "side.png", np.array(im).reshape(-1, 3).mean(0).round(1))


if __name__ == "__main__":
    main()
