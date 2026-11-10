#!/usr/bin/env python3
"""Optional catalog planner. Dry-run by default; live operations require explicit environment opt-in.
No API calls are made by importing this module. Tests inject a synthetic transport.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import stat
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

UNIVERSE_ID = int(os.environ.get("SKYRALLY_UNIVERSE_ID", "0"))
KEY_LABEL = "waku"
KEY_PATH = os.environ.get("SKYRALLY_API_KEY_FILE", "")
API = "https://apis.roblox.com"
TIMEOUT = 30
ICON_DIR = os.path.join(REPO, "assets", "store_icons")
OUT_JSON = os.path.join(REPO, "out", "store_writes.json")
PASS_IDS_FILE = os.path.join(REPO, "src", "shared", "StorePassIds.luau")

# The six launch items. Names must equal MonetizationConfig labels (StoreBinding binds dev products by name).
ITEMS = [
    {"key": "gearsPack1", "kind": "DevProduct", "name": "500 Cash", "price": 49, "icon": "cash_500.png",
     "description": "500 Cash for the Garage shop."},
    {"key": "gearsPack2", "kind": "DevProduct", "name": "1,200 Cash", "price": 99, "icon": "cash_1200.png",
     "description": "1,200 Cash for the Garage shop."},
    {"key": "gearsPack3", "kind": "DevProduct", "name": "3,500 Cash", "price": 249, "icon": "cash_3500.png",
     "description": "3,500 Cash for the Garage shop."},
    {"key": "gearsPack4", "kind": "DevProduct", "name": "8,000 Cash", "price": 499, "icon": "cash_8000.png",
     "description": "8,000 Cash for the Garage shop."},
    {"key": "winPassPremiumS1", "kind": "DevProduct", "name": "Win Pass Premium", "price": 199, "icon": "win_pass_premium.png",
     "description": "Unlock the premium column of the Season 1 Win Pass. Wins still have to be earned."},
    {"key": "x2Gears", "kind": "Pass", "name": "2x Cash", "price": 399, "icon": "cash_x2.png",
     "description": "Double the Cash you earn from every race, boss, coin challenge and Storm Cup. "
                    "Cosmetic currency only: no speed or item advantage."},
]

# Never created by this tool (docs/STORE_PRODUCTS_TO_CREATE.md "Do not create"). Checked so a future edit of ITEMS
# cannot slip one in.
FORBIDDEN = {
    "garage+", "rookie pack", "founder pack", "season 1 tint", "season 1 tints x3", "season 1 set (all 6)",
    "ember trail", "frost trail", "prism trail", "aurora trail", "gift: founder pack", "gift: season 1 tint",
    "gift: season 1 tints x3", "gift: season 1 set", "gift: win pass premium",
}


def normalize(name) -> str:
    """Same rule as src/shared/StoreBinding.luau normalize: trim, collapse inner whitespace, lower case."""
    if not isinstance(name, str):
        return ""
    return re.sub(r"\s+", " ", name.strip()).lower()


def validate_items(items=ITEMS):
    if len(items) != 6:
        raise SystemExit("refusing: ITEMS must hold exactly the six launch rows")
    for it in items:
        if normalize(it["name"]) in FORBIDDEN:
            raise SystemExit("refusing: %r is on the do-not-create list" % it["name"])
    names = [normalize(it["name"]) for it in items]
    if len(set(names)) != len(names):
        raise SystemExit("refusing: duplicate item names")


# ------------------------------------------------------------------------------------------------ icons

def png_size(path):
    """(width, height) of a PNG file, or None when the file is missing or not a PNG."""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
    except OSError:
        return None
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", head[16:24])


def check_icon(path):
    """None when the icon is a 512x512 PNG, else the problem as text."""
    size = png_size(path)
    if size is None:
        return "missing or not a PNG"
    if size != (512, 512):
        return "is %dx%d, need 512x512" % size
    return None


# ------------------------------------------------------------------------------------------------ plan

def build_plan(items=ITEMS, icon_dir=ICON_DIR):
    plan = []
    for it in items:
        icon = os.path.join(icon_dir, it["icon"])
        plan.append({**it, "iconPath": icon, "iconProblem": check_icon(icon)})
    return plan


def print_plan(plan, out=sys.stdout):
    out.write("SkyRally store catalog plan: universe %d, key=%s (DRY RUN unless --apply)\n" % (UNIVERSE_ID, KEY_LABEL))
    for p in plan:
        kind = "Game Pass" if p["kind"] == "Pass" else "Developer Product"
        status = "icon OK 512x512" if p["iconProblem"] is None else "ICON PROBLEM: " + p["iconProblem"]
        out.write("  %-17s %-18s %4d R$  icon %-22s %s\n" % (kind, '"%s"' % p["name"], p["price"], p["icon"], status))
    out.write("  then: skip any name that already exists (record its id), create the rest, read each back,\n"
              "        write out/store_writes.json and StorePassIds.x2Gears from the API response.\n"
              "  never created: the other 15 config rows (Garage+, packs, tints, trails, gift twins).\n")


# ------------------------------------------------------------------------------------------------ multipart

def multipart(fields, files=None, boundary=None):
    """(body bytes, content-type) for multipart/form-data. fields: [(name, value)], files: [(name, filename, bytes, mime)].
    Booleans become 'true'/'false' (the API's form binding)."""
    boundary = boundary or ("----skyrally" + uuid.uuid4().hex)
    parts = []
    for name, value in fields:
        if isinstance(value, bool):
            value = "true" if value else "false"
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (boundary, name, value)).encode("utf-8"))
    for name, filename, data, mime in files or []:
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
                      % (boundary, name, filename, mime)).encode("utf-8") + data + b"\r\n")
    parts.append(("--%s--\r\n" % boundary).encode("utf-8"))
    return b"".join(parts), "multipart/form-data; boundary=%s" % boundary


def create_form(item, with_image):
    fields = [("name", item["name"]), ("description", item["description"]), ("isForSale", True), ("price", item["price"])]
    files = []
    if with_image:
        with open(item["iconPath"], "rb") as f:
            files.append(("imageFile", item["icon"], f.read(), "image/png"))
    return fields, files


# ------------------------------------------------------------------------------------------------ http

class ApiError(Exception):
    def __init__(self, method, path, status, body):
        super().__init__("%s %s -> HTTP %s" % (method, path, status))
        self.method, self.path, self.status, self.body = method, path, status, body


class Client:
    """Open Cloud caller. The key lives only in self._key and the x-api-key header; any echo of it in a response body
    is scrubbed before the body is recorded."""

    def __init__(self, key, opener=None, sleep=time.sleep):
        if opener is None and (UNIVERSE_ID <= 0 or os.environ.get("SKYRALLY_COMMERCE_APPLY") != "1"):
            raise RuntimeError("Live catalog operations disabled: set a universe and explicit apply opt-in")
        self._key = key
        self._open = opener or (lambda req: urllib.request.urlopen(req, timeout=TIMEOUT))
        self._sleep = sleep
        self.calls = []  # (method, path, status) for the record, never headers

    def _scrub(self, text):
        return text.replace(self._key, "<redacted>") if self._key else text

    def request(self, method, path, body=None, content_type=None):
        url = API + path
        attempt = 0
        while True:
            attempt += 1
            req = urllib.request.Request(url, data=body, method=method)
            req.add_header("x-api-key", self._key)
            req.add_header("Accept", "application/json")
            if content_type:
                req.add_header("Content-Type", content_type)
            try:
                resp = self._open(req)
                status = getattr(resp, "status", None) or resp.getcode()
                raw = resp.read()
            except urllib.error.HTTPError as e:
                status, raw = e.code, (e.read() or b"")
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                status, raw = 0, ("network error: %s" % e).encode("utf-8")
            text = self._scrub(raw.decode("utf-8", "replace"))
            self.calls.append((method, path, status))
            if 200 <= status < 300:
                if not text.strip():
                    return {}
                try:
                    return json.loads(text)
                except ValueError:
                    raise ApiError(method, path, status, "non-JSON 2xx body: " + text[:2000])
            if (status == 0 or status >= 500) and attempt == 1:
                self._sleep(2)
                continue
            raise ApiError(method, path, status, text[:4000])

    def list_all(self, path, field):
        out, token = [], None
        for _ in range(50):
            q = {"pageSize": 50}
            if token:
                q["pageToken"] = token
            page = self.request("GET", path + "?" + urllib.parse.urlencode(q))
            out.extend(page.get(field) or [])
            token = page.get("nextPageToken")
            if not token:
                return out
        raise ApiError("GET", path, 0, "more than 50 pages; refusing to continue")


def dp_base():
    return "/developer-products/v2/universes/%d/developer-products" % UNIVERSE_ID


def gp_base():
    return "/game-passes/v1/universes/%d/game-passes" % UNIVERSE_ID


# ------------------------------------------------------------------------------------------------ idempotency

def is_id(v):
    if isinstance(v, str) and v.isdigit():
        v = int(v)
    return isinstance(v, int) and not isinstance(v, bool) and 0 < v < 2 ** 53


def find_existing(listed, name, id_field):
    """Match listed entries by normalized name. Returns (id or None, entry or None, problem or None).
    Two entries with one name is a problem (the binder would bind neither), never a guess."""
    hits = [e for e in listed if isinstance(e, dict) and normalize(e.get("name")) == normalize(name)]
    if not hits:
        return None, None, None
    if len(hits) > 1:
        return None, None, "%d existing entries are named %r" % (len(hits), name)
    raw = hits[0].get(id_field)
    if not is_id(raw):
        return None, hits[0], "existing entry %r has no usable %s" % (name, id_field)
    return int(raw), hits[0], None


def price_of(entry):
    info = entry.get("priceInformation") if isinstance(entry, dict) else None
    if isinstance(info, dict):
        for k in ("defaultPriceInRobux", "priceInRobux", "price"):
            if isinstance(info.get(k), int):
                return info[k]
    if isinstance(entry, dict) and isinstance(entry.get("price"), int):
        return entry["price"]
    return None


# ------------------------------------------------------------------------------------------------ StorePassIds

PASS_LINE = re.compile(r"^(\s*x2Gears\s*=\s*)([^,]*?)(\s*,.*)$", re.M)


def write_pass_id(text, pass_id):
    """StorePassIds.luau text with x2Gears set to pass_id (a real id from the API). Only that line changes."""
    if not is_id(pass_id):
        raise ValueError("refusing to write a non-id: %r" % (pass_id,))
    new, n = PASS_LINE.subn(lambda m: "%s%d :: number?%s" % (m.group(1), int(pass_id), m.group(3)), text, count=1)
    if n != 1:
        raise ValueError("x2Gears line not found in StorePassIds.luau")
    return new


# ------------------------------------------------------------------------------------------------ apply

def proof_line(rec):
    return "PROOF %s | id=%s | universe=%d | key=%s | icon=%s | price=%s R$ | %s" % (
        rec["name"], rec.get("id"), UNIVERSE_ID, KEY_LABEL, rec.get("iconAssetId"), rec.get("readBackPrice"), rec["action"])


def apply_item(client, item, listed):
    is_pass = item["kind"] == "Pass"
    id_field, icon_field = ("gamePassId", "iconAssetId") if is_pass else ("productId", "iconImageAssetId")
    base = gp_base() if is_pass else dp_base()
    rec = {"key": item["key"], "kind": item["kind"], "name": item["name"], "price": item["price"], "universe": UNIVERSE_ID,
           "keyLabel": KEY_LABEL, "id": None, "action": None, "errors": []}
    found, entry, problem = find_existing(listed, item["name"], id_field)
    if problem:
        rec["action"] = "STOPPED"
        rec["errors"].append({"step": "existing", "status": None, "body": problem})
        return rec
    try:
        if found:
            rec["id"], rec["action"] = found, "existing"
        else:
            # Passes take the icon on create (the only create-time icon route for passes); dev products are created
            # first and get the icon through PATCH imageFile right after, so a rejected image never blocks the product.
            fields, files = create_form(item, with_image=is_pass)
            body, ctype = multipart(fields, files)
            created = client.request("POST", base, body, ctype)
            new_id = created.get(id_field)
            if not is_id(new_id):
                rec["action"] = "STOPPED"
                rec["errors"].append({"step": "create", "status": 200, "body": "no %s in response: %s" % (id_field, json.dumps(created)[:2000])})
                return rec
            rec["id"], rec["action"] = int(new_id), "created"
            entry = created
        if not is_id((entry or {}).get(icon_field)):
            with open(item["iconPath"], "rb") as f:
                body, ctype = multipart([], [("imageFile", item["icon"], f.read(), "image/png")])
            client.request("PATCH", "%s/%d" % (base, rec["id"]), body, ctype)
            rec["iconSet"] = True
    except ApiError as e:
        rec["errors"].append({"step": e.method + " " + e.path, "status": e.status, "body": e.body})
        if rec["action"] is None:
            rec["action"] = "STOPPED"
        return rec
    try:
        back = client.request("GET", "%s/%d/creator" % (base, rec["id"]))
        rec["readBack"] = back
        rec["iconAssetId"] = back.get(icon_field)
        rec["readBackPrice"] = price_of(back)
        rec["isForSale"] = back.get("isForSale")
        if rec["readBackPrice"] is not None and rec["readBackPrice"] != item["price"]:
            rec["errors"].append({"step": "readBack", "status": 200,
                                  "body": "price is %s R$, plan says %d R$ (left unchanged)" % (rec["readBackPrice"], item["price"])})
    except ApiError as e:
        rec["errors"].append({"step": "readBack " + e.path, "status": e.status, "body": e.body})
    return rec


def read_key(path=KEY_PATH):
    try:
        st = os.stat(path)
    except OSError:
        raise SystemExit("refusing: key file %s not found" % path)
    if stat.S_IMODE(st.st_mode) != 0o600:
        raise SystemExit("refusing: key file %s must be mode 600 (is %o)" % (path, stat.S_IMODE(st.st_mode)))
    with open(path, "r", encoding="utf-8") as f:
        key = f.read().strip()
    if not key or any(c in key for c in "\r\n"):
        raise SystemExit("refusing: key file is empty or malformed")
    return key


def run_apply(client, plan, pass_ids_file=PASS_IDS_FILE, out_json=OUT_JSON, out=sys.stdout):
    report = {"universe": UNIVERSE_ID, "keyLabel": KEY_LABEL, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "items": [], "proof": [], "listErrors": []}
    listed = {}
    for kind, path, field in (("DevProduct", dp_base() + "/creator", "developerProducts"),
                              ("Pass", gp_base() + "/creator", "gamePasses")):
        try:
            listed[kind] = client.list_all(path, field)
        except ApiError as e:
            report["listErrors"].append({"kind": kind, "status": e.status, "body": e.body})
    for item in plan:
        if item["kind"] not in listed:
            report["items"].append({"key": item["key"], "name": item["name"], "action": "STOPPED", "id": None,
                                    "errors": [{"step": "list", "status": None, "body": "listing failed; not creating blind"}]})
            continue
        rec = apply_item(client, item, listed[item["kind"]])
        report["items"].append(rec)
        if rec.get("id") and rec["action"] in ("created", "existing"):
            report["proof"].append(proof_line(rec))
        if item["key"] == "x2Gears" and is_id(rec.get("id")):
            with open(pass_ids_file, "r", encoding="utf-8") as f:
                text = f.read()
            new = write_pass_id(text, rec["id"])
            if new != text:
                with open(pass_ids_file, "w", encoding="utf-8") as f:
                    f.write(new)
            report["passIdsWritten"] = {"x2Gears": rec["id"]}
    report["calls"] = [{"method": m, "path": p, "status": s} for m, p, s in client.calls]
    os.makedirs(os.path.dirname(out_json), exist_ok=True)
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    for line in report["proof"]:
        out.write(line + "\n")
    for le in report["listErrors"]:
        out.write("LIST FAILED %s: HTTP %s %s\n" % (le["kind"], le["status"], le["body"][:500]))
    for rec in report["items"]:
        for err in rec.get("errors", []):
            out.write("ERROR %s at %s: HTTP %s %s\n" % (rec["name"], err["step"], err["status"], str(err["body"])[:500]))
    ok = sum(1 for r in report["items"] if r.get("action") in ("created", "existing") and r.get("id"))
    out.write("SUMMARY: %d/6 items have a real id (created %d, existing %d, stopped %d); x2Gears pass id %s; wrote %s\n" % (
        ok, sum(r.get("action") == "created" for r in report["items"]), sum(r.get("action") == "existing" for r in report["items"]),
        sum(r.get("action") == "STOPPED" for r in report["items"]),
        (report.get("passIdsWritten") or {}).get("x2Gears", "NOT written"), os.path.relpath(out_json, REPO)))
    if report.get("passIdsWritten"):
        out.write("NEXT: commit src/shared/StorePassIds.luau and republish the place so the 2x Cash chip appears.\n")
    return report


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true", help="create the six items via Open Cloud (default: dry run)")
    args = ap.parse_args(argv)
    validate_items()
    plan = build_plan()
    print_plan(plan)
    bad = [p for p in plan if p["iconProblem"]]
    if bad:
        print("REFUSING: %d icon(s) not ready" % len(bad))
        return 2
    if not args.apply:
        print("DRY RUN: no network calls made, key file not opened. Re-run with --apply to create.")
        return 0
    client = Client(read_key())
    report = run_apply(client, plan)
    return 0 if all(r.get("action") in ("created", "existing") and not any(e.get("step", "").startswith(("POST", "PATCH")) for e in r.get("errors", []))
                    for r in report["items"]) else 1


if __name__ == "__main__":
    sys.exit(main())
