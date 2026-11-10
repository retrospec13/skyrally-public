#!/usr/bin/env python3
"""Zone-emblem iris masks for Portal Plunge (REMARKABLE Batch 2 item 20), drawn in code (original, licence-free: this
source is the record). Two PNGs per zone: iris_<zone> is an opaque WHITE cover with an emblem-shaped transparent HOLE in
the middle, iris_<zone>_rim is only the thin white rim around that hole. client/PortalPlunge stacks them and tints each
with ImageColor3 (cover: near-black when plunging, the curtain's zone colour when opening; rim: the zone accent).
Scaled down over the screen they close a late-90s style iris onto the car, in the shape of the zone you plunge into.

  iris_dino    a hatching (cracked) dino egg     iris_snow    a chunky six-armed snowflake
  iris_island  a scallop shell                iris_forest  a leaf with a centre vein notch
  iris_space   a crescent moon and a star     iris_hub     an eight-point compass star

The hole spans about HOLE_FRACTION of the image (PortalPlunge.HOLE_FRACTION must match). 512 x 512 RGBA.
Usage: make_iris_emblems.py <out_dir>"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

N = 2048  # drawn at 4x, downsampled for clean edges
OUT = 512
C = N / 2
R = N * 0.2  # emblem "radius": the hole spans ~40 % of the image (HOLE_FRACTION 0.4)


def star_points(cx, cy, r_out, r_in, n, rot=-math.pi / 2):
    pts = []
    for i in range(n * 2):
        r = r_out if i % 2 == 0 else r_in
        a = rot + i * math.pi / n
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def egg(d):
    pts = []
    for i in range(361):
        t = math.radians(i)
        x = math.sin(t) * 0.86 * (1 - 0.18 * math.cos(t))
        y = -math.cos(t) * 1.12
        pts.append((C + R * x, C + R * 0.08 + R * y))
    d.polygon(pts, fill=255)


def egg_crack(img):
    # a zig-zag crack across the shell (carved back to black) so it reads as a hatching dino egg
    d = ImageDraw.Draw(img)
    zig = [(C - R * 0.95, C - R * 0.05), (C - R * 0.55, C - R * 0.3), (C - R * 0.2, C + R * 0.02), (C + R * 0.15, C - R * 0.32),
           (C + R * 0.5, C - R * 0.02), (C + R * 0.95, C - R * 0.25)]
    d.line(zig, fill=0, width=int(R * 0.09), joint="curve")


def snowflake(d):
    d.regular_polygon((C, C, R * 0.42), 6, fill=255)
    for k in range(6):
        a = k * math.pi / 3
        ux, uy = math.cos(a), math.sin(a)
        px, py = -uy, ux
        w = R * 0.16
        arm = [(C + px * w, C + py * w), (C + ux * R * 1.05 + px * w, C + uy * R * 1.05 + py * w),
               (C + ux * R * 1.05 - px * w, C + uy * R * 1.05 - py * w), (C - px * w, C - py * w)]
        d.polygon(arm, fill=255)
        d.ellipse([C + ux * R * 1.05 - w, C + uy * R * 1.05 - w, C + ux * R * 1.05 + w, C + uy * R * 1.05 + w], fill=255)
        for s in (-1, 1):
            bx, by = C + ux * R * 0.62, C + uy * R * 0.62
            b2 = a + s * math.pi / 4
            ex, ey = bx + math.cos(b2) * R * 0.38, by + math.sin(b2) * R * 0.38
            d.line([(bx, by), (ex, ey)], fill=255, width=int(w * 1.4))
            d.ellipse([ex - w * 0.7, ey - w * 0.7, ex + w * 0.7, ey + w * 0.7], fill=255)


def scallop(d):
    # fan of seven rounded ribs over a hinge
    base = (C, C + R * 0.85)
    for k in range(7):
        a = math.radians(-150 + k * 20)
        tip = (C + math.cos(a) * R * 1.15, C + R * 0.85 + math.sin(a) * R * 1.75)
        d.line([base, tip], fill=255, width=int(R * 0.36))
        d.ellipse([tip[0] - R * 0.2, tip[1] - R * 0.2, tip[0] + R * 0.2, tip[1] + R * 0.2], fill=255)
    d.pieslice([C - R * 1.1, C - R * 0.75, C + R * 1.1, C + R * 2.45], 200, 340, fill=255)
    d.polygon([(C - R * 0.45, C + R * 0.85), (C + R * 0.45, C + R * 0.85), (C + R * 0.3, C + R * 1.12), (C - R * 0.3, C + R * 1.12)], fill=255)


def leaf(d):
    pts = []
    for i in range(361):
        t = math.radians(i)
        x = math.sin(t) * 0.78 * (1 - 0.15 * math.cos(t))
        y = -math.cos(t) * 1.15
        pts.append((C + R * x, C + R * y))
    d.polygon(pts, fill=255)
    d.line([(C, C + R * 1.05), (C + R * 0.2, C + R * 1.45)], fill=255, width=int(R * 0.14))


def leaf_vein(img):
    # carve a thin vein back out (black) so the leaf reads as a leaf at small sizes
    d = ImageDraw.Draw(img)
    d.line([(C, C - R * 0.8), (C, C + R * 0.9)], fill=0, width=int(R * 0.07))


def crescent(d, img):
    d.ellipse([C - R * 1.05, C - R * 1.05, C + R * 1.05, C + R * 1.05], fill=255)
    cut = Image.new("L", img.size, 0)
    ImageDraw.Draw(cut).ellipse([C - R * 0.55, C - R * 1.2, C + R * 1.35, C + R * 0.7], fill=255)
    img.paste(ImageChops.subtract(img, cut))
    ImageDraw.Draw(img).polygon(star_points(C + R * 0.55, C - R * 0.05, R * 0.42, R * 0.18, 5), fill=255)


def compass(d):
    d.polygon(star_points(C, C, R * 1.15, R * 0.36, 4), fill=255)
    d.polygon(star_points(C, C, R * 0.78, R * 0.3, 4, rot=-math.pi / 2 + math.pi / 4), fill=255)
    d.ellipse([C - R * 0.3, C - R * 0.3, C + R * 0.3, C + R * 0.3], fill=255)


def render(draw_fn):
    hole = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(hole)
    if draw_fn is crescent:
        crescent(d, hole)
    else:
        draw_fn(d)
    if draw_fn is leaf:
        leaf_vein(hole)
    if draw_fn is egg:
        egg_crack(hole)
    hole = hole.filter(ImageFilter.GaussianBlur(3))
    rim = hole.filter(ImageFilter.MaxFilter(41))
    rim = ImageChops.subtract(rim, hole)
    white = Image.new("L", (N, N), 255)
    cover = Image.merge("RGBA", (white, white, white, ImageChops.invert(hole)))  # opaque outside the hole
    ring = Image.merge("RGBA", (white, white, white, rim))
    return cover.resize((OUT, OUT), Image.LANCZOS), ring.resize((OUT, OUT), Image.LANCZOS)


SHAPES = {
    "iris_dino": egg,
    "iris_snow": snowflake,
    "iris_island": scallop,
    "iris_forest": leaf,
    "iris_space": crescent,
    "iris_hub": compass,
}


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in SHAPES.items():
        cover, ring = render(fn)
        cover.save(out / f"{name}.png")
        ring.save(out / f"{name}_rim.png")
        print("IRIS", out / f"{name}.png", "+ rim")


if __name__ == "__main__":
    main()
