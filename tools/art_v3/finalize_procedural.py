#!/usr/bin/env python3
"""Install the procedural rebuilds (space_arch, start_gantry, mesa_portal) into assets/models/arches_v3, update manifest, notes, sheets."""
import json, shutil, sys
from pathlib import Path
from PIL import Image, ImageDraw
ROOT = Path(__file__).resolve().parents[2]
D = ROOT / "assets/models/arches_v3"; QC = ROOT / "out/art_v3_qc"; B = ROOT / "out/art_v3_build"
man = json.loads((D / "manifest.json").read_text())
META = {
 "space_arch": dict(ref="assets/models/arches_v3/_refs/space_crop.png", label="approved space concept 20 (cream/gold/maroon ring, brick piers)",
   origin="model base (pedestal feet) at y 0, buried 0.8 (y -0.8); opening centred on x = 0. The original arch starts at prefab y 7.2 (parapet caps): ArtSwap align 'bbox', scale 1.",
   opening_txt="superellipse opening 48.5 wide, crown y 40.05",
   opening_note="Required: pedestal inner faces clear of |x| 22.9+0.3 to y 9, then the original ellipse (a 23.95, b 35.75 about y 4, n 2.4) to y 39.75. Built: pedestals inner |x| 24.2-24.4, maroon inner band exactly on the superellipse a 24.25 / b 36.05 (0.3 clearance), crown y 40.05. 0 vertices inside the required opening.",
   integ="Rule meshes {'space_arch'}, scale 1, align 'bbox', non-colliding (as the original). Mirror-exact in X (0 asymmetric vertices). The arch band is 8.4 thick (18% of the 48.5 opening): 6.0 cream stone voussoirs + 2.4 recessed maroon inner band, gold collars on the pedestals, gold clasps over three joints per side, gold-capped keystone with an amber lantern window (front and back).",
   replaces=None),
 "start_gantry": dict(ref="assets/models/arches_v3/start_gantry/concept.png", label="2D asset concept (nano_banana_2)",
   origin="prefab pivot (road point): opening centred on x = 0, depth centred on z = 0, base buried 0.3. Align 'origin', scale 1.",
   opening_txt="|x| 30.6 to y 21.2",
   opening_note="Required: |x| < 29.9 to y 20.6 (+0.6 clearance). Built: post inner faces at |x| 30.0-30.6, beam underside y 21.2 (the sun medallion stays above it). 0 vertices inside the required opening.",
   integ="Wider and heavier than the Tripo version: posts 8.2 wide x 8 deep (1/10 of the span, 4x4-block proportions), beam 9.8 deep, rope wraps, teal caps, stone footings, painted sun medallion on both faces. Overall 79.6 wide (orig 72.4): the 3.6 stud overhang each side is outside the road opening; check the island/hub shore clearance when wiring. The Fabric banner/sign must hang from y 21..13 in front (z -4.6) or be dropped.",
   replaces=None),
 "mesa_portal": dict(ref="assets/models/arches_v3/_refs/space_crop.png", label="approved space concept 20 (cream stone, maroon band, gold brass)",
   origin="prefab pivot (road point): opening centred on x = 0, depth centred on z = 0, base buried 1.9. Align 'origin', scale 1.",
   opening_txt="|x| 20.6 to y 34.7",
   opening_note="Required: |x| < 20 to y 34 (+0.6 clearance). Built: maroon steel-band jambs inner face at |x| 20.6, flat maroon soffit at y 34.7. No baked interior shadow: the reveal is painted maroon (min albedo value 0.50). 0 vertices inside the required opening.",
   integ="Rule meshes {'mesa_portal'}, scale 1, collider 'arch' = the 3 boxes in colliders (2 piers + top bar). Front and back are identical (mirror-exact); flat backside, no stray boxes, flat lintel underside. The separate MesaTunnelChevron prefab stays in the opening under the soffit.",
   replaces=None)}
by = {f["name"]: f for f in man["files"]}
for n, m in META.items():
    d = D / n
    old = d / "rejected_r2_tripo"; old.mkdir(exist_ok=True)
    for f in (f"{n}.glb", "preview.png", "stats.json"):
        if (d / f).exists() and not (old / f).exists():
            shutil.copy(d / f, old / f)
    st = json.loads((B / n / "build.json").read_text())
    shutil.copy(B / n / f"{n}.glb", d / f"{n}.glb"); shutil.copy(B / n / "atlas.png", d / "albedo.png")
    shutil.copy(B / n / "views/preview.png", d / "preview.png")
    shutil.copy(ROOT / "tools/art_v3/build_arch_v3.py", d / "build_arch_v3.py")
    fs = {"mode": "procedural", **st}
    (d / "stats.json").write_text(json.dumps(fs, indent=1))
    ims = [Image.open(ROOT / m["ref"]).convert("RGB"), Image.open(d / "concept.png").convert("RGB"), Image.open(B / n / "views/view_threeq.png").convert("RGB"), Image.open(B / n / "views/view_front.png").convert("RGB")]
    labs = [m["label"], "2D asset concept (nano_banana_2, shape guide only)", "v3 model, three-quarter", f"v3 model, front (opening {m['opening_txt']})"]
    S = 500; sh = Image.new("RGB", (S * 4, S + 34), (24, 22, 26)); dr = ImageDraw.Draw(sh)
    dr.text((8, 9), f"{n}: procedural bevelled-block build (Tripo model rejected by judge), {st['tris']} tris, 1024 tex, {st['size_studs_xyz']} studs", fill=(255, 220, 140))
    for i, (im, lab) in enumerate(zip(ims, labs)):
        sh.paste(im.resize((S, S)), (i * S, 34)); dr.text((i * S + 8, 40), lab, fill=(255, 255, 255))
    sh.save(QC / f"{n}_vs_concept.png")
    e = by[n]
    bmin, bmax = st["bbox_min"], st["bbox_max"]
    e.update({"tris": st["tris"], "size_studs_xyz": st["size_studs_xyz"], "bbox_min": bmin, "bbox_max": bmax, "bbox_centre": st["bbox_centre"],
              "origin": m["origin"], "opening_note": m["opening_note"], "integration": m["integ"],
              "texture": "1024x1024 JPEG albedo (4x4 painted cell atlas), metallic 0, no vertex colours (MeshPart.Color white)",
              "colliders": st["colliders"], "collides_originally": st["collides"], "boundary_edges": st["open_edges"],
              "build": {"method": "procedural bevelled-block build, tools/art_v3/build_arch_v3.py (numpy+PIL), mirror-exact, closed solids, flat normals; first Tripo version kept in rejected_r2_tripo/",
                        "mirror_asymmetric_vertices": st["mirror_asymmetric_vertices"], "vertices_inside_required_opening": st["vertices_inside_required_opening"], "min_albedo_value": st["min_albedo_value"]},
              "rules_numbers": f"{n} = {{ size = Vector3.new({st['size_studs_xyz'][0]}, {st['size_studs_xyz'][1]}, {st['size_studs_xyz'][2]}), centre = Vector3.new({st['bbox_centre'][0]}, {st['bbox_centre'][1]}, {st['bbox_centre'][2]}), bury = {round(-bmin[1], 3)} }}  -- bury = -bbox_min.y",
              "collider_note": "invisible boxes (centre, size) in the model frame: piers + top bar" if st["collides"] else "original did not collide: no colliders"})
    e["opening"] = {"required": st["opening"], "clearance_studs": 0.3 if n == "space_arch" else 0.6, "vertices_inside_original_opening": st["vertices_inside_required_opening"]}
    e["tripo"] = {**e.get("tripo", {}), "status": "rejected by judge round 1 (thin/warped); superseded by the procedural build; no further Tripo credits spent (lane cap 400/400 reached)"}
    (d / "notes.md").write_text(f"""# {n} (arches_v3, revision: procedural rebuild)

- Judge verdict on the Tripo version: failed (thin warped slats, stray geometry, weak silhouette). The lane's Tripo cap (400) was already fully spent, so the fix is a Blender-fix style rebuild: clean bevelled blocks, one half built and mirrored, painted atlas. Old Tripo output kept in `rejected_r2_tripo/`.
- Build: `python3 tools/art_v3/build_arch_v3.py {n} <out>` (copy in this folder), 4x4 cell atlas of painted stone / maroon steel / brass / wood-or-bevel cells, 1024 JPEG, metallic 0, flat normals. Render QC: `tools/art_v3/render_glb.py` (Blender 4.3 on the PC).
- Result: {st['tris']} tris, {st['size_studs_xyz']} studs, 0 open edges, {st['mirror_asymmetric_vertices']} asymmetric vertices, {st['vertices_inside_required_opening']} vertices inside the required opening, min albedo value {st['min_albedo_value']}.
- Opening: {m['opening_note']}
- Integration: {m['integ']}
- Style: palette follows the approved concepts (cream stone, maroon band, brass trim, painted wood); texture is procedural painting, flatter than a Tripo hand-paint. Honest weak point: surfaces are clean but plainer than the concept renders; a Tripo texture pass could be re-projected later if credits allow.
- Not done: not uploaded, not wired into ArtSwapRules, not seen in Studio.
""")
(D / "manifest.json").write_text(json.dumps(man, indent=1))
print("OK")
