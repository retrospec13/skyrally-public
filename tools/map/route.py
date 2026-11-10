#!/usr/bin/env python3
"""Route math for SkyRally map plans (docs/MAP_PLAN_SCHEMA.md section 2 `route`).

An exact port of builder_dino4.luau `catmullRom` / `generateWaypoints` and its flex-scale bisection, plus the
station frame of src/shared/SplineUtils.luau `sampleAtStation`. Plain Python floats (no numpy) so two runs are
bit-identical; the adapter's TrackData waypoints come from here, not from the old Luau builder.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

Vec = tuple[float, float, float]
UP: Vec = (0.0, 1.0, 0.0)


def add(a: Vec, b: Vec) -> Vec:
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def sub(a: Vec, b: Vec) -> Vec:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def mul(a: Vec, k: float) -> Vec:
    return (a[0] * k, a[1] * k, a[2] * k)


def dot(a: Vec, b: Vec) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a: Vec, b: Vec) -> Vec:
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def mag(a: Vec) -> float:
    # Same formula as Vector3.Magnitude
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def unit(a: Vec) -> Vec:
    m = mag(a)
    return (a[0] / m, a[1] / m, a[2] / m)


def lerp(a: Vec, b: Vec, alpha: float) -> Vec:
    return (a[0] + (b[0] - a[0]) * alpha, a[1] + (b[1] - a[1]) * alpha, a[2] + (b[2] - a[2]) * alpha)


def catmull_rom(p0: Vec, p1: Vec, p2: Vec, p3: Vec, t: float) -> Vec:
    # builder_dino4.luau catmullRom, same operation order per component
    t2 = t * t
    t3 = t2 * t
    out = []
    for k in range(3):
        a0, a1, a2, a3 = p0[k], p1[k], p2[k], p3[k]
        out.append(0.5 * (
            (2 * a1)
            + (-a0 + a2) * t
            + (2 * a0 - 5 * a1 + 4 * a2 - a3) * t2
            + (-a0 + 3 * a1 - 3 * a2 + a3) * t3
        ))
    return (out[0], out[1], out[2])


@dataclass
class Node:
    pos: Vec
    bank: float
    flex: Vec = (0.0, 0.0, 0.0)


@dataclass
class Waypoint:
    pos: Vec
    bank: float
    station: float
    tangent: Vec = (0.0, 0.0, -1.0)


@dataclass
class Frame:
    pos: Vec
    tangent: Vec
    right: Vec
    up: Vec
    bank: float

    def offset(self, lateral: float = 0.0, height: float = 0.0) -> Vec:
        return add(add(self.pos, mul(self.right, lateral)), mul(self.up, height))

    def cframe(self, pos: Vec | None = None) -> list[float]:
        """12 CFrame components (GetComponents order) at pos, LookVector = tangent."""
        p = self.pos if pos is None else pos
        r, u, t = self.right, self.up, self.tangent
        # Columns are RightVector, UpVector, -LookVector
        return [p[0], p[1], p[2], r[0], u[0], -t[0], r[1], u[1], -t[1], r[2], u[2], -t[2]]


@dataclass
class Route:
    waypoints: list[Waypoint]
    length: float
    flex_scale: float
    evaluations: list[tuple[float, float]] = field(default_factory=list)  # (scale, length) per bisection step

    def frame_at(self, station: float) -> Frame:
        return frame_at(self.waypoints, self.length, station)


def nodes_from_plan(raw: list[dict]) -> list[Node]:
    out = []
    for n in raw:
        pos = n["pos"]
        flex = n.get("flex") or [0, 0, 0]
        out.append(Node((float(pos[0]), float(pos[1]), float(pos[2])), float(n.get("bank", 0)),
                        (float(flex[0]), float(flex[1]), float(flex[2]))))
    return out


def generate_waypoints(nodes: list[Node], flex_scale: float, steps_per_seg: int) -> tuple[list[Waypoint], float]:
    """builder_dino4.luau generateWaypoints: closed loop, wraparound neighbours, bank lerped per segment,
    station = running chord sum, closing waypoint = copy of the first at station = total."""
    count = len(nodes)
    adjusted = [add(n.pos, mul(n.flex, flex_scale)) for n in nodes]
    waypoints: list[Waypoint] = []
    total = 0.0
    for i in range(count):
        # Luau's 1-based ((i - 2) % count) + 1 etc. are these 0-based floored-mod indices
        p0 = adjusted[(i - 1) % count]
        p1 = adjusted[i]
        p2 = adjusted[(i + 1) % count]
        p3 = adjusted[(i + 2) % count]
        b1 = nodes[i].bank
        b2 = nodes[(i + 1) % count].bank
        for s in range(steps_per_seg):
            t = s / steps_per_seg
            pt = catmull_rom(p0, p1, p2, p3, t)
            bk = b1 + (b2 - b1) * t
            if waypoints:
                total = total + mag(sub(pt, waypoints[-1].pos))
            waypoints.append(Waypoint(pt, bk, total))
    total = total + mag(sub(waypoints[0].pos, waypoints[-1].pos))
    waypoints.append(Waypoint(waypoints[0].pos, waypoints[0].bank, total))
    return waypoints, total


def add_tangents(waypoints: list[Waypoint]) -> None:
    """tangent = unit(next.pos - pos); the closing waypoint copies the first tangent. A zero-length chord
    (duplicate control points) inherits its neighbour's tangent instead of dividing by zero."""
    n = len(waypoints)
    tangents: list[Vec | None] = []
    for i in range(n - 1):
        d = sub(waypoints[i + 1].pos, waypoints[i].pos)
        tangents.append(unit(d) if mag(d) > 1e-9 else None)
    known = [t for t in tangents if t is not None]
    carry: Vec = known[0] if known else (0.0, 0.0, -1.0)
    for i in range(n - 1):
        t = tangents[i]
        if t is not None:
            carry = t
        waypoints[i].tangent = carry
    waypoints[-1].tangent = waypoints[0].tangent


def solve(nodes: list[Node], target_length: float, scale_min: float = 0.0, scale_max: float = 3.5,
          iterations: int = 24, steps_per_seg: int = 9) -> Route:
    """The builder's bisection: len < target -> low = mid else high = mid; the LAST evaluated waypoints win
    (not the closest), exactly like the Luau loop."""
    low, high = scale_min, scale_max
    best: list[Waypoint] = []
    measured = 0.0
    mid = low
    evals = []
    for _ in range(iterations):
        mid = (low + high) * 0.5
        best, measured = generate_waypoints(nodes, mid, steps_per_seg)
        evals.append((mid, measured))
        if measured < target_length:
            low = mid
        else:
            high = mid
    if not best:
        best, measured = generate_waypoints(nodes, mid, steps_per_seg)
    add_tangents(best)
    return Route(best, measured, mid, evals)


def solve_plan_route(route: dict) -> Route:
    return solve(
        nodes_from_plan(route["nodes"]),
        float(route["targetLength"]),
        float(route.get("flexScaleMin", 0.0)),
        float(route.get("flexScaleMax", 3.5)),
        int(route.get("bisectIterations", 24)),
        int(route.get("samplesPerSegment", 9)),
    )


def sample_at_station(waypoints: list[Waypoint], total: float, station: float) -> tuple[Vec, Vec, float]:
    """SplineUtils.sampleAtStation: wrap, bisect the bracketing waypoints, lerp pos/bank, chord tangent."""
    if not waypoints:
        return (0.0, 146.0, 0.0), (0.0, 0.0, -1.0), 0.0
    s = station - math.floor(station / total) * total  # Luau's floored `%`
    if s < 0:
        s = s + total
    low, high = 0, len(waypoints) - 1
    while low < high - 1:
        mid = (low + high) // 2
        if waypoints[mid].station <= s:
            low = mid
        else:
            high = mid
    w1, w2 = waypoints[low], waypoints[high]
    span = max(0.01, w2.station - w1.station)
    alpha = min(1.0, max(0.0, (s - w1.station) / span))
    pos = lerp(w1.pos, w2.pos, alpha)
    bank = w1.bank + (w2.bank - w1.bank) * alpha
    raw = sub(w2.pos, w1.pos)
    tangent = unit(raw) if mag(raw) > 0.05 else w1.tangent
    return pos, tangent, bank


def frame_at(waypoints: list[Waypoint], total: float, station: float) -> Frame:
    """Station frame: right = tangent x up (horizontal, unit), up = right x tangent. Bank is reported, not
    applied: gameplay objects stand upright on banked stretches like the builder's."""
    pos, tangent, bank = sample_at_station(waypoints, total, station)
    r = cross(tangent, UP)
    rm = mag(r)
    right = (r[0] / rm, r[1] / rm, r[2] / rm) if rm > 1e-6 else (1.0, 0.0, 0.0)  # vertical tangent fallback
    up = unit(cross(right, tangent))
    return Frame(pos, tangent, right, up, bank)
