#!/usr/bin/env python3
"""Battle-mode QA in the own Studio window (L71-L74): start the track's battle through the Adventure-board remote
(UnlockAll in Edit), play it with real keyboard input (tools/windows/key_pilot.js goal=qa steers to the mode's bot-brain goal
that BattleCore publishes under workspace.QAPilotGoals, and taps F to fire), capture every 15 s, read the board/HUD,
then end it with TriggerBattleEnd and capture the results.
Usage: battle_check.py <TRACK-ID> [seconds] [--no-end] [--clip]   -> out/battle_<track>.jpg (+ out/clips/battle_<track>.mp4)
+ printed state/log"""
import json
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import clip  # noqa: E402
import lane  # noqa: E402

track = sys.argv[1]
secs = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 60
end_it = "--no-end" not in sys.argv
want_clip = "--clip" in sys.argv
tag = "battle_" + track.lower().replace("-", "")

STATE = """local lp = game:GetService('Players'):GetPlayers()[1]
return string.format('state=%s kind=%s title=%s endsAt=%s hud=%s goal=%s fire=%s board=%s',
  tostring(workspace:GetAttribute('BattleState')), tostring(workspace:GetAttribute('BattleKind')),
  tostring(workspace:GetAttribute('BattleTitle')), tostring(workspace:GetAttribute('BattleEndsAt')),
  tostring(lp and lp:GetAttribute('BattleHud')), tostring(lp and lp:GetAttribute('QAGoal')),
  tostring(lp and lp:GetAttribute('QAFire')), tostring(workspace:GetAttribute('BattleBoard')))
  .. ' planes=' .. (function() local o = {} for _, m in workspace.Planes:GetChildren() do local h = m:FindFirstChild('Hull')
    if h and lp and m.Name:find(lp.Name, 1, true) then table.insert(o, string.format('%s@(%.0f,%.0f,%.0f)v%.0f', m.Name, h.Position.X, h.Position.Y, h.Position.Z, h.AssemblyLinearVelocity.Magnitude)) end end
    return table.concat(o, ',') end)()"""


def grab(label):
    c = lane.capture(f"{tag}_{label}")
    return lane.stamp(c, f"{track} battle {label}") if c else None


def main():
    lane.sync(["win"])
    lane.luau("workspace:SetAttribute('UnlockAll', true) workspace:SetAttribute('QAPilotGoals', true) return 1", dm="Edit", name="ua")
    lane.play(True)
    caps = []
    try:
        time.sleep(24)
        lane.luau(f"game.ReplicatedStorage.SkyRallyRemotes.TrackFlowRemote:FireServer('RequestRace','{track}','battle') return 1",
                  dm="Client", name="fire")
        t0 = time.time()
        while time.time() - t0 < 120:
            time.sleep(1)
            con = lane.console()
            if "mode=battle ok=" in con:
                break
        time.sleep(7)  # curtain + countdown
        caps.append(grab("start"))
        pc_out = f"{lane.PCWIN}\\out\\pilot_{tag}.jsonl"
        proc = subprocess.Popen(["ssh", "-o", "BatchMode=yes", "-i", lane.KEY, lane.HOST,
                                 f"node {lane.PCWIN}\\tools\\windows\\key_pilot.js {pc_out} {secs} assist=off skill=1 goal=qa"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        rec = clip.start(tag, secs) if want_clip else None
        t1 = time.time()
        while proc.poll() is None and time.time() - t1 < secs + 60:
            time.sleep(15)
            caps.append(grab(f"+{int(time.time() - t1)}s"))
            print(lane.luau(STATE, dm="Server", name="bstate"))
        proc.wait(timeout=120)
        if rec:
            clip.finish(rec)
        lane.get(f"out/pilot_{tag}.jsonl", lane.OUT / f"pilot_{tag}.jsonl")
        if end_it:
            lane.luau("workspace:SetAttribute('TriggerBattleEnd', true) return 1", dm="Server", name="bend")
            time.sleep(4)
            caps.append(grab("results"))
            print(lane.luau(STATE, dm="Server", name="bstate"))
        for line in lane.console().splitlines():
            if any(k in line for k in ("BATTLE", "KEY", "rror", "arn")) and "ASSETPROBE] OK" not in line:
                print(line[:240])
    finally:
        lane.play(False)
    rows = [json.loads(x) for x in (lane.OUT / f"pilot_{tag}.jsonl").read_text().splitlines() if x.strip()]
    fires = sum(1 for r in rows if "F" in (r.get("keys") or []))
    end = next((r for r in rows if r.get("event") == "end"), {})
    print(f"PILOT ticks={end.get('ticks')} hz={end.get('hz')} fireTicks={fires} crashes={max([r.get('crashes', 0) for r in rows] or [0])}")
    ims = [Image.open(x).convert("RGB") for x in caps if x]
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
