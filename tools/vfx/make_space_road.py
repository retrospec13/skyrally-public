#!/usr/bin/env python3
"""SPACE-4 L61 road texture T7_ROAD_PANELS (owned, procedural, deterministic).

The Higgsfield T1_METAL_PLATES tile is a teal/cream patchwork of odd-shaped plates with rivets on every edge; on the
road it read as "random metal plate collage, placeholder" (critic r1/r2). This tile is a calm, deliberate module: two
columns of long plates in a staggered running bond, one value family (light neutral grey-blue, so the kit's paver
colours carry the hue), thin dark seams with a soft bevel highlight, rivets only at the plate corners, a faint brushed
grain and low-frequency wear. Low contrast on purpose: the neon lane lines and the light do the work.
Writes assets/materials/space_v1/tiles/T7_ROAD_PANELS_{color,normal}.png (1024, seamless).
Usage: make_space_road.py"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
D = ROOT / "assets" / "materials" / "space_v1" / "tiles"
NAME = "T7_ROAD_PANELS"
N = 1024
SEED = 4471


def periodic_noise(n, freq_lo, freq_hi, seed):
    """Seamless band-limited noise in [-1, 1] (random phases on an integer frequency ring)."""
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
    y, x = np.mgrid[0:N, 0:N].astype(float)
    cols, rows = 2, 4
    pw, ph = N / cols, N / rows
    row = np.floor(y / ph)
    xs = (x + (row % 2) * pw / 2) % N  # running bond: odd rows shift half a plate
    col = np.floor(xs / pw)
    u, v = xs - col * pw, y - row * ph  # position inside the plate
    pid = (row * cols + col).astype(int)
    tone = rng.uniform(-6, 6, rows * cols)[pid]  # each plate a hair lighter or darker
    base = np.array([196, 202, 214], float)
    img = base[None, None, :] + tone[..., None]
    wear = periodic_noise(N, 2, 8, SEED + 1)
    img += wear[..., None] * np.array([7, 7, 8])
    grain = periodic_noise(N, 120, 300, SEED + 2)
    img += grain[..., None] * 3.0
    # seams (dark) and bevel highlight just inside the top/left edges
    edge = np.minimum.reduce([u, v, pw - u, ph - v])
    seam = edge < 3.0
    bevel = (edge >= 3.0) & (edge < 7.0) & ((u < 7.0) | (v < 7.0))
    shade = (edge >= 3.0) & (edge < 7.0) & ~((u < 7.0) | (v < 7.0))
    img[seam] = np.array([92, 98, 116])
    img[bevel] += 16
    img[shade] -= 14
    # rivets at the plate corners only
    for cu in (14.0, pw - 14.0):
        for cv in (14.0, ph - 14.0):
            d = np.hypot(u - cu, v - cv)
            img[d < 5.0] = np.array([150, 156, 172])
            img[(d < 3.0) & (u - cu < 0) & (v - cv < 0)] = np.array([226, 230, 238])
    img = np.clip(img, 0, 255)
    color = Image.fromarray(img.astype(np.uint8), "RGB")
    D.mkdir(parents=True, exist_ok=True)
    color.save(D / f"{NAME}_color.png", optimize=True)
    h = np.asarray(color.convert("L").filter(ImageFilter.GaussianBlur(1.5)), dtype=float) / 255
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 2.5
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 2.5
    nrm = np.stack([-dx, dy, np.ones_like(h)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    Image.fromarray(((nrm * 0.5 + 0.5) * 255).astype(np.uint8)).save(D / f"{NAME}_normal.png", optimize=True)
    print(NAME, "written")


if __name__ == "__main__":
    main()
