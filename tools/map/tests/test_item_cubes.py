"""Item cubes v3 layout over every launch map (docs/design/ITEM_BOXES.md, rules in tools/map/item_cubes.json): staggered
sets of 2 + 3 per lap, gaps (wrap included), first and last set, rank depth and the chain line between ranks, the cube
and part budget, Speed/Air pods away from the sets, and every cube and boost block clear of the rings, pads and deck
gaps (a cube inside a ring or over a jump gap reads as a bug)."""
from __future__ import annotations

import json
import math
import unittest

import fixtures  # noqa: F401  (puts tools/map and tools/course on sys.path)
import item_rows

ROOT = fixtures.ROOT
MAPS = ("hub0", "island2", "space4", "dino4", "forest1", "snow1")


def load(key: str) -> dict:
    return json.loads((ROOT / "map" / key / "plan.json").read_text())["skyrally"]


class ItemCubeLayout(unittest.TestCase):
    def test_layout_rules(self):
        for key in MAPS:
            sk = load(key)
            with self.subTest(key=key):
                bad = item_rows.audit(sk["gameplay"], sk["vehicle"], key, sk["route"]["targetLength"])
                self.assertEqual(bad, [])

    def test_budget_and_counts(self):
        rules = item_rows.RULES
        for key in MAPS:
            sk = load(key)
            sets = item_rows.item_sets(sk["gameplay"]["pods"])
            cubes = sum(len(s) for s in sets)
            with self.subTest(key=key):
                self.assertLessEqual(cubes, rules["maxCubesPerMap"])
                self.assertLessEqual(cubes * rules["cubeParts"], rules["maxCubeParts"])
                self.assertTrue(all(len(s) == 5 for s in sets))  # the owner's 'Staggered 2 + 3'
                self.assertTrue(all(p.get("cubeSet") and p.get("cubeRank") in (1, 2) for s in sets for p in s))
                if sk["vehicle"] == "plane":
                    self.assertEqual(len(sets), 7)
                    self.assertGreater(cubes, 21)  # owner: more cubes for the planes than v2's 7 x 3
                # Above the 32 guide only with the budget reasons written down in item_cubes.json
                if cubes > 32:
                    self.assertIn("_maxCubesPerMap", rules)
        self.assertGreaterEqual(rules["maxCubeParts"], rules["maxCubesPerMap"] * rules["cubeParts"])

    def test_stagger_chains(self):
        """A straight or gentle line at racing speed takes one cube of each rank: rank depth in range, every cube has a
        partner in the other rank within the chain angle, and the time between them at 128 studs/s stays under the
        rank lock (so the lock never eats the chained cube: it only holds back the same rank)."""
        lo, hi = item_rows.RULES["rankDepthRange"]
        tan = math.tan(math.radians(item_rows.RULES["maxChainAngleDeg"]))
        for key in MAPS:
            sk = load(key)
            for s in item_rows.item_sets(sk["gameplay"]["pods"]):
                front = [p for p in s if p["cubeRank"] == 1]
                back = [p for p in s if p["cubeRank"] == 2]
                depth = back[0]["station"] - front[0]["station"]
                with self.subTest(key=key, set=s[0]["cubeSet"]):
                    self.assertTrue(lo <= depth <= hi, depth)
                    self.assertEqual((len(front), len(back)), (2, 3))
                    for a in front:
                        self.assertTrue(any(math.hypot(a["lateral"] - b["lateral"], a["height"] - b["height"]) <= tan * depth for b in back))
                    self.assertLess(depth / 128.0, 1.0)
                    # the stagger: no back cube hides dead behind a front one
                    for b in back:
                        self.assertTrue(all(abs(b["lateral"] - a["lateral"]) >= 4 for a in front))

    def test_cubes_clear_of_rings_pads_and_gaps(self):
        for key in MAPS:
            sk = load(key)
            gp = sk["gameplay"]
            singles = [p for p in gp["pods"] if p["type"] in item_rows.SINGLE_TYPES]
            for s in item_rows.item_sets(gp["pods"]):
                for st in sorted({p["station"] for p in s}):
                    with self.subTest(key=key, station=st):
                        for r in gp["rings"]:
                            self.assertGreater(abs(st - r["station"]), 30, r["name"])
                        for pad in gp["pads"]:
                            self.assertGreater(abs(st - pad["station"]), 25, pad["name"])
                        if sk["vehicle"] == "car":
                            for g in sk["deck"].get("gaps", []) or []:
                                self.assertFalse(g["from"] - 60 <= st <= g["to"] + 60, g)
            if sk["vehicle"] == "car":
                for p in singles:  # the boost blocks v3 moved mid-gap
                    with self.subTest(key=key, single=p["name"]):
                        for r in gp["rings"]:
                            self.assertGreater(abs(p["station"] - r["station"]), 20, r["name"])
                        for pad in gp["pads"]:
                            self.assertGreater(abs(p["station"] - pad["station"]), 20, pad["name"])
                        for g in sk["deck"].get("gaps", []) or []:
                            self.assertFalse(g["from"] - 60 <= p["station"] <= g["to"] + 60, g)

    def test_audit_catches_a_bad_layout(self):
        sk = load("hub0")
        gp = dict(sk["gameplay"])
        sets = item_rows.item_sets(gp["pods"])
        drop = {p["name"] for p in sets[3]}  # remove one set: its neighbours' gap exceeds maxGap
        gp["pods"] = [p for p in gp["pods"] if p["name"] not in drop]
        bad = item_rows.audit(gp, "car", "hub0", sk["route"]["targetLength"])
        self.assertTrue(any("gap" in b for b in bad), bad)
        gp2 = dict(sk["gameplay"])
        gp2["pods"] = gp2["pods"] + [item_rows.speed_single("Bad_Speed", sets[0][0]["station"] + 60, 4.5)]
        self.assertTrue(any("next to a cube set" in b for b in item_rows.audit(gp2, "car", "hub0", 3600)))
        # a set whose back rank is too deep and too wide to chain fails both rules
        bent = [dict(p) for p in sets[1]]
        for p in bent:
            if p["cubeRank"] == 2:
                p["station"] += 30
                p["lateral"] = p["lateral"] * 3 + 30
        gp3 = dict(sk["gameplay"])
        gp3["pods"] = [p for p in gp3["pods"] if p["name"] not in {q["name"] for q in bent}] + bent
        bad3 = item_rows.audit(gp3, "car", "hub0", 3600)
        self.assertTrue(any("apart" in b for b in bad3) and any("deg" in b for b in bad3), bad3)


if __name__ == "__main__":
    unittest.main()
