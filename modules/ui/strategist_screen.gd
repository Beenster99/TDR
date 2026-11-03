class_name StrategistScreen
extends Control
## The pit wall: a full-screen strategist view over the race. Timing tower
## with every car's sector and lap times, last-5-lap average, gaps,
## intervals, tyres and where a stop now would rejoin; weather radar and
## forecast (WeatherRadar: rain radar over a map with range rings, where
## the rain is heading, a 30-minute forecast loop and the coming changes);
## the selected car's details and pit window; and the feed of
## other teams' radio and strategy calls.
##
## Mouse and keyboard first: click a car in the timing to look at it, click
## ◀ ▶ on the feed (or roll the wheel over it) to filter it, "Plan the stop"
## opens the PitPlanner for our car; ↑ ↓ choose a car, ← → filter, Enter
## plans the stop, P or Esc closes. A controller works too (D-pad, B).
## Pit wall players (not driving) can watch the selected car's onboard
## camera (OnboardCamera) above the feed: Y / C switches front, rear, off.
## Drawn immediate-mode at 1600x900 and scaled by
## the window's stretch, so it stays sharp at 4K.
##
## The panels (timing, weather radar, selected car, feed and the onboard
## picture) move: drag a title bar (or the picture) to move one, the grip in
## its bottom right corner to zoom it (text and all), its right or bottom
## edge to make it wider or taller (PanelLayout). Where they were left
## is saved in GameData.prefs["pit_wall_layout"]["full"]. "Reset layout" in
## the header puts them back.

const FILTERS := [["All", []], ["Radio", ["radio"]], ["Strategy", ["strategy"]], ["Pit", ["pit"]],
	["Timing", ["timing"]], ["Tyres", ["tyres"]], ["Weather", ["weather"]], ["Incidents", ["incident"]], ["Race control", ["race_control"]]]
const KIND_COLOURS := {"radio": Color(0.45, 0.85, 1.0), "strategy": Color(1.0, 0.7, 0.3),
	"pit": Color(0.5, 1.0, 0.55), "timing": Color(0.85, 0.85, 0.85), "tyres": Color(1.0, 0.5, 0.4),
	"weather": Color(0.6, 0.75, 1.0), "incident": Color(1.0, 0.35, 0.35), "race_control": Color(1.0, 0.85, 0.2)}
const PURPLE := Color(0.78, 0.45, 1.0)
const GREEN := Color(0.4, 1.0, 0.5)
const YELLOW := Color(1.0, 0.88, 0.35)
const DIM := Color(1, 1, 1, 0.55)
const BG := Color(0.03, 0.05, 0.08, 0.98)
const PANEL := Color(1, 1, 1, 0.05)

signal open_planner

var session: RaceSession
var selected: int = -1          ## car index
var filter: int = 0
var font: Font
var _note := ""                 ## a short line after a pit call (driver change)
var _note_time := 0.0
var _track_pts := PackedVector2Array()
## The pit stop planner (PitPlanner): input goes there while it's open.
var planner: Control
var _hits: Array = []                ## [Rect2, action, arg] from the last draw
var _hover := Vector2(-1, -1)
## Onboard camera for the selected car (set by the race scene; null = none).
var onboard: OnboardCamera
var cam_mode := 0               ## 0 off, 1 front, 2 rear
## Where the player has moved the panels.
var layout := PanelLayout.new("full")
var _cursor := Input.CURSOR_ARROW
## The weather radar panel (zoom, forecast loop).
var radar := WeatherRadar.new()


func setup(p_session: RaceSession) -> void:
	session = p_session
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	selected = _our_car() if _our_car() >= 0 else 0
	var t := session.sim.track
	for i in range(0, t.point_count(), 3):
		_track_pts.append(t.points[i])
	_track_pts.append(t.points[0])
	layout.spec("timing", Vector2(700, 300), Vector2(1400, 4000))
	layout.spec("weather", Vector2(300, 200), Vector2(1600, 900))
	layout.spec("car", Vector2(340, 236), Vector2(900, 420))
	layout.spec("feed", Vector2(280, 120))
	layout.spec("pip", Vector2(240, 135), Vector2(1120, 630), 16.0 / 9.0, true)
	var gd := get_node_or_null("/root/GameData")
	if gd:
		layout.load_from(gd.prefs)


func open() -> void:
	visible = true
	if _our_car() >= 0:
		selected = _our_car()


## The car this player drives or is in the pit crew / strategist of.
func _our_car() -> int:
	return session.local_car if session.local_car >= 0 else session.team_car


func close() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func _input(event: InputEvent) -> void:
	if not visible or (planner and planner.visible):
		return
	if event is InputEventMouseMotion:
		_hover = event.position
		layout.motion(event.position, event.button_mask & MOUSE_BUTTON_MASK_LEFT != 0)
		_set_cursor(layout.cursor_at(event.position))
		return
	if event is InputEventMouseButton:
		get_viewport().set_input_as_handled()
		if event.button_index == MOUSE_BUTTON_LEFT:
			# A title bar moves its panel; a press there that doesn't move is a click.
			if event.pressed and layout.press(event.position):
				return
			if not event.pressed:
				if layout.release() == "click":
					_click(layout.press_position(), MOUSE_BUTTON_LEFT)
				return
		if event.pressed:
			_click(event.position, event.button_index)
		return
	if not event.is_pressed() or event.is_echo() and not (event.is_action("ui_up") or event.is_action("ui_down")):
		return
	if event is InputEventKey and event.keycode in [KEY_ENTER, KEY_KP_ENTER] and _can_plan():
		open_planner.emit()
		get_viewport().set_input_as_handled()
		return
	var order := session.sim.running_order
	var p := order.find(selected)
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.is_action_pressed("strategy_screen")):
		close()
	elif event.is_action_pressed("ui_up", true):
		selected = order[maxi(p - 1, 0)]
	elif event.is_action_pressed("ui_down", true):
		selected = order[mini(p + 1, order.size() - 1)]
	elif event.is_action_pressed("ui_left"):
		filter = posmod(filter - 1, FILTERS.size())
	elif event.is_action_pressed("ui_right"):
		filter = posmod(filter + 1, FILTERS.size())
	elif event is InputEventJoypadButton and session.local_car >= 0 and session.sim.pits.enabled \
			and event.button_index in [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
		# The driver's next stop: which tyres to change.
		var me := session.local_car
		var ch := PitRules.WHEEL_CHOICES
		var now := ch.find(str(session.sim.entries[me].pit["plan"].get("wheels", PitRules.WHEELS_ALL)))
		var step := 1 if event.button_index == JOY_BUTTON_RIGHT_SHOULDER else -1
		session.request_pit(me, {"wheels": ch[posmod(now + step, ch.size())]})
	elif event.is_action_pressed("camera_toggle") and _cam_allowed():
		cam_mode = (cam_mode + 1) % 3
	elif event is InputEventJoypadButton and event.button_index == JOY_BUTTON_Y and session.local_car >= 0:
		_note = RaceHud.toggle_driver_change(session, session.local_car)
		_note_time = 3.0
	else:
		return
	get_viewport().set_input_as_handled()


## True when this player can plan our car's next stop here.
func _can_plan() -> bool:
	return _our_car() >= 0 and session.sim.pits.enabled


func _click(pos: Vector2, button: int) -> void:
	var dir := 0
	match button:
		MOUSE_BUTTON_LEFT: dir = 1
		MOUSE_BUTTON_RIGHT: dir = -1
		MOUSE_BUTTON_WHEEL_UP: dir = -2
		MOUSE_BUTTON_WHEEL_DOWN: dir = 2
	for k in range(_hits.size() - 1, -1, -1):
		var h: Array = _hits[k]
		if not (h[0] as Rect2).has_point(pos):
			continue
		match str(h[1]):
			"car":
				if absi(dir) == 1:
					selected = int(h[2])
			"filter":
				filter = posmod(filter + (int(h[2]) if absi(dir) == 1 else signi(dir)), FILTERS.size())
			"plan":
				if dir == 1:
					open_planner.emit()
			"close":
				if dir == 1:
					close()
			"reset_layout":
				if dir == 1:
					layout.reset_all()
					layout.save()
			"radar":
				# The time bar is in the panel's own (unzoomed) units.
				var wr := layout.rect_of("weather", Rect2(), layout.bounds) if layout.is_moved("weather") else Rect2()
				var x := wr.position.x + (pos.x - wr.position.x) / layout.scale_of("weather")
				radar.click(h[2], dir, x)
		if absi(dir) == 1:
			Sound.ui("ui_select", -6.0)
		return


func _button(r: Rect2, label: String, action: String, fs := 15, col := Color.WHITE) -> void:
	var hover := r.has_point(_hover)
	draw_rect(r, Color(1, 0.88, 0.35, 0.3 if hover else 0.18))
	draw_rect(r, Color(1, 0.88, 0.35, 0.9 if hover else 0.6), false, 1.5)
	_text(Vector2(r.position.x, r.position.y + r.size.y * 0.5 + fs * 0.36), label, fs, col, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	_hits.append([r, action, null])


func _set_cursor(c: Input.CursorShape) -> void:
	if c != _cursor:
		_cursor = c
		Input.set_default_cursor_shape(c)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		layout.release()
		_set_cursor(Input.CURSOR_ARROW)


func _process(delta: float) -> void:
	if not visible:
		return
	size = get_viewport_rect().size
	radar.process(delta)
	_note_time = maxf(_note_time - delta, 0.0)
	if _pip_on():
		OnboardPip.feed(self, onboard, _pip_rect(), selected, cam_mode == 2)
	queue_redraw()


## The onboard camera is for the pit wall (players not driving).
func _cam_allowed() -> bool:
	return onboard != null and session.local_car < 0


func _pip_on() -> bool:
	return _cam_allowed() and cam_mode > 0 and selected >= 0 and selected < session.sim.car_count()


var _pip_at := Rect2()   ## where the right column leaves room for the picture


func _pip_rect() -> Rect2:
	return _pip_at


# --- Drawing helpers ------------------------------------------------------------


## Draws one panel through f(content rect), scaled by the player's zoom for
## it: hover and clicks are mapped to match.
func _in_panel(id: String, r: Rect2, f: Callable) -> void:
	var sc := layout.scale_of(id)
	var lr := layout.content_rect(id, r)
	if absf(sc - 1.0) < 0.001:
		f.call(lr)
		return
	var n0 := _hits.size()
	var hov := _hover
	_hover = r.position + (hov - r.position) / sc
	draw_set_transform(r.position * (1.0 - sc), 0.0, Vector2(sc, sc))
	f.call(lr)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_hover = hov
	for k in range(n0, _hits.size()):
		var hr: Rect2 = _hits[k][0]
		_hits[k][0] = Rect2(r.position + (hr.position - r.position) * sc, hr.size * sc)

func _text(pos: Vector2, s: String, fs := 15, col := Color.WHITE, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	if width > 0.0 and align == HORIZONTAL_ALIGNMENT_LEFT:
		s = _fit(s, width, fs)
	draw_string(font, pos, s, align, width, fs, col)


func _fit(s: String, width: float, fs: int) -> String:
	if font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= width:
		return s
	while s.length() > 1 and font.get_string_size(s + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width:
		s = s.left(s.length() - 1)
	return s + "…"


## Splits text into lines that fit width.
func _wrap(s: String, width: float, fs: int) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for w in s.split(" "):
		var cand := w if line == "" else line + " " + w
		if font.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width and line != "":
			out.append(line)
			line = w
		else:
			line = cand
	if line != "":
		out.append(line)
	return out


func _panel(r: Rect2, title := "") -> void:
	draw_rect(r, BG)      # solid, so a panel moved over another hides it
	draw_rect(r, PANEL)
	draw_rect(r, Color(1, 1, 1, 0.08), false, 1.0)
	if title != "":
		_text(r.position + Vector2(10, 20), title, 13, DIM)


static func fmt_lap(t: float) -> String:
	if t <= 0.0:
		return "-"
	return "%d:%06.3f" % [int(t) / 60, fmod(t, 60.0)]


static func fmt_gap(t: float) -> String:
	return "%.1f" % t if t >= 60.0 else "%.3f" % t


func _temp_colour(t: float, tc: TyreCompound) -> Color:
	var x := (t - tc.optimal_temp_c) / tc.temp_window_c
	if x < 0.0:
		return Color(0.3, 0.55, 1.0).lerp(Color(0.3, 0.9, 0.4), clampf(1.0 + x, 0.0, 1.0))
	return Color(0.3, 0.9, 0.4).lerp(Color(1.0, 0.3, 0.2), clampf(x, 0.0, 1.0))


# --- Screen ----------------------------------------------------------------------

func _draw() -> void:
	_hits.clear()
	if session == null:
		return
	var vp := size
	draw_rect(Rect2(Vector2.ZERO, vp), BG)
	var sim := session.sim
	var tel := session.telemetry
	var table_w := clampf(vp.x * 0.66, 900.0, 1080.0)
	_draw_header(Rect2(16, 10, vp.x - 32, 40), sim, tel)
	layout.begin(Rect2(8, 54, vp.x - 16, vp.y - 54 - 26))
	# As designed: timing on the left; radar, selected car, then the picture
	# and the feed down the right. A moved panel goes where it was left, and
	# panels drawn later sit on top.
	var d := {"timing": Rect2(16, 58, table_w, vp.y - 58 - 34)}
	var rx := 16 + table_w + 14
	var rw := vp.x - rx - 16
	var radar_h := minf(rw * 0.62, 280.0)
	d["weather"] = Rect2(rx, 58, rw, radar_h)
	var car_h := 236.0
	d["car"] = Rect2(rx, 58 + radar_h + 10, rw, car_h)
	var fy := 58 + radar_h + 10 + car_h + 10
	# The picture takes the feed's place (the feed is back when it's off).
	var ph := minf(rw * 9.0 / 16.0, vp.y - fy - 40)
	_pip_at = layout.rect_of("pip", Rect2(rx + (rw - ph * 16.0 / 9.0) * 0.5, fy + 3, ph * 16.0 / 9.0, ph))
	if _pip_on() and not layout.is_moved("pip"):
		fy += _pip_at.size.y + 12
	d["feed"] = Rect2(rx, fy, rw, vp.y - fy - 34)
	var draws := {"timing": func(r: Rect2): _draw_timing(r, sim, tel), "weather": func(r: Rect2): _draw_weather(r, tel),
		"car": func(r: Rect2): _draw_car(r, sim, tel), "feed": func(r: Rect2): _draw_feed(r, tel)}
	for id in layout.draw_order(["timing", "weather", "car", "feed"]):
		_in_panel(id, layout.place(id, d[id]), draws[id])
	if _pip_on():
		layout.place("pip", _pip_at)
		_hits.append([_pip_at, "pip", null])
		OnboardPip.draw(self, font, onboard, _pip_at, session, selected, cam_mode == 2)
	layout.draw_handles(self, _hover, font)
	if layout.customised():
		var rb := Rect2(vp.x - 196, 14, 132, 32)
		var hot := rb.has_point(_hover)
		draw_rect(rb, Color(1, 1, 1, 0.14 if hot else 0.06))
		draw_rect(rb, Color(1, 1, 1, 0.5 if hot else 0.25), false, 1.0)
		_text(Vector2(rb.position.x, rb.position.y + 21), "Reset layout", 14, Color.WHITE if hot else DIM, HORIZONTAL_ALIGNMENT_CENTER, rb.size.x)
		_hits.append([rb, "reset_layout", null])
	var keys := InputPrompt.fill("Click a car to look at it    ↑↓ choose car    ←→ or wheel filter feed    Drag a title bar to move, the corner to zoom    {strategy_screen} / {ui_cancel} close")
	if InputPrompt.pad:
		keys = InputPrompt.fill("D-pad ↑↓ choose car    ←→ filter feed    {ui_cancel} close")
		if session.local_car >= 0 and session.sim.pits.enabled:
			keys += "    %s / %s tyres to change" % [InputPrompt.button(JOY_BUTTON_LEFT_SHOULDER), InputPrompt.button(JOY_BUTTON_RIGHT_SHOULDER)]
	if _can_plan() and not InputPrompt.pad:
		keys += "    Enter plan the stop"
	if _cam_allowed():
		keys += "    %s onboard camera: %s" % [InputPrompt.key("camera_toggle"), ["off", "front", "rear"][cam_mode]]
	_text(Vector2(16, vp.y - 12), keys + "    The race keeps running", 13, DIM)
	_button(Rect2(vp.x - 52, 14, 36, 32), "✕", "close", 18)
	if _note_time > 0.0:
		_text(Vector2(vp.x - 16, vp.y - 12), _note, 14, YELLOW, HORIZONTAL_ALIGNMENT_RIGHT, vp.x * 0.4)


func _draw_header(r: Rect2, sim: RaceSim, tel: RaceTelemetry) -> void:
	var lead := sim.entries[sim.running_order[0]] if not sim.running_order.is_empty() else null
	var lap := mini(lead.laps_done + 1, sim.settings.laps) if lead else 0
	_text(r.position + Vector2(0, 26), "PIT WALL", 26, YELLOW)
	_text(r.position + Vector2(150, 26), "%s   ·   Lap %d / %d   ·   %s" % [sim.track.display_name, lap,
		sim.settings.laps, fmt_lap(sim.race_time).trim_suffix("0")], 18)
	var f := tel.forecast
	_text(r.position + Vector2(r.size.x - 580 - (150.0 if layout.customised() else 0.0), 26), "%02d:%02d   %s   Air %d°   Track %d°   Wet %d%%" % [
		int(f.time_of_day_h), int(fmod(f.time_of_day_h, 1.0) * 60.0), WeatherForecast.weather_label(f.weather),
		int(f.ambient_c), int(f.track_c), int(f.wetness * 100.0)], 16, Color(0.75, 0.85, 1.0),
		HORIZONTAL_ALIGNMENT_RIGHT, 520)


func _draw_timing(r: Rect2, sim: RaceSim, tel: RaceTelemetry) -> void:
	_panel(r)
	# Column x positions (fractions of a 1060 px table, scaled to fit).
	var k := r.size.x / 1060.0
	var cols := {"pos": 8, "drv": 52, "car": 205, "last": 318, "best": 396, "avg": 474, "s1": 552,
		"gap": 744, "int": 818, "tyre": 884, "pit": 978}
	for key in cols:
		cols[key] = r.position.x + cols[key] * k
	var n := sim.running_order.size()
	var rh := clampf((r.size.y - 34) / maxf(n, 1), 18.0, 28.0)
	var fs := 15 if rh >= 22.0 else 13
	var hy := r.position.y + 22
	for h in [["pos", "P"], ["drv", "DRIVER"], ["car", "CAR"], ["last", "LAST"], ["best", "BEST"],
			["avg", "AVG 5"], ["gap", "GAP"], ["int", "INT"], ["tyre", "TYRES"], ["pit", "STOP NOW"]]:
		_text(Vector2(cols[h[0]], hy), h[1], 12, DIM)
	var sw := 62.0 * k
	for s in sim.track.sectors.size():
		_text(Vector2(cols["s1"] + s * sw, hy), "S%d" % (s + 1), 12, DIM)
	for p in n:
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var c := tel.cars[i]
		var y := r.position.y + 32 + p * rh
		if y + rh > r.end.y + 2:
			break      # a panel made too short for the whole field
		var row := Rect2(r.position.x + 2, y, r.size.x - 4, rh - 2)
		if i == selected:
			draw_rect(row, Color(1, 0.88, 0.35, 0.16))
			draw_rect(row, Color(1, 0.88, 0.35, 0.6), false, 1.5)
		elif row.has_point(_hover):
			draw_rect(row, Color(1, 1, 1, 0.07))
		elif p % 2 == 1:
			draw_rect(row, Color(1, 1, 1, 0.025))
		_hits.append([row, "car", i])
		var ty := y + rh * 0.5 + fs * 0.35
		var name_col := YELLOW if i == _our_car() else (Color(0.75, 0.85, 1) if not e.is_ai else Color.WHITE)
		_text(Vector2(cols["pos"], ty), str(e.position), fs, Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, 26 * k)
		draw_rect(Rect2(cols["drv"] - 12 * k, y + 4, 5, rh - 10), sim.defs[i].colour)
		_text(Vector2(cols["drv"], ty), e.driver_name, fs, name_col, HORIZONTAL_ALIGNMENT_LEFT, 148 * k)
		_text(Vector2(cols["car"], ty), sim.defs[i].display_name, fs - 2, DIM, HORIZONTAL_ALIGNMENT_LEFT, 108 * k)
		var last := c.last_lap()
		var best := c.best_lap()
		_text(Vector2(cols["last"], ty), fmt_lap(last), fs, PURPLE if last > 0.0 and last == tel.fastest_lap else (GREEN if last > 0.0 and last == best else Color.WHITE))
		_text(Vector2(cols["best"], ty), fmt_lap(best), fs, PURPLE if best > 0.0 and best == tel.fastest_lap else Color(1, 1, 1, 0.8))
		_text(Vector2(cols["avg"], ty), fmt_lap(c.last5_avg), fs, Color(0.8, 0.9, 1.0))
		var secs := c.last_sectors()
		for s in secs.size():
			var v: float = secs[s]
			var col := Color.WHITE
			if s < tel.best_sectors.size() and v <= tel.best_sectors[s] + 1e-6:
				col = PURPLE
			elif s < c.best_sectors.size() and v <= c.best_sectors[s] + 1e-6:
				col = GREEN
			_text(Vector2(cols["s1"] + s * sw, ty), "%.2f" % v, fs - 1, col)
		var gap := ""
		var inter := ""
		if e.finished:
			gap = "FIN"
		elif e.dnf:
			gap = "DNF"
		elif p == 0:
			gap = "Leader"
		else:
			gap = ("+%d L" % c.laps_down) if c.laps_down >= 1 else "+" + fmt_gap(c.gap_leader)
			inter = "+" + fmt_gap(c.interval)
		_text(Vector2(cols["gap"], ty), gap, fs, Color.WHITE)
		_text(Vector2(cols["int"], ty), inter, fs, YELLOW if p > 0 and c.interval < 1.0 and inter != "" else Color(1, 1, 1, 0.85))
		var car := sim.cars[i]
		var tc := sim.compounds[i]
		for t in 4:
			var tr := Rect2(cols["tyre"] + (t % 2) * 9 * k + (t / 2) * 0.0, y + 3 + (t / 2) * (rh - 6) * 0.5, 7 * k, (rh - 8) * 0.5)
			draw_rect(tr, _temp_colour(car.tyre_temp[t], tc))
		_text(Vector2(cols["tyre"] + 22 * k, ty), "%d°" % int((car.tyre_temp[0] + car.tyre_temp[1] + car.tyre_temp[2] + car.tyre_temp[3]) / 4.0),
			fs - 2, {"hot": Color(1, 0.5, 0.4), "cold": Color(0.55, 0.7, 1.0)}.get(c.tyre_state, Color(1, 1, 1, 0.8)))
		_text(Vector2(cols["tyre"] + 56 * k, ty), sim.compounds[i].display_name.left(1), fs - 3, DIM)
		if not c.pit.is_empty():
			var pit_col := GREEN if c.pit["ideal"] else (Color(0.8, 1.0, 0.6) if c.pit["clear_air"] else Color(1, 1, 1, 0.55))
			var mark := "  clear" if c.pit["clear_air"] else ""
			_text(Vector2(cols["pit"], ty), "P%d%s" % [c.pit["rejoin_pos"], mark], fs - 1, pit_col)


func _draw_weather(r: Rect2, tel: RaceTelemetry) -> void:
	_panel(r, "WEATHER RADAR")
	radar.draw(self, font, r, tel.forecast, _track_pts, session.sim.track.short_name, _hover, _hits)


func _draw_car(r: Rect2, sim: RaceSim, tel: RaceTelemetry) -> void:
	if selected < 0 or selected >= sim.car_count():
		return
	_panel(r, "SELECTED CAR")
	var i := selected
	if _can_plan():
		_button(Rect2(r.end.x - 196, r.position.y + 6, 186, 28), "PLAN THE STOP  ⏎", "plan", 14, YELLOW)
	var e := sim.entries[i]
	var c := tel.cars[i]
	var x := r.position.x + 10
	var w := r.size.x - 20
	draw_rect(Rect2(x, r.position.y + 30, 6, 22), sim.defs[i].colour)
	_text(Vector2(x + 14, r.position.y + 48), "P%d  %s" % [e.position, e.at_wheel()], 19, YELLOW if i == _our_car() else Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, w * 0.6)
	_text(Vector2(x + w * 0.6, r.position.y + 48), sim.defs[i].display_name, 14, DIM, HORIZONTAL_ALIGNMENT_LEFT, w * 0.4)
	var trend := c.trend()
	var trend_s := "steady" if absf(trend) < 0.05 else ("%+.2f s/lap" % trend)
	_text(Vector2(x, r.position.y + 74), "Avg 5 %s   Best %s   %s" % [fmt_lap(c.last5_avg), fmt_lap(c.best_lap()), trend_s], 14, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, w)
	var temps := sim.cars[i].tyre_temp
	_text(Vector2(x, r.position.y + 96), "Tyres %s  %d° %d° / %d° %d°  grip %d%%" % [c.tyre_state.to_upper(),
		int(temps[0]), int(temps[1]), int(temps[2]), int(temps[3]), int(c.tyre_grip * 100.0)], 14,
		{"hot": Color(1, 0.5, 0.4), "cold": Color(0.55, 0.7, 1.0)}.get(c.tyre_state, GREEN), HORIZONTAL_ALIGNMENT_LEFT, w)
	var strat: Dictionary = tel.strategies.get(i, {})
	if i == session.local_car and sim.pits.enabled:
		# Our own car: what the next stop will do.
		var plan: Dictionary = e.pit["plan"]
		var work := sim.pits.service_for(i, plan)
		var line := "Next stop: tyres " + RaceHud.stop_tyres_text(sim, i, plan, work)
		var pend := session.pending_swap(i)
		if not pend.is_empty():
			line += ", driver change"
		_text(Vector2(x, r.position.y + 118), line, 14, Color(1.0, 0.75, 0.4), HORIZONTAL_ALIGNMENT_LEFT, w)
	else:
		_text(Vector2(x, r.position.y + 118), "Strategy: " + (strat.get("text", "no calls heard") as String), 14, Color(1.0, 0.75, 0.4), HORIZONTAL_ALIGNMENT_LEFT, w)
	# Pit window.
	var pa := c.pit
	if pa.is_empty():
		_text(Vector2(x, r.position.y + 144), "Pit window: waiting for timing", 14, DIM)
	else:
		var status := "IDEAL: no places lost, clear air" if pa["ideal"] else ("clear air" if pa["clear_air"] else "into traffic")
		_text(Vector2(x, r.position.y + 144), "Stop now: lose %.1f s, rejoin P%d (%s)" % [pa["loss"], pa["rejoin_pos"], status], 14,
			GREEN if pa["ideal"] else (Color(0.8, 1.0, 0.6) if pa["clear_air"] else Color(1, 0.75, 0.5)), HORIZONTAL_ALIGNMENT_LEFT, w)
		var gb := "%.1f s" % c.gap_behind if c.gap_behind >= 0.0 else "nobody"
		_text(Vector2(x, r.position.y + 164), "Gap behind %s, need %.1f s for a free stop" % [gb, pa["need"]], 13, DIM, HORIZONTAL_ALIGNMENT_LEFT, w)
	# Lap history: last laps against the 5-lap average.
	var hx := x
	var hy := r.position.y + 176
	var hw := w
	var hh := r.end.y - hy - 8
	var n := mini(c.laps.size(), 12)
	if n == 0:
		return
	var ref := c.last5_avg if c.last5_avg > 0.0 else c.best_lap()
	var bw := hw / 12.0
	draw_line(Vector2(hx, hy + hh * 0.5), Vector2(hx + hw, hy + hh * 0.5), Color(1, 1, 1, 0.25), 1.0)
	for k in n:
		var l: Dictionary = c.laps[c.laps.size() - n + k]
		var d: float = clampf((l["time"] - ref) / 2.0, -1.0, 1.0)  # ±2 s full scale
		var bh := d * hh * 0.5
		var col := GREEN if d < 0.0 else Color(1, 0.55, 0.4)
		if l["time"] == tel.fastest_lap:
			col = PURPLE
		draw_rect(Rect2(hx + k * bw + 2, hy + hh * 0.5, bw - 4, bh), col)


func _draw_feed(r: Rect2, tel: RaceTelemetry) -> void:
	if r.size.y < 60:
		return
	_panel(r, "FEED  ◀ %s ▶" % FILTERS[filter][0])
	var head_w := font.get_string_size("FEED  ◀ %s ▶" % FILTERS[filter][0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	_hits.append([Rect2(r.position.x, r.position.y, r.size.x, r.size.y), "filter", 0])
	_hits.append([Rect2(r.position.x + 40, r.position.y + 4, 26, 22), "filter", -1])
	_hits.append([Rect2(r.position.x + head_w - 6, r.position.y + 4, 26, 22), "filter", 1])
	var fs := 13
	var y := r.position.y + 42
	var w := r.size.x - 20
	for it in tel.feed.latest(30, FILTERS[filter][1]):
		var kind: String = it.get("kind", "")
		var who := ""
		if kind in ["radio", "strategy"]:
			who = tel.driver_name(int(it.get("car", -1))) + ": "
		var head := "L%d %s " % [int(it.get("lap", 0)), "CONTROL" if kind == "race_control" else kind.to_upper()]
		var lines := _wrap(who + str(it.get("text", "")), w - 90, fs)
		if y + lines.size() * 17 > r.end.y - 4:
			break
		_text(Vector2(r.position.x + 10, y), head, 11, KIND_COLOURS.get(kind, DIM))
		for ln in lines:
			_text(Vector2(r.position.x + 100, y), ln, fs, Color(1, 1, 1, 0.9))
			y += 17
		y += 4
