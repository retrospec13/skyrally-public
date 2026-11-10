#!/usr/bin/env python3
"""D20 / L80-L81 input probe: real keyboard and gamepad events through Studio's input path, then a mouse drag
on the touch pad. Records what the controller saw (PlayerSteerX), the InputMode and touch-zone visibility."""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

SAMPLER = r"""
local lp = game:GetService('Players').LocalPlayer
local UIS = game:GetService('UserInputService')
_G.IP = {}; _G.IPRun = true
task.spawn(function()
	local t0 = os.clock()
	while _G.IPRun and os.clock() - t0 < 40 do
		local hud = lp.PlayerGui:FindFirstChild('SkyRallyHUD')
		local pad = hud and hud:FindFirstChild('LeftSteerZone', true)
		local hint = lp.PlayerGui:FindFirstChild('SkyRallyControlsHint')
		table.insert(_G.IP, {t = math.floor((os.clock() - t0) * 10) / 10, px = lp:GetAttribute('PlayerSteerX'), sx = lp:GetAttribute('SteerX'),
			mode = lp:GetAttribute('InputMode'), padVis = pad and pad.Visible, gp = UIS:GetGamepadConnected(Enum.UserInputType.Gamepad1),
			hint = hint and hint.Hint.Visible and hint.Hint.Text or nil, last = UIS:GetLastInputType().Name})
		task.wait(0.25)
	end
end)
return 'ok'
"""


def W(ms):
    return {"action": "wait", "wait_time_ms": ms}


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else "run"
    res = {"utc": lane.utc(), "head": lane.git_head()}
    lane.play(True)
    time.sleep(20)
    lane.luau(SAMPLER, dm="Client", name="ip_sampler")
    seq = [W(1000),
           {"action": "keyDown", "key_code": "A"}, W(2000), {"action": "keyUp", "key_code": "A"}, W(1500),
           {"action": "keyDown", "key_code": "DPadLeft"}, W(2000), {"action": "keyUp", "key_code": "DPadLeft"}, W(1500),
           {"action": "keyDown", "key_code": "Thumbstick1Right"}, W(2000), {"action": "keyUp", "key_code": "Thumbstick1Right"}, W(1500),
           {"action": "keyDown", "key_code": "ButtonR1"}, W(1500), {"action": "keyUp", "key_code": "ButtonR1"}, W(1000)]
    res["keys"] = lane.keys(seq, name="ip_keys", timeout=120)
    g = json.loads((lambda t: t[t.index("{"):])(lane.luau(
        "local p=game:GetService('Players').LocalPlayer.PlayerGui.SkyRallyHUD.LeftSteerZone local i=game:GetService('GuiService'):GetGuiInset() "
        "return game:GetService('HttpService'):JSONEncode({x=p.AbsolutePosition.X,y=p.AbsolutePosition.Y,w=p.AbsoluteSize.X,h=p.AbsoluteSize.Y,iy=i.Y})",
        dm="Client", name="ip_pad")))
    cx, cy = g["x"] + g["w"] / 2, g["y"] + g["h"] / 2 + g["iy"]
    acts = [{"action": "moveTo", "x": cx - g["w"] * 0.35, "y": cy}, {"action": "mouseButtonDown", "mouse_button": "left"}, W(2000),
            {"action": "mouseButtonUp", "mouse_button": "left"}, W(1500)]
    res["mouse"] = lane.text(lane.mcp([{"name": "user_mouse_input", "arguments": {"datamodel_type": "Client", "actions": acts}, "timeout": 60}], "ip_mouse"))
    cap = lane.capture(f"input_{tag}")
    res["capture"] = lane.stamp(cap, f"input probe {tag}") if cap else None
    lane.luau("_G.IPRun=false return 'x'", dm="Client", name="ip_stop")
    res["samples"] = lane.read_g_list("IP", dm="Client", name="ip_read")
    lane.play(False)
    (lane.OUT / f"input_{tag}.json").write_text(json.dumps(res, indent=1))
    prev = None
    for x in res["samples"]:
        k = (x.get("px"), x.get("mode"), x.get("padVis"), x.get("last"), x.get("gp"))
        if k != prev:
            print(x)
            prev = k


if __name__ == "__main__":
    main()
