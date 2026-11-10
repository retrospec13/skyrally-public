"""Unit tests for the Creator Store ("toolbox-temp") classification in tools/asset_preflight.py. Offline: no PC, no Studio.

Run: python3 -m unittest tools.tests.test_asset_preflight   (from the repo root)
  or python3 -m unittest discover -s tools/tests -p 'test_asset_preflight.py'
"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools"))

import asset_preflight as pf  # noqa: E402

HEADER = ("| asset id | title | creator (name + id) | type | where used | why | replace-by plan | added (date) |\n"
          "|---|---|---|---|---|---|---|---|\n")
GOOD = "| `111111111` | Oak tree | SomeCreator (id 4242424) | Model | map/forest1 | fills a gap | REPLACE-LATER with a Tripo tree | 2026-10-19 |\n"


def ledger(rows):
    f = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8")
    f.write("# Toolbox ledger\n\nIntro text with a | pipe | but no row.\n\n" + HEADER + rows)
    f.close()
    return f.name


def decide(i, cls, toolbox, refs=("src/x.luau:1",), asset_type="Image", expanded=None, exceptions=None, grant=True, g=None):
    a = {"class": cls, "assetType": asset_type, "grant": g}
    return pf.decide(i, a, list(refs), expanded or {}, exceptions or {}, toolbox, grant)


class ToolboxLedgerParse(unittest.TestCase):
    def test_header_and_prose_are_not_rows(self):
        path = ledger("")
        self.addCleanup(os.unlink, path)
        self.assertEqual(pf.load_toolbox_ledger(path), {})

    def test_missing_file_is_empty(self):
        self.assertEqual(pf.load_toolbox_ledger("/nonexistent/ASSETS_TOOLBOX_TEMP.md"), {})

    def test_complete_row(self):
        path = ledger(GOOD)
        self.addCleanup(os.unlink, path)
        rows = pf.load_toolbox_ledger(path)
        self.assertEqual(list(rows), ["111111111"])
        self.assertEqual(rows["111111111"]["problems"], [])

    def test_incomplete_rows_carry_problems(self):
        bad = [
            "| 222222222 | t | SomeCreator (id 1234) | Model | map | why | plan |\n",  # 7 columns
            "| 333333333 | t | SomeCreator | Model | map | why | plan | 2026-10-19 |\n",  # creator id missing
            "| 444444444 | t | SomeCreator (id 1234) | Model | map | why |  | 2026-10-19 |\n",  # no replace-by plan
            "| 555555555 | t | SomeCreator (id 1234) | Model | map | why | plan | soon |\n",  # bad date
        ]
        path = ledger("".join(bad) + GOOD + GOOD)
        self.addCleanup(os.unlink, path)
        rows = pf.load_toolbox_ledger(path)
        for i in ("222222222", "333333333", "444444444", "555555555"):
            self.assertTrue(rows[i]["problems"], i)
        self.assertIn("duplicate row", rows["111111111"]["problems"])

    def test_repo_ledger_is_complete(self):
        policy = json.loads(pf.POLICY.read_text())
        rows = pf.load_toolbox_ledger(os.path.join(REPO, policy["toolbox_temp_ledger"]))
        for i, row in rows.items():
            self.assertEqual(row["problems"], [], f"{i}: {row['problems']}")


class Decide(unittest.TestCase):
    def setUp(self):
        path = ledger(GOOD + "| 222222222 | t | SomeCreator | Model | map | why | plan | 2026-10-19 |\n")
        self.addCleanup(os.unlink, path)
        self.toolbox = pf.load_toolbox_ledger(path)

    def test_listed_creator_store_id_passes(self):
        ok, why, basis = decide("111111111", "foreign-third-party", self.toolbox)
        self.assertTrue(ok, why)
        self.assertEqual(basis, "toolbox-temp")
        self.assertIn("REPLACE-LATER", why)

    def test_unlisted_foreign_third_party_blocks(self):
        for cls in ("foreign-third-party", "foreign-or-unknown", "foreign-roblox", "lookup-failed", "lookup-missing"):
            ok, why, basis = decide("999999999", cls, self.toolbox)
            self.assertFalse(ok, cls)
            self.assertIsNone(basis)

    def test_incomplete_row_blocks(self):
        ok, why, _ = decide("222222222", "foreign-third-party", self.toolbox)
        self.assertFalse(ok)
        self.assertIn("incomplete", why)

    def test_listed_but_lookup_failed_blocks(self):
        self.assertFalse(decide("111111111", "lookup-failed", self.toolbox)[0])

    def test_listed_wrapper_must_expand(self):
        ok, why, _ = decide("111111111", "foreign-third-party", self.toolbox, asset_type="Model",
                            expanded={"111111111": {"ok": False, "err": "boom"}})
        self.assertFalse(ok)
        ok, why, _ = decide("111111111", "foreign-third-party", self.toolbox, asset_type="Model",
                            expanded={"111111111": {"ok": True, "children": {}}})
        self.assertTrue(ok, why)

    def test_child_of_listed_model_passes_but_direct_reference_does_not(self):
        child = ["child-of:111111111:MeshPart.MeshId", "runtime:Client:Workspace"]
        ok, why, basis = decide("777777777", "foreign-third-party", self.toolbox, refs=child)
        self.assertTrue(ok, why)
        self.assertEqual(basis, "toolbox-temp-child")
        ok, _, _ = decide("777777777", "foreign-third-party", self.toolbox, refs=child + ["src/x.luau:9"])
        self.assertFalse(ok)
        ok, _, _ = decide("777777777", "foreign-third-party", self.toolbox, refs=["child-of:888888888:MeshPart.MeshId"])
        self.assertFalse(ok)  # parent not in the ledger
        ok, _, _ = decide("777777777", "foreign-third-party", self.toolbox, refs=["child-of:222222222:MeshPart.MeshId"])
        self.assertFalse(ok)  # parent row incomplete

    def test_existing_paths_unchanged(self):
        self.assertTrue(decide("1", "owned-user", {}, g="granted")[0])
        self.assertFalse(decide("1", "owned-user", {}, g="failed")[0])
        self.assertTrue(decide("1", "owned-user", {}, grant=False)[0])
        self.assertTrue(decide("1", "owned-group-same-owner", {})[0])
        exc = {"1": {"class": "foreign-roblox", "reason": "r", "evidence": "e"}}
        self.assertEqual(decide("1", "foreign-roblox", {}, exceptions=exc)[2], "exception")
        self.assertFalse(decide("1", "foreign-third-party", {})[0])


class ModelBakeManifest(unittest.TestCase):
    def test_glob_scans_the_manifest(self):
        self.assertIn("build/model_bakes/manifest.json", pf.SCAN_GLOBS)

    def test_ids_are_models_and_packs_not_sizes_or_hashes(self):
        doc = {"111843268690922": {"sha256": "1234567" + "a" * 57, "packs": [98765432101234, 55555555555], "surfaceAppearances": 1,
                                   "bytes": 1234567, "baked_utc": "2026-10-19 12:00:00Z"}}
        self.assertEqual(pf.model_bake_ids(json.dumps(doc, indent=1)), {"111843268690922", "98765432101234", "55555555555"})
        self.assertEqual(pf.model_bake_ids("{}"), set())
        self.assertEqual(pf.model_bake_ids("not json"), set())


if __name__ == "__main__":
    unittest.main()
