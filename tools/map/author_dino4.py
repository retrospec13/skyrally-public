#!/usr/bin/env python3
"""TRACK_PIPELINE P1 author script for DINO-4: map/dino4/extracted/* + the route nodes in builder_dino4.luau ->
map/dino4/plan.json (docs/MAP_PLAN_SCHEMA.md). Deterministic. Change the map here (or in the plan's art data), never in
generated Luau.

Conversions:
- art parts -> 30MAPS prefabs per unit (outermost Model; folder-level parts grouped per folder), part transforms in the
  unit's WorldPivot space, rotation as YXZ Euler degrees; cylinders inverted from the template's convention
  (Size=(sy,sx,sz), extra Rz(+90)); every part is round-tripped numerically and the script fails on a mismatch.
- terrain ops -> skyrally.shells.ops in call order; the per-segment cavern triplets (builder lines 633-635) collapse
  into one RouteCavern op so the walls follow the route instead of frozen coordinates.
- rings/pads/pods -> stations by projecting their built positions onto the route; placed ON the flight line
  (fixes the 16-48 stud drift from unscaled node coordinates); pods keep a clamped lateral offset.
- Route-derived parts (deck, curbs, fascia, piers) are excluded: kit/Deck regenerates them.
- Alt1/Alt2 parts are excluded from art: the adapter builds alternates by name (^Alt parts are safe flight surfaces).
"""
import hashlib
import json
import math
import re
import sys
from pathlib import Path

import numpy as np

if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
import item_rows  # noqa: E402  (item cubes v2 layout rules, tools/map/item_cubes.json)

ROOT = Path(__file__).resolve().parents[2]
EXT = ROOT / "map" / "dino4" / "extracted"
OUT = ROOT / "map" / "dino4" / "plan.json"
HEADER_LINES = None  # computed: offset between recorded line numbers and builder lines


# ---------- math ----------
def rot_from_components(c):
    return np.array([[c[3], c[4], c[5]], [c[6], c[7], c[8]], [c[9], c[10], c[11]]], float)


def euler_yxz(R):
    """Inverse of CFrame.fromEulerAnglesYXZ (R = Ry * Rx * Rz). Degrees."""
    sx = max(-1.0, min(1.0, -R[1][2]))
    rx = math.asin(sx)
    if abs(math.cos(rx)) > 1e-6:
        ry = math.atan2(R[0][2], R[2][2])
        rz = math.atan2(R[1][0], R[1][1])
    else:  # gimbal: fold rz into ry
        ry = math.atan2(-R[2][0], R[0][0])
        rz = 0.0
    return [math.degrees(rx), math.degrees(ry), math.degrees(rz)]


def mat_yxz(rx, ry, rz):
    rx, ry, rz = map(math.radians, (rx, ry, rz))
    cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    Rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return Ry @ Rx @ Rz


RZ90 = mat_yxz(0, 0, 90)


def r4(x):
    return round(float(x), 4)


# ---------- route (builder_dino4.luau generateWaypoints semantics) ----------
def parse_nodes():
    src = (ROOT / "builder_dino4.luau").read_text()
    block = src[src.index("local controlNodes"):src.index("local lowScale")]
    nodes = []
    for m in re.finditer(r"pos = Vector3\.new\(([-\d., ]+)\), bank = ([-\d.]+), flex = Vector3\.new\(([-\d., ]+)\)", block):
        nodes.append({"pos": [float(v) for v in m.group(1).split(",")], "bank": float(m.group(2)),
                      "flex": [float(v) for v in m.group(3).split(",")]})
    assert len(nodes) == 20, len(nodes)
    return nodes


def cr(p0, p1, p2, p3, t):
    t2, t3 = t * t, t * t * t
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)


def gen(nodes, scale, steps=9):
    c = len(nodes)
    adj = [np.array(n["pos"]) + np.array(n["flex"]) * scale for n in nodes]
    wps, L = [], 0.0
    for i in range(c):
        p0, p1, p2, p3 = adj[(i - 1) % c], adj[i], adj[(i + 1) % c], adj[(i + 2) % c]
        for s in range(steps):
            pt = cr(p0, p1, p2, p3, s / steps)
            if wps:
                L += float(np.linalg.norm(pt - wps[-1]))
            wps.append(pt)
    L += float(np.linalg.norm(wps[0] - wps[-1]))
    wps.append(wps[0].copy())
    return wps, L


def route(nodes, target=5450.0):
    lo, hi = 0.0, 3.5
    for _ in range(24):
        mid = (lo + hi) / 2
        w, L = gen(nodes, mid)
        if L < target:
            lo = mid
        else:
            hi = mid
    st = [0.0]
    for i in range(1, len(w)):
        st.append(st[-1] + float(np.linalg.norm(w[i] - w[i - 1])))
    return w, st, mid


def project(w, st, p):
    """Nearest point on the polyline: (station, lateral offset along horizontal right, height above line)."""
    p = np.array(p, float)
    best = None
    for i in range(len(w) - 1):
        a, b = w[i], w[i + 1]
        ab = b - a
        t = max(0.0, min(1.0, float(np.dot(p - a, ab) / max(1e-9, np.dot(ab, ab)))))
        q = a + ab * t
        d = float(np.linalg.norm(p - q))
        if best is None or d < best[0]:
            tan = ab / max(1e-9, np.linalg.norm(ab))
            right = np.cross(tan, [0, 1, 0])
            right = right / max(1e-9, np.linalg.norm(right))
            best = (d, st[i] + t * (st[i + 1] - st[i]), float(np.dot(p - q, right)), float(p[1] - q[1]))
    return best[1], best[2], best[3]


def frame_at(w, st, s_):
    """Position, unit tangent and horizontal right vector at station s_ (linear interpolation, like SplineUtils)."""
    L = st[-1]
    s_ = s_ % L
    for i in range(len(w) - 1):
        if st[i + 1] >= s_:
            t = (s_ - st[i]) / max(1e-9, st[i + 1] - st[i])
            pos = w[i] + (w[i + 1] - w[i]) * t
            tan = (w[i + 1] - w[i]) / max(1e-9, np.linalg.norm(w[i + 1] - w[i]))
            right = np.cross(tan, [0, 1, 0])
            right = right / max(1e-9, np.linalg.norm(right))
            return pos, tan, right
    return w[-1], np.array([0, 0, -1.0]), np.array([1.0, 0, 0])


def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def offset_path(w, st, s0, s1, lateral, height, ramp, step, min_offset=0.0):
    """Points of an alternate line: offset from the race line by `lateral` (right +) and `height`, eased in over `ramp`
    studs after s0 and out over `ramp` before s1, so both ends sit on the race line. Points closer than `min_offset`
    to the race line are dropped: the alternate's structure then starts as a mouth beside the course instead of walls
    standing on the race line (2026-10-18 capture: Alt1 walls at the join filled the screen)."""
    pts = []
    s_ = s0
    while s_ <= s1 + 1e-6:
        k = min(smooth((s_ - s0) / ramp), smooth((s1 - s_) / ramp))
        pos, _, right = frame_at(w, st, s_)
        q = pos + right * lateral * k + np.array([0, height * k, 0])
        if abs(lateral * k) >= min_offset:
            pts.append([round(float(v), 3) for v in q])
        s_ += step
    return pts


# ---------- battle overlay ----------
# LAUNCH_PROGRESSION 2b / TEST_LIST_LAUNCH L71: the DINO-BATTLE egg battle (plane vs three bots) is a mode overlay on the
# cavern floor of the lower basin in the great hall, around the altar deck (LowerBasinVolcanicAltar: the legacy
# builder's "sauropod floor", flanked by BoosterRing_2_SauropodLeft / BoosterRing_3_SauropodRight and
# GroundBoost_SauropodFloor). The hall is open air from the lava floor (Y 16) to its roof (Y 244) for 300 studs round
# the altar (west wall at X -880, south wall at Z -1650); the race line and the Alt2 ledge stay 360+ studs away, so
# nothing the race uses moves. The altar tiers (Y 14..48) are the only collidable parts inside the boundary.
EGG_CENTRE = (-580.0, -1340.0)  # altar pivot (x, z)
EGG_FLOOR = 16.0  # lava floor and basalt slabs of the great hall
EGG_ALTAR_TOP = 48.0  # top of the altar's upper tier (150 x 150)
# Trap audit fixes (docs/audits/traps_dino4.md, 2026-10-18):
# D4-01: every objective sits well inside the 270 return line, so the run-out after a nest, a steal or an outer pod is at
#   least one boosted turn radius (145) long instead of the 60-100 studs the old r170 nests / r208 pods / r215 spawns left.
# D4-07: the nest rings float above the altar (ring bottom 54 > altar top 48), so the low inward pass through a nest
#   (eggs sit in the ring's bottom bowl) no longer meets the tier-2 face head-on 95 studs later.
EGG_NEST_R = 125.0  # on the axes, outside tier 1 (half 110), so each nest still stands on the hall floor
EGG_NEST_Y = EGG_ALTAR_TOP + 22  # ring 54..86
EGG_POD_R = (120.0, 160.0)  # inner and outer item pod rings
# Pods keep their old height over the nests (+8 inner, +4 outer): the bots fly no lower than the nests + 6
# (modes/Egg AIM_OVER_NEST), so pods left at the old Y 54-58 would sit under every bot and never be taken.
EGG_POD_Y = (EGG_NEST_Y + 8, EGG_NEST_Y + 4)
EGG_SPAWN_R = 185.0


def egg_battle():
    """modes.battle for the egg mode (server/battle/modes/Egg): soft-bounded arena, four spawn pads, four nest rings
    standing on the floor at the sides of the altar (one per seat, ring axis toward the centre), the centre nest on the
    altar top under its crown arch (axis along the arch opening, yaw 35), and eight item pod anchors between the nests.
    `ground` is the solid top under each nest (the mode stands the nest on it)."""
    cx, cz = EGG_CENTRE

    def at(angle, r, y):
        a = math.radians(angle)
        return [round(cx + math.cos(a) * r, 2), round(y, 2), round(cz + math.sin(a) * r, 2)]

    def yaw_to_centre(p):
        # CFrame.Angles(0, yaw, 0).LookVector = (-sin yaw, 0, -cos yaw): the ring axis from p toward the centre
        return round(math.degrees(math.atan2(p[0] - cx, p[2] - cz)), 2)

    sides = (0, 90, 180, 270)
    nests = []
    for i, a in enumerate(sides, 1):
        pos = at(a, EGG_NEST_R, EGG_NEST_Y)
        nests.append({"name": f"Nest_{i}", "pos": pos, "radius": 16, "yaw": yaw_to_centre(pos), "ground": EGG_FLOOR})
    centre = [cx, EGG_FLOOR + 60, cz]
    return {
        "kind": "egg", "mode": "DINO-BATTLE", "vehicle": "plane",
        "venue": "lower-basin cavern floor round the altar deck (legacy sauropod floor), great hall",
        "center": centre,
        "radius": 230,
        "boundary": {"shape": "cylinder", "soft": True, "center": [cx, EGG_FLOOR, cz], "radius": 240, "softWidth": 30,
                     "floor": EGG_FLOOR - 6, "ceiling": 232},
        "centerNest": {"name": "CentreNest", "pos": centre, "radius": 14, "yaw": 35, "ground": EGG_ALTAR_TOP},
        "nests": nests,
        # beside each nest (25 degrees on), so the first run at the centre egg does not cross the seat's own ring
        "spawns": [at(a + 25, EGG_SPAWN_R, EGG_FLOOR + 50) for a in sides],
        "pickupAnchors": [at(a, EGG_POD_R[0], EGG_POD_Y[0]) for a in (45, 135, 225, 315)]
        + [at(a, EGG_POD_R[1], EGG_POD_Y[1]) for a in (45, 135, 225, 315)],
        "rules": {"bots": 3, "eggsToWin": 3, "hatchSeconds": 10, "eggRespawnSeconds": 3, "carryMax": 1,
                  "items": "race level-one set", "levelOneOnly": True, "timeCapSeconds": 180},
    }


# ---------- race trap fixes (docs/audits/traps_dino4.md, 2026-10-18) ----------
# D4-06 / D4-02: ring stations that override the projection of the built ring. A boost holds 165 studs/s for 1.8 s at a
# 65 deg/s yaw cap (a ~145-stud turn radius), so a ring must not fire into a bend tighter than that (X-07 lint,
# tools/map/tests/test_boost_windows.py).
# - Start_1 / Start_2 sat inside the start S-curve (R 45-77, first 5 s of every race): moved down the start straight
#   after Start_3, so the S is a clean swoop under the foreground arch and the three rings are a triple boost after it.
# - 5_Final sat in the 5190-5230 bend (R 89-95) and boosted straight into the final bend (R 85-95, the course minimum):
#   with the respawn 300 studs back at cp14 that was a crash loop. Moved to the great-hall straight, where its window
#   (3900-4257) never drops under R 250. The name is kept (stable ids for the lint, probes and audits).
RING_STATIONS = {"BoosterRing_Start_1": 340.0, "BoosterRing_Start_2": 400.0, "BoosterRing_5_Final": 3900.0}
# D4-02: a checkpoint between the last two bends, so a crash in the final bend respawns 40 studs before it (the 1.6 s
# respawn invulnerability, ~176 studs, covers the whole bend) instead of 300 studs back.
EXTRA_CHECKPOINTS = [5290]
# D4-02: widen the outer (east) wall at the final bend's exit, where late planes ran wide (sim crash points
# (59-81, 149, 48-52)). Clear of StoneArchway_S5350 (>= 9 studs) and of the StartFinishGate pillars (>= 3 studs).
FINAL_BEND_WIDEN = {"op": "FillBall", "center": [66, 152, 50], "r": 38, "mat": "Air"}
# D4-10: the invisible lethal StartLavaBed (top Y 77) only matches the visible floor inside the start chamber. South of
# z -330 the route tube and floor fill sit 10-30 studs lower, and west of x -110 it hung over the route's lava shelf
# (st 4500-4750) and a hole down to the hall's lava sea (Y 14) 60 studs below. Clip it to the chamber.
START_LAVA_BED_BOUNDS = {"x": (-110.0, 110.0), "z": (-330.0, 70.0)}
# DINO-4's terrain tints as published. The e7a623e low-graphics cap (assets/materials/dino_v1/tiles/tints.json, 1.15x the
# texture mean) re-derived every other map's tints at adapt time but never reached this plan, which bakes its colours in.
# Pinned so that rerunning this script reproduces the published plan; adopting the cap is a separate look change for
# DINO-4 (needs a low-graphics capture), done by replacing this dict with the tints.json lookup.
# L61 grade pass: strata a deeper, less saturated terracotta (r0: "over-orange, one value band"), the crown rock a cool
# plum instead of near-black clumps, basalt crust darker so the lava cracks between it read hotter.
ROCK_PREFABS = ("MidTrackRockPillar", "VolcanoCaldera_Loose", "DressHallSpire")
HALL_PILLAR_CLEAR = 150.0  # basalt hall-edge pillars stay this far (3D) from the main line and both alternates (tube radius max 112)
# dino-cave (v22): the Sandstone terrain is the cavern mass (FillRouteBounds) that CarveRouteTube's FillBall chain cuts
# into the curved tube walls; Basalt is the crust islands in the lava floor and the hall pillars. #3e3134 times the
# neutral detail map rendered as black voids in the cave light, so the crust is lifted to a dark warm grey-brown (still
# the darkest terrain, under the Rock ceiling and the Sandstone walls).
# Visual critic v28 1.13: Rock (the upper walls and ceiling above the value break) from plum #6a5262 to a cool slate violet
# so the break reads as warm lit stone below, cool shadowed rock above.
# Wave 1b C7 (critic v29): the upper shell Rock tint (116,108,134) read violet; dusk slate (96,92,118) instead.
TERRAIN_COLORS = {"Sandstone": "#c98a64", "Rock": "#605c76", "Basalt": "#7a6762", "CrackedLava": "#ff862e"}
# D4-04: the coin challenge (LAUNCH_PROGRESSION 3: all eight coins AND first place; at least one coin on an alternate).
# Main-line coins sit 11-16 studs off the assisted line (line +14) so taking one is a choice, never inside a boost ring,
# with >= 40 studs of terrain clearance (voxel rebuild); none inside the Alt1 span (130-1420), so one lap through the
# tunnel can take all eight. The plane pickup radius is 13 at a 10 Hz server sweep: a pass within ~10 studs of the
# centre always counts at boost speed.
COINS = [  # (station, lateral, height above the route, note)
    (1520, 0, 28, "crest hop: pull up over the GroundBoost_Crest pad's boost"),
    (1960, 0, 2, "dip through the hairpin lava gap (no deck 1880-2040), 39 studs above the kill plane"),
    (2150, -10, 20, "inside line out of the hairpin"),
    (2700, -12, 18, "main line beside the Alt2 ledge"),
    (3600, 13, 22, "wide bank over the open great hall"),
    (4250, 14, 20, "hall exit straight, before BoosterRing_4_Penultimate"),
    (5120, -8, 22, "inside line into the last two bends"),
]
# The alternate coin: the middle of the Alt1 tunnel's enclosed stretch (flight line = its points + 14, floor at +1.8,
# walls at +-13, roof at +28), so anyone who enters the tunnel takes it, even grinding a wall.
# Geyser vents: (0-based Alt1 point, phase seconds). Points 9 and 21 sit mid-tunnel, ~290 studs from the coin point.
UPDRAFT_VENTS = [(9, 0.0), (21, 2.0)]
ALT1_FLOOR = 1.8  # Alt1Floor top above the point (the flight line is +14)
ALT1_COIN_POINT = 4  # 0-based index into the Alt1 points (pt5, station ~382)


def coin_anchor(w, st, s_, lateral, height):
    """Station anchor exactly as the adapter places it (tools/map/route.py Frame.offset: horizontal right, up =
    right x tangent)."""
    pos, tan, right = frame_at(w, st, s_)
    up = np.cross(right, tan)
    up = up / max(1e-9, np.linalg.norm(up))
    return pos + right * lateral + up * height


# ---------- L61 art pass: palette, set dressing, ambient fx (evidence/L61/critic_dino4_r*.md) ----------
# Critic r0 (5/10): one orange value band, no cool counterlight, bare repeated walls, few landmarks, lava not alive.
# Ancient stone reads grey-brown against the orange strata (guide 04_dino4_controls.png arches), not the same orange.
STONE_RECOLOR = {"#e4b680": "#b9a690", "#ce9866": "#9c8772", "#b26842": "#78604f", "#8e4e34": "#5d4940"}
STONE_UNITS = re.compile(r"^(StoneArchway_|StartForegroundArch|FTUEFinishArch|StartFinishGate|MidTrackRockPillar|"
                         r"DualLevelTunnelPortal|LowerBasinVolcanicAltar|SauropodTieredPedestal|VolcanoCaldera_Loose)")
# The legacy cliff shrubs stood 118 studs out, inside the new tube walls, and showed as floating green boxes where the
# tube widens; dropped (their 220 parts go to the dressing below).
# Visual critic v28 1.12: the legacy FTUEFinishArch stood astride the start straight at st ~280 (right pier 6 studs off the
# deck centre, crown 0-15 studs over the flight line), so the chase camera rode through its crown and the runtime arch
# mesh filled the opening shot with two untextured planes and a dark pier slab. Non-colliding art, no gameplay role (the
# finish is StartFinishGate), so it is dropped; StartForegroundArch and the MidTrackRockPillar arch still frame the start.
DROPPED_UNITS = re.compile(r"/CliffShrub[LR]_\d+$|^Landmarks/FTUEFinishArch$")
FLOOR_H = -37.0  # lava floor below the deck (in-game probe: CrackedLava/Basalt crust at -31..-38 along the tube)
ALT_SIDES = [(130, 1420, 1), (2380, 3240, -1)]  # (from, to, side) of each alternate: keep that side clear
BONE, BONE_SHADE, SOCKET, TOOTH = "#d9bd8f", "#ab8b62", "#1c1214", "#efdcb4"  # aged bone, never pure white
BASALT = ("#5c4a50", "#69545a", "#76606a")
MAGMA = "#ff5a16"


def fx_texture(name):
    """rbxassetid of an owned particle texture (src/shared/VfxAssets.luau or the flip_v2 set in VfxFlipAssets.luau)."""
    src = (ROOT / "src" / "shared" / "VfxAssets.luau").read_text()
    m = re.search(name + r' = \{ id = "(rbxassetid://\d+)"', src)
    if not m:
        m = re.search(name + r' = "(rbxassetid://\d+)"', (ROOT / "src" / "shared" / "VfxFlipAssets.luau").read_text())
    assert m, name
    return m.group(1)


def lava_texture():
    """The lava flow map already uploaded for SR_DINO_Lava (assets/materials/dino_v1/tiles/uploaded.json)."""
    up = json.loads((ROOT / "assets" / "materials" / "dino_v1" / "tiles" / "uploaded.json").read_text())
    return f"rbxassetid://{up['T4_LAVA_FLOW_color']['id']}"


def part(shape, x, y, z, sx, sy, sz, rx=0.0, ry=0.0, rz=0.0, col="#ffffff", mat="SmoothPlastic", nc=False, light=None,
         alpha=0.0, n=None):
    p = [shape, r4(x), r4(y), r4(z), r4(sx), r4(sy), r4(sz), r4(rx), r4(ry), r4(rz), col, mat]
    extra = {}
    if n:
        extra["n"] = n  # cone sides (shape "K")
    if alpha:
        extra["a"] = r4(alpha)
    if nc:
        extra["nc"] = 1
    if light:
        extra["l"] = light
    if extra:
        p.append(extra)
    return p


def basalt_cluster(cols):
    """Basalt organ pipes standing in the lava (local origin on the lava floor), each seated in a broken rock collar with
    a thin ember rim where it meets the lava. Visual critic v28 1.20 / 1.16: the straight Neon seams up the columns and
    the 30-stud Neon disc under the cluster (an ART_BAR "straight neon strip" and "neon sheet") are gone; the glow is
    the rim plus one PointLight. Collars and rims never collide (the columns keep their own collision)."""
    parts = []
    for i, (dx, dz, d, h, tilt) in enumerate(cols):
        parts.append(part("C", dx, h / 2 - 5, dz, d, h, d, tilt, 0, tilt * 0.5, BASALT[i % 3], "Basalt"))
        # collar: a squat drum and a tilted half-drum, so it reads as heaped rock rather than a washer
        parts.append(part("C", dx, 1.6, dz, d * 1.42, 4.2, d * 1.42, 0, i * 23, 0, BASALT[(i + 1) % 3], "Basalt", nc=True))
        parts.append(part("C", dx + d * 0.18, 3.6, dz - d * 0.12, d * 1.12, 2.8, d * 1.12, 6, i * 41, -5, BASALT[(i + 2) % 3],
                          "Basalt", nc=True))
        parts.append(part("C", dx, 0.15, dz, d * 1.56, 0.5, d * 1.56, col="#ff7a24", mat="Neon", nc=True,
                          light=[16, 1.4, "#ff6a1e", False] if i == 0 else None))
    return {"parts": parts}


BASALT_VARIANTS = {
    "DressBasaltOrganA": [(0, 0, 12, 74, 0), (9, 5, 10, 54, 4), (-7, 7, 9, 40, -5), (3, -9, 8, 28, 6)],
    "DressBasaltOrganB": [(0, 0, 14, 92, 3), (10, -4, 9, 62, -4), (-9, -3, 10, 46, 5)],
    "DressBasaltOrganC": [(0, 0, 11, 40, 8), (8, 6, 9, 28, -6), (-6, 5, 8, 20, 0), (2, -8, 7, 13, 10)],
}
RIB_R = 64.0  # inner bone face at >= 59 studs from the deck centre clears the corridor's top corner (34, 44) = 55.6


RIB_TIP_ANGLE = -16.0  # degrees: the rib tips curl down past the deck (y < 0) and stop well above the lava
FOSSIL_CAMERA_FADE = 30  # Wave 1b C2: studs; ribs hidden inside 15, drawn again at 30 (shared/CameraNearFadeRules)
RIB_BONE = "#d8c3a0"  # Wave 1b C2: opaque bone (critic v29)
BONE_TIP = "#bf9d70"  # the rib darkens from the spine toward its tip (one gradient, no alternating stripe)


def fossil_rib(scale=1.0):
    """One giant rib pair arching over the route (local X lateral, Y up, origin on the deck centre line). Visual critic
    v28 1.20 ("bone variant with tapered tips"): each side leaves the spine at the crown and curves down an arc of radius
    RIB_R in seven chords that thin from 7.5 to 2.6 studs, ending in a six-sided cone tip that points down the curve,
    instead of the old even-width chords in alternating colours standing on posts in the lava. The inner face stays at
    >= RIB_R - 3.75 = 60.25 studs from the deck centre (clear of the corridor's top corner, 55.6)."""
    parts, n = [], 7
    a_top, a_end = math.radians(86.0), math.radians(RIB_TIP_ANGLE)
    # Wave 1b C2 (critic v29: "translucent ribs"): opaque bone #d8c3a0 in Sandstone (no variant, partRules) instead of
    # SmoothPlastic, which read glassy under the cave's cool top light; the camera-near fade (client/CameraNearFade,
    # modelAttributes on Dressing/Fossils) thins a rib only while the chase camera passes through the gate.
    cols = [RIB_BONE, RIB_BONE, "#d2b98f", "#cbb085", "#c4a77c", "#bd9f73", BONE_TIP]

    def rz_of(dx, dy):  # Z rotation that turns local +Y onto (dx, dy)
        return math.degrees(math.atan2(-dx, dy))

    for s in (-1, 1):
        for k in range(n):
            a0 = a_top + (a_end - a_top) * k / n
            a1 = a_top + (a_end - a_top) * (k + 1) / n
            am = (a0 + a1) / 2
            chord = 2 * RIB_R * math.sin(abs(a1 - a0) / 2) * 1.08
            t = (7.5 - 4.9 * k / (n - 1)) * scale
            x, y = s * RIB_R * math.cos(am), RIB_R * math.sin(am)
            parts.append(part("B", x, y, 0, t, chord, t * 0.82, 0, 0, rz_of(-s * math.sin(am), math.cos(am)), cols[k],
                              "Sandstone", nc=True))
        # cone tip continuing the curve downward from the last chord
        dx, dy = s * math.sin(a_end), -math.cos(a_end)
        ex, ey = s * RIB_R * math.cos(a_end), RIB_R * math.sin(a_end)
        tip = 9.0 * scale
        parts.append(part("K", ex + dx * tip / 2, ey + dy * tip / 2, 0, 2.8 * scale, tip, 2.4 * scale, 0, 0, rz_of(dx, dy),
                          BONE_TIP, "Sandstone", nc=True, n=6))
    return {"parts": parts}


def fossil_spine(n):
    """Vertebrae along the crown of a rib gate (local -Z along the route), above the ribs: a centrum bar, one block
    body per vertebra and a tapered dorsal spine (four-sided cone) leaning back along the route."""
    parts = [part("B", 0, RIB_R + 3, -(n - 1) * 7, 6, 5, (n - 1) * 14 + 12, col=BONE_SHADE, mat="Sandstone", nc=True)]
    for k in range(n):
        parts.append(part("B", 0, RIB_R + 7, -k * 14, 10, 6, 8, col=RIB_BONE, mat="Sandstone", nc=True))
        parts.append(part("K", 0, RIB_R + 14.5, -k * 14 + 1.5, 4, 10, 6, -18, 0, 0, "#d2b486", "Sandstone", nc=True, n=4))
    return {"parts": parts}


SKULL_BONE, SKULL_SHADE = "#d2b486", "#a88c66"  # Wave 1b C6 (critic v29): aged bone and its shade, Sandstone


def fossil_skull():
    """A giant fossil skull lying in the lava with its jaws open round a boost ring (local +Z faces the oncoming
    planes, origin on the deck centre line). Every part is outside the flight corridor (|x| > 34 or y > 44 or y < 5)
    and non-colliding. Read from the chase camera: the snout's underside with its fangs, long canines either side of
    the ring, and two dim ember cores in dark sockets on the cranium above the snout.
    Wave 1b C6 (critic v29, "cartoon skull gate"): bone #d2b486 / #a88c66 in Sandstone (no variant, partRules), the
    eyebrow blocks gone, eight tapered four-sided fangs instead of the 45-degree diamond teeth, the sockets set flat
    into the cranium with a dim ember core (Neon at 0.55 transparency) and an orange PointLight (Range 30), and a broken
    jaw half sunk in the lava beside the gate. Block rework now; the Tripo skull is Wave 2."""
    p = []
    p.append(part("S", 0, 92, -26, 104, 70, 80, col=SKULL_BONE, mat="Sandstone"))  # cranium (y 57..127, front at z 14)
    p.append(part("B", 0, 58, 8, 94, 12, 44, col=SKULL_SHADE, mat="Sandstone"))  # snout / upper jaw (y 52..64, z -14..30)
    p.append(part("W", 0, 70, 6, 30, 12, 34, col=SKULL_BONE, mat="Sandstone"))  # nasal ridge rising into the cranium
    p.append(part("B", 0, 58, 31, 62, 10, 6, col=SKULL_BONE, mat="Sandstone"))  # snout tip
    for s in (-1, 1):
        # socket: a shallow dark oval only just proud of the cranium (its surface is ~8 studs forward here), so it reads
        # set in rather than stuck on; the ember core sits in its face, dim, with the light doing the glow
        p.append(part("S", s * 26, 88, 5.5, 24, 20, 6, col=SOCKET, mat="Basalt"))
        p.append(part("S", s * 26, 87, 8.2, 7, 7, 2, col="#c8541c", mat="Neon", alpha=0.55,
                      light=[30, 1.6, "#ff7a2a", False]))
        p.append(part("B", s * 10, 64.5, 24, 8, 3, 6, col=SOCKET, mat="Basalt"))  # nostril
        p.append(part("B", s * 52, 62, -10, 10, 16, 48, col=SKULL_BONE, mat="Sandstone"))  # cheekbone (|x| >= 47)
        p.append(part("B", s * 52, 30, -28, 10, 56, 12, col=SKULL_SHADE, mat="Sandstone"))  # jaw hinge strut
        p.append(part("B", s * 49, -1, 2, 6, 10, 64, col=SKULL_SHADE, mat="Sandstone"))  # lower jaw bar (top y 4)
        # fangs: tapered four-sided cones, tips down from the upper jaw and up from the lower
        p.append(part("K", s * 45, 44, 26, 5.5, 18, 5.5, 0, 0, 180, TOOTH, "Sandstone", n=4))  # upper canine (y 35..53)
        p.append(part("K", s * 47, 11, 24, 5, 14, 5, col=TOOTH, mat="Sandstone", n=4))  # lower canine (y 4..18)
        p.append(part("K", s * 44, 48, 8, 4, 8, 4, 0, 0, 180, TOOTH, "Sandstone", n=4))  # upper side fang (y 44..52)
        p.append(part("K", s * 16, 48.5, 29, 4, 7, 4, 0, 0, 180, TOOTH, "Sandstone", n=4))  # front fang (y 45..52)
    p.append(part("B", 0, -12, 30, 104, 8, 8, col=SKULL_SHADE, mat="Sandstone"))  # chin under the deck
    for k, (z, y) in enumerate(((-76, 84), (-102, 78), (-126, 72))):  # neck vertebrae behind the cranium
        p.append(part("S", 0, y, z, 30, 26, 24, col=SKULL_BONE if k % 2 == 0 else SKULL_SHADE, mat="Sandstone"))
    # the broken-off lower jaw, half sunk in the lava off the right of the gate (lava floor FLOOR_H, 37 under the deck)
    p.append(part("B", 72, FLOOR_H + 1.5, -18, 8, 7, 56, 6, 28, 9, SKULL_SHADE, "Sandstone"))
    p.append(part("K", 66, FLOOR_H + 6, 4, 4, 9, 4, -12, 0, 8, TOOTH, "Sandstone", n=4))
    p.append(part("K", 70, FLOOR_H + 5.5, -6, 3.5, 8, 3.5, 10, 0, -6, TOOTH, "Sandstone", n=4))
    for q in p:
        if len(q) == 12:
            q.append({"nc": 1})
        else:
            q[12]["nc"] = 1
    return {"parts": p}


def spire():
    """The hall sauropod's lava spire: stepped basalt drums with an ember rim at the lava and a carved stone cap (local
    origin on the hall's lava floor, top at y 60)."""
    p = [part("C", 0, 6, 0, 56, 16, 56, 0, 0, 0, BASALT[0], "Basalt"),
         part("C", 0, 22, 0, 46, 20, 46, 0, 0, 0, BASALT[1], "Basalt"),
         part("C", 0, 40, 0, 40, 18, 40, 0, 0, 0, BASALT[2], "Basalt"),
         part("B", 0, 55, 0, 44, 10, 30, col="#a8937d", mat="Sandstone"),
         part("B", 0, 55, 0, 30, 10, 44, col="#b9a690", mat="Sandstone"),
         # visual critic v28 1.16/1.20: an ember rim at the lava line and a heaped rock collar replace the 70-stud Neon
         # disc and the six straight Neon seams up the drums
         part("C", 0, 0.3, 0, 60, 0.6, 60, col="#ff7a24", mat="Neon", nc=True, light=[30, 1.6, "#ff6a1e", False]),
         part("C", 8, 15, -6, 50, 5, 50, 4, 17, -3, BASALT[2], "Basalt", nc=True)]
    return {"parts": p}


OCULUS_DROP = 6.0  # Wave 1b C5: the oculus disc hangs this far under the roof plane (clear of the 4-stud voxel band)
HALL_CEILING = 245.0  # the great hall's flat roof (shell op: Air FillBlock y 15..245) over the monument


def hall_oculus():
    """Visual critic v28 1.15: a cool oculus over the hall monument. The roof stays sealed terrain; under it hangs a
    pale-blue sky disc (the guide's oculus read, 04_dino4_controls.png) in a ring of broken rock voussoirs. Local origin
    on the roof plane over the monument; every part is non-colliding and 165+ studs above the hall's lava."""
    # Wave 1b C5 (critic v29: the oculus never showed in V12). The disc sat at roof - 0.6 with a 1-stud thickness, inside
    # the 4-stud voxel band where the Air FillBlock's top (245) leaves a partly filled, smoothed roof surface, so the
    # terrain covered it. It now hangs OCULUS_DROP under the roof plane (still 160+ over the hall floor), wider, with
    # the voussoir ring dropped with it so the ring frames the disc from the route below.
    d = OCULUS_DROP
    p = [part("C", 0, -d - 0.6, 0, 76, 1.0, 76, col="#d6ecff", mat="Neon", nc=True, alpha=0.08)]
    for k in range(12):
        a = 2 * math.pi * k / 12
        r = 44 + (k % 3) * 1.5
        h = 9 + (k * 5) % 4
        p.append(part("B", math.cos(a) * r, -d - h / 2 + 3.5, math.sin(a) * r, 15, h + 6, 11 + (k % 2) * 3,
                      (k % 3 - 1) * 6, -math.degrees(a) + 90, 0, "#6f6880" if k % 2 else "#7d7590", "Rock", nc=True))
    return {"parts": p}


HALL_STATUE_AT = (1150.0, -150.0)  # (station, lateral): ahead-left of the first great-hall pass, over BoosterRing_3
HALL_FLOOR = 16.0  # the hall's lava floor (EGG_FLOOR)
HALL_STATUE_HEIGHT = 140.0


def bone_pile():
    """Fossil bones and a small skull stranded on the lava crust (local origin on the lava floor)."""
    return {"parts": [part("B", 0, 2, 0, 3, 3, 24, 0, 20, 8, BONE, nc=True),
                      part("B", 5, 4, 3, 2.5, 14, 2.5, 0, 0, 28, BONE_SHADE, nc=True),
                      part("B", -4, 4, -2, 2.5, 13, 2.5, 0, 40, -24, BONE, nc=True),
                      part("S", -6, 3.5, 7, 8, 7, 10, col=BONE, nc=True),
                      part("S", -7.5, 4.5, 10.5, 2.4, 2.4, 1.2, col=SOCKET, nc=True)]}


def lava_lip():
    """The rock lip a lavafall pours from (local origin at the lip, X along the wall, Z out of the wall)."""
    # Wave 1b C7 (critic v29, "neon spire caps"): the lip's Neon pour block over the thin beam read as a glowing cap on
    # a spire; it is a CrackedLava spout in a Basalt cap now, and the stream below is wider (8-10), a lavafall again.
    return {"parts": [part("B", 0, 0, 0, 26, 9, 16, 0, 0, 3, BASALT[1], "Basalt", nc=True),
                      part("B", 0, 3.2, 1, 24, 3, 14, 0, 0, -2, BASALT[0], "Basalt", nc=True),
                      part("B", 0, -3.5, 6, 12, 3, 6, col="#d0682a", mat="CrackedLava", nc=True)]}


def lava_pool():
    """The splash pool a lavafall lands in (local origin on the lava floor): a bright lava disc ringed by low basalt
    crust stones, all non-colliding (critic v28 1.14: "a narrow scrolling lavafall with a splash pool")."""
    p = [part("C", 0, 0.2, 0, 22, 1.0, 22, col="#ff9a3c", mat="CrackedLava", nc=True)]
    for k in range(7):
        a = 2 * math.pi * k / 7
        r = 12.5 + (k % 2) * 1.5
        p.append(part("B", math.cos(a) * r, 0.6, math.sin(a) * r, 6 + (k % 3), 2.4, 4 + (k % 2) * 2, 0, k * 37, (k % 3 - 1) * 8,
                      BASALT[k % 3], "Basalt", nc=True))
    return {"parts": p}


# Critic v28 Wave 1 dressing constants (PropLibrary sizes from src/shared/PropLibrary.luau)
PROP_FLOOR_H = -39.0  # prop bases sit 2 studs into the lava crust so they read half sunk
TOTEM_HEIGHT = 20.0  # dino_stone_totem bounding box 7.87 x 20 x 6.85, face along +X
TOTEM_SCALE = 2.6  # 52 studs tall, 17.8 deep across the line: inner face at 46 - 8.9 = 37.1 > corridor half width 34
TOTEM_LATERAL = 46.0
RUIN_COLUMN_SCALE = 2.3  # dino_broken_column 16.66 x 22 x 10.33 -> 38 x 51 x 24
RUIN_ARCH_SCALE = 2.2  # dino_ruined_arch 10.85 x 27.98 x 17.86 -> 24 x 62 x 39
RIBCAGE_SCALE = 1.8  # dino_ribcage_bones 21.1 x 19.22 x 32.01 -> 38 x 35 x 58, top 7 under the deck
RIBCAGE_LATERAL = 66.0
DECK_GLOW_FROM, DECK_GLOW_TO, DECK_GLOW_EVERY = 460.0, 5330.0, 80.0
DECK_GLOW_LATERAL, DECK_GLOW_DROP = 19.0, -5.0  # just outside the 32-wide deck's edge, under its top
SKULL_STATION = 3900.0  # BoosterRing_5_Final, on the great-hall straight
RIB_GATES = [1955.0, 3500.0, 4720.0, 5100.0]  # first rib station; four ribs 14 studs apart
LAVAFALLS = [(1850, 1, 85), (2150, -1, 90), (2600, 1, 86), (3050, 1, 82), (3350, -1, 88), (4600, -1, 79),
             (4950, 1, 82), (5150, -1, 87)]  # (station, side, wall distance at line height from the in-game probe)
GEYSERS = [(1148.2, -1), (1834.9, 1), (2284.3, -1), (4520.1, 1)]  # beside boost rings
KEEP_CLEAR = [1050, 2100, 3150, 4350, 5350, SKULL_STATION] + [s + 21 for s in RIB_GATES]  # arches, skull, gates


# Wave 1b C4 (critic v29 dino4_03, V12 Studio miss 5): the yellow Neon ceiling strip down the Alt1 tunnel. Wave 1 changed
# only the Alt1 walls and portal (plan partRules) and never saw the strip, because it is not plan art: kit/Deck builds it
# at runtime for every "tunnel" alternate (Alt1TorchStrip_<i>, Neon, style.torchAmber, under the roof). The plan now
# turns those parts into a dark Basalt recess course (partRules, so SPACE-4's tunnel strip is untouched) and hangs a few
# staggered dim ember slivers in that recess with a warm PointLight every ALT1_EMBER_EVERY studs of the Alt1 line.
ALT1_EMBER_EVERY = 60.0
ALT1_EMBER_Y = 26.6  # sliver centre above the alternate point (roof underside at +28, the strip at +27.1..27.9)
ALT1_LAMP_Y = 22.0  # PointLight above the point (flight line at +14)


def alt1_ember():
    """Three staggered ember slivers (<= 1 stud across, Neon at 0.3) under a thin basalt plate; local -Z along the
    tunnel, origin at the recess. Non-colliding."""
    return {"parts": [part("B", 0, 0.55, 0, 3.4, 0.5, 15, col="#3a2e30", mat="Basalt", nc=True),
                      part("B", -1.1, 0, -5, 0.8, 0.6, 4.5, 0, 6, 0, "#ff7a24", "Neon", nc=True, alpha=0.3),
                      part("B", 1.0, 0, 0.5, 0.7, 0.6, 3.5, 0, -8, 0, "#ff7a24", "Neon", nc=True, alpha=0.3),
                      part("B", -0.4, 0, 5.5, 0.8, 0.6, 4, 0, 4, 0, "#ff7a24", "Neon", nc=True, alpha=0.3)]}


def alt1_embers(points):
    """Instances and lights along the Alt1 tunnel: one ember group every ALT1_EMBER_EVERY studs of the polyline, laid in
    the segment's own frame (kit/Deck builds the roof on CFrame.lookAt(mid, b) of each segment)."""
    pts = [np.array(q, float) for q in points]
    lens = [float(np.linalg.norm(pts[i + 1] - pts[i])) for i in range(len(pts) - 1)]
    total = sum(lens)
    inst, lights = [], []
    d = ALT1_EMBER_EVERY / 2
    k = 0
    while d < total - ALT1_EMBER_EVERY / 4:
        i, acc = 0, 0.0
        while acc + lens[i] < d:
            acc += lens[i]
            i += 1
        a, b = pts[i], pts[i + 1]
        look = (b - a) / lens[i]
        z = -look
        x = np.cross(np.array([0.0, 1.0, 0.0]), z)
        x /= np.linalg.norm(x)
        y = np.cross(z, x)
        R = np.array([[x[0], y[0], z[0]], [x[1], y[1], z[1]], [x[2], y[2], z[2]]])
        base = a + look * (d - acc)
        q = base + y * ALT1_EMBER_Y
        inst.append({"pf": "DressAlt1Ember", "p": [r4(v) for v in q], "group": "Dressing/Alt1Embers",
                     "r": [r4(v) for v in euler_yxz(R)], "s": 1})
        lamp = base + y * ALT1_LAMP_Y
        lights.append({"class": "PointLight", "name": f"Alt1Ember_{k + 1}", "group": "Dressing/Alt1Embers",
                       "cf": [r4(lamp[0]), r4(lamp[1]), r4(lamp[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1],
                       "props": {"Brightness": 1.2, "Range": 24, "Color": "#ff8a3a", "Shadows": False}})
        k += 1
        d += ALT1_EMBER_EVERY
    return inst, lights


def side_free(s_, side):
    return not any(a - 60 <= s_ <= b + 60 and side == sd for a, b, sd in ALT_SIDES)


def dressing(w, st):
    """Prefabs, instances (group name instead of index), fx and PropLibrary set dressing of the L61 dressing (visual
    critic v28 Wave 1 pass), all placed from route frames."""
    prefabs, inst, fx, props = {}, [], [], []

    def place(pf, s_, lat, h, group, yaw_extra=0.0):
        pos, tan, right = frame_at(w, st, s_)
        q = pos + right * lat + np.array([0.0, h, 0.0])
        yaw = math.degrees(math.atan2(-tan[0], -tan[2])) + yaw_extra
        inst.append({"pf": pf, "p": [r4(v) for v in q], "group": group, "r": r4(yaw), "s": 1})

    def at(s_, lat, h):
        pos, tan, right = frame_at(w, st, s_)
        return pos + right * lat + np.array([0.0, h, 0.0]), tan, right

    def ident(q):
        return [r4(q[0]), r4(q[1]), r4(q[2]), 1, 0, 0, 0, 1, 0, 0, 0, 1]

    def prop(key, s_, lat, h, scale, yaw, group):
        """A PropLibrary mesh (setDressing). Always non-colliding here: the library marks the DINO props solid, and a
        new solid beside the course would change the flying space (owner rule), so `collide` false overrides it."""
        q, _, _ = at(s_, lat, h)
        props.append({"key": key, "pos": [r4(v) for v in q], "yaw": r4(yaw % 360), "scale": r4(scale), "collide": False,
                      "note": group})

    def yaw_x_facing(s_):  # yaw that turns the prop's +X toward the oncoming planes (-tangent)
        _, tan, _ = frame_at(w, st, s_)
        return math.degrees(math.atan2(tan[2], -tan[0]))

    def yaw_z_along(s_):  # yaw that lays the prop's +Z along the route
        _, tan, _ = frame_at(w, st, s_)
        return math.degrees(math.atan2(tan[0], tan[2]))

    prefabs.update({k: basalt_cluster(v) for k, v in BASALT_VARIANTS.items()})
    prefabs["DressFossilRib"] = fossil_rib()
    prefabs["DressFossilSpine"] = fossil_spine(4)
    prefabs["DressFossilSkull"] = fossil_skull()
    prefabs["DressLavaLip"] = lava_lip()
    prefabs["DressLavaPool"] = lava_pool()
    prefabs["DressHallSpire"] = spire()
    prefabs["DressHallOculus"] = hall_oculus()
    prefabs["DressBonePile"] = bone_pile()

    # Basalt organ clusters in the lava along the tube, alternating sides, clear of arches/gates/alternate sides.
    names = sorted(BASALT_VARIANTS)
    k = 0
    s_ = 470.0
    while s_ < 5330:
        side = 1 if k % 2 == 0 else -1
        if not side_free(s_, side):
            side = -side
        if side_free(s_, side) and all(abs(s_ - c) > 45 for c in KEEP_CLEAR):
            lat = side * (58 + (k * 7) % 9)
            place(names[k % 3], s_, lat, FLOOR_H, "Dressing/Basalt", yaw_extra=(k * 47) % 360)
            k += 1
        s_ += 150.0 + (k * 37) % 50

    # Temple ruins half sunk in the lava, on the side opposite the nearest basalt (guide: ancient arches in the lava).
    # Visual critic v28 1.20: the loose block columns and the five-block "arch" read as brick fragments (dino4_08); the
    # approved PropLibrary ruin meshes (dino_ruined_arch, dino_broken_column) stand in their places instead.
    ruins = [("dino_broken_column", RUIN_COLUMN_SCALE), ("dino_ruined_arch", RUIN_ARCH_SCALE),
             ("dino_broken_column", RUIN_COLUMN_SCALE * 0.8)]
    k = 0
    s_ = 560.0
    while s_ < 5300:
        side = -1 if k % 2 == 0 else 1
        if not side_free(s_, side):
            side = -side
        if side_free(s_, side) and all(abs(s_ - c) > 50 for c in KEEP_CLEAR):
            key, sc = ruins[k % 3]
            prop(key, s_, side * (62 + (k * 5) % 8), PROP_FLOOR_H, sc, yaw_x_facing(s_) + (k * 71) % 40 - 20, "Ruins")
            k += 1
        s_ += 190.0 + (k * 29) % 60

    # Carved dino totems beside the deck (focal beats every few seconds) and bone piles on the lava crust. Visual critic
    # v28 1.20: the approved dino_stone_totem mesh (face along its +X, turned to the oncoming planes) replaces the block
    # post-and-head, with an ember PointLight at its face for the lit-eyes read.
    k = 0
    s_ = 640.0
    while s_ < 5300:
        side = 1 if k % 2 == 0 else -1
        if not side_free(s_, side):
            side = -side
        if side_free(s_, side) and all(abs(s_ - c) > 60 for c in KEEP_CLEAR):
            prop("dino_stone_totem", s_, side * TOTEM_LATERAL, PROP_FLOOR_H, TOTEM_SCALE, yaw_x_facing(s_), "Totems")
            eye, tan_, _ = at(s_, side * TOTEM_LATERAL, PROP_FLOOR_H + TOTEM_HEIGHT * TOTEM_SCALE * 0.8)
            eye = eye - tan_ * 7
            fx.append({"class": "PointLight", "name": f"TotemEmber_{k + 1}", "group": "Dressing/Totems", "cf": ident(eye),
                       "props": {"Brightness": 1.3, "Range": 14, "Color": "#ff7a2a", "Shadows": False}})
            place("DressBonePile", s_ + 90, -side * 48, FLOOR_H + 1, "Dressing/Bones", yaw_extra=(k * 53) % 360)
            k += 1
        s_ += 300.0 + (k * 41) % 70

    # Fossil ribcages half sunk in the lava ahead of each rib gate (critic v28 1.20: the PropLibrary dino_ribcage_bones),
    # spine along the route, on a side the alternates leave free.
    for i, g in enumerate(RIB_GATES):
        s_ = g - 70.0
        side = 1 if i % 2 == 0 else -1
        if not side_free(s_, side):
            side = -side
        prop("dino_ribcage_bones", s_, side * RIBCAGE_LATERAL, PROP_FLOOR_H - 3, RIBCAGE_SCALE, yaw_z_along(s_) + side * 12,
             "Fossils")

    # Fossil rib gates over the route (four ribs and their spine) and the skull round BoosterRing_5_Final.
    for g in RIB_GATES:
        for j in range(4):
            place("DressFossilRib", g + j * 14, 0, 0, "Dressing/Fossils")
        place("DressFossilSpine", g, 0, 0, "Dressing/Fossils")
    place("DressFossilSkull", SKULL_STATION, 0, 0, "Dressing/Fossils")

    # Hall monument: a giant stone sauropod on a lava spire in a cool skylight shaft (the guide's hero composition).
    q, _, _ = at(*HALL_STATUE_AT, 0)
    hx, hz = r4(q[0]), r4(q[2])
    inst.append({"pf": "DressHallSpire", "p": [hx, HALL_FLOOR, hz], "group": "Dressing/HallMonument", "r": 0.0, "s": 1})
    # Visual critic v28 1.15: the oculus the shafts fall from (sky disc in a rock ring under the sealed roof), softer and
    # narrower shafts (they started at 0.45 transparency and up to 128 studs wide), and a cool key on the ring.
    inst.append({"pf": "DressHallOculus", "p": [hx, HALL_CEILING, hz], "group": "Dressing/HallMonument", "r": 0.0, "s": 1})
    for i, (dx, dz, w0, w1) in enumerate(((0, 0, 46, 80), (-34, 20, 26, 44), (30, -26, 22, 40))):
        fx.append({"class": "Beam", "name": f"HallSkyShaft_{i + 1}", "group": "Dressing/HallMonument",
                   "a0": [hx + dx * 0.4, HALL_CEILING - 2, hz + dz * 0.4], "a1": [hx + dx, HALL_FLOOR + 6, hz + dz],
                   "props": {"Texture": fx_texture("glow_soft"), "TextureMode": "Stretch", "Width0": w0 * 1.1,
                             "Width1": w1 * 1.2, "FaceCamera": True, "Segments": 1, "LightEmission": 1,
                             "LightInfluence": 0, "Brightness": 1.2, "Color": "#8cbeff",
                             "Transparency": {"seq": [[0, 0.78, 0], [0.6, 0.86, 0], [1, 1, 0]]}}})
    fx.append({"class": "SpotLight", "name": "HallOculusSpot", "group": "Dressing/HallMonument",
               "cf": [hx, HALL_CEILING - 8, hz, 1, 0, 0, 0, 0, 1, 0, -1, 0],
               "props": {"Brightness": 1.2, "Range": 60, "Angle": 90, "Color": "#8cbeff", "Face": "Front", "Shadows": False}})
    fx.append({"class": "SpotLight", "name": "HallSkySpot", "group": "Dressing/HallMonument",
               "cf": [hx, HALL_FLOOR + 60 + HALL_STATUE_HEIGHT + 40, hz, 1, 0, 0, 0, 0, 1, 0, -1, 0],
               "props": {"Brightness": 6, "Range": 60, "Angle": 70, "Color": "#a6d6ff", "Face": "Front", "Shadows": True}})
    fx.append({"class": "SpotLight", "name": "HallSkySpotLow", "group": "Dressing/HallMonument",
               "cf": [hx, HALL_FLOOR + 60 + 50, hz + 40, 1, 0, 0, 0, 0, 1, 0, -1, 0],
               "props": {"Brightness": 3, "Range": 60, "Angle": 90, "Color": "#8cc4ff", "Face": "Front", "Shadows": False}})
    fx.append({"class": "ParticleEmitter", "name": "HallShaftMotes", "group": "Dressing/HallMonument",
               "cf": [hx, 120.0, hz, 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [70, 160, 70],
               "props": {"Texture": fx_texture("glow_soft"), "Rate": 10, "Lifetime": [5, 8], "Speed": [0.5, 1.5],
                         "SpreadAngle": [180, 180], "Color": "#cfe8ff", "LightEmission": 0.8,
                         "Size": {"seq": [[0, 0, 0], [0.3, 0.7, 0.2], [1, 0, 0]]},
                         "Transparency": {"seq": [[0, 0.3, 0], [1, 0.9, 0]]}}})

    # Lavafalls: a flowing lava beam down the tube wall from a rock lip into a steaming splash with an orange glow.
    lava, steam, ember = lava_texture(), fx_texture("smoke_puff_8x8"), fx_texture("ember")
    for i, (s_, side, wall) in enumerate(LAVAFALLS):
        top, tan, right = at(s_, side * (wall - 18), 66)
        bot, _, _ = at(s_, side * (wall - 6), FLOOR_H + 1)
        place("DressLavaLip", s_, side * (wall - 15), 70, "Dressing/Lavafalls", yaw_extra=-90.0 * side)
        fx.append({"class": "Beam", "name": f"Lavafall_{i + 1}", "group": "Dressing/Lavafalls",
                   "a0": [r4(v) for v in top], "a1": [r4(v) for v in bot],
                   # visual critic v28 1.14: 15-24 studs wide the beam read as a flat vertical lava slab; now a narrow
                   # stream that runs visibly, widening only a little into its splash
                   "props": {"Texture": lava, "TextureMode": "Wrap", "TextureLength": 14, "TextureSpeed": 1.1,
                             "Width0": 8, "Width1": 10, "FaceCamera": True, "Segments": 1, "LightEmission": 0.45,
                             "LightInfluence": 0, "Brightness": 1.15, "Color": "#ffc896",
                             "Transparency": {"seq": [[0, 0.35, 0], [0.12, 0.0, 0], [0.92, 0.0, 0], [1, 0.4, 0]]}}})
        splash, _, _ = at(s_, side * (wall - 10), FLOOR_H + 2)
        place("DressLavaPool", s_, side * (wall - 9), FLOOR_H + 0.4, "Dressing/Lavafalls", yaw_extra=(i * 61) % 360)
        fx.append({"class": "ParticleEmitter", "name": f"LavafallSteam_{i + 1}", "group": "Dressing/Lavafalls",
                   "cf": ident(splash), "size": [22, 2, 22],
                   "props": {"Texture": steam, "FlipbookLayout": "Grid8x8", "FlipbookMode": "OneShot",
                             "Rate": 3, "Lifetime": [3.5, 5], "Speed": [5, 9], "SpreadAngle": [12, 12],
                             "Acceleration": [0, 2, 0], "Color": "#b9a6a4", "LightEmission": 0.15,
                             "Size": {"seq": [[0, 8, 2], [1, 26, 4]]},
                             "Transparency": {"seq": [[0, 0.55, 0], [0.6, 0.75, 0], [1, 1, 0]]}}})
        fx.append({"class": "ParticleEmitter", "name": f"LavafallEmbers_{i + 1}", "group": "Dressing/Lavafalls",
                   "cf": ident(splash), "size": [18, 2, 18],
                   "props": {"Texture": ember, "Rate": 10, "Lifetime": [1.6, 2.6], "Speed": [14, 26],
                             "SpreadAngle": [28, 28], "Acceleration": [0, -10, 0], "Color": ["#ffe08a", "#ff4a10"],
                             "LightEmission": 1, "Size": {"seq": [[0, 1.3, 0.3], [1, 0.2, 0]]},
                             "Transparency": {"seq": [[0, 0.0, 0], [1, 1, 0]]}}})
        glow, _, _ = at(s_, side * (wall - 16), FLOOR_H + 12)
        fx.append({"class": "PointLight", "name": f"LavafallGlow_{i + 1}", "group": "Dressing/Lavafalls", "cf": ident(glow),
                   "props": {"Brightness": 2.2, "Range": 52, "Color": "#ff6a1e", "Shadows": False}})

    # Lava geysers beside four boost rings: a fire column with a glow, read from the chase camera as the ring nears.
    fire = fx_texture("fire_loop_8x8")
    for i, (s_, side) in enumerate(GEYSERS):
        base, _, _ = at(s_, side * 50, FLOOR_H + 1)
        fx.append({"class": "ParticleEmitter", "name": f"LavaGeyser_{i + 1}", "group": "Dressing/Geysers",
                   "cf": ident(base), "size": [6, 1, 6],
                   "props": {"Texture": fire, "FlipbookLayout": "Grid8x8", "FlipbookMode": "Loop",
                             "FlipbookFramerate": [30, 30], "FlipbookStartRandom": True,
                             "Rate": 22, "Lifetime": [1.1, 1.5], "Speed": [44, 58], "SpreadAngle": [5, 5],
                             "Acceleration": [0, -24, 0], "Color": ["#ffd27a", "#ff3c0a"], "LightEmission": 1,
                             "Size": {"seq": [[0, 8, 1], [0.5, 12, 2], [1, 5, 1]]},
                             "Transparency": {"seq": [[0, 0.1, 0], [0.8, 0.3, 0], [1, 1, 0]]}}})
        fx.append({"class": "ParticleEmitter", "name": f"LavaGeyserEmbers_{i + 1}", "group": "Dressing/Geysers",
                   "cf": ident(base), "size": [10, 1, 10],
                   "props": {"Texture": ember, "Rate": 14, "Lifetime": [1.8, 2.8], "Speed": [40, 60],
                             "SpreadAngle": [16, 16], "Acceleration": [0, -30, 0], "Color": ["#ffe08a", "#ff4a10"],
                             "LightEmission": 1, "Size": {"seq": [[0, 1.4, 0.3], [1, 0.3, 0]]},
                             "Transparency": {"seq": [[0, 0.0, 0], [1, 1, 0]]}}})
        glow, _, _ = at(s_, side * 50, FLOOR_H + 20)
        fx.append({"class": "PointLight", "name": f"LavaGeyserGlow_{i + 1}", "group": "Dressing/Geysers", "cf": ident(glow),
                   "props": {"Brightness": 2.4, "Range": 56, "Color": "#ff7a2a", "Shadows": False}})

    # Ember vents: embers drifting up off the lava every ~300 studs, alternating sides.
    for i, s_ in enumerate(range(520, 5330, 300)):
        side = 1 if i % 2 == 0 else -1
        base, _, _ = at(float(s_), side * 46, FLOOR_H + 2)
        fx.append({"class": "ParticleEmitter", "name": f"EmberVent_{i + 1}", "group": "Dressing/Embers",
                   "cf": ident(base), "size": [40, 2, 60],
                   "props": {"Texture": ember, "Rate": 9, "Lifetime": [3.5, 5.5], "Speed": [6, 13], "SpreadAngle": [20, 20],
                             "Acceleration": [0, 2.5, 0], "Color": ["#ffd27a", "#ff5014"], "LightEmission": 1,
                             "Size": {"seq": [[0, 0.9, 0.3], [0.6, 0.7, 0.2], [1, 0, 0]]},
                             "Transparency": {"seq": [[0, 0.1, 0], [0.8, 0.3, 0], [1, 1, 0]]}}})

    # Cool counterlight: skylight blue spots high over the deck (above the corridor) every ~480 studs, so the walls
    # the lava does not reach read cool (guide: blue light from the oculus against the molten glow).
    for i, s_ in enumerate(range(560, 5300, 480)):
        q, _, _ = at(float(s_), 0, 58)
        fx.append({"class": "SpotLight", "name": f"SkylightSpot_{i + 1}", "group": "Dressing/Skylight",
                   "cf": [r4(q[0]), r4(q[1]), r4(q[2]), 1, 0, 0, 0, 0, 1, 0, -1, 0],
                   "props": {"Brightness": 1.5, "Range": 60, "Angle": 95, "Color": "#6fa6ff", "Face": "Front", "Shadows": False}})

    # Visual critic v28 1.14: warm bounce under the deck edge, alternating sides every 80 studs, so the lava light reads
    # on the deck's flanks and the walls right beside the line (the route light rig sits 55 out over the lava). None in
    # the hairpin lava gap, which has no deck.
    gap = (1880.0, 2040.0)
    for i, s_ in enumerate(np.arange(DECK_GLOW_FROM, DECK_GLOW_TO, DECK_GLOW_EVERY)):
        if gap[0] - 10 <= s_ <= gap[1] + 10:
            continue
        side = 1 if i % 2 == 0 else -1
        if not side_free(s_, side) and ALT_SIDES[1][0] - 60 <= s_ <= ALT_SIDES[1][1] + 60:
            # Wave 1b C3 (critic v29 dino4_06): these Wave 1 lights lit the cave wall the Alt2 ledge rides on a hot
            # orange right beside the chase camera (the "occluding slab"); the wall itself never moves (WD rule)
            continue
        q, _, _ = at(float(s_), side * DECK_GLOW_LATERAL, DECK_GLOW_DROP)
        fx.append({"class": "PointLight", "name": f"DeckEdgeGlow_{i + 1}", "group": "Dressing/DeckGlow", "cf": ident(q),
                   "props": {"Brightness": 1.2, "Range": 44, "Color": "#ff8a3a", "Shadows": False}})
    return prefabs, inst, fx, props


# ---------- art ----------
def part_spec(p, pivot_c):
    P = np.array(pivot_c[:3]); PR = rot_from_components(pivot_c)
    W = np.array(p["cf"][:3]); WR = rot_from_components(p["cf"])
    rel_pos = PR.T @ (W - P)
    rel_R = PR.T @ WR
    sx, sy, sz = p["size"]
    shape = p["shape"]
    if shape == "C":
        # template: Size=(sy,sx,sz), CFrame = cf * Rz(90)  =>  cf rotation = rel_R * Rz(-90)
        rot = rel_R @ RZ90.T
        size = [sy, sx, sz]
        size = [p["size"][1], p["size"][0], p["size"][2]]
    else:
        rot = rel_R
        size = [sx, sy, sz]
    if shape not in ("B", "W", "C", "S"):
        raise SystemExit(f"unsupported shape {shape} in {p['unit']}/{p['name']}")
    e = euler_yxz(rot)
    # round-trip check against the template's construction
    back = mat_yxz(*e) @ (RZ90 if shape == "C" else np.eye(3))
    if np.abs(back - rel_R).max() > 1e-4:
        raise SystemExit(f"rotation round-trip failed for {p['unit']}/{p['name']}")
    extra = {}
    if p["transparency"] > 0:
        extra["a"] = r4(p["transparency"])
    if not p["collide"]:
        extra["nc"] = 1
    spec = [shape, r4(rel_pos[0]), r4(rel_pos[1]), r4(rel_pos[2]), r4(size[0]), r4(size[1]), r4(size[2]),
            r4(e[0]), r4(e[1]), r4(e[2]), p["color"], p["material"]]
    if extra:
        spec.append(extra)
    return spec


def backdrop_block(shell_ops: list[dict]) -> dict:
    """Visibility v1 (owner report 2026-10-20: "too much of the map is constantly not being displayed"): at lower
    graphics levels, on phones and under Automatic quality the client stops drawing terrain past its render distance,
    so the great hall's far walls (600-1350 studs) and the lava sea drop out and the violet sky shows. tools/map/backdrop.py
    expands this into plain non-colliding parts: a wall ring and a ceiling 30 studs outside every carve of the cave
    (hall, tube and alternates), in the terrain's own Sandstone/Rock look, and a lava plane 6 studs under the top of
    the lava sea slab. Hidden by the terrain wherever it is drawn; drawn where it is not. Purely visual."""
    slab = next(i for i, op in enumerate(shell_ops)
                if op["op"] == "FillBlock" and op["mat"] == "CrackedLava" and op["size"][0] >= 2000)
    return {
        "shells": [{"name": "CaveShell", "ops": "all", "offset": 30, "thickness": 8, "floorY": 0, "tile": 512,
                    "minTile": 40, "minEdge": 120,
                    "wall": {"mat": "Sandstone", "color": TERRAIN_COLORS["Sandstone"]},
                    "ceiling": {"mat": "Rock", "color": TERRAIN_COLORS["Rock"]}}],
        "floors": [{"name": "LavaFloor", "ops": "all", "slab": slab, "sink": 6, "thickness": 4, "pad": 60, "tile": 700,
                    "minTile": 80, "mat": "CrackedLava", "color": TERRAIN_COLORS["CrackedLava"]}],
    }


# Visual critic v28 1.13 (cave shell value break): the tube walls were one Sandstone value band to the roof. The mass
# is re-materialed (never reshaped) right after FillRouteBounds, while it is still one solid block: per pair of route
# segments a yaw-aligned Rock block from VALUE_BREAK studs over the deck up into the crown. Every block sits inside the
# solid mass, so it only swaps Sandstone voxels for Rock ones; the carves that follow open the same tube, halls and
# chamber as before, now with a warm lower wall (Sandstone) and a darker, cool upper wall and ceiling (Rock, larger
# tiles in assets/materials/dino_v1/variants.json). The plane's surface handling never reads terrain material
# (FlightController keys on part names; StyleSense only on CrackedLava), so nothing the game flies against changes.
VALUE_BREAK = 30.0  # ~30% of the tube height (lava -39 .. upper lobe ~+190)
VALUE_BAND_WIDTH = 460.0
VALUE_BAND_STRIDE = 2


def value_break_bands(w, frb):
    w = np.asarray(w, float)
    lo, hi = w.min(0), w.max(0)
    m = frb["margin"]
    top = hi[1] + frb["above"]
    band_top = top - frb["crownThickness"] + 4  # overlaps the crown
    xlo, xhi, zlo, zhi = lo[0] - m + 2, hi[0] + m - 2, lo[2] - m + 2, hi[2] + m - 2
    ops = []
    n = len(w)
    for i in range(0, n - 1, VALUE_BAND_STRIDE):
        a, b = w[i], w[min(i + VALUE_BAND_STRIDE, n - 1)]
        d = np.array([b[0] - a[0], 0.0, b[2] - a[2]])
        ln = float(np.linalg.norm(d))
        if ln < 0.5:
            continue
        look = d / ln
        right = np.array([-look[2], 0.0, look[0]])
        bottom = min(a[1], b[1]) + VALUE_BREAK
        mid = (a + b) / 2
        width, length = VALUE_BAND_WIDTH, ln + 60.0
        while True:  # shrink until every corner is inside the mass footprint
            corners = [mid + right * sx * width / 2 + look * sz * length / 2 for sx in (-1, 1) for sz in (-1, 1)]
            if all(xlo <= c[0] <= xhi and zlo <= c[2] <= zhi for c in corners):
                break
            width -= 20.0
            assert width >= 200, (i, width)
        back = -look
        cf = [r4(mid[0]), r4((bottom + band_top) / 2), r4(mid[2]),
              r4(right[0]), 0, r4(back[0]), 0, 1, 0, r4(right[2]), 0, r4(back[2])]
        ops.append({"op": "FillBlock", "cf": cf, "size": [r4(width), r4(band_top - bottom), r4(length)], "mat": "Rock"})
    return ops


# Review fix (w1-dino): the route bands are 460 wide, so in the great hall (1000 x 1200, roof at 245) they covered only
# strips of the roof and walls along the two hall passes (64% of the flat roof), leaving straight-edged Rock/Sandstone
# patches. Over the hall's own footprint (plus 12, so the wall-surface voxels are included) the break is one level
# instead: first the band Rock below it goes back to Sandstone, then Rock from HALL_VALUE_BREAK up into the crown. Both
# blocks lie inside the solid mass before any carve, so, like the bands, they swap material only.
HALL_BOX = ((-380.0, -1050.0), (1000.0, 1200.0))  # the great hall's Air FillBlock (centre x/z, size x/z)
HALL_VALUE_BREAK = 120.0  # route through the hall 58..112 (break 88..142 at the portals); ~30% of floor 16 .. domes 390
HALL_BREAK_MARGIN = 12.0


def hall_value_break(frb, w):
    w = np.asarray(w, float)
    top = w.max(0)[1] + frb["above"]
    band_top = top - frb["crownThickness"] + 4
    (cx, cz), (sx, sz) = HALL_BOX
    sx, sz = sx + 2 * HALL_BREAK_MARGIN, sz + 2 * HALL_BREAK_MARGIN
    y0 = frb["yMin"]
    return [{"op": "FillBlock", "cf": [cx, r4((y0 + HALL_VALUE_BREAK) / 2), cz, 1, 0, 0, 0, 1, 0, 0, 0, 1],
             "size": [sx, r4(HALL_VALUE_BREAK - y0), sz], "mat": frb["mat"]},
            {"op": "FillBlock", "cf": [cx, r4((HALL_VALUE_BREAK + band_top) / 2), cz, 1, 0, 0, 0, 1, 0, 0, 0, 1],
             "size": [sx, r4(band_top - HALL_VALUE_BREAK), sz], "mat": "Rock"}]


# Visual critic v28 1.14 (lava reads as the floor): five crust islands of radius 16-36 on every 30-stud segment buried
# the CrackedLava under Basalt (dino4_05/07/09/11 floor all dark plate). Through the great hall pass and the far cavern
# the crust thins to two smaller islands every third segment; the slab, its width and depth are unchanged and nothing is
# added (the islands only stand 3 studs proud of the lava, 37+ under the deck, and no wall base is touched). The per-
# segment random seed is the segment index, so the crust outside those spans is exactly as before.
LAVA_OPEN = [(1300.0, 2200.0), (3500.0, 4400.0)]


def floor_fills():
    base = {"op": "RouteFloorFill", "mat": "CrackedLava", "depth": 44, "width": 230, "thickness": 10,
            "crustMat": "Basalt", "crustEvery": 1, "crustPerSegment": 5, "crustRadius": 26, "seed": 11}
    light = dict(base, crustEvery=3, crustPerSegment=2, crustRadius=18)
    out, s0 = [], 440.0
    for a, b in LAVA_OPEN:
        out.append(dict(base, fromStation=s0, toStation=a - 0.001))
        out.append(dict(light, fromStation=a, toStation=b))
        s0 = b + 0.001
    out.append(dict(base, fromStation=s0, toStation=5330))
    return [{"op": o["op"], "fromStation": o["fromStation"], "toStation": o["toStation"],
             **{k: v for k, v in o.items() if k not in ("op", "fromStation", "toStation")}} for o in out]


def build():
    """The plan as a dict (deterministic; tools/map/tests/test_dino4.py compares it with map/dino4/plan.json)."""
    art = json.loads((EXT / "art.json").read_text())
    ops = json.loads((EXT / "terrain_ops.json").read_text())
    fb = json.loads((EXT / "fallback.json").read_text())
    nodes = parse_nodes()
    w, st, scale = route(nodes)
    length = st[-1]
    assert abs(length - 5450) < 1, length

    # --- prefabs and instances ---
    excluded = re.compile(r"^(CausewayPier|PierFooting)")
    units = {u["path"]: u for u in art["units"]}
    by_unit = {}
    for p in art["parts"]:
        if p["unit"] == "folder:TrackRibbon" or excluded.match(p["name"]):
            continue
        by_unit.setdefault(p["unit"], []).append(p)
    groups, prefabs, instances = [], {}, []

    def gidx(path):
        if path not in groups:
            groups.append(path)
        return groups.index(path) + 1

    for unit in sorted(by_unit):
        if DROPPED_UNITS.search(unit):
            continue
        parts = by_unit[unit]
        if unit.startswith("folder:"):
            folder = unit[len("folder:"):]
            ctr = np.mean([np.array(p["cf"][:3]) for p in parts], axis=0).round(1)
            pivot = [*ctr.tolist(), 1, 0, 0, 0, 1, 0, 0, 0, 1]
            key, group = folder.replace("/", "_") + "_Loose", folder
        else:
            u = units[unit]
            pivot = u["pivot"]
            key, group = u["name"], "/".join(unit.split("/")[:-1])
        if key in prefabs:
            raise SystemExit(f"duplicate prefab key {key}")
        specs = [part_spec(p, pivot) for p in parts]
        if STONE_UNITS.match(key):
            for sp in specs:
                if sp[11] == "Sandstone":
                    sp[10] = STONE_RECOLOR.get(sp[10], sp[10])
        prefabs[key] = {"parts": specs}
        R = rot_from_components(pivot)
        instances.append({"pf": key, "p": [r4(v) for v in pivot[:3]], "g": gidx(group), "r": [r4(v) for v in euler_yxz(R)], "s": 1})

    # deliberate block fallback for the sauropod: its own prefab, hidden by the adapter when the mesh loads
    normal = {(p["name"], tuple(round(v, 2) for v in p["cf"][:3])) for p in art["parts"] if p["unit"].startswith("Landmarks/RoamingGreenSauropod")}
    fb_parts = [p for p in fb["parts"] if (p["name"], tuple(round(v, 2) for v in p["cf"][:3])) not in normal]
    sauro = units["Landmarks/RoamingGreenSauropod"]
    prefabs["RoamingGreenSauropodFallback"] = {"parts": [part_spec(p, sauro["pivot"]) for p in fb_parts]}
    instances.append({"pf": "RoamingGreenSauropodFallback", "p": [r4(v) for v in sauro["pivot"][:3]], "g": gidx("Landmarks"),
                      "r": [r4(v) for v in euler_yxz(rot_from_components(sauro["pivot"]))], "s": 1})

    d_prefabs, d_inst, d_fx, d_props = dressing(w, st)
    for k in sorted(d_prefabs):
        prefabs[k] = d_prefabs[k]
    for di in d_inst:
        instances.append({"pf": di["pf"], "p": di["p"], "g": gidx(di["group"]), "r": di["r"], "s": di["s"]})

    # --- shells: terrain ops in order; RouteCavern replaces the per-segment cavern triplets ---
    # The per-segment cavern walls are the FillBlock call sites repeated once per qualifying route segment (45 for the
    # current route); identified by signature, not by line offsets that shift with the injected recorder header.
    from collections import Counter
    fb_lines = Counter(o["line"] for o in ops if o["op"] == "FillBlock")
    cavern_lines = {line for line, n in fb_lines.items() if n >= 30}
    assert len(cavern_lines) == 3, fb_lines
    shell_ops, cavern_done, hall_pillars = [], False, False

    def arg(o, i):
        return o["args"][i]["v"]

    for o in ops:
        if o["line"] in cavern_lines:
            if not cavern_done:
                # 2026-10-18 art pass: the legacy per-segment flat wall slabs (builder_dino4.luau:631-636) left sky gaps and
                # read as a corridor of flat walls. Sealed cavern instead: solid mass around the course, a great hall over
                # the caldera here, the organic route tube and lava floor after the start-chamber ops (below).
                shell_ops.append({"op": "FillRouteBounds", "mat": "Sandstone", "margin": 280, "yMin": 0, "above": 310,
                                  "crownMat": "Rock", "crownThickness": 120})
                frb = shell_ops[-1]
                shell_ops.extend(value_break_bands(w, frb))
                shell_ops.extend(hall_value_break(frb, w))
                shell_ops.append({"op": "FillBlock", "cf": [-380, 130, -1050, 1, 0, 0, 0, 1, 0, 0, 0, 1], "size": [1000, 230, 1200], "mat": "Air"})
                for k in range(10):
                    a = k / 10 * 2 * math.pi
                    shell_ops.append({"op": "FillBall", "center": [round(-380 + math.cos(a) * 420, 2), 220, round(-1050 + math.sin(a) * 520, 2)], "r": 170, "mat": "Air"})
                cavern_done = True
                hall_pillars = True
            continue
        name = o["op"]
        if name == "Clear":
            shell_ops.append({"op": "Clear"})
        elif name == "SetMaterialColor":
            mat = arg(o, 0).split(".")[-1]
            c = arg(o, 1)
            shell_ops.append({"op": "SetMaterialColor", "mat": mat, "color": "#%02x%02x%02x" % tuple(round(x * 255) for x in c)})
        elif name == "FillBlock":
            shell_ops.append({"op": "FillBlock", "cf": [r4(v) for v in arg(o, 0)], "size": [r4(v) for v in arg(o, 1)], "mat": arg(o, 2).split(".")[-1]})
        elif name == "FillBall":
            shell_ops.append({"op": "FillBall", "center": [r4(v) for v in arg(o, 0)], "r": r4(arg(o, 1)), "mat": arg(o, 2).split(".")[-1]})
        elif name == "FillCylinder":
            shell_ops.append({"op": "FillCylinder", "cf": [r4(v) for v in arg(o, 0)], "h": r4(arg(o, 1)), "r": r4(arg(o, 2)), "mat": arg(o, 3).split(".")[-1]})
        elif name == "FillWedge":
            shell_ops.append({"op": "FillWedge", "cf": [r4(v) for v in arg(o, 0)], "size": [r4(v) for v in arg(o, 1)], "mat": arg(o, 2).split(".")[-1]})
        else:
            raise SystemExit(f"unhandled terrain op {name} at line {o['line']}")

    if hall_pillars:
        # terrain-look: basalt pillars standing at the hall edge (vertical rhythm against the flat cavern wall), placed
        # strictly outside the route corridor (HALL_PILLAR_CLEAR from the main line and the alternates); the tube carve after
        # them would trim any overlap anyway
        lines_ = [np.array(w, float),
                  np.array(offset_path(w, st, 130, 1420, lateral=112, height=0, ramp=190, step=36, min_offset=40), float),
                  np.array(offset_path(w, st, 2380, 3240, lateral=-74, height=-16, ramp=160, step=36, min_offset=34), float)]

        def seg_dist(pt):
            pt = np.array(pt, float)
            best = 1e18
            for ln_ in lines_:
                for i in range(len(ln_) - 1):
                    ab = ln_[i + 1] - ln_[i]
                    t = max(0.0, min(1.0, float(np.dot(pt - ln_[i], ab) / max(1e-9, np.dot(ab, ab)))))
                    best = min(best, float(np.linalg.norm(pt - (ln_[i] + ab * t))))
            return best

        ring = [(x, -1600.0) for x in range(-800, 61, 172)] + [(x, -500.0) for x in range(-800, 61, 172)]
        ring += [(-830.0, z) for z in range(-1500, -599, 180)] + [(70.0, z) for z in range(-1500, -599, 180)]
        placed = 0
        for hx, hz in ring:
            if math.hypot(hx - EGG_CENTRE[0], hz - EGG_CENTRE[1]) < 240 + 30 + 40:
                continue  # outside the egg-battle return circle (radius 240 + soft band 30) and its margin
            if placed >= 8 or min(seg_dist((hx, y_, hz)) for y_ in (40.0, 110.0, 180.0)) < HALL_PILLAR_CLEAR:
                continue
            for yy, rr in ((40, 24), (78, 21), (114, 18), (146, 15)):
                shell_ops.append({"op": "FillBall", "center": [float(hx), float(yy), float(hz)], "r": rr, "mat": "Basalt"})
            placed += 1
        assert placed >= 3, placed
    shell_ops.append({"op": "CarveRouteTube", "fromStation": 440, "toStation": 5330, "radiusMin": 66, "radiusMax": 112,
                      "lift": 26, "upperLift": 70, "upperScale": 0.8, "noiseFreq": 0.13, "seed": 7})
    shell_ops.extend(floor_fills())
    shell_ops.append(dict(FINAL_BEND_WIDEN))

    # --- gameplay: project built objects onto the corrected route ---
    rings, pads, pods = [], [], []
    for g in art["gameplay"]:
        s, lat, h = project(w, st, g["pos"])
        if g.get("trigger") == "BoosterRing":
            ring = {"name": g["parent"], "station": round(s, 1), "lateral": 0, "height": 14, "coin": bool(g.get("coin")), "coinId": None,
                    "builtOffset": [round(lat, 1), round(h, 1)]}
            if ring["name"] in RING_STATIONS:
                ring["builtStation"] = ring["station"]  # where the built ring projected (builtOffset is relative to it)
                ring["station"] = RING_STATIONS[ring["name"]]
            rings.append(ring)
        elif g.get("trigger") == "GroundBoostPad":
            pads.append({"name": g["parent"], "station": round(s, 1), "lateral": 0, "builtOffset": [round(lat, 1), round(h, 1)]})
        elif g.get("pod"):
            pods.append({"name": g["name"], "station": round(s, 1), "lateral": round(max(-12, min(12, lat)), 1), "height": 12,
                         "type": g.get("podType") or "Speed", "builtOffset": [round(lat, 1), round(h, 1)]})
    # Item cubes v3 (docs/design/ITEM_BOXES.md; rules in tools/map/item_cubes.json): the builder's scattered item pods
    # (a start-drop pair, an Alt1 single, a slope pair and a four-pod pile at the arch) give way to 7 staggered two-deep
    # clusters of 5 mystery cubes (front rank of 2, back rank of 3 36 studs on; v2 had 3 a cluster) every 700-870 studs
    # at the old height (12). Fixed race stations clear of rings, pads and coins: past the start pad, the sauropod hall
    # approach, the lava hairpin, the Alt2 span, the far cavern, before the penultimate ring and the final run. The
    # builder's Speed and Air pods (start drop, pillar trio, cavern floor) stay where they are, except the one that sat
    # 64 studs before the cavern cluster (owner: no winged coin beside the blocks): it moves to 4080, between the final
    # ring (3900) and the 4250 coin, well clear of the cavern and penultimate clusters (assert_layout checks the gap).
    pods = [p for p in pods if p["type"] in item_rows.SINGLE_TYPES]
    for p in pods:
        if p["name"] == "CavernFloorSpeed_4":
            p["station"] = 4080.0
            p.pop("builtOffset", None)  # no longer where the builder put it
    sets = ((540.0, "StartRow"), (1300.0, "HallRow"), (2050.0, "HairpinRow"), (2800.0, "BasinRow"),
            (3500.0, "CavernRow"), (4300.0, "PenultRow"), (5160.0, "FinalRow"))
    for k, (s_, tag) in enumerate(sets):
        pods += item_rows.cube_set("plane", "dino4", k, s_, 12, lambda t, j, tag=tag: f"{tag}_{t}Pod_{j}", tag)
    item_rows.assert_layout({"pods": pods}, "plane", "dino4", length)
    for lst in (rings, pads, pods):
        lst.sort(key=lambda x: (x["station"], x["name"]))

    # Alternate lines are generated from the main route's own frames (eased lateral/height offset between a join and a
    # rejoin station), so they always leave and rejoin the race line. The legacy builder's hand-placed Alt1/Alt2 points
    # were dead ends (Alt2 ended in mid-air) and read as floating planks from the main line.
    alt = {
        "alt1Pts": offset_path(w, st, 130, 1420, lateral=112, height=0, ramp=190, step=36, min_offset=40),
        "alt2Pts": offset_path(w, st, 2380, 3240, lateral=-74, height=-16, ramp=160, step=36, min_offset=34),
    }

    prefabs["DressAlt1Ember"] = alt1_ember()
    e_inst, e_fx = alt1_embers(alt["alt1Pts"])
    for di in e_inst:
        instances.append({"pf": di["pf"], "p": di["p"], "g": gidx(di["group"]), "r": di["r"], "s": di["s"]})
    d_fx.extend(e_fx)

    coins = []
    for s_, lat, h, note in COINS:
        coins.append({"station": float(s_), "lateral": float(lat), "height": float(h),
                      "pos": [round(float(v), 2) for v in coin_anchor(w, st, s_, lat, h)], "note": note})
    a1 = np.array(alt["alt1Pts"][ALT1_COIN_POINT], float) + np.array([0, 14.0, 0])
    a1_s, a1_lat, a1_h = project(w, st, a1)
    coins.append({"station": round(a1_s, 1), "lateral": round(a1_lat, 1), "height": round(a1_h, 1),
                  "pos": [round(float(v), 2) for v in a1], "alternate": "Alt1",
                  "note": "Alt1 tunnel, middle of the enclosed stretch (its flight line: point + 14)"})
    coins.sort(key=lambda c: c["station"])
    for i, c in enumerate(coins, 1):
        c["id"] = i

    # DINO-4 launch upgrade (TRACK_VARIETY 5a): geyser updraft vents on the Alt1 floor, so Alt1 is the comeback line.
    # Non-collidable, a fixed 4 s cycle (shared/VolcanoRules). Placed on the Alt1 points (floor 1.8 under the flight line
    # point + 14), clear of the Alt1 coin, the key (Alt2) and the egg-battle floor; the second runs 2 s out of phase.
    geysers = []
    for n, (pt, phase) in enumerate(UPDRAFT_VENTS, 1):
        base = np.array(alt["alt1Pts"][pt], float) + np.array([0, ALT1_FLOOR, 0])
        g_s = project(w, st, base)[0]
        geysers.append({"id": f"AltGeyser{n}", "alternate": "Alt1", "pointIndex": pt, "station": round(g_s, 1),
                        "pos": [round(float(v), 2) for v in base], "phase": phase, "cycle": 4.0,
                        "radius": 12, "height": 26})

    # zone where the builder narrows the deck: mid.Z > -420 and wp1.station < 460
    # Deck zones match segments by start station; the builder's test (mid.Z > -420 and station < 460) ends the narrow
    # start deck at the first segment that fails it, so the zone ends just before that segment's start station.
    start_vista_end = 0.0
    for i in range(len(w) - 1):
        mid = (w[i] + w[i + 1]) / 2
        if not (mid[2] > -420 and st[i] < 460):
            start_vista_end = math.floor(st[i])
            break

    hz = []
    for h in art["hazards"]:
        cf, size = [r4(v) for v in h["cf"]], [r4(v) for v in h["size"]]
        if h["name"] == "StartLavaBed":
            assert cf[3:] == [1, 0, 0, 0, 1, 0, 0, 0, 1], cf  # axis-aligned, so clipping is a box intersection
            (x0, x1), (z0, z1) = START_LAVA_BED_BOUNDS["x"], START_LAVA_BED_BOUNDS["z"]
            x0, x1 = max(x0, cf[0] - size[0] / 2), min(x1, cf[0] + size[0] / 2)
            z0, z1 = max(z0, cf[2] - size[2] / 2), min(z1, cf[2] + size[2] / 2)
            cf[0], cf[2], size[0], size[2] = r4((x0 + x1) / 2), r4((z0 + z1) / 2), r4(x1 - x0), r4(z1 - z0)
        hz.append({"name": h["name"], "kind": h["kind"], "cf": cf, "size": size,
                   "visible": h["transparency"] < 1, "collide": h["collide"], "material": h["material"], "color": h["color"],
                   "group": "/".join(h["path"].split("/")[:1])})
    m0 = art["meshes"][0]
    # Stone sauropod v2 (2026-10-18): the faceted editable mesh refined in Blender (win/blender_sauropod_v2.py, painterly
    # 2x2 stone atlas) replaces the melted Tripo mesh as the landmark, per ASSETS/TRACK_PIPELINE ("refine, do not
    # regenerate"); the accepted Tripo ids stay recorded in ASSETS. Head toward camera-left like the concept.
    sx, sy, sz = m0["cf"][:3]
    q_, _, _ = frame_at(w, st, HALL_STATUE_AT[0])
    _, _, rgt = frame_at(w, st, HALL_STATUE_AT[0])
    mx, mz = r4(q_[0] + rgt[0] * HALL_STATUE_AT[1]), r4(q_[2] + rgt[2] * HALL_STATUE_AT[1])
    hall_mesh = {"name": "HallSauropodMonument", "model": 110536125503897, "textureId": "rbxassetid://88832612858767",
                 "parent": "Landmarks/HallSauropod", "cf": [mx, r4(HALL_FLOOR + 60 + HALL_STATUE_HEIGHT / 2 - 2), mz, 0, 0, 1, 0, 1, 0, -1, 0, 0],
                 "height": HALL_STATUE_HEIGHT, "material": "SmoothPlastic", "color": "#ffffff", "collide": False,
                 "label": "hall sauropod monument (L61)"}
    meshes = [{"name": "StoneSauropodV2Mesh", "model": 110536125503897, "textureId": "rbxassetid://88832612858767", "parent": m0["parent"],
               "cf": [r4(sx), r4(sy), r4(sz), -1, 0, 0, 0, 1, 0, 0, 0, -1], "height": 62, "material": "SmoothPlastic", "color": "#ffffff",
               "collide": False, "fallbackGroup": "Landmarks/RoamingGreenSauropodFallback", "label": "sauropod"}, hall_mesh]
    fx = []
    for f in art["fx"]:
        props = dict(f["props"])
        if f["class"] in ("PointLight", "SpotLight") and isinstance(props.get("Brightness"), (int, float)):
            # Lights were tuned under the legacy lighting technology; Future (2026-10-18 art pass) renders local
            # lights much hotter, which blew out the start chamber.
            props["Brightness"] = round(props["Brightness"] * 0.6, 3)
        if f["class"] == "Beam":
            # Oculus god rays: under Future + bloom the legacy values washed the start chamber white.
            props["Transparency"] = {"seq": [[0, 0.95, 0], [0.5, 0.97, 0], [1, 1, 0]]}
            props["LightEmission"] = 0.25
        e = {"class": f["class"], "group": f["group"].replace("folder:", ""), "props": props}
        if "cf" in f:
            e["cf"] = [r4(v) for v in f["cf"]]
        if "a0" in f:
            e["a0"] = [r4(v) for v in f["a0"]]
            e["a1"] = [r4(v) for v in f["a1"]]
        if "size" in f:
            e["size"] = [r4(v) for v in f["size"]]
        fx.append(e)
    # Start chamber light pass (concept 04_dino4_controls.png: cool skylight key from the oculus over the statue, warm lava
    # fill low in the chamber). The chamber is the hero view, so it gets its own rig beyond the route lights.
    fx.append({"class": "SpotLight", "group": "VolcanoCaldera", "cf": [16, 196, -142, 1, 0, 0, 0, 0, 1, 0, -1, 0],
               "props": {"Brightness": 5, "Range": 140, "Angle": 62, "Color": "#9adcff", "Face": "Front", "Shadows": True}})
    for (lx, ly, lz) in [(-70, 92, -60), (70, 92, -90), (-60, 92, -230), (60, 92, -260), (0, 92, -360), (-20, 96, -10)]:
        fx.append({"class": "PointLight", "group": "VolcanoCaldera", "cf": [lx, ly, lz, 1, 0, 0, 0, 1, 0, 0, 0, 1],
                   "props": {"Brightness": 1.1, "Range": 85, "Color": "#ff7a30", "Shadows": False}})
    attrs = [{"path": a["path"], "attrs": {k: v for k, v in a["attrs"].items() if k in ("BasePivotPos", "BaseYawDeg")}} for a in art["attrs"]]
    # Wave 1b C2 (critic v29 dino4_00 "caged" frame): the rib gates fade on the client while the chase camera passes
    # through them (client/CameraNearFade; LocalTransparencyModifier only, the ribs never collide)
    attrs.append({"path": "Dressing/Fossils", "attrs": {"CameraNearFade": FOSSIL_CAMERA_FADE}})

    plan = {
        "prefabs": {k: prefabs[k] for k in sorted(prefabs)},
        "instances": instances,
        "groups": groups,
        "terrain": {"nx": 1, "nz": 1, "cell": 4},
        "markers": [],
        "skyrally": {
            "archetype": "Waking volcano, lap-3 eruption", "signatureVerb": "weave",
            "signature": "Weave between the lava spires and tunnel mouths, then ride the geyser updrafts on the Alt1 comeback line while the volcano wakes on lap 3.",
            "id": "DINO-4", "key": "dino4", "zone": "DINO", "vehicle": "plane", "laps": 3,
            "guide": "docs/guides/dino4.md", "lighting": "DINO-4",
            "route": {"nodes": nodes, "closed": True, "samplesPerSegment": 9, "targetLength": 5450, "flexScaleMin": 0.0,
                      "flexScaleMax": 3.5, "bisectIterations": 24, "minRadius": 85,
                      "radiusExceptions": [{"from": 130, "to": 240, "reason": "approved start S-curve through the foreground arch, inside the open start chamber"}]},
            "deck": {"style": "dino_paver", "width": 32,
                     "zones": [{"from": 0, "to": start_vista_end, "width": 22, "paverRows": 2, "curbHeights": [3.2, 2.6]}],
                     "curbHeights": [5.2, 4.4], "gaps": [{"from": 1880, "to": 2040, "reason": "lava gap jump at the hairpin apex"}], "piersEvery": 5},
            "flight": {"lineOffset": 14, "corridor": {"halfWidth": 34, "floor": 5, "ceiling": 44},
                       "allowPockets": []},  # FLIGHT_GUIDE.md 12.3: survey found none needed (key and coins sit on Alt1/Alt2, the egg hall is a battle arena)
            "gameplay": {
                "checkpoints": {"stations": sorted([round(c["station"], 1) for c in art["checkpoints"]] + EXTRA_CHECKPOINTS),
                                "size": [56, 42, 6], "heightOffset": 18},
                "rings": rings, "pads": pads, "pods": pods,
                "startGrid": {"station": 18, "height": 11, "rowSpacing": 28, "laneOffset": 12},
                "finish": {"station": 0, "radius": 58},
                "alternates": [
                    {"id": "Alt1", "points": alt["alt1Pts"], "style": "tunnel", "joinStation": 130, "rejoinStation": 1420},
                    {"id": "Alt2", "points": alt["alt2Pts"], "style": "ledge", "joinStation": 2380, "rejoinStation": 3240},
                ],
                # LAUNCH_PROGRESSION 2b: the DINO key sits off the racing line, over the middle of the Alt2 ledge.
                "key": {"station": 2810, "lateral": 0, "height": 9, "line": "Alt2", "pos": [-886.68, 54.24, -1596.02],
                        "note": "above the middle of the Alt2 ledge (9 studs over its flight point 9), about 78 studs inside the main line at station 2790: seen across the bend from the lap, taken only by flying the ledge alternate"},
                "coins": coins,
                "geysers": geysers,
                # lap-3 eruption (client/VolcanoMoments): lava light pulse, ash, rumble stand-in, small shake; purely visual
                "eruption": {"lap": 3},
                "modes": {"battle": egg_battle()},
            },
            "shells": {"ops": shell_ops},
            "backdrop": backdrop_block(shell_ops),
            "hazards": hz, "meshes": meshes, "modelAttributes": attrs, "fx": fx + d_fx,
            "setDressing": d_props,
            "framing": {"heroStation": 60, "note": "first gameplay view matches 04_dino4_controls.png (L3 framing lock)"},
            "routeLights": {"every": 3, "fromStation": 460, "toStation": 5300, "offsets": [[-55, -32], [55, -32]],
                            "color": "#ff6a24", "range": 58, "brightness": 1.1},
            "materials": {
                # dino-cave (v22): terrain Sandstone takes SR_DINO_CaveRock (Sandstone base, the non-directional T2_DARK_ROCK
                # tile and pack reused, no new upload), not SR_DINO_Strata. Terrain texturing is world-projected per material,
                # so the strata's horizontal bands swirl and stretch radially on the carved tube's curved walls; isotropic
                # rock reads the same at any wall angle. Strata stays on the planar part prefabs via partRules below.
                # Runtime-only (MaterialService override at activate): voxels, geometry and collision are unchanged.
                "terrainOverrides": {"Sandstone": "SR_DINO_CaveRock", "Rock": "SR_DINO_Rock", "Basalt": "SR_DINO_Basalt", "CrackedLava": "SR_DINO_Lava"},
                # Low-graphics terrain tints, as published (TERRAIN_COLORS above; tints.json carries the newer cap)
                "terrainColors": dict(TERRAIN_COLORS),
                "partRules": [
                    {"name": "^Paver_", "setMaterial": "Slate", "variant": "SR_DINO_Pavers", "color": "#9c8276"},
                    {"name": "^Alt1Floor", "setMaterial": "Slate", "variant": "SR_DINO_Pavers", "color": "#9c8276"},
                    {"name": "^TrackSeg_", "setMaterial": "Slate", "variant": "SR_DINO_Pavers", "color": "#5e4e50"},
                    # L61: one light stone trim on both deck edges so the racing line reads at speed (r1: track dead dark)
                    {"name": "^Curb[LR]_", "variant": "SR_DINO_Masonry", "color": "#e8c690"},
                    # visual critic v28 1.20: the Alt1 tunnel walls and the Alt1 portal read as red brick slabs from the
                    # main line (dino4_02/04/10, the "brick hut" in dino4_00); painted sandstone strata instead, the
                    # tunnel walls in the critic's sandstone (200,150,100). The Alt2 ledge takes the deck's pavers.
                    {"name": "^Alt1Wall[LR]_", "setMaterial": "Sandstone", "variant": "SR_DINO_Strata", "color": "#c89664"},
                    {"name": "^Alt2Ledge_", "setMaterial": "Slate", "variant": "SR_DINO_Pavers", "color": "#9c8276"},
                    # Wave 1b C4: kit/Deck's runtime Neon torch strip down the Alt1 roof becomes a dark basalt recess
                    # course; the ember slivers and lamps (Dressing/Alt1Embers) carry the light
                    {"name": "^Alt1TorchStrip_", "setMaterial": "Basalt", "color": "#3a2e30"},
                    # Wave 1b C2/C6: fossil bone is plain Sandstone (no masonry block tile from the catch-all below)
                    {"prefab": "DressFossilRib", "material": "Sandstone"},
                    {"prefab": "DressFossilSpine", "material": "Sandstone"},
                    {"prefab": "DressFossilSkull", "material": "Sandstone"},
                    {"prefab": "DualLevelTunnelPortal", "material": "Sandstone", "variant": "SR_DINO_Strata"},
                    # terrain-look: rock-like prefabs (pillars, caldera rim stones, hall spires) take the painted strata tile
                    # (40 studs); every other Sandstone part is built masonry (arches, gates, altar, ruins, totems, pedestals)
                    *({"prefab": pf, "material": "Sandstone", "variant": "SR_DINO_Strata"} for pf in ROCK_PREFABS),
                    {"material": "Sandstone", "variant": "SR_DINO_Masonry"},
                ],
            },
            "provenance": {"extracted_from": art["source"], "author": "tools/map/author_dino4.py",
                           "routeFlexScale": round(scale, 6), "routeLength": round(length, 3),
                           "excluded": "deck/curbs/fascia/piers (kit/Deck), Alt1/Alt2 parts (adapter alternates), trigger parts FinishLine/FTUEArch (unused)"},
        },
    }
    return plan


def main():
    plan = build()
    sk = plan["skyrally"]
    gp = sk["gameplay"]
    text = json.dumps(plan, indent=1, sort_keys=False)
    OUT.write_text(text + "\n")
    print(f"wrote {OUT} prefabs={len(plan['prefabs'])} instances={len(plan['instances'])} "
          f"parts={sum(len(p['parts']) for p in plan['prefabs'].values())} shellOps={len(sk['shells']['ops'])} "
          f"rings={len(gp['rings'])} pads={len(gp['pads'])} pods={len(gp['pods'])} coins={len(gp['coins'])} fx={len(sk['fx'])} "
          f"sha256={hashlib.sha256(text.encode()).hexdigest()[:12]}")
    for r in gp["rings"] + gp["pads"]:
        print(f"  {r['name']:32} st={r['station']:7.1f} built offset lateral/height={r['builtOffset']}")


if __name__ == "__main__":
    main()
