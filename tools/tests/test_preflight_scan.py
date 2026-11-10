"""Strict offline preflight scan: unledgered ids fail unless they carry a validated upload record (D1)."""
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import preflight_scan as ps  # noqa: E402


class StrictScan(unittest.TestCase):
    def _repo(self, tmp, sha_ok=True):
        glb = Path(tmp) / "assets/models/x/a/a.glb"
        glb.parent.mkdir(parents=True)
        glb.write_bytes(b"glb")
        sha = hashlib.sha256(b"glb").hexdigest() if sha_ok else "0" * 64
        (Path(tmp) / "assets/models/x/uploaded.json").write_text(json.dumps(
            {"a": {"model": 111, "sha256": sha, "file": "assets/models/x/a/a.glb", "name": "n"}}))

    def test_recorded_id_is_pending_not_failure(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(ps, "REPO", Path(tmp)):
            self._repo(tmp)
            self.assertEqual(ps.split_unseen(["111", "222"]), (["111"], ["222"]))

    def test_changed_file_loses_the_record(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(ps, "REPO", Path(tmp)):
            self._repo(tmp, sha_ok=False)
            self.assertEqual(ps.split_unseen(["111"]), ([], ["111"]))

    def test_gate_runs_strict(self):
        gate = (Path(__file__).resolve().parent.parent / "gate.sh").read_text()
        self.assertIn("preflight_scan.py --strict", gate)


if __name__ == "__main__":
    unittest.main()
