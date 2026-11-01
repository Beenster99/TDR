class_name TrackView
extends Node2D
## Draws the track once from TrackData (1 unit = 1 metre).

var track: TrackData

const GRASS := Color(0.24, 0.42, 0.2)
const RUNOFF := Color(0.29, 0.47, 0.24)
const ASPHALT := Color(0.24, 0.24, 0.26)
const EDGE := Color(0.92, 0.92, 0.92)
const KERB_A := Color(0.85, 0.15, 0.15)
const KERB_B := Color(0.95, 0.95, 0.95)
const BARRIER := Color(0.55, 0.55, 0.6)


func setup(p_track: TrackData) -> void:
	track = p_track
	queue_redraw()


func _draw() -> void:
	if track == null:
		return
	var n := track.point_count()
	var lo := Vector2(INF, INF)
	var hi := -lo
	for p in track.points:
		lo = lo.min(p)
		hi = hi.max(p)
	draw_rect(Rect2(lo - Vector2(600, 600), hi - lo + Vector2(1200, 1200)), GRASS)
	var curv := _curvature()
	# Discs at every centre-line point fill the cracks that offset quads leave
	# where a tight hairpin folds the inside edge over itself.
	for i in n:
		draw_circle(track.points[i], minf(track.width_left[i], track.width_right[i]) + track.runoff, RUNOFF)
	for i in n:
		var j := (i + 1) % n
		var ni := track.vertex_normal(i)
		var nj := track.vertex_normal(j)
		var ro := track.runoff
		_quad(track.points[i] - ni * (track.width_left[i] + ro), track.points[j] - nj * (track.width_left[j] + ro),
			track.points[j] + nj * (track.width_right[j] + ro), track.points[i] + ni * (track.width_right[i] + ro), RUNOFF)
	for i in n:
		draw_circle(track.points[i], minf(track.width_left[i], track.width_right[i]), ASPHALT)
	for i in n:
		var j := (i + 1) % n
		var ni := track.vertex_normal(i)
		var nj := track.vertex_normal(j)
		var a := track.points[i]
		var b := track.points[j]
		var ri := track.width_right[i]
		var rj := track.width_right[j]
		var li := track.width_left[i]
		var lj := track.width_left[j]
		var ro := track.runoff
		# asphalt
		_quad(a - ni * li, b - nj * lj, b + nj * rj, a + ni * ri, ASPHALT)
		# kerbs on corners only, on both sides
		if curv[i] > 0.006:
			var kc := KERB_A if (i / 2) % 2 == 0 else KERB_B
			var kw := track.kerb_width
			_quad(a + ni * ri, b + nj * rj, b + nj * (rj + kw), a + ni * (ri + kw), kc)
			_quad(a - ni * li, b - nj * lj, b - nj * (lj + kw), a - ni * (li + kw), kc)
		draw_line(a + ni * (ri - 0.3), b + nj * (rj - 0.3), EDGE, 0.25)
		draw_line(a - ni * (li - 0.3), b - nj * (lj - 0.3), EDGE, 0.25)
		draw_line(a + ni * (ri + ro), b + nj * (rj + ro), BARRIER, 0.8)
		draw_line(a - ni * (li + ro), b - nj * (lj + ro), BARRIER, 0.8)
	# chequered start/finish line
	var n0 := track.vertex_normal(0)
	var d0 := track.seg_dir[0]
	var w := track.width_left[0] + track.width_right[0]
	var cells := int(w / 1.0)
	for k in cells:
		for row in 2:
			var c := Color.WHITE if (k + row) % 2 == 0 else Color.BLACK
			var p := track.points[0] - n0 * track.width_left[0] + n0 * k + d0 * (row - 1)
			_quad(p, p + d0, p + d0 + n0, p + n0, c)
	# grid boxes
	for g in 16:
		var slot := track.grid_slot(g)
		var gp: Vector2 = slot["pos"]
		var gd := Vector2.from_angle(slot["heading"])
		var gn := Vector2(-gd.y, gd.x)
		draw_polyline(PackedVector2Array([gp + gd * 2.6 - gn * 1.3, gp + gd * 2.6 + gn * 1.3]), EDGE, 0.2)


func _quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, col: Color) -> void:
	# Two triangles: never fails triangulation, even when the offset edges of
	# a tight hairpin fold over each other.
	var cols := PackedColorArray([col, col, col])
	draw_primitive(PackedVector2Array([a, b, c]), cols, PackedVector2Array())
	draw_primitive(PackedVector2Array([a, c, d]), cols, PackedVector2Array())


func _curvature() -> PackedFloat64Array:
	var n := track.point_count()
	var out := PackedFloat64Array()
	out.resize(n)
	for i in n:
		var d1 := track.seg_dir[(i - 2 + n) % n]
		var d2 := track.seg_dir[(i + 2) % n]
		out[i] = absf(d1.angle_to(d2)) / 20.0
	return out
