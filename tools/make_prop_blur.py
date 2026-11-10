#!/usr/bin/env python3
"""Write the 256x256 RGBA prop-blur texture for the hero plane v3 blur disc.

Soft radial streaks in the prop's varnished-wood colour: two blade trails (a two-blade prop smears into two sweeps)
over fine angular streak noise, mean alpha about 0.35, clear in the middle (the spinner covers it) and fading at the rim.
UVs on prop_blur_disc.glb are planar with the disc centre at (0.5, 0.5).
"""
import sys
import numpy as np
from PIL import Image

out = sys.argv[1] if len(sys.argv) > 1 else "prop_blur.png"
N = 256
rng = np.random.default_rng(7)
y, x = np.mgrid[0:N, 0:N]
u = (x + 0.5) / N * 2 - 1
v = (y + 0.5) / N * 2 - 1
r = np.hypot(u, v)
th = np.arctan2(v, u)
# fine streaks: smooth random function of angle (sum of a few harmonics) and of radius (rings)
ang = np.zeros_like(th)
for k in range(3, 40, 3):
    ang += rng.uniform(0.2, 1.0) / k ** 0.6 * np.cos(k * th + rng.uniform(0, 2 * np.pi))
ang = (ang - ang.min()) / (ang.max() - ang.min())
rings = 0.5 + 0.5 * np.cos(r * 38 + rng.uniform(0, 6))
# two blade trails: bright at the blade angle, decaying behind it
trail = np.zeros_like(th)
for b in range(2):
    d = np.mod(th - b * np.pi, 2 * np.pi)  # angle behind the blade
    trail += np.exp(-d / 0.9)
trail /= trail.max()
radial = np.clip((r - 0.16) / 0.12, 0, 1) * np.clip((1.0 - r) / 0.12, 0, 1)  # clear hub, soft rim
a = radial * (0.18 + 0.32 * trail + 0.14 * ang + 0.06 * rings)
a = a * (0.35 / a[r < 1].mean() * (radial[r < 1].mean()))  # mean alpha over the blade annulus ~0.35
a = np.clip(a, 0, 0.75)
wood = np.array([132, 86, 46], float)
cream = np.array([226, 214, 188], float)
mix = (0.25 * trail + 0.15 * ang)[..., None]
rgb = wood * (1 - mix) + cream * mix
img = np.dstack([rgb, a[..., None] * 255]).clip(0, 255).astype(np.uint8)
Image.fromarray(img, "RGBA").save(out)
ann = (r > 0.28) & (r < 0.88)
print("prop blur", out, "mean alpha annulus %.3f max %.3f" % (a[ann].mean(), a.max()))
