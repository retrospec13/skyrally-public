# SkyRally prop QC (Blender 4.3 headless, runs ON THE PC).
# blender -b --factory-startup -P blender_prop_qc.py -- <in.glb> <out_dir> <name> <axis:height|length> <studs> [max_tris=6000] [tex=1024] [yaw=90] [fixblue=0]
# Output frame: front faces Blender +Y = glTF -Z = Roblox -Z (LookVector); up +Z; pivot at base centre; 1 unit = 1 stud.
# Imports a Tripo GLB, joins it into one mesh, (optionally) yaws it, scales so the chosen dimension equals <studs>
# (1 Blender unit = 1 stud), puts the pivot at the base centre, applies transforms, decimates to <= max_tris,
# downsizes the albedo to <= tex px and embeds it, makes the material matte non-metallic, exports <name>.glb,
# re-imports it to verify, renders a 2x2 preview (front, right, back, three-quarter) and writes stats.json.
import bpy, bmesh, sys, os, json, math
import numpy as np
from mathutils import Vector, Matrix

a = sys.argv[sys.argv.index("--") + 1:]
src, out_dir, name, axis, studs = os.path.abspath(a[0]), os.path.abspath(a[1]), a[2], a[3], float(a[4])
kv = dict(x.split("=", 1) for x in a[5:])
max_tris = int(kv.get("max_tris", 6000))
tex_px = int(kv.get("tex", 1024))
yaw = float(kv.get("yaw", 90))      # Tripo default output faces Blender +X; +90 turns the front to +Y (= Roblox -Z)
fixblue = kv.get("fixblue", "0") == "1"
os.makedirs(out_dir, exist_ok=True)
warn = []

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
if not meshes:
    raise SystemExit("QC_FAIL no mesh")
# Bake parent transforms, drop empties, join.
for o in meshes:
    mw = o.matrix_world.copy()
    o.parent = None
    o.matrix_world = mw
for o in list(bpy.context.scene.objects):
    if o.type != "MESH":
        bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
ob = bpy.context.view_layer.objects.active
ob.name = name
ob.data.name = name + "_mesh"
ob.matrix_world = Matrix.Rotation(math.radians(yaw), 4, "Z") @ ob.matrix_world  # importer uses quaternion mode
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def tris(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


orig_tris = tris(ob)
# Clean: merge coincident verts only where UVs allow (merge by distance keeps UV seams split by default in 4.x).
bm = bmesh.new()
bm.from_mesh(ob.data)
loose = [v for v in bm.verts if not v.link_faces]
bmesh.ops.delete(bm, geom=loose, context="VERTS")
bm.to_mesh(ob.data)
bm.free()

if tris(ob) > max_tris:
    m = ob.modifiers.new("dec", "DECIMATE")
    m.decimate_type = "COLLAPSE"
    m.ratio = max(0.05, (max_tris - 50) / float(tris(ob)))
    m.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier="dec")
    warn.append("decimated %d -> %d" % (orig_tris, tris(ob)))

# Scale and pivot.
vs = [ob.matrix_world @ v.co for v in ob.data.vertices]
mn = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
mx = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
d = mx - mn
ref = d.z if axis == "height" else max(d.x, d.y)
s = studs / ref
ob.location = Vector((-(mn.x + mx.x) / 2 * s, -(mn.y + mx.y) / 2 * s, -mn.z * s))
ob.scale = (s, s, s)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
vs = [v.co for v in ob.data.vertices]
mn = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
mx = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
dims = mx - mn

# Base footprint check: share of verts within 2% of the floor (grounded base).
low = [v for v in vs if v.z < mn.z + 0.02 * dims.z]
base_span = (max(v.x for v in low) - min(v.x for v in low), max(v.y for v in low) - min(v.y for v in low)) if low else (0, 0)

# Materials: matte, non-metallic, albedo only, texture downsized.
imgs = []
for slot in ob.material_slots:
    mat = slot.material
    if not mat or not mat.use_nodes:
        continue
    for n in mat.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            n.inputs["Metallic"].default_value = 0.0
            n.inputs["Roughness"].default_value = 0.85
            for k in ("Metallic", "Roughness"):
                for l in list(n.inputs[k].links):
                    mat.node_tree.links.remove(l)
        if n.type == "TEX_IMAGE" and n.image:
            im = n.image
            if max(im.size) > tex_px:
                im.scale(tex_px, tex_px)
            if fixblue:
                px = np.array(im.pixels[:], dtype=np.float32).reshape(im.size[1], im.size[0], 4)
                r, g, b = px[..., 0], px[..., 1], px[..., 2]
                mxc, mnc = px[..., :3].max(-1), px[..., :3].min(-1)
                sat = (mxc - mnc) / np.maximum(mxc, 1e-4)
                # off-palette blue/violet (Tripo fills unseen areas with it); teal (g high) is part of the palette and kept
                bad = (b >= mxc - 1e-4) & (b > g * 1.25) & (b > r * 1.1) & (sat > 0.3) & (mxc > 0.08)
                nbad = int(bad.sum())
                valid = ~bad
                for _ in range(200):
                    if valid.all():
                        break
                    acc = np.zeros_like(px[..., :3]); cnt = np.zeros(bad.shape, np.float32)
                    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        sv = np.roll(valid, (dy, dx), (0, 1)); sp = np.roll(px[..., :3], (dy, dx), (0, 1))
                        acc += sp * sv[..., None]; cnt += sv
                    grow = (~valid) & (cnt > 0)
                    px[..., :3][grow] = acc[grow] / cnt[grow][:, None]
                    valid = valid | grow
                im.pixels = px.flatten().tolist()
                warn.append("fixblue recoloured %d px" % nbad)
            im.pack()
            imgs.append((im.name, list(im.size)))
if not imgs:
    warn.append("NO_TEXTURE")

# Mesh hygiene stats.
bm = bmesh.new()
bm.from_mesh(ob.data)
non_manifold = sum(1 for e in bm.edges if not e.is_manifold)
boundary = sum(1 for e in bm.edges if e.is_boundary)
bm.free()
# Holes: boundary edges left after welding by position (UV seams split verts, so the raw count overstates).
bm = bmesh.new()
bm.from_mesh(ob.data)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0005 * max(dims))
holes = sum(1 for e in bm.edges if e.is_boundary)
bm.free()
has_uv = len(ob.data.uv_layers) > 0
if not has_uv:
    warn.append("NO_UV")

glb = os.path.join(out_dir, name + ".glb")
bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", use_selection=False, export_apply=True,
                          export_image_format="AUTO", export_materials="EXPORT", export_yup=True)

# Preview render (Workbench, texture colour, studio light), 4 views tiled 2x2.
sc = bpy.context.scene
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "STUDIO"
sc.display.shading.color_type = "TEXTURE"
sc.display.shading.show_cavity = True
sc.display.shading.show_shadows = False
sc.display.shading.show_backface_culling = True  # Roblox draws imported meshes single-sided; show holes honestly
sc.render.resolution_x = sc.render.resolution_y = 512
sc.render.film_transparent = False
sc.view_settings.view_transform = "Standard"
w = bpy.data.worlds.new("w")
sc.world = w
cam_d = bpy.data.cameras.new("cam")
cam_d.type = "ORTHO"
cam = bpy.data.objects.new("cam", cam_d)
sc.collection.objects.link(cam)
sc.camera = cam
ctr = Vector((0, 0, dims.z / 2))
rad = max(dims.x, dims.y, dims.z)
cam_d.ortho_scale = rad * 1.25
tiles = []
views = [("front", 0, 8), ("side_+X", 90, 8), ("back_low", 200, -12), ("three_quarter", 35, 25)]
for vname, az, el in views:
    azr, elr = math.radians(az), math.radians(el)
    # Front camera sits on +Y looking back at the prop (the prop faces +Y after the yaw).
    off = Vector((math.sin(azr) * math.cos(elr), math.cos(azr) * math.cos(elr), math.sin(elr))) * rad * 4
    cam.location = ctr + off
    cam.rotation_euler = (ctr - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam_d.clip_end = rad * 10
    p = os.path.join(out_dir, "_view_%s.png" % vname)
    sc.render.filepath = p
    bpy.ops.render.render(write_still=True)
    im = bpy.data.images.load(p)
    px = np.array(im.pixels[:], dtype=np.float32).reshape(512, 512, 4)
    tiles.append(px)
    bpy.data.images.remove(im)
    os.remove(p)
top = np.concatenate([tiles[3], tiles[0]], axis=1)   # numpy rows are bottom-up in Blender images
bot = np.concatenate([tiles[1], tiles[2]], axis=1)
grid = np.concatenate([bot, top], axis=0)            # visual: top row = three_quarter, front; bottom = right, back
out = bpy.data.images.new("preview", 1024, 1024, alpha=True)
out.pixels = grid.flatten().tolist()
out.filepath_raw = os.path.join(out_dir, "preview.png")
out.file_format = "PNG"
out.save()

# Re-import check.
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
ro = [o for o in bpy.context.scene.objects if o.type == "MESH"]
re_tris = sum(tris(o) for o in ro)
re_imgs = [(i.name, list(i.size)) for i in bpy.data.images if i.size[0] > 0]
stats = {"name": name, "src": src, "orig_tris": orig_tris, "tris": re_tris, "dims_studs": [round(dims.x, 3), round(dims.z, 3), round(dims.y, 3)],
         "dims_note": "Roblox order X (width), Y (height), Z (depth)", "scale_applied": s, "yaw_deg": yaw,
         "base_span_studs": [round(base_span[0], 3), round(base_span[1], 3)], "non_manifold_edges": non_manifold,
         "boundary_edges": boundary, "hole_edges_welded": holes, "has_uv": has_uv, "images": re_imgs, "glb_bytes": os.path.getsize(glb), "warnings": warn,
         "qc_ok": re_tris <= max_tris and bool(re_imgs) and has_uv}
json.dump(stats, open(os.path.join(out_dir, "stats.json"), "w"), indent=1)
print("QC_STATS", json.dumps(stats))
print("QC_OK" if stats["qc_ok"] else "QC_CHECK_FAILED")
