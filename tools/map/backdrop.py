"""Backdrop shells (visibility v1): big plain non-colliding parts that stand in for terrain the client stops drawing.

Roblox draws terrain only out to the client's render distance, which shrinks at lower graphics levels, on phones and
under Automatic quality when the frame-rate manager lowers detail. Past it the sky shows through (the DINO-4 great
hall's far walls at 600-1350 studs, owner report 2026-10-20). Large parts survive that cut far longer than voxels, so
the plan's `skyrally.backdrop` block lists a few generators and this module expands them into plain parts, written to
TrackData.backdrop by tools/map/adapt.py and built by src/server/kit/Backdrop.luau:

  shells  a wall ring and a ceiling `offset` studs outside a carved volume (the union of the listed Air shell ops):
          when the terrain wall is drawn it hides them, when it drops out they are drawn in its colour instead.
  floors  a plane a few studs under a solid terrain slab (DINO-4's lava sea), so a culled floor still reads as lava.
  rings   low ridge silhouettes (back-to-back wedges) outside the terrain heightfield, beyond the plane leash.
  peaks   far Rock range wedges re-drawn as crossed gable pairs with snow caps (SNOW-1's skyline, <= 200 studs each)
  cores   for big far terrain fills (SNOW-1's wedge ranges), the same wedge inset `inset` studs inside the fill.

Everything is purely visual (Anchored, CanCollide/CanQuery/CanTouch false, CastShadow false; kit/Backdrop) and is
checked here and again in Luau (src/shared/BackdropRules.luau, tools/tests/backdrop_spec.luau): every part stays at
least MARGIN studs outside every Air carve (CarveRouteTube taken at its largest radius), every route and alternate
corridor sample and every battle arena cylinder. Floors are the one exception to the Air rule: they sit inside the
solid slab they back (top at least FLOOR_SINK under its top), under every route sample by MARGIN. Owner rule: no
terrain op, adhesion, barrier, kill volume, rescue, course bound or corridor changes here.
"""
from __future__ import annotations

import math
from typing import Any

import numpy as np

MARGIN = 20.0           # task rule: every part at least this far outside any carve, corridor or arena
FLOOR_SINK = 4.0        # a floor part's top sits at least this far under the top of the slab it backs
MAX_AXIS = 2048.0       # Roblox part size limit per axis
MAX_PARTS = 150         # per map
LEASH_REACH = 440.0     # PlaneConfig.LEASH_RESPAWN 380 + 60: a ring part is never where a plane can be in play
ALT_RADIUS = 40.0       # alternates: kit carve halfWidth 20 (13 tunnel), ceiling 40 (28 tunnel)


# ---------------------------------------------------------------------------------------------------- geometry

def cf_to_rt(cf) -> tuple[np.ndarray, np.ndarray]:
    """[x,y,z, r00..r22] -> (position, 3x3 rotation whose columns are the right, up and back axes)."""
    return np.array(cf[:3], float), np.array(cf[3:12], float).reshape(3, 3)


def rt_to_cf(p, R) -> list[float]:
    return [round(float(v), 4) for v in list(p) + list(np.asarray(R).reshape(9))]


class Box:
    """An oriented box (a Block part, or a Wedge part's bounding box)."""

    def __init__(self, center, R, size):
        self.c = np.asarray(center, float)
        self.R = np.asarray(R, float)
        self.h = np.asarray(size, float) * 0.5

    @classmethod
    def from_cf(cls, cf, size) -> "Box":
        p, R = cf_to_rt(cf)
        return cls(p, R, size)

    def corners(self) -> np.ndarray:
        s = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)], float)
        return self.c + (s * self.h) @ self.R.T

    def point_distance(self, p) -> float:
        local = (np.asarray(p, float) - self.c) @ self.R
        d = np.maximum(np.abs(local) - self.h, 0.0)
        return float(np.linalg.norm(d))

    def points_distance(self, pts: np.ndarray) -> np.ndarray:
        local = (np.asarray(pts, float) - self.c) @ self.R
        d = np.maximum(np.abs(local) - self.h, 0.0)
        return np.linalg.norm(d, axis=1)


def box_gap(a: Box, b: Box) -> float:
    """A lower bound of the distance between two boxes: the largest separating gap over the 15 SAT axes (<= 0 when
    they overlap). Any projection gap is a lower bound, so gap >= m proves the boxes are at least m apart."""
    axes = [a.R[:, i] for i in range(3)] + [b.R[:, i] for i in range(3)]
    for i in range(3):
        for j in range(3):
            v = np.cross(a.R[:, i], b.R[:, j])
            n = np.linalg.norm(v)
            if n > 1e-6:
                axes.append(v / n)
    d = b.c - a.c
    best = -math.inf
    for ax in axes:
        ra = float(np.sum(np.abs(a.R.T @ ax) * a.h))
        rb = float(np.sum(np.abs(b.R.T @ ax) * b.h))
        best = max(best, abs(float(d @ ax)) - ra - rb)
    return best


def wedge_planes(cf, size) -> list[tuple[np.ndarray, float]]:
    """Outward half-spaces n.p <= d of a Roblox wedge (slope from the top back edge down to the bottom front edge,
    the same shape Terrain:FillWedge fills)."""
    p, R = cf_to_rt(cf)
    w, h, dd = (float(v) for v in size)
    x, y, z = R[:, 0], R[:, 1], R[:, 2]
    planes = [(x, w / 2), (-x, w / 2), (-y, h / 2), (z, dd / 2)]
    n = y / h - z / dd  # local y/h - z/d <= 0
    ln = float(np.linalg.norm(n))
    planes.append((n / ln, 0.0))
    return [(nn, float(off + nn @ p)) for nn, off in planes]


def wedge_vertices(cf, size) -> np.ndarray:
    p, R = cf_to_rt(cf)
    w, h, d = (float(v) * 0.5 for v in size)
    local = [(sx * w, -h, -d) for sx in (-1, 1)] + [(sx * w, -h, d) for sx in (-1, 1)] + [(sx * w, h, d) for sx in (-1, 1)]
    return p + np.array(local) @ R.T


def wedge_inset(cf, size, inset: float):
    """The wedge `inset` studs inside every face of the given wedge (same orientation and slope), or None when that
    leaves nothing."""
    p, R = cf_to_rt(cf)
    w, h, d = (float(v) for v in size)
    y0, z0 = -h / 2 + inset, d / 2 - inset
    c = inset * math.sqrt(1 / h ** 2 + 1 / d ** 2)
    h2 = h * (z0 / d - c) - y0
    d2 = z0 - d * (y0 / h + c)
    w2 = w - 2 * inset
    if min(w2, h2, d2) <= 1:
        return None
    centre = p + R @ np.array([0.0, y0 + h2 / 2, z0 - d2 / 2])
    return rt_to_cf(centre, R), [round(w2, 4), round(h2, 4), round(d2, 4)]


def convex_hull(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    pts = sorted(set(points))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower: list = []
    for q in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], q) <= 0:
            lower.pop()
        lower.append(q)
    upper: list = []
    for q in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], q) <= 0:
            upper.pop()
        upper.append(q)
    return lower[:-1] + upper[:-1]  # counter-clockwise in (x, z)


def simplify_hull(hull: list, min_edge: float) -> list:
    """Merges short hull edges (fewer, longer wall panels): the two ends of a short edge become the crossing of its
    neighbours' lines, so the polygon only grows and still contains the carve."""
    pts = list(hull)
    changed = True
    while changed and len(pts) > 4:
        changed = False
        for i in range(len(pts)):
            a, b = np.array(pts[i]), np.array(pts[(i + 1) % len(pts)])
            if np.linalg.norm(b - a) < min_edge:
                # keep the hull containing the dropped vertex: replace the pair by the intersection of the two
                # neighbouring edge lines
                prev, nxt = np.array(pts[i - 1]), np.array(pts[(i + 2) % len(pts)])
                x = line_intersection(prev, a, b, nxt)
                if x is None:
                    continue
                pts[i] = (float(x[0]), float(x[1]))
                pts.pop((i + 1) % len(pts))
                changed = True
                break
    return pts


def line_intersection(p1, p2, p3, p4):
    d1, d2 = p2 - p1, p4 - p3
    den = d1[0] * d2[1] - d1[1] * d2[0]
    if abs(den) < 1e-9:
        return None
    t = ((p3[0] - p1[0]) * d2[1] - (p3[1] - p1[1]) * d2[0]) / den
    return p1 + d1 * t


# ---------------------------------------------------------------------------------------------------- the map

def _mat_ok(op) -> bool:
    return op.get("mat") == "Air"


def air_volumes(ops: list[dict], waypoints) -> list[tuple]:
    """Every carved (Air) volume of the shell ops: ("ball", centre, r) or ("box", Box). CarveRouteTube is taken at
    radiusMax on every waypoint (the game varies the radius by noise inside [radiusMin, radiusMax]) plus its upper
    lobe at its highest lift, so the set covers the real tube."""
    out: list[tuple] = []
    for op in ops:
        kind = op.get("op")
        if kind == "FillBall" and _mat_ok(op):
            out.append(("ball", np.array(op["center"], float), float(op["r"])))
        elif kind == "FillBlock" and _mat_ok(op):
            out.append(("box", Box.from_cf(op["cf"], op["size"])))
        elif kind == "FillCylinder" and _mat_ok(op):
            r, hh = float(op["r"]), float(op["h"])
            out.append(("box", Box.from_cf(op["cf"], [2 * r, hh, 2 * r])))
        elif kind == "FillWedge" and _mat_ok(op):
            out.append(("box", Box.from_cf(op["cf"], op["size"])))
        elif kind == "CarveRouteTube":
            r_max = float(op.get("radiusMax", 112))
            lift = float(op.get("lift", 26))
            up_lift = float(op.get("upperLift", 70)) + 30
            up_r = r_max * float(op.get("upperScale", 0.8))
            lo, hi = float(op.get("fromStation", 0)), float(op.get("toStation", math.inf))
            for w in waypoints:
                if lo <= w["station"] <= hi:
                    p = np.array(w["pos"], float)
                    out.append(("ball", p + [0, lift, 0], r_max))
                    out.append(("ball", p + [0, up_lift, 0], up_r))
    return out


def route_samples(sk: dict, waypoints) -> tuple[np.ndarray, np.ndarray]:
    """(points, radius per point): every waypoint and its flight line, each with the corridor's largest extent, and
    every alternate line sampled every 10 studs."""
    fl = sk.get("flight") or {}
    cor = fl.get("corridor") or {}
    line = float(fl.get("lineOffset", 14))
    r_main = max(float(cor.get("halfWidth", 34)), float(cor.get("ceiling", 44)), float(cor.get("floor", 5)))
    pts, rad = [], []
    for w in waypoints:
        p = np.array(w["pos"], float)
        pts += [p, p + [0, line, 0]]
        rad += [r_main, r_main]
    for alt in (sk.get("gameplay") or {}).get("alternates") or []:
        ap = [np.array(q, float) for q in alt.get("points") or []]
        for a, b in zip(ap, ap[1:]):
            n = max(1, int(math.ceil(np.linalg.norm(b - a) / 10)))
            for k in range(n + 1):
                pts.append(a + (b - a) * (k / n))
                rad.append(ALT_RADIUS)
    return np.array(pts), np.array(rad)


def arenas(sk: dict) -> list[dict]:
    """Battle arena cylinders (BattleRules.arena): centre, the return radius (boundary + soft band) and the
    vertical extent."""
    out = []
    for m in ((sk.get("gameplay") or {}).get("modes") or {}).values():
        if not isinstance(m, dict) or m.get("center") is None:
            continue
        b = m.get("boundary") or {}
        c = np.array(b.get("center") or m["center"], float)
        bound_r = max(float(b.get("radius") or m.get("radius") or 0), float(m.get("radius") or 0))
        soft = float(b.get("softWidth", 30 if not b.get("radius") or bound_r <= float(m.get("radius") or 0) else 0))
        floor_y = float(b["floor"]) if b.get("floor") is not None else c[1] - 50
        if b.get("ceiling") is not None:
            ceil_y = float(b["ceiling"])
        elif b.get("height") is not None:
            ceil_y = c[1] + float(b["height"])
        else:
            ceil_y = c[1] + 300
        out.append({"center": c, "radius": bound_r + soft, "floor": floor_y, "ceiling": ceil_y})
    return out


def part_box(part: dict) -> Box:
    return Box.from_cf(part["cf"], part["size"])


def solid_mass(ops: list[dict], waypoints) -> Box | None:
    """The FillRouteBounds mass (MapAdapter.fillRouteBounds), when the map is a sealed cave: shell parts must stay
    inside it, where solid terrain hides them."""
    for op in ops:
        if op.get("op") == "FillRouteBounds" and waypoints:
            p = np.array([w["pos"] for w in waypoints], float)
            lo, hi = p.min(axis=0), p.max(axis=0)
            m = float(op.get("margin", 280))
            a = np.array([lo[0] - m, float(op.get("yMin", 0)), lo[2] - m])
            b = np.array([hi[0] + m, hi[1] + float(op.get("above", 230)), hi[2] + m])
            return Box((a + b) / 2, np.eye(3), b - a)
    return None


def heightfield_rect(plan: dict) -> tuple[float, float, float, float] | None:
    t = plan.get("terrain") or {}
    if not isinstance(t.get("heights"), list):
        return None
    x0, z0, cell = float(t["x0"]), float(t["z0"]), float(t.get("cell") or 4)
    return x0, z0, x0 + (t["nx"] - 1) * cell, z0 + (t["nz"] - 1) * cell


def violations(part: dict, air, samples, arena_list, ops: list[dict] | None = None, mass: Box | None = None,
               rect: tuple | None = None) -> list[str]:
    """Why a part breaks the backdrop rules (empty = fine). `floor` parts skip the Air rule (they sit inside a slab
    under the carved floor) and instead must sit FLOOR_SINK under their slab top and MARGIN under every route sample."""
    out = []
    box = part_box(part)
    kind = part.get("kind")
    size = part["size"]
    if max(size) > MAX_AXIS:
        out.append(f"size {size} over {MAX_AXIS}")
    if abs(float(box.R[1, 1]) - 1.0) > 1e-3:
        out.append("not upright (backdrop parts only turn about Y)")
    top = float(np.max(box.corners()[:, 1]))
    bottom = float(np.min(box.corners()[:, 1]))
    solid_top = None
    if kind == "floor":
        slab = (ops or [])[part["slab"]] if isinstance(part.get("slab"), int) and part["slab"] < len(ops or []) else None
        if not slab or slab.get("op") != "FillBlock" or slab.get("mat") == "Air":
            out.append(f"floor slab {part.get('slab')} is not a solid FillBlock")
        else:
            sb = Box.from_cf(slab["cf"], slab["size"])
            solid_top = float(sb.corners()[:, 1].max())
            if top > solid_top - FLOOR_SINK + 1e-6:
                out.append(f"floor top {top:.1f} not {FLOOR_SINK} under its slab top {solid_top:.1f}")
            if any(sb.point_distance([q[0], sb.c[1], q[2]]) > 1e-6 for q in box.corners()):
                out.append("floor reaches past its slab")
    else:
        for v in air:
            if v[0] == "ball":
                d = box.point_distance(v[1]) - v[2]
            else:
                d = box_gap(box, v[1])
            if d < MARGIN:
                out.append(f"{d:.1f} from an Air carve")
                break
    pts, rad = samples
    if kind == "floor":
        lowest = float(np.min(pts[:, 1]))
        if top > lowest - MARGIN + 1e-6:
            out.append(f"floor top {top:.1f} within {MARGIN} under the lowest route sample ({lowest:.1f})")
    else:
        d = box.points_distance(pts) - rad
        i = int(np.argmin(d))
        if d[i] < MARGIN:
            out.append(f"{d[i]:.1f} from the corridor at {pts[i].round(1).tolist()}")
    if kind == "ring":
        hd = box.points_distance(np.c_[pts[:, 0], np.full(len(pts), box.c[1]), pts[:, 2]])
        if float(np.min(hd)) < LEASH_REACH:
            out.append(f"ring {float(np.min(hd)):.0f} from the course, inside the leash reach {LEASH_REACH}")
        if rect and rect[0] < box.c[0] < rect[2] and rect[1] < box.c[2] < rect[3]:
            out.append("ring part inside the terrain heightfield")
    if kind == "core":
        src = (ops or [])[part["source"]] if isinstance(part.get("source"), int) and part["source"] < len(ops or []) else None
        if not src or src.get("op") != "FillWedge" or src.get("mat") == "Air":
            out.append("core source is not a solid FillWedge")
        else:
            planes = wedge_planes(src["cf"], src["size"])
            verts = wedge_vertices(part["cf"], part["size"])
            if any(float(n @ v) > d - MARGIN + 1e-3 for v in verts for n, d in planes):
                out.append(f"core vertex less than {MARGIN} inside its source wedge")
    if kind == "shell" and mass is not None:
        if any(mass.point_distance(q) > 1e-6 for q in box.corners()):
            out.append("shell part outside the sealed rock mass")
    for a in arena_list:
        floor_y = a["floor"]
        if solid_top is not None:
            floor_y = max(floor_y, solid_top)  # the slab is solid: nobody plays inside it
        if bottom >= a["ceiling"] + MARGIN or top <= floor_y - (0 if kind == "floor" else MARGIN):
            continue
        # horizontal distance from the arena axis to the (upright) part
        c = a["center"]
        hd = box.point_distance(np.array([c[0], box.c[1], c[2]]))
        if hd < a["radius"] + MARGIN:
            out.append(f"{hd - a['radius']:.1f} from a battle arena")
    return out


# ---------------------------------------------------------------------------------------------------- generators

def _part(name, kind, cf, size, style, shape="Block", **extra) -> dict:
    p = {"name": "Backdrop_" + name, "kind": kind, "shape": shape, "cf": rt_to_cf(*cf_to_rt(cf)),
         "size": [round(float(v), 4) for v in size], "material": style["mat"], "color": style["color"]}
    p.update(extra)
    return p


def _subdivide(name, kind, p, R, size, style, ok, min_tile, split_axes=(0, 1), **extra) -> list[dict]:
    """The tile if it passes `ok`, else its quarters (along split_axes) recursively down to min_tile; tiles that still
    fail are dropped."""
    part = _part(name, kind, rt_to_cf(p, R), size, style, **extra)
    if ok(part):
        return [part]
    a0, a1 = split_axes
    if size[a0] / 2 < min_tile and size[a1] / 2 < min_tile:
        return []
    out = []
    n0 = 2 if size[a0] / 2 >= min_tile else 1
    n1 = 2 if size[a1] / 2 >= min_tile else 1
    for i in range(n0):
        for j in range(n1):
            s = list(size)
            s[a0], s[a1] = size[a0] / n0, size[a1] / n1
            off = np.zeros(3)
            off[a0] = (i - (n0 - 1) / 2) * s[a0]
            off[a1] = (j - (n1 - 1) / 2) * s[a1]
            out += _subdivide(f"{name}_{i + 1}{j + 1}", kind, p + R @ off, R, s, style, ok, min_tile, split_axes, **extra)
    return out


def _grid(lo: float, hi: float, tile: float) -> list[tuple[float, float]]:
    n = max(1, int(math.ceil((hi - lo) / tile)))
    step = (hi - lo) / n
    return [(lo + step * (k + 0.5), step) for k in range(n)]


def footprint(vols) -> tuple[list, float, float]:
    """(x, z) points of the carved union's plan outline plus its lowest and highest Y."""
    pts, lo, hi = [], math.inf, -math.inf
    for v in vols:
        if v[0] == "ball":
            c, r = v[1], v[2]
            for k in range(32):
                a = 2 * math.pi * k / 32
                # 1/cos(pi/32) so the 32-gon contains the circle
                rr = r / math.cos(math.pi / 32)
                pts.append((float(c[0] + rr * math.cos(a)), float(c[2] + rr * math.sin(a))))
            lo, hi = min(lo, c[1] - r), max(hi, c[1] + r)
        else:
            cs = v[1].corners()
            pts += [(float(q[0]), float(q[2])) for q in cs]
            lo, hi = min(lo, float(cs[:, 1].min())), max(hi, float(cs[:, 1].max()))
    return pts, lo, hi


def carved(cfg: dict, sk: dict, ops: list[dict], waypoints) -> list[tuple]:
    """The volumes a shell or floor wraps: `ops` [first, last] (inclusive shell op indices) or "all" (every Air
    carve plus the alternate lines, so the shell also clears every tunnel that leaves the carved hall)."""
    sel = cfg.get("ops", "all")
    if sel == "all":
        vols = air_volumes(ops, waypoints)
        pts, rad = route_samples(sk, [])
        vols += [("ball", p, r) for p, r in zip(pts, rad)]
        return vols
    i0, i1 = sel
    return air_volumes(ops[i0:i1 + 1], waypoints)


def shell_parts(cfg: dict, sk: dict, ops: list[dict], waypoints, ok) -> tuple[list[dict], dict]:
    pts, lo, hi = footprint(carved(cfg, sk, ops, waypoints))
    off, thick = float(cfg.get("offset", 30)), float(cfg.get("thickness", 8))
    hull = simplify_hull(convex_hull(pts), float(cfg.get("minEdge", 120)))
    n = len(hull)
    # offset each (counter-clockwise) edge outward by `off` and intersect neighbours (mitre)
    lines = []
    for k in range(n):
        a, b = np.array(hull[k]), np.array(hull[(k + 1) % n])
        t = (b - a) / np.linalg.norm(b - a)
        out_n = np.array([t[1], -t[0]])  # right of a CCW edge in (x, z) is outward
        lines.append((a + out_n * off, b + out_n * off, out_n))
    ring = []
    for k in range(n):
        p1, p2, _ = lines[k - 1]
        p3, p4, _ = lines[k]
        ring.append(line_intersection(p1, p2, p3, p4))
    y0 = float(cfg.get("floorY", 0))
    y1 = hi + off + thick
    tile = float(cfg.get("tile", 512))
    min_tile = float(cfg.get("minTile", 40))
    wall, ceil = cfg["wall"], cfg.get("ceiling") or cfg["wall"]
    parts: list[dict] = []
    for k in range(n):
        a, b = ring[k], ring[(k + 1) % n]
        out_n = lines[k][2]
        L = float(np.linalg.norm(b - a))
        t2 = (b - a) / L
        # back (+Z) = outward, up = +Y, right = up x back
        back = np.array([out_n[0], 0.0, out_n[1]])
        up = np.array([0.0, 1.0, 0.0])
        right = np.cross(up, back)
        R = np.c_[right, up, back]
        sign = 1.0 if right @ np.array([t2[0], 0, t2[1]]) > 0 else -1.0
        mid = (a + b) / 2 + out_n * (thick / 2)
        span = L + 2 * thick  # overlap the mitred corners
        for gi, (u, du) in enumerate(_grid(-span / 2, span / 2, tile)):
            for gj, (y, dy) in enumerate(_grid(y0, y1, tile)):
                p = np.array([mid[0], y, mid[1]]) + right * (u * sign)
                parts += _subdivide(f"{cfg['name']}_Wall{k + 1:02d}_{gi + 1}{gj + 1}", "shell", p, R, [du, dy, thick],
                                    wall, ok, min_tile)
    xs, zs = [q[0] for q in ring], [q[1] for q in ring]
    ytop = hi + off
    R = np.eye(3)
    for gi, (x, dx) in enumerate(_grid(min(xs) - thick, max(xs) + thick, tile * 1.5)):
        for gj, (z, dz) in enumerate(_grid(min(zs) - thick, max(zs) + thick, tile * 1.5)):
            p = np.array([x, ytop + thick / 2, z])
            parts += _subdivide(f"{cfg['name']}_Ceiling_{gi + 1}{gj + 1}", "shell", p, R, [dx, thick, dz], ceil, ok,
                                min_tile, (0, 2))
    info = {"hull": [(round(float(q[0]), 1), round(float(q[1]), 1)) for q in ring], "carvedY": (lo, hi), "top": y1}
    return parts, info


def floor_parts(cfg: dict, sk: dict, ops: list[dict], waypoints, ok) -> list[dict]:
    """A plane `sink` studs under the top of the solid slab op `slab` (0-based shell op index), over the plan
    rectangle of the carved volumes (plus `pad`)."""
    slab_i = int(cfg["slab"])
    sb = Box.from_cf(ops[slab_i]["cf"], ops[slab_i]["size"])
    solid_top = float(sb.corners()[:, 1].max())
    top = solid_top - float(cfg.get("sink", 6))
    thick = float(cfg.get("thickness", 4))
    pts, _, _ = footprint(carved(cfg, sk, ops, waypoints))
    pad = float(cfg.get("pad", 40))
    xs, zs = [q[0] for q in pts], [q[1] for q in pts]
    tile = float(cfg.get("tile", 640))
    parts = []
    for gi, (x, dx) in enumerate(_grid(min(xs) - pad, max(xs) + pad, tile)):
        for gj, (z, dz) in enumerate(_grid(min(zs) - pad, max(zs) + pad, tile)):
            p = np.array([x, top - thick / 2, z])
            parts += _subdivide(f"{cfg['name']}_{gi + 1}{gj + 1}", "floor", p, np.eye(3), [dx, thick, dz], cfg, ok,
                                float(cfg.get("minTile", 80)), (0, 2), slab=slab_i)
    return parts


def ring_parts(cfg: dict, plan: dict, ok, crests: list | None = None) -> list[dict]:
    """Ridge rows around the terrain heightfield: back-to-back wedges (slopes facing in and out) along a rounded
    rectangle `gap` studs outside the heightfield edge. Heights come from a fixed hash, so the output is stable."""
    t = plan["terrain"]
    x0, z0 = float(t["x0"]), float(t["z0"])
    x1, z1 = x0 + (t["nx"] - 1) * float(t["cell"]), z0 + (t["nz"] - 1) * float(t["cell"])
    base = float(cfg["baseY"])
    parts: list[dict] = []
    for ri, row in enumerate(cfg["rows"]):
        gap, depth = float(row["gap"]), float(row["depth"])
        seg = float(row["length"])
        r = gap + depth  # the spine runs on the rounded rectangle at this distance from the edge
        sides = [((x0, z0), (x1, z0), (0, -1)), ((x1, z0), (x1, z1), (1, 0)),
                 ((x1, z1), (x0, z1), (0, 1)), ((x0, z1), (x0, z0), (-1, 0))]
        k = 0
        for (a, b, nrm) in sides:
            a, b, nrm = np.array(a), np.array(b), np.array(nrm, float)
            L = float(np.linalg.norm(b - a))
            # extend each side by the spine distance so neighbouring sides cross at the corners
            count = max(1, int(math.ceil((L + 2 * r) / seg)))
            step = (L + 2 * r) / count
            tdir = (b - a) / L
            for j in range(count):
                k += 1
                h = row["heights"][(k * 7 + ri * 3) % len(row["heights"])]
                along = -r + step * (j + 0.5)
                spine = a + tdir * along + nrm * r
                length = step * 1.12
                back = np.array([nrm[0], 0.0, nrm[1]])
                up = np.array([0.0, 1.0, 0.0])
                for side, sgn in (("In", 1.0), ("Out", -1.0)):
                    bz = back * sgn  # inner wedge: back toward the outside, slope faces the course
                    R = np.c_[np.cross(up, bz), up, bz]
                    centre = np.array([spine[0], base + h / 2, spine[1]]) - bz * (depth / 2)
                    part = _part(f"{cfg['name']}_R{ri + 1}_{k:02d}{side}", "ring", rt_to_cf(centre, R),
                                 [length, h, depth], row, shape="Wedge")
                    if ok(part):
                        parts.append(part)
                        if crests is not None and side == "In":
                            # the ridge line of this back-to-back pair: where the author stands its windmills
                            crests.append({"row": ri, "k": k, "x": float(spine[0]), "z": float(spine[1]),
                                           "y": base + h, "along": [float(tdir[0]), float(tdir[1])]})
    return parts


def core_parts(cfg: dict, ops: list[dict], waypoints, sk: dict, ok) -> list[dict]:
    pts, _ = route_samples(sk, waypoints)
    styles = cfg["styles"]
    inset = float(cfg.get("inset", 24))
    min_d = float(cfg.get("minRouteDistance", 800))
    min_h = float(cfg.get("minHeight", 120))
    parts = []
    for i, op in enumerate(ops):
        if op.get("op") != "FillWedge" or op.get("mat") not in styles:
            continue
        if float(op["size"][1]) < min_h:
            continue
        box = Box.from_cf(op["cf"], op["size"])
        if float(np.min(box.points_distance(pts))) < min_d:
            continue
        # a style may set its own inset: SNOW-1's Snow cap wedges share the slope, sides and back face of the Rock
        # wedge under them, so equal insets made the two cores coplanar (Rock/Snow z-fighting on every far peak
        # once the terrain is culled); a deeper Rock inset keeps the snow core proud of the rock core
        ins = float(styles[op["mat"]].get("inset", inset))
        res = wedge_inset(op["cf"], op["size"], ins)
        if res is None:
            continue
        cf, size = res
        part = _part(f"{cfg['name']}_{i:03d}", "core", cf, size, styles[op["mat"]], shape="Wedge",
                     source=i, inset=ins)
        if ok(part):
            parts.append(part)
    return parts


def _gable(name, centre_xz, base_y, yaw_deg, length, height, depth, style, cap_style, frac) -> list[dict]:
    """One back-to-back wedge pair (a gable ridge along `yaw_deg`) with a snow cap pair on its upper `frac`. The cap
    stands 1.2 studs proud of the rock slope (same slope, raised), so the two never z-fight."""
    a = math.radians(yaw_deg)
    parts: list[dict] = []
    up = np.array([0.0, 1.0, 0.0])
    for side, sgn in (("A", 1.0), ("B", -1.0)):
        back = sgn * np.array([math.cos(a), 0.0, math.sin(a)])
        R = np.c_[np.cross(up, back), up, back]
        axis = np.array([centre_xz[0], base_y, centre_xz[1]])
        centre = axis - back * (depth / 2) + up * (height / 2)
        parts.append(_part(f"{name}_{side}", "peak", rt_to_cf(centre, R), [length, height, depth], style, shape="Wedge"))
        hc = frac * height + 1.2
        dc = hc * depth / height
        cc = axis + up * (height + 1.2 - hc / 2) - back * (dc / 2)
        parts.append(_part(f"{name}_{side}Cap", "peak", rt_to_cf(cc, R), [length + 2.0, hc, dc], cap_style, shape="Wedge"))
    return parts


def peak_parts(cfg: dict, ops: list[dict], waypoints, sk: dict, ok) -> list[dict]:
    """SNOW-1 far skyline as faceted peaks (critic v28 1.10): along the crest of every far Rock range wedge, crossed
    gable pairs (each at most `maxSpan` studs across) in cool rock with a snow cap, rising `lift` studs over the crest.
    Far backdrop only: the generic corridor, carve and arena rules apply; a peak with any part failing them is dropped."""
    import random
    pts, _ = route_samples(sk, waypoints)
    rock, cap = cfg["rock"], cfg["cap"]
    min_d = float(cfg.get("minRouteDistance", 600))
    min_h = float(cfg.get("minHeight", 140))
    span = float(cfg.get("maxSpan", 200))
    rng = random.Random(int(cfg.get("seed", 7)))
    crests: list[np.ndarray] = []
    cand: list[tuple] = []
    for i, op in enumerate(ops):
        if op.get("op") != "FillWedge" or op.get("mat") != "Rock" or float(op["size"][1]) < min_h:
            continue
        box = Box.from_cf(op["cf"], op["size"])
        if float(np.min(box.points_distance(pts))) < min_d:
            continue
        p, R = cf_to_rt(op["cf"])
        w, h, d = (float(v) for v in op["size"])
        crest = p + R @ np.array([0.0, h / 2, d / 2])
        if any(float(np.linalg.norm(crest[[0, 2]] - c[[0, 2]])) < 60 for c in crests):
            continue  # the back-to-back partner of a ridge already done
        crests.append(crest)
        yaw = math.degrees(math.atan2(R[0, 0], -R[2, 0]))  # _gable's back-angle for a ridge along local +X
        cand.append((float(crest[1]), i, crest, yaw))
    # one peak per ridge (the part budget is MAX_PARTS): the highest crests carry the skyline
    cand.sort(key=lambda c: (-c[0], c[1]))
    out: list[dict] = []
    k = 0
    for _top, _i, crest, yaw in cand[: int(cfg.get("maxPeaks", 17)) * 2]:
        if k >= int(cfg.get("maxPeaks", 17)):
            break
        base_y = float(crest[1]) - 40.0
        ph = float(cfg.get("lift", 110)) * (0.8 + 0.5 * rng.random()) + 40.0
        slope = 1.15 + 0.35 * rng.random()
        dep = min(span / 2, ph / slope)
        style = {"mat": rock["mat"], "color": rock["colors"][k % len(rock["colors"])]}
        capst = {"mat": cap["mat"], "color": cap["color"]}
        nm = f"{cfg['name']}_{k + 1:02d}"
        gs = _gable(nm + "a", crest[[0, 2]], base_y, yaw + rng.uniform(-12, 12), span, ph, dep, style, capst, 0.55)
        gs += _gable(nm + "b", crest[[0, 2]] + rng.uniform(-18, 18), base_y, yaw + rng.uniform(55, 80),
                     span * 0.8, ph * rng.uniform(0.78, 0.92), dep * 0.8, style, capst, 0.5)
        if cfg.get("tripleGable") and k == 0:  # only the hero peak (MAX_PARTS 150)
            # v29 D5: a third, taller and narrower hero-peak gable crossing the pair at a skew angle breaks the straight ridge line
            gs += _gable(nm + "c", crest[[0, 2]] + np.array([rng.uniform(-30, 30), rng.uniform(-30, 30)]), base_y,
                         yaw + rng.choice((-1, 1)) * rng.uniform(25, 45), span * 0.55, ph * rng.uniform(1.0, 1.18),
                         dep * 0.6, style, capst, 0.62)
        if all(ok(g) for g in gs):
            out += gs
            k += 1
    return out


def build(plan: dict, waypoints: list[dict]) -> list[dict]:
    """TrackData.backdrop for a plan: [] without a `backdrop` block. `waypoints` are dicts with pos (x,y,z) and
    station."""
    sk = plan["skyrally"]
    cfg = sk.get("backdrop")
    if not cfg:
        return []
    ops = (sk.get("shells") or {}).get("ops") or []
    air = air_volumes(ops, waypoints)
    samples = route_samples(sk, waypoints)
    ar = arenas(sk)
    mass = solid_mass(ops, waypoints)
    rect = heightfield_rect(plan)

    def ok(part):
        return not violations(part, air, samples, ar, ops, mass, rect)

    parts: list[dict] = []
    info: dict = {}
    for s in cfg.get("shells") or []:
        ps, inf = shell_parts(s, sk, ops, waypoints, ok)
        parts += ps
        info[s["name"]] = inf
    for f in cfg.get("floors") or []:
        parts += floor_parts(f, sk, ops, waypoints, ok)
    for r in cfg.get("rings") or []:
        parts += ring_parts(r, plan, ok)
    for c in cfg.get("cores") or []:
        parts += core_parts(c, ops, waypoints, sk, ok)
    for c in cfg.get("peaks") or []:
        parts += peak_parts(c, ops, waypoints, sk, ok)
    return parts


def audit(plan: dict, waypoints: list[dict], parts: list[dict]) -> list[str]:
    """Every rule broken by a part list (used by adapt's gate and the map tests)."""
    sk = plan["skyrally"]
    ops = (sk.get("shells") or {}).get("ops") or []
    air = air_volumes(ops, waypoints)
    samples = route_samples(sk, waypoints)
    ar = arenas(sk)
    out = []
    if len(parts) > MAX_PARTS:
        out.append(f"{len(parts)} backdrop parts, over {MAX_PARTS}")
    names = [p["name"] for p in parts]
    if len(set(names)) != len(names):
        out.append("duplicate backdrop part names")
    mass = solid_mass(ops, waypoints)
    rect = heightfield_rect(plan)
    for p in parts:
        for v in violations(p, air, samples, ar, ops, mass, rect):
            out.append(f"{p['name']}: {v}")
    return out
