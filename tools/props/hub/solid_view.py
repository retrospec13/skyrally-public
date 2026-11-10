# Untextured single-sided (backface-culled) ortho render of a GLB, to find see-through holes the texture hides.
# blender -b --factory-startup -P solid_view.py -- <in.glb> <out.png> <azimuth_deg> <elevation_deg>
import bpy, sys, math, os
from mathutils import Vector
a = sys.argv[sys.argv.index("--") + 1:]
glb, out = os.path.abspath(a[0]), os.path.abspath(a[1])
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)
sc = bpy.context.scene
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "STUDIO"
sc.display.shading.color_type = "SINGLE"
sc.display.shading.show_backface_culling = True
sc.render.resolution_x = sc.render.resolution_y = 768
cd = bpy.data.cameras.new("c"); cd.type = "ORTHO"
cam = bpy.data.objects.new("c", cd); sc.collection.objects.link(cam); sc.camera = cam
vs = [o.matrix_world @ v.co for o in sc.objects if o.type == "MESH" for v in o.data.vertices]
mx = max(max(abs(v.x), abs(v.y), v.z) for v in vs)
ctr = Vector((0, 0, max(v.z for v in vs) / 2)); cd.ortho_scale = mx * 1.6
azr, elr = math.radians(float(a[2])), math.radians(float(a[3]))
cam.location = ctr + Vector((math.sin(azr) * math.cos(elr), math.cos(azr) * math.cos(elr), math.sin(elr))) * mx * 5
cam.rotation_euler = (ctr - cam.location).to_track_quat("-Z", "Y").to_euler(); cd.clip_end = mx * 20
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
