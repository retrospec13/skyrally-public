#!/usr/bin/env python3
"""SkyRally items_v1 2D art (PIL + numpy, original): item_icons/<kind>.png (256, white-outlined emblems),
oil_slick.png (512 oily puddle with rainbow sheen), shield_hex.png (512 seamless soft hex pattern, alpha).
Usage: tools/items_art.py   (writes into assets/models/items_v1)"""
import math, colorsys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops

DEST = Path(__file__).resolve().parents[1] / "assets" / "models" / "items_v1"
SS = 4          # supersample
S = 256 * SS


def P(pts, cx=128, cy=128):
    return [(x * SS, y * SS) for x, y in pts]


def poly(d, pts, fill, line=(40, 30, 50, 255), w=5):
    d.polygon(P(pts), fill=fill)
    d.line(P(pts + [pts[0]]), fill=line, width=w * SS, joint="curve")


def ell(d, box, fill, line=(40, 30, 50, 255), w=5):
    d.ellipse([c * SS for c in box], fill=fill, outline=line, width=w * SS)


def rot(pts, deg, c=(128, 128)):
    a = math.radians(deg); ca, sa = math.cos(a), math.sin(a)
    return [(c[0] + (x - c[0]) * ca - (y - c[1]) * sa, c[1] + (x - c[0]) * sa + (y - c[1]) * ca) for x, y in pts]


def finish(layer, path, outline=11):
    """white outline around the emblem + soft drop shadow, downsample to 256."""
    a = layer.split()[3]
    k = outline * SS * 2 + 1
    grown = a.filter(ImageFilter.MaxFilter(k if k % 2 else k + 1))
    grown = grown.filter(ImageFilter.GaussianBlur(SS * 0.8))
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    sh = Image.new("RGBA", layer.size, (20, 15, 40, 0))
    shadow_a = grown.filter(ImageFilter.GaussianBlur(SS * 3)).point(lambda v: int(v * 0.35))
    sh.putalpha(shadow_a)
    sh = ImageChops.offset(sh, 0, 4 * SS)
    out = Image.alpha_composite(out, sh)
    white = Image.new("RGBA", layer.size, (255, 255, 255, 255)); white.putalpha(grown)
    out = Image.alpha_composite(out, white)
    out = Image.alpha_composite(out, layer)
    out = out.resize((256, 256), Image.LANCZOS)
    out.save(path)


def new():
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def icon_missile():
    im, d = new()
    # rocket drawn pointing up, then rotated 45 deg (to the upper right)
    body = Image.new("RGBA", (S, S), (0, 0, 0, 0)); bd = ImageDraw.Draw(body)
    poly(bd, [(100, 150), (60, 200), (96, 190), (112, 170)], (230, 60, 55, 255))       # left fin
    poly(bd, [(156, 150), (196, 200), (160, 190), (144, 170)], (230, 60, 55, 255))     # right fin
    poly(bd, [(110, 175), (128, 232), (146, 175)], (255, 170, 40, 255))                # flame
    poly(bd, [(118, 178), (128, 210), (138, 178)], (255, 240, 130, 255), w=0)
    poly(bd, [(100, 70), (100, 180), (156, 180), (156, 70)], (250, 245, 235, 255))    # body (nose built below)
    # nose
    nose = [(100, 72)]
    for k in range(1, 10):
        t = math.pi * k / 9
        nose.append((128 - 28 * math.cos(t), 72 - 50 * math.sin(t)))
    poly(bd, nose, (235, 60, 55, 255))
    poly(bd, [(100, 118), (156, 118), (156, 136), (100, 136)], (255, 205, 50, 255), w=4)
    ell(bd, (112, 140, 144, 172), (90, 170, 255, 255), w=4)
    body = body.rotate(-45, resample=Image.BICUBIC, center=(S // 2, S // 2)) if False else body
    # rotate manually at supersampled size
    body = body.rotate(-42, resample=Image.BICUBIC, center=(128 * SS, 140 * SS))
    body = body.transform(body.size, Image.AFFINE, (1, 0, -6 * SS, 0, 1, 2 * SS), resample=Image.BICUBIC)
    return body


def icon_boost():
    im, d = new()
    blue = (60, 190, 255, 255); dk = (28, 90, 190, 255)
    for k, (dy, col) in enumerate(((52, (255, 255, 255, 255)), (0, blue), (-52, blue))):
        pass
    # three stacked chevrons pointing up, plus a speed streak each side
    for i, dy in enumerate((76, 32, -12)):
        pts = [(128, 30 + 80 + dy - 70), (214, 100 + dy - 40 + 40 - 40), (214, 138 + dy - 40), (128, 70 + 80 + dy - 70 + 0), (42, 138 + dy - 40), (42, 100 + dy - 40 + 40 - 40)]
        pts = [(128, 44 + dy), (210, 126 + dy - 10), (210, 164 + dy - 10), (128, 82 + dy), (46, 164 + dy - 10), (46, 126 + dy - 10)]
        poly(d, pts, (60 + i * 40, 195 - i * 10, 255, 255) if i else (30, 140, 245, 255))
    return im


def icon_shield():
    im, d = new()
    outer = [(128, 28), (206, 52), (212, 120), (190, 178), (128, 230), (66, 178), (44, 120), (50, 52)]
    # smooth the polygon with more points via simple Chaikin
    def chaikin(pts, n=3):
        for _ in range(n):
            new = []
            for i in range(len(pts)):
                p, q = pts[i], pts[(i + 1) % len(pts)]
                new += [(0.75 * p[0] + 0.25 * q[0], 0.75 * p[1] + 0.25 * q[1]), (0.25 * p[0] + 0.75 * q[0], 0.25 * p[1] + 0.75 * q[1])]
            pts = new
        return pts
    o = chaikin(outer)
    poly(d, o, (255, 205, 45, 255))
    inner = chaikin([(128, 52), (186, 68), (190, 120), (172, 164), (128, 206), (84, 164), (66, 120), (70, 68)])
    poly(d, inner, (255, 160, 30, 255), w=3)
    # star
    star = []
    for k in range(10):
        r = 42 if k % 2 == 0 else 18
        a = -math.pi / 2 + math.pi * k / 5
        star.append((128 + r * math.cos(a), 118 + r * math.sin(a)))
    poly(d, star, (255, 250, 200, 255), w=3)
    return im


def icon_trap():
    im, d = new()
    green = (95, 215, 80, 255); dk = (40, 120, 50, 255)
    # spiked ball
    for k in range(12):
        a = 2 * math.pi * k / 12
        tip = (128 + 104 * math.cos(a), 128 + 104 * math.sin(a))
        l = (128 + 62 * math.cos(a - 0.26), 128 + 62 * math.sin(a - 0.26))
        r = (128 + 62 * math.cos(a + 0.26), 128 + 62 * math.sin(a + 0.26))
        poly(d, [l, tip, r], (200, 230, 90, 255), w=4)
    ell(d, (52, 52, 204, 204), green)
    ell(d, (66, 66, 190, 190), (70, 185, 70, 0), line=(0, 0, 0, 0), w=0)
    # exclamation mark
    poly(d, [(116, 88), (140, 88), (134, 142), (122, 142)], (255, 255, 255, 255), w=4)
    ell(d, (116, 150, 140, 174), (255, 255, 255, 255), w=4)
    # highlight
    ell(d, (74, 70, 104, 92), (190, 255, 170, 255), line=(0, 0, 0, 0), w=0)
    return im


def icon_magnet():
    im, d = new()
    red = (235, 60, 70, 255); sil = (225, 230, 240, 255)
    # horseshoe: thick arc
    cx, cy = 128, 112
    ro, ri = 78, 38
    outer, inner = [], []
    for k in range(0, 19):
        a = math.pi + math.pi * k / 18
        outer.append((cx + ro * math.cos(a), cy - 0 + ro * math.sin(a) * -1))
    # build arc over the top: angles from 180 to 360 in screen coords (y down) -> use -sin for upward
    arc_o = [(cx + ro * math.cos(math.pi * k / 18), cy - ro * math.sin(math.pi * k / 18)) for k in range(19)]
    arc_i = [(cx + ri * math.cos(math.pi * k / 18), cy - ri * math.sin(math.pi * k / 18)) for k in range(19)]
    legs_y = 196
    shape = arc_o + [(cx - ro, legs_y), (cx - ri, legs_y)] + arc_i[::-1] + [(cx + ri, legs_y), (cx + ro, legs_y)]
    shape = [(x, y) for x, y in arc_o] + [(cx - ro, legs_y), (cx - ri, legs_y)] + [(x, y) for x, y in arc_i[::-1]] + [(cx + ri, legs_y), (cx + ro, legs_y)]
    # polygon order: outer arc from right (k=0 -> angle 0 -> right) over to left, down left leg, inner arc back, right leg
    poly(d, shape, red)
    # silver tips
    poly(d, [(cx - ro, 150), (cx - ri, 150), (cx - ri, legs_y), (cx - ro, legs_y)], sil)
    poly(d, [(cx + ri, 150), (cx + ro, 150), (cx + ro, legs_y), (cx + ri, legs_y)], sil)
    # highlight
    d.line(P([(cx - 62, 98), (cx - 44, 60), (cx - 10, 42)]), fill=(255, 170, 170, 255), width=7 * SS, joint="curve")
    # attraction sparks
    for sx in (-1, 1):
        for (x, y, l) in ((46, 224, 30), (30, 214, 22)):
            pass
    for sx in (-1, 1):
        d.line(P([(cx + sx * 58, 222), (cx + sx * 36, 236)]), fill=(255, 215, 60, 255), width=8 * SS)
        d.line(P([(cx + sx * 20, 226), (cx + sx * 14, 244)]), fill=(255, 215, 60, 255), width=8 * SS)
    return im.transform(im.size, Image.AFFINE, (1, 0, 0, 0, 1, 12 * SS), resample=Image.BICUBIC)


def make_icons():
    out = DEST / "item_icons"; out.mkdir(parents=True, exist_ok=True)
    for name, fn in (("missile", icon_missile), ("boost", icon_boost), ("shield", icon_shield), ("trap", icon_trap), ("magnet", icon_magnet)):
        finish(fn(), out / f"{name}.png")


# ------------------------------------------------------------------ oil slick

def smooth_noise(n, scale, rng):
    g = rng.random((scale, scale)).astype(np.float32)
    im = Image.fromarray((g * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC)
    return np.asarray(im, np.float32) / 255.0


def make_oil(n=512):
    rng = np.random.default_rng(11)
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    cx = cy = n / 2
    dx, dy = (xx - cx) / (n / 2), (yy - cy) / (n / 2)
    r = np.sqrt(dx * dx + dy * dy)
    th = np.arctan2(dy, dx)
    rad = 0.62 + sum(a * np.sin(k * th + ph) for a, k, ph in ((0.07, 2, 0.3), (0.05, 3, 1.7), (0.035, 5, 4.0), (0.02, 8, 2.2)))
    d = r - rad
    mask = np.clip(0.5 - d / 0.012, 0, 1)
    # satellite droplets
    for _ in range(7):
        a = rng.random() * 2 * math.pi; rr = 0.78 + rng.random() * 0.12; sr = 0.03 + rng.random() * 0.04
        ddx, ddy = dx - rr * math.cos(a), dy - rr * math.sin(a)
        mask = np.maximum(mask, np.clip(0.5 - (np.sqrt(ddx * ddx + ddy * ddy) - sr) / 0.02, 0, 1))
    n1 = smooth_noise(n, 6, rng); n2 = smooth_noise(n, 14, rng); n3 = smooth_noise(n, 3, rng)
    hue = (n1 * 1.4 + n2 * 0.25 + r * 0.8) % 1.0
    # thin-film sheen: iridescent bands, stronger away from centre and along a diagonal highlight
    sheen = np.clip(0.25 + 0.55 * n3 + 0.4 * np.sin((dx * 0.8 + dy * 0.5) * 9 + n1 * 5), 0, 1) * np.clip(r / 0.6, 0.25, 1.0)
    rgb = np.zeros((n, n, 3), np.float32)
    base = np.array([18, 16, 26], np.float32) / 255.0
    base_lit = base + (n2[..., None] - 0.5) * 0.05
    hv = np.vectorize(lambda h: colorsys.hsv_to_rgb(h, 0.75, 1.0), otypes=[np.float32, np.float32, np.float32])
    # vectorised hsv->rgb
    h6 = hue * 6; i = np.floor(h6).astype(int) % 6; f = h6 - np.floor(h6)
    v = 1.0; s = 0.7
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    R = np.choose(i, [np.full_like(f, v), q, np.full_like(f, p), np.full_like(f, p), t, np.full_like(f, v)])
    G = np.choose(i, [t, np.full_like(f, v), np.full_like(f, v), q, np.full_like(f, p), np.full_like(f, p)])
    Bc = np.choose(i, [np.full_like(f, p), np.full_like(f, p), t, np.full_like(f, v), np.full_like(f, v), q])
    film = np.stack([R, G, Bc], -1)
    w = (sheen * 0.75)[..., None]
    rgb = base_lit * (1 - w) + film * w
    # specular glints
    glint = np.exp(-(((dx + 0.25) / 0.22) ** 2 + ((dy + 0.3) / 0.07) ** 2)) * 0.5
    rgb = np.clip(rgb + glint[..., None], 0, 1)
    alpha = mask * np.clip(0.88 + 0.1 * (1 - r), 0, 1)
    out = np.dstack([rgb, alpha])
    Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA").save(DEST / "oil_slick.png")


# ------------------------------------------------------------------ shield hex

def make_hex(n=512, cols=12, pairs=7):
    rng = np.random.default_rng(5)
    w = n / cols                      # horizontal cell pitch
    P_y = n / pairs                   # vertical period of two rows
    ysc = (math.sqrt(3) * w) / P_y    # stretch so cells are regular after scaling
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    y = yy * ysc
    Py = math.sqrt(3) * w

    def hexd(ox, oy):
        dx = ((xx - ox + w / 2) % w) - w / 2
        dy = ((y - oy + Py / 2) % Py) - Py / 2
        ax, ay = np.abs(dx), np.abs(dy)
        return np.maximum(ax, 0.5 * ax + 0.8660254 * ay), dx, dy

    dA, _, _ = hexd(0, 0)
    dB, _, _ = hexd(w / 2, Py / 2)
    d = np.minimum(dA, dB)
    use_a = dA <= dB
    # cell id hashes for per-cell brightness
    ia = np.floor((xx + w / 2) / w) % cols; ja = np.floor((y + Py / 2) / Py) % pairs
    ib = np.floor(xx / w) % cols; jb = np.floor(y / Py) % pairs
    idA = ia * 31 + ja * 17; idB = ib * 31 + jb * 17 + 101
    cid = np.where(use_a, idA, idB)
    hsh = (np.sin(cid * 12.9898) * 43758.5453) % 1.0
    apo = w / 2
    edge = np.clip((d - apo * 0.80) / (apo * 0.20), 0, 1)           # soft glow toward the cell borders
    line = np.clip(1 - np.abs(d - apo * 0.97) / (apo * 0.07), 0, 1)  # hard-ish thin border
    # note: d is the min over both lattices so it reaches apothem on shared edges
    edge = edge ** 1.6
    alpha = 0.06 + 0.10 * hsh + 0.38 * edge + 0.45 * line
    alpha = np.clip(alpha, 0, 1)
    rgb = np.ones((n, n, 3), np.float32)
    rgb[..., 0] = 0.86 + 0.14 * edge; rgb[..., 1] = 0.96 + 0.04 * edge
    out = np.dstack([rgb, alpha])
    Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA").save(DEST / "shield_hex.png")


if __name__ == "__main__":
    DEST.mkdir(parents=True, exist_ok=True)
    make_icons(); make_oil(); make_hex()
    print("ART_OK")
