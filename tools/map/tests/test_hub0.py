#!/usr/bin/env python3
"""HUB-0 (map/hub0/plan.json, authored by tools/map/author_hub0.py): adapt gates, the car-track contract and the
launch anchors (coins, boss, portals, finds, spawn, exchange), materials, lighting and sky files.
Run: python3 -m unittest discover -s tools/map/tests -v"""
import json
import math
import re
import shutil
import subprocess
import tempfile
import unittest

import numpy as np
from pathlib import Path

import fixtures  # noqa: F401  (puts tools/map and tools/course on sys.path)
import adapt
import route
import route_geometry

ROOT = fixtures.ROOT
PLAN_PATH = ROOT / "map" / "hub0" / "plan.json"
LUNE = shutil.which("lune") or shutil.which(str(Path.home() / ".local" / "bin" / "lune"))
POD_TYPES = {"Red", "Blue", "Yellow", "Green", "Rainbow", "Speed"}
DRIVE_TOP = 2.7  # paver top the car drives on
# v29 Wave 2 harbour frontage and tunnel collar prefabs (tools/map/author_hub0.py), all non-colliding dressing
HARBOUR_PREFIXES = ("QuaySection#", "QuayEnd#", "QuayLamp#", "QuayCrates#", "NetRack", "PierDressing_", "SeaplaneFloats",
                    "CliffTunnelCollar")


def load_plan() -> dict:
    return json.loads(PLAN_PATH.read_text())


def car_config(name: str) -> float:
    """A number from src/shared/CarConfig.luau (`CarConfig.NAME = 1.23`)."""
    src = (ROOT / "src" / "shared" / "CarConfig.luau").read_text()
    return float(re.search(rf"^CarConfig\.{name} = ([-\d.]+)", src, re.M).group(1))


def terrain_ground(plan: dict, x: float, z: float) -> float:
    """World terrain height, bilinear over the 30MAPS node grid (clamped to the grid)."""
    t = plan["terrain"]
    nx, nz, cell, x0, z0, H = t["nx"], t["nz"], t["cell"], t["x0"], t["z0"], t["heights"]
    fx = (min(max(x, x0), x0 + (nx - 1) * cell) - x0) / cell
    fz = (min(max(z, z0), z0 + (nz - 1) * cell) - z0) / cell
    ix, iz = min(int(math.floor(fx)), nx - 2), min(int(math.floor(fz)), nz - 2)
    tx, tz = fx - ix, fz - iz
    k = iz * nx + ix
    u = H[k] + (H[k + 1] - H[k]) * tx
    v = H[k + nx] + (H[k + nx + 1] - H[k + nx]) * tx
    return u + (v - u) * tz


def instance_frame(inst: dict):
    """(pivot, 3x3 rotation) of a plan instance, as the compiled builder places it."""
    return inst["p"], adapt.instance_rotation(inst["r"])


def part_top(plan: dict, prefix: str, x: float, z: float, tol: float = 0.15) -> float | None:
    """Highest collidable top surface at world (x, z) of the yaw-only B/W parts of every instance whose prefab key starts
    with `prefix` (WedgePart: zero height at local -Z, full height at +Z). `tol` closes the 0.2-stud plank seams."""
    best = None
    for inst in plan["instances"]:
        if not inst["pf"].startswith(prefix):
            continue
        p, r_inst = instance_frame(inst)
        for part in plan["prefabs"][inst["pf"]]["parts"]:
            extra = part[12] if len(part) > 12 else {}
            if part[0] not in "BW" or extra.get("nc"):
                continue
            rot = r_inst @ adapt.rot_yxz(*(v or 0 for v in part[7:10]))
            if abs(rot[1, 1] - 1.0) > 1e-6:
                continue
            c = [p[k] + sum(r_inst[k][j] * part[1 + j] for j in range(3)) for k in range(3)]
            sx, sy, sz = part[4:7]
            dx, dz = x - c[0], z - c[2]
            xl, zl = dx * rot[0, 0] + dz * rot[2, 0], dx * rot[0, 2] + dz * rot[2, 2]
            pad = tol if part[0] == "B" else 0.0
            if abs(xl) > sx / 2 + pad or abs(zl) > sz / 2 + pad:
                continue
            top = c[1] + sy / 2 if part[0] == "B" else c[1] - sy / 2 + (zl / sz + 0.5) * sy
            best = top if best is None else max(best, top)
    return best


class Hub0(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = load_plan()
        cls.sk = cls.plan["skyrally"]
        cls.gp = cls.sk["gameplay"]
        cls.res = adapt.check(cls.plan)
        cls.route = cls.res.route
        cls.length = cls.route.length

    # ---------------------------------------------------------------------------------------------- gates
    def test_adapt_gates_pass(self):
        self.assertEqual([f"{e.code}: {e.msg}" for e in self.res.report.errors], [])
        g = self.res.gates
        self.assertLessEqual(abs(self.length - self.sk["route"]["targetLength"]), 1.0)
        self.assertGreaterEqual(g["minRadius"], 85.0)
        self.assertEqual(self.sk["route"]["radiusExceptions"], [])
        self.assertEqual(g["corridorPartIntrusions"], 0)
        self.assertGreater(g["collidableParts"], 1000)
        self.assertTrue(self.sk["route"]["closed"])

    def test_identity(self):
        self.assertEqual((self.sk["id"], self.sk["key"], self.sk["zone"], self.sk["vehicle"]), ("HUB-0", "hub0", "HUB", "car"))
        self.assertEqual(self.sk["lighting"], "HUB-0")
        self.assertTrue((ROOT / self.sk["guide"]).is_file())
        self.assertAlmostEqual(self.sk["route"]["targetLength"], 3600, delta=200)

    # ------------------------------------------------------------------------------------- car contract
    def test_car_road_contract(self):
        deck = self.sk["deck"]
        self.assertTrue(40 <= deck["width"] <= 48)
        self.assertEqual(deck["piersEvery"], 0)
        self.assertEqual(deck["style"], "hub0_road")
        style = (ROOT / "src" / "server" / "kit" / "styles" / "hub0.luau").read_text()
        self.assertIn("hub0_road = {", style)
        # kit/Deck.luau centres exactly two paver columns (xOff = (c - 1.5) * pitch)
        self.assertRegex(style, r"\n\s*paverCols = 2,")
        for n in self.sk["route"]["nodes"]:
            self.assertLessEqual(abs(n["bank"]), 12)
        for w in self.route.waypoints:
            self.assertLessEqual(abs(w.bank), 12)
        rows, _ = route_geometry.analyse([list(w.pos) for w in self.route.waypoints], min_radius=85)
        self.assertLessEqual(max(abs(r["grade"]) for r in rows), 15.0)
        cor = self.sk["flight"]["corridor"]
        self.assertLessEqual(cor["halfWidth"], deck["width"] / 2)  # the corridor is the road's own footprint
        self.assertLess(cor["floor"], self.sk["flight"]["lineOffset"])

    def test_terrain_meets_road_edge(self):
        """Outside the tunnel and the bridge channels the ground at the road edge sits at deck level, and nowhere
        does terrain poke through the drive surface."""
        t = self.plan["terrain"]
        nx, nz, cell, x0, z0 = t["nx"], t["nz"], t["cell"], t["x0"], t["z0"]
        H = t["heights"]

        def ground(x, z):
            fx, fz = (x - x0) / cell, (z - z0) / cell
            ix, iz = min(max(int(math.floor(fx)), 0), nx - 2), min(max(int(math.floor(fz)), 0), nz - 2)
            tx, tz = fx - ix, fz - iz
            k = iz * nx + ix
            u = H[k] + (H[k + 1] - H[k]) * tx
            v = H[k + nx] + (H[k + nx + 1] - H[k + nx]) * tx
            return u + (v - u) * tz

        tun = self.sk["provenance"]["tunnel"]
        skip = [(tun[0] - 40, tun[1] + 40)] + [(b["deckEnd"] - 10, b["deckResume"] + 10) for b in self.sk["provenance"]["bridges"]]
        edge_ok = total = 0
        s = 0.0
        while s < self.length:
            if not any(a <= s <= b for a, b in skip):
                f = self.route.frame_at(s)
                sb = math.sin(math.radians(f.bank))
                for lat in (-20.0, -10.0, 0.0, 10.0, 20.0):
                    p = f.offset(lat, 0)
                    self.assertLessEqual(ground(p[0], p[2]), f.pos[1] + lat * sb + DRIVE_TOP + 0.3, f"terrain above road at st {s:.0f} lat {lat}")
                for lat in (-27.0, 27.0):
                    p = f.offset(lat, 0)
                    total += 1
                    if abs(ground(p[0], p[2]) - (f.pos[1] + math.copysign(24.0, lat) * sb + 1.2)) < 2.5:
                        edge_ok += 1
            s += 10.0
        self.assertGreater(edge_ok / total, 0.95)

    def test_tunnel_shoulders_at_deck_level(self):
        """Inside the tunnel (shell Terrain, not the grid) the shoulders beside the curbs sit at the open-road shoulder
        level in the banked deck frame (1.2 above the ribbon): solid just below it, open just above it."""
        ops = self.sk["shells"]["ops"]
        tube = max(i for i, o in enumerate(ops) if o["op"] == "CarveRouteTube")
        later = [o for o in ops[tube + 1:] if o["op"] == "FillBlock"]
        self.assertTrue(later)

        def inside(p, op):
            c = op["cf"]
            d = [p[k] - c[k] for k in range(3)]
            cols = [(c[3], c[6], c[9]), (c[4], c[7], c[10]), (c[5], c[8], c[11])]
            return all(abs(sum(d[k] * col[k] for k in range(3))) <= op["size"][j] / 2 for j, col in enumerate(cols))

        tun = self.sk["provenance"]["tunnel"]
        s = tun[0]
        while s <= tun[1]:
            f = self.route.frame_at(s)
            th = math.radians(f.bank)
            rb = [f.right[k] * math.cos(th) + f.up[k] * math.sin(th) for k in range(3)]
            ub = [-f.right[k] * math.sin(th) + f.up[k] * math.cos(th) for k in range(3)]
            for lat in (-27.0, 27.0):
                below = [f.pos[k] + rb[k] * lat + ub[k] * (1.2 - 1.5) for k in range(3)]
                above = [f.pos[k] + rb[k] * lat + ub[k] * (1.2 + 1.0) for k in range(3)]
                self.assertTrue(any(inside(below, o) for o in later), f"no tunnel shoulder at st {s:.0f} lat {lat}")
                self.assertFalse(any(inside(above, o) for o in later), f"tunnel shoulder too high at st {s:.0f} lat {lat}")
            s += 5.0

    def test_bridge_channels_open_water(self):
        """Under the middle of each log-bridge span the ground is under water across the whole road width and both
        shoulders (storm guide: water on both sides; falling off either edge drops into the channel)."""
        t = self.plan["terrain"]
        nx, cell, x0, z0 = t["nx"], t["cell"], t["x0"], t["z0"]
        H = t["heights"]
        level = t["water"]["level"]

        def ground(x, z):
            fx, fz = (x - x0) / cell, (z - z0) / cell
            ix, iz = int(math.floor(fx)), int(math.floor(fz))
            tx, tz = fx - ix, fz - iz
            k = iz * nx + ix
            u = H[k] + (H[k + 1] - H[k]) * tx
            v = H[k + nx] + (H[k + nx + 1] - H[k + nx]) * tx
            return u + (v - u) * tz

        for b in self.sk["provenance"]["bridges"]:
            a, z = b["deckEnd"] + 14.0, b["deckResume"] - 14.0
            self.assertLess(a, z)
            s = a
            while s <= z:
                f = self.route.frame_at(s)
                for lat in (-40.0, -30.0, -20.0, -10.0, 0.0, 10.0, 20.0, 30.0, 40.0):
                    p = f.offset(lat, 0)
                    self.assertLess(ground(p[0], p[2]), level - 2.0, f"{b['name']} channel dry at st {s:.0f} lat {lat}")
                s += 4.0

    # ----------------------------------------------------------------------------------------- gameplay
    def test_checkpoints(self):
        st = self.gp["checkpoints"]["stations"]
        self.assertEqual(st[0], 0)
        self.assertEqual(st, sorted(st))
        gaps = [b - a for a, b in zip(st, st[1:])] + [self.length - st[-1]]
        # 400 apart, plus the causeway checkpoint between the log bridges (200 either side of it)
        self.assertTrue(all(180 <= g <= 460 for g in gaps), gaps)
        bridges = self.sk["provenance"]["bridges"]
        for b in bridges:
            self.assertFalse(any(b["deckEnd"] - 20 <= c <= b["deckResume"] + 20 for c in st))
        # trap audit H0-06 b: a fall at the south bridge respawns after the north bridge, not before it
        between = [c for c in st if bridges[0]["deckResume"] + 20 <= c <= bridges[1]["deckEnd"] - 20]
        self.assertEqual(len(between), 1, between)

    def test_rings_pads_pods(self):
        rings, pads, pods = self.gp["rings"], self.gp["pads"], self.gp["pods"]
        self.assertTrue(6 <= len(rings) <= 10)
        self.assertTrue(2 <= len(pads) <= 4)
        items = [p for p in pods if p["type"] != "Speed"]
        self.assertEqual(len(items), 35)  # item cubes v3: 7 staggered sets of 2 + 3 (rules: test_item_cubes)
        self.assertTrue(all(r["lateral"] == 0 for r in rings))  # on the drive line
        # a car hull (~4.5 above the ribbon) passes within the car's ring trigger radius (16) of the ring centre
        self.assertTrue(all(abs(r["height"] - 4.5) <= 14 for r in rings))
        # ... and through the opening: the opening's lower edge (kit/Gameplay inner glow, r 9.95) is at or under the
        # paver top, so the car never drives through the non-colliding lower rim
        self.assertTrue(all(r["height"] - 9.95 <= DRIVE_TOP for r in rings))
        self.assertTrue({p["type"] for p in pods} <= POD_TYPES)
        self.assertEqual({p["type"] for p in pods}, POD_TYPES)
        self.assertTrue(all(abs(p["lateral"]) <= 18 for p in items))  # across the road, still on it
        self.assertTrue(all(p["lateral"] == 0 for p in pods if p["type"] == "Speed"))  # boost blocks on the line, mid-gap
        names = [x["name"] for x in rings + pads + pods]
        self.assertEqual(len(names), len(set(names)))

    def test_start_and_finish(self):
        self.assertEqual(self.gp["finish"]["station"], 0)
        self.assertEqual(self.sk["framing"]["heroStation"], self.gp["startGrid"]["station"])

    def test_alternate_ends_on_race_line(self):
        alts = self.gp["alternates"]
        self.assertTrue(0 <= len(alts) <= 2)
        for alt in alts:
            self.assertTrue(alt["id"].startswith("Alt"))  # FlightController/CourseCarve treat ^Alt parts as track
            self.assertIn(alt["style"], ("tunnel", "ledge"))
            self.assertLess(alt["joinStation"], alt["rejoinStation"])
            for pt, st in ((alt["points"][0], alt["joinStation"]), (alt["points"][-1], alt["rejoinStation"])):
                best = min((self.route.frame_at(st + d) for d in range(0, 80, 2)) if pt is alt["points"][0]
                           else (self.route.frame_at(st - d) for d in range(0, 80, 2)),
                           key=lambda f: math.dist((f.pos[0], f.pos[2]), (pt[0], pt[2])))
                lateral = math.dist((best.pos[0], best.pos[2]), (pt[0], pt[2]))
                self.assertLess(lateral, 46.0)  # starts as a mouth beside the curbs
                # ledge slabs are 4 thick: their top is flush with the paver top where the car steps across
                self.assertLess(abs(pt[1] + 2.0 - (best.pos[1] + DRIVE_TOP)), 0.5)

    def test_coins(self):
        coins = self.gp["coins"]
        self.assertEqual(len(coins), 8)
        self.assertEqual(sorted(c["id"] for c in coins), list(range(1, 9)))
        alts = {a["id"]: a for a in self.gp["alternates"]}
        on_alt = [c for c in coins if c.get("alternate")]
        self.assertGreaterEqual(len(on_alt), 1)
        for c in on_alt:
            a = alts[c["alternate"]]
            self.assertTrue(a["joinStation"] < c["station"] < a["rejoinStation"])
            f = self.route.frame_at(c["station"])
            p = f.offset(c["lateral"], c["height"])
            self.assertLess(min(math.dist(p, q) for q in a["points"]), 12.0)
        for c in coins:
            self.assertTrue(0 <= c["station"] < self.length)

    def test_no_key_no_battle(self):
        self.assertIsNone(self.gp["key"])
        self.assertEqual(self.gp["modes"], {})

    def test_boss(self):
        boss = self.gp["boss"]
        content = (ROOT / "docs" / "CONTENT.md").read_text()
        row = next(line for line in content.splitlines() if line.startswith("| HUB-BOSS-1 "))
        self.assertIn(boss["hazard"], row)
        self.assertEqual(boss["id"], "HUB-BOSS-1")
        self.assertTrue(boss["anchors"])
        self.assertTrue(all(0 <= a < self.length for a in boss["anchors"]))
        self.assertEqual(boss["lighting"], "HUB-0-STORM")
        gaps = {(g["from"], g["to"]) for g in self.sk["deck"]["gaps"]}
        self.assertEqual(len(boss["riskyBridges"]), 2)
        self.assertEqual({(b["from"], b["to"]) for b in boss["riskyBridges"]}, gaps)
        pad_names = {p["name"] for p in self.gp["pads"]}
        self.assertTrue(boss["timedPads"])
        self.assertTrue(all(tp["name"] in pad_names for tp in boss["timedPads"]))
        bridge_instances = [i for i in self.plan["instances"] if i["pf"].startswith("RiskyLogBridge")]
        self.assertEqual(len(bridge_instances), 2)

    def test_portals_match_progression(self):
        portals = self.gp["portals"]
        self.assertEqual([p["zone"] for p in portals], ["DINO", "SNOW", "ISLAND", "FOREST", "SPACE"])
        prog = (ROOT / "src" / "shared" / "Progression.luau").read_text()
        block = prog[prog.index("Progression.PORTAL_THRESHOLD = {"):]
        block = block[:block.index("}")]
        expected = {k: int(v) for k, v in re.findall(r"(\w+) = (\d+)", block)}
        for p in portals:
            self.assertEqual(len(p["cf"]), 12)
            if p["zone"] == "SPACE":
                self.assertEqual(p["threshold"], "final-boss")
            else:
                self.assertEqual(p["threshold"], expected[p["zone"]])
            self.assertIn(p["prefab"], self.plan["prefabs"])

    def test_finds_spawn_exchange(self):
        prog = (ROOT / "src" / "shared" / "Progression.luau").read_text()
        ids = re.findall(r'"(HubFind_\w+)"', prog)
        finds = self.gp["finds"]
        self.assertEqual(sorted(f["id"] for f in finds), sorted(ids))
        reach = {f["id"]: f["reach"] for f in finds}
        self.assertEqual(reach, {"HubFind_Ground": "ground", "HubFind_WaterEdge": "water", "HubFind_Ledge": "plane",
                                 "HubFind_Cove": "car"})
        for f in finds:
            self.assertEqual(len(f["pos"]), 3)
        ledge = next(f for f in finds if f["id"] == "HubFind_Ledge")
        self.assertGreater(ledge["pos"][1], 120)  # above the ridge: a plane find
        self.assertEqual(len(self.gp["spawn"]["cf"]), 12)
        self.assertEqual({e["vehicle"] for e in self.gp["exchange"]}, {"car", "plane"})

    # ------------------------------------------------------------ trap audit fixes (docs/audits/traps_hub0.md)
    def test_h0_03_dock_slipway_runup_and_shoal(self):
        """Each timber dock can be driven onto from the beach (a slipway, no plank step for the wall rays), its run-up
        is clear, the planks run unbroken to the end platform, a splash kicker sits at the end, and the sea under and
        past it is shallower than the drown depth."""
        sink = car_config("WATER_SINK_DEPTH")
        lengths = {"TimberDock_Long": 110.0, "TimberDock_Short": 60.0}
        centres, halves, meta = adapt.collidable_parts(self.plan)
        docks = [i for i in self.plan["instances"] if i["pf"] in lengths]
        self.assertEqual(len(docks), 2)
        for inst in docks:
            L = lengths[inst["pf"]]
            p, rot = instance_frame(inst)
            d = (-rot[0][2], -rot[2][2])  # prefab -Z (out over the water) in world
            n = (-d[1], d[0])
            prev = None
            for k in range(-40, int(L + 8)):  # beach, slipway, planks, end platform and kicker: no step a car can't take
                x, z = p[0] + d[0] * k, p[2] + d[1] * k
                top = part_top(self.plan, inst["pf"], x, z)
                surf = max(terrain_ground(self.plan, x, z), top if top is not None else -1e9)
                if prev is not None:
                    self.assertLess(surf - prev, math.tan(math.radians(30)), f"{inst['pf']} step at {k}")
                prev = surf
                if 2 <= k <= L + 6:
                    self.assertIsNotNone(top, f"{inst['pf']} deck gap at {k}")
                    self.assertGreaterEqual(top, 3.3, f"{inst['pf']} deck low at {k}")
            kicker = [q for q in self.plan["prefabs"][inst["pf"]]["parts"] if q[0] == "W" and q[3] < -L - 2]
            self.assertEqual(len(kicker), 1)
            self.assertGreater(kicker[0][2] + kicker[0][5] / 2, 4.5)
            for k in range(-90, 0):  # the shore run-up, a car's width either side of the axis
                for o in (-4.5, 0.0, 4.5):
                    x, z = p[0] + d[0] * k + n[0] * o, p[2] + d[1] * k + n[1] * o
                    gy = terrain_ground(self.plan, x, z)
                    hit = ((abs(centres[:, 0] - x) <= halves[:, 0]) & (abs(centres[:, 2] - z) <= halves[:, 2])
                           & (centres[:, 1] + halves[:, 1] > gy + 2.2) & (centres[:, 1] - halves[:, 1] < gy + 6))
                    blockers = {meta[j]["prefab"] for j in hit.nonzero()[0]} - {inst["pf"]}
                    self.assertFalse(blockers, f"{inst['pf']} run-up blocked at {k}/{o}: {blockers}")
            for k in range(8, int(L + 8 + 60), 4):  # fall off the side or fly off the kicker: splash, not drown
                for o in (-20.0, -10.0, 0.0, 10.0, 20.0):
                    x, z = p[0] + d[0] * k + n[0] * o, p[2] + d[1] * k + n[1] * o
                    self.assertGreater(terrain_ground(self.plan, x, z), -(sink - 0.5), f"{inst['pf']} deep at {k}/{o}")
        find = next(f for f in self.gp["finds"] if f["id"] == "HubFind_WaterEdge")["pos"]
        top = part_top(self.plan, "TimberDock_Long", find[0], find[2])
        self.assertIsNotNone(top)
        self.assertLess(abs(top + car_config("RIDE_HEIGHT") - find[1]), 13.0)  # the find floats over the end platform

    def test_h0_04_cove_slipway(self):
        """The cove find is reached by a two-way timber ramp off the boardwalk slab (top flush with the slab top, gentle,
        running into the sand), not by a 4.6-stud drop with no way back."""
        inst = [i for i in self.plan["instances"] if i["pf"] == "CoveSlipway"]
        self.assertEqual(len(inst), 1)
        p, rot = instance_frame(inst[0])
        wedge = self.plan["prefabs"]["CoveSlipway"]["parts"][0]
        self.assertEqual(wedge[0], "W")
        L, rise = wedge[6], wedge[5]
        self.assertLessEqual(math.degrees(math.atan2(rise, L)), 12.0)
        down = (rot[0][2], rot[2][2])  # prefab +Z (downhill) in world
        # the high edge is on the slab and flush with its top (kit/Deck ledge: 26 wide, top = point + 2)
        pts = self.gp["alternates"][0]["points"]
        best = None
        for a, b in zip(pts, pts[1:]):
            vx, vz = b[0] - a[0], b[2] - a[2]
            t = max(0.0, min(1.0, ((p[0] - a[0]) * vx + (p[2] - a[2]) * vz) / (vx * vx + vz * vz)))
            dist = math.hypot(p[0] - a[0] - vx * t, p[2] - a[2] - vz * t)
            if best is None or dist < best[0]:
                best = (dist, a[1] + (b[1] - a[1]) * t + 2.0)
        self.assertLess(best[0], 13.0)
        self.assertLess(abs(part_top(self.plan, "CoveSlipway", p[0] + down[0] * 0.2, p[2] + down[1] * 0.2) - best[1]), 0.3)
        # it runs into the sand before its low end (no lip to drive up onto from the beach)
        lo = (p[0] + down[0] * (L - 0.5), p[2] + down[1] * (L - 0.5))
        self.assertLess(part_top(self.plan, "CoveSlipway", *lo), terrain_ground(self.plan, *lo))
        # a car rolling down it passes through the find's pickup radius (TrackDirector.FIND_RADIUS 14)
        find = next(f for f in self.gp["finds"] if f["id"] == "HubFind_Cove")["pos"]
        ride = car_config("RIDE_HEIGHT")
        near = min(math.dist(find, (p[0] + down[0] * s, max(part_top(self.plan, "CoveSlipway", p[0] + down[0] * s,
                                                                         p[2] + down[1] * s) or -1e9,
                                                                terrain_ground(self.plan, p[0] + down[0] * s,
                                                                               p[2] + down[1] * s)) + ride,
                                    p[2] + down[1] * s)) for s in range(1, int(L) + 10))
        self.assertLess(near, 10.0)

    def test_h0_11_no_bowl_and_climbable_inland_edge(self):
        """No Air ball digs a bowl beside the boardwalk, and on its inland side the ground stays within a climbable step
        of the slab top, so a car that drops off that edge can drive back up."""
        cove = next(f for f in self.gp["finds"] if f["id"] == "HubFind_Cove")["pos"]
        for op in self.sk["shells"]["ops"]:
            if op["op"] == "FillBall" and op["mat"] == "Air":
                self.assertGreater(math.dist(op["center"][0::2], cove[0::2]), 120.0)
        step = car_config("RIDE_HEIGHT") + car_config("WALL_RAY_LIFT") - 0.2
        wps = [w.pos for w in self.route.waypoints]
        pts = self.gp["alternates"][0]["points"]
        for i in range(1, len(pts) - 1):
            a, b, q = pts[i - 1], pts[i + 1], pts[i]
            tx, tz = b[0] - a[0], b[2] - a[2]
            m = math.hypot(tx, tz)
            nrm = (-tz / m, tx / m)
            side = min((1, -1), key=lambda s: min(math.hypot(q[0] + nrm[0] * s * 20 - w[0], q[2] + nrm[1] * s * 20 - w[2])
                                                  for w in wps))
            for off in (14.0, 15.0, 16.0):
                x, z = q[0] + nrm[0] * side * off, q[2] + nrm[1] * side * off
                self.assertGreater(terrain_ground(self.plan, x, z), q[1] + 2.0 - step, f"AltCove point {i} at {off}")

    def test_h0_05_cliff_road_no_pits(self):
        """Inland of the north cliff road the ground holds shoulder level out to the ridge face: no pit a car can
        drop into and never climb out of (the hub has no off-track rescue)."""
        for race in range(570, 1270, 5):
            f = self.route.frame_at(float(race))
            sb = math.sin(math.radians(f.bank))
            shoulder = f.pos[1] + 24.0 * sb + 1.2
            for lat in (38.0, 42.0, 46.0):
                p = f.offset(lat, 0)
                self.assertGreater(terrain_ground(self.plan, p[0], p[2]), shoulder - 1.0, f"pit at race {race} lat {lat}")

    def test_h0_05_respawn_anchors(self):
        """hub.respawns: named anchors on dry, drivable ground (the runtime picks the nearest; G5)."""
        anchors = {a["name"]: a for a in self.gp["respawns"]}
        self.assertEqual(set(anchors), {"Plaza", "StartLine", "ExchangeForecourt", "DockRoot", "CoveSlipwayTop",
                                        "LighthousePlateau", "Causeway"})
        self.assertEqual(anchors["Plaza"]["cf"], self.gp["spawn"]["cf"])
        for a in anchors.values():
            cf = a["cf"]
            self.assertEqual(len(cf), 12)
            self.assertAlmostEqual(cf[7], 1.0)  # upright
            ground = terrain_ground(self.plan, cf[0], cf[2])
            if a["name"] == "CoveSlipwayTop":
                surface = part_top(self.plan, "CoveSlipway", cf[0], cf[2]) or (cf[1] - 3.0)
                self.assertLess(abs(cf[1] - 3.0 - surface), 0.5)
            elif a["name"] in ("StartLine", "Causeway"):
                self.assertTrue(any(math.dist(cf[0:3], w.pos) < 40 for w in self.route.waypoints))
            else:
                self.assertLess(abs(cf[1] - 3.0 - ground), 0.6, a["name"])
            self.assertGreater(cf[1] - 3.0, 0.5, f"{a['name']} under the water line")

    def test_h0_06_causeway_pad_line(self):
        """Straight off the causeway pad at boost speed (no steering) the car stays on the 28-wide south log bridge,
        and the pad trigger window covers the drive line."""
        cause = [p for p in self.gp["pads"] if "Causeway" in p["name"]]
        self.assertEqual(len(cause), 1)
        pad = cause[0]
        reach = car_config("PAD_BOOST_SPEED") * car_config("PAD_BOOST_DURATION")
        half = 14.0 - car_config("HALF_WIDTH")
        self.assertLessEqual(abs(pad["lateral"]), car_config("PAD_TRIGGER_RADIUS") - 6.0)
        f = self.route.frame_at(pad["station"])
        t = (f.tangent[0], f.tangent[2])
        m = math.hypot(*t)
        t = (t[0] / m, t[1] / m)
        # The causeway checkpoint (H0-06 b) respawns a car on the race line (lateral 0, its own tangent) just short of
        # the pad, which fires before the kid can steer: that launch line must stay on the logs too.
        bridges = self.sk["provenance"]["bridges"]
        cp = [c for c in self.gp["checkpoints"]["stations"]
              if bridges[0]["deckResume"] < c < pad["station"] < bridges[1]["deckEnd"]]
        self.assertEqual(len(cp), 1, cp)
        fc = self.route.frame_at(float(cp[0]))
        tc = (fc.tangent[0], fc.tangent[2])
        mc = math.hypot(*tc)
        lines = [(f.offset(lat, 0), t) for lat in (pad["lateral"] - 2.0, pad["lateral"], pad["lateral"] + 2.0, 0.0)]
        lines.append((fc.offset(0.0, 0), (tc[0] / mc, tc[1] / mc)))
        for k, (o, t) in enumerate(lines):
            lat = f"line {k}"
            for b in self.sk["provenance"]["bridges"]:
                pa, pb = self.route.frame_at(b["deckEnd"]).pos, self.route.frame_at(b["deckResume"]).pos
                cx, cz = pb[0] - pa[0], pb[2] - pa[2]
                cl = math.hypot(cx, cz)
                ux, uz = cx / cl, cz / cl
                s = 0.0
                while s <= reach:
                    x, z = o[0] + t[0] * s, o[2] + t[1] * s
                    along = (x - pa[0]) * ux + (z - pa[2]) * uz
                    if 0.0 <= along <= cl:
                        off = (x - pa[0]) * -uz + (z - pa[2]) * ux
                        self.assertLess(abs(off), half - 2.0, f"{b['name']} from lateral {lat} at {s:.0f}")
                    s += 1.0

    def test_h0_08_spawn_lanes_clear(self):
        """Every FlightServer hub slot faces open plaza: 140 studs (2 s of touch auto-throttle) straight ahead, a car's
        width either side, without a collidable part, the plaza rim or a portal trigger."""
        fs = (ROOT / "src" / "server" / "FlightServer.luau").read_text()
        self.assertIn("hubSpawn * CFrame.new((col - 1.5) * 12, 3, row * 16)", fs)
        cf = self.gp["spawn"]["cf"]
        look = (-cf[5], -cf[11])
        right = (cf[3], cf[9])
        centres, halves, meta = adapt.collidable_parts(self.plan)
        portals = [(p["cf"][0], p["cf"][2]) for p in self.gp["portals"]]
        import author_hub0
        plaza = (author_hub0.ORIGIN[0] + author_hub0.PLAZA_C[0], author_hub0.ORIGIN[2] + author_hub0.PLAZA_C[1])
        for slot in range(1, 9):
            col, row = (slot - 1) % 4, (slot - 1) // 4
            sx = cf[0] + right[0] * (col - 1.5) * 12 - look[0] * row * 16
            sz = cf[2] + right[1] * (col - 1.5) * 12 - look[1] * row * 16
            for s in range(0, 140, 2):
                for o in (-3.6, 0.0, 3.6):
                    x, z = sx + look[0] * s + right[0] * o, sz + look[1] * s + right[1] * o
                    self.assertLess(math.hypot(x - plaza[0], z - plaza[1]), 140.0, f"slot {slot} leaves the plaza at {s}")
                    gy = terrain_ground(self.plan, x, z)
                    hit = ((abs(centres[:, 0] - x) <= halves[:, 0]) & (abs(centres[:, 2] - z) <= halves[:, 2])
                           & (centres[:, 1] + halves[:, 1] > gy + 2.2) & (centres[:, 1] - halves[:, 1] < gy + 6))
                    self.assertFalse(hit.any(), f"slot {slot} blocked at {s}: {[meta[j]['prefab'] for j in hit.nonzero()[0]]}")
                    for px, pz in portals:
                        self.assertGreater(math.hypot(x - px, z - pz), 20.0, f"slot {slot} crosses a portal at {s}")

    def test_h0_08_return_grid_lanes_clear(self):
        """The return grid after a race (RaceFlowRules.returnFrame, L19) in front of each arch: turned RETURN_TURN off
        straight-out (which faced the fountain basin 55-65 studs ahead), every slot of every arch has 120 studs (2 s of
        touch auto-throttle) of open paving ahead, with 2 degrees to spare either way: no collidable part, still on the
        plaza, never through another arch's trigger."""
        rf = (ROOT / "src" / "shared" / "RaceFlowRules.luau").read_text()
        turn = float(re.search(r"RaceFlowRules\.RETURN_TURN = ([-\d.]+)", rf).group(1))
        back = float(re.search(r"RaceFlowRules\.RETURN_BACK = ([-\d.]+)", rf).group(1))
        fs = (ROOT / "src" / "server" / "FlightServer.luau").read_text()
        self.assertIn("hubSpawn * CFrame.new((col - 1.5) * 12, 3, row * 16)", fs)
        centres, halves, meta = adapt.collidable_parts(self.plan)
        portals = [(p["zone"], p["cf"]) for p in self.gp["portals"]]
        import author_hub0
        plaza = (author_hub0.ORIGIN[0] + author_hub0.PLAZA_C[0], author_hub0.ORIGIN[2] + author_hub0.PLAZA_C[1])
        for zone, cf in portals:
            lx, lz = -cf[5], -cf[11]
            n = math.hypot(lx, lz)
            dx, dz = lx / n, lz / n
            bx, bz = cf[0] - dx * back, cf[2] - dz * back
            for t_deg in (turn - 2, turn, turn + 2):
                t = math.radians(t_deg)
                look = (-dx * math.cos(t) - dz * math.sin(t), dx * math.sin(t) - dz * math.cos(t))
                right = (-look[1], look[0])
                for slot in range(1, 9):
                    col, row = (slot - 1) % 4, (slot - 1) // 4
                    sx = bx + right[0] * (col - 1.5) * 12 - look[0] * row * 16
                    sz = bz + right[1] * (col - 1.5) * 12 - look[1] * row * 16
                    for s in range(0, 120, 2):
                        for o in (-3.6, 0.0, 3.6):
                            x, z = sx + look[0] * s + right[0] * o, sz + look[1] * s + right[1] * o
                            where = f"{zone} slot {slot} turn {t_deg} at {s}"
                            self.assertLess(math.hypot(x - plaza[0], z - plaza[1]), 140.0, f"{where}: leaves the plaza")
                            gy = terrain_ground(self.plan, x, z)
                            hit = ((abs(centres[:, 0] - x) <= halves[:, 0]) & (abs(centres[:, 2] - z) <= halves[:, 2])
                                   & (centres[:, 1] + halves[:, 1] > gy + 2.2) & (centres[:, 1] - halves[:, 1] < gy + 6))
                            self.assertFalse(hit.any(), f"{where}: {[meta[j]['prefab'] for j in hit.nonzero()[0]]}")
                            for other, ocf in portals:
                                if other != zone:
                                    self.assertGreater(math.hypot(x - ocf[0], z - ocf[2]), 20.0, f"{where}: {other} trigger")

    # --------------------------------------------------------------------------------- art and materials
    # ------------------------------------------------- v29 Wave 2: harbour frontage (critic 3.1) and the tunnel collar
    def harbour_boxes(self, collar: bool = True):
        """World AABBs (centre, half, prefab) of every part of the v29 harbour and collar prefabs."""
        out = []
        for inst in self.plan["instances"]:
            if not inst["pf"].startswith(HARBOUR_PREFIXES) or (not collar and inst["pf"] == "CliffTunnelCollar"):
                continue
            p, r_inst = instance_frame(inst)
            for q in self.plan["prefabs"][inst["pf"]]["parts"]:
                rot = r_inst @ adapt.rot_yxz(*(v or 0 for v in q[7:10]))
                c = np.array(p) + r_inst @ np.array(q[1:4], float)
                out.append((c, np.abs(rot) @ (np.array(q[4:7], float) * 0.5), inst["pf"]))
        return out

    def test_v29_harbour_never_collides(self):
        """Owner hard rule (wall driving untouched): every harbour and collar part is non-colliding (MapAdapter's DecorQuery
        then clears its CanQuery, so no wheel probe or respawn ray stands on it), the moored vehicles are adapter meshes
        with collide false, and the collidable art of the map is exactly the docks, houses and arches it was."""
        keys = [k for k in self.plan["prefabs"] if k.startswith(HARBOUR_PREFIXES)]
        self.assertGreaterEqual(len(keys), 12)
        for k in keys:
            for q in self.plan["prefabs"][k]["parts"]:
                self.assertTrue(len(q) > 12 and q[12].get("nc"), f"{k}: collidable part {q[:12]}")
        placed = {i["pf"] for i in self.plan["instances"]}
        for want in ("QuayEnd#N", "QuayEnd#S", "PierDressing_Long", "PierDressing_Short", "SeaplaneFloats",
                     "CliffTunnelCollar", "NetRack", "QuayLamp#lit"):
            self.assertIn(want, placed)
        self.assertEqual(sum(1 for i in self.plan["instances"] if i["pf"] == "CliffTunnelCollar"), 2)
        self.assertEqual(sum(1 for i in self.plan["instances"] if i["pf"] == "CliffTunnelArch"), 2, "arches stay (colliders)")
        for m in self.sk["meshes"]:
            self.assertIs(m["collide"], False, m["name"])
        # light budget: three quay lamps, the long pier's lantern and one bounce lantern per tunnel mouth
        lights = []
        for inst in self.plan["instances"]:
            if inst["pf"].startswith(HARBOUR_PREFIXES):
                lights += [q[12]["l"] for q in self.plan["prefabs"][inst["pf"]]["parts"] if len(q) > 12 and "l" in q[12]]
        self.assertEqual(len(lights), 6)
        self.assertTrue(all(l_[0] <= 34 and l_[1] <= 1.0 and l_[3] is False for l_ in lights))

    def test_v29_quay_on_the_shore_off_the_road_and_cliffs(self):
        """The quay sits on the west beach's waterline, at least 90 studs seaward of the race line, on sand (never on the
        hub cliffs or the exchange forecourt), and its apron dressing stands clear of the two docks' shore run-ups."""
        pts = np.array([w.pos for w in self.route.waypoints])
        docks = [i for i in self.plan["instances"] if i["pf"].startswith("TimberDock_")]
        for inst in self.plan["instances"]:
            pf = inst["pf"]
            if not pf.startswith(HARBOUR_PREFIXES) or pf == "CliffTunnelCollar":
                continue
            x, z = inst["p"][0], inst["p"][2]
            gy = terrain_ground(self.plan, x, z)
            self.assertLess(gy, 2.0, f"{pf} on raised ground {gy:.1f} at {x:.0f},{z:.0f}")
            self.assertGreater(float(np.min(np.hypot(pts[:, 0] - x, pts[:, 2] - z))), 90.0, f"{pf} near the road")
            if pf.startswith("QuaySection#"):
                self.assertTrue(-0.6 < gy < 1.0, f"{pf} off the waterline ({gy:.2f})")
            if pf.startswith(("QuayLamp#", "QuayCrates#", "NetRack")):
                for d in docks:
                    p, rot = instance_frame(d)
                    dvec = (-rot[0][2], -rot[2][2])
                    along = (x - p[0]) * dvec[0] + (z - p[2]) * dvec[1]
                    perp = (x - p[0]) * -dvec[1] + (z - p[2]) * dvec[0]
                    self.assertFalse(-90 <= along <= 0 and abs(perp) < 14, f"{pf} in {d['pf']}'s run-up")
        ex = next(i for i in self.plan["instances"] if i["pf"] == "VehicleExchangeBays")["p"]
        for c, _, pf in self.harbour_boxes(collar=False):
            self.assertGreater(math.hypot(c[0] - ex[0], c[2] - ex[2]), 80.0, f"{pf} at the exchange forecourt")

    def test_v29_moored_vehicles(self):
        """The moored plane and hovercraft are the existing in-game models (PlaneBuilder ids, no new asset ids), over
        open water beside their pier, clear of its piles and of the moored boats."""
        src = (ROOT / "src" / "server" / "PlaneBuilder.luau").read_text()
        ids = {k: int(re.search(rf"PlaneBuilder\.{k} = (\d+)", src).group(1)) for k in ("HERO_PLANE_MODEL_ID", "HERO_HOVERCRAFT_MODEL_ID")}
        tex = re.search(r'PlaneBuilder\.HERO_HOVERCRAFT_TEX_ID = "([^"]+)"', src).group(1)
        meshes = {m["name"]: m for m in self.sk["meshes"]}
        self.assertEqual(set(meshes), {"MooredPlane", "MooredHovercraft"})
        self.assertEqual(meshes["MooredPlane"]["model"], ids["HERO_PLANE_MODEL_ID"])
        self.assertEqual(meshes["MooredHovercraft"]["model"], ids["HERO_HOVERCRAFT_MODEL_ID"])
        self.assertEqual(meshes["MooredHovercraft"]["textureId"], tex)
        boats = [i["p"] for i in self.plan["instances"] if i["pf"].startswith("MooredBoat#")]
        docks = [i for i in self.plan["instances"] if i["pf"].startswith("TimberDock_")]
        for name, m in meshes.items():
            x, y, z = m["cf"][:3]
            self.assertTrue(m["parent"].startswith("Harbor/"))
            self.assertLess(terrain_ground(self.plan, x, z), 0.0, f"{name} not over water")
            self.assertLess(y - m["height"] / 2, 2.5, f"{name} floats too high")
            self.assertGreater(y - m["height"] / 2, -0.2, f"{name} sunk")
            for b in boats:
                self.assertGreater(math.hypot(b[0] - x, b[2] - z), 18.0, f"{name} on a moored boat")
            p, rot = instance_frame(min(docks, key=lambda d: math.hypot(d["p"][0] - x, d["p"][2] - z)))
            dvec = (-rot[0][2], -rot[2][2])
            perp = abs((x - p[0]) * -dvec[1] + (z - p[2]) * dvec[0])
            half = 8.25 if name == "MooredPlane" else 6.25  # wingspan / hull half width across the dock
            self.assertGreater(perp - half, 7.3 + 1.0, f"{name} into the dock piles")
            # orientation: the plane's nose (mesh -X) and the hull's long axis (mesh X) run along the dock
            ax = np.array([m["cf"][3], m["cf"][6], m["cf"][9]])
            self.assertGreater(abs(ax[0] * dvec[0] + ax[2] * dvec[1]), 0.99, f"{name} not along the dock")

    def test_v29_sight_lines(self):
        """Sight lines (the Paint Shop / Storm stand checks): from the hub approach views nothing new stands between the
        camera and a portal arch, the Paint Shop kiosk or the Storm stand; from the start grid's chase camera nothing new
        stands between the camera and the south tunnel mouth (the guide's view up the promenade)."""
        def seg_dist(c, a, b):
            ab, ac = b - a, c - a
            t = max(0.0, min(1.0, float(ac @ ab) / float(ab @ ab)))
            return float(np.linalg.norm(ac - ab * t))

        boxes = self.harbour_boxes()
        views = [(-8196, 8066), (-8180, 8050), (-8160, 8030), (-8150, 8010), (-8200, 8030), (-8120, 8010), (-8180, 8066)]
        targets = [np.array([i["p"][0], 40.0, i["p"][2]]) for i in self.plan["instances"] if i["pf"].startswith("PortalArch_")]
        targets += [np.array([-8262.0, 30.0, 8052.0]), np.array([-8122.0, 30.0, 8102.0])]  # Paint Shop, Storm stand
        self.assertEqual(len(targets), 7)
        for vx, vz in views:
            a = np.array([vx, 31.0, vz], float)
            for b in targets:
                for c, h, pf in boxes:
                    self.assertGreater(seg_dist(c, a, b) - float(np.linalg.norm(h)), 12.0, f"{pf} in a hub sight line")
        f = self.route.frame_at(20.0)
        hx, hz = f.tangent[0], f.tangent[2]
        n = math.hypot(hx, hz)
        eye = np.array(f.offset(0, DRIVE_TOP)) + np.array([-hx / n * 16, 7.0, -hz / n * 16])
        south = min((i for i in self.plan["instances"] if i["pf"] == "CliffTunnelCollar"),
                    key=lambda i: math.hypot(i["p"][0] - eye[0], i["p"][2] - eye[2]))
        for dx_, dy_ in ((0.0, 30.0), (-30.0, 20.0), (30.0, 20.0), (0.0, 62.0)):
            p, rot = instance_frame(south)
            b = np.array(p) + rot @ np.array([dx_, dy_, -12.0])
            for c, h, pf in boxes:
                if pf == "CliffTunnelCollar":
                    continue
                self.assertGreater(seg_dist(c, eye, b) - float(np.linalg.norm(h)), 6.0, f"{pf} hides the tunnel mouth")

    def test_v29_tunnel_collar_frames_the_live_colliders(self):
        """The collar keeps the opening the cars and planes use clear (the stone_arch_v3 opening ArtSwap's specs check, and
        the road corridor), and every stone_arch_v3 collider ArtSwap still places (collidersOnly) lies inside visible
        collar masonry, so the mouths have no invisible walls."""
        src = (ROOT / "src" / "shared" / "ArtSwapRules.luau").read_text()
        rule = src[src.index('{ id = "cliff_tunnel_arch"'):]
        self.assertIn("collidersOnly = true", rule[:rule.index("{ id =", 5)])
        blk = src[src.index("stone_arch_v3 = {"):]
        blk = blk[:blk.index("\n\t},")]
        cols = [([float(t) for t in m.group(1).split(",")], [float(t) for t in m.group(2).split(",")])
                for m in re.finditer(r"centre = Vector3.new\(([^)]*)\), size = Vector3.new\(([^)]*)\)", blk)]
        self.assertEqual(len(cols), 30)
        parts = self.plan["prefabs"]["CliffTunnelCollar"]["parts"]
        stone = [q for q in parts if q[11] == "Sandstone"]
        frames = [(np.array(q[1:4], float), adapt.rot_yxz(*(v or 0 for v in q[7:10])), np.array(q[4:7], float) / 2)
                  for q in stone]

        def opening(x, y):
            return y > 0 and ((abs(x) < 29.5 and y <= 30) or (y > 30 and x * x + (y - 30) ** 2 < 29.8 ** 2))

        for q, (c, rot, h) in zip(stone, frames):
            for sx in (-1, 1):
                for sy in (-1, 1):
                    for sz in (-1, 1):
                        x, y, _ = c + rot @ (h * [sx, sy, sz])
                        self.assertFalse(opening(x, y), f"collar stone corner in the opening at {x:.1f},{y:.1f}")
                        self.assertFalse(abs(x) < 22 and y < 32.4, f"collar stone in the road corridor at {x:.1f},{y:.1f}")
        for q in parts:
            if q[11] in ("Metal", "Neon"):
                self.assertGreater(q[2] - q[5] / 2, 32.4 + 8.0, "the hanging lantern clears the corridor")

        def covered(pt):
            return any(np.all(np.abs(rot.T @ (pt - c)) <= h + 1e-6) for c, rot, h in frames)

        for (cx, cy, cz), (sx, sy, sz) in cols:
            for fx in (-0.45, 0.0, 0.45):
                for fy in np.linspace(-0.47, 0.47, 7):
                    for fz in (-0.45, 0.0, 0.45):
                        pt = np.array([cx + fx * sx, cy + fy * sy, cz + fz * sz])
                        self.assertTrue(covered(pt), f"stone_arch_v3 collider at x {cx} not inside the collar ({pt})")

    def test_landmarks_present(self):
        names = {i["pf"].split("#")[0] for i in self.plan["instances"]}
        for want in ("CliffTunnelArch", "VehicleExchangeBays", "ExchangePad_Car", "ExchangePad_Plane", "PlazaFountain",
                     "TimberDock_Long", "HarborLighthouse", "RiskyLogBridge", "StartFinishGantry", "TownHouse_A",
                     "TownHouse_B", "TownHouse_C", "PalmTree"):
            self.assertIn(want, names)
        self.assertFalse(any(k.startswith("LM_") for k in self.plan["prefabs"]))
        self.assertGreater(self.plan["terrain"]["nx"], 1)  # organic masses are the 30MAPS height grid
        self.assertEqual(len(self.plan["terrain"]["heights"]), self.plan["terrain"]["nx"] * self.plan["terrain"]["nz"])
        self.assertEqual(self.plan["terrain"]["water"]["level"], 0)

    def test_materials_resolve(self):
        variants = json.loads((ROOT / "assets" / "materials" / "hub_v1" / "variants.json").read_text())
        tex = {"T1_PLAZA_STONE", "T2_TERRACOTTA_ROOF", "T3_ISLAND_GRASS", "T4_BEACH_SAND", "T5_CLIFF_ROCK", "T6_TIMBER_DOCK"}
        for name, v in variants.items():
            self.assertTrue(name.startswith("SR_HUB_"))
            self.assertIn(v["tex"], tex)
            self.assertIn(v["base"], adapt.MATERIALS)
            self.assertGreater(v["studsPerTile"], 0)
        self.assertEqual({v["tex"] for v in variants.values()}, tex)
        mats = self.sk["materials"]
        self.assertEqual(mats["terrainColor"], "#ffffff")
        palette = {p["material"] for p in self.plan["terrain"]["palette"]}
        self.assertEqual(set(mats["terrainOverrides"]), palette)
        for base, var in mats["terrainOverrides"].items():
            self.assertEqual(variants[var]["base"], base)
        for rule in mats["partRules"]:
            v = variants[rule["variant"]]
            self.assertEqual(v["base"], rule.get("setMaterial") or rule["material"])

    def test_lighting_and_sky(self):
        src = (ROOT / "src" / "shared" / "lighting" / "hub0.luau").read_text()
        self.assertIn('["HUB-0"] = {', src)
        self.assertIn('["HUB-0-STORM"] = {', src)
        self.assertNotIn("rbxassetid", src)  # sky ids are added by the integrator after upload
        names = re.findall(r'name = "([^"]+)"', src)
        self.assertTrue(names and all(n.startswith("SkyRally_") for n in names))
        from PIL import Image
        for sub in ("", "storm/"):
            for face in ("up", "side", "down"):
                with Image.open(ROOT / "assets" / "sky" / "hub0" / f"{sub}{face}.png") as im:
                    self.assertEqual(im.size, (512, 512))

    # ---------------------------------------------------------------------------------------- provenance
    def test_plan_is_generated(self):
        """The committed plan is exactly what the author script emits (never hand-edited)."""
        import author_hub0
        plan, _ = author_hub0.build()
        self.assertEqual(json.dumps(plan, separators=(",", ":")), json.dumps(self.plan, separators=(",", ":")))

    def test_trackdata_emits(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc = adapt.main([str(PLAN_PATH), "--no-compile", "--build-dir", tmp])
            self.assertEqual(rc, 0)
            out = Path(tmp) / "TrackData.luau"
            text = out.read_text()
            self.assertIn('id = "HUB-0"', text)
            if LUNE:
                p = subprocess.run([LUNE, "run", str(fixtures.TESTS / "load_trackdata.luau"), str(out),
                                    str(len(self.route.waypoints))], capture_output=True, text=True)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
