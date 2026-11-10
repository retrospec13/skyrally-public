#!/usr/bin/env python3
"""Crop the four-view boss guides (assets/concepts/launch_guides_v1/B*.png: FRONT, LEFT SIDE / REAR, THREE-QUARTER)
into Tripo multiview inputs: front, left, back, plus right = mirrored left (the designs are bilaterally symmetric).
The view label strip under each quadrant is cut; each view is padded square on the guide's own background colour.
Usage: boss_views.py  -> assets/models/bosses/<key>/views/{front,left,back,right}.png"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
GUIDES = {
    "dino_boss": "B1_DINO_BOSS_CINDERWING",
    "snow_boss": "B2_SNOW_BOSS_FROSTHORN",
    "island_boss": "B3_ISLAND_BOSS_CLATTERSHELL",
    "forest_boss": "B4_FOREST_BOSS_EMBERBEETLE",
    "hub_boss": "B5_HUB_BOSS_THUNDERWRIGHT",
}


def square(im: Image.Image, bg) -> Image.Image:
    a = np.asarray(im.convert("RGB")).astype(int)
    diff = np.abs(a - np.array(bg)).sum(-1) > 40
    ys, xs = np.where(diff)
    if len(xs):
        pad = 24
        im = im.crop((max(0, xs.min() - pad), max(0, ys.min() - pad), min(im.width, xs.max() + pad), min(im.height, ys.max() + pad)))
    s = max(im.size)
    out = Image.new("RGB", (s, s), tuple(bg))
    out.paste(im, ((s - im.width) // 2, (s - im.height) // 2))
    return out.resize((1024, 1024), Image.LANCZOS)


# Row bands (fractions of the guide height, view labels excluded) holding front, left, rear in reading order; B1 is a
# 2x2 sheet (front | left over rear | three-quarter), B4 uses its lower row, B5 its upper row.
BANDS = {
    "dino_boss": [(0.0, 0.445), (0.5, 0.93)],
    "snow_boss": [(0.04, 0.865)],
    "island_boss": [(0.12, 0.815)],
    "forest_boss": [(0.49, 0.835)],
    "hub_boss": [(0.03, 0.47)],
}


def segments(band: Image.Image, bg) -> list:
    a = np.asarray(band).astype(int)
    fg = np.abs(a - np.array(bg)).sum(-1) > 40
    cols = fg.sum(0) > 2
    out, x, w = [], 0, len(cols)
    while x < w:
        if cols[x]:
            x0 = x
            gap = 0
            while x < w and gap < 14:
                gap = 0 if cols[x] else gap + 1
                x += 1
            x1 = x - gap
            if x1 - x0 > w * 0.05:
                out.append((x0, x1))
        else:
            x += 1
    return out


for key, name in GUIDES.items():
    g = Image.open(ROOT / "assets/concepts/launch_guides_v1" / f"{name}.png").convert("RGB")
    w, h = g.size
    bg = np.median(np.asarray(g)[:20, :, :].reshape(-1, 3), axis=0).astype(int)
    crops = []
    for y0, y1 in BANDS[key]:
        band = g.crop((0, int(y0 * h), w, int(y1 * h)))
        for x0, x1 in segments(band, bg):
            crops.append(band.crop((x0, 0, x1, band.height)))
    out = ROOT / "assets/models/bosses" / key / "views"
    out.mkdir(parents=True, exist_ok=True)
    names = ["front", "left", "back", "three_quarter"]
    views = {}
    for v, c in zip(names, crops):
        views[v] = square(c, bg)
        views[v].save(out / f"{v}.png")
    ImageOps.mirror(views["left"]).save(out / "right.png")
    print(key, len(crops), "views ->", out.relative_to(ROOT))
