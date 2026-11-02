class_name Scenery
extends Node3D
## A circuit's real surroundings, built from open map data by
## tools/build_scenery.py (OpenStreetMap footprints and landuse, Environment
## Agency LIDAR heights in England): every building at its real size and
## height, the named grandstands full of people with their roofs, footbridges
## and road bridges, and a painted ground map under it all (fields, woods,
## car parks with their bays, roads, paths, ponds, the circuit's other loops).
## Trees come back as a list for Trackside to plant with its own tree meshes.
## Tracks without a data/scenery/<id>.json keep the made-up trackside.

const DIR := "res://modules/graphics/data/scenery/"

var tv: TrackView
var data: Dictionary
var _mat: StandardMaterial3D
var _crowd_mat: Material
var _rects: Array[Rect2] = []   ## footprints' bounding boxes (trees keep out)
var _clear_pts := PackedVector2Array()   ## no real buildings within _clear_r of these
var _clear_r := 0.0


## The scenery data for a track, or {} if it has none (or it's switched off).
static func data_for(track_id: String) -> Dictionary:
	if not GfxSettings.real_scenery:
		return {}
	var path := DIR + track_id + ".json"
	if not FileAccess.file_exists(path):
		return {}
	var d = JsonData.load_json(path)
	return d if d is Dictionary else {}


func setup(p_tv: TrackView, p_data: Dictionary, crowd_mat: Material) -> void:
	tv = p_tv
	data = p_data
	_crowd_mat = crowd_mat
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.85
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_apply_ground_map()
	if GfxSettings.buildings or GfxSettings.grandstands:
		_build_buildings()
	if GfxSettings.buildings:
		_build_bridges()


## Credits to show (OpenStreetMap's licence asks for it).
func sources() -> Array:
	return data.get("sources", [])


## Leave out real buildings that come within r metres of these points
## (call before setup).
func keep_clear(points: PackedVector2Array, r: float) -> void:
	_clear_pts = points
	_clear_r = r


func _in_clear_zone(pts: PackedVector2Array) -> bool:
	var r2 := _clear_r * _clear_r
	for c in _clear_pts:
		for p in pts:
			if p.distance_squared_to(c) < r2:
				return true
	return false


func is_built_on(p: Vector2) -> bool:
	for r in _rects:
		if r.has_point(p):
			return true
	return false


## [position, height m, kind (0 broadleaf, 1 conifer, 2 bush)] for each tree.
func trees() -> Array:
	return data.get("trees", [])


# --- Ground map ------------------------------------------------------------------

func _apply_ground_map() -> void:
	var g: Dictionary = data.get("ground", {})
	if not g.has("webp"):
		return
	var img := Image.new()
	if img.load_webp_from_buffer(Marshalls.base64_to_raw(g["webp"])) != OK:
		push_warning("Scenery: ground map unreadable")
		return
	img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var o: Array = g["origin"]
	var s: Array = g["size"]
	var m := tv.terrain_material
	m.set_shader_parameter("ground_map", tex)
	m.set_shader_parameter("ground_rect", Vector4(o[0], o[1], s[0], s[1]))
	m.set_shader_parameter("ground_on", 1.0)


# --- Buildings -----------------------------------------------------------------------

const ROOF_HOUSE := [Color(0.46, 0.27, 0.22), Color(0.38, 0.33, 0.31), Color(0.52, 0.34, 0.26), Color(0.31, 0.31, 0.34), Color(0.43, 0.3, 0.27)]
const ROOF_BIG := [Color(0.74, 0.75, 0.76), Color(0.58, 0.6, 0.63), Color(0.66, 0.64, 0.6), Color(0.82, 0.83, 0.84), Color(0.5, 0.52, 0.55)]
const WALL_HOUSE := Color(0.62, 0.45, 0.36)
const WALL_BIG := Color(0.74, 0.73, 0.7)


func _build_buildings() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seats := SurfaceTool.new()
	seats.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n_seats := 0
	var count := 0
	for b in data.get("buildings", []):
		var pts := PackedVector2Array()
		for q in b["p"]:
			pts.append(Vector2(q[0], q[1]))
		if pts.size() < 3:
			continue
		var kind: String = b.get("k", "building")
		if kind == "grandstand" and not GfxSettings.grandstands:
			continue
		if kind != "grandstand" and not GfxSettings.buildings:
			continue
		if not _clear_pts.is_empty() and _in_clear_zone(pts):
			continue
		var r := Rect2(pts[0], Vector2.ZERO)
		var base := INF
		for p in pts:
			r = r.expand(p)
			base = minf(base, tv.terrain_height(p))
		_rects.append(r)
		base -= 0.4
		var h: float = float(b.get("h", 7.0)) + 0.4
		var key := hash(str(pts[0]))
		if kind == "grandstand":
			_grandstand(st, seats, pts, base, h, int(b.get("front", 0)))
			n_seats += 1
		elif kind == "house" and pts.size() == 4:
			_gabled(st, pts, base, h, ROOF_HOUSE[key % ROOF_HOUSE.size()], WALL_HOUSE)
		else:
			var roof: Color = ROOF_HOUSE[key % ROOF_HOUSE.size()] if kind == "house" else \
				Color(0.86, 0.86, 0.87) if kind == "roof" else ROOF_BIG[key % ROOF_BIG.size()]
			var wall := WALL_HOUSE if kind == "house" else WALL_BIG
			if kind == "roof":   # a canopy on posts: roof only, thin
				_prism(st, pts, base + h - 0.6, 0.6, roof, wall * 0.8)
			else:
				_prism(st, pts, base, h, roof, wall)
				if r.size.length() > 40.0 and kind == "building":
					_roof_plant(st, pts, r, base + h, key)
		count += 1
	_commit(st, _mat, "Buildings")
	if n_seats > 0:
		_commit(seats, _crowd_mat, "GrandstandSeats")
	print_verbose("[scenery] %d buildings, %d grandstands" % [count, n_seats])


## Walls straight up from base to base + h, a flat roof on top.
func _prism(st: SurfaceTool, pts: PackedVector2Array, base: float, h: float, roof: Color, wall: Color) -> void:
	var tops := PackedFloat32Array()
	tops.resize(pts.size())
	tops.fill(base + h)
	_walls(st, pts, base, tops, wall)
	_cap(st, pts, tops, roof)


func _walls(st: SurfaceTool, pts: PackedVector2Array, base: float, tops: PackedFloat32Array, col: Color) -> void:
	var n := pts.size()
	var ccw := _signed_area(pts) > 0.0
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var e := (b - a).normalized()
		var out := Vector2(e.y, -e.x) if ccw else Vector2(-e.y, e.x)
		var nrm := Vector3(out.x, 0, out.y)
		# a little shading by which way the wall faces
		var c := col * (0.82 + 0.18 * (out.dot(Vector2(0.6, 0.8)) * 0.5 + 0.5))
		c.a = 1.0
		_tri(st, Vector3(a.x, base, a.y), Vector3(b.x, base, b.y), Vector3(b.x, tops[(i + 1) % n], b.y), nrm, c)
		_tri(st, Vector3(a.x, base, a.y), Vector3(b.x, tops[(i + 1) % n], b.y), Vector3(a.x, tops[i], a.y), nrm, c)


## The top of a footprint at each corner's height (flat or sloping).
func _cap(st: SurfaceTool, pts: PackedVector2Array, tops: PackedFloat32Array, col: Color) -> void:
	var idx := Geometry2D.triangulate_polygon(pts)
	for k in range(0, idx.size(), 3):
		var a := pts[idx[k]]
		var b := pts[idx[k + 1]]
		var c := pts[idx[k + 2]]
		var va := Vector3(a.x, tops[idx[k]], a.y)
		var vb := Vector3(b.x, tops[idx[k + 1]], b.y)
		var vc := Vector3(c.x, tops[idx[k + 2]], c.y)
		var nrm := (vb - va).cross(vc - va).normalized()
		if nrm.y < 0.0:
			nrm = -nrm
		_tri(st, va, vb, vc, nrm, col)


## A four-cornered house: walls up to the eaves and a pitched roof along its length.
func _gabled(st: SurfaceTool, pts: PackedVector2Array, base: float, h: float, roof: Color, wall: Color) -> void:
	var a := pts[0]
	var b := pts[1]
	var c := pts[2]
	var d := pts[3]
	if a.distance_to(b) < b.distance_to(c):   # make a-b a long side
		var t := a
		a = b
		b = c
		c = d
		d = t
	var short := b.distance_to(c)
	var pitch := clampf(short * 0.32, 1.0, 3.5)
	var eaves := base + maxf(h - pitch, 2.4)
	var ridge := eaves + pitch
	var quad := PackedVector2Array([a, b, c, d])
	var tops := PackedFloat32Array([eaves, eaves, eaves, eaves])
	_walls(st, quad, base, tops, wall)
	var m1 := (d + a) * 0.5
	var m2 := (b + c) * 0.5
	var A := Vector3(a.x, eaves, a.y)
	var B := Vector3(b.x, eaves, b.y)
	var Cc := Vector3(c.x, eaves, c.y)
	var D := Vector3(d.x, eaves, d.y)
	var M1 := Vector3(m1.x, ridge, m1.y)
	var M2 := Vector3(m2.x, ridge, m2.y)
	for face in [[A, B, M2, M1], [Cc, D, M1, M2]]:
		var nrm: Vector3 = (face[1] - face[0]).cross(face[3] - face[0]).normalized()
		if nrm.y < 0.0:
			nrm = -nrm
		var shade := roof * (0.8 + 0.3 * clampf(nrm.dot(Vector3(0.4, 0.8, 0.45).normalized()), 0.0, 1.0))
		shade.a = 1.0
		_tri(st, face[0], face[1], face[2], nrm, shade)
		_tri(st, face[0], face[2], face[3], nrm, shade)
	for g in [[D, A, M1], [B, Cc, M2]]:
		var nrm: Vector3 = (g[1] - g[0]).cross(Vector3.UP).normalized()
		_tri(st, g[0], g[1], g[2], nrm, wall * 0.9)


## Rooftop plant on big flat roofs: a few grey boxes.
func _roof_plant(st: SurfaceTool, pts: PackedVector2Array, r: Rect2, y: float, key: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = key
	for k in mini(int(r.get_area() / 900.0), 8):
		var p := r.position + Vector2(rng.randf(), rng.randf()) * r.size
		if not Geometry2D.is_point_in_polygon(p, pts):
			continue
		var s := Vector2(rng.randf_range(2.0, 5.0), rng.randf_range(2.0, 4.0))
		var box := PackedVector2Array([p - s * 0.5, p + Vector2(s.x, -s.y) * 0.5, p + s * 0.5, p + Vector2(-s.x, s.y) * 0.5])
		_prism(st, box, y, rng.randf_range(0.8, 1.8), Color(0.5, 0.51, 0.53), Color(0.45, 0.46, 0.48))


## A grandstand: seats rising away from the edge that faces the circuit,
## full of people, and a roof over the back rows on the bigger stands.
func _grandstand(st: SurfaceTool, seats: SurfaceTool, pts: PackedVector2Array, base: float, h: float, front: int) -> void:
	var n := pts.size()
	front = clampi(front, 0, n - 1)
	var fa := pts[front]
	var fb := pts[(front + 1) % n]
	var e := (fb - fa).normalized()
	var inward := Vector2(-e.y, e.x)
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= n
	if (c - fa).dot(inward) < 0.0:
		inward = -inward
	var depth := 0.0
	for p in pts:
		depth = maxf(depth, (p - fa).dot(inward))
	depth = maxf(depth, 1.0)
	var low := base + 1.2
	var high := base + maxf(h * (0.7 if h > 9.0 else 1.0), 2.5)
	var tops := PackedFloat32Array()
	for p in pts:
		tops.append(lerpf(low, high, clampf((p - fa).dot(inward) / depth, 0.0, 1.0)))
	_walls(st, pts, base, tops, Color(0.66, 0.66, 0.64))
	_cap(seats, pts, tops, Color.WHITE)
	if h > 9.0 and depth > 8.0:
		# roof over the back 60 % of the seats, sloping up towards the track
		var far := 4000.0
		var cut := fa + inward * depth * 0.4
		var half := PackedVector2Array([cut - e * far, cut + e * far, cut + e * far + inward * far, cut - e * far + inward * far])
		var roof_y := base + h
		for poly in Geometry2D.intersect_polygons(pts, half):
			var rt := PackedFloat32Array()
			for p in poly:
				rt.append(roof_y + 0.8 * (1.0 - clampf((p - fa).dot(inward) / depth, 0.0, 1.0)))
			_cap(st, poly, rt, Color(0.84, 0.85, 0.87))
			# the roof's thin edge
			var under := PackedFloat32Array()
			for k in rt.size():
				under.append(rt[k])
			_walls(st, poly, roof_y - 0.5, under, Color(0.55, 0.56, 0.58))


# --- Bridges ---------------------------------------------------------------------

func _build_bridges() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for br in data.get("bridges", []):
		var path: Array = br["p"]
		var w: float = br.get("w", 4.0)
		var h: float = br.get("h", 6.0)
		var foot: bool = br.get("kind", "") == "foot"
		var deck := Color(0.6, 0.6, 0.6) if foot else Color(0.3, 0.3, 0.32)
		var side := Color(0.72, 0.72, 0.7)
		# deck height: level across, from the higher bank
		var y := -INF
		for q in [path[0], path[path.size() - 1]]:
			y = maxf(y, tv.terrain_height(Vector2(q[0], q[1])))
		for k in path.size() - 1:
			var a := Vector2(path[k][0], path[k][1])
			var b := Vector2(path[k + 1][0], path[k + 1][1])
			y = maxf(y, maxf(tv.terrain_height(a), tv.terrain_height(b)) + h)
		for k in path.size() - 1:
			var a := Vector2(path[k][0], path[k][1])
			var b := Vector2(path[k + 1][0], path[k + 1][1])
			var d := (b - a).normalized()
			var nn := Vector2(-d.y, d.x) * w * 0.5
			var quad := PackedVector2Array([a - nn, b - nn, b + nn, a + nn])
			_prism(st, quad, y - 0.9, 0.9, deck, side * 0.8)
			# parapets
			for s in [-1.0, 1.0]:
				var o: Vector2 = nn * s
				var o2: Vector2 = nn * s * (1.0 - 0.5 / maxf(w * 0.5, 0.6))
				_prism(st, PackedVector2Array([a + o2, b + o2, b + o, a + o]), y, 1.1, side, side * 0.85)
	_commit(st, _mat, "Bridges")


# --- helpers -----------------------------------------------------------------------

## One triangle facing nrm (wound the way Godot draws front faces:
## Plane(a, b, c).normal, i.e. (c - a) x (b - a), points along nrm).
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, nrm: Vector3, col: Color) -> void:
	if (c - a).cross(b - a).dot(nrm) < 0.0:
		var t := b
		b = c
		c = t
	st.set_color(col)
	st.set_normal(nrm)
	st.add_vertex(a)
	st.set_normal(nrm)
	st.add_vertex(b)
	st.set_normal(nrm)
	st.add_vertex(c)


func _signed_area(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		s += a.x * b.y - b.x * a.y
	return s * 0.5


func _commit(st: SurfaceTool, mat: Material, node_name: String) -> void:
	var mesh := st.commit()
	if mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)
