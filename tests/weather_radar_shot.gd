extends Control
## Draws the pit wall's weather radar (WeatherRadar) for a real track and a
## changing-weather race, at the panel's normal size and enlarged, plus a
## forecast frame of the loop. Checks the picture fills in and the forecast
## agrees with what then happens.
##   godot --headless --path . res://tests/weather_radar_shot.tscn
## With a screen (xvfb, --rendering-driver opengl3): add -- <out.png> to save it.

var out := ""
var f := WeatherForecast.new()
var radars: Array = []
var rects: Array = []
var track_pts := PackedVector2Array()
var track: TrackData
var frames := 0
var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else ""
	var id: String = a[1] if a.size() > 1 else "spa"
	track = TrackCatalog.load_track(id)
	for i in range(0, track.point_count(), 3):
		track_pts.append(track.points[i])
	track_pts.append(track.points[0])
	# A race where heavy rain is on its way: find the moment it's ~12 min out.
	var env: SimEnvironment
	for seed in range(1, 200):
		env = SimEnvironment.create({"climate": {"rain_chance": 0.7}}, {"weather": "light_rain", "weather_changes": true}, seed)
		f.setup(track, seed)
		var found := false
		for k in range(1, env.timeline.size()):
			if env.timeline[k][2] > 0.6 and env.timeline[k][0] <= 900.0:
				break
			if env.timeline[k][2] > 0.6 and env.timeline[k - 1][2] > 0.2 and env.timeline[k - 1][2] < 0.6 and env.timeline[k][0] > 900.0:
				env.update(env.timeline[k][0] - 720.0)
				found = true
				break
		if found:
			break
	f.update(env)
	print("  wind %s %d km/h, range %d km; %s" % [f.heading_name(), int(f.wind_speed * 3.6), int(f.radar_range / 1000.0), f.summary()])
	for r in [Rect2(16, 16, 498, 280), Rect2(16, 312, 498, 572), Rect2(530, 16, 1054, 560), Rect2(530, 592, 520, 292), Rect2(1066, 592, 518, 292)]:
		rects.append(r)
		radars.append(WeatherRadar.new())
	radars[1].zoom = 1
	radars[3].offset_s = 900.0
	radars[4].offset_s = -600.0
	size = Vector2(1600, 900)


func _process(_d: float) -> void:
	frames += 1
	queue_redraw()
	if frames == 40:
		var filled := 0
		for r in radars:
			filled += 1 if r._rain_tex != null else 0
		check(filled == 5 and radars.size() == 5, "every radar has its rain picture (%d)" % filled)
		check(f.changes.any(func(c): return c["weather"] == "heavy_rain"), "heavy rain in the forecast: %s" % f.summary())
		if out != "":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out)
			print("  saved " + out)
		print("PASS" if fails == 0 else "FAIL (%d)" % fails)
		get_tree().quit(1 if fails > 0 else 0)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.05, 0.08))
	var font := ThemeDB.fallback_font
	for i in radars.size():
		var r: Rect2 = rects[i]
		draw_rect(r, Color(1, 1, 1, 0.05))
		draw_string(font, r.position + Vector2(12, 21), "WEATHER RADAR", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.55))
		radars[i].draw(self, font, r, f, track_pts, track.short_name, Vector2(-1, -1), [])
