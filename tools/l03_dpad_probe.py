#!/usr/bin/env python3
"""TEST_LIST_LAUNCH L03 (D-pad half): press-and-hold the on-screen steer pad with real mouse input
(user_mouse_input, the engine input path) and record the controller's PlayerSteerX / SteerX.

V1 D5 (2026-10-22): touch steer v2 (`de5f739`) has a floating origin (TouchSteerRules.origin): the stick centres where
the thumb lands, so a tap without a drag reads only about 0.2. The probe now presses at the pad centre and drags past the
stick radius (TouchSteerRules.radius = 0.42 x pad side, clamps beyond), then holds 2.5 s: expect PlayerSteerX about
-1.0 / +1.0 (final steer about -0.98 / +0.98)."""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

PAD = r"""
local lp = game:GetService('Players').LocalPlayer
local gs = game:GetService('GuiService')
local hud = lp.PlayerGui:WaitForChild('SkyRallyHUD')
local pad = hud:FindFirstChild('LeftSteerZone', true)
local inset = gs:GetGuiInset()
return game:GetService('HttpService'):JSONEncode({x = pad.AbsolutePosition.X, y = pad.AbsolutePosition.Y, w = pad.AbsoluteSize.X, h = pad.AbsoluteSize.Y, ix = inset.X, iy = inset.Y, vp = {workspace.CurrentCamera.ViewportSize.X, workspace.CurrentCamera.ViewportSize.Y}})
"""
SAMPLER = r"""
local lp = game:GetService('Players').LocalPlayer
_G.DP = {}; _G.DPRun = true
task.spawn(function()
	local t0 = os.clock()
	while _G.DPRun and os.clock() - t0 < 30 do
		table.insert(_G.DP, {t = math.floor((os.clock() - t0) * 100) / 100, px = lp:GetAttribute('PlayerSteerX'), sx = lp:GetAttribute('SteerX'), aw = lp:GetAttribute('AssistWeight')})
		task.wait(0.1)
	end
end)
return 'ok'
"""


def main():
    res = {"utc": lane.utc(), "head": lane.git_head()}
    lane.play(True)
    time.sleep(22)
    lane.luau("game:GetService('Players').LocalPlayer:SetAttribute('ForceInputMode','Touch') task.wait(0.3) return 'forced'", dm="Client", name="dpad_force")
    t = lane.luau(PAD, dm="Client", name="dpad_geom")
    g = json.loads(t[t.index("{"):])
    res["pad"] = g
    cx, cy = g["x"] + g["w"] / 2 + g["ix"], g["y"] + g["h"] / 2 + g["iy"]
    reach = g["w"] * 0.45  # past the 0.42 x side stick radius: full deflection
    left, right = (cx - reach, cy), (cx + reach, cy)
    lane.luau(SAMPLER, dm="Client", name="dpad_sampler")
    W = lambda ms: {"action": "wait", "wait_time_ms": ms}
    acts = [W(1500),
            {"action": "moveTo", "x": cx, "y": cy}, {"action": "mouseButtonDown", "mouse_button": "left"}, W(200),
            {"action": "moveTo", "x": left[0], "y": left[1]}, W(2500),
            {"action": "mouseButtonUp", "mouse_button": "left"}, W(1500),
            {"action": "moveTo", "x": cx, "y": cy}, {"action": "mouseButtonDown", "mouse_button": "left"}, W(200),
            {"action": "moveTo", "x": right[0], "y": right[1]}, W(2500),
            {"action": "mouseButtonUp", "mouse_button": "left"}, W(1500)]
    res["mouse"] = lane.text(lane.mcp([{"name": "user_mouse_input", "arguments": {"datamodel_type": "Client", "actions": acts}, "timeout": 120}], "dpad_mouse"))
    raw = lane.luau("_G.DPRun=false return game:GetService('HttpService'):JSONEncode(_G.DP)", dm="Client", name="dpad_read")
    res["samples"] = json.loads(raw[raw.index("["):])
    lane.play(False)
    (lane.OUT / "l03_dpad.json").write_text(json.dumps(res, indent=1))
    print("pad", g, "mouse", res["mouse"][:200])
    for x in res["samples"][::3]:
        print(x)


if __name__ == "__main__":
    main()
