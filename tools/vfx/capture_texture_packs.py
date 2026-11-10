#!/usr/bin/env python3
"""Capture the engine-generated TexturePack of every MaterialVariant from the lane's own Studio window (read-only, Edit
DataModel) into assets/materials/texture_packs.json; tools/vfx/write_material_project.py then writes each pack into
default.project.json.

Why (hunt:texpack, 2026-10-19): a live client does not fetch a MaterialVariant's ColorMap / NormalMap one by one; it
fetches the variant's TexturePack (a hidden, NotScriptable, serialized ContentId that Studio generates from the maps).
Studio renders from the maps directly, so a variant without a pack looks right in Studio, but the published place is a
rojo build (win/publish_skyrally.ps1 -> Open Cloud place publish) and rojo writes no pack, so every joined client logged
'Asset (Image) "" load failed in fetchTexturePackTextures' and 'Failed to load MaterialService.SR_* ... PBR textures
may not be visible' and drew the bare base material (the flat cream hub plaza). Packs are keyed by their exact maps
(identical ColorMap + NormalMap pairs get the same pack id), so the table is keyed by that pair: a variant whose maps
change simply loses its pack until the next capture instead of carrying a stale one.

Reading: SerializationService:SerializeInstancesAsync (plugin context) returns the binary model with the hidden
property; lune (rbx-dom) decodes it here. Nothing is written to the window or the place; no upload.
Usage: capture_texture_packs.py [--dry-run]"""
import base64
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "materials" / "texture_packs.json"

SERIALIZE_LUA = r"""
local ss = game:GetService("SerializationService")
local s = buffer.tostring(ss:SerializeInstancesAsync(game:GetService("MaterialService"):GetChildren()))
local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local out = {}
for i = 1, #s, 3 do
	local a, b, c = string.byte(s, i, i + 2)
	local n = a * 65536 + (b or 0) * 256 + (c or 0)
	local function ch(k) local x = bit32.extract(n, k, 6) + 1 return A:sub(x, x) end
	table.insert(out, ch(18) .. ch(12) .. (b and ch(6) or "=") .. (c and ch(0) or "="))
end
return "B64=" .. table.concat(out)
"""

DECODE_LUAU = r"""
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local rows = {}
for _, v in roblox.deserializeModel(fs.readFile(process.args[1])) do
	if v.ClassName == "MaterialVariant" then
		local function uri(p)
			local ok, c = pcall(function() return v[p] end)
			if not ok or c == nil then return "" end
			local s = tostring(c)
			return string.match(s, "rbxassetid://%d+") or (if string.match(s, "^rbxassetid") then s else "")
		end
		table.insert(rows, { name = v.Name, pack = uri("TexturePack"), color = uri("ColorMapContent"), normal = uri("NormalMapContent") })
	end
end
print(serde.encode("json", rows))
"""


def main():
    if lane.own_studio_id() is None:
        sys.exit("no own Studio window (" + lane.PLACE + ")")
    t = lane.luau(SERIALIZE_LUA, dm="Edit", name="capture_texture_packs", timeout=120)
    if "B64=" not in t:
        sys.exit("capture failed: " + t[:400])
    with tempfile.TemporaryDirectory() as td:
        m = Path(td) / "ms.rbxm"
        m.write_bytes(base64.b64decode(t.split("B64=", 1)[1].strip()))
        d = Path(td) / "decode.luau"
        d.write_text(DECODE_LUAU)
        rows = json.loads(subprocess.run(["lune", "run", str(d), str(m)], check=True, capture_output=True, text=True).stdout)
    packs = {}
    for r in sorted(rows, key=lambda r: r["name"]):
        if not (r["pack"] and r["color"] and r["normal"]):
            print("no pack yet:", r["name"])
            continue
        key = r["color"] + "|" + r["normal"]
        e = packs.setdefault(key, {"pack": r["pack"], "variants": []})
        if e["pack"] != r["pack"]:
            print("WARN two packs for one map pair:", key, e["pack"], r["pack"])
        e["variants"].append(r["name"])
    doc = {
        "about": "Engine-generated MaterialVariant TexturePacks keyed by 'ColorMap|NormalMap', captured read-only from the lane's own Studio window by tools/vfx/capture_texture_packs.py; written into default.project.json by tools/vfx/write_material_project.py",
        "captured": time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime()),
        "packs": packs,
    }
    if "--dry-run" in sys.argv:
        print(json.dumps(doc, indent=1))
        return
    OUT.write_text(json.dumps(doc, indent=1) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(packs)} packs for {sum(len(e['variants']) for e in packs.values())} variants")


if __name__ == "__main__":
    main()
