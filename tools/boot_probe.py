#!/usr/bin/env python3
"""Boot timeline probe (TEST_LIST L42, perf pass 2026-10-19) in the lane's own Studio window: N fresh Plays, each waits
for the loading screen to log "[SkyRally][LOAD] join_to_control=..." and collects the boot timeline from the output:
  [SkyRally][BOOT] phase=<name> t=<s since server start> ...   (server/BootClock)
  [SkyRally][MAP]  <id> steps ...                             (MapAdapter step seconds)
  [30MAPS] DONE ... in <s>                                    (compiled builder)
  [SkyRally][DIRECTOR] load ... in <s>                         (whole TrackDirector.load)
plus the hub root's AdapterStep_* attributes. Writes evidence/L40/boot_<commit>[_tag].json and prints a summary.
Usage: boot_probe.py [--runs 3] [--tag before]"""
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

runs = int(next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--runs=")), "3"))
tag = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--tag=")), "")

WAIT_LOAD = r"""
local P = game:GetService('Players').LocalPlayer
return tostring(P and P:GetAttribute('LoadingDone')) .. '|' .. tostring(P and P:GetAttribute('LoadLog'))
"""

STEPS = r"""
local maps = workspace:FindFirstChild('Maps')
local out = {}
if maps then
  for _, r in maps:GetChildren() do
    local a = {}
    for k, v in r:GetAttributes() do
      if string.sub(k, 1, 12) == 'AdapterStep_' then a[string.sub(k, 13)] = tostring(v) end
    end
    a.BuildSteps = tostring(r:GetAttribute('BuildSteps'))
    a.TerrainBaked = tostring(r:GetAttribute('TerrainBaked'))
    out[r.Name] = a
  end
end
out.BootTimeline = tostring(workspace:GetAttribute('BootTimeline')) .. ' stalls: ' .. tostring(workspace:GetAttribute('BootServerStalls'))
return game:GetService('HttpService'):JSONEncode(out)
"""

KEEP = re.compile(r"\[SkyRally\]\[(LOAD|BOOT|DIRECTOR)\]|\[30MAPS\] (DONE|terrain:|terrain done|terrain bake|plan)|\[SkyRally\]\[MAP\] \S+ (steps|built|artSwap)|\[SkyRally\]\[ASSETS\] (bird|flame|item art|part=|car model|plane model|prewarm)|PilotSeat|\[SkyRally\]\[CLIENT\]")


def one(i):
    lane.play(True)
    t0 = time.time()
    try:
        load = ""
        while time.time() - t0 < 90:
            time.sleep(4)
            st = str(lane.luau(WAIT_LOAD, dm="Client", name="bp_wait"))
            if st.startswith("true|"):
                load = st.split("|", 1)[1].strip()
                break
        time.sleep(6)  # late boot lines (SelfTest, item art) after control
        steps = str(lane.luau(STEPS, dm="Server", name="bp_steps"))
        con = lane.console()
    finally:
        lane.play(False)
    lines = [ln.strip() for ln in con.splitlines() if KEEP.search(ln)]
    load = load if "[SkyRally][LOAD]" in load else next((ln for ln in lines if "[SkyRally][LOAD]" in ln), "")
    m = re.search(r"join_to_control=([\d.]+)s", load)
    s = steps[steps.find("{"): steps.rfind("}") + 1] if "{" in steps else "{}"
    try:
        stepd = json.loads(s)
    except Exception:
        stepd = {"raw": s[:400]}
    rec = {"run": i, "joinToControlS": float(m.group(1)) if m else None, "loadLine": load, "lines": lines, "adapterSteps": stepd}
    print(f"run {i}: {load}", flush=True)
    print(f"    boot: {stepd.get('BootTimeline')}", flush=True)
    for k, v in stepd.items():
        if isinstance(v, dict):
            print(f"    {k}: baked={v.get('TerrainBaked')} {v.get('BuildSteps')}", flush=True)
    for ln in lines:
        if "[BOOT]" in ln or "[DIRECTOR] load" in ln or "[30MAPS]" in ln or "steps" in ln or "prewarm" in ln:
            print("   ", ln[:400], flush=True)
    return rec


def main():
    lane.luau("workspace:SetAttribute('UnlockAll', nil) workspace:SetAttribute('AutoPilot', nil) workspace:SetAttribute('ActiveTrackKey', nil) return 1",
              dm="Edit", name="bp_flags")
    recs = []
    for i in range(1, runs + 1):
        recs.append(one(i))
        time.sleep(5)
    vals = [r["joinToControlS"] for r in recs if r["joinToControlS"] is not None]
    out = lane.ROOT / "evidence" / "L40" / f"boot_{lane.git_head()[:7]}{'_' + tag if tag else ''}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"commit": lane.git_head(), "utc": lane.utc(), "tag": tag, "runs": recs,
                               "joinToControlS": vals}, indent=1))
    print("join_to_control:", vals, "mean=%.2f" % (sum(vals) / len(vals)) if vals else "-")
    print(out)


if __name__ == "__main__":
    main()
