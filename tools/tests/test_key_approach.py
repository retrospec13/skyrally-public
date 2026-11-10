import math
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import key_route  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TRACK_DIR = {"SNOW-1": "snow1", "DINO-4": "dino4", "ISLAND-2": "island2", "FOREST-1": "forest1"}


def key_pos(track_id):
    text = (ROOT / "build" / TRACK_DIR[track_id] / "TrackData.luau").read_text(encoding="utf-8")
    m = re.search(r"hiddenKey = \{[^\n]*?pos = Vector3\.new\(([-\d.]+), ([-\d.]+), ([-\d.]+)\)", text)
    return tuple(float(g) for g in m.groups())


class KeyApproachTest(unittest.TestCase):
    def test_every_route_ends_on_the_hidden_key(self):
        for tid, entry in key_route.routes().items():
            end = entry["route"][-1][:3]
            self.assertLess(math.dist(end, key_pos(tid)), 3.0, tid)

    def test_route_is_flyable(self):
        for tid, entry in key_route.routes().items():
            r = entry["route"]
            self.assertGreaterEqual(len(r), 3, tid)
            for a, b in zip(r, r[1:]):
                self.assertLess(math.dist(a[:3], b[:3]), 130.0, f"{tid} leg too long")
                self.assertLessEqual(b[3], a[3], f"{tid} speed caps must not rise toward the key")
            self.assertLessEqual(r[-1][3], 80, f"{tid} must slow into the notch")

    def test_snow_line_stays_in_the_gorge_and_notch(self):
        r = key_route.routes()["SNOW-1"]["route"]
        for x, y, z, _v in r:
            self.assertTrue(-8120 <= x <= -7990 and -190 <= z <= 60, (x, z))
            self.assertTrue(48 <= y <= 70, y)  # under the lip (76) and clear of the floor (46)
        # the last two points are inside the slot x -8116..-8040
        self.assertTrue(all(-8116 <= p[0] <= -8040 for p in r[-2:]))

    def test_route_arg_format(self):
        arg = key_route.route_arg("snow-1")
        self.assertTrue(arg.startswith(" route=-8000:55:40:9999/"))
        self.assertEqual(key_route.route_arg("DINO-4"), "")
        self.assertNotIn(" ", arg.strip())


if __name__ == "__main__":
    unittest.main()
