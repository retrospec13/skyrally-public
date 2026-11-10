#!/usr/bin/env python3
"""SPACE-4 rooftop wall-climb shortcut (TRACK_VARIETY 5a, SPACE-4 launch upgrade): pure geometry, no plan objects.

The line leaves the road on a slip lane beside the north1 straight, climbs the face of a grid block (a steep, smoothly
rounded ramp the car drives up with the existing slope and wall driving: no surface is steeper than MAX_FACE_DEG, so
no CarController wall ray ever classifies it as a wall), runs along the roof, bridges the downtown leg to a second
block, comes down a long descent and merges onto the north2 straight through a second slip lane. Nothing here changes
adhesion, wall/slope handling, barriers, kill volumes or rescue; the car meets plain collidable slabs.

author_space4.py supplies the anchors (route frames) and turns the result into prefabs and instances; the numbers
here are exercised by tools/map/tests/test_space4.py.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

# ------------------------------------------------------------------------------------------------ dimensions
LANE_LATERAL = 36.0  # slip-lane centre from the route axis: lane inner edge 22 = the road's curb line
DECK_W = 28.0  # driving width of the line
DECK_T = 3.0  # slab thickness (surface down)
WALL_T = 2.0
WALL_H = 5.0  # over the surface (the car's wall rays run 2.2 above its ground)
WALL_LATERAL = DECK_W / 2 + WALL_T / 2  # wall centre from the line axis
SUPPORT_W = 30.0  # the blocks under the line (deck 28, the walls overhang a stud each side)
FILLET_R = 170.0  # plan radius where the line leaves / rejoins the road heading (car minimum is 85)
STEP = 6.0  # sample spacing along the line (horizontal)
MAX_FACE_DEG = 48.0  # steepest surface the car is asked to climb (CarConfig.WALL_MAX_UP_DOT 0.5 starts at 60)
MAX_STEP_DEG = 20.0  # largest pitch change between two neighbouring 6-stud samples (terrain walls step up to 60 deg at once)
CLIMB_RAMP = (0.4, 0.2, 0.4)  # climb pitch profile: ease-in share, steep face share, ease-out share
DESC_RAMP = (0.4, 0.2, 0.4)
CLEAR_OVER_CORRIDOR = 3.0  # roof underside clearance over the corridor ceiling (ribbon + 26) at the bridge
PARAPET_FACE = 27.2  # outer face of the road parapet (centre 26.2, 2 thick)
SUPPORT_CLEAR = 30.0  # nearest plan distance from the route axis to the support blocks' corners

# ------------------------------------------------------------------------------------------------ small helpers


def smooth(t: float) -> float:
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def unit2(v):
    n = math.hypot(v[0], v[1])
    return (v[0] / n, v[1] / n)


def shape(u: float, ramp: tuple[float, float, float]) -> float:
    """0..1 pitch envelope: eases up over the first share, holds, eases down over the last share."""
    a, h, b = ramp
    if u <= a:
        return smooth(u / a)
    if u >= 1 - b:
        return smooth((1 - u) / b)
    return 1.0


def rise_for(peak_deg: float, length: float, ramp, n: int = 400) -> float:
    """Height gained over `length` horizontal studs when the pitch follows peak * shape(u)."""
    tot = 0.0
    for i in range(n):
        u = (i + 0.5) / n
        tot += math.tan(math.radians(peak_deg * shape(u, ramp))) * (length / n)
    return tot


def solve_peak(length: float, rise: float, ramp, max_deg: float) -> float:
    """Peak pitch (degrees) whose profile gains exactly `rise` over `length`. Raises when it would exceed max_deg."""
    lo, hi = 0.0, 80.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if rise_for(mid, length, ramp) < rise:
            lo = mid
        else:
            hi = mid
    peak = (lo + hi) / 2
    if peak > max_deg + 1e-6:
        raise ValueError(f"profile needs {peak:.1f} deg > {max_deg} over {length} studs for a rise of {rise:.2f}")
    return peak


# ------------------------------------------------------------------------------------------------ plan polyline
def fillet_path(vs: list[tuple[float, float]], radius: float, step: float) -> list[tuple[float, float]]:
    """Plan polyline V0..Vn with every interior corner rounded by an arc of `radius`; samples about `step` apart."""
    pts: list[tuple[float, float]] = []

    def straight(a, b):
        n = max(1, math.ceil(math.hypot(b[0] - a[0], b[1] - a[1]) / step))
        for k in range(n):
            pts.append((a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n))

    cur = vs[0]
    for i in range(1, len(vs) - 1):
        d0, d1 = unit2((vs[i][0] - vs[i - 1][0], vs[i][1] - vs[i - 1][1])), unit2((vs[i + 1][0] - vs[i][0], vs[i + 1][1] - vs[i][1]))
        turn = math.atan2(d0[0] * d1[1] - d0[1] * d1[0], d0[0] * d1[0] + d0[1] * d1[1])  # signed
        t_len = radius * math.tan(abs(turn) / 2)
        p_in = (vs[i][0] - d0[0] * t_len, vs[i][1] - d0[1] * t_len)
        p_out = (vs[i][0] + d1[0] * t_len, vs[i][1] + d1[1] * t_len)
        straight(cur, p_in)
        sgn = 1.0 if turn > 0 else -1.0
        centre = (p_in[0] - d0[1] * sgn * radius, p_in[1] + d0[0] * sgn * radius)
        a0 = math.atan2(p_in[1] - centre[1], p_in[0] - centre[0])
        n = max(2, math.ceil(radius * abs(turn) / step))
        for k in range(n):
            a = a0 + turn * k / n
            pts.append((centre[0] + radius * math.cos(a), centre[1] + radius * math.sin(a)))
        cur = p_out
    straight(cur, vs[-1])
    pts.append(vs[-1])
    return pts


@dataclass
class Sample:
    s: float  # horizontal distance along the line
    x: float
    z: float
    y: float  # surface height at the centreline
    yaw_dx: float  # horizontal heading (unit)
    yaw_dz: float


@dataclass
class Line:
    samples: list[Sample]
    climb: tuple[float, float]  # s range of the climb ramp
    roof: tuple[float, float]  # s range held at roof height
    descent: tuple[float, float]
    roof_y: float
    climb_peak: float
    descent_peak: float
    bridge: tuple[float, float]  # s range where the line is over the road
    blocks: list[tuple[float, float, str]] = field(default_factory=list)  # support runs (s0, s1, name)

    def pitch_deg(self, i: int) -> float:
        a, b = self.samples[i], self.samples[i + 1]
        return math.degrees(math.atan2(b.y - a.y, math.hypot(b.x - a.x, b.z - a.z)))


def build_line(vs: list[tuple[float, float]], road_y, roof_y: float, climb_from: float, climb_len: float,
               descent_from: float, descent_len: float) -> Line:
    """Plan polyline `vs` (start, two corners, end) -> samples with the height profile applied.

    road_y(x, z): the road surface height beside the line (ribbon + 2.7 at the nearest route point); the line follows it
    on the slip lanes. The climb starts at horizontal distance climb_from and is climb_len long, the roof is held to
    descent_from, the descent is descent_len long and ends on the road surface."""
    xz = fillet_path(vs, FILLET_R, STEP)
    cum = [0.0]
    for a, b in zip(xz, xz[1:]):
        cum.append(cum[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    total = cum[-1]
    c0, c1 = climb_from, climb_from + climb_len
    d0, d1 = descent_from, descent_from + descent_len
    assert c1 < d0 and d1 < total - 10.0, (c1, d0, d1, total)

    def at(s: float) -> tuple[float, float]:
        for (a, sa), (b, sb) in zip(zip(xz, cum), zip(xz[1:], cum[1:])):
            if s <= sb:
                t = (s - sa) / max(1e-9, sb - sa)
                return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        return xz[-1]

    y_a = road_y(*at(c0))
    y_e = road_y(*at(d1))
    climb_peak = solve_peak(climb_len, roof_y - y_a, CLIMB_RAMP, MAX_FACE_DEG)
    desc_peak = solve_peak(descent_len, roof_y - y_e, DESC_RAMP, 40.0)

    def integral(peak: float, ramp, length: float, s_in: float) -> float:
        n = 200
        u1 = s_in / length
        tot = 0.0
        for i in range(n):
            u = u1 * (i + 0.5) / n
            tot += math.tan(math.radians(peak * shape(u, ramp))) * (s_in / n)
        return tot

    samples = []
    for i, (p, s) in enumerate(zip(xz, cum)):
        q = xz[min(i + 1, len(xz) - 1)]
        r = xz[max(i - 1, 0)]
        h = unit2((q[0] - r[0], q[1] - r[1]))
        if s <= c0:
            y = road_y(*p)
        elif s <= c1:
            y = y_a + integral(climb_peak, CLIMB_RAMP, climb_len, s - c0)
        elif s <= d0:
            y = roof_y
        elif s <= d1:
            y = roof_y - integral(desc_peak, DESC_RAMP, descent_len, s - d0)
        else:
            y = road_y(*p)
        samples.append(Sample(s, p[0], p[1], y, h[0], h[1]))
    return Line(samples, (c0, c1), (c1, d0), (d0, d1), roof_y, climb_peak, desc_peak, (0.0, 0.0))


# ------------------------------------------------------------------------------------------------ queries
def surface_height_at(line: Line, s: float) -> float:
    ss = line.samples
    if s <= ss[0].s:
        return ss[0].y
    for a, b in zip(ss, ss[1:]):
        if s <= b.s:
            t = (s - a.s) / max(1e-9, b.s - a.s)
            return a.y + (b.y - a.y) * t
    return ss[-1].y


def max_surface_pitch(line: Line) -> float:
    return max(abs(line.pitch_deg(i)) for i in range(len(line.samples) - 1))


def max_pitch_step(line: Line) -> float:
    ps = [line.pitch_deg(i) for i in range(len(line.samples) - 1)]
    return max(abs(b - a) for a, b in zip(ps, ps[1:]))
