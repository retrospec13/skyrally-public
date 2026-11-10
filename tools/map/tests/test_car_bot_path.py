#!/usr/bin/env python3
"""Car bots on the real car-map routes (docs/audits/plane_stutter.md "Car bots"): AIRacers.renderCar's horizontal
placement, replayed at the fixed 1/60 s server step on HUB-0, ISLAND-2 and SPACE-4, with the raw chord frame
(SplineUtils.sampleAtStation, before) and the box-filtered RacerViewRules.pathFrame (after).

renderCar places the hull AT pos + rightOf(tan) * lateral every step (no position ease; only the rotation eases at
CAR_BOT.turnResponse), so any step in the chord tangent is a sideways hop on screen. The ground ray (height) is not
modelled: this is the horizontal path only.

Run: python3 -m unittest test_car_bot_path -v (from tools/map/tests); SKYRALLY_TEST_VERBOSE=1 prints the tables."""
from __future__ import annotations

import json
import math
import os
import unittest

import fixtures
import route

MAPS = ("hub0", "island2", "space4")
DT = 1.0 / 60.0
SPEED = 130.0  # PlaneConfig baseSpeed 134 x CAR_BOT.paceFactor 0.97
PATH_HALF = 16.0  # RacerViewRules.PATH_HALF
AHEAD = 12.0  # renderCar look-ahead
TURN_RESPONSE = 14.0  # CAR_BOT.turnResponse
LANES = (0.0, 12.0, 16.0)  # CAR_BOT.maxLateral = 16
VERBOSE = os.environ.get("SKYRALLY_TEST_VERBOSE") == "1"


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def mul(a, k):
    return (a[0] * k, a[1] * k, a[2] * k)


def mag(a):
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def right_of(t):
    """AIRacers.rightOf: tan x UP, unit."""
    r = (-t[2], 0.0, t[0])
    m = mag(r)
    return (r[0] / m, 0.0, r[2] / m) if m > 0.01 else (1.0, 0.0, 0.0)


def pct(xs, q):
    s = sorted(xs)
    return s[min(max(int(math.floor(q * len(s) + 0.5)), 1), len(s)) - 1] if s else 0.0


def wrap_deg(a):
    return (a + 180.0) % 360.0 - 180.0


class CarBotPath:
    def __init__(self, key: str):
        plan = json.loads((fixtures.ROOT / "map" / key / "plan.json").read_text())
        self.vehicle = plan["skyrally"].get("vehicle")
        self.route = route.solve_plan_route(plan["skyrally"]["route"])
        self.wps, self.total = self.route.waypoints, self.route.length

    def sample(self, st):
        return route.sample_at_station(self.wps, self.total, st)

    def path_frame(self, st):
        """RacerViewRules.pathFrame."""
        q = PATH_HALF * 0.25
        a, _, ba = self.sample(st - 3 * q)
        b, fallback, bb = self.sample(st - q)
        c, _, bc = self.sample(st + q)
        d, _, bd = self.sample(st + 3 * q)
        dv = sub(add(c, d), add(a, b))
        m = mag(dv)
        pos = mul(add(add(a, b), add(c, d)), 0.25)
        return pos, (mul(dv, 1 / m) if m > 0.05 else fallback), (ba + bb + bc + bd) * 0.25

    def corners(self):
        out = []
        for i in range(1, len(self.wps) - 1):
            a = sub(self.wps[i].pos, self.wps[i - 1].pos)
            b = sub(self.wps[i + 1].pos, self.wps[i].pos)
            if mag(a) > 1e-6 and mag(b) > 1e-6:
                c = (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (mag(a) * mag(b))
                out.append(math.degrees(math.acos(max(-1.0, min(1.0, c)))))
        return out

    def replay(self, new: bool, lateral: float):
        """One lap of renderCar at the fixed step: placed-hull jerk (studs/step, XZ), eased heading jerk (deg/step),
        steer step (wheel-rig units/step)."""
        frame = self.path_frame if new else self.sample
        alpha = min(1.0, DT * TURN_RESPONSE)
        st, yaw = 0.0, None
        hist, yaws, steers = [], [], []
        for _ in range(int(self.total / SPEED / DT)):
            st += SPEED * DT
            pos, tan, _ = frame(st)
            apos, atan, _ = frame(st + AHEAD)
            base = add(pos, mul(right_of(tan), lateral))
            abase = add(apos, mul(right_of(atan), lateral))
            fwd = sub(abase, base)
            goal = math.degrees(math.atan2(fwd[0], fwd[2]))
            yaw = goal if yaw is None else yaw + wrap_deg(goal - yaw) * alpha
            hist.append((base[0], base[2]))
            yaws.append(yaw)
            steers.append(max(-1.0, min(1.0, -(tan[2] * atan[0] - tan[0] * atan[2]) * 4)))
        pj, yj, ss = [], [], []
        for i in range(2, len(hist)):
            a, b, c = hist[i - 2], hist[i - 1], hist[i]
            pj.append(math.hypot(c[0] - 2 * b[0] + a[0], c[1] - 2 * b[1] + a[1]))
            yj.append(abs(wrap_deg(yaws[i] - yaws[i - 1]) - wrap_deg(yaws[i - 1] - yaws[i - 2])))
            ss.append(abs(steers[i] - steers[i - 1]))
        return pj, yj, ss

    def line_offset(self):
        """Lane 0 after: the filtered point's horizontal distance from the raw line at the same station."""
        worst, st = 0.0, 0.0
        while st < self.total:
            p, _, _ = self.path_frame(st)
            r, _, _ = self.sample(st)
            worst = max(worst, math.hypot(p[0] - r[0], p[2] - r[2]))
            st += 2.0
        return worst


class CarBotsOnRealRoutes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.maps = {k: CarBotPath(k) for k in MAPS}

    def test_maps_are_car_maps(self):
        for key, m in self.maps.items():
            self.assertEqual(m.vehicle, "car", key)

    def test_side_lane_hops_gone(self):
        for key, m in self.maps.items():
            corners = m.corners()
            chords = [w2.station - w1.station for w1, w2 in zip(m.wps, m.wps[1:])]
            if VERBOSE:
                print(f"\n{key}: {len(m.wps)} waypoints, {m.total:.0f} studs, chord p50 {pct(chords, 0.5):.1f}, "
                      f"corner p50 {pct(corners, 0.5):.2f} / p99 {pct(corners, 0.99):.2f} / max {max(corners):.2f} deg, "
                      f"lane-0 offset from the line {m.line_offset():.2f} studs")
            for lane in LANES:
                op, oy, os_ = m.replay(False, lane)
                np_, ny, ns = m.replay(True, lane)
                if VERBOSE:
                    print(f"  lane {lane:4.0f}: pos jerk p99/max {pct(op, .99):.3f} / {max(op):.3f} -> "
                          f"{pct(np_, .99):.3f} / {max(np_):.3f}   heading jerk p99/max {pct(oy, .99):.3f} / {max(oy):.3f} -> "
                          f"{pct(ny, .99):.3f} / {max(ny):.3f} deg   steer step p99/max {pct(os_, .99):.3f} / {max(os_):.3f} -> "
                          f"{pct(ns, .99):.3f} / {max(ns):.3f}")
                if lane >= 12:
                    self.assertLess(max(np_), max(op) * 0.5, f"{key} lane {lane}: hull hop max")
                    self.assertLess(max(np_), 0.25, f"{key} lane {lane}: no sideways hop over a quarter stud")
                self.assertLessEqual(pct(np_, 0.99), pct(op, 0.99) + 1e-6, f"{key} lane {lane}: pos jerk p99")
                self.assertLessEqual(max(ny), max(oy) + 1e-6, f"{key} lane {lane}: heading jerk max")
                self.assertLessEqual(max(ns), max(os_) + 1e-6, f"{key} lane {lane}: steer step max")

    def test_stays_on_the_road(self):
        # 44-wide deck, lanes to +-18 (maxLateral 16 + 2): the filtered line must not cut a corner by more than 1.5.
        for key, m in self.maps.items():
            self.assertLess(m.line_offset(), 1.5, key)


if __name__ == "__main__":
    unittest.main()
