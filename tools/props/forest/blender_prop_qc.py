# SkyRally prop QC + export (Blender 4.3 headless). 1 Blender unit = 1 stud.
# blender -b --factory-startup -P blender_prop_qc.py -- <in.glb> <out_dir> <name> <axis> <target_studs> [max_tris=6000] [tex=1024] [yaw_deg=0]
#   axis: "z" scales so height == target, "xy" scales so the longest horizontal side == target, "max" the longest side.
# Output: <out_dir>/<name>.glb (single mesh, pivot at base centre, transforms applied, albedo-only material, embedded
# texture), views/*.png + preview.png (4-view sheet: front, right, back, three-quarter), stats.json. Prints QC_OK.
import json
import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT, NAME, AXIS, TARGET = os.path.abspath(argv[0]), os.path.abspath(argv[1]), argv[2], argv[3], float(argv[4])
MAX_TRIS = int(argv[5]) if len(argv) > 5 else 6000
TEX = int(argv[6]) if len(argv) > 6 else 1024
YAW = float(argv[7]) if len(argv) > 7 else 0.0
os.makedirs(os.path.join(OUT, "views"), exist_ok=True)
STATS = {"name": NAME, "source": SRC, "warnings": []}

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
STATS["source_mesh_objects"] = len(meshes)
# bake every parent/child transform into the meshes, drop empties
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
ob.name = NAME
ob.data.name = NAME
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
if YAW:
    from mathutils import Matrix
    ob.data.transform(Matrix.Rotation(math.radians(YAW), 4, "Z"))
    ob.data.update()


def tri_count(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


STATS["tris_source"] = tri_count(ob)
# mesh health before any reduction
bm = bmesh.new()
bm.from_mesh(ob.data)
_d = max(ob.dimensions) * 1e-4
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=_d)
STATS["welded_boundary_edges"] = sum(1 for e in bm.edges if e.is_boundary)
STATS["welded_nonmanifold_edges"] = sum(1 for e in bm.edges if not e.is_manifold)
_seen, _parts = set(), 0
for v in bm.verts:
    if v.index in _seen:
        continue
    _parts += 1
    stack = [v]
    _seen.add(v.index)
    while stack:
        x = stack.pop()
        for e in x.link_edges:
            y = e.other_vert(x)
            if y.index not in _seen:
                _seen.add(y.index)
                stack.append(y)
STATS["loose_parts"] = _parts
bm.free()
if tri_count(ob) > MAX_TRIS:
    m = ob.modifiers.new("dec", "DECIMATE")
    m.decimate_type = "COLLAPSE"
    m.ratio = (MAX_TRIS - 150) / tri_count(ob)
    m.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier="dec")
    STATS["warnings"].append("decimated %d -> %d" % (STATS["tris_source"], tri_count(ob)))
# triangulate so the count is exact and the exporter does not change it
m = ob.modifiers.new("tri", "TRIANGULATE")
bpy.ops.object.modifier_apply(modifier="tri")
TRIS = tri_count(ob)

# scale to studs, pivot at base centre
co = np.empty(len(ob.data.vertices) * 3, np.float32)
ob.data.vertices.foreach_get("co", co)
co = co.reshape(-1, 3)
mn, mx = co.min(0), co.max(0)
dims = mx - mn
ref = {"z": dims[2], "xy": max(dims[0], dims[1]), "max": dims.max()}[AXIS]
s = TARGET / float(ref)
co = (co - np.array([(mn[0] + mx[0]) / 2, (mn[1] + mx[1]) / 2, mn[2]])) * s
ob.data.vertices.foreach_set("co", co.ravel())
ob.data.update()
mn, mx = co.min(0), co.max(0)
STATS["scale_factor"] = s
STATS["size_blender_xyz"] = [round(float(v), 3) for v in (mx - mn)]
# Roblox (Y up): X = Blender X, Y = Blender Z, Z = Blender Y depth
STATS["size_studs_roblox"] = [round(float(mx[0] - mn[0]), 2), round(float(mx[2] - mn[2]), 2), round(float(mx[1] - mn[1]), 2)]
STATS["tris"] = TRIS

# albedo-only materials: keep Base Color texture, drop normal/metal-rough/emission links, matte
imgs = set()
for mat in ob.data.materials:
    if not mat or not mat.use_nodes:
        continue
    nt = mat.node_tree
    bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if not bsdf:
        STATS["warnings"].append("material %s has no principled BSDF" % mat.name)
        continue
    for inp in bsdf.inputs:
        if inp.name != "Base Color" and inp.is_linked:
            for l in list(inp.links):
                nt.links.remove(l)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.85
    keep = set()
    stack = [bsdf.inputs["Base Color"]]
    while stack:
        sock = stack.pop()
        for l in sock.links:
            n = l.from_node
            if n.name in keep:
                continue
            keep.add(n.name)
            stack.extend(i for i in n.inputs if i.is_linked)
    for n in list(nt.nodes):
        if n.type == "TEX_IMAGE":
            if n.name not in keep:
                nt.nodes.remove(n)
            elif n.image:
                imgs.add(n.image)
    if bsdf.inputs["Base Color"].is_linked is False:
        STATS["warnings"].append("material %s has no base color texture" % mat.name)
STATS["materials"] = len(ob.data.materials)
STATS["textures"] = []
for im in imgs:
    w, h = im.size
    if max(w, h) > TEX:
        im.scale(TEX, TEX)
    im.pack()
    STATS["textures"].append({"name": im.name, "size": list(im.size)})
if not imgs:
    STATS["warnings"].append("NO TEXTURE")

# texture variance sanity (untextured / blank check)
for im in imgs:
    px = np.empty(im.size[0] * im.size[1] * 4, np.float32)
    im.pixels.foreach_get(px)
    px = px.reshape(-1, 4)[:, :3]
    STATS.setdefault("texture_std", []).append(round(float(px.std()), 4))

# export
glb = os.path.join(OUT, NAME + ".glb")
bpy.ops.object.select_all(action="DESELECT")
ob.select_set(True)
bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", use_selection=True, export_apply=True,
                          export_image_format="JPEG", export_jpeg_quality=92, export_materials="EXPORT",
                          export_yup=True, export_texcoords=True, export_normals=True)
STATS["glb_bytes"] = os.path.getsize(glb)

# renders: workbench textured, perspective
scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
sh = scene.display.shading
sh.light = "STUDIO"
sh.color_type = "TEXTURE"
sh.show_specular_highlight = False
sh.show_cavity = True
sh.cavity_type = "WORLD"
scene.render.resolution_x = scene.render.resolution_y = 640
scene.render.film_transparent = False
scene.render.image_settings.file_format = "PNG"
scene.view_settings.view_transform = "Standard"
world = bpy.data.worlds.new("Grey")
world.color = (0.55, 0.57, 0.6)
scene.world = world
# ground disc for grounding read
bpy.ops.mesh.primitive_circle_add(vertices=64, radius=float(max(mx - mn)) * 0.9, fill_type="NGON", location=(0, 0, -0.01))
ground = bpy.context.active_object
gm = bpy.data.materials.new("ground")
gm.diffuse_color = (0.32, 0.34, 0.36, 1)
ground.data.materials.append(gm)
cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
scene.collection.objects.link(cam)
scene.camera = cam
cam.data.lens = 50
CEN = Vector((0, 0, float(mx[2]) * 0.45))
RAD = float(np.linalg.norm(mx - mn))
VIEWS = [("front", Vector((0, -1, 0.18))), ("right", Vector((1, 0, 0.18))), ("back", Vector((0, 1, 0.18))),
         ("threequarter", Vector((-1, -1.1, 0.8)))]
paths = []
for vname, d in VIEWS:
    d = d.normalized()
    cam.location = CEN + d * RAD * 1.55
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    cam.data.clip_start = 0.01
    cam.data.clip_end = RAD * 10
    p = os.path.join(OUT, "views", "%s.png" % vname)
    scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    paths.append(p)
tiles = []
for p in paths:
    im = bpy.data.images.load(p, check_existing=False)
    w, h = im.size
    a = np.empty(w * h * 4, np.float32)
    im.pixels.foreach_get(a)
    tiles.append(a.reshape(h, w, 4)[::-1])
    bpy.data.images.remove(im)
h, w = tiles[0].shape[:2]
S = np.ones((2 * h, 2 * w, 4), np.float32)
for i, t in enumerate(tiles):
    r, c = divmod(i, 2)
    S[r * h:(r + 1) * h, c * w:(c + 1) * w] = t
S[h - 1:h + 1, :, :3] = 0.1
S[:, w - 1:w + 1, :3] = 0.1
img = bpy.data.images.new("sheet", 2 * w, 2 * h, alpha=True)
img.pixels.foreach_set(S[::-1].ravel())
img.filepath_raw = os.path.join(OUT, "preview.png")
img.file_format = "PNG"
img.save()
json.dump(STATS, open(os.path.join(OUT, "stats.json"), "w"), indent=1)
print("QC_OK", json.dumps(STATS))
