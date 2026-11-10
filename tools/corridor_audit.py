#!/usr/bin/env python3
"""Course clearance audit (L02 gate, reused per map): sweeps the race spline in the own Studio window's
Play server and reports every obstruction in the flight corridor. Usage: corridor_audit.py <tag>
Writes out/corridor_<tag>.json and prints blocked station ranges grouped by blocking instance."""
import json
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

TAG = sys.argv[1] if len(sys.argv) > 1 else "run"
STEP, RADIUS, HEIGHT = 10, 4, 14
OFFSETS = [(0, 0), (-14, 0), (14, 0), (0, 10), (0, -6)]


def ranges(sts, gap=30):
    sts = sorted(set(sts))
    out, a, b = [], None, None
    for s in sts:
        if a is None:
            a = b = s
        elif s - b <= gap:
            b = s
        else:
            out.append((a, b)); a = b = s
    if a is not None:
        out.append((a, b))
    return out


def main():
    code = (Path(__file__).resolve().parent / "luau" / "corridor_audit.luau").read_text()
    code = (code.replace("__STEP__", str(STEP)).replace("__RADIUS__", str(RADIUS)).replace("__HEIGHT__", str(HEIGHT))
            .replace("__OFFSETS__", "{" + ",".join("{%d,%d}" % o for o in OFFSETS) + "}"))
    lane.play(True)
    time.sleep(25)
    t = lane.luau(code, dm="Server", name=f"corridor_{TAG}", timeout=240)
    lane.play(False)
    d = json.loads(t[t.index("{"):])
    d["params"] = {"step": STEP, "radius": RADIUS, "height": HEIGHT, "offsets": OFFSETS, "utc": lane.utc(), "head": lane.git_head()}
    (lane.OUT / f"corridor_{TAG}.json").write_text(json.dumps(d, indent=1))
    s = d["summary"]
    print(f"samples={s['samples']} blockedCentre={s['blockedCentre']} blockedAny={s['blockedAny']} length={s['length']}")
    by = defaultdict(list)
    for b in d["blocks"]:
        key = b["name"].replace("Workspace.DINO-4_TrackModel.DINO-4.", "")
        if b["cls"] == "Terrain":
            key = f"Terrain[{b['mat']}]"
        by[(key, b["o"] == 1, b["lava"])].append(b["st"])
    for (k, centre, lava), sts in sorted(by.items(), key=lambda kv: min(kv[1])):
        rs = ", ".join(f"{a}-{b}" if a != b else str(a) for a, b in ranges(sts))
        print(f"{'CENTRE' if centre else 'offset'} {'LAVA ' if lava else ''}{k}: n={len(sts)} st[{rs}]")
    width_report(d)


def width_report(d, min_half=22, min_up=16):
    """Pinch points: half-width (to nearest wall left/right) under min_half or headroom under min_up. -1 = open."""
    pinches = []
    for w in d.get("widths", []):
        L, R, U = [x if x >= 0 else 999 for x in (w["L"], w["R"], w["U"])]
        if min(L, R) < min_half or U < min_up:
            pinches.append((w["st"], L, R, U))
    print(f"pinch samples (half-width<{min_half} or headroom<{min_up}): {len(pinches)}")
    for a, b in ranges([p[0] for p in pinches]):
        seg = [p for p in pinches if a <= p[0] <= b]
        print(f"  st {a}-{b}: minL={min(p[1] for p in seg)} minR={min(p[2] for p in seg)} minUp={min(p[3] for p in seg)}")


if __name__ == "__main__":
    main()
