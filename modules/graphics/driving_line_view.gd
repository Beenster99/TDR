class_name DrivingLineView
extends Node3D
## The driving line aid on the track (Settings > Gameplay): a soft band along
## the racing line ahead of the player's car, green where the speed is fine,
## yellow where it's time to lift and red where they should be braking
## (see driving_line.gdshader). Settings can show it all round the lap or
## only into and through the corners. Built once from a DrivingLine (physics);
## the race scene calls update() every frame with the player's car.
## Rallycross: a second view draws the joker line (DrivingLine.build_joker),
## either only where it leaves the lap (set_branch_only, while the player
## still owes the joker) or all of it (on the joker lane).

const SHADER := preload("res://modules/graphics/shaders/driving_line.gdshader")
const HALF_WIDTH := 1.0     ## metres each side of the line (faded towards the edges)
const LIFT := 0.07          ## above the road, over the rubber line and markings
## Settings > Gameplay > Driving line (prefs aid_driving_line).
const LINE_OFF := 0
const LINE_CORNERS := 1     ## from the braking zone through each corner (DrivingLine.corner)
const LINE_FULL := 2
const JOKER_LIFT := 0.045   ## the joker lane sits this far over the ground (TrackView)

var line: DrivingLine
var material: ShaderMaterial
var enabled := false        ## the player has the line or the braking colours on
var _hint := -1


## line_mode: LINE_FULL the whole line ahead, LINE_CORNERS only into and
## through the corners, LINE_OFF none (a bool still works: true = full).
## show_brake: braking colours (with the line off, only the braking zones
## show; with corners only, a braking warning still shows wherever you're
## too fast). Line off and braking colours off: nothing is drawn.
func setup(p_line: DrivingLine, tv: TrackView, line_mode, show_brake: bool) -> void:
	line = p_line
	var mode: int = (LINE_FULL if line_mode else LINE_OFF) if typeof(line_mode) == TYPE_BOOL else clampi(int(line_mode), LINE_OFF, LINE_FULL)
	var show_line := mode != LINE_OFF
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.render_priority = 1
	material.set_shader_parameter("line_length", line.length)
	material.set_shader_parameter("show_full", 1.0 if show_line else 0.0)
	material.set_shader_parameter("corners_only", 1.0 if mode == LINE_CORNERS else 0.0)
	material.set_shader_parameter("show_colours", 1.0 if show_brake else 0.0)
	material.set_shader_parameter("branch_only", 0.0)
	enabled = show_line or show_brake
	visible = enabled
	if not enabled:
		return
	var n := line.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const LANES := 4
	var joker := line.joker_d.size() == n
	var hint := -1
	for i in n + 1:
		var k := i % n
		var p := line.points[k]
		var d := (line.points[(k + 1) % n] - line.points[(k - 1 + n) % n]).normalized()
		var nrm := Vector2(-d.y, d.x)
		var dist := line.dist[k] if i < n else line.length
		for l in LANES + 1:
			var u := -1.0 + 2.0 * l / LANES
			var q := p + nrm * u * HALF_WIDTH
			var y := 0.0
			if joker and line.joker_d[k] >= 0.0:
				# On the joker lane: its own surface, as TrackView builds it.
				y = tv.track.surface_height_at(q, hint) + JOKER_LIFT
				hint = int(tv.track.project(q, hint)["idx"])
			elif tv.has_elevation():
				y = tv.height(line.track_s[k], line.offset[k] + u * HALF_WIDTH)
			st.set_color(Color(line.branch[k] if joker else 1.0, 1, 1, 1))
			st.set_uv(Vector2(u, line.speed[k]))
			st.set_uv2(Vector2(dist, line.corner[k] if line.corner.size() == n else 1.0))
			st.add_vertex(Vector3(q.x, y + LIFT, q.y))
	for i in n:
		for l in LANES:
			var a := i * (LANES + 1) + l
			var b := a + LANES + 1
			st.add_index(a)
			st.add_index(b)
			st.add_index(a + 1)
			st.add_index(a + 1)
			st.add_index(b)
			st.add_index(b + 1)
	var mi := MeshInstance3D.new()
	mi.name = "DrivingLine"
	mi.mesh = st.commit()
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Joker line only: true shows just the stretch where it leaves the lap for
## the joker lane (plus a lead-in), false the whole line like the lap's.
func set_branch_only(on: bool) -> void:
	if material:
		material.set_shader_parameter("branch_only", 1.0 if on else 0.0)


## The player's car: where it is and how fast it's going (m/s).
func update(pos: Vector2, speed: float) -> void:
	if not enabled or not visible:
		return
	_hint = line.locate(pos, _hint)
	material.set_shader_parameter("car_dist", line.dist[_hint])
	material.set_shader_parameter("car_speed", speed)
