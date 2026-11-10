#!/usr/bin/env python3
"""Low-graphics-safe terrain materials. Roblox renders terrain without detail textures at low quality levels, using only
the terrain material colour; with a white colour the caves rendered white on the published client (2026-10-18 v12).
For each tiles/T*_color.png this writes tiles/<name>_ncolor.png = texture / tint (a neutral detail map) and records the
tint (the texture's average colour, scaled so the neutral map stays within range) in tiles/tints.json.
At high quality texture x tint reproduces the painted look; at low quality the tint alone carries the colour.
Usage: neutralize.py <set_dir>"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

D = Path(sys.argv[1]) / "tiles"
tints = {}
for f in sorted(D.glob("T*_color.png")):
    a = np.asarray(Image.open(f).convert("RGB"), dtype=float) / 255
    avg = a.reshape(-1, 3).mean(0)
    # scale so 98% of pixels fit under 1 after division, but the tint itself must stay a valid colour
    # capped at 1.15 so the low-quality tint stays close to the true average (1.4 still read washed out on the
    # published hub plaza; basalt once reached 3.6 and read pale pink). Highlights above 1.15x the mean clip slightly.
    k = min(np.percentile((a / np.maximum(avg, 1e-3)).max(-1), 98), 1.15, 1 / avg.max())
    tint = np.clip(avg * k, 0, 1)
    n = np.clip(a / np.maximum(tint, 1e-3), 0, 1)
    name = f.stem[: -len("_color")]
    Image.fromarray((n * 255).astype(np.uint8)).save(D / f"{name}_ncolor.png")
    tints[name] = "#%02x%02x%02x" % tuple(int(round(v * 255)) for v in tint)
    print(name, tints[name], "k=%.2f" % k)
(D / "tints.json").write_text(json.dumps(tints, indent=1))
