import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def body(text):
    lines = text.split("\n")
    s = next(i for i, l in enumerate(lines) if l.startswith("local ") and l.endswith(" = {"))
    e = max(i for i, l in enumerate(lines) if l == "}")
    return lines[s + 1:e]


class SplitTest(unittest.TestCase):
    def test_small_not_split(self):
        self.assertIsNone(lane.split_data_module("local t: any = {\n\ta = 1,\n}\nreturn t\n"))

    def test_big_generated_modules_split_losslessly(self):
        n = 0
        for f in sorted((ROOT / "build").glob("*/TrackData.luau")):
            text = f.read_text(encoding="utf-8")
            sp = lane.split_data_module(text, limit=100000)
            if len(text) < 100000:
                continue
            n += 1
            self.assertIsNotNone(sp, f.parent.name)
            stub, parts = sp
            self.assertLess(len(stub), lane.SOURCE_CAP)
            merged = []
            for name, src in parts:
                self.assertLess(len(src), lane.SOURCE_CAP, name)
                self.assertTrue(src.startswith("--!nonstrict\nreturn {\n") and src.endswith("\n}\n"))
                merged += body(src.replace("return {", "local x: any = {", 1))
            self.assertEqual(merged, body(text), f.parent.name)
        self.assertGreater(n, 0)

    def test_default_threshold_splits_snow1(self):
        text = (ROOT / "build/snow1/TrackData.luau").read_text(encoding="utf-8")
        self.assertGreaterEqual(len(text), lane.SPLIT_AT)
        stub, parts = lane.split_data_module(text)
        self.assertGreater(len(parts), 1)

    def test_unknown_shape_returns_none(self):
        self.assertIsNone(lane.split_data_module("x" * 200000))


    def test_builder_like_module_not_split(self):
        text = ("--!nonstrict\nlocal M = {}\nlocal data: any = {\n" + "\tk = 1,\n" * 30000
                + "}\nfunction M.build() return data end\nreturn M\n")
        self.assertIsNone(lane.split_data_module(text, limit=1000))
        real = ROOT / "build/snow1/builder_module.luau"
        if real.exists():
            self.assertIsNone(lane.split_data_module(real.read_text(encoding="utf-8")))

    def test_path_gate(self):
        self.assertTrue(lane.is_splittable_path("build/snow1/TrackData.luau"))
        self.assertFalse(lane.is_splittable_path("build/snow1/builder_module.luau"))

    def test_needs_launch_prefix(self):
        big = "--!nonstrict\nlocal x = {}\n" + "x.a = 1\n" * 40000 + "return x\n"
        self.assertGreaterEqual(len(big), lane.SOURCE_CAP)
        rel = "build/fake/builder_module.luau"
        f = lane.ROOT / rel
        orig = (lane.script_map, lane.luau, lane.Path.read_bytes)
        try:
            lane.script_map = lambda: [(["Maps", "Fake"], "ModuleScript", f)]
            lane.luau = lambda *a, **k: "ok"
            lane.Path.read_bytes = lambda self: big.encode()
            res = lane.hot_reload()
        finally:
            lane.script_map, lane.luau, lane.Path.read_bytes = orig
        self.assertTrue(res.startswith("NEEDS_LAUNCH:"), res)
        self.assertIn(rel, res)


if __name__ == "__main__":
    unittest.main()
