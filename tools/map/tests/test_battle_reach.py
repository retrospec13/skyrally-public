#!/usr/bin/env python3
"""Every map's battle overlay (skyrally.gameplay.modes.battle): every pickup and every seat a vehicle can reach.

Owner 2026-10-21: "all the balloons are on the ship that you can't even get to, you forget that people are on vehicles
and they have to be able to easily and quickly navigate around". For each plan with a battle block:

* every pickup (`pickups[].pos` or `pickupAnchors`) and every spawn pad is inside the play radius;
* none is inside a collidable part of the plan (rebuilt by galleon_geom, the builder's own transforms) or a collidable
  set-dressing prop (PropLibrary sizes, the author scripts' AABB);
* car battles: each one sits a few studs over plain terrain (never a deck, hull, crate or other prop top), clear of
  walls, and a car can drive to it: a flood fill over the plan's ground (a step a car can climb, no wall, not deeper
  than the drown depth) from the player's seat reaches it. A water battle floods at its last tide level too, so the
  dry loop never loses a pod or a pad to the tide;
* plane battles: each one floats between the arena floor and ceiling, clear of the ground under it;
* the seats past the plan's pads (BattleRules.spawnPosition ring seats, used by a field of eight) are inside the
  arena, over the ground, and not in a part.

Standard library + numpy only. Run: cd tools/map/tests && python3 -m unittest test_battle_reach -v"""
from __future__ import annotations

import json
import math
import re
import unittest

import numpy as np

import fixtures
import galleon_geom

ROOT = fixtures.ROOT
FIELD = 8  # src/shared/battle/BattleRules.luau FIELD (read below; this is the fallback)
SPAWN_RING = 0.6  # BattleRules.SPAWN_RING
CAR_CLIMB = 2.2  # galleon_geom.flood default: a step a car climbs per stud
SNAP_RISE = 1.5  # the author scripts' prop AABB rise over the snapped ground


def battle_rules_const(name: str, default: float) -> float:
    src = (ROOT / "src" / "shared" / "battle" / "BattleRules.luau").read_text()
    m = re.search(rf"^BattleRules\.{name}\s*=\s*([0-9.]+)", src, re.M)
    return float(m.group(1)) if m else default


def prop_sizes(zone: str) -> dict[str, tuple[float, float, float, bool]]:
    """{key: (sx, sy, sz, collide)} for a zone's props in src/shared/PropLibrary.luau (author prop_library)."""
    src = (ROOT / "src" / "shared" / "PropLibrary.luau").read_text()
    out = {}
    for m in re.finditer(r"\n\t(\w+) = \{(.*?)\n\t\},", src, re.S):
        body = m.group(2)
        if f'zone = "{zone}"' not in body:
            continue
        sz = re.search(r"size = Vector3\.new\(([\d.]+), ([\d.]+), ([\d.]+)\)", body)
        if sz:
            out[m.group(1)] = (float(sz.group(1)), float(sz.group(2)), float(sz.group(3)), "collide = true" in body)
    return out


def battle_maps() -> list[tuple[str, dict]]:
    out = []
    for path in sorted((ROOT / "map").glob("*/plan.json")):
        plan = json.loads(path.read_text())
        if (plan.get("skyrally", {}).get("gameplay", {}).get("modes") or {}).get("battle"):
            out.append((path.parent.name, plan))
    return out


def arena_of(b: dict) -> dict:
    """BattleRules.arena: radius, returnRadius, floor, ceiling (a cylinder `height` counts up from its centre)."""
    bound = b.get("boundary") or b.get("softBoundary") or {}
    radius = float(b.get("radius") or bound["radius"])
    bound_r = max(float(bound.get("radius", radius)), radius)
    soft = bound.get("softWidth", 0 if bound_r > radius else 30)
    centre = bound.get("center", b["center"])
    floor = bound.get("floor", -math.inf)
    if "ceiling" in bound:
        ceiling = bound["ceiling"]
    elif "height" in bound:
        ceiling = centre[1] + bound["height"]
    else:
        ceiling = math.inf
    return {"center": b["center"], "radius": radius, "return": bound_r + soft, "floor": floor, "ceiling": ceiling}


def pickups_of(b: dict) -> list[list[float]]:
    if b.get("pickups"):
        return [p["pos"] if isinstance(p, dict) else p for p in b["pickups"]]
    return [p["pos"] if isinstance(p, dict) else p for p in b.get("pickupAnchors", [])]


def ring_seats(b: dict, field: int) -> list[list[float]]:
    """BattleRules.spawnPosition for the seats past the plan's pads (a field of `field`)."""
    pads, a = b["spawns"], arena_of(b)
    y = sum(p[1] for p in pads) / len(pads) if pads else b["center"][1]
    out = []
    for slot in range(len(pads) + 1, field + 1):
        k = slot - len(pads)
        ang = (k - 0.5) / 8 * 2 * math.pi
        r = a["radius"] * SPAWN_RING
        out.append([b["center"][0] + math.cos(ang) * r, y, b["center"][2] + math.sin(ang) * r])
    return out


class BattleReach(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.maps = battle_maps()
        cls.field = int(battle_rules_const("FIELD", FIELD))
        cls.geo = {}
        for key, plan in cls.maps:
            b = plan["skyrally"]["gameplay"]["modes"]["battle"]
            cls.geo[key] = galleon_geom.Cove(plan, radius=arena_of(b)["return"] + 60)

    def battle(self, plan: dict) -> dict:
        return plan["skyrally"]["gameplay"]["modes"]["battle"]

    def test_every_battle_map_is_covered(self):
        keys = {k for k, _ in self.maps}
        self.assertTrue({"island2", "snow1", "dino4", "forest1"} <= keys, keys)
        self.assertEqual(self.field, 8, "BattleRules.FIELD: a battle fills to the race field (owner 2026-10-21)")

    def test_points_inside_the_play_radius(self):
        for key, plan in self.maps:
            b = self.battle(plan)
            a = arena_of(b)
            for kind, pts in (("pickup", pickups_of(b)), ("pad", b["spawns"]), ("ring seat", ring_seats(b, self.field))):
                for i, p in enumerate(pts):
                    d = math.hypot(p[0] - a["center"][0], p[2] - a["center"][2])
                    self.assertLessEqual(d, a["radius"], (key, kind, i + 1))

    def test_nothing_inside_a_part_or_a_prop(self):
        for key, plan in self.maps:
            b = self.battle(plan)
            geo = self.geo[key]
            sizes = prop_sizes(plan["skyrally"]["zone"])
            props = []
            for d in plan["skyrally"].get("setDressing") or []:
                size = sizes.get(d["key"])
                if not size or not d.get("collide", size[3]):
                    continue
                s = d.get("scale", 1.0)
                sx, sy, sz = (v * s for v in size[:3])
                c, s_ = abs(math.cos(math.radians(d.get("yaw", 0)))), abs(math.sin(math.radians(d.get("yaw", 0))))
                hx, hz = 0.5 * (sx * c + sz * s_), 0.5 * (sx * s_ + sz * c)
                g = d["pos"][1] - 2.0
                props.append((d["pos"][0], d["pos"][2], hx + 2.0, hz + 2.0, g - 2.0, g + SNAP_RISE + sy, d["key"]))
            pts = [("pickup", p) for p in pickups_of(b)] + [("pad", p) for p in b["spawns"]] + \
                  [("ring seat", p) for p in ring_seats(b, self.field)]
            for i, (kind, p) in enumerate(pts):
                X, Z = np.array([p[0]]), np.array([p[2]])
                # a part whose column spans the point's height (1.5 under it to 1.5 over it)
                hit = geo.walls(X, Z, np.array([p[1]]), lift_lo=-1.5, lift_hi=1.5, grow=1.0)[0]
                self.assertIsNone(hit, (key, kind, i + 1, p))
                for x, z, hx, hz, lo, hi, name in props:
                    inside = abs(p[0] - x) <= hx and abs(p[2] - z) <= hz and lo <= p[1] <= hi
                    self.assertFalse(inside, (key, kind, i + 1, name))

    # ------------------------------------------------------------------------------------------------ car battles
    def car_maps(self):
        return [(k, p) for k, p in self.maps if self.battle(p).get("vehicle") == "car"]

    def test_car_points_sit_on_terrain_never_on_a_deck_or_prop(self):
        self.assertTrue(self.car_maps(), "at least one car battle (ISLAND-BATTLE)")
        for key, plan in self.car_maps():
            b = self.battle(plan)
            geo = self.geo[key]
            for kind, pts in (("pickup", pickups_of(b)), ("pad", b["spawns"])):
                for i, p in enumerate(pts):
                    g, what = geo.ground(p[0], p[2], below=p[1])
                    self.assertEqual(what[0], "terrain", (key, kind, i + 1, "stands on", what[0]))
                    self.assertTrue(0.5 <= p[1] - g[0] <= 6.0, (key, kind, i + 1, p[1] - g[0]))
                    # a car-sized patch of ground round it: no wall, no step a car cannot climb
                    ring = [(p[0] + 6 * math.cos(a), p[2] + 6 * math.sin(a)) for a in np.linspace(0, 2 * math.pi, 12)]
                    RX, RZ = np.array([q[0] for q in ring]), np.array([q[1] for q in ring])
                    RG, _ = geo.ground(RX, RZ, below=g[0] + CAR_CLIMB)
                    walls = geo.walls(RX, RZ, RG)
                    self.assertTrue(all(w is None for w in walls), (key, kind, i + 1, set(walls) - {None}))
                    self.assertLess(float(np.max(np.abs(RG - g[0]))), 3.0, (key, kind, i + 1))

    def test_car_points_are_reachable_by_car_at_every_level(self):
        for key, plan in self.car_maps():
            b = self.battle(plan)
            a = arena_of(b)
            geo = self.geo[key]
            step = 2.0
            X, Z, G, W = geo.raster(a["return"], step)
            x0, z0 = X[0, 0], Z[0, 0]
            inside = np.hypot(X - a["center"][0], Z - a["center"][2]) <= a["return"]

            def cell(p):
                return int(round((p[2] - z0) / step)), int(round((p[0] - x0) / step))

            drown = b.get("drownDepth")
            levels = [b["baseLevel"]] + [s["level"] for s in b.get("tideSteps", [])] if drown is not None else [None]
            for level in levels:
                ok = ~W & inside
                if level is not None:
                    ok &= level - G <= drown
                reach = galleon_geom.flood(ok, G, [cell(b["spawns"][0])], climb=CAR_CLIMB * step)
                for kind, pts in (("pickup", pickups_of(b)), ("pad", b["spawns"])):
                    for i, p in enumerate(pts):
                        j, k = cell(p)
                        near = reach[max(j - 1, 0):j + 2, max(k - 1, 0):k + 2]
                        self.assertTrue(near.any(), (key, kind, i + 1, "not reachable by car at level", level))

    def test_car_pickups_spread_over_the_arena(self):
        # Rule 6 of docs/research/BATTLE_ARENAS.md: pods spread over the floor, a dozen or more for eight cars, never
        # stacked; each within 3 s at top speed (128 studs/s) of at least two pads.
        for key, plan in self.car_maps():
            b = self.battle(plan)
            pts = pickups_of(b)
            self.assertGreaterEqual(len(pts), 12, key)
            for i in range(len(pts)):
                for j in range(i + 1, len(pts)):
                    self.assertGreaterEqual(math.hypot(pts[i][0] - pts[j][0], pts[i][2] - pts[j][2]), 40, (key, i, j))
                near = sum(math.hypot(pts[i][0] - s[0], pts[i][2] - s[2]) <= 3 * 128 for s in b["spawns"])
                self.assertGreaterEqual(near, 2, (key, i + 1))

    def test_car_arena_is_sized_for_cars(self):
        # Owner 2026-10-21 ("way too tiny"): at least ~3.5 s across at the car's 128 top speed, a pad per seat.
        for key, plan in self.car_maps():
            b = self.battle(plan)
            self.assertGreaterEqual(2 * arena_of(b)["radius"] / 128.0, 3.5, key)
            self.assertGreaterEqual(len(b["spawns"]), self.field, key)

    # ---------------------------------------------------------------------------------------------- plane battles
    def test_plane_points_float_between_the_floor_and_the_ceiling(self):
        planes = [(k, p) for k, p in self.maps if self.battle(p).get("vehicle") == "plane"]
        self.assertTrue(planes)
        for key, plan in planes:
            b = self.battle(plan)
            a = arena_of(b)
            geo = self.geo[key]
            has_grid = plan["terrain"].get("nx", 1) > 1
            for kind, pts in (("pickup", pickups_of(b)), ("ring seat", ring_seats(b, self.field))):
                for i, p in enumerate(pts):
                    self.assertTrue(a["floor"] + 2 <= p[1] <= a["ceiling"] - 10, (key, kind, i + 1, p[1]))
                    if has_grid:
                        g, _ = geo.ground(p[0], p[2], below=p[1])
                        self.assertGreaterEqual(p[1] - g[0], 4.0, (key, kind, i + 1, "too close to the ground"))


class WaterKeepOut(unittest.TestCase):
    """V4-3: car bots plan nothing inside a battle barrier's footprint grown by WaterRules.KEEP_OUT_PAD (the cavern-mouth
    pocket where the ISLAND water battle logged 24 'water unstick' events). Pads, pods and the player's seat stay outside."""

    # (x, z) of the repeating wedge spots from docs/VERIFY_RESULTS_V33.md (V4-3 row, build 887f53d) and the player's Stuck respawn
    STUCK = [(-5149.0, 4142.0), (-5193.0, 4150.0)]

    @staticmethod
    def pad():
        src = (ROOT / "src" / "shared" / "battle" / "WaterRules.luau").read_text()
        return float(re.search(r"^WaterRules\.KEEP_OUT_PAD\s*=\s*([0-9.]+)", src, re.M).group(1))

    @staticmethod
    def inside(bar: dict, pad: float, x: float, z: float) -> bool:
        c = bar["cf"]  # x y z r00 r01 r02 r10 r11 r12 r20 r21 r22 (row major)
        right, look = (c[3], c[9]), (c[5], c[11])
        sx, _, sz = bar["collider"]["size"]
        dx, dz = x - c[0], z - c[2]
        return abs(dx * right[0] + dz * right[1]) <= sx / 2 + pad and abs(dx * look[0] + dz * look[1]) <= sz / 2 + pad

    def test_island2_pocket(self):
        plan = json.loads((ROOT / "map" / "island2" / "plan.json").read_text())
        b = plan["skyrally"]["gameplay"]["modes"]["battle"]
        pad, bars = self.pad(), b["barriers"]
        hit = lambda x, z: any(self.inside(bar, pad, x, z) for bar in bars)  # noqa: E731
        self.assertTrue(hit(*self.STUCK[0]), "the repeating wedge spot is in the keep-out")
        for i, s in enumerate(b["spawns"], 1):
            self.assertFalse(hit(s[0], s[2]), f"pad {i} must stay outside")
        for i, p in enumerate(pickups_of(b), 1):
            self.assertFalse(hit(p[0], p[2]), f"pod {i} must stay outside")


if __name__ == "__main__":
    unittest.main()
