class_name RaceHud
extends Control
## Race HUD drawn immediate-mode: timing, standings, tyre temps, speed/gear,
## minimap and countdown. Reads the session's sim every frame.

var session: RaceSession
var message := ""
var message_time := 0.0
var font: Font
var _minimap_pts := PackedVector2Array()
var _mm_rect := Rect2()


func setup(p_session: RaceSession) -> void:
	session = p_session
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	_build_minimap()


func flash(text: String, secs := 2.0) -> void:
	message = text
	message_time = secs


func _process(delta: float) -> void:
	size = get_viewport_rect().size
	message_time -= delta
	queue_redraw()


static func fmt_time(t: float) -> String:
	if t <= 0.0:
		return "--:--.---"
	return "%d:%06.3f" % [int(t) / 60, fmod(t, 60.0)]


func _text(pos: Vector2, s: String, size := 18, col := Color.WHITE, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(font, pos + Vector2(1, 1), s, align, width, size, Color(0, 0, 0, 0.6))
	draw_string(font, pos, s, align, width, size, col)


func _panel(r: Rect2) -> void:
	draw_rect(r, Color(0, 0, 0, 0.45))


func _draw() -> void:
	if session == null:
		return
	var sim := session.sim
	var vp := size
	var me := session.local_car
	# --- Countdown / messages
	if sim.phase == RaceSim.Phase.COUNTDOWN:
		var remaining := sim.settings.countdown_s - sim.phase_time
		var lit := clampi(int(sim.settings.countdown_s - remaining) + 1, 0, 4)
		for k in 4:
			var c := Vector2(vp.x * 0.5 - 90 + k * 60, 70)
			draw_circle(c, 22, Color(0.1, 0.1, 0.1, 0.8))
			draw_circle(c, 18, Color(0.9, 0.1, 0.1) if k < lit else Color(0.25, 0.05, 0.05))
	if message_time > 0.0:
		_text(Vector2(0, 150), message, 40, Color(1, 0.9, 0.3), HORIZONTAL_ALIGNMENT_CENTER, vp.x)

	# --- Standings (top right)
	var x0 := vp.x - 330
	var rows := mini(sim.running_order.size(), 16)
	_panel(Rect2(x0 - 10, 10, 330, 34 + rows * 22))
	_text(Vector2(x0, 32), "LAP %d / %d" % [_leader_lap(), sim.settings.laps], 16, Color(1, 1, 1, 0.8))
	for p in rows:
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var col := Color(1, 0.9, 0.3) if i == me else (Color(0.75, 0.85, 1) if not e.is_ai else Color.WHITE)
		var right := ""
		if e.finished:
			right = "FIN"
		elif e.dnf:
			right = "DNF"
		elif p > 0:
			var gap := sim.entries[sim.running_order[0]].distance - e.distance
			right = "+%.0f m" % gap if gap < sim.track.length else "+%d lap" % int(gap / sim.track.length)
		var dot := sim.defs[i].colour
		draw_rect(Rect2(x0, 42 + p * 22, 8, 14), dot)
		_text(Vector2(x0 + 14, 55 + p * 22), "%2d  %s" % [p + 1, e.driver_name.left(18)], 15, col)
		_text(Vector2(x0 + 200, 55 + p * 22), right, 15, col, HORIZONTAL_ALIGNMENT_RIGHT, 110)

	# --- Minimap
	_draw_minimap(Vector2(vp.x - 230, 50 + rows * 22 + 10))

	if me < 0:
		_text(Vector2(20, 40), "SPECTATING", 22)
		return
	var e := sim.entries[me]
	var c := sim.cars[me]
	# --- Timing (top left)
	_panel(Rect2(10, 10, 300, 150))
	_text(Vector2(24, 48), "P%d / %d" % [e.position, sim.car_count()], 34)
	var lap_now := mini(e.laps_done + 1, sim.settings.laps)
	_text(Vector2(170, 48), "LAP %d/%d" % [lap_now, sim.settings.laps], 20)
	var cur := sim.race_time - e.lap_start_time if e.started_lap and not e.finished else 0.0
	_text(Vector2(24, 82), "Time  " + fmt_time(cur), 18)
	_text(Vector2(24, 106), "Last  " + fmt_time(e.lap_times[-1] if e.lap_times.size() > 0 else 0.0), 18, Color(1, 1, 1, 0.8))
	_text(Vector2(24, 130), "Best  " + fmt_time(e.best_lap), 18, Color(0.6, 1, 0.6))

	# --- Speed / gear / rpm (bottom right)
	var br := Vector2(vp.x - 260, vp.y - 130)
	_panel(Rect2(br, Vector2(250, 120)))
	_text(br + Vector2(14, 56), "%3d" % int(c.speed() * 3.6), 48)
	_text(br + Vector2(120, 56), "km/h", 16, Color(1, 1, 1, 0.7))
	_text(br + Vector2(190, 58), "R" if c.gear < 0 else str(c.gear), 44, Color(1, 0.9, 0.3))
	var d := sim.defs[me]
	var frac := clampf(c.rpm / d.redline_rpm, 0.0, 1.0)
	draw_rect(Rect2(br + Vector2(14, 78), Vector2(222, 12)), Color(1, 1, 1, 0.15))
	draw_rect(Rect2(br + Vector2(14, 78), Vector2(222 * frac, 12)), Color(1, 0.25, 0.2) if frac > 0.92 else Color(0.4, 0.85, 1))
	_text(br + Vector2(14, 110), "%5d rpm" % int(c.rpm), 14, Color(1, 1, 1, 0.7))
	if c.surface >= CarState.Surface.GRASS:
		_text(br + Vector2(120, 110), "OFF TRACK", 14, Color(1, 0.5, 0.3))

	# --- Tyres + conditions (bottom left)
	var bl := Vector2(10, vp.y - 170)
	_panel(Rect2(bl, Vector2(260, 160)))
	_text(bl + Vector2(14, 24), "TYRES", 14, Color(1, 1, 1, 0.7))
	var tc := sim.compounds[me]
	var pos := [Vector2(20, 36), Vector2(80, 36), Vector2(20, 92), Vector2(80, 92)]
	for k in 4:
		var t := c.tyre_temp[k]
		var r := Rect2(bl + pos[k], Vector2(48, 48))
		draw_rect(r, _temp_colour(t, tc))
		_text(r.position + Vector2(0, 30), "%d°" % int(t), 16, Color.BLACK, HORIZONTAL_ALIGNMENT_CENTER, 48)
	var env := sim.env
	_text(bl + Vector2(146, 50), "Air %d°C" % int(env.ambient_c), 15)
	_text(bl + Vector2(146, 72), "Track %d°C" % int(env.track_c), 15)
	_text(bl + Vector2(146, 94), "%02d:00 %s" % [int(env.time_of_day_h), env.weather], 15)
	if sim.settings.fuel_enabled:
		_text(bl + Vector2(146, 116), "Fuel %.1f L" % c.fuel_l, 15)
	var avg := 0.0
	for k in 4:
		avg += tc.temp_grip_factor(c.tyre_temp[k])
	_text(bl + Vector2(146, 138), "Grip %d%%" % int(avg / 4.0 * 100.0), 15, Color(0.6, 1, 0.6))


func _temp_colour(t: float, tc: TyreCompound) -> Color:
	var x := (t - tc.optimal_temp_c) / tc.temp_window_c
	if x < 0.0:
		return Color(0.3, 0.55, 1.0).lerp(Color(0.3, 0.9, 0.4), clampf(1.0 + x, 0.0, 1.0))
	return Color(0.3, 0.9, 0.4).lerp(Color(1.0, 0.3, 0.2), clampf(x, 0.0, 1.0))


func _leader_lap() -> int:
	var sim := session.sim
	if sim.running_order.is_empty():
		return 0
	var e := sim.entries[sim.running_order[0]]
	return mini(e.laps_done + 1, sim.settings.laps)


func _build_minimap() -> void:
	var t := session.sim.track
	var lo := Vector2(INF, INF)
	var hi := -lo
	for p in t.points:
		lo = lo.min(p)
		hi = hi.max(p)
	var span := hi - lo
	var scale_f := 200.0 / maxf(span.x, span.y)
	_mm_rect = Rect2(lo, span)
	for i in range(0, t.point_count(), 4):
		_minimap_pts.append((t.points[i] - lo) * scale_f)
	_minimap_pts.append(_minimap_pts[0])
	set_meta("mm_scale", scale_f)


func _draw_minimap(origin: Vector2) -> void:
	var scale_f: float = get_meta("mm_scale", 1.0)
	var span := _mm_rect.size * scale_f
	_panel(Rect2(origin - Vector2(10, 10), span + Vector2(20, 20)))
	var pts := PackedVector2Array()
	for p in _minimap_pts:
		pts.append(origin + p)
	draw_polyline(pts, Color(1, 1, 1, 0.7), 3.0)
	var sim := session.sim
	for i in sim.car_count():
		var p := origin + (sim.cars[i].pos - _mm_rect.position) * scale_f
		draw_circle(p, 5.0 if i == session.local_car else 3.5, sim.defs[i].colour)
		if i == session.local_car:
			draw_arc(p, 7.0, 0, TAU, 16, Color.WHITE, 1.5)
