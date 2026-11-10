#!/usr/bin/env python3
"""plan.json -> Roblox builder.

Reads a BloxMap plan (tools/mapgen.py output) and emits:
  <out>/builder.server.luau    one ServerScript that rebuilds the map at runtime
  <out>/overview.client.luau   (only with --overview-cam) QA orbit camera
  <project>                    rojo project wiring them into a place

The plan data is baked into the script as a JSON long-string and decoded with
HttpService:JSONDecode at runtime (works without HttpEnabled). Prefabs are kept
as one template each and cloned per instance; see NOTES.md for the schema.

usage: build_plan.py PLAN.json [--out build_output] [--project default.project.json]
                     [--overview-cam] [--name NAME]

SKYRALLY PATCH: vendored from 30MAPS aa9a451 (tools/map30/SOURCE.txt lists every
patch). --out, --project and --name are required; the map builds under
Workspace.Maps.<NAME>, never touches Lighting or SpawnLocations, and the project
sets neither StreamingEnabled nor a SpawnLocation.
"""
import argparse
import hashlib  # SKYRALLY PATCH (terrain bake)
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REPO = os.path.dirname(ROOT)  # SKYRALLY PATCH: repo root (this file is tools/map30/build_plan.py)
PAD_KINDS = ("Checkpoint", "Objective", "Teleport")  # SKYRALLY PATCH: marker kinds the builder turns into pads


def rnd(v, nd=3):
    if isinstance(v, float):
        r = round(v, nd)
        return int(r) if r == int(r) else r
    if isinstance(v, list):
        return [rnd(x, nd) for x in v]
    if isinstance(v, dict):
        return {k: rnd(x, nd) for k, x in v.items()}
    return v


def load_plan(path):
    with open(path) as f:
        plan = json.load(f)
    # SKYRALLY PATCH (doc only): "terrain" stays required as on aa9a451; a map without a height grid
    # passes {"nx": 1, "nz": 1}, which the builder skips ("no terrain in plan") with no Terrain side effects.
    for k in ("instances", "prefabs", "terrain"):
        if k not in plan:
            sys.exit(f"plan {path} has no '{k}'")
    # SKYRALLY PATCH: the builder reads markers and labels outside any pcall, so a bad entry stopped the Script
    # before the readiness attribute was set; reject it here instead (a null list reads as empty)
    for k in ("groups", "markers", "labels"):
        if plan.get(k) is None:
            plan[k] = []
        elif not isinstance(plan[k], list):
            sys.exit(f"plan {path}: '{k}' must be a list")
    for i, m in enumerate(plan["markers"], 1):
        if not isinstance(m, dict):
            sys.exit(f"marker {i}: not an object")
        if m.get("kind") in PAD_KINDS and not (is_vec3(m.get("p")) and is_scalar(m.get("name"))
                                               and is_scalar(m.get("index"))):
            sys.exit(f"marker {i} ({m['kind']}): needs p [x,y,z] and a string or number name/index")
    for i, lab in enumerate(plan["labels"], 1):
        if not (isinstance(lab, dict) and isinstance(lab.get("text"), str) and is_vec3(lab.get("p"))):
            sys.exit(f"label {i}: needs a string text and p [x,y,z]")
    return plan


def is_num(v):  # SKYRALLY PATCH (plan checks)
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def is_vec3(v):  # SKYRALLY PATCH (plan checks)
    return isinstance(v, list) and len(v) == 3 and all(is_num(x) for x in v)


def is_scalar(v):  # SKYRALLY PATCH (plan checks): nil or a value Luau can concatenate and store as an attribute
    return v is None or isinstance(v, str) or is_num(v)


def source_label(plan_path):
    # SKYRALLY PATCH: repo-relative plan path in the builder header, so a committed builder is identical from
    # every checkout (stock embedded the absolute path); a plan outside the repo keeps its absolute path
    p = os.path.abspath(plan_path)
    try:
        rel = os.path.relpath(p, REPO)
    except ValueError:  # another Windows drive
        return p
    if rel == os.pardir or rel.startswith(os.pardir + os.sep):
        return p
    return rel.replace(os.sep, "/")


def pack(plan, name):
    prefabs = plan["prefabs"]
    keys = sorted(prefabs)
    index = {k: i + 1 for i, k in enumerate(keys)}  # 1-based for Luau
    pf_out = []
    for k in keys:
        parts = []
        for p in prefabs[k]["parts"]:
            if len(p) < 12:
                sys.exit(f"prefab {k}: part with {len(p)} fields (expected 12-13)")
            q = rnd(list(p[:12]))
            # JSON null inside a Luau array leaves a hole; rotations default to 0
            for j in (7, 8, 9):
                if q[j] is None:
                    q[j] = 0
            if len(p) > 12 and isinstance(p[12], dict) and p[12]:
                q.append(rnd(p[12]))
            parts.append(q)
        pf_out.append({"key": k, "parts": parts})

    inst_out = []
    part_count = 0
    for i, inst in enumerate(plan["instances"]):
        k = inst["pf"]
        if k not in index:
            sys.exit(f"instance {i}: unknown prefab {k}")
        r = inst.get("r")
        if r is None:
            r = 0
        elif isinstance(r, list):
            r = [x or 0 for x in r]
        s = inst.get("s") or 1
        x, y, z = inst["p"]
        inst_out.append([index[k], inst.get("g", 0), rnd(x), rnd(y), rnd(z), rnd(r), rnd(s)])
        part_count += len(prefabs[k]["parts"])

    t = dict(plan["terrain"])
    # SKYRALLY PATCH: cell is optional (the builder already defaults it to 4); aa9a451 raised KeyError
    # in the summary print after the outputs were written
    t.setdefault("cell", 4)
    n = t["nx"] * t["nz"]
    for key in ("heights", "materials", "ceilings"):
        if key in t and len(t[key]) != n:
            sys.exit(f"terrain.{key} has {len(t[key])} values, expected nx*nz={n}")
    t = rnd(t, 2)

    return {
        "name": name,
        "partCount": part_count,
        "groups": plan.get("groups", []),
        "prefabs": pf_out,
        "instances": inst_out,
        "terrain": t,
        "lighting": plan.get("lighting"),
        "markers": plan.get("markers", []),
        "labels": plan.get("labels", []),
    }


def spawn_marker(plan):
    for m in plan.get("markers", []):
        if m.get("kind") == "Spawn":
            return m
    return None


# SKYRALLY PATCH (terrain bake, V1 D1): the template's terrain step (header, helpers, buildTerrain and its call) ends
# where this section starts; nothing after it writes voxels, so a change to the prefab/instance code keeps the bakes.
TERRAIN_CODE_END = "------------------------------------------------------------------ prefabs"


def terrain_code(tpl):
    # SKYRALLY PATCH (terrain bake, V1 D1): the part of the template that decides the voxels
    i = tpl.find(TERRAIN_CODE_END)
    if i < 0:
        sys.exit(f"builder template has no {TERRAIN_CODE_END!r} line (terrain hash scope)")
    return tpl[:i]


def terrain_hash(tpl, data):
    # SKYRALLY PATCH (terrain bake): identifies the voxels the builder's terrain step writes: the template's terrain
    # code (terrain_code, V1 D1: no longer the whole template) plus the packed terrain block (the data). A baked
    # TerrainRegion is used only while its TerrainHash equals this.
    h = hashlib.sha256()
    h.update(terrain_code(tpl).encode("utf-8"))
    h.update(b"\0")
    h.update(json.dumps(data["terrain"], sort_keys=True, separators=(",", ":")).encode("utf-8"))
    return h.hexdigest()[:16]


def ready_attribute(name):
    # SKYRALLY PATCH: per-map readiness attribute on Workspace. Roblox attribute names allow only
    # [A-Za-z0-9_] (max 100 chars), so "DINO-4" -> "MapBuilt_DINO_4". MapAdapter must use the same rule.
    key = "MapBuilt_" + re.sub(r"[^A-Za-z0-9_]", "_", name)
    if len(key) > 100:
        sys.exit(f"map name {name!r} too long for a Roblox attribute name")
    return key


def write_project(path, name, out_rel, overview, spawn):
    # SKYRALLY PATCH: no Workspace.StreamingEnabled (the game project owns streaming) and no
    # SpawnLocation (the game owns spawns); Spawn markers are ignored, so `spawn` is unused here
    tree = {
        "$className": "DataModel",
        "Workspace": {
            "$className": "Workspace",
        },
        "Lighting": {
            "$className": "Lighting",
            "$properties": {"Technology": "ShadowMap"},
        },
        "ServerScriptService": {
            "$className": "ServerScriptService",
            "MapBuilder": {"$path": f"{out_rel}/builder.server.luau"},
        },
    }
    # SKYRALLY PATCH: stock placed the project SpawnLocation at the first Spawn marker here
    if overview:
        tree["StarterPlayer"] = {
            "$className": "StarterPlayer",
            "StarterPlayerScripts": {
                "$className": "StarterPlayerScripts",
                "OverviewCam": {"$path": f"{out_rel}/overview.client.luau"},
            },
        }
    proj = {"name": name, "tree": tree}
    with open(path, "w") as f:
        json.dump(proj, f, indent=2)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("plan")
    # SKYRALLY PATCH: required; the stock defaults write under tools/ here, and the name keys
    # Workspace.Maps.<NAME> (map/<key>/plan.json would otherwise become "plan")
    ap.add_argument("--out", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--name", required=True, help="map id, e.g. DINO-4 (Workspace.Maps child name)")
    ap.add_argument("--overview-cam", action="store_true", help="add the QA orbit camera LocalScript")
    a = ap.parse_args()

    plan = load_plan(a.plan)
    stem = os.path.splitext(os.path.basename(a.plan))[0]
    name = a.name or stem.replace("_plan", "")
    data = pack(plan, name)
    blob = json.dumps(data, separators=(",", ":"))
    if "]==]" in blob:
        sys.exit("plan data contains ']==]', cannot embed as a long string")

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(HERE, "builder_template.luau")) as f:
        tpl = f.read()
    ready = ready_attribute(name)  # SKYRALLY PATCH
    src = (tpl.replace("@@SOURCE@@", source_label(a.plan)).replace("@@READY@@", ready)
           .replace("@@TERRAIN_HASH@@", terrain_hash(tpl, data)).replace("@@DATA@@", blob))  # SKYRALLY PATCH (terrain bake)
    builder = os.path.join(a.out, "builder.server.luau")
    with open(builder, "w") as f:
        f.write(src)

    ov_path = os.path.join(a.out, "overview.client.luau")
    if a.overview_cam:
        cam = plan.get("camera") or {}
        focus = cam.get("focus") or [0, 0, 0]
        radius = cam.get("radius") or 300
        sp = spawn_marker(plan)
        # look from above the spawn side toward the focus
        if sp:
            dx, dz = sp["p"][0] - focus[0], sp["p"][2] - focus[2]
            l = math.hypot(dx, dz) or 1
            d = [dx / l, 0.85, dz / l]
        else:
            d = [1, 0.8, 1]
        with open(os.path.join(HERE, "overview_template.luau")) as f:
            ot = f.read()
        ot = (ot.replace("@@FOCUS@@", ", ".join(str(rnd(v)) for v in focus))
                .replace("@@RADIUS@@", str(rnd(radius)))
                .replace("@@DIR@@", ", ".join(str(rnd(v)) for v in d)))
        with open(ov_path, "w") as f:
            f.write(ot)
    elif os.path.exists(ov_path):
        os.remove(ov_path)

    out_rel = os.path.relpath(a.out, os.path.dirname(os.path.abspath(a.project))).replace(os.sep, "/")
    write_project(a.project, name, out_rel, a.overview_cam, spawn_marker(plan))

    print(f"plan       {a.plan}")
    print(f"name       {name}")
    print(f"prefabs    {len(data['prefabs'])}")
    print(f"instances  {len(data['instances'])}")
    print(f"parts      {data['partCount']}")
    t = data["terrain"]
    print(f"terrain    {t['nx']}x{t['nz']} nodes, cell {t['cell']}, palette {len(t.get('palette', []))}")
    # SKYRALLY PATCH: say what the builder will ignore and which attribute signals readiness
    spawns = sum(1 for m in plan.get("markers", []) if m.get("kind") == "Spawn")
    if plan.get("lighting") is not None or spawns:
        print(f"ignored    lighting block: {'yes' if plan.get('lighting') is not None else 'no'}, Spawn markers: {spawns}")
    print(f"root       Workspace.Maps.{name} (ready: workspace.{ready})")
    print(f"builder    {builder} ({os.path.getsize(builder)} bytes)")
    if a.overview_cam:
        print(f"overview   {ov_path}")
    print(f"project    {a.project}")


if __name__ == "__main__":
    main()
