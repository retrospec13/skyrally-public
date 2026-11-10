#!/usr/bin/env python3
"""Art v3 procedural arches (numpy + PIL, no bpy): chunky bevelled-block builds with a painted 4x4 cell atlas (1024 px).
Used where the Tripo result was judged too thin / warped (space_arch, start_gantry, mesa_portal): symmetric by construction
(one half is built and mirrored), every solid is a closed bevelled prism, flat normals, albedo only.
Usage: build_arch_v3.py <space_arch|start_gantry|mesa_portal> <out_dir>   -> <out_dir>/<name>.glb, atlas.png, build.json
Frame: Roblox prefab frame, +Y up, X across the opening (centred on 0), Z depth centred on 0, base buried (bbox min y < 0)."""
import io
import json
import math
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

CELL = 256
PAD = 8
NAME_TO_CELL = {}


def blur(a, sy, sx):
    h, w = a.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    g = np.exp(-2 * (np.pi ** 2) * ((sy * fy) ** 2 + (sx * fx) ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(a) * g))


def nz(rng, sy, sx):
    a = blur(rng.normal(0, 1, (CELL, CELL)), sy, sx)
    return a / max(1e-6, np.abs(a).max())


def lerp3(c0, c1, t):
    return np.array(c0, np.float32) * (1 - t)[..., None] + np.array(c1, np.float32) * t[..., None]


YY, XX = np.mgrid[0:CELL, 0:CELL].astype(np.float32)


def rim(width=9.0, light=14.0, dark=14.0):
    """painted block rim: lighter top/left, deeper bottom/right (no black outlines)."""
    t = np.clip(1 - YY / width, 0, 1) + np.clip(1 - XX / width, 0, 1) * 0.7
    b = np.clip(1 - (CELL - 1 - YY) / width, 0, 1) + np.clip(1 - (CELL - 1 - XX) / width, 0, 1) * 0.7
    return (t * light - b * dark)[..., None]


def paint_stone(seed, top, bot, chips=7, cracks=1):
    rng = np.random.default_rng(seed)
    t = YY / (CELL - 1)
    col = lerp3(top, bot, t)
    v = 1 + 0.10 * nz(rng, 22, 22) + 0.08 * nz(rng, 2, 18) + 0.035 * nz(rng, 1.1, 1.1)
    n2 = nz(rng, 18, 18)
    col = col * v[..., None]
    col[..., 0] *= 1 + 0.035 * n2
    col[..., 2] *= 1 - 0.035 * n2
    col += rim()
    img = Image.fromarray(np.clip(col, 0, 255).astype(np.uint8))
    dr = ImageDraw.Draw(img, "RGBA")
    for _ in range(chips):  # light chips / dry-brush flecks
        x, y = rng.integers(24, CELL - 24, 2)
        r = rng.integers(4, 12)
        dr.polygon([(x + math.cos(a) * r * rng.uniform(.6, 1.2), y + math.sin(a) * r * rng.uniform(.5, 1)) for a in np.linspace(0, 6.28, 6, endpoint=False)], fill=(255, 245, 215, 46))
    for _ in range(14):  # dry-brush strokes (painted look)
        x, y = rng.integers(10, CELL - 60, 2)
        ln = rng.integers(30, 90)
        lit = rng.random() < 0.5
        dr.line([(x, y), (x + ln, y + rng.integers(-5, 6))], fill=(255, 246, 220, 40) if lit else (120, 104, 84, 34), width=int(rng.integers(3, 8)))
    for _ in range(cracks):
        x, y = rng.integers(40, CELL - 40, 2)
        pts = [(x, y)]
        for k in range(5):
            x += rng.integers(-12, 12)
            y += rng.integers(6, 18)
            pts.append((x, y))
        dr.line(pts, fill=(110, 92, 64, 70), width=2)
    return np.asarray(img, np.float32)


def rivets(img, pts, r=9):
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))
    dr = ImageDraw.Draw(im, "RGBA")
    for (x, y) in pts:
        dr.ellipse((x - r, y - r, x + r, y + r), fill=(214, 156, 52, 255))
        dr.ellipse((x - r * .75, y - r * .8, x + r * .25, y + r * .1), fill=(255, 226, 130, 255))
    return np.asarray(im, np.float32)


def paint_maroon(seed):
    rng = np.random.default_rng(seed)
    t = YY / (CELL - 1)
    col = lerp3((184, 70, 84), (140, 42, 60), t) * (1 + 0.06 * nz(rng, 2, 18) + 0.05 * nz(rng, 20, 20))[..., None]
    col += rim(10, 18, 8)
    return rivets(col, [(36, 128), (CELL - 36, 128)], 11)


def paint_gold(seed):
    rng = np.random.default_rng(seed)
    t = YY / (CELL - 1)
    col = lerp3((255, 226, 124), (226, 166, 56), t) * (1 + 0.05 * nz(rng, 1, 24) + 0.04 * nz(rng, 16, 16))[..., None]
    col += rim(12, 14, 20)
    return rivets(col, [(34, 34), (CELL - 34, 34), (34, CELL - 34), (CELL - 34, CELL - 34)], 8)


def flat(c, seed, amt=0.04):
    rng = np.random.default_rng(seed)
    return np.array(c, np.float32)[None, None, :] * (1 + amt * nz(rng, 6, 6))[..., None] * np.ones((CELL, CELL, 1), np.float32)


def paint_glow():
    d = np.hypot(XX - CELL / 2, YY - CELL / 2) / (CELL * 0.55)
    col = lerp3((255, 232, 120), (244, 150, 42), np.clip(d, 0, 1))
    col[(np.abs(XX - CELL / 2) < 5)] *= 0.86  # window mullion
    return col


def paint_wood_h(seed, base=(218, 152, 86)):
    rng = np.random.default_rng(seed)
    col = np.array(base, np.float32)[None, None, :] * (1 + 0.14 * nz(rng, 0.8, 34) + 0.05 * nz(rng, 14, 40))[..., None]
    col += rim(8, 16, 14)
    seam = np.exp(-((YY - CELL * (0.33 + 0.34 * (seed % 2))) / 2.2) ** 2)[..., None]
    col = col * (1 - 0.13 * seam) + 8 * np.roll(seam, 3, 0)
    return col


def paint_wood_v(seed, base=(214, 146, 82), teal=0.0):
    rng = np.random.default_rng(seed)
    col = np.array(base, np.float32)[None, None, :] * (1 + 0.14 * nz(rng, 34, 0.8) + 0.05 * nz(rng, 40, 14))[..., None]
    if teal:
        m = np.clip((YY / CELL - (1 - teal)) / teal, 0, 1) ** 1.4 * (0.6 + 0.4 * nz(rng, 8, 8) ** 2)
        col = col * (1 - m[..., None] * 0.55) + np.array((90, 174, 160), np.float32) * m[..., None] * 0.55
    col += rim(8, 14, 14)
    return col


def paint_rope():
    ph = (XX * 0.055 + YY * 0.11)
    s = 0.5 + 0.5 * np.sin(ph * 2 * np.pi / 1.0)
    col = lerp3((150, 116, 70), (240, 216, 160), np.clip(s ** 0.8, 0, 1))
    return col * (1 + 0.04 * nz(np.random.default_rng(3), 1, 1))[..., None]


def paint_sun():
    im = Image.new("RGB", (CELL, CELL), (226, 150, 74))
    dr = ImageDraw.Draw(im)
    c = CELL // 2
    dr.ellipse((8, 8, CELL - 8, CELL - 8), fill=(244, 128, 52))      # outer ring
    for k in range(16):                                               # rays as painted petals
        a = k * math.tau / 16 if hasattr(math, "tau") else k * 6.2832 / 16
        pts = [(c + math.cos(a - .12) * 92, c + math.sin(a - .12) * 92), (c + math.cos(a) * 120, c + math.sin(a) * 120), (c + math.cos(a + .12) * 92, c + math.sin(a + .12) * 92)]
        dr.polygon(pts, fill=(255, 214, 92))
    dr.ellipse((c - 92, c - 92, c + 92, c + 92), fill=(255, 206, 74))
    dr.ellipse((c - 78, c - 78, c + 78, c + 78), fill=(255, 226, 112))
    dr.ellipse((c - 52, c - 70, c + 20, c - 20), fill=(255, 244, 168))  # soft highlight
    for ex in (-30, 30):
        dr.ellipse((c + ex - 9, c - 24, c + ex + 9, c + 2), fill=(150, 84, 34))
    dr.arc((c - 44, c - 28, c + 44, c + 46), 22, 158, fill=(150, 84, 34), width=8)
    for ex in (-48, 48):
        dr.ellipse((c + ex - 11, c + 8, c + ex + 11, c + 22), fill=(255, 168, 120))
    return np.asarray(im, np.float32)


def atlas(kind):
    cells = {}
    if kind == "wood":
        cells = {
            "plank0": paint_wood_h(1), "plank1": paint_wood_h(2), "plank2": paint_wood_h(3, (226, 160, 92)), "post0": paint_wood_v(4, teal=0.3),
            "post1": paint_wood_v(5, teal=0.25), "post2": paint_wood_v(6, teal=0.35), "stone0": paint_stone(11, (226, 206, 170), (186, 160, 122)),
            "stone1": paint_stone(12, (232, 212, 176), (190, 164, 126)), "stone2": paint_stone(13, (220, 200, 164), (180, 154, 118)), "rope": paint_rope(),
            "teal": paint_wood_v(7, (74, 170, 158)), "sun": paint_sun(), "bevel_light": flat((252, 232, 186), 21), "bevel_mid": flat((214, 170, 112), 22),
            "side": flat((196, 140, 80), 23), "gold": paint_gold(24)}
    else:
        top, bot = (240, 226, 192), (196, 172, 134)
        cells = {
            "stone0": paint_stone(31, top, bot), "stone1": paint_stone(32, top, bot), "stone2": paint_stone(33, (236, 220, 184), (192, 166, 128)),
            "stone3": paint_stone(34, (244, 230, 196), (200, 176, 138)), "maroon0": paint_maroon(35), "maroon1": paint_maroon(36), "gold0": paint_gold(37),
            "gold1": paint_gold(38), "bevel_light": flat((252, 240, 208), 41), "bevel_mid": flat((212, 188, 148), 42), "bevel_gold": flat((255, 232, 150), 43),
            "bevel_maroon": flat((206, 96, 106), 44), "side": flat((176, 154, 120), 45), "side_maroon": flat((134, 46, 62), 46), "glow": paint_glow(),
            "frame": flat((190, 130, 48), 47)}
    names = list(cells)
    img = np.zeros((4 * CELL, 4 * CELL, 3), np.float32)
    for i, nme in enumerate(names):
        r, c = divmod(i, 4)
        img[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL] = cells[nme]
        NAME_TO_CELL[nme] = (r, c)
    return np.clip(img, 0, 255).astype(np.uint8)


def cell_rect(name):
    r, c = NAME_TO_CELL[name]
    S = 4 * CELL
    return ((c * CELL + PAD) / S, (r * CELL + PAD) / S, ((c + 1) * CELL - PAD) / S, ((r + 1) * CELL - PAD) / S)


# ---------------------------------------------------------------- geometry
FACES = []  # (pts(n,3), uv(n,2))


def inset_poly(poly, b):
    poly = np.array(poly, float)
    d1, d2 = poly[1] - poly[0], poly[2] - poly[1]
    if d1[0] * d2[1] - d1[1] * d2[0] < 0:
        poly = poly[::-1]
    n = len(poly)
    c = poly.mean(0)
    out = []
    for i in range(n):
        p0, p1, p2 = poly[i - 1], poly[i], poly[(i + 1) % n]
        e1 = (p1 - p0) / np.linalg.norm(p1 - p0)
        e2 = (p2 - p1) / np.linalg.norm(p2 - p1)
        n1 = np.array([-e1[1], e1[0]])
        n2 = np.array([-e2[1], e2[0]])
        M = np.array([n1, n2])
        try:
            q = p1 + np.linalg.solve(M, [b, b])
        except np.linalg.LinAlgError:
            q = p1 + n1 * b
        out.append(q)
    return poly, np.array(out)


def to3(p, w, axis):
    u, v = p
    return {"z": (u, v, w), "y": (u, w, v), "x": (w, u, v)}[axis]


def emit(pts, uv, solid_c):
    pts = np.array(pts, float)
    uv = np.array(uv, float)
    nrm = np.zeros(3)
    for i in range(len(pts)):
        nrm += np.cross(pts[i], pts[(i + 1) % len(pts)])
    fc = pts.mean(0)
    if np.dot(nrm, fc - solid_c) < 0:
        pts, uv = pts[::-1], uv[::-1]
    FACES.append((pts, uv))


def bbox_uv(poly, rect):
    poly = np.array(poly)
    lo, hi = poly.min(0), poly.max(0)
    span = np.maximum(hi - lo, 1e-6)
    t = (poly - lo) / span
    return np.stack([rect[0] + t[:, 0] * (rect[2] - rect[0]), rect[1] + (1 - t[:, 1]) * (rect[3] - rect[1])], 1)


def prism(poly, w0, w1, b, front, back=None, side="side", bev=("bevel_light", "bevel_mid"), axis="z", mirror_u=False):
    """closed bevelled prism: poly = convex 2D polygon (u, v) extruded w0..w1 along `axis`; caps get `front` (w1) / `back` (w0) cells."""
    back = back or front
    full, ins = inset_poly(poly, b)
    n = len(full)
    allp = [to3(p, w, axis) for p in full for w in (w0, w1)]
    sc = np.mean(allp, 0)
    fr, br, sd = cell_rect(front), cell_rect(back), cell_rect(side)
    for cap_w, cap_cell, inner_w, sgn in ((w1, fr, w1 - b, 1), (w0, br, w0 + b, -1)):
        emit([to3(p, cap_w, axis) for p in ins], np.stack([bbox_uv(ins, cap_cell)[i] for i in range(n)]), sc)
        for i in range(n):
            j = (i + 1) % n
            quad = [to3(ins[i], cap_w, axis), to3(ins[j], cap_w, axis), to3(full[j], inner_w, axis), to3(full[i], inner_w, axis)]
            e = np.array(quad[1]) - np.array(quad[0])
            nn = np.cross(e, np.array(quad[3]) - np.array(quad[0]))
            ny = abs(nn[1]) / max(1e-9, np.linalg.norm(nn))
            mid = np.mean(quad, 0)
            up = (mid - sc)[1] > 0 and ny > 0.2
            r = cell_rect(bev[0] if up else bev[1])
            cu, cv = (r[0] + r[2]) / 2, (r[1] + r[3]) / 2
            emit(quad, [(cu, cv)] * 4, sc)
    for i in range(n):
        j = (i + 1) % n
        quad = [to3(full[i], w0 + b, axis), to3(full[j], w0 + b, axis), to3(full[j], w1 - b, axis), to3(full[i], w1 - b, axis)]
        emit(quad, [(sd[0], sd[1]), (sd[2], sd[1]), (sd[2], sd[3]), (sd[0], sd[3])], sc)


def rect(x0, x1, y0, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def mirror_pair(fn):
    fn(1)
    fn(-1)


def pick(names, i):
    return names[i % len(names)]


# ---------------------------------------------------------------- assets
def build_space():
    A, B, CY, N = 24.25, 36.05, 4.0, 2.4
    THK_M, THK_S = 2.4, 8.4

    def sup(th):
        return np.array([A * math.cos(th) ** (2 / N), CY + B * math.sin(th) ** (2 / N)])

    def nrm(th):
        e = 1e-4
        t = sup(min(th + e, math.pi / 2)) - sup(max(th - e, 0))
        n = np.array([t[1], -t[0]])
        return n / np.linalg.norm(n)

    def P(th, d):
        return sup(th) + nrm(th) * d

    # arc-length sampling of the inner curve
    ths = np.linspace(0.02, math.pi / 2, 4000)
    pts = np.array([sup(t) for t in ths])
    cum = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))])

    def th_at(s):
        return float(np.interp(s, cum, ths))

    def th_for_y(y):
        return float(np.interp(y, pts[:, 1], ths))
    th0 = th_for_y(11.9)
    s0 = float(np.interp(th0, ths, cum))
    s_end = cum[-1]
    s_key = float(np.interp(th_for_y(39.0), ths, cum))  # stone band ends where the keystone starts (|x| ~ 6)
    nm, ns = 12, 9
    TM = [th_at(s0 + (s_end - s0) * k / nm) for k in range(nm + 1)]
    TS = [th_at(s0 + (s_key - s0) * k / ns) for k in range(ns + 1)]
    stones = ["stone0", "stone1", "stone2", "stone3"]

    def half(sg):
        S = lambda p: (p[0] * sg, p[1])
        # pedestals: 3 stacked courses, 2 blocks each, then gold collar
        courses = [(-0.8, 3.0, 24.2, 36.0, 4.0, 29.6), (3.0, 6.3, 24.4, 35.2, 3.7, 29.9), (6.3, 9.4, 24.4, 35.2, 3.7, 28.9)]
        for ci, (y0, y1, xa, xb, d, split) in enumerate(courses):
            for k, (a, c) in enumerate(((xa, split), (split, xb))):
                prism([S((a, y0)), S((c, y0)), S((c, y1)), S((a, y1))], -d, d, 0.38, pick(stones, ci * 2 + k + (1 if sg < 0 else 0)), side="side")
        prism([S(p) for p in rect(24.2, 35.0, 9.4, 12.0)], -4.2, 4.2, 0.45, "gold0", side="side", bev=("bevel_gold", "bevel_gold"))
        # maroon inner band (recessed), continuous to the crown
        for k in range(nm):
            a, c = TM[k], TM[k + 1]
            q = [P(a, 0), P(c, 0), P(c, THK_M + 0.2), P(a, THK_M + 0.2)]
            if k == 0:
                q[0] = np.array([q[0][0], 11.9]); q[3] = np.array([q[3][0], 11.9])
            prism([S(p) for p in q], -3.2, 3.2, 0.3, pick(["maroon0", "maroon1"], k), side="side_maroon", bev=("bevel_maroon", "side_maroon"))
        # stone voussoirs
        for k in range(ns):
            a, c = TS[k], TS[k + 1]
            q = [P(a, THK_M), P(c, THK_M), P(c, THK_S), P(a, THK_S)]
            if k == 0:
                q[0] = np.array([q[0][0] - 0.1, 11.9]); q[3] = np.array([q[3][0], 11.9])
            prism([S(p) for p in q], -3.8, 3.8, 0.4, pick(stones, k * 3 + (2 if sg < 0 else 0)), side="side")
        # gold clasps over three joints
        for k in (3, 6, 9 if ns >= 9 else 8):
            th = TS[min(k, ns)]
            c = P(th, 5.4)
            n = nrm(th)
            t = np.array([-n[1], n[0]])
            q = [c - n * 2.9 - t * 1.7, c + n * 2.9 - t * 1.7, c + n * 2.9 + t * 1.7, c - n * 2.9 + t * 1.7]
            prism([S(p) for p in q], -4.3, 4.3, 0.4, "gold1", side="gold1", bev=("bevel_gold", "bevel_gold"))

    mirror_pair(half)
    # keystone + gold cap + lantern (centre, symmetric by construction)
    ytop_m = CY + B + THK_M
    prism([(-3.9, ytop_m - 0.5), (3.9, ytop_m - 0.5), (5.2, 48.2), (-5.2, 48.2)], -4.2, 4.2, 0.45, "stone2", side="side")
    prism(rect(-5.8, 5.8, 48.2, 49.8), -4.5, 4.5, 0.45, "gold0", side="gold1", bev=("bevel_gold", "bevel_gold"))
    prism(rect(-2.0, 2.0, 42.6, 47.2), -5.3, 5.3, 0.35, "glow", side="frame", bev=("bevel_gold", "bevel_gold"))
    return {"opening": ("superellipse", dict(a=23.95, b=35.75, cy=4.0, n=2.4, hw0=22.9, ytop=39.75)), "collides": False}


def build_mesa():
    stones = ["stone0", "stone1", "stone2", "stone3"]
    Y0, YB = -1.9, 34.7
    OX = 20.6
    def jamb(sg):
        S = lambda p: (p[0] * sg, p[1])
        prism([S(p) for p in rect(OX, OX + 3.0, Y0, YB + 2.9)], -5.3, 5.3, 0.35, "maroon0", side="side_maroon", bev=("bevel_maroon", "side_maroon"))
        ys = [Y0, 2.4, 6.8, 11.2, 15.6, 20.0, 24.4, 28.8, 33.2, 37.6]
        for ci in range(len(ys) - 1):
            xa, xb = OX + 3.0, 33.4 + (0.6 if ci == 0 else 0.0)
            sp = 28.4 + (1.6 if ci % 2 else 0.0)
            for k, (a, c) in enumerate(((xa, sp), (sp, xb))):
                prism([S(p) for p in rect(a, c, ys[ci], ys[ci + 1])], -5.0, 5.0, 0.42, pick(stones, ci * 2 + k + (1 if sg < 0 else 0)), side="side")
        # brass studs belt on the pier face
        prism([S(p) for p in rect(OX + 3.0, 33.4, 17.2, 19.4)], -5.4, 5.4, 0.35, "gold1", side="gold1", bev=("bevel_gold", "bevel_gold"))
    mirror_pair(jamb)
    # lintel: maroon soffit band, two brick courses, brass cornice, plates, cap
    prism(rect(-OX - 3.0, OX + 3.0, YB, YB + 2.9), -5.3, 5.3, 0.35, "maroon1", side="side_maroon", bev=("bevel_maroon", "side_maroon"))
    for ci, (y0, y1) in enumerate(((37.6, 41.0), (41.0, 44.2))):
        xs = [-33.4, -17.0, 0.0, 17.0, 33.4] if ci == 0 else [-33.4, -8.5, 8.5, 33.4]
        for k in range(len(xs) - 1):
            prism(rect(xs[k], xs[k + 1], y0, y1), -5.0, 5.0, 0.42, pick(stones, ci * 3 + k), side="side")
    prism(rect(-34.0, 34.0, 44.2, 46.7), -5.4, 5.4, 0.45, "gold0", side="gold1", bev=("bevel_gold", "bevel_gold"))
    for cx in (-25.0, 0.0, 25.0):
        prism(rect(cx - 4.0, cx + 4.0, 44.4, 46.5), -5.9, 5.9, 0.4, "gold1", side="gold1", bev=("bevel_gold", "bevel_gold"))
    cx_ = [-33.0, -16.5, 0.0, 16.5, 33.0]
    for k in range(4):
        prism(rect(cx_[k], cx_[k + 1], 46.7, 49.0), -4.6, 4.6, 0.45, pick(stones, k + 1), side="side")
    return {"opening": ("rect", dict(hw=20.0, ytop=34.0)), "collides": True,
            "colliders": [{"centre": [-27.0, 21.3, 0.0], "size": [13.4, 46.0, 10.6]}, {"centre": [27.0, 21.3, 0.0], "size": [13.4, 46.0, 10.6]},
                          {"centre": [0.0, 41.4, 0.0], "size": [67.4, 13.6, 10.6]}]}


def build_gantry():
    HX, HX0 = 38.8, 30.6

    def post(sg):
        S = lambda p: (p[0] * sg, p[1])
        # stone footing (2 courses), post shaft with teal-weathered feet, rope wraps
        for ci, (y0, y1, xa, xb, d) in enumerate(((-0.3, 2.9, 30.0, 39.8, 4.6), (2.9, 5.6, 30.2, 39.4, 4.4))):
            mid = (xa + xb) / 2 + (0.5 if ci else -0.5)
            for k, (a, c) in enumerate(((xa, mid), (mid, xb))):
                prism([S(p) for p in rect(a, c, y0, y1)], -d, d, 0.4, pick(["stone0", "stone1", "stone2"], ci * 2 + k + (1 if sg < 0 else 0)), side="side", bev=("bevel_light", "bevel_mid"))
        prism([S(p) for p in rect(HX0, 38.6, 5.6, 22.2)], -4.0, 4.0, 0.5, "post0" if sg > 0 else "post1", back="post2", side="side", bev=("bevel_light", "bevel_mid"))
        for (ya, yb) in ((7.0, 10.0), (13.0, 16.0)):
            prism([S(p) for p in rect(HX0 - 0.45, 39.05, ya, yb)], -4.45, 4.45, 0.5, "rope", side="rope", bev=("rope", "rope"))
        prism([S(p) for p in rect(32.2, 37.4, 31.0, 34.6)], -3.3, 3.3, 0.45, "teal", side="teal", bev=("bevel_light", "teal"))
        # beam end bracket (carved plate)
        prism([S(p) for p in rect(HX0 + 0.2, 39.0, 22.2, 30.2)], -5.0, 5.0, 0.55, "plank2", side="side", bev=("bevel_light", "bevel_mid"))
    mirror_pair(post)
    xs = [-39.0, -30.6, -14.0, 14.0, 30.6, 39.0]
    for k in range(5):
        prism(rect(xs[k], xs[k + 1], 21.2, 31.0), -4.3, 4.3, 0.55, pick(["plank0", "plank1", "plank2"], k), side="side", bev=("bevel_light", "bevel_mid"))
    # sun medallion (gold rim ring + painted sun disc), both faces
    ring = [(4.65 * math.cos(a), 26.1 + 4.65 * math.sin(a)) for a in np.linspace(0, 2 * math.pi, 16, endpoint=False)]
    disc = [(3.9 * math.cos(a + math.pi / 16), 26.1 + 3.9 * math.sin(a + math.pi / 16)) for a in np.linspace(0, 2 * math.pi, 16, endpoint=False)]
    prism(ring, -5.0, 5.0, 0.3, "gold", side="gold", bev=("bevel_light", "bevel_mid"))
    prism(disc, -5.6, 5.6, 0.3, "sun", side="gold", bev=("bevel_light", "bevel_mid"))
    return {"opening": ("rect", dict(hw=29.9, ytop=20.6)), "collides": True,
            "colliders": [{"centre": [-35.0, 11.0, 0.0], "size": [9.6, 22.6, 9.2]}, {"centre": [35.0, 11.0, 0.0], "size": [9.6, 22.6, 9.2]},
                          {"centre": [0.0, 26.1, 0.0], "size": [78.0, 9.8, 8.6]}]}


def write_glb(path, pos, uv, idx, nrm, tex_rgb):
    P = pos.astype(np.float32)
    N = nrm.astype(np.float32)
    U = uv.astype(np.float32)
    big = len(P) > 65000
    I = idx.astype(np.uint32 if big else np.uint16)
    buf = io.BytesIO()
    views = []

    def add(b, target=None):
        while buf.tell() % 4:
            buf.write(b"\0")
        off = buf.tell()
        buf.write(b)
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(b), **({"target": target} if target else {})})
        return len(views) - 1
    vp, vn, vu, vi = add(P.tobytes(), 34962), add(N.tobytes(), 34962), add(U.tobytes(), 34962), add(I.tobytes(), 34963)
    jb_ = io.BytesIO()
    Image.fromarray(tex_rgb).save(jb_, "JPEG", quality=94, subsampling=0)
    vt = add(jb_.getvalue())
    js = {"asset": {"version": "2.0", "generator": "skyrally art_v3 build_arch_v3.py"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0, "name": "arch_v3"}],
          "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]}],
          "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 1.0}, "doubleSided": False}],
          "textures": [{"source": 0, "sampler": 0}], "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071}],
          "images": [{"bufferView": vt, "mimeType": "image/jpeg"}],
          "accessors": [{"bufferView": vp, "componentType": 5126, "count": len(P), "type": "VEC3", "min": P.min(0).tolist(), "max": P.max(0).tolist()},
                        {"bufferView": vn, "componentType": 5126, "count": len(N), "type": "VEC3"}, {"bufferView": vu, "componentType": 5126, "count": len(U), "type": "VEC2"},
                        {"bufferView": vi, "componentType": 5125 if big else 5123, "count": len(I), "type": "SCALAR"}],
          "bufferViews": views, "buffers": [{"byteLength": buf.tell()}]}
    jb = json.dumps(js, separators=(",", ":")).encode()
    jb += b" " * (-len(jb) % 4)
    bb = buf.getvalue() + b"\0" * (-len(buf.getvalue()) % 4)
    Path(path).write_bytes(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(jb) + 8 + len(bb)) + struct.pack("<II", len(jb), 0x4E4F534A) + jb + struct.pack("<II", len(bb), 0x004E4942) + bb)


def main():
    name, out = sys.argv[1], Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    kind = "wood" if name == "start_gantry" else "stone"
    tex = atlas(kind)
    meta = {"space_arch": build_space, "mesa_portal": build_mesa, "start_gantry": build_gantry}[name]()
    pos, uvs, nrm, idx = [], [], [], []
    for pts, uv in FACES:
        n = np.zeros(3)
        for i in range(len(pts)):
            n += np.cross(pts[i], pts[(i + 1) % len(pts)])
        ln = np.linalg.norm(n)
        n = n / ln if ln > 1e-12 else np.array([0, 0, 1.0])
        b = len(pos)
        pos += [tuple(p) for p in pts]
        uvs += [tuple(u) for u in uv]
        nrm += [tuple(n)] * len(pts)
        for i in range(1, len(pts) - 1):
            idx += [b, b + i, b + i + 1]
    pos, uvs, nrm, idx = np.array(pos), np.array(uvs), np.array(nrm), np.array(idx)
    write_glb(out / f"{name}.glb", pos, uvs, idx, nrm, tex)
    Image.fromarray(tex).save(out / "atlas.png")
    # QC: symmetry, opening intrusion, bbox, texture min value
    mn, mx = pos.min(0), pos.max(0)
    key = lambda p: sorted(map(tuple, np.round(p, 2).tolist()))
    mir = pos.copy()
    mir[:, 0] *= -1
    sym = set(map(tuple, np.round(pos, 2).tolist())) ^ set(map(tuple, np.round(mir, 2).tolist()))
    o = meta["opening"]
    x, y = pos[:, 0], pos[:, 1]
    if o[0] == "rect":
        inside = (np.abs(x) < o[1]["hw"]) & (y < o[1]["ytop"])
    else:
        p = o[1]
        yy = np.clip((y - p["cy"]) / p["b"], 0, 1)
        hw = np.where(y < p["cy"], p["hw0"], p["a"] * np.clip(1 - yy ** p["n"], 0, 1) ** (1 / p["n"]))
        inside = (np.abs(x) < hw) & (y < p["ytop"])
    # tile cells: minimum albedo value
    mv = float(tex.max(-1).min() / 255)
    # open edges (each face is its own vertex set: check by quantised edge pairing)
    from collections import Counter
    ec = Counter()
    for pts, _ in FACES:
        q = np.round(pts, 3)
        for i in range(len(q)):
            a, b = tuple(q[i]), tuple(q[(i + 1) % len(q)])
            ec[tuple(sorted((a, b)))] += 1
    open_edges = sum(1 for v in ec.values() if v == 1)
    st = {"tris": int(len(idx) // 3), "verts": int(len(pos)), "bbox_min": np.round(mn, 3).tolist(), "bbox_max": np.round(mx, 3).tolist(),
          "size_studs_xyz": np.round(mx - mn, 3).tolist(), "bbox_centre": np.round((mx + mn) / 2, 3).tolist(),
          "vertices_inside_required_opening": int(inside.sum()), "mirror_asymmetric_vertices": len(sym), "open_edges": int(open_edges),
          "min_albedo_value": round(mv, 3), "collides": meta["collides"], "colliders": meta.get("colliders", []), "opening": {"kind": o[0], **o[1]}}
    (out / "build.json").write_text(json.dumps(st, indent=1))
    print(json.dumps({k: v for k, v in st.items() if k != "colliders"}))


if __name__ == "__main__":
    main()
