#!/usr/bin/env python3
"""X-05 decor query rule (docs/audits/traps_summary.md X-05, D4-11): MapAdapter's last world step
(src/server/kit/DecorQuery.luau) clears CanQuery on every visible non-collidable part of the map, except the deck
(TrackRibbon), hazards (HazardType / LavaSeaFloor) and anything under a Road = true model. These tests mirror that rule
on the plans so a car map can never ship a queryable non-collidable part a wheel probe could stand on:

* the adapter runs the rule after the carve and keeps the folders its own deck and hazards are built in;
* on car maps, no non-collidable 30MAPS part the rule leaves queryable (invisible ones, Road-tagged models) lies within
  REACH studs above the drivable surface (CarController PROBE_UP is 2.5; the respawn drop ray is 30 long, so 4 covers
  the wheel probes with margin and every visible case is cleared by the rule anyway).

The behaviour of the rule itself on real instances is specced in tools/tests/traps_shared_spec.luau.
Run: python3 -m unittest discover -s tools/map/tests -v"""
from __future__ import annotations

import json
import math
import re
import unittest

import numpy as np

import fixtures
import adapt

ROOT = fixtures.ROOT
ADAPTER = ROOT / "src" / "server" / "MapAdapter.luau"
RULE = ROOT / "src" / "server" / "kit" / "DecorQuery.luau"
CAR_MAPS = ("hub0", "island2", "space4", "teststrip")
REACH = 4.0  # studs above the road top
PAVER_TOP = 2.7  # Deck pavers: TrackSeg top 1.6 + paver 1.4 thick at +2.0 -> top 2.7 over the route line


def nc_parts(plan: dict):
    """(centre, half extent, alpha, meta) of every non-collidable 30MAPS part, world AABB as adapt.collidable_parts."""
    prefabs = plan.get("prefabs") or {}
    out = []
    for i, inst in enumerate(plan.get("instances") or []):
        pf = prefabs.get(inst.get("pf"))
        r_inst = adapt.instance_rotation(inst.get("r"))
        if not isinstance(pf, dict) or r_inst is None:
            continue
        s = inst.get("s") or 1
        p = np.array(inst["p"], float)
        for j, part in enumerate(pf.get("parts") or [], 1):
            extra = part[12] if len(part) > 12 and isinstance(part[12], dict) else {}
            if extra.get("nc") is None or extra.get("nc") is False:
                continue
            alpha = extra.get("a") or 0
            r_part = adapt.rot_yxz(*(v or 0 for v in part[7:10]))
            rot = r_inst @ r_part
            centre = p + r_inst @ (np.array(part[1:4], float) * s)
            half = np.abs(rot) @ (np.array(part[4:7], float) * s * 0.5)
            out.append((centre, half, alpha, {"prefab": inst["pf"], "instance": i + 1, "part": j,
                                              "group": inst.get("g")}))
    return out


def road_tagged_groups(plan: dict) -> set[str]:
    """Model paths the plan tags Road = true through skyrally.modelAttributes."""
    tagged = set()
    for entry in plan["skyrally"].get("modelAttributes") or []:
        if (entry.get("attrs") or {}).get("Road") is True:
            tagged.add(str(entry.get("path")))
    return tagged


def kept_queryable(plan: dict):
    """The rule's complement on 30MAPS art: invisible non-collidable parts (Road-tagged models are listed separately:
    they are meant to be driven on and are judged by the support test instead)."""
    return [t for t in nc_parts(plan) if t[2] >= 1]


def over_road(plan: dict, waypoints, parts):
    """Parts whose AABB bottom is within (road top - 0.5, road top + REACH] over the deck."""
    half_width = float(plan["skyrally"]["deck"].get("width", 32)) * 0.5
    pts = np.array([w.pos for w in waypoints], float)
    hits = []
    for centre, half, alpha, meta in parts:
        d = np.hypot(pts[:, 0] - centre[0], pts[:, 2] - centre[2])
        k = int(np.argmin(d))
        if d[k] - max(half[0], half[2]) > half_width:
            continue
        road_top = pts[k, 1] + PAVER_TOP
        bottom = centre[1] - half[1]
        if road_top - 0.5 < bottom <= road_top + REACH:
            hits.append((meta, round(float(bottom - road_top), 2)))
    return hits


class AdapterRule(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.adapter = ADAPTER.read_text()
        cls.rule = RULE.read_text()

    def test_adapter_requires_the_rule_and_runs_it_after_the_carve(self):
        self.assertIn("require(script.Parent.kit.DecorQuery)", self.adapter)
        carve = self.adapter.index('step("carve"')
        decor = self.adapter.index('step("decorQuery"')
        waypoints = self.adapter.index('step("waypoints"')
        self.assertLess(carve, decor, "after the carve: its intrusion scan keeps seeing what it saw before")
        self.assertLess(decor, waypoints, "before the route data and TrackReady")
        self.assertIn("DecorQuery.apply(root)", self.adapter)

    def test_kept_folders_are_the_adapters_deck_and_hazard_folders(self):
        """Renaming the deck folder without the rule would make every paver unqueryable: cars would sink 1.1."""
        kept = set(re.findall(r"(\w+) = true", re.search(r"KEEP_FOLDERS = table\.freeze\(\{([^}]*)\}", self.rule).group(1)))
        self.assertEqual(kept, {"TrackRibbon", "Hazards"})
        self.assertIn('adapterFolder(root, "TrackRibbon")', self.adapter)
        self.assertIn('adapterFolder(root, "Hazards")', self.adapter)
        self.assertIn("Deck.build(td, ribbon)", self.adapter)
        self.assertIn("Deck.buildAlternate, alt, ribbon", self.adapter)

    def test_rule_keeps_lethal_volumes_queryable(self):
        """CarController.isLethal and FlightController's lava check find these by raycast."""
        self.assertIn('GetAttribute("HazardType") ~= nil', self.rule)
        self.assertIn('Name == "LavaSeaFloor"', self.rule)
        self.assertIn("Transparency >= 1", self.rule)


class CarMapsDecor(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.maps = {}
        for key in CAR_MAPS:
            plan = json.loads((ROOT / "map" / key / "plan.json").read_text())
            cls.maps[key] = (plan, adapt.check(plan).route)

    def test_no_queryable_non_collidable_art_over_the_road(self):
        for key, (plan, route) in self.maps.items():
            with self.subTest(map=key):
                self.assertEqual(plan["skyrally"]["vehicle"], "car")
                hits = over_road(plan, route.waypoints, kept_queryable(plan))
                self.assertEqual(hits, [], f"{key}: invisible non-collidable parts within {REACH} above the road keep "
                                           "CanQuery (the rule only clears visible ones): make them collidable, "
                                           "visible decor, or remove them")

    def test_road_tags_are_explicit(self):
        """A Road = true model keeps its non-collidable parts as ground: none is in use; a new one is a deliberate,
        reviewed choice (list it here with the surface it provides)."""
        for key, (plan, _) in self.maps.items():
            self.assertEqual(road_tagged_groups(plan), set(), key)

    def test_rule_covers_the_audited_decor_over_the_road(self):
        """The trap class X-05 names exists in the data (visible non-collidable parts within reach over a car road)
        and every one of them is visible, so the rule clears it."""
        total = 0
        for key, (plan, route) in self.maps.items():
            visible = [t for t in nc_parts(plan) if t[2] < 1]
            total += len(over_road(plan, route.waypoints, visible))
        self.assertGreater(total, 0, "no decor near the road left to cover: the X-05 rule still stands, update this test")


if __name__ == "__main__":
    unittest.main()
