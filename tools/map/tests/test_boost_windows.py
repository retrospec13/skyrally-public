#!/usr/bin/env python3
"""X-07 boost-window lint (docs/audits/traps_summary.md X-07 / G7.4): every booster ring and ground boost pad on a main
route is paired with the bends its boost runs into. A boost holds the vehicle at boost speed for the boost distance,
and at that speed the vehicle cannot turn tighter than its boosted turn radius:

  car    PAD_BOOST_SPEED / turnRate(PAD_BOOST_SPEED)   (CarConfig: 165 / 76.2 deg/s  -> R ~124)
  plane  BOOST_SPEED / BOOST_YAW_RATE                  (PlaneConfig: 165 / 85 deg/s  -> R ~111; 65 -> 145 before
                                                        docs/audits/flight_feel.md C4)

Both numbers are read from src/shared/CarConfig.luau and src/shared/PlaneConfig.luau, so a tuning change re-lints every
map. The window is [station, station + boost speed * boost duration + WINDOW_TAIL] (the tail covers the overspeed decay
and a reaction), and the route radius is tools/course/route_geometry.analyse, the same curvature the adapt
route.radius gate uses. A window whose minimum radius is below the boosted radius is a crash-loop risk (boost -> bend
-> wall -> respawn -> same boost). It must be listed in REVIEWED with the audit verdict that clears it (outer side
clear or parapeted, slowdown only, or a fix pending); a new tight window fails until someone looks at it.

Run: python3 -m unittest discover -s tools/map/tests -v"""
from __future__ import annotations

import json
import math
import re
import unittest
from functools import lru_cache

import fixtures
import adapt
import route_geometry

ROOT = fixtures.ROOT
MAPS = ("dino4", "forest1", "hub0", "island2", "snow1", "space4", "teststrip")
WINDOW_TAIL = 60.0  # studs past the boost end: overspeed decay (CarConfig.OVERSPEED_DECAY) plus reaction distance
# Curvature sampling: 5-stud samples, radius through the points 20 studs either side (the audit's boostlint.py). Finer
# than the adapt route.radius gate (10 / 30), so a short kink inside a boost window is not averaged away.
RADIUS_STEP, RADIUS_BASE = 5, 20

# (map, boost name) -> the verdict that clears the tight window, pointing at the audit finding (docs/audits/traps_*.md)
# that reviewed it. "open:" marks a window whose data fix is still pending (the finding has the fix and the probe); it is
# listed so this lint stays green while that fix lands, and the entry should go when the fix moves the boost. An entry
# whose boost moved out of the bend (or was removed) is harmless: only unreviewed tight windows fail.
REVIEWED: dict[tuple[str, str], str] = {
    # DINO-4 (plane; reviewed at boosted R 145, now R 111 after flight_feel.md C4, so some entries are stale-harmless)
    # (D4-06 moved Start_1/Start_2 to st 340/400 and D4-02 moved 5_Final to st 3900: their windows are no longer
    # tight, so they are not listed and this lint now fails if either fix is undone.)
    ("dino4", "BoosterRing_3_SauropodRight"): "R 116, D4 assist and immediate-reaction lap sims: 0 crashes; corridor "
                                              "lateral >= 44 (traps_dino4 'Checked and fine')",
    ("dino4", "BoosterRing_1_SlopeBottom"): "R 107, D4 lap sims: 0 crashes; lateral >= 44 (traps_dino4)",
    ("dino4", "BoosterRing_2_SauropodLeft"): "R 115-121, D4 lap sims: 0 crashes; lateral >= 44 (traps_dino4)",
    ("dino4", "GroundBoost_Crest"): "R 111-116, D4 lap sims: 0 crashes; lateral >= 44 (traps_dino4)",
    ("dino4", "GroundBoost_SauropodFloor"): "R 145 at the window end, marginal; D4 lap sims: 0 crashes",
    # HUB-0 (car, boosted R 124)
    ("hub0", "BoosterRing_Southwest"): "R 105, reviewed fine by the hub audit (traps_summary X-07 table)",
    # ISLAND-2 (car)
    ("island2", "BoosterRing_Promontory"): "R 124 = the boosted radius, marginal (traps_summary X-07)",
    ("island2", "BoosterRing_Village"): "R 94 at st 4005: land within +-3 of the road on both sides, a slowdown, not "
                                        "a trap (traps_summary X-07, village.py)",
    # SNOW-1 (plane): lateral clearance >= 41 along the lake and slopes
    ("snow1", "BoosterRing_BasinSweep"): "R 143, SNOW clearance >= 41 lateral (traps_summary X-07); verify assist off",
    ("snow1", "BoosterRing_PineSlope"): "R 144, SNOW clearance >= 41 lateral (traps_summary X-07); verify assist off",
    ("snow1", "BoosterRing_LakeCrossing"): "R 120-125 over the open lake, clearance >= 41 (traps_summary X-07)",
    ("snow1", "GroundBoost_LakeIce"): "R 120-125 over the open lake, clearance >= 41 (traps_summary X-07)",
    # SPACE-4 (car)
    # (S4-06 replaced GroundBoost_DowntownEntry with GroundBoost_DowntownExit on the north2 straight, min R 409: not
    # listed, so the old pad coming back fails here.)
    ("space4", "BoostGate_CraterRun"): "reviewed: the straight line runs down the Alt1 chord into the tube; the bulge1 "
                                       "outer side is the fork opening into the sealed apron, bulge2 is parapeted "
                                       "(traps_space4 X-07 VERIFIED, test_space4.test_x07_boost_windows); Studio PX07",
    # TEST-STRIP: QA strip (TrackInfo 'Test Strip'), not on the progression board
    ("teststrip", "GroundBoost_MainStraight"): "QA test strip, not a player track",
    ("teststrip", "GroundBoost_WestStraight"): "QA test strip, not a player track",
    ("teststrip", "GroundBoost_BottomStraight"): "QA test strip, not a player track",
}

NUM_RE = r"(-?\d+(?:\.\d+)?)"


@lru_cache(maxsize=None)
def config(name: str) -> dict[str, float]:
    """Numeric top-level constants `<Name>.KEY = <number>` of src/shared/<Name>.luau."""
    src = (ROOT / "src" / "shared" / f"{name}.luau").read_text()
    out: dict[str, float] = {}
    for m in re.finditer(rf"^{name}\.([A-Z0-9_]+)\s*=\s*{NUM_RE}\b", src, re.M):
        out[m.group(1)] = float(m.group(2))
    return out


def car_turn_rate(speed: float) -> float:
    """CarConfig.turnRate, ported line for line (deg/s)."""
    c = config("CarConfig")
    v = abs(speed)
    low = min(max(v / c["FULL_TURN_SPEED"], 0.0), 1.0) ** c["TURN_LOW_SPEED_EXP"]
    high_t = min(max((v - c["FULL_TURN_SPEED"]) / (c["TOP_SPEED"] - c["FULL_TURN_SPEED"]), 0.0), 1.0)
    high = 1 - (1 - c["HIGH_SPEED_TURN_FACTOR"]) * high_t
    return c["TURN_RATE_MAX"] * low * high


def boost_model(vehicle: str) -> dict[str, float]:
    """Boost speed, boost distance and the boosted turn radius of a vehicle, from the shared configs."""
    if vehicle == "car":
        c = config("CarConfig")
        speed, duration = c["PAD_BOOST_SPEED"], c["PAD_BOOST_DURATION"]
        rate = car_turn_rate(speed)
    else:
        p = config("PlaneConfig")
        speed, duration = p["BOOST_SPEED"], p["BOOST_DURATION"]
        rate = p["BOOST_YAW_RATE"]
    return {"speed": speed, "distance": speed * duration, "radius": speed / math.radians(rate)}


def boost_windows(plan: dict, waypoints: list, length: float) -> list[dict]:
    """Every main-route ring and pad with the bends (stretches under the boosted radius) inside its window."""
    sk = plan["skyrally"]
    model = boost_model(sk.get("vehicle", "plane"))
    rows, _ = route_geometry.analyse([list(w) for w in waypoints], step=RADIUS_STEP, base=RADIUS_BASE)
    span = model["distance"] + WINDOW_TAIL
    out = []
    gp = sk.get("gameplay", {})
    for kind in ("rings", "pads"):
        for b in gp.get(kind, []) or []:
            if b.get("alternate") is not None or b.get("line") is not None or not isinstance(b.get("station"), (int, float)):
                continue  # alternate-line boosts sit on their own polyline, not on the route stations
            st = float(b["station"])

            def ahead(r, st=st):
                d = (r["st"] - st) % length
                return d <= span

            window = sorted((r for r in rows if ahead(r)), key=lambda r: (r["st"] - st) % length)
            bends = [min(s, key=lambda r: r["r"]) for s in route_geometry.stretches(window, lambda r: r["r"] < model["radius"])]
            worst = min(window, key=lambda r: r["r"]) if window else {"r": math.inf, "st": st}
            out.append({"kind": kind, "name": b["name"], "station": st, "minRadius": worst["r"],
                        "minStation": worst["st"], "bends": [(r["st"], r["r"]) for r in bends],
                        "boostedRadius": model["radius"], "span": span})
    return out


@lru_cache(maxsize=None)
def map_windows(key: str) -> tuple:
    plan = json.loads((ROOT / "map" / key / "plan.json").read_text())
    res = adapt.check(plan)
    route = res.route
    wps = [w.pos for w in route.waypoints]
    return plan["skyrally"].get("vehicle", "plane"), tuple(
        tuple(sorted(w.items())) for w in boost_windows(plan, wps, route.length))


def tight(key: str) -> list[dict]:
    _, ws = map_windows(key)
    return [dict(w) for w in ws if dict(w)["bends"]]


class BoostModel(unittest.TestCase):
    def test_car_boosted_radius_from_carconfig(self):
        m = boost_model("car")
        self.assertAlmostEqual(m["speed"], 165)
        self.assertAlmostEqual(m["distance"], 264, places=3)
        self.assertAlmostEqual(m["radius"], 124.1, delta=0.5)

    def test_plane_boosted_radius_from_planeconfig(self):
        m = boost_model("plane")
        self.assertAlmostEqual(m["distance"], 297, places=3)
        self.assertAlmostEqual(m["radius"], 111.2, delta=0.5)  # flight_feel.md C4 (was 145.4 at 65 deg/s)

    def test_lint_flags_a_ring_before_a_tight_circle(self):
        """Synthetic: a ring on a circle of radius 100 (< both boosted radii) is tight; on radius 400 it is not."""
        for radius, expect in ((100.0, True), (400.0, False)):
            n = 72
            pts = [(radius * math.sin(2 * math.pi * k / n), 100.0, radius * math.cos(2 * math.pi * k / n))
                   for k in range(n)]
            pts.append(pts[0])
            length = sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))
            plan = {"skyrally": {"vehicle": "car", "gameplay": {"rings": [{"name": "R", "station": 10.0}],
                                                                 "pads": [{"name": "A", "station": 5.0, "alternate": "Alt1"}]}}}
            ws = boost_windows(plan, pts, length)
            self.assertEqual([w["name"] for w in ws], ["R"], "alternate boosts are skipped")
            self.assertEqual(bool(ws[0]["bends"]), expect, f"radius {radius}")


class BoostWindows(unittest.TestCase):
    def test_every_tight_window_is_reviewed(self):
        for key in MAPS:
            for w in tight(key):
                with self.subTest(map=key, boost=w["name"]):
                    bends = ", ".join(f"R {r:.0f} at st {s}" for s, r in w["bends"])
                    self.assertIn((key, w["name"]), REVIEWED,
                                  f"{key} {w['kind'][:-1]} {w['name']} at st {w['station']:.0f}: the boost runs "
                                  f"{w['span']:.0f} studs into {bends}, tighter than the boosted turn radius "
                                  f"{w['boostedRadius']:.0f}. Move or soften the boost, or review it and add it to "
                                  f"REVIEWED with the verdict.")

    def test_reviewed_entries_name_known_maps_and_verdicts(self):
        for (key, name), verdict in REVIEWED.items():
            self.assertIn(key, MAPS, f"REVIEWED names unknown map {key}")
            self.assertTrue(name.startswith(("BoosterRing_", "BoostGate_", "GroundBoost_")), name)
            self.assertTrue(verdict.strip(), f"{key} {name}: a reviewed window needs its verdict")

    def test_pairs_cover_every_main_route_boost(self):
        """Every main-route boost gets a window (the pairing itself), and the audit's known bends are found."""
        for key in MAPS:
            plan = json.loads((ROOT / "map" / key / "plan.json").read_text())
            gp = plan["skyrally"].get("gameplay", {})
            main = [b["name"] for k in ("rings", "pads") for b in gp.get(k, []) or [] if b.get("alternate") is None and b.get("line") is None]
            _, ws = map_windows(key)
            self.assertEqual(sorted(dict(w)["name"] for w in ws), sorted(main), key)
        village = {w["name"]: w for w in tight("island2")}.get("BoosterRing_Village")
        if village:  # the X-07 table: R 94 at st 4005
            self.assertTrue(any(abs(s - 4005) <= 15 and r < 100 for s, r in village["bends"]), village["bends"])


if __name__ == "__main__":
    unittest.main()
