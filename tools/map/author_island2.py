#!/usr/bin/env python3
"""TRACK_PIPELINE P1 author script for ISLAND-2 "Tropical Galleon Coast" (car), CONTENT row ISLAND-2 (Crescent Island
homage), guide docs/guides/island2.md. Deterministic (fixed seeds, rounded
floats): rerun it, then `python3 tools/map/adapt.py map/island2/plan.json`. Never edit the outputs by hand.

Writes:
  map/island2/plan.json               the whole map as data (MAP_PLAN_SCHEMA)
  map/island2/preview_topdown.png     top-down QA render (terrain materials, route, stations, landmarks)
  assets/materials/island_v1/variants.json   MaterialVariant names -> island_v1 textures
  assets/sky/island2/{up,side,down}.png      procedural Sunshine sky faces (the integrator uploads them)

Lap (clockwise from above, ~4600 studs, 3 laps):
  crescent beach start straight (galleon cove on the left, key alcove inlet on the right; the guide's hero view)
  -> torch-lit coastal stone cavern through the headland (masonry mouth arch, arch ribs every ~70 studs, a sea-grotto
     chamber with a skylight and a pool beside a rock ledge) -> north cliff ledge road along the sea -> east clifftop
     past the lighthouse promontory -> crest jump (a short height step on a straight) -> descent to the south-east
     corner -> stone arch bridge over the lagoon channel -> palm-hut village chicane on the south beach -> the
     crescent back to the line. Alt1 is a timber boardwalk (ledge style) that leaves the south beach, swings out
     over the shallows round the crescent (coin 7) and rejoins 40 studs before the line.
Car rules honoured: deck top = ribbon + 1.6, banks within +-6 deg (derived from curvature), grades <= 15 deg, the jump
is a 3.5 deg kicker then a 10 deg step down on a straight (a car at 128 studs/s flies ~41 studs), road width 44,
terrain shoulders at ribbon + 1 following the bank. The beach road sits 3 above the sea so the key inlet, the cove
flats and the alcove stay within CarConfig.OFFTRACK_DROP (6) of the route and never trigger a stranded respawn.
Construction: open landscape = one 30MAPS terrain height grid (cell 8: sand, coastal rock, tropical grass, a
Limestone shallow-water bed and a Slate deep bed, Terrain Water at sea level); the cavern, grotto and key alcove are
shells ops carved after the builder; the far sea is a water frame (SEA_FRAME) around the grid, bounded clear of the
other launch maps. Masonry, galleon, lighthouse,
huts, palms and parapets are block-built 30MAPS prefabs (Raiser faceted style), collidable only where a car can reach
them and never inside the car corridor (halfWidth 24, floor +1, ceiling +34 over the ribbon).
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

import route as routelib  # noqa: E402
import route_geometry  # noqa: E402
import item_rows  # noqa: E402  (item cubes v2 layout rules, tools/map/item_cubes.json)

OUT_DIR = ROOT / "map" / "island2"
OUT = OUT_DIR / "plan.json"
PREVIEW = OUT_DIR / "preview_topdown.png"
SKY_DIR = ROOT / "assets" / "sky" / "island2"
VARIANTS = ROOT / "assets" / "materials" / "island_v1" / "variants.json"

MAP_ID, KEY, ZONE = "ISLAND-2", "island2", "ISLAND"
GUIDE = "docs/guides/island2.md"
# World position of local (0, 0, 0). Local y 0 is sea level. Chosen clear of DINO-4 (x -1380..320, z -2090..490 with
# its bounds fill) and TEST-STRIP (x ~3400..4400); the whole map moves with this constant.
ORIGIN = (-5200.0, 20.0, 4400.0)
SEA = ORIGIN[1]
# Far-sea water frame around the height grid (world x0, x1, z0, z1). Bounded so it never reaches the other launch
# maps' footprints as authored on 2026-10-18 (HUB-0 x<=-6300 z>=6500, SNOW-1 x<=-7200 z<=960, DINO-4 x>=-1580 z<=250);
# shells write Terrain Water there, which would flood a neighbour built in the same place.
SEA_FRAME = (-7000.0, -1700.0, 1100.0, 6300.0)
TARGET_LENGTH = 4600
STEPS = 8  # Catmull-Rom samples per node segment
DECK_WIDTH = 44
DECK_TOP = 1.6  # TrackSeg top above the ribbon (kit/Deck)
SHOULDER = 1.0  # terrain beside the road sits this far above the ribbon (= corridor floor, so the carve keeps it)
CORRIDOR = {"halfWidth": 24, "floor": 1, "ceiling": 34}
LINE_OFFSET = 4.5  # car hull centre over the ribbon (paver top 2.7 + ride height 1.9)
CAR_GRAVITY = 140.0  # src/shared/CarConfig.luau GRAVITY
# Ring centre over the ribbon. The car's hull (paver top 2.7 + ride 1.9 = 4.6) passes through the ring's lower opening
# (inner radius ~10, so the opening reaches under the pavers) instead of driving through its bottom rim; the rims a
# wheel probe can touch (kit/Gameplay rims are queryable) stay outside +-6 of the line. Hull-to-ring 3.4 < 16.
RING_HEIGHT = 8.0
POD_HEIGHT = 4.5
COIN_HEIGHT = 5.0
PARAPET_LATERAL = 30.5
BRIDGE_PARAPET_LATERAL = 26.4  # on the bridge the parapet stands against the curbs (outer face 25.2), over the deck
# Parapets reach this far below their base: on the 8-stud grid the sea cliff edge falls up to 12.5 under the parapet
# line, so a 3.4 wall alone floated over a gap; the foot reads as a sea wall built on the cliff edge.
PARAPET_FOOT = 14.0
BRIDGE_PARAPET_FOOT = 7.6  # bridge parapets cover the deck fascia down to ribbon - 6.4
GRID_CELL = 8

# Route control nodes, local studs: (x, z, height above sea, flex x, flex z). Banks are derived from the solved
# curvature (bank_for). Flex widens the east and south of the loop so the bisection lands on TARGET_LENGTH.
NODES = [
    (0, 0, 3, 0, 0),            # N0  start/finish on the crescent beach, heading north
    (8, -120, 3, 0, 0),         # N1
    (24, -250, 4, 0, 0),        # N2  cavern mouth in the headland's south face
    (40, -410, 6.5, 0, -10),    # N3  cavern
    (80, -590, 10, -5, -15),    # N4  grotto chamber on the left
    (190, -740, 13, 0, -20),    # N5
    (340, -830, 17, 0, -25),    # N6  exit portal
    (520, -850, 21, 10, -25),   # N7  north cliff ledge road, sea on the left
    (700, -800, 23, 20, -20),   # N8
    (840, -700, 25, 25, -10),   # N9  east clifftop
    (940, -560, 26, 30, 0),     # N10
    (990, -430, 26, 30, 0),     # N11 lighthouse promontory S-bend
    (1070, -330, 26, 30, 0),    # N12
    (1170, -270, 26, 30, 0),    # N13
    (1240, -170, 26, 30, 0),    # N14
    (1255, -62, 26, 30, 0),     # N15 jump straight
    (1257, -26, 28.2, 30, 0),   # N16 crest lip (3.5 deg kicker)
    (1258, 6, 23.4, 30, 0),     # N17 step down
    (1258, 130, 16, 30, 0),     # N18
    (1235, 280, 13, 30, 10),    # N19
    (1150, 400, 12, 20, 20),    # N20 south-east corner
    (1000, 465, 13, 10, 20),    # N21
    (800, 490, 21, 0, 20),      # N22 lagoon bridge
    (620, 495, 22, 0, 20),      # N23
    (440, 488, 19, 0, 20),      # N24
    (300, 490, 7, 0, 20),       # N25 village chicane
    (190, 462, 4.5, 0, 20),     # N26
    (70, 470, 3.5, 0, 20),      # N27
    (-40, 400, 3, -10, 10),     # N28 crescent
    (-75, 280, 3, -10, 0),      # N29
    (-50, 150, 3, -5, 0),       # N30
    (-15, 62, 3, 0, 0),         # N31
]
ZERO_BANK = {0, 1, 15, 16, 17, 22, 23}  # start straight, jump, bridge

# Headland (the cavern's rock mass), local (x, z) polygon. South face z=-255 holds the cavern mouth and the key
# alcove; the exit portal is the short north-south edge at x~375; the ledge road runs outside its north edge.
HEADLAND = [(-40, -255), (270, -255), (330, -330), (520, -470), (700, -600), (805, -735), (720, -785),
            (540, -838), (380, -818), (372, -905), (330, -965), (200, -995), (80, -935), (-40, -800),
            (-150, -640), (-160, -470), (-80, -400)]
HEADLAND_FACE_Z = -255.0
EXIT_PORTAL_X = 376.0

# Galleon: anchored in the cove, bow towards the headland, starboard side (gangways) facing the beach.
GALLEON_POS = (-170.0, -272.0)  # local x, z (waterline): ~34 deg left of the start grid's view, ~300 studs out
GALLEON_YAW = -36.87  # bow (local -Z) points (0.6, -0.8): north-north-east
# Water-battle galleon geometry in the SHIP frame (x starboard toward the beach, y up from the waterline, z toward the
# stern; the bow is -z). Trap audit docs/audits/traps_island2.md G1 (I2-01/02/03/04/08/11): the ship is a fortress a
# player chooses, never a cage. Every opening in the starboard bulwark is exactly as wide as the ramp or plank in it;
# the ramps carry collidable plank rails with skirts down into the sand, flared 20 deg at both ends; a sand bank (the
# Plank Dune) lies under the lower ramps and the plank landing, joined to the beach crest by a spit, dry at every tide.
SHIP_DECK = 12.0  # main deck top
HULL_SIDE = 16.2  # starboard bulwark line: the gangways and the plank leave the deck here
GANGWAY_W = 16.0  # ramp width = its bulwark opening (the old 15-wide aft opening held a 9-wide ramp: a 5.5-stud hole)
GANGWAY_Z = {"Fore": -20.0, "Aft": 22.0}  # lane centres (fore opening z -28..-12, aft 14..30)
DUNE_TOP = 4.6  # Plank Dune plateau over the sea: dry above the last tide step (+4.5)
RAMP_FOOT_Y = DUNE_TOP + 0.6  # ramp foot and its landing plank top: the dune stays under every ramp surface
# The run stays the first gangways' 48 (WaterRules' ramp tuning: RAMP_COMMIT, APPROACH, and DECK_TOLERANCE 3, which
# would count the top 12.6 studs of a 28.6-stud ramp as the decks); the drop onto the dune is 6.8, an 8.1 deg slope.
RAMP_RUN = 48.0
RAMP_SLOPE = (SHIP_DECK - RAMP_FOOT_Y) / RAMP_RUN
FOOT_PLANK = 6.0  # landing plank past each ramp foot
RAIL_H = 3.0  # collidable plank rails: top this far over the ramp (CarController wall rays run 2.2 over the road)
RAIL_T = 0.6
SKIRT_DROP = 10.0  # rail boards reach this far under the ramp surface: no car gets under a ramp (I2-11)
FLARE_DEG = 20.0  # rail flares: a car along the lane meets them at |dir.n| = sin 20 = 0.34 < WALL_SHALLOW_DOT 0.42
FLARE_LEN = 8.0
# Walk the Plank: a 12 deg kicker amidships, off the starboard side between the main mast (z -2) and the hatch
# (z 10..18), 10 wide; any car that runs off it lands on dry sand (the bank under the deck side or the dune beyond).
PLANK_Z0, PLANK_Z1 = 0.5, 10.5
PLANK_X0, PLANK_X1 = 4.0, 22.0
PLANK_DEG = 12.0
# Plank Dune (ship frame): plateau rectangle x0, x1, z0, z1, a spit (capsule a -> b, radius) to the beach crest, and
# the flank run from the plateau edge down to the natural ground.
DUNE_RECT = (16.0, 100.0, -36.0, 38.0)
DUNE_SPIT = ((96.0, 4.0), (176.0, -6.0), 11.0)
DUNE_FLANK = 16.0
# Key alcove in the headland face, right of the mouth, behind a shallow inlet. The arch stands at the foot of the cliff
# ramp (grid rows z -248 outside / -256 inside the face), so its recess box opens straight onto the apron.
ALCOVE_X = 150.0
ALCOVE_FLOOR = 0.4
ALCOVE_Z = HEADLAND_FACE_Z + 6.0  # arch pivot (local z); the key plinth is 18 behind it, inside the recess
# Tall cliff faces over the two cavern portals (guide: the arch is set in a towering rock face). Without them the
# tube's balls (lift 18, r <= 50, upper lobe to ~+100) broke through the 41-59 stud face crest behind each arch.
# (local x, z of the portal on the face, radius of full height)
PORTAL_CLIFFS = [((24.0, -255.0), 200.0), ((376.0, -869.0), 120.0)]
PORTAL_CLIFF_BASE = 112.0
# Sea stacks: local (x, z, radius, top height)
STACKS = [(-82, -48, 17, 22), (-330, -110, 20, 30), (-330, -390, 26, 38), (-420, 60, 14, 18), (450, -985, 18, 26),
          (620, -955, 28, 44), (1420, -230, 22, 36), (1430, 80, 16, 22), (300, 650, 20, 26), (900, 640, 24, 30),
          (1180, 560, 15, 18),
          # L61: more stacks so every sea view has a silhouette (critic r0 item 12: empty horizon)
          (-560, -300, 30, 52), (-470, -560, 22, 34), (-270, 380, 18, 28), (1560, -620, 26, 44), (1000, 780, 22, 34),
          (180, -1180, 24, 40)]
LAGOON = ((630.0, 395.0), (205.0, 82.0))  # centre, radii (inside the loop, north of the bridge)
INLET = ((165.0, -168.0), (100.0, 112.0))  # shallow water in front of the key alcove

# ISLAND-2 Alt2 "Headland Wall-Ride" (TRACK_VARIETY 5a launch upgrade): a third line that leaves the start straight just
# past the line, crosses the dry flats east of the key inlet, rides diagonally up the headland's south-east face (an
# existing 60-65 deg rock band: the car's wall driving, nothing about it changes), crosses the headland roof above the
# cavern and rides down the north-east face onto the inland plain, then rejoins the clifftop road from its right side at
# a 34 deg angle. The terrain is not touched: the line is a polyline over the grid that is already baked. Control points
# are local (x, z) studs, chosen so the path crosses the rock bands at a shallow angle to their contours (path slope
# <= ~0.55, about 29 deg, where the face itself is 63-65 deg) and keeps clear of the key inlet, the alcove, the
# water-battle cove, the grotto skylight and every cavern ball that breaks the roof. verify_cliff_line() asserts it.
#
# v26 (V7A Studio check): the line used to rejoin at station 1690 heading 34 deg across the road, straight at the unwalled
# sea edge of the clifftop (a car that did not turn within ~55 studs went into the sea), and it ran 2.8-3.1 s slower than
# the main route over the same stretch, most of it a crawl (17-41 studs/s) where the old line turned 67 deg (radius ~50)
# while crossing the crease at the foot of the face. Now: the face entry turns on the ledge and crosses the foot at a
# shallow angle (radius >= 110 there, the ground normal turns <= 25 deg per 8 studs instead of 42), the descent ends on the
# inland plain and the line runs beside the road on its inland side and merges at ~9 deg by station 1760 (it reaches the
# deck by ~1670, through the Clifftop cube rows), and three booster rings (CLIFF_RINGS) make a clean run about 1 s
# faster than the main route (docs/design/TRACK_VARIETY.md 5a, "ISLAND-2 Alt2 pace"). Terrain, walls, kill volumes and
# rescue are untouched: only the line, its tells and its rings move.
CLIFF_ID = "Alt2"
CLIFF_JOIN, CLIFF_REJOIN = 46.0, 1760.0  # route stations of the first and last point (both sit on the ribbon)
CLIFF_CTRL = [(60, -52), (112, -40), (172, -24), (231, -48), (274, -94), (303, -150), (319, -196), (317, -243),
              (313, -291), (330, -342), (366, -381), (413, -430), (483, -498), (539, -555), (603, -579), (640, -603),
              (684, -618), (730, -660), (796, -681), (869, -669), (928, -624)]
# Booster rings on the line, by horizontal distance along it: one just past the foot crease (the climb), one on the
# lower half of the descent, one on the inland plain before the merge. Each boost window (PAD_BOOST_SPEED 165 for 1.6 s plus
# 60 studs, as tools/map/tests/test_boost_windows.py) stays in line radius >= 124, the car's boosted turning radius, and every
# ring stays 40+ studs from the road so a main-route car never takes one.
CLIFF_RINGS = [("BoosterRing_CliffClimb", 580.0), ("BoosterRing_CliffDescent", 1015.0), ("BoosterRing_CliffPlain", 1180.0)]
CLIFF_EXIT_ARROWS = (1120.0, 1215.0)  # horizontal studs along the line: the plain run-out, 30+ studs right of the road
CLIFF_RING_LIFT = 8.0  # ring centre over the ground along the surface normal (the road rings: RING_HEIGHT over the ribbon)
CLIFF_STEP = 16.0  # polyline spacing
CLIFF_SINK = 2.0  # line height under the grid surface: the stranded test measures from it, so a low reading is the safe side
CLIFF_PAD = {"name": "GroundBoost_CliffEntry", "station": 50.0, "lateral": 31.0}  # on the line, beyond the road edge
CLIFF_PAD_CLEAR = 160.0  # v37: the pad's horizontal distance from the front grid row (station 20)


# ------------------------------------------------------------------------------------------------ small helpers
def r3(x: float) -> float:
    v = round(float(x), 3)
    return 0.0 if v == 0 else v


def r1(x: float) -> float:
    v = round(float(x), 1)
    return 0.0 if v == 0 else v


def W(x: float, h: float, z: float) -> list[float]:
    """local -> world"""
    return [r3(ORIGIN[0] + x), r3(ORIGIN[1] + h), r3(ORIGIN[2] + z)]


def smooth(t: float) -> float:
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def rot_y(deg: float) -> np.ndarray:
    a = math.radians(deg)
    return np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])


def yaw_of(t) -> float:
    """Instance yaw (degrees) whose local -Z points along the horizontal direction t."""
    return math.degrees(math.atan2(-t[0], -t[2]))


def part(shape, pos, size, rot=(0, 0, 0), color="#ffffff", mat="SmoothPlastic", nc=False, a=None, light=None, n=None):
    p = [shape, r3(pos[0]), r3(pos[1]), r3(pos[2]), r3(size[0]), r3(size[1]), r3(size[2]),
         r3(rot[0]), r3(rot[1]), r3(rot[2]), color, mat]
    ex = {}
    if nc:
        ex["nc"] = 1
    if a is not None:
        ex["a"] = a
    if light is not None:
        ex["l"] = light
    if n is not None:
        ex["n"] = n
    if ex:
        p.append(ex)
    return p


def beam(p0, p1, w, t, color, mat="SmoothPlastic", shape="B", **kw):
    """Block/cylinder whose local Y runs from p0 to p1 (YXZ Euler: rx = acos(dy), ry = atan2(dx, dz))."""
    d = np.subtract(p1, p0).astype(float)
    L = float(np.linalg.norm(d))
    d /= L
    rx = math.degrees(math.acos(max(-1.0, min(1.0, d[1]))))
    ry = math.degrees(math.atan2(d[0], d[2])) if abs(d[1]) < 0.9999 else 0.0
    mid = (np.add(p0, p1) * 0.5).tolist()
    return part(shape, mid, (w, L, t), (rx, ry, 0), color, mat, **kw)


# ------------------------------------------------------------------------------------------------------ route
def route_block(banks: list[float] | None = None) -> dict:
    nodes = []
    for i, (x, z, h, fx, fz) in enumerate(NODES):
        n = {"pos": W(x, h, z), "bank": banks[i] if banks else 0.0}
        if fx or fz:
            n["flex"] = [r3(fx), 0.0, r3(fz)]
        nodes.append(n)
    return {"nodes": nodes, "closed": True, "samplesPerSegment": STEPS, "targetLength": TARGET_LENGTH,
            "flexScaleMin": 0.0, "flexScaleMax": 3.5, "bisectIterations": 24, "minRadius": 85,
            "radiusExceptions": []}


def node_station(route: routelib.Route, i: int) -> float:
    return route.waypoints[i * STEPS].station


def signed_radius(route: routelib.Route, st: float, span: float = 35.0) -> float:
    a = route.frame_at(st - span).pos
    b = route.frame_at(st).pos
    c = route.frame_at(st + span).pos
    r = route_geometry.radius3(a, b, c)
    t1 = (b[0] - a[0], b[2] - a[2])
    t2 = (c[0] - b[0], c[2] - b[2])
    cross_y = t1[1] * t2[0] - t1[0] * t2[1]  # (a x b).y with a=(x,0,z): a.z*b.x - a.x*b.z ; > 0 = left turn
    return r if cross_y > 0 else -r


def bank_for(route: routelib.Route, i: int, tunnel: tuple[float, float]) -> float:
    if i in ZERO_BANK:
        return 0.0
    st = node_station(route, i)
    r = signed_radius(route, st)
    if math.isinf(r):
        return 0.0
    cap = 4.0 if tunnel[0] <= st <= tunnel[1] else 6.0
    b = max(-cap, min(cap, 620.0 / r))  # left turn -> positive (raises the right/outside edge)
    return round(b * 2) / 2


# ----------------------------------------------------------------------------------------- polygon utilities
def point_in_poly(x: np.ndarray, z: np.ndarray, poly) -> np.ndarray:
    inside = np.zeros(x.shape, bool)
    n = len(poly)
    for i in range(n):
        x1, z1 = poly[i]
        x2, z2 = poly[(i + 1) % n]
        cond = ((z1 > z) != (z2 > z))
        xint = (x2 - x1) * (z - z1) / ((z2 - z1) + 1e-12) + x1
        inside ^= cond & (x < xint)
    return inside


def dist_to_poly_edges(x: np.ndarray, z: np.ndarray, poly) -> np.ndarray:
    best = np.full(x.shape, np.inf)
    n = len(poly)
    for i in range(n):
        x1, z1 = poly[i]
        x2, z2 = poly[(i + 1) % n]
        dx, dz = x2 - x1, z2 - z1
        t = np.clip(((x - x1) * dx + (z - z1) * dz) / (dx * dx + dz * dz), 0, 1)
        d = np.hypot(x - (x1 + t * dx), z - (z1 + t * dz))
        best = np.minimum(best, d)
    return best


def value_noise(x: np.ndarray, z: np.ndarray, scale: float, seed: int) -> np.ndarray:
    """Deterministic smooth value noise in [-1, 1] (hash lattice + smoothstep)."""
    gx, gz = x / scale, z / scale
    ix, iz = np.floor(gx).astype(np.int64), np.floor(gz).astype(np.int64)
    fx, fz = gx - ix, gz - iz

    def h(a, b):
        v = (a * 374761393 + b * 668265263 + seed * 2147483647) & 0xFFFFFFFF
        v = ((v ^ (v >> 13)) * 1274126177) & 0xFFFFFFFF
        return ((v ^ (v >> 16)) & 0xFFFF) / 32767.5 - 1.0

    sx, sz = fx * fx * (3 - 2 * fx), fz * fz * (3 - 2 * fz)
    a, b = h(ix, iz), h(ix + 1, iz)
    c, d = h(ix, iz + 1), h(ix + 1, iz + 1)
    return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sz


# ---------------------------------------------------------------------------------------------- the terrain
class Terrain:
    """30MAPS height grid (local heights; written to the plan in world Y) plus a bilinear sampler matching the
    builder, so props sit on the ground the builder will make."""

    def __init__(self, route: routelib.Route, sections: list[tuple[float, float, str, str]], promontory=None):
        self.route = route
        self.promontory = promontory
        wp = route.waypoints
        xs = [w.pos[0] - ORIGIN[0] for w in wp]
        zs = [w.pos[2] - ORIGIN[2] for w in wp]
        m = 420
        self.x0 = math.floor((min(xs) - m) / GRID_CELL) * GRID_CELL
        self.z0 = math.floor((min(zs) - m - 180) / GRID_CELL) * GRID_CELL
        x1 = math.ceil((max(xs) + m) / GRID_CELL) * GRID_CELL
        z1 = math.ceil((max(zs) + m) / GRID_CELL) * GRID_CELL
        self.nx = int((x1 - self.x0) / GRID_CELL) + 1
        self.nz = int((z1 - self.z0) / GRID_CELL) + 1
        self.sections = sections
        self._build()

    # dense route samples (local x, z, ribbon height, bank, right vector, station)
    def _samples(self, step: float = 3.0):
        L = self.route.length
        out = []
        s = 0.0
        while s < L:
            f = self.route.frame_at(s)
            out.append((f.pos[0] - ORIGIN[0], f.pos[2] - ORIGIN[2], f.pos[1] - ORIGIN[1], f.bank, f.right[0], f.right[2], s))
            s += step
        return np.array(out)

    def nearest(self, X: np.ndarray, Z: np.ndarray):
        """Per point: horizontal distance, signed lateral, station, ribbon height, bank of the nearest route sample."""
        S = self.samples
        flatX, flatZ = X.ravel(), Z.ravel()
        n = flatX.size
        d = np.empty(n)
        idx = np.empty(n, np.int64)
        for a in range(0, n, 4000):
            bx, bz = flatX[a:a + 4000, None], flatZ[a:a + 4000, None]
            dd = (bx - S[None, :, 0]) ** 2 + (bz - S[None, :, 1]) ** 2
            k = np.argmin(dd, axis=1)
            idx[a:a + 4000] = k
            d[a:a + 4000] = np.sqrt(dd[np.arange(k.size), k])
        sx, sz = S[idx, 0], S[idx, 1]
        lat = (flatX - sx) * S[idx, 4] + (flatZ - sz) * S[idx, 5]
        shp = X.shape
        return (d.reshape(shp), lat.reshape(shp), S[idx, 6].reshape(shp), S[idx, 2].reshape(shp),
                S[idx, 3].reshape(shp))

    def _profile(self, kind: str, d_out: np.ndarray, e: np.ndarray, noise: np.ndarray) -> np.ndarray:
        """Natural ground for a side of the road; where the road is raised above that ground (bridge ends, the
        descent) an embankment (slope 0.4) carries the shoulder down to it."""
        cap = {"cove_beach": 5.2, "beach_sea": 5.2, "inlet_beach": 5.2, "village": 6.5}.get(kind)
        if cap is None:
            return self._natural(kind, d_out, e, noise)
        nat = self._natural(kind, d_out, np.minimum(e, cap), noise)
        return np.maximum(nat, e - np.maximum(d_out - 4.0, 0.0) * 0.4)

    def _natural(self, kind: str, d_out: np.ndarray, e: np.ndarray, noise: np.ndarray) -> np.ndarray:
        if kind in ("cove_beach", "beach_sea"):
            flats = 150.0 if kind == "cove_beach" else 26.0
            slope = 0.14 if kind == "cove_beach" else 0.10
            d0 = 6.0 + np.maximum(e, 0.5) / slope
            h = np.where(d_out < 6, e, e - (d_out - 6) * slope)
            h = np.where(d_out >= d0, -1.0 * np.clip((d_out - d0) / 10.0, 0, 1), h)
            far = d0 + 10 + flats
            h = np.where(d_out >= far, -1.0 - 11.0 * np.clip((d_out - far) / 80.0, 0, 1), h)
            h = np.where(d_out >= far + 80, -12.0 - 8.0 * np.clip((d_out - far - 80) / 160.0, 0, 1), h)
            return h + 0.25 * noise * (d_out > 12)
        if kind == "inlet_beach":
            h = np.where(d_out < 10, e, e - np.clip(d_out - 10, 0, 40) * 0.04)
            return h + 26.0 * (1 - np.exp(-np.maximum(d_out - 90, 0) / 110.0)) + 0.3 * noise * (d_out > 12)
        if kind == "cliff_sea":
            h = np.where(d_out < 5, e, e - (e + 8.0) * np.clip((d_out - 5) / 9.0, 0, 1))
            return np.where(d_out >= 14, -8.0 - 10.0 * np.clip((d_out - 14) / 70.0, 0, 1) + 1.5 * noise, h)
        if kind == "hill":
            rise = 30.0 * (1 - np.exp(-np.maximum(d_out - 6, 0) / 80.0))
            return e + rise + (3.0 * noise) * np.clip((d_out - 10) / 30, 0, 1)
        if kind == "hill_low":
            rise = 12.0 * (1 - np.exp(-np.maximum(d_out - 6, 0) / 60.0))
            return e + rise + (2.0 * noise) * np.clip((d_out - 10) / 30, 0, 1)
        if kind == "village":
            rise = 3.0 * (1 - np.exp(-np.maximum(d_out - 10, 0) / 50.0))
            hill = 24.0 * (1 - np.exp(-np.maximum(d_out - 120, 0) / 110.0))
            return e + rise + hill + 0.6 * noise * (d_out > 14)
        if kind == "bridge_sea":
            return -6.0 - 10.0 * np.clip((d_out - 40.0) / 120.0, 0, 1)
        if kind == "bridge_lagoon":
            return -6.0 + (e + 10.0) * smooth_np((d_out - 30.0) / 80.0)
        raise SystemExit(f"unknown terrain profile {kind}")

    def _kind_grid(self, st: np.ndarray, lat: np.ndarray) -> np.ndarray:
        kinds = np.empty(st.shape, dtype=object)
        kinds[:] = "hill"
        for a, b, left, right in self.sections:
            sel = (st >= a) & (st < b)
            kinds[sel & (lat < 0)] = left
            kinds[sel & (lat >= 0)] = right
        return kinds

    def _build(self) -> None:
        self.samples = self._samples()
        ix = np.arange(self.nx)
        iz = np.arange(self.nz)
        X, Z = np.meshgrid(self.x0 + ix * GRID_CELL, self.z0 + iz * GRID_CELL)  # [iz, ix]
        self.X, self.Z = X.astype(float), Z.astype(float)
        d, lat, st, ry, bank = self.nearest(self.X, self.Z)
        self.d, self.lat, self.st = d, lat, st
        d_out = np.maximum(d - 25.0, 0.0)
        # shoulder: the deck top minus (DECK_TOP - SHOULDER), following the bank across the road
        latc = np.clip(lat, -25.0, 25.0)
        e = ry + SHOULDER + latc * np.sin(np.radians(bank))
        noise = value_noise(self.X, self.Z, 70.0, 3) * 0.7 + value_noise(self.X, self.Z, 23.0, 5) * 0.3
        kinds = self._kind_grid(st, lat)
        H = np.zeros(self.X.shape)
        for kind in sorted(set(kinds.ravel())):
            sel = kinds == kind
            H[sel] = self._profile(kind, d_out[sel], e[sel], noise[sel])
        self.kinds = kinds
        # blur away the steps where the nearest-station profile switches (medial lines), never at the shoulders
        B = H.copy()
        for _ in range(5):
            P = np.pad(B, 1, mode="edge")
            B = sum(P[1 + dz:1 + dz + B.shape[0], 1 + dx:1 + dx + B.shape[1]] for dz in (-1, 0, 1) for dx in (-1, 0, 1)) / 9.0
        alpha = np.clip((d - 40.0) / 50.0, 0, 1)
        alpha = alpha * alpha * (3 - 2 * alpha)
        H = H * (1 - alpha) + B * alpha
        far = d > 34.0
        # lagoon (inside the loop, north of the bridge)
        (lx, lz), (ra, rb) = LAGOON
        q = np.hypot((self.X - lx) / ra, (self.Z - lz) / rb)
        lag = -4.0 + 4.6 * np.clip((q - 0.55) / 0.45, 0, 1)
        H = np.where(far & (q < 1.0), np.minimum(H, lag), H)
        # inlet in front of the key alcove: drivable shallows (bed -1.0), rising to the alcove sill
        (ixc, izc), (ia, ib) = INLET
        q = np.hypot((self.X - ixc) / ia, (self.Z - izc) / ib)
        inlet = -1.0 + (H + 1.0) * smooth_np((q - 0.5) / 0.5)
        H = np.where((d > 34.0) & (q < 1.0), np.minimum(H, inlet), H)
        # galleon basin (ship-aligned ellipse) and the dry sandbar under the gangway feet
        R = rot_y(GALLEON_YAW)
        rel = np.stack([self.X - GALLEON_POS[0], np.zeros_like(self.X), self.Z - GALLEON_POS[1]], -1) @ R  # ship frame
        sxs, szs = rel[..., 0], rel[..., 2]
        q = np.hypot(sxs / 34.0, szs / 80.0)
        H = np.where(q < 1.0, np.minimum(H, -9.0 + 8.0 * np.clip((q - 0.75) / 0.25, 0, 1)), H)
        for zoff in (-20.0, 22.0):
            qb = np.hypot((sxs - 66.0) / 22.0, (szs - zoff) / 16.0)
            H = np.where(qb < 1.0, np.maximum(H, -1.0 + 1.7 * np.clip((1 - qb) / 0.4, 0, 1)), H)
        # Plank Dune (trap audit G1): a dry sand bank against the starboard side, under both lower gangways and the
        # plank landing, joined to the beach crest by a spit. Before, the sandbars under the gangway feet flooded at
        # the 23.0 step and the decks became an island from t=50 (I2-01).
        dune = np.maximum(H, dune_height(sxs, szs, H))
        self.dune_mask = dune > H + 0.05  # grid nodes the dune raised (kept clear of palms)
        H = dune
        # lighthouse promontory: clifftop-level land out to the lighthouse, sheer edges to the sea
        self.prom_mask = np.zeros(self.X.shape, bool)
        if self.promontory is not None:
            (px_, pz_), pr, ph = self.promontory
            q = np.hypot(self.X - px_, self.Z - pz_) / (pr * (1.0 + 0.16 * value_noise(self.X, self.Z, 26.0, 21)))
            prom = ph + 0.6 * noise - 30.0 * np.clip((q - 0.9) / 0.1, 0, 1)
            H = np.where(q < 1.0, np.maximum(H, prom), H)
            self.prom_mask = q < 0.88
        # sea stacks (rock)
        self.stack_mask = np.zeros(self.X.shape, bool)
        for sx_, sz_, rr, top in STACKS:
            q = np.hypot(self.X - sx_, self.Z - sz_) / rr
            jag = 1.0 + 0.18 * value_noise(self.X, self.Z, 9.0, int(sx_ * 7 + sz_) & 0xFFFF)
            hs = np.where(q < 1.0 * jag, top * (1 - np.clip((q - 0.55) / 0.45, 0, 1) ** 2) + 2 * jag, -100)
            self.stack_mask |= hs > H + 0.5
            H = np.maximum(H, hs)
        # headland: rock mass with near-vertical faces, crowned at ~155
        inside = point_in_poly(self.X, self.Z, HEADLAND)
        dist = dist_to_poly_edges(self.X, self.Z, HEADLAND)
        hh = 46.0 + 108.0 * smooth_np(dist / 75.0) + 7.0 * value_noise(self.X, self.Z, 40.0, 11)
        for (px_, pz_), rad in PORTAL_CLIFFS:  # towering faces over the cavern mouth (and key alcove) and the exit
            w = smooth_np((rad - np.hypot(self.X - px_, self.Z - pz_)) / 60.0)
            tall = PORTAL_CLIFF_BASE + 42.0 * smooth_np(dist / 40.0) + 5.0 * value_noise(self.X, self.Z, 40.0, 11)
            hh = np.maximum(hh, hh * (1 - w) + tall * w)
        self.headland = inside
        H = np.where(inside, np.maximum(H, hh), H)
        # key alcove apron: flat sand from the inlet shallows up to the sill. The nodes in front of the face are nearest
        # to cavern stations (profile "hill"), which left an 8-26 stud bank across the alcove mouth: no car got in.
        along = self.Z - HEADLAND_FACE_Z  # 0 at the face, growing towards the inlet
        target = ALCOVE_FLOOR - (ALCOVE_FLOOR + 1.0) * smooth_np((along - 8.0) / 30.0)
        wa = smooth_np((30.0 - np.abs(self.X - ALCOVE_X)) / 10.0) * smooth_np((50.0 - along) / 10.0) * (~inside)
        H = np.where(wa > 0, np.minimum(H, H * (1 - wa) + target * wa), H)
        self.H = np.round(H, 1)
        self._materials()

    def _materials(self) -> None:
        H = self.H
        gz, gx = np.gradient(H, GRID_CELL)
        slope = np.hypot(gx, gz)
        k = self.kinds
        sandy = np.isin(k, ["cove_beach", "beach_sea", "inlet_beach", "village", "bridge_sea", "bridge_lagoon"])
        M = np.full(H.shape, PAL["grass"])
        M[(sandy & (self.d < 150)) | (H < 4.5)] = PAL["sand"]
        M[(self.d < 30) & ~sandy & (H >= 4.5)] = PAL["grass"]
        M[(slope > 0.85) & (H >= 2)] = PAL["rock"]
        M[np.isin(k, ["cliff_sea"]) & (self.d > 31) & (H > -0.4)] = PAL["rock"]
        M[self.stack_mask] = PAL["rock"]
        M[self.prom_mask & (slope < 0.6)] = PAL["grass"]
        M[self.dune_mask] = PAL["sand"]  # the Plank Dune is a sand bank (above 4.5 the default would paint it grass)
        hd = self.headland
        M[hd] = PAL["rock"]
        M[hd & (slope < 0.35) & (H > 120)] = PAL["grass"]
        M[H < -0.4] = PAL["seabed"]
        M[H < -6.0] = PAL["deep"]
        self.M = M

    def on_dune(self, x: float, z: float) -> bool:
        """Whether any grid node of the cell under (x, z) was raised by the Plank Dune."""
        ix = max(min(int(math.floor((x - self.x0) / GRID_CELL)), self.nx - 2), 0)
        iz = max(min(int(math.floor((z - self.z0) / GRID_CELL)), self.nz - 2), 0)
        return bool(self.dune_mask[iz:iz + 2, ix:ix + 2].any())

    def height(self, x: float, z: float) -> float:
        """Bilinear, as builder_template height()."""
        fx = (min(max(x, self.x0), self.x0 + (self.nx - 1) * GRID_CELL) - self.x0) / GRID_CELL
        fz = (min(max(z, self.z0), self.z0 + (self.nz - 1) * GRID_CELL) - self.z0) / GRID_CELL
        ix = max(min(int(math.floor(fx)), self.nx - 2), 0)
        iz = max(min(int(math.floor(fz)), self.nz - 2), 0)
        tx, tz = fx - ix, fz - iz
        H = self.H
        u = H[iz, ix] + (H[iz, ix + 1] - H[iz, ix]) * tx
        v = H[iz + 1, ix] + (H[iz + 1, ix + 1] - H[iz + 1, ix]) * tx
        return float(u + (v - u) * tz)

    def material(self, x: float, z: float) -> int:
        ix = int(round((x - self.x0) / GRID_CELL))
        iz = int(round((z - self.z0) / GRID_CELL))
        ix = max(0, min(self.nx - 1, ix))
        iz = max(0, min(self.nz - 1, iz))
        return int(self.M[iz, ix])

    def plan_block(self) -> dict:
        return {
            "nx": self.nx, "nz": self.nz, "cell": GRID_CELL,
            "x0": r3(ORIGIN[0] + self.x0), "z0": r3(ORIGIN[2] + self.z0),
            "heights": [r1(v + SEA) for v in self.H.ravel()],
            "materials": [int(v) for v in self.M.ravel()],
            "palette": [{"key": k, "material": m, "color": c} for k, m, c in PALETTE],
            "floor": r1(SEA - 36), "top": r1(float(self.H.max()) + SEA),
            "water": {"level": SEA, "color": WATER_COLOR, "transparency": 0.22},
        }


def smooth_np(t: np.ndarray) -> np.ndarray:
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


# L61 grade (critic r0: "toxic greens", "washed-out beach tones"): olive sea-grass, warm sand, warm grey stone, a teal
# seabed. These are also the plan's materials.terrainColors: the tint the neutral detail maps multiply (low-graphics
# clients show the tint alone).
PALETTE = [  # key, Enum.Material, colour
    ("sand", "Sand", "#e2d0aa"),
    ("rock", "Rock", "#a89e90"),
    ("grass", "Grass", "#83985a"),
    ("seabed", "Limestone", "#a8ad8e"),
    ("deep", "Slate", "#2d5f6b"),
]
# terrain-look: runtime tint overrides, kept out of PALETTE so the baked terrain block (and terrain_hash) is unchanged
TERRAIN_TINT = {"Rock": "#b0a595", "Limestone": "#d2c8a2"}  # v29 D13: seabed reads sand, not pink-grey
WATER_COLOR = "#1a8494"  # deep tropical teal (was a bright cyan #36c9d3 that read as neon from the clifftop)
PAL = {k: i + 1 for i, (k, _, _) in enumerate(PALETTE)}


# ------------------------------------------------------------------------------------------------ the prefabs
WOOD_DARK, WOOD, WOOD_LIGHT = "#6b4a2e", "#8e5f39", "#a9784a"
TEAL, CREAM, GOLD, IRON = "#3f8a86", "#efe3c6", "#d9a441", "#3a3a40"
SAIL, SAIL_SHADE, DECK = "#f4ecd8", "#e3d7bb", "#c49563"
STONE, STONE_LIGHT, STONE_DARK = "#b9b4ab", "#d6d0c4", "#8c877f"
FLAME, FLAME_LIGHT = "#ffa53a", [30, 1.5, "#ffa64a", False]
BRONZE = "#7a5a34"  # torch cups


def voussoirs(cx: float, cy: float, r_in: float, thick: float, depth: float, count: int, theta0: float = 0.0,
              theta1: float = 180.0, color=STONE, key_color=STONE_LIGHT, mat="Slate", z: float = 0.0) -> list:
    """Arch ring of block stones across local X (span) and Y, centred at (cx, cy), depth along local Z."""
    out = []
    rm = r_in + thick / 2
    arc = (math.radians(theta1 - theta0) * rm / count) * 0.94
    for k in range(count):
        th = math.radians(theta0 + (theta1 - theta0) * (k + 0.5) / count)
        keystone = (k == count // 2) and count % 2 == 1
        t = thick + (2.0 if keystone else 0.0)
        u, v = cx + rm * math.cos(th), cy + rm * math.sin(th)
        col = key_color if keystone or k % 3 == 1 else color
        out.append(part("B", (u, v, z), (t, arc, depth + (1.0 if keystone else 0.0)), (0, 0, math.degrees(th)), col, mat))
    return out


def prefab_cavern_mouth() -> dict:
    """Big chunky voussoir arch for the cavern mouth / exit portal (guide: grey masonry blocks set in the cliff)."""
    parts = voussoirs(0, 32, 33.5, 10, 14, 11)
    for side in (-1, 1):
        x = side * 39.0
        parts += [part("B", (x, 4, 0), (11, 12, 15), (0, 0, 0), STONE_DARK, "Slate"),
                  part("B", (x + side * 0.5, 15.5, 0), (10, 11, 14), (0, 0, 0), STONE, "Slate"),
                  part("B", (x, 26.5, 0), (11.5, 11, 15), (0, 0, 0), STONE_LIGHT, "Slate"),
                  part("B", (x + side * 6.5, 33, 0.5), (4, 3, 16), (0, 0, 0), STONE_DARK, "Slate")]
        # wall torches on the arch flanks (non-colliding)
        # v28 critic 1.16: bracket + bronze cup; the art swap hides the Neon block and puts the particle flame there
        parts += [part("B", (side * 33.0, 18, -6), (1.2, 4, 1.2), (0, 0, side * -20), IRON, "Metal", nc=True),
                  part("C", (side * 32.2, 19.4, -6), (2.2, 1.0, 2.2), (0, 0, 0), BRONZE, "Metal", nc=True),
                  part("B", (side * 32.2, 20.6, -6), (1.6, 2.2, 1.6), (0, 45, 0), FLAME, "Neon", nc=True, light=[40, 1.8, "#ffa64a", False])]
    return {"parts": parts}


def prefab_cavern_rib() -> dict:
    parts = voussoirs(0, 30, 31.5, 6, 8, 9, color=STONE, key_color=STONE_LIGHT)
    for side in (-1, 1):
        x = side * 34.5
        parts += [part("B", (x, 6, 0), (6.5, 14, 9), (0, 0, 0), STONE_DARK, "Slate"),
                  part("B", (x, 21, 0), (6, 16, 8), (0, 0, 0), STONE, "Slate"),
                  part("B", (side * 31.2, 15, 0), (0.9, 3.6, 0.9), (0, 0, side * -22), IRON, "Metal", nc=True),
                  part("C", (side * 30.4, 16.3, 0), (2.0, 0.9, 2.0), (0, 0, 0), BRONZE, "Metal", nc=True),
                  part("B", (side * 30.4, 17.4, 0), (1.5, 2.0, 1.5), (0, 45, 0), FLAME, "Neon", nc=True, light=FLAME_LIGHT)]
    return {"parts": parts}


def prefab_key_alcove() -> dict:
    """Small water-side arch in the headland face; the key floats over the plinth inside (gameplay.key)."""
    parts = voussoirs(0, 12.5, 13, 5, 7, 7, color=STONE, key_color=STONE_LIGHT)
    for side in (-1, 1):
        parts += [part("B", (side * 15.5, 6.2, 0), (5, 12.4, 7.5), (0, 0, 0), STONE_DARK, "Slate"),
                  part("B", (side * 15.5, 0.2, 2.5), (6, 1.2, 4), (0, 0, 0), STONE, "Slate"),
                  part("C", (side * 11.0, 9.5, 1.5), (0.6, 4, 0.6), (0, 0, 0), IRON, "Metal", nc=True),
                  part("B", (side * 11.0, 12.2, 1.5), (1.6, 1.8, 1.6), (0, 45, 0), "#9fefff", "Neon", nc=True,
                       light=[26, 1.4, "#a8f0ff", False])]
    # stepped sill and the key plinth inside the recess (recess runs to local -Z, into the cliff)
    parts += [part("B", (0, 0.1, -2), (26, 1.0, 6), (0, 0, 0), STONE_LIGHT, "Slate"),
              part("B", (0, 0.9, -18), (7, 2.2, 7), (0, 45, 0), STONE, "Slate"),
              part("B", (0, 2.4, -18), (5, 0.8, 5), (0, 45, 0), GOLD, "Metal", nc=True, light=[22, 1.2, "#ffd27a", False])]
    return {"parts": parts}


# Battle-only barrier across the cavern-mouth road (trap audit I2-05, docs/audits/traps_island2.md). The race road runs
# out of the water-battle arena through the soft band (150..175 from the centre) and into the cavern, where the boundary
# return used to drop the car onto a flooded pad. This closes the arch opening jamb to jamb, but only in a battle:
# it is modes.battle data that server/battle/BattleBarriers builds into the BattleOverlay folder, so the race, boss and
# coin modes never see it and the adapt corridor gate stays clean. The fun layer: a hanging "NOPE!" board, a kraken
# tentacle asleep over the crates, and a snore from the dark (cue barrier_snore; silent until it is uploaded).
BARRIER_HALF_SPAN = 35.0  # the arch jambs' inner faces stand at +-33.5; the collider ends inside them
ROPE = "#c9a46a"
KRAKEN = "#b65e9a"


def part_front_z(row) -> float:
    """Largest local z a part row reaches (its box, YXZ Euler degrees as the map builder applies them)."""
    rx, ry, rz = (math.radians(v) for v in row[7:10])
    cx, sx_, cy, sy_, cz, sz_ = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    ry_m = np.array([[cy, 0, sy_], [0, 1, 0], [-sy_, 0, cy]])
    rx_m = np.array([[1, 0, 0], [0, cx, -sx_], [0, sx_, cx]])
    rz_m = np.array([[cz, -sz_, 0], [sz_, cz, 0], [0, 0, 1]])
    m = ry_m @ rx_m @ rz_m
    half = np.array(row[4:7], float) / 2
    return float(row[3] + np.abs(m[2]) @ half)


def cavern_barrier(frame, station: float) -> dict:
    """modes.battle.barriers entry: frame on the ribbon at `station`, +Z toward the arena, X = the route's right."""
    t = np.array([frame.tangent[0], 0.0, frame.tangent[2]], float)
    t /= np.linalg.norm(t)
    back = -t  # +Z faces the arena (the car arrives travelling along the tangent)
    up = np.array([0.0, 1.0, 0.0])
    right = np.cross(up, back)
    cf = [r3(frame.pos[0]), r3(frame.pos[1]), r3(frame.pos[2]),
          r3(right[0]), 0.0, r3(back[0]),
          0.0, 1.0, 0.0,
          r3(right[2]), 0.0, r3(back[2])]
    road = 2.7  # paver top over the ribbon
    rope = dict(shape="C", nc=True)
    P = []
    for x in (-25.5, 25.5):  # 1-2 posts, 3-4 brass knobs
        P.append(part("C", (x, 6.0, 0.0), (2.8, 20.0, 2.8), (0, 0, 0), WOOD_DARK, "Wood"))
    for x in (-25.5, 25.5):
        P.append(part("S", (x, 16.4, 0.0), (2.9, 2.9, 2.9), (0, 0, 0), GOLD, "Metal"))
    sag = [(-25.5, 14.2), (-12.5, 10.9), (0.0, 10.2), (12.5, 10.9), (25.5, 14.2)]  # 5-8 the sagging rope
    for (xa, ya), (xb, yb) in zip(sag, sag[1:]):
        P.append(beam((xa, ya, 0.0), (xb, yb, 0.0), 0.9, 0.9, ROPE, "Fabric", **rope))
    for x in (-5.5, 5.5):  # 9-10 sign hangers
        P.append(beam((x, 10.4, 0.8), (x, 8.6, 0.8), 0.35, 0.35, ROPE, "Fabric", **rope))
    P.append(part("B", (0, 6.3, 0.75), (19.2, 5.6, 0.5), (0, 0, 3), "#b8402e", "WoodPlanks", nc=True))  # 11 trim
    P.append(part("B", (0, 6.3, 1.05), (18.0, 4.8, 0.6), (0, 0, 3), WOOD_LIGHT, "WoodPlanks", nc=True))  # 12 NOPE board
    barrels = [(-19.5, -0.8), (-15.0, -1.2), (15.5, -1.0), (20.0, -0.75)]
    for x, z in barrels:  # 13-16 barrels on the road
        P.append(part("C", (x, road + 2.8, z), (4.2, 5.6, 4.2), (0, 0, 0), WOOD, "Wood"))
    P.append(part("C", (-17.2, road + 8.4, -1.0), (4.2, 5.6, 4.2), (0, 0, 0), WOOD, "Wood"))  # 17 stacked barrel
    for x, z in barrels:  # 18-21 iron hoops
        P.append(part("C", (x, road + 2.8, z), (4.45, 0.45, 4.45), (0, 0, 0), IRON, "Metal", nc=True))
    P += [part("B", (-7.5, road + 2.5, -1.6), (5, 5, 5), (0, 10, 0), WOOD_LIGHT, "WoodPlanks"),  # 22-24 crates
          part("B", (7.0, road + 2.5, -1.8), (5, 5, 5), (0, -8, 0), WOOD_LIGHT, "WoodPlanks"),
          part("B", (7.3, road + 7.25, -1.8), (4.5, 4.5, 4.5), (0, 22, 0), WOOD, "WoodPlanks")]
    P.append(part("B", (21.4, 10.6, 1.1), (8.0, 3.4, 0.5), (0, 0, -7), WOOD_LIGHT, "WoodPlanks", nc=True))  # 25 SHHH
    P += [part("B", (-24.4, 13.4, 0.5), (2.4, 0.3, 0.3), (0, 0, 0), IRON, "Metal", nc=True),  # 26-27 lantern
          part("B", (-23.4, 12.2, 0.5), (1.3, 1.8, 1.3), (0, 45, 0), "#ffb347", "Neon", nc=True,
               light=[34, 1.6, "#ffa64a", False])]
    tentacle = [((7.6, 13.7, -2.4), 3.0), ((10.2, 12.6, -1.8), 2.7), ((12.6, 10.9, -1.2), 2.3),
                ((14.6, 9.6, -0.6), 1.9), ((16.2, 10.3, -0.2), 1.5), ((16.6, 11.4, 0.0), 1.1)]
    for pos, d in tentacle:  # 28-33 a sleeping kraken tentacle draped over the crates
        P.append(part("S", pos, (d, d, d), (0, 0, 0), KRAKEN, "SmoothPlastic", nc=True))
    for prow in P:  # nothing pokes out of the collider's arena face (z = +1.5): the car meets the flat wall first
        assert part_front_z(prow) <= 1.5 + 1e-6, (prow, part_front_z(prow))
    return {
        "name": "CavernMouthBarrier",
        "station": station,
        "cf": cf,
        "collider": {"center": [0.0, 16.0, 0.0], "size": [2 * BARRIER_HALF_SPAN, 36.0, 3.0]},
        "parts": P,
        "signs": [{"part": 12, "face": "Back", "title": "NOPE!", "text": "THE BATTLE'S BEHIND YOU, MATEY", "tilt": 0},
                  {"part": 25, "face": "Back", "title": "SHHH!", "text": "KRAKEN NAPPING", "titleColor": "#fff4d6",
                   "textColor": "#ffd27a"}],
        "snore": {"offset": [0.0, 14.0, -26.0], "cue": "barrier_snore", "volume": 0.8, "rollOff": 150,
                  "text": "z Z z"},
        "note": "battle only (server/battle/BattleBarriers): collider jamb to jamb from under the road to the arch "
                "spring, CanCollide + CanQuery for the car's wall rays; props behind its arena face",
    }


# Galleon cannons (docs/REMARKABLE.md item 13, the fun layer of trap audit G1 step 7). Battle-only data: modes.battle
# .launchers rows that server/WorldSetPieces builds into cannons and arms in the water battle only (the names are the
# runtime's allow-list, shared/SetPieceRules.LAUNCHER_NAMES). Drive into a cradle and the cannon takes the car: the
# CrestCannon on the beach crest fires it back aboard onto the main deck, the DeckCannon on the forecastle fires it
# ashore onto the dune spit (sand above the last tide step). One server-announced landing per shot; the arc between
# is the client's scripted ride (shared/SetPieceRules.rideFrame). The Walk the Plank salute gun is the starboard
# gunport cannon beside the kicker.
CANNON_ELEV = {"CrestCannon": 30.0, "DeckCannon": 32.0}  # barrel elevation (deg)
CANNON_LEN = 15.0  # breech to muzzle
CANNON_BORE_Y = 4.0  # bore centre over the floor at the breech (the bore is 7 across: a car fits)
CANNON_BREECH = 5.0  # cradle centre to the breech, along the barrel's heading
CAR_RIDE = 1.9  # src/shared/CarConfig.luau RIDE_HEIGHT


def galleon_launchers(ship, ship_dir, local_ground, pads, road_xz, centre, arena_r, deck_y, last_tide) -> dict:
    """modes.battle.launchers rows + the plank salute gun. ship(local) -> world list; local_ground(world x, z) -> the
    world surface y there; pads: world spawn points; road_xz: (n, 2) world route points."""
    def unit(v):
        v = np.asarray(v, float)
        return v / np.linalg.norm(v)

    def v3(v):
        return [r3(v[0]), r3(v[1]), r3(v[2])]

    def flat_dist(a, b):
        return math.hypot(a[0] - b[0], a[2] - b[2])

    def road_gap(p):
        d = road_xz - np.array([p[0], p[2]])
        return float(np.min(np.hypot(d[:, 0], d[:, 1])))

    # CrestCannon: cradle on the beach crest between the seat (crest pad B) and the bot pad, 12 studs off the road
    # edge; lands on the starboard main deck, clear of the hatch and the capstan, facing the stern.
    # DeckCannon: cradle on the forecastle at the top of the port stair (the item box stays 10 studs clear, under no
    # barrel); lands on the dune spit facing the crest, veering away from the CrestCannon's cradle so a landing never
    # rolls into it.
    specs = [
        ("CrestCannon", W(-22.0, 0.0, -150.0), None, ship((9.0, 0.0, -24.0)), deck_y["main"], "deck", ship_dir(0.0, 1.0)),
        ("DeckCannon", ship((-9.0, 0.0, -41.0)), deck_y["forecastle"], ship((156.0, 0.0, -3.5)), None, "sand",
         ship_dir(1.0, -0.35)),
    ]
    rows = []
    for name, cxz, cfloor, lxz, lground, surface, look in specs:
        floor = cfloor if cfloor is not None else local_ground(cxz[0], cxz[2])
        ground = lground if lground is not None else local_ground(lxz[0], lxz[2])
        land = np.array([lxz[0], ground + CAR_RIDE, lxz[2]])
        head = unit([land[0] - cxz[0], 0.0, land[2] - cxz[2]])
        breech = np.array([cxz[0], floor + CANNON_BORE_Y, cxz[2]]) + head * CANNON_BREECH
        el = math.radians(CANNON_ELEV[name])
        axis = unit(head * math.cos(el) + np.array([0.0, math.sin(el), 0.0]))
        # aim the horizontal heading from the muzzle (the breech offset shifts it by a hair)
        for _ in range(4):
            muzzle = breech + axis * CANNON_LEN
            head = unit([land[0] - muzzle[0], 0.0, land[2] - muzzle[2]])
            axis = unit(head * math.cos(el) + np.array([0.0, math.sin(el), 0.0]))
        cradle = np.array([cxz[0], floor + CAR_RIDE, cxz[2]])
        rows.append({"name": name, "cradle": v3(cradle), "breech": v3(breech), "axis": v3(axis), "length": CANNON_LEN,
                     "land": v3(land), "landLook": [r3(look[0]), 0.0, r3(look[2])], "ground": r3(ground),
                     "surface": surface, "floor": r3(floor)})
    cradles = [np.array(r["cradle"]) for r in rows]
    for r in rows:
        land, cradle = np.array(r["land"]), np.array(r["cradle"])
        # every cradle and landing stays dry at the last tide step (drownDepth 2.2 under it would still drive)
        assert r["floor"] >= last_tide - 2.2 + 0.5, (r["name"], r["floor"])
        if r["surface"] == "sand":
            assert r["ground"] >= last_tide, (r["name"], "sand landing under the last tide", r["ground"])
        # off the pads (a respawn is never set down in a cradle or under a landing), inside the arena
        for p in pads:
            assert flat_dist(cradle, p) >= 28.0, (r["name"], "cradle near a pad", p)
            assert flat_dist(land, p) >= 20.0, (r["name"], "landing near a pad", p)
        # inside the arena: landings well inside, the forecastle cradle as far out as the forecastle itself stands
        assert flat_dist(land, centre) <= arena_r - 20.0, (r["name"], "landing outside the arena")
        assert flat_dist(cradle, centre) <= arena_r - 5.0, (r["name"], "cradle outside the arena")
        # the race road stays clear of the beach cannon (the whole barrel and the cradle sled)
        if r["surface"] == "deck":
            muzzle = np.array(r["breech"]) + np.array(r["axis"]) * CANNON_LEN
            for p in (cradle, np.array(r["breech"]), muzzle):
                assert road_gap(p) >= DECK_WIDTH / 2 + 8.0, (r["name"], "cannon on the race road", road_gap(p))
        # a landing car rolls 30 studs along its look without entering any cradle (no ping-pong between the cannons)
        look = np.array(r["landLook"])
        for c in cradles:
            for t in np.arange(0.0, 30.01, 1.0):
                assert flat_dist(land + look * t, c) >= 6.5 + 4.0, (r["name"], "landing rolls into a cradle", t)
        # the sand landing run stays dry for those 30 studs
        if r["surface"] == "sand":
            for t in np.arange(0.0, 30.01, 2.0):
                q = land + look * t
                assert local_ground(q[0], q[2]) >= last_tide - 2.2 + 0.3, (r["name"], "landing run floods", t)
    salute = {"gun": ship((18.6, 7.4, 12.0)), "dir": ship_dir(1.0, 0.0),
              "note": "the starboard gunport cannon beside the Walk the Plank kicker fires a salute (client only)"}
    return {"launchers": rows, "salute": salute}


def dune_height(sx: np.ndarray, sz: np.ndarray, natural: np.ndarray) -> np.ndarray:
    """Plank Dune height (local, over the sea) at ship-frame points: DUNE_TOP on the plateau rectangle and the spit,
    easing down to the natural ground over DUNE_FLANK; the natural ground wherever it is higher or out of reach."""
    x0, x1, z0, z1 = DUNE_RECT
    dx = np.maximum(np.maximum(x0 - sx, sx - x1), 0.0)
    dz = np.maximum(np.maximum(z0 - sz, sz - z1), 0.0)
    d = np.hypot(dx, dz)
    (ax, az), (bx, bz), rad = DUNE_SPIT
    ux, uz = bx - ax, bz - az
    t = np.clip(((sx - ax) * ux + (sz - az) * uz) / (ux * ux + uz * uz), 0.0, 1.0)
    d = np.minimum(d, np.maximum(np.hypot(sx - (ax + t * ux), sz - (az + t * uz)) - rad, 0.0))
    target = DUNE_TOP - (DUNE_TOP - natural) * smooth_np(d / DUNE_FLANK)
    return np.where(d < DUNE_FLANK, target, natural)


def ramp_top(x: float) -> float:
    """Gangway surface height (ship frame) at ship x along a lane, from the deck at HULL_SIDE to the foot."""
    return SHIP_DECK - RAMP_SLOPE * (x - HULL_SIDE)


def prefab_galleon_hull() -> dict:
    """Timber galleon hull (ship frame: bow -Z, starboard +X, waterline y=0, main deck top y=12). Collidable."""
    P = []
    P += [part("B", (0, -7, 2), (10, 4, 96), (0, 0, 0), WOOD_DARK, "Wood"),
          part("B", (0, -3.5, 2), (22, 5, 104), (0, 0, 0), WOOD_DARK, "WoodPlanks"),
          part("B", (0, 1.5, 2), (30, 5, 110), (0, 0, 0), WOOD, "WoodPlanks"),
          part("B", (0, 5.0, 2), (32.4, 2, 111), (0, 0, 0), TEAL, "SmoothPlastic"),
          part("B", (0, 8.5, 2), (33, 5, 112), (0, 0, 0), WOOD_LIGHT, "WoodPlanks"),
          part("B", (0, 10.7, 2), (33.6, 0.8, 112.6), (0, 0, 0), CREAM, "SmoothPlastic")]
    # faceted prow: two converging side planks, a filler, the stem and the bowsprit
    for side in (-1, 1):
        P.append(part("B", (side * 7.6, 3, -60.5), (3, 18, 22.5), (0, side * 43.0, 0), WOOD, "WoodPlanks"))
        P.append(part("B", (side * 7.4, 5.0, -60.3), (3.3, 2, 22.8), (0, side * 43.0, 0), TEAL, "SmoothPlastic"))
    P += [part("B", (0, 3, -55), (26, 18, 8), (0, 0, 0), WOOD, "WoodPlanks"),
          part("B", (0, 6, -69), (3, 24, 3), (-15, 0, 0), WOOD_DARK, "Wood"),
          beam((0, 14, -66), (0, 26, -92), 2.4, 2.4, WOOD_DARK, "Wood", shape="C", nc=True)]
    # forecastle (bow, top y=17) and stern castle (quarterdeck top y=20)
    P += [part("B", (0, 14.5, -45), (30, 5, 20), (0, 0, 0), WOOD_LIGHT, "WoodPlanks"),
          part("B", (0, 16, 47), (33, 8, 22), (0, 0, 0), WOOD, "WoodPlanks"),
          part("B", (0, 19.2, 47), (33.4, 0.6, 22.4), (0, 0, 0), CREAM, "SmoothPlastic"),
          part("B", (0, -1, 60), (2, 14, 5), (0, 0, 0), WOOD_DARK, "Wood")]
    # stern: windows, gold trim, lanterns
    for wx in (-9, 0, 9):
        P.append(part("B", (wx, 15.5, 58.3), (4.4, 4.4, 0.5), (0, 0, 0), "#f2b24a", "SmoothPlastic", nc=True,
                      light=[16, 0.9, "#ffb35c", False] if wx == 0 else None))  # v29 D12: amber glass, not a Neon block
        P.append(part("B", (wx, 15.5, 58.15), (5.6, 5.6, 0.4), (0, 0, 0), GOLD, "SmoothPlastic", nc=True))
    P.append(part("B", (0, 12.4, 58.4), (24, 1.2, 0.4), (0, 0, 0), GOLD, "SmoothPlastic", nc=True))
    for side in (-1, 1):
        P += [part("B", (side * 15.0, 25.0, 57.5), (0.8, 6, 0.8), (0, 0, 0), IRON, "Metal", nc=True),
              part("B", (side * 15.0, 28.6, 57.5), (2.2, 2.6, 2.2), (0, 45, 0), "#ffcf7a", "Neon", nc=True,
                   light=[40, 1.6, "#ffc070", False])]
    # bulwarks: collidable rails round the main deck (openings on starboard for the gangways), quarterdeck rails
    def rail(x, z0, z1, y=13.5, h=3.0):
        return [part("B", (x, y, (z0 + z1) / 2), (1.2, h, z1 - z0), (0, 0, 0), WOOD_DARK, "WoodPlanks"),
                part("B", (x, y + h / 2 + 0.2, (z0 + z1) / 2), (1.8, 0.4, z1 - z0), (0, 0, 0), CREAM, "SmoothPlastic", nc=True)]
    P += rail(-16.2, -35, 36)
    # starboard: openings exactly as wide as the gangways (GANGWAY_W) and the plank (PLANK_Z0..Z1), nothing else
    fz, az = GANGWAY_Z["Fore"], GANGWAY_Z["Aft"]
    hw = GANGWAY_W / 2
    e = 0.1  # each bulwark stub laps 0.1 over the edge of the ramp or plank beside it: no slot at the seam
    P += (rail(HULL_SIDE, -35, fz - hw + e) + rail(HULL_SIDE, fz + hw - e, PLANK_Z0 + e)
          + rail(HULL_SIDE, PLANK_Z1 - e, az - hw + e) + rail(HULL_SIDE, az + hw - e, 36))
    P += rail(-16.2, 36, 58, y=21.5) + rail(16.2, 36, 58, y=21.5)
    P += [part("B", (0, 21.5, 58), (33.6, 3, 1.2), (0, 0, 0), WOOD_DARK, "WoodPlanks")]
    P += rail(-15.2, -55, -35, y=18.4, h=2.4) + rail(15.2, -55, -35, y=18.4, h=2.4)
    # bow rail across the forecastle's front edge: the 5-stud drop onto the prow top was a dead end (I2-08)
    P += [part("B", (0, 18.4, -54.4), (31.6, 2.4, 1.2), (0, 0, 0), WOOD_DARK, "WoodPlanks"),
          part("B", (0, 19.8, -54.4), (32.2, 0.4, 1.8), (0, 0, 0), CREAM, "SmoothPlastic", nc=True)]
    # gunports and cannons
    for side in (-1, 1):
        for gz in (-36, -24, -12, 0, 12, 24, 36):
            P.append(part("B", (side * 16.8, 7.4, gz), (0.5, 3.2, 3.6), (0, 0, 0), "#2a1d14", "SmoothPlastic", nc=True))
            P.append(part("C", (side * 18.0, 7.4, gz), (1.6, 3.2, 1.6), (0, 0, 90), IRON, "Metal", nc=True))
    return {"parts": P}


def prefab_galleon_decks() -> dict:
    """Drivable decks: main deck (y 12), ramps up to the forecastle (y 17) and quarterdeck (y 20). WoodPlanks get the
    SR_ISLAND_ShipDeck variant (plan materials.partRules)."""
    P = [part("B", (0, 11.6, 0.5), (31.4, 0.8, 71), (0, 0, 0), DECK, "WoodPlanks"),
         part("B", (0, 16.6, -45), (29, 0.8, 20), (0, 0, 0), DECK, "WoodPlanks"),
         part("B", (0, 19.6, 47), (32.6, 0.8, 22), (0, 0, 0), DECK, "WoodPlanks")]
    # ramp main deck -> quarterdeck (port side, rises 8 over 34 towards the stern)
    ang = math.degrees(math.atan2(8, 34))
    P.append(part("B", (-9, 15.5, 19), (10, 1, math.hypot(8, 34)), (-ang, 0, 0), WOOD_LIGHT, "WoodPlanks"))
    # ramp main deck -> forecastle (PORT side, rises 5 over 24 towards the bow). It stood starboard at x 4..14, right
    # inboard of the fore gangway opening: a car coming aboard met its side step at once (I2-03); the deck inboard of
    # both gangway openings is now clear (x >= 4 between z -35 and 36, but the plank kicker and the capstan).
    ang2 = math.degrees(math.atan2(5, 24))
    P.append(part("B", (-9, 14.0, -23), (10, 1, math.hypot(5, 24)), (ang2, 0, 0), WOOD_LIGHT, "WoodPlanks"))
    # hatch, capstan and cargo for cover (the cargo moved from the port main deck, where the stair now runs, to the
    # forecastle's starboard side)
    P += [part("B", (0, 13.0, 14), (10, 2, 8), (0, 0, 0), WOOD_DARK, "WoodPlanks"),
          part("C", (0, 13.6, -12), (4.5, 3.2, 4.5), (0, 0, 0), WOOD_DARK, "Wood"),
          part("B", (9, 19.0, -48), (5, 4, 5), (0, 15, 0), WOOD_LIGHT, "WoodPlanks"),
          part("B", (8.5, 22.4, -48.5), (3.6, 2.8, 3.6), (0, 40, 0), WOOD, "WoodPlanks")]
    return {"parts": P}


def prefab_galleon_plank() -> dict:
    """Walk the Plank (ship frame, placed with the hull): a 12 deg kicker from the main deck out over the starboard
    side between the main mast and the hatch. No pad, no trigger: the car's own speed launches it (a car rolling up
    from rest on the deck leaves the lip at ~60 studs/s and lands on the Plank Dune ~30 studs out; anything slower
    drops onto the dry bank against the hull, anything faster lands further along the dune and its spit)."""
    ang = math.radians(PLANK_DEG)
    L = (PLANK_X1 - PLANK_X0) / math.cos(ang)
    w = PLANK_Z1 - PLANK_Z0
    zc = (PLANK_Z0 + PLANK_Z1) / 2
    lip_y = SHIP_DECK + (PLANK_X1 - PLANK_X0) * math.tan(ang)
    mx, my = (PLANK_X0 + PLANK_X1) / 2, (SHIP_DECK + lip_y) / 2
    t = 1.0  # board thickness: its top face runs from the deck edge (x0, deck) to the lip
    P = [part("B", (mx + math.sin(ang) * t / 2, my - math.cos(ang) * t / 2, zc), (L, t, w), (0, 0, PLANK_DEG),
              DECK, "WoodPlanks")]
    for side in (-1, 1):  # gold edge trim and a hanging rope (decor)
        z = zc + side * (w / 2 + 0.15)
        P.append(part("B", (mx, my - 0.25, z), (L, 0.5, 0.3), (0, 0, PLANK_DEG), GOLD, "SmoothPlastic", nc=True))
    P += [beam((HULL_SIDE + 0.8, 6.0, zc), (PLANK_X1 - 1.0, lip_y - 0.9, zc), 0.8, 0.8, WOOD_DARK, "Wood", nc=True),
          part("B", (PLANK_X1 - 0.6, lip_y + 2.4, PLANK_Z1 + 0.7), (0.4, 4.8, 0.4), (0, 0, 0), WOOD_DARK, "Wood",
               nc=True),
          part("B", (PLANK_X1 - 0.6, lip_y + 4.0, PLANK_Z1 + 2.0), (0.2, 1.8, 2.6), (0, 0, 0), "#26262c", "Fabric",
               nc=True)]
    return {"parts": P}


def prefab_galleon_rigging() -> dict:
    P = []
    masts = [(-32, 12, 70, 2.6), (-2, 12, 92, 3.0), (48, 20, 56, 2.2)]
    for z, y0, h, dia in masts:
        P.append(part("C", (0, y0 + h / 2, z), (dia, h, dia), (0, 0, 0), WOOD_DARK, "Wood"))
    # yards and square sails (two slightly billowed halves each)
    sails = [(-32, 30, 18, 34), (-32, 54, 16, 28), (-2, 33, 22, 38), (-2, 62, 20, 32), (-2, 89, 10, 20)]
    for z, ymid, h, w in sails:
        P.append(part("B", (0, ymid + h / 2 + 1.2, z), (w + 6, 1.4, 1.4), (0, 0, 0), WOOD_DARK, "Wood", nc=True))
        for side in (-1, 1):
            P.append(part("B", (side * w / 4, ymid, z - 1.4), (w / 2 + 0.4, h, 0.6), (0, side * -10.0, 0),
                          SAIL if side < 0 else SAIL_SHADE, "Fabric", nc=True))
        P.append(part("B", (0, ymid - h / 2 + 0.3, z - 0.8), (w * 0.9, 0.8, 0.8), (0, 0, 0), CREAM, "Fabric", nc=True))
    # mizzen fore-and-aft sail, jib, crow's nest, flag
    P += [part("B", (0, 44, 50.5), (0.6, 24, 22), (8, 0, 0), SAIL_SHADE, "Fabric", nc=True),
          beam((0, 21, -84), (0, 52, -40), 0.4, 9, SAIL, "Fabric", nc=True),
          beam((0, 30, -74), (0, 62, -36), 0.4, 6, SAIL_SHADE, "Fabric", nc=True),
          part("C", (0, 78, -2), (8, 3, 8), (0, 0, 0), WOOD, "WoodPlanks", nc=True),
          part("B", (0, 106, 3.8), (0.3, 6, 8), (0, 0, 0), "#26262c", "Fabric", nc=True),
          part("B", (0.25, 106, 3.8), (0.2, 2.2, 2.6), (0, 0, 45), CREAM, "Fabric", nc=True)]
    # shrouds (non-colliding rope beams)
    for z, y0, h, _ in masts:
        for side in (-1, 1):
            for dz in (-4, 0, 4):
                P.append(beam((side * 16, y0 + 2, z + dz), (side * 1.5, y0 + h * 0.78, z), 0.35, 0.35, "#b49a72", nc=True))
    return {"parts": P}


def prefab_gangway() -> dict:
    """Ramp from the starboard main deck (local origin at the hull side, deck height y 12, lane along +x) down onto
    the Plank Dune. GANGWAY_W wide (it fills its bulwark opening), collidable plank rails RAIL_H over the surface with
    skirts SKIRT_DROP under it (the space beneath is closed: no fall off the side, no car wedged under it), flared
    FLARE_DEG at the deck end and at the foot, and a landing plank on the sand past the foot."""
    run, drop = RAMP_RUN, SHIP_DECK - RAMP_FOOT_Y
    L = math.hypot(run, drop)
    ang = math.degrees(math.atan2(drop, run))
    a = math.radians(ang)
    hw = GANGWAY_W / 2
    t = 1.0
    # board: top face from (0, 12) to (run, foot), i.e. the ramp_top() line
    P = [part("B", (run / 2 - math.sin(a) * t / 2, 12 - drop / 2 - math.cos(a) * t / 2, 0), (L, t, GANGWAY_W),
              (0, 0, -ang), WOOD_LIGHT, "WoodPlanks"),
         # threshold over the bulwark line: the deck planking stops at x -0.5, the hull top under it is 0.9 lower
         part("B", (-0.1, SHIP_DECK - 0.4, 0), (1.4, 0.8, GANGWAY_W), (0, 0, 0), DECK, "WoodPlanks")]
    # Vertical spans over the ramp surface: rail -0.5..+RAIL_H, skirt -SKIRT_DROP..-0.5 (centre offsets below). A block
    # rotated with the ramp spans height / cos(ang) vertically, so each is sized in its own frame.
    rail_c, skirt_c = (RAIL_H - 0.5) / 2, -(SKIRT_DROP + 0.5) / 2
    for side in (-1, 1):
        z = side * (hw + RAIL_T / 2)
        P.append(part("B", (run / 2, 12 - drop / 2 + rail_c, z), (L, (RAIL_H + 0.5) * math.cos(a), RAIL_T),
                      (0, 0, -ang), WOOD_DARK, "WoodPlanks"))
        P.append(part("B", (run / 2, 12 - drop / 2 + skirt_c, z), (L, (SKIRT_DROP - 0.5) * math.cos(a), RAIL_T),
                      (0, 0, -ang), WOOD, "WoodPlanks"))
        P.append(part("B", (run / 2, 12 - drop / 2 + RAIL_H + 0.2, z), (L, 0.4, RAIL_T + 0.6), (0, 0, -ang), CREAM,
                      "SmoothPlastic", nc=True))
        # flares: rail stubs at FLARE_DEG to the lane, opening the mouth inboard on the deck and outward at the foot
        f = math.radians(FLARE_DEG)
        for x0, y0, dirx in ((0.0, SHIP_DECK, -1.0), (run, RAMP_FOOT_Y, 1.0)):
            cx = x0 + dirx * math.cos(f) * FLARE_LEN / 2
            cz = side * (hw + RAIL_T / 2 + math.sin(f) * FLARE_LEN / 2)
            yaw = FLARE_DEG * side * -dirx  # local +X of the stub along the flare line (rotY maps +X to (cos, -sin))
            P.append(part("B", (cx, y0 + RAIL_H / 2, cz), (FLARE_LEN, RAIL_H, RAIL_T), (0, yaw, 0), WOOD_DARK,
                          "WoodPlanks"))
        # rope posts on the rail (decor)
        for k in range(4):
            x = 3 + k * (run - 6) / 3
            P.append(part("B", (x, ramp_top(HULL_SIDE + x) + RAIL_H + 0.9, z), (0.7, 1.4, 0.7), (0, 0, 0), WOOD_DARK,
                          "Wood", nc=True))
    # landing plank on the dune past the foot, wide enough for the foot flares
    fw = GANGWAY_W + 2 * (RAIL_T + math.sin(math.radians(FLARE_DEG)) * FLARE_LEN) + 2
    P.append(part("B", (run + FOOT_PLANK / 2, RAMP_FOOT_Y - 3.4, 0), (FOOT_PLANK, 6.8, fw), (0, 0, 0), WOOD_DARK,
                  "WoodPlanks"))
    return {"parts": P}


def prefab_anchor_chain() -> dict:
    P = []
    for k in range(9):
        a = (2.0 * k, 9.0 - 2.2 * k, -2.4 * k)
        b = (2.0 * (k + 1), 9.0 - 2.2 * (k + 1), -2.4 * (k + 1))
        P.append(beam(a, b, 0.9, 0.5, IRON, "Metal", nc=True))
    return {"parts": P}


def prefab_lighthouse() -> dict:
    P = [part("B", (0, 3, 0), (34, 6, 34), (0, 0, 0), STONE_DARK, "Slate"),
         part("B", (0, 3, 0), (34, 6, 34), (0, 45, 0), STONE, "Slate"),
         part("B", (0, 7, 0), (26, 2, 26), (0, 22.5, 0), STONE_LIGHT, "Slate")]
    y = 8.0
    for k in range(6):
        w = 21.0 - k * 1.4
        col = CREAM if k % 2 == 0 else "#d4553f"
        P.append(part("B", (0, y + 6, 0), (w, 12, w), (0, 0, 0), col, "SmoothPlastic"))
        P.append(part("B", (0, y + 6, 0), (w, 12, w), (0, 45, 0), col, "SmoothPlastic"))
        y += 12
    # gallery, lantern room, roof cone
    P += [part("B", (0, y + 0.8, 0), (20, 1.6, 20), (0, 22.5, 0), STONE, "Slate"),
          part("B", (0, y + 0.8, 0), (20, 1.6, 20), (0, 67.5, 0), STONE, "Slate")]
    for k in range(8):
        a = math.radians(22.5 + 45 * k)
        P.append(part("B", (9.4 * math.cos(a), y + 3.2, 9.4 * math.sin(a)), (0.6, 3.2, 0.6), (0, 0, 0), IRON, "Metal", nc=True))
    P += [part("B", (0, y + 7, 0), (11, 10, 11), (0, 0, 0), "#cfefff", "Glass", nc=True, a=0.35),
          part("B", (0, y + 7, 0), (11, 10, 11), (0, 45, 0), "#cfefff", "Glass", nc=True, a=0.35),
          part("B", (0, y + 7, 0), (5, 5, 5), (0, 45, 0), "#fff1c0", "Neon", nc=True, light=[60, 3.0, "#fff1c0", False]),
          part("K", (0, y + 16, 0), (15, 8, 15), (0, 0, 0), "#c8453a", "SmoothPlastic", nc=True, n=8),
          part("S", (0, y + 20.6, 0), (2.4, 2.4, 2.4), (0, 0, 0), GOLD, "Metal", nc=True)]
    return {"parts": P}


def prefab_palm(height: float, lean: float, seed: int) -> dict:
    rng = random.Random(seed)
    P = []
    segs = 6
    pts = []
    for k in range(segs + 1):
        t = k / segs
        pts.append((lean * t * t, height * t, 0.0))
    for k in range(segs):
        w = 3.0 - 1.2 * k / segs
        col = "#8a6440" if k % 2 == 0 else "#a07a4e"
        P.append(beam(pts[k], pts[k + 1], w, w, col, "Wood", nc=k >= 2))
        P.append(part("B", pts[k + 1], (w + 0.6, 0.7, w + 0.6), (0, 45 * (k % 2), 0), "#6f4f32", "Wood", nc=True))
    top = pts[-1]
    greens = ["#6a9a3e", "#557f34", "#82a94c", "#719f40"]  # L61: muted palm greens (were neon #4fae3c..#69c247)
    n_fronds = 8
    for f in range(n_fronds):
        phi = 2 * math.pi * f / n_fronds + rng.uniform(-0.15, 0.15)
        L1, L2 = 8.0 + rng.uniform(-1, 1), 9.0 + rng.uniform(-1.5, 1.5)
        e1, e2 = math.radians(18 + rng.uniform(-6, 6)), math.radians(-32 + rng.uniform(-8, 8))
        d1 = (math.cos(phi) * math.cos(e1), math.sin(e1), math.sin(phi) * math.cos(e1))
        p1 = (top[0] + d1[0] * L1, top[1] + d1[1] * L1, top[2] + d1[2] * L1)
        d2 = (math.cos(phi) * math.cos(e2), math.sin(e2), math.sin(phi) * math.cos(e2))
        p2 = (p1[0] + d2[0] * L2, p1[1] + d2[1] * L2, p1[2] + d2[2] * L2)
        g = greens[f % len(greens)]
        P.append(beam(top, p1, 4.6, 0.5, g, nc=True))
        P.append(beam(p1, p2, 3.6, 0.5, greens[(f + 1) % len(greens)], nc=True))
    for c in range(3):
        a = 2 * math.pi * c / 3 + 0.4
        P.append(part("S", (top[0] + 1.3 * math.cos(a), top[1] - 1.2, top[2] + 1.3 * math.sin(a)), (1.6, 1.6, 1.6),
                      (0, 0, 0), "#6b4a24", "SmoothPlastic", nc=True))
    return {"parts": P}


def prefab_hut(seed: int) -> dict:
    rng = random.Random(seed)
    straw = "#d9b56a" if seed % 2 == 0 else "#cfa85c"
    P = [part("B", (0, 1.4, 0), (22, 1.2, 20), (0, 0, 0), WOOD_LIGHT, "WoodPlanks")]
    for sx in (-1, 1):
        for sz in (-1, 1):
            P.append(part("C", (sx * 10, 6.5, sz * 9), (1.4, 13, 1.4), (0, 0, 0), WOOD_DARK, "Wood"))
    bamboo = "#d8c08a"
    P += [part("B", (0, 6, 8.6), (18, 8, 0.8), (0, 0, 0), bamboo, "WoodPlanks"),
          part("B", (-9.6, 6, 0), (0.8, 8, 16), (0, 0, 0), bamboo, "WoodPlanks"),
          part("B", (9.6, 6, 0), (0.8, 8, 16), (0, 0, 0), bamboo, "WoodPlanks"),
          part("B", (-6, 6, -8.6), (6, 8, 0.8), (0, 0, 0), bamboo, "WoodPlanks"),
          part("B", (6, 6, -8.6), (6, 8, 0.8), (0, 0, 0), bamboo, "WoodPlanks"),
          part("B", (0, 9, -8.6), (6, 2, 0.8), (0, 0, 0), TEAL, "SmoothPlastic")]
    pitch = 30 + rng.uniform(-3, 3)
    for side in (-1, 1):
        P.append(part("B", (side * 6.6, 14.2, 0), (15.5, 1.4, 25), (0, 0, side * -pitch), straw, "Fabric"))
    P.append(part("B", (0, 18.0, 0), (2.2, 1.8, 26), (0, 0, 0), "#b8914c", "Fabric"))
    P.append(part("B", (0, 4.0, -12), (4, 2, 4), (0, 20, 0), WOOD, "WoodPlanks"))
    return {"parts": P}


def prefab_tiki_torch() -> dict:
    return {"parts": [part("B", (0, 4, 0), (0.9, 8, 0.9), (0, 45, 0), WOOD_DARK, "Wood"),
                      part("B", (0, 8.4, 0), (1.8, 1.4, 1.8), (0, 0, 0), "#7a5232", "Wood", nc=True),
                      part("B", (0, 9.9, 0), (1.2, 1.8, 1.2), (0, 45, 0), FLAME, "Neon", nc=True,
                           light=[22, 1.2, "#ffa64a", False])]}


# Alt2 entry tell. All non-colliding, all neon on navy (no new materials); lights only on the banners (MapLight budget).
CLIFF_AMBER = "#ffb23c"
CLIFF_NAVY = "#14233a"


def prefab_cliff_chevron() -> dict:
    """Upright board on a short post, two stacked up-chevrons (^) facing +Z (the driver, who comes from +Z): says go up."""
    # v28 critic 1.23: two stakes from the board down into the slope (boards on the climb face read as floating);
    # both reach 9 studs under the site ground, so the downhill one still meets the face
    P = [part("B", (sx, -0.5, -0.2), (0.9, 17.0, 0.9), (0, 0, 0), WOOD_DARK, "Wood", nc=True) for sx in (-4.2, 4.2)]
    # v37: the amber trim runs along the board's top edge (at the centre line it crossed both chevrons into an "A")
    P += [part("B", (0, 11.0, 0), (13.0, 11.0, 0.7), (0, 0, 0), CLIFF_NAVY, "SmoothPlastic", nc=True),
         part("B", (0, 16.5, 0.45), (13.8, 0.7, 0.4), (0, 0, 0), CLIFF_AMBER, "Neon", nc=True)]
    for k, y0 in enumerate((8.4, 12.2)):
        for sgn in (-1, 1):  # arm centre 2.3 either side of the apex, 45 deg, 5.4 long
            P.append(part("B", (sgn * 2.3, y0, 0.5), (5.4, 1.5, 0.4), (0, 0, -sgn * 45), CLIFF_AMBER, "Neon", nc=True))
    return {"parts": P}


TURN_BOARD_DEG = 60.0  # heading change over +-100 studs that earns turn boards (ISLAND-2: only the st 4090 bend)
TURN_BOARD_SEAT = 1.5  # the baked voxel ground stands 1.1-1.6 over terrain.height (v37 Studio)


def sharp_turns(fr, length: float, min_deg: float, span: float = 100.0, step: float = 10.0) -> list[tuple[float, int]]:
    """(apex station, +1 right-hand / -1 left-hand) of every bend turning at least min_deg within +-span."""
    def heading(s: float) -> float:
        t = fr(s % length).tangent
        return math.atan2(t[0], -t[2])
    out, cur = [], []
    s = 0.0
    while s <= length:
        d = math.degrees((heading(s + span) - heading(s - span) + math.pi) % (2 * math.pi) - math.pi)
        if abs(d) >= min_deg:
            cur.append((s, d))
        elif cur:
            s_b, d_b = max(cur, key=lambda r: abs(r[1]))
            if out and s_b - out[-1][0] < span * 1.5 and (d_b > 0) == (out[-1][1] > 0):
                if abs(d_b) > abs(out[-1][2]):  # one bend dipping under the threshold is still one bend
                    out[-1] = (s_b, 1 if d_b > 0 else -1, d_b)
            else:
                out.append((s_b, 1 if d_b > 0 else -1, d_b))
            cur = []
        s += step
    return [(r1(a), b) for a, b, _ in out]


def prefab_turn_board(sgn: int) -> dict:
    """Turn sign on two posts: navy board, three amber chevrons pointing +X (sgn 1, a right-hand bend) or -X, face +Z
    (the driver, who comes from +Z). A bar long in x rolled rz runs along (cos rz, sin rz) in (x, y)."""
    P = [part("B", (sx, 1.5, -0.2), (0.7, 12.0, 0.7), (0, 0, 0), WOOD_DARK, "Wood", nc=True) for sx in (-3.9, 3.9)]
    P.append(part("B", (0, 6.6, 0), (10.0, 4.6, 0.6), (0, 0, 0), CLIFF_NAVY, "SmoothPlastic", nc=True))
    for tx in (-2.6, 0.2, 3.0):
        for up in (1, -1):  # upper arm runs down to the tip, lower arm up to it
            P.append(part("B", (sgn * (tx - 1.15), 6.6 + up * 1.15, 0.45), (3.3, 0.9, 0.3), (0, 0, -sgn * up * 45),
                          CLIFF_AMBER, "Neon", nc=True))
    return {"parts": P}


def prefab_cliff_banner() -> dict:
    """Lit flag on a tall pole: the long-range read of the entry from the start grid."""
    P = [part("B", (0, 9.0, 0), (1.0, 18.0, 1.0), (0, 0, 0), WOOD_DARK, "Wood", nc=True),
         part("B", (0, 18.3, 0), (1.8, 1.0, 1.8), (0, 0, 0), CLIFF_AMBER, "Neon", nc=True),
         part("B", (0, 13.0, 0), (0.4, 8.0, 0.4), (0, 0, 0), WOOD_DARK, "Wood", nc=True)]
    for k in range(3):  # a pennant in three overlapping tiers, streaming to +X, narrowing to the tip
        w = 9.0 - 2.6 * k
        P.append(part("B", (0.5 + w / 2, 16.2 - 1.9 * k, 0), (w, 1.9, 0.3), (0, 0, 0), CLIFF_AMBER if k != 1 else "#fff1c9",
                      "Neon", nc=True, light=[28, 1.3, CLIFF_AMBER, False] if k == 0 else None))
    return {"parts": P}


def prefab_cliff_arrow() -> dict:
    """Flat chevron lying on the ground, apex towards -Z (the direction of travel), 0.3 thick.
    v37: a bar long in x yawed ry runs along (cos ry, -sin ry) in (x, z), so the right arm (x > 0) takes ry < 0 to reach
    the apex at the front; it had +45 and every ground chevron on the cliff line pointed back at the driver."""
    P = []
    for sgn in (-1, 1):
        P.append(part("B", (sgn * 2.6, 0.2, -0.9), (7.2, 0.3, 1.8), (0, -sgn * 45, 0), CLIFF_AMBER, "Neon", nc=True))
    return {"parts": P}


def prefab_start_arch() -> dict:
    P = []
    for side in (-1, 1):
        x = side * 31.5
        P += [part("B", (x, 1.5, 0), (5, 3, 5), (0, 45, 0), STONE, "Slate"),
              part("B", (x, 11, 0), (3.2, 18, 3.2), (0, 0, 0), WOOD, "Wood"),
              part("B", (x, 20.5, 0), (4.4, 3, 4.4), (0, 45, 0), TEAL, "SmoothPlastic"),
              part("B", (x, 23, 0), (3.4, 2, 3.4), (0, 0, 0), GOLD, "SmoothPlastic", nc=True)]
    P.append(part("B", (0, 26.5, 0), (68, 1.6, 2.2), (0, 0, 0), WOOD_DARK, "Wood", nc=True))
    for i in range(14):
        for j in range(2):
            P.append(part("B", (-29.25 + i * 4.5, 24.2 - j * 2.4, 0.2), (4.5, 2.4, 0.3), (0, 0, 0),
                          CREAM if (i + j) % 2 == 0 else "#26262c", "Fabric", nc=True))
    # chequered line on the pavers (non-colliding, just above the paver tops)
    for i in range(22):
        for j in range(2):
            P.append(part("B", (-21 + i * 2, 1.15, -1 + j * 2), (2, 0.1, 2), (0, 0, 0),
                          CREAM if (i + j) % 2 == 0 else "#26262c", "SmoothPlastic", nc=True))
    return {"parts": P}


def prefab_bridge_pier(height: float) -> dict:
    """Pier across the deck (local X across the road, Z along it); top at local y 0 = the deck underside."""
    P = [part("B", (0, -height / 2, 0), (50, height, 10), (0, 0, 0), STONE, "Slate"),
         part("B", (0, -height + 2, 0), (54, 4, 13), (0, 0, 0), STONE_DARK, "Slate")]
    for side in (-1, 1):
        P.append(part("B", (side * 26.5, -height / 2, 0), (7.07, height, 7.07), (0, 45, 0), STONE_DARK, "Slate"))
    return {"parts": P}


def prefab_bridge_arch(span: float, rise: float) -> dict:
    """Segmental arch ring plus spandrel faces under the deck between two piers; crown at local y 0 - 0.4."""
    R = (span * span / 4 + rise * rise) / (2 * rise)
    th0 = math.degrees(math.asin(span / 2 / R))
    cy = -0.4 - R
    P = []
    count = 9
    arc = (2 * math.radians(th0) * R / count) * 0.95
    for k in range(count):
        th = math.radians(-th0 + 2 * th0 * (k + 0.5) / count)
        rm = R - 1.6
        u, v = rm * math.sin(th), cy + rm * math.cos(th)
        col = STONE_LIGHT if k == count // 2 else STONE
        P.append(part("B", (0, v, u), (46, 3.2, arc), (math.degrees(th), 0, 0), col, "Slate"))
        top = cy + R * math.cos(th)  # extrados at this voussoir
        h = -0.4 - top
        if h > 0.6:
            for side in (-1, 1):
                P.append(part("B", (side * 23.4, top + h / 2, R * math.sin(th)), (1.6, h, arc + 0.3), (0, 0, 0),
                              STONE_LIGHT, "Slate"))
    return {"parts": P}


def prefab_parapet(length: float, foot: float = PARAPET_FOOT) -> dict:
    """Low stone wall, 3.4 above its base and `foot` below it (the ground under the line falls away)."""
    return {"parts": [part("B", (0, (3.4 - foot) / 2, 0), (2.4, 3.4 + foot, length), (0, 0, 0), STONE, "Slate"),
                      part("B", (0, 3.55, 0), (3.0, 0.3, length), (0, 0, 0), STONE_LIGHT, "Slate", nc=True)]}


def prefab_boardwalk_piles() -> dict:
    return {"parts": [part("C", (-10, -6, 0), (1.6, 12, 1.6), (0, 0, 0), WOOD_DARK, "Wood"),
                      part("C", (10, -6, 0), (1.6, 12, 1.6), (0, 0, 0), WOOD_DARK, "Wood"),
                      part("B", (0, -1.2, 0), (21, 0.8, 1.0), (0, 0, 0), WOOD, "Wood", nc=True)]}


def prefab_rowboat() -> dict:
    return {"parts": [part("B", (0, 0.6, 0), (6, 2.4, 14), (0, 0, 0), WOOD, "WoodPlanks"),
                      part("B", (0, 0.6, -8.2), (4.24, 2.4, 4.24), (0, 45, 0), WOOD, "WoodPlanks"),
                      part("B", (0, 1.9, 0), (6.4, 0.4, 14.4), (0, 0, 0), TEAL, "SmoothPlastic", nc=True),
                      part("B", (0, 1.6, 2), (5.4, 0.5, 1.4), (0, 0, 0), WOOD_LIGHT, "Wood", nc=True),
                      beam((2.6, 2.0, -1), (6.5, 0.0, 2), 0.4, 0.4, WOOD_LIGHT, "Wood", nc=True)]}


def prefab_dock() -> dict:
    P = [part("B", (0, 3.2, -20), (10, 0.8, 44), (0, 0, 0), DECK, "WoodPlanks")]
    for k in range(5):
        for side in (-1, 1):
            P.append(part("C", (side * 4.4, -1.5, -2 - 9 * k), (1.2, 10, 1.2), (0, 0, 0), WOOD_DARK, "Wood"))
    return {"parts": P}


def prefab_crates(seed: int) -> dict:
    rng = random.Random(seed)
    P = []
    for k in range(4):
        s = rng.uniform(3.0, 4.2)
        x, z = rng.uniform(-4, 4), rng.uniform(-4, 4)
        P.append(part("B", (x, s / 2, z), (s, s, s), (0, rng.uniform(0, 90), 0), WOOD_LIGHT if k % 2 else WOOD, "WoodPlanks"))
    P.append(part("C", (5.5, 2.2, -3), (3.2, 4.4, 3.2), (0, 0, 0), "#7a5232", "Wood"))
    P.append(part("C", (5.5, 2.2, -3), (3.5, 0.5, 3.5), (0, 0, 0), IRON, "Metal", nc=True))
    return {"parts": P}


def prefab_buoy() -> dict:
    return {"parts": [part("C", (0, 0.6, 0), (3.2, 2.4, 3.2), (0, 0, 0), "#d4553f", "SmoothPlastic", nc=True),
                      part("C", (0, 2.4, 0), (1.2, 2.4, 1.2), (0, 0, 0), CREAM, "SmoothPlastic", nc=True)]}


# ------------------------------------------------------------------------------------- L61 set-dressing kit
# Critic r0 (evidence/L61/critic_island2_r0.md): "beaches and roadside are empty", "few landmarks at turns", "far
# background and horizon are empty". Cheap block-built pieces in the Raiser faceted style: boulder clusters that frame
# the turns and break up the hills (Rock base material: the SR_ISLAND_Rock override and the part colour carry the
# look), bleached driftwood, a beached skiff, a broken shipwreck landmark, pennant bunting, a smugglers' treasure hoard
# for the cavern hall. Decorative pieces are no-collide; boulders collide only where a car can reach them, and every
# collidable one stays out of the car corridor (the adapt gate checks it) and the water-battle arena.
ROCK_TONES = ["#b9ae9c", "#a89f92", "#c4b596", "#9d978f", "#b3a68e"]


def prefab_rock_cluster(seed: int) -> dict:
    rng = random.Random(seed)
    P = []
    n = 4 + seed % 3
    for k in range(n):
        big = k == 0
        s = rng.uniform(9, 14) if big else rng.uniform(4, 9)
        a = rng.uniform(0, 2 * math.pi)
        d = 0 if big else rng.uniform(5, 10)
        x, z = d * math.cos(a), d * math.sin(a)
        h = s * rng.uniform(0.6, 1.0)
        P.append(part("B", (x, h * 0.35, z), (s, h, s * rng.uniform(0.7, 1.1)),
                      (rng.uniform(-14, 14), rng.uniform(0, 90), rng.uniform(-14, 14)), ROCK_TONES[(seed + k) % 5], "Rock"))
        if big or rng.random() < 0.5:  # a faceted wedge cap: the Raiser chamfer read
            P.append(part("W", (x + rng.uniform(-1, 1), h * 0.35 + h * 0.5, z), (s * 0.8, h * 0.45, s * 0.7),
                          (0, rng.uniform(0, 360), 0), ROCK_TONES[(seed + k + 2) % 5], "Rock"))
    return {"parts": P}


def prefab_driftwood(seed: int) -> dict:
    rng = random.Random(seed)
    P = []
    for k in range(2 + seed % 2):
        L = rng.uniform(10, 18)
        a = rng.uniform(0, math.pi)
        x0, z0 = rng.uniform(-3, 3), rng.uniform(-3, 3)
        p0 = (x0 - L / 2 * math.cos(a), 0.6, z0 - L / 2 * math.sin(a))
        p1 = (x0 + L / 2 * math.cos(a), 0.6 + rng.uniform(0, 1.2), z0 + L / 2 * math.sin(a))
        P.append(beam(p0, p1, 1.4, 1.2, "#cdbfa6" if k % 2 == 0 else "#b8a88c", "Wood", nc=True))
        P.append(beam(p1, (p1[0] + rng.uniform(-3, 3), p1[1] + rng.uniform(1, 3), p1[2] + rng.uniform(-3, 3)), 0.6, 0.6,
                      "#c4b597", "Wood", nc=True))
    return {"parts": P}


def prefab_beached_skiff() -> dict:
    """A small boat keeled over on the sand (local -Z = bow), oars and a coil of rope beside it."""
    P = [part("B", (0, 1.4, 0), (7, 2.8, 16), (0, 0, 14), WOOD, "WoodPlanks", nc=True),
         part("B", (0, 1.4, -9.4), (4.95, 2.8, 4.95), (0, 45, 14), WOOD, "WoodPlanks", nc=True),
         part("B", (-0.4, 2.9, 0), (7.4, 0.4, 16.4), (0, 0, 14), "#c9573f", "SmoothPlastic", nc=True),
         part("B", (0.2, 2.6, 2), (6, 0.5, 1.4), (0, 0, 14), WOOD_LIGHT, "Wood", nc=True),
         beam((5, 0.4, -6), (7, 0.8, 6), 0.5, 0.5, WOOD_LIGHT, "Wood", nc=True),
         part("B", (6.6, 0.8, 6.2), (1.4, 0.3, 3), (0, 10, 0), WOOD_LIGHT, "Wood", nc=True),
         part("C", (-6, 0.5, 3), (1.0, 3.2, 3.2), (0, 0, 0), ROPE, "Fabric", nc=True)]
    return {"parts": P}


def prefab_shipwreck() -> dict:
    """Landmark at the south-east corner: the broken stern half of a galleon run aground and listing, ribs bare where
    the hull split, a snapped mast with a torn sail, a lantern still burning at the stern. Local -Z toward the break."""
    P = []
    list_deg = 16.0
    # hull planking (port side intact, starboard torn open toward the break)
    for k in range(6):
        y = 1.0 + k * 2.6
        w = 22.0 - abs(k - 2.5) * 1.6
        col = WOOD_DARK if k % 2 == 0 else WOOD
        P.append(part("B", (-w / 2, y, 6), (1.4, 2.7, 36 - k * 1.5), (0, 0, list_deg), col, "WoodPlanks", nc=True))
        if k < 3:
            P.append(part("B", (w / 2, y, 14), (1.4, 2.7, 20 - k * 4), (0, 0, list_deg), col, "WoodPlanks", nc=True))
    # stern castle
    P += [part("B", (0, 10, 22), (22, 18, 6), (0, 0, list_deg), WOOD_DARK, "WoodPlanks", nc=True),
          part("B", (0, 20, 21), (18, 4, 8), (0, 0, list_deg), WOOD, "WoodPlanks", nc=True),
          part("B", (-3, 13, 25.2), (3, 3, 0.4), (0, 0, list_deg), "#f2b24a", "SmoothPlastic", nc=True, light=[30, 1.4, "#ffb35c", False]),
          part("B", (4, 13, 25.2), (3, 3, 0.4), (0, 0, list_deg), "#f2b24a", "SmoothPlastic", nc=True)]
    # bare ribs at the break
    for k in range(5):
        z = -12 - k * 4.5
        for side in (-1, 1):
            P.append(beam((side * 10, 1, z), (side * (6 + k), 14 - k * 1.8, z), 1.2, 1.2, "#a88b62", "Wood", nc=True))
    P.append(part("B", (0, 1.4, -14), (3, 2.2, 30), (0, 0, 0), WOOD_DARK, "Wood", nc=True))  # keel
    # snapped mainmast leaning out, torn sail, a teal pennant
    P += [beam((0, 4, 8), (-14, 40, 2), 1.8, 1.8, WOOD_DARK, "Wood", nc=True),
          beam((-9, 30, 4), (-2, 31, 18), 0.7, 0.7, WOOD, "Wood", nc=True),
          part("B", (-8, 23, 9), (0.5, 12, 12), (0, 20, 24), SAIL_SHADE, "Fabric", nc=True),
          part("W", (-8.5, 16, 12), (0.5, 6, 7), (0, 20, 24), SAIL, "Fabric", nc=True),
          part("W", (-14.5, 41.5, 2.6), (0.3, 3, 6), (0, 0, 20), TEAL, "Fabric", nc=True)]
    # spilled cargo
    P += [part("B", (8, 1.5, -24), (3.2, 3.2, 3.2), (0, 30, 8), WOOD_LIGHT, "WoodPlanks", nc=True),
          part("C", (-6, 1.6, -28), (3.0, 3.6, 3.0), (90, 0, 20), "#7a5232", "Wood", nc=True),
          part("B", (2, 0.9, -32), (2.4, 1.8, 2.4), (0, 60, 0), WOOD, "WoodPlanks", nc=True)]
    return {"parts": P}


def bunting_parts(p0, p1, sag: float, seed: int, flag: float = 1.0) -> list:
    """Pennant string from p0 to p1 sagging `sag` in the middle, a hanging pennant on every link."""
    cols = ["#d4553f", TEAL, GOLD, CREAM, "#e98a3a"]
    L = math.dist(p0, p1)
    n = max(4, int(L / (3.4 * flag)))
    pts = []
    for k in range(n + 1):
        t = k / n
        pts.append((p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t - sag * 4 * t * (1 - t),
                    p0[2] + (p1[2] - p0[2]) * t))
    P = []
    for k in range(n):
        P.append(beam(pts[k], pts[k + 1], 0.18, 0.18, "#e8dcc0", "Fabric", nc=True))
        m = ((pts[k][0] + pts[k + 1][0]) / 2, (pts[k][1] + pts[k + 1][1]) / 2 - 1.0 * flag, (pts[k][2] + pts[k + 1][2]) / 2)
        yaw = math.degrees(math.atan2(pts[k + 1][0] - pts[k][0], pts[k + 1][2] - pts[k][2]))
        P.append(part("W", m, (0.15, 2.0 * flag, 1.8 * flag), (180, yaw, 0), cols[(k + seed) % len(cols)], "Fabric", nc=True))
    return P


def prefab_galleon_dressing() -> dict:
    """No-collide festoons for the galleon (ship frame, as prefab_galleon_rigging): pennant lines from the bowsprit
    over the three mastheads to the stern, long streamers at each masthead, lanterns along the rails."""
    tops = [(0, 26, -92), (0, 81, -32), (0, 103, -2), (0, 75, 48), (0, 22, 60)]
    P = []
    for k in range(len(tops) - 1):
        P += bunting_parts(tops[k], tops[k + 1], 5.0, k, flag=1.4)
    for z, top, col in ((-32, 82, "#d4553f"), (-2, 109.5, TEAL), (48, 76, GOLD)):
        P.append(part("W", (0, top - 2.0, z + 6.5), (0.25, 2.2, 12), (0, 0, 0), col, "Fabric", nc=True))
    for z in (-36, -12, 12, 32):
        for side in (-1, 1):
            P += [part("B", (side * 16.6, 16.4, z), (0.5, 4, 0.5), (0, 0, 0), IRON, "Metal", nc=True),
                  part("B", (side * 16.6, 19.0, z), (1.4, 1.8, 1.4), (0, 45, 0), "#ffcf7a", "Neon", nc=True)]
    return {"parts": P}


CORAL = ["#ff7a6b", "#ff9f4a", "#e85c9a", "#b06ce0", "#4fd6c8", "#ffd166"]


def prefab_coral_patch(seed: int) -> dict:
    """Reef colour pops under the shallows: faceted coral heads, branch cones and fans (no-collide)."""
    rng = random.Random(seed)
    P = []
    for k in range(6):
        a = rng.uniform(0, 2 * math.pi)
        d = rng.uniform(0, 7)
        x, z = d * math.cos(a), d * math.sin(a)
        col = CORAL[(seed + k) % len(CORAL)]
        kind = k % 3
        if kind == 0:
            sz = rng.uniform(2.5, 4.0)
            P.append(part("S", (x, sz * 0.3, z), (sz, sz * 0.7, sz), (0, 0, 0), col, "SmoothPlastic", nc=True))
        elif kind == 1:
            h = rng.uniform(2.0, 3.0)  # v28 critic 1.23: every head stays under the water (tops <= 3 over the bed)
            P.append(part("K", (x, h / 2, z), (1.6, h, 1.6), (rng.uniform(-15, 15), 0, rng.uniform(-15, 15)), col,
                          "SmoothPlastic", nc=True, n=5))
        else:
            P.append(part("B", (x, 1.2, z), (0.3, 2.4, 3.4), (0, rng.uniform(0, 180), rng.uniform(-10, 10)), col,
                          "SmoothPlastic", nc=True))
    return {"parts": P}


def prefab_ring_gate(seed: int) -> dict:
    """Pirate dressing for a booster ring (critic r2: rings "read like temp markers"): two rope-lashed spar posts with
    lanterns either side of the deck and a pennant line slung over the ring. Local X across the road, ribbon at y 0;
    no-collide, outside the ring's rim (outer radius ~14 round its centre 8 over the ribbon)."""
    P = []
    for side in (-1, 1):
        x = side * 19.5
        P += [part("C", (x, 15.5, 0), (1.6, 26, 1.6), (0, 0, 0), WOOD_DARK, "Wood", nc=True),
              part("C", (x, 6.5, 0), (2.0, 2.2, 2.0), (0, 0, 0), ROPE, "Fabric", nc=True),
              part("C", (x, 21.0, 0), (2.0, 1.6, 2.0), (0, 0, 0), ROPE, "Fabric", nc=True),
              part("B", (x - side * 1.6, 25.5, 0), (2.4, 0.5, 0.5), (0, 0, 0), IRON, "Metal", nc=True),
              part("B", (x - side * 2.6, 24.0, 0), (1.5, 1.9, 1.5), (0, 45, 0), "#ffcf7a", "Neon", nc=True,
                   light=[24, 1.0, "#ffb35c", False])]
    P += bunting_parts((-19.5, 28.5, 0), (19.5, 28.5, 0), 2.6, seed, flag=1.2)
    return {"parts": P}


def prefab_rope_span(length: float) -> dict:
    """Beach road edge: a driftwood post and a sagging rope to the next post (local -Z), no-collide."""
    P = [part("C", (0, 1.9, 0), (0.9, 3.8, 0.9), (0, 0, 0), "#9c8664", "Wood", nc=True),
         part("C", (0, 3.9, 0), (1.1, 0.4, 1.1), (0, 0, 0), ROPE, "Fabric", nc=True)]
    a, b, m = (0, 3.5, 0), (0, 3.5, -length), (0, 2.6, -length / 2)
    P += [beam(a, m, 0.22, 0.22, ROPE, "Fabric", nc=True), beam(m, b, 0.22, 0.22, ROPE, "Fabric", nc=True)]
    return {"parts": P}


def prefab_bunting(length: float, sag: float, seed: int) -> dict:
    """Pennant string along local Z from -L/2 to +L/2 at local y 0 (the ends), sagging `sag` in the middle."""
    cols = ["#d4553f", TEAL, GOLD, CREAM, "#e98a3a"]
    n = max(4, int(length / 3.4))
    P = []
    pts = []
    for k in range(n + 1):
        t = k / n
        pts.append((0.0, -sag * 4 * t * (1 - t), -length / 2 + length * t))
    for k in range(n):
        P.append(beam(pts[k], pts[k + 1], 0.18, 0.18, "#e8dcc0", "Fabric", nc=True))
        m = ((pts[k][0] + pts[k + 1][0]) / 2, (pts[k][1] + pts[k + 1][1]) / 2 - 1.0, (pts[k][2] + pts[k + 1][2]) / 2)
        P.append(part("W", m, (0.15, 2.0, 1.8), (180, 0, 0), cols[(k + seed) % len(cols)], "Fabric", nc=True))
    return {"parts": P}


def prefab_treasure_hoard() -> dict:
    """Smugglers' hoard in the cavern hall: gold mounds, scattered coins and a few gems, glowing warm."""
    P = [part("S", (0, 0.2, 0), (14, 4.4, 11), (0, 0, 0), GOLD, "Metal", nc=True, light=[36, 1.6, "#ffcf6a", False]),
         part("S", (6, 0.0, 4), (8, 3.0, 7), (0, 30, 0), "#e6b84e", "Metal", nc=True),
         part("S", (-6, 0.0, -3), (7, 2.6, 6), (0, 0, 0), "#e0ac3e", "Metal", nc=True)]
    rng = random.Random(77)
    for k in range(14):
        a = rng.uniform(0, 2 * math.pi)
        d = rng.uniform(6, 12)
        P.append(part("C", (d * math.cos(a), 0.3, d * math.sin(a)), (0.3, 1.4, 1.4), (rng.uniform(-30, 30), 0, 0),
                      GOLD, "Metal", nc=True))
    for k, col in enumerate(("#4fd6c8", "#e0506a", "#7fb2ff", "#4fd6c8")):
        a = 1.3 * k
        P.append(part("B", (3 * math.cos(a), 2.4, 3 * math.sin(a)), (1.1, 1.4, 1.1), (0, 45, 20), col, "Neon", nc=True))
    return {"parts": P}


# skyrally.setDressing (MapAdapter step 7b) for the uploaded ISLAND props (src/shared/PropLibrary.luau). The adapter's
# snap ray starts 60 above pos, so each placement is tested with its whole AABB (yawed footprint from the ground up to
# SNAP_RISE + its height) against the compile gate's corridor boxes plus PROP_MARGIN (tools/map/tests/test_island2.py
# test_set_dressing uses the same box).
SNAP_RISE = 62.0
PROP_MARGIN = 4.0


def prop_library(zone: str = "ISLAND") -> dict:
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
    """World AABB (centre, half) a placement may occupy: yawed footprint, from 2 below pos's ground (pos.y - 2) up to
    SNAP_RISE + the prop height."""
    sx, sy, sz = (v * scale for v in size[:3])
    c, s_ = abs(math.cos(math.radians(yaw))), abs(math.sin(math.radians(yaw)))
    hx, hz = 0.5 * (sx * c + sz * s_), 0.5 * (sx * s_ + sz * c)
    g = pos[1] - 2.0
    top = g + SNAP_RISE + sy
    return np.array([pos[0], (g - 2.0 + top) / 2, pos[2]]), np.array([hx, (top - g + 2.0) / 2, hz])


class Corridor:
    """The compile gate's car-corridor boxes (adapt.segment_box) for filtering placements before the gate runs."""

    def __init__(self, route: routelib.Route):
        import adapt
        self._hit = adapt.aabbs_hit_obb
        self.boxes = []
        wps = route.waypoints
        for i in range(len(wps) - 1):
            b = adapt.segment_box(wps[i].pos, wps[i + 1].pos, CORRIDOR["halfWidth"], CORRIDOR["floor"], CORRIDOR["ceiling"])
            if b is not None:
                self.boxes.append(b)

    def hits(self, centres: np.ndarray, halves: np.ndarray, margin: float = 0.0) -> np.ndarray:
        out = np.zeros(len(centres), bool)
        reach = np.linalg.norm(halves, axis=1).max() + 140.0
        for mid, axes, half in self.boxes:
            near = np.linalg.norm(centres - mid, axis=1) < reach
            idx = np.nonzero(near & ~out)[0]
            if idx.size == 0:
                continue
            h = self._hit(centres[idx], halves[idx] + margin, mid, axes, half)
            out[idx[h]] = True
        return out


# Far islands on the horizon (critic r0 item 12): terrain shells beyond the height grid, inside SEA_FRAME. Each is a
# rock dome, a sea-grass cap and a sand ring at the waterline: (world x, z, rock radius, top over the sea).
FAR_ISLANDS = [(-4700.0, 2380.0, 170.0, 92.0), (-3880.0, 2180.0, 120.0, 52.0), (-5600.0, 2560.0, 120.0, 110.0),
               (-2920.0, 3720.0, 150.0, 66.0), (-2560.0, 4720.0, 200.0, 128.0), (-4200.0, 5920.0, 140.0, 78.0),
               (-3150.0, 5800.0, 110.0, 56.0), (-6420.0, 3620.0, 160.0, 102.0), (-6480.0, 4820.0, 120.0, 68.0)]


def far_island_top(isl, dx: float, dz: float) -> float:
    """Height over the sea of a far island's surface at offset (dx, dz) from its centre (rock dome or grass cap)."""
    _, _, R, H = isl
    d2 = dx * dx + dz * dz
    rock = (H - R) + math.sqrt(max(R * R - d2, 0.0)) if d2 < R * R else -1e9
    rc = R * 0.72
    cap = (H + 3.0 - rc) + math.sqrt(max(rc * rc - d2, 0.0)) if d2 < rc * rc else -1e9
    return max(rock, cap)


# -------------------------------------------------------------------------------------------- jump physics
def car_jump_report(route: routelib.Route, lip: float) -> dict:
    """Ballistic path of a car leaving the crest at `lip` (CarConfig.GRAVITY): airtime and landing station."""
    out = {}
    f = route.frame_at(lip)
    f = routelib.Frame(f.pos, route.frame_at(lip - 0.5).tangent, f.right, f.up, f.bank)  # launch along the kicker
    for v in (128.0, 165.0):
        vh = v * math.hypot(f.tangent[0], f.tangent[2])
        x, air = 0.5, None
        while x < 160:
            t = x / vh
            y = f.pos[1] + v * f.tangent[1] * t - 0.5 * CAR_GRAVITY * t * t
            if y <= route.frame_at(lip + x).pos[1]:
                air = x
                break
            x += 0.25
        peak_gap = 0.0
        xx = 0.5
        while air and xx < air:
            t = xx / vh
            y = f.pos[1] + v * f.tangent[1] * t - 0.5 * CAR_GRAVITY * t * t
            peak_gap = max(peak_gap, y - route.frame_at(lip + xx).pos[1])
            xx += 0.5
        out[str(int(v))] = {"flight": round(air or 0.0, 1), "landing": round(lip + (air or 0.0), 1),
                            "maxGap": round(peak_gap, 2)}
    return out


# ------------------------------------------------------------------------------------------ Alt2 headland wall-ride
def chaikin_path(points, rounds: int) -> np.ndarray:
    P = [np.array(p, float) for p in points]
    for _ in range(rounds):
        Q = [P[0]]
        for a, b in zip(P[:-1], P[1:]):
            Q += [0.75 * a + 0.25 * b, 0.25 * a + 0.75 * b]
        Q.append(P[-1])
        P = Q
    return np.array(P)


def resample_path(P: np.ndarray, step: float) -> np.ndarray:
    d = np.r_[0.0, np.cumsum(np.hypot(*np.diff(P, axis=0).T))]
    n = max(2, int(round(d[-1] / step)) + 1)
    t = np.linspace(0.0, d[-1], n)
    return np.c_[np.interp(t, d, P[:, 0]), np.interp(t, d, P[:, 1])]


def cliff_line(terrain: Terrain, fr) -> tuple[list[list[float]], dict]:
    """World points of Alt2 and its report. Ends sit exactly on the ribbon at CLIFF_JOIN / CLIFF_REJOIN; every point
    between is on the baked ground (grid height) minus CLIFF_SINK."""
    j, r = fr(CLIFF_JOIN), fr(CLIFF_REJOIN)
    jl, rl = (j.pos[0] - ORIGIN[0], j.pos[2] - ORIGIN[2]), (r.pos[0] - ORIGIN[0], r.pos[2] - ORIGIN[2])
    Q = resample_path(chaikin_path([jl] + CLIFF_CTRL + [rl], 3), CLIFF_STEP)
    pts, hs = [], []
    for i, (x, z) in enumerate(Q):
        g = terrain.height(float(x), float(z))
        hs.append(g)
        if i == 0:
            pts.append([r3(j.pos[0]), r3(j.pos[1]), r3(j.pos[2])])
        elif i == len(Q) - 1:
            pts.append([r3(r.pos[0]), r3(r.pos[1]), r3(r.pos[2])])
        else:
            pts.append([r3(ORIGIN[0] + x), r3(g + SEA - CLIFF_SINK), r3(ORIGIN[2] + z)])
    seg = np.hypot(*np.diff(Q, axis=0).T)
    h = np.array(hs)
    win = np.convolve(np.diff(h), np.ones(3), "valid") / np.convolve(seg, np.ones(3), "valid")
    ang = np.degrees(np.unwrap(np.arctan2(*np.diff(Q, axis=0).T[::-1])))
    rep = {"length": r1(seg.sum()), "points": len(pts), "peak": r1(h.max() ), "maxSlope48": r3(np.abs(win).max()),
           "maxTurnDeg": r1(np.abs(np.diff(ang)).max()), "endAngleDeg": 0.0}
    t_end = Q[-1] - Q[-2]
    t_end = t_end / np.hypot(*t_end)
    cosa = float(t_end[0] * r.tangent[0] + t_end[1] * r.tangent[2])
    rep["endAngleDeg"] = r1(math.degrees(math.acos(max(-1.0, min(1.0, cosa)))))
    assert h[1:-1].min() >= 1.6, ("Alt2 wet", h.min())  # dry ground only: the grid is sea level + 0 at the shore
    assert rep["maxSlope48"] <= 0.8, rep  # 48-stud windows: <= 39 deg along the path
    assert rep["endAngleDeg"] <= 15.0, rep  # merges along the road, never across it towards the sea edge
    return pts, rep


def ground_normal(terrain: Terrain, x: float, z: float, e: float = 2.0) -> np.ndarray:
    gx = (terrain.height(x + e, z) - terrain.height(x - e, z)) / (2 * e)
    gz = (terrain.height(x, z + e) - terrain.height(x, z - e)) / (2 * e)
    n = np.array([-gx, 1.0, -gz])
    return n / np.linalg.norm(n)


def cliff_rings(terrain: Terrain, pts: list[list[float]]) -> list[dict]:
    """CLIFF_RINGS as gameplay rings on the line: world pos CLIFF_RING_LIFT over the ground along its normal, facing the
    line's travel direction, station = the line's mapped station (RouteBranch.cliffProgress)."""
    P = np.array(pts, float)
    cum = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]  # 3D: RouteBranch line length / along
    hcum = np.r_[0.0, np.cumsum(np.hypot(*np.diff(P[:, [0, 2]], axis=0).T))]
    out = []
    for name, along in CLIFF_RINGS:
        i = int(np.searchsorted(hcum, along))
        t = (along - hcum[i - 1]) / (hcum[i] - hcum[i - 1])
        along3 = float(cum[i - 1] + (cum[i] - cum[i - 1]) * t)
        x = float(P[i - 1][0] + (P[i][0] - P[i - 1][0]) * t) - ORIGIN[0]
        z = float(P[i - 1][2] + (P[i][2] - P[i - 1][2]) * t) - ORIGIN[2]
        n = ground_normal(terrain, x, z)
        look = P[min(i + 1, len(P) - 1)] - P[max(i - 2, 0)]
        look = look / np.linalg.norm(look)
        pos = np.array([ORIGIN[0] + x, terrain.height(x, z) + SEA, ORIGIN[2] + z]) + n * CLIFF_RING_LIFT
        out.append({"name": name, "station": r1(CLIFF_JOIN + (CLIFF_REJOIN - CLIFF_JOIN) * along3 / cum[-1]),
                    "lateral": 0, "height": 0, "coin": False, "coinId": None, "line": CLIFF_ID, "along": along,
                    "pos": [r3(v) for v in pos], "look": [r3(v) for v in look], "up": [r3(v) for v in n]})
    return out


# ---------------------------------------------------------------------------------------------- the sky faces
def make_sky() -> None:
    """Late-afternoon Sunshine sky (guide: deep cobalt overhead, big painterly cumulus to the left). L61 grade: the
    horizon warms to peach-cream under the low west sun, the cumulus tops are sun-gilded and their bellies lavender.
    Side faces are horizontally periodic so the four identical faces join; the side's top row equals the up face's
    edge colour and its bottom row the down face's edge colour."""
    from PIL import Image, ImageFilter

    N = 512
    top = np.array([40, 104, 196], float)       # cobalt at the side face's top edge (= up face edge)
    zenith = np.array([30, 88, 182], float)
    mid = np.array([132, 178, 222], float)      # soft blue a third of the way down
    horizon = np.array([250, 222, 186], float)  # warm peach-cream haze at the horizon line (late afternoon)
    sea = np.array([66, 146, 168], float)       # below the horizon (rarely visible past the far sea)
    yy = np.arange(N)[:, None] / (N - 1)
    # side: 0..0.5 sky (top -> horizon), 0.5..1 below horizon
    t = np.clip(yy / 0.5, 0, 1)
    t1 = np.clip(t / 0.62, 0, 1) ** 1.3
    t2 = np.clip((t - 0.62) / 0.38, 0, 1) ** 1.4
    sky = np.where((t < 0.62)[..., None], top * (1 - t1)[..., None] + mid * t1[..., None],
                   mid * (1 - t2)[..., None] + horizon * t2[..., None])
    below = np.clip((yy - 0.5) / 0.5, 0, 1)
    low = horizon * (1 - below)[..., None] + sea * below[..., None]
    side = np.where((yy < 0.5)[..., None], sky, low) * np.ones((1, N, 1))
    rng = np.random.default_rng(20261018)
    xs = np.arange(N)[None, :]
    Y = yy * (N - 1) * np.ones((1, N))
    cover = np.zeros((N, N))
    lit = np.zeros((N, N))
    # cumulus banks: flat bases just above the horizon, cauliflower domes, wrapped horizontally (cx, base, width, height)
    banks = [(70, 238, 150, 92), (215, 244, 70, 40), (330, 236, 120, 70), (455, 246, 60, 30)]
    for cx, base, width, height in banks:
        for _ in range(int(width / 5)):
            t = rng.uniform(-1, 1)
            px = cx + t * width / 2
            dome = math.sqrt(max(0.0, 1 - t * t))
            r = rng.uniform(0.35, 0.6) * height * (0.45 + 0.55 * dome)
            py = base - r * 0.55 - rng.uniform(0, 0.55) * height * dome
            dx = (xs - px + N / 2) % N - N / 2
            dy = Y - py
            q = (dx * dx + dy * dy) / (r * r)
            blob = np.clip((1.0 - q) * 3.0, 0, 1) * np.clip((base - Y) / 3.0 + 0.5, 0, 1)
            cover = np.maximum(cover, blob)
            # lighting: sun from upper left -> bright upper-left rims, shaded undersides
            l = np.clip(0.5 - (dy / r) * 0.6 - (dx / r) * 0.25, 0, 1) * blob
            lit = np.maximum(lit, l)
    cover *= (yy < 0.5)
    hi = np.array([255, 238, 208], float)       # sun-gilded tops
    lo = np.array([178, 168, 200], float)       # lavender bellies
    lt = np.clip(lit / np.maximum(cover, 1e-6), 0, 1)
    ccol = lo + (hi - lo) * (lt ** 0.8)[..., None]
    side = side * (1 - cover)[..., None] + ccol * cover[..., None]
    # blur with horizontal wrap (three tiles, keep the middle) so the four faces still join after softening
    tiled = np.concatenate([side, side, side], axis=1)
    blurred = Image.fromarray(np.clip(tiled, 0, 255).astype(np.uint8), "RGB").filter(ImageFilter.GaussianBlur(1.4))
    arr = np.array(blurred).astype(float)[:, N:2 * N]
    # keep the seam rows exact after the blur
    arr[:3] = top
    arr[-3:] = sea
    side_img = Image.fromarray(arr.astype(np.uint8), "RGB")
    # up: zenith in the centre easing to the side-top colour at every edge; a few wisps
    u = (np.arange(N) - (N - 1) / 2) / ((N - 1) / 2)
    UX, UY = np.meshgrid(u, u)
    edge = np.clip(np.maximum(abs(UX), abs(UY)), 0, 1) ** 2
    up = zenith * (1 - edge)[..., None] + top * edge[..., None]
    wisp = np.clip(value_noise(UX * 260, UY * 260, 150.0, 9), 0, 1) * (1 - edge) * 0.12
    up = up * (1 - wisp)[..., None] + np.array([235, 244, 255], float) * wisp[..., None]
    up_img = Image.fromarray(np.clip(up, 0, 255).astype(np.uint8), "RGB")
    down = sea * np.ones((N, N, 3))
    SKY_DIR.mkdir(parents=True, exist_ok=True)
    side_img.save(SKY_DIR / "side.png", optimize=False)
    up_img.save(SKY_DIR / "up.png", optimize=False)
    Image.fromarray(down.astype(np.uint8), "RGB").save(SKY_DIR / "down.png", optimize=False)


# ------------------------------------------------------------------------------------------- material variants
# L61: T7_COAST_ROCK (no baked grass ledges), T8_SEA_GRASS (no tile frame) and T9_COVE_COBBLE (no terracotta grid)
# replace T3/T4/T6 (tools/vfx/make_island_textures.py).
VARIANT_SET = {
    "SR_ISLAND_Sand": {"base": "Sand", "tex": "T1_BEACH_SAND", "studsPerTile": 40},
    "SR_ISLAND_WaterBed": {"base": "Limestone", "tex": "T2_SHALLOW_WATER_BED", "studsPerTile": 56},
    "SR_ISLAND_Rock": {"base": "Rock", "tex": "T7_COAST_ROCK", "studsPerTile": 36},
    "SR_ISLAND_Grass": {"base": "Grass", "tex": "T8_SEA_GRASS", "studsPerTile": 56},
    "SR_ISLAND_ShipDeck": {"base": "WoodPlanks", "tex": "T5_SHIP_DECK", "studsPerTile": 12},
    # v28 critic 1.17: large irregular flagstones, 2-3x the old 16-stud tile (the cobbles read as small hex tiles)
    "SR_ISLAND_Cobble": {"base": "Cobblestone", "tex": "T9_COVE_COBBLE", "studsPerTile": 24},  # v29 D8: 40 -> 24 (honeycomb stopgap),
    "SR_ISLAND_Masonry": {"base": "Slate", "tex": "T7_COAST_ROCK", "studsPerTile": 20},
    # v28 critic 1.17: the cavern road, darker grey flagstones at the same large scale (same textures as Masonry, so
    # the engine TexturePack captured for that ColorMap|NormalMap pair serves it too)
    "SR_ISLAND_Flagstone": {"base": "Slate", "tex": "T7_COAST_ROCK", "studsPerTile": 40},
    # packed-sand road on the beach stretches (guide: a sand road between stone curbs). Concrete base: not one of
    # CarConfig.OFFROAD_MATERIALS, so the car drives it as road.
    "SR_ISLAND_PackedSand": {"base": "Concrete", "tex": "T1_BEACH_SAND", "studsPerTile": 56},
}


def write_variants() -> None:
    lines = ["{"]
    keys = list(VARIANT_SET)
    for i, k in enumerate(keys):
        v = VARIANT_SET[k]
        lines.append(f' "{k}": {{"base": "{v["base"]}", "tex": "{v["tex"]}", "studsPerTile": {v["studsPerTile"]}}}'
                     + ("," if i < len(keys) - 1 else ""))
    lines.append("}")
    VARIANTS.parent.mkdir(parents=True, exist_ok=True)
    VARIANTS.write_text("\n".join(lines) + "\n")


# ------------------------------------------------------------------------------------------------------- main
def main() -> None:
    # --- route: solve, derive banks from the curvature, solve again (same positions, banked) ---
    rt0 = route_block()
    route0 = routelib.solve_plan_route(rt0)

    def crossing(rt: routelib.Route, pred, s_from: float, s_to: float) -> float:
        s = s_from
        while s <= s_to:
            p = rt.frame_at(s).pos
            if pred(p[0] - ORIGIN[0], p[2] - ORIGIN[2]):
                return round(s, 1)
            s += 0.5
        raise SystemExit("crossing not found")

    s_mouth = crossing(route0, lambda x, z: z <= HEADLAND_FACE_Z, 100, 400)
    s_exit = crossing(route0, lambda x, z: x >= EXIT_PORTAL_X, 800, 1300)
    banks = [bank_for(route0, i, (s_mouth, s_exit)) for i in range(len(NODES))]
    rt = route_block(banks)
    route = routelib.solve_plan_route(rt)
    length = route.length
    assert abs(length - TARGET_LENGTH) < 1.0, length
    rows, _ = route_geometry.analyse([list(w.pos) for w in route.waypoints], min_radius=rt["minRadius"])
    min_r = min(rows, key=lambda r: r["r"])
    max_grade = max(abs(r["grade"]) for r in rows)
    assert min_r["r"] >= 85 and max_grade <= 15.0, (min_r, max_grade)
    st = {i: round(node_station(route, i), 1) for i in range(len(NODES))}
    fr = route.frame_at

    def station_near(x: float, z: float) -> float:
        p = (ORIGIN[0] + x, ORIGIN[2] + z)
        best = min(route.waypoints, key=lambda w: (w.pos[0] - p[0]) ** 2 + (w.pos[2] - p[2]) ** 2)
        return round(best.station, 1)

    s_bridge_from = crossing(route, lambda x, z: x <= 790 and z > 300, 3000, 3700)
    s_bridge_to = crossing(route, lambda x, z: x <= 468 and z > 300, 3000, 3800)
    s_ledge_end = round(st[9] + 40, 1)
    s_desc = round(st[19], 1)
    s_crescent = round(st[28], 1)
    sections = [
        (0, s_mouth, "cove_beach", "inlet_beach"),
        (s_mouth, s_exit, "cliff_sea", "hill"),
        (s_exit, s_ledge_end, "cliff_sea", "hill"),
        (s_ledge_end, s_desc, "cliff_sea", "hill"),
        (s_desc, s_bridge_from, "beach_sea", "hill_low"),
        (s_bridge_from, s_bridge_to + 0.01, "bridge_sea", "bridge_lagoon"),
        (s_bridge_to + 0.01, s_crescent, "beach_sea", "village"),
        (s_crescent, length + 1, "cove_beach", "village"),
    ]
    # lighthouse promontory, outside the S-bend (left of the road), at clifftop level
    s_light = round((st[12] + st[13]) / 2, 1)
    fl = fr(s_light)
    lh = fl.offset(-120, 0)
    terrain = Terrain(route, sections, promontory=((lh[0] - ORIGIN[0], lh[2] - ORIGIN[2]), 100.0, fl.pos[1] - SEA + SHOULDER))

    # --- art: prefabs and instances ---
    groups = ["Galleon", "Cavern", "Landmarks", "Coast", "Village", "Palms", "KeyAlcove", "StartFinish"]
    G = {g: i + 1 for i, g in enumerate(groups)}
    prefabs: dict[str, dict] = {}
    instances: list[dict] = []
    fx: list[dict] = []
    torch_world: list[tuple[list[float], str]] = []

    def place(pf: str, pos, group: str, yaw: float | list = 0.0, scale: float | None = None):
        inst = {"pf": pf, "p": [r3(v) for v in pos], "g": G[group],
                "r": r3(yaw) if not isinstance(yaw, list) else [r3(v) for v in yaw]}
        if scale is not None:
            inst["s"] = r3(scale)
        instances.append(inst)
        return inst

    def to_world(pos, yaw: float, local) -> list[float]:
        v = rot_y(yaw) @ np.array(local, float)
        return [r3(pos[0] + v[0]), r3(pos[1] + v[1]), r3(pos[2] + v[2])]

    # galleon
    gx, gz = GALLEON_POS
    gpos = W(gx, 0, gz)
    prefabs["GalleonHull"] = prefab_galleon_hull()
    prefabs["GalleonDecks"] = prefab_galleon_decks()
    prefabs["GalleonRigging"] = prefab_galleon_rigging()
    prefabs["GalleonGangwayFore"] = prefab_gangway()
    prefabs["GalleonGangwayAft"] = prefab_gangway()
    prefabs["GalleonAnchorChain"] = prefab_anchor_chain()
    prefabs["GalleonPlank"] = prefab_galleon_plank()
    for pf in ("GalleonHull", "GalleonDecks", "GalleonRigging", "GalleonPlank"):
        place(pf, gpos, "Galleon", GALLEON_YAW)
    place("GalleonGangwayFore", to_world(gpos, GALLEON_YAW, (HULL_SIDE, 0, GANGWAY_Z["Fore"])), "Galleon", GALLEON_YAW)
    place("GalleonGangwayAft", to_world(gpos, GALLEON_YAW, (HULL_SIDE, 0, GANGWAY_Z["Aft"])), "Galleon", GALLEON_YAW)
    place("GalleonAnchorChain", to_world(gpos, GALLEON_YAW, (-12, 0, -52)), "Galleon", GALLEON_YAW + 200)
    deck_y = {"main": SEA + 12.0, "forecastle": SEA + 17.0, "quarterdeck": SEA + 20.0}
    prefabs["GalleonDressing"] = prefab_galleon_dressing()  # L61, no-collide (galleon_geom skips nc parts)
    place("GalleonDressing", gpos, "Galleon", GALLEON_YAW)

    # cavern: mouth arch, ribs every ~70 studs, exit portal arch
    prefabs["CavernMouthArch"] = prefab_cavern_mouth()
    prefabs["CavernArchRib"] = prefab_cavern_rib()
    prefabs["CavernExitArch"] = prefab_cavern_mouth()

    def arch_at(pf: str, s: float, group: str) -> None:
        f = fr(s)
        yaw = yaw_of(f.tangent)
        pos = f.pos
        place(pf, pos, group, yaw)
        torches = [(-32.2, 20.6, -6), (32.2, 20.6, -6)] if pf != "CavernArchRib" else [(-30.4, 17.4, 0), (30.4, 17.4, 0)]
        for t in torches:
            torch_world.append((to_world(pos, yaw, t), group))

    arch_at("CavernMouthArch", s_mouth - 3, "Cavern")
    rib_stations = []
    s = s_mouth + 45
    while s < s_exit - 30:
        rib_stations.append(round(s, 1))
        arch_at("CavernArchRib", s, "Cavern")
        s += 70
    arch_at("CavernExitArch", s_exit + 2, "Cavern")

    # key alcove (headland face, right of the mouth)
    prefabs["KeyAlcoveArch"] = prefab_key_alcove()
    alcove_pos = W(ALCOVE_X, ALCOVE_FLOOR, ALCOVE_Z)
    place("KeyAlcoveArch", alcove_pos, "KeyAlcove", 0.0)
    key_world = W(ALCOVE_X, ALCOVE_FLOOR + 4.6, ALCOVE_Z - 18.0)  # over the plinth (prefab z -18)

    # lighthouse on the promontory (outside the S-bend)
    prefabs["Lighthouse"] = prefab_lighthouse()
    lh_ground = terrain.height(lh[0] - ORIGIN[0], lh[2] - ORIGIN[2]) + SEA
    place("Lighthouse", [lh[0], lh_ground - 1.0, lh[2]], "Landmarks", 0.0)

    # start/finish arch
    prefabs["StartFinishArch"] = prefab_start_arch()
    f0 = fr(0.0)
    place("StartFinishArch", [f0.pos[0], f0.pos[1] + DECK_TOP, f0.pos[2]], "StartFinish", yaw_of(f0.tangent))

    # lagoon bridge: piers every ~62 studs, segmental arches between them
    bridge_piers = []
    span = 62.0
    nspan = max(3, int(round((s_bridge_to - s_bridge_from) / span)))
    span = (s_bridge_to - s_bridge_from) / nspan
    for k in range(nspan + 1):
        sp = s_bridge_from + k * span
        f = fr(sp)
        top = f.pos[1] - 6.6
        hgt = round(top - (SEA - 6.0) + 1.0, 1)
        key = f"BridgePier_{hgt:05.1f}"
        if key not in prefabs:
            prefabs[key] = prefab_bridge_pier(hgt)
        place(key, [f.pos[0], top, f.pos[2]], "Coast", yaw_of(f.tangent))
        bridge_piers.append(round(sp, 1))
    for k in range(nspan):
        sm = s_bridge_from + (k + 0.5) * span
        f = fr(sm)
        top = f.pos[1] - 6.6
        rise = min(top - SEA - 2.0, 14.0)
        key = f"BridgeArch_{span - 10:04.1f}_{rise:04.1f}"
        if key not in prefabs:
            prefabs[key] = prefab_bridge_arch(span - 10.0, rise)
        place(key, [f.pos[0], top, f.pos[2]], "Coast", yaw_of(f.tangent))

    # parapets (collidable low stone walls) where the road edge drops to the sea or into the grotto
    grotto_s = st[4]
    # (from, to, side, bridge): the bridge runs stand against the curbs over the deck edge, not out in the air
    parapet_runs = [
        (grotto_s - 90, grotto_s + 110, -1, False),
        (s_exit + 40, s_desc - 40, -1, False),
        (s_bridge_from - 6, s_bridge_to + 6, -1, True),
        (s_bridge_from - 6, s_bridge_to + 6, 1, True),
    ]
    parapet_count = 0
    for a, b, side, on_bridge in parapet_runs:
        lat_p = BRIDGE_PARAPET_LATERAL if on_bridge else PARAPET_LATERAL
        s = a
        while s < b - 0.5:
            e = min(b, s + 6.0)
            pa = fr(s).offset(side * lat_p, 0)
            pb = fr(e).offset(side * lat_p, 0)
            fm = fr((s + e) / 2)
            yb = fm.pos[1] + DECK_TOP - 0.4 + side * lat_p * math.sin(math.radians(fm.bank)) * 0.9
            seg_len = math.hypot(pb[0] - pa[0], pb[2] - pa[2])
            q = math.ceil(seg_len * 4) / 4
            key = f"{'BridgeParapet' if on_bridge else 'Parapet'}_{q:05.2f}"
            if key not in prefabs:
                prefabs[key] = prefab_parapet(q, BRIDGE_PARAPET_FOOT if on_bridge else PARAPET_FOOT)
            yaw = math.degrees(math.atan2(-(pb[0] - pa[0]), -(pb[2] - pa[2])))
            place(key, [(pa[0] + pb[0]) / 2, yb, (pa[2] + pb[2]) / 2], "Coast", yaw)
            parapet_count += 1
            s = e

    # tiki torches along the beach sections (both sides, every 64 studs, lateral 33)
    prefabs["TikiTorch"] = prefab_tiki_torch()
    torch_stations = []
    # Alt1 boardwalk: long 250-stud eases keep its own turns >= ~100 studs radius (drivable at speed)
    alt_join, alt_rejoin = round(s_crescent - 140, 1), round(length - 40, 1)
    beach_ranges = [(s_crescent + 20, length - 30), (30, s_mouth - 40), (s_bridge_to + 30, s_crescent - 10)]
    for a, b in beach_ranges:
        s = a
        while s < b:
            f = fr(s)
            for side in (-1, 1):
                if side < 0 and alt_join - 10 <= s <= alt_rejoin + 10:
                    continue
                p = f.offset(side * 33.0, 0)
                gy = terrain.height(p[0] - ORIGIN[0], p[2] - ORIGIN[2]) + SEA
                place("TikiTorch", [p[0], gy - 0.4, p[2]], "Village", yaw_of(f.tangent))  # on the sand, never floating
            torch_stations.append(round(s, 1))
            s += 64

    # --- alternate line Alt1: timber boardwalk over the cove shallows (left of the crescent), both ends on the line
    def offset_path(s0: float, s1: float, lateral: float, height: float, ramp: float, step: float):
        """author_dino4.offset_path for a drivable line: eased lateral/height offset from the race line's frames,
        sampled evenly so the first and last points sit exactly on the race line at the join and rejoin stations."""
        pts, sts = [], []
        n = max(2, math.ceil((s1 - s0) / step) + 1)
        for i in range(n):
            s = s0 + (s1 - s0) * i / (n - 1)
            k = min(smooth((s - s0) / ramp), smooth((s1 - s) / ramp))
            f = fr(s)
            q = f.offset(lateral * k, height * k)
            pts.append([r3(v) for v in q])
            sts.append((round(s, 1), lateral * k, height * k))
        return pts, sts

    alt_pts, alt_sts = offset_path(alt_join, alt_rejoin, -75.0, 2.0, 250.0, 12.0)
    prefabs["BoardwalkPiles"] = prefab_boardwalk_piles()
    for i in range(1, len(alt_pts) - 1, 2):
        _, lat_i, _ = alt_sts[i]
        if abs(lat_i) < 40:
            continue
        a, b = alt_pts[i - 1], alt_pts[i + 1]
        yaw = math.degrees(math.atan2(-(b[0] - a[0]), -(b[2] - a[2])))
        place("BoardwalkPiles", [alt_pts[i][0], alt_pts[i][1] - 2.0, alt_pts[i][2]], "Coast", yaw)

    # --- alternate line Alt2: the headland wall-ride (style "cliff": no deck and no carve, the cliff is the road).
    # Entry tell: a lit banner pair over the departure, amber ground chevrons along the first 190 studs, up-chevron boards
    # on both sides of the line up the face and over the crest; a boost pad on the line (pads below) carries the car onto
    # the face. Everything is non-colliding; only the four banner flags carry a PointLight.
    cliff_pts, cliff_rep = cliff_line(terrain, fr)
    cliff_np = np.array([[p[0] - ORIGIN[0], p[2] - ORIGIN[2]] for p in cliff_pts])
    prefabs["CliffChevron"] = prefab_cliff_chevron()
    prefabs["CliffBanner"] = prefab_cliff_banner()
    prefabs["CliffArrow"] = prefab_cliff_arrow()
    cliff_tell = {"banners": 0, "boards": 0, "arrows": 0}

    def cliff_dir(i: int) -> np.ndarray:
        d = cliff_np[min(i + 1, len(cliff_np) - 1)] - cliff_np[max(i - 1, 0)]
        return d / np.hypot(*d)

    def cliff_site(i: int, lateral: float) -> tuple[float, float, float] | None:
        """World (x, ground y, z) at line index i and `lateral` studs to the right of travel; None over water or in the
        key inlet."""
        d = cliff_dir(i)
        x, z = float(cliff_np[i][0] - d[1] * lateral), float(cliff_np[i][1] + d[0] * lateral)
        g = terrain.height(x, z)
        if g < 1.8 or math.hypot((x - INLET[0][0]) / (INLET[1][0] + 12), (z - INLET[0][1]) / (INLET[1][1] + 12)) < 1.0:
            return None
        return ORIGIN[0] + x, g + SEA, ORIGIN[2] + z

    for i in (3, 31):  # banners: over the departure and at the foot of the face
        for lat in (-17.0, 17.0):
            q = cliff_site(i, lat)
            if q:
                d = cliff_dir(i)
                place("CliffBanner", [q[0], q[1] - 0.5, q[2]], "Coast", yaw_of((d[0], 0.0, d[1])))
                cliff_tell["banners"] += 1
    # v37 Studio: the baked voxel ground (and the paver ribbon at the join) stands 1.1-1.6 over terrain.height, so at +0.4
    # 19 of the 20 ground chevrons were buried; +2.1 puts them 0.1-0.6 proud of the surface
    ARROW_LIFT = 2.1
    for i in list(range(1, 10)) + [12, 15, 18, 21, 24]:  # ground chevrons, the line itself
        q = cliff_site(i, 0.0)
        if q:
            d = cliff_dir(i)
            place("CliffArrow", [q[0], q[1] + ARROW_LIFT, q[2]], "Coast", yaw_of((d[0], 0.0, d[1])))
            cliff_tell["arrows"] += 1
    # exit tell: ground chevrons along the run-out on the inland plain, pointing along the road the line merges into (only
    # where the line is still off the deck, so nothing lies on the road surface)
    cliff_cum = np.r_[0.0, np.cumsum(np.hypot(*np.diff(cliff_np, axis=0).T))]
    cliff_tell["exitArrows"] = 0
    for i in range(len(cliff_np)):
        if CLIFF_EXIT_ARROWS[0] <= cliff_cum[i] <= CLIFF_EXIT_ARROWS[1]:
            q = cliff_site(i, 0.0)
            if q:
                d = cliff_dir(i)
                place("CliffArrow", [q[0], q[1] + ARROW_LIFT, q[2]], "Coast", yaw_of((d[0], 0.0, d[1])))
                cliff_tell["exitArrows"] += 1
    for i in (4, 7, 10, 13, 34, 37, 40, 43, 46, 49, 52, 58, 62, 66):  # boards both sides: entry, face, crest, descent
        for lat in (-14.0, 14.0):
            q = cliff_site(i, lat)
            if q:
                d = cliff_dir(i)
                place("CliffChevron", [q[0], q[1] - 1.5, q[2]], "Coast", yaw_of((d[0], 0.0, d[1])))
                cliff_tell["boards"] += 1
    alt_np = np.vstack([np.array([[p[0] - ORIGIN[0], p[2] - ORIGIN[2]] for p in alt_pts]), cliff_np])
    # v37 turn boards (Mario Kart rule: on the outside of a bend, facing the driver, chevrons pointing the way the road
    # turns). Only the lap's sharpest bend (about 90 degrees inside 200 studs, the min radius) gets them: the others read.
    prefabs["TurnBoardR"] = prefab_turn_board(1)
    prefabs["TurnBoardL"] = prefab_turn_board(-1)
    turn_boards = []
    for s_t, sgn_t in sharp_turns(fr, route.length, TURN_BOARD_DEG):
        for along in (-55.0, 0.0, 55.0):
            f_t = fr((s_t + along) % route.length)
            lat_t = -sgn_t * (DECK_WIDTH / 2 + 10.0)  # the outside: left of a right-hand bend
            q = f_t.offset(lat_t, 0.0)
            g = terrain.height(q[0] - ORIGIN[0], q[2] - ORIGIN[2])
            if g < 1.8:
                continue  # never on the water
            place("TurnBoardR" if sgn_t > 0 else "TurnBoardL", [q[0], g + SEA + TURN_BOARD_SEAT, q[2]], "Coast",
                  yaw_of(f_t.tangent))
            turn_boards.append(round(s_t + along, 1))

    # lagoon dock, rowboats, buoys, crates
    prefabs["LagoonDock"] = prefab_dock()
    prefabs["Rowboat"] = prefab_rowboat()
    prefabs["MooringBuoy"] = prefab_buoy()
    (lx, lz), (_, lb) = LAGOON
    place("LagoonDock", W(lx - 60, 0, lz - lb + 6), "Coast", 0.0)
    place("Rowboat", W(lx + 20, 0.2, lz - 10), "Coast", 35.0)
    place("Rowboat", W(lx - 75, 0.2, lz - lb + 40), "Coast", -80.0)
    place("Rowboat", W(gx + 70, 0.2, gz + 95), "Coast", 120.0)
    # (the fourth buoy rode at (-120, -250) until the Plank Dune covered that water: moved out past its north flank)
    for bx, bz in ((-150, -60), (-270, -60), (-330, -220), (-104, -296)):
        assert terrain.height(bx, bz) < -1.0, (bx, bz, terrain.height(bx, bz))  # floating on water, not on sand
        place("MooringBuoy", W(bx, -0.4, bz), "Coast", 0.0)

    # village huts and crates on the south beach (right side, inside the loop)
    huts, hut_xz = [], []
    s = s_bridge_to + 70
    k = 0
    while s < s_crescent - 40 and k < 7:
        f = fr(s)
        lat = 72 + 28 * (k % 2)
        p = f.offset(lat, 0)
        gy = terrain.height(p[0] - ORIGIN[0], p[2] - ORIGIN[2])
        if gy > 2.0:
            key = f"BeachHut#{k % 3}"
            if key not in prefabs:
                prefabs[key] = prefab_hut(k % 3)
            place(key, [p[0], gy + SEA - 0.6, p[2]], "Village", yaw_of(f.tangent) + 90 + (k % 3) * 7)
            huts.append(round(s, 1))
            hut_xz.append((p[0] - ORIGIN[0], p[2] - ORIGIN[2]))
            cp = f.offset(lat - 22, 0)
            cgy = terrain.height(cp[0] - ORIGIN[0], cp[2] - ORIGIN[2])
            ck = f"CargoCrates#{k % 2}"
            if ck not in prefabs:
                prefabs[ck] = prefab_crates(k % 2)
            place(ck, [cp[0], cgy + SEA - 0.3, cp[2]], "Village", 20.0 * k)
            k += 1
        s += 58

    # palms: deterministic scatter on dry sand/grass, clear of the road, the boardwalk, huts and landmarks
    palm_variants = [(26, 5, 1), (31, 7, 2), (36, 9, 3), (29, -6, 4)]
    for vi, (h, lean, sd) in enumerate(palm_variants):
        prefabs[f"PalmTree#{vi}"] = prefab_palm(h, lean, sd)
    rng = random.Random(4242)
    sx = terrain.samples
    avoid = [(gx, gz, 95), (ALCOVE_X, HEADLAND_FACE_Z, 45), (lh[0] - ORIGIN[0], lh[2] - ORIGIN[2], 40),
             (lx - 60, lz - lb, 30)]
    avoid += [(hx, hz, 24) for hx, hz in hut_xz]
    palms = []
    tries = 0
    xs_lo, xs_hi = float(sx[:, 0].min()) - 200, float(sx[:, 0].max()) + 200
    zs_lo, zs_hi = float(sx[:, 1].min()) - 200, float(sx[:, 1].max()) + 200
    while len(palms) < 56 and tries < 20000:  # L61: 90 -> 56, the uploaded palm clusters carry the rest
        tries += 1
        x, z = rng.uniform(xs_lo, xs_hi), rng.uniform(zs_lo, zs_hi)
        h = terrain.height(x, z)
        if not (1.8 < h < 60):
            continue
        if terrain.on_dune(x, z):  # the Plank Dune is battle ground: no trunks on it
            continue
        if point_in_poly(np.array([x]), np.array([z]), HEADLAND)[0]:
            continue
        mat = terrain.material(x, z)
        if mat not in (PAL["sand"], PAL["grass"]):
            continue
        d_route = float(np.min(np.hypot(sx[:, 0] - x, sx[:, 1] - z)))
        if d_route < 42:
            continue
        if d_route > 260 and rng.random() < 0.6:
            continue
        if float(np.min(np.hypot(alt_np[:, 0] - x, alt_np[:, 1] - z))) < 26:
            continue
        if any(math.hypot(x - ax, z - az) < ar for ax, az, ar in avoid):
            continue
        if any(math.hypot(x - px, z - pz) < 26 for px, pz in palms):
            continue
        palms.append((x, z))
        v = rng.randrange(len(palm_variants))
        place(f"PalmTree#{v}", W(x, h - 0.4, z), "Palms", rng.uniform(0, 360), r3(rng.uniform(0.85, 1.15)))

    # --- fx: fire on the cavern torches, the grotto light shaft, the key sparkle ---
    for pos, group in torch_world:
        fx.append({"class": "Fire", "cf": [pos[0], pos[1] + 0.6, pos[2], 1, 0, 0, 0, 1, 0, 0, 0, 1], "group": group,
                   "props": {"Size": 3.2, "Heat": 6, "Color": "#ff8a2a", "SecondaryColor": "#ffd27a"}})
    f4 = fr(grotto_s)
    gc = f4.offset(-92, 22)
    grotto_center = [r3(v) for v in gc]
    fx.append({"class": "Beam", "a0": [gc[0], SEA + 172.0, gc[2]], "a1": [gc[0], SEA + 1.0, gc[2]], "group": "Cavern",
               "props": {"Width0": 26, "Width1": 46, "Color": "#e6f8ff",
                         "Transparency": {"seq": [[0, 0.82, 0], [0.6, 0.9, 0], [1, 1, 0]]}, "LightEmission": 0.6,
                         "FaceCamera": True, "Texture": ""}})
    fx.append({"class": "SpotLight", "cf": [gc[0], SEA + 90.0, gc[2], 1, 0, 0, 0, 1, 0, 0, 0, 1], "group": "Cavern",
               "props": {"Brightness": 1.6, "Range": 60, "Angle": 50, "Color": "#e6f8ff", "Face": "Bottom", "Shadows": False}})
    fx.append({"class": "ParticleEmitter", "cf": [key_world[0], key_world[1], key_world[2], 1, 0, 0, 0, 1, 0, 0, 0, 1],
               "size": [4, 4, 4], "group": "KeyAlcove",
               "props": {"Rate": 6, "Lifetime": [1.2, 2.2], "Speed": [0.4, 1.2], "SpreadAngle": [180, 180],
                         "Size": {"seq": [[0, 0.7, 0], [1, 0, 0]]}, "Color": "#ffe9a0", "LightEmission": 1,
                         "Texture": "rbxasset://textures/particles/sparkles_main.dds"}})

    # --- shells: far sea frame, cavern tube, grotto, floor, key alcove ---
    gx0, gz0 = ORIGIN[0] + terrain.x0, ORIGIN[2] + terrain.z0
    gx1 = gx0 + (terrain.nx - 1) * GRID_CELL
    gz1 = gz0 + (terrain.nz - 1) * GRID_CELL
    border = np.concatenate([terrain.H[0], terrain.H[-1], terrain.H[:, 0], terrain.H[:, -1]])
    assert border.max() < -10.0, border.max()
    gx0, gz0, gx1, gz1 = gx0 + 8, gz0 + 8, gx1 - 8, gz1 - 8  # frame starts inside the grid: no seam in the sea
    fx0, fx1, fz0, fz1 = SEA_FRAME
    assert fx0 < gx0 and gx1 < fx1 and fz0 < gz0 and gz1 < fz1, (SEA_FRAME, gx0, gx1, gz0, gz1)

    def box_op(xa, xb, ya, yb, za, zb, mat):
        return {"op": "FillBlock", "cf": [r3((xa + xb) / 2), r3((ya + yb) / 2), r3((za + zb) / 2), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                "size": [r3(xb - xa), r3(yb - ya), r3(zb - za)], "mat": mat}

    shell_ops = []
    for mat, ya, yb in (("Slate", SEA - 26, SEA - 20), ("Water", SEA - 20, SEA)):
        shell_ops += [box_op(fx0, fx1, ya, yb, fz0, gz0, mat),
                      box_op(fx0, fx1, ya, yb, gz1, fz1, mat),
                      box_op(fx0, gx0, ya, yb, gz0, gz1, mat),
                      box_op(gx1, fx1, ya, yb, gz0, gz1, mat)]
    # The first/last balls sit >= 20 inside each portal face: their cut through the face then stays inside the portal
    # arch's silhouette (an upper lobe 13 studs in cut a hollow into the face above the arch crown).
    tube_from, tube_to = round(s_mouth + 20, 1), round(s_exit - 20, 1)
    shell_ops.append({"op": "CarveRouteTube", "fromStation": tube_from, "toStation": tube_to, "radiusMin": 40,
                      "radiusMax": 50, "lift": 18, "upperLift": 40, "upperScale": 0.6, "noiseFreq": 0.13, "seed": 5})
    # portal bores: a ball the size of the arch opening (inner radius 33.5 at +32) 8 studs inside each face, so the
    # tunnel behind each portal arch is as big as the arch and joins the tube
    for s_bore in (s_mouth + 8.0, s_exit - 8.0):
        fb = fr(s_bore)
        shell_ops.append({"op": "FillBall", "center": [r3(fb.pos[0]), r3(fb.pos[1] + 32.0), r3(fb.pos[2])], "r": 33,
                          "mat": "Air"})
    # sea grotto: a chamber left of the bend, a skylight through the headland, a rock floor and a pool
    shell_ops += [{"op": "FillBall", "center": grotto_center, "r": 74, "mat": "Air"},
                  {"op": "FillCylinder", "cf": [gc[0], SEA + 125.0, gc[2], 1, 0, 0, 0, 1, 0, 0, 0, 1], "h": 110, "r": 17, "mat": "Air"},
                  box_op(gc[0] - 80, gc[0] + 80, SEA - 50, SEA - 6, gc[2] - 80, gc[2] + 80, "Rock"),
                  # round pool filling the whole carved bowl below the waterline (the ball reaches below SEA - 0.5 out
                  # to r ~66.5): a square pool left free-standing water walls over a dry ring of rock at SEA - 6
                  {"op": "FillCylinder", "cf": [gc[0], SEA - 3.25, gc[2], 1, 0, 0, 0, 1, 0, 0, 0, 1], "h": 5.5, "r": 67,
                   "mat": "Water"}]
    shell_ops.append({"op": "RouteFloorFill", "fromStation": round(s_mouth - 40, 1), "toStation": round(s_exit + 40, 1),
                      "mat": "Sand", "depth": 16, "width": 104, "thickness": 30})
    # key alcove recess (into the cliff, behind the arch), floor at the sill, as tall as the arch opening; it runs out
    # to the arch front so the bilinear cliff ramp between the grid rows never closes the mouth
    shell_ops.append(box_op(ORIGIN[0] + ALCOVE_X - 13, ORIGIN[0] + ALCOVE_X + 13, SEA + ALCOVE_FLOOR,
                            SEA + ALCOVE_FLOOR + 25.5, ORIGIN[2] + ALCOVE_Z - 40, ORIGIN[2] + ALCOVE_Z + 3, "Air"))

    # --- gameplay ---
    cps, n_cp = [], 12
    for k in range(n_cp):
        cps.append(round(k * length / n_cp, 1))
    rings = []
    ring_plan = [("BoosterRing_CavernMouth", s_mouth - 50), ("BoosterRing_GrottoLedge", grotto_s + 60),
                 ("BoosterRing_LedgeRoad", s_exit + 120), ("BoosterRing_Promontory", s_light + 40),
                 ("BoosterRing_CrestJump", round(st[16] + 4, 1)), ("BoosterRing_LagoonBridge", round((s_bridge_from + s_bridge_to) / 2, 1)),
                 ("BoosterRing_Village", round(st[26], 1)), ("BoosterRing_Crescent", round(st[30], 1))]
    for name, s in ring_plan:
        rings.append({"name": name, "station": round(s, 1), "lateral": 0, "height": RING_HEIGHT, "coin": False, "coinId": None})
    rings += cliff_rings(terrain, cliff_pts)
    pads = [{"name": "GroundBoost_LedgeRoad", "station": round(s_exit + 330, 1), "lateral": 0},
            {"name": "GroundBoost_JumpRunup", "station": round(st[15] - 60, 1), "lateral": 0},
            {"name": "GroundBoost_BridgeApproach", "station": round(s_bridge_from - 90, 1), "lateral": 0},
            dict(CLIFF_PAD)]
    # v37: the pad stood ~43 studs from the front grid row (a free boost at GO for anyone steering right). It now sits
    # on the cliff line at its first point CLIFF_PAD_CLEAR studs (horizontal) from the front row, projected back onto the
    # route frame (station + lateral) the adapter places pads by.
    g0 = fr(20.0).pos
    for q in cliff_pts:
        if math.hypot(q[0] - g0[0], q[2] - g0[2]) >= CLIFF_PAD_CLEAR:
            best_s, best_d = 0.0, None
            s_ = 0.0
            while s_ < 600.0:
                f_ = fr(s_)
                d_ = (q[0] - f_.pos[0]) ** 2 + (q[2] - f_.pos[2]) ** 2
                if best_d is None or d_ < best_d:
                    best_s, best_d = s_, d_
                s_ += 0.5
            f_ = fr(best_s)
            pads[-1]["station"] = round(best_s, 1)
            pads[-1]["lateral"] = round((q[0] - f_.pos[0]) * f_.right[0] + (q[2] - f_.pos[2]) * f_.right[2], 1)
            break
    CLIFF_PAD.update(station=pads[-1]["station"], lateral=pads[-1]["lateral"])
    # v37: the cliff-entry pad lies on the Alt2 line, which leaves the road at about 80 degrees, so it faces the line's
    # own direction there (the main tangent made its chevrons point across the line)
    cp = fr(CLIFF_PAD["station"]).offset(CLIFF_PAD["lateral"], 0.0)
    ci = int(np.argmin(np.hypot(cliff_np[:, 0] - (cp[0] - ORIGIN[0]), cliff_np[:, 1] - (cp[2] - ORIGIN[2]))))
    cd = cliff_dir(ci)
    pads[-1]["facing"] = [r3(float(cd[0])), 0.0, r3(float(cd[1]))]
    lip = max((w for w in route.waypoints if st[15] - 5 <= w.station <= st[17] + 5), key=lambda w: w.pos[1]).station
    # Item cubes v3 (docs/design/ITEM_BOXES.md; rules in tools/map/item_cubes.json): 7 staggered sets of 5 mystery
    # cubes (front rank +-8, back rank -16/0/+16 32 studs on) every 540-700 studs (v1 had 4 rows ~1300 apart). Fixed
    # race stations of the front rank, each in a free stretch: the cavern, the ledge road before its ring, the clifftop,
    # the promontory run before the jump pad, the south-east after the landing, the far end of the lagoon bridge (its
    # deck is 50 wide between the parapets, a set spans +-16) and the village end (inside the Alt1 span: the wrap gap to
    # the cavern must stay under 700, so the boardwalk line trades this one set for its own shortcut). The v2 Speed
    # singles 60 after a row became each set's fifth cube; the Speed pickups (mint boost blocks) moved mid-gap.
    pod_rows = [(380.0, "Cavern"), (1040.0, "LedgeRoad"), (1700.0, "Clifftop"), (2240.0, "Promontory"),
                (2900.0, "SECorner"), (3600.0, "Lagoon"), (4300.0, "Village")]
    set_st = [s for s, _ in pod_rows]
    pods = []
    for k, (s, row) in enumerate(pod_rows):
        pods += item_rows.cube_set("car", "island2", k, s, POD_HEIGHT, lambda t, j, row=row: f"ItemPod_{row}_{t}", row)
    for k, row in ((1, "LedgeRoad"), (4, "SECorner"), (5, "Lagoon")):
        pods.append(item_rows.speed_single(f"ItemPod_{row}_Speed", item_rows.gap_single("car", set_st, k, route.length), POD_HEIGHT))
    item_rows.assert_layout({"pods": pods}, "car", "island2", route.length)
    for p in pods:  # never on the jump (run-up pad to well past the landing): an airborne car would sail over them
        assert not (st[15] - 60 <= p["station"] <= lip + 160), p
    # coins: 8 (coin challenge), one on the Alt1 boardwalk
    mid_alt = alt_sts[len(alt_sts) // 2]
    coins = [
        {"id": 1, "station": round(s_mouth + 80, 1), "lateral": -12, "height": COIN_HEIGHT, "line": "main"},
        {"id": 2, "station": round(grotto_s - 20, 1), "lateral": -17, "height": COIN_HEIGHT, "line": "main"},
        {"id": 3, "station": round(s_exit + 230, 1), "lateral": 14, "height": COIN_HEIGHT, "line": "main"},
        {"id": 4, "station": round(st[13], 1), "lateral": -15, "height": COIN_HEIGHT, "line": "main"},
        {"id": 5, "station": None, "lateral": 0, "height": 8.0, "line": "main", "note": "at the top of the crest-jump arc"},
        {"id": 6, "station": round(s_bridge_from + 40, 1), "lateral": 15, "height": COIN_HEIGHT, "line": "main"},
        {"id": 7, "station": mid_alt[0], "lateral": r1(mid_alt[1]), "height": r1(mid_alt[2] + COIN_HEIGHT), "line": "Alt1"},
        {"id": 8, "station": round(st[25] + 30, 1), "lateral": 16, "height": COIN_HEIGHT, "line": "main"},
    ]

    coins[4]["station"] = round(lip + 18.0, 1)
    # key: project the alcove plinth point onto the route
    def project(p) -> tuple[float, float, float]:
        best = None
        s = 0.0
        while s < length:
            f = fr(s)
            d = (p[0] - f.pos[0]) ** 2 + (p[2] - f.pos[2]) ** 2
            if best is None or d < best[0]:
                best = (d, s)
            s += 1.0
        f = fr(best[1])
        lat = (p[0] - f.pos[0]) * f.right[0] + (p[2] - f.pos[2]) * f.right[2]
        return round(best[1], 1), round(lat, 1), round(p[1] - f.pos[1], 1)

    ks, kl, kh = project(key_world)
    key = {"station": ks, "lateral": kl, "height": kh, "pos": key_world,
           "note": "water-side alcove right of the cavern mouth; drive off the line through the inlet shallows"}

    # battle overlay: water battle on the cove shallows + galleon decks, tide in three steps
    R = rot_y(GALLEON_YAW)

    def ship(local) -> list[float]:
        v = R @ np.array(local, float)
        return [r3(gpos[0] + v[0]), r3(gpos[1] + v[1]), r3(gpos[2] + v[2])]

    # The art venue: the first water-battle disc (cove flats between the beach road and the galleon's starboard side).
    # The L61 art pass below keeps its props, foam and spray out of it, so the art does not move with the arena.
    venue_local, venue_r = (-120.0, -170.0), 150.0
    # Owner 2026-10-21 ("way too tiny ... you forget that people are on vehicles"): the arena covers the whole drivable
    # cove: the beach and dunes from the headland face to the south hills, the inlet, the shallows and the galleon.
    # 500 across is ~3.9 s at the car's 128 top speed (docs/research/BATTLE_ARENAS.md rule 1); walls, terrain, the
    # cavern barrier and the art are unchanged.
    centre_local = (-60.0, -110.0)
    centre = W(centre_local[0], 1.0, centre_local[1])
    arena_r = 250.0

    def ground(x, z, lift=4.0):
        g = terrain.height(x, z)
        # drivable at the base tide: dry sand, or shallows no deeper than the car's drown depth
        assert -1.3 <= g <= 6.0 and not point_in_poly(np.array([x]), np.array([z]), HEADLAND)[0], (x, z, g)
        assert math.hypot(x - centre_local[0], z - centre_local[1]) <= arena_r - 15, (x, z)
        return W(x, max(g, 0.0) + lift, z)

    def ship_ground(sx, sz, lift):
        """A ship-frame (x, z) on the sand (the Plank Dune or the beach) as a world point `lift` over the ground."""
        w = ship((sx, 0, sz))
        g = terrain.height(w[0] - ORIGIN[0], w[2] - ORIGIN[2])
        assert -1.3 <= g <= 6.0, (sx, sz, g)
        assert math.hypot(w[0] - centre[0], w[2] - centre[2]) <= arena_r - 15, (sx, sz)
        return [w[0], r3(SEA + max(g, 0.0) + lift), w[2]]

    def ship_dir(dx, dz) -> list[float]:
        v = R @ np.array([dx, 0.0, dz], float)
        v /= np.linalg.norm(v)
        return [r3(v[0]), 0.0, r3(v[2])]

    # Pads (trap audit I2-01/02/04/10; owner 2026-10-21). Eight sand pads for the eight-car field (BattleRules.FIELD),
    # every one 3.6+ over the sea, so dry with WaterRules.SAFE_MARGIN at the last tide step (beach crest, dunes, the south beach), clear of props by 10+ studs and of the
    # galleon by 30, spread by farthest-point order so the first four seats are already far apart. Slot 1 is the
    # player's seat (crest B, as before); bots take the free pads in order. No pad is on the galleon: a respawn on the
    # deck read as being stranded on the ship (owner), so the deck is a place to drive to, never a seat.
    pad_xz = [(-14, -210), (-56, 88), (126, -38), (4, -20), (54, -122), (92, -230), (34, 66), (-84, -218)]
    spawns = [ground(x, z) for x, z in pad_xz]

    def toward_centre(p) -> list[float]:
        d = np.array([centre[0] - p[0], 0.0, centre[2] - p[2]])
        d /= np.linalg.norm(d)
        return [r3(d[0]), 0.0, r3(d[2])]

    spawn_looks = [toward_centre(p) for p in spawns]
    # Item pods (owner 2026-10-21: "all the balloons are on the ship that you can't even get to"): every pod sits 3 over
    # sand that stays dry at the last tide step, on the drivable loop (tools/map/tests/test_battle_reach floods from the
    # pads at every tide level and must reach each one), 45+ apart, none on the galleon, none on a pad.
    pod_xz = [(-30, -110), (-80, 108), (114, 24), (66, -228), (-82, -246), (-8, 10), (132, -86), (46, -62), (70, -144),
              (4, 92), (-4, -186), (-120, -186), (50, 44), (-32, -48)]
    pickups = [ground(x, z, 3) for x, z in pod_xz]

    # Walk the Plank: where a car that rolls up from rest on the deck (throttle 1 and the touch auto-gas 0.92) leaves
    # the lip and lands, with CarConfig's car physics (ACCEL_RESPONSE 1.15, ACCEL_MIN 20, SLOPE_GRAVITY 70, GRAVITY 140,
    # RIDE_HEIGHT 1.9). tools/map/tests/test_island2 re-flies it from the plan's parts and terrain.
    plank_ang = math.radians(PLANK_DEG)
    lip_y = SHIP_DECK + (PLANK_X1 - PLANK_X0) * math.tan(plank_ang)
    plank_zc = (PLANK_Z0 + PLANK_Z1) / 2

    def plank_run(throttle: float, start_x: float = 1.5) -> tuple[float, float]:
        x, v, dt = start_x, 0.0, 1.0 / 240.0
        while x < PLANK_X1:
            target = 128.0 * throttle
            v = min(target, v + max(20.0, (target - v) * 1.15) * dt)
            fy = math.sin(plank_ang) if x >= PLANK_X0 else 0.0
            v -= 70.0 * fy * dt
            x += v * math.cos(plank_ang if x >= PLANK_X0 else 0.0) * dt
        vx, vy = v * math.cos(plank_ang), v * math.sin(plank_ang)
        y = lip_y + 1.9
        while True:
            x += vx * dt
            vy -= CAR_GRAVITY * dt
            y += vy * dt
            w = ship((x, 0, plank_zc))
            if vy < 0 and y - 1.9 <= terrain.height(w[0] - ORIGIN[0], w[2] - ORIGIN[2]):
                return v, x

    runs = {k: plank_run(th) for k, th in (("keyboard", 1.0), ("touch", 0.92))}
    land_x = runs["keyboard"][1]
    plank = {"name": "GalleonPlank", "lip": ship((PLANK_X1, lip_y, plank_zc)), "dir": ship_dir(1.0, 0.0),
             "launchDeg": PLANK_DEG, "width": r1(PLANK_Z1 - PLANK_Z0),
             "landing": ship_ground(land_x, plank_zc, 0.0),
             "lipSpeed": {k: r1(v) for k, (v, _) in runs.items()},
             "landingShipX": {k: r1(x) for k, (_, x) in runs.items()},
             "note": "physical kicker, no pad: from rest on the deck the car leaves the lip at lipSpeed and lands on "
                     "the Plank Dune (dry at every tide); slower cars drop onto the bank against the hull, faster ones "
                     "further along the dune and its spit to the beach crest"}
    for k, (v, x) in runs.items():
        # on the dune between the two gangway lanes, clear of the hull bank's foot
        assert 45.0 < v < 90.0 and HULL_SIDE + 25.0 < x < DUNE_RECT[1], (k, v, x)
    # Trap I2-05: the cavern-mouth road leaves the arena through the soft band; close it in the arch, battle only.
    s_barrier = round(s_mouth - 1.5, 1)
    barrier = cavern_barrier(fr(s_barrier), s_barrier)
    # REMARKABLE item 13: the galleon cannons and the plank salute gun (battle only, server/WorldSetPieces).
    guns = galleon_launchers(
        lambda local: ship(local), ship_dir,
        lambda wx, wz: SEA + terrain.height(wx - ORIGIN[0], wz - ORIGIN[2]),
        [np.asarray(p, float) for p in spawns],
        np.array([[w.pos[0], w.pos[2]] for w in route.waypoints], float),
        np.asarray(centre, float), arena_r, deck_y, SEA + 4.5)
    battle = {
        "kind": "water", "id": "ISLAND-BATTLE", "vehicle": "car",
        "center": centre, "radius": arena_r, "softBoundary": {"center": centre, "radius": arena_r, "softWidth": 25},
        "venue": {"center": W(venue_local[0], 1.0, venue_local[1]), "radius": venue_r,
                  "note": "the first water-battle disc: the art pass keeps props, foam and spray out of it"},
        "spawns": spawns,
        "spawnLooks": spawn_looks,
        "baseLevel": SEA,
        "tideSteps": [{"step": 1, "atSeconds": 50, "level": r1(SEA + 1.5)},
                      {"step": 2, "atSeconds": 100, "level": r1(SEA + 3.0)},
                      {"step": 3, "atSeconds": 140, "level": r1(SEA + 4.5)}],
        "drownDepth": 2.2,
        "pickupAnchors": pickups,
        "decks": {"group": "Galleon", "main": {"name": "GalleonDecks", "y": deck_y["main"]},
                  "forecastle": {"y": deck_y["forecastle"]}, "quarterdeck": {"y": deck_y["quarterdeck"]}},
        "gangways": [{"name": f"GalleonGangway{k}", "top": ship((HULL_SIDE, SHIP_DECK, GANGWAY_Z[k])),
                      "foot": ship((HULL_SIDE + RAMP_RUN, RAMP_FOOT_Y, GANGWAY_Z[k])), "width": GANGWAY_W}
                     for k in ("Fore", "Aft")],
        "plank": plank,
        "dune": {"top": r1(SEA + DUNE_TOP), "note": "Plank Dune: sand bank under the lower gangways and the plank "
                 "landing, spit to the beach crest; dry at every tide, so the decks are never an island"},
        "lives": 3, "capSeconds": 180,
        "barriers": [barrier],
        "launchers": guns["launchers"],
        "salute": guns["salute"],
        "note": "shallows bed -1.0 below sea level; ground deeper than drownDepth under the tide level drowns "
                "(CarController WATER_SINK_DEPTH), so each step closes the low sand toward the beach crest, the Plank "
                "Dune and the decks. spawnLooks: authored seat/respawn headings, one per spawn (the deck pad looks down "
                "the aft gangway)",
    }
    # ------------------------------------------------------------------ L61 art pass: density, landmarks, horizon, fx
    G_EXTRA = ["Dressing", "Horizon", "Ambience"]
    for g in G_EXTRA:
        groups.append(g)
        G[g] = len(groups)
    lib = prop_library()
    cor = Corridor(route)
    drng = random.Random(6161)
    dressing: list[dict] = []
    taken: list[tuple[float, float, float]] = []  # local x, z, footprint radius (props and kit pieces)
    why: dict = {}
    sx_all = terrain.samples
    centre_xz = venue_local  # the art venue, not the widened battle arena (the art keeps its v27 layout)
    (ixc_, izc_), (ia_, ib_) = INLET
    trunk_xz = list(palms)
    rib_free = (s_mouth - 30, s_exit + 30)

    def no(w: str) -> bool:
        why[w] = why.get(w, 0) + 1
        return False

    def route_dist(x: float, z: float) -> float:
        return float(np.min(np.hypot(sx_all[:, 0] - x, sx_all[:, 1] - z)))

    def slope_at(x: float, z: float) -> float:
        hx = terrain.height(x + 4, z) - terrain.height(x - 4, z)
        hz = terrain.height(x, z + 4) - terrain.height(x, z - 4)
        return math.hypot(hx, hz) / 8.0

    def site_ok(x: float, z: float, r: float, collide: bool, min_route: float = 30.0, dry: float = 1.6,
                spacing: float = 0.85) -> bool:
        if not (terrain.x0 + 40 < x < terrain.x0 + (terrain.nx - 1) * GRID_CELL - 40
                and terrain.z0 + 40 < z < terrain.z0 + (terrain.nz - 1) * GRID_CELL - 40):
            return no("grid")
        if math.hypot(x - centre_xz[0], z - centre_xz[1]) < venue_r + 25 + r:
            return no("arena")  # the water battle's open sand and shallows stay clear (decor included)
        if math.hypot((x - ixc_) / (ia_ + r + 10), (z - izc_) / (ib_ + r + 10)) < 1.0:
            return no("inlet")  # the key's approach through the inlet shallows
        if point_in_poly(np.array([x]), np.array([z]), HEADLAND)[0]:
            return no("headland")
        h = terrain.height(x, z)
        if h < dry or terrain.on_dune(x, z):
            return no("water")
        if slope_at(x, z) > 0.5:
            return no("slope")
        if route_dist(x, z) < min_route + r:
            return no("route")
        if float(np.min(np.hypot(alt_np[:, 0] - x, alt_np[:, 1] - z))) < 30 + r:
            return no("alt")
        for ax_, az_, ar_ in avoid:
            if math.hypot(x - ax_, z - az_) < ar_ * 0.6 + r:
                return no("landmark")
        for px_, pz_ in trunk_xz:
            if math.hypot(x - px_, z - pz_) < 7 + r:
                return no("palm")
        for tx_, tz_, tr_ in taken:
            if math.hypot(x - tx_, z - tz_) < (tr_ + r) * spacing:
                return no("spacing")
        return True

    def corridor_clear(c_, h_) -> bool:
        return not cor.hits(c_[None, :], h_[None, :], margin=PROP_MARGIN).any() or no("corridor")

    def dput(key: str, x: float, z: float, yaw: float, sc: float, **kw) -> bool:
        sc = float(min(max(sc, 0.8), 1.3))
        if key not in lib:
            return no("lib")
        sx_, sy_, sz_, collide = lib[key]
        r = 0.5 * math.hypot(sx_, sz_) * sc
        if not site_ok(x, z, r, collide, **kw):
            return False
        if key != "island_palm_cluster" and slope_at(x, z) > 0.28:
            return no("slope")  # small props stand level (critic r1: chests and anchors read as floating on slopes)
        g = terrain.height(x, z) + SEA
        pos = [ORIGIN[0] + x, g + 2.0, ORIGIN[2] + z]
        c_, h_ = prop_aabb(lib[key], pos, yaw, sc)
        if not corridor_clear(c_, h_):
            return False
        dressing.append({"key": key, "pos": [r3(v) for v in pos], "yaw": r3(yaw % 360.0), "scale": r3(sc), "snap": True})
        taken.append((x, z, r))
        return True

    def kput(pf: str, x: float, z: float, yaw: float, sc: float, r: float, sink: float = 0.6, **kw) -> bool:
        if not site_ok(x, z, r, True, **kw):
            return False
        g = terrain.height(x, z) + SEA
        c_ = np.array([ORIGIN[0] + x, g + 10.0, ORIGIN[2] + z])
        if not corridor_clear(c_, np.array([r, 14.0, r])):
            return False
        place(pf, [ORIGIN[0] + x, g - sink, ORIGIN[2] + z], "Dressing", yaw, sc)
        taken.append((x, z, r))
        return True

    def at(s_: float, lat: float, along: float = 0.0):
        f = fr(s_ + along)
        q = f.offset(lat, 0)
        return q[0] - ORIGIN[0], q[2] - ORIGIN[2], f

    def face_road(x: float, z: float, f) -> float:
        """Yaw that turns an ISLAND prop's front (-Z, the LookVector) toward the road point of frame f."""
        return yaw_of((f.pos[0] - ORIGIN[0] - x, 0.0, f.pos[2] - ORIGIN[2] - z))

    for k in range(4):
        prefabs[f"RockCluster#{k}"] = prefab_rock_cluster(31 + k)
    for k in range(3):
        prefabs[f"Driftwood#{k}"] = prefab_driftwood(51 + k)
    prefabs["BeachedSkiff"] = prefab_beached_skiff()
    prefabs["Shipwreck"] = prefab_shipwreck()
    prefabs["TreasureHoard"] = prefab_treasure_hoard()

    small = ["island_cargo_pile", "island_rope_anchor", "island_treasure_chest", "island_tiki_torch_pair"]
    # (1) turn framing: a cluster on the outside of every open-air turn (palm cluster, boulders, a torch pair facing
    # the road, cargo), a smaller one on the inside
    apexes = []
    s = 40.0
    prev = None
    while s < length - 40:
        if not (rib_free[0] <= s <= rib_free[1]) and not (s_bridge_from - 30 <= s <= s_bridge_to + 30):
            rr = signed_radius(route, s, 45.0)
            if not math.isinf(rr) and abs(rr) < 330:
                if prev is None or s - prev > 110:
                    apexes.append((s, rr))
                    prev = s
        s += 10.0
    for s_, rr in apexes:
        out_side = 1.0 if rr > 0 else -1.0
        x, z, f = at(s_, out_side * drng.uniform(70, 86))
        dput("island_palm_cluster", x, z, drng.uniform(0, 360), drng.uniform(0.95, 1.25))
        x, z, f = at(s_, out_side * 50, drng.uniform(-14, -6))
        kput(f"RockCluster#{drng.randrange(4)}", x, z, drng.uniform(0, 360), drng.uniform(0.9, 1.2), 12)
        x, z, f = at(s_, out_side * 40, 14)
        dput("island_tiki_torch_pair", x, z, face_road(x, z, f), drng.uniform(1.0, 1.15))
        x, z, f = at(s_, out_side * 46, 30)
        dput(drng.choice(small[:3]), x, z, face_road(x, z, f) + drng.uniform(-25, 25), drng.uniform(0.9, 1.2))
        x, z, f = at(s_, -out_side * 44, drng.uniform(-10, 10))
        dput(drng.choice(small[:3]), x, z, face_road(x, z, f) + drng.uniform(-30, 30), drng.uniform(0.9, 1.2))
    # (2) the route edges: every ~55 studs on the open-air sections, alternating sides: a small prop at a readable
    # distance, every third a palm cluster further back, sometimes a boulder pair
    s = 30.0
    k = 0
    while s < length - 20:
        if rib_free[0] <= s <= rib_free[1] or s_bridge_from - 20 <= s <= s_bridge_to + 20:
            s += 44.0
            continue
        side = 1.0 if k % 2 == 0 else -1.0
        x, z, f = at(s, side * drng.uniform(40, 52))
        if dput(small[k % 4] if k % 4 != 3 else "island_tiki_torch_pair", x, z, face_road(x, z, f) + drng.uniform(-20, 20),
                drng.uniform(0.9, 1.2)):
            # a composed vignette: a second and third piece tucked behind the first (cargo + chest, anchor + rope)
            for along_, lat_ in ((7.0, 9.0), (-8.0, 11.0)):
                x2, z2, f2 = at(s, side * (abs(math.hypot(x - (f.pos[0] - ORIGIN[0]), z - (f.pos[2] - ORIGIN[2]))) + lat_), along_)
                dput(drng.choice(small[:3]), x2, z2, face_road(x2, z2, f2) + drng.uniform(-40, 40), drng.uniform(0.85, 1.1),
                     spacing=0.7)
        x, z, f = at(s + 22, -side * drng.uniform(42, 56))
        dput(drng.choice(small), x, z, face_road(x, z, f) + drng.uniform(-25, 25), drng.uniform(0.9, 1.2))
        if k % 3 == 0:
            x, z, f = at(s, side * drng.uniform(78, 120), 18)
            dput("island_palm_cluster", x, z, drng.uniform(0, 360), drng.uniform(0.9, 1.25))
        if k % 4 == 1:
            x, z, f = at(s, -side * drng.uniform(58, 80), -16)
            kput(f"RockCluster#{drng.randrange(4)}", x, z, drng.uniform(0, 360), drng.uniform(0.8, 1.1), 11)
        s += 44.0
        k += 1
    # (3) the palm-hut village: cargo, a chest, rope and torches at each hut; the lighthouse yard; the lagoon dock
    for hx, hz in hut_xz:
        for ox, oz, pkey in ((16, 6, "island_cargo_pile"), (-14, 10, "island_treasure_chest"), (6, -16, "island_rope_anchor"),
                            (-10, -14, "island_tiki_torch_pair")):
            dput(pkey, hx + ox, hz + oz, drng.uniform(0, 360), drng.uniform(0.9, 1.15), spacing=0.6)
    lhx, lhz = lh[0] - ORIGIN[0], lh[2] - ORIGIN[2]
    for a_, pkey in ((0.4, "island_rope_anchor"), (1.9, "island_cargo_pile"), (3.3, "island_treasure_chest"),
                    (4.6, "island_tiki_torch_pair")):
        dput(pkey, lhx + 30 * math.cos(a_), lhz + 30 * math.sin(a_), math.degrees(a_) + 90, 1.1, spacing=0.6)
    for ox, oz, pkey in ((-12, -8, "island_cargo_pile"), (12, -10, "island_rope_anchor"), (0, -18, "island_tiki_torch_pair")):
        dput(pkey, lx - 60 + ox, lz - lb + 6 + oz, drng.uniform(0, 360), 1.1, spacing=0.6)
    # (4) break up the open hills and beach backs: palm clusters and boulders well off the line
    tries = 0
    xs_lo, xs_hi = float(sx_all[:, 0].min()) - 160, float(sx_all[:, 0].max()) + 160
    zs_lo, zs_hi = float(sx_all[:, 1].min()) - 160, float(sx_all[:, 1].max()) + 160
    n_fill = 0
    while n_fill < 130 and tries < 12000:
        tries += 1
        x, z = drng.uniform(xs_lo, xs_hi), drng.uniform(zs_lo, zs_hi)
        d = route_dist(x, z)
        if d < 85 or d > 420:
            continue
        if drng.random() < 0.6:
            n_fill += dput("island_palm_cluster", x, z, drng.uniform(0, 360), drng.uniform(0.9, 1.3))
        else:
            n_fill += kput(f"RockCluster#{drng.randrange(4)}", x, z, drng.uniform(0, 360), drng.uniform(1.0, 1.3), 13)
    # (5) the beaches: bleached driftwood near the waterline and skiffs drawn up on the sand (no-collide)
    n_drift, n_skiff, tries = 0, 0, 0
    while (n_drift < 22 or n_skiff < 4) and tries < 6000:
        tries += 1
        x, z = drng.uniform(xs_lo, xs_hi), drng.uniform(zs_lo, zs_hi)
        h = terrain.height(x, z)
        if not (1.0 < h < 3.2) or terrain.material(x, z) != PAL["sand"]:
            continue
        if n_skiff < 4 and drng.random() < 0.3:
            n_skiff += kput("BeachedSkiff", x, z, drng.uniform(0, 360), 1.0, 10, sink=0.3, dry=1.0, min_route=40)
        elif n_drift < 22:
            n_drift += kput(f"Driftwood#{drng.randrange(3)}", x, z, drng.uniform(0, 360), drng.uniform(0.9, 1.2), 9,
                            sink=0.4, dry=1.0, min_route=34)
    # (6) the shipwreck landmark: run aground on the sand bar outside the south-east corner, stern to the road
    s_w = round(st[20] - 20, 1)
    f_w = fr(s_w)
    wreck = None
    for lat_w in (-150, -170, -130, -190, -110):
        q = f_w.offset(lat_w, 0)
        wx_, wz_ = q[0] - ORIGIN[0], q[2] - ORIGIN[2]
        hg = terrain.height(wx_, wz_)
        if -3.0 < hg < 2.0 and route_dist(wx_, wz_) > 90:
            wreck = (wx_, wz_)
            break
    assert wreck is not None
    place("Shipwreck", W(wreck[0], max(terrain.height(*wreck), -2.5) - 0.8, wreck[1]), "Dressing",
          yaw_of(f_w.tangent) + 125.0)
    # (6b) reef colour pops in the shallows beside the road (critic r1 item 12: "reef colour pops in shallows")
    for k in range(4):
        prefabs[f"CoralPatch#{k}"] = prefab_coral_patch(71 + k)
    n_coral, tries = 0, 0
    coral_xz: list[tuple[float, float]] = []
    while n_coral < 44 and tries < 9000:
        tries += 1
        x, z = drng.uniform(xs_lo, xs_hi), drng.uniform(zs_lo, zs_hi)
        h = terrain.height(x, z)
        # v28 critic 1.23 (capture island2_06: red/purple bits at the waterline): the bed sits deep enough that the
        # tallest head (3.0 x scale 1.1, sunk 0.3) stays 0.8 under the surface, below the car's drive depth too
        if not (-7.0 < h < -4.1):
            continue
        d = route_dist(x, z)
        if not (34 < d < 260) or math.hypot(x - centre_xz[0], z - centre_xz[1]) < venue_r + 20:
            continue
        if math.hypot((x - ixc_) / (ia_ + 10), (z - izc_) / (ib_ + 10)) < 1.0:
            continue
        if float(np.min(np.hypot(alt_np[:, 0] - x, alt_np[:, 1] - z))) < 26 or any(math.hypot(x - a, z - b) < 40 for a, b in coral_xz):
            continue
        place(f"CoralPatch#{drng.randrange(4)}", W(x, h - 0.3, z), "Dressing", drng.uniform(0, 360), r3(drng.uniform(0.9, 1.1)))
        coral_xz.append((x, z))
        n_coral += 1
    # (6b2) v28 critic 1.23: palm-and-rock clusters on the Alt2 inland field (capture island2_01: a bare grass plain under
    # the cliff). Own rng, so the draws above and below are unchanged; site_ok keeps 30 + r from the cliff line and
    # min_route from the road, and only flat ground takes a cluster, so nothing stands on the face or the line.
    frng = random.Random(4242 + 23)
    n_field = 0
    field_idx = [i for i in range(len(cliff_np)) if 120.0 <= cliff_cum[i] <= 480.0 or 1080.0 <= cliff_cum[i] <= 1260.0]
    for i in field_idx[::2]:
        for side in (-1.0, 1.0):
            if n_field >= 12:
                break
            d = cliff_dir(i)
            lat = side * frng.uniform(48, 84)
            x, z = float(cliff_np[i][0] - d[1] * lat), float(cliff_np[i][1] + d[0] * lat)
            if slope_at(x, z) > 0.18:
                continue
            if frng.random() < 0.55:
                n_field += dput("island_palm_cluster", x, z, frng.uniform(0, 360), frng.uniform(0.95, 1.25), min_route=50.0)
            else:
                n_field += kput(f"RockCluster#{frng.randrange(4)}", x, z, frng.uniform(0, 360), frng.uniform(0.8, 1.1), 12,
                                min_route=50.0)
    # (6c) pirate ring gates (posts, lanterns and a pennant line framing every booster ring) and rope-post edges on the
    # beach stretches (critic r2: "stronger edge language: darker stone curbs, rope posts"); all no-collide
    for k in range(3):
        prefabs[f"RingGate#{k}"] = prefab_ring_gate(k)
    for k, rg in enumerate(rings):
        if rg.get("line"):
            continue  # a cliff-line ring stands on the rock, not over the road at its mapped station
        f = fr(rg["station"])
        place(f"RingGate#{k % 3}", [f.pos[0], f.pos[1], f.pos[2]], "Dressing", yaw_of(f.tangent))
    n_rope = 0
    for a_, b_ in ((30.0, s_mouth - 40), (s_bridge_to + 40, length - 20)):
        for side in (-1, 1):
            s_r = a_
            while s_r < b_ - 20:
                if side < 0 and alt_join - 20 <= s_r <= alt_rejoin + 20:
                    s_r += 20.0
                    continue
                f0, f1 = fr(s_r), fr(s_r + 20.0)
                q0, q1 = f0.offset(side * 27.5, 0), f1.offset(side * 27.5, 0)
                Ls = math.dist((q0[0], q0[2]), (q1[0], q1[2]))
                g0 = terrain.height(q0[0] - ORIGIN[0], q0[2] - ORIGIN[2]) + SEA
                if g0 < f0.pos[1] - 3.0:
                    s_r += 20.0
                    continue  # the shoulder falls away (an embankment): no post in the air
                key_r = f"RopeSpan_{round(Ls):d}"
                if key_r not in prefabs:
                    prefabs[key_r] = prefab_rope_span(round(Ls))
                yaw_r = math.degrees(math.atan2(-(q1[0] - q0[0]), -(q1[2] - q0[2])))
                place(key_r, [q0[0], max(g0, f0.pos[1] + SHOULDER) - 0.3, q0[2]], "Dressing", yaw_r)
                n_rope += 1
                s_r += 20.0
    # (7) pennant bunting between the right-hand tiki torches on the beach straights and between the village huts
    torch_r = [i["p"] for i in instances if i["pf"] == "TikiTorch"]
    n_bunt = 0
    for a_ in range(len(torch_r) - 1):
        p0, p1 = torch_r[a_], torch_r[a_ + 1]
        Lb = math.dist((p0[0], p0[2]), (p1[0], p1[2]))
        if not (50 < Lb < 70) or n_bunt >= 9:
            continue
        mid_x, mid_z = (p0[0] + p1[0]) / 2 - ORIGIN[0], (p0[2] + p1[2]) / 2 - ORIGIN[2]
        if route_dist(mid_x, mid_z) < 28:
            continue  # only strings that run beside the road, never across it
        key_b = f"Bunting_{round(Lb):d}"
        if key_b not in prefabs:
            prefabs[key_b] = prefab_bunting(Lb, 2.6, len(prefabs))
        yaw_b = math.degrees(math.atan2(-(p1[0] - p0[0]), -(p1[2] - p0[2])))
        place(key_b, [(p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2 + 9.6, (p0[2] + p1[2]) / 2], "Dressing", yaw_b)
        n_bunt += 1
    hut_w = [i["p"] for i in instances if i["pf"].startswith("BeachHut")]
    for a_ in range(len(hut_w) - 1):
        p0, p1 = hut_w[a_], hut_w[a_ + 1]
        Lb = math.dist((p0[0], p0[2]), (p1[0], p1[2]))
        if Lb > 90:
            continue
        mid_x, mid_z = (p0[0] + p1[0]) / 2 - ORIGIN[0], (p0[2] + p1[2]) / 2 - ORIGIN[2]
        if route_dist(mid_x, mid_z) < 40:
            continue
        key_b = f"Bunting_{round(Lb):d}"
        if key_b not in prefabs:
            prefabs[key_b] = prefab_bunting(Lb, 3.5, len(prefabs))
        yaw_b = math.degrees(math.atan2(-(p1[0] - p0[0]), -(p1[2] - p0[2])))
        place(key_b, [(p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2 + 17.0, (p0[2] + p1[2]) / 2], "Dressing", yaw_b)
        n_bunt += 1
    # (8) the smugglers' hall: a chamber carved off the right of the cavern (the grotto is on the left), torch-warm,
    # a treasure hoard, chests and cargo on its sand floor. Inserted before RouteFloorFill so the floor stays sealed.
    s_hall = round(grotto_s + 30, 1)
    f_h = fr(s_hall)
    hall_c = f_h.offset(30.0, 42.0)
    hall_r = 46.0
    assert terrain.height(hall_c[0] - ORIGIN[0], hall_c[2] - ORIGIN[2]) + SEA > hall_c[1] + hall_r + 20
    ifloor = next(i for i, o in enumerate(shell_ops) if o["op"] == "RouteFloorFill")
    shell_ops.insert(ifloor, {"op": "FillBall", "center": [r3(v) for v in hall_c], "r": hall_r, "mat": "Air"})
    floor_y = f_h.pos[1] - 1.0
    hq = f_h.offset(44.0, 0)
    place("TreasureHoard", [hq[0], floor_y + 0.4, hq[2]], "Cavern", yaw_of(f_h.tangent))
    for ox, oz, pkey in ((40, -12, "island_treasure_chest"), (48, 10, "island_treasure_chest"), (42, 24, "island_cargo_pile"),
                        (38, -26, "island_cargo_pile"), (50, -4, "island_rope_anchor")):
        q = fr(s_hall + oz).offset(ox, 0)
        pos = [q[0], floor_y + 2.0, q[2]]
        yaw_h = r3(drng.uniform(0, 360))
        c_, h_ = prop_aabb(lib[pkey], pos, yaw_h, 1.1)
        if corridor_clear(c_, h_):
            dressing.append({"key": pkey, "pos": [r3(v) for v in pos], "yaw": yaw_h, "scale": 1.1, "snap": True})
    fx.append({"class": "PointLight", "name": "HallTorchGlow", "group": "Cavern",
               "cf": [r3(hall_c[0]), r3(hall_c[1] + 6), r3(hall_c[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1],
               "props": {"Brightness": 1.4, "Range": 60, "Color": "#ffb060", "Shadows": False}})
    for dz_ in (-24.0, 24.0):
        q = fr(s_hall + dz_).offset(66.0, 16.0)
        fx.append({"class": "Fire", "cf": [r3(q[0]), r3(q[1]), r3(q[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1], "group": "Cavern",
                   "props": {"Size": 3.0, "Heat": 6, "Color": "#ff8a2a", "SecondaryColor": "#ffd27a"}})
        fx.append({"class": "PointLight", "cf": [r3(q[0]), r3(q[1]), r3(q[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1], "group": "Cavern",
                   "props": {"Brightness": 1.2, "Range": 40, "Color": "#ffa64a", "Shadows": False}})
    # (9) far islands on the horizon (terrain shells, after everything else) with a few big palms on their crowns
    fx0_, fx1_, fz0_, fz1_ = SEA_FRAME
    n_far_palms = 0
    for ii, isl in enumerate(FAR_ISLANDS):
        wx_, wz_, R, H = isl
        rw = math.sqrt(2 * R * H - H * H) + 14.0
        assert fx0_ + 60 < wx_ - rw and wx_ + rw < fx1_ - 60 and fz0_ + 60 < wz_ - rw and wz_ + rw < fz1_ - 60, isl
        gxa, gxb = ORIGIN[0] + terrain.x0, ORIGIN[0] + terrain.x0 + (terrain.nx - 1) * GRID_CELL
        gza, gzb = ORIGIN[2] + terrain.z0, ORIGIN[2] + terrain.z0 + (terrain.nz - 1) * GRID_CELL
        assert not (gxa - rw < wx_ < gxb + rw and gza - rw < wz_ < gzb + rw), isl  # never over the height grid
        shell_ops.append({"op": "FillBall", "center": [r3(wx_), r3(SEA + H - R), r3(wz_)], "r": R, "mat": "Rock"})
        rc = R * 0.72
        shell_ops.append({"op": "FillBall", "center": [r3(wx_), r3(SEA + H + 3.0 - rc), r3(wz_)], "r": r3(rc), "mat": "Grass"})
        shell_ops.append({"op": "FillCylinder", "cf": [r3(wx_), r3(SEA + 0.4), r3(wz_), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                          "h": 3.6, "r": r3(rw), "mat": "Sand"})
        if n_far_palms < 11:
            for maintainer in range(1 + (ii % 2)):
                a_ = drng.uniform(0, 2 * math.pi)
                d_ = rc * drng.uniform(0.15, 0.45)
                top = far_island_top(isl, d_ * math.cos(a_), d_ * math.sin(a_))
                hp = f"HorizonPalm#{(ii + maintainer) % 4}"
                if hp not in prefabs:
                    prefabs[hp] = prefabs[f"PalmTree#{(ii + maintainer) % 4}"]
                place(hp, [r3(wx_ + d_ * math.cos(a_)), r3(SEA + top - 1.0), r3(wz_ + d_ * math.sin(a_))],
                      "Horizon", drng.uniform(0, 360), 1.8)
                n_far_palms += 1

    # (10) ambient fx (critic r0 item 9 "VFX nearly nonexistent"): surf foam where the sea meets the sand and rocks,
    # sun glints on the water beside the road, flames on every tiki torch, sparkle shed by every booster ring.
    # Low rates, beside or below the line, small at phone size.
    import re as _re
    vfx_src = (ROOT / "src" / "shared" / "VfxAssets.luau").read_text()
    flip_src = (ROOT / "src" / "shared" / "VfxFlipAssets.luau").read_text()

    def fx_tex(name: str) -> str:
        m = _re.search(name + r' = \{ id = "(rbxassetid://\d+)"', vfx_src) or _re.search(name + r' = "(rbxassetid://\d+)"', flip_src)
        assert m, name
        return m.group(1)

    sparkle = fx_tex("sparkle_star_4x4")
    star = {"Texture": sparkle, "FlipbookLayout": "Grid4x4", "FlipbookMode": "Loop", "FlipbookFramerate": [24, 24],
            "FlipbookStartRandom": True}
    Hh = terrain.H
    shore = (Hh > -0.8) & (Hh < 0.6)
    nb = np.zeros_like(shore)
    for dz_, dx_ in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nb |= np.roll(np.roll(Hh, dz_, 0), dx_, 1) < -0.9
    cand = np.argwhere(shore & nb)
    foam_pts: list[tuple[float, float]] = []
    order = drng.sample(range(len(cand)), len(cand))
    for ci in order:
        iz_, ix_ = cand[ci]
        x, z = terrain.x0 + ix_ * GRID_CELL, terrain.z0 + iz_ * GRID_CELL
        d = route_dist(x, z)
        if not (46 < d < 320):
            continue
        if math.hypot(x - centre_xz[0], z - centre_xz[1]) < venue_r * 0.6:
            continue
        if any(math.hypot(x - a, z - b) < 70 for a, b in foam_pts):
            continue
        foam_pts.append((x, z))
        if len(foam_pts) >= 48:
            break
    for i, (x, z) in enumerate(foam_pts):
        fx.append({"class": "ParticleEmitter", "name": f"SurfFoam_{i + 1}", "group": "Ambience",
                   "cf": [r3(ORIGIN[0] + x), r3(SEA + 0.5), r3(ORIGIN[2] + z), 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [26, 0.5, 26],
                   "props": {"Texture": "rbxasset://textures/particles/smoke_main.dds", "Rate": 3, "Lifetime": [1.4, 2.4],
                             "Speed": [0.6, 1.6], "SpreadAngle": [70, 70], "Acceleration": [0, 0.4, 0], "Color": "#f6fbff",
                             "LightEmission": 0.2, "Size": {"seq": [[0, 2.5, 0.5], [0.4, 6, 1], [1, 8, 1]]},
                             "Transparency": {"seq": [[0, 0.45, 0], [0.5, 0.6, 0], [1, 1, 0]]},
                             "Rotation": [0, 360], "RotSpeed": [-20, 20]}})
    glints = []
    s = 60.0
    while s < length and len(glints) < 18:
        for side in (-1, 1):
            q = fr(s).offset(side * 120.0, 0)
            x, z = q[0] - ORIGIN[0], q[2] - ORIGIN[2]
            if terrain.height(x, z) < -3.0 and route_dist(x, z) > 90 and not any(math.hypot(x - a, z - b) < 200 for a, b in glints):
                glints.append((x, z))
        s += 70.0
    for i, (x, z) in enumerate(glints):
        fx.append({"class": "ParticleEmitter", "name": f"SeaGlints_{i + 1}", "group": "Ambience",
                   "cf": [r3(ORIGIN[0] + x), r3(SEA + 0.8), r3(ORIGIN[2] + z), 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [90, 0.5, 90],
                   "props": {**star, "Rate": 7, "Lifetime": [0.5, 0.9], "Speed": [0, 0.2], "Color": "#fff6dc",
                             "LightEmission": 1, "Size": {"seq": [[0, 0, 0], [0.4, 1.6, 0.4], [1, 0, 0]]},
                             "Transparency": {"seq": [[0, 0.05, 0], [1, 0.5, 0]]}}})
    drop_tex = fx_tex("water_droplet")
    n_spray = 0
    for i, (sx_s, sz_s, sr_s, _top) in enumerate(STACKS):
        d = route_dist(sx_s, sz_s)
        if d > 420 or math.hypot(sx_s - centre_xz[0], sz_s - centre_xz[1]) < venue_r:
            continue
        n_spray += 1
        fx.append({"class": "ParticleEmitter", "name": f"StackSpray_{n_spray}", "group": "Ambience",
                   "cf": [r3(ORIGIN[0] + sx_s), r3(SEA + 0.6), r3(ORIGIN[2] + sz_s), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                   "size": [sr_s * 2.2, 0.5, sr_s * 2.2],
                   "props": {"Texture": drop_tex, "Rate": 10, "Lifetime": [0.7, 1.2], "Speed": [10, 20], "SpreadAngle": [25, 25],
                             "Acceleration": [0, -55, 0], "Color": "#eefcff", "LightEmission": 0.25, "EmissionDirection": "Top",
                             "Size": {"seq": [[0, 1.1, 0.3], [1, 0.5, 0.1]]}, "Transparency": {"seq": [[0, 0.1, 0], [1, 0.85, 0]]}}})
        fx.append({"class": "ParticleEmitter", "name": f"StackFoam_{n_spray}", "group": "Ambience",
                   "cf": [r3(ORIGIN[0] + sx_s), r3(SEA + 0.4), r3(ORIGIN[2] + sz_s), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                   "size": [sr_s * 2.4, 0.5, sr_s * 2.4],
                   "props": {"Texture": "rbxasset://textures/particles/smoke_main.dds", "Rate": 4, "Lifetime": [1.4, 2.2],
                             "Speed": [0.5, 1.5], "Color": "#f6fbff", "LightEmission": 0.2,
                             "Size": {"seq": [[0, 3, 0.5], [1, 9, 1]]}, "Transparency": {"seq": [[0, 0.4, 0], [1, 1, 0]]}}})
    glow_tex = fx_tex("glow_soft")
    s_m = s_mouth + 60
    n_motes = 0
    while s_m < s_exit - 40:
        q = fr(s_m).offset(0, 22)
        n_motes += 1
        fx.append({"class": "ParticleEmitter", "name": f"CaveMotes_{n_motes}", "group": "Cavern",
                   "cf": [r3(q[0]), r3(q[1]), r3(q[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [60, 26, 60],
                   "props": {"Texture": glow_tex, "Rate": 4, "Lifetime": [4, 6], "Speed": [0.2, 0.8], "SpreadAngle": [180, 180],
                             "Acceleration": [0.3, 0.2, 0.2], "Color": "#ffd9a0", "LightEmission": 0.6,
                             "Size": {"seq": [[0, 0, 0], [0.3, 0.32, 0.1], [0.7, 0.26, 0.1], [1, 0, 0]]},
                             "Transparency": {"seq": [[0, 0.3, 0], [1, 0.8, 0]]}}})
        s_m += 120.0
    for i, tp in enumerate(torch_r):
        fx.append({"class": "Fire", "cf": [r3(tp[0]), r3(tp[1] + 10.4), r3(tp[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1], "group": "Village",
                   "props": {"Size": 2.2, "Heat": 5, "Color": "#ff8a2a", "SecondaryColor": "#ffd27a"}})
    for rg in rings:
        if rg.get("line"):  # a cliff-line ring: its own frame (adapt builds the ring cf the same way)
            c = rg["pos"]
            up = np.array(rg["up"], float)
            up /= np.linalg.norm(up)
            look = np.array(rg["look"], float)
            look -= up * float(look @ up)
            look /= np.linalg.norm(look)
            rot = np.column_stack([np.cross(look, up), up, -look])
        else:
            f = fr(rg["station"])
            c = f.offset(rg["lateral"], rg["height"])
            rot = rot_y(yaw_of(f.tangent))
        fx.append({"class": "ParticleEmitter", "name": f"RingSparkle_{rg['name']}", "group": "Ambience",
                   "cf": [r3(c[0]), r3(c[1]), r3(c[2])] + [r3(v) for v in rot.flatten()], "size": [24, 24, 0.5],
                   "props": {**star, "Shape": "Cylinder", "ShapeStyle": "Surface", "ShapeInOut": "Outward",
                             "EmissionDirection": "Back", "Rate": 10, "Lifetime": [0.9, 1.4], "Speed": [0.4, 1.2],
                             "SpreadAngle": [30, 30], "Color": "#fff1c8", "LightEmission": 1.0,
                             "Size": {"seq": [[0, 0.0, 0], [0.3, 1.2, 0.3], [1, 0.0, 0]]},
                             "Transparency": {"seq": [[0, 0.1, 0], [1, 0.6, 0]]}}})
    dress_counts: dict = {}
    for e in dressing:
        dress_counts[e["key"]] = dress_counts.get(e["key"], 0) + 1
    n_kit = sum(1 for i in instances if i["g"] in (G["Dressing"], G["Horizon"])) + 1
    print(f"setDressing {len(dressing)} {dict(sorted(dress_counts.items()))} kit {n_kit} apexes {len(apexes)} "
          f"foam {len(foam_pts)} glints {len(glints)} bunting {n_bunt} coral {n_coral} alt2Field {n_field} spray {n_spray} rope {n_rope} rejected={dict(sorted(why.items()))}")

    mines = [round(v, 1) for v in (120.0, s_exit + 260, st[11], st[18] + 20, (s_bridge_from + s_bridge_to) / 2 + 40, st[26] + 60)]
    bubbles = [round(v, 1) for v in (grotto_s + 20, s_exit + 150, st[20] + 40, s_bridge_from + 30, st[27] + 40, st[30])]
    boss = {"hazard": "dropped mines, then bubbles in rematch", "encounter": "ISLAND-BOSS", "vehicle": "car",
            "anchors": mines, "mines": {"anchors": mines, "lateral": [-12, 0, 12]},
            "rematch": {"hazard": "bubbles", "anchors": bubbles, "lateral": [-14, 14], "note": "water-side stretches"}}

    # L61 road surfaces by section (critic r1: "the same stone tiling across nearly the whole route kills identity"):
    # packed sand between stone curbs on the beach stretches (the guide's road), darker damp cobble in the cavern,
    # sun-bleached masonry slabs on the lagoon bridge, the cove cobble elsewhere. Deck parts are named per segment
    # (kit/Deck: TrackSeg_i, Paver_i_r_c, segment i starts at waypoint i), so each rule matches a segment range.
    seg_start = [w.station for w in route.waypoints]

    def seg_range(a: float, b: float) -> list[int]:
        return [i + 1 for i in range(len(seg_start) - 1) if a <= seg_start[i] < b]

    def seg_patterns(prefix: str, segs: list[int]) -> list[str]:
        by: dict = {}
        for n in segs:
            by.setdefault(n // 10, []).append(n % 10)
        out = []
        for t in sorted(by):
            ds = sorted(by[t])
            lo, hi = ds[0], ds[-1]
            assert ds == list(range(lo, hi + 1)), ds
            out.append(f"^{prefix}{t if t else ''}[{lo}-{hi}]_" if prefix.startswith("Paver") else f"^{prefix}{t if t else ''}[{lo}-{hi}]$")
        return out

    surfaces = [
        # v28 critic 1.17: cool grey flagstones in the cavern (the warm cobble read orange under the torches); the
        # joint slab matches the pavers, so no guide lines run down the road
        (seg_range(s_mouth - 6, s_exit + 6), {"setMaterial": "Slate", "variant": "SR_ISLAND_Flagstone", "color": "#c6bdb0"},
         {"setMaterial": "Slate", "variant": "SR_ISLAND_Flagstone", "color": "#c6bdb0"}),
        (seg_range(s_bridge_from - 12, s_bridge_to + 12), {"setMaterial": "Slate", "variant": "SR_ISLAND_Masonry", "color": "#f4ecdc"},
         {"setMaterial": "Slate", "variant": "SR_ISLAND_Masonry", "color": "#e2d8c4"}),
        # (r3: the joint slab under the paver seams matches the pavers, so no dark guide lines run down the road)
        # v28 critic 1.17: compacted sand (about 210,170,110 on screen: T1 sand x this tint), one tone for the pavers and
        # the joint slab so the slab seams merge; the grey curbs carry the edge against the loose beach sand
        (seg_range(s_bridge_to + 40, length + 1) + seg_range(0, s_mouth - 30),
         {"setMaterial": "Concrete", "variant": "SR_ISLAND_PackedSand", "color": "#e6d6b8"},
         {"setMaterial": "Concrete", "variant": "SR_ISLAND_PackedSand", "color": "#e6d6b8"}),
    ]
    road_rules = []
    for segs, paver, seg in surfaces:
        for pat in seg_patterns("Paver_", segs):
            road_rules.append({"name": pat, **paver})
        for pat in seg_patterns("TrackSeg_", segs):
            road_rules.append({"name": pat, **seg})

    # --- assemble ---
    alt = {"id": "Alt1", "points": alt_pts, "style": "ledge", "joinStation": alt_join, "rejoinStation": alt_rejoin}
    cliff_alt = {"id": CLIFF_ID, "points": cliff_pts, "style": "cliff", "joinStation": CLIFF_JOIN,
                 "rejoinStation": CLIFF_REJOIN}

    plan = {
        "prefabs": {k: prefabs[k] for k in sorted(prefabs)},
        "instances": instances,
        "groups": groups,
        "terrain": terrain.plan_block(),
        "markers": [],
        "skyrally": {
            "archetype": "Three-way branching coast", "signatureVerb": "branch",
            "signature": "Branch three ways along the coast: beach, cavern or the cliff roof.",
            "id": MAP_ID, "key": KEY, "zone": ZONE, "vehicle": "car", "laps": 3, "guide": GUIDE, "lighting": MAP_ID,
            "route": rt,
            "deck": {"style": "island2_cobble", "width": DECK_WIDTH, "zones": [], "curbHeights": [3.2, 2.6], "gaps": [],
                     "piersEvery": 0},
            "flight": {"lineOffset": LINE_OFFSET, "corridor": CORRIDOR},
            "gameplay": {
                "checkpoints": {"stations": cps, "size": [54, 26, 6], "heightOffset": 8},
                "rings": rings, "pads": pads, "pods": pods,
                "startGrid": {"station": 20, "height": 5, "rowSpacing": 22, "laneOffset": 11},
                "finish": {"station": 0, "radius": 44},
                "alternates": [alt, cliff_alt],
                "coins": coins,
                "key": key,
                "modes": {"battle": battle},
                "boss": boss,
            },
            "shells": {"ops": shell_ops},
            "hazards": [],
            "meshes": [],
            "modelAttributes": [],
            "fx": fx,
            "setDressing": dressing,
            "framing": {"heroStation": 24, "note": "start grid looks north up the crescent beach: galleon in the cove "
                        "at 10 o'clock, cavern mouth arch ahead in the headland, key alcove and inlet to its right "
                        "(10_ISLAND2_CRESCENT_ISLAND.png)"},
            "routeLights": {"every": 4, "fromStation": round(s_mouth + 20, 1), "toStation": round(s_exit - 20, 1),
                            "offsets": [[-27, 14], [27, 14]], "color": "#ffa64a", "range": 44, "brightness": 1.1},
            "materials": {
                "terrainOverrides": {"Sand": "SR_ISLAND_Sand", "Limestone": "SR_ISLAND_WaterBed",
                                     "Rock": "SR_ISLAND_Rock", "Grass": "SR_ISLAND_Grass"},
                # v28 1.7: Sunshine cyan water via the plan materials (terrain.water stays as is: it keys terrain_hash)
                "waterColor": "#14aad2", "waterTransparency": 0.35, "waterReflectance": 0.1,
                "terrainColor": "#ffffff",
                "terrainColors": {m: TERRAIN_TINT.get(m, c) for _, m, c in PALETTE if m in ("Sand", "Rock", "Grass", "Limestone")},
                "partRules": road_rules + [
                    # v28 critic 1.17: cream-grey flagstones (T9 x a near-white cool tint reads ~ 185,170,150), pavers and
                    # joint slab one tone; lighter grey curb blocks that read against both the road and the sand
                    {"name": "^Paver_", "setMaterial": "Cobblestone", "variant": "SR_ISLAND_Cobble", "color": "#fbf8f2"},
                    {"name": "^TrackSeg_", "setMaterial": "Cobblestone", "variant": "SR_ISLAND_Cobble", "color": "#fbf8f2"},
                    {"name": "^Curb", "setMaterial": "Slate", "variant": "SR_ISLAND_Masonry", "color": "#a9a7a2"},
                    {"name": "^BridgeFascia_", "setMaterial": "Slate", "variant": "SR_ISLAND_Masonry", "color": "#cfc6b6"},
                    {"name": "^Alt1Ledge", "setMaterial": "WoodPlanks", "variant": "SR_ISLAND_ShipDeck", "color": "#d6b283"},
                    {"material": "WoodPlanks", "variant": "SR_ISLAND_ShipDeck"},
                    {"material": "Slate", "variant": "SR_ISLAND_Masonry"},
                ],
            },
            "provenance": {
                "author": "tools/map/author_island2.py",
                "origin": list(ORIGIN),
                "routeLength": round(length, 3),
                "routeFlexScale": round(route.flex_scale, 6),
                "minTurnRadius": round(min_r["r"], 1), "minTurnRadiusStation": min_r["st"],
                "maxGradeDeg": round(max_grade, 2),
                "banks": banks,
                "stations": {"cavernMouth": s_mouth, "cavernExit": s_exit, "grotto": grotto_s, "ledgeEnd": s_ledge_end,
                             "lighthouse": s_light, "jumpLip": round(lip, 1), "bridge": [s_bridge_from, s_bridge_to],
                             "crescent": s_crescent, "ribs": rib_stations, "bridgePiers": bridge_piers},
                "jump": car_jump_report(route, lip),
                "terrainGrid": [terrain.nx, terrain.nz, GRID_CELL],
                "seaFrame": list(SEA_FRAME),
                "cliffLine": {**cliff_rep, "join": CLIFF_JOIN, "rejoin": CLIFF_REJOIN, "tell": cliff_tell,
                              "mainStretch": r1(CLIFF_REJOIN - CLIFF_JOIN)},
                "turnBoards": turn_boards,
                "palms": len(palms), "huts": len(huts), "parapets": parapet_count, "tikiTorchStations": len(torch_stations),
                "seeds": {"palms": 4242, "noise": [3, 5, 11], "sky": 20261018},
            },
        },
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    text = dump_json(plan)
    OUT.write_text(text + "\n")
    write_variants()
    make_sky()
    write_preview(terrain, route, plan, palms, alt_pts, cliff_pts)
    parts = sum(len(p["parts"]) for p in prefabs.values())
    print(f"wrote {OUT.relative_to(ROOT)} ({len(text) // 1024} KB) sha256={hashlib.sha256(text.encode()).hexdigest()[:12]}")
    print(f"route      {len(route.waypoints)} waypoints, length {length:.2f}, flexScale {route.flex_scale:.4f}, "
          f"min radius {min_r['r']:.1f} at st {min_r['st']}, max grade {max_grade:.1f}")
    print(f"stations   mouth {s_mouth} exit {s_exit} grotto {grotto_s} bridge {s_bridge_from}-{s_bridge_to} lip {lip:.1f}")
    print(f"jump       {plan['skyrally']['provenance']['jump']}")
    print(f"art        prefabs {len(prefabs)} instances {len(instances)} prefab parts {parts} palms {len(palms)} "
          f"huts {len(huts)} parapets {parapet_count} fx {len(fx)} shellOps {len(shell_ops)}")
    print(f"terrain    {terrain.nx}x{terrain.nz} cell {GRID_CELL}, h {terrain.H.min():.1f}..{terrain.H.max():.1f} (local)")
    print(f"gameplay   checkpoints {len(cps)} rings {len(rings)} pads {len(pads)} pods {len(pods)} coins {len(coins)} "
          f"key st {ks} lat {kl}")


def dump_json(v, ind: int = 0) -> str:
    """Deterministic, diff-friendly JSON: objects one key per line, scalar lists and part rows inline."""
    pad = " " * ind
    if isinstance(v, dict):
        if not v:
            return "{}"
        items = [f'{pad} {json.dumps(k)}: {dump_json(x, ind + 1)}' for k, x in v.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(v, list):
        if not v:
            return "[]"
        if all(not isinstance(x, (dict, list)) for x in v) or all(
                isinstance(x, list) and all(not isinstance(y, (dict, list)) for y in x) for x in v) and len(v) <= 4:
            return json.dumps(v, separators=(",", ":"))
        if all(isinstance(x, list) for x in v):
            return "[\n" + ",\n".join(pad + " " + json.dumps(x, separators=(",", ":")) for x in v) + "\n" + pad + "]"
        return "[\n" + ",\n".join(pad + " " + dump_json(x, ind + 1) for x in v) + "\n" + pad + "]"
    return json.dumps(v)


# --------------------------------------------------------------------------------------------- QA preview
def write_preview(terrain: Terrain, route: routelib.Route, plan: dict, palms, alt_pts, cliff_pts) -> None:
    from PIL import Image, ImageDraw

    cols = {PAL["sand"]: (242, 223, 176), PAL["rock"]: (150, 145, 138), PAL["grass"]: (108, 191, 76),
            PAL["seabed"]: (120, 222, 220), PAL["deep"]: (40, 110, 160)}
    H, M = terrain.H, terrain.M
    img = np.zeros(H.shape + (3,), float)
    for k, c in cols.items():
        img[M == k] = c
    gz, gx = np.gradient(H, GRID_CELL)
    shade = np.clip(1.0 - 0.35 * (gx * 0.7 - gz * 0.7), 0.55, 1.25)
    img = np.clip(img * shade[..., None], 0, 255)
    im = Image.fromarray(img.astype(np.uint8), "RGB").resize((H.shape[1] * 3, H.shape[0] * 3), Image.NEAREST)
    dr = ImageDraw.Draw(im)

    def px(wx, wz):
        return ((wx - ORIGIN[0] - terrain.x0) / GRID_CELL * 3, (wz - ORIGIN[2] - terrain.z0) / GRID_CELL * 3)

    pts = [px(w.pos[0], w.pos[2]) for w in route.waypoints]
    dr.line(pts, fill=(60, 60, 60), width=16)
    dr.line(pts, fill=(246, 238, 220), width=12)
    dr.line([px(p[0], p[2]) for p in alt_pts], fill=(160, 110, 60), width=8)
    dr.line([px(p[0], p[2]) for p in cliff_pts], fill=(255, 178, 60), width=6)
    for s in range(0, int(route.length), 250):
        p = px(*[route.frame_at(s).pos[i] for i in (0, 2)])
        dr.ellipse([p[0] - 5, p[1] - 5, p[0] + 5, p[1] + 5], fill=(200, 40, 40))
        dr.text((p[0] + 8, p[1] - 6), str(s), fill=(0, 0, 0))
    for inst in plan["instances"]:
        pf = inst["pf"]
        p = px(inst["p"][0], inst["p"][2])
        if pf.startswith("Palm"):
            dr.ellipse([p[0] - 4, p[1] - 4, p[0] + 4, p[1] + 4], fill=(30, 120, 40))
        elif pf.startswith("Galleon"):
            dr.rectangle([p[0] - 6, p[1] - 6, p[0] + 6, p[1] + 6], fill=(110, 70, 40))
        elif pf in ("Lighthouse", "KeyAlcoveArch", "StartFinishArch") or pf.startswith(("Cavern", "BeachHut")):
            dr.rectangle([p[0] - 5, p[1] - 5, p[0] + 5, p[1] + 5], fill=(230, 120, 30))
    k = plan["skyrally"]["gameplay"]["key"]["pos"]
    p = px(k[0], k[2])
    dr.ellipse([p[0] - 7, p[1] - 7, p[0] + 7, p[1] + 7], fill=(255, 215, 0), outline=(0, 0, 0))
    b = plan["skyrally"]["gameplay"]["modes"]["battle"]
    c = px(b["center"][0], b["center"][2])
    r = b["radius"] / GRID_CELL * 3
    dr.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], outline=(200, 0, 160), width=3)
    for bar in b.get("barriers", []):  # battle-only barriers: a magenta bar across the road
        cf, half = bar["cf"], bar["collider"]["size"][0] / 2
        a = px(cf[0] - cf[3] * half, cf[2] - cf[9] * half)
        z = px(cf[0] + cf[3] * half, cf[2] + cf[9] * half)
        dr.line([a, z], fill=(200, 0, 160), width=6)
    im.save(PREVIEW, optimize=False)


if __name__ == "__main__":
    main()
