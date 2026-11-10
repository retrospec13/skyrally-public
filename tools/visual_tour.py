#!/usr/bin/env python3
"""Visual tour for critique (L8 critic input): per track, start a race through the Adventure-board remote (UnlockAll in
Edit), fly it with the real-key pilot (tools/windows/key_pilot.js, assist on so the line is clean), capture gameplay frames every
few seconds, then three free-camera beauty shots looking back along the course from high, low and wide.
Usage: visual_tour.py <TRACK-ID|hub> [seconds] -> out/tour/<track>/*.png + out/tour/<track>.jpg contact sheet"""
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

track = sys.argv[1]
secs = int(sys.argv[2]) if len(sys.argv) > 2 else 60
key = track.lower().replace("-", "")
outdir = lane.OUT / "tour" / key
outdir.mkdir(parents=True, exist_ok=True)

BEAUTY = """local RS = game:GetService('RunService') pcall(function() RS:UnbindFromRenderStep('QATour') end)
local Spline = require(game.ReplicatedStorage.Shared.SplineUtils)
local st = %f
local p, tan = Spline.sampleAtStation(st)
local eye = p - tan * %f + Vector3.new(0, %f, 0) + tan:Cross(Vector3.yAxis).Unit * %f
local look = Spline.sampleAtStation(st + %f)
-- camera occlusion like the game camera: an eye that ends up inside terrain or a wall is pulled in along the sight
-- line to just in front of the first surface (a beauty shot from inside a cliff shows nothing of the course)
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.FilterDescendantsInstances = { workspace:FindFirstChild('Planes') or workspace.CurrentCamera }
rp.IgnoreWater = true
local from = look + Vector3.new(0, 6, 0)
local hit = workspace:Raycast(from, eye - from, rp)
if hit then eye = hit.Position + (from - eye).Unit * 3 end
RS:BindToRenderStep('QATour', Enum.RenderPriority.Last.Value + 1, function() workspace.CurrentCamera.CFrame = CFrame.lookAt(eye, look) end)
return 1"""


def grab(label):
    c = lane.capture(f"tour_{key}_{label}")
    if not c:
        return None
    dst = outdir / f"{label}.png"
    Path(c).replace(dst)
    return dst


def main():
    lane.sync(["win"])
    lane.luau("workspace:SetAttribute('UnlockAll', true) workspace:SetAttribute('QAPilotGoals', false) return 1", dm="Edit", name="ua")
    lane.play(True)
    caps = []
    try:
        time.sleep(24)
        if track != "hub":
            lane.luau(f"game.ReplicatedStorage.SkyRallyRemotes.TrackFlowRemote:FireServer('RequestRace','{track}','race') return 1",
                      dm="Client", name="fire")
            t0 = time.time()
            while time.time() - t0 < 120:
                time.sleep(1)
                if "mode=race ok=" in lane.console():
                    break
            time.sleep(1.5)
        caps.append(grab("00_grid"))
        proc = subprocess.Popen(["ssh", "-o", "BatchMode=yes", "-i", lane.KEY, lane.HOST,
                                 f"node {lane.PCWIN}\\tools\\windows\\key_pilot.js {lane.PCWIN}\\out\\pilot_tour_{key}.jsonl {secs} assist=on skill=1"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        t1 = time.time()
        i = 1
        while proc.poll() is None and time.time() - t1 < secs + 30:
            time.sleep(2)
            caps.append(grab(f"{i:02d}_race"))
            i += 1
        proc.wait(timeout=120)
        length = lane.luau("local _, total = require(game.ReplicatedStorage.Shared.SplineUtils).loadWaypoints(true) return total",
                           dm="Client", name="len")
        try:
            total = float(str(length).strip().split()[-1])
        except ValueError:
            total = 3000.0
        for j, (frac, back, up, side, ahead) in enumerate(((0.15, 60, 45, 30, 220), (0.45, 25, 8, 14, 160), (0.75, 140, 120, -60, 400))):
            lane.luau(BEAUTY % (total * frac, back, up, side, ahead), dm="Client", name="beauty")
            time.sleep(1.5)
            caps.append(grab(f"9{j}_beauty"))
        lane.luau("pcall(function() game:GetService('RunService'):UnbindFromRenderStep('QATour') end) return 1", dm="Client", name="unb")
    finally:
        lane.play(False)
    ims = [Image.open(x).convert("RGB") for x in caps if x]
    w = 640
    ims = [im.resize((w, int(w * im.height / im.width))) for im in ims]
    cols = 4
    rows = (len(ims) + cols - 1) // cols
    sheet = Image.new("RGB", (w * cols, ims[0].height * rows))
    for k, im in enumerate(ims):
        sheet.paste(im, ((k % cols) * w, (k // cols) * ims[0].height))
    out = lane.OUT / "tour" / f"{key}.jpg"
    sheet.save(out)
    print(out, len(ims), "frames")


main()
