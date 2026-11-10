#!/usr/bin/env python3
"""SPACE-4 rooftop wall-climb shortcut (sig-space4; TRACK_VARIETY 5a, SPACE-4 launch upgrade): the line is plain
collidable slabs and walls, steeper than a road but never in the wall class of the existing car physics, it rejoins the
course through slip lanes, counts as a course line (Alt2, style span), and everything else on the map stays as it was
(gameplay anchors, terrain, neon strips, holograms) except what had to make room for it.
Run: python3 -m unittest discover -s tools/map/tests -v"""
from __future__ import annotations

import json
import math
import re
import unittest

import numpy as np

import fixtures
import adapt
import test_space4 as t4

ROOT = fixtures.ROOT
PLAN = ROOT / "map" / "space4" / "plan.json"
STEP = 6.0


def rot_of(inst: dict) -> np.ndarray:
    return adapt.instance_rotation(inst["r"])


def obb_overlap(c1, r1, h1, c2, r2, h2, eps=1e-6) -> bool:
    """3D separating-axis test of two oriented boxes (centres, rotation matrices, half extents)."""
    axes = [r1[:, i] for i in range(3)] + [r2[:, i] for i in range(3)]
    axes += [np.cross(r1[:, i], r2[:, j]) for i in range(3) for j in range(3)]
    d = c2 - c1
    for a in axes:
        n = np.linalg.norm(a)
        if n < 1e-9:
            continue
        a = a / n
        ra = sum(h1[i] * abs(a @ r1[:, i]) for i in range(3))
        rb = sum(h2[i] * abs(a @ r2[:, i]) for i in range(3))
        if abs(d @ a) > ra + rb - eps:
            return False
    return True


class Space4Rooftop(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = json.loads(PLAN.read_text())
        cls.res = adapt.check(cls.plan)
        cls.sk = cls.plan["skyrally"]
        cls.gp = cls.sk["gameplay"]
        cls.route = cls.res.route
        cls.prov = cls.sk["provenance"]["rooftopShortcut"]
        cls.cfg = t4.car_config()
        cls.insts = [(i, inst) for i, inst in enumerate(cls.plan["instances"])]

    # ------------------------------------------------------------------------------------------ helpers
    def family(self, inst) -> str:
        return inst["pf"].split("#")[0]

    def pieces(self, fam: str):
        """(centre, rotation, half extents (x, y, z), part) of every collidable part of a family, in plan order."""
        out = []
        for _, inst in self.insts:
            if self.family(inst) != fam:
                continue
            r = rot_of(inst)
            p = np.array(inst["p"], float)
            for part in self.plan["prefabs"][inst["pf"]]["parts"]:
                if len(part) > 12 and part[12].get("nc"):
                    continue
                rp = r @ adapt.rot_yxz(*(v or 0 for v in part[7:10]))
                out.append((p + r @ np.array(part[1:4], float), rp, np.array(part[4:7], float) / 2, part))
        return out

    def deck_chain(self):
        """Top-face centre line of the deck slabs in plan order: [(a, b, pitch_deg, normal)] with a/b the world ends of
        each slab's top-face axis."""
        out = []
        for c, rp, h, part in self.pieces("RooftopDeck"):
            fwd = -rp[:, 2]  # the author builds each slab with its Look along the line; local +z is the back
            up = rp[:, 1]
            top = c + up * h[1]
            a, b = top - fwd * h[2], top + fwd * h[2]
            out.append((a, b, math.degrees(math.atan2(b[1] - a[1], math.hypot(b[0] - a[0], b[2] - a[2]))), up))
        return out

    # --------------------------------------------------------------------------------------- additive
    def test_rooftop_is_additive(self):
        """The anchors the owner named stay: portal flow lives in the hub, the coin challenge coins, rings, pads, pods
        and checkpoints are byte-identical to the plan without the shortcut; terrain, shells, key and boss too, so no
        terrain rebake is needed (the old bake stays valid)."""
        import author_space4 as A
        A.ROOFTOP_SHORTCUT = False
        try:
            old, _ = A.build()
        finally:
            A.ROOFTOP_SHORTCUT = True
        og, ng = old["skyrally"]["gameplay"], self.gp
        for k in ("coins", "rings", "pads", "pods", "checkpoints", "startGrid", "finish", "key", "modes", "boss"):
            self.assertEqual(og[k], ng[k], k)
        self.assertEqual(og["alternates"], ng["alternates"][:1])
        self.assertEqual(old["terrain"], self.plan["terrain"])
        self.assertEqual(old["skyrally"]["shells"], self.sk["shells"])
        self.assertEqual(old["skyrally"]["route"], self.sk["route"])
        self.assertEqual(old["skyrally"]["deck"], self.sk["deck"])
        self.assertEqual(old["groups"], self.plan["groups"][:-1])
        self.assertEqual(self.plan["groups"][-1], "Highway/RooftopLine")
        on, nn = old["skyrally"]["provenance"]["spaceNeon"], self.sk["provenance"]["spaceNeon"]
        self.assertEqual(json.loads(json.dumps(on["holograms"])), nn["holograms"])
        for k in ("edgePieces", "gridRungs", "chevrons", "lightArches"):
            self.assertEqual(on[k], nn[k], k) if k != "lightArches" else self.assertLessEqual(len(nn[k]), len(on[k]))
        # nothing that existed was removed except the lamps/arches/towers/props that stood where the line is
        new_keys = {json.dumps([i["pf"], i["p"]]) for i in self.plan["instances"]}
        gone = [i for i in old["instances"] if json.dumps([i["pf"], i["p"]]) not in new_keys]
        gone_families = {i["pf"].split("#")[0] for i in gone}
        self.assertTrue(all(f.startswith(("Streetlamp", "Skyway", "Tron", "HighwayParapet", "CityTower", "CityDome",
                                          "CityBlock", "NeonLane")) or f == "HighwayParapet" for f in gone_families), gone_families)

    def test_rooftop_off_switch_restores_the_old_plan(self):
        """ROOFTOP_SHORTCUT = False is the whole kill switch: same prefabs and instances as stage-v24 had."""
        import author_space4 as A
        A.ROOFTOP_SHORTCUT = False
        try:
            old, _ = A.build()
        finally:
            A.ROOFTOP_SHORTCUT = True
        self.assertFalse(any(k.startswith("Rooftop") for k in old["prefabs"]))
        self.assertEqual(len(old["skyrally"]["gameplay"]["alternates"]), 1)
        self.assertNotIn("rooftopShortcut", old["skyrally"]["provenance"])  # no null key: the stage-v24 plan exactly
        self.assertNotIn("Highway/RooftopLine", old["groups"])
        self.assertFalse(any(i["pf"].startswith("Rooftop") for i in old["instances"]))

    # ------------------------------------------------------------------------------------------- course line
    def test_rooftop_alt2_is_a_span_course_line(self):
        alts = self.gp["alternates"]
        a2 = alts[1]
        self.assertEqual((a2["id"], a2["style"]), ("Alt2", "span"))
        self.assertEqual((a2["joinStation"], a2["rejoinStation"]), (self.prov["entryStation"],
                                                                    self.prov["exitStation"] + self.prov["extend"]))
        chain = self.deck_chain()
        pts = np.array(a2["points"])
        self.assertGreaterEqual(len(pts), 40)
        # each point sits 1.8 under the driving surface (like Alt1's), on a slab of the chain
        for p in pts[::3]:
            best = None
            for a, b, _, _ in chain:
                ab = b - a
                t = max(0.0, min(1.0, ((p - a) @ ab) / (ab @ ab)))
                q = a + ab * t
                d = math.hypot(p[0] - q[0], p[2] - q[2])
                if best is None or d < best[0]:
                    best = (d, q[1])
            self.assertLess(best[0], 4.0)
            self.assertAlmostEqual(p[1] + 1.8, best[1], delta=1.0)
        # the ends are on the road surface (slip lanes flush with the pavers: ribbon + 2.7)
        for p, st in ((pts[0], a2["joinStation"]), (pts[-1], a2["rejoinStation"])):
            ribbon = self.route.frame_at(st).pos[1]
            self.assertAlmostEqual(p[1] + 1.8, ribbon + 2.7, delta=0.8)

    def test_rooftop_alt2_is_inside_the_tools_and_the_rules(self):
        """RouteBranch knows the span style, the adapter builds and carves nothing for it, adapt validates the plan."""
        rb = (ROOT / "src" / "shared" / "RouteBranch.luau").read_text()
        self.assertRegex(rb, r"span = 26")
        deck = (ROOT / "src" / "server" / "kit" / "Deck.luau").read_text()
        self.assertIn('alt.style == "span"', deck)
        mapper = (ROOT / "src" / "server" / "MapAdapter.luau").read_text()
        self.assertIn('alt.style ~= "span"', mapper)
        self.assertEqual(self.res.report.errors, [])

    # ----------------------------------------------------------------------------- existing wall driving
    def test_rooftop_surface_stays_clear_of_the_wall_class(self):
        """OWNER RULE: wall and mountain driving is untouched, so the line only asks the car to climb what it already
        climbs. Every driving surface is a smooth slab chain whose steepest face (a quarter-pipe-like ramp, ~41 degrees)
        keeps |n.up| well above CarConfig.WALL_MAX_UP_DOT, and neighbouring slabs never turn sharply under the car."""
        chain = self.deck_chain()
        self.assertGreaterEqual(len(chain), 50)
        wall_dot = self.cfg["WALL_MAX_UP_DOT"]
        steepest = 0.0
        for a, b, pitch, up in chain:
            steepest = max(steepest, abs(pitch))
            self.assertGreater(abs(up[1]), wall_dot + 0.15, (a, pitch))
        self.assertLessEqual(steepest, 48.5)
        self.assertGreaterEqual(steepest, 30.0)  # it is a real climb: a wall-class ramp, not a gentle road
        self.assertAlmostEqual(steepest, self.prov["climbPeakDeg"], delta=1.5)
        ps = [c[2] for c in chain]
        for a, b in zip(ps, ps[1:]):
            self.assertLessEqual(abs(b - a), 20.5)
        # the chain is continuous: each slab's front end is the next one's back end
        for (a0, b0, _, _), (a1, b1, _, _) in zip(chain, chain[1:]):
            self.assertLess(np.linalg.norm(b0 - a1), 0.7, (b0, a1))
        # CarController.isWallNormal on a car riding the surface: no slab changes the car's up by the wall class
        for (a0, b0, p0, u0), (a1, b1, p1, u1) in zip(chain, chain[1:]):
            self.assertGreater(float(u0 @ u1), wall_dot + 0.3)

    def test_rooftop_does_not_touch_physics_files(self):
        """Wall adhesion, climbing, barriers, kill volumes and rescue live in CarController / CarServer / AIRacers /
        RespawnRules / CarConfig: none of them is part of this change. Checked per commit that touches the rooftop
        geometry (not against a moving branch tip, so a later lane that edits a physics file on its own does not fail
        here, and the check still bites once this branch is merged)."""
        import subprocess
        physics = {"src/client/CarController.luau", "src/server/CarServer.luau", "src/server/AIRacers.luau",
                   "src/shared/RespawnRules.luau", "src/shared/CarConfig.luau", "src/shared/PlaneConfig.luau"}
        log = subprocess.run(["git", "log", "--format=%H", "--", "tools/map/space4_rooftop.py"],
                             cwd=ROOT, capture_output=True, text=True)
        if log.returncode != 0 or not log.stdout.strip():
            self.skipTest("no git history for the rooftop geometry")
        for sha in log.stdout.split():
            files = subprocess.run(["git", "show", "--name-only", "--format=", sha], cwd=ROOT, capture_output=True,
                                   text=True).stdout.split()
            self.assertEqual(physics & set(files), set(), sha)
        for _, inst in self.insts:
            self.assertFalse(self.plan["prefabs"][inst["pf"]]["parts"] and
                             self.family(inst) in ("RooftopKill", "RooftopRescue"))  # no rescue or kill volume

    # --------------------------------------------------------------------------------- clearance and rejoin
    def test_rooftop_clears_the_road_and_the_barriers(self):
        decks = self.pieces("RooftopDeck")
        walls = self.pieces("RooftopWall")
        self.assertEqual(self.res.gates["corridorPartIntrusions"], 0)  # the compile gate sees the line's parts too
        parapets = self.pieces("HighwayParapet") + self.pieces("ShortcutFunnelRail")
        pa = [(c, rp, h) for c, rp, h, _ in parapets]
        checked = 0
        for c, rp, h, _ in decks + walls:
            ext = np.abs(rp) @ h
            for pc, pr, ph in pa:
                pext = np.abs(pr) @ ph
                if np.any(np.abs(pc - c) > ext + pext):
                    continue
                if self.plan_nearest(c[0], c[2])[1] > self.prov["exitStation"] + self.prov["extend"] - 14.0:
                    continue  # the funnel's last piece is buried one stud into the resumed parapet on purpose
                self.assertFalse(obb_overlap(c, rp, h, pc, pr, ph, eps=0.3), "rooftop piece overlaps a road parapet")
                checked += 1
        self.assertGreater(len(pa), 100)
        # over the road: the deck underside clears the corridor ceiling (ribbon + 26) by at least 2 studs
        over = 0
        for c, rp, h, _ in decks:
            _, st, ribbon_y = self.plan_nearest(c[0], c[2])
            if self.plan_dist_to_route(c[0], c[2]) < 24.0:
                over += 1
                self.assertGreaterEqual(c[1] - h[1] - ribbon_y, self.sk["flight"]["corridor"]["ceiling"] + 2.0, c)
        self.assertGreaterEqual(over, 1)  # the bridge really crosses the road
        crossing = [p for p in self.gp["alternates"][1]["points"] if self.plan_dist_to_route(p[0], p[2]) < 20.0]
        self.assertGreaterEqual(len(crossing), 4)
        for p in crossing:
            ribbon_y = self.plan_nearest(p[0], p[2])[2]
            self.assertGreaterEqual(p[1] + 1.8 - ribbon_y, self.sk["flight"]["corridor"]["ceiling"] + 2.0 + 3.0, p)
        self.assertGreaterEqual(self.prov["bridgeS"][1] - self.prov["bridgeS"][0], 60.0)

    def plan_nearest(self, x: float, z: float):
        pts = np.array([[w.pos[0], w.pos[1], w.pos[2], w.station] for w in self.route.waypoints])
        a, b = pts[:-1], pts[1:]
        ab = b[:, [0, 2]] - a[:, [0, 2]]
        t = np.clip(((x - a[:, 0]) * ab[:, 0] + (z - a[:, 2]) * ab[:, 1]) / np.maximum(1e-9, (ab ** 2).sum(1)), 0, 1)
        qx, qz = a[:, 0] + ab[:, 0] * t, a[:, 2] + ab[:, 1] * t
        d = np.hypot(qx - x, qz - z)
        k = int(np.argmin(d))
        return float(d[k]), float(a[k, 3] + (b[k, 3] - a[k, 3]) * t[k]), float(a[k, 1] + (b[k, 1] - a[k, 1]) * t[k])

    def plan_dist_to_route(self, x: float, z: float) -> float:
        return self.plan_nearest(x, z)[0]

    def test_rooftop_walls_keep_clear_of_the_road_and_never_end_face_on(self):
        """Walls hold the line on its far side; the road side stays open at both slip lanes (an on-ramp and an
        off-ramp). Cars on the road and on the lanes meet only wall sides or deflect angles."""
        for c, rp, h, _ in self.pieces("RooftopWall"):
            look = rp[:, 2]
            _, _, ribbon_y = self.plan_nearest(c[0], c[2])
            if c[1] > ribbon_y + 20.0:
                continue  # over the road on the bridge
            for sgn in (-1, 1):
                end = c + look * h[2] * sgn
                self.assertGreaterEqual(self.plan_dist_to_route(end[0], end[2]), 25.0, end)
        # off-ramp funnel: driving along the merge lane into its closing wall is a deflect, never an end face
        a2 = np.array(self.gp["alternates"][1]["points"])
        f = self.route.frame_at(self.prov["exitStation"])  # the funnel starts here (RT_EXTEND before the lane's end)
        walls = t4.Walls2D(self.plan, (f.pos[0] - 150, f.pos[0] + 150), (f.pos[2] - 150, f.pos[2] + 150), a2[-1][1] + 1.8 + 2.2)
        hw = self.cfg["HALF_WIDTH"]
        heading = (f.tangent[0], f.tangent[2])
        saw_wall = False
        for lat in np.arange(-46.0, -24.0, 1.0):  # car centres on the lane (road is at 0, lane axis at -36)
            q = f.offset(lat, 0.0)
            hit = walls.drive(q[0], q[2], heading, hw, 120.0)
            if hit is not None:
                saw_wall = True
                self.assertEqual(hit[2], "side", (lat, hit))
                self.assertLess(hit[3], self.cfg["WALL_SHALLOW_DOT"], (lat, hit))
        self.assertTrue(saw_wall)
        # on-ramp: cars on the paver at the resumed parapet's start never meet its end face (rays reach lateral 21.6 + 2.7)
        s_hi = self.prov["parapetOpen"]["right"][0][1]
        f = self.route.frame_at(s_hi - 20.0)
        walls = t4.Walls2D(self.plan, (f.pos[0] - 150, f.pos[0] + 150), (f.pos[2] - 150, f.pos[2] + 150), f.pos[1] + 4.2)
        for lat in np.arange(0.0, 21.0, 1.0):
            q = f.offset(lat, 0.0)
            hit = walls.drive(q[0], q[2], (f.tangent[0], f.tangent[2]), hw, 90.0)
            if hit is not None:
                self.assertEqual(hit[2], "side", (lat, hit))

    def test_rooftop_parapet_is_open_only_where_a_lane_is_beside_it(self):
        """The parapet is removed only along the two slip-lane mouths (right side at the entry, left side at the exit),
        so no hole opens onto the plaza anywhere else; the lane's own wall closes each wedge at its apex."""
        op = self.prov["parapetOpen"]
        self.assertEqual(len(op["right"]), 1)
        self.assertEqual(len(op["left"]), 1)
        (rlo, rhi), (llo, lhi) = op["right"][0], op["left"][0]
        self.assertLess(rhi - rlo, 120.0)
        self.assertLess(lhi - llo, 180.0)
        self.assertTrue(all(0 <= v <= self.route.length for v in (rlo, rhi, llo, lhi)))
        for c, rp, h, part in self.pieces("HighwayParapet"):
            st = self.plan_nearest(c[0], c[2])[1]
            side = 1.0 if (c - np.array(self.route.frame_at(st).pos)) @ np.array(self.route.frame_at(st).right) > 0 else -1.0
            lo, hi = (rlo, rhi) if side > 0 else (llo, lhi)
            self.assertFalse(lo + 3.0 < st < hi - 3.0, f"parapet piece inside the opening at st {st:.1f}")
        # every station of an opening has the lane's deck within a few studs of the curb (no hole to the plaza)
        decks = self.pieces("RooftopDeck")

        def gap(x, z):
            best = 1e9
            for c, rp, h, _ in decks:
                u = (x - c[0]) * rp[0, 0] + (z - c[2]) * rp[2, 0]
                w = (x - c[0]) * rp[0, 2] + (z - c[2]) * rp[2, 2]
                best = min(best, math.hypot(max(abs(u) - h[0], 0.0), max(abs(w) - h[2], 0.0)))
            return best

        for side, (lo, hi) in ((1.0, (rlo, rhi)), (-1.0, (llo, lhi))):
            st = lo + 2.0
            while st < hi - 2.0:
                q = np.array(self.route.frame_at(st).offset(side * 25.2, 0.0))
                self.assertLess(gap(q[0], q[2]), 5.0, f"hole beside the curb at st {st:.0f} ({gap(q[0], q[2]):.1f})")
                st += 4.0

    # -------------------------------------------------------------------------------------- course counting
    def test_rooftop_gates_still_count_by_station(self):
        """A car on the line keeps earning checkpoints: for each gate the line bypasses, some sample of the line is
        within 110 studs of its station (or 85 of the gate part), the car rule in RaceManager."""
        a2 = self.gp["alternates"][1]
        pts = np.array(a2["points"])
        stations = [self.plan_nearest(p[0], p[2])[1] for p in pts]
        for cp in self.gp["checkpoints"]["stations"]:
            if not (a2["joinStation"] < cp < a2["rejoinStation"]):
                continue
            part = np.array(self.route.frame_at(cp).offset(0.0, self.gp["checkpoints"]["heightOffset"]))
            ok = any(abs(st - cp) <= 110.0 for st in stations) or any(np.linalg.norm(p - part) <= 85.0 for p in pts)
            self.assertTrue(ok, f"gate at {cp} is out of reach of the rooftop line")
        self.assertTrue(all(self.plan_nearest(p[0], p[2])[0] < 240.0 for p in pts))  # RaceManager distToSpline < 240

    def test_rooftop_saves_a_real_but_modest_amount(self):
        """Lap length: the line is ~150 studs shorter than the road it skips; with the car's own speed model (slope
        gravity 70, accel and overspeed decay from CarConfig) it takes about a second less than driving the road at
        top speed, so it is worth taking but never a free win."""
        c = self.cfg
        a2 = np.array(self.gp["alternates"][1]["points"])
        top = c["TOP_SPEED"]

        def run(profile):
            v, t, dt = top, 0.0, 0.004
            for ds, dy in profile:
                L = math.hypot(ds, dy)
                fy = dy / L
                d = 0.0
                while d < L:
                    if v < top:
                        v = min(top, v + max(c["ACCEL_MIN"], (top - v) * c["ACCEL_RESPONSE"]) * dt)
                    else:
                        v = max(top, v - max(c["COAST_DECEL"], (v - top) * c["OVERSPEED_DECAY"]) * dt)
                    v -= c["SLOPE_GRAVITY"] * fy * dt
                    d += v * dt
                    t += dt
            return t

        line = [(math.hypot(b[0] - a[0], b[2] - a[2]), b[1] - a[1]) for a, b in zip(a2, a2[1:])]
        st0, st1 = self.gp["alternates"][1]["joinStation"], self.gp["alternates"][1]["rejoinStation"]
        road, prev, st = [], np.array(self.route.frame_at(st0).pos), st0
        while st < st1:
            st = min(st1, st + STEP)
            q = np.array(self.route.frame_at(st).pos)
            road.append((math.hypot(q[0] - prev[0], q[2] - prev[2]), q[1] - prev[1]))
            prev = q
        saved = run(road) - run(line)
        self.assertGreater(saved, 0.7)
        self.assertLess(saved, 2.5)
        self.assertGreaterEqual(self.prov["plannedSaving"], 120.0)
        self.assertLessEqual(self.prov["plannedSaving"], 250.0)

    # ------------------------------------------------------------------------------------------ the tell
    def test_rooftop_tell_is_lit_budgeted_and_visual_only(self):
        fams = {}
        for _, inst in self.insts:
            f = self.family(inst)
            if f.startswith("Rooftop"):
                fams.setdefault(f, []).append(inst)
        self.assertTrue(any(f.startswith("RooftopChevron") for f in fams))  # up-slope arrows on the face
        self.assertTrue(any(f.startswith("RooftopTellArch") for f in fams))  # arches over the slip lane
        import author_space4 as A
        pal = set(A.TRON_PALETTE)  # the SpaceNeon TRON_PALETTE (v29 W1b A10: amber and cyan only)
        lights = 0
        parts = 0
        for key, pf in self.plan["prefabs"].items():
            if not key.startswith("Rooftop"):
                continue
            fam = key.split("#")[0]
            for part in pf["parts"]:
                parts += 1
                extra = part[12] if len(part) > 12 else {}
                if fam == "RooftopDeck" or (fam == "RooftopWall" and part is pf["parts"][0]):
                    self.assertFalse(extra.get("nc"), key)  # the driving parts collide (a wall's neon cap does not)
                    continue
                self.assertTrue(extra.get("nc"), (key, part))  # all dressing is visual only
                if "l" in extra:
                    lights += 1
                    self.assertLessEqual(extra["l"][0], 70)
                if fam.startswith(("RooftopChevron", "RooftopEdge", "RooftopTellArch", "RooftopBand", "RooftopLamp")) and part[11] == "Neon" and "RooftopWall" not in fam:
                    self.assertIn(part[10], pal, (key, part[10]))
        # one keystone plus the roof lamp prefabs (one light each; the plan places several instances, LightLod caps them)
        self.assertEqual(lights, 3)
        lamps = [i for f, v in fams.items() if f.startswith("RooftopLamp") for i in v]
        self.assertGreaterEqual(len(lamps), 4)
        self.assertLessEqual(len(lamps), 10)  # light budget: at most 10 lamp lights + the keystone
        for i in lamps:  # lamps stay low on the wall caps, never above the chase camera's line
            self.assertLess(i["p"][1], self.prov["roofY"] + 8.0)
        # owner rule (walls and climbing untouched): the car's ground probes count visible nc parts as road, so a lamp
        # is a lens flush with the wall's neon cap (instance origin = cap top): at most 0.05 proud, inside the 2.6 cap
        for key, pf in self.plan["prefabs"].items():
            if key.startswith("RooftopLamp"):
                for part in pf["parts"]:
                    self.assertLessEqual(part[2] + part[5] / 2, 0.05, key)
                    self.assertLessEqual(abs(part[1]) + part[4] / 2, 1.3, key)
        # the roof run carries chevrons too (not only the face and the lanes)
        roof_chev = [i for f, v in fams.items() if f.startswith("RooftopChevron") for i in v if i["p"][1] > self.prov["roofY"] - 1.0]
        self.assertGreaterEqual(len(roof_chev), 5)
        # the face chevrons point the way the car drives (local -z): a bar yawed ry runs along (sin ry, cos ry) in (x, z),
        # so the arm left of the axis (x < 0) must take ry < 0 for its end nearest the axis to be the front one
        for key, pf in self.plan["prefabs"].items():
            if key.startswith("RooftopChevron_"):
                for part in pf["parts"]:
                    self.assertGreater(part[8] * part[1], 0.0, (key, part))  # ry and x have the same sign
                    self.assertGreater(abs(part[8]), 30.0)
        # chevrons are really on the climb: at least 8 instances sit between the face's ends
        chev = [i for f, v in fams.items() if f.startswith("RooftopChevron") for i in v]
        self.assertGreaterEqual(len(chev), 8)
        n_inst_parts = sum(len(self.plan["prefabs"][i["pf"]]["parts"]) for v in fams.values() for i in v)
        self.assertLessEqual(n_inst_parts, 1000)  # part budget of the whole line, blocks and neon included
        self.assertLessEqual(self.prov["neonParts"], 450)

    def test_rooftop_blocks_are_visual_masses_under_the_line(self):
        """Support blocks and piers are nc (the car only meets slabs and walls) and reach the ground; every deck slab
        within a block run has a block under it."""
        sup = [i for _, i in self.insts if self.family(i).startswith(("RooftopPodium", "RooftopShaft", "RooftopWedge",
                                                                           "RooftopPier"))]
        self.assertGreater(len(sup), 20)
        for inst in sup:
            for part in self.plan["prefabs"][inst["pf"]]["parts"]:
                self.assertTrue(part[12].get("nc"))
        families = {self.family(i).split("_")[0] for i in sup}
        self.assertEqual(families, {"RooftopPodium", "RooftopShaft", "RooftopWedge", "RooftopPier"})
        for inst in sup:  # podiums and piers reach the ground
            if self.family(inst).startswith(("RooftopPodium", "RooftopPier")):
                self.assertLessEqual(min(inst["p"][1] + part[2] - part[5] / 2 for part in self.plan["prefabs"][inst["pf"]]["parts"]), 0.5)
        decks = self.pieces("RooftopDeck")
        s_a1, s_b0 = self.prov["bridgeS"]
        under = 0
        for c, rp, h, _ in decks:
            if any(abs(c[0] - i["p"][0]) < 8 and abs(c[2] - i["p"][2]) < 8 for i in sup):
                under += 1
        self.assertGreater(under, 0.75 * (len(decks) - 22))  # all but the bridge (~20 pieces) and the lane ends

    # ------------------------------------------------------------------------------------- neon and the rest
    def test_rooftop_keeps_spaceneon_clear(self):
        """Holograms and billboards stay clear of the line (plan view, past the outer wall face), as they do the Alt1
        chord; the neon strips, rungs and chevrons of the road are unchanged."""
        a2 = np.array(self.gp["alternates"][1]["points"])

        def dist(x, z):
            a, b = a2[:-1][:, [0, 2]], a2[1:][:, [0, 2]]
            ab = b - a
            t = np.clip(((x - a[:, 0]) * ab[:, 0] + (z - a[:, 1]) * ab[:, 1]) / np.maximum(1e-9, (ab ** 2).sum(1)), 0, 1)
            return float(np.min(np.hypot(a[:, 0] + ab[:, 0] * t - x, a[:, 1] + ab[:, 1] * t - z)))

        neon = self.sk["provenance"]["spaceNeon"]
        for h in neon["holograms"]:
            reach = h["h"] * (0.6 * math.sin(math.radians(h["lean"])) + 0.26)
            self.assertGreaterEqual(dist(h["pos"][0], h["pos"][2]) - reach, 16.0 + 40.0 - 0.5, h)
        for b in neon["billboards"]:
            self.assertGreaterEqual(dist(b["pos"][0], b["pos"][2]) - b["w"] / 2, 16.0 + 30.0 - 0.5, b)
        self.assertEqual(len(neon["billboards"]), 4)
        for key, pf in self.plan["prefabs"].items():
            if key.startswith("Tron"):
                self.assertTrue(all(len(p) > 12 and p[12].get("nc") for p in pf["parts"]))

    def test_rooftop_line_is_not_under_a_tower_or_prop(self):
        """Towers, set dressing and streetlamps/arches that stood where the line is were left out (no draw changed)."""
        a2 = np.array(self.gp["alternates"][1]["points"])
        for inst in self.plan["instances"]:
            fam = self.family(inst)
            if not fam.startswith(("CityTower", "CityDome", "CityBlock")):
                continue
            x, z = inst["p"][0], inst["p"][2]
            d = np.min(np.hypot(a2[:, 0] - x, a2[:, 2] - z))
            self.assertGreater(d, 34.0 + 16.0, (fam, x, z))
        for d_ in self.sk["setDressing"]:
            self.assertGreater(float(np.min(np.hypot(a2[:, 0] - d_["pos"][0], a2[:, 2] - d_["pos"][2]))), 40.0)
        stations = self.prov["keepOut"]
        opens = self.prov["parapetOpen"]["right"] + self.prov["parapetOpen"]["left"]
        for inst in self.plan["instances"]:
            fam = self.family(inst)
            if fam.startswith(("Streetlamp", "SkywayArch", "TronArch")):
                st = self.plan_nearest(inst["p"][0], inst["p"][2])[1]
                self.assertFalse(any(lo + 1.0 < st < hi - 1.0 for lo, hi in stations), (fam, st))
            if fam.startswith("NeonSignGantry"):  # its legs stand on the parapet caps: never inside a parapet opening
                st = self.plan_nearest(inst["p"][0], inst["p"][2])[1]
                self.assertFalse(any(lo - 2.0 < st < hi + 2.0 for lo, hi in opens), (fam, st))


if __name__ == "__main__":
    unittest.main()
