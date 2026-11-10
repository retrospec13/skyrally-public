#!/usr/bin/env python3
"""Finalize arches_v3 assets after run_fit.py: copy glb/stats, fetch tripo_task.json from the PC, build the comparison sheets
out/art_v3_qc/<name>_vs_concept.png, the hub portal sign check, notes.md per asset and arches_v3/manifest.json."""
import json, shutil, sys
from pathlib import Path
from PIL import Image, ImageDraw
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane

ROOT = Path(__file__).resolve().parents[2]
D = ROOT / "assets/models/arches_v3"
QC = ROOT / "out/art_v3_qc"
QC.mkdir(parents=True, exist_ok=True)
G = json.loads((Path(__file__).with_name("arch_meta.json")).read_text())
manifest = json.loads((D / "manifest.json").read_text())
keep = [f for f in manifest["files"] if f["name"] == "stone_arch_v3"]
files = list(keep)

for name, meta in G.items():
    d = D / name
    st = json.loads((d / "fit/stats.json").read_text())
    shutil.copy(d / "fit/asset.glb", d / f"{name}.glb")
    shutil.copy(d / "fit/stats.json", d / "stats.json")
    shutil.copy(d / "fit/preview.png", d / "preview.png")
    try:
        lane.get(f"out/art_v3_arch/{name}/tripo_task.json", d / "tripo_task.json")
    except Exception as e:  # noqa: BLE001
        print("tripo_task fetch fail", name, str(e)[:100])
    tt = json.loads((d / "tripo_task.json").read_text()) if (d / "tripo_task.json").exists() else {}
    jobs = json.loads((d / "concept_jobs.json").read_text())
    # comparison sheet: reference crop | 2D concept | 3/4 | front
    ref = Image.open(ROOT / meta["ref"]).convert("RGB")
    ims = [ref, Image.open(d / "concept.png").convert("RGB"), Image.open(d / "fit/view_threeq.png").convert("RGB"), Image.open(d / "fit/view_front.png").convert("RGB")]
    labs = [meta["ref_label"], "2D asset concept (nano_banana_2)", "v3 model, three-quarter", f"v3 model, front (opening {meta['opening_txt']})"]
    S = 500
    sheet = Image.new("RGB", (S * 4, S + 34), (24, 22, 26))
    dr = ImageDraw.Draw(sheet)
    dr.text((8, 9), f"{name} ({meta['replaces_txt']}): Tripo {tt.get('model_task_id','?')[:8]}, {st['tris']} tris, 1024 tex, {st['size_studs_xyz'][0]} x {st['size_studs_xyz'][1]} x {st['size_studs_xyz'][2]} studs", fill=(255, 220, 140))
    for i, (im, lab) in enumerate(zip(ims, labs)):
        sheet.paste(im.resize((S, S)), (i * S, 34))
        dr.text((i * S + 8, 40), lab, fill=(255, 255, 255))
    sheet.save(QC / f"{name}_vs_concept.png")
    prof = json.loads((d / "open.json").read_text())
    bmin, bmax = st["bbox_min"], st["bbox_max"]
    o = st["opening"]
    entry = {
        "name": name, "glb": f"assets/models/arches_v3/{name}/{name}.glb", "roblox_name": f"SkyRally_arches_{name}",
        "replaces": meta["replaces"], "tripo": {"model_task_id": tt.get("model_task_id"), "credits": 50.0, "face_limit": tt.get("payload", {}).get("face_limit"), "texture_quality": "detailed", "input": "concept_tripo_input.png (opening painted out to the background grey)"},
        "concept": {"job_id": jobs[-1]["job_id"], "credits": jobs[-1].get("credits"), "refs": [Path(r).name for r in jobs[-1]["refs"]]},
        "tris": st["tris"], "texture": "1024x1024 JPEG albedo, metallic 0, no vertex colours (MeshPart.Color white)",
        "size_studs_xyz": st["size_studs_xyz"], "bbox_min": bmin, "bbox_max": bmax, "bbox_centre": st["bbox_centre"],
        "origin": meta["origin"], "opening": {"required_profile_halfwidth_by_y": prof["pts"][:1] + prof["pts"][-1:], "clearance_studs": prof["clear"], "crown_y": o["crown_y"], "x_at_y": o["x_at_y"],
                                               "vertices_inside_original_opening": o["vertices_inside_original_opening"], "collider_samples_inside_original_opening": o["collider_samples_inside_original_opening"]},
        "opening_note": meta["opening_note"], "kept_original_parts": meta["kept"], "integration": meta["integration"],
        "rules_numbers": f"{name} = {{ size = Vector3.new({st['size_studs_xyz'][0]}, {st['size_studs_xyz'][1]}, {st['size_studs_xyz'][2]}), centre = Vector3.new({st['bbox_centre'][0]}, {st['bbox_centre'][1]}, {st['bbox_centre'][2]}), bury = {round(-bmin[1], 3)} }}  -- bury = -bbox_min.y (ArtSwapRules.originPosition adds bury*scale to the bbox bottom; arches_v3's first entry wrote -1.5, the sign was wrong but unused with align 'origin')",
        "colliders": st["colliders"], "collider_note": "invisible boxes (centre, size) in the model frame: 4-stud column strips over the solid front silhouette, carved clear of the original opening; use them only where the original collided." if meta["collides"] else "original did not collide: ignore these",
        "collides_originally": meta["collides"], "moving_parts": "none (static)", "boundary_edges": st["boundary_edges"],
    }
    if "sign" in meta:
        entry["hub_sign_and_label"] = meta["sign"]
    files.append(entry)
    (d / "notes.md").write_text(meta["notes"].format(tt=tt.get("model_task_id"), tris=st["tris"], size=st["size_studs_xyz"], job=jobs[-1]["job_id"]))
manifest["files"] = files
manifest["generator"] += " Round 2 (2026-10-19): remaining arches and gantries; fit via win/art_v3_fit.py arch mode with the opening-aware warp (open=<profile json> warp pk rect rz), tools/art_v3/make_guides.py for guides/profiles, tools/art_v3/finalize_arches.py for sheets and this manifest."
(D / "manifest.json").write_text(json.dumps(manifest, indent=1))
print("OK", [f["name"] for f in files])
