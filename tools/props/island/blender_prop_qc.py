# SkyRally prop QC + export (Blender 4.3 headless, runs ON THE PC).
# blender -b --factory-startup -P blender_prop_qc.py -- <in.glb> <out_dir> <name> <axis=h|x|y|max> <size_studs> [max_tris=6000] [tex=1024] [yaw_deg=0]
# yaw_deg turns the prop about the up axis so its front faces Blender +Y = glTF -Z = Roblox -Z (the model's LookVector).
# Joins the Tripo meshes, scales so the chosen extent equals size_studs (1 unit = 1 stud), puts the pivot at the base
# centre (min Z = 0, XY centred), applies transforms, decimates only when over max_tris, drops PBR maps (albedo only,
# metallic 0 / roughness 1), downsizes the albedo, exports <name>.glb with the texture embedded (glTF +Y up), renders
# four Workbench views (view_0..3.png; view_3 has a 6.3x2.4x10.5 car-hull box for scale) and writes stats.json.
import bmesh
import bpy
import json
import math
import os
import sys
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
src, out_dir, name, axis, size = argv[0], argv[1], argv[2], argv[3], float(argv[4])
max_tris = int(argv[5]) if len(argv) > 5 else 6000
tex_px = int(argv[6]) if len(argv) > 6 else 1024
yaw_fix = float(argv[7]) if len(argv) > 7 else 0.0
os.makedirs(out_dir, exist_ok=True)
stats = {"name": name, "src": src, "warnings": []}

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
for o in list(bpy.context.scene.objects):
    if o.type != "MESH":
        # keep children world transforms before deleting empties
        pass
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
# clear parents keeping transforms, then join
bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
if len(meshes) > 1:
    bpy.ops.object.join()
obj = bpy.context.view_layer.objects.active
for o in list(bpy.context.scene.objects):
    if o != obj:
        bpy.data.objects.remove(o, do_unlink=True)
obj.name = name
obj.data.name = name + "_mesh"
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
if yaw_fix:
    obj.data.transform(__import__("mathutils").Matrix.Rotation(math.radians(yaw_fix), 4, "Z"))
    obj.data.update()
# weld the glTF seam splits (UVs are per loop in Blender, so nothing is lost) so topology checks mean something
_bm = bmesh.new()
_bm.from_mesh(obj.data)
_before = len(_bm.verts)
bmesh.ops.remove_doubles(_bm, verts=_bm.verts, dist=1e-5)
_bm.to_mesh(obj.data)
_bm.free()
obj.data.update()
stats["welded_verts"] = _before - len(obj.data.vertices)
stats["yaw_fix_deg"] = yaw_fix


def tri_count(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


stats["tris_raw"] = tri_count(obj)
# scale
vs = [v.co for v in obj.data.vertices]
mn = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
mx = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
d = mx - mn
ref = {"h": d.z, "x": d.x, "y": d.y, "max": max(d)}[axis]
k = size / ref
obj.scale = (k, k, k)
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
vs = [v.co for v in obj.data.vertices]
mn = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
mx = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
off = Vector(((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z))
obj.data.transform(__import__("mathutils").Matrix.Translation(-off))
obj.location = (0, 0, 0)
obj.data.update()

# decimate if needed
if tri_count(obj) > max_tris:
    m = obj.modifiers.new("dec", "DECIMATE")
    m.ratio = max_tris / tri_count(obj) * 0.98
    bpy.ops.object.modifier_apply(modifier="dec")
    stats["warnings"].append("decimated")
stats["tris"] = tri_count(obj)

# topology checks
bm = bmesh.new()
bm.from_mesh(obj.data)
bm.edges.ensure_lookup_table()
stats["boundary_edges"] = sum(1 for e in bm.edges if e.is_boundary)
stats["non_manifold_edges"] = sum(1 for e in bm.edges if not e.is_manifold)
stats["edges"] = len(bm.edges)
# islands
seen = set()
islands = 0
for v in bm.verts:
    if v.index in seen:
        continue
    islands += 1
    stack = [v]
    seen.add(v.index)
    while stack:
        x = stack.pop()
        for e in x.link_edges:
            y = e.other_vert(x)
            if y.index not in seen:
                seen.add(y.index)
                stack.append(y)
stats["islands"] = islands
bm.free()

# materials: albedo only
texs = []
for mat in obj.data.materials:
    if not mat or not mat.use_nodes:
        continue
    nt = mat.node_tree
    bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if not bsdf:
        continue
    for inp in ("Metallic", "Roughness", "Normal"):
        for l in list(bsdf.inputs[inp].links):
            nt.links.remove(l)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 1.0
    for n in list(nt.nodes):
        if n.type == "TEX_IMAGE" and not any(l.to_node == bsdf and l.to_socket.name == "Base Color" for l in n.outputs[0].links):
            nt.nodes.remove(n)
    for n in nt.nodes:
        if n.type == "TEX_IMAGE" and n.image:
            im = n.image
            w, h = im.size
            if max(w, h) > tex_px:
                im.scale(tex_px, tex_px)
            im.pack()
            texs.append({"image": im.name, "size": list(im.size)})
stats["textures"] = texs
stats["materials"] = len(obj.data.materials)
if not texs:
    stats["warnings"].append("NO_TEXTURE")
for im in list(bpy.data.images):
    if im.users == 0:
        bpy.data.images.remove(im)

vs = [obj.matrix_world @ v.co for v in obj.data.vertices]
mn = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
mx = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
# Blender (X, Y, Z-up) -> Roblox (X, Y-up, Z): size = (dx, dz, dy)
stats["size_studs"] = [round(mx.x - mn.x, 2), round(mx.z - mn.z, 2), round(mx.y - mn.y, 2)]
stats["bbox_min"] = [round(c, 3) for c in mn]
stats["bbox_max"] = [round(c, 3) for c in mx]

glb = os.path.join(out_dir, name + ".glb")
bpy.ops.object.select_all(action="DESELECT")
obj.select_set(True)
bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", use_selection=True, export_yup=True,
                          export_apply=True, export_image_format="AUTO", export_materials="EXPORT")
stats["glb_bytes"] = os.path.getsize(glb)

# re-import check
bpy.ops.object.select_all(action="DESELECT")
before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=glb)
new = [o for o in bpy.data.objects if o not in before]
stats["reimport_tris"] = sum(tri_count(o) for o in new if o.type == "MESH")
stats["reimport_images"] = len([i for i in bpy.data.images if i.packed_file or i.source == "FILE"])
for o in new:
    bpy.data.objects.remove(o, do_unlink=True)

# renders
scn = bpy.context.scene
scn.render.engine = "BLENDER_WORKBENCH"
scn.display.shading.light = "STUDIO"
scn.display.shading.color_type = "TEXTURE"
scn.display.shading.show_cavity = True
scn.display.shading.show_object_outline = True
scn.render.resolution_x = 640
scn.render.resolution_y = 640
scn.render.film_transparent = False
world = bpy.data.worlds.new("w")
scn.world = world
world.color = (0.82, 0.84, 0.86)
cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam = bpy.data.objects.new("cam", cam_data)
scn.collection.objects.link(cam)
scn.camera = cam
ext = mx - mn
centre = (mn + mx) / 2
radius = max(ext) * 0.5
views = [(180, 12), (90, 12), (0, 12), (215, 28)]  # camera yaw deg about Z (180 = from +Y = prop front), elevation deg
for i, (yaw, elev) in enumerate(views):
    box = None
    if i == 3:
        bm2 = bpy.data.meshes.new("car")
        box = bpy.data.objects.new("carhull", bm2)
        scn.collection.objects.link(box)
        b = bmesh.new()
        bmesh.ops.create_cube(b, size=1.0)
        b.to_mesh(bm2)
        b.free()
        box.scale = (6.3, 10.5, 2.4)
        box.location = (mn.x - 4.0 - 3.15, centre.y, 1.2)
        box.color = (0.25, 0.4, 0.9, 1)
    pad = 1.25
    if box:
        lo = Vector((min(mn.x, box.location.x - 3.15), min(mn.y, centre.y - 5.25), 0))
        hi = Vector((max(mx.x, box.location.x + 3.15), max(mx.y, centre.y + 5.25), max(mx.z, 2.4)))
        c = (lo + hi) / 2
        r = max(hi - lo) * 0.5
    else:
        c, r = centre, radius
    yr, er = math.radians(yaw), math.radians(elev)
    dirv = Vector((math.sin(yr) * math.cos(er), -math.cos(yr) * math.cos(er), math.sin(er)))
    cam.location = c + dirv * (r * 6 + 10)
    cam.rotation_euler = (-dirv).to_track_quat("-Z", "Y").to_euler()
    cam_data.ortho_scale = r * 2 * pad
    cam_data.clip_end = r * 20 + 100
    scn.render.filepath = os.path.join(out_dir, "view_%d.png" % i)
    bpy.ops.render.render(write_still=True)
    if box:
        bpy.data.objects.remove(box, do_unlink=True)

json.dump(stats, open(os.path.join(out_dir, "stats.json"), "w"), indent=1)
print("PROP_QC_OK", json.dumps(stats))
