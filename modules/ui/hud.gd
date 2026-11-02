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
## Timing tower (left column): position, badge, driver, last lap, gap to the
## car ahead. On/off is the player's choice, GameData.prefs["hud_timing_tower"]
## (Settings > Gameplay, or H in a race).
const PREF_TOWER := "hud_timing_tower"
const TOWER_W := 352.0
const TOWER_ROW := 24.0
## How long a finished lap's sectors stay up before the next lap's go live.
const LAP_HOLD_S := 4.0
const SECTOR_PURPLE := Color(0.78, 0.45, 1.0)
const SECTOR_GREEN := Color(0.35, 0.95, 0.45)
const SECTOR_YELLOW := Color(1.0, 0.82, 0.25)
## Gap trend to the cars ahead and behind, sampled every couple of seconds.
var _gap_sample := Vector2(-1, -1)
var _gap_trend := Vector2.ZERO
var _gap_sample_t := -99.0


func setup(p_session: RaceSession) -> void:
	session = p_session
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	_build_minimap()


## The player's prefs (GameData autoload, looked up by path so this class
## also loads in the headless tests, where autoloads aren't registered).
func _prefs() -> Dictionary:
	var gd := get_node_or_null("/root/GameData")
	return gd.prefs if gd != null else {}


func show_tower() -> bool:
	return bool(_prefs().get(PREF_TOWER, true))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("hud_tower"):
		var gd := get_node_or_null("/root/GameData")
		if gd == null:
			return
		gd.prefs[PREF_TOWER] = not show_tower()
		if gd.has_method("save_prefs"):
			gd.call("save_prefs")
		flash("Timing tower " + ("on" if show_tower() else "off"), 1.2)


## Team radio from the pit wall (co-op): shown as a banner for a few seconds.
var radio_msg: Dictionary = {}
var radio_time := 0.0


func show_radio(msg: Dictionary, secs := 5.0) -> void:
	radio_msg = msg
	radio_time = secs


func flash(text: String, secs := 2.0) -> void:
	message = text
	message_time = secs


func _process(delta: float) -> void:
	size = get_viewport_rect().size
	message_time -= delta
	radio_time -= delta
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
	if radio_time > 0.0 and not radio_msg.is_empty():
		_draw_radio(vp)

	# --- Standings: timing tower on the left, or the compact list top right
	var tower := show_tower()
	var rows := 0
	if tower:
		_draw_tower(vp, me)
	else:
		rows = _draw_standings(vp, me)
	_draw_minimap(Vector2(vp.x - 230, 50 + rows * 22 + 10 if rows > 0 else 20))

	_text(Vector2(0, vp.y - 14), "P / D-pad →  Pit wall", 13, Color(1, 1, 1, 0.45), HORIZONTAL_ALIGNMENT_CENTER, vp.x)
	if me < 0:
		_text(Vector2(20, 40), "SPECTATING", 22)
		return
	var e := sim.entries[me]
	var c := sim.cars[me]
	# --- Timing (top left, beside the tower when it's on)
	var lx := TOWER_W + 20.0 if tower else 10.0
	_panel(Rect2(lx, 10, 300, 150))
	_text(Vector2(lx + 14, 48), "P%d / %d" % [e.position, sim.car_count()], 34)
	var lap_now := mini(e.laps_done + 1, sim.settings.laps)
	_text(Vector2(lx + 160, 48), "LAP %d/%d" % [lap_now, sim.settings.laps], 20)
	var cur := sim.race_time - e.lap_start_time if e.started_lap and not e.finished else 0.0
	_text(Vector2(lx + 14, 82), "Time  " + fmt_time(cur), 18)
	_text(Vector2(lx + 14, 106), "Last  " + fmt_time(e.lap_times[-1] if e.lap_times.size() > 0 else 0.0), 18, Color(1, 1, 1, 0.8))
	_text(Vector2(lx + 14, 130), "Best  " + fmt_time(e.best_lap), 18, Color(0.6, 1, 0.6))
	if e.penalty_s > 0.0:
		_text(Vector2(lx + 160, 82), "+%d s penalty" % int(e.penalty_s), 16, Color(1, 0.55, 0.3))

	# --- Sectors and the gaps ahead / behind (bottom centre)
	_draw_sectors_and_gaps(vp, me)

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
		if sim.settings.tyre_wear_enabled:
			_text(r.position + Vector2(0, 46), "%d%%" % roundi((1.0 - c.tyre_wear[k]) * 100.0), 11, Color(0, 0, 0, 0.75), HORIZONTAL_ALIGNMENT_CENTER, 48)
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
		var fl := sim.pits.fuel_laps(me)
		_text(bl + Vector2(146, 160), "Fuel %.1f L  %s" % [c.fuel_l, "(%.1f laps)" % fl if fl < 99.0 else ""], 15,
			Color(1, 0.5, 0.3) if fl < 1.5 else Color.WHITE)
	if sim.pits.enabled:
		_draw_pit_panel(Vector2(lx, 170), me)
	if sim.damage_level != CarDamage.Level.OFF:
		_draw_damage(Vector2(lx, vp.y - 196 - 126), c, sim.damage_level == CarDamage.Level.FULL)


## Pit panel (left, under the timing): pit call, limiter, plan, stops, stop time.
func _draw_pit_panel(o: Vector2, me: int) -> void:
	var sim := session.sim
	var pits := sim.pits
	var e := sim.entries[me]
	var p: Dictionary = e.pit
	var plan: Dictionary = p["plan"]
	var phase: String = p["phase"]
	var need := sim.settings.mandatory_pit_stops
	var busy: bool = phase != PitRules.PHASE_NONE or p["box"] or p["limiter"]
	var h := 114 if need > 0 or busy or sim.settings.fuel_enabled or sim.settings.tyre_wear_enabled else 0
	if h == 0 and e.penalty_s <= 0.0:
		return
	_panel(Rect2(o, Vector2(300, h + (22 if e.penalty_s > 0.0 else 0))))
	var y := o.y + 22
	if h > 0:
		var head := "PIT"
		var hc := Color(1, 1, 1, 0.7)
		match phase:
			PitRules.PHASE_APPROACH: head = "BOXING: CAR DRIVING TO THE PITS"
			PitRules.PHASE_ENTRY: head = "PIT LANE: %d KM/H LIMIT" % roundi(sim.track.pit_speed_limit * 3.6)
			PitRules.PHASE_LIMIT: head = "PIT LANE, TO YOUR BOX"
			PitRules.PHASE_SERVICE: head = "PIT STOP  %.1f s" % float(p["service_left"])
			PitRules.PHASE_LEAVE, PitRules.PHASE_EXIT: head = "PIT EXIT"
			_:
				if p["box"]:
					head = "BOX THIS LAP"
		if phase != PitRules.PHASE_NONE or p["box"]:
			hc = Color(1, 0.85, 0.2)
		_text(Vector2(o.x + 14, y), head, 15, hc)
		if p["limiter"]:
			_text(Vector2(o.x + 214, y), "LIMITER", 15, Color(0.4, 0.9, 1))
		y += 22
		if need > 0:
			var done := int(p["window_stops"])
			_text(Vector2(o.x + 14, y), "Stops %d/%d  window laps %d-%d" % [done, need, pits.window_open, pits.window_close], 14,
				Color(0.6, 1, 0.6) if done >= need else Color.WHITE)
		else:
			_text(Vector2(o.x + 14, y), "Stops %d" % int(p["stops"]), 14)
		y += 22
		var fuel_txt := ""
		if sim.settings.fuel_enabled:
			fuel_txt = "  fuel " + fuel_plan_text(float(plan["fuel"]))
		_text(Vector2(o.x + 14, y), "Next: tyres %s%s" % [tyre_plan_text(sim, me, str(plan["tyre"])), fuel_txt], 14, Color(1, 1, 1, 0.85))
		y += 22
		var work := pits.service_for(me, plan)
		_text(Vector2(o.x + 14, y), "Stop about %.0f s%s" % [work["total_s"], "  + repairs" if float(work["repair_s"]) > 0.0 else ""], 14, Color(1, 1, 1, 0.7))
		y += 22
	if e.penalty_s > 0.0:
		_text(Vector2(o.x + 14, y), "Penalties +%d s" % int(e.penalty_s), 14, Color(1, 0.5, 0.3))


func _draw_radio(vp: Vector2) -> void:
	var who := str(radio_msg.get("from", "Pit wall"))
	var role := str(radio_msg.get("role", "")).replace("_", " ")
	var line := "%s%s: %s" % [who, (" (%s)" % role) if role != "" else "", radio_msg.get("text", "")]
	var w := minf(font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x + 120, vp.x - 40)
	var r := Rect2((vp.x - w) * 0.5, 196, w, 44)
	var a := clampf(radio_time / 0.5, 0.0, 1.0)
	draw_rect(r, Color(0.02, 0.04, 0.08, 0.8 * a))
	draw_rect(r, Color(1, 0.88, 0.35, 0.8 * a), false, 2.0)
	_text(r.position + Vector2(14, 30), "RADIO", 16, Color(1, 0.88, 0.35, a))
	_text(r.position + Vector2(84, 30), line, 22, Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_LEFT, w - 96)


static func tyre_plan_text(sim: RaceSim, car: int, choice: String) -> String:
	match choice:
		PitRules.TYRE_AUTO:
			var id := sim.pits.compound_for_conditions(car)
			return "auto (%s)" % (sim.tyre_defs[id].display_name if sim.tyre_defs.has(id) else id)
		PitRules.TYRE_KEEP:
			return "no change"
		PitRules.TYRE_DRY:
			var dry := sim.dry_compound[car]
			return sim.tyre_defs[dry].display_name if sim.tyre_defs.has(dry) else "dry"
	return sim.tyre_defs[choice].display_name if sim.tyre_defs.has(choice) else choice


static func fuel_plan_text(fuel: float) -> String:
	if fuel < 0.0:
		return "to the end"
	if fuel == 0.0:
		return "none"
	return "+%d L" % int(fuel)


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


## The compact standings list (top right), used when the timing tower is off.
## Returns how many rows it drew.
func _draw_standings(vp: Vector2, me: int) -> int:
	var sim := session.sim
	var x0 := vp.x - 330
	var rows := mini(sim.running_order.size(), 16)
	_panel(Rect2(x0 - 10, 10, 330, 34 + rows * 22))
	_text(Vector2(x0, 32), "LAP %d / %d" % [_leader_lap(), sim.settings.laps], 16, Color(1, 1, 1, 0.8))
	for p in rows:
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var col := Color(1, 0.9, 0.3) if i == me else (Color(0.75, 0.85, 1) if not e.is_ai else Color.WHITE)
		var right := _status_text(i)
		if right == "" and p > 0:
			var gap := sim.entries[sim.running_order[0]].distance - e.distance
			right = "+%.0f m" % gap if gap < sim.track.length else "+%d lap" % int(gap / sim.track.length)
		draw_rect(Rect2(x0, 42 + p * 22, 8, 14), sim.defs[i].colour)
		_text(Vector2(x0 + 14, 55 + p * 22), "%2d  %s" % [p + 1, e.driver_name.left(18)], 15, col)
		if sim.pits.enabled and int(e.pit.get("stops", 0)) > 0:
			_text(Vector2(x0 + 172, 55 + p * 22), str(e.pit["stops"]), 12, Color(1, 1, 1, 0.55))
		if e.penalty_s > 0.0:
			_text(Vector2(x0 + 140, 55 + p * 22), "+%ds" % int(e.penalty_s), 13, Color(1, 0.55, 0.3))
		_text(Vector2(x0 + 200, 55 + p * 22), right, 15, col, HORIZONTAL_ALIGNMENT_RIGHT, 110)
	return rows


## PIT / FIN / DNF for a car, or "" while it's racing.
func _status_text(i: int) -> String:
	var sim := session.sim
	var e := sim.entries[i]
	if e.finished:
		return "FIN"
	if e.dnf:
		return "DNF"
	if sim.in_pit_lane(i):
		return "PIT"
	return ""


## Which rows of the running order the tower shows: everyone if they fit,
## otherwise the top three and a window around the player.
static func tower_rows(order_size: int, my_pos: int, max_rows: int) -> Array[int]:
	var out: Array[int] = []
	if order_size <= max_rows:
		for p in order_size:
			out.append(p)
		return out
	var top := 3
	for p in top:
		out.append(p)
	var span := max_rows - top
	var from := clampi(my_pos - span / 2, top, order_size - span)
	for p in range(from, from + span):
		out.append(p)
	return out


## Timing tower (left column): position, manufacturer badge, driver, last lap
## and the gap to the car ahead. The player's row is highlighted.
func _draw_tower(vp: Vector2, me: int) -> void:
	var sim := session.sim
	var tel := session.telemetry
	var n := sim.running_order.size()
	var max_rows := maxi(int((vp.y - 206.0 - 84.0) / TOWER_ROW), 6)  # keep clear of the tyre panel
	var my_pos := sim.running_order.find(me)
	var shown := tower_rows(n, maxi(my_pos, 0), max_rows)
	var x := 10.0
	var top := 10.0
	var h := 62.0 + shown.size() * TOWER_ROW + (6.0 if shown.size() < n else 0.0)
	_panel(Rect2(x, top, TOWER_W, h))
	_text(Vector2(x + 12, top + 26), "LAP %d / %d" % [_leader_lap(), sim.settings.laps], 18, Color.WHITE)
	_text(Vector2(x + 12, top + 26), "%d CARS" % n, 14, Color(1, 1, 1, 0.55), HORIZONTAL_ALIGNMENT_RIGHT, TOWER_W - 24)
	var head := Color(1, 1, 1, 0.45)
	_text(Vector2(x + 12, top + 50), "POS", 11, head)
	_text(Vector2(x + 86, top + 50), "DRIVER", 11, head)
	_text(Vector2(x + 202, top + 50), "LAST", 11, head)
	_text(Vector2(x + 274, top + 50), "GAP", 11, head, HORIZONTAL_ALIGNMENT_RIGHT, 66)
	var y := top + 58.0
	var prev := -1
	for p in shown:
		if prev >= 0 and p != prev + 1:
			draw_line(Vector2(x + 12, y + 2), Vector2(x + TOWER_W - 12, y + 2), Color(1, 1, 1, 0.25), 1.0)
			y += 6.0
		prev = p
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var mine := i == me
		if mine:
			draw_rect(Rect2(x + 2, y, TOWER_W - 4, TOWER_ROW), Color(1, 0.85, 0.2, 0.22))
		elif p % 2 == 1:
			draw_rect(Rect2(x + 2, y, TOWER_W - 4, TOWER_ROW), Color(1, 1, 1, 0.04))
		var col := Color(1, 0.92, 0.45) if mine else (Color(0.75, 0.85, 1) if not e.is_ai else Color.WHITE)
		var base := y + TOWER_ROW - 6.0
		draw_rect(Rect2(x + 4, y + 3, 4, TOWER_ROW - 6), sim.defs[i].colour)
		_text(Vector2(x + 12, base), str(p + 1), 16, col, HORIZONTAL_ALIGNMENT_RIGHT, 26)
		draw_badge(Rect2(x + 44, y + 3, 36, TOWER_ROW - 6), sim.defs[i])
		_text(Vector2(x + 86, base), short_name(e.driver_name), 15, col)
		var tc: CarTelemetry = tel.cars[i] if tel != null and i < tel.cars.size() else null
		var last := e.lap_times[-1] if e.lap_times.size() > 0 else 0.0
		var last_col := Color(1, 1, 1, 0.8)
		if last > 0.0 and tel != null and tel.fastest_lap > 0.0 and absf(last - tel.fastest_lap) < 0.0005:
			last_col = SECTOR_PURPLE
		_text(Vector2(x + 202, base), fmt_lap(last), 15, last_col)
		var gap := _status_text(i)
		var gap_col := Color(1, 0.6, 0.3) if gap == "PIT" else Color(1, 1, 1, 0.8)
		if gap == "":
			if p == 0:
				gap = "Leader"
				gap_col = Color(1, 1, 1, 0.55)
			else:
				gap = _interval_text(sim.running_order[p - 1], i, tc.interval if tc != null else 0.0)
		_text(Vector2(x + 274, base), gap, 15, gap_col, HORIZONTAL_ALIGNMENT_RIGHT, 66)
		if e.penalty_s > 0.0:
			_text(Vector2(x + 166, base), "+%ds" % int(e.penalty_s), 11, Color(1, 0.55, 0.3))
		y += TOWER_ROW


## Gap from car `behind` to car `ahead`: whole laps when it's been lapped,
## otherwise the timed interval ("+1.234").
func _interval_text(ahead: int, behind: int, secs: float) -> String:
	var sim := session.sim
	var laps := int((sim.entries[ahead].distance - sim.entries[behind].distance) / sim.track.length)
	if laps >= 1:
		return "+%d LAP%s" % [laps, "S" if laps > 1 else ""]
	if secs <= 0.0:
		return "--"
	return "+%.3f" % secs if secs < 100.0 else "+%.0f" % secs


## Bottom centre: this lap's sector times (purple = fastest of anyone, green =
## personal best, yellow = slower; white is the sector being driven now),
## flanked by the gap to the car ahead (left) and behind (right).
func _draw_sectors_and_gaps(vp: Vector2, me: int) -> void:
	var sim := session.sim
	var e := sim.entries[me]
	var n := sim.track.sectors.size()
	var box_w := 108.0
	var gap_w := 210.0
	var w := gap_w * 2.0 + n * box_w + (n - 1) * 6.0 + 24.0
	var r := Rect2(vp.x * 0.5 - w * 0.5, vp.y - 110, w, 82)
	_panel(r)
	# Sectors
	var since_line := sim.race_time - e.sector_start_time
	var hold := e.sector_times.is_empty() and e.last_sector_times.size() == n and e.laps_done > 0 \
		and (since_line < LAP_HOLD_S or e.finished)
	var x := r.position.x + 12.0 + gap_w
	for k in n:
		var br := Rect2(x + k * (box_w + 6.0), r.position.y + 10, box_w, 62)
		var t := 0.0
		var col := Color(1, 1, 1, 0.35)
		var bar := Color(1, 1, 1, 0.12)
		if hold:
			t = e.last_sector_times[k]
			col = sector_colour(k, t, me)
			bar = col
		elif k < e.sector_times.size():
			t = e.sector_times[k]
			col = sector_colour(k, t, me)
			bar = col
		elif k == e.sector_times.size() and e.started_lap and not e.finished and sim.phase == RaceSim.Phase.RACING:
			t = since_line
			col = Color.WHITE
			bar = Color(1, 1, 1, 0.5)
		elif k < e.last_sector_times.size():
			t = e.last_sector_times[k]  # last lap's time, dimmed, until this lap gets there
		draw_rect(br, Color(0, 0, 0, 0.35))
		draw_rect(Rect2(br.position, Vector2(br.size.x, 5)), bar)
		_text(br.position + Vector2(0, 24), "S%d" % (k + 1), 13, Color(1, 1, 1, 0.6), HORIZONTAL_ALIGNMENT_CENTER, box_w)
		_text(br.position + Vector2(0, 52), fmt_sector(t), 22, col, HORIZONTAL_ALIGNMENT_CENTER, box_w)
	# Gaps
	_sample_gap_trend(me)
	var my_pos := sim.running_order.find(me)
	var ahead := sim.running_order[my_pos - 1] if my_pos > 0 else -1
	var behind := sim.running_order[my_pos + 1] if my_pos >= 0 and my_pos + 1 < sim.running_order.size() else -1
	var tc: CarTelemetry = session.telemetry.cars[me] if session.telemetry != null and me < session.telemetry.cars.size() else null
	var left := Rect2(r.position.x + 12, r.position.y + 10, gap_w - 12, 62)
	var right := Rect2(r.end.x - gap_w, r.position.y + 10, gap_w - 12, 62)
	_draw_gap(left, "AHEAD", ahead, my_pos, _interval_text(ahead, me, tc.interval if tc != null else 0.0) if ahead >= 0 else "", -_gap_trend.x, HORIZONTAL_ALIGNMENT_LEFT)
	var behind_txt := ""
	if behind >= 0:
		behind_txt = _interval_text(me, behind, tc.gap_behind if tc != null else 0.0).replace("+", "-")
	_draw_gap(right, "BEHIND", behind, my_pos + 2, behind_txt, _gap_trend.y, HORIZONTAL_ALIGNMENT_RIGHT)


## One side of the gap readout. `trend` > 0 means the gap is growing in the
## player's favour (green), < 0 means they're losing time (red).
func _draw_gap(r: Rect2, label: String, car: int, pos: int, gap: String, trend: float, align: HorizontalAlignment) -> void:
	var sim := session.sim
	if car < 0:
		_text(r.position + Vector2(0, 22), label, 12, Color(1, 1, 1, 0.45), align, r.size.x)
		_text(r.position + Vector2(0, 50), "LEADING" if label == "AHEAD" else "—", 20, Color(1, 1, 1, 0.5), align, r.size.x)
		return
	_text(r.position + Vector2(0, 22), "%s  P%d  %s" % [label, pos, short_name(sim.entries[car].driver_name)], 13, Color(1, 1, 1, 0.65), align, r.size.x)
	var col := Color.WHITE
	if trend > 0.05:
		col = SECTOR_GREEN
	elif trend < -0.05:
		col = Color(1, 0.45, 0.4)
	_text(r.position + Vector2(0, 54), gap, 28, col, align, r.size.x)


## Every 2 s: did the gaps to the cars ahead and behind shrink or grow?
func _sample_gap_trend(me: int) -> void:
	var tel := session.telemetry
	if tel == null or me >= tel.cars.size():
		return
	var now := session.sim.race_time
	if now - _gap_sample_t < 2.0 and now >= _gap_sample_t:
		return
	var tc := tel.cars[me]
	var cur := Vector2(tc.interval, tc.gap_behind)
	if _gap_sample.x > 0.0 and cur.x > 0.0:
		_gap_trend.x = cur.x - _gap_sample.x   # ahead: growing gap is bad
	else:
		_gap_trend.x = 0.0
	if _gap_sample.y > 0.0 and cur.y > 0.0:
		_gap_trend.y = cur.y - _gap_sample.y   # behind: growing gap is good
	else:
		_gap_trend.y = 0.0
	_gap_sample = cur
	_gap_sample_t = now


## Purple for the fastest sector anyone has done, green for a personal best,
## yellow for slower.
func sector_colour(k: int, t: float, car: int) -> Color:
	var tel := session.telemetry
	if t <= 0.0 or tel == null:
		return Color.WHITE
	var overall := tel.best_sectors[k] if k < tel.best_sectors.size() else 0.0
	var personal := 0.0
	if car < tel.cars.size() and k < tel.cars[car].best_sectors.size():
		personal = tel.cars[car].best_sectors[k]
	if overall <= 0.0 or t <= overall + 0.0005:
		return SECTOR_PURPLE
	if personal <= 0.0 or t <= personal + 0.0005:
		return SECTOR_GREEN
	return SECTOR_YELLOW


static func fmt_sector(t: float) -> String:
	if t <= 0.0:
		return "--.---"
	if t >= 60.0:
		return fmt_time(t)
	return "%.3f" % t


static func fmt_lap(t: float) -> String:
	return "--:--.---" if t <= 0.0 else fmt_time(t)


## "Max Verstappen" -> "M. Verstappen", kept short enough for the tower.
static func short_name(full: String) -> String:
	var parts := full.strip_edges().split(" ", false)
	var s := full.strip_edges()
	if s.length() > 15 and parts.size() >= 2:
		s = "%s. %s" % [parts[0].left(1), " ".join(parts.slice(1))]
	return s.left(15)


## Manufacturer badges, drawn as monograms in the brand's colours (we don't
## ship real logos). Keyed by a lower-case word found in the car's name or its
## "manufacturer" field.
const BADGES := {
	"bmw": ["BMW", Color(1, 1, 1), Color(0.0, 0.4, 0.8)],
	"ferrari": ["FER", Color(1.0, 0.85, 0.0), Color(0.05, 0.05, 0.05)],
	"porsche": ["POR", Color(0.08, 0.08, 0.08), Color(0.85, 0.7, 0.3)],
	"lamborghini": ["LAM", Color(0.08, 0.08, 0.08), Color(0.9, 0.75, 0.3)],
	"mclaren": ["McL", Color(1.0, 0.5, 0.0), Color(0.05, 0.05, 0.05)],
	"mercedes": ["AMG", Color(0.75, 0.77, 0.8), Color(0.05, 0.05, 0.05)],
	"amg": ["AMG", Color(0.75, 0.77, 0.8), Color(0.05, 0.05, 0.05)],
	"lotus": ["LOT", Color(0.0, 0.4, 0.2), Color(1.0, 0.85, 0.1)],
	"aston": ["AM", Color(0.0, 0.33, 0.25), Color(0.85, 1.0, 0.6)],
	"audi": ["AUDI", Color(0.1, 0.1, 0.1), Color(0.9, 0.9, 0.9)],
	"toyota": ["TOY", Color(0.9, 0.1, 0.15), Color(1, 1, 1)],
	"cadillac": ["CAD", Color(0.1, 0.1, 0.15), Color(0.85, 0.75, 0.4)],
	"peugeot": ["PEU", Color(0.12, 0.12, 0.12), Color(0.6, 1.0, 0.3)],
	"alpine": ["ALP", Color(0.0, 0.35, 0.8), Color(1, 1, 1)],
	"acura": ["ACU", Color(0.1, 0.1, 0.1), Color(0.95, 0.2, 0.2)],
	"oreca": ["ORE", Color(0.0, 0.25, 0.55), Color(1, 1, 1)],
	"ligier": ["LIG", Color(0.0, 0.2, 0.45), Color(0.95, 0.95, 0.95)],
	"corvette": ["CORV", Color(0.95, 0.8, 0.1), Color(0.05, 0.05, 0.05)],
	"ford": ["FORD", Color(0.0, 0.2, 0.55), Color(1, 1, 1)],
	"lexus": ["LEX", Color(0.1, 0.1, 0.1), Color(0.85, 0.85, 0.85)],
	"bentley": ["BEN", Color(0.0, 0.25, 0.15), Color(0.9, 0.9, 0.9)],
	"nissan": ["NIS", Color(0.75, 0.0, 0.1), Color(1, 1, 1)],
	"honda": ["HON", Color(0.85, 0.0, 0.1), Color(1, 1, 1)],
}


## The badge [text, background, text colour] for a car.
static func badge_for(def: CarDefinition) -> Array:
	var maker := str(def.raw.get("manufacturer", "")).to_lower()
	var name := def.display_name.to_lower().replace("-", " ")
	for key in BADGES:
		if maker.contains(key) or name.begins_with(key) or name.contains(" " + key + " "):
			return BADGES[key]
	var word := maker if maker != "" else (name.split(" ", false)[0] if name != "" else "?")
	return [word.left(3).to_upper(), def.colour.darkened(0.2), Color.WHITE]


func draw_badge(r: Rect2, def: CarDefinition) -> void:
	var b := badge_for(def)
	draw_rect(r, b[1])
	draw_rect(r, Color(1, 1, 1, 0.35), false, 1.0)
	var fs := 12 if str(b[0]).length() <= 3 else 10
	draw_string(font, Vector2(r.position.x, r.position.y + r.size.y * 0.5 + fs * 0.36), str(b[0]),
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, b[2])
