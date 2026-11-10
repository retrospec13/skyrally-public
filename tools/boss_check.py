#!/usr/bin/env python3
"""QA a boss in the own Studio window: start its boss race through the Adventure-board remote (UnlockAll in Edit),
wait for the model, then capture it from behind, in front and from the right side with a temporary camera bound after
the chase camera. Usage: boss_check.py <TRACK-ID> <BossName> [settle_seconds]  -> out/bosscheck_<name>.jpg"""
import sys
import time
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

track, name = sys.argv[1], sys.argv[2]
settle = float(sys.argv[3]) if len(sys.argv) > 3 else 16
lane.luau("workspace:SetAttribute('UnlockAll', true) return 1", dm="Edit", name="ua")
lane.play(True)
try:
    time.sleep(24)
    lane.luau(f"game.ReplicatedStorage.SkyRallyRemotes.TrackFlowRemote:FireServer('RequestRace','{track}','boss') return 1", dm="Client", name="fire")
    t0 = time.time()
    while time.time() - t0 < 90:
        time.sleep(1)
        if "mode=boss ok=" in lane.console():
            break
    time.sleep(settle)
    caps = []
    blen = lane.luau(f"return require(game.ReplicatedStorage.Shared.BossConfig).forTrack('{track}').length", dm="Client", name="blen")
    try:
        d = max(34.0, 1.5 * float(str(blen).strip().split()[-1]))
    except ValueError:
        d = 34.0
    h = d * 0.3
    for view, off in (("behind", f"CFrame.new(0, {h:.0f}, {d:.0f})"), ("front", f"CFrame.new(0, {h:.0f}, {-d:.0f})"), ("side", f"CFrame.new({d:.0f}, {h * 0.5:.0f}, 0)")):
        lane.luau(f"""local RS=game:GetService('RunService') pcall(function() RS:UnbindFromRenderStep('QABossCam') end)
RS:BindToRenderStep('QABossCam', Enum.RenderPriority.Last.Value, function()
  local b=workspace.Planes:FindFirstChild('BOSS_{name}') local h=b and b:FindFirstChild('Hull')
  if h then local c=h.CFrame*{off} workspace.CurrentCamera.CFrame=CFrame.lookAt(c.Position, h.Position) end end) return 1""", dm="Client", name="qacam")
        time.sleep(1.2)
        caps.append(lane.capture(f"boss_{name}_{view}"))
    # Motion burst: four quarter-side frames ~0.18 s apart, so wing beats and leg steps show frame to frame.
    lane.luau(f"""local RS=game:GetService('RunService') pcall(function() RS:UnbindFromRenderStep('QABossCam') end)
RS:BindToRenderStep('QABossCam', Enum.RenderPriority.Last.Value, function()
  local b=workspace.Planes:FindFirstChild('BOSS_{name}') local h=b and b:FindFirstChild('Hull')
  if h then local c=h.CFrame*CFrame.new(%.0f, %.0f, %.0f) workspace.CurrentCamera.CFrame=CFrame.lookAt(c.Position, h.Position) end end) return 1""" % (d * 0.75, h, -d * 0.55), dm="Client", name="qacam")
    time.sleep(1.0)
    for i in range(4):
        caps.append(lane.capture(f"boss_{name}_burst{i}"))
        time.sleep(0.05)
    print(lane.luau("local n=0 for _,d in workspace.Planes:GetDescendants() do if d:IsA('Bone') and d:IsDescendantOf(workspace.Planes:FindFirstChild('BOSS_" + name + "') or workspace) then n+=1 end end return 'bones='..n", dm="Client", name="bones"))
    lane.luau("pcall(function() game:GetService('RunService'):UnbindFromRenderStep('QABossCam') end) return 1", dm="Client", name="unb")
    print("\n".join(l[:200] for l in lane.console().splitlines() if "BOSS" in l or "rror" in l))
finally:
    lane.play(False)
ims = [Image.open(x).convert("RGB") for x in caps if x]
w = 640
ims = [im.resize((w, int(w * im.height / im.width))) for im in ims]
cols = min(len(ims), 4)
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (w * cols, ims[0].height * rows))
for k, im in enumerate(ims):
    sheet.paste(im, ((k % cols) * w, (k // cols) * ims[0].height))
out = lane.OUT / f"bosscheck_{name}.jpg"
sheet.save(out)
print(out)
