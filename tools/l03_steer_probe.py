#!/usr/bin/env python3
"""TEST_LIST_LAUNCH L03 probe: does held keyboard steering move the plane while the default
steering assist is on? Real key events go through Studio's user_keyboard_input (the engine input
path); a client-side sampler records what UserInputService saw plus hull yaw and ribbon distance.

Usage: l03_steer_probe.py <tag>
Writes out/l03_<tag>.json and stamped captures out/l03_<tag>_*.png.
"""
import json
import sys
import time

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
import lane  # noqa: E402

TAG = sys.argv[1] if len(sys.argv) > 1 else "run"

SAMPLER = r"""
local Players = game:GetService('Players')
local UIS = game:GetService('UserInputService')
local RS = game:GetService('ReplicatedStorage')
local Spline = require(RS:WaitForChild('Shared'):WaitForChild('SplineUtils'))
local lp = Players.LocalPlayer
_G.L03 = {}
_G.L03Run = true
task.spawn(function()
	local t0 = os.clock()
	while _G.L03Run and os.clock() - t0 < 60 do
		local hull
		local planes = workspace:FindFirstChild('Planes')
		if planes then
			for _, m in planes:GetChildren() do
				if m.Name:find(lp.Name, 1, true) and m:FindFirstChild('Hull') then hull = m.Hull end
			end
		end
		if hull then
			local lv = hull.CFrame.LookVector
			local yaw = math.deg(math.atan2(-lv.X, -lv.Z))
			local ok, st, _, _, dist = pcall(Spline.projectPosition, hull.Position, lp:GetAttribute('Station'))
			table.insert(_G.L03, {
				t = math.floor((os.clock() - t0) * 100) / 100,
				a = UIS:IsKeyDown(Enum.KeyCode.A), d = UIS:IsKeyDown(Enum.KeyCode.D),
				yaw = math.floor(yaw * 10) / 10,
				st = ok and math.floor(st) or -1,
				dist = ok and math.floor((dist or -1) * 10) / 10 or -1,
				spd = math.floor((lp:GetAttribute('Speed') or 0)),
				cp = lp:GetAttribute('Checkpoint'), lap = lp:GetAttribute('Lap'),
				sx = lp:GetAttribute('SteerX'), px = lp:GetAttribute('PlayerSteerX'), aw = lp:GetAttribute('AssistWeight'),
				cr = lp:GetAttribute('Crashing'), why = lp:GetAttribute('LastCrashReason'), part = lp:GetAttribute('LastCrashPart'), n = lp:GetAttribute('CrashCount'),
				x = math.floor(hull.Position.X), y = math.floor(hull.Position.Y), z = math.floor(hull.Position.Z),
			})
		end
		task.wait(0.1)
	end
end)
return 'SAMPLER_STARTED hull_search=' .. tostring(workspace:FindFirstChild('Planes') ~= nil)
"""

READ = r"""
_G.L03Run = false
local H = game:GetService('HttpService')
return H:JSONEncode(_G.L03 or {})
"""


def main():
    res = {"tag": TAG, "utc_start": lane.utc(), "head": lane.git_head()}
    print("state:", lane.state()[:300])
    res["play"] = lane.play(True)
    time.sleep(25)
    res["console_boot"] = lane.console()[-6000:]
    cap = lane.capture(f"l03_{TAG}_start")
    if cap:
        res["capture_start"] = lane.stamp(cap, f"L03 {TAG} start (own window, real input)")
    res["sampler"] = lane.luau(SAMPLER, dm="Client", name="l03_sampler")
    def W(ms):
        return {"action": "wait", "wait_time_ms": ms}
    seq = [W(3000),
           {"action": "keyDown", "key_code": "A"}, W(3000), {"action": "keyUp", "key_code": "A"},
           W(3000),
           {"action": "keyDown", "key_code": "D"}, W(3000), {"action": "keyUp", "key_code": "D"},
           W(3000)]
    res["keys"] = lane.keys(seq, name="l03_keys", timeout=120)
    cap = lane.capture(f"l03_{TAG}_end")
    if cap:
        res["capture_end"] = lane.stamp(cap, f"L03 {TAG} end")
    raw = lane.luau(READ, dm="Client", name="l03_read")
    try:
        res["samples"] = json.loads(raw[raw.index("["):])
    except Exception:
        res["samples_raw"] = raw[:3000]
    res["console_end"] = lane.console()[-4000:]
    res["stop"] = lane.play(False)
    res["utc_end"] = lane.utc()
    p = lane.OUT / f"l03_{TAG}.json"
    p.write_text(json.dumps(res, indent=1))
    print("wrote", p)


if __name__ == "__main__":
    main()
