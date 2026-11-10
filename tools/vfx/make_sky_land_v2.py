#!/usr/bin/env python3
"""FOREST-1 and SNOW-1 sky side faces v2 (visibility fix 3, 2026-10-20): land below the horizon.

The current side faces (tools/map/author_forest1.py write_sky, tools/map/author_snow1.py sky_faces) are a plain colour
gradient below the horizon, so where the client culls the heightfield rim (graphics level 1, phones) the kart looks
out at a flat green or white void. This keeps every pixel above the horizon exactly as it is and paints distant land
on the lower part of the side face: layered far hills, each hazier toward the horizon, fading back into the original
gradient near the bottom edge so the unchanged down face still meets it.

- FOREST-1: far rolling green-gold hills, golden field patches and dark round treelines, hazing into the warm cream
  Atmosphere colour (238, 226, 200).
- SNOW-1: far white-blue faceted ranges, rolling snowfields with soft blue shadows and dark fir specks, hazing into
  the pale lilac Atmosphere colour (236, 232, 238).

Owned, procedural (numpy). The land is periodic across the face (the four side faces share one image), and only
pixels below the horizon change (checked). Up/down faces are copied unchanged (same images and ids).
Usage: make_sky_land_v2.py -> assets/sky/{forest1_v2,snow1_v2}/{side,up,down}.png, uploaded.json seeded with the
unchanged up/down ids, and previews out/sky_v3/{forest1,snow1}_land.png."""
import hashlib
import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SKY = ROOT / "assets" / "sky"
PREV = ROOT / "out" / "sky_v3"


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def mix(c0, c1, t):
    t = np.asarray(t)[..., None]
    return c0 * (1 - t) + c1 * t


def pnoise(px, rng, freqs, falloff=0.6):
    """Periodic noise in px (0..1 wraps): random-phase sines with integer frequencies, in [-1, 1]."""
    v, a, s = 0.0, 1.0, 0.0
    for k in freqs:
        v = v + a * np.sin(2 * np.pi * (k * px + rng.random()))
        s += a
        a *= falloff
    return v / s


def faceted(px, rng, n, lo=0.0, hi=1.0):
    """Periodic piecewise-linear (faceted) profile with n knots."""
    knots = [rng.uniform(lo, hi) for _ in range(n)]
    knots.append(knots[0])
    return np.interp(px % 1.0, np.linspace(0, 1, n + 1), knots)


def treeline(px, rng, count, height, cluster):
    """Scalloped canopy bumps (degrees above a ridge), present only where the cluster noise is positive."""
    f = px * count
    fr = f - np.floor(f)
    idx = np.floor(f).astype(int) % count
    jit = np.array([rng.uniform(0.6, 1.0) for _ in range(count)])
    bump = np.sqrt(np.clip(1 - (2 * fr - 1) ** 2, 0, 1)) * jit[idx]
    return height * bump * (cluster > 0)


def geometry(n):
    u = (np.arange(n) + 0.5) / n * 2 - 1
    U, V = np.meshgrid(u, -u)
    e = np.degrees(np.arctan2(V, np.sqrt(U * U + 1)))
    px = (np.degrees(np.arctan2(U, 1.0)) + 45) / 90.0
    return e, px


def forest(img, rng):
    n = img.shape[0]
    e, px = geometry(n)
    out = img.copy()
    haze = np.array([238, 226, 200.0])
    # (top elevation, amplitude, frequencies, lit colour, shade colour, haze, treeline)
    layers = [(-0.6, 0.7, (3, 5, 8, 13), (176, 186, 120), (150, 168, 112), 0.62, (90, 0.35)),
              (-2.4, 1.1, (2, 4, 7, 11), (168, 182, 92), (128, 156, 84), 0.42, (70, 0.55)),
              (-5.6, 1.8, (2, 3, 5, 9), (146, 176, 82), (104, 146, 76), 0.24, (46, 0.9)),
              (-10.5, 2.6, (1, 3, 4, 7), (126, 168, 80), (92, 138, 74), 0.12, (30, 1.4))]
    for top, amp, fq, lit, shade, hz, (tcount, theight) in layers:
        ridge = top + amp * pnoise(px, rng, fq)
        cluster = pnoise(px, rng, (3, 5, 9))
        trees = treeline(px, rng, tcount * 4, theight, cluster - 0.15)
        depth = np.clip((ridge - e) / (6 + amp * 2), 0, 1)  # 0 at the ridge, 1 lower on the hill face
        col = mix(np.array(lit, float), np.array(shade, float), smooth(0, 1, depth))
        # golden field patches and a darker hedge stripe on the hill face
        fields = 0.5 * pnoise(px, rng, (7, 13, 19)) + 0.5 * np.sin(e * 1.4 + 3.0 * pnoise(px, rng, (3, 5)))
        patch = smooth(0.4, 0.55, fields)  # field patches stretched along the slope
        col = mix(col, np.array([214, 188, 104.0]), patch * smooth(0.03, 0.15, depth) * 0.7)
        col = mix(col, col * 0.86, smooth(0.80, 0.88, np.abs(np.sin(np.pi * (depth * 3 + 0.3 * fields)))) * 0.6)
        land = e <= ridge
        tree = (e > ridge) & (e <= ridge + trees)
        tcol = np.array([66, 104, 66.0]) * (0.9 + 0.2 * smooth(ridge, ridge + theight, e))[..., None]
        layer = np.where(tree[..., None], tcol, col)
        layer = mix(layer, haze, hz)
        m = (land | tree).astype(float)
        out = mix(out, layer, m)
    return out


def snow(img, rng):
    n = img.shape[0]
    e, px = geometry(n)
    out = img.copy()
    haze = np.array([236, 232, 238.0])
    # far faceted ranges just under the existing peaks
    for top, amp, knots, lit, sh, hz in ((-0.5, 2.0, 13, (214, 226, 246), (176, 196, 230), 0.5),
                                         (-1.4, 2.0, 19, (226, 236, 250), (184, 204, 236), 0.38)):
        prof = faceted(px, rng, knots)
        ridge = top - amp + amp * 2 * prof
        slope = np.gradient(prof, axis=1)
        col = mix(np.array(lit, float), np.array(sh, float), (slope > 0).astype(float) * 0.85)
        col = mix(col, np.array([236, 244, 252.0]), smooth(ridge - 0.8, ridge - 0.1, e) * 0.6)  # snowy crest
        col = mix(col, haze, hz)
        out = mix(out, col, (e <= ridge).astype(float) * (e > -14))
    # rolling snowfields with blue shadow hollows, fir specks along their crests
    for top, amp, fq, hz, tcount in ((-3.2, 0.8, (3, 5, 9, 14), 0.34, 80), (-7.0, 1.6, (2, 4, 7, 11), 0.18, 52),
                                     (-12.5, 2.4, (1, 3, 5, 8), 0.08, 34)):
        ridge = top + amp * pnoise(px, rng, fq)
        depth = np.clip((ridge - e) / (5 + amp * 2), 0, 1)
        col = mix(np.array([244, 248, 254.0]), np.array([196, 214, 240.0]), smooth(0.05, 0.9, depth) * 0.8)
        drift = pnoise(px + 0.1 * e / 10, rng, (5, 9, 15))
        col = mix(col, np.array([206, 222, 244.0]), smooth(0.4, 0.55, drift) * smooth(0.1, 0.3, depth) * 0.6)
        cluster = pnoise(px, rng, (4, 7, 11))
        trees = treeline(px * 1.0, rng, tcount * 3, 0.55 + 0.12 * abs(top), cluster - 0.25)
        tree = (e > ridge) & (e <= ridge + trees)
        tcol = np.array([58, 86, 96.0])
        layer = np.where(tree[..., None], tcol, col)
        layer = mix(layer, haze, hz)
        out = mix(out, layer, ((e <= ridge) | tree).astype(float))
    return out


def finish(src, painted):
    n = src.shape[0]
    e, _ = geometry(n)
    # unchanged above the horizon; back to the original gradient toward the bottom edge (the down face meets it)
    w = smooth(0.0, -0.8, e) * (1 - smooth(-17, -26, e))
    return mix(src, painted, w)


def run(name, fn, seed):
    src_dir, dst = SKY / name, SKY / f"{name}_v2"
    dst.mkdir(parents=True, exist_ok=True)
    src = np.asarray(Image.open(src_dir / "side.png").convert("RGB"), float)
    rng = np.random.default_rng(seed)
    out = finish(src, fn(src, rng))
    im = Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8))
    im.save(dst / "side.png", optimize=True)
    n = src.shape[0]
    changed_above = np.abs(np.asarray(im, float)[: n // 2] - np.asarray(Image.open(src_dir / "side.png").convert("RGB"), float)[: n // 2]).max()
    lr = np.abs(np.asarray(im, float)[:, 0] - np.asarray(im, float)[:, -1]).mean()
    bot = np.abs(np.asarray(im, float)[-1] - src[-1]).max()
    print(f"{name}: max change above the horizon {changed_above:.0f}, side left/right edge diff {lr:.2f}, bottom row change {bot:.0f}")
    # up/down unchanged: copy and seed their ids so upload_set.py skips them and the module keeps them
    old = json.loads((src_dir / "uploaded.json").read_text())
    ids = json.loads((dst / "uploaded.json").read_text()) if (dst / "uploaded.json").exists() else {}
    for face in ("up", "down"):
        shutil.copyfile(src_dir / f"{face}.png", dst / f"{face}.png")
        sha = hashlib.sha256((dst / f"{face}.png").read_bytes()).hexdigest()
        assert old[face]["sha256"] == sha, (name, face, "source png differs from its uploaded sha")
        ids[face] = old[face]
    (dst / "uploaded.json").write_text(json.dumps(ids, indent=1))
    # preview: old | new, plus the side tiled twice
    PREV.mkdir(parents=True, exist_ok=True)
    old_im = Image.open(src_dir / "side.png").convert("RGB")
    sheet = Image.new("RGB", (n * 4, n))
    sheet.paste(old_im, (0, 0))
    sheet.paste(im, (n, 0))
    sheet.paste(im, (2 * n, 0))
    sheet.paste(im, (3 * n, 0))
    sheet.save(PREV / f"{name}_land.png")
    print(dst / "side.png", PREV / f"{name}_land.png")


def main():
    run("forest1", forest, 1101)
    run("snow1", snow, 1102)


if __name__ == "__main__":
    main()
