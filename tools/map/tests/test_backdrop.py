#!/usr/bin/env python3
"""Backdrop shells (visibility v1, tools/map/backdrop.py; owner report 2026-10-20 "too much of the map is constantly
not being displayed"): the plans of DINO-4, FOREST-1 and SNOW-1 carry a `backdrop` block, adapt turns it into
TrackData.backdrop, and every generated part is purely visual and out of play:
  * at least 20 studs outside every Air carve (the route tube at its largest radius), every route/alternate corridor
    sample and every battle arena cylinder; shell parts inside the sealed rock mass; floors under their lava slab top
    and under every route sample; ring parts beyond the heightfield and the plane leash; cores inside their wedge;
  * under 150 parts per map, every axis <= 2048, deterministic, and the build/<key>/TrackData.luau files are current;
  * the generator's own checks catch a wall in the hall, a floor at the lava surface and a core poking out.
No terrain op, collision, barrier, kill volume, rescue, bound or corridor changes (owner rule: wall driving stays).
Run: python3 -m unittest discover -s tools/map/tests -v"""
import json
import math
import re
import unittest

import numpy as np

import fixtures  # noqa: F401  (puts tools/map and tools/course on sys.path)
import adapt
import backdrop

ROOT = fixtures.ROOT
KEYS = ("dino4", "forest1", "snow1")


def load(key):
    plan = json.loads((ROOT / "map" / key / "plan.json").read_text())
    res = adapt.check(plan)
    wps = [{"pos": list(w.pos), "station": w.station} for w in res.route.waypoints]
    return plan, res, wps


class Backdrop(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.maps = {k: load(k) for k in KEYS}

    def parts(self, key):
        return self.maps[key][1].gates["backdrop"]

    def test_gates_pass_and_audit_is_clean(self):
        for key in KEYS:
            plan, res, wps = self.maps[key]
            self.assertEqual(res.report.errors, [], key)
            parts = self.parts(key)
            self.assertTrue(parts, key)
            self.assertEqual(backdrop.audit(plan, wps, parts), [], key)

    def test_counts_sizes_names(self):
        for key in KEYS:
            parts = self.parts(key)
            self.assertLess(len(parts), backdrop.MAX_PARTS, key)
            names = [p["name"] for p in parts]
            self.assertEqual(len(names), len(set(names)), key)
            for p in parts:
                self.assertTrue(p["name"].startswith("Backdrop_"), p["name"])
                self.assertLessEqual(max(p["size"]), backdrop.MAX_AXIS, p["name"])
                self.assertIn(p["kind"], ("shell", "floor", "ring", "core", "peak"))
        kinds = {k: {p["kind"] for p in self.parts(k)} for k in KEYS}
        self.assertEqual(kinds, {"dino4": {"shell", "floor"}, "forest1": {"ring"}, "snow1": {"core", "peak"}})

    def test_other_maps_have_none(self):
        for key in ("hub0", "island2", "space4", "teststrip"):
            plan = json.loads((ROOT / "map" / key / "plan.json").read_text())
            self.assertNotIn("backdrop", plan["skyrally"], key)

    def test_deterministic_and_trackdata_current(self):
        for key in KEYS:
            plan, res, wps = self.maps[key]
            again = backdrop.build(plan, wps)
            self.assertEqual(again, self.parts(key), key)
            text = (ROOT / "build" / key / "TrackData.luau").read_text()
            names = re.findall(r'name = "(Backdrop_[A-Za-z0-9_]+)"', text)
            self.assertEqual(names, [p["name"] for p in self.parts(key)],
                             f"build/{key}/TrackData.luau is stale: rerun tools/map/adapt.py map/{key}/plan.json")

    def test_dino4_shell_wraps_the_hall_and_its_tunnels(self):
        plan, _, wps = self.maps["dino4"]
        ops = plan["skyrally"]["shells"]["ops"]
        # the great hall: the first Air block after the mass (the critic v28 value-break Rock bands sit between them)
        h = next(i for i, o in enumerate(ops) if o["op"] == "FillBlock" and o["mat"] == "Air")
        self.assertEqual(ops[h - 1]["op"], "FillBlock" if h > 6 else "FillRouteBounds")
        self.assertEqual(ops[h]["size"], [1000, 230, 1200], "the great hall block")
        hall = backdrop.Box.from_cf(ops[h]["cf"], ops[h]["size"])
        walls = [p for p in self.parts("dino4") if p["kind"] == "shell" and "Wall" in p["name"]]
        ceil = [p for p in self.parts("dino4") if "Ceiling" in p["name"]]
        # every wall is beyond the hall block, the ten domes and the tube (audit) and the ceiling is over the domes
        for p in walls:
            self.assertGreaterEqual(backdrop.box_gap(backdrop.part_box(p), hall), 30 - 1e-6, p["name"])
        for p in ceil:
            self.assertGreaterEqual(p["cf"][1] - p["size"][1] / 2, 220 + 170 + 20, p["name"])
        # a closed ring: walls on every bearing from the hall centre
        c = np.array([-380.0, 130.0, -1050.0])
        for k in range(36):
            a = 2 * math.pi * k / 36
            d = np.array([math.cos(a), 0, math.sin(a)])
            hit = any(backdrop.part_box(p).point_distance(c + d * r) < 6 for r in range(0, 2400, 10) for p in walls)
            self.assertTrue(hit, f"bearing {k * 10}")

    def test_dino4_lava_plane_under_the_lava_sea(self):
        plan, _, _ = self.maps["dino4"]
        ops = plan["skyrally"]["shells"]["ops"]
        floors = [p for p in self.parts("dino4") if p["kind"] == "floor"]
        slab = ops[floors[0]["slab"]]
        self.assertEqual((slab["op"], slab["mat"]), ("FillBlock", "CrackedLava"))
        slab_top = slab["cf"][1] + slab["size"][1] / 2
        for p in floors:
            self.assertEqual(p["material"], "CrackedLava")
            self.assertEqual(p["color"], plan["skyrally"]["materials"]["terrainColors"]["CrackedLava"])
            self.assertLessEqual(p["cf"][1] + p["size"][1] / 2, slab_top - backdrop.FLOOR_SINK)
        for x, z in ((-640, -800), (-580, -1340), (-100, -1100), (-860, -1600), (100, -480)):
            self.assertTrue(any(backdrop.part_box(p).point_distance([x, p["cf"][1], z]) < 1e-6 for p in floors), (x, z))

    def test_forest_ridges_ring_the_heightfield(self):
        plan, _, _ = self.maps["forest1"]
        x0, z0, x1, z1 = backdrop.heightfield_rect(plan)
        rings = self.parts("forest1")
        for p in rings:
            c = p["cf"]
            self.assertFalse(x0 < c[0] < x1 and z0 < c[2] < z1, p["name"])
            self.assertLessEqual(c[1] + p["size"][1] / 2, 240 + 100, p["name"])
        mid = np.array([(x0 + x1) / 2, 120.0, (z0 + z1) / 2])
        for k in range(24):
            a = 2 * math.pi * k / 24
            d = np.array([math.cos(a), 0, math.sin(a)])
            self.assertTrue(any(backdrop.part_box(p).point_distance(mid + d * r) < 6
                                for r in range(0, 3200, 10) for p in rings), f"bearing {k * 15}")

    def test_snow_cores_inside_far_ranges(self):
        """The visibility cores stay under the v28 peaks: a culled range must not leave its peaks floating."""
        plan, _, wps = self.maps["snow1"]
        ops = plan["skyrally"]["shells"]["ops"]
        pts, _ = backdrop.route_samples(plan["skyrally"], wps)
        cores = [p for p in self.parts("snow1") if p["kind"] == "core"]
        self.assertGreaterEqual(len(cores), 40)
        tint = plan["skyrally"]["materials"]["terrainColors"]
        for p in cores:
            src = ops[p["source"]]
            self.assertEqual(p["color"], tint[src["mat"]], p["name"])
            planes = backdrop.wedge_planes(src["cf"], src["size"])
            for v in backdrop.wedge_vertices(p["cf"], p["size"]):
                for n, d in planes:
                    self.assertLessEqual(float(n @ v), d - backdrop.MARGIN, p["name"])
            self.assertGreaterEqual(float(np.min(backdrop.Box.from_cf(src["cf"], src["size"]).points_distance(pts))), 600)

    def test_snow_cores_of_different_colour_never_share_a_face(self):
        """A Snow cap wedge shares the slope, sides and back of the Rock wedge under it: equal insets put the two
        cores' faces in one plane, and the culled-terrain silhouette z-fights grey/white. Bottoms (hidden) excepted."""
        cores = [p for p in self.parts("snow1") if p["kind"] == "core"]
        for i, a in enumerate(cores):
            pa = backdrop.wedge_planes(a["cf"], a["size"])
            for b in cores[i + 1:]:
                if a["material"] == b["material"]:
                    continue
                if backdrop.box_gap(backdrop.part_box(a), backdrop.part_box(b)) > 0:
                    continue
                pb = backdrop.wedge_planes(b["cf"], b["size"])
                for k, (na, da) in enumerate(pa):
                    if k == 2:
                        continue  # bottom face
                    for na2, db in pb:
                        self.assertFalse(np.allclose(na, na2, atol=1e-3) and abs(da - db) < 4.0,
                                         f"{a['name']} / {b['name']} face {k} coplanar")

    def test_snow_peaks_are_faceted_far_and_small(self):
        """Critic v28 1.10: crossed gable pairs (<= 200 studs each way) with SmoothPlastic snow caps in cool rock, at
        least 600 studs from the course, every part an upright wedge and the audit clean."""
        plan, _, wps = self.maps["snow1"]
        pts, _ = backdrop.route_samples(plan["skyrally"], wps)
        parts = [p for p in self.parts("snow1") if p["kind"] == "peak"]
        self.assertGreaterEqual(len(parts), 40)
        for p in parts:
            self.assertEqual(p["shape"], "Wedge")
            self.assertLessEqual(max(p["size"][0], p["size"][2]), 202.0, p["name"])
            self.assertGreaterEqual(float(np.min(backdrop.part_box(p).points_distance(pts))), 600, p["name"])
            if p["name"].endswith("Cap"):
                self.assertEqual((p["material"], p["color"]), ("SmoothPlastic", "#eef3fb"), p["name"])
            else:
                self.assertEqual(p["material"], "Rock", p["name"])
                self.assertIn(p["color"], ("#6f7f99", "#788aa6", "#6a7a94"), p["name"])

    def test_wedge_inset_is_exact(self):
        cf = [5, 10, 15] + list(np.array([[0.6, 0, 0.8], [0, 1, 0], [-0.8, 0, 0.6]]).reshape(9))
        size = [300, 200, 260]
        icf, isize = backdrop.wedge_inset(cf, size, 24)
        planes = backdrop.wedge_planes(cf, size)
        verts = backdrop.wedge_vertices(icf, isize)
        gaps = [min(d - float(n @ v) for v in verts) for n, d in planes]
        for g in gaps:
            self.assertAlmostEqual(g, 24, places=3)
        self.assertIsNone(backdrop.wedge_inset(cf, [40, 30, 30], 24))

    def test_rules_catch_bad_parts(self):
        plan, _, wps = self.maps["dino4"]
        good = dict(self.parts("dino4")[0])
        inside = dict(good, cf=[-380, 130, -1050, 1, 0, 0, 0, 1, 0, 0, 0, 1])
        self.assertTrue(backdrop.audit(plan, wps, [inside]))
        floor = dict(next(p for p in self.parts("dino4") if p["kind"] == "floor"))
        floor["cf"] = list(floor["cf"])
        floor["cf"][1] += 6
        self.assertTrue(any("slab top" in m for m in backdrop.audit(plan, wps, [floor])))
        big = dict(good, size=[2100, 400, 8])
        self.assertTrue(any("over" in m for m in backdrop.audit(plan, wps, [big])))
        splan, _, swps = self.maps["snow1"]
        core = dict(next(p for p in self.parts("snow1") if p["kind"] == "core"))
        core["cf"] = list(core["cf"])
        core["cf"][1] += 40
        self.assertTrue(any("source wedge" in m for m in backdrop.audit(splan, swps, [core])))
        peak = dict(next(p for p in self.parts("snow1") if p["kind"] == "peak"))
        peak["cf"] = [float(swps[0]["pos"][0]), float(swps[0]["pos"][1]), float(swps[0]["pos"][2])] + list(peak["cf"][3:])
        self.assertTrue(any("corridor" in m for m in backdrop.audit(splan, swps, [peak])))
        self.assertTrue(backdrop.audit(plan, wps, [dict(good)] * (backdrop.MAX_PARTS + 1)))

    def test_bad_block_is_a_gate_error(self):
        plan, _, _ = self.maps["dino4"]
        bad = json.loads(json.dumps(plan))
        # the generator never emits a part that breaks a rule (it splits or drops it), so a block that asks for too
        # many tiles is what the gate stops
        bad["skyrally"]["backdrop"]["shells"][0]["tile"] = 60
        res = adapt.check(bad)
        self.assertIn("backdrop.clearance", res.report.codes())
        bad["skyrally"]["backdrop"] = {"walls": []}
        self.assertIn("backdrop.field", adapt.check(bad).report.codes())


if __name__ == "__main__":
    unittest.main()
