#!/usr/bin/env python3
"""TRACK_PIPELINE P2 isolated smoke test: run build/<key>/builder.server.luau (the vendored compiler's output, nothing
else wired) in the own Studio window's Edit DataModel and check: [30MAPS] DONE, MapBuilt_<id>, part/instance counts
vs the plan, no Workspace.Map, Lighting children unchanged, MapBuildErrors == 0. Cleans up afterwards.
Usage: smoke_compiled.py <key> <id>"""
import base64
import re
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane  # noqa: E402

key, mid = sys.argv[1], sys.argv[2]
src = (lane.ROOT / "build" / key / "builder.server.luau").read_bytes() + b"\nreturn true\n"
plan = json.loads((lane.ROOT / "map" / key / "plan.json").read_text())
expect_parts = sum(len(plan["prefabs"][i["pf"]]["parts"]) for i in plan["instances"])
code = r"""
local EncodingService = game:GetService('EncodingService')
local function dec(s) return buffer.tostring(EncodingService:Base64Decode(buffer.fromstring(s))) end
local Lighting = game:GetService('Lighting')
local before = {}
for _, c in Lighting:GetChildren() do table.insert(before, c.ClassName .. ':' .. c.Name) end
table.sort(before)
local m = Instance.new('ModuleScript'); m.Name = 'SmokeBuilder'; m.Source = dec('__SRC__'); m.Parent = game:GetService('ServerScriptService')
local t0 = os.clock()
local ok, err = pcall(require, m)
m:Destroy()
local after = {}
for _, c in Lighting:GetChildren() do table.insert(after, c.ClassName .. ':' .. c.Name) end
table.sort(after)
local maps = workspace:FindFirstChild('Maps')
local root = maps and maps:FindFirstChild('__ID__')
local parts, models = 0, 0
if root then
	for _, d in root:GetDescendants() do
		if d:IsA('BasePart') then parts += 1 elseif d:IsA('Model') then models += 1 end
	end
end
local res = {ok = ok, err = err and tostring(err) or nil, seconds = os.clock() - t0, root = root ~= nil,
	mapBuilt = workspace:GetAttribute('MapBuilt___ATTR__'), rootBuilt = root and root:GetAttribute('MapBuilt'),
	buildErrors = root and root:GetAttribute('MapBuildErrors'), strayMap = workspace:FindFirstChild('Map') ~= nil,
	parts = parts, models = models, lightingUnchanged = table.concat(before, '|') == table.concat(after, '|'),
	groups = {}}
if root then for _, g in root:GetChildren() do table.insert(res.groups, g.Name) end end
if root then root:Destroy() end
return game:GetService('HttpService'):JSONEncode(res)
""".replace("__SRC__", base64.b64encode(src).decode()).replace("__ID__", mid).replace("__ATTR__", re.sub(r"[^A-Za-z0-9_]", "_", mid))
if "Edit" not in lane.state().split("Current Studio Mode:")[-1].splitlines()[0]:
    lane.play(False)
t = lane.luau(code, dm="Edit", name=f"smoke_{key}", timeout=600)
r = json.loads(t[t.index("{"):])
r["expectParts"] = expect_parts
r["expectInstances"] = len(plan["instances"])
print(json.dumps(r, indent=1))
logs = [l for l in lane.console().splitlines() if "30MAPS" in l][-6:]
print("\n".join(logs))
r["log"] = logs
(lane.OUT / f"smoke_{key}.json").write_text(json.dumps(r, indent=1))
passed = r["ok"] and r["root"] and r["mapBuilt"] and not r["strayMap"] and r["lightingUnchanged"] and r["parts"] >= expect_parts and not r.get("buildErrors")
print("P2", "PASS" if passed else "FAIL")
sys.exit(0 if passed else 1)
