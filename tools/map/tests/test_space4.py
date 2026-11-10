#!/usr/bin/env python3
"""SPACE-4 "Monorail Neon Grid" plan (tools/map/author_space4.py -> map/space4/plan.json): adapt gates, car-track
geometry, terrain meeting the road at grade, materials/style/lighting/sky wiring and the L4 gameplay anchors
(LAUNCH_PROGRESSION 2, 2b, 3: race + coin challenge, no key, no battle, no boss at launch).
Run: python3 -m unittest discover -s tools/map/tests -v"""
from __future__ import annotations

import hashlib
import json
import math
import re
import struct
import unittest

import numpy as np

import fixtures
import adapt
import route_geometry

ROOT = fixtures.ROOT
PLAN = ROOT / "map" / "space4" / "plan.json"
POD_TYPES = {"Red", "Blue", "Yellow", "Green", "Rainbow", "Speed"}
TEXTURES = {"T1_METAL_PLATES", "T2_NEON_ROAD", "T3_MOON_ROCK", "T4_GLASS_PANELS", "T5_BRASS_MACHINE", "T6_STONE_ARCH",
            "T7_ROAD_PANELS"}
CAR_TOP_SPEED = 128.0  # src/shared/CarConfig.luau TOP_SPEED


def car_config() -> dict[str, float]:
    """Numeric top-level constants of src/shared/CarConfig.luau (`CarConfig.KEY = <number>`)."""
    src = (ROOT / "src" / "shared" / "CarConfig.luau").read_text()
    return {m.group(1): float(m.group(2))
            for m in re.finditer(r"^CarConfig\.([A-Z0-9_]+)\s*=\s*(-?\d+(?:\.\d+)?)\b", src, re.M)}


def boosted_radius(c: dict[str, float]) -> float:
    """PAD_BOOST_SPEED / CarConfig.turnRate(PAD_BOOST_SPEED) (the boosted grip radius, ~124)."""
    v = c["PAD_BOOST_SPEED"]
    low = min(max(v / c["FULL_TURN_SPEED"], 0.0), 1.0) ** c["TURN_LOW_SPEED_EXP"]
    high_t = min(max((v - c["FULL_TURN_SPEED"]) / (c["TOP_SPEED"] - c["FULL_TURN_SPEED"]), 0.0), 1.0)
    rate = c["TURN_RATE_MAX"] * low * (1 - (1 - c["HIGH_SPEED_TURN_FACTOR"]) * high_t)
    return v / math.radians(rate)


class Walls2D:
    """Plan view of the collidable walls in a box (30MAPS B and W parts cut at one height, plus the kit/Deck Alt1 tube
    walls from the alternate's points) and the car's forward wall rays against them (CarController: three rays along
    the motion at lateral 0 and +-0.85 * HALF_WIDTH; the nearest wall face hit decides; CarConfig.classifyWallHit then
    uses |dir . normal|). Edges are labelled so a test can tell a wall's side face from its blunt end face."""

    def __init__(self, plan: dict, x_range, z_range, y: float, alt_points=None):
        self.polys = []
        prefabs = plan["prefabs"]
        for inst in plan["instances"]:
            p = np.array(inst["p"], float)
            if not (x_range[0] < p[0] < x_range[1] and z_range[0] < p[2] < z_range[1]):
                continue
            r_inst = adapt.instance_rotation(inst["r"])
            for part in prefabs[inst["pf"]]["parts"]:
                if len(part) > 12 and part[12].get("nc"):
                    continue
                if part[0] not in ("B", "W"):
                    continue
                rot = r_inst @ adapt.rot_yxz(*(v or 0 for v in part[7:10]))
                c = p + r_inst @ np.array(part[1:4], float)
                hx, hy, hz = (v / 2 for v in part[4:7])
                ext = np.abs(rot) @ np.array([hx, hy, hz])
                if not (c[1] - ext[1] < y < c[1] + ext[1]):
                    continue
                if part[0] == "B":
                    loc = [(-hx, 0, -hz), (hx, 0, -hz), (hx, 0, hz), (-hx, 0, hz)]
                    labels = ["end", "side", "end", "side"]
                else:  # wedge: right angle at (y -h/2, z +d/2), vertical prism when local x is vertical
                    loc = [(0, -hy, -hz), (0, -hy, hz), (0, hy, hz)]
                    labels = ["side", "side", "side"]
                pts = [c + rot @ np.array(v, float) for v in loc]
                self.polys.append(([np.array([q[0], q[2]]) for q in pts], labels, inst["pf"].split("#")[0]))
        for a, b in zip(alt_points or [], (alt_points or [])[1:]):
            a, b = np.array(a, float), np.array(b, float)
            d = (b - a) / np.linalg.norm(b - a)
            n = np.array([-d[2], 0.0, d[0]])
            for s in (-16.0, 16.0):  # kit/Deck tunnel walls: 6 thick at +-16, each 1 stud past its points
                q = [a - d + n * (s - 3), b + d + n * (s - 3), b + d + n * (s + 3), a - d + n * (s + 3)]
                self.polys.append(([np.array([v[0], v[2]]) for v in q], ["side", "end", "side", "end"], "Alt1Wall"))

    def cast(self, o, dv, max_d):
        best = None
        for verts, labels, name in self.polys:
            for k in range(len(verts)):
                a, b = verts[k], verts[(k + 1) % len(verts)]
                e = b - a
                den = dv[0] * -e[1] - dv[1] * -e[0]
                if abs(den) < 1e-12:
                    continue
                w = a - o
                t = (w[0] * -e[1] - w[1] * -e[0]) / den
                s = (dv[0] * w[1] - dv[1] * w[0]) / den
                if 0 <= s <= 1 and 1e-6 < t <= max_d and (best is None or t < best[0]):
                    nrm = np.array([-e[1], e[0]]) / np.linalg.norm(e)
                    best = (t, name, labels[k], abs(float(nrm @ dv)))
        return best

    def drive(self, x, z, heading, half_width, max_d):
        """First wall a car at (x, z) driving straight along the horizontal unit `heading` meets: (distance, part
        family, face, impact) or None."""
        o = np.array([x, z], float)
        dv = np.array(heading, float) / np.linalg.norm(heading)
        side = np.array([-dv[1], dv[0]])
        hits = [h for h in (self.cast(o + side * lat, dv, max_d) for lat in (0.0, 0.85 * half_width, -0.85 * half_width))
                if h]
        return min(hits, key=lambda h: h[0]) if hits else None


class Space4Plan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = json.loads(PLAN.read_text())
        cls.res = adapt.check(cls.plan)
        cls.sk = cls.plan["skyrally"]
        cls.gp = cls.sk["gameplay"]
        cls.route = cls.res.route

    # ------------------------------------------------------------------------------------------- gates
    def test_adapt_gates_pass(self):
        self.assertEqual(self.res.report.errors, [])
        self.assertLessEqual(abs(self.route.length - self.sk["route"]["targetLength"]), 1.0)
        self.assertEqual(self.sk["route"]["targetLength"], 4800)
        self.assertGreaterEqual(self.res.gates["minRadius"], 85.0)
        self.assertEqual(self.sk["route"]["radiusExceptions"], [])
        self.assertEqual(self.res.gates["corridorPartIntrusions"], 0)
        self.assertGreater(self.res.gates["collidableParts"], 0)  # the parapets are really checked
        self.assertTrue(self.sk["route"]["closed"])

    def test_identity(self):
        sk = self.sk
        self.assertEqual((sk["id"], sk["key"], sk["zone"], sk["vehicle"], sk["laps"], sk["lighting"]),
                         ("SPACE-4", "space4", "SPACE", "car", 3, "SPACE-4"))
        self.assertTrue((ROOT / sk["guide"]).is_file())

    # ------------------------------------------------------------------------------------ car geometry
    def gaps(self):
        return [(g["from"], g["to"]) for g in self.sk["deck"]["gaps"]]

    def test_car_deck_geometry(self):
        deck = self.sk["deck"]
        self.assertTrue(40 <= deck["width"] <= 48)
        self.assertEqual(deck["piersEvery"] >= 0, True)
        fl = self.sk["flight"]
        self.assertLess(fl["corridor"]["floor"], 1.6 + 0.01)  # the car drives ON the deck (top = ribbon + 1.6)
        wps = self.route.waypoints
        self.assertLessEqual(max(abs(w.bank) for w in wps), 12.0)
        for a, b in zip(wps, wps[1:]):
            if any(lo <= a.station <= hi for lo, hi in self.gaps()):
                continue
            h = math.hypot(b.pos[0] - a.pos[0], b.pos[2] - a.pos[2])
            grade = abs(math.degrees(math.atan2(b.pos[1] - a.pos[1], h)))
            self.assertLessEqual(grade, 15.0, f"grade {grade:.1f} deg at st {a.station:.0f}")

    def test_jump_is_a_short_clearable_step(self):
        (lo, hi), = self.gaps()
        self.assertLessEqual(hi - lo, 30.0)
        jump = self.sk["provenance"]["jump"]
        self.assertLess(jump["minLaunchSpeed"], CAR_TOP_SPEED * 0.8)
        lip = self.route.frame_at(jump["deckEnd"]).pos[1]
        land = self.route.frame_at(jump["deckResume"]).pos[1]
        self.assertGreater(lip - land, 3.0)  # a height step down, not a hop up
        # on a straight: heading barely changes across the kicker and landing
        t0 = self.route.frame_at(lo - 90).tangent
        t1 = self.route.frame_at(hi + 60).tangent
        self.assertGreater(t0[0] * t1[0] + t0[2] * t1[2], math.cos(math.radians(6)))

    def height(self, x, z):
        """30MAPS grid height (bilinear between nodes, as builder_template `height`)."""
        t = self.plan["terrain"]
        nx, cell, x0, z0, H = t["nx"], t["cell"], t["x0"], t["z0"], t["heights"]
        fx, fz = (x - x0) / cell, (z - z0) / cell
        ix, iz = int(math.floor(fx)), int(math.floor(fz))
        tx, tz = fx - ix, fz - iz
        k = iz * nx + ix
        a = H[k] + (H[k + 1] - H[k]) * tx
        b = H[k + nx] + (H[k + nx + 1] - H[k + nx]) * tx
        return a + (b - a) * tz

    def test_terrain_meets_road_at_grade(self):
        alt = self.gp["alternates"][0]
        skip = [(lo - 40, hi + 40) for lo, hi in self.gaps()] + [(alt["joinStation"] - 20, alt["rejoinStation"] + 20)]
        checked = 0
        st = 0.0
        while st < self.route.length:
            f = self.route.frame_at(st)
            if f.pos[1] <= 16.0 and not any(lo <= st <= hi for lo, hi in skip):
                for side in (-1, 1):
                    q = f.offset(side * 32.0, 0.0)
                    # the shelf follows the banked deck plane out to the parapet line (26.2)
                    plane = side * 26.2 * math.sin(math.radians(f.bank))
                    dy = self.height(q[0], q[2]) - f.pos[1] - plane
                    self.assertTrue(-0.5 <= dy <= 1.6, f"ground {dy:+.2f} vs banked ribbon at st {st:.0f} side {side}")
                checked += 1
            st += 25.0
        self.assertGreater(checked, 20)

    def test_no_terrain_over_the_road(self):
        """Grid terrain stays under the banked paver top (|lateral| <= 21.5) and curb top (to 25.2) everywhere off the
        jump gap, also on the low side of banked at-grade curves (CourseCarve only clears +-halfWidth above +floor)."""
        worst = -1e9
        st = 0.0
        while st < self.route.length:
            if not any(lo - 2 <= st <= hi + 2 for lo, hi in self.gaps()):
                f = self.route.frame_at(st)
                b = math.radians(f.bank)
                for k in range(-50, 51):
                    lat = k * 0.5
                    q = f.offset(lat * math.cos(b), 0.0)
                    top = f.pos[1] + lat * math.sin(b) + (2.7 if abs(lat) <= 21.5 else 3.0) * math.cos(b)
                    ex = self.height(q[0], q[2]) - top
                    worst = max(worst, ex)
                    self.assertLess(ex, -0.3, f"terrain {ex:+.2f} over the road surface at st {st:.0f} lateral {lat}")
            st += 10.0
        self.assertLess(worst, 0.0)

    def test_shortcut_forks_remountable(self):
        """Where the parapet is open toward Alt1, the curb top stays under the car's wall rays (CarConfig: ride height
        1.9 + WALL_RAY_LIFT 0.3 above its ground) seen from the cutting floor or ground beside the road, so a car
        leaving the shortcut climbs the curb as a step instead of scraping along it as a wall."""
        prov = self.sk["provenance"]
        side = 1.0 if prov["forkSide"] == "right" else -1.0
        floor_y = self.gp["alternates"][0]["points"][0][1] + 1.8  # kit Alt1Floor top
        wall_ray = 1.9 + 0.3
        for lo, hi in prov["forkOpenStretches"]:
            st = lo
            while st <= hi:
                f = self.route.frame_at(st)
                b = math.radians(f.bank)
                curb_top = f.pos[1] + side * 25.2 * math.sin(b) + 3.0 * math.cos(b)  # taller kit curb (4.4)
                q = f.offset(side * 30.0, 0.0)
                ground = min(self.height(q[0], q[2]), floor_y)
                self.assertLess(curb_top - ground, wall_ray - 0.2,
                                f"curb {curb_top - ground:.2f} over the ground at fork st {st:.0f}")
                st += 4.0

    # ---------------------------------------------------------------------------------------- gameplay
    def test_checkpoints(self):
        sts = self.gp["checkpoints"]["stations"]
        alt = self.gp["alternates"][0]
        self.assertEqual(sts[0], 0)
        self.assertEqual(sts, sorted(sts))
        self.assertTrue(all(0 <= s < self.route.length for s in sts))
        for a, b in zip(sts, sts[1:] + [self.route.length]):
            if a <= alt["joinStation"] and b >= alt["rejoinStation"]:
                continue  # no checkpoint can sit on both the bulge and the Alt1 tunnel
            self.assertLessEqual(b - a, 450.0, (a, b))
        for s in sts:
            self.assertFalse(alt["joinStation"] < s < alt["rejoinStation"], s)
            self.assertFalse(any(lo - 25 <= s <= hi + 25 for lo, hi in self.gaps()), s)

    def test_rings_pads_pods(self):
        rings, pads, pods = self.gp["rings"], self.gp["pads"], self.gp["pods"]
        self.assertTrue(6 <= len(rings) <= 10)
        self.assertTrue(2 <= len(pads) <= 4)
        self.assertEqual(len([p for p in pods if p["type"] != "Speed"]), 40)  # cubes v3: 8 staggered sets of 2 + 3
        names = [x["name"] for x in rings + pads + pods]
        self.assertEqual(len(names), len(set(names)))
        for r in rings + pads:
            self.assertFalse(any(lo - 5 <= r["station"] <= hi + 5 for lo, hi in self.gaps()), r["name"])
            self.assertLessEqual(abs(r["lateral"]), 12.0)  # on the drive line
        self.assertTrue({p["type"] for p in pods} <= POD_TYPES)
        self.assertEqual({p["type"] for p in pods}, POD_TYPES)
        for p in pods:
            self.assertTrue(abs(p["lateral"]) <= 16.0, p["name"])  # across the road (back rank -12/0/+12), still on it

    def test_coins(self):
        coins = self.gp["coins"]
        self.assertEqual(len(coins), 8)
        self.assertEqual(sorted(c["id"] for c in coins), list(range(1, 9)))
        self.assertTrue(all(0 <= c["station"] < self.route.length for c in coins))
        on_alt = [c for c in coins if c.get("line") == "Alt1"]
        self.assertGreaterEqual(len(on_alt), 1)
        pts = self.gp["alternates"][0]["points"]
        for c in on_alt:
            d = min(math.dist(c["pos"], p) for p in pts)
            self.assertLess(d, 20.0)
            f = self.route.frame_at(c["station"])
            q = f.offset(c["lateral"], c["height"])
            self.assertLess(math.dist(q, c["pos"]), 3.0)  # station/lateral/height describe the same point
        for c in coins:
            if c.get("line") == "main":
                self.assertLessEqual(abs(c["lateral"]), 16.0)

    def test_alternate_generated_from_route_frames(self):
        alts = self.gp["alternates"]
        self.assertEqual([a["id"] for a in alts], ["Alt1", "Alt2"])  # Alt2 is the rooftop line (test_rooftop_*)
        alt = alts[0]
        self.assertEqual((alt["id"], alt["style"]), ("Alt1", "tunnel"))
        self.assertLess(alt["joinStation"], alt["rejoinStation"])
        a = self.route.frame_at(alt["joinStation"]).pos
        b = self.route.frame_at(alt["rejoinStation"]).pos
        ab = (b[0] - a[0], b[2] - a[2])
        L = math.hypot(*ab)
        for p in alt["points"]:  # on the chord between the join and rejoin frames (both ends on the race line)
            rel = (p[0] - a[0], p[2] - a[2])
            off = abs(rel[0] * ab[1] - rel[1] * ab[0]) / L
            self.assertLess(off, 1.0)
        prov = self.sk["provenance"]
        self.assertTrue(prov["forkOpenStretches"])  # parapets open where the shortcut leaves and rejoins

    def test_no_key_battle_or_boss_on_space4(self):
        self.assertIsNone(self.gp["key"])
        self.assertEqual(self.gp["modes"], {})
        self.assertIsNone(self.gp["boss"])

    def test_start_grid_and_finish(self):
        sg, fin = self.gp["startGrid"], self.gp["finish"]
        self.assertEqual(fin["station"], 0)
        self.assertEqual(sg["station"] + 3 * sg["rowSpacing"] < min(r["station"] for r in self.gp["rings"]), True)

    # ------------------------------------------------------------------- trap audit fixes (traps_space4.md)
    def chord(self):
        """Alt1 chord frame: origin at the join frame, `along` toward the rejoin, `north` = lateral away from the bulge
        road (the side the shortcut is on)."""
        alt = self.gp["alternates"][0]
        a = self.route.frame_at(alt["joinStation"]).pos
        b = self.route.frame_at(alt["rejoinStation"]).pos
        along = np.array([b[0] - a[0], b[2] - a[2]])
        along /= np.linalg.norm(along)
        north = np.array([-along[1], along[0]])
        mid = self.route.frame_at((alt["joinStation"] + alt["rejoinStation"]) / 2).pos
        if north @ np.array([mid[0] - a[0], mid[2] - a[2]]) > 0:
            north = -north
        o = np.array([a[0], a[2]])

        def uv(p):
            q = np.array([p[0], p[2]]) - o
            return float(q @ along), float(q @ north)

        def xz(u, v):
            return o + along * u + north * v

        return uv, xz, along, north

    def apron_walls(self):
        alt = self.gp["alternates"][0]
        y = alt["points"][0][1] + 1.8 + 1.9 + 0.3  # tube floor top + ride height + WALL_RAY_LIFT
        xs = [p[0] for p in alt["points"]]
        return Walls2D(self.plan, (min(xs) - 260, max(xs) + 260), (7300, 8000), y, alt["points"])

    def test_s4_04_fork_openings_only_into_the_apron(self):
        """S4-04: the parapet facing the shortcut is open only while its line runs inside the Alt1 apron (no further
        toward the bulge than the tube wall's outer face), not along the inner-bulge shelf that drops into the basin
        (the old openings ran to 3479.7 and from 3818.7)."""
        prov = self.sk["provenance"]
        uv, _, _, _ = self.chord()
        side = 1.0 if prov["forkSide"] == "right" else -1.0
        band = prov["forkOpenBand"]
        self.assertLessEqual(band, 19.0)
        (a1, b1), (a2, b2) = prov["forkOpenStretches"]
        self.assertLessEqual(b1, 3440.0)
        self.assertGreaterEqual(a2, 3860.0)
        for lo, hi in prov["forkOpenStretches"]:
            st = lo
            while st <= hi:
                _, v = uv(self.route.frame_at(st).offset(side * 26.2, 0.0))
                self.assertGreater(v, -band - 0.5, f"open parapet line at st {st:.0f} is {-v:.1f} toward the bulge")
                st += 2.0

    def test_s4_01_s4_03_funnel_rails_close_both_aprons(self):
        """S4-01/S4-03: four ShortcutFunnelRail lines close the entry and exit aprons from the fork parapet ends to
        the kit tube walls at shallow angles; their tube ends sit in the walls with the inner face at the tube's."""
        prov = self.sk["provenance"]
        rails = prov["funnelRails"]
        self.assertEqual(set(rails), {"entryNorth", "entrySouth", "exitNorth", "exitSouth"})
        uv, _, _, _ = self.chord()
        pts = self.gp["alternates"][0]["points"]
        u_first, u_last = uv(pts[0])[0], uv(pts[-1])[0]
        for name, r in rails.items():
            self.assertLess(r["angleDeg"], 7.0, name)  # impact sin(7) = 0.12 << WALL_SHALLOW_DOT 0.42: a deflect
            tube_end = r["to"] if name.startswith("entry") else r["from"]
            u, v = uv(tube_end)
            if name.startswith("entry"):
                self.assertTrue(u_first - 1 < u <= u_first + 1.01, (name, u, u_first))
                self.assertTrue(13.4 <= abs(v) <= 13.7, (name, v))  # inner face 12.4-12.7: shadows the wall ends
            else:
                self.assertTrue(u_last - 1.01 <= u < u_last + 1, (name, u, u_last))
                self.assertAlmostEqual(abs(v), 14.0, places=1)  # inner face flush with the wall's (13)
            self.assertEqual(v > 0, name.endswith("North"), name)
        # every rail line is really built: samples every 2 studs lie on a ShortcutFunnelRail piece's centre line
        segs = []
        for inst in self.plan["instances"]:
            key = inst["pf"]
            if not key.startswith("ShortcutFunnelRail#") or not re.match(r"^ShortcutFunnelRail#[\d.]+$", key):
                continue
            length = float(key.split("#")[1])
            look = adapt.instance_rotation(inst["r"]) @ np.array([0.0, 0.0, -1.0])
            c = np.array(inst["p"], float)
            segs.append((c - look * length / 2, c + look * length / 2))
        self.assertEqual(len(segs), prov["funnelRailPieces"])
        for name, r in rails.items():
            a, b = np.array(r["from"]), np.array(r["to"])
            n = int(np.linalg.norm(b - a) // 2)
            for k in range(n + 1):
                q = a + (b - a) * k / n
                d = min(np.linalg.norm(np.cross(q - s0, (s1 - s0) / np.linalg.norm(s1 - s0)))
                        for s0, s1 in segs
                        if -0.2 <= (q - s0) @ (s1 - s0) / np.linalg.norm(s1 - s0) <= np.linalg.norm(s1 - s0) + 0.2)
                self.assertLess(d, 0.3, f"{name}: no rail piece at sample {k}")
        self.assertIn("ShortcutFunnelRail#gore", self.plan["prefabs"])

    def test_s4_01_tunnel_mouth_has_no_head_on_face(self):
        """S4-01: driving straight at the Alt1 entry from anywhere across the apron (60 studs in from the fork, the
        old audit probe P01 lines and wider), a car meets only rail or tube wall SIDE faces at a deflect angle, or rolls
        straight through; off-line arrivals at the entry gore meet a face at a bump angle at worst, never a blunt end
        (the old mouth was a flat face plus wall and portal ends: a 0.9 s spin at boost speed)."""
        c = car_config()
        uv, xz, along, north = self.chord()
        walls = self.apron_walls()
        hw = c["HALF_WIDTH"]
        for deg in (0.0, 8.0, -8.0, -25.0):
            t = math.radians(deg)
            heading = along * math.cos(t) + north * math.sin(t)
            for v0 in range(-25, 19):
                x, z = xz(60.0, float(v0))
                hit = walls.drive(x, z, heading, hw, 300.0)
                if hit is None:
                    continue
                _, fam, face, impact = hit
                self.assertEqual(face, "side", f"heading {deg:+.0f} lateral {v0}: hits the end of a {fam}")
                self.assertLess(impact, c["WALL_SPIN_DOT"], f"heading {deg:+.0f} lateral {v0}: {fam} at {impact:.2f}")
                funnel = (deg == 0.0 and -15 <= v0) or (deg == 8.0 and -15 <= v0) or (deg == -8.0 and -5 <= v0)
                if funnel:  # lined up anywhere near the hole: always a deflect into the tube
                    self.assertLess(impact, c["WALL_SHALLOW_DOT"],
                                    f"heading {deg:+.0f} lateral {v0}: {fam} {face} at {impact:.2f}")

    def test_s4_03_tube_exit_reaches_the_road(self):
        """S4-03: leaving the tube anywhere across it with a drift up to 6 degrees either way, the car meets only
        shallow rail or parapet faces (no blunt parapet nose, no gap onto the strip outside the right parapet); with a
        10 degree drift it still never meets an end face or a spin angle."""
        c = car_config()
        uv, xz, along, north = self.chord()
        walls = self.apron_walls()
        u_last = uv(self.gp["alternates"][0]["points"][-1])[0]
        for deg in (0.0, 3.0, -3.0, 6.0, -6.0, 10.0, -10.0):
            t = math.radians(deg)
            heading = along * math.cos(t) + north * math.sin(t)
            for v0 in range(-9, 10):
                x, z = xz(u_last - 5.0, float(v0))
                hit = walls.drive(x, z, heading, c["HALF_WIDTH"], 260.0)
                if hit is not None:
                    self.assertEqual(hit[2], "side", (deg, v0, hit))
                    self.assertLess(hit[3], c["WALL_SHALLOW_DOT"] if abs(deg) <= 6 else c["WALL_SPIN_DOT"],
                                    (deg, v0, hit))

    def test_s4_03_rift_landing_parapet_noses_flare(self):
        """S4-03: past the rift gap each parapet starts with a nose flared 15 degrees outward, so a car landing on the
        curb slides back in instead of meeting a blunt end head-on."""
        c = car_config()
        jump = self.sk["provenance"]["jump"]
        f = self.route.frame_at(jump["deckResume"])
        walls = Walls2D(self.plan, (f.pos[0] - 120, f.pos[0] + 120), (f.pos[2] - 120, f.pos[2] + 120),
                        f.pos[1] + 2.2)
        heading = (f.tangent[0], f.tangent[2])
        for side in (-1.0, 1.0):
            for lat in np.arange(23.0, 25.6, 0.5):  # car centre; its outer wall ray reaches the parapet face
                q = f.offset(side * lat, 0.0)
                hit = walls.drive(q[0], q[2], heading, c["HALF_WIDTH"], 60.0)
                self.assertIsNotNone(hit, lat)  # the parapet is there
                self.assertEqual(hit[2], "side", (side, lat, hit))
                self.assertLess(hit[3], c["WALL_SHALLOW_DOT"], (side, lat, hit))

    def test_x07_boost_windows(self):
        """X-07 / S4-06: no boost window (boost distance + 60) runs into a bend tighter than the boosted grip radius,
        except BoostGate_CraterRun, whose straight line runs down the Alt1 chord into the tube (a no-input car takes the
        shortcut, it cannot reach the S4-04 basin), and whose tight bulge stretches on the road have the fork opening
        into the sealed apron (bulge1, left-hander) or a continuous parapet (bulge2) on their outer side."""
        c = car_config()
        rb = boosted_radius(c)
        span = c["PAD_BOOST_SPEED"] * c["PAD_BOOST_DURATION"] + 60.0
        rows, _ = route_geometry.analyse([list(w.pos) for w in self.route.waypoints], step=5, base=20)
        L = self.route.length
        names = []
        for b in self.gp["rings"] + self.gp["pads"]:
            win = [r for r in rows if (r["st"] - b["station"]) % L <= span]
            tight = [r for r in win if r["r"] < rb]
            names.append(b["name"])
            if b["name"] != "BoostGate_CraterRun":
                self.assertEqual(tight, [], f"{b['name']} boosts into R {min(r['r'] for r in win):.0f} < {rb:.0f}")
                continue
            prov = self.sk["provenance"]
            (o1a, o1b), _ = prov["forkOpenStretches"]
            alt_side = 1.0 if prov["forkSide"] == "right" else -1.0
            for r in tight:
                st = r["st"]
                fa, fb = self.route.frame_at(st - 10), self.route.frame_at(st + 10)
                outer = -1.0 if (fb.tangent[0] * fa.right[0] + fb.tangent[2] * fa.right[2]) > 0 else 1.0
                self.assertFalse(any(lo - 5 <= st <= hi + 5 for lo, hi in self.gaps()), r)
                if any(lo <= st <= hi for lo, hi in prov["forkOpenStretches"]):
                    self.assertEqual(outer, alt_side, r)  # running wide there leaves into the funnel apron
            uv, _, _, _ = self.chord()
            f = self.route.frame_at(b["station"])
            u0, v0 = uv(f.pos)
            u1, v1 = uv((f.pos[0] + f.tangent[0], 0, f.pos[2] + f.tangent[2]))
            pts = self.gp["alternates"][0]["points"]
            for p in (pts[0], pts[-1]):
                u = uv(p)[0]
                v = v0 + (v1 - v0) * (u - u0) / (u1 - u0)
                self.assertLess(abs(v) + c["HALF_WIDTH"], 13.0, f"straight line {v:+.1f} off the tube axis at u {u:.0f}")
        self.assertNotIn("GroundBoost_DowntownEntry", names)  # S4-06: the pad moved out of north1 (city1 boost)

    def test_s4_07_no_coin_on_the_start_grid(self):
        """S4-07: no coin lies within the car coin radius (CoinChallenge RADIUS_CAR 10) of any grid slot plus margin;
        coin 1 sat 3.6 studs from slot 8 and was collected during the countdown."""
        sg = self.gp["startGrid"]
        slots = []
        for k in range(1, adapt.GRID_SLOTS + 1):
            st, lat = adapt.grid_slot(sg, k)
            slots.append(self.route.frame_at(st).offset(lat, sg["height"]))
        for coin in self.gp["coins"]:
            pos = coin.get("pos") or self.route.frame_at(coin["station"]).offset(coin["lateral"], coin["height"])
            d = min(math.dist(pos, s) for s in slots)
            self.assertGreater(d, 25.0, f"coin {coin['id']} is {d:.1f} from a grid slot")

    # ------------------------------------------------------------------------------ art wiring and assets
    def test_landmarks_named_and_collision_limited(self):
        families = {k.split("#")[0] for k in self.plan["prefabs"]}
        for name in ("MonorailViaductPier", "MonorailViaductSpan", "MonorailTrain", "GlassVaultRib", "StarSpireTower",
                     "HighwayParapet", "Streetlamp_Sodium", "Streetlamp_Cyan", "MesaTunnelPortal", "MonorailStation"):
            self.assertIn(name, families)
        self.assertFalse(any(k.startswith("LM_") for k in self.plan["prefabs"]))
        collidable = set()
        for key, pf in self.plan["prefabs"].items():
            for p in pf["parts"]:
                if not (len(p) > 12 and p[12].get("nc")):
                    collidable.add(key.split("#")[0])
        # RooftopDeck and RooftopWall are the sig-space4 rooftop line's slabs and walls (everything else there is nc)
        self.assertEqual(collidable, {"HighwayParapet", "MesaTunnelPortal", "ShortcutFunnelRail", "RooftopDeck",
                                      "RooftopWall"})

    def test_materials_variants_style_lighting(self):
        variants = json.loads((ROOT / "assets" / "materials" / "space_v1" / "variants.json").read_text())
        for name, v in variants.items():
            self.assertTrue(name.startswith("SR_SPACE_"), name)
            self.assertIn(v["tex"], TEXTURES)
            self.assertIn(v["base"], adapt.MATERIALS)
            self.assertGreater(v["studsPerTile"], 0)
        self.assertEqual({v["tex"] for v in variants.values()}, TEXTURES)
        m = self.sk["materials"]
        self.assertEqual(m["terrainColor"], "#ffffff")
        for base, var in m["terrainOverrides"].items():
            self.assertEqual(variants[var]["base"], base)
        pal = {p["material"] for p in self.plan["terrain"]["palette"]}
        self.assertEqual(pal, set(m["terrainOverrides"]))
        for r in m["partRules"]:
            mat = r.get("setMaterial") or r.get("material")
            self.assertEqual(variants[r["variant"]]["base"], mat, r)
        style = (ROOT / "src" / "server" / "kit" / "styles" / "space4.luau").read_text()
        self.assertRegex(style, r"\b%s\s*=" % re.escape(self.sk["deck"]["style"]))
        light = (ROOT / "src" / "shared" / "lighting" / "space4.luau").read_text()
        self.assertIn('["%s"]' % self.sk["lighting"], light)
        self.assertNotIn("rbxassetid", light)  # sky ids come later from the integrator

    def test_sky_faces(self):
        """L61 night sky: 1024 cube faces (up/side/down plus the planet and earthface side faces), the 512 earth disc,
        all uploaded with their current bytes, and the profile's skyFaces/skyProps images exist in the sky module."""
        sky = ROOT / "assets" / "sky" / "space4"
        uploaded = json.loads((sky / "uploaded.json").read_text())
        for name, size in (("up", 1024), ("side", 1024), ("down", 1024), ("planet", 1024), ("earthface", 1024),
                           ("earth", 512)):
            raw = (sky / f"{name}.png").read_bytes()
            self.assertEqual(raw[:8], b"\x89PNG\r\n\x1a\n")
            w, h = struct.unpack(">II", raw[16:24])
            self.assertEqual((w, h), (size, size), name)
            self.assertEqual(uploaded[name]["sha256"], hashlib.sha256(raw).hexdigest(), f"{name}.png changed: re-upload")
        module = (ROOT / "src" / "shared" / "sky" / "space4.luau").read_text()
        light = (ROOT / "src" / "shared" / "lighting" / "space4.luau").read_text()
        for image in re.findall(r'(?:Ft|Bk|Lf|Rt) = "(\w+)"', light):
            self.assertRegex(module, r"\b%s = \"rbxassetid://\d+\"" % image)

    def test_set_dressing(self):
        """L61 set dressing: uploaded SPACE props only, a few hundred placements, scale 0.8-1.3, snapped, every whole
        AABB clear of the compile gate's corridor boxes, none inside the Alt1 aprons or under the viaduct."""
        import author_space4 as A
        lib = A.prop_library()
        sd = self.sk["setDressing"]
        self.assertTrue(150 <= len(sd) <= 600, len(sd))
        self.assertGreaterEqual(len({d["key"] for d in sd}), 7)
        _, dbg = A.build()
        route = dbg["route"]
        boxes = []
        for d in sd:
            self.assertIn(d["key"], lib)
            self.assertTrue(0.8 <= d["scale"] <= 1.3, d)
            self.assertIs(d["snap"], True)
            boxes.append(A.prop_aabb(lib[d["key"]], d["pos"], d["yaw"], d["scale"]))
            self.assertGreater(abs(d["pos"][2] - dbg["z_v"]), 18.0, d)
        hits = A.corridor_hits(route.waypoints, np.array([b[0] for b in boxes]), np.array([b[1] for b in boxes]),
                               A.PROP_MARGIN)
        self.assertFalse(hits.any(), [sd[i] for i in np.nonzero(hits)[0][:5]])
        fx = self.sk["fx"]
        self.assertLessEqual(sum(1 for f in fx if f["class"] == "PointLight"), 60)
        self.assertTrue(any(f["class"] == "Beam" for f in fx))

    # ------------------------------------------------------------------------------------ space-neon pass
    def plan_dist_to_route(self, x: float, z: float) -> float:
        pts = np.array([[w.pos[0], w.pos[2]] for w in self.route.waypoints])
        a, b = pts, np.roll(pts, -1, axis=0)
        ab = b - a
        t = np.clip(np.einsum("ij,ij->i", np.array([x, z]) - a, ab) / np.maximum(1e-9, np.einsum("ij,ij->i", ab, ab)), 0, 1)
        q = a + ab * t[:, None]
        return float(np.min(np.hypot(q[:, 0] - x, q[:, 1] - z)))

    def test_space_neon_holograms_clear_of_the_road(self):
        """Figures are visual only and stand where even a leaning head and swinging hand stay HOLO_CLEAR from the road
        axis (shared/SpaceNeonRules.reach, spec'd in tools/tests/space_neon_spec.luau with the same constants)."""
        neon = self.sk["provenance"]["spaceNeon"]
        k_lean, k_arm, clear = 0.6, 0.26, 180.0  # v29 W1b A8: HOLO_CLEAR 55 -> 180
        rules = (ROOT / "src" / "shared" / "SpaceNeonRules.luau").read_text()
        for name, val in (("HOLO_K_LEAN", k_lean), ("HOLO_K_ARM", k_arm), ("HOLO_CLEAR", clear)):
            self.assertRegex(rules, r"Rules\.%s = %g\b" % (name, val))
        holos = neon["holograms"]
        self.assertGreaterEqual(len(holos), 3)
        self.assertLessEqual(len(holos), 6)
        wall_lateral = 26.2  # parapet centre
        for h in holos:
            self.assertTrue(40 <= h["h"] <= 60, h)  # v29 A8: capped at 60 (was 80-150)
            reach = h["h"] * (k_lean * math.sin(math.radians(h["lean"])) + k_arm)
            d = self.plan_dist_to_route(h["pos"][0], h["pos"][2])
            self.assertGreaterEqual(d - reach, clear - 0.5, h)
            self.assertGreater(d - reach, wall_lateral + 20, h)  # clear of the parapets by a wide margin
        for a in holos:
            for b in holos:
                if a is not b:
                    self.assertGreater(math.hypot(a["pos"][0] - b["pos"][0], a["pos"][2] - b["pos"][2]), 200)
        # Alt1 tunnel: the shortcut chord
        alt = np.array(self.sk["gameplay"]["alternates"][0]["points"])
        for h in holos:
            dm = float(np.min(np.hypot(alt[:, 0] - h["pos"][0], alt[:, 2] - h["pos"][2])))
            self.assertGreater(dm, 60, h)

    def test_space_neon_billboards_float_clear(self):
        neon = self.sk["provenance"]["spaceNeon"]
        boards = neon["billboards"]
        self.assertGreaterEqual(len(boards), 3)
        for b in boards:
            d = self.plan_dist_to_route(b["pos"][0], b["pos"][2])
            half_w = b["w"] / 2
            # the panel is toed in 28 degrees: its nearest plan-view edge is still well outside the parapets
            self.assertGreater(d - half_w * math.cos(math.radians(28)), 26.2 + 20, b)
            self.assertGreater(b["lateral"], 90)

    def test_space_neon_road_pass_is_nc_and_budgeted(self):
        neon = self.sk["provenance"]["spaceNeon"]
        self.assertLessEqual(neon["mapParts"], 900)  # part budget of the road pass (strips, rungs, chevrons, arches)
        self.assertLessEqual(neon["lightArchLights"], 12)  # MapLight budget (client/LightLod keeps the nearest K)
        for key, pf in self.plan["prefabs"].items():
            if key.startswith("Tron"):
                for prt in pf["parts"]:
                    self.assertTrue(len(prt) > 12 and prt[12].get("nc"), (key, prt))  # visual only
                    # v29 W1b A10: edge strips and rungs are flush brass plates (Metal); chevrons and arches stay Neon
                    self.assertEqual(prt[11], "Metal" if key.startswith(("TronEdge", "TronGridRung")) else "Neon", key)
        st = neon["lightArches"]
        self.assertTrue(all(abs(a - b) >= 72 for a, b in zip(st, st[1:])))

    def test_space_neon_layout_file_matches_plan(self):
        neon = self.sk["provenance"]["spaceNeon"]
        src = (ROOT / "src" / "shared" / "SpaceNeonLayout.luau").read_text()
        self.assertEqual(src.count("palette = "), len(neon["holograms"]) + len(neon["billboards"]))
        for h in neon["holograms"]:
            self.assertIn("Vector3.new(%g, %g, %g)" % tuple(h["pos"]), src)
        for b in neon["billboards"]:
            self.assertIn("Vector3.new(%g, %g, %g)" % tuple(b["pos"]), src)

    # ------------------------------------------------------------------------------------ Wave 2 landmarks
    def family_instances(self, prefix: str) -> list[dict]:
        return [i for i in self.plan["instances"] if i["pf"].split("#")[0].startswith(prefix)]

    def test_w2_landmarks_are_visual_only(self):
        """Critic v29 2.1/2.2: the downtown viaduct, its MonorailSlot and the gate portal frames are nc (DecorQuery then
        clears CanQuery on every visible part); nothing collidable was added, so walls, barriers and the corridor are
        unchanged (test_landmarks_named_and_collision_limited holds the collidable family list). No Neon except the
        lantern lenses (ART_BAR: no straight neon strips)."""
        keys = [k for k in self.plan["prefabs"] if k.startswith(("DowntownViaduct", "GatePortalFrame", "MonorailSlot"))]
        self.assertTrue(keys)
        for k in keys:
            for prt in self.plan["prefabs"][k]["parts"]:
                self.assertTrue(len(prt) > 12 and prt[12].get("nc"), (k, prt))
                if prt[11] == "Neon":
                    self.assertIn("l", prt[12], (k, prt))
                    self.assertLessEqual(max(prt[4], prt[5], prt[6]), 2.0, (k, prt))

    def test_w2_viaduct_clears_road_camera_and_parapets(self):
        """Every viaduct part, treated as if it collided, stays out of a corridor box raised to 30 studs (the chase camera
        rides ~10 over the ribbon); the pier footings stand outside the parapets' outer face (27.2) on both sides; the
        gateways span DT_FROM..DT_TO, clear of the other viaduct's crossings, with no skyway arch inside the arcade."""
        import author_space4 as A
        sub = {"prefabs": {}, "instances": []}
        for i in self.family_instances("DowntownViaduct"):
            pf = json.loads(json.dumps(self.plan["prefabs"][i["pf"]]))
            for prt in pf["parts"]:
                prt[12] = {k: v for k, v in prt[12].items() if k != "nc"}
            sub["prefabs"][i["pf"]] = pf
            sub["instances"].append(i)
        self.assertGreater(len(sub["instances"]), 40)
        cor = dict(self.sk["flight"]["corridor"], ceiling=30)
        res = adapt.corridor_gate(sub, {"flight": {"corridor": cor}}, self.route, adapt.Report())
        self.assertEqual(res["corridorPartIntrusions"], 0, res["intrusions"][:3])
        for i in self.family_instances("DowntownViaductShaft"):
            d = self.plan_dist_to_route(i["p"][0], i["p"][2])
            self.assertGreaterEqual(d - (A.DT_PIER_W + 3.2) / 2, A.WALL_LATERAL + A.WALL_THICK / 2 + 1.0, i)
        dv = self.sk["provenance"]["downtownViaduct"]
        self.assertEqual(dv["stations"][0], A.DT_FROM)
        self.assertEqual(dv["stations"][-1], A.DT_TO)
        self.assertGreaterEqual(dv["clearances"]["intradosOverRoadEdgeMin"], 30.0)
        self.assertEqual(len(self.family_instances("DowntownViaductShaft")), 2 * dv["gateways"])
        for st in self.sk["provenance"]["skywayArches"]:
            self.assertFalse(A.DT_FROM - 30 <= st <= A.DT_TO + 30, st)
        for st in self.sk["provenance"]["viaductCrossings"]:
            self.assertGreater(min(abs(st - A.DT_FROM), abs(st - A.DT_TO)), 100.0)
        self.assertLessEqual(dv["lanterns"], 7)  # MapLight budget (client/LightLod keeps the nearest K)

    def test_w2_monorail_slot_is_an_invisible_placeholder(self):
        import author_space4 as A
        slots = self.family_instances("MonorailSlot")
        self.assertEqual(len(slots), 1)
        self.assertEqual(self.plan["groups"][slots[0]["g"] - 1], "Landmarks/DowntownViaduct")
        for prt in self.plan["prefabs"]["MonorailSlot"]["parts"]:
            self.assertEqual(prt[12].get("a"), 1)
            self.assertNotIn("l", prt[12])
        f = self.route.frame_at(A.DT_SLOT_STATION)
        self.assertAlmostEqual(slots[0]["p"][1] - f.pos[1], A.DT_BEAM_TOP, delta=1.0)
        self.assertIn({"path": "Landmarks/DowntownViaduct/MonorailSlot",
                       "attrs": {"Placeholder": True, "SlotFor": "MonorailTrain3Car", "Wave": "W2-2.2"}},
                      self.sk["modelAttributes"])

    def test_w2_gate_portal_frames_coaxial_with_the_rings(self):
        """One frame per boost gate on the ring's own CFrame (from build/space4/TrackData.luau), every part outside the
        ring housing and clasps (radius 15.1), so the frame never covers the opening the car drives through."""
        td = (ROOT / "build" / "space4" / "TrackData.luau").read_text()
        frames = self.family_instances("GatePortalFrame")
        rings = self.gp["rings"]
        self.assertEqual(len(frames), len(rings))
        for r, fr in zip(rings, frames):
            m = re.search(r'name = "%s".*?cf = CFrame\.new\(([^)]*)\)' % re.escape(r["name"]), td, re.S)
            v = [float(x) for x in m.group(1).split(",")]
            self.assertTrue(np.allclose(v[:3], fr["p"], atol=1e-3), r["name"])
            self.assertTrue(np.allclose(np.array(v[3:]).reshape(3, 3), adapt.instance_rotation(fr["r"]), atol=1e-3),
                            r["name"])
            self.assertEqual(self.plan["groups"][fr["g"] - 1], "Highway/Gantries/GatePortals")
        keys = [k for k in self.plan["prefabs"] if k.startswith("GatePortalFrame")]
        self.assertEqual(len(keys), 3)
        for k in keys:
            for prt in self.plan["prefabs"][k]["parts"]:
                radial = math.hypot(prt[1], prt[2]) - prt[5] / 2
                self.assertGreaterEqual(radial, 15.2, (k, prt))
        # no low frame part (bottom under 9 over the ribbon: car and chase camera height) stands within 6 studs
        # laterally of another gate's line within 40 studs of travel: the offset start pair opens its inner side
        for r, fr in zip(rings, frames):
            for prt in self.plan["prefabs"][fr["pf"]]["parts"]:
                c, sn = abs(math.cos(math.radians(prt[9]))), abs(math.sin(math.radians(prt[9])))
                hx, hy = 0.5 * (prt[4] * c + prt[5] * sn), 0.5 * (prt[4] * sn + prt[5] * c)
                if r["height"] + prt[2] - hy >= 9.0:
                    continue
                lat = r["lateral"] + prt[1]
                for o in rings:
                    if o is not r and abs(o["station"] - r["station"]) < 40.0:
                        self.assertGreater(abs(lat - o["lateral"]) - hx, 6.0, (r["name"], o["name"], prt))

    def test_plan_is_author_output(self):
        import author_space4
        plan, _ = author_space4.build()
        self.assertEqual(json.dumps(plan, indent=1, sort_keys=False) + "\n", PLAN.read_text())


if __name__ == "__main__":
    unittest.main()
