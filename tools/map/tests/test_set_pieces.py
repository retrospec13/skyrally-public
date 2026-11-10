"""Batch 2 set pieces against the map plans (docs/REMARKABLE.md items 13, 22 and 25).

* ISLAND-2 galleon cannons (modes.battle.launchers): only the runtime's allow-listed names, aimed down their own arc,
  cradles and landings on the surfaces a car really meets (galleon_geom), sand landings above the last tide.
* Lost Squeaky Ducks: each map's duck spot (src/shared/SetPieceRules.luau DUCK_SPOTS) names a real alternate and sits
  clear of the hidden key, the coins and the hub finds.
* Moon Monorail: the SPACE-4 viaduct numbers in SetPieceRules.MONORAIL match the plan they were read from.
Standard library + numpy; reads the Luau source with regular expressions, like galleon_geom.car_config()."""
from __future__ import annotations

import json
import math
import re
import unittest
from pathlib import Path

import numpy as np

import galleon_geom

ROOT = Path(__file__).resolve().parents[3]
RULES = (ROOT / "src" / "shared" / "SetPieceRules.luau").read_text()
MAPS = {"DINO-4": "dino4", "SNOW-1": "snow1", "ISLAND-2": "island2", "FOREST-1": "forest1", "SPACE-4": "space4",
        "HUB-0": "hub0"}


def plan(key: str) -> dict:
    return json.loads((ROOT / "map" / key / "plan.json").read_text())


def rule_number(name: str) -> float:
    m = re.search(r"SetPieceRules\." + name + r"\s*=\s*(-?[0-9.]+)", RULES)
    assert m, name
    return float(m.group(1))


def monorail_field(name: str) -> float:
    block = RULES[RULES.index("SetPieceRules.MONORAIL = table.freeze"):]
    block = block[: block.index("}) :: any")]
    m = re.search(r"\b" + name + r"\s*=\s*(-?[0-9.]+)", block)
    assert m, name
    return float(m.group(1))


def along(points, t: float) -> np.ndarray:
    pts = [np.asarray(p, float) for p in points]
    seg = [float(np.linalg.norm(b - a)) for a, b in zip(pts, pts[1:])]
    want = t * sum(seg)
    for a, b, L in zip(pts, pts[1:], seg):
        if want <= L:
            return a + (b - a) * (want / L if L > 0 else 0)
        want -= L
    return pts[-1]


class GalleonCannons(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = plan("island2")
        cls.b = cls.plan["skyrally"]["gameplay"]["modes"]["battle"]
        cls.cove = galleon_geom.Cove(cls.plan)
        cls.last_tide = cls.b["tideSteps"][-1]["level"]
        cls.names = set(re.findall(r"(\w+) = true", RULES[RULES.index("SetPieceRules.LAUNCHER_NAMES = "):].split("\n")[0]))

    def test_known_launcher_names_only(self):
        self.assertEqual(self.names, {"CrestCannon", "DeckCannon"})
        self.assertEqual({r["name"] for r in self.b["launchers"]}, self.names)

    def test_cradles_and_landings_on_real_surfaces(self):
        for r in self.b["launchers"]:
            for key, want in (("cradle", r["floor"]), ("land", r["ground"])):
                p = r[key]
                g = self.cove.ground(np.array([p[0]]), np.array([p[2]]), below=p[1] + 1.0)[0][0]
                self.assertAlmostEqual(g, want, delta=0.6, msg=(r["name"], key, g, want))
                self.assertAlmostEqual(p[1] - g, 1.9, delta=0.6, msg=(r["name"], key))
            if r["surface"] == "sand":
                self.assertGreaterEqual(r["ground"], self.last_tide, r["name"])
            else:
                self.assertAlmostEqual(r["ground"], self.b["decks"]["main"]["y"], delta=0.01)

    def test_barrels_aim_at_their_landings(self):
        lo, hi = 0.2, 0.85
        for r in self.b["launchers"]:
            axis = np.asarray(r["axis"], float)
            self.assertAlmostEqual(float(np.linalg.norm(axis)), 1.0, delta=2e-3)
            self.assertTrue(lo <= axis[1] <= hi, r["name"])
            muzzle = np.asarray(r["breech"], float) + axis * r["length"]
            to_land = np.asarray(r["land"], float) - muzzle
            way = axis[[0, 2]] / np.linalg.norm(axis[[0, 2]])
            self.assertGreater(float(way @ (to_land[[0, 2]] / np.linalg.norm(to_land[[0, 2]]))), 0.97, r["name"])

    def test_landings_off_the_pads_and_out_of_the_cradles(self):
        pads = [np.asarray(p, float) for p in self.b["spawns"]]
        radius = rule_number("TRIGGER_RADIUS")
        cradles = [np.asarray(r["cradle"], float) for r in self.b["launchers"]]
        for r in self.b["launchers"]:
            land = np.asarray(r["land"], float)
            for p in pads:
                self.assertGreaterEqual(math.hypot(*(land - p)[[0, 2]]), 20.0, r["name"])
            look = np.asarray(r["landLook"], float)
            for c in cradles:
                for t in np.arange(0.0, 30.01, 1.0):
                    self.assertGreaterEqual(math.hypot(*(land + look * t - c)[[0, 2]]), radius + 4.0, (r["name"], t))

    def test_ride_fits_the_validator_grace(self):
        car = galleon_geom.car_config()
        ride = rule_number("LOAD_TIME") + rule_number("FUSE_TIME") + rule_number("FLIGHT_TIME")
        self.assertLessEqual(ride + rule_number("GRACE_PAD"), rule_number("GRACE_MAX"))
        self.assertGreater(rule_number("GRACE_MAX"), car["TELEPORT_GRACE_TIME"])
        # the landing is announced exactly: the car is set down within the grace radius of it (placeAt drops <= 2)
        self.assertLess(2.0, car["TELEPORT_GRACE_RADIUS"])

    def test_salute_gun_beside_the_plank(self):
        gun = np.asarray(self.b["salute"]["gun"], float)
        lip = np.asarray(self.b["plank"]["lip"], float)
        self.assertLess(math.hypot(*(gun - lip)[[0, 2]]), 16.0)
        self.assertLess(gun[1], lip[1])


class Ducks(unittest.TestCase):
    def spots(self) -> dict:
        out = {}
        for tid, alt, t in re.findall(r'\["([A-Z0-9-]+)"\] = \{ alt = "(\w+)", t = ([0-9.]+)', RULES):
            out[tid] = (alt, float(t))
        return out

    def test_one_duck_per_launch_map(self):
        self.assertEqual(set(self.spots()), set(MAPS))

    def test_spots_on_real_alternates_clear_of_other_finds(self):
        for tid, (alt_id, t) in self.spots().items():
            p = plan(MAPS[tid])
            gp = p["skyrally"]["gameplay"]
            alts = {a["id"]: a for a in gp.get("alternates") or []}
            self.assertIn(alt_id, alts, tid)
            duck = along(alts[alt_id]["points"], t)
            key = gp.get("key")
            if isinstance(key, dict) and key.get("pos"):
                self.assertGreater(float(np.linalg.norm(duck - np.asarray(key["pos"], float))), 60.0, tid)
            for f in gp.get("finds") or []:
                self.assertGreater(float(np.linalg.norm(duck - np.asarray(f["pos"], float))), 60.0, (tid, f["id"]))
            self.assertTrue(0.1 <= t <= 0.9, tid)


class MoonMonorail(unittest.TestCase):
    def test_viaduct_numbers_match_space4(self):
        p = plan("space4")
        prov = p["skyrally"]["provenance"]
        stations = [i for i in p["instances"] if i["pf"] == "MonorailStation"]
        trains = [i for i in p["instances"] if i["pf"] == "MonorailTrain"]
        xs = sorted(i["p"][0] for i in stations)
        self.assertAlmostEqual(monorail_field("westX"), xs[0], delta=0.05)
        self.assertAlmostEqual(monorail_field("eastX"), xs[1], delta=0.05)
        self.assertAlmostEqual(monorail_field("viaductZ"), stations[0]["p"][2], delta=0.01)
        self.assertAlmostEqual(monorail_field("trainY"), trains[0]["p"][1], delta=0.01)
        self.assertAlmostEqual(monorail_field("restX"), min(i["p"][0] for i in trains), delta=0.05)
        a, b = prov["viaductCrossings"]
        block = RULES[RULES.index("crossA"):]
        self.assertAlmostEqual(float(re.search(r"crossA = \{ station = ([0-9.]+)", block).group(1)), a, delta=0.05)
        self.assertAlmostEqual(float(re.search(r"crossB = \{ station = ([0-9.]+)", block).group(1)), b, delta=0.05)
        # crossing A is the start straight's x; crossing B is 150 east of the parked eastbound train
        self.assertAlmostEqual(float(re.search(r"crossA = \{ station = [0-9.]+, x = ([0-9.]+)", block).group(1)),
                               p["skyrally"]["route"]["nodes"][0]["pos"][0], delta=0.5)
        east_train = max(trains, key=lambda i: i["p"][0])
        self.assertAlmostEqual(float(re.search(r"crossB = \{ station = [0-9.]+, x = ([0-9.]+)", block).group(1)),
                               east_train["p"][0] + 150.0, delta=0.5)


if __name__ == "__main__":
    unittest.main()
