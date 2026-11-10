#!/usr/bin/env python3
"""Real-input race run (L02, T01-T03): Play in the own window, fly with win/key_pilot.js (keyboard events only,
assist off by default), stamped captures every 20 s, then summary from the pilot's per-tick log.
Usage: pilot_run.py <tag> [seconds] [assist=on|off] [skill=0..1] [goal=verify] [boost=1]
goal=verify (S1): coin-chasing, item-firing pilot for coin 8/8 and race/boss win attempts without seeding (docs/STUDIO_ROUND_V22.md)."""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

tag = sys.argv[1]
secs = int(sys.argv[2]) if len(sys.argv) > 2 else 200
assist = sys.argv[3] if len(sys.argv) > 3 else "assist=off"
skill = sys.argv[4] if len(sys.argv) > 4 else "skill=1"
extra = " ".join(a for a in sys.argv[5:] if a.split("=")[0] in ("goal", "boost"))


def main():
    lane.sync(["win"])
    lane.play(True)
    time.sleep(18)
    pc_out = f"{lane.PCWIN}\\out\\pilot_{tag}.jsonl"
    proc = subprocess.Popen(["ssh", "-o", "BatchMode=yes", "-i", lane.KEY, lane.HOST,
                             f"node {lane.PCWIN}\\win\\key_pilot.js {pc_out} {secs} {assist} {skill}{(' ' + extra) if extra else ''}"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    caps, t0 = [], time.time()
    while proc.poll() is None and time.time() - t0 < secs + 60:
        time.sleep(20)
        c = lane.capture(f"pilot_{tag}_{int(time.time() - t0):03d}")
        if c:
            caps.append(lane.stamp(c, f"real-key pilot {tag} {assist} +{int(time.time() - t0)}s"))
    proc.wait(timeout=120)
    lane.get(f"out/pilot_{tag}.jsonl", lane.OUT / f"pilot_{tag}.jsonl")
    console = [l for l in lane.console().splitlines() if "[SkyRally]" in l and "ASSETPROBE] OK" not in l][-40:]
    lane.play(False)
    rows = [json.loads(l) for l in (lane.OUT / f"pilot_{tag}.jsonl").read_text().splitlines() if l.strip()]
    ticks = [r for r in rows if "st" in r]
    end = next((r for r in rows if r.get("event") == "end"), {})
    crashes = []
    prev = None
    for r in ticks:
        if prev is not None and r["crashes"] > prev["crashes"]:
            crashes.append({"t": r["t"], "st": prev["st"], "why": r["why"]})
        prev = r
    keyticks = sum(1 for r in ticks if any(k != "W" for k in r["keys"]))
    summary = {"tag": tag, "assist": assist, "skill": skill, "extra": extra, "maxCoins": max((r.get("coins", 0) for r in ticks), default=0), "utc": lane.utc(), "head": lane.git_head(), "ticks": len(ticks),
               "hz": end.get("hz"), "maxLap": max((r["lap"] for r in ticks), default=0), "finished": any(r["fin"] for r in ticks), "finishRank": next((r.get("rank") for r in ticks if r["fin"]), None),
               "finishT": next((r["t"] for r in ticks if r["fin"]), None), "overchargeTicks": sum(1 for r in ticks if r.get("spd", 0) >= 200),
               "crashes": crashes, "steerTicks": keyticks, "captures": caps, "console": console,
               "toggle": next((r for r in rows if r.get("event") == "assist_toggle"), None)}
    (lane.OUT / f"pilot_{tag}_summary.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps({k: v for k, v in summary.items() if k not in ("captures", "console")}, indent=1))


if __name__ == "__main__":
    main()
