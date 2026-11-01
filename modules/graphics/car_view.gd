class_name CarView
extends Node2D
## Top-down car sprite drawn from the definition's size and colour.
## Visual position eases toward the sim state, hiding small snapshot corrections.

var def: CarDefinition
var state: CarState
var label: String = ""
var is_local := false
var _init_done := false
var env: SimEnvironment


func setup(p_def: CarDefinition, p_state: CarState, p_label: String, p_local: bool) -> void:
	def = p_def
	state = p_state
	label = p_label
	is_local = p_local
	z_index = 2 if p_local else 1


## Optional: conditions for spray (headlights are drawn by WeatherView).
func set_environment(p_env: SimEnvironment) -> void:
	env = p_env


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


func _draw() -> void:
	if def == null:
		return
	var L := def.length
	var W := def.width
	_draw_spray(L, W)
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
	# brake lights
	if state and state.ax < -3.0:
		draw_rect(Rect2(-L * 0.5, -W * 0.36, 0.15, 0.3), Color(1, 0.1, 0.1))
		draw_rect(Rect2(-L * 0.5, W * 0.06, 0.15, 0.3), Color(1, 0.1, 0.1))


## Spray thrown up behind the car on a wet track (hides the cars behind).
func _draw_spray(L: float, W: float) -> void:
	if env == null or state == null:
		return
	var w := env.wetness_at(state.lateral_offset - env.raceline_offset(state.track_idx))
	var amount := clampf(w * 1.3, 0.0, 1.0) * clampf((state.speed() - 8.0) / 50.0, 0.0, 1.0)
	if amount < 0.03:
		return
	var back := Vector2(-L * 0.5, 0.0)
	var t := Time.get_ticks_msec() / 1000.0
	for k in 7:
		var f := float(k) / 6.0
		var wob := sin(t * 17.0 + k * 2.3) * 0.25
		var c := back + Vector2(-0.6 - f * 5.0 * amount * 1.5, wob * (1.0 + f))
		var r := W * (0.35 + f * 0.6)
		draw_circle(c, r, Color(0.85, 0.88, 0.92, 0.45 * amount * (1.0 - f * 0.8)))

