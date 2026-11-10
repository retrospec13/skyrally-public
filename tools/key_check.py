#!/usr/bin/env python3
"""Hidden-key QA in the own Studio window (L70): start a race on the key track through the Adventure-board remote,
point the real-key pilot (tools/windows/key_pilot.js goal=qa) at the track's HiddenKey model, and check the pickup log, the
player's KeysHeld/BattleBoard state and the race attributes before and after; captures around the pickup.
Usage: key_check.py <TRACK-ID> [seconds] [--unlock-all]   -> out/keycheck_<track>.jpg
S2b: a track listed in tools/key_approach.json (SNOW-1) is flown along its approach line (route=), not straight at the key."""
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402
from key_route import route_arg  # noqa: E402

track = sys.argv[1]
secs = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 90
unlock = "--unlock-all" in sys.argv
tag = "keycheck_" + track.lower().replace("-", "")


AIM = """local lp = game:GetService('Players'):GetPlayers()[1]
local key
for _, d in workspace:GetDescendants() do if d:IsA('Model') and d.Name:sub(1, 10) == 'HiddenKey_' then key = d break end end
if lp and key then lp:SetAttribute('QAGoal', key:GetPivot().Position) end
return string.format('key=%s at=%s lap=%s rank=%s keys=%s', key and key.Name or 'NONE', key and tostring(key:GetPivot().Position) or '-',
  tostring(lp and lp:GetAttribute('Lap')), tostring(lp and lp:GetAttribute('Rank')), tostring(lp and lp:GetAttribute('KeysHeld')))"""
CLEAR = "local lp = game:GetService('Players'):GetPlayers()[1] if lp then lp:SetAttribute('QAGoal', nil) end return 1"


def grab(label):
    c = lane.capture(f"{tag}_{label}")
    return lane.stamp(c, f"{track} key {label}") if c else None


def main():
    lane.sync(["win"])
    lane.luau(f"workspace:SetAttribute('UnlockAll', {'true' if unlock else 'false'}) workspace:SetAttribute('QAPilotGoals', false) return 1",
              dm="Edit", name="ua")
    lane.play(True)
    caps = []
    try:
        time.sleep(24)
        lane.luau(f"game.ReplicatedStorage.SkyRallyRemotes.TrackFlowRemote:FireServer('RequestRace','{track}','race') return 1",
                  dm="Client", name="fire")
        t0 = time.time()
        while time.time() - t0 < 120:
            time.sleep(1)
            if "mode=race ok=" in lane.console():
                break
        time.sleep(6)
        print("before:", lane.luau(AIM, dm="Server", name="kaim"))
        caps.append(grab("start"))
        pc_out = f"{lane.PCWIN}\\out\\pilot_{tag}.jsonl"
        proc = subprocess.Popen(["ssh", "-o", "BatchMode=yes", "-i", lane.KEY, lane.HOST,
                                 f"node {lane.PCWIN}\\tools\\windows\\key_pilot.js {pc_out} {secs} assist=off skill=1 goal=qa{route_arg(track)}"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        t1 = time.time()
        found = False
        while proc.poll() is None and time.time() - t1 < secs + 60:
            time.sleep(3)
            con = lane.console()
            if not found and "[KEY] pickup" in con:
                found = True
                caps.append(grab("found"))
                lane.luau(CLEAR, dm="Server", name="kclear")
                print("after:", lane.luau(AIM.replace("lp:SetAttribute('QAGoal', key:GetPivot().Position)", "local _ = 0"), dm="Server", name="kaim"))
            elif int(time.time() - t1) % 15 < 3:
                caps.append(grab(f"+{int(time.time() - t1)}s"))
        proc.wait(timeout=120)
        caps.append(grab("end"))
        for line in lane.console().splitlines():
            if any(k in line for k in ("KEY", "Key", "rror")) and "ASSETPROBE] OK" not in line:
                print(line[:240])
    finally:
        lane.play(False)
    ims = [Image.open(x).convert("RGB") for x in caps if x][:12]
    w = 640
    ims = [im.resize((w, int(w * im.height / im.width))) for im in ims]
    cols = 4
    rows_n = (len(ims) + cols - 1) // cols
    sheet = Image.new("RGB", (w * cols, ims[0].height * rows_n))
    for k, im in enumerate(ims):
        sheet.paste(im, ((k % cols) * w, (k // cols) * ims[0].height))
    out = lane.OUT / f"{tag}.jpg"
    sheet.save(out)
    print(out)


main()
