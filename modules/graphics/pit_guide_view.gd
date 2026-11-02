class_name PitGuideView
extends Node3D
## The pit guide for a driver who drives into the pits themselves: a dashed
## band from the track into the pit lane and onto their box, coloured by
## their speed against the speed to be doing there (blue fine, yellow lift,
## red brake), painted lines
## across the lane where the speed limit starts and ends, and their box
## marked out on the ground. Built once from plain data (PitRules.guide_line,
## race module); the race scene calls update() every frame.

const SHADER := preload("res://modules/graphics/shaders/pit_guide.gdshader")
const HALF_WIDTH := 1.1     ## metres each side of the line
const LIFT := 0.09          ## above the road, over the driving line
const BOX_LEN := 6.0        ## the box outline, metres along the lane
const BOX_WIDE := 3.2       ## and across
const BOX_COLOUR := Color(0.35, 0.9, 1.0)  ## not the yellow of the painted boxes

var material: ShaderMaterial
var guide: Dictionary = {}
var _line: MeshInstance3D
var _marks: Node3D
var _box: MeshInstance3D
var _box_mat: StandardMaterial3D
var _t := 0.0


## g: PitRules.guide_line(car) ({points, dist, speed, limit_start, limit_end,
## box_d, box_pos, box_heading, limit}).
func setup(g: Dictionary, tv: TrackView) -> void:
	guide = g
	visible = false
	if g.is_empty():
		return
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.render_priority = 2
	var pts: PackedVector2Array = g["points"]
	var dist: PackedFloat64Array = g["dist"]
	var speed: PackedFloat64Array = g["speed"]
	var ls: float = g["limit_start"]
	var le: float = g["limit_end"]
	var n := pts.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const LANES := 4
	var hint := -1
	for i in n:
		var d := (pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var nrm := Vector2(-d.y, d.x)
		var zone := 1.0 if dist[i] >= ls and dist[i] <= le else 0.0
		hint = tv.nearest_index(pts[i])
		for l in LANES + 1:
			var u := -1.0 + 2.0 * l / LANES
			var q := pts[i] + nrm * u * HALF_WIDTH
			st.set_uv(Vector2(u, speed[i]))
			st.set_uv2(Vector2(dist[i], zone))
			st.add_vertex(Vector3(q.x, tv.surface_height(q, hint) + LIFT, q.y))
	for i in n - 1:
		for l in LANES:
			var a := i * (LANES + 1) + l
			var b := a + LANES + 1
			for k in [a, b, a + 1, a + 1, b, b + 1]:
				st.add_index(k)
	_line = MeshInstance3D.new()
	_line.name = "PitGuideLine"
	_line.mesh = st.commit()
	_line.material_override = material
	_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_line)
	_marks = Node3D.new()
	_marks.name = "PitGuideMarks"
	add_child(_marks)
	var kph := roundi(float(g["limit"]) * 3.6)
	_bar(tv, _at(ls), "PIT LIMIT %d" % kph, Color(1, 1, 1))
	_bar(tv, _at(le), "END LIMIT", Color(0.6, 0.85, 1.0))
	_build_box(tv)


## Point and direction on the guide at guide metres d.
func _at(d: float) -> Array:
	var pts: PackedVector2Array = guide["points"]
	var dist: PackedFloat64Array = guide["dist"]
	var k := 0
	while k < dist.size() - 2 and dist[k + 1] < d:
		k += 1
	var f := clampf((d - dist[k]) / maxf(dist[k + 1] - dist[k], 0.001), 0.0, 1.0)
	return [pts[k].lerp(pts[k + 1], f), (pts[k + 1] - pts[k]).normalized()]


## A painted line across the pit lane with a label beside it.
func _bar(tv: TrackView, at: Array, text: String, col: Color) -> void:
	var p: Vector2 = at[0]
	var dir: Vector2 = at[1]
	var across := Vector2(-dir.y, dir.x)
	var half := tv.track.pit_width * 0.5 + 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := tv.surface_height(p) + LIFT + 0.01
	var a := p - across * half - dir * 0.35
	var b := p + across * half - dir * 0.35
	var c := p + across * half + dir * 0.35
	var d := p - across * half + dir * 0.35
	for v in [a, b, c, a, c, d]:
		st.add_vertex(Vector3(v.x, y, v.y))
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marks.add_child(mi)
	if DisplayServer.get_name() != "headless":
		var l := _label(text, col)
		var at_pt := p - dir * 3.0
		l.position = Vector3(at_pt.x, y + 0.05, at_pt.y)
		l.rotation = Vector3(-PI * 0.5, -dir.angle() - PI * 0.5, 0.0)
		_marks.add_child(l)


func _label(text: String, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = 64
	l.outline_size = 14
	l.pixel_size = 0.03
	l.modulate = col
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.double_sided = true
	l.no_depth_test = true
	l.render_priority = 3
	return l


## The driver's box: a glowing outline on the ground where the car stops (pit-lane blue, so it
## stands out from the yellow boxes painted for every car; green on the marks).
func _build_box(tv: TrackView) -> void:
	var p: Vector2 = guide["box_pos"]
	var fwd := Vector2.from_angle(float(guide["box_heading"]))
	var across := Vector2(-fwd.y, fwd.x)
	var y := tv.surface_height(p) + LIFT + 0.02
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hl := BOX_LEN * 0.5
	var hw := BOX_WIDE * 0.5
	var t := 0.22
	var corners := [p - fwd * hl - across * hw, p + fwd * hl - across * hw, p + fwd * hl + across * hw, p - fwd * hl + across * hw]
	for k in 4:
		var a: Vector2 = corners[k]
		var b: Vector2 = corners[(k + 1) % 4]
		var e := (b - a).normalized()
		var nrm := Vector2(-e.y, e.x) * t
		for v in [a - nrm, b - nrm, b + nrm, a - nrm, b + nrm, a + nrm]:
			st.add_vertex(Vector3(v.x, y, v.y))
	# The front wheels' marks: a bar across the box where the nose stops.
	var f0 := p + fwd * (hl - 1.0)
	for v in [f0 - across * hw - fwd * t, f0 + across * hw - fwd * t, f0 + across * hw + fwd * t,
			f0 - across * hw - fwd * t, f0 + across * hw + fwd * t, f0 - across * hw + fwd * t]:
		st.add_vertex(Vector3(v.x, y, v.y))
	_box = MeshInstance3D.new()
	_box.name = "PitGuideBox"
	_box.mesh = st.commit()
	_box_mat = StandardMaterial3D.new()
	_box_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_box_mat.albedo_color = BOX_COLOUR
	_box_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_box.material_override = _box_mat
	_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marks.add_child(_box)
	if DisplayServer.get_name() != "headless":
		var l := _label("YOUR BOX", BOX_COLOUR)
		var at_pt := p - fwd * (hl + 2.0)
		l.position = Vector3(at_pt.x, y + 0.05, at_pt.y)
		l.rotation = Vector3(-PI * 0.5, -fwd.angle() - PI * 0.5, 0.0)
		_marks.add_child(l)


## Every frame. progress: the car's guide metres (PitRules.guide_progress;
## PitRules.GUIDE_NONE or below = not heading in: hidden), speed in m/s,
## stopping: true until the car has been serviced (the line ends at the
## box), on_marks: the car is on its marks (the box turns green).
func update(progress: float, speed: float, stopping: bool, on_marks := false, delta := 0.016) -> void:
	if guide.is_empty() or progress < -2000.0:
		visible = false
		return
	visible = true
	material.set_shader_parameter("car_dist", progress)
	material.set_shader_parameter("car_speed", speed)
	material.set_shader_parameter("end_dist", float(guide["box_d"]) + 0.5 if stopping else 100000.0)
	_t += delta
	var pulse := 0.75 + 0.25 * sin(_t * 6.0)
	_box.visible = stopping
	_box_mat.albedo_color = Color(0.3, 1.0, 0.4) if on_marks else Color(BOX_COLOUR * pulse, 1.0)
