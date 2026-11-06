class_name StrategistScreen
extends Control
## The Strategist screen (the full pit wall): a full-screen view over the race. Timing tower
## with every car's sector and lap times, last-5-lap average, gaps,
## intervals, tyres and where a stop now would rejoin; weather radar and
## forecast (WeatherRadar: rain radar over a map with range rings, where
## the rain is heading, a 30-minute forecast loop and the coming changes);
## the selected car's details and pit window; and the feed of
## other teams' radio and strategy calls.
##
## Everything fits on one screen, at a glance: the drivers table (timing /
## pace) top left with the onboard camera of the selected car and the feed
## under it; down the right the weather radar, OUR CAR (the setup the car
## runs now and each tyre's temperature, hot pressure and wear) and the
## selected car's details and pit window.
##
## Mouse and keyboard first: click a car in the timing to look at it (and
## put the camera on it), click ◀ ▶ on the feed (or roll the wheel over it)
## to filter it, "PIT STOP SETTINGS" opens the PitPlanner dialog in the
## middle for our car (change everything the crew can do at the stop, Send to
## driver, or Cancel at any time); ↑ ↓ choose a car, ← → filter, Enter opens
## the pit stop settings, P or Esc closes. A controller works too (D-pad, B).
## Y / C switches the onboard camera front, rear, off.
## Drawn immediate-mode in a canvas UI_SCALE times the 1600x900 one (smaller
## text, so it all fits) and scaled by the window's stretch, so it stays
## sharp at 4K.
##
## The timing panel has two views, TIMING and PACE (click the tab or press
## Tab). PACE is one table of every car in our class with its last lap, its
## last 3 laps and its last 5 laps (each with its rank and the gap to our car),
## best lap and race gap; click a heading to sort on it (again to turn it round). Our car is
## yellow everywhere, the car we're really racing (RaceTelemetry.rival_of:
## the nearer of the cars just ahead and behind on our lap, or the one the
## player marked in SELECTED CAR) is orange, and backmarkers (a lap or more
## down on us) carry a blue lap-down chip, with the next ones up the road
## listed under the pace table.
##
## The panels (timing, weather radar, our car, selected car, feed and the
## onboard picture) move: drag a title bar (or the picture) to move one, the grip in
## its bottom right corner to zoom it (text and all), its right or bottom
## edge to make it wider or taller (PanelLayout). Where they were left
## is saved in GameData.prefs["pit_wall_layout"]["wall"]. "Reset layout" in
## the header puts them back.

const FILTERS := [["All", []], ["Radio", ["radio"]], ["Strategy", ["strategy"]], ["Pit", ["pit"]],
	["Timing", ["timing"]], ["Tyres", ["tyres"]], ["Weather", ["weather"]], ["Incidents", ["incident"]], ["Race control", ["race_control"]]]
const KIND_COLOURS := {"radio": Color(0.45, 0.85, 1.0), "strategy": Color(1.0, 0.7, 0.3),
	"pit": Color(0.5, 1.0, 0.55), "timing": Color(0.85, 0.85, 0.85), "tyres": Color(1.0, 0.5, 0.4),
	"weather": Color(0.6, 0.75, 1.0), "incident": Color(1.0, 0.35, 0.35), "race_control": Color(1.0, 0.85, 0.2)}
const PURPLE := Color(0.78, 0.45, 1.0)
const GREEN := Color(0.4, 1.0, 0.5)
const RED := Color(1.0, 0.4, 0.35)
const YELLOW := Color(1.0, 0.88, 0.35)
const DIM := Color(1, 1, 1, 0.55)
const WHEELS := ["FL", "FR", "RL", "RR"]
const BG := Color(0.03, 0.05, 0.08, 0.98)
const PANEL := Color(1, 1, 1, 0.05)
const ORANGE := Color(1.0, 0.6, 0.25)       ## the car we're racing
const BACKMARKER := Color(0.35, 0.6, 1.0)   ## a lap or more down on us
## The screen draws at this size of the usual 1600x900 canvas, so its text is
## smaller and everything fits on one screen.
const UI_SCALE := 0.8
## Setup lines in OUR CAR, two columns: [key, short label].
const SETUP_COLS := [
	[["wing_front", "Front splitter"], ["wing_rear", "Rear wing"], ["ride_front", "Ride height F"], ["ride_rear", "Ride height R"],
		["spring_front", "Springs F"], ["spring_rear", "Springs R"], ["arb_front", "Anti-roll bar F"], ["arb_rear", "Anti-roll bar R"]],
	[["camber_front", "Camber F"], ["camber_rear", "Camber R"], ["toe_front", "Toe F"], ["toe_rear", "Toe R"],
		["brake_bias", "Brake bias"], ["diff_power", "Diff on power"], ["diff_coast", "Diff off power"], ["final_drive", "Gearing"]]]
const VIEW_TIMING := 0
const VIEW_PACE := 1
## The PACE table's columns: [key, heading, x (of a 1040 px table), sortable].
const PACE_COLUMNS := [["rank", "#", 4, false], ["pos", "POS", 34, true], ["driver", "DRIVER", 84, true],
	["last", "LAST LAP", 290, true], ["avg3", "LAST 3", 460, true], ["avg5", "LAST 5", 630, true],
	["best", "BEST", 800, true], ["gap", "GAP", 880, true], ["wear", "TYRES LEFT", 960, true]]

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
var cam_mode := 1               ## 0 off, 1 front, 2 rear
## Where the player has moved the panels.
var layout := PanelLayout.new("wall")
var _cursor := Input.CURSOR_ARROW
## The weather radar panel (zoom, forecast loop).
var radar := WeatherRadar.new()
## The timing panel's view: VIEW_TIMING (the tower) or VIEW_PACE.
var view := VIEW_TIMING
## The rival the player marked (-1: worked out, RaceTelemetry.rival_of).
var rival_pick := -1
## The PACE table's sort: a column key (PACE_COLUMNS) and its direction.
var pace_sort := "last"
var pace_desc := false


func setup(p_session: RaceSession) -> void:
	session = p_session
	font = ThemeDB.fallback_font
	scale = Vector2.ONE * UI_SCALE
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	selected = _our_car() if _our_car() >= 0 else 0
	var t := session.sim.track
	for i in range(0, t.point_count(), 3):
		_track_pts.append(t.points[i])
	_track_pts.append(t.points[0])
	layout.spec("timing", Vector2(700, 300), Vector2(1400, 4000))
	layout.spec("weather", Vector2(300, 200), Vector2(1600, 900))
	layout.spec("ours", Vector2(560, 300), Vector2(1400, 600))
	layout.spec("car", Vector2(340, 236), Vector2(1400, 600))
	layout.spec("feed", Vector2(280, 120))
	layout.spec("pip", Vector2(240, 135), Vector2(1400, 788), 16.0 / 9.0, true)
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


## A point on the window (the canvas the events come in) in this screen's own
## smaller canvas.
func to_local_pos(p: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * p


func _input(event: InputEvent) -> void:
	if not visible or (planner and planner.visible):
		return
	if event is InputEventMouse:
		event = event.duplicate()
		event.position = to_local_pos(event.position)
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
	if event is InputEventKey and event.keycode == KEY_TAB:
		view = VIEW_PACE if view == VIEW_TIMING else VIEW_TIMING
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
			"cam":
				if dir == 1 and _cam_allowed():
					cam_mode = (cam_mode + 1) % 3
			"view":
				if absi(dir) == 1:
					view = int(h[2])
			"sort":
				if absi(dir) == 1:
					sort_pace(str(h[2]))
			"rival":
				if dir == 1:
					rival_pick = -1 if rival_pick == selected else selected
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
	position = Vector2.ZERO
	size = get_viewport_rect().size / UI_SCALE
	if planner and not planner.plan_sent.is_connected(_on_plan_sent):
		planner.plan_sent.connect(_on_plan_sent)
	radar.process(delta)
	_note_time = maxf(_note_time - delta, 0.0)
	if _pip_on():
		OnboardPip.feed(self, onboard, _pip_rect(), selected, cam_mode == 2)
	queue_redraw()


## A line on the screen once the pit stop settings went to the driver.
func _on_plan_sent(_msg: Dictionary) -> void:
	if not visible:
		return
	_note = "Pit stop settings sent to the driver" if planner.car != session.local_car else "Your next stop is set"
	_note_time = 4.0


## The onboard camera on any car (not on a machine with no 3D view).
func _cam_allowed() -> bool:
	return onboard != null


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


## A tyre's colour by its wear (ResultsTable.wear_colour).
static func wear_colour(wear: float) -> Color:
	return ResultsTable.wear_colour(wear)


## The worst-worn tyre: its index (0 FL, 1 FR, 2 RL, 3 RR).
static func worst_tyre(wear) -> int:
	var worst := 0
	for t in range(1, 4):
		if float(wear[t]) > float(wear[worst]):
			worst = t
	return worst


## Each tyre's rubber left as four small bars laid out like the car (FL FR
## over RL RR), filled from the bottom and coloured by wear, then how much
## the most worn one has left. Light grey while a tyre is fine (so it isn't
## mistaken for the temperature squares beside it), yellow and red as it wears.
func _wear_cell(at: Vector2, rh: float, k: float, wear, fs: int) -> void:
	var bh := (rh - 8) * 0.5
	for t in 4:
		var w := clampf(float(wear[t]), 0.0, 1.0)
		var tr := Rect2(at.x + (t % 2) * 9 * k, at.y + 3 + (t / 2) * (rh - 6) * 0.5, 7 * k, bh)
		draw_rect(tr, Color(1, 1, 1, 0.12))
		var fh := tr.size.y * (1.0 - w)
		draw_rect(Rect2(tr.position.x, tr.end.y - fh, tr.size.x, fh), wear_colour(w) if w > 0.45 else Color(0.86, 0.89, 0.94))
	var worst := clampf(float(wear[worst_tyre(wear)]), 0.0, 1.0)
	_text(Vector2(at.x + 22 * k, at.y + rh * 0.5 + fs * 0.35), "%d%%" % roundi((1.0 - worst) * 100.0), fs - 2,
		wear_colour(worst) if worst > 0.45 else Color(1, 1, 1, 0.8))


# --- Screen ----------------------------------------------------------------------

func _draw() -> void:
	_hits.clear()
	if session == null:
		return
	var vp := size
	draw_rect(Rect2(Vector2.ZERO, vp), BG)
	var sim := session.sim
	var tel := session.telemetry
	_draw_header(Rect2(16, 10, vp.x - 32, 40), sim, tel)
	var top := 54.0
	var bottom := vp.y - 28.0
	var ch := bottom - top
	layout.begin(Rect2(8, top - 4, vp.x - 16, ch + 8))
	# As designed, all on one screen: the drivers table top left with the
	# onboard camera and the feed under it; the weather radar, our car and the
	# selected car down the right. A moved panel goes where it was left, and
	# panels drawn later sit on top.
	var lw := clampf(vp.x * 0.5, 900.0, 1240.0)
	var tim_h := roundf(ch * 0.67)
	var d := {"timing": Rect2(12, top, lw, tim_h)}
	var by := top + tim_h + 10.0
	var bh := bottom - by
	var cam_w := minf(bh * 16.0 / 9.0, lw * 0.62)
	_pip_at = layout.rect_of("pip", Rect2(12, by, cam_w, cam_w * 9.0 / 16.0))
	d["feed"] = Rect2(12 + cam_w + 10, by, lw - cam_w - 10, bh)
	var rx := 12.0 + lw + 12.0
	var rw := vp.x - rx - 12.0
	var radar_h := clampf(ch * 0.29, 220.0, 340.0)
	d["weather"] = Rect2(rx, top, rw, radar_h)
	var ours_h := clampf(ch * 0.355, 300.0, 400.0)
	d["ours"] = Rect2(rx, top + radar_h + 10, rw, ours_h)
	var cy := top + radar_h + ours_h + 20
	d["car"] = Rect2(rx, cy, rw, bottom - cy)
	var draws := {"timing": func(r: Rect2): _draw_timing(r, sim, tel), "weather": func(r: Rect2): _draw_weather(r, tel),
		"ours": func(r: Rect2): _draw_ours(r, sim, tel), "car": func(r: Rect2): _draw_car(r, sim, tel),
		"feed": func(r: Rect2): _draw_feed(r, tel)}
	for id in layout.draw_order(["timing", "weather", "ours", "car", "feed"]):
		_in_panel(id, layout.place(id, d[id]), draws[id])
	layout.place("pip", _pip_at)
	_hits.append([_pip_at, "pip", null])
	if _pip_on():
		OnboardPip.draw(self, font, onboard, _pip_at, session, selected, cam_mode == 2)
	else:
		_draw_camera_off(_pip_at)
	layout.draw_handles(self, _hover, font)
	if layout.customised():
		var rb := Rect2(vp.x - 196, 14, 132, 32)
		var hot := rb.has_point(_hover)
		draw_rect(rb, Color(1, 1, 1, 0.14 if hot else 0.06))
		draw_rect(rb, Color(1, 1, 1, 0.5 if hot else 0.25), false, 1.0)
		_text(Vector2(rb.position.x, rb.position.y + 21), "Reset layout", 14, Color.WHITE if hot else DIM, HORIZONTAL_ALIGNMENT_CENTER, rb.size.x)
		_hits.append([rb, "reset_layout", null])
	var keys := InputPrompt.fill("Click a car to look at it    Tab timing / pace    ↑↓ choose car    ←→ or wheel filter feed    Drag a title bar to move, the corner to zoom    {strategy_screen} / {ui_cancel} close")
	if InputPrompt.pad:
		keys = InputPrompt.fill("D-pad ↑↓ choose car    ←→ filter feed    {ui_cancel} close")
		if session.local_car >= 0 and session.sim.pits.enabled:
			keys += "    %s / %s tyres to change" % [InputPrompt.button(JOY_BUTTON_LEFT_SHOULDER), InputPrompt.button(JOY_BUTTON_RIGHT_SHOULDER)]
	if _can_plan() and not InputPrompt.pad:
		keys += "    Enter pit stop settings"
	if _cam_allowed():
		keys += "    %s onboard camera: %s" % [InputPrompt.key("camera_toggle"), ["off", "front", "rear"][cam_mode]]
	_text(Vector2(16, vp.y - 12), keys + "    The race keeps running", 13, DIM)
	_button(Rect2(vp.x - 52, 14, 36, 32), "✕", "close", 18)
	if _note_time > 0.0:
		_text(Vector2(vp.x - 16, vp.y - 12), _note, 14, YELLOW, HORIZONTAL_ALIGNMENT_RIGHT, vp.x * 0.4)


func _draw_header(r: Rect2, sim: RaceSim, tel: RaceTelemetry) -> void:
	var lead := sim.entries[sim.running_order[0]] if not sim.running_order.is_empty() else null
	var lap := mini(lead.laps_done + 1, sim.settings.laps) if lead else 0
	_text(r.position + Vector2(0, 26), "STRATEGIST", 26, YELLOW)
	_text(r.position + Vector2(185, 26), "%s   ·   Lap %d / %d   ·   %s" % [sim.track.display_name, lap,
		sim.settings.laps, fmt_lap(sim.race_time).trim_suffix("0")], 18)
	var f := tel.forecast
	_text(r.position + Vector2(r.size.x - 580 - (150.0 if layout.customised() else 0.0), 26), "%02d:%02d   %s   Air %d°   Track %d°   Wet %d%%" % [
		int(f.time_of_day_h), int(fmod(f.time_of_day_h, 1.0) * 60.0), WeatherForecast.weather_label(f.weather),
		int(f.ambient_c), int(f.track_c), int(f.wetness * 100.0)], 16, Color(0.75, 0.85, 1.0),
		HORIZONTAL_ALIGNMENT_RIGHT, 520)


## The car we're really racing: the one the player marked, else worked out.
func rival() -> int:
	var me := _our_car()
	if rival_pick >= 0 and rival_pick != me and rival_pick < session.sim.car_count() and not session.sim.entries[rival_pick].dnf:
		return rival_pick
	return session.telemetry.rival_of(session.sim, me)


## Pace ranks for our class (every class when there's no car of ours).
func _ranks() -> Dictionary:
	var me := _our_car()
	var cls := session.sim.defs[me].class_tag if me >= 0 and RaceTelemetry.multi_class(session.sim) else ""
	return session.telemetry.pace_ranks(session.sim, cls)


## A small coloured tag (RIVAL, +1L) ending at x; returns its left edge.
func _chip(right_x: float, cy: float, label: String, col: Color, fs := 11) -> float:
	var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 10
	var r := Rect2(right_x - w, cy - fs * 0.5 - 3, w, fs + 6)
	draw_rect(r, Color(col, 0.28))
	draw_rect(r, col, false, 1.0)
	_text(Vector2(r.position.x, r.position.y + fs + 1), label, fs, col.lightened(0.35), HORIZONTAL_ALIGNMENT_CENTER, w)
	return r.position.x


## The tabs at the top of the timing panel: TIMING | PACE.
func _view_tabs(r: Rect2) -> void:
	var x := r.position.x + 8
	for k in 2:
		var label: String = ["TIMING", "PACE"][k]
		var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 22
		var tr := Rect2(x, r.position.y + 5, w, 22)
		var on := view == k
		if on:
			draw_rect(tr, Color(1, 0.88, 0.35, 0.22))
			draw_rect(tr, Color(1, 0.88, 0.35, 0.8), false, 1.5)
		elif tr.has_point(_hover):
			draw_rect(tr, Color(1, 1, 1, 0.3), false, 1.0)
		_text(Vector2(tr.position.x, tr.position.y + 16), label, 13, Color.WHITE if on else DIM, HORIZONTAL_ALIGNMENT_CENTER, w)
		_hits.append([tr, "view", k])
		x += w + 6
	if not InputPrompt.pad:
		_text(Vector2(x + 4, r.position.y + 21), "Tab", 11, Color(1, 1, 1, 0.35))
	# Key: what the colours mean.
	var kx := r.end.x - 10
	for item in [["backmarker", BACKMARKER], ["our rival", ORANGE], ["us", YELLOW], ["fastest", PURPLE], ["coming through", RaceTelemetry.relation_colour(RaceTelemetry.REL_FASTER)]]:
		var w := font.get_string_size(item[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		_text(Vector2(kx - w, r.position.y + 21), item[0], 11, Color(item[1], 0.9))
		draw_rect(Rect2(kx - w - 12, r.position.y + 13, 8, 8), item[1])
		kx -= w + 26


## Row background for car i: us, our rival, the selected car, hover, stripes.
func _row_bg(row: Rect2, i: int, stripe: bool, riv: int) -> void:
	if i == _our_car():
		draw_rect(row, Color(1, 0.88, 0.35, 0.16))
	elif i == riv:
		draw_rect(row, Color(ORANGE, 0.14))
	elif row.has_point(_hover):
		draw_rect(row, Color(1, 1, 1, 0.07))
	elif stripe:
		draw_rect(row, Color(1, 1, 1, 0.025))
	if i == selected:
		draw_rect(row, Color(1, 1, 1, 0.75), false, 1.5)
	elif i == riv:
		draw_rect(row, Color(ORANGE, 0.6), false, 1.0)


## Name colour: us yellow, rival orange, backmarkers blue, players light blue.
func _name_colour(i: int, riv: int, bm: bool) -> Color:
	if i == _our_car():
		return YELLOW
	if i == riv:
		return ORANGE
	if bm:
		return BACKMARKER.lightened(0.25)
	return Color(0.75, 0.85, 1) if not session.sim.entries[i].is_ai else Color.WHITE


func _draw_timing(r: Rect2, sim: RaceSim, tel: RaceTelemetry) -> void:
	_panel(r)
	_view_tabs(r)
	if view == VIEW_PACE:
		_draw_pace(Rect2(r.position + Vector2(0, 30), r.size - Vector2(0, 30)), sim, tel)
		return
	r = Rect2(r.position + Vector2(0, 24), r.size - Vector2(0, 24))
	# Column x positions (fractions of a 1060 px table, scaled to fit).
	var k := r.size.x / 1060.0
	var cols := {"pos": 8, "drv": 52, "car": 194, "last": 274, "avg3": 346, "avg5": 418, "best": 490, "s1": 562,
		"gap": 722, "int": 790, "tyre": 852, "wear": 930, "pit": 990}
	var wear_on := sim.settings.tyre_wear_enabled
	for key in cols:
		cols[key] = r.position.x + cols[key] * k
	var n := sim.running_order.size()
	var multi := RaceTelemetry.multi_class(sim)
	# The strip along the bottom: who's just ahead and behind on the road,
	# and whether we're racing them.
	var me := _our_car()
	var road_h := 52.0 if me >= 0 else 0.0
	var road := tel.road_neighbours(sim, me) if me >= 0 else {}
	if road_h > 0.0:
		_draw_road(Rect2(r.position.x, r.end.y - road_h, r.size.x, road_h), sim, me, road)
		r.size.y -= road_h
	var rh := clampf((r.size.y - 34) / maxf(n, 1), 14.0, 28.0)
	var fs := 15 if rh >= 22.0 else (13 if rh >= 17.0 else 11)
	var hy := r.position.y + 22
	for h in [["pos", "P"], ["drv", "DRIVER"], ["car", "CAR"], ["last", "LAST"], ["avg3", "AVG 3"],
			["avg5", "AVG 5"], ["best", "BEST"], ["gap", "GAP"], ["int", "INT"], ["tyre", "TYRES"], ["wear", "TYRE LEFT" if wear_on else ""], ["pit", "STOP NOW"]]:
		_text(Vector2(cols[h[0]], hy), h[1], 12, DIM)
	var sw := 52.0 * k
	for s in sim.track.sectors.size():
		_text(Vector2(cols["s1"] + s * sw, hy), "S%d" % (s + 1), 12, DIM)
	var riv := rival()
	var ranks := _ranks()
	for p in n:
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var c := tel.cars[i]
		var y := r.position.y + 32 + p * rh
		if y + rh > r.end.y + 2:
			break      # a panel made too short for the whole field
		var row := Rect2(r.position.x + 2, y, r.size.x - 4, rh - 2)
		var bm := tel.is_backmarker(sim, me, i)
		_row_bg(row, i, p % 2 == 1, riv)
		_hits.append([row, "car", i])
		var ty := y + rh * 0.5 + fs * 0.35
		var cy := y + rh * 0.5 - 1
		var dim_row := 0.6 if bm else 1.0
		_text(Vector2(cols["pos"], ty), str(e.position), fs, Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, 26 * k)
		var cls := sim.defs[i].class_tag
		draw_rect(Rect2(cols["drv"] - 12 * k, y + 4, 5, rh - 10), CarCatalog.class_colour(cls) if multi else sim.defs[i].colour)
		var name_end: float = cols["car"] - 6 * k
		# The cars either side of us on the road get an arrow in their
		# relation's colour (are we racing them, or is it traffic?).
		var arrow := ""
		if me >= 0 and i != me and (i == road.get("ahead", -1) or i == road.get("behind", -1)):
			arrow = "▲" if i == road.get("ahead", -1) else "▼"
		if bm:
			name_end = _chip(name_end, cy, ("%s " % arrow if arrow != "" else "") + "+%dL" % tel.laps_behind(sim, me, i), BACKMARKER) - 4
		elif i == riv:
			name_end = _chip(name_end, cy, ("%s " % arrow if arrow != "" else "") + "RIVAL", ORANGE) - 4
		elif arrow != "":
			name_end = _chip(name_end, cy, arrow, RaceTelemetry.relation_colour(RaceTelemetry.relation(sim, me, i))) - 4
		_text(Vector2(cols["drv"], ty), e.driver_name, fs, _name_colour(i, riv, bm), HORIZONTAL_ALIGNMENT_LEFT, name_end - cols["drv"])
		var car_x: float = cols["car"]
		var car_name := sim.defs[i].display_name
		if multi:   # the class and its place in it, in the class colour; then the make
			car_x += _class_chip(Vector2(car_x, cy), cls, RaceTelemetry.class_position(sim, i), fs - 3, dim_row) + 4
			car_name = str(RaceHud.badge_for(sim.defs[i])[0])
		_text(Vector2(car_x, ty), car_name, fs - 2, Color(DIM, DIM.a * dim_row), HORIZONTAL_ALIGNMENT_LEFT, cols["last"] - 6 * k - car_x)
		for key in RaceTelemetry.PACE_KEYS:
			var v := tel.pace_value(i, key)
			var top: Array = ranks.get(key, [])
			var col := Color(1, 1, 1, 0.9 * dim_row)
			if v > 0.0 and not top.is_empty() and top[0] == i:
				col = PURPLE
			elif key == "last" and v > 0.0 and v == c.best_lap():
				col = GREEN
			_text(Vector2(cols[key], ty), fmt_lap(v), fs, col)
		var best := c.best_lap()
		_text(Vector2(cols["best"], ty), fmt_lap(best), fs, PURPLE if best > 0.0 and best == tel.fastest_lap else Color(1, 1, 1, 0.75 * dim_row))
		var secs := c.last_sectors()
		for s in secs.size():
			var v: float = secs[s]
			var col := Color(1, 1, 1, dim_row)
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
		_text(Vector2(cols["gap"], ty), gap, fs, Color(1, 1, 1, dim_row))
		_text(Vector2(cols["int"], ty), inter, fs, YELLOW if p > 0 and c.interval < 1.0 and inter != "" else Color(1, 1, 1, 0.85 * dim_row))
		var car := sim.cars[i]
		var tc := sim.compounds[i]
		for t in 4:
			var tr := Rect2(cols["tyre"] + (t % 2) * 9 * k, y + 3 + (t / 2) * (rh - 6) * 0.5, 7 * k, (rh - 8) * 0.5)
			draw_rect(tr, _temp_colour(car.tyre_temp[t], tc))
		_text(Vector2(cols["tyre"] + 22 * k, ty), "%d°" % int((car.tyre_temp[0] + car.tyre_temp[1] + car.tyre_temp[2] + car.tyre_temp[3]) / 4.0),
			fs - 2, {"hot": Color(1, 0.5, 0.4), "cold": Color(0.55, 0.7, 1.0)}.get(c.tyre_state, Color(1, 1, 1, 0.8)))
		_text(Vector2(cols["tyre"] + 56 * k, ty), sim.compounds[i].display_name.left(1), fs - 3, DIM)
		if wear_on:
			_wear_cell(Vector2(cols["wear"], y), rh, k, car.tyre_wear, fs)
		if not c.pit.is_empty():
			var pit_col := GREEN if c.pit["ideal"] else (Color(0.8, 1.0, 0.6) if c.pit["clear_air"] else Color(1, 1, 1, 0.55))
			var mark := "  clear" if c.pit["clear_air"] else ""
			_text(Vector2(cols["pit"], ty), "P%d%s" % [c.pit["rejoin_pos"], mark], fs - 1, pit_col)


## A class chip ("GT3 2") starting at x, centred on cy; returns its width.
func _class_chip(at: Vector2, cls: String, pos: int, fs: int, alpha := 1.0) -> float:
	var t := "%s %d" % [CarCatalog.class_short(cls), pos] if pos > 0 else CarCatalog.class_short(cls)
	var w := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 8
	var r := Rect2(at.x, at.y - fs * 0.5 - 2, w, fs + 4)
	draw_rect(r, Color(CarCatalog.class_colour(cls), alpha))
	_text(Vector2(r.position.x, r.position.y + fs + 0.5), t, fs, CarCatalog.class_text_colour(cls), HORIZONTAL_ALIGNMENT_CENTER, w)
	return w


## Who's just ahead of and behind our car on the road (whatever lap they're
## on), and what they are to us: a car we're racing, a backmarker, the
## leaders lapping us, or another class coming through.
func _draw_road(r: Rect2, sim: RaceSim, me: int, road: Dictionary) -> void:
	var x0 := r.position.x + 10
	draw_line(Vector2(x0, r.position.y + 2), Vector2(r.end.x - 10, r.position.y + 2), Color(1, 1, 1, 0.12))
	_text(Vector2(x0, r.position.y + 16), "ON THE ROAD", 11, DIM)
	var multi := RaceTelemetry.multi_class(sim)
	for k in 2:
		var ahead := k == 0
		var j: int = road.get("ahead" if ahead else "behind", -1)
		var y := r.position.y + 22 + k * 23
		var x := x0
		_text(Vector2(x, y + 11), ("AHEAD" if ahead else "BEHIND"), 12, Color(1, 1, 1, 0.75))
		x += 64
		if j < 0:
			_text(Vector2(x, y + 11), "clear road", 14, DIM)
			continue
		var secs: float = road.get("ahead_s" if ahead else "behind_s", 0.0)
		_text(Vector2(x, y + 11), "%.1f s" % secs, 14, YELLOW if secs < 1.0 else Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, 52)
		x += 62
		var rel := RaceTelemetry.relation(sim, me, j)
		var rc := RaceTelemetry.relation_colour(rel)
		var tag := RaceTelemetry.relation_text(rel)
		var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 10
		_chip(x + tw, y + 6, tag, rc)
		x += tw + 8
		var cls := sim.defs[j].class_tag
		if multi:
			x += _class_chip(Vector2(x, y + 6), cls, RaceTelemetry.class_position(sim, j), 11) + 6
		var name := sim.entries[j].driver_name
		_text(Vector2(x, y + 11), name, 14, rc.lightened(0.3), HORIZONTAL_ALIGNMENT_LEFT, 170)
		x += minf(font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x, 170.0) + 10
		_text(Vector2(x, y + 11), road_advice(sim, me, j, ahead), 13, Color(1, 1, 1, 0.7), HORIZONTAL_ALIGNMENT_LEFT, r.end.x - 10 - x)


## What a car just ahead (or behind) on the road means for us, in a few words.
static func road_advice(sim: RaceSim, me: int, j: int, ahead: bool) -> String:
	var rel := RaceTelemetry.relation(sim, me, j)
	var cls := sim.defs[j].class_tag
	var their := RaceTelemetry.class_position(sim, j)
	var ours := RaceTelemetry.class_position(sim, me)
	var laps := absi(roundi((sim.entries[me].distance - sim.entries[j].distance) / sim.track.length))
	var lap_s := "%d lap%s" % [laps, "" if laps == 1 else "s"]
	match rel:
		RaceTelemetry.REL_RIVAL:
			return ("racing us for P%d in class: attack" % their) if ahead else ("racing us: defend P%d in class" % ours)
		RaceTelemetry.REL_LAPPED:
			return ("backmarker, %s down: pass it, don't fight" % lap_s) if ahead else ("backmarker, %s down: no threat" % lap_s)
		RaceTelemetry.REL_LAPPING:
			return ("%s up on us: not a fight" % lap_s) if ahead else ("class leaders, %s up: coming through, let them by" % lap_s)
		RaceTelemetry.REL_SLOWER:
			return ("%s traffic: pass it, not a fight" % cls) if ahead else ("%s behind: no threat" % cls)
		RaceTelemetry.REL_FASTER:
			var who := ("the %s leader" % cls) if their == 1 else ("%s P%d" % [cls, their])
			return ("%s, pulling away: not a fight" % who) if ahead else ("%s coming through: let them by cleanly" % who)
	return ""


## PACE: one table of every car in our class with its last lap, last 3 and
## last 5 laps (each ranked, with the gap to us), sorted on any column by
## clicking its heading; then the rival and the backmarkers coming up.
func _draw_pace(r: Rect2, sim: RaceSim, tel: RaceTelemetry) -> void:
	var me := _our_car()
	var riv := rival()
	var ranks := _ranks()
	var x0 := r.position.x + 10
	var w := r.size.x - 20
	# The summary line: who's quickest on each measure.
	var multi := RaceTelemetry.multi_class(sim)
	var head := "Fastest in %s" % sim.defs[me].class_tag if me >= 0 and multi else "Fastest"
	_text(Vector2(x0, r.position.y + 14), head.to_upper(), 12, DIM)
	var sx := x0 + 130
	var sw := (w - 130) / 3.0
	for k in RaceTelemetry.PACE_KEYS.size():
		var key: String = RaceTelemetry.PACE_KEYS[k]
		var list: Array = ranks.get(key, [])
		var txt := "%s  -" % RaceTelemetry.PACE_LABELS[key]
		if not list.is_empty():
			txt = "%s  %s  %s" % [RaceTelemetry.PACE_LABELS[key].to_lower().capitalize(), sim.entries[list[0]].driver_name, fmt_lap(tel.pace_value(list[0], key))]
		_text(Vector2(sx + k * sw, r.position.y + 14), txt, 14, PURPLE, HORIZONTAL_ALIGNMENT_LEFT, sw - 12)
	# One table, sorted on the column the player clicked; then the rival and
	# the backmarkers ahead.
	var foot_h := 92.0
	var lists := Rect2(r.position.x + 10, r.position.y + 26, r.size.x - 20, r.size.y - 26 - foot_h)
	_pace_table(lists, ranks, me, riv)
	var fy := lists.end.y + 6
	draw_line(Vector2(x0, fy), Vector2(x0 + w, fy), Color(1, 1, 1, 0.12))
	_text(Vector2(x0, fy + 22), "OUR RIVAL", 12, DIM)
	if riv < 0 or me < 0:
		_text(Vector2(x0 + 110, fy + 22), "nobody on our lap in our class", 14, DIM)
	else:
		var order := sim.running_order
		var ahead := order.find(riv) < order.find(me)
		var gap := absf(tel.cars[riv].gap_leader - tel.cars[me].gap_leader)
		var where := "%.1f s %s" % [gap, "ahead" if ahead else "behind"]
		var line := "P%d %s, %s" % [sim.entries[riv].position, sim.entries[riv].driver_name, where]
		var mine := tel.pace_value(me, "avg3")
		var theirs := tel.pace_value(riv, "avg3")
		if mine > 0.0 and theirs > 0.0:
			var d := theirs - mine   # > 0: we're quicker
			line += ",  %s %.2f s/lap over the last 3" % ["we're quicker by" if d > 0.0 else "they're quicker by", absf(d)]
		_text(Vector2(x0 + 110, fy + 22), line, 14, ORANGE, HORIZONTAL_ALIGNMENT_LEFT, w - 110)
	_text(Vector2(x0, fy + 48), "BACKMARKERS", 12, DIM)
	var bms := tel.backmarkers_ahead(sim, me, 3)
	if bms.is_empty():
		_text(Vector2(x0 + 110, fy + 48), "none up the road", 14, DIM)
	else:
		var bx := x0 + 110
		var bw := (w - 110) / 3.0
		for b in bms:
			var tag := "+%dL" % b["laps"]
			var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 10
			_chip(bx + tw, fy + 43, tag, BACKMARKER)
			var txt := "%s  %.1f s up the road" % [sim.entries[b["car"]].driver_name, b["seconds"]]
			_text(Vector2(bx + tw + 6, fy + 48), txt, 14, BACKMARKER.lightened(0.3), HORIZONTAL_ALIGNMENT_LEFT, bw - tw - 16)
			bx += bw
	_text(Vector2(x0, fy + 74), "Laps since the start only (lap 1 left out).  Gaps are to %s." % ("our car" if me >= 0 else "the leader"), 12, Color(1, 1, 1, 0.4), HORIZONTAL_ALIGNMENT_LEFT, w)


## Sorts the PACE table on a column; the same column again turns it round.
## Times sort fastest first, POS from the leader, drivers A to Z.
func sort_pace(key: String) -> void:
	if key == pace_sort:
		pace_desc = not pace_desc
	else:
		pace_sort = key
		pace_desc = false


## The value car i sorts on in a PACE column (no time yet: INF, always last).
func _sort_value(i: int, key: String) -> float:
	var sim := session.sim
	var tel := session.telemetry
	match key:
		"pos": return float(sim.entries[i].position)
		"best":
			var b := tel.cars[i].best_lap()
			return b if b > 0.0 else INF
		"gap": return float(sim.running_order.find(i))
		"wear":    # most rubber left first: the most worn tyre on each car
			var w := sim.cars[i].tyre_wear
			return float(w[worst_tyre(w)])
	var v := tel.pace_value(i, key)
	return v if v > 0.0 else INF


## The cars in the PACE table (our class in a multi-class race), sorted.
func pace_rows() -> Array:
	var sim := session.sim
	var me := _our_car()
	var cls := sim.defs[me].class_tag if me >= 0 and RaceTelemetry.multi_class(sim) else ""
	var list: Array = []
	for i in sim.car_count():
		if not sim.is_retired(i) and (cls == "" or sim.defs[i].class_tag == cls):
			list.append(i)
	var key := pace_sort
	var desc := pace_desc
	if key == "driver":
		list.sort_custom(func(a: int, b: int):
			var x := sim.entries[a].driver_name.naturalnocasecmp_to(sim.entries[b].driver_name)
			return x > 0 if desc else x < 0)
	else:
		list.sort_custom(func(a: int, b: int):
			var va := _sort_value(a, key)
			var vb := _sort_value(b, key)
			if is_inf(va) != is_inf(vb):
				return is_inf(vb)          # cars with no time at the bottom either way
			if va == vb:
				return sim.entries[a].position < sim.entries[b].position
			return va > vb if desc else va < vb)
	return list


## The PACE table: every car with its last lap, last 3 and last 5 laps (each
## with its rank on that measure and the gap to us), best lap and race gap.
## Click a heading to sort on it.
func _pace_table(r: Rect2, ranks: Dictionary, me: int, riv: int) -> void:
	var sim := session.sim
	var tel := session.telemetry
	var k := r.size.x / 1040.0
	var cx := {}
	for c in PACE_COLUMNS:
		cx[c[0]] = r.position.x + float(c[2]) * k
	# Headings: click to sort; the sorted one is yellow with an arrow.
	var hy := r.position.y + 18
	var wear_on := sim.settings.tyre_wear_enabled
	for c in PACE_COLUMNS:
		var key: String = c[0]
		if key == "wear" and not wear_on:
			continue
		var label: String = c[1]
		var on: bool = key == pace_sort
		if on:
			label += "  ▼" if pace_desc else "  ▲"
		var col := YELLOW if on else DIM
		var hw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 12
		var hr := Rect2(cx[key] - 4, r.position.y, hw, 26)
		if c[3]:
			if hr.has_point(_hover):
				draw_rect(hr, Color(1, 1, 1, 0.08))
				col = Color.WHITE if not on else YELLOW
			_hits.append([hr, "sort", key])
		_text(Vector2(cx[key], hy), label, 12, col)
	draw_line(Vector2(r.position.x, r.position.y + 26), Vector2(r.end.x, r.position.y + 26), Color(1, 1, 1, 0.15))
	var list := pace_rows()
	if list.is_empty():
		_text(Vector2(r.position.x, r.position.y + 50), "no laps yet", 14, DIM)
		return
	var rh := clampf((r.size.y - 34) / maxf(list.size(), 1), 14.0, 28.0)
	var fs := 15 if rh >= 23.0 else (13 if rh >= 17.0 else 11)
	for p in list.size():
		var i: int = list[p]
		var y := r.position.y + 30 + p * rh
		if y + rh > r.end.y + 2:
			_text(Vector2(r.position.x + 4, y + fs), "+ %d more" % (list.size() - p), 12, DIM)
			break
		var row := Rect2(r.position.x, y, r.size.x, rh - 2)
		var bm := tel.is_backmarker(sim, me, i)
		_row_bg(row, i, p % 2 == 1, riv)
		_hits.append([row, "car", i])
		var ty := y + rh * 0.5 + fs * 0.35
		var cy := y + rh * 0.5 - 1
		_text(Vector2(cx["rank"], ty), str(p + 1), fs - 2, DIM, HORIZONTAL_ALIGNMENT_RIGHT, 22 * k)
		_text(Vector2(cx["pos"], ty), "P%d" % sim.entries[i].position, fs - 1, Color(1, 1, 1, 0.8))
		draw_rect(Rect2(cx["driver"] - 10, y + 4, 4, rh - 10), sim.defs[i].colour)
		var name_end: float = cx["last"] - 14
		if bm:
			name_end = _chip(name_end, cy, "+%dL" % tel.laps_behind(sim, me, i), BACKMARKER) - 4
		elif i == riv:
			name_end = _chip(name_end, cy, "RIVAL", ORANGE) - 4
		_text(Vector2(cx["driver"], ty), sim.entries[i].driver_name, fs, _name_colour(i, riv, bm), HORIZONTAL_ALIGNMENT_LEFT, name_end - cx["driver"])
		for key in RaceTelemetry.PACE_KEYS:
			var v := tel.pace_value(i, key)
			var x: float = cx[key]
			if v <= 0.0:
				_text(Vector2(x, ty), "-", fs, DIM)
				continue
			var order: Array = ranks.get(key, [])
			var rank := order.find(i) + 1
			# Rank on this measure, the time, the gap to us.
			_text(Vector2(x, ty), str(rank) if rank > 0 else "", fs - 4, PURPLE if rank == 1 else Color(1, 1, 1, 0.4),
				HORIZONTAL_ALIGNMENT_RIGHT, 16 * k)
			var tcol := PURPLE if rank == 1 else (YELLOW if i == me else Color.WHITE)
			_text(Vector2(x + 22 * k, ty), fmt_lap(v), fs, tcol)
			var ref := tel.pace_value(me, key) if me >= 0 else 0.0
			if i != me and ref > 0.0:
				var dd := v - ref
				_text(Vector2(x + 96 * k, ty), "%+.3f" % dd, fs - 3, GREEN if dd > 0.0 else RED)
		var best := tel.cars[i].best_lap()
		_text(Vector2(cx["best"], ty), fmt_lap(best), fs - 1, PURPLE if best > 0.0 and best == tel.fastest_lap else Color(1, 1, 1, 0.75))
		var c := tel.cars[i]
		var gap := "Leader" if sim.running_order.find(i) == 0 else (("+%d L" % c.laps_down) if c.laps_down >= 1 else "+" + fmt_gap(c.gap_leader))
		_text(Vector2(cx["gap"], ty), gap, fs - 1, Color(1, 1, 1, 0.8))
		if wear_on:
			_wear_cell(Vector2(cx["wear"], y), rh, 1.0, sim.cars[i].tyre_wear, fs)


func _draw_weather(r: Rect2, tel: RaceTelemetry) -> void:
	_panel(r, "WEATHER RADAR")
	radar.draw(self, font, r, tel.forecast, _track_pts, session.sim.track.short_name, _hover, _hits)


## Where the onboard picture goes while the camera is off (or there is none).
func _draw_camera_off(r: Rect2) -> void:
	_panel(r, "ONBOARD CAMERA")
	if not _cam_allowed():
		_text(Vector2(r.position.x, r.get_center().y + 5), "No onboard camera on this screen", 14, DIM, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
		return
	_text(Vector2(r.position.x, r.get_center().y - 14), "Camera off", 15, DIM, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	_button(Rect2(r.get_center().x - 110, r.get_center().y + 2, 220, 30), "TURN ON  (%s)" % InputPrompt.key("camera_toggle"), "cam", 14)


## A temperature, pressure or wear reading in a tyre card: big value, small label.
func _reading(at: Vector2, w: float, value: String, label: String, col: Color, fs := 22) -> void:
	_text(at, value, fs, col, HORIZONTAL_ALIGNMENT_LEFT, w)
	_text(at + Vector2(0, 15), label, 11, DIM, HORIZONTAL_ALIGNMENT_LEFT, w)


## Colour for a hot tyre pressure against the compound's best one: green in
## the window, blue under it, orange and red over it.
static func psi_colour(hot: float, tc: TyreCompound) -> Color:
	var x := (hot - tc.optimal_hot_psi) / maxf(tc.pressure_window_psi, 0.1)
	if absf(x) < 0.34:
		return GREEN
	if x < 0.0:
		return Color(0.45, 0.65, 1.0) if x < -1.0 else Color(0.6, 0.85, 1.0)
	return RED if x > 1.0 else Color(1.0, 0.7, 0.35)


## Our car: the setup it runs now (the settings a stop can change in yellow)
## and each tyre's compound, temperature, hot and cold pressure and wear, with
## the PIT STOP SETTINGS button that opens the dialog. A screen with no car of
## its own shows the selected car.
func _draw_ours(r: Rect2, sim: RaceSim, tel: RaceTelemetry) -> void:
	var i := _our_car()
	var ours := i >= 0
	if not ours:
		i = selected
	if i < 0 or i >= sim.car_count():
		return
	_panel(r, "OUR CAR" if ours else "CAR")
	var e := sim.entries[i]
	var def := sim.defs[i]
	var car := sim.cars[i]
	var x := r.position.x + 10
	draw_rect(Rect2(x + 64, r.position.y + 8, 5, 16), def.colour)
	_text(Vector2(x + 76, r.position.y + 21), "P%d  %s  ·  %s" % [e.position, e.at_wheel(), def.display_name], 15,
		YELLOW if ours else Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 360)
	if _can_plan():
		_button(Rect2(r.end.x - 250, r.position.y + 5, 240, 30), "PIT STOP SETTINGS" + ("" if InputPrompt.pad else "  ⏎"), "plan", 14, YELLOW)
	var half := r.size.x * 0.43     # setup on the left, the car on the right
	var y := r.position.y + 54
	# Damaged: the damage advice takes the setup's place (the setup is still
	# in the pit stop settings).
	var adv := DamageAdvice.assess(sim, tel, i)
	if int(adv["level"]) >= DamageAdvice.LIGHT:
		y = _draw_damage(Rect2(x - 4, y - 16, half - 12, 20 + 8 * 19 + 2), adv) + 22
	else:
		y = _draw_setup(x, y, half, sim, i, def) + 6
	draw_line(Vector2(x, y - 12), Vector2(x + half - 20, y - 12), Color(1, 1, 1, 0.1))
	var lines := []
	if sim.settings.fuel_enabled:
		var laps := sim.pits.fuel_laps(i)
		lines.append(["Fuel", "%.1f L on board  ·  %s" % [car.fuel_l, "%.1f laps" % laps if laps < 99.0 else "-"],
			RED if laps < 1.5 else Color.WHITE])
	var psis := sim.pits.wheel_psi(i)
	var cold := PackedStringArray()
	for w in 4:
		cold.append("%.1f" % (sim.wheel_compounds[i][w].cold_psi + float(psis[w])))
	lines.append(["Cold psi", "FL %s  FR %s  ·  RL %s  RR %s" % [cold[0], cold[1], cold[2], cold[3]], Color.WHITE])
	var tc0: TyreCompound = sim.wheel_compounds[i][0]
	lines.append(["Hot psi", "best %.1f, green within ±%.1f" % [tc0.optimal_hot_psi, tc0.pressure_window_psi * 0.34], DIM])
	if sim.damage_level != CarDamage.Level.OFF:
		var rep := CarDamage.report(car)
		var hurt := PackedStringArray()
		for part in ["aero", "suspension", "alignment", "engine", "gearbox"]:
			if float(rep[part]) > 0.02:
				hurt.append("%s %d%%" % [part, roundi(float(rep[part]) * 100.0)])
		var punct := (rep["punctures"] as Array).count(true)
		if punct > 0:
			hurt.append("%d puncture%s" % [punct, "" if punct == 1 else "s"])
		var dmg_txt := "none" if hurt.is_empty() else ", ".join(hurt)
		if int(adv["level"]) == DamageAdvice.SCUFFS:
			dmg_txt = "scuffs only, not worth a repair"
		if int(adv["level"]) >= DamageAdvice.LIGHT:
			dmg_txt = "%s, see above" % (adv["level_text"] as String).to_lower()
		lines.append(["Damage", dmg_txt, GREEN if hurt.is_empty() else DamageAdvice.level_colour(int(adv["level"]))])
	if ours and sim.pits.enabled:
		var plan: Dictionary = e.pit["plan"]
		var work := sim.pits.service_for(i, plan)
		var nxt := "tyres " + RaceHud.stop_tyres_text(sim, i, plan, work)
		if not session.pending_swap(i).is_empty():
			nxt += ", driver change"
		lines.append(["Next stop", nxt, Color(1.0, 0.75, 0.4)])
	for ln in lines:
		if y > r.end.y - 6:
			break
		_text(Vector2(x, y), ln[0], 12, DIM)
		_text(Vector2(x + 76, y), ln[1], 13, ln[2], HORIZONTAL_ALIGNMENT_LEFT, half - 100)
		y += 19
	# Right: the car from above with its four tyres (coloured by temperature)
	# and a card for each tyre beside it, like the pit stop settings.
	var tr := Rect2(r.position.x + half + 4, r.position.y + 42, r.size.x - half - 14, r.size.y - 52)
	var L := minf(tr.size.y - 32, 300.0)
	var Wd := L * 0.36
	var c := tr.get_center() + Vector2(0, 2)
	var top := c.y - L * 0.5
	var tw := Wd * 0.3
	var th := L * 0.19
	var wpos := [Vector2(c.x - Wd * 0.5 - tw + 4, top + L * 0.16), Vector2(c.x + Wd * 0.5 - 4, top + L * 0.16),
		Vector2(c.x - Wd * 0.5 - tw + 4, top + L * 0.70), Vector2(c.x + Wd * 0.5 - 4, top + L * 0.70)]
	PitPlanner.draw_car_top(self, font, c, L, Wd, top, def.colour, str(e.position))
	var cw := minf((tr.size.x - Wd - 2 * tw - 36) * 0.5, 210.0)
	var chh := minf((tr.size.y - 10) * 0.5, 140.0)
	var wear_on := sim.settings.tyre_wear_enabled
	for w in 4:
		var tc: TyreCompound = sim.wheel_compounds[i][w]
		var temp := car.tyre_temp[w]
		var hot := tc.hot_psi(float(psis[w]), temp)
		var tcol := _temp_colour(temp, tc)
		var ccol := PitPlanner.compound_colour(tc.id)
		# The tyre on the car: tread in its temperature colour, compound stripes.
		var tyre := Rect2(wpos[w], Vector2(tw, th))
		PitPlanner.card_on(self, tyre, Color(0.06, 0.06, 0.07), 5.0)
		PitPlanner.card_on(self, tyre.grow(-3), Color(tcol, 0.75), 4.0)
		draw_rect(Rect2(tyre.position.x + 2, tyre.position.y + 5, 2, tyre.size.y - 10), ccol)
		draw_rect(Rect2(tyre.end.x - 4, tyre.position.y + 5, 2, tyre.size.y - 10), ccol)
		if car.puncture[w] > 0.5:
			PitPlanner.card_on(self, tyre, Color(0, 0, 0, 0), 5.0, RED)
		_text(Vector2(tyre.position.x, tyre.get_center().y + 5), WHEELS[w], 12, Color(0, 0, 0, 0.85), HORIZONTAL_ALIGNMENT_CENTER, tyre.size.x)
		# Its card, with a line to the tyre.
		var cx := tr.position.x if w % 2 == 0 else tr.end.x - cw
		var cy := tr.position.y if w < 2 else tr.end.y - chh
		var cr := Rect2(cx, cy, cw, chh)
		var from := Vector2(cr.end.x if w % 2 == 0 else cr.position.x, clampf(tyre.get_center().y, cr.position.y + 10, cr.end.y - 10))
		draw_line(from, Vector2(tyre.position.x if w % 2 == 0 else tyre.end.x, tyre.get_center().y), Color(1, 1, 1, 0.18), 1.0)
		PitPlanner.card_on(self, cr, Color(1, 1, 1, 0.04), 6.0, Color(1, 1, 1, 0.1))
		var kx := cr.position.x + 10
		_text(Vector2(kx, cr.position.y + 19), WHEELS[w], 13, Color.WHITE)
		draw_circle(Vector2(kx + 34, cr.position.y + 14), 5.0, ccol)
		_text(Vector2(kx + 44, cr.position.y + 19), tc.display_name, 12, ccol.lightened(0.2), HORIZONTAL_ALIGNMENT_LEFT, cw - 58)
		var col_w := (cw - 20) * 0.5
		var vy := cr.position.y + 19 + maxf((chh - 19 - 44) * 0.5, 20.0)
		_reading(Vector2(kx, vy), col_w, "%d°" % roundi(temp), "temp", tcol, 20)
		_reading(Vector2(kx + col_w, vy), col_w, "%.1f" % hot, "hot psi", psi_colour(hot, tc), 20)
		if wear_on:
			var wt := clampf(float(car.tyre_wear[w]), 0.0, 1.0)
			var wcol := wear_colour(wt) if wt > 0.45 else Color(0.86, 0.89, 0.94)
			var bar := Rect2(kx, cr.end.y - 12, cw - 20, 5)
			_text(Vector2(kx, bar.position.y - 5), "%d%% left" % roundi((1.0 - wt) * 100.0), 12, wcol if wt > 0.45 else Color.WHITE)
			draw_rect(bar, Color(1, 1, 1, 0.1))
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * (1.0 - wt), bar.size.y)), wcol)
		else:
			_text(Vector2(kx, cr.end.y - 10), "wear off", 11, DIM)


## OUR CAR's setup now, in two columns; returns the y under it.
func _draw_setup(x: float, y: float, half: float, sim: RaceSim, i: int, def: CarDefinition) -> float:
	_text(Vector2(x, y), "SETUP NOW", 11, DIM)
	if sim.settings.tuning_enabled:
		var tw := font.get_string_size("SETUP NOW", HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		_text(Vector2(x + tw + 12, y), "yellow: changes at a stop", 11, Color(YELLOW, 0.7))
	var full := CarSetup.complete(def, def.tuning)
	full.merge(sim.pits.current_setup(i), true)
	var colw := (half - 24) * 0.5
	for c in SETUP_COLS.size():
		var cx := x + c * (colw + 8)
		var ly := y + 20
		for item in SETUP_COLS[c]:
			var key: String = item[0]
			var v := "fixed" if not CarSetup.adjustable(def, key) else CarSetup.format_value(def, key, float(full[key]))
			if key == "final_drive":
				v = "%.2f" % float(full[key])
			var pit_key := sim.settings.tuning_enabled and key in PitRules.PIT_SETUP_KEYS and CarSetup.adjustable(def, key)
			_text(Vector2(cx, ly), item[1], 12, DIM, HORIZONTAL_ALIGNMENT_LEFT, colw * 0.55)
			_text(Vector2(cx + colw * 0.56, ly), v, 13, YELLOW if pit_key else Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, colw * 0.44)
			ly += 19
	return y + 20 + 8 * 19


## The damage advice card (DamageAdvice.assess): how bad, the call, lap time
## lost, the repair time, what it costs to the flag, each damaged part, and
## why. Returns the y under it.
func _draw_damage(r: Rect2, adv: Dictionary) -> float:
	var level := int(adv["level"])
	var lcol := DamageAdvice.level_colour(level)
	PitPlanner.card_on(self, r, Color(lcol, 0.07), 6.0, Color(lcol, 0.45))
	var x := r.position.x + 10
	var w := r.size.x - 20
	var y := r.position.y + 19
	_text(Vector2(x, y), "DAMAGE", 11, DIM)
	var tw := font.get_string_size("DAMAGE", HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var lt: String = adv["level_text"]
	var lw := font.get_string_size(lt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 12
	PitPlanner.card_on(self, Rect2(x + tw + 8, y - 12, lw, 16), Color(lcol, 0.9), 4.0)
	_text(Vector2(x + tw + 14, y), lt, 11, Color(0.05, 0.05, 0.06))
	var call: String = adv["call"]
	if call != "":
		_text(Vector2(x, y + 1), call, 17, DamageAdvice.call_colour(call), HORIZONTAL_ALIGNMENT_RIGHT, w)
	# The three numbers that decide it.
	y += 30
	var cw := w / 3.0
	var loss := float(adv["loss_lap"])
	_reading(Vector2(x, y), cw - 6, "+%.1f s" % loss if loss >= 0.05 else "< 0.1 s", "per lap (estimate)",
		RED if loss >= 1.0 else (YELLOW if loss >= 0.3 else Color.WHITE), 19)
	var rep := float(adv["repair_s"])
	_reading(Vector2(x + cw, y), cw - 6, "%.0f s" % rep if rep > 0.0 else "none", "repair in the box", Color.WHITE, 19)
	var laps := int(adv["laps_left"])
	_reading(Vector2(x + 2 * cw, y), cw - 6, "%.0f s" % float(adv["cost_out"]) if laps > 0 else "-",
		"to the flag, %d lap%s" % [laps, "" if laps == 1 else "s"], Color.WHITE, 19)
	# Each damaged part: how bad, time a lap, repair time.
	y += 34
	for p in adv["parts"]:
		if y > r.end.y - 44:
			break
		var pct := float(p["pct"])
		var pcol := DamageAdvice.level_colour(DamageAdvice.LIGHT if pct < 30.0 else (DamageAdvice.MODERATE if pct < 60.0 else DamageAdvice.HEAVY))
		_text(Vector2(x, y), p["label"], 12, DIM, HORIZONTAL_ALIGNMENT_LEFT, w * 0.3)
		var bar := Rect2(x + w * 0.3, y - 8, w * 0.2, 6)
		draw_rect(bar, Color(1, 1, 1, 0.1))
		if p["part"] == "tyres":
			_text(Vector2(bar.position.x, y), "%d flat" % roundi(pct / 100.0), 12, RED)
		else:
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(pct / 100.0, 0.0, 1.0), bar.size.y)), pcol)
			_text(Vector2(bar.end.x + 6, y), "%d%%" % roundi(pct), 12, pcol)
		_text(Vector2(x + w * 0.6, y), "+%.1f s/lap" % float(p["loss_s"]), 12, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, w * 0.2)
		var fix := "fix %.0f s" % float(p["repair_s"]) if bool(p["fixed"]) and float(p["repair_s"]) > 0.0 \
			else ("new tyre" if p["part"] == "tyres" else ("free" if bool(p["fixed"]) else "too light to fix"))
		_text(Vector2(x, y), fix, 12, DIM, HORIZONTAL_ALIGNMENT_RIGHT, w)
		y += 17
	# Why, and any risk.
	y = maxf(y + 2, r.end.y - 38)
	var why: String = adv["why"]
	if (adv["risk"] as String) != "":
		why = (adv["risk"] as String) + " " + why
	for ln in _wrap(why, w, 12).slice(0, 2):
		_text(Vector2(x, y), ln, 12, Color(1, 0.55, 0.45) if (adv["risk"] as String) != "" else Color(0.85, 0.88, 0.95))
		y += 15
	return r.end.y


func _draw_car(r: Rect2, sim: RaceSim, tel: RaceTelemetry) -> void:
	if selected < 0 or selected >= sim.car_count():
		return
	_panel(r, "SELECTED CAR")
	var i := selected
	if i != _our_car() and _our_car() >= 0:
		var marked := rival_pick == i
		_button(Rect2(r.end.x - 152, r.position.y + 6, 142, 28), "AUTO RIVAL" if marked else "MARK AS RIVAL", "rival", 13,
			Color.WHITE if marked else ORANGE)
	var e := sim.entries[i]
	var c := tel.cars[i]
	var x := r.position.x + 10
	var w := r.size.x - 20
	draw_rect(Rect2(x, r.position.y + 30, 6, 22), sim.defs[i].colour)
	_text(Vector2(x + 14, r.position.y + 48), "P%d  %s" % [e.position, e.at_wheel()], 19,
		_name_colour(i, rival(), tel.is_backmarker(sim, _our_car(), i)), HORIZONTAL_ALIGNMENT_LEFT, w * 0.6)
	_text(Vector2(x + w * 0.6, r.position.y + 48), sim.defs[i].display_name, 14, DIM, HORIZONTAL_ALIGNMENT_LEFT, w * 0.4)
	var trend := c.trend()
	var trend_s := "steady" if absf(trend) < 0.05 else ("%+.2f s/lap" % trend)
	_text(Vector2(x, r.position.y + 74), "Avg 5 %s   Best %s   %s" % [fmt_lap(c.last5_avg), fmt_lap(c.best_lap()), trend_s], 14, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, w)
	var temps := sim.cars[i].tyre_temp
	_text(Vector2(x, r.position.y + 96), "Tyres %s  %d° %d° / %d° %d°  grip %d%%" % [c.tyre_state.to_upper(),
		int(temps[0]), int(temps[1]), int(temps[2]), int(temps[3]), int(c.tyre_grip * 100.0)], 14,
		{"hot": Color(1, 0.5, 0.4), "cold": Color(0.55, 0.7, 1.0)}.get(c.tyre_state, GREEN), HORIZONTAL_ALIGNMENT_LEFT, w)
	var oy := 0.0       # the lines below move down for the wear line
	if sim.settings.tyre_wear_enabled:
		_wear_line(Vector2(x, r.position.y + 118), w, sim.cars[i].tyre_wear, c)
		oy = 22.0
	var strat: Dictionary = tel.strategies.get(i, {})
	if i == session.local_car and sim.pits.enabled:
		# Our own car: what the next stop will do.
		var plan: Dictionary = e.pit["plan"]
		var work := sim.pits.service_for(i, plan)
		var line := "Next stop: tyres " + RaceHud.stop_tyres_text(sim, i, plan, work)
		var pend := session.pending_swap(i)
		if not pend.is_empty():
			line += ", driver change"
		_text(Vector2(x, r.position.y + 118 + oy), line, 14, Color(1.0, 0.75, 0.4), HORIZONTAL_ALIGNMENT_LEFT, w)
	else:
		_text(Vector2(x, r.position.y + 118 + oy), "Strategy: " + (strat.get("text", "no calls heard") as String), 14, Color(1.0, 0.75, 0.4), HORIZONTAL_ALIGNMENT_LEFT, w)
	# Pit window.
	var pa := c.pit
	if pa.is_empty():
		_text(Vector2(x, r.position.y + 144 + oy), "Pit window: waiting for timing", 14, DIM)
	else:
		var status := "IDEAL: no places lost, clear air" if pa["ideal"] else ("clear air" if pa["clear_air"] else "into traffic")
		_text(Vector2(x, r.position.y + 144 + oy), "Stop now: lose %.1f s, rejoin P%d (%s)" % [pa["loss"], pa["rejoin_pos"], status], 14,
			GREEN if pa["ideal"] else (Color(0.8, 1.0, 0.6) if pa["clear_air"] else Color(1, 0.75, 0.5)), HORIZONTAL_ALIGNMENT_LEFT, w)
		var gb := "%.1f s" % c.gap_behind if c.gap_behind >= 0.0 else "nobody"
		_text(Vector2(x, r.position.y + 164 + oy), "Gap behind %s, need %.1f s for a free stop" % [gb, pa["need"]], 13, DIM, HORIZONTAL_ALIGNMENT_LEFT, w)
	# Lap history: last laps against the 5-lap average.
	var hx := x
	var hy := r.position.y + 176 + oy
	var hw := w
	var hh := minf(r.end.y - hy - 8, 110.0)
	var n := mini(c.laps.size(), 12)
	if n == 0:
		return
	if r.end.y - hy > 150.0:
		_text(Vector2(hx, hy + 10), "LAST LAPS AGAINST THE 5-LAP AVERAGE (±2 s)", 11, DIM)
		hy += 18
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


## The selected car's tyre wear: rubber left on each tyre, coloured by wear,
## then the most worn one's rate and how many laps it has left at that rate.
func _wear_line(at: Vector2, w: float, wear, c: CarTelemetry) -> void:
	_text(at, "Wear", 14, DIM)
	var x := at.x + 44
	for t in 4:
		var wt := clampf(float(wear[t]), 0.0, 1.0)
		var txt := "%s %d%%" % [WHEELS[t], roundi((1.0 - wt) * 100.0)]
		_text(Vector2(x, at.y), txt, 14, wear_colour(wt) if wt > 0.45 else Color.WHITE)
		x += font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + (18 if t == 1 else 10)
	var worst := worst_tyre(wear)
	var rate := c.wear_per_lap()[worst]
	if rate <= 1e-5:
		return
	var left := CarTelemetry.laps_to_worn(float(wear[worst]), rate)
	var note := "%s -%.1f%%/lap, ~%d laps left" % [WHEELS[worst], rate * 100.0, int(left)] if left < 99.0 else "%s -%.1f%%/lap" % [WHEELS[worst], rate * 100.0]
	_text(Vector2(x + 8, at.y), note, 13, wear_colour(float(wear[worst])) if left < 5.0 else DIM, HORIZONTAL_ALIGNMENT_LEFT, at.x + w - x - 8)


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
