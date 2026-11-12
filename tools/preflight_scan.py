#!/usr/bin/env python3
"""Offline half of the asset preflight (gate step 5): runs the same static number scan as asset_preflight.py and checks
every referenced id against the committed ledger (assets/ledger/asset_access_current.json). No PC, no network.
FAIL (exit 1): a referenced id whose last ledger decision is not "ok" (a known-blocked asset is in the tree).
Ids the ledger has never seen: WARN (exit 0) by default; the gate runs this with --strict, where they FAIL (exit 1),
except ids with an upload record: assets/models/**/uploaded.json lists the id, and that entry's file exists with the
recorded sha256. tools/upload_models.py writes the entry only after the upload returned MODEL_ASSET_ID and the Use grant
to the universe was validated (GRANT_STATUS ok=True), so the entry is the grant record. Such ids print as
PENDING_LEDGER (exit 0): the ledger itself is regenerated only by the PC preflight at publish, which classifies them
and blocks the publish if the grant is not confirmed. Any other new id (no record, or a changed file) fails the gate."""
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asset_preflight as ap  # noqa: E402

REPO = Path(__file__).resolve().parent.parent


def upload_records():
    """{asset id: entry} for every uploaded.json entry whose file exists and matches its recorded sha256."""
    out = {}
    for f in sorted((REPO / "assets" / "models").rglob("uploaded.json")):
        try:
            data = json.loads(f.read_text())
        except ValueError:
            continue
        for entry in data.values() if isinstance(data, dict) else []:
            if not isinstance(entry, dict) or not str(entry.get("model", "")).isdigit() or not entry.get("sha256"):
                continue
            path = REPO / entry.get("file", "")
            if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]:
                out[str(entry["model"])] = entry
    # tools/vfx/upload_set.py image sets (assets/ui/...): {name: {id, sha256}} beside <name>.png
    for f in sorted((REPO / "assets" / "ui").rglob("uploaded.json")):
        try:
            data = json.loads(f.read_text())
        except ValueError:
            continue
        for name, entry in data.items() if isinstance(data, dict) else []:
            if not isinstance(entry, dict) or not str(entry.get("id", "")).isdigit() or not entry.get("sha256"):
                continue
            path = f.parent / f"{name}.png"
            if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]:
                out[str(entry["id"])] = entry
    # tools/vfx/upload_set.py audio sets (assets/audio/...): {name: {id, sha256}} beside <name>.ogg
    for f in sorted((REPO / "assets" / "audio").rglob("uploaded.json")):
        try:
            data = json.loads(f.read_text())
        except ValueError:
            continue
        for name, entry in data.items() if isinstance(data, dict) else []:
            if not isinstance(entry, dict) or not str(entry.get("id", "")).isdigit() or not entry.get("sha256"):
                continue
            path = f.parent / f"{name}.ogg"
            if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]:
                out[str(entry["id"])] = entry
    return out


def check(strict=False):
    policy = json.loads(ap.POLICY.read_text())
    non_asset = set(policy.get("non_asset_numbers", {}))
    refs = ap.static_scan(non_asset)
    cur = json.loads((ap.LEDGER / "asset_access_current.json").read_text())
    assets = cur.get("assets", {})
    bad = sorted((i for i in refs if i in assets and assets[i].get("decision") != "ok"), key=int)
    unseen = sorted((i for i in refs if i not in assets), key=int)
    return refs, bad, unseen, cur.get("commit", "?")


def split_unseen(unseen):
    """(recorded, unrecorded): unledgered ids with a validated upload record vs. ids with nothing behind them."""
    rec = upload_records()
    return [i for i in unseen if i in rec], [i for i in unseen if i not in rec]


def main():
    strict = "--strict" in sys.argv
    refs, bad, unseen, commit = check(strict)
    recorded, unrecorded = split_unseen(unseen)
    print(f"PREFLIGHT_SCAN refs={len(refs)} ledger_commit={commit[:7]} blocked={len(bad)} unledgered={len(unseen)} "
          f"pending_ledger={len(recorded)} unrecorded={len(unrecorded)}")
    for i in bad:
        print(f"  BLOCKED {i} {refs[i][:2]}")
    for i in recorded:
        print(f"  PENDING_LEDGER {i} {refs[i][:2]} (upload record + sha256 ok; PC preflight adds the ledger row at publish)")
    for i in unrecorded[:20]:
        print(f"  UNLEDGERED {i} {refs[i][:2]}")
    if len(unrecorded) > 20:
        print(f"  ... {len(unrecorded) - 20} more unledgered")
    return 1 if bad or (strict and unrecorded) else 0


if __name__ == "__main__":
    sys.exit(main())
