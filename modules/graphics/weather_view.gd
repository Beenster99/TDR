class_name WeatherView
extends CanvasLayer
## Rain on the screen: falling streaks, splashes and mist over the 3D world
## (the light, the wet road, headlights and spray are done in 3D by
## WorldView, TrackView and CarView). WorldView adds this itself.

var env: SimEnvironment
var _rain: _RainOverlay


func setup(p_env: SimEnvironment) -> void:
	env = p_env
	layer = 0
	_rain = _RainOverlay.new()
	_rain.env = env
	add_child(_rain)


class _RainOverlay extends Control:
	var env: SimEnvironment
	var _drops: Array = []        ## [pos, speed, length]
	var _splashes: Array = []     ## [pos, age]
	var _rng := RandomNumberGenerator.new()

	func _ready() -> void:
		set_anchors_preset(PRESET_FULL_RECT)
		mouse_filter = MOUSE_FILTER_IGNORE

	func _process(dt: float) -> void:
		size = get_viewport_rect().size
		if env == null:
			return
		var want := int(env.rain * 700.0)
		while _drops.size() < want:
			_drops.append([Vector2(_rng.randf() * size.x, _rng.randf() * size.y), _rng.randf_range(900, 1500), _rng.randf_range(10, 26)])
		if _drops.size() > want:
			_drops.resize(want)
		var dir := Vector2(0.25, 1.0).normalized()
		for d in _drops:
			d[0] += dir * d[1] * dt
			if d[0].y > size.y or d[0].x > size.x:
				if _rng.randf() < 0.35 and _splashes.size() < 200:
					_splashes.append([Vector2(_rng.randf() * size.x, _rng.randf() * size.y), 0.0])
				d[0] = Vector2(_rng.randf() * size.x - size.y * 0.25, -_rng.randf() * 60.0)
		for sp in _splashes:
			sp[1] += dt
		_splashes = _splashes.filter(func(sp): return sp[1] < 0.25)
		queue_redraw()

	func _draw() -> void:
		if env == null or env.rain < 0.01:
			return
		var night := env.darkness()
		# Mist: heavy rain cuts visibility.
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.55, 0.6, 0.66, 0.22 * env.rain * (1.0 - 0.6 * night)))
		var col := Color(0.8, 0.85, 0.95, lerpf(0.35, 0.15, night))
		var dir := Vector2(0.25, 1.0).normalized()
		for d in _drops:
			draw_line(d[0], d[0] + dir * d[2], col, 1.2)
		for sp in _splashes:
			var k: float = sp[1] / 0.25
			draw_arc(sp[0], 2.0 + 6.0 * k, 0.0, TAU, 10, Color(col, col.a * (1.0 - k)), 1.0)
