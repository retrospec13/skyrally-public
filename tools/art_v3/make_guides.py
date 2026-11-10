#!/usr/bin/env python3
"""Per-asset flat front proportion guide (stone silhouette + dark opening) and the opening profile open.json for the fit.
Frame: x centred, y up from the model base (studs). Usage: make_guides.py  (writes assets/models/arches_v3/<name>/{proportion_guide.png,open.json})"""
import json, math
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets/models/arches_v3"


def ell(xc, yc, a, b, y0, y1, n=60):
    pts = []
    for i in range(n + 1):
        y = y0 + (y1 - y0) * i / n
        v = 1 - ((y - yc) / b) ** 2
        pts.append((y, a * math.sqrt(max(v, 0))))
    return pts


A = {}
# name: (outline polys [(x,y)...] in studs, opening profile [(y,hw)], target clear, depth)
A["portal_gate"] = dict(
    outline=[[(-24, 0), (24, 0), (24, 3), (22, 3), (22, 38), (7, 38), (7, 44), (-7, 44), (-7, 38), (-22, 38), (-22, 3), (-24, 3)]],
    open=[(0, 14), (30.5, 14)], clear=0.3, depth=9, bury=0.5)
yc, a, b = 4.0, 23.95, 35.75
sky_open = [(0, 22.9), (9, 22.9), (9.5, 23.6)] + [p for p in ell(0, yc, a, b, 10.0, yc + b)]
sky_out = [(-29.5, 0), (29.5, 0)] + [(math.sqrt(max(1 - ((y - yc) / 41) ** 2, 0)) * 29.5, y) for y in [yc + 41 * math.sin(t) for t in [i * math.pi / 2 / 40 for i in range(41)]] if y >= 4]
sky_poly = [(-37, 0), (37, 0), (37, 4)] + [(37 * math.cos(t), 4 + 49 * math.sin(t)) for t in [i * math.pi / 2 / 40 for i in range(0, 41)]]
sky_poly += [(-x, y) for x, y in reversed(sky_poly[3:])] + [(-37, 4)]
A["space_arch"] = dict(outline=[sky_poly], open=sky_open, clear=0.3, depth=8, bury=0.8)
A["start_gantry"] = dict(
    outline=[[(-41, 0), (-30.4, 0), (-30.4, 27), (30.4, 27), (30.4, 0), (41, 0), (41, 40), (-41, 40)]],
    open=[(0, 29.9), (26, 29.9)], clear=0.6, depth=11, bury=0.3)
A["snow_finish_gantry"] = dict(
    outline=[[(-57, 0), (-49.5, 0), (-49.5, 46.5), (49.5, 46.5), (49.5, 0), (57, 0), (57, 8), (54.5, 8), (54.5, 55), (57, 55), (57, 66), (52, 66), (52, 55), (-52, 55), (-52, 66), (-57, 66), (-57, 55), (-54.5, 55), (-54.5, 8), (-57, 8)]],
    open=[(0, 49.5), (46.5, 49.5)], clear=0.5, depth=11, bury=3.0)
cv = [(0, 31.25), (30, 31.25)] + [(30 + 31.5 * math.sin(t), 31.5 * math.cos(t)) for t in [i * 0.5 * math.pi / 30 for i in range(1, 31)]]
cv = [(y, w) for y, w in cv if y <= 60.5]
cv.append((60.5, cv[-1][1]))
cav_out = [(-39.5, 0), (39.5, 0)] + [(39.5 * math.cos(t), 30 + 39.5 * math.sin(t)) for t in [i * 0.5 * math.pi / 40 for i in range(0, 41)]]
cav_out = cav_out + [(-x, y) for x, y in reversed(cav_out[2:])]
A["cavern_arch"] = dict(outline=[cav_out], open=cv, clear=0.5, depth=13, bury=1.5)
A["mine_portal"] = dict(
    outline=[[(-33, 0), (33, 0), (33, 8), (28, 8), (28, 40), (31, 40), (31, 44), (0, 47.4), (-31, 44), (-31, 40), (-28, 40), (-28, 8), (-33, 8)]],
    open=[(0, 19), (33, 19)], clear=0.6, depth=12, bury=2.0)
A["mesa_portal"] = dict(
    outline=[[(-32.2, 0), (32.2, 0), (32.2, 46), (24, 48.6), (-24, 48.6), (-32.2, 46)]],
    open=[(0, 20), (34, 20)], clear=0.6, depth=10, bury=1.9)

if __name__ == "__main__":
    import sys
    for name, s in A.items():
        if len(sys.argv) > 1 and name not in sys.argv[1:]:
            continue
        d = OUT / name
        d.mkdir(parents=True, exist_ok=True)
        pts = [list(map(float, p)) for p in s["open"]]
        (d / "open.json").write_text(json.dumps({"pts": pts, "clear": s["clear"], "depth": s["depth"], "bury": s["bury"]}))
        xs = [x for poly in s["outline"] for x, _ in poly]
        ys = [y for poly in s["outline"] for _, y in poly]
        sc = 780 / max(max(xs) - min(xs), max(ys) - min(ys))
        im = Image.new("RGB", (1024, 1024), (214, 214, 216))
        dr = ImageDraw.Draw(im)
        X = lambda x: 512 + x * sc
        Y = lambda y: 900 - y * sc
        for poly in s["outline"]:
            dr.polygon([(X(x), Y(y)) for x, y in poly], fill=(170, 150, 118))
        op = [(-w, y) for y, w in s["open"]]
        poly = [(X(w), Y(y)) for y, w in s["open"]] + [(X(-w), Y(y)) for y, w in reversed(s["open"])]
        dr.polygon(poly, fill=(214, 214, 216))
        im.save(d / "proportion_guide.png")
        print(name, "guide", round(max(xs) - min(xs), 1), "x", round(max(ys), 1))
