# SkyRally prop QC + export (Blender 4.3 headless, runs ON THE PC).
# blender -b --factory-startup -P blender_prop_qc.py -- <in.glb> <out_dir> <name> <axis:x|y|z|max> <size_studs> [max_tris=6000] [yaw_deg=0] [tex=1024]
# Joins the Tripo meshes, rotates by yaw, scales uniformly so the chosen axis measures size_studs (1 unit = 1 stud),
# puts the pivot at the base centre (min Z = 0, XY bbox centre = 0), applies transforms, keeps <= max_tris (planar then
# collapse decimate only if over), flattens materials to an unlit-safe albedo (base colour texture only, metallic 0,
# roughness 0.85, no normal/MR maps), downsizes the albedo to tex px, exports a GLB with the texture embedded, and
# renders a labelled 2x2 preview (front, right, back, three-quarter top) with a 1-stud-grid ground plane.
import bpy, bmesh, sys, os, json, math
from mathutils import Vector, Matrix

a = sys.argv[sys.argv.index("--") + 1:]
src, out_dir, name, axis, size = os.path.abspath(a[0]), os.path.abspath(a[1]), a[2], a[3], float(a[4])
max_tris = int(a[5]) if len(a) > 5 else 6000
yaw = float(a[6]) if len(a) > 6 else 0.0
texpx = int(a[7]) if len(a) > 7 else 1024
os.makedirs(out_dir, exist_ok=True)
stats = {"name": name, "src": src, "warnings": []}

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
stats["src_meshes"] = len(meshes)
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
ob = bpy.context.view_layer.objects.active
# unparent (keep world transform) and drop empties
bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
for o in list(bpy.context.scene.objects):
    if o.type != "MESH":
        bpy.data.objects.remove(o, do_unlink=True)
ob.name = name
ob.data.name = name
bpy.ops.object.select_all(action="DESELECT")
ob.select_set(True)
bpy.context.view_layer.objects.active = ob
ob.rotation_mode = "XYZ"
ob.rotation_euler.z += math.radians(yaw)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def tri_count(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


def bbox(o):
    vs = [v.co for v in o.data.vertices]
    mn = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
    mx = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
    return mn, mx


stats["src_tris"] = tri_count(ob)
mn, mx = bbox(ob)
d = mx - mn
ref = {"x": d.x, "y": d.y, "z": d.z, "max": max(d)}[axis]
s = size / ref
ob.data.transform(Matrix.Translation(Vector((-(mn.x + mx.x) / 2, -(mn.y + mx.y) / 2, -mn.z))))
ob.data.transform(Matrix.Scale(s, 4))
ob.data.update()

# triangulate (Roblox triangulates anyway; the count we report is the real one)
# weld the glTF seam splits first (UVs are per face corner in Blender, so welding keeps them) so a decimate can
# never tear the surface open along UV seams
bm = bmesh.new()
bm.from_mesh(ob.data)
bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-5)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
bm.to_mesh(ob.data)
bm.free()
if tri_count(ob) > max_tris:
    if ob.data.has_custom_normals:
        bpy.ops.mesh.customdata_custom_splitnormals_clear()
    m = ob.modifiers.new("dec", "DECIMATE")
    m.decimate_type = "COLLAPSE"
    m.ratio = max_tris / tri_count(ob) * 0.98
    m.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=m.name)
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(40))
    stats["warnings"].append("collapse-decimated to fit max_tris (seams welded first)")
stats["tris"] = tri_count(ob)

# topology checks
bm = bmesh.new()
bm.from_mesh(ob.data)
bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)  # glTF splits vertices on UV seams; weld for the check only
bm.verts.ensure_lookup_table()
stats["non_manifold_edges"] = sum(1 for e in bm.edges if not e.is_manifold)
stats["boundary_edges"] = sum(1 for e in bm.edges if e.is_boundary)
stats["edges"] = len(bm.edges)
# islands
seen = set(); islands = 0
for v in bm.verts:
    if v.index in seen:
        continue
    islands += 1
    stack = [v]
    while stack:
        x = stack.pop()
        if x.index in seen:
            continue
        seen.add(x.index)
        stack.extend(e.other_vert(x) for e in x.link_edges if e.other_vert(x).index not in seen)
stats["islands"] = islands
bm.free()
stats["uv_layers"] = len(ob.data.uv_layers)
mn, mx = bbox(ob)
d = mx - mn
stats["size_studs"] = [round(d.x, 3), round(d.z, 3), round(d.y, 3)]  # Roblox X, Y(up), Z
stats["blender_dims_xyz"] = [round(d.x, 3), round(d.y, 3), round(d.z, 3)]
stats["base_min_z"] = round(mn.z, 4)

# flatten materials to albedo-only
tex_imgs = []
for slot in ob.material_slots:
    mat = slot.material
    if not mat or not mat.use_nodes:
        continue
    nt = mat.node_tree
    bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if not bsdf:
        continue
    base_img = None
    lk = bsdf.inputs["Base Color"].links
    if lk:
        n = lk[0].from_node
        if n.type == "TEX_IMAGE":
            base_img = n.image
    for inp in ("Metallic", "Roughness", "Normal", "Emission Color", "Emission Strength", "Alpha"):
        for l in list(bsdf.inputs[inp].links):
            nt.links.remove(l)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.85
    bsdf.inputs["Alpha"].default_value = 1.0
    for n in list(nt.nodes):
        if n.type == "TEX_IMAGE" and n.image is not base_img:
            nt.nodes.remove(n)
    mat.blend_method = "OPAQUE" if hasattr(mat, "blend_method") else None
    if base_img:
        if max(base_img.size) > texpx:
            base_img.scale(texpx, texpx)
        base_img.file_format = "PNG"
        tex_imgs.append({"mat": mat.name, "img": base_img.name, "px": list(base_img.size)})
stats["materials"] = len(ob.material_slots)
stats["albedo"] = tex_imgs
if not tex_imgs:
    stats["warnings"].append("NO ALBEDO TEXTURE")

for img in list(bpy.data.images):
    if img.users == 0:
        bpy.data.images.remove(img)

glb = os.path.join(out_dir, name + ".glb")
bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", use_selection=True, export_apply=True,
                          export_image_format="JPEG", export_jpeg_quality=92, export_yup=True)
stats["glb"] = glb
stats["glb_bytes"] = os.path.getsize(glb)

# re-import check
bpy.ops.object.select_all(action="DESELECT")
pre = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=glb)
new = [o for o in bpy.data.objects if o not in pre and o.type == "MESH"]
stats["reimport"] = {"meshes": len(new), "tris": sum(tri_count(o) for o in new),
                     "images": len([i for i in bpy.data.images if i.packed_file or i.source == "FILE"])}
for o in new:
    bpy.data.objects.remove(o, do_unlink=True)

# preview renders
sc = bpy.context.scene
sc.render.engine = "BLENDER_EEVEE_NEXT"
sc.eevee.taa_render_samples = 16
sc.render.resolution_x = sc.render.resolution_y = 512
sc.view_settings.view_transform = "Standard"
world = bpy.data.worlds.new("w"); sc.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.78, 0.8, 0.84, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 3.0
sun.rotation_euler = (math.radians(50), 0, math.radians(35))
sc.collection.objects.link(sun)
# ground with 1-stud checker for scale
R = max(d.x, d.y) * 1.6 + 4
bpy.ops.mesh.primitive_plane_add(size=1, location=(0, 0, -0.01))
gp = bpy.context.active_object
gp.scale = (R, R, 1)
gm = bpy.data.materials.new("ground"); gm.use_nodes = True
nt = gm.node_tree
chk = nt.nodes.new("ShaderNodeTexChecker"); chk.inputs["Scale"].default_value = R
chk.inputs["Color1"].default_value = (0.55, 0.55, 0.6, 1); chk.inputs["Color2"].default_value = (0.62, 0.62, 0.67, 1)
tc = nt.nodes.new("ShaderNodeTexCoord")
nt.links.new(tc.outputs["UV"], chk.inputs["Vector"])
nt.links.new(chk.outputs["Color"], nt.nodes["Principled BSDF"].inputs["Base Color"])
gp.data.materials.append(gm)
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
sc.collection.objects.link(cam); sc.camera = cam
cam.data.type = "ORTHO"
ext = max(d.x, d.y, d.z)
cam.data.ortho_scale = ext * 1.35
ctr = Vector((0, 0, d.z / 2))
views = [("front", 0, 8), ("right", 90, 8), ("back", 180, 8), ("3q_top", 35, 35)]
paths = []
for label, az, el in views:
    azr, elr = math.radians(az), math.radians(el)
    dist = ext * 4
    cam.location = ctr + Vector((math.sin(azr) * math.cos(elr) * dist, -math.cos(azr) * math.cos(elr) * dist, math.sin(elr) * dist))
    cam.rotation_euler = (ctr - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.ortho_scale = ext * (1.6 if el > 20 else 1.35)
    p = os.path.join(out_dir, "_view_%s.png" % label)
    sc.render.filepath = p
    bpy.ops.render.render(write_still=True)
    paths.append(p)
# stitch 2x2 with numpy
import numpy as np
tiles = []
for p in paths:
    im = bpy.data.images.load(p)
    arr = np.array(im.pixels[:], dtype=np.float32).reshape(im.size[1], im.size[0], 4)
    tiles.append(arr)
    bpy.data.images.remove(im)
# pixel rows are bottom-up: top row of sheet = tiles 0,1
top = np.concatenate([tiles[0], tiles[1]], axis=1)
bot = np.concatenate([tiles[2], tiles[3]], axis=1)
sheet = np.concatenate([bot, top], axis=0)
h, w = sheet.shape[:2]
out = bpy.data.images.new("preview", w, h)
out.pixels = sheet.ravel()
out.filepath_raw = os.path.join(out_dir, "preview.png")
out.file_format = "PNG"
out.save()
for p in paths:
    os.remove(p)
json.dump(stats, open(os.path.join(out_dir, "qc.json"), "w"), indent=1)
print("QC_JSON", json.dumps(stats))
print("PROP_QC_OK")
