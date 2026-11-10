#!/usr/bin/env python3
"""Boot one mounted map in the own Studio window (Edit attribute ActiveTrackKey), wait for the adapter, and collect
boot lines, errors, selftest results and three captures. Usage: map_boot_check.py <key> [seconds]

V1 D2 (2026-10-22): on race maps the game's BootLog ring and the Studio console both roll over within about 40 s of
item/name chatter, and a single end-of-run read kept `lines[:200]` filled by AdapterStep lines first, so the json held
no [BOOT]/[MAP]/[DIRECTOR]/[SELFTEST] lines. Now: the console, the ring and the ring's quiet key list (workspace
attribute BootLogKey, src/server/BootLog.luau) are polled every 3 s from Play start and unioned; key lines are kept
first with their own larger cap; the director's `[DIRECTOR] load <key> (<ID>) mode=... ok=true errors=0 built|cached
in Ns` line is required (directorOk in the json, DIRECTOR_OK / DIRECTOR_MISSING / DIRECTOR_FAILED printed, exit 2 when
not confirmed), and the `[MAP] <ID> steps build wait=...` timing line and the BootClock phases are lifted out."""
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

POLL_S = 3
BOOTLOG_LUA = """
local out = { tostring(workspace:GetAttribute('BootLogKey') or ''), tostring(workspace:GetAttribute('BootLog') or '') }
local maps = workspace:FindFirstChild('Maps')
if maps then
	for _, r in maps:GetChildren() do
		for k, v in r:GetAttributes() do
			if string.sub(k, 1, 12) == 'AdapterStep_' then table.insert(out, '[AdapterStep] ' .. r.Name .. ' ' .. k .. ' = ' .. tostring(v)) end
		end
		local steps = r:GetAttribute('BuildSteps')
		if steps then table.insert(out, '[SkyRally][MAP] ' .. r.Name .. ' steps ' .. tostring(steps) .. ' (BuildSteps attribute)') end
	end
end
return table.concat(out, '\\n')
"""

# Boot evidence: kept first, never squeezed out by the rest.
KEY_TAGS = ("[BOOT]", "[MAP]", "[DIRECTOR]", "[SELFTEST]", "[LIGHTING]", "[MAPCACHE]", "[30MAPS] DONE",
            "[30MAPS] terrain bake", "ERROR", "rror", "FAIL")
OTHER_TAGS = ("WORLD] t=15", "WORLDANIM", "MapAdapter", "[AI] track marks", "AdapterStep")
KEEP_KEY = 400
KEEP_OTHER = 200
DIRECTOR_RE = re.compile(r"\[DIRECTOR\] load (\S+) \(([^)]*)\) mode=(\S+) ok=(\w+) errors=(\d+) (built|cached) in ([0-9.]+)s")
STEPS_RE = re.compile(r"\[MAP\] (\S+) steps (build|activate) (.*)")
PHASE_RE = re.compile(r"\[BOOT\] phase=(\S+) t=([0-9.]+)")


def strip_stamp(line):
    """Console lines can carry a time prefix; the union dedupes on the text from the first '[' on."""
    i = line.find("[")
    return line[i:] if i > 0 else line


def select_lines(lines):
    """Union in first-seen order, key lines first (KEEP_KEY), then the rest (KEEP_OTHER)."""
    seen, key, other = set(), [], []
    for raw in lines:
        l = strip_stamp(raw.rstrip())
        if not l or l in seen:
            continue
        if any(t in l for t in KEY_TAGS):
            seen.add(l)
            key.append(l)
        elif any(t in l for t in OTHER_TAGS):
            seen.add(l)
            other.append(l)
    return key[:KEEP_KEY] + other[:KEEP_OTHER]


def director_verdict(lines, key):
    """The director's load line for `key` (the last one if the map loaded more than once)."""
    hit = None
    for l in lines:
        m = DIRECTOR_RE.search(l)
        if m and m.group(1) == key:
            hit = {"key": m.group(1), "id": m.group(2), "mode": m.group(3), "ok": m.group(4) == "true",
                   "errors": int(m.group(5)), "source": m.group(6), "seconds": float(m.group(7)), "line": l}
    return hit


def build_steps(lines):
    out = {}
    for l in lines:
        m = STEPS_RE.search(l)
        if m:
            out[m.group(1)] = m.group(2) + " " + m.group(3)
    return out


def phases(lines):
    out = {}
    for l in lines:
        m = PHASE_RE.search(l)
        if m and m.group(1) not in out:
            out[m.group(1)] = float(m.group(2))
    return out


def poll_once(lane):
    """One console + ring read, no retries (the Server DataModel does not exist yet early in Play)."""
    got = []
    try:
        got += str(lane.text(lane.mcp([{"name": "execute_luau", "arguments": {"datamodel_type": "Server", "code": BOOTLOG_LUA},
                                         "timeout": 30}], "bootlog", timeout=90))).splitlines()
    except Exception:  # noqa: BLE001 - before the server is up, or a busy bridge: the next poll covers it
        pass
    try:
        got += str(lane.console()).splitlines()
    except Exception:  # noqa: BLE001
        pass
    return got


def main(argv):
    import lane  # noqa: E402 - Studio bridge; imported here so the pure helpers above are testable offline

    key = argv[1]
    secs = int(argv[2]) if len(argv) > 2 else 45
    lane.luau(f"workspace:SetAttribute('ActiveTrackKey', '{key}') return workspace:GetAttribute('ActiveTrackKey')", dm="Edit", name="atk")
    t0 = time.time()
    lane.play(True)
    seen_lines = []
    caps = []
    boot_s = None

    def poll():
        seen_lines.extend(poll_once(lane))

    try:
        while time.time() - t0 < 240:
            time.sleep(POLL_S)
            poll()
            if any("[SkyRally][BOOT] Server initialized" in l for l in seen_lines):
                break
        boot_s = time.time() - t0
        for frac, tag in ((0.3, "a"), (0.35, "b"), (0.35, "c")):
            end = time.time() + secs * frac
            while time.time() < end:
                time.sleep(min(POLL_S, max(0.0, end - time.time())))
                poll()
            caps.append(lane.capture(f"{key}_{tag}"))
        poll()
    finally:
        lane.play(False)
        lane.luau("workspace:SetAttribute('ActiveTrackKey', nil) return 'cleared'", dm="Edit", name="atk")
    keep = select_lines(seen_lines)
    director = director_verdict(keep, key)
    ok = bool(director and director["ok"] and director["errors"] == 0)
    out = {"key": key, "bootSeconds": round(boot_s or 0, 1), "captures": caps, "directorOk": ok, "director": director,
           "buildSteps": build_steps(keep), "phases": phases(keep), "lines": keep, "polledLines": len(seen_lines)}
    Path(lane.OUT / f"mapboot_{key}.json").write_text(json.dumps(out, indent=1))
    print(f"BOOT {key} {out['bootSeconds']:.1f}s")
    print(("DIRECTOR_OK " if ok else ("DIRECTOR_FAILED " if director else "DIRECTOR_MISSING ")) + (director["line"] if director else key))
    for mid, st in out["buildSteps"].items():
        print(f"  STEPS {mid} {st[:400]}")
    for l in keep[:160]:
        print(" ", l[:260])
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
