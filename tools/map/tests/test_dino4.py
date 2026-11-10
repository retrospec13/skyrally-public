#!/usr/bin/env python3
"""DINO-4 race data after the trap audit (docs/audits/traps_dino4.md, FIXED sections): map/dino4/plan.json is exactly
what tools/map/author_dino4.py writes, and each data fix stays pinned:

- D4-04  eight silver coins, one on the Alt1 tunnel line, each in open air and reachable from the race line;
- D4-02  no boost runs into the final bends, a checkpoint sits between the last two bends, the final bend's outer
         wall is widened without cutting the archway or the start gate;
- D4-06  no boost ring inside the start S-curve; the three start rings run down the start straight;
- D4-10  the invisible lethal StartLavaBed covers the start chamber only;
- D4-01 / D4-07  egg arena objectives leave a run-out before the return line, and the nest rings clear the altar.

Terrain clearance uses an analytic replay of the plan's shell ops that can only under-carve (CarveRouteTube at its
radiusMin, upper lobes and the deck-bed carve left out, RouteFloorFill crust islands as a solid layer on the slab), so a
point it calls air is air in every Studio build.
Run: python3 -m unittest discover -s tools/map/tests -v"""
import json
import math
import re
import unittest

import numpy as np

import fixtures  # noqa: F401  (puts tools/map and tools/course on sys.path)
import adapt
import author_dino4 as author
import route_geometry

ROOT = fixtures.ROOT
PLAN = ROOT / "map" / "dino4" / "plan.json"
KILL_Y = 16.0  # FlightController: Y <= 16 is a lava crash
COIN_PICKUP = 13.0  # CoinChallenge RADIUS_PLANE
CRUST_TOP = 3.0  # RouteFloorFill crust cylinders (h 4, centred 1 over the slab top) reach this far above the slab


def plane_boost():
    """(boost distance, boosted turn radius) from src/shared/PlaneConfig.luau."""
    src = (ROOT / "src" / "shared" / "PlaneConfig.luau").read_text()

    def num(key):
        return float(re.search(rf"^PlaneConfig\.{key}\s*=\s*(-?[\d.]+)", src, re.M).group(1))

    speed = num("BOOST_SPEED")
    return speed * num("BOOST_DURATION"), speed / math.radians(num("BOOST_YAW_RATE"))


class Shell:
    """Solid/air of points after the plan's shell ops and the adapter's corridor carves (under-carving, see above)."""

    def __init__(self, plan, route):
        self.ops = plan["skyrally"]["shells"]["ops"]
        self.wps = route.waypoints
        sk = plan["skyrally"]
        self.cor = sk["flight"]["corridor"]
        self.alts = sk["gameplay"].get("alternates") or []

    @staticmethod
    def _in_obb(p, mid, axes, half):
        local = (p - mid) @ np.array(axes).T  # rows of axes are the box axes
        return np.all(np.abs(local) <= half, axis=1)

    def solid(self, pts):
        p = np.atleast_2d(np.array(pts, float))
        s = np.zeros(len(p), bool)
        P = np.array([w.pos for w in self.wps])
        for op in self.ops:
            k, val = op["op"], op.get("mat") != "Air"
            if k == "Clear":
                s[:] = False
            elif k == "FillRouteBounds":
                lo, hi = P.min(0), P.max(0)
                m = op.get("margin", 280)
                top = hi[1] + op.get("above", 230)
                inside = ((p[:, 0] >= lo[0] - m) & (p[:, 0] <= hi[0] + m) & (p[:, 2] >= lo[2] - m)
                          & (p[:, 2] <= hi[2] + m) & (p[:, 1] >= op.get("yMin", 0)) & (p[:, 1] <= top))
                s[inside] = True
            elif k == "FillBlock":
                cf = op["cf"]
                axes = np.array(cf[3:12], float).reshape(3, 3).T  # rows: the CFrame's right, up, back columns
                m = self._in_obb(p, np.array(cf[:3], float), axes, np.array(op["size"], float) / 2)
                s[m] = val
            elif k == "FillBall":
                m = np.linalg.norm(p - np.array(op["center"], float), axis=1) <= op["r"]
                s[m] = val
            elif k == "FillCylinder":
                cf = op["cf"]
                assert cf[3:] == [1, 0, 0, 0, 1, 0, 0, 0, 1], cf  # upright only in this plan
                c = np.array(cf[:3], float)
                m = (np.hypot(p[:, 0] - c[0], p[:, 2] - c[2]) <= op["r"]) & (np.abs(p[:, 1] - c[1]) <= op["h"] / 2)
                s[m] = val
            elif k == "CarveRouteTube":
                for w in self.wps:
                    if op["fromStation"] <= w.station <= op["toStation"]:
                        c = np.array(w.pos, float) + [0, op["lift"], 0]
                        s[np.linalg.norm(p - c, axis=1) <= op["radiusMin"]] = False
            elif k == "RouteFloorFill":
                for a, b in zip(self.wps, self.wps[1:]):
                    a_, b_ = np.array(a.pos, float), np.array(b.pos, float)
                    ln = float(np.linalg.norm(b_ - a_))
                    if ln <= 0.5 or not (op["fromStation"] <= a.station <= op["toStation"]):
                        continue
                    look = (b_ - a_) / ln
                    right = np.cross(look, [0, 1, 0])
                    right /= np.linalg.norm(right)
                    up = np.cross(right, look)
                    centre = (a_ + b_) / 2 - up * op["depth"]
                    half = np.array([op["width"] / 2, op["thickness"] / 2, (ln + 40) / 2])
                    # crust islands are seeded by Roblox's Random: count the whole slab top + CRUST_TOP as solid
                    lifted = centre + up * (CRUST_TOP / 2)
                    s[self._in_obb(p, lifted, [right, up, look], half + [0, CRUST_TOP / 2, 0])] = True
            elif k in ("SetMaterialColor",):
                pass
            else:
                raise AssertionError(f"shell op {k} not modelled")
        # MapAdapter carves the flight corridor and the alternates last
        for i in range(len(self.wps) - 1):
            box = adapt.segment_box(self.wps[i].pos, self.wps[i + 1].pos, self.cor["halfWidth"], self.cor["floor"], self.cor["ceiling"])
            if box is not None:
                s[self._in_obb(p, box[0], box[1], box[2])] = False
        for alt in self.alts:
            tunnel = alt.get("style") == "tunnel"
            pts_ = alt["points"]
            for a, b in zip(pts_, pts_[1:]):
                box = adapt.segment_box(a, b, 13 if tunnel else 20, 4, 28 if tunnel else 40)
                if box is not None:
                    s[self._in_obb(p, box[0], box[1], box[2])] = False
        return s

    def clear(self, centre, radius):
        """Every point of the ball (centre, radius), sampled on shells every 4 studs, is air."""
        dirs = [np.array(d, float) / np.linalg.norm(d) for d in
                [(x, y, z) for x in (-1, 0, 1) for y in (-1, 0, 1) for z in (-1, 0, 1) if (x, y, z) != (0, 0, 0)]]
        pts = [np.array(centre, float)]
        for r in np.arange(4.0, radius + 1e-6, 4.0):
            pts += [np.array(centre, float) + d * r for d in dirs]
        return not self.solid(pts).any()


class Dino4Plan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = json.loads(PLAN.read_text())
        cls.sk = cls.plan["skyrally"]
        cls.gp = cls.sk["gameplay"]
        cls.res = adapt.check(cls.plan)
        cls.route = cls.res.route
        cls.L = cls.route.length
        cls.shell = Shell(cls.plan, cls.route)
        cls.boost_distance, cls.boost_radius = plane_boost()

    # ------------------------------------------------------------------------------------------------ pipeline

    def test_plan_is_the_author_scripts(self):
        self.assertEqual(self.plan, json.loads(json.dumps(author.build())),
                         "map/dino4/plan.json is stale: rerun tools/map/author_dino4.py, then tools/map/adapt.py")

    def test_gates_unchanged(self):
        self.assertEqual([f"{e.code}: {e.msg}" for e in self.res.report.errors], [])
        self.assertLessEqual(abs(self.L - 5450), 1.0)
        self.assertEqual(self.res.gates["corridorPartIntrusions"], 0)

    def test_trackdata_is_current(self):
        td = (ROOT / "build" / "dino4" / "TrackData.luau").read_text()
        sha = re.search(r'planSha256 = "([0-9a-f]{64})"', td).group(1)
        self.assertEqual(sha, adapt.sha256_file(PLAN), "build/dino4/TrackData.luau is stale: rerun tools/map/adapt.py")

    # ------------------------------------------------------------------------------------------------ D4-04 coins

    def coin_lines(self):
        line = self.sk["flight"]["lineOffset"]
        alts = {a["id"]: a for a in self.gp["alternates"]}
        return line, alts

    def test_eight_coins_one_on_the_alt1_tunnel(self):
        coins = self.gp["coins"]
        self.assertEqual(len(coins), 8)
        self.assertEqual([c["id"] for c in coins], list(range(1, 9)))
        self.assertEqual([c["station"] for c in coins], sorted(c["station"] for c in coins))
        line, alts = self.coin_lines()
        on_alt = [c for c in coins if c.get("alternate")]
        self.assertEqual([c["alternate"] for c in on_alt], ["Alt1"])
        for c in coins:
            self.assertTrue(0 <= c["station"] < self.L, c)
        for c in on_alt:
            alt = alts[c["alternate"]]
            pts = [np.array(p, float) + [0, line, 0] for p in alt["points"]]
            d = min(np.linalg.norm(np.array(c["pos"]) - q) for q in pts)
            self.assertLess(d, 0.5, "the Alt1 coin sits on a tunnel point's flight line (point + lineOffset)")
            self.assertTrue(alt["joinStation"] < c["station"] < alt["rejoinStation"])
            # tunnel kit (kit/Deck buildAlternate): floor top +1.8, inner walls +-13, roof underside +28 over the point
            self.assertGreaterEqual(line - 1.8, 12)
            self.assertGreaterEqual(28 - line, 12)

    def test_alt1_coin_inside_the_enclosed_tunnel(self):
        """The tunnel coin is where the Alt1 line is a closed tube (rock above, below and on both sides within 24),
        so a pilot who enters the tunnel cannot pass it by more than the tube's half width."""
        c = next(c for c in self.gp["coins"] if c.get("alternate") == "Alt1")
        p = np.array(c["pos"], float)
        # alternate points are offsets from the main route: the tube is enclosed when the main corridor is far away
        main = min(math.hypot(w.pos[0] - p[0], w.pos[2] - p[2]) for w in self.route.waypoints)
        self.assertGreater(main, 34 + 13 + 40)
        self.assertTrue(self.shell.clear(p, 8), "coin ball (8) in carved air")
        for d in ([0, 1, 0], [0, -1, 0], [1, 0, 0], [-1, 0, 0]):
            ray = [p + np.array(d, float) * t for t in np.arange(0.0, 24.0, 1.0)]
            self.assertTrue(self.shell.solid(ray).any(), f"rock within 24 along {d}")

    def test_main_coins_reachable_from_the_race_line(self):
        """Main-line coins: exactly the adapter's frame offset, within 16 of the assisted line (line +14) so taking
        one is a small, deliberate move, the whole pickup ball inside the flight corridor's width, never on the start
        grid, 20 studs of air all round (under-carving model) and well above the lava kill plane."""
        line, _ = self.coin_lines()
        cor = self.sk["flight"]["corridor"]
        gaps = self.sk["deck"].get("gaps") or []
        alt_spans = [(a["joinStation"], a["rejoinStation"]) for a in self.gp["alternates"] if a["id"] == "Alt1"]
        for c in self.gp["coins"]:
            if c.get("alternate"):
                continue
            with self.subTest(coin=c["id"]):
                f = self.route.frame_at(c["station"])
                self.assertLess(math.dist(f.offset(c["lateral"], c["height"]), c["pos"]), 0.5)
                self.assertLessEqual(math.hypot(c["lateral"], c["height"] - line), 16.0)
                self.assertLessEqual(abs(c["lateral"]) + COIN_PICKUP, cor["halfWidth"])
                self.assertLessEqual(c["height"] + COIN_PICKUP, cor["ceiling"])
                if c["height"] - COIN_PICKUP < cor["floor"]:
                    # below the corridor floor only where the deck is gapped (the lava-gap dip)
                    self.assertTrue(any(g["from"] + COIN_PICKUP <= c["station"] <= g["to"] - COIN_PICKUP for g in gaps), c)
                self.assertGreater(c["station"], 250, "off the start grid")
                self.assertFalse(any(a <= c["station"] <= b for a, b in alt_spans),
                                 "no main coin beside Alt1: one lap through the tunnel can take all eight")
                self.assertTrue(self.shell.clear(c["pos"], 20), "20 studs of carved air round the coin")
                self.assertGreater(c["pos"][1] - KILL_Y, 30)

    def test_coins_clear_of_boosts_pods_and_checkpoints(self):
        """A coin never shares a ring, pad or pod (the boost or item would hide the coin's own moment) and is spread
        out along the lap."""
        others = []
        for kind in ("rings", "pads", "pods"):
            for o in self.gp[kind]:
                f = self.route.frame_at(o["station"])
                others.append((o["name"], f.offset(o.get("lateral", 0), o.get("height", adapt.PAD_LIFT))))
        for c in self.gp["coins"]:
            for name, q in others:
                self.assertGreater(math.dist(c["pos"], q), 25, f"coin {c['id']} beside {name}")
        main = sorted(c["station"] for c in self.gp["coins"] if not c.get("alternate"))
        self.assertGreaterEqual(min(b - a for a, b in zip(main, main[1:])), 190)

    # ------------------------------------------------------------------------------------------- D4-02 / D4-06

    def windows(self):
        rows, _ = route_geometry.analyse([list(w.pos) for w in self.route.waypoints], step=5, base=20)
        span = self.boost_distance + 60
        out = {}
        for kind in ("rings", "pads"):
            for b in self.gp[kind]:
                st = b["station"]
                win = [r for r in rows if (r["st"] - st) % self.L <= span]
                out[b["name"]] = min(win, key=lambda r: r["r"])
        return out

    def test_no_boost_runs_into_the_tight_bends(self):
        """Every ring and pad window (boost distance + 60) stays out of the course's tight bends (R < 100: the start
        S, 5190-5230 and the final bend); the moved rings have fully clean windows (never under the boosted radius)."""
        w = self.windows()
        for name, r in w.items():
            self.assertGreaterEqual(r["r"], 100, f"{name} boosts into R {r['r']:.0f} at st {r['st']}")
        for name in author.RING_STATIONS:
            self.assertGreaterEqual(w[name]["r"], self.boost_radius, f"{name} window min R {w[name]['r']:.0f}")

    def test_moved_rings(self):
        rings = {r["name"]: r for r in self.gp["rings"]}
        for name, st in author.RING_STATIONS.items():
            self.assertEqual(rings[name]["station"], st)
            self.assertIn("builtStation", rings[name])
        s_curve = self.sk["route"]["radiusExceptions"][0]
        start = sorted(r["station"] for n, r in rings.items() if n.startswith("BoosterRing_Start_"))
        self.assertEqual(len(start), 3)
        self.assertGreater(start[0], s_curve["to"], "no start ring inside the start S-curve")
        self.assertTrue(all(295 - 15 <= s <= 450 for s in start), "the start rings run down the FTUE straight")
        self.assertGreater(min(b - a for a, b in zip(start, start[1:])), 50)
        final = rings["BoosterRing_5_Final"]["station"]
        self.assertLess(final + self.boost_distance + 60, 4900, "the final ring's boost ends before the last bends")

    def test_checkpoint_between_the_last_two_bends(self):
        """A crash in the final bend (5330-5375) respawns between the bends, no farther back than the 1.6 s respawn
        invulnerability (~176 studs at cruise) covers, and never behind a ring or pad."""
        stations = self.gp["checkpoints"]["stations"]
        self.assertEqual(stations, sorted(stations))
        before = [s for s in stations if s < 5330]
        self.assertTrue(5240 <= before[-1] <= 5330 - 30, before[-1])
        self.assertLess(5375 - before[-1], 176)
        boosts = [b["station"] for k in ("rings", "pads") for b in self.gp[k]]
        self.assertFalse(any(before[-1] <= b <= 5450 for b in boosts), "no boost between that respawn and the line")
        self.assertEqual(len(stations), 15)

    def test_final_bend_widened_clear_of_art(self):
        ops = self.sk["shells"]["ops"]
        floor = max(i for i, o in enumerate(ops) if o["op"] == "RouteFloorFill")
        widen = [o for o in ops[floor + 1:] if o["op"] == "FillBall" and o["mat"] == "Air"]
        self.assertEqual(widen, [author.FINAL_BEND_WIDEN])
        b = widen[0]
        # every art part, collidable or not: the ball cuts no terrain an art piece stands in
        art = json.loads(json.dumps(self.plan))
        for pf in art["prefabs"].values():
            for part in pf["parts"]:
                if len(part) > 12 and isinstance(part[12], dict):
                    part[12].pop("nc", None)
        centres, halves, meta = adapt.collidable_parts(art)
        gap = np.linalg.norm(np.maximum(np.abs(centres - np.array(b["center"], float)) - halves, 0), axis=1)
        k = int(gap.argmin())
        self.assertGreater(float(gap[k]), b["r"] + 2, f"widening ball cuts near {meta[k]}")
        # the sim's wide-exit crash points are open air now
        for q in ([59, 149, 52], [66, 149, 48], [71, 150, 72]):
            self.assertFalse(self.shell.solid([q]).any(), q)
        # and the ball stays inside the solid mass (no window to the void)
        P = np.array([w.pos for w in self.route.waypoints])
        fb = next(o for o in ops if o["op"] == "FillRouteBounds")
        for ax in (0, 2):
            self.assertGreater(b["center"][ax] - b["r"], P[:, ax].min() - fb["margin"] + 40)
            self.assertLess(b["center"][ax] + b["r"], P[:, ax].max() + fb["margin"] - 40)

    # -------------------------------------------------------------------------------------------------- D4-10

    def test_start_lava_bed_covers_the_start_chamber_only(self):
        bed = next(h for h in self.sk["hazards"] if h["name"] == "StartLavaBed")
        cx, cy, cz = bed["cf"][:3]
        sx, sy, sz = bed["size"]
        (x0, x1), (z0, z1) = author.START_LAVA_BED_BOUNDS["x"], author.START_LAVA_BED_BOUNDS["z"]
        self.assertGreaterEqual(cx - sx / 2, x0 - 1e-6)
        self.assertLessEqual(cx + sx / 2, x1 + 1e-6)
        self.assertGreaterEqual(cz - sz / 2, z0 - 1e-6)
        self.assertLessEqual(cz + sz / 2, z1 + 1e-6)
        self.assertEqual((cy, sy), (75, 4), "the lethal top stays at the chamber floor (Y 77)")
        # no route-tube waypoint (where the lava shelf sits 10-30 lower, deck - 44) is under the bed
        tube = next(o for o in self.sk["shells"]["ops"] if o["op"] == "CarveRouteTube")
        for w in self.route.waypoints:
            if tube["fromStation"] <= w.station <= tube["toStation"]:
                inside = (cx - sx / 2 <= w.pos[0] <= cx + sx / 2) and (cz - sz / 2 <= w.pos[2] <= cz + sz / 2)
                self.assertFalse(inside, f"tube waypoint at st {w.station:.0f} under the lava bed")

    # ------------------------------------------------------------------------------------------- D4-01 / D4-07

    def test_egg_objectives_leave_a_run_out(self):
        """A plane leaving a nest or an outer pod heading straight out has room to turn before the return line:
        nests a boosted turn radius (145), outer pods a cruise turn radius (~92) and more."""
        b = self.gp["modes"]["battle"]
        c = b["center"]
        ret = b["boundary"]["radius"] + b["boundary"]["softWidth"]
        r = lambda p: math.hypot(p[0] - c[0], p[2] - c[2])  # noqa: E731
        for n in b["nests"]:
            self.assertGreaterEqual(ret - r(n["pos"]), self.boost_radius - 1, n["name"])
        for p in b["pickupAnchors"]:
            self.assertGreaterEqual(ret - r(p), 100, p)
        for s in b["spawns"]:
            self.assertGreaterEqual(ret - r(s), 80, s)

    def test_nest_rings_clear_the_altar(self):
        """The ring's bottom (where the egg bowl sits) is above the altar's top tier, so the low inward pass through a
        nest flies over the altar instead of into its tier-2 face."""
        b = self.gp["modes"]["battle"]
        centres, halves, meta = adapt.collidable_parts(self.plan)
        tiers = [i for i, m in enumerate(meta) if m["prefab"] == "LowerBasinVolcanicAltar"]
        top = max(centres[i][1] + halves[i][1] for i in tiers)
        for n in b["nests"]:
            self.assertGreaterEqual(n["pos"][1] - n["radius"], top + 4, n["name"])
            self.assertEqual(n["ground"], author.EGG_FLOOR, "still standing on the hall floor (outside tier 1)")

    def test_pods_in_the_bots_flight_band(self):
        """Raising the nests raised the bots' floor (modes/Egg: never lower than the lowest nest + AIM_OVER_NEST); every
        item pod stays within a bot's pickup reach of that floor, so the bots still use items."""
        egg = (ROOT / "src" / "server" / "battle" / "modes" / "Egg.luau").read_text()
        bots = (ROOT / "src" / "server" / "battle" / "BattleBots.luau").read_text()
        over = float(re.search(r"^local AIM_OVER_NEST = ([\d.]+)", egg, re.M).group(1))
        reach = float(re.search(r"plane = \{[^}]*pickup = ([\d.]+)", bots).group(1))
        b = self.gp["modes"]["battle"]
        floor = min(n["pos"][1] for n in b["nests"]) + over
        for p in b["pickupAnchors"]:
            self.assertLess(floor - p[1], reach, p)


    # ------------------------------------------------------------------------- visual critic v28 Wave 1 (look only)

    def test_ftue_arch_dropped(self):
        """1.12: the legacy FTUE arch the chase camera rode through at st ~280 is gone; the start's other arches stay."""
        self.assertNotIn("FTUEFinishArch", self.plan["prefabs"])
        for keep in ("StartForegroundArch", "MidTrackRockPillar", "StartFinishGate"):
            self.assertIn(keep, self.plan["prefabs"])

    def test_value_break_only_rematerials_the_solid_mass(self):
        """1.13: the Rock bands come straight after FillRouteBounds (nothing carved yet), lie inside its mass and start
        at least VALUE_BREAK - 1 over the deck, so they swap materials without adding or removing terrain."""
        ops = self.sk["shells"]["ops"]
        i = next(k for k, o in enumerate(ops) if o["op"] == "FillRouteBounds")
        bands = []
        for o in ops[i + 1:]:
            if o["op"] == "FillBlock" and o["mat"] == "Rock":
                bands.append(o)
            else:
                break
        self.assertGreater(len(bands), 60)
        fb = ops[i]
        P = np.array([w.pos for w in self.route.waypoints])
        lo, hi = P.min(0), P.max(0)
        m = fb["margin"]
        for b in bands:
            cf = np.array(b["cf"], float)
            axes = cf[3:12].reshape(3, 3).T
            half = np.array(b["size"], float) / 2
            corners = [cf[:3] + axes.T @ (half * np.array([sx, sy, sz])) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
            for c in corners:
                self.assertTrue(lo[0] - m <= c[0] <= hi[0] + m and lo[2] - m <= c[2] <= hi[2] + m, b)
                self.assertTrue(fb["yMin"] <= c[1] <= hi[1] + fb["above"] + 1e-6, b)
            bottom = cf[1] - half[1]
            near = P[np.argsort(np.hypot(P[:, 0] - cf[0], P[:, 2] - cf[2]))[:3]]
            self.assertGreaterEqual(bottom, near[:, 1].min() + author.VALUE_BREAK - 1, b)
        self.assertEqual(self.sk["materials"]["terrainColors"]["Rock"], author.TERRAIN_COLORS["Rock"])

    def test_hall_value_break_is_one_level(self):
        """1.13 review fix: the great hall's roof and walls break at one level (no strips where the 460-wide route bands
        happened to reach). Right after the bands, inside the mass and before the hall carve: Sandstone up to
        HALL_VALUE_BREAK, Rock above, both over the hall footprint plus a margin."""
        ops = self.sk["shells"]["ops"]
        h = next(i for i, o in enumerate(ops) if o["op"] == "FillBlock" and o["mat"] == "Air")
        sand, rock = ops[h - 2], ops[h - 1]
        self.assertEqual((sand["mat"], rock["mat"]), ("Sandstone", "Rock"))
        fb = next(o for o in ops if o["op"] == "FillRouteBounds")
        P = np.array([w.pos for w in self.route.waypoints])
        lo, hi = P.min(0), P.max(0)
        hall = ops[h]
        for o in (sand, rock):
            c, sz = np.array(o["cf"][:3], float), np.array(o["size"], float)
            for k in (0, 2):
                self.assertGreaterEqual(sz[k], hall["size"][k] + 2 * 8)  # covers the hall's wall-surface voxels
                self.assertAlmostEqual(c[k], hall["cf"][k])
                self.assertTrue(lo[k] - fb["margin"] <= c[k] - sz[k] / 2 and c[k] + sz[k] / 2 <= hi[k] + fb["margin"])
            self.assertGreaterEqual(c[1] - sz[1] / 2, fb["yMin"])
            self.assertLessEqual(c[1] + sz[1] / 2, hi[1] + fb["above"] - fb["crownThickness"] + 4 + 1e-6)
        self.assertAlmostEqual(sand["cf"][1] + sand["size"][1] / 2, author.HALL_VALUE_BREAK)
        self.assertAlmostEqual(rock["cf"][1] - rock["size"][1] / 2, author.HALL_VALUE_BREAK)

    def test_floor_fill_split_keeps_the_slab(self):
        """1.14: the floor fill covers 440..5330 once, same slab everywhere, lighter crust only in the open-lava spans."""
        fills = [o for o in self.sk["shells"]["ops"] if o["op"] == "RouteFloorFill"]
        self.assertEqual(fills[0]["fromStation"], 440)
        self.assertEqual(fills[-1]["toStation"], 5330)
        for a, b in zip(fills, fills[1:]):
            self.assertAlmostEqual(b["fromStation"] - a["toStation"], 0.001, places=6)
        for f in fills:
            self.assertEqual((f["mat"], f["depth"], f["width"], f["thickness"], f["crustMat"], f["seed"]),
                             ("CrackedLava", 44, 230, 10, "Basalt", 11))
            open_ = any(a <= f["fromStation"] and f["toStation"] <= b for a, b in author.LAVA_OPEN)
            self.assertEqual(f["crustPerSegment"], 2 if open_ else 5)

    def test_no_straight_neon_strips_or_sheets_in_the_dressing(self):
        """1.16 / ART_BAR anti-comps: dressing Neon is only thin rims (<= 0.6 tall) or small accents (<= 18 across).
        The one exception is the hall oculus's sky disc (1.15), which is the sky seen through the roof, 165+ studs up."""
        for key, pf in self.plan["prefabs"].items():
            if not key.startswith("Dress") or key == "DressHallOculus":
                continue
            for part in pf["parts"]:
                if part[11] != "Neon":
                    continue
                sx, sy, sz = part[4:7]
                rim = sy <= 0.6
                small = max(sx, sy, sz) <= 18 and max(sx, sy, sz) <= 4 * min(sx, sy, sz) + 6
                self.assertTrue(rim or small, (key, part))

    def test_lavafalls_are_narrow_streams(self):
        """1.14: the lavafall beams are streams (<= 10 wide), not vertical lava slabs, and each has a splash pool."""
        falls = [f for f in self.sk["fx"] if f.get("name", "").startswith("Lavafall_")]
        self.assertEqual(len(falls), len(author.LAVAFALLS))
        for f in falls:
            self.assertLessEqual(max(f["props"]["Width0"], f["props"]["Width1"]), 10)
        g = self.plan["groups"].index("Dressing/Lavafalls") + 1
        pools = [i for i in self.plan["instances"] if i["pf"] == "DressLavaPool" and i["g"] == g]
        self.assertEqual(len(pools), len(author.LAVAFALLS))

    def test_hall_oculus_hangs_under_the_sealed_roof(self):
        """1.15: the oculus is dressing under the roof (no terrain op opens it), high above the hall floor."""
        ops = self.sk["shells"]["ops"]
        inst = next(i for i in self.plan["instances"] if i["pf"] == "DressHallOculus")
        x, y, z = inst["p"]
        self.assertEqual(y, author.HALL_CEILING)
        self.assertTrue(self.shell.solid([[x, y + 3, z]]).all(), "roof above the oculus is solid terrain")
        self.assertFalse(self.shell.solid([[x, y - 12, z]]).any(), "the disc hangs in the hall's air")
        for part in self.plan["prefabs"]["DressHallOculus"]["parts"]:
            self.assertEqual(part[12].get("nc"), 1)
            self.assertGreater(y + part[2] - part[5] / 2, author.HALL_FLOOR + 160)
        self.assertFalse(any(o["op"] in ("FillBall", "FillBlock", "FillCylinder") and o["mat"] == "Air"
                             and abs(o.get("center", o.get("cf", [0, 0, 0]))[0] - x) < 1 and
                             abs(o.get("center", o.get("cf", [0, 0, 0]))[2] - z) < 1 for o in ops))

    # ------------------------------------------------------------------------------------------------ Wave 1b (critic v29)

    def test_wave1b_alt1_strip_becomes_a_recess_with_ember_lamps(self):
        """C4: kit/Deck's runtime Neon torch strip (Alt1TorchStrip_) is re-materialed to dark Basalt by a plan rule, and
        ember slivers (<= 1 stud across) with warm lamps run the Alt1 line every ~60 studs, all non-colliding."""
        rules = self.sk["materials"]["partRules"]
        strip = next(r for r in rules if r.get("name") == "^Alt1TorchStrip_")
        self.assertEqual(strip["setMaterial"], "Basalt")
        self.assertLess(rules.index(strip), next(i for i, r in enumerate(rules) if r.get("material") == "Sandstone"
                                                  and "prefab" not in r and "name" not in r))
        deck = (ROOT / "src" / "server" / "kit" / "Deck.luau").read_text()
        self.assertIn('id .. "TorchStrip_"', deck, "the rule must match the name kit/Deck gives the strip")
        for part in self.plan["prefabs"]["DressAlt1Ember"]["parts"]:
            self.assertEqual(part[12].get("nc"), 1)
            if part[11] == "Neon":
                self.assertLessEqual(min(part[4], part[6]), 1.0)
                self.assertGreaterEqual(part[12].get("a", 0), 0.3)
        g = self.plan["groups"].index("Dressing/Alt1Embers") + 1
        embers = [i for i in self.plan["instances"] if i["g"] == g]
        lamps = [f for f in self.sk["fx"] if f.get("name", "").startswith("Alt1Ember_")]
        pts = np.array(next(a for a in self.gp["alternates"] if a["id"] == "Alt1")["points"], float)
        length = float(np.sum(np.linalg.norm(np.diff(pts, axis=0), axis=1)))
        self.assertEqual(len(embers), len(lamps))
        self.assertGreaterEqual(len(embers), int(length / author.ALT1_EMBER_EVERY) - 1)
        for f in lamps:
            self.assertLessEqual(f["props"]["Range"], 24)

    def test_wave1b_skull_ribs_and_spires(self):
        """C2/C6/C7: bone dressing is Sandstone (plain, by prefab rules) with no SmoothPlastic ribs; the skull has no brow
        blocks, its teeth are cones and its ember cores are dim; the lavafall lips carry no Neon; the rib gates are
        marked for the client camera-near fade."""
        for key in ("DressFossilRib", "DressFossilSpine", "DressFossilSkull"):
            mats = {p[11] for p in self.plan["prefabs"][key]["parts"]}
            self.assertNotIn("SmoothPlastic", mats, key)
            self.assertTrue(any(r.get("prefab") == key and "variant" not in r for r in self.sk["materials"]["partRules"]))
        skull = self.plan["prefabs"]["DressFossilSkull"]["parts"]
        self.assertFalse([p for p in skull if p[0] == "B" and p[5] == 34 and p[6] == 7], "eyebrow blocks")
        self.assertGreaterEqual(sum(1 for p in skull if p[0] == "K"), 8)
        for p in skull:
            if p[11] == "Neon":
                self.assertGreaterEqual(p[12].get("a", 0), 0.5)
        self.assertNotIn("Neon", {p[11] for p in self.plan["prefabs"]["DressLavaLip"]["parts"]})
        falls = [f for f in self.sk["fx"] if f.get("name", "").startswith("Lavafall_")]
        self.assertTrue(all(f["props"]["Width0"] >= 8 for f in falls))
        fade = [a for a in self.sk["modelAttributes"] if a["path"] == "Dressing/Fossils"]
        self.assertEqual(fade[0]["attrs"]["CameraNearFade"], author.FOSSIL_CAMERA_FADE)

    def test_wave1b_no_warm_deck_glow_on_the_alt2_wall(self):
        """C3: no DeckEdgeGlow on the Alt2 side along the ledge (they lit the wall beside the chase camera orange)."""
        pts = np.array(next(a for a in self.gp["alternates"] if a["id"] == "Alt2")["points"], float)
        dense = np.concatenate([np.linspace(pts[i], pts[i + 1], 8) for i in range(len(pts) - 1)])
        for f in self.sk["fx"]:
            if f.get("name", "").startswith("DeckEdgeGlow_"):
                d = float(np.min(np.linalg.norm(dense - np.array(f["cf"][:3]), axis=1)))
                self.assertGreater(d, 40.0, f["name"])

    def test_set_dressing_props_stay_out_of_the_flying_space(self):
        """1.20: the PropLibrary totems, ruins and ribcages never collide and their scaled boxes stay outside the main
        flight corridor and both alternates (owner rule: the flying space does not change)."""
        lib = (ROOT / "src" / "shared" / "PropLibrary.luau").read_text()

        def size(key):
            m = re.search(key + r" = \{.*?size = Vector3\.new\(([^)]*)\)", lib, re.S)
            return np.array([float(v) for v in m.group(1).split(",")])

        sd = self.sk["setDressing"]
        self.assertGreater(len(sd), 20)
        boxes = []
        for i in range(len(self.route.waypoints) - 1):
            a, b = self.route.waypoints[i].pos, self.route.waypoints[i + 1].pos
            box = adapt.segment_box(a, b, self.sk["flight"]["corridor"]["halfWidth"], self.sk["flight"]["corridor"]["floor"],
                                    self.sk["flight"]["corridor"]["ceiling"])
            if box is not None:
                boxes.append(box)
        for alt in self.gp["alternates"]:
            tunnel = alt.get("style") == "tunnel"
            for a, b in zip(alt["points"], alt["points"][1:]):
                box = adapt.segment_box(a, b, 13 if tunnel else 20, 4, 28 if tunnel else 40)
                if box is not None:
                    boxes.append(box)
        g = np.linspace(-1, 1, 5)
        for d in sd:
            self.assertIs(d["collide"], False, d)
            half = size(d["key"]) * d["scale"] / 2
            yaw = math.radians(d["yaw"])
            R = np.array([[math.cos(yaw), 0, math.sin(yaw)], [0, 1, 0], [-math.sin(yaw), 0, math.cos(yaw)]])
            centre = np.array(d["pos"], float) + [0, half[1], 0]
            pts = np.array([centre + R @ (half * [u, v, t]) for u in g for v in g for t in g])
            for mid, axes, hb in boxes:
                hit = Shell._in_obb(pts, mid, axes, hb)
                self.assertFalse(hit.any(), (d, pts[hit][:1]))


if __name__ == "__main__":
    unittest.main()
