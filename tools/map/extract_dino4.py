#!/usr/bin/env python3
"""L1 extraction of the current DINO-4 builder into data (TRACK_PIPELINE P1 input). Runs the builder, source-patched
with a recording Terrain proxy, in the own Studio window's Edit DataModel and writes map/dino4/extracted/:
terrain_ops.json (every Terrain call in order with its builder line), art.json (parts, units, meshes, fx, hazards,
model attributes, gameplay objects as built, checkpoint stations), and fallback.json (the block sauropod captured
with the Tripo load forced to fail). The builder itself is not modified."""
import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane  # noqa: E402

OUTDIR = lane.ROOT / "map" / "dino4" / "extracted"
LISTS = ["parts", "meshes", "fx", "units", "hazards", "gameplay", "skipped", "attrs", "checkpoints"]


def run(force_fallback):
    code = (lane.ROOT / "tools" / "luau" / "extract_builder.luau").read_text()
    src = (lane.ROOT / "builder_dino4.luau").read_bytes()
    code = code.replace("__SOURCE_B64__", base64.b64encode(src).decode()).replace("__FORCE_FALLBACK__", "true" if force_fallback else "false")
    meta = lane.luau(code, dm="Edit", name="extract_run", timeout=600)
    print("meta:", meta[:600])
    if "BUILD_ERR" in meta or "NO_ROOT" in meta:
        raise SystemExit(meta)
    out = {"meta": json.loads(meta[meta.index("{"):])}
    for k in LISTS:
        out[k] = lane.read_g_list(f"EXTRACT.{k}", dm="Edit", chunk=150, name=f"extract_{k}")
    out["terrain_ops"] = lane.read_g_list("EXTRACT_TERRAIN_OPS", dm="Edit", chunk=150, name="extract_terrain")
    return out


def main():
    OUTDIR.mkdir(parents=True, exist_ok=True)
    if "Edit" not in lane.state().split("Current Studio Mode:")[-1].splitlines()[0]:
        lane.play(False)
    a = run(False)
    (OUTDIR / "terrain_ops.json").write_text(json.dumps(a.pop("terrain_ops"), indent=0))
    a["source"] = {"builder": "builder_dino4.luau", "head": lane.git_head(), "utc": lane.utc()}
    (OUTDIR / "art.json").write_text(json.dumps(a, indent=0))
    b = run(True)
    fb = {"parts": [p for p in b["parts"] if p["unit"].startswith("Landmarks/RoamingGreenSauropod")],
          "meshes": b["meshes"], "source": a["source"]}
    (OUTDIR / "fallback.json").write_text(json.dumps(fb, indent=0))
    print("wrote", OUTDIR, {k: len(v) for k, v in a.items() if isinstance(v, list)}, "fallback parts", len(fb["parts"]))


if __name__ == "__main__":
    main()
