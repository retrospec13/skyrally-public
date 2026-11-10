"""Offline tests for tools/store_create.py: dry-run plan, multipart body, name-skip logic, StorePassIds writer and the
apply flow against mocked Open Cloud responses. No network, never reads an operator credential file.

Run: python3 -m unittest tools/tests/test_store_create.py   (from the repo root)
"""
import io
import json
import os
import struct
import sys
import tempfile
import unittest
import urllib.error
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tools"))

import store_create as sc  # noqa: E402

FAKE_KEY = "TESTKEY-not-real-0123456789"


def tiny_png(path, w, h):
    raw = b"".join(b"\x00" + b"\x00\x00\x00" * w for _ in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class FakeResp:
    def __init__(self, status, body):
        self.status, self._body = status, body

    def read(self):
        return self._body

    def getcode(self):
        return self.status


class FakeApi:
    """Routes (method, path-without-query) to queued (status, json-able body) answers and records requests."""

    def __init__(self, routes):
        self.routes = {k: list(v) for k, v in routes.items()}
        self.requests = []

    def __call__(self, req):
        path = req.full_url[len(sc.API):].split("?")[0]
        self.requests.append((req.get_method(), path, dict(req.header_items()), req.data))
        queue = self.routes.get((req.get_method(), path))
        if not queue:
            raise AssertionError("unexpected call %s %s" % (req.get_method(), path))
        status, body = queue.pop(0) if len(queue) > 1 else queue[0]
        raw = body if isinstance(body, bytes) else json.dumps(body).encode()
        if status >= 400:
            raise urllib.error.HTTPError(req.full_url, status, "err", {}, io.BytesIO(raw))
        return FakeResp(status, raw)


PASS_TEXT = """local StorePassIds = {}

StorePassIds.PASS_IDS = {
\tx2Gears = nil :: number?, -- pass named "2x Cash"
\tgaragePlus = nil :: number?, -- pass named "Garage+"
} :: { [string]: number? }

return StorePassIds
"""


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        for it in sc.ITEMS:
            tiny_png(os.path.join(self.tmp, it["icon"]), 512, 512)
        self.plan = sc.build_plan(icon_dir=self.tmp)
        self.pass_file = os.path.join(self.tmp, "StorePassIds.luau")
        with open(self.pass_file, "w") as f:
            f.write(PASS_TEXT)
        self.out_json = os.path.join(self.tmp, "out", "store_writes.json")


class TestPlan(Base):
    def test_exactly_six_items_none_forbidden(self):
        sc.validate_items()
        self.assertEqual([i["name"] for i in sc.ITEMS],
                         ["500 Cash", "1,200 Cash", "3,500 Cash", "8,000 Cash", "Win Pass Premium", "2x Cash"])
        self.assertEqual([i["price"] for i in sc.ITEMS], [49, 99, 249, 499, 199, 399])
        self.assertEqual([i["kind"] for i in sc.ITEMS].count("Pass"), 1)

    def test_forbidden_name_refused(self):
        bad = list(sc.ITEMS[:5]) + [{**sc.ITEMS[5], "name": "Garage+"}]
        with self.assertRaises(SystemExit):
            sc.validate_items(bad)

    def test_dry_run_plan_ok_icons(self):
        self.assertTrue(all(p["iconProblem"] is None for p in self.plan))
        buf = io.StringIO()
        sc.print_plan(self.plan, buf)
        text = buf.getvalue()
        self.assertIn("universe 0", text)
        self.assertIn('"8,000 Cash"', text)
        self.assertEqual(text.count("icon OK 512x512"), 6)

    def test_icon_checks(self):
        p = os.path.join(self.tmp, "small.png")
        tiny_png(p, 256, 256)
        self.assertEqual(sc.check_icon(p), "is 256x256, need 512x512")
        self.assertEqual(sc.check_icon(os.path.join(self.tmp, "nope.png")), "missing or not a PNG")
        jpg = os.path.join(self.tmp, "x.png")
        with open(jpg, "wb") as f:
            f.write(b"\xff\xd8\xff" + b"0" * 40)
        self.assertEqual(sc.check_icon(jpg), "missing or not a PNG")

    def test_real_icons_in_repo(self):
        for p in sc.build_plan():
            self.assertIsNone(p["iconProblem"], p["icon"])


class TestMultipart(unittest.TestCase):
    def test_body(self):
        body, ctype = sc.multipart([("name", "1,200 Cash"), ("isForSale", True), ("price", 99)],
                                   [("imageFile", "a.png", b"\x89PNGdata", "image/png")], boundary="BND")
        self.assertEqual(ctype, "multipart/form-data; boundary=BND")
        self.assertIn(b'--BND\r\nContent-Disposition: form-data; name="name"\r\n\r\n1,200 Cash\r\n', body)
        self.assertIn(b'name="isForSale"\r\n\r\ntrue\r\n', body)
        self.assertIn(b'name="price"\r\n\r\n99\r\n', body)
        self.assertIn(b'name="imageFile"; filename="a.png"\r\nContent-Type: image/png\r\n\r\n\x89PNGdata\r\n', body)
        self.assertTrue(body.endswith(b"--BND--\r\n"))


class TestNames(unittest.TestCase):
    def test_normalize_matches_storebinding(self):
        self.assertEqual(sc.normalize("  500   CASH "), "500 cash")
        self.assertEqual(sc.normalize(None), "")

    def test_find_existing(self):
        listed = [{"name": "500 cash", "productId": 111}, {"name": "Other", "productId": 222}]
        self.assertEqual(sc.find_existing(listed, "500 Cash", "productId")[0], 111)
        self.assertEqual(sc.find_existing(listed, "8,000 Cash", "productId"), (None, None, None))
        dup = listed + [{"name": "500 Cash ", "productId": 333}]
        idv, _, problem = sc.find_existing(dup, "500 Cash", "productId")
        self.assertIsNone(idv)
        self.assertIn("2 existing", problem)
        self.assertIsNotNone(sc.find_existing([{"name": "500 Cash", "productId": 0}], "500 Cash", "productId")[2])


class TestPassIds(unittest.TestCase):
    def test_writes_only_x2gears(self):
        new = sc.write_pass_id(PASS_TEXT, 987654321)
        self.assertIn("\tx2Gears = 987654321 :: number?, -- pass named \"2x Cash\"", new)
        self.assertIn("\tgaragePlus = nil :: number?,", new)
        self.assertEqual(sc.write_pass_id(new, 987654321), new)
        self.assertIn("x2Gears = 5 :: number?,", sc.write_pass_id(new, 5))

    def test_refuses_non_id(self):
        for bad in (None, 0, -3, "abc", 1.5, True):
            with self.assertRaises(ValueError):
                sc.write_pass_id(PASS_TEXT, bad)

    def test_real_file_has_line(self):
        with open(sc.PASS_IDS_FILE) as f:
            sc.write_pass_id(f.read(), 1)


def dp(u=sc.UNIVERSE_ID):
    return "/developer-products/v2/universes/%d/developer-products" % u


def gp(u=sc.UNIVERSE_ID):
    return "/game-passes/v1/universes/%d/game-passes" % u


class TestApply(Base):
    def run_apply(self, api):
        client = sc.Client(FAKE_KEY, opener=api, sleep=lambda s: None)
        out = io.StringIO()
        rep = sc.run_apply(client, self.plan, pass_ids_file=self.pass_file, out_json=self.out_json, out=out)
        return rep, out.getvalue()

    def test_creates_missing_skips_existing(self):
        routes = {
            ("GET", dp() + "/creator"): [(200, {"developerProducts": [{"name": "500 Cash", "productId": 1001, "iconImageAssetId": 5001}],
                                                "nextPageToken": ""})],
            ("GET", gp() + "/creator"): [(200, {"gamePasses": []})],
            ("POST", dp()): [(200, {"productId": 1002}), (200, {"productId": 1003}), (200, {"productId": 1004}), (200, {"productId": 1005})],
            ("POST", gp()): [(200, {"gamePassId": 7007, "iconAssetId": 8008})],
        }
        for pid in (1002, 1003, 1004, 1005):
            routes[("PATCH", "%s/%d" % (dp(), pid))] = [(204, b"")]
        for pid in (1001, 1002, 1003, 1004, 1005):
            routes[("GET", "%s/%d/creator" % (dp(), pid))] = [(200, {"productId": pid, "iconImageAssetId": pid + 4000,
                                                                     "priceInformation": {"defaultPriceInRobux": 49}})]
        routes[("GET", "%s/7007/creator" % gp())] = [(200, {"gamePassId": 7007, "iconAssetId": 8008, "priceInformation": {"defaultPriceInRobux": 399}})]
        api = FakeApi(routes)
        rep, text = self.run_apply(api)
        actions = [r["action"] for r in rep["items"]]
        self.assertEqual(actions, ["existing", "created", "created", "created", "created", "created"])
        posts = [r for r in api.requests if r[0] == "POST"]
        self.assertEqual(len(posts), 5)
        self.assertNotIn(b"\r\n\r\n500 Cash\r\n", b"".join(p[3] for p in posts))
        pass_post = [p for p in posts if p[1] == gp()][0]
        self.assertIn(b'name="imageFile"; filename="cash_x2.png"', pass_post[3])
        self.assertIn(b'name="price"\r\n\r\n399', pass_post[3])
        for p in posts:
            self.assertTrue(p[2]["Content-type"].startswith("multipart/form-data; boundary="))
        self.assertEqual(len([r for r in api.requests if r[0] == "PATCH"]), 4)
        with open(self.pass_file) as f:
            self.assertIn("x2Gears = 7007 :: number?", f.read())
        self.assertEqual(len(rep["proof"]), 6)
        self.assertIn("PROOF 2x Cash | id=7007 | universe=0 | key=waku | icon=8008 | price=399 R$ | created", text)
        self.assertIn("SUMMARY: 6/6", text)
        with open(self.out_json) as f:
            self.assertNotIn(FAKE_KEY, f.read())
        self.assertNotIn(FAKE_KEY, text)

    def test_4xx_stops_item_no_retry_no_invented_id(self):
        body = {"errorCode": "Forbidden", "message": "echo " + FAKE_KEY}
        routes = {
            ("GET", dp() + "/creator"): [(200, {"developerProducts": []})],
            ("GET", gp() + "/creator"): [(200, {"gamePasses": []})],
            ("POST", dp()): [(403, body)],
            ("POST", gp()): [(400, {"message": "bad image"})],
        }
        api = FakeApi(routes)
        rep, text = self.run_apply(api)
        self.assertTrue(all(r["action"] == "STOPPED" and r["id"] is None for r in rep["items"]))
        self.assertEqual(len([r for r in api.requests if r[0] == "POST"]), 6)  # one each, no retries
        self.assertEqual(rep["items"][0]["errors"][0]["status"], 403)
        self.assertIn("<redacted>", rep["items"][0]["errors"][0]["body"])
        with open(self.pass_file) as f:
            self.assertEqual(f.read(), PASS_TEXT)
        self.assertIn("x2Gears pass id NOT written", text)
        self.assertNotIn(FAKE_KEY, text)

    def test_5xx_retried_once(self):
        routes = {("GET", dp() + "/creator"): [(503, {"m": "down"}), (503, {"m": "down"})],
                  ("GET", gp() + "/creator"): [(500, {}), (200, {"gamePasses": [{"name": "2X cash", "gamePassId": "4242", "iconAssetId": 9}]})],
                  ("GET", gp() + "/4242/creator"): [(200, {"gamePassId": 4242, "iconAssetId": 9})]}
        api = FakeApi(routes)
        rep, _ = self.run_apply(api)
        self.assertEqual(len([r for r in api.requests if r[1] == dp() + "/creator"]), 2)
        self.assertEqual(rep["listErrors"][0]["status"], 503)
        self.assertEqual([r["action"] for r in rep["items"]], ["STOPPED"] * 5 + ["existing"])
        with open(self.pass_file) as f:
            self.assertIn("x2Gears = 4242 :: number?", f.read())

    def test_key_file_mode(self):
        p = os.path.join(self.tmp, "k.txt")
        with open(p, "w") as f:
            f.write(FAKE_KEY + "\n")
        os.chmod(p, 0o644)
        with self.assertRaises(SystemExit):
            sc.read_key(p)
        os.chmod(p, 0o600)
        self.assertEqual(sc.read_key(p), FAKE_KEY)


if __name__ == "__main__":
    unittest.main()
