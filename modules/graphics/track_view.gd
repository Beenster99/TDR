class_name TrackView
extends Node3D
## The circuit in 3D, built once from TrackData (1 unit = 1 metre; the sim's
## 2D (x, y) is 3D (x, height, y)): grass terrain, asphalt with a rubbered
## racing line and edge lines, kerbs, tarmac and gravel run-off, walls and
## tyre barriers, start line and grid, and the pit lane. Trees, grandstands
## and pit buildings are added by Trackside.
##
## Heights come from TrackData when it has elevation (height_at /
## ground_height_at), otherwise the circuit is flat.

const ROAD_SHADER := preload("res://modules/graphics/shaders/road.gdshader")
const TERRAIN_SHADER := preload("res://modules/graphics/shaders/terrain.gdshader")

const K_ASPHALT := 1.0
const K_KERB := 0.75
const K_TARMAC := 0.5
const K_GRAVEL := 0.25
const K_PIT := 0.0

var track: TrackData
var env: SimEnvironment
var road_material: ShaderMaterial
var terrain_material: ShaderMaterial
var bounds := Rect2()                  ## everything built, in 2D metres
var curvature := PackedFloat64Array()  ## signed, + = turning right

## Clearance field: for each cell, roughly how far the nearest bit of tarmac
## (track or pit lane) is. Used to keep walls from folding at hairpins and
## to place trees and buildings away from the circuit.
const FIELD_CELL := 4.0
const FIELD_REACH := 90.0
var _field := PackedFloat32Array()
var _field_origin := Vector2.ZERO
var _field_size := Vector2i.ZERO
var _noise_tex: NoiseTexture2D


func setup(p_track: TrackData, p_env: SimEnvironment = null) -> void:
	track = p_track
	env = p_env
	curvature = _curvature()
	_bounds()
	_build_field()
	_noise_tex = _make_noise()
	road_material = ShaderMaterial.new()
	road_material.shader = ROAD_SHADER
	road_material.set_shader_parameter("noise", _noise_tex)
	road_material.set_shader_parameter("kerb_len", 1.0)
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = TERRAIN_SHADER
	terrain_material.set_shader_parameter("noise", _noise_tex)
	terrain_material.set_shader_parameter("stripe_angle", fposmod(track.seg_dir[0].angle(), PI))
	var has_elev := has_elevation()
	road_material.set_shader_parameter("rungs", 1.0 if GfxSettings.height_rungs and has_elev else 0.0)
	road_material.set_shader_parameter("hillshade", GfxSettings.hillshade if has_elev else 0.0)
	terrain_material.set_shader_parameter("hillshade", GfxSettings.hillshade if has_elev else 0.0)
	terrain_material.set_shader_parameter("contours", 1.0 if GfxSettings.contours and has_elev else 0.0)
	_build_terrain()
	_build_road()
	_build_walls()
	_build_markings()
	if track.has_pit_lane():
		_build_pit_lane()


## Sun direction for the hillshade cue (WorldView keeps it in step with the sun).
func set_light_dir(dir: Vector3) -> void:
	road_material.set_shader_parameter("light_dir", dir)
	terrain_material.set_shader_parameter("light_dir", dir)


func set_conditions(wetness: float, dry_line: float) -> void:
	road_material.set_shader_parameter("wetness", wetness)
	road_material.set_shader_parameter("dry_line", dry_line)
	terrain_material.set_shader_parameter("wetness", wetness)


# --- Heights (flat until TrackData has elevation) ----------------------------

func has_elevation() -> bool:
	return track.has_method("has_elevation") and track.call("has_elevation")


func height(s: float, off: float) -> float:
	return track.call("height_at", s, off) if track.has_method("height_at") else 0.0


func ground_height(p: Vector2) -> float:
	if track.has_method("ground_height_at"):
		return track.call("ground_height_at", p)
	return 0.0


## Height of the driving surface (track, pit lane or ground) under a point.
func surface_height(p: Vector2) -> float:
	if track.has_method("surface_height_at"):
		return track.call("surface_height_at", p)
	return 0.0


func surface_normal(p: Vector2) -> Vector3:
	if track.has_method("surface_normal_at"):
		return track.call("surface_normal_at", p)
	return Vector3.UP


func pit_height(d: float) -> float:
	return track.call("pit_height_at", d) if track.has_method("pit_height_at") else 0.0


# --- Clearance field ----------------------------------------------------------

func clearance(p: Vector2) -> float:
	var c := Vector2i(((p - _field_origin) / FIELD_CELL).floor())
	if c.x < 0 or c.y < 0 or c.x >= _field_size.x or c.y >= _field_size.y:
		return FIELD_REACH
	return _field[c.y * _field_size.x + c.x]


func _build_field() -> void:
	_field_origin = bounds.position
	_field_size = Vector2i((bounds.size / FIELD_CELL).ceil()) + Vector2i.ONE
	_field.resize(_field_size.x * _field_size.y)
	_field.fill(FIELD_REACH)
	var n := track.point_count()
	for i in range(0, n, 2):
		_stamp(track.points[i], maxf(track.width_left[i], track.width_right[i]))
	if track.has_pit_lane():
		for p in track.pit_path:
			_stamp(p, track.pit_width * 0.5)


func _stamp(p: Vector2, half_w: float) -> void:
	var r := int(ceil((FIELD_REACH + half_w) / FIELD_CELL))
	var c := Vector2i(((p - _field_origin) / FIELD_CELL).floor())
	for y in range(maxi(c.y - r, 0), mini(c.y + r + 1, _field_size.y)):
		var cy := _field_origin.y + (y + 0.5) * FIELD_CELL
		for x in range(maxi(c.x - r, 0), mini(c.x + r + 1, _field_size.x)):
			var cx := _field_origin.x + (x + 0.5) * FIELD_CELL
			var d := Vector2(cx, cy).distance_to(p) - half_w
			var k := y * _field_size.x + x
			if d < _field[k]:
				_field[k] = d


# --- Building blocks -----------------------------------------------------------

func _bounds() -> void:
	var lo := Vector2(INF, INF)
	var hi := -lo
	for p in track.points:
		lo = lo.min(p)
		hi = hi.max(p)
	for p in track.pit_path:
		lo = lo.min(p)
		hi = hi.max(p)
	var m := track.runoff + 420.0
	bounds = Rect2(lo - Vector2(m, m), hi - lo + Vector2(2 * m, 2 * m))


func _make_noise() -> NoiseTexture2D:
	var fn := FastNoiseLite.new()
	fn.seed = hash(track.id)
	fn.frequency = 0.02
	fn.fractal_octaves = 4
	var t := NoiseTexture2D.new()
	t.width = 512
	t.height = 512
	t.seamless = true
	t.noise = fn
	t.generate_mipmaps = true
	return t


func _curvature() -> PackedFloat64Array:
	var n := track.point_count()
	var out := PackedFloat64Array()
	out.resize(n)
	for i in n:
		var d1 := track.seg_dir[(i - 2 + n) % n]
		var d2 := track.seg_dir[(i + 2) % n]
		out[i] = d1.angle_to(d2) / 20.0
	return out


func _mesh_node(st: SurfaceTool, mat: Material, node_name: String, shadows := false) -> MeshInstance3D:
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


# --- Terrain -------------------------------------------------------------------

func _build_terrain() -> void:
	var cell := 12.0
	var nx := int(ceil(bounds.size.x / cell))
	var ny := int(ceil(bounds.size.y / cell))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lift := -0.05
	for y in ny + 1:
		for x in nx + 1:
			var p := bounds.position + Vector2(x, y) * cell
			var mown := 1.0 - smoothstep(track.runoff + 20.0, track.runoff + 60.0, clearance(p))
			st.set_color(Color(mown, 0, 0))
			st.set_uv(p)
			st.add_vertex(Vector3(p.x, ground_height(p) + lift, p.y))
	for y in ny:
		for x in nx:
			var a := y * (nx + 1) + x
			var b := a + 1
			var c := a + nx + 1
			var d := c + 1
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(b)
			st.add_index(d)
			st.add_index(c)
	var mi := _mesh_node(st, terrain_material, "Terrain")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if has_elevation() else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# --- Road ------------------------------------------------------------------------

## One band of the cross-section as a ribbon around the lap.
## offs(i) -> [inner, outer] lateral offsets (+ right); kind(i) -> COLOR.a.
func _ribbon(st: SurfaceTool, offs: Callable, kind: Callable, lift: float, lanes := 1) -> void:
	var n := track.point_count()
	var base := 0
	for i in n + 1:
		var k := i % n
		var p := track.points[k]
		var nrm := track.vertex_normal(k)
		var s := track.cum_s[k] if i < n else track.length
		var o: Array = offs.call(k)
		var rl := env.raceline_offset(k) if env else 0.0
		for l in lanes + 1:
			var off: float = lerpf(o[0], o[1], float(l) / lanes)
			var q := p + nrm * off
			var edge := minf(off + track.width_left[k], track.width_right[k] - off)
			var c := Color(1, 1, 1, kind.call(k))
			st.set_color(c)
			st.set_uv(Vector2(s, off))
			st.set_uv2(Vector2(off - rl, edge))
			st.add_vertex(Vector3(q.x, height(s, off) + lift, q.y))
	for i in n:
		for l in lanes:
			var a := base + i * (lanes + 1) + l
			var b := a + lanes + 1
			st.add_index(a)
			st.add_index(b)
			st.add_index(a + 1)
			st.add_index(a + 1)
			st.add_index(b)
			st.add_index(b + 1)


func _build_road() -> void:
	var kw := track.kerb_width
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# asphalt
	_ribbon(st, func(i): return [-track.width_left[i], track.width_right[i]], func(_i): return K_ASPHALT, 0.03, 6)
	_mesh_node(st, road_material, "Asphalt")
	# kerbs on corners (both sides), raised a touch
	for side in [-1.0, 1.0]:
		var ks := SurfaceTool.new()
		ks.begin(Mesh.PRIMITIVE_TRIANGLES)
		var sd: float = side
		_ribbon(ks, func(i):
			var e := track.width_right[i] if sd > 0 else track.width_left[i]
			var w := kw if absf(curvature[i]) > 0.006 else 0.0
			return [sd * e, sd * (e + w)] if sd > 0 else [sd * (e + w), sd * e],
			func(_i): return K_KERB, 0.06, 2)
		_mesh_node(ks, road_material, "Kerbs")
		# run-off beyond the kerb: gravel on the outside of fast corners,
		# a strip of old tarmac elsewhere
		var rs := SurfaceTool.new()
		rs.begin(Mesh.PRIMITIVE_TRIANGLES)
		_ribbon(rs, func(i):
			var e := (track.width_right[i] if sd > 0 else track.width_left[i]) + (kw if absf(curvature[i]) > 0.006 else 0.0)
			var w := _runoff_width(i, sd)
			return [sd * e, sd * (e + w)] if sd > 0 else [sd * (e + w), sd * e],
			func(i): return K_GRAVEL if _is_gravel(i, sd) else K_TARMAC, 0.02, 2)
		_mesh_node(rs, road_material, "Runoff")


## Outside of a corner = the side the car is thrown towards.
func _is_gravel(i: int, side: float) -> bool:
	var n := track.point_count()
	var c := 0.0
	for k in range(-6, 7):
		var ck := curvature[(i + k + n) % n]
		if absf(ck) > absf(c):
			c = ck
	return absf(c) > 0.012 and signf(c) == -side


func _runoff_width(i: int, side: float) -> float:
	if _is_gravel(i, side):
		return track.runoff * 0.6
	return minf(4.0, track.runoff * 0.3)


# --- Walls and tyre barriers ------------------------------------------------------

func _build_walls() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tyres: Array = []   ## [pos, dir] for the tyre walls
	var n := track.point_count()
	for side in [-1.0, 1.0]:
		var run: Array = []
		for i in n + 1:
			var k := i % n
			var e: float = track.width_right[k] if side > 0 else track.width_left[k]
			var off: float = side * (e + track.runoff)
			var q := track.points[k] + track.vertex_normal(k) * off
			var ok := clearance(q) > track.runoff - 2.5 and not _in_pit_area(q)
			if ok:
				run.append([q, track.cum_s[k], off, k])
			if (not ok or i == n) and run.size() >= 2:
				_wall(st, run)
				run = []
			elif not ok:
				run = []
			if ok and _is_gravel(k, side) and k % 2 == 0:
				tyres.append([q - track.vertex_normal(k) * side * 0.9, track.seg_dir[k]])
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	_mesh_node(st, mat, "Walls", true)
	_build_tyre_walls(tyres)


func _in_pit_area(q: Vector2) -> bool:
	if not track.has_pit_lane():
		return false
	var pr := track.project_pit(q)
	return pr.get("dist", INF) < track.pit_width * 0.5 + 6.0 if pr.has("dist") else false


func _wall(st: SurfaceTool, run: Array) -> void:
	var w := 0.4
	var h := 0.9
	for j in run.size() - 1:
		var a: Vector2 = run[j][0]
		var b: Vector2 = run[j + 1][0]
		var d := (b - a)
		if d.length() < 0.01 or d.length() > 30.0:
			continue
		var nn := Vector2(-d.y, d.x).normalized() * w * 0.5
		var ha := height(run[j][1], run[j][2])
		var hb := height(run[j + 1][1], run[j + 1][2])
		var shade: float = 0.72 if (int(run[j][1] / 6.0) % 2 == 0) else 0.8
		var top := Color(shade, shade, shade * 0.98)
		var face := Color(shade * 0.85, shade * 0.85, shade * 0.84)
		var quads := [
			[a - nn, b - nn, ha, hb, 0.0, h, face],
			[a + nn, b + nn, ha, hb, 0.0, h, face],
		]
		# top
		_quad(st, Vector3(a.x - nn.x, ha + h, a.y - nn.y), Vector3(b.x - nn.x, hb + h, b.y - nn.y),
			Vector3(b.x + nn.x, hb + h, b.y + nn.y), Vector3(a.x + nn.x, ha + h, a.y + nn.y), top)
		for q in quads:
			var p0: Vector2 = q[0]
			var p1: Vector2 = q[1]
			_quad(st, Vector3(p0.x, q[2], p0.y), Vector3(p1.x, q[3], p1.y),
				Vector3(p1.x, q[3] + h, p1.y), Vector3(p0.x, q[2] + h, p0.y), q[6])


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	st.set_color(col)
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)
	# and the back side, so walls look solid from any angle
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(b)
	st.add_vertex(a)
	st.add_vertex(d)
	st.add_vertex(c)


## Stacks of tyres in front of the wall where cars run wide.
func _build_tyre_walls(spots: Array) -> void:
	if spots.is_empty():
		return
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.32
	cyl.bottom_radius = 0.32
	cyl.height = 0.8
	cyl.radial_segments = 10
	cyl.rings = 1
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(1, 1, 1)
	m.roughness = 0.8
	cyl.material = m
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = cyl
	var xs: Array[Transform3D] = []
	var cs: Array[Color] = []
	for sp in spots:
		var p: Vector2 = sp[0]
		var d: Vector2 = sp[1]
		var nrm := Vector2(-d.y, d.x)
		for row in 2:
			for k in 8:
				var q := p + d * (k * 0.66 - 2.6) + nrm * (row * 0.62 - 0.31)
				xs.append(Transform3D(Basis(), Vector3(q.x, ground_height(q) + 0.4, q.y)))
				var band := (k + row) % 4 == 0
				cs.append(Color(0.85, 0.85, 0.85) if band else Color(0.08, 0.08, 0.08))
	mm.instance_count = xs.size()
	for i in xs.size():
		mm.set_instance_transform(i, xs[i])
		mm.set_instance_color(i, cs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "TyreWalls"
	mmi.multimesh = mm
	add_child(mmi)


# --- Painted markings ----------------------------------------------------------------

func _build_markings() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lift := 0.045
	# chequered start/finish line
	var n0 := track.vertex_normal(0)
	var d0 := track.seg_dir[0]
	var w := track.width_left[0] + track.width_right[0]
	var cells := int(w / 1.0)
	for k in cells:
		for row in 2:
			var c := Color(0.92, 0.92, 0.9) if (k + row) % 2 == 0 else Color(0.05, 0.05, 0.05)
			var p := track.points[0] - n0 * track.width_left[0] + n0 * k + d0 * (row - 1)
			_flat(st, p, p + d0, p + d0 + n0, p + n0, height(0.0, 0.0) + lift, c)
	# grid boxes
	for g in 16:
		var slot := track.grid_slot(g)
		var gp: Vector2 = slot["pos"]
		var gd := Vector2.from_angle(slot["heading"])
		var gn := Vector2(-gd.y, gd.x)
		var y := height(track.project(gp)["s"], 0.0) + lift
		var front := gp + gd * 2.6
		_flat(st, front - gn * 1.3, front - gn * 1.3 + gd * 0.2, front + gn * 1.3 + gd * 0.2, front + gn * 1.3, y, Color(0.9, 0.9, 0.88))
		for s in [-1.0, 1.0]:
			var a: Vector2 = front + gn * 1.3 * s
			_flat(st, a, a - gd * 1.2, a - gd * 1.2 - gn * 0.2 * s, a - gn * 0.2 * s, y, Color(0.9, 0.9, 0.88))
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.6
	_mesh_node(st, mat, "Markings")


func _flat(st: SurfaceTool, a: Vector2, b: Vector2, c: Vector2, d: Vector2, y: float, col: Color) -> void:
	st.set_color(col)
	st.set_normal(Vector3.UP)
	for v in [a, b, c, a, c, d]:
		st.add_vertex(Vector3(v.x, y, v.y))
	for v in [a, c, b, a, d, c]:
		st.add_vertex(Vector3(v.x, y, v.y))


# --- Pit lane ----------------------------------------------------------------------

func _build_pit_lane() -> void:
	var path := track.pit_path
	var w := track.pit_width
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var m := path.size()
	for i in m:
		var d := track.pit_cum[i]
		var dir := (path[mini(i + 1, m - 1)] - path[maxi(i - 1, 0)]).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		for l in 3:
			var off := lerpf(-w * 0.5 - 1.5, w * 0.5 + 1.5, l / 2.0)
			var q := path[i] + nrm * off
			st.set_color(Color(1, 1, 1, K_PIT))
			st.set_uv(Vector2(d, off))
			st.set_uv2(Vector2(99.0, 99.0))
			st.add_vertex(Vector3(q.x, pit_height(d) + 0.025, q.y))
	for i in m - 1:
		for l in 2:
			var a := i * 3 + l
			var b := a + 3
			st.add_index(a)
			st.add_index(b)
			st.add_index(a + 1)
			st.add_index(a + 1)
			st.add_index(b)
			st.add_index(b + 1)
	_mesh_node(st, road_material, "PitLane")
	# pit wall on the track side, speed-limit lines and the boxes
	var wall: Array = []
	var dd := track.pit_limit_start
	while dd <= track.pit_limit_end:
		var off := -track.pit_side * (w * 0.5 + 0.6)
		wall.append([track.pit_position_at(dd, off), 0.0, 0.0, 0])
		dd += 4.0
	if wall.size() >= 2:
		var ws := SurfaceTool.new()
		ws.begin(Mesh.PRIMITIVE_TRIANGLES)
		_wall(ws, wall)
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.85
		_mesh_node(ws, mat, "PitWall", true)
	var mk := SurfaceTool.new()
	mk.begin(Mesh.PRIMITIVE_TRIANGLES)
	for lim in [track.pit_limit_start, track.pit_limit_end]:
		var a := track.pit_position_at(lim, -w * 0.5)
		var b := track.pit_position_at(lim, w * 0.5)
		var dir := (b - a).normalized()
		var fwd := Vector2(dir.y, -dir.x) * 0.3
		_flat(mk, a, b, b + fwd, a + fwd, pit_height(lim) + 0.04, Color(0.9, 0.9, 0.88))
	var yellow := Color(0.95, 0.82, 0.2)
	for i in track.pit_box_count:
		var box := track.pit_box(i)
		var bd := Vector2.from_angle(box["heading"])
		var bn := Vector2(-bd.y, bd.x)
		var c: Vector2 = box["pos"]
		var y := pit_height(track.project_pit(c).get("d", 0.0)) + 0.04
		var corners := [c - bd * 2.6 - bn * 1.4, c + bd * 2.6 - bn * 1.4, c + bd * 2.6 + bn * 1.4, c - bd * 2.6 + bn * 1.4]
		for k in 4:
			var a: Vector2 = corners[k]
			var b: Vector2 = corners[(k + 1) % 4]
			var e := (b - a).normalized()
			var nn := Vector2(-e.y, e.x) * 0.12
			_flat(mk, a - nn, b - nn, b + nn, a + nn, y, yellow)
	var mmat := StandardMaterial3D.new()
	mmat.vertex_color_use_as_albedo = true
	mmat.roughness = 0.6
	_mesh_node(mk, mmat, "PitMarkings")
