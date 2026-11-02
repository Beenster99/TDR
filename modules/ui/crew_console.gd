class_name CrewConsole
extends Control
## The pit wall for co-op players who are not driving: the pit crew and the
## strategist (with two players in a car they are one combined role). The 3D
## race stays on screen in the middle, zoomed out to the whole track with
## every car, and the console sits around it:
##   * left: timing tower (gaps, last lap, tyres, stops) with our car marked;
##   * right: the role's panel. PIT CREW calls the stop (box, tyres, fuel,
##     repairs, wing and tyre pressure changes) and watches the car (tyre
##     wear and temperatures, fuel, damage). STRATEGY reads the race: gaps
##     and pace against the cars around, the pit window and where a stop now
##     rejoins, rival strategies, weather;
##   * bottom: team radio with the driver, and race control;
##   * top right of the 3D view (strategist): a picture-in-picture onboard
##     camera on any car, front or rear (OnboardCamera), picked on the
##     strategy tab.
## A combined role switches tabs with Y / C. Radio calls to the driver open
## with X / V. The full-screen pit wall (StrategistScreen) opens from the
## strategy tab or with P.
##
## Mouse and keyboard first: click a row to act on it (right-click or the
## mouse wheel steps a value back and forth, or click its ◀ ▶), click the tabs,
## click a car in the timing to watch it, click the radio strip to call the
## driver. "Plan the stop" opens the PitPlanner: every job for the next stop
## queued on a plan view of the car, then sent to the driver. Keys: ↑ ↓ choose,
## ← → change, Enter acts, C switches tab, V radio, P full pit wall. A
## controller still works (D-pad, A, Y, X). Drawn immediate-mode in the 1600x900 canvas, scaled to the window, so it
## stays sharp at 4K.

signal open_pit_wall
signal open_planner
signal watch_changed(car: int)

const TAB_PIT := "pit_crew"
const TAB_STRATEGY := "strategist"
const LEFT_W := 430.0
const RIGHT_W := 480.0
const RADIO_H := 132.0
const YELLOW := Color(1.0, 0.88, 0.35)
const GREEN := Color(0.4, 1.0, 0.5)
const PURPLE := Color(0.78, 0.45, 1.0)
const RED := Color(1.0, 0.4, 0.35)
const BLUE := Color(0.55, 0.75, 1.0)
const DIM := Color(1, 1, 1, 0.55)
const PANEL := Color(0.02, 0.04, 0.07, 0.86)
const RADIO_LOG := 40
const CAM_OFF := "off"
const CAM_FRONT := "front"
const CAM_REAR := "rear"
const CAM_MODES := [CAM_FRONT, CAM_REAR, CAM_OFF]

var session: RaceSession
var font: Font
var tabs: Array[String] = []
var tab := 0
var selected := 0                    ## row in the current tab's list
var watch_car := -1                  ## rival the strategist is watching
var swap_pick := 0                   ## which crew mate a role swap is with
var radio: TeamRadio
var radio_log: Array = []            ## [{t, from, role, text}]
## (car index) -> screen position of that car, set by the race scene so the
## console can mark our car and the watched car on the 3D view.
var car_screen_pos: Callable
## A screen drawn over the console (the full pit wall): input goes there while it's open.
var cover: Control
## The pit stop planner (PitPlanner): input goes there while it's open.
var planner: Control
var _hits: Array = []                ## [Rect2, action, arg] from the last draw
var _hover := Vector2(-1, -1)
## The onboard camera for the picture-in-picture window (set by the race
## scene; null = no PiP, e.g. on a dedicated server).
var onboard: OnboardCamera
var cam_car := -1                    ## car the onboard camera is on
var cam_mode := CAM_FRONT
var _items: Array = []               ## rows of the current tab: [id, label, value text, can_change]


func setup(p_session: RaceSession) -> void:
	session = p_session
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	radio = TeamRadio.new()
	add_child(radio)
	radio.setup(session, team_car(), false)
	refresh_role()


## Our car: the one this player is in the crew of.
func team_car() -> int:
	if session == null:
		return -1
	if session.team_car >= 0:
		return session.team_car
	return session.local_car


func role() -> String:
	return str(session.local_role) if session else ""


## Call when the local role changes (RaceSession.role_changed).
func refresh_role() -> void:
	tabs.clear()
	var r := role()
	if RaceEntry.role_covers(r, RaceEntry.ROLE_PIT_CREW):
		tabs.append(TAB_PIT)
	if RaceEntry.role_covers(r, RaceEntry.ROLE_STRATEGIST):
		tabs.append(TAB_STRATEGY)
	if tabs.is_empty():
		tabs.append(TAB_STRATEGY)
	tab = clampi(tab, 0, tabs.size() - 1)
	selected = 0
	if radio:
		radio.car = team_car()
	if watch_car < 0 or watch_car == team_car():
		watch_car = _neighbour(-1)
	if cam_car < 0:
		cam_car = team_car()


## True when the onboard camera window is showing (strategist roles only).
func pip_on() -> bool:
	return onboard != null and session != null and cam_mode != CAM_OFF and cam_car >= 0 \
			and cam_car < session.sim.car_count() and RaceEntry.role_covers(role(), RaceEntry.ROLE_STRATEGIST)


## Where the onboard camera window sits: the top right of the 3D view.
func pip_rect() -> Rect2:
	var vr := view_rect()
	return Rect2(Vector2(vr.end.x - OnboardPip.SIZE.x - 10, vr.position.y + 10), OnboardPip.SIZE)


func current_tab() -> String:
	return tabs[tab]


static func role_title(r: String) -> String:
	match r:
		RaceEntry.ROLE_PIT_WALL: return "PIT CREW + STRATEGIST"
		RaceEntry.ROLE_PIT_CREW: return "PIT CREW"
		RaceEntry.ROLE_STRATEGIST: return "STRATEGIST"
		RaceEntry.ROLE_DRIVER: return "DRIVER"
	return r.to_upper()


## The part of the screen the 3D race shows through (between the panels).
func view_rect() -> Rect2:
	var vp := get_viewport_rect().size
	return Rect2(LEFT_W + 24, 58, maxf(vp.x - LEFT_W - RIGHT_W - 48, 200.0), maxf(vp.y - 58 - RADIO_H - 20, 200.0))


## A team radio message for our car (from the session's team_radio signal,
## which also brings back our own calls).
func add_radio(msg: Dictionary) -> void:
	radio_log.append({"t": session.sim.race_time if session else 0.0, "from": str(msg.get("from", "")),
		"role": str(msg.get("role", "")), "text": str(msg.get("text", ""))})
	while radio_log.size() > RADIO_LOG:
		radio_log.pop_front()


# --- Input -----------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not visible or radio.visible or (cover and cover.visible) or (planner and planner.visible):
		return
	if event is InputEventMouseMotion:
		_hover = event.position
		return
	if event is InputEventMouseButton:
		if event.pressed and _click(event.position, event.button_index):
			get_viewport().set_input_as_handled()
		return
	if not event.is_pressed():
		return
	if event.is_echo() and not (event.is_action("ui_up") or event.is_action("ui_down") \
			or event.is_action("ui_left") or event.is_action("ui_right")):
		return
	var handled := true
	if event.is_action_pressed("crew_tab"):
		tab = posmod(tab + 1, tabs.size())
		selected = 0
	elif event.is_action_pressed("team_radio") or (event is InputEventJoypadButton and event.button_index == JOY_BUTTON_X):
		radio.open()
	elif event.is_action_pressed("ui_up", true):
		selected = posmod(selected - 1, maxi(_items.size(), 1))
	elif event.is_action_pressed("ui_down", true):
		selected = posmod(selected + 1, maxi(_items.size(), 1))
	elif event.is_action_pressed("ui_left", true):
		_change(-1)
	elif event.is_action_pressed("ui_right", true):
		_change(1)
	elif event.is_action_pressed("ui_accept"):
		_activate()
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()


## A click on the console. Returns true if it hit something (else the click
## goes on to the 3D view: the wheel zooms there).
func _click(pos: Vector2, button: int) -> bool:
	var dir := 0
	match button:
		MOUSE_BUTTON_LEFT: dir = 1
		MOUSE_BUTTON_RIGHT: dir = -1
		MOUSE_BUTTON_WHEEL_UP: dir = 2
		MOUSE_BUTTON_WHEEL_DOWN: dir = -2
	if dir == 0:
		return false
	for k in range(_hits.size() - 1, -1, -1):
		var h: Array = _hits[k]
		if not (h[0] as Rect2).has_point(pos):
			continue
		var arg = h[2]
		match str(h[1]):
			"panel":
				return true
			"tab":
				if absi(dir) == 1:
					tab = int(arg)
					selected = 0
			"watch":
				if absi(dir) == 1 and int(arg) != team_car():
					watch_car = int(arg)
					watch_changed.emit(watch_car)
			"radio":
				if dir == 1:
					radio.open()
			"row":
				selected = int(arg)
				if absi(dir) == 2:
					_change(signi(dir))
				elif _items[selected][0] in ACTION_ROWS:
					if dir == 1:
						_activate()
				else:
					_change(dir)
			"step":
				selected = int(arg[0])
				_change(int(arg[1]))
		if absi(dir) == 1:
			Sound.ui("ui_select", -6.0)
		return true
	return false


## Rows that do something when clicked (the rest step a value).
const ACTION_ROWS := ["planner", "box", "repair", "radio", "pit_wall", "setup_reset", "swap"]


func _item_id() -> String:
	return _items[selected][0] if selected < _items.size() else ""


const FUEL_STEP := 5.0


func _change(dir: int) -> void:
	var car := team_car()
	if car < 0:
		return
	var sim := session.sim
	var id := _item_id()
	var plan: Dictionary = sim.entries[car].pit["plan"]
	match id:
		"box", "repair":
			_activate()
		"tyre":
			var ch := PitRules.TYRE_CHOICES
			session.request_pit(car, {"tyre": ch[posmod(ch.find(str(plan["tyre"])) + dir, ch.size())]})
		"wheels":
			var ch := PitRules.WHEEL_CHOICES
			var now := ch.find(str(plan.get("wheels", PitRules.WHEELS_ALL)))
			session.request_pit(car, {"wheels": ch[posmod(now + dir, ch.size())]})
		"fuel":
			var cap := sim.defs[car].fuel_capacity_l
			var f := float(plan["fuel"])
			var steps := [PitRules.FUEL_AUTO, PitRules.FUEL_NONE]
			var v := FUEL_STEP
			while v <= cap + 0.01:
				steps.append(v)
				v += FUEL_STEP
			var k := 0
			for n in steps.size():
				if absf(float(steps[n]) - f) < 0.01:
					k = n
			session.request_pit(car, {"fuel": steps[clampi(k + dir, 0, steps.size() - 1)]})
		"watch":
			watch_car = _cycle_car(watch_car, dir)
			watch_changed.emit(watch_car)
		"cam_car":
			cam_car = _cycle_any(cam_car, dir)
		"cam_view":
			cam_mode = CAM_MODES[posmod(CAM_MODES.find(cam_mode) + dir, CAM_MODES.size())]
		"swap":
			var mates := crew_mates()
			if not mates.is_empty():
				swap_pick = posmod(swap_pick + dir, mates.size())
		_:
			if id.begins_with("setup:"):
				var key := id.substr(6)
				var def := sim.defs[car]
				var r := CarSetup.range_of(def, key)
				var cur: float = _setup_target(car, key)
				session.request_pit(car, {"setup": {key: clampf(cur + dir * float(r[3]), float(r[1]), float(r[2]))}})


func _activate() -> void:
	var car := team_car()
	if car < 0:
		return
	var p: Dictionary = session.sim.entries[car].pit
	match _item_id():
		"planner":
			open_planner.emit()
		"box":
			var box: bool = not p["box"]
			session.request_pit(car, {"box": box})
			# Tell the driver too, so the call is never missed.
			var code := "box_now" if box else "stay_out"
			for c in TeamRadio.CREW_CALLS:
				if c[0] == code:
					var msg := TeamRadio.make_message(code, c[2], radio.my_name(), role())
					session.send_team_radio(car, msg)
		"repair":
			session.request_pit(car, {"repair": not bool(p["plan"]["repair"])})
		"setup_reset":
			session.request_pit(car, {"setup": {}})
		"radio":
			radio.open()
		"pit_wall":
			open_pit_wall.emit()
		"watch", "cam_car", "cam_view":
			_change(1)
		"swap":
			var pend: Dictionary = session.pending_swap(car)
			if not pend.is_empty():
				session.cancel_role_swap(car)
			else:
				var mates := crew_mates()
				if not mates.is_empty():
					session.request_role_swap(car, session.local_peer, int(mates[swap_pick % mates.size()]["peer_id"]))


## The other players in our car's crew.
func crew_mates() -> Array:
	var car := team_car()
	if car < 0:
		return []
	return session.sim.entries[car].crew.filter(func(m): return int(m.get("peer_id", 0)) != session.local_peer)


func _setup_target(car: int, key: String) -> float:
	var plan: Dictionary = session.sim.entries[car].pit["plan"]
	var want: Dictionary = plan.get("setup", {})
	if want.has(key):
		return float(want[key])
	return float(session.sim.pits.current_setup(car)[key])


## The car one place ahead (-1) or behind (+1) ours in the running order.
func _neighbour(dir: int) -> int:
	var order := session.sim.running_order
	var p := order.find(team_car())
	if p < 0 or order.size() < 2:
		return -1
	var q := p + dir
	if q < 0 or q >= order.size():
		q = p - dir
	return order[clampi(q, 0, order.size() - 1)]


## The next car in the running order, ours included.
func _cycle_any(car: int, dir: int) -> int:
	var order := session.sim.running_order
	if order.is_empty():
		return car
	var p := order.find(car)
	return order[posmod(p + dir, order.size())] if p >= 0 else order[0]


func _cycle_car(car: int, dir: int) -> int:
	var order := session.sim.running_order
	var p := order.find(car)
	for n in order.size():
		p = posmod(p + dir, order.size())
		if order[p] != team_car():
			return order[p]
	return car


# --- Rows ------------------------------------------------------------------------

func _build_items() -> void:
	_items.clear()
	var car := team_car()
	if car < 0:
		return
	var sim := session.sim
	var p: Dictionary = sim.entries[car].pit
	var plan: Dictionary = p["plan"]
	if sim.pits.enabled:
		_items.append(["planner", "Plan the stop", "tyres, pressures, downforce, driver: then Send", true])
	if current_tab() == TAB_PIT:
		if sim.pits.enabled:
			_items.append(["box", "Pit call", "BOX THIS LAP" if p["box"] else "Stay out", true])
			var per_wheel: Array = plan.get("wheel_tyres", [])
			if per_wheel.size() == 4:
				# A stop planned tyre by tyre (Plan the stop); changing Tyres here replaces it.
				var parts := PackedStringArray()
				for w in 4:
					var id := sim.pits.choice_compound(car, str(per_wheel[w]))
					parts.append("%s %s" % [PitPlanner.WHEEL_SHORT[w], sim.tyre_defs[id].display_name.left(5) if sim.tyre_defs.has(id) else "keep"])
				_items.append(["tyre", "Tyres (planned)", " · ".join(parts), true])
			else:
				_items.append(["tyre", "Tyres", RaceHud.tyre_plan_text(sim, car, str(plan["tyre"])), true])
			if str(plan["tyre"]) != PitRules.TYRE_KEEP and per_wheel.size() != 4:
				var work := sim.pits.service_for(car, plan)
				var which := RaceHud.wheels_text(str(plan.get("wheels", PitRules.WHEELS_ALL)))
				if (work.get("wheels", []) as Array).size() == 4 and str(plan.get("wheels", PitRules.WHEELS_ALL)) != PitRules.WHEELS_ALL:
					which += " (new compound: all four)"
				_items.append(["wheels", "Change", which, true])
			if sim.settings.fuel_enabled:
				_items.append(["fuel", "Fuel", RaceHud.fuel_plan_text(float(plan["fuel"])), true])
			if sim.damage_level != CarDamage.Level.OFF:
				_items.append(["repair", "Repairs", "Fix everything" if plan["repair"] else "No repairs", true])
			if sim.settings.tuning_enabled:
				var def := sim.defs[car]
				var now := sim.pits.current_setup(car)
				for key in PitRules.PIT_SETUP_KEYS:
					if not CarSetup.adjustable(def, key):
						continue
					var target := _setup_target(car, key)
					var txt := CarSetup.format_value(def, key, target)
					if absf(target - float(now[key])) > 1e-4:
						txt = "%s → %s" % [CarSetup.format_value(def, key, now[key]), txt]
					_items.append(["setup:" + key, _setup_label(key), txt, true])
				if plan.has("setup"):
					_items.append(["setup_reset", "Setup changes", "Cancel them", true])
	else:
		_items.append(["pit_wall", "Full pit wall", "radar, all timing (P)", true])
		_items.append(["watch", "Watch", sim.entries[watch_car].driver_name if watch_car >= 0 else "-", true])
		if onboard:
			var who := "-"
			if cam_car >= 0:
				who = "P%d %s%s" % [sim.entries[cam_car].position, sim.entries[cam_car].at_wheel(), " (us)" if cam_car == car else ""]
			_items.append(["cam_car", "Onboard camera", who, true])
			_items.append(["cam_view", "Camera view", {CAM_FRONT: "Front", CAM_REAR: "Rear", CAM_OFF: "Off"}[cam_mode], true])
	_items.append(["radio", "Radio the driver", "quick calls (V)", true])
	var mates := crew_mates()
	if not mates.is_empty():
		var pend: Dictionary = session.pending_swap(car)
		if not pend.is_empty():
			_items.append(["swap", "Role swap", "waiting for the stop: A to cancel", true])
		else:
			var m: Dictionary = mates[swap_pick % mates.size()]
			if m.get("ai", false):
				# The AI co-driver: take the wheel back, or hand it over.
				var what := "take the wheel from" if m.get("role", "") == RaceEntry.ROLE_DRIVER else "swap with"
				_items.append(["swap", "Driver change", "%s %s (AI) at the stop" % [what, m.get("name", "?")], true])
			else:
				_items.append(["swap", "Swap roles with", "%s (%s)" % [m.get("name", "?"), role_title(str(m.get("role", ""))).to_lower()], true])
	selected = clampi(selected, 0, maxi(_items.size() - 1, 0))


static func _setup_label(key: String) -> String:
	for it in CarSetup.ITEMS:
		if it[0] == key:
			return it[2]
	return key


# --- Drawing ---------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not visible or session == null:
		return
	size = get_viewport_rect().size
	_build_items()
	if pip_on() and not (cover and cover.visible):
		OnboardPip.feed(self, onboard, pip_rect(), cam_car, cam_mode == CAM_REAR)
	queue_redraw()


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


func _panel(r: Rect2, title := "") -> void:
	draw_rect(r, PANEL)
	draw_rect(r, Color(1, 1, 1, 0.1), false, 1.0)
	if title != "":
		_text(r.position + Vector2(12, 22), title, 13, DIM)


func _draw() -> void:
	_hits.clear()
	if session == null:
		return
	var vp := size
	var car := team_car()
	_draw_header(Rect2(12, 8, vp.x - 24, 42), car)
	_draw_timing(Rect2(12, 58, LEFT_W, vp.y - 58 - 12), car)
	var rx := vp.x - RIGHT_W - 12
	var rr := Rect2(rx, 58, RIGHT_W, vp.y - 58 - 12)
	_hits.append([rr, "panel", null])
	_hits.append([Rect2(12, 58, LEFT_W, vp.y - 70), "panel", null])
	if car >= 0:
		if current_tab() == TAB_PIT:
			_draw_pit_crew(rr, car)
		else:
			_draw_strategy(rr, car)
	var mid := Rect2(LEFT_W + 24, vp.y - RADIO_H - 12, rx - LEFT_W - 36, RADIO_H)
	_draw_radio(mid)
	_hits.append([mid, "radio", null])
	_draw_markers(car)
	if pip_on():
		OnboardPip.draw(self, font, onboard, pip_rect(), session, cam_car, cam_mode == CAM_REAR)
	_text(Vector2(LEFT_W + 24, mid.position.y - 10), "Click: act   Right-click / wheel: change   ↑↓ ←→ Enter   %sV radio   P pit wall" % (
		"C switch tab   " if tabs.size() > 1 else ""), 13, Color(1, 1, 1, 0.75))


func _draw_header(r: Rect2, car: int) -> void:
	draw_rect(r, PANEL)
	var sim := session.sim
	_text(r.position + Vector2(12, 29), "PIT WALL", 22, YELLOW)
	var tx := r.position.x + 120
	for k in tabs.size():
		var label := "PIT CREW" if tabs[k] == TAB_PIT else "STRATEGY"
		var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x + 24
		var tr := Rect2(tx, r.position.y + 7, w, 28)
		if k == tab:
			draw_rect(tr, Color(1, 0.88, 0.35, 0.22))
			draw_rect(tr, Color(1, 0.88, 0.35, 0.8), false, 1.5)
		elif tr.has_point(_hover):
			draw_rect(tr, Color(1, 1, 1, 0.3), false, 1.0)
		_hits.append([tr, "tab", k])
		_text(tr.position + Vector2(12, 20), label, 16, Color.WHITE if k == tab else DIM)
		tx += w + 8
	if car >= 0:
		var e := sim.entries[car]
		var lap := mini(e.laps_done + 1, sim.settings.laps)
		_text(Vector2(tx + 16, r.position.y + 28), "%s  ·  P%d %s  ·  %s  ·  Lap %d/%d" % [role_title(role()), e.position,
			e.at_wheel(), sim.defs[car].display_name, lap, sim.settings.laps], 16, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, r.end.x - tx - 300)
	var f := session.telemetry.forecast
	_text(Vector2(r.end.x - 290, r.position.y + 28), "%s  Air %d°  Track %d°  Wet %d%%" % [WeatherForecast.weather_label(f.weather),
		int(f.ambient_c), int(f.track_c), int(f.wetness * 100.0)], 15, BLUE, HORIZONTAL_ALIGNMENT_RIGHT, 280)


func _draw_timing(r: Rect2, car: int) -> void:
	_panel(r, "TIMING")
	var sim := session.sim
	var tel := session.telemetry
	var n := sim.running_order.size()
	var rh := clampf((r.size.y - 40) / maxf(n, 1), 18.0, 30.0)
	var fs := 15 if rh >= 24.0 else 13
	var x := r.position.x
	var hy := r.position.y + 40
	for h in [[8, "P"], [40, "DRIVER"], [196, "GAP"], [268, "LAST"], [350, "TYRE"], [404, "ST"]]:
		_text(Vector2(x + h[0], hy), h[1], 11, DIM)
	for p in n:
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var c := tel.cars[i]
		var y := r.position.y + 46 + p * rh
		var row := Rect2(x + 2, y, r.size.x - 4, rh - 2)
		if i == car:
			draw_rect(row, Color(1, 0.88, 0.35, 0.2))
			draw_rect(row, Color(1, 0.88, 0.35, 0.7), false, 1.5)
		elif i == watch_car:
			draw_rect(row, Color(0.55, 0.75, 1.0, 0.16))
		elif row.has_point(_hover):
			draw_rect(row, Color(1, 1, 1, 0.06))
		_hits.append([row, "watch", i])
		var ty := y + rh * 0.5 + fs * 0.35
		_text(Vector2(x + 8, ty), str(e.position), fs, Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, 22)
		draw_rect(Rect2(x + 34, y + 4, 4, rh - 10), sim.defs[i].colour)
		_text(Vector2(x + 42, ty), e.at_wheel(), fs, YELLOW if i == car else (BLUE if not e.is_ai else Color.WHITE),
			HORIZONTAL_ALIGNMENT_LEFT, 150)
		var gap := ""
		if e.finished:
			gap = "FIN"
		elif e.dnf:
			gap = "DNF"
		elif sim.in_pit_lane(i):
			gap = "PIT"
		elif p == 0:
			gap = "Leader"
		else:
			gap = ("+%d L" % c.laps_down) if c.laps_down >= 1 else "+" + StrategistScreen.fmt_gap(c.interval)
		_text(Vector2(x + 196, ty), gap, fs - 1, GREEN if gap == "PIT" else Color.WHITE)
		var last := c.last_lap()
		_text(Vector2(x + 268, ty), StrategistScreen.fmt_lap(last), fs - 1,
			PURPLE if last > 0.0 and last == tel.fastest_lap else Color(1, 1, 1, 0.85))
		var age := e.laps_done - int(e.pit.get("stint_lap", 0))
		_text(Vector2(x + 350, ty), "%s %d" % [sim.compounds[i].display_name.left(1), age], fs - 1, _compound_colour(sim.compounds[i].id))
		_text(Vector2(x + 404, ty), str(int(e.pit.get("stops", 0))), fs - 1, DIM)


static func _compound_colour(id: String) -> Color:
	if id.contains("wet"):
		return Color(0.4, 0.6, 1.0)
	if id.contains("inter"):
		return Color(0.45, 0.9, 0.45)
	return Color(1.0, 0.9, 0.75)


func _draw_rows(r: Rect2) -> float:
	var y := r.position.y
	for k in _items.size():
		var it: Array = _items[k]
		var row := Rect2(r.position.x, y, r.size.x, 30)
		var hover := row.has_point(_hover)
		if it[0] == "planner":
			draw_rect(row, Color(1, 0.88, 0.35, 0.3 if hover else 0.2))
		if k == selected:
			draw_rect(row, Color(1, 0.88, 0.35, 0.18))
			draw_rect(row, Color(1, 0.88, 0.35, 0.75), false, 1.5)
		elif hover:
			draw_rect(row, Color(1, 1, 1, 0.07))
			draw_rect(row, Color(1, 1, 1, 0.3), false, 1.0)
		_hits.append([row, "row", k])
		_text(Vector2(row.position.x + 10, y + 21), it[1], 15, YELLOW if it[0] == "planner" else DIM, HORIZONTAL_ALIGNMENT_LEFT, 170)
		var v: String = it[2]
		var col := Color.WHITE
		if it[0] == "box" and v.begins_with("BOX"):
			col = YELLOW
		var stepper: bool = it[3] and not it[0] in ACTION_ROWS
		if stepper and (k == selected or hover):
			# ◀ ▶ arrows to click.
			var la := Rect2(row.position.x + 176, y + 2, 22, 26)
			var ra := Rect2(row.end.x - 26, y + 2, 22, 26)
			_text(Vector2(la.position.x + 4, y + 21), "◀", 15, YELLOW if la.has_point(_hover) else Color.WHITE)
			_text(Vector2(ra.position.x + 4, y + 21), "▶", 15, YELLOW if ra.has_point(_hover) else Color.WHITE)
			_hits.append([la, "step", [k, -1]])
			_hits.append([ra, "step", [k, 1]])
			_text(Vector2(row.position.x + 202, y + 21), v, 15, col, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 236)
		else:
			_text(Vector2(row.position.x + 180, y + 21), v, 15, col, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 190)
		y += 32
	return y


func _draw_pit_crew(r: Rect2, car: int) -> void:
	_panel(r)
	var sim := session.sim
	var pits := sim.pits
	var e := sim.entries[car]
	var p: Dictionary = e.pit
	var c := sim.cars[car]
	var x := r.position.x + 12
	var w := r.size.x - 24
	# Where the car is in the stop.
	var head := "ON TRACK"
	var hc := Color(1, 1, 1, 0.8)
	match str(p["phase"]):
		PitRules.PHASE_APPROACH: head = "COMING IN THIS LAP"
		PitRules.PHASE_ENTRY, PitRules.PHASE_LIMIT: head = "IN THE PIT LANE"
		PitRules.PHASE_SERVICE: head = PitRules.service_text(p, "IN THE BOX")
		PitRules.PHASE_LEAVE, PitRules.PHASE_EXIT: head = "LEAVING THE PITS"
		_:
			if p["box"]:
				head = "BOX THIS LAP"
	if head != "ON TRACK":
		hc = YELLOW
	_text(Vector2(x, r.position.y + 28), head, 20, hc)
	var need := sim.settings.mandatory_pit_stops
	var stops := "Stops %d" % int(p["stops"])
	if need > 0 and sim.settings.laps >= 2:
		stops = "Stops %d/%d · window laps %d-%d" % [int(p["window_stops"]), need, pits.window_open, pits.window_close]
	_text(Vector2(x + w * 0.5, r.position.y + 28), stops, 14, GREEN if pits.mandatory_left(car) == 0 else Color.WHITE,
		HORIZONTAL_ALIGNMENT_RIGHT, w * 0.5)
	var y := _draw_rows(Rect2(r.position.x + 4, r.position.y + 40, r.size.x - 8, 0)) + 6
	# What the stop will do.
	if pits.enabled:
		var work := pits.service_for(car, p["plan"])
		draw_line(Vector2(x, y), Vector2(x + w, y), Color(1, 1, 1, 0.12))
		_text(Vector2(x, y + 22), "THE STOP", 12, DIM)
		_text(Vector2(x + 90, y + 22), "about %.1f s stationary, %.0f s lost in all" % [work["total_s"], pits.stop_loss(car, p["plan"])],
			15, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, w - 90)
		var parts := PackedStringArray()
		if work["tyre"] != "":
			var n := (work.get("wheels", [0, 1, 2, 3]) as Array).size()
			var kinds := {}
			for id in work.get("wheel_tyres", []):
				if str(id) != "":
					kinds[id] = true
			var tname: String = "Mixed" if kinds.size() > 1 else sim.tyre_defs[work["tyre"]].display_name
			parts.append("%s%s %.0f s" % [tname, " tyres" if n == 4 else " x%d" % n, work["tyre_s"]])
		if float(work["fuel_l"]) > 0.0:
			parts.append("%.0f L fuel %.0f s" % [work["fuel_l"], work["fuel_s"]])
		if not (work["setup"] as Dictionary).is_empty():
			parts.append("setup %.1f s" % work["setup_s"])
		if float(work["repair_s"]) > 0.0:
			parts.append("repairs %.0f s" % work["repair_s"])
		_text(Vector2(x + 90, y + 42), " · ".join(parts) if not parts.is_empty() else "nothing to do", 13, DIM, HORIZONTAL_ALIGNMENT_LEFT, w - 90)
		var pa: Dictionary = session.telemetry.cars[car].pit
		if not pa.is_empty():
			_text(Vector2(x + 90, y + 62), "Stop now: rejoin P%d%s" % [pa["rejoin_pos"], ", clear air" if pa["clear_air"] else ", in traffic"], 13,
				GREEN if pa["ideal"] else (Color(0.8, 1.0, 0.6) if pa["clear_air"] else Color(1, 0.75, 0.5)), HORIZONTAL_ALIGNMENT_LEFT, w - 90)
		y += 74
	# The car: tyres, fuel, damage.
	draw_line(Vector2(x, y), Vector2(x + w, y), Color(1, 1, 1, 0.12))
	_text(Vector2(x, y + 22), "THE CAR", 12, DIM)
	var tc := sim.compounds[car]
	var age := e.laps_done - int(p.get("stint_lap", 0))
	_text(Vector2(x + 90, y + 22), "%s, %d laps old" % [tc.display_name, age], 15, _compound_colour(tc.id))
	var ty := y + 34
	for t in 4:
		var tx := x + 90 + (t % 2) * 120
		var tyy := ty + (t / 2) * 44
		var wear := c.tyre_wear[t]
		draw_rect(Rect2(tx, tyy, 26, 38), _temp_colour(c.tyre_temp[t], tc))
		if c.puncture[t] > 0.5:
			draw_rect(Rect2(tx, tyy, 26, 38), RED, false, 3.0)
		_text(Vector2(tx + 32, tyy + 16), "%d°" % int(c.tyre_temp[t]), 14)
		_text(Vector2(tx + 32, tyy + 34), "%d%% left" % roundi((1.0 - wear) * 100.0), 13,
			RED if wear > 0.7 else (YELLOW if wear > 0.45 else DIM))
	var sx := x + 340
	if sim.settings.fuel_enabled:
		var laps_left := pits.fuel_laps(car)
		var to_go := pits.laps_after_this(car) + 1
		_text(Vector2(sx, ty + 16), "Fuel %.0f L" % c.fuel_l, 14)
		_text(Vector2(sx, ty + 34), "%.1f laps" % laps_left if laps_left < 999.0 else "-", 13,
			RED if laps_left < to_go else GREEN)
		_text(Vector2(sx, ty + 52), "%d to go" % to_go, 13, DIM)
	y = ty + 92
	if sim.damage_level != CarDamage.Level.OFF:
		var parts := {"Aero": c.damage_aero, "Suspension": maxf(c.damage_suspension, absf(c.alignment)),
			"Engine": c.damage_engine, "Gearbox": c.damage_gearbox}
		var bx := x + 90
		var bw := (w - 90) / 4.0
		var k := 0
		for name in parts:
			var v: float = parts[name]
			_text(Vector2(bx + k * bw, y + 14), name, 12, DIM)
			draw_rect(Rect2(bx + k * bw, y + 20, bw - 10, 8), Color(1, 1, 1, 0.12))
			draw_rect(Rect2(bx + k * bw, y + 20, (bw - 10) * clampf(v, 0.0, 1.0), 8),
				GREEN.lerp(RED, clampf(v * 2.0, 0.0, 1.0)))
			k += 1
		_text(Vector2(x, y + 26), "DAMAGE", 12, DIM)
	var last: Dictionary = p.get("last_stop", {})
	if not last.is_empty() and y + 56 < r.end.y:
		_text(Vector2(x, y + 56), "Last stop lap %d: %.1f s" % [int(last.get("lap", 0)), float(last.get("stationary_s", 0.0))], 13, DIM)


func _temp_colour(t: float, tc: TyreCompound) -> Color:
	var k := (t - tc.optimal_temp_c) / tc.temp_window_c
	if k < 0.0:
		return Color(0.3, 0.55, 1.0).lerp(Color(0.3, 0.9, 0.4), clampf(1.0 + k, 0.0, 1.0))
	return Color(0.3, 0.9, 0.4).lerp(Color(1.0, 0.3, 0.2), clampf(k, 0.0, 1.0))


func _draw_strategy(r: Rect2, car: int) -> void:
	_panel(r)
	var sim := session.sim
	var tel := session.telemetry
	var e := sim.entries[car]
	var c := tel.cars[car]
	var x := r.position.x + 12
	var w := r.size.x - 24
	_text(Vector2(x, r.position.y + 28), "P%d  %s" % [e.position, e.at_wheel()], 20, YELLOW, HORIZONTAL_ALIGNMENT_LEFT, w * 0.6)
	_text(Vector2(x + w * 0.6, r.position.y + 28), "Avg 5 %s" % StrategistScreen.fmt_lap(c.last5_avg), 14, Color.WHITE,
		HORIZONTAL_ALIGNMENT_RIGHT, w * 0.4)
	var y := r.position.y + 40
	# Battles: the cars just ahead and behind, pace against ours.
	var order := sim.running_order
	var p := order.find(car)
	var ahead := order[p - 1] if p > 0 else -1
	var behind := order[p + 1] if p >= 0 and p + 1 < order.size() else -1
	y = _battle_line(Vector2(x, y + 22), w, "AHEAD", ahead, car, c.interval)
	y = _battle_line(Vector2(x, y + 4), w, "BEHIND", behind, car, c.gap_behind)
	# Pit window.
	draw_line(Vector2(x, y + 6), Vector2(x + w, y + 6), Color(1, 1, 1, 0.12))
	y += 28
	var pits := sim.pits
	var pa := c.pit
	if not pits.enabled:
		_text(Vector2(x, y), "No pit lane on this track", 14, DIM)
	elif pa.is_empty():
		_text(Vector2(x, y), "Pit window: waiting for timing", 14, DIM)
	else:
		var status := "IDEAL: no places lost, clear air" if pa["ideal"] else ("clear air" if pa["clear_air"] else "into traffic")
		_text(Vector2(x, y), "Stop now: lose %.1f s, rejoin P%d, %s" % [pa["loss"], pa["rejoin_pos"], status], 15,
			GREEN if pa["ideal"] else (Color(0.8, 1.0, 0.6) if pa["clear_air"] else Color(1, 0.75, 0.5)), HORIZONTAL_ALIGNMENT_LEFT, w)
		y += 20
		var gb := "%.1f s" % c.gap_behind if c.gap_behind >= 0.0 else "nobody"
		_text(Vector2(x, y), "Gap behind %s, need %.1f s for a free stop" % [gb, pa["need"]], 13, DIM, HORIZONTAL_ALIGNMENT_LEFT, w)
	y += 20
	var need := sim.settings.mandatory_pit_stops
	if pits.enabled and need > 0 and sim.settings.laps >= 2:
		var left := pits.mandatory_left(car)
		var lap := pits.current_lap(car)
		var when := "window open" if pits.in_window(lap) else ("window opens lap %d" % pits.window_open if lap < pits.window_open else "window closed")
		_text(Vector2(x, y), "Mandatory stops left %d · %s (laps %d-%d)" % [left, when, pits.window_open, pits.window_close], 13,
			GREEN if left == 0 else (YELLOW if pits.in_window(lap) else Color.WHITE), HORIZONTAL_ALIGNMENT_LEFT, w)
		y += 20
	if sim.settings.fuel_enabled:
		var fl := pits.fuel_laps(car)
		var to_go := pits.laps_after_this(car) + 1
		_text(Vector2(x, y), "Fuel for %.1f laps, %d to go%s" % [fl, to_go, "  (must stop)" if fl < to_go else ""], 13,
			RED if fl < to_go else DIM, HORIZONTAL_ALIGNMENT_LEFT, w)
		y += 20
	# Weather.
	draw_line(Vector2(x, y), Vector2(x + w, y), Color(1, 1, 1, 0.12))
	y += 22
	var f := tel.forecast
	if f.changes.is_empty():
		_text(Vector2(x, y), "Weather: " + f.summary(), 14, BLUE, HORIZONTAL_ALIGNMENT_LEFT, w)
	else:
		var ch: Dictionary = f.changes[0]
		_text(Vector2(x, y), "Weather: %s %s (%d%% sure)" % [WeatherForecast.weather_label(ch["weather"]), WeatherForecast.eta_text(ch),
			int(ch["confidence"] * 100.0)], 14, BLUE if ch["rain"] > 0.05 else Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, w)
	y += 8
	# Rival strategies.
	draw_line(Vector2(x, y + 6), Vector2(x + w, y + 6), Color(1, 1, 1, 0.12))
	_text(Vector2(x, y + 26), "RIVALS", 12, DIM)
	y += 32
	var rivals: Array[int] = []
	for i in [watch_car, ahead, behind]:
		if i >= 0 and i != car and not rivals.has(i):
			rivals.append(i)
	for k in mini(order.size(), 3):
		if order[k] != car and not rivals.has(order[k]):
			rivals.append(order[k])
	for i in rivals:
		if y > r.end.y - 32.0 * _items.size() - 52:
			break
		var re := sim.entries[i]
		var rc := tel.cars[i]
		var age := re.laps_done - int(re.pit.get("stint_lap", 0))
		_text(Vector2(x, y + 16), "P%d %s" % [re.position, re.driver_name], 14, BLUE if i == watch_car else Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, w * 0.5)
		_text(Vector2(x + w * 0.5, y + 16), "%s %d laps · %d stops · avg %s" % [sim.compounds[i].display_name.left(5), age,
			int(re.pit.get("stops", 0)), StrategistScreen.fmt_lap(rc.last5_avg)], 13, DIM, HORIZONTAL_ALIGNMENT_LEFT, w * 0.5)
		var strat: Dictionary = tel.strategies.get(i, {})
		_text(Vector2(x + 10, y + 34), strat.get("text", "no calls heard") as String, 13, Color(1.0, 0.75, 0.4), HORIZONTAL_ALIGNMENT_LEFT, w - 10)
		y += 42
	_draw_rows(Rect2(r.position.x + 4, r.end.y - _items.size() * 32 - 6, r.size.x - 8, 0))


## One line comparing our pace with a rival's. Returns the next y.
func _battle_line(o: Vector2, w: float, label: String, other: int, car: int, gap: float) -> float:
	_text(o, label, 12, DIM)
	if other < 0:
		_text(o + Vector2(70, 0), "nobody", 15, DIM)
		return o.y + 22
	var tel := session.telemetry
	var mine := tel.cars[car].last5_avg
	var theirs := tel.cars[other].last5_avg
	_text(o + Vector2(70, 0), session.sim.entries[other].driver_name, 15, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, w * 0.4)
	_text(o + Vector2(70 + w * 0.4, 0), ("%.1f s" % gap) if gap >= 0.0 else "-", 15, YELLOW if gap >= 0.0 and gap < 1.0 else Color.WHITE)
	if mine > 0.0 and theirs > 0.0:
		var d := theirs - mine   # > 0: we are quicker
		var closing := d if label == "AHEAD" else -d
		var txt := "%s %.2f s/lap" % ["closing" if closing > 0.0 else "losing", absf(d)]
		if absf(d) < 0.05:
			txt = "same pace"
		_text(o + Vector2(160 + w * 0.4, 0), txt, 13, (GREEN if closing > 0.0 else RED) if absf(d) >= 0.05 else DIM,
			HORIZONTAL_ALIGNMENT_LEFT, w * 0.6 - 170)
	return o.y + 22


func _draw_radio(r: Rect2) -> void:
	_panel(r, "TEAM RADIO")
	var y := r.end.y - 10
	var w := r.size.x - 24
	var lines := 0
	for k in range(radio_log.size() - 1, -1, -1):
		if y < r.position.y + 44:
			break
		var m: Dictionary = radio_log[k]
		var who := "%s (%s)" % [m["from"], role_title(m["role"]).to_lower()] if m["from"] != "" else role_title(m["role"])
		var age := session.sim.race_time - float(m["t"])
		var a := clampf(1.0 - age / 90.0, 0.45, 1.0)
		_text(Vector2(r.position.x + 12, y), "%s: %s" % [who, m["text"]], 15,
			Color(YELLOW, a) if m["role"] != RaceEntry.ROLE_DRIVER else Color(0.6, 0.9, 1.0, a), HORIZONTAL_ALIGNMENT_LEFT, w)
		y -= 20
		lines += 1
	if lines == 0:
		_text(Vector2(r.position.x + 12, r.position.y + 50), "No calls yet. Click here or press V to radio the driver.", 14, DIM)
	# Race control: the latest call, top right of the strip.
	var rc := session.telemetry.feed.latest(1, ["race_control"])
	if not rc.is_empty():
		_text(Vector2(r.position.x + 120, r.position.y + 22), "RACE CONTROL: " + str(rc[0].get("text", "")), 13,
			Color(1.0, 0.85, 0.2), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 132)


## Rings round our car and the watched car on the 3D view.
func _draw_markers(car: int) -> void:
	if not car_screen_pos.is_valid():
		return
	var view := view_rect()
	for pair in [[car, YELLOW], [watch_car, BLUE]]:
		var i: int = pair[0]
		if i < 0:
			continue
		var sp = car_screen_pos.call(i)
		if not (sp is Vector2) or not view.grow(20).has_point(sp):
			continue
		draw_arc(sp, 16.0, 0.0, TAU, 32, pair[1], 2.5)
		_text(sp + Vector2(20, -10), session.sim.entries[i].driver_name, 14, pair[1])
