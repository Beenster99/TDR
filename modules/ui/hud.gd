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
## Damage last seen on the player's car, to flash a warning when it changes.
var _seen_worst := 0.0
var _seen_punctures := 0
var _seen_engine_failed := false
## Lap elevation profile (bottom centre), shown on tracks with elevation.
var show_elevation_profile := true
var _profile := PackedFloat64Array()   ## 0..1 height at evenly spaced points
var _profile_range := Vector2.ZERO
const PROFILE_STEPS := 240


func setup(p_session: RaceSession) -> void:
	session = p_session
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	_build_minimap()
	_build_profile()


func flash(text: String, secs := 2.0) -> void:
	message = text
	message_time = secs


func _process(delta: float) -> void:
	size = get_viewport_rect().size
	message_time -= delta
	_watch_damage()
	queue_redraw()


## Flashes a warning when the player's car gets hurt (works the same online,
## where the player's own car is simulated on their machine).
func _watch_damage() -> void:
	if session == null or session.local_car < 0 or session.sim.damage_level == CarDamage.Level.OFF:
		return
	var c := session.sim.cars[session.local_car]
	var p := CarDamage.punctures(c)
	var failed := CarDamage.engine_failed(c)
	if failed and not _seen_engine_failed:
		flash("ENGINE FAILURE", 4.0)
	elif p > _seen_punctures:
		flash("PUNCTURE! Box for new tyres", 3.0)
	elif CarDamage.worst(c) - _seen_worst > 0.15:
		flash("DAMAGE: " + _worst_part(c), 2.5)
	_seen_punctures = p
	_seen_engine_failed = failed
	_seen_worst = CarDamage.worst(c)


static func _worst_part(c: CarState) -> String:
	var parts := {"aero": c.damage_aero, "suspension": c.damage_suspension, "steering alignment": absf(c.alignment),
		"engine": c.damage_engine, "gearbox": c.damage_gearbox}
	var best := "bodywork"
	var v := 0.05
	for k in parts:
		if parts[k] > v:
			v = parts[k]
			best = k
	return best.to_upper()


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
	_draw_race_control(vp, me)

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
		if e.penalty_s > 0.0:
			_text(Vector2(x0 + 150, 55 + p * 22), "+%ds" % int(e.penalty_s), 13, Color(1, 0.55, 0.3))
		_text(Vector2(x0 + 200, 55 + p * 22), right, 15, col, HORIZONTAL_ALIGNMENT_RIGHT, 110)

	# --- Minimap
	_draw_minimap(Vector2(vp.x - 230, 50 + rows * 22 + 10))
	if show_elevation_profile and not _profile.is_empty():
		_draw_profile(Rect2(vp.x * 0.5 - 230, vp.y - 92, 460, 70))

	_text(Vector2(0, vp.y - 14), "P / D-pad →  Pit wall", 13, Color(1, 1, 1, 0.45), HORIZONTAL_ALIGNMENT_CENTER, vp.x)
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
	if e.penalty_s > 0.0:
		_text(Vector2(170, 82), "+%d s penalty" % int(e.penalty_s), 16, Color(1, 0.55, 0.3))

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
	if c.surface >= TrackData.Surface.GRASS:
		_text(br + Vector2(120, 110), "OFF TRACK", 14, Color(1, 0.5, 0.3))

	# --- Tyres + conditions (bottom left)
	var bl := Vector2(10, vp.y - 196)
	_panel(Rect2(bl, Vector2(300, 186)))
	var tc := sim.compounds[me]
	_text(bl + Vector2(14, 24), "TYRES  " + tc.display_name.to_upper(), 14, Color(1, 1, 1, 0.7))
	var pos := [Vector2(20, 36), Vector2(80, 36), Vector2(20, 92), Vector2(80, 92)]
	for k in 4:
		var t := c.tyre_temp[k]
		var r := Rect2(bl + pos[k], Vector2(48, 48))
		draw_rect(r, _temp_colour(t, tc))
		_text(r.position + Vector2(0, 30), "%d°" % int(t), 16, Color.BLACK, HORIZONTAL_ALIGNMENT_CENTER, 48)
	var env := sim.env
	var h := env.time_of_day_h
	_text(bl + Vector2(146, 50), "%02d:%02d  %s" % [int(h), int(fmod(h, 1.0) * 60.0), SimEnvironment.weather_name(env.weather)], 15)
	_text(bl + Vector2(146, 72), "Air %d°  Track %d°" % [roundi(env.ambient_c), roundi(env.track_c)], 15)
	_text(bl + Vector2(146, 94), _surface_text(env), 15, Color(0.6, 0.85, 1) if env.wetness > 0.05 else Color.WHITE)
	var forecast := _forecast_text(env)
	if forecast != "":
		_text(bl + Vector2(146, 116), forecast, 14, Color(1, 0.85, 0.5))
	var avg := 0.0
	for k in 4:
		avg += tc.temp_grip_factor(c.tyre_temp[k])
	var off_line := c.lateral_offset - env.raceline_offset(c.track_idx)
	var grip := avg / 4.0 * env.grip_factor(tc, off_line, c.speed())
	_text(bl + Vector2(146, 138), "Grip %d%%" % int(grip * 100.0), 15, Color(0.6, 1, 0.6) if grip > 0.85 else Color(1, 0.7, 0.4))
	if sim.settings.fuel_enabled:
		_text(bl + Vector2(146, 160), "Fuel %.1f L" % c.fuel_l, 15)
	if sim.damage_level != CarDamage.Level.OFF:
		_draw_damage(Vector2(10, vp.y - 196 - 126), c, sim.damage_level == CarDamage.Level.FULL)


## Damage panel: a top view of the car with each zone coloured by how bent
## it is, flat tyres in red, and (full damage) each system's state.
func _draw_damage(o: Vector2, c: CarState, full: bool) -> void:
	_panel(Rect2(o, Vector2(300, 116)))
	_text(o + Vector2(14, 22), "DAMAGE", 14, Color(1, 1, 1, 0.7))
	var car := Rect2(o + Vector2(36, 32), Vector2(40, 74))  # nose at the top
	var b := c.body_damage
	draw_rect(car, Color(0.25, 0.25, 0.28))
	draw_rect(Rect2(car.position, Vector2(car.size.x, 16)), _damage_colour(b[CarDamage.FRONT]))
	draw_rect(Rect2(car.position + Vector2(0, car.size.y - 16), Vector2(car.size.x, 16)), _damage_colour(b[CarDamage.REAR]))
	draw_rect(Rect2(car.position + Vector2(0, 18), Vector2(9, car.size.y - 36)), _damage_colour(b[CarDamage.LEFT]))
	draw_rect(Rect2(car.position + Vector2(car.size.x - 9, 18), Vector2(9, car.size.y - 36)), _damage_colour(b[CarDamage.RIGHT]))
	var wheels := [Vector2(-10, 8), Vector2(car.size.x + 2, 8), Vector2(-10, car.size.y - 26), Vector2(car.size.x + 2, car.size.y - 26)]
	for w in 4:
		var flat := c.puncture[w] > 0.5
		draw_rect(Rect2(car.position + wheels[w], Vector2(8, 18)), Color(1, 0.15, 0.1) if flat else Color(0.08, 0.08, 0.08))
	if not full:
		_text(o + Vector2(110, 60), "Visual only", 15, Color(1, 1, 1, 0.6))
		return
	var rows := [["Aero", c.damage_aero], ["Suspension", maxf(c.damage_suspension, absf(c.alignment))],
		["Engine", c.damage_engine], ["Gearbox", c.damage_gearbox]]
	for k in rows.size():
		var y := o.y + 26 + k * 20
		var v: float = rows[k][1]
		_text(Vector2(o.x + 110, y + 12), rows[k][0], 14)
		draw_rect(Rect2(o.x + 196, y + 1, 90, 12), Color(1, 1, 1, 0.12))
		draw_rect(Rect2(o.x + 196, y + 1, 90 * v, 12), _damage_colour(v))
	var note := ""
	if CarDamage.engine_failed(c):
		note = "ENGINE FAILED"
	elif CarDamage.punctures(c) > 0:
		note = "PUNCTURE"
	elif absf(c.alignment) > 0.1:
		note = "Pulls " + ("right" if c.alignment > 0.0 else "left")
	if note != "":
		_text(Vector2(o.x + 110, o.y + 110), note, 14, Color(1, 0.55, 0.35))


static func _damage_colour(v: float) -> Color:
	if v < 0.02:
		return Color(0.3, 0.8, 0.4, 0.9)
	if v < 0.5:
		return Color(0.3, 0.8, 0.4).lerp(Color(1.0, 0.85, 0.2), v / 0.5)
	return Color(1.0, 0.85, 0.2).lerp(Color(1.0, 0.2, 0.15), clampf((v - 0.5) / 0.5, 0.0, 1.0))


static func _surface_text(env: SimEnvironment) -> String:
	if env.wetness < 0.05:
		return "Track dry"
	var s := "Track %s %d%%" % ["soaked" if env.wetness > 0.75 else ("wet" if env.wetness > 0.3 else "damp"), int(env.wetness * 100.0)]
	if env.dry_line > 0.35 and env.rain < 0.1:
		s += ", dry line"
	return s


static func _forecast_text(env: SimEnvironment) -> String:
	var t := env.next_change_in()
	if t < 0.0 or t > 300.0:
		return ""
	var nxt := env.next_weather()
	if nxt == env.weather:
		return ""
	return "%s in %d:%02d" % [SimEnvironment.weather_name(nxt), int(t) / 60, int(t) % 60]


func _temp_colour(t: float, tc: TyreCompound) -> Color:
	var x := (t - tc.optimal_temp_c) / tc.temp_window_c
	if x < 0.0:
		return Color(0.3, 0.55, 1.0).lerp(Color(0.3, 0.9, 0.4), clampf(1.0 + x, 0.0, 1.0))
	return Color(0.3, 0.9, 0.4).lerp(Color(1.0, 0.3, 0.2), clampf(x, 0.0, 1.0))


## Flag board (top centre): yellow flags, VSC, safety car, restart, and what
## the player has to do (keep the delta, give a place back...).
func _draw_race_control(vp: Vector2, me: int) -> void:
	var sim := session.sim
	var rc := sim.race_control
	var state := rc.neutralisation()
	var line := rc.instruction_for(me) if me >= 0 else ""
	var title := ""
	var col := Color(1, 0.85, 0.1)
	match state:
		"sc":
			title = "SAFETY CAR"
			if rc.stage == "in_this_lap":
				title = "SAFETY CAR IN THIS LAP"
			elif rc.stage == "restart":
				title = "RESTART"
				col = Color(0.3, 0.9, 0.4)
		"vsc":
			title = "VSC ENDING" if rc.stage == "ending" else "VIRTUAL SAFETY CAR"
		"yellow":
			if me >= 0 and rc.yellow_at(sim.cars[me].track_s):
				title = "YELLOW FLAG"
	if title == "" and line == "":
		return
	var w := 520.0
	var r := Rect2(vp.x * 0.5 - w * 0.5, 96, w, 58 if line != "" and title != "" else 34)
	if title != "":
		draw_rect(r, Color(0, 0, 0, 0.6))
		var flash := int(Time.get_ticks_msec() / 400) % 2 == 0 or state == "sc"
		draw_rect(Rect2(r.position, Vector2(w, 34)), col if flash else col.darkened(0.35))
		_text(r.position + Vector2(0, 25), title, 22, Color.BLACK, HORIZONTAL_ALIGNMENT_CENTER, w)
	if line != "" and line.to_upper() != title:
		var y := r.position.y + (52 if title != "" else 24)
		if title == "":
			draw_rect(r, Color(0, 0, 0, 0.6))
		var warn := rc.give_back.has(me)
		_text(Vector2(r.position.x, y), line, 17, Color(1, 0.5, 0.3) if warn else Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, w)


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
	var rc := sim.race_control
	var t := sim.track
	# Yellow flag zones along the track, and the safety car.
	for y in rc.yellows:
		var zone := PackedVector2Array()
		var from: float = y["from"]
		var to: float = y["to"]
		var span_m := fposmod(to - from, t.length)
		for k in 9:
			zone.append(origin + (t.position_at(from + span_m * k / 8.0) - _mm_rect.position) * scale_f)
		draw_polyline(zone, Color(1, 0.85, 0.1), 5.0)
	if rc.sc_visible:
		var sp := origin + (rc.sc_pos - _mm_rect.position) * scale_f
		draw_rect(Rect2(sp - Vector2(5, 5), Vector2(10, 10)), Color(1, 0.6, 0.1))
		_text(sp + Vector2(7, 4), "SC", 11, Color(1, 0.75, 0.3))
	for i in sim.car_count():
		var p := origin + (sim.cars[i].pos - _mm_rect.position) * scale_f
		draw_circle(p, 5.0 if i == session.local_car else 3.5, sim.defs[i].colour)
		if i == session.local_car:
			draw_arc(p, 7.0, 0, TAU, 16, Color.WHITE, 1.5)


func _build_profile() -> void:
	var t := session.sim.track
	if not t.has_elevation():
		return
	_profile_range = t.height_range()
	var span := maxf(_profile_range.y - _profile_range.x, 1.0)
	_profile.resize(PROFILE_STEPS + 1)
	for k in PROFILE_STEPS + 1:
		_profile[k] = (t.height_at(t.length * k / PROFILE_STEPS) - _profile_range.x) / span


## Height of the whole lap with every car on it, plus the gradient under
## the local car (uphill amber, downhill blue when steeper than 3%).
func _draw_profile(r: Rect2) -> void:
	var sim := session.sim
	var t := sim.track
	_panel(r.grow(8))
	var pts := PackedVector2Array()
	for k in _profile.size():
		pts.append(Vector2(r.position.x + r.size.x * k / PROFILE_STEPS, r.end.y - _profile[k] * r.size.y))
	var fill := pts.duplicate()
	fill.append(r.end)
	fill.append(Vector2(r.position.x, r.end.y))
	draw_colored_polygon(fill, Color(0.45, 0.75, 0.45, 0.3))
	draw_polyline(pts, Color(0.85, 1, 0.85, 0.9), 2.0)
	var span := maxf(_profile_range.y - _profile_range.x, 1.0)
	var me := session.local_car
	for i in sim.car_count():
		if i == me:
			continue
		_profile_dot(r, sim.cars[i].track_s, span, 3.0, sim.defs[i].colour)
	_text(r.position + Vector2(0, -12), "%d m  ↕ %d m" % [int(t.base_alt_m + (_profile_range.x if me < 0 else t.height_at(sim.cars[me].track_s))), int(span)], 14, Color(1, 1, 1, 0.75))
	if me < 0:
		return
	var s := sim.cars[me].track_s
	var x := r.position.x + r.size.x * fposmod(s, t.length) / t.length
	draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.35), 1.0)
	_profile_dot(r, s, span, 6.0, Color(1, 0.9, 0.3))
	var g := t.grade_at(s) * 100.0
	var col := Color.WHITE
	if g > 3.0:
		col = Color(1, 0.75, 0.3)
	elif g < -3.0:
		col = Color(0.5, 0.8, 1)
	_text(Vector2(r.end.x - 120, r.position.y - 12), "%s %d%%" % ["▲" if g >= 0.0 else "▼", int(round(absf(g)))], 18, col, HORIZONTAL_ALIGNMENT_RIGHT, 120)


func _profile_dot(r: Rect2, s: float, span: float, rad: float, col: Color) -> void:
	var t := session.sim.track
	var f := fposmod(s, t.length) / t.length
	var y := (t.height_at(s) - _profile_range.x) / span
	draw_circle(Vector2(r.position.x + r.size.x * f, r.end.y - y * r.size.y), rad, col)
