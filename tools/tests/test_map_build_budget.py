"""Map build budget guard (V1 D1, 2026-10-22). Offline: no PC, no Studio.

SPACE-4 reached first control in 12.55-12.87 s in Studio (L42 limit 12 s, T01 10 s): its compiled builder yielded one
server frame per 50 prefab instances (65 yields for 3268 instances, about 0.1-0.15 s each while a map loads in Studio).
The builder now yields by work time (YIELD_SLICE). This test pins that, the terrain-hash scope that let the change keep
the terrain bakes, and a per-map size budget: a map that grows past it needs its L42 boot re-measured (tools/
map_boot_check.py <key>, the "[MAP] <id> steps build wait=..." and "[DIRECTOR] load ... built in" lines) and the budget
raised here with that number. The runtime half is DirectorFailsafeRules.BUILD_BUDGET ("[DIRECTOR] build_budget over").

Run: python3 -m unittest discover -s tools/tests -p 'test_map_build_budget.py'
"""
import json
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools", "map30"))

import build_plan  # noqa: E402

# Builder size per map (compiled 30MAPS art: prefab instances and their parts). Measured 2026-10-22 (v34 stage):
# SPACE-4 3268 / 10180 is the largest. Raise only with a fresh Studio boot measurement under the L42 limit.
MAX_INSTANCES = 4000
MAX_PARTS = 12000


def mounted_builders():
    with open(os.path.join(REPO, "default.project.json"), encoding="utf-8") as f:
        maps = json.load(f)["tree"]["ServerScriptService"]["Maps"]
    return {k: os.path.join(REPO, v["$path"]) for k, v in maps.items() if isinstance(v, dict) and "$path" in v}


def plan_data(src):
    m = re.search(r"JSONDecode\(\[==\[(.*?)\]==\]\)", src, re.S)
    return json.loads(m.group(1))


class MapBuildBudgetTest(unittest.TestCase):
    def test_template_yields_by_time_not_by_count(self):
        with open(os.path.join(REPO, "tools", "map30", "builder_template.luau"), encoding="utf-8") as f:
            tpl = f.read()
        loop = tpl[tpl.index("for i, inst in DATA.instances do"):tpl.index("-- markers + labels")]
        self.assertIn("if os.clock() - sliceT0 >= YIELD_SLICE then", loop)
        self.assertNotRegex(loop, r"i %\s*\d+ == 0 then\s*task\.wait\(\)", "a fixed-count yield is back in the loop")
        m = re.search(r"local YIELD_SLICE = ([0-9.]+)", tpl)
        self.assertIsNotNone(m)
        self.assertTrue(0.03 <= float(m.group(1)) <= 0.2, "slice keeps the server frame bounded and the yields few")

    def test_every_builder_is_current_with_the_template(self):
        for key, path in mounted_builders().items():
            with open(path, encoding="utf-8") as f:
                src = f.read()
            self.assertIn("local YIELD_SLICE = ", src, f"{key}: regenerate with tools/map/adapt.py map/{key}/plan.json")

    def test_terrain_hash_covers_only_the_terrain_code(self):
        with open(os.path.join(REPO, "tools", "map30", "builder_template.luau"), encoding="utf-8") as f:
            tpl = f.read()
        code = build_plan.terrain_code(tpl)
        self.assertIn("local function buildTerrain(t)", code)
        self.assertIn("pcall(buildTerrain, DATA.terrain)", code)
        self.assertNotIn("for i, inst in DATA.instances do", code)
        data = {"terrain": {"nx": 1, "nz": 1}}
        self.assertEqual(build_plan.terrain_hash(tpl, data),
                         build_plan.terrain_hash(tpl + "\n-- an instance-loop change\n", data))

    def test_builder_size_budget(self):
        for key, path in mounted_builders().items():
            with open(path, encoding="utf-8") as f:
                data = plan_data(f.read())
            n = len(data["instances"])
            parts = data["partCount"]
            self.assertLessEqual(n, MAX_INSTANCES, f"{key}: {n} instances; re-measure the L42 boot, then raise the budget")
            self.assertLessEqual(parts, MAX_PARTS, f"{key}: {parts} parts; re-measure the L42 boot, then raise the budget")


if __name__ == "__main__":
    unittest.main()
