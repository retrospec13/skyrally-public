#!/usr/bin/env python3
"""Creator Store stand-in bakes (docs/ASSETS_TOOLBOX_TEMP.md; owner allowance 2026-10-19: free toolbox assets as tracked,
replace-later gap fillers).

Why a separate tool: a live server cannot InsertService:LoadAsset another creator's model ("User is not authorized to
access Asset", also in the lane Studio), and nothing from the store may run code in our game. Studio's game:GetObjects
does load the model in the Edit DataModel, so each stand-in is loaded there, STRIPPED, RESTYLED to docs/ART_BAR.md and
serialized to build/model_bakes/<id>.rbxm, which src/shared/ModelBakes clones at runtime (the game never calls LoadAsset
on these ids; with no bake the stand-in simply does not load and the builder art stays).

Stripping (every id): only Model / Folder / Part / MeshPart / UnionOperation / SpecialMesh / CylinderMesh / BlockMesh survive.
Everything else goes (Script, LocalScript, ModuleScript and every other LuaSourceContainer, Configuration and value
objects, Fire / Smoke / Sparkles, the store's own ParticleEmitters and lights, Tools, Seats, Sounds, GUIs); every attribute and
tag is cleared. The bake is then decoded again with lune and refused when it holds any LuaSourceContainer or a class off
the allow list (the restyle adds only ParticleEmitter + Attachment of our own).

Restyle per id is in SPECS below (flat painted colours; Grass / Wood materials so the game's own painted MaterialVariants
apply; smooth surfaces; our own particle emitters; pivot at the base of the trunk / pole so the prefab fit stands it on the
prefab origin). manifest.json gets a row with "toolbox": true, "packs": [], "surfaceAppearances": 0 and the strip report.

Studio stays read-only (loaded instances are destroyed afterwards); no upload, no Open Cloud.
Usage: bake_toolbox.py [ids...]   (no ids: every id in SPECS)"""
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bake_models as bm  # noqa: E402
import lane  # noqa: E402

ROOT = lane.ROOT
BAKES = bm.BAKES
MANIFEST = bm.MANIFEST

PRELUDE = bm.PRELUDE + r"""
local CS = game:GetService("CollectionService")
local KEEP = { Model = true, Folder = true, Part = true, MeshPart = true, UnionOperation = true, WedgePart = true,
	SpecialMesh = true, CylinderMesh = true, BlockMesh = true }
local function strip(root)
	local removed = {}
	local list = root:GetDescendants()
	table.insert(list, root)
	for _, d in list do
		for k in d:GetAttributes() do d:SetAttribute(k, nil) end
		for _, t in CS:GetTags(d) do CS:RemoveTag(d, t) end
	end
	for _, d in root:GetDescendants() do
		if not KEEP[d.ClassName] then
			removed[d.ClassName] = (removed[d.ClassName] or 0) + 1
		end
	end
	for _, d in root:GetDescendants() do
		if not KEEP[d.ClassName] and d.Parent then d:Destroy() end
	end
	return removed
end
local function smooth(p)
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.LeftSurface = Enum.SurfaceType.Smooth
	p.RightSurface = Enum.SurfaceType.Smooth
	p.FrontSurface = Enum.SurfaceType.Smooth
	p.BackSurface = Enum.SurfaceType.Smooth
end
local function bounds(root)
	local lo, hi = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			local h = d.Size * 0.5
			local c = d.CFrame
			local ex = math.abs(c.RightVector.X) * h.X + math.abs(c.UpVector.X) * h.Y + math.abs(c.LookVector.X) * h.Z
			local ey = math.abs(c.RightVector.Y) * h.X + math.abs(c.UpVector.Y) * h.Y + math.abs(c.LookVector.Y) * h.Z
			local ez = math.abs(c.RightVector.Z) * h.X + math.abs(c.UpVector.Z) * h.Y + math.abs(c.LookVector.Z) * h.Z
			lo = Vector3.new(math.min(lo.X, c.X - ex), math.min(lo.Y, c.Y - ey), math.min(lo.Z, c.Z - ez))
			hi = Vector3.new(math.max(hi.X, c.X + ex), math.max(hi.Y, c.Y + ey), math.max(hi.Z, c.Z + ez))
		end
	end
	return lo, hi
end
local function histogram(root)
	local h = {}
	local list = root:GetDescendants()
	table.insert(list, root)
	for _, d in list do h[d.ClassName] = (h[d.ClassName] or 0) + 1 end
	return h
end
local function setAll(root, f)
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then f(d) end
	end
end
"""

LOAD_ONE = PRELUDE + r"""
local id = __ID__
local ok, got = pcall(function() return game:GetObjects("rbxassetid://" .. id)[1] end)
if not ok or not got then return "ERR " .. tostring(got) end
local root = got
local wrapped = false
if not root:IsA("Model") then
	local m = Instance.new("Model")
	root.Parent = m
	root = m
	wrapped = true
end
local nameBefore = got.Name
local removed = strip(root)
-- Invisible helper parts (the tree's leaf-drop plate DropSource, Transparency 1) are script scaffolding: deleted, not made visible.
for _, d in root:GetDescendants() do
	if d:IsA("BasePart") and d.Transparency >= 0.9 then
		removed["InvisibleHelperPart:" .. d.Name] = (removed["InvisibleHelperPart:" .. d.Name] or 0) + 1
		d:Destroy()
	end
end
local before = histogram(root)
__RESTYLE__
-- opaque, matte: the store's 2015 canopy blocks were semi-transparent
setAll(root, function(p)
	p.Transparency = 0
	p.Reflectance = 0
end)
local lo, hi = bounds(root)
local report = { id = id, rootName = root.Name, wrapped = wrapped, removed = removed, classes = histogram(root),
	size = { hi.X - lo.X, hi.Y - lo.Y, hi.Z - lo.Z }, centre = { (hi.X + lo.X) / 2, (lo.Y + hi.Y) / 2, (hi.Z + lo.Z) / 2 },
	minY = lo.Y, pivot = { root:GetPivot().X, root:GetPivot().Y, root:GetPivot().Z } }
local tris = 0
for _, d in root:GetDescendants() do
	if d:IsA("MeshPart") then
		local ok2, n = pcall(function() return d.MeshId end)
		report.meshId = report.meshId or {}
		table.insert(report.meshId, tostring(d.MeshId))
	elseif d:IsA("SpecialMesh") then
		report.meshId = report.meshId or {}
		table.insert(report.meshId, tostring(d.MeshId) .. " tex=" .. tostring(d.TextureId))
	end
end
if _G.__mb[tostring(id)] then _G.__mb[tostring(id)]:Destroy() end
_G.__mb[tostring(id)] = root
return "JSON=" .. H:JSONEncode(report)
"""

# Normalise a tree / pole so its base stands at the origin and the model pivot is there (the prefab fit stands the model's
# pivot on the prefab origin): `base` is the lowest point of the part named `basePart`, or the bbox centre when nil.
RESTYLE_COMMON_PIVOT = r"""
local function pivotAtBase(root, basePartName)
	local lo, hi = bounds(root)
	local bx, bz = (lo.X + hi.X) / 2, (lo.Z + hi.Z) / 2
	if basePartName then
		local p = root:FindFirstChild(basePartName, true)
		local c = p.CFrame
		local h = p.Size * 0.5
		local sx, sz, n = 0, 0, 0
		for _, sxn in { -1, 1 } do for _, syn in { -1, 1 } do for _, szn in { -1, 1 } do
			local w = c:PointToWorldSpace(Vector3.new(h.X * sxn, h.Y * syn, h.Z * szn))
			if w.Y < lo.Y + 0.35 then sx += w.X sz += w.Z n += 1 end
		end end end
		if n > 0 then bx, bz = sx / n, sz / n end
	end
	root:TranslateBy(Vector3.new(-bx, -lo.Y, -bz))
	root.WorldPivot = CFrame.new(0, 0, 0)
end
"""

HEDGE = r"""
local mp = root:FindFirstChildWhichIsA("MeshPart", true)
mp.Name = "Hedge"
mp.Anchored = true
mp.CanCollide = false
mp.Material = Enum.Material.Grass
mp.Color = Color3.fromRGB(79, 128, 72) -- #4f8048, the builder hedges' mid green
mp.CFrame = CFrame.new(0, mp.Size.Y / 2, 0)
mp.TextureID = ""
smooth(mp)
root.Name = "Hedge"
root.WorldPivot = CFrame.new(0, 0, 0)
"""

AUTUMN = RESTYLE_COMMON_PIVOT + r"""
-- Trunk and branches: Wood; canopy blocks: Grass (the game's painted meadow variant, tinted by the block colour as the builder's
-- own autumn canopies are). Colours stay the creator's flat oranges.
local canopy = {}
local bestVol, bestPart = 0, nil
setAll(root, function(p)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	smooth(p)
	if p.Name == "Trunk" or p.Color == Color3.new(0.486275, 0.360784, 0.27451) or p.Color.R < 0.6 and p.Color.B < 0.4 and p.Size.Magnitude < 5 and p.Color.R > 0.4 and p.Color.G < 0.45 then
		p.Material = Enum.Material.Wood
	else
		p.Material = Enum.Material.Grass
		table.insert(canopy, p)
		local v = p.Size.X * p.Size.Y * p.Size.Z
		if p.Position.Y > 12.5 and v > bestVol then bestVol, bestPart = v, p end
	end
	if p:IsA("UnionOperation") then p.UsePartColor = true end
end)
-- Fuller silhouette: the creator's tree is sparse next to the game's oaks, so the canopy blocks grow 1.3x about their own centres
-- and the branches / trunk thicken (the ART_BAR bold-silhouette rule); the colours stay the creator's flat oranges, lifted a little
-- toward the Sunshine yellow so the Grass variant's shading does not read brown.
for _, p in canopy do
	p.Size = p.Size * 1.3
	p.Color = p.Color:Lerp(Color3.new(1, 0.78, 0.35), 0.18)
end
setAll(root, function(p)
	if p.Material == Enum.Material.Wood then
		if p.Name == "Trunk" then
			p.Size = Vector3.new(p.Size.X * 1.7, p.Size.Y, p.Size.Z * 1.7)
		else
			p.Size = Vector3.new(p.Size.X * 2, p.Size.Y, p.Size.Z * 2)
		end
	end
end)
pivotAtBase(root, "Trunk")
-- Falling leaves: one small sparse emitter inside the largest upper canopy block (the creator's own emitter fed a script that is gone).
if bestPart then
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "FallingLeaves"
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Shape = Enum.ParticleEmitterShape.Box
	pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	pe.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	pe.Rate = 1.4
	pe.Lifetime = NumberRange.new(5, 7)
	pe.Speed = NumberRange.new(0.3, 0.9)
	pe.Acceleration = Vector3.new(0, -1.1, 0)
	pe.Drag = 0.8
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-90, 90)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0.3) })
	pe.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(232, 184, 96)), ColorSequenceKeypoint.new(1, Color3.fromRGB(192, 106, 54)) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.1, 0.1), NumberSequenceKeypoint.new(0.85, 0.2), NumberSequenceKeypoint.new(1, 1) })
	pe.LightEmission = 0
	pe.LockedToPart = false
	pe.Parent = bestPart
end
"""

TIKI = RESTYLE_COMMON_PIVOT + r"""
setAll(root, function(p)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	smooth(p)
end)
local handle = root:FindFirstChild("Handle", true)
local pole = nil
for _, d in root:GetDescendants() do
	if d:IsA("BasePart") and d ~= handle then pole = d end
end
if pole then
	pole.Material = Enum.Material.SmoothPlastic
	pole.Color = Color3.fromRGB(222, 176, 120) -- bamboo tan (the creator's peach pole drew grey under the game's lighting)
	pole.Name = "Pole"
end
pivotAtBase(root, nil)
-- Flame: the store's legacy Fire object is replaced by a small particle flame above the cup (owner rule: VFX are particles).
if handle then
	handle.Name = "Cup"
	local att = Instance.new("Attachment")
	att.Name = "FlameTip"
	att.Position = Vector3.new(0, handle.Size.Y * 0.5, 0)
	att.Parent = handle
	local pe = Instance.new("ParticleEmitter")
	pe.Name = "Flame"
	pe.Texture = "rbxasset://textures/particles/fire_main.dds"
	pe.Rate = 24
	pe.Lifetime = NumberRange.new(0.45, 0.8)
	pe.Speed = NumberRange.new(2, 3.4)
	pe.Acceleration = Vector3.new(0, 3, 0)
	pe.SpreadAngle = Vector2.new(12, 12)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-60, 60)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(0.4, 1.9), NumberSequenceKeypoint.new(1, 0) })
	pe.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 226, 120)), ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 150, 50)), ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 70, 30)) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.7, 0.4), NumberSequenceKeypoint.new(1, 1) })
	pe.LightEmission = 1
	pe.LockedToPart = false
	pe.Parent = att
end
"""

SPECS = {
    "12182258755": {"name": "Long Hedge", "creator": "Verzsk", "creator_id": 2537865409, "restyle": HEDGE},
    "241615822": {"name": "Autumn Tree with falling leaves", "creator": "Wonuf", "creator_id": 43068978, "restyle": AUTUMN},
    "89148106": {"name": "Tiki Torch", "creator": "Searchlites", "creator_id": 15581999, "restyle": TIKI},
}

VERIFY_LUAU = r"""
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local ALLOW = { Model = true, Folder = true, Part = true, MeshPart = true, UnionOperation = true, WedgePart = true, SpecialMesh = true,
	CylinderMesh = true, BlockMesh = true, ParticleEmitter = true, Attachment = true }
local res = {}
for i = 1, #process.args do
	local roots = roblox.deserializeModel(fs.readFile(process.args[i]))
	local hist, bad = {}, {}
	local function visit(inst)
		hist[inst.ClassName] = (hist[inst.ClassName] or 0) + 1
		if not ALLOW[inst.ClassName] then table.insert(bad, inst.ClassName) end
		for _, c in inst:GetChildren() do visit(c) end
	end
	for _, r in roots do visit(r) end
	table.insert(res, { roots = #roots, classes = hist, bad = bad })
end
print(serde.encode("json", res))
"""


def verify(path):
    import subprocess
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        d = Path(td) / "verify.luau"
        d.write_text(VERIFY_LUAU)
        r = subprocess.run(["lune", "run", str(d), str(path)], check=True, capture_output=True, text=True)
    return json.loads(r.stdout)[0]


def main():
    ids = [a for a in sys.argv[1:] if a.isdigit()] or list(SPECS)
    if lane.own_studio_id() is None:
        sys.exit("no own Studio window (" + lane.PLACE + ")")
    BAKES.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    cleanup = bm.CLEANUP.replace("__TMP__", bm.TMP_FOLDER)
    bm.call(cleanup, "bake_toolbox_clean")
    try:
        for id_ in ids:
            spec = SPECS[id_]
            code = LOAD_ONE.replace("__ID__", id_).replace("__RESTYLE__", spec["restyle"])
            rep = bm.call(code, "bake_toolbox_load", timeout=300)
            if not isinstance(rep, dict):
                sys.exit(f"{id_}: load/restyle failed: {str(rep)[:600]}")
            print(f"{id_} {spec['name']} by {spec['creator']}: stripped {rep['removed'] or 'nothing'}; classes {rep['classes']}; "
                  f"size {[round(x, 3) for x in rep['size']]} centre {[round(x, 3) for x in rep['centre']]} minY {rep['minY']:.3f}; meshes {rep.get('meshId')}")
            data = bm.fetch(id_)
            v = verify_bytes(data)
            if v["roots"] != 1 or v["bad"]:
                sys.exit(f"{id_}: bake REFUSED, classes off the allow list: {v['bad']}")
            out = BAKES / f"{id_}.rbxm"
            out.write_bytes(data)
            v = verify(out)
            if v["roots"] != 1 or v["bad"] or any("Script" in c or "Module" in c for c in v["classes"]):
                out.unlink()
                sys.exit(f"{id_}: bake REFUSED: {v}")
            manifest[id_] = {"sha256": hashlib.sha256(data).hexdigest(), "packs": [], "surfaceAppearances": 0, "bytes": len(data),
                             "baked_utc": lane.utc(), "toolbox": True, "creator": spec["creator"], "creator_id": spec["creator_id"],
                             "stripped": rep["removed"], "classes": v["classes"], "size": [round(x, 3) for x in rep["size"]],
                             "centre": [round(x, 3) for x in rep["centre"]]}
            print(f"{id_}: baked {len(data)} bytes -> {out.relative_to(ROOT)}; lune decode: {v['classes']}, no scripts")
    finally:
        bm.call(cleanup, "bake_toolbox_clean")
    manifest = {k: manifest[k] for k in sorted(manifest, key=int)}
    MANIFEST.write_text(json.dumps(manifest, indent=1) + "\n")
    bm.write_project(manifest)


def verify_bytes(data):
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "x.rbxm"
        p.write_bytes(data)
        return verify(p)


if __name__ == "__main__":
    main()
