#!/usr/bin/env python3
"""Props lineup (Edit mode, own Studio window): loads every uploaded PropLibrary model through InsertService the way
MapAdapter's setDressing step does (scripts stripped, parts only, base-centre pivot), lines each zone up on a test row
far from the maps, captures one image per zone from a fixed camera and removes the row.
Usage: props_lineup.py [ZONE ...]   -> out/props_<zone>.png + printed load report"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

ZONES = sys.argv[1:] or ["HUB", "DINO", "SNOW", "ISLAND", "FOREST", "SPACE"]

BUILD = r"""
local IS = game:GetService('InsertService')
local lib = require(game.ReplicatedStorage.Shared.PropLibrary)
local zone = '%s'
local old = workspace:FindFirstChild('QA_PropsLineup') if old then old:Destroy() end
local row = Instance.new('Folder') row.Name = 'QA_PropsLineup' row.Parent = workspace
local keys = {}
for k, p in lib do if p.zone == zone then table.insert(keys, k) end end
table.sort(keys)
local x, out = 0, {}
local base = Vector3.new(0, 2000, 20000)
local floor = Instance.new('Part') floor.Anchored = true floor.Size = Vector3.new(400, 2, 80)
floor.Color = Color3.fromRGB(150, 150, 150) floor.Material = Enum.Material.SmoothPlastic
floor.CFrame = CFrame.new(base + Vector3.new(150, -1, 0)) floor.Parent = row
for _, k in keys do
  local p = lib[k]
  if p.model then
    local ok, c = pcall(function() return IS:LoadAsset(p.model) end)
    if ok and c then
      local m = Instance.new('Model') m.Name = k
      for _, d in c:GetDescendants() do if d:IsA('LuaSourceContainer') then d:Destroy() end end
      for _, d in c:GetDescendants() do if d:IsA('BasePart') then d.Anchored = true d.Parent = m end end
      c:Destroy()
      local bb, size = m:GetBoundingBox()
      m.WorldPivot = CFrame.new(bb.Position - Vector3.new(0, size.Y * 0.5, 0))
      m:PivotTo(CFrame.new(base + Vector3.new(x + size.X * 0.5, 0, 0)))
      m.Parent = row
      table.insert(out, string.format('%%s ok size=(%%.1f,%%.1f,%%.1f) parts=%%d', k, size.X, size.Y, size.Z, #m:GetChildren()))
      x += size.X + 6
    else
      table.insert(out, k .. ' LOAD FAIL ' .. tostring(c))
    end
  else
    table.insert(out, k .. ' not uploaded')
  end
end
row:SetAttribute('Width', x)
return table.concat(out, '\n')
"""

for zone in ZONES:
    print(f"== {zone}")
    print(lane.luau(BUILD % zone, dm="Edit", name="props_build", timeout=300))
    width = lane.luau("return workspace.QA_PropsLineup:GetAttribute('Width')", dm="Edit", name="w")
    try:
        w = float(str(width).strip().split()[-1])
    except ValueError:
        w = 200.0
    cam = [round(w * 0.5), 2022, round(20000 + max(55, w * 0.42))]
    look = [round(w * 0.5), 2008, 20000]
    res = lane.mcp([{"name": "screen_capture", "arguments": {"capture_id": f"props_{zone}",
                     "camera_position": cam, "look_at_position": look}, "tag": f"props_{zone}"}], name=f"props_{zone}")
    for r in res["results"]:
        for p in r.get("content", []) or []:
            if p.get("local"):
                print("capture", p["local"])
    lane.luau("local r = workspace:FindFirstChild('QA_PropsLineup') if r then r:Destroy() end return 1", dm="Edit", name="clean")
    time.sleep(1)
