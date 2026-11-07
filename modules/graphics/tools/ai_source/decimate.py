"""Keeps the biggest piece of an AI mesh and decimates it to ~220k triangles.

    blender -b --python decimate.py -- <in.glb> <out.glb> [keep=0.0]

keep > 0 also keeps every other piece with at least that share of the
biggest piece's triangles (an AI shell can come out in a few big pieces,
e.g. a prototype's front wheel arches split from the tub).
"""
import bpy, sys
args = sys.argv[sys.argv.index("--") + 1:]
src, dst = args[:2]
keep = float(args[2]) if len(args) > 2 else 0.0
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
nb = len(big.data.polygons)
kept = [o for o in ms if o == big or (keep > 0 and len(o.data.polygons) >= keep * nb)]
print("pieces kept", sorted((len(o.data.polygons) for o in kept), reverse=True)[:12])
for o in ms:
    if o not in kept: bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.object.select_all(action="DESELECT")
for o in kept: o.select_set(True)
bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB", use_selection=True, export_yup=True, export_materials="NONE", export_normals=False, export_texcoords=False)
print("pieces", len(ms), "kept", len(kept), "faces", sum(len(o.data.polygons) for o in kept))
