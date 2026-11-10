#!/usr/bin/env python3
"""Make generated material textures seamless and derive normal maps (MaterialVariant inputs).
Usage: make_tileable.py <set_dir>  -> <set_dir>/tiles/<name>_color.png, <name>_normal.png (1024x1024)
Seam method: crossfade the image with a half-offset copy using a centre-weighted mask, so the output's borders come
from the copy's interior (which wraps) and its centre stays the original. Normal map: Sobel of a blurred luminance
height, OpenGL (+Y up) convention, gentle strength so the painted shading stays the main read."""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

D = Path(sys.argv[1])
OUT = D / "tiles"
OUT.mkdir(exist_ok=True)
N = 1024
for f in sorted(D.glob("T*.png")):
    a = np.asarray(Image.open(f).convert("RGB").resize((N, N), Image.LANCZOS), dtype=float) / 255
    b = np.roll(np.roll(a, N // 2, 0), N // 2, 1)
    y, x = np.mgrid[0:N, 0:N] / (N - 1)
    w = np.minimum(np.minimum(x, 1 - x), np.minimum(y, 1 - y)) * 2   # 0 at border, 1 at centre
    w = np.clip((w - 0.08) / 0.5, 0, 1)
    w = (w * w * (3 - 2 * w))[..., None]
    t = a * w + b * (1 - w)
    Image.fromarray((t * 255).astype(np.uint8)).save(OUT / f"{f.stem}_color.png")
    h = Image.fromarray((t.mean(-1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2.2))
    hf = np.asarray(h, dtype=float) / 255
    dx = (np.roll(hf, -1, 1) - np.roll(hf, 1, 1)) * 2.2
    dy = (np.roll(hf, -1, 0) - np.roll(hf, 1, 0)) * 2.2
    nrm = np.stack([-dx, dy, np.ones_like(hf)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    Image.fromarray(((nrm * 0.5 + 0.5) * 255).astype(np.uint8)).save(OUT / f"{f.stem}_normal.png")
    # seam check: wrapped edge difference vs interior neighbour difference
    seam = np.abs(t[:, 0] - t[:, -1]).mean() + np.abs(t[0] - t[-1]).mean()
    inner = np.abs(t[:, N // 2] - t[:, N // 2 + 1]).mean() + np.abs(t[N // 2] - t[N // 2 + 1]).mean()
    print(f"{f.stem}: seam {seam:.4f} vs interior {inner:.4f}")
