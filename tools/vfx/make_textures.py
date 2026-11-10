#!/usr/bin/env python3
"""Owned VFX texture set for SkyRally (ART_BAR Polish bar; rights-clean, no third-party art).
Procedural, painterly sprites in the Sunshine/Raiser palette, white-on-alpha where the effect is tinted in engine
(ParticleEmitter.Color / Beam.Color), coloured where the texture carries the look. Flipbooks use Roblox layouts
(2x2, 4x4, 8x8 grids). Output: assets/vfx/*.png + assets/vfx/manifest.json (name, size, layout, use).
Deterministic (fixed seeds)."""
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

OUT = Path(__file__).resolve().parents[2] / "assets" / "vfx"
OUT.mkdir(parents=True, exist_ok=True)
MAN = {}


def grid(n):
    y, x = np.mgrid[0:n, 0:n].astype(float)
    c = (n - 1) / 2
    return (x - c) / c, (y - c) / c


def value_noise(n, cells, seed):
    rng = np.random.default_rng(seed)
    g = rng.random((cells + 1, cells + 1))
    y, x = np.mgrid[0:n, 0:n] / n * cells
    x0, y0 = x.astype(int), y.astype(int)
    fx, fy = x - x0, y - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a = g[y0, x0] * (1 - fx) + g[y0, x0 + 1] * fx
    b = g[y0 + 1, x0] * (1 - fx) + g[y0 + 1, x0 + 1] * fx
    return a * (1 - fy) + b * fy


def fbm(n, seed, octaves=5, base=4):
    out, amp, tot = np.zeros((n, n)), 1.0, 0.0
    for o in range(octaves):
        out += value_noise(n, base * 2 ** o, seed + o) * amp
        tot += amp
        amp *= 0.5
    return out / tot


def save(name, rgba, use, layout="None", tint=True):
    img = Image.fromarray(np.clip(rgba * 255, 0, 255).astype(np.uint8), "RGBA")
    p = OUT / f"{name}.png"
    img.save(p)
    MAN[name] = {"file": f"assets/vfx/{name}.png", "size": list(img.size), "flipbook": layout, "tint": tint, "use": use}


def white_alpha(a):
    n = a.shape[0]
    rgba = np.ones((a.shape[0], a.shape[1], 4))
    rgba[..., 3] = np.clip(a, 0, 1)
    return rgba


def soft_glow(n=256):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    a = np.clip(1 - r, 0, 1) ** 2.2
    save("glow_soft", white_alpha(a), "soft radial glow: ring/pad halos, engine glow, pickups")


def spark(n=256):
    x, y = grid(n)
    core = np.exp(-(x / 0.9) ** 2 * 1.0 - (y / 0.06) ** 2)
    halo = np.exp(-(x / 1.0) ** 2 * 2 - (y / 0.22) ** 2) * 0.35
    taper = np.clip(1 - np.abs(x), 0, 1) ** 0.6
    a = (core + halo) * taper
    save("spark_streak", white_alpha(a / a.max()), "elongated spark: crash sparks, boost ignition (Orientation VelocityParallel)")


def ember(n=128):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    a = np.exp(-(r / 0.18) ** 2) + 0.4 * np.exp(-(r / 0.55) ** 2)
    save("ember", white_alpha(a / a.max()), "hot ember dot with halo: lava embers, fireball trails")


def star(n=256):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y) + 1e-6
    rays = np.exp(-(np.abs(x) / 0.035) ** 1.2) * np.clip(1 - np.abs(y), 0, 1) ** 2 + \
        np.exp(-(np.abs(y) / 0.035) ** 1.2) * np.clip(1 - np.abs(x), 0, 1) ** 2
    diag = (np.exp(-(np.abs(x - y) / 0.05)) + np.exp(-(np.abs(x + y) / 0.05))) * np.clip(1 - r, 0, 1) ** 3 * 0.45
    core = np.exp(-(r / 0.09) ** 2)
    a = np.clip(rays + diag + core, 0, 1)
    save("star_twinkle", white_alpha(a), "4-point twinkle: token award, coin, ring pass, finish")


def ring(n=512):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    a = np.exp(-((r - 0.82) / 0.05) ** 2) + 0.35 * np.exp(-((r - 0.7) / 0.14) ** 2) * (r < 0.82)
    save("shockwave_ring", white_alpha(np.clip(a, 0, 1)), "expanding shockwave ring: ring pass, landing, impact, portal open")


def smoke_flipbook(n=1024, frames=16, seed=11):
    cell = n // 4
    out = np.zeros((n, n, 4))
    base = fbm(cell, seed, 5, 3)
    for f in range(frames):
        t = f / (frames - 1)
        x, y = grid(cell)
        r = np.sqrt(x * x + (y * 1.05) ** 2)
        swirl = fbm(cell, seed + 7 + f, 4, 3)
        edge = 0.72 + 0.22 * t + (base - 0.5) * 0.35 + (swirl - 0.5) * 0.25
        a = np.clip((edge - r) / 0.25, 0, 1) * (1 - t) ** 1.3
        shade = 0.72 + 0.28 * np.clip(-y * 0.8 + (base - 0.5), -1, 1)   # painterly top light
        rgba = np.zeros((cell, cell, 4))
        rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = np.clip(shade, 0, 1)
        rgba[..., 3] = a
        oy, ox = (f // 4) * cell, (f % 4) * cell
        out[oy:oy + cell, ox:ox + cell] = rgba
    save("smoke_puff_4x4", out, "billowing painterly smoke puff (16-frame flipbook): crash smoke, exhaust, dust, ash", "Grid4x4")


def fire_flipbook(n=1024, frames=16, seed=23):
    cell = n // 4
    out = np.zeros((n, n, 4))
    for f in range(frames):
        t = f / (frames - 1)
        x, y = grid(cell)
        up = (1 - y) / 2                      # 0 at the bottom row, 1 at the top: flames widest at the base
        nz = fbm(cell, seed + f * 3, 5, 4)
        sway = (value_noise(cell, 3, seed + 100 + f) - 0.5) * 0.35 * up
        halfw = 0.58 * (1 - up) ** 0.7 + 0.04
        shape = np.clip(1 - np.abs(x - sway) / halfw, 0, 1)
        heat = np.clip(shape * (1 - up * (0.55 + 0.5 * t)) + (nz - 0.5) * 0.55, 0, 1)
        a = np.clip(heat * 2.0 - 0.2, 0, 1) * (1 - t) ** 0.7 * np.clip(up / 0.14, 0, 1)
        col = np.stack([np.ones_like(heat), np.clip(0.2 + heat * 0.9, 0, 1), np.clip(heat ** 3 * 0.85, 0, 1)], -1)
        rgba = np.concatenate([col, a[..., None]], -1)
        oy, ox = (f // 4) * cell, (f % 4) * cell
        out[oy:oy + cell, ox:ox + cell] = rgba
    save("fire_lick_4x4", out, "stylized flame lick (coloured flipbook): fireballs, lava bursts, boss flames, explosions", "Grid4x4", tint=False)


def explosion_flipbook(n=1024, frames=16, seed=31):
    cell = n // 4
    out = np.zeros((n, n, 4))
    base = fbm(cell, seed, 5, 3)
    for f in range(frames):
        t = f / (frames - 1)
        x, y = grid(cell)
        r = np.sqrt(x * x + y * y)
        rad = 0.45 + 0.5 * (1 - (1 - t) ** 2)
        nz = fbm(cell, seed + 5 + f, 4, 4)
        body = np.clip((rad + (base - 0.5) * 0.3 + (nz - 0.5) * 0.25 - r) / 0.18, 0, 1)
        heat = np.clip(1 - t * 1.4 + (0.5 - r) * 0.8, 0, 1)
        a = body * (1 - t ** 2.5)
        col = np.stack([np.clip(0.35 + heat, 0, 1), np.clip(0.2 + heat * 0.75, 0, 1), np.clip(0.18 + heat ** 3 * 0.6, 0, 1)], -1)
        rgba = np.concatenate([col, a[..., None]], -1)
        oy, ox = (f // 4) * cell, (f % 4) * cell
        out[oy:oy + cell, ox:ox + cell] = rgba
    save("explosion_4x4", out, "fireball explosion (coloured flipbook): missile hits, mine, crash burst, boss defeat", "Grid4x4", tint=False)


def shard(n=128, seed=5):
    rng = np.random.default_rng(seed)
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    from PIL import ImageDraw
    d = ImageDraw.Draw(img)
    pts = [(n * 0.5 + math.cos(a) * n * r, n * 0.5 + math.sin(a) * n * r)
           for a, r in zip(sorted(rng.random(6) * 2 * math.pi), 0.28 + rng.random(6) * 0.18)]
    d.polygon(pts, fill=(255, 255, 255, 255))
    d.line(pts[:3], fill=(205, 205, 205, 255), width=4)   # faceted highlight edge, Raiser read
    a = np.array(img).astype(float) / 255
    MAN_save_rgba("debris_shard", a, "faceted rock/stone debris chip: impacts, crash debris, boulder hazards")


def MAN_save_rgba(name, a, use):
    save(name, a, use)


def speed_line(w=1024, h=64):
    y, x = np.mgrid[0:h, 0:w].astype(float)
    xn, yn = x / (w - 1), (y - (h - 1) / 2) / ((h - 1) / 2)
    a = np.exp(-(yn / 0.25) ** 2) * np.clip(xn, 0, 1) ** 1.5 * np.clip((1 - xn) / 0.08, 0, 1)
    save("speed_line", white_alpha(a), "screen-space speed line (ImageLabel, boost/overcharge)")


def trail_ramp(w=256, h=64):
    y, x = np.mgrid[0:h, 0:w].astype(float)
    xn, yn = x / (w - 1), (y - (h - 1) / 2) / ((h - 1) / 2)
    nz = value_noise(max(w, h), 16, 3)[:h, :w]
    a = np.exp(-(yn / 0.55) ** 2) * (0.75 + 0.25 * nz)
    save("trail_soft", white_alpha(a), "soft trail/beam body with painterly streaks (Trail/Beam texture)")


def lightning(w=512, h=128, seed=9):
    rng = np.random.default_rng(seed)
    img = np.zeros((h, w))
    yv = h / 2
    pts = []
    for xi in range(0, w, 16):
        yv = np.clip(yv + rng.normal(0, 10), 18, h - 18)
        pts.append((xi, yv))
    from PIL import ImageDraw
    im = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(im)
    d.line(pts, fill=255, width=5)
    glow = im.filter(ImageFilter.GaussianBlur(9))
    core = np.array(im, float) / 255
    a = np.clip(core + np.array(glow, float) / 255 * 1.6, 0, 1)
    save("lightning_beam", white_alpha(a), "lightning bolt beam texture: storm boss, tesla rods, electric hazards")


def droplet(n=128):
    x, y = grid(n)
    r = np.sqrt(x * x + ((y + 0.15) * 1.35) ** 2)
    a = np.clip((0.55 - r) / 0.08, 0, 1)
    hl = np.exp(-(((x + 0.18) / 0.12) ** 2 + ((y + 0.25) / 0.12) ** 2))
    rgba = white_alpha(a)
    rgba[..., :3] = np.clip(0.75 + 0.25 * hl, 0, 1)[..., None]
    save("water_droplet", rgba, "water droplet/splash: shallows, tide, splash on landing")


def snowflake(n=128):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    th = np.arctan2(y, x)
    arms = np.exp(-((np.abs(np.sin(3 * th)) * r) / 0.05) ** 2) * (r < 0.85)
    a = np.clip(arms + np.exp(-(r / 0.15) ** 2), 0, 1)
    save("snowflake", white_alpha(a), "snowflake: SNOW ambience, snowball impacts")


def acorn_glint(n=128):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    a = np.clip(np.exp(-(r / 0.3) ** 2) + 0.6 * np.exp(-((r - 0.6) / 0.06) ** 2), 0, 1)
    save("pickup_glint", white_alpha(a), "pickup glint ring+core: acorns, eggs, coins, keys")


def leaf(n=128):
    # almond leaf with a midrib, white so the emitter tints it per zone (meadow green, autumn gold)
    x, y = grid(n)
    xr, yr = (x + y) / np.sqrt(2), (y - x) / np.sqrt(2)
    body = (xr / 0.9) ** 2 + (yr / 0.42) ** 2
    a = np.clip((1 - body) / 0.08, 0, 1)
    rib = np.exp(-(yr / 0.03) ** 2) * (np.abs(xr) < 0.85)
    rgba = white_alpha(a)
    rgba[..., :3] = np.clip(0.88 - 0.25 * rib, 0, 1)[..., None]
    save("leaf", rgba, "drifting leaf/petal: FOREST ambience, windmill gusts")


def confetti(n=64):
    # a soft-edged paper square; particles spin with random colours (victory confetti, hub celebration)
    x, y = grid(n)
    a = np.clip((0.72 - np.maximum(np.abs(x), np.abs(y) * 1.6)) / 0.06, 0, 1)
    save("confetti", white_alpha(a), "confetti square: finish celebration, hub find, unlocks")


def bubble(n=128):
    x, y = grid(n)
    r = np.sqrt(x * x + y * y)
    rim = np.exp(-((r - 0.8) / 0.07) ** 2)
    hl = np.exp(-(((x + 0.3) / 0.16) ** 2 + ((y + 0.35) / 0.12) ** 2))
    a = np.clip(0.18 * (r < 0.8) + rim + hl, 0, 1)
    save("bubble", white_alpha(a), "bubble: ISLAND shallows and lagoon, water battle")


def main():
    soft_glow(); spark(); ember(); star(); ring()
    smoke_flipbook(); fire_flipbook(); explosion_flipbook()
    shard(); speed_line(); trail_ramp(); lightning(); droplet(); snowflake(); acorn_glint()
    leaf(); confetti(); bubble()
    (OUT / "manifest.json").write_text(json.dumps(MAN, indent=1))
    print(len(MAN), "textures:", ", ".join(MAN))


if __name__ == "__main__":
    main()
