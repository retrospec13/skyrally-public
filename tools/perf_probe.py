#!/usr/bin/env python3
"""Per-map performance probe (TEST_LIST L40-L42) in the lane's own Studio window: Play, then for each map request a race
through the Adventure-board remote (UnlockAll, AutoPilot so the vehicle drives the route), wait for GO, and sample the
CLIENT for a while: frame time (mean, p95, worst), total memory and the main memory tags, instance and part counts, and
the server's director load time. Studio on the PC is not a phone: frame numbers are relative; memory, counts and load
times are the comparable figures. Writes evidence/L40/perf_<commit>.json and prints a table.
Usage: perf_probe.py [hub dino4 snow1 island2 forest1 space4] [--secs 25]"""
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

args = [a for a in sys.argv[1:] if not a.startswith("--")]
secs = int(next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--secs=")), "25"))
maps = args or ["hub", "dino4", "snow1", "island2", "forest1", "space4"]
TRACK_ID = {"dino4": "DINO-4", "snow1": "SNOW-1", "island2": "ISLAND-2", "forest1": "FOREST-1", "space4": "SPACE-4"}

SAMPLE = r"""
local RS = game:GetService('RunService')
local Stats = game:GetService('Stats')
local dts = {}
local t0 = os.clock()
local conn = RS.RenderStepped:Connect(function(dt) table.insert(dts, dt) end)
while os.clock() - t0 < %d do task.wait(0.5) end
conn:Disconnect()
table.sort(dts)
local sum = 0 for _, d in dts do sum += d end
local function tag(t) local ok, v = pcall(function() return Stats:GetMemoryUsageMbForTag(t) end) return ok and math.floor(v) or -1 end
local parts, inst = 0, 0
for _, d in workspace:GetDescendants() do inst += 1 if d:IsA('BasePart') then parts += 1 end end
return game:GetService('HttpService'):JSONEncode({
  frames = #dts, meanMs = #dts > 0 and math.floor(sum / #dts * 10000) / 10 or -1,
  p95Ms = #dts > 0 and math.floor(dts[math.max(1, math.floor(#dts * 0.95))] * 10000) / 10 or -1,
  worstMs = #dts > 0 and math.floor(dts[#dts] * 10000) / 10 or -1,
  memMb = math.floor(Stats:GetTotalMemoryUsageMb()),
  texMb = tag(Enum.DeveloperMemoryTag.GraphicsTexture), meshMb = tag(Enum.DeveloperMemoryTag.GraphicsMeshParts),
  partsMb = tag(Enum.DeveloperMemoryTag.GraphicsParts), terrainMb = tag(Enum.DeveloperMemoryTag.GraphicsTerrain),
  soundMb = tag(Enum.DeveloperMemoryTag.Sounds), instances = Stats.InstanceCount, wsInstances = inst, wsParts = parts,
  map = workspace:GetAttribute('ActiveTrackId'),
})
"""


def json_of(text):
    s = str(text)
    i, j = s.find("{"), s.rfind("}")
    return json.loads(s[i:j + 1]) if i >= 0 else {"raw": s[:300]}


def back_to_hub():
    """From a race, ask for the hub (RequestHub; solo it returns at once) and wait until the hub is up again."""
    t0 = time.time()
    while time.time() - t0 < 120:
        st = str(lane.luau("return tostring(workspace:GetAttribute('RaceMode')) .. ' ' .. tostring(workspace:GetAttribute('TrackSwitching'))",
                           dm="Client", name="pp_mode"))
        if "hub false" in st:
            time.sleep(3)
            return
        if "true" not in st:
            lane.luau("game.ReplicatedStorage.SkyRallyRemotes.TrackFlowRemote:FireServer('RequestHub') return 1", dm="Client", name="pp_hub")
        time.sleep(5)


def main():
    lane.luau("workspace:SetAttribute('UnlockAll', true) workspace:SetAttribute('AutoPilot', true) return 1", dm="Edit", name="pp_flags")
    lane.play(True)
    rows = {}
    try:
        time.sleep(30)
        for m in maps:
            if m != "hub":
                # The board takes the track id (TrackDirector keyById) and only opens a race from the hub.
                back_to_hub()
                lane.luau(f"game.ReplicatedStorage.SkyRallyRemotes.TrackFlowRemote:FireServer('RequestRace','{TRACK_ID[m]}','race') return 1",
                          dm="Client", name="pp_req")
                t0 = time.time()
                while time.time() - t0 < 180:
                    time.sleep(5)
                    st = lane.luau("return tostring(workspace:GetAttribute('ActiveTrackId')) .. ' ' .. tostring(workspace:GetAttribute('TrackSwitching'))"
                                   " .. ' ' .. tostring((workspace:GetAttribute('RaceGoTime') or 0) < workspace:GetServerTimeNow())",
                                   dm="Client", name="pp_state")
                    if TRACK_ID[m] in str(st) and "false true" in str(st):
                        break
                time.sleep(4)
            rows[m] = json_of(lane.luau(SAMPLE % secs, dm="Client", name=f"pp_{m}", timeout=secs + 120))
            con = lane.console()
            loads = re.findall(r"\[SkyRally\]\[DIRECTOR\] load (\w+) .*?built in ([\d.]+)s", con)
            cached = re.findall(r"\[SkyRally\]\[MAPCACHE\] restored (\w+).*? in ([\d.]+)s", con)
            rows[m]["serverLoadS"] = next((float(t) for k, t in reversed(loads) if k == (m if m != "hub" else "hub0")), None)
            rows[m]["cacheRestoreS"] = next((float(t) for k, t in reversed(cached) if k == (m if m != "hub" else "hub0")), None)
            # Where the build spent its time (MapAdapter BuildSteps on the root; readable after the output has scrolled).
            steps = str(lane.luau("local r = workspace:FindFirstChild('Maps') and workspace.Maps:FindFirstChild(tostring(workspace:GetAttribute('ActiveTrackId')))"
                                  " return r and (tostring(r:GetAttribute('BuildSteps')) .. ' baked=' .. tostring(r:GetAttribute('TerrainBaked'))) or 'none'",
                                  dm="Server", name="pp_steps"))
            rows[m]["buildSteps"] = steps.strip()[:600]
            print(m, rows[m], flush=True)
    finally:
        lane.play(False)
    out = lane.ROOT / "evidence" / "L40" / f"perf_{lane.git_head()[:7]}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"commit": lane.git_head(), "utc": lane.utc(), "secs": secs, "maps": rows}, indent=1))
    print(f"{'map':8} {'meanMs':>7} {'p95Ms':>6} {'memMb':>6} {'texMb':>6} {'meshMb':>6} {'terrMb':>6} {'parts':>6} {'loadS':>6}")
    for m, r in rows.items():
        print(f"{m:8} {r.get('meanMs', '-'):>7} {r.get('p95Ms', '-'):>6} {r.get('memMb', '-'):>6} {r.get('texMb', '-'):>6} "
              f"{r.get('meshMb', '-'):>6} {r.get('terrainMb', '-'):>6} {r.get('wsParts', '-'):>6} {r.get('serverLoadS') or '-':>6}")
    print(out)


if __name__ == "__main__":
    main()
