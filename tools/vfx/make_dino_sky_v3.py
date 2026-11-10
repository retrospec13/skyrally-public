#!/usr/bin/env python3
"""DINO-4 cave skybox v3 (visibility fix 3, 2026-10-20): the skybox IS the inside of the sealed cavern.

At graphics level 1 (phones, low settings) Roblox culls the great hall's far walls, its ceiling and even the backdrop
shell, so the far background is always the skybox. v2 (make_dino_sky.py, kept) was a violet gradient with mountain
silhouettes, which read as "outdoors at night". v3 paints the cave itself, procedurally (numpy, no external images):

- side faces: painted strata rock walls in the terrain palette (Sandstone #c98a64 bands, basalt #7a6762 buttresses,
  dark crown rock #6a5262 rising into the ceiling), lit warm from below by the lava, with soft depth haze toward the
  Atmosphere colour (132, 96, 92) at the horizon line so the culled terrain fades into it;
- the bottom of each side face and the down face: a glowing lava sea (deep red-orange CrackedLava look) with dark
  crust plates and bright cracks, hazing into a lava glow toward the horizon;
- up face: dark rock ceiling with a warm upward lava bounce. No oculus: the hall roof is sealed (author_dino4.py
  carves the hall to Y 244 under a solid Rock crown; the "skylight" shafts are Beams), so no bright disc.

Seams. Every colour is a function of the view direction. The four side faces share one image (Lighting applies
`side` to Bk/Ft/Lf/Rt), so the direction fields are made 4-fold periodic around the vertical axis by cross-fading
each field with its 90-degree-rotated copy near the face's right edge (left edge == right edge exactly). Near the
side/up and side/down edges (|elevation| 33-50 degrees) the colour depends on elevation only, so the faces meet
without a seam whatever rotation or mirroring Roblox applies to the up and down images. Checked numerically below.

Usage: make_dino_sky_v3.py [--size 1024] -> assets/sky/dino_cave_v3/{side,up,down}.png and previews in
out/sky_v3/ (cross.png, views.png)."""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "sky" / "dino_cave_v3"
PREV = ROOT / "out" / "sky_v3"
SEED = 4613

HAZE = np.array([132, 96, 92], float)  # src/shared/lighting/dino4.luau Atmosphere.Color
SAND = np.array([201, 138, 100], float)  # terrain Sandstone #c98a64
CROWN = np.array([106, 82, 98], float)  # terrain Rock #6a5262
BASALT = np.array([122, 103, 98], float)  # terrain Basalt #7a6762
LAVA_HOT = np.array([255, 196, 92], float)
LAVA = np.array([255, 134, 46], float)  # CrackedLava #ff862e
LAVA_DEEP = np.array([178, 46, 22], float)
CRUST = np.array([84, 46, 40], float)
CRUST_RIM = np.array([124, 62, 44], float)
GLOW = np.array([196, 98, 62], float)  # lava light hanging over the sea near the horizon
STRATA = np.array([[218, 150, 100], [201, 138, 100], [176, 108, 80], [230, 168, 116], [156, 98, 80],
                   [206, 126, 86], [140, 96, 88], [212, 146, 96]], float)  # painted bands around #c98a64


# ---------------------------------------------------------------- noise
def _hash(*ints, seed=0):
    h = np.uint32(2166136261 ^ seed)
    with np.errstate(over="ignore"):
        for k, a in enumerate(ints):
            h = (h ^ (a.astype(np.int64) & 0xFFFFFFFF).astype(np.uint32)) * np.uint32(16777619)
            h ^= h >> np.uint32(13)
            h *= np.uint32(0x5BD1E995 + k * 2)
            h ^= h >> np.uint32(15)
    return h


def _rand(*ints, seed=0):
    return _hash(*ints, seed=seed).astype(np.float64) / 4294967296.0


def vnoise3(p, seed):
    """Value noise in [-1, 1] at points p (..., 3)."""
    f = np.floor(p)
    t = p - f
    t = t * t * (3 - 2 * t)
    i = f.astype(np.int64)
    out = 0.0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (t[..., 0] if dx else 1 - t[..., 0]) * (t[..., 1] if dy else 1 - t[..., 1]) * (t[..., 2] if dz else 1 - t[..., 2])
                out = out + w * _rand(i[..., 0] + dx, i[..., 1] + dy, i[..., 2] + dz, seed=seed)
    return out * 2 - 1


def fbm3(p, octaves, seed, gain=0.5):
    v, a, s = 0.0, 1.0, 0.0
    for o in range(octaves):
        v = v + a * vnoise3(p * (2.0 ** o), seed + 101 * o)
        s += a
        a *= gain
    return v / s


def worley2(x, y, seed):
    """F1, F2 distances of a jittered-grid cell pattern, and a per-cell random id."""
    ix, iy = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
    f1 = np.full(x.shape, 9.0)
    f2 = np.full(x.shape, 9.0)
    cid = np.zeros(x.shape)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            cx, cy = ix + dx, iy + dy
            px = cx + 0.15 + 0.7 * _rand(cx, cy, seed=seed)
            py = cy + 0.15 + 0.7 * _rand(cx, cy, seed=seed + 1)
            d = np.hypot(x - px, y - py)
            closer = d < f1
            f2 = np.where(closer, f1, np.minimum(f2, d))
            cid = np.where(closer, _rand(cx, cy, seed=seed + 2), cid)
            f1 = np.where(closer, d, f1)
    return f1, f2, cid


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def mix(c0, c1, t):
    t = np.asarray(t)[..., None]
    return c0 * (1 - t) + c1 * t


# ---------------------------------------------------------------- the cave as a function of direction
H_EYE = 140.0  # camera height above the lava sea (studs) for the floor projection
FIELD_KEYS = ("wall", "warp", "brush", "bulge", "pillar", "ceil", "ceil_f", "lava_f", "lava_f2", "lava_id", "lava_n", "shore")


def fields(d):
    """Azimuth-dependent scalar fields for directions d (..., 3). Blended across the side-face seam."""
    x, y, z = d[..., 0], d[..., 1], d[..., 2]
    hor = np.sqrt(x * x + z * z) + 1e-9
    ux, uz = x / hor, z / hor  # unit horizontal direction
    out = {}
    # wall: points on a unit cylinder, height = tan(elevation)
    tan_e = y / hor
    cyl = np.stack([ux * 3.0, tan_e * 3.0, uz * 3.0], -1)
    out["bulge"] = fbm3(np.stack([ux * 1.6, np.zeros_like(ux), uz * 1.6], -1), 3, SEED + 1)  # wall distance wobble
    out["warp"] = fbm3(cyl * 0.9, 4, SEED + 2)
    out["wall"] = fbm3(cyl * 2.2, 5, SEED + 3)
    # brush strokes: stretched along the strata (horizontal), tight vertically
    out["brush"] = fbm3(np.stack([ux * 7.0, tan_e * 70.0, uz * 7.0], -1), 3, SEED + 4)
    # vertical folds of the rock: azimuth noise stretched up the wall
    out["pillar"] = 0.5 + 0.5 * fbm3(np.stack([ux * 7.0 + 0.3 * out["warp"], tan_e * 0.5, uz * 7.0], -1), 3, SEED + 5)
    out["shore"] = fbm3(np.stack([ux * 9.0, np.zeros_like(ux) + 1.7, uz * 9.0], -1), 4, SEED + 6)
    # ceiling (plane y = 1 seen from below): rock plates
    cy = np.maximum(y, 1e-3)
    cx_, cz_ = x / cy, z / cy
    f1, f2, _ = worley2(cx_ * 2.6, cz_ * 2.6, SEED + 7)
    out["ceil_f"] = f2 - f1
    out["ceil"] = fbm3(np.stack([cx_ * 2.0, cz_ * 2.0, np.zeros_like(cx_) + 5.1], -1), 4, SEED + 8)
    # lava sea (plane y = -H_EYE): crust plates
    fy = np.maximum(-y, 1e-3)
    lx, lz = x / fy * H_EYE, z / fy * H_EYE
    s = 1 / 24.0  # crust plate size ~24 studs
    wx = lx * s + 0.35 * fbm3(np.stack([lx * s * 0.5, lz * s * 0.5, np.zeros_like(lx) + 2.2], -1), 3, SEED + 9)
    wz = lz * s + 0.35 * fbm3(np.stack([lx * s * 0.5, lz * s * 0.5, np.zeros_like(lx) + 7.9], -1), 3, SEED + 10)
    f1, f2, cid = worley2(wx, wz, SEED + 11)
    out["lava_f"] = f2 - f1
    out["lava_id"] = cid
    g1, g2, _ = worley2(wx * 2.7 + 13.1, wz * 2.7 - 5.3, SEED + 13)  # finer cracks inside the plates
    out["lava_f2"] = g2 - g1
    out["lava_n"] = fbm3(np.stack([lx * s * 1.7, lz * s * 1.7, np.zeros_like(lx) + 3.3], -1), 4, SEED + 12)
    return out


def periodic_fields(d):
    """Fields made exactly 90-degree periodic in azimuth (for the shared side image)."""
    az = np.degrees(np.arctan2(d[..., 0], d[..., 2]))  # -45..45 on the side face
    w = smooth(22.0, 45.0, az)
    # R(-90): direction at azimuth a maps to a - 90. With az = atan2(x, z): (x, z) -> (-z, x)... check: a=+45
    # (x = z) -> (-z, x) has atan2(-z, x) = -45.
    dr = np.stack([-d[..., 2], d[..., 1], d[..., 0]], -1)
    f0, f1 = fields(d), fields(dr)
    return {k: f0[k] * (1 - w) + f1[k] * w for k in FIELD_KEYS}


def colour(d, f):
    x, y, z = d[..., 0], d[..., 1], d[..., 2]
    hor = np.sqrt(x * x + z * z) + 1e-9
    e = np.degrees(np.arctan2(y, hor))
    # detail mask: elevation-only colour in the seam bands |e| 33..50 (side/up and side/down edges)
    det_up = 1 - smooth(26, 33, e)  # wall detail fades below the side/up seam band
    det_ceil = smooth(50, 64, e)  # ceiling detail returns inside the up face
    det_dn = 1 - smooth(22, 33.5, -e)
    det_floor = smooth(49, 56, -e)

    # ---- wall
    R = 1.0 + 0.22 * f["bulge"]  # wall distance varies: strata heights shift in perspective
    h = np.tan(np.radians(np.clip(e, -80, 80))) * R + 0.05 * f["warp"]
    k = h * 11.0 + 2.0 * h * h + 0.6 * f["warp"]
    band = np.floor(k).astype(np.int64)
    frac = k - band
    pal = STRATA[(_hash(band, seed=SEED + 20) % len(STRATA)).astype(np.int64)]
    pal_n = STRATA[(_hash(band + 1, seed=SEED + 20) % len(STRATA)).astype(np.int64)]
    wall = mix(pal, pal_n, smooth(0.86, 1.0, frac))  # soft painted band edges
    # basalt buttresses with a warm lit edge
    # painted blocks: the rock's large light/shadow masses posterised into soft steps
    bq = f["wall"] * 3.0 + 0.5
    blocks = (np.floor(bq) + smooth(0.35, 0.65, bq - np.floor(bq)) - 0.5) / 3.0  # soft-edged steps
    wall = wall * (1 + 0.16 * blocks + 0.05 * f["brush"])[..., None]
    # vertical folds in the rock: soft light/shadow flutes, lit from below
    folds = np.round(f["pillar"] * 4.0) / 4.0
    wall = wall * (1 + 0.10 * (folds - 0.5))[..., None]
    # basalt accents: some strata are basalt, broken up by the rock masses
    is_bas = (_hash(band, seed=SEED + 21) % 5 == 0) * smooth(-0.12, 0.02, f["wall"] + 0.25 * f["warp"])
    bas = is_bas * (1 - smooth(0.82, 0.98, frac)) * (1 - smooth(16, 26, e)) * 0.6
    wall = mix(wall, BASALT * np.array([1.08, 0.92, 0.86]) * (0.9 + 0.12 * blocks + 0.05 * f["brush"])[..., None], bas * 0.85)
    # dark crown rock rising into the ceiling
    crown_t = smooth(9, 26, e + 4 * f["warp"])
    wall = mix(wall, CROWN * (1 + 0.08 * f["wall"])[..., None], crown_t)
    # lighting: lava bounce warm and bright low on the wall, dim up toward the crown
    lit = 1.0 - 0.42 * smooth(0, 28, e)
    warm = np.clip(1 - e / 16.0, 0, 1) * 0.5
    wall = wall * lit[..., None]
    wall = mix(wall, wall * np.array([1.16, 0.88, 0.72]), warm)
    wall = mix(wall, wall + np.array([50, 18, 0.0]), smooth(4, -1, e) * 0.6)  # hot glow at the lava line

    # ---- ceiling (up face interior and its seam band)
    ceil_base = mix(np.array([98, 72, 80.0]), np.array([58, 44, 54.0]), smooth(35, 90, e))  # bounce fades upward
    plates = smooth(0.0, 0.12, f["ceil_f"])
    ceil_det = ceil_base * (0.88 + 0.12 * plates + 0.08 * f["ceil"])[..., None]
    bounce = np.clip(0.5 + 0.6 * f["ceil"], 0, 1) * (1 - smooth(55, 88, e)) * 0.55  # warm lava bounce patches
    ceil_det = mix(ceil_det, ceil_det * np.array([1.55, 1.05, 0.85]) + np.array([18, 4, 0.0]), bounce)
    ceil = mix(ceil_base, ceil_det, det_ceil)

    # the side's top band: elevation only, meets the ceiling's band colour
    upper = mix(wall, mix(CROWN * 0.86, ceil_base, smooth(30, 45, e)), 1 - det_up)
    sky = np.where((e > 45)[..., None], ceil, upper)
    sky = np.where((e > 33)[..., None] & (e <= 45)[..., None], mix(CROWN * 0.86, ceil_base, smooth(30, 45, e)), sky)

    # ---- lava sea
    crust_t = smooth(0.08, 0.14, f["lava_f"]) * (f["lava_id"] > 0.14)  # plate interiors; a few cells stay open lava
    crust_t = crust_t * smooth(0.03, 0.07, f["lava_f2"])  # hairline cracks through the crust
    crack = np.maximum(1 - smooth(0.0, 0.09, f["lava_f"]), (1 - smooth(0.0, 0.05, f["lava_f2"])) * 0.6)
    lava = mix(LAVA_DEEP, LAVA, np.clip(0.55 + 0.6 * f["lava_n"], 0, 1))
    lava = mix(lava, LAVA_HOT, crack * 0.75)
    crust = mix(CRUST, CRUST_RIM, smooth(0.25, 0.12, f["lava_f"])) * (0.9 + 0.15 * f["lava_n"])[..., None]
    floor_det = mix(lava, crust, crust_t * 0.92)
    # distance: plates shrink into a glowing haze toward the horizon (also keeps them from aliasing)
    far = smooth(-18, -5, e)
    floor_far = mix(np.array([214, 86, 40.0]), GLOW, smooth(-8, -1, e))
    floor = mix(floor_det, floor_far, far)
    floor_band = mix(np.array([178, 70, 40.0]), np.array([214, 92, 42.0]), smooth(33, 50, -e))  # elevation-only seam band colour (mean lava)
    floor = np.where((-e > 33)[..., None], mix(floor_band, floor_det, det_floor), mix(floor, floor_band, 1 - det_dn))

    # shoreline: the wall's foot meets the sea a few degrees below the horizon
    shore = -6.0 + 2.4 * f["shore"]
    sea = smooth(shore + 0.5, shore - 0.5, e)
    foot = smooth(shore + 2.2, shore + 0.3, e) * (1 - sea)  # dark basalt foot of the wall, glowing at the waterline
    sky = mix(sky, BASALT * 0.62, foot * 0.5)
    sky = mix(sky, np.array([255, 150, 70.0]), smooth(shore + 0.9, shore + 0.2, e) * (1 - sea) * 0.7)
    col = mix(sky, floor, sea)

    # ---- depth haze toward the Atmosphere colour at the horizon line
    r = np.sqrt(e * e + 2.25) - 1.5  # |e| with a rounded peak: no bright line exactly at the horizon
    hz = np.where(e >= 0, 0.10 + 0.55 * np.exp(-r / 6.0), 0.65 * np.exp(-r / 4.0))
    haze_col = mix(HAZE, GLOW, smooth(2, -6, e) * 0.6)
    col = mix(col, haze_col, hz)
    return np.clip(col, 0, 255)


# ---------------------------------------------------------------- faces
def face_dirs(n, face):
    u = (np.arange(n) + 0.5) / n * 2 - 1
    U, V = np.meshgrid(u, -u)  # V +1 at the top row, U +1 at the right column
    one = np.ones_like(U)
    if face == "side":
        d = np.stack([U, V, one], -1)  # facing +Z, right = +X, up = +Y
    elif face == "up":
        d = np.stack([U, one, -V], -1)  # image top edge toward -Z... any rotation works (band is elevation-only)
    else:
        d = np.stack([U, -one, V], -1)
    return d / np.linalg.norm(d, axis=-1, keepdims=True)


def render_face(n, face):
    """The side image is 90-degree periodic; the up and down interiors are free (their edges are elevation-only)."""
    d = face_dirs(n, face)
    return colour(d, periodic_fields(d) if face == "side" else fields(d))


def to_img(a):
    return Image.fromarray(np.clip(a + 0.5, 0, 255).astype(np.uint8))


def seam_report(side, up, down):
    s, u, dn = (np.asarray(i, float) for i in (side, up, down))
    lr = np.abs(s[:, 0] - s[:, -1]).mean()
    top = s[0]
    up_edges = [u[0], u[-1], u[:, 0], u[:, -1]]
    up_err = max(min(np.abs(top - ed).mean(), np.abs(top - ed[::-1]).mean()) for ed in up_edges)
    bot = s[-1]
    dn_edges = [dn[0], dn[-1], dn[:, 0], dn[:, -1]]
    dn_err = max(min(np.abs(bot - ed).mean(), np.abs(bot - ed[::-1]).mean()) for ed in dn_edges)
    # worst case: any edge of up/down against the side edge in either direction
    up_any = max(max(np.abs(top - ed).mean(), np.abs(top - ed[::-1]).mean()) for ed in up_edges)
    dn_any = max(max(np.abs(bot - ed).mean(), np.abs(bot - ed[::-1]).mean()) for ed in dn_edges)
    return {"side_left_right": round(lr, 2), "side_top_vs_up_edges_any_orientation": round(up_any, 2),
            "side_bottom_vs_down_edges_any_orientation": round(dn_any, 2), "_best": (round(up_err, 2), round(dn_err, 2))}


def cross(side, up, down, cell=256):
    s, u, dn = (i.resize((cell, cell), Image.LANCZOS) for i in (side, up, down))
    c = Image.new("RGB", (cell * 4, cell * 3), (24, 24, 24))
    for k in range(4):
        c.paste(s, (k * cell, cell))
    c.paste(u, (cell, 0))
    c.paste(dn, (cell, cell * 2))
    return c


def sample_cube(dirs, side, up, down):
    """Look up the cube (side image on all four sides, rotated per quadrant) for directions (..., 3)."""
    S, U, D = (np.asarray(i, float) for i in (side, up, down))
    n = S.shape[0]
    x, y, z = dirs[..., 0], dirs[..., 1], dirs[..., 2]
    ax, ay, az = np.abs(x), np.abs(y), np.abs(z)
    out = np.zeros(dirs.shape[:-1] + (3,))

    def px(a):
        return np.clip(((a + 1) / 2 * n).astype(int), 0, n - 1)

    is_up = (ay >= ax) & (ay >= az) & (y > 0)
    is_dn = (ay >= ax) & (ay >= az) & (y <= 0)
    is_side = ~(is_up | is_dn)
    # rotate side directions to the +Z face
    q = np.round(np.arctan2(x, z) / (np.pi / 2)).astype(int) % 4
    xr, zr = x.copy(), z.copy()
    for k in range(1, 4):
        m = q == k
        a = -k * np.pi / 2
        xr[m] = x[m] * np.cos(a) + z[m] * np.sin(a)
        zr[m] = -x[m] * np.sin(a) + z[m] * np.cos(a)
    uu, vv = xr / np.maximum(zr, 1e-6), y / np.maximum(zr, 1e-6)
    out[is_side] = S[px(-vv), px(uu)][is_side]
    out[is_up] = U[px(z / np.maximum(y, 1e-6)), px(x / np.maximum(y, 1e-6))][is_up]
    out[is_dn] = D[px(z / np.maximum(-y, 1e-6)), px(x / np.maximum(-y, 1e-6))][is_dn]
    return out


def view(side, up, down, yaw, pitch, w=480, h=270, fov=70):
    t = np.tan(np.radians(fov) / 2)
    xs = (np.arange(w) + 0.5) / w * 2 - 1
    ys = ((np.arange(h) + 0.5) / h * 2 - 1) * h / w
    X, Y = np.meshgrid(xs * t, -ys * t)
    d = np.stack([X, Y, np.ones_like(X)], -1)
    cp, sp = np.cos(np.radians(pitch)), np.sin(np.radians(pitch))
    d = np.stack([d[..., 0], d[..., 1] * cp + d[..., 2] * sp, -d[..., 1] * sp + d[..., 2] * cp], -1)
    cy, sy = np.cos(np.radians(yaw)), np.sin(np.radians(yaw))
    d = np.stack([d[..., 0] * cy + d[..., 2] * sy, d[..., 1], -d[..., 0] * sy + d[..., 2] * cy], -1)
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    return to_img(sample_cube(d, side, up, down))


def views_sheet(side, up, down, shots):
    tiles = [view(side, up, down, yw, pt) for yw, pt in shots]
    w, h = tiles[0].size
    cols = 2
    sheet = Image.new("RGB", (w * cols, h * ((len(tiles) + cols - 1) // cols)))
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % cols) * w, (i // cols) * h))
    return sheet


SHOTS = [(0, 4), (45, 4), (20, -12), (70, 25), (10, 60), (30, -55)]  # (yaw, pitch): horizon, side seam, lava, crown, ceiling, floor


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=1024)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    PREV.mkdir(parents=True, exist_ok=True)
    faces = {k: to_img(render_face(a.size, k)) for k in ("side", "up", "down")}
    for k, im in faces.items():
        im.save(OUT / f"{k}.png", optimize=True)
    print("seams (mean abs RGB diff, 0-255):", seam_report(faces["side"], faces["up"], faces["down"]))
    cross(faces["side"], faces["up"], faces["down"]).save(PREV / "dino4_cross.png")
    views_sheet(faces["side"], faces["up"], faces["down"], SHOTS).save(PREV / "dino4_views.png")
    for k in faces:
        print(OUT / f"{k}.png", np.asarray(faces[k]).reshape(-1, 3).mean(0).round(1))
    print(PREV / "dino4_cross.png", PREV / "dino4_views.png")


if __name__ == "__main__":
    main()
