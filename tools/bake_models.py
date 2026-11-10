#!/usr/bin/env python3
"""Model bakes (texpack fix, 2026-10-19; docs/ASSETS.md "Model bakes"): give the live client the SurfaceAppearance
TexturePacks that Open Cloud GLB uploads never carry.

Why: a SurfaceAppearance (like a MaterialVariant, see tools/vfx/capture_texture_packs.py) has a hidden saved property
TexturePack that Studio generates from its maps; a live client loads PBR maps only through that pack. A model uploaded
as GLB through Open Cloud comes back from InsertService:LoadAsset with an EMPTY pack, so on a published server the hero
car, the hero plane, their split parts and the bosses drew untextured ("Failed to load ...SurfaceAppearance. PBR
textures may not be visible in game"). Studio fills the pack in once it has the model loaded.

What: in the lane's own Studio window (Edit DataModel) each model id is loaded with InsertService:LoadAsset, kept off
the place (Parent = nil), and polled until Studio has generated every SurfaceAppearance.TexturePack. If packs are still
empty after half the timeout the containers move into a temporary ServerStorage folder "__ModelBakeTmp"
(Archivable = false, so a save never keeps it; --no-parent skips this) in case Studio generates packs only for
instances in the DataModel. The loaded model is serialized with SerializationService:SerializeInstancesAsync, written
to build/model_bakes/<id>.rbxm, decoded again with lune (every SurfaceAppearance must carry a non-empty pack) and
recorded in build/model_bakes/manifest.json {id: {sha256, packs: [numbers], surfaceAppearances, bytes, baked_utc}}.
default.project.json's ServerStorage.ModelBakes is rewritten from the manifest (one Model per id, named by the id);
src/shared/ModelBakes.luau clones a bake instead of calling LoadAsset whenever one is mounted.

Studio stays read-only: nothing is written to the place besides the temporary LoadAsset results and the temporary
folder, which are destroyed at the end (and at the start, should a previous run have died). No upload, no Open Cloud.
Idempotent: a model whose fresh bake decodes to the same packs and SurfaceAppearance count as the existing file keeps
its file and manifest row (serialization is not byte-stable); --force rewrites them.

Rerun after ANY re-upload of a model (new id: update the src reference first; the old bake then simply stops being
looked up and --prune drops it).

Usage: bake_models.py [ids...] [--timeout S] [--force] [--no-parent] [--prune] [--dry-run]
  no ids: every model id referenced in src/ whose LoadAsset result holds a SurfaceAppearance (probed in Studio).
  --dry-run: list the candidate / probed ids and exit without baking."""
import base64
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

ROOT = lane.ROOT
BAKES = ROOT / "build" / "model_bakes"
MANIFEST = BAKES / "manifest.json"
PROJECT = ROOT / "default.project.json"
POLICY = ROOT / "assets" / "ledger" / "asset_access_policy.json"
CHUNK = 90000  # execute_luau output is truncated at 100000 characters
PROBE_BATCH = 20
TMP_FOLDER = "__ModelBakeTmp"

# Lines that cannot hold a model id: content URIs and audio/image tables.
SKIP_LINE = re.compile(r"rbxassetid://|rbxthumb://|SoundId|Image\s*=|Texture\w*\s*=")
SKIP_FILE = re.compile(r"Audio|Sfx|Music|Sound|Images|TexAssets|BuildInfo|bossclips", re.I)
NUM_RE = re.compile(r"(?<![\w.#])(\d{6,})(?![\w.])")

PRELUDE = r"""
local IS = game:GetService("InsertService")
local H = game:GetService("HttpService")
local SS = game:GetService("ServerStorage")
local Ser = game:GetService("SerializationService")
local Enc = game:GetService("EncodingService")
_G.__mb = _G.__mb or {}
local function sas(c)
	local out = {}
	for _, d in c:GetDescendants() do
		if d:IsA("SurfaceAppearance") then table.insert(out, d) end
	end
	return out
end
local function b64(list)
	return buffer.tostring(Enc:Base64Encode(Ser:SerializeInstancesAsync(list)))
end
"""

PROBE = PRELUDE + r"""
local out = {}
for _, id in H:JSONDecode('__IDS__') do
	local ok, c = pcall(function() return IS:LoadAsset(tonumber(id)) end)
	if ok and c then
		out[id] = #sas(c)
		c:Destroy()
	else
		out[id] = -1
	end
end
return "JSON=" .. H:JSONEncode(out)
"""

CLEANUP = PRELUDE + r"""
for _, c in _G.__mb do pcall(function() c:Destroy() end) end
_G.__mb = nil
_G.__mbOut = nil
local f = SS:FindFirstChild("__TMP__")
if f then f:Destroy() end
return "CLEAN"
"""

LOAD = PRELUDE + r"""
local out = {}
for _, id in H:JSONDecode('__IDS__') do
	if not _G.__mb[id] then
		local ok, c = pcall(function() return IS:LoadAsset(tonumber(id)) end)
		if ok and c then _G.__mb[id] = c else out[id] = "ERR " .. tostring(c) end
	end
	if _G.__mb[id] then out[id] = #sas(_G.__mb[id]) end
end
return "JSON=" .. H:JSONEncode(out)
"""

PARENT = PRELUDE + r"""
local f = SS:FindFirstChild("__TMP__")
if not f then
	f = Instance.new("Folder")
	f.Name = "__TMP__"
	f.Archivable = false
	f.Parent = SS
end
for _, c in _G.__mb do c.Parent = f end
return "PARENTED"
"""

# Only the SurfaceAppearances (small) are serialized while polling; lune reads their packs here.
POLL = PRELUDE + r"""
local out = {}
for _, id in H:JSONDecode('__IDS__') do
	local c = _G.__mb[id]
	if c then out[id] = b64(sas(c)) end
end
return "JSON=" .. H:JSONEncode(out)
"""

SERIALIZE = PRELUDE + r"""
local c = _G.__mb['__ID__']
if not c then return "ERR not loaded" end
local parent = c.Parent
c.Parent = nil
local bytes = Ser:SerializeInstancesAsync({ c })
c.Parent = parent
_G.__mbOut = buffer.tostring(Enc:Base64Encode(bytes))
return "JSON=" .. H:JSONEncode({ bytes = buffer.len(bytes), b64 = #_G.__mbOut })
"""

READ = "return string.sub(_G.__mbOut, %d, %d)"

DECODE_LUAU = r"""
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local res = {}
for i = 1, #process.args do
	local roots = roblox.deserializeModel(fs.readFile(process.args[i]))
	local list = {}
	local function visit(inst)
		if inst.ClassName == "SurfaceAppearance" then table.insert(list, inst) end
		for _, d in inst:GetDescendants() do
			if d.ClassName == "SurfaceAppearance" then table.insert(list, d) end
		end
	end
	for _, r in roots do visit(r) end
	local packs = {}
	for _, sa in list do
		local ok, c = pcall(function() return sa.TexturePackContent.Uri end)
		local s = if ok and c ~= nil then tostring(c) else ""
		table.insert(packs, string.match(s, "rbxassetid://(%d+)") or string.match(s, "^(%d+)$") or "")
	end
	table.insert(res, { roots = #roots, rootClass = if roots[1] then roots[1].ClassName else "", sa = #list, packs = packs })
end
print(serde.encode("json", res))
"""


def decode(paths):
    with tempfile.TemporaryDirectory() as td:
        d = Path(td) / "decode.luau"
        d.write_text(DECODE_LUAU)
        r = subprocess.run(["lune", "run", str(d), *map(str, paths)], check=True, capture_output=True, text=True)
    return json.loads(r.stdout)


def decode_bytes(blobs):
    with tempfile.TemporaryDirectory() as td:
        paths = []
        for i, b in enumerate(blobs):
            p = Path(td) / f"{i}.rbxm"
            p.write_bytes(b)
            paths.append(p)
        return decode(paths) if paths else []


def call(code, name, timeout=300):
    res = str(lane.luau(code, dm="Edit", name=name, timeout=timeout))
    if "JSON=" in res:
        return json.loads(res.split("JSON=", 1)[1].strip())
    return res


def candidates():
    non_asset = set()
    if POLICY.exists():
        non_asset = set(json.loads(POLICY.read_text()).get("non_asset_numbers", {}))
    ids = set()
    for f in (ROOT / "src").rglob("*.luau"):
        if SKIP_FILE.search(f.name):
            continue
        for line in f.read_text(errors="ignore").splitlines():
            code = line.split("--", 1)[0] if not line.lstrip().startswith("--") else ""
            if not code or SKIP_LINE.search(code):
                continue
            ids |= set(NUM_RE.findall(code))
    return sorted(ids - non_asset, key=int)


def probe(ids):
    found = {}
    for i in range(0, len(ids), PROBE_BATCH):
        part = ids[i:i + PROBE_BATCH]
        r = call(PROBE.replace("__IDS__", json.dumps(part)), "bake_models_probe", timeout=600)
        if not isinstance(r, dict):
            raise RuntimeError("probe failed: " + str(r)[:400])
        found.update(r)
        print(f"probe {i + len(part)}/{len(ids)}", flush=True)
    return sorted([k for k, n in found.items() if n and n > 0], key=int)


def poll_packs(ids):
    r = call(POLL.replace("__IDS__", json.dumps(ids)), "bake_models_poll")
    if not isinstance(r, dict):
        raise RuntimeError("poll failed: " + str(r)[:400])
    keys = [k for k in ids if k in r]
    rows = decode_bytes([base64.b64decode(r[k]) for k in keys])
    return {k: row for k, row in zip(keys, rows)}


def fetch(id_):
    info = call(SERIALIZE.replace("__ID__", id_), "bake_models_ser")
    if not isinstance(info, dict):
        raise RuntimeError(f"{id_}: serialize failed: {str(info)[:400]}")
    parts = []
    for i in range(0, info["b64"], CHUNK):
        for _ in range(6):  # the shared PC's MCP bridge drops for tens of seconds under load
            piece = re.sub(r"\s", "", str(lane.luau(READ % (i + 1, i + CHUNK), dm="Edit", name="bake_models_read", timeout=180)))
            if re.fullmatch(r"[A-Za-z0-9+/=]*", piece):
                break
            time.sleep(15)
        else:
            raise RuntimeError(f"{id_}: bad chunk at {i}: {piece[:120]}")
        parts.append(piece)
    data = base64.b64decode("".join(parts))
    if len(data) != info["bytes"]:
        raise RuntimeError(f"{id_}: got {len(data)} bytes, Studio serialized {info['bytes']}")
    return data


def write_project(manifest):
    proj = json.loads(PROJECT.read_text())
    ss = proj["tree"]["ServerStorage"]
    node = {"$className": "Folder"}
    for k in sorted(manifest, key=int):
        node[k] = {"$path": f"build/model_bakes/{k}.rbxm"}
    if ss.get("ModelBakes") != node:
        ss["ModelBakes"] = node
        PROJECT.write_text(json.dumps(proj, indent=2) + "\n")
        print(f"default.project.json: ServerStorage.ModelBakes mounts {len(manifest)} bakes")


def main():
    args = sys.argv[1:]
    opt, ids, timeout = set(), [], 300.0
    it = iter(args)
    for a in it:
        if a == "--timeout":
            timeout = float(next(it))
        elif a.startswith("--"):
            opt.add(a)
        elif a.isdigit():
            ids.append(a)
        else:
            sys.exit(f"bad argument {a!r}\n" + __doc__)
    ids = list(dict.fromkeys(ids))
    BAKES.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}

    if lane.own_studio_id() is None:
        sys.exit("no own Studio window (" + lane.PLACE + ")")
    cleanup = CLEANUP.replace("__TMP__", TMP_FOLDER)
    call(cleanup, "bake_models_clean")
    try:
        if not ids:
            cand = candidates()
            print(f"{len(cand)} candidate ids in src/; probing for SurfaceAppearances", flush=True)
            ids = probe(cand)
        print("bake ids:", " ".join(ids), flush=True)
        if "--dry-run" in opt or not ids:
            return

        loaded = call(LOAD.replace("__IDS__", json.dumps(ids)), "bake_models_load", timeout=600)
        if not isinstance(loaded, dict):
            raise RuntimeError("load failed: " + str(loaded)[:400])
        bad = {k: v for k, v in loaded.items() if not isinstance(v, int) or v == 0}
        for k, v in bad.items():
            print(f"{k}: skipped ({'no SurfaceAppearance' if v == 0 else v})")
        ids = [k for k in ids if k not in bad]

        t0, parented, rows = time.time(), False, {}
        while ids:
            rows = poll_packs(ids)
            waiting = [k for k in ids if k not in rows or "" in rows[k]["packs"] or rows[k]["sa"] == 0]
            if not waiting:
                break
            el = time.time() - t0
            if el > timeout:
                break
            if not parented and el > timeout / 2 and "--no-parent" not in opt:
                print(f"packs still empty after {el:.0f}s for {waiting}; parenting into ServerStorage.{TMP_FOLDER} (temporary, Archivable=false)", flush=True)
                call(PARENT.replace("__TMP__", TMP_FOLDER), "bake_models_parent")
                parented = True
            print(f"waiting for packs ({el:.0f}s): " + ", ".join(f"{k} {rows[k]['packs'].count('')}/{rows[k]['sa']}" for k in waiting if k in rows), flush=True)
            time.sleep(10)

        now = lane.utc()
        failed = []
        for k in ids:
            row = rows.get(k)
            if not row or row["sa"] == 0 or "" in row["packs"]:
                print(f"{k}: FAILED, packs not generated within {timeout:.0f}s ({row and row['packs']}); not writing")
                failed.append(k)
                continue
            data = fetch(k)
            fresh = decode_bytes([data])[0]
            if fresh["roots"] != 1 or "" in fresh["packs"] or fresh["sa"] != row["sa"]:
                print(f"{k}: FAILED, serialized model decodes to {fresh}; not writing")
                failed.append(k)
                continue
            out = BAKES / f"{k}.rbxm"
            packs = [int(p) for p in fresh["packs"]]
            old = manifest.get(k)
            if (out.exists() and old and "--force" not in opt and old.get("packs") == packs
                    and old.get("surfaceAppearances") == fresh["sa"]
                    and hashlib.sha256(out.read_bytes()).hexdigest() == old.get("sha256")):
                print(f"{k}: unchanged ({fresh['sa']} SurfaceAppearances, same packs); kept")
                continue
            out.write_bytes(data)
            check = decode([out])[0]
            if check["roots"] != 1 or "" in check["packs"] or [int(p) for p in check["packs"]] != packs:
                out.unlink()
                raise RuntimeError(f"{k}: written file does not decode to the same packs: {check}")
            manifest[k] = {"sha256": hashlib.sha256(data).hexdigest(), "packs": packs, "surfaceAppearances": fresh["sa"],
                           "bytes": len(data), "baked_utc": now}
            print(f"{k}: {fresh['sa']} SurfaceAppearances, packs {sorted(set(packs))}, {len(data) / 1e3:.0f} kB -> {out.relative_to(ROOT)}", flush=True)
    finally:
        call(cleanup, "bake_models_clean")

    if "--prune" in opt:
        keep = set(candidates())
        for k in [k for k in manifest if k not in keep]:
            print(f"{k}: no longer referenced in src/; pruned")
            (BAKES / f"{k}.rbxm").unlink(missing_ok=True)
            del manifest[k]
    manifest = {k: manifest[k] for k in sorted(manifest, key=int)}
    MANIFEST.write_text(json.dumps(manifest, indent=1) + "\n")
    write_project(manifest)
    print(f"manifest: {len(manifest)} bakes; next: bash tools/tests/run_lune_tests.sh tools/tests/model_bakes_spec.luau")
    if failed:
        sys.exit(f"FAILED: {' '.join(failed)}")


if __name__ == "__main__":
    main()
