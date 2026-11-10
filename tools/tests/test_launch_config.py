import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import launch_config_check as lc  # noqa: E402

REAL = Path(__file__).resolve().parents[2]


def fake_root(tmp, **over):
    vals = {"store": "true", "hide": "false", "storm": "true", "v2": "false", "pg": "false"}
    vals.update(over)
    (tmp / "src/shared").mkdir(parents=True)
    (tmp / "src/server").mkdir(parents=True)
    (tmp / "src/shared/MonetizationConfig.luau").write_text(f"MonetizationConfig.Enabled = {vals['store']}\nMonetizationConfig.LAUNCH_HIDE = {vals['hide']}\n")
    (tmp / "src/shared/StormConfig.luau").write_text(f"StormConfig.Enabled = {vals['storm']}\nStormConfig.RACE_V2 = {vals['v2']}\n")
    (tmp / "src/shared/RaceFlowRules.luau").write_text(f"RaceFlowRules.PER_GROUP = {vals['pg']}\n")
    (tmp / "src/server/AdminConfig.luau").write_text('AdminConfig.ADMIN_USER_ID = 42\nAdminConfig.STUDIO_ATTRIBUTE = "QAAdminStudio"\n')
    (tmp / "default.project.json").write_text(json.dumps({"tree": {"Workspace": {"$attributes": over.get("attrs", {})}}}))
    return tmp


def approved(**exp):
    e = {"store_enabled": "false", "launch_hide": "true", "storm_enabled": "true", "storm_race_v2": "false",
         "per_group_races": "false", "admin_user_id": "42", "admin_studio_attribute": "QAAdminStudio"}
    e.update(exp)
    return {"approved": True, "approved_by": "owner", "date": "2026-10-22", "expected": e}


class LaunchConfigTest(unittest.TestCase):
    def test_release_defaults_disabled_in_real_tree(self):
        r = lc.report(REAL)
        self.assertEqual(r["store_enabled"]["value"], "false")
        self.assertEqual(r["admin_user_id"]["value"], "0")
        self.assertEqual(r["launch_hide"]["value"], "true")
        self.assertEqual(r["storm_enabled"]["value"], "true")
        self.assertEqual(r["qa_attributes_preset"]["value"], "none")

    def test_real_tree_public_refused_until_owner_approves(self):
        probs = lc.check_public(lc.report(REAL), lc.load_approved(REAL))
        self.assertTrue(probs)
        self.assertIn("not owner-approved", probs[0])

    def test_matching_approved_config_passes(self):
        with tempfile.TemporaryDirectory() as t:
            r = lc.report(fake_root(Path(t), store="false", hide="true"))
            self.assertEqual(lc.check_public(r, approved()), [])

    def test_source_drift_from_approved_is_refused(self):
        with tempfile.TemporaryDirectory() as t:
            r = lc.report(fake_root(Path(t), store="true", hide="true"))
            probs = lc.check_public(r, approved())
            self.assertEqual(len(probs), 1)
            self.assertIn("store_enabled", probs[0])

    def test_launch_hide_false_never_public(self):
        with tempfile.TemporaryDirectory() as t:
            r = lc.report(fake_root(Path(t), store="false", hide="false"))
            probs = lc.check_public(r, approved(launch_hide="false"))
            self.assertTrue(any("LAUNCH_HIDE=true" in p for p in probs))

    def test_undecided_value_and_qa_attribute_refused(self):
        with tempfile.TemporaryDirectory() as t:
            r = lc.report(fake_root(Path(t), store="false", hide="true", attrs={"QAMP": True, "Other": 1}))
            probs = lc.check_public(r, approved(store_enabled=None))
            self.assertTrue(any("no owner decision" in p for p in probs))
            self.assertTrue(any("QAMP" in p for p in probs))

    def test_unapproved_flag_refused_even_when_values_match(self):
        with tempfile.TemporaryDirectory() as t:
            r = lc.report(fake_root(Path(t), store="false", hide="true"))
            a = approved()
            a["approved"] = False
            self.assertTrue(lc.check_public(r, a))


if __name__ == "__main__":
    unittest.main()
