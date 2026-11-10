#!/usr/bin/env python3
"""Bake the Curtain Kart mini tracks (docs/REMARKABLE.md item 8).

For every build/<key>/TrackData.luau (the adapter's sampled, flex-scaled route, so the outline is the road you
actually race), take the waypoint (x, z) loop, simplify it with Douglas-Peucker to at most MAX_POINTS points (the
smallest tolerance that fits, so tight corners survive), normalise it into a unit box with the aspect ratio kept
(long side = 1, min corner at 0) and write src/shared/CurtainTracks.luau:

    { [trackId] = { points = { {x, y}, ... }, startIndex = 1, w = <width>, h = <height>, length = <perimeter> } }

Screen x = world X, screen y = world Z, the same orientation as map/<id>/preview_topdown.png. Point 1 is waypoint 1
(the start line) and the loop runs in race direction. A map with no TrackData falls back to its plan.json route nodes
through a closed Catmull-Rom spline.

Usage: python3 tools/bake_curtain_tracks.py [--check]   (--check exits 1 when the committed module is stale)
"""
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "src" / "shared" / "CurtainTracks.luau"
MAX_POINTS = 48
MIN_POINTS = 12

VEC = r"Vector3\.new\(\s*(-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+)\s*\)"


def track_data_loop(path: Path):
    """(id, [(x, z), ...]) from a generated TrackData.luau: the top-level `waypoints = {` block only."""
    text = path.read_text()
    mid = re.search(r'^\tid = "([^"]+)"', text, re.M)
    block = re.search(r"^\twaypoints = \{\n(.*?)^\t\},?$", text, re.M | re.S)
    if not (mid and block):
        return None
    pts = []
    for line in block.group(1).splitlines():
        m = re.search(r"pos = " + VEC, line)
        if m:
            pts.append((float(m.group(1)), float(m.group(3))))
    return mid.group(1), pts


def catmull_closed(nodes, per_seg=12):
    out = []
    n = len(nodes)
    for i in range(n):
        p0, p1, p2, p3 = nodes[(i - 1) % n], nodes[i], nodes[(i + 1) % n], nodes[(i + 2) % n]
        for k in range(per_seg):
            t = k / per_seg
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * (2 * p1[j] + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in range(2)))
    return out


def plan_loop(path: Path):
    sr = json.loads(path.read_text()).get("skyrally", {})
    nodes = [(n["pos"][0], n["pos"][2]) for n in sr.get("route", {}).get("nodes", [])]
    if len(nodes) < 3 or not sr.get("id"):
        return None
    return sr["id"], catmull_closed(nodes)


def seg_dist(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    L2 = dx * dx + dy * dy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L2))
    return math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy)


def dp(pts, eps):
    """Douglas-Peucker on an open polyline (iterative); keeps both ends."""
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        best, idx = -1.0, -1
        for k in range(i + 1, j):
            d = seg_dist(pts[k], pts[i], pts[j])
            if d > best:
                best, idx = d, k
        if idx >= 0 and best > eps:
            keep[idx] = True
            stack.append((i, idx))
            stack.append((idx, j))
    return [p for p, k in zip(pts, keep) if k]


def dp_closed(pts, eps):
    """Closed loop: split at point 0 and the point farthest from it, simplify both halves, keep point 0 first."""
    far = max(range(len(pts)), key=lambda k: math.hypot(pts[k][0] - pts[0][0], pts[k][1] - pts[0][1]))
    a = dp(pts[: far + 1], eps)
    b = dp(pts[far:] + [pts[0]], eps)
    return a[:-1] + b[:-1]


def simplify(pts):
    # Drop a duplicated closing point.
    if math.hypot(pts[0][0] - pts[-1][0], pts[0][1] - pts[-1][1]) < 1e-6:
        pts = pts[:-1]
    if len(pts) <= MAX_POINTS:
        return pts
    lo, hi = 0.0, max(max(p[0] for p in pts) - min(p[0] for p in pts), max(p[1] for p in pts) - min(p[1] for p in pts))
    best = dp_closed(pts, hi)
    for _ in range(40):
        mid = (lo + hi) / 2
        s = dp_closed(pts, mid)
        if len(s) <= MAX_POINTS:
            best, hi = s, mid
        else:
            lo = mid
    return best


def normalise(pts):
    x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
    y0, y1 = min(p[1] for p in pts), max(p[1] for p in pts)
    span = max(x1 - x0, y1 - y0) or 1.0
    out = [((p[0] - x0) / span, (p[1] - y0) / span) for p in pts]
    return out, (x1 - x0) / span, (y1 - y0) / span


def perimeter(pts):
    return sum(math.hypot(pts[(i + 1) % len(pts)][0] - pts[i][0], pts[(i + 1) % len(pts)][1] - pts[i][1]) for i in range(len(pts)))


def fmt(v):
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def bake():
    tracks = {}
    sources = {}
    for d in sorted(p for p in (ROOT / "build").iterdir() if p.is_dir()):
        got = None
        td = d / "TrackData.luau"
        if td.exists():
            got = track_data_loop(td)
            src = f"build/{d.name}/TrackData.luau"
        if not got or len(got[1]) < 3:
            plan = ROOT / "map" / d.name / "plan.json"
            got = plan_loop(plan) if plan.exists() else None
            src = f"map/{d.name}/plan.json"
        if not got:
            continue
        tid, raw = got
        simp = simplify(raw)
        if len(simp) < MIN_POINTS:
            raise SystemExit(f"{tid}: only {len(simp)} points after simplifying")
        pts, w, h = normalise(simp)
        tracks[tid] = {"points": pts, "w": w, "h": h, "length": perimeter(pts)}
        sources[tid] = (src, len(raw))
    lines = [
        "--!strict",
        "-- GENERATED by tools/bake_curtain_tracks.py from build/*/TrackData.luau waypoints (top-down x, z; Douglas-Peucker",
        f"-- to at most {MAX_POINTS} points; unit box, long side = 1, aspect kept; point 1 = start line, race direction).",
        "-- Do not edit by hand: rerun the bake after a route change. Read by client/CurtainKart (REMARKABLE item 8).",
        "export type CurtainTrack = { points: { { number } }, startIndex: number, w: number, h: number, length: number }",
        "",
        "local tracks: { [string]: CurtainTrack } = {",
    ]
    for tid in sorted(tracks):
        t = tracks[tid]
        src, n = sources[tid]
        lines.append(f'\t["{tid}"] = {{ -- {src}: {n} waypoints -> {len(t["points"])} points')
        lines.append(f'\t\tstartIndex = 1, w = {fmt(t["w"])}, h = {fmt(t["h"])}, length = {fmt(t["length"])},')
        lines.append("\t\tpoints = {")
        row = []
        for k, p in enumerate(t["points"]):
            row.append(f"{{ {fmt(p[0])}, {fmt(p[1])} }}")
            if len(row) == 6 or k == len(t["points"]) - 1:
                lines.append("\t\t\t" + ", ".join(row) + ",")
                row = []
        lines.append("\t\t},")
        lines.append("\t},")
    lines += ["}", "", "return tracks", ""]
    return "\n".join(lines), tracks


def main():
    text, tracks = bake()
    if "--check" in sys.argv:
        ok = OUT.exists() and OUT.read_text() == text
        print("CURTAIN_TRACKS", "FRESH" if ok else "STALE")
        sys.exit(0 if ok else 1)
    OUT.write_text(text)
    for tid in sorted(tracks):
        t = tracks[tid]
        print(f"{tid:12s} points={len(t['points']):2d} w={t['w']:.3f} h={t['h']:.3f} perimeter={t['length']:.3f}")
    print("WROTE", OUT.relative_to(ROOT))


if __name__ == "__main__":
    main()
