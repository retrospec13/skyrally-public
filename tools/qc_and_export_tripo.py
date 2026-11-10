"""Import a Tripo GLB in Blender, render 8-angle turntable + top view, decimate cleanly to a game-ready poly budget (< 8,500 tris) preserving UV textures, and save both .blend and embedded-texture .fbx."""
import bpy
import sys
import math
import os
import json
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
glb_path, out_dir, asset_name = argv[0], argv[1], argv[2]
target_tris = int(argv[3]) if len(argv) > 3 else 7500
os.makedirs(out_dir, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb_path)

meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
orig_tris = sum(len(o.data.polygons) for o in meshes)
print(f"[{asset_name}] Imported GLB meshes={len(meshes)} orig_tris={orig_tris}")

# Decimate each mesh proportionally if total > target_tris
if orig_tris > target_tris:
    ratio = max(0.002, min(1.0, target_tris / float(orig_tris)))
    for o in meshes:
        bpy.context.view_layer.objects.active = o
        mod = o.modifiers.new(name="DecimateGame", type="DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = ratio
        mod.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier=mod.name)

final_tris = sum(len(o.data.polygons) for o in meshes)
print(f"[{asset_name}] Decimated to final_tris={final_tris}")

pts = []
for o in meshes:
    mw = o.matrix_world
    pts += [mw @ v.co for v in o.data.vertices]
mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
dims = mx - mn
ctr = (mn + mx) * 0.5

info = {
    "asset_name": asset_name,
    "orig_tris": orig_tris,
    "final_tris": final_tris,
    "dims_xyz": [round(dims.x, 4), round(dims.y, 4), round(dims.z, 4)],
}
json.dump(info, open(os.path.join(out_dir, "qc_dims.json"), "w"), indent=2)

# Save editable .blend and embedded-texture .fbx
blend_out = os.path.join(out_dir, f"{asset_name}.blend")
fbx_out = os.path.join(out_dir, f"{asset_name}.fbx")
bpy.ops.wm.save_as_mainfile(filepath=blend_out)
bpy.ops.export_scene.fbx(filepath=fbx_out, path_mode="COPY", embed_textures=True)
print(f"[{asset_name}] Exported {blend_out} and {fbx_out}")

# Render 4 turntable angles (0, 90, 180, 270) + 3/4 hero + top_down
sc = bpy.context.scene
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "STUDIO"
sc.display.shading.color_type = "TEXTURE"
sc.display.shading.show_cavity = True
sc.render.resolution_x = 640
sc.render.resolution_y = 640
sc.render.film_transparent = False

cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
sc.collection.objects.link(cam)
sc.camera = cam
cam.data.type = "ORTHO"
cam.data.ortho_scale = max(dims) * 1.25
R = max(dims) * 3.0

for ang in (0, 45, 90, 135, 180, 270):
    a = math.radians(ang)
    cam.location = ctr + Vector((math.sin(a) * R, -math.cos(a) * R, dims.z * 0.35))
    d = ctr - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    sc.render.filepath = os.path.join(out_dir, f"turntable_{ang:03d}.png")
    bpy.ops.render.render(write_still=True)

cam.location = ctr + Vector((0, 0, R))
cam.rotation_euler = (0, 0, 0)
sc.render.filepath = os.path.join(out_dir, "top_down.png")
bpy.ops.render.render(write_still=True)
print(f"[{asset_name}] Rendered QC turntables in {out_dir}")
