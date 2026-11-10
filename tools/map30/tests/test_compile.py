#!/usr/bin/env python3
"""Tests for the vendored 30MAPS compiler (tools/map30) and its SkyRally patches.

Run: python3 -m unittest discover -s tools/map30/tests -v
Static checks always run. The Luau checks need luau-lsp and lune (on PATH or in ~/.local/bin) and skip without
them; the negative controls compile with the read-only 30MAPS clone (MAP30_CLONE, default ./external/30MAPS)
and skip without it.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MAP30 = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(MAP30))
BUILD_PLAN = os.path.join(MAP30, "build_plan.py")
HARNESS = os.path.join(HERE, "run_builder.luau")
DEFINITIONS = os.path.join(REPO, "tools", "luau-types", "globalTypes.d.luau")
CLONE = os.environ.get("MAP30_CLONE", "./external/30MAPS")
CLONE_BUILD_PLAN = os.path.join(CLONE, "tools", "build_plan.py")

NAME = "DINO-4"
READY = "MapBuilt_DINO_4"  # "-" is not legal in a Roblox attribute name
FAIL_X = 10  # the harness fails PivotTo for the instance placed at this X on its second run

# 2 prefabs (a cylinder; a part with nc/a/l), 3 instances, 2 groups, minimal terrain without "cell",
# a Spawn marker and a lighting block that the patched builder must both ignore
PLAN = {
    "prefabs": {
        "SauropodTieredPedestal": {"parts": [
            ["C", 0, 1, 0, 10, 2, 10, 0, 0, 0, "#c98a5a", "Sandstone"],
            ["B", 0, 3, 0, 4, 2, 4, None, None, None, "#808080", "Slate"],
        ]},
        "lamp#1": {"parts": [
            ["B", 1, 1, 0, 1, 2, 1, 0, 0, 0, "#ffcc00", "Neon", {"nc": 1, "a": 0.3, "l": [90, 2, "#ffcc00", True]}],
        ]},
    },
    "instances": [
        {"pf": "SauropodTieredPedestal", "p": [0, 10, 0], "g": 1},
        {"pf": "lamp#1", "p": [FAIL_X, 5, 0], "g": 2, "r": 90, "s": 2},
        {"pf": "lamp#1", "p": [-10, 5, 0], "g": 2, "r": [0, 45, 0]},
    ],
    "groups": ["Landmarks", "VolcanoCaldera/StartVista"],
    "terrain": {"nx": 1, "nz": 1},
    "markers": [{"kind": "Spawn", "p": [0, 50, 0], "size": [20, 1, 20], "face": [1, 0]}],
    "lighting": {"clockTime": 3, "brightness": 9, "atmosphere": {"density": 0.9}, "lights": {"on": False}},
}


def find_tool(name):
    return shutil.which(name) or shutil.which(name, path=os.path.expanduser("~/.local/bin"))


def compile_plan(build_plan, plan_path, out, project, name=NAME, extra=()):
    args = [sys.executable, build_plan, plan_path]
    if out is not None:
        args += ["--out", out]
    if project is not None:
        args += ["--project", project]
    if name is not None:
        args += ["--name", name]
    return subprocess.run(args + list(extra), capture_output=True, text=True)


def import_build_plan():
    sys.dont_write_bytecode = True
    sys.path.insert(0, MAP30)
    try:
        import build_plan
    finally:
        sys.path.remove(MAP30)
    return build_plan


def code_only(src):
    """Luau source without the embedded plan blob and comments, so checks only see executable code."""
    src = re.sub(r"\[==\[.*?\]==\]", "[==[]==]", src, flags=re.S)
    src = re.sub(r"--\[(=*)\[.*?\]\1\]", "", src, flags=re.S)
    return re.sub(r"--[^\n]*", "", src)


def embedded_data(src):
    return json.loads(re.search(r"JSONDecode\(\[==\[(.*?)\]==\]\)", src, flags=re.S).group(1))


def stock_root_destroy(code):
    return re.search(r'FindFirstChild\("Map"\)', code) or re.search(r"\bworkspace\.Map\b", code, flags=re.I)


class Workdir(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="map30_test_")
        cls.plan_path = os.path.join(cls.tmp, "plan.json")
        with open(cls.plan_path, "w") as f:
            json.dump(PLAN, f)
        cls.out = os.path.join(cls.tmp, "build", "dino4")
        cls.project = os.path.join(cls.out, "map.project.json")
        cls.builder = os.path.join(cls.out, "builder.server.luau")
        cls.result = compile_plan(BUILD_PLAN, cls.plan_path, cls.out, cls.project)
        if cls.result.returncode == 0:
            with open(cls.builder) as f:
                cls.src = f.read()
            cls.code = code_only(cls.src)
            with open(cls.project) as f:
                cls.proj = json.load(f)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.assertEqual(self.result.returncode, 0, self.result.stderr + self.result.stdout)


class CompileTest(Workdir):
    def test_outputs_exist(self):
        self.assertTrue(os.path.isfile(self.builder))
        self.assertTrue(os.path.isfile(self.project))
        self.assertFalse(os.path.exists(os.path.join(self.out, "overview.client.luau")))
        self.assertIn(f"root       Workspace.Maps.{NAME} (ready: workspace.{READY})", self.result.stdout)
        self.assertIn("ignored    lighting block: yes, Spawn markers: 1", self.result.stdout)

    def test_missing_cell_defaults_to_4(self):
        self.assertIn("terrain    1x1 nodes, cell 4", self.result.stdout)
        self.assertEqual(embedded_data(self.src)["terrain"], {"nx": 1, "nz": 1, "cell": 4})

    def test_embedded_packed_subset(self):
        data = embedded_data(self.src)
        self.assertEqual(data["name"], NAME)
        self.assertEqual(sorted(data), ["groups", "instances", "labels", "lighting", "markers", "name", "partCount",
                                        "prefabs", "terrain"])
        self.assertEqual([p["key"] for p in data["prefabs"]], ["SauropodTieredPedestal", "lamp#1"])
        self.assertEqual(len(data["instances"]), 3)
        self.assertEqual(data["partCount"], 4)
        # null rotations become 0 so the Luau array keeps 12 slots
        self.assertEqual(data["prefabs"][0]["parts"][1][7:10], [0, 0, 0])

    def test_root_is_maps_name(self):
        self.assertIn('local mapFolder = replaceFolder(ensureFolder(workspace, "Maps"), DATA.name)', self.code)
        self.assertIsNone(stock_root_destroy(self.code))

    def test_ready_attributes(self):
        self.assertIn(f'local READY_ATTR = "{READY}"', self.code)
        self.assertIn("workspace:SetAttribute(READY_ATTR, false)", self.code)
        tail = self.code[self.code.index('mapFolder:SetAttribute("MapBuildErrors", buildErrors)'):]
        # root attributes before the Workspace flag, then the unchanged DONE line
        self.assertLess(tail.index('mapFolder:SetAttribute("MapBuilt", true)'),
                        tail.index("workspace:SetAttribute(READY_ATTR, true)"))
        self.assertLess(tail.index("workspace:SetAttribute(READY_ATTR, true)"), tail.index('"DONE %s:'))
        self.assertNotIn('workspace:SetAttribute("MapBuilt"', self.code)
        self.assertEqual(self.code.count("buildErrors += 1"), 2)  # terrain FAILED + per-instance failure

    def test_lighting_not_applied(self):
        self.assertEqual(len(re.findall(r"\bapplyLighting\(", self.code)), 1)  # the definition only
        self.assertIn("DATA.lighting = nil", self.code)

    def test_spawn_ignored(self):
        self.assertNotIn("SpawnLocation", self.code)
        self.assertNotRegex(self.code, r"\bspawn\.(CFrame|Size|Anchored)\b")

    def test_templates_per_map(self):
        self.assertIn('replaceFolder(ensureFolder(ServerStorage, "30MAPS_Templates"), DATA.name)', self.code)

    def test_project_has_no_streaming_or_spawn(self):
        text = json.dumps(self.proj)
        self.assertNotIn("StreamingEnabled", text)
        self.assertNotIn("SpawnLocation", text)
        self.assertEqual(self.proj["tree"]["Workspace"], {"$className": "Workspace"})
        self.assertEqual(self.proj["name"], NAME)
        mb = self.proj["tree"]["ServerScriptService"]["MapBuilder"]["$path"]
        self.assertTrue(os.path.samefile(os.path.join(os.path.dirname(self.project), mb), self.builder))


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="map30_cli_")
        self.out = os.path.join(self.tmp, "out")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, plan):
        path = os.path.join(self.tmp, "plan.json")
        with open(path, "w") as f:
            json.dump(plan, f)
        return path

    def test_terrain_still_required(self):
        plan = {k: v for k, v in PLAN.items() if k != "terrain"}
        r = compile_plan(BUILD_PLAN, self.write(plan), self.out, os.path.join(self.out, "p.json"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("has no 'terrain'", r.stderr)

    def test_out_project_name_required(self):
        path = self.write(PLAN)
        for kw in ({"out": None}, {"project": None}, {"name": None}):
            args = {"out": self.out, "project": os.path.join(self.out, "p.json"), "name": NAME, **kw}
            r = compile_plan(BUILD_PLAN, path, args["out"], args["project"], args["name"])
            self.assertEqual(r.returncode, 2, kw)
        self.assertFalse(os.path.exists(os.path.join(MAP30, "..", "build_output")))
        self.assertFalse(os.path.exists(os.path.join(MAP30, "..", "default.project.json")))

    def test_ready_attribute_rule(self):
        build_plan = import_build_plan()
        self.assertEqual(build_plan.ready_attribute("DINO-4"), "MapBuilt_DINO_4")
        self.assertEqual(build_plan.ready_attribute("SPACE4"), "MapBuilt_SPACE4")
        self.assertEqual(build_plan.ready_attribute("Hub Loop"), "MapBuilt_Hub_Loop")

    def test_source_label_repo_relative(self):
        # committed builders must not depend on where the repo is checked out
        build_plan = import_build_plan()
        self.assertEqual(build_plan.source_label(os.path.join(REPO, "map", "dino4", "plan.json")), "map/dino4/plan.json")
        outside = os.path.join(self.tmp, "plan.json")
        self.assertEqual(build_plan.source_label(outside), os.path.abspath(outside))

    def test_bad_markers_and_labels_fail_compile(self):
        # the builder indexes these without a pcall; a bad one would stop it before the readiness attribute
        cases = [
            ({"markers": [{"kind": "Checkpoint", "index": 1}]}, "marker 1 (Checkpoint)"),
            ({"markers": [{"kind": "Teleport", "p": [0, 1, 0], "name": {"x": 1}}]}, "marker 1 (Teleport)"),
            ({"markers": [7]}, "marker 1: not an object"),
            ({"labels": [{"p": [0, 1, 0]}]}, "label 1"),
            ({"labels": [{"text": "Start", "p": [0, 1]}]}, "label 1"),
            ({"markers": {"kind": "Spawn"}}, "'markers' must be a list"),
        ]
        for patch, msg in cases:
            r = compile_plan(BUILD_PLAN, self.write({**PLAN, **patch}), self.out, os.path.join(self.out, "p.json"))
            self.assertEqual(r.returncode, 1, patch)
            self.assertIn(msg, r.stderr, patch)
        self.assertFalse(os.path.exists(os.path.join(self.out, "builder.server.luau")))

    def test_null_lists_and_unchecked_kinds_compile(self):
        plan = {**PLAN, "markers": [{"kind": "Spawn"}, {"kind": "Objective", "p": [1, 2, 3], "index": 2}],
                "labels": None, "groups": None}
        r = compile_plan(BUILD_PLAN, self.write(plan), self.out, os.path.join(self.out, "p.json"))
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(self.out, "builder.server.luau")) as f:
            data = embedded_data(f.read())
        self.assertEqual((data["labels"], data["groups"], len(data["markers"])), ([], [], 2))


@unittest.skipUnless(find_tool("luau-lsp"), "luau-lsp not installed")
class LuauAnalyzeTest(Workdir):
    def analyze(self, path):
        r = subprocess.run([find_tool("luau-lsp"), "analyze", f"--definitions={DEFINITIONS}", path],
                           capture_output=True, text=True, cwd=REPO)
        out = r.stdout + r.stderr
        return [l for l in out.splitlines() if re.search(r"SyntaxError|TypeError|UnknownGlobal", l)]

    def test_builder_analyzes_clean(self):
        self.assertEqual(self.analyze(self.builder), [])

    def test_overview_analyzes_clean(self):
        out = os.path.join(self.tmp, "ov")
        r = compile_plan(BUILD_PLAN, self.plan_path, out, os.path.join(out, "p.json"), extra=["--overview-cam"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.analyze(os.path.join(out, "overview.client.luau")), [])


@unittest.skipUnless(find_tool("lune"), "lune not installed")
class LuneRuntimeTest(Workdir):
    """Runs the generated builder twice in one lune DataModel (second run with one injected instance failure)."""

    @classmethod
    def run_harness(cls, builder, *extra):
        r = subprocess.run([find_tool("lune"), "run", HARNESS, builder, NAME, READY, str(FAIL_X), *extra],
                           capture_output=True, text=True, cwd=REPO)
        if r.returncode != 0:
            raise AssertionError(r.stdout + r.stderr)
        return json.loads(r.stdout.strip().splitlines()[-1])

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        if cls.result.returncode == 0:
            cls.obs = cls.run_harness(cls.builder)

    def assert_untouched(self, s):
        self.assertTrue(s["ok"], s.get("err"))
        self.assertEqual(s["mapsChildren"], [NAME, "OTHER"])
        self.assertTrue(s["stockMapSentinel"])
        self.assertTrue(s["otherMapIntact"])
        self.assertEqual(s["spawnCFrame"], [1, 2, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1])
        self.assertEqual(s["spawnSize"], [6, 1, 6])
        self.assertTrue(s["spawnParented"])
        self.assertEqual(s["lightingChildren"], ["Atmosphere", "BloomEffect"])
        self.assertAlmostEqual(s["atmosphereDensity"], 0.42, places=5)
        self.assertAlmostEqual(s["clockTime"], 14.5, places=5)
        self.assertAlmostEqual(s["brightness"], 2.2, places=5)
        self.assertEqual(s["serverStorageChildren"], ["30MAPS_Templates"])
        self.assertEqual(s["templateRootChildren"], [NAME, "OTHER"])
        self.assertEqual(s["templatesForMap"], ["SauropodTieredPedestal", "lamp"])
        self.assertEqual(s["otherTemplates"], ["Keep"])
        self.assertIsNone(s.get("staleTemplateParent"))
        self.assertIsNone(s.get("globalMapBuilt"))
        self.assertEqual(s["rootClass"], "Folder")
        self.assertEqual(s["rootChildren"], ["Landmarks", "Markers", "VolcanoCaldera"])
        self.assertTrue(s["rootMapBuilt"])
        self.assertTrue(s["ready"])
        self.assertIn("[30MAPS] plan lighting block ignored", "\n".join(s["logs"]))
        self.assertIn("[30MAPS] 1 Spawn marker(s) ignored", "\n".join(s["logs"]))
        self.assertTrue(s["logs"][-1].startswith("print [30MAPS] DONE DINO-4: 3/3 instances"), s["logs"][-1])

    def test_first_build(self):
        s = self.obs["first"]
        self.assert_untouched(s)
        self.assertEqual(s["rootErrors"], 0)
        self.assertFalse([l for l in s["logs"] if l.startswith("warn")])
        models = {(m["name"], tuple(m["pivot"][:3])): m for m in s["models"]}
        self.assertEqual(len(models), 3)
        ped = models[("SauropodTieredPedestal", (0, 10, 0))]
        self.assertEqual(ped["path"], f"Workspace.Maps.{NAME}.Landmarks")
        cyl = ped["parts"][0]
        self.assertEqual((cyl["shape"], cyl["size"], cyl["cf"][:3]), ("Cylinder", [2, 10, 10], [0, 11, 0]))
        self.assertEqual(cyl["material"], "Sandstone")
        # Size (sy, sx, sz) turned 90 degrees about Z so the plan's Y axis is the cylinder axis
        self.assertEqual([round(v, 6) for v in cyl["cf"][3:]], [0, -1, 0, 1, 0, 0, 0, 0, 1])
        # lamp#1: Name strips the #suffix, Prefab keeps it; yaw 90 and scale 2 about the pivot
        lamp = models[("lamp", (FAIL_X, 5, 0))]
        self.assertEqual(lamp["prefab"], "lamp#1")
        self.assertEqual(lamp["path"], f"Workspace.Maps.{NAME}.VolcanoCaldera.StartVista")
        p = lamp["parts"][0]
        self.assertEqual([round(v, 4) for v in p["cf"][:3]], [FAIL_X + 0, 7, -2])
        self.assertEqual(p["size"], [2, 4, 2])
        self.assertFalse(p["canCollide"])
        self.assertFalse(p["canTouch"])
        self.assertAlmostEqual(p["transparency"], 0.3, places=5)
        # range clamped to 60 and doubled scale stays clamped; lights.on=false from the ignored block has no effect
        self.assertEqual(p["light"], {"range": 60, "brightness": 2, "enabled": True, "shadows": True})

    def test_rebuild_with_failure(self):
        s = self.obs["second"]
        self.assert_untouched(s)
        self.assertEqual(s["rootErrors"], 1)
        self.assertEqual(len(s["models"]), 2)
        warns = [l for l in s["logs"] if l.startswith("warn")]
        self.assertEqual(len(warns), 2, warns)
        self.assertIn("instance 2 failed", warns[0])
        self.assertIn("finished with 1 build error(s)", warns[1])


class SourceTxtTest(unittest.TestCase):
    """SOURCE.txt must describe the files as they are (INFRASTRUCTURE: no unrecorded edits to the vendored copy)."""

    def setUp(self):
        with open(os.path.join(MAP30, "SOURCE.txt")) as f:
            self.text = f.read()

    def test_recorded_hashes_match_vendored_files(self):
        rows = re.findall(r"(?m)^(\S+)\s+([0-9a-f]{64}) -> ([0-9a-f]{64})", self.text)
        self.assertEqual(sorted(r[0] for r in rows),
                         ["NOTES.md", "build_plan.py", "builder_template.luau", "overview_template.luau"])
        for name, _, vendored in rows:
            with open(os.path.join(MAP30, name), "rb") as f:
                self.assertEqual(hashlib.sha256(f.read()).hexdigest(), vendored, name)
        self.assertIn("aa9a4519513aa8dec9abf5151f657d22a41611fa", self.text)

    def test_every_diff_hunk_is_marked(self):
        generated = self.text.split("----- BEGIN GENERATED")[1]
        hunks = re.split(r"(?m)^@@ ", generated)[1:]
        self.assertGreater(len(hunks), 0)
        for h in hunks:
            added = [l for l in h.splitlines()[1:] if l.startswith("+")]
            self.assertTrue(any("SKYRALLY PATCH" in l for l in added), h.splitlines()[0])

    @unittest.skipUnless(os.path.isdir(os.path.join(CLONE, ".git")), "30MAPS clone not present")
    def test_source_txt_current_against_clone(self):
        r = subprocess.run([sys.executable, os.path.join(MAP30, "source_txt.py"), "--clone", CLONE, "--check"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


@unittest.skipUnless(os.path.isfile(CLONE_BUILD_PLAN), "30MAPS clone not present")
class StockNegativeControlTest(unittest.TestCase):
    """The same checks against the unpatched aa9a451 compiler must fail, so the tests above are not vacuous."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="map30_stock_")
        plan_path = os.path.join(cls.tmp, "plan.json")
        plan = json.loads(json.dumps(PLAN))
        plan["terrain"]["cell"] = 4  # aa9a451 raises KeyError without it
        with open(plan_path, "w") as f:
            json.dump(plan, f)
        cls.out = os.path.join(cls.tmp, "out")
        cls.project = os.path.join(cls.out, "map.project.json")
        cls.result = compile_plan(CLONE_BUILD_PLAN, plan_path, cls.out, cls.project)
        cls.builder = os.path.join(cls.out, "builder.server.luau")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_static_checks_detect_stock(self):
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        with open(self.builder) as f:
            code = code_only(f.read())
        self.assertIsNotNone(stock_root_destroy(code))
        self.assertEqual(len(re.findall(r"\bapplyLighting\(", code)), 2)
        self.assertIn("SpawnLocation", code)
        with open(self.project) as f:
            text = f.read()
        self.assertIn("StreamingEnabled", text)
        self.assertIn("SpawnLocation", text)

    @unittest.skipUnless(find_tool("lune"), "lune not installed")
    def test_harness_detects_stock(self):
        moved = LuneRuntimeTest.run_harness(self.builder)["first"]
        self.assertNotEqual(moved["spawnCFrame"][:3], [1, 2, 3])  # stock moves the game's SpawnLocation
        s = LuneRuntimeTest.run_harness(self.builder, "--no-spawn")["first"]
        self.assertTrue(s["ok"], s.get("err"))
        self.assertFalse(s["stockMapSentinel"])  # Workspace.Map destroyed and rebuilt
        self.assertAlmostEqual(s["clockTime"], 3, places=5)  # plan lighting applied
        self.assertNotIn("BloomEffect", s["lightingChildren"])
        self.assertTrue(s["globalMapBuilt"])
        self.assertIsNone(s.get("ready"))
        # stock adds another ServerStorage.30MAPS_Templates per run and never clears the old one
        self.assertEqual(s["serverStorageChildren"], ["30MAPS_Templates", "30MAPS_Templates"])
        self.assertEqual(s["templatesForMap"], ["Stale"])


if __name__ == "__main__":
    unittest.main()
