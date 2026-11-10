#!/usr/bin/env python3
"""Launch-config check (audit T0-6). Reads, never edits, the source switches that must differ for a PUBLIC publish.

Owner rules: private builds keep everything ON (store, Storm Cup v1, admin, QA hooks) and are never touched by this
check; every launch-only restriction hangs on the single launch switch MonetizationConfig.LAUNCH_HIDE or on a decision
recorded in docs/LAUNCH_CONFIG_APPROVED.json. A public publish is refused unless that file says approved=true (owner,
dated), every expected value is decided (no null) and the source reads exactly those values.

Usage:
  tools/launch_config_check.py                 list every switch with its current value (private view, exit 0)
  tools/launch_config_check.py --public        exit 1 unless the owner-approved launch config is in place
  tools/launch_config_check.py --json          machine-readable report
Library: report(root), check_public(report, approved) -> list of problems (pure; see tools/tests/test_launch_config.py)."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APPROVED = "docs/LAUNCH_CONFIG_APPROVED.json"

# id -> (file, regex with one capture group for the literal value, what it is)
SOURCE_SWITCHES = {
    "store_enabled": ("src/shared/MonetizationConfig.luau", r"MonetizationConfig\.Enabled\s*=\s*(true|false)", "store on/off (owner decision D18)"),
    "launch_hide": ("src/shared/MonetizationConfig.luau", r"MonetizationConfig\.LAUNCH_HIDE\s*=\s*(true|false)", "the single launch switch (hides non-launch products and features)"),
    "storm_enabled": ("src/shared/StormConfig.luau", r"StormConfig\.Enabled\s*=\s*(true|false)", "Storm Shards and the Storm vendor"),
    "storm_race_v2": ("src/shared/StormConfig.luau", r"StormConfig\.RACE_V2\s*=\s*(true|false)", "false = Storm Cup v1 (whole-server cup) runs; true = per-group storm race v2"),
    "per_group_races": ("src/shared/RaceFlowRules.luau", r"RaceFlowRules\.PER_GROUP\s*=\s*(true|false)", "per-group race engine"),
    "admin_user_id": ("src/server/AdminConfig.luau", r"AdminConfig\.ADMIN_USER_ID\s*=\s*(\d+)", "owner admin account (D22): admin tab and /admin work on live servers"),
    "admin_studio_attribute": ("src/server/AdminConfig.luau", r"AdminConfig\.STUDIO_ATTRIBUTE\s*=\s*\"(\w+)\"", "Studio-only admin override attribute (RunService:IsStudio() gated; inert on live servers)"),
}
# Attributes a project file or builder must not preset on the shipped place (QA hooks and test flags).
QA_ATTR_RE = re.compile(r"^(QA\w*|AutoPilot|TriggerSimulateFinish|UnlockAll|BadgeQA|StormCup(QA|Now)|ArtSwapOff|MapCacheOff|SimulateFinish\w*)$")
PRIVATE_EXPECT = {"store_enabled": "true", "launch_hide": "false", "storm_enabled": "true"}  # owner: everything ON in private


def _val(text, rx):
    m = re.search(rx, text)
    return m.group(1) if m else None


def project_qa_attributes(root: Path):
    found = []
    try:
        data = json.loads((root / "default.project.json").read_text(encoding="utf-8"))
    except Exception:
        return found

    def walk(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "$attributes" or k == "Attributes":
                    for a, av in (v or {}).items():
                        if QA_ATTR_RE.match(a) and av not in (False, None, 0):
                            found.append(f"{path}.{a}={av}")
                else:
                    walk(v, path + "." + k if path else k)
    walk(data, "")
    return found


def report(root: Path = ROOT):
    sw = {}
    for sid, (f, rx, what) in SOURCE_SWITCHES.items():
        p = root / f
        v = _val(p.read_text(encoding="utf-8"), rx) if p.exists() else None
        if sid == "admin_user_id" and v is None and p.exists():
            v = _val(p.read_text(encoding="utf-8"), r"return create\((\d+)\)\s*$")
        sw[sid] = {"file": f, "value": v, "what": what}
    sw["qa_attributes_preset"] = {"file": "default.project.json", "value": ",".join(project_qa_attributes(root)) or "none", "what": "QA/test attributes preset on the shipped place (must be none)"}
    return sw


def load_approved(root: Path = ROOT):
    p = root / APPROVED
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}


def check_public(rep, approved):
    """Problems that block a PUBLIC publish; [] means the owner-approved launch config is set."""
    probs = []
    if approved.get("approved") is not True or not approved.get("approved_by") or not approved.get("date"):
        probs.append(f"{APPROVED}: not owner-approved (approved/approved_by/date) - the public-release decision (D18) has not been recorded")
    exp = approved.get("expected", {})
    for sid in SOURCE_SWITCHES:
        if sid not in exp or exp[sid] is None:
            probs.append(f"{sid}: no owner decision recorded in expected ({rep[sid]['what']})")
        elif str(exp[sid]).lower() != str(rep[sid]["value"]).lower():
            probs.append(f"{sid}: source reads {rep[sid]['value']!r} but the approved launch config expects {exp[sid]!r} ({rep[sid]['file']})")
    if rep["qa_attributes_preset"]["value"] != "none":
        probs.append("qa_attributes_preset: " + rep["qa_attributes_preset"]["value"])
    if str(exp.get("launch_hide")).lower() != "true":
        probs.append("launch_hide: a public build must run with LAUNCH_HIDE=true (single launch switch)")
    return probs


def main(argv):
    rep = report()
    approved = load_approved()
    if "--json" in argv:
        print(json.dumps({"switches": rep, "approved": approved.get("approved")}, indent=1))
    else:
        print("LAUNCH_CONFIG switches (private builds keep these as they are; the public publish needs the approved values):")
        exp = approved.get("expected", {})
        for sid, r in rep.items():
            print(f"  {sid:24} source={r['value']!s:12} approved={exp.get(sid)!s:8} {r['what']}")
    if "--public" in argv:
        probs = check_public(rep, approved)
        for p in probs:
            print("LAUNCH_REFUSED " + p)
        print("LAUNCH_CONFIG " + ("PUBLIC_OK" if not probs else f"PUBLIC_REFUSED problems={len(probs)}"))
        return 1 if probs else 0
    drift = [f"{k} reads {rep[k]['value']} (private default {v})" for k, v in PRIVATE_EXPECT.items() if rep[k]["value"] != v]
    for d in drift:
        print("PRIVATE_NOTE " + d)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
