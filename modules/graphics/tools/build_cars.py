"""Builds the 3D car models in Blender from each car's real dimensions.

Run (Blender 4.5, no window needed):
    blender -b --python modules/graphics/tools/build_cars.py -- [car_id ...]

Inputs
  modules/cars/data/<id>.json          real dimensions (special/ for the safety car) (length, width, wheelbase,
                                       track, wheel radius, weight split)
  modules/graphics/tools/car_shapes/<id>.json   the car's shape: body sections,
                                       cabin, wing, lights, vents, livery

Outputs
  modules/graphics/cars/<id>.glb       what the game loads
  modules/graphics/cars_blend/<id>.blend  the same car to open and edit in Blender

Car space (Blender): +X forward, +Y left, +Z up, metres. The origin is the
car's centre of gravity on the ground, exactly where the simulation puts the
car, so the wheels sit on the simulated axles. glTF turns this into Godot's
+X forward, +Z right, +Y up.

Parts are separate objects so upgrades can swap them: body, bumper_front,
bumper_rear, cabin (glass + pillars), splitter, diffuser, wing_rear, mirror_l,
mirror_r, interior, wheel_fl/fr/rl/rr (each with a spinning wheel and a
static brake caliper). Empties: number_roof, number_door_l, number_door_r.

Materials (Godot finds them by name): paint (the livery), carbon, glass,
grille, vent, intake, light_head, light_tail, light_drl, tyre, rim, disc,
caliper, underbody, interior, helmet, mirror_glass.

UVs: UV0 is a livery unwrap. u runs 0 at the nose to 1 at the tail, and v
runs around the body from 0 under the left sill, over the roof (0.5) to 1
under the right sill. A painted livery texture can use it. The procedural
liveries in the game use the car-space position instead.

If you hand-edit a car in Blender, set "hand_edited": true in its shape file
and export the .glb yourself (File > Export > glTF, defaults). The builder
then leaves that car alone.
"""

import bpy
import bmesh
import json
import math
import os
import sys
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(GFX))
CARS_DATA = os.path.join(ROOT, "modules", "cars", "data")
CARS_SPECIAL = os.path.join(ROOT, "modules", "cars", "special")   # the safety car
SHAPES = os.path.join(HERE, "car_shapes")
OUT_GLB = os.path.join(GFX, "cars")
OUT_BLEND = os.path.join(GFX, "cars_blend")

# ---------------------------------------------------------------- helpers


def lerp(a, b, k):
    return a + (b - a) * k


def smooth(k):
    k = max(0.0, min(1.0, k))
    return k * k * (3 - 2 * k)


def interp_keys(keys, t, field):
    """Monotone cubic (Fritsch-Carlson) through keyframes [{t, field...}]."""
    ts = [k["t"] for k in keys]
    vs = [k[field] for k in keys]
    n = len(ts)
    if t <= ts[0]:
        return vs[0]
    if t >= ts[-1]:
        return vs[-1]
    d = [(vs[i + 1] - vs[i]) / (ts[i + 1] - ts[i]) for i in range(n - 1)]
    m = [d[0]] + [0.0] * (n - 2) + [d[-1]]
    for i in range(1, n - 1):
        if d[i - 1] * d[i] <= 0:
            m[i] = 0.0
        else:
            m[i] = 2.0 / (1.0 / d[i - 1] + 1.0 / d[i])
    i = 0
    while ts[i + 1] < t:
        i += 1
    h = ts[i + 1] - ts[i]
    s = (t - ts[i]) / h
    h00 = 2 * s ** 3 - 3 * s ** 2 + 1
    h10 = s ** 3 - 2 * s ** 2 + s
    h01 = -2 * s ** 3 + 3 * s ** 2
    h11 = s ** 3 - s ** 2
    return h00 * vs[i] + h10 * h * m[i] + h01 * vs[i + 1] + h11 * h * m[i + 1]


def superellipse_arc(cx, cz, rx, rz, a0, a1, n, steps, include_start):
    pts = []
    for k in range(0 if include_start else 1, steps + 1):
        a = math.radians(lerp(a0, a1, k / steps))
        c, s = math.cos(a), math.sin(a)
        y = cx + rx * math.copysign(abs(c) ** (2.0 / n), c)
        z = cz + rz * math.copysign(abs(s) ** (2.0 / n), s)
        pts.append((y, z))
    return pts


def new_object(name, me, parent=None):
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    if parent:
        ob.parent = parent
    return ob


def bake_modifiers(ob):
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    old = ob.data
    ob.modifiers.clear()
    ob.data = me
    bpy.data.meshes.remove(old)


def shade_smooth(ob, angle=40.0):
    for p in ob.data.polygons:
        p.use_smooth = True
    # Sharp edges above the angle stay crisp (Blender 4.1+ replacement for auto smooth).
    try:
        with bpy.context.temp_override(active_object=ob, selected_objects=[ob], object=ob):
            bpy.ops.object.shade_smooth_by_angle(angle=math.radians(angle))
    except Exception:
        pass


# ---------------------------------------------------------------- materials

MATS = {}


def material(name, color, metallic=0.0, roughness=0.5, emission=None, alpha=1.0, coat=0.0):
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (*color, 1.0)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = roughness
    if coat > 0:
        b.inputs["Coat Weight"].default_value = coat
    if emission:
        b.inputs["Emission Color"].default_value = (*emission[0], 1.0)
        b.inputs["Emission Strength"].default_value = emission[1]
    if alpha < 1.0:
        b.inputs["Alpha"].default_value = alpha
        m.blend_method = "BLEND"
    MATS[name] = m
    return m


def setup_materials(shape):
    MATS.clear()
    liv = shape.get("livery", {})
    paint = hex_rgb(liv.get("primary", shape.get("_colour", "#cc2222")))
    material("paint", paint, 0.35, 0.28, coat=1.0)
    material("carbon", (0.025, 0.025, 0.028), 0.2, 0.32)
    material("glass", (0.02, 0.03, 0.04), 0.0, 0.04, alpha=0.55)
    material("grille", (0.015, 0.015, 0.015), 0.1, 0.55)
    material("vent", (0.01, 0.01, 0.01), 0.0, 0.7)
    material("intake", (0.008, 0.008, 0.008), 0.0, 0.8)
    material("light_head", (0.85, 0.88, 0.9), 0.6, 0.08, emission=((1.0, 0.97, 0.9), 0.0))
    material("light_tail", (0.45, 0.02, 0.02), 0.2, 0.15, emission=((1.0, 0.05, 0.02), 0.0))
    material("light_drl", (0.9, 0.9, 0.95), 0.3, 0.1, emission=((0.9, 0.95, 1.0), 0.0))
    material("tyre", (0.035, 0.035, 0.035), 0.0, 0.85)
    material("rim", hex_rgb(shape.get("rim_colour", "#202226")), 0.85, 0.3)
    material("disc", (0.35, 0.35, 0.36), 0.9, 0.45)
    material("caliper", hex_rgb(shape.get("caliper_colour", "#c8102e")), 0.3, 0.35)
    material("underbody", (0.02, 0.02, 0.02), 0.0, 0.9)
    material("interior", (0.04, 0.04, 0.045), 0.0, 0.8)
    material("helmet", hex_rgb(shape.get("helmet_colour", "#f0f0f0")), 0.2, 0.25, coat=1.0)
    material("mirror_glass", (0.6, 0.62, 0.65), 1.0, 0.05)
    material("cage", (0.12, 0.12, 0.13), 0.6, 0.4)
    material("light_bar_amber", (0.6, 0.32, 0.02), 0.1, 0.1, emission=((1.0, 0.55, 0.05), 0.0))
    material("light_bar_green", (0.05, 0.4, 0.1), 0.1, 0.1, emission=((0.1, 1.0, 0.25), 0.0))


def hex_rgb(h):
    h = h.lstrip("#")
    srgb = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb)


def mat_index(me, name):
    m = MATS[name]
    for i, mm in enumerate(me.materials):
        if mm == m:
            return i
    me.materials.append(m)
    return len(me.materials) - 1


# ---------------------------------------------------------------- the car


class Car:
    def __init__(self, cid, data, shape):
        self.id = cid
        self.d = data
        self.s = shape
        self.L = data["length_m"]
        self.W = data["width_m"]
        self.wb = data["wheelbase_m"]
        self.track = data["track_width_m"]
        self.R = data["wheel_radius_m"]
        self.a = self.wb * (1.0 - data.get("weight_front", 0.5))   # CG -> front axle
        self.b = self.wb - self.a                                  # CG -> rear axle
        self.fo = shape["front_overhang"]
        # x of the nose and tail in car space (CG at 0)
        self.x_front = self.a + self.fo
        self.x_rear = self.x_front - self.L
        self.axles = [self.a, -self.b]
        self.parts = {}
        self.root = None

    # t (0 nose .. 1 tail) <-> x
    def x_of(self, t):
        return lerp(self.x_front, self.x_rear, t)

    def t_of(self, x):
        return (self.x_front - x) / self.L

    # ---------------------------------------------------- body sections

    def section_params(self, t):
        keys = self.s["body"]
        p = {f: interp_keys(keys, t, f) for f in ("w", "zb", "zs", "zt", "ze", "wt")}
        hw = self.W * 0.5
        w = p["w"] * hw
        # Wheel arches: flare the body out and up over each wheel.
        x = self.x_of(t)
        flare = self.s.get("arch_flare", [0.06, 0.07])
        lift = self.s.get("arch_lift", [0.05, 0.05])
        for i, ax in enumerate(self.axles):
            k = (x - ax) / (self.R * 1.55)
            bump = math.cos(min(abs(k), 1.0) * math.pi * 0.5) ** 1.6 if abs(k) < 1.0 else 0.0
            w += flare[i] * bump
            p["ze"] += lift[i] * bump
        p["w"] = min(w, hw)
        p["wt"] = p["wt"] * p["w"]
        return p

    def ring(self, t):
        p = self.section_params(t)
        w, zb, zs, zt, ze, wt = p["w"], p["zb"], p["zs"], p["zt"], p["ze"], p["wt"]
        zs = max(zs, zb + 0.04)
        ze = max(ze, zs + 0.03)
        half = [(0.0, zb), (w * 0.55, zb)]
        half += superellipse_arc(w * 0.82, zs, w * 0.18, zs - zb, -90, 0, 2.6, 3, False)
        half += superellipse_arc(wt, zs, w - wt, ze - zs, 0, 90, 2.4, 4, False)
        for f in (0.62, 0.3):
            y = wt * f
            half.append((y, zt + (ze - zt) * f * f))
        half.append((0.0, zt))
        # full ring: right side (y<0) bottom->top, then left side top->bottom
        right = [(-y, z) for (y, z) in half]
        left = [(y, z) for (y, z) in reversed(half[1:-1])]
        return right + left    # first = bottom centre, middle = top centre

    def deck_height(self, t, y):
        """Top surface height of the body at (t, |y|), before subdivision."""
        p = self.section_params(t)
        y = abs(y)
        if y <= p["wt"]:
            f = y / max(p["wt"], 1e-3)
            return p["zt"] + (p["ze"] - p["zt"]) * f * f
        return p["ze"]

    def build_body(self):
        n_st = 56
        ts = []
        for i in range(n_st):
            k = i / (n_st - 1)
            ts.append(0.5 - 0.5 * math.cos(k * math.pi))   # denser at the ends
        rings = [self.ring(t) for t in ts]
        bm = bmesh.new()
        uv = bm.loops.layers.uv.new("UVMap")
        verts = []
        for t, r in zip(ts, rings):
            x = self.x_of(t)
            verts.append([bm.verts.new((x, y, z)) for (y, z) in r])
        m = len(rings[0])
        for i in range(n_st - 1):
            for j in range(m):
                j2 = (j + 1) % m
                f = bm.faces.new((verts[i][j], verts[i][j2], verts[i + 1][j2], verts[i + 1][j]))
                for loop, (ii, jj) in zip(f.loops, ((i, j), (i, j2), (i + 1, j2), (i + 1, jj if False else j))):
                    v = jj / m if not (jj == 0 and j == m - 1 and loop.vert is verts[ii][0]) else 1.0
                    loop[uv].uv = (ts[ii], v)
        bm.faces.new(list(reversed(verts[0])))
        bm.faces.new(verts[-1])
        # Creases keep the shoulder line (top of the wings) and the sills crisp.
        cl = bm.edges.layers.float.get("crease_edge") or bm.edges.layers.float.new("crease_edge")
        bm.edges.ensure_lookup_table()
        creases = {8: self.s.get("shoulder_crease", 0.65), m - 8: self.s.get("shoulder_crease", 0.65),
                   1: 0.5, m - 1: 0.5}
        for i in range(n_st - 1):
            for j, c in creases.items():
                e = bm.edges.get((verts[i][j], verts[i + 1][j]))
                if e:
                    e[cl] = c
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        me = bpy.data.meshes.new("body")
        bm.to_mesh(me)
        bm.free()
        ob = new_object("body", me)
        mod = ob.modifiers.new("sub", "SUBSURF")
        mod.levels = 2
        mod.render_levels = 2
        mod.uv_smooth = "PRESERVE_BOUNDARIES"
        bake_modifiers(ob)
        self.fit_extent(ob)
        self.cut_wheel_arches(ob)
        return ob

    def fit_extent(self, ob):
        """Subdivision shrinks the shape; scale it back to the real length and width."""
        xs = [v.co.x for v in ob.data.vertices]
        ys = [v.co.y for v in ob.data.vertices]
        L = max(xs) - min(xs)
        W = max(ys) - min(ys)
        cx = (max(xs) + min(xs)) * 0.5
        want_cx = (self.x_front + self.x_rear) * 0.5
        sx = self.L / L
        sy = (self.W - 2 * self.s.get("mirror_width", 0.0)) / W
        for v in ob.data.vertices:
            v.co.x = want_cx + (v.co.x - cx) * sx
            v.co.y *= sy

    def cut_wheel_arches(self, ob):
        """Boolean the wheel openings out of the body so the wheels show."""
        cutters = []
        for i, ax in enumerate(self.axles):
            r = self.R * self.s.get("arch_radius", 1.13)
            depth = self.W
            me = bpy.data.meshes.new("cut")
            bm = bmesh.new()
            bmesh.ops.create_cone(bm, cap_ends=True, segments=40, radius1=r, radius2=r, depth=depth)
            bm.to_mesh(me)
            bm.free()
            for side in (1, -1):
                c = new_object("cutter", me.copy())
                inner = self.track * 0.5 - self.tyre_width(i) * 0.5 - 0.05
                c.location = (ax, side * (inner + depth * 0.5), self.R + self.s.get("arch_center_up", 0.02))
                c.rotation_euler = (math.pi / 2, 0, 0)
                cutters.append(c)
        bpy.context.view_layer.update()
        for c in cutters:
            mod = ob.modifiers.new("arch", "BOOLEAN")
            mod.operation = "DIFFERENCE"
            mod.solver = "EXACT"
            mod.object = c
            bake_modifiers(ob)
        for c in cutters:
            me = c.data
            bpy.data.objects.remove(c)
            bpy.data.meshes.remove(me)

    def tyre_width(self, axle):
        tw = self.s.get("tyre_width", [0.30, 0.32])
        return tw[axle]

    # ---------------------------------------------------- cabin

    def build_cabin(self):
        """The greenhouse: its own loft sitting on the body. Glass is assigned
        on the coarse mesh along ring and station lines, so subdivision gives
        the windows smooth edges."""
        c = self.s["cabin"]
        keys = c["stations"]
        t0, t1 = keys[0]["t"], keys[-1]["t"]
        ws, sw, rg = c["windscreen"], c["side_windows"], c.get("rear_glass")
        n_st = 30
        ts = set(lerp(t0, t1, 0.5 - 0.5 * math.cos(i / (n_st - 1) * math.pi)) for i in range(n_st))
        for rng in (ws, sw, rg or []):
            for t in rng:
                if t0 < t < t1:
                    ts.add(t)
        ts = sorted(ts)
        clean = [ts[0]]
        for t in ts[1:]:
            if t - clean[-1] > 0.004:
                clean.append(t)
        ts = clean
        hw = self.W * 0.5
        bm = bmesh.new()
        uv = bm.loops.layers.uv.new("UVMap")
        rows = []
        for t in ts:
            zt = interp_keys(keys, t, "zt")
            wb = interp_keys(keys, t, "wb") * hw
            wt = interp_keys(keys, t, "wt") * hw
            zbase = self.deck_height(t, wb) - 0.015
            zt = max(zt, zbase + 0.02)
            z0 = zbase - 0.12
            h = zt - zbase
            half = [(0.0, z0), (wb, z0), (wb, zbase)]
            half.append((lerp(wb, wt, 0.45) + 0.012, zbase + h * 0.45))
            half.append((wt + 0.025, zt - min(0.07, h * 0.3)))
            half.append((wt * 0.72, zt - min(0.018, h * 0.1)))
            half.append((wt * 0.36, zt - 0.004))
            half.append((0.0, zt))
            right = [(-y, z) for (y, z) in half]
            left = [(y, z) for (y, z) in reversed(half[1:-1])]
            x = self.x_of(t)
            rows.append([bm.verts.new((x, y, z)) for (y, z) in right + left])
        m = len(rows[0])
        hi = lambda j: j if j <= 7 else 14 - j
        side_seg = ({2, 3}, {3, 4})
        top_seg = ({4, 5}, {5, 6}, {6, 7})
        rear_seg = ({5, 6}, {6, 7})
        for i in range(len(ts) - 1):
            tm = (ts[i] + ts[i + 1]) * 0.5
            for j in range(m):
                j2 = (j + 1) % m
                f = bm.faces.new((rows[i][j], rows[i][j2], rows[i + 1][j2], rows[i + 1][j]))
                seg = {hi(j), hi(j2)}
                glass = (ws[0] <= tm <= ws[1] and seg in top_seg) or \
                        (sw[0] <= tm <= sw[1] and seg in side_seg) or \
                        (rg is not None and rg[0] <= tm <= rg[1] and seg in rear_seg)
                f.material_index = 1 if glass else 0
                for loop, (ii, jj) in zip(f.loops, ((i, j), (i, j2), (i + 1, j2), (i + 1, j))):
                    v = 1.0 if (jj == 0 and j == m - 1) else jj / m
                    loop[uv].uv = (ts[ii], v)
        bm.faces.new(list(reversed(rows[0])))
        bm.faces.new(rows[-1])
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        me = bpy.data.meshes.new("cabin")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(MATS["paint"])
        me.materials.append(MATS["glass"])
        ob = new_object("cabin", me)
        mod = ob.modifiers.new("sub", "SUBSURF")
        mod.levels = 2
        mod.uv_smooth = "PRESERVE_BOUNDARIES"
        bake_modifiers(ob)
        rs = c.get("roof_scoop")
        if rs:
            self.add_roof_scoop(ob, rs)
        return ob

    def add_roof_scoop(self, cab, rs):
        keys = self.s["cabin"]["stations"]
        ta, tb = rs["t"]
        hw = rs.get("w", 0.12)
        h = rs.get("h", 0.11)
        bm = bmesh.new()
        n = 8
        rows = []
        for i in range(n + 1):
            t = lerp(ta, tb, i / n)
            z = interp_keys(keys, t, "zt") - 0.01
            k = i / n
            hh = h * min(1.0, k * 4.0) * (1 - 0.5 * k)
            ww = hw * (0.85 + 0.15 * k)
            x = self.x_of(t)
            rows.append([bm.verts.new((x, -ww, z)), bm.verts.new((x, -ww * 0.9, z + hh)),
                         bm.verts.new((x, ww * 0.9, z + hh)), bm.verts.new((x, ww, z))])
        for i in range(n):
            for k in range(4):
                k2 = (k + 1) % 4
                bm.faces.new((rows[i][k], rows[i][k2], rows[i + 1][k2], rows[i + 1][k]))
        f = bm.faces.new(list(reversed(rows[0])))
        f.material_index = 1
        bm.faces.new(rows[-1])
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        me = bpy.data.meshes.new("scoop")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(MATS["paint"])
        me.materials.append(MATS["intake"])
        join_into(cab, new_object("scoop", me))

    # ---------------------------------------------------- material regions on the body

    def paint_regions(self, ob):
        """Underbody material, then lights, vents, grilles and intakes as thin
        decal patches shrink-wrapped onto the body (crisp edges at any size)."""
        me = ob.data
        if not me.materials:
            me.materials.append(MATS["paint"])
        under = mat_index(me, "underbody")
        mid_zb = self.s["body"][len(self.s["body"]) // 2]["zb"]
        for p in me.polygons:
            if p.normal.z < -0.6 or (p.center.z < mid_zb + 0.02 and p.normal.z < 0.0):
                p.material_index = under
        for r in self.s.get("regions", []):
            sides = (1, -1) if r.get("mirror", True) and r.get("facing") in ("side",) else (1,)
            if r.get("mirror", True) and r.get("facing") != "side" and r.get("y", [0, 0])[0] > 0.0:
                sides = (1, -1)
            for s in sides:
                d = self.decal(r, s, ob)
                if d:
                    join_into(ob, d)

    def decal(self, r, side, target):
        hw = self.W * 0.5
        facing = r.get("facing", "top")
        tt = r.get("t", [0, 1])
        yy = r.get("y", [-1, 1])
        zz = r.get("z", [0, 1.5])
        nu, nv = 18, 8
        bm = bmesh.new()
        grid = []
        for i in range(nu + 1):
            u = i / nu
            row = []
            for j in range(nv + 1):
                v = j / nv
                if r.get("shape") == "ellipse":
                    # square -> disc
                    a, b = u * 2 - 1, v * 2 - 1
                    a, b = a * math.sqrt(max(0.0, 1 - b * b / 2)), b * math.sqrt(max(0.0, 1 - a * a / 2))
                    u2, v2 = (a + 1) / 2, (b + 1) / 2
                else:
                    u2, v2 = u, v
                sh = r.get("slant", 0.0) * u2
                t = lerp(tt[0], tt[1], u2)
                if facing == "top":
                    y = lerp(yy[0] + sh, yy[1] + sh, v2) * hw * side
                    co = (self.x_of(t), y, 3.0)
                elif facing == "side":
                    z = lerp(zz[0], zz[1], v2) + r.get("slant", 0.0) * (u2 - 0.5)
                    co = (self.x_of(t), side * 3.0, z)
                elif facing in ("front", "frontish"):
                    y = lerp(yy[0], yy[1], u2) * hw * side
                    z = lerp(zz[0], zz[1], v2) + r.get("slant", 0.0) * u2
                    co = (self.x_front + 2.0, y, z)
                else:  # rear
                    y = lerp(yy[0], yy[1], u2) * hw * side
                    z = lerp(zz[0], zz[1], v2) + r.get("slant", 0.0) * u2
                    co = (self.x_rear - 2.0, y, z)
                row.append(bm.verts.new(co))
            grid.append(row)
        for i in range(nu):
            for j in range(nv):
                f = (grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1])
                bm.faces.new(f)
        me = bpy.data.meshes.new("decal")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(MATS[r["mat"]])
        ob = new_object("decal", me)
        sw = ob.modifiers.new("wrap", "SHRINKWRAP")
        sw.target = target
        sw.wrap_method = "PROJECT"
        sw.use_negative_direction = True
        sw.use_positive_direction = True
        sw.offset = 0.004
        if facing == "top":
            sw.use_project_z = True
        elif facing == "side":
            sw.use_project_y = True
        else:
            sw.use_project_x = True
        bake_modifiers(ob)
        # drop faces that missed the body (still floating where they started)
        bm = bmesh.new()
        bm.from_mesh(ob.data)
        far = [v for v in bm.verts if v.co.z > 2.5 or abs(v.co.y) > 2.5 or v.co.x > self.x_front + 1.5 or v.co.x < self.x_rear - 1.5]
        bmesh.ops.delete(bm, geom=far, context="VERTS")
        # Drop slivers: faces that landed at a grazing angle or got stretched
        # across a gap (edges far longer than the patch grid).
        axis = {"top": Vector((0, 0, 1)), "side": Vector((0, side, 0)), "front": Vector((1, 0, 0)),
                "frontish": Vector((1, 0, 0)), "rear": Vector((-1, 0, 0))}[facing]
        if facing == "side":
            axis = Vector((0, 1, 0))
        bm.normal_update()
        step = 0.0
        for e in bm.edges:
            step += e.calc_length()
        step = step / max(len(bm.edges), 1)
        bad = []
        for f in bm.faces:
            dot = abs(f.normal.dot(axis))
            if dot < r.get("min_facing", 0.25) or max(e.calc_length() for e in f.edges) > step * 3.5:
                bad.append(f)
        bmesh.ops.delete(bm, geom=bad, context="FACES")
        loose = [v for v in bm.verts if not v.link_faces]
        bmesh.ops.delete(bm, geom=loose, context="VERTS")
        for f in bm.faces:
            f.smooth = True
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.to_mesh(ob.data)
        bm.free()
        if not ob.data.polygons:
            bpy.data.objects.remove(ob)
            return None
        # face outwards like the surface below
        return ob

    # ---------------------------------------------------- split body into panels

    def split_panels(self, body):
        """Cut the front and rear bumpers off as their own parts."""
        out = {}
        cuts = self.s.get("bumper_cuts", [0.12, 0.9])
        for name, keep in (("bumper_front", "front"), ("bumper_rear", "rear"), ("body", "mid")):
            me = body.data.copy()
            bm = bmesh.new()
            bm.from_mesh(me)
            xf = self.x_of(cuts[0])
            xr = self.x_of(cuts[1])
            geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
            if keep == "front":
                bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(xf, 0, 0), plane_no=(1, 0, 0), clear_inner=True)
            elif keep == "rear":
                bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(xr, 0, 0), plane_no=(-1, 0, 0), clear_inner=True)
            else:
                r = bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(xf, 0, 0), plane_no=(1, 0, 0), clear_outer=True)
                geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
                bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(xr, 0, 0), plane_no=(-1, 0, 0), clear_outer=True)
            bm.to_mesh(me)
            bm.free()
            out[name] = me
        old = body.data
        body.data = out["body"]
        bpy.data.meshes.remove(old)
        fb = new_object("bumper_front", out["bumper_front"])
        rb = new_object("bumper_rear", out["bumper_rear"])
        return fb, rb

    # ---------------------------------------------------- aero parts

    def build_splitter(self):
        sp = self.s.get("splitter")
        if not sp:
            return None
        hw = self.W * 0.5 * sp.get("width", 0.92)
        depth = sp.get("depth", 0.18)
        x0 = self.x_front + sp.get("extend", 0.04)
        z = sp.get("z", 0.07)
        bm = bmesh.new()
        pts = []
        n = 14
        for i in range(n + 1):
            a = i / n
            y = lerp(-hw, hw, a)
            # nose follows the body's plan shape: rounder at the corners
            f = abs(y) / hw
            pts.append((x0 - 0.08 * f ** 3 - sp.get("sweep", 0.12) * f ** 4, y))
        top = [bm.verts.new((x, y, z + 0.012)) for (x, y) in pts]
        topb = [bm.verts.new((x - depth - 0.25, y * 0.92, z + 0.012)) for (x, y) in pts]
        bot = [bm.verts.new((x, y, z - 0.012)) for (x, y) in pts]
        botb = [bm.verts.new((x - depth - 0.25, y * 0.92, z - 0.012)) for (x, y) in pts]
        for i in range(n):
            bm.faces.new((top[i], top[i + 1], topb[i + 1], topb[i]))
            bm.faces.new((bot[i + 1], bot[i], botb[i], botb[i + 1]))
            bm.faces.new((bot[i], bot[i + 1], top[i + 1], top[i]))
        bm.faces.new((top[0], topb[0], botb[0], bot[0]))
        bm.faces.new((bot[n], botb[n], topb[n], top[n]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        me = bpy.data.meshes.new("splitter")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(MATS["carbon"])
        return new_object("splitter", me)

    def build_diffuser(self):
        df = self.s.get("diffuser")
        if not df:
            return None
        hw = self.W * 0.5 * df.get("width", 0.8)
        x1 = self.x_rear + df.get("extend", 0.02)
        x0 = x1 + df.get("length", 0.6)
        h = df.get("height", 0.2)
        bm = bmesh.new()
        me = bpy.data.meshes.new("diffuser")
        # ramp plate
        v = [bm.verts.new(p) for p in ((x0, -hw, 0.06), (x0, hw, 0.06), (x1, hw, 0.06 + h), (x1, -hw, 0.06 + h))]
        bm.faces.new(v)
        # strakes
        nf = df.get("fins", 5)
        for i in range(nf):
            y = lerp(-hw, hw, (i + 0.5) / nf)
            s = [bm.verts.new(p) for p in ((x0, y, 0.06), (x1, y, 0.06 + h), (x1, y, 0.04), (x0 + 0.1, y, 0.04))]
            bm.faces.new(s)
        bm.to_mesh(me)
        bm.free()
        me.materials.append(MATS["carbon"])
        ob = new_object("diffuser", me)
        mod = ob.modifiers.new("thick", "SOLIDIFY")
        mod.thickness = 0.012
        bake_modifiers(ob)
        return ob

    def build_wing(self):
        wg = self.s.get("wing")
        if not wg:
            return None
        if wg.get("type") == "ducktail":
            return self.build_ducktail(wg)
        chord = wg.get("chord", 0.34)
        span = self.W * wg.get("span", 0.88)
        xt = self.x_of(wg.get("t", 0.95))      # trailing edge
        z = wg.get("z", 1.22)
        aoa = math.radians(wg.get("angle", 9.0))
        bm = bmesh.new()
        prof = airfoil(chord, wg.get("thickness", 0.11), wg.get("camber", 0.06))
        # inverted (downforce) foil, leading edge forward
        loops = []
        for y in (-span * 0.5, span * 0.5):
            ring = []
            for (u, v) in prof:
                px = xt + chord - u
                pz = z - v
                # pitch nose down about the trailing edge
                dx, dz = px - xt, pz - z
                ring.append(bm.verts.new((xt + dx * math.cos(aoa) + dz * math.sin(aoa), y,
                                          z - dx * math.sin(aoa) + dz * math.cos(aoa))))
            loops.append(ring)
        n = len(prof)
        for i in range(n):
            i2 = (i + 1) % n
            bm.faces.new((loops[0][i], loops[0][i2], loops[1][i2], loops[1][i]))
        bm.faces.new(list(reversed(loops[0])))
        bm.faces.new(loops[1])
        # Gurney flap
        g = wg.get("gurney", 0.025)
        if g > 0:
            gv = [bm.verts.new(p) for p in ((xt + 0.004, -span * 0.5, z), (xt + 0.004, span * 0.5, z),
                                             (xt + 0.004, span * 0.5, z + g), (xt + 0.004, -span * 0.5, z + g))]
            bm.faces.new(gv)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        # end plates
        ep_len = chord * wg.get("endplate_len", 1.7)
        ep_h = wg.get("endplate_h", 0.3)
        for s in (-1, 1):
            y = s * (span * 0.5 + 0.004)
            x0 = xt - 0.04
            x1 = x0 + ep_len
            pts = ((x0, z + 0.07), (x1 - 0.1, z + 0.09), (x1, z - 0.02), (x1 - 0.05, z - ep_h + 0.08), (x0 + 0.08, z - ep_h), (x0, z - ep_h + 0.05))
            vs = [bm.verts.new((px, y, pz)) for (px, pz) in pts]
            bm.faces.new(vs)
        me = bpy.data.meshes.new("wing_rear")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(MATS["carbon"])
        ob = new_object("wing_rear", me)
        # mounts
        mount = wg.get("mount", "swan")
        my = self.W * 0.5 * wg.get("mount_y", 0.28)
        deck_t = self.t_of(xt + chord * 0.5)
        for s in (-1, 1):
            y = s * my
            base_z = self.deck_height(min(max(deck_t, 0.0), 1.0), y) - 0.02
            mb = bmesh.new()
            if mount == "swan":
                # hangs from the top of the wing, curving down and forward
                pts = [(xt + chord * 0.55, z + 0.05), (xt + chord * 0.15, z + 0.07), (xt - 0.04, z - 0.02),
                       (xt - 0.02, lerp(z, base_z, 0.5)), (xt + chord * 0.4, base_z), (xt + chord * 0.95, base_z),
                       (xt + chord * 0.35, lerp(z, base_z, 0.45)), (xt + chord * 0.45, z - 0.01)]
            else:
                pts = [(xt + chord * 0.25, z - 0.03), (xt + chord * 0.75, z - 0.05), (xt + chord * 0.95, base_z),
                       (xt + chord * 0.15, base_z)]
            vs = [mb.verts.new((px, y, pz)) for (px, pz) in pts]
            mb.faces.new(vs)
            mme = bpy.data.meshes.new("mount")
            mb.to_mesh(mme)
            mb.free()
            mo = new_object("mount", mme)
            sol = mo.modifiers.new("t", "SOLIDIFY")
            sol.thickness = 0.016
            sol.offset = 0
            bake_modifiers(mo)
            join_into(ob, mo)
        sol = None
        shade_smooth(ob, 35)
        return ob

    def build_ducktail(self, wg):
        """A lip spoiler on the tail (road cars)."""
        hw = self.W * 0.5 * wg.get("span", 0.75)
        t = wg.get("t", 0.97)
        x = self.x_of(t)
        bm = bmesh.new()
        n = 12
        rows = []
        for i in range(n + 1):
            y = lerp(-hw, hw, i / n)
            zb = self.deck_height(t - 0.02, y)
            h = wg.get("height", 0.05) * (1 - (abs(y) / hw) ** 4 * 0.6)
            rows.append([bm.verts.new((x + 0.12, y, zb - 0.01)), bm.verts.new((x - 0.03, y, zb + h)), bm.verts.new((x - 0.05, y, zb - 0.04))])
        for i in range(n):
            for k in range(3):
                k2 = (k + 1) % 3
                bm.faces.new((rows[i][k], rows[i][k2], rows[i + 1][k2], rows[i + 1][k]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        me = bpy.data.meshes.new("wing_rear")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(MATS["paint" if wg.get("painted", True) else "carbon"])
        ob = new_object("wing_rear", me)
        shade_smooth(ob, 50)
        return ob

    def build_mirrors(self):
        mr = self.s.get("mirrors", {})
        c = self.s["cabin"]
        t = mr.get("t", c["windscreen"][0] + 0.02)
        hw = self.W * 0.5
        out = []
        for s, name in ((1, "mirror_l"), (-1, "mirror_r")):
            base_y = interp_keys(c["stations"], max(t, c["stations"][0]["t"]), "wb") * hw
            z = self.deck_height(t, base_y) + mr.get("z", 0.13)
            y = s * (base_y + mr.get("out", 0.17))
            bm = bmesh.new()
            bmesh.ops.create_uvsphere(bm, u_segments=14, v_segments=8, radius=1.0)
            bmesh.ops.scale(bm, vec=(0.075, 0.11, 0.055), verts=bm.verts)
            # flat glass on the back
            # stalk
            st = bmesh.new()
            bmesh.ops.create_cube(st, size=1.0)
            bmesh.ops.scale(st, vec=(0.05, 0.16, 0.02), verts=st.verts)
            bmesh.ops.translate(st, vec=(0.0, -s * 0.09, -0.04), verts=st.verts)
            me = bpy.data.meshes.new(name)
            bm.to_mesh(me)
            bm.free()
            me2 = bpy.data.meshes.new("stalk")
            st.to_mesh(me2)
            st.free()
            me.materials.append(MATS["paint"])
            ob = new_object(name, me)
            ob2 = new_object("stalk", me2)
            me2.materials.append(MATS["carbon"])
            join_into(ob, ob2)
            gi = mat_index(ob.data, "mirror_glass")
            for p in ob.data.polygons:
                if p.normal.x < -0.75:
                    p.material_index = gi
            ob.data.transform(Matrix.Translation((self.x_of(t) - 0.05, y, z)))
            shade_smooth(ob, 60)
            out.append(ob)
        return out

    # ---------------------------------------------------- interior (seen through the glass)

    def build_interior(self):
        c = self.s["cabin"]
        hw = self.W * 0.5
        bm = bmesh.new()
        me = bpy.data.meshes.new("interior")
        ws0, ws1 = c["windscreen"]
        x_seat = self.x_of(lerp(ws1, c["side_windows"][1], 0.35))
        floor_z = self.s["body"][len(self.s["body"]) // 2]["zb"] + 0.12
        dy = self.s.get("driver_side", 1) * hw * 0.28   # +1 = left-hand drive... GT cars: driver on the left
        objs = []

        def box(cx, cy, cz, sx, sy, sz, mat):
            b = bmesh.new()
            bmesh.ops.create_cube(b, size=1.0)
            bmesh.ops.scale(b, vec=(sx, sy, sz), verts=b.verts)
            bmesh.ops.translate(b, vec=(cx, cy, cz), verts=b.verts)
            m = bpy.data.meshes.new("ib")
            b.to_mesh(m)
            b.free()
            m.materials.append(MATS[mat])
            o = new_object("ib", m)
            objs.append(o)
            return o

        # tub floor and dash
        box(x_seat + 0.2, 0, floor_z, 1.6, hw * 1.25, 0.04, "interior")
        dash_x = self.x_of(ws1) - 0.05
        box(dash_x, 0, floor_z + 0.42, 0.25, hw * 1.2, 0.12, "interior")
        # seats (driver + passenger for road cars)
        seats = [dy] if self.s.get("race_car", True) else [dy, -dy]
        for sy in seats:
            box(x_seat, sy, floor_z + 0.16, 0.5, 0.48, 0.12, "interior")
            box(x_seat - 0.27, sy, floor_z + 0.45, 0.12, 0.5, 0.6, "interior")
        # helmet for the driver
        b = bmesh.new()
        bmesh.ops.create_uvsphere(b, u_segments=16, v_segments=10, radius=0.14)
        bmesh.ops.scale(b, vec=(1.12, 1.0, 1.0), verts=b.verts)
        bmesh.ops.translate(b, vec=(x_seat - 0.12, dy, floor_z + 0.72), verts=b.verts)
        m = bpy.data.meshes.new("helmet")
        b.to_mesh(m)
        b.free()
        m.materials.append(MATS["helmet"])
        h = new_object("helmet", m)
        objs.append(h)
        # roll cage for race cars
        if self.s.get("race_car", True):
            ks = c["stations"]
            def roof_at(x):
                t = min(max(self.t_of(x), ks[0]["t"]), ks[-1]["t"])
                return interp_keys(ks, t, "zt") - 0.12
            xb, xf = x_seat - 0.35, dash_x - 0.05
            for xx in (xb, xf):
                box(xx, 0, roof_at(xx), 0.05, hw * 0.9, 0.04, "cage")
            zmid = min(roof_at(xb), roof_at(xf))
            for sy in (-1, 1):
                box((xb + xf) * 0.5, sy * hw * 0.42, zmid, abs(xf - xb), 0.04, 0.04, "cage")
        ob = objs[0]
        ob.name = "interior"
        for o in objs[1:]:
            join_into(ob, o)
        return ob

    # ---------------------------------------------------- wheels

    def build_wheel(self, axle, side):
        """side +1 = left (+Y). Returns hub empty; children spin / caliper."""
        name = ("wheel_f" if axle == 0 else "wheel_r") + ("l" if side > 0 else "r")
        R = self.R
        w = self.tyre_width(axle)
        rim_r = R * self.s.get("rim_ratio", 0.68)
        hub = bpy.data.objects.new(name, None)
        bpy.context.scene.collection.objects.link(hub)
        hub.location = (self.axles[axle], side * self.track * 0.5, R)
        # Tyre: revolve a rounded profile around the axle (local Y).
        bm = bmesh.new()
        prof = []
        bulge = 0.012
        for k in range(9):
            a = k / 8
            y = lerp(-w * 0.5, w * 0.5, a)
            r = R - 0.022 * (abs(a - 0.5) * 2) ** 4 + 0.0
            prof.append((y, r))
        prof = [(-w * 0.5 + 0.01, rim_r + 0.01), (-w * 0.5 - bulge, lerp(rim_r, R, 0.55))] + prof + \
               [(w * 0.5 + bulge, lerp(rim_r, R, 0.55)), (w * 0.5 - 0.01, rim_r + 0.01)]
        segs = 40
        rings = []
        for i in range(segs):
            a = i / segs * math.tau
            ca, sa = math.cos(a), math.sin(a)
            rings.append([bm.verts.new((r * ca, y, r * sa)) for (y, r) in prof])
        n = len(prof)
        for i in range(segs):
            i2 = (i + 1) % segs
            for j in range(n - 1):
                bm.faces.new((rings[i][j], rings[i][j + 1], rings[i2][j + 1], rings[i2][j]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        me = bpy.data.meshes.new(name + "_tyre")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(MATS["tyre"])
        spin = new_object(name + "_spin", me, hub)
        # Rim: barrel + face with spokes + centre lock, on the outer side.
        out = -side  # outer face direction in local Y... left wheel's outside is +Y
        out = side
        parts = []
        b = bmesh.new()
        bmesh.ops.create_cone(b, cap_ends=False, segments=32, radius1=rim_r, radius2=rim_r, depth=w * 0.9)
        bmesh.ops.rotate(b, verts=b.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 3, "X"))
        m = bpy.data.meshes.new("barrel")
        b.to_mesh(m)
        b.free()
        m.materials.append(MATS["rim"])
        parts.append(new_object("barrel", m))
        nsp = self.s.get("spokes", 10)
        face_y = out * (w * 0.5 - 0.035)
        for k in range(nsp):
            a = k / nsp * math.tau
            b = bmesh.new()
            bmesh.ops.create_cube(b, size=1.0)
            bmesh.ops.scale(b, vec=(0.03, 0.02, rim_r * 0.92), verts=b.verts)
            bmesh.ops.translate(b, vec=(0, face_y, rim_r * 0.5), verts=b.verts)
            bmesh.ops.rotate(b, verts=b.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(a, 3, "Y"))
            m = bpy.data.meshes.new("spoke")
            b.to_mesh(m)
            b.free()
            m.materials.append(MATS["rim"])
            parts.append(new_object("spoke", m))
        b = bmesh.new()
        bmesh.ops.create_cone(b, cap_ends=True, segments=16, radius1=0.055, radius2=0.04, depth=0.05)
        bmesh.ops.rotate(b, verts=b.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(-out * math.pi / 2, 3, "X"))
        bmesh.ops.translate(b, vec=(0, face_y + out * 0.02, 0), verts=b.verts)
        m = bpy.data.meshes.new("nut")
        b.to_mesh(m)
        b.free()
        m.materials.append(MATS["rim"])
        parts.append(new_object("nut", m))
        # outer rim lip
        b = bmesh.new()
        bmesh.ops.create_cone(b, cap_ends=False, segments=32, radius1=rim_r + 0.012, radius2=rim_r - 0.01, depth=0.02)
        bmesh.ops.rotate(b, verts=b.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 3, "X"))
        bmesh.ops.translate(b, vec=(0, out * (w * 0.5 - 0.02), 0), verts=b.verts)
        m = bpy.data.meshes.new("lip")
        b.to_mesh(m)
        b.free()
        m.materials.append(MATS["rim"])
        parts.append(new_object("lip", m))
        # brake disc (spins)
        b = bmesh.new()
        bmesh.ops.create_cone(b, cap_ends=True, segments=32, radius1=rim_r * 0.86, radius2=rim_r * 0.86, depth=0.032)
        bmesh.ops.rotate(b, verts=b.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 3, "X"))
        bmesh.ops.translate(b, vec=(0, out * (w * 0.5 - 0.13), 0), verts=b.verts)
        m = bpy.data.meshes.new("disc")
        b.to_mesh(m)
        b.free()
        m.materials.append(MATS["disc"])
        parts.append(new_object("disc", m))
        for p in parts:
            p.parent = spin
            join_into(spin, p)
        shade_smooth(spin, 45)
        # caliper: static, at the back-top of the disc
        b = bmesh.new()
        bmesh.ops.create_cube(b, size=1.0)
        bmesh.ops.scale(b, vec=(0.17, 0.07, 0.07), verts=b.verts)
        ca = math.radians(110 if axle == 0 else 70)
        bmesh.ops.translate(b, vec=(rim_r * 0.7 * math.cos(ca), out * (w * 0.5 - 0.09), rim_r * 0.7 * math.sin(ca)), verts=b.verts)
        m = bpy.data.meshes.new(name + "_caliper")
        b.to_mesh(m)
        b.free()
        m.materials.append(MATS["caliper"])
        new_object(name + "_caliper", m, hub)
        return hub

    # ---------------------------------------------------- safety car light bar

    def build_light_bar(self):
        """Roof light bar: a dark housing with amber lenses at the ends and
        green ones in the middle (lit by the game). One object, light_bar."""
        lb = self.s["light_bar"]
        c = self.s["cabin"]
        t = lb.get("t", lerp(c["side_windows"][0], c["side_windows"][1], 0.3))
        x = self.x_of(t)
        roof = interp_keys(c["stations"], t, "zt")
        hw = self.W * 0.5 * lb.get("width", 0.62)
        depth = lb.get("depth", 0.2)
        h = lb.get("height", 0.075)
        objs = []

        def box(cx, cy, cz, sx, sy, sz, mat):
            b = bmesh.new()
            bmesh.ops.create_cube(b, size=1.0)
            bmesh.ops.bevel(b, geom=b.edges[:], offset=min(sx, sy, sz) * 0.18, segments=2, affect="EDGES")
            bmesh.ops.scale(b, vec=(sx, sy, sz), verts=b.verts)
            bmesh.ops.translate(b, vec=(cx, cy, cz), verts=b.verts)
            m = bpy.data.meshes.new("lb")
            b.to_mesh(m)
            b.free()
            m.materials.append(MATS[mat])
            objs.append(new_object("lb", m))

        z0 = roof - 0.01
        # feet sunk into the curved roof, then the housing
        for sy in (-1, 1):
            box(x, sy * hw * 0.75, z0 + 0.0, depth * 0.6, 0.06, 0.06, "carbon")
        box(x, 0, z0 + 0.025 + h * 0.5, depth, hw * 2.0, h, "carbon")
        # lenses on top: amber at the ends, green in the middle
        n = 6
        seg = hw * 2.0 / n
        for i in range(n):
            y = -hw + seg * (i + 0.5)
            mat = "light_bar_green" if i in (2, 3) else "light_bar_amber"
            box(x, y, z0 + 0.025 + h * 0.6, depth * 0.88, seg * 0.88, h * 0.85, mat)
        ob = objs[0]
        ob.name = "light_bar"
        for o in objs[1:]:
            join_into(ob, o)
        shade_smooth(ob, 40)
        return ob

    # ---------------------------------------------------- markers

    def markers(self):
        c = self.s["cabin"]
        t = lerp(c["side_windows"][0], c["side_windows"][1], 0.45)
        roof = interp_keys(c["stations"], t, "zt")
        e = bpy.data.objects.new("number_roof", None)
        bpy.context.scene.collection.objects.link(e)
        e.location = (self.x_of(t), 0, roof + 0.004)
        nd = self.s.get("number_door", {"t": 0.48, "z": 0.55})
        for s, nm in ((1, "number_door_l"), (-1, "number_door_r")):
            e = bpy.data.objects.new(nm, None)
            bpy.context.scene.collection.objects.link(e)
            e.location = (self.x_of(nd["t"]), s * self.W * 0.5, nd["z"])
        hl = bpy.data.objects.new("headlights", None)
        bpy.context.scene.collection.objects.link(hl)
        hl.location = (self.x_front - 0.15, 0, self.s.get("headlight_z", 0.55))
        tl = bpy.data.objects.new("taillights", None)
        bpy.context.scene.collection.objects.link(tl)
        tl.location = (self.x_rear + 0.1, 0, self.s.get("taillight_z", 0.75))

    # ---------------------------------------------------- assemble

    def build(self):
        setup_materials(self.s)
        body = self.build_body()
        body.data.materials.clear()
        self.paint_regions(body)
        fb, rb = self.split_panels(body)
        for ob in (body, fb, rb):
            shade_smooth(ob, 48)
        cab = self.build_cabin()
        shade_smooth(cab, 50)
        for f in (self.build_splitter, self.build_diffuser, self.build_wing, self.build_interior):
            f()
        self.build_mirrors()
        if self.s.get("light_bar"):
            self.build_light_bar()
        for axle in (0, 1):
            for side in (1, -1):
                self.build_wheel(axle, side)
        self.markers()


def region_hit(r, t, yf, z, n):
    tt = r.get("t", [-1, 2])
    yy = r.get("y", [-2, 2])
    zz = r.get("z", [-1, 5])
    y = abs(yf) if r.get("mirror", True) else yf
    facing = r.get("facing", "any")
    if facing == "top" and n.z < 0.35:
        return False
    if facing == "side" and abs(n.y) < 0.45:
        return False
    if facing == "front" and n.x < 0.3:
        return False
    if facing == "rear" and n.x > -0.3:
        return False
    if facing == "frontish" and n.x < -0.1:
        return False
    if not (zz[0] <= z <= zz[1]):
        return False
    if r.get("shape") == "ellipse":
        ct = (tt[0] + tt[1]) * 0.5
        cy = (yy[0] + yy[1]) * 0.5
        dt = (t - ct) / max((tt[1] - tt[0]) * 0.5, 1e-4)
        dy = (y - cy) / max((yy[1] - yy[0]) * 0.5, 1e-4)
        return dt * dt + dy * dy <= 1.0
    if r.get("shape") == "slant":
        # parallelogram: y range moves with t (swept headlights)
        k = (t - tt[0]) / max(tt[1] - tt[0], 1e-4)
        if not (0 <= k <= 1):
            return False
        sh = r.get("slant", 0.0) * k
        return yy[0] + sh <= y <= yy[1] + sh
    return tt[0] <= t <= tt[1] and yy[0] <= y <= yy[1]


def airfoil(chord, thick, camber, n=14):
    """Cambered foil, points from trailing edge over the top and back (u along chord, v up)."""
    pts_top, pts_bot = [], []
    for i in range(n + 1):
        x = 0.5 - 0.5 * math.cos(i / n * math.pi)
        yt = 5 * thick * (0.2969 * math.sqrt(x) - 0.126 * x - 0.3516 * x * x + 0.2843 * x ** 3 - 0.1036 * x ** 4)
        p = 0.4
        yc = camber / p ** 2 * (2 * p * x - x * x) if x < p else camber / (1 - p) ** 2 * ((1 - 2 * p) + 2 * p * x - x * x)
        pts_top.append(((1 - x) * chord, (yc + yt) * chord))
        pts_bot.append(((1 - x) * chord, (yc - yt) * chord))
    # u measured from the trailing edge here; flip so u=0 is the leading edge
    top = [(chord - u, v) for (u, v) in pts_top]
    bot = [(chord - u, v) for (u, v) in pts_bot]
    ring = list(reversed(top)) + bot[1:-1]
    return ring


def join_into(target, other):
    """Merge other's mesh (in its world transform) into target, keeping materials."""
    bpy.context.view_layer.update()
    m = target.matrix_world.inverted() @ other.matrix_world
    me = other.data.copy()
    me.transform(m)
    bm = bmesh.new()
    bm.from_mesh(target.data)
    # map materials
    remap = []
    for mm in me.materials:
        if mm.name not in [x.name for x in target.data.materials]:
            target.data.materials.append(mm)
        remap.append([x.name for x in target.data.materials].index(mm.name))
    tmp = bmesh.new()
    tmp.from_mesh(me)
    for f in tmp.faces:
        f.material_index = remap[f.material_index] if remap else 0
    tmp.to_mesh(me)
    tmp.free()
    bm.from_mesh(me)
    bm.to_mesh(target.data)
    bm.free()
    old = other.data
    bpy.data.objects.remove(other)
    bpy.data.meshes.remove(old)
    bpy.data.meshes.remove(me)


def clear_scene():
    bpy.context.preferences.filepaths.save_version = 0
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob)
    for coll in (bpy.data.meshes, bpy.data.materials):
        for x in list(coll):
            coll.remove(x)


def build_car(cid):
    path = os.path.join(CARS_DATA, cid + ".json")
    if not os.path.exists(path):
        path = os.path.join(CARS_SPECIAL, cid + ".json")
    with open(path) as f:
        data = json.load(f)
    with open(os.path.join(SHAPES, cid + ".json")) as f:
        shape = json.load(f)
    if shape.get("hand_edited"):
        print("[cars] %s is hand edited, skipping" % cid)
        return
    shape["_colour"] = data.get("colour", "#cc2222")
    clear_scene()
    car = Car(cid, data, shape)
    car.build()
    os.makedirs(OUT_GLB, exist_ok=True)
    os.makedirs(OUT_BLEND, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT_BLEND, cid + ".blend"), compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT_GLB, cid + ".glb"), export_format="GLB",
                              export_apply=True, export_yup=True, export_extras=False,
                              export_cameras=False, export_lights=False)
    tris = sum(len(p.vertices) - 2 for ob in bpy.data.objects if ob.type == "MESH" for p in ob.data.polygons)
    print("[cars] built %s: %d triangles" % (cid, tris))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ids = argv or sorted(f[:-5] for f in os.listdir(SHAPES) if f.endswith(".json"))
    for cid in ids:
        build_car(cid)
    write_liveries()


def write_liveries():
    """Default livery per car for the game (modules/graphics/data/liveries.json)."""
    out = {}
    for f in sorted(os.listdir(SHAPES)):
        if f.endswith(".json"):
            with open(os.path.join(SHAPES, f)) as fh:
                s = json.load(fh)
            liv = dict(s.get("livery", {}))
            liv["front_overhang"] = s["front_overhang"]
            out[f[:-5]] = liv
    path = os.path.join(GFX, "data", "liveries.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(out, fh, indent=1)


if __name__ == "__main__":
    main()
