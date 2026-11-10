#!/usr/bin/env python3
"""Track variety gate (docs/design/TRACK_VARIETY.md section 4): every map plan carries archetype, signature and
signatureVerb, no two maps share a primary archetype, and no two maps in a zone share a signature verb. The gate itself is
adapt.variety_gate (run by adapt.py for every plan under map/); this file checks it on synthetic blocks and on the
plans in the repo.
Run: python3 -m unittest discover -s tools/map/tests -v"""
import json
import unittest

import fixtures
import adapt

ROOT = fixtures.ROOT
MAPS = ("dino4", "forest1", "hub0", "island2", "snow1", "space4", "teststrip")


def block(key, zone, archetype, verb, id_=None):
    return {"id": id_ or key.upper(), "key": key, "zone": zone, "archetype": archetype,
            "signature": f"{verb.capitalize()} the course.", "signatureVerb": verb}


def run(plan_block, siblings):
    rep = adapt.Report()
    adapt.variety_gate({"skyrally": plan_block}, siblings, rep)
    return rep.codes()


class VarietyGate(unittest.TestCase):
    def test_distinct_maps_pass(self):
        me = block("a", "DINO", "Waking volcano", "weave")
        other = {"b": block("b", "DINO", "Badlands glide", "glide")}
        self.assertEqual(run(me, other), set())

    def test_shared_archetype_in_a_zone_fails(self):
        me = block("a", "DINO", "Waking volcano", "weave")
        other = {"b": block("b", "DINO", "  waking VOLCANO ", "glide")}
        self.assertEqual(run(me, other), {"variety.duplicate"})

    def test_shared_verb_in_a_zone_fails(self):
        me = block("a", "SNOW", "Figure-8", "cross")
        other = {"b": block("b", "SNOW", "Descent", "Cross")}
        self.assertEqual(run(me, other), {"variety.duplicate"})

    def test_other_zone_may_repeat_the_verb(self):
        me = block("a", "SNOW", "Figure-8", "cross")
        other = {"b": block("b", "SPACE", "Urban grid", "cross")}
        self.assertEqual(run(me, other), set())

    def test_archetype_is_unique_across_zones(self):
        # rule 1: a primary archetype is used by no other map, in any zone
        me = block("a", "SNOW", "Figure-8", "cross")
        other = {"b": block("b", "SPACE", " figure-8 ", "ride")}
        self.assertEqual(run(me, other), {"variety.duplicate"})

    def test_missing_field_fails(self):
        me = block("a", "SNOW", "Figure-8", "cross")
        for f in adapt.VARIETY_FIELDS:
            broken = dict(me)
            broken.pop(f)
            self.assertEqual(run(broken, {}), {"variety.field"}, f)
            broken[f] = "  "
            self.assertEqual(run(broken, {}), {"variety.field"}, f)

    def test_own_entry_is_not_a_duplicate(self):
        me = block("a", "DINO", "Waking volcano", "weave")
        self.assertEqual(run(me, {"a": dict(me)}), set())


class RepoMaps(unittest.TestCase):
    def test_every_plan_passes_against_the_others(self):
        plans = {k: json.loads((ROOT / "map" / k / "plan.json").read_text()) for k in MAPS}
        for k, plan in plans.items():
            others = {o: p["skyrally"] for o, p in plans.items() if o != k}
            self.assertEqual(run(plan["skyrally"], others), set(), k)

    def test_signature_is_one_sentence(self):
        for k in MAPS:
            sig = json.loads((ROOT / "map" / k / "plan.json").read_text())["skyrally"]["signature"]
            self.assertTrue(sig.endswith("."), k)
            self.assertEqual(sig.count(". "), 0, k)

    def test_sibling_scan_finds_the_repo_maps(self):
        sibs = adapt.sibling_skyrally(ROOT / "map" / "dino4" / "plan.json")
        self.assertEqual(set(sibs), set(MAPS) - {"dino4"})


if __name__ == "__main__":
    unittest.main()
