#!/usr/bin/env python3
"""TRACK_PIPELINE P1 author script for HUB-0, Central Adventure Island (zone HUB, car; launch map and the HUB-BOSS-1
storm venue). Design data in this file -> map/hub0/plan.json (docs/MAP_PLAN_SCHEMA.md), plus the zone material
variants (assets/materials/hub_v1/variants.json) and the procedural sky faces (assets/sky/hub0/*.png, storm/*.png).
Deterministic (fixed seeds, no clock). Change the map here and rerun, then `python3 tools/map/adapt.py
map/hub0/plan.json`; never edit the plan, the variants file, the sky PNGs or build/hub0/* by hand.

Guide: docs/guides/hub0.md (sunny coastal hub: turquoise shallows, cream stone
road with low curbs, timber docks and beach on the left, terracotta town on the right, a carved cream arch into a
tunnel through tan grass-topped cliffs ahead, vehicle exchange bays at the cliff base). Storm variant for the final boss:
assets/concepts/launch_guides_v1/H1_HUB0_LOOP_STORM.png (wet causeway with water both sides, two risky log bridges,
glowing timed boost pads, town across the water, cliff and tunnel arch, lightning sky).

Layout (local coordinates, +X east, +Z south, sea level 0; the loop runs clockwise seen from above, island on the
right of the racing line). Design stations from the south end of the promenade; the race start/finish is at design
~278 (START_NODE), so race station = design - 278 and the start grid looks at the guide's view:
  d    0- 520  west promenade heading north: town on the right, beach, timber docks and sea on the left, vehicle
                exchange bays ahead-left at the foot of the west bluff; start/finish gantry at d ~278.
  d  600- 840  carved CliffTunnelArch into a curving tunnel through the NW headland (Terrain, carved by shells).
  d  840-1550  north cliff road (+36..+47): sea far below on the left, the terraced tan ridge rising on the right.
  d 1550-1880  NE descent past the lighthouse headland.
  d 1880-2350  east causeway over the harbour: water both sides, harbour islet left, lagoon right, two risky log
                bridges (deck gaps) and the paired causeway pads (HUB-BOSS-1 timed boosts).
  d 2350-2800  SE rocky shore; d 2800-3300 south coast with the hidden cove alternate (AltCove boardwalk through a
                gap in a rock bar under a rock arch); d 3300-3600 SW sweep back onto the promenade.
Inland: a cream stone plaza (Terrain Pavement) on the island crown with the five zone portal arches on its north arc,
backed by the cliff ridge and the ledge spire (plane find); terraces of terracotta houses between the plaza and the
promenade. Organic masses are the 30MAPS height grid plus shells ops; masonry, timber and machinery are 30MAPS
prefabs in the Raiser faceted block style.

World placement: ORIGIN puts the hub clear of every other launch map (checked 2026-10-18 against DINO-4, SNOW-1,
ISLAND-2, FOREST-1, SPACE-4 and TEST-STRIP plans): the height grid covers ORIGIN -1080..+1080 x -904..+880 and the
open-sea apron shells ORIGIN +-1700 x +-1500 (a grid writes Air over its whole footprint, so footprints must not
overlap).
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

import route as routelib  # noqa: E402
import route_geometry  # noqa: E402
import item_rows  # noqa: E402  (item cubes v2 layout rules, tools/map/item_cubes.json)

OUT = ROOT / "map" / "hub0" / "plan.json"
VARIANTS_OUT = ROOT / "assets" / "materials" / "hub_v1" / "variants.json"
SKY_OUT = ROOT / "assets" / "sky" / "hub0"
GUIDE = "docs/guides/hub0.md"
STORM_GUIDE = "assets/concepts/launch_guides_v1/H1_HUB0_LOOP_STORM.png"

ORIGIN = (-8000.0, 0.0, 8000.0)
TARGET_LENGTH = 3600
SAMPLES_PER_SEGMENT = 8
FLEX = 30.0  # studs of radial (outward from the island centre) widening per unit of flex scale
ROAD_WIDTH = 44
DECK_TOP = 1.6  # TrackSeg top above the ribbon (kit/Deck: centre -2.2, height 7.6)
DRIVE_TOP = 2.7  # paver top: the car's ground ray ignores CanCollide, so this is the surface it drives on
LINE_OFFSET = 4.5  # car hull centre above the ribbon (paver top 2.7 + ride height 1.9)
SHOULDER = 36.0  # flat ground at deck level out to here from the centre line (road 22, curbs 25.2): wide enough that
#                  every 8-stud grid node the curb line interpolates from sits at deck level
CORRIDOR = {"halfWidth": 22, "floor": 3, "ceiling": 34}  # the road's own footprint, clear of all collidable art
# Booster ring centre above the ribbon (kit/Gameplay ring: opening edge r 9.95, outer rim r 14.6). At 12.5 the opening's
# lower edge (2.55) is under the paver top (2.7), so the ring rises out of the road like a gate and the car (hull 6.3 x
# 2.4 at +4.6) drives through the opening, never through the non-colliding lower rim; the hull passes 7.9 from the
# centre, inside CarConfig.RING_TRIGGER_RADIUS 16. (At 16 the lower rim spanned +0.9..+6.05 across the car body.)
RING_HEIGHT = 12.5
TUNNEL = (600.0, 840.0)  # carved tunnel through the NW headland (arches at both mouths)
BRIDGES = [(1995.0, 2035.0), (2150.0, 2190.0)]  # deck gaps (3 deck segments each) spanned by RiskyLogBridge
CAUSEWAY_PAD_LATERAL = 3.5  # trap audit H0-06: centres the boosted straight line on the south log bridge
CHANNEL_REACH = 76.0  # each bridge channel cuts the inland half of the causeway out to here (the lagoon shore ~50-60)
ALT_COVE = {"join": 2830.0, "rejoin": 3180.0, "lateral": -84.0, "height": -8.0, "ramp": 165.0, "step": 10.0,
            "minOffset": 34.0}  # 26-wide ledge slabs: the first one abuts the curb (road edge 22, curb to 25.2)
SEED = 20261018
# The loop is designed in "design stations" measured from NODES[0] (south end of the promenade). The race start/finish
# sits at node START_NODE, ~280 studs up the promenade, so the first gameplay view is the guide's view (dock and
# beach left, exchange bays and the carved tunnel arch ahead, town right). Track.rs() converts design -> race stations;
# every station written to the plan is a race station.
START_NODE = 2

# Route nodes, local (x, z, height above sea, bank deg). Positive bank raises the right edge (outside of a left turn);
# this loop turns right, so banks are negative. |bank| <= 9, grades <= 4 degrees.
NODES = [
    (-540, 215, 8, 0), (-540, 80, 8, 0), (-540, -55, 8, 0), (-534, -185, 10, -2),
    (-508, -300, 15, -5), (-455, -395, 22, -6), (-370, -470, 29, -5), (-265, -515, 36, -3),
    (-135, -535, 42, 0), (5, -540, 47, 0), (150, -530, 46, -2), (285, -495, 39, -6),
    (400, -425, 29, -8), (485, -325, 18, -8), (535, -195, 9, -4), (550, -60, 6, 0),
    (545, 75, 6, 0), (522, 200, 6, 0), (465, 310, 8, -7), (370, 395, 10, -8),
    (245, 445, 12, -4), (105, 460, 12, 0), (-40, 460, 12, 0), (-185, 445, 11, -3),
    (-325, 410, 10, -7), (-445, 360, 9, -9), (-520, 295, 8, -6),
]

# Island features (local x, z)
PLAZA_C = (-150.0, 0.0)
PLAZA_H = 26.0
PLAZA_R = 150.0
RIDGE_A, RIDGE_B, RIDGE_R = (-430.0, -400.0), (330.0, -400.0), 85.0
SPIRE_C, SPIRE_TOP = (40.0, -330.0), 188.0
WEST_BLUFF = ((-700.0, -430.0), (-560.0, -470.0), 80.0, 92.0)  # capsule a, b, radius, top
NE_HEADLAND = ((500.0, -505.0), 62.0, 42.0)  # centre, flat radius, top
ISLET = ((690.0, 20.0), 45.0, 7.0)
LAGOON = ((436.0, 22.0), (74.0, 176.0), -6.0)  # ellipse centre, radii (x, z), floor
COVE = ((-70.0, 615.0), 70.0)
COVE_BAR = ((-260.0, 524.0), (110.0, 524.0), 9.0, 30.0)  # capsule a, b, half width, top
EXCHANGE = (-655.0, -300.0)  # exchange bay forecourt centre
# Hub spawn offset from the plaza centre and its look (x, z), 12 degrees north of east (trap audit H0-08): every
# FlightServer hub slot (4 abreast, 12 apart, rows 16 back) has 150 studs of open plaza ahead, clear of the fountain,
# the r 96 lamp ring, the south balustrade and the portal arches, with +-4 degrees of heading to spare.
SPAWN, SPAWN_LOOK = (-30.0, 66.0), (0.978, -0.208)

# Grid (local): cell 8 over the island and its shallows; the open sea beyond is the shells apron.
CELL = 8
GX0, GX1, GZ0, GZ1 = -1080, 1080, -904, 880
APRON = (1700.0, 1500.0)
SEA_FLOOR = -24.0

# Palette (Sunshine light, Majora craft, Raiser faceted blocks)
CREAM = "#f2e4c4"
CREAM_L = "#f7eedb"
STONE = "#e6d5b0"
STONE_D = "#cdb68c"
STONE_INSET = "#d8c296"
TERRA = "#d0643c"
TERRA_D = "#b44e2e"
TIMBER = "#8a5634"
TIMBER_D = "#5e3a24"
TIMBER_L = "#b98a5a"
GLASS = "#2f4254"  # v29 B11: dark recessed panes (L61 was a bright sky blue, which read as flat stickers)
SHUTTERS = ["#2f8f8a", "#3a78b0", "#6a3058", "#d9a03a"]
GOLD = "#e0a838"
HOUSE_PLASTER = "#efe0c2"  # v29 B11 house tint pass (part colour only)
HOUSE_ROOF = "#c8643a"
PLUM = "#6a3058"
LEAF = "#5fb043"
LEAF_D = "#4a9a36"
LEAF_L = "#86c95a"
TRUNK = "#b08454"
ROPE = "#d8c08a"
# L61 art pass: plaster tints per shutter colour (warm Mediterranean village, never one flat white), window-box
# flowers, bunting and awning stripes
WALLS = ["#f3dcb2", "#f0c49c", "#f2dc9c", "#e9b8a0"]
FLOWERS = ["#e8485e", "#f4a3c0", "#ffd54a", "#f7f2e8", "#b061c8"]
BUNTING = ["#d8483a", "#e0a838", "#2f9c96", "#f2ead8", "#6a3058", "#3a78b0"]

ZONE_COLOURS = {  # portal accents: veil, crest, banner
    "DINO": ("#f07a2a", "#4a3430", "#c9452a"),
    "SNOW": ("#8fd8ff", "#f4fbff", "#4f8fd0"),
    "ISLAND": ("#2fd0c8", "#ff8a6a", "#1f9aa0"),
    "FOREST": ("#6cc84a", "#8a5a34", "#3f8a34"),
    "SPACE": ("#9a6cff", "#6ff0ff", "#4a3a9a"),
}
PORTALS = [("DINO", -80.0, 0), ("SNOW", -40.0, 1), ("ISLAND", 0.0, 2), ("FOREST", 40.0, 4), ("SPACE", 80.0, "final-boss")]
PORTAL_TRACKS = {"DINO": "DINO-4", "SNOW": "SNOW-1", "ISLAND": "ISLAND-2", "FOREST": "FOREST-1", "SPACE": "SPACE-4"}

# Zone material set (hub_v1 textures T1..T6; names fixed by the texture job)
VARIANTS = {
    # L61: colorMap T1_PLAZA_STONE_softn = the neutral map with grout contrast cut 40% (tools/vfx/make_hub_fx.py)
    "SR_HUB_PlazaStone": {"base": "Pavement", "tex": "T1_PLAZA_STONE", "studsPerTile": 12, "colorMap": "T1_PLAZA_STONE_softn"},  # 210f4b0: smaller cobbles
    "SR_HUB_Masonry": {"base": "Sandstone", "tex": "T1_PLAZA_STONE", "studsPerTile": 10},
    "SR_HUB_Roof": {"base": "ClayRoofTiles", "tex": "T2_TERRACOTTA_ROOF", "studsPerTile": 10, "neutral": True},
    "SR_HUB_Grass": {"base": "LeafyGrass", "tex": "T3_ISLAND_GRASS", "studsPerTile": 22},
    "SR_HUB_Meadow": {"base": "Grass", "tex": "T3_ISLAND_GRASS", "studsPerTile": 16},
    "SR_HUB_Sand": {"base": "Sand", "tex": "T4_BEACH_SAND", "studsPerTile": 32},
    "SR_HUB_Dirt": {"base": "Ground", "tex": "T3_ISLAND_GRASS", "studsPerTile": 30},  # terrain-look: dirt patches (rebake tier)
    "SR_HUB_PathEdge": {"base": "Mud", "tex": "T4_BEACH_SAND", "studsPerTile": 24},  # terrain-look: worn path edges (rebake tier)
    "SR_HUB_Cliff": {"base": "Limestone", "tex": "T5_CLIFF_ROCK", "studsPerTile": 44},
    "SR_HUB_Timber": {"base": "WoodPlanks", "tex": "T6_TIMBER_DOCK", "studsPerTile": 10, "neutral": True},
    # L61: Roblox's stock Plaster texture greys every tint toward blue; a fine neutral grain keeps the part colour
    "SR_HUB_Plaster": {"base": "Plaster", "tex": "T4_BEACH_SAND", "studsPerTile": 18, "neutral": True},
}


# ------------------------------------------------------------------------------------------------- small helpers
def r3(x: float) -> float:
    v = round(float(x), 3)
    return 0.0 if v == 0 else v


def r4(x: float) -> float:
    v = round(float(x), 4)
    return 0.0 if v == 0 else v


def smooth(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def smooth1(x: float) -> float:
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def lerp(a, b, t):
    return a + (b - a) * t


def rise(h, top, w):
    """Raise ground toward `top` with weight w in [0, 1]; never lowers it (w = 0 leaves h untouched)."""
    return np.maximum(h, lerp(h, top, w))


def terrace(w, steps: int = 5, k: float = 0.5):
    """Stepped contours on a cliff falloff weight: part smooth, part quantised, so faces read as faceted ledges."""
    return (1 - k) * w + k * np.floor(w * steps + 0.5) / steps


def to_world(lx: float, y: float, lz: float) -> list[float]:
    return [r4(ORIGIN[0] + lx), r4(ORIGIN[1] + y), r4(ORIGIN[2] + lz)]


def cf_look(pos, look) -> list[float]:
    """12 CFrame components at pos with a horizontal LookVector along look (x, z)."""
    lx, lz = look
    m = math.hypot(lx, lz)
    lx, lz = lx / m, lz / m
    rx, rz = -lz, lx  # right = look x up
    return [r4(pos[0]), r4(pos[1]), r4(pos[2]), r4(rx), 0.0, r4(-lx), 0.0, 1.0, 0.0, r4(rz), 0.0, r4(-lz)]


def cf_up(pos, up, fwd=(1.0, 0.0, 0.0)) -> list[float]:
    """12 CFrame components at pos whose UpVector (+Y) is `up` (a ParticleEmitter's Top emission direction)."""
    u = np.array(up, dtype=float)
    u /= np.linalg.norm(u)
    f = np.array(fwd, dtype=float)
    x = np.cross(u, f) if abs(float(np.dot(u, f / np.linalg.norm(f)))) < 0.99 else np.cross(u, [0.0, 0.0, 1.0])
    x /= np.linalg.norm(x)
    z = np.cross(x, u)
    return [r4(pos[0]), r4(pos[1]), r4(pos[2]), r4(x[0]), r4(u[0]), r4(z[0]), r4(x[1]), r4(u[1]), r4(z[1]),
            r4(x[2]), r4(u[2]), r4(z[2])]


def fx_texture(name: str) -> str:
    """rbxassetid of an owned particle texture: the hub set (assets/vfx/hub_v1/uploaded.json) or the shared
    VfxAssets table (src/shared/VfxAssets.luau)."""
    hub = json.loads((ROOT / "assets" / "vfx" / "hub_v1" / "uploaded.json").read_text())
    if name in hub:
        return f"rbxassetid://{hub[name]['id']}"
    import re
    src = (ROOT / "src" / "shared" / "VfxAssets.luau").read_text()
    m = re.search(name + r' = \{ id = "(rbxassetid://\d+)"', src)
    if not m:
        m = re.search(name + r' = "(rbxassetid://\d+)"', (ROOT / "src" / "shared" / "VfxFlipAssets.luau").read_text())
    assert m, name
    return m.group(1)


def yaw_facing(fx: float, fz: float) -> float:
    """Instance yaw (deg) that turns a prefab's front (local -Z) to face direction (fx, fz)."""
    return r4(math.degrees(math.atan2(-fx, -fz)))


def P(shape, x, y, z, sx, sy, sz, rx=0.0, ry=0.0, rz=0.0, col="#ffffff", mat="SmoothPlastic", nc=False, a=None,
      light=None, n=None):
    part = [shape, r3(x), r3(y), r3(z), r3(sx), r3(sy), r3(sz), r3(rx), r3(ry), r3(rz), col, mat]
    extra = {}
    if nc:
        extra["nc"] = 1
    if a is not None:
        extra["a"] = a
    if light is not None:
        extra["l"] = light
    if n is not None:
        extra["n"] = n
    if extra:
        part.append(extra)
    return part


def gable_cap(x, y, z, w, h, d, col, mat, nc=False):
    """Small two-wedge gable cap centred at (x, y, z), ridge along X (L61: replaces the K cones, whose CSG renders as a
    plain box in-engine)."""
    return [P("W", x, y, z - d / 4, w, h, d / 2, 0, 0, 0, col, mat, nc=nc),
            P("W", x, y, z + d / 4, w, h, d / 2, 0, 180, 0, col, mat, nc=nc)]


def chunky(x, y, z, w, h, d, col, mat, bevel=0.82, ry=0.0, nc=False):
    """Raiser faceted mass: a block plus a 45-degree twin, so corners read chamfered (two parts)."""
    return [P("B", x, y, z, w, h, d, 0, ry, 0, col, mat, nc=nc),
            P("B", x, y, z, w * bevel, h * 0.999, d * bevel, 0, ry + 45, 0, col, mat, nc=nc)]


# -------------------------------------------------------------------------------------------------------- route
def route_block() -> dict:
    nodes = []
    for x, z, h, bank in NODES[START_NODE:] + NODES[:START_NODE]:
        m = math.hypot(x, z)
        nodes.append({"pos": to_world(x, h, z), "bank": bank,
                      "flex": [r4(x / m * FLEX), 0.0, r4(z / m * FLEX)]})
    return {"nodes": nodes, "closed": True, "samplesPerSegment": SAMPLES_PER_SEGMENT, "targetLength": TARGET_LENGTH,
            "flexScaleMin": 0.0, "flexScaleMax": 3.5, "bisectIterations": 24, "minRadius": 85,
            "radiusExceptions": []}


class Track:
    """The solved route plus dense station samples for terrain and placement."""

    def __init__(self, rt: dict):
        self.route = routelib.solve_plan_route(rt)
        self.length = self.route.length
        # design station of the race start = length minus the race station of the design origin (NODES[0])
        first = (len(NODES) - START_NODE) % len(NODES) * int(rt["samplesPerSegment"])
        self.shift = (self.length - self.route.waypoints[first].station) % self.length
        step = 2.0
        st = np.arange(0.0, self.length, step)
        fr = [self.route.frame_at(float(s)) for s in st]
        self.st = st  # race stations of the samples
        self.dst = (st + self.shift) % self.length  # design stations of the samples
        self.px = np.array([f.pos[0] for f in fr])
        self.py = np.array([f.pos[1] for f in fr])
        self.pz = np.array([f.pos[2] for f in fr])
        self.rx = np.array([f.right[0] for f in fr])
        self.rz = np.array([f.right[2] for f in fr])
        self.bank = np.array([f.bank for f in fr])

    def rs(self, design: float) -> float:
        """Design station -> race station (rounded to 0.1)."""
        return round((design - self.shift) % self.length, 1)

    def frame(self, s: float) -> routelib.Frame:
        """Frame at a DESIGN station."""
        return self.route.frame_at((s - self.shift) % self.length)

    def local(self, s: float, lateral: float = 0.0, height: float = 0.0) -> tuple[float, float, float]:
        p = self.frame(s).offset(lateral, height)
        return p[0] - ORIGIN[0], p[1] - ORIGIN[1], p[2] - ORIGIN[2]

    def heading(self, s: float) -> tuple[float, float]:
        t = self.frame(s).tangent
        m = math.hypot(t[0], t[2])
        return t[0] / m, t[2] / m

    def nearest(self, wx: np.ndarray, wz: np.ndarray, chunk: int = 1024) -> np.ndarray:
        """Index of the nearest route sample per point: coarse pass on every 8th sample, then an exact pass over the
        +-12 samples around it (the coarse winner is within 16 studs of the true nearest along the line)."""
        flat_x, flat_z = wx.ravel(), wz.ravel()
        out = np.empty(flat_x.size, dtype=np.int64)
        cx, cz = self.px[::8], self.pz[::8]
        m = self.px.size
        offs = np.arange(-12, 13)
        for a in range(0, flat_x.size, chunk):
            x, z = flat_x[a:a + chunk, None], flat_z[a:a + chunk, None]
            coarse = np.argmin((x - cx[None, :]) ** 2 + (z - cz[None, :]) ** 2, axis=1) * 8
            cand = (coarse[:, None] + offs[None, :]) % m
            d = (x - self.px[cand]) ** 2 + (z - self.pz[cand]) ** 2
            out[a:a + chunk] = cand[np.arange(cand.shape[0]), np.argmin(d, axis=1)]
        return out.reshape(wx.shape)


def alt_cove_points(tr: Track) -> list[list[float]]:
    """AltCove boardwalk line from the route's own frames: eased out to `lateral` (left = seaward) between join and
    rejoin, both ends on the race line. The stretch nearer the line than minOffset is left out, so the boardwalk starts
    as a mouth beside the curbs; the first and last points sit exactly at minOffset (solved by bisection), and the
    height only starts to fall after that, so the boardwalk top (point + 2, kit/Deck ledge slabs are 4 thick) is
    flush with the paver top (ribbon + 2.7) where the car steps across."""
    a = ALT_COVE
    k_min = a["minOffset"] / abs(a["lateral"])
    k_h0 = k_min + 0.12  # height easing starts once the boardwalk is clear of the curb

    def k_at(s: float) -> float:
        return min(smooth1((s - a["join"]) / a["ramp"]), smooth1((a["rejoin"] - s) / a["ramp"]))

    def point(s: float) -> list[float]:
        k = k_at(s)
        kh = smooth1((k - k_h0) / (1.0 - k_h0))
        return [r3(v) for v in tr.frame(s).offset(a["lateral"] * k, DRIVE_TOP - 2.0 + a["height"] * kh)]

    def solve(lo: float, hi: float) -> float:  # k_at(lo) < k_min <= k_at(hi), monotone between
        for _ in range(40):
            mid = (lo + hi) / 2
            if k_at(mid) < k_min:
                lo = mid
            else:
                hi = mid
        return hi

    s0 = solve(a["join"], a["join"] + a["ramp"])
    s1 = solve(a["rejoin"], a["rejoin"] - a["ramp"])
    pts = [point(s0)]
    s = a["join"] + a["step"] * (math.floor((s0 - a["join"]) / a["step"]) + 1)
    while s < s1 - 1e-6:
        pts.append(point(s))
        s += a["step"]
    pts.append(point(s1))
    return pts


# ------------------------------------------------------------------------------------------------------ terrain
def value_noise(x: np.ndarray, z: np.ndarray, scale: float, seed: int) -> np.ndarray:
    """Smooth deterministic value noise in [-1, 1] on a 64-periodic lattice."""
    rng = np.random.default_rng(seed)
    lat = rng.uniform(-1.0, 1.0, (64, 64))
    u, v = x / scale, z / scale
    i0, j0 = np.floor(u).astype(np.int64), np.floor(v).astype(np.int64)
    fu, fv = smooth(u - i0), smooth(v - j0)
    i0, j0 = i0 % 64, j0 % 64
    i1, j1 = (i0 + 1) % 64, (j0 + 1) % 64
    a = lat[j0, i0] + (lat[j0, i1] - lat[j0, i0]) * fu
    b = lat[j1, i0] + (lat[j1, i1] - lat[j1, i0]) * fu
    return a + (b - a) * fv


def seg_dist(x, z, a, b):
    ax, az = a
    bx, bz = b
    vx, vz = bx - ax, bz - az
    t = np.clip(((x - ax) * vx + (z - az) * vz) / (vx * vx + vz * vz), 0.0, 1.0)
    return np.hypot(x - (ax + vx * t), z - (az + vz * t))


def interior_height(lx, lz):
    """Natural island surface inland of the road (local coords)."""
    base = 13.0 + 4.0 * value_noise(lx, lz, 230.0, SEED + 1) + 2.0 * value_noise(lx, lz, 95.0, SEED + 2)
    # town terraces: lower toward the promenade so the houses step down to the road
    base = base - 3.0 * smooth((-(lx + 380.0)) / 160.0)
    # soft SE hill for a midground silhouette
    base = rise(base, 34.0, 1 - smooth((np.hypot(lx - 190.0, lz - 230.0) - 40.0) / 150.0))
    r = np.hypot(lx - PLAZA_C[0], lz - PLAZA_C[1])
    h = lerp(PLAZA_H, base, smooth((r - PLAZA_R) / 120.0))
    # the ridge: flat grass top, tan cliff faces
    d_r = seg_dist(lx, lz, RIDGE_A, RIDGE_B) + 12.0 * value_noise(lx, lz, 38.0, SEED + 8)
    ridge_top = 132.0 + 16.0 * value_noise(lx, lz, 170.0, SEED + 3)
    h = rise(h, ridge_top, terrace(1 - smooth((d_r - RIDGE_R) / 40.0)))
    d_s = np.hypot(lx - SPIRE_C[0], lz - SPIRE_C[1])
    h = rise(h, SPIRE_TOP, 1 - smooth((d_s - 22.0) / 18.0))
    # lagoon behind the east causeway: a soft ellipse with a noisy shore
    (cx, cz), (ax, az), floor = LAGOON
    q = np.hypot((lx - cx) / ax, (lz - cz) / az)
    d_l = (q - 1.0) * ax + 14.0 * value_noise(lx, lz, 48.0, SEED + 4)
    h = lerp(floor, h, smooth(d_l / 34.0))
    return h


# seaward profiles: (e, height) breakpoints, e = distance beyond the 30-stud road band
SEA_PROFILES = {
    "beach": [(0, 4.0), (24, 3.2), (95, 0.2), (130, -1.6), (250, -6.0), (430, -22.0), (560, SEA_FLOOR)],
    "cliff": [(0, -3.0), (30, -7.0), (130, -14.0), (320, SEA_FLOOR)],
    "coastNE": [(0, 0.0), (30, -4.0), (200, -18.0), (340, SEA_FLOOR)],
    "causeway": [(0, -9.0), (200, -18.0), (340, SEA_FLOOR)],
    "rocky": [(0, 2.0), (25, 1.0), (90, -3.0), (220, -10.0), (400, SEA_FLOOR)],
    "south": [(0, -1.0), (40, -4.0), (200, -12.0), (400, SEA_FLOOR)],
}
SEA_BLEND = {"beach": 12.0, "cliff": 8.0, "coastNE": 10.0, "causeway": 8.0, "rocky": 10.0, "south": 9.0}
SECTIONS = [("beach", -300.0, 560.0), ("cliff", 560.0, 1560.0), ("coastNE", 1560.0, 1870.0),
            ("causeway", 1870.0, 2360.0), ("rocky", 2360.0, 2800.0), ("south", 2800.0, 3300.0)]


def section_weights(st: np.ndarray, length: float) -> dict[str, np.ndarray]:
    ws = {}
    for name, a, b in SECTIONS:
        mid, half = (a + b) / 2, (b - a) / 2
        delta = (st - mid + length / 2) % length - length / 2
        ws[name] = 1 - smooth((np.abs(delta) - half + 40.0) / 80.0)
    tot = sum(ws.values())
    return {k: v / tot for k, v in ws.items()}


def sea_natural(e: np.ndarray, ws: dict[str, np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
    h = np.zeros_like(e)
    blend = np.zeros_like(e)
    for name, w in ws.items():
        xs, ys = zip(*SEA_PROFILES[name])
        h += w * np.interp(e, xs, ys)
        blend += w * SEA_BLEND[name]
    return h, blend


def seaward_overlays(lx, lz, h):
    (ax, az), (bx, bz), rad, top = WEST_BLUFF
    d = seg_dist(lx, lz, (ax, az), (bx, bz)) + 10.0 * value_noise(lx, lz, 34.0, SEED + 9)
    h = rise(h, top + 10 * value_noise(lx, lz, 60.0, SEED + 5), terrace(1 - smooth((d - rad) / 30.0), 4))
    (cx, cz), rad, top = NE_HEADLAND
    h = rise(h, top, 1 - smooth((np.hypot(lx - cx, lz - cz) - rad) / 24.0))
    (cx, cz), rad, top = ISLET
    h = rise(h, top, 1 - smooth((np.hypot(lx - cx, lz - cz) - rad) / 36.0))
    (cx, cz), rad = COVE
    h = rise(h, 2.6, 1 - smooth((np.hypot(lx - cx, lz - cz) - rad * 0.55) / (rad * 0.75)))
    a, b, half, top = COVE_BAR
    h = rise(h, top + 4 * value_noise(lx, lz, 40.0, SEED + 6), 1 - smooth((seg_dist(lx, lz, a, b) - half) / 13.0))
    return h


def tunnel_headland(tr: Track, wx, wz):
    """The NW headland the tunnel passes under: high ground within ~72 studs of the tunnel line (both sides), so
    both mouths are cliff faces with a short canyon approach and the tube keeps ~40 studs of rock overhead."""
    sel = (tr.dst >= TUNNEL[0] + 30) & (tr.dst <= TUNNEL[1] - 20)
    px, pz = tr.px[sel], tr.pz[sel]
    d = np.full(wx.shape, 1e9)
    for x, z in zip(px[::4], pz[::4]):
        d = np.minimum(d, np.hypot(wx - x, wz - z))
    lx = wx - ORIGIN[0]
    lz = wz - ORIGIN[2]
    top = 128.0 + 10.0 * value_noise(lx, lz, 80.0, SEED + 7)
    d = d + 8.0 * value_noise(lx, lz, 30.0, SEED + 10)
    return top, terrace(1 - smooth((d - 72.0) / 30.0), 4)


def bridge_spans(tr: Track) -> list[dict]:
    """Where the deck really ends and resumes around each gap: kit/Deck skips a segment when its START station lies
    in [from, to]; the segment before reaches its end waypoint (plus a 1.8 overhang)."""
    wps = tr.route.waypoints
    out = []
    for i, (da, db) in enumerate(BRIDGES):
        a, b = tr.rs(da), tr.rs(db)
        assert a < b, "a bridge gap must not straddle the start line"
        starts = [w.station for w in wps[:-1] if a <= w.station <= b]
        deck_end = starts[0]
        deck_resume = next(w.station for w in wps if w.station > b)
        d = lambda x: (x + tr.shift) % tr.length  # noqa: E731
        out.append({"name": f"RiskyLogBridge_{'North' if i == 0 else 'South'}", "from": a, "to": b,
                    "deckEnd": round(deck_end, 2), "deckResume": round(deck_resume, 2),
                    "segments": len(starts), "mid": round((deck_end + deck_resume) / 2, 1),
                    "dDeckEnd": d(deck_end), "dDeckResume": d(deck_resume), "dMid": d((deck_end + deck_resume) / 2)})
    return out


TUNNEL_SHOULDER = {"top": 1.2, "thickness": 10.0, "width": 76.0, "overlap": 4.0, "mat": "Limestone"}
ALT_INLAND_STEP = 1.6  # inland ground beside the AltCove slab sits this far under the slab top (wall rays at 2.2)
CLIFF_SHELF = {"from": 840.0, "to": 1550.0, "flat": 56.0, "ease": 16.0}  # design stations, lateral studs (H0-05 d)


def tunnel_shoulders(tr: Track, from_station: float, to_station: float) -> list[dict]:
    """Banked FillBlock per route segment through the tunnel (race stations): the tunnel shoulders sit at the same
    level as the open-road shoulders (`edge` in Terrain: 1.2 above the ribbon in the banked deck frame, 0.4 under the
    TrackSeg top), so a car that crosses the 0.3-stud curb lands on a shoulder it can drive back from instead of a
    4.7-deep gutter between the deck and the tube wall. RouteFloorFill cannot bank (its block is CFrame.lookAt only)
    and the tunnel is banked 3-6 degrees, so a flat floor would either poke through the low side of the road or leave
    that gutter on the high side. The frame is kit/Deck's TrackSeg frame: lookAt(mid, b) * Angles(0, 0, mean bank)."""
    sh = TUNNEL_SHOULDER
    wps = tr.route.waypoints
    out = []
    for w1, w2 in zip(wps, wps[1:]):
        if w2.station < from_station or w1.station > to_station:  # every segment that overlaps the range
            continue
        a, b = np.array(w1.pos), np.array(w2.pos)
        seg = float(np.linalg.norm(b - a))
        if seg <= 0.1:
            continue
        look = (b - a) / seg
        right = np.cross(look, [0.0, 1.0, 0.0])
        right /= np.linalg.norm(right)
        up = np.cross(right, look)
        th = math.radians((w1.bank + w2.bank) / 2)
        right_b = right * math.cos(th) + up * math.sin(th)
        up_b = -right * math.sin(th) + up * math.cos(th)
        centre = (a + b) / 2 + up_b * (sh["top"] - sh["thickness"] / 2)
        rot = np.column_stack([right_b, up_b, -look])  # columns RightVector, UpVector, -LookVector
        cf = [r4(v) for v in centre] + [r4(v) for v in rot.ravel()]  # row-major R00..R22 (GetComponents order)
        out.append({"op": "FillBlock", "cf": cf, "size": [sh["width"], sh["thickness"], r4(seg + sh["overlap"])],
                    "mat": sh["mat"]})
    return out


class Terrain:
    def __init__(self, tr: Track, alt_pts: list[list[float]]):
        xs = np.arange(GX0, GX1 + 0.5, CELL, dtype=float)
        zs = np.arange(GZ0, GZ1 + 0.5, CELL, dtype=float)
        self.nx, self.nz = xs.size, zs.size
        self.lx, self.lz = np.meshgrid(xs, zs)  # [iz, ix], row-major iz * nx + ix
        wx, wz = self.lx + ORIGIN[0], self.lz + ORIGIN[2]
        idx = tr.nearest(wx, wz)
        dx, dz = wx - tr.px[idx], wz - tr.pz[idx]
        lat = dx * tr.rx[idx] + dz * tr.rz[idx]
        dist = np.hypot(dx, dz)
        st, yr, bank = tr.dst[idx], tr.py[idx], tr.bank[idx]  # design stations
        inside = lat > 0
        self.dist, self.lat, self.st, self.inside = dist, lat, st, inside

        ws = section_weights(st, tr.length)
        e = np.maximum(dist - SHOULDER, 0.0)
        sea_h, sea_b = sea_natural(e, ws)
        natural = np.where(inside, interior_height(self.lx, self.lz), sea_h)
        natural = np.where(inside, natural, seaward_overlays(self.lx, self.lz, natural))
        hl_top, hl_w = tunnel_headland(tr, wx, wz)
        natural = rise(natural, hl_top, hl_w)
        self.natural = natural

        # Road conformance: under the deck the ground follows the banked deck plane just below its top; the
        # shoulder meets the curbs at deck level; beyond, a blend to the natural ground (steep where they differ).
        sb = np.sin(np.radians(bank))
        core = yr + np.clip(lat, -24.0, 24.0) * sb + 0.4
        edge = yr + np.sign(lat) * 24.0 * sb + 1.2
        blend_in = np.clip(40.0 - np.abs(natural - edge) * 1.2, 8.0, 40.0)
        blend = np.where(inside, blend_in, sea_b)
        t = smooth((dist - SHOULDER) / blend)
        road = np.where(dist <= 24.0, core, np.where(dist <= SHOULDER, edge, lerp(edge, natural, t)))
        open_ground = (st >= TUNNEL[0]) & (st <= TUNNEL[1])
        channel = np.zeros(open_ground.shape, dtype=bool)
        for br in bridge_spans(tr):  # open water under each span, short abutments under the log ends
            channel |= (st >= br["dDeckEnd"] + 6.0) & (st <= br["dDeckResume"] - 6.0)
        open_ground |= channel
        h = np.where(open_ground, natural, road)
        # Each span is a channel across the WHOLE causeway embankment, sea to lagoon (storm guide: water on both sides
        # of each log bridge). The inland half would otherwise keep the interior ground (+5..+11 above the ribbon
        # between the road and the lagoon shore), burying half the logs and leaving a dry shelf under the span.
        h = np.where(channel & inside & (dist <= CHANNEL_REACH), np.minimum(h, sea_h), h)
        # Cliff road inland shelf (trap audit H0-05 d): where the natural ground between the road and the ridge dips far
        # under the shoulder, blend_in clamps to 8 studs and leaves 18-31-deep pits against the ridge face that a car
        # can fall into and never climb out of (hub free roam has no off-track rescue). Hold the inland ground at
        # shoulder level out to CLIFF_SHELF["flat"] (the ridge face rises from there), easing off by "flat" + "ease".
        cs = CLIFF_SHELF
        shelf = inside & (dist > SHOULDER) & (st >= cs["from"]) & (st <= cs["to"])
        h = np.where(shelf, rise(h, edge, 1 - smooth((dist - cs["flat"]) / cs["ease"])), h)

        # AltCove boardwalk: ground just under the boardwalk slabs (top = point + 2, 4 thick), blended outward.
        ap = np.array(alt_pts)
        dense = []
        for i in range(len(ap) - 1):
            for k in range(8):
                dense.append(ap[i] + (ap[i + 1] - ap[i]) * (k / 8.0))
        dense.append(ap[-1])
        dense = np.array(dense)
        di = tr.nearest(dense[:, 0], dense[:, 2])
        dense_lat = (dense[:, 0] - tr.px[di]) * tr.rx[di] + (dense[:, 2] - tr.pz[di]) * tr.rz[di]
        best = np.full(wx.shape, 1e9)
        alt_y = np.zeros(wx.shape)
        alt_lat = np.zeros(wx.shape)
        for p, pl in zip(dense, dense_lat):
            d = np.hypot(wx - p[0], wz - p[2])
            closer = d < best
            best = np.where(closer, d, best)
            alt_y = np.where(closer, p[1], alt_y)
            alt_lat = np.where(closer, pl, alt_lat)
        alt_core = alt_y - 2.6
        mask = (best <= 32.0) & (dist > 26.0)
        h = np.where(mask, lerp(alt_core, h, smooth((best - 15.0) / 17.0)), h)
        # Inland of the boardwalk (toward the race line) the ground beside the slab sat 4.6 under its top, between the
        # slab and the cove bar: a car that dropped off that edge needed a ~40-degree climb to get out (trap audit
        # H0-11). Hold it ALT_INLAND_STEP under the slab top (a step the car climbs) and ease out by +10 studs.
        inland = mask & (lat > alt_lat)
        h = np.where(inland, rise(h, alt_y + 2.0 - ALT_INLAND_STEP, 1 - smooth((best - 16.0) / 10.0)), h)
        self.alt_dist = best
        self.h = h
        self.pads: list[tuple] = []

    # bilinear height exactly as the compiled builder interpolates the node grid
    def ground(self, lx: float, lz: float) -> float:
        fx = (min(max(lx, GX0), GX1) - GX0) / CELL
        fz = (min(max(lz, GZ0), GZ1) - GZ0) / CELL
        ix = max(min(int(math.floor(fx)), self.nx - 2), 0)
        iz = max(min(int(math.floor(fz)), self.nz - 2), 0)
        tx, tz = fx - ix, fz - iz
        H = self.h
        u = H[iz, ix] + (H[iz, ix + 1] - H[iz, ix]) * tx
        v = H[iz + 1, ix] + (H[iz + 1, ix + 1] - H[iz + 1, ix]) * tx
        return float(u + (v - u) * tz)

    def flatten(self, cx: float, cz: float, yaw_deg: float, w: float, d: float, level: float, margin: float = 6.0,
                ring: float = 14.0) -> None:
        """Terrace pad for a building footprint (never touches the road band)."""
        a = math.radians(yaw_deg)
        ca, sa = math.cos(a), math.sin(a)
        dx, dz = self.lx - cx, self.lz - cz
        u = dx * ca - dz * sa  # local x of the rotated footprint
        v = dx * sa + dz * ca
        ou = np.maximum(np.abs(u) - (w / 2 + margin), 0.0)
        ov = np.maximum(np.abs(v) - (d / 2 + margin), 0.0)
        out = np.hypot(ou, ov)
        t = smooth(out / ring)
        ok = self.dist > SHOULDER + 2.0
        self.h = np.where(ok, lerp(level, self.h, t), self.h)
        self.pads.append((cx, cz, w, d, yaw_deg))

    def shoal(self, a: tuple[float, float], b: tuple[float, float], level: float, radius: float, blend: float) -> None:
        """Raise the sea floor to `level` within `radius` of segment a-b, easing out over `blend` (never lowers): water
        there is shallower than CarConfig.WATER_SINK_DEPTH, so a car that leaves the dock splashes down and drives back
        to the beach instead of drowning and respawning on the plaza (trap audit H0-03)."""
        d = seg_dist(self.lx, self.lz, a, b)
        self.h = rise(self.h, level, 1 - smooth((d - radius) / blend))

    def materials(self, paths: list[tuple]) -> np.ndarray:
        """Palette indices (1 grass, 2 sand, 3 rock, 4 plaza, 5 meadow, 6 dirt, 7 path edge)."""
        h = self.h
        gz, gx = np.gradient(h, CELL)
        slope = np.hypot(gx, gz)
        mat = np.ones(h.shape, dtype=np.int64)
        sandy = (h < 4.6) & ((~self.inside) | (h < 0.5))
        mat = np.where(sandy, 2, mat)
        r = np.hypot(self.lx - PLAZA_C[0], self.lz - PLAZA_C[1])
        plaza = r <= PLAZA_R - 4
        for (a, b, half) in paths:
            plaza |= (seg_dist(self.lx, self.lz, a, b) <= half) & (self.dist > 27.0)
        ex = np.hypot(self.lx - EXCHANGE[0], self.lz - (EXCHANGE[1] + 46.0)) <= 46.0
        plaza |= ex
        mat = np.where(plaza, 4, mat)
        mat = np.where((slope > 0.9) & ~plaza, 3, mat)
        # seaward shoulders of the promenade and south coast read as sand, the causeway embankment as rock
        shoulder = (self.dist <= SHOULDER + 4.0) & (self.dist > 24.0) & (~self.inside)
        beachy = ((self.st < 520.0) | (self.st > 3300.0))
        mat = np.where(shoulder & beachy, 2, mat)
        # paved sidewalk in front of the promenade houses (guide: cream paving between curb and house fronts)
        walk = (self.dist <= SHOULDER + 4.0) & (self.dist > 24.0) & self.inside & ((self.st < 470.0) | (self.st > 3570.0))
        mat = np.where(walk, 4, mat)
        causeway = (self.st > 1870.0) & (self.st < 2360.0) & (self.dist <= 42.0)
        mat = np.where(causeway & (self.dist > 22.0), 3, mat)
        mat = np.where(self.alt_dist <= 20.0, np.where(mat == 3, 3, 2), mat)
        # L61: broad patches of a deeper meadow green (palette 5) break up the single lawn tone
        meadow = (mat == 1) & (value_noise(self.lx, self.lz, 70.0, SEED + 31) + 0.5 * value_noise(self.lx, self.lz, 23.0, SEED + 32) > 0.25)
        mat = np.where(meadow, 5, mat)
        # terrain-look (rebake tier; MAP_SURFACE_PLAN item 4): dirt patches (6, Ground) where a 45-stud noise field is high,
        # and worn path edges (7, Mud) in a thin band along the plaza paths, both only on the lawns
        lawn = (mat == 1) | (mat == 5)
        dirt = lawn & (value_noise(self.lx, self.lz, 45.0, SEED + 40) > 0.55) & (self.dist > 27.0)
        edge = np.zeros(mat.shape, dtype=bool)
        for (a, b, half) in paths:
            sd = seg_dist(self.lx, self.lz, a, b)
            edge |= (sd > half) & (sd <= half + 5.0)
        edge &= lawn & (self.dist > 27.0)
        mat = np.where(dirt, 6, mat)
        mat = np.where(edge, 7, mat)
        return mat


# -------------------------------------------------------------------------------------------------------- prefabs
def window(x, y, z_face, facing=-1, shutter=None, w=4.6, h=6.0):
    """Window on a wall face at z = z_face (facing -1 = front, +1 = back): timber frame, deep glass, cream sill."""
    zf = z_face + facing * 0.35
    parts = [P("B", x, y, zf, w + 1.2, h + 1.2, 0.7, col=TIMBER, mat="WoodPlanks"),
             P("B", x, y, zf + facing * 0.15, w, h, 0.7, col=GLASS, mat="SmoothPlastic"),
             P("B", x, y - h / 2 - 0.8, zf + facing * 0.2, w + 2.0, 0.7, 1.4, col=STONE, mat="Sandstone")]
    if shutter:
        for s in (-1, 1):
            parts.append(P("B", x + s * (w / 2 + 1.5), y, zf + facing * 0.1, 1.8, h + 0.6, 0.5, col=shutter,
                           mat="WoodPlanks"))
    return parts


def flower_box(x, y, z_face, facing=-1, w=5.6, seed=0):
    """Timber window box under a window with a row of flowers (two parts; the flowers never collide)."""
    zf = z_face + facing * 1.1
    return [P("B", x, y, zf, w, 1.2, 1.6, col=TIMBER, mat="WoodPlanks"),
            P("B", x, y + 1.0, zf, w - 0.6, 1.0, 1.2, col=FLOWERS[seed % len(FLOWERS)], mat="SmoothPlastic", nc=True)]


def wall_bed(length, z_face, facing=1, seed=0):
    """Low stone flower bed along a wall foot (non-colliding: it never becomes a kerb that traps a car)."""
    zf = z_face + facing * 1.6
    return [P("B", 0, 1.5, zf, length, 1.4, 2.4, col=STONE_D, mat="Sandstone", nc=True),
            P("B", 0, 2.5, zf, length - 1.0, 1.0, 1.8, col=FLOWERS[seed % len(FLOWERS)], mat="SmoothPlastic", nc=True)]


def back_window(x, y, z_face, facing=1, shutter=None, w=4.2, h=5.6):
    """Cheaper window for the plain back and gable faces (frame, glass, optional shutters; no sill)."""
    zf = z_face + facing * 0.35
    parts = [P("B", x, y, zf, w + 1.2, h + 1.2, 0.7, col=TIMBER, mat="WoodPlanks"),
             P("B", x, y, zf + facing * 0.15, w, h, 0.7, col=GLASS, mat="SmoothPlastic")]
    if shutter:
        for s in (-1, 1):
            parts.append(P("B", x + s * (w / 2 + 1.4), y, zf + facing * 0.1, 1.6, h + 0.4, 0.5, col=shutter,
                           mat="WoodPlanks"))
    return parts


def side_window(x_face, y, z, facing=1, w=4.0, h=5.6):
    xf = x_face + facing * 0.35
    return [P("B", xf, y, z, 0.7, h + 1.2, w + 1.2, col=TIMBER, mat="WoodPlanks"),
            P("B", xf + facing * 0.15, y, z, 0.7, h, w, col=GLASS, mat="SmoothPlastic")]


def gable_roof(W, D, base_y, rise, ov=2.2, col=HOUSE_ROOF, ridge_col=TERRA_D, wall_col=CREAM):
    """Gable roof along X: two terracotta slope wedges meeting at the ridge, plastered gable triangles, ridge cap and
    timber eave boards. WedgePart: low edge at local -Z, full height at +Z."""
    half = D / 2 + ov
    yc = base_y + rise / 2
    parts = [P("W", 0, yc, -half / 2, W + 2 * ov, rise, half, 0, 0, 0, col, "ClayRoofTiles"),
             P("W", 0, yc, half / 2, W + 2 * ov, rise, half, 0, 180, 0, col, "ClayRoofTiles")]
    for s in (-1, 1):
        parts.append(P("W", s * (W / 2 - 0.6), yc - 0.1, -D / 4, 1.2, rise - 0.2, D / 2, 0, 0, 0, wall_col, "Plaster"))
        parts.append(P("W", s * (W / 2 - 0.6), yc - 0.1, D / 4, 1.2, rise - 0.2, D / 2, 0, 180, 0, wall_col, "Plaster"))
    parts.append(P("B", 0, base_y + rise + 0.3, 0, W + 2 * ov + 0.6, 1.3, 2.2, col=ridge_col, mat="ClayRoofTiles"))
    for s in (-1, 1):
        parts.append(P("B", 0, base_y + 0.2, s * (half - 0.3), W + 2 * ov, 0.9, 0.8, col=TIMBER_D, mat="WoodPlanks"))
    return parts


def townhouse_a(shutter: str, wall: str = HOUSE_PLASTER) -> dict:
    """Two-storey gable house (guide right side): tinted plaster, timber frame, terracotta roof, painted shutters,
    window boxes; the back face (seen from the plaza) has its own windows and a back door."""
    W, D, H = 34.0, 24.0, 24.0
    parts = [P("B", 0, -3.0, 0, W + 2.4, 8.0, D + 2.4, col=STONE_D, mat="Sandstone"),
             P("B", 0, 1 + H / 2, 0, W, H, D, col=wall, mat="Plaster")]
    band = 1 + H * 0.5
    for s in (-1, 1):
        parts.append(P("B", 0, band, s * (D / 2 + 0.3), W + 1.0, 1.3, 0.8, col=TIMBER, mat="WoodPlanks"))
        parts.append(P("B", s * (W / 2 + 0.3), band, 0, 0.8, 1.3, D + 1.0, col=TIMBER, mat="WoodPlanks"))
        for t in (-1, 1):
            parts.append(P("B", s * (W / 2 + 0.1), 1 + H / 2, t * (D / 2 + 0.1), 2.2, H, 2.2, col=TIMBER,
                           mat="WoodPlanks"))
    for x in (-10.0, 10.0):
        parts += window(x, 7.5, -D / 2, -1)
        parts += window(x, 19.0, -D / 2, -1, shutter)
    parts += window(0.0, 19.0, -D / 2, -1, shutter, w=3.6)
    for k, x in enumerate((-10.0, 10.0)):
        parts += flower_box(x, 14.6, -D / 2, -1, seed=k + int(shutter[1:3], 16))
        parts += back_window(x, 19.0, D / 2, 1, shutter)
        parts += back_window(x, 7.5, D / 2, 1)
    parts.append(P("B", 0, 5.6, D / 2 + 0.4, 5.6, 9.6, 0.9, col=TIMBER_D, mat="WoodPlanks"))  # back door
    parts += wall_bed(W * 0.62, D / 2, 1, seed=int(shutter[1:3], 16) + 1)
    parts.append(P("B", 0, 5.6, -D / 2 - 0.4, 6.4, 10.0, 0.9, col=TIMBER_D, mat="WoodPlanks"))  # door
    parts.append(P("B", 0, 11.2, -D / 2 - 1.6, 9.0, 0.8, 3.4, col=TIMBER, mat="WoodPlanks"))  # door hood
    parts.append(P("W", 0, 12.2, -D / 2 - 1.6, 9.0, 1.2, 3.4, 0, 0, 0, TERRA, "ClayRoofTiles"))
    for s in (-1, 1):
        parts += side_window(s * W / 2, 19.0, 0.0, s)
    parts += gable_roof(W, D, 1 + H, 11.0, wall_col=wall)
    parts.append(P("B", W / 4, 1 + H + 9.0, D / 6, 3.6, 9.0, 3.6, col=wall, mat="Plaster"))  # chimney
    parts.append(P("B", W / 4, 1 + H + 13.9, D / 6, 4.6, 1.0, 4.6, col=TERRA_D, mat="ClayRoofTiles"))
    return {"parts": parts}


def townhouse_b(shutter: str, wall: str = HOUSE_PLASTER) -> dict:
    """Square three-storey tower house with a terracotta pyramid roof (n=4 cone), a timber balcony with flowers and
    windows on the back face too."""
    W, D, H = 24.0, 24.0, 34.0
    parts = [P("B", 0, -3.0, 0, W + 2.4, 8.0, D + 2.4, col=STONE_D, mat="Sandstone"),
             P("B", 0, 1 + H / 2, 0, W, H, D, col=wall, mat="Plaster")]
    for s in (-1, 1):
        for t in (-1, 1):
            parts.append(P("B", s * (W / 2 + 0.1), 1 + H / 2, t * (D / 2 + 0.1), 2.2, H, 2.2, col=TIMBER,
                           mat="WoodPlanks"))
    for yb in (12.0, 23.5):
        parts.append(P("B", 0, yb, -D / 2 - 0.3, W + 1.0, 1.2, 0.8, col=TIMBER, mat="WoodPlanks"))
        parts.append(P("B", 0, yb, D / 2 + 0.3, W + 1.0, 1.2, 0.8, col=TIMBER, mat="WoodPlanks"))
    parts += window(-5.5, 6.5, -D / 2, -1)
    parts.append(P("B", 5.5, 5.4, -D / 2 - 0.4, 6.0, 9.6, 0.9, col=TIMBER_D, mat="WoodPlanks"))
    for x in (-5.5, 5.5):
        parts += window(x, 18.0, -D / 2, -1, shutter, w=4.0)
        parts += window(x, 29.0, -D / 2, -1, shutter, w=4.0)
    # balcony on the second floor
    parts.append(P("B", 0, 13.2, -D / 2 - 3.0, W - 4.0, 1.0, 5.0, col=TIMBER, mat="WoodPlanks"))
    parts.append(P("B", 0, 16.0, -D / 2 - 5.2, W - 4.0, 0.8, 0.6, col=TIMBER_D, mat="WoodPlanks"))
    for x in (-9.5, -3.2, 3.2, 9.5):
        parts.append(P("B", x, 14.6, -D / 2 - 5.2, 0.7, 2.8, 0.7, col=TIMBER_D, mat="WoodPlanks"))
    parts.append(P("B", 0, 14.1, -D / 2 - 4.6, W - 6.0, 0.9, 1.0, col=FLOWERS[int(shutter[1:3], 16) % 5], mat="SmoothPlastic",
                   nc=True))  # balcony flowers
    for x in (-5.5, 5.5):
        parts += back_window(x, 18.0, D / 2, 1, shutter)
        parts += back_window(x, 29.0, D / 2, 1)
    parts += back_window(0.0, 6.5, D / 2, 1)
    parts += wall_bed(W * 0.7, D / 2, 1, seed=int(shutter[1:3], 16) + 2)
    for s in (-1, 1):
        parts += side_window(s * W / 2, 18.0, 0.0, s)
        parts += side_window(s * W / 2, 29.0, 0.0, s)
    parts.append(P("B", 0, 1 + H + 0.6, 0, W + 3.0, 1.2, D + 3.0, col=TIMBER_D, mat="WoodPlanks"))
    parts += gable_roof(W, D, 1 + H + 1.0, 10.0, ov=2.4, wall_col=wall)
    parts.append(P("B", 0, 1 + H + 12.6, 0, 1.6, 3.0, 1.6, col=GOLD, mat="Metal"))
    return {"parts": parts}


def townhouse_c(shutter: str, wall: str = HOUSE_PLASTER) -> dict:
    """Long house with a cream stone arcade on the ground floor and a deep gable roof (guide top right); window boxes
    on the front and a windowed back face with a timber band."""
    W, D, H = 46.0, 22.0, 22.0
    parts = [P("B", 0, -3.0, 0, W + 2.4, 8.0, D + 2.4, col=STONE_D, mat="Sandstone"),
             P("B", 0, 1 + H / 2, 2.0, W, H, D - 4.0, col=wall, mat="Plaster"),
             P("B", 0, 12.0 + 5.5, -D / 2 + 2.0, W, 11.0, 4.0, col=wall, mat="Plaster")]
    # arcade: stone piers and lintels across the front
    for i in range(5):
        x = -W / 2 + 2.0 + i * (W - 4.0) / 4
        parts.append(P("B", x, 6.0, -D / 2 + 1.0, 3.2, 10.0, 3.2, col=STONE, mat="Sandstone"))
        parts.append(P("B", x, 11.2, -D / 2 + 1.0, 4.4, 1.2, 4.4, col=STONE_D, mat="Sandstone"))
    parts.append(P("B", 0, 12.4, -D / 2 + 1.0, W + 1.0, 1.6, 3.8, col=STONE, mat="Sandstone"))
    for i in range(4):
        x = -W / 2 + 2.0 + (i + 0.5) * (W - 4.0) / 4
        parts += window(x, 6.0, -D / 2 + 4.0, -1, None, w=6.0, h=7.0)
        parts += window(x, 17.5, -D / 2, -1, shutter, w=4.2)
        if i in (0, 3):
            parts += flower_box(x, 13.2, -D / 2, -1, seed=i + int(shutter[1:3], 16))
        parts += back_window(x, 16.5, D / 2, 1, shutter if i in (1, 2) else None)
    parts.append(P("B", 0, 11.0, D / 2 + 0.3, W + 0.6, 1.2, 0.8, col=TIMBER, mat="WoodPlanks"))  # back band
    parts += wall_bed(W * 0.7, D / 2, 1, seed=int(shutter[1:3], 16) + 3)
    for s in (-1, 1):
        parts.append(P("B", s * (W / 2 + 0.1), 1 + H / 2, 0, 2.2, H, D + 0.2, col=TIMBER, mat="WoodPlanks"))
    parts += gable_roof(W, D, 1 + H, 12.0, ov=2.6, wall_col=wall)
    parts.append(P("B", -W / 3, 1 + H + 10.0, D / 5, 3.8, 9.0, 3.8, col=wall, mat="Plaster"))
    parts.append(P("B", -W / 3, 1 + H + 14.9, D / 5, 4.8, 1.0, 4.8, col=TERRA_D, mat="ClayRoofTiles"))
    return {"parts": parts}


def voussoir_ring(cy, r_in, r_out, depth, count, col, mat, z=0.0, a0=0.0, a1=180.0):
    parts = []
    rm = (r_in + r_out) / 2
    span = (a1 - a0) / count
    tang = 2 * math.pi * rm * (span / 360.0) * 1.08
    for k in range(count):
        a = a0 + (k + 0.5) * span
        ar = math.radians(a)
        parts.append(P("B", rm * math.cos(ar), cy + rm * math.sin(ar), z, tang, r_out - r_in, depth, 0, 0, a - 90,
                       col, mat))
    return parts


def portal_arch(zone: str) -> dict:
    """Zone portal on the plaza: chunky stepped stone arch with a zone-coloured veil, crest and banners. Front (the
    plaza side) faces local -Z; walking through goes toward +Z."""
    veil, crest, banner = ZONE_COLOURS[zone]
    parts = []
    half, spring, r_in, r_out, depth = 12.0, 20.0, 12.0, 18.0, 7.0
    for s in (-1, 1):
        x = s * (half + 3.2)
        parts.append(P("B", x, 1.2, 0, 10.0, 3.0, 10.0, col=STONE_D, mat="Sandstone"))
        parts.append(P("B", x, spring / 2 + 1.5, 0, 6.4, spring - 1.0, depth, col=STONE, mat="Sandstone"))
        parts.append(P("B", x, spring + 0.4, 0, 8.4, 1.8, depth + 1.6, col=STONE_D, mat="Sandstone"))
        parts.append(P("B", x, spring * 0.55, -depth / 2 - 0.4, 3.6, spring * 0.6, 0.8, col=banner, mat="Fabric"))
        parts.append(P("W", x, spring * 0.25 - 0.4, -depth / 2 - 0.4, 3.6, 2.4, 0.8, 0, 180, 0, banner, "Fabric"))
        parts.append(P("B", s * (half + 8.6), 6.0, 0, 3.0, 10.0, depth - 1.0, col=STONE_D, mat="Sandstone"))
        parts.append(P("W", s * (half + 8.6), 13.0, 0, 3.0, 4.0, depth - 1.0, 0, 90 * s, 0, STONE_D, "Sandstone"))
    parts += voussoir_ring(spring, r_in, r_out, depth, 9, STONE, "Sandstone")
    parts += voussoir_ring(spring, r_out, r_out + 1.6, depth - 1.2, 9, STONE_INSET, "Sandstone")
    parts.append(P("B", 0, spring + r_out - 1.0, 0, 6.6, 8.0, depth + 1.4, col=STONE_D, mat="Sandstone"))
    parts.append(P("B", 0, spring + r_out - 1.0, -depth / 2 - 0.9, 4.2, 4.2, 0.6, 0, 0, 45, crest, "SmoothPlastic"))
    parts.append(P("S", 0, spring + r_out - 1.0, -depth / 2 - 1.3, 2.4, 2.4, 1.2, col=veil, mat="Neon"))
    parts.append(P("B", 0, spring + r_out + 5.4, 0, 3.8, 3.8, 3.8, 35.26, 45, 0, crest, "SmoothPlastic"))
    # veil: rectangle to the springline plus a disc for the round top (non-colliding, translucent, glowing)
    parts.append(P("B", 0, spring / 2 + 0.5, 0, half * 2, spring, 0.6, col=veil, mat="Glass", nc=True, a=0.45,
                   light=[22, 1.2, veil, False]))
    parts.append(P("C", 0, spring, 0, half * 2, 0.6, half * 2, 90, 0, 0, veil, "Glass", nc=True, a=0.45))
    # threshold step
    parts.append(P("B", 0, 0.4, 0, half * 2 + 2.0, 0.8, depth + 3.0, col=STONE_INSET, mat="Sandstone"))
    return {"parts": parts}


def cliff_tunnel_arch() -> dict:
    """The guide's carved cream arch at the tunnel mouths: thick voussoir ring, outer band, crown keystone, panelled
    pillars and buttresses blending into the cliff. Opening 62 wide, springline 30, inner apex 61 above the deck.
    Pillars and ring stay outside the road corridor (|lateral| > 22, or above +34) even on the yawed, climbing
    mouths, where the gate tests world AABBs."""
    parts = []
    r_in, r_out, spring, depth = 31.0, 39.5, 30.0, 11.0
    for s in (-1, 1):
        x = s * 35.5
        parts.append(P("B", s * 36.0, 1.0, 0, 12.0, 8.0, depth + 1.0, col=STONE_D, mat="Sandstone"))
        parts.append(P("B", x, spring / 2 + 1.0, 0, 9.0, spring - 2.0, depth, col=STONE, mat="Sandstone"))
        parts.append(P("B", x, spring + 0.5, 0, 12.0, 3.0, depth + 2.0, col=STONE_D, mat="Sandstone"))
        for z in (-depth / 2 - 0.3, depth / 2 + 0.3):
            parts.append(P("B", x, spring / 2 + 1.0, z, 5.0, spring - 9.0, 0.6, col=STONE_INSET, mat="Sandstone"))
            parts.append(P("B", x, spring / 2 + 1.0, z + (0.25 if z > 0 else -0.25), 2.2, spring - 14.0, 0.5,
                           col=STONE, mat="Sandstone"))
        parts.append(P("W", s * 46.0, 20.0, 0, depth, 38.0, 12.0, 0, -90 * s, 0, STONE_D, "Sandstone"))
        parts.append(P("B", s * 46.0, -2.0, 0, 12.0, 8.0, depth + 2.0, col=STONE_D, mat="Sandstone"))
    parts += voussoir_ring(spring, r_in, r_out, depth, 13, STONE, "Sandstone")
    parts += voussoir_ring(spring, r_out, r_out + 3.0, depth - 2.0, 13, STONE_INSET, "Sandstone")
    parts += voussoir_ring(spring, r_in - 1.2, r_in, depth + 1.0, 13, STONE_D, "Sandstone")
    ky = spring + r_out - 0.5
    parts.append(P("B", 0, ky, 0, 12.0, 14.0, depth + 3.0, col=STONE, mat="Sandstone"))
    for z in (-depth / 2 - 1.8, depth / 2 + 1.8):
        parts.append(P("B", 0, ky - 1.0, z, 8.0, 3.0, 0.8, col=GOLD, mat="Metal"))
        for x in (-2.8, 0.0, 2.8):
            dz = 2.0 + (0.6 if x == 0 else 0.0)  # gold diamond crown points (were K cones)
            parts.append(P("B", x, ky + 2.0 + (0.6 if x == 0 else 0.0), z, dz, dz, 0.8, 0, 0, 45, GOLD, "Metal"))
        parts.append(P("S", 0, ky - 1.0, z + (-0.5 if z < 0 else 0.5), 1.6, 1.6, 0.8, col="#2fd0c8", mat="Neon"))
    # cornice across the top of the ring, stepping back into the cliff
    parts.append(P("B", 0, spring + r_out + 5.5, 0, 2 * (r_out + 6.0), 3.0, depth + 1.0, col=STONE_D, mat="Sandstone"))
    return {"parts": parts}


def exchange_bays() -> dict:
    """Vehicle exchange hall at the foot of the west bluff: two stone bays (PLANE left, CAR right) under a carved
    entablature with timber sign boards carrying block-built vehicle pictograms. Front faces local -Z."""
    W, D, H = 100.0, 38.0, 30.0
    parts = [P("B", 0, -2.0, 0, W + 6.0, 6.0, D + 6.0, col=STONE_D, mat="Sandstone"),
             P("B", 0, H / 2 + 1.0, D / 2 - 2.0, W, H, 4.0, col=STONE, mat="Sandstone")]
    for s in (-1, 1):
        parts.append(P("B", s * (W / 2 - 2.0), H / 2 + 1.0, 0, 4.0, H, D, col=STONE, mat="Sandstone"))
    parts.append(P("B", 0, H / 2 + 1.0, 2.0, 8.0, H, D - 4.0, col=STONE, mat="Sandstone"))
    for x in (-W / 2 + 4.0, -4.0, 4.0, W / 2 - 4.0):
        parts.append(P("B", x, 2.2, -D / 2 + 1.0, 10.0, 3.4, 10.0, col=STONE_D, mat="Sandstone"))
        parts += chunky(x, 13.0, -D / 2 + 1.0, 7.0, 19.0, 7.0, STONE, "Sandstone")
        parts.append(P("B", x, 23.4, -D / 2 + 1.0, 10.0, 2.0, 10.0, col=STONE_D, mat="Sandstone"))
    parts.append(P("B", 0, 27.5, -D / 2 + 1.0, W + 4.0, 6.5, 10.0, col=STONE, mat="Sandstone"))
    parts.append(P("B", 0, 31.6, 0, W + 6.0, 2.0, D + 6.0, col=STONE_D, mat="Sandstone"))
    parts.append(P("W", 0, 34.0, -D / 2 - 1.0, W + 6.0, 3.0, 6.0, 0, 0, 0, TERRA, "ClayRoofTiles"))
    parts.append(P("W", 0, 34.0, D / 2 + 1.0, W + 6.0, 3.0, 6.0, 0, 180, 0, TERRA, "ClayRoofTiles"))
    parts.append(P("B", 0, 34.0, 0, W + 4.0, 3.0, D - 6.0, col=TERRA_D, mat="ClayRoofTiles"))
    bay_cols = {-1: "#7cc7f0", 1: "#e07a4a"}  # plane bay sky blue, car bay terracotta
    for s in (-1, 1):
        cx = s * (W / 4 + 1.0)
        parts.append(P("B", cx, 1.0, 0, W / 2 - 12.0, 1.0, D - 6.0, col=STONE_INSET, mat="Pavement"))
        parts.append(P("B", cx, 14.0, D / 2 - 4.3, W / 2 - 12.0, 4.0, 0.6, col=bay_cols[s], mat="Fabric"))
        # sign board with rope hangers
        parts.append(P("B", cx, 27.5, -D / 2 - 4.6, 26.0, 7.0, 1.2, col=TIMBER, mat="WoodPlanks"))
        parts.append(P("B", cx, 27.5, -D / 2 - 5.3, 24.0, 5.6, 0.4, col=TIMBER_D, mat="WoodPlanks"))
        ic = -D / 2 - 5.6
        if s < 0:  # plane pictogram
            parts += [P("B", cx, 27.6, ic, 12.0, 1.6, 0.4, col=CREAM_L, mat="SmoothPlastic"),
                      P("B", cx + 1.0, 27.6, ic, 3.0, 5.0, 0.4, col=CREAM_L, mat="SmoothPlastic"),
                      P("B", cx - 5.0, 28.8, ic, 1.4, 3.0, 0.4, col=CREAM_L, mat="SmoothPlastic"),
                      P("W", cx + 6.6, 27.6, ic, 0.4, 1.6, 1.6, 0, 90, 0, CREAM_L, "SmoothPlastic")]
        else:  # car pictogram
            parts += [P("B", cx, 28.0, ic, 12.0, 2.6, 0.4, col=CREAM_L, mat="SmoothPlastic"),
                      P("B", cx - 1.0, 30.0, ic, 5.0, 1.8, 0.4, col=CREAM_L, mat="SmoothPlastic"),
                      P("C", cx - 3.8, 26.2, ic, 2.6, 0.4, 2.6, 90, 0, 0, CREAM_L, "SmoothPlastic"),
                      P("C", cx + 3.8, 26.2, ic, 2.6, 0.4, 2.6, 90, 0, 0, CREAM_L, "SmoothPlastic")]
    # side buttresses into the bluff
    for s in (-1, 1):
        parts.append(P("W", s * (W / 2 + 5.0), 12.0, 0, D, 24.0, 10.0, 0, -90 * s, 0, STONE_D, "Sandstone"))
    return {"parts": parts}


def exchange_pad(colour: str) -> dict:
    """Round exchange pad in front of a bay: stone rim, coloured inset, glowing ring (non-colliding glow)."""
    return {"parts": [
        P("C", 0, -0.4, 0, 30.0, 2.4, 30.0, col=STONE_D, mat="Sandstone"),
        P("C", 0, 0.6, 0, 25.0, 0.6, 25.0, col=STONE, mat="Pavement"),
        P("C", 0, 0.95, 0, 21.0, 0.2, 21.0, col=colour, mat="Neon", nc=True, light=[18, 0.8, colour, False]),
        P("C", 0, 1.0, 0, 17.0, 0.25, 17.0, col=colour, mat="SmoothPlastic", nc=True),
    ] + [P("B", 13.2 * math.cos(math.radians(a)), 0.9, 13.2 * math.sin(math.radians(a)), 2.0, 1.0, 2.0, 0, -a, 0,
           GOLD, "Metal") for a in range(0, 360, 45)]}


DOCK_PLANK_TOP = 3.35  # plank y 3.0, 0.7 thick (instance y 0): 2.3 over the sand at the root, above the 2.2 wall ray
DOCK_SLIPWAY = {"length": 16.0, "width": 12.6, "bottom": -1.0}  # trap audit H0-03 (a): shore ramp onto the planks
DOCK_KICKER = {"length": 6.0, "width": 12.0, "rise": 1.5}  # H0-03 (c): splash ramp off the end platform
DOCK_SHOAL = {"level": -1.5, "radius": 24.0, "blend": 20.0, "beyond": 90.0}  # H0-03 (c): shallow water round the docks


def timber_dock(length: float) -> dict:
    """Plank dock along local -Z from its shore end (z = 0) out over the water, on square piles. A timber slipway on
    the shore side (+Z) climbs from under the sand to the plank top (the bare plank ends were a 2.3 step, which the
    car's wall rays read as a wall: trap audit H0-03), and a low splash kicker at the far end throws an overshooting car
    out over the shoal (DOCK_SHOAL) instead of nosing it off the edge."""
    parts = []
    sw = DOCK_SLIPWAY
    rise_sw = DOCK_PLANK_TOP - sw["bottom"]
    # WedgePart: low edge at local -Z, full height at +Z; turned 180 the full height meets the first plank at z = -0.2
    parts.append(P("W", 0, sw["bottom"] + rise_sw / 2, sw["length"] / 2 - 0.2, sw["width"], rise_sw, sw["length"],
                   0, 180, 0, TIMBER_L, "WoodPlanks"))
    n = int(length // 3.2)
    for i in range(n):
        z = -1.6 - i * 3.2
        parts.append(P("B", (0.3 if i % 3 == 0 else -0.2), 3.0, z, 12.0 + (0.6 if i % 2 else 0.0), 0.7, 3.0,
                       0, (1.5 if i % 4 == 1 else -1.0 if i % 5 == 2 else 0.0), 0, TIMBER_L, "WoodPlanks"))
    last = -1.6 - (n - 1) * 3.2 - 1.5  # far edge of the last plank; the end platform starts at -length
    if last > -length + 0.1:  # close the open gap before the platform (1.3 on the long dock, 2.5 on the short one)
        parts.append(P("B", 0.0, 3.0, (last - length) / 2, 12.0, 0.7, last + length + 0.4, col=TIMBER_L,
                       mat="WoodPlanks"))
    for s in (-1, 1):
        parts.append(P("B", s * 5.4, 2.2, -length / 2, 1.2, 1.0, length, col=TIMBER, mat="WoodPlanks"))
        for i in range(0, int(length // 14) + 1):
            z = -2.0 - i * 14.0
            parts.append(P("B", s * 6.4, -2.0, z, 1.8, 12.0, 1.8, col=TIMBER_D, mat="WoodPlanks"))
            if i % 2 == 0:
                parts.append(P("B", s * 6.4, 4.6, z, 1.6, 1.6, 1.6, col=TIMBER_D, mat="WoodPlanks"))
    # end platform and bollards
    parts.append(P("B", 0, 3.0, -length - 4.0, 20.0, 0.8, 8.0, col=TIMBER_L, mat="WoodPlanks"))
    kk = DOCK_KICKER  # on the end platform (top 3.4), full height at the very end (z = -length - 8)
    parts.append(P("W", 0, 3.4 + kk["rise"] / 2, -length - 8.0 + kk["length"] / 2, kk["width"], kk["rise"], kk["length"],
                   0, 180, 0, TIMBER, "WoodPlanks"))
    for s in (-1, 1):
        parts.append(P("C", s * 8.5, 4.4, -length - 6.5, 1.6, 2.4, 1.6, col=TIMBER_D, mat="Wood"))
        parts.append(P("B", s * 9.6, -2.0, -length - 4.0, 1.8, 12.0, 1.8, col=TIMBER_D, mat="WoodPlanks"))
    return {"parts": parts}


COVE_SLIPWAY = {"length": 30.0, "width": 14.0, "base": 1.0, "overlap": 1.0}  # trap audit H0-04


def cove_slipway(rise: float) -> dict:
    """Two-way timber ramp off the seaward edge of the AltCove boardwalk down to the cove beach (trap audit H0-04: the
    find was a 4.6-stud drop off an unrailed slab with no way back up). Pivot at the top of the high edge (the slab top);
    local +Z runs downhill. The base sits `rise` below the pivot, under the sand, so the slope runs into the beach
    instead of ending in a lip; low non-colliding rope posts mark both sides."""
    sw = COVE_SLIPWAY
    L, W = sw["length"], sw["width"]
    # WedgePart: low edge at local -Z, full height at +Z; turned 180 the full height is at z = 0 (the slab edge)
    parts = [P("W", 0, -rise / 2, L / 2, W, rise, L, 0, 180, 0, TIMBER_L, "WoodPlanks")]
    z0, z1 = 2.0, 2.0 + L * 0.6
    for s in (-1, 1):
        for k in range(4):
            z = z0 + k * (z1 - z0) / 3
            parts.append(P("B", s * (W / 2 - 0.4), -rise * z / L + 1.2, z, 0.6, 2.4, 0.6, col=TIMBER_D, mat="Wood",
                           nc=True))
        zm = (z0 + z1) / 2  # rope along the post tops, pitched with the slope (positive rx raises the -Z end)
        parts.append(P("B", s * (W / 2 - 0.4), -rise * zm / L + 2.2, zm, 0.3, 0.3, (z1 - z0) / math.cos(math.atan2(rise, L)),
                       math.degrees(math.atan2(rise, L)), 0, 0, ROPE, "Fabric", nc=True))
    return {"parts": parts}


def palm_tree(lean: float, seed: int) -> dict:
    """Faceted palm: stacked trunk blocks curving with the lean, a crown of drooping frond wedges, coconuts."""
    rng = np.random.default_rng(seed)
    parts = []
    pos = np.array([0.0, 0.0, 0.0])
    ang = 0.0
    for i in range(7):
        seg = 5.2
        ang += lean / 7.0
        d = np.array([0.0, math.cos(math.radians(ang)), -math.sin(math.radians(ang))])
        c = pos + d * seg / 2
        w = 2.8 - i * 0.16
        # L61: round tapered trunk segments in one bark tone (the alternating blocks read as temp geometry)
        parts.append(P("C", c[0], c[1], c[2], w, seg + 0.3, w, ang, 0, 0, "#a27c50" if i % 2 == 0 else "#977248", "Wood"))
        pos = pos + d * seg
    top = pos
    parts.append(P("B", top[0], top[1] + 0.6, top[2], 3.4, 2.4, 3.4, 0, 20, 0, "#7a5a36", "Wood"))
    for k in range(13):  # nine long drooping fronds plus an upper layer of four shorter, lighter ones
        upper = k >= 9
        th = (k - 9) * 90.0 + 20.0 + float(rng.uniform(-8, 8)) if upper else k * 40.0 + float(rng.uniform(-8, 8))
        droop = -float(rng.uniform(4, 14)) if upper else -float(rng.uniform(20, 36))
        L = float(rng.uniform(8.0, 10.0)) if upper else float(rng.uniform(13.0, 16.0))
        dl = np.array([0.0, math.sin(math.radians(droop)), -math.cos(math.radians(droop))])
        tr = math.radians(th)
        dw = np.array([dl[0] * math.cos(tr) + dl[2] * math.sin(tr), dl[1], -dl[0] * math.sin(tr) + dl[2] * math.cos(tr)])
        c = top + np.array([0, 1.4, 0]) + dw * (L / 2)
        parts.append(P("W", c[0], c[1] + (0.8 if upper else 0.0), c[2], 4.4 if not upper else 3.4, 0.9, L, droop, th, 0,
                       ("#7cbf4e" if upper else ("#55a03c" if k % 2 else "#3f8a30")), "LeafyGrass", nc=True))
    for k in range(3):
        a = math.radians(k * 120 + 30)
        parts.append(P("S", top[0] + 1.6 * math.cos(a), top[1] - 0.8, top[2] + 1.6 * math.sin(a), 1.5, 1.6, 1.5,
                       col="#6b4a2a", mat="Wood", nc=True))
    return {"parts": parts}


def broadleaf_tree(seed: int) -> dict:
    rng = np.random.default_rng(seed)
    parts = [P("B", 0, 5.0, 0, 2.6, 10.0, 2.6, 0, 15, 0, "#7a5232", "Wood"),
             P("B", 0, 3.0, 0, 3.6, 6.0, 3.6, 0, 60, 0, "#6a4628", "Wood")]
    # L61: rounded canopy of three overlapping ellipsoids (the stacked chunky slabs read as copy-pasted green boxes)
    for k, (x, y, z, w, h) in enumerate(((0.0, 13.5, 0.0, 17.0, 11.0), (3.6, 17.0, 2.0, 11.0, 8.5),
                                         (-3.4, 18.0, -1.8, 10.0, 8.0))):
        dx, dz = float(rng.uniform(-1.2, 1.2)), float(rng.uniform(-1.2, 1.2))
        parts.append(P("S", x + dx, y, z + dz, w, h, w * 0.92, col=("#4f8f3a", "#64a646", "#76b252")[k],
                       mat="SmoothPlastic", nc=k > 0))
    return {"parts": parts}


def shrub(seed: int) -> dict:
    """Three faceted leaf blocks plus two blossom clusters (L61: colour breakup on the lawns)."""
    rng = np.random.default_rng(seed)
    parts = []
    for k in range(3):
        w = float(rng.uniform(4.5, 7.0))
        parts.append(P("S", float(rng.uniform(-2.5, 2.5)), w * 0.3, float(rng.uniform(-2.5, 2.5)), w, w * 0.75, w * 0.9,
                       col=("#5a9a40", "#4a8a36", "#6cae4c")[k], mat="SmoothPlastic", nc=True))
    for k in range(2):
        a = float(rng.uniform(0, 2 * math.pi))
        parts.append(P("S", 2.2 * math.cos(a), 3.4 + k * 0.8, 2.2 * math.sin(a), 2.2, 1.6, 2.2,
                       col=FLOWERS[(seed + k) % len(FLOWERS)], mat="SmoothPlastic", nc=True))
    return {"parts": parts}


def cypress_tree(seed: int) -> dict:
    """Tall Mediterranean cypress (three parts): a flame-shaped skyline silhouette that breaks up the round broadleaf
    canopy. Ellipsoids, not K cones: the CSG cone renders as stacked blocks at this size."""
    rng = np.random.default_rng(seed)
    h = float(rng.uniform(26.0, 34.0))
    return {"parts": [
        P("B", 0, 2.0, 0, 1.8, 4.0, 1.8, 0, 20, 0, "#6e4a2c", "Wood"),
        P("S", 0, 2.5 + h * 0.4, 0, 8.0, h * 0.8, 8.0, col="#3c7436", mat="SmoothPlastic"),
        P("S", 0.4, 2.5 + h * 0.72, -0.3, 5.0, h * 0.5, 5.0, col="#4c8a3e", mat="SmoothPlastic", nc=True),
    ]}


def market_stall(seed: int) -> dict:
    """Plaza market stall: timber counter and posts, striped canvas awning, crates of fruit. Front faces local -Z."""
    rng = np.random.default_rng(seed)
    stripe = (BUNTING[seed % 3], "#f6eedc")
    parts = [P("B", 0, 2.0, 0, 14.0, 4.0, 5.0, col=TIMBER_L, mat="WoodPlanks"),
             P("B", 0, 4.2, -0.4, 14.6, 0.5, 5.8, col=TIMBER, mat="WoodPlanks")]
    for sx in (-1, 1):
        for sz in (-1, 1):
            parts.append(P("B", sx * 6.6, 5.0, sz * 2.4 + 0.6, 0.8, 10.0, 0.8, col=TIMBER_D, mat="WoodPlanks"))
    for k in range(5):  # awning: five sloped stripes, low edge to the front
        parts.append(P("W", -6.0 + k * 3.0, 10.6, -0.6, 3.0, 1.6, 8.4, 0, 0, 0, stripe[k % 2], "Fabric"))
    for k in range(3):  # produce on the counter
        x = -4.5 + k * 4.5
        parts.append(P("S", x, 5.4, -0.8, 3.0, 1.6, 2.6, col=("#f08a2a", "#e8485e", "#ffd54a")[(k + seed) % 3],
                       mat="SmoothPlastic", nc=True))
    parts.append(P("B", float(rng.uniform(-6, 6)), 1.6, -4.4, 3.2, 3.2, 3.2, 0, float(rng.uniform(0, 30)), 0, TIMBER_L,
                   "WoodPlanks"))
    return {"parts": parts}


def plaza_planter(seed: int) -> dict:
    """Stepped sandstone tub (v29 B2: two chamfered boxes, terracotta rim) holding a small cypress (smooth ellipsoids,
    the cypress_tree silhouette) and three low wedge flowers in two colours; replaces the stacked-cube shrub that read
    as voxel art. Same footprint as before; collides only at its stone tub."""
    parts = chunky(0, 1.6, 0, 8.6, 3.2, 8.6, "#c9a46e", "Sandstone", bevel=0.82)
    parts += chunky(0, 3.3, 0, 9.4, 0.6, 9.4, TERRA, "Sandstone", bevel=0.82)
    parts.append(P("B", 0, 3.5, 0, 6.4, 0.4, 6.4, 0, 0, 0, "#4a3a28", "Ground", nc=True))  # soil
    h = 8.0 + (seed % 3) * 1.2
    parts.append(P("S", 0, 3.6 + h * 0.5, 0, 3.8, h, 3.8, col="#3f7a34", mat="SmoothPlastic", nc=True))
    parts.append(P("S", 0.3, 3.6 + h * 0.62, -0.2, 2.4, h * 0.6, 2.4, col="#4f8f3e", mat="SmoothPlastic", nc=True))
    cols = (FLOWERS[(seed + 0) % len(FLOWERS)], FLOWERS[(seed + 2) % len(FLOWERS)])
    for k, (x, z) in enumerate(((2.8, -1.6), (-2.6, 1.8), (1.2, 2.9))):
        parts.append(P("W", x, 4.0, z, 1.2, 1.0, 1.2, 0, 60 * k + 20, 0, cols[k % 2], "SmoothPlastic", nc=True))
    return {"parts": parts}


def harbour_crates(seed: int) -> dict:
    """Stacked harbour crates and a barrel pair for the plaza rim (v28 harbour-town proposal). Painted wood, a rope
    coil on top; small enough to sit outside every drive lane."""
    rng = np.random.default_rng(seed)
    parts = [P("B", -1.6, 1.7, 0, 3.4, 3.4, 3.4, 0, float(rng.uniform(-8, 8)), 0, TIMBER_L, "WoodPlanks"),
             P("B", 1.9, 1.4, 1.2, 2.8, 2.8, 2.8, 0, float(rng.uniform(10, 30)), 0, TIMBER, "WoodPlanks"),
             P("B", -1.4, 5.0, 0.2, 2.6, 2.6, 2.6, 0, float(rng.uniform(20, 50)), 0, TIMBER_L, "WoodPlanks")]
    for dz in (-0.5, 0.5):  # painted straps on the big crate
        parts.append(P("B", -1.6, 1.7, dz * 3.5, 3.5, 3.5, 0.25, 0, 0, 0, TERRA_D, "WoodPlanks", nc=True))
    for k in range(2):
        parts.append(P("C", 5.2 + k * 2.8, 2.0, -1.0 + k * 1.2, 2.6, 4.0, 2.6, col=TIMBER, mat="Wood"))
        parts.append(P("C", 5.2 + k * 2.8, 1.2, -1.0 + k * 1.2, 2.8, 0.4, 2.8, col=TIMBER_D, mat="Metal", nc=True))
        parts.append(P("C", 5.2 + k * 2.8, 2.9, -1.0 + k * 1.2, 2.8, 0.4, 2.8, col=TIMBER_D, mat="Metal", nc=True))
    return {"parts": parts}


def quay_bollards(length: float) -> dict:
    """Dock piece for the plaza rim: two stone-capped timber mooring bollards joined by a sagging rope (the bollards
    collide like the plaza lamps, the rope does not; local X is the rope run). A non-colliding part still answers the
    car's ground ray (CarController: RespectCanCollide = false), so a low nc foot would be a phantom step."""
    parts = []
    for s_ in (-1, 1):
        parts.append(P("B", s_ * length / 2, 0.5, 0, 1.8, 1.0, 1.8, col=STONE_D, mat="Sandstone"))
        parts.append(P("C", s_ * length / 2, 2.6, 0, 1.5, 3.2, 1.5, col=TIMBER_D, mat="Wood"))
        parts.append(P("B", s_ * length / 2, 4.4, 0, 2.2, 0.5, 2.2, 0, 45, 0, TIMBER, "WoodPlanks", nc=True))
    n = 5
    for i in range(n):
        t = (i + 0.5) / n
        sag = 4.0 * t * (1 - t) * 1.6
        parts.append(P("B", -length / 2 + t * length, 4.0 - sag, 0, length / n + 0.2, 0.3, 0.3, 0, 0, 0, "#cdb98a",
                       "Fabric", nc=True))
    return {"parts": parts}


def harbour_lamp() -> dict:
    """Harbour-town lamp post for the plaza rim: stone foot, black-timber post, bracket arm, lantern cage with a warm
    light (foot and post collide like the PlazaLamp, so the car never reads a phantom step)."""
    return {"parts": [
        P("B", 0, 0.7, 0, 2.6, 1.4, 2.6, 0, 45, 0, STONE_D, "Sandstone"),
        P("B", 0, 7.0, 0, 0.8, 11.0, 0.8, col=TIMBER_D, mat="Wood"),
        P("B", 0.9, 12.2, 0, 2.2, 0.4, 0.4, col=TIMBER_D, mat="Metal", nc=True),
        P("B", 1.8, 11.2, 0, 1.6, 1.8, 1.6, 0, 45, 0, "#ffe2a0", "Neon", nc=True, light=[22, 0.6, "#ffd08a", False]),
        P("B", 1.8, 12.3, 0, 2.0, 0.4, 2.0, 0, 45, 0, TIMBER_D, "Metal", nc=True),
    ]}


def awning_lean(seed: int) -> dict:
    """A lean-to awning against nothing: two posts and a striped canvas pitch over a bench, for the plaza rim (posts
    and bench collide, the canvas does not: a nc bench would be a phantom step for the car's ground ray). Front faces
    local -Z."""
    stripe = (BUNTING[(seed + 1) % 6], "#f6eedc")
    parts = [P("B", sx * 5.0, 4.0, 0.0, 0.7, 8.0, 0.7, col=TIMBER_D, mat="WoodPlanks") for sx in (-1, 1)]
    for k in range(4):
        parts.append(P("W", -4.5 + k * 3.0, 8.4, 1.4, 3.0, 1.4, 6.4, 0, 0, 0, stripe[k % 2], "Fabric", nc=True))
    parts.append(P("B", 0, 1.6, 0.4, 7.0, 0.5, 1.8, col=TIMBER_L, mat="WoodPlanks"))
    for sx in (-1, 1):
        parts.append(P("B", sx * 2.8, 0.8, 0.4, 0.5, 1.6, 1.4, col=TIMBER_D, mat="WoodPlanks"))
    return {"parts": parts}


def tunnel_lantern() -> dict:
    """Standing lantern for the tunnel shoulders: timber post, caged lantern with a warm light (non-colliding; it
    stands outside the road corridor, v28 1.8). No foot block: a non-colliding part still answers the car's ground ray
    (RespectCanCollide = false), so a foot on the drivable shoulder next to the climbable tube wall would be a phantom
    step. The post starts under the shoulder top and the cage sits above probe reach, so nothing changes the surface."""
    return {"parts": [
        P("B", 0, 6.25, 0, 1.0, 12.5, 1.0, col=TIMBER_D, mat="Wood", nc=True),
        P("B", 0, 12.6, 0, 2.8, 0.5, 2.8, 0, 45, 0, TIMBER_D, "Metal", nc=True),
        P("B", 0, 14.0, 0, 2.2, 2.4, 2.2, 0, 45, 0, "#ffe2a0", "Neon", nc=True, light=[22, 0.9, "#ffcf8a", False]),
        P("B", 0, 15.5, 0, 3.0, 0.5, 3.0, 0, 45, 0, TIMBER_D, "Metal", nc=True),
    ]}


def banner_pole(colour: str) -> dict:
    """Seaward route banner pole (edge language and flags): stone foot, timber pole, crossbar, hanging pennant flag.
    Non-colliding. Flag hangs toward local +X (the road side)."""
    return {"parts": [
        P("B", 0, 0.6, 0, 2.2, 1.6, 2.2, 0, 45, 0, STONE_D, "Sandstone", nc=True),
        P("B", 0, 7.5, 0, 0.7, 15.0, 0.7, col=TIMBER_D, mat="WoodPlanks", nc=True),
        P("B", 1.6, 14.4, 0, 3.6, 0.5, 0.5, col=TIMBER_D, mat="WoodPlanks", nc=True),
        P("B", 2.2, 10.8, 0, 2.6, 6.8, 0.25, col=colour, mat="SmoothPlastic", nc=True),
    ]}


def street_bunting(span: float, height: float, seed: int) -> dict:
    """Festival bunting across the road: two tall timber poles at z = +-span/2 and a pennant string between their
    tops (local Z across the road). Non-colliding; the poles stand outside the road corridor."""
    parts = []
    for sz in (-1, 1):
        parts.append(P("B", 0, height / 2, sz * span / 2, 0.9, height, 0.9, col=TIMBER_D, mat="WoodPlanks", nc=True))
        parts.append(P("B", 0, height + 0.6, sz * span / 2, 1.6, 1.2, 1.6, col=GOLD, mat="Metal", nc=True))
    for part in bunting(span - 2.0, sag=4.0, count=9, seed=seed)["parts"]:
        q = list(part)
        q[2] = r3(q[2] + height - 0.5)
        parts.append(q)
    return {"parts": parts}


def back_yard(seed: int) -> dict:
    """House yard set: two barrels, a crate and a laundry line with three cloths (props every few lots)."""
    rng = np.random.default_rng(seed)
    cloth = ["#f2ead8", "#e8485e", "#3a78b0", "#ffd54a", "#2f9c96"]
    parts = [P("C", 0, 1.6, 0, 2.6, 3.2, 2.6, col=TIMBER, mat="WoodPlanks"),
             P("C", 2.9, 1.6, 0.6, 2.6, 3.2, 2.6, col=TIMBER_L, mat="WoodPlanks"),
             P("B", 1.2, 1.3, -3.0, 2.8, 2.6, 2.8, 0, float(rng.uniform(0, 40)), 0, TIMBER_L, "WoodPlanks")]
    for sx in (-1, 1):
        parts.append(P("B", 8.0 + sx * 7.0, 3.6, 0, 0.5, 7.2, 0.5, col=TIMBER_D, mat="WoodPlanks", nc=True))
    parts.append(P("B", 8.0, 6.9, 0, 14.0, 0.15, 0.15, col="#efe2c0", mat="SmoothPlastic", nc=True))
    for k in range(3):
        parts.append(P("B", 4.0 + k * 4.0, 5.4, 0, 2.6, 3.0, 0.2, 0, 0, float(rng.uniform(-4, 4)),
                       cloth[(seed + k) % len(cloth)], "SmoothPlastic", nc=True))
    return {"parts": parts}


def moored_boat(hull: str, sail: str) -> dict:
    """Small moored sailing boat (non-colliding): painted hull with a pointed bow, timber deck, mast and sail.
    Bow toward local -Z; pivot at the waterline."""
    return {"parts": [
        P("B", 0, 0.4, 2.0, 6.0, 2.4, 12.0, col=hull, mat="WoodPlanks", nc=True),
        P("W", -1.5, 0.4, -6.0, 3.0, 2.4, 4.0, 0, 180, 0, hull, "WoodPlanks", nc=True),
        P("W", 1.5, 0.4, -6.0, 3.0, 2.4, 4.0, 0, 180, 0, hull, "WoodPlanks", nc=True),
        P("B", 0, 1.7, 2.0, 5.4, 0.3, 11.4, col=TIMBER_L, mat="WoodPlanks", nc=True),
        P("B", 0, 7.5, 0.0, 0.5, 12.0, 0.5, col=TIMBER_D, mat="WoodPlanks", nc=True),
        P("W", 0, 7.6, 3.2, 0.2, 9.0, 6.0, 0, 0, 0, sail, "SmoothPlastic", nc=True),
    ]}


def buoy(colour: str) -> dict:
    return {"parts": [P("C", 0, 0.6, 0, 2.6, 2.0, 2.6, col=colour, mat="SmoothPlastic", nc=True),
                      P("B", 0, 2.6, 0, 0.4, 2.4, 0.4, col="#f2ead8", mat="SmoothPlastic", nc=True)]}


def bunting(length: float, sag: float = 3.0, count: int = 7, seed: int = 0) -> dict:
    """A string of pennant flags along local Z (pivot at the middle of the span, ends at z = +-length/2 at y = 0),
    sagging `sag` at the middle. Non-colliding; two rope halves plus `count` pennants (rotated wedges)."""
    parts = []
    half = length / 2
    ang = math.degrees(math.atan2(sag, half))
    seg = math.hypot(sag, half)
    for s in (-1, 1):
        parts.append(P("B", 0, -sag / 2, s * half / 2, 0.18, 0.18, seg, -s * ang, 0, 0, "#efe2c0", "SmoothPlastic", nc=True))
    for k in range(count):
        z = -half + (k + 0.5) * length / count
        y = -sag * (1 - abs(z) / half) - 1.2
        parts.append(P("W", 0, y, z, 0.3, 2.6, 2.2, 180, 0, 0, BUNTING[(k + seed) % len(BUNTING)], "SmoothPlastic", nc=True))
    return {"parts": parts}


def risky_log_bridge(length: float) -> dict:
    """HUB-BOSS-1 risky bridge: a narrow (28 wide, road 44) deck of faceted logs, top flush with the paver top the
    car drives on (instance at ribbon + 2.6, pitched along the span; log bevels peak at +2.71, under the corridor
    floor +3), on two stringers
    and piles; no barriers on the span (low non-colliding rope markers only), stout posts at the ends outside the
    road corridor."""
    parts = []
    n = int(length // 2.9)
    pitch = length / n
    for i in range(n):
        z = -length / 2 + (i + 0.5) * pitch
        w = 28.0 + (0.8 if i % 3 == 0 else -0.6 if i % 3 == 1 else 0.2)
        x = (0.5 if i % 4 == 0 else -0.4 if i % 4 == 2 else 0.0)
        col = TIMBER if i % 2 == 0 else "#7a4a2c"
        parts.append(P("B", x, -1.3, z, w, 2.6, 2.6, 0, 0, 0, col, "Wood"))
        parts.append(P("B", x, -1.3, z, w + 0.6, 2.0, 2.0, 45, 0, 0, "#6e4228", "Wood"))
    for s in (-1, 1):
        parts.append(P("B", s * 9.0, -3.9, 0, 2.4, 2.4, length + 4.0, col=TIMBER_D, mat="Wood"))
        for z in (-length / 2 - 1.0, 0.0, length / 2 + 1.0):
            parts.append(P("B", s * 9.0, -11.0, z, 2.6, 13.0, 2.6, col=TIMBER_D, mat="Wood"))
        # end posts on the causeway, outside the corridor
        for z in (-length / 2 - 2.5, length / 2 + 2.5):
            parts.append(P("B", s * 25.6, 2.0, z, 2.4, 7.0, 2.4, col=TIMBER_D, mat="Wood"))
            parts.append(P("B", s * 25.6, 5.9, z, 3.0, 0.8, 3.0, col=TIMBER, mat="Wood"))
    # sagging rope edge markers (non-colliding: they never stop a car)
    for s in (-1, 1):
        for i in range(4):
            z0 = -length / 2 + i * length / 4
            parts.append(P("B", s * 14.2, 1.2 - (0.5 if i in (1, 2) else 0.2), z0 + length / 8, 0.35, 0.35, length / 4,
                           col=ROPE, mat="Fabric", nc=True))
            parts.append(P("B", s * 14.2, 0.9, z0, 0.7, 2.2, 0.7, col=TIMBER_D, mat="Wood", nc=True))
    return {"parts": parts}


def lighthouse() -> dict:
    """Harbour lighthouse on the NE headland (skyline landmark): faceted cream and terracotta bands, lamp room."""
    parts = chunky(0, 2.0, 0, 22.0, 6.0, 22.0, STONE_D, "Sandstone", bevel=0.8)
    y = 5.0
    for i, (w, h) in enumerate(((15.0, 12.0), (13.5, 12.0), (12.0, 11.0), (10.6, 10.0))):
        col = CREAM if i % 2 == 0 else TERRA
        parts += chunky(0, y + h / 2, 0, w, h, w, col, "Plaster" if i % 2 == 0 else "ClayRoofTiles", bevel=0.8)
        parts.append(P("B", 0, y + h, 0, w + 1.6, 1.0, w + 1.6, col=STONE_D, mat="Sandstone"))
        if i % 2 == 0:
            parts.append(P("B", 0, y + h * 0.55, -w / 2 - 0.3, 2.6, 3.6, 0.6, col=GLASS, mat="SmoothPlastic"))
        y += h
    parts += chunky(0, y + 0.8, 0, 15.0, 1.6, 15.0, STONE_D, "Sandstone", bevel=0.8)
    for k in range(8):
        a = math.radians(k * 45)
        parts.append(P("B", 6.6 * math.cos(a), y + 3.0, 6.6 * math.sin(a), 0.6, 3.0, 0.6, col=TIMBER_D, mat="Metal"))
    parts.append(P("B", 0, y + 4.6, 0, 7.0, 6.0, 7.0, 0, 45, 0, "#bfe8ff", "Glass", a=0.35))
    parts.append(P("S", 0, y + 4.6, 0, 3.6, 3.6, 3.6, col="#ffe9a8", mat="Neon", nc=True, light=[60, 1.6, "#ffd98a", False]))
    parts += chunky(0, y + 9.0, 0, 10.0, 3.0, 10.0, TERRA_D, "ClayRoofTiles", bevel=0.8)
    parts += chunky(0, y + 11.6, 0, 6.6, 2.6, 6.6, TERRA, "ClayRoofTiles", bevel=0.8)
    parts += chunky(0, y + 13.6, 0, 3.2, 2.0, 3.2, TERRA_D, "ClayRoofTiles", bevel=0.8)
    parts.append(P("S", 0, y + 15.0, 0, 1.6, 1.6, 1.6, col=GOLD, mat="Metal"))
    return {"parts": parts}


def plaza_fountain() -> dict:
    parts = chunky(0, 0.6, 0, 40.0, 2.2, 40.0, STONE_D, "Sandstone", bevel=0.86)
    parts += chunky(0, 2.4, 0, 34.0, 3.0, 34.0, STONE, "Sandstone", bevel=0.86)
    parts.append(P("B", 0, 3.5, 0, 29.0, 1.0, 29.0, 0, 0, 0, "#3fd0dc", "Glass", nc=True, a=0.3))
    parts.append(P("B", 0, 3.5, 0, 22.0, 1.0, 22.0, 0, 45, 0, "#3fd0dc", "Glass", nc=True, a=0.3))
    parts += chunky(0, 7.0, 0, 6.0, 10.0, 6.0, STONE, "Sandstone", bevel=0.8)
    parts += chunky(0, 12.4, 0, 16.0, 1.6, 16.0, STONE_D, "Sandstone", bevel=0.82)
    parts.append(P("B", 0, 13.4, 0, 13.0, 0.6, 13.0, 0, 45, 0, "#3fd0dc", "Glass", nc=True, a=0.3))
    parts += chunky(0, 15.6, 0, 3.0, 5.0, 3.0, STONE, "Sandstone", bevel=0.8)
    # sky token emblem: gold star block and a glowing gem
    parts.append(P("B", 0, 20.6, 0, 5.4, 5.4, 1.4, 0, 0, 45, GOLD, "Metal"))
    parts.append(P("B", 0, 20.6, 0, 5.4, 5.4, 1.4, 0, 0, 0, GOLD, "Metal"))
    parts.append(P("S", 0, 20.6, 0, 2.6, 2.6, 2.6, col="#7ff0ff", mat="Neon", nc=True, light=[24, 0.7, "#9ff4ff", False]))
    return {"parts": parts}


def plaza_lamp() -> dict:
    return {"parts": [
        P("B", 0, 0.6, 0, 3.0, 1.2, 3.0, col=STONE_D, mat="Sandstone"),
        P("B", 0, 7.0, 0, 1.0, 12.0, 1.0, col=TIMBER_D, mat="Metal"),
        P("B", 0, 13.6, 0, 2.6, 0.6, 2.6, col=TIMBER_D, mat="Metal"),
        P("B", 0, 15.0, 0, 2.0, 2.4, 2.0, 0, 45, 0, "#ffe9b0", "Neon", nc=True, light=[20, 0.6, "#ffd98a", False]),
        *gable_cap(0, 17.0, 0, 3.4, 1.8, 3.4, TERRA_D, "ClayRoofTiles"),
    ]}


def promenade_lamp() -> dict:
    return {"parts": [
        P("B", 0, 0.5, 0, 2.4, 1.6, 2.4, col=STONE_D, mat="Sandstone"),
        P("B", 0, 6.5, 0, 0.9, 11.0, 0.9, col=TIMBER_D, mat="Metal"),
        P("B", 0, 12.4, -1.6, 0.6, 0.6, 3.6, col=TIMBER_D, mat="Metal"),
        P("B", 0, 11.5, -3.2, 1.6, 1.8, 1.6, 0, 45, 0, "#ffe9b0", "Neon", nc=True),
    ]}


def balustrade(length: float) -> dict:
    parts = [P("B", 0, 0.6, 0, length, 1.2, 2.6, col=STONE_D, mat="Sandstone"),
             P("B", 0, 3.6, 0, length, 0.9, 2.4, col=STONE, mat="Sandstone")]
    n = max(2, int(length // 2.4))
    for i in range(n):
        x = -length / 2 + (i + 0.5) * length / n
        parts.append(P("B", x, 2.1, 0, 0.9, 1.8, 0.9, 0, 45, 0, CREAM, "Sandstone"))
    return {"parts": parts}


def start_gantry() -> dict:
    """Start/finish gantry over station 0 (pillars outside the corridor, banner beam above it, non-colliding)."""
    parts = []
    for s in (-1, 1):
        parts += chunky(s * 31.0, 13.0, 0, 4.0, 26.0, 4.0, STONE, "Sandstone", bevel=0.8)
        parts.append(P("B", s * 31.0, 0.8, 0, 6.0, 1.6, 6.0, col=STONE_D, mat="Sandstone"))
        parts.append(P("B", s * 31.0, 26.6, 0, 5.6, 1.4, 5.6, col=STONE_D, mat="Sandstone"))
        parts += gable_cap(s * 31.0, 29.6, 0, 5.6, 4.0, 5.6, TERRA, "ClayRoofTiles")
    parts.append(P("B", 0, 24.0, 0, 66.0, 2.0, 2.4, col=TIMBER, mat="WoodPlanks", nc=True))
    for i in range(14):
        parts.append(P("B", -29.25 + i * 4.5, 21.4, 0, 4.5, 3.0, 0.5, col=CREAM_L if i % 2 == 0 else "#2a2222",
                       mat="Fabric", nc=True))
    parts.append(P("B", 0, 27.0, 0, 30.0, 4.0, 0.8, col=PLUM, mat="Fabric", nc=True))
    parts.append(P("B", 0, 27.0, -0.5, 26.0, 2.4, 0.3, col=GOLD, mat="Fabric", nc=True))
    return {"parts": parts}


def start_line() -> dict:
    parts = []
    for i in range(22):
        for j in range(2):
            parts.append(P("B", -21 + i * 2, 0, -1 + j * 2, 2, 0.1, 2, col=CREAM_L if (i + j) % 2 == 0 else "#2a2222",
                           mat="SmoothPlastic", nc=True))
    return {"parts": parts}


def cargo_stack(seed: int) -> dict:
    rng = np.random.default_rng(seed)
    parts = []
    for k in range(3):
        x, z = float(rng.uniform(-4, 4)), float(rng.uniform(-3, 3))
        s = float(rng.uniform(3.2, 4.4))
        parts.append(P("B", x, s / 2, z, s, s, s, 0, float(rng.uniform(0, 30)), 0, TIMBER_L, "WoodPlanks"))
    parts.append(P("B", 0.5, 5.6, 0.2, 3.2, 3.2, 3.2, 0, 12, 0, TIMBER, "WoodPlanks"))
    for k in range(2):
        parts.append(P("C", 6.0 + k * 3.2, 2.0, -3.0, 2.8, 4.0, 2.8, col=TIMBER, mat="Wood"))
        parts.append(P("C", 6.0 + k * 3.2, 2.0, -3.0, 3.0, 0.5, 3.0, col=TIMBER_D, mat="Metal"))
    return {"parts": parts}


def ledge_cairn() -> dict:
    return {"parts": [
        P("B", 0, 1.2, 0, 7.0, 2.4, 6.0, 0, 10, 0, STONE_D, "Limestone"),
        P("B", 0.4, 3.4, 0.2, 5.0, 2.0, 4.4, 0, 40, 0, STONE, "Limestone"),
        P("B", -0.2, 5.1, 0, 3.2, 1.6, 3.0, 0, 70, 0, STONE_D, "Limestone"),
        P("B", 0, 10.0, 0, 0.5, 12.0, 0.5, col=TIMBER_D, mat="Wood"),
        P("B", 2.4, 14.0, 0, 4.4, 3.0, 0.2, col=GOLD, mat="Fabric", nc=True),
    ]}


def cove_shack() -> dict:
    parts = [P("B", 0, 0.4, 0, 18.0, 1.0, 14.0, col=TIMBER_L, mat="WoodPlanks")]
    for s in (-1, 1):
        for t in (-1, 1):
            parts.append(P("B", s * 8.0, 4.0, t * 6.0, 1.2, 8.0, 1.2, col=TIMBER_D, mat="Wood"))
    parts.append(P("B", 0, 4.4, 6.2, 16.0, 7.0, 0.8, col=TIMBER, mat="WoodPlanks"))
    parts.append(P("W", 0, 9.4, -2.0, 20.0, 3.0, 9.0, 0, 0, 0, LEAF_D, "LeafyGrass"))
    parts.append(P("W", 0, 9.4, 4.5, 20.0, 3.0, 4.0, 0, 180, 0, LEAF_D, "LeafyGrass"))
    parts.append(P("C", -4.0, 2.0, -3.0, 2.8, 3.0, 2.8, col=TIMBER, mat="Wood"))
    parts.append(P("B", 4.0, 1.6, -2.0, 4.0, 2.4, 3.0, 0, 20, 0, TIMBER_L, "WoodPlanks"))
    return {"parts": parts}


# ------------------------------------------------------------------ v29 Wave 2: harbour frontage and tunnel collar
# Critic v29 Wave 2 (docs/audits/visual_critic_v29.md, items 3.1 and the 2.3-style collar), guide 04_HUB0_CENTRAL_ISLAND.png.
# Owner hard rule: wall/mountain driving stays exactly as it is. Every part below is non-colliding (MapAdapter's DecorQuery
# then clears CanQuery on it, so no wheel probe or respawn ray can stand on it), nothing touches the terrain grid or the
# shells, and nothing is built into the hub cliffs. The moored hovercraft and plane are the existing vehicle models placed
# by the adapter's meshes step (collide false, scripts stripped, anchored).
QUAY = {"from": 16.0, "to": 410.0, "section": 24.0, "top": 2.4, "foot": -4.0, "depth": 6.0, "apron": 8.0, "ramp": 8.0,
        "shoreLevel": 0.5, "faceInset": 1.0}
QUAY_TONES = [CREAM, STONE, CREAM_L, "#eadcb9"]
QUAY_FOOT_COL = "#c9b38a"  # footing course, tide-darkened
QUAY_WET = "#bda97f"  # wet band at the waterline
QUAY_PAVE = "#e2cfa6"
IRON = "#3b3936"
NET = "#6f7d58"
NET_FLOAT = "#e8783a"
BUOY_RED = "#d8483a"
BUOY_WHITE = "#f2ead8"
FLOAT_COL = "#f2ead8"
# Moored display vehicles: the existing models (src/server/PlaneBuilder.luau HERO_PLANE_MODEL_ID / HERO_HOVERCRAFT_*),
# no new asset ids. Mesh frames: the plane mesh has its nose on -X, up +Y, span on Z (hero_plane_v3 manifest), 16.5 span
# at game scale = 5.81 tall; the hovercraft mesh is long on X (98 x 30.9 x 81.6 raw, assets/models/uploaded_models.json),
# 15 long = 4.73 tall. Each lies alongside a pier, 17 off its axis like the moored boats.
MOORED = {
    "plane": {"model": 107580586112839, "height": 5.81, "dock": "TimberDock_Short", "along": 30.0, "side": -1.0,
              "bottom": 2.3, "span": 16.5, "length": 14.5},
    "hovercraft": {"model": 122536889901424, "texture": "rbxassetid://115513663776992", "height": 4.73,
                   "dock": "TimberDock_Long", "along": 34.0, "side": -1.0, "bottom": 0.1, "span": 12.5, "length": 15.0},
}
MOORED_LATERAL = 17.0
# Carved voussoir collar over the tunnel mouths (prefab frame of CliffTunnelArch: opening along local Z, front = -Z).
# Its silhouette follows the stone_arch_v3 colliders that ArtSwap keeps placing (src/shared/ArtSwapRules.luau,
# collidersOnly): a round intrados springing from the jamb tops (+-35.2, 31) to the collider crown (0, 60.7), under every
# collider's lower edge (no invisible lip in the visible opening), with the outer silhouette circle round every collider's
# top (no collider outside visible masonry; tools/map/tests/test_hub0.py checks both).
COLLAR = {"spring": 31.0, "jamb": 35.2, "cy": 25.0, "rIn": 35.7, "rMid": 43.7, "c2": 31.4, "rOut": 54.5, "count": 15,
          "depth": 15.0, "pillarOut": 52.9, "plinth": {-1: (31.14, 51.14, 6.0), 1: (32.86, 52.86, 8.73)}}
COLLAR_INSET = "#e3cfa3"
COLLAR_BAND = "#efdcb6"
COLLAR_DRIP = "#d9c29a"


def rope_parts(a, b, sag: float = 0.8, seg: int = 3, col: str = ROPE, th: float = 0.28) -> list:
    """Sagging rope from a to b (local points) as `seg` thin non-colliding Fabric bars."""
    pts = []
    for i in range(seg + 1):
        t = i / seg
        pts.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t - 4.0 * sag * t * (1 - t), a[2] + (b[2] - a[2]) * t))
    parts = []
    for p0, p1 in zip(pts, pts[1:]):
        v = np.subtract(p1, p0)
        ln = float(np.linalg.norm(v))
        v = v / ln
        rx, ry = math.degrees(math.asin(-v[1])), math.degrees(math.atan2(v[0], v[2]))
        parts.append(P("B", (p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2, (p0[2] + p1[2]) / 2, th, th, ln + 0.1, rx, ry, 0,
                       col, "Fabric", nc=True))
    return parts


def quay_bollard(x: float, y: float, z: float, big: bool = False) -> list:
    d = 1.8 if big else 1.4
    return [P("C", x, y + 0.9, z, d, 1.8, d, col=IRON, mat="Metal", nc=True),
            P("C", x, y + 1.95, z, d + 0.5, 0.35, d + 0.5, col=IRON, mat="Metal", nc=True)]


def quay_section(length: float, seed: int, bollard: bool = False, apron: bool = True) -> dict:
    """One run of the cream stone quay wall at the west beach's waterline (guide: the cream quay edge over the cyan
    shallows). Local X runs along the shore, the seaward face is z = 0 with the sea toward -Z, y is world height above
    sea level. Courses: a tide-darkened footing, an ashlar course of dressed blocks in four cream tones over a recessed
    darker core (the joints), a wet band at the waterline, a proud coping with a wedge chamfer under its lip, and (apron)
    a paved strip behind the coping that ramps down into the sand. All non-colliding."""
    rng = np.random.default_rng(seed)
    Q = QUAY
    L, D, top, foot = length + 0.4, Q["depth"], Q["top"], Q["foot"]
    parts = [P("B", 0, (foot - 0.4) / 2, (D - 0.4) / 2, L, -0.4 - foot, D + 0.4, col=QUAY_FOOT_COL, mat="Sandstone", nc=True),
             P("B", 0, 0.6, D / 2 + 0.3, L, 1.98, D - 0.6, col=STONE_D, mat="Sandstone", nc=True)]
    x, k = -L / 2, int(rng.integers(0, 4))
    while x < L / 2 - 0.01:
        w = min(float(rng.uniform(5.5, 9.5)), L / 2 - x)
        if L / 2 - x - w < 3.0:
            w = L / 2 - x
        inset = 0.12 if k % 2 else 0.0
        parts.append(P("B", x + w / 2, 0.6, D / 2 + inset / 2, w - 0.25, 2.0, D - inset, col=QUAY_TONES[k % 4],
                       mat="Sandstone", nc=True))
        x += w
        k += 1
    parts.append(P("B", 0, 0.3, -0.03, L, 0.6, 0.1, col=QUAY_WET, mat="Sandstone", nc=True))
    parts.append(P("B", 0, (top + 1.6) / 2, D / 2, length - 0.15, top - 1.6, D + 1.2, col=CREAM_L, mat="Sandstone", nc=True))
    parts.append(P("W", 0, 1.3, -0.3, length - 0.15, 0.6, 0.6, 0, 0, 180, CREAM, "Sandstone", nc=True))
    if apron:
        A, R = Q["apron"], Q["ramp"]
        parts.append(P("B", 0, (top - 0.2) / 2, D + 0.6 + A / 2, L, top - 0.2, A, col=QUAY_PAVE, mat="Pavement", nc=True))
        parts.append(P("W", 0, (top - 0.2) / 2, D + 0.6 + A + R / 2, L, top - 0.2, R, 0, 180, 0, QUAY_PAVE, "Pavement",
                       nc=True))
    if bollard:
        parts += quay_bollard(0.0, top, 1.6)
    return {"parts": parts}


def quay_end(mirror: float = 1.0) -> dict:
    """Pier-head at an end of the quay: a squared bastion with a coping, a big bollard and three water steps down to the
    sea along the shore (local +X outward, x mirrored for the south end)."""
    Q = QUAY
    D, top, foot = Q["depth"], Q["top"], Q["foot"]
    m = mirror
    parts = [P("B", m * 2.0, (foot + 1.6) / 2, D / 2, 8.0, 1.6 - foot, D + 1.0, col=STONE, mat="Sandstone", nc=True),
             P("B", m * 2.0, (top + 1.6) / 2, D / 2, 9.2, top - 1.6, D + 2.2, col=CREAM_L, mat="Sandstone", nc=True),
             P("W", m * 2.0, 1.3, -0.8, 9.2, 0.6, 0.6, 0, 0, 180, CREAM, "Sandstone", nc=True)]
    for k in range(3):
        t = top - 0.8 * (k + 1)
        parts.append(P("B", m * (6.0 + 1.2 + 2.4 * k), (foot + t) / 2, 2.5, 2.4, t - foot, 4.0,
                       col=QUAY_TONES[k % 2], mat="Sandstone", nc=True))
    parts += quay_bollard(m * 3.0, top, 2.6, big=True)
    return {"parts": parts}


def quay_lamp(lit: bool) -> dict:
    """Harbour lamp post on the quay apron (paving top 2.2): stone foot, black timber post, iron bracket and a caged
    lantern; the lit ones carry a small warm light (tagged MapLight by the builder, capped by LightLod)."""
    y0 = QUAY["top"] - 0.2
    return {"parts": [
        P("B", 0, y0 + 0.6, 0, 2.4, 1.2, 2.4, 0, 45, 0, STONE_D, "Sandstone", nc=True),
        P("B", 0, y0 + 6.4, 0, 0.8, 10.6, 0.8, col=TIMBER_D, mat="Wood", nc=True),
        P("B", 0, y0 + 11.2, 0, 1.3, 0.6, 1.3, col=IRON, mat="Metal", nc=True),
        P("B", 0.0, y0 + 11.8, -0.9, 0.4, 0.4, 2.2, col=IRON, mat="Metal", nc=True),
        P("B", 0.0, y0 + 10.9, -1.9, 1.6, 1.8, 1.6, 0, 45, 0, "#ffe2a0", "Neon", nc=True,
          light=[20, 0.6, "#ffd08a", False] if lit else None),
        P("B", 0.0, y0 + 12.0, -1.9, 2.0, 0.4, 2.0, 0, 45, 0, IRON, "Metal", nc=True),
    ]}


def quay_crates(seed: int) -> dict:
    """Quay goods on the apron: two or three painted crates, a barrel pair and a coil of rope (non-colliding)."""
    rng = np.random.default_rng(seed)
    y0 = QUAY["top"] - 0.2
    parts = []
    cols = [TIMBER_L, "#c99e72", TIMBER]
    for k in range(2 + seed % 2):
        s = float(rng.uniform(2.6, 3.6))
        x, z, yaw = -3.0 + k * 3.4, float(rng.uniform(-0.8, 0.8)), float(rng.uniform(-12, 12))
        parts.append(P("B", x, y0 + s / 2, z, s, s, s, 0, yaw, 0, cols[k % 3], "WoodPlanks", nc=True))
        parts.append(P("B", x, y0 + s / 2, z, s + 0.12, 0.35, s + 0.12, 0, yaw, 0, TIMBER_D, "WoodPlanks", nc=True))
    parts.append(P("B", -1.2, y0 + 4.6, 0.2, 2.6, 2.4, 2.6, 0, 18, 0, cols[seed % 3], "WoodPlanks", nc=True))
    for k in range(2):
        parts.append(P("C", 5.4 + k * 2.6, y0 + 1.6, 1.6, 2.3, 3.2, 2.3, col=TIMBER, mat="Wood", nc=True))
        parts.append(P("C", 5.4 + k * 2.6, y0 + 1.6, 1.6, 2.5, 0.4, 2.5, col=IRON, mat="Metal", nc=True))
    parts.append(P("C", 4.0, y0 + 0.25, -2.2, 2.6, 0.5, 2.6, col=ROPE, mat="Fabric", nc=True))
    parts.append(P("C", 4.0, y0 + 0.3, -2.2, 1.0, 0.55, 1.0, col=TIMBER_D, mat="Wood", nc=True))
    return {"parts": parts}


def net_rack() -> dict:
    """Fishing-net drying rack on the apron: two posts and a crossbar, a draped net with orange floats, a net heap."""
    y0 = QUAY["top"] - 0.2
    parts = []
    for s in (-1, 1):
        parts.append(P("B", s * 4.5, y0 + 3.0, 0, 0.6, 6.0, 0.6, col=TIMBER_D, mat="Wood", nc=True))
    parts.append(P("B", 0, y0 + 6.1, 0, 10.2, 0.5, 0.5, col=TIMBER, mat="Wood", nc=True))
    parts.append(P("B", 0, y0 + 4.2, -0.35, 8.4, 3.6, 0.12, col=NET, mat="Fabric", nc=True, a=0.25))
    parts.append(P("B", 0, y0 + 4.0, 0.35, 8.0, 3.2, 0.12, col=NET, mat="Fabric", nc=True, a=0.25))
    for k in range(4):
        parts.append(P("S", -3.0 + 2.0 * k, y0 + 5.7, -0.45, 0.6, 0.6, 0.6, col=NET_FLOAT, mat="SmoothPlastic", nc=True))
    parts.append(P("S", 6.6, y0 + 0.4, 1.0, 4.2, 1.4, 3.4, col=NET, mat="Fabric", nc=True))
    parts.append(P("S", 6.0, y0 + 0.9, 1.4, 0.6, 0.6, 0.6, col=NET_FLOAT, mat="SmoothPlastic", nc=True))
    return {"parts": parts}


def pier_dressing(length: float, vessel: tuple[float, float] | None, lantern: bool, kind: str) -> dict:
    """Dressing for a TimberDock, in the dock prefab's own frame (root z = 0, out along -Z, plank top 3.35, piles at
    x = +-6.4 every 14 from z = -2, end platform -L..-L-8): iron bollards on the odd pile heads, rope swags between the
    capped even piles, a lifebuoy board and a rope coil on the end platform, an optional pier-end lantern, and mooring
    lines from the bollards to the moored vessel at local (x, z) = vessel. All non-colliding (the dock itself is
    untouched: it stays the trap-audited H0-03 drive surface)."""
    parts = []
    piles = [-2.0 - i * 14.0 for i in range(int(length // 14) + 1)]
    for s in (-1, 1):
        for i, z in enumerate(piles):
            if i % 2 == 1:
                parts += quay_bollard(s * 6.4, 4.0, z)
        evens = [z for i, z in enumerate(piles) if i % 2 == 0]
        for za, zb in zip(evens, evens[1:]):
            parts += rope_parts((s * 6.4, 5.3, za), (s * 6.4, 5.3, zb), sag=1.0, seg=3)
    L = length
    # lifebuoy board on the north-east corner of the end platform (ring in the board's Y-Z plane, facing +X)
    bx, bz = 9.4, -L - 1.6
    parts.append(P("B", bx, 3.4 + 2.4, bz, 0.5, 4.8, 0.5, col=TIMBER_D, mat="Wood", nc=True))
    parts.append(P("B", bx + 0.15, 6.0, bz, 0.25, 3.2, 3.2, col=TIMBER_L, mat="WoodPlanks", nc=True))
    for j in range(8):
        a = math.radians(j * 45.0)
        parts.append(P("B", bx + 0.45, 6.0 + 1.1 * math.sin(a), bz + 1.1 * math.cos(a), 0.45, 0.95, 0.45, -j * 45.0, 0, 0,
                       BUOY_RED if (j // 2) % 2 == 0 else BUOY_WHITE, "SmoothPlastic", nc=True))
    parts.append(P("C", -6.6, 3.65, -L - 2.8, 2.4, 0.5, 2.4, col=ROPE, mat="Fabric", nc=True))
    parts.append(P("C", -6.6, 3.7, -L - 2.8, 1.0, 0.55, 1.0, col=TIMBER_D, mat="Wood", nc=True))
    if lantern:
        lx, lz = -9.4, -L - 1.2
        parts += [P("B", lx, 3.4 + 4.5, lz, 0.6, 9.0, 0.6, col=TIMBER_D, mat="Wood", nc=True),
                  P("B", lx + 0.9, 12.7, lz, 2.2, 0.35, 0.35, col=IRON, mat="Metal", nc=True),
                  P("B", lx + 1.8, 11.7, lz, 1.4, 1.7, 1.4, 0, 45, 0, "#ffe2a0", "Neon", nc=True,
                    light=[24, 0.6, "#ffd08a", False]),
                  P("B", lx + 1.8, 12.75, lz, 1.8, 0.35, 1.8, 0, 45, 0, IRON, "Metal", nc=True)]
    if vessel is not None:
        vx, vz = vessel
        s = 1.0 if vx > 0 else -1.0
        near = vx - s * (5.0 if kind == "hovercraft" else 3.0)  # hull side / float facing the pier
        y = 3.4 if kind == "hovercraft" else 1.2
        odd = [z for i, z in enumerate(piles) if i % 2 == 1]
        fwd = min(odd, key=lambda z: abs(z - (vz - 10.0)))
        aft = min(odd, key=lambda z: abs(z - (vz + 10.0)))
        parts += rope_parts((near, y, vz - 4.5), (s * 6.4, 5.6, fwd), sag=0.7, seg=3)
        parts += rope_parts((near, y, vz + 4.5), (s * 6.4, 5.6, aft), sag=0.7, seg=3)
    return {"parts": parts}


def seaplane_floats() -> dict:
    """Twin cream floats with a plum stripe, struts and a spreader bar under the moored plane (forward = local -Z; the
    plane mesh sits on the strut tops at y 2.3). Non-colliding."""
    parts = []
    for s in (-1, 1):
        x = s * 3.0
        parts += [P("B", x, 0.45, 0.5, 1.5, 1.3, 11.0, col=FLOAT_COL, mat="SmoothPlastic", nc=True),
                  P("W", x, 0.45, -6.0, 1.5, 1.3, 2.0, 0, 0, 180, FLOAT_COL, "SmoothPlastic", nc=True),
                  P("B", x, 1.15, 0.5, 1.55, 0.2, 9.0, col=PLUM, mat="SmoothPlastic", nc=True)]
        for z in (-2.5, 2.5):
            parts.append(P("B", x * 0.8, 1.9, z, 0.35, 1.6, 0.35, 0, 0, -s * 12.0, TIMBER_D, "Wood", nc=True))
    parts.append(P("B", 0, 1.4, 0.0, 6.0, 0.3, 0.4, col=TIMBER_D, mat="Wood", nc=True))
    return {"parts": parts}


def collar_ray_out(theta_deg: float) -> float:
    """Distance from the intrados centre (0, cy) along the ray at theta to the outer silhouette circle (0, c2) r rOut."""
    C = COLLAR
    dx, dy = math.cos(math.radians(theta_deg)), math.sin(math.radians(theta_deg))
    k = C["c2"] - C["cy"]
    return dy * k + math.sqrt((dy * k) ** 2 - k * k + C["rOut"] ** 2)


def collar_theta0() -> float:
    C = COLLAR
    return math.degrees(math.asin((C["spring"] - C["cy"]) / C["rIn"]))


def cliff_tunnel_collar() -> dict:
    """Carved voussoir collar for the tunnel mouths (critic v29 Wave 2, replaces the grey stone_arch_v3 mesh, whose
    colliders stay: ArtSwapRules collidersOnly). Prefab frame of CliffTunnelArch (front = -Z, y 0 = deck top). Plinths
    and panelled jambs with carved plaques and stepped imposts, haunch masonry, 15 voussoirs (alternating cream tones,
    each with a raised panel and boss), a carved archivolt band out to the silhouette circle with chevron reliefs and a
    drip mould, a stepped keystone carrying the crown emblem around the kept cyan gem, and a hanging lantern with a warm
    bounce light under the crown. Every part is non-colliding."""
    C = COLLAR
    parts = []
    depth, cy, r_in, r_mid, spring = C["depth"], C["cy"], C["rIn"], C["rMid"], C["spring"]
    zf = -depth / 2
    for s in (-1, 1):
        x_in, x_out, top = C["plinth"][s]
        w, xc = x_out - x_in, s * (x_in + x_out) / 2
        parts.append(P("B", xc, (top - 1.5) / 2, 0, w, top + 1.5, depth + 1.6, col=COLLAR_DRIP, mat="Sandstone", nc=True))
        parts.append(P("W", xc, top + 0.35, zf - 0.4, w, 0.7, 0.8, col=STONE, mat="Sandstone", nc=True))
        p_in, p_out = C["jamb"], C["pillarOut"]
        pw, pxc = p_out - p_in, s * (p_in + p_out) / 2
        ph = spring - top
        parts.append(P("B", pxc, (top + spring) / 2, 0, pw, ph, depth, col=CREAM, mat="Sandstone", nc=True))
        parts.append(P("B", pxc, (top + spring) / 2 - 1.0, zf - 0.15, pw - 4.4, ph - 9.0, 0.3, col=COLLAR_INSET,
                       mat="Sandstone", nc=True))
        py = (top + spring) / 2 + 2.0
        parts.append(P("B", pxc, py, zf - 0.45, pw - 8.0, 8.0, 0.4, col=CREAM_L, mat="Sandstone", nc=True))
        for t in (-1, 1):
            parts.append(P("B", pxc + t * 1.25, py, zf - 0.75, 0.7, 4.6, 0.3, 0, 0, t * 40.0, COLLAR_INSET, "Sandstone",
                           nc=True))
        parts.append(P("B", pxc, py - 3.0, zf - 0.75, 1.1, 1.1, 0.3, 0, 0, 45, COLLAR_INSET, "Sandstone", nc=True))
        # stepped impost (outward and forward only: the opening edge stays the jamb face)
        parts.append(P("B", s * (p_in + (pw + 1.2) / 2), spring - 2.9, -0.6, pw + 1.2, 1.6, depth + 1.2, col=STONE,
                       mat="Sandstone", nc=True))
        parts.append(P("B", s * (p_in + (pw + 2.4) / 2), spring - 1.05, -1.2, pw + 2.4, 2.1, depth + 2.4, col=CREAM_L,
                       mat="Sandstone", nc=True))
        parts.append(P("W", s * (p_in + (pw + 2.4) / 2), spring - 2.45, zf - 1.8, pw + 2.4, 0.7, 0.7, 0, 0, 180, STONE,
                       "Sandstone", nc=True))
        # haunch masonry between the jamb top and the archivolt, set back behind the ring faces
        parts.append(P("B", s * (p_in + 9.65), spring + 6.0, 0.3, 19.3, 12.0, depth - 0.6, col=STONE, mat="Sandstone",
                       nc=True))
    n = C["count"]
    t0 = collar_theta0()
    span = (180.0 - 2 * t0) / n
    key = n // 2
    for k in range(n):
        a = t0 + (k + 0.5) * span
        ar = math.radians(a)
        rot = a - 90.0
        t_out = max(collar_ray_out(t0 + k * span), collar_ray_out(t0 + (k + 1) * span))
        if k == key:
            continue
        rm = (r_in + r_mid) / 2
        w = 2 * r_mid * math.sin(math.radians(span / 2)) * 1.02
        cx_, cy_ = rm * math.cos(ar), cy + rm * math.sin(ar)
        parts.append(P("B", cx_, cy_, 0, w, r_mid - r_in, depth, 0, 0, rot, CREAM_L if k % 2 == 0 else CREAM,
                       "Sandstone", nc=True))
        parts.append(P("B", cx_, cy_, zf - 0.2, w * 0.62, (r_mid - r_in) * 0.56, 0.4, 0, 0, rot, COLLAR_INSET,
                       "Sandstone", nc=True))
        parts.append(P("B", cx_, cy_, zf - 0.5, 1.3, 1.3, 0.3, 0, 0, rot + 45.0, CREAM_L, "Sandstone", nc=True))
        # archivolt band out to the silhouette circle, its chevron relief, and the drip mould on its outer edge
        bm = (r_mid - 0.3 + t_out) / 2
        bw = 2 * t_out * math.sin(math.radians(span / 2)) * 1.03
        bx_, by_ = bm * math.cos(ar), cy + bm * math.sin(ar)
        parts.append(P("B", bx_, by_, 0.25, bw, t_out - r_mid + 0.3, depth - 0.5, 0, 0, rot, COLLAR_BAND, "Sandstone",
                       nc=True))
        for t in (-1, 1):
            parts.append(P("B", bx_ + t * 0.9 * math.cos(ar - math.pi / 2), by_ + t * 0.9 * math.sin(ar - math.pi / 2),
                           zf + 0.05, 0.7, min(4.2, (t_out - r_mid) * 0.6), 0.3, 0, 0, rot + t * 38.0, COLLAR_INSET,
                           "Sandstone", nc=True))
        dm = t_out + 0.45
        parts.append(P("B", dm * math.cos(ar), cy + dm * math.sin(ar), -0.3, 2 * dm * math.sin(math.radians(span / 2)) * 1.03,
                       0.9, depth + 0.6, 0, 0, rot, COLLAR_DRIP, "Sandstone", nc=True))
    # stepped keystone: lower block in the ring, wider upper block through the band; the kept Neon gem (y 68, z -7.8)
    # shows on the lower block's face as the jewel of the carved crown
    crown_in = cy + r_in
    crown_mid = cy + r_mid
    crown_out = cy + collar_ray_out(90.0) + 0.9
    parts.append(P("B", 0, (crown_in + crown_mid) / 2, 0, 8.0, crown_mid - crown_in, depth, col=CREAM_L, mat="Sandstone",
                   nc=True))
    parts.append(P("B", 0, (crown_mid + crown_out) / 2, -0.25, 11.0, crown_out - crown_mid, depth + 0.5, col=CREAM,
                   mat="Sandstone", nc=True))
    parts.append(P("B", 0, crown_out + 0.4, -0.3, 12.6, 0.8, depth + 0.6, col=COLLAR_DRIP, mat="Sandstone", nc=True))
    ep = crown_mid + 7.0
    parts.append(P("B", 0, ep, zf - 0.8, 8.0, 9.0, 0.4, col=CREAM_L, mat="Sandstone", nc=True))
    parts.append(P("B", 0, ep - 2.4, zf - 1.15, 6.0, 1.0, 0.4, col=GOLD, mat="Metal", nc=True))
    for x, dy in ((-2.2, 0.0), (0.0, 0.8), (2.2, 0.0)):
        parts.append(P("B", x, ep - 0.6 + dy, zf - 1.15, 1.6, 1.6, 0.4, 0, 0, 45, GOLD, "Metal", nc=True))
    parts.append(P("S", 0, ep + 2.6, zf - 1.1, 1.4, 1.4, 0.6, col=CREAM_L, mat="Sandstone", nc=True))
    # hanging lantern under the crown: warm bounce light on the collar's reveal (ART_BAR light hierarchy)
    parts += [P("B", 0, crown_in - 2.6, -4.0, 0.3, 4.4, 0.3, col=IRON, mat="Metal", nc=True),
              P("B", 0, crown_in - 5.6, -4.0, 2.0, 2.4, 2.0, 0, 45, 0, IRON, "Metal", nc=True, a=0.35),
              P("B", 0, crown_in - 5.6, -4.0, 1.3, 1.7, 1.3, 0, 45, 0, "#ffe2a0", "Neon", nc=True,
                light=[34, 0.8, "#ffc98a", False]),
              P("W", 0, crown_in - 4.1, -4.0, 2.2, 0.8, 2.2, 0, 0, 0, IRON, "Metal", nc=True)]
    return {"parts": parts}


# -------------------------------------------------------------------------------------------------------- sky PNGs
def write_sky() -> list[str]:
    """Procedural sky faces (512x512): side = sky over a sea horizon at mid height (tiles horizontally, used on all
    four sides), up = zenith, down = deep sea. Clear: Sunshine cobalt-to-pale gradient, soft flat-bottomed cumulus
    puffs along the horizon band. Storm (HUB-BOSS-1): indigo overcast billows with a lavender horizon glow."""
    from PIL import Image, ImageFilter

    N = 512

    def fbm(w, h, period, seed, octaves=5, stretch=1.0):
        """Periodic value-noise fbm in [0, 1] (period cells across the width; rows stretched by `stretch`)."""
        rng = np.random.default_rng(seed)
        out = np.zeros((h, w))
        amp, tot = 1.0, 0.0
        for o in range(octaves):
            cx = period * (2 ** o)
            cy = max(1, int(round(cx / stretch)))
            lat = rng.uniform(0, 1, (cy + 1, cx + 1))
            lat[:, -1] = lat[:, 0]
            lat[-1, :] = lat[0, :]
            ys = np.linspace(0, cy, h, endpoint=False)
            xs = np.linspace(0, cx, w, endpoint=False)
            yi, xi = np.floor(ys).astype(int), np.floor(xs).astype(int)
            fy, fx = smooth(ys - yi)[:, None], smooth(xs - xi)[None, :]
            a = lat[yi][:, xi]
            b = lat[yi][:, xi + 1]
            c = lat[yi + 1][:, xi]
            d = lat[yi + 1][:, xi + 1]
            top = a + (b - a) * fx
            out += amp * (top + ((c + (d - c) * fx) - top) * fy)
            tot += amp
            amp *= 0.5
        return out / tot

    def hexc(c):
        return np.array([int(c[i:i + 2], 16) for i in (1, 3, 5)], float)

    def grad(stops, t):
        t = np.clip(t, 0, 1)
        xs = [q for q, _ in stops]
        cols = np.stack([hexc(c) for _, c in stops])
        return np.stack([np.interp(t, xs, cols[:, k]) for k in range(3)], axis=-1)

    def save(arr, path, blur=0.7):
        img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").filter(ImageFilter.GaussianBlur(blur))
        path.parent.mkdir(parents=True, exist_ok=True)
        img.save(path, optimize=False)

    yy, xx = np.mgrid[0:N, 0:N].astype(float)
    v, u = yy / (N - 1.0), xx / (N - 1.0)

    def puffs(seed, count, y_lo, y_hi, size_lo, size_hi, base_soft=0.012):
        """Cumulus clusters: overlapping soft discs with a flat soft base; wraps horizontally. Returns (alpha, shade)."""
        rng = np.random.default_rng(seed)
        alpha = np.zeros((N, N))
        shade = np.zeros((N, N))
        for _ in range(count):
            cx, base = rng.uniform(0, 1), rng.uniform(y_lo, y_hi)
            size = rng.uniform(size_lo, size_hi)
            for _k in range(int(rng.integers(5, 10))):
                ox = rng.normal(0, size * 0.9)
                r = size * rng.uniform(0.45, 0.9)
                oy = -r * rng.uniform(0.2, 0.75)
                for wrap in (-1.0, 0.0, 1.0):
                    d = np.hypot((u - (cx + ox + wrap)) / 1.0, (v - (base + oy)) * 1.6)
                    disc = 1 - smooth((d - r * 0.82) / (r * 0.3))
                    disc = disc * (1 - smooth((v - base) / base_soft))  # flat underside
                    alpha = np.maximum(alpha, disc)
                    shade = np.maximum(shade, disc * smooth(((base + oy) - v) / (r * 1.4) + 0.5))
        return alpha, shade

    written = []
    # ---- clear
    base = SKY_OUT
    side = grad([(0.0, "#3a82e2"), (0.30, "#5c9fec"), (0.44, "#a9d8f8"), (0.497, "#e8f7ff"), (0.502, "#a8e6f2"),
                 (0.56, "#4cc4d6"), (0.75, "#2a9ec0"), (1.0, "#1a7aa4")], v)
    a_c, s_c = puffs(SEED + 11, 9, 0.38, 0.47, 0.035, 0.07)
    a_f, s_f = puffs(SEED + 12, 5, 0.22, 0.32, 0.05, 0.09)
    for a_, s_ in ((a_f, s_f), (a_c, s_c)):
        col = hexc("#cfe0f2")[None, None, :] * (1 - s_[..., None]) + hexc("#ffffff")[None, None, :] * s_[..., None]
        side = side * (1 - a_[..., None] * 0.95) + col * (a_[..., None] * 0.95)
    sea = v > 0.502
    side = side + (sea * (fbm(N, N, 6, SEED + 13, 4, stretch=0.2) - 0.5) * 18.0)[..., None]
    save(side, base / "side.png")
    r = np.clip(np.hypot(u - 0.5, v - 0.5) / 0.7071, 0, 1)
    up = grad([(0.0, "#2a6cd6"), (1.0, "#3a82e2")], r)
    n = fbm(N, N, 4, SEED + 14, 5)
    cl = smooth((n - 0.6) / 0.16) * 0.8
    up = up * (1 - cl[..., None]) + hexc("#f4f9ff") * cl[..., None]
    save(up, base / "up.png")
    down = grad([(0.0, "#1a7aa4"), (1.0, "#156c94")], fbm(N, N, 8, SEED + 15, 3))
    save(down, base / "down.png")
    written += [str((base / f).relative_to(ROOT)) for f in ("up.png", "side.png", "down.png")]

    # ---- storm
    base = SKY_OUT / "storm"
    side = grad([(0.0, "#1e1a38"), (0.30, "#2c2552"), (0.45, "#4a3f7a"), (0.495, "#8a78b8"), (0.502, "#3c6474"),
                 (0.58, "#28505e"), (0.8, "#1c3c48"), (1.0, "#152e38")], v)
    bil = fbm(N, N, 4, SEED + 21, 5, stretch=0.45)
    sky_part = (v < 0.497)[..., None]
    lum = (bil - 0.5)[..., None] * 110.0 * (1 - smooth((v - 0.40) / 0.10))[..., None]
    side = np.where(sky_part, side + lum * np.array([0.8, 0.75, 1.0]), side)
    side = side + ((v > 0.502) * (fbm(N, N, 6, SEED + 22, 4, stretch=0.2) - 0.5) * 16.0)[..., None]
    save(side, base / "side.png")
    up = grad([(0.0, "#17142c"), (1.0, "#1e1a38")], r)
    up = up + ((fbm(N, N, 4, SEED + 23, 5) - 0.5) * 100.0)[..., None] * np.array([0.8, 0.75, 1.0])
    save(up, base / "up.png")
    down = grad([(0.0, "#152e38"), (1.0, "#10242c")], fbm(N, N, 8, SEED + 24, 3))
    save(down, base / "down.png")
    written += [str((base / f).relative_to(ROOT)) for f in ("up.png", "side.png", "down.png")]
    return written


# ---------------------------------------------------------------------------------------------------------- build
def build() -> tuple[dict, dict]:
    rt = route_block()
    tr = Track(rt)
    length = tr.length
    rows, _ = route_geometry.analyse([list(w.pos) for w in tr.route.waypoints], min_radius=rt["minRadius"])
    min_r = min(rows, key=lambda r: r["r"])
    max_grade = max(abs(r["grade"]) for r in rows)

    alt_pts = alt_cove_points(tr)
    terrain = Terrain(tr, alt_pts)

    prefabs: dict[str, dict] = {}
    instances: list[dict] = []
    groups = ["Landmarks", "Landmarks/Portals", "Plaza", "Town", "Harbor", "Beach", "Foliage", "Route", "Finds"]

    def g(name: str) -> int:
        return groups.index(name) + 1

    def place(pf: str, lx: float, y: float, lz: float, group: str, yaw: float | list = 0.0, scale: float = 1.0):
        inst = {"pf": pf, "p": to_world(lx, y, lz), "g": g(group), "r": yaw if isinstance(yaw, list) else r4(yaw)}
        if scale != 1.0:
            inst["s"] = r4(scale)
        instances.append(inst)

    # ---- houses: positions first, then terrace pads into the terrain, then placement on the final ground
    house_specs = []  # (prefab, lx, lz, yaw, w, d, group, scale)
    kinds = [("TownHouse_A", 34, 24), ("TownHouse_B", 24, 24), ("TownHouse_C", 46, 22)]
    shutter_cycle = 0

    def house_prefab(kind: str) -> str:
        nonlocal shutter_cycle
        si = shutter_cycle % len(SHUTTERS)
        shutter = SHUTTERS[si]
        shutter_cycle += 1
        key = f"{kind}#{shutter[1:]}"
        if key not in prefabs:
            wall = WALLS[(si + {"TownHouse_A": 0, "TownHouse_B": 1, "TownHouse_C": 2}[kind]) % len(WALLS)]
            prefabs[key] = {"TownHouse_A": townhouse_a, "TownHouse_B": townhouse_b,
                            "TownHouse_C": townhouse_c}[kind](shutter, wall)
        return key

    # promenade front row (right of the start straight), facing the road
    front_row = [(26, 0), (82, 1), (130, 2), (190, 0), (238, 1), (312, 0), (360, 2), (410, 1)]
    for st, k in front_row:
        kind, w, d = kinds[k]
        lat = SHOULDER + d / 2 - 1.0
        x, _, z = tr.local(st, lat)
        rx, rz = tr.frame(st).right[0], tr.frame(st).right[2]
        house_specs.append((kind, x, z, yaw_facing(-rx, -rz), w, d, "Town", 1.0))
    # second row and upper town, facing west toward the sea
    for st, k, lat in ((40, 2, 96.0), (100, 0, 92.0), (238, 2, 98.0), (322, 1, 90.0), (112, 1, 150.0), (276, 0, 152.0)):
        kind, w, d = kinds[k]
        x, _, z = tr.local(st, lat)
        house_specs.append((kind, x, z, yaw_facing(-1.0, 0.0), w, d, "Town", 1.0))
    for (x, z, k, fx, fz) in ((-352.0, -48.0, 0, -1.0, 0.0), (-356.0, 66.0, 1, -1.0, 0.2), (-318.0, 150.0, 2, -0.6, -0.8)):
        kind, w, d = kinds[k]
        house_specs.append((kind, x, z, yaw_facing(fx, fz), w, d, "Town", 1.0))
    # harbour quarter on the lagoon's west shore, facing the lagoon; islet cottages facing the causeway
    for (x, z, k) in ((322.0, -70.0, 0), (318.0, 30.0, 1), (326.0, 128.0, 2)):
        kind, w, d = kinds[k]
        house_specs.append((kind, x, z, yaw_facing(1.0, 0.0), w, d, "Harbor", 1.0))
    for (x, z, k, s) in ((684.0, -6.0, 0, 0.85), (700.0, 44.0, 1, 0.85)):
        kind, w, d = kinds[k]
        house_specs.append((kind, x, z, yaw_facing(-1.0, 0.0), w * s, d * s, "Harbor", s))

    for kind, x, z, yaw, w, d, grp, s in house_specs:
        level = max(terrain.ground(x + cx, z + cz) for cx in (-w / 2, w / 2) for cz in (-d / 2, d / 2))
        level = max(level, terrain.ground(x, z))
        terrain.flatten(x, z, yaw, w, d, level)
    for kind, x, z, yaw, w, d, grp, s in house_specs:
        place(house_prefab(kind), x, terrain.ground(x, z) - 0.2, z, grp, yaw, s)
    # L61: a yard set (barrels, crate, laundry line) beside the back corner of every house
    for k in range(3):
        prefabs[f"BackYard#{k + 1}"] = back_yard(SEED + 140 + k)
    for i, (kind, x, z, yaw, w, d, grp, s) in enumerate(house_specs):
        ox, oz = (-1 if i % 2 else 1) * (w / 2 - 6.0), d / 2 + 7.0
        th = math.radians(yaw)
        yx, yz = x + ox * math.cos(th) + oz * math.sin(th), z - ox * math.sin(th) + oz * math.cos(th)
        place(f"BackYard#{i % 3 + 1}", yx, terrain.ground(yx, yz) - 0.1, yz, grp, yaw)

    # ---- plaza: fountain, portals, lamps, balustrade, spawn
    prefabs["PlazaFountain"] = plaza_fountain()
    place("PlazaFountain", PLAZA_C[0], PLAZA_H - 0.3, PLAZA_C[1], "Plaza")
    portals = []
    for zone, bearing, threshold in PORTALS:
        key = f"PortalArch_{zone}"
        prefabs[key] = portal_arch(zone)
        b = math.radians(bearing)
        ox, oz = math.sin(b), -math.cos(b)  # outward from the plaza centre
        x, z = PLAZA_C[0] + 118.0 * ox, PLAZA_C[1] + 118.0 * oz
        place(key, x, PLAZA_H - 0.2, z, "Landmarks/Portals", yaw_facing(-ox, -oz))
        portals.append({"zone": zone, "track": PORTAL_TRACKS[zone], "threshold": threshold, "prefab": key,
                        "cf": cf_look(to_world(x, PLAZA_H + 11.0, z), (ox, oz)),
                        "size": [24, 30, 6]})
    prefabs["PlazaLamp"] = plaza_lamp()
    for k in range(10):
        a = math.radians(k * 36 + 18)
        place("PlazaLamp", PLAZA_C[0] + 96 * math.sin(a), PLAZA_H - 0.2, PLAZA_C[1] - 96 * math.cos(a), "Plaza")
    seg_len = 18.0
    key = "PlazaBalustrade"
    prefabs[key] = balustrade(seg_len)
    for k in range(40):
        bearing = 102.0 + k * 7.0  # south half of the rim, from east-south-east round to west-south-west
        if bearing > 258.0:
            break
        if abs(bearing - 180.0) < 9.0 or abs(bearing - 246.0) < 9.0 or abs(bearing - 114.0) < 9.0:
            continue  # openings: south path, west path to the town, east path
        b = math.radians(bearing)
        x, z = PLAZA_C[0] + (PLAZA_R - 6) * math.sin(b), PLAZA_C[1] - (PLAZA_R - 6) * math.cos(b)
        place(key, x, terrain.ground(x, z) - 0.3, z, "Plaza", yaw_facing(math.sin(b), -math.cos(b)))
    # L61 dressing: bunting strung lamp to lamp round the plaza, market stalls on the south rim, flowering planters
    # between the lamps and cypress pairs framing each portal arch (all clear of the spawn lanes, test H0-08)
    chord = 2 * 96.0 * math.sin(math.radians(18.0))
    for k in range(10):
        key = f"PlazaBunting#{k % 2 + 1}"
        if key not in prefabs:
            prefabs[key] = bunting(chord - 3.0, sag=3.2, count=7, seed=k % 2 * 3)
        a0, a1 = math.radians(k * 36 + 18), math.radians(k * 36 + 54)
        p0 = (PLAZA_C[0] + 96 * math.sin(a0), PLAZA_C[1] - 96 * math.cos(a0))
        p1 = (PLAZA_C[0] + 96 * math.sin(a1), PLAZA_C[1] - 96 * math.cos(a1))
        place(key, (p0[0] + p1[0]) / 2, PLAZA_H + 13.2, (p0[1] + p1[1]) / 2, "Plaza",
              yaw_facing(p1[0] - p0[0], p1[1] - p0[1]))
    for k, bearing in enumerate((140.0, 158.0, 202.0, 222.0)):
        key = f"MarketStall#{k % 2 + 1}"
        if key not in prefabs:
            prefabs[key] = market_stall(k % 2 + 1)
        b = math.radians(bearing)
        ox, oz = math.sin(b), -math.cos(b)
        place(key, PLAZA_C[0] + 127.0 * ox, PLAZA_H - 0.2, PLAZA_C[1] + 127.0 * oz, "Plaza", yaw_facing(-ox, -oz))
    for k, bearing in enumerate((198.0, 234.0, 270.0, 306.0, 342.0, 18.0, 54.0)):
        key = f"PlazaPlanter#{k % 3 + 1}"
        if key not in prefabs:
            prefabs[key] = plaza_planter(k % 3)
        b = math.radians(bearing)
        place(key, PLAZA_C[0] + 106.0 * math.sin(b), PLAZA_H - 0.2, PLAZA_C[1] - 106.0 * math.cos(b), "Plaza")
    for k in range(2):
        prefabs[f"CypressTree#{k + 1}"] = cypress_tree(SEED + 120 + k)
    for i, (zone, bearing, _) in enumerate(PORTALS):
        b = math.radians(bearing)
        ox, oz = math.sin(b), -math.cos(b)
        for side in (-1, 1):
            x = PLAZA_C[0] + 136.0 * ox + side * 30.0 * -oz
            z = PLAZA_C[1] + 136.0 * oz + side * 30.0 * ox
            place(f"CypressTree#{(i + side) % 2 + 1}", x, terrain.ground(x, z) - 0.4, z, "Foliage",
                  float((i * 53 + side * 31) % 360), 1.0 + 0.08 * ((i + side) % 3))
    # v28 1.18 perimeter: harbour-town dressing on the south rim (r 134-140), clear of the spawn lanes (the east path
    # lane ends at bearing ~106 and the spawn grid reaches bearing ~125, the town and south paths open at 246 and 180), the stalls (127) and the balustrade (144)
    for k in range(3):
        prefabs[f"HarbourCrates#{k + 1}"] = harbour_crates(SEED + 140 + k)
    prefabs["QuayBollards"] = quay_bollards(14.0)
    prefabs["HarbourLamp"] = harbour_lamp()
    for k in range(2):
        prefabs[f"AwningLean#{k + 1}"] = awning_lean(k)
    for k, bearing in enumerate((150.0, 206.0, 232.0)):
        b = math.radians(bearing)
        ox, oz = math.sin(b), -math.cos(b)
        place(f"HarbourCrates#{k % 3 + 1}", PLAZA_C[0] + 138.0 * ox, PLAZA_H - 0.2, PLAZA_C[1] + 138.0 * oz, "Plaza",
              yaw_facing(-ox, -oz) + 20.0 * k)
    for bearing in (141.0, 170.0, 190.0, 221.0):
        b = math.radians(bearing)
        ox, oz = math.sin(b), -math.cos(b)
        place("HarbourLamp", PLAZA_C[0] + 139.0 * ox, PLAZA_H - 0.2, PLAZA_C[1] + 139.0 * oz, "Plaza",
              yaw_facing(-oz, ox))
    for bearing in (157.0, 203.0):  # rope lines between the crate groups, parallel to the rim
        b = math.radians(bearing)
        ox, oz = math.sin(b), -math.cos(b)
        place("QuayBollards", PLAZA_C[0] + 139.0 * ox, PLAZA_H - 0.2, PLAZA_C[1] + 139.0 * oz, "Plaza",
              yaw_facing(-oz, ox) + 90.0)
    for k, bearing in enumerate((163.0, 197.0)):
        b = math.radians(bearing)
        ox, oz = math.sin(b), -math.cos(b)
        place(f"AwningLean#{k + 1}", PLAZA_C[0] + 138.0 * ox, PLAZA_H - 0.2, PLAZA_C[1] + 138.0 * oz, "Plaza",
              yaw_facing(-ox, -oz))
    # Facing along the open south plaza, not at the fountain (trap audit H0-08: the basin wall stood 45 studs straight
    # ahead of slots 2-3, the first touch auto-throttle input hit it); the portal arc stays in view on the left.
    spawn = {"cf": cf_look(to_world(PLAZA_C[0] + SPAWN[0], PLAZA_H + 3.0, PLAZA_C[1] + SPAWN[1]), SPAWN_LOOK),
             "note": "south of the fountain, facing along the open plaza with the portal arc on the left"}

    # ---- route landmarks: gantry, start line, tunnel arches, bridges, promenade lamps
    prefabs["StartFinishGantry"] = start_gantry()
    prefabs["StartLine"] = start_line()
    start_d = tr.shift  # design station of the start/finish line
    f0 = tr.frame(start_d)
    hx, hz = tr.heading(start_d)
    p0 = f0.offset(0, DECK_TOP)
    place("StartFinishGantry", p0[0] - ORIGIN[0], p0[1], p0[2] - ORIGIN[2], "Route", yaw_facing(hx, hz))
    p1 = f0.offset(0, 2.75)
    place("StartLine", p1[0] - ORIGIN[0], p1[1], p1[2] - ORIGIN[2], "Route", yaw_facing(hx, hz))

    prefabs["CliffTunnelArch"] = cliff_tunnel_arch()
    for st, outward in ((TUNNEL[0] - 4.0, -1.0), (TUNNEL[1] + 4.0, 1.0)):
        hx, hz = tr.heading(st)
        p = tr.frame(st).offset(0, DECK_TOP)
        place("CliffTunnelArch", p[0] - ORIGIN[0], p[1], p[2] - ORIGIN[2], "Landmarks",
              yaw_facing(hx * outward, hz * outward))
    # v29 Wave 2: the carved voussoir collar over both mouths, same frame as the arch (the arch's runtime swap keeps only
    # the stone_arch_v3 colliders, ArtSwapRules collidersOnly, so collision at the mouths is exactly as before)
    prefabs["CliffTunnelCollar"] = cliff_tunnel_collar()
    for st, outward in ((TUNNEL[0] - 4.0, -1.0), (TUNNEL[1] + 4.0, 1.0)):
        hx, hz = tr.heading(st)
        p = tr.frame(st).offset(0, DECK_TOP)
        place("CliffTunnelCollar", p[0] - ORIGIN[0], p[1], p[2] - ORIGIN[2], "Landmarks",
              yaw_facing(hx * outward, hz * outward))

    # deck gaps and bridges: the deck kit skips segments whose START station lies in [from, to]
    bridges = bridge_spans(tr)
    for br in bridges:
        pa, pb = tr.frame(br["dDeckEnd"]).pos, tr.frame(br["dDeckResume"]).pos
        p = [(pa[k] + pb[k]) / 2 for k in range(3)]
        br["length"] = round(math.dist(pa, pb) + 4.0, 1)
        br["pos"] = [r4(p[0]), r4(p[1] + DRIVE_TOP - 0.1), r4(p[2])]
        # pitch along the chord so both log ends meet the deck (positive rx raises the forward, local -Z, end)
        br["pitch"] = r4(math.degrees(math.atan2(pb[1] - pa[1], math.hypot(pb[0] - pa[0], pb[2] - pa[2]))))
    for br in bridges:  # one prefab per span length; both clones are named RiskyLogBridge
        key = f"RiskyLogBridge#{br['name'].split('_')[-1]}"
        prefabs[key] = risky_log_bridge(br["length"])
        br["prefab"] = key
        pa, pb = tr.frame(br["dDeckEnd"]).pos, tr.frame(br["dDeckResume"]).pos
        hx, hz = pb[0] - pa[0], pb[2] - pa[2]
        place(key, br["pos"][0] - ORIGIN[0], br["pos"][1], br["pos"][2] - ORIGIN[2], "Route",
              [br["pitch"], yaw_facing(hx, hz), 0.0])

    prefabs["PromenadeLamp"] = promenade_lamp()
    for st in range(20, 520, 60):
        x, _, z = tr.local(st, -29.0)
        rx, rz = tr.frame(st).right[0], tr.frame(st).right[2]
        place("PromenadeLamp", x, terrain.ground(x, z) - 0.4, z, "Route", yaw_facing(rx, rz))

    # v28 1.8: six standing lanterns on the tunnel shoulders (alternating sides, outside the 22-stud road corridor),
    # non-colliding, each with a warm PointLight (tagged as a map light by the builder, so LightLod caps them)
    prefabs["TunnelLantern"] = tunnel_lantern()
    for k in range(6):
        st = TUNNEL[0] + 30.0 + k * 36.0
        side = -1.0 if k % 2 == 0 else 1.0
        x, y, z = tr.local(st, 31.0 * side)
        rx, rz = tr.frame(st).right[0], tr.frame(st).right[2]
        place("TunnelLantern", x, y + 0.6, z, "Route", yaw_facing(rx * side, rz * side))
    # L61 route dressing: seaward banner poles (edge language and flags) and festival bunting across the road
    pole_cols = [BUNTING[0], BUNTING[1], BUNTING[2], BUNTING[4], BUNTING[5]]
    for k, c in enumerate(pole_cols):
        prefabs[f"BannerPole#{k + 1}"] = banner_pole(c)
    skip = [(TUNNEL[0] - 20, TUNNEL[1] + 20), (BRIDGES[0][0] - 30, BRIDGES[1][1] + 30), (250.0, 310.0)]
    n_pole = 0
    for d in range(10, 3590, 75):
        if any(a <= d <= b for a, b in skip):
            continue
        x, _, z = tr.local(float(d), -31.0)
        g_ = terrain.ground(x, z)
        if g_ < 0.5:
            continue
        # local +X (the flag side) toward the road: yaw so the prefab's -Z faces along the route
        hx, hz = tr.heading(float(d))
        place(f"BannerPole#{n_pole % 5 + 1}", x, g_ - 0.3, z, "Route", yaw_facing(hx, hz))
        n_pole += 1
    prefabs["StreetBunting#1"] = street_bunting(64.0, 24.0, 0)
    prefabs["StreetBunting#2"] = street_bunting(64.0, 24.0, 3)
    for k, d in enumerate((150.0, 410.0, 650.0, 720.0, 790.0, 1050.0, 1400.0, 2090.0, 2950.0, 3150.0, 3470.0)):
        f_ = tr.frame(d)
        p_ = f_.offset(0, DECK_TOP)
        place(f"StreetBunting#{k % 2 + 1}", p_[0] - ORIGIN[0], p_[1], p_[2] - ORIGIN[2], "Route",
              yaw_facing(f_.right[0], f_.right[2]))

    # ---- exchange bays and pads (front faces the start straight, south-east)
    ex_x, ex_z = EXCHANGE
    level = 6.0
    terrain.flatten(ex_x, ex_z, yaw_facing(0.25, 1.0), 106.0, 44.0, level, margin=4.0, ring=10.0)
    # One forecourt terrace under both pads: two separate 32-wide pads left a 4.8-deep V ditch between them (found
    # with the trap audit fixes; the hub respawn anchor ExchangeForecourt sits there)
    terrain.flatten(ex_x, ex_z + 46.0, 0.0, 92.0, 32.0, level, margin=2.0, ring=10.0)
    prefabs["VehicleExchangeBays"] = exchange_bays()
    place("VehicleExchangeBays", ex_x, level, ex_z, "Landmarks", yaw_facing(0.25, 1.0))
    exchange = []
    for vehicle, dx, col in (("plane", -30.0, "#7cc7f0"), ("car", 30.0, "#e07a4a")):
        key = f"ExchangePad_{vehicle.capitalize()}"
        prefabs[key] = exchange_pad(col)
        x, z = ex_x + dx, ex_z + 46.0
        place(key, x, level, z, "Landmarks", 0.0)
        exchange.append({"vehicle": vehicle, "prefab": key, "radius": 14,
                         "cf": cf_look(to_world(x, level + 1.2, z), (0.25, 1.0))})

    # ---- docks, palms, cargo on the west beach
    prefabs["TimberDock_Long"] = timber_dock(110.0)
    prefabs["TimberDock_Short"] = timber_dock(60.0)
    docks = []
    dock_station = {}
    for st, key in ((345.0, "TimberDock_Long"), (120.0, "TimberDock_Short")):
        x, _, z = tr.local(st, -112.0)
        rx, rz = tr.frame(st).right[0], tr.frame(st).right[2]
        place(key, x, 0.0, z, "Beach", yaw_facing(-rx, -rz))
        docks.append((key, x, z, -rx, -rz))
        dock_station[key] = st
    long_dock = docks[0]
    dock_end = (long_dock[1] + long_dock[3] * 114.0, long_dock[2] + long_dock[4] * 114.0)
    dock_len = {"TimberDock_Long": 110.0, "TimberDock_Short": 60.0}
    sh = DOCK_SHOAL
    for key, x, z, dx, dz in docks:  # a shoal under and past each dock (seaward of the root only: rise never lowers)
        far = dock_len[key] + 8.0 + sh["beyond"]
        terrain.shoal((x + dx * 4.0, z + dz * 4.0), (x + dx * far, z + dz * far), sh["level"], sh["radius"], sh["blend"])

    # L61 waterfront life: moored boats beside the docks, in the lagoon and the cove; a buoy line offshore
    boat_cols = [("#c9452a", "#f6eedc"), ("#2f8f8a", "#f2dc9c"), ("#3a78b0", "#f6eedc"), ("#e0a838", "#e9b8a0")]
    for k, (h_, s_) in enumerate(boat_cols):
        prefabs[f"MooredBoat#{k + 1}"] = moored_boat(h_, s_)
    boat_sites = []
    for key, x, z, dx, dz in docks:
        L_ = dock_len[key]
        for along, side in ((L_ * 0.55, 1), (L_ * 0.85, -1)):
            boat_sites.append((x + dx * along - dz * side * 17.0, z + dz * along + dx * side * 17.0, dx, dz))
    boat_sites += [(LAGOON[0][0] - 10.0, LAGOON[0][1] - 60.0, 0.3, 1.0), (LAGOON[0][0] + 20.0, LAGOON[0][1] + 70.0, -0.4, 1.0),
                   (COVE[0][0] + 10.0, COVE[0][1] + 55.0, 1.0, 0.2)]
    for i, (x, z, dx, dz) in enumerate(boat_sites):
        place(f"MooredBoat#{i % 4 + 1}", x, 0.0, z, "Harbor", yaw_facing(dx, dz) + (i * 17) % 30 - 15)
    prefabs["Buoy#1"], prefabs["Buoy#2"] = buoy("#d8483a"), buoy("#f2ead8")
    for k, d in enumerate(range(40, 520, 80)):
        x, _, z = tr.local(float(d), -190.0)
        if terrain.ground(x, z) < -1.0:
            place(f"Buoy#{k % 2 + 1}", x, -0.3, z, "Harbor", float(k * 37 % 360))

    # ---- v29 Wave 2 (critic 3.1): harbour frontage along the west beach's waterline, guide 04_HUB0 (a cream stone quay
    # over the cyan shallows, timber piers with bollards and rope, a moored hovercraft and a moored plane, crates, nets
    # and lamp posts along the quay). Dressing only, all non-colliding: the terrain grid, the shells, the docks (H0-03)
    # and every collidable part are unchanged; nothing is built into the cliffs (the quay ends short of the exchange
    # forecourt at the west bluff's foot).
    Q = QUAY

    def shore_point(st: float) -> tuple[float, float]:
        lat = -60.0
        while terrain.ground(*tr.local(st, lat)[0::2]) > Q["shoreLevel"]:
            lat -= 0.5
        x, _, z = tr.local(st, lat - Q["faceInset"])
        return x, z

    sec = Q["section"]
    spans = []  # (from, to, apron): one apron-less section centred on each dock, even runs between
    a_ = Q["from"]
    for c_ in sorted(dock_station.values()):
        spans += [(a_, c_ - sec / 2, True), (c_ - sec / 2, c_ + sec / 2, False)]
        a_ = c_ + sec / 2
    spans.append((a_, Q["to"], True))
    quay_secs = []  # (s0, s1, apron, (x0, z0), (x1, z1))
    for s0, s1, ap in spans:
        n_ = max(1, round((s1 - s0) / sec))
        for i in range(n_):
            u0, u1 = s0 + (s1 - s0) * i / n_, s0 + (s1 - s0) * (i + 1) / n_
            quay_secs.append((u0, u1, ap, shore_point(u0), shore_point(u1)))
    quay_frames = []  # (s0, s1, apron, centre x, z, along (cx, cz), seaward (fx, fz), yaw)
    n_bollard = 0
    for i, (u0, u1, ap, p0_, p1_) in enumerate(quay_secs):
        cx, cz = p1_[0] - p0_[0], p1_[1] - p0_[1]
        ln = math.hypot(cx, cz)
        cx, cz = cx / ln, cz / ln
        fx, fz = cz, -cx  # seaward: the chord turned left (the sea is on the left of the promenade)
        bol = ap and n_bollard % 2 == 0
        n_bollard += 1 if ap else 0
        L_ = round(ln * 2) / 2
        key = f"QuaySection#{L_:.1f}{'a' if ap else 'd'}{'b' if bol else ''}"
        if key not in prefabs:
            prefabs[key] = quay_section(L_ + 0.2, SEED + 300 + len(prefabs), bollard=bol, apron=ap)
        mx, mz = (p0_[0] + p1_[0]) / 2, (p0_[1] + p1_[1]) / 2
        yaw = yaw_facing(fx, fz)
        place(key, mx, 0.0, mz, "Harbor", yaw)
        quay_frames.append((u0, u1, ap, mx, mz, (cx, cz), (fx, fz), yaw))
    prefabs["QuayEnd#N"], prefabs["QuayEnd#S"] = quay_end(1.0), quay_end(-1.0)
    first, last = quay_frames[0], quay_frames[-1]
    place("QuayEnd#S", quay_secs[0][3][0], 0.0, quay_secs[0][3][1], "Harbor", first[7])
    place("QuayEnd#N", quay_secs[-1][4][0], 0.0, quay_secs[-1][4][1], "Harbor", last[7])

    def on_apron(st: float) -> tuple[float, float, float]:
        """(x, z, yaw) on the apron's centre line at design station st (must be an apron section)."""
        fr_ = next(f for f in quay_frames if f[0] <= st <= f[1])
        assert fr_[2], f"station {st} is on a dock section (no apron)"
        x0, z0 = shore_point(st)
        back = Q["depth"] + 0.6 + Q["apron"] / 2
        return x0 - fr_[6][0] * back, z0 - fr_[6][1] * back, fr_[7]

    prefabs["QuayLamp#lit"], prefabs["QuayLamp#unlit"] = quay_lamp(True), quay_lamp(False)
    for st, lit in ((40.0, False), (190.0, True), (270.0, True), (400.0, True)):
        x, z, yaw = on_apron(st)
        place(f"QuayLamp#{'lit' if lit else 'unlit'}", x, 0.0, z, "Harbor", yaw)
    prefabs["QuayCrates#1"], prefabs["QuayCrates#2"] = quay_crates(1), quay_crates(2)
    prefabs["NetRack"] = net_rack()
    for st, key in ((70.0, "QuayCrates#1"), (160.0, "QuayCrates#2"), (230.0, "NetRack"), (300.0, "QuayCrates#1"),
                    (380.0, "NetRack")):
        x, z, yaw = on_apron(st)
        place(key, x, 0.0, z, "Harbor", yaw)

    # piers: bollards, rope swags, a lifebuoy board and the mooring lines; the moored hovercraft and plane are the
    # existing vehicle models (adapter meshes step, non-colliding), the plane on block-built floats
    harbour_meshes = []
    for kind, m in MOORED.items():
        key, x0, z0, dx, dz = next(dk for dk in docks if dk[0] == m["dock"])
        ox, oz = -dz, dx  # the dock prefab's local +X in world
        vx, vz = x0 + dx * m["along"] + ox * m["side"] * MOORED_LATERAL, z0 + dz * m["along"] + oz * m["side"] * MOORED_LATERAL
        pk = f"PierDressing_{key.split('_')[1]}"
        prefabs[pk] = pier_dressing(dock_len[key], (m["side"] * MOORED_LATERAL, -m["along"]), key == "TimberDock_Long", kind)
        place(pk, x0, 0.0, z0, "Harbor", yaw_facing(dx, dz))
        y = m["bottom"] + m["height"] / 2
        if kind == "plane":  # mesh nose on -X: -X along the dock (nose out to sea)
            cf = [r4(ORIGIN[0] + vx), r4(y), r4(ORIGIN[2] + vz), r4(-dx), 0.0, r4(dz), 0.0, 1.0, 0.0, r4(-dz), 0.0, r4(-dx)]
            prefabs["SeaplaneFloats"] = seaplane_floats()
            place("SeaplaneFloats", vx, 0.0, vz, "Harbor", yaw_facing(dx, dz))
        else:  # hull long on X: X along the dock
            cf = [r4(ORIGIN[0] + vx), r4(y), r4(ORIGIN[2] + vz), r4(dx), 0.0, r4(-dz), 0.0, 1.0, 0.0, r4(dz), 0.0, r4(dx)]
        mesh = {"name": f"Moored{kind.capitalize()}", "model": m["model"], "parent": f"Harbor/Moored{kind.capitalize()}",
                "cf": cf, "height": m["height"], "color": "#ffffff", "collide": False,
                "label": f"moored {kind} display (hub harbour, v29 Wave 2)"}
        if m.get("texture"):
            mesh["textureId"] = m["texture"]
        harbour_meshes.append(mesh)

    def off_dock_runup(x: float, z: float, clear: float = 14.0) -> tuple[float, float]:
        """Push a point that sits in a dock's shore run-up (on the axis, up to 90 studs inland of the root) sideways
        to `clear` from the axis, keeping its side (trap audit H0-03 b: a palm and a crate stack blocked the line)."""
        for _, rx_, rz_, dx, dz in docks:
            along = (x - rx_) * dx + (z - rz_) * dz  # negative = inland of the root
            perp = (x - rx_) * -dz + (z - rz_) * dx
            if -90.0 <= along <= 0.0 and abs(perp) < clear:
                side = 1.0 if perp >= 0 else -1.0
                x, z = rx_ + dx * along - dz * side * clear, rz_ + dz * along + dx * side * clear
        return x, z

    palm_keys = []
    for k in range(4):
        key = f"PalmTree#{k + 1}"
        prefabs[key] = palm_tree(lean=10.0 + 6.0 * k, seed=SEED + 40 + k)
        palm_keys.append(key)
    rng = np.random.default_rng(SEED + 99)
    palm_spots = []
    for st in (12, 60, 140, 178, 226, 262, 342, 380, 430, 3360, 3420, 3480, 3540):
        palm_spots.append(tr.local(st, -float(rng.uniform(46.0, 80.0))))
    for (x, z) in ((660.0, 50.0), (712.0, -14.0), (672.0, 70.0), (-125.0, 600.0), (-110.0, 636.0), (-6.0, 596.0),
                   (300.0, 165.0), (300.0, -120.0), (405.0, 470.0), (470.0, 420.0), (-600.0, -262.0), (-725.0, -282.0)):
        palm_spots.append((x, 0.0, z))
    palm_spots = [(p[0], 0.0, p[1]) for p in (off_dock_runup(x, z) for x, _, z in palm_spots)]
    for i, (x, _, z) in enumerate(palm_spots):
        place(palm_keys[i % 4], x, terrain.ground(x, z) - 0.6, z, "Foliage", float(rng.uniform(0, 360)),
              float(rng.uniform(0.85, 1.15)))

    for k in range(3):
        prefabs[f"CargoCrates#{k + 1}"] = cargo_stack(SEED + 60 + k)
    # the third stack sits beside the long dock's root, 22 south of its axis and clear of the run-up (it stood on the
    # axis 20 inland, trap audit H0-03 b); (dz, -dx) is the dock's left-hand (south) side
    crate_dock = (long_dock[1] - long_dock[3] * 10.0 + long_dock[4] * 22.0,
                  long_dock[2] - long_dock[4] * 10.0 - long_dock[3] * 22.0)
    for i, (x, z) in enumerate(((ex_x + 62.0, ex_z + 30.0), (330.0, 70.0), crate_dock)):
        place(f"CargoCrates#{i % 3 + 1}", x, terrain.ground(x, z) - 0.2, z, "Harbor", float(i * 47 % 360))

    # ---- lighthouse, cove shack, ledge cairn
    prefabs["HarborLighthouse"] = lighthouse()
    lhx, lhz = NE_HEADLAND[0][0] + 10.0, NE_HEADLAND[0][1] - 12.0
    place("HarborLighthouse", lhx, terrain.ground(lhx, lhz) - 0.5, lhz, "Landmarks", 30.0)
    prefabs["CoveShack"] = cove_shack()
    csx, csz = COVE[0][0] + 30.0, COVE[0][1] + 18.0
    place("CoveShack", csx, terrain.ground(csx, csz) - 0.3, csz, "Beach", yaw_facing(0.3, -1.0))
    # CoveSlipway (trap audit H0-04): from the seaward edge of the boardwalk slab nearest the cove find straight down
    # to the find, both ways. The slab (kit/Deck ledge) is 26 wide with its top at point + 2.
    find_cove = (COVE[0][0], 4.5, COVE[0][1] - 25.0)
    k_near = min(range(len(alt_pts)), key=lambda k: math.hypot(alt_pts[k][0] - ORIGIN[0] - find_cove[0],
                                                               alt_pts[k][2] - ORIGIN[2] - find_cove[2]))
    apx, apy, apz = alt_pts[k_near][0] - ORIGIN[0], alt_pts[k_near][1], alt_pts[k_near][2] - ORIGIN[2]
    sdx, sdz = find_cove[0] - apx, find_cove[2] - apz
    sdm = math.hypot(sdx, sdz)
    sdx, sdz = sdx / sdm, sdz / sdm  # downhill, seaward
    slab_top = apy + 2.0
    edge_d = 13.0 - COVE_SLIPWAY["overlap"]  # the high edge reaches 1 stud onto the slab
    cove_rise = slab_top - COVE_SLIPWAY["base"]
    prefabs["CoveSlipway"] = cove_slipway(cove_rise)
    cove_top = (apx + sdx * edge_d, slab_top, apz + sdz * edge_d)
    place("CoveSlipway", cove_top[0], cove_top[1], cove_top[2], "Beach", yaw_facing(-sdx, -sdz))
    prefabs["LedgeCairn"] = ledge_cairn()
    spire_top = terrain.ground(*SPIRE_C)
    place("LedgeCairn", SPIRE_C[0] + 6.0, terrain.ground(SPIRE_C[0] + 6.0, SPIRE_C[1]) - 0.3, SPIRE_C[1], "Finds", 0.0)

    # ---- inland trees and shrubs (fixed seed scatter, clear of the road, plaza, ridge, houses and lagoon)
    tree_keys = []
    for k in range(3):
        key = f"BroadleafTree#{k + 1}"
        prefabs[key] = broadleaf_tree(SEED + 70 + k)
        tree_keys.append(key)
    shrub_keys = []
    for k in range(3):
        key = f"ShrubCluster#{k + 1}"
        prefabs[key] = shrub(SEED + 80 + k)
        shrub_keys.append(key)
    rng = np.random.default_rng(SEED + 7)
    trees = shrubs = 0
    tries = 0
    taken = [(x, z, max(w, d) * 0.75 + 12.0) for _, x, z, _, w, d, _, _ in house_specs]
    while (trees < 34 or shrubs < 40) and tries < 6000:
        tries += 1
        x, z = float(rng.uniform(-520, 480)), float(rng.uniform(-300, 440))
        ix = int(round((x - GX0) / CELL))
        iz = int(round((z - GZ0) / CELL))
        if not terrain.inside[iz, ix] or terrain.dist[iz, ix] < 48.0:
            continue
        h = terrain.ground(x, z)
        if h < 5.0 or h > 60.0:
            continue
        if math.hypot(x - PLAZA_C[0], z - PLAZA_C[1]) < PLAZA_R + 14.0:
            continue
        if any(math.hypot(x - tx, z - tz) < rad for tx, tz, rad in taken):
            continue
        gz, gx = terrain.h[iz, min(ix + 1, terrain.nx - 1)] - terrain.h[iz, ix], terrain.h[min(iz + 1, terrain.nz - 1), ix] - terrain.h[iz, ix]
        if math.hypot(gx, gz) / CELL > 0.5:
            continue
        if trees < 34:
            cyc = (tree_keys[0], "CypressTree#1", tree_keys[1], tree_keys[2], "CypressTree#2")
            place(cyc[trees % 5], x, h - 0.5, z, "Foliage", float(rng.uniform(0, 360)), float(rng.uniform(0.85, 1.3)))
            taken.append((x, z, 16.0))
            trees += 1
        else:
            place(shrub_keys[shrubs % 3], x, h - 0.3, z, "Foliage", float(rng.uniform(0, 360)), float(rng.uniform(0.8, 1.4)))
            taken.append((x, z, 7.0))
            shrubs += 1

    # ---- terrain materials and grid
    west_gate = (PLAZA_C[0] + (PLAZA_R - 10.0) * math.sin(math.radians(246.0)),
                 PLAZA_C[1] - (PLAZA_R - 10.0) * math.cos(math.radians(246.0)))
    paths = [(west_gate, tuple(tr.local(160.0, 30.0)[0::2]), 7.0),
             (tuple(tr.local(250.0, -30.0)[0::2]), (ex_x + 20.0, ex_z + 70.0), 6.0),
             ((PLAZA_C[0], PLAZA_C[1] + PLAZA_R - 10.0), (-120.0, 420.0), 6.0),
             ((PLAZA_C[0] + PLAZA_R - 10.0, PLAZA_C[1] + 20.0), (300.0, 40.0), 6.0)]
    mats = terrain.materials(paths)
    heights = np.round(terrain.h, 1)
    terrain_block = {
        "nx": terrain.nx, "nz": terrain.nz, "cell": CELL,
        "x0": r4(ORIGIN[0] + GX0), "z0": r4(ORIGIN[2] + GZ0),
        "floor": -48, "top": r4(float(heights.max())),
        "heights": [r4(v) for v in heights.ravel()],
        "materials": [int(v) for v in mats.ravel()],
        "palette": [
            {"key": "grass", "material": "LeafyGrass", "color": "#78c24c"},
            {"key": "sand", "material": "Sand", "color": "#f2dea6"},
            {"key": "rock", "material": "Limestone", "color": "#d6b685"},
            {"key": "plaza", "material": "Pavement", "color": "#ecdcbc"},
            {"key": "meadow", "material": "Grass", "color": "#5a9440"},
            {"key": "dirt", "material": "Ground", "color": "#9b8350"},
            {"key": "pathedge", "material": "Mud", "color": "#7a6a4a"},
        ],
        "water": {"level": 0, "color": "#34c6d6", "transparency": 0.32},
    }

    # ---- shells (after the compiled builder): open-sea apron, sea rocks, cove arch, tunnel carve and floor
    ops: list[dict] = []
    ax, az = APRON
    gx0, gx1, gz0, gz1 = ORIGIN[0] + GX0, ORIGIN[0] + GX1, ORIGIN[2] + GZ0, ORIGIN[2] + GZ1
    ox0, ox1, oz0, oz1 = ORIGIN[0] - ax, ORIGIN[0] + ax, ORIGIN[2] - az, ORIGIN[2] + az
    rects = [(ox0, gx0, oz0, oz1), (gx1, ox1, oz0, oz1), (gx0, gx1, oz0, gz0), (gx0, gx1, gz1, oz1)]
    for x0, x1, z0, z1 in rects:
        cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
        ops.append({"op": "FillBlock", "cf": [r4(cx), SEA_FLOOR - 2.0, r4(cz), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                    "size": [r4(x1 - x0), 4, r4(z1 - z0)], "mat": "Sand"})
        ops.append({"op": "FillBlock", "cf": [r4(cx), SEA_FLOOR / 2, r4(cz), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                    "size": [r4(x1 - x0), -SEA_FLOOR, r4(z1 - z0)], "mat": "Water"})
    rng = np.random.default_rng(SEED + 5)
    rock_sites = [tr.local(st, lat) for st, lat in ((40, -230), (180, -260), (230, -205), (470, -200), (1200, -110),
                                                     (1700, -150), (2600, -120), (2700, -160), (3420, -190))]
    rock_sites += [(x, 0.0, z) for x, z in ((760.0, 60.0), (-150.0, 700.0), (40.0, 690.0))]
    for x, _, z in rock_sites:
        for k in range(3):
            c = to_world(x + float(rng.uniform(-9, 9)), float(rng.uniform(-4, 3)), z + float(rng.uniform(-9, 9)))
            ops.append({"op": "FillBall", "center": c, "r": r4(float(rng.uniform(6, 13))), "mat": "Limestone"})
    # cove entrance arch over the AltCove gap in the rock bar (the alternate's own carve opens the gap below it)
    bar_z = COVE_BAR[0][1]
    cross = None  # where the boardwalk first crosses the rock bar's centre line
    for a_, b_ in zip(alt_pts, alt_pts[1:]):
        za, zb = a_[2] - ORIGIN[2], b_[2] - ORIGIN[2]
        if (za - bar_z) * (zb - bar_z) <= 0 and za != zb:
            k = (bar_z - za) / (zb - za)
            cross = [a_[i] + (b_[i] - a_[i]) * k for i in range(3)]
            break
    assert cross is not None, "AltCove must cross the cove bar"
    # The boardwalk crosses the bar at ~35 degrees, so the AltCove carve (half width 20, up to +40) trims the inner
    # faces of the pillar balls; the shoulder balls are 18 (not 15) so the crown still overlaps the trimmed pillars by
    # several studs instead of ~2 (one 4-stud voxel), and the arch does not read as a floating blob.
    for dx, dy, rad in ((0.0, 58.0, 16.0), (-15.0, 54.0, 18.0), (15.0, 54.0, 18.0), (-34.0, 26.0, 20.0), (34.0, 26.0, 20.0)):
        ops.append({"op": "FillBall", "center": [r4(cross[0] + dx), r4(cross[1] + dy), r4(ORIGIN[2] + bar_z)],
                    "r": rad, "mat": "Limestone"})
    # (The "sea cave" Air ball that used to follow here sat on the inland side of the boardwalk, 50 studs from the cove
    # find, and only dug a 5-deep bowl into the sand strip: removed, trap audit H0-11.)
    tun_a, tun_b = tr.rs(TUNNEL[0]), tr.rs(TUNNEL[1])
    assert tun_a < tun_b
    ops.append({"op": "CarveRouteTube", "fromStation": tun_a - 10.0, "toStation": tun_b + 10.0,
                "radiusMin": 36, "radiusMax": 40, "lift": 20, "upperLift": 8, "upperScale": 0.6, "noiseFreq": 0.2,
                "seed": 5})
    ops.append({"op": "RouteFloorFill", "fromStation": tun_a - 10.0, "toStation": tun_b + 10.0,
                "mat": "Limestone", "depth": 8, "width": 76, "thickness": 12})
    ops += tunnel_shoulders(tr, tun_a - 10.0, tun_b + 10.0)

    # ---- gameplay (designed in design stations, written as race stations)
    rs = tr.rs
    # race stations; 1800 sits on the causeway between the two log bridges (trap audit H0-06 b): a fall at the south
    # bridge respawns there instead of at 1600, before the north bridge, which replayed both bridges every time
    cps = [0.0, 400.0, 800.0, 1200.0, 1600.0, 1800.0, 2000.0, 2400.0, 2800.0, 3200.0]
    for br in bridges:
        assert not any(br["deckEnd"] - 20 <= c <= br["deckResume"] + 20 for c in cps), "checkpoint on a log bridge"
    assert any(bridges[0]["deckResume"] < c < bridges[1]["deckEnd"] for c in cps), "no checkpoint between the bridges"
    rings = []
    for st, tag in ((150.0, "Promenade"), (540.0, "TunnelMouth"), (720.0, "Tunnel"), (1100.0, "CliffRoad"),
                    (1420.0, "CliffCrest"), (1790.0, "HeadlandDescent"), (2570.0, "Rocky"), (3420.0, "Southwest")):
        rings.append({"name": f"BoosterRing_{tag}", "station": rs(st), "lateral": 0, "height": RING_HEIGHT, "coin": False,
                      "coinId": None})
    pads = [{"name": "GroundBoost_Promenade", "station": rs(60.0), "lateral": 0},  # 90 before the promenade ring
            {"name": "GroundBoost_CliffRoad", "station": rs(1260.0), "lateral": 0},
            # One pad between the log bridges (trap audit H0-06 a). The old pair at lateral -10/+10 launched the car at
            # 165 for 264 studs straight ahead, and the route bends right under it: off the left pad's centre the line
            # left the 28-wide south bridge (offset -15.5 from its axis). From this pad's centre, toed 3.5 into the
            # bend, the straight line stays within 2 of the bridge axis across the whole span.
            {"name": "GroundBoost_Causeway", "station": rs(2095.0), "lateral": CAUSEWAY_PAD_LATERAL}]
    # Item cubes v3 (docs/design/ITEM_BOXES.md; rules in tools/map/item_cubes.json): 7 staggered sets of 5 mystery
    # cubes (a front rank of 2 at +-8, a back rank of 3 at -16/0/+16 32 studs on), RACE stations (no rs) of the front
    # rank, every 380-690 studs: first 340 past the line (clear of the tunnel-mouth ring), 1300 on the cliff road past
    # the crest ring, 1990 just after the north log bridge (the bridges and the causeway pad in between stay clear),
    # 2420 before the AltCove split and 2930 after its rejoin, so both lines get the same sets, and 3300 before the
    # promenade pad (its back rank must end 250 before the line). The v2 Speed singles 60 after a row became each set's
    # fifth cube; the Speed pickups (mint boost blocks) moved to the middle of the gap after their set.
    pod_rows = [(340.0, "Promenade"), (732.2, "CliffRoad"), (1300.0, "CliffTop"), (1990.0, "Causeway"),
                (2420.0, "Rocky"), (2930.0, "CoveExit"), (3300.0, "Southwest")]
    set_st = [st for st, _ in pod_rows]
    pods = []
    for k, (st, tag) in enumerate(pod_rows):
        pods += item_rows.cube_set("car", "hub0", k, st, 4.5, lambda typ, j, tag=tag: f"PodRow_{tag}_{typ}", tag)
    # Mid-gap, except where the middle is taken: CliffTop's would sit on the north log bridge (1717), so it stands at
    # 1600 between the HeadlandDescent ring and the bridge; CoveExit's would be inside the Southwest ring (3142), so 3100.
    for k, tag, st in ((2, "CliffTop", 1600.0), (3, "Causeway", None), (4, "Rocky", None), (5, "CoveExit", 3100.0)):
        st = st if st is not None else item_rows.gap_single("car", set_st, k, tr.length)
        pods.append(item_rows.speed_single(f"PodSingle_{tag}_Speed", st, 4.5))
    item_rows.assert_layout({"pods": pods}, "car", "hub0", tr.length)
    for lst in (rings, pads, pods):
        lst.sort(key=lambda e: (e["station"], e["name"]))

    # mid station is inside the flat full-offset stretch (ramp < half the alternate), so the boardwalk there sits at
    # exactly (lateral, -0.4 + height) from the race line; the car's hull rides ~4 above the boardwalk point
    alt_mid = (ALT_COVE["join"] + ALT_COVE["rejoin"]) / 2
    assert ALT_COVE["ramp"] < (ALT_COVE["rejoin"] - ALT_COVE["join"]) / 2
    alt_lat = ALT_COVE["lateral"]
    alt_h = DRIVE_TOP - 2.0 + ALT_COVE["height"]
    br1 = bridges[0]
    coins = [
        {"id": 1, "station": rs(690.0), "lateral": -9.0, "height": 4.5, "note": "inside the tunnel"},
        {"id": 2, "station": rs(1150.0), "lateral": 11.0, "height": 4.5},
        {"id": 3, "station": rs(1700.0), "lateral": -10.0, "height": 4.5},
        {"id": 4, "station": round(br1["mid"], 1), "lateral": 10.0, "height": 4.5, "note": "edge of the north log bridge"},
        {"id": 5, "station": rs(2600.0), "lateral": 12.0, "height": 4.5},
        {"id": 6, "station": rs(alt_mid), "lateral": round(alt_lat, 2), "height": round(alt_h + 4.0, 2),
         "alternate": "AltCove", "note": "on the hidden cove boardwalk"},
        {"id": 7, "station": rs(3460.0), "lateral": -8.0, "height": 4.5},
        {"id": 8, "station": rs(230.0), "lateral": 8.0, "height": 4.5, "note": "final promenade straight"},
    ]

    finds = [
        {"id": "HubFind_Ground", "reach": "ground", "pos": to_world(-330.0, terrain.ground(-330.0, 108.0) + 3.0, 108.0),
         "note": "garden terrace behind the upper town houses, on foot from the plaza"},
        {"id": "HubFind_WaterEdge", "reach": "water", "pos": to_world(dock_end[0], 6.0, dock_end[1]),
         "note": "end platform of the long timber dock on the west beach"},
        {"id": "HubFind_Ledge", "reach": "plane", "pos": to_world(SPIRE_C[0], spire_top + 6.0, SPIRE_C[1]),
         "note": "top of the ledge spire above the ridge (LedgeCairn), plane only"},
        {"id": "HubFind_Cove", "reach": "car", "pos": to_world(find_cove[0], terrain.ground(find_cove[0], find_cove[2]) + 4.5, find_cove[2]),
         "note": "hidden cove beach behind the rock bar, reached through the AltCove boardwalk"},
    ]

    # Hub respawn anchors (trap audit H0-05 c): free roam has one respawn point (the plaza slot), so a drown at the
    # dock, the cove or a causeway channel walked the kid back 500-900 studs. Data only: the runtime pick (nearest
    # route frame within 120 of the route, else the nearest anchor to the crash point) lands with the G5 rescue work.
    # Each cf is a ground frame 3 studs up, facing where the kid most likely wants to go next.
    def anchor_cf(lx: float, lz: float, look: tuple[float, float], y: float | None = None) -> list[float]:
        return cf_look(to_world(lx, (terrain.ground(lx, lz) if y is None else y) + 3.0, lz), look)

    def route_cf(race: float) -> list[float]:
        f = tr.route.frame_at(race)
        hx, hz = f.tangent[0], f.tangent[2]
        p = f.offset(0, DRIVE_TOP)
        return cf_look([p[0], p[1] + 3.0, p[2]], (hx, hz))

    _, ldx, ldz, ldd_x, ldd_z = long_dock
    nh_c, _, _ = NE_HEADLAND
    nh_i = int(np.argmin(np.hypot(tr.px - ORIGIN[0] - nh_c[0], tr.pz - ORIGIN[2] - nh_c[1])))
    to_road = (tr.px[nh_i] - ORIGIN[0] - nh_c[0], tr.pz[nh_i] - ORIGIN[2] - nh_c[1])
    tr_m = math.hypot(*to_road)
    to_road = (to_road[0] / tr_m, to_road[1] / tr_m)
    lh_anchor = (nh_c[0] + to_road[0] * 35.0, nh_c[1] + to_road[1] * 35.0)
    k_next = min(k_near + 1, len(alt_pts) - 1)
    bw_look = (alt_pts[k_next][0] - alt_pts[k_near][0], alt_pts[k_next][2] - alt_pts[k_near][2])
    respawns = [
        {"name": "Plaza", "cf": spawn["cf"], "note": "the boot spawn"},
        {"name": "StartLine", "cf": route_cf(20.0), "note": "start grid pole, race station 20"},
        {"name": "ExchangeForecourt", "cf": anchor_cf(ex_x, ex_z + 46.0, (0.25, 1.0), level),
         "note": "between the exchange pads, facing the start straight"},
        {"name": "DockRoot", "cf": anchor_cf(ldx - ldd_x * 24.0, ldz - ldd_z * 24.0, (ldd_x, ldd_z)),
         "note": "24 studs inland of the long dock's slipway, facing out along the dock"},
        {"name": "CoveSlipwayTop", "cf": cf_look(to_world(apx, slab_top + 3.0, apz), bw_look),
         "note": "on the AltCove boardwalk at the top of the CoveSlipway, facing along the boardwalk to the rejoin"},
        {"name": "LighthousePlateau", "cf": anchor_cf(lh_anchor[0], lh_anchor[1], to_road),
         "note": "NE headland plateau beside the lighthouse, facing the road"},
        {"name": "Causeway", "cf": route_cf(1800.0), "note": "between the log bridges, race station 1800"},
    ]

    boss = {
        "id": "HUB-BOSS-1", "hazard": "storm, timed boosts and risky bridges", "lighting": "HUB-0-STORM",
        "guide": STORM_GUIDE, "sky": "assets/sky/hub0/storm",
        "anchors": sorted({p["station"] for p in pads} | {b["mid"] for b in bridges}),
        "timedPads": [{"name": p["name"], "station": p["station"], "period": 4.0, "onFor": 1.6,
                       "phase": (0.0 if p["lateral"] <= 0 else 2.0)} for p in pads],
        "riskyBridges": [{"name": b["name"], "from": b["from"], "to": b["to"], "deckEnd": b["deckEnd"],
                          "deckResume": b["deckResume"], "width": 28} for b in bridges],
        "framingStation": rs(1960.0),
    }

    plan_route = rt
    deck = {"style": "hub0_road", "width": ROAD_WIDTH, "zones": [], "curbHeights": [4.4, 3.8],
            "gaps": [{"from": b["from"], "to": b["to"], "reason": "RiskyLogBridge span over a causeway channel"}
                     for b in bridges],
            "piersEvery": 0}
    materials = {
        "terrainOverrides": {"LeafyGrass": "SR_HUB_Grass", "Sand": "SR_HUB_Sand", "Limestone": "SR_HUB_Cliff",
                             "Pavement": "SR_HUB_PlazaStone", "Grass": "SR_HUB_Meadow",
                             "Ground": "SR_HUB_Dirt", "Mud": "SR_HUB_PathEdge"},
        "terrainColor": "#ffffff",
        # v28 1.8: Limestone tint warmed toward sandstone (colour only; the terrain MATERIAL is unchanged, so CarConfig.OFFROAD_MATERIALS
        # and every surface read stay as they were).
        # L61 grade pass: explicit terrain tints over the neutral maps (the derived texture tints made the grass a
        # neon lime and the cliffs and plaza washed out): a natural mid green, warm sand, ochre cliffs, warm plaza.
        "terrainColors": {"LeafyGrass": "#6fa443", "Grass": "#8aa845", "Sand": "#ecd29e", "Limestone": "#c8a47c",
                          "Pavement": "#e2d0b4", "Ground": "#9b8350", "Mud": "#7a6a4a"},
        "partRules": [
            {"name": "^Paver_", "setMaterial": "Pavement", "variant": "SR_HUB_PlazaStone", "color": "#dcc29a"},
            {"name": "^TrackSeg_", "setMaterial": "Sandstone", "variant": "SR_HUB_Masonry", "color": "#d9ccb2"},
            {"name": "^AltCoveLedge_", "setMaterial": "WoodPlanks", "variant": "SR_HUB_Timber", "color": "#c99e72"},
            {"material": "ClayRoofTiles", "variant": "SR_HUB_Roof"},
            {"material": "WoodPlanks", "variant": "SR_HUB_Timber"},
            {"material": "Sandstone", "variant": "SR_HUB_Masonry"},
            {"material": "Pavement", "variant": "SR_HUB_PlazaStone"},
            {"material": "Limestone", "variant": "SR_HUB_Cliff"},
            {"material": "Plaster", "variant": "SR_HUB_Plaster"},
        ],
    }
    fx = []
    for p in portals:
        veil = ZONE_COLOURS[p["zone"]][0]
        c = p["cf"]
        fx.append({"class": "ParticleEmitter", "name": f"PortalShimmer_{p['zone']}", "group": "Landmarks/Portals",
                   "cf": c, "size": [20, 18, 1],
                   "props": {"Rate": 7, "Lifetime": [1.4, 2.4], "Speed": [0.6, 2.0], "Color": veil,
                             "LightEmission": 0.7, "Size": {"seq": [[0, 1.1, 0], [1, 0.0, 0]]},
                             "Transparency": {"seq": [[0, 0.25, 0], [1, 1.0, 0]]}}})
    # L61 ambient life: fountain jets, surf foam on every beach, gulls wheeling over the coast and the plaza
    droplet, foam, gull = fx_texture("water_droplet"), fx_texture("surf_foam"), fx_texture("gull_flap_2x2")
    fy = PLAZA_H - 0.3
    # v28 W1.3: the jet is capped at 8-10 studs over the nozzle (apex = v^2 / 2g, g = 30: plume 21-23, jet 15-18; it was
    # 30-34 = 17-19 studs and read as a 40-stud bubble column), smaller droplets, and a crown of splash where it lands.
    fx.append({"class": "ParticleEmitter", "name": "FountainJet", "group": "Plaza",
               "cf": cf_up(to_world(PLAZA_C[0], fy + 23.5, PLAZA_C[1]), (0, 1, 0)), "size": [1.5, 0.5, 1.5],
               "props": {"Texture": droplet, "Rate": 70, "Lifetime": [0.9, 1.2], "Speed": [15, 18], "SpreadAngle": [14, 14],
                         "Acceleration": [0, -30, 0], "Drag": 0.3, "Color": "#dff7ff", "LightEmission": 0.25,
                         "Size": {"seq": [[0, 0.6, 0.2], [1, 0.35, 0.1]]},
                         "Transparency": {"seq": [[0, 0.1, 0], [0.8, 0.35, 0], [1, 1, 0]]}}})
    fx.append({"class": "ParticleEmitter", "name": "FountainPlume", "group": "Plaza",
               "cf": cf_up(to_world(PLAZA_C[0], fy + 23.5, PLAZA_C[1]), (0, 1, 0)), "size": [0.8, 0.5, 0.8],
               "props": {"Texture": droplet, "Rate": 36, "Lifetime": [1.3, 1.6], "Speed": [21, 23], "SpreadAngle": [3, 3],
                         "Acceleration": [0, -30, 0], "Color": "#eefbff", "LightEmission": 0.25,
                         "Size": {"seq": [[0, 0.7, 0.2], [0.5, 0.9, 0.2], [1, 0.5, 0.1]]},
                         "Transparency": {"seq": [[0, 0.05, 0], [0.75, 0.3, 0], [1, 1, 0]]}}})
    fx.append({"class": "ParticleEmitter", "name": "FountainSplash", "group": "Plaza",
               "cf": cf_up(to_world(PLAZA_C[0], fy + 23.2, PLAZA_C[1]), (0, 1, 0)), "size": [4.5, 0.4, 4.5],
               "props": {"Texture": droplet, "Shape": "Cylinder", "ShapeStyle": "Surface", "ShapeInOut": "Outward",
                         "EmissionDirection": "Top", "Rate": 26, "Lifetime": [0.5, 0.7], "Speed": [4, 8], "SpreadAngle": [60, 60],
                         "Acceleration": [0, -30, 0], "Color": "#eefbff", "LightEmission": 0.2,
                         "Size": {"seq": [[0, 0.45, 0.1], [1, 0.25, 0]]},
                         "Transparency": {"seq": [[0, 0.15, 0], [1, 1, 0]]}}})
    sparkle = fx_texture("sparkle_star_4x4")
    for st, tag in ((150.0, "Promenade"), (540.0, "TunnelMouth"), (720.0, "Tunnel"), (1100.0, "CliffRoad"),
                    (1420.0, "CliffCrest"), (1790.0, "HeadlandDescent"), (2570.0, "Rocky"), (3420.0, "Southwest")):
        f_ = tr.frame(st)
        hx, hz = tr.heading(st)
        fx.append({"class": "ParticleEmitter", "name": f"RingSparkle_{tag}", "group": "Route",
                   "cf": cf_look(f_.offset(0, RING_HEIGHT), (hx, hz)), "size": [24, 24, 0.5],
                   "props": {"Texture": sparkle, "FlipbookLayout": "Grid4x4", "FlipbookMode": "Loop",
                             "FlipbookFramerate": [24, 24], "FlipbookStartRandom": True, "Shape": "Cylinder",
                             "ShapeStyle": "Surface", "ShapeInOut": "Outward", "EmissionDirection": "Back",
                             "Rate": 14, "Lifetime": [0.9, 1.4], "Speed": [0.4, 1.2], "SpreadAngle": [30, 30],
                             "Color": "#fff1b8", "LightEmission": 1.0,
                             "Size": {"seq": [[0, 0.0, 0], [0.3, 1.4, 0.3], [1, 0.0, 0]]},
                             "Transparency": {"seq": [[0, 0.1, 0], [1, 0.6, 0]]}}})
    for d in (660.0, 720.0, 780.0):
        f_ = tr.frame(d)
        p_ = f_.offset(0, 14.0)
        fx.append({"class": "ParticleEmitter", "name": f"TunnelMotes_{int(d)}", "group": "Route",
                   "cf": cf_up(p_, (0, 1, 0)), "size": [40, 20, 40],
                   "props": {"Texture": fx_texture("glow_soft"), "Rate": 8, "Lifetime": [4, 7], "Speed": [0.3, 1.0],
                             "SpreadAngle": [180, 180], "Color": "#ffe9c4", "LightEmission": 0.8,
                             "Size": {"seq": [[0, 0.0, 0], [0.3, 0.35, 0.1], [1, 0.0, 0]]},
                             "Transparency": {"seq": [[0, 0.3, 0], [1, 0.9, 0]]}}})
    for k in range(4):
        a = math.radians(45 + k * 90)
        ox, oz = math.cos(a), math.sin(a)
        fx.append({"class": "ParticleEmitter", "name": f"FountainArc_{k + 1}", "group": "Plaza",
                   "cf": cf_up(to_world(PLAZA_C[0] + 15.5 * ox, fy + 4.6, PLAZA_C[1] + 15.5 * oz), (-ox * 0.55, 1, -oz * 0.55)),
                   "size": [0.8, 0.4, 0.8],
                   "props": {"Texture": droplet, "Rate": 26, "Lifetime": [0.8, 1.0], "Speed": [13, 15], "SpreadAngle": [4, 4],
                             "Acceleration": [0, -34, 0], "Color": "#dff7ff", "LightEmission": 0.3,
                             "Size": {"seq": [[0, 0.55, 0.1], [1, 0.35, 0]]},
                             "Transparency": {"seq": [[0, 0.15, 0], [1, 0.8, 0]]}}})
    surf_sites = []
    for d in list(range(0, 540, 40)) + list(range(2380, 3340, 80)):
        for lat in range(-36, -300, -4):
            x, _, z = tr.local(float(d), float(lat))
            if terrain.ground(x, z) < 0.4:
                hx, hz = tr.heading(float(d))
                surf_sites.append((x, z, (hx, 0.0, hz)))
                break
    for k in range(6):  # cove and harbour islet shores (ring)
        a = math.radians(200 + k * 28)
        surf_sites.append((COVE[0][0] + 74.0 * math.cos(a), COVE[0][1] + 74.0 * math.sin(a) * 0.6,
                           (-math.sin(a), 0.0, math.cos(a))))
    for k in range(4):
        a = math.radians(k * 90 + 20)
        surf_sites.append((ISLET[0][0] + 52.0 * math.cos(a), ISLET[0][1] + 52.0 * math.sin(a), (-math.sin(a), 0.0, math.cos(a))))
    for i, (x, z, along) in enumerate(surf_sites):
        fx.append({"class": "ParticleEmitter", "name": f"SurfFoam_{i + 1}", "group": "Beach",
                   "cf": cf_up(to_world(x, 0.35, z), (0, 1, 0), along), "size": [6, 0.2, 30],
                   "props": {"Texture": foam, "Rate": 4.0, "Lifetime": [2.2, 3.2], "Speed": [0.2, 0.5],
                             "Orientation": "FacingCameraWorldUp", "Rotation": [0, 360], "RotSpeed": [-8, 8],
                             "Color": "#ffffff", "LightEmission": 0.3,
                             "Size": {"seq": [[0, 2.5, 0.5], [1, 6.0, 1.0]]},
                             "Transparency": {"seq": [[0, 1, 0], [0.2, 0.2, 0], [0.7, 0.45, 0], [1, 1, 0]]}}})
    gull_sites = [(PLAZA_C[0], PLAZA_H + 62.0, PLAZA_C[1], 180.0),
                  (tr.local(260.0, -170.0)[0], 52.0, tr.local(260.0, -170.0)[2], 220.0),
                  (LAGOON[0][0] + 90.0, 46.0, LAGOON[0][1], 200.0),
                  (COVE[0][0], 44.0, COVE[0][1] - 20.0, 160.0),
                  (NE_HEADLAND[0][0], 88.0, NE_HEADLAND[0][1] + 20.0, 160.0)]
    for i, (x, y, z, w) in enumerate(gull_sites):
        fx.append({"class": "ParticleEmitter", "name": f"Gulls_{i + 1}", "group": "Beach",
                   "cf": cf_up(to_world(x, y, z), (0, 1, 0)), "size": [w, 16, w],
                   "props": {"Texture": gull, "FlipbookLayout": "Grid2x2", "FlipbookMode": "Loop",
                             "FlipbookFramerate": [5, 7], "FlipbookStartRandom": True,
                             "Shape": "Cylinder", "ShapeStyle": "Surface", "ShapeInOut": "InAndOut",
                             "Rate": 0.4, "Lifetime": [16, 22], "Speed": [7, 10], "SpreadAngle": [6, 6],
                             "Color": "#ffffff", "LightEmission": 0.0, "LightInfluence": 1.0,
                             "Size": {"seq": [[0, 7.5, 1.0], [1, 7.5, 1.0]]},
                             "Transparency": {"seq": [[0, 1, 0], [0.06, 0, 0], [0.94, 0, 0], [1, 1, 0]]}}})
    route_lights = {"every": 4, "fromStation": tun_a, "toStation": tun_b, "offsets": [[-18, 8], [18, 8]],
                    "color": "#ffbe70", "range": 22, "brightness": 1.0}  # v28 1.8: small warm lanterns, not a wide wash

    plan = {
        "prefabs": {k: prefabs[k] for k in sorted(prefabs)},
        "instances": instances,
        "groups": groups,
        "terrain": terrain_block,
        "markers": [],
        "skyrally": {
            "archetype": "Hub loop with secret routes (boss venue)", "signatureVerb": "explore",
            "signature": "Explore the hub loop for secret routes behind the waterfall, over the cliff and into the hidden cove.",
            "id": "HUB-0", "key": "hub0", "zone": "HUB", "vehicle": "car", "laps": 3,
            "guide": GUIDE, "lighting": "HUB-0",
            "route": plan_route,
            "deck": deck,
            "flight": {"lineOffset": LINE_OFFSET, "corridor": dict(CORRIDOR)},
            "gameplay": {
                "checkpoints": {"stations": cps, "size": [52, 28, 6], "heightOffset": 8},
                "rings": rings, "pads": pads, "pods": pods,
                "startGrid": {"station": 20, "height": 5, "rowSpacing": 22, "laneOffset": 11},
                "finish": {"station": 0, "radius": 40},
                "alternates": [{"id": "AltCove", "points": alt_pts, "style": "ledge",
                                "joinStation": rs(ALT_COVE["join"]), "rejoinStation": rs(ALT_COVE["rejoin"])}],
                "coins": coins,
                "key": None,
                "modes": {},
                "boss": boss,
                "portals": portals,
                "finds": finds,
                "spawn": spawn,
                "respawns": respawns,
                "exchange": exchange,
            },
            "shells": {"ops": ops},
            "hazards": [],
            "meshes": harbour_meshes,
            "modelAttributes": [],
            "fx": fx,
            "framing": {"heroStation": 20, "note": "start grid chase view north up the promenade: timber dock, beach "
                                                  "and the exchange bays at the bluff foot on the left, terracotta town "
                                                  "on the right, the carved tunnel arch in the cliff ahead "
                                                  "(04_HUB0_CENTRAL_ISLAND.png)"},
            "routeLights": route_lights,
            "materials": materials,
            "provenance": {
                "author": "tools/map/author_hub0.py", "seed": SEED, "origin": list(ORIGIN),
                "routeLength": round(length, 3), "routeFlexScale": round(tr.route.flex_scale, 6),
                "minTurnRadius": round(float(min_r["r"]), 1), "minTurnRadiusStation": min_r["st"],
                "maxGradeDeg": round(float(max_grade), 2),
                "startDesignStation": round(tr.shift, 3), "tunnel": [tun_a, tun_b],
                "bridges": [{k: v for k, v in b.items() if k not in ("dDeckEnd", "dDeckResume", "dMid")}
                            for b in bridges],
                "terrainGrid": [terrain.nx, terrain.nz, CELL], "seaApron": list(APRON),
                "materialSet": "assets/materials/hub_v1/variants.json",
                "sky": {"clear": "assets/sky/hub0", "storm": "assets/sky/hub0/storm"},
            },
        },
    }
    return plan, {"length": length, "minR": min_r, "maxGrade": max_grade, "bridges": bridges, "alt": alt_pts,
                  "parts": sum(len(prefabs[i["pf"]]["parts"]) for i in instances), "instances": len(instances),
                  "prefabs": len(prefabs)}


def main() -> None:
    plan, info = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(plan, indent=None, separators=(",", ":"), sort_keys=False)
    OUT.write_text(text + "\n")
    VARIANTS_OUT.parent.mkdir(parents=True, exist_ok=True)
    VARIANTS_OUT.write_text(json.dumps(VARIANTS, indent=1) + "\n")
    skies = write_sky()
    print(f"wrote {OUT.relative_to(ROOT)} ({len(text) // 1024} KB) sha256={hashlib.sha256(text.encode()).hexdigest()[:12]}")
    print(f"route      length {info['length']:.2f} (target {TARGET_LENGTH}), min turn radius {info['minR']['r']:.1f} at "
          f"st {info['minR']['st']}, max grade {info['maxGrade']:.2f} deg")
    print(f"art        {info['prefabs']} prefabs, {info['instances']} instances, {info['parts']} parts")
    for b in info["bridges"]:
        print(f"bridge     {b['name']} gap {b['from']}-{b['to']} deck {b['deckEnd']}..{b['deckResume']} len {b['length']}")
    print(f"altcove    {len(info['alt'])} points")
    print(f"wrote      {VARIANTS_OUT.relative_to(ROOT)}, " + ", ".join(skies))


if __name__ == "__main__":
    main()
