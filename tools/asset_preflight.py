#!/usr/bin/env python3
"""Asset access preflight (owner invariant 2026-10-18; D19; TEST_LIST_LAUNCH L67). Runs before every checkpoint
publish and after every upload. Blocks the PUBLISH (exit 1) when any required id lacks proven access; it never
blocks the rest of the build.

Required set = closure of:
  1. static references in the deployable tree (every 6+ digit number in .luau sources, rbxassetid://, rbxthumb id=),
     minus the policy's declared non-asset numbers;
  2. runtime references read from the own Studio window in Play (server and client; avatars and core chat excluded);
  3. children of every Model/Decal/Package wrapper, loaded in the own window (actual MeshId/TextureID,
     SurfaceAppearance maps, Decal -> resolved Image id, Sound ids), repeated until no new id appears.
Each id is classified on the PC (owned-user / owned-group-same-owner / foreign-roblox / foreign-third-party /
foreign-or-unknown / lookup-failed). Every owned-user id gets a validated Use grant to the universe (per-item
successAssetIds, retries on transient errors). Foreign/unknown ids pass only with a classified exception in
assets/ledger/asset_access_policy.json that names its evidence (e.g. a published-client preload success), or as
"toolbox-temp": a free Creator Store asset (and the children of a listed Creator Store model) that has a complete row in
docs/ASSETS_TOOLBOX_TEMP.md (owner allowance 2026-10-19: gap fillers, each tracked and listed for later replacement).
Any other foreign third-party id still blocks the publish.
Ledger: assets/ledger/asset_access.jsonl (one decision line per id per run), asset_access_current.json (latest),
pc_ledger_snapshot.jsonl (the PC's append-only upload/audit ledger).
Usage: asset_preflight.py [--no-runtime] [--no-grant]"""
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

LEDGER = lane.ROOT / "assets" / "ledger"
POLICY = LEDGER / "asset_access_policy.json"
SCAN_GLOBS = ["default.project.json", "src/**/*.luau", "builder_*.luau", "map/**/*.luau", "map/**/*.json", "build/**/*.luau", "assets/kits/**/*.json",
              "build/model_bakes/manifest.json"]
MODEL_BAKES = "build/model_bakes/manifest.json"  # tools/bake_models.py: {model id: {packs: [TexturePack ids], ...}}
NUM_RE = re.compile(r"(?<![\w.#])(\d{6,})(?![\w.])")  # "#744634" colours are not ids
WRAPPER_TYPES = {"Model", "Decal", "Package"}
TOOLBOX_LEDGER = lane.ROOT / "docs" / "ASSETS_TOOLBOX_TEMP.md"  # policy key "toolbox_temp_ledger" overrides (repo-relative)
TOOLBOX_CLASSES = {"foreign-third-party", "foreign-or-unknown", "foreign-roblox"}  # lookup-failed never passes
TOOLBOX_COLUMNS = ["asset id", "title", "creator", "type", "where used", "why", "replace-by plan", "added"]

EXPAND_LUA = r"""
local IS = game:GetService('InsertService')
local H = game:GetService('HttpService')
local ids = H:JSONDecode('__IDS__')
local PROPS = {
	MeshPart = {'MeshId', 'TextureID'}, SpecialMesh = {'MeshId', 'TextureId'}, Decal = {'Texture'}, Texture = {'Texture'},
	Sound = {'SoundId'}, SurfaceAppearance = {'ColorMap', 'NormalMap', 'RoughnessMap', 'MetalnessMap'},
	ImageLabel = {'Image'}, ImageButton = {'Image'}, ParticleEmitter = {'Texture'}, Animation = {'AnimationId'},
}
local out = {}
for _, id in ids do
	local e = {wrapper = id, ok = false, children = {}}
	local ok, c = pcall(function() return IS:LoadAsset(tonumber(id)) end)
	if not (ok and c) then
		-- Another creator's Creator Store model (docs/ASSETS_TOOLBOX_TEMP.md) is refused by LoadAsset in the lane Studio
		-- ("User is not authorized to access Asset"); GetObjects reads it, which is what tools/bake_toolbox.py bakes from.
		local ok2, objs = pcall(function() return game:GetObjects('rbxassetid://' .. id) end)
		if ok2 and objs and #objs > 0 then
			local f = Instance.new('Folder')
			for _, o in objs do o.Parent = f end
			ok, c = true, f
		end
	end
	if ok and c then
		e.ok = true
		for _, d in c:GetDescendants() do
			local props = PROPS[d.ClassName]
			if props then
				for _, p in props do
					local okp, v = pcall(function() return (d :: any)[p] end)
					if okp and type(v) == 'string' and v ~= '' then table.insert(e.children, {cls = d.ClassName, prop = p, value = v}) end
				end
			end
		end
		c:Destroy()
	else
		e.err = tostring(c)
	end
	table.insert(out, e)
end
return H:JSONEncode(out)
"""


def ids_in(text):
    out = set(NUM_RE.findall(text))
    out |= set(re.findall(r"rbxassetid://(\d+)", text))
    out |= set(re.findall(r"rbxthumb://[^\"']*?id=(\d+)", text))
    return out


JSON_ID_RE = re.compile(r'"(?:model|[A-Za-z]*[Ii]d|[A-Za-z]*Asset)"\s*:\s*"?(?:rbxassetid://)?(\d{6,})"?')


def model_bake_ids(text):
    """Every id a model bake manifest references: the baked model ids (keys) and their TexturePack ids (numbers)."""
    try:
        data = json.loads(text)
    except ValueError:
        return set()
    out = set()
    for k, row in (data.items() if isinstance(data, dict) else []):
        if str(k).isdigit():
            out.add(str(k))
        for pk in (row.get("packs", []) if isinstance(row, dict) else []):
            if str(pk).isdigit():
                out.add(str(pk))
    return out


def static_scan(non_asset):
    refs = {}
    for g in SCAN_GLOBS:
        for f in lane.ROOT.glob(g):
            text = f.read_text(errors="ignore")
            bake_ids = model_bake_ids(text) if f.relative_to(lane.ROOT).as_posix() == MODEL_BAKES else None
            for n, line in enumerate(text.splitlines(), 1):
                if bake_ids is not None:
                    # Pack ids are bare numbers in lists; sizes and hashes in the same file are not ids.
                    found = set(re.findall(r"\d{6,}", line)) & bake_ids
                elif f.suffix == ".json":
                    # Plans are full of numbers (coordinates, seeds, dates); only explicit asset references count.
                    found = set(re.findall(r"rbxassetid://(\d+)", line)) | set(re.findall(r"rbxthumb://[^\"']*?id=(\d+)", line))
                    found |= set(JSON_ID_RE.findall(line))
                else:
                    found = ids_in(line)
                for i in found:
                    if i not in non_asset:
                        refs.setdefault(i, []).append(f"{f.relative_to(lane.ROOT)}:{n}")
    return refs


def runtime_scan():
    code = (lane.ROOT / "tools" / "luau" / "enumerate_content.luau").read_text()
    lane.play(True)
    time.sleep(28)
    found = {}
    try:
        for dm in ("Server", "Client"):
            t = lane.luau(code, dm=dm, name=f"preflight_enum_{dm}")
            for e in json.loads(t[t.index("["):]):
                raw = e.get("raw", "")
                if raw.startswith("rbxasset://") or not e["id"].isdigit():
                    continue
                found.setdefault(e["id"], []).append(f"runtime:{dm}:{e['where'][0]}")
    finally:
        lane.play(False)
    return found


def classify_on_pc(ids, grant, commit):
    f = lane.OUT / "preflight_ids.json"
    f.write_text(json.dumps(sorted(ids, key=int)))
    lane.put(f, "out/preflight_ids.json")
    flag = "" if grant else " -NoGrant"
    log = lane.ssh(f"powershell -NoProfile -ExecutionPolicy Bypass -File {lane.PCWIN}\\win\\asset_grants.ps1 "
                   f"-IdsFile {lane.PCWIN}\\out\\preflight_ids.json -OutFile {lane.PCWIN}\\out\\preflight_report.json -Commit {commit}{flag}",
                   check=False, timeout=900)
    lane.get("out/preflight_report.json", lane.OUT / "preflight_report.json")
    rep = json.loads((lane.OUT / "preflight_report.json").read_text(encoding="utf-8-sig"))
    assets = rep.get("assets") or []
    if isinstance(assets, dict):
        assets = [assets]
    return {str(a["assetId"]): a for a in assets}, rep, log


def expand_wrappers(wrapper_ids):
    if not wrapper_ids:
        return {}
    t = lane.luau(EXPAND_LUA.replace("__IDS__", json.dumps(sorted(wrapper_ids))), dm="Edit", name="preflight_expand", timeout=300)
    out = {}
    for e in json.loads(t[t.index("["):]):
        kids = {}
        for c in e["children"]:
            for i in ids_in(c["value"]):
                kids.setdefault(i, []).append(f"child-of:{e['wrapper']}:{c['cls']}.{c['prop']}")
        out[str(e["wrapper"])] = {"ok": e["ok"], "err": e.get("err"), "children": kids}
    return out


def load_toolbox_ledger(path=None):
    """Rows of the Creator Store temporary-asset ledger (a markdown table, first column = asset id).
    Returns {asset id: {"cells": [...], "problems": [...]}}; a row with any problem does not grant a pass."""
    path = Path(path) if path else TOOLBOX_LEDGER
    rows = {}
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line.lstrip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        m = re.fullmatch(r"`?(?:rbxassetid://)?(\d{6,})`?", cells[0]) if cells else None
        if not m:  # header, separator, or prose that happens to use a pipe
            continue
        problems = []
        if len(cells) != len(TOOLBOX_COLUMNS):
            problems.append(f"{len(cells)} columns, expected {len(TOOLBOX_COLUMNS)}")
        else:
            problems += [f"empty {TOOLBOX_COLUMNS[k]}" for k in range(1, len(cells)) if not cells[k] or cells[k] in ("-", "?", "TBD")]
            if not re.search(r"\d{3,}|\(\d+\)", cells[2]):
                problems.append("creator needs a name and a numeric id")
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", cells[7]):
                problems.append("added must be YYYY-MM-DD")
        if m.group(1) in rows:
            problems.append("duplicate row")
        rows[m.group(1)] = {"cells": cells, "problems": problems}
    return rows


def decide(i, a, refs_i, expanded, exceptions, toolbox, grant):
    """(ok, why, basis) for one required id. a = the PC classification record, refs_i = every place the id is referenced."""
    cls, g = a.get("class"), a.get("grant")
    basis = None
    if cls == "owned-user":
        ok = (g == "granted") if grant else True
        why, basis = f"grant={g}", "owned-user"
    elif cls == "owned-group-same-owner":
        ok, why, basis = True, "same owner as universe", "owned-group-same-owner"
    elif i in exceptions:
        ok, why, basis = True, f"exception: {exceptions[i].get('class')} - {exceptions[i].get('reason')} (evidence {exceptions[i].get('evidence')})", "exception"
    elif cls in TOOLBOX_CLASSES and i in toolbox:
        row = toolbox[i]
        if row["problems"]:
            ok, why = False, f"{cls}: listed in {TOOLBOX_LEDGER.name} but the row is incomplete ({'; '.join(row['problems'])})"
        else:
            ok, why, basis = True, f"toolbox-temp: {cls}; {TOOLBOX_LEDGER.name} row (replace-by: {row['cells'][6]})", "toolbox-temp"
    else:
        ok, why = False, f"{cls}: no access proof; add a classified exception with evidence, list it in {TOOLBOX_LEDGER.name} (free Creator Store gap filler only) or replace the asset"
        # A mesh/texture/sound inside a listed Creator Store model rides on that row (the model's children are loaded in the own window).
        parents = sorted({r.split(":")[1] for r in refs_i if r.startswith("child-of:")} & {w for w, row in toolbox.items() if not row["problems"]})
        direct = [r for r in refs_i if not r.startswith(("child-of:", "runtime:"))]
        if cls in TOOLBOX_CLASSES and parents and not direct:
            ok, why, basis = True, f"toolbox-temp: {cls}; child of listed Creator Store model {parents[0]}", "toolbox-temp-child"
    if a.get("assetType") in WRAPPER_TYPES and not expanded.get(i, {}).get("ok", False):
        ok, why = False, f"{why}; wrapper could not be expanded: {expanded.get(i, {}).get('err')}"
    return ok, why, basis


def main():
    no_runtime = "--no-runtime" in sys.argv
    grant = "--no-grant" not in sys.argv
    policy = json.loads(POLICY.read_text())
    non_asset = set(policy.get("non_asset_numbers", {}))
    exceptions = policy.get("exceptions", {})
    toolbox = load_toolbox_ledger(lane.ROOT / policy["toolbox_temp_ledger"] if policy.get("toolbox_temp_ledger") else None)
    commit = lane.git_head()
    refs = static_scan(non_asset)
    if not no_runtime:
        for i, w in runtime_scan().items():
            if i not in non_asset:
                refs.setdefault(i, []).extend(w)

    info, expanded, seen_wrappers = {}, {}, set()
    for _round in range(4):
        pending = sorted(set(refs) - set(info), key=int)
        if pending:
            new_info, _, _ = classify_on_pc(pending, grant=False, commit=commit)
            info.update(new_info)
        wrappers = {i for i, a in info.items() if a.get("assetType") in WRAPPER_TYPES} - seen_wrappers
        if not wrappers:
            break
        seen_wrappers |= wrappers
        ex = expand_wrappers(wrappers)
        expanded.update(ex)
        for w, e in ex.items():
            for i, where in e["children"].items():
                if i not in non_asset:
                    refs.setdefault(i, []).extend(where)

    grant_log = ""
    if grant:
        info, rep, grant_log = classify_on_pc(sorted(refs, key=int), grant=True, commit=commit)

    decisions, blocked = [], []
    for i in sorted(refs, key=int):
        a = info.get(i, {"class": "lookup-missing"})
        cls, g = a.get("class"), a.get("grant")
        ok, why, basis = decide(i, a, refs[i], expanded, exceptions, toolbox, grant)
        d = {"utc": lane.utc(), "universe": policy["universe"], "commit": commit, "assetId": i, "assetType": a.get("assetType"),
             "class": cls, "moderation": a.get("moderation"), "grant": g, "decision": "ok" if ok else "BLOCK", "why": why,
             "basis": basis, "refs": refs[i][:6]}
        decisions.append(d)
        if not ok:
            blocked.append(d)

    LEDGER.mkdir(parents=True, exist_ok=True)
    with (LEDGER / "asset_access.jsonl").open("a") as fh:
        for d in decisions:
            fh.write(json.dumps(d) + "\n")
    current = {d["assetId"]: d for d in decisions}
    (LEDGER / "asset_access_current.json").write_text(json.dumps(
        {"utc": lane.utc(), "commit": commit, "required": len(decisions), "blocked": len(blocked), "assets": current}, indent=1))
    try:
        lane.get("out/asset_access_ledger.jsonl", LEDGER / "pc_ledger_snapshot.jsonl")
    except Exception as e:  # the PC ledger exists after the first audit; absence is reported, not fatal
        print("PC ledger snapshot unavailable:", e)
    result = {"utc": lane.utc(), "commit": commit, "required": len(decisions), "blocked": blocked,
              "wrappers": {w: {"ok": e["ok"], "children": sorted(e["children"])} for w, e in expanded.items()}, "grant_log": grant_log[-3000:]}
    (lane.OUT / "asset_preflight_last.json").write_text(json.dumps(result, indent=1))
    print(f"PREFLIGHT required={len(decisions)} blocked={len(blocked)} wrappers={len(expanded)}")
    for d in decisions:
        print(f"  {d['decision']:5} {d['assetId']} {d['assetType']} {d['class']} {d['why']} <- {d['refs'][0]}")
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
