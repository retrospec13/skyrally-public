#!/usr/bin/env python3
"""High-pass the terrain detail tiles that show large straight-edged tint patches on cliffs (MAP_SURFACE_PLAN item 5).

For each tile: (1) divide out the low-frequency drift (wrapped Gaussian blur, sigma ~128 px) and rescale to the original
per-channel mean; (2) fix the wrap seams with a half-tile-offset cross-fade (the rolled copy has its seam in the middle,
the original has it at the edges; a mask that is 0 at the edges and 1 in the middle picks the clean side everywhere).
Normal maps carry slope, not brightness, so their xy is high-passed by subtraction (mean 0) and z is rebuilt.

Writes <name>_hp.png next to each original (originals untouched, no ids change) and a before/after contact sheet
(each tile repeated 2x2 so seams and patches show). The integrator uploads the _hp files and points the matching
MaterialVariants at the new ids; this script uploads nothing.

Usage: highpass_tiles.py [--sigma 128] [--band 0.28] [--sheet out/highpass_sheet.png]
"""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

ROOT = Path(__file__).resolve().parents[2]
TILES = ROOT / "assets" / "materials"
# (set dir, tile) -> which MaterialVariant(s) use it
SOURCES = [
    ("island_v1", "T7_COAST_ROCK", "SR_ISLAND_Rock (terrain Rock), SR_ISLAND_Masonry (parts)"),
    ("island_v1", "T9_COVE_COBBLE", "SR_ISLAND_Cobble (parts)"),
    ("snow_v1", "T4_GRANITE_SNOWCAP", "SR_SNOW_Rock (terrain Rock), SR_SNOW_Fieldstone (parts)"),
]
KINDS = ("ncolor", "color", "normal")


def blur(a, sigma):
    return gaussian_filter(a, sigma=(sigma, sigma, 0), mode="wrap")


def ramp(n, band):
    """0 at both ends, 1 across the middle, smoothstep over `band` (fraction of n) from each end."""
    x = np.minimum(np.arange(n), n - 1 - np.arange(n)) / (n * band)
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def needs_fix(a, axis):
    """True when the wrap seam on `axis` differs from the tile's own neighbour-row difference by more than 1.5x."""
    b = np.moveaxis(a.astype(np.float64), axis, 0)
    seam = float(np.abs(b[0] - b[-1]).mean())
    typical = float(np.abs(b[1:] - b[:-1]).mean())
    return seam > 1.5 * typical + 0.5


def seam_fix(a, band, fix_y=True, fix_x=True):
    my = ramp(a.shape[0], band) if fix_y else np.ones(a.shape[0])
    mx = ramp(a.shape[1], band) if fix_x else np.ones(a.shape[1])
    m = (my[:, None] * mx[None, :])[:, :, None]
    rolled = np.roll(a, (a.shape[0] // 2, a.shape[1] // 2), axis=(0, 1))
    return a * m + rolled * (1.0 - m)


def seam_err(a):
    a = a.astype(np.float64)
    return float(np.abs(a[0] - a[-1]).mean()), float(np.abs(a[:, 0] - a[:, -1]).mean())


def process_color(img, sigma, band):
    a = img.astype(np.float64)
    mean = a.mean(axis=(0, 1))
    low = np.maximum(blur(a, sigma), 1.0)
    a = a / low * mean
    a = seam_fix(a, band, needs_fix(img, 0), needs_fix(img, 1))
    a = a * (mean / np.maximum(a.mean(axis=(0, 1)), 1e-6))  # the cross-fade shifts the mean a little
    return np.clip(np.rint(a), 0, 255).astype(np.uint8)


def process_normal(img, sigma, band):
    a = img.astype(np.float64) / 255.0 * 2.0 - 1.0
    xy = a[:, :, :2]
    xy = xy - blur(xy, sigma)
    xy = seam_fix(xy, band, needs_fix(img, 0), needs_fix(img, 1))
    xy = xy - xy.mean(axis=(0, 1))
    z = np.sqrt(np.clip(1.0 - (xy ** 2).sum(axis=2), 0.0, 1.0))
    out = np.dstack([xy, z])
    return np.clip(np.rint((out * 0.5 + 0.5) * 255.0), 0, 255).astype(np.uint8)


def tiled(a):
    im = Image.fromarray(a).resize((256, 256), Image.LANCZOS)
    t = Image.new("RGB", (im.width * 2, im.height * 2))
    for i in range(2):
        for j in range(2):
            t.paste(im, (i * im.width, j * im.height))
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sigma", type=float, default=128.0)
    ap.add_argument("--band", type=float, default=0.28)
    ap.add_argument("--sheet", default=str(ROOT / "out" / "highpass_sheet.png"))
    a = ap.parse_args()
    rows, written = [], []
    for sdir, tile, used in SOURCES:
        for kind in KINDS:
            src = TILES / sdir / "tiles" / f"{tile}_{kind}.png"
            img = np.array(Image.open(src).convert("RGB"))
            out = process_normal(img, a.sigma, a.band) if kind == "normal" else process_color(img, a.sigma, a.band)
            dst = src.with_name(f"{tile}_{kind}_hp.png")
            Image.fromarray(out).save(dst, optimize=True)
            written.append((dst.relative_to(ROOT), used))
            b, f = seam_err(img), seam_err(out)
            blk = lambda x: [round(float(x[i * 128:(i + 1) * 128, j * 128:(j + 1) * 128].mean()), 1)
                             for i in range(0, 8, 3) for j in range(0, 8, 3)]
            print(f"{sdir}/{tile}_{kind}: seam top/bottom {b[0]:.1f}->{f[0]:.1f} left/right {b[1]:.1f}->{f[1]:.1f}"
                  f" | block means {min(blk(img[..., 0])):.0f}..{max(blk(img[..., 0])):.0f}"
                  f" -> {min(blk(out[..., 0])):.0f}..{max(blk(out[..., 0])):.0f}")
            if kind != "color":
                rows.append((f"{tile}_{kind}", tiled(img), tiled(out)))
    w = rows[0][1].width
    sheet = Image.new("RGB", (w * 2 + 30, (rows[0][1].height + 8) * len(rows)), (24, 24, 24))
    for i, (_, before, after) in enumerate(rows):
        sheet.paste(before, (0, i * (before.height + 8)))
        sheet.paste(after, (w + 30, i * (before.height + 8)))
    Path(a.sheet).parent.mkdir(parents=True, exist_ok=True)
    sheet.save(a.sheet)
    print("rows (before | after):", [r[0] for r in rows])
    print("contact sheet:", a.sheet)
    print("upload:")
    for p, used in written:
        print(f"  {p}  ->  replaces the same tile minus _hp ({used})")


if __name__ == "__main__":
    main()
