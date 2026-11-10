#!/usr/bin/env python3
"""Top-down concept layouts for the six V2 battle arenas (docs/design/BATTLE_MAPS_V2.md).

Writes docs/design/battle_maps_v2/<zone>.svg for DINO, SNOW, ISLAND, FOREST, SPACE and HUB. Each arena is data:
lanes (closed loops or links, lower or upper level, a width), ramps between the levels, jump pads, cover, 8 spawns,
pickups and the mode anchors (8 nests / home gates, the tag pedestal). Before drawing, check() proves what the doc
promises:
* every spawn, pickup and mode anchor sits on a lane, ramp or deck of its level (never on a prop or off the loop);
* every link lane and ramp ends on another lane, so the network has no dead ends;
* lane curves a car takes flat out are no tighter than CarConfig's ~94-stud turning radius at TOP_SPEED (128);
* the arena is 4-6 s across at 128 studs/s, with 8 spawns and 12+ pickups, and each pickup has at least two spawns
  within 3 s of travel (flat distance).

Concept only: nothing here builds an arena. Run: python3 tools/design/battle_maps_v2.py"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "design" / "battle_maps_v2"
TOP_SPEED = 128.0  # CarConfig.TOP_SPEED, studs/s
TURN_RADIUS = 94.0  # CarConfig HIGH_SPEED_TURN_FACTOR comment: ~94 studs flat out
LANE = 44.0  # main lane width (about 4 car lengths)
HALF = 380.0  # drawn extent, studs from the centre


# ---------------------------------------------------------------------------------------------------------- shapes
def circle(cx: float, cz: float, r: float, n: int = 64, a0: float = 0.0) -> list[tuple[float, float]]:
    return [(cx + r * math.cos(a0 + 2 * math.pi * k / n), cz + r * math.sin(a0 + 2 * math.pi * k / n)) for k in range(n)]


def ellipse(cx: float, cz: float, rx: float, rz: float, n: int = 72) -> list[tuple[float, float]]:
    return [(cx + rx * math.cos(2 * math.pi * k / n), cz + rz * math.sin(2 * math.pi * k / n)) for k in range(n)]


def rounded_rect(cx: float, cz: float, hx: float, hz: float, r: float, n: int = 12) -> list[tuple[float, float]]:
    pts = []
    for (sx, sz, a0) in ((1, 1, 0), (-1, 1, 90), (-1, -1, 180), (1, -1, 270)):
        ox, oz = cx + sx * (hx - r), cz + sz * (hz - r)
        for k in range(n + 1):
            a = math.radians(a0 + 90 * k / n)
            pts.append((ox + r * math.cos(a), oz + r * math.sin(a)))
    return pts


def on_closed(pts, t: float) -> tuple[float, float]:
    """Point at fraction t of a closed polyline's length."""
    segs = [(pts[i], pts[(i + 1) % len(pts)]) for i in range(len(pts))]
    lens = [math.dist(a, b) for a, b in segs]
    d = (t % 1.0) * sum(lens)
    for (a, b), l in zip(segs, lens):
        if d <= l:
            f = d / l if l else 0
            return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)
        d -= l
    return pts[0]


def tangent_closed(pts, t: float) -> tuple[float, float]:
    a, b = on_closed(pts, t - 0.002), on_closed(pts, t + 0.002)
    d = math.dist(a, b) or 1
    return ((b[0] - a[0]) / d, (b[1] - a[1]) / d)


def seg_dist(p, a, b) -> float:
    ax, az, bx, bz = a[0], a[1], b[0], b[1]
    dx, dz = bx - ax, bz - az
    L = dx * dx + dz * dz
    t = 0.0 if L == 0 else max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - az) * dz) / L))
    return math.hypot(p[0] - (ax + t * dx), p[1] - (az + t * dz))


# ---------------------------------------------------------------------------------------------------------- model
@dataclass
class Lane:
    name: str
    pts: list
    closed: bool = True
    level: str = "low"  # "low" or "up"
    width: float = LANE
    flat_out: bool = True  # a curve cars take at top speed (checked against TURN_RADIUS)

    def segments(self):
        n = len(self.pts)
        rng = range(n) if self.closed else range(n - 1)
        return [(self.pts[i], self.pts[(i + 1) % n]) for i in rng]

    def dist(self, p) -> float:
        return min(seg_dist(p, a, b) for a, b in self.segments())


@dataclass
class Deck:  # an open upper (or lower) floor: a polygon you can drive anywhere on
    name: str
    pts: list
    level: str = "up"

    def contains(self, p) -> bool:
        inside, n = False, len(self.pts)
        for i in range(n):
            (x1, z1), (x2, z2) = self.pts[i], self.pts[(i + 1) % n]
            if (z1 > p[1]) != (z2 > p[1]) and p[0] < (x2 - x1) * (p[1] - z1) / (z2 - z1) + x1:
                inside = not inside
        return inside


@dataclass
class Ramp:
    a: tuple  # low end
    b: tuple  # high end
    width: float = 40.0
    rise: float = 20.0

    @property
    def run(self) -> float:
        return math.dist(self.a, self.b)

    @property
    def deg(self) -> float:
        return math.degrees(math.atan2(self.rise, self.run))


@dataclass
class Arena:
    zone: str
    name: str
    tagline: str
    ground: str  # background colour
    low: str  # lower lane colour
    up: str  # upper lane colour
    accent: str
    lanes: list = field(default_factory=list)
    decks: list = field(default_factory=list)
    ramps: list = field(default_factory=list)
    jumps: list = field(default_factory=list)  # (pos, dir, label)
    cover: list = field(default_factory=list)  # ("rect", cx, cz, w, h, label) / ("circle", cx, cz, r, label)
    water: list = field(default_factory=list)  # polygons (decor: sea, lava) under the lanes: not drivable
    floors: list = field(default_factory=list)  # open drivable ground (low level) between the lanes
    spawns: list = field(default_factory=list)  # (pos, dir, level)
    pickups: list = field(default_factory=list)  # (pos, level)
    nests: list = field(default_factory=list)  # (pos, level): egg nests / hoard home gates, one per seat
    tag: tuple | None = None  # item-tag pedestal (pos, level)
    labels: list = field(default_factory=list)  # (pos, text)
    notes: list = field(default_factory=list)

    def surfaces(self, level: str):
        return [l for l in self.lanes if l.level == level], [d for d in self.decks if d.level == level]

    def on_level(self, p, level: str, margin: float = 4.0) -> bool:
        lanes, decks = self.surfaces(level)
        if any(l.dist(p) <= l.width / 2 - margin for l in lanes) or any(d.contains(p) for d in decks):
            return True
        if level == "low" and any(Deck("floor", f).contains(p) for f in self.floors):
            return True
        return any(seg_dist(p, r.a, r.b) <= r.width / 2 - margin for r in self.ramps)

    def extent(self) -> tuple[float, float]:
        xs = [p[0] for l in self.lanes for p in l.pts] + [p[0] for d in self.decks for p in d.pts]
        zs = [p[1] for l in self.lanes for p in l.pts] + [p[1] for d in self.decks for p in d.pts]
        return max(xs) - min(xs) + LANE, max(zs) - min(zs) + LANE


def curvature_radius(a, b, c) -> float:
    ab, bc, ca = math.dist(a, b), math.dist(b, c), math.dist(c, a)
    area2 = abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]))
    return math.inf if area2 < 1e-9 else ab * bc * ca / (2 * area2)


def check(ar: Arena) -> dict:
    errs = []
    for kind, items in (("spawn", [(p, lv) for p, _d, lv in ar.spawns]), ("pickup", ar.pickups), ("nest", ar.nests),
                        ("tag", [ar.tag] if ar.tag else [])):
        for i, (p, lv) in enumerate(items):
            if not ar.on_level(p, lv):
                errs.append(f"{ar.zone} {kind} {i + 1} {p} is not on a {lv} lane, deck or ramp")
    for l in ar.lanes:
        if not l.closed:
            for end in (l.pts[0], l.pts[-1]):
                others = [o for o in ar.lanes if o is not l and o.level == l.level]
                ok = any(o.dist(end) <= o.width / 2 + 2 for o in others) or any(
                    d.contains(end) for d in ar.decks if d.level == l.level) or any(
                    min(math.dist(end, r.a), math.dist(end, r.b)) <= r.width for r in ar.ramps)
                if not ok:
                    errs.append(f"{ar.zone} lane {l.name} dead-ends at {end}")
        if l.flat_out:
            pts = l.pts
            n = len(pts)
            idx = range(n) if l.closed else range(1, n - 1)
            for i in idx:
                r = curvature_radius(pts[i - 1], pts[i], pts[(i + 1) % n])
                if r < TURN_RADIUS - 1:
                    errs.append(f"{ar.zone} lane {l.name} bends at radius {r:.0f} < {TURN_RADIUS} near {pts[i]}")
                    break
    for i, r in enumerate(ar.ramps):
        if r.deg > 12.5:
            errs.append(f"{ar.zone} ramp {i + 1} is {r.deg:.1f} deg (> 12)")
        if not ar.on_level(r.a, "low", margin=-r.width / 2) or not ar.on_level(r.b, "up", margin=-r.width / 2):
            errs.append(f"{ar.zone} ramp {i + 1} does not join a low lane to an upper one")
    for i, (p, _d, label) in enumerate(ar.jumps):
        if not (ar.on_level(p, "low") or ar.on_level(p, "up")):
            errs.append(f"{ar.zone} jump {label} is off every lane and floor")
    for c in ar.cover:  # cover stands on open floor beside the lanes, never across a lane or a ramp
        p, r = (c[1], c[2]), (c[3] if c[0] == "circle" else math.hypot(c[3], c[4]) / 2)
        for l in ar.lanes:
            if l.level == "low" and l.dist(p) < l.width / 2 + r - 1:
                errs.append(f"{ar.zone} cover {c[-1]} stands on lane {l.name}")
        for rp in ar.ramps:
            if seg_dist(p, rp.a, rp.b) < rp.width / 2 + r - 1:
                errs.append(f"{ar.zone} cover {c[-1]} stands on a ramp")
    w, h = ar.extent()
    secs = max(w, h) / TOP_SPEED
    if not 4.0 <= secs <= 6.0:
        errs.append(f"{ar.zone} is {secs:.1f} s across (want 4-6)")
    if len(ar.spawns) != 8:
        errs.append(f"{ar.zone} has {len(ar.spawns)} spawns")
    if len(ar.pickups) < 12:
        errs.append(f"{ar.zone} has {len(ar.pickups)} pickups")
    if len(ar.nests) != 8:
        errs.append(f"{ar.zone} has {len(ar.nests)} nests/home gates")
    for i, (p, _lv) in enumerate(ar.pickups):
        near = sum(math.dist(p, s[0]) <= 3 * TOP_SPEED for s in ar.spawns)
        if near < 2:
            errs.append(f"{ar.zone} pickup {i + 1} has {near} spawns within 3 s")
    if errs:
        raise SystemExit("\n".join(errs))
    return {"w": w, "h": h, "secs": secs, "ramps": [(round(r.run), round(r.deg, 1)) for r in ar.ramps]}


# ---------------------------------------------------------------------------------------------------------- arenas
def ring_spawns(loop, n: int = 8, t0: float = 0.0, reverse_every: int = 0) -> list:
    out = []
    for k in range(n):
        t = t0 + k / n
        d = tangent_closed(loop, t)
        if reverse_every and k % reverse_every == 1:
            d = (-d[0], -d[1])
        out.append((on_closed(loop, t), d, "low"))
    return out


def clear_t0(ar: Arena, loop, n: int = 8) -> float:
    """The ring offset whose n evenly spaced seats (and the nests just ahead of them) stand farthest from every
    junction (link-lane ends), ramp foot and pickup already placed: nobody spawns in a crossing."""
    avoid = [p for l in ar.lanes if not l.closed for p in (l.pts[0], l.pts[-1])]
    avoid += [r.a for r in ar.ramps] + [p for p, _lv in ar.pickups]
    best, best_d = 0.0, -1.0
    for j in range(200):
        t0 = j / 200 / n
        d = min(math.dist(on_closed(loop, t0 + k / n + dt), q) for k in range(n) for dt in (0.0, 0.028)
                for q in avoid) if avoid else 0.0
        if d > best_d:
            best, best_d = t0, d
    return best


def ring_nests(loop, t0: float, n: int = 8) -> list:
    """One nest / home gate per seat, 40-50 studs ahead of each ring spawn (seat i's is N i)."""
    return [(on_closed(loop, t0 + k / n + 0.028), "low") for k in range(n)]


def island() -> Arena:
    a = Arena("ISLAND", "Galleon Cove Circuit", "the cove ring, the dune figure-8 and the galleon as a bypass",
              "#7cc8d8", "#e8d6a4", "#c79a5c", "#2f6f8f")
    ring = ellipse(0, 20, 290, 230)
    a.water = [ellipse(0, 20, 370, 320)]
    a.floors = [ellipse(0, 20, 312, 252)]  # the sand flats inside the ring
    a.lanes.append(Lane("cove ring", ring))
    # figure-8 through the dune: two diagonals cross on the dune crest (upper)
    for name, s, e in (("NW-SE dune lane", (-205, -142), (205, 182)), ("NE-SW dune lane", (205, -142), (-205, 182))):
        a.lanes.append(Lane(name + " (low)", [s, (s[0] * 0.55, s[1] * 0.55 + 20 * 0.45), ], closed=False))
        a.lanes.append(Lane(name + " (low) b", [(e[0] * 0.55, e[1] * 0.55 + 20 * 0.45), e], closed=False))
    a.decks.append(Deck("Plank Dune crest (+8)", ellipse(0, 20, 120, 80, 36)))
    for s in ((-205, -142), (205, -142), (205, 182), (-205, 182)):
        lo = (s[0] * 0.55, s[1] * 0.55 + 9)
        hi = (s[0] * 0.38, s[1] * 0.38 + 12.4)
        a.ramps.append(Ramp(lo, hi, 44, 8))
    # galleon bypass on the north arc: gangway up at the bow, deck west-east, stern ramp down
    a.decks.append(Deck("galleon main deck (+12)", [(-120, -268), (120, -268), (138, -246), (120, -224), (-120, -224),
                                                    (-138, -246)]))
    a.ramps.append(Ramp((-215, -166), (-128, -238), 32, 12))
    a.ramps.append(Ramp((215, -166), (128, -238), 32, 12))
    a.jumps += [((0, 96), (0, 1), "dune kicker"), ((0, -222), (0, 1), "the plank (one-way drop)")]
    a.cover += [("circle", -205, 20, 16, "palms"), ("circle", 205, 20, 16, "palms"), ("rect", 0, 175, 60, 18,
                "cargo crates"), ("rect", -60, -150, 26, 16, "rowboat"), ("rect", 60, -150, 26, 16, "chest pile")]
    a.pickups = [(on_closed(ring, k / 8), "low") for k in range(8)]
    a.pickups += [((-60, 20), "up"), ((60, 20), "up"), ((-150, -82), "low"), ((150, -82), "low"),
                  ((-150, 122), "low"), ((150, 122), "low")]
    t0 = clear_t0(a, ring)
    a.spawns, a.nests = ring_spawns(ring, 8, t0, reverse_every=2), ring_nests(ring, t0)
    a.tag = ((0, 20), "up")
    a.labels += [((0, -290), "GALLEON (bypass, +12)"), ((0, 64), "PLANK DUNE (+8)"), ((-330, 20), "SHALLOWS"),
                 ((0, 300), "BEACH")]
    a.notes += ["Tide event: one step at 120 s floods the shallows outside the ring only; ring, dune and deck stay dry "
                "(target: about 85% of the drivable area)."]
    return a


def dino() -> Arena:
    a = Arena("DINO", "Altar Crater", "three terraces, tunnels under the middle ring, the altar on top",
              "#5a4636", "#b9a07c", "#d8c49a", "#d9622b")
    outer = circle(0, 0, 300, 72)
    inner = circle(0, 0, 165, 56, a0=math.pi / 8)
    a.water = [circle(0, 0, 360, 48)]
    a.lanes.append(Lane("outer ring (floor)", outer))
    a.lanes.append(Lane("middle terrace (+16)", inner, level="up"))
    # four spokes on the floor pass UNDER the middle terrace through the dual-level tunnels to the altar roundabout
    a.lanes.append(Lane("altar roundabout (floor)", circle(0, 0, 70, 32), flat_out=False))
    for ang in (0, 90, 180, 270):
        c, s = math.cos(math.radians(ang)), math.sin(math.radians(ang))
        a.lanes.append(Lane(f"spoke {ang}", [(c * 278, s * 278), (c * 92, s * 92)], closed=False))
    # ramps: outer floor up to the middle terrace, two per quadrant (both ends), alternating direction
    for k in range(4):
        base = math.radians(45 + 90 * k)
        for off in (-0.22, 0.22):
            lo = (math.cos(base + off) * 282, math.sin(base + off) * 282)
            hi = (math.cos(base + off * 0.6) * 182, math.sin(base + off * 0.6) * 182)
            a.ramps.append(Ramp(lo, hi, 40, 16))
    a.jumps += [((math.cos(math.radians(a_)) * 165, math.sin(math.radians(a_)) * 165),
                 (-math.cos(math.radians(a_)), -math.sin(math.radians(a_))), "terrace hop") for a_ in (0, 180)]
    a.cover += [("circle", 0, 0, 34, "volcanic altar")]
    for j, name in enumerate(("basalt organ", "bone pile", "basalt organ", "bone pile")):
        ang = math.radians(22.5 + 90 * j)
        a.cover.append(("circle", 232 * math.cos(ang), 232 * math.sin(ang), 12, name))
    a.pickups = [(on_closed(outer, k / 8), "low") for k in range(8)]
    a.pickups += [(on_closed(inner, k / 4 + 1 / 16), "up") for k in range(4)]
    a.pickups += [((0, 70), "low"), ((0, -70), "low")]
    t0 = clear_t0(a, outer)
    a.spawns, a.nests = ring_spawns(outer, 8, t0, reverse_every=2), ring_nests(outer, t0)
    a.tag = ((-70, 0), "low")
    a.labels += [((0, -195), "MIDDLE TERRACE (+16)"), ((0, 0), "ALTAR"), ((0, -335), "CRATER FLOOR"),
                 ((120, 26), "TUNNEL")]
    a.notes += ["The spokes run under the middle terrace through DualLevelTunnelPortal pieces: a crossing with no "
                "junction, so a chase can split high and low."]
    return a


def snow() -> Arena:
    a = Arena("SNOW", "Twin Lakes", "a figure-8 over two frozen lakes, the crossing on an ice bridge",
              "#e9f1f7", "#b9d6ea", "#8fb6d3", "#2c5d8a")
    west = circle(-130, 0, 130, 56)
    east = circle(130, 0, 130, 56, a0=math.pi)
    a.floors = [rounded_rect(0, 0, 352, 252, 142), circle(-130, 0, 108, 40), circle(130, 0, 108, 40)]
    a.lanes.append(Lane("west lake loop", west))
    a.lanes.append(Lane("east lake loop", east))
    stadium = rounded_rect(0, 0, 330, 230, 120)
    a.lanes.append(Lane("snowbank ring", stadium))
    for x in (-130, 130):
        a.lanes.append(Lane(f"spoke N {x}", [(x, -130), (x, -208)], closed=False))
        a.lanes.append(Lane(f"spoke S {x}", [(x, 130), (x, 208)], closed=False))
    # the crossing: the two lake loops meet at the centre (the figure-8 node); the E-W line goes over it on the bridge
    a.decks.append(Deck("ice bridge (+16)", [(-60, -26), (60, -26), (60, 26), (-60, 26)]))
    a.ramps += [Ramp((-150, -64), (-52, -10), 40, 16), Ramp((150, 64), (52, 10), 40, 16)]
    a.lanes.append(Lane("bridge approach W", [(-330, -64), (-150, -64)], closed=False, flat_out=False))
    a.lanes.append(Lane("bridge approach E", [(150, 64), (330, 64)], closed=False, flat_out=False))
    a.jumps += [((-130, -130), (0, 1), "snow kicker into the lake"), ((130, 130), (0, -1), "snow kicker into the lake")]
    a.cover += [("rect", -150, 20, 30, 20, "fishing hut"), ("rect", 150, -20, 30, 20, "fishing hut"),
                ("circle", 0, -160, 16, "snowman"), ("circle", 0, 160, 16, "sled and presents")]
    a.pickups = [(on_closed(west, k / 4 + 1 / 8), "low") for k in range(4)]
    a.pickups += [(on_closed(east, k / 4 + 1 / 8), "low") for k in range(4)]
    a.pickups += [((0, 0), "up"), ((-130, -208), "low"), ((130, 208), "low"), ((-130, 208), "low"),
                  ((130, -208), "low"), ((-292, -64), "low")]
    t0 = clear_t0(a, stadium)
    a.spawns, a.nests = ring_spawns(stadium, 8, t0, reverse_every=2), ring_nests(stadium, t0)
    a.tag = ((0, 0), "up")
    a.labels += [((-130, 60), "WEST LAKE (ice)"), ((130, 60), "EAST LAKE (ice)"), ((0, -42), "ICE BRIDGE (+16)"),
                 ((0, 268), "SNOWBANK RING")]
    a.notes += ["Lake interiors and the snowfield are open drivable floor (ice, low fishing-hut cover), not a hazard."]
    return a


def forest() -> Arena:
    a = Arena("FOREST", "Mill Commons", "a field ring, the mill-yard loop and the aqueduct over the millpond",
              "#8cbf6a", "#d8c69a", "#b7a07a", "#7a4f2a")
    outer = rounded_rect(0, 0, 300, 280, 130)
    yard = circle(0, 0, 112, 48)
    a.floors = [rounded_rect(0, 0, 322, 302, 152)]  # meadow inside the ring
    a.water = [ellipse(150, 140, 95, 70, 40)]
    a.lanes.append(Lane("field ring", outer))
    a.lanes.append(Lane("mill-yard loop", yard))
    for ang in (0, 90, 180, 270):
        c, s = math.cos(math.radians(ang)), math.sin(math.radians(ang))
        rx = 278 if c else 0
        rz = 258 if s else 0
        a.lanes.append(Lane(f"lane {ang}", [(c * 112, s * 112), (c * rx if c else 0, s * rz if s else 0)],
                            closed=False))
    # the aqueduct: a raised diagonal over the millpond from the yard loop to the field ring (ramps both ends)
    a.decks.append(Deck("aqueduct (+12)", [(116, 144), (144, 116), (199, 171), (171, 199)]))
    a.ramps += [Ramp((79, 79), (136, 136), 40, 12), Ramp((258, 238), (188, 188), 40, 12)]
    a.jumps += [((-210, -200), (1, 1), "hay-bale kicker"), ((-80, 0), (1, 0), "barn ramp")]
    a.cover += [("circle", 0, 0, 40, "windmill"), ("rect", -150, -150, 40, 20, "hay bales"),
                ("rect", -150, 150, 30, 20, "produce cart"), ("circle", 150, -150, 14, "stone well")]
    a.pickups = [(on_closed(outer, k / 8 + 1 / 32), "low") for k in range(8)]
    a.pickups += [(on_closed(yard, k / 4 + 1 / 8), "low") for k in range(4)]
    a.pickups += [((158, 158), "up"), ((0, -190), "low")]
    t0 = clear_t0(a, outer)
    a.spawns, a.nests = ring_spawns(outer, 8, t0, reverse_every=2), ring_nests(outer, t0)
    a.tag = ((0, -112), "low")
    a.labels += [((0, 26), "MILL"), ((200, 120), "AQUEDUCT (+12)"), ((150, 196), "MILLPOND"),
                 ((0, -312), "FIELD RING")]
    a.notes += ["Hoard: the 8 home gates are drive-through barn doors on the field ring (a ring per seat, so no two "
                "entrants share one)."]
    return a


def space() -> Arena:
    a = Arena("SPACE", "Neon Interchange", "a 3x3 street grid under a rooftop ring, hover pads up",
              "#151a33", "#3a4270", "#6a4fb0", "#29e0ff")
    a.water = []
    loop = rounded_rect(0, 0, 300, 300, 110)
    a.lanes.append(Lane("boulevard", loop))
    for x in (-100, 100):
        a.lanes.append(Lane(f"avenue {x}", [(x, -278), (x, 278)], closed=False))
    for z in (-100, 100):
        a.lanes.append(Lane(f"street {z}", [(-278, z), (278, z)], closed=False))
    roof = circle(0, 0, 200, 64, a0=math.pi / 4)
    a.lanes.append(Lane("rooftop ring (+16)", roof, level="up"))
    for ang in (0, 90, 180, 270):
        c, s = math.cos(math.radians(ang)), math.sin(math.radians(ang))
        # both ends: each quarter of the rooftop ring has a ramp down at each end
        for off in (-1, 1):
            hi = (c * 200 - s * off * 60, s * 200 + c * off * 60)
            lo = (c * 282 - s * off * 60, s * 282 + c * off * 60)
            a.ramps.append(Ramp(lo, hi, 40, 16))
    a.jumps += [((0, -100), (0, -1), "hover pad up to the roof"), ((0, 100), (0, 1), "hover pad up to the roof"),
                ((-100, 0), (-1, 0), "hover pad"), ((100, 0), (1, 0), "hover pad")]
    a.cover += [("rect", 0, 0, 60, 60, "dome hall"), ("rect", -200, -200, 50, 50, "tower"),
                ("rect", 200, -200, 50, 50, "tower"), ("rect", -200, 200, 50, 50, "tower"),
                ("rect", 200, 200, 50, 50, "tower")]
    a.pickups = [((x, z), "low") for x in (-100, 100) for z in (-248, 248)]
    a.pickups += [((x, z), "low") for z in (-100, 100) for x in (-248, 248)]
    a.pickups += [(on_closed(roof, k / 4 + 1 / 8), "up") for k in range(4)]
    a.pickups += [((100, 100), "low"), ((-100, 100), "low")]
    t0 = clear_t0(a, loop)
    a.spawns, a.nests = ring_spawns(loop, 8, t0, reverse_every=2), ring_nests(loop, t0)
    a.tag = ((-100, -100), "low")
    a.labels += [((0, 6), "DOME"), ((0, -222), "ROOFTOP RING (+16)"), ((0, -330), "BOULEVARD")]
    a.notes += ["Forks every 100 studs (the grid): the most junctions of the six; neon lane colours code the four "
                "quarters (cyan, amber, magenta, lime)."]
    return a


def hub() -> Arena:
    a = Arena("HUB", "Harbour Block Fort", "four colour forts, bridges on top, the fountain roundabout",
              "#a9c7d9", "#d9cbb2", "#c4a983", "#c0392b")
    outer = rounded_rect(0, 0, 300, 300, 115)
    a.lanes.append(Lane("promenade ring", outer))
    a.lanes.append(Lane("fountain roundabout", circle(0, 0, 70, 32), flat_out=False))
    for ang in (0, 90, 180, 270):
        c, s = math.cos(math.radians(ang)), math.sin(math.radians(ang))
        a.lanes.append(Lane(f"lane {ang}", [(c * 92, s * 92), (c * 278, s * 278)], closed=False))
    forts = {"RED": (-175, -175), "BLUE": (175, -175), "GREEN": (175, 175), "YELLOW": (-175, 175)}
    for name, (fx, fz) in forts.items():
        a.decks.append(Deck(f"{name} fort top (+20)", [(fx - 55, fz - 55), (fx + 55, fz - 55), (fx + 55, fz + 55),
                                                       (fx - 55, fz + 55)]))
    # bridges join the fort tops (upper ring), crossing over the four lanes
    for (x1, z1), (x2, z2) in (((-126, -175), (126, -175)), ((175, -126), (175, 126)), ((126, 175), (-126, 175)),
                               ((-175, 126), (-175, -126))):
        a.lanes.append(Lane("bridge", [(x1, z1), (x2, z2)], closed=False, level="up", width=36))
    # each fort: two ramps up from the promenade ring, one on each outer face (a way off at both ends)
    for (fx, fz) in forts.values():
        sx, sz = (1 if fx > 0 else -1), (1 if fz > 0 else -1)
        a.ramps.append(Ramp((fx + sx * 103, fz - sz * 40), (fx + sx * 40, fz - sz * 40), 40, 12))
        a.ramps.append(Ramp((fx - sx * 40, fz + sz * 103), (fx - sx * 40, fz + sz * 40), 40, 12))
    a.jumps += [((70, 0), (1, 0), "roundabout kicker"), ((-175, 0), (-1, 0), "bridge drop (one-way)")]
    a.cover += [("circle", 0, 0, 30, "fountain"), ("rect", -60, -230, 30, 14, "market stall"),
                ("rect", 60, 230, 30, 14, "market stall"), ("rect", 230, 60, 14, 30, "harbour crates"),
                ("rect", -230, -60, 14, 30, "harbour crates")]
    a.pickups = [((fx, fz), "up") for fx, fz in forts.values()]
    a.pickups += [((0, -250), "low"), ((250, 0), "low"), ((0, 250), "low"), ((-250, 0), "low")]
    a.pickups += [(on_closed(outer, k / 4 + 1 / 16), "low") for k in range(4)]
    a.pickups += [((0, -175), "up"), ((0, 175), "up")]
    t0 = clear_t0(a, outer)
    a.spawns, a.nests = ring_spawns(outer, 8, t0, reverse_every=2), ring_nests(outer, t0)
    a.tag = ((0, -70), "low")
    a.labels += [((-175, -238), "RED FORT"), ((175, -238), "BLUE FORT"), ((175, 248), "GREEN FORT"),
                 ((-175, 248), "YELLOW FORT"), ((0, 6), "FOUNTAIN")]
    a.notes += ["MK64 Block Fort homage: each fort is colour coded (the Double Deck complaint), two levels, ramps at both "
                "ends; bridges are the upper ring."]
    return a


ARENAS = [dino, snow, island, forest, space, hub]


# ---------------------------------------------------------------------------------------------------------- SVG
def svg(ar: Arena, stats: dict) -> str:
    W, H = 980, 1060
    ox, oz, k = 490, 520, 1.15  # centre on the canvas, px per stud

    def P(p):
        return f"{ox + p[0] * k:.1f},{oz + p[1] * k:.1f}"

    def poly(pts, closed=True):
        return ("M" + " L".join(P(p) for p in pts) + (" Z" if closed else ""))

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
           f'font-family="Helvetica, Arial, sans-serif">',
           '<defs><pattern id="hatch" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
           '<rect width="8" height="8" fill="#f2c14e"/><line x1="0" y1="0" x2="0" y2="8" stroke="#8a5a00" '
           'stroke-width="3"/></pattern>'
           '<marker id="arr" viewBox="0 0 10 10" refX="5" refY="5" markerWidth="5" markerHeight="5" orient="auto">'
           '<path d="M0,0 L10,5 L0,10 z" fill="#222"/></marker></defs>',
           f'<rect width="{W}" height="{H}" fill="#fbfaf6"/>',
           f'<text x="24" y="40" font-size="26" font-weight="700" fill="#222">{ar.zone}: {ar.name}</text>',
           f'<text x="24" y="66" font-size="15" fill="#444">{ar.tagline}. {stats["w"]:.0f} x {stats["h"]:.0f} studs, '
           f'{stats["secs"]:.1f} s across at 128 studs/s, 8 entrants.</text>',
           f'<rect x="{ox - HALF * k}" y="{oz - HALF * k}" width="{2 * HALF * k}" height="{2 * HALF * k}" '
           f'fill="{ar.ground}" rx="8"/>']
    for f in ar.floors:
        out.append(f'<path d="{poly(f)}" fill="{ar.low}" fill-opacity="0.45" stroke="{ar.low}" stroke-width="2"/>')
    for wpoly in ar.water:
        lava = ar.zone == "DINO"
        out.append(f'<path d="{poly(wpoly)}" fill="{"#e9b04a" if lava else "#3f8fb5"}" '
                   f'fill-opacity="{0.35 if lava else 0.5}"/>')
    for l in ar.lanes:
        if l.level != "low":
            continue
        out.append(f'<path d="{poly(l.pts, l.closed)}" fill="none" stroke="#00000033" stroke-width="{(l.width + 6) * k}" '
                   'stroke-linejoin="round" stroke-linecap="round"/>')
        out.append(f'<path d="{poly(l.pts, l.closed)}" fill="none" stroke="{ar.low}" stroke-width="{l.width * k}" '
                   'stroke-linejoin="round" stroke-linecap="round"/>')
    for c in ar.cover:
        if c[0] == "circle":
            out.append(f'<circle cx="{ox + c[1] * k}" cy="{oz + c[2] * k}" r="{c[3] * k}" fill="#6b6b5e" '
                       'stroke="#333" stroke-width="1.5"/>')
        else:
            out.append(f'<rect x="{ox + (c[1] - c[3] / 2) * k}" y="{oz + (c[2] - c[4] / 2) * k}" width="{c[3] * k}" '
                       f'height="{c[4] * k}" fill="#6b6b5e" stroke="#333" stroke-width="1.5"/>')
    for r in ar.ramps:
        dx, dz = r.b[0] - r.a[0], r.b[1] - r.a[1]
        L = math.hypot(dx, dz) or 1
        nx, nz = -dz / L * r.width / 2, dx / L * r.width / 2
        quad = [(r.a[0] + nx, r.a[1] + nz), (r.b[0] + nx, r.b[1] + nz), (r.b[0] - nx, r.b[1] - nz),
                (r.a[0] - nx, r.a[1] - nz)]
        out.append(f'<path d="{poly(quad)}" fill="url(#hatch)" stroke="#8a5a00" stroke-width="1.5"/>')
    for d in ar.decks:
        out.append(f'<path d="{poly(d.pts)}" fill="{ar.up}" stroke="#222" stroke-width="2.5"/>')
    for l in ar.lanes:
        if l.level != "up":
            continue
        out.append(f'<path d="{poly(l.pts, l.closed)}" fill="none" stroke="#222" stroke-width="{(l.width + 5) * k}" '
                   'stroke-linejoin="round" stroke-linecap="round"/>')
        out.append(f'<path d="{poly(l.pts, l.closed)}" fill="none" stroke="{ar.up}" stroke-width="{l.width * k}" '
                   'stroke-linejoin="round" stroke-linecap="round"/>')
    for r in ar.ramps:
        out.append(f'<line x1="{ox + r.a[0] * k}" y1="{oz + r.a[1] * k}" x2="{ox + (r.a[0] + (r.b[0] - r.a[0]) * 0.8) * k}" '
                   f'y2="{oz + (r.a[1] + (r.b[1] - r.a[1]) * 0.8) * k}" stroke="#222" stroke-width="2" '
                   'marker-end="url(#arr)"/>')
    for (p, d, label) in ar.jumps:
        cx, cz = ox + p[0] * k, oz + p[1] * k
        ang = math.degrees(math.atan2(d[1], d[0]))
        out.append(f'<g transform="translate({cx:.1f},{cz:.1f}) rotate({ang:.1f})">'
                   '<path d="M-12,-10 L0,0 L-12,10 M-2,-10 L10,0 L-2,10" fill="none" stroke="#ff7a00" '
                   'stroke-width="4" stroke-linecap="round"/></g>')
    for i, (p, lv) in enumerate(ar.nests):
        out.append(f'<rect x="{ox + p[0] * k - 9}" y="{oz + p[1] * k - 9}" width="18" height="18" rx="4" '
                   f'fill="#fff" stroke="{ar.accent}" stroke-width="3"/><text x="{ox + p[0] * k}" '
                   f'y="{oz + p[1] * k + 4}" font-size="10" text-anchor="middle" fill="{ar.accent}" '
                   f'font-weight="700">N{i + 1}</text>')
    for i, (p, lv) in enumerate(ar.pickups):
        out.append(f'<circle cx="{ox + p[0] * k:.1f}" cy="{oz + p[1] * k:.1f}" r="9" fill="#e83e8c" '
                   f'stroke="#fff" stroke-width="2"/><text x="{ox + p[0] * k:.1f}" y="{oz + p[1] * k + 3.5:.1f}" '
                   f'font-size="9" text-anchor="middle" fill="#fff" font-weight="700">{i + 1}</text>')
    for i, (p, d, lv) in enumerate(ar.spawns):
        cx, cz = ox + p[0] * k, oz + p[1] * k
        ang = math.degrees(math.atan2(d[1], d[0]))
        out.append(f'<g transform="translate({cx:.1f},{cz:.1f}) rotate({ang:.1f})"><path d="M14,0 L-8,-10 L-8,10 Z" '
                   'fill="#1f9d55" stroke="#fff" stroke-width="2"/></g>'
                   f'<text x="{cx:.1f}" y="{cz - 14:.1f}" font-size="11" text-anchor="middle" fill="#0d5e31" '
                   f'font-weight="700" stroke="#ffffff" stroke-width="3" stroke-linejoin="round">S{i + 1}</text>'
                   f'<text x="{cx:.1f}" y="{cz - 14:.1f}" font-size="11" text-anchor="middle" fill="#0d5e31" '
                   f'font-weight="700">S{i + 1}</text>')
    if ar.tag:
        p = ar.tag[0]
        out.append(f'<path d="M{ox + p[0] * k},{oz + p[1] * k - 13} L{ox + p[0] * k + 11},{oz + p[1] * k + 8} '
                   f'L{ox + p[0] * k - 11},{oz + p[1] * k + 8} Z" fill="#ffd400" stroke="#7a5d00" stroke-width="2"/>')
    for p, text in ar.labels:
        for stroke in ('stroke="#ffffff" stroke-width="4" stroke-linejoin="round"', ''):
            out.append(f'<text x="{ox + p[0] * k:.1f}" y="{oz + p[1] * k:.1f}" font-size="13" text-anchor="middle" '
                       f'font-weight="700" fill="#111" {stroke}>{text}</text>')
    # scale bar: 128 studs = 1 s at top speed
    sx, sy = 40, H - 60
    out.append(f'<rect x="{sx}" y="{sy}" width="{128 * k}" height="8" fill="#222"/>'
               f'<rect x="{sx + 128 * k}" y="{sy}" width="{128 * k}" height="8" fill="#fff" stroke="#222"/>'
               f'<text x="{sx}" y="{sy - 6}" font-size="12" fill="#222">0</text>'
               f'<text x="{sx + 128 * k}" y="{sy - 6}" font-size="12" fill="#222" text-anchor="middle">128 studs = 1 s</text>'
               f'<text x="{sx + 256 * k}" y="{sy - 6}" font-size="12" fill="#222" text-anchor="middle">256 = 2 s</text>'
               f'<text x="{sx}" y="{sy + 24}" font-size="11" fill="#444">at 128 studs/s (CarConfig.TOP_SPEED); '
               f'lanes {LANE:.0f} wide, ramps 10-12 deg</text>')
    # legend: two columns
    lx, ly = 560, H - 128
    out.append(f'<rect x="{lx - 12}" y="{ly - 18}" width="420" height="124" fill="#fff" stroke="#ccc" rx="6"/>')
    left = [(f'<rect x="{lx}" y="{{y}}" width="26" height="12" fill="{ar.low}" stroke="#222"/>', "lane (main line)"),
            (f'<rect x="{lx}" y="{{y}}" width="26" height="12" fill="{ar.low}" fill-opacity="0.45"/>',
             "open floor (drivable)"),
            (f'<rect x="{lx}" y="{{y}}" width="26" height="12" fill="{ar.up}" stroke="#222" stroke-width="2"/>',
             "upper level"),
            (f'<rect x="{lx}" y="{{y}}" width="26" height="12" fill="url(#hatch)" stroke="#8a5a00"/>',
             "ramp (arrow = up)"),
            (f'<rect x="{lx}" y="{{y}}" width="26" height="12" fill="#6b6b5e"/>', "low cover / prop")]
    rx = lx + 210
    right = [(f'<path d="M{rx},{{y}} l22,6 l-22,6 z" fill="#1f9d55"/>', "spawn S1-S8 (heading)"),
             (f'<circle cx="{rx + 11}" cy="{{yc}}" r="7" fill="#e83e8c"/>', "pickup"),
             (f'<rect x="{rx + 3}" y="{{y}}" width="14" height="13" rx="3" fill="#fff" stroke="{ar.accent}" '
              f'stroke-width="3"/>', "nest / home gate N1-N8"),
             (f'<path d="M{rx + 3},{{y2}} l8,-13 l8,13 z" fill="#ffd400" stroke="#7a5d00"/>', "tag pedestal"),
             (f'<path d="M{rx},{{y}} l9,6 l-9,6 M{rx + 10},{{y}} l9,6 l-9,6" fill="none" stroke="#ff7a00" '
              f'stroke-width="3"/>', "jump / kicker")]
    for col, x in ((left, lx), (right, rx)):
        for j, (shape, text) in enumerate(col):
            y = ly - 6 + j * 22
            out.append(shape.format(y=y, yc=y + 6, y2=y + 13))
            out.append(f'<text x="{x + 30}" y="{y + 11}" font-size="12" fill="#222">{text}</text>')
    out.append("</svg>")
    return "\n".join(out)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for make in ARENAS:
        ar = make()
        stats = check(ar)
        (OUT / f"{ar.zone.lower()}.svg").write_text(svg(ar, stats))
        print(f"{ar.zone:7s} {ar.name:22s} {stats['w']:.0f}x{stats['h']:.0f} studs {stats['secs']:.1f} s across, "
              f"{len(ar.pickups)} pickups, ramps (run, deg) {stats['ramps']}")


if __name__ == "__main__":
    main()
