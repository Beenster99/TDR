class_name WeatherView
extends Node2D
## Shows the conditions: daylight and dusk colour, a darker wet track with a
## drying racing line, and rain (screen-space streaks, splashes and mist).
## Add it right after the TrackView so it draws over the track but under cars.

var env: SimEnvironment
var track: TrackData
var track_view: CanvasItem
var _sky: CanvasModulate
var _rain_layer: CanvasLayer
var _rain: _RainOverlay
var _line_alpha := -1.0
var _lights: _Headlights


func setup(p_env: SimEnvironment, p_track: TrackData, p_track_view: CanvasItem) -> void:
	env = p_env
	track = p_track
	track_view = p_track_view
	_sky = CanvasModulate.new()
	add_child(_sky)
	_rain_layer = CanvasLayer.new()
	_rain_layer.layer = 0
	add_child(_rain_layer)
	_rain = _RainOverlay.new()
	_rain.env = env
	_rain_layer.add_child(_rain)
	# Headlights sit on their own canvas so the night tint doesn't dim them.
	var light_layer := CanvasLayer.new()
	light_layer.layer = 0
	light_layer.follow_viewport_enabled = true
	add_child(light_layer)
	move_child(light_layer, _rain_layer.get_index())
	_lights = _Headlights.new()
	_lights.env = env
	light_layer.add_child(_lights)
	_apply()
	queue_redraw()


## Gives a car headlights after dark and in heavy rain.
func add_headlights(car: Node2D, length: float) -> void:
	_lights.cars.append([car, length])


func _process(_dt: float) -> void:
	_apply()


func _apply() -> void:
	if env == null:
		return
	_sky.color = sky_colour(env)
	if track_view:
		track_view.modulate = Color.WHITE.lerp(Color(0.66, 0.71, 0.82), env.wetness)
	var a := clampf(env.wetness * env.dry_line * 1.4, 0.0, 1.0)
	if absf(a - _line_alpha) > 0.01:
		_line_alpha = a
		modulate.a = a


## Light colour for the world: midday white, golden low sun, blue night, grey cloud and rain.
static func sky_colour(e: SimEnvironment) -> Color:
	var dark := e.darkness()
	var h := e.time_of_day_h
	var low_sun := clampf(1.0 - absf(h - (7.0 if h < 12.0 else 18.3)) / 1.6, 0.0, 1.0) * (1.0 - e.cloud)
	var c := Color.WHITE.lerp(Color(1.0, 0.82, 0.62), low_sun * 0.7)
	c = c.lerp(Color(0.8, 0.83, 0.88), e.cloud * 0.6)
	c = c.lerp(Color(0.66, 0.7, 0.76), e.rain * 0.6)
	return c.lerp(Color(0.19, 0.21, 0.34), dark)


## The drier strip along the racing line (faded in with modulate.a).
func _draw() -> void:
	if track == null or track.raceline.size() < 2:
		return
	var pts := track.raceline.duplicate()
	pts.append(pts[0])
	draw_polyline(pts, Color(0.3, 0.3, 0.32), SimEnvironment.DRY_LINE_WIDTH * 1.6, true)


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


class _Headlights extends Node2D:
	var env: SimEnvironment
	var cars: Array = []          ## [[Node2D, car length], ...]
	static var _beam: Texture2D

	func _ready() -> void:
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = m

	func _process(_dt: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if env == null:
			return
		var level := maxf(env.darkness(), clampf((env.rain - 0.5) * 0.8, 0.0, 0.4))
		if level < 0.1:
			return
		var tex := _beam_texture()
		var col := Color(1.0, 0.95, 0.8, 0.45 * level)
		for c in cars:
			var car: Node2D = c[0]
			if not is_instance_valid(car):
				continue
			draw_set_transform(car.position, car.rotation)
			# 40 m long beam starting at the nose.
			draw_texture_rect(tex, Rect2(c[1] * 0.5, -10.0, 40.0, 20.0), false, col)
			draw_rect(Rect2(-c[1] * 0.5 - 0.2, -0.7, 0.25, 1.4), Color(1, 0.1, 0.05, 0.6 * level))
		draw_set_transform(Vector2.ZERO, 0.0)

	## A soft cone of light pointing along +X from its left edge.
	static func _beam_texture() -> Texture2D:
		if _beam:
			return _beam
		var w := 128
		var h := 64
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		for y in h:
			for x in w:
				var p := Vector2(x + 0.5, y + 0.5 - h * 0.5)
				var ang := absf(atan2(p.y, p.x * 0.5))
				var cone := clampf(1.0 - ang / 0.42, 0.0, 1.0)
				var fall := clampf(1.0 - p.x / w, 0.0, 1.0)
				var a := cone * cone * sqrt(fall)
				img.set_pixel(x, y, Color(a, a, a, 1.0))
		_beam = ImageTexture.create_from_image(img)
		return _beam
