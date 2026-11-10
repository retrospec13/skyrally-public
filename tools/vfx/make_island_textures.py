#!/usr/bin/env python3
"""ISLAND-2 L61 textures (owned, procedural, deterministic): T7_COAST_ROCK, T8_SEA_GRASS, T9_COVE_COBBLE.

Critic r0 (evidence/L61/critic_island2_r0.md): "lime-green cliff faces", "neon greens", "route surface looks like a
generic tiled test track". The Higgsfield T3_COASTAL_ROCK tile carries bright green grass ledges baked into the rock
(no terrain tint can remove them: the cliffs read as a green chequerboard), T4_GRASS_TROPICAL is a framed, banded tile
that repeats as a grid, and T6_CREAM_COBBLE has a saturated terracotta mortar grid. These replace them:
  T7_COAST_ROCK   faceted warm sandstone / grey coastal rock: Voronoi blocks with a lit upper-left bevel, dark cracks
                  and soft horizontal strata, no vegetation (terrain Rock, the cavern and the masonry).
  T8_SEA_GRASS    soft olive sea-grass: low-frequency sunlit drifts and blue-green hollows, short brush tufts, sandy
                  bare patches and a few hibiscus/frangipani specks (terrain Grass).
  T9_COVE_COBBLE  irregular rounded beach cobbles in cream, sand, driftwood grey and pale coral, a muted sandy-umber
                  mortar and drifted sand in the joints (the road pavers).
All tiles are periodic (seamless). Writes assets/materials/island_v1/tiles/<NAME>_{color,ncolor,normal}.png (1024)
and their tints into tiles/tints.json with the tools/vfx/neutralize.py formula (only these tiles change).
Usage: make_island_textures.py"""
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
D = ROOT / "assets" / "materials" / "island_v1" / "tiles"
N = 1024


def periodic_noise(n, freq_lo, freq_hi, seed):
    """Seamless band-limited noise in [-1, 1]: random phases on an integer frequency ring (periodic by construction)."""
    rng = np.random.default_rng(seed)
    fy = np.fft.fftfreq(n) * n
    fx = np.fft.rfftfreq(n) * n
    FY, FX = np.meshgrid(fy, fx, indexing="ij")
    r = np.hypot(FX, FY)
    amp = np.where((r >= freq_lo) & (r <= freq_hi), 1.0 / np.maximum(r, 1.0), 0.0)
    spec = amp * np.exp(2j * np.pi * rng.random(amp.shape))
    out = np.fft.irfft2(spec, s=(n, n))
    out -= out.mean()
    return out / (np.abs(out).max() + 1e-9)


def voronoi(n, pts):
    """Periodic Voronoi: (nearest index, d1, d2) per pixel for seed points in [0, n)^2 (wrapped distances)."""
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    d1 = np.full((n, n), 1e9, np.float32)
    d2 = np.full((n, n), 1e9, np.float32)
    idx = np.zeros((n, n), np.int32)
    for k, (px, py) in enumerate(pts):
        dx = np.abs(xx - px)
        dx = np.minimum(dx, n - dx)
        dy = np.abs(yy - py)
        dy = np.minimum(dy, n - dy)
        d = np.sqrt(dx * dx + dy * dy)
        closer = d < d1
        d2 = np.where(closer, d1, np.minimum(d2, d))
        idx = np.where(closer, k, idx)
        d1 = np.where(closer, d, d1)
    return idx, d1, d2


def jittered_grid(cols, rows, jitter, seed, stagger=0.0):
    rng = np.random.default_rng(seed)
    pts = []
    for j in range(rows):
        for i in range(cols):
            x = (i + 0.5 + stagger * (j % 2) + rng.uniform(-jitter, jitter)) * N / cols
            y = (j + 0.5 + rng.uniform(-jitter, jitter)) * N / rows
            pts.append((x % N, y % N))
    return pts


def save_set(name, img, height=None, normal_strength=2.0):
    img = np.clip(img, 0, 255)
    color = Image.fromarray(img.astype(np.uint8), "RGB")
    D.mkdir(parents=True, exist_ok=True)
    color.save(D / f"{name}_color.png", optimize=True)
    if height is None:
        height = np.asarray(color.convert("L").filter(ImageFilter.GaussianBlur(2.0)), dtype=float) / 255
    h = height
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * normal_strength
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * normal_strength
    nrm = np.stack([-dx, dy, np.ones_like(h)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    Image.fromarray(((nrm * 0.5 + 0.5) * 255).astype(np.uint8)).save(D / f"{name}_normal.png", optimize=True)
    # neutral map + tint, tools/vfx/neutralize.py formula
    a = img / 255
    avg = a.reshape(-1, 3).mean(0)
    k = min(np.percentile((a / np.maximum(avg, 1e-3)).max(-1), 98), 1.15, 1 / avg.max())
    tint = np.clip(avg * k, 0, 1)
    n = np.clip(a / np.maximum(tint, 1e-3), 0, 1)
    Image.fromarray((n * 255).astype(np.uint8)).save(D / f"{name}_ncolor.png", optimize=True)
    tp = D / "tints.json"
    tints = json.loads(tp.read_text())
    tints[name] = "#%02x%02x%02x" % tuple(int(round(v * 255)) for v in tint)
    tp.write_text(json.dumps(tints, indent=1))
    print(name, tints[name], "k=%.2f" % k)


def coast_rock():
    seed = 7301
    rng = np.random.default_rng(seed)
    # blocks: wider than tall (stratified sandstone), staggered rows
    pts = jittered_grid(7, 11, 0.32, seed, stagger=0.5)
    idx, d1, d2 = voronoi(N, pts)
    edge = d2 - d1  # 0 on the cracks
    tones = [np.array(c, float) for c in ((176, 170, 160), (164, 160, 154), (192, 178, 152), (150, 148, 146),
                                          (184, 172, 150), (170, 164, 156))]
    cell_col = np.array([tones[rng.integers(len(tones))] * rng.uniform(0.93, 1.06) for _ in pts])
    img = cell_col[idx]
    # facet shading: a lit upper-left bevel and a shaded lower-right bevel inside each block
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    cx = np.array([p[0] for p in pts], np.float32)[idx]
    cy = np.array([p[1] for p in pts], np.float32)[idx]
    ox = (xx - cx + N / 2) % N - N / 2
    oy = (yy - cy + N / 2) % N - N / 2
    bevel = np.clip(1 - edge / 22.0, 0, 1)
    side = np.clip((-ox - oy) / (np.hypot(ox, oy) + 1e-3), -1, 1)  # +1 toward the upper-left
    img = img * (1 + (0.16 * side * bevel)[..., None])
    # second facet split inside each block (diagonal plane) for the faceted Raiser read
    split = np.sign(ox * 0.6 + oy * (rng.uniform(-1, 1)))
    img = img * (1 + 0.04 * split[..., None])
    # cracks
    crack = np.clip(1 - edge / 3.2, 0, 1)
    img = img * (1 - 0.55 * crack[..., None]) + np.array([70, 62, 56], float) * 0.0
    # soft horizontal strata and mottling
    strata = periodic_noise(N, 1, 3, seed + 1)
    bands = np.sin((yy / N) * 2 * math.pi * 9 + strata * 3.0)
    img = img * (1 + 0.035 * bands[..., None])
    mott = periodic_noise(N, 4, 16, seed + 2)
    img = img + mott[..., None] * np.array([10, 9, 7], float)
    fine = periodic_noise(N, 40, 120, seed + 3)
    img = img + fine[..., None] * np.array([7, 7, 6], float)
    # warm ochre stain and cool grey patches, broad
    stain = periodic_noise(N, 1, 4, seed + 4)
    img = img + np.where(stain[..., None] > 0, stain[..., None] * np.array([10, 3, -8], float),
                         -stain[..., None] * np.array([-6, -2, 4], float))
    height = (1 - crack) * 0.6 + bevel * 0.0 + 0.4 * np.clip(edge / 30.0, 0, 1)
    height = np.asarray(Image.fromarray((height * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.5)), float) / 255
    save_set("T7_COAST_ROCK", img, height, 3.0)


def sea_grass():
    seed = 7302
    rng = np.random.default_rng(seed)
    base = np.array([122, 140, 82], float)     # olive sea-grass
    sun = np.array([160, 166, 98], float)      # sunlit drift (warm)
    hollow = np.array([86, 116, 86], float)    # blue-green hollow
    lo = periodic_noise(N, 1, 4, seed)
    mid = periodic_noise(N, 5, 14, seed + 1)
    t = np.clip(0.55 * lo + 0.3 * mid, -1, 1)
    img = base[None, None, :] + np.where(t[..., None] > 0, (sun - base) * t[..., None], (base - hollow) * t[..., None])
    img += periodic_noise(N, 30, 90, seed + 2)[..., None] * np.array([6, 7, 4], float)
    # sandy bare patches (beach grass thins out over sand)
    bare = periodic_noise(N, 3, 8, seed + 3)
    w = np.clip((bare - 0.45) / 0.2, 0, 1)[..., None]
    img = img * (1 - 0.55 * w) + np.array([206, 186, 142], float) * 0.55 * w
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    dr = ImageDraw.Draw(layer)

    def wrapped_line(pts, fill, width):
        for ox in (-N, 0, N):
            for oy in (-N, 0, N):
                dr.line([(x + ox, y + oy) for x, y in pts], fill=fill, width=width)

    for _ in range(1100):
        cx, cy = rng.random() * N, rng.random() * N
        local = float(lo[int(cy) % N, int(cx) % N])
        blades = int(rng.integers(3, 7))
        h = 14 + rng.random() * 20
        lean = rng.normal(0.3, 0.3)
        for b in range(blades):
            a = lean + (b - blades / 2) * 0.24 + rng.normal(0, 0.08)
            L = h * (0.6 + rng.random() * 0.5)
            x0 = cx + (b - blades / 2) * 2.2
            x1, y1 = x0 + math.sin(a) * L, cy - math.cos(a) * L
            xm, ym = (x0 + x1) / 2 + math.sin(a) * 2, (cy + y1) / 2
            root = (78, 104, 74, 95)
            tip = (184, 184, 112, 150) if local > 0.1 else (146, 164, 102, 140)
            wrapped_line([(x0, cy), (xm, ym)], root, 3)
            wrapped_line([(xm, ym), (x1, y1)], tip, 2)
    for _ in range(170):  # hibiscus coral and frangipani cream specks, sparse
        cx, cy = rng.random() * N, rng.random() * N
        col = (236, 120, 96, 170) if rng.random() < 0.45 else (244, 232, 196, 160)
        r = 1.8 + rng.random() * 1.6
        for ox in (-N, 0, N):
            for oy in (-N, 0, N):
                dr.ellipse([cx + ox - r, cy + oy - r, cx + ox + r, cy + oy + r], fill=col)
    layer = layer.filter(ImageFilter.GaussianBlur(0.7))
    la = np.asarray(layer, dtype=float)
    alpha = la[..., 3:4] / 255.0
    img = img * (1 - alpha) + la[..., :3] * alpha
    save_set("T8_SEA_GRASS", img)


def cove_cobble():
    seed = 7303
    rng = np.random.default_rng(seed)
    pts = jittered_grid(8, 8, 0.3, seed, stagger=0.5)
    idx, d1, d2 = voronoi(N, pts)
    edge = d2 - d1
    tones = [(214, 200, 174), (200, 184, 156), (184, 176, 164), (206, 182, 160), (176, 166, 150), (220, 206, 180)]
    cell_col = np.array([np.array(tones[rng.integers(len(tones))], float) * rng.uniform(0.94, 1.05) for _ in pts])
    img = cell_col[idx]
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    cx = np.array([p[0] for p in pts], np.float32)[idx]
    cy = np.array([p[1] for p in pts], np.float32)[idx]
    ox = (xx - cx + N / 2) % N - N / 2
    oy = (yy - cy + N / 2) % N - N / 2
    mortar_w = 10.0
    stone = np.clip((edge - mortar_w) / 10.0, 0, 1)  # 0 in the joint, 1 well inside the stone
    dome = np.sqrt(stone)
    light = np.clip((-ox - oy) / (np.hypot(ox, oy) + 1e-3), -1, 1) * (1 - stone) * 0.9
    img = img * (0.74 + 0.26 * dome)[..., None] * (1 + 0.14 * light)[..., None]
    # worn top: a slightly paler, smoother centre
    img = img + (dome ** 3)[..., None] * np.array([8, 7, 6], float)
    img = img + periodic_noise(N, 20, 80, seed + 1)[..., None] * np.array([7, 6, 5], float)
    # mortar: sandy umber with drifted sand
    sandn = periodic_noise(N, 6, 24, seed + 2)
    mortar = np.array([128, 108, 84], float) + sandn[..., None] * np.array([26, 22, 16], float)
    joint = np.clip(1 - (edge - mortar_w * 0.4) / (mortar_w * 0.9), 0, 1)
    img = img * (1 - joint[..., None]) + mortar * joint[..., None]
    # broad wear: damp-darker and sun-bleached drifts
    wear = periodic_noise(N, 1, 3, seed + 3)
    img = img * (1 + 0.05 * wear[..., None])
    height = 0.25 + 0.75 * dome
    height = np.asarray(Image.fromarray((np.clip(height, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2.0)), float) / 255
    save_set("T9_COVE_COBBLE", img, height, 4.0)


def main() -> None:
    coast_rock()
    sea_grass()
    cove_cobble()


if __name__ == "__main__":
    main()
