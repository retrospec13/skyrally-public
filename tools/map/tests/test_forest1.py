#!/usr/bin/env python3
"""FOREST-1 (Windmill Countryside, plane) plan checks: adapt compile gates, gameplay anchors (checkpoints, rings,
pads, pods, alternate, L4 coins / hidden key / battle overlay / boss hazards), zone materials, terrain clearance,
world placement against the other maps, and author-script determinism.
Run: python3 -m unittest discover -s tools/map/tests -v"""
import contextlib
import glob
import io
import json
import math
import re
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

import fixtures  # noqa: F401  (puts tools/map and tools/course on sys.path)
import adapt

ROOT = fixtures.ROOT
PLAN = ROOT / "map" / "forest1" / "plan.json"
VARIANTS = ROOT / "assets" / "materials" / "forest_v1" / "variants.json"
TEXTURES = {"T7_MEADOW_SOFT", "T2_DIRT_PATH", "T3_MOSSY_STONE", "T4_FIELD_CROPS", "T5_COBBLE_ROAD", "T6_MILL_WOOD"}  # L61: T7 replaced T1
POD_TYPES = {"Red", "Blue", "Yellow", "Green", "Rainbow", "Speed"}


def dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def seg_point_dist(p, a, b):
    ab = [y - x for x, y in zip(a, b)]
    ap = [y - x for x, y in zip(a, p)]
    L2 = sum(v * v for v in ab) or 1e-9
    t = max(0.0, min(1.0, sum(u * v for u, v in zip(ab, ap)) / L2))
    return dist(p, [x + t * v for x, v in zip(a, ab)])


def part_obbs(plan, x, z, reach):
    """World OBBs (centre, rotation, half size) of the collidable parts of every instance whose pivot lies within
    reach of (x, z): the exact boxes builder_template builds (adapt.collidable_parts keeps only their AABBs)."""
    out = []
    for inst in plan["instances"]:
        p = inst["p"]
        if math.hypot(p[0] - x, p[2] - z) > reach:
            continue
        r_inst = adapt.instance_rotation(inst.get("r"))
        s = inst.get("s") or 1
        for part in plan["prefabs"][inst["pf"]]["parts"]:
            extra = part[12] if len(part) > 12 and isinstance(part[12], dict) else {}
            if extra.get("nc"):
                continue
            r_part = adapt.rot_yxz(*(v or 0 for v in part[7:10]))
            out.append((np.array(p, float) + r_inst @ (np.array(part[1:4], float) * s), r_inst @ r_part,
                        np.array(part[4:7], float) * s / 2))
    return out


def ground_grid(t, X, Z):
    """Vectorised Ground (bilinear, as builder_template `height(x, z)`)."""
    H = np.array(t["heights"], float).reshape(t["nz"], t["nx"])
    c = t["cell"]
    fx = (np.clip(X, t["x0"], t["x0"] + (t["nx"] - 1) * c) - t["x0"]) / c
    fz = (np.clip(Z, t["z0"], t["z0"] + (t["nz"] - 1) * c) - t["z0"]) / c
    ix = np.clip(fx.astype(int), 0, t["nx"] - 2)
    iz = np.clip(fz.astype(int), 0, t["nz"] - 2)
    tx, tz = fx - ix, fz - iz
    a, b, cc, d = H[iz, ix], H[iz, ix + 1], H[iz + 1, ix], H[iz + 1, ix + 1]
    u, v = a + (b - a) * tx, cc + (d - cc) * tx
    return u + (v - u) * tz


def erode(free, m):
    """Cells whose whole disc of radius m (cells) is free."""
    out = free.copy()
    k = int(math.ceil(m))
    ny, nx = free.shape
    for dy in range(-k, k + 1):
        for dx in range(-k, k + 1):
            if dx * dx + dy * dy > m * m:
                continue
            sh = np.zeros_like(free)
            sh[max(-dy, 0):ny + min(-dy, 0), max(-dx, 0):nx + min(-dx, 0)] = \
                free[max(dy, 0):ny + min(dy, 0), max(dx, 0):nx + min(dx, 0)]
            out &= sh
    return out


class Ground:
    """Bilinear ground height of the plan's grid, as builder_template `height(x, z)`."""

    def __init__(self, t):
        self.t = t
        self.H = t["heights"]

    def __call__(self, x, z):
        t = self.t
        nx, nz, c = t["nx"], t["nz"], t["cell"]
        fx = (min(max(x, t["x0"]), t["x0"] + (nx - 1) * c) - t["x0"]) / c
        fz = (min(max(z, t["z0"]), t["z0"] + (nz - 1) * c) - t["z0"]) / c
        ix, iz = max(min(int(fx), nx - 2), 0), max(min(int(fz), nz - 2), 0)
        tx, tz = fx - ix, fz - iz
        k = iz * nx + ix
        a, b, cc, d = self.H[k], self.H[k + 1], self.H[k + nx], self.H[k + nx + 1]
        u, v = a + (b - a) * tx, cc + (d - cc) * tx
        return u + (v - u) * tz


class Forest1(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = json.loads(PLAN.read_text())
        cls.sk = cls.plan["skyrally"]
        cls.gp = cls.sk["gameplay"]
        cls.res = adapt.check(cls.plan)
        cls.route = cls.res.route
        cls.L = cls.route.length if cls.route else 0.0
        cls.ground = Ground(cls.plan["terrain"])

    # ------------------------------------------------------------------------------------------- critic v28 wave 1
    def test_windmill_density_and_ridge_mills(self):
        """1.22: 13 farm mills (0.8-1.4x) in three clusters plus the hero mill; 1.11: windmills on the far backdrop ridge,
        each standing on a ridge part; every mill body 140+ horizontal studs from the route unless an old one."""
        plan = self.plan
        names = {i + 1: g for i, g in enumerate(plan["groups"])}
        mills = [(names[i["g"]], i) for i in plan["instances"] if i["pf"].startswith("Windmill") and "Sails" not in i["pf"]]
        farm = [i for n, i in mills if "/FarmMill_" in n]
        self.assertEqual(len(farm), 13)
        self.assertTrue(all(0.8 <= i["s"] <= 1.4 for i in farm))
        self.assertEqual(len([1 for n, _ in mills if "/HeroMill_" in n]), 1)
        ridge = [i for n, i in mills if "/RidgeMill_" in n]
        self.assertGreaterEqual(len(ridge), 6)
        wps = self.route.waypoints
        pts = np.array([w.pos for w in wps])
        res = adapt.check(plan)
        parts = [p for p in res.gates["backdrop"] if p["kind"] == "ring"]
        import backdrop as bd
        for i in ridge:
            near = min(bd.part_box(p).point_distance([i["p"][0], i["p"][1] + 20, i["p"][2]]) for p in parts)
            self.assertLess(near, 40.0, f"ridge mill at {i['p']} stands on no ridge part")
        for i in farm:
            self.assertGreaterEqual(float(np.min(np.hypot(pts[:, 0] - i["p"][0], pts[:, 2] - i["p"][2]))), 140.0)

    # ------------------------------------------------------------------------------------------- gates / identity
    def test_adapt_gates_pass(self):
        self.assertEqual([f"{e.code}: {e.msg}" for e in self.res.report.errors], [])
        self.assertLessEqual(abs(self.L - self.sk["route"]["targetLength"]), 1.0)
        self.assertAlmostEqual(self.sk["route"]["targetLength"], 5200, delta=100)
        self.assertGreaterEqual(self.res.gates["minRadius"], 85)
        self.assertEqual(self.sk["route"]["radiusExceptions"], [])
        self.assertEqual(self.res.gates["corridorPartIntrusions"], 0)
        self.assertGreater(self.res.gates["collidableParts"], 500)

    def test_identity_and_blocks(self):
        sk = self.sk
        self.assertEqual((sk["id"], sk["key"], sk["zone"], sk["vehicle"], sk["laps"], sk["lighting"]),
                         ("FOREST-1", "forest1", "FOREST", "plane", 3, "FOREST-1"))
        self.assertTrue(sk["route"]["closed"])
        self.assertEqual(sk["flight"], {"lineOffset": 14, "corridor": {"halfWidth": 34, "floor": 5, "ceiling": 44},
                                       "allowPockets": []})
        self.assertEqual(sk["deck"]["style"], "forest1_cobble")
        self.assertEqual(sk["deck"]["piersEvery"], 0)
        self.assertTrue((ROOT / sk["guide"]).is_file())
        self.assertNotIn("lighting", self.plan)
        for m in self.plan["markers"]:
            self.assertNotIn(m.get("kind"), ("Spawn", "Checkpoint"))

    # ------------------------------------------------------------------------------------------------- gameplay
    def test_checkpoints_every_350_to_450(self):
        st = self.gp["checkpoints"]["stations"]
        self.assertEqual(st[0], 0)
        self.assertEqual(st, sorted(st))
        gaps = [b - a for a, b in zip(st, st[1:])] + [self.L - st[-1]]
        for g in gaps:
            self.assertTrue(350 <= g <= 450, gaps)

    def test_rings_on_the_flight_line(self):
        rings = self.gp["rings"]
        self.assertTrue(6 <= len(rings) <= 10)
        line = self.sk["flight"]["lineOffset"]
        for r in rings:
            if r["name"] == "BoosterRing_SailGate":  # the one off-line ring: it hangs in a sail disc (test_sail_gate_*)
                cor = self.sk["flight"]["corridor"]
                self.assertTrue(abs(r["lateral"]) <= cor["halfWidth"] and cor["floor"] <= r["height"] <= cor["ceiling"], r)
            else:
                self.assertEqual(r["lateral"], 0, r["name"])
                self.assertEqual(r["height"], line, r["name"])
            self.assertTrue(0 <= r["station"] < self.L)
        self.assertEqual(len({r["name"] for r in rings}), len(rings))
        # the aerial chain: at least three rings above the valley floor by 60+ studs
        high = [r for r in rings if self.route.frame_at(r["station"]).pos[1] > 120]
        self.assertGreaterEqual(len(high), 3)

    # ------------------------------------------------------------------------------- sail-gap timing ring (launch upgrade)
    def _gate(self):
        """The gate ring, the gate mill's instances, and the ring centre in the sails' own frame (x, y, z)."""
        ring = next(r for r in self.gp["rings"] if r["name"] == "BoosterRing_SailGate")
        groups = self.plan["groups"]
        insts = [i for i in self.plan["instances"] if groups[i["g"] - 1] == "Windmills/GateMill"]
        sails = next(i for i in insts if i["pf"] == "WindmillSails")
        tower = next(i for i in insts if i["pf"] == "Windmill")
        centre = np.array(self.route.frame_at(ring["station"]).offset(ring["lateral"], ring["height"]), float)
        rot = adapt.instance_rotation(sails["r"])
        local = rot.T @ (centre - np.array(sails["p"], float)) / (sails.get("s") or 1)
        return ring, insts, sails, tower, centre, local

    def test_sail_gate_ring_hangs_in_the_sail_disc(self):
        ring, insts, sails, tower, _centre, local = self._gate()
        self.assertEqual(sorted(i["pf"] for i in insts), ["Windmill", "WindmillSails"])
        self.assertAlmostEqual(local[2], 0.0, delta=1.0)  # in the sail plane (the ring's axis is the route tangent)
        r = float(np.hypot(local[0], local[1]))
        self.assertTrue(30.0 <= r <= 40.0, r)  # inside the lattice, ring opening (10) clear of the 44-stud arm tips
        ang = math.degrees(math.atan2(local[1], local[0])) % 360.0
        self.assertAlmostEqual(ang, ring["sailGate"]["ringDeg"], delta=0.5)
        # the sail disc is square to the flight direction: ring axis (route tangent) is the sails' local Z
        rot = adapt.instance_rotation(sails["r"])
        tan = np.array(self.route.frame_at(ring["station"]).tangent, float)
        self.assertGreater(abs(float((rot @ np.array([0, 0, 1.0])) @ tan)), 0.99)
        self.assertEqual(tower["r"], sails["r"])
        self.assertEqual(tower["s"], sails["s"])

    def test_sail_gate_geometry_matches_the_rules(self):
        """src/shared/SailGateRules.luau constants against the sails prefab and the ring: the lit window never leaves a
        lattice edge across the ring opening."""
        src = (ROOT / "src" / "shared" / "SailGateRules.luau").read_text()
        const = {k: float(v) for k, v in re.findall(r"SailGateRules\.([A-Z_]+_DEG) = (-?[0-9.]+)", src)}
        ring, _insts, sails, _tower, _centre, local = self._gate()
        r = float(np.hypot(local[0], local[1])) / 1.0
        # lattice: arm k at 45 + 90k, filling 0..~9.8 studs of offset on its counter-clockwise side
        arm_parts = [p for p in self.plan["prefabs"]["WindmillSails"]["parts"] if p[0] == "B" and abs(p[3] - 0.0) < 1.0]
        self.assertTrue(arm_parts)
        span = math.degrees(math.atan2(9.4 + 0.55, r))
        self.assertGreaterEqual(const["ARM_SPAN_DEG"], span - 0.5)
        half = math.degrees(math.atan2(10.0, r))  # ring opening radius 10 (kit/Gameplay RING_OPENING_DIAMETER = 20)
        self.assertGreaterEqual(const["RING_HALF_DEG"], half - 0.5)
        self.assertEqual(const["ARM_OFFSET_DEG"], 45.0)
        self.assertGreaterEqual(const["LIT_FROM_DEG"], const["ARM_SPAN_DEG"] + const["RING_HALF_DEG"])
        self.assertLessEqual(const["LIT_TO_DEG"], 90.0 - const["RING_HALF_DEG"])
        # the in-game sails are the v3 mesh (ArtSwapRules windmill_sails), blades centred on the stock
        self.assertLessEqual(const["LIT_TO_DEG"], 90.0 - const["MESH_ARM_HALF_DEG"] - const["RING_HALF_DEG"])
        self.assertGreaterEqual(const["LIT_FROM_DEG"], const["MESH_ARM_HALF_DEG"] + const["RING_HALF_DEG"])
        # prefab: the arm stocks sit at 45 + 90k, as the rules assume
        stocks = sorted(round(p[9]) % 360 for p in self.plan["prefabs"]["WindmillSails"]["parts"]
                        if len(p) > 12 and p[4] == 44)
        self.assertEqual(stocks, [45, 135, 225, 315])
        sg = ring["sailGate"]
        mill_attr = next(a for a in self.sk["modelAttributes"] if a["path"] == "Windmills/GateMill/WindmillSails")["attrs"]
        self.assertEqual(mill_attr["SpinRPM"], sg["rpm"])
        self.assertIs(mill_attr["SailClock"], True)
        self.assertEqual(mill_attr["SailPhase"], sg["phaseDeg"])
        self.assertEqual(sg["mill"], "Windmills/GateMill")

    def _sail_clear_window(self, pts2d, radius):
        """Range of ring angles (degrees counter-clockwise of an arm's rest stock at 45) at which the ring opening (radius
        10 at `radius` from the hub) holds none of the sail points; 0.1-degree steps."""
        clear = []
        for i in range(900):
            rel = i / 10.0
            ok = True
            for k in range(4):
                a = math.radians(45 + 90 * k + rel)
                c = np.array([radius * math.cos(a), radius * math.sin(a)])
                if bool((np.hypot(pts2d[:, 0] - c[0], pts2d[:, 1] - c[1]) < 10.0).any()):
                    ok = False
                    break
            if ok:
                clear.append(rel)
        return min(clear), max(clear)

    def test_sail_gate_lit_window_is_clear_of_the_real_sails(self):
        """Measured, not assumed: the lit window lies inside the angles where no sail geometry crosses the ring opening, for
        the block prefab (ArtSwapOff) and, when trimesh is installed, the v3 sails mesh ArtSwap shows in game."""
        src = (ROOT / "src" / "shared" / "SailGateRules.luau").read_text()
        const = {k: float(v) for k, v in re.findall(r"SailGateRules\.([A-Z_]+_DEG) = (-?[0-9.]+)", src)}
        _ring, _insts, _sails, _tower, _centre, local = self._gate()
        radius = float(np.hypot(local[0], local[1]))
        rng = np.random.default_rng(7)
        pts = []
        for p in self.plan["prefabs"]["WindmillSails"]["parts"]:
            x, y, sx, sy, rz = p[1], p[2], p[4], p[5], math.radians(p[9])
            u = rng.uniform(-0.5, 0.5, (3000, 2)) * np.array([sx, sy])
            pts.append(np.c_[x + u[:, 0] * math.cos(rz) - u[:, 1] * math.sin(rz), y + u[:, 0] * math.sin(rz) + u[:, 1] * math.cos(rz)])
        lo, hi = self._sail_clear_window(np.vstack(pts), radius)
        self.assertLessEqual(lo, const["LIT_FROM_DEG"], (lo, hi))
        self.assertGreaterEqual(hi, const["LIT_TO_DEG"], (lo, hi))
        try:
            import trimesh
        except ImportError:
            self.skipTest("trimesh not installed: the mesh half is checked where it is")
        mesh = trimesh.load(ROOT / "assets" / "models" / "props_v3" / "windmill_sails" / "windmill_sails.glb").to_geometry()
        sample, _ = trimesh.sample.sample_surface(mesh, 120000, seed=7)
        lo, hi = self._sail_clear_window(sample[:, :2] * np.array([-1.0, 1.0]), radius)  # pre-turned 180 about Y
        self.assertLessEqual(lo, const["LIT_FROM_DEG"], (lo, hi))
        self.assertGreaterEqual(hi, const["LIT_TO_DEG"], (lo, hi))

    def test_sail_gate_sails_cannot_hit_planes_and_tower_clears_the_ring(self):
        ring, insts, sails, _tower, centre, _local = self._gate()
        for part in self.plan["prefabs"]["WindmillSails"]["parts"]:
            self.assertTrue(len(part) > 12 and part[12].get("nc"), part)  # every sail part is no-collide
        # no collidable part of the gate mill lies on the ring's fly-through line or inside the ring opening
        tan = np.array(self.route.frame_at(ring["station"]).tangent, float)
        up = np.array(self.route.frame_at(ring["station"]).up, float)
        right = np.cross(tan, up)
        right /= np.linalg.norm(right)
        pts = []
        for along in np.arange(-90.0, 90.0 + 1e-6, 2.0):
            pts.append(centre + tan * along)
            for k in range(12):  # the ring opening plus 6 studs of wing room round the centre line
                a = 2 * math.pi * k / 12
                pts.append(centre + tan * along + (right * math.cos(a) + up * math.sin(a)) * 14.0)
        for inst in insts:
            for c, rot, half in part_obbs({"instances": [inst], "prefabs": self.plan["prefabs"]}, inst["p"][0], inst["p"][2], 5):
                for p in pts:
                    d = np.abs(rot.T @ (p - c)) - half
                    self.assertFalse(bool(np.all(d < 0)), (inst["pf"], p))
        # the tower stands on the ground (plinth sunk a few studs at most) and outside the flight corridor (the compile gate
        # already checks the corridor; this pins the margin to the corridor half width)
        tw = np.array(_tower["p"], float)
        base_gap = float(self.ground(tw[0], tw[2])) - tw[1]
        self.assertTrue(-4.0 <= base_gap <= 10.0, base_gap)
        _st, lat, _h = self._project(tw)
        self.assertGreater(abs(lat), self.sk["flight"]["corridor"]["halfWidth"] + 14)

    def _project(self, p):
        best = None
        for s in np.arange(0.0, self.L, 4.0):
            q = np.array(self.route.frame_at(float(s)).pos, float)
            d = float(np.hypot(*(q - p)[[0, 2]]))
            if best is None or d < best[0]:
                best = (d, float(s))
        f = self.route.frame_at(best[1])
        rel = p - np.array(f.pos, float)
        return best[1], float(rel @ np.array(f.right, float)), float(rel @ np.array(f.up, float))

    def test_sail_gate_leaves_other_features_alone(self):
        ring, _insts, _s, tower, _c, _l = self._gate()
        # additive: the key (windmill base), the hoard yard and the Alt1 line are untouched and clear of the new mill
        key = self.gp["key"]["pos"]
        b = self.gp["modes"]["battle"]
        tw = tower["p"]
        self.assertGreater(math.hypot(tw[0] - key[0], tw[2] - key[2]), 600)
        self.assertGreater(math.hypot(tw[0] - b["center"][0], tw[2] - b["center"][2]), b["boundary"]["radius"] + 100)
        alt = self.gp["alternates"][0]
        self.assertLess(ring["station"], alt["joinStation"])
        self.assertGreater(ring["station"], 4035 + 100)  # after GroundBoost_RiverMeadow
        for other in self.gp["rings"]:
            if other is not ring:
                self.assertGreater(abs(other["station"] - ring["station"]), 400, other["name"])
        # the ring is the only gated ring; TrackData carries the config for it alone
        self.assertEqual([r["name"] for r in self.gp["rings"] if "sailGate" in r], ["BoosterRing_SailGate"])
        td = (ROOT / "build" / "forest1" / "TrackData.luau").read_text()
        self.assertEqual(td.count("sailGate = {"), 1)
        for key_ in ("dino4", "snow1", "island2", "hub0", "space4"):
            self.assertNotIn("sailGate", (ROOT / "build" / key_ / "TrackData.luau").read_text(), key_)

    def test_pads_and_pods(self):
        self.assertTrue(2 <= len(self.gp["pads"]) <= 4)
        gaps = self.sk["deck"]["gaps"]
        for p in self.gp["pads"]:  # pads lie on the road deck, never over the deck gap
            self.assertFalse(any(g["from"] <= p["station"] <= g["to"] for g in gaps), p["name"])
        pods = self.gp["pods"]
        self.assertEqual(len([p for p in pods if p["type"] != "Speed"]), 35)  # cubes v3: 7 two-deep clusters of 2 + 3
        self.assertEqual({p["type"] for p in pods}, POD_TYPES)
        for p in pods:
            self.assertTrue(abs(p["lateral"]) <= 14, p["name"])  # a cluster's back rank spans -10/0/+10
            self.assertTrue(0 <= p["station"] < self.L)

    def test_start_and_finish(self):
        self.assertEqual(self.gp["finish"]["station"], 0)
        sg = self.gp["startGrid"]
        self.assertLess(adapt.grid_slot(sg, adapt.GRID_SLOTS)[0], self.gp["checkpoints"]["stations"][1])

    def test_alternate_generated_from_route_frames(self):
        alts = self.gp["alternates"]
        self.assertTrue(0 <= len(alts) <= 2)
        wps = [w.pos for w in self.route.waypoints]
        for alt in alts:
            self.assertLess(alt["joinStation"], alt["rejoinStation"])
            self.assertEqual(alt["style"], "ledge")  # floor slab only: no alternate wall can stand in the corridor
            # both ends lie on the race line
            self.assertLess(dist(alt["points"][0], self.route.frame_at(alt["joinStation"]).pos), 1.0)
            self.assertLess(dist(alt["points"][-1], self.route.frame_at(alt["rejoinStation"]).pos), 1.0)
            far = 0.0
            for q in alt["points"]:
                k = min(range(len(wps)), key=lambda i: (wps[i][0] - q[0]) ** 2 + (wps[i][2] - q[2]) ** 2)
                d = math.hypot(wps[k][0] - q[0], wps[k][2] - q[2])
                far = max(far, d)
                if d < 34 + 13:  # where the ledge (half width 13) is under the main corridor it stays below its floor
                    self.assertLess(q[1] + 2.0, wps[k][1] + self.sk["flight"]["corridor"]["floor"], q)
            self.assertTrue(90 < far < 160, far)  # a real alternate line, inside the bend

    def test_coins(self):
        coins = self.gp["coins"]
        self.assertEqual(len(coins), 8)
        self.assertEqual(sorted(c["id"] for c in coins), list(range(1, 9)))
        for c in coins:
            self.assertTrue(0 <= c["station"] < self.L)
            want = self.route.frame_at(c["station"]).offset(c["lateral"], c["height"])
            self.assertLess(dist(want, c["pos"]), 0.5, c)  # pos is exactly the frame offset the adapter would compute
        on_alt = [c for c in coins if c.get("alternate")]
        self.assertGreaterEqual(len(on_alt), 1)
        alts = {a["id"]: a for a in self.gp["alternates"]}
        line = self.sk["flight"]["lineOffset"]
        for c in on_alt:
            pts = [[p[0], p[1] + line, p[2]] for p in alts[c["alternate"]]["points"]]
            self.assertLess(min(seg_point_dist(c["pos"], a, b) for a, b in zip(pts, pts[1:])), 3.0)

    def test_hidden_key_in_the_windmill_base(self):
        key = self.gp["key"]
        self.assertTrue(0 <= key["station"] < self.L)
        self.assertGreaterEqual(abs(key["lateral"]), 50)  # off the racing line, outside the corridor
        want = self.route.frame_at(key["station"]).offset(key["lateral"], key["height"])
        self.assertLess(dist(want, key["pos"]), 0.5)
        st = self.sk["provenance"]["stations"]
        self.assertTrue(st["tunnelMouth"] < key["station"] < st["tunnelExit"])  # reached through the tunnel mouth
        cyl = [o for o in self.sk["shells"]["ops"] if o["op"] == "FillCylinder" and o["mat"] == "Air"]
        self.assertEqual(len(cyl), 1)
        c = cyl[0]
        self.assertLess(math.hypot(key["pos"][0] - c["cf"][0], key["pos"][2] - c["cf"][2]), c["r"] - 5)
        self.assertTrue(c["cf"][1] - c["h"] / 2 < key["pos"][1] < c["cf"][1] + c["h"] / 2)
        self.assertGreater(self.ground(key["pos"][0], key["pos"][2]) - key["pos"][1], 40)  # inside the hill
        # the TunnelMill and its cellar prefab stand over / around the key
        mills = [i for i in self.plan["instances"] if i["pf"] == "MillCellar"]
        self.assertEqual(len(mills), 1)
        self.assertLess(math.hypot(mills[0]["p"][0] - key["pos"][0], mills[0]["p"][2] - key["pos"][2]), 2)

    def test_battle_overlay_hoard(self):
        b = self.gp["modes"]["battle"]
        self.assertEqual(b["kind"], "hoard")
        self.assertEqual(b["mode"], "FOREST-BATTLE")
        self.assertEqual(len(b["center"]), 3)
        self.assertEqual(len(b["spawns"]), 4)
        self.assertEqual(len(b["homeRings"]), 4)
        self.assertGreaterEqual(len(b["pickupAnchors"]), 8)
        cx, cz = b["center"][0], b["center"][2]
        for p in b["spawns"] + [h["pos"] for h in b["homeRings"]] + b["pickupAnchors"]:
            self.assertEqual(len(p), 3)
            self.assertLessEqual(math.hypot(p[0] - cx, p[2] - cz), b["radius"])
            self.assertGreater(p[1], self.ground(p[0], p[2]))  # above the ground
        mills = {i["p"][0]: i for i in self.plan["instances"] if i["pf"] == "Windmill"}
        for h in b["homeRings"]:  # each home ring stands at one of the field windmills (F1: 46 in front, 55 aside)
            self.assertTrue(any(math.hypot(h["pos"][0] - m["p"][0], h["pos"][2] - m["p"][2]) < 80 for m in mills.values()))

    def test_battle_anchors_clear_of_collision(self):
        """Spawns sit in open air, and each home ring's fly-through (+-60 along its axis) is clear of every collidable
        part and of the ground, so a plane passing through it never flies into its windmill."""
        b = self.gp["modes"]["battle"]
        centres, halves, _ = adapt.collidable_parts(self.plan)
        mills = [i["p"] for i in self.plan["instances"] if i["pf"] == "Windmill"]
        for s in b["spawns"]:
            gap = (abs(centres - s) - halves).max(axis=1)  # > 0: outside that part's AABB on some axis
            self.assertGreater(gap.min(), 8.0, s)
            self.assertGreater(min(math.hypot(s[0] - m[0], s[2] - m[2]) for m in mills), 40, s)
            self.assertGreater(s[1] - self.ground(s[0], s[2]), 15, s)
        for h in b["homeRings"]:
            yaw = math.radians(h["yaw"])
            look = [-math.sin(yaw), 0.0, -math.cos(yaw)]
            a = [p - 60 * l for p, l in zip(h["pos"], look)]
            z = [p + 60 * l for p, l in zip(h["pos"], look)]
            box = adapt.segment_box(a, z, h["radius"], -h["radius"], h["radius"])
            self.assertFalse(adapt.aabbs_hit_obb(centres, halves, *box).any(), h["name"])
            for k in range(-60, 61, 6):
                q = [p + k * l for p, l in zip(h["pos"], look)]
                self.assertLess(self.ground(q[0], q[2]), h["pos"][1] - h["radius"], (h["name"], k))

    def test_boss_hazards(self):
        self.assertNotIn("boss", self.gp["modes"])  # gameplay.boss, as every other launch plan
        boss = self.gp["boss"]
        self.assertEqual(boss["hazard"], "suspended fireballs")
        self.assertGreaterEqual(len(boss["anchors"]), 4)
        for s in boss["anchors"]:
            self.assertTrue(0 <= s < self.L)

    # ------------------------------------------------------------------------------------------- art / terrain
    def test_windmill_sails_are_separate_and_animatable(self):
        groups = self.plan["groups"]
        by_group = {}
        for inst in self.plan["instances"]:
            by_group.setdefault(groups[inst["g"] - 1], []).append(inst["pf"])
        mills = [g for g in groups if g.startswith("Windmills/")]
        self.assertGreaterEqual(len(mills), 12)
        attrs = {a["path"] for a in self.sk["modelAttributes"]}
        for g in mills:
            self.assertEqual(sorted(pf.split("#")[0] for pf in by_group[g]), ["Windmill", "WindmillSails"], g)
            self.assertIn(f"{g}/WindmillSails", attrs)
        for part in self.plan["prefabs"]["WindmillSails"]["parts"]:
            self.assertTrue(len(part) > 12 and part[12].get("nc"), part)  # sails never collide (they spin)

    def test_terrain_grid(self):
        t = self.plan["terrain"]
        n = t["nx"] * t["nz"]
        self.assertEqual(len(t["heights"]), n)
        self.assertEqual(len(t["materials"]), n)
        self.assertEqual(t["cell"], 8)
        self.assertTrue(all(1 <= m <= len(t["palette"]) for m in t["materials"]))
        self.assertGreater(min(t["heights"]), t["floor"])
        self.assertLessEqual(max(t["heights"]), t["top"])
        self.assertIn("rock", {p["key"] for p in t["palette"]})
        # the plane line stays far above FlightController's y <= 16 crash floor
        self.assertGreater(min(w.pos[1] for w in self.route.waypoints) + self.sk["flight"]["lineOffset"], 60)

    def test_no_terrain_in_the_flight_corridor(self):
        """Outside the tunnel (whose tube is carved by shells) the grid stays under the corridor floor, so the runtime
        corridor carve never cuts a box notch into a hill."""
        st = self.sk["provenance"]["stations"]
        floor = self.sk["flight"]["corridor"]["floor"]
        s = 0.0
        while s < self.L:
            if not (st["tunnelMouth"] - 30 <= s <= st["tunnelExit"] + 30):
                f = self.route.frame_at(s)
                for lat in (-34, -17, 0, 17, 34):
                    p = f.offset(lat, 0)
                    self.assertLessEqual(self.ground(p[0], p[2]), f.pos[1] + floor, (s, lat))
            s += 15.0

    def test_tunnel_tube_and_alt1_are_covered(self):
        st = self.sk["provenance"]["stations"]
        tube = next(o for o in self.sk["shells"]["ops"] if o["op"] == "CarveRouteTube")
        top = tube["lift"] + tube["radiusMax"]
        s = st["tunnelMouth"] + 14
        while s < st["tunnelExit"] - 14:
            f = self.route.frame_at(s)
            self.assertGreater(self.ground(f.pos[0], f.pos[2]) - (f.pos[1] + top), 8, s)
            s += 10
        # Alt1's Terrain tube (FillBall chain) runs under Granary Hill where the line is well off the race line
        balls = [o for o in self.sk["shells"]["ops"] if o["op"] == "FillBall" and o["r"] == 28 and o["mat"] == "Air"]
        self.assertGreater(len(balls), 8)
        covered = [self.ground(o["center"][0], o["center"][2]) - (o["center"][1] + o["r"]) for o in balls]
        self.assertGreaterEqual(sum(c > 0 for c in covered), 8, covered)
        # the adapter's ledge carve box (+-20, +4..+40 above the line) lies inside each ball
        for o in balls:
            self.assertGreaterEqual(o["r"], math.hypot(20, 40 - 22) + 0.5)

    def test_materials_and_variants(self):
        variants = json.loads(VARIANTS.read_text())
        for name, v in variants.items():
            self.assertTrue(name.startswith("SR_FOREST_"), name)
            self.assertIn(v["tex"], TEXTURES)
            self.assertIn(v["base"], adapt.MATERIALS)
            self.assertGreater(v["studsPerTile"], 0)
        self.assertEqual({v["tex"] for v in variants.values()}, TEXTURES)  # every zone texture is used
        m = self.sk["materials"]
        self.assertEqual(m["terrainColor"], "#ffffff")
        for base, var in m["terrainOverrides"].items():
            self.assertEqual(variants[var]["base"], base)
        palette = {p["material"] for p in self.plan["terrain"]["palette"]}
        self.assertEqual(palette, set(m["terrainOverrides"]))  # every terrain material has its painted variant
        for r in m["partRules"]:
            self.assertIn(r["variant"], variants)
            self.assertEqual(variants[r["variant"]]["base"], r.get("setMaterial", r.get("material")))

    def test_world_placement_clear_of_other_maps(self):
        def box(p):
            t, sk = p["terrain"], p["skyrally"]
            if "heights" in t:
                c = t.get("cell", 4)
                return (t["x0"], t["x0"] + (t["nx"] - 1) * c, t["z0"], t["z0"] + (t["nz"] - 1) * c)
            ns = [n["pos"] for n in sk["route"]["nodes"]]
            m = 600  # shells-only maps (DINO-4 FillRouteBounds margin 280 plus the flex reach)
            return (min(n[0] for n in ns) - m, max(n[0] for n in ns) + m, min(n[2] for n in ns) - m, max(n[2] for n in ns) + m)

        mine = box(self.plan)
        for path in sorted(glob.glob(str(ROOT / "map" / "*" / "plan.json"))):
            if Path(path) == PLAN:
                continue
            try:
                other = json.loads(Path(path).read_text())
                b = box(other)
            except (OSError, ValueError, KeyError):
                continue  # another lane's plan mid-write; its own test covers it
            overlap = not (b[1] < mine[0] or b[0] > mine[1] or b[3] < mine[2] or b[2] > mine[3])
            self.assertFalse(overlap, f"{path} footprint {b} overlaps FOREST-1 {mine}")

    def test_wave1b_ridge_mills_stay_drawn_and_cobble_is_grey_brown(self):
        """Wave 1b C9/C10/C11 (critic v29): every crest mill and its sails carry DressGround "part" (client DressingLod
        hid them as floating props past the Level01 radius); the cobble tints are grey-brown, not warm cream (the
        neutral T5 ColorMap takes its hue from the part colour); the off-spline beacon guide rings are gone."""
        attrs = {a["path"]: a["attrs"] for a in self.sk["modelAttributes"]}
        ridge = sorted({g.split("/")[1] for g in self.plan["groups"] if g.startswith("Windmills/RidgeMill_")})
        self.assertGreaterEqual(len(ridge), 6)
        for nm in ridge:
            self.assertEqual(attrs[f"Windmills/{nm}/Windmill"]["DressGround"], "part", nm)
            self.assertEqual(attrs[f"Windmills/{nm}/WindmillSails"]["DressGround"], "part", nm)
        style = (ROOT / "src" / "server" / "kit" / "styles" / "forest1.luau").read_text()
        for key in ("paverWarmA", "paverWarmB", "paverWarmC"):
            r, g, b = (int(v) for v in re.search(key + r" = Color3\.fromRGB\((\d+), (\d+), (\d+)\)", style).groups())
            self.assertTrue(r < 200 and r - b < 50 and r >= g >= b, (key, r, g, b))
        gameplay = (ROOT / "src" / "server" / "kit" / "Gameplay.luau").read_text()
        self.assertIn("local BEACON_GUIDES: { { z: number, r: number } } = {}", gameplay)

    def test_lighting_style_and_sky_files(self):
        light = (ROOT / "src" / "shared" / "lighting" / "forest1.luau").read_text()
        self.assertIn('["FOREST-1"]', light)
        self.assertNotIn("require(", light)  # LightingProfiles requires this module: no cycle
        style = (ROOT / "src" / "server" / "kit" / "styles" / "forest1.luau").read_text()
        self.assertIn("forest1_cobble", style)
        self.assertNotIn("require(", style)
        from PIL import Image
        for face in ("up", "side", "down"):
            with Image.open(ROOT / "assets" / "sky" / "forest1" / f"{face}.png") as im:
                self.assertEqual(im.size, (512, 512))

    # ------------------------------------------------------------------------- traps_forest1 F1 / F2 / F5 fixes
    def test_home_rings_face_the_way_home_and_run_out_clear(self):
        """F1: the natural line home runs from the field (the arena centre) out to your ring. Each ring's axis is that
        radial line, so you meet the disc square, and flying on through it (no input) runs past the windmill to the
        arena boundary clear of every collidable part and of the ground: no 'banked, then exploded on my own mill'."""
        b = self.gp["modes"]["battle"]
        c = b["center"]
        bound = b["boundary"]["radius"]
        centres, halves, _ = adapt.collidable_parts(self.plan)
        mills = [i["p"] for i in self.plan["instances"] if i["pf"] == "Windmill"]
        for h in b["homeRings"]:
            p = h["pos"]
            yaw = math.radians(h["yaw"])
            look = [-math.sin(yaw), 0.0, -math.cos(yaw)]
            out = [p[0] - c[0], 0.0, p[2] - c[2]]
            r_ring = math.hypot(out[0], out[2])
            cos = (look[0] * out[0] + look[2] * out[2]) / r_ring
            self.assertGreater(abs(cos), math.cos(math.radians(3)), (h["name"], "axis not radial"))
            sgn = 1.0 if cos > 0 else -1.0
            look = [sgn * v for v in look]  # outward along the axis
            a = [p[i] - 60 * look[i] for i in range(3)]  # the last 60 of the approach from the field
            z = [p[i] + (bound - r_ring) * look[i] for i in range(3)]  # straight on to the arena boundary
            box = adapt.segment_box(a, z, h["radius"], -h["radius"], h["radius"])
            self.assertFalse(adapt.aabbs_hit_obb(centres, halves, *box).any(), h["name"])
            for k in range(-60, int(bound - r_ring) + 1, 6):
                q = [p[i] + k * look[i] for i in range(3)]
                self.assertLess(self.ground(q[0], q[2]), p[1] - h["radius"], (h["name"], k))
            # the straight run-out passes every windmill (tower 16, sail disc 42) by more than 45
            for m in mills:
                self.assertGreater(seg_point_dist([m[0], 0, m[2]], [a[0], 0, a[2]], [z[0], 0, z[2]]), 45, (h["name"], m))
        # each spawn pad sits on its ring's axis, toward the field (seat i flies through ring i)
        for sp, h in zip(b["spawns"], b["homeRings"]):
            d = math.hypot(sp[0] - h["pos"][0], sp[2] - h["pos"][2])
            self.assertTrue(30 <= d <= 50, (h["name"], d))
            self.assertLess(math.hypot(sp[0] - c[0], sp[2] - c[2]), math.hypot(h["pos"][0] - c[0], h["pos"][2] - c[2]))

    def gallery_raster(self, res=1.0):
        """Free space at flight-line height around the key gallery: the tunnel tube, the gallery balls, the cellar
        cylinder and open air above the ground, minus every collidable part (exact OBBs). Returns the raster."""
        kg = self.sk["provenance"]["keyGallery"]
        ops = self.sk["shells"]["ops"]
        tube = next(o for o in ops if o["op"] == "CarveRouteTube")
        balls = [o for o in ops if o["op"] == "FillBall" and o["mat"] == "Air" and o["r"] == kg["radius"]]
        cyl = next(o for o in ops if o["op"] == "FillCylinder" and o["mat"] == "Air")
        line = self.sk["flight"]["lineOffset"]
        sts = np.arange(kg["from"] - 120, kg["to"] + 120, 3.0)
        fr = [self.route.frame_at(float(v)) for v in sts]
        P = np.array([f.pos for f in fr])
        Rt = np.array([f.right for f in fr])
        xs = [q[0] for q in P] + [o["center"][0] for o in balls]
        zs = [q[2] for q in P] + [o["center"][2] for o in balls]
        x0, z0 = min(xs) - 60, min(zs) - 60
        X, Z = np.meshgrid(np.arange(x0, max(xs) + 60, res), np.arange(z0, max(zs) + 60, res))
        idx = np.zeros(X.shape, int)
        for r in range(0, X.shape[0], 64):  # nearest route sample, a band of rows at a time
            d2 = (X[r:r + 64, :, None] - P[:, 0]) ** 2 + (Z[r:r + 64, :, None] - P[:, 2]) ** 2
            idx[r:r + 64] = np.argmin(d2, axis=2)
        st = sts[idx]
        Y = P[idx, 1] + line
        lat = (X - P[idx, 0]) * Rt[idx, 0] + (Z - P[idx, 2]) * Rt[idx, 2]
        free = ((lat ** 2 + (line - tube["lift"]) ** 2 < tube["radiusMin"] ** 2)
                & (st >= tube["fromStation"]) & (st <= tube["toStation"]))
        for o in balls:
            q = o["center"]
            free |= (X - q[0]) ** 2 + (Z - q[2]) ** 2 + (Y - q[1]) ** 2 < o["r"] ** 2
        q = cyl["cf"]
        free |= ((X - q[0]) ** 2 + (Z - q[2]) ** 2 < cyl["r"] ** 2) & (np.abs(Y - q[1]) < cyl["h"] / 2)
        free |= ground_grid(self.plan["terrain"], X, Z) < Y - 2  # open air outside the hill
        mx, mz = float(np.mean(xs)), float(np.mean(zs))
        for c, R, h in part_obbs(self.plan, mx, mz, 400):
            loc = np.stack([X - c[0], Y - c[1], Z - c[2]], -1) @ R
            free &= ~np.all(np.abs(loc) < h, axis=-1)
        return {"free": free, "x0": x0, "z0": z0, "res": res, "st": st, "lat": lat}

    def fly_gallery(self, rr, start_st, speed, yaw_rate, margin, dt=0.05):
        """Breadth-first search over yaw-rate inputs (full, half, none, both ways) at constant speed: from the race
        line at start_st, through the key's pickup sphere (12, tighter than KeyPickup.RADIUS_PLANE 16), and back onto
        the race line past the gallery's rejoin (within 20 of the line, heading within 25 deg of it). The plane is a
        point that must stay `margin` inside free space, plus FlightController's 4.5-stud look-ahead ray."""
        kg = self.sk["provenance"]["keyGallery"]
        key = self.gp["key"]["pos"]
        ok = erode(rr["free"], margin / rr["res"])
        raw = rr["free"]

        def cell(x, z):
            i, j = int(round((z - rr["z0"]) / rr["res"])), int(round((x - rr["x0"]) / rr["res"]))
            return (i, j) if 0 <= i < ok.shape[0] and 0 <= j < ok.shape[1] else None

        f = self.route.frame_at(start_st)
        frontier = [(f.pos[0], f.pos[2], math.atan2(f.tangent[0], -f.tangent[2]), False)]
        seen, rates = set(), [math.radians(yaw_rate) * k for k in (-1, -0.5, 0, 0.5, 1)]
        steps = int((kg["to"] + 10 - start_st) * 1.5 / (speed * dt))
        for _ in range(steps):
            nxt = []
            for x, z, hd, got in frontier:
                for w in rates:
                    h2 = hd + w * dt
                    sx, sz = math.sin(h2), -math.cos(h2)
                    x2, z2 = x + sx * speed * dt, z + sz * speed * dt
                    c1, cm, ca = cell(x2, z2), cell((x + x2) / 2, (z + z2) / 2), cell(x2 + 4.5 * sx, z2 + 4.5 * sz)
                    if not (c1 and cm and ca and ok[c1] and ok[cm] and raw[ca]):
                        continue
                    g2 = got or math.hypot(x2 - key[0], z2 - key[2]) <= 12
                    if g2 and rr["st"][c1] >= kg["to"] + 10 and abs(rr["lat"][c1]) < 20:
                        t = self.route.frame_at(float(rr["st"][c1])).tangent
                        if abs((h2 - math.atan2(t[0], -t[2]) + math.pi) % (2 * math.pi) - math.pi) < math.radians(25):
                            return True
                    k = (round(x2 / 1.5), round(z2 / 1.5), round(math.degrees(h2) / 4) % 90, g2)
                    if k not in seen:
                        seen.add(k)
                        nxt.append((x2, z2, h2, g2))
            frontier = nxt
        return False

    def test_key_gallery_flyable_default_controls(self):
        """F2: the hidden key's gallery (one long S through Tunnel Hill and the cellar) is a round trip at the
        DEFAULT turn radius (auto-throttle 122 studs/s at 75 deg/s, about 93; no sharp bank) with 3 studs of wall
        margin, from the line at the tunnel mouth and from the CP8 respawn in front of it. The old chicane (bend radii
        15-40 in a 34-wide tube, 35-wide cellar doors) needed sharp bank."""
        kg = self.sk["provenance"]["keyGallery"]
        self.assertGreaterEqual(kg["radius"], 22)
        cps = self.gp["checkpoints"]["stations"]
        before = max(v for v in cps if v < kg["from"])
        rr = self.gallery_raster()
        self.assertTrue(self.fly_gallery(rr, kg["from"] - 14, 122.0, 75.0, 3.0), "from the line at the mouth")
        self.assertTrue(self.fly_gallery(rr, before + 6, 122.0, 75.0, 3.0), "from the checkpoint before the gallery")
        # TrackData hiddenKey.gallery (for a course assist that follows the side tube, F3/G8): the centreline at line
        # height, from the race line through the key's cellar back to the race line, inside the carved tube
        pts = self.gp["key"]["gallery"]
        line = self.sk["flight"]["lineOffset"]
        self.assertLess(dist(pts[0], self.route.frame_at(kg["from"]).offset(0, line)), 1.0)
        self.assertLess(dist(pts[-1], self.route.frame_at(kg["to"]).offset(0, line)), 1.0)
        self.assertLess(min(dist(q, self.gp["key"]["pos"]) for q in pts), 6.0)
        for q in pts:
            i, j = int(round((q[2] - rr["z0"]) / rr["res"])), int(round((q[0] - rr["x0"]) / rr["res"]))
            self.assertTrue(rr["free"][i, j], q)
        # the key's pickup sphere lies on the gallery line, in the cellar, with nothing collidable around it
        key = self.gp["key"]["pos"]
        i, j = int(round((key[2] - rr["z0"]) / rr["res"])), int(round((key[0] - rr["x0"]) / rr["res"]))
        self.assertTrue(erode(rr["free"][i - 30:i + 31, j - 30:j + 31], 18)[30, 30])

    def test_gallery_crash_respawns_before_its_entrance(self):
        """F2: a crash anywhere in the gallery respawns in front of its entrance, not past it (a lap). RaceManager
        credits a checkpoint within 110 stations (or 85 studs) of it, so the checkpoint before the gallery is credited
        before the gallery starts and the next one only after the gallery has rejoined."""
        kg = self.sk["provenance"]["keyGallery"]
        cps = self.gp["checkpoints"]["stations"]
        before = max(v for v in cps if v < kg["from"])
        after = min(v for v in cps if v > kg["from"])
        self.assertLess(before, kg["from"] - 30)
        self.assertGreater(after - 110, kg["to"])
        f_after = self.route.frame_at(after).offset(0, self.gp["checkpoints"]["heightOffset"])
        for o in self.sk["shells"]["ops"]:
            if o["op"] == "FillBall" and o["mat"] == "Air" and o["r"] == kg["radius"]:
                self.assertGreater(dist(o["center"], f_after), 85 + o["r"])
        # the respawn frame (route +12 along the tangent) has 150 studs of clear line ahead: open air over the deck,
        # then the carved tunnel tube (its runtime carve opens the hill face at the portal)
        f = self.route.frame_at(before)
        tube = next(o for o in self.sk["shells"]["ops"] if o["op"] == "CarveRouteTube")
        centres, halves, _ = adapt.collidable_parts(self.plan)
        a = f.offset(0, 12)
        z = [a[i] + f.tangent[i] * 150 for i in range(3)]
        self.assertFalse(adapt.aabbs_hit_obb(centres, halves, *adapt.segment_box(a, z, 3, -3, 3)).any())
        for k in range(0, 151, 5):
            q = [a[i] + f.tangent[i] * k for i in range(3)]
            if before + k < tube["fromStation"]:
                self.assertLess(self.ground(q[0], q[2]), q[1] - 4, k)
            else:
                self.assertLess(abs(12 - tube["lift"]), tube["radiusMin"] - 12)  # on the tube axis, well inside it

    def test_rim_cliff_stops_drifting_planes(self):
        """F5: from anywhere on the flight line, a plane that flies off in any direction with the nose settling down
        (1 deg, half the neutral -2 deg) meets terrain at or above its height before it leaves the map; it used to
        fly off the high line (y 200-270) over the old rim (crest 127-231) into the void. Where it meets the rim cliff
        (the last 50 studs), the face is steeper than 45 deg, so a level plane crashes (respawn at its checkpoint)
        instead of sliding up and over."""
        t = self.plan["terrain"]
        x0, z0 = t["x0"], t["z0"]
        x1, z1 = x0 + (t["nx"] - 1) * t["cell"], z0 + (t["nz"] - 1) * t["cell"]
        line = self.sk["flight"]["lineOffset"]
        drift = math.tan(math.radians(1.0))
        rim_hits = 0
        for s in range(0, int(self.L), 100):
            f = self.route.frame_at(s)
            px, py, pz = f.pos[0], f.pos[1] + line, f.pos[2]
            for th in range(0, 360, 15):
                dx, dz = math.sin(math.radians(th)), -math.cos(math.radians(th))
                ks = np.arange(4.0, 4000.0, 4.0)
                X, Z = px + dx * ks, pz + dz * ks
                inside = (X >= x0) & (X <= x1) & (Z >= z0) & (Z <= z1)
                X, Z, ks = X[inside], Z[inside], ks[inside]
                hit = np.nonzero(ground_grid(t, X, Z) >= py - drift * ks)[0]
                self.assertTrue(hit.size, (s, th, round(py)))  # no escape
                x, z = X[hit[0]], Z[hit[0]]
                if min(x - x0, x1 - x, z - z0, z1 - z) < 50:
                    rim_hits += 1
                    g = ground_grid(t, np.array([x + 4, x - 4, x, x]), np.array([z, z, z + 4, z - 4]))
                    slope = math.degrees(math.atan(math.hypot(g[0] - g[1], g[2] - g[3]) / 8))
                    self.assertGreater(slope, 45, (s, th, round(py), round(x), round(z)))
        self.assertGreater(rim_hits, 100)
        self.assertGreaterEqual(t["top"], max(t["heights"]))

    def test_set_dressing(self):
        """L61 set dressing: uploaded FOREST props only, a few hundred placements, scale 0.8-1.3, every whole AABB
        (yawed footprint from the ground up to the snap rise plus the prop height) clear of the flight corridor, and
        nothing collidable inside the battle arena."""
        import author_forest1 as A
        lib = A.prop_library()
        sd = self.sk["setDressing"]
        self.assertTrue(150 <= len(sd) <= 600, len(sd))
        self.assertGreaterEqual(len({d["key"] for d in sd}), 7)
        cor = A.Corridor(A.Track())
        b = self.gp["modes"]["battle"]
        cx, cz = b["center"][0], b["center"][2]
        cs, hs = [], []
        for d in sd:
            self.assertIn(d["key"], lib)
            self.assertTrue(0.8 <= d["scale"] <= 1.3, d)
            self.assertIs(d["snap"], True)
            c, h = A.prop_aabb(lib[d["key"]], d["pos"], d["yaw"], d["scale"])
            cs.append(c)
            hs.append(h)
            sx, _sy, sz, collide = lib[d["key"]]
            if collide:
                self.assertGreater(math.hypot(d["pos"][0] - cx, d["pos"][2] - cz) - math.hypot(sx, sz) * d["scale"] / 2,
                                   b["boundary"]["radius"] + 2.0, d)
        hits = cor.hits(np.array(cs), np.array(hs), margin=A.PROP_MARGIN)
        self.assertFalse(hits.any(), [sd[i] for i in np.nonzero(hits)[0][:5]])

    def test_author_script_is_deterministic(self):
        import author_forest1 as A
        with tempfile.TemporaryDirectory() as tmp:
            saved = (A.OUT, A.VARIANTS_OUT, A.SKY_DIR)
            A.OUT, A.VARIANTS_OUT, A.SKY_DIR = Path(tmp) / "plan.json", Path(tmp) / "variants.json", Path(tmp) / "sky"
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    A.main()
            finally:
                A.OUT, A.VARIANTS_OUT, A.SKY_DIR = saved
            self.assertEqual((Path(tmp) / "plan.json").read_bytes(), PLAN.read_bytes(),
                             "map/forest1/plan.json is stale: rerun tools/map/author_forest1.py")
            self.assertEqual(json.loads((Path(tmp) / "variants.json").read_text()), json.loads(VARIANTS.read_text()))  # values, not formatting
            for face in ("up", "side", "down"):
                # Metadata sanitation may change PNG compression, never image pixels.
                from PIL import Image
                with Image.open(Path(tmp) / "sky" / f"{face}.png") as generated, Image.open(ROOT / "assets" / "sky" / "forest1" / f"{face}.png") as retained:
                    self.assertEqual(generated.size, retained.size)
                    self.assertEqual(generated.convert("RGBA").tobytes(), retained.convert("RGBA").tobytes())


if __name__ == "__main__":
    unittest.main()
