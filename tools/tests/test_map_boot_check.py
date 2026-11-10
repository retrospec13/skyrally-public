"""tools/map_boot_check.py line selection (V1 D2, 2026-10-22). Offline: the Studio bridge (lane) is not imported.

The V1 run lost every [BOOT]/[MAP]/[DIRECTOR]/[SELFTEST] line on race maps: 190 AdapterStep lines filled keep[:200]
first and the ring rolled over. These pin: key lines first with their own cap, union dedupe across polls (console time
prefixes ignored), and the director `load ... ok=true errors=0` verdict.

Run: python3 -m unittest discover -s tools/tests -p 'test_map_boot_check.py'
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE)))

import map_boot_check as mbc  # noqa: E402

DIRECTOR = "[SkyRally][DIRECTOR] load space4 (SPACE-4) mode=race ok=true errors=0 built in 11.4s"
STEPS = "[SkyRally][MAP] SPACE-4 steps build wait=9.71 lighting=0.00 shells=0.59 total=11.13"


class SelectLinesTest(unittest.TestCase):
    def test_key_lines_survive_adapter_step_flood(self):
        flood = [f"[AdapterStep] SPACE-4 AdapterStep_s{i} = ok n=1 0.00s" for i in range(400)]
        lines = flood + ["[SkyRally][BOOT] phase=start t=0.00", DIRECTOR, "[SkyRally][SELFTEST] PASS: TrackRegistry_Root"]
        keep = mbc.select_lines(lines)
        self.assertEqual(keep[:3], ["[SkyRally][BOOT] phase=start t=0.00", DIRECTOR, "[SkyRally][SELFTEST] PASS: TrackRegistry_Root"])
        self.assertEqual(len(keep), 3 + mbc.KEEP_OTHER)

    def test_union_dedupes_across_polls_and_console_stamps(self):
        poll1 = ["7.0 [SkyRally][BOOT] phase=start t=0.00"]
        poll2 = ["[SkyRally][BOOT] phase=start t=0.00", "11.4 " + DIRECTOR]
        poll3 = [DIRECTOR, "[SkyRally][NAMES] pool dry: unchecked name X"]
        keep = mbc.select_lines(poll1 + poll2 + poll3)
        self.assertEqual(keep, ["[SkyRally][BOOT] phase=start t=0.00", DIRECTOR])

    def test_director_verdict(self):
        v = mbc.director_verdict(["x", DIRECTOR], "space4")
        self.assertTrue(v["ok"])
        self.assertEqual((v["id"], v["mode"], v["errors"], v["source"], v["seconds"]), ("SPACE-4", "race", 0, "built", 11.4))
        self.assertIsNone(mbc.director_verdict([DIRECTOR], "dino4"))
        bad = mbc.director_verdict(["[SkyRally][DIRECTOR] load hub0 (HUB-0) mode=hub ok=false errors=2 built in 3.0s"], "hub0")
        self.assertFalse(bad["ok"])
        self.assertEqual(bad["errors"], 2)
        cached = mbc.director_verdict(["[SkyRally][DIRECTOR] load hub0 (HUB-0) mode=hub ok=true errors=0 cached in 0.9s"], "hub0")
        self.assertEqual(cached["source"], "cached")

    def test_steps_and_phases(self):
        lines = [STEPS, "[SkyRally][BOOT] phase=first_vehicle t=12.87 player=p", "[SkyRally][BOOT] phase=first_vehicle t=99"]
        self.assertEqual(mbc.build_steps(lines), {"SPACE-4": "build wait=9.71 lighting=0.00 shells=0.59 total=11.13"})
        self.assertEqual(mbc.phases(lines), {"first_vehicle": 12.87})


if __name__ == "__main__":
    unittest.main()
