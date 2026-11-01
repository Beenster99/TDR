class_name CarView
extends Node2D
## Top-down car sprite drawn from the definition's size and colour.
## Visual position eases toward the sim state, hiding small snapshot corrections.

var def: CarDefinition
var state: CarState
var label: String = ""
var is_local := false
var _init_done := false


func setup(p_def: CarDefinition, p_state: CarState, p_label: String, p_local: bool) -> void:
	def = p_def
	state = p_state
	label = p_label
	is_local = p_local
	z_index = 2 if p_local else 1


func _process(delta: float) -> void:
	if state == null:
		return
	if not _init_done or position.distance_to(state.pos) > 6.0:
		position = state.pos
		rotation = state.heading
		_init_done = true
	else:
		var k := 1.0 - exp(-30.0 * delta)
		position = position.lerp(state.pos, k)
		rotation = lerp_angle(rotation, state.heading, k)
	queue_redraw()


## Screen pixels per metre right now (camera zoom times window scaling).
func _px_per_m() -> float:
	return get_viewport().get_canvas_transform().get_scale().x


func _draw() -> void:
	if def == null:
		return
	var L := def.length
	var W := def.width
	var tyre := Color(0.08, 0.08, 0.08)
	var a := def.cg_to_front
	var b := def.wheelbase - a
	var tw := def.track_width * 0.5
	# wheels (front ones steer)
	for side in [-1.0, 1.0]:
		draw_set_transform(Vector2(a, side * tw), state.steer_angle if state else 0.0)
		draw_rect(Rect2(-0.35, -0.13, 0.7, 0.26), tyre)
		draw_set_transform(Vector2(-b, side * tw), 0.0)
		draw_rect(Rect2(-0.35, -0.15, 0.7, 0.3), tyre)
	draw_set_transform(Vector2.ZERO, 0.0)
	# body
	var body := PackedVector2Array([
		Vector2(L * 0.5, -W * 0.32), Vector2(L * 0.5, W * 0.32),
		Vector2(L * 0.38, W * 0.48), Vector2(-L * 0.45, W * 0.48),
		Vector2(-L * 0.5, W * 0.38), Vector2(-L * 0.5, -W * 0.38),
		Vector2(-L * 0.45, -W * 0.48), Vector2(L * 0.38, -W * 0.48)])
	draw_colored_polygon(body, def.colour)
	draw_polyline(body + PackedVector2Array([body[0]]), def.colour.darkened(0.45), 0.08)
	# cockpit glass
	var glass := PackedVector2Array([
		Vector2(L * 0.12, -W * 0.34), Vector2(L * 0.12, W * 0.34),
		Vector2(-L * 0.2, W * 0.3), Vector2(-L * 0.2, -W * 0.3)])
	draw_colored_polygon(glass, Color(0.1, 0.13, 0.18))
	if is_local:
		draw_arc(Vector2.ZERO, L * 0.75, 0, TAU, 32, Color(1, 1, 1, 0.25), 0.15)
	_draw_marker()
	# brake lights
	if state and state.ax < -3.0:
		draw_rect(Rect2(-L * 0.5, -W * 0.36, 0.15, 0.3), Color(1, 0.1, 0.1))
		draw_rect(Rect2(-L * 0.5, W * 0.06, 0.15, 0.3), Color(1, 0.1, 0.1))


## Zoomed out, a car is only a few pixels long, so draw an arrow marker of a
## fixed on-screen size over it (yours bigger, with a white ring).
func _draw_marker() -> void:
	var px := _px_per_m()
	var fade := clampf((5.0 - px) / 2.5, 0.0, 1.0)
	if fade <= 0.0:
		return
	var r := (11.0 if is_local else 8.0) / px
	var col := def.colour
	col.a = fade
	var arrow := PackedVector2Array([Vector2(r * 1.3, 0), Vector2(-r * 0.8, r * 0.85), Vector2(-r * 0.4, 0), Vector2(-r * 0.8, -r * 0.85)])
	draw_colored_polygon(arrow, col)
	var edge := Color(1, 1, 1, fade) if is_local else Color(0, 0, 0, 0.7 * fade)
	draw_polyline(arrow + PackedVector2Array([arrow[0]]), edge, 1.5 / px)
	if is_local:
		draw_arc(Vector2.ZERO, r * 1.9, 0, TAU, 40, Color(1, 1, 1, 0.85 * fade), 2.0 / px)
