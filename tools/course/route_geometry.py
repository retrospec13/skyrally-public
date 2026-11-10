#!/usr/bin/env python3
"""Route geometry gate (L02, reused by every map's plan): horizontal turn radius and grade along a closed
waypoint polyline. Input: JSON list of [x,y,z] waypoints (closed, last == first) or a builder port.
Flags stretches where the turn radius is under --min-radius or the grade exceeds --max-grade-deg."""
import argparse
import json
import math
import sys

import numpy as np


def resample(pts, step):
    pts = [np.array(p, float) for p in pts]
    seg = [np.linalg.norm(pts[i + 1] - pts[i]) for i in range(len(pts) - 1)]
    L = sum(seg)
    out, s, i, acc = [], 0.0, 0, 0.0
    while s < L:
        while i < len(seg) - 1 and acc + seg[i] < s:
            acc += seg[i]; i += 1
        t = (s - acc) / seg[i] if seg[i] > 0 else 0
        out.append((s, pts[i] + (pts[i + 1] - pts[i]) * t))
        s += step
    return out, L


def radius3(a, b, c):
    a, b, c = (np.array([p[0], p[2]]) for p in (a, b, c))
    ab, bc, ca = np.linalg.norm(b - a), np.linalg.norm(c - b), np.linalg.norm(a - c)
    cross = abs((b - a)[0] * (c - a)[1] - (b - a)[1] * (c - a)[0])
    return math.inf if cross < 1e-6 else ab * bc * ca / (2 * cross)


def analyse(pts, step=10, base=30, min_radius=100, max_grade=25):
    samples, L = resample(pts, step)
    n = len(samples)
    k = max(1, base // step)
    rows = []
    for j in range(n):
        s, p = samples[j]
        a, c = samples[(j - k) % n][1], samples[(j + k) % n][1]
        r = radius3(a, p, c)
        nxt = samples[(j + 1) % n][1]
        h = math.hypot(nxt[0] - p[0], nxt[2] - p[2])
        grade = math.degrees(math.atan2(nxt[1] - p[1], h)) if h > 0 else 0
        rows.append({"st": round(s), "r": r, "grade": grade, "pos": [round(float(v)) for v in p]})
    return rows, L


def stretches(rows, pred):
    out, cur = [], []
    for r in rows:
        if pred(r):
            cur.append(r)
        elif cur:
            out.append(cur); cur = []
    if cur:
        out.append(cur)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("waypoints_json")
    ap.add_argument("--min-radius", type=float, default=100)
    ap.add_argument("--max-grade-deg", type=float, default=25)
    a = ap.parse_args()
    pts = json.load(open(a.waypoints_json))
    rows, L = analyse(pts, min_radius=a.min_radius, max_grade=a.max_grade_deg)
    print(f"length={L:.1f} samples={len(rows)} minRadius={min(r['r'] for r in rows):.0f}")
    bad = stretches(rows, lambda r: r["r"] < a.min_radius)
    for b in bad:
        m = min(b, key=lambda r: r["r"])
        print(f"TIGHT st {b[0]['st']}-{b[-1]['st']} minR={m['r']:.0f} at st {m['st']} pos {m['pos']}")
    steep = stretches(rows, lambda r: abs(r["grade"]) > a.max_grade_deg)
    for b in steep:
        m = max(b, key=lambda r: abs(r["grade"]))
        print(f"STEEP st {b[0]['st']}-{b[-1]['st']} maxGrade={m['grade']:.0f}deg at st {m['st']}")
    sys.exit(1 if bad or steep else 0)


if __name__ == "__main__":
    main()
