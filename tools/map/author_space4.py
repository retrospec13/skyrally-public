#!/usr/bin/env python3
"""TRACK_PIPELINE P1 author script for SPACE-4 "Monorail Neon Grid" (Star City homage, car): design data in this file ->
map/space4/plan.json (docs/MAP_PLAN_SCHEMA.md). Deterministic (fixed seeds, no clock). Change the map here and rerun,
then `python3 tools/map/adapt.py map/space4/plan.json`; never edit the plan or build/space4/* by hand.

Guide: docs/guides/space4.md (hero view = the start straight: two ivory/brass boost
gates, a stone-and-steel arch viaduct carrying a painted monorail train across the highway, the bright glass-vaulted
tunnel framed by the central arch, sodium and cyan streetlamps, faceted towers in warm haze).

Lap (clockwise from above, ~4800 studs), every section derived from the solved spline:
  start straight, elevated y=64, heading north: boost-gate pair -> monorail viaduct crossing -> Glass Vault tunnel
  -> NW sweeper -> downtown city turns (right/left 90s between towers, gentle descent to y=56) -> NE sweeper
  -> east descent under the viaduct's second crossing to grade (y=14) -> SE sweeper onto the moon-rock plain
  -> crater bulge around the mesa (Alt1 = straight shortcut tunnel through the mesa) -> rift jump (kicker lip, deck gap
  over a moonquake rift; too slow = fall in and the off-track respawn) -> SW climbing sweeper back up to the start.
Construction (ART_BAR construction rules): the road is the kit deck (bridge, piers every 6th segment) with cream stone
parapet walls on both sides (the car's wall/bump responses), brass seams and curved neon lane lines; organic masses
are Terrain: a 30MAPS height grid (moon-rock plain, city plazas, craters, the rift, embankments that meet the road edge
wherever the road is at grade) plus shells ops (the terraced mesa, boulders, the shortcut tube). Landmarks are 30MAPS
block-built prefabs named after what they are (MonorailViaductPier/Span, MonorailTrain, GlassVaultRib, StarSpireTower,
CityTower_*, Streetlamp_*, NeonSignGantry, MesaTunnelPortal, MonorailStation). Only parapets, the Alt1 funnel rails
(ShortcutFunnelRail) and portal piers collide.
"""
from __future__ import annotations

import hashlib
import json
import math
import random
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
for _p in (ROOT / "tools" / "map", ROOT / "tools" / "course"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import adapt  # noqa: E402
import route as routelib  # noqa: E402
import route_geometry  # noqa: E402
import item_rows  # noqa: E402  (item cubes v2 layout rules, tools/map/item_cubes.json)

OUT = ROOT / "map" / "space4" / "plan.json"
SEED = 4404  # every random choice below comes from random.Random(SEED + k)

# ------------------------------------------------------------------------------------------------ world frame
# Its own quadrant: clear of DINO-4 (x -1500..300, z -2100..500), TEST-STRIP (x ~3500..4100), and the other launch
# maps' grids (all at negative x), so every launch map can be built in one place without wiping another's Terrain.
ORIGIN = (7000.0, 0.0, 7000.0)
TARGET_LENGTH = 4800
MIN_RADIUS = 85.0
MAX_GRADE_DEG = 15.0
MAX_BANK_DEG = 12.0

# Deck / car geometry (kit/Deck: TrackSeg centre -2.2 height 7.6 -> top +1.6; pavers to +2.7; fascia to -6.3)
DECK_WIDTH = 44
DECK_TOP = 1.6
PAVER_TOP = 2.7
CURB_HEIGHTS = [4.4, 3.8]  # curb tops +3.0 / +2.7: lips under the car's wall rays (2.2 above the road)
WALL_LATERAL = 26.2  # parapet centre: curbs end at 22 + 1.4 + 1.8 = 25.2
WALL_THICK = 2.0
WALL_BOTTOM = -6.3  # parapet doubles as the bridge's edge beam (fascia bottom)
WALL_TOP = 6.4
CAP_TOP = 7.2
WALL_MAX_PIECE = 24.0  # longer pieces are split below wherever their world AABB would reach the corridor
WALL_SAG = 0.25
CORRIDOR = {"halfWidth": 19, "floor": 1, "ceiling": 26}
LINE_OFFSET = 4.5  # hull centre above the ribbon (paver top 2.7 + ride height 1.9)
CAR_GRAVITY = 140.0  # src/shared/CarConfig.luau GRAVITY
SHELF_ABOVE_RIBBON = 1.2  # at-grade terrain meets the road edge just under the deck top (+1.6)

# Plain and landmarks (local heights == world heights, ORIGIN y = 0)
PLAIN_Y = 4.0
PLAZA_Y = 5.0
RIFT_FLOOR = -22.0
VIADUCT_STATION = 150.0  # where the monorail viaduct crosses the start straight (guide hero view)
TUNNEL_FROM, TUNNEL_TO, RIB_STEP = 176.0, 476.0, 15.0
ALT_MIN_OFFSET = 66.0  # Alt1 points closer than this to the race line are dropped (tunnel mouths stand beside the course)
# Alt1 aprons (trap audit S4-01/S4-03/S4-04, docs/audits/traps_space4.md): the fork parapet opens only where its line runs
# inside the apron (chord lateral > -FORK_OPEN_BAND, the tube wall's outer face), and collidable funnel rails close each
# apron from the parapet ends to the tube walls (kit/Deck tunnel: walls 6 thick at +-16, inner faces +-13, each wall
# 1 stud longer than the point run at both ends), so every off-centre arrival slides into the tube along a rail at < 7
# degrees (a "Deflect", CarConfig.WALL_SHALLOW_DOT 0.42) instead of meeting the flat rock face at boost speed
FORK_OPEN_BAND = 19.0
TUBE_INNER = 13.0
FUNNEL_EMBED = 2.0  # rail ends reach this far into the kit tube walls
FUNNEL_MAX_PIECE = 24.0
# a parapet's leading end that faces traffic after a deck gap gets a nose bent outward by this angle over this length
NOSE_FLARE_DEG = 15.0
NOSE_FLARE_LEN = 12.0

# --------------------------------------------------------------------------------------------- design path
# Turtle segments in local x (east) / z (south); start heading north (-z). ("S", length) / ("R"|"L", radius, degrees).
# base length = 2 * (L_CITY2 + L_EAST) + 3515 at flex 0 (the closure straights absorb the rest); flex adds ~24/unit
L_START, L_NORTH1, L_CITY2, L_NORTH2, L_EAST, L_SOUTH1 = 650.0, 200.0, 100.0, 614.0, 530.0, 100.0
BULGE_R = 160.0
SEGMENTS = [
    ("start", "S", L_START),
    ("nw", "R", 170.0, 90.0),
    ("north1", "S", L_NORTH1),
    ("city1", "R", 110.0, 90.0),
    ("city2", "S", L_CITY2),
    ("city3", "L", 110.0, 90.0),
    ("north2", "S", L_NORTH2),
    ("ne", "R", 150.0, 90.0),
    ("east", "S", L_EAST),
    ("se", "R", 160.0, 90.0),
    ("south1", "S", L_SOUTH1),
    ("bulge1", "L", BULGE_R, 60.0),
    ("bulge2", "R", BULGE_R, 120.0),
    ("bulge3", "L", BULGE_R, 60.0),
    ("jump", "S", None),  # closes x
    ("sw", "R", 160.0, 90.0),
    ("climb", "S", None),  # closes z
]
START_LOCAL = (0.0, 300.0)
FLEXED = ("ne", "east", "se")  # translated east by flex * scale: the north2 and south1 straights stretch
FLEX_X = 12.0
# bulge1/bulge3 stay flat: they carry the parapet-free fork stretches on their right (high-bank) side, where a car on
# the Alt1 cutting floor (ribbon + 1.4) must climb the curb back onto the road; a 5-degree bank lifted that curb top to
# ~3.9 above the floor, over the car's wall rays (2.2 above its ground), so the curb read as a wall (review fix)
BANK = {"nw": -6.0, "city1": -8.0, "city3": 8.0, "ne": -6.0, "se": -6.0, "bulge1": 0.0, "bulge2": -6.0,
        "bulge3": 0.0, "sw": -6.0}
LIP_FROM_JUMP_START = 205.0  # kicker crest along the jump straight
# kicker: ~7 deg ramp to a 9-stud lip, then a height step down inside the deck gap to a flat landing
KICK = [(-96, 0.0), (-60, 2.0), (-30, 6.0), (-10, 8.4), (0, 9.0), (8, 7.6), (16, 3.2), (24, 1.2), (36, 0.4), (70, 0.0)]


def r4(x: float) -> float:
    v = round(float(x), 4)
    return 0.0 if v == 0 else v


def r2(x: float) -> float:
    v = round(float(x), 2)
    return 0.0 if v == 0 else v


def smooth(t: float) -> float:
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def turtle(segments: list[tuple]) -> tuple[list[dict], dict[str, tuple[float, float]]]:
    """Walk the segments; returns per-segment records {label, kind, d0, d1, p0, p1, h0, h1, centre, radius, sgn, deg}
    and the closure lengths. Right turns are clockwise seen from above (x east, z south)."""
    x, z = START_LOCAL
    hx, hz = 0.0, -1.0
    d = 0.0
    recs = []
    for seg in segments:
        label, kind = seg[0], seg[1]
        rec = {"label": label, "kind": kind, "d0": d, "p0": (x, z), "h0": (hx, hz)}
        if kind == "S":
            length = seg[2]
            x, z = x + hx * length, z + hz * length
            d += length
            rec.update(length=length)
        else:
            radius, deg = seg[2], seg[3]
            sgn = 1.0 if kind == "R" else -1.0
            rx, rz = -hz * sgn, hx * sgn  # right of heading = (-hz, hx)
            cx, cz = x + rx * radius, z + rz * radius
            a0 = math.atan2(x - cx, z - cz)
            a1 = a0 - sgn * math.radians(deg)
            x, z = cx + radius * math.sin(a1), cz + radius * math.cos(a1)
            hx, hz = -sgn * math.cos(a1), sgn * math.sin(a1)
            d += radius * math.radians(deg)
            rec.update(centre=(cx, cz), radius=radius, sgn=sgn, a0=a0, a1=a1, length=radius * math.radians(deg))
        rec.update(d1=d, p1=(x, z), h1=(hx, hz))
        recs.append(rec)
    return recs, {"end": (x, z), "heading": (hx, hz), "length": d}


def design() -> list[dict]:
    """Segments with the two closure straights solved: 'jump' closes x (ends 160 east of the start line before the
    SW quarter turn) and 'climb' closes z (ends on the start point)."""
    segs = [list(s) for s in SEGMENTS]
    # first pass with zero-length closures to find where the bulge ends
    probe = [s if s[2] is not None else (s[0], "S", 0.0) for s in segs]
    recs, _ = turtle([tuple(s) for s in probe])
    bulge_end = next(r for r in recs if r["label"] == "bulge3")["p1"]
    sw_r = next(s for s in SEGMENTS if s[0] == "sw")[2]
    l_jump = bulge_end[0] - sw_r - START_LOCAL[0]
    l_climb = (bulge_end[1] - sw_r) - START_LOCAL[1]
    for s in segs:
        if s[0] == "jump":
            s[2] = l_jump
        elif s[0] == "climb":
            s[2] = l_climb
    recs, info = turtle([tuple(s) for s in segs])
    assert abs(info["end"][0] - START_LOCAL[0]) < 1e-6 and abs(info["end"][1] - START_LOCAL[1]) < 1e-6, info
    assert l_jump > 340 and l_climb > 150, (l_jump, l_climb)
    return recs


def seg_point(rec: dict, t: float) -> tuple[float, float]:
    """Design point at fraction t of a segment."""
    if rec["kind"] == "S":
        (x0, z0), (hx, hz) = rec["p0"], rec["h0"]
        return x0 + hx * rec["length"] * t, z0 + hz * rec["length"] * t
    cx, cz = rec["centre"]
    a = rec["a0"] + (rec["a1"] - rec["a0"]) * t
    return cx + rec["radius"] * math.sin(a), cz + rec["radius"] * math.cos(a)


def elevation(recs: list[dict], d: float) -> float:
    """Ribbon height (world y) at design distance d: smoothstep between keyed heights per section."""
    by = {r["label"]: r for r in recs}
    total = recs[-1]["d1"]
    keys = [
        (0.0, 64.0),
        (by["nw"]["d1"], 64.0),
        (by["north2"]["d1"], 56.0),
        (by["ne"]["d1"], 56.0),
        (by["east"]["d1"], 14.0),
        (by["sw"]["d0"], 14.0),
        (total, 64.0),
    ]
    y = keys[-1][1]
    for (da, ya), (db, yb) in zip(keys, keys[1:]):
        if da <= d <= db:
            y = ya + (yb - ya) * smooth((d - da) / max(1e-9, db - da))
            break
    return y


def build_nodes(recs: list[dict]) -> tuple[list[dict], dict]:
    """Route nodes sampled along the design path (straights ~115 apart, arcs ~58), the jump kicker as close nodes."""
    by = {r["label"]: r for r in recs}
    lip_d = by["jump"]["d0"] + LIP_FROM_JUMP_START
    nodes = []
    meta = {"lipDesignD": lip_d}

    def add(rec: dict, t: float, extra_h: float = 0.0, bank: float | None = None):
        x, z = seg_point(rec, t)
        d = rec["d0"] + rec["length"] * t
        y = elevation(recs, d) + extra_h
        if bank is None:
            bank = BANK.get(rec["label"], 0.0)
            if rec["kind"] != "S" and (t <= 0.0 or t >= 1.0):
                bank *= 0.5
        n = {"pos": [r4(ORIGIN[0] + x), r4(ORIGIN[1] + y), r4(ORIGIN[2] + z)], "bank": r4(bank),
             "_d": d, "_label": rec["label"]}
        if rec["label"] in FLEXED:
            n["flex"] = [FLEX_X, 0.0, 0.0]
        nodes.append(n)

    for rec in recs:
        if rec["label"] == "jump":
            length = rec["length"]
            offs = sorted({0.0} | {LIP_FROM_JUMP_START + k for k, _ in KICK} | {LIP_FROM_JUMP_START - 160.0})
            offs = [o for o in offs if 0.0 <= o < length - 40]
            tail = LIP_FROM_JUMP_START + KICK[-1][0]
            n_tail = max(1, math.ceil((length - tail) / 130))
            offs += [tail + (length - tail) * k / n_tail for k in range(1, n_tail)]
            kick = dict(KICK)
            for o in sorted(set(offs)):
                h = kick.get(round(o - LIP_FROM_JUMP_START), 0.0)
                add(rec, o / length, h, 0.0)
            continue
        if rec["kind"] == "S":
            n = max(1, math.ceil(rec["length"] / 130.0))
        else:
            n = max(2, math.ceil(rec["length"] / 72.0))
        for k in range(n):
            add(rec, k / n)
    return nodes, meta


def route_block(nodes: list[dict]) -> dict:
    clean = []
    for n in nodes:
        c = {"pos": n["pos"], "bank": n["bank"]}
        if "flex" in n:
            c["flex"] = n["flex"]
        clean.append(c)
    return {"nodes": clean, "closed": True, "samplesPerSegment": 6, "targetLength": TARGET_LENGTH,
            "flexScaleMin": 0.0, "flexScaleMax": 3.5, "bisectIterations": 24, "minRadius": MIN_RADIUS,
            "radiusExceptions": []}


# ------------------------------------------------------------------------------------------- frame helpers
def banked_axes(f: routelib.Frame) -> tuple[tuple, tuple]:
    """Right and up of the deck at a station: the route frame rolled by the bank, as kit/Deck rolls each segment."""
    b = math.radians(f.bank)
    right = routelib.add(routelib.mul(f.right, math.cos(b)), routelib.mul(f.up, math.sin(b)))
    up = routelib.sub(routelib.mul(f.up, math.cos(b)), routelib.mul(f.right, math.sin(b)))
    return right, up


def yxz_from_axes(right: tuple, up: tuple, look: tuple) -> list[float]:
    """YXZ Euler degrees (30MAPS / CFrame.fromEulerAnglesYXZ) of the rotation with these Right/Up/Look vectors."""
    back = routelib.mul(look, -1.0)
    m = [[right[0], up[0], back[0]], [right[1], up[1], back[1]], [right[2], up[2], back[2]]]
    sx = max(-1.0, min(1.0, -m[1][2]))
    rx = math.asin(sx)
    if abs(math.cos(rx)) > 1e-6:
        ry = math.atan2(m[0][2], m[2][2])
        rz = math.atan2(m[1][0], m[1][1])
    else:
        ry, rz = math.atan2(-m[2][0], m[0][0]), 0.0
    return [r4(math.degrees(rx)), r4(math.degrees(ry)), r4(math.degrees(rz))]


def yaw_of(v: tuple) -> float:
    """Yaw (degrees, 30MAPS instance r) whose LookVector is the horizontal direction of v."""
    return r4(math.degrees(math.atan2(-v[0], -v[2])))


def offset_point(route: routelib.Route, st: float, lateral: float, height: float) -> tuple:
    f = route.frame_at(st)
    right, up = banked_axes(f)
    return routelib.add(routelib.add(f.pos, routelib.mul(right, lateral)), routelib.mul(up, height))


def in_ranges(st: float, ranges: list[tuple[float, float]]) -> bool:
    return any(a <= st <= b for a, b in ranges)


def wrap(st: float, length: float) -> float:
    return st - math.floor(st / length) * length


class Poly:
    """Horizontal nearest-point queries against a route polyline (vectorized)."""

    def __init__(self, pts: list[tuple], stations: list[float]):
        p = np.array(pts, float)
        self.a = p[:-1]
        self.b = p[1:]
        self.st = np.array(stations, float)
        self.ab = self.b - self.a
        self.ab2 = np.maximum(1e-9, self.ab[:, 0] ** 2 + self.ab[:, 2] ** 2)

    def nearest(self, x: float, z: float) -> tuple[float, float, float]:
        """(horizontal distance, station, ribbon y) of the nearest polyline point."""
        t = ((x - self.a[:, 0]) * self.ab[:, 0] + (z - self.a[:, 2]) * self.ab[:, 2]) / self.ab2
        t = np.clip(t, 0, 1)
        qx = self.a[:, 0] + self.ab[:, 0] * t
        qz = self.a[:, 2] + self.ab[:, 2] * t
        d2 = (x - qx) ** 2 + (z - qz) ** 2
        k = int(np.argmin(d2))
        y = self.a[k, 1] + self.ab[k, 1] * t[k]
        return math.sqrt(float(d2[k])), float(self.st[k] + (self.st[k + 1] - self.st[k]) * t[k]), float(y)

    def nearest_many(self, xs: np.ndarray, zs: np.ndarray, chunk: int = 1500) -> tuple[np.ndarray, np.ndarray]:
        """Distances and ribbon heights for many query points."""
        dist, ys, _, _ = self.nearest_frames_many(xs, zs, None, chunk)
        return dist, ys

    def nearest_frames_many(self, xs: np.ndarray, zs: np.ndarray, banks: np.ndarray | None,
                            chunk: int = 1500) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        """Distances, ribbon heights, signed lateral along the route's horizontal right (tangent x up, as
        routelib.frame_at) and the lerped bank (degrees; zeros without `banks`) of the nearest polyline point."""
        dist = np.empty(xs.shape[0])
        ys = np.empty(xs.shape[0])
        lat = np.empty(xs.shape[0])
        bk = np.zeros(xs.shape[0])
        for i in range(0, xs.shape[0], chunk):
            x = xs[i:i + chunk, None]
            z = zs[i:i + chunk, None]
            t = ((x - self.a[None, :, 0]) * self.ab[None, :, 0] + (z - self.a[None, :, 2]) * self.ab[None, :, 2]) / self.ab2[None, :]
            t = np.clip(t, 0, 1)
            qx = self.a[None, :, 0] + self.ab[None, :, 0] * t
            qz = self.a[None, :, 2] + self.ab[None, :, 2] * t
            d2 = (x - qx) ** 2 + (z - qz) ** 2
            k = np.argmin(d2, axis=1)
            rows = np.arange(k.shape[0])
            dist[i:i + chunk] = np.sqrt(d2[rows, k])
            ys[i:i + chunk] = self.a[k, 1] + self.ab[k, 1] * t[rows, k]
            tk = t[rows, k]
            hx, hz = self.ab[k, 0], self.ab[k, 2]
            hl = np.sqrt(self.ab2[k])
            # right = tangent x up = (-tz, 0, tx)
            lat[i:i + chunk] = ((x[:, 0] - qx[rows, k]) * (-hz) + (z[:, 0] - qz[rows, k]) * hx) / hl
            if banks is not None:
                bk[i:i + chunk] = banks[k] + (banks[k + 1] - banks[k]) * tk
        return dist, ys, lat, bk


def project(route: routelib.Route, poly: Poly, p: tuple) -> tuple[float, float, float]:
    """(station, lateral along the horizontal right, height above the ribbon) of a world point."""
    _, st, _ = poly.nearest(p[0], p[2])
    f = route.frame_at(st)
    rel = routelib.sub(p, f.pos)
    return st, routelib.dot(rel, f.right), rel[1]


# ------------------------------------------------------------------------------------------------ the jump
def find_lip(route: routelib.Route, lo: float, hi: float) -> float:
    best_st, best_y = lo, -1e9
    for w in route.waypoints:
        if lo <= w.station <= hi and w.pos[1] > best_y:
            best_y, best_st = w.pos[1], w.station
    return best_st


def deck_gap_span(route: routelib.Route, gap_from: float, gap_to: float) -> tuple[float, float]:
    """kit/Deck skips a segment whose START station is inside [from, to]; the segment before reaches its end."""
    wps = route.waypoints
    end_at = start_at = None
    for i in range(len(wps) - 1):
        st = wps[i].station
        if gap_from <= st <= gap_to:
            if end_at is None:
                end_at = st
        elif end_at is not None and start_at is None and st > gap_to:
            start_at = st
    return float(end_at), float(start_at)


def car_height(route: routelib.Route, lip: float, speed: float, x: float) -> float:
    f = route.frame_at(lip)
    vh = speed * math.hypot(f.tangent[0], f.tangent[2])
    t = x / vh
    return f.pos[1] + speed * f.tangent[1] * t - 0.5 * CAR_GRAVITY * t * t


def clears_gap(route: routelib.Route, lip: float, resume: float, speed: float) -> bool:
    x = resume - lip + 3.2
    return car_height(route, lip, speed, x) >= route.frame_at(resume + 3.2).pos[1]


def min_jump_speed(route: routelib.Route, lip: float, resume: float) -> float:
    lo, hi = 10.0, 400.0
    for _ in range(40):
        mid = (lo + hi) * 0.5
        if clears_gap(route, lip, resume, mid):
            hi = mid
        else:
            lo = mid
    return hi


def landing_station(route: routelib.Route, lip: float, resume: float, speed: float) -> float:
    x = resume - lip
    while x < 400:
        if car_height(route, lip, speed, x) <= route.frame_at(lip + x).pos[1]:
            return lip + x
        x += 0.25
    return lip + x


# ------------------------------------------------------------------------------------- route-following pieces
def curve_pieces(route: routelib.Route, lateral: float, height: float, skip: list[tuple[float, float]],
                 max_piece: float, sag: float, lo: float = 0.0, hi: float | None = None) -> list[dict]:
    """Greedy straight pieces along an offset curve (banked frame), split where the curve leaves a piece by more than
    `sag` or the piece would exceed `max_piece`. Each piece spans point a -> b exactly; skip ranges are holes."""
    pieces = []
    step = 1.0
    total = route.length if hi is None else hi
    st = lo
    while st < total - 1e-6:
        if in_ranges(st, skip):
            st += step
            continue
        a_st = st
        b_st = st
        probe = st + step
        while probe <= total + 1e-6 and not in_ranges(probe, skip):
            a = offset_point(route, a_st, lateral, height)
            b = offset_point(route, probe, lateral, height)
            if routelib.mag(routelib.sub(b, a)) > max_piece:
                break
            ok = True
            k = a_st + step
            ab = routelib.sub(b, a)
            while k < probe:
                p = offset_point(route, k, lateral, height)
                t = max(0.0, min(1.0, routelib.dot(routelib.sub(p, a), ab) / max(1e-9, routelib.dot(ab, ab))))
                q = routelib.add(a, routelib.mul(ab, t))
                if routelib.mag(routelib.sub(p, q)) > sag:
                    ok = False
                    break
                k += step
            if not ok:
                break
            b_st = probe
            probe += step
        if b_st <= a_st:
            b_st = min(total, a_st + step)
        pieces.append(piece_record(route, a_st, b_st, lateral, height))
        st = b_st
    return pieces


def piece_record(route: routelib.Route, a_st: float, b_st: float, lateral: float, height: float) -> dict:
    a = offset_point(route, a_st, lateral, height)
    b = offset_point(route, b_st, lateral, height)
    f = route.frame_at((a_st + b_st) * 0.5)
    _, up = banked_axes(f)
    look = routelib.unit(routelib.sub(b, a))
    right = routelib.unit(routelib.cross(look, up))
    up2 = routelib.unit(routelib.cross(right, look))
    return {"from": a_st, "to": b_st, "lateral": lateral, "height": height, "len": routelib.mag(routelib.sub(b, a)),
            "p": routelib.mul(routelib.add(a, b), 0.5), "r": yxz_from_axes(right, up2, look)}


def bucket(length: float, step: float = 0.25) -> float:
    return math.ceil(length / step) * step


# ------------------------------------------------------------------------------------------------- palette
C = {
    "cream": "#ead9bb", "creamLight": "#f3e8d2", "stone": "#d6c6a6", "stoneDark": "#b6a585", "stoneWarm": "#cbb48e",
    "navy": "#3a4664", "navyDark": "#2b3450", "steel": "#55627e", "steelLight": "#7a88a2",
    "brass": "#c8963c", "brassLight": "#e0b864", "copper": "#a86e2c",
    "plum": "#5e2f5a", "plumDark": "#43213f", "teal": "#3f8a96", "tealDark": "#2f6a76",
    "glass": "#b8e6f4", "skyGlass": "#9fd3ea", "paleBlue": "#bccbdb", "sand": "#dcc6a2", "white": "#f6f1e6",
    "neonCyan": "#59ecff", "neonAmber": "#ffaa3c", "neonWarm": "#ffd58a", "neonRed": "#ff5a4a", "neonPink": "#ff7ac8",
    "neonViolet": "#7c4dff", "parapet": "#4c5374",
    # v28 critic 1.16/1.24: painted forms instead of full neon faces (dark plum metal walls under a cream stone cap),
    # Sunshine-style cream/terracotta tower caps, one paint colour for the Glass Vault frame
    "plumWall": "#3e2440", "capStone": "#d9c8a8", "terracotta": "#c4704a", "vaultPaint": "#e8dcc4",
    "vaultGlass": "#8fd0d6", "windowWarm": "#e0ad78",
}
NC = {"nc": 1}


def part(shape: str, x: float, y: float, z: float, sx: float, sy: float, sz: float, rx: float, ry: float, rz: float,
         colour: str, material: str, extra: dict | None = None) -> list:
    p = [shape, r4(x), r4(y), r4(z), r4(sx), r4(sy), r4(sz), r4(rx), r4(ry), r4(rz), colour, material]
    if extra:
        p.append(dict(extra))
    return p


def nc(extra: dict | None = None) -> dict:
    e = dict(NC)
    if extra:
        e.update(extra)
    return e


# ---------------------------------------------------------------------------------------------- prefab kits
def inset_line(length: float, y: float, width: float) -> list:
    """v28 critic 1.16: a thin violet neon line set into both faces of a cap (0.04 proud of each face, inside the cap's
    own height), stopping a stud short of each piece end so the pieces read as a segmented inset, not one neon strip.
    nc: the cap it sits in keeps the collision."""
    ln = max(length - 2.0, length * 0.6)
    return [part("B", 0, y, 0, width + 0.08, 0.3, ln, 0, 0, 0, "#a8783a", "Neon", NC)]  # v29 A10: dim amber (was neonViolet)


def parapet_prefab(length: float) -> dict:
    """Parapet that is also the bridge's edge beam: dark plum metal wall under a cream stone cap with a thin inset neon
    line (v28 critic 1.16: the full violet neon cap read as a straight neon strip and the wall as a flat neon face).
    Wall and cap collide exactly as before (same boxes, same heights): the car's walls are unchanged."""
    h = WALL_TOP - WALL_BOTTOM
    return {"parts": [
        part("B", 0, (WALL_TOP + WALL_BOTTOM) / 2, 0, WALL_THICK, h, length, 0, 0, 0, C["plumWall"], "DiamondPlate"),
        part("B", 0, (WALL_TOP + CAP_TOP) / 2, 0, 2.6, CAP_TOP - WALL_TOP, length, 0, 0, 0, C["capStone"], "Brick"),
    ] + inset_line(length, (WALL_TOP + CAP_TOP) / 2, 2.6)}


def lane_prefab(length: float, colour: str, width: float = 0.9) -> dict:
    return {"parts": [part("B", 0, 0, 0, width, 0.16, length, 0, 0, 0, colour, "Neon", NC)]}


# ------------------------------------------------------------------------------------- space-neon (synthwave pass)
# 80s synthwave palette stepped along the lap: hot pink -> magenta -> purple -> blue -> cyan -> sunset orange. The left edge
# strip starts on step 0 and the right on step 3, so the two sides always read as a complementary pair (pink/cyan,
# magenta/orange, ...); a band is TRON_BAND studs long. Static colours: the "cycling" is the drive, no per-part script.
# v29 W1b A10 (critic v29: magenta/violet neon lines dominated space4 00/02/05/07/09): no magenta or violet left; the
# chevrons and light arches step through warm amber and cool cyan only (was hot pink, magenta, purple, blue, cyan, orange).
TRON_PALETTE = ("#e0a048", "#4fc8dc", "#d8b070", "#3fb4c8", "#e8a858", "#62d2e2")
# v29 A10: the road-edge strips and the transverse rungs are flush brass plates, not neon (a brass edge band on warm
# grey-stone plates); the amber lane lines one tier dimmer than the cyan centre line, which is 60 % as wide.
TRON_BRASS = "#b48a46"
LANE_CENTRE_W = 0.54
LANE_AMBER_DIM = "#c98838"
TRON_BAND = 150.0
TRON_EDGE_LATERAL = 20.4  # inside the curbs (deck half width 22), outside the corridor half width (19)
TRON_RUNG_STEP = 60.0
TRON_CHEVRON_STEP = 120.0
TRON_ARCH_STEP = 192.0
TRON_ARCH_B = 26.0  # crown height above the springs (the skyway arches are 38)


HOLO_K_LEAN = 0.6  # shared/SpaceNeonRules.reach: head/shoulder reach from the hip per unit height x sin(lean)
HOLO_K_ARM = 0.26  # plus the swinging hands
# v29 W1b A8 (critic v29: the giant magenta Neon figure leaning over the start straight was the 'magenta glass building'
# in space4 00/02/09): figures stand behind the first tower row (55 -> 180 studs) and are at most HOLO_MAX_H tall.
HOLO_CLEAR = 180.0  # studs of plan-view clearance from the race line to the nearest reachable part
HOLO_MAX_H = 60.0  # studs: height cap for every hologram figure
BOARD_W, BOARD_H, BOARD_RISE, BOARD_TOE = 88.0, 30.0, 52.0, 28.0  # holo billboard face size, height over the road, toe-in


def tron_colour(side: float, st: float) -> tuple[int, str]:
    i = (int(st // TRON_BAND) + (0 if side < 0 else 3)) % len(TRON_PALETTE)
    return i, TRON_PALETTE[i]


def tron_edge_prefab(length: float, colour: str) -> dict:
    # v29 A10: a brass edge band (Metal), not a synthwave neon strip; `colour` is kept for the key only
    return {"parts": [part("B", 0, 0, 0, 1.1, 0.12, length, 0, 0, 0, TRON_BRASS, "Metal", NC)]}


def tron_rung_prefab() -> dict:
    # v29 A10: a flush brass plate across the road (was a violet neon bar)
    return {"parts": [part("B", 0, 0, 0, 2 * (TRON_EDGE_LATERAL - 1.4), 0.06, 0.34, 0, 0, 0, TRON_BRASS, "Metal", NC)]}


def tron_chevron_prefab(colour: str) -> dict:
    """Two stacked forward chevrons flat on the road (local -z = the way the car drives).
    v37 (owner: "the arrows are facing the wrong direction"): a bar yawed ry has its long axis along (sin ry, cos ry) in
    (x, z), so the left arm (x < 0) takes ry < 0 for the tip to sit at the front (-z); it had +40 and the V pointed back."""
    parts = []
    for k in range(2):
        z = 4.0 - k * 7.0
        parts.append(part("B", -2.15, 0, z, 0.9, 0.14, 6.4, 0, -40, 0, colour, "Neon", NC))  # arms meet at the tip
        parts.append(part("B", 2.15, 0, z, 0.9, 0.14, 6.4, 0, 40, 0, colour, "Neon", NC))
    return {"parts": parts}


def tron_arch_prefab(glow: str) -> dict:
    """Thin neon light arch over the whole road: springs on the parapet caps, all nc, one lit keystone (MapLight)."""
    n = 8
    pts = [(VAULT_A * math.cos(math.pi * k / n), CAP_TOP + 4.0 + TRON_ARCH_B * math.sin(math.pi * k / n)) for k in range(n + 1)]
    parts = []
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        L = math.hypot(x1 - x0, y1 - y0)
        parts.append(part("B", (x0 + x1) / 2, (y0 + y1) / 2, 0, L + 0.6, 0.9, 0.9, 0, 0, math.degrees(math.atan2(y1 - y0, x1 - x0)),
                          glow, "Neon", NC))
    for sx in (-1, 1):
        parts.append(part("B", sx * VAULT_A, CAP_TOP + 2.0, 0, 1.2, 4.0, 1.2, 0, 0, 0, glow, "Neon", NC))
    top = CAP_TOP + 4.0 + TRON_ARCH_B
    parts.append(part("B", 0, top - 1.6, 0, 2.2, 0.6, 2.2, 0, 0, 0, glow, "Neon", nc({"l": [70, 1.5, glow, False]})))
    return {"parts": parts}


def turn_board_prefab(sgn: int) -> dict:
    """v37 turn sign for the walled 90-degree corners: a floating neon board (no post, all nc) hung outside the outer
    parapet and well above its cap, so the wall and its cap stay a clean drive surface. Navy face toward the driver (+z,
    who comes from +z), three amber chevrons pointing +x (sgn 1, a right-hand corner) or -x, cyan rim."""
    P = [part("B", 0, 0, 0, 12.0, 5.0, 0.6, 0, 0, 0, C["navyDark"], "SmoothPlastic", NC),
         part("B", 0, 2.7, 0.1, 12.6, 0.4, 0.8, 0, 0, 0, C["neonCyan"], "Neon", NC),
         part("B", 0, -2.7, 0.1, 12.6, 0.4, 0.8, 0, 0, 0, C["neonCyan"], "Neon", NC)]
    for tx in (-3.4, 0.0, 3.4):
        for up in (1, -1):  # upper arm runs down to the tip, lower arm up to it (a bar long in x rolled rz runs (cos, sin))
            P.append(part("B", sgn * (tx - 1.1), up * 1.1, 0.4, 3.3, 0.9, 0.3, 0, 0, -sgn * up * 45, C["neonAmber"], "Neon",
                          nc({"l": [14, 0.8, C["neonAmber"], False]}) if (tx == 0.0 and up == 1) else NC))
    return {"parts": P}


def streetlamp_prefab(glow: str) -> dict:
    """Lamp on the parapet cap, arm reaching over the road along local -x (instance yaw turns it to face the road)."""
    return {"parts": [
        part("B", 0, 0.6, 0, 2.4, 1.2, 2.4, 0, 0, 0, C["navyDark"], "DiamondPlate", NC),
        part("C", 0, 11.0, 0, 1.0, 20.0, 1.0, 0, 0, 0, C["navy"], "DiamondPlate", NC),
        part("B", 0, 21.2, 0, 1.7, 0.9, 1.7, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", -3.8, 21.5, 0, 7.6, 0.7, 0.7, 0, 0, 0, C["navy"], "DiamondPlate", NC),
        part("B", -7.4, 21.1, 0, 3.6, 1.1, 2.0, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", -7.4, 20.45, 0, 3.0, 0.3, 1.4, 0, 0, 0, glow, "Neon", nc({"l": [50, 2.4, glow, False]})),
    ]}


def vault_lamp_prefab(glow: str) -> dict:
    """Short wall lamp for inside the Glass Vault (a tall streetlamp would pierce the vault)."""
    return {"parts": [
        part("B", 0, 1.6, 0, 1.4, 3.2, 1.4, 0, 0, 0, C["navy"], "DiamondPlate", NC),
        part("B", -1.1, 3.3, 0, 2.4, 0.6, 1.6, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", -1.4, 2.95, 0, 1.8, 0.2, 1.2, 0, 0, 0, glow, "Neon", nc({"l": [30, 1.1, glow, False]})),
    ]}


VAULT_A, VAULT_B, VAULT_SEGS = WALL_LATERAL, 33.0, 10


def vault_points() -> list[tuple[float, float]]:
    return [(VAULT_A * math.cos(math.pi * k / VAULT_SEGS), CAP_TOP + VAULT_B * math.sin(math.pi * k / VAULT_SEGS))
            for k in range(VAULT_SEGS + 1)]


def vault_rib_prefab(heavy: bool = False) -> dict:
    pts = vault_points()
    parts = []
    thick, depth = (2.4, 3.0) if heavy else (1.4, 1.6)
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        L = math.hypot(x1 - x0, y1 - y0)
        # v28 critic 1.24: the whole frame (ribs, keystones, feet, purlins) in one paint colour
        parts.append(part("B", (x0 + x1) / 2, (y0 + y1) / 2, 0, L + 0.6, thick, depth, 0, 0,
                          math.degrees(math.atan2(y1 - y0, x1 - x0)), C["vaultPaint"], "DiamondPlate", NC))
    parts.append(part("B", 0, CAP_TOP + VAULT_B, 0, 3.2, 2.6, depth + 0.8, 0, 0, 0, C["vaultPaint"], "DiamondPlate", NC))
    for s in (-1, 1):
        parts.append(part("B", s * WALL_LATERAL, CAP_TOP + 0.6, 0, 3.4, 1.2, depth + 1.0, 0, 0, 0, C["vaultPaint"], "DiamondPlate", NC))
    if heavy:
        # portal: cyan neon outline on the inner face plus a cream stone collar
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            L = math.hypot(x1 - x0, y1 - y0)
            ang = math.degrees(math.atan2(y1 - y0, x1 - x0))
            nx, ny = -(y1 - y0) / L, (x1 - x0) / L  # inward normal of the counter-clockwise arc
            parts.append(part("B", (x0 + x1) / 2 + nx * 1.5, (y0 + y1) / 2 + ny * 1.5, -1.6, L, 0.45, 0.4, 0, 0, ang,
                              C["neonCyan"], "Neon", NC))
        for s in (-1, 1):
            parts.append(part("B", s * (WALL_LATERAL + 1.6), CAP_TOP + 6, 0, 3.2, 12, 4.4, 0, 0, 0, C["stone"], "Brick", NC))
    return {"parts": parts}


SKYWAY_B = 38.0


def skyway_arch_prefab(glow: str) -> dict:
    """L61 landmark beat: a monumental plum-and-brass arch over the road (the guide's portal language), standing on
    stone collars on both parapet caps, with a neon inner outline and a lit keystone that throws coloured light onto
    the road under it. All nc (the parapets are the walls); the arch springs at the parapet line, outside the
    corridor's half-width, and its crown is far above the corridor ceiling."""
    n = 12
    pts = [(VAULT_A * math.cos(math.pi * k / n), CAP_TOP + 4.0 + SKYWAY_B * math.sin(math.pi * k / n)) for k in range(n + 1)]
    parts = []
    for i, ((x0, y0), (x1, y1)) in enumerate(zip(pts, pts[1:])):
        L = math.hypot(x1 - x0, y1 - y0)
        ang = math.degrees(math.atan2(y1 - y0, x1 - x0))
        mx, my = (x0 + x1) / 2, (y0 + y1) / 2
        parts.append(part("B", mx, my, 0, L + 0.8, 3.4, 4.6, 0, 0, ang, C["plum"] if i % 2 else C["plumDark"], "SmoothPlastic", NC))
        nx, ny = -(y1 - y0) / L, (x1 - x0) / L
        parts.append(part("B", mx + nx * 2.0, my + ny * 2.0, 0, L + 0.2, 0.5, 5.0, 0, 0, ang, glow, "Neon", NC))
        if i % 3 == 1:
            parts.append(part("B", mx - nx * 1.9, my - ny * 1.9, 0, 2.2, 0.8, 5.4, 0, 0, ang, C["brass"], "Metal", NC))
    for sx in (-1, 1):
        parts.append(part("B", sx * VAULT_A, CAP_TOP + 4.0, 0, 6.0, 8.0, 7.0, 0, 0, 0, C["stone"], "Brick", NC))
        parts.append(part("B", sx * VAULT_A, CAP_TOP + 8.4, 0, 6.8, 1.0, 7.8, 0, 0, 0, C["brass"], "Metal", NC))
    top = CAP_TOP + 4.0 + SKYWAY_B
    parts.append(part("B", 0, top + 1.0, 0, 7.0, 7.0, 5.6, 0, 0, 45, C["brassLight"], "Metal", NC))
    parts.append(part("S", 0, top + 1.0, -1.6, 4.4, 4.4, 4.4, 0, 0, 0, glow, "Neon", nc({"l": [60, 2.2, glow, False]})))
    return {"parts": parts}


def vault_bay_prefab(bay: float) -> dict:
    """Glazing between two ribs. v28 critic 1.24: teal-tinted panes at 0.4 transparency (0.55 clear glass vanished at
    night, the vault read as bare ribs) and purlins along every second arc point (none on the springing points, which
    sit on the parapet caps), painted like the ribs. All nc and far above the corridor (lowest purlin ~17 over the
    cap line at lateral ~24)."""
    pts = vault_points()
    parts = []
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        L = math.hypot(x1 - x0, y1 - y0)
        parts.append(part("B", (x0 + x1) / 2, (y0 + y1) / 2, 0, L + 0.2, 0.3, bay - 1.4, 0, 0,
                          math.degrees(math.atan2(y1 - y0, x1 - x0)), C["vaultGlass"], "Glass", nc({"a": 0.4})))
    for k in range(2, VAULT_SEGS - 1, 2):
        x, y = pts[k]
        ang = math.pi * k / VAULT_SEGS
        ox, oy = math.cos(ang) * 0.6, math.sin(ang) * 0.6  # just outside the glass
        parts.append(part("B", x + ox, y + oy, 0, 1.0, 1.0, bay - 1.2, 0, 0, math.degrees(ang), C["vaultPaint"],
                          "DiamondPlate", NC))
    return {"parts": parts}


def vault_banner_prefab(glow: str) -> dict:
    """Vertical neon banner hanging on a rib leg (the guide's orange tunnel signs)."""
    return {"parts": [
        part("B", 0, 0, 0, 0.5, 8.4, 3.4, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", -0.35, 0, 0, 0.3, 7.4, 2.6, 0, 0, 0, glow, "Neon", NC),
        part("B", -0.5, 1.6, 0, 0.2, 0.5, 1.8, 0, 0, 0, C["plumDark"], "SmoothPlastic", NC),
        part("B", -0.5, -1.2, 0, 0.2, 0.5, 1.8, 0, 0, 0, C["plumDark"], "SmoothPlastic", NC),
    ]}


# Monorail viaduct (runs along world X; local x along the viaduct, z across)
V_IMPOST, V_DECK, V_TRUSS_TOP, V_BEAM_TOP = 64.0, 104.0, 116.0, 121.0


def viaduct_pier_prefab() -> dict:
    return {"parts": [
        part("B", 0, 2.0, 0, 16, 12, 20, 0, 0, 0, C["stoneDark"], "Brick", NC),
        part("B", 0, 36.0, 0, 10, 56, 14, 0, 0, 0, C["stone"], "Brick", NC),
        part("B", 0, 38.0, 0, 10.8, 3.0, 14.8, 0, 0, 0, C["steel"], "DiamondPlate", NC),
        part("B", 0, V_IMPOST + 1.0, 0, 12.4, 2.0, 16.4, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, (V_IMPOST + 2 + V_DECK - 2) / 2, 0, 10, V_DECK - V_IMPOST - 4, 14, 0, 0, 0, C["stoneWarm"], "Brick", NC),
        part("B", 0, V_DECK - 1.0, 0, 12, 2.0, 16, 0, 0, 0, C["creamLight"], "Brick", NC),
    ]}


def viaduct_span_prefab(span: float) -> dict:
    """One arch span between pier centres (local x = 0 at mid-span): stone arch ring, spandrels, steel deck girder,
    W-truss both sides, painted monorail beam with a brass running rail."""
    parts = []
    r = span / 2 - 5.0
    ring = 4.0
    rm = r + ring / 2
    spring = V_IMPOST + 2.0
    n = 8
    for k in range(n):
        a0, a1 = math.pi * k / n, math.pi * (k + 1) / n
        am = (a0 + a1) / 2
        chord = 2 * rm * math.sin((a1 - a0) / 2) + 0.6
        parts.append(part("B", rm * math.cos(am), spring + rm * math.sin(am), 0, chord, ring, 13, 0, 0,
                          math.degrees(am) + 90, C["stone"] if k % 2 else C["stoneWarm"], "Brick", NC))
    parts.append(part("B", 0, spring + r + ring / 2, 0, 4.2, ring + 1.6, 14, 0, 0, 0, C["creamLight"], "Brick", NC))
    top = V_DECK - 2.0
    crown = spring + r + ring
    parts.append(part("B", 0, (crown - 1 + top) / 2, 0, span - 9.6, top - crown + 1, 12.4, 0, 0, 0, C["stone"], "Brick", NC))
    for s in (-1, 1):
        x0, x1 = r * 0.42, span / 2 - 5.0
        y0 = spring + math.sqrt(max(0.0, (r + ring) ** 2 - x0 ** 2)) - 6
        parts.append(part("B", s * (x0 + x1) / 2, (y0 + top) / 2, 0, x1 - x0 + 0.4, top - y0, 12.6, 0, 0, 0,
                          C["stoneWarm"], "Brick", NC))
    parts.append(part("B", 0, V_DECK + 1.5, 0, span + 0.2, 3.0, 15.0, 0, 0, 0, C["steel"], "DiamondPlate", NC))
    tb, tt = V_DECK + 3.0, V_TRUSS_TOP
    xs = [-span / 2, -span / 4, 0.0, span / 4, span / 2]
    for zs in (-6.6, 6.6):
        parts.append(part("B", 0, tt, zs, span + 1.0, 1.4, 1.2, 0, 0, 0, C["navy"], "DiamondPlate", NC))
        parts.append(part("B", span / 2, (tb + tt) / 2, zs, 1.2, tt - tb, 1.2, 0, 0, 0, C["navy"], "DiamondPlate", NC))
        for k in range(4):
            xa, xb = xs[k], xs[k + 1]
            ya, yb = (tb, tt) if k % 2 == 0 else (tt, tb)
            L = math.hypot(xb - xa, yb - ya)
            parts.append(part("B", (xa + xb) / 2, (ya + yb) / 2, zs, L, 0.9, 0.9, 0, 0,
                              math.degrees(math.atan2(yb - ya, xb - xa)), C["steelLight"], "DiamondPlate", NC))
    # the monorail rides ON the truss (guide): a cross deck on the top chords carries the painted beam
    parts.append(part("B", 0, V_TRUSS_TOP + 0.9, 0, span + 0.2, 1.0, 14.4, 0, 0, 0, C["navyDark"], "DiamondPlate", NC))
    parts.append(part("B", 0, (V_TRUSS_TOP + 1.4 + V_BEAM_TOP) / 2, 0, span + 0.2, V_BEAM_TOP - V_TRUSS_TOP - 1.4, 4.6,
                      0, 0, 0, C["cream"], "Concrete", NC))
    parts.append(part("B", 0, V_BEAM_TOP - 1.4, 0, span + 0.2, 0.6, 4.8, 0, 0, 0, C["plum"], "SmoothPlastic", NC))
    parts.append(part("B", 0, V_BEAM_TOP + 0.2, 0, span + 0.2, 0.4, 1.4, 0, 0, 0, C["brass"], "Metal", NC))
    return {"parts": parts}


def train_prefab() -> dict:
    """Three-car painted monorail (cream body, plum roof, warm lit window bands), riding on the beam top (y = 0)."""
    parts = []
    for i, cx in enumerate((-27.5, 0.0, 27.5)):
        parts += [
            part("B", cx, 1.2, 0, 24.4, 1.6, 6.8, 0, 0, 0, C["navyDark"], "DiamondPlate", NC),
            part("B", cx, 4.8, 0, 24.0, 5.6, 7.4, 0, 0, 0, C["white"], "SmoothPlastic", NC),
            part("B", cx, 8.3, 0, 23.0, 1.6, 6.6, 0, 0, 0, C["plum"], "SmoothPlastic", NC),
            part("B", cx, 5.6, -3.76, 19.0, 1.9, 0.3, 0, 0, 0, C["neonWarm"], "Neon", NC),
            part("B", cx, 5.6, 3.76, 19.0, 1.9, 0.3, 0, 0, 0, C["neonWarm"], "Neon", NC),
            part("B", cx, 3.0, 0, 24.2, 0.7, 7.6, 0, 0, 0, C["teal"], "SmoothPlastic", NC),
        ]
        if i < 2:
            parts.append(part("B", cx + 13.75, 3.6, 0, 3.6, 3.0, 4.2, 0, 0, 0, C["navy"], "DiamondPlate", NC))
    parts.append(part("W", 27.5 + 14.5, 4.8, 0, 7.4, 5.6, 5.0, 0, -90, 0, C["white"], "SmoothPlastic", NC))
    parts.append(part("W", -27.5 - 14.5, 4.8, 0, 7.4, 5.6, 5.0, 0, 90, 0, C["white"], "SmoothPlastic", NC))
    parts.append(part("B", 27.5 + 12.4, 6.6, 0, 0.4, 1.6, 5.6, 0, 0, 0, C["neonCyan"], "Neon", NC))
    parts.append(part("B", -27.5 - 12.4, 6.6, 0, 0.4, 1.6, 5.6, 0, 0, 0, C["neonRed"], "Neon", NC))
    return {"parts": parts}


def station_prefab() -> dict:
    """Monorail terminus at each viaduct end: stone tower up to the platform, platform level with the train floor,
    brass columns, plum canopy, cyan sign."""
    plat = V_BEAM_TOP - 0.6  # platform top just under the car floor
    return {"parts": [
        part("B", 0, (plat - 10.0) / 2, 0, 30, plat + 2.0, 30, 0, 0, 0, C["stone"], "Brick", NC),  # -6 .. plat - 4
        part("B", 0, -2.0, 0, 38, 8, 38, 0, 0, 0, C["stoneDark"], "Brick", NC),
        part("B", 0, 34.0, 0, 31, 3, 31, 0, 0, 0, C["steel"], "DiamondPlate", NC),
        part("B", 0, V_IMPOST + 1.0, 0, 31.4, 2, 31.4, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, plat - 2.0, 0, 40, 4, 34, 0, 0, 0, C["creamLight"], "Concrete", NC),
        part("B", 0, plat - 0.5, -14, 36, 1.2, 4, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, plat - 0.5, 14, 36, 1.2, 4, 0, 0, 0, C["brass"], "Metal", NC),
        part("C", -16, plat + 7, -14, 1.6, 14, 1.6, 0, 0, 0, C["brass"], "Metal", NC),
        part("C", 16, plat + 7, -14, 1.6, 14, 1.6, 0, 0, 0, C["brass"], "Metal", NC),
        part("C", -16, plat + 7, 14, 1.6, 14, 1.6, 0, 0, 0, C["brass"], "Metal", NC),
        part("C", 16, plat + 7, 14, 1.6, 14, 1.6, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, plat + 14.6, 0, 44, 1.2, 37, 0, 0, 0, C["plumDark"], "SmoothPlastic", NC),
        part("W", 0, plat + 18.2, -9, 44, 6, 18, 0, 180, 0, C["plum"], "SmoothPlastic", NC),
        part("W", 0, plat + 18.2, 9, 44, 6, 18, 0, 0, 0, C["plum"], "SmoothPlastic", NC),
        part("B", 0, plat + 24, 0, 22, 6, 1.2, 0, 0, 0, C["navy"], "DiamondPlate", NC),
        part("B", 0, plat + 24, 0, 19, 4, 1.5, 0, 0, 0, C["neonCyan"], "Neon", nc({"l": [48, 1.2, C["neonCyan"], False]})),
    ]}


# ------------------------------------------------------------------ Wave 2 (critic v29 2.2): downtown stone-arch viaduct
# An arcade of road-spanning stone gateways along the downtown straight and the NE sweeper (20_SPACE4_STAR_CITY.png:
# brick piers with brass imposts, a voussoir arch ring with a cream keystone, stepped spandrels under a cream cornice),
# carrying a steel deck with W-truss rails and the painted monorail beam. Local frame: origin on the ribbon at the
# gateway's station, x across the road (route right, unbanked), y up, z along the road. Everything is nc and visible
# (DecorQuery clears CanQuery), so no part is a wall, a floor or a wheel-probe hit; the piers stand outside the parapets.
DT_FROM, DT_TO, DT_STEP = 1908.0, 2484.0, 48.0  # gateway stations: mid-gap on the 48-stud streetlamp grid (lamps 24 away)
DT_PIER_IN = 31.0  # pier inner face = intrados radius: parapet outer face 27.2, cap edge 27.5
DT_PIER_W = 8.0  # pier width across the road
DT_SPRING = 14.0  # springing line above the ribbon
DT_RING = 4.6  # voussoir ring depth (radial); extrados crown = SPRING + PIER_IN + RING = 49.6
DT_CORNICE = 50.0  # cornice band bottom
DT_DECK = 52.0  # deck girder bottom: the lowest viaduct part over the road
DT_DECK_TOP = 55.0
DT_BEAM_TOP = 60.4  # monorail running rail top: the MonorailSlot stands here
DT_GATE_DEPTH = 6.4  # voussoir ring depth along the road (piers and spandrels sit 0.4 behind its faces)
DT_SHAFT_TOP = -6.0  # the gateway prefab starts here; the pier shafts run from the plaza up to it
DT_SLOT_STATION = 2028.0  # the monorail slot sits on the straight (bank 0) between the 2004 and 2052 gateways
DT_SLOT_SIZE = (7.8, 9.2, 83.0)  # three-car train envelope (train_prefab): across, up, along
DT_LANTERN_EVERY = 2  # a warm bounce lantern under every second keystone


def dt_gate_prefab(lantern: bool) -> dict:
    parts = []
    xc = DT_PIER_IN + DT_PIER_W / 2
    pd = DT_GATE_DEPTH - 0.8
    for s in (-1, 1):
        # pier from the shaft top to the cornice (the arch ring springs from its inner face)
        parts.append(part("B", s * xc, (DT_SHAFT_TOP + DT_CORNICE) / 2, 0, DT_PIER_W, DT_CORNICE - DT_SHAFT_TOP, pd,
                          0, 0, 0, C["stoneWarm"], "Brick", NC))
        # stepped plinth course where the shaft meets the gateway, brass impost at the springing line
        parts.append(part("B", s * xc, DT_SHAFT_TOP + 1.5, 0, DT_PIER_W + 1.6, 3.0, pd + 1.6, 0, 0, 0, C["stoneDark"],
                          "Brick", NC))
        parts.append(part("B", s * xc, DT_SPRING - 0.6, 0, DT_PIER_W + 1.2, 1.6, pd + 1.2, 0, 0, 0, C["brass"], "Metal", NC))
        # plum painted inset panels on both faces of the pier (contrasting inset detail), 0.15 proud
        for zf in (-1, 1):
            parts.append(part("B", s * xc, DT_SPRING + 15.0, zf * (pd / 2 + 0.15), DT_PIER_W - 2.4, 18.0, 0.3, 0, 0, 0,
                              C["plum"], "SmoothPlastic", NC))
        # stepped spandrels between the ring and the cornice: every inner corner lies outside the intrados
        for a, b in ((24.0, DT_PIER_IN), (15.0, 24.0)):
            y0 = DT_SPRING + math.sqrt(DT_PIER_IN ** 2 - a ** 2) + 0.4
            parts.append(part("B", s * (a + b) / 2, (y0 + DT_CORNICE) / 2, 0, b - a + 0.2, DT_CORNICE - y0, pd - 0.4,
                              0, 0, 0, C["stone"], "Brick", NC))
    y0 = DT_SPRING + DT_PIER_IN + 0.4
    parts.append(part("B", 0, (y0 + DT_CORNICE) / 2, 0, 30.2, DT_CORNICE - y0, pd - 0.4, 0, 0, 0, C["stone"], "Brick", NC))
    # voussoir ring: 10 alternating stones on a semicircle (intrados radius DT_PIER_IN); the two crown stones are
    # narrowed around a proud cream keystone
    n = 10
    rm = DT_PIER_IN + DT_RING / 2
    for k in range(n):
        a0, a1 = math.pi * k / n, math.pi * (k + 1) / n
        am = (a0 + a1) / 2
        crown = k in (n // 2 - 1, n // 2)
        chord = 2 * rm * math.sin((a1 - a0) / 2) + (-1.6 if crown else 0.5)
        colour = C["stoneWarm"] if crown else (C["stone"] if k % 2 else C["sand"])
        parts.append(part("B", rm * math.cos(am), DT_SPRING + rm * math.sin(am), 0, chord, DT_RING, DT_GATE_DEPTH,
                          0, 0, math.degrees(am) + 90, colour, "Brick", NC))
    parts.append(part("B", 0, DT_SPRING + DT_PIER_IN + DT_RING / 2 + 0.2, 0, 4.4, DT_RING + 1.6, DT_GATE_DEPTH + 0.6,
                      0, 0, 0, C["creamLight"], "Brick", NC))
    # cornice: cream band over a stepped dark course; wedge nosings bevel both ends
    span = 2 * (DT_PIER_IN + DT_PIER_W) + 1.6
    parts.append(part("B", 0, DT_CORNICE + 1.0, 0, span, 2.0, DT_GATE_DEPTH + 1.4, 0, 0, 0, C["creamLight"], "Brick", NC))
    parts.append(part("B", 0, DT_CORNICE + 0.4, 0, span - 1.2, 0.8, DT_GATE_DEPTH + 0.6, 0, 0, 0, C["stoneDark"],
                      "Brick", NC))
    for s in (-1, 1):
        parts.append(part("W", s * (span / 2 + 0.6), DT_CORNICE + 1.0, 0, DT_GATE_DEPTH + 1.4, 2.0, 1.2, 0, -90 * s, 0,
                          C["creamLight"], "Brick", NC))
    if lantern:
        # warm bounce lantern hung under the keystone (ART_BAR light rule: warm PointLights under spans)
        yk = DT_SPRING + DT_PIER_IN
        parts.append(part("B", 0, yk - 1.4, 0, 0.6, 2.8, 0.6, 0, 0, 0, C["brass"], "Metal", NC))
        parts.append(part("B", 0, yk - 3.6, 0, 2.2, 1.8, 2.2, 0, 45, 0, C["brass"], "Metal", NC))
        parts.append(part("B", 0, yk - 4.7, 0, 1.6, 0.5, 1.6, 0, 45, 0, C["neonWarm"], "Neon",
                          nc({"l": [38, 1.0, C["neonWarm"], False]})))
    return {"parts": parts}


def dt_shaft_prefab(length: float) -> dict:
    """Pier shaft from the plaza (local y = 0, 3 studs under the ground) up to the gateway (local y = length): stone
    with a stepped footing and a steel string course."""
    pd = DT_GATE_DEPTH - 0.8
    return {"parts": [
        part("B", 0, length / 2, 0, DT_PIER_W, length + 0.2, pd, 0, 0, 0, C["stone"], "Brick", NC),
        part("B", 0, 3.0, 0, DT_PIER_W + 3.2, 6.0, pd + 3.2, 0, 0, 0, C["stoneDark"], "Brick", NC),
        part("B", 0, 7.0, 0, DT_PIER_W + 1.6, 2.0, pd + 1.6, 0, 0, 0, C["stoneDark"], "Brick", NC),
        part("B", 0, length * 0.55, 0, DT_PIER_W + 1.0, 1.4, pd + 1.0, 0, 0, 0, C["steel"], "DiamondPlate", NC),
    ]}


def dt_deck_prefab(length: float) -> dict:
    """One deck span between two gateway crowns (local z along the chord, origin at mid-span on the deck girder's
    bottom): steel girder with plum fascias, W-truss rails, cream monorail beam with a plum band and a brass rail."""
    L = length
    parts = [
        part("B", 0, 1.5, 0, 14.0, 3.0, L + 0.2, 0, 0, 0, C["steel"], "DiamondPlate", NC),
        part("B", 0, 0.2, 0, 12.4, 0.4, L + 0.2, 0, 0, 0, C["navyDark"], "DiamondPlate", NC),
    ]
    tb, tt = DT_DECK_TOP - DT_DECK, DT_DECK_TOP - DT_DECK + 4.2
    zs = [-L / 2 + L * k / 4 for k in range(5)]
    for s in (-1, 1):
        parts.append(part("B", s * 7.15, 1.5, 0, 0.3, 2.2, L - 0.4, 0, 0, 0, C["plum"], "SmoothPlastic", NC))
        parts.append(part("B", s * 6.6, tt, 0, 0.9, 0.9, L + 0.6, 0, 0, 0, C["navy"], "DiamondPlate", NC))
        for k in range(4):
            za, zb = zs[k], zs[k + 1]
            ya, yb = (tb, tt) if k % 2 == 0 else (tt, tb)
            ln = math.hypot(zb - za, yb - ya)
            parts.append(part("B", s * 6.6, (ya + yb) / 2, (za + zb) / 2, 0.7, 0.7, ln,
                              -math.degrees(math.atan2(yb - ya, zb - za)), 0, 0, C["steelLight"], "DiamondPlate", NC))
    bt = DT_BEAM_TOP - DT_DECK
    parts.append(part("B", 0, (3.0 + bt - 0.4) / 2, 0, 4.6, bt - 0.4 - 3.0, L + 0.2, 0, 0, 0, C["cream"], "Concrete", NC))
    parts.append(part("B", 0, bt - 1.8, 0, 4.8, 0.6, L + 0.2, 0, 0, 0, C["plum"], "SmoothPlastic", NC))
    parts.append(part("B", 0, bt - 0.2, 0, 1.4, 0.4, L + 0.2, 0, 0, 0, C["brass"], "Metal", NC))
    return {"parts": parts}


def monorail_slot_prefab() -> dict:
    """Invisible anchored placeholder for the Wave 2 monorail mesh (origin on the running rail, local z along the
    beam): the three-car train envelope only. Transparency 1 and nc; it stands DT_BEAM_TOP studs over the road."""
    w, h, ln = DT_SLOT_SIZE
    return {"parts": [part("B", 0, h / 2, 0, w, h, ln, 0, 0, 0, C["white"], "SmoothPlastic", nc({"a": 1}))]}


# ------------------------------------------------------------------ Wave 2 (critic v29 2.1): gate portal frames
# Octagonal cream-rim frames with a recessed plum band and gold clamps around each boost gate, coaxial with the kit
# ring (ring centre 3 over the ribbon; housing outer radius 14.6, clasps 15.1). Local frame = the ring's: XY is the
# ring plane, z along travel. Only the five faces that reach above the road are built (the lower three would sit in
# the deck). Frames only: nc (DecorQuery clears CanQuery); the kit ring and its trigger are untouched.
GP_BAND_IN, GP_RIM_IN, GP_RIM_OUT = 15.6, 17.0, 20.6  # apothems: plum band inner, cream rim inner, cream rim outer
GP_RIM_DEPTH, GP_BAND_DEPTH = 5.0, 3.6


def gate_portal_prefab(open_side: int = 0) -> dict:
    """open_side (+1 local right / -1 local left / 0 none): leave out that vertical side face and its clamp. The offset
    start pair (lateral -9 at st 488, +9 at st 512) opens its inner side: a full frame would stand that post at lateral
    -+8..11.6, square on the other start gate's drive line (a phantom pillar every car through that gate drives into)."""
    parts = []
    t = math.tan(math.pi / 8)
    for k in range(8):
        ang = math.pi / 2 + k * math.pi / 4  # face normal; k = 0 is the flat top
        cx, cy = math.cos(ang), math.sin(ang)
        if cy < -0.1:
            continue  # lower diagonals and the bottom: inside the deck
        if open_side and cx * open_side > 0.9:
            continue  # the open inner side of an offset start gate
        rot = math.degrees(ang) - 90
        am = (GP_RIM_IN + GP_RIM_OUT) / 2
        parts.append(part("B", cx * am, cy * am, 0, 2 * am * t + 0.6, GP_RIM_OUT - GP_RIM_IN, GP_RIM_DEPTH, 0, 0, rot,
                          C["creamLight"] if k % 2 == 0 else C["cream"], "SmoothPlastic", NC))
        bm = (GP_BAND_IN + GP_RIM_IN) / 2 - 0.1
        parts.append(part("B", cx * bm, cy * bm, 0, 2 * bm * t + 0.4, GP_RIM_IN - GP_BAND_IN + 0.2, GP_BAND_DEPTH, 0, 0,
                          rot, C["plum"], "SmoothPlastic", NC))
        # bevel trims on the outer edge of both faces: a wedge whose slope faces outward and forward/back
        for zf in (-1.0, 1.0):
            right = (-zf * cy, zf * cx, 0.0)
            r_w = yxz_from_axes(right, (cx, cy, 0.0), (0.0, 0.0, zf))
            ro = GP_RIM_OUT - 0.6
            parts.append(part("W", cx * ro, cy * ro, zf * (GP_RIM_DEPTH / 2 + 0.4), 2 * ro * t - 0.4, 1.2, 0.8,
                              r_w[0], r_w[1], r_w[2], C["stone"], "SmoothPlastic", NC))
    # gold clamps at 12, 3 and 9 o'clock straddling the rim, a copper bolt plate inside each
    for ang in (math.pi / 2, 0.0, math.pi):
        cx, cy = math.cos(ang), math.sin(ang)
        if open_side and cx * open_side > 0.9:
            continue
        rot = math.degrees(ang) - 90
        r = (GP_RIM_IN + GP_RIM_OUT) / 2 + 0.4
        parts.append(part("B", cx * r, cy * r, 0, 4.4, GP_RIM_OUT - GP_RIM_IN + 1.6, GP_RIM_DEPTH + 1.4, 0, 0, rot,
                          C["brassLight"], "Metal", NC))
        parts.append(part("B", cx * (r - 1.0), cy * (r - 1.0), 0, 2.6, 1.6, GP_RIM_DEPTH + 2.0, 0, 0, rot,
                          C["copper"], "Metal", NC))
    return {"parts": parts}


def gantry_prefab(glow: str) -> dict:
    """Sign bridge over the road: legs on both parapet caps, steel beam, framed neon sign (no text).
    v29 W1b A13 (critic v29 space4 03/10): painted cream stone legs and a brass beam (were navy and steel plate); the
    only emissive face is the sign. client/CameraFade fades the legs when the chase camera passes beside them."""
    w = WALL_LATERAL * 2
    return {"parts": [
        part("B", -WALL_LATERAL, CAP_TOP + 12, 0, 1.6, 24, 1.6, 0, 0, 0, C["capStone"], "Brick", NC),
        part("B", WALL_LATERAL, CAP_TOP + 12, 0, 1.6, 24, 1.6, 0, 0, 0, C["capStone"], "Brick", NC),
        part("B", 0, CAP_TOP + 24.6, 0, w + 3, 1.6, 2.2, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, CAP_TOP + 29.6, 0, 26, 8.4, 1.4, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, CAP_TOP + 29.6, -0.5, 23.6, 6.4, 0.8, 0, 0, 0, glow, "Neon", NC),
        part("B", -7, CAP_TOP + 29.6, -1.0, 3.0, 3.0, 0.3, 0, 0, 0, C["plumDark"], "SmoothPlastic", NC),
        part("B", 4, CAP_TOP + 29.6, -1.0, 10.0, 1.2, 0.3, 0, 0, 0, C["plumDark"], "SmoothPlastic", NC),
    ]}


def start_arch_prefab() -> dict:
    parts = [
        part("B", -WALL_LATERAL, CAP_TOP + 11, 0, 2.8, 22, 2.8, 0, 0, 0, C["navy"], "DiamondPlate", NC),
        part("B", WALL_LATERAL, CAP_TOP + 11, 0, 2.8, 22, 2.8, 0, 0, 0, C["navy"], "DiamondPlate", NC),
        part("B", 0, CAP_TOP + 23, 0, WALL_LATERAL * 2 + 4, 2.2, 3.0, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, CAP_TOP + 25.4, 0, 30, 2.6, 2.4, 0, 0, 0, C["neonCyan"], "Neon", NC),
    ]
    for i in range(12):
        parts.append(part("B", -27.5 + i * 5, CAP_TOP + 20.6, 0, 5, 2.6, 0.5, 0, 0, 0,
                          C["white"] if i % 2 == 0 else "#1e1a22", "SmoothPlastic", NC))
    return {"parts": parts}


def start_line_prefab() -> dict:
    parts = []
    for i in range(22):
        for j in range(2):
            parts.append(part("B", -21 + i * 2, 0, -1 + j * 2, 2, 0.12, 2, 0, 0, 0,
                              C["white"] if (i + j) % 2 == 0 else "#1e1a22", "SmoothPlastic", NC))
    return {"parts": parts}


def lip_chevron_prefab() -> dict:
    parts = [part("B", 0, 0, 0, 40, 0.14, 5, 0, 0, 0, C["brass"], "Metal", NC)]
    for i in range(5):
        x = -16 + i * 8
        # v37: tips forward (-z), as tron_chevron_prefab (the arms had +45 on the left and pointed back at the driver);
        # flat bars meeting at the tip (0.14-tall wedges hid their thin front ends, so the ^ read as loose dashes)
        parts.append(part("B", x - 1.45, 0.05, 0, 0.8, 0.14, 4.0, 0, -45, 0, C["neonAmber"], "Neon", NC))
        parts.append(part("B", x + 1.45, 0.05, 0, 0.8, 0.14, 4.0, 0, 45, 0, C["neonAmber"], "Neon", NC))
    return {"parts": parts}


def rift_beacon_prefab() -> dict:
    return {"parts": [
        part("B", 0, 3.0, 0, 1.6, 6.0, 1.6, 0, 0, 0, C["navyDark"], "DiamondPlate", NC),
        part("B", 0, 1.6, 0, 1.7, 1.0, 1.7, 0, 0, 0, C["neonAmber"], "Neon", NC),
        part("B", 0, 4.0, 0, 1.7, 1.0, 1.7, 0, 0, 0, C["neonAmber"], "Neon", NC),
        part("S", 0, 7.0, 0, 2.2, 2.2, 2.2, 0, 0, 0, C["neonRed"], "Neon", nc({"l": [26, 1.0, C["neonAmber"], False]})),
    ]}


def portal_prefab() -> dict:
    """Stone tunnel portal at each Alt1 mouth (kit tunnel walls at +-16, roof at +31 around the opening). The piers
    collide (racers on the approach shelf can reach them); everything above is decoration."""
    return {"parts": [
        # v29 W1b A12: the piers read as a bright cream slab jutting into the Alt1 exit (space4 08). They collide, so only
        # their paint changes (same boxes, same Brick material): a darker moon-stone grey that sits back into the tube.
        part("B", -23.0, 17.0, 0, 6, 38, 8, 0, 0, 0, "#9a8f8a", "Brick"),
        part("B", 23.0, 17.0, 0, 6, 38, 8, 0, 0, 0, "#9a8f8a", "Brick"),
        part("W", -28.5, 9.0, 0, 8, 22, 5, 0, 90, 0, C["stoneDark"], "Brick", NC),
        part("W", 28.5, 9.0, 0, 8, 22, 5, 0, -90, 0, C["stoneDark"], "Brick", NC),
        part("B", 0, 38.5, 0, 54, 7, 9, 0, 0, 0, C["stoneWarm"], "Brick", NC),
        part("B", 0, 34.6, 0, 42, 1.2, 9.6, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, 35.2, -4.9, 36, 0.8, 0.4, 0, 0, 0, C["neonCyan"], "Neon", NC),
        part("B", 0, 43.6, 0, 12, 4, 9.4, 0, 0, 0, C["creamLight"], "Brick", NC),
    ]}


def tunnel_chevron_prefab(roof_bottom: float) -> dict:
    """Downward neon chevron (a V over the hole) just proud of the Alt1 tube roof's front face, which kit/Deck puts 1 stud
    upstream of the first Alt1 point (local +z = toward the approach); roof_bottom is the roof's underside over the pivot."""
    y = roof_bottom + 3.0  # the 6-tall roof's face centre
    return {"parts": [
        part("B", -2.1, y, 1.45, 0.9, 5.6, 0.5, 0, 0, 42, C["neonCyan"], "Neon", NC),
        part("B", 2.1, y, 1.45, 0.9, 5.6, 0.5, 0, 0, -42, C["neonCyan"], "Neon", NC),
        part("B", -6.4, y, 1.45, 0.9, 5.6, 0.5, 0, 0, 42, C["neonAmber"], "Neon", NC),
        part("B", 6.4, y, 1.45, 0.9, 5.6, 0.5, 0, 0, -42, C["neonAmber"], "Neon", NC),
    ]}


# Towers (all nc; base at local y = 0, embedded a few studs into the ground)
# L61 night: dark tinted glass shafts (the GlassPanels texture stays, its value comes down), slate podiums, neon bands
# and corner rim strips in four hues so districts read apart
# v28 critic 1.24: crowns are stepped painted stone caps, cream or terracotta (Sunshine roofs), in place of the brass /
# copper metal blocks that read as orange crates; "step" is the slab under each crown in the other tone
# v29 W1b A11 (critic v29 space4 00/01/03/04/05: navy hex glass towers read as a cold night city): three of the four
# palettes (75 % of the towers) are painted stone shafts in cream #d9c8a8, tan and terracotta with dusty-teal accents and
# a hex-glass storefront band only on the podium ("shaftMat" Concrete -> SR_SPACE_StoneBlocks, "podiumMat" Plastic ->
# SR_SPACE_GlassPanels); the fourth keeps a teal glass shaft. Bands are cyan or amber (no pink or violet) and every tower
# keeps its warm window band. Was: navy/plum/teal/indigo glass shafts on slate podiums, cyan/pink/amber/violet bands.
PAL = [
    {"podium": "#6f9a98", "podiumMat": "Plastic", "shaft": "#d9c8a8", "shaftMat": "Concrete", "accent": "#5f8a88",
     "crown": C["terracotta"], "step": C["capStone"], "band": C["neonCyan"]},
    {"podium": "#6f9a98", "podiumMat": "Plastic", "shaft": "#c8a67c", "shaftMat": "Concrete", "accent": "#5f8a88",
     "crown": C["capStone"], "step": C["terracotta"], "band": C["neonAmber"]},
    {"podium": "#46576a", "shaft": "#265a74", "accent": C["tealDark"], "crown": C["capStone"], "step": C["terracotta"], "band": C["neonAmber"]},
    {"podium": "#6f9a98", "podiumMat": "Plastic", "shaft": "#c4704a", "shaftMat": "Concrete", "accent": "#5f8a88",
     "crown": C["capStone"], "step": C["creamLight"], "band": C["neonCyan"]},
]
CAP_MAT = "Concrete"  # partRules: Concrete -> SR_SPACE_StoneBlocks, colour kept


def dim(colour: str, f: float) -> str:
    v = [int(colour[i:i + 2], 16) for i in (1, 3, 5)]
    return "#%02x%02x%02x" % tuple(max(0, min(255, round(c * f))) for c in v)


def rims(w: float, d: float, y0: float, h: float, colour: str, corners=((1, 1),)) -> list:  # v29 A11: one rim strip (was two)
    """Vertical neon rim strips on two opposite corners of a w x d shaft (L61: glow carves the tower silhouettes; a
    dimmer tier than the route lines and the bands)."""
    colour = dim(colour, 0.62)
    return [part("B", sx * (w / 2 + 0.15), y0 + h / 2, sz * (d / 2 + 0.15), 0.9, h, 0.9, 0, 0, 0, colour, "Neon", NC)
            for sx, sz in corners]


def tower_setback(h: float, p: dict) -> dict:
    h1, h2 = h * 0.58, h * 0.27
    y1 = 12 + h1
    y2 = y1 + 1.6 + h2
    parts = [
        part("B", 0, 4, 0, 46, 16, 46, 0, 0, 0, p["podium"], p.get("podiumMat", "Concrete"), NC),
        part("B", 0, 12 + h1 / 2, 0, 32, h1, 32, 0, 0, 0, p["shaft"], p.get("shaftMat", "Plastic"), NC),
        part("B", 0, y1 + 0.8, 0, 35, 1.6, 35, 0, 0, 0, p["step"], CAP_MAT, NC),
        part("B", 0, y1 + 1.6 + h2 / 2, 0, 23, h2, 23, 0, 0, 0, p["shaft"], p.get("shaftMat", "Plastic"), NC),
        part("B", 0, y2 + 0.9, 0, 26, 1.8, 26, 0, 0, 0, p["step"], CAP_MAT, NC),
        part("K", 0, y2 + 9.8, 0, 23, 16, 23, 0, 45, 0, p["crown"], CAP_MAT, nc({"n": 4})),
        part("C", 0, y2 + 23.8, 0, 1.0, 16, 1.0, 0, 0, 0, p["accent"], "DiamondPlate", NC),
        part("S", 0, y2 + 32.8, 0, 2.6, 2.6, 2.6, 0, 0, 0, C["neonRed"], "Neon", NC),
        part("B", 0, 12 + h1 * 0.33, 0, 32.4, 1.1, 32.4, 0, 0, 0, p["band"], "Neon", NC),
        part("B", 0, 12 + h1 * 0.66, 0, 32.3, 2.6, 32.3, 0, 0, 0, C["windowWarm"], "Neon", NC),  # warm window band
        part("B", 0, y1 + 1.6 + h2 * 0.5, 0, 23.4, 1.0, 23.4, 0, 0, 0, p["band"], "Neon", NC),
        part("B", 16.4, 12 + h1 / 2, 0, 1.2, h1, 6, 0, 0, 0, p["accent"], "DiamondPlate", NC),
        part("B", -16.4, 12 + h1 / 2, 0, 1.2, h1, 6, 0, 0, 0, p["accent"], "DiamondPlate", NC),
    ] + rims(32, 32, 12, h1, p["band"])  # v29 A11: one rim strip per tower (the upper shaft had a second pair)
    return {"parts": parts}


def tower_slab(h: float, p: dict) -> dict:
    parts = [
        part("B", 0, 4, 0, 62, 14, 30, 0, 0, 0, p["podium"], p.get("podiumMat", "Concrete"), NC),
        part("B", 0, 10 + h / 2, 0, 54, h, 20, 0, 0, 0, p["shaft"], p.get("shaftMat", "Plastic"), NC),
        part("B", 0, 10 + h + 0.9, 0, 56, 1.8, 22, 0, 0, 0, p["step"], CAP_MAT, NC),
        part("W", 0, 10 + h + 8.8, 0, 54, 14, 20, 0, 0, 0, p["crown"], CAP_MAT, NC),
        part("B", 0, 10 + h * 0.4, 0, 54.4, 1.0, 20.4, 0, 0, 0, p["band"], "Neon", NC),
        part("B", 0, 10 + h * 0.75, 0, 54.3, 2.6, 20.3, 0, 0, 0, C["windowWarm"], "Neon", NC),  # warm window band
    ] + rims(54, 20, 10, h, p["band"])
    for x in (-18, 0, 18):
        parts.append(part("B", x, 10 + h / 2, 10.8, 2.2, h, 1.6, 0, 0, 0, p["accent"], "DiamondPlate", NC))
        parts.append(part("B", x, 10 + h / 2, -10.8, 2.2, h, 1.6, 0, 0, 0, p["accent"], "DiamondPlate", NC))
    return {"parts": parts}


def tower_spire(h: float, p: dict) -> dict:
    a, b, c = h * 0.5, h * 0.28, h * 0.14
    return {"parts": [
        part("B", 0, 5, 0, 34, 14, 34, 0, 0, 0, p["podium"], p.get("podiumMat", "Concrete"), NC),
        part("B", 0, 12 + a / 2, 0, 24, a, 24, 0, 0, 0, p["shaft"], p.get("shaftMat", "Plastic"), NC),
        part("B", 0, 12 + a + b / 2, 0, 17, b, 17, 0, 45, 0, p["shaft"], p.get("shaftMat", "Plastic"), NC),
        part("B", 0, 12 + a + 0.8, 0, 27, 1.6, 27, 0, 0, 0, p["step"], CAP_MAT, NC),
        part("B", 0, 12 + a + b + c / 2, 0, 11, c, 11, 0, 0, 0, p["accent"], "DiamondPlate", NC),
        part("B", 0, 12 + a + b + c + 0.8, 0, 13, 1.6, 13, 0, 0, 0, p["step"], CAP_MAT, NC),
        part("K", 0, 12 + a + b + c + 16.6, 0, 9, 30, 9, 0, 0, 0, p["crown"], CAP_MAT, nc({"n": 6})),
        part("S", 0, 12 + a + b + c + 33.6, 0, 3, 3, 3, 0, 0, 0, p["band"], "Neon", NC),
        part("B", 0, 12 + a * 0.5, 0, 24.3, 2.6, 24.3, 0, 0, 0, C["windowWarm"], "Neon", NC),  # warm window band
        part("B", 0, 12 + a + b * 0.5, 0, 17.4, 1.0, 17.4, 0, 45, 0, p["band"], "Neon", NC),
    ] + rims(24, 24, 12, a, p["band"])}


def tower_twin(h: float, p: dict) -> dict:
    parts = [part("B", 0, 4, 0, 60, 14, 30, 0, 0, 0, p["podium"], p.get("podiumMat", "Concrete"), NC)]
    for s, hh in ((-1, h), (1, h * 0.82)):
        parts += [
            part("B", s * 15, 10 + hh / 2, 0, 18, hh, 20, 0, 0, 0, p["shaft"], p.get("shaftMat", "Plastic"), NC),
            part("B", s * 15, 10 + hh + 0.9, 0, 20, 1.8, 22, 0, 0, 0, p["step"], CAP_MAT, NC),
            part("W", s * 15, 10 + hh + 7.8, 0, 20, 12, 18, 0, 90 * s, 0, p["crown"], CAP_MAT, NC),
            part("B", s * 15, 10 + hh * 0.45, 0, 18.4, 1.0, 20.4, 0, 0, 0, p["band"], "Neon", NC),
            part("B", s * 24.15, 10 + hh / 2, 10.15, 0.9, hh, 0.9, 0, 0, 0, dim(p["band"], 0.62), "Neon", NC),
        ]
    parts.append(part("B", 0, 10 + h * 0.62, 0, 13, 6, 9, 0, 0, 0, p["accent"], "DiamondPlate", NC))
    parts.append(part("B", 0, 10 + h * 0.62, 0, 12, 2.2, 9.4, 0, 0, 0, C["windowWarm"], "Neon", NC))  # warm window band
    return {"parts": parts}


def dome_hall(p: dict) -> dict:
    return {"parts": [
        part("B", 0, 6, 0, 64, 18, 64, 0, 0, 0, p["podium"], p.get("podiumMat", "Concrete"), NC),
        part("C", 0, 19, 0, 46, 8, 46, 0, 0, 0, p["accent"], "DiamondPlate", NC),
        part("K", 0, 34, 0, 48, 22, 48, 0, 22.5, 0, C["skyGlass"], "Plastic", nc({"n": 8})),
        part("C", 0, 23.4, 0, 47, 1.0, 47, 0, 0, 0, p["band"], "Neon", NC),
        part("C", 0, 48, 0, 4, 6, 4, 0, 0, 0, p["crown"], CAP_MAT, NC),
    ]}


def low_block(w: float, d: float, h: float, p: dict) -> dict:
    return {"parts": [
        # v29 A11: a painted-stone palette's low block is its stone body (the podium hex band is for the towers)
        part("B", 0, h / 2 - 2, 0, w, h + 4, d, 0, 0, 0, p["shaft"] if "shaftMat" in p else p["podium"],
             p["shaftMat"] if "shaftMat" in p else "Concrete", NC),
        part("B", w * 0.18, h + 4, d * 0.1, w * 0.5, 8, d * 0.55, 0, 0, 0, p["shaft"], p.get("shaftMat", "Plastic"), NC),
        part("B", -w * 0.28, h + 2.5, -d * 0.2, 8, 5, 8, 0, 0, 0, p["accent"], "DiamondPlate", NC),
        part("B", 0, h * 0.55, 0, w + 0.4, 0.9, d + 0.4, 0, 0, 0, p["band"], "Neon", NC),
        part("W", w * 0.18, h + 10, d * 0.1, w * 0.5, 4, d * 0.55, 0, 0, 0, p["crown"], CAP_MAT, NC),
    ]}


def star_spire() -> dict:
    """Hero landmark at the city centre: faceted spire, brass halo ring, cyan core light, visible from the whole lap."""
    parts = [
        part("B", 0, 6, 0, 70, 20, 70, 0, 0, 0, C["stone"], "Brick", NC),
        part("B", 0, 18, 0, 56, 6, 56, 0, 45, 0, C["brass"], "Metal", NC),
        part("B", 0, 80, 0, 34, 120, 34, 0, 0, 0, "#e9e0cc", "Plastic", NC),
        part("B", 0, 80, 0, 30, 118, 30, 0, 45, 0, C["paleBlue"], "Plastic", NC),
        part("B", 0, 141, 0, 38, 2.4, 38, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, 182, 0, 22, 80, 22, 0, 45, 0, "#e9e0cc", "Plastic", NC),
        part("B", 0, 182, 0, 18, 78, 18, 0, 0, 0, C["teal"], "DiamondPlate", NC),
        part("B", 0, 223, 0, 26, 2.0, 26, 0, 45, 0, C["brass"], "Metal", NC),
        part("K", 0, 254, 0, 18, 60, 18, 0, 0, 0, C["brassLight"], "Metal", nc({"n": 8})),
        part("S", 0, 288, 0, 6, 6, 6, 0, 0, 0, C["neonCyan"], "Neon", nc({"l": [60, 2.0, C["neonCyan"], False]})),
    ]
    for y in (40, 70, 100, 130, 160, 190, 210):
        w = 34.6 if y < 141 else 22.6
        parts.append(part("B", 0, y, 0, w, 1.2, w, 0, 0 if y < 141 else 45, 0, C["neonWarm"], "Neon", NC))
    seg = 16
    for k in range(seg):
        a = 2 * math.pi * k / seg
        rr = 38.0
        parts.append(part("B", rr * math.cos(a), 200, rr * math.sin(a), 2 * rr * math.sin(math.pi / seg) + 0.8, 3.0, 4.0,
                          0, -math.degrees(a) + 90, 0, C["brass"], "Metal", NC))
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        parts.append(part("B", 26 * math.cos(a), 200, 26 * math.sin(a), 22, 1.4, 1.4, 0, -math.degrees(a), 0,
                          C["steel"], "DiamondPlate", NC))
    return {"parts": parts}


# ---------------------------------------------------------------------------------------------- terrain grid
CELL = 10
TERRAIN_MARGIN = 380.0
CITY_EAST_OF_START = 300.0  # the plaza district reaches this far east of the start straight south of the viaduct


def plain_height(x: np.ndarray, z: np.ndarray) -> np.ndarray:
    lx, lz = x - ORIGIN[0], z - ORIGIN[2]
    return PLAIN_Y + 2.4 * np.sin(lx / 170.0) * np.cos(lz / 210.0) + 1.4 * np.sin((lx + lz) / 97.0)


# ------------------------------------------------------------------------------------------------------ sky
SKY_DIR = ROOT / "assets" / "sky" / "space4"
SKY_SIZE = 1024


def sky_colour(elev: np.ndarray) -> np.ndarray:
    """L61 night sky by elevation (degrees): near-black indigo zenith, deep violet mid sky, a magenta-violet glow of city
    light at the horizon (it meets the Atmosphere's violet haze without a seam), dark lunar ground below."""
    # below the horizon: the violet haze colour of the far plain, so a high camera sees no dark band past its edge
    keys = [(-90.0, (30, 24, 58)), (-12.0, (40, 30, 76)), (-2.0, (62, 40, 100)), (0.0, (96, 52, 128)),
            (2.0, (84, 48, 124)), (6.0, (56, 38, 108)), (14.0, (32, 28, 86)), (28.0, (17, 18, 58)),
            (50.0, (9, 11, 36)), (90.0, (5, 7, 24))]
    out = np.zeros(elev.shape + (3,))
    for (e0, c0), (e1, c1) in zip(keys, keys[1:]):
        m = (elev >= e0) & (elev <= e1)
        t = ((elev[m] - e0) / (e1 - e0))[:, None]
        t = t * t * (3 - 2 * t)
        out[m] = np.array(c0) + (np.array(c1) - np.array(c0)) * t
    return out


def periodic_noise(az: np.ndarray, el: np.ndarray, rng: np.random.Generator, octaves: int = 4) -> np.ndarray:
    """Smooth noise periodic in azimuth over the 90-degree face (all four sides share one image, so the left edge must
    meet the right edge)."""
    out = np.zeros_like(az)
    amp = 1.0
    for o in range(octaves):
        k = 2 ** o
        for _ in range(3):
            fa = rng.integers(1, 3) * k  # whole periods per face
            fe = rng.uniform(0.03, 0.07) * k
            ph1, ph2 = rng.uniform(0, 2 * math.pi, 2)
            out += amp * np.sin(az * (2 * math.pi / 90.0) * fa + ph1) * np.sin(el * fe + ph2)
        amp *= 0.5
    return out / 3.0


def _stars(img: np.ndarray, el: np.ndarray, rng: np.random.Generator, count: int, min_el: float) -> np.ndarray:
    """Point stars (1-3 px, a few with a soft halo), white to pale cyan/amber, fading into the horizon glow."""
    n = img.shape[0]
    ys = rng.integers(0, n, count)
    xs = rng.integers(0, n, count)
    mag = rng.random(count) ** 3.2  # mostly faint, a few bright
    tint = rng.choice(np.array([[255, 255, 255], [190, 226, 255], [255, 226, 190], [226, 200, 255]], float), count)
    for y, x, m, t in zip(ys, xs, mag, tint):
        e = el[y, x]
        if e < min_el:
            continue
        fade = min(1.0, (e - min_el) / 8.0)
        a = (0.35 + 0.65 * m) * fade
        img[y, x] = img[y, x] * (1 - a) + t * a
        if m > 0.55:
            for dy, dx in ((0, 1), (1, 0), (0, -1), (-1, 0)):
                yy, xx = y + dy, x + dx
                if 0 <= yy < n and 0 <= xx < n:
                    img[yy, xx] = img[yy, xx] * (1 - a * 0.45) + t * a * 0.45
    return img


def _skyline(img: np.ndarray, az: np.ndarray, el: np.ndarray, seed: int) -> np.ndarray:
    """A far neon city on the horizon, periodic over the face: dark violet silhouettes (setbacks and needles) with lit
    window dots, neon crown bands and red aircraft beacons."""
    for layer, (count, tone, hmin, hmax) in enumerate(((22, (34, 26, 62), 1.6, 4.8), (16, (22, 18, 44), 1.0, 3.2))):
        rng = random.Random(seed + layer)
        for _ in range(count):
            ac = rng.uniform(-45, 45)
            hw = rng.uniform(0.7, 2.4)
            top = rng.uniform(hmin, hmax)
            spire = rng.random() < 0.35
            neon = rng.choice(((89, 236, 255), (255, 92, 200), (255, 170, 60), (176, 110, 255)))
            for shift in (-90.0, 0.0, 90.0):
                da = np.abs(az - (ac + shift))
                body = (da < hw) & (el < top) & (el > -1.5)
                setback = (da < hw * 0.6) & (el < top + 0.8) & (el > -1.5)
                needle = (da < 0.1) & (el < top + 2.4) & (el > -1.5) if spire else np.zeros_like(body)
                m = body | setback | needle
                if not m.any():
                    continue
                img[m] = np.array(tone, float)
                # lit windows: a sparse grid inside the body
                win = body & (np.mod(np.floor((az - ac) * 7.0), 2) == 0) & (np.mod(np.floor(el * 9.0), 2) == 0)
                hashv = np.sin(np.floor((az - ac) * 7.0) * 12.9898 + np.floor(el * 9.0) * 78.233 + layer) * 43758.5453
                lit = win & ((hashv - np.floor(hashv)) < 0.35)
                img[lit] = np.array((255, 214, 140)) * 0.85 if layer == 0 else np.array((150, 200, 255)) * 0.7
                crown = body & (np.abs(el - (top - 0.25)) < 0.09)
                img[crown] = np.array(neon, float)
                if spire:
                    bea = (da < 0.16) & (np.abs(el - (top + 2.45)) < 0.14)
                    img[bea] = np.array((255, 70, 60), float)
    return img


def _planet(img: np.ndarray, U: np.ndarray, V: np.ndarray) -> np.ndarray:
    """A ringed gas giant low over the horizon (one face only): violet/teal bands lit from the left, a tilted brass
    ring system passing in front of and behind the disc, a soft atmospheric rim."""
    cx, cy, r = -0.16, 0.30, 0.34
    dx, dy = (U - cx) / r, (V - cy) / r
    d2 = dx * dx + dy * dy
    disc = d2 < 1.0
    # ring plane: tilted ellipse
    tilt = math.radians(-14)
    rx = dx * math.cos(tilt) - dy * math.sin(tilt)
    ry = dx * math.sin(tilt) + dy * math.cos(tilt)
    rr = np.sqrt(rx * rx + (ry / 0.24) ** 2)
    ring = ((rr > 1.28) & (rr < 1.62)) | ((rr > 1.68) & (rr < 1.95))
    ring_front = ring & (ry < 0)
    ring_back = ring & ~ring_front
    # rim glow behind everything
    glow = np.clip(1.0 - (np.sqrt(d2) - 1.0) / 0.12, 0, 1) * (d2 >= 1.0)
    img = img + glow[..., None] * np.array((60, 90, 160)) * 0.55
    ring_col = np.array((214, 176, 120), float)
    band_t = np.clip(rr - 1.28, 0, 1)
    ring_shade = (0.65 + 0.35 * np.sin(band_t * 40.0))[..., None]
    a_back = ring_back & ~disc
    img[a_back] = (img * 0.35 + ring_col * ring_shade * 0.65)[a_back]
    # disc: latitude bands, lit from upper-left, terminator to the lower right
    z = np.sqrt(np.clip(1 - d2, 0, 1))
    light = np.array((-0.62, 0.42, 0.66))
    light = light / np.linalg.norm(light)
    lam = np.clip(dx * light[0] + dy * light[1] + z * light[2], 0, 1)
    lat = dy + 0.06 * np.sin(dx * 9.0)
    bands = 0.5 + 0.5 * np.sin(lat * 15.0) * np.cos(lat * 4.0)
    c1, c2 = np.array((132, 92, 196), float), np.array((70, 168, 190), float)
    base = c1 * bands[..., None] + c2 * (1 - bands[..., None])
    shade = (0.08 + 0.92 * lam ** 0.8)[..., None]
    limb = (0.75 + 0.25 * z)[..., None]
    img[disc] = (base * shade * limb)[disc]
    # the ring's shadow on the disc and the front arc of the ring
    img[ring_front] = (img * 0.25 + ring_col * ring_shade * 0.8)[ring_front]
    return img


def write_earth(path: Path) -> None:
    """A small blue home planet (512 RGBA, transparent around it): oceans, soft continents and cloud swirls, lit from the
    right as a fat crescent with a cyan atmosphere rim. Used as the Sky's SunTextureId (the low 'earthlight')."""
    from PIL import Image

    n = 512
    c = (np.arange(n) + 0.5) / n * 2 - 1
    X, Y = np.meshgrid(c, -c)
    r = 0.80
    dx, dy = X / r, Y / r
    d2 = dx * dx + dy * dy
    disc = d2 < 1.0
    z = np.sqrt(np.clip(1 - d2, 0, 1))
    rng = np.random.default_rng(SEED + 31)

    def noise(fx: float, octs: int) -> np.ndarray:
        out = np.zeros_like(dx)
        amp = 1.0
        for o in range(octs):
            for _ in range(3):
                kx, ky, kz = rng.normal(0, fx * 2 ** o, 3)
                ph = rng.uniform(0, 2 * math.pi)
                out += amp * np.sin(dx * kx + dy * ky + z * kz + ph)
            amp *= 0.55
        return out

    land = np.clip((noise(1.6, 3) + 0.2) * 2.2, 0, 1)[..., None]  # soft coasts (a hard threshold aliased)
    cloud = np.clip((noise(2.4, 3) - 0.25) * 1.3, 0, 1)
    ocean = np.array((40, 104, 214), float)
    green = np.array((86, 170, 98), float)
    col = green * land + ocean * (1 - land)
    col = col * (1 - cloud[..., None] * 0.85) + np.array((246, 250, 255)) * cloud[..., None] * 0.85
    light = np.array((0.78, 0.22, 0.58))
    light = light / np.linalg.norm(light)
    lam = np.clip(dx * light[0] + dy * light[1] + z * light[2], 0, 1)
    shade = (0.04 + 0.96 * lam ** 0.7)[..., None]
    rgb = col * shade
    rim = np.clip(1 - z, 0, 1) ** 2.2
    rgb = rgb + (rim * lam * 0.9 + rim * 0.12)[..., None] * np.array((110, 200, 255))
    alpha = np.where(disc, 255.0, 0.0)
    halo = np.clip(1.0 - (np.sqrt(d2) - 1.0) / 0.08, 0, 1) * (~disc)
    rgb = np.where(disc[..., None], rgb, np.array((110, 200, 255)) * 0.9)
    alpha = np.where(disc, alpha, halo * 150.0)
    out = np.concatenate([np.clip(rgb, 0, 255), alpha[..., None]], axis=-1).astype(np.uint8)
    Image.fromarray(out, "RGBA").save(path, optimize=False)


def write_sky() -> list[str]:
    """assets/sky/space4/{up,side,planet,down,earth}.png. Colour comes from each pixel's true elevation on the cube, so
    the faces meet without seams; the side faces add a far neon skyline (periodic over 90 degrees), a faint violet/teal
    nebula band and stars; `planet` is the side face plus a ringed gas giant (LightingProfiles puts it on one face);
    `earth` is the home planet the Sky shows as its sun. Deterministic (fixed seeds)."""
    from PIL import Image

    SKY_DIR.mkdir(parents=True, exist_ok=True)
    n = SKY_SIZE
    c = (np.arange(n) + 0.5) / n * 2 - 1
    U, V = np.meshgrid(c, -c)  # row 0 = top of the image
    rng = np.random.default_rng(SEED + 10)
    written = []

    # side: direction (u, v, 1)
    el = np.degrees(np.arctan2(V, np.sqrt(U * U + 1)))
    az = np.degrees(np.arctan(U))
    img = sky_colour(el)
    neb = periodic_noise(az, el, rng, octaves=5)
    neb2 = periodic_noise(az, el, rng, octaves=4)
    band = np.clip((el - 4) / 8, 0, 1) * np.clip((30 - el) / 10, 0, 1)
    a1 = np.clip((neb - 0.05) * 1.1, 0, 1) * band * 0.38
    a2 = np.clip((neb2 - 0.15) * 1.1, 0, 1) * band * 0.26
    img = img * (1 - a1[..., None]) + np.array((126, 64, 170)) * a1[..., None]
    img = img * (1 - a2[..., None]) + np.array((40, 120, 150)) * a2[..., None]
    img = _stars(img, el, rng, 2600, 3.0)
    img = _skyline(img, az, el, SEED + 20)
    base_side = img.copy()
    grain = rng.normal(0, 1.4, img.shape[:2])[..., None]
    Image.fromarray(np.clip(img + grain, 0, 255).astype(np.uint8), "RGB").save(SKY_DIR / "side.png", optimize=False)
    written.append("side.png")
    planet = _planet(base_side.copy(), U, V)
    planet = _skyline(planet, az, el, SEED + 20)  # the far city stands in front of the planet
    Image.fromarray(np.clip(planet + grain, 0, 255).astype(np.uint8), "RGB").save(SKY_DIR / "planet.png", optimize=False)
    written.append("planet.png")

    # up: direction (u, 1, v); down: (u, -1, v)
    el_up = np.degrees(np.arctan2(1.0, np.sqrt(U * U + V * V)))
    for name, el_face in (("up", el_up), ("down", -el_up)):
        img = sky_colour(el_face)
        if name == "up":
            img = _stars(img, el_face, rng, 3400, 0.0)
        grain = rng.normal(0, 1.2, img.shape[:2])[..., None]
        img = np.clip(img + grain, 0, 255).astype(np.uint8)
        Image.fromarray(img, "RGB").save(SKY_DIR / f"{name}.png", optimize=False)
        written.append(f"{name}.png")
    write_earth(SKY_DIR / "earth.png")
    written.append("earth.png")
    # earthface: the side face with the home planet rising over the far city (LightingProfiles puts it on the north
    # face, behind the viaduct in the start view); composited from earth.png so both stay in step
    from PIL import Image as _I
    e = np.asarray(_I.open(SKY_DIR / "earth.png").convert("RGBA"), float)
    face = base_side.copy()
    size = int(n * 0.36)
    e = np.asarray(_I.fromarray(e.astype(np.uint8), "RGBA").resize((size, size), _I.LANCZOS), float)
    cx, cy = int(n * 0.60), int(n * 0.30)
    y0, x0 = cy - size // 2, cx - size // 2
    a = e[..., 3:4] / 255.0
    face[y0:y0 + size, x0:x0 + size] = face[y0:y0 + size, x0:x0 + size] * (1 - a) + e[..., :3] * a
    face = _skyline(face, az, el, SEED + 20)
    grain = rng.normal(0, 1.4, face.shape[:2])[..., None]
    _I.fromarray(np.clip(face + grain, 0, 255).astype(np.uint8), "RGB").save(SKY_DIR / "earthface.png", optimize=False)
    written.append("earthface.png")
    return written

# ------------------------------------------------------------------------------------------- set dressing (L61)
# The uploaded SPACE props (src/shared/PropLibrary.luau, MapAdapter step 7b) stand outside the parapets: clusters on
# the outside of every turn, a loose line along the at-grade road edges, glowing crystal groves in the crater bowls,
# tech yards on the plazas and rock/crystal scatter on the open plain. Every whole AABB (yawed footprint from below the
# ground up to SNAP_RISE + its height, plus PROP_MARGIN) is tested against the compile gate's corridor boxes; nothing
# stands within the Alt1 aprons, on the mesa, in the rift, under the viaduct or on a tower podium.
SNAP_RISE = 10.0
PROP_MARGIN = 4.0


def prop_library(zone: str = "SPACE") -> dict:
    """{key: (sx, sy, sz, collide)} of the uploaded props of a zone in src/shared/PropLibrary.luau (skips model = nil)."""
    import re
    src = (ROOT / "src" / "shared" / "PropLibrary.luau").read_text()
    out = {}
    for m in re.finditer(r"\n\t(\w+) = \{(.*?)\n\t\},", src, re.S):
        body = m.group(2)
        if f'zone = "{zone}"' not in body or re.search(r"model = nil", body):
            continue
        sz = re.search(r"size = Vector3\.new\(([\d.]+), ([\d.]+), ([\d.]+)\)", body)
        out[m.group(1)] = (float(sz.group(1)), float(sz.group(2)), float(sz.group(3)), "collide = true" in body)
    return out


def prop_aabb(size, pos, yaw: float, scale: float):
    """World AABB (centre, half) a placement may occupy: yawed footprint, from 4 below pos up to SNAP_RISE + height."""
    sx, sy, sz = (v * scale for v in size[:3])
    c, s_ = abs(math.cos(math.radians(yaw))), abs(math.sin(math.radians(yaw)))
    hx, hz = 0.5 * (sx * c + sz * s_), 0.5 * (sx * s_ + sz * c)
    lo, hi = pos[1] - 4.0, pos[1] + SNAP_RISE + sy
    return np.array([pos[0], (lo + hi) / 2, pos[2]]), np.array([hx, (hi - lo) / 2, hz])


def corridor_hits(wps, centres: np.ndarray, halves: np.ndarray, margin: float = 0.0) -> np.ndarray:
    out = np.zeros(len(centres), bool)
    if len(centres) == 0:
        return out
    reach = np.linalg.norm(halves, axis=1).max() + 140.0
    for i in range(len(wps) - 1):
        b = adapt.segment_box(wps[i].pos, wps[i + 1].pos, CORRIDOR["halfWidth"], CORRIDOR["floor"], CORRIDOR["ceiling"])
        if b is None:
            continue
        mid, axes, half = b
        near = np.linalg.norm(centres - mid, axis=1) < reach
        idx = np.nonzero(near & ~out)[0]
        if idx.size == 0:
            continue
        h = adapt.aabbs_hit_obb(centres[idx], halves[idx] + margin, mid, axes, half)
        out[idx[h]] = True
    return out


def fx_texture(name: str) -> str:
    """rbxassetid of an owned particle texture (src/shared/VfxAssets.luau or the flip set in VfxFlipAssets.luau)."""
    import re
    m = re.search(name + r' = \{ id = "(rbxassetid://\d+)"', (ROOT / "src" / "shared" / "VfxAssets.luau").read_text())
    if not m:
        m = re.search(name + r' = "(rbxassetid://\d+)"', (ROOT / "src" / "shared" / "VfxFlipAssets.luau").read_text())
    assert m, name
    return m.group(1)


def cf_at(x: float, y: float, z: float) -> list:
    return [r2(x), r2(y), r2(z), 1, 0, 0, 0, 1, 0, 0, 0, 1]


LAYOUT_OUT = ROOT / "src" / "shared" / "SpaceNeonLayout.luau"


def write_layout(neon: dict) -> None:
    """src/shared/SpaceNeonLayout.luau: world placements of the hologram figures and billboards (generated)."""
    def v3(p) -> str:
        return "Vector3.new(%s, %s, %s)" % tuple(("%g" % c) for c in p)
    lines = ["--!strict",
             "-- GENERATED by tools/map/author_space4.py (write_layout); do not edit. SPACE-4 hologram figures and billboards:",
             "-- world placements (plan view clear of the race line by shared/SpaceNeonRules.reach + HOLO_CLEAR), built at",
             "-- runtime by client/SpaceNeon.",
             "local Layout = {}", "",
             "Layout.holograms = {"]
    for h in neon["holograms"]:
        lines.append("	{ pos = %s, yaw = %g, height = %g, lean = %g, palette = %d, phase = %g }," %
                     (v3(h["pos"]), h["yaw"], h["h"], h["lean"], h["palette"], h["phase"]))
    lines += ["}", "", "Layout.billboards = {"]
    for b in neon["billboards"]:
        lines.append("	{ pos = %s, yaw = %g, width = %g, height = %g, palette = %d, text = %d }," %
                     (v3(b["pos"]), b["yaw"], b["w"], b["h"], b["palette"], b["text"]))
    lines += ["}", "", "return Layout", ""]
    LAYOUT_OUT.write_text("\n".join(lines))


# ------------------------------------------------------------------------------- rooftop shortcut (SPACE-4 signature)
# TRACK_VARIETY 5a, SPACE-4 launch upgrade: a rooftop wall-climb shortcut between two grid blocks with a lit tell. Geometry
# lives in tools/map/space4_rooftop.py (pure); this section anchors it to the route, builds its prefabs and instances and
# keeps the rest of the map clear of it. Static map data: ROOFTOP_SHORTCUT = False restores the previous plan exactly.
ROOFTOP_SHORTCUT = True
RT_ENTRY_ST = 922.0  # north1 straight (bank 0 from st 920 to 1015): the slip lane starts here, right of the road
RT_EXIT_ST = 1700.0  # north2 straight (bank 0): the lane that merges back runs left of the road, to RT_EXIT_ST + RT_EXTEND
RT_LEAD = 85.0  # straight lead along the road before the line turns away / after it turns back (plan corner distance)
WALL_JOIN_D = 28.5  # wall centre distance from the route axis where a lane wall meets the parapet (face 27.5 + the wall's own half thickness 1)
RT_EXTEND = 66.0  # the merge lane runs this far past RT_EXIT_ST, closed by a funnel wall that meets the parapet
RT_CLIMB_LEN = 56.0
RT_DESCENT_LEN = 130.0
RT_BLOCK_NAMES = ("RooftopBlockA", "RooftopBlockB")
RT_PALETTE = (3, 0)  # PAL rows of the two blocks (v29 A11: terracotta and cream stone; were violet and navy glass)
RT_FOOT_R = 34.0  # footprint circle radius (support half width 14 + slack) used to keep towers and props clear
RT_HOLO_CLEAR = 40.0  # plan distance kept between the line (outer wall face) and any hologram part
RT_BOARD_CLEAR = 30.0  # ... and any billboard face
RT_HALF_OUTER = 16.0  # line axis to the outer face of its walls
RT_DECK_COLOUR = "#7b82a8"  # lighter than the first cut (#2b3047): the car and the road read at night (Studio V7A L2r2_004)
RT_LAMP_STEP = 36.0  # roof lamps (MapLight neon posts on the wall caps), alternating sides
RT_LAMP_RANGE = 46
RT_LAMP_BRIGHT = 2.4
RT_SUPPORT_COLOUR = ("#3b3f63", "#2f3858")


class RoofPlan:
    """Everything the rest of build() needs to know about the line before any prefab exists."""

    def __init__(self):
        self.line = None
        self.vs = []
        self.xz = []  # centreline plan samples
        self.open_ranges = {-1.0: [], 1.0: []}  # station ranges where the road parapet is open, per road side
        self.keep_out = []  # station ranges (both sides) kept clear of lamps, arches and gantries
        self.footprints = []  # (x, z, r)
        self.blocks = []  # (name, s0, s1)
        self.bridge = (0.0, 0.0)
        self.left_wall = (0.0, 0.0)
        self.right_wall = (0.0, 0.0)
        self.stats = {}

    def dist(self, x: float, z: float) -> float:
        """Plan distance from (x, z) to the line's centre polyline (inf when the line is off)."""
        if not self.xz:
            return math.inf
        p = np.array(self.xz, float)
        a, b = p[:-1], p[1:]
        ab = b - a
        t = np.clip(((x - a[:, 0]) * ab[:, 0] + (z - a[:, 1]) * ab[:, 1]) / np.maximum(1e-9, ab[:, 0] ** 2 + ab[:, 1] ** 2), 0, 1)
        return float(np.min(np.hypot(a[:, 0] + ab[:, 0] * t - x, a[:, 1] + ab[:, 1] * t - z)))


def rooftop_plan(route: routelib.Route, poly: "Poly") -> RoofPlan:
    import space4_rooftop as RT
    rp = RoofPlan()
    if not ROOFTOP_SHORTCUT:
        return rp
    f_in, f_out = route.frame_at(RT_ENTRY_ST), route.frame_at(RT_EXIT_ST)
    v0 = offset_point(route, RT_ENTRY_ST, RT.LANE_LATERAL, 0.0)
    v3 = offset_point(route, RT_EXIT_ST + RT_EXTEND, -RT.LANE_LATERAL, 0.0)
    tin = routelib.unit((f_in.tangent[0], 0.0, f_in.tangent[2]))
    tout = routelib.unit((f_out.tangent[0], 0.0, f_out.tangent[2]))
    v1 = (v0[0] + tin[0] * RT_LEAD, v0[2] + tin[2] * RT_LEAD)
    v2 = (v3[0] - tout[0] * (RT_LEAD + RT_EXTEND), v3[2] - tout[2] * (RT_LEAD + RT_EXTEND))
    vs = [(v0[0], v0[2]), v1, v2, (v3[0], v3[2])]
    xz = RT.fillet_path(vs, RT.FILLET_R, RT.STEP)
    cum = [0.0]
    for a, b in zip(xz, xz[1:]):
        cum.append(cum[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    d_route = [poly.nearest(x, z)[0] for x, z in xz]
    i_cross = int(np.argmin(d_route[len(xz) // 5:-len(xz) // 5])) + len(xz) // 5
    s_cross = cum[i_cross]

    def corners_clear(i: int) -> bool:
        x, z = xz[i]
        q = xz[min(i + 1, len(xz) - 1)]
        r = xz[max(i - 1, 0)]
        h = RT.unit2((q[0] - r[0], q[1] - r[1]))
        rgt = (-h[1], h[0])
        for sgn in (-1.0, 1.0):
            for along in (-RT.STEP, RT.STEP):  # the run's end face spans one sample either side
                cx = x + rgt[0] * sgn * RT.SUPPORT_W / 2 + h[0] * along
                cz = z + rgt[1] * sgn * RT.SUPPORT_W / 2 + h[1] * along
                if poly.nearest(cx, cz)[0] < RT.SUPPORT_CLEAR:
                    return False
        return True

    i_a = i_cross
    while i_a > 0 and not corners_clear(i_a):
        i_a -= 1
    i_b = i_cross
    while i_b < len(xz) - 1 and not corners_clear(i_b):
        i_b += 1
    s_a1, s_b0 = cum[i_a], cum[i_b]  # block A ends / block B starts; the span between them is the bridge
    ribbon_max = max(poly.nearest(xz[i][0], xz[i][1])[2] for i in range(i_a, i_b + 1))
    roof_y = ribbon_max + CORRIDOR["ceiling"] + RT.CLEAR_OVER_CORRIDOR + RT.DECK_T

    def road_y(x: float, z: float) -> float:
        return poly.nearest(x, z)[2] + PAVER_TOP

    climb_from = s_a1 - 34.0 - RT_CLIMB_LEN
    descent_from = s_b0 + 14.0
    line = RT.build_line(vs, road_y, roof_y, climb_from, RT_CLIMB_LEN, descent_from, RT_DESCENT_LEN)
    line.bridge = (s_a1, s_b0)
    rp.line, rp.vs, rp.xz = line, vs, xz
    rp.bridge = (s_a1, s_b0)
    rp.blocks = [(RT_BLOCK_NAMES[0], line.climb[0] - 12.0, s_a1), (RT_BLOCK_NAMES[1], s_b0, line.descent[1] + 6.0)]

    # walls: the road side of each lane stays open (an on-ramp and an off-ramp), the far side is closed from the start
    def edge_far(i: int, sgn: float, lateral: float) -> float:
        x, z = xz[i]
        q = xz[min(i + 1, len(xz) - 1)]
        r = xz[max(i - 1, 0)]
        h = RT.unit2((q[0] - r[0], q[1] - r[1]))
        rgt = (-h[1], h[0])
        return poly.nearest(x + rgt[0] * sgn * lateral, z + rgt[1] * sgn * lateral)[0]

    # left wall (road on the left at the entry): starts where its road-side face meets the resumed parapet (the wedge
    # between them is closed at its apex and unreachable from the road and from the lane)
    i_lw = next(i for i in range(len(xz)) if edge_far(i, -1.0, RT.WALL_LATERAL) >= WALL_JOIN_D)
    # right wall (road on the right at the exit): ends where its road-side face meets the parapet that is removed from there
    i_rw = max(i for i in range(len(xz)) if edge_far(i, 1.0, RT.WALL_LATERAL) >= WALL_JOIN_D)
    rp.left_wall = (cum[i_lw], cum[-1])
    rp.right_wall = (0.0, cum[i_rw])

    # parapet openings (stations on the route): entry on the right side, exit on the left side
    st_lw = poly.nearest(*xz[i_lw])[1]
    st_rw = poly.nearest(*xz[i_rw])[1]
    rp.open_ranges[1.0] = [(RT_ENTRY_ST - 0.5, st_lw)]
    rp.open_ranges[-1.0] = [(st_rw, RT_EXIT_ST + RT_EXTEND - 1.0)]
    rp.keep_out = [(RT_ENTRY_ST - 30.0, st_lw + 14.0), (st_rw - 40.0, RT_EXIT_ST + RT_EXTEND + 40.0)]
    # the bridge crosses the road: no arch or gantry may stand in its span
    sa = poly.nearest(*xz[i_a])[1]
    sb = poly.nearest(*xz[i_b])[1]
    lo, hi = sorted((sa, sb))
    rp.keep_out.append((lo - 70.0, hi + 70.0))
    for i in range(0, len(xz), 2):
        rp.footprints.append((xz[i][0], xz[i][1], RT_FOOT_R))
    rp.stats = {"length": round(cum[-1], 1), "routeSaved": round((RT_EXIT_ST + RT_EXTEND - RT_ENTRY_ST) - cum[-1], 1),
                "roofY": r2(roof_y), "climbPeakDeg": round(line.climb_peak, 2), "descentPeakDeg": round(line.descent_peak, 2),
                "crossingS": round(s_cross, 1), "bridgeS": [round(s_a1, 1), round(s_b0, 1)],
                "bridgeStations": [round(lo, 1), round(hi, 1)]}
    return rp


def RT_MAX_FACE_DEG() -> float:
    import space4_rooftop as RT
    return RT.MAX_FACE_DEG


def _rt_hr(sm) -> tuple[float, float]:
    """Horizontal right of the line at a sample (heading (dx, dz) -> (-dz, dx), as the turtle)."""
    return (-sm.yaw_dz, sm.yaw_dx)


def rooftop_emit(rp: RoofPlan, route: routelib.Route, prefabs: dict, place) -> dict:
    """Prefabs and instances of the rooftop line; returns the numbers the plan, the Alt2 record and the tests need."""
    import space4_rooftop as RT
    ss = rp.line.samples
    n = len(ss)
    up = (0.0, 1.0, 0.0)

    def pt(i: int, lat: float = 0.0, dy: float = 0.0) -> tuple:
        hr = _rt_hr(ss[i])
        return (ss[i].x + hr[0] * lat, ss[i].y + dy, ss[i].z + hr[1] * lat)

    def box_axes(a: tuple, b: tuple) -> tuple[list, tuple, float]:
        look = routelib.unit(routelib.sub(b, a))
        right = routelib.unit(routelib.cross(look, up))
        up2 = routelib.unit(routelib.cross(right, look))
        return yxz_from_axes(right, up2, look), routelib.mul(routelib.add(a, b), 0.5), routelib.mag(routelib.sub(b, a))

    def uphill_axes(u_h: tuple) -> list:
        """Wedge frame: local +z = the horizontal uphill direction u_h (the wedge's full-height back face), +y up."""
        look = (-u_h[0], 0.0, -u_h[1])
        right = routelib.unit(routelib.cross(look, up))
        return yxz_from_axes(right, up, look)

    def deck_prefab(length: float) -> dict:
        return {"parts": [part("B", 0, -RT.DECK_T / 2, 0, RT.DECK_W, RT.DECK_T, length, 0, 0, 0, RT_DECK_COLOUR, "Slate")]}

    def wall_prefab(length: float) -> dict:
        # v28 critic 1.16 (capture space4_01: a full neon wall face): plum metal wall, cream stone cap, thin inset line
        return {"parts": [
            part("B", 0, RT.WALL_H / 2, 0, RT.WALL_T, RT.WALL_H, length, 0, 0, 0, C["plumWall"], "DiamondPlate"),
            part("B", 0, RT.WALL_H + 0.35, 0, 2.6, 0.7, length, 0, 0, 0, C["capStone"], "Brick", NC)]
            + inset_line(length, RT.WALL_H + 0.35, 2.6)}

    # ---- collidable pieces: deck slabs and walls, split like the parapets until none reaches the corridor boxes
    recs: list[dict] = []
    for i in range(n - 1):
        recs.append({"fam": "RooftopDeck", "a": pt(i), "b": pt(i + 1), "s": ss[i].s})

    def wall_line(side: float, s0: float, s1: float, lat_fn) -> None:
        idx = [i for i in range(n) if s0 - 1e-6 <= ss[i].s <= s1 + 1e-6]
        for i, j in zip(idx, idx[1:]):
            a = pt(i, side * lat_fn(ss[i].s), RT.WALL_H * 0.0)
            b = pt(j, side * lat_fn(ss[j].s), RT.WALL_H * 0.0)
            recs.append({"fam": "RooftopWall", "a": a, "b": b, "s": ss[i].s, "side": side})

    flare_len = 12.0
    s_end = ss[-1].s
    f0 = s_end - RT_EXTEND

    def right_lat(s: float) -> float:  # outer wall at the entry: flares out over its first 12 studs
        return RT.WALL_LATERAL + 3.2 * max(0.0, 1.0 - s / flare_len)

    def left_lat(s: float) -> float:  # outer wall at the exit closes onto the parapet line over the last RT_EXTEND studs;
        # at its start (entry side) it flares out toward the road
        out = 0.0  # the wall's start meets the resumed parapet: no flare
        k = max(0.0, (s - f0) / RT_EXTEND)
        # the parapet centre is 9.8 studs to the road side of the lane axis (36 - 26.2)
        return (RT.WALL_LATERAL + out) * (1.0 - k) + (-(RT.LANE_LATERAL - WALL_LATERAL)) * k

    wall_line(1.0, rp.right_wall[0], rp.right_wall[1], right_lat)
    wall_line(-1.0, rp.left_wall[0], rp.left_wall[1], left_lat)

    def merge_straight(rs: list[dict], max_len: float = 30.0) -> list[dict]:
        """Neighbouring pieces of one family that lie on one straight line (flat roof, straight lane, the funnel) become
        one longer piece: fewer joints for a wall ray to meet, fewer parts."""
        out_: list[dict] = []
        for rc in rs:
            if out_ and out_[-1]["fam"] == rc["fam"] and out_[-1].get("side") == rc.get("side") and out_[-1].get("idx") == rc.get("idx") and \
                    routelib.mag(routelib.sub(out_[-1]["b"], rc["a"])) < 1e-6:
                prev = out_[-1]
                a, b = prev["a"], rc["b"]
                ab = routelib.sub(b, a)
                ln = routelib.mag(ab)
                mid = prev["b"]
                t = routelib.dot(routelib.sub(mid, a), ab) / (ln * ln)
                off = routelib.mag(routelib.sub(routelib.sub(mid, a), routelib.mul(ab, t)))
                if ln <= max_len and off < 0.04:
                    out_[-1] = dict(prev, b=rc["b"])
                    continue
            out_.append(dict(rc))
        return out_

    recs = merge_straight(recs)

    def make_inst(rc: dict) -> tuple[str, dict, tuple, list]:
        r, p, ln = box_axes(rc["a"], rc["b"])
        q = bucket(ln + 0.4)
        key = "%s#%05.2f" % (rc["fam"], q)
        return key, (deck_prefab(q) if rc["fam"] == "RooftopDeck" else wall_prefab(q)), p, r

    for _ in range(10):
        tmp_pf, tmp_inst = {}, []
        for rc in recs:
            key, pf, p, r = make_inst(rc)
            tmp_pf.setdefault(key, pf)
            tmp_inst.append({"pf": key, "p": [r4(v) for v in p], "g": 1, "r": r})
        rep = adapt.Report()
        res = adapt.corridor_gate({"prefabs": tmp_pf, "instances": tmp_inst}, {"flight": {"corridor": CORRIDOR}}, route, rep)
        bad = {m["instance"] - 1 for m in res["intrusions"]}
        if not bad:
            break
        nxt = []
        for i, rc in enumerate(recs):
            if i in bad:
                mid = routelib.mul(routelib.add(rc["a"], rc["b"]), 0.5)
                nxt += [dict(rc, b=mid), dict(rc, a=mid)]
            else:
                nxt.append(rc)
        recs = nxt
    assert not bad, f"rooftop pieces still in the corridor: {len(bad)}"
    for rc in recs:
        key, pf, p, r = make_inst(rc)
        prefabs.setdefault(key, pf)
        place(key, p, "Highway/RooftopLine", r)
    out = {"deckPieces": sum(1 for rc in recs if rc["fam"] == "RooftopDeck"),
           "wallPieces": sum(1 for rc in recs if rc["fam"] == "RooftopWall"), "recs": recs}

    # ---- neon: edge strips and up-slope chevrons on the surface, all nc
    nc_parts = 0
    edges: list[dict] = []
    for i in range(n - 1):
        for side in (-1.0, 1.0):
            idx, col = tron_colour(side, ss[i].s)
            edges.append({"fam": "RooftopEdge", "side": side, "idx": idx, "col": col,
                          "a": pt(i, side * (RT.DECK_W / 2 - 1.7), 0.14), "b": pt(i + 1, side * (RT.DECK_W / 2 - 1.7), 0.14)})
    # merge each side separately (they interleave in the list above)
    merged: list[dict] = []
    for side in (-1.0, 1.0):
        merged += merge_straight([e for e in edges if e["side"] == side], 48.0)
    for e in merged:
        r, p, ln = box_axes(e["a"], e["b"])
        q = bucket(ln + 0.3)
        key = "RooftopEdge_%d#%05.2f" % (e["idx"], q)
        prefabs.setdefault(key, {"parts": [part("B", 0, 0, 0, 1.5, 0.2, q, 0, 0, 0, e["col"], "Neon", NC)]})
        place(key, p, "Highway/RooftopLine", r)
        nc_parts += 1
    c0, c1 = rp.line.climb
    face_k = 0
    for i in range(n - 1):
        s_i = ss[i].s
        on_face = c0 - 2.0 <= s_i <= c1 + 2.0
        on_lane = s_i < 80.0 or s_i > s_end - 130.0
        on_roof_run = c1 + 2.0 < s_i < rp.line.descent[1] - 20.0  # roof, bridge and the upper descent: a chevron every 24 studs
        if not (on_face or on_lane or on_roof_run):
            continue
        if on_lane and not on_face and int(round(s_i / RT.STEP)) % 2:
            continue
        if on_roof_run and not on_face and not on_lane:
            if int(round(s_i / RT.STEP)) % 4:
                continue
        if on_face:  # the whole synthwave ladder up the face, pink at the foot to orange at the lip
            idx = (face_k * len(TRON_PALETTE)) // max(1, int((c1 - c0) / RT.STEP) + 2)
            idx = min(idx, len(TRON_PALETTE) - 1)
            face_k += 1
        elif on_roof_run and not on_lane:
            idx = 0 if int(round(s_i / (4 * RT.STEP))) % 2 else 4
        else:  # the lanes alternate hot pink and cyan every other chevron
            idx = 0 if int(round(s_i / (2 * RT.STEP))) % 2 else 4
        col = TRON_PALETTE[idx]
        key = "RooftopChevron_%d" % idx
        if key not in prefabs:
            bars = []
            for sgn in (-1, 1):
                # local -z is the way the car drives: the tip is at the front (-z) and each arm trails back (+z) and out.
                # A bar yawed ry has its long axis along (sin ry, cos ry) in (x, z), so the left arm (x < 0) takes ry < 0.
                bars.append(part("B", sgn * 2.8, 0, 0, 0.9, 0.14, 8.4, 0, sgn * 42, 0, col, "Neon", NC))
                bars.append(part("B", sgn * 2.8, 0, -6.0, 0.9, 0.14, 8.4, 0, sgn * 42, 0, col, "Neon", NC))
            prefabs[key] = {"parts": bars}
        a, b = pt(i, 0.0, 0.11), pt(i + 1, 0.0, 0.11)
        look = routelib.unit(routelib.sub(b, a))
        right = routelib.unit(routelib.cross(look, up))
        up2 = routelib.unit(routelib.cross(right, look))
        place(key, a, "Highway/RooftopLine", yxz_from_axes(right, up2, look))
        nc_parts += 4

    # ---- roof lamps: a neon lens set flush into each wall cap (its top 0.02 over the cap's), each with one MapLight
    # that LightLod caps. Nothing stands on the cap: the car's ground probes count visible nc parts as road
    # (CarController groundParams.RespectCanCollide = false), so a post on the cap would add wall surface to climb
    # onto; the lens keeps the wall's profile as it was (owner rule: walls and climbing untouched).
    lamp_n = 0
    lamp_s = rp.line.climb[1] + 8.0
    cap_top = RT.WALL_H + 0.7  # the wall prefab's neon cap: centre WALL_H + 0.35, 0.7 tall
    while lamp_s < rp.line.descent[0] + 40.0:
        i = min(range(n - 1), key=lambda j: abs(ss[j].s - lamp_s))
        side = 1.0 if lamp_n % 2 == 0 else -1.0
        idx = 0 if lamp_n % 2 == 0 else 4
        col = TRON_PALETTE[idx]
        key = "RooftopLamp_%d" % idx
        prefabs.setdefault(key, {"parts": [
            part("B", 0, -0.13, 0, 1.2, 0.3, 3.0, 0, 0, 0, col, "Neon", nc({"l": [RT_LAMP_RANGE, RT_LAMP_BRIGHT, col, False]}))]})
        a, b = pt(i, side * RT.WALL_LATERAL), pt(i + 1, side * RT.WALL_LATERAL)
        look = routelib.unit(routelib.sub(b, a))
        right = routelib.unit(routelib.cross(look, up))
        up2 = routelib.unit(routelib.cross(right, look))
        place(key, routelib.add(routelib.mul(routelib.add(a, b), 0.5), routelib.mul(up2, cap_top)), "Highway/RooftopLine",
              yxz_from_axes(right, up2, look))
        lamp_n += 1
        nc_parts += 1
        lamp_s += RT_LAMP_STEP
    out["lampPieces"] = lamp_n

    # ---- the lit tell: three arches over the slip lane, each topped by up chevrons, the middle one with a MapLight keystone
    def tell_arch_prefab(col: str, lit: bool) -> dict:
        half, h = 13.0, 22.0
        parts = [part("B", sgn * half, h / 2, 0, 1.2, h, 1.2, 0, 0, 0, col, "Neon", NC) for sgn in (-1, 1)]
        parts.append(part("B", 0, h, 0, 2 * half + 1.2, 1.2, 1.2, 0, 0, 0, col, "Neon", NC))
        for dz, sc in ((0.0, 1.0), (-2.6, 0.8)):  # two up chevrons on the lintel
            for sgn in (-1, 1):
                # a ^: each arm leans in toward the axis at the top
                parts.append(part("B", sgn * 1.8 * sc, h + 3.2 * sc, dz, 0.9, 5.6 * sc, 0.9, 0, 0, sgn * 38, col, "Neon", NC))
        if lit:
            parts.append(part("B", 0, h + 0.9, 0, 2.2, 0.6, 2.2, 0, 0, 0, col, "Neon", nc({"l": [70, 1.5, col, False]})))
        return {"parts": parts}

    arch_n = 0
    for k, s_arch in enumerate((16.0, 46.0, 76.0)):
        i = min(range(n), key=lambda j: abs(ss[j].s - s_arch))
        idx, col = tron_colour(1.0, ss[i].s + 150.0 * k)
        key = "RooftopTellArch%s_%d" % ("Lit" if k == 1 else "", idx)
        prefabs.setdefault(key, tell_arch_prefab(col, k == 1))
        hr = _rt_hr(ss[i])
        place(key, pt(i), "Highway/RooftopLine",
              yxz_from_axes((hr[0], 0.0, hr[1]), up, (ss[i].yaw_dx, 0.0, ss[i].yaw_dz)))
        arch_n += 1
        nc_parts += len(prefabs[key]["parts"])
    out["archPieces"] = arch_n
    out["ncParts"] = nc_parts
    return out


def rooftop_supports(rp: RoofPlan, prefabs: dict, place) -> dict:
    """The two grid blocks under the climb, the roof and the descent, and pier pairs under the slip lanes (all nc: the
    car only meets the slabs and walls). Per 6-stud interval a box reaches from y=0 to the slab's underside and, on a
    slope, a wedge fills the rise, so the underside is solid and seamless."""
    import space4_rooftop as RT
    ss = rp.line.samples
    n = len(ss)
    up = (0.0, 1.0, 0.0)
    c0 = rp.line.climb[0]
    d1 = rp.line.descent[1]
    s_a1, s_b0 = rp.bridge
    runs = [(RT_BLOCK_NAMES[0], c0 - 12.0, s_a1, 0), (RT_BLOCK_NAMES[1], s_b0, d1 + 6.0, 1)]
    parts_n = 0
    podium_h = 14.0
    bands_y = (30.0, 54.0, 78.0)

    def horiz(a, b):
        return math.hypot(b.x - a.x, b.z - a.z)

    def yaw_axes(dx: float, dz: float) -> list:
        h = routelib.unit((dx, 0.0, dz))
        return yxz_from_axes(routelib.unit(routelib.cross(h, up)), up, h)

    def put(key: str, pf: dict, p: tuple, r) -> None:
        prefabs.setdefault(key, pf)
        place(key, p, "Highway/RooftopLine", r)

    def seg_height(i: int) -> tuple[float, float]:
        a, b = ss[i], ss[i + 1]
        pitch = math.atan2(b.y - a.y, horiz(a, b))
        return min(a.y, b.y) - RT.DECK_T / math.cos(pitch) + 0.4, abs(b.y - a.y)

    for name, r0, r1, bi in runs:
        shaft = RT_SUPPORT_COLOUR[bi]
        pal = PAL[RT_PALETTE[bi]]
        idxs = [i for i in range(n - 1) if r0 - 1e-6 <= ss[i].s and ss[i + 1].s <= r1 + 1e-6]
        k = 0
        while k < len(idxs):
            i = idxs[k]
            y_top, rise = seg_height(i)
            j = k
            if rise < 0.05:  # merge flat intervals that keep their heading into one box (at most 60 long)
                while (j + 1 < len(idxs) and seg_height(idxs[j + 1])[1] < 0.05 and abs(seg_height(idxs[j + 1])[0] - y_top) < 0.05
                       and horiz(ss[i], ss[idxs[j + 1] + 1]) <= 60.0
                       and abs(ss[idxs[j + 1]].yaw_dx * ss[i].yaw_dz - ss[idxs[j + 1]].yaw_dz * ss[i].yaw_dx) < 0.02):
                    j += 1
            a, b = ss[i], ss[idxs[j] + 1]
            ln = round(horiz(a, b) + 0.3, 2)
            mid = ((a.x + b.x) / 2, (a.z + b.z) / 2)
            r = yaw_axes(b.x - a.x, b.z - a.z)
            h_full = round(y_top, 1)
            tag = "%s#%d_%d" % (name, i, idxs[j])
            pod_h = min(podium_h, h_full)
            put("RooftopPodium_" + tag, {"parts": [part("B", 0, pod_h / 2, 0, RT.SUPPORT_W + 2, pod_h, ln, 0, 0, 0,
                                                       dim(pal["podium"], 0.9), "Concrete", NC)]}, (mid[0], 0.0, mid[1]), r)
            parts_n += 1
            if h_full > podium_h:
                put("RooftopShaft_" + tag, {"parts": [part("B", 0, (h_full + podium_h) / 2, 0, RT.SUPPORT_W, h_full - podium_h, ln,
                                                           0, 0, 0, shaft, "Plastic", NC)]}, (mid[0], 0.0, mid[1]), r)
                parts_n += 1
            if rise >= 0.05:
                hi, lo = (a, b) if a.y > b.y else (b, a)  # the wedge's +z (full-height back face) is the uphill end
                u = (hi.x - lo.x, hi.z - lo.z)
                look = routelib.unit((-u[0], 0.0, -u[1]))
                wr = yxz_from_axes(routelib.unit(routelib.cross(look, up)), up, look)
                put("RooftopWedge_" + tag, {"parts": [part("W", 0, rise / 2, 0, RT.SUPPORT_W, round(rise, 2), round(horiz(a, b) + 0.2, 2),
                                                           0, 0, 0, shaft, "Plastic", NC)]}, (mid[0], y_top, mid[1]), wr)
                parts_n += 1
            # neon bands on both long faces at fixed world heights where the box reaches them
            for by in bands_y:
                if h_full < by + 1.0:
                    continue
                idx_c, col = tron_colour(1.0, a.s + bi * 450.0 + by * 3)
                put("RooftopBand#%s_%d" % (tag, int(by)),
                    {"parts": [part("B", sgn * (RT.SUPPORT_W / 2 + 0.1), by, 0, 0.4, 1.1, ln, 0, 0, 0, col, "Neon", NC)
                               for sgn in (-1, 1)]}, (mid[0], 0.0, mid[1]), r)
                parts_n += 2
            k = j + 1

    # pier pairs under the slip lanes (flat at road height): two columns and a cap every 30 studs
    pier_runs = [(8.0, c0 - 18.0), (d1 + 12.0, ss[-1].s - 8.0)]
    piers_n = 0
    for lo, hi in pier_runs:
        s_p = lo
        while s_p <= hi:
            i = min(range(n), key=lambda j: abs(ss[j].s - s_p))
            sm = ss[i]
            hr = _rt_hr(sm)
            r = yaw_axes(sm.yaw_dx, sm.yaw_dz)
            deck_bottom = sm.y - RT.DECK_T
            cols = [part("B", sgn * 8.0, (deck_bottom - 2.0) / 2, 0, 6.0, deck_bottom - 2.0, 6.0, 0, 0, 0, RT_SUPPORT_COLOUR[0], "Concrete", NC)
                    for sgn in (-1, 1)]
            cols.append(part("B", 0, deck_bottom - 1.0, 0, RT.DECK_W, 2.0, 7.0, 0, 0, 0, dim(PAL[RT_PALETTE[0]]["podium"], 0.9), "Concrete", NC))
            put("RooftopPier#%d" % round(deck_bottom * 2), {"parts": cols}, (sm.x, 0.0, sm.z), r)
            piers_n += 1
            parts_n += 3
            s_p += 30.0
    return {"supportParts": parts_n, "piers": piers_n}


def main() -> None:
    plan, dbg = build()
    write_layout(dbg["neon"])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(plan, indent=1, sort_keys=False)
    OUT.write_text(text + "\n")
    pv = plan["skyrally"]["provenance"]
    print(f"wrote {OUT.relative_to(ROOT)} sha256={hashlib.sha256(text.encode()).hexdigest()[:12]}")
    print(f"sky        {', '.join(write_sky())} -> {SKY_DIR.relative_to(ROOT)}")
    print(f"route      {pv['waypoints']} waypoints, length {pv['routeLength']:.2f} (target {TARGET_LENGTH}, flexScale "
          f"{pv['routeFlexScale']:.4f}), min turn radius {pv['minTurnRadius']} at st {pv['minTurnRadiusStation']}, "
          f"max grade {pv['maxGradeDeg']} deg, max bank {pv['maxBankDeg']} deg")
    j = pv["jump"]
    print(f"jump       lip st {j['lip']} deck ends {j['deckEnd']} resumes {j['deckResume']}; min launch speed "
          f"{j['minLaunchSpeed']} studs/s (car top 128); lands st {j['landingAt128']} at 128")
    print(f"art        prefabs {len(plan['prefabs'])}, instances {len(plan['instances'])}, parts {pv['parts']} "
          f"(collidable {pv['collidableParts']}), terrain {plan['terrain']['nx']}x{plan['terrain']['nz']} cell {CELL}")
    gp = plan["skyrally"]["gameplay"]
    print(f"gameplay   checkpoints {gp['checkpoints']['stations']}")
    print(f"           rings {[r['station'] for r in gp['rings']]} pads {[p['station'] for p in gp['pads']]} "
          f"pods {len(gp['pods'])} coins {[c['station'] for c in gp['coins']]}")
    a = gp["alternates"][0]
    print(f"           Alt1 join {a['joinStation']} rejoin {a['rejoinStation']} points {len(a['points'])}")


def build() -> tuple[dict, dict]:
    recs = design()
    by = {r["label"]: r for r in recs}
    nodes, _ = build_nodes(recs)
    rt = route_block(nodes)
    route = routelib.solve_plan_route(rt)
    length = route.length
    wps = route.waypoints
    poly = Poly([w.pos for w in wps], [w.station for w in wps])
    rows, _ = route_geometry.analyse([list(w.pos) for w in wps], min_radius=MIN_RADIUS)
    min_r = min(rows, key=lambda r: r["r"])

    def station_of_design(label: str, t: float) -> float:
        x, z = seg_point(by[label], t)
        sh = FLEX_X * route.flex_scale if label in FLEXED else 0.0
        _, st, _ = poly.nearest(ORIGIN[0] + x + sh, ORIGIN[2] + z)
        return st

    # ---------------------------------------------------------------- jump
    j0 = station_of_design("jump", 0.0)
    j1 = station_of_design("jump", 1.0)
    lip = round(find_lip(route, j0, j1), 1)
    # the gap runs from the crest over the whole height step: it ends just before the first waypoint after which
    # every deck segment (to the landing flat) is within the grade limit
    gap_to = None
    cand = [w for w in wps if lip + 12.0 <= w.station <= lip + 40.0]
    for w in cand:
        ok = True
        for a, b in zip(wps, wps[1:]):
            if w.station <= a.station <= lip + 90.0:
                h = math.hypot(b.pos[0] - a.pos[0], b.pos[2] - a.pos[2])
                if abs(math.degrees(math.atan2(b.pos[1] - a.pos[1], h))) > MAX_GRADE_DEG - 1.0:
                    ok = False
                    break
        if ok:
            gap_to = round(w.station - 0.1, 1)
            break
    assert gap_to is not None and gap_to - lip <= 30.0, (lip, gap_to)
    gap_from = lip
    deck_end, deck_resume = deck_gap_span(route, gap_from, gap_to)
    v_min = min_jump_speed(route, deck_end, deck_resume)
    land_128 = landing_station(route, deck_end, deck_resume, 128.0)

    # grades and banks (deck segments only; the gap has no deck)
    max_grade = 0.0
    for a, b in zip(wps, wps[1:]):
        if gap_from <= a.station <= gap_to:
            continue
        h = math.hypot(b.pos[0] - a.pos[0], b.pos[2] - a.pos[2])
        if h > 1e-6:
            max_grade = max(max_grade, abs(math.degrees(math.atan2(b.pos[1] - a.pos[1], h))))
    max_bank = max(abs(w.bank) for w in wps)
    assert max_grade <= MAX_GRADE_DEG, max_grade
    assert max_bank <= MAX_BANK_DEG, max_bank

    # ---------------------------------------------------------------- alternate: straight tunnel through the mesa
    s_join = station_of_design("bulge1", 0.0)
    s_rejoin = station_of_design("bulge3", 1.0)
    fa, fb = route.frame_at(s_join), route.frame_at(s_rejoin)
    chord = routelib.sub(fb.pos, fa.pos)
    chord_len = routelib.mag(chord)
    alt_dir = routelib.unit((chord[0], 0.0, chord[2]))
    alt_all = []
    n_alt = max(2, round(chord_len / 16.0))
    for k in range(n_alt + 1):
        t = k / n_alt
        p = routelib.add(fa.pos, routelib.mul(chord, t))
        p = (p[0], p[1] - 0.4, p[2])  # floor top (point + 1.8) at ribbon + 1.4, flush with the approach shelf
        dist, _, _ = poly.nearest(p[0], p[2])
        alt_all.append((p, dist, t))
    kept = [i for i, (_, d_, _) in enumerate(alt_all) if d_ >= ALT_MIN_OFFSET]
    assert kept and kept == list(range(kept[0], kept[-1] + 1)), "Alt1 kept points must be one contiguous run"
    alt_pts = [[r2(v) for v in alt_all[i][0]] for i in kept]
    alt_first, alt_last = alt_all[kept[0]][0], alt_all[kept[-1]][0]
    alt_mid = routelib.mul(routelib.add(alt_first, alt_last), 0.5)
    alt_floor_y = alt_first[1] + 1.8
    alt_right = routelib.unit(routelib.cross(alt_dir, routelib.UP))

    def chord_distance(x: float, z: float) -> float:
        rel = (x - fa.pos[0], 0.0, z - fa.pos[2])
        t = max(0.0, min(chord_len, routelib.dot(rel, alt_dir)))
        q = routelib.add((fa.pos[0], 0.0, fa.pos[2]), routelib.mul(alt_dir, t))
        return math.hypot(x - q[0], z - q[2])

    alt_side = 1.0 if routelib.dot(routelib.sub(alt_mid, route.frame_at((s_join + s_rejoin) / 2).pos),
                                   route.frame_at((s_join + s_rejoin) / 2).right) > 0 else -1.0
    alt_north = routelib.mul(alt_right, alt_side)  # chord lateral axis, positive away from the bulge road

    def chord_uv(p: tuple) -> tuple[float, float]:
        """(along the chord from the join frame, lateral off the chord: + away from the bulge road)."""
        rel = (p[0] - fa.pos[0], 0.0, p[2] - fa.pos[2])
        return routelib.dot(rel, alt_dir), routelib.dot(rel, alt_north)

    # open (wall-less) stretches of the parapet on the route side that faces the shortcut, at both forks: open only
    # while that parapet line runs inside the shortcut apron, i.e. no further toward the bulge than the tube wall's
    # outer face (FORK_OPEN_BAND). The funnel rails below close the apron from there to the tube, so a car that leaves
    # the road through an opening can only reach the tube (S4-04: the old chord-distance rule, < 74 plus 6 studs of
    # padding, also opened 50-60 studs of parapet that faced the inner-bulge shelf and its basin -> OffTrack at CP10)
    fork_open = []
    cur = None
    st = s_join - 4
    while st <= s_rejoin + 4:
        _, v_par = chord_uv(offset_point(route, st, alt_side * WALL_LATERAL, 0.0))
        if v_par > -FORK_OPEN_BAND:
            cur = [st, st] if cur is None else [cur[0], st]
        elif cur is not None:
            fork_open.append(tuple(cur))
            cur = None
        st += 1.0
    if cur is not None:
        fork_open.append(tuple(cur))
    fork_open = [(round(a, 1), round(b, 1)) for a, b in fork_open]
    assert len(fork_open) == 2, fork_open

    # ---------------------------------------------------------------- viaduct crossings
    fv = route.frame_at(VIADUCT_STATION)
    z_v = fv.pos[2]
    crossings = [(VIADUCT_STATION, fv.pos[0], fv.pos[1])]
    e0, e1 = station_of_design("east", 0.0), station_of_design("east", 1.0)
    for a, b in zip(wps, wps[1:]):
        if e0 <= a.station <= e1 and (a.pos[2] - z_v) * (b.pos[2] - z_v) <= 0 and a.pos[2] != b.pos[2]:
            t = (z_v - a.pos[2]) / (b.pos[2] - a.pos[2])
            crossings.append((a.station + (b.station - a.station) * t, a.pos[0] + (b.pos[0] - a.pos[0]) * t,
                              a.pos[1] + (b.pos[1] - a.pos[1]) * t))
            break
    assert len(crossings) == 2, crossings
    near_viaduct = [(wrap(s - 30, length), wrap(s + 30, length)) for s, _, _ in crossings]

    # ---------------------------------------------------------------- rooftop shortcut (SPACE-4 signature): anchors only
    roof = rooftop_plan(route, poly)

    # ---------------------------------------------------------------- prefabs / instances
    prefabs: dict[str, dict] = {}
    instances: list[dict] = []
    groups = ["Landmarks", "Landmarks/MonorailViaduct", "Landmarks/GlassVault", "City", "Highway/Parapets",
              "Highway/LaneLines", "Highway/Streetlamps", "Highway/Gantries", "MoonPlain", "StartFinish",
              "Landmarks/DowntownViaduct", "Highway/Gantries/GatePortals"]  # Wave 2 (critic v29 2.1/2.2)
    if ROOFTOP_SHORTCUT:
        groups.append("Highway/RooftopLine")
    gi = {g: i + 1 for i, g in enumerate(groups)}

    def place(pf: str, p: tuple | list, g: str, r=0.0, s: float | None = None):
        inst = {"pf": pf, "p": [r4(v) for v in p], "g": gi[g], "r": r}
        if s is not None:
            inst["s"] = s
        instances.append(inst)

    # parapets (collidable): skip over the jump gap on both sides and at the shortcut forks on the shortcut side; past
    # the gap the parapet starts NOSE_FLARE_LEN later and a flared nose (below) leads into it
    gap_skip = [(deck_end - 1.0, deck_resume + 1.0)]
    wall_gap_skip = [(deck_end - 1.0, deck_resume + 1.0 + NOSE_FLARE_LEN)]
    wall_specs = []
    for side in (-1.0, 1.0):
        skip = list(wall_gap_skip) + (fork_open if side == alt_side else []) + roof.open_ranges[side]
        for pc in curve_pieces(route, side * WALL_LATERAL, 0.0, skip, WALL_MAX_PIECE, WALL_SAG):
            wall_specs.append(pc)
    # split any piece whose world AABB still reaches the corridor box until the gate passes
    for _ in range(8):
        tmp_pf, tmp_inst = {}, []
        for pc in wall_specs:
            key = "HighwayParapet#%05.2f" % bucket(pc["len"])
            tmp_pf.setdefault(key, parapet_prefab(bucket(pc["len"])))
            tmp_inst.append({"pf": key, "p": [r4(v) for v in pc["p"]], "g": 1, "r": pc["r"]})
        rep = adapt.Report()
        res = adapt.corridor_gate({"prefabs": tmp_pf, "instances": tmp_inst}, {"flight": {"corridor": CORRIDOR}}, route, rep)
        bad = {m["instance"] - 1 for m in res["intrusions"]}
        if not bad:
            break
        nxt = []
        for i, pc in enumerate(wall_specs):
            if i in bad:
                mid = (pc["from"] + pc["to"]) / 2
                nxt.append(piece_record(route, pc["from"], mid, pc["lateral"], 0.0))
                nxt.append(piece_record(route, mid, pc["to"], pc["lateral"], 0.0))
            else:
                nxt.append(pc)
        wall_specs = nxt
    for pc in wall_specs:
        q = bucket(pc["len"])
        key = "HighwayParapet#%05.2f" % q
        prefabs.setdefault(key, parapet_prefab(q))
        place(key, pc["p"], "Highway/Parapets", pc["r"])

    # straight collidable wall lines that are not route offsets (nose flares, Alt1 funnel rails): equal pieces of at most
    # max_len, each halved again while its world AABB reaches the corridor box (as the parapets above)
    def line_record(a: tuple, b: tuple) -> dict:
        look = routelib.unit(routelib.sub(b, a))
        right = routelib.unit(routelib.cross(look, routelib.UP))
        up = routelib.unit(routelib.cross(right, look))
        return {"a": a, "b": b, "len": routelib.mag(routelib.sub(b, a)), "p": routelib.mul(routelib.add(a, b), 0.5),
                "r": yxz_from_axes(right, up, look)}

    def line_walls(lines: list[tuple[tuple, tuple]], family: str, max_len: float) -> list[dict]:
        recs = []
        for a, b in lines:
            n = max(1, math.ceil(routelib.mag(routelib.sub(b, a)) / max_len - 1e-9))
            ab = routelib.sub(b, a)
            recs += [line_record(routelib.add(a, routelib.mul(ab, k / n)), routelib.add(a, routelib.mul(ab, (k + 1) / n)))
                     for k in range(n)]
        for _ in range(8):
            tmp_pf, tmp_inst = {}, []
            for rc in recs:
                key = "%s#%05.2f" % (family, bucket(rc["len"]))
                tmp_pf.setdefault(key, parapet_prefab(bucket(rc["len"])))
                tmp_inst.append({"pf": key, "p": [r4(v) for v in rc["p"]], "g": 1, "r": rc["r"]})
            rep = adapt.Report()
            res = adapt.corridor_gate({"prefabs": tmp_pf, "instances": tmp_inst}, {"flight": {"corridor": CORRIDOR}},
                                      route, rep)
            bad = {m["instance"] - 1 for m in res["intrusions"]}
            if not bad:
                break
            nxt = []
            for i, rc in enumerate(recs):
                if i in bad:
                    mid = routelib.mul(routelib.add(rc["a"], rc["b"]), 0.5)
                    nxt += [line_record(rc["a"], mid), line_record(mid, rc["b"])]
                else:
                    nxt.append(rc)
            recs = nxt
        assert not bad, f"{family}: pieces still in the corridor"
        for rc in recs:
            q = bucket(rc["len"])
            key = "%s#%05.2f" % (family, q)
            prefabs.setdefault(key, parapet_prefab(q))
            place(key, rc["p"], "Highway/Parapets", rc["r"])
        return recs

    # flared noses where the parapets resume after the rift gap (S4-03): the leading end that faces landing traffic
    # bends outward NOSE_FLARE_DEG over NOSE_FLARE_LEN, so a car landing wide slides back inside instead of meeting a
    # blunt 2-stud end head-on (the landing abutment rock under it is 84 wide)
    flare_out = NOSE_FLARE_LEN * math.tan(math.radians(NOSE_FLARE_DEG))
    nose_lines, landing_noses = [], {}
    for side in (-1.0, 1.0):
        s0 = min(pc["from"] for pc in wall_specs if pc["lateral"] == side * WALL_LATERAL and pc["from"] > deck_resume)
        nose_lines.append((offset_point(route, s0 - NOSE_FLARE_LEN, side * (WALL_LATERAL + flare_out), 0.0),
                           offset_point(route, s0, side * WALL_LATERAL, 0.0)))
        landing_noses[side] = (s0 - NOSE_FLARE_LEN, side * (WALL_LATERAL + flare_out))
    nose_recs = line_walls(nose_lines, "HighwayParapet", WALL_MAX_PIECE)

    # Alt1 funnel rails (S4-01 tunnel mouth, S4-03 exit leak, S4-04 basin): four straight rails close both aprons from
    # the fork parapet ends to the tube walls. Entry rails end FUNNEL_EMBED inside the walls with their inner face just
    # inside the tube's (so the walls' blunt ends are shadowed); exit rails start flush with the walls' inner faces and
    # diverge (so no step faces traffic leaving the tube). The south rails meet the bulge parapet where its opening ends
    # (entry, through the gore wedge below) and starts (exit), sealing the inner-bulge shelf and its basin off both
    # aprons.
    alt_ws = [pc for pc in wall_specs if pc["lateral"] == alt_side * WALL_LATERAL]
    (o1a, o1b), (o2a, o2b) = fork_open

    # the parapet's real ends next to an opening (curve_pieces can run its last piece up to 1 stud into a skip range)
    def par_end(limit: float) -> tuple:
        pc = max((pc for pc in alt_ws if pc["from"] < limit), key=lambda pc: pc["to"])
        return offset_point(route, pc["to"], pc["lateral"], 0.0)

    def par_start(limit: float) -> tuple:
        pc = min((pc for pc in alt_ws if pc["to"] > limit), key=lambda pc: pc["from"])
        return offset_point(route, pc["from"], pc["lateral"], 0.0)

    rail_y = alt_floor_y - 1.4  # the parapet profile's ribbon height (the apron floor is ribbon + 1.4)

    def tube_point(base: tuple, along: float, lateral: float) -> tuple:
        q = routelib.add(routelib.add(base, routelib.mul(alt_dir, along)), routelib.mul(alt_north, lateral))
        return (q[0], rail_y, q[2])

    rail_in = TUBE_INNER + WALL_THICK / 2 - 0.4  # inner face 0.4 inside the tube's where the entry rails end
    rail_out = TUBE_INNER + WALL_THICK / 2  # inner face flush with the tube's where the exit rails start
    t_in, t_out = FUNNEL_EMBED - 1.0, -(FUNNEL_EMBED - 1.0)  # kit walls run 1 stud past the end points
    j_entry, j_exit = par_start(o1b), par_end(o2a)
    t_south_in = tube_point(alt_first, t_in, -rail_in)
    # the entry gore, where the south rail leaves the bulge parapet's leading end, is a ~48 degree spike pointing
    # upstream. Two 2-thick blocks cannot make a clean spike (each one's thickness pokes past the other's outer face near
    # the tip, leaving an end face for a car to meet head-on, a spin), so a vertical wedge fills the tip: its legs are the
    # rail's apron face (X -> A) and the rail's start (A -> B, one wall thick), its hypotenuse (X -> B) is the parapet's
    # road face. The rail starts at A and a short parapet nose starts at B; their start faces are buried in each other or
    # in the wedge. A westbound car at the tip touches the rail face (~6 deg, a deflect) or the parapet face (~45 deg, a
    # bump), never an end face.
    pc1 = min((pc for pc in alt_ws if pc["to"] > o1b), key=lambda pc: pc["from"])
    dp = routelib.unit(routelib.sub(offset_point(route, pc1["to"], pc1["lateral"], 0.0), j_entry))
    dr = routelib.unit(routelib.sub(t_south_in, j_entry))
    dp, dr = routelib.unit((dp[0], 0.0, dp[2])), routelib.unit((dr[0], 0.0, dr[2]))
    road = routelib.sub(route.frame_at(pc1["from"]).pos, j_entry)
    n_p = routelib.unit((-dp[2], 0.0, dp[0]))
    n_p = n_p if routelib.dot(n_p, road) > 0 else routelib.mul(n_p, -1.0)  # toward the road
    n_r = routelib.unit((-dr[2], 0.0, dr[0]))
    n_r = n_r if routelib.dot(n_r, dp) < 0 else routelib.mul(n_r, -1.0)  # toward the apron, away from the inner wedge
    half = WALL_THICK / 2
    # tip X: j + n_r*half + s*dr == j + n_p*half + t*dp (horizontal)
    rx, rz = (n_p[0] - n_r[0]) * half, (n_p[2] - n_r[2]) * half
    det = dr[0] * (-dp[2]) - dr[2] * (-dp[0])
    s_x = (rx * (-dp[2]) - rz * (-dp[0])) / det
    tip = routelib.add(j_entry, routelib.add(routelib.mul(n_r, half), routelib.mul(dr, s_x)))
    spike = math.acos(max(-1.0, min(1.0, routelib.dot(dr, dp))))
    assert math.radians(20) < spike < math.radians(80), math.degrees(spike)
    leg = WALL_THICK / math.tan(spike)
    gore_a = routelib.add(tip, routelib.mul(dr, leg))
    gore_b = routelib.sub(gore_a, routelib.mul(n_r, WALL_THICK))
    rail_start = routelib.sub(gore_a, routelib.mul(n_r, half))
    nose_start = routelib.sub(gore_b, routelib.mul(n_p, half))
    gore_c = routelib.mul(routelib.add(tip, gore_b), 0.5)
    w_up = routelib.mul(n_r, -1.0)  # wedge local +y: A -> B
    w_back = dr  # wedge local +z: X -> A (the full-height back face is the rail start)
    w_right = routelib.cross(w_up, w_back)
    prefabs["ShortcutFunnelRail#gore"] = {"parts": [
        part("W", 0, (CAP_TOP + WALL_BOTTOM) / 2, 0, CAP_TOP - WALL_BOTTOM, WALL_THICK, leg,
             *yxz_from_axes(w_right, w_up, routelib.mul(w_back, -1.0)), C["cream"], "Concrete"),
    ]}
    place("ShortcutFunnelRail#gore", (gore_c[0], j_entry[1], gore_c[2]), "Highway/Parapets", 0.0)
    funnel_lines = {
        "entryNorth": (par_end(o1a), tube_point(alt_first, t_in, rail_in)),
        "entrySouth": (rail_start, t_south_in),
        "exitSouth": (tube_point(alt_last, t_out, -rail_out), j_exit),
        "exitNorth": (tube_point(alt_last, t_out, rail_out), par_start(o2b)),
    }
    funnel_recs = line_walls(list(funnel_lines.values()), "ShortcutFunnelRail", FUNNEL_MAX_PIECE)
    nose_start = (nose_start[0], j_entry[1], nose_start[2])
    line_walls([(nose_start, routelib.add(j_entry, routelib.mul(dp, 0.5)))], "HighwayParapet", WALL_MAX_PIECE)
    funnel_angles = {}
    for name, (a, b) in funnel_lines.items():
        (ua, va), (ub, vb) = chord_uv(a), chord_uv(b)
        funnel_angles[name] = round(math.degrees(math.atan2(abs(vb - va), abs(ub - ua))), 2)

    # neon lane lines on the pavers (cyan centre, amber lane edges), curved with the road
    line_h = PAVER_TOP + 0.1
    lane_count = 0
    for lat, colour, name in ((0.0, C["neonCyan"], "NeonLaneLine_Cyan"), (-14.5, LANE_AMBER_DIM, "NeonLaneLine_Amber"),
                              (14.5, LANE_AMBER_DIM, "NeonLaneLine_Amber")):
        for pc in curve_pieces(route, lat, line_h, gap_skip, 24.0, 0.18):
            q = bucket(pc["len"])
            key = "%s#%05.2f" % (name, q)
            prefabs.setdefault(key, lane_prefab(q, colour, LANE_CENTRE_W if lat == 0.0 else 0.9))
            place(key, pc["p"], "Highway/LaneLines", pc["r"])
            lane_count += 1

    # streetlamps on the parapet caps, alternating sodium/cyan, staggered sides; short wall lamps inside the vault
    prefabs["Streetlamp_Sodium"] = streetlamp_prefab(C["neonAmber"])
    prefabs["Streetlamp_Cyan"] = streetlamp_prefab(C["neonCyan"])
    prefabs["VaultWallLamp_Sodium"] = vault_lamp_prefab(C["neonAmber"])
    prefabs["VaultWallLamp_Cyan"] = vault_lamp_prefab(C["neonCyan"])
    # the rift beacons own the parapet caps at both deck ends (a lamp there stood inside a beacon)
    lamp_skip = [(deck_end - 10.0, deck_resume + 10.0)] + [(a - 20, b + 20) for a, b in near_viaduct] + \
        [(-1, 40), (length - 12, length + 1)] + roof.keep_out
    lamp_count = 0
    spacing = 96.0
    for side in (-1.0, 1.0):
        st = 60.0 + (0.0 if side > 0 else spacing / 2)
        k = 0
        while st < length - 20:
            k += 1
            skip = lamp_skip + (fork_open if side == alt_side else [])
            if not in_ranges(st, skip):
                in_vault = TUNNEL_FROM - 4 <= st <= TUNNEL_TO + 4
                st_l = st
                if in_vault:  # mid-bay, so a wall lamp never stands inside a rib leg on the same cap
                    bay = min(max(0, math.floor((st - TUNNEL_FROM) / RIB_STEP)), round((TUNNEL_TO - TUNNEL_FROM) / RIB_STEP) - 1)
                    st_l = TUNNEL_FROM + RIB_STEP * (bay + 0.5)
                f = route.frame_at(st_l)
                pos = offset_point(route, st_l, side * WALL_LATERAL, CAP_TOP)
                face = routelib.mul(f.right, side)  # local +x points away from the road
                yaw = r4(math.degrees(math.atan2(-face[2], face[0])))  # rotate local +x onto `face`
                kind = ("VaultWallLamp_" if in_vault else "Streetlamp_") + ("Sodium" if k % 2 else "Cyan")
                place(kind, pos, "Highway/Streetlamps", [0.0, yaw, 0.0])
                lamp_count += 1
            st += spacing

    # Glass Vault tunnel on the start straight (bright glazed vault; heavy portal ribs at both ends)
    prefabs["GlassVaultRib"] = vault_rib_prefab()
    prefabs["GlassVaultPortal"] = vault_rib_prefab(heavy=True)
    prefabs["GlassVaultBanner_Amber"] = vault_banner_prefab(C["neonAmber"])
    prefabs["GlassVaultBanner_Cyan"] = vault_banner_prefab(C["neonCyan"])
    ribs = []
    st = TUNNEL_FROM
    while st <= TUNNEL_TO + 1e-6:
        ribs.append(st)
        st += RIB_STEP
    bay_key = "GlassVaultBay#%05.2f" % RIB_STEP
    prefabs[bay_key] = vault_bay_prefab(RIB_STEP)
    for i, st in enumerate(ribs):
        f = route.frame_at(st)
        r = yxz_from_axes(f.right, routelib.UP, (f.tangent[0], 0.0, f.tangent[2]))
        place("GlassVaultPortal" if i in (0, len(ribs) - 1) else "GlassVaultRib", f.pos, "Landmarks/GlassVault", r)
        if i + 1 < len(ribs):
            fm = route.frame_at(st + RIB_STEP / 2)
            place(bay_key, fm.pos, "Landmarks/GlassVault",
                  yxz_from_axes(fm.right, routelib.UP, (fm.tangent[0], 0.0, fm.tangent[2])))
        if 0 < i < len(ribs) - 1 and i % 4 == 2:
            for side in (-1.0, 1.0):
                ang = math.atan2(VAULT_B * 0.42, VAULT_A)  # banner on the rib leg, ~15 studs up
                bx = side * (VAULT_A * math.cos(ang) - 1.6)
                by_ = CAP_TOP + VAULT_B * math.sin(ang) - 4.0
                pos = routelib.add(routelib.add(f.pos, routelib.mul(f.right, bx)), (0.0, by_, 0.0))
                face = routelib.mul(f.right, side)
                yaw = r4(math.degrees(math.atan2(-face[2], face[0])))
                place("GlassVaultBanner_Amber" if (i // 4) % 2 == 0 else "GlassVaultBanner_Cyan", pos,
                      "Landmarks/GlassVault", [0.0, yaw, 0.0])

    # Monorail viaduct along world X at the start-straight crossing, crossing the east descent too
    x_min = min(w.pos[0] for w in wps)
    x_max = max(w.pos[0] for w in wps)
    xa_c, xb_c = sorted(c[1] for c in crossings)
    piers = []
    x = xa_c - 36.0
    west_end = x_min - 300.0
    while x >= west_end:
        piers.append(x)
        x -= 72.0
    inner_a, inner_b = xa_c + 36.0, xb_c - 36.0
    n_mid = max(1, round((inner_b - inner_a) / 72.0))
    piers += [inner_a + (inner_b - inner_a) * k / n_mid for k in range(n_mid + 1)]
    x = xb_c + 36.0
    east_end = x_max + 300.0
    while x <= east_end:
        piers.append(x)
        x += 72.0
    piers = sorted(set(round(p, 3) for p in piers))
    prefabs["MonorailViaductPier"] = viaduct_pier_prefab()
    for px in piers:
        place("MonorailViaductPier", (px, 0.0, z_v), "Landmarks/MonorailViaduct", 0.0)
    for pa, pb in zip(piers, piers[1:]):
        span = round(pb - pa, 1)
        key = "MonorailViaductSpan#%05.1f" % span
        prefabs.setdefault(key, viaduct_span_prefab(span))
        place(key, ((pa + pb) / 2, 0.0, z_v), "Landmarks/MonorailViaduct", 0.0)
    prefabs["MonorailTrain"] = train_prefab()
    place("MonorailTrain", (xa_c + 12.0, V_BEAM_TOP + 0.4, z_v), "Landmarks/MonorailViaduct", 0.0)
    place("MonorailTrain", (xb_c - 150.0, V_BEAM_TOP + 0.4, z_v), "Landmarks/MonorailViaduct", 180.0)
    prefabs["MonorailStation"] = station_prefab()
    place("MonorailStation", (piers[0] - 18.0, 0.0, z_v), "Landmarks/MonorailViaduct", 0.0)
    place("MonorailStation", (piers[-1] + 18.0, 0.0, z_v), "Landmarks/MonorailViaduct", 180.0)

    # sign gantries over the road, start/finish arch and line, jump lip chevrons and rift beacons
    prefabs["NeonSignGantry_Cyan"] = gantry_prefab(C["neonCyan"])
    prefabs["NeonSignGantry_Amber"] = gantry_prefab(C["neonAmber"])
    gantry_at = [station_of_design("north1", 0.55), station_of_design("north2", 0.45), station_of_design("east", 0.22),
                 station_of_design("south1", 0.5), station_of_design("climb", 0.35)]
    for i, st in enumerate(gantry_at):
        f = route.frame_at(st)
        place("NeonSignGantry_Cyan" if i % 2 == 0 else "NeonSignGantry_Amber", f.pos, "Highway/Gantries",
              yxz_from_axes(*banked_axes(f), f.tangent))
    # L61 skyway arches: a landmark beat every few seconds of driving, each between two streetlamps (lamps stand every
    # 48 studs from st 60, alternating sides, so st 84 + 48k is always mid-gap), clear of the vault, the viaduct
    # crossings, the gantries, the boost gates, the Alt1 bulge and the rift
    arch_cols = (C["neonCyan"], C["neonWarm"], C["neonAmber"])  # v29 A10: neonPink -> neonWarm
    for i, col in enumerate(arch_cols):
        prefabs["SkywayArch_%d" % i] = skyway_arch_prefab(col)
    arch_keep_out = [(TUNNEL_FROM - 60, TUNNEL_TO + 40), (s_join - 60, s_rejoin + 60), (gap_from - 120, gap_to + 60)] + \
        [(c - 60, c + 60) for c, _, _ in crossings] + [(g - 45, g + 45) for g in gantry_at] + [(-1, 60), (length - 60, length + 1)] + roof.keep_out
    # Wave 2: the downtown viaduct's gateways are the landmark beats from DT_FROM to DT_TO (an arch there would cut them)
    arch_keep_out.append((DT_FROM - 30.0, DT_TO + 30.0))
    arch_stations = []
    for want in (700.0, 1060.0, 1360.0, 1920.0, 2200.0, 2460.0, 2900.0, 3160.0, 4420.0, 4620.0):
        st_a = 84.0 + 48.0 * round((want - 84.0) / 48.0)
        if in_ranges(st_a, arch_keep_out) or any(abs(st_a - a) < 160 for a in arch_stations):
            continue
        arch_stations.append(st_a)
    for i, st_a in enumerate(arch_stations):
        fa_ = route.frame_at(st_a)
        place("SkywayArch_%d" % (i % 3), fa_.pos, "Highway/Gantries", yxz_from_axes(*banked_axes(fa_), fa_.tangent))
    # ---------------------------------------------------------------- space-neon road pass (all nc, visual only)
    tron_skip = list(gap_skip)
    tron_parts_before = sum(len(prefabs[i["pf"]]["parts"]) for i in instances)
    edge_pieces = 0
    for side in (-1.0, 1.0):
        for pc in curve_pieces(route, side * TRON_EDGE_LATERAL, PAVER_TOP + 0.12, tron_skip, 48.0, 0.35):
            idx, col = tron_colour(side, (pc["from"] + pc["to"]) / 2)
            q = bucket(pc["len"], 2.0)
            key = "TronEdge_%d#%05.2f" % (idx, q)
            prefabs.setdefault(key, tron_edge_prefab(q, col))
            place(key, pc["p"], "Highway/LaneLines", pc["r"])
            edge_pieces += 1
    prefabs["TronGridRung"] = tron_rung_prefab()
    rung_keep_out = tron_skip + [(-1, 30), (length - 30, length + 1)]
    rungs = 0
    st = TRON_RUNG_STEP / 2
    while st < length - 20:
        if not in_ranges(st, rung_keep_out):
            fr = route.frame_at(st)
            place("TronGridRung", offset_point(route, st, 0.0, PAVER_TOP + 0.06), "Highway/LaneLines",
                  yxz_from_axes(*banked_axes(fr), fr.tangent))
            rungs += 1
        st += TRON_RUNG_STEP
    chev_keep_out = tron_skip + [(gap_from - 60, gap_to + 40), (-1, 80), (length - 40, length + 1)] + \
        [(c - 40, c + 40) for c, _, _ in crossings]
    chevrons = 0
    st = 150.0
    while st < length - 60:
        if not in_ranges(st, chev_keep_out):
            idx, col = tron_colour(-1.0, st)
            key = "TronChevron_%d" % idx
            prefabs.setdefault(key, tron_chevron_prefab(col))
            fr = route.frame_at(st)
            place(key, offset_point(route, st, 7.25, PAVER_TOP + 0.09), "Highway/LaneLines",
                  yxz_from_axes(*banked_axes(fr), fr.tangent))
            chevrons += 1
        st += TRON_CHEVRON_STEP
    # v37: chevron turn boards at the walled 90-degree corners (owner: no turn signage there). Three per corner along the
    # outer side, hung outside the parapet line and 7+ studs over its cap: nothing touches the wall or the cap surface.
    turn_boards = 0
    turn_board_parts = 0  # not the road pass: kept out of the tron part budget below
    d_total = recs[-1]["d1"]
    for rec in recs:
        if rec["kind"] not in ("R", "L") or abs(math.degrees(rec["a1"] - rec["a0"])) < 80:
            continue
        sgn = 1 if rec["kind"] == "R" else -1
        key = "TurnBoard%s" % ("R" if sgn > 0 else "L")
        prefabs.setdefault(key, turn_board_prefab(sgn))
        for u in (0.12, 0.42, 0.72):
            st = (rec["d0"] + rec["length"] * u) * length / d_total
            fr = route.frame_at(st)
            outer = -float(sgn)  # a right-hand corner's outside is on the left
            pos = offset_point(route, st, outer * (WALL_LATERAL + 2.5), CAP_TOP + 9.5)
            place(key, pos, "Highway/Gantries", yxz_from_axes(fr.right, routelib.UP, (fr.tangent[0], 0.0, fr.tangent[2])))
            turn_boards += 1
            turn_board_parts += len(prefabs[key]["parts"])
    print("turn boards", turn_boards)
    tron_arch_stations = []
    for want in np.arange(130.0, length - 100.0, TRON_ARCH_STEP):
        st_a = 84.0 + 48.0 * round((want - 84.0) / 48.0)
        if in_ranges(st_a, arch_keep_out) or any(abs(st_a - a) < 72 for a in arch_stations + tron_arch_stations):
            continue
        tron_arch_stations.append(st_a)
    for i, st_a in enumerate(tron_arch_stations):
        idx, col = tron_colour(1.0, st_a)
        key = "TronArch_%d" % idx
        prefabs.setdefault(key, tron_arch_prefab(col))
        fa_ = route.frame_at(st_a)
        place(key, fa_.pos, "Highway/Gantries", yxz_from_axes(*banked_axes(fa_), fa_.tangent))
    tron_parts = sum(len(prefabs[i["pf"]]["parts"]) for i in instances) - tron_parts_before - turn_board_parts
    tron_lights = len(tron_arch_stations)
    roof_out = {}
    if ROOFTOP_SHORTCUT:
        roof_out = rooftop_emit(roof, route, prefabs, place)
        roof_out.update(rooftop_supports(roof, prefabs, place))
    prefabs["StartFinishArch"] = start_arch_prefab()
    prefabs["StartFinishLine"] = start_line_prefab()
    f0 = route.frame_at(0.0)
    r0 = yxz_from_axes(*banked_axes(f0), f0.tangent)
    place("StartFinishArch", f0.pos, "StartFinish", r0)
    place("StartFinishLine", offset_point(route, 0.0, 0.0, PAVER_TOP + 0.06), "StartFinish", r0)
    prefabs["RiftLipChevrons"] = lip_chevron_prefab()
    fl = route.frame_at(deck_end - 5.0)
    place("RiftLipChevrons", offset_point(route, deck_end - 5.0, 0.0, PAVER_TOP + 0.07), "MoonPlain",
          yxz_from_axes(*banked_axes(fl), fl.tangent))
    prefabs["RiftHazardBeacon"] = rift_beacon_prefab()
    for side in (-1.0, 1.0):
        place("RiftHazardBeacon", offset_point(route, deck_end - 2.0, side * WALL_LATERAL, CAP_TOP), "MoonPlain", 0.0)
        # landing side: on the flared nose's cap, 1 stud in from its upstream end
        nose_st, nose_lat = landing_noses[side]
        k = 1.0 / NOSE_FLARE_LEN
        place("RiftHazardBeacon", offset_point(route, nose_st + 1.0, nose_lat + (side * WALL_LATERAL - nose_lat) * k,
                                               CAP_TOP), "MoonPlain", 0.0)

    # Alt1 tunnel portals at both mouths (kit builds the tube from the points)
    prefabs["MesaTunnelPortal"] = portal_prefab()
    yaw_in = yaw_of(alt_dir)
    place("MesaTunnelPortal", routelib.add(alt_first, (0.0, -0.4, 0.0)), "MoonPlain", yaw_in)
    place("MesaTunnelPortal", routelib.add(alt_last, (0.0, -0.4, 0.0)), "MoonPlain", r4(yaw_in + 180.0))
    # S4-01: a neon chevron on the tube roof's front face over the entry hole (aim here); local +z faces the approach
    prefabs["MesaTunnelChevron"] = tunnel_chevron_prefab(alt_first[1] + 31.0 - 3.0 - (alt_first[1] - 0.4))
    place("MesaTunnelChevron", routelib.add(alt_first, (0.0, -0.4, 0.0)), "MoonPlain", yaw_in)
    # v29 W1b A12: the kit's straight amber Neon ceiling strip (Alt1TorchStrip_*, nc) is painted brass by a part rule
    # below; the tube is lit by six recessed amber lenses flush under the roof (kit roof underside = point y + 28),
    # each with a PointLight (range 20). All nc, above the corridor ceiling (26), nothing narrows the tube.
    # Review fix: the kit strip hangs on the tube axis (1.8 wide, roof underside -0.9..-0.1), so a lens on the axis sat
    # inside it; the lenses alternate 5 studs either side of the strip, flush under the bare roof.
    prefabs["Alt1CeilingLens"] = {"parts": [
        part("B", 0, 0, 0, 3.0, 0.2, 3.0, 0, 0, 0, C["brass"], "Metal", NC),
        part("B", 0, -0.12, 0, 2.0, 0.12, 2.0, 0, 0, 0, C["neonAmber"], "Neon", nc({"l": [20, 1.2, C["neonAmber"], False]})),
    ]}
    alt_len = routelib.mag(routelib.sub(alt_last, alt_first))
    for k in range(6):
        u = (k + 0.5) / 6.0
        q = routelib.add(alt_first, routelib.mul(routelib.sub(alt_last, alt_first), u))
        q = routelib.add(q, routelib.mul(alt_right, 5.0 if k % 2 == 0 else -5.0))
        place("Alt1CeilingLens", (q[0], q[1] + 27.9, q[2]), "MoonPlain", yaw_in)
    assert 120.0 < alt_len < 1200.0, alt_len

    # ---------------------------------------------------------------- terrain: height grid + mesa/boulders shells
    xs_all = [w.pos[0] for w in wps]
    zs_all = [w.pos[2] for w in wps]
    gx0 = math.floor((min(xs_all) - TERRAIN_MARGIN) / CELL) * CELL
    gz0 = math.floor((min(zs_all) - TERRAIN_MARGIN) / CELL) * CELL
    gx1 = math.ceil((max(xs_all) + TERRAIN_MARGIN) / CELL) * CELL
    gz1 = math.ceil((max(zs_all) + TERRAIN_MARGIN) / CELL) * CELL
    nx = int((gx1 - gx0) / CELL) + 1
    nz = int((gz1 - gz0) / CELL) + 1
    gx = gx0 + np.arange(nx) * CELL
    gz = gz0 + np.arange(nz) * CELL
    GX, GZ = np.meshgrid(gx, gz)  # row-major: index iz * nx + ix
    X, Z = GX.ravel().astype(float), GZ.ravel().astype(float)
    P = plain_height(X, Z)

    # districts: the city sits north of the monorail line and on both sides of the start straight (the guide's hero
    # view has towers left and right); the moon wilds fill the south-east
    x_start = f0.pos[0]
    z_start = f0.pos[2]
    city_soft = np.clip(np.minimum((z_v + 110.0 - Z) / 40.0, 1.0), 0.0, 1.0)
    city_soft = np.maximum(city_soft, np.clip(np.minimum((x_start + CITY_EAST_OF_START - X) / 40.0,
                                                         (z_start + 200.0 - Z) / 40.0), 0, 1))
    P = P + (PLAZA_Y - P) * city_soft

    # mesa footprint (terraced cylinders across the shortcut, kept clear of the main road; shells ops below)
    north = routelib.mul(alt_right, alt_side)  # away from the bulge road (the shortcut is on the road's alt_side)
    mesa = []
    along = (routelib.dot(routelib.sub(alt_last, alt_first), alt_dir)) / 2
    for off_a, off_n, r, top in ((0.0, 26.0, 92.0, 72.0), (-along * 0.55, 10.0, 70.0, 64.0), (along * 0.55, 10.0, 70.0, 64.0),
                                 (0.0, 64.0, 64.0, 84.0), (-along * 0.2, 96.0, 56.0, 58.0)):
        c = routelib.add(routelib.add(alt_mid, routelib.mul(alt_dir, off_a)), routelib.mul(north, off_n))
        d_road, _, _ = poly.nearest(c[0], c[2])
        r = min(r, d_road - 42.0)
        mesa.append((c, r, top))

    # craters in the wilds (bowl + rim), deterministic
    crater_rng = random.Random(SEED + 1)
    craters = []
    tries = 0
    while len(craters) < 9 and tries < 400:
        tries += 1
        cx = crater_rng.uniform(x_min - 260, x_max + 260)
        cz = crater_rng.uniform(z_v + 120, max(zs_all) + 300)
        r = crater_rng.uniform(34, 78)
        d_route, _, _ = poly.nearest(cx, cz)
        if d_route < r + 70 or chord_distance(cx, cz) < r + 60:
            continue
        # wilds only: no bowl in the city plazas (a tower podium would sink into it)
        if cz < z_v + 110.0 + r or (cx < x_start + CITY_EAST_OF_START + r and cz < z_start + 200.0 + r):
            continue
        if any(math.hypot(cx - mc[0], cz - mc[2]) < r + mr + 24.0 for mc, mr, _ in mesa):  # no bowl under the mesa
            continue
        if any(math.hypot(cx - a, cz - b) < r + rb + 30 for a, b, rb, _ in craters):
            continue
        craters.append((cx, cz, r, crater_rng.uniform(6, 12)))
    dust = np.zeros_like(P, dtype=bool)
    for cx, cz, r, depth in craters:
        d = np.hypot(X - cx, Z - cz)
        bowl = np.where(d < r, -depth * (1 - (d / r) ** 2), 0.0)
        rim = 0.45 * depth * np.exp(-(((d - r) / (0.22 * r)) ** 2))
        P = P + bowl + rim
        dust |= d < r * 0.8

    # road influence: at-grade shelves meet the road edge; high bridges stand clear of the ground
    d_main, y_main, lat_main, bank_main = poly.nearest_frames_many(X, Z, np.array([w.bank for w in wps], float))
    a_above = y_main - P
    # the shelf follows the banked deck plane out to the parapet line (0.4 under the deck top at every lateral), so the
    # low side of a banked at-grade curve never lifts terrain over its pavers and curbs (review fix: a flat shelf at
    # ribbon + 1.2 stood ~0.7 over the low-edge pavers and buried the low curbs on the se/bulge2/sw curves)
    shelf = (y_main + SHELF_ABOVE_RIBBON
             + np.clip(lat_main, -WALL_LATERAL, WALL_LATERAL) * np.sin(np.radians(bank_main)))
    bridge_top = np.minimum(P, y_main - 12.0)
    e = np.clip((28.0 - a_above) / 12.0, 0.0, 1.0)
    e = e * e * (3 - 2 * e)
    h_near = bridge_top + e * (shelf - bridge_top)
    RI = 44.0
    RO = RI + np.maximum(26.0, 1.7 * np.abs(h_near - P))
    w_main = np.clip((RO - d_main) / (RO - RI), 0.0, 1.0)
    w_main = w_main * w_main * (3 - 2 * w_main)
    H_main = P + w_main * (h_near - P)
    # the Alt1 line carries its own shelf (fork approaches; under the mesa it is buried by the shells)
    alt_poly = Poly([(fa.pos[0], alt_floor_y - 0.1, fa.pos[2]), (fb.pos[0], alt_floor_y - 0.1, fb.pos[2])], [0.0, chord_len])
    d_alt, y_alt = alt_poly.nearest_many(X, Z)
    w_alt = np.clip((50.0 - d_alt) / 24.0, 0.0, 1.0)
    w_alt = w_alt * w_alt * (3 - 2 * w_alt)
    H_alt = P + w_alt * (y_alt - P)
    H = np.where(w_alt > w_main, H_alt, H_main)
    H = np.where((w_alt > 0) & (w_main > 0), np.maximum(H_alt, H_main), H)

    # moonquake rift across the jump gap (narrow at the road, widening and closing away from it)
    fg = route.frame_at((deck_end + deck_resume) / 2)
    gap_c = fg.pos
    rift_dir = routelib.unit((fg.right[0], 0.0, fg.right[2]))
    road_dir = routelib.unit((fg.tangent[0], 0.0, fg.tangent[2]))
    half0 = (deck_resume - deck_end) / 2 + 3.0
    u = (X - gap_c[0]) * rift_dir[0] + (Z - gap_c[2]) * rift_dir[2]
    v = (X - gap_c[0]) * road_dir[0] + (Z - gap_c[2]) * road_dir[2]
    meander = 9.0 * np.sin(u / 47.0) * np.clip(np.abs(u) / 80.0, 0, 1)
    half = half0 * (1 + 0.9 * np.clip(np.abs(u) / 220.0, 0, 1))
    closing = np.clip((300.0 - np.abs(u)) / 80.0, 0, 1)  # the rift pinches shut 220-300 studs from the road
    dv = np.abs(v - meander)
    wall = np.where(dv < half, RIFT_FLOOR + 6 * np.clip(dv / half, 0, 1) ** 2,
                    RIFT_FLOOR + 6 + np.clip((dv - half) / 9, 0, 1) * 44)
    rift_h = np.where((closing > 0) & (dv < half + 9), wall + (1 - closing) * 60, 1e9)
    in_rift = rift_h < H
    H = np.minimum(H, rift_h)
    H = np.round(H, 1)

    mats = np.where(city_soft > 0.5, 2, 1)
    mats = np.where(dust & (city_soft < 0.5), 3, mats)
    mats = np.where(in_rift, 1, mats)
    mats = np.where((w_main > 0.85) & (city_soft < 0.5), 1, mats)
    terrain = {
        "nx": nx, "nz": nz, "cell": CELL, "x0": float(gx0), "z0": float(gz0),
        "heights": [float(v) for v in H], "materials": [int(m) for m in mats],
        "floor": RIFT_FLOOR - 8.0, "top": float(math.ceil(float(H.max()) + 4)),
        "palette": [
            {"key": "rock", "material": "Limestone", "color": "#6c6890"},
            {"key": "plaza", "material": "Pavement", "color": "#4d5370"},
            {"key": "dust", "material": "Salt", "color": "#9a93b8"},
        ],
    }

    def ground_at(x: float, z: float) -> float:
        fx = (x - gx0) / CELL
        fz = (z - gz0) / CELL
        ix = max(0, min(nx - 2, int(math.floor(fx))))
        iz = max(0, min(nz - 2, int(math.floor(fz))))
        tx, tz = fx - ix, fz - iz
        k = iz * nx + ix
        a, b, c, d = H[k], H[k + 1], H[k + nx], H[k + nx + 1]
        return float((a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * tz)

    # mesa (terraced cylinders, footprint computed above), then boulders, horizon fills, abutments, cuttings
    shell_ops = [
        {"op": "SetMaterialColor", "mat": "Limestone", "color": "#6c6890"},
        {"op": "SetMaterialColor", "mat": "Pavement", "color": "#4d5370"},
        {"op": "SetMaterialColor", "mat": "Salt", "color": "#9a93b8"},
    ]
    for c, r, top in mesa:
        shell_ops.append({"op": "FillCylinder", "cf": [r2(c[0]), r2(top / 2), r2(c[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                          "h": r2(top + 2), "r": r2(r), "mat": "Limestone"})
    boulder_rng = random.Random(SEED + 2)
    boulders = 0
    tries = 0
    while boulders < 14 and tries < 600:
        tries += 1
        bx = boulder_rng.uniform(x_min - 200, x_max + 200)
        bz = boulder_rng.uniform(z_v + 150, max(zs_all) + 250)
        br = boulder_rng.uniform(7, 17)
        d_road, _, _ = poly.nearest(bx, bz)
        if d_road < br + 60 or chord_distance(bx, bz) < br + 40:
            continue
        g = ground_at(bx, bz)
        if g < PLAIN_Y - 6:
            continue
        shell_ops.append({"op": "FillBall", "center": [r2(bx), r2(g + br * 0.35), r2(bz)], "r": r2(br), "mat": "Limestone"})
        boulders += 1
    # the moon plain continues past the grid to the horizon (four flat fills around the grid's footprint, so no grid
    # crater or the rift is filled back in), instead of a terrain edge dropping into the sky
    ext, top_y, bot_y = 2600.0, PLAIN_Y - 1.0, PLAIN_Y - 11.0
    gw, gd = gx1 - gx0, gz1 - gz0
    for cx_, cz_, sx_, sz_ in ((gx0 + gw / 2, gz0 - ext / 2, gw + 2 * ext, ext), (gx0 + gw / 2, gz1 + ext / 2, gw + 2 * ext, ext),
                               (gx0 - ext / 2, gz0 + gd / 2, ext, gd), (gx1 + ext / 2, gz0 + gd / 2, ext, gd)):
        shell_ops.append({"op": "FillBlock", "cf": [r2(cx_), r2((top_y + bot_y) / 2), r2(cz_), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                          "size": [r2(sx_), r2(top_y - bot_y), r2(sz_)], "mat": "Limestone"})

    # rift abutments: crisp rock faces exactly at both deck ends (the grid's 10-stud cells only make sloped walls), so
    # the visible gap at the road is the deck gap and no kit pier near the lip stands over the canyon
    abut = []
    for st_a, st_b, top_st in ((deck_end - 22.0, deck_end - 0.4, deck_end - 22.0),
                               (deck_resume + 0.4, deck_resume + 22.0, deck_resume + 22.0)):
        fa_, fb_ = route.frame_at(st_a), route.frame_at(st_b)
        top = route.frame_at(top_st).pos[1] + 0.6
        c = routelib.mul(routelib.add(fa_.pos, fb_.pos), 0.5)
        d = routelib.unit((fb_.pos[0] - fa_.pos[0], 0.0, fb_.pos[2] - fa_.pos[2]))
        rgt = routelib.unit(routelib.cross(d, routelib.UP))
        L = math.hypot(fb_.pos[0] - fa_.pos[0], fb_.pos[2] - fa_.pos[2])
        bottom = RIFT_FLOOR - 2.0
        shell_ops.append({"op": "FillBlock", "cf": [r2(c[0]), r2((top + bottom) / 2), r2(c[2]), r4(rgt[0]), 0, r4(-d[0]),
                                                    0, 1, 0, r4(rgt[2]), 0, r4(-d[2])],
                          "size": [84, r2(top - bottom), r2(L)], "mat": "Limestone"})
        abut.append((st_a, st_b, top))

    # the shortcut: open cuttings from each fork to its portal (bottom flush with the approach shelf, so the car
    # remounts the curb), then the tube inside the mesa (the kit tunnel walls and roof stand in the rock around it)
    def air_box(a: tuple, b: tuple, width: float, bottom: float, height: float) -> dict:
        c = routelib.mul(routelib.add(a, b), 0.5)
        L = math.hypot(b[0] - a[0], b[2] - a[2])
        return {"op": "FillBlock", "cf": [r2(c[0]), r2(bottom + height / 2), r2(c[2]), r4(alt_right[0]), 0, r4(-alt_dir[0]),
                                          0, 1, 0, r4(alt_right[2]), 0, r4(-alt_dir[2])],
                "size": [width, r2(height), r2(L)], "mat": "Air"}

    mouth_in = routelib.add(alt_first, routelib.mul(alt_dir, 6.0))
    mouth_out = routelib.add(alt_last, routelib.mul(alt_dir, -6.0))
    shell_ops.append(air_box(fa.pos, mouth_in, 64.0, alt_floor_y, 90.0))
    shell_ops.append(air_box(mouth_out, fb.pos, 64.0, alt_floor_y, 90.0))
    shell_ops.append(air_box(alt_first, alt_last, 28.0, alt_floor_y - 1.0, 28.2))

    # kit piers (kit/Deck: every piersEvery-th segment outside gaps, shaft down to max(16, mid.y - 8) below mid.y - 4.5,
    # footing at pierFootingY +-4) must stand on ground everywhere: nothing hangs over the rift or a dip
    pier_every, footing_y = 6, 2.0
    for i in range(1, len(wps)):
        a_, b_ = wps[i - 1], wps[i]
        if i % pier_every or (gap_from <= a_.station <= gap_to):
            continue
        mid = routelib.mul(routelib.add(a_.pos, b_.pos), 0.5)
        pier_h = max(16.0, mid[1] - 8.0)
        lowest = min(mid[1] - 4.5 - pier_h, footing_y - 4.0)
        ground = ground_at(mid[0], mid[2])
        for st_a, st_b, top in abut:
            if st_a <= (a_.station + b_.station) / 2 <= st_b:
                ground = max(ground, top)
        assert ground >= lowest - 0.5, f"kit pier {i} at st {a_.station:.0f} hangs: ground {ground:.1f} < {lowest:.1f}"

    # ---------------------------------------------------------------- city towers (seeded) and the Star Spire
    # hero spire: inside the loop, ahead-right of the start grid (12-38 degrees off the heading, 350-800 studs out) so
    # the first gameplay view frames it beyond the vault; as far from the road as that window allows
    fh = route.frame_at(20.0)
    head = math.atan2(fh.tangent[0], -fh.tangent[2])
    best = None
    for ia in range(0, 27):
        for ir in range(0, 46):
            bearing = head + math.radians(12 + ia)
            rng_ = 350 + ir * 10
            x = fh.pos[0] + math.sin(bearing) * rng_
            z = fh.pos[2] - math.cos(bearing) * rng_
            d_road, _, _ = poly.nearest(x, z)
            if d_road < 130 or abs(z - z_v) < 90:
                continue
            score = d_road - 2.0 * abs(ia - 13)
            if best is None or score > best[0]:
                best = (score, x, z)
    assert best is not None
    spire_pos = (best[1], ground_at(best[1], best[2]) - 4.0, best[2])
    prefabs["StarSpireTower"] = star_spire()
    place("StarSpireTower", spire_pos, "Landmarks", 0.0)

    tower_kinds = []
    for pi, pal in enumerate(PAL):
        tower_kinds.append(("CityTower_Setback#%d_%d" % (pi, 150), tower_setback(150, pal), 33.0, 3))
        tower_kinds.append(("CityTower_Setback#%d_%d" % (pi, 215), tower_setback(215, pal), 33.0, 4))
        tower_kinds.append(("CityTower_Slab#%d_%d" % (pi, 110), tower_slab(110, pal), 35.0, 2))
        tower_kinds.append(("CityTower_Spire#%d_%d" % (pi, 190), tower_spire(190, pal), 25.0, 3))
        tower_kinds.append(("CityTower_Twin#%d_%d" % (pi, 165), tower_twin(165, pal), 34.0, 3))
        tower_kinds.append(("CityDome_Hall#%d" % pi, dome_hall(pal), 46.0, 1))
        tower_kinds.append(("CityBlock_Low#%d" % pi, low_block(48, 40, 34, pal), 32.0, 0))
    placed = [(spire_pos[0], spire_pos[2], 60.0)]
    skipped_towers: list[tuple[float, float]] = []
    tower_rng = random.Random(SEED + 3)
    cand = []
    step_c = 72.0
    zx0, zx1 = x_min - (TERRAIN_MARGIN - 60), x_max + (TERRAIN_MARGIN - 60)  # podiums stay on the grid
    zz0, zz1 = min(zs_all) - (TERRAIN_MARGIN - 60), max(zs_all) + (TERRAIN_MARGIN - 60)
    zz = zz0
    while zz <= zz1:
        xx = zx0
        while xx <= zx1:
            cand.append((xx + tower_rng.uniform(-18, 18), zz + tower_rng.uniform(-18, 18)))
            xx += step_c
        zz += step_c
    tower_rng.shuffle(cand)
    for cx, cz in cand:
        in_city = cz < z_v + 40 or (cx < x_start + CITY_EAST_OF_START - 50 and cz < z_start + 140)
        if not in_city:
            continue
        d_road, _, _ = poly.nearest(cx, cz)
        far = d_road > 200
        tier = 0 if (far and tower_rng.random() < 0.4) else (1 if d_road > 120 else 3)
        options = [k for k in tower_kinds if (k[3] <= 1 if tier == 0 else (k[3] >= 1 if tier == 1 else k[3] >= 2))]
        kind = options[tower_rng.randrange(len(options))]
        key, pf, rad = kind[0], kind[1], kind[2]
        if d_road < rad + 46.0:
            continue
        if abs(cz - z_v) < rad + 14.0:
            continue
        if any(math.hypot(cx - a, cz - b) < rad + rb + 10.0 for a, b, rb in placed):
            continue
        g = ground_at(cx, cz)
        prefabs.setdefault(key, pf)
        yaw = float(tower_rng.choice((0.0, 90.0, 180.0, 270.0)))
        placed.append((cx, cz, rad))
        if any(math.hypot(cx - fx_, cz - fz_) < rad + fr_ + 4.0 for fx_, fz_, fr_ in roof.footprints):
            skipped_towers.append((cx, cz))  # the rooftop line's blocks stand here; the draw sequence stays the same
            continue
        place(key, (cx, g - 3.0, cz), "City", yaw)
    tower_count = len(placed) - 1 - len(skipped_towers)

    # ---------------------------------------------------------------- Wave 2: downtown stone-arch viaduct (critic v29 2.2)
    # Gateways every DT_STEP from DT_FROM to DT_TO, square to the route (unbanked, level), each on two pier shafts that
    # stand outside the parapets; deck chords join the crowns; the invisible MonorailSlot waits on the beam for the
    # Wave 2 monorail mesh. All nc: the road, the parapets (the car's walls), the corridor and the rescue are untouched.
    dt_stations = []
    st = DT_FROM
    while st <= DT_TO + 1e-6:
        dt_stations.append(st)
        st += DT_STEP
    prefabs["DowntownViaductGate"] = dt_gate_prefab(False)
    prefabs["DowntownViaductGate_Lantern"] = dt_gate_prefab(True)
    dt_crowns, dt_piers, dt_lanterns = [], [], 0
    dt_clear = {"pierLateralMin": 1e9, "intradosOverRoadEdgeMin": 1e9, "deckOverRibbonMin": 1e9,
                "shaftLengthMin": 1e9, "shaftLengthMax": 0.0}
    xc = DT_PIER_IN + DT_PIER_W / 2
    for i, st in enumerate(dt_stations):
        f = route.frame_at(st)
        look = routelib.unit((f.tangent[0], 0.0, f.tangent[2]))
        right = routelib.unit(routelib.cross(look, routelib.UP))
        r = yxz_from_axes(right, routelib.UP, look)
        lit = i % DT_LANTERN_EVERY == 1
        dt_lanterns += 1 if lit else 0
        place("DowntownViaductGate_Lantern" if lit else "DowntownViaductGate", f.pos, "Landmarks/DowntownViaduct", r)
        dt_crowns.append(routelib.add(f.pos, (0.0, DT_DECK, 0.0)))
        for s_ in (-1.0, 1.0):
            px, pz = f.pos[0] + right[0] * s_ * xc, f.pos[2] + right[2] * s_ * xc
            g = ground_at(px, pz) - 3.0
            top = f.pos[1] + DT_SHAFT_TOP + 0.5
            ln = math.ceil(top - g)
            key = "DowntownViaductShaft#%03d" % ln
            prefabs.setdefault(key, dt_shaft_prefab(float(ln)))
            place(key, (px, top - ln, pz), "Landmarks/DowntownViaduct", r)
            dt_piers.append((px, pz, 0.5 * math.hypot(DT_PIER_W + 3.2, DT_GATE_DEPTH + 2.4)))
            d_pier, _, _ = poly.nearest(px, pz)
            dt_clear["pierLateralMin"] = min(dt_clear["pierLateralMin"], d_pier - DT_PIER_W / 2 - 0.8)
            dt_clear["shaftLengthMin"] = min(dt_clear["shaftLengthMin"], ln)
            dt_clear["shaftLengthMax"] = max(dt_clear["shaftLengthMax"], ln)
            # intrados height over the deck's edge (lateral 22, banked road surface) at this gateway
            edge = offset_point(route, st, s_ * DECK_WIDTH / 2, PAVER_TOP)
            lat_e = abs(routelib.dot(routelib.sub(edge, f.pos), right))
            y_in = f.pos[1] + DT_SPRING + math.sqrt(max(0.0, DT_PIER_IN ** 2 - lat_e ** 2))
            dt_clear["intradosOverRoadEdgeMin"] = min(dt_clear["intradosOverRoadEdgeMin"], y_in - edge[1])
        dt_clear["deckOverRibbonMin"] = min(dt_clear["deckOverRibbonMin"], DT_DECK)
    for a, b in zip(dt_crowns, dt_crowns[1:]):
        look = routelib.unit(routelib.sub(b, a))
        right = routelib.unit(routelib.cross(look, routelib.UP))
        up = routelib.unit(routelib.cross(right, look))
        ln = bucket(routelib.mag(routelib.sub(b, a)), 0.5)
        key = "DowntownViaductDeck#%05.1f" % ln
        prefabs.setdefault(key, dt_deck_prefab(ln))
        place(key, routelib.mul(routelib.add(a, b), 0.5), "Landmarks/DowntownViaduct", yxz_from_axes(right, up, look))
    # the deck between gateways is a straight chord: its lowest point over the road is the lower crown, minus the
    # chord's sag below the route on the NE sweeper (the deck rides above the ribbon line there)
    fs = route.frame_at(DT_SLOT_STATION)
    look_s = routelib.unit((fs.tangent[0], 0.0, fs.tangent[2]))
    right_s = routelib.unit(routelib.cross(look_s, routelib.UP))
    prefabs["MonorailSlot"] = monorail_slot_prefab()
    k_slot = max(i for i, s0 in enumerate(dt_stations) if s0 <= DT_SLOT_STATION)
    ya, yb = dt_crowns[k_slot][1], dt_crowns[k_slot + 1][1]
    tt = (DT_SLOT_STATION - dt_stations[k_slot]) / DT_STEP
    slot_pos = (fs.pos[0], ya + (yb - ya) * tt + (DT_BEAM_TOP - DT_DECK), fs.pos[2])
    place("MonorailSlot", slot_pos, "Landmarks/DowntownViaduct", yxz_from_axes(right_s, routelib.UP, look_s))
    downtown_viaduct = {
        "stations": dt_stations, "gateways": len(dt_stations), "lanterns": dt_lanterns, "deckSpans": len(dt_crowns) - 1,
        "slot": {"station": DT_SLOT_STATION, "pos": [r2(v) for v in slot_pos], "size": list(DT_SLOT_SIZE)},
        "clearances": {k: r2(v) for k, v in dt_clear.items()},
        "heights": {"spring": DT_SPRING, "intradosCrown": DT_SPRING + DT_PIER_IN, "deckBottom": DT_DECK,
                    "beamTop": DT_BEAM_TOP, "pierInnerFace": DT_PIER_IN},
    }

    # ---------------------------------------------------------------- space-neon holograms and billboards (client-built)
    # src/client/SpaceNeon.luau builds these at runtime from the layout written to src/shared/SpaceNeonLayout.luau (visual
    # only: CanCollide/CanQuery/CanTouch false, no map Instances). Placement rule (shared/SpaceNeonRules.reach, spec'd in
    # tools/tests/space_neon_spec.luau and tools/map/tests/test_space4.py): a figure's feet stand at least reach + HOLO_CLEAR
    # studs (plan view) from the race line and from the Alt1 chord, so even its leaning head and swinging hands stay
    # HOLO_CLEAR studs from the road axis (the parapets are at 26): nothing reaches the corridor or the wall surfaces.
    holo_rng = random.Random(SEED + 40)
    holos = []
    # v29 A8: the st. 560 (start straight) and st. 4450 (final straight) figures are gone; the other three are capped
    # at HOLO_MAX_H and kept HOLO_CLEAR back (behind the first tower row).
    for want_st, hh, lean in ((1500.0, 96.0, 36.0), (2650.0, 132.0, 42.0), (3500.0, 104.0, 38.0)):
        hh = min(hh, HOLO_MAX_H) - (0.0 if hh >= 120.0 else 4.0)  # keep the old size order (tallest at 2650)
        reach = HOLO_K_LEAN * hh * math.sin(math.radians(lean)) + HOLO_K_ARM * hh
        done = False
        for lat in range(int(reach + HOLO_CLEAR), int(reach + HOLO_CLEAR) + 200, 10):
            for side in (1.0, -1.0):
                for dst in (0.0, 40.0, -40.0, 80.0, -80.0):
                    f = route.frame_at(want_st + dst)
                    q = offset_point(route, want_st + dst, side * lat, 0.0)
                    x, z = q[0], q[2]
                    d_route, _, _ = poly.nearest(x, z)
                    if d_route < reach + HOLO_CLEAR or chord_distance(x, z) < reach + HOLO_CLEAR - 20:
                        continue
                    if roof.dist(x, z) < reach + RT_HOLO_CLEAR + RT_HALF_OUTER:  # the rooftop line (SpaceNeon stays clear)
                        continue
                    if any(math.hypot(x - a, z - b) < rb + 26.0 for a, b, rb in placed):
                        continue
                    if any(math.hypot(x - c[0], z - c[2]) < mr + 30.0 for c, mr, _ in mesa):
                        continue
                    if any(math.hypot(x - cx, z - cz) < cr + 14.0 for cx, cz, cr, _ in craters):
                        continue
                    if any(math.hypot(x - o[0], z - o[2]) < 220.0 for o in [h["pos"] for h in holos]):
                        continue
                    # face the road: toward the nearest route point
                    _, st_n, _ = poly.nearest(x, z)
                    fn = route.frame_at(st_n)
                    toward = (fn.pos[0] - x, 0.0, fn.pos[2] - z)
                    holos.append({"pos": (r2(x), r2(ground_at(x, z)), r2(z)), "yaw": yaw_of(toward), "h": hh, "lean": lean,
                                  "palette": len(holos) % 4, "phase": r2(holo_rng.uniform(0, 6.28)),
                                  "station": r2(want_st + dst), "dRoute": r2(d_route), "reach": r2(reach)})
                    done = True
                    break
                if done:
                    break
            if done:
                break
    assert len(holos) >= 3, f"holograms placed: {len(holos)}"
    boards = []
    board_keep_out = [(TUNNEL_FROM - 80, TUNNEL_TO + 80), (s_join - 80, s_rejoin + 80), (gap_from - 150, gap_to + 80),
                      (-1, 120), (length - 120, length + 1)]
    for want_st in (700.0, 1100.0, 1750.0, 2150.0, 2500.0, 3000.0, 3750.0, 4350.0, 4650.0):
        st_b = next((want_st + d for d in (0.0, 50.0, -50.0, 100.0, -100.0) if not in_ranges(want_st + d, board_keep_out)), None)
        if st_b is None or len(boards) >= 4:  # v29 A8: at most 4 (moving the figures back freed room for 6 more neon boards)
            continue
        side0 = 1.0 if len(boards) % 2 == 0 else -1.0
        roof_blocked = False
        done = False
        for side in (side0, -side0):
            if side != side0 and not roof_blocked:
                break  # the opposite side is tried only when the rooftop line was what ruled the first one out
            for lat in (100.0, 125.0, 150.0):
                fb = route.frame_at(st_b)
                rgt, _ = banked_axes(fb)
                away = routelib.mul(rgt, side)
                pos = routelib.add(routelib.add(fb.pos, routelib.mul(away, lat)), (0.0, BOARD_RISE, 0.0))
                if any(math.hypot(pos[0] - a, pos[2] - b) < rb + 8.0 for a, b, rb in placed):
                    continue
                if any(math.hypot(pos[0] - h["pos"][0], pos[2] - h["pos"][2]) < 90.0 for h in holos):
                    continue
                if roof.dist(pos[0], pos[2]) < BOARD_W / 2 + RT_BOARD_CLEAR + RT_HALF_OUTER:
                    roof_blocked = True
                    continue
                tang = routelib.unit((fb.tangent[0], 0.0, fb.tangent[2]))
                n = routelib.unit(routelib.add(routelib.mul(tang, -math.cos(math.radians(BOARD_TOE))),
                                               routelib.mul(away, -math.sin(math.radians(BOARD_TOE)))))
                boards.append({"pos": (r2(pos[0]), r2(pos[1]), r2(pos[2])), "yaw": yaw_of(n), "w": BOARD_W, "h": BOARD_H,
                               "palette": len(boards) % 4, "text": len(boards), "station": r2(st_b), "lateral": lat})
                done = True
                break
            if done:
                break
    assert len(boards) >= 4, f"billboards placed: {len(boards)}"
    neon_layout = {"holograms": holos, "billboards": boards}

    # v28 critic 1.24: a far tower skyline beyond the crater bulge (captures space4_07/11: an empty horizon over the
    # crater run). Existing tower kits, 800-1500 studs out on the side away from the course centre, bases sunk below the
    # horizon. All nc and far outside every road, wall and climb; own rng, so nothing placed above moves.
    sky_rng = random.Random(SEED + 61)
    ccx = sum(w.pos[0] for w in wps) / len(wps)
    ccz = sum(w.pos[2] for w in wps) / len(wps)
    tall = [k for k in tower_kinds if k[3] >= 3]
    gxmax, gzmax = gx0 + (nx - 1) * CELL, gz0 + (nz - 1) * CELL
    skyline = 0
    for lb in ("bulge1", "bulge2", "bulge3"):
        for t in (0.2, 0.55, 0.9):
            fsk = route.frame_at(station_of_design(lb, t))
            rgt = routelib.unit((fsk.right[0], 0.0, fsk.right[2]))
            side = 1.0 if (fsk.pos[0] - ccx) * rgt[0] + (fsk.pos[2] - ccz) * rgt[2] >= 0 else -1.0
            dist = sky_rng.uniform(800.0, 1500.0)
            bx, bz = fsk.pos[0] + rgt[0] * side * dist, fsk.pos[2] + rgt[2] * side * dist
            for j in range(2):
                ox, oz = (0.0, 0.0) if j == 0 else (sky_rng.uniform(-90, 90), sky_rng.uniform(-90, 90))
                x, z = bx + ox, bz + oz
                if min(math.hypot(x - h["pos"][0], z - h["pos"][2]) for h in holos) < 300.0:
                    continue
                kind = tall[sky_rng.randrange(len(tall))]
                prefabs.setdefault(kind[0], kind[1])
                inside = gx0 + 20 < x < gxmax - 20 and gz0 + 20 < z < gzmax - 20
                y = ground_at(x, z) - 3.0 if inside else -40.0
                place(kind[0], (x, y, z), "City", float(sky_rng.choice((0.0, 90.0, 180.0, 270.0))),
                      r4(sky_rng.uniform(1.2, 1.6)))
                skyline += 1

    # ---------------------------------------------------------------- set dressing and night fx (L61)
    lib = prop_library()
    dress_rng = random.Random(SEED + 5)
    dressing: list[dict] = []
    taken: list[tuple[float, float, float]] = []  # (x, z, radius) of props already placed
    turn_labels = ("nw", "city1", "city3", "ne", "se", "bulge1", "bulge2", "bulge3", "sw")
    turn_ranges = [(station_of_design(lb, 0.0), station_of_design(lb, 1.0), BANK.get(lb, 0.0), lb) for lb in turn_labels]
    station_l = station_of_design("start", 0.0)
    keep_out_st = [(deck_end - 40.0, deck_resume + 40.0)] + [(a - 40, b + 40) for a, b in fork_open] + \
        [(s - 45, s + 45) for s, _, _ in crossings]
    stations_xz = [(piers[0] - 18.0, z_v), (piers[-1] + 18.0, z_v)]

    def free_spot(x: float, z: float, rad: float) -> bool:
        if abs(z - z_v) < rad + 18.0:  # viaduct piers and arches
            return False
        if any(math.hypot(x - a, z - b) < rad + 26.0 for a, b in stations_xz):
            return False
        if any(math.hypot(x - a, z - b) < rad + rb + 8.0 for a, b, rb in placed):  # tower podiums, the spire
            return False
        if any(math.hypot(x - mc[0], z - mc[2]) < mr + rad + 10.0 for mc, mr, _ in mesa):
            return False
        if chord_distance(x, z) < rad + 70.0:
            return False
        if any(math.hypot(x - a, z - b) < rad + rb + 3.0 for a, b, rb in taken):
            return False
        g = ground_at(x, z)
        if g < PLAIN_Y - 7.0:  # the rift and the deepest crater floors
            return False
        d_road, _, _ = poly.nearest(x, z)
        return d_road >= WALL_LATERAL + 6.0 + rad

    def add_prop(key: str, x: float, z: float, yaw: float, scale: float) -> bool:
        sx, sy, sz, _ = lib[key]
        rad = 0.5 * math.hypot(sx, sz) * scale
        if not free_spot(x, z, rad):
            return False
        dressing.append({"key": key, "pos": [r2(x), r2(ground_at(x, z) + 2.0), r2(z)], "yaw": r2(yaw % 360.0),
                         "scale": r2(scale), "snap": True})
        taken.append((x, z, rad))
        return True

    def face_road_yaw(x: float, z: float) -> float:
        """Yaw that turns a prop's front (+Z) toward the nearest road point."""
        _, st_n, _ = poly.nearest(x, z)
        q = route.frame_at(st_n).pos
        return math.degrees(math.atan2(q[0] - x, q[2] - z))

    def road_y_minus_ground(st: float, lat: float) -> float:
        q = offset_point(route, st, lat, 0.0)
        return q[1] - ground_at(q[0], q[2])

    # 1. turn clusters on the outside of every turn (tech yards with a neon sign facing the apex)
    yard = ["space_fuel_tanks", "space_cargo_container", "space_antenna_dish", "space_rover", "space_cargo_container",
            "space_moon_rock_cluster", "space_crystal_formation"]
    for a_st, b_st, bank, lb in turn_ranges:
        f_mid = route.frame_at((a_st + b_st) / 2)
        f_a = route.frame_at(a_st)
        turn_sign = 1.0 if routelib.dot(routelib.sub(route.frame_at(b_st).tangent, f_a.tangent), f_a.right) > 0 else -1.0
        outside = -turn_sign
        n_spots = 3 if b_st - a_st < 200 else 4
        for k in range(n_spots):
            st = a_st + (b_st - a_st) * (k + 0.5) / n_spots
            if in_ranges(st, keep_out_st):
                continue
            lat0 = outside * dress_rng.uniform(40.0, 52.0)
            q = offset_point(route, st, lat0, 0.0)
            if k == n_spots // 2:
                add_prop("space_neon_sign_frame", q[0], q[2], face_road_yaw(q[0], q[2]), dress_rng.uniform(1.1, 1.3))
            else:
                add_prop(dress_rng.choice(yard), q[0], q[2], dress_rng.uniform(0, 360), dress_rng.uniform(0.85, 1.2))
            for _ in range(2):
                lat = lat0 + outside * dress_rng.uniform(12.0, 26.0)
                q2 = offset_point(route, st + dress_rng.uniform(-14, 14), lat, 0.0)
                add_prop(dress_rng.choice(yard), q2[0], q2[2], dress_rng.uniform(0, 360), dress_rng.uniform(0.8, 1.15))

    # 2. road-edge line where the road is near the ground (the car sees it), alternating tech and moon rock
    edge_mix = ["space_moon_rock_cluster", "space_crystal_formation", "space_rover", "space_antenna_dish",
                "space_fuel_tanks", "space_moon_rock_cluster", "space_cargo_container", "space_neon_sign_frame"]
    st = 30.0
    k = 0
    while st < length - 30:
        for side in (-1.0, 1.0):
            if in_ranges(st, keep_out_st) or dress_rng.random() < 0.15:
                continue
            lat = side * dress_rng.uniform(36.0, 56.0)
            if road_y_minus_ground(st, lat) > 16.0:
                continue
            q = offset_point(route, st + dress_rng.uniform(-8, 8), lat, 0.0)
            key = edge_mix[k % len(edge_mix)]
            k += 1
            yaw = face_road_yaw(q[0], q[2]) if key == "space_neon_sign_frame" else dress_rng.uniform(0, 360)
            add_prop(key, q[0], q[2], yaw, dress_rng.uniform(0.85, 1.25))
            # an outer row for depth (rock and crystal, sometimes a dish)
            lat2 = side * dress_rng.uniform(72.0, 110.0)
            q2 = offset_point(route, st + dress_rng.uniform(-16, 16), lat2, 0.0)
            key2 = dress_rng.choice(("space_moon_rock_cluster", "space_crystal_formation", "space_moon_rock_cluster",
                                     "space_antenna_dish"))
            add_prop(key2, q2[0], q2[2], dress_rng.uniform(0, 360), dress_rng.uniform(0.95, 1.3))
        st += 36.0

    # 3. crystal groves in the crater bowls (they glow: fx lights below)
    groves = []
    for cx, cz, r, depth in craters:
        n = 3 + int(r // 25)
        for j in range(n):
            a = 2 * math.pi * j / n + dress_rng.uniform(-0.3, 0.3)
            rr = r * dress_rng.uniform(0.15, 0.55)
            x, z = cx + math.cos(a) * rr, cz + math.sin(a) * rr
            if add_prop("space_crystal_formation", x, z, dress_rng.uniform(0, 360), dress_rng.uniform(0.9, 1.3)):
                groves.append((x, z))
        add_prop("space_moon_rock_cluster", cx + r * 0.9, cz, dress_rng.uniform(0, 360), 1.2)

    # 4. plaza tech yards in the city (hover pads with cargo and tanks), and plain scatter in the wilds
    yards = 0
    for _ in range(700):
        if yards >= 16:
            break
        x = dress_rng.uniform(x_min - 200, x_max + 200)
        z = dress_rng.uniform(min(zs_all) - 200, z_v - 30)
        if not (40.0 < poly.nearest(x, z)[0] < 260.0):
            continue
        if add_prop("space_hover_pad", x, z, dress_rng.choice((0.0, 45.0)), dress_rng.uniform(0.95, 1.2)):
            yards += 1
            for key in ("space_cargo_container", "space_fuel_tanks", "space_antenna_dish"):
                a = dress_rng.uniform(0, 2 * math.pi)
                add_prop(key, x + math.cos(a) * 22, z + math.sin(a) * 22, dress_rng.uniform(0, 360), dress_rng.uniform(0.85, 1.1))
    scatter = 0
    for _ in range(1500):
        if scatter >= 110:
            break
        x = dress_rng.uniform(x_min - 260, x_max + 260)
        z = dress_rng.uniform(z_v + 60, max(zs_all) + 300)
        if poly.nearest(x, z)[0] < 70.0:
            continue
        key = "space_moon_rock_cluster" if dress_rng.random() < 0.6 else "space_crystal_formation"
        if add_prop(key, x, z, dress_rng.uniform(0, 360), dress_rng.uniform(0.9, 1.3)):
            scatter += 1
            if key == "space_crystal_formation":
                groves.append((x, z))

    if ROOFTOP_SHORTCUT:  # the rooftop blocks and lanes stand here (no draw is spent: the filter runs after every placement)
        dressing = [d for d in dressing if roof.dist(d["pos"][0], d["pos"][2]) >= RT_FOOT_R + 14.0]

    # Wave 2: no prop inside a downtown viaduct pier footing (filtered after the draws, so every other prop keeps its spot)
    dressing = [d for d in dressing
                if all(math.hypot(d["pos"][0] - px, d["pos"][2] - pz) >= pr + 0.5 * math.hypot(lib[d["key"]][0], lib[d["key"]][2])
                       * d["scale"] + 2.0 for px, pz, pr in dt_piers)]

    # the compile gate's corridor boxes: drop anything whose whole box reaches them (none expected at these offsets)
    if dressing:
        boxes = [prop_aabb(lib[d["key"]], d["pos"], d["yaw"], d["scale"]) for d in dressing]
        hits = corridor_hits(wps, np.array([b[0] for b in boxes]), np.array([b[1] for b in boxes]), PROP_MARGIN)
        dressing = [d for d, h in zip(dressing, hits) if not h]

    # night fx: glow lights on crystals, signs and pads; slow glints over the crystal groves; searchlights over the city
    sparkle = fx_texture("sparkle_star_4x4")
    glow_cols = ("#ff5ad2", "#59ecff", "#b07cff")
    dress_fx: list[dict] = []
    n_light = 0
    for i, d in enumerate(dressing):
        x, y, z = d["pos"]
        if d["key"] == "space_crystal_formation" and n_light < 60:
            col = glow_cols[i % 3]
            dress_fx.append({"class": "PointLight", "name": "CrystalGlow", "cf": cf_at(x, y + 8.0, z), "group": "MoonPlain",
                             "props": {"Brightness": 3.0, "Range": 22, "Color": col, "Shadows": False}})
            n_light += 1
        elif d["key"] in ("space_neon_sign_frame", "space_hover_pad") and n_light < 60:
            dress_fx.append({"class": "PointLight", "name": "SignGlow" if "sign" in d["key"] else "PadGlow",
                             "cf": cf_at(x, y + 7.0, z), "group": "MoonPlain",
                             "props": {"Brightness": 2.4, "Range": 18, "Color": "#59ecff" if i % 2 else "#ff7ac8",
                                       "Shadows": False}})
            n_light += 1
    for j, (x, z) in enumerate(groves[:24]):
        dress_fx.append({"class": "ParticleEmitter", "name": "CrystalGlints", "cf": cf_at(x, ground_at(x, z) + 9.0, z),
                         "size": [14, 12, 14], "group": "MoonPlain",
                         "props": {"Texture": sparkle, "FlipbookLayout": "Grid4x4", "FlipbookMode": "Loop",
                                   "FlipbookFramerate": [24, 24], "FlipbookStartRandom": True, "Rate": 3,
                                   "Lifetime": [1.2, 2.0], "Speed": [0.5, 1.5], "SpreadAngle": [180, 180],
                                   "Color": glow_cols[j % 3], "LightEmission": 1, "Size": {"seq": [[0, 0, 0], [0.3, 1.6, 0], [1, 0, 0]]},
                                   "Transparency": {"seq": [[0, 0.2, 0], [1, 1, 0]]}, "EmissionDirection": "Top"}})
    # searchlights: six slanted beams sweeping up from tower tops around the city (static; FaceCamera ribbons)
    beam_rng = random.Random(SEED + 6)
    tall = [pp for pp in placed[1:] if poly.nearest(pp[0], pp[1])[0] > 140]
    beam_rng.shuffle(tall)
    tall = [pp for pp in tall if (pp[0], pp[1]) not in skipped_towers]
    for j, (bx, bz, _) in enumerate(tall[:6]):
        gy = ground_at(bx, bz)
        tilt_a = beam_rng.uniform(0, 2 * math.pi)
        top = (bx + math.cos(tilt_a) * 260, gy + 900, bz + math.sin(tilt_a) * 260)
        col = ("#9a5cff", "#59ecff", "#ff7ac8")[j % 3]
        dress_fx.append({"class": "Beam", "name": "CitySearchlight", "a0": [r2(bx), r2(gy + 120), r2(bz)],
                         "a1": [r2(v) for v in top], "group": "City",
                         "props": {"Width0": 5, "Width1": 28, "Color": col, "LightEmission": 0.6, "FaceCamera": True,  # v28 W1.3: under 15% opaque, narrower
                                   "Transparency": {"seq": [[0, 0.88, 0], [0.6, 0.94, 0], [1, 1, 0]]}, "Segments": 1}})
    # each skyway arch keystone sheds slow sparkles over its road (small, sparse: never a curtain over the route)
    for i, st_a in enumerate(arch_stations):
        q = offset_point(route, st_a, 0.0, CAP_TOP + 4.0 + SKYWAY_B)
        dress_fx.append({"class": "ParticleEmitter", "name": "ArchSparkle", "cf": cf_at(*q), "size": [30, 2, 4],
                         "group": "Highway/Gantries",
                         "props": {"Texture": sparkle, "FlipbookLayout": "Grid4x4", "FlipbookMode": "Loop",
                                   "FlipbookFramerate": [24, 24], "FlipbookStartRandom": True, "Rate": 5,
                                   "Lifetime": [2.0, 3.0], "Speed": [3, 6], "SpreadAngle": [25, 25],
                                   "Color": arch_cols[i % 3], "LightEmission": 1,
                                   "Size": {"seq": [[0, 0, 0], [0.2, 1.1, 0], [1, 0, 0]]},
                                   "Transparency": {"seq": [[0, 0.1, 0], [1, 1, 0]]}, "EmissionDirection": "Bottom"}})
    # the Star Spire's crown throws a cyan column into the sky
    dress_fx.append({"class": "Beam", "name": "SpireBeacon", "a0": [r2(spire_pos[0]), r2(spire_pos[1] + 290), r2(spire_pos[2])],
                     "a1": [r2(spire_pos[0]), r2(spire_pos[1] + 1300), r2(spire_pos[2])], "group": "Landmarks",
                     "props": {"Width0": 8, "Width1": 26, "Color": "#59ecff", "LightEmission": 1, "FaceCamera": True,
                               "Transparency": {"seq": [[0, 0.3, 0], [1, 1, 0]]}, "Segments": 1}})

    # ---------------------------------------------------------------- gameplay
    def avoid(st: float, ranges: list[tuple[float, float]], nudge: float) -> float:
        for a, b in ranges:
            if a <= st <= b:
                return round(b + nudge, 1)
        return round(st, 1)

    # every 400 studs, none on the bulge Alt1 bypasses (one just before the fork, one after the rejoin) and none
    # near the rift (a respawn frame must sit over road)
    no_cp = [(gap_from - 30, gap_to + 30)]
    stations = []
    st = 0.0
    while st < length - 200:
        if not (s_join - 120 <= st <= s_rejoin + 120):
            stations.append(avoid(st, no_cp, 32.0))
        st += 400.0
    stations += [round(s_join - 15.0, 1), avoid(s_rejoin + 25.0, no_cp, 32.0)]
    stations = sorted(set(stations))
    # keep the spacing <= 450 outside the Alt1 span (that span cannot hold a checkpoint both lines pass)
    filled = [stations[0]]
    for a, b in zip(stations, stations[1:] + [length]):
        if b - a > 450.0 and not (a <= s_join and b >= s_rejoin):
            filled.append(avoid((a + b) / 2, no_cp, 32.0))
        if b < length:
            filled.append(b)
    stations = sorted(set(round(s, 1) for s in filled))

    def sd(label: str, t: float) -> float:
        return round(station_of_design(label, t), 1)

    rings = [
        # v37: the offset start pair stood 72-96 studs ahead of the front grid row (every car boosted within 0.3 s of
        # GO, so the rocket start bought little). It now leads out of the Glass Vault (its offset frames do not fit
        # inside the vault) in place of the centred BoostGate_VaultExit: nothing boosts within 150 of the grid.
        {"name": "BoostGate_StartLeft", "station": round(TUNNEL_TO + 12.0, 1), "lateral": -9.0, "height": 3.0},
        {"name": "BoostGate_StartRight", "station": round(TUNNEL_TO + 36.0, 1), "lateral": 9.0, "height": 3.0},
        {"name": "BoostGate_Downtown", "station": sd("north2", 0.3), "lateral": 0.0, "height": 3.0},
        {"name": "BoostGate_ViaductDive", "station": round(crossings[1][0] - 70.0, 1), "lateral": 0.0, "height": 3.0},
        {"name": "BoostGate_CraterRun", "station": sd("south1", 0.4), "lateral": 0.0, "height": 3.0},
        {"name": "BoostGate_RiftKicker", "station": round(gap_from - 95.0, 1), "lateral": 0.0, "height": 3.0},
        {"name": "BoostGate_SkywayClimb", "station": sd("climb", 0.7), "lateral": 0.0, "height": 3.0},
    ]
    for r in rings:
        r.update(coin=False, coinId=None)
    # Wave 2 (critic v29 2.1): an octagonal portal frame around every boost gate, on the ring's own frame (frames only,
    # nc; the kit ring, its trigger and the gate stations are unchanged). Under Highway/Gantries so client/CameraFade
    # fades a frame side when the chase camera passes beside it.
    # An offset gate (the start pair, lateral -+9) opens the side that faces the road centre: that post would stand
    # on the other start gate's drive line.
    prefabs["GatePortalFrame"] = gate_portal_prefab()
    prefabs["GatePortalFrame_OpenRight"] = gate_portal_prefab(1)
    prefabs["GatePortalFrame_OpenLeft"] = gate_portal_prefab(-1)
    for r in rings:
        fr_ = route.frame_at(r["station"])
        key = "GatePortalFrame" if abs(r["lateral"]) < 1.0 else \
            ("GatePortalFrame_OpenRight" if r["lateral"] < 0 else "GatePortalFrame_OpenLeft")
        place(key, offset_point(route, r["station"], r["lateral"], r["height"]),
              "Highway/Gantries/GatePortals", yxz_from_axes(*banked_axes(fr_), fr_.tangent))
    pads = [
        # S4-06: was GroundBoost_DowntownEntry at north1 0.25, which boosted cars into the R~95-110 city1 right-hander
        # (boosted grip radius 124) and onto its outer parapet; at the north2 entry it chains with BoostGate_Downtown
        {"name": "GroundBoost_DowntownExit", "station": sd("north2", 0.02), "lateral": 0.0},
        {"name": "GroundBoost_EastDescent", "station": sd("east", 0.62), "lateral": 0.0},
        {"name": "GroundBoost_RiftApproach", "station": round(gap_from - 150.0, 1), "lateral": 0.0},
        {"name": "GroundBoost_SkywayClimb", "station": sd("sw", 0.85), "lateral": 0.0},
    ]
    # Item cubes v3 (docs/design/ITEM_BOXES.md; rules in tools/map/item_cubes.json): 8 staggered sets of 5 mystery
    # cubes (front rank +-6, back rank -12/0/+12 32 studs on: the city road is irregular, so narrower than the other
    # car maps), every 476-690 studs. Fixed race stations of the front rank in free stretches: the Glass Vault, the
    # city approach, the city turn, the north straight, before the viaduct dive, the crater run, inside the Alt1 span
    # (the mesa tunnel line trades it for the shortcut) and the SW sweeper after the rift landing (lands at ~4228; the
    # run-up pad to 4300 stays clear). The two v2 Speed singles 60 after a row became their set's fifth cube; the
    # Speed pickups (mint boost blocks) moved mid-gap. The Skyway single was never next to a set and stays.
    pod_rows = [(330.0, "VaultRow"), (900.0, "CityRow"), (1450.0, "CityTurnRow"), (2004.0, "NorthRow"),
                (2480.0, "EastRow"), (3100.0, "CraterRow"), (3750.0, "MesaRow"), (4440.0, "SkywayRow")]
    set_st = [st for st, _ in pod_rows]
    pods = []
    for k, (st, name) in enumerate(pod_rows):
        pods += item_rows.cube_set("car", "space4", k, st, 4.5, lambda t, j, name=name: f"{name}_{t}Pod_{j}", name)
    for st, name in ((item_rows.gap_single("car", set_st, 1, route.length), "CitySingle"),
                     (item_rows.gap_single("car", set_st, 3, route.length), "NorthSingle"), (sd("climb", 0.2), "SkywaySingle")):
        pods.append(item_rows.speed_single(f"{name}_SpeedPod", st, 4.5))
    item_rows.assert_layout({"pods": pods}, "car", "space4", route.length)
    for p in pods:  # never on the rift jump: run-up pad to past the landing
        assert not (gap_from - 160.0 <= p["station"] <= deck_resume + 80.0), p

    # coin challenge: 8 coins, one inside the Alt1 tunnel (projected onto the race line as station/lateral)
    a_coin = alt_pts[len(alt_pts) // 2]
    ast, alat, ah = project(route, poly, (a_coin[0], a_coin[1], a_coin[2]))
    coins = [
        # S4-07: was st 70, 3.6 studs from grid slot 8 (collected during the countdown); now past the start gates
        {"id": 1, "station": 140.0, "lateral": 12.0, "height": 4.5, "line": "main"},
        {"id": 2, "station": round(TUNNEL_FROM + 110.0, 1), "lateral": -14.0, "height": 4.5, "line": "main"},
        {"id": 3, "station": sd("city1", 0.5), "lateral": 13.0, "height": 4.5, "line": "main"},
        {"id": 4, "station": sd("ne", 0.5), "lateral": -14.0, "height": 4.5, "line": "main"},
        {"id": 5, "station": round(crossings[1][0], 1), "lateral": 13.0, "height": 4.5, "line": "main"},
        {"id": 6, "station": round(ast, 1), "lateral": round(alat, 1), "height": round(ah + 4.8, 1),
         "line": "Alt1", "pos": [r2(a_coin[0]), r2(a_coin[1] + 1.8 + 3.0), r2(a_coin[2])]},
        {"id": 7, "station": round(gap_from + 10.0, 1), "lateral": 0.0, "height": 7.0, "line": "main",
         "note": "mid-air over the rift: on the jump arc of a car that clears the gap"},
        {"id": 8, "station": sd("sw", 0.5), "lateral": 14.0, "height": 4.5, "line": "main"},
    ]

    fx = dress_fx  # the vault fill and lamp lights come from routeLights and prefab lights
    alternates = [{"id": "Alt1", "points": alt_pts, "style": "tunnel", "joinStation": round(s_join, 1),
                   "rejoinStation": round(s_rejoin, 1)}]
    if ROOFTOP_SHORTCUT:
        # Alt2: the rooftop line as a course line. Style "span": RouteBranch counts a car or plane on it as on a course
        # line; the plan owns its geometry (kit/Deck builds nothing, CourseCarve skips it). Points sit 1.8 under the
        # surface like Alt1's, every second sample.
        sm_ = roof.line.samples
        pts_ = [sm_[i] for i in range(0, len(sm_), 2)]
        if pts_[-1] is not sm_[-1]:
            pts_.append(sm_[-1])
        alternates.append({"id": "Alt2", "points": [[r2(q.x), r2(q.y - 1.8), r2(q.z)] for q in pts_], "style": "span",
                           "joinStation": round(RT_ENTRY_ST, 1), "rejoinStation": round(RT_EXIT_ST + RT_EXTEND, 1)})
    gameplay = {
        "checkpoints": {"stations": stations, "size": [52, 26, 6], "heightOffset": 8},
        "rings": rings, "pads": pads, "pods": pods,
        "startGrid": {"station": 20, "height": 5, "rowSpacing": 22, "laneOffset": 11},
        "finish": {"station": 0, "radius": 40},
        "alternates": alternates,
        "coins": coins,
        "key": None,
        "modes": {},
        "boss": None,
    }

    parts_total = sum(len(prefabs[i["pf"]]["parts"]) for i in instances)
    collidable = sum(1 for i in instances for p in prefabs[i["pf"]]["parts"]
                     if not (len(p) > 12 and isinstance(p[12], dict) and p[12].get("nc")))
    plan = {
        "prefabs": {k: prefabs[k] for k in sorted(prefabs)},
        "instances": instances,
        "groups": groups,
        "terrain": terrain,
        "markers": [],
        "skyrally": {
            "archetype": "Urban grid with rooftop routes", "signatureVerb": "ride",
            "signature": "Ride the star city grid and take the rooftop routes between blocks.",
            "id": "SPACE-4", "key": "space4", "zone": "SPACE", "vehicle": "car", "laps": 3,
            "guide": "docs/guides/space4.md", "lighting": "SPACE-4",
            "route": rt,
            "deck": {"style": "space4_neon", "width": DECK_WIDTH, "zones": [], "curbHeights": CURB_HEIGHTS,
                     "gaps": [{"from": gap_from, "to": gap_to, "reason": "rift jump: kicker lip over the moonquake rift"}],
                     "piersEvery": pier_every, "pierFootingY": footing_y},
            "flight": {"lineOffset": LINE_OFFSET, "corridor": dict(CORRIDOR)},
            "gameplay": gameplay,
            "shells": {"ops": shell_ops},
            "hazards": [],
            "meshes": [],
            "modelAttributes": [{"path": "Landmarks/DowntownViaduct/MonorailSlot",
                                 "attrs": {"Placeholder": True, "SlotFor": "MonorailTrain3Car", "Wave": "W2-2.2"}}],
            "fx": fx,
            "setDressing": dressing,
            "framing": {"heroStation": 20, "note": "chase camera on the start grid facing north: boost-gate pair, "
                                                   "monorail viaduct and train overhead, Glass Vault mouth framed by "
                                                   "the central arch (20_SPACE4_STAR_CITY.png)"},
            "routeLights": {"every": 5, "fromStation": TUNNEL_FROM, "toStation": TUNNEL_TO, "offsets": [[0, 26]],
                            "color": "#fff0d6", "range": 58, "brightness": 1.1},
            "materials": {
                "terrainOverrides": {"Limestone": "SR_SPACE_MoonRock", "Pavement": "SR_SPACE_Plaza",
                                     "Salt": "SR_SPACE_MoonDust"},
                "terrainColor": "#ffffff",
                "partRules": [
                    {"name": "^Paver_", "setMaterial": "Slate", "variant": "SR_SPACE_RoadPlates"},
                    {"name": "^TrackSeg_", "setMaterial": "Metal", "variant": "SR_SPACE_BrassMachine", "color": "#e6c27a"},
                    {"name": "^Curb", "setMaterial": "DiamondPlate", "variant": "SR_SPACE_MetalPlates"},
                    {"name": "^BridgeFascia_", "setMaterial": "DiamondPlate", "variant": "SR_SPACE_MetalPlates"},
                    {"name": "^CausewayPier_", "setMaterial": "Brick", "variant": "SR_SPACE_StoneArch", "color": "#e2d4b8"},
                    {"name": "^PierFooting_", "setMaterial": "Brick", "variant": "SR_SPACE_StoneArch", "color": "#c6b698"},
                    {"name": "^Alt1Floor", "setMaterial": "Slate", "variant": "SR_SPACE_NeonRoad", "color": "#ffffff"},
                    {"name": "^Alt1Wall", "setMaterial": "Brick", "variant": "SR_SPACE_StoneArch"},
                    {"name": "^Alt1Roof", "setMaterial": "DiamondPlate", "variant": "SR_SPACE_MetalPlates"},
                    # v29 W1b A12: the ceiling strip is a painted brass rail, not Neon (nc part: material is look only)
                    {"name": "^Alt1TorchStrip_", "setMaterial": "Metal", "variant": "SR_SPACE_BrassMachine", "color": "#8a6a40"},
                    {"material": "Slate", "variant": "SR_SPACE_RoadPlates"},  # v28 1.16: the rooftop deck (bare Slate read as foil)
                    {"material": "Brick", "variant": "SR_SPACE_StoneArch"},
                    {"material": "Concrete", "variant": "SR_SPACE_StoneBlocks"},
                    {"material": "DiamondPlate", "variant": "SR_SPACE_MetalPlates"},
                    {"material": "Metal", "variant": "SR_SPACE_BrassMachine"},
                    {"material": "Plastic", "variant": "SR_SPACE_GlassPanels"},
                ],
            },
            "notes": {
                "key": "none: SPACE has no hidden key (LAUNCH_PROGRESSION 2b, N64 FACT: no fifth battle)",
                "modes": "none: no SPACE battle overlay",
                "boss": "none at launch: SPACE-4 is the endgame race + coin challenge; SPACE-BOSS is U3",
                "rings": "car boost gates: ring centre 3 studs above the ribbon (0.3 above the paver top) so the hull "
                         "(+4.5) passes through the lower opening inside CarConfig.RING_TRIGGER_RADIUS and no bottom "
                         "rim crosses the gate's centre line; the side rims (3 and 9 o'clock, 10-15 studs either side "
                         "of the ring centre) do stand on the road surface, and kit/Gameplay ring parts are "
                         "CanQuery=true while the car's ground probes use RespectCanCollide=false, so a wheel crossing "
                         "a side rim reads a ~2.3 stud step until the kit makes ring visuals CanQuery=false",
                "coins": "station/lateral/height on the race line like pods; coin 6 is on Alt1 (pos is the world "
                         "point inside the tunnel, 3 studs above its floor)",
                "alt1Aprons": "trap audit S4-01/03/04 (docs/audits/traps_space4.md): the fork parapet is open only "
                              "while its line runs inside the shortcut apron; ShortcutFunnelRail pieces (parapet "
                              "profile) close both aprons from the parapet ends to the kit tube walls at < 7 degrees, "
                              "and a wedge fills the entry gore, so nothing faces an arriving car head-on and the "
                              "inner-bulge shelf/basin is unreachable from either fork",
            },
            "provenance": {
                "author": "tools/map/author_space4.py", "seed": SEED, "origin": list(ORIGIN),
                "routeLength": round(length, 3), "routeFlexScale": round(route.flex_scale, 6),
                "waypoints": len(wps),
                "minTurnRadius": round(min_r["r"], 1), "minTurnRadiusStation": min_r["st"],
                "maxGradeDeg": round(max_grade, 2), "maxBankDeg": round(max_bank, 2),
                "jump": {"lip": gap_from, "deckEnd": round(deck_end, 1), "deckResume": round(deck_resume, 1),
                         "minLaunchSpeed": round(v_min, 1), "landingAt128": round(land_128, 1)},
                "viaductCrossings": [round(c[0], 1) for c in crossings],
                "downtownViaduct": downtown_viaduct,
                "gatePortals": [r["name"] for r in rings],
                "glassVault": [TUNNEL_FROM, TUNNEL_TO],
                "forkOpenStretches": [list(r) for r in fork_open], "forkSide": "right" if alt_side > 0 else "left",
                "forkOpenBand": FORK_OPEN_BAND,
                "funnelRails": {k: {"from": [r2(v) for v in a], "to": [r2(v) for v in b], "angleDeg": funnel_angles[k]}
                                for k, (a, b) in funnel_lines.items()},
                "funnelRailPieces": len(funnel_recs), "landingNosePieces": len(nose_recs),
                "parts": parts_total, "collidableParts": collidable, "parapetPieces": len(wall_specs),
                "laneLinePieces": lane_count, "streetlamps": lamp_count, "towers": tower_count,
                "craters": len(craters), "boulders": boulders, "setDressing": len(dressing),
                "skywayArches": arch_stations,
                "rooftopShortcut": ({
                    "entryStation": RT_ENTRY_ST, "exitStation": RT_EXIT_ST, "extend": RT_EXTEND, "lanePlanLength": roof.stats["length"],
                    "plannedSaving": roof.stats["routeSaved"], "roofY": roof.stats["roofY"],
                    "climbPeakDeg": roof.stats["climbPeakDeg"], "descentPeakDeg": roof.stats["descentPeakDeg"],
                    "maxFaceDeg": RT_MAX_FACE_DEG(), "bridgeS": roof.stats["bridgeS"], "bridgeStations": roof.stats["bridgeStations"],
                    "parapetOpen": {"right": [[round(a, 1), round(b, 1)] for a, b in roof.open_ranges[1.0]],
                                    "left": [[round(a, 1), round(b, 1)] for a, b in roof.open_ranges[-1.0]]},
                    "keepOut": [[round(a, 1), round(b, 1)] for a, b in roof.keep_out],
                    "deckPieces": roof_out["deckPieces"], "wallPieces": roof_out["wallPieces"],
                    "neonParts": roof_out["ncParts"], "supportParts": roof_out["supportParts"], "piers": roof_out["piers"],
                    "towersSkipped": len(skipped_towers),
                } if ROOFTOP_SHORTCUT else None),
                "spaceNeon": {"edgePieces": edge_pieces, "gridRungs": rungs, "chevrons": chevrons,
                              "lightArches": tron_arch_stations, "lightArchLights": tron_lights, "mapParts": tron_parts,
                              "holograms": neon_layout["holograms"], "billboards": neon_layout["billboards"]},
            },
        },
    }
    if not ROOFTOP_SHORTCUT:  # the kill switch gives back the stage-v24 plan byte for byte (no null provenance key)
        del plan["skyrally"]["provenance"]["rooftopShortcut"]
    dbg = {"route": route, "poly": poly, "H": H, "X": X, "Z": Z, "nx": nx, "nz": nz, "gx0": gx0, "gz0": gz0,
           "alt_all": alt_all, "kept": kept, "mesa": mesa, "craters": craters, "placed": placed, "z_v": z_v,
           "piers": piers, "crossings": crossings, "wall_specs": wall_specs, "fork_open": fork_open,
           "alt_side": alt_side, "dt_piers": dt_piers, "mats": mats, "recs": recs, "nodes": nodes, "neon": neon_layout}
    return plan, dbg


if __name__ == "__main__":
    main()
