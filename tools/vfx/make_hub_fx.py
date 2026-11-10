#!/usr/bin/env python3
"""HUB-0 ambient life textures (owned, procedural, deterministic): a 2x2 seagull wing-flap flipbook and a soft surf-foam
patch, written to assets/vfx/hub_v1/. Upload with
  python3 tools/vfx/upload_set.py assets/vfx/hub_v1 SkyRally_ src/shared/HubFxAssets.luau HubFxAssets
It also writes the softened plaza map assets/materials/hub_v1/tiles/T1_PLAZA_STONE_softn.png (upload with
  python3 tools/vfx/upload_set.py assets/materials/hub_v1/tiles SkyRally_HUB_ src/shared/materials_hub.luau MaterialsHub
tools/map/author_hub0.py reads assets/vfx/hub_v1/uploaded.json for the ids it writes into the plan's fx block.
Usage: make_hub_fx.py"""
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "vfx" / "hub_v1"
SS = 4  # supersampling for clean edges


def gull_frame(size: int, lift: float) -> Image.Image:
    """One frame of a stylised gull seen head-on from slightly below (symmetric, so a particle reads right whichever
    way it drifts): white body and head, grey "M" wings with dark tips. lift in [-1, 1]: +1 wings up, -1 down."""
    S = size * SS
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    cx, cy = S * 0.5, S * 0.5
    span = S * 0.46
    outline = (60, 60, 68, 255)
    for side in (-1, 1):
        sh = (cx + side * S * 0.035, cy - S * 0.01)
        el = (cx + side * span * 0.42, cy - lift * S * 0.15 - S * 0.04)
        tip = (cx + side * span, cy - lift * S * 0.28 + S * 0.06 * (1 - abs(lift)))
        tip_b = (tip[0] - side * S * 0.06, tip[1] + S * 0.04)
        trail_el = (el[0] + side * S * 0.01, el[1] + S * 0.075)
        trail_sh = (sh[0], sh[1] + S * 0.07)
        d.polygon([sh, el, tip, tip_b, trail_el, trail_sh], fill=(212, 218, 226, 255), outline=outline)
        t0 = (el[0] + (tip[0] - el[0]) * 0.6, el[1] + (tip[1] - el[1]) * 0.6)
        t1 = (trail_el[0] + (tip_b[0] - trail_el[0]) * 0.6, trail_el[1] + (tip_b[1] - trail_el[1]) * 0.6)
        d.polygon([t0, tip, tip_b, t1], fill=(46, 48, 56, 255))
    bw, bh = S * 0.075, S * 0.13
    d.ellipse([cx - bw / 2, cy - bh * 0.35, cx + bw / 2, cy + bh * 0.65], fill=(250, 250, 248, 255), outline=outline,
              width=SS * 2)
    hr = S * 0.038
    d.ellipse([cx - hr, cy - bh * 0.35 - hr * 1.6, cx + hr, cy - bh * 0.35 + hr * 0.4], fill=(252, 252, 250, 255),
              outline=outline, width=SS * 2)
    d.polygon([(cx - S * 0.012, cy - bh * 0.35 - hr * 0.2), (cx + S * 0.012, cy - bh * 0.35 - hr * 0.2),
               (cx, cy - bh * 0.35 + hr * 0.9)], fill=(240, 176, 52, 255))
    return im.resize((size, size), Image.LANCZOS)


def gull_sheet() -> Image.Image:
    cell = 256
    sheet = Image.new("RGBA", (cell * 2, cell * 2), (0, 0, 0, 0))
    for k, lift in enumerate((0.9, 0.25, -0.55, 0.25)):  # row-major: up, mid, down, mid (Grid2x2 loop)
        sheet.paste(gull_frame(cell, lift), ((k % 2) * cell, (k // 2) * cell))
    return sheet


def foam_patch() -> Image.Image:
    """Soft white surf foam: a broken ring of bubbly lace around a fading centre, alpha only (tinted in engine)."""
    n = 256
    rng = np.random.default_rng(20261019)
    y, x = np.mgrid[0:n, 0:n] / (n - 1) * 2 - 1
    r = np.hypot(x, y)
    a = np.arctan2(y, x)
    noise = np.zeros((n, n))
    for octave in range(4):
        f = 2 ** (octave + 2)
        g = rng.random((f + 1, f + 1))
        gi = Image.fromarray((g * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC)
        noise += np.asarray(gi, dtype=float) / 255.0 / (octave + 1)
    noise /= sum(1 / (o + 1) for o in range(4))
    ring = np.exp(-((r - 0.62 - 0.08 * np.sin(a * 5)) / 0.16) ** 2)
    centre = 0.35 * np.clip(1 - r / 0.7, 0, 1)
    lace = np.clip((noise - 0.42) * 3.2, 0, 1)
    alpha = np.clip((ring * 0.9 + centre) * (0.35 + 0.9 * lace), 0, 1) * np.clip((1 - r) * 4, 0, 1)
    img = np.zeros((n, n, 4), dtype=np.uint8)
    img[..., :3] = 255
    img[..., 3] = (alpha * 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA").filter(ImageFilter.GaussianBlur(0.8))


def soft_plaza() -> None:
    """assets/materials/hub_v1/tiles/T1_PLAZA_STONE_softn.png: the plaza/road neutral map with its contrast (the
    orange grout lines) pulled 40% toward the mean, for SR_HUB_PlazaStone's colorMap (critic L61: busy road noise)."""
    tiles = ROOT / "assets" / "materials" / "hub_v1" / "tiles"
    a = np.asarray(Image.open(tiles / "T1_PLAZA_STONE_ncolor.png").convert("RGB"), dtype=float)
    mean = a.reshape(-1, 3).mean(0)
    Image.fromarray(np.clip(mean + (a - mean) * 0.6, 0, 255).astype(np.uint8)).save(tiles / "T1_PLAZA_STONE_softn.png")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    soft_plaza()
    gull_sheet().save(OUT / "gull_flap_2x2.png")
    foam_patch().save(OUT / "surf_foam.png")
    print("wrote", ", ".join(str(p.relative_to(ROOT)) for p in sorted(OUT.glob("*.png"))))


if __name__ == "__main__":
    main()
