#!/usr/bin/env python3
"""adapt.py gates and TrackData emission on a synthetic circular plan.
Run: python3 -m unittest discover -s tools/map/tests -v"""
import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import fixtures
import adapt
import route

LUNE = shutil.which("lune") or shutil.which(str(Path.home() / ".local" / "bin" / "lune"))
LUAU_LSP = shutil.which("luau-lsp") or shutil.which(str(Path.home() / ".local" / "bin" / "luau-lsp"))
LOADER = fixtures.TESTS / "load_trackdata.luau"


def codes(plan):
    return adapt.check(plan).report.codes()


class Gates(unittest.TestCase):
    def test_clean_plan_passes(self):
        res = adapt.check(fixtures.circle_plan())
        self.assertEqual(res.report.errors, [])
        self.assertEqual(len(res.route.waypoints), 12 * 9 + 1)
        self.assertLessEqual(abs(res.route.length - 2700), 1)
        self.assertEqual(res.gates["corridorPartIntrusions"], 0)
        self.assertEqual(res.gates["collidableParts"], 3)  # Pillar, Spire cone + base; the nc Glow is skipped
        self.assertGreater(res.gates["minRadius"], 85)

    def test_bot_pace_optional(self):
        # M-5 (L7): absent = no field in the data (1.0 in the game); present and sane passes; junk is an error.
        plan = fixtures.circle_plan()
        self.assertNotIn("botPace", plan["skyrally"])
        self.assertEqual(adapt.check(plan).report.errors, [])
        plan["skyrally"]["botPace"] = 0.92
        self.assertEqual(adapt.check(plan).report.errors, [])
        for bad in (0, -1, "fast", 5, True):
            plan["skyrally"]["botPace"] = bad
            self.assertIn("skyrally.field", codes(plan), repr(bad))

    def test_bad_shape(self):
        plan = fixtures.circle_plan()
        plan["prefabs"]["Pillar"]["parts"][0][0] = "X"
        self.assertIn("part.shape", codes(plan))

    def test_part_fields_colour_material(self):
        plan = fixtures.circle_plan()
        plan["prefabs"]["Short"] = {"parts": [["B", 0, 0, 0, 1, 1, 1, 0, 0, 0, "#ffffff"]]}
        plan["prefabs"]["Pillar"]["parts"][0][10] = "red"
        plan["prefabs"]["Pillar"]["parts"][0][11] = "Lava"
        self.assertTrue({"part.fields", "part.colour", "part.material"} <= codes(plan))

    def test_missing_prefab_and_group(self):
        plan = fixtures.circle_plan()
        plan["instances"].append({"pf": "Nope", "p": [0, 0, 0]})
        plan["instances"].append({"pf": "Pillar", "p": [0, 0, 0], "g": 3})
        c = codes(plan)
        self.assertIn("prefab.unknown", c)
        self.assertIn("instance.group", c)

    def test_intruding_collidable_part(self):
        plan = fixtures.circle_plan()
        r = adapt.check(plan).route
        f = r.frame_at(300)
        # Pillar part spans p.y .. p.y + 20, here ribbon +15 .. +35, inside the corridor (ribbon +5 .. +44)
        plan["instances"].append({"pf": "Pillar", "p": [f.pos[0], f.pos[1] + 15, f.pos[2]], "g": 1})
        res = adapt.check(plan)
        self.assertIn("corridor.intrusion", res.report.codes())
        hits = res.gates["intrusions"]
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["prefab"], "Pillar")
        self.assertEqual(hits[0]["instance"], len(plan["instances"]))
        self.assertTrue(250 <= hits[0]["station"] <= 300, hits[0])
        self.assertIn("prefab Pillar", [e.msg for e in res.report.errors if e.code == "corridor.intrusion"][0])

    def test_part_below_corridor_floor_passes(self):
        plan = fixtures.circle_plan()
        f = adapt.check(plan).route.frame_at(300)
        # Top face 1 stud under the corridor floor (ribbon + 5)
        plan["instances"].append({"pf": "Pillar", "p": [f.pos[0], f.pos[1] - 16, f.pos[2]], "g": 1})
        self.assertNotIn("corridor.intrusion", codes(plan))

    def test_nc_part_ignored_until_collidable(self):
        plan = fixtures.circle_plan()
        self.assertNotIn("corridor.intrusion", codes(plan))
        plan["prefabs"]["Glow#a"]["parts"][0][12] = {}
        res = adapt.check(plan)
        self.assertEqual([h["prefab"] for h in res.gates["intrusions"]], ["Glow#a"])

    def test_too_tight_route(self):
        plan = fixtures.circle_plan(radius=40, target=250)
        plan["instances"] = []
        plan["skyrally"]["route"]["radiusExceptions"] = []
        self.assertIn("route.radius", codes(plan))

    def test_radius_exception_suppresses(self):
        plan = fixtures.circle_plan(radius=40, target=250)
        plan["instances"] = []
        plan["skyrally"]["route"]["radiusExceptions"] = [{"from": 0, "to": 400, "reason": "whole loop"}]
        self.assertNotIn("route.radius", codes(plan))

    def test_length_off_target(self):
        plan = fixtures.circle_plan(target=9000)  # flexScaleMax 3.5 cannot stretch the circle that far
        self.assertIn("route.length", codes(plan))

    def test_station_outside_loop(self):
        plan = fixtures.circle_plan()
        plan["skyrally"]["gameplay"]["rings"][0]["station"] = 2700.5
        plan["skyrally"]["gameplay"]["pads"][0]["station"] = -1
        errs = [e for e in adapt.check(plan).report.errors if e.code == "gameplay.station"]
        self.assertEqual(len(errs), 2)

    def test_start_grid_back_row_inside_loop(self):
        plan = fixtures.circle_plan()
        plan["skyrally"]["gameplay"]["startGrid"]["station"] = 2690  # back row at 2690 + 84 wraps past the line
        errs = [e.msg for e in adapt.check(plan).report.errors if e.code == "gameplay.station"]
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("startGrid slot 8", errs[0])

    def test_start_grid_camera_clearance(self):
        # Grid-order regression: the old plane grid (rows 14, lanes 8) and car grid (rows 16, lanes 9) put the racer one
        # row behind the player inside the chase camera; the new spacing clears every player slot.
        for vehicle, old, new in (("plane", (14, 8), (28, 12)), ("car", (16, 9), (22, 11))):
            bad = adapt.grid_camera_clearance({"station": 18, "rowSpacing": old[0], "laneOffset": old[1]}, vehicle)
            self.assertIn((4, 2, "near"), [(k, j, kind) for k, j, kind, _ in bad], vehicle)
            self.assertEqual(adapt.grid_camera_clearance(
                {"station": 18, "rowSpacing": new[0], "laneOffset": new[1]}, vehicle), [], vehicle)
        # Plane lanes 8 wide: the pole plane sits in the sightline of a player beside it (slot 2), and vice versa
        tight = adapt.grid_camera_clearance({"station": 18, "rowSpacing": 28, "laneOffset": 8}, "plane")
        self.assertEqual(sorted((k, j, kind) for k, j, kind, _ in tight), [(1, 2, "sightline"), (2, 1, "sightline")])
        plan = fixtures.circle_plan()
        plan["skyrally"]["gameplay"]["startGrid"]["rowSpacing"] = 14
        self.assertIn("startGrid.camera", codes(plan))

    def test_start_grid_width(self):
        plan = fixtures.circle_plan()
        plan["skyrally"]["gameplay"]["startGrid"]["laneOffset"] = 27  # wingtip at 35 > corridor halfWidth 34
        self.assertIn("startGrid.width", codes(plan))
        # A car grid is held to the deck, and to a narrower deck zone over the grid stations
        plan = fixtures.circle_plan()
        plan["skyrally"]["vehicle"] = "car"
        plan["skyrally"]["gameplay"]["startGrid"].update(rowSpacing=22, laneOffset=11)
        plan["skyrally"]["deck"]["zones"][0]["width"] = 32
        self.assertNotIn("startGrid.width", codes(plan))  # side at 14.15 on a 32-wide deck
        plan["skyrally"]["deck"]["zones"][0]["width"] = 22  # the start zone narrows to 22: off the deck
        self.assertIn("startGrid.width", codes(plan))

    def test_bad_types_report_not_raise(self):
        # Art errors leave the route valid, so the corridor gate still runs over the broken entries
        plan = fixtures.circle_plan()
        plan["prefabs"]["Pillar"]["parts"][0][0] = ["B"]
        plan["prefabs"]["Pillar"]["parts"][0][11] = {"m": "Rock"}
        plan["prefabs"]["Spire"]["parts"][1][7] = "tilt"
        plan["instances"].append({"pf": ["Pillar"], "p": [0, 0, 0]})
        plan["instances"].append({"pf": "Pillar", "p": [0, 0, 0], "r": [1, 2], "s": "big"})
        plan["skyrally"]["shells"] = [{"op": "Clear"}]
        plan["skyrally"]["fx"] = {"class": "Beam"}
        res = adapt.check(plan)
        self.assertIsNotNone(res.route)
        self.assertIn("corridorSegments", res.gates)
        self.assertTrue({"part.shape", "part.material", "part.number", "prefab.unknown", "instance.r", "instance.s",
                         "shells.op", "fx.field"} <= res.report.codes())
        plan = fixtures.circle_plan()
        plan["skyrally"]["route"]["radiusExceptions"] = {"from": 0, "to": 10}
        self.assertIn("route.field", codes(plan))

    def test_nc_follows_luau_truthiness(self):
        plan = fixtures.circle_plan()
        plan["prefabs"]["Glow#a"]["parts"][0][12] = {"nc": 0}  # `extra.nc` is truthy in the template
        self.assertEqual(adapt.check(plan).gates["collidableParts"], 3)

    def test_flight_allow_pockets(self):
        """FLIGHT_GUIDE.md 12: optional secret-route volumes; well-formed spheres and capsules pass, anything the runtime
        (FlightGuideRules.cleanPocket) would drop is a gate failure."""
        plan = fixtures.circle_plan()
        self.assertNotIn("flight.allowPockets", codes(plan), "absent: fine")
        plan["skyrally"]["flight"]["allowPockets"] = []
        self.assertNotIn("flight.allowPockets", codes(plan), "empty: fine")
        plan["skyrally"]["flight"]["allowPockets"] = [
            {"kind": "sphere", "center": [0, 100, 0], "radius": 60, "note": "cave mouth"},
            {"kind": "capsule", "a": [0, 90, 0], "b": [300, 90, 0], "radius": 40},
        ]
        self.assertNotIn("flight.allowPockets", codes(plan))
        for bad in ({"kind": "sphere", "center": [0, 0], "radius": 10}, {"kind": "cube", "center": [0, 0, 0], "radius": 9},
                    {"kind": "capsule", "a": [0, 0, 0], "radius": 9}, {"kind": "sphere", "center": [0, 0, 0], "radius": 0},
                    {"kind": "sphere", "center": [0, 0, 0], "radius": 201}, "junk"):
            plan["skyrally"]["flight"]["allowPockets"] = [bad]
            self.assertIn("flight.allowPockets", codes(plan), bad)
        plan["skyrally"]["flight"]["allowPockets"] = [{"kind": "sphere", "center": [i, 0, 0], "radius": 5} for i in range(17)]
        self.assertIn("flight.allowPockets", codes(plan), "at most 16")
        plan["skyrally"]["flight"]["allowPockets"] = {"kind": "sphere"}
        self.assertIn("flight.allowPockets", codes(plan), "must be a list")

    def test_mesh_asset_id_must_be_integer(self):
        plan = fixtures.circle_plan()
        plan["skyrally"]["meshes"][0]["model"] = 98086222919300.0
        self.assertIn("mesh.model", codes(plan))


class PartBounds(unittest.TestCase):
    def test_yaw_scale_and_offset(self):
        plan = {"prefabs": {"Bar": {"parts": [["B", 5, 0, 0, 10, 2, 2, 0, 0, 0, "#ffffff", "Rock"]]}},
                "instances": [{"pf": "Bar", "p": [100, 0, 0], "r": 90, "s": 2}]}
        c, h, meta = adapt.collidable_parts(plan)
        # CFrame.Angles(0, pi/2, 0) maps +X to -Z; scale 2 about the pivot doubles offset and size
        self.assertTrue(route.mag(route.sub(tuple(c[0]), (100, 0, -10))) < 1e-9)
        self.assertTrue(route.mag(route.sub(tuple(h[0]), (2, 2, 10))) < 1e-9)
        self.assertEqual(meta[0], {"prefab": "Bar", "instance": 1, "part": 1})

    def test_yxz_order(self):
        # fromEulerAnglesYXZ(rx, ry, rz) = Ry * Rx * Rz: local +Y pitches to +Z, then yaws to +X (Rx * Ry gives +Z)
        m = adapt.rot_yxz(90, 90, 0)
        y_world = m @ [0, 1, 0]
        self.assertTrue(all(abs(a - b) < 1e-9 for a, b in zip(y_world, (1, 0, 0))))


def run_main(args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        rc = adapt.main(args)
    return rc, out.getvalue()


class Emission(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="adapt_test_"))
        self.plan_path = self.tmp / "test1" / "plan.json"
        self.plan_path.parent.mkdir()
        self.plan_path.write_text(json.dumps(fixtures.circle_plan(), indent=1))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def emit(self, name="out", extra=()):
        out = self.tmp / name
        rc, log = run_main([str(self.plan_path), "--build-dir", str(out), *extra])
        return rc, log, out

    def test_trackdata_content(self):
        rc, log, out = self.emit(extra=["--no-compile"])
        self.assertEqual(rc, 0, log)
        text = (out / "TrackData.luau").read_text()
        self.assertTrue(text.startswith("--!nonstrict\n-- GENERATED"))
        wp_block = text[text.index("\twaypoints = {"):text.index("\tdeck = ")]
        self.assertEqual(wp_block.count("pos = Vector3.new("), 109)
        grid = text[text.index("\tstartGrid = {"):text.index("\tfinish = ")]
        self.assertEqual(grid.count("CFrame.new("), 8)
        self.assertIn('coinId = nil', text)
        self.assertIn('coinId = "c1"', text)
        self.assertIn("model = 98086222919300", text)  # integer literal: asset_preflight's scan requires it
        self.assertIn('compiler = "not run (--no-compile)"', text)
        self.assertIn("corridorPartIntrusions = 0", text)
        self.assertFalse((out / "builder.server.luau").exists())

    def test_trackdata_geometry(self):
        rc, log, out = self.emit(extra=["--no-compile"])
        self.assertEqual(rc, 0, log)
        text = (out / "TrackData.luau").read_text()
        r = adapt.check(fixtures.circle_plan()).route
        # Ring_1: station 300, lateral 4, height 14
        m = re.search(r'name = "Ring_1", station = 300, cf = CFrame\.new\(([^)]*)\)', text)
        c = [float(v) for v in m.group(1).split(",")]
        f = r.frame_at(300)
        want = f.cframe(f.offset(4, 14))
        self.assertTrue(all(abs(a - b) < 6e-5 for a, b in zip(c, want)))
        # Legacy FlightServer grid: slot 2 beside the pole on the right lane, rows of two further down the route,
        # slot 8 three rows (3 * 28) ahead on the right; nothing behind the line at station 0
        grid = re.findall(r"CFrame\.new\(([^)]*)\)", text[text.index("\tstartGrid = {"):text.index("\tfinish = ")])
        for slot, station, lateral in ((1, 0, 0), (2, 0, 12), (3, 28, -12), (8, 84, 12)):
            got = [float(v) for v in grid[slot - 1].split(",")]
            f = r.frame_at(station)
            self.assertTrue(all(abs(a - b) < 6e-5 for a, b in zip(got, f.cframe(f.offset(lateral, 11)))), slot)

    def test_fx_props_stay_raw(self):
        # A NumberSequence keypoint [t, v, envelope] is not a Vector3; MapAdapter converts props by property type
        plan = fixtures.circle_plan()
        plan["skyrally"]["fx"][1]["props"]["Transparency"] = {"seq": [[0, 0.88, 0], [1, 0.99, 0]]}
        self.plan_path.write_text(json.dumps(plan))
        rc, log, out = self.emit(extra=["--no-compile"])
        self.assertEqual(rc, 0, log)
        text = (out / "TrackData.luau").read_text()
        fx = text[text.index("\tfx = {"):text.index("\tframing = ")]
        self.assertIn("seq = {\n", fx)
        self.assertIn("{ 0, 0.8800, 0 }", fx)
        self.assertNotIn("Vector3.new(0, 0.8800, 0)", fx)
        self.assertIn("a0 = Vector3.new(0, 110, 0)", fx)  # geometry outside props is still converted

    def test_deterministic(self):
        rc1, log1, a = self.emit("a", ["--no-compile"])
        rc2, log2, b = self.emit("b", ["--no-compile"])
        self.assertEqual((rc1, rc2), (0, 0), log1 + log2)
        self.assertEqual((a / "TrackData.luau").read_bytes(), (b / "TrackData.luau").read_bytes())

    def test_gate_failure_writes_nothing(self):
        plan = fixtures.circle_plan()
        plan["instances"].append({"pf": "Nope", "p": [0, 0, 0]})
        self.plan_path.write_text(json.dumps(plan))
        rc, log, out = self.emit(extra=["--no-compile"])
        self.assertEqual(rc, 1)
        self.assertIn("GATE  prefab.unknown", log)
        self.assertFalse((out / "TrackData.luau").exists())

    def stub(self, body):
        p = self.tmp / "stub_compiler.py"
        p.write_text(textwrap.dedent(body))
        return p

    def test_compile_path_with_stub(self):
        stub = self.stub("""
            import json, sys, pathlib
            a = sys.argv[1:]
            out = pathlib.Path(a[a.index("--out") + 1])
            (out / "builder.server.luau").write_text("-- stub")
            pathlib.Path(a[a.index("--project") + 1]).write_text(json.dumps({"argv": a}))
        """)
        rc, log, out = self.emit(extra=["--compiler", str(stub)])
        self.assertEqual(rc, 0, log)
        argv = json.loads((out / "map.project.json").read_text())["argv"]
        self.assertEqual(argv[0], str(self.plan_path.resolve()))
        self.assertEqual(argv[argv.index("--name") + 1], "TEST-1")
        self.assertEqual(argv[argv.index("--out") + 1], str(out.resolve()))
        self.assertTrue((out / "TrackData.luau").exists())

    def test_compile_failure_stops(self):
        stub = self.stub("import sys; sys.exit(4)")
        rc, log, out = self.emit(extra=["--compiler", str(stub)])
        self.assertEqual(rc, 3, log)
        self.assertFalse((out / "TrackData.luau").exists())

    @unittest.skipUnless(adapt.COMPILER.is_file(), "vendored compiler tools/map30/build_plan.py not present")
    def test_vendored_compiler(self):
        rc, log, out = self.emit()
        self.assertEqual(rc, 0, log)
        self.assertTrue((out / "builder.server.luau").stat().st_size > 0)
        self.assertTrue((out / "map.project.json").exists())
        self.assertIn("tools/map30", (out / "TrackData.luau").read_text())

    @unittest.skipUnless(LUNE, "lune not installed")
    def test_luau_loads_in_lune(self):
        rc, log, out = self.emit(extra=["--no-compile"])
        self.assertEqual(rc, 0, log)
        p = subprocess.run([LUNE, "run", str(LOADER), str(out / "TrackData.luau"), "109"],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(p.stdout.startswith("OK 109 2700.0000"), p.stdout)

    @unittest.skipUnless(LUAU_LSP, "luau-lsp not installed")
    def test_luau_lsp_analyze(self):
        rc, log, out = self.emit(extra=["--no-compile"])
        self.assertEqual(rc, 0, log)
        env = dict(os.environ, PATH=str(Path.home() / ".local" / "bin") + os.pathsep + os.environ.get("PATH", ""))
        p = subprocess.run(["bash", str(fixtures.ROOT / "tools" / "check_luau.sh"), str(out / "TrackData.luau")],
                           capture_output=True, text=True, timeout=120, env=env)
        self.assertIn("LUAU_ERRORS=0", p.stdout, p.stdout + p.stderr)


class TerrainBounds(unittest.TestCase):
    """L42: TrackData.terrainBounds is the compiled builder's terrain box (tools/map30 buildTerrain), for the map cache."""

    def test_no_grid_is_empty(self):
        self.assertEqual(adapt.terrain_bounds(fixtures.circle_plan()), {"empty": True})

    def test_grid_snapped_with_roof_and_water(self):
        plan = {"terrain": {"nx": 3, "nz": 2, "cell": 10, "x0": -21, "z0": 6, "floor": -10, "top": 50, "roof": 61,
                            "water": {"level": 70}, "heights": [0] * 6}}
        tb = adapt.terrain_bounds(plan)
        # x -21..-1 -> -24..0, z 6..16 -> 4..16, y floor4(-10) - 4 = -16 .. ceil4(70) + 8 = 80 (water above the roof)
        self.assertEqual((str(tb["min"]), str(tb["max"])), ("Vector3.new(-24, -16, 4)", "Vector3.new(0, 80, 16)"))
        plan["terrain"]["water"]["lava"] = True  # lava is not written as terrain water: the roof is the top
        self.assertEqual(str(adapt.terrain_bounds(plan)["max"]), "Vector3.new(0, 72, 16)")


if __name__ == "__main__":
    unittest.main()
