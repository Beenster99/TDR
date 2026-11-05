"""Swaps a built car's body for one made from an AI-generated mesh.

Used by build_cars.py when a car's shape file has an "ai_body" block:

    "ai_body": {
      "source": "porsche_911_gt3_r.glb",      # in tools/ai_source/, glTF space (Y up)
      "flip": false,                          # true if the source faces backwards
      "wing_cut": [[-0.25, 1.24], [-1.35, 0.96], [-2.2, 0.96]],   # [x, z] car space:
                                              # behind x[0], anything above this line
                                              # (+ 3 cm) is the AI's own wing: removed
      "glass": [...regions...], "lights": [...regions...]
    }

The source mesh came from an AI image-to-3D model (Hunyuan3D 2.1) fed one
freely licensed photo; see tools/ai_source/README.md. It is one fused
shell, so this script:

  1. scales it to the car's real length (uniformly) and centres it on the
     simulated axles (the wheels line up with the physics),
  2. cuts away the AI's wing (we fit our own, with its upgrade versions),
     its fused wheels (we fit our own spinning wheels) and fills the holes,
  3. smooths the lumps out and decimates it to a game budget,
  4. paints glass, lights and grilles by region and puts a dark interior
     under tinted glass (the shell has no inside to see through to),
  5. splits it into the parts the game expects: body, bumper_front,
     bumper_rear, cabin (glass) and the two mirrors.

Our own splitter, diffuser, wing, upgrade parts, wheels and number markers
from the normal build stay. The interior box is dropped.
"""

import bpy
import bmesh
import math
import os
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "ai_source")


def _line(pts, x):
    """Piecewise-linear z(x) through [x, z] points (x descending)."""
    if x >= pts[0][0]:
        return None
    for (x0, z0), (x1, z1) in zip(pts, pts[1:]):
        if x1 <= x <= x0:
            k = (x0 - x) / max(x0 - x1, 1e-6)
            return z0 + (z1 - z0) * k
    return pts[-1][1]


def _in_poly(pts, a, b):
    inside = False
    for (a0, b0), (a1, b1) in zip(pts, pts[1:] + pts[:1]):
        if (b0 > b) != (b1 > b) and a < a0 + (b - b0) * (a1 - a0) / (b1 - b0):
            inside = not inside
    return inside


def _in_region(r, c, n):
    """Region test in car space. Keys: x, y (|y| unless mirror false), z ranges,
    'ellipse' (x/y ellipse), 'poly_xz' (a side-view outline, [[x, z], ...]), 'face' (top/side/front/rear, with a normal limit)."""
    y = abs(c.y) if r.get("mirror", True) else c.y
    xs, ys, zs = r.get("x", [-9, 9]), r.get("y", [-9, 9]), r.get("z", [-9, 9])
    face = r.get("face")
    lim = r.get("n", 0.4)
    if face == "top" and n.z < lim:
        return False
    if face == "side" and abs(n.y) < lim:
        return False
    if face == "front" and n.x < lim:
        return False
    if face == "rear" and n.x > -lim:
        return False
    if not (zs[0] <= c.z <= zs[1]):
        return False
    if "poly_xz" in r and not _in_poly(r["poly_xz"], c.x, c.z):
        return False
    if "poly_xz" in r:
        return xs[0] <= c.x <= xs[1] and ys[0] <= y <= ys[1]
    if r.get("ellipse"):
        cx, cy = (xs[0] + xs[1]) * 0.5, (ys[0] + ys[1]) * 0.5
        dx = (c.x - cx) / max((xs[1] - xs[0]) * 0.5, 1e-4)
        dy = (y - cy) / max((ys[1] - ys[0]) * 0.5, 1e-4)
        return dx * dx + dy * dy <= 1.0
    return xs[0] <= c.x <= xs[1] and ys[0] <= y <= ys[1]


def _mat(name):
    return bpy.data.materials.get(name)


def replace(car, cfg):
    MATS = bpy.data.materials
    # Drop the parts the AI shell replaces.
    for n in ("body", "bumper_front", "bumper_rear", "cabin", "interior", "mirror_l", "mirror_r"):
        ob = bpy.data.objects.get(n)
        if ob:
            for ch in list(ob.children_recursive):
                bpy.data.objects.remove(ch, do_unlink=True)
            bpy.data.objects.remove(ob, do_unlink=True)
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, cfg["source"]))
    new = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in new if o.type == "MESH"]
    for o in bpy.data.objects:
        o.select_set(False)
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    for o in new:
        if o != ob and o.name in bpy.data.objects:
            bpy.data.objects.remove(o, do_unlink=True)
    ob.parent = None
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    me = ob.data

    # 1. Car space: long axis to x, nose at +x, uniform scale to the real length.
    vs = [v.co.copy() for v in me.vertices]
    ext = [max(v[i] for v in vs) - min(v[i] for v in vs) for i in range(3)]
    mn = [min(v[i] for v in vs) for i in range(3)]
    mx = [max(v[i] for v in vs) for i in range(3)]
    la = 0 if ext[0] > ext[1] else 1
    k = car.L / ext[la]
    for v in me.vertices:
        c = v.co
        u = (c[la] - mn[la]) / ext[la]
        if cfg.get("flip"):
            u = 1.0 - u
        w = c[1 - la] - (mn[1 - la] + mx[1 - la]) * 0.5
        v.co = Vector((car.x_rear + u * car.L, w * k, (c[2] - mn[2]) * k))
    # Optional: stretch width and height to the real car (an AI shell made
    # from a three-quarter photo is often a little too wide or tall). Width
    # is measured at the 99th percentile so the mirrors don't count.
    sy = sz = 1.0
    if cfg.get("fit_width"):
        ys = sorted(abs(v.co.y) for v in me.vertices)
        sy = car.W * 0.5 / max(ys[int(len(ys) * 0.99)], 1e-4)
    if cfg.get("height"):
        cut0 = cfg["wing_cut"][0][0] if cfg.get("wing_cut") else -99.0   # the AI's wing doesn't count
        sz = cfg["height"] / max(v.co.z for v in me.vertices if v.co.x > cut0)
    if sy != 1.0 or sz != 1.0:
        for v in me.vertices:
            v.co = Vector((v.co.x, v.co.y * sy, v.co.z * sz))
    me.update()

    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

    # 2. Cut away the AI's wing and its fused wheels.
    cut = cfg.get("wing_cut")
    R = car.R
    dead = []
    for f in bm.faces:
        c = f.calc_center_median()
        if cut:
            zl = _line(cut, c.x)
            if zl is not None and c.z > zl + 0.03:
                dead.append(f)
                continue
        if c.z < cfg.get("floor_cut", 0.06) and all(abs(c.x - ax) > R + 0.05 for ax in car.axles):
            dead.append(f)     # ragged skirt left where the source sat on the floor
            continue
        ac = cfg.get("arch_clear", 0.0)     # also clear the AI's tyre sidewalls below the hub
        if ac and any(abs(c.x - ax) < R + ac and c.z < R * 1.05 and abs(c.y) > car.track * 0.5 - cfg.get("wheel_cut_inner", 0.2)
                      for ax in car.axles):
            dead.append(f)
            continue
        for ax in car.axles:
            if math.hypot(c.x - ax, c.z - R) < R + cfg.get("wheel_cut_margin", 0.02) and abs(c.y) > car.track * 0.5 - cfg.get("wheel_cut_inner", 0.2):
                dead.append(f)
                break
    bmesh.ops.delete(bm, geom=dead, context="FACES")
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context="VERTS")
    # Fill the small holes the wing left (not the big wheel openings).
    edges = [e for e in bm.edges if e.is_boundary]
    bmesh.ops.holes_fill(bm, edges=edges, sides=cfg.get("fill_sides", 80))
    bmesh.ops.triangulate(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()

    # 3. Smooth and decimate.
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    sm = ob.modifiers.new("smooth", "SMOOTH")
    sm.factor = cfg.get("smooth", 0.5)
    sm.iterations = cfg.get("smooth_iter", 8)
    bpy.ops.object.modifier_apply(modifier=sm.name)

    dec = ob.modifiers.new("dec", "DECIMATE")
    dec.ratio = cfg.get("decimate", 0.25)
    bpy.ops.object.modifier_apply(modifier=dec.name)

    # 4. Paint regions. First cut clean edges along each region's straight
    # borders (bisect), so glass edges are lines, not the jagged triangles.
    me.materials.clear()
    names = ["paint", "interior", "light_head", "light_tail", "grille", "carbon"]
    for n in names:
        me.materials.append(MATS[n])
    idx = {n: i for i, n in enumerate(names)}
    bm = bmesh.new()
    bm.from_mesh(me)
    planes = []
    for r in cfg.get("regions", []):
        if r.get("ellipse"):
            continue
        if "poly_xz" in r:
            pts = r["poly_xz"]
            for (x0, z0), (x1, z1) in zip(pts, pts[1:] + pts[:1]):
                d = Vector((x1 - x0, 0, z1 - z0)).normalized()
                planes.append((Vector((x0, 0, z0)), Vector((d.z, 0, -d.x))))
        for i, key in ((0, "x"), (1, "y")):
            if key in r:
                for v in r[key]:
                    if abs(v) < 5 and not (key == "y" and v == 0):
                        nrm = Vector((1, 0, 0)) if i == 0 else Vector((0, 1, 0))
                        co = nrm * v
                        planes.append((co, nrm))
                        if key == "y" and r.get("mirror", True):
                            planes.append((-co, nrm))
        if "z" in r:
            for v in r["z"]:
                planes.append((Vector((0, 0, v)), Vector((0, 0, 1))))
    for co, nrm in planes:
        geom = [f for f in bm.faces if f.calc_center_median().z > cfg.get("cut_above", 0.0)]
        geom = list(set(geom)) + list({e for f in geom for e in f.edges}) + list({v for f in geom for v in f.verts})
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=co, plane_no=nrm, dist=0.002)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    bm.normal_update()
    for f in bm.faces:
        c, n = f.calc_center_median(), f.normal
        m = "paint"
        for r in cfg.get("regions", []):
            if _in_region(r, c, n):
                m = r["mat"]
                break
        if m == "glass":
            m = "interior"
        f.material_index = idx[m]
    bm.to_mesh(me)
    bm.free()

    # 5. Split into parts. Glass: a copy of the dark faces, pushed out 4 mm.
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.normal_update()
    gl = bmesh.new()
    gvi = {}
    for f in bm.faces:
        if f.material_index != idx["interior"]:
            continue
        vs = []
        for v in f.verts:
            if v.index not in gvi:
                gvi[v.index] = gl.verts.new(v.co + v.normal * 0.004)
            vs.append(gvi[v.index])
        try:
            gl.faces.new(vs)
        except ValueError:
            pass
    bm.free()
    gme = bpy.data.meshes.new("cabin")
    gl.to_mesh(gme)
    gl.free()
    gme.materials.append(MATS["glass"])
    cab = bpy.data.objects.new("cabin", gme)
    bpy.context.scene.collection.objects.link(cab)

    xf, xr = car.x_front, car.x_rear
    cuts = cfg.get("bumper_cuts", [0.12, 0.92])
    x_fb = xf - cuts[0] * car.L
    x_rb = xf - cuts[1] * car.L
    mir = cfg.get("mirror", {"x": [0.6, 1.05], "y": [0.86, 1.2], "z": [0.85, 1.15]})

    def part_of(c):
        if mir["x"][0] <= c.x <= mir["x"][1] and abs(c.y) >= mir["y"][0] and mir["z"][0] <= c.z <= mir["z"][1]:
            return "mirror_l" if c.y > 0 else "mirror_r"
        if c.x > x_fb:
            return "bumper_front"
        if c.x < x_rb:
            return "bumper_rear"
        return "body"

    groups = {}
    for p in me.polygons:
        groups.setdefault(part_of(Vector(p.center)), []).append(p.index)
    out = {}
    for name in ("bumper_front", "bumper_rear", "mirror_l", "mirror_r"):
        if name not in groups:
            continue
        bpy.ops.object.select_all(action="DESELECT")
        ob.select_set(True)
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="DESELECT")
        bpy.ops.object.mode_set(mode="OBJECT")
        sel = set(groups[name])
        for p in ob.data.polygons:
            p.select = part_of(Vector(p.center)) == name
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.separate(type="SELECTED")
        bpy.ops.object.mode_set(mode="OBJECT")
        part = [o for o in bpy.context.selected_objects if o != ob][0]
        part.name = name
        part.data.name = name
        out[name] = part
    ob.name = "body"
    ob.data.name = "body"
    for o in [ob, cab] + list(out.values()):
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(50))
        # livery UVs: u nose -> tail, v round the body (same as built cars)
        uvl = o.data.uv_layers.new(name="UVMap") if not o.data.uv_layers else o.data.uv_layers[0]
        for p in o.data.polygons:
            for li in p.loop_indices:
                co = o.data.vertices[o.data.loops[li].vertex_index].co
                u = (xf - co.x) / car.L
                v = 0.5 + math.atan2(co.y, max(co.z - 0.3, 0.01)) / math.pi
                uvl.data[li].uv = (u, v)
    car.parts["body"] = ob
    # Sit the number markers on the new surface.
    bpy.context.view_layer.update()
    nr = bpy.data.objects.get("number_roof")
    if nr:
        x = cfg.get("roof_number_x", nr.location.x)
        hit, loc, _, _ = ob.ray_cast(Vector((x, 0, 3)), Vector((0, 0, -1)))
        if hit:
            nr.location = (x, 0, loc.z + 0.004)
    for nm, sgn in (("number_door_l", 1), ("number_door_r", -1)):
        e = bpy.data.objects.get(nm)
        if e:
            hit, loc, _, _ = ob.ray_cast(Vector((e.location.x, sgn * 2.0, e.location.z)), Vector((0, -sgn, 0)))
            if hit:
                e.location = (e.location.x, loc.y + sgn * 0.004, e.location.z)
    print("[cars] %s: AI body, %d triangles" % (car.id, sum(len(p.vertices) - 2 for p in ob.data.polygons)))
    return ob
