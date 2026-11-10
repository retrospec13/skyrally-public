#!/usr/bin/env python3
"""DINO-4 egg battle overlay (LAUNCH_PROGRESSION 2b, TEST_LIST_LAUNCH L71/X1-X2): the plan's
skyrally.gameplay.modes.battle is exactly what tools/map/author_dino4.py writes, the overlay sits in open air on the
lower-basin floor of the great hall round the altar (inside the hall's carved air, above the lava floor, clear of every
later solid shell op and of the altar's collidable tiers), far from everything the race uses, and adding it left the
route and every adapt gate as they were.
Run: python3 -m unittest discover -s tools/map/tests -v"""
import json
import math
import unittest

import numpy as np

import fixtures  # noqa: F401  (puts tools/map and tools/course on sys.path)
import adapt
import author_dino4 as author

ROOT = fixtures.ROOT
PLAN = ROOT / "map" / "dino4" / "plan.json"
FLOOR = 16.0  # the hall's lava floor / basalt slabs (FlightController crashes at Y <= 16)


def horizontal(a, b):
    return math.hypot(a[0] - b[0], a[2] - b[2])


def in_op(op, p, pad=0.0):
    """Whether point p lies inside a FillBlock / FillBall / FillCylinder (grown by pad)."""
    kind = op["op"]
    if kind == "FillBlock":
        cf = op["cf"]
        rot = np.array(cf[3:]).reshape(3, 3)
        local = rot.T @ (np.array(p, float) - np.array(cf[:3], float))
        return bool(np.all(np.abs(local) <= np.array(op["size"], float) / 2 + pad))
    if kind == "FillBall":
        return math.dist(p, op["center"]) <= op["r"] + pad
    if kind == "FillCylinder":  # upright cylinders only in this plan (identity rotation, checked below)
        cf = op["cf"]
        return horizontal(p, cf[:3]) <= op["r"] + pad and abs(p[1] - cf[1]) <= op["h"] / 2 + pad
    return False


class Dino4Battle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = json.loads(PLAN.read_text())
        cls.sk = cls.plan["skyrally"]
        cls.gp = cls.sk["gameplay"]
        cls.b = cls.gp["modes"]["battle"]
        cls.res = adapt.check(cls.plan)

    def anchors(self):
        """(label, point, clearance) for every point a plane must reach or start from."""
        b = self.b
        out = [("centre egg", b["centerNest"]["pos"], 10.0)]
        out += [(f"spawn {i}", s, 15.0) for i, s in enumerate(b["spawns"], 1)]
        out += [(f"pod {i}", p, 10.0) for i, p in enumerate(b["pickupAnchors"], 1)]
        out += [(n["name"], n["pos"], n["radius"] + 4.0) for n in b["nests"]]
        return out

    def test_battle_block_is_the_author_scripts(self):
        self.assertEqual(self.b, json.loads(json.dumps(author.egg_battle())),
                         "map/dino4/plan.json modes.battle is stale: rerun tools/map/author_dino4.py")

    def test_egg_overlay_shape(self):
        b = self.b
        self.assertEqual((b["kind"], b["mode"], b["vehicle"]), ("egg", "DINO-BATTLE", "plane"))
        self.assertEqual(len(b["spawns"]), 4)
        self.assertEqual(len(b["nests"]), 4)
        self.assertGreaterEqual(len(b["pickupAnchors"]), 8)
        self.assertEqual(b["rules"]["hatchSeconds"], 10)
        self.assertEqual(b["rules"]["eggsToWin"], 3)
        self.assertEqual(b["rules"]["timeCapSeconds"], 180)
        bound = b["boundary"]
        self.assertGreater(bound["radius"], b["radius"])
        for label, p, _ in self.anchors():
            self.assertLess(horizontal(p, b["center"]), b["radius"], label)
            self.assertLess(p[1], bound["ceiling"] - 20, label)
            self.assertGreater(p[1], bound["floor"] + 20, label)

    def test_overlay_clear_of_everything_the_race_uses(self):
        """The whole soft boundary is at least 60 studs from the route (and so from the checkpoints, rings, pads and pods
        on it), its alternates and the hidden key: nothing the race uses is inside, or moved for, the overlay."""
        b = self.b
        reach = b["boundary"]["radius"] + b["boundary"]["softWidth"] + 60
        route = self.res.route
        for w in route.waypoints:
            self.assertGreater(horizontal(w.pos, b["center"]), reach, f"route at station {w.station:.0f}")
        for alt in self.gp["alternates"]:
            for q in alt["points"]:
                self.assertGreater(horizontal(q, b["center"]), reach, alt["id"])
        self.assertGreater(horizontal(self.gp["key"]["pos"], b["center"]), reach, "hidden key")

    def test_route_and_gates_unchanged(self):
        self.assertEqual([f"{e.code}: {e.msg}" for e in self.res.report.errors], [])
        self.assertLessEqual(abs(self.res.route.length - 5450), 1.0)
        self.assertEqual(self.res.gates["corridorPartIntrusions"], 0)

    def test_anchors_in_the_halls_open_air(self):
        """Every anchor (with its clearance) lies inside the great hall's carved air, above the lava floor, outside every
        solid shell op the plan applies after the hall is carved, and outside the altar's collidable tiers."""
        ops = self.sk["shells"]["ops"]
        hall = next(i for i, o in enumerate(ops) if o["op"] == "FillBlock" and o["mat"] == "Air" and o["size"][0] >= 1000)
        later_solid = [o for o in ops[hall + 1:] if o["op"] in ("FillBlock", "FillBall", "FillCylinder") and o.get("mat") != "Air"]
        for o in later_solid:
            if o["op"] == "FillCylinder":
                self.assertEqual(o["cf"][3:], [1, 0, 0, 0, 1, 0, 0, 0, 1])
        centres, halves, meta = adapt.collidable_parts(self.plan)
        for label, p, clear in self.anchors():
            self.assertTrue(in_op(ops[hall], p, -clear), f"{label} inside the hall's air")
            self.assertGreater(p[1] - clear, FLOOR, f"{label} above the lava floor")
            for o in later_solid:
                self.assertFalse(in_op(o, p, clear), f"{label} inside a solid {o['op']} {o.get('cf', o.get('center'))}")
            gap = (np.abs(centres - np.array(p, float)) - halves).max(axis=1)
            k = int(gap.argmin())
            self.assertGreater(float(gap[k]), clear - 4.0, f"{label} too close to {meta[k]}")

    def test_boundary_band_in_open_air(self):
        """The return circle (play radius + soft band), from just above the floor to the ceiling, is inside the hall's
        carved air and outside every later solid op: a plane is put back on a pad before it can reach a wall."""
        ops = self.sk["shells"]["ops"]
        hall = next(i for i, o in enumerate(ops) if o["op"] == "FillBlock" and o["mat"] == "Air" and o["size"][0] >= 1000)
        later_solid = [o for o in ops[hall + 1:] if o["op"] in ("FillBlock", "FillBall", "FillCylinder") and o.get("mat") != "Air"]
        b = self.b
        bound = b["boundary"]
        r = bound["radius"] + bound["softWidth"]
        for deg in range(0, 360, 5):
            a = math.radians(deg)
            for y in np.linspace(FLOOR + 10, bound["ceiling"], 8):
                p = [b["center"][0] + math.cos(a) * r, float(y), b["center"][2] + math.sin(a) * r]
                self.assertTrue(in_op(ops[hall], p, -8.0), f"return circle at {deg} deg, Y {y:.0f} in the hall's air")
                for o in later_solid:
                    self.assertFalse(in_op(o, p, 4.0), f"return circle at {deg} deg, Y {y:.0f} inside {o['op']}")

    def test_centre_nest_over_the_altar(self):
        """The centre egg hangs over the altar (the only collidable parts in the arena), above its top tier."""
        centres, halves, meta = adapt.collidable_parts(self.plan)
        c = self.b["centerNest"]
        tiers = [i for i, m in enumerate(meta) if m["prefab"] == "LowerBasinVolcanicAltar"]
        self.assertTrue(tiers)
        top = max(centres[i][1] + halves[i][1] for i in tiers)
        self.assertAlmostEqual(top, c["ground"], places=3)
        self.assertGreaterEqual(c["pos"][1] - c["radius"] - top, 10)
        for i, m in enumerate(meta):
            if m["prefab"] != "LowerBasinVolcanicAltar":
                self.assertGreater(horizontal(centres[i], self.b["center"]), self.b["boundary"]["radius"] + 30, m)


if __name__ == "__main__":
    unittest.main()
