"""Renders preview pictures of built cars (top, side, three-quarter views).

    blender -b --python modules/graphics/tools/preview_cars.py -- <out_dir> [car_id ...]

Writes <out_dir>/<id>.png: a 2x2 sheet (top, three-quarter front,
three-quarter rear, side), rendered with Cycles on the CPU.
"""

import bpy
import math
import os
import sys
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
BLEND = os.path.join(os.path.dirname(HERE), "cars_blend")


def look(cam, target):
    d = Vector(target) - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def render_car(cid, out_dir, size):
    bpy.ops.wm.open_mainfile(filepath=os.path.join(BLEND, cid + ".blend"))
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 24
    sc.cycles.use_denoising = True
    sc.render.resolution_x = size
    sc.render.resolution_y = int(size * 0.62)
    sc.view_settings.view_transform = "AgX"
    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    sky = world.node_tree.nodes.new("ShaderNodeTexSky")
    sky.sky_type = "NISHITA" if hasattr(sky, "sky_type") else sky.sky_type
    try:
        sky.sun_elevation = math.radians(50)
        sky.sun_rotation = math.radians(30)
    except Exception:
        pass
    world.node_tree.links.new(sky.outputs[0], bg.inputs[0])
    bg.inputs[1].default_value = 0.18
    sc.world = world
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 4.0
    sun.data.angle = math.radians(3)
    sun.rotation_euler = (math.radians(35), math.radians(15), math.radians(30))
    sc.collection.objects.link(sun)
    # ground
    bpy.ops.mesh.primitive_plane_add(size=40)
    g = bpy.context.object
    gm = bpy.data.materials.new("ground")
    gm.use_nodes = True
    gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.05, 0.05, 0.055, 1)
    gm.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.8
    g.data.materials.append(gm)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    sc.camera = cam
    views = [
        ("top", (0.0, 0.0, 20.0), (0, 0, 0), 22),
        ("front34", (6.5, -5.0, 3.2), (0.2, 0, 0.5), 32),
        ("rear34", (-6.5, 5.0, 3.6), (-0.2, 0, 0.5), 32),
        ("side", (0.0, -11.0, 1.0), (0, 0, 0.6), 30),
    ]
    paths = []
    for name, loc, tgt, lens in views:
        cam.location = loc
        look(cam, tgt)
        if name == "top":
            cam.rotation_euler = (0, 0, math.radians(90))
        cam.data.lens = lens * 2.2 if name != "top" else 70
        p = os.path.join(out_dir, "%s_%s.png" % (cid, name))
        sc.render.filepath = p
        bpy.ops.render.render(write_still=True)
        paths.append(p)
    # 2x2 sheet
    imgs = [bpy.data.images.load(p) for p in paths]
    w, h = imgs[0].size
    sheet = bpy.data.images.new("sheet", w * 2, h * 2, alpha=False)
    px = [0.0] * (w * 2 * h * 2 * 4)
    for k, im in enumerate(imgs):
        src = list(im.pixels)
        ox = (k % 2) * w
        oy = (1 - k // 2) * h
        for y in range(h):
            row = src[y * w * 4:(y + 1) * w * 4]
            start = ((oy + y) * w * 2 + ox) * 4
            px[start:start + w * 4] = row
    sheet.pixels = px
    sheet.filepath_raw = os.path.join(out_dir, cid + ".png")
    sheet.file_format = "PNG"
    sheet.save()
    for p in paths:
        os.remove(p)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    out_dir = argv[0]
    ids = argv[1:] or sorted(f[:-6] for f in os.listdir(BLEND) if f.endswith(".blend"))
    os.makedirs(out_dir, exist_ok=True)
    for cid in ids:
        render_car(cid, out_dir, 640)
        print("[preview] " + cid)


main()
