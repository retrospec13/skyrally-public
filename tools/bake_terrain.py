#!/usr/bin/env python3
"""Terrain bakes (perf pass 2026-10-19, TEST_LIST L42): run each map's compiled builder in the lane's own Studio window
(Edit DataModel), copy exactly the voxels its terrain step wrote (the root's TerrainCellMin/Max) into a TerrainRegion
stamped with the builder's TerrainHash, serialize it with SerializationService and write build/<key>/terrain_bake.rbxm.
default.project.json mounts each file as ServerStorage.TerrainBakes.<MAP-ID>; the builder pastes it in one call
instead of evaluating ~3M voxels (8-9 s of a 13 s hub build in Studio) while the hashes match, and builds as before
otherwise. Self-check per map: the file is deserialized again, pasted into cleared terrain at the same corner, copied
back and must serialize to the same bytes.

The Studio window must hold the CURRENT builders (tools/lane.py sync() + launch(), builders are not hot-reloaded).
Leaves the Edit DataModel as it found it (terrain cleared, Maps.<id>, templates and readiness attributes removed).
Rerun after any change to tools/map30/builder_template.luau or a plan's terrain; tools/tests/terrain_bake_spec.luau
fails while a bake is stale or missing.
Usage: bake_terrain.py [hub0 snow1 island2 forest1 space4]"""
import base64
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

CHUNK = 90000  # execute_luau output is truncated at 100000 characters

BUILD = r"""
local key = "%s"
local SSS = game:GetService("ServerScriptService")
local SS = game:GetService("ServerStorage")
local Enc = game:GetService("EncodingService")
local Ser = game:GetService("SerializationService")
-- No bake may be present while the builder runs: the copy must come from the computed voxels.
local saved = SS:FindFirstChild("TerrainBakes")
if saved then saved.Parent = nil end
workspace.Terrain:Clear()
local mod = SSS.Maps:FindFirstChild(key)
if not mod then return "ERR no builder " .. key end
local clone = mod:Clone()
clone.Parent = SS
local t0 = os.clock()
local ok, err = pcall(require, clone)
clone:Destroy()
if saved then saved.Parent = SS end
if not ok then return "ERR builder " .. tostring(err) end
local buildS = os.clock() - t0
local maps = workspace:FindFirstChild("Maps")
local root
for _, c in (maps and maps:GetChildren() or {}) do
	if c:GetAttribute("TerrainHash") ~= nil then root = c end
end
if not root then return "ERR no map root" end
local mn, mx, hash = root:GetAttribute("TerrainCellMin"), root:GetAttribute("TerrainCellMax"), root:GetAttribute("TerrainHash")
if typeof(mn) ~= "Vector3" then return "ERR no terrain cells (map without terrain)" end
local cmin = Vector3int16.new(mn.X, mn.Y, mn.Z)
local region = workspace.Terrain:CopyRegion(Region3int16.new(cmin, Vector3int16.new(mx.X, mx.Y, mx.Z)))
region.Name = root.Name
region:SetAttribute("TerrainHash", hash)
region:SetAttribute("Corner", mn)
local bytes = Ser:SerializeInstancesAsync({ region })
-- Self-check: deserialize, paste into cleared terrain at the same corner, copy back, serialize: same bytes.
local back = Ser:DeserializeInstancesAsync(bytes)[1]
workspace.Terrain:Clear()
local tp = os.clock()
workspace.Terrain:PasteRegion(back, cmin, true)
local pasteS = os.clock() - tp
local again = workspace.Terrain:CopyRegion(Region3int16.new(cmin, Vector3int16.new(mx.X, mx.Y, mx.Z)))
again.Name = region.Name
again:SetAttribute("TerrainHash", hash)
again:SetAttribute("Corner", mn)
local same = buffer.tostring(Ser:SerializeInstancesAsync({ again })) == buffer.tostring(bytes)
_G.__terrainBake = buffer.tostring(Enc:Base64Encode(bytes))
-- Leave the Edit place as it was.
local name = root.Name
root:Destroy()
workspace.Terrain:Clear()
local tf = SS:FindFirstChild("30MAPS_Templates")
local t = tf and tf:FindFirstChild(name)
if t then t:Destroy() end
for k in workspace:GetAttributes() do
	if string.sub(k, 1, 9) == "MapBuilt_" then workspace:SetAttribute(k, nil) end
end
return game:GetService("HttpService"):JSONEncode({ name = name, hash = hash, cells = tostring(region.SizeInCells),
	bytes = buffer.len(bytes), b64 = #_G.__terrainBake, buildS = buildS, pasteS = pasteS, roundTrip = same })
"""

READ = "return string.sub(_G.__terrainBake, %d, %d)"


def bake(key):
    res = ""
    for attempt in range(3):
        res = str(lane.luau(BUILD % key, dm="Edit", name="bake_build", timeout=600))
        if "No Roblox Studio instances are connected" not in res:
            break
        time.sleep(20)
    if "{" not in res:
        print(key, res)
        return None
    info = json.loads(res[res.find("{"): res.rfind("}") + 1])
    parts = []
    for i in range(0, info["b64"], CHUNK):
        for attempt in range(6):  # the shared PC's MCP bridge drops for tens of seconds under load
            piece = re.sub(r"\s", "", str(lane.luau(READ % (i + 1, i + CHUNK), dm="Edit", name="bake_read", timeout=180)))
            if re.fullmatch(r"[A-Za-z0-9+/=]*", piece):
                break
            time.sleep(15)
        else:
            raise RuntimeError(f"{key}: bad chunk at {i}: {piece[:120]}")
        parts.append(piece)
    data = base64.b64decode("".join(parts))
    if len(data) != info["bytes"]:
        raise RuntimeError(f"{key}: got {len(data)} bytes, Studio serialized {info['bytes']}")
    if not info["roundTrip"]:
        raise RuntimeError(f"{key}: paste/copy round trip differs; not writing")
    builder = (lane.ROOT / "build" / key / "builder_module.luau").read_text()
    m = re.search(r'local TERRAIN_HASH = "([0-9a-f]+)"', builder)
    if not m or m.group(1) != info["hash"]:
        raise RuntimeError(f"{key}: Studio builder hash {info['hash']} != repo builder {m.group(1) if m else None}: sync + launch first")
    out = lane.ROOT / "build" / key / "terrain_bake.rbxm"
    out.write_bytes(data)
    lane.luau("_G.__terrainBake = nil return 1", dm="Edit", name="bake_clear")
    print(f"{key}: {info['name']} hash={info['hash']} cells={info['cells']} {len(data) / 1e6:.2f} MB "
          f"build={info['buildS']:.1f}s paste={info['pasteS']:.2f}s -> {out.relative_to(lane.ROOT)}", flush=True)
    return info


def main():
    keys = [a for a in sys.argv[1:] if not a.startswith("--")] or ["hub0", "snow1", "island2", "forest1", "space4"]
    for k in keys:
        bake(k)


if __name__ == "__main__":
    main()
