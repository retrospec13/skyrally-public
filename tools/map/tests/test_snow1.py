#!/usr/bin/env python3
"""SNOW-1 "Frozen River Peak": the authored plan passes every adapt gate and carries the launch gameplay anchors
(TRACK_PIPELINE P1, LAUNCH_PROGRESSION 2b, CONTENT SNOW rows). Also checks that plan.json is exactly what
tools/map/author_snow1.py writes (no hand edits), the over/under crossing at the arch bridge, and the zone files
(material variants, lighting profile, deck style, sky faces).
Run: python3 -m unittest discover -s tools/map/tests -v"""
import hashlib
import json
import math
import re
import unittest

import numpy as np

import fixtures  # noqa: F401  (puts tools/map and tools/course on sys.path)
import adapt
import author_snow1 as author

ROOT = fixtures.ROOT
PLAN_PATH = ROOT / "map" / "snow1" / "plan.json"
ITEM_TYPES = {"Red", "Blue", "Yellow", "Green", "Rainbow", "Speed"}


def load_plan():
    return json.loads(PLAN_PATH.read_text())


class Snow1Gates(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = load_plan()
        cls.sk = cls.plan["skyrally"]
        cls.gp = cls.sk["gameplay"]
        cls.res = adapt.check(cls.plan)
        cls.length = cls.res.route.length

    def test_identity(self):
        self.assertEqual(self.sk["id"], "SNOW-1")
        self.assertEqual(self.sk["key"], "snow1")
        self.assertEqual(self.sk["zone"], "SNOW")
        self.assertEqual(self.sk["vehicle"], "plane")
        self.assertEqual(self.sk["lighting"], "SNOW-1")
        self.assertTrue((ROOT / self.sk["guide"]).is_file())

    def test_all_gates_pass(self):
        self.assertEqual([e for e in self.res.report.errors], [])
        self.assertEqual(self.res.gates["corridorPartIntrusions"], 0)
        # the gate saw the whole kit (bridge, lodge, gantry, portals, huts); since L61 the forest is set dressing, whose
        # corridor clearance test_set_dressing checks
        self.assertGreater(self.res.gates["collidableParts"], 150)

    def test_route_length_and_radius(self):
        self.assertTrue(self.sk["route"]["closed"])
        self.assertLessEqual(abs(self.length - self.sk["route"]["targetLength"]), 1.0)
        self.assertAlmostEqual(self.sk["route"]["targetLength"], 5000, delta=100)
        self.assertGreaterEqual(self.res.gates["minRadius"], 85.0)
        self.assertEqual(self.sk["route"]["radiusExceptions"], [])

    def test_flight_corridor_contract(self):
        self.assertEqual(self.sk["flight"]["corridor"], {"halfWidth": 34, "floor": 5, "ceiling": 44})
        self.assertEqual(self.sk["flight"]["lineOffset"], 14.0)

    def test_over_under_crossing_at_the_arch(self):
        """The lap passes UNDER the arch (river) and OVER it (deck run) at the bridge centre, corridors stacked."""
        bridge = [i for i in self.plan["instances"] if i["pf"] == "StoneArchBridge"]
        self.assertEqual(len(bridge), 1)
        cx, _, cz = bridge[0]["p"]
        wps = self.res.route.waypoints
        near = [w for w in wps if math.hypot(w.pos[0] - cx, w.pos[2] - cz) < 60]
        low = [w for w in near if w.pos[1] < 60]
        high = [w for w in near if w.pos[1] > 120]
        self.assertTrue(low and high, "route must cross the bridge centre both below and above")
        cor = self.sk["flight"]["corridor"]
        under_top = max(w.pos[1] for w in low) + cor["ceiling"]
        over_floor = min(w.pos[1] for w in high) + cor["floor"]
        self.assertGreater(over_floor - under_top, 50)  # room for the voussoir crown and the deck between them
        # the under-pass runs north-south, the over-pass east-west (a true crossing, not a parallel stack)
        t_low = low[len(low) // 2].tangent
        t_high = high[len(high) // 2].tangent
        self.assertLess(abs(t_low[0] * t_high[0] + t_low[2] * t_high[2]), 0.2)

    def test_checkpoints(self):
        st = self.gp["checkpoints"]["stations"]
        self.assertEqual(st[0], 0)
        gaps = [b - a for a, b in zip(st, st[1:])] + [self.length - st[-1]]
        for g in gaps:
            self.assertTrue(350 <= g <= 450, gaps)

    def test_rings_on_the_line(self):
        rings = self.gp["rings"]
        self.assertTrue(6 <= len(rings) <= 10)
        for r in rings:
            self.assertEqual(r["lateral"], 0)
            self.assertEqual(r["height"], self.sk["flight"]["lineOffset"])
            self.assertTrue(0 <= r["station"] < self.length)
        names = {r["name"] for r in rings}
        self.assertIn("BoosterRing_UnderArch", names)
        self.assertIn("BoosterRing_OverArch", names)

    def test_pads_and_pods(self):
        self.assertTrue(2 <= len(self.gp["pads"]) <= 4)
        pods = self.gp["pods"]
        self.assertEqual(len([p for p in pods if p["type"] != "Speed"]), 35)  # cubes v3: 7 two-deep clusters of 2 + 3
        self.assertTrue({p["type"] for p in pods} <= ITEM_TYPES)
        self.assertEqual({p["type"] for p in pods}, ITEM_TYPES)  # every type appears
        self.assertTrue(all(abs(p["lateral"]) <= 16 for p in pods))  # a cluster's back rank spans -10/0/+10
        self.assertEqual(len({p["name"] for p in pods}), len(pods))

    def test_start_and_finish(self):
        self.assertEqual(self.gp["finish"]["station"], 0)
        sg = self.gp["startGrid"]
        self.assertLess(adapt.grid_slot(sg, adapt.GRID_SLOTS)[0], 120)

    def test_alternate(self):
        alts = self.gp["alternates"]
        self.assertTrue(1 <= len(alts) <= 2)
        for alt in alts:
            self.assertIn(alt["style"], ("tunnel", "ledge"))
            self.assertTrue(0 <= alt["joinStation"] < alt["rejoinStation"] < self.length)
            pts = alt["points"]
            self.assertGreaterEqual(len(pts), 4)
            # both ends are mouths beside the line (eased from it); the middle runs well inside the gorge wall
            def off_line(p):
                return min(math.hypot(p[0] - w.pos[0], p[2] - w.pos[2]) for w in self.res.route.waypoints)
            ends = [off_line(pts[0]), off_line(pts[-1])]
            self.assertTrue(all(v < 90 for v in ends), ends)
            self.assertGreater(off_line(pts[len(pts) // 2]), 80)

    def test_coins(self):
        coins = self.gp["coins"]
        self.assertEqual(len(coins), 8)
        for c in coins:
            self.assertTrue(0 <= c["station"] < self.length)
            self.assertTrue(all(k in c for k in ("station", "lateral", "height")))
        on_alt = [c for c in coins if c.get("line")]
        self.assertGreaterEqual(len(on_alt), 1)
        alt = {a["id"]: a for a in self.gp["alternates"]}
        for c in on_alt:
            a = alt[c["line"]]
            self.assertTrue(a["joinStation"] < c["station"] < a["rejoinStation"])

    def test_hidden_key_behind_the_arch_on_the_under_route(self):
        key = self.gp["key"]
        self.assertTrue(0 <= key["station"] < self.length)
        self.assertGreater(abs(key["lateral"]), self.sk["flight"]["corridor"]["halfWidth"] + 20)  # off the line
        under = self.sk["provenance"]["underArchStation"]
        self.assertTrue(under < key["station"] < under + 150)  # just past the arch on the under route
        f = self.res.route.frame_at(key["station"])
        self.assertLess(f.pos[1], 60)  # river level, not the deck
        shrine = [i for i in self.plan["instances"] if i["pf"] == "KeyAlcoveShrine"]
        self.assertEqual(len(shrine), 1)

    def _ground(self, x, z):
        t = self.plan["terrain"]
        nx, c = t["nx"], t["cell"]
        fx, fz = (x - t["x0"]) / c, (z - t["z0"]) / c
        ix, iz = int(fx), int(fz)
        tx, tz = fx - ix, fz - iz
        h = t["heights"]
        at = lambda i, k: h[k * nx + i]  # noqa: E731
        return ((at(ix, iz) * (1 - tx) + at(ix + 1, iz) * tx) * (1 - tz)
                + (at(ix, iz + 1) * (1 - tx) + at(ix + 1, iz + 1) * tx) * tz)

    def test_alt_tunnel_buried_in_terrain(self):
        """Alt1 is a tunnel through the west wall: beside and over every interior point the height grid stands above
        the tube's roof (Deck.buildAlternate: walls to +31, roof top +34 over the line), so no wall or slab is exposed."""
        pts = self.gp["alternates"][0]["points"]
        for i in range(1, len(pts) - 1):
            p, a, b = pts[i], pts[i - 1], pts[i + 1]
            dx, dz = b[0] - a[0], b[2] - a[2]
            n = math.hypot(dx, dz)
            rx, rz = -dz / n, dx / n
            for off in (-19.0, 0.0, 19.0):
                g = self._ground(p[0] + rx * off, p[2] + rz * off)
                self.assertGreater(g - p[1], 34.0, (i, off, round(g - p[1], 1)))
        self.assertFalse([op for op in self.sk["shells"]["ops"] if op.get("mat") == "Rock" and op["op"] == "FillBlock"
                          and any(math.hypot(op["cf"][0] - q[0], op["cf"][2] - q[2]) < 30 for q in pts)],
                         "no stacked Terrain slabs over the tunnel")

    def test_key_notch_is_fly_through(self):
        """The key slot is carved long enough along the river to swerve in and out at cruise speed (110 studs/s at the
        145 deg/s sharp yaw = ~44-stud radius): a dead-end pocket would make the key collectable only by crashing."""
        key = self.gp["key"]
        f = self.res.route.frame_at(key["station"])
        kp = f.offset(key["lateral"], key["height"])
        air = [op for op in self.sk["shells"]["ops"] if op.get("mat") == "Air" and op["op"] in ("FillBlock", "FillCylinder")]

        def inside(p):
            for op in air:
                cf = op["cf"]
                d = [p[k] - cf[k] for k in range(3)]
                loc = [sum(cf[3 + 3 * r + c] * d[r] for r in range(3)) for c in range(3)]  # R^T d
                if op["op"] == "FillBlock":
                    if all(abs(loc[k]) <= op["size"][k] / 2 for k in range(3)):
                        return True
                elif math.hypot(loc[0], loc[2]) <= op["r"] and abs(loc[1]) <= op["h"] / 2:
                    return True
            return False

        t = f.tangent
        run = [s for s in range(-120, 121, 2) if inside([kp[0] + t[0] * s, kp[1], kp[2] + t[2] * s])]
        self.assertIn(0, run)
        lo = hi = 0
        while lo - 2 in run:
            lo -= 2
        while hi + 2 in run:
            hi += 2
        self.assertGreaterEqual(hi - lo, 90, (lo, hi))

    def test_battle_overlay_survival_on_the_lake(self):
        b = self.gp["modes"]["battle"]
        self.assertEqual(b["kind"], "survival")
        self.assertEqual(len(b["center"]), 3)
        self.assertGreater(b["radius"], 100)
        self.assertEqual(len(b["spawns"]), 4)
        for sp in b["spawns"]:
            self.assertEqual(len(sp), 3)
            self.assertLess(math.hypot(sp[0] - b["center"][0], sp[2] - b["center"][2]), b["radius"])
        self.assertGreaterEqual(len(b["pickups"]), 4)
        for pk in b["pickups"]:
            self.assertTrue(set(pk["types"]) <= {"Red", "Green", "Yellow"})
        self.assertEqual(b["rules"]["lives"], 3)

    def test_boss_hazard(self):
        boss = self.gp["boss"]
        self.assertEqual(boss["hazard"], "rolling snowballs")
        self.assertTrue(boss["anchors"])
        self.assertTrue(all(0 <= s < self.length for s in boss["anchors"]))

    def test_landmarks_named(self):
        pfs = {i["pf"].split("#")[0] for i in self.plan["instances"]}
        for name in ("StoneArchBridge", "MountainLodge", "FinishGantry", "MineTunnelPortal"):
            self.assertIn(name, pfs)
        # L61: the forest is the uploaded snow_pine_cluster prop (three firs per clone), no longer block-built pines
        pines = [d for d in self.sk["setDressing"] if d["key"] == "snow_pine_cluster"]
        self.assertGreater(len(pines), 150)

    def test_set_dressing(self):
        """L61 set dressing: uploaded SNOW props only, a few hundred placements, scale 0.6-1.6, every whole AABB
        (yawed footprint from the ground up to a rock-shelf snap plus the prop height) clear of the flight corridor,
        nothing inside the battle arena, on the bridge or over the Alt1 tunnel line."""
        lib = author.prop_library()
        sd = self.sk["setDressing"]
        self.assertTrue(150 <= len(sd) <= 600, len(sd))
        self.assertGreaterEqual(len({d["key"] for d in sd}), 7)
        cor = author.Corridor(author.Track())
        b = self.gp["modes"]["battle"]
        cx, cz = b["center"][0], b["center"][2]
        for d in sd:
            self.assertIn(d["key"], lib)
            self.assertTrue(0.6 <= d["scale"] <= 1.6)
            self.assertIs(d["snap"], True)
            sx, sy, sz = (v * d["scale"] for v in lib[d["key"]])
            hxz, _r = author.rotation_halves((sx, 1.0, sz), 0.0, d["yaw"], 0.0)
            g = d["pos"][1] - 2.0
            top = g + author.SHELF_RISE + sy
            c = [d["pos"][0], (g - 2.0 + top) / 2, d["pos"][2]]
            h = [hxz[0], (top - g + 2.0) / 2, hxz[2]]
            self.assertFalse(cor.hits(np.array([c]), np.array([h]), margin=author.PROP_MARGIN).any(), d)
            self.assertGreater(math.hypot(d["pos"][0] - cx, d["pos"][2] - cz) - math.hypot(sx, sz) / 2,
                               b["boundary"]["radius"] + 2.0, d)

    def test_terrain_grid(self):
        t = self.plan["terrain"]
        n = t["nx"] * t["nz"]
        self.assertEqual(len(t["heights"]), n)
        self.assertEqual(len(t["materials"]), n)
        self.assertTrue(set(t["materials"]) <= set(range(1, len(t["palette"]) + 1)))
        self.assertEqual([p["material"] for p in t["palette"]], ["Snow", "Rock", "Ice", "Glacier", "Ground", "Mud"])
        self.assertNotIn({"op": "Clear"}, self.sk["shells"]["ops"])  # never wipe another map's Terrain

    def test_deck_kind_none_and_style_module(self):
        self.assertEqual(self.sk["deck"]["style"], "snow1_open")
        src = (ROOT / "src" / "server" / "kit" / "styles" / "snow1.luau").read_text()
        self.assertIn("snow1_open", src)
        self.assertRegex(src, r'kind\s*=\s*"none"')

    def test_lighting_profile_module(self):
        src = (ROOT / "src" / "shared" / "lighting" / "snow1.luau").read_text()
        self.assertIn('["SNOW-1"]', src)
        names = re.findall(r'name = "([^"]+)"', src)
        self.assertTrue(names and all(n.startswith("SkyRally_") for n in names))
        self.assertIn("Atmosphere", src)
        self.assertNotIn("rbxassetid", src)  # sky ids come from the integrator after upload

    def test_materials_and_variants(self):
        variants = json.loads((ROOT / "assets" / "materials" / "snow_v1" / "variants.json").read_text())
        tex = {"T1_SNOW_DRIFT", "T2_GLACIER_ICE", "T3_FROZEN_RIVER", "T4_GRANITE_SNOWCAP", "T5_ICE_PAVERS", "T6_TIMBER"}
        for name, v in variants.items():
            self.assertTrue(name.startswith("SR_SNOW_"))
            self.assertIn(v["tex"], tex)
            self.assertIn(v["base"], adapt.MATERIALS)
            self.assertGreater(v["studsPerTile"], 0)
        self.assertEqual({v["tex"] for v in variants.values()}, tex)  # the whole texture set is used
        m = self.sk["materials"]
        self.assertEqual(m["terrainColor"], "#ffffff")
        for base, var in m["terrainOverrides"].items():
            self.assertEqual(variants[var]["base"], base)
        for rule in m["partRules"]:
            self.assertIn(rule["variant"], variants)
            base = rule.get("setMaterial") or rule.get("material")
            self.assertEqual(variants[rule["variant"]]["base"], base)

    def test_sky_faces(self):
        from PIL import Image
        for face in ("up", "side", "down"):
            with Image.open(ROOT / "assets" / "sky" / "snow1" / f"{face}.png") as im:
                self.assertEqual(im.size, (512, 512))
        with Image.open(ROOT / "assets" / "sky" / "snow1" / "side.png") as im:
            side = im.convert("RGB")
        # the one side face serves all four sides: its left and right edges must match
        # (adjacent pixel columns across the seam: only a hard edge such as a snow-cap line may flip on a row or two)
        bad = [y for y in range(512)
               if max(abs(a - b) for a, b in zip(side.getpixel((0, y)), side.getpixel((511, y)))) > 12]
        self.assertLessEqual(len(bad), 2, bad)


def _air_ops(sk):
    return [op for op in sk["shells"]["ops"] if op.get("mat") == "Air" and op["op"] in ("FillBlock", "FillCylinder", "FillBall")]


def _in_op(op, p):
    """Point inside a shells op (FillBlock / FillCylinder / FillBall), in the op's own frame."""
    if op["op"] == "FillBall":
        return math.dist(p, op["center"]) <= op["r"]
    cf = op["cf"]
    d = [p[k] - cf[k] for k in range(3)]
    loc = [sum(cf[3 + 3 * r + c] * d[r] for r in range(3)) for c in range(3)]  # R^T d
    if op["op"] == "FillBlock":
        return all(abs(loc[k]) <= op["size"][k] / 2 for k in range(3))
    return math.hypot(loc[0], loc[2]) <= op["r"] and abs(loc[1]) <= op["h"] / 2


class Snow1TrapFixes(unittest.TestCase):
    """Pins the data fixes for docs/audits/traps_snow1.md (SN-01..SN-04, SN-06, SN-07, SN-08). Each assert fails on the
    plan as it was audited."""

    @classmethod
    def setUpClass(cls):
        cls.plan = load_plan()
        cls.sk = cls.plan["skyrally"]
        cls.gp = cls.sk["gameplay"]
        cls.res = adapt.check(cls.plan)
        cls.battle = cls.gp["modes"]["battle"]
        t = cls.plan["terrain"]
        cls.t = t

    def _ground(self, x, z):
        return Snow1Gates._ground(self, x, z)

    def _solid_ops(self):
        return [op for op in self.sk["shells"]["ops"] if op.get("mat") not in ("Air", None)]

    def _collidable(self, pf=None):
        plan = self.plan if pf is None else {"prefabs": self.plan["prefabs"],
                                             "instances": [i for i in self.plan["instances"] if i["pf"] == pf]}
        c, h = adapt.collidable_parts(plan)[:2]
        return c, h

    def test_sn01_sn08_arena_edge_band_and_ceiling(self):
        """SN-01: the warn toast and the client edge pull start at the play radius, 80 studs inside the 280 return
        line (it was 30 studs, 0.27 s). SN-08: the ceiling is boundary centre Y + height, raised from 172 to 292."""
        b = self.battle
        self.assertLessEqual(b["radius"], 200)
        self.assertGreaterEqual(b["boundary"]["radius"] - b["radius"], 80)
        self.assertGreaterEqual(b["boundary"]["center"][1] + b["boundary"]["height"], 280)
        for sp in b["spawns"]:  # every seat stays inside the play circle
            self.assertLess(math.hypot(sp[0] - b["center"][0], sp[2] - b["center"][2]), b["radius"])

    def test_sn02_arena_ground_stays_under_the_seats(self):
        """SN-02: the lake is a 262 x 168 ellipse but the arena is a circle, so the north/south banks reached the 46
        seat height 190-210 studs out. Now: inside 250 the ground is 6+ under the seats, up to the return line it never
        reaches seat height, and no slope a plane can meet inside the return line is a crash face (> 35 degrees)."""
        b = self.battle
        cx, cz = b["center"][0], b["center"][2]
        seat_y = min(sp[1] for sp in b["spawns"])
        rr = b["boundary"]["radius"]
        worst_in, worst_edge, worst_slope = -1e9, -1e9, 0.0
        for a_deg in range(0, 360, 5):
            a = math.radians(a_deg)
            prev = None
            for r in range(0, int(rr) + 1, 5):
                g = self._ground(cx + r * math.cos(a), cz + r * math.sin(a))
                if r <= 250:
                    worst_in = max(worst_in, g)
                worst_edge = max(worst_edge, g)
                if prev is not None:
                    worst_slope = max(worst_slope, math.degrees(math.atan2(g - prev, 5.0)))
                prev = g
        self.assertLessEqual(worst_in, seat_y - 6, worst_in)
        self.assertLess(worst_edge, seat_y, worst_edge)
        self.assertLess(worst_slope, 30.0, worst_slope)

    def test_sn02_no_pines_or_rock_shelves_in_the_arena(self):
        """SN-02: pines stood at r 200-280 inside the battle circle (5 head-on crashes in the audit sweep). The only
        collidable things inside the return line (plus a pine crown) are the authored cover: huts and the 3 islets."""
        b = self.battle
        cx, cz = b["center"][0], b["center"][2]
        reach = b["boundary"]["radius"] + 2.0
        for inst in self.plan["instances"]:
            if inst["pf"] == "IceFishingHut":
                continue
            c, h = adapt.collidable_parts({"prefabs": {inst["pf"]: self.plan["prefabs"][inst["pf"]]}, "instances": [inst]})[:2]
            for cc, hh in zip(c, h):
                gap = math.hypot(cc[0] - cx, cc[2] - cz) - math.hypot(hh[0], hh[2])
                self.assertGreater(gap, reach, inst["pf"])
        rock = [op for op in self._solid_ops() if op["op"] == "FillBlock" and op["mat"] == "Rock"
                and math.hypot(op["cf"][0] - cx, op["cf"][2] - cz) < 300]
        self.assertEqual(len(rock), 3, [op["cf"][:3] for op in rock])  # the three lake islets only

    def test_sn03_seat_lines_to_the_centre_are_clear(self):
        """SN-03: islets 2/3 sat on the seat 1/2 -> centre line 130-140 studs ahead at GO. Each seat -> centre segment
        must have no solid shell op, hut or other collidable part within 12 studs (and the ground stays under it)."""
        b = self.battle
        c = b["center"]
        ops = [op for op in self._solid_ops() if op["op"] in ("FillBlock", "FillBall", "FillCylinder")]
        cc, hh = self._collidable()
        for sp in b["spawns"]:
            for k in range(0, 101, 2):
                t = k / 100
                p = [sp[0] + (c[0] - sp[0]) * t, sp[1], sp[2] + (c[2] - sp[2]) * t]
                self.assertLess(self._ground(p[0], p[2]), sp[1] - 8, (sp, t))
                for op in ops:
                    if op["op"] == "FillBall":
                        ext, oc = op["r"], op["center"]
                    else:
                        oc = op["cf"][:3]
                        ext = (math.hypot(op["size"][0], op["size"][2]) / 2 if op["op"] == "FillBlock"
                               else op["r"])
                    if oc[1] - 30 > sp[1]:
                        continue
                    self.assertGreater(math.hypot(p[0] - oc[0], p[2] - oc[2]) - ext, 12.0, (sp, t, op["cf"][:3]))
                for q, h in zip(cc, hh):
                    if abs(q[0] - p[0]) > 300 or abs(q[2] - p[2]) > 300 or q[1] - h[1] > sp[1] + 6:
                        continue
                    dx = max(abs(p[0] - q[0]) - h[0], 0.0)
                    dz = max(abs(p[2] - q[2]) - h[2], 0.0)
                    self.assertGreater(math.hypot(dx, dz), 12.0, (sp, t, q))

    def test_sn04_pods_away_from_the_seats(self):
        """SN-04: the east/west Red pods were 22 studs from seats 1/2, where the bots re-arm next to a respawning
        player. Every battle pickup is now 60+ studs from every seat."""
        for pk in self.battle["pickups"]:
            for sp in self.battle["spawns"]:
                self.assertGreaterEqual(math.hypot(pk["pos"][0] - sp[0], pk["pos"][2] - sp[2]), 60.0, (pk["pos"], sp))

    def test_sn06_portal_posts_are_decor(self):
        """SN-06: the MineTunnelPortal posts and their granite facing (+-22 / +-27) were collidable, so clipping the
        mouth was a WallHit crash. Only the lintel, 17+ over the tunnel flight line (+14), stays solid."""
        parts = self.plan["prefabs"]["MineTunnelPortal"]["parts"]
        solid = [pt for pt in parts if not (len(pt) > 12 and isinstance(pt[12], dict) and pt[12].get("nc"))]
        self.assertTrue(solid)
        for pt in solid:
            self.assertGreaterEqual(pt[2] - pt[5] / 2, 28.0, pt)  # over the tube carve (4..28); the line is +15.8 here

    def test_sn06_entry_mouth_is_a_flared_open_cut(self):
        """SN-06: the entry mouth was a 26-wide hole in a rock face square to a 60-70 degree turn. In front of it the
        rock is now carved open along the tube axis: 12 studs out the cut is 70+ wide and 25 out 100+ wide at the
        tunnel flight height (+14), so a plane that swerves in short of the axis meets air or a glancing funnel wall."""
        alt = self.gp["alternates"][0]
        p0, p1 = alt["points"][0], alt["points"][1]
        air = _air_ops(self.sk)
        ax = [p1[0] - p0[0], p1[2] - p0[2]]
        n = math.hypot(*ax)
        ax = [ax[0] / n, ax[1] / n]  # into the tunnel
        perp = [-ax[1], ax[0]]
        y = p0[1] + 14.0
        for out, half in ((12.0, 35.0), (25.0, 50.0)):
            for w in (-half, -half / 2, 0.0, half / 2, half):
                q = [p0[0] - ax[0] * out + perp[0] * w, y, p0[2] - ax[1] * out + perp[1] * w]
                self.assertTrue(any(_in_op(op, q) for op in air), (out, w, q))

    def test_sn07_key_pickup_clear_of_the_shrine(self):
        """SN-07: the key sat 17 studs in front of the collidable shrine, so its 16-stud pickup sphere touched the
        shrine face (17 of 30 key grabs crashed in the audit sim). The key is now 40+ studs clear of every collidable
        shrine part beyond the pickup radius, 40+ in front of the notch back wall, and still off the line."""
        key = self.gp["key"]
        f = self.res.route.frame_at(key["station"])
        kp = f.offset(key["lateral"], key["height"])
        c, h = self._collidable("KeyAlcoveShrine")
        self.assertTrue(len(c))
        gap = min(math.dist([0, 0, 0], [max(abs(kp[k] - q[k]) - hh[k], 0.0) for k in range(3)]) for q, hh in zip(c, h))
        self.assertGreaterEqual(gap - 16.0, 24.0, gap)
        self.assertGreaterEqual(kp[0] - (author.KEY_NOTCH["x0"] + author.ORIGIN[0]), 40.0)
        self.assertTrue(60 <= abs(key["lateral"]) <= 85, key["lateral"])


class Snow1Authored(unittest.TestCase):
    def test_plan_is_the_author_output(self):
        """plan.json is byte-identical to a fresh author run (generated data, never hand-edited; deterministic)."""
        plan = author.make_plan(author.build())
        text = json.dumps(plan, indent=None, separators=(",", ":"), sort_keys=False) + "\n"
        self.assertEqual(hashlib.sha256(text.encode()).hexdigest(), hashlib.sha256(PLAN_PATH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
