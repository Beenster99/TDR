class_name Trackside
extends Node3D
## Things around the circuit: woods and lone trees, grandstands full of
## people on the main straight and the big corners, the pit garages and the
## paddock behind them, and the start gantry. All placed from the track's
## shape, the same every time for a given track.
## Trees are MultiMeshes in 256 m tiles so far tiles cull and use simpler
## meshes (automatic LODs).

const TILE := 256.0

var tv: TrackView
var track: TrackData
var rng := RandomNumberGenerator.new()
var _crowd_mat: ShaderMaterial
var _build_mat: StandardMaterial3D


func setup(p_tv: TrackView) -> void:
	tv = p_tv
	track = tv.track
	rng.seed = hash(track.id + "trackside")
	_build_mat = StandardMaterial3D.new()
	_build_mat.vertex_color_use_as_albedo = true
	_build_mat.roughness = 0.8
	_crowd_mat = ShaderMaterial.new()
	_crowd_mat.shader = preload("res://modules/graphics/shaders/crowd.gdshader")
	if GfxSettings.grandstands:
		_build_grandstands()
	if GfxSettings.buildings and track.has_pit_lane():
		_build_pit_buildings()
	_build_gantry()
	if GfxSettings.trees > 0.0:
		_build_trees()


# --- Trees ----------------------------------------------------------------------

func _build_trees() -> void:
	var forest := FastNoiseLite.new()
	forest.seed = rng.seed
	forest.frequency = 0.0035
	forest.fractal_octaves = 3
	var meshes := [_tree_mesh(false), _tree_mesh(true), _bush_mesh()]
	var tiles := {}   ## Vector2i -> [Array[Transform3D], Array[Color]] per mesh kind
	var spacing := 7.5 / sqrt(GfxSettings.trees)
	var b := tv.bounds
	var keep_out := track.runoff + 6.0
	var y := b.position.y
	while y < b.end.y:
		var x := b.position.x
		while x < b.end.x:
			var p := Vector2(x + rng.randf_range(-0.45, 0.45) * spacing, y + rng.randf_range(-0.45, 0.45) * spacing)
			x += spacing
			var c := tv.clearance(p)
			if c < keep_out or _occupied(p):
				continue
			var f := forest.get_noise_2dv(p) * 0.5 + 0.5
			# dense woods where the noise is high, scattered trees elsewhere,
			# and a lone line of trees just beyond the run-off
			var chance := smoothstep(0.52, 0.62, f) * 0.95 + 0.03
			if c < keep_out + 10.0:
				chance = maxf(chance, 0.12)
			if rng.randf() > chance:
				continue
			var kind := 0
			var r := rng.randf()
			if f > 0.6 and r < 0.35:
				kind = 1
			elif r > 0.9:
				kind = 2
			var s := rng.randf_range(0.75, 1.35) * (1.15 if f > 0.6 else 1.0)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.2), s))
			var t := Transform3D(basis, Vector3(p.x, tv.terrain_height(p) - 0.1, p.y))
			var key := Vector2i((p / TILE).floor())
			if not tiles.has(key):
				tiles[key] = [[[], []], [[], []], [[], []]]
			var hue := rng.randf()
			tiles[key][kind][0].append(t)
			tiles[key][kind][1].append(Color(hue, rng.randf(), 0, 0))
		y += spacing
	var mat := ShaderMaterial.new()
	mat.shader = _tree_shader()
	var count := 0
	for key in tiles:
		for kind in 3:
			var xs: Array = tiles[key][kind][0]
			if xs.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = meshes[kind]
			mm.instance_count = xs.size()
			for i in xs.size():
				mm.set_instance_transform(i, xs[i])
				mm.set_instance_custom_data(i, tiles[key][kind][1][i])
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = mat
			add_child(mmi)
			count += xs.size()
	print_verbose("[trackside] %d trees" % count)


var _blocked: Array[Rect2] = []


func _occupied(p: Vector2) -> bool:
	for r in _blocked:
		if r.has_point(p):
			return true
	return false


func _tree_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type spatial;
varying vec3 tint;
void vertex() {
	float h = INSTANCE_CUSTOM.r;
	vec3 dark = vec3(0.10, 0.20, 0.07);
	vec3 light = vec3(0.24, 0.36, 0.12);
	vec3 autumn = vec3(0.36, 0.34, 0.12);
	tint = mix(dark, light, h);
	tint = mix(tint, autumn, step(0.93, INSTANCE_CUSTOM.g) * 0.6);
	tint *= COLOR.rgb;
}
void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	BACKLIGHT = vec3(0.12, 0.18, 0.05);
}
"""
	return s


## Broadleaf tree: a short trunk under a lumpy crown of a few blobs.
func _tree_mesh(conifer: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk_col := Color(0.55, 0.42, 0.3)
	_cone(st, Vector3.ZERO, 0.35, 0.2, 3.0, 6, trunk_col)
	if conifer:
		for k in 4:
			var y := 2.0 + k * 2.6
			_cone(st, Vector3(0, y, 0), 3.4 - k * 0.75, 0.15, 4.2 - k * 0.5, 9, Color(0.75 + k * 0.08, 0.8 + k * 0.06, 0.8 + k * 0.05))
	else:
		var blobs := [[Vector3(0, 6.2, 0), 3.6], [Vector3(1.6, 5.4, 0.8), 2.6], [Vector3(-1.4, 5.6, -1.0), 2.7], [Vector3(0.3, 7.6, -0.4), 2.4]]
		for bl in blobs:
			_blob(st, bl[0], bl[1])
	st.generate_normals()
	return _with_lods(st.commit())


func _bush_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_blob(st, Vector3(0, 1.0, 0), 1.7)
	_blob(st, Vector3(1.0, 0.8, 0.5), 1.2)
	st.generate_normals()
	return _with_lods(st.commit())


func _with_lods(m: ArrayMesh) -> Mesh:
	var im := ImporterMesh.new()
	for s in m.get_surface_count():
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, m.surface_get_arrays(s))
	im.generate_lods(25.0, 60.0, [])
	return im.get_mesh()


## Low-poly lumpy sphere: an icosahedron split once, pushed in and out.
func _blob(st: SurfaceTool, c: Vector3, r: float) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var v := [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var f := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2],
		[10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11],
		[6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for tri in f:
		var a: Vector3 = v[tri[0]].normalized()
		var b: Vector3 = v[tri[1]].normalized()
		var cc: Vector3 = v[tri[2]].normalized()
		var ab := (a + b).normalized()
		var bc := (b + cc).normalized()
		var ca := (cc + a).normalized()
		for sub in [[a, ab, ca], [ab, b, bc], [ca, bc, cc], [ab, bc, ca]]:
			for p in sub:
				var q: Vector3 = p
				var bump := 1.0 + 0.12 * sin(q.x * 7.0 + q.z * 5.0) * cos(q.y * 6.0)
				var shade := 0.7 + 0.45 * clampf(q.y * 0.5 + 0.5, 0.0, 1.0)
				st.set_color(Color(shade, shade, shade))
				st.add_vertex(c + Vector3(q.x, q.y * 0.85, q.z) * r * bump)


func _cone(st: SurfaceTool, base: Vector3, r0: float, r1: float, h: float, seg: int, col: Color) -> void:
	for k in seg:
		var a0 := TAU * k / seg
		var a1 := TAU * (k + 1) / seg
		var p0 := base + Vector3(cos(a0) * r0, 0, sin(a0) * r0)
		var p1 := base + Vector3(cos(a1) * r0, 0, sin(a1) * r0)
		var q0 := base + Vector3(cos(a0) * r1, h, sin(a0) * r1)
		var q1 := base + Vector3(cos(a1) * r1, h, sin(a1) * r1)
		st.set_color(col * 0.75)
		st.add_vertex(p0)
		st.add_vertex(q1)
		st.add_vertex(p1)
		st.set_color(col)
		st.add_vertex(p0)
		st.add_vertex(q0)
		st.add_vertex(q1)


# --- Grandstands --------------------------------------------------------------------

func _build_grandstands() -> void:
	var main_side := -track.pit_side if track.has_pit_lane() else 1.0
	_grandstand(-160.0, 120.0, main_side, 14.0, true)
	# the slowest corners get stands on the outside
	var picks: Array = []
	var n := track.point_count()
	var order := range(n)
	order.sort_custom(func(a, b): return absf(tv.curvature[a]) > absf(tv.curvature[b]))
	for i in order:
		if picks.size() >= 4 or absf(tv.curvature[i]) < 0.01:
			break
		var s := track.cum_s[i]
		var ok := absf(s) > 300.0 and absf(s - track.length) > 300.0
		for p in picks:
			var ds := absf(s - p)
			ok = ok and minf(ds, track.length - ds) > 350.0
		if ok:
			picks.append(s)
			var outside := -signf(tv.curvature[i])
			_grandstand(s - 45.0, s + 45.0, outside, 11.0, false)


## A stand along the track from s0 to s1, on side (+1 right), set back
## behind the wall: stepped seating full of people, a back wall and a roof.
func _grandstand(s0: float, s1: float, side: float, depth: float, roof: bool) -> void:
	var setback := track.runoff + 5.0
	var steps := 9
	var rise := 0.8
	var pts: Array = []
	var s := s0
	while s <= s1:
		var ss := fposmod(s, track.length)
		var i := track.index_at(ss)
		var e: float = track.width_right[i] if side > 0 else track.width_left[i]
		var off: float = side * (e + setback)
		var p := track.position_at(ss, off)
		var nrm := track.vertex_normal(i) * side
		pts.append([p, nrm, tv.terrain_height(p)])
		s += 6.0
	if pts.size() < 3:
		return
	# skip if the footprint lands on another bit of the circuit
	for p in pts:
		for k in [0.0, depth * 0.5, depth]:
			var q: Vector2 = p[0] + p[1] * k
			if tv.clearance(q) < track.runoff * 0.6:
				return
	var seats := SurfaceTool.new()
	seats.begin(Mesh.PRIMITIVE_TRIANGLES)
	var shell := SurfaceTool.new()
	shell.begin(Mesh.PRIMITIVE_TRIANGLES)
	var concrete := Color(0.62, 0.62, 0.6)
	for j in pts.size() - 1:
		var a: Vector2 = pts[j][0]
		var b: Vector2 = pts[j + 1][0]
		var na: Vector2 = pts[j][1]
		var nb: Vector2 = pts[j + 1][1]
		var y0: float = pts[j][2]
		for k in steps:
			var d0 := depth * k / steps
			var d1 := depth * (k + 1) / steps
			var h := y0 + rise * (k + 1)
			# tread
			_q3(seats, Vector3(a.x + na.x * d0, h, a.y + na.y * d0), Vector3(b.x + nb.x * d0, h, b.y + nb.y * d0),
				Vector3(b.x + nb.x * d1, h, b.y + nb.y * d1), Vector3(a.x + na.x * d1, h, a.y + na.y * d1), Color.WHITE)
			# riser
			_q3(shell, Vector3(a.x + na.x * d0, h - rise, a.y + na.y * d0), Vector3(b.x + nb.x * d0, h - rise, b.y + nb.y * d0),
				Vector3(b.x + nb.x * d0, h, b.y + nb.y * d0), Vector3(a.x + na.x * d0, h, a.y + na.y * d0), concrete)
		var top := y0 + rise * steps
		# back wall (up to the roof on covered stands)
		var wall_top := top + (4.5 if roof else 1.2)
		_q3(shell, Vector3(a.x + na.x * depth, y0, a.y + na.y * depth), Vector3(b.x + nb.x * depth, y0, b.y + nb.y * depth),
			Vector3(b.x + nb.x * depth, wall_top, b.y + nb.y * depth), Vector3(a.x + na.x * depth, wall_top, a.y + na.y * depth), concrete * 0.9)
		if roof:
			var ry := top + 4.5
			var r0 := depth * 0.55
			var col := Color(0.62, 0.64, 0.66) if j % 6 != 0 else Color(0.5, 0.52, 0.55)
			_q3(shell, Vector3(a.x + na.x * r0, ry + 0.6, a.y + na.y * r0), Vector3(b.x + nb.x * r0, ry + 0.6, b.y + nb.y * r0),
				Vector3(b.x + nb.x * (depth + 0.3), ry, b.y + nb.y * (depth + 0.3)), Vector3(a.x + na.x * (depth + 0.3), ry, a.y + na.y * (depth + 0.3)), col)
	_commit(seats, _crowd_mat, "Grandstand")
	_commit(shell, _build_mat, "GrandstandShell")
	_block_area(pts, depth + 4.0)


func _block_area(pts: Array, depth: float) -> void:
	var r := Rect2(pts[0][0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p[0])
		r = r.expand(p[0] + p[1] * depth)
	_blocked.append(r.grow(4.0))


func _q3(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	st.set_color(col)
	for v in [a, b, c, a, c, d, a, c, b, a, d, c]:
		st.add_vertex(v)


func _commit(st: SurfaceTool, mat: Material, node_name: String) -> void:
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = st.commit()
	mi.material_override = mat
	add_child(mi)


# --- Pit garages and paddock ---------------------------------------------------------

func _build_pit_buildings() -> void:
	var w := track.pit_width
	var d0 := track.pit_limit_start
	var d1 := track.pit_limit_end
	var side := track.pit_side
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var depth := 16.0
	var h := 8.0
	var front := w * 0.5 + 3.0
	var pts: Array = []
	var d := d0
	while d <= d1:
		pts.append([track.pit_position_at(d, side * front), track.pit_position_at(d, side * (front + depth)),
			track.pit_position_at(d, side * (front + depth + 40.0)), d])
		d += 5.0
	if pts.size() < 2:
		return
	var roof := Color(0.8, 0.81, 0.82)
	var door := Color(0.12, 0.12, 0.14)
	var wall := Color(0.68, 0.68, 0.7)
	for j in pts.size() - 1:
		var a0: Vector2 = pts[j][0]
		var a1: Vector2 = pts[j][1]
		var b0: Vector2 = pts[j + 1][0]
		var b1: Vector2 = pts[j + 1][1]
		var ya: float = track.pit_height_at(pts[j][3])
		var yb: float = ya
		var rc := roof if j % 8 != 0 else roof * 0.9
		_q3(st, Vector3(a0.x, ya + h, a0.y), Vector3(b0.x, yb + h, b0.y), Vector3(b1.x, yb + h, b1.y), Vector3(a1.x, ya + h, a1.y), rc)
		_q3(st, Vector3(a0.x, ya, a0.y), Vector3(b0.x, yb, b0.y), Vector3(b0.x, yb + h, b0.y), Vector3(a0.x, ya + h, a0.y), door if j % 2 == 0 else wall)
		_q3(st, Vector3(a1.x, ya, a1.y), Vector3(b1.x, yb, b1.y), Vector3(b1.x, yb + h, b1.y), Vector3(a1.x, ya + h, a1.y), wall)
	# rooftop plant: a few boxes
	for k in range(2, pts.size() - 2, 7):
		var c: Vector2 = (pts[k][0] + pts[k][1]) * 0.5
		_box(st, c, 2.5, 2.0, h, 1.2, Color(0.55, 0.56, 0.58))
	# paddock: rows of team trucks and hospitality units behind the garages
	var team_cols := [Color(0.85, 0.1, 0.1), Color(0.1, 0.25, 0.7), Color(0.95, 0.95, 0.95), Color(0.1, 0.1, 0.1),
		Color(0.95, 0.5, 0.05), Color(0.1, 0.55, 0.3), Color(0.9, 0.8, 0.1), Color(0.6, 0.6, 0.62)]
	var dd := d0 + 10.0
	var k := 0
	while dd < d1 - 10.0:
		for row in 2:
			var off := side * (front + depth + 8.0 + row * 9.0)
			var c := track.pit_position_at(dd, off)
			var dir := Vector2.from_angle(track.pit_heading_at(dd))
			if tv.clearance(c) > 12.0:
				_truck(st, c, dir, team_cols[(k + row * 3) % team_cols.size()])
		dd += 12.0
		k += 1
	_commit(st, _build_mat, "PitBuildings")
	var r := Rect2(pts[0][0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p[0])
		r = r.expand(p[2])
	_blocked.append(r.grow(6.0))


func _box(st: SurfaceTool, c: Vector2, sx: float, sz: float, y: float, h: float, col: Color) -> void:
	var a := Vector3(c.x - sx * 0.5, y, c.y - sz * 0.5)
	var b := Vector3(c.x + sx * 0.5, y, c.y - sz * 0.5)
	var cc := Vector3(c.x + sx * 0.5, y, c.y + sz * 0.5)
	var d := Vector3(c.x - sx * 0.5, y, c.y + sz * 0.5)
	var up := Vector3(0, h, 0)
	_q3(st, a + up, b + up, cc + up, d + up, col)
	_q3(st, a, b, b + up, a + up, col * 0.85)
	_q3(st, b, cc, cc + up, b + up, col * 0.8)
	_q3(st, cc, d, d + up, cc + up, col * 0.85)
	_q3(st, d, a, a + up, d + up, col * 0.8)


## An articulated truck seen from above: cab plus trailer in team colours.
func _truck(st: SurfaceTool, c: Vector2, dir: Vector2, col: Color) -> void:
	var nrm := Vector2(-dir.y, dir.x)
	var y := tv.terrain_height(c)
	for part in [[0.0, 13.6, 4.0, col], [8.0, 2.4, 3.6, Color(0.9, 0.9, 0.9)]]:
		var mid: Vector2 = c + dir * (part[0] - 1.5)
		var hl: float = part[1] * 0.5
		var hw := 1.25
		var h: float = part[2]
		var p := [mid - dir * hl - nrm * hw, mid + dir * hl - nrm * hw, mid + dir * hl + nrm * hw, mid - dir * hl + nrm * hw]
		var v := []
		for q in p:
			v.append(Vector3(q.x, y, q.y))
		var up := Vector3(0, h, 0)
		var pc: Color = part[3]
		_q3(st, v[0] + up, v[1] + up, v[2] + up, v[3] + up, pc)
		for k in 4:
			_q3(st, v[k], v[(k + 1) % 4], v[(k + 1) % 4] + up, v[k] + up, pc * 0.8)


# --- Start gantry ---------------------------------------------------------------------

func _build_gantry() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var p := track.points[0]
	var nrm := track.vertex_normal(0)
	var d := track.seg_dir[0]
	var reach_l := track.width_left[0] + 2.0
	var reach_r := track.width_right[0] + 2.0
	var h := 6.5
	var y := tv.height(0.0, 0.0)
	var a := p - nrm * reach_l + d * 3.0
	var b := p + nrm * reach_r + d * 3.0
	var dark := Color(0.15, 0.15, 0.17)
	for q in [a, b]:
		_box(st, q, 0.6, 0.6, y, h + 1.2, dark)
	# beam across
	var e := (b - a).normalized()
	var m := (a + b) * 0.5
	var hl := a.distance_to(b) * 0.5
	var bw := 0.9
	var corners := [m - e * hl - d * bw * 0.5, m + e * hl - d * bw * 0.5, m + e * hl + d * bw * 0.5, m - e * hl + d * bw * 0.5]
	var v := []
	for q in corners:
		v.append(Vector3(q.x, y + h, q.y))
	var up := Vector3(0, 1.2, 0)
	_q3(st, v[0] + up, v[1] + up, v[2] + up, v[3] + up, dark)
	for k in 4:
		_q3(st, v[k], v[(k + 1) % 4], v[(k + 1) % 4] + up, v[k] + up, dark * 1.3)
	_commit(st, _build_mat, "StartGantry")
