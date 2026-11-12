#!/usr/bin/env python3
"""ISLAND-2 "Tropical Galleon Coast" plan (tools/map/author_island2.py output): every adapt gate passes, the car-track
limits hold and the launch anchors (gameplay, coins, key, water-battle overlay, boss hazards) are present as data.
Run: python3 -m unittest discover -s tools/map/tests -v"""
import json
import math
import re
import struct
import unittest

import numpy as np

import fixtures
import adapt
import galleon_geom
import route_geometry

ROOT = fixtures.ROOT
PLAN = ROOT / "map" / "island2" / "plan.json"
POD_TYPES = {"Red", "Blue", "Yellow", "Green", "Rainbow", "Speed"}
TEXTURES = {"T1_BEACH_SAND", "T2_SHALLOW_WATER_BED", "T3_COASTAL_ROCK", "T4_GRASS_TROPICAL", "T5_SHIP_DECK",
            "T6_CREAM_COBBLE", "T7_COAST_ROCK", "T8_SEA_GRASS", "T9_COVE_COBBLE"}


def is_vec3(v):
    return isinstance(v, list) and len(v) == 3 and all(isinstance(x, (int, float)) for x in v)


def grid_height(t, x, z):
    """Bilinear height of the 30MAPS grid, as builder_template height() (row-major heights[iz * nx + ix])."""
    nx, nz, cell = t["nx"], t["nz"], t.get("cell", 4)
    fx = (min(max(x, t["x0"]), t["x0"] + (nx - 1) * cell) - t["x0"]) / cell
    fz = (min(max(z, t["z0"]), t["z0"] + (nz - 1) * cell) - t["z0"]) / cell
    ix, iz = max(min(int(math.floor(fx)), nx - 2), 0), max(min(int(math.floor(fz)), nz - 2), 0)
    tx, tz = fx - ix, fz - iz
    hs = t["heights"]
    a, b = hs[iz * nx + ix], hs[iz * nx + ix + 1]
    c, d = hs[(iz + 1) * nx + ix], hs[(iz + 1) * nx + ix + 1]
    u, v = a + (b - a) * tx, c + (d - c) * tx
    return u + (v - u) * tz


def in_block(p, op):
    """Point inside an axis-aligned FillBlock op (identity rotation)."""
    cf, size = op["cf"], op["size"]
    return cf[3:] == [1, 0, 0, 0, 1, 0, 0, 0, 1] and all(abs(p[k] - cf[k]) <= size[k] / 2 for k in range(3))


class Island2Plan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = json.loads(PLAN.read_text())
        cls.res = adapt.check(cls.plan)
        cls.sk = cls.plan["skyrally"]
        cls.gp = cls.sk["gameplay"]
        cls.route = cls.res.route
        cls.length = cls.route.length

    def in_loop(self, s):
        return isinstance(s, (int, float)) and 0 <= s < self.length

    # ------------------------------------------------------------------------------------------- gates
    def test_adapt_gates_pass(self):
        self.assertEqual(self.res.report.errors, [], [e.msg for e in self.res.report.errors][:10])
        g = self.res.gates
        self.assertLessEqual(abs(self.length - self.sk["route"]["targetLength"]), 1.0)
        self.assertEqual(self.sk["route"]["targetLength"], 4600)
        self.assertGreaterEqual(g["minRadius"], 85.0)
        self.assertEqual(self.sk["route"]["radiusExceptions"], [])
        self.assertEqual(g["corridorPartIntrusions"], 0)
        self.assertGreater(g["collidableParts"], 500)  # the gate really checked the art

    def test_identity(self):
        sk = self.sk
        self.assertEqual((sk["id"], sk["key"], sk["zone"], sk["vehicle"], sk["lighting"], sk["laps"]),
                         ("ISLAND-2", "island2", "ISLAND", "car", "ISLAND-2", 3))
        self.assertTrue((ROOT / sk["guide"]).is_file(), sk["guide"])
        self.assertTrue(self.sk["route"]["closed"])

    # ------------------------------------------------------------------------------------- car limits
    def test_car_track_limits(self):
        banks = [n["bank"] for n in self.sk["route"]["nodes"]]
        self.assertTrue(all(abs(b) <= 12 for b in banks), banks)
        rows, _ = route_geometry.analyse([list(w.pos) for w in self.route.waypoints], min_radius=85)
        self.assertLessEqual(max(abs(r["grade"]) for r in rows), 15.0)
        deck = self.sk["deck"]
        self.assertTrue(40 <= deck["width"] <= 48)
        self.assertEqual(deck["piersEvery"], 0)  # road deck: bridge style without piers
        self.assertEqual(deck["style"], "island2_cobble")
        fl = self.sk["flight"]
        self.assertTrue(fl["corridor"]["floor"] < fl["lineOffset"] < fl["corridor"]["ceiling"])
        # the jump is a short height step on a straight, and a car at top speed really leaves the road
        jump = self.sk["provenance"]["jump"]["128"]
        self.assertGreater(jump["flight"], 15)
        self.assertGreater(jump["maxGap"], 1.0)

    def test_guide_landmarks_are_named_prefabs(self):
        pf = self.plan["prefabs"]
        for name in ("GalleonHull", "GalleonDecks", "GalleonRigging", "GalleonGangwayFore", "GalleonGangwayAft",
                     "CavernMouthArch", "CavernArchRib", "CavernExitArch", "KeyAlcoveArch", "Lighthouse",
                     "StartFinishArch", "TikiTorch"):
            self.assertIn(name, pf)
        self.assertTrue(any(k.startswith("PalmTree") for k in pf))
        self.assertTrue(any(k.startswith("BridgeArch") for k in pf))
        self.assertFalse([k for k in pf if k.startswith(("LM_", "MESH_"))])
        used = {i["pf"] for i in self.plan["instances"]}
        self.assertTrue({"GalleonHull", "CavernMouthArch", "KeyAlcoveArch", "Lighthouse"} <= used)

    def test_terrain_grid_and_shells(self):
        t = self.plan["terrain"]
        n = t["nx"] * t["nz"]
        self.assertEqual(len(t["heights"]), n)
        self.assertEqual(len(t["materials"]), n)
        self.assertTrue(all(1 <= m <= len(t["palette"]) for m in t["materials"]))
        self.assertEqual(t["water"]["level"], self.sk["provenance"]["origin"][1])  # Terrain Water at sea level
        ops = [o["op"] for o in self.sk["shells"]["ops"]]
        self.assertNotIn("Clear", ops)  # would wipe the compiled height grid
        for need in ("CarveRouteTube", "RouteFloorFill"):
            self.assertIn(need, ops)
        self.assertIn("Water", {o.get("mat") for o in self.sk["shells"]["ops"]})

    # ---------------------------------------------------------------------------------------- gameplay
    def test_checkpoints(self):
        st = self.gp["checkpoints"]["stations"]
        self.assertEqual(st[0], 0)
        gaps = [b - a for a, b in zip(st, st[1:])] + [self.length - st[-1]]
        self.assertTrue(all(350 <= g <= 450 for g in gaps), gaps)

    def test_rings_pads_pods(self):
        rings, pads, pods = self.gp["rings"], self.gp["pads"], self.gp["pods"]
        main_rings = [r for r in rings if not r.get("line")]
        self.assertTrue(6 <= len(main_rings) <= 10)
        self.assertTrue(all(r["lateral"] == 0 and self.in_loop(r["station"]) for r in rings))  # on the drive line
        self.assertTrue(2 <= len(pads) <= 4)
        items = [p for p in pods if p["type"] != "Speed"]
        self.assertEqual(len(items), 35)  # item cubes v3: 7 staggered sets of 2 + 3 (rules: test_item_cubes)
        self.assertTrue({p["type"] for p in pods} <= POD_TYPES)
        self.assertTrue(all(abs(p["lateral"]) <= 16 for p in items))  # across the road, on the deck
        self.assertTrue(all(p["lateral"] == 0 for p in pods if p["type"] == "Speed"))  # boost blocks on the line, mid-gap
        names = [x["name"] for x in rings + pads + pods]
        self.assertEqual(len(names), len(set(names)))

    def test_alternates_join_the_race_line(self):
        alts = self.gp["alternates"]
        self.assertTrue(0 < len(alts) <= 2)
        for alt in alts:
            self.assertTrue(self.in_loop(alt["joinStation"]) and self.in_loop(alt["rejoinStation"]))
            self.assertLess(alt["joinStation"], alt["rejoinStation"])
            for end, s in ((alt["points"][0], alt["joinStation"]), (alt["points"][-1], alt["rejoinStation"])):
                on_line = self.route.frame_at(s).pos
                self.assertLess(math.dist(end, on_line), 1.0, (alt["id"], end, on_line))

    # ------------------------------------------------------------------------------ Alt2: the headland wall-ride
    def cliff(self):
        alts = {a["id"]: a for a in self.gp["alternates"]}
        self.assertIn("Alt2", alts)
        return alts["Alt2"]

    def test_cliff_line_is_a_cliff_style_line_on_the_baked_rock(self):
        alt = self.cliff()
        self.assertEqual(alt["style"], "cliff")  # no deck, no carve: the existing rock face is the road
        pts = alt["points"]
        t = self.plan["terrain"]
        self.assertGreater(len(pts), 60)
        # every point sits on the baked ground (CLIFF_SINK under it), never in water, never in air
        for p in pts[1:-1]:
            g = grid_height(t, p[0] - t["x0"] + t["x0"], p[2])  # grid_height takes world x, z
            self.assertAlmostEqual(p[1], g - 2.0, delta=0.35, msg=p)
            self.assertGreaterEqual(g, self.sk["provenance"]["origin"][1] + 1.6, p)
        # 48-stud windows never climb or fall steeper than 0.8 (39 deg): the face itself is 63-65 deg, the path crosses
        # the contours at a shallow angle
        d = [math.dist(a, b) for a, b in zip(pts, pts[1:])]
        h = [grid_height(t, p[0], p[2]) for p in pts]
        for i in range(len(d) - 2):
            self.assertLessEqual(abs(h[i + 3] - h[i]) / sum(d[i:i + 3]), 0.8, (i, pts[i]))
        # it really climbs the headland: the roof is more than 100 studs over the start
        self.assertGreater(max(h) - h[0], 100)
        prov = self.sk["provenance"]["cliffLine"]
        self.assertEqual((prov["join"], prov["rejoin"]), (alt["joinStation"], alt["rejoinStation"]))
        self.assertLessEqual(prov["maxSlope48"], 0.8)
        self.assertLessEqual(prov["maxTurnDeg"], 25.0)  # a chase camera can follow it

    def test_cliff_line_keeps_clear_of_the_protected_areas(self):
        o = self.sk["provenance"]["origin"]
        pts = [(p[0] - o[0], p[2] - o[2]) for p in self.cliff()["points"]]
        (ix, iz), (ia, ib) = (165.0, -168.0), (100.0, 112.0)  # author INLET: the key's approach shallows
        for x, z in pts:
            self.assertGreaterEqual(math.hypot((x - ix) / ia, (z - iz) / ib), 1.1, (x, z))  # key inlet
            self.assertGreater(math.hypot(x - 150.0, z + 255.0), 90.0, (x, z))  # key alcove
        # the first water-battle disc (the art venue; the battle arena itself covers the whole cove since owner
        # 2026-10-21, cliff line included: in a battle it is only rock to drive on)
        venue = self.gp["modes"]["battle"]["venue"]
        c = venue["center"]
        for p in self.cliff()["points"]:
            self.assertGreater(math.hypot(p[0] - c[0], p[2] - c[2]), venue["radius"] + 15, p)  # (the road itself starts 176 from its centre)
        # no roof breach (grotto skylight, chamber balls, alcove recess) within 40 of the line
        for op in self.sk["shells"]["ops"]:
            if op.get("mat") != "Air":
                continue
            ctr = op.get("center") or op["cf"][:3]
            r = op.get("r") or max(op["size"][0], op["size"][2]) / 2
            for p in self.cliff()["points"][1:-1]:
                self.assertGreater(math.hypot(p[0] - ctr[0], p[2] - ctr[2]), r + 40, (op, p))

    def test_cliff_line_joins_and_rejoins_cleanly(self):
        alt = self.cliff()
        self.assertGreater(alt["joinStation"], 30)  # after the start line and the grid
        self.assertGreater(alt["rejoinStation"] - alt["joinStation"], 1000)
        end = np.array(alt["points"][-1]) - np.array(alt["points"][-2])
        tan = np.array(self.route.frame_at(alt["rejoinStation"]).tangent)
        ang = math.degrees(math.acos(float(np.dot(end[[0, 2]] / np.hypot(end[0], end[2]), tan[[0, 2]]))))
        # merges along the road, never across it: V7A (v26) found the old 34 deg rejoin at station 1690 aimed the car at
        # the unwalled sea edge of the clifftop 55 studs on
        self.assertLessEqual(ang, 15.0)
        # the last 200 studs come in from the inland (right) side and close in on the road gently: never left of the centre
        # line, and a car that holds the line's heading from any point there drives 110+ studs before it reaches the
        # sea-side deck edge (22 left of the centre; the old 34 deg rejoin reached it in ~40, about 0.3 s at speed)
        pts = np.array(alt["points"])
        cum = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))]
        wps = self.route.waypoints
        for i in range(len(pts) - 1):
            if cum[i] < cum[-1] - 200:
                continue
            w = self.route.frame_at(min(wps, key=lambda w: math.dist(w.pos, pts[i])).station)
            lat = float(np.dot(np.array(pts[i])[[0, 2]] - np.array(w.pos)[[0, 2]], np.array(w.right)[[0, 2]]))
            self.assertGreaterEqual(lat, -1.0, (i, lat))
            d = pts[i + 1] - pts[i]
            cosang = float(np.dot(d[[0, 2]] / np.hypot(d[0], d[2]), np.array(w.tangent)[[0, 2]]))
            sin_in = math.sin(math.acos(max(-1.0, min(1.0, cosang))))
            self.assertGreaterEqual((lat + 22.0) / max(sin_in, 1e-6), 110.0, (i, lat))
        # it arrives on the right of the road (the inland side): the parapets are on the left
        f = self.route.frame_at(alt["rejoinStation"] - 60)
        prev = np.array(alt["points"][-4]) - np.array(f.pos)
        right = np.array(f.right)
        self.assertGreater(float(np.dot(prev[[0, 2]], right[[0, 2]])), 0.0)
        # the join is a departure to the right, off the beach side of the road (no parapet there)
        out = np.array(alt["points"][3]) - np.array(alt["points"][0])
        r0 = np.array(self.route.frame_at(alt["joinStation"]).right)
        self.assertGreater(float(np.dot(out[[0, 2]], r0[[0, 2]])), 0.0)

    def test_cliff_line_entry_tell_and_pad(self):
        alt = self.cliff()
        pf, inst = self.plan["prefabs"], self.plan["instances"]
        for name in ("CliffChevron", "CliffBanner", "CliffArrow"):
            self.assertIn(name, pf)
            # every part is non-colliding: the tell never changes what a car touches
            self.assertTrue(all(len(p) > 12 and p[12].get("nc") for p in pf[name]["parts"]), name)
        lights = sum(1 for p in pf["CliffBanner"]["parts"] if len(p) > 12 and p[12].get("l"))
        n_banner = sum(1 for i in inst if i["pf"] == "CliffBanner")
        self.assertEqual(n_banner, 4)
        self.assertLessEqual(lights * n_banner, 4)  # MapLight budget: four flag lights in all
        self.assertGreaterEqual(sum(1 for i in inst if i["pf"] == "CliffArrow"), 10)
        self.assertGreaterEqual(sum(1 for i in inst if i["pf"] == "CliffChevron"), 20)
        # nothing else stands on the line: no collidable prop within 18 studs of it (torches 21 away at the departure)
        line = [(p[0], p[2]) for p in alt["points"]]
        for i in inst:
            if i["pf"].startswith("Cliff"):
                continue
            if any(len(p) <= 12 or not p[12].get("nc") for p in pf[i["pf"]]["parts"]):
                d = min(math.hypot(i["p"][0] - x, i["p"][2] - z) for x, z in line)
                self.assertGreater(d, 18.0, (i["pf"], i["p"]))
        for dr in self.sk["setDressing"]:
            d = min(math.hypot(dr["pos"][0] - x, dr["pos"][2] - z) for x, z in line)
            self.assertGreater(d, 30.0, dr)
        # the boost pad sits on the line beyond the road edge (not in a racing lane) and carries the car onto the face
        pad = next(p for p in self.gp["pads"] if p["name"] == "GroundBoost_CliffEntry")
        self.assertGreater(pad["lateral"], 26)
        f = self.route.frame_at(pad["station"])
        pos = f.offset(pad["lateral"], 0)
        self.assertLess(min(math.hypot(pos[0] - x, pos[2] - z) for x, z in line), 8.0)
        # v37: no free boost at GO: the pad lies 150+ studs (horizontal) from the grid's front row
        g = self.route.frame_at(self.gp["startGrid"]["station"]).pos
        self.assertGreater(math.hypot(pos[0] - g[0], pos[2] - g[2]), 150.0)

    def test_cliff_line_exit_tell(self):
        # ground chevrons along the run-out on the inland plain, pointing along the road, all off the deck
        tell = self.sk["provenance"]["cliffLine"]["tell"]
        self.assertGreaterEqual(tell["exitArrows"], 4)
        alt = self.cliff()
        end = np.array(alt["points"][-1])
        arrows = [i for i in self.plan["instances"] if i["pf"] == "CliffArrow" and math.dist(i["p"], end) < 400]
        self.assertGreaterEqual(len(arrows), tell["exitArrows"])
        wps = self.route.waypoints
        for a in arrows:
            self.assertGreater(min(math.hypot(a["p"][0] - w.pos[0], a["p"][2] - w.pos[2]) for w in wps), 26.0, a)

    def test_cliff_line_rings(self):
        """Booster rings on the cliff line (v26 pace: a clean run about 1 s faster than the main route, TRACK_VARIETY 5a)."""
        alt = self.cliff()
        rings = [r for r in self.gp["rings"] if r.get("line")]
        self.assertEqual(len(rings), 3)
        pts = np.array(alt["points"])
        cum = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))]
        t = self.plan["terrain"]
        # boosted turning radius: CarConfig PAD_BOOST_SPEED / turnRate at boost speed (test_boost_windows reads the same)
        from test_boost_windows import WINDOW_TAIL, boost_model  # noqa: E402
        model = boost_model("car")
        radius, window = model["radius"], model["distance"] + WINDOW_TAIL  # line rings: their own window on the polyline
        horiz = np.r_[0.0, np.cumsum(np.hypot(*np.diff(pts[:, [0, 2]], axis=0).T))]

        def line_xz(a):  # point at horizontal distance a along the line
            return np.interp(a, horiz, pts[:, 0]), np.interp(a, horiz, pts[:, 2])

        for r in rings:
            self.assertEqual(r["line"], "Alt2")
            self.assertTrue(r["name"].startswith("BoosterRing_Cliff"))
            a = r["along"]  # horizontal studs along the line; the station maps the 3D distance (RouteBranch.cliffProgress)
            a3 = float(np.interp(a, horiz, cum))
            self.assertAlmostEqual(r["station"], alt["joinStation"] + (alt["rejoinStation"] - alt["joinStation"]) * a3 / cum[-1], delta=0.1)
            pos, up, look = np.array(r["pos"]), np.array(r["up"]), np.array(r["look"])
            x, z = line_xz(a)
            g = grid_height(t, x, z)
            # 8 studs off the ground along its normal, over the line; a hull 2.5 off the ground is well inside the 16-stud
            # trigger reach (CarConfig.RING_TRIGGER_RADIUS) and inside the 9.95 opening
            hull = np.array([x, g, z]) + up / np.linalg.norm(up) * 2.5
            self.assertLess(float(np.linalg.norm(pos - hull)), 9.95 - 1.2)
            k = int(np.searchsorted(horiz, a))
            self.assertGreater(float(np.dot(look, pts[min(k + 1, len(pts) - 1)] - pts[k - 1])), 0)
            # never on the road: 40+ studs (16 trigger reach + the 22-stud half deck) from every route waypoint
            self.assertGreater(min(math.dist(w.pos, pos) for w in self.route.waypoints), 40.0, r["name"])
            # the boost window stays inside the boosted turning radius (crash-loop rule of test_boost_windows)
            ss = np.arange(a, min(a + window, horiz[-1] - 20.5), 5.0)
            X, Z = np.interp(ss, horiz, pts[:, 0]), np.interp(ss, horiz, pts[:, 2])
            for k in range(len(ss)):
                if ss[k] - 20 < 0:
                    continue
                p0 = np.array([np.interp(ss[k] - 20, horiz, pts[:, 0]), np.interp(ss[k] - 20, horiz, pts[:, 2])])
                p1 = np.array([X[k], Z[k]])
                p2 = np.array([np.interp(ss[k] + 20, horiz, pts[:, 0]), np.interp(ss[k] + 20, horiz, pts[:, 2])])
                cr = abs((p1 - p0)[0] * (p2 - p0)[1] - (p1 - p0)[1] * (p2 - p0)[0])
                if cr > 1e-6:
                    rr = np.linalg.norm(p1 - p0) * np.linalg.norm(p2 - p1) * np.linalg.norm(p2 - p0) / (2 * cr)
                    self.assertGreaterEqual(rr, radius, (r["name"], float(ss[k]), float(rr)))
        # no road dressing for them: the pirate ring gates frame the main-route rings only
        self.assertEqual(sum(1 for i in self.plan["instances"] if i["pf"].startswith("RingGate#")), len(self.gp["rings"]) - len(rings))
        # in order along the line, after the foot crease and before the merge
        alongs = [r["along"] for r in rings]
        self.assertEqual(alongs, sorted(alongs))

    def test_coins(self):
        coins = self.gp["coins"]
        self.assertEqual(len(coins), 8)
        self.assertEqual(sorted(c["id"] for c in coins), list(range(1, 9)))
        self.assertTrue(all(self.in_loop(c["station"]) for c in coins))
        alt_ids = {a["id"]: a for a in self.gp["alternates"]}
        on_alt = [c for c in coins if c["line"] in alt_ids]
        self.assertGreaterEqual(len(on_alt), 1)
        for c in on_alt:  # the coin really sits over that alternate's line
            f = self.route.frame_at(c["station"])
            pos = f.offset(c["lateral"], c["height"])
            d = min(math.dist(pos, p) for p in alt_ids[c["line"]]["points"])
            self.assertLess(d, 14.0)

    def test_key(self):
        key = self.gp["key"]
        self.assertIsInstance(key, dict)
        self.assertTrue(self.in_loop(key["station"]))
        self.assertGreaterEqual(abs(key["lateral"]), 40)  # off-line: reachable only by leaving the racing line
        self.assertTrue(is_vec3(key["pos"]))

    def test_key_alcove_is_drivable(self):
        # The approach from the inlet shallows to the arch stays at the sill (no bank across the mouth) and above the
        # car's drown depth; the recess is carved from the arch front to past the key.
        t = self.plan["terrain"]
        sea = t["water"]["level"]
        ax, floor, az = next(i["p"] for i in self.plan["instances"] if i["pf"] == "KeyAlcoveArch")
        for dz in range(4, 44, 2):  # the arch faces +z, its recess runs to -z
            for dx in (-8, 0, 8):
                g = grid_height(t, ax + dx, az + dz)
                self.assertLessEqual(g, floor + 1.0, (dx, dz, g))
                self.assertGreaterEqual(g, sea - 1.3, (dx, dz, g))
        key = self.gp["key"]["pos"]
        air = [o for o in self.sk["shells"]["ops"] if o["op"] == "FillBlock" and o["mat"] == "Air"]
        self.assertTrue(any(in_block([ax, floor + 3, az + 2.5], o) and in_block(key, o) for o in air))
        self.assertLessEqual(key[1] - floor, 6.0)  # within reach of a hull on the alcove floor or the plinth

    def test_rings_frame_the_car(self):
        # kit/Gameplay ring: clear opening radius 9.95. The hull (lineOffset over the ribbon, 2.4 tall) passes through
        # the opening, which reaches under the paver tops (2.7): the car never drives through a rim (rims are
        # queryable, so a wheel probe would also ride up onto one).
        line = self.sk["flight"]["lineOffset"]
        for r in self.gp["rings"]:
            if r.get("line"):
                continue  # cliff-line rings: test_cliff_line_rings
            self.assertLessEqual(abs(r["height"] - line) + 1.2, 9.95, r["name"])
            self.assertLess(r["height"] - 9.95, 2.7, r["name"])

    def test_cavern_tube_stays_sealed(self):
        # Every tube ball (worst-case radius, upper lobe at its highest) stays under the headland crest, and the first
        # and last balls sit >= 20 inside the portal faces, so the cut through each face stays inside the portal arch.
        ops = self.sk["shells"]["ops"]
        tube = next(o for o in ops if o["op"] == "CarveRouteTube")
        st = self.sk["provenance"]["stations"]
        self.assertGreaterEqual(tube["fromStation"], st["cavernMouth"] + 20)
        self.assertLessEqual(tube["toStation"], st["cavernExit"] - 20)
        t = self.plan["terrain"]
        for i, w in enumerate(self.route.waypoints, 1):
            if tube["fromStation"] <= w.station <= tube["toStation"]:
                top = w.pos[1] + max(tube["lift"] + tube["radiusMax"],
                                     tube["upperLift"] + 30 + tube["radiusMax"] * tube["upperScale"] if i % 2 == 0 else 0)
                self.assertGreater(grid_height(t, w.pos[0], w.pos[2]), top + 4, (round(w.station), top))
        pool = [o for o in ops if o["op"] == "FillCylinder" and o["mat"] == "Water"]
        self.assertTrue(pool and pool[0]["r"] >= 66)  # the grotto pool fills the whole carved bowl

    def test_parapets_and_props_meet_the_ground(self):
        pf = self.plan["prefabs"]
        t = self.plan["terrain"]
        for k in pf:
            if k.startswith(("Parapet_", "BridgeParapet_")):
                body = pf[k]["parts"][0]
                self.assertLessEqual(body[2] - body[5] / 2, -12.5 if k.startswith("Parapet_") else -7.0, k)
        for inst in self.plan["instances"]:
            p = inst["p"]
            if inst["pf"].startswith("BridgeParapet_"):
                # against the curbs over the deck edge (curb outer face 25.2), never out in the air beside the bridge
                s0 = min(self.route.waypoints, key=lambda w: math.dist((w.pos[0], w.pos[2]), (p[0], p[2]))).station
                d = min(math.dist((f.pos[0], f.pos[2]), (p[0], p[2]))
                        for f in (self.route.frame_at(s0 + k * 0.5) for k in range(-40, 41)))
                self.assertTrue(25.9 <= d <= 27.0, (inst["pf"], d))
            elif inst["pf"].split("#")[0] in ("TikiTorch", "PalmTree", "BeachHut", "CargoCrates"):
                self.assertLessEqual(p[1] - grid_height(t, p[0], p[2]), 0.1, inst["pf"])  # standing, not floating

    def test_water_battle_overlay(self):
        b = self.gp["modes"]["battle"]
        self.assertEqual(b["kind"], "water")
        self.assertTrue(is_vec3(b["center"]) and b["radius"] > 0)
        self.assertGreaterEqual(len(b["spawns"]), 4)
        self.assertEqual(len(b["spawnLooks"]), len(b["spawns"]))
        for p in b["spawns"] + b["pickupAnchors"]:
            self.assertTrue(is_vec3(p))
            self.assertLessEqual(math.hypot(p[0] - b["center"][0], p[2] - b["center"][2]), b["radius"])
        steps = b["tideSteps"]
        self.assertEqual(len(steps), 3)
        levels = [s["level"] for s in steps]
        times = [s["atSeconds"] for s in steps]
        self.assertEqual(levels, sorted(levels))
        self.assertEqual(times, sorted(times))
        self.assertGreater(levels[0], b["baseLevel"])
        self.assertEqual(len(b["gangways"]), 2)
        self.assertGreaterEqual(len(b["pickupAnchors"]), 4)
        # the galleon decks stay above the highest tide (the arena shrinks toward them)
        self.assertGreater(b["decks"]["main"]["y"], levels[-1] + 3)

    def test_cavern_mouth_battle_barrier(self):
        # Trap I2-05: the race road leaves the water-battle arena through the soft band (st 251 is 165 from the
        # centre, st 270 is 176, past the 175 return radius) into the cavern, and the boundary return dropped the car
        # onto a flooded pad. A battle-only barrier closes the mouth arch: modes.battle data (server/battle/
        # BattleBarriers builds it into the BattleOverlay), never an instance, so race/boss/coin keep the road.
        b = self.gp["modes"]["battle"]
        bars = b["barriers"]
        self.assertEqual(len(bars), 1)
        bar = bars[0]
        self.assertEqual(bar["name"], "CavernMouthBarrier")
        st = self.sk["provenance"]["stations"]
        self.assertTrue(250 <= bar["station"] <= 262, bar["station"])
        cf = bar["cf"]
        pos = np.array(cf[:3])
        f = self.route.frame_at(bar["station"])
        self.assertLess(math.dist(pos, f.pos), 0.01)
        rot = np.array(cf[3:]).reshape(3, 3)
        right, up, back = rot[:, 0], rot[:, 1], rot[:, 2]
        self.assertTrue(np.allclose(rot.T @ rot, np.eye(3), atol=2e-3))
        self.assertTrue(np.allclose(up, [0, 1, 0]))
        self.assertGreater(float(np.dot(right, f.right)), 0.999)
        c = np.array(b["center"])
        to_centre = np.array([c[0] - pos[0], 0, c[2] - pos[2]])
        d = float(np.linalg.norm(to_centre))
        # the arena face (+Z) looks back toward the arena; the wall stands inside the return line (never a teleport).
        # Since the arena covers the whole cove (owner 2026-10-21) it stands inside the play radius too: it closes the
        # cavern road, which would otherwise lead a battle car under the headland.
        self.assertGreater(float(np.dot(back, to_centre / d)), 0.5)  # the road meets the arena at ~55 degrees
        self.assertTrue(d < b["softBoundary"]["radius"] + b["softBoundary"]["softWidth"] - 5, d)
        # inside the mouth arch: the arch's jambs flank the collider, which ends inside every jamb block
        arch = next(i for i in self.plan["instances"] if i["pf"] == "CavernMouthArch")
        along = float(np.dot(np.subtract(arch["p"], pos), -back))
        self.assertLessEqual(abs(along) + bar["collider"]["size"][2] / 2, 7.5)  # the jambs are 15 deep
        self.assertAlmostEqual(arch["p"][1], pos[1], delta=0.1)
        jambs = [q for q in self.plan["prefabs"]["CavernMouthArch"]["parts"]
                 if q[0] == "B" and 38 <= abs(q[1]) <= 40 and q[2] < 30 and len(q) == 12]  # the 3 stacked blocks a side
        self.assertEqual(len(jambs), 6)
        inner = max(abs(q[1]) - q[4] / 2 for q in jambs)
        outer = min(abs(q[1]) + q[4] / 2 for q in jambs)
        size, centre = bar["collider"]["size"], bar["collider"]["center"]
        self.assertTrue(inner < size[0] / 2 < outer, (inner, size[0] / 2, outer))
        self.assertGreater(size[0] / 2, self.sk["deck"]["width"] / 2 + 10)  # deck and shoulders
        self.assertLessEqual(centre[1] - size[1] / 2, 0.0)  # from under the paver top (ribbon + 2.7) ...
        self.assertGreaterEqual(centre[1] + size[1] / 2, 32.0)  # ... to the arch spring (no hop over it)
        self.assertEqual(centre[2], 0.0)
        face = centre[2] + size[2] / 2
        # props stay behind the arena face, so the car meets one flat wall; every row is a builder row
        for row in bar["parts"]:
            self.assertIn(len(row), (12, 13))
            self.assertIn(row[0], ("B", "C", "S", "W"))
            rx, ry, rz = (math.radians(v) for v in row[7:10])
            m = (np.array([[math.cos(ry), 0, math.sin(ry)], [0, 1, 0], [-math.sin(ry), 0, math.cos(ry)]])
                 @ np.array([[1, 0, 0], [0, math.cos(rx), -math.sin(rx)], [0, math.sin(rx), math.cos(rx)]])
                 @ np.array([[math.cos(rz), -math.sin(rz), 0], [math.sin(rz), math.cos(rz), 0], [0, 0, 1]]))
            self.assertLessEqual(row[3] + float(np.abs(m[2]) @ (np.array(row[4:7]) / 2)), face + 1e-6, row)
        self.assertLessEqual(len(bar["parts"]), 48)
        for sign in bar["signs"]:
            self.assertTrue(1 <= sign["part"] <= len(bar["parts"]))
            self.assertEqual(sign["face"], "Back")
        self.assertEqual(bar["snore"]["cue"], "barrier_snore")
        self.assertLess(bar["snore"]["offset"][2], -face)  # the kraken snores from inside the cave
        # battle only: no barrier instance or prefab in the art, so the race through the cavern stays open
        self.assertFalse(any("Barrier" in i["pf"] for i in self.plan["instances"]))
        self.assertFalse(any("Barrier" in k for k in self.plan["prefabs"]))
        self.assertGreaterEqual(bar["station"], st["cavernMouth"] - 10.5)

    def test_boss_hazards(self):
        boss = self.gp["boss"]
        self.assertIn("mines", boss["hazard"])
        self.assertIn("bubbles", boss["hazard"])
        self.assertTrue(boss["anchors"] and all(self.in_loop(s) for s in boss["anchors"]))
        self.assertTrue(all(self.in_loop(s) for s in boss["rematch"]["anchors"]))

    # ------------------------------------------------------------------------- materials, light, sky
    def test_materials_and_variants(self):
        variants = json.loads((ROOT / "assets" / "materials" / "island_v1" / "variants.json").read_text())
        for name, v in variants.items():
            self.assertRegex(name, r"^SR_ISLAND_[A-Za-z]+$")
            self.assertIn(v["tex"], TEXTURES)
            self.assertIn(v["base"], adapt.MATERIALS)
        m = self.sk["materials"]
        self.assertEqual(m["terrainColor"], "#ffffff")
        # L61 grade: explicit per-material tints (olive sea-grass, never the old neon #7ad354 / #6cbf4c)
        tints = m["terrainColors"]
        self.assertEqual(set(tints), set(m["terrainOverrides"]))
        g = tints["Grass"]
        r, gg, b = (int(g[i:i + 2], 16) for i in (1, 3, 5))
        self.assertLess(gg - max(r, b), 40, g)  # muted: green leads red/blue by under 40
        self.assertNotIn("T3_COASTAL_ROCK", {v["tex"] for v in variants.values()})  # the tile with baked grass ledges
        palette_mats = {p["material"] for p in self.plan["terrain"]["palette"]}
        for base, var in m["terrainOverrides"].items():
            self.assertEqual(variants[var]["base"], base)
            self.assertIn(base, palette_mats)
        for rule in m["partRules"]:
            v = variants[rule["variant"]]
            self.assertEqual(v["base"], rule.get("setMaterial") or rule.get("material"))

    def test_lighting_and_deck_style_modules(self):
        light = (ROOT / "src" / "shared" / "lighting" / "island2.luau").read_text()
        self.assertIn('["ISLAND-2"]', light)
        self.assertNotRegex(light, r"rbxassetid://")  # sky ids are added by the integrator after upload
        style = (ROOT / "src" / "server" / "kit" / "styles" / "island2.luau").read_text()
        self.assertTrue(re.search(r"\bisland2_cobble\s*=", style))

    def test_set_dressing(self):
        """L61 set dressing: uploaded ISLAND props only, a few hundred placements at most, scale 0.8-1.3, every whole
        AABB (yawed footprint from the ground up to the snap rise plus the prop height) clear of the car corridor,
        nothing in the water-battle arena or on the Plank Dune, nothing within 28 studs of the Alt1 boardwalk line."""
        import author_island2 as A
        lib = A.prop_library()
        sd = self.sk["setDressing"]
        self.assertTrue(80 <= len(sd) <= 400, len(sd))
        self.assertEqual({d["key"] for d in sd}, set(lib))
        cor = A.Corridor(self.route)
        b = self.gp["modes"]["battle"]["venue"]  # the first water-battle disc: the art keeps out of it
        cx, cz = b["center"][0], b["center"][2]
        alt = np.array([[p[0], p[2]] for p in self.gp["alternates"][0]["points"]])
        cs, hs = [], []
        for d in sd:
            self.assertTrue(0.8 <= d["scale"] <= 1.3, d)
            self.assertIs(d["snap"], True)
            c, h = A.prop_aabb(lib[d["key"]], d["pos"], d["yaw"], d["scale"])
            cs.append(c)
            hs.append(h)
            sx, _sy, sz, _collide = lib[d["key"]]
            r = math.hypot(sx, sz) * d["scale"] / 2
            self.assertGreater(math.hypot(d["pos"][0] - cx, d["pos"][2] - cz) - r, b["radius"] + 2.0, d)
            self.assertGreater(float(np.min(np.hypot(alt[:, 0] - d["pos"][0], alt[:, 1] - d["pos"][2]))) - r, 28.0, d)
        hits = cor.hits(np.array(cs), np.array(hs), margin=A.PROP_MARGIN)
        self.assertFalse(hits.any(), [sd[i] for i in np.nonzero(hits)[0][:5]])

    def test_horizon_islands_stay_in_the_sea_frame(self):
        frame = self.sk["provenance"]["seaFrame"]
        t = self.plan["terrain"]
        gx1, gz1 = t["x0"] + (t["nx"] - 1) * t["cell"], t["z0"] + (t["nz"] - 1) * t["cell"]
        balls = [o for o in self.sk["shells"]["ops"] if o["op"] == "FillBall" and o["mat"] in ("Rock", "Grass")]
        self.assertGreaterEqual(len(balls), 10)
        for o in balls:
            c, r = o["center"], o["r"]
            self.assertTrue(frame[0] < c[0] - r and c[0] + r < frame[1] and frame[2] < c[2] - r and c[2] + r < frame[3], o)
            self.assertFalse(t["x0"] - r < c[0] < gx1 + r and t["z0"] - r < c[2] < gz1 + r, o)  # never over the grid

    def test_sky_faces(self):
        for face in ("up", "side", "down"):
            raw = (ROOT / "assets" / "sky" / "island2" / f"{face}.png").read_bytes()
            self.assertEqual(raw[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", raw[16:24]), (512, 512))



class GalleonBattle(unittest.TestCase):
    """Trap audit G1 (docs/audits/traps_island2.md I2-01/02/03/04/08/11): the galleon is a fortress a player chooses,
    never a cage. Geometry is rebuilt from the plan's parts and terrain (galleon_geom); car numbers come from
    src/shared/CarConfig.luau."""

    @classmethod
    def setUpClass(cls):
        cls.plan = json.loads(PLAN.read_text())
        cls.b = cls.plan["skyrally"]["gameplay"]["modes"]["battle"]
        cls.cove = galleon_geom.Cove(cls.plan)
        cls.car = galleon_geom.car_config()
        cls.deck = cls.b["decks"]["main"]["y"]
        cls.levels = [cls.b["baseLevel"]] + [s["level"] for s in cls.b["tideSteps"]]
        cls.top_level = cls.levels[-1]
        cls.drown = cls.b["drownDepth"]
        cls.pads = [np.asarray(p, float) for p in cls.b["spawns"]]
        cls.pad_ground = [cls.cove.ground(p[0], p[2], below=p[1] + 2)[0][0] for p in cls.pads]
        lanes = {}
        for g in cls.b["gangways"]:
            top, foot = np.asarray(g["top"], float), np.asarray(g["foot"], float)
            st, sf = cls.cove.to_ship(top), cls.cove.to_ship(foot)
            lanes[g["name"]] = {"z": st[2], "x0": st[0], "x1": sf[0], "y0": top[1], "y1": foot[1], "w": g["width"]}
        cls.lanes = lanes
        pk = cls.b["plank"]
        cls.plank_z = float(cls.cove.to_ship(pk["lip"])[2])
        cls.plank_w = pk["width"]

    def dry(self, g: float, level: float) -> bool:
        return level - g <= self.drown

    def ramp_top(self, lane: dict, x: float) -> float:
        return lane["y0"] + (lane["y1"] - lane["y0"]) * (x - lane["x0"]) / (lane["x1"] - lane["x0"])

    def on_deck(self, i: int) -> bool:
        return self.pad_ground[i] >= self.deck - 3

    # ------------------------------------------------------------------------------- seats and respawn pads
    def test_seat_order_crest_pads_and_no_deck_seat(self):
        # Owner 2026-10-21: eight cars (BattleRules.FIELD), a sand pad each, none on the galleon (a deck respawn read
        # as being stranded on the ship). Slot 1 is the player's seat, crest B (FlightServer slot 1); bots take the
        # free pads in order. Every pad stays dry at the last tide step with WaterRules.SAFE_MARGIN (1.2) to spare,
        # so a respawn is never handed a pad the tide is about to take (I2-01).
        self.assertEqual(len(self.pads), 8)
        self.assertFalse(any(self.on_deck(i) for i in range(len(self.pads))), [round(g, 2) for g in self.pad_ground])
        for i, g in enumerate(self.pad_ground):
            self.assertTrue(self.dry(g - 1.2, self.top_level), (i + 1, g))
            self.assertLess(g, self.b["baseLevel"] + 8, (i + 1, "beach level, not a cliff top"))
        self.assertLess(math.hypot(self.pads[0][0] + 5215, self.pads[0][2] - 4195), 8, "the seat is crest B")
        # Spread out: no two pads within 60 studs, and the first four (a 1 + 3 field) 80+ apart.
        flat = lambda a, b: math.hypot(a[0] - b[0], a[2] - b[2])  # noqa: E731
        for i in range(len(self.pads)):
            for j in range(i + 1, len(self.pads)):
                self.assertGreaterEqual(flat(self.pads[i], self.pads[j]), 80 if j < 4 else 60, (i + 1, j + 1))

    def test_pads_stand_clear_of_props(self):
        # The car's footprint (HALF_LENGTH x HALF_WIDTH along its authored heading) on every pad is clear of walls and
        # flat within a climb (the audit's crest A stood on a tiki torch at (-5220.4, 4238.3)).
        hl, hw = self.car["HALF_LENGTH"], self.car["HALF_WIDTH"]
        for i, (p, d) in enumerate(zip(self.pads, self.b["spawnLooks"])):
            d = np.asarray(d, float)
            side = np.array([-d[2], 0.0, d[0]])
            pts = [p + d * a + side * c for a in np.arange(-hl, hl + 0.01, 0.75) for c in np.arange(-hw, hw + 0.01, 0.75)]
            X, Z = np.array([q[0] for q in pts]), np.array([q[2] for q in pts])
            G, _ = self.cove.ground(X, Z, below=p[1] + 2)
            hit = self.cove.walls(X, Z, np.full(X.shape, self.pad_ground[i]))
            self.assertTrue(all(h is None for h in hit), (i + 1, set(hit) - {None}))
            self.assertLess(float(np.max(np.abs(G - self.pad_ground[i]))), 2.2, i + 1)

    def test_spawn_looks_run_clear(self):
        # Authored headings (I2-02 fix 2 / I2-04 data side): unit, flat, and 12 studs (the car's length plus a
        # second at respawn speed) of ground ahead with no wall and no step a car cannot climb. The deck pad looks
        # straight down the aft gangway and has a clear 30-stud run off the ship.
        looks = [np.asarray(v, float) for v in self.b["spawnLooks"]]
        for i, (p, d) in enumerate(zip(self.pads, looks)):
            self.assertAlmostEqual(float(np.linalg.norm(d)), 1.0, places=2)
            self.assertEqual(d[1], 0.0)
            reach = 30.0 if self.on_deck(i) else 12.0
            prev = self.pad_ground[i]
            for t in np.arange(1.0, reach + 0.01, 1.0):
                for lat in (-3.0, 0.0, 3.0):
                    q = p + d * t + np.array([-d[2], 0, d[0]]) * lat
                    g, _ = self.cove.ground(q[0], q[2], below=prev + 2.3)
                    wall = self.cove.walls(q[0], q[2], g)[0]
                    self.assertIsNone(wall, (i + 1, t, lat))
                    self.assertLess(abs(g[0] - prev), 2.2 if lat == 0 else 3.0, (i + 1, t, lat))
                prev = self.cove.ground((p + d * t)[0], (p + d * t)[2], below=prev + 2.3)[0][0]
        for i, d in enumerate(looks):
            if self.on_deck(i):  # a deck pad (none since owner 2026-10-21) faces the gangways' way off
                self.assertGreater(float(d @ self.cove.ship_dir(1, 0)), 0.999, i + 1)

    # ---------------------------------------------------------------------------- deck edges and openings
    def edge_state(self, x, z, outward, deck_y):
        """At a deck edge point (ship frame): 'wall' if a solid stands across the wall-ray band over the deck just
        inboard, 'open' if a car carries on across it onto a surface within a climb (a ramp or the plank), else
        'drop'. The inboard reference may be the kicker (up to 2.4 over the deck there), never a rail top (2.6-3)."""
        wi = self.cove.ship(x - outward[0] * 1.2, 0, z - outward[1] * 1.2)
        g_in = self.cove.ground(wi[0], wi[2], below=deck_y + 2.5)[0][0]
        we = self.cove.ship(x, 0, z)
        if self.cove.walls(we[0], we[2], g_in)[0] is not None:
            return "wall", g_in
        ge = self.cove.ground(we[0], we[2], below=g_in + 2.3)[0][0]
        wo = self.cove.ship(x + outward[0] * 1.6, 0, z + outward[1] * 1.6)
        go = self.cove.ground(wo[0], wo[2], below=ge + 2.3)[0][0]
        return ("open" if abs(ge - g_in) <= 2.2 and abs(go - ge) <= 2.2 else "drop"), g_in

    def assert_edge(self, x0, z0, x1, z1, outward, deck_y, label):
        """Walk a deck edge: every point is walled or continues onto a ramp or the plank: never a drop off the deck."""
        n = max(2, int(math.hypot(x1 - x0, z1 - z0) / 0.25) + 1)
        holes = []
        for k in range(n):
            x, z = x0 + (x1 - x0) * k / (n - 1), z0 + (z1 - z0) * k / (n - 1)
            state, g = self.edge_state(x, z, outward, deck_y)
            if state == "drop":
                holes.append((round(x, 2), round(z, 2), round(g, 1)))
        self.assertEqual(holes, [], label)

    def test_deck_edges_closed_or_onto_a_ramp(self):
        # Starboard: openings only where a 16-wide gangway or the plank continues (the aft opening had a 5.5-stud hole
        # into 9-deep basin water, I2-03); port; the forecastle sides and its bow (open before: I2-08); quarterdeck.
        main, fc, qd = self.deck, self.b["decks"]["forecastle"]["y"], self.b["decks"]["quarterdeck"]["y"]
        self.assert_edge(16.2, -34.5, 16.2, 35.5, (1, 0), main, "starboard bulwark")
        self.assert_edge(-16.2, -34.5, -16.2, 35.5, (-1, 0), main, "port bulwark")
        self.assert_edge(-14.0, -54.4, 14.0, -54.4, (0, -1), fc, "forecastle bow")
        self.assert_edge(15.2, -54.0, 15.2, -36.0, (1, 0), fc, "forecastle starboard")
        self.assert_edge(-15.2, -54.0, -15.2, -36.0, (-1, 0), fc, "forecastle port")
        self.assert_edge(16.2, 37.0, 16.2, 57.0, (1, 0), qd, "quarterdeck starboard")
        self.assert_edge(-16.2, 37.0, -16.2, 57.0, (-1, 0), qd, "quarterdeck port")
        self.assert_edge(-15.5, 58.0, 15.5, 58.0, (0, 1), qd, "stern")

    def test_openings_no_wider_than_their_ramps(self):
        # Each starboard opening at deck height is exactly a gangway lane (or the plank): its width equals the ramp's.
        opens, cur = [], None
        for k in range(int(70.5 / 0.25) + 1):
            z = -34.75 + k * 0.25
            if self.edge_state(16.2, z, (1, 0), self.deck)[0] != "wall":
                cur = [z, z] if cur is None else [cur[0], z]
            elif cur is not None:
                opens.append(cur)
                cur = None
        spans = sorted([(lane["z"] - lane["w"] / 2, lane["z"] + lane["w"] / 2) for lane in self.lanes.values()]
                       + [(self.plank_z - self.plank_w / 2, self.plank_z + self.plank_w / 2)])
        self.assertEqual(len(opens), len(spans), opens)
        for (a, b), (sa, sb) in zip(opens, spans):
            self.assertGreaterEqual(a, sa - 0.3, (a, b, sa, sb))
            self.assertLessEqual(b, sb + 0.3, (a, b, sa, sb))
            self.assertGreaterEqual(b - a, sb - sa - 1.0, (a, b, sa, sb))  # and the whole lane is usable
        self.assertTrue(all(lane["w"] >= 15 for lane in self.lanes.values()))

    def test_fore_and_aft_landings_clear(self):
        # A car coming up either gangway has 10 studs of flat, clear deck straight ahead (the forecastle stair stood
        # 1.6 studs inboard of the fore opening: I2-03).
        for name, lane in self.lanes.items():
            for x in np.arange(lane["x0"] - 10.0, lane["x0"] - 0.4, 0.5):
                for dz in np.arange(-lane["w"] / 2 + 1.0, lane["w"] / 2 - 0.99, 0.5):
                    w = self.cove.ship(x, 0, lane["z"] + dz)
                    g, what = self.cove.ground(w[0], w[2])
                    self.assertAlmostEqual(g[0], self.deck, delta=0.3, msg=(name, x, dz, what[0]))
                    self.assertIsNone(self.cove.walls(w[0], w[2], g)[0], (name, x, dz))

    # ------------------------------------------------------------------------------------------- gangways
    def test_gangway_rails_collidable_with_skirts(self):
        # Collidable plank rails along both edges over the wall-ray band (I2-03: the rope rails were nc) and skirts
        # down into the sand, so nothing drives or falls under a ramp (I2-11: cars wedged under the low end).
        for name, lane in self.lanes.items():
            for x in np.arange(lane["x0"] + 1.0, lane["x1"] - 0.49, 1.0):
                top = self.ramp_top(lane, x)
                for side in (-1, 1):
                    edge = lane["z"] + side * (lane["w"] / 2 + 0.3)
                    w = self.cove.ship(x, 0, edge)
                    hit = self.cove.walls(w[0], w[2], top)[0]
                    self.assertTrue(hit and hit.startswith("GalleonGangway"), (name, x, side, hit))
                    sand = float(self.cove.terrain(w[0], w[2]))
                    skirt = self.cove.walls(w[0], w[2], sand, lift_lo=0.0, lift_hi=top - sand - 0.6)[0]
                    self.assertIsNotNone(skirt, (name, x, side, "gap under the rail"))
            # the lane itself is a ramp, as wide as its opening
            for x in np.arange(lane["x0"] + 0.5, lane["x1"] - 0.49, 2.0):
                for dz in np.arange(-lane["w"] / 2 + 0.3, lane["w"] / 2 - 0.29, 1.0):
                    w = self.cove.ship(x, 0, lane["z"] + dz)
                    g, what = self.cove.ground(w[0], w[2])
                    self.assertEqual(what[0], name, (x, dz))
                    self.assertAlmostEqual(g[0], self.ramp_top(lane, x), delta=0.25)

    def test_gangway_rail_flares_deflect(self):
        # Every collidable rail and flare of a gangway runs within asin(WALL_SHALLOW_DOT) of the lane axis: a car going
        # along the lane that meets one deflects along it instead of bumping (|dir.n| < WALL_SHALLOW_DOT), and both
        # ends of each rail carry a flare.
        max_deg = math.degrees(math.asin(self.car["WALL_SHALLOW_DOT"]))
        for key in ("GalleonGangwayFore", "GalleonGangwayAft"):
            flares = 0
            for spec in self.plan["prefabs"][key]["parts"]:
                extra = spec[12] if len(spec) > 12 and isinstance(spec[12], dict) else {}
                if extra.get("nc") or spec[5] < 2.0:  # decor, or the boards a car drives on (1.0 thick)
                    continue
                R = galleon_geom.yxz(*[math.radians(v) for v in spec[7:10]])
                along = R @ np.array([1.0, 0, 0])
                deg = math.degrees(math.atan2(abs(along[2]), abs(along[0])))
                self.assertLessEqual(deg, max_deg - 2.0, (key, spec[:10]))
                flares += deg > 5.0
            self.assertEqual(flares, 4, key)

    def test_gangway_data_matches_the_ramps(self):
        # WaterRules reads the gangways' top/foot (bots' ramp coordinates, the deck reach): they sit on the ramps.
        for name, lane in self.lanes.items():
            for x, y in ((lane["x0"] + 0.3, lane["y0"]), (lane["x1"] - 0.3, lane["y1"])):
                g, what = self.cove.ship_ground(x, lane["z"])
                self.assertEqual(what, name)
                self.assertAlmostEqual(g, y, delta=0.15)
            self.assertAlmostEqual(lane["y0"], self.deck, delta=0.01)

    def test_sand_under_the_lower_gangways(self):
        # The Plank Dune fills the lower half of each ramp's underside (I2-03 fix 5 / I2-11) and never pokes through
        # a ramp: terrain stays 0.5 under every ramp surface and comes within a car's height of its underside.
        for name, lane in self.lanes.items():
            mid = (lane["x0"] + lane["x1"]) / 2
            for x in np.arange(lane["x0"] + 0.5, lane["x1"], 1.0):
                for dz in np.arange(-lane["w"] / 2, lane["w"] / 2 + 0.01, 2.0):
                    w = self.cove.ship(x, 0, lane["z"] + dz)
                    sand, top = float(self.cove.terrain(w[0], w[2])), self.ramp_top(lane, x)
                    self.assertLessEqual(sand, top - 0.5, (name, x, dz))
                    if x >= mid:
                        self.assertLess((top - 1.0) - sand, 3.1, (name, x, dz, "a car fits under"))

    # -------------------------------------------------------------------------------------- walk the plank
    def fly(self, v: float, z: float, ang: float, lip_x: float, lip_y: float, dt: float = 1 / 240):
        """Ballistic arc off the lip (CarController airborne: GRAVITY, hull RIDE_HEIGHT over the surface) until the
        hull bottom meets the ground; returns the ship-frame landing x, the ground there and the worst clip."""
        g_ = self.car["GRAVITY"]
        ride = self.car["RIDE_HEIGHT"]
        vx, vy = v * math.cos(ang), v * math.sin(ang)
        x, y = lip_x, lip_y + ride
        while True:
            x += vx * dt
            vy = max(vy - g_ * dt, -self.car["MAX_FALL_SPEED"])
            y += vy * dt
            for lat in (-self.car["HALF_WIDTH"], 0.0, self.car["HALF_WIDTH"]):
                w = self.cove.ship(x, 0, z + lat)
                hit = self.cove.walls(w[0], w[2], y - ride, lift_lo=0.2, lift_hi=ride + 1.2)[0]
                self.assertIsNone(hit, (v, round(x, 1), lat, "the arc runs into a part"))
            w = self.cove.ship(x, 0, z)
            g, what = self.cove.ground(w[0], w[2], below=y)
            if vy < 0 and y - ride <= g[0] + 1e-6:
                return x, g[0], what[0]

    def plank_profile(self):
        """The kicker's surface along the plank centreline (ship frame) from the plan geometry: launch angle and lip."""
        xs = np.arange(4.5, 30.0, 0.25)
        tops = []
        for x in xs:
            w = self.cove.ship(x, 0, self.plank_z)
            g, what = self.cove.ground(w[0], w[2])
            if what[0] != "GalleonPlank":
                break
            tops.append((x, g[0]))
        self.assertGreater(len(tops), 40)
        (xa, ya), (xb, yb) = tops[len(tops) // 2], tops[-1]
        return math.atan2(yb - ya, xb - xa), xb, yb

    def test_walk_the_plank_lands_dry_at_any_speed(self):
        # Any car that leaves the plank, from a crawl to an item boost (ITEM_BOOST_MAX_SPEED), lands on ground that
        # stays dry at the last tide step: the bank against the hull, the Plank Dune or its spit to the beach crest.
        ang, lip_x, lip_y = self.plank_profile()
        self.assertTrue(math.radians(8) < ang < math.radians(16), math.degrees(ang))
        for v in list(range(8, 130, 8)) + [self.car["PAD_BOOST_SPEED"], self.car["ITEM_BOOST_MAX_SPEED"]]:
            self.assertLessEqual(v * math.sin(ang), self.car["MAX_RISE_SPEED"])  # inside the CarServer budget
            x, g, what = self.fly(v, self.plank_z, ang, lip_x, lip_y)
            self.assertEqual(what, "terrain", (v, x))
            self.assertTrue(self.dry(g - 1.0, self.top_level), (v, round(x, 1), round(g, 2)))

    def test_walk_the_plank_from_rest_lands_off_the_pads(self):
        # From rest on the deck (keyboard throttle 1 and the touch auto-gas), CarController's ground speed law up the
        # kicker, then the flight: the landing is on the dune, >= 20 studs from every pad (critic correction).
        ang, lip_x, lip_y = self.plank_profile()
        c = self.car
        for throttle in (1.0, c["AUTO_THROTTLE"]):
            x, v, dt = 1.5, 0.0, 1 / 240
            while x < lip_x:
                target = c["TOP_SPEED"] * throttle
                v = min(target, v + max(c["ACCEL_MIN"], (target - v) * c["ACCEL_RESPONSE"]) * dt)
                slope = ang if x >= 4.0 else 0.0
                v -= c["SLOPE_GRAVITY"] * math.sin(slope) * dt
                x += v * math.cos(slope) * dt
            self.assertGreater(v, 45.0, throttle)
            land_x, g, what = self.fly(v, self.plank_z, ang, lip_x, lip_y)
            p = self.cove.ship(land_x, 0, self.plank_z)
            self.assertTrue(self.dry(g - 1.0, self.top_level), (throttle, land_x, g))
            for i, pad in enumerate(self.pads):
                self.assertGreaterEqual(math.hypot(p[0] - pad[0], p[2] - pad[2]), 20.0, (throttle, i + 1))
            self.assertAlmostEqual(land_x, self.b["plank"]["landingShipX"]["keyboard" if throttle == 1 else "touch"],
                                   delta=1.5)

    # --------------------------------------------------------------------------------- never an island
    def test_every_dry_pad_reaches_a_tide_safe_pad_at_every_level(self):
        # The owner's loop (I2-01): from t=50 the decks and sandbars were an island, so every way back to the beach
        # drowned him. A 1-stud flood fill (climb <= drownDepth per stud, no wall, not drowned) from every pad that is
        # dry at a level must reach a pad that stays dry at the last step, at every level: the gangways land on the
        # Plank Dune, whose spit joins the beach crest.
        half = self.b["softBoundary"]["radius"] + self.b["softBoundary"]["softWidth"] + 5
        X, Z, G, W = self.cove.raster(half)
        x0, z0 = X[0, 0], Z[0, 0]

        def cell(p):
            return int(round(p[2] - z0)), int(round(p[0] - x0))

        safe = [i for i, g in enumerate(self.pad_ground) if self.dry(g, self.top_level)]
        self.assertIn(0, safe)
        self.assertEqual(len(safe), len(self.pads), "every pad is tide-safe (owner 2026-10-21)")
        for level in self.levels:
            ok = ~W & (level - G <= self.drown)
            for i, g in enumerate(self.pad_ground):
                if not self.dry(g, level):
                    continue
                reach = galleon_geom.flood(ok, G, [cell(self.pads[i])])
                self.assertTrue(reach[cell(self.pads[i])], (level, i + 1, "pad cell walled or drowned"))
                self.assertTrue(any(reach[cell(self.pads[j])] for j in safe if j != i),
                                (level, i + 1, "cut off from every tide-safe pad"))
                if self.on_deck(i):
                    # Reaching the Plank Dune pads beside the ship is not enough: the deck must reach the beach itself
                    # (the seat on the crest and the beach dune pad), or the dune and the decks are one bigger island.
                    for j in (0, 3):
                        self.assertTrue(reach[cell(self.pads[j])], (level, "deck cut off from beach pad", j + 1))

if __name__ == "__main__":
    unittest.main()
