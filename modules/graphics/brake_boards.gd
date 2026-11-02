class_name BrakeBoards
extends Node3D
## Brake marker boards before every real braking zone: numbered boards
## (distance to the corner in metres) on the outside of the track, on the
## run-off where drivers look for their braking point. Always there (not a
## setting). They're scenery only: nothing in the sim hits them, so they
## can never be knocked down or damaged.

const SET_BACK := 3.2          ## metres beyond the kerb
const FAST_MARKS := [300, 200, 100]
const SLOW_MARKS := [150, 100, 50]
const FAST_ENTRY := 55.0       ## m/s (about 200 km/h): above this the boards count from 300
const SHOW_WITHIN := 700.0     ## camera distance (m) the numbers stay visible

var boards: Array = []         ## [{pos: Vector2, mark: int, zone: int}] (for tests)


func setup(line: DrivingLine, tv: TrackView) -> void:
	var track := tv.track
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := line.size()
	var prev_end := -1
	if not line.zones.is_empty():
		prev_end = int(line.zones[-1]["end"])
	for z in line.zones.size():
		var zone: Dictionary = line.zones[z]
		var e := int(zone["end"])
		# Room on the straight before this corner (back to the last corner).
		var room := fposmod(line.dist[e] - line.dist[prev_end], line.length) if prev_end >= 0 else line.length
		prev_end = e
		var marks: Array = FAST_MARKS if float(zone["entry_v"]) > FAST_ENTRY else SLOW_MARKS
		var side := -float(zone["side"])   # the outside of the corner ahead
		for mark in marks:
			if mark > room - 40.0:
				continue
			var k := e
			var back := 0.0
			while back < mark:
				var pk := (k - 1 + n) % n
				back += line.points[k].distance_to(line.points[pk])
				k = pk
			var s := line.track_s[k]
			var i := track.index_at(s)
			var edge: float = track.width_right[i] if side > 0.0 else track.width_left[i]
			var off := side * (edge + track.kerb_width + SET_BACK)
			var p := track.position_at(s, off)
			var dir := track.seg_dir[i]
			var y := tv.terrain_height(p)
			_board(st, p, dir, y, int(mark))
			boards.append({"pos": p, "mark": int(mark), "zone": z})
			if DisplayServer.get_name() != "headless":
				_number(p, y, int(mark))
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.7
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.name = "BrakeBoards"
	mi.mesh = st.commit()
	mi.material_override = mat
	add_child(mi)


## A board on two posts, its face tilted up to the sky so it reads from the
## camera above: white with a red band (one band per 100 m on the big boards).
func _board(st: SurfaceTool, p: Vector2, dir: Vector2, y: float, mark: int) -> void:
	var across := Vector2(-dir.y, dir.x)
	var w := 1.6                 # half width (across the track)
	var depth := 1.0             # half depth (along the track)
	var h := 1.3
	var tilt := 0.35             # back edge higher: faces oncoming cars and the sky
	var white := Color(0.95, 0.95, 0.93)
	var red := Color(0.85, 0.08, 0.07)
	var post := Color(0.25, 0.25, 0.27)
	var a := p - across * w - dir * depth
	var b := p + across * w - dir * depth
	var c := p + across * w + dir * depth
	var d := p - across * w + dir * depth
	var top := func(q: Vector2, front: bool) -> Vector3:
		return Vector3(q.x, y + h + (0.0 if front else tilt), q.y)
	# face (front edge is the one the cars come from, -dir)
	_quad(st, top.call(a, true), top.call(b, true), top.call(c, false), top.call(d, false), white)
	# bands: 3, 2 or 1 stripes like real boards
	var bands := clampi(mark / 100 if mark >= 100 else 1, 1, 3)
	for j in bands:
		var t0 := -0.75 + j * 0.5
		var a2 := p - across * w * 0.85 + dir * depth * t0
		var b2 := p + across * w * 0.85 + dir * depth * t0
		var c2 := p + across * w * 0.85 + dir * depth * (t0 + 0.25)
		var d2 := p - across * w * 0.85 + dir * depth * (t0 + 0.25)
		var lift := Vector3(0, 0.02, 0)
		var f0 := (t0 + 1.0) * 0.5
		var f1 := (t0 + 1.25) * 0.5
		_quad(st, top.call(a2, true) + lift + Vector3(0, tilt * f0, 0), top.call(b2, true) + lift + Vector3(0, tilt * f0, 0),
			top.call(c2, true) + lift + Vector3(0, tilt * f1, 0), top.call(d2, true) + lift + Vector3(0, tilt * f1, 0), red)
	# front edge, so it reads as a board, and two posts
	var a3 := Vector3(a.x, y + h - 0.12, a.y)
	var b3 := Vector3(b.x, y + h - 0.12, b.y)
	_quad(st, a3, b3, top.call(b, true), top.call(a, true), red)
	for sx in [-0.8, 0.8]:
		var q: Vector2 = p + across * w * sx
		var q0 := q - across * 0.06
		var q1 := q + across * 0.06
		_quad(st, Vector3(q0.x, y, q0.y), Vector3(q1.x, y, q1.y), Vector3(q1.x, y + h, q1.y), Vector3(q0.x, y + h, q0.y), post)


func _number(p: Vector2, y: float, mark: int) -> void:
	var l := Label3D.new()
	l.text = str(mark)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.font_size = 96
	l.outline_size = 18
	l.pixel_size = 0.022
	l.modulate = Color(0.08, 0.08, 0.1)
	l.outline_modulate = Color(1, 1, 1)
	l.position = Vector3(p.x, y + 2.4, p.y)
	l.visibility_range_end = SHOW_WITHIN
	l.no_depth_test = false
	add_child(l)


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	var nrm := (b - a).cross(d - a).normalized()
	if nrm.y < 0.0:
		nrm = -nrm
	st.set_color(col)
	st.set_normal(nrm)
	for v in [a, b, c, a, c, d]:
		st.set_color(col)
		st.set_normal(nrm)
		st.add_vertex(v)
