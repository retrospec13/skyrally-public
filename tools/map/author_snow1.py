#!/usr/bin/env python3
"""TRACK_PIPELINE P1 author script for SNOW-1 "Frozen River Peak" (plane): design data in this file ->
map/snow1/plan.json (docs/MAP_PLAN_SCHEMA.md), assets/materials/snow_v1/variants.json and the procedural sky faces
assets/sky/snow1/{up,side,down}.png. Deterministic (fixed seeds, rounded output). Change the map here and rerun, then
`python3 tools/map/adapt.py map/snow1/plan.json`; never edit the plan, the variants file or build/snow1/* by hand.

Guide: docs/guides/snow1.md (low flight up a winding cyan frozen river between
cobalt-shadowed snow-capped rock shelves and tall faceted pines, toward a monumental carved stone arch bridge with the
high alpine peak beyond).

Layout (local coordinates, +x east, -z north; ORIGIN moves the whole map clear of DINO-4 at the world origin and the
TEST-STRIP at x=+4000, because all launch maps share one place):
  The lap is a figure eight whose crossing IS the arch bridge (stations of the solved 5000-stud route).
  st 0     start/finish on the frozen river ~235 short of the arch, heading north: the arch fills the upper third
           with the peak above its deck (framing.heroStation 30 = the guide's composition).
  st ~235  UNDER the arch (river level, the plane 16 studs over the ice, the intrados 60+ studs over the plane).
           Hidden key (st ~340): a 120-stud notch cut along the west gorge wall behind the west pier, just past
           the arch, under a rock lip (fly-in/fly-out), with the shrine in a niche at its back.
  st ~300-1080  the winding gorge north of the bridge: terraced snow-capped walls, granite shelves, the Alt1 mine
           tunnel through the west wall (st ~450-860), the two-step frozen cascade (st ~910-960).
  st ~1080-1870 out of the gorge: a climbing right-hand sweep through the glacial basin below the peak, around a pine
           knoll, onto the east plateau.
  st ~1870-2780 the east plateau heading south through pine forest toward the mountain lodge, then a right turn.
  st ~3085 OVER the arch: the straight run along the bridge deck (deck top 1 stud under the waypoint).
  st ~3400-4300 west plateau, left turn, descent down a pine slope to the frozen lake.
  st ~4300-4720 across the frozen lake (SNOW battle overlay basin), left turn into the river mouth and the line.

Construction (ART_BAR): ground, gorge, lake, basin, knoll and peak are a 30MAPS terrain height grid (cell 8, terraced
gorge walls so cliffs show rock and treads hold snow); the far skyline ridges, snow-capped rock blocks, the cascade
ice and the key/tunnel openings are shells ops. Landmarks are faceted block-built prefabs named after what they are.
The SNOW deck style has kind "none" (open flight line, no road; the guide shows none).
"""
from __future__ import annotations

import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
for _p in (ROOT / "tools" / "map", ROOT / "tools" / "course"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import adapt  # noqa: E402  (corridor box math, so placement filters match the compile gate exactly)
import route as routelib  # noqa: E402
import item_rows  # noqa: E402  (item cubes v2 layout rules, tools/map/item_cubes.json)

KEY = "snow1"
MAP_ID = "SNOW-1"
OUT = ROOT / "map" / KEY / "plan.json"
VARIANTS_OUT = ROOT / "assets" / "materials" / "snow_v1" / "variants.json"
SKY_DIR = ROOT / "assets" / "sky" / KEY
GUIDE = "docs/guides/snow1.md"

ORIGIN = (-8000.0, 0.0, 0.0)  # world position of local (0,0,0); SNOW-1 occupies world x -8800..-7200, z -1800..960
SEED = 5101
TARGET_LENGTH = 5000
LINE = 14.0  # flight line above the waypoint (skyrally.flight.lineOffset)
CORRIDOR = {"halfWidth": 34, "floor": 5, "ceiling": 44}

# ------------------------------------------------------------------------------------------------ small math


def r2(v: float) -> float:
    return round(float(v), 2)


def r3(v: float) -> float:
    return round(float(v), 3)


def W(x: float, y: float, z: float) -> list[float]:
    """Local -> world position, rounded."""
    return [r3(x + ORIGIN[0]), r3(y + ORIGIN[1]), r3(z + ORIGIN[2])]


def smooth(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def yaw_to(dx: float, dz: float) -> float:
    """Yaw (degrees, CFrame.Angles(0, yaw, 0)) that turns local -Z (a prefab's front) to the direction (dx, dz)."""
    return math.degrees(math.atan2(-dx, -dz))


def yaw_right(rx: float, rz: float) -> float:
    """Yaw that turns local +X onto the horizontal right vector (rx, rz)."""
    return math.degrees(math.atan2(-rz, rx))


def cf_yaw(x: float, y: float, z: float, yaw_deg: float = 0.0, pitch_deg: float = 0.0, roll_deg: float = 0.0) -> list[float]:
    """World CFrame (12 components) at local (x, y, z) with YXZ Euler rotation (degrees)."""
    R = adapt.rot_yxz(pitch_deg, yaw_deg, roll_deg)
    p = W(x, y, z)
    return p + [r3(R[0][0]), r3(R[0][1]), r3(R[0][2]), r3(R[1][0]), r3(R[1][1]), r3(R[1][2]),
                r3(R[2][0]), r3(R[2][1]), r3(R[2][2])]


class Noise2:
    """Deterministic value noise (smooth lattice interpolation) for terrain shaping."""

    def __init__(self, seed: int, size: int = 256):
        rng = np.random.default_rng(seed)
        self.size = size
        self.v = rng.random((size, size))

    def __call__(self, x, z):
        x = np.asarray(x, float)
        z = np.asarray(z, float)
        xi = np.floor(x).astype(int)
        zi = np.floor(z).astype(int)
        fx = smooth(x - xi)
        fz = smooth(z - zi)
        s = self.size
        a = self.v[xi % s, zi % s]
        b = self.v[(xi + 1) % s, zi % s]
        c = self.v[xi % s, (zi + 1) % s]
        d = self.v[(xi + 1) % s, (zi + 1) % s]
        return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fz

    def fbm(self, x, z, octaves: int = 3):
        tot, amp, norm = 0.0, 1.0, 0.0
        for o in range(octaves):
            tot = tot + amp * self(x * (2 ** o) + 17.3 * o, z * (2 ** o) - 9.1 * o)
            norm += amp
            amp *= 0.5
        return tot / norm * 2 - 1  # [-1, 1]


NOISE = Noise2(SEED)
NOISE_B = Noise2(SEED + 1)

# ------------------------------------------------------------------------------------------------ route


def arc(c, r, a0, a1, n, y0, y1, bank, flex=(0, 0, 0)):
    """Nodes on a horizontal circle (centre c=(x,z), angle in the x/z plane, +z = south), heights eased linearly."""
    out = []
    for k in range(n):
        t = k / (n - 1)
        a = math.radians(a0 + (a1 - a0) * t)
        out.append((round(c[0] + r * math.cos(a), 1), round(y0 + (y1 - y0) * t, 1), round(c[1] + r * math.sin(a), 1), bank, flex))
    return out


Z0 = (0, 0, 0)
# (x, y, z, bank, flex) local. Positive bank raises the right edge (left turns), negative for right turns.
# The waypoint is 2 studs over the river/lake ice (the plane flies 16 over it) and 140 on the bridge deck run.
NODES = [
    (-12, 39.0, 235, 0, Z0),          # 0  start/finish on the river, heading north ~235 short of the arch (guide view)
    (0, 40.8, 150, 0, Z0),            # 1..4 collinear: the straight UNDER the arch (bridge centre at z=0)
    (0, 41.6, 50, 0, Z0),
    (0, 42.4, -50, 0, Z0),
    (0, 43.2, -150, 0, Z0),
    (-30, 45, -262, 6, Z0),           # the winding gorge
    (-92, 48, -372, 4, Z0),
    (-110, 51, -492, -6, Z0),
    (-76, 56, -602, -6, Z0),          # frozen cascade between here and the next node
    (-30, 67, -695, -4, Z0),
]
NODES += arc((250, -800), 250, 180, 360, 7, 76, 144, -12)                       # basin sweep (right) around the knoll
NODES += [(506, 149, -650, 0, (60, 0, 0)), (506, 150, -500, 0, (60, 0, 0)), (502, 148, -350, -4, (30, 0, 0))]
NODES += arc((300, -200), 200, 0, 90, 4, 147, 140, -10)[0:3]                    # right turn around the lodge
NODES += [(x, 140, 0, 0, Z0) for x in (300, 200, 100, 0, -100, -200, -300)]    # the straight OVER the arch
NODES += [(x, y, z, 10, (-40, 0, 0)) for (x, y, z, _b, _f) in arc((-300, 200), 200, 270, 180, 4, 140, 122, 10)[1:]]
NODES += [(-500, 101, 340, 0, (-50, 0, 0))]                                     # pine slope descent
NODES += [(x, y, z, 10, (-30, 0, 40)) for (x, y, z, _b, _f) in arc((-320, 480), 180, 180, 90, 4, 80, 36, 10)]
NODES += [(x, y, z, 10, (0, 0, 30)) for (x, y, z, _b, _f) in arc((-160, 500), 160, 90, 0, 4, 34, 34.5, 10)]
NODES += [(0, 35.0, 420, 0, Z0), (-16, 37.0, 325, 0, Z0)]                     # up the river to the line


def plan_nodes() -> list[dict]:
    return [{"pos": W(x, y, z), "bank": b, "flex": [float(f[0]), float(f[1]), float(f[2])]} for x, y, z, b, f in NODES]


ROUTE_BLOCK = {"closed": True, "samplesPerSegment": 9, "targetLength": TARGET_LENGTH, "flexScaleMin": 0.0,
               "flexScaleMax": 3.5, "bisectIterations": 24, "minRadius": 85, "radiusExceptions": []}


class Track:
    """The solved route in LOCAL coordinates plus station helpers."""

    def __init__(self):
        rt = dict(ROUTE_BLOCK, nodes=plan_nodes())
        self.route = routelib.solve_plan_route(rt)
        self.length = self.route.length
        self.wps = np.array([[w.pos[0] - ORIGIN[0], w.pos[1] - ORIGIN[1], w.pos[2] - ORIGIN[2]] for w in self.route.waypoints])
        self.st = np.array([w.station for w in self.route.waypoints])
        # dense resample (5 studs) for distance fields
        self.dense_st = np.arange(0.0, self.length, 5.0)
        self.dense = np.array([self.pos(s) for s in self.dense_st])

    def frame(self, s: float):
        f = self.route.frame_at(s)
        p = np.array(f.pos) - np.array(ORIGIN)
        return p, np.array(f.tangent), np.array(f.right), np.array(f.up)

    def pos(self, s: float) -> np.ndarray:
        return self.frame(s)[0]

    def offset(self, s: float, lateral: float = 0.0, height: float = 0.0) -> np.ndarray:
        p, _t, r, u = self.frame(s)
        return p + r * lateral + u * height

    def station_of(self, x: float, z: float) -> float:
        d = (self.dense[:, 0] - x) ** 2 + (self.dense[:, 2] - z) ** 2
        return float(self.dense_st[int(np.argmin(d))])


# ------------------------------------------------------------------------------------------------ landscape design

RIVER_HALF = 46.0      # frozen river half width (ice)
LIP = 10.0             # snow bank lip beyond the ice
LAKE_C = (-240.0, 600.0)
LAKE_R = (262.0, 168.0)
LAKE_ICE = 32.0
# Survival battle arena on the lake (modes.battle; BattleRules.arena reads radius, boundary.radius and boundary.height).
# docs/audits/traps_snow1.md SN-01/SN-02/SN-08: the play circle is 200 (warn toast and edge pull start inside the lake,
# 80 studs before the 280 return line instead of 30), the ceiling is 32 + 260 (was 172, a climb hit it in 1.8 s), and
# the ground inside the return line is a low beach (ARENA_BEACH) because the lake is a 262 x 168 ellipse: the forested
# north and south banks used to reach the plane's 46 seat height 190-210 studs out, inside the circle
ARENA = {"radius": 200.0, "boundary": 280.0, "height": 260.0}
# beach cap around LAKE_C by radius: (from r, rise per stud) segments, cumulative from LAKE_ICE + 1: 4 degrees to
# r 250, 10 degrees to the return line (ground 44.4 there, under the 46 seats), then 31 and 42 degrees beyond it.
# Every face a plane can meet inside the return line deflects (FlightController crashes only at impactDot < -0.58,
# about 35 degrees head-on); the cap only lowers ground, so outside ~r 340 the original banks and skyline stand.
ARENA_BEACH = ((160.0, 0.07), (250.0, 0.17), (280.0, 0.6), (300.0, 0.9))
ARENA_ISLETS = ((-430.0, 560.0, 30.0, 16.0, 22.0, 20.0), (-310.0, 545.0, 24.0, 20.0, 26.0, -15.0),
                (-180.0, 560.0, 22.0, 14.0, 18.0, 40.0))  # (x, z, size x/y/z, yaw) local, Rock with a Snow cap
START_Z, START_CLEAR = 223.0, 150.0  # terrain-look: shelf-free band around the start grid (local z)
ARENA_CLEAR = 300.0  # no pines or rock shelves nearer the lake centre than this (a Tall pine crown reaches ~21 studs)
PLATEAU = 134.0
BRIDGE_DECK_TOP = 139.0   # over-pass waypoint 140: deck top 1 under it, pads sit 2.6 over the paving
SPRING = 54.0             # main arch spring line (pier tops)
ARCH_R = 64.0             # intrados radius (clear span 128)
ARCH_T = 18.0             # voussoir ring depth
BRIDGE_HALF_DEPTH = 37.5  # deck half width along z (parapet inner faces at 34.5)
BRIDGE_HALF_LEN = 176.0   # deck runs x = -176..176
LODGE = (600.0, -40.0)    # mountain lodge: on the outside of the right turn into the bridge run, ahead of the S4 leg
LODGE_Y = 140.0
TRAIL_GATES = (2315.0, 3536.0)
GATE_SCALE = 1.5            # critic v28 1.19: start gate 1.5x (posts 78 off the line, beam 70 over it)
LODGE_SCALE = 1.5          # critic v28 1.19: the lodge reads small against the basin; 1.5x, footing sunk into the pad
LODGE_YAW = yaw_to(-120.0, -80.0)  # porch toward the line
KNOLL = (250.0, -850.0)
# snow hills (x, z, radius, height) beside the plateau legs and the west slope
HILLS = [(390.0, -700.0, 95.0, 46.0), (660.0, -600.0, 120.0, 70.0), (410.0, -430.0, 80.0, 38.0),
         (640.0, -300.0, 110.0, 55.0), (-380.0, -160.0, 110.0, 52.0), (-660.0, 120.0, 130.0, 80.0),
         (-340.0, 230.0, 95.0, 44.0), (-250.0, -330.0, 120.0, 40.0), (170.0, -470.0, 100.0, 36.0)]
# forest zones (x0, z0, x1, z1): dense pines (the guide: tall pines everywhere along the lap)
FORESTS = [(360.0, -980.0, 700.0, -230.0), (-720.0, -260.0, -300.0, 420.0), (130.0, -1000.0, 380.0, -700.0),
           (-260.0, 60.0, 260.0, 470.0), (-300.0, -560.0, 300.0, -120.0), (230.0, -220.0, 520.0, 120.0)]
# tall pines at the arch abutments: beside the piers on both faces and out by the end pylons (x, z, scale, yaw)
ABUTMENT_PINES = ((226.0, 78.0, 1.6, 20.0), (214.0, 100.0, 1.45, 140.0), (-226.0, 78.0, 1.6, 200.0), (-214.0, 100.0, 1.45, 80.0),
                  (226.0, -78.0, 1.6, 310.0), (214.0, -100.0, 1.45, 50.0), (-226.0, -78.0, 1.6, 100.0), (-214.0, -100.0, 1.45, 260.0),
                  (160.0, 92.0, 1.4, 10.0), (-160.0, 92.0, 1.4, 170.0), (160.0, -92.0, 1.4, 330.0), (-160.0, -92.0, 1.4, 220.0),
                  (104.0, 96.0, 1.3, 60.0), (-104.0, 96.0, 1.3, 120.0), (104.0, -96.0, 1.3, 240.0), (-104.0, -96.0, 1.3, 300.0))
PEAK = (110.0, -1560.0)
PEAK_TOP = 640.0
CASCADE_XZ = ((-56.0, -644.0), (-33.0, -688.0))  # the two frozen steps of the cascade (on the route)
LAKE_FROM_XZ = (-430.0, 646.0)                   # the route is over the lake (or its shore) from here to the mouth
GRID = {"x0": -800.0, "z0": -1680.0, "x1": 800.0, "z1": 960.0, "cell": 8.0, "floor": 14.0}  # back of the peak trimmed (never seen)


def arena_beach(rc):
    """SN-02: the beach cap height at distance rc from the lake centre (ARENA_BEACH segments)."""
    h = np.full(np.shape(rc), LAKE_ICE + 1.0)
    bounds = [r for r, _k in ARENA_BEACH] + [None]
    for (r0, k), r1 in zip(ARENA_BEACH, bounds[1:]):
        h = h + k * np.clip(rc - r0, 0.0, None if r1 is None else r1 - r0)
    return h


def facet_peak(X, Z, cx, cz, top, faces):
    """Height of a faceted pyramid: the lowest of planar faces (azimuth, slope) around (cx, cz); 0 outside."""
    ang = np.arctan2(Z - cz, X - cx)
    rp = np.hypot(X - cx, Z - cz)
    h = np.full(np.shape(X), np.inf)
    for a0, sl in faces:
        h = np.minimum(h, top - sl * rp * np.maximum(0.2, np.cos(ang - a0)))
    return np.maximum(h, 0.0)


class Landscape:
    def __init__(self, tr: Track):
        self.tr = tr
        L = tr.length
        # River: route stations from the lake mouth around through 0 to the north end of the gorge, then a northern
        # extension to the glacier tongue below the peak.
        self.cascade = tuple(tr.station_of(x, z) for x, z in CASCADE_XZ)
        self.lake_from = tr.station_of(*LAKE_FROM_XZ)
        self.mouth_st = tr.station_of(-30.0, 560.0)       # route leaves the lake here into the river
        self.north_st = tr.station_of(0.0, -800.0)        # route leaves the river here (basin sweep)
        ss = [s for s in tr.dense_st if s >= self.mouth_st] + [s for s in tr.dense_st if s <= self.north_st]
        pts = [tr.pos(s) for s in ss]
        ice = [self.route_ice(s, p) for s, p in zip(ss, pts)]
        ext = [(-6.0, -880.0), (-22.0, -960.0), (-36.0, -1040.0), (-40.0, -1120.0), (-30.0, -1200.0), (-10.0, -1280.0)]
        ext_ice = [ice[-1] + 3, ice[-1] + 7, ice[-1] + 12, ice[-1] + 20, ice[-1] + 34, ice[-1] + 56]
        self.river_xz = np.array([[p[0], p[2]] for p in pts] + [list(e) for e in ext])
        self.river_ice = np.array(ice + ext_ice)
        self.river_glacier = np.array([0] * len(pts) + [0, 0, 1, 1, 1, 1], bool)
        self.river_st = np.array(ss + [-1.0] * len(ext))
        self.n_route_river = len(pts)
        # Alt1 mine tunnel line (the height grid raises a spur over it, build() places portals and carves from it)
        self.alt_s = (tr.station_of(*ALT1["from_xz"]), tr.station_of(*ALT1["to_xz"]))
        self.alt = offset_path(tr, self.alt_s[0], self.alt_s[1], ALT1["lateral"], ALT1["height"], ALT1["ramp"],
                               ALT1["step"], ALT1["min_offset"], ALT1["ramp_in"])
        self.alt_xz = np.array([[q[0], q[2]] for _s, q, _k in self.alt])
        self.alt_y = np.array([q[1] for _s, q, _k in self.alt])

    # ice level under the route in river sections: 2 studs under the waypoint, with the cascade as two crisp steps
    def route_ice(self, s: float, p: np.ndarray) -> float:
        y = float(p[1]) - 2.0
        c0, c1 = self.cascade
        if c0 - 60 <= s <= c1 + 40:
            lo = float(self.tr.pos(c0 - 60)[1]) - 2.0
            hi = float(self.tr.pos(c1 + 40)[1]) - 2.0
            mid = (lo + hi) / 2
            step = lo + (mid - lo) * float(smooth((s - c0 + 8) / 16)) + (hi - mid) * float(smooth((s - c1 + 8) / 16))
            y = min(y, step)
        return max(y, LAKE_ICE)

    # -------------------------------------------------------------------------------------- distance fields
    @staticmethod
    def seg_dist(px, pz, a, b):
        """Distance from points to the polyline a->b segments; returns (dist, segment index, t, side sign)."""
        best = np.full(px.shape, np.inf)
        bi = np.zeros(px.shape, int)
        bt = np.zeros(px.shape)
        bside = np.zeros(px.shape)
        for i in range(len(a)):
            ax, az = a[i]
            bx, bz = b[i]
            dx, dz = bx - ax, bz - az
            ll = dx * dx + dz * dz
            if ll < 1e-9:
                continue
            t = np.clip(((px - ax) * dx + (pz - az) * dz) / ll, 0, 1)
            qx, qz = ax + dx * t, az + dz * t
            d = np.hypot(px - qx, pz - qz)
            m = d < best
            best = np.where(m, d, best)
            bi = np.where(m, i, bi)
            bt = np.where(m, t, bt)
            # side: + right of the downstream->upstream direction (route heading north = right is east)
            cr = dx * (pz - az) - dz * (px - ax)
            bside = np.where(m, -np.sign(cr), bside)
        return best, bi, bt, bside

    def river_field(self, px, pz):
        a = self.river_xz[:-1]
        b = self.river_xz[1:]
        d, i, t, side = self.seg_dist(px, pz, a, b)
        ice = self.river_ice[:-1][i] + (self.river_ice[1:][i] - self.river_ice[:-1][i]) * t
        gl = self.river_glacier[:-1][i] | self.river_glacier[1:][i]
        return d, ice, side, gl, i

    def route_field(self, px, pz):
        """Distance to the route centre line and the clearance ground target there."""
        tr = self.tr
        ds = tr.dense
        a = ds[:, [0, 2]]
        b = np.roll(a, -1, axis=0)
        d, i, t, _ = self.seg_dist(px, pz, a, b)
        st = tr.dense_st[i]
        wy = ds[i, 1] + (ds[(i + 1) % len(ds), 1] - ds[i, 1]) * t
        low = (st >= self.lake_from) | (st <= self.north_st)  # river and lake: the ice itself is the ground
        target = np.where(low, wy - 2.0, wy - 5.0)
        return d, target, st

    # -------------------------------------------------------------------------------------- the height grid
    def build_grid(self):
        g = GRID
        cell = g["cell"]
        nx = int(round((g["x1"] - g["x0"]) / cell)) + 1
        nz = int(round((g["z1"] - g["z0"]) / cell)) + 1
        xs = g["x0"] + np.arange(nx) * cell
        zs = g["z0"] + np.arange(nz) * cell
        X, Z = np.meshgrid(xs, zs)  # row-major: [iz, ix]
        H, mat = self.height(X, Z)
        return {"nx": nx, "nz": nz, "xs": xs, "zs": zs, "X": X, "Z": Z, "H": H, "mat": mat}

    def height(self, X, Z):
        n1 = NOISE.fbm(X / 230.0, Z / 230.0)
        n2 = NOISE_B.fbm(X / 90.0, Z / 90.0)
        B = PLATEAU + 9.0 * n1 + 3.0 * n2
        # snow hills beside the plateau legs: the line weaves between them (the route clearance keeps the lane open)
        for hx, hz, hr, hh in HILLS:
            rr = np.hypot(X - hx, Z - hz) / hr
            B = B + hh * smooth(1.0 - rr) ** 1.3
        # the land falls south toward the lake and the river mouth
        south = smooth((Z - 160.0) / 420.0)
        B = B + (44.0 - B) * south * smooth((260.0 - X) / 500.0 + 0.35)
        # the west slope descends with the route (pine slope to the lake)
        # rims of the valley: east / west / south ridges (skyline enclosure)
        B = B + np.clip(X - 600.0, 0, None) * 0.75 + np.clip(-640.0 - X, 0, None) * 0.85
        B = B + np.clip(Z - 790.0, 0, None) * 0.95
        B = B + np.clip(X - 380.0, 0, None) * np.clip((Z - 150.0) / 300.0, 0, 1) * 0.35  # south-east shoulder
        # glacial basin north of the gorge, the pine knoll inside the sweep
        rb = np.hypot((X - 170.0) / 360.0, (Z + 900.0) / 300.0)
        B = B - 62.0 * smooth(1.0 - rb)
        rk = np.hypot(X - KNOLL[0], Z - KNOLL[1])
        B = np.maximum(B, 122.0 - 0.0026 * rk ** 2 + 4.0 * n2)
        # faceted alpine peak: an irregular 7-face pyramid (planar facets = the Raiser read), glacier on its south face
        peak = facet_peak(X, Z, PEAK[0], PEAK[1], PEAK_TOP,
                          [(0.2, 1.6), (1.1, 1.45), (2.0, 1.7), (2.9, 1.5), (3.8, 1.6), (4.7, 1.3), (5.6, 1.55)])
        # faceted shoulders and flanking ridges (elongated: two shallow faces along the ridge, steep faces across it)
        for cx, cz, top, faces in ((-430.0, -1560.0, 380.0, [(0.3, 0.55), (1.6, 1.3), (3.4, 0.6), (4.8, 1.2)]),
                                   (560.0, -1500.0, 420.0, [(0.0, 0.6), (1.4, 1.25), (3.1, 0.55), (4.6, 1.35)]),
                                   (-720.0, -1120.0, 300.0, [(1.4, 0.6), (3.0, 1.2), (4.6, 0.55), (0.1, 1.3)]),
                                   (740.0, -1060.0, 320.0, [(1.7, 0.55), (3.3, 1.3), (4.9, 0.6), (0.2, 1.25)])):
            peak = np.maximum(peak, facet_peak(X, Z, cx, cz, top, faces))
        B = np.maximum(B, peak)
        mat = np.full(X.shape, 1, int)  # 1 snow, 2 rock, 3 ice, 4 glacier

        # river gorge: ice floor, snow lip, terraced walls (steeper, rockier west wall like the guide's left side)
        d, ice, side, gl, _ = self.river_field(X, Z)
        near_bridge = smooth(1.0 - (np.abs(Z) - 90.0) / 120.0) * (np.abs(X) < 400)
        wg_w = 118.0 + 14.0 * n1
        wg_e = 185.0 + 22.0 * n1
        wg = np.where(side < 0, wg_w, wg_e)
        wg = wg + (np.where(side < 0, 124.0, 140.0) - wg) * near_bridge  # the bridge springs from rock on both sides
        u = np.clip((d - RIVER_HALF - LIP) / np.maximum(20.0, wg - RIVER_HALF - LIP), 0, 1)
        steps = np.where(side < 0, 3.0, 2.0)
        k = np.floor(u * steps)
        f = u * steps - k
        riser = np.where(side < 0, smooth((f - 0.5) / 0.22), smooth((f - 0.35) / 0.45))
        T = np.clip((k + riser + 0.12 * f) / steps, 0, 1)
        lip = 3.5 * smooth((d - RIVER_HALF) / LIP)
        top = np.maximum(B, ice + 6.0)
        G = ice + lip + (top - ice - lip) * T
        in_gorge = d < wg
        H = np.where(in_gorge, np.minimum(B, G), B)
        river_ice = d < RIVER_HALF
        H = np.where(river_ice, np.minimum(H, ice), H)
        mat = np.where(river_ice, np.where(gl, 4, 3), mat)
        # L61: a dark granite shoreline rim where the ice meets the snow (critic r1: "snow and ice values blend")
        rim = (d >= RIVER_HALF) & (d < RIVER_HALF + 7.0) & (mat == 1)
        mat = np.where(rim, 2, mat)

        # frozen lake basin
        rl = np.hypot((X - LAKE_C[0]) / LAKE_R[0], (Z - LAKE_C[1]) / LAKE_R[1])
        shore = LAKE_ICE + 1.0 + 95.0 * np.clip(rl - 1.0, 0, None) ** 1.15 + 3.0 * smooth((rl - 1.0) / 0.06)
        lake = np.where(rl < 1.0, LAKE_ICE, shore)
        H = np.minimum(H, lake)
        mat = np.where(rl < 1.0, 3, mat)
        # SN-02 arena beach: inside the battle return line the ground stays under the plane's seat height
        H = np.minimum(H, arena_beach(np.hypot(X - LAKE_C[0], Z - LAKE_C[1])))

        # Alt1 spur: the west wall swells over the mine tunnel so the tube is buried in Terrain (crest ALT1.cover over
        # the tube floor, steep flanks); only beside the tunnel, so each mouth is a cliff face the portal sits in
        if len(self.alt_xz) >= 2:
            da, ia, ta, _ = self.seg_dist(X, Z, self.alt_xz[:-1], self.alt_xz[1:])
            nseg = len(self.alt_xz) - 1
            inner = ~(((ia == 0) & (ta <= 0.0)) | ((ia == nseg - 1) & (ta >= 1.0)))
            fy = self.alt_y[:-1][ia] + (self.alt_y[1:][ia] - self.alt_y[:-1][ia]) * ta
            spur = fy + ALT1["cover"] - np.clip(da - 24.0, 0, None) * 1.2
            H = np.where(inner, np.maximum(H, spur), H)

        # route clearance: ground stays under the flight corridor (river: the ice; elsewhere 5 under the waypoint)
        dr, target, _st = self.route_field(X, Z)
        clear = target + np.clip(dr - 40.0, 0, None) * 1.05
        H = np.minimum(H, clear)

        # flat pad for the lodge
        rlod = np.hypot(X - LODGE[0], Z - LODGE[1])
        pad = LODGE_Y
        w = smooth((rlod - 46.0) / 22.0)
        H = np.where(rlod < 68.0, pad + (H - pad) * w, H)

        H = np.maximum(H, GRID["floor"] + 4.0)
        gy, gx = np.gradient(H, GRID["cell"])
        slope = np.hypot(gx, gy)
        # cliffs (risers) read as granite, the cascade risers on the river as glacier ice
        mat = np.where((mat == 1) & (slope > 0.95), 2, mat)
        # L61 (critic r2: "mountain faces read as stamped snow"): exposed granite bands on the steeper faces of the
        # ridges and the peak, so the big slopes split into sunlit snow, shadow snow and rock
        band = NOISE.fbm(X / 60.0 + 7.0, Z / 60.0 - 3.0)
        mat = np.where((mat == 1) & (H > PLATEAU + 40.0) & (slope > 0.62 + 0.18 * band), 2, mat)
        mat = np.where((mat == 3) & (slope > 0.22), 4, mat)
        # the glacier tongue and the upper peak faces
        mat = np.where((mat != 3) & (H > 430.0) & (slope < 1.3), 4, mat)
        # terrain-look (rebake tier; MAP_SURFACE_PLAN item 2): break up the white plain with three more terrain materials,
        # all on existing uploaded tiles. 5 snowshade (Ground, SR_SNOW_Wind): wind-packed, cooler patches wherever a
        # 90-stud noise field is high; 6 hollow (Mud, SR_SNOW_Hollow): shadowed dips on the flat snow; ridge crust is
        # plain Rock (2, the granite tile) on the shoulders and ridge flanks where a 70-stud noise field is high.
        flat_snow = (mat == 1) & (slope < 0.12)
        shade = NOISE_B.fbm(X / 90.0 + 5.0, Z / 90.0 - 11.0, 2)
        hollow = NOISE.fbm(X / 55.0 + 31.0, Z / 55.0 + 4.0, 2)
        crest = NOISE_B.fbm(X / 70.0 - 13.0, Z / 70.0 + 29.0, 2)
        ridge = (mat == 1) & (H > PLATEAU + 25.0) & (slope > 0.3) & (crest > 0.15)
        mat = np.where(ridge, 2, mat)
        mat = np.where(flat_snow & (hollow < -0.3), 6, mat)
        mat = np.where(flat_snow & (mat == 1) & (shade > 0.22), 5, mat)
        return H, mat




# ------------------------------------------------------------------------------------------------ prefab parts
# Colours: textured materials (Slate ashlar, Granite fieldstone, Pavement pavers, WoodPlanks timber, Snow, Ice) carry a
# near-white tint so the zone texture set (assets/materials/snow_v1) carries the colour, as DINO-4 does; flat-painted
# accents (pine needles, banners, lanterns) are SmoothPlastic/Neon in the guide's palette.
STONE = ("#d9dbe6", "#cdd0dc", "#e3e4ec")   # ashlar blocks (lavender-grey stone of the guide's bridge)
KEYSTONE = "#eceef4"
FIELD = "#e2e6ee"
SNOWC = "#f6f9ff"
TIMBER = "#f2dcc0"
TIMBER_DK = "#d9b48a"
LANTERN = "#ffd08a"


def P(shape, x, y, z, sx, sy, sz, rx=0.0, ry=0.0, rz=0.0, color="#ffffff", mat="SmoothPlastic", extra=None):
    out = [shape, r3(x), r3(y), r3(z), r3(sx), r3(sy), r3(sz), r3(rx), r3(ry), r3(rz), color, mat]
    if extra:
        out.append(extra)
    return out


def wedge_euler(ur, ut, side):
    """YXZ Euler degrees (CFrame.fromEulerAnglesYXZ) orienting a Roblox WedgePart as a voussoir flank: local Y = -radial
    (outward is local -Y), local Z = -side*tangent, so the vertical face meets the stone body and the slope opens
    outward; local X = Y x Z (+-world Z)."""
    ax_y = (-ur[0], -ur[1], 0.0)
    ax_z = (-side * ut[0], -side * ut[1], 0.0)
    ax_x = (ax_y[1] * ax_z[2] - ax_y[2] * ax_z[1], ax_y[2] * ax_z[0] - ax_y[0] * ax_z[2], ax_y[0] * ax_z[1] - ax_y[1] * ax_z[0])
    R = [[ax_x[0], ax_y[0], ax_z[0]], [ax_x[1], ax_y[1], ax_z[1]], [ax_x[2], ax_y[2], ax_z[2]]]
    # R = Ry(b) Rx(a) Rz(c): R[1][2] = -sin a
    a = math.asin(max(-1.0, min(1.0, -R[1][2])))
    ca = math.cos(a)
    bb = math.atan2(R[0][2], R[2][2])
    cc = math.atan2(R[1][0], R[1][1])
    return (math.degrees(a), math.degrees(bb), math.degrees(cc))


def bridge_parts() -> list:
    """StoneArchBridge, pivot at the bridge centre (local 0,0,0): one monumental voussoir arch over the river (the
    under-pass), solid ashlar side walls stepping onto the gorge terraces, a paved deck (the over-pass) with a
    snow-capped parapet, lanterns and end pylons. Everything that could meet a racer is collidable; nothing enters
    either flight corridor (under: |x| < 34 up to 86; over: |z| < 34 from 145 up)."""
    parts = []
    D = BRIDGE_HALF_DEPTH * 2
    deck_bottom = 135.6
    # piers and stepped plinths on both banks
    for sx in (-1, 1):
        parts.append(P("B", sx * 75, 39, 0, 22, 30, D, color=STONE[0], mat="Slate"))
        parts.append(P("B", sx * 75, 28, 0, 30, 10, D + 8, color=STONE[1], mat="Slate"))
        parts.append(P("B", sx * 75, 22, 0, 36, 6, D + 14, color=FIELD, mat="Granite"))
    # voussoir ring (W2 critic 3.4): 13 true wedge-shaped stones (a block plus two wedge flanks each, joints on the radial
    # lines), keystone proud and tall, alternating stones proud of the spandrel face, snow on the upper extrados ledge.
    # The intrados stays the old circle (radius ARCH_R about (0, SPRING)), so the opening clearances are unchanged.
    n = 13
    dphi = math.pi / n
    th = math.tan(dphi / 2)
    for i in range(n):
        phi = dphi * (i + 0.5)
        key = i == n // 2
        # review: the keystone grows 2 each way (the v28 envelope, r 62..84, top 138) so it stays under the deck paving
        # (top 139, the over-pass waypoint 140); r 86 put a collidable 1-stud ridge across the deck at the waypoint
        ro = ARCH_R + ARCH_T + (2.0 if key else 0.0)
        ri = ARCH_R - (2.0 if key else 0.0)
        rad = ro - ri
        wi, wo = 2 * ri * th, 2 * ro * th
        dd = (wo - wi) / 2
        depth = D + (3.5 if key else (2.4 if i % 2 == 0 else 1.2))
        col = KEYSTONE if key else STONE[i % 3]
        ur = (math.cos(phi), math.sin(phi))
        ut = (-math.sin(phi), math.cos(phi))
        rm = (ri + ro) / 2
        parts.append(P("B", rm * ur[0], SPRING + rm * ur[1], 0, wi + 0.5, rad, depth, 0, 0, math.degrees(phi) - 90, col, "Slate"))
        for side in (-1, 1):
            tm = side * (wi / 2 + dd / 2 - 0.05)
            cx, cy = rm * ur[0] + tm * ut[0], SPRING + rm * ur[1] + tm * ut[1]
            parts.append(P("W", cx, cy, 0, depth, rad, dd + 0.1, *wedge_euler(ur, ut, side), col, "Slate"))
        if 3 <= i <= 9:
            # snow on the proud ledge of the upper stones, both faces (decor)
            for sz in (-1, 1):
                rs = ro + 0.35
                parts.append(P("B", rs * ur[0], SPRING + rs * ur[1], sz * (depth / 2 - 0.9), wo * 0.92, 0.9, 1.8, 0, 0,
                               math.degrees(phi) - 90, SNOWC, "Snow", {"nc": 1}))
    # (review: no crown drift; at r 86.6 it lay across the deck paving in the over-pass line. The keystone's own face
    # snow caps above carry the guide's snow read.)
    # spandrel columns over the extrados (16-wide courses, bottoms never below the intrados)
    xo = ARCH_R + ARCH_T
    for c in range(10):
        x0, x1 = -80 + 16 * c, -64 + 16 * c
        ext = min(SPRING + math.sqrt(max(0.0, xo * xo - x * x)) for x in (x0, x1, (x0 + x1) / 2))
        bot = ext - 4.0
        parts.append(P("B", (x0 + x1) / 2, (bot + deck_bottom) / 2, 0, 16.2, deck_bottom - bot, D - 1.0,
                       color=STONE[(c + 1) % 3], mat="Slate"))
    # side walls from the piers to the abutments (buried in the gorge terraces), with pilasters
    for sx in (-1, 1):
        parts.append(P("B", sx * 131, 96, 0, 90, 80, D - 1.0, color=STONE[2], mat="Slate"))
        for px in (88, 131, 172):
            parts.append(P("B", sx * px, 100, 0, 9, 72, D + 7, color=STONE[0], mat="Slate"))
            parts.append(P("B", sx * px, 136.8, 0, 11, 3, D + 9, color=KEYSTONE, mat="Slate"))
        # blind arch panel on each face (darker recess, the guide's side opening read)
        for sz in (-1, 1):
            parts.append(P("B", sx * 110, 108, sz * (BRIDGE_HALF_DEPTH - 0.6), 28, 30, 1.4, color="#9fa3b6", mat="Slate",
                           extra={"nc": 1}))
            parts.append(P("B", sx * 152, 108, sz * (BRIDGE_HALF_DEPTH - 0.6), 26, 30, 1.4, color="#9fa3b6", mat="Slate",
                           extra={"nc": 1}))
    # string course and deck
    parts.append(P("B", 0, 134.2, 0, 2 * BRIDGE_HALF_LEN + 6, 3.0, D + 4, color=KEYSTONE, mat="Slate"))
    parts.append(P("B", 0, (deck_bottom + BRIDGE_DECK_TOP) / 2, 0, 2 * BRIDGE_HALF_LEN, BRIDGE_DECK_TOP - deck_bottom,
                   D - 6.0, color="#8a93a8", mat="Pavement"))  # v29 D4: cool grey deck (was #e8ecf2)
    # parapets (inner faces at |z| = 34.5, top 144.4 = 4.4 under the over-pass corridor floor), merlons, snow
    for sz in (-1, 1):
        zc = sz * 36.0
        parts.append(P("B", 0, (BRIDGE_DECK_TOP - 3.4 + 144.4) / 2, zc, 2 * BRIDGE_HALF_LEN, 144.4 - BRIDGE_DECK_TOP + 3.4, 3.0,
                       color=STONE[1], mat="Slate"))
        parts.append(P("B", 0, 144.9, zc, 2 * BRIDGE_HALF_LEN, 1.0, 3.0, color=SNOWC, mat="Snow"))
        # lantern posts at both ends and the centre
        for x in (-176, 0, 176):
            parts.append(P("B", x, 149.0, zc, 3.4, 9.2, 3.0, color=STONE[0], mat="Slate"))
            # v29 D4: a snow-capped stone lantern housing (no Neon cap); the warm PointLight sits just below the cap
            parts.append(P("B", x, 155.2, zc, 3.6, 3.6, 3.0, color="#6f7f99", mat="Slate",
                           extra={"l": [34, 1.3, "#ffc46e", False]}))
            parts.append(P("B", x, 155.2, zc + sz * 1.6, 2.0, 2.4, 0.4, color="#ffd9a0", mat="SmoothPlastic", extra={"nc": 1}))
            # review: the snow slab is decor (nc) and the wedge keeps its v28 height, so the post's collidable envelope
            # is unchanged (owner rule: no collision changes)
            parts.append(P("B", x, 157.4, zc, 4.4, 1.0, 3.6, color="#eef3fb", mat="Snow", extra={"nc": 1}))
            parts.append(P("W", x, 158.2, zc, 4.6, 2.4, 3.0, 0, 0 if sz < 0 else 180, 0, SNOWC, "Snow"))
    # end pylons (outside the over-pass corridor: inner faces at |z| = 37)
    for sx in (-1, 1):
        for sz in (-1, 1):
            parts.append(P("B", sx * 186, 140, sz * 44, 14, 44, 14, color=STONE[1], mat="Slate"))
            parts.append(P("B", sx * 186, 163, sz * 44, 16, 3, 16, color=KEYSTONE, mat="Slate"))
            # L61: a snow-loaded gable cap (two wedges) instead of a 4-sided cone (its CSG falls back to a cube)
            parts.append(P("W", sx * 186, 169.5, sz * 44 - 4.0, 17, 9, 8, 0, 0, 0, SNOWC, "Snow"))
            parts.append(P("W", sx * 186, 169.5, sz * 44 + 4.0, 17, 9, 8, 0, 180, 0, SNOWC, "Snow"))
            # pennant on the outer face of each pylon (decor): red on the east pair, cobalt on the west pair
            col = "#b8382c" if sx > 0 else "#2f5fc4"
            parts.append(P("B", sx * 186, 150, sz * 51.6, 9, 22, 0.6, color=col, mat="SmoothPlastic", extra={"nc": 1}))
            parts.append(P("W", sx * 186, 136.5, sz * 51.6, 9, 5, 0.6, 180, 0, 0, col, "SmoothPlastic", {"nc": 1}))
            parts.append(P("B", sx * 186, 161.6, sz * 51.8, 10.5, 1.2, 1.0, color="#e8c46a", mat="SmoothPlastic", extra={"nc": 1}))
    # icicles under the crown, both faces (decor, no collision)
    for sz in (-1, 1):
        for k, x in enumerate((-30, -19, -9, 0, 10, 21, 31)):
            y_in = SPRING + math.sqrt(ARCH_R ** 2 - x * x)
            h = 7.0 + (k * 37 % 5)
            parts.append(P("K", x, y_in - h / 2 + 1.0, sz * (BRIDGE_HALF_DEPTH + 0.2), 3.2, h, 3.2, 180, 0, 0, "#cfefff", "Ice",
                           {"n": 5, "nc": 1, "a": 0.2}))
    # snow on the cornice ledges and pier plinths
    for sx in (-1, 1):
        parts.append(P("B", sx * 75, 33.6, 0, 30.4, 1.2, D + 8.4, color=SNOWC, mat="Snow"))
    return parts


def lodge_parts() -> list:
    """MountainLodge: fieldstone plinth, honey timber walls, overhanging upper floor, steep snow-loaded gable roof,
    warm windows, chimney, porch. Pivot at the ground centre, front (porch) toward -Z."""
    p = []
    p.append(P("B", 0, -5, 0, 58, 14, 42, color=FIELD, mat="Granite"))   # footing: hides the pad blend under the plinth
    p.append(P("B", 0, 3, 0, 60, 6, 44, color=FIELD, mat="Granite"))
    p.append(P("B", 0, 14, 0, 52, 16, 36, color=TIMBER, mat="WoodPlanks"))
    for sx in (-1, 1):
        for sz in (-1, 1):
            p.append(P("B", sx * 26, 15, sz * 18, 4.4, 18, 4.4, color=TIMBER_DK, mat="WoodPlanks"))
    p.append(P("B", 0, 28, 0, 58, 12, 42, color=TIMBER, mat="WoodPlanks"))
    p.append(P("B", 0, 22.6, 0, 60, 1.4, 44, color=TIMBER_DK, mat="WoodPlanks"))
    # gable roof along x (wedges back to back), snow layer on top, gable ends timber
    for sz, ry in ((-1, 0), (1, 180)):
        p.append(P("W", 0, 44, sz * 12.5, 64, 20, 25, 0, ry, 0, "#8a5a3a", "WoodPlanks"))
        p.append(P("W", 0, 46.2, sz * 13.2, 66, 20, 26.4, 0, ry, 0, SNOWC, "Snow"))
    p.append(P("B", 0, 34.6, 0, 66, 1.4, 52, color=SNOWC, mat="Snow"))
    # chimney
    p.append(P("B", 18, 50, 6, 7, 24, 7, color=FIELD, mat="Granite"))
    p.append(P("B", 18, 62.6, 6, 8.4, 1.4, 8.4, color=SNOWC, mat="Snow"))
    # windows (warm glow) on the front and sides, door, sign, porch
    for x in (-16, -6, 10, 18):
        p.append(P("B", x, 15, -18.3, 6, 6, 0.8, color="#ffc477", mat="Neon"))
    p.append(P("B", -12, 28, -21.3, 7, 5, 0.8, color="#ffc477", mat="Neon", extra={"l": [30, 1.2, "#ffb760", False]}))
    p.append(P("B", 12, 28, -21.3, 7, 5, 0.8, color="#ffc477", mat="Neon", extra={"l": [30, 1.2, "#ffb760", False]}))
    for sx in (-1, 1):
        p.append(P("B", sx * 26.3, 15, 0, 0.8, 6, 7, color="#ffc477", mat="Neon"))
    p.append(P("B", 2, 12, -18.4, 8, 12, 1.0, color="#9a6634", mat="WoodPlanks"))
    p.append(P("B", 2, 20, -19.4, 18, 4, 0.8, color="#b07040", mat="SmoothPlastic"))
    p.append(P("B", 0, 6.8, -25, 40, 1.6, 12, color=TIMBER_DK, mat="WoodPlanks"))
    for x in (-18, 18):
        p.append(P("B", x, 13.5, -30, 2.4, 12, 2.4, color=TIMBER_DK, mat="WoodPlanks"))
    p.append(P("W", 0, 21, -27, 42, 5, 10, 0, 0, 0, "#8a5a3a", "WoodPlanks"))
    p.append(P("W", 0, 22.2, -27.4, 43, 5, 10.6, 0, 0, 0, SNOWC, "Snow"))
    # woodpile and a lantern post by the porch
    p.append(P("B", -28, 4, -26, 10, 8, 5, color="#a86c3c", mat="Wood"))
    p.append(P("B", 26, 8, -32, 1.6, 16, 1.6, color=TIMBER_DK, mat="WoodPlanks"))
    p.append(P("B", 26, 17, -32, 3, 3, 3, color=LANTERN, mat="Neon", extra={"l": [28, 1.1, "#ffc46e", False]}))
    return p


def gantry_parts() -> list:
    """FinishGantry: timber start/finish gate spanning the river on fieldstone footings; posts at +-52 lateral, the
    beam bottom 47 over the waypoint (corridor ceiling 44). Pivot on the waypoint, local +X = route right."""
    p = []
    for sx in (-1, 1):
        p.append(P("B", sx * 52, -6, 0, 10, 8, 10, color=FIELD, mat="Granite"))
        p.append(P("B", sx * 52, 24, 0, 5, 56, 5, color=TIMBER_DK, mat="WoodPlanks"))
        p.append(P("B", sx * 52, 47, 0, 6.4, 1.2, 6.4, color=SNOWC, mat="Snow"))
        p.append(P("B", sx * 52, 34, -3.4, 2.4, 2.4, 2.4, color=LANTERN, mat="Neon", extra={"l": [30, 1.2, "#ffc46e", False]}))
    p.append(P("B", 0, 50, 0, 116, 6, 6, color=TIMBER, mat="WoodPlanks"))
    p.append(P("B", 0, 53.6, 0, 117, 1.4, 7, color=SNOWC, mat="Snow"))
    # checkered banner under the beam (decor only)
    for k in range(12):
        p.append(P("B", -44 + 8 * k, 47.2 + (0 if k % 2 else 0.0), -0.2, 8, 5.4, 0.6,
                   color="#1d2433" if k % 2 == 0 else "#f4f6fb", mat="SmoothPlastic", extra={"nc": 1}))
    p.append(P("B", 0, 58.5, 0, 34, 8, 1.2, color="#3a6fd8", mat="SmoothPlastic", extra={"nc": 1}))
    p.append(P("B", 0, 58.5, -0.7, 30, 5, 0.4, color="#f4f6fb", mat="SmoothPlastic", extra={"nc": 1}))
    return p


def shrine_parts() -> list:
    """KeyAlcoveShrine: carved fieldstone niche with a small voussoir arch and a gold lantern, set in the alcove behind
    the west pier; the key itself is spawned by the game from gameplay.key. Front toward -Z (yawed to face the river)."""
    p = []
    p.append(P("B", 0, 1, 0, 22, 2, 14, color=FIELD, mat="Granite"))
    for sx in (-1, 1):
        p.append(P("B", sx * 9, 9, 0, 4, 16, 10, color=STONE[0], mat="Slate"))
    for i in range(5):
        a = math.pi * (i + 0.5) / 5
        p.append(P("B", 9 * math.cos(a), 17 + 9 * math.sin(a), 0, 6.4, 4, 10.4, 0, 0, math.degrees(a) - 90,
                   KEYSTONE if i == 2 else STONE[i % 3], "Slate"))
    p.append(P("B", 0, 12, 4.6, 14, 22, 1.6, color="#aeb3c4", mat="Slate"))
    p.append(P("B", 0, 4, 1, 6, 6, 6, color=FIELD, mat="Granite"))
    p.append(P("B", 0, 8.2, 1, 3.2, 3.2, 3.2, color="#ffd36a", mat="Neon", extra={"l": [32, 1.6, "#ffd36a", False]}))
    p.append(P("B", 0, 27.6, 0, 22, 1.4, 12, color=SNOWC, mat="Snow"))
    return p


def portal_parts() -> list:
    """MineTunnelPortal: timber-framed, fieldstone-faced mouth of the Alt1 tunnel. Posts at +-21 and the lintel from
    33 up stay outside the tunnel carve (+-13, 4..28). Pivot on the alt line, front toward -Z (out of the tunnel).
    SN-06: the posts and their granite facing are decor (nc), so clipping the mouth edge is the rock's glancing
    deflect, not a WallHit crash on a timber post; the lintel 17 over the flight line stays solid."""
    p = []
    for sx in (-1, 1):
        p.append(P("B", sx * 22, 16, 0, 6, 34, 6, color=TIMBER_DK, mat="WoodPlanks", extra={"nc": 1}))
        p.append(P("B", sx * 27, 18, 2, 8, 40, 10, color=FIELD, mat="Granite", extra={"nc": 1}))
    p.append(P("B", 0, 35.5, 0, 52, 5, 7, color=TIMBER, mat="WoodPlanks"))
    p.append(P("B", 0, 40, 2, 60, 6, 10, color=FIELD, mat="Granite"))
    p.append(P("B", 0, 43.6, 2, 61, 1.4, 11, color=SNOWC, mat="Snow"))
    p.append(P("B", 0, 30.5, -3.6, 2.4, 2.4, 2.4, color=LANTERN, mat="Neon", extra={"l": [26, 1.1, "#ffc46e", False]}))
    return p


def mine_rib_parts() -> list:
    """MineRib (v29 D6): a timber mine-frame rib inside the Alt1 tube, ALL decor (nc), flush on the inner wall faces
    (inner half width 13) and under the roof (bottom 28). Pivot on the tube frame like the portal (floor centre -1.8),
    local Z along the tunnel. Every third rib hangs a warm lantern."""
    nc = {"nc": 1}
    p = []
    for sx in (-1, 1):
        p.append(P("B", sx * 12.4, 16.6, 0, 1.2, 26, 1.8, color="#6b4a2e", mat="SmoothPlastic", extra=nc))
    p.append(P("B", 0, 29.0, 0, 26, 1.2, 1.8, color="#6b4a2e", mat="SmoothPlastic", extra=nc))
    return p


def mine_rib_lamp_parts() -> list:
    nc = {"nc": 1}
    p = mine_rib_parts()
    p.append(P("B", 0, 26.4, 0, 1.6, 1.6, 1.6, color="#ffd08a", mat="SmoothPlastic",
               extra={"nc": 1, "l": [18, 1.2, "#ffb760", False]}))
    return p


def trail_gate_parts() -> list:
    """TrailGate (critic v28 1.19, secondary gates at st 2315 and 3536): a big timber gate with snowy cap beam, red
    pennant drops and lanterns, ALL decor (nc): the posts stand 70 off the line and the beam 60 over it, so nothing here
    can be hit. Pivot on the waypoint, local +X = route right."""
    nc = {"nc": 1}
    p = []
    for sx in (-1, 1):
        p.append(P("B", sx * 70, 20, 0, 9, 90, 9, color=TIMBER_DK, mat="WoodPlanks", extra=nc))
        p.append(P("B", sx * 70, -26, 0, 15, 12, 15, color=FIELD, mat="Granite", extra=nc))
        p.append(P("B", sx * 70, 66, 0, 12, 2.2, 12, color=SNOWC, mat="Snow", extra=nc))
        p.append(P("B", sx * 70, 40, -5.4, 3.2, 3.2, 3.2, color=LANTERN, mat="Neon",
                   extra={"nc": 1, "l": [34, 1.3, "#ffc46e", False]}))
    p.append(P("B", 0, 62, 0, 148, 8, 8, color=TIMBER, mat="WoodPlanks", extra=nc))
    p.append(P("B", 0, 67, 0, 150, 2.2, 9.4, color=SNOWC, mat="Snow", extra=nc))
    for k in range(7):
        p.append(P("B", -54 + 18 * k, 53, -0.2, 9, 8, 0.6, color="#c8323a" if k % 2 == 0 else "#f4f6fb", mat="Fabric", extra=nc))
    p.append(P("B", 0, 73, 0, 36, 9, 1.4, color="#3a6fd8", mat="SmoothPlastic", extra=nc))
    p.append(P("B", 0, 73, -0.9, 30, 5.4, 0.4, color="#f4f6fb", mat="SmoothPlastic", extra=nc))
    return p


def hut_parts() -> list:
    """IceFishingHut on the frozen lake (survival cover): timber box, snowy pent roof, a red door."""
    return [
        P("B", 0, 5, 0, 12, 10, 10, color=TIMBER, mat="WoodPlanks"),
        P("W", 0, 12, 0, 14, 4, 12, 0, 90, 0, "#8a5a3a", "WoodPlanks"),
        P("W", 0, 12.8, 0, 14.6, 4, 12.6, 0, 90, 0, SNOWC, "Snow"),
        P("B", 0, 4, -5.2, 4, 7, 0.6, color="#c9473a", mat="SmoothPlastic"),
        P("B", 3, 0.4, -8, 3, 0.8, 3, color="#2d4f7a", mat="SmoothPlastic", extra={"nc": 1}),
    ]


def pennant_parts(colour: str) -> list:
    """RacePennant (L61): a timber pole on a snow-capped stone footing with a long swallow-tail pennant and a brass
    finial; marks the outside of turns and the open plateau legs in the guide's warm accent colours (Neon cloth: a
    thin flag lit from behind went near-black under the cool ambient, Fabric read as a black plate). Decor (nc):
    placed 50+ studs off the line, never something to crash on. Pivot at the ground, the flag flies toward +X."""
    nc = {"nc": 1}
    return [
        P("B", 0, 1.2, 0, 4.4, 2.4, 4.4, color=FIELD, mat="Granite", extra=nc),
        P("B", 0, 2.6, 0, 4.8, 0.6, 4.8, color=SNOWC, mat="Snow", extra=nc),
        # v29 D3: a plain natural-wood pole (no WoodPlanks/Timber texture, which read as brick) and flat painted cloth
        P("B", 0, 12.0, 0, 1.2, 20.0, 1.2, color="#6b4a2e", mat="SmoothPlastic", extra=nc),
        # critic v28 1.16: painted cloth (Fabric) with a two-wedge wave instead of Neon plates
        P("B", 3.4, 18.8, 0, 6.0, 4.8, 0.5, color=colour, mat="SmoothPlastic", extra=nc),
        P("W", 8.4, 19.6, 0, 3.8, 3.2, 0.5, 0, 0, -90, colour, "SmoothPlastic", nc),
        P("W", 8.4, 17.4, 0, 3.8, 3.2, 0.5, 0, 180, -90, colour, "SmoothPlastic", nc),
        P("B", 2.2, 16.0, 0, 3.0, 0.5, 0.6, color="#f4e8c8", mat="SmoothPlastic", extra=nc),
        P("B", 0, 22.4, 0, 1.8, 1.0, 1.8, color="#e8c46a", mat="SmoothPlastic", extra=nc),
    ]


def build_prefabs() -> dict:
    pf = {
        "RacePennant#red": {"parts": pennant_parts("#c8323a")},
        "RacePennant#gold": {"parts": pennant_parts("#d9922a")},
        "StoneArchBridge": {"parts": bridge_parts()},
        "MountainLodge": {"parts": lodge_parts()},
        "FinishGantry": {"parts": gantry_parts()},
        "TrailGate": {"parts": trail_gate_parts()},
        "KeyAlcoveShrine": {"parts": shrine_parts()},
        "MineTunnelPortal": {"parts": portal_parts()},
        "MineRib": {"parts": mine_rib_parts()},
        "MineRibLamp": {"parts": mine_rib_lamp_parts()},
        "IceFishingHut": {"parts": hut_parts()},
    }
    return {k: pf[k] for k in sorted(pf)}


# ------------------------------------------------------------------------------------------------ corridor checks


class Corridor:
    """The compile gate's flight-corridor boxes (adapt.segment_box), for filtering placements before the gate runs."""

    def __init__(self, tr: Track):
        self.boxes = []
        wps = tr.route.waypoints
        for i in range(len(wps) - 1):
            b = adapt.segment_box(wps[i].pos, wps[i + 1].pos, CORRIDOR["halfWidth"], CORRIDOR["floor"], CORRIDOR["ceiling"])
            if b is not None:
                self.boxes.append(b)
        self.mids = np.array([b[0] for b in self.boxes])

    def hits(self, centres: np.ndarray, halves: np.ndarray, margin: float = 0.0) -> np.ndarray:
        """Per AABB (world): does it intersect any corridor box (optionally grown by margin)?"""
        out = np.zeros(len(centres), bool)
        if len(centres) == 0:
            return out
        reach = np.linalg.norm(halves, axis=1).max() + 140.0
        for mid, axes, half in self.boxes:
            near = np.linalg.norm(centres - mid, axis=1) < reach
            if not near.any():
                continue
            idx = np.nonzero(near & ~out)[0]
            if idx.size == 0:
                continue
            h = adapt.aabbs_hit_obb(centres[idx], halves[idx] + margin, mid, axes, half)
            out[idx[h]] = True
        return out


def prop_library(zone: str = "SNOW") -> dict:
    """{key: (sx, sy, sz)} of the uploaded props of a zone in src/shared/PropLibrary.luau (skips model = nil)."""
    import re
    src = (ROOT / "src" / "shared" / "PropLibrary.luau").read_text()
    out = {}
    for m in re.finditer(r"\n\t(\w+) = \{(.*?)\n\t\},", src, re.S):
        body = m.group(2)
        if f'zone = "{zone}"' not in body or re.search(r"model = nil", body):
            continue
        s = re.search(r"size = Vector3\.new\(([\d.]+), ([\d.]+), ([\d.]+)\)", body)
        out[m.group(1)] = (float(s.group(1)), float(s.group(2)), float(s.group(3)))
    return out


PROPS = prop_library()


def fx_texture(name: str) -> str:
    """rbxassetid of an owned particle texture (src/shared/VfxAssets.luau or the flip set in VfxFlipAssets.luau)."""
    import re
    m = re.search(name + r' = \{ id = "(rbxassetid://\d+)"', (ROOT / "src" / "shared" / "VfxAssets.luau").read_text())
    if not m:
        m = re.search(name + r' = "(rbxassetid://\d+)"', (ROOT / "src" / "shared" / "VfxFlipAssets.luau").read_text())
    assert m, name
    return m.group(1)


# L61 set dressing (skyrally.setDressing, MapAdapter step 7b): the uploaded SNOW props stand in clusters that frame the
# turns, line the river banks at a readable distance, mark the landmarks and fill the plateau fields. Every placement
# is tested here against the compile gate's corridor boxes with its whole AABB (yawed footprint, from the ground up to
# SHELF_RISE + its height, so a snap onto a rock shelf is covered too) plus PROP_MARGIN; nothing collidable stands
# inside the battle arena (ARENA_CLEAR), on the bridge, in the key notch or over the Alt1 tunnel line.
SHELF_RISE = 26.0
PROP_MARGIN = 4.0


class Dresser:
    def __init__(self, tr: "Track", grid: dict, cor: Corridor, land: "Landscape", alt_xz: np.ndarray):
        self.tr, self.grid, self.cor, self.land, self.alt_xz = tr, grid, cor, land, alt_xz
        self.items: list[dict] = []
        self.taken: list[tuple[float, float, float]] = []  # (x, z, footprint radius) for spacing
        gy, gx = np.gradient(grid["H"], GRID["cell"])
        self.slope = np.hypot(gx, gy)
        self.rejected = 0
        self.why: dict = {}

    def footprint(self, key: str, scale: float) -> float:
        sx, _sy, sz = PROPS[key]
        return 0.5 * math.hypot(sx, sz) * scale

    def fits(self, key: str, x: float, z: float, yaw: float, scale: float, *, max_slope: float = 0.9,
             spacing: float = 0.75, allow_ice: bool = False, lodge_ok: bool = False) -> bool:
        if key not in PROPS:
            return False
        sx, sy, sz = (v * scale for v in PROPS[key])
        r = self.footprint(key, scale)
        def no(why: str) -> bool:
            self.why[(key, why)] = self.why.get((key, why), 0) + 1
            return False
        if not (GRID["x0"] + 20 < x < GRID["x1"] - 20 and GRID["z0"] + 20 < z < GRID["z1"] - 20):
            return no("grid")
        if math.hypot(x - LAKE_C[0], z - LAKE_C[1]) - r < ARENA_CLEAR:
            return no("arena")
        if abs(x) < 205 + r and abs(z) < 62 + r:            # bridge and abutments
            return no("bridge")
        if not lodge_ok and math.hypot(x - LODGE[0], z - LODGE[1]) < 64 * LODGE_SCALE + r:
            return no("lodge")
        if in_notch(x, z, 16.0 + r):
            return no("notch")
        if len(self.alt_xz) and float(np.min(np.hypot(self.alt_xz[:, 0] - x, self.alt_xz[:, 1] - z))) < 34 + r:
            return no("alt1")
        iz, ix = grid_node(self.grid, x, z)
        if self.slope[iz, ix] > max_slope:
            return no("slope")
        if not allow_ice and self.grid["mat"][iz, ix] in (3, 4):
            return no("ice")
        for (tx, tz, tr_) in self.taken:
            if math.hypot(tx - x, tz - z) < (tr_ + r) * spacing:
                return no("spacing")
        g = sample_grid(self.grid, x, z)
        half_xz, _R = rotation_halves((sx, 1.0, sz), 0.0, yaw, 0.0)
        top = g + SHELF_RISE + sy
        centre = np.array(W(x, (g - 2.0 + top) / 2, z))
        half = np.array([half_xz[0], (top - g + 2.0) / 2, half_xz[2]])
        if self.cor.hits(centre[None, :], half[None, :], margin=PROP_MARGIN).any():
            return no("corridor")
        return True

    def add(self, key: str, x: float, z: float, yaw: float, scale: float, **kw) -> bool:
        scale = float(min(max(scale, 0.6), 1.6))
        if not self.fits(key, x, z, yaw, scale, **kw):
            self.rejected += 1
            return False
        g = sample_grid(self.grid, x, z)
        self.items.append({"key": key, "pos": W(x, g + 2.0, z), "yaw": r2(yaw % 360.0), "scale": r3(scale), "snap": True})
        self.taken.append((x, z, self.footprint(key, scale)))
        return True

    def counts(self) -> dict:
        out: dict = {}
        for it in self.items:
            out[it["key"]] = out.get(it["key"], 0) + 1
        return dict(sorted(out.items()))


def ring_stations(tr: "Track", land: "Landscape", st_under: float, st_over: float) -> list:
    """(name, station) of the booster rings (gameplay.rings; also framed by the set dressing)."""
    at = tr.station_of
    c1 = land.cascade[1]
    return [
        ("BoosterRing_RiverApproach", st_under - 125.0), ("BoosterRing_UnderArch", st_under),
        ("BoosterRing_GorgeBend", at(-100.0, -420.0)), ("BoosterRing_CascadeTop", c1 + 22.0),
        ("BoosterRing_BasinSweep", at(250.0, -1050.0)), ("BoosterRing_LodgeTurn", at(451.0, -70.0)),
        ("BoosterRing_OverArch", st_over), ("BoosterRing_PineSlope", at(-519.0, 350.0)),
        ("BoosterRing_LakeCrossing", at(-247.0, 676.0)),
    ]


def turn_stations(tr: "Track", step: float = 20.0, span: float = 70.0, min_deg: float = 28.0):
    """Stations of the lap's turns (heading change over +-span above min_deg), one per turn: (station, sign) with sign
    +1 when the turn bends right (the outside is the left, lateral < 0)."""
    def heading(s):
        _p, t, _r, _u = tr.frame(s % tr.length)
        return math.atan2(t[2], t[0])
    rows = []
    s = 0.0
    while s < tr.length:
        d = math.degrees((heading(s + span) - heading(s - span) + math.pi) % (2 * math.pi) - math.pi)
        rows.append((s, d))
        s += step
    turns, cur = [], []
    for s, d in rows + [(tr.length, 0.0)]:
        if abs(d) >= min_deg:
            cur.append((s, d))
        elif cur:
            s_best, d_best = max(cur, key=lambda r: abs(r[1]))
            turns.append((s_best, 1 if d_best > 0 else -1))
            cur = []
    return turns


def instance_aabbs(prefabs: dict, inst: dict):
    """World AABBs (centres, half extents) of an instance's collidable parts, exactly as the compile gate sees them."""
    return adapt.collidable_parts({"prefabs": {inst["pf"]: prefabs[inst["pf"]]}, "instances": [inst]})[:2]


# ------------------------------------------------------------------------------------------------ placement


def sample_grid(grid: dict, x: float, z: float) -> float:
    """Bilinear height between grid nodes (the compiled builder's height())."""
    c = GRID["cell"]
    fx = (min(max(x, GRID["x0"]), GRID["x1"]) - GRID["x0"]) / c
    fz = (min(max(z, GRID["z0"]), GRID["z1"]) - GRID["z0"]) / c
    ix = min(max(int(math.floor(fx)), 0), grid["nx"] - 2)
    iz = min(max(int(math.floor(fz)), 0), grid["nz"] - 2)
    tx, tz = fx - ix, fz - iz
    H = grid["H"]
    a, b, cc, d = H[iz, ix], H[iz, ix + 1], H[iz + 1, ix], H[iz + 1, ix + 1]
    u = a + (b - a) * tx
    v = cc + (d - cc) * tx
    return float(u + (v - u) * tz)


def grid_node(grid: dict, x: float, z: float):
    ix = int(round((x - GRID["x0"]) / GRID["cell"]))
    iz = int(round((z - GRID["z0"]) / GRID["cell"]))
    ix = min(max(ix, 0), grid["nx"] - 1)
    iz = min(max(iz, 0), grid["nz"] - 1)
    return iz, ix


def offset_path(tr: Track, s0, s1, lateral, height, ramp, step, min_offset, ramp_in=None):
    """author_dino4.offset_path on this route: eased lateral/height offset so both ends sit on the race line; points
    nearer the line than min_offset are dropped (the alternate starts as a mouth beside the course). Local coords.
    ramp_in (default ramp) eases the entry end on its own, so the mouth can face the approach (SN-06)."""
    pts = []
    s_ = s0
    ramp_in = ramp if ramp_in is None else ramp_in
    while s_ <= s1 + 1e-6:
        k = float(min(smooth((s_ - s0) / ramp_in), smooth((s1 - s_) / ramp)))
        p, _t, r, _u = tr.frame(s_)
        q = p + r * lateral * k + np.array([0.0, height * k, 0.0])
        if abs(lateral * k) >= min_offset:
            pts.append((s_, q, k))
        s_ += step
    return pts


# lateral -140 puts the tube inside the west wall (the river-side face of the tube has 34+ studs of terrain beside it;
# at -104 it ran along the foot of a terrace riser with the whole river-side wall and roof exposed); `cover` is the
# grid spur crest over the tube floor (roof top is +34), so the tube is buried in Terrain, not under stacked slabs
# SN-06 (docs/audits/traps_snow1.md): `bell` opens a flared open cut in the rock in front of the entry mouth (shells
# below, bell_segments) and the portal posts are decor (portal_parts). `ramp_in` can ease the entry end on its own, but
# it stays at `ramp`: longer entry ramps (240, 300) turned the mouth only 20 degrees and moved it 30-60 stations deeper
# along the west cliff, which crashed more swerving planes (audit sim: 46 and 58 of 80, against 36 at 170)
ALT1 = {"id": "Alt1", "from_xz": (-12.0, -215.0), "to_xz": (-77.0, -600.0), "lateral": -140.0, "height": 8.0, "ramp": 170.0,
        "ramp_in": 170.0, "step": 30.0, "min_offset": 55.0, "portal_offset": 55.0, "cover": 46.0, "bell": 200.0}


BELL_RISE = 0.5  # the wide part of the funnel is an open cut (no rock roof strip along the wall foot)
BELL_POW = 0.35  # concave: the funnel is already wide where it meets the rock face, not only at the corridor edge


def bell_segments(tr: Track, alt) -> list:
    """SN-06: the entry funnel in front of the Alt1 mouth, as (a, b, width) segments along the eased alt line (local),
    from the corridor edge (CORRIDOR.halfWidth) out to the first tunnel point, width easing from ALT1.bell to 26."""
    s_first = alt[0][0]
    lat0 = CORRIDOR["halfWidth"]
    lat1 = abs(ALT1["lateral"] * alt[0][2])
    pre = [(s_, q, k) for s_, q, k in offset_path(tr, tr.station_of(*ALT1["from_xz"]), tr.station_of(*ALT1["to_xz"]),
                                                   ALT1["lateral"], ALT1["height"], ALT1["ramp"], 5.0, lat0,
                                                   ALT1["ramp_in"])
           if s_ <= s_first + 1e-6]
    out = []
    for (_sa, qa, ka), (_sb, qb, kb) in zip(pre, pre[1:]):
        lat = abs(ALT1["lateral"]) * (ka + kb) / 2
        u = float(np.clip((lat - lat0) / max(1.0, lat1 - lat0), 0.0, 1.0))
        out.append((qa, qb, 26.0 + (ALT1["bell"] - 26.0) * (1.0 - u) ** BELL_POW))
    return out


# the hidden-key notch (local): open to the river on the east, back wall at x0, floor/top heights; terrain stays above
# SN-07 (docs/audits/traps_snow1.md): the slot is 76 deep (back wall x0 -104 -> -116) and runs 16 further north
# (z0 -170 -> -186); the key sits 18 nearer the line (lateral ~-94 -> ~-76) and the shrine 18 deeper in a larger niche,
# so the key's 16-stud pickup sphere ends 40+ studs short of the shrine face (it touched it before) and a swerve that
# grabs the key has room to turn back out
KEY_NOTCH = {"x0": -116.0, "x1": -40.0, "z0": -186.0, "z1": -50.0, "floor": 46.0, "top": 76.0}
# the key (local) and the shrine at the notch's back wall; the niche is a ball carved NICHE_IN in front of the shrine
KEY_POS = (-74.0, 56.0, -116.0)
SHRINE_POS = (-132.0, 46.0, -116.0)
NICHE_IN, NICHE_R = 10.0, 26.0


def allow_pockets() -> list:
    """Secret-route volumes where the default flight mode never resets a plane (FLIGHT_GUIDE.md 12.3). The hidden-key notch
    runs 65-120 studs from the course lines (key 76, back wall ~118) and its shrine niche (x -132) is 135 from them,
    past BOUND 130: one capsule along the notch's centre line, from its mouth to the shrine niche, radius 45 (covers the
    whole 136-stud-long slot and the niche; the nearest other flyable space is the river, already inside BOUND)."""
    return [{"kind": "capsule", "a": W(-48.0, 61.0, KEY_POS[2]), "b": W(SHRINE_POS[0] + 8.0, 52.0, KEY_POS[2]),
             "radius": 45.0,
             "note": "SNOW-1 hidden-key notch behind the west pier (key 76 studs off the line, shrine niche 135)"}]


def in_notch(x: float, z: float, margin: float = 0.0) -> bool:
    n = KEY_NOTCH
    return n["x0"] - margin <= x <= n["x1"] + margin and n["z0"] - margin <= z <= n["z1"] + margin


def rotation_halves(size, rx, ry, rz):
    R = adapt.rot_yxz(rx, ry, rz)
    return np.abs(R) @ (np.array(size, float) * 0.5), R


def build():
    tr = Track()
    land = Landscape(tr)
    grid = land.build_grid()
    cor = Corridor(tr)
    prefabs = build_prefabs()
    rng = np.random.default_rng(SEED + 11)
    L = tr.length
    groups = ["Landmarks", "Forest", "FrozenLake", "Gorge"]
    G_LM, G_FOREST, G_LAKE, G_GORGE = 1, 2, 3, 4
    instances: list[dict] = []
    notes: dict = {}

    def add(pf, x, y, z, g, r=0.0, s=1.0):
        inst = {"pf": pf, "p": W(x, y, z), "g": g, "r": r2(r) if not isinstance(r, list) else [r2(v) for v in r], "s": r3(s)}
        instances.append(inst)
        return inst

    # --- landmarks ---------------------------------------------------------------------------------------------
    # the two crossings of the bridge centre: the under-pass (river) and the over-pass (deck run)
    st_under = float(min((s for s in tr.dense_st if s < 1500), key=lambda s: abs(tr.pos(s)[2])))
    st_over = float(min((s for s in tr.dense_st if 2900 < s < 3700), key=lambda s: abs(tr.pos(s)[0])))
    add("StoneArchBridge", 0, 0, 0, G_LM)
    add("MountainLodge", LODGE[0], LODGE_Y, LODGE[1], G_LM, LODGE_YAW, s=LODGE_SCALE)
    p0, t0, r0, _ = tr.frame(0.0)
    add("FinishGantry", p0[0], p0[1], p0[2], G_LM, yaw_right(r0[0], r0[2]), s=GATE_SCALE)
    # key notch behind the west pier, just past the arch on the under route: a 120-stud slot along the west wall under
    # a rock lip (KEY_NOTCH), long enough to swerve in and out at cruise speed (min turn radius ~31-44 studs), with the
    # shrine in a niche at its back
    key_pos = np.array(KEY_POS)
    add("KeyAlcoveShrine", SHRINE_POS[0], SHRINE_POS[1], SHRINE_POS[2], G_GORGE, yaw_to(1.0, 0.0))
    # ice fishing huts on the lake (survival cover), well north of the crossing
    # SN-03: the middle hut stood 4 studs off the north seat's line to the centre; it moves 18 west
    huts = [(-372.0, 548.0, 20.0), (-270.0, 516.0, -35.0), (-128.0, 552.0, 60.0)]
    for x, z, yaw in huts:
        add("IceFishingHut", x, LAKE_ICE, z, G_LAKE, yaw)
    # glacier crystals at the cascade banks and the glacier tongue (L61: the uploaded snow_ice_crystals prop; the
    # block-built IceCrystalCluster read as translucent cubes in game, its cones fall back to stepped tiers)
    c0, c1 = land.cascade
    crystal_sites = []
    for s_, lat in ((c0 - 10.0, -62.0), (c0 + 18.0, 64.0), (c1 - 10.0, -66.0), (c1 + 12.0, 60.0)):
        q = tr.offset(s_, lat, 0.0)
        crystal_sites.append((float(q[0]), float(q[2]), float(rng.integers(0, 360)), 1.35))
    for x, z in ((-70.0, -1010.0), (14.0, -1090.0), (-80.0, -1180.0), (40.0, -1240.0)):
        crystal_sites.append((x, z, float(rng.integers(0, 360)), 1.55))

    # --- Alt1: the mine tunnel in the west gorge wall ------------------------------------------------------------
    alt_s0, alt_s1 = land.alt_s
    alt = land.alt
    alt_pts = [q for _s, q, _k in alt]
    # portals at the tunnel mouths: the outermost alt point (walking inward) where the portal stays out of the race
    # corridor; the mouth carve (shells) opens the rock in front of it
    deep = [(s_, q, k) for s_, q, k in alt if abs(ALT1["lateral"] * k) >= ALT1["portal_offset"]]
    portal_st = []
    for seq in (deep, deep[::-1]):
        for j in range(len(seq) - 1):
            (s_a, qa, _ka), (_sb, qb, _kb) = seq[j], seq[j + 1]
            d = qb - qa  # into the tunnel; the portal's front faces back out toward the river
            inst = {"pf": "MineTunnelPortal", "p": W(qa[0], qa[1] - 1.8, qa[2]), "g": G_GORGE, "r": r2(yaw_to(-d[0], -d[2])), "s": 1}
            c, hv = instance_aabbs(prefabs, inst)
            if not cor.hits(c, hv, margin=1.0).any():
                instances.append(inst)
                portal_st.append(s_a)
                break
    notes["alt1Portals"] = [round(v, 1) for v in portal_st]
    # v29 D6: decor timber ribs (nc) every alt step through the tube, a lantern rib on every third
    for j in range(1, len(deep) - 1):
        (_sa, qa, _ka), (_sb, qb, _kb) = deep[j], deep[j + 1]
        d = qb - qa
        inst = {"pf": "MineRibLamp" if j % 3 == 1 else "MineRib", "p": W(qa[0], qa[1] - 1.8, qa[2]), "g": G_GORGE,
                "r": r2(yaw_to(d[0], d[2])), "s": 1}
        instances.append(inst)

    # --- pines and set dressing (L61) --------------------------------------------------------------------------
    # The block-built SnowPine prefabs read as stacked cubes from the chase camera (critic r0: "blocky trees, graybox");
    # the forest is now the uploaded snow_pine_cluster prop (three faceted snow-loaded firs per clone), and the other
    # SNOW props stand in authored clusters. Set pieces claim their ground first, the forest fills in around them.
    H = grid["H"]
    gy, gx = np.gradient(H, GRID["cell"])
    slope_g = np.hypot(gx, gy)
    dense = tr.dense
    alt_xz = np.array([[q[0], q[2]] for q in alt_pts])
    dz_ = Dresser(tr, grid, cor, land, alt_xz)
    rng_d = np.random.default_rng(SEED + 61)
    PINE, ROCKS, CRYST, LAMP = "snow_pine_cluster", "snow_frozen_rocks", "snow_ice_crystals", "snow_lantern_post"
    HUT, SLED, SNOWMAN, FENCE = "snow_fishing_hut", "snow_sled_presents", "snow_snowman", "snow_timber_fence"
    lamp_lights: list[tuple[float, float]] = []
    gameplay_rings_for_dressing = [(n_, s_) for n_, s_ in ring_stations(tr, land, st_under, st_over)]

    def at_lat(s_: float, lat: float, along: float = 0.0):
        p, t, r, _u = tr.frame(s_ % L)
        q = p + r * lat + t * along
        return float(q[0]), float(q[2]), (float(r[0]), float(r[2])), (float(t[0]), float(t[2]))

    def yaw_z_to(dx: float, dz: float) -> float:   # local +Z onto (dx, dz)
        return math.degrees(math.atan2(dx, dz))

    def yaw_x_to(dx: float, dz: float) -> float:   # local +X onto (dx, dz)
        return math.degrees(math.atan2(-dz, dx))

    def jitter() -> float:
        return float(rng_d.random() * 360.0)

    # 1. start/finish and the arch approach: lantern posts on both river banks (warm accents in the cold scene; the arm
    #    hangs over the ice), spectators (snowmen, a sled of presents) behind short fence runs beside the gantry
    for s_ in [L - 200.0 + 40.0 * k for k in range(5)] + [10.0 + 40.0 * k for k in range(4)]:
        for side in (-1.0, 1.0):
            x, z, r_, _t = at_lat(s_, side * (RIVER_HALF + 10.0))
            if dz_.add(LAMP, x, z, yaw_z_to(-side * r_[0], -side * r_[1]), 1.0, spacing=0.5):
                lamp_lights.append((x, z))
    for s_, side, items in ((L - 30.0, -1.0, (SNOWMAN, SLED)), (L - 55.0, 1.0, (SNOWMAN, FENCE)),
                            (60.0, 1.0, (SLED, SNOWMAN)), (95.0, -1.0, (SNOWMAN, FENCE))):
        for j, key in enumerate(items):
            x, z, r_, t_ = at_lat(s_, side * (RIVER_HALF + 26.0 + 6.0 * j), along=12.0 * j)
            if key == SNOWMAN:
                dz_.add(key, x, z, yaw_x_to(-side * r_[0], -side * r_[1]) + float(rng_d.integers(-25, 25)), 1.1)
            elif key == FENCE:
                for f in range(3):
                    fx_, fz_ = x + t_[0] * 9.6 * (f - 1), z + t_[1] * 9.6 * (f - 1)
                    dz_.add(FENCE, fx_, fz_, yaw_z_to(*t_) + float(rng_d.integers(-4, 4)), 1.0, spacing=0.3)
            else:
                dz_.add(key, x, z, yaw_z_to(*t_) + float(rng_d.integers(-30, 30)), 1.2)

    # 2. the mountain lodge becomes a hamlet: two cabins, a lantern path to the line, a sled, snowmen, fence runs
    lod_f = adapt.rot_yxz(0, LODGE_YAW, 0) @ np.array([0.0, 0.0, -1.0])   # porch direction
    lod_r = adapt.rot_yxz(0, LODGE_YAW, 0) @ np.array([1.0, 0.0, 0.0])
    def lod(a: float, b: float):                                          # (along porch, right) -> x, z
        return (LODGE[0] + (lod_f[0] * a + lod_r[0] * b) * LODGE_SCALE, LODGE[1] + (lod_f[2] * a + lod_r[2] * b) * LODGE_SCALE)
    for (a, b_, key, yaw_off, sc) in ((-6.0, 62.0, HUT, 180.0, 1.25), (-22.0, -52.0, HUT, 200.0, 1.15),
                                      (40.0, 30.0, SNOWMAN, 0.0, 1.15), (46.0, -24.0, SLED, 70.0, 1.2),
                                      (30.0, 52.0, ROCKS, 0.0, 1.2), (-40.0, 40.0, PINE, 0.0, 1.3),
                                      (-52.0, -10.0, PINE, 0.0, 1.35), (-30.0, 92.0, PINE, 0.0, 1.2)):
        x, z = lod(a, b_)
        dz_.add(key, x, z, LODGE_YAW + yaw_off + float(rng_d.integers(-12, 12)), sc, lodge_ok=True, max_slope=1.2)
    for k in range(4):                                                    # lantern path from the porch toward the line
        for side in (-1.0, 1.0):
            x, z = lod(34.0 + 22.0 * k, side * 11.0)
            if dz_.add(LAMP, x, z, LODGE_YAW + 90.0 * side, 1.0, lodge_ok=True, spacing=0.4):
                lamp_lights.append((x, z))
    for k in range(5):                                                    # fence run along the yard edge
        x, z = lod(14.0 + 9.6 * k, 34.0)
        dz_.add(FENCE, x, z, LODGE_YAW, 1.0, lodge_ok=True, spacing=0.3)

    # 3. turn landmarks: on the outside of every turn a crystal outcrop with frozen rocks, a lantern at the edge and a
    #    pine stand behind, so each bend is announced 4-6 s out; a low rock pair on the inside
    turns = turn_stations(tr)
    notes["turnStations"] = [round(s_, 1) for s_, _sg in turns]
    for s_, sign in turns:
        out = -float(sign)
        placed_any = False
        for lat0 in (78.0, 96.0, 118.0):
            x, z, r_, t_ = at_lat(s_, out * lat0)
            if dz_.add(CRYST, x, z, jitter(), 1.3 + 0.15 * rng_d.random()):
                placed_any = True
                for along, dl, sc in ((-16.0, 6.0, 1.3), (15.0, -4.0, 1.0), (30.0, 10.0, 1.4)):
                    x2, z2, _r2, _t2 = at_lat(s_, out * (lat0 + dl), along=along)
                    dz_.add(ROCKS, x2, z2, jitter(), sc)
                x3, z3, _r3, _t3 = at_lat(s_, out * (lat0 - 22.0), along=-34.0)
                if dz_.add(LAMP, x3, z3, yaw_z_to(-out * r_[0], -out * r_[1]), 1.0, spacing=0.5):
                    lamp_lights.append((x3, z3))
                for along in (-40.0, 0.0, 40.0):
                    x4, z4, _r4, _t4 = at_lat(s_, out * (lat0 + 38.0), along=along)
                    dz_.add(PINE, x4, z4, jitter(), 1.2 + 0.2 * rng_d.random())
                break
        if not placed_any:
            for lat0 in (70.0, 90.0):
                x, z, _r, _t = at_lat(s_, out * lat0)
                if dz_.add(ROCKS, x, z, jitter(), 1.4):
                    break
        x, z, _r, _t = at_lat(s_, -out * 70.0, along=8.0)
        dz_.add(ROCKS, x, z, jitter(), 0.95)

    # 3b. the cascade and glacier-tongue crystal outcrops, and a boulder-and-fir frame beside every booster ring (the
    #     lateral dead space near the gates; critic r1)
    for x, z, yaw, sc in crystal_sites:
        dz_.add(CRYST, x, z, yaw, sc, max_slope=1.8, allow_ice=True, spacing=0.5)
    for ring in gameplay_rings_for_dressing:
        for side in (-1.0, 1.0):
            for lat0 in (64.0, 80.0):
                x, z, _r, _t = at_lat(ring[1], side * lat0, along=-20.0)
                if dz_.add(ROCKS, x, z, jitter(), 1.15 + 0.3 * rng_d.random(), max_slope=1.6):
                    x2, z2, _r2, _t2 = at_lat(ring[1], side * (lat0 + 22.0), along=-4.0)
                    dz_.add(PINE, x2, z2, jitter(), 1.2 + 0.15 * rng_d.random(), max_slope=1.0)
                    break

    # 3c. lane markers on the open plateau legs (critic r1: "the lane is lost in the white field sections"): lantern
    #     posts in pairs every ~110 stations, 52 studs either side of the line, like a groomed piste
    for s_ in np.arange(40.0, L, 110.0):
        if s_ >= land.lake_from - 60 or s_ <= land.north_st + 60:
            continue
        for side in (-1.0, 1.0):
            x, z, r_, _t = at_lat(float(s_), side * 52.0)
            if dz_.add(LAMP, x, z, yaw_z_to(-side * r_[0], -side * r_[1]), 1.0, spacing=0.5, max_slope=1.0):
                if int(s_ / 110.0) % 2 == 0:
                    lamp_lights.append((x, z))

    # 3d. race pennants (30MAPS prefab instances, decor): a run of five on the outside of every turn, one pair every
    #     ~220 stations along the open legs, alternating red and gold (critic r2: "side markers in an accent colour")
    pennant_n = 0
    def pennant(s_: float, lat: float, colour: str) -> None:
        nonlocal pennant_n
        x, z, r_, t_ = at_lat(s_, lat)
        if not dz_.fits(LAMP, x, z, 0.0, 1.0, spacing=0.4, max_slope=1.2):
            return
        g = sample_grid(grid, x, z)
        # the flag flies away from the line (local +X onto the outward lateral direction)
        out = 1.0 if lat > 0 else -1.0
        add(f"RacePennant#{colour}", x, g - 0.6, z, G_LM, yaw_x_to(out * r_[0], out * r_[1]) + float(rng_d.integers(-10, 10)))
        dz_.taken.append((x, z, 4.0))
        pennant_n += 1
    for s_, sign in turns:
        for k in range(-2, 3):
            pennant(s_ + 26.0 * k, -float(sign) * 58.0, "red" if k % 2 == 0 else "gold")
    for s_ in np.arange(95.0, L, 220.0):
        if s_ >= land.lake_from - 60 or s_ <= land.north_st + 60:
            continue
        for side in (-1.0, 1.0):
            pennant(float(s_), side * 58.0, "gold" if int(s_ / 220.0) % 2 else "red")
    notes["pennants"] = pennant_n

    # 4. the glacial basin knoll: a crystal crown and boulders on the knoll the sweep circles (the vista beat)
    for k, (dx, dzz, key, sc) in enumerate(((0.0, 0.0, CRYST, 1.55), (16.0, 10.0, CRYST, 1.15), (-14.0, 12.0, ROCKS, 1.4),
                                            (10.0, -18.0, ROCKS, 1.2), (-22.0, -12.0, CRYST, 1.0), (30.0, -6.0, ROCKS, 1.0))):
        dz_.add(key, KNOLL[0] + dx, KNOLL[1] + dzz, jitter(), sc, max_slope=1.2, spacing=0.4)

    # 5. river banks: frozen boulder groups (and now and then a crystal) on the snow lip just past the ice, alternating
    #    sides, every ~45 stations along the gorge and the river mouth
    river_sts = [s_ for s_ in np.arange(0.0, L, 45.0) if s_ >= land.mouth_st or s_ <= land.north_st]
    for i, s_ in enumerate(river_sts):
        if rng_d.random() < 0.25:
            continue
        side = -1.0 if (i + int(rng_d.integers(0, 2))) % 2 else 1.0
        lat = side * (RIVER_HALF + 12.0 + 10.0 * rng_d.random())
        x, z, _r, t_ = at_lat(s_, lat)
        key = CRYST if i % 5 == 2 else ROCKS
        if dz_.add(key, x, z, jitter(), 1.0 + 0.45 * rng_d.random(), max_slope=1.6):
            if rng_d.random() < 0.6:
                x2, z2 = x + t_[0] * 11.0 + _r[0] * side * 5.0, z + t_[1] * 11.0 + _r[1] * side * 5.0
                dz_.add(ROCKS, x2, z2, jitter(), 0.8 + 0.3 * rng_d.random(), max_slope=1.6, spacing=0.5)

    # 5b. critic v28 1.19: two big secondary gates (decor, st 2315 and 3536), lantern pairs either side of every bend
    for gs_ in TRAIL_GATES:
        gp_, _gt, gr_, _gu = tr.frame(gs_)
        add("TrailGate", gp_[0], gp_[1], gp_[2], G_LM, yaw_right(gr_[0], gr_[2]))
        for sx in (-1.0, 1.0):
            gx_, gz_, _a, _b = at_lat(gs_, sx * 70.0)
            dz_.taken.append((gx_, gz_, 14.0))
    for s_, sign in turns:
        for along in (-60.0, 60.0):
            for side in (-1.0, 1.0):
                x, z, r_, _t = at_lat(s_ + along, side * 50.0)
                if dz_.add(LAMP, x, z, yaw_z_to(-side * r_[0], -side * r_[1]), 1.0, spacing=0.5, max_slope=1.2):
                    lamp_lights.append((x, z))

    # 6. pines lining the route at a readable distance (the guide's tall firs on both rims), then the forest
    for s_ in np.arange(0.0, L, 34.0):
        for side in (-1.0, 1.0):
            if rng_d.random() < 0.38:
                continue
            x, z, _r, _t = at_lat(float(s_), side * (54.0 + 30.0 * rng_d.random()))  # v28 1.19: banks pulled inward
            dz_.add(PINE, x, z, jitter(), 1.05 + 0.3 * rng_d.random())
    # pine clumps of 3, 5 or 7 around grove seeds (critic r1: "trees copy-pasted, evenly spaced"), leaving vista gaps
    for _k in range(70):
        cx = GRID["x0"] + 40 + rng_d.random() * (GRID["x1"] - GRID["x0"] - 80)
        cz = GRID["z0"] + 200 + rng_d.random() * (GRID["z1"] - GRID["z0"] - 260)
        dr = float(np.min(np.hypot(dense[:, 0] - cx, dense[:, 2] - cz)))
        if not (70.0 < dr < 360.0):
            continue
        n = int(rng_d.choice([3, 5, 7]))
        for j in range(n):
            a = rng_d.random() * 2 * math.pi
            rr = 10.0 + 34.0 * math.sqrt(rng_d.random())
            dz_.add(PINE, cx + rr * math.cos(a), cz + rr * math.sin(a), jitter(), 0.95 + 0.4 * rng_d.random(),
                    max_slope=0.7, spacing=0.55)
    pines = []
    spacing = 46.0
    for iz in range(int((GRID["z1"] - GRID["z0"]) / spacing)):
        for ix in range(int((GRID["x1"] - GRID["x0"]) / spacing)):
            x = GRID["x0"] + (ix + rng.random()) * spacing
            z = GRID["z0"] + (iz + rng.random()) * spacing
            roll = rng.random()
            kind_roll = rng.random()
            sc = 0.85 + 0.45 * rng.random()
            yaw = float(rng.integers(0, 360))
            if not (GRID["x0"] + 16 < x < GRID["x1"] - 16 and GRID["z0"] + 16 < z < GRID["z1"] - 16):
                continue
            nz_, nx_ = grid_node(grid, x, z)
            if grid["mat"][nz_, nx_] in (3, 4) or slope_g[nz_, nx_] > 0.62:
                continue
            h = sample_grid(grid, x, z)
            if h > 300.0:
                continue
            dr = float(np.min(np.hypot(dense[:, 0] - x, dense[:, 2] - z)))
            if dr < 44.0:
                continue
            if math.hypot((x - LAKE_C[0]) / LAKE_R[0], (z - LAKE_C[1]) / LAKE_R[1]) < 1.12:
                continue
            dv, _ice, _side, _gl, _ = land.river_field(np.array([x]), np.array([z]))
            if dv[0] < RIVER_HALF + 14.0:
                continue
            grove = float(NOISE_B(x / 140.0 + 40.0, z / 140.0 - 11.0))  # pines stand in groves, not a lawn
            forest = any(fx0 <= x <= fx1 and fz0 <= z <= fz1 for fx0, fz0, fx1, fz1 in FORESTS)
            w = (0.62 if dr < 200 else (0.3 if dr < 420 else 0.12)) * (0.3 + 1.1 * grove)
            if forest:
                w = max(w, 0.78 if dr < 180 else 0.4)
            if roll > w:
                continue
            kind = "Tall" if kind_roll < 0.45 else ("Mid" if kind_roll < 0.82 else "Small")
            sc = {"Tall": 1.18, "Mid": 1.0, "Small": 0.84}[kind] * (0.92 + 0.16 * (sc - 0.85) / 0.45)
            if kind == "Tall" and dr < 260:
                sc = sc * 1.1  # the guide's pines tower over the river
            pines.append((x, z, sc, yaw))
    for x, z, sc, yaw in pines:
        dz_.add(PINE, x, z, yaw, sc, max_slope=0.62, spacing=0.7)

    # 6b. W2 critic 3.4 / guide 05: tall pines at the arch abutments, flanking both bridge faces beyond the piers (outside
    # the under-pass |x| < 34 and the over-pass |z| < 34 corridors, decor props with the usual clearance checks)
    for k_, (x, z, sc, yaw) in enumerate(ABUTMENT_PINES):
        ok_ = dz_.add(PINE, x, z, yaw, sc, max_slope=1.2, spacing=0.3)
        notes.setdefault("abutmentPines", []).append(bool(ok_))

    # 7. open plateau and basin fields: low frozen boulder groups break up the empty snow
    for _k in range(220):
        x = GRID["x0"] + 40 + rng_d.random() * (GRID["x1"] - GRID["x0"] - 80)
        z = -1000.0 + rng_d.random() * 1700.0
        dr = float(np.min(np.hypot(dense[:, 0] - x, dense[:, 2] - z)))
        if not (70.0 < dr < 320.0):
            continue
        if dz_.add(ROCKS, x, z, jitter(), 0.9 + 0.6 * rng_d.random(), max_slope=0.8, spacing=1.6):
            if rng_d.random() < 0.5:
                dz_.add(ROCKS, x + 9.0, z + 6.0, jitter(), 0.8, max_slope=0.9, spacing=0.4)
    notes["setDressing"] = dz_.counts()
    notes["setDressingRejected"] = dz_.rejected
    if "--why" in sys.argv:
        print(sorted(dz_.why.items(), key=lambda kv: -kv[1]))
    dressing = dz_.items

    # --- gameplay ----------------------------------------------------------------------------------------------
    at = tr.station_of
    c0, c1 = land.cascade
    cps = [round(k * 415.0, 1) for k in range(12)]
    rings = ring_stations(tr, land, st_under, st_over)
    rings = [{"name": n, "station": round(s_, 1), "lateral": 0, "height": LINE, "coin": False, "coinId": None}
             for n, s_ in rings]
    pads = [{"name": "GroundBoost_RiverIce", "station": round(at(0.0, 400.0), 1), "lateral": 0},
            {"name": "GroundBoost_BridgeDeck", "station": round(st_over - 80.0, 1), "lateral": 0},
            {"name": "GroundBoost_LakeIce", "station": round(at(-297.0, 677.0), 1), "lateral": 0}]
    # Item cubes v3 (docs/design/ITEM_BOXES.md; rules in tools/map/item_cubes.json): 7 staggered two-deep clusters of 5
    # mystery cubes (owner: "do we need to provide more cubes to be available in the air plane?"; v2 had 3 a cluster):
    # a front rank of 2 (lateral -6/+6 at +3/-3) and a back rank of 3 (-10/0/+10 at -3/+3/-3) 36 studs on, round the
    # old pod height, every 680-800 studs. Fixed race stations clear of rings, pads and coins: the river before the
    # Alt1 split, the cascade run, the basin, the plateau before the lodge ring, past the over-arch, the pine slope and
    # the lake. The Speed pickups (mint boost blocks) sit mid-gap, away from the clusters (the cascade one at 1300: the
    # middle of its gap is the BasinSweep ring).
    # SNOW-1 launch upgrade (TRACK_VARIETY 5a): the over/under crossing is the identity, so both passes arrive armed.
    # The over-pass (st ~3085) is fed by DeckPods at 2930 (back rank 2966, ~120 studs / 0.9 s before the deck run; it
    # was 3200, past the arch). The under-pass (st ~235, after the line) is fed by the lake set at 4600 (~635 studs
    # before it, no pod in between), so a racer holding an item from either set crosses with it in hand. The Slope set
    # moves 3920 -> 3750 and the Plateau set 2500 -> 2450 to keep the 450-900 gaps (the boost pad sits at 3005, so the
    # deck set ends 39 studs short of it).
    pod_rows = [(400.0, "RiverPods"), (1100.0, "CascadePods"), (1800.0, "BasinPods"), (2450.0, "PlateauPods"),
                (2930.0, "DeckPods"), (3750.0, "SlopePods"), (4600.0, "LakePods")]
    set_st = [s_ for s_, _ in pod_rows]
    pods = []
    for k, (s_, row) in enumerate(pod_rows):
        pods += item_rows.cube_set("plane", "snow1", k, s_, 12, lambda typ, i, row=row: f"{row}_{typ}Pod_{i}", row)
    for k, row, s_ in ((1, "CascadeSingle", 1300.0), (3, "PlateauSingle", None), (4, "DeckSingle", None)):
        s_ = s_ if s_ is not None else item_rows.gap_single("plane", set_st, k, tr.length)
        pods.append(item_rows.speed_single(f"{row}_SpeedPod", s_, 12))
    item_rows.assert_layout({"pods": pods}, "plane", "snow1", tr.length)
    alt_mid = alt[len(alt) // 2]
    coins = [
        {"id": "Coin_1", "station": at(5.0, 380.0), "lateral": 18, "height": 8},
        {"id": "Coin_2", "station": st_under + 48.0, "lateral": -16, "height": 26},
        {"id": "Coin_3", "station": alt_mid[0], "lateral": round(ALT1["lateral"] * alt_mid[2], 1),
         "height": round(ALT1["height"] * alt_mid[2] + LINE, 1), "line": "Alt1"},
        {"id": "Coin_4", "station": c0 + 26.0, "lateral": 10, "height": 6},
        {"id": "Coin_5", "station": at(454.0, -944.0), "lateral": -20, "height": 22},
        {"id": "Coin_6", "station": at(370.0, -14.0), "lateral": 22, "height": 20},
        {"id": "Coin_7", "station": st_over + 60.0, "lateral": 0, "height": 30},
        {"id": "Coin_8", "station": at(-430.0, 646.0), "lateral": -22, "height": 6},
    ]
    for c in coins:
        c["station"] = round(float(c["station"]), 1)
    # hidden key: behind the west pier, past the arch on the under route
    ks = float(min(tr.dense_st[(tr.dense_st > st_under) & (tr.dense_st < st_under + 200)],
                   key=lambda s_: abs(tr.pos(s_)[2] - key_pos[2])))
    kp, _kt, kr, ku = tr.frame(ks)
    key = {"station": round(ks, 1), "lateral": round(float(np.dot(key_pos - kp, kr)), 1),
           "height": round(float(key_pos[1] - kp[1]), 1), "alcove": "KeyAlcoveShrine",
           "note": "behind the over/under stone arch on the under route: a notch along the west gorge wall behind the "
                   "west pier (fly in and out under the rock lip); shrine niche at its back"}
    # battle overlay: survival on the frozen lake basin (LAUNCH_PROGRESSION 2b)
    lc = np.array([LAKE_C[0], LAKE_ICE + LINE, LAKE_C[1]])
    spawns = [W(lc[0] + dx, lc[1], lc[2] + dz) for dx, dz in ((-190.0, 0.0), (190.0, 0.0), (0.0, -120.0), (0.0, 120.0))]
    pickups = []
    # SN-04: the east/west Red pods sit at radius 90 (x +-126), 64 studs from seats 1/2 (they were 22 away at 120, so a
    # bot re-arming there could hit a player respawning on the seat)
    for i, (a_deg, rad, typ) in enumerate(((0, 90, "Red"), (60, 105, "Green"), (120, 120, "Yellow"), (180, 90, "Red"),
                                          (240, 105, "Green"), (300, 120, "Yellow"), (90, 40, "Red"), (270, 40, "Yellow"))):
        a = math.radians(a_deg)
        pickups.append({"pos": W(lc[0] + rad * math.cos(a) * 1.4, lc[1] - 2.0, lc[2] + rad * math.sin(a) * 0.9),
                        "types": [typ], "respawn": 12, "level": 1})
    modes = {"battle": {
        "kind": "survival", "zoneId": "SNOW-BATTLE", "vehicle": "plane",
        "center": W(*lc), "radius": ARENA["radius"],
        "boundary": {"shape": "cylinder", "center": W(lc[0], LAKE_ICE, lc[2]), "radius": ARENA["boundary"],
                     "height": ARENA["height"], "soft": True},
        "spawns": spawns, "pickups": pickups,
        "cover": ["FrozenLake/IceFishingHut", "lake islets (Terrain)"],
        "rules": {"lives": 3, "capSeconds": 180, "items": ["Red", "Green", "Yellow"], "levelOneOnly": True},
    }}
    boss_st = [at(-35.0, -272.0), c0 + 6.0, at(101.0, -1000.0), at(530.0, -507.0), at(-516.0, 220.0), at(-517.0, 420.0)]
    boss_rel = [(95, 70), (0, 40), (110, 50), (160, 60), (150, 60), (140, 50)]
    boss = {"hazard": "rolling snowballs", "phase": "rematch", "encounter": "SNOW-BOSS",
            "anchors": [round(v, 1) for v in boss_st],
            "rollFrom": [{"station": round(v, 1), "lateral": lat, "height": h} for v, (lat, h) in zip(boss_st, boss_rel)],
            "note": "snowballs roll down the gorge terraces, the cascade, the knoll, the east ridge and the pine slope "
                    "across the line; anchors are stations, rollFrom gives the uphill release point per anchor"}
    gameplay = {
        "checkpoints": {"stations": cps, "size": [56, 42, 6], "heightOffset": 18},
        "rings": rings, "pads": pads, "pods": pods,
        "startGrid": {"station": 12, "height": 11, "rowSpacing": 28, "laneOffset": 12},
        "finish": {"station": 0, "radius": 58},
        "alternates": [{"id": "Alt1", "points": [W(*q) for q in alt_pts], "style": "tunnel",
                        "joinStation": round(alt_s0, 1), "rejoinStation": round(alt_s1, 1),
                        "note": "mine tunnel through the west gorge wall (timber roof, lantern strip)"}],
        "coins": coins, "key": key, "modes": modes, "boss": boss,
    }

    # --- shells: Terrain after the compiled grid -----------------------------------------------------------------
    ops = []
    # far skyline: faceted gable ridges (two Terrain wedges back to back: a WedgePart's slope faces local -Z and its
    # tall back face +Z, so wedge A at -z and wedge B turned 180 meet at the ridge line) in a ring outside the grid.
    rng_r = np.random.default_rng(SEED + 23)
    ring_c = (0.0, -350.0)
    base_y = 60.0
    for k in range(20):
        a = 2 * math.pi * k / 20 + 0.07
        rad = 1250.0 + 220.0 * rng_r.random()
        cx, cz = ring_c[0] + math.cos(a) * rad * 1.05, ring_c[1] + math.sin(a) * rad * 1.15
        if GRID["x0"] - 60 < cx < GRID["x1"] + 60 and GRID["z0"] - 60 < cz < GRID["z1"] + 60:
            continue
        if float(np.min(np.hypot(tr.dense[:, 0] - cx, tr.dense[:, 2] - cz))) < 560.0:
            continue  # skyline only: never a slope reaching down to the lap
        top = 300.0 + 260.0 * rng_r.random() + (200.0 if cz < -1300 else 0.0)
        h = top - base_y
        length = 520.0 + 260.0 * rng_r.random()
        yaw = -math.degrees(a) + 90.0 + (rng_r.random() - 0.5) * 30.0
        slopes = (0.85 + 0.4 * rng_r.random(), 0.85 + 0.4 * rng_r.random())
        Ry = adapt.rot_yxz(0.0, yaw, 0.0)
        # L61 (critic r0: "repeated placeholder wedges"): a cool granite range with a snow mantle on its upper half
        # (the cap is the same gable, shorter, so the rock shows below it) and a lower offset shoulder, so the skyline
        # reads as layered peaks rather than one repeated tent
        cap = 0.52 + 0.14 * rng_r.random()
        for mat, hh, along, lenf in (("Rock", h, 0.0, 1.0), ("Snow", h * cap, 0.0, 1.0)):
            for side, sl in zip((-1.0, 1.0), slopes):
                hd = hh / sl
                off = Ry @ np.array([along, 0.0, side * hd / 2])
                y0 = base_y + (h - hh)
                ops.append({"op": "FillWedge", "cf": cf_yaw(cx + off[0], y0 + hh / 2, cz + off[2], yaw + (0.0 if side < 0 else 180.0)),
                            "size": [r2(length * lenf), r2(hh), r2(hd)], "mat": mat})
        sh_h = h * (0.55 + 0.15 * rng_r.random())
        sh_al = (rng_r.random() - 0.5) * length * 0.9
        for mat, hh in (("Rock", sh_h), ("Snow", sh_h * 0.5)):
            for side, sl in zip((-1.0, 1.0), slopes):
                hd = hh / (sl * 0.9)
                off = Ry @ np.array([sh_al, 0.0, side * hd / 2 + 60.0])
                ops.append({"op": "FillWedge", "cf": cf_yaw(cx + off[0], base_y + (sh_h - hh) + hh / 2, cz + off[2],
                                                            yaw + 25.0 + (0.0 if side < 0 else 180.0)),
                            "size": [r2(length * 0.55), r2(hh), r2(hd)], "mat": mat})
    # snow-capped granite shelves on the gorge terraces (the guide's chunky blue rock blocks)
    river_st = [s_ for s_ in tr.dense_st if s_ >= land.mouth_st - 20 or s_ <= land.north_st]
    rocks = 0
    for s_ in river_st[::6]:
        if rng.random() < 0.2:
            continue
        side = -1.0 if rng.random() < 0.55 else 1.0
        dist = 60.0 + 38.0 * rng.random()
        q = tr.offset(s_, side * dist, 0.0)
        x, z = float(q[0]), float(q[2])
        if abs(x) < 205 and abs(z) < 70:
            continue
        if abs(z - START_Z) < START_CLEAR:
            continue  # terrain-look: no rock shelves near the start grid (a shelf slab read across the grid view)
        if in_notch(x, z, 20.0) or (len(alt_xz) and float(np.min(np.hypot(alt_xz[:, 0] - x, alt_xz[:, 1] - z))) < 34):
            continue
        if s_ < 40 or s_ > L - 40:
            continue
        size = [22.0 + 20.0 * rng.random(), 12.0 + 14.0 * rng.random(), 18.0 + 18.0 * rng.random()]
        yaw = float(rng.random() * 360.0)
        rx = (rng.random() - 0.5) * 10.0
        rz = (rng.random() - 0.5) * 10.0
        y = sample_grid(grid, x, z) + size[1] * 0.18
        half, R = rotation_halves(size, rx, yaw, rz)
        centre = np.array(W(x, y, z))
        if cor.hits(centre[None, :], half[None, :], margin=4.0).any():
            continue
        # SN-02: the battle arena keeps only its authored islets (tested after the draws so the rest keep their seeds)
        if math.hypot(x - LAKE_C[0], z - LAKE_C[1]) < ARENA_CLEAR:
            continue
        ops.append({"op": "FillBlock", "cf": cf_yaw(x, y, z, yaw, rx, rz), "size": [r2(v) for v in size], "mat": "Rock"})
        up = R[:, 1]
        cap = np.array([x, y, z]) + up * (size[1] / 2 + 1.2)
        ops.append({"op": "FillBlock", "cf": cf_yaw(cap[0], cap[1], cap[2], yaw, rx, rz),
                    "size": [r2(size[0] * 0.94), 3.2, r2(size[2] * 0.94)], "mat": "Snow"})
        rocks += 1
    notes["rockShelves"] = rocks
    # lake islets (survival cover). SN-03: islets 2 and 3 straddled z = 600, 130-140 studs ahead of seats 1 and 2 at GO;
    # they now sit north of that line and off the north seat's line (the race line crosses the lake at z 660-680, so
    # nothing goes south of the seat line)
    for x, z, sx, sy, sz, yaw in ARENA_ISLETS:
        y = LAKE_ICE + sy * 0.3
        ops.append({"op": "FillBlock", "cf": cf_yaw(x, y, z, yaw, 4.0, -3.0), "size": [sx, sy, sz], "mat": "Rock"})
        ops.append({"op": "FillBlock", "cf": cf_yaw(x, y + sy / 2 + 1.2, z, yaw, 4.0, -3.0), "size": [sx * 0.94, 3.2, sz * 0.94],
                    "mat": "Snow"})
    # frozen cascade: glacier columns on the two step faces (below the corridor floor)
    for s_step in land.cascade:
        for lat in range(-40, 41, 9):
            q = tr.offset(s_step, float(lat), 0.0)
            top_ice = land.route_ice(s_step + 10, tr.pos(s_step + 10))
            low_ice = land.route_ice(s_step - 12, tr.pos(s_step - 12))
            h = max(4.0, top_ice - low_ice + 2.0)
            ops.append({"op": "FillCylinder", "cf": cf_yaw(q[0], low_ice + h / 2 - 1.0, q[2]), "h": r2(h), "r": 4.6,
                        "mat": "Glacier"})
    # key notch: a long slot cut along the west wall behind the west pier, open to the river, under a rock lip, with a
    # rounded niche at the back for the shrine (a dead-end pocket would make the key collectable only by crashing)
    kn = KEY_NOTCH
    kcx, kcz = (kn["x0"] + kn["x1"]) / 2, (kn["z0"] + kn["z1"]) / 2
    k_rad = (kn["x1"] - kn["x0"]) / 2
    kmid = (kn["floor"] + kn["top"]) / 2
    # stadium plan (straight slot plus two vertical half-cylinder ends) inside the KEY_NOTCH rectangle, so the cut reads
    # carved rather than boxed and never reaches the bridge abutment (z > -44.5)
    ops.append({"op": "FillBlock", "cf": cf_yaw(kcx, kmid, kcz),
                "size": [kn["x1"] - kn["x0"], kn["top"] - kn["floor"], kn["z1"] - kn["z0"] - 2 * k_rad], "mat": "Air"})
    for zc in (kn["z1"] - k_rad, kn["z0"] + k_rad):
        ops.append({"op": "FillCylinder", "cf": cf_yaw(kcx, kmid, zc), "h": kn["top"] - kn["floor"], "r": k_rad, "mat": "Air"})
    ops.append({"op": "FillBall", "center": W(SHRINE_POS[0] + NICHE_IN, 62.0, SHRINE_POS[2]), "r": NICHE_R, "mat": "Air"})
    ops.append({"op": "FillBlock", "cf": cf_yaw(kcx - 4.0, kn["floor"] - 2.0, kcz),
                "size": [kn["x1"] - kn["x0"] + 8.0, 4.0, kn["z1"] - kn["z0"]], "mat": "Snow"})
    # Alt1 tunnel interior and mouths (the tunnel parts are built by the adapter's alternate step)
    for i in range(len(alt_pts) - 1):
        a, b = alt_pts[i], alt_pts[i + 1]
        mid = (a + b) / 2
        d = b - a
        ln = float(np.linalg.norm(d))
        yaw = yaw_to(d[0], d[2])
        pitch = math.degrees(math.atan2(d[1], math.hypot(d[0], d[2])))
        ops.append({"op": "FillBlock", "cf": cf_yaw(mid[0], mid[1] + 15.0, mid[2], yaw, pitch, 0.0),
                    "size": [26.0, 26.4, r2(ln + 4.0)], "mat": "Air"})
    # the rock over the tunnel is the height grid's Alt1 spur (Landscape.height), not stacked Terrain slabs
    for q in (alt_pts[0], alt_pts[-1]):
        ops.append({"op": "FillBall", "center": W(q[0], q[1] + 16.0, q[2]), "r": 22.0, "mat": "Air"})
    # SN-06 bell mouth: the entry approach (the eased alt line from the corridor edge to the first tunnel point) is
    # carved as a funnel that narrows from ALT1.bell wide at the corridor edge to the 26-wide tube at the mouth, so a
    # plane swerving in meets open air or a glancing funnel wall, never a square rock lip around a 26-wide hole
    # terrain-look: the funnel used to be one thin Air block per segment, each yawed to its own segment direction, which
    # left a fan of tilted rock slivers (marching-cubes facets, and a slab across the start-grid view). The same union
    # footprint is now carved with TWO axis-aligned Air boxes (wide inner half, narrower outer half): each box is the
    # world-axis bounding rectangle of its segments' rotated footprints, from the lowest segment floor to the highest top.
    bell_rects = []  # (xz corners (8,2), floor y, top y)
    for a, b, w in bell_segments(tr, alt):
        mid = (a + b) / 2
        d = b - a
        ln = float(np.linalg.norm(d))
        yaw = yaw_to(d[0], d[2])
        pitch = math.degrees(math.atan2(d[1], math.hypot(d[0], d[2])))
        h = 30.0 + BELL_RISE * (w - 26.0)  # floor stays at the tube floor; the wide part opens to the sky (an open cut)
        R = adapt.rot_yxz(pitch, yaw, 0.0)
        centre = np.array([mid[0], mid[1] + 1.0 + h / 2, mid[2]])
        half = np.array([w / 2, h / 2, (ln + 6.0) / 2])
        pts = np.array([centre + np.array(R) @ (half * np.array([sx, sy, sz])) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
        bell_rects.append((pts[:, [0, 2]], float(pts[:, 1].min()), float(pts[:, 1].max())))
    cut = (len(bell_rects) + 1) // 2
    for grp in (bell_rects[:cut], bell_rects[cut:]):
        if not grp:
            continue
        xz = np.vstack([g[0] for g in grp])
        x0, x1 = float(xz[:, 0].min()), float(xz[:, 0].max())
        z0, z1 = float(xz[:, 1].min()), float(xz[:, 1].max())
        y0, y1 = min(g[1] for g in grp), max(g[2] for g in grp)
        ops.append({"op": "FillBlock", "cf": cf_yaw((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
                    "size": [r2(x1 - x0), r2(y1 - y0), r2(z1 - z0)], "mat": "Air"})

    # --- fx --------------------------------------------------------------------------------------------------------
    fx = []
    snow_props = {
        "Rate": 26, "Lifetime": [9, 13], "Speed": [7, 11], "SpreadAngle": [14, 14], "Size": [0.5, 0.3],  # v28 W1.3: 0.75 -> 0.5, no emission
        "Transparency": [0.1, 0.6], "Color": "#ffffff", "LightEmission": 0.0, "LightInfluence": 0.6,
        "Acceleration": [3, -1, 1.5], "Drag": 0.4, "EmissionDirection": "Bottom", "Rotation": [0, 360], "RotSpeed": [-40, 40],
        "Texture": "rbxasset://textures/particles/sparkles_main.dds",
    }
    for x, y, z in ((0.0, 210.0, 260.0), (0.0, 250.0, -300.0), (190.0, 260.0, -930.0), (500.0, 290.0, -480.0),
                    (-420.0, 260.0, 220.0), (-260.0, 190.0, 620.0)):
        fx.append({"class": "ParticleEmitter", "name": "Snowfall", "cf": cf_yaw(x, y, z), "size": [520, 2, 520],
                   "group": "Weather", "props": dict(snow_props)})
    for s_step in land.cascade:
        q = tr.offset(s_step, 0.0, 0.0)
        fx.append({"class": "ParticleEmitter", "name": "CascadeMist", "cf": cf_yaw(q[0], q[1] - 2.0, q[2]), "size": [80, 2, 10],
                   "group": "Gorge", "props": {"Rate": 6, "Lifetime": [4, 6], "Speed": [2, 4], "SpreadAngle": [40, 40],
                                               "Size": [9, 18], "Transparency": [0.82, 1.0], "Color": "#eaf8ff",
                                               "LightEmission": 0.15, "EmissionDirection": "Top",
                                               "Texture": "rbxasset://textures/particles/smoke_main.dds"}})
    chim = adapt.rot_yxz(0, LODGE_YAW, 0) @ np.array([18.0, 64.0, 6.0]) * LODGE_SCALE
    fx.append({"class": "ParticleEmitter", "name": "ChimneySmoke",
               "cf": cf_yaw(LODGE[0] + chim[0], LODGE_Y + chim[1], LODGE[1] + chim[2]),
               "size": [4, 1, 4], "group": "Landmarks",
               "props": {"Rate": 4, "Lifetime": [5, 7], "Speed": [4, 6], "SpreadAngle": [10, 10], "Size": [3, 10],
                         "Transparency": [0.55, 1.0], "Color": "#e6ecf5", "Acceleration": [2, 0.5, 0],
                         "EmissionDirection": "Top", "Texture": "rbxasset://textures/particles/smoke_main.dds"}})
    fx.append({"class": "PointLight", "name": "KeyAlcoveGlow", "cf": cf_yaw(SHRINE_POS[0] + 14.0, 62.0, SHRINE_POS[2]), "group": "Gorge",
               "props": {"Brightness": 1.4, "Range": 34, "Color": "#ffd36a", "Shadows": False}})
    for i, q in enumerate(alt_pts):
        if i % 3 == 1:
            fx.append({"class": "PointLight", "name": "Alt1Lantern", "cf": cf_yaw(q[0], q[1] + 22.0, q[2]), "group": "Gorge",
                       "props": {"Brightness": 1.1, "Range": 38, "Color": "#ffc27a", "Shadows": False}})

    # --- L61 ambient life and the frozen waterfalls -----------------------------------------------------------
    sparkle, glow, flake = fx_texture("sparkle_star_4x4"), fx_texture("glow_soft"), fx_texture("snowflake")
    smoke = "rbxasset://textures/particles/smoke_main.dds"
    # frozen waterfalls down the east gorge wall (the critic's "frozen waterfall" landmark): a Glacier ribbon that
    # follows the terraces from the plateau rim to the river lip, icicle columns on the risers, mist and glints at
    # the foot. Terrain only (Glacier), all of it 55+ studs off the line.
    falls = []
    for s_fall, width, lat1 in ((620.0, 46.0, 140.0), (905.0, 30.0, 128.0)):
        p, t, r, _u = tr.frame(s_fall)
        prof = []
        for lat in np.arange(56.0, lat1 + 0.1, 6.0):
            q = p + r * lat
            prof.append(np.array([q[0], sample_grid(grid, q[0], q[2]) + 2.6, q[2]]))
        for a, b_ in zip(prof, prof[1:]):
            mid = (a + b_) / 2
            d = b_ - a
            ln = float(np.linalg.norm(d))
            w = width * (0.75 + 0.25 * float(np.linalg.norm(a[[0, 2]] - p[[0, 2]])) / lat1)
            ops.append({"op": "FillBlock", "cf": cf_yaw(mid[0], mid[1], mid[2], yaw_to(d[0], d[2]),
                                                        math.degrees(math.atan2(d[1], math.hypot(d[0], d[2]))), 0.0),
                        "size": [r2(w), 6.0, r2(ln + 3.0)], "mat": "Glacier"})
            if d[1] > 7.0:  # a riser: icicle columns across the fall
                for k in range(-2, 3):
                    c = mid + t * (k * w / 5.5)
                    hh = float(d[1]) + 6.0 + 4.0 * ((k * 7 + int(mid[1])) % 3)
                    ops.append({"op": "FillCylinder", "cf": cf_yaw(c[0], c[1] - 1.0, c[2]), "h": r2(hh),
                                "r": r2(2.6 + (k % 2) * 1.2), "mat": "Glacier"})
        foot = prof[0]
        falls.append((s_fall, foot, t, r))
        fx.append({"class": "ParticleEmitter", "name": "FrozenFallMist", "cf": cf_yaw(foot[0], foot[1] + 2.0, foot[2]),
                   "size": [16, 2, width], "group": "Gorge",
                   "props": {"Texture": smoke, "Rate": 3, "Lifetime": [4, 6], "Speed": [1, 3], "SpreadAngle": [30, 30],
                             "Color": "#eef9ff", "LightEmission": 0.2, "EmissionDirection": "Top",
                             "Size": {"seq": [[0, 8, 2], [1, 18, 4]]},
                             "Transparency": {"seq": [[0, 1, 0], [0.3, 0.72, 0], [1, 1, 0]]}}})
        top = prof[len(prof) // 2]
        fx.append({"class": "ParticleEmitter", "name": "FrozenFallGlints", "cf": cf_yaw(top[0], top[1] + 1.0, top[2]),
                   "size": [30, 40, width], "group": "Gorge",
                   "props": {"Texture": sparkle, "FlipbookLayout": "Grid4x4", "FlipbookMode": "Loop",
                             "FlipbookFramerate": [24, 24], "FlipbookStartRandom": True,
                             "Rate": 9, "Lifetime": [0.6, 1.1], "Speed": [0, 0.3], "Color": "#e6fbff", "LightEmission": 1,
                             "Size": {"seq": [[0, 0, 0], [0.35, 1.6, 0.4], [1, 0, 0]]},
                             "Transparency": {"seq": [[0, 0.05, 0], [1, 0.4, 0]]}}})
    notes["frozenFalls"] = [round(f[0], 1) for f in falls]

    # sparkling ice: tiny star glints on the frozen river and the lake, below the flight line (16 under the plane)
    for s_ in np.arange(0.0, L, 110.0):
        if not (s_ >= land.mouth_st or s_ <= land.north_st or s_ >= land.lake_from):
            continue
        p, t, r, _u = tr.frame(float(s_))
        fx.append({"class": "ParticleEmitter", "name": "IceGlints", "cf": cf_yaw(p[0], p[1] - 1.2, p[2], yaw_to(t[0], t[2])),
                   "size": [80, 0.5, 100], "group": "Weather",
                   "props": {"Texture": sparkle, "FlipbookLayout": "Grid4x4", "FlipbookMode": "Loop",
                             "FlipbookFramerate": [24, 24], "FlipbookStartRandom": True,
                             "Rate": 7, "Lifetime": [0.5, 0.9], "Speed": [0, 0.2], "Color": "#f2fdff", "LightEmission": 1,
                             "Size": {"seq": [[0, 0, 0], [0.4, 1.1, 0.3], [1, 0, 0]]},
                             "Transparency": {"seq": [[0, 0.05, 0], [1, 0.5, 0]]}}})

    # spindrift: powder blown off the gorge rims and the plateau hill crests into the low morning sun
    drift_n = 0
    for s_ in np.arange(150.0, L, 290.0):
        p, t, r, _u = tr.frame(float(s_))
        for side in (-1.0, 1.0):
            best = None
            for lat in np.arange(90.0, 230.0, 10.0):
                q = p + r * side * lat
                gq = sample_grid(grid, q[0], q[2])
                if best is None or gq > best[1] + 1.0:
                    best = (q, gq)
            q, gq = best
            if math.hypot(q[0] - LAKE_C[0], q[2] - LAKE_C[1]) < ARENA_CLEAR:
                continue
            fx.append({"class": "ParticleEmitter", "name": "Spindrift", "cf": cf_yaw(q[0], gq + 3.0, q[2], yaw_to(t[0], t[2])),
                       "size": [24, 2, 60], "group": "Weather",
                       "props": {"Texture": smoke, "Rate": 2.2, "Lifetime": [3.5, 5.5], "Speed": [3, 6], "SpreadAngle": [25, 25],
                                 "Acceleration": [9, 1.5, 3], "Drag": 0.3, "Color": "#ffffff", "LightEmission": 0.25,
                                 "EmissionDirection": "Top", "Rotation": [0, 360], "RotSpeed": [-20, 20],
                                 "Size": {"seq": [[0, 5, 1], [1, 22, 4]]},
                                 "Transparency": {"seq": [[0, 1, 0], [0.2, 0.62, 0], [1, 1, 0]]}}})
            drift_n += 1
    notes["spindrift"] = drift_n

    # ring sparkle: each booster ring sheds slow gold-white stars (readable beats on the line, as on HUB-0)
    for ring in gameplay["rings"]:
        p, t, r, u = tr.frame(ring["station"])
        c = p + u * ring["height"]
        R = adapt.rot_yxz(math.degrees(math.asin(max(-1.0, min(1.0, float(t[1]))))), yaw_to(t[0], t[2]), 0.0)
        fx.append({"class": "ParticleEmitter", "name": f"RingSparkle_{ring['name']}",
                   "cf": W(c[0], c[1], c[2]) + [r3(v) for v in R.flatten()], "size": [24, 24, 0.5], "group": "Weather",
                   "props": {"Texture": sparkle, "FlipbookLayout": "Grid4x4", "FlipbookMode": "Loop",
                             "FlipbookFramerate": [24, 24], "FlipbookStartRandom": True, "Shape": "Cylinder",
                             "ShapeStyle": "Surface", "ShapeInOut": "Outward", "EmissionDirection": "Back",
                             "Rate": 12, "Lifetime": [0.9, 1.4], "Speed": [0.4, 1.2], "SpreadAngle": [30, 30],
                             "Color": "#fff1c8", "LightEmission": 1.0,
                             "Size": {"seq": [[0, 0.0, 0], [0.3, 1.3, 0.3], [1, 0.0, 0]]},
                             "Transparency": {"seq": [[0, 0.1, 0], [1, 0.6, 0]]}}})

    # warm lantern glow at the start, the arch approach, the turns and the lodge path (shadows off, phone budget)
    for x, z in lamp_lights[:30]:
        fx.append({"class": "PointLight", "name": "LanternGlow", "cf": cf_yaw(x, sample_grid(grid, x, z) + 13.0, z),
                   "group": "Weather", "props": {"Brightness": 1.5, "Range": 20, "Color": "#ffbe6e", "Shadows": False}})

    # --- route lights: warm bounce under the arch span only ----------------------------------------------------
    route_lights = {"every": 2, "fromStation": round(st_under - 50.0, 1), "toStation": round(st_under + 50.0, 1),
                    "offsets": [[-46, 30], [46, 30]], "color": "#ffd9a8", "range": 52, "brightness": 0.85}

    # --- terrain grid (30MAPS) ---------------------------------------------------------------------------------
    Hq = np.round(grid["H"], 2)
    terrain = {
        "nx": grid["nx"], "nz": grid["nz"], "cell": GRID["cell"],
        "x0": GRID["x0"] + ORIGIN[0], "z0": GRID["z0"] + ORIGIN[2],
        "heights": [float(v) for v in (Hq + ORIGIN[1]).flatten()],
        "materials": [int(v) for v in grid["mat"].flatten()],
        "palette": [{"key": "snow", "material": "Snow", "color": "#f2f6fc"},
                    {"key": "rock", "material": "Rock", "color": "#8e98ab"},
                    {"key": "ice", "material": "Ice", "color": "#a6e8f6"},
                    {"key": "glacier", "material": "Glacier", "color": "#9fdcf0"},
                    {"key": "snowshade", "material": "Ground", "color": "#cfd8e6"},
                    {"key": "hollow", "material": "Mud", "color": "#c4cddd"}],
        "floor": GRID["floor"], "top": float(Hq.max()),
    }
    return {"tr": tr, "land": land, "grid": grid, "prefabs": prefabs, "instances": instances, "groups": groups,
            "gameplay": gameplay, "ops": ops, "fx": fx, "routeLights": route_lights, "terrain": terrain, "notes": notes,
            "dressing": dressing,
            "st_under": st_under, "st_over": st_over, "alt": alt}


# ------------------------------------------------------------------------------------------------ materials, sky

VARIANTS = {
    "SR_SNOW_Drift": {"base": "Snow", "tex": "T1_SNOW_DRIFT", "studsPerTile": 56},  # terrain-look: 110 -> 56 (white plain read flat)
    "SR_SNOW_Glacier": {"base": "Glacier", "tex": "T2_GLACIER_ICE", "studsPerTile": 44},
    "SR_SNOW_RiverIce": {"base": "Ice", "tex": "T3_FROZEN_RIVER", "studsPerTile": 64},
    "SR_SNOW_Rock": {"base": "Rock", "tex": "T4_GRANITE_SNOWCAP", "studsPerTile": 60},
    "SR_SNOW_Wind": {"base": "Ground", "tex": "T1_SNOW_DRIFT", "studsPerTile": 70},  # terrain-look: wind-packed patches (rebake tier)
    "SR_SNOW_Hollow": {"base": "Mud", "tex": "T1_SNOW_DRIFT", "studsPerTile": 90},  # terrain-look: shadowed hollows (rebake tier)
    "SR_SNOW_Fieldstone": {"base": "Granite", "tex": "T4_GRANITE_SNOWCAP", "studsPerTile": 16},
    "SR_SNOW_Ashlar": {"base": "Slate", "tex": "T5_ICE_PAVERS", "studsPerTile": 22},
    "SR_SNOW_Pavers": {"base": "Pavement", "tex": "T5_ICE_PAVERS", "studsPerTile": 11},
    "SR_SNOW_Timber": {"base": "WoodPlanks", "tex": "T6_TIMBER", "studsPerTile": 10},
}

# Visibility v1 (owner report 2026-10-20): the far wedge ranges (Terrain, 900-1400 studs out) can drop past the client's
# terrain render distance at plane height. tools/map/backdrop.py puts a plain wedge 24 studs inside every far Rock/Snow
# range wedge (at least 600 studs from the course, 140+ tall) in the same colour: hidden while the terrain is drawn,
# the range's silhouette when it is not. Non-colliding, purely visual. Rock cores sit 20 deeper (inset 44) than the
# Snow cores: a snow cap wedge shares its slope, sides and back with the rock wedge under it, so equal insets z-fight.
# Critic v28 1.10: the plain ranges read as pale tiled slabs; the skyline now adds crossed gable pairs (<= 200 studs
# each) on the crests of the tallest far Rock ranges, cool slate rock under SmoothPlastic snow caps. The cores STAY (they
# are the owner-reported visibility fix: without them a culled range leaves its peaks floating in the sky); the Rock
# core takes the new Rock tint so the culled silhouette matches the terrain. Cores (78) + 8 peaks (64) < MAX_PARTS 150.
BACKDROP = {"cores": [{"name": "FarRangeCore", "inset": 24, "minRouteDistance": 600, "minHeight": 140,
                       "styles": {"Rock": {"mat": "Rock", "color": "#7f8fae", "inset": 44},
                                  "Snow": {"mat": "Snow", "color": "#dfe6f2"}}}],
            "peaks": [{"name": "FarPeak", "minRouteDistance": 600, "minHeight": 140, "maxSpan": 200, "lift": 110, "seed": 11,
                       "maxPeaks": 8, "tripleGable": True,  # v29 D5: jagged, overlapping gables
                       
                       "rock": {"mat": "Rock", "colors": ["#6f7f99", "#788aa6", "#6a7a94"]},
                       "cap": {"mat": "SmoothPlastic", "color": "#eef3fb"}}]}

MATERIALS_BLOCK = {
    "terrainOverrides": {"Snow": "SR_SNOW_Drift", "Glacier": "SR_SNOW_Glacier", "Ice": "SR_SNOW_RiverIce", "Rock": "SR_SNOW_Rock",
                        "Ground": "SR_SNOW_Wind", "Mud": "SR_SNOW_Hollow"},
    "terrainColor": "#ffffff",
    # L61 grade: per-material tints over the neutral detail maps (they win over terrainColor). Snow is a soft, slightly
    # warm white a step under pure white so sunlit fields keep their form, the granite a cool slate far darker than the
    # snow (the guide's blue-grey shelves), the river ice a saturated turquoise so the line reads at speed.
    "terrainColors": {"Snow": "#dfe6f2", "Rock": "#7f8fae", "Ice": "#5fcde8", "Glacier": "#74c9e6",
                      "Ground": "#cfd8e6", "Mud": "#c4cddd"},
    "partRules": [
        {"name": "^Alt1Floor", "setMaterial": "Pavement", "variant": "SR_SNOW_Pavers", "color": "#e6ebf2"},
        {"name": "^Alt1Wall", "setMaterial": "Granite", "variant": "SR_SNOW_Fieldstone", "color": "#6d7a94"},
        {"name": "^Alt1Roof", "setMaterial": "Granite", "variant": "SR_SNOW_Fieldstone", "color": "#5d6a84"},
        {"material": "Slate", "variant": "SR_SNOW_Ashlar"},
        {"material": "Granite", "variant": "SR_SNOW_Fieldstone"},
        {"material": "Pavement", "variant": "SR_SNOW_Pavers"},
        {"material": "WoodPlanks", "variant": "SR_SNOW_Timber"},
    ],
}


def sky_faces(out_dir: Path) -> dict:
    """Procedural Sunshine-bright alpine sky (guide: deep cobalt zenith, pale cyan haze at the horizon, distant pale
    faceted ranges). Colour is a function of elevation on every face, so the cube seams match; the side face is used
    for all four sides, so its range silhouette and clouds repeat every 90 degrees of azimuth (edges wrap)."""
    from PIL import Image
    N = 512
    zen = np.array([22, 82, 205], float)
    mid = np.array([64, 150, 236], float)
    hor = np.array([206, 234, 252], float)
    below = np.array([226, 240, 251], float)

    def grad(el):  # el in radians
        e = np.clip(el / (math.pi / 2), -1, 1)
        t1 = np.clip(e / 0.22, 0, 1)[..., None]
        t2 = np.clip((e - 0.22) / 0.78, 0, 1)[..., None]
        sky = hor + (mid - hor) * (t1 ** 0.8) + (zen - mid) * (t2 ** 0.9)
        return np.where((e < 0)[..., None], hor + (below - hor) * np.clip(-e / 0.15, 0, 1)[..., None], sky)

    u = (np.arange(N) + 0.5) / N * 2 - 1
    U, V = np.meshgrid(u, -u)  # V up
    # side face: direction (U, V, 1)
    el = np.arctan2(V, np.sqrt(U * U + 1))
    az = np.arctan(U)  # -45..45 degrees
    img = grad(el)
    rng = np.random.default_rng(SEED + 31)

    def ridge(az_, peaks):
        """Periodic (90 degrees) piecewise-linear silhouette: elevation of the range top at azimuth az_."""
        ph = (az_ + math.pi / 4) / (math.pi / 2)  # 0..1 across the face
        h = np.zeros_like(ph)
        for c, w, hh in peaks:
            for o in (-1.0, 0.0, 1.0):
                h = np.maximum(h, hh * (1 - np.abs(ph - c - o) / w))
        return h

    far = [(0.08, 0.16, 0.085), (0.31, 0.12, 0.11), (0.52, 0.2, 0.075), (0.74, 0.1, 0.12), (0.9, 0.14, 0.09)]
    near = [(0.18, 0.12, 0.05), (0.43, 0.1, 0.065), (0.63, 0.15, 0.045), (0.85, 0.09, 0.06)]
    for peaks, col_lit, col_sh, snow in ((far, (184, 212, 242), (160, 192, 232), (236, 244, 252)),
                                         (near, (168, 200, 236), (138, 172, 222), (226, 238, 250))):
        top = ridge(az, peaks)
        inside = (el > -0.02) & (el < top)
        # lit/shaded facet split by the slope sign of the silhouette (faceted Raiser read)
        d = np.gradient(top, axis=1)
        facet = np.where(d[..., None] > 0, np.array(col_lit, float), np.array(col_sh, float))
        cap = (el > top * 0.72)[..., None]
        colr = np.where(cap, np.array(snow, float), facet)
        # haze toward the horizon
        hz = np.clip(1 - el / 0.06, 0, 1)[..., None] * 0.55
        colr = colr + (hor - colr) * hz
        img = np.where(inside[..., None], colr, img)
    # soft Sunshine cumulus band (periodic in azimuth), fading out before the top edge
    cl = np.zeros_like(el)
    for k in range(9):
        c = rng.random()
        e0 = 0.10 + 0.28 * rng.random()
        w = 0.05 + 0.06 * rng.random()
        we = 0.035 + 0.02 * rng.random()
        ph = (az + math.pi / 4) / (math.pi / 2)
        for o in (-1.0, 0.0, 1.0):
            cl += np.exp(-(((ph - c - o) / w) ** 2) - ((el - e0) / we) ** 2)
    cl = np.clip(cl, 0, 1) * np.clip((0.62 - el) / 0.2, 0, 1)
    img = img + (np.array([250, 252, 255], float) - img) * (cl[..., None] * 0.85)
    side = img

    # up face: direction (U, 1, V): pure elevation gradient
    el_up = np.arctan2(1.0, np.sqrt(U * U + V * V))
    up = grad(el_up)
    down = np.broadcast_to(below, (N, N, 3)).copy()
    out_dir.mkdir(parents=True, exist_ok=True)
    shas = {}
    for name, arr in (("up", up), ("side", side), ("down", down)):
        path = out_dir / f"{name}.png"
        Image.fromarray(np.clip(np.round(arr), 0, 255).astype(np.uint8), "RGB").save(path, optimize=False)
        shas[name] = hashlib.sha256(path.read_bytes()).hexdigest()[:12]
    return shas


# ------------------------------------------------------------------------------------------------ plan


def make_plan(b: dict) -> dict:
    tr = b["tr"]
    return {
        "prefabs": b["prefabs"],
        "instances": b["instances"],
        "groups": b["groups"],
        "terrain": b["terrain"],
        "markers": [],
        "skyrally": {
            "archetype": "Figure-8 crossing, item duel at the cross", "signatureVerb": "cross",
            "signature": "Cross your own path at the over/under arch and meet the field at the crossing.",
            "id": MAP_ID, "key": KEY, "zone": "SNOW", "vehicle": "plane", "laps": 3, "guide": GUIDE, "lighting": MAP_ID,
            "title": "Frozen River Peak",
            "route": dict(ROUTE_BLOCK, nodes=plan_nodes()),
            "deck": {"style": "snow1_open", "width": 32, "zones": [], "curbHeights": [5.2, 4.4], "gaps": [], "piersEvery": 0,
                     "note": "kind none: open flight line over the river, plateau and lake (the guide shows no road)"},
            "flight": {"lineOffset": LINE, "corridor": dict(CORRIDOR), "allowPockets": allow_pockets()},  # FLIGHT_GUIDE.md 12.3
            "gameplay": b["gameplay"],
            "shells": {"ops": b["ops"]},
            "backdrop": BACKDROP,
            "hazards": [], "meshes": [], "modelAttributes": [],
            "setDressing": b["dressing"],
            "fx": b["fx"],
            "framing": {"heroStation": 30, "note": "first gameplay view: up the frozen river at the arch bridge with the "
                        "peak above the deck, pines on the rims (05_SNOW1_EVERFROST_PEAK.png composition)"},
            "routeLights": b["routeLights"],
            "materials": MATERIALS_BLOCK,
            "provenance": {"author": "tools/map/author_snow1.py", "seed": SEED, "origin": list(ORIGIN),
                           "routeFlexScale": round(tr.route.flex_scale, 6), "routeLength": round(tr.length, 3),
                           "underArchStation": round(b["st_under"], 1), "overArchStation": round(b["st_over"], 1),
                           "skyFaces": "assets/sky/snow1/{up,side,down}.png (integrator uploads; no ids referenced yet)",
                           "materialSet": "assets/materials/snow_v1/variants.json", **b["notes"]},
        },
    }


def main(argv=None) -> int:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-sky", action="store_true", help="skip writing the sky faces")
    ap.add_argument("--why", action="store_true", help="print set-dressing rejection reasons")
    a = ap.parse_args(argv)
    b = build()
    plan = make_plan(b)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(plan, indent=None, separators=(",", ":"), sort_keys=False)
    OUT.write_text(text + "\n")
    VARIANTS_OUT.parent.mkdir(parents=True, exist_ok=True)
    VARIANTS_OUT.write_text(json.dumps(VARIANTS, indent=1) + "\n")
    shas = {} if a.no_sky else sky_faces(SKY_DIR)
    parts = sum(len(plan["prefabs"][i["pf"]]["parts"]) for i in plan["instances"])
    gp = plan["skyrally"]["gameplay"]
    print(f"wrote {OUT.relative_to(ROOT)} prefabs={len(plan['prefabs'])} instances={len(plan['instances'])} parts={parts} "
          f"grid={plan['terrain']['nx']}x{plan['terrain']['nz']} shellOps={len(b['ops'])} fx={len(b['fx'])} "
          f"rings={len(gp['rings'])} pads={len(gp['pads'])} pods={len(gp['pods'])} coins={len(gp['coins'])} "
          f"setDressing={len(plan['skyrally']['setDressing'])} "
          f"sha256={hashlib.sha256(text.encode()).hexdigest()[:12]}")
    print(f"route length={b['tr'].length:.3f} flex={b['tr'].route.flex_scale:.4f} under={b['st_under']:.1f} "
          f"over={b['st_over']:.1f} notes={b['notes']}")
    if shas:
        print(f"sky {SKY_DIR.relative_to(ROOT)} {shas}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
