#!/usr/bin/env python3
"""DINO-4 launch upgrade (TRACK_VARIETY 5a): the Alt1 geyser vents and the lap-3 eruption in the plan and TrackData.
The vents sit on the Alt1 floor, inside the tunnel, apart from the Alt1 coin, never near the Alt2 key or the egg-battle
floor, with a fixed 4 s cycle and staggered phases; the plan carries no new collidable part, hazard, shell op or route
change (the wall-driving rule: nothing about adhesion, barriers, kill volumes or rescue moves).
Run: python3 -m unittest discover -s tools/map/tests -v"""
import json
import math
import re
import unittest

import fixtures

ROOT = fixtures.ROOT
PLAN = json.loads((ROOT / "map" / "dino4" / "plan.json").read_text())
SK = PLAN["skyrally"]
GP = SK["gameplay"]
TD = (ROOT / "build" / "dino4" / "TrackData.luau").read_text()


def alt1():
    return next(a for a in GP["alternates"] if a["id"] == "Alt1")["points"]


class Updraft(unittest.TestCase):
    def test_two_vents_on_alt1_points(self):
        g = GP["geysers"]
        self.assertEqual([x["id"] for x in g], ["AltGeyser1", "AltGeyser2"])
        pts = alt1()
        for x in g:
            self.assertEqual(x["alternate"], "Alt1")
            p = pts[x["pointIndex"]]
            self.assertEqual(x["pos"][0], round(p[0], 2))
            self.assertEqual(x["pos"][2], round(p[2], 2))
            self.assertAlmostEqual(x["pos"][1] - p[1], 1.8, places=1)  # on the Alt1 floor, under the flight line (+14)

    def test_fixed_cycle_and_staggered_phase(self):
        g = GP["geysers"]
        for x in g:
            self.assertEqual(x["cycle"], 4.0)
        self.assertEqual({x["phase"] % 4.0 for x in g}, {0.0, 2.0})

    def test_inside_the_tunnel(self):
        # Alt1 carves a 26-wide, 28-tall tunnel round its points (MapAdapter): the column stays inside it
        for x in GP["geysers"]:
            self.assertLessEqual(x["radius"], 13)
            self.assertLessEqual(x["height"], 28)

    def test_clear_of_the_coin_the_key_and_the_egg_floor(self):
        coin = next(c for c in GP["coins"] if c.get("alternate") == "Alt1")["pos"]
        key = GP["key"]["pos"]
        egg = GP["modes"]["battle"]
        for x in GP["geysers"]:
            self.assertGreater(math.dist(x["pos"], coin), 120)
            self.assertGreater(math.dist(x["pos"], key), 500)
        for x in GP["geysers"]:  # horizontal distance to the egg-battle circle (centre, radius), plus a margin
            d = math.dist([x["pos"][0], x["pos"][2]], [egg["center"][0], egg["center"][2]])
            self.assertGreater(d, egg["boundary"]["radius"] + 60)

    def test_inside_alt1_span_and_alt2_is_untouched(self):
        n = len(alt1())
        for x in GP["geysers"]:
            self.assertTrue(2 <= x["pointIndex"] <= n - 3, "away from the join and the rejoin")
        alts = {a["id"]: a for a in GP["alternates"]}
        self.assertEqual(set(alts), {"Alt1", "Alt2"})
        self.assertEqual(alts["Alt2"]["style"], "ledge")
        self.assertEqual((alts["Alt2"]["joinStation"], alts["Alt2"]["rejoinStation"]), (2380, 3240))

    def test_eruption_lap(self):
        self.assertEqual(GP["eruption"], {"lap": 3})
        self.assertEqual(SK["laps"], 3)

    def test_no_new_solid_or_hazard(self):
        # the vents are server-built visual parts: the plan adds no part, hazard or terrain op for them
        names = [h["name"] for h in SK["hazards"]]
        self.assertEqual(names, ["LavaSeaFloor", "StartLavaBed"])
        for n in json.dumps(PLAN["prefabs"]).lower().split('"'):
            self.assertNotIn("altgeyser", n)

    def test_trackdata_carries_the_vents(self):
        self.assertIn('id = "AltGeyser1"', TD)
        self.assertIn('id = "AltGeyser2"', TD)
        self.assertRegex(TD, r"eruption = \{\s*lap = 3")
        m = re.search(r'planSha256 = "([0-9a-f]{64})"', TD)
        import hashlib
        self.assertEqual(m.group(1), hashlib.sha256((ROOT / "map" / "dino4" / "plan.json").read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
