#!/usr/bin/env python3
"""512 painted atlas for the procedural windmill sails: left half caramel timber (grain along texture v), right half muted cream cloth.
Colours are the tower's own (tower texture medians: cream 237,219,179 -> x0.6 sat / x0.92 val; wood caramel)."""
import sys
import numpy as np
from PIL import Image, ImageFilter
rng = np.random.default_rng(7)
N = 512
img = np.zeros((N, N, 3), np.float32)
def smooth(a, r):
    k = np.exp(-0.5 * (np.arange(-int(3 * r) - 1, int(3 * r) + 2) / r) ** 2)
    k /= k.sum()
    a = np.apply_along_axis(lambda v: np.convolve(np.pad(v, len(k) // 2, mode="wrap"), k, "valid"), 0, a)
    return np.apply_along_axis(lambda v: np.convolve(np.pad(v, len(k) // 2, mode="wrap"), k, "valid"), 1, a)
yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
# timber (x < 256)
base = np.array([178, 120, 63], np.float32)
streak = smooth(rng.normal(0, 1, (N, N)), 1.0)
streak = np.repeat(rng.normal(0, 1, (N, N // 8)).astype(np.float32), 8, axis=1)  # long vertical streaks
streak = smooth(streak, 1.2)
streak /= max(1e-6, np.abs(streak).max())
t = np.zeros((N, 256, 3), np.float32)
for c in range(3):
    t[..., c] = base[c] * (1 + 0.16 * streak[:, :256])
# painted edge highlights / shade on the timber block
ex = np.minimum(xx[:, :256], 255 - xx[:, :256])
t *= (0.86 + 0.14 * np.clip(ex / 14.0, 0, 1))[..., None]
t += (np.clip(1 - ex / 6.0, 0, 1) * 10)[..., None]
img[:, :256] = t
# cloth (x >= 256)
cream = np.array([226, 210, 172], np.float32)
blot = smooth(rng.normal(0, 1, (N, N)), 14)
blot /= max(1e-6, np.abs(blot).max())
weave = smooth(rng.normal(0, 1, (N, N)), 2.5)
weave /= max(1e-6, np.abs(weave).max())
c = np.zeros((N, 256, 3), np.float32)
for k in range(3):
    c[..., k] = cream[k] * (1 + 0.05 * blot[:, 256:] + 0.02 * weave[:, 256:])
img[:, 256:] = c
Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(sys.argv[1])
