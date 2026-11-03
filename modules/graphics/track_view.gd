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
const FIELD_CELL := 6.0
const FIELD_REACH := 90.0
var _field := PackedFloat32Array()
var _field_origin := Vector2.ZERO
var _field_size := Vector2i.ZERO
var _field_idx := PackedInt32Array()
var _field_td := PackedFloat32Array()   ## distance to the track only (for _field_idx)
var _pit_rect := Rect2()
var _joker_rect := Rect2()   ## around the rallycross joker lane and its verge
## Terrain mesh heights as built (row by row), for terrain_mesh_height.
var _terrain_h := PackedFloat32Array()
var _terrain_grid := Rect2()
var _terrain_cell := 10.0
var _terrain_n := Vector2i.ZERO
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
	road_material.set_shader_parameter("hillshade", GfxSettings.hillshade if has_elev else 0.0)
	terrain_material.set_shader_parameter("hillshade", GfxSettings.hillshade if has_elev else 0.0)
	_build_terrain()
	_build_road()
	_build_walls()
	_build_markings()
	if not track.jumps.is_empty():
		_build_jump_markings()
	if track.has_pit_lane():
		_build_pit_lane()
	if track.has_joker():
		_build_joker()
		_build_joker_posts()


## The rallycross joker lane: a road the joker's width along its path (dirt
## or tarmac as the track data says), with a narrow verge each side, drawn a
## touch above the lap where the two share the ground at each end.
const JOKER_LIFT := 0.045
func _build_joker() -> void:
	var path := track.joker_path
	var h := track.joker_width * 0.5
	var m := path.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Separate strips for the road and each verge, so the surface kind
	# doesn't blend across their edge (a blend through the kerb band would
	# draw a red and white stripe there).
	var strips := [[-h - 1.2, -h], [-h, -h * 0.5, 0.0, h * 0.5, h], [h, h + 1.2]]
	var base := 0
	for across in strips:
		var cols: int = across.size()
		var hint := -1
		for i in m:
			var d := track.joker_cum[i]
			var dir := (path[mini(i + 1, m - 1)] - path[maxi(i - 1, 0)]).normalized()
			var nrm := Vector2(-dir.y, dir.x)
			var dirt := track.joker_dirt_at(d)
			var shoulder: bool = cols == 2
			var kind := (K_GRAVEL if dirt > 0.5 else K_TARMAC) if shoulder else K_ASPHALT
			for c in cols:
				var off: float = across[c]
				var q := path[i] + nrm * off
				var qt := track.project(q, hint)
				hint = qt["idx"]
				st.set_color(Color(1.0 - dirt, 1, 1, kind))
				st.set_uv(Vector2(d, off))
				st.set_uv2(Vector2(off, h - absf(off)))
				st.add_vertex(Vector3(q.x, track.surface_height_at(q, qt["idx"]) + JOKER_LIFT, q.y))
		for i in m - 1:
			for l in cols - 1:
				var a := base + i * cols + l
				var b := a + cols
				st.add_index(a)
				st.add_index(b)
				st.add_index(a + 1)
				st.add_index(a + 1)
				st.add_index(b)
				st.add_index(b + 1)
		base += m * cols
	_mesh_node(st, road_material, "Joker")


## Orange and white marker posts along both edges of the joker lane, where it
## has left the lap, so the joker reads from above at any zoom.
const JOKER_POST_GAP_M := 5.0
func _build_joker_posts() -> void:
	var post := BoxMesh.new()
	post.size = Vector3(0.7, 1.3, 0.7)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.6
	post.material = m
	var xs: Array[Transform3D] = []
	var cs: Array[Color] = []
	var path := track.joker_path
	var off := track.joker_width * 0.5 + 0.9
	var d := 0.0
	var k := 0
	while d <= track.joker_length:
		var i := clampi(track.joker_cum.bsearch(d) - 1, 0, path.size() - 2)
		var a := path[i]
		var b := path[i + 1]
		var span := maxf(track.joker_cum[i + 1] - track.joker_cum[i], 0.001)
		var p := a.lerp(b, clampf((d - track.joker_cum[i]) / span, 0.0, 1.0))
		var dir := (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		for side in [-1.0, 1.0]:
			var q: Vector2 = p + nrm * off * side
			# Only beside the lane, not out on the lap where the two meet.
			if clearance_lap(q) > 1.0:
				xs.append(Transform3D(Basis(), Vector3(q.x, track.surface_height_at(q) + 0.65, q.y)))
				cs.append(Color(1.0, 0.45, 0.05) if k % 2 == 0 else Color(0.95, 0.95, 0.92))
		d += JOKER_POST_GAP_M
		k += 1
	if xs.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = post
	mm.instance_count = xs.size()
	for j in xs.size():
		mm.set_instance_transform(j, xs[j])
		mm.set_instance_color(j, cs[j])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "JokerPosts"
	mmi.multimesh = mm
	add_child(mmi)


## How far q is outside the lap's road and kerbs (negative = on them).
func clearance_lap(q: Vector2) -> float:
	var t := track.project(q)
	var o: float = t["offset"]
	return absf(o) - ((t["w_right"] if o >= 0.0 else t["w_left"]) + track.kerb_width)


## Sun direction for the hillshade cue (WorldView keeps it in step with the sun).
func set_light_dir(dir: Vector3) -> void:
	road_material.set_shader_parameter("light_dir", dir)
	terrain_material.set_shader_parameter("light_dir", dir)


func set_conditions(wetness: float, dry_line: float) -> void:
	road_material.set_shader_parameter("wetness", wetness)
	road_material.set_shader_parameter("dry_line", dry_line)
	terrain_material.set_shader_parameter("wetness", wetness)


# --- Heights (all flat on a track without elevation data) -------------------

func has_elevation() -> bool:
	return track.has_elevation()


func height(s: float, off: float) -> float:
	return track.height_at(s, off)


func ground_height(p: Vector2) -> float:
	return track.ground_height_at(p)


## Height of the driving surface (track, pit lane, run-off easing into the
## hillside) under a point. hint = a nearby centre-line index (-1 = search all).
func surface_height(p: Vector2, hint := -1) -> float:
	if not track.has_elevation():
		return 0.0
	if hint < 0:
		hint = nearest_index(p)
	return track.surface_height_at(p, hint)


func surface_normal(p: Vector2, hint := -1) -> Vector3:
	if not track.has_elevation():
		return Vector3.UP
	if hint < 0:
		hint = nearest_index(p)
	return track.surface_normal_at(p, hint)


## Height of the terrain mesh at a point (what trees and buildings stand on):
## the hillside, easing into the road's edges near the circuit (the same
## blend as TrackData.surface_height_at, done locally so it's fast).
func terrain_height(p: Vector2) -> float:
	if not track.has_elevation():
		return 0.0
	if clearance(p) >= track.runoff + 70.0:
		return track.ground_height_at(p)
	if _pit_rect.has_point(p) or _joker_rect.has_point(p):
		return track.surface_height_at(p, nearest_index(p))
	var i := nearest_index(p)
	var d := track.seg_dir[i]
	var rel := p - track.points[i]
	var s := track.cum_s[i] + rel.dot(d)
	var off := rel.dot(Vector2(-d.y, d.x))
	var edge: float = (track.width_right[i] if off >= 0.0 else track.width_left[i]) + track.kerb_width
	var road := track.height_at(s, clampf(off, -edge, edge))
	if absf(off) <= edge:
		return road
	var t := clampf((absf(off) - edge) / (track.runoff + 60.0), 0.0, 1.0)
	return lerpf(road, track.ground_height_at(p), t * t * (3.0 - 2.0 * t))


## Height of the grass mesh as drawn (its triangles, not the smooth
## hillside), so a car off the road can be kept on top of it.
## The terrain grid as built: [origin, cell size m, points per side, lowest
## and highest point]. Scenery lays its land cover on it.
func terrain_grid() -> Array:
	var lo := INF
	var hi := -INF
	for h in _terrain_h:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	return [_terrain_grid.position, _terrain_cell, _terrain_n, lo, hi]


func terrain_mesh_height(p: Vector2, _hint := -1) -> float:
	if _terrain_h.is_empty():
		return -INF
	var g := (p - _terrain_grid.position) / _terrain_cell
	var x := clampi(int(floor(g.x)), 0, _terrain_n.x - 2)
	var y := clampi(int(floor(g.y)), 0, _terrain_n.y - 2)
	var fx := clampf(g.x - x, 0.0, 1.0)
	var fy := clampf(g.y - y, 0.0, 1.0)
	var a := _terrain_h[y * _terrain_n.x + x]
	var b := _terrain_h[y * _terrain_n.x + x + 1]
	var c := _terrain_h[(y + 1) * _terrain_n.x + x]
	var d := _terrain_h[(y + 1) * _terrain_n.x + x + 1]
	if fx + fy <= 1.0:   # triangle a-b-c (the cells are split from b to c)
		return a + (b - a) * fx + (c - a) * fy
	return d + (c - d) * (1.0 - fx) + (b - d) * (1.0 - fy)


func pit_height(d: float) -> float:
	return track.pit_height_at(d)


# --- Clearance field ----------------------------------------------------------

## Nearest centre-line point index (from the clearance field; cheap).
func nearest_index(p: Vector2) -> int:
	var c := Vector2i(((p - _field_origin) / FIELD_CELL).floor())
	if c.x < 0 or c.y < 0 or c.x >= _field_size.x or c.y >= _field_size.y:
		return 0
	return maxi(_field_idx[c.y * _field_size.x + c.x], 0)


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
	_field_idx.resize(_field.size())
	_field_idx.fill(0)
	_field_td.resize(_field.size())
	_field_td.fill(INF)
	var n := track.point_count()
	if track.has_pit_lane():
		_pit_rect = Rect2(track.pit_path[0], Vector2.ZERO)
		for p in track.pit_path:
			_stamp(p, track.pit_width * 0.5, -1)
			_pit_rect = _pit_rect.expand(p)
		_pit_rect = _pit_rect.grow(track.pit_width + 40.0)
	for i in range(0, n, 2):
		_stamp(track.points[i], maxf(track.width_left[i], track.width_right[i]), i)
	if track.has_joker():
		_joker_rect = Rect2(track.joker_path[0], Vector2.ZERO)
		for p in track.joker_path:
			_joker_rect = _joker_rect.expand(p)
		_joker_rect = _joker_rect.grow(track.joker_width + 40.0)
	for p in track.joker_path:
		_stamp(p, track.joker_width * 0.5, -1)


## idx = centre-line point (-1 for the pit lane: it only blocks, the nearest
## track point is still recorded from the track stamps).
func _stamp(p: Vector2, half_w: float, idx: int) -> void:
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
			if idx >= 0 and d < _field_td[k]:
				_field_td[k] = d
				_field_idx[k] = idx


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
	for p in track.joker_path:
		lo = lo.min(p)
		hi = hi.max(p)
	var m := track.runoff + 420.0
	bounds = Rect2(lo - Vector2(m, m), hi - lo + Vector2(2 * m, 2 * m))
	# Fill a widescreen (or tall) window at the whole-track zoom in any
	# direction: the camera can turn with the car.
	var side := maxf(bounds.size.x, bounds.size.y) * 1.5
	bounds = Rect2(bounds.get_center() - Vector2(side, side) * 0.5, Vector2(side, side))


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
	var cell := 16.0 if not has_elevation() else 10.0
	var has_elev := has_elevation()
	var nx := int(ceil(bounds.size.x / cell))
	var ny := int(ceil(bounds.size.y / cell))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_terrain_h = PackedFloat32Array()
	for y in ny + 1:
		for x in nx + 1:
			var p := bounds.position + Vector2(x, y) * cell
			var cl := clearance(p)
			var mown := 1.0 - smoothstep(track.runoff + 20.0, track.runoff + 60.0, cl)
			# near the circuit the ground eases into the road's edges
			# sink the grass a little under the run-off so tarmac never clips
			var hy := terrain_height(p) - (0.3 if cl < track.runoff + 8.0 else 0.05)
			_terrain_h.append(hy)
			st.set_color(Color(mown, 0, 0))
			st.set_uv(p)
			st.add_vertex(Vector3(p.x, hy, p.y))
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
	_terrain_grid = Rect2(bounds.position, Vector2(nx, ny) * cell)
	_terrain_cell = cell
	_terrain_n = Vector2i(nx + 1, ny + 1)
	# the grid's heights for the shader: it lights the grass from them and
	# lays Scenery's land cover (fields, roads, water...) on the same triangles
	var img := Image.create_from_data(_terrain_n.x, _terrain_n.y, false, Image.FORMAT_RF, _terrain_h.to_byte_array())
	terrain_material.set_shader_parameter("heights", ImageTexture.create_from_image(img))
	terrain_material.set_shader_parameter("grid_origin", bounds.position)
	terrain_material.set_shader_parameter("grid_cell", cell)
	terrain_material.set_shader_parameter("grid_n", _terrain_n)
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
			var kd: float = kind.call(k)
			var dirt := track.dirt_at(s) if kd > 0.875 and track.has_dirt() else 0.0
			var c := Color(1.0 - dirt, 1, 1, kd)
			st.set_color(c)
			st.set_uv(Vector2(s, off))
			st.set_uv2(Vector2(off - rl, edge))
			st.add_vertex(Vector3(q.x, _surface_y(k, s, off, q) + lift + _crossover_lift(s, lift), q.y))
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


## Where a derby arena's road crosses itself, the second pass is drawn a
## touch above the first (they're at the same height, so they'd flicker).
func _crossover_lift(s: float, lift: float) -> float:
	if track.crossovers.is_empty() or lift < 0.025:
		return 0.0
	return 0.012 if track.crossover_upper(s, 30.0) else 0.0


## Height of the driving surface at a ribbon vertex. On the road and kerbs
## it is the road's own cross-section; beyond the kerb it is exactly the
## height a car there is drawn at (the same blend as
## TrackData.surface_height_at: the run-off eases from the road's edge into
## the hillside), so a car in a gravel trap or on a run-off never sinks under
## the mesh it is driving on.
func _surface_y(k: int, s: float, off: float, q: Vector2) -> float:
	var edge: float = (track.width_right[k] if off >= 0.0 else track.width_left[k]) + track.kerb_width
	if absf(off) <= edge + 0.01 or not has_elevation():
		return height(s, off)
	if _pit_rect.has_point(q) or _joker_rect.has_point(q):   # the ground eases into the pit lane / joker here
		return track.surface_height_at(q, k)
	var road := height(s, signf(off) * edge)
	if track.terrain_size == Vector2i.ZERO:
		return road
	var t := clampf((absf(off) - edge) / (track.runoff + 60.0), 0.0, 1.0)
	return lerpf(road, track.ground_height_at(q), t * t * (3.0 - 2.0 * t))


func _build_road() -> void:
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
			var w := _kerb_w(i, sd)
			return [sd * e, sd * (e + w)] if sd > 0 else [sd * (e + w), sd * e],
			func(_i): return K_KERB, 0.06, 2)
		_mesh_node(ks, road_material, "Kerbs")
		# run-off beyond the kerb: gravel on the outside of fast corners,
		# a strip of old tarmac elsewhere
		var rs := SurfaceTool.new()
		rs.begin(Mesh.PRIMITIVE_TRIANGLES)
		_ribbon(rs, func(i):
			var e := (track.width_right[i] if sd > 0 else track.width_left[i]) + _kerb_w(i, sd)
			var w := _runoff_width(i, sd)
			return [sd * e, sd * (e + w)] if sd > 0 else [sd * (e + w), sd * e],
			func(i): return K_GRAVEL if _is_gravel(i, sd) else K_TARMAC, 0.02, 2)
		_mesh_node(rs, road_material, "Runoff")


## Kerb width at point i on side sd: kerbs on corners, but none on dirt
## (rallycross) or where the joker lane runs alongside.
func _kerb_w(i: int, sd: float) -> float:
	if absf(curvature[i]) <= 0.006 or track.dirt_at(track.cum_s[i]) >= 0.3:
		return 0.0
	if track.discipline == "derby":   # no kerbs in a derby arena (they'd cross the other road at the crossovers)
		return 0.0
	if track.has_joker():
		var e := track.width_right[i] if sd > 0 else track.width_left[i]
		var q := track.points[i] + track.right_normal(i) * sd * (e + track.kerb_width * 0.5)
		if track.project_joker(q)["dist"] < track.joker_width * 0.5 + 1.5:
			return 0.0
	return track.kerb_width


## Gravel trap here? From the track data where it has run-off surfaces,
## else on the outside of a corner (the side the car is thrown towards).
func _is_gravel(i: int, side: float) -> bool:
	var ro := track.runoff_right if side > 0 else track.runoff_left
	if ro.size() == track.point_count():
		return ro[i] == TrackData.Surface.GRAVEL
	var n := track.point_count()
	var c := 0.0
	for k in range(-6, 7):
		var ck := curvature[(i + k + n) % n]
		if absf(ck) > absf(c):
			c = ck
	return absf(c) > 0.012 and signf(c) == -side


func _runoff_width(i: int, side: float) -> float:
	var ro := track.runoff_right if side > 0 else track.runoff_left
	var w := minf(4.0, track.runoff * 0.3)
	if ro.size() == track.point_count() and ro[i] != TrackData.Surface.GRASS:
		w = track.runoff - track.kerb_width - 0.5   # gravel trap or paved run-off, as wide as it drives
	elif _is_gravel(i, side):
		w = track.runoff * 0.6
	# On the inside of a tight corner the run-off can't reach past the
	# corner's centre, or the strip folds over itself in a big fan.
	var n := track.point_count()
	var c := 0.0
	for k in range(-8, 9):
		var ck := curvature[(i + k + n) % n]
		if signf(ck) == side and absf(ck) > absf(c):
			c = ck
	if absf(c) > 1e-4:
		var e := (track.width_right[i] if side > 0 else track.width_left[i]) + track.kerb_width
		w = clampf(0.8 / absf(c) - e, 0.0, w)
	# Beside the pit lane the run-off stops at the lane (the lane's own verge
	# fills a narrow gap), so it never lies across the lane in a slab.
	if track.has_pit_lane() and side == track.pit_side:
		var e := (track.width_right[i] if side > 0 else track.width_left[i]) + track.kerb_width
		var q := track.points[i] + track.vertex_normal(i) * side * e
		if _pit_rect.has_point(q):
			var room: float = track.project_pit(q)["dist"] - track.pit_width * 0.5 - PIT_SHOULDER
			w = clampf(room, 0.0, w)
	return w


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
			var ok := clearance(q) > track.runoff - 2.5 and not _in_pit_area(q) and not _in_joker_area(q)
			var kind := _barrier_kind(k, side)
			# A change of barrier type starts a new run (sharing the joint).
			if ok and run.size() >= 1 and run[-1][4] != kind:
				run.append([q, track.cum_s[k], off, k, run[-1][4]])
				_wall(st, run)
				run = []
			if ok:
				run.append([q, track.cum_s[k], off, k, kind])
			if (not ok or i == n) and run.size() >= 2:
				_wall(st, run)
				run = []
			elif not ok:
				run = []
			var tyre_here := kind == TrackData.Barrier.TYRES if track.barrier_left.size() == n else _is_gravel(k, side)
			if ok and tyre_here and k % 2 == 0:
				tyres.append([q - track.vertex_normal(k) * side * 0.9, track.seg_dir[k]])
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	_mesh_node(st, mat, "Walls", true)
	_build_tyre_walls(tyres)


## Barrier type from the track data (concrete wall when it has none).
func _barrier_kind(k: int, side: float) -> int:
	var arr := track.barrier_right if side > 0 else track.barrier_left
	return arr[k] if arr.size() == track.point_count() else TrackData.Barrier.WALL


## Beside the rallycross joker lane: no barrier across it.
func _in_joker_area(q: Vector2) -> bool:
	if not track.has_joker():
		return false
	return track.project_joker(q)["dist"] < track.joker_width * 0.5 + 6.0


func _in_pit_area(q: Vector2) -> bool:
	if not track.has_pit_lane() or not _pit_rect.has_point(q):
		return false
	var pr := track.project_pit(q)
	return pr.get("dist", INF) < track.pit_width * 0.5 + 6.0 if pr.has("dist") else false


## One run of barrier of a single type: concrete wall (grey blocks), armco
## (low steel rail), catch fencing (armco with a tall dark mesh above), tyre
## wall (a concrete wall behind the tyre stacks).
func _wall(st: SurfaceTool, run: Array) -> void:
	var kind: int = run[0][4] if run[0].size() > 4 else TrackData.Barrier.WALL
	var steel := kind == TrackData.Barrier.ARMCO or kind == TrackData.Barrier.FENCE
	var w := 0.15 if steel else 0.4
	var h := 0.75 if steel else 0.9
	for j in run.size() - 1:
		var a: Vector2 = run[j][0]
		var b: Vector2 = run[j + 1][0]
		var d := (b - a)
		if d.length() < 0.01 or d.length() > 30.0:
			continue
		var nn := Vector2(-d.y, d.x).normalized() * w * 0.5
		var ha := terrain_height(a) + 0.3
		var hb := terrain_height(b) + 0.3
		var shade: float = 0.72 if (int(run[j][1] / 6.0) % 2 == 0) else 0.8
		var top := Color(shade, shade, shade * 0.98)
		var face := Color(shade * 0.85, shade * 0.85, shade * 0.84)
		if steel:
			top = Color(0.62, 0.66, 0.72)
			face = Color(0.5, 0.55, 0.6)
		if kind == TrackData.Barrier.FENCE:
			# mesh fence on posts above the rail
			var fc := Color(0.16, 0.22, 0.18)
			_quad(st, Vector3(a.x, ha + h, a.y), Vector3(b.x, hb + h, b.y), Vector3(b.x, hb + 3.2, b.y), Vector3(a.x, ha + 3.2, a.y), fc)
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
				xs.append(Transform3D(Basis(), Vector3(q.x, terrain_height(q) + 0.4, q.y)))
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


## Demolition Derby ramps, painted so they read from above: yellow-and-black
## chevrons up the take-off ramp pointing the way you jump, a hazard stripe
## along the lip, and white chevrons down the landing.
const JUMP_PAINT_LIFT := 0.05
func _build_jump_markings() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var yellow := Color(0.98, 0.78, 0.08)
	var black := Color(0.06, 0.06, 0.06)
	var white := Color(0.93, 0.93, 0.9)
	for j in track.jumps:
		var lip := float(j["s"])
		var up := float(j["up_m"])
		var top := float(j["top_m"])
		var down := float(j["down_m"])
		var k := track.index_at(lip)
		var wl: float = track.width_left[k] - 0.4
		var wr: float = track.width_right[k] - 0.4
		# Take-off ramp: black base with yellow chevrons.
		_ramp_paint(st, lip - up, lip, -wl, wr, black)
		var n := maxi(int(up / 2.2), 2)
		for c in n:
			var s0 := lip - up + (c + 0.25) * up / n
			_chevron(st, s0, 0.9, minf(wl, wr) * 0.45, -wl, wr, yellow)
		# The lip: yellow and black hazard blocks across the road.
		var blocks := int((wl + wr) / 1.2)
		for b in blocks:
			var o0 := -wl + b * (wl + wr) / blocks
			var o1 := -wl + (b + 1) * (wl + wr) / blocks
			_ramp_paint(st, lip - 0.15, lip + 0.75, o0, o1, yellow if b % 2 == 0 else black, 0.004)
		# Landing ramp: white chevrons on the way down.
		var m := maxi(int(down / 3.5), 2)
		for c in m:
			var s0 := lip + top + (c + 0.3) * down / m
			_chevron(st, s0, 0.6, minf(wl, wr) * 0.45, -wl, wr, white)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.7
	_mesh_node(st, mat, "JumpMarkings")


## A painted patch on the road surface from s0 to s1 and across from off0 to
## off1, following the ramp's slope (cut into 1 m steps along the road).
func _ramp_paint(st: SurfaceTool, s0: float, s1: float, off0: float, off1: float, col: Color, extra := 0.0) -> void:
	var steps := maxi(int(ceil((s1 - s0) / 1.0)), 1)
	for i in steps:
		var a := s0 + (s1 - s0) * i / steps
		var b := s0 + (s1 - s0) * (i + 1) / steps
		_paint_tri(st, [[a, off0], [b, off0], [b, off1]], col, extra)
		_paint_tri(st, [[a, off0], [b, off1], [a, off1]], col, extra)


## One chevron (a V pointing the race direction): two bands from the road's
## edges, band thick along the road, meeting at the centre reach metres ahead.
func _chevron(st: SurfaceTool, s0: float, band: float, reach: float, off_l: float, off_r: float, col: Color) -> void:
	for side in [off_l, off_r]:
		var pts := [[s0, side], [s0 + band, side], [s0 + reach + band, 0.0], [s0 + reach, 0.0]]
		_paint_tri(st, [pts[0], pts[1], pts[2]], col, 0.008)
		_paint_tri(st, [pts[0], pts[2], pts[3]], col, 0.008)


func _paint_tri(st: SurfaceTool, pts: Array, col: Color, extra: float) -> void:
	var vs := []
	for p in pts:
		var at := track.position_at(float(p[0]), float(p[1]))
		vs.append(Vector3(at.x, height(float(p[0]), float(p[1])) + JUMP_PAINT_LIFT + extra, at.y))
	st.set_color(col)
	st.set_normal(Vector3.UP)
	for v in [vs[0], vs[1], vs[2], vs[0], vs[2], vs[1]]:
		st.add_vertex(v)


func _flat(st: SurfaceTool, a: Vector2, b: Vector2, c: Vector2, d: Vector2, y: float, col: Color) -> void:
	st.set_color(col)
	st.set_normal(Vector3.UP)
	for v in [a, b, c, a, c, d]:
		st.add_vertex(Vector3(v.x, y, v.y))
	for v in [a, c, b, a, d, c]:
		st.add_vertex(Vector3(v.x, y, v.y))


# --- Pit lane ----------------------------------------------------------------------

const PIT_LIFT := 0.045        ## above the run-off and asphalt, under the kerbs
const PIT_SHOULDER := 1.5      ## m of tarmac beside the lane's painted edges
const PIT_GORE_FULL := 8.0     ## lane this close to the track: tarmac all the way across
const PIT_GORE_END := 16.0     ## and by here only the shoulder


## Height for paint on the pit lane at a point.
func _pit_paint_y(p: Vector2) -> float:
	return surface_height(p) + PIT_LIFT + 0.015


## Width of the track on the pit side at a projected point.
func _pit_side_edge(q: Dictionary) -> float:
	return q["w_right"] if track.pit_side > 0.0 else q["w_left"]


## How far a projected point is beyond the track's edge on the pit side
## (negative = on the track, or past it on the other side).
func _pit_gap(q: Dictionary) -> float:
	return float(q["offset"]) * track.pit_side - _pit_side_edge(q)


func _build_pit_lane() -> void:
	var path := track.pit_path
	var w := track.pit_width
	var h := w * 0.5
	var ps := track.pit_side
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Across the lane, from the track side to the garage side (lane offsets
	# times pit_side, so + is towards the garages): a verge on the track side
	# (which fills the whole gap to the track where the lane is splitting off
	# or merging), the lane itself, and a narrow shoulder by the garages.
	var across := [-h - PIT_SHOULDER, -h, -h * 0.5, 0.0, h * 0.5, h, h + PIT_SHOULDER]
	var cols := across.size()
	var m := path.size()
	var hint := -1
	for i in m:
		var d := track.pit_cum[i]
		var dir := (path[mini(i + 1, m - 1)] - path[maxi(i - 1, 0)]).normalized()
		var nrm := Vector2(-dir.y, dir.x) * ps   # towards the garages
		# The verge on the track side: tarmac right up to the track's edge
		# while the gap is narrow (hatched where the lane splits off).
		var inner := path[i] - nrm * h
		var qi := track.project(inner, hint)
		hint = qi["idx"]
		var gap := _pit_gap(qi)
		var fill := 1.0 - smoothstep(PIT_GORE_FULL, PIT_GORE_END, gap)
		var gore := 1.0 if gap > 0.3 and fill > 0.5 else 0.0
		for c in cols:
			var off: float = across[c]
			var q := path[i] + nrm * off
			if c == 0:
				var edge_pt := track.position_at(qi["s"], ps * _pit_side_edge(qi))
				q = q.lerp(edge_pt, fill) if gap > 0.0 else edge_pt
			# Never on top of the track: anything inside its edge is moved to
			# the edge, so the lane meets the track exactly at its edge line.
			var qt := track.project(q, hint)
			if _pit_gap(qt) < 0.0:
				q = track.position_at(qt["s"], ps * _pit_side_edge(qt))
				qt = track.project(q, hint)
			var lane_off := (q - path[i]).dot(nrm)
			st.set_color(Color(1, 1, 1, K_PIT))
			st.set_uv(Vector2(d, lane_off))
			st.set_uv2(Vector2(gore, h - absf(lane_off)))
			st.add_vertex(Vector3(q.x, track.surface_height_at(q, qt["idx"]) + PIT_LIFT, q.y))
	for i in m - 1:
		for l in cols - 1:
			var a := i * cols + l
			var b := a + cols
			if ps > 0.0:
				st.add_index(a)
				st.add_index(b)
				st.add_index(a + 1)
				st.add_index(a + 1)
				st.add_index(b)
				st.add_index(b + 1)
			else:
				st.add_index(a)
				st.add_index(a + 1)
				st.add_index(b)
				st.add_index(a + 1)
				st.add_index(b + 1)
				st.add_index(b)
	_mesh_node(st, road_material, "PitLane")
	# pit wall on the track side, speed-limit lines and the boxes
	var wall: Array = []
	var dd := track.pit_limit_start
	while dd <= track.pit_limit_end:
		var off := -track.pit_side * (w * 0.5 + 0.6)
		wall.append([track.pit_position_at(dd, off), 0.0, 0.0, -1])
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
		_flat(mk, a, b, b + fwd, a + fwd, _pit_paint_y((a + b) * 0.5), Color(0.9, 0.9, 0.88))
	var yellow := Color(0.95, 0.82, 0.2)
	for i in track.pit_box_count:
		var box := track.pit_box(i)
		var bd := Vector2.from_angle(box["heading"])
		var bn := Vector2(-bd.y, bd.x)
		var c: Vector2 = box["pos"]
		var y := _pit_paint_y(c)
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
