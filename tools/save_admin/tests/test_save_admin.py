"""Unit tests for tools/save_admin/save_admin.py against a fake Open Cloud (no network, no key).
Run: cd tools/save_admin/tests && python3 -m unittest discover -s ."""

import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import save_admin as sa  # noqa: E402

KEY = "SECRET-KEY-123"
NOW = 1800000000


class Resp:
    def __init__(self, status, body, headers=None):
        self.status, self._body, self.headers = status, body, _Headers(headers or {})

    def read(self):
        return self._body

    def getcode(self):
        return self.status


class _Headers:
    def __init__(self, d):
        self.d = d

    def items(self):
        return self.d.items()


class FakeCloud:
    """Standard + ordered DataStores with versions, matchVersion conflicts and injectable failures."""

    def __init__(self):
        self.std = {}  # (store, key) -> list of {"version", "value", "deleted"}
        self.ordered = {}  # (store, key) -> value
        self.seq = 0
        self.fail = {}  # (method, store, key) -> status
        self.throttle_once = False
        self.requests = []

    def seed(self, store, key, value):
        self.seq += 1
        self.std.setdefault((store, key), []).append({"version": "v%d" % self.seq, "value": value, "deleted": False})

    def current(self, store, key):
        rows = self.std.get((store, key)) or []
        return rows[-1] if rows and not rows[-1]["deleted"] else None

    def __call__(self, req):
        assert req.get_header("X-api-key") == KEY
        url = urllib.parse.urlparse(req.full_url)
        q = dict(urllib.parse.parse_qsl(url.query))
        method = req.get_method()
        self.requests.append((method, url.path, q, dict(req.header_items()), req.data))
        if self.throttle_once:
            self.throttle_once = False
            raise urllib.error.HTTPError(req.full_url, 429, "throttled", {}, io.BytesIO(b"TooManyRequests"))
        if "/ordered-data-stores/" in url.path:
            parts = url.path.split("/")
            store, key = urllib.parse.unquote(parts[6]), urllib.parse.unquote(parts[-1])
            st = self.fail.get((method, store, key))
            if st:
                raise urllib.error.HTTPError(req.full_url, st, "x", {}, io.BytesIO(b"fail " + KEY.encode()))
            if (store, key) not in self.ordered:
                raise urllib.error.HTTPError(req.full_url, 404, "nf", {}, io.BytesIO(b"{}"))
            del self.ordered[(store, key)]
            return Resp(200, b"{}")
        store, key = q.get("datastoreName"), q.get("entryKey")
        st = self.fail.get((method, store, key))
        if st:
            raise urllib.error.HTTPError(req.full_url, st, "x", {}, io.BytesIO(b"fail"))
        if url.path.endswith("/entries"):
            keys = sorted({k for (s, k) in self.std if s == store and self.current(s, k)})
            return Resp(200, json.dumps({"keys": [{"key": k} for k in keys]}).encode())
        if url.path.endswith("/entry/versions"):
            rows = list(reversed(self.std.get((store, key)) or []))[: int(q.get("limit", 10))]
            return Resp(200, json.dumps({"versions": [{"version": r["version"], "deleted": r["deleted"], "createdTime": "t"} for r in rows]}).encode())
        if url.path.endswith("/entry/versions/version"):
            for r in self.std.get((store, key)) or []:
                if r["version"] == q.get("versionId"):
                    return Resp(200, json.dumps(r["value"]).encode())
            raise urllib.error.HTTPError(req.full_url, 404, "nf", {}, io.BytesIO(b"{}"))
        cur = self.current(store, key)
        if method == "GET":
            if not cur:
                raise urllib.error.HTTPError(req.full_url, 404, "nf", {}, io.BytesIO(b"{}"))
            return Resp(200, json.dumps(cur["value"]).encode(), {"Roblox-Entry-Version": cur["version"]})
        if method == "POST":
            mv = q.get("matchVersion")
            if mv and (not cur or cur["version"] != mv):
                raise urllib.error.HTTPError(req.full_url, 412, "pre", {}, io.BytesIO(b"PreconditionFailed"))
            self.seed(store, key, json.loads(req.data))
            return Resp(200, b"{}")
        if method == "DELETE":
            if not cur:
                raise urllib.error.HTTPError(req.full_url, 404, "nf", {}, io.BytesIO(b"{}"))
            self.seq += 1
            self.std[(store, key)].append({"version": "v%d" % self.seq, "value": None, "deleted": True})
            return Resp(204, b"")
        raise AssertionError("unhandled " + method + " " + url.path)


def profile(**kw):
    p = {"version": 2, "tokens": {}, "gears": 0, "economy": {"receipts": {}, "oneTime": {}}, "pendingGifts": {}}
    p.update(kw)
    return p


class Base(unittest.TestCase):
    def setUp(self):
        self.cloud = FakeCloud()
        self.client = sa.Client(KEY, opener=self.cloud, sleep=lambda s: None)
        self.tmp = tempfile.mkdtemp()
        self.out = io.StringIO()
        self.log = sa.Log(path=os.path.join(self.tmp, "log.jsonl"), out=self.out, clock=lambda: NOW)

    def run_cli(self, *argv):
        return sa.main(list(argv), client=self.client, log=self.log, now=NOW)

    def logged(self):
        with open(self.log.path, encoding="utf-8") as f:
            return [json.loads(line) for line in f]

    def assertNoKey(self):
        self.assertNotIn(KEY, self.out.getvalue())
        with open(self.log.path, encoding="utf-8") as f:
            self.assertNotIn(KEY, f.read())


class RulesTest(unittest.TestCase):
    def test_lock_rules_match_save_lock_rules(self):
        self.assertEqual(sa.lock_ttl({}), 180)
        self.assertEqual(sa.lock_ttl({"ttl": 90}), 90)
        self.assertEqual(sa.lock_ttl({"ttl": 1}), 30)
        self.assertEqual(sa.lock_state({"session": {"id": "j", "lockedAt": 100, "ttl": 90}}, 150)["state"], "held")
        self.assertEqual(sa.lock_state({"session": {"id": "j", "lockedAt": 100, "ttl": 90}}, 191)["state"], "stale")
        self.assertEqual(sa.lock_state({}, 1)["state"], "free")

    def test_board_stores_and_version_read_from_the_game(self):
        boards = sa.board_stores()
        self.assertIn("SkyRallyLB_v1_stars", boards)
        self.assertIn("SkyRallyLB_v1_best_DINO-4", boards)
        self.assertEqual(len(boards), 6)
        self.assertEqual(sa.current_version(), 2)

    def test_read_key_refuses_loose_permissions(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "k.txt")
        with open(p, "w") as f:
            f.write(KEY)
        if os.name == "posix":
            os.chmod(p, 0o644)
            with self.assertRaises(SystemExit):
                sa.read_key(p)
            os.chmod(p, 0o600)
        self.assertEqual(sa.read_key(p), KEY)
        with self.assertRaises(SystemExit):
            sa.read_key(None)


class InspectTest(Base):
    def test_inspect_and_versions_are_read_only(self):
        self.cloud.seed("SkyRallyProfiles", "u_5", {"profile": profile(gears=99), "savedAt": NOW - 5,
                                                  "session": {"id": "job", "lockedAt": NOW - 5, "ttl": 90}})
        self.assertEqual(self.run_cli("inspect", "5"), 0)
        self.assertIn("lock held by job", self.out.getvalue())
        self.assertIn("cash=99", self.out.getvalue())
        self.assertEqual(self.run_cli("versions", "5"), 0)
        self.assertIn("v1", self.out.getvalue())
        self.assertTrue(all(r[0] == "GET" for r in self.cloud.requests))
        self.assertEqual([e["action"] for e in self.logged()], ["inspect", "versions"])
        self.assertNoKey()

    def test_missing_profile(self):
        self.assertEqual(self.run_cli("inspect", "6"), 0)
        self.assertIn("no saved profile", self.out.getvalue())

    def test_throttle_is_retried(self):
        self.cloud.seed("SkyRallyProfiles", "u_5", {"profile": profile()})
        self.cloud.throttle_once = True
        self.assertEqual(self.run_cli("inspect", "5"), 0)


class RestoreTest(Base):
    def seed_history(self, locked=False):
        self.cloud.seed("SkyRallyProfiles", "u_7", {"profile": profile(gears=5000)})
        bad = profile(gears=0)
        bad["economy"]["receipts"]["buy-1"] = {"at": 1, "ledger": True}
        bad["pendingGifts"]["gift-1"] = {"key": "trail"}
        rec = {"profile": bad, "savedAt": NOW - 100}
        if locked:
            rec["session"] = {"id": "job-L", "lockedAt": NOW - 10, "ttl": 90}
        self.cloud.seed("SkyRallyProfiles", "u_7", rec)

    def test_dry_run_writes_nothing(self):
        self.seed_history()
        self.assertEqual(self.run_cli("restore", "7", "v1"), 0)
        self.assertIn("DRY RUN", self.out.getvalue())
        self.assertFalse(any(r[0] == "POST" for r in self.cloud.requests))
        self.assertEqual(self.logged()[-1]["result"], "preview")

    def test_apply_restores_keeps_receipts_and_uses_match_version(self):
        self.seed_history()
        self.assertEqual(self.run_cli("restore", "7", "v1", "--apply"), 0)
        post = [r for r in self.cloud.requests if r[0] == "POST"][0]
        self.assertEqual(post[2].get("matchVersion"), "v2")
        headers = {k.lower(): v for k, v in post[3].items()}
        self.assertEqual(headers["roblox-entry-userids"], "[7]")
        self.assertIn("content-md5", headers)
        cur = self.cloud.current("SkyRallyProfiles", "u_7")["value"]
        self.assertEqual(cur["profile"]["gears"], 5000)
        self.assertIn("buy-1", cur["profile"]["economy"]["receipts"])
        self.assertIn("gift-1", cur["profile"]["pendingGifts"])
        self.assertNotIn("session", cur)
        self.assertEqual(cur["restoredFrom"]["version"], "v1")
        self.assertEqual(self.logged()[-1]["result"], "done")
        self.assertNoKey()

    def test_refused_while_online(self):
        self.seed_history(locked=True)
        self.assertEqual(self.run_cli("restore", "7", "v1", "--apply"), 2)
        self.assertIn("player is online", self.out.getvalue())
        self.assertFalse(any(r[0] == "POST" for r in self.cloud.requests))

    def test_newer_version_refused(self):
        self.cloud.seed("SkyRallyProfiles", "u_8", {"profile": profile(version=99)})
        self.cloud.seed("SkyRallyProfiles", "u_8", {"profile": profile()})
        self.assertEqual(self.run_cli("restore", "8", "v1", "--apply"), 2)
        self.assertIn("newer than the game", self.out.getvalue())

    def test_a_server_writing_between_read_and_write_wins(self):
        self.seed_history()
        real = self.cloud.__call__

        def racing(req):
            if req.get_method() == "POST":
                # A server took the lock just before our write.
                self.cloud.seed("SkyRallyProfiles", "u_7", {"profile": profile(gears=1), "session": {"id": "job-R", "lockedAt": NOW, "ttl": 90}})
            return real(req)
        self.client._open = racing
        self.assertEqual(self.run_cli("restore", "7", "v1", "--apply"), 1)
        self.assertEqual(self.cloud.current("SkyRallyProfiles", "u_7")["value"]["session"]["id"], "job-R")
        self.assertEqual(self.logged()[-1]["result"], "failed")


class EraseTest(Base):
    def seed_user(self, locked=False):
        p = profile(gears=3)
        p["economy"]["receipts"] = {"buy-1": {"at": 1}, "buy-2": {"at": 2}}
        rec = {"profile": p}
        if locked:
            rec["session"] = {"id": "job-E", "lockedAt": NOW - 1, "ttl": 90}
        self.cloud.seed("SkyRallyProfiles", "u_9", rec)
        self.cloud.seed("SkyRallyPendingGifts", "g_9", {"x": 1})
        self.cloud.seed("SkyRallyPurchaseHistory", "buy-1", {"userId": 9})
        self.cloud.seed("SkyRallyPurchaseHistory", "buy-2", {"userId": 10})
        self.cloud.seed("SkyRallyPurchaseHistory", "old-1", {"userId": 9})
        self.cloud.ordered[("SkyRallyLB_v1_stars", "9")] = 12
        self.cloud.ordered[("SkyRallyLB_v1_stars", "10")] = 13

    def test_dry_run(self):
        self.seed_user()
        self.assertEqual(self.run_cli("erase", "9"), 0)
        self.assertIn("DRY RUN", self.out.getvalue())
        self.assertFalse(any(r[0] == "DELETE" for r in self.cloud.requests))

    def test_apply_removes_everything_of_this_user_only(self):
        self.seed_user()
        self.assertEqual(self.run_cli("erase", "9", "--apply", "--scan-purchases"), 0)
        self.assertIsNone(self.cloud.current("SkyRallyProfiles", "u_9"))
        self.assertIsNone(self.cloud.current("SkyRallyPendingGifts", "g_9"))
        self.assertIsNone(self.cloud.current("SkyRallyPurchaseHistory", "buy-1"))
        self.assertIsNone(self.cloud.current("SkyRallyPurchaseHistory", "old-1"), "--scan-purchases finds older records")
        self.assertIsNotNone(self.cloud.current("SkyRallyPurchaseHistory", "buy-2"), "another buyer's record stays")
        self.assertNotIn(("SkyRallyLB_v1_stars", "9"), self.cloud.ordered)
        self.assertIn(("SkyRallyLB_v1_stars", "10"), self.cloud.ordered)
        self.assertEqual(self.logged()[-1]["result"], "done")
        self.assertNoKey()

    def test_refused_while_online(self):
        self.seed_user(locked=True)
        self.assertEqual(self.run_cli("erase", "9", "--apply"), 2)
        self.assertIsNotNone(self.cloud.current("SkyRallyProfiles", "u_9"))

    def test_partial_failure_keeps_profile_and_rerun_finishes(self):
        self.seed_user()
        self.cloud.fail[("DELETE", "SkyRallyLB_v1_stars", "9")] = 500
        self.assertEqual(self.run_cli("erase", "9", "--apply"), 1)
        self.assertIsNotNone(self.cloud.current("SkyRallyProfiles", "u_9"))
        self.assertIn("Run the same command again", self.out.getvalue())
        self.assertNoKey()
        self.cloud.fail.clear()
        self.assertEqual(self.run_cli("erase", "9", "--apply"), 0)
        self.assertIsNone(self.cloud.current("SkyRallyProfiles", "u_9"))


if __name__ == "__main__":
    unittest.main()
