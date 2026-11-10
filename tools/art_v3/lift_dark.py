#!/usr/bin/env python3
"""Lift only the darkest albedo texels of a GLB (owner: dark assets read as black in game). v' = v + 0.27*(1-v/0.5)^2 for v<0.5
(max-channel value), hue kept. Usage: lift_dark.py <in.glb> <out.glb>"""
import subprocess, sys, tempfile, os
import numpy as np
from PIL import Image
here = os.path.dirname(os.path.abspath(__file__))
src, dst = sys.argv[1], sys.argv[2]
t = tempfile.mkdtemp()
subprocess.run(["python3", f"{here}/glbtex.py", "extract", src, f"{t}/a.png"], check=True)
a = np.asarray(Image.open(f"{t}/a.png").convert("RGB")).astype(np.float32) / 255
v = a.max(2)
add = np.where(v < 0.5, 0.27 * (1 - v / 0.5) ** 2, 0)
vn = v + add
f = np.where(v > 1e-4, vn / np.maximum(v, 1e-4), 1)
b = a * f[..., None]
b = np.where((v <= 1e-4)[..., None], vn[..., None], b)
Image.fromarray((np.clip(b, 0, 1) * 255 + 0.5).astype(np.uint8)).save(f"{t}/b.png")
subprocess.run(["python3", f"{here}/glbtex.py", "replace", src, f"{t}/b.png", dst], check=True)
print("lifted", dst, "min v", round(float(np.clip(vn, 0, 1).min()), 3))
