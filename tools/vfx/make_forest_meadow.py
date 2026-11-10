#!/usr/bin/env python3
"""FOREST-1 L61 meadow texture T7_MEADOW_SOFT (owned, procedural, deterministic).

The Higgsfield T1_MEADOW_GRASS tile carried a dark frame on two edges and high-contrast wavy grass bands: tiled over
the vale's big hills it read as a grid of neon "fish scales" (critic r0: "blown out, unpleasantly neon"). This tile is a
soft painterly sea-grass meadow: low-frequency mottling (lighter sunlit drifts, deeper blue-green hollows), short
brush tufts with light tips and darker roots, and a few clover/flower specks, all periodic so it tiles without seams.
Low contrast on purpose: the light and the terrain shape do the modelling, the texture only adds a painted surface.
Writes assets/materials/forest_v1/tiles/T7_MEADOW_SOFT_{color,ncolor,normal}.png (1024) and adds its tint to
tiles/tints.json with the tools/vfx/neutralize.py formula (only this tile; the other tiles are left byte-identical).
Usage: make_forest_meadow.py"""
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
D = ROOT / "assets" / "materials" / "forest_v1" / "tiles"
NAME = "T7_MEADOW_SOFT"
N = 1024
SEED = 7107


def periodic_noise(n, freq_lo, freq_hi, seed):
    """Seamless band-limited noise in [-1, 1]: random phases on an integer frequency ring (periodic by construction)."""
    rng = np.random.default_rng(seed)
    fy = np.fft.fftfreq(n) * n
    fx = np.fft.rfftfreq(n) * n
    FY, FX = np.meshgrid(fy, fx, indexing="ij")
    r = np.hypot(FX, FY)
    amp = np.where((r >= freq_lo) & (r <= freq_hi), 1.0 / np.maximum(r, 1.0), 0.0)
    spec = amp * np.exp(2j * np.pi * rng.random(amp.shape))
    out = np.fft.irfft2(spec, s=(n, n))
    out -= out.mean()
    return out / (np.abs(out).max() + 1e-9)


def main() -> None:
    rng = np.random.default_rng(SEED)
    base = np.array([120, 158, 88], float)       # sea-grass green (warm light turns it gold-green, shade blue-green)
    sun = np.array([156, 184, 98], float)         # sunlit drift
    hollow = np.array([86, 128, 92], float)       # blue-green hollow
    lo = periodic_noise(N, 1, 4, SEED)            # broad drifts (one tile = ~60-90 studs)
    mid = periodic_noise(N, 5, 14, SEED + 1)
    t = np.clip(0.55 * lo + 0.3 * mid, -1, 1)
    img = base[None, None, :] + np.where(t[..., None] > 0, (sun - base) * t[..., None], (base - hollow) * t[..., None])
    fine = periodic_noise(N, 30, 90, SEED + 2)
    img += fine[..., None] * np.array([6, 7, 4], float)

    # brush tufts: drawn on an RGBA layer with every stroke repeated at the 8 wrap offsets (seamless)
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    dr = ImageDraw.Draw(layer)

    def wrapped_line(pts, fill, width):
        for ox in (-N, 0, N):
            for oy in (-N, 0, N):
                dr.line([(x + ox, y + oy) for x, y in pts], fill=fill, width=width)

    for _ in range(1000):
        cx, cy = rng.random() * N, rng.random() * N
        local = float(lo[int(cy) % N, int(cx) % N])
        blades = int(rng.integers(3, 7))
        h = 14 + rng.random() * 18
        lean = rng.normal(0.25, 0.25)
        for b in range(blades):
            a = lean + (b - blades / 2) * 0.22 + rng.normal(0, 0.08)
            L = h * (0.6 + rng.random() * 0.5)
            x0 = cx + (b - blades / 2) * 2.2
            x1, y1 = x0 + math.sin(a) * L, cy - math.cos(a) * L
            xm, ym = (x0 + x1) / 2 + math.sin(a) * 2, (cy + y1) / 2
            # dark root, lighter tip (sunlit drifts get yellower tips)
            root = (74, 116, 74, 95)
            tip = (176, 196, 104, 150) if local > 0.1 else (140, 178, 104, 140)
            wrapped_line([(x0, cy), (xm, ym)], root, 3)
            wrapped_line([(xm, ym), (x1, y1)], tip, 2)
    # clover / flower specks (pale cream and soft yellow, sparse)
    for _ in range(260):
        cx, cy = rng.random() * N, rng.random() * N
        col = (236, 226, 170, 170) if rng.random() < 0.6 else (226, 214, 236, 150)
        r = 1.6 + rng.random() * 1.4
        for ox in (-N, 0, N):
            for oy in (-N, 0, N):
                dr.ellipse([cx + ox - r, cy + oy - r, cx + ox + r, cy + oy + r], fill=col)
    layer = layer.filter(ImageFilter.GaussianBlur(0.7))
    la = np.asarray(layer, dtype=float)
    alpha = la[..., 3:4] / 255.0
    img = img * (1 - alpha) + la[..., :3] * alpha
    img = np.clip(img, 0, 255)
    color = Image.fromarray(img.astype(np.uint8), "RGB")
    D.mkdir(parents=True, exist_ok=True)
    color.save(D / f"{NAME}_color.png", optimize=True)

    # normal map: gentle, from the blurred luminance (as tools/vfx/make_tileable.py), wrapped differences
    h = np.asarray(color.convert("L").filter(ImageFilter.GaussianBlur(2.0)), dtype=float) / 255
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 2.0
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 2.0
    nrm = np.stack([-dx, dy, np.ones_like(h)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    Image.fromarray(((nrm * 0.5 + 0.5) * 255).astype(np.uint8)).save(D / f"{NAME}_normal.png", optimize=True)

    # neutral map + tint, tools/vfx/neutralize.py formula, for this tile only
    a = img / 255
    avg = a.reshape(-1, 3).mean(0)
    k = min(np.percentile((a / np.maximum(avg, 1e-3)).max(-1), 98), 1.15, 1 / avg.max())
    tint = np.clip(avg * k, 0, 1)
    n = np.clip(a / np.maximum(tint, 1e-3), 0, 1)
    Image.fromarray((n * 255).astype(np.uint8)).save(D / f"{NAME}_ncolor.png", optimize=True)
    tp = D / "tints.json"
    tints = json.loads(tp.read_text())
    tints[NAME] = "#%02x%02x%02x" % tuple(int(round(v * 255)) for v in tint)
    tp.write_text(json.dumps(tints, indent=1))
    print(NAME, tints[NAME], "k=%.2f" % k)


if __name__ == "__main__":
    main()
