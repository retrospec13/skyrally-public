#!/usr/bin/env python3
"""Procedural celebration textures (assets/vfx/celebration/*.png) + a contact-sheet preview.
fireworks_burst_4x4.png: 512x512, 4x4 grid of 128px frames (row-major, one-shot). A firework shell opening: bright core
flash, a ring of comet streaks flying out and sagging, glitter dots trailing behind, everything fading. White RGB with
alpha (premultiply-safe, the emitter Color tints each shell); all shape lives in alpha."""
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "vfx", "celebration")
os.makedirs(OUT, exist_ok=True)
F = 128  # frame size
SS = 2  # supersample
N = F * SS
y, x = np.mgrid[0:N, 0:N].astype(np.float64)
cx = (N - 1) / 2
px, py = (x - cx) / (N / 2), (y - cx) / (N / 2)  # -1..1


def sm(a, b, v):
    t = np.clip((v - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def seg_dist(ax, ay, bx, by):
    """Distance from every pixel to the segment a-b, plus the 0..1 position along it."""
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy + 1e-9
    t = np.clip(((px - ax) * dx + (py - ay) * dy) / l2, 0, 1)
    return np.hypot(px - (ax + t * dx), py - (ay + t * dy)), t


rng = np.random.default_rng(11)
RAYS = 22
ang = np.linspace(0, 2 * np.pi, RAYS, endpoint=False) + rng.random(RAYS) * 0.12
reach = 0.62 + 0.18 * (np.arange(RAYS) % 2)  # alternate long/short rays
GLIT = 46
gang = rng.random(GLIT) * 2 * np.pi
greach = 0.25 + 0.6 * rng.random(GLIT)
gphase = rng.random(GLIT) * 0.25


def frame(t):
    a = np.zeros((N, N))
    ease = 1 - (1 - t) ** 2.2
    fade = 1 - sm(0.45, 1.0, t)
    sag = 0.16 * t * t  # gravity pulls the whole burst down a little
    core = np.exp(-(np.hypot(px, py) / (0.16 * (1 - t) + 0.02)) ** 2) * (1 - sm(0.0, 0.35, t)) * 1.4
    a = np.maximum(a, core)
    for i in range(RAYS):  # comet streaks: head at reach*ease, tail trailing back toward the centre
        head = reach[i] * ease
        tail = max(head - (0.30 - 0.18 * t), 0.02)
        ca, sa = np.cos(ang[i]), np.sin(ang[i])
        hx, hy = ca * head, sa * head + sag * head
        tx, ty = ca * tail, sa * tail + sag * tail
        d, u = seg_dist(tx, ty, hx, hy)
        w = 0.012 + 0.014 * u  # thicker at the head
        a = np.maximum(a, np.exp(-(d / w) ** 2) * (0.35 + 0.65 * u) * fade)
        hd = np.hypot(px - hx, py - hy)
        a = np.maximum(a, np.exp(-(hd / 0.035) ** 2) * fade * 1.2)
    for i in range(GLIT):  # glitter: small dots that appear a bit later and twinkle out
        tt = np.clip((t - gphase[i]) / (1 - gphase[i]), 0, 1)
        if tt <= 0:
            continue
        r = greach[i] * (1 - (1 - tt) ** 2)
        gx, gy = np.cos(gang[i]) * r, np.sin(gang[i]) * r + 0.2 * tt * tt
        tw = 0.5 + 0.5 * np.sin(tt * 18 + i)
        a = np.maximum(a, np.exp(-(np.hypot(px - gx, py - gy) / 0.018) ** 2) * (1 - tt) ** 0.7 * tw)
    return a


sheet = np.zeros((F * 4, F * 4))
for i in range(16):
    f = frame(i / 15.0)
    f = f.reshape(F, SS, F, SS).mean(axis=(1, 3))
    f = np.clip(f * 1.15, 0, 1)
    r, c = divmod(i, 4)
    sheet[r * F:(r + 1) * F, c * F:(c + 1) * F] = f

img = np.zeros((F * 4, F * 4, 4), np.uint8)
img[..., :3] = 255
img[..., 3] = (sheet * 255 + 0.5).astype(np.uint8)
Image.fromarray(img, "RGBA").save(os.path.join(OUT, "fireworks_burst_4x4.png"))

# preview: warm tint over a dark sky, 2x
tint = np.array([255, 190, 80]) / 255
prev = np.clip(sheet[..., None] * tint + 0.03, 0, 1)
Image.fromarray((prev * 255).astype(np.uint8)).resize((F * 8, F * 8), Image.LANCZOS).save(os.path.join(OUT, "preview_fireworks_burst_4x4.png"))
print("ok")
