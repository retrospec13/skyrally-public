#!/usr/bin/env python3
"""Full-race run in the own Studio window with telemetry (L02 and race rows).
Usage: lap_run.py <tag> [seconds] [--keys pilot.json]
Records lap/checkpoint/station/crashes/finish at 5 Hz on the client and takes stamped captures every 20 s.
Optional --keys: a JSON list of user_keyboard_input actions sent once at the start (real input path).
Writes out/lap_<tag>.json and prints a summary (crashes with the part hit, laps, finish)."""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

TAG = sys.argv[1] if len(sys.argv) > 1 else "run"
SECS = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 170
KEYS = None
if "--keys" in sys.argv:
    KEYS = json.loads(Path(sys.argv[sys.argv.index("--keys") + 1]).read_text())

SAMPLER = r"""
local lp = game:GetService('Players').LocalPlayer
_G.LR = {}; _G.LRRun = true
task.spawn(function()
	local t0 = os.clock()
	local lastN = lp:GetAttribute('CrashCount') or 0
	while _G.LRRun and os.clock() - t0 < __SECS__ do
		local planes = workspace:FindFirstChild('Planes')
		local hull
		if planes then for _, m in planes:GetChildren() do if m.Name:find(lp.Name, 1, true) and m:FindFirstChild('Hull') then hull = m.Hull end end end
		local n = lp:GetAttribute('CrashCount') or 0
		table.insert(_G.LR, {
			t = math.floor((os.clock() - t0) * 10) / 10, st = lp:GetAttribute('Station'), lap = lp:GetAttribute('Lap'),
			cp = lp:GetAttribute('Checkpoint'), rank = lp:GetAttribute('Rank'), n = n,
			crash = (n > lastN) and (tostring(lp:GetAttribute('LastCrashReason')) .. ' ' .. tostring(lp:GetAttribute('LastCrashPart')) .. ' @' .. tostring(lp:GetAttribute('LastCrashPos'))) or nil,
			fin = lp:GetAttribute('RaceFinished'), frank = lp:GetAttribute('FinishRank'), ftime = lp:GetAttribute('FinishTime'),
			sx = lp:GetAttribute('SteerX'), px = lp:GetAttribute('PlayerSteerX'),
			y = hull and math.floor(hull.Position.Y) or nil, x = hull and math.floor(hull.Position.X) or nil, z = hull and math.floor(hull.Position.Z) or nil,
			spd = lp:GetAttribute('Speed'), boost = hull and hull.Parent and hull.Parent:GetAttribute('BoostState') or nil, aw = lp:GetAttribute('AssistWeight'),
		})
		lastN = n
		task.wait(0.2)
	end
end)
return 'ok'
"""


def main():
    res = {"tag": TAG, "utc_start": lane.utc(), "head": lane.git_head(), "secs": SECS}
    lane.play(True)
    time.sleep(18)
    res["sampler"] = lane.luau(SAMPLER.replace("__SECS__", str(SECS)), dm="Client", name=f"lap_{TAG}_sampler")
    if KEYS:
        res["keys"] = lane.keys(KEYS, name=f"lap_{TAG}_keys", timeout=SECS + 60)
    caps = []
    t0 = time.time()
    while time.time() - t0 < SECS:
        time.sleep(20)
        c = lane.capture(f"lap_{TAG}_{int(time.time() - t0):03d}")
        if c:
            caps.append(lane.stamp(c, f"lap {TAG} +{int(time.time() - t0)}s"))
    lane.luau("_G.LRRun=false return 'stopped'", dm="Client", name=f"lap_{TAG}_stop")
    res["samples"] = lane.read_g_list("LR", dm="Client", name=f"lap_{TAG}_read")
    res["captures"] = caps
    res["console"] = "\n".join(l for l in lane.console().splitlines() if "[SkyRally]" in l or "[Track]" in l or "Race" in l)[-6000:]
    lane.play(False)
    res["utc_end"] = lane.utc()
    (lane.OUT / f"lap_{TAG}.json").write_text(json.dumps(res, indent=1))
    s = res["samples"]
    crashes = [(x["t"], x["st"], x["crash"]) for x in s if x.get("crash")]
    laps = max((x.get("lap") or 0) for x in s) if s else 0
    fin = next((x for x in s if x.get("fin")), None)
    print(f"samples={len(s)} maxLap={laps} crashes={len(crashes)} finished={bool(fin)} "
          f"{'rank=%s time=%s' % (fin.get('frank'), fin.get('ftime')) if fin else ''}")
    for c in crashes:
        print("CRASH t=%s st=%s %s" % c)
    for x in s[::25]:
        print({k: x.get(k) for k in ("t", "st", "lap", "cp", "rank", "n", "y", "sx")})


if __name__ == "__main__":
    main()
