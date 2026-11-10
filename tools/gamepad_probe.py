#!/usr/bin/env python3
"""TG-5 / L81: can the MCP bridge send GAMEPAD input to Studio? Sends gamepad KeyCodes (Thumbstick1Right/Left, DPadLeft,
ButtonA throttle, ButtonB brake, ButtonR1 bank) through user_keyboard_input (lane.keys) while a client sampler records what
Studio's input stack actually saw: UserInputService:GetLastInputType(), GetGamepadConnected, the controller's PlayerSteerX and
the InputMode attribute. Then a menu pass (DPadDown/ButtonA) records GuiService.SelectedObject.

Verdict (classify):
  WORKS    the last input type became Gamepad1 AND the stick moved PlayerSteerX: L81 can be run through the bridge.
  PARTIAL  the controller reacted to the key codes but Studio still reports keyboard input (the key codes act as keys, no
           gamepad input family, no hint/prompt switching): steer/throttle rows may be read, the menu-selection and
           input-family rows (L81 menus, L82) stay BLOCKED for the owner's physical gamepad.
  BLOCKED  the bridge refused the key codes (the exact error is kept) or nothing reacted: needs the owner's physical gamepad.
The Studio Controller Emulator window is a separate OS-level window the bridge cannot address (no MCP tool targets it), so it
is not a fallback.

Usage (Play running in the lane window, hub or a race, owner order for Studio):  python3 tools/gamepad_probe.py [tag] [--menu]
Writes out/gamepad_<tag>.json and prints the verdict. Unit-tested offline: tools/tests/test_qa_hooks.py."""
import json
import sys
import time
from pathlib import Path


def classify(keys_result, samples):
    """keys_result: the text lane.keys returned; samples: list of sampler dicts. -> (verdict, reason)."""
    txt = str(keys_result)
    if txt.startswith("ERROR") or txt.startswith("ISERROR") or "invalid key" in txt.lower() or "unknown key" in txt.lower():
        return "BLOCKED", "the bridge refused the gamepad key codes: " + txt[:300]
    if not samples:
        return "BLOCKED", "the sampler returned nothing (no client DataModel or Play not running)"
    moved = any(isinstance(s.get("px"), (int, float)) and abs(s["px"]) > 0.2 for s in samples)
    gamepad = any(str(s.get("last", "")).startswith("Gamepad") for s in samples)
    if gamepad and moved:
        return "WORKS", "last input type reached Gamepad1 and PlayerSteerX followed the stick"
    if moved:
        return "PARTIAL", "PlayerSteerX moved but the last input type never became Gamepad1 (keys, not a gamepad); menus/input family unproven"
    return "BLOCKED", "no sample showed a steer reaction or a Gamepad input type"


SAMPLER = r"""
local lp = game:GetService('Players').LocalPlayer
local UIS = game:GetService('UserInputService')
local GS = game:GetService('GuiService')
_G.GP = {}; _G.GPRun = true
task.spawn(function()
	local t0 = os.clock()
	while _G.GPRun and os.clock() - t0 < 60 do
		local sel = GS.SelectedObject
		table.insert(_G.GP, {t = math.floor((os.clock() - t0) * 10) / 10, px = lp:GetAttribute('PlayerSteerX'), sx = lp:GetAttribute('SteerX'),
			mode = lp:GetAttribute('InputMode'), gp = UIS:GetGamepadConnected(Enum.UserInputType.Gamepad1),
			last = UIS:GetLastInputType().Name, sel = sel and sel:GetFullName() or nil})
		task.wait(0.25)
	end
end)
return 'ok'
"""


def W(ms):
    return {"action": "wait", "wait_time_ms": ms}


def hold(code, ms):
    return [{"action": "keyDown", "key_code": code}, W(ms), {"action": "keyUp", "key_code": code}, W(600)]


def main(argv):
    import lane
    tag = next((a for a in argv if not a.startswith("--")), "run")
    res = {"utc": lane.utc(), "head": lane.git_head()}
    lane.luau(SAMPLER, dm="Client", name="gp_sampler")
    seq = [W(800)]
    for code, ms in (("Thumbstick1Right", 1500), ("Thumbstick1Left", 1500), ("DPadLeft", 1200), ("ButtonA", 1500),
                     ("ButtonB", 1200), ("ButtonR1", 1200), ("ButtonR2", 1200), ("ButtonL2", 1200)):
        seq += hold(code, ms)
    if "--menu" in argv:
        for code in ("DPadDown", "DPadDown", "DPadRight", "ButtonA"):
            seq += hold(code, 300)
    res["keys"] = lane.keys(seq, name="gp_keys", timeout=180)
    lane.luau("_G.GPRun=false return 'x'", dm="Client", name="gp_stop")
    time.sleep(1)
    res["samples"] = lane.read_g_list("GP", dm="Client", name="gp_read")
    res["verdict"], res["reason"] = classify(res["keys"], res["samples"])
    (lane.OUT / ("gamepad_%s.json" % tag)).write_text(json.dumps(res, indent=1))
    print(res["verdict"], "-", res["reason"])
    return 0 if res["verdict"] != "BLOCKED" else 2


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(main(sys.argv[1:]))
