"""Keeps the biggest piece of an AI mesh and decimates it to ~220k triangles.

    blender -b --python decimate.py -- <in.glb> <out.glb>
"""
import bpy, sys
src, dst = sys.argv[sys.argv.index("--") + 1:][:2]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
ob = [o for o in bpy.data.objects if o.type == "MESH"][0]
bpy.context.view_layer.objects.active = ob; ob.select_set(True)
n = len(ob.data.polygons)
d = ob.modifiers.new("d", "DECIMATE"); d.ratio = min(1.0, 220000 / n)
bpy.ops.object.modifier_apply(modifier="d")
bpy.ops.object.mode_set(mode="EDIT"); bpy.ops.mesh.separate(type="LOOSE"); bpy.ops.object.mode_set(mode="OBJECT")
ms = [o for o in bpy.data.objects if o.type == "MESH"]
big = max(ms, key=lambda o: len(o.data.polygons))
for o in ms:
    if o != big: bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.object.select_all(action="DESELECT"); big.select_set(True)
bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB", use_selection=True, export_yup=True, export_materials="NONE", export_normals=False, export_texcoords=False)
print("pieces", len(ms), "faces", len(big.data.polygons))
