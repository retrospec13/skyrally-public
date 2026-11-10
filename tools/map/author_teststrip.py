#!/usr/bin/env python3
"""TRACK_PIPELINE P1 author script for TEST-STRIP, the launch car's test track (PLAN L2, TEST_LIST_LAUNCH L05):
design data in this file -> map/teststrip/plan.json (docs/MAP_PLAN_SCHEMA.md). Deterministic. Change the strip here and
rerun, then `python3 tools/map/adapt.py map/teststrip/plan.json`; never edit the plan or build/teststrip/* by hand.

The strip exercises every car behaviour on one ~1800-stud loop (counter-clockwise from above):
  main straight (start/finish, pad) -> gentle left sweeper -> jump: ramp crest with a deck gap over a water pool
  (too slow = splash and respawn; the lip-to-landing speed is computed below) -> tight left hairpin -> right/left
  chicane -> medium left -> straight with an item-pod row and a pad -> banked left (bank 14 deg) back onto the main
  straight.
Construction: a raised causeway (the dino_paver deck kit, piers buried) over a flat Grass field 8 studs below the
road, so the banked deck never meets Terrain. Low barrier walls (cream body, red non-colliding rail) run both sides
except over the gap: they are what the car's wall deflect / bump / spin-out responses hit. Falling off the causeway is
a stranded-off-track respawn; missing the jump is a water respawn. Placed at x=+4000 so it can be built in the same
place as DINO-4 without overlapping it.
"""
from __future__ import annotations

import hashlib
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
for _p in (ROOT / "tools" / "map", ROOT / "tools" / "course"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import route as routelib  # noqa: E402
import route_geometry  # noqa: E402

OUT = ROOT / "map" / "teststrip" / "plan.json"

ORIGIN = (4000.0, 20.0, 0.0)  # route base height 20; grass top at 12
GRASS_TOP = 12.0
TARGET_LENGTH = 1800
DECK_WIDTH = 40
DECK_TOP = 1.6  # TrackSeg top above the ribbon (kit/Deck: centre -2.2, height 7.6); pavers reach +2.7
WALL_LATERAL = 24.2  # wall centre line: curbs end at 23.2 (half width 20 + 1.4 + 1.8)
WALL_THICK = 2.0
WALL_HEIGHT = 6.0
WALL_MAX_PIECE = 6.0  # short pieces keep their world AABBs out of the corridor gate on diagonal bends
WALL_SAG = 0.2  # max deviation of a straight wall piece from the offset curve
CORRIDOR_HALF_WIDTH = 17
CAR_GRAVITY = 140.0  # src/shared/CarConfig.luau GRAVITY (the jump check below must match the controller)
JUMP_GAP = 17.0  # deck gap length after the lip (studs of station)
CHECKPOINT_EVERY = 150

# Route nodes in local coordinates: (x, z, height above the base, bank deg, flex x). Positive bank raises the right
# edge (kit/Deck: lookAt * Angles(0, 0, bank)), i.e. the outside of a left turn. flex widens the loop westward so
# the adapter's bisection lands the length exactly on TARGET_LENGTH.
NODES = [
    # main straight, heading north (-Z); node 1 is station 0 = start/finish
    (0.0, -30.0, 0.0, 0.0, 0.0),
    (0.0, -120.0, 0.0, 0.0, 0.0),
    (0.0, -210.0, 0.0, 0.0, 0.0),
    # A: gentle left sweeper, R 160, centre (-160, -300)
    (0.0, -300.0, 0.0, 2.0, 0.0),
    (-21.4, -380.0, 0.0, 5.0, 0.0),
    (-80.0, -438.6, 0.0, 5.0, 0.0),
    (-160.0, -460.0, 0.0, 2.0, 0.0),
    # jump on the top straight, heading west: ramp up to the crest, steep drop beyond it (deck gap over the pool)
    # Close nodes at the lip give a sharp crest (uniform Catmull-Rom smooths widely spaced ones into a hump).
    (-198.0, -460.0, 3.0, 0.0, 0.0),
    (-232.0, -460.0, 9.5, 0.0, 0.0),
    (-244.0, -460.0, 11.5, 0.0, 0.0),
    (-256.0, -460.0, 8.0, 0.0, 0.0),
    (-290.0, -460.0, 2.0, 0.0, 0.0),
    (-328.0, -460.0, 0.0, 0.0, 0.0),
    # B: tight left hairpin corner, R 55, centre (-358, -405)
    (-358.0, -460.0, 0.0, 0.0, -1.0),
    (-396.9, -443.9, 0.0, 3.0, -1.0),
    (-413.0, -405.0, 0.0, 0.0, -1.0),
    # west side heading south with a right-left chicane (right = west while heading south)
    (-413.0, -330.0, 0.0, 0.0, -1.0),
    (-428.0, -260.0, 0.0, -4.0, -1.0),
    (-446.0, -200.0, 0.0, 0.0, -1.0),
    (-430.0, -140.0, 0.0, 4.0, -1.0),
    (-413.0, -80.0, 0.0, 0.0, -1.0),
    # C: medium left, R 90, centre (-323, -10)
    (-413.0, -10.0, 0.0, 3.0, -1.0),
    (-386.6, 53.6, 0.0, 6.0, -1.0),
    (-323.0, 80.0, 0.0, 3.0, -1.0),
    # bottom straight heading east (item pods, pad)
    (-245.0, 80.0, 0.0, 0.0, -0.5),
    (-175.0, 80.0, 0.0, 0.0, 0.0),
    # D: banked left, R 110, centre (-110, -30)
    (-110.0, 80.0, 0.0, 8.0, 0.0),
    (-55.0, 65.3, 0.0, 14.0, 0.0),
    (-14.7, 25.0, 0.0, 14.0, 0.0),
]
FLEX = 12.0  # studs of westward widening per unit of flex scale


def r4(x: float) -> float:
    v = round(float(x), 4)
    return 0.0 if v == 0 else v


def world(x: float, z: float, h: float) -> list[float]:
    return [r4(ORIGIN[0] + x), r4(ORIGIN[1] + h), r4(ORIGIN[2] + z)]


def route_block() -> dict:
    nodes = []
    for x, z, h, bank, fx in NODES:
        n = {"pos": world(x, z, h), "bank": bank}
        if fx:
            n["flex"] = [r4(fx * FLEX), 0.0, 0.0]
        nodes.append(n)
    return {"nodes": nodes, "closed": True, "samplesPerSegment": 6, "targetLength": TARGET_LENGTH,
            "flexScaleMin": 0.0, "flexScaleMax": 3.5, "bisectIterations": 24, "minRadius": 45,
            "radiusExceptions": []}


# ------------------------------------------------------------------------------------------- geometry helpers
def banked_axes(f: routelib.Frame) -> tuple[tuple, tuple]:
    """Right and up of the deck at a station: the route frame rolled by the bank, as kit/Deck rolls each segment."""
    b = math.radians(f.bank)
    right = routelib.add(routelib.mul(f.right, math.cos(b)), routelib.mul(f.up, math.sin(b)))
    up = routelib.sub(routelib.mul(f.up, math.cos(b)), routelib.mul(f.right, math.sin(b)))
    return right, up


def yxz_from_axes(right: tuple, up: tuple, look: tuple) -> list[float]:
    """YXZ Euler degrees (30MAPS / CFrame.fromEulerAnglesYXZ) of the rotation with these Right/Up/Look vectors."""
    # Columns of R are Right, Up, Back (= -Look). R = Ry * Rx * Rz.
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


def in_ranges(st: float, ranges: list[tuple[float, float]]) -> bool:
    return any(a <= st <= b for a, b in ranges)


# ------------------------------------------------------------------------------------------------ the jump
def find_lip(route: routelib.Route) -> float:
    """Station of the highest route point on the top straight (the ramp crest): the deck ends there."""
    best_st, best_y = 0.0, -1e9
    for w in route.waypoints:
        if w.pos[1] > best_y:
            best_y, best_st = w.pos[1], w.station
    return best_st


def deck_gap_span(route: routelib.Route, gap_from: float, gap_to: float) -> tuple[float, float]:
    """Where the built deck really ends and resumes: kit/Deck skips a segment when its START station is inside
    [from, to], and the segment before the gap reaches its end waypoint."""
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
    """Ribbon-relative height of the car's ballistic path (CarConfig.GRAVITY) x studs past the deck end, launched
    along the route tangent there (deck-top offsets are equal at both ends and cancel)."""
    f = route.frame_at(lip)
    vh = speed * math.hypot(f.tangent[0], f.tangent[2])
    t = x / vh
    return f.pos[1] + speed * f.tangent[1] * t - 0.5 * CAR_GRAVITY * t * t


def clears_gap(route: routelib.Route, lip: float, resume: float, speed: float) -> bool:
    """Inside the gap there is no surface, so only the far deck matters: the car must still be above it when its
    rear wheels (3.2 aft of the centre) pass the deck's front edge; lower means it meets the front face or the pool."""
    x = resume - lip + 3.2
    return car_height(route, lip, speed, x) >= route.frame_at(resume + 3.2).pos[1]


def landing_station(route: routelib.Route, lip: float, resume: float, speed: float) -> float:
    """Station where a car that clears the gap meets the far deck."""
    x = resume - lip
    while x < 400:
        if car_height(route, lip, speed, x) <= route.frame_at(lip + x).pos[1]:
            return lip + x
        x += 0.25
    return lip + x


def min_jump_speed(route: routelib.Route, lip: float, resume: float) -> float:
    lo, hi = 10.0, 400.0
    for _ in range(40):
        mid = (lo + hi) * 0.5
        if clears_gap(route, lip, resume, mid):
            hi = mid
        else:
            lo = mid
    return hi


# ----------------------------------------------------------------------------------------------- the walls
def offset_point(route: routelib.Route, st: float, side: float, lateral: float, height: float) -> tuple:
    f = route.frame_at(st)
    right, up = banked_axes(f)
    return routelib.add(routelib.add(f.pos, routelib.mul(right, side * lateral)), routelib.mul(up, height))


def wall_pieces(route: routelib.Route, skip: list[tuple[float, float]]) -> list[dict]:
    """Greedy straight pieces along each side's offset curve (base at the deck top), split where the curve leaves a
    piece by more than WALL_SAG or the piece would exceed WALL_MAX_PIECE. Each piece spans point a -> b exactly."""
    pieces = []
    step = 1.0
    total = route.length
    for side in (-1.0, 1.0):
        st = 0.0
        while st < total:
            if in_ranges(st, skip):
                st += step
                continue
            a_st = st
            b_st = st
            probe = st + step
            while probe <= total and not in_ranges(probe, skip):
                a = offset_point(route, a_st, side, WALL_LATERAL, DECK_TOP)
                b = offset_point(route, probe, side, WALL_LATERAL, DECK_TOP)
                if routelib.mag(routelib.sub(b, a)) > WALL_MAX_PIECE:
                    break
                ok = True
                k = a_st + step
                while k < probe:
                    p = offset_point(route, k, side, WALL_LATERAL, DECK_TOP)
                    ab = routelib.sub(b, a)
                    t = max(0.0, min(1.0, routelib.dot(routelib.sub(p, a), ab) / max(1e-9, routelib.dot(ab, ab))))
                    q = routelib.add(a, routelib.mul(ab, t))
                    if routelib.mag(routelib.sub(p, q)) > WALL_SAG:
                        ok = False
                        break
                    k += step
                if not ok:
                    break
                b_st = probe
                probe += step
            if b_st <= a_st:
                b_st = min(total, a_st + step)
            a = offset_point(route, a_st, side, WALL_LATERAL, DECK_TOP)
            b = offset_point(route, b_st, side, WALL_LATERAL, DECK_TOP)
            mid_st = (a_st + b_st) * 0.5
            f = route.frame_at(mid_st)
            _, up = banked_axes(f)
            look = routelib.unit(routelib.sub(b, a))
            right = routelib.unit(routelib.cross(look, up))
            up2 = routelib.unit(routelib.cross(right, look))
            length = routelib.mag(routelib.sub(b, a))
            centre = routelib.mul(routelib.add(a, b), 0.5)
            pieces.append({"side": side, "from": a_st, "to": b_st, "len": length, "p": centre,
                           "r": yxz_from_axes(right, up2, look)})
            st = b_st
    return pieces


def wall_prefab_key(length: float) -> tuple[str, float]:
    q = math.ceil(length * 4.0) / 4.0  # quarter-stud buckets; pieces overlap by < 0.25 stud (same colour, no flicker)
    return "Barrier_%05.2f" % q, q


def wall_prefab(length: float) -> dict:
    return {"parts": [
        ["B", 0, r4(WALL_HEIGHT / 2), 0, WALL_THICK, WALL_HEIGHT, r4(length), 0, 0, 0, "#efe6d2", "Concrete"],
        ["B", 0, r4(WALL_HEIGHT + 0.15), 0, 1.4, 0.3, r4(length), 0, 0, 0, "#c8402e", "SmoothPlastic", {"nc": 1}],
    ]}


# ---------------------------------------------------------------------------------------------------- build
def main() -> None:
    rt = route_block()
    route = routelib.solve_plan_route(rt)
    length = route.length
    rows, _ = route_geometry.analyse([list(w.pos) for w in route.waypoints], min_radius=rt["minRadius"])
    min_r = min(rows, key=lambda r: r["r"])

    # Jump: deck gap from the crest over the steep drop.
    lip = round(find_lip(route), 1)
    gap_from, gap_to = lip, round(lip + JUMP_GAP, 1)
    deck_end, deck_resume = deck_gap_span(route, gap_from, gap_to)
    v_min = min_jump_speed(route, deck_end, deck_resume)
    land_128 = landing_station(route, deck_end, deck_resume, 128.0)
    land_165 = landing_station(route, deck_end, deck_resume, 165.0)

    # Checkpoints every ~150 studs, nudged out of the gap (a respawn frame must sit over road).
    stations = []
    st = 0.0
    while st < length - 60:
        s = st
        if gap_from - 25 <= s <= gap_to + 25:
            s = gap_to + 30
        stations.append(round(s, 1))
        st += CHECKPOINT_EVERY

    # Station landmarks along the loop (computed, so they survive node edits).
    def station_near(x: float, z: float) -> float:
        p = (ORIGIN[0] + x, ORIGIN[1], ORIGIN[2] + z)
        best = min(route.waypoints, key=lambda w: (w.pos[0] - p[0]) ** 2 + (w.pos[2] - p[2]) ** 2)
        return round(best.station, 1)

    pad_main = 150.0
    # West straight after the hairpin: a boost before the jump would carry 165 studs/s into the hairpin.
    pad_west = station_near(-413.0, -330.0)
    hairpin_st = station_near(-358.0, -460.0)
    # Bottom straight: the pad sits at corner C's exit so its boost is spent on the straight (through the pod row),
    # not carried into the banked turn.
    pad_bottom = station_near(-310.0, 80.0)
    pods_st = station_near(-205.0, 80.0)

    # Walls: both sides, everywhere but over the gap (plus a stud each side so no piece hangs into it).
    skip = [(deck_end - 1.0, deck_resume + 1.0)]
    pieces = wall_pieces(route, skip)
    prefabs: dict[str, dict] = {}
    instances = []
    groups = ["Landmarks", "Barriers"]
    for pc in pieces:
        key, q = wall_prefab_key(pc["len"])
        if key not in prefabs:
            prefabs[key] = wall_prefab(q)
        instances.append({"pf": key, "p": [r4(v) for v in pc["p"]], "g": 2, "r": pc["r"]})

    # Start/finish arch over station 0 (pillars outside the walls; beam and banner non-colliding) and a checkered
    # line on the pavers (non-colliding, 0.05 above the paver tops).
    f0 = route.frame_at(0.0)
    right0, up0 = banked_axes(f0)
    arch_parts = []
    for side in (-1, 1):
        arch_parts.append(["B", side * 28.5, 9, 0, 2.6, 18, 2.6, 0, 0, 0, "#3f2a22", "WoodPlanks"])
        arch_parts.append(["B", side * 28.5, 0.5, 0, 4, 1, 4, 0, 0, 0, "#7a5a3a", "Slate"])
    arch_parts.append(["B", 0, 18.6, 0, 62, 1.6, 2.2, 0, 0, 0, "#3f2a22", "WoodPlanks", {"nc": 1}])
    for i in range(12):
        arch_parts.append(["B", -27.5 + i * 5, 16.6, 0, 5, 2.4, 0.4, 0, 0, 0, "#f2ead8" if i % 2 == 0 else "#1e1a1a",
                           "SmoothPlastic", {"nc": 1}])
    prefabs["StartArch"] = {"parts": arch_parts}
    for i in range(20):
        for j in range(2):
            prefabs.setdefault("StartLine", {"parts": []})["parts"].append(
                ["B", r4(-19 + i * 2), 0, r4(-1 + j * 2), 2, 0.1, 2, 0, 0, 0,
                 "#f2ead8" if (i + j) % 2 == 0 else "#1e1a1a", "SmoothPlastic", {"nc": 1}])
    look0 = f0.tangent
    rot0 = yxz_from_axes(right0, up0, look0)
    instances.append({"pf": "StartArch", "p": [r4(v) for v in routelib.add(f0.pos, routelib.mul(up0, DECK_TOP))],
                      "g": 1, "r": rot0})
    instances.append({"pf": "StartLine", "p": [r4(v) for v in routelib.add(f0.pos, routelib.mul(up0, 2.75))],
                      "g": 1, "r": rot0})

    # Terrain: one flat Grass field under the loop; a carved pool of Water under the jump gap.
    xs = [w.pos[0] for w in route.waypoints]
    zs = [w.pos[2] for w in route.waypoints]
    margin = 160.0
    gx0, gx1, gz0, gz1 = min(xs) - margin, max(xs) + margin, min(zs) - margin, max(zs) + margin
    grass_cf = [r4((gx0 + gx1) / 2), GRASS_TOP - 8.0, r4((gz0 + gz1) / 2), 1, 0, 0, 0, 1, 0, 0, 0, 1]
    pa = route.frame_at(deck_end)
    pb = route.frame_at(deck_resume)
    pool_mid = routelib.mul(routelib.add(pa.pos, pb.pos), 0.5)
    pool_len = routelib.mag(routelib.sub(pb.pos, pa.pos)) + 60.0
    yaw = math.degrees(math.atan2(-pa.tangent[0], -pa.tangent[2]))
    cy, sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    pool_rot = [cy, 0, sy, 0, 1, 0, -sy, 0, cy]

    def pool_cf(y: float) -> list[float]:
        return [r4(pool_mid[0]), r4(y), r4(pool_mid[2])] + [r4(v) for v in pool_rot]

    shell_ops = [
        {"op": "SetMaterialColor", "mat": "Grass", "color": "#6fa04a"},
        {"op": "FillBlock", "cf": grass_cf, "size": [r4(gx1 - gx0), 16, r4(gz1 - gz0)], "mat": "Grass"},
        {"op": "FillBlock", "cf": pool_cf(GRASS_TOP - 6.0), "size": [70, 14, r4(pool_len)], "mat": "Air"},
        {"op": "FillBlock", "cf": pool_cf(GRASS_TOP - 8.0), "size": [70, 10, r4(pool_len)], "mat": "Water"},
    ]

    plan = {
        "prefabs": {k: prefabs[k] for k in sorted(prefabs)},
        "instances": instances,
        "groups": groups,
        "terrain": {"nx": 1, "nz": 1, "cell": 4},
        "markers": [],
        "skyrally": {
            "archetype": "Engineering test strip", "signatureVerb": "test",
            "signature": "Straight-line test bench for the launch car (QA only, not a raced map).",
            "id": "TEST-STRIP", "key": "teststrip", "zone": "TEST", "vehicle": "car", "laps": 3,
            "guide": "docs/guides/teststrip.md",
            # No TEST profile exists in src/shared/LightingProfiles.luau; DINO-4's daylight reads well on grass.
            "lighting": "DINO-4",
            "route": rt,
            "deck": {"style": "dino_paver", "width": DECK_WIDTH, "zones": [], "curbHeights": [5.2, 4.4],
                     "gaps": [{"from": gap_from, "to": gap_to, "reason": "jump: crest lip over the water pool"}],
                     "piersEvery": 4, "pierFootingY": r4(GRASS_TOP - 8.0)},
            # lineOffset: the car's hull centre sits ~4.6 above the ribbon (paver top 2.7 + ride height 1.9).
            "flight": {"lineOffset": 4.5, "corridor": {"halfWidth": CORRIDOR_HALF_WIDTH, "floor": 1, "ceiling": 26}},
            "gameplay": {
                "checkpoints": {"stations": stations, "size": [48, 24, 6], "heightOffset": 8},
                "rings": [],
                "pads": [
                    {"name": "GroundBoost_MainStraight", "station": pad_main, "lateral": 0},
                    {"name": "GroundBoost_WestStraight", "station": pad_west, "lateral": 0},
                    {"name": "GroundBoost_BottomStraight", "station": pad_bottom, "lateral": 0},
                ],
                "pods": [
                    {"name": "PodRow_Red", "station": pods_st, "lateral": -10, "height": 4.5, "type": "Red"},
                    {"name": "PodRow_Blue", "station": pods_st, "lateral": 0, "height": 4.5, "type": "Blue"},
                    {"name": "PodRow_Speed", "station": pods_st, "lateral": 10, "height": 4.5, "type": "Speed"},
                ],
                "startGrid": {"station": 20, "height": 5, "rowSpacing": 22, "laneOffset": 11},
                "finish": {"station": 0, "radius": 40},
                "alternates": [],
                "key": None,
                "modes": {},
            },
            "shells": {"ops": shell_ops},
            "hazards": [],
            "meshes": [],
            "modelAttributes": [],
            "fx": [],
            "framing": {"heroStation": 30, "note": "chase camera on the main straight facing the sweeper"},
            "provenance": {
                "author": "tools/map/author_teststrip.py",
                "routeLength": round(length, 3),
                "routeFlexScale": round(route.flex_scale, 6),
                "minTurnRadius": round(min_r["r"], 1),
                "minTurnRadiusStation": min_r["st"],
                "jump": {"lip": gap_from, "deckEnd": deck_end, "deckResume": deck_resume,
                         "minLaunchSpeed": round(v_min, 1), "landingAt128": round(land_128, 1),
                         "landingAt165": round(land_165, 1)},
                "wallPieces": len(pieces),
            },
        },
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(plan, indent=1, sort_keys=False)
    OUT.write_text(text + "\n")
    print(f"wrote {OUT.relative_to(ROOT)} sha256={hashlib.sha256(text.encode()).hexdigest()[:12]}")
    print(f"route      {len(route.waypoints)} waypoints, length {length:.2f} (target {TARGET_LENGTH}, flexScale "
          f"{route.flex_scale:.4f}), min turn radius {min_r['r']:.1f} at st {min_r['st']}")
    print(f"jump       lip st {gap_from} deck ends {deck_end:.1f} resumes {deck_resume:.1f}; min launch speed "
          f"{v_min:.1f} studs/s (car top 128); lands st {land_128:.1f} at 128, {land_165:.1f} at 165")
    print(f"gameplay   checkpoints {len(stations)} {stations}")
    print(f"           pads {pad_main}, {pad_west}, {pad_bottom}; pods at {pods_st}; hairpin entry st {hairpin_st}")
    print(f"walls      {len(pieces)} pieces, {len([k for k in prefabs if k.startswith('Barrier_')])} length buckets")


if __name__ == "__main__":
    main()
