#!/usr/bin/env python3
"""TRACK_PIPELINE P1 author script for FOREST-1 "Windmill Countryside" (plane), the FOREST launch track.

Design data in this file -> map/forest1/plan.json (docs/MAP_PLAN_SCHEMA.md), assets/materials/forest_v1/variants.json and
the procedural sky faces assets/sky/forest1/{up,side,down}.png. Deterministic (fixed seeds, no clock, no dict-order
dependence). Change the map here and rerun, then `python3 tools/map/adapt.py map/forest1/plan.json`; never edit the
plan or build/forest1/* by hand.

Guide: docs/guides/forest1.md (authorized by D08). Composition kept:
  first gameplay view = cobblestone road running north between two hero windmills, ground boost arches standing on the
  road, the stone aqueduct on the left with three waterfalls into a pool and a river that crosses under the road ahead,
  windmills on bright green hills in the distance and the high flight line of aerial rings rising ahead-right.
Lap (clockwise from above, ~5200 studs, 3 laps):
  start road north -> river arch bridge -> lift-off: aerial ring climb into the HIGH FLIGHT LINE over the windmill field,
  mill yard and north hills -> long right sweep east -> dive to Tunnel Hill -> cobblestone TUNNEL (TunnelMill on top;
  its cellar = the windmill base holding the hidden key, a side gallery that leaves the tunnel just inside the north
  mouth and rejoins it) -> Windy Gap saddle -> south river meadows -> right bend around Granary Hill (Alt1: tunnel
  shortcut through the hill, cobble ledge floor in a carved Terrain tube) -> under the aqueduct's GREAT ARCH -> finish.
Construction (ART_BAR construction rules): all organic masses are Terrain (30MAPS height grid, cell 8: rolling meadow,
  hills, rim mountains, river/pool/mill pond under one water level, mesas for Tunnel Hill and Granary Hill) plus
  shells ops applied after the grid (tunnel tube, tunnel floor, key gallery and cellar, Alt1 tube and floor, cascade rocks).
  Masonry and machinery (windmills, sails, aqueduct, portals, bridge, cellar, barn) are Raiser-style studless
  block-built 30MAPS prefabs: octagonal prisms are four rotated blocks, tapers are stepped tiers, arches are voussoir
  rings. Sails are separate prefabs (one per mill, pivot = hub, spin axis = pivot LookVector) for the integrator to
  animate; they are no-collide. The road is the kit deck (style forest1_cobble, piersEvery 0) with a deck gap over
  the high flight line; a cobblestone terrain path continues the road below it to the mill yard and the tunnel.

World placement: ORIGIN offsets the whole map (x, z). The 30MAPS builder writes Air over its grid's whole footprint,
so FOREST-1 (grid world x -1680..792, z -7592..-5120) must not overlap another map: checked 2026-10-18 against
DINO-4, HUB-0, ISLAND-2, SNOW-1, SPACE-4 and TEST-STRIP (tools/map/tests/test_forest1.py re-checks every plan).
Heights are absolute: valley road ~61, water level 50 (FlightController crashes below y=16).
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
import item_rows  # noqa: E402  (item cubes v2 layout rules, tools/map/item_cubes.json)

KEY = "forest1"
MAP_ID = "FOREST-1"
OUT = ROOT / "map" / KEY / "plan.json"
VARIANTS_OUT = ROOT / "assets" / "materials" / "forest_v1" / "variants.json"
SKY_DIR = ROOT / "assets" / "sky" / KEY
GUIDE = "docs/guides/forest1.md"

ORIGIN = (-1000.0, 0.0, -6200.0)  # world offset of local (0, y, 0); y stays absolute. Grid ~x -1680..792, z -7592..-5120
TARGET_LENGTH = 5200
WATER_LEVEL = 50.0
ROAD_Y = 61.0
DECK_WIDTH = 28
AQ_DECK = 150.0  # aqueduct deck top (water channel level), absolute
SEED = 4113  # every random choice below derives from this

# ------------------------------------------------------------------------------------------------ route
# (x, y, z, bank, (flex x, y, z)) in LOCAL coordinates (x east, z south; heading north = -z). Positive bank raises the
# right edge of the deck (kit/Deck), i.e. leans into a left turn. flex grows the loop outward so the adapter's bisection
# lands the length exactly on TARGET_LENGTH.
NODES = [
    (0.0, 61.0, 0.0, 0.0, (0, 0, 0)),          # 0  start / finish, heading north
    (0.0, 62.0, -140.0, 0.0, (0, 0, 0)),
    (0.0, 68.0, -290.0, 0.0, (0, 0, 0)),       # 2  river arch bridge (hump)
    (3.0, 84.0, -425.0, 0.0, (0, 0, 0)),       # 3  lift-off: deck ends, aerial ring climb
    (40.0, 134.0, -565.0, 0.0, (0, 0, -12)),
    (120.0, 182.0, -695.0, 0.0, (0, 0, -20)),
    (240.0, 216.0, -805.0, 0.0, (0, 0, -28)),
    (400.0, 236.0, -885.0, 0.0, (0, 0, -36)),  # 7  high flight line over the windmill field / mill yard
    (590.0, 238.0, -935.0, 0.0, (0, 0, -40)),
    (800.0, 240.0, -945.0, 0.0, (20, 0, -40)),
    (1000.0, 230.0, -900.0, 0.0, (40, 0, -32)),
    (1165.0, 210.0, -805.0, 0.0, (52, 0, -16)),
    (1275.0, 180.0, -670.0, 0.0, (60, 0, 0)),
    (1315.0, 140.0, -535.0, 0.0, (60, 0, 0)),  # 13 dive to Tunnel Hill
    (1320.0, 100.0, -415.0, 0.0, (60, 0, 0)),
    (1315.0, 70.0, -300.0, 0.0, (60, 0, 0)),   # 15 touchdown: deck resumes
    (1310.0, 63.0, -180.0, 0.0, (60, 0, 0)),
    (1305.0, 63.0, -40.0, 0.0, (60, 0, 0)),    # 17 inside the tunnel
    (1295.0, 63.0, 100.0, 0.0, (60, 0, 12)),
    (1255.0, 70.0, 235.0, 0.0, (48, 0, 28)),
    (1165.0, 92.0, 345.0, 0.0, (32, 0, 40)),   # 20 Windy Gap crest
    (1035.0, 98.0, 435.0, 0.0, (16, 0, 48)),
    (870.0, 84.0, 515.0, 0.0, (0, 0, 52)),
    (690.0, 68.0, 575.0, 0.0, (0, 0, 52)),
    (500.0, 62.0, 615.0, 0.0, (0, 0, 48)),     # 24 south river meadows
    (320.0, 62.0, 635.0, -3.0, (0, 0, 40)),
    (150.0, 62.0, 600.0, -4.0, (0, 0, 28)),    # 26 bend around Granary Hill (Alt1 inside)
    (35.0, 62.0, 495.0, -3.0, (0, 0, 12)),
    (0.0, 62.0, 355.0, 0.0, (0, 0, 0)),        # 28 under the aqueduct great arch
    (0.0, 61.5, 190.0, 0.0, (0, 0, 0)),
]

RADIUS_EXCEPTIONS: list[dict] = []
SAMPLES_PER_SEGMENT = 9
FLIGHT_LINE = 14.0      # flight.lineOffset: the plane line above the ribbon
RIM_MARGIN = 30.0       # rim cliff crest above the highest drift-reachable flight line (traps_forest1 F5)
RIM_DRIFT_DEG = 1.0     # design glide: half the -2 deg a neutral-input nose settles at, so near-level flight is covered
RIM_CLIFF_SLOPE = 1.4   # rim cliff face rise per stud (~54 deg: a crash even from a 15-deg foothill climb)
RIM_FOOTHILL = 50.0     # foothill height at the edge (smoothstep over RIM_BAND: steepest 14 deg)
RIM_BAND = 300.0        # foothills and cliff live within this distance of the grid edge
ALT_TUBE_R = 28.0     # Alt1 Terrain tube radius (contains the adapter's ledge carve box +-20, +4..+40)
ALT_TUBE_LIFT = 22.0  # tube centre above the alternate line


def world(x: float, z: float) -> tuple[float, float]:
    return x + ORIGIN[0], z + ORIGIN[2]


def plan_nodes() -> list[dict]:
    out = []
    for x, y, z, bank, flex in NODES:
        wx, wz = world(x, z)
        out.append({"pos": [wx, y, wz], "bank": bank, "flex": [float(v) for v in flex]})
    return out


def route_block() -> dict:
    return {"nodes": plan_nodes(), "closed": True, "samplesPerSegment": SAMPLES_PER_SEGMENT,
            "targetLength": TARGET_LENGTH, "flexScaleMin": 0.0, "flexScaleMax": 3.5, "bisectIterations": 24,
            "minRadius": 85, "radiusExceptions": RADIUS_EXCEPTIONS}


class Track:
    """The solved route (exactly what adapt.py computes) plus dense samples for terrain work."""

    def __init__(self) -> None:
        self.route = routelib.solve_plan_route(route_block())
        self.length = self.route.length
        n = int(self.length // 6)
        self.st = np.array([self.length * i / n for i in range(n)])
        fr = [self.route.frame_at(float(s)) for s in self.st]
        self.pos = np.array([f.pos for f in fr])
        self.tan = np.array([f.tangent for f in fr])
        self.right = np.array([f.right for f in fr])

    def frame(self, s: float) -> routelib.Frame:
        return self.route.frame_at(s % self.length)

    def at(self, s: float, lateral: float = 0.0, height: float = 0.0) -> np.ndarray:
        """frame.offset (what adapt.py uses for rings/pods): right * lateral + frame.up * height."""
        return np.array(self.frame(s).offset(lateral, height))

    def ground_point(self, s: float, lateral: float) -> np.ndarray:
        """Horizontal lateral offset at the waypoint's height (for placing things on the ground)."""
        f = self.frame(s)
        return np.array(f.pos) + np.array(f.right) * lateral

    def yaw_facing(self, s: float, sign: float = -1.0) -> float:
        """Yaw (deg) that turns a prefab's front (local -Z) to face back along the route (sign -1) or forward (+1)."""
        t = np.array(self.frame(s).tangent)
        d = t * sign  # direction the front should face: -1 back toward the approaching racer, +1 forward
        return math.degrees(math.atan2(-d[0], -d[2]))

    def project(self, p) -> tuple[float, float, float]:
        """Station, lateral, height (frame.up) of point p; lateral/height reproduce p exactly via frame.offset when
        the residual along the tangent is ~0 (checked by callers)."""
        p = np.asarray(p, float)
        d = np.linalg.norm(self.pos - p, axis=1)
        i = int(np.argmin(d))
        best = None
        for s in np.linspace(self.st[i] - 12, self.st[i] + 12, 97):
            f = self.frame(float(s))
            r = p - np.array(f.pos)
            along = float(r @ np.array(f.tangent))
            if best is None or abs(along) < abs(best[3]):
                best = (float(s) % self.length, float(r @ np.array(f.right)), float(r @ np.array(f.up)), along)
        return best[0], best[1], best[2]


# ------------------------------------------------------------------------------------------------ parts
def P(shape, x, y, z, sx, sy, sz, rx, ry, rz, colour, mat, extra=None):
    spec = [shape, r3(x), r3(y), r3(z), r3(sx), r3(sy), r3(sz), r3(rx), r3(ry), r3(rz), colour, mat]
    if extra:
        spec.append(extra)
    return spec


def r3(v):
    v = round(float(v), 3)
    return 0.0 if v == 0 else v


def r2(v):
    v = round(float(v), 2)
    return 0.0 if v == 0 else v


TAN225 = math.tan(math.radians(22.5))


def octa(a, h, y0, colour, mat, x=0.0, z=0.0, extra=None):
    """Regular octagonal prism (apothem a, from y0 to y0+h) as four rotated blocks: the union of four 2a x s bands at
    0/45/90/135 degrees is exactly the octagon (every interior point lies within a*tan(22.5) of its nearest band)."""
    s = 2 * a * TAN225
    return [P("B", x, y0 + h / 2, z, 2 * a, h, s, 0, yaw, 0, colour, mat, extra) for yaw in (0, 45, 90, 135)]


def ring_slabs(r_in, thick, h, y0, n, colour, mat, skip=(), extra=None, phase=0.0):
    """Polygonal wall ring of n slabs (inner radius r_in). skip: slab indices left open (doors). Angle phi_k is
    measured from +X toward +Z; slab k faces radially outward."""
    out = []
    rm = r_in + thick / 2
    w = 2 * rm * math.tan(math.pi / n) * 1.03
    for k in range(n):
        if k in skip:
            continue
        phi = phase + 360.0 * k / n
        x, z = rm * math.cos(math.radians(phi)), rm * math.sin(math.radians(phi))
        out.append(P("B", x, y0 + h / 2, z, w, h, thick, 0, 90 - phi, 0, colour, mat, extra))
    return out


def voussoirs(cx, cy, r_in, depth, n, colour, mat, z=0.0, a0=0.0, a1=180.0, thick=8.0, extra=None):
    """Arch ring in the local XY plane: n blocks between angles a0..a1 (deg, 0 = +X), intrados radius r_in."""
    out = []
    rm = r_in + thick / 2
    step = (a1 - a0) / n
    tl = 2 * rm * math.sin(math.radians(step / 2)) * 1.06
    for i in range(n):
        a = a0 + step * (i + 0.5)
        x = cx + rm * math.cos(math.radians(a))
        y = cy + rm * math.sin(math.radians(a))
        out.append(P("B", x, y, z, tl, thick, depth, 0, 0, a + 90, colour, mat, extra))
    return out


# Palette (guide): cream plaster, warm brown wood, light sail wood + cream canvas, grey mossy masonry, terracotta roofs.
PLASTER = "#f4e4c6"
PLASTER_B = "#efdbb9"
PLASTER_C = "#f7ead2"
CAP_WOOD = "#d9a878"     # WoodPlanks x SR_FOREST_MillWood (red-brown painted boards) -> warm brown
DARK_WOOD = "#8a5a36"
SAIL_WOOD = "#e9c690"
CANVAS = "#f6eedb"
MASONRY = "#ece9de"      # Slate x SR_FOREST_Masonry (mossy grey stone) keeps the texture's own colour
MASONRY_B = "#dcd8ca"
MASONRY_DARK = "#bdb8a6"
ROOF = "#c8653c"
ROOF_B = "#b4552f"
WATER = "#8fe0f4"
FOAM = "#ffffff"
# L61: sea-grass foliage (critic r0: "neon"): a deep blue-green shadow mass, a mid green and a warm sunlit crown, so
# every canopy reads lit-side / shade-side under the low afternoon sun; golden and russet accents for a few trees.
LEAF_A, LEAF_B, LEAF_C = "#4f8048", "#6d9a52", "#3f6b44"
LEAF_SUN = "#8fb25a"
POPLAR_A, POPLAR_B = "#4a7a48", "#5f8a4e"
AUTUMN_A, AUTUMN_B = "#d39a3c", "#c06a36"
TRUNK = "#7a5232"
STRAW = "#e8cb6a"
WINDOW = "#3c3448"
GOLD = "#e0a834"


def pf_windmill(far: bool = False) -> list:
    """Hero windmill body (guide): stone plinth, four stepped cream plaster tiers with a brown gallery band, faceted
    wooden cap, door and windows on the front (local -Z), axle box carrying the sails hub at (0, 61, -15).
    far = True (L61, the skyline hill mills 500+ studs off the line): each octagonal tier is one cylinder instead of
    four blocks, the same silhouette at that distance for a third of the parts."""
    def tier(a, h, y0, colour, mat, x=0.0, z=0.0, extra=None):
        if not far:
            return octa(a, h, y0, colour, mat, x, z, extra)
        return [P("C", x, y0 + h / 2, z, 2.08 * a, h, 2.08 * a, 0, 0, 0, colour, mat, extra)]
    p = []
    p += tier(15.5, 6, -4, MASONRY_B, "Slate")
    p += tier(14.0, 2, 2, MASONRY, "Slate")
    p += tier(12.6, 16, 4, PLASTER, "Plaster")
    p += tier(11.6, 14, 20, PLASTER_B, "Plaster")
    p += tier(13.4, 2.4, 33.6, CAP_WOOD, "WoodPlanks")
    p += tier(10.6, 12, 34, PLASTER, "Plaster")
    p += tier(9.6, 10.2, 46, PLASTER_C, "Plaster")
    p += tier(11.4, 2.4, 56, DARK_WOOD, "WoodPlanks")
    p += tier(10.6, 4.2, 58.2, CAP_WOOD, "WoodPlanks")
    p += tier(9.0, 3.6, 62.2, CAP_WOOD, "WoodPlanks")
    p += tier(7.0, 3.0, 65.6, CAP_WOOD, "WoodPlanks")
    p += tier(4.4, 2.6, 68.4, DARK_WOOD, "WoodPlanks")
    p.append(P("B", 0, 72.4, 0, 1.6, 3.2, 1.6, 0, 45, 0, GOLD, "Metal"))
    # axle box out of the cap front, axle to the hub
    p.append(P("B", 0, 61, -10.5, 6.5, 6.5, 6.0, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("B", 0, 61, -13.6, 2.4, 2.4, 3.2, 0, 0, 0, "#6e6a62", "Metal"))
    # door (front face of tier 1 is z = -12.6)
    p.append(P("B", 0, 10.2, -12.75, 8.4, 12.4, 1.0, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("B", 0, 9.4, -13.05, 6.2, 10.0, 0.8, 0, 0, 0, "#a5703f", "WoodPlanks"))
    p.append(P("B", 0, 16.9, -13.0, 10.0, 1.4, 1.6, 0, 0, 0, MASONRY, "Slate"))
    # windows: front of tier 3, side of tier 2, back of tier 4
    p.append(P("B", 0, 41.5, -10.75, 4.8, 5.8, 0.6, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("B", 0, 41.5, -10.95, 3.4, 4.4, 0.5, 0, 0, 0, WINDOW, "SmoothPlastic"))
    p.append(P("B", 11.75, 27, 0, 0.6, 5.4, 4.4, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("B", 11.95, 27, 0, 0.5, 4.0, 3.0, 0, 0, 0, WINDOW, "SmoothPlastic"))
    p.append(P("B", 0, 50.5, 9.75, 4.0, 4.6, 0.6, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("B", 0, 50.5, 9.95, 2.8, 3.4, 0.5, 0, 0, 0, WINDOW, "SmoothPlastic"))
    return p


SAIL_HUB = (0.0, 61.0, -15.6)  # hub position in the Windmill prefab frame (front = local -Z)


def pf_sails() -> list:
    """Four lattice sails in an X (guide): wooden stocks, side rails and cross bars framing cream canvas panels.
    Pivot = hub; the sail plane is local XY, so the spin axis is the pivot's LookVector. All no-collide."""
    nc = {"nc": 1}
    p = [P("B", 0, 0, 0, 5.2, 5.2, 3.2, 0, 0, 45, DARK_WOOD, "WoodPlanks", nc),
         P("B", 0, 0, -1.9, 2.6, 2.6, 1.2, 0, 0, 45, GOLD, "Metal", nc)]
    for k in range(4):
        th = 45 + 90 * k
        c, s = math.cos(math.radians(th)), math.sin(math.radians(th))
        d, n = np.array([c, s]), np.array([-s, c])

        def at(r, off, z=0.0):
            q = d * r + n * off
            return q[0], q[1], z

        x, y, z = at(22, 0)
        p.append(P("B", x, y, z, 44, 1.7, 1.5, 0, 0, th, SAIL_WOOD, "Wood", nc))       # stock
        x, y, z = at(25.5, 9.4)
        p.append(P("B", x, y, z, 38, 1.1, 1.1, 0, 0, th, SAIL_WOOD, "Wood", nc))       # outer rail
        bars = [6.5 + 7.5 * i for i in range(6)]
        for r in bars:
            x, y, z = at(r, 4.7)
            p.append(P("B", x, y, z, 1.1, 9.4, 1.1, 0, 0, th, SAIL_WOOD, "Wood", nc))  # cross bar
        # one canvas sheet behind the lattice (L61: was five panels; the bars in front still read as the lattice,
        # 16 fewer parts per mill)
        x, y, z = at((bars[0] + bars[-1]) / 2, 4.7, 0.55)
        p.append(P("B", x, y, z, bars[-1] - bars[0], 8.4, 0.4, 0, 0, th, CANVAS, "Fabric", nc))   # canvas sheet
    return p


def pf_aqueduct_bay(width=44.0, tone=0) -> list:
    """One aqueduct bay along local X (origin = deck top centre). Tall single-tier arch (guide): pier at -width/2 (the
    next bay supplies the other), semicircular arch of span width-14, spandrel fill, deck, cornice, parapets and a
    water channel. Piers run 110 studs down so they bury into any ground."""
    hw = width / 2
    r_in = hw - 7
    spring = -11 - r_in  # crown at -11
    # L61 (critic r0: "tiled blockout wall"): tone 1 bays are a warmer, darker stone so the long run reads as
    # weathered masonry in irregular runs, not one repeated tile
    stone, stone_b = (MASONRY, MASONRY_B) if tone == 0 else ("#ddd3bd", "#cfc5ad")
    p = []
    p.append(P("B", -hw, (spring - 120) / 2, 0, 14, spring + 120, 10.5, 0, 0, 0, stone, "Slate"))
    p.append(P("B", -hw, spring + 0.9, 0, 16.4, 1.8, 12.2, 0, 0, 0, stone_b, "Slate"))
    p += voussoirs(0, spring, r_in, 10.4, 7, stone, "Slate", thick=5.6)
    p.append(P("B", -hw + 3.6, (spring - 6.2) / 2, 0, 7.2, -6.2 - spring, 10.2, 0, 0, 0, stone, "Slate"))
    p.append(P("B", hw - 3.6, (spring - 6.2) / 2, 0, 7.2, -6.2 - spring, 10.2, 0, 0, 0, stone, "Slate"))
    p.append(P("B", 0, -8.6, 0, width, 5.0, 10.2, 0, 0, 0, stone, "Slate"))
    p.append(P("B", 0, -6.8, 0, width, 1.6, 13.4, 0, 0, 0, stone_b, "Slate"))
    p.append(P("B", 0, -3.6, 0, width, 4.8, 12.2, 0, 0, 0, stone, "Slate"))
    p.append(P("B", 0, 1.4, 5.3, width, 3.2, 1.8, 0, 0, 0, MASONRY_DARK, "Slate"))
    p.append(P("B", 0, 1.4, -5.3, width, 3.2, 1.8, 0, 0, 0, MASONRY_DARK, "Slate"))
    p.append(P("B", 0, -0.6, 0, width, 1.0, 8.8, 0, 0, 0, WATER, "Glass", {"nc": 1, "a": 0.25}))
    # moss creeping out under the cornice on both faces (value break between deck and arch)
    for z in (-5.35, 5.35):
        p.append(P("B", 0, -10.2, z, width - 2, 2.4, 0.7, 0, 0, 0, LEAF_C, "Grass"))
    return p


GREAT_R = 50.0      # great arch intrados radius (corridor: +-34 lateral, ribbon +5..+44)
GREAT_SPRING = 22.0  # spring line above the ribbon


def pf_aqueduct_great_arch(spring_rel: float) -> list:
    """Great arch over the final straight (origin = deck top centre, local X along the aqueduct). spring_rel = spring
    line relative to the deck top (negative). Piers at +-(R+7), a double voussoir ring and haunch fill."""
    R = GREAT_R
    hw = R + 14
    p = []
    for sx in (-1, 1):
        p.append(P("B", sx * (R + 7), (spring_rel - 120) / 2, 0, 14, spring_rel + 120, 11, 0, 0, 0, MASONRY, "Slate"))
        p.append(P("B", sx * (R + 7), spring_rel + 1, 0, 17, 2, 13, 0, 0, 0, MASONRY_B, "Slate"))
        p.append(P("B", sx * (R + 11), (spring_rel - 6.2) / 2, 0, 6, -6.2 - spring_rel, 10.4, 0, 0, 0, MASONRY, "Slate"))
    p += voussoirs(0, spring_rel, R, 11.4, 11, MASONRY, "Slate", thick=7.0)
    p += voussoirs(0, spring_rel, R + 7.0, 10.4, 9, MASONRY_B, "Slate", thick=4.0)
    crown = spring_rel + R + 11
    # haunch fill between the ring and the deck, stepped
    for i, (x0, x1) in enumerate(((R * 0.55, R + 8), (R * 0.2, R * 0.55))):
        ytop = -6.2
        ybot = spring_rel + math.sqrt(max(0.0, (R + 11) ** 2 - x0 ** 2)) - 1
        if ybot < ytop:
            for sx in (-1, 1):
                p.append(P("B", sx * (x0 + x1) / 2, (ybot + ytop) / 2, 0, x1 - x0, ytop - ybot, 10.2, 0, 0, 0, MASONRY, "Slate"))
    if crown < -6.2:
        p.append(P("B", 0, (crown - 6.2) / 2, 0, R * 0.4 + 2, -6.2 - crown, 10.2, 0, 0, 0, MASONRY, "Slate"))
    p.append(P("B", 0, -6.8, 0, 2 * hw, 1.6, 13.6, 0, 0, 0, MASONRY_B, "Slate"))
    p.append(P("B", 0, -3.6, 0, 2 * hw, 4.8, 12.4, 0, 0, 0, MASONRY, "Slate"))
    p.append(P("B", 0, 1.4, 5.3, 2 * hw, 3.2, 1.8, 0, 0, 0, MASONRY_DARK, "Slate"))
    p.append(P("B", 0, 1.4, -5.3, 2 * hw, 3.2, 1.8, 0, 0, 0, MASONRY_DARK, "Slate"))
    p.append(P("B", 0, -0.6, 0, 2 * hw, 1.0, 8.8, 0, 0, 0, WATER, "Glass", {"nc": 1, "a": 0.25}))
    # keystone (Majora-style contrasting inset)
    p.append(P("B", 0, crown - 3.5, 0, 6, 9, 12.4, 0, 0, 0, MASONRY_B, "Slate"))
    return p


def pf_aqueduct_tower() -> list:
    """Corner / head tower (origin = aqueduct deck top centre): square masonry shaft from deep below to above the
    deck, a corbelled cornice and a terracotta pyramid roof of stepped wedges."""
    p = [P("B", 0, -60, 0, 24, 132, 24, 0, 0, 0, MASONRY, "Slate"),
         P("B", 0, 7.5, 0, 27, 3, 27, 0, 0, 0, MASONRY_B, "Slate"),
         P("B", 0, 11, 0, 22, 4, 22, 0, 0, 0, PLASTER, "Plaster")]
    for i, (w, y) in enumerate(((26, 15.5), (19, 21.5), (11, 26.5))):
        h = 6 if i < 2 else 5
        for yaw in (0, 90, 180, 270):
            c = (ROOF, ROOF_B)[(i + yaw // 90) % 2]
            dx, dz = -math.sin(math.radians(yaw)) * w / 4, -math.cos(math.radians(yaw)) * w / 4
            p.append(P("W", dx, y, dz, w, h, w / 2, 0, yaw, 0, c, "ClayRoofTiles"))
    p.append(P("B", 0, 30, 0, 1.6, 4, 1.6, 0, 45, 0, GOLD, "Metal"))
    # arched windows (dark inset) on each face below the cornice
    for yaw in (0, 90, 180, 270):
        dx, dz = -math.sin(math.radians(yaw)) * 12.1, -math.cos(math.radians(yaw)) * 12.1
        p.append(P("B", dx, -4, dz, 5, 9, 0.6, 0, yaw, 0, WINDOW, "SmoothPlastic"))
    return p


def pf_spring_house() -> list:
    """Aqueduct head at Granary Hill (origin = deck top centre): masonry block with an arched outlet and a roof."""
    p = [P("B", 8, -40, 0, 26, 92, 30, 0, 0, 0, MASONRY, "Slate"),
         P("B", 8, 7.5, 0, 29, 3, 33, 0, 0, 0, MASONRY_B, "Slate"),
         P("B", 8, 13, 0, 24, 8, 28, 0, 0, 0, PLASTER, "Plaster")]
    p.append(P("W", 8, 21, -7, 26, 8, 14, 0, 0, 0, ROOF, "ClayRoofTiles"))
    p.append(P("W", 8, 21, 7, 26, 8, 14, 0, 180, 0, ROOF_B, "ClayRoofTiles"))
    p += voussoirs(-5.2, -4, 4.5, 3, 5, MASONRY_DARK, "Slate", z=0, thick=2.4)
    p.append(P("B", -5.2, -6, 0, 0.6, 8, 9, 0, 0, 0, WINDOW, "SmoothPlastic"))
    return p


FALL_FRACS = (0.34, 0.67, 1.0)   # tier break heights as a fraction of the drop (ledge 1, ledge 2, pool)


def fall_geometry(drop: float) -> dict:
    """Shared tier layout of pf_waterfall and its emitters (prefab-local: +X outward from the bay face, Y rel. deck top)."""
    y1, y2, y3 = (-0.5 - drop * f for f in FALL_FRACS)
    return {"ys": (y1, y2, y3), "xs": (11.5, 19.0, 31.0), "front": (14.0, 25.0), "w": (22.0, 24.0, 26.0)}


def curved_sheet(x0, y0, x1, y1, w, n=5, thick=0.8, colour=WATER, mat="Glass", extra=None):
    """A falling sheet as n chained slabs along a parabola (leaves the lip level, ends near vertical): the curved-sheet
    read of the guide without a texture upload. Width along local Z; every slab is no-collide."""
    out = []
    pts = [(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * (k / n) ** 2) for k in range(n + 1)]
    for (xa, ya), (xb, yb) in zip(pts[:-1], pts[1:]):
        ln = math.hypot(xb - xa, yb - ya) + 0.5
        ang = math.degrees(math.atan2(yb - ya, xb - xa))
        out.append(P("B", (xa + xb) / 2, (ya + yb) / 2, 0, ln, thick, w, 0, 0, ang, colour, mat, extra))
    return out


def pf_waterfall(drop: float) -> list:
    """FOREST-1 W2 critic 2.6: tiered falls through the aqueduct bay (origin = deck top at the bay's side face, local +X =
    outward, local Z along the aqueduct). A stone spout lip at the channel, three curved sheets (parabolic slab chains with
    paler streaks) stepping over two non-colliding rock ledges (visual only: the terrain is untouched) into the pool, foam
    at every landing. Water, foam and rock steps are all no-collide; the old vertical blue slab columns are gone."""
    nc = {"nc": 1, "a": 0.3}
    g = fall_geometry(drop)
    (y1, y2, y3), (x1, x2, x3), (f1, f2), (w1, w2, w3) = g["ys"], g["xs"], g["front"], g["w"]
    ncs = {"nc": 1}
    p = [P("B", 2.5, -0.4, 0, 5, 2.2, 16, 0, 0, 0, MASONRY_DARK, "Slate"),
         P("B", 4.2, -2.4, 0, 2.4, 1.6, 17.5, 0, 0, 0, MASONRY_B, "Slate", ncs)]
    # rock steps (visual only): two stepped masses of faceted blocks with wedge fronts and a mossy cap
    for (xa, xb, top, bot, w, col) in ((3.0, f1, y1, y2 - 1.0, w2 + 6, "#d4cdb6"), (5.0, f2, y2, y3 - 1.0, w3 + 8, "#c6bfa8")):
        d = xb - xa
        p.append(P("B", (xa + xb) / 2, (top + bot) / 2 - 1.0, 0, d, top - bot - 2.0, w, 0, 0, 0, col, "Slate", ncs))
        p.append(P("W", xb + 2.0, top - 4.0, -w * 0.18, w * 0.42, 8.0, 4.0, 0, 270, 0, MASONRY_B, "Slate", ncs))
        p.append(P("W", xb + 1.6, top - 3.0, w * 0.24, w * 0.34, 6.0, 3.2, 0, 270, 0, MASONRY_DARK, "Slate", ncs))
        p.append(P("B", (xa + xb) / 2 + 1.0, top - 0.5, 0, d - 2.0, 1.0, w - 3.0, 0, 0, 0, LEAF_C, "Grass", ncs))
    # falls: lip -> ledge 1 -> ledge 2 -> pool (curved sheets) with a paler, narrower streak sheet in front of each
    for (xs, ys, xe, ye, w) in ((4.6, -0.6, x1, y1 + 0.3, w1), (f1 - 0.3, y1 + 0.2, x2, y2 + 0.3, w2),
                                (f2 - 0.3, y2 + 0.2, x3, y3 + 0.4, w3)):
        p += curved_sheet(xs, ys, xe, ye, w, 5, 0.8, WATER, "Glass", nc)
        p += curved_sheet(xs + 0.9, ys - 1.0, xe + 0.9, ye, w * 0.5, 4, 0.5, "#d4f7ff", "Glass", {"nc": 1, "a": 0.4})
    # water running across each ledge top
    p.append(P("B", (x2 + f1) / 2, y1 + 0.4, 0, f1 - x1 + 2, 0.5, w1 * 0.8, 0, 0, 0, WATER, "Glass", nc))
    p.append(P("B", (x3 + f2) / 2, y2 + 0.4, 0, f2 - x2 + 2, 0.5, w2 * 0.8, 0, 0, 0, WATER, "Glass", nc))
    # foam where each sheet lands
    for (xl, yl, w) in ((x1, y1, w1), (x2, y2, w2)):
        for j in range(3):
            p.append(P("S", xl + 1.0, yl + 0.8, (j - 1) * w / 3.4, 5.6, 3.0, 5.6, 0, 0, 0, FOAM, "SmoothPlastic", ncs))
    for j in range(5):
        a = math.radians(j * 360 / 5)
        p.append(P("S", x3 + 3.0 + 8 * math.cos(a), y3 + 1.0, 11 * math.sin(a), 9, 3.6, 9, 0, 0, 0, FOAM, "SmoothPlastic", ncs))
    return p


def pf_tunnel_portal() -> list:
    """Masonry tunnel collar (origin = ribbon at the mouth, local -Z = outside). Opening clears the flight corridor:
    jambs at |x| >= 46, semicircular intrados radius 46 springing at +28; retaining wings hold back the hill face."""
    p = []
    r, spring = 46.0, 28.0
    for sx in (-1, 1):
        p.append(P("B", sx * 50.5, spring / 2 - 2, 0, 9, spring + 4, 12, 0, 0, 0, MASONRY, "Slate"))
        p.append(P("B", sx * 51, spring + 0.8, 0, 11, 1.6, 13, 0, 0, 0, MASONRY_B, "Slate"))
        p.append(P("B", sx * 72, 36, 1, 34, 80, 10, 0, 0, 0, MASONRY, "Slate"))
        p.append(P("B", sx * 72, 77.5, 1, 36, 3, 12, 0, 0, 0, MASONRY_B, "Slate"))
        p.append(P("B", sx * 58, 66, 0, 10, 26, 12, 0, 0, 0, MASONRY, "Slate"))
    p += voussoirs(0, spring, r, 13, 11, MASONRY_B, "Slate", thick=8.0)
    p.append(P("B", 0, spring + r + 5, -0.6, 7, 12, 14, 0, 0, 0, MASONRY_DARK, "Slate"))  # keystone
    p.append(P("B", 0, 82, 1, 180, 4, 12, 0, 0, 0, MASONRY_B, "Slate"))                   # coping
    p.append(P("B", 0, 85.5, 1, 168, 3, 9, 0, 0, 0, LEAF_B, "Grass"))                      # turf lip
    return p


def pf_mill_cellar() -> list:
    """Base (cellar) of the TunnelMill inside Tunnel Hill: the hidden key's chamber. Origin = floor centre; the
    gallery runs straight through it along local Z (in from the tunnel mouth at -Z, back out at +Z). Masonry drum of
    16 slabs (inner radius 28) with only the three slabs on each side (+-X) standing, so each doorway is 47 wide
    (traps_forest1 F2: wider than the 44-wide gallery tube, never the limit on the line); no-collide lintels over the
    openings, timber ceiling, the mill's vertical drive shaft and crown gear tucked into the -X wall, lanterns and a
    low key plinth. Nothing collidable stands within 23 of the centre between floor +5 and +24."""
    p = []
    p += octa(32, 2.4, -2.4, MASONRY_B, "Slate")
    # 16 slabs; standing: k = 15, 0, 1 (+X side, phi -22.5..22.5) and 7, 8, 9 (-X side); the rest are doorways
    p += ring_slabs(28, 3.2, 31, 0, 16, MASONRY, "Slate", skip=(2, 3, 4, 5, 6, 10, 11, 12, 13, 14))
    nc = {"nc": 1}
    for k in (2, 3, 4, 5, 6, 10, 11, 12, 13, 14):  # lintels over the doorways (no-collide trim, doors 26 high)
        phi = 22.5 * k
        rm = 29.6
        x, z = rm * math.cos(math.radians(phi)), rm * math.sin(math.radians(phi))
        w = 2 * rm * math.tan(math.pi / 16) * 1.03
        p.append(P("B", x, 28.5, z, w, 5, 3.2, 0, 90 - phi, 0, MASONRY_B, "Slate", nc))
    p += octa(32.5, 3, 31, DARK_WOOD, "WoodPlanks")
    for yaw in (0, 60, 120):
        p.append(P("B", 0, 29.6, 0, 60, 1.8, 2.2, 0, yaw, 0, CAP_WOOD, "WoodPlanks"))
    # drive shaft and crown gear against the -X wall (inner face at x = -28), gear above the flight height
    p.append(P("B", -25.5, 15.5, 0, 3, 31, 3, 0, 45, 0, CAP_WOOD, "WoodPlanks"))
    p += octa(5.5, 1.6, 24, DARK_WOOD, "WoodPlanks", x=-25.5)
    for k in range(8):
        a = math.radians(22.5 + 45 * k)
        p.append(P("B", -25.5 + 5.6 * math.cos(a), 26.2, 5.6 * math.sin(a), 1.6, 2.8, 1.6, 0, -math.degrees(a), 0, GOLD, "Metal"))
    # grain sacks and a crate (craft detail) against the +X wall
    p.append(P("B", 24, 2.5, -6, 5, 5, 5, 0, 20, 0, "#b98a52", "WoodPlanks"))
    p.append(P("B", 24.5, 1.8, 3, 4.5, 3.6, 3, 0, -15, 0, STRAW, "Fabric"))
    p.append(P("B", 23.5, 1.8, 8, 4.5, 3.6, 3, 0, 30, 0, STRAW, "Fabric"))
    # key plinth (low) and lanterns
    p += octa(3.2, 4, 0, MASONRY_B, "Slate")
    p.append(P("B", 0, 4.4, 0, 4.6, 0.8, 4.6, 0, 45, 0, GOLD, "Metal"))
    for x, z in ((20, -20), (-20, 20), (20, 20)):
        p.append(P("B", x, 24, z, 1.6, 2.6, 1.6, 0, 45, 0, "#ffd590", "Neon", {"nc": 1, "l": [34, 1.4, "#ffc274", False]}))
    return p


def pf_arch_bridge() -> list:
    """Stone arch bridge under the deck at the river (origin = ribbon, local -Z = route forward). Spandrel faces sit
    under the deck edges (deck bottom is ribbon -6.3), so nothing reaches the flight corridor."""
    p = []
    top = -6.4
    r, spring = 17.0, -30.0
    for sx in (-1, 1):
        x = sx * 15.2
        # arch ring on each face (arch in the local YZ plane)
        n = 7
        rm = r + 2.8
        tl = 2 * rm * math.sin(math.radians(90 / n)) * 1.06
        for i in range(n):
            a = 180 * (i + 0.5) / n
            z = rm * math.cos(math.radians(a))
            y = spring + rm * math.sin(math.radians(a))
            p.append(P("B", x, y, z, 2.6, 5.6, tl, a - 90, 0, 0, MASONRY_B, "Slate"))
        p.append(P("B", x * 0.98, (top + spring + r + 5.6) / 2, 0, 2.4, top - (spring + r + 5.6) + 0.2, 2 * (r + 5.6) * 0.62, 0, 0, 0, MASONRY, "Slate"))
        for sz in (-1, 1):
            p.append(P("B", x * 0.98, (top + spring - 2) / 2 - 6, sz * (r + 13), 2.4, top - spring + 14, 16, 0, 0, 0, MASONRY, "Slate"))
    for i in range(6):  # barrel vault underside
        a = 180 * (i + 0.5) / 6
        z = (r + 0.8) * math.cos(math.radians(a))
        y = spring + (r + 0.8) * math.sin(math.radians(a))
        p.append(P("B", 0, y, z, 28, 1.6, 2 * (r + 0.8) * math.sin(math.radians(15)) * 1.1, a - 90, 0, 0, MASONRY_DARK, "Slate"))
    for sz in (-1, 1):  # abutments
        p.append(P("B", 0, spring - 6, sz * (r + 6), 32, 14, 12, 0, 0, 0, MASONRY_B, "Slate"))
    return p


def pf_barn() -> list:
    """Mill yard barn: cream plaster walls, timber frame, terracotta gable roof of two wedges, big door, dormer."""
    p = [P("B", 0, 1, 0, 46, 2, 30, 0, 0, 0, MASONRY_B, "Slate"),
         P("B", 0, 10, 0, 42, 16, 26, 0, 0, 0, PLASTER, "Plaster")]
    for x in (-21, -7, 7, 21):
        p.append(P("B", x, 10, -13.2, 1.6, 16, 1, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
        p.append(P("B", x, 10, 13.2, 1.6, 16, 1, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("B", 0, 17.4, -13.3, 42, 1.4, 1, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("B", 0, 17.4, 13.3, 42, 1.4, 1, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("W", 0, 24, -7.5, 47, 12, 16, 0, 0, 0, ROOF, "ClayRoofTiles"))
    p.append(P("W", 0, 24, 7.5, 47, 12, 16, 0, 180, 0, ROOF_B, "ClayRoofTiles"))
    p.append(P("B", 0, 30.4, 0, 48, 1.2, 2.2, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("B", 0, 8, -13.4, 12, 13, 0.8, 0, 0, 0, "#a5703f", "WoodPlanks"))
    p.append(P("B", 0, 8, -13.7, 1.2, 13, 0.6, 0, 0, 0, DARK_WOOD, "WoodPlanks"))
    p.append(P("B", 14, 30, 4, 3.5, 9, 3.5, 0, 0, 0, MASONRY, "Slate"))
    for x in (-14, 14):
        p.append(P("B", x, 11, -13.35, 4, 4.5, 0.5, 0, 0, 0, WINDOW, "SmoothPlastic"))
    return p


def pf_granary() -> list:
    """Granary on Granary Hill: stone base, cream body, terracotta pyramid cap."""
    p = [P("B", 0, 4, 0, 22, 8, 22, 0, 0, 0, MASONRY, "Slate")]
    p += octa(9.5, 18, 8, PLASTER, "Plaster")
    p += octa(11, 2, 26, DARK_WOOD, "WoodPlanks")
    for i, (w, y, h) in enumerate(((22, 30.5, 5), (15, 35, 4.5), (8, 39, 4))):
        for yaw in (0, 90, 180, 270):
            dx, dz = -math.sin(math.radians(yaw)) * w / 4, -math.cos(math.radians(yaw)) * w / 4
            p.append(P("W", dx, y, dz, w, h, w / 2, 0, yaw, 0, (ROOF, ROOF_B)[(i + yaw // 90) % 2], "ClayRoofTiles"))
    p.append(P("B", 0, 13, -9.7, 5, 9, 0.6, 0, 0, 0, "#a5703f", "WoodPlanks"))
    return p


def pf_hay() -> list:
    return [P("B", 0, 2.2, 0, 8, 4.4, 5, 0, 8, 0, STRAW, "Fabric"),
            P("B", 7.5, 2.2, 1, 8, 4.4, 5, 0, -6, 0, "#e3c262", "Fabric"),
            P("B", 3.6, 6.4, 0.5, 8, 4.0, 5, 0, 3, 0, "#efd57a", "Fabric")]


def pf_fence(length=24.0) -> list:
    p = []
    n = 4
    for i in range(n + 1):
        x = -length / 2 + length * i / n
        p.append(P("B", x, 2.4, 0, 1.0, 4.8, 1.0, 0, 0, 0, DARK_WOOD, "Wood"))
    p.append(P("B", 0, 3.6, 0, length, 0.7, 0.5, 0, 0, 0, SAIL_WOOD, "Wood"))
    p.append(P("B", 0, 1.8, 0, length, 0.7, 0.5, 0, 0, 0, SAIL_WOOD, "Wood"))
    return p


def canopy(a, h, y0, colour, x=0.0, z=0.0, tilt=0.0, turn=0.0):
    """Faceted canopy mass (L61, critic r1: "cube trees read as placeholder"): two blocks turned 45 degrees apart,
    each slightly tilted, so the silhouette is an irregular octagon from every side (2 parts)."""
    s_ = 2 * a
    return [P("B", x, y0 + h / 2, z, s_, h, s_, tilt, turn, -tilt * 0.6, colour, "Grass"),
            P("B", x, y0 + h / 2 + h * 0.06, z, s_ * 0.94, h * 0.88, s_ * 0.94, -tilt * 0.7, turn + 45, tilt * 0.5, colour, "Grass")]


def pf_tree(variant: int) -> list:
    """Raiser faceted oak (L61): trunk, a deep shade-side mass and a lighter sunlit crown offset up and to one side,
    each an octagonal pair of turned blocks (5 parts)."""
    rng = random.Random(SEED + 100 + variant)
    h = 9 + rng.random() * 4
    s = 17 + rng.random() * 6
    p = [P("B", 0, h / 2, 0, 2.8, h, 2.8, 0, rng.random() * 90, 0, TRUNK, "Wood")]
    p += canopy(s * 0.5, s * 0.62, h - 1, LEAF_C if variant % 2 else LEAF_A, tilt=rng.uniform(-8, 8), turn=rng.uniform(0, 45))
    p += canopy(s * 0.33, s * 0.48, h + s * 0.42, LEAF_SUN if variant % 2 == 0 else LEAF_B, x=s * 0.1, z=-s * 0.06,
                tilt=rng.uniform(-12, 12), turn=rng.uniform(0, 45))
    return p


def pf_autumn_tree(variant: int) -> list:
    """Storybook accent oak in golden or russet leaf (a few per grove): same build as pf_tree."""
    rng = random.Random(SEED + 150 + variant)
    h = 8 + rng.random() * 3
    s = 15 + rng.random() * 5
    a, b = (AUTUMN_A, "#e8b860") if variant == 0 else (AUTUMN_B, AUTUMN_A)
    return ([P("B", 0, h / 2, 0, 2.6, h, 2.6, 0, rng.random() * 90, 0, TRUNK, "Wood")]
            + canopy(s * 0.5, s * 0.62, h - 1, a, tilt=rng.uniform(-8, 8), turn=rng.uniform(0, 45))
            + canopy(s * 0.32, s * 0.46, h + s * 0.42, b, x=s * 0.1, tilt=rng.uniform(-12, 12), turn=rng.uniform(0, 45)))


def pf_poplar(variant: int) -> list:
    """Lombardy poplar (L61): the tall slim column that lines country roads and field edges, readable at speed.
    Short trunk and two stacked faceted (octagonal) tapering masses (5 parts, ~30-36 studs)."""
    rng = random.Random(SEED + 170 + variant)
    k = 1.0 + 0.1 * variant
    return ([P("B", 0, 2.5, 0, 1.8, 5, 1.8, 0, 0, 0, TRUNK, "Wood")]
            + canopy(3.4, 17 * k, 4.0, POPLAR_A, tilt=rng.uniform(-3, 3), turn=rng.uniform(0, 45))
            + canopy(2.3, 12 * k, 4.0 + 14 * k, POPLAR_B, tilt=rng.uniform(-4, 4), turn=rng.uniform(0, 45)))


def pf_hedge(variant: int) -> list:
    """Hedgerow run along a field edge (L61, ~30 studs along local X): three staggered rounded masses (3 parts)."""
    rng = random.Random(SEED + 190 + variant)
    p = []
    for i in range(3):
        x = (i - 1) * 10 + rng.uniform(-1.5, 1.5)
        w, hh = 12 + rng.random() * 3, 5.5 + rng.random() * 2.5
        p.append(P("B", x, hh / 2, rng.uniform(-0.8, 0.8), w, hh, 6.5 + rng.random(), rng.uniform(-4, 4), rng.uniform(-10, 10), rng.uniform(-4, 4),
                   (LEAF_C, LEAF_A, LEAF_B)[(i + variant) % 3], "Grass"))
    return p


def pf_bush(variant: int) -> list:
    rng = random.Random(SEED + 200 + variant)
    s = 6 + rng.random() * 3
    return [P("B", 0, s * 0.3, 0, s * 1.4, s * 0.8, s, rng.uniform(-10, 10), rng.uniform(0, 90), rng.uniform(-10, 10), LEAF_C, "Grass"),
            P("B", s * 0.4, s * 0.5, s * 0.2, s * 0.8, s * 0.7, s * 0.8, rng.uniform(-15, 15), rng.uniform(0, 90), rng.uniform(-15, 15), LEAF_B, "Grass")]


def pf_boulder(variant: int) -> list:
    rng = random.Random(SEED + 300 + variant)
    s = 7 + rng.random() * 5
    return [P("B", 0, s * 0.3, 0, s * 1.3, s * 0.9, s, rng.uniform(-12, 12), rng.uniform(0, 90), rng.uniform(-12, 12), MASONRY, "Slate"),
            P("B", s * 0.35, s * 0.55, -s * 0.15, s * 0.7, s * 0.6, s * 0.7, rng.uniform(-20, 20), rng.uniform(0, 90), rng.uniform(-20, 20), MASONRY_B, "Slate")]


def pf_lantern() -> list:
    """Wall lantern for the tunnel (no-collide, warm PointLight)."""
    return [P("B", 0, 0, 0, 1.2, 6, 1.2, 0, 0, 0, DARK_WOOD, "Wood", {"nc": 1}),
            P("B", 0, -3.6, 0, 2.6, 3.2, 2.6, 0, 45, 0, "#ffd08a", "Neon", {"nc": 1, "l": [40, 1.1, "#ffbe6e", False]})]


# ------------------------------------------------------------------------------------------------ terrain
CELL = 8
# L61 grade: sea-grass greens, not neon (critic r0). These are also the plan's materials.terrainColors (the tint the
# neutral detail maps multiply; low-graphics clients show the tint alone). Upper meadows are a lighter gold-green,
# the valley floors and hollows a deeper blue-green (Mud carries the second meadow variant), so the big hills read
# as value layers instead of one flat green.
PALETTE = [
    {"key": "grass", "material": "Grass", "color": "#90ad66"},
    {"key": "crops", "material": "LeafyGrass", "color": "#d6aa52"},
    {"key": "dirt", "material": "Ground", "color": "#a07250"},
    {"key": "path", "material": "Cobblestone", "color": "#afa17b"},
    {"key": "rock", "material": "Limestone", "color": "#8f9178"},
    {"key": "meadow", "material": "Mud", "color": "#68935e"},
]
M_GRASS, M_CROPS, M_DIRT, M_PATH, M_ROCK, M_MEADOW = 1, 2, 3, 4, 5, 6


def smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def dome(d, r):
    """1 at the centre, 0 at radius r, cosine profile."""
    return 0.5 * (1 + np.cos(np.pi * np.clip(d / r, 0, 1)))


class Layout:
    """Everything placed relative to the route: stations of the features, built once from the solved route."""

    def __init__(self, tr: Track) -> None:
        self.tr = tr
        L = tr.length
        st_of = lambda x, z: self.station_near((x, z))  # noqa: E731
        self.s_bridge = st_of(0, -290)
        self.s_liftoff = st_of(3, -420)
        self.s_touchdown = st_of(1315, -310)
        self.s_mouth = st_of(1310, -170)
        self.s_exit = st_of(1295, 95)
        self.s_gap = st_of(1165, 345)
        self.s_arch = self.station_cross_z(300.0)
        self.L = L

    def station_near(self, xz) -> float:
        wx, wz = world(*xz)
        d = np.hypot(self.tr.pos[:, 0] - wx, self.tr.pos[:, 2] - wz)
        return float(self.tr.st[int(np.argmin(d))])

    def station_cross_z(self, z_local: float) -> float:
        """Station where the final straight crosses local z (searching the last 900 studs)."""
        wz = z_local + ORIGIN[2]
        best = None
        for s in np.arange(self.tr.length - 900, self.tr.length, 0.25):
            p = self.tr.frame(float(s)).pos
            if best is None or abs(p[2] - wz) < best[1]:
                best = (float(s), abs(p[2] - wz))
        return round(best[0], 2)


def build_terrain(tr: Track, lay: Layout, aq_lines, river_pts, path_pts, yard, fields, hills_extra):
    """30MAPS height grid (row-major, cell 8). Returns (terrain dict, height sampler)."""
    pad = 380
    xs_l = tr.pos[:, 0] - ORIGIN[0]
    zs_l = tr.pos[:, 2] - ORIGIN[2]
    xmin, xmax = min(xs_l.min(), -300) - pad, xs_l.max() + pad
    zmin, zmax = zs_l.min() - pad, zs_l.max() + pad
    xmin, zmin = math.floor(xmin / CELL) * CELL, math.floor(zmin / CELL) * CELL
    nx = int(math.ceil((xmax - xmin) / CELL)) + 1
    nz = int(math.ceil((zmax - zmin) / CELL)) + 1
    xl = xmin + np.arange(nx) * CELL
    zl = zmin + np.arange(nz) * CELL
    X, Z = np.meshgrid(xl, zl)  # [iz, ix] -> row-major iz*nx + ix

    # natural ground: gentle rolling meadow around the road level
    h = (ROAD_Y + 1.0
         + 4.0 * np.sin(X / 170 + 0.7) * np.cos(Z / 210 - 0.3)
         + 3.0 * np.sin((X + Z) / 260 + 1.9)
         + 2.5 * np.cos((X - 2 * Z) / 330))
    # hills (local x, z, radius, height above the meadow)
    hills = [
        # west ridge behind the aqueduct (guide: green hills and cliffs behind it)
        (-520, -760, 300, 120), (-560, -330, 300, 110), (-520, 80, 280, 100), (-560, 520, 300, 125),
        # north hills (windmills on top, end of the start valley)
        (-150, -1240, 300, 135), (260, -1290, 320, 150), (650, -1300, 300, 140), (1000, -1260, 300, 150),
        (1320, -1120, 260, 130),
        # east
        (1650, -760, 300, 160), (1680, -240, 280, 140), (1660, 260, 280, 150), (1520, 680, 300, 140),
        # Windy Gap shoulders
        (1010, 210, 150, 62), (1330, 470, 170, 78),
        # south downs
        (160, 980, 320, 115), (700, 990, 300, 105), (-260, 930, 280, 120), (1120, 900, 260, 110),
        # knolls inside the valleys (windmill seats)
        (-95, -78, 70, 6), (125, -175, 90, 12), (-70, -930, 170, 85), (520, -720, 110, 8), (760, 330, 120, 16), (420, 330, 120, 14),
        # rolling relief inside the loop (guide: every view is layered green hills)
        (520, -230, 210, 55), (880, -200, 220, 72), (300, 120, 190, 42), (720, 180, 220, 58), (1100, -430, 150, 46),
        (220, -40, 160, 26), (1000, 40, 160, 40), (560, -980, 160, 30), (-120, 420, 140, 26), (60, 760, 160, 30),
    ] + hills_extra
    for cx, cz, r, ht in hills:
        h = h + ht * dome(np.hypot(X - cx, Z - cz), r)
    # rim mountains: enclose the skyline (faceted read comes from the cliffs' rock and the haze). traps_forest1 F5: the
    # old rim (a smoothstep band, crest 127-231) sat below the high line (y 200-270) and its flat top ran out to the
    # grid edge, so a plane that drifted off the line flew (or slid) off the map with nothing to stop it. The rim is
    # now low grassy foothills (gentle, under 15 deg) in front of a rock CLIFF that rises RIM_CLIFF_SLOPE per stud
    # (~54 deg) to a crest at the grid edge. The crest keeps the old silhouette (same noise) and stands at least
    # RIM_MARGIN above any flight line a plane can drift out from (nose settling down at RIM_DRIFT_DEG). A plane that
    # meets the cliff meets it at more than the 35-degree crash angle (even climbing out of the foothills), so it
    # crashes and respawns at its checkpoint instead of sliding up and over into the void.
    db = np.minimum.reduce([X - xl[0], xl[-1] - X, Z - zl[0], zl[-1] - Z])
    h = np.maximum(h, ROAD_Y + RIM_FOOTHILL * smoothstep(1 - db / RIM_BAND))
    band = db < RIM_BAND
    wxb, wzb = X[band] + ORIGIN[0], Z[band] + ORIGIN[2]
    k = max(1, int(round(30.0 / (tr.length / len(tr.st)))))  # route samples every ~30 studs
    crest = ROAD_Y + 118 + 34 * np.sin(X[band] / 140 + 1.3) * np.cos(Z[band] / 170 + 0.4) + 18 * np.sin((X[band] - Z[band]) / 90)
    drift = math.tan(math.radians(RIM_DRIFT_DEG))
    for q in tr.pos[::k]:
        crest = np.maximum(crest, q[1] + FLIGHT_LINE + RIM_MARGIN - drift * np.hypot(wxb - q[0], wzb - q[2]))
    cliff = np.full(h.shape, -np.inf)
    cliff[band] = crest - RIM_CLIFF_SLOPE * db[band]
    h = np.maximum(h, cliff)

    # Tunnel Hill (applied after the flight-valley clamp below): a mesa aligned with the tunnel, steep mouth faces
    fm, fe = tr.frame(lay.s_mouth), tr.frame(lay.s_exit)
    axis = np.array(fe.pos) - np.array(fm.pos)
    tl = float(np.hypot(axis[0], axis[2]))
    ax = axis / np.linalg.norm(axis)
    rx = np.array([np.cross(ax, [0, 1, 0])[0], np.cross(ax, [0, 1, 0])[2]])  # horizontal right of the axis
    rx = rx / np.linalg.norm(rx)
    axh = np.array([ax[0], ax[2]]) / math.hypot(ax[0], ax[2])
    ux = (X + ORIGIN[0] - fm.pos[0]) * axh[0] + (Z + ORIGIN[2] - fm.pos[2]) * axh[1]
    vx = (X + ORIGIN[0] - fm.pos[0]) * rx[0] + (Z + ORIGIN[2] - fm.pos[2]) * rx[1]
    # rounded (superellipse) footprint with a noisy rim; the rim crosses the route at the portals (ux = 0, tl)
    half_u = tl / 2 + 22.0  # face runs from 22 studs in front of each portal to 12 behind it
    au = (ux - tl / 2) / half_u
    bv = vx / 225.0
    rr = (np.abs(au) ** 4 + np.abs(bv) ** 4) ** 0.25
    ang = np.arctan2(bv, au)
    rr = rr * (1 + 0.05 * np.sin(5 * ang + 0.8) + 0.03 * np.sin(11 * ang + 2.1) * smoothstep(np.abs(bv) * 4))
    w_edge = (34.0 / half_u) + (0.42 - 34.0 / half_u) * np.abs(np.sin(ang))  # steep at the portals, ~45 deg on the sides
    edge = smoothstep((1.0 - rr) / w_edge)
    crest = 96 + 14 * dome(np.abs(vx), 170) * dome(np.abs(ux - tl / 2), tl * 0.9)
    mesa = fm.pos[1] + crest * edge
    # Granary Hill (inside the final bend): plateau with cliffs
    gx, gz = GRANARY
    gd = np.hypot(X - gx, Z - gz)
    gmesa = ROAD_Y + 1 + 72 * smoothstep((168 - gd) / 42.0) + 6 * dome(gd, 120)
    h = np.maximum(h, gmesa)

    # aqueduct band: keep the arches open (ground under the bays <= 72)
    for (ax0, az0), (ax1, az1) in aq_lines:
        d = seg_dist(X, Z, ax0, az0, ax1, az1)
        cap = 70 + np.maximum(0, d - 26) * 0.9
        h = np.minimum(h, cap)

    # flight valley: nothing within 38 of any route sample above ribbon+1, then a 32-degree slope away from it
    wx, wz = X + ORIGIN[0], Z + ORIGIN[2]
    flat_x, flat_z = wx.ravel(), wz.ravel()
    hv = h.ravel().copy()
    tunnel = (tr.st >= lay.s_mouth - 2) & (tr.st <= lay.s_exit + 2)
    keep = ~tunnel
    px, pz, py = tr.pos[keep, 0], tr.pos[keep, 2], tr.pos[keep, 1]
    tan40 = math.tan(math.radians(32))  # valley wall slope beside the flight line
    nearest_deck_y = np.full(hv.shape, np.nan)
    nearest_deck_d = np.full(hv.shape, np.inf)
    deck = deck_mask(tr.st, lay) & ~tunnel
    dpx, dpz, dpy = tr.pos[deck, 0], tr.pos[deck, 2], tr.pos[deck, 1]
    for i0 in range(0, hv.size, 1500):
        sl = slice(i0, i0 + 1500)
        dx = flat_x[sl, None] - px[None, :]
        dz = flat_z[sl, None] - pz[None, :]
        d = np.sqrt(dx * dx + dz * dz)
        cap = py[None, :] + 1.0 + np.maximum(0.0, d - 38.0) * tan40
        hv[sl] = np.minimum(hv[sl], cap.min(axis=1))
        dx = flat_x[sl, None] - dpx[None, :]
        dz = flat_z[sl, None] - dpz[None, :]
        d = np.sqrt(dx * dx + dz * dz)
        j = np.argmin(d, axis=1)
        nearest_deck_d[sl] = d[np.arange(d.shape[0]), j]
        nearest_deck_y[sl] = dpy[j]
    h = hv.reshape(h.shape)
    nd = nearest_deck_d.reshape(h.shape)
    ny = nearest_deck_y.reshape(h.shape)
    tunnel_zone = (ux > -40) & (ux < tl + 40) & (np.abs(vx) < 240)

    mats = np.full(h.shape, M_GRASS, dtype=np.int64)

    # crop fields (patchwork of wheat; T4)
    for cx, cz, w, d, yaw in fields:
        c, s = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
        u = (X - cx) * c - (Z - cz) * s
        v = (X - cx) * s + (Z - cz) * c
        mats[(np.abs(u) <= w / 2) & (np.abs(v) <= d / 2)] = M_CROPS

    # cosmetic cobblestone path (the road below the high flight line) and the mill yard plaza
    pd = polyline_dist(X, Z, path_pts)
    yard_d = np.hypot(X - yard[0], Z - yard[1])
    yard_level = ROAD_Y + 2.5
    h = np.where(yard_d < yard[2], yard_level, np.where(yard_d < yard[2] + 50,
                 yard_level + (h - yard_level) * smoothstep((yard_d - yard[2]) / 50.0), h))
    # path: smooth the crown so it reads as a laid road
    mats[pd <= 9] = M_PATH
    mats[(pd > 9) & (pd <= 12)] = M_DIRT
    mats[yard_d < yard[2] - 6] = M_PATH

    # road deck: ground under the deck sits below it, the verge meets the curb tops (ribbon +2.6)
    under = nd <= DECK_WIDTH / 2 + 2
    verge = (nd > DECK_WIDTH / 2 + 2) & (nd <= DECK_WIDTH / 2 + 8)
    blend = (nd > DECK_WIDTH / 2 + 8) & (nd <= DECK_WIDTH / 2 + 80)
    h = np.where(under, ny - 2.0, h)
    h = np.where(verge, ny + 2.2, h)
    k = smoothstep((nd - (DECK_WIDTH / 2 + 8)) / 72.0)
    h = np.where(blend, (ny + 2.2) + (h - (ny + 2.2)) * k, h)
    mats[under] = M_DIRT
    mats[verge | blend] = np.where(mats[verge | blend] == M_PATH, M_GRASS, mats[verge | blend])
    # Tunnel Hill rises over everything here (the tube is carved by the shells at runtime)
    h = np.where(tunnel_zone, np.maximum(h, mesa), h)

    # river, pool and mill pond under one water level
    rd = polyline_dist(X, Z, river_pts)
    bed = WATER_LEVEL - 8.0
    rw = 17.0
    rv = np.where(rd < rw, bed, np.where(rd < rw + 18, bed + (np.maximum(h, WATER_LEVEL + 3) - bed) * smoothstep((rd - rw) / 18.0), h))
    h = np.minimum(h, rv)
    for (cx, cz, r) in (POOL, POND):
        dd = np.hypot(X - cx, Z - cz)
        pv = np.where(dd < r, bed - 2, np.where(dd < r + 24, bed - 2 + (np.maximum(h, WATER_LEVEL + 3) - bed + 2) * smoothstep((dd - r) / 24.0), h))
        h = np.minimum(h, pv)
    mats[h < WATER_LEVEL + 1.5] = M_DIRT
    # nothing else may dip under the water level (one global water plane)
    wet = (rd < rw + 18) | (np.hypot(X - POOL[0], Z - POOL[1]) < POOL[2] + 24) | (np.hypot(X - POND[0], Z - POND[1]) < POND[2] + 24)
    h = np.where(~wet, np.maximum(h, WATER_LEVEL + 2.0), h)

    # deep meadow (L61): valley floors and hollows in the darker blue-green variant, with a soft noisy edge so it
    # follows the land instead of drawing a contour line
    wob = 9.0 * np.sin(X / 61 + 0.4) * np.cos(Z / 47 - 1.1) + 6.0 * np.sin((X - Z) / 37 + 2.3)
    low = h < ROAD_Y + 20 + wob
    mats[low & (mats == M_GRASS)] = M_MEADOW
    # rock on steep faces and the highest peaks
    gy, gx_ = np.gradient(h, CELL)
    slope = np.degrees(np.arctan(np.hypot(gx_, gy)))
    # L61 (critic r1: the rim cliff read as one continuous graybox wall): on the rim the rock shows only in strata
    # ledges that follow the height (with a wobble), grassy bands between them, and the crest is grass; elsewhere
    # steep faces stay rock.
    strata = np.sin(h / 11.0 + 0.9 * np.sin(X / 90 + 0.3) + 0.7 * np.cos(Z / 70 - 1.2))
    rim = db < RIM_BAND
    steep = (slope > 40) & (mats != M_PATH)
    mats[steep & (~rim | (strata > -0.15))] = M_ROCK
    mats[steep & rim & (strata <= -0.15)] = M_GRASS
    mats[(h > ROAD_Y + 200) & ~rim] = M_ROCK

    h = np.round(h * 2) / 2
    terrain = {
        "nx": int(nx), "nz": int(nz), "cell": CELL,
        "x0": float(xl[0] + ORIGIN[0]), "z0": float(zl[0] + ORIGIN[2]),
        "floor": 36, "top": float(math.ceil(h.max() + 4)),
        "palette": PALETTE,
        "water": {"level": WATER_LEVEL, "color": "#5ccfe6", "transparency": 0.35},  # terrain-look overrides live in materials.water* (keeps terrain_hash)
        "heights": [float(v) if v != int(v) else int(v) for v in h.ravel()],
        "materials": [int(v) for v in mats.ravel()],
    }
    sampler = HeightSampler(terrain)
    return terrain, sampler, (X, Z, h, mats, slope)


class HeightSampler:
    """Bilinear ground height exactly like builder_template `height(x, z)` (world coordinates)."""

    def __init__(self, t: dict) -> None:
        self.nx, self.nz, self.cell = t["nx"], t["nz"], t["cell"]
        self.x0, self.z0 = t["x0"], t["z0"]
        self.H = np.array(t["heights"], float).reshape(self.nz, self.nx)

    def __call__(self, wx: float, wz: float) -> float:
        fx = (min(max(wx, self.x0), self.x0 + (self.nx - 1) * self.cell) - self.x0) / self.cell
        fz = (min(max(wz, self.z0), self.z0 + (self.nz - 1) * self.cell) - self.z0) / self.cell
        ix = max(min(int(math.floor(fx)), self.nx - 2), 0)
        iz = max(min(int(math.floor(fz)), self.nz - 2), 0)
        tx, tz = fx - ix, fz - iz
        a, b = self.H[iz, ix], self.H[iz, ix + 1]
        c, d = self.H[iz + 1, ix], self.H[iz + 1, ix + 1]
        u = a + (b - a) * tx
        v = c + (d - c) * tx
        return float(u + (v - u) * tz)


def seg_dist(X, Z, x0, z0, x1, z1):
    dx, dz = x1 - x0, z1 - z0
    L2 = dx * dx + dz * dz
    t = np.clip(((X - x0) * dx + (Z - z0) * dz) / L2, 0, 1)
    return np.hypot(X - (x0 + t * dx), Z - (z0 + t * dz))


def polyline_dist(X, Z, pts):
    d = np.full(X.shape, np.inf)
    for (x0, z0), (x1, z1) in zip(pts[:-1], pts[1:]):
        d = np.minimum(d, seg_dist(X, Z, x0, z0, x1, z1))
    return d


def deck_mask(st, lay: Layout):
    return ~((st >= lay.s_liftoff) & (st <= lay.s_touchdown))


# Fixed scenery anchors (local x, z)
GRANARY = (232.0, 418.0)
AQ_SLANT = 10.0   # degrees the aqueduct's long run leans toward the route (east of north)
FALLS_Z = -300.0  # local z of the middle waterfall bay
POOL = (0.0, 0.0, 0.0)  # set in main() from the aqueduct layout
POND = (820.0, -470.0, 82.0)
RIVER_DOWNSTREAM = [(-60, -296), (0, -290), (60, -300), (160, -340), (300, -400), (460, -445), (640, -470), (820, -470)]
RIVER: list = []  # set in main(): pool -> downstream
COSMETIC_PATH_MID = [(22, -540), (90, -640), (200, -705), (330, -735), (420, -720), (560, -700), (720, -660),
                     (900, -600), (1080, -520), (1250, -420)]  # ends are taken from the route (lift-off, touchdown)
MILL_YARD = (430.0, -705.0, 70.0)
FIELDS = [  # local cx, cz, width, depth, yaw
    (300, -600, 150, 90, 12), (560, -610, 140, 100, -8), (650, -790, 160, 90, 4), (250, -820, 120, 80, -10),
    (-110, -470, 120, 160, 0), (140, -480, 110, 120, 6), (560, 470, 220, 100, -6), (850, 650, 200, 110, 8),
    (300, 780, 200, 120, 4), (-120, 620, 140, 160, -4), (980, -380, 150, 120, 10), (120, 80, 120, 140, 0),
    (-110, 230, 110, 120, 0),
]



# ------------------------------------------------------------------------------------------------ set dressing (L61)
# skyrally.setDressing (MapAdapter step 7b): the uploaded FOREST props (src/shared/PropLibrary.luau) stand in clusters
# that frame the low turns and booster rings, line the start and final straights at a readable distance, sit at the
# foot of every windmill outside the battle arena, dress the cobble path and the crop fields under the high line, the
# river banks, the mill pond and Granary Hill, and break up the open meadows. Every placement is tested against the
# compile gate's corridor boxes with its whole AABB (yawed footprint from the ground up to SNAP_RISE + its height:
# the adapter's snap ray starts 60 above pos, so a snap onto anything up there is covered) plus PROP_MARGIN; props keep
# off tree canopies, mills, the aqueduct and buildings (so the snap lands on the ground), off the water, and nothing
# collidable stands in the battle arena.
SNAP_RISE = 62.0
PROP_MARGIN = 4.0
CORRIDOR = {"halfWidth": 34, "floor": 5, "ceiling": 44}


def prop_library(zone: str = "FOREST") -> dict:
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


class Corridor:
    """The compile gate's flight-corridor boxes (adapt.segment_box), for filtering placements before the gate runs."""

    def __init__(self, tr: "Track"):
        import adapt
        self._hit = adapt.aabbs_hit_obb
        self.boxes = []
        wps = tr.route.waypoints
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


def prop_aabb(size, pos, yaw: float, scale: float):
    """World AABB (centre, half) a placement may occupy: yawed footprint, from 2 below pos's ground (pos.y - 2) up to
    SNAP_RISE + the prop height (tools/map/tests/test_forest1.py test_set_dressing uses the same box)."""
    sx, sy, sz = (v * scale for v in size[:3])
    c, s_ = abs(math.cos(math.radians(yaw))), abs(math.sin(math.radians(yaw)))
    hx, hz = 0.5 * (sx * c + sz * s_), 0.5 * (sx * s_ + sz * c)
    g = pos[1] - 2.0
    top = g + SNAP_RISE + sy
    return np.array([pos[0], (g - 2.0 + top) / 2, pos[2]]), np.array([hx, (top - g + 2.0) / 2, hz])



def fx_texture(name: str) -> str:
    """rbxassetid of an owned particle texture (src/shared/VfxAssets.luau or the flip set in VfxFlipAssets.luau)."""
    import re
    m = re.search(name + r' = \{ id = "(rbxassetid://\d+)"', (ROOT / "src" / "shared" / "VfxAssets.luau").read_text())
    if not m:
        m = re.search(name + r' = "(rbxassetid://\d+)"', (ROOT / "src" / "shared" / "VfxFlipAssets.luau").read_text())
    assert m, name
    return m.group(1)


def adapt_rot(rx: float, ry: float, rz: float):
    import adapt
    return adapt.rot_yxz(rx, ry, rz)


def cf_at(x: float, y: float, z: float) -> list:
    return [r2(x), r2(y), r2(z), 1, 0, 0, 0, 1, 0, 0, 0, 1]


# ------------------------------------------------------------------------------------------------ sky
def write_sky() -> dict:
    """Sunshine midday sky (guide): cobalt zenith, cyan-white horizon haze, puffy faceted-soft cumulus in a band above
    the horizon and pale blue-green distant ridges. Colours are a function of the view direction's elevation, so the
    four identical side faces, the up face and the down face meet without seams; clouds and ridges are periodic in
    the side face's x so neighbouring side faces join."""
    from PIL import Image

    N = 512
    SKY_DIR.mkdir(parents=True, exist_ok=True)
    # L61 golden afternoon: a warm cream-peach band at the horizon (it meets the Atmosphere's cream haze without a
    # seam), clear mid blue above it and a deeper cobalt zenith
    stops = [(-90, (88, 128, 96)), (-12, (120, 158, 124)), (-2, (214, 214, 196)), (0, (246, 228, 198)),
             (4, (236, 226, 206)), (12, (176, 206, 230)), (28, (110, 166, 226)), (55, (66, 124, 212)), (90, (46, 98, 196))]
    el = np.array([s[0] for s in stops], float)
    cols = np.array([s[1] for s in stops], float)

    def grad(e):
        return np.stack([np.interp(e, el, cols[:, k]) for k in range(3)], axis=-1)

    u = (np.arange(N) + 0.5) / N * 2 - 1
    U, V = np.meshgrid(u, -u)  # V: +1 at the top row
    # side face: direction (U, V, 1) -> elevation
    e_side = np.degrees(np.arctan2(V, np.sqrt(U * U + 1)))
    side = grad(e_side)
    azi = np.degrees(np.arctan2(U, 1.0))  # -45..45 across the face; periodic over 90 for the four faces
    px = (azi + 45) / 90.0  # 0..1 across the face
    rng = random.Random(SEED + 7)
    # distant ridges: two layers of piecewise-linear (faceted) silhouettes, periodic in px
    for layer, (base, amp, col, n) in enumerate(((0.8, 4.2, (168, 178, 204), 7), (0.0, 2.8, (132, 160, 150), 11))):
        knots = [rng.uniform(0.2, 1.0) for _ in range(n)]
        knots.append(knots[0])
        xs = np.linspace(0, 1, n + 1)
        ridge = base + amp * np.interp(px, xs, knots)
        mask = (e_side <= ridge) & (e_side > -3)
        shade = 0.9 + 0.1 * np.clip((e_side - (ridge - 2.5)) / 2.5, 0, 1)  # lighter crest, hazier foot
        tint = np.array(col, float)[None, None, :] * shade[..., None]
        fade = np.clip((e_side + 3) / 3, 0, 1)[..., None]
        side = np.where(mask[..., None], side * (1 - 0.85 * fade) + tint * 0.85 * fade, side)
    # cumulus: clusters of soft round puffs with flat bottoms, light tops and blue-grey bellies, wrapped in px
    cloud = np.zeros((N, N))
    belly = np.zeros((N, N))
    ys = np.degrees(np.arctan2(V, np.sqrt(U * U + 1)))
    for _ in range(6):
        cx = rng.random()
        ce = rng.uniform(10, 24)
        w = rng.uniform(0.07, 0.13)
        for _b in range(rng.randint(6, 9)):
            t = rng.uniform(-1, 1)
            bx = cx + t * w
            br = rng.uniform(0.035, 0.065) * (1.25 - 0.5 * abs(t))  # bigger puffs in the middle of a cloud
            be = ce + br * 40 * rng.uniform(0.2, 0.7)
            bh = br * 90 * rng.uniform(0.6, 0.8)
            for wrap in (-1, 0, 1):
                dx = (px - bx - wrap) / br
                de = (ys - be) / bh
                d = np.sqrt(dx * dx + de * de)
                blob = smoothstep((1.0 - d) / 0.28)
                blob = blob * smoothstep((ys - (ce - 1.0)) / 0.8)  # flat bottom, slightly soft
                cloud = np.maximum(cloud, blob)
                belly = np.maximum(belly, blob * np.clip(1 - (ys - (ce - 1.0)) / 5.0, 0, 1))
    cloud = np.clip(cloud, 0, 1)
    # sun-warmed tops, soft lavender-grey bellies (the low sun lights the clouds from the side)
    cloud_col = np.array([255, 246, 228], float) * (1 - belly[..., None] * 0.35) + np.array([196, 190, 220], float) * belly[..., None] * 0.35
    side = side * (1 - cloud[..., None] * 0.96) + cloud_col * cloud[..., None] * 0.96
    # up face: direction (U, 1, V) -> elevation
    e_up = np.degrees(np.arctan2(1.0, np.sqrt(U * U + V * V)))
    up = grad(e_up)
    # down face: direction (U, -1, V)
    e_dn = -np.degrees(np.arctan2(1.0, np.sqrt(U * U + V * V)))
    down = grad(e_dn)
    # gentle painterly grain (deterministic)
    g = np.random.default_rng(SEED).normal(0, 1.2, (N, N, 3))
    out = {}
    for name, img in (("up", up), ("side", side), ("down", down)):
        arr = np.clip(img + g, 0, 255).astype(np.uint8)
        path = SKY_DIR / f"{name}.png"
        Image.fromarray(arr, "RGB").save(path, optimize=True)
        out[name] = hashlib.sha256(path.read_bytes()).hexdigest()[:12]
    return out


# ------------------------------------------------------------------------------------------------ variants
VARIANTS = {
    # L61: both meadow variants use the soft procedural T7 (tools/vfx/make_forest_meadow.py); T1's framed, banded tile
    # read as a grid of neon scales. Different tile sizes on the two keep them from repeating in step.
    "SR_FOREST_Meadow": {"base": "Grass", "tex": "T7_MEADOW_SOFT", "studsPerTile": 56},
    "SR_FOREST_MeadowDeep": {"base": "Mud", "tex": "T7_MEADOW_SOFT", "studsPerTile": 68},
    "SR_FOREST_Dirt": {"base": "Ground", "tex": "T2_DIRT_PATH", "studsPerTile": 26},
    "SR_FOREST_MossyStone": {"base": "Limestone", "tex": "T3_MOSSY_STONE", "studsPerTile": 84},  # L61: 34 tiled the rim
    "SR_FOREST_Crops": {"base": "LeafyGrass", "tex": "T4_FIELD_CROPS", "studsPerTile": 36},
    "SR_FOREST_Cobble": {"base": "Cobblestone", "tex": "T5_COBBLE_ROAD", "studsPerTile": 9},
    "SR_FOREST_MillWood": {"base": "WoodPlanks", "tex": "T6_MILL_WOOD", "studsPerTile": 10},
    "SR_FOREST_Masonry": {"base": "Slate", "tex": "T3_MOSSY_STONE", "studsPerTile": 14},
}


def write_variants() -> None:
    VARIANTS_OUT.write_text(json.dumps(VARIANTS, indent=1) + "\n")


# ------------------------------------------------------------------------------------------------ main
# Visibility v1 (owner report 2026-10-20): nothing stood past the heightfield rim (241-278 high, 447-680 studs from the
# route), so wherever the client stopped drawing the far terrain the void showed under the horizon. Two rows of low
# ridge silhouettes (back-to-back wedges, tools/map/backdrop.py) ring the heightfield 40 and 420 studs past its edge,
# tops 256-340 (the route's high point is 240), the far row hazier toward the Atmosphere colour. Non-colliding,
# beyond the plane leash (PlaneConfig.LEASH_RESPAWN); purely visual.
BACKDROP = {"rings": [{"name": "HorizonRidge", "baseY": 20, "rows": [
    {"gap": 40, "depth": 280, "length": 520, "heights": [236, 282, 252, 310, 244, 300, 262, 318, 248, 292],
     "mat": "Grass", "color": "#6f9f78"},
    {"gap": 420, "depth": 340, "length": 640, "heights": [300, 318, 286, 312, 306, 296, 320, 290],
     "mat": "SmoothPlastic", "color": "#7fa8a4"},
]}]}


# ------------------------------------------------------------------------------------------------ sail-gap timing ring
# FOREST-1 launch upgrade (docs/design/TRACK_VARIETY.md 5a). A dedicated mill, GateMill, stands beside the south river
# meadow straight with its sail disc square to the flight line; BoosterRing_SailGate hangs in the disc at a fixed angle
# and is lit only while the gap between two sails lines up with it (src/shared/SailGateRules.luau; the sails turn on the
# server clock, client/WorldAnim). The sails are the no-collide prefab; the tower stands outside the flight corridor.
GATE_STATION = 4240.0   # ring station (south river meadows, heading west; before the Alt1 bend)
GATE_LATERAL = -30.0    # ring lateral on the route frame (tower side is the same side, further out)
GATE_HEIGHT = 34.0      # ring height above the waypoint (the disc is centred ~23 above this)
GATE_SCALE = 1.0
GATE_RING_LOCAL = (27.0, -23.0)  # ring centre relative to the hub in the sail plane (x, y), mill units
GATE_RPM = 4.0          # one gap passes the ring every 3.75 s, lit for about 1.2 s
GATE_PHASE = 0.0
GATE_NAME = "GateMill"


def gate_layout(tr: "Track") -> dict:
    """Ring pose from (station, lateral, height) and the mill pose that puts the ring inside its sail disc: the disc
    is square to the horizontal route tangent, the tower stands behind the hub (in the direction of travel) and the hub
    sits on the far side of the ring from the route centre line. Returns the tower xz, the point it faces, the hub
    height, the ring angle in the sails' own XY plane (degrees, counter-clockwise from local +X) and the ring pose."""
    f = tr.frame(GATE_STATION)
    t = np.array(f.tangent, float)
    th = np.array([t[0], 0.0, t[2]])
    th /= np.linalg.norm(th)
    psi = math.atan2(th[0], th[2])  # prefab yaw that turns its front (-Z) back along the route
    c, s_ = math.cos(psi), math.sin(psi)
    ex = np.array([c, 0.0, -s_])    # the prefab's local +X in world
    right = np.array(f.right, float)
    dx_local, dy_local = GATE_RING_LOCAL
    sgn = 1.0 if float(ex @ right) * GATE_LATERAL < 0 else -1.0  # hub further from the route centre than the ring
    dx_local *= sgn
    ring = np.array(tr.at(GATE_STATION, GATE_LATERAL, GATE_HEIGHT), float)
    hub = ring - GATE_SCALE * (dx_local * ex + np.array([0.0, dy_local, 0.0]))
    tower = hub + 15.6 * GATE_SCALE * th
    return {"ring": ring, "hub": hub, "tower": tower, "tangent_h": th,
            "face_to": (float(tower[0] - th[0] * 100.0), float(tower[2] - th[2] * 100.0)),
            "base_y": float(hub[1] - SAIL_HUB[1] * GATE_SCALE),
            "ring_deg": round(math.degrees(math.atan2(dy_local, dx_local)) % 360.0, 3)}


def main() -> None:
    tr = Track()
    lay = Layout(tr)
    L = tr.length
    assert abs(L - TARGET_LENGTH) < 1, L

    prefabs: dict[str, dict] = {}
    groups: list[str] = []
    instances: list[dict] = []
    model_attrs: list[dict] = []

    def gidx(path: str) -> int:
        if path not in groups:
            groups.append(path)
        return groups.index(path) + 1

    def add_pf(key: str, parts: list) -> None:
        if key not in prefabs:
            prefabs[key] = {"parts": parts}

    def place(pf: str, p, group: str, yaw: float = 0.0, s: float = 1.0, rot=None) -> None:
        inst = {"pf": pf, "p": [r2(p[0]), r2(p[1]), r2(p[2])], "g": gidx(group),
                "r": [r2(v) for v in rot] if rot is not None else r2(yaw), "s": r3(s)}
        instances.append(inst)

    # ---- aqueduct layout (local): N-S run along x = AQ_X, corner tower, E-W run crossing the final straight with the
    # great arch exactly perpendicular to the route there.
    fa = tr.frame(lay.s_arch)
    arch_c = np.array(fa.pos)
    t_h = np.array([fa.tangent[0], 0, fa.tangent[2]])
    t_h /= np.linalg.norm(t_h)
    run_dir = np.array(fa.right)  # aqueduct E-W run direction = route right at the crossing (perpendicular)
    run_yaw = math.degrees(math.atan2(-run_dir[2], run_dir[0]))  # yaw that maps local +X onto run_dir
    bay = 44.0
    great_hw = GREAT_R + 14
    n_west, n_east = 5, 2
    west_end = arch_c - run_dir * (great_hw + bay * n_west)
    east_end = arch_c + run_dir * (great_hw + bay * n_east)
    corner = west_end - run_dir * 12  # tower centre
    # long run: slanted 10 degrees toward the route so it recedes toward the centre of the first view (guide)
    ns_dir = np.array([math.sin(math.radians(AQ_SLANT)), 0.0, -math.cos(math.radians(AQ_SLANT))])
    n_ns = 25
    ns_start = corner + ns_dir * 12  # first bay begins at the tower's north face
    north_end = ns_start + ns_dir * bay * n_ns
    east = np.array([-ns_dir[2], 0.0, ns_dir[0]])  # valley side of the long run (outward normal, toward the road)
    # waterfalls: the three bays nearest local z = FALLS_Z; the pool sits at their foot and feeds the river
    centres = [ns_start + ns_dir * (bay * (i + 0.5)) for i in range(n_ns)]
    i_mid = min(range(n_ns), key=lambda i: abs((centres[i][2] - ORIGIN[2]) - FALLS_Z))
    fall_bays = [centres[i] for i in (i_mid - 1, i_mid, i_mid + 1)]
    pool_c = centres[i_mid] + east * 36
    global POOL, RIVER
    POOL = (float(pool_c[0] - ORIGIN[0]), float(pool_c[2] - ORIGIN[2]), 50.0)
    RIVER = [(POOL[0], POOL[1])] + RIVER_DOWNSTREAM
    aq_lines_local = [((corner[0] - ORIGIN[0], corner[2] - ORIGIN[2]), (north_end[0] - ORIGIN[0], north_end[2] - ORIGIN[2])),
                      ((corner[0] - ORIGIN[0], corner[2] - ORIGIN[2]), (east_end[0] - ORIGIN[0], east_end[2] - ORIGIN[2]))]

    # ---- terrain
    hills_extra: list = []
    pa, pb = tr.ground_point(lay.s_liftoff + 12, 0), tr.ground_point(lay.s_touchdown - 6, 0)
    path_pts = [(pa[0] - ORIGIN[0], pa[2] - ORIGIN[2])] + COSMETIC_PATH_MID + [(pb[0] - ORIGIN[0], pb[2] - ORIGIN[2])]
    terrain, ground, grid = build_terrain(tr, lay, aq_lines_local, RIVER, path_pts, MILL_YARD, FIELDS, hills_extra)

    # ---- windmills (body + separate sails prefab per mill, each in its own group)
    add_pf("Windmill", pf_windmill())
    add_pf("Windmill#far", pf_windmill(far=True))
    add_pf("WindmillSails", pf_sails())

    def mill(name: str, wx: float, wz: float, face_to, scale: float = 1.0, rpm: float = 5.0, base_y=None, far=False,
             sail_attrs=None) -> None:
        gy = ground(wx, wz) - 0.6 if base_y is None else base_y
        fx, fz = face_to[0] - wx, face_to[1] - wz
        yaw = math.degrees(math.atan2(-fx, -fz))  # front (-Z) toward face_to
        grp = f"Windmills/{name}"
        place("Windmill#far" if far else "Windmill", (wx, gy, wz), grp, yaw, scale)
        c, s_ = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
        hx, hy, hz = SAIL_HUB
        # Roblox yaw: local (x, z) -> world (x c + z s, -x s + z c)
        hub = (wx + (hx * c + hz * s_) * scale, gy + hy * scale, wz + (-hx * s_ + hz * c) * scale)
        place("WindmillSails", hub, grp, yaw, scale)
        model_attrs.append({"path": f"{grp}/WindmillSails",
                            "attrs": {"SpinAxis": "PivotLookVector", "SpinRPM": rpm, **(sail_attrs or {})}})

    def lw(x, z):
        return world(x, z)

    cam = tr.at(30, 0, 14)
    # hero pair at the start (guide foreground): left mill on a knoll beside the aqueduct pool, right mill on the east
    mill("StartMillWest", *lw(-92, -78), (cam[0] + 40, cam[2] - 60), 1.22, 4.5)
    mill("StartMillEast", *lw(118, -172), (cam[0] - 10, cam[2] - 30), 1.18, 5.5)
    # windmill field around the mill yard (battle overlay home rings stand in front of these four)
    yard_w = lw(MILL_YARD[0], MILL_YARD[1])
    field_mills = {"FieldMillNW": lw(300, -815), "FieldMillNE": lw(585, -835), "FieldMillSW": lw(275, -575),
                   "FieldMillSE": lw(600, -585)}
    for i, (nm, (x, z)) in enumerate(sorted(field_mills.items())):
        mill(nm, x, z, yard_w, 0.95, 4.0 + i * 0.6)
    # battle overlay home rings (LAUNCH_PROGRESSION 2b FOREST hoard). traps_forest1 F1: the natural line home runs
    # from the field (the yard) out toward your windmill, so each ring's fly-through axis is RADIAL (yard -> ring, the
    # way a kid arrives) and the ring stands RING_IN on the yard side of its mill and RING_SIDE to one side of the
    # yard-mill line. Flying on through it carries you past the mill (about 70 to its side, clear of tower and sail
    # disc) into the open edge band instead of into the tower 32 studs on (the old tangential ring: banked, then
    # crashed). The side is the one whose run-out to the arena boundary has the lower ground and keeps clear of every
    # other windmill. The spawn pad is on the ring's axis, 40 toward the yard. Laid out before the scatter, which keeps
    # each fly-through and run-out clear.
    RING_IN, RING_SIDE, RING_LIFT, BOUND_R = 46.0, 55.0, 24.0, 270.0
    yard3 = (yard_w[0], ground(*yard_w), yard_w[1])
    all_mills = [(wx, wz) for wx, wz in field_mills.values()]
    home_rings = []
    spawns = []
    ring_passes = []  # local (x, z) segment pairs: each home ring's fly-through (70 in) and run-out to the boundary
    for i, (nm, (x, z)) in enumerate(sorted(field_mills.items()), 1):
        d = np.array([yard3[0] - x, 0, yard3[2] - z])
        d /= np.linalg.norm(d)
        t = np.array([-d[2], 0.0, d[0]])  # horizontal, perpendicular to the mill-yard line
        best = None
        for side in (1.0, -1.0):
            hp = np.array([x, 0, z]) + d * RING_IN + t * side * RING_SIDE
            a = np.array([hp[0] - yard3[0], 0.0, hp[2] - yard3[2]])
            r_ring = float(np.linalg.norm(a))
            a /= r_ring
            run = [hp + a * k for k in np.arange(0.0, BOUND_R - r_ring + 1e-6, 6.0)]
            hi = max(ground(q[0], q[2]) for q in run)
            clear = min(float(seg_dist(np.array([mx]), np.array([mz]), hp[0] - a[0] * 70, hp[2] - a[2] * 70,
                                       run[-1][0], run[-1][2])[0]) for mx, mz in all_mills)
            key = (clear < 45.0, round(hi, 1), -side)
            if best is None or key < best[0]:
                best = (key, hp, a, r_ring)
        _, hp, a, r_ring = best
        hy = ground(hp[0], hp[2]) + RING_LIFT
        home_rings.append({"name": f"HomeRing_{i}", "mill": nm, "pos": [r2(hp[0]), r2(hy), r2(hp[2])],
                           "yaw": r2(math.degrees(math.atan2(-a[0], -a[2]))), "radius": 14})
        far = hp + a * (BOUND_R - r_ring)
        ring_passes.append(((hp[0] - a[0] * 70 - ORIGIN[0], hp[2] - a[2] * 70 - ORIGIN[2]),
                            (far[0] - ORIGIN[0], far[2] - ORIGIN[2])))
        # spawn on the axis 40 toward the yard (open air), facing the arena centre like every pad
        sp = hp - a * 40
        spawns.append([r2(sp[0]), r2(ground(sp[0], sp[2]) + 30), r2(sp[2])])
    # distant hill mills (guide: windmills on every skyline hill)
    hill_mills = [("NorthHillMill_1", -150, -1150, 0.9), ("NorthHillMill_2", 250, -1190, 1.0), ("NorthHillMill_3", 640, -1200, 0.95),
                  ("NorthHillMill_4", 1000, -1160, 1.0), ("WestRidgeMill_1", -520, -640, 0.9), ("WestRidgeMill_2", -540, -260, 0.85),
                  ("WestRidgeMill_3", -500, 160, 0.9), ("EastHillMill_1", 1620, -600, 0.95), ("SouthDownsMill_1", 700, 900, 0.9),
                  ("SouthDownsMill_2", 160, 900, 0.95), ("GapMill", 1000, 215, 0.85)]
    for i, (nm, x, z, sc) in enumerate(hill_mills):
        wx, wz = lw(x, z)
        mill(nm, wx, wz, (cam[0], cam[2]), sc, 3.5 + (i % 4) * 0.7, far=nm != "GapMill")


    # ---- critic v28 1.22: ten-plus more mills in three farm clusters (0.8-1.4x) and a hero mill at st 1050. Every spot is
    # 140+ horizontal studs off any route sample (the compile gate would flag a collidable mill in a corridor), outside
    # the battle ring, off the water, the aqueduct, the path and the existing mills, on gentle meadow ground.
    X_, Z_, H_, MATS_, SLOPE_ = grid
    mill_rng = random.Random(SEED + 122)
    mills_now = [(i_["p"][0], i_["p"][2]) for i_ in instances if i_["pf"].startswith("Windmill") and "Sails" not in i_["pf"]]

    def mill_spot_ok(wx: float, wz: float, gap: float) -> bool:
        lx, lz = wx - ORIGIN[0], wz - ORIGIN[2]
        if float(np.min(np.hypot(tr.pos[:, 0] - wx, tr.pos[:, 2] - wz))) < 140.0:
            return False
        if math.hypot(lx - MILL_YARD[0], lz - MILL_YARD[1]) < BOUND_R + 70:
            return False
        if math.hypot(lx - POND[0], lz - POND[1]) < POND[2] + 40 or math.hypot(lx - POOL[0], lz - POOL[1]) < POOL[2] + 40:
            return False
        if math.hypot(lx - GRANARY[0], lz - GRANARY[1]) < 190:
            return False
        if polyline_dist(np.array([lx]), np.array([lz]), RIVER)[0] < 50 or polyline_dist(np.array([lx]), np.array([lz]), path_pts)[0] < 40:
            return False
        for (ax0, az0), (ax1, az1) in aq_lines_local:
            if seg_dist(np.array([lx]), np.array([lz]), ax0, az0, ax1, az1)[0] < 60:
                return False
        for (ax0, az0), (ax1, az1) in ring_passes:
            if seg_dist(np.array([lx]), np.array([lz]), ax0, az0, ax1, az1)[0] < 60:
                return False
        if any(math.hypot(wx - mx, wz - mz) < gap for mx, mz in mills_now):
            return False
        ix = int(round((wx - terrain["x0"]) / CELL))
        iz = int(round((wz - terrain["z0"]) / CELL))
        if not (3 <= ix < terrain["nx"] - 3 and 3 <= iz < terrain["nz"] - 3):
            return False
        return bool(SLOPE_[iz, ix] <= 18 and MATS_[iz, ix] not in (M_PATH, M_DIRT) and ground(wx, wz) <= ROAD_Y + 150)

    new_mills = 0
    for ci, (ccx, ccz, want) in enumerate(((-30.0, -520.0, 5), (430.0, 640.0, 4), (960.0, -300.0, 4))):
        got, tries = 0, 0
        while got < want and tries < 400:
            tries += 1
            ang, rad = mill_rng.uniform(0, 2 * math.pi), 40 + 240 * math.sqrt(mill_rng.random())
            wx, wz = lw(ccx + rad * math.cos(ang), ccz + rad * math.sin(ang))
            if not mill_spot_ok(wx, wz, 70.0):
                continue
            sc = round(mill_rng.uniform(0.8, 1.4), 2)
            mill(f"FarmMill_{ci + 1}{got + 1}", wx, wz, (cam[0], cam[2]), sc, 3.0 + 0.6 * ((ci + got) % 4), far=sc < 1.0)
            mills_now.append((wx, wz))
            got += 1
            new_mills += 1
    # hero mill beside the line at st 1050 (the lap's first big view after the lift-off), either side, whichever clears
    h0 = tr.at(1050.0, 0.0, 0.0)
    hero = None
    for rad in range(150, 520, 30):
        for k_ in range(24):
            ang = 2 * math.pi * k_ / 24
            hx_, hz_ = float(h0[0]) + rad * math.cos(ang), float(h0[2]) + rad * math.sin(ang)
            if mill_spot_ok(hx_, hz_, 90.0):
                hero = (hx_, hz_)
                break
        if hero:
            break
    assert hero, "no hero mill spot near st 1050"
    mill("HeroMill_1050", hero[0], hero[1], (float(h0[0]), float(h0[2])), 1.6, 4.2)
    mills_now.append(hero)
    new_mills += 1
    assert new_mills >= 11, new_mills

    # critic v28 1.11: the far ridge (backdrop ring row 1, cool green) carries windmills on its crest; they stand where a
    # ridge part stands (the same hash the generator uses), sunk into the crest so the plinth never hangs in the air
    import backdrop as backdrop_lib
    ridge_crests: list = []
    backdrop_lib.ring_parts(BACKDROP["rings"][0], {"terrain": terrain}, lambda _p: True, ridge_crests)
    crest_mills = 0
    for c_ in ridge_crests:
        if c_["row"] != 0 or c_["k"] % 3 != 1:
            continue
        # Wave 1b C9 (critic v29: the crest mills never showed in V12). They sit 490-700 studs off the line, past the
        # Level01 dressing radius (DressingLodRules 450), and their ground ray finds no terrain (the ridge is a
        # non-queryable backdrop part), so client/DressingLod hid them as floating props at the capture and phone
        # levels. They stand on the backdrop ridge, which is always drawn: DressGround "part" keeps mill and sails drawn.
        nm = f"RidgeMill_{crest_mills + 1}"
        mill(nm, c_["x"], c_["z"], (cam[0], cam[2]), 2.1, 3.0 + 0.5 * (crest_mills % 4),
             base_y=c_["y"] - 16.0, far=True, sail_attrs={"DressGround": "part"})
        model_attrs.append({"path": f"Windmills/{nm}/Windmill", "attrs": {"DressGround": "part"}})  # built name drops "#far"
        crest_mills += 1
    assert crest_mills >= 6, crest_mills

    # ---- sail-gap timing ring (launch upgrade): the gate mill, its sails on the shared server clock
    gate = gate_layout(tr)
    mill(GATE_NAME, float(gate["tower"][0]), float(gate["tower"][2]), gate["face_to"], GATE_SCALE, GATE_RPM,
         base_y=gate["base_y"], sail_attrs={"SailClock": True, "SailPhase": GATE_PHASE})
    gate_sink = ground(float(gate["tower"][0]), float(gate["tower"][2])) - gate["base_y"]
    assert -4.0 <= gate_sink <= 10.0, f"gate mill base {gate_sink:.1f} off the ground"

    # ---- far hills (r3, critic r2: "the empty ocean horizon makes the map feel unfinished and small"): a ring of
    # faceted low-poly hip ridges 250-700 studs beyond the rim, four wedges each (ridge along the rim), no-collide; the
    # Atmosphere fades them into blue-green layers, so the vale is closed by hills, not by sea. FOREST-1 is 3000+ studs
    # from every other map, so they never photobomb another track.
    far_rng = random.Random(SEED + 91)
    gx0, gx1 = terrain["x0"], terrain["x0"] + (terrain["nx"] - 1) * CELL
    gz0, gz1 = terrain["z0"], terrain["z0"] + (terrain["nz"] - 1) * CELL
    gcx, gcz = (gx0 + gx1) / 2, (gz0 + gz1) / 2
    far_cols = ["#7b9c72", "#86a37a", "#7896a0", "#8aa69a"]
    perim = 2 * ((gx1 - gx0) + (gz1 - gz0))
    n_far = 22
    for k in range(n_far):
        t_ = (k + far_rng.uniform(-0.25, 0.25)) / n_far * perim
        # walk the grid perimeter, then push outward
        w_, d_ = gx1 - gx0, gz1 - gz0
        if t_ < w_:
            ex, ez, nx_, nz_ = gx0 + t_, gz0, 0.0, -1.0
        elif t_ < w_ + d_:
            ex, ez, nx_, nz_ = gx1, gz0 + (t_ - w_), 1.0, 0.0
        elif t_ < 2 * w_ + d_:
            ex, ez, nx_, nz_ = gx1 - (t_ - w_ - d_), gz1, 0.0, 1.0
        else:
            ex, ez, nx_, nz_ = gx0, gz1 - (t_ - 2 * w_ - d_), -1.0, 0.0
        out_ = far_rng.uniform(260, 700)
        hx, hz = ex + nx_ * out_, ez + nz_ * out_
        yaw = math.degrees(math.atan2(-nz_, nx_)) + 90 + far_rng.uniform(-20, 20)  # ridge along the rim
        width, height, depth = far_rng.uniform(520, 900), far_rng.uniform(230, 380), far_rng.uniform(380, 620)
        # the compiler scales uniformly: each hill's size is baked into its own prefab
        key = f"FarHill_{k + 1:02d}"
        inst = {"pf": key, "p": [r2(hx), 20.0, r2(hz)], "g": gidx("Skyline/FarHills"), "r": r2(yaw), "s": 1.0}
        # hip-roofed ridge: two long slopes plus a sloped wedge on each end (no vertical triangle ends to read as a
        # prism from the side)
        ridge, end_ = width * 0.6, width * 0.2
        c0, c1 = far_cols[k % 4], far_cols[(k + 1) % 4]
        nc_ = {"nc": 1}
        add_pf(key, [P("W", 0, height / 2, -depth / 4, ridge, height, depth / 2, 0, 0, 0, c0, "Grass", nc_),
                     P("W", 0, height / 2, depth / 4, ridge, height, depth / 2, 0, 180, 0, c1, "Grass", nc_),
                     P("W", -(ridge + end_) / 2, height / 2, 0, depth, height, end_, 0, 90, 0, c1, "Grass", nc_),
                     P("W", (ridge + end_) / 2, height / 2, 0, depth, height, end_, 0, 270, 0, c0, "Grass", nc_)])
        instances.append(inst)

    # ---- aqueduct instances
    add_pf("AqueductBay", pf_aqueduct_bay(bay))
    add_pf("AqueductBay#warm", pf_aqueduct_bay(bay, tone=1))
    bay_rng = random.Random(SEED + 61)

    def bay_pf() -> str:
        return "AqueductBay#warm" if bay_rng.random() < 0.4 else "AqueductBay"
    spring_rel = (arch_c[1] + GREAT_SPRING) - AQ_DECK
    add_pf("AqueductGreatArch", pf_aqueduct_great_arch(spring_rel))
    add_pf("AqueductTower", pf_aqueduct_tower())
    add_pf("AqueductSpringHouse", pf_spring_house())
    ns_yaw = math.degrees(math.atan2(-ns_dir[2], ns_dir[0]))
    for i in range(n_ns):
        c = ns_start + ns_dir * (bay * (i + 0.5))
        place(bay_pf(), (c[0], AQ_DECK, c[2]), "Aqueduct", ns_yaw)
    # the last N-S bay supplies only its south pier; close the north end with the head tower
    place("AqueductTower", (north_end[0] + ns_dir[0] * 12, AQ_DECK, north_end[2] + ns_dir[2] * 12), "Aqueduct", ns_yaw)
    place("AqueductTower", (corner[0], AQ_DECK, corner[2]), "Aqueduct", run_yaw)
    for i in range(n_west):
        c = west_end + run_dir * (bay * (i + 0.5))
        place(bay_pf(), (c[0], AQ_DECK, c[2]), "Aqueduct", run_yaw)
    place("AqueductGreatArch", (arch_c[0], AQ_DECK, arch_c[2]), "Aqueduct", run_yaw)
    for i in range(n_east):
        c = arch_c + run_dir * (great_hw + bay * (i + 0.5))
        place(bay_pf(), (c[0], AQ_DECK, c[2]), "Aqueduct", run_yaw)
    place("AqueductSpringHouse", (east_end[0], AQ_DECK, east_end[2]), "Aqueduct", run_yaw)

    # waterfalls: three bays of the long run beside the pool, falling toward the valley
    drop = AQ_DECK - (WATER_LEVEL + 0.5)
    add_pf("AqueductWaterfall", pf_waterfall(drop))
    fx_list: list[dict] = []
    shell_rocks: list[dict] = []
    for i, c in enumerate(fall_bays):
        o = c + east * 6.6
        place("AqueductWaterfall", (o[0], AQ_DECK, o[2]), "Aqueduct/Waterfalls", math.degrees(math.atan2(-east[2], east[0])))
        base = (o[0] + 13.6, WATER_LEVEL + 1, o[2])
        fx_list.append({"class": "ParticleEmitter", "name": f"WaterfallMist_{i + 1}", "group": "Aqueduct/Waterfalls",
                        "cf": [r2(base[0]), r2(base[1]), r2(base[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [18, 2, 18],
                        "props": {"Texture": "rbxasset://textures/particles/smoke_main.dds", "Rate": 14,
                                  "Lifetime": [1.4, 2.4], "Speed": [3, 7], "SpreadAngle": [35, 35],
                                  "Acceleration": [0, 4, 0], "Color": "#ffffff", "LightEmission": 0.15,
                                  "Size": [[0, 5, 1], [1, 14, 2]], "Transparency": [[0, 0.55, 0], [1, 1, 0]],
                                  "Drag": 1.2}})
        gq = fall_geometry(AQ_DECK - (WATER_LEVEL + 0.5))
        ex, ez = east[0], east[2]
        for t_, (ys_, ye_, xs_, xe_, w_) in enumerate(((-0.6, gq["ys"][0], 4.6, gq["xs"][0], gq["w"][0]),
                                                      (gq["ys"][0], gq["ys"][1], gq["front"][0], gq["xs"][1], gq["w"][1]),
                                                      (gq["ys"][1], gq["ys"][2], gq["front"][1], gq["xs"][2], gq["w"][2]))):
            mx_, my_ = (xs_ + xe_) / 2, AQ_DECK + (ys_ + ye_) / 2
            fx_list.append({"class": "ParticleEmitter", "name": f"WaterfallSheet_{i + 1}_{t_ + 1}", "group": "Aqueduct/Waterfalls",
                            "cf": cf_at(o[0] + ex * mx_, my_, o[2] + ez * mx_), "size": [r2(w_ * 0.6), r2((ys_ - ye_) * 0.5), r2(w_ * 0.6)],
                            "props": {"Texture": fx_texture("water_droplet"), "Rate": 9, "Lifetime": [0.9, 1.3], "Speed": [8, 14], "SpreadAngle": [4, 4],
                                      "Acceleration": [0, -30, 0], "Color": "#e8fbff", "LightEmission": 0.25,
                                      "EmissionDirection": "Bottom", "Orientation": "VelocityParallel",
                                      "Size": {"seq": [[0, 2.6, 0.4], [1, 1.6, 0.4]]},
                                      "Transparency": {"seq": [[0, 0.25, 0], [0.8, 0.45, 0], [1, 1, 0]]}}})
        for t_, (yl_, xl_) in enumerate(((gq["ys"][0], gq["xs"][0]), (gq["ys"][1], gq["xs"][1]))):
            fx_list.append({"class": "ParticleEmitter", "name": f"WaterfallFoam_{i + 1}_{t_ + 1}", "group": "Aqueduct/Waterfalls",
                            "cf": cf_at(o[0] + ex * (xl_ + 1.0), AQ_DECK + yl_ + 1.5, o[2] + ez * (xl_ + 1.0)), "size": [6, 1, 14],
                            "props": {"Texture": "rbxasset://textures/particles/smoke_main.dds", "Rate": 5, "Lifetime": [1.0, 1.8],
                                      "Speed": [2, 5], "SpreadAngle": [40, 40], "Acceleration": [0, 3, 0], "Color": "#ffffff",
                                      "LightEmission": 0.2, "Size": {"seq": [[0, 3, 1], [1, 7, 1.5]]},
                                      "Transparency": {"seq": [[0, 0.45, 0], [1, 1, 0]]}, "Drag": 1.0}})
        for j, (dz, rr) in enumerate(((-12, 9), (11, 8), (0, 7))):
            shell_rocks.append({"op": "FillBall", "center": [r2(base[0] + 14 + 4 * j), r2(WATER_LEVEL - 2 + rr * 0.3), r2(base[2] + dz)],
                                "r": rr, "mat": "Limestone"})

    # ---- river arch bridge under the deck
    add_pf("StoneArchBridge", pf_arch_bridge())
    fb = tr.frame(lay.s_bridge)
    place("StoneArchBridge", fb.pos, "RiverBridge", tr.yaw_facing(lay.s_bridge, +1))

    # ---- tunnel portals, lanterns, TunnelMill and its cellar (hidden key)
    add_pf("TunnelPortal", pf_tunnel_portal())
    fm = tr.frame(lay.s_mouth)
    fe = tr.frame(lay.s_exit)
    place("TunnelPortal", fm.pos, "TunnelHill", tr.yaw_facing(lay.s_mouth, -1))
    place("TunnelPortal", fe.pos, "TunnelHill", tr.yaw_facing(lay.s_exit, +1))
    # r3 (critic: "the tunnel entrance reads as a cut hole"): warm hanging lanterns on both jambs of each portal face
    for st_p, sgn in ((lay.s_mouth, -1), (lay.s_exit, 1)):
        f_ = tr.frame(st_p)
        for lat in (-58, 58):
            q = np.array(f_.pos) + np.array(f_.right) * lat + np.array(f_.tangent) * (sgn * 9)
            place("TunnelLantern", (q[0], q[1] + 40, q[2]), "TunnelHill/Lanterns", 0)
    add_pf("TunnelLantern", pf_lantern())
    s = lay.s_mouth + 40
    while s < lay.s_exit - 30:
        for lat in (-47, 47):
            q = tr.ground_point(s, lat)
            place("TunnelLantern", (q[0], q[1] + 36, q[2]), "TunnelHill/Lanterns", 0)
        s += 70
    # Key gallery (traps_forest1 F2): one long S through the hill instead of the old tight chicane (bend radii 15-40
    # in a 34-wide tube, flyable only with sharp bank). It leaves the tube's left wall just inside the north mouth,
    # eases out to CELLAR_LAT over GALLERY_RAMP, runs straight through the cellar and eases back in to rejoin just
    # inside the south portal; ball radius 22 (44 wide). A state search at the default turn radius (93, auto-throttle,
    # no sharp bank) with 3 studs of wall margin flies key-and-back from the line at the mouth and from the CP8
    # respawn (tools/map/tests/test_forest1.py test_key_gallery_flyable_default_controls).
    GALLERY_FROM = lay.s_mouth - 6
    GALLERY_TO = lay.s_mouth + 274
    GALLERY_RAMP = 120.0
    GALLERY_R = 22.0
    CELLAR_ST = lay.s_mouth + 134
    CELLAR_LAT = -82.0
    CELLAR_CARVE_R = 30.0
    add_pf("MillCellar", pf_mill_cellar())
    cq = tr.ground_point(CELLAR_ST, CELLAR_LAT)
    place("MillCellar", (cq[0], cq[1] + 1.0, cq[2]), "TunnelHill/TunnelMill", tr.yaw_facing(CELLAR_ST, -1))
    top_y = ground(cq[0], cq[2])
    mill("TunnelMill", cq[0], cq[2], (fm.pos[0] - fm.tangent[0] * 400, fm.pos[2] - fm.tangent[2] * 400), 1.1, 5.0, base_y=top_y - 0.6)

    # ---- mill yard (battle venue): barn, hay, fences
    add_pf("MillBarn", pf_barn())
    add_pf("HayBales", pf_hay())
    add_pf("FenceRun", pf_fence())
    bx, bz = lw(MILL_YARD[0] - 20, MILL_YARD[1] - 46)
    place("MillBarn", (bx, ground(bx, bz) - 0.5, bz), "MillYard", 8)
    for i, (x, z, yaw) in enumerate(((MILL_YARD[0] + 36, MILL_YARD[1] - 20, 20), (MILL_YARD[0] - 52, MILL_YARD[1] + 10, -35),
                                     (MILL_YARD[0] + 20, MILL_YARD[1] + 38, 70))):
        wx, wz = lw(x, z)
        place("HayBales", (wx, ground(wx, wz) - 0.3, wz), "MillYard", yaw)
    for k in range(14):
        a = 2 * math.pi * k / 14
        if k in (3, 4, 10, 11):
            continue  # gates where the path crosses the yard
        x, z = MILL_YARD[0] + (MILL_YARD[2] + 6) * math.cos(a), MILL_YARD[1] + (MILL_YARD[2] + 6) * math.sin(a)
        wx, wz = lw(x, z)
        place("FenceRun", (wx, ground(wx, wz) - 0.4, wz), "MillYard", -math.degrees(a) + 90)

    # ---- Granary Hill
    add_pf("Granary", pf_granary())
    gwx, gwz = lw(GRANARY[0] + 30, GRANARY[1] + 20)
    place("Granary", (gwx, ground(gwx, gwz) - 0.5, gwz), "GranaryHill", 25)
    gmx, gmz = lw(GRANARY[0] - 25, GRANARY[1] - 35)
    mill("GranaryMill", gmx, gmz, (cam[0], cam[2] + 600), 1.0, 4.2)

    # ---- trees, hedgerows, bushes, boulders (deterministic, kept off every flight line and structure).
    # L61 (critic r0: "sparse lollipop trees, huge empty green mounds"): GROVES of big two-tone oaks with a few golden
    # and russet accents on the hill shoulders and in the hollows (each with a vista gap between), POPLAR AVENUES that
    # line the start straight, the final straight and the cobble path under the high line (the tall dark columns read
    # the course edge and the speed), HEDGEROWS on the crop-field edges (patchwork farmland from the high line), and a
    # few bushes and boulder groups. Every spot passes clear_spot (75 studs off any low route sample, off the river,
    # path, aqueduct, ponds, mill yard, battle ring run-outs, Granary Hill and the mills).
    for v in range(4):
        add_pf(f"RoundTree_{v + 1}", pf_tree(v))
        add_pf(f"Bush_{v + 1}", pf_bush(v))
    for v in range(2):
        add_pf(f"AutumnTree_{v + 1}", pf_autumn_tree(v))
    for v in range(3):
        add_pf(f"Poplar_{v + 1}", pf_poplar(v))
        add_pf(f"Hedge_{v + 1}", pf_hedge(v))
        add_pf(f"Boulder_{v + 1}", pf_boulder(v))
    X, Z, H, MATS, SLOPE = grid
    rng = random.Random(SEED)
    placed: list[tuple[float, float]] = []
    mills_xy = [(i["p"][0] - ORIGIN[0], i["p"][2] - ORIGIN[2]) for i in instances if i["pf"].startswith("Windmill") and "Sails" not in i["pf"]]
    tree_xy: list[tuple[float, float, float]] = []  # local x, z, canopy radius (set dressing keeps props off canopies)

    def clear_spot(x, z, r) -> bool:
        wx, wz = lw(x, z)
        d = np.hypot(tr.pos[:, 0] - wx, tr.pos[:, 2] - wz)
        gy = ground(wx, wz)
        near = d < 75
        if np.any(near & (tr.pos[:, 1] - gy < 70)):
            return False
        if polyline_dist(np.array([x]), np.array([z]), RIVER)[0] < 40 or polyline_dist(np.array([x]), np.array([z]), path_pts)[0] < 22:
            return False
        for (ax0, az0), (ax1, az1) in aq_lines_local:
            if seg_dist(np.array([x]), np.array([z]), ax0, az0, ax1, az1)[0] < 30:
                return False
        if math.hypot(x - POND[0], z - POND[1]) < POND[2] + 25 or math.hypot(x - POOL[0], z - POOL[1]) < POOL[2] + 25:
            return False
        if math.hypot(x - MILL_YARD[0], z - MILL_YARD[1]) < MILL_YARD[2] + 30:
            return False
        for (ax0, az0), (ax1, az1) in ring_passes:  # battle home-ring fly-throughs stay open
            if seg_dist(np.array([x]), np.array([z]), ax0, az0, ax1, az1)[0] < 34:
                return False
        if math.hypot(x - GRANARY[0], z - GRANARY[1]) < 175:
            return False
        for mx, mz in mills_xy:
            if math.hypot(x - mx, z - mz) < 30:
                return False
        for px_, pz_ in placed:
            if math.hypot(x - px_, z - pz_) < r:
                return False
        ix = int(round((x - (terrain["x0"] - ORIGIN[0])) / CELL))
        iz = int(round((z - (terrain["z0"] - ORIGIN[2])) / CELL))
        if not (0 <= ix < terrain["nx"] and 0 <= iz < terrain["nz"]):
            return False
        if SLOPE[iz, ix] > 24 or MATS[iz, ix] in (M_PATH, M_DIRT) or gy > ROAD_Y + 170:
            return False
        return True

    xs_l = (terrain["x0"] - ORIGIN[0], terrain["x0"] - ORIGIN[0] + (terrain["nx"] - 1) * CELL)
    zs_l = (terrain["z0"] - ORIGIN[2], terrain["z0"] - ORIGIN[2] + (terrain["nz"] - 1) * CELL)
    counts = {"oak": 0, "autumn": 0, "poplar": 0, "hedge": 0, "bush": 0, "boulder": 0}

    def put(kind: str, pf: str, x: float, z: float, yaw: float, sc: float, spacing: float, grp: str, canopy: float) -> bool:
        if not clear_spot(x, z, spacing):
            return False
        wx, wz = lw(x, z)
        place(pf, (wx, ground(wx, wz) - 0.8, wz), grp, yaw, sc)
        placed.append((x, z))
        tree_xy.append((x, z, canopy * sc))
        counts[kind] += 1
        return True

    # groves
    groves = 0
    tries = 0
    while groves < 30 and tries < 4000:
        tries += 1
        cx = rng.uniform(xs_l[0] + 230, xs_l[1] - 230)
        cz = rng.uniform(zs_l[0] + 230, zs_l[1] - 230)
        if not clear_spot(cx, cz, 70):
            continue
        groves += 1
        n = rng.randint(4, 8)
        for _k in range(n * 3):
            if n <= 0:
                break
            x, z = cx + rng.gauss(0, 22), cz + rng.gauss(0, 18)
            autumn = rng.random() < 0.13
            v = rng.randrange(2 if autumn else 4)
            ok = put("autumn" if autumn else "oak", f"AutumnTree_{v + 1}" if autumn else f"RoundTree_{v + 1}", x, z,
                     rng.uniform(0, 360), round(rng.uniform(0.85, 1.3), 2), 13, "Scenery/Groves", 12)
            n -= 1 if ok else 0
        for _k in range(2):  # a bush or two at the grove edge
            a = rng.uniform(0, 2 * math.pi)
            put("bush", f"Bush_{rng.randrange(4) + 1}", cx + 34 * math.cos(a), cz + 30 * math.sin(a), rng.uniform(0, 360),
                round(rng.uniform(0.9, 1.3), 2), 10, "Scenery/Bushes", 6)
    # rim groves (L61, critic r1: the boundary read as one wall): oak and poplar stands along the foothills in front
    # of the rim cliffs break its base line into layered tree masses
    rim_groves = 0
    tries = 0
    while rim_groves < 26 and tries < 6000:
        tries += 1
        side = rng.randrange(4)
        inset = rng.uniform(150, 280)
        u = rng.uniform(0.08, 0.92)
        cx = (xs_l[0] + inset, xs_l[1] - inset, xs_l[0] + u * (xs_l[1] - xs_l[0]), xs_l[0] + u * (xs_l[1] - xs_l[0]))[side]
        cz = (zs_l[0] + u * (zs_l[1] - zs_l[0]), zs_l[0] + u * (zs_l[1] - zs_l[0]), zs_l[0] + inset, zs_l[1] - inset)[side]
        if not clear_spot(cx, cz, 60):
            continue
        rim_groves += 1
        for _k in range(rng.randint(3, 5)):
            x, z = cx + rng.gauss(0, 18), cz + rng.gauss(0, 18)
            if rng.random() < 0.35:
                v = rng.randrange(3)
                put("poplar", f"Poplar_{v + 1}", x, z, rng.uniform(0, 90), round(rng.uniform(0.95, 1.2), 2), 10, "Scenery/RimGroves", 5)
            else:
                v = rng.randrange(4)
                put("oak", f"RoundTree_{v + 1}", x, z, rng.uniform(0, 360), round(rng.uniform(0.95, 1.3), 2), 12, "Scenery/RimGroves", 12)
    # lone oaks in the open meadows (break up the big fields; a tree on a crest is a landmark at speed)
    lone = 0
    tries = 0
    while lone < 40 and tries < 6000:
        tries += 1
        x = rng.uniform(xs_l[0] + 200, xs_l[1] - 200)
        z = rng.uniform(zs_l[0] + 200, zs_l[1] - 200)
        v = rng.randrange(4)
        lone += put("oak", f"RoundTree_{v + 1}", x, z, rng.uniform(0, 360), round(rng.uniform(1.0, 1.3), 2), 40,
                    "Scenery/Trees", 12)

    # poplar avenues: start straight and final straight (both sides, outside the 75-stud clearance) and both sides of
    # the cobble path under the high line, with gaps
    def avenue(s0: float, s1: float, lateral: float, step: float, gap: float = 0.2) -> None:
        s_ = s0
        while s_ < s1:
            for side in (-1, 1):
                if rng.random() < gap:
                    continue
                q = tr.ground_point(s_ % L, side * (lateral + rng.uniform(-4, 4)))
                if rng.random() < 0.35:  # r3 (critic: "repeated green posts"): oaks break the poplar rhythm
                    v = rng.randrange(4)
                    put("oak", f"RoundTree_{v + 1}", q[0] - ORIGIN[0], q[2] - ORIGIN[2], rng.uniform(0, 360),
                        round(rng.uniform(0.9, 1.2), 2), 14, "Scenery/Poplars", 12)
                    continue
                v = rng.randrange(3)
                put("poplar", f"Poplar_{v + 1}", q[0] - ORIGIN[0], q[2] - ORIGIN[2], rng.uniform(0, 90),
                    round(rng.uniform(0.8, 1.2), 2), 12, "Scenery/Poplars", 5)
            s_ += step
    L = tr.length
    avenue(30, lay.s_bridge - 60, 92, 30)
    avenue(lay.s_arch + 60, L + 20, 92, 30)
    avenue(lay.s_exit + 120, lay.s_gap - 60, 96, 34, gap=0.35)
    for (x0, z0), (x1, z1) in zip(path_pts[:-1], path_pts[1:]):
        seg = math.hypot(x1 - x0, z1 - z0)
        ux, uz = (x1 - x0) / seg, (z1 - z0) / seg
        t = 10.0
        while t < seg:
            for side in (-1, 1):
                if rng.random() < 0.3:
                    continue
                x, z = x0 + ux * t - uz * side * 30, z0 + uz * t + ux * side * 30
                v = rng.randrange(3)
                put("poplar", f"Poplar_{v + 1}", x, z, rng.uniform(0, 90), round(rng.uniform(0.9, 1.15), 2), 12,
                    "Scenery/Poplars", 5)
            t += 32
    # river-bank willows/oaks (the river is the vale's spine)
    for (x0, z0), (x1, z1) in zip(RIVER[:-1], RIVER[1:]):
        seg = math.hypot(x1 - x0, z1 - z0)
        ux, uz = (x1 - x0) / seg, (z1 - z0) / seg
        t = 12.0
        while t < seg:
            side = 1 if rng.random() < 0.5 else -1
            x, z = x0 + ux * t - uz * side * 50, z0 + uz * t + ux * side * 50
            v = rng.randrange(4)
            put("oak", f"RoundTree_{v + 1}", x, z, rng.uniform(0, 360), round(rng.uniform(0.85, 1.15), 2), 22,
                "Scenery/RiverBank", 12)
            t += 40
    # hedgerows on two or three edges of each crop field (patchwork from the high line)
    for fi, (cx, cz, w, d, yaw) in enumerate(FIELDS):
        c, s_ = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
        edges = [(0, d / 2 + 5, w, yaw), (0, -d / 2 - 5, w, yaw), (w / 2 + 5, 0, d, yaw + 90), (-w / 2 - 5, 0, d, yaw + 90)]
        for ei, (u0, v0, length, eyaw) in enumerate(edges):
            if (ei + fi) % 4 == 3:
                continue  # one open edge per field
            along = (1.0, 0.0) if eyaw == yaw else (0.0, 1.0)
            k = -length / 2 + 15
            while k < length / 2 - 10:
                u, v = u0 + along[0] * k, v0 + along[1] * k
                x, z = cx + u * c + v * s_, cz - u * s_ + v * c
                put("hedge", f"Hedge_{rng.randrange(3) + 1}", x, z, eyaw + rng.uniform(-3, 3), round(rng.uniform(0.95, 1.1), 2),
                    16, "Scenery/Hedgerows", 7)
                k += 30 + rng.uniform(0, 8)
    # bushes and boulder groups
    for kind, goal, sp in (("bush", 70, 18), ("boulder", 30, 22)):
        tries = 0
        while counts[kind] < goal and tries < 8000:
            tries += 1
            x = rng.uniform(xs_l[0] + 200, xs_l[1] - 200)
            z = rng.uniform(zs_l[0] + 200, zs_l[1] - 200)
            n_ = 1 if kind == "bush" else rng.randint(2, 3)
            for j in range(n_):
                v = rng.randrange(4 if kind == "bush" else 3)
                pf = f"Bush_{v + 1}" if kind == "bush" else f"Boulder_{v + 1}"
                put(kind, pf, x + j * 9 * math.cos(j * 2.1), z + j * 9 * math.sin(j * 2.1), rng.uniform(0, 360),
                    round(rng.uniform(0.85, 1.35), 2), sp if j == 0 else 6,
                    "Scenery/Bushes" if kind == "bush" else "Scenery/Rocks", 7)

    # ---- shells (Terrain after the grid): tunnel tube and floor, key gallery and cellar, cascade rocks, Alt1 tube
    shell_ops: list[dict] = []
    shell_ops.append({"op": "CarveRouteTube", "fromStation": round(lay.s_mouth - 26, 1), "toStation": round(lay.s_exit + 26, 1),
                      "radiusMin": 46, "radiusMax": 52, "lift": 22, "upperLift": 22, "upperScale": 0.6,
                      "noiseFreq": 0.17, "seed": 13})
    shell_ops.append({"op": "RouteFloorFill", "fromStation": round(lay.s_mouth - 26, 1), "toStation": round(lay.s_exit + 26, 1),
                      "mat": "Ground", "depth": 15, "width": 112, "thickness": 32})
    # key gallery: leaves the tube's left wall just inside the north mouth, runs through the cellar, rejoins
    gallery = offset_path(tr, GALLERY_FROM, GALLERY_TO, CELLAR_LAT, 0.0, ramp=GALLERY_RAMP, step=8)
    for q in gallery:
        shell_ops.append({"op": "FillBall", "center": [r2(q[0]), r2(q[1] + 15), r2(q[2])], "r": GALLERY_R, "mat": "Air"})
    shell_ops.append({"op": "FillCylinder", "cf": [r2(cq[0]), r2(cq[1] + 16), r2(cq[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                      "h": 30, "r": CELLAR_CARVE_R, "mat": "Air"})
    shell_ops.extend(shell_rocks)

    # ---- Alt1: tunnel shortcut through Granary Hill on the inside of the final bend. Generated from the race line's
    # frames (offset_path), so both ends lie ON the race line. Style "ledge": a cobble floor slab (kit/Deck) that starts
    # under the road deck (its top is 0.7 below the pavers) and branches off; the tunnel itself is Terrain, an
    # organic tube carved by shells, so no wall ever stands in the main flight corridor.
    s_alt0 = lay.station_near((300, 636))
    s_alt1 = lay.station_near((2, 400))
    alt_pts_full = offset_path(tr, s_alt0, s_alt1, 140.0, 0.0, ramp=150, step=24)
    alt_pts = alt_pts_full
    alt_points = [[r3(q[0]), r3(q[1]), r3(q[2])] for q in alt_pts]
    cover = [ground(q[0], q[2]) - (q[1] + ALT_TUBE_LIFT + ALT_TUBE_R) for q in alt_pts if q[3] >= 90]
    print(f"Alt1 terrain cover over the tube top where the line is >= 90 off the race line: {[round(c) for c in cover]}")
    for q in alt_pts:  # tube (on the race line itself the main corridor is already open)
        if q[3] >= 20:
            shell_ops.append({"op": "FillBall", "center": [r2(q[0]), r2(q[1] + ALT_TUBE_LIFT), r2(q[2])], "r": ALT_TUBE_R, "mat": "Air"})
    for a, b in zip(alt_pts[:-1], alt_pts[1:]):  # floor under the ledge (after the carve)
        if min(a[3], b[3]) < 20:
            continue
        a3, b3 = np.array(a[:3]), np.array(b[:3])
        f = b3 - a3
        cf = look_cframe((a3 + b3) / 2 + np.array([0, -4.75, 0]), f)
        shell_ops.append({"op": "FillBlock", "cf": [r3(v) for v in cf], "size": [40, 6.5, r2(float(np.linalg.norm(f)) + 4)], "mat": "Ground"})

    # ---- gameplay
    # Checkpoints every 400, except CP7-CP10 (traps_forest1 F2): CP8 sits before the tunnel mouth and the key gallery
    # (credited from ~110 stations before it, never from inside the gallery, which ends before CP9's credit window), so
    # a crash in the gallery respawns in front of its entrance (a ~3 s retry) instead of past it (a full lap).
    stations = [round(400.0 * i, 1) for i in range(6)] + [2350.0, 2700.0, 3150.0, 3550.0] + [4000.0, 4400.0, 4800.0]
    assert len(stations) == 13 and stations[7] < GALLERY_FROM - 30 and stations[8] - 110 > GALLERY_TO, stations
    def ring(name, s, lateral=0.0, height=14.0):
        return {"name": name, "station": round(s, 1), "lateral": lateral, "height": height, "coin": False, "coinId": None}
    climb = [lay.s_liftoff + 90, lay.s_liftoff + 240, lay.s_liftoff + 400]
    rings = [
        ring("BoosterRing_StartArch_1", 112),
        ring("BoosterRing_StartArch_2", 236),
        ring("BoosterRing_Sky_1", climb[0]),
        ring("BoosterRing_Sky_2", climb[1]),
        ring("BoosterRing_Sky_3", climb[2]),
        ring("BoosterRing_HighLine", lay.station_near((800, -945))),
        ring("BoosterRing_TunnelExit", lay.s_exit + 46),
        ring("BoosterRing_WindyGap", lay.s_gap),
        ring("BoosterRing_GreatArch", lay.s_arch),
        {**ring("BoosterRing_SailGate", GATE_STATION, GATE_LATERAL, GATE_HEIGHT),
         "sailGate": {"rpm": GATE_RPM, "phaseDeg": GATE_PHASE, "ringDeg": gate["ring_deg"], "mill": f"Windmills/{GATE_NAME}"}},
    ]
    pads = [{"name": "GroundBoost_TunnelRun", "station": round(lay.s_mouth + 150, 1), "lateral": 0},
            {"name": "GroundBoost_RiverMeadow", "station": round(lay.station_near((600, 595)), 1), "lateral": 0},
            {"name": "GroundBoost_ArchApproach", "station": round(lay.s_arch - 120, 1), "lateral": 0}]
    # Item cubes v3 (docs/design/ITEM_BOXES.md; rules in tools/map/item_cubes.json): 7 staggered two-deep clusters of 5
    # mystery cubes (owner: "do we need to provide more cubes to be available in the air plane?"; v2 had 3 a cluster):
    # a front rank of 2 (lateral -6/+6 at +3/-3) and a back rank of 3 (-10/0/+10 at -3/+3/-3) 36 studs on, round the
    # old pod height, every 650-830 studs. Fixed race stations in free stretches (clear of rings, pads and coins):
    # after the start arches, the sky chain's end, before the high-line ring, the valley run, just out of the tunnel,
    # the windy-gap meadow and the Alt1 span's start (its trail line trades this one cluster). The Speed pickups (mint
    # boost blocks) sit mid-gap, away from the clusters.
    pod_sets = [(330.0, "StartRow"), (1050.0, "SkyRow"), (1700.0, "HighLine"), (2400.0, "ValleyRow"),
                (3150.0, "TunnelRow"), (3900.0, "Meadow"), (4700.0, "FinalStraight")]
    set_st = [s for s, _ in pod_sets]
    pods = []
    for k, (s, nm) in enumerate(pod_sets):
        pods += item_rows.cube_set("plane", "forest1", k, s, 13, lambda t, j, nm=nm: f"{nm}_{t}Pod_{j}", nm)
    for k, nm in ((1, "SkySingle"), (5, "MeadowSingle")):
        pods.append(item_rows.speed_single(f"{nm}_SpeedPod", item_rows.gap_single("plane", set_st, k, tr.length), 13))
    item_rows.assert_layout({"pods": pods}, "plane", "forest1", tr.length)

    def anchor(s, lateral, height, **kw):
        p = tr.at(s, lateral, height)
        d = {"station": round(s, 1), "lateral": round(lateral, 2), "height": round(height, 2), "pos": [r2(v) for v in p]}
        d.update(kw)
        return d

    # coins: 8, one on the Alt1 line (inside the Granary Hill tunnel)
    mid = alt_pts[len(alt_pts) // 2]
    cs, clat, chgt = tr.project(np.array(mid[:3]) + np.array([0, 14, 0]))
    coins = [
        anchor(176, 9, 18, id=1),
        anchor(lay.s_bridge, -8, 22, id=2),
        anchor((climb[1] + climb[2]) / 2, 10, 20, id=3),
        anchor(lay.station_near((1000, -900)), -12, 22, id=4),
        anchor(lay.s_mouth + 210, 12, 12, id=5),
        anchor(lay.s_gap + 70, -10, 18, id=6),
        anchor(cs, clat, chgt, id=7, alternate="Alt1"),
        anchor(lay.s_arch + 60, 9, 16, id=8),
    ]
    coins.sort(key=lambda c: c["station"])
    for i, c in enumerate(coins, 1):
        c["id"] = i
    key = anchor(CELLAR_ST, CELLAR_LAT, 14, note="inside the TunnelMill's base (cellar), reached by the side gallery that "
                 "leaves the tunnel just inside the north mouth; lit doorway visible from the lap")
    # the gallery's centreline at flight-line height (TrackData hiddenKey.gallery): data for a course assist that
    # follows the side tube instead of pulling the plane into its wall (traps_forest1 F3 / summary G8); KeyPickup
    # reads only hiddenKey.pos, so it changes nothing until the runtime uses it
    key["gallery"] = [[r2(q[0]), r2(q[1] + FLIGHT_LINE), r2(q[2])] for q in gallery]

    # battle overlay (LAUNCH_PROGRESSION 2b FOREST: hoard in the windmill field and mill yard; home rings and spawns
    # are laid out with the field mills above)
    prng = random.Random(SEED + 55)
    pickups = []
    while len(pickups) < 18:
        a = prng.uniform(0, 2 * math.pi)
        rr = math.sqrt(prng.random()) * 200
        x, z = yard3[0] + rr * math.cos(a), yard3[2] + rr * math.sin(a)
        if any(math.hypot(x - q[0], z - q[2]) < 30 for q in pickups):
            continue
        if any(math.hypot(x - m[0], z - m[1]) < 24 for m in field_mills.values()):
            continue
        pickups.append([r2(x), r2(ground(x, z) + prng.uniform(10, 34)), r2(z)])
    battle = {
        "mode": "FOREST-BATTLE", "kind": "hoard", "vehicle": "plane",
        "center": [r2(yard3[0]), r2(yard3[1]), r2(yard3[2])], "radius": 250,
        "boundary": {"shape": "cylinder", "center": [r2(yard3[0]), r2(yard3[1]), r2(yard3[2])], "radius": int(BOUND_R),
                     "floor": r2(yard3[1] - 10), "ceiling": r2(yard3[1] + 170), "soft": True},
        "spawns": spawns, "homeRings": home_rings, "pickupAnchors": pickups,
        "rules": {"pickup": "Acorn", "carryMax": 10, "depositToWin": 20, "hitDropFraction": 0.5, "timeCapSeconds": 180,
                  "bots": 3, "items": "race level-one set"},
    }
    boss = {"encounter": "FOREST-BOSS", "hazard": "suspended fireballs",
            "anchors": sorted(round(s, 1) for s in [climb[1], lay.station_near((590, -935)), lay.station_near((1000, -900)),
                                                    lay.s_touchdown + 20, lay.s_mouth + 120, lay.s_mouth + 260,
                                                    lay.s_gap, lay.station_near((500, 615)), lay.s_arch - 60]),
            "note": "fireballs hang on the flight line at these stations (cave/windmill route per CONTENT FOREST-BOSS); "
                    "rematch adds lateral swing"}

    gameplay = {
        "checkpoints": {"stations": stations, "size": [56, 42, 6], "heightOffset": 18},
        "rings": sorted(rings, key=lambda r: r["station"]), "pads": pads, "pods": pods,
        "startGrid": {"station": 18, "height": 11, "rowSpacing": 28, "laneOffset": 12},
        "finish": {"station": 0, "radius": 58},
        "alternates": [{"id": "Alt1", "points": alt_points, "style": "ledge", "joinStation": round(s_alt0, 3),
                        "rejoinStation": round(s_alt1, 3)}],
        "coins": coins, "key": key, "modes": {"battle": battle}, "boss": boss,  # boss beside modes, as the other plans
    }

    # ---- set dressing (L61; helpers above prop_library / Corridor / prop_aabb)
    lib = prop_library()
    cor = Corridor(tr)
    dressing: list[dict] = []
    taken: list[tuple[float, float, float]] = []  # local x, z, footprint radius
    why: dict = {}
    drng = random.Random(SEED + 77)
    building_xy = [(GRANARY[0] + 30, GRANARY[1] + 20, 26), (MILL_YARD[0] - 20, MILL_YARD[1] - 46, 30)]
    pass_pts = [((ax0, az0), (ax1, az1)) for (ax0, az0), (ax1, az1) in ring_passes]

    def dfits(key: str, x: float, z: float, yaw: float, sc: float, spacing: float = 0.8) -> bool:
        sx, sy, sz, collide = lib[key]
        r = 0.5 * math.hypot(sx, sz) * sc

        def no(w: str) -> bool:
            why[w] = why.get(w, 0) + 1
            return False
        if not (xs_l[0] + 160 < x < xs_l[1] - 160 and zs_l[0] + 160 < z < zs_l[1] - 160):
            return no("grid")
        ax_ = np.array([x]); az_ = np.array([z])
        if math.hypot(x - (yard3[0] - ORIGIN[0]), z - (yard3[2] - ORIGIN[2])) < BOUND_R + 8 + r and collide:
            return no("arena")
        for (a0, a1) in pass_pts:
            if seg_dist(ax_, az_, a0[0], a0[1], a1[0], a1[1])[0] < 36 + r:
                return no("ringpass")
        if polyline_dist(ax_, az_, RIVER)[0] < 32 + r:
            return no("river")
        if math.hypot(x - POND[0], z - POND[1]) < POND[2] + 22 + r or math.hypot(x - POOL[0], z - POOL[1]) < POOL[2] + 22 + r:
            return no("pond")
        if polyline_dist(ax_, az_, path_pts)[0] < 12 + r:
            return no("path")
        for (q0, q1) in aq_lines_local:
            if seg_dist(ax_, az_, q0[0], q0[1], q1[0], q1[1])[0] < 24 + r:
                return no("aqueduct")
        for mx, mz in mills_xy:
            if math.hypot(x - mx, z - mz) < 19 + r:
                return no("mill")
        for bx_, bz_, br in building_xy:
            if math.hypot(x - bx_, z - bz_) < br + r:
                return no("building")
        for tx, tz, tr_ in tree_xy:
            if math.hypot(x - tx, z - tz) < tr_ + r + 2:
                return no("tree")
        for tx, tz, tr_ in taken:
            if math.hypot(x - tx, z - tz) < (tr_ + r) * spacing:
                return no("spacing")
        ix = int(round((x - (terrain["x0"] - ORIGIN[0])) / CELL))
        iz = int(round((z - (terrain["z0"] - ORIGIN[2])) / CELL))
        if not (0 <= ix < terrain["nx"] and 0 <= iz < terrain["nz"]) or SLOPE[iz, ix] > 26 or MATS[iz, ix] == M_ROCK:
            return no("slope")
        wx, wz = lw(x, z)
        g = ground(wx, wz)
        if g < WATER_LEVEL + 2.5:
            return no("water")
        c_, h_ = prop_aabb(lib[key], (wx, g + 2.0, wz), yaw, sc)
        if cor.hits(c_[None, :], h_[None, :], margin=PROP_MARGIN).any():
            return no("corridor")
        # a low-route clearance like the trees' (never a prop beside the plane at line height)
        d = np.hypot(tr.pos[:, 0] - wx, tr.pos[:, 2] - wz)
        if np.any((d < 44 + r) & (tr.pos[:, 1] - g < 60)):
            return no("line")
        return True

    def dput(key: str, x: float, z: float, yaw: float, sc: float, **kw) -> bool:
        sc = float(min(max(sc, 0.8), 1.3))
        if key not in lib or not dfits(key, x, z, yaw, sc, **kw):
            return False
        wx, wz = lw(x, z)
        dressing.append({"key": key, "pos": [r2(wx), r2(ground(wx, wz) + 2.0), r2(wz)], "yaw": r2(yaw % 360.0),
                         "scale": r3(sc), "snap": True})
        sx, _sy, sz, _c = lib[key]
        taken.append((x, z, 0.5 * math.hypot(sx, sz) * sc))
        return True

    def face(x, z, tx, tz) -> float:
        """Yaw that turns a FOREST prop's front (+Z) toward (tx, tz) (PropLibrary: concept front on +Z)."""
        return math.degrees(math.atan2(tx - x, tz - z))

    def along(dx, dz) -> float:
        """Yaw that runs a prop's local X (the fence) along (dx, dz)."""
        return math.degrees(math.atan2(-dz, dx))

    def jitter(sc=1.0):
        return round(sc * drng.uniform(0.88, 1.22), 2)

    FARM = ["forest_hay_bale_stack", "forest_produce_cart", "forest_beehive_box", "forest_scarecrow", "forest_stone_well"]

    def cluster(cx, cz, look_x, look_z, kinds, radius=22.0, n=None) -> int:
        """A small storytelling group around (cx, cz) facing (look_x, look_z): the first kinds are the centrepiece."""
        got = 0
        n = n or len(kinds)
        for i in range(n * 3):
            if got >= n:
                break
            key = kinds[got % len(kinds)]
            a = drng.uniform(0, 2 * math.pi)
            rr = 0 if (i == 0) else drng.uniform(radius * 0.4, radius)
            x, z = cx + rr * math.cos(a), cz + rr * math.sin(a)
            yaw = face(x, z, look_x, look_z) + drng.uniform(-25, 25)
            if key == "forest_fence_flowers":
                yaw = along(look_x - x, look_z - z) + 90 + drng.uniform(-10, 10)
            got += dput(key, x, z, yaw, jitter())
        return got

    def route_local(s_, lat):
        q = tr.ground_point(s_ % L, lat)
        return q[0] - ORIGIN[0], q[2] - ORIGIN[2]

    # 1. start and final straights: flower fences in runs parallel to the road, bushes, a farm corner at each end
    for s0, s1 in ((24.0, lay.s_bridge - 30), (lay.s_arch + 70, L - 10)):
        s_ = s0
        while s_ < s1:
            for side in (-1, 1):
                lat = side * drng.uniform(50, 58)
                x, z = route_local(s_, lat)
                t_ = tr.frame(s_ % L).tangent
                if drng.random() < 0.7:
                    for j in range(3):  # a run of three fence segments
                        xx, zz = x + t_[0] * 11.2 * j, z + t_[2] * 11.2 * j
                        dput("forest_fence_flowers", xx, zz, along(t_[0], t_[2]) + drng.uniform(-3, 3), 1.0, spacing=0.3)
                xb, zb = route_local(s_ + 20, side * drng.uniform(62, 74))
                dput("forest_flowering_bush", xb, zb, drng.uniform(0, 360), jitter())
            s_ += 52
    sx_, sz_ = route_local(60, -78)
    cluster(sx_, sz_, *route_local(60, 0), ["forest_hay_bale_stack", "forest_produce_cart", "forest_scarecrow", "forest_hay_bale_stack"])
    sx_, sz_ = route_local(150, 80)
    cluster(sx_, sz_, *route_local(150, 0), ["forest_stone_well", "forest_beehive_box", "forest_beehive_box", "forest_flowering_bush"])
    sx_, sz_ = route_local(L - 120, -82)
    cluster(sx_, sz_, *route_local(L - 120, 0), ["forest_produce_cart", "forest_hay_bale_stack", "forest_flowering_bush"])

    # 2. low turns and booster rings: a cluster on the outside of each turn and beside each low ring
    seen: list[float] = []
    s_ = 0.0
    while s_ < L:
        f0, f1, fm_ = tr.frame((s_ - 35) % L), tr.frame((s_ + 35) % L), tr.frame(s_)
        dt = np.array(f1.tangent) - np.array(f0.tangent)
        bend = float(np.linalg.norm(dt))
        gy_ = ground(fm_.pos[0], fm_.pos[2])
        if bend > 0.28 and fm_.pos[1] - gy_ < 45 and all(abs(s_ - q) > 140 for q in seen):
            seen.append(s_)
            out_side = -1.0 if float(dt @ np.array(fm_.right)) > 0 else 1.0
            for lat in (out_side * 70, out_side * 105):
                x, z = route_local(s_, lat)
                cluster(x, z, *route_local(s_, 0), ["forest_hay_bale_stack", "forest_scarecrow", "forest_fence_flowers",
                                                    "forest_flowering_bush", "forest_hay_bale_stack"], radius=20)
        s_ += 10
    for rg in rings:
        if "sailGate" in rg:  # the gate ring's dressing is placed last on its own stream (additive: nothing else moves)
            continue
        f = tr.frame(rg["station"])
        if f.pos[1] - ground(f.pos[0], f.pos[2]) > 45:
            continue
        for side in (-1, 1):
            x, z = route_local(rg["station"] - 30, side * 56)
            cluster(x, z, *route_local(rg["station"], 0), ["forest_flowering_bush", "forest_mushroom_ring", "forest_flowering_bush"],
                    radius=14)

    # 3. every windmill outside the arena gets a farmyard at its foot (hay, cart, beehives, a fence, flowers)
    gate_xy = (float(gate["tower"][0]) - ORIGIN[0], float(gate["tower"][2]) - ORIGIN[2])
    for mx, mz in mills_xy:
        if math.hypot(mx - gate_xy[0], mz - gate_xy[1]) < 1.0:  # the gate mill: placed last on its own stream
            continue
        kinds = drng.sample(FARM[:3], 3) + ["forest_fence_flowers", "forest_flowering_bush"]
        cluster(mx + drng.uniform(-6, 6), mz + drng.uniform(-6, 6), *route_local(40, 0), kinds, radius=36, n=4)

    # 4. under the high line: the cobble path is a lane through farmland (fences, carts, wells at the bends),
    # scarecrows and hay stacks in the crop fields
    for i, ((x0, z0), (x1, z1)) in enumerate(zip(path_pts[:-1], path_pts[1:])):
        seg = math.hypot(x1 - x0, z1 - z0)
        ux, uz = (x1 - x0) / seg, (z1 - z0) / seg
        t_ = 14.0
        while t_ < seg - 10:
            side = 1 if drng.random() < 0.5 else -1
            x, z = x0 + ux * t_ - uz * side * 17, z0 + uz * t_ + ux * side * 17
            for j in range(2):
                dput("forest_fence_flowers", x + ux * 11.2 * j, z + uz * 11.2 * j, along(ux, uz), 1.0, spacing=0.3)
            t_ += 46
        if i % 2 == 0:
            x, z = x1 + 22, z1 - 18
            cluster(x, z, x1, z1, ["forest_stone_well", "forest_produce_cart", "forest_flowering_bush"], radius=16)
    for (cx, cz, w, d, yaw) in FIELDS:
        cluster(cx, cz, cx + 100, cz + 100, ["forest_scarecrow"], radius=6, n=1)
        c_, s2 = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
        for k in range(2):
            u, v = drng.uniform(-w / 2 + 12, w / 2 - 12), (d / 2 - 12) * (1 if k else -1)
            x, z = cx + u * c_ + v * s2, cz - u * s2 + v * c_
            dput("forest_hay_bale_stack", x, z, yaw + drng.uniform(-20, 20), jitter())

    # 5. river banks and the mill pond: mushroom rings and flowering bushes; a well and beehives by the pond
    for (x0, z0), (x1, z1) in zip(RIVER[:-1], RIVER[1:]):
        seg = math.hypot(x1 - x0, z1 - z0)
        ux, uz = (x1 - x0) / seg, (z1 - z0) / seg
        t_ = 20.0
        while t_ < seg:
            side = 1 if drng.random() < 0.5 else -1
            x, z = x0 + ux * t_ - uz * side * 42, z0 + uz * t_ + ux * side * 42
            dput("forest_flowering_bush" if drng.random() < 0.65 else "forest_mushroom_ring", x, z, drng.uniform(0, 360), jitter())
            t_ += 34
    cluster(POND[0] - POND[2] - 34, POND[1] + 10, POND[0], POND[1], ["forest_stone_well", "forest_beehive_box", "forest_beehive_box",
                                                                    "forest_flowering_bush"], radius=18)

    # 6. Granary Hill: the farm on the plateau over the final bend (seen across the whole last third of the lap)
    gx_, gz_ = GRANARY
    cluster(gx_ - 10, gz_ + 50, gx_ + 30, gz_ + 20, ["forest_produce_cart", "forest_hay_bale_stack", "forest_hay_bale_stack",
                                                    "forest_scarecrow", "forest_stone_well", "forest_beehive_box",
                                                    "forest_fence_flowers", "forest_fence_flowers"], radius=48)

    # 7. open meadows: flowering bushes and the odd fairy ring break up the big fields
    tries = 0
    while sum(1 for e in dressing if e["key"] in ("forest_flowering_bush", "forest_mushroom_ring")) < 150 and tries < 6000:
        tries += 1
        x = drng.uniform(xs_l[0] + 180, xs_l[1] - 180)
        z = drng.uniform(zs_l[0] + 180, zs_l[1] - 180)
        key = "forest_mushroom_ring" if drng.random() < 0.15 else "forest_flowering_bush"
        dput(key, x, z, drng.uniform(0, 360), jitter(), spacing=2.5)
    # 8. the gate mill (sail-gap ring, launch upgrade): its farmyard comes last on a separate random stream, so every
    # placement above is exactly what it was before the mill existed (additive only)
    drng = random.Random(SEED + 4240)
    cluster(gate_xy[0] + drng.uniform(-6, 6), gate_xy[1] + drng.uniform(-6, 6), *route_local(40, 0),
            drng.sample(FARM[:3], 3) + ["forest_fence_flowers", "forest_flowering_bush"], radius=36, n=4)
    dress_counts: dict = {}
    for e in dressing:
        dress_counts[e["key"]] = dress_counts.get(e["key"], 0) + 1
    print(f"setDressing {len(dressing)} {dict(sorted(dress_counts.items()))} rejected={dict(sorted(why.items()))}")

    # ---- L61 ambient life (critic r0: "almost no ambient VFX"): pollen over the wheat, leaves drifting off the
    # groves, glints on the river and the falls, spray at the pool, sparkle shed by every booster ring. All emitters
    # are low-rate, below or beside the line, and small at phone size.
    sparkle, glow, leaf = fx_texture("sparkle_star_4x4"), fx_texture("glow_soft"), fx_texture("leaf")
    drop = fx_texture("water_droplet")
    star = {"Texture": sparkle, "FlipbookLayout": "Grid4x4", "FlipbookMode": "Loop", "FlipbookFramerate": [24, 24],
            "FlipbookStartRandom": True}
    for i, (cx, cz, w, d, yaw) in enumerate(FIELDS):
        wx, wz = lw(cx, cz)
        fx_list.append({"class": "ParticleEmitter", "name": f"FieldPollen_{i + 1}", "group": "Ambience",
                        "cf": cf_at(wx, ground(wx, wz) + 9, wz), "size": [w, 12, d],
                        "props": {"Texture": glow, "Rate": 5, "Lifetime": [4, 6], "Speed": [0.3, 1.2], "SpreadAngle": [180, 180],
                                  "Acceleration": [1.2, 0.5, 0.6], "Color": "#ffe9a8", "LightEmission": 0.75,
                                  "Size": {"seq": [[0, 0, 0], [0.25, 0.55, 0.15], [0.75, 0.45, 0.1], [1, 0, 0]]},
                                  "Transparency": {"seq": [[0, 0.2, 0], [1, 0.75, 0]]}}})
    grove_pts = [(x, z) for (x, z, _r) in tree_xy][::9]
    for i, (x, z) in enumerate(grove_pts[:22]):
        wx, wz = lw(x, z)
        fx_list.append({"class": "ParticleEmitter", "name": f"GroveLeaves_{i + 1}", "group": "Ambience",
                        "cf": cf_at(wx, ground(wx, wz) + 26, wz), "size": [30, 6, 30],
                        "props": {"Texture": leaf, "Rate": 1.6, "Lifetime": [5, 8], "Speed": [1, 3], "SpreadAngle": [60, 60],
                                  "Acceleration": [4, -2.2, 1.5], "Drag": 0.2, "Rotation": [0, 360], "RotSpeed": [-140, 140],
                                  "EmissionDirection": "Bottom", "LightEmission": 0.05,
                                  "Color": {"seq": [[0, "#8aaa52"], [1, "#e0a844"]]},
                                  "Size": {"seq": [[0, 1.3, 0.2], [1, 1.0, 0.2]]},
                                  "Transparency": {"seq": [[0, 1, 0], [0.1, 0.05, 0], [0.85, 0.1, 0], [1, 1, 0]]}}})
    for i, ((x0, z0), (x1, z1)) in enumerate(zip(RIVER[:-1], RIVER[1:])):
        wx, wz = lw((x0 + x1) / 2, (z0 + z1) / 2)
        seg = math.hypot(x1 - x0, z1 - z0)
        fx_list.append({"class": "ParticleEmitter", "name": f"RiverGlints_{i + 1}", "group": "Ambience",
                        "cf": [r2(wx), WATER_LEVEL + 0.6, r2(wz)] + [r3(v) for v in np.array(adapt_rot(0.0, math.degrees(math.atan2(-(x1 - x0), -(z1 - z0))), 0.0)).flatten()],
                        "size": [22, 0.5, r2(seg)],
                        "props": {**star, "Rate": 4, "Lifetime": [0.5, 0.9], "Speed": [0, 0.2], "Color": "#fffbe6",
                                  "LightEmission": 1, "Size": {"seq": [[0, 0, 0], [0.4, 1.2, 0.3], [1, 0, 0]]},
                                  "Transparency": {"seq": [[0, 0.05, 0], [1, 0.5, 0]]}}})
    for i, c in enumerate(fall_bays):
        o = c + east * 14
        fx_list.append({"class": "ParticleEmitter", "name": f"WaterfallGlints_{i + 1}", "group": "Aqueduct/Waterfalls",
                        "cf": cf_at(o[0], (AQ_DECK + WATER_LEVEL) / 2, o[2]), "size": [8, AQ_DECK - WATER_LEVEL - 10, 18],
                        "props": {**star, "Rate": 8, "Lifetime": [0.5, 0.9], "Speed": [0, 0.3], "Color": "#f2fdff",
                                  "LightEmission": 1, "Size": {"seq": [[0, 0, 0], [0.35, 1.5, 0.4], [1, 0, 0]]},
                                  "Transparency": {"seq": [[0, 0.05, 0], [1, 0.45, 0]]}}})
        base = (o[0] + 4, WATER_LEVEL + 1, o[2])
        fx_list.append({"class": "ParticleEmitter", "name": f"WaterfallSpray_{i + 1}", "group": "Aqueduct/Waterfalls",
                        "cf": cf_at(*base), "size": [14, 1, 16],
                        "props": {"Texture": drop, "Rate": 18, "Lifetime": [0.6, 1.1], "Speed": [14, 24], "SpreadAngle": [28, 28],
                                  "Acceleration": [0, -60, 0], "Color": "#e8fbff", "LightEmission": 0.3, "EmissionDirection": "Top",
                                  "Size": {"seq": [[0, 0.9, 0.2], [1, 0.4, 0.1]]},
                                  "Transparency": {"seq": [[0, 0.1, 0], [1, 0.8, 0]]}}})
    for rg in rings:
        if "sailGate" in rg:  # the gate ring sparkles only while lit (client/SailGateFx), so a dark ring reads dark
            continue
        f = tr.frame(rg["station"])
        c = np.array(f.offset(rg["lateral"], rg["height"]))
        fx_list.append({"class": "ParticleEmitter", "name": f"RingSparkle_{rg['name']}", "group": "Ambience",
                        "cf": [r3(v) for v in look_cframe(c, f.tangent)], "size": [24, 24, 0.5],
                        "props": {**star, "Shape": "Cylinder", "ShapeStyle": "Surface", "ShapeInOut": "Outward",
                                  "EmissionDirection": "Back", "Rate": 12, "Lifetime": [0.9, 1.4], "Speed": [0.4, 1.2],
                                  "SpreadAngle": [30, 30], "Color": "#fff1c8", "LightEmission": 1.0,
                                  "Size": {"seq": [[0, 0.0, 0], [0.3, 1.3, 0.3], [1, 0.0, 0]]},
                                  "Transparency": {"seq": [[0, 0.1, 0], [1, 0.6, 0]]}}})

    # ---- fx: mill pond sparkle-free mist at the pool, warm lights in the cellar doorway
    fx_list.append({"class": "ParticleEmitter", "name": "PoolMist", "group": "Aqueduct/Waterfalls",
                    "cf": [r2(world(*POOL[:2])[0]), WATER_LEVEL + 1, r2(world(*POOL[:2])[1]), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                    "size": [60, 1, 60],
                    "props": {"Texture": "rbxasset://textures/particles/smoke_main.dds", "Rate": 6, "Lifetime": [3, 5],
                              "Speed": [1, 2], "Color": "#f4fbff", "Size": [[0, 8, 2], [1, 18, 3]],
                              "Transparency": [[0, 0.75, 0], [1, 1, 0]], "LightEmission": 0.1}})
    # the lit doorway: where the gallery leaves the main tube (its offset passes 40), on the gallery line
    door = next(np.array(q[:3]) for q in gallery if q[3] >= 40.0)
    fx_list.append({"class": "PointLight", "name": "CellarDoorGlow", "group": "TunnelHill/TunnelMill",
                    "cf": [r2(door[0]), r2(door[1] + 18), r2(door[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                    "props": {"Brightness": 1.6, "Range": 36, "Color": "#ffc274", "Shadows": False}})

    materials = {
        "terrainOverrides": {"Grass": "SR_FOREST_Meadow", "Ground": "SR_FOREST_Dirt", "Limestone": "SR_FOREST_MossyStone",
                             "LeafyGrass": "SR_FOREST_Crops", "Cobblestone": "SR_FOREST_Cobble", "Mud": "SR_FOREST_MeadowDeep"},
        "terrainColor": "#ffffff",
        # terrain-look: lake water pass, applied at runtime by MapAdapter after the builder (the builder reads terrain.water and
        # a 0.45 reflectance default; changing either would change terrain_hash and invalidate the forest1 bake)
        "waterColor": "#3fb9d8", "waterTransparency": 0.5, "waterReflectance": 0.3,
        # critic v28 1.22: the tunnel floor (RouteFloorFill Ground) read orange; a mid brown tint at runtime only (the
        # palette in terrain.* is untouched, so the terrain bake hash stays valid)
        "terrainColors": {**{e["material"]: e["color"] for e in PALETTE}, "Ground": "#8a6b4e"},
        "partRules": [
            {"name": "^Paver_", "setMaterial": "Cobblestone", "variant": "SR_FOREST_Cobble"},
            {"name": "^Alt1Ledge", "setMaterial": "Cobblestone", "variant": "SR_FOREST_Cobble"},
            {"name": "^TrackSeg_", "setMaterial": "Slate", "variant": "SR_FOREST_Masonry"},
            {"name": "^Curb", "setMaterial": "Slate", "variant": "SR_FOREST_Masonry"},
            {"name": "^BridgeFascia_", "setMaterial": "Slate", "variant": "SR_FOREST_Masonry"},
            {"material": "Slate", "variant": "SR_FOREST_Masonry"},
            {"material": "WoodPlanks", "variant": "SR_FOREST_MillWood"},
        ],
    }

    plan = {
        "prefabs": {k: prefabs[k] for k in sorted(prefabs)},
        "instances": instances,
        "groups": groups,
        "terrain": terrain,
        "markers": [],
        "skyrally": {
            "archetype": "Timing gates through windmill sails", "signatureVerb": "thread",
            "signature": "Thread the windmill sail gaps on the climb, timing each pass to the turning blades.",
            "id": MAP_ID, "key": KEY, "zone": "FOREST", "vehicle": "plane", "laps": 3, "guide": GUIDE, "lighting": MAP_ID,
            "route": route_block(),
            "deck": {"style": "forest1_cobble", "width": DECK_WIDTH, "zones": [], "curbHeights": [4.4, 4.0],
                     "gaps": [{"from": round(lay.s_liftoff, 1), "to": round(lay.s_touchdown, 1),
                               "reason": "high flight line: the road continues below as a cobblestone terrain path"}],
                     "piersEvery": 0},
            "flight": {"lineOffset": int(FLIGHT_LINE), "corridor": {"halfWidth": 34, "floor": 5, "ceiling": 44},
                       "allowPockets": []},  # FLIGHT_GUIDE.md 12.3: survey found none needed (key gallery and cellar stay within 112 studs of the line)
            "gameplay": gameplay,
            "shells": {"ops": shell_ops},
            "backdrop": BACKDROP,
            "hazards": [], "meshes": [], "modelAttributes": model_attrs, "fx": fx_list, "setDressing": dressing,
            "framing": {"heroStation": 40, "note": "first gameplay view matches 13_FOREST1_WINDMILL_PLAINS.png: road north "
                        "between the hero mills, ground arches, aqueduct + waterfalls left, aerial rings ahead-right"},
            "routeLights": {"every": 3, "fromStation": round(lay.s_mouth - 10, 1), "toStation": round(lay.s_exit + 10, 1),
                            "offsets": [[-38, 30], [38, 30]], "color": "#ffc47a", "range": 52, "brightness": 1.1},
            "materials": materials,
            "provenance": {"author": "tools/map/author_forest1.py", "seed": SEED, "origin": list(ORIGIN),
                           "routeFlexScale": round(tr.route.flex_scale, 6), "routeLength": round(L, 3),
                           "stations": {"bridge": round(lay.s_bridge, 1), "liftoff": round(lay.s_liftoff, 1),
                                        "touchdown": round(lay.s_touchdown, 1), "tunnelMouth": round(lay.s_mouth, 1),
                                        "tunnelExit": round(lay.s_exit, 1), "windyGap": round(lay.s_gap, 1),
                                        "greatArch": round(lay.s_arch, 1)},
                           "keyGallery": {"from": round(GALLERY_FROM, 1), "to": round(GALLERY_TO, 1),
                                          "lateral": CELLAR_LAT, "ramp": GALLERY_RAMP, "radius": GALLERY_R,
                                          "cellarStation": round(CELLAR_ST, 1), "cellarCarveRadius": CELLAR_CARVE_R},
                           "rimCliff": {"margin": RIM_MARGIN, "driftDeg": RIM_DRIFT_DEG, "slope": RIM_CLIFF_SLOPE,
                                        "foothill": RIM_FOOTHILL, "band": RIM_BAND},
                           "sky": "assets/sky/forest1/{up,side,down}.png (write_sky in this script; not uploaded)",
                           "materialSet": "assets/materials/forest_v1 (variants.json written by this script)"},
        },
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    text = dump_plan(plan)
    OUT.write_text(text + "\n")
    write_variants()
    sky = write_sky()
    nparts = sum(len(prefabs[i["pf"]]["parts"]) for i in instances)
    shown = OUT.relative_to(ROOT) if OUT.is_relative_to(ROOT) else OUT
    print(f"wrote {shown} length={L:.2f} flex={tr.route.flex_scale:.4f} prefabs={len(prefabs)} "
          f"instances={len(instances)} placedParts={nparts} grid={terrain['nx']}x{terrain['nz']} shellOps={len(shell_ops)} "
          f"rings={len(rings)} pads={len(pads)} pods={len(pods)} coins={len(coins)} bytes={len(text)} "
          f"sha256={hashlib.sha256(text.encode()).hexdigest()[:12]} sky={sky}")
    print(f"stations: {json.dumps(plan['skyrally']['provenance']['stations'])} alt1={round(s_alt0, 1)}..{round(s_alt1, 1)} "
          f"altPts={len(alt_points)} scatter={counts}")


def dump_plan(plan: dict) -> str:
    """Diff-friendly JSON: objects indented, scalar lists on one line (a part, a vector, a CFrame), the terrain grid
    one row per line."""
    nx = plan["terrain"]["nx"]

    def scalar(v):
        return not isinstance(v, (dict, list))

    def enc(v, ind, key=None):
        pad = " " * ind
        if isinstance(v, dict):
            if not v:
                return "{}"
            items = [f'{pad} {json.dumps(k)}: {enc(x, ind + 1, k)}' for k, x in v.items()]
            return "{\n" + ",\n".join(items) + "\n" + pad + "}"
        if isinstance(v, list):
            if key in ("heights", "materials"):
                rows = [",".join(json.dumps(x) for x in v[i:i + nx]) for i in range(0, len(v), nx)]
                return "[\n" + ",\n".join(pad + "  " + r for r in rows) + "\n" + pad + "]"
            if all(scalar(x) for x in v) or (all(isinstance(x, (list, dict)) for x in v) and
                                              all(scalar(y) for x in v if isinstance(x, list) for y in x) and
                                              all(isinstance(x, list) for x in v) and len(v) <= 4):
                return json.dumps(v, separators=(", ", ": "))
            return "[\n" + ",\n".join(pad + "  " + enc(x, ind + 2) for x in v) + "\n" + pad + "]"
        return json.dumps(v)

    text = enc(plan, 0)
    assert json.loads(text) == plan
    return text


def offset_path(tr: Track, s0, s1, lateral, height, ramp, step):
    """author_dino4.offset_path semantics: race-line frames offset by lateral (right +) and height, eased in over `ramp`
    after s0 and out over `ramp` before s1, so both ends sit on the race line. Returns [x, y, z, |offset|]."""
    out = []
    n = max(2, int(math.ceil((s1 - s0) / step)) + 1)  # even spacing, so the last point sits exactly at s1
    for i in range(n):
        s_ = s0 + (s1 - s0) * i / (n - 1)
        k = min(smooth1((s_ - s0) / ramp), smooth1((s1 - s_) / ramp))
        f = tr.frame(s_)
        q = np.array(f.pos) + np.array(f.right) * lateral * k + np.array([0, height * k, 0])
        out.append([float(q[0]), float(q[1]), float(q[2]), abs(lateral * k)])
    return out


def smooth1(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def look_cframe(pos, fwd):
    """CFrame.lookAt(pos, pos + fwd) components (RightVector, UpVector, -LookVector columns)."""
    f = np.asarray(fwd, float)
    f = f / np.linalg.norm(f)
    r = np.cross(f, [0, 1, 0])
    r = r / np.linalg.norm(r)
    u = np.cross(r, f)
    return [pos[0], pos[1], pos[2], r[0], u[0], -f[0], r[1], u[1], -f[1], r[2], u[2], -f[2]]


if __name__ == "__main__":
    main()
