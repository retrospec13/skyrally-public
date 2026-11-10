import datetime as dt
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import qa_hooks  # noqa: E402
import gamepad_probe  # noqa: E402

NOON = dt.datetime(2026, 10, 21, 12, 5, 0, tzinfo=dt.timezone.utc)


class QaHooks(unittest.TestCase):
    def test_fault(self):
        self.assertEqual(qa_hooks.build(["fault", "load"]), [("QASaveFault", "load"), ("QASaveFaultCount", None)])
        self.assertEqual(qa_hooks.build(["fault", "save", "2"]), [("QASaveFault", "save"), ("QASaveFaultCount", 2)])
        self.assertEqual(qa_hooks.build(["fault", "none"])[0], ("QASaveFault", None))
        for bad in (["fault"], ["fault", "x"], ["fault", "load", "0"], ["fault", "load", "abc"]):
            with self.assertRaises(SystemExit):
                qa_hooks.build(bad)

    def test_saveas(self):
        self.assertEqual(qa_hooks.build(["saveas", "123456"]), [("QASaveAs", 123456)])
        for bad in (["saveas"], ["saveas", "0"], ["saveas", "x"], ["saveas", "1.5"]):
            with self.assertRaises(SystemExit):
                qa_hooks.build(bad)

    def test_utc(self):
        self.assertEqual(qa_hooks.parse_utc("1790000000"), 1790000000)
        self.assertEqual(qa_hooks.parse_utc("12:29:50", NOON), int(NOON.replace(minute=29, second=50).timestamp()))
        self.assertEqual(qa_hooks.parse_utc("2026-10-21T23:59:50Z"), int(dt.datetime(2026, 10, 21, 23, 59, 50, tzinfo=dt.timezone.utc).timestamp()))
        self.assertEqual(qa_hooks.build(["utc", "off"]), [("QAUtcAt", None)])
        for bad in ("25:00:00", "noon", "12:61"):
            with self.assertRaises(ValueError):
                qa_hooks.parse_utc(bad)

    def test_liveops_and_lua(self):
        self.assertEqual(qa_hooks.build(["liveops", "memory", "on"]), [("QALiveOpsMemory", True)])
        lua = qa_hooks.lua_for([("QASaveFault", "load"), ("QASaveFaultCount", 2), ("QALiveOpsMemory", None)])
        self.assertIn("SetAttribute('QASaveFault', 'load')", lua)
        self.assertIn("SetAttribute('QASaveFaultCount', 2)", lua)
        self.assertIn("SetAttribute('QALiveOpsMemory', nil)", lua)

    def test_signature_compare(self):
        self.assertTrue(qa_hooks.same_signature("a\n", "a"))
        self.assertFalse(qa_hooks.same_signature("a", "b"))


class GamepadVerdict(unittest.TestCase):
    def test_blocked_on_error(self):
        v, why = gamepad_probe.classify('ERROR {"message":"Invalid key_code ButtonA"}', [{"px": 0}])
        self.assertEqual(v, "BLOCKED")
        self.assertIn("Invalid key_code", why)

    def test_blocked_when_nothing_reacts(self):
        self.assertEqual(gamepad_probe.classify("ok", [{"px": 0, "last": "Keyboard"}])[0], "BLOCKED")
        self.assertEqual(gamepad_probe.classify("ok", [])[0], "BLOCKED")

    def test_partial_and_works(self):
        self.assertEqual(gamepad_probe.classify("ok", [{"px": 1, "last": "Keyboard"}])[0], "PARTIAL")
        self.assertEqual(gamepad_probe.classify("ok", [{"px": 0.8, "last": "Gamepad1"}])[0], "WORKS")


if __name__ == "__main__":
    unittest.main()
