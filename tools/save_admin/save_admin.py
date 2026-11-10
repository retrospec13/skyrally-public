#!/usr/bin/env python3
"""SkyRally owner save tools over Roblox Open Cloud (systems audit v32 T1-14; docs/SAVE_ADMIN.md).

The same four tools the admin account has in game ("/admin save ..."; server/SaveAdmin, shared/SaveAdminRules), for
when no server is running, e.g. a Roblox right-to-erasure email:

  inspect  <userId>                 read the profile record: lock, facts, last takeover          (read only)
  versions <userId>                 list the newest DataStore versions of the profile             (read only)
  restore  <userId> <versionId>     put an earlier version back (refused while the player is online)
  erase    <userId>                 remove every SkyRally entry for the user (right to erasure)

restore and erase are DRY RUNS unless --apply is given. Every run appends one JSON line per action to
out/save_admin/save_admin_log.jsonl (no key, no profile contents) and prints what it did.

Key: an Open Cloud API key with DataStore read/write/list-versions/delete and ordered-DataStore delete on universe
UNIVERSE_ID, in a file named by --key-file or SKYRALLY_DATASTORE_KEY_FILE (POSIX: mode 600). The key is sent only in the
x-api-key header and is never printed or logged.

NOT RUN by any agent (no keys, owner order needed): the first owner run should be `inspect` on his own userId.

Endpoints (Open Cloud DataStores v1 standard, v2 ordered):
  GET    /datastores/v1/universes/{u}/standard-datastores/datastore/entries/entry?datastoreName&entryKey
  POST   /datastores/v1/universes/{u}/standard-datastores/datastore/entries/entry?datastoreName&entryKey&matchVersion
  DELETE /datastores/v1/universes/{u}/standard-datastores/datastore/entries/entry?datastoreName&entryKey
  GET    /datastores/v1/universes/{u}/standard-datastores/datastore/entries/entry/versions?...&sortOrder=Descending&limit
  GET    /datastores/v1/universes/{u}/standard-datastores/datastore/entries/entry/versions/version?...&versionId
  GET    /datastores/v1/universes/{u}/standard-datastores/datastore/entries?datastoreName&limit&cursor   (--scan-purchases)
  DELETE /cloud/v2/universes/{u}/ordered-data-stores/{store}/scopes/global/entries/{userId}
"""

import argparse
import base64
import hashlib
import json
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

UNIVERSE_ID = 0
API = "https://apis.roblox.com"
TIMEOUT = 30
KEY_ENV = "SKYRALLY_DATASTORE_KEY_FILE"
LOG_PATH = os.path.join(REPO, "out", "save_admin", "save_admin_log.jsonl")

# Must match shared/SaveAdminRules (save_ops_spec checks the names against the game's own constants).
PROFILE_STORE = "SkyRallyProfiles"
PROFILE_PREFIX = "u_"
GIFT_STORE = "SkyRallyPendingGifts"
GIFT_PREFIX = "g_"
PURCHASE_STORE = "SkyRallyPurchaseHistory"
BOARD_PREFIX = "SkyRallyLB_v1_"
FALLBACK_TRACKS = ["DINO-4", "SNOW-1", "ISLAND-2", "FOREST-1", "SPACE-4"]

# shared/SaveLockRules
LEGACY_TTL, MIN_TTL, MAX_TTL = 180, 30, 600


class ApiError(Exception):
    def __init__(self, method, path, status, body):
        Exception.__init__(self, "%s %s -> %s: %s" % (method, path, status, body[:300]))
        self.method, self.path, self.status, self.body = method, path, status, body


# ------------------------------------------------------------------------------------------------ rules (pure)

def lock_ttl(session):
    ttl = session.get("ttl") if isinstance(session, dict) else None
    if not isinstance(ttl, (int, float)) or ttl != ttl:
        return LEGACY_TTL
    return max(MIN_TTL, min(MAX_TTL, ttl))


def lock_state(record, now):
    session = record.get("session") if isinstance(record, dict) else None
    if not isinstance(session, dict):
        return {"state": "free"}
    ttl = lock_ttl(session)
    locked_at = session.get("lockedAt")
    age = max(0, now - (locked_at if isinstance(locked_at, (int, float)) else 0))
    held = age < ttl
    return {"state": "held" if held else "stale", "holder": str(session.get("id")), "age": int(age), "ttl": ttl,
            "remaining": ttl - age if held else 0}


def _count(t):
    return sum(1 for v in t.values() if v not in (None, False)) if isinstance(t, dict) else 0


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def facts(profile):
    p = profile if isinstance(profile, dict) else {}
    sub = lambda k: p.get(k) if isinstance(p.get(k), dict) else {}
    return {
        "version": _num(p.get("version")), "tokens": _count(p.get("tokens")), "keys": _count(p.get("keys")),
        "battles": _count(p.get("battles")), "ducks": _count(p.get("ducks")), "bestTimes": _count(p.get("bestTimes")),
        "finalBoss": 1 if p.get("finalBoss") is True else 0, "cash": _num(p.get("gears")),
        "shards": _num(sub("storm").get("shards")), "winPassRaces": _num(sub("winPass").get("races")),
        "cosmetics": _count(sub("cosmetics").get("owned")), "avatars": _count(sub("avatars").get("owned")),
        "receipts": _count(sub("economy").get("receipts")),
    }


FACT_ORDER = ["version", "tokens", "keys", "battles", "ducks", "bestTimes", "finalBoss", "cash", "shards",
              "winPassRaces", "cosmetics", "avatars", "receipts"]


def fact_line(profile):
    f = facts(profile)
    return " ".join("%s=%s" % (k, f[k]) for k in FACT_ORDER)


def utc(t):
    if not isinstance(t, (int, float)):
        return "?"
    return time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime(t))


def summarize(user_id, record, now):
    if record is None:
        return "user %d: no saved profile" % user_id
    if not isinstance(record, dict):
        return "user %d: record is a %s (unreadable; restore an earlier version)" % (user_id, type(record).__name__)
    lock = lock_state(record, now)
    lock_text = "free" if lock["state"] == "free" else "%s by %s, refreshed %ds ago (ttl %ds)" % (
        lock["state"], lock["holder"], lock["age"], lock["ttl"])
    lines = ["user %d: saved %s, lock %s" % (user_id, utc(record.get("savedAt")), lock_text), fact_line(record.get("profile"))]
    tk = record.get("lastTakeover")
    if isinstance(tk, dict):
        lines.append("last takeover %s: %s -> %s (lock was %ss old)" % (utc(tk.get("at")), tk.get("from"), tk.get("by"), tk.get("age")))
    rs = record.get("restoredFrom")
    if isinstance(rs, dict):
        lines.append("restored %s from version %s" % (utc(rs.get("at")), rs.get("version")))
    return "\n".join(lines)


def _union(base, keep):
    out = dict(base) if isinstance(base, dict) else {}
    if isinstance(keep, dict):
        out.update(keep)
    return out


def plan_restore(current, candidate, version, now, current_version):
    """The record a restore writes, or (None, why). Same rules as SaveAdminRules.planRestore, except migration: the
    server migrates on its next load, so this only refuses a version newer than the game (or not a profile)."""
    lock = lock_state(current, now)
    if lock["state"] == "held":
        return None, "player is online (lock held by %s, %ds ago); restore after they leave" % (lock["holder"], lock["age"])
    if not isinstance(candidate, dict) or not isinstance(candidate.get("profile"), dict):
        return None, "version %s holds no profile" % version
    restored = json.loads(json.dumps(candidate["profile"]))
    v = restored.get("version", 0)
    if not isinstance(v, (int, float)) or v > current_version:
        return None, "version %s cannot be read: record version %s is newer than the game's %d" % (version, v, current_version)
    cur = current.get("profile") if isinstance(current, dict) and isinstance(current.get("profile"), dict) else None
    if cur is not None:
        cur_econ = cur.get("economy") if isinstance(cur.get("economy"), dict) else {}
        econ = restored.get("economy") if isinstance(restored.get("economy"), dict) else {}
        econ["receipts"] = _union(econ.get("receipts"), cur_econ.get("receipts"))
        econ["oneTime"] = _union(econ.get("oneTime"), cur_econ.get("oneTime"))
        restored["economy"] = econ
        restored["pendingGifts"] = _union(restored.get("pendingGifts"), cur.get("pendingGifts"))
    record = json.loads(json.dumps(current)) if isinstance(current, dict) else {}
    record["profile"] = restored
    record.pop("session", None)
    record["savedAt"] = now
    record["restoredFrom"] = {"version": version, "at": now}
    return record, None


def board_stores(repo=REPO):
    tracks = FALLBACK_TRACKS
    try:
        with open(os.path.join(repo, "src", "shared", "LeaderboardRules.luau"), encoding="utf-8") as f:
            m = re.search(r"LeaderboardRules\.RACE_TRACKS\s*=\s*\{([^}]*)\}", f.read())
        if m:
            tracks = re.findall(r'"([^"]+)"', m.group(1)) or FALLBACK_TRACKS
    except OSError:
        pass
    return sorted([BOARD_PREFIX + "best_" + t for t in tracks] + [BOARD_PREFIX + "stars"])


def current_version(repo=REPO):
    try:
        with open(os.path.join(repo, "src", "server", "SaveService.luau"), encoding="utf-8") as f:
            m = re.search(r"SaveService\.CURRENT_VERSION\s*=\s*(\d+)", f.read())
        return int(m.group(1)) if m else 2
    except OSError:
        return 2


def erasure_targets(user_id, profile_record, boards):
    out = [("standard", GIFT_STORE, GIFT_PREFIX + str(user_id))]
    profile = profile_record.get("profile") if isinstance(profile_record, dict) else None
    econ = profile.get("economy") if isinstance(profile, dict) else None
    receipts = econ.get("receipts") if isinstance(econ, dict) else None
    if isinstance(receipts, dict):
        out += [("purchase", PURCHASE_STORE, pid) for pid in sorted(k for k in receipts if isinstance(k, str))]
    out += [("ordered", name, str(user_id)) for name in sorted(boards)]
    out.append(("standard", PROFILE_STORE, PROFILE_PREFIX + str(user_id)))
    return out


# ------------------------------------------------------------------------------------------------ Open Cloud

class Client:
    """Open Cloud DataStore caller. The key lives only in self._key and the x-api-key header; any echo of it in a
    response body is scrubbed."""

    def __init__(self, key, universe=UNIVERSE_ID, opener=None, sleep=time.sleep):
        self._key = key
        self.universe = universe
        self._open = opener or (lambda req: urllib.request.urlopen(req, timeout=TIMEOUT))
        self._sleep = sleep
        self.calls = []  # (method, path, status); never headers

    def _scrub(self, text):
        return text.replace(self._key, "<redacted>") if self._key else text

    def request(self, method, path, body=None, headers=None, ok404=False):
        attempt = 0
        while True:
            attempt += 1
            req = urllib.request.Request(API + path, data=body, method=method)
            req.add_header("x-api-key", self._key)
            for k, v in (headers or {}).items():
                req.add_header(k, v)
            try:
                resp = self._open(req)
                status = getattr(resp, "status", None) or resp.getcode()
                raw = resp.read()
                rheaders = dict(resp.headers.items()) if getattr(resp, "headers", None) is not None else {}
            except urllib.error.HTTPError as e:
                status, raw, rheaders = e.code, (e.read() or b""), {}
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                status, raw, rheaders = 0, ("network error: %s" % e).encode("utf-8"), {}
            text = self._scrub(raw.decode("utf-8", "replace"))
            self.calls.append((method, path.split("?")[0], status))
            if 200 <= status < 300:
                return status, text, {k.lower(): v for k, v in rheaders.items()}
            if status == 404 and ok404:
                return status, None, {}
            # 429 (throttled) and 5xx: back off and retry a few times, like the game's own backoff.
            if (status == 0 or status == 429 or status >= 500) and attempt < 4:
                self._sleep(2 ** attempt)
                continue
            raise ApiError(method, path.split("?")[0], status, text)

    def _std(self, suffix, store, key, extra=None):
        q = {"datastoreName": store, "entryKey": key}
        q.update(extra or {})
        return "/datastores/v1/universes/%d/standard-datastores/datastore/entries%s?%s" % (
            self.universe, suffix, urllib.parse.urlencode(q))

    def get(self, store, key):
        """(value or None, version or None)"""
        status, text, headers = self.request("GET", self._std("/entry", store, key), ok404=True)
        if status == 404:
            return None, None
        return json.loads(text), headers.get("roblox-entry-version")

    def set(self, store, key, value, user_ids, match_version=None):
        body = json.dumps(value, separators=(",", ":")).encode("utf-8")
        md5 = base64.b64encode(hashlib.md5(body).digest()).decode("ascii")
        extra = {"matchVersion": match_version} if match_version else None
        self.request("POST", self._std("/entry", store, key, extra), body=body, headers={
            "content-type": "application/json", "content-md5": md5,
            "roblox-entry-userids": json.dumps(user_ids)})

    def delete(self, store, key):
        self.request("DELETE", self._std("/entry", store, key), ok404=True)

    def versions(self, store, key, limit):
        _, text, _ = self.request("GET", self._std("/entry/versions", store, key, {"sortOrder": "Descending", "limit": limit}))
        return (json.loads(text) or {}).get("versions") or []

    def get_version(self, store, key, version):
        status, text, _ = self.request("GET", self._std("/entry/versions/version", store, key, {"versionId": version}), ok404=True)
        if status == 404:
            raise ApiError("GET", "version", 404, "version %s not found" % version)
        return json.loads(text)

    def list_keys(self, store, cursor=None):
        q = {"datastoreName": store, "limit": 100}
        if cursor:
            q["cursor"] = cursor
        path = "/datastores/v1/universes/%d/standard-datastores/datastore/entries?%s" % (self.universe, urllib.parse.urlencode(q))
        _, text, _ = self.request("GET", path)
        page = json.loads(text) or {}
        return [k.get("key") for k in page.get("keys") or []], page.get("nextPageCursor")

    def delete_ordered(self, store, key):
        path = "/cloud/v2/universes/%d/ordered-data-stores/%s/scopes/global/entries/%s" % (
            self.universe, urllib.parse.quote(store, safe=""), urllib.parse.quote(key, safe=""))
        self.request("DELETE", path, ok404=True)


# ------------------------------------------------------------------------------------------------ commands

class Log:
    def __init__(self, path=LOG_PATH, out=sys.stdout, clock=time.time):
        self.path, self.out, self.clock = path, out, clock

    def action(self, action, target, result, detail="", apply=False):
        entry = {"at": int(self.clock()), "actor": "owner-cli", "action": action, "target": target, "result": result,
                 "apply": bool(apply), "detail": detail}
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, sort_keys=True) + "\n")
        self.out.write("[SAVEADMIN] action=%s target=%d result=%s%s\n" % (action, target, result, (" " + detail) if detail else ""))


def cmd_inspect(client, log, user_id, now):
    rec, _ = client.get(PROFILE_STORE, PROFILE_PREFIX + str(user_id))
    log.out.write(summarize(user_id, rec, now) + "\n")
    log.action("inspect", user_id, "ok")
    return 0


def cmd_versions(client, log, user_id, limit=10):
    rows = client.versions(PROFILE_STORE, PROFILE_PREFIX + str(user_id), limit)
    for r in rows:
        log.out.write("%s  %s%s\n" % (r.get("version"), r.get("createdTime"), "  (deleted)" if r.get("deleted") else ""))
    if not rows:
        log.out.write("user %d: no versions\n" % user_id)
    log.action("versions", user_id, "ok", "rows=%d" % len(rows))
    return 0


def cmd_restore(client, log, user_id, version, now, apply, cur_version):
    key = PROFILE_PREFIX + str(user_id)
    candidate = client.get_version(PROFILE_STORE, key, version)
    current, current_ver = client.get(PROFILE_STORE, key)
    record, why = plan_restore(current, candidate, version, now, cur_version)
    if record is None:
        log.out.write("Restore refused: %s\n" % why)
        log.action("restore", user_id, "refused", "version=%s %s" % (version, why), apply)
        return 2
    log.out.write("now:   %s\nafter: %s\n" % (fact_line((current or {}).get("profile") if isinstance(current, dict) else None),
                                              fact_line(record["profile"])))
    if not apply:
        log.out.write("DRY RUN: nothing written. Add --apply to restore.\n")
        log.action("restore", user_id, "preview", "version=%s" % version, apply)
        return 0
    # matchVersion: a server that wrote (took the lock) since the read above makes this write fail instead of racing it.
    try:
        client.set(PROFILE_STORE, key, record, [user_id], match_version=current_ver)
    except ApiError as e:
        log.out.write("Restore failed (the record changed or the call failed; nothing written): %s\n" % e)
        log.action("restore", user_id, "failed", "version=%s status=%s" % (version, e.status), apply)
        return 1
    log.action("restore", user_id, "done", "version=%s" % version, apply)
    return 0


def cmd_erase(client, log, user_id, now, apply, boards, scan_purchases=False):
    pkey = PROFILE_PREFIX + str(user_id)
    rec, _ = client.get(PROFILE_STORE, pkey)
    lock = lock_state(rec, now)
    if lock["state"] == "held":
        log.out.write("Erase refused: user %d is online (lock held by %s). Run it after they leave.\n" % (user_id, lock["holder"]))
        log.action("erase", user_id, "refused", "online", apply)
        return 2
    targets = erasure_targets(user_id, rec, boards)
    if scan_purchases:
        # Purchase records older than the profile's kept receipts: scan the whole store for this buyer.
        named = {t[2] for t in targets if t[0] == "purchase"}
        cursor, extra = None, []
        for _ in range(10000):
            keys, cursor = client.list_keys(PURCHASE_STORE, cursor)
            for k in keys:
                if k in named:
                    continue
                value, _ = client.get(PURCHASE_STORE, k)
                if isinstance(value, dict) and value.get("userId") == user_id:
                    extra.append(("purchase", PURCHASE_STORE, k))
            if not cursor:
                break
        targets = targets[:-1] + sorted(extra) + targets[-1:]
    for kind, store, key in targets:
        log.out.write("  %s %s/%s\n" % (kind, store, key))
    if not apply:
        log.out.write("DRY RUN: %d entries would be removed. Add --apply to erase.\n" % len(targets))
        log.action("erase", user_id, "preview", "targets=%d" % len(targets), apply)
        return 0
    failed, removed = [], 0
    for kind, store, key in targets:
        try:
            if kind == "ordered":
                client.delete_ordered(store, key)
            elif kind == "purchase":
                value, _ = client.get(store, key)
                if value is not None and (not isinstance(value, dict) or value.get("userId") != user_id):
                    removed += 1  # names another buyer: left alone
                    continue
                if value is not None:
                    client.delete(store, key)
            elif store == PROFILE_STORE:
                if failed:
                    raise ApiError("DELETE", key, 0, "kept for a rerun: earlier removals failed")
                again, _ = client.get(store, key)
                if lock_state(again, now)["state"] == "held":
                    raise ApiError("DELETE", key, 0, "player came online")
                client.delete(store, key)
            else:
                client.delete(store, key)
            removed += 1
        except ApiError as e:
            failed.append("%s/%s: %s" % (store, key, e))
    if failed:
        log.out.write("Erase incomplete (%d of %d). Run the same command again.\n%s\n" % (removed, len(targets), "\n".join(failed)))
        log.action("erase", user_id, "partial", "removed=%d failed=%d" % (removed, len(failed)), apply)
        return 1
    log.out.write("Erased user %d: %d entries removed. Old versions expire on Roblox's 30-day schedule.\n" % (user_id, removed))
    log.action("erase", user_id, "done", "removed=%d" % removed, apply)
    return 0


def read_key(path):
    if not path:
        raise SystemExit("refusing: no key file (--key-file or %s)" % KEY_ENV)
    try:
        st = os.stat(path)
    except OSError:
        raise SystemExit("refusing: key file not found")
    if os.name == "posix" and stat.S_IMODE(st.st_mode) & 0o077:
        raise SystemExit("refusing: key file must not be readable by group or others (chmod 600)")
    with open(path, "r", encoding="utf-8") as f:
        key = f.read().strip()
    if not key or any(c in key for c in "\r\n"):
        raise SystemExit("refusing: key file is empty or malformed")
    return key


def main(argv=None, client=None, log=None, now=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("action", choices=["inspect", "versions", "restore", "erase"])
    ap.add_argument("user_id", type=int)
    ap.add_argument("version", nargs="?")
    ap.add_argument("--apply", action="store_true", help="really write (restore) or remove (erase)")
    ap.add_argument("--scan-purchases", action="store_true", help="erase: also scan the whole PurchaseHistory store")
    ap.add_argument("--key-file", default=os.environ.get(KEY_ENV))
    ap.add_argument("--universe", type=int, default=UNIVERSE_ID)
    args = ap.parse_args(argv)
    if args.user_id < 1:
        ap.error("user_id must be positive")
    if args.action == "restore" and not args.version:
        ap.error("restore needs a versionId (from: versions <userId>)")
    if client is None:
        client = Client(read_key(args.key_file), universe=args.universe)
    log = log or Log()
    now = time.time() if now is None else now
    try:
        if args.action == "inspect":
            return cmd_inspect(client, log, args.user_id, now)
        if args.action == "versions":
            return cmd_versions(client, log, args.user_id)
        if args.action == "restore":
            return cmd_restore(client, log, args.user_id, args.version, now, args.apply, current_version())
        return cmd_erase(client, log, args.user_id, now, args.apply, board_stores(), args.scan_purchases)
    except ApiError as e:
        log.out.write("Open Cloud call failed: %s\n" % e)
        log.action(args.action, args.user_id, "failed", "status=%s" % e.status, args.apply)
        return 1


if __name__ == "__main__":
    sys.exit(main())
