class_name PitPlanner
extends Control
## The strategist's pit stop planner: a plan view of the car from above with
## each tyre, the front splitter and the rear wing on it. Everything the crew
## should do at the next stop is queued here first: the compound and cold
## pressure of each tyre on its own (mixing allowed), front and rear
## downforce, fuel, repairs, a driver change and the call to box. Nothing
## reaches the car until Send: then the plan goes to the car's pit crew
## (RaceSession.request_pit) and the driver hears it on the team radio, as
## text on screen and read out with radio crackle.
##
## Mouse and keyboard first. Click a tyre to pick it (Shift or Ctrl adds
## more), click the − / + buttons or roll the mouse wheel over a value,
## right-click steps back. Keys: 1-4 pick a tyre (FL FR RL RR, Shift adds),
## A all four, Q keep / W dry / E intermediate / R wet for the picked tyres,
## ↑ ↓ their pressure, Z X front downforce, C V rear downforce, F G fuel,
## B box this lap, D driver change, Enter sends, Backspace starts again from
## the car's plan, Esc closes. A controller works too: the D-pad and A.
##
## Opened over the co-op pit wall (CrewConsole) and the full pit wall
## (StrategistScreen). Drawn immediate-mode in the 1600x900 canvas.

signal closed
signal plan_sent(msg: Dictionary)

const YELLOW := Color(1.0, 0.88, 0.35)
const GREEN := Color(0.4, 1.0, 0.5)
const RED := Color(1.0, 0.4, 0.35)
const BLUE := Color(0.55, 0.75, 1.0)
const DIM := Color(1, 1, 1, 0.55)
const PANEL_BG := Color(0.03, 0.05, 0.08, 0.97)
const CARD := Color(1, 1, 1, 0.035)
const W := 1180.0
const H := 760.0
const WHEEL_NAMES := ["front left", "front right", "rear left", "rear right"]
const WHEEL_SHORT := ["FL", "FR", "RL", "RR"]
const PSI_STEP := 0.5
const FUEL_STEP := 1.0              ## litres per click (Shift / the ±10 buttons: 10)

var session: RaceSession
var car := -1
var font: Font
## What the stop will do, built up here until Send:
## tyres: [4] compound id to fit ("" = keep), psi: [4] cold pressure delta
## (vs each compound's own), wing_front / wing_rear, fuel (litres,
## PitRules.FUEL_AUTO / FUEL_NONE), repair, box, driver_change, driver_to (peer).
var draft: Dictionary = {}
var picked: Array[bool] = [true, true, true, true]
var sent_at := -1.0                  ## race time of the last send (-1 never)
var _sent_draft: Dictionary = {}
var _hits: Array = []                ## [Rect2, action, arg, steps (for wheel)]
var _hover := Vector2(-1, -1)
var _flash := ""
var _flash_t := 0.0


func setup(p_session: RaceSession) -> void:
	session = p_session
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	focus_mode = FOCUS_ALL
	visible = false


## Opens the planner for a car (our car), starting from its current pit plan.
func open_for(p_car: int) -> void:
	if session == null or p_car < 0 or p_car >= session.sim.car_count():
		return
	if car != p_car or draft.is_empty() or not dirty():
		car = p_car
		load_from_car()
	visible = true
	grab_focus()


func close() -> void:
	visible = false
	closed.emit()


# --- The draft --------------------------------------------------------------------

## The draft from the car's plan as the crew has it now.
func load_from_car() -> void:
	var sim := session.sim
	var p: Dictionary = sim.entries[car].pit
	var plan: Dictionary = p["plan"]
	var work := sim.pits.service_for(car, plan)
	var tyres: Array = (work.get("wheel_tyres", ["", "", "", ""]) as Array).duplicate()
	var psi: Array = plan.get("psi", sim.pits.wheel_psi(car))
	var setup: Dictionary = plan.get("setup", {})
	var now := sim.pits.current_setup(car)
	var pend := session.pending_swap(car)
	draft = {
		"tyres": tyres,
		"psi": psi.duplicate(),
		"wing_front": float(setup.get("wing_front", now["wing_front"])),
		"wing_rear": float(setup.get("wing_rear", now["wing_rear"])),
		"fuel": float(plan["fuel"]),
		"repair": bool(plan["repair"]),
		"box": true,
		"driver_change": not pend.is_empty() or bool(plan.get("driver_change", false)),
		"driver_to": int(pend.get("b", -1)) if not pend.is_empty() else -1,
	}
	if int(draft["driver_to"]) == -1 or not _driver_options().has(int(draft["driver_to"])):
		var opts := _driver_options()
		draft["driver_to"] = opts[0] if not opts.is_empty() else -1
	_sent_draft = {}


## True when the draft has changes that haven't been sent.
func dirty() -> bool:
	return str(draft) != str(_sent_draft)


## Compounds the crew can fit: this car's dry tyre, intermediates and wets.
func compound_options() -> Array:
	var sim := session.sim
	var out := []
	for id in [sim.dry_compound[car], PitRules.TYRE_INTER, PitRules.TYRE_WET]:
		if sim.tyre_defs.has(id) and not id in out:
			out.append(id)
	return out


## The compound on wheel w after the stop (the new one, or the one on now).
func compound_after(w: int) -> TyreCompound:
	var id := str(draft["tyres"][w])
	if id != "" and session.sim.tyre_defs.has(id):
		return session.sim.tyre_defs[id]
	return session.sim.wheel_compounds[car][w]


func set_tyre(w: int, id: String) -> void:
	(draft["tyres"] as Array)[w] = id


## Sets the picked tyres to a compound ("" = keep them).
func fit_picked(id: String) -> void:
	for w in 4:
		if picked[w]:
			set_tyre(w, id)


func cycle_tyre(w: int, dir: int) -> void:
	var opts := [""] + compound_options()
	var k := opts.find(str(draft["tyres"][w]))
	set_tyre(w, opts[posmod(k + dir, opts.size())])


func can_tune() -> bool:
	return session.sim.settings.tuning_enabled


func change_psi(w: int, steps: int) -> void:
	if not can_tune():
		return
	var r := CarSetup.range_of(session.sim.defs[car], "pressure_front")
	var v := float(draft["psi"][w]) + steps * PSI_STEP
	(draft["psi"] as Array)[w] = clampf(snappedf(v, 0.1), float(r[1]), float(r[2]))


func psi_picked(steps: int) -> void:
	for w in 4:
		if picked[w]:
			change_psi(w, steps)


func can_wing(key: String) -> bool:
	return can_tune() and CarSetup.adjustable(session.sim.defs[car], key)


func change_wing(key: String, steps: int) -> void:
	if not can_wing(key):
		return
	var r := CarSetup.range_of(session.sim.defs[car], key)
	draft[key] = clampf(float(draft[key]) + steps * float(r[3]), float(r[1]), float(r[2]))


func change_fuel(steps: int) -> void:
	var sim := session.sim
	if not sim.settings.fuel_enabled:
		return
	var cap := floorf(sim.defs[car].fuel_capacity_l)
	var f := float(draft["fuel"])
	if f < 0.0:
		# From "to the end": step from the litres that would go in.
		f = roundf(RaceHud.fuel_added_l(sim, car, f))
	draft["fuel"] = clampf(snappedf(f + steps * FUEL_STEP, FUEL_STEP), 0.0, cap)


## Players (and the AI co-driver) who could take over the car: everyone in
## the crew but the driver at the wheel now.
func _driver_options() -> Array:
	var e := session.sim.entries[car]
	var at_wheel := e.driver_peer()
	var out := []
	for m in e.crew:
		var pid := int(m.get("peer_id", 0))
		if pid != at_wheel:
			out.append(pid)
	return out


func can_change_driver() -> bool:
	return session.sim.entries[car].has_peer(session.sim.entries[car].driver_peer()) and not _driver_options().is_empty()


func cycle_driver(dir: int) -> void:
	var opts := _driver_options()
	if opts.is_empty():
		return
	var k := opts.find(int(draft["driver_to"]))
	draft["driver_to"] = opts[posmod(k + dir, opts.size())]


func _crew_name(pid: int) -> String:
	for m in session.sim.entries[car].crew:
		if int(m.get("peer_id", 0)) == pid:
			return str(m.get("name", "?"))
	return "?"


## The pit plan the draft makes (PitRules.set_plan changes).
func plan_changes() -> Dictionary:
	var ch := {"wheel_tyres": (draft["tyres"] as Array).duplicate(), "fuel": float(draft["fuel"]),
		"repair": bool(draft["repair"]), "box": bool(draft["box"])}
	if can_tune():
		ch["psi"] = (draft["psi"] as Array).duplicate()
		var setup := {}
		for key in ["wing_front", "wing_rear"]:
			if can_wing(key):
				setup[key] = float(draft[key])
		if not setup.is_empty():
			ch["setup"] = setup
	return ch


## What the stop would do with the draft (PitRules.service_for); a driver
## change keeps the car in the box for at least PitRules.DRIVER_CHANGE_S.
func work() -> Dictionary:
	var wk := session.sim.pits.service_for(car, draft_plan())
	if draft["driver_change"] and can_change_driver():
		wk["total_s"] = maxf(float(wk["total_s"]), PitRules.DRIVER_CHANGE_S)
	return wk


## The car's pit plan as it would be after Send.
func draft_plan() -> Dictionary:
	var plan: Dictionary = session.sim.entries[car].pit["plan"].duplicate(true)
	var ch := plan_changes()
	plan["wheel_tyres"] = ch["wheel_tyres"]
	plan["fuel"] = ch["fuel"]
	plan["repair"] = ch["repair"]
	if ch.has("psi"):
		plan["psi"] = ch["psi"]
	if ch.has("setup"):
		plan["setup"] = ch["setup"]
	return plan


## The radio lines the driver gets for the draft, one job per line.
func message_lines() -> PackedStringArray:
	var sim := session.sim
	var lines := PackedStringArray()
	lines.append("Box, box. Box this lap." if draft["box"] else "Plan for the next stop.")
	# Tyres, grouped by compound.
	var groups := {}
	for w in 4:
		var id := str(draft["tyres"][w])
		if id != "":
			if not groups.has(id):
				groups[id] = []
			groups[id].append(w)
	if groups.is_empty():
		lines.append("No tyres.")
	for id in groups:
		var ws: Array = groups[id]
		var name := (sim.tyre_defs[id] as TyreCompound).display_name.to_lower()
		var which := ""
		for k in PitRules.WHEEL_SETS:
			if PitRules.WHEEL_SETS[k] == ws:
				which = PitRules.WHEEL_LABELS[k]
		if which == "all four":
			lines.append("Four new %ss." % name)
		elif which != "":
			lines.append("New %ss, %s." % [name, which])
		else:
			var names := PackedStringArray()
			for w in ws:
				names.append(WHEEL_NAMES[w])
			lines.append("New %ss, %s." % [name, " and ".join(names)])
	# Pressures that change.
	if can_tune():
		var now := sim.pits.wheel_psi(car)
		var changed := PackedStringArray()
		for w in 4:
			if absf(float(draft["psi"][w]) - float(now[w])) > 0.05:
				changed.append("%s %.1f" % [WHEEL_NAMES[w], cold_psi(w)])
		if not changed.is_empty():
			lines.append("Pressures: %s psi." % ", ".join(changed))
		var cur := sim.pits.current_setup(car)
		for key in ["wing_front", "wing_rear"]:
			if can_wing(key):
				var d := float(draft[key]) - float(cur[key])
				if absf(d) > 1e-4:
					lines.append("%s downforce %s %d to %d." % ["Front" if key == "wing_front" else "Rear",
						"up" if d > 0.0 else "down", absi(roundi(d)), roundi(float(draft[key]))])
	if sim.settings.fuel_enabled:
		var f := float(draft["fuel"])
		lines.append("Fuel to the end." if f < 0.0 else ("No fuel." if f == 0.0 else "%d litres of fuel." % int(f)))
	if sim.damage_level != CarDamage.Level.OFF:
		var dmg := not CarDamage.repair_plan(sim.cars[car]).is_empty()
		if dmg:
			lines.append("We fix the damage." if draft["repair"] else "No repairs, we leave the damage.")
	if draft["driver_change"] and can_change_driver():
		lines.append("Driver change: %s takes over." % _crew_name(int(draft["driver_to"])))
	return lines


## Cold pressure (psi) wheel w will run after the stop.
func cold_psi(w: int) -> float:
	return compound_after(w).cold_psi + float(draft["psi"][w])


## Sends the draft: the plan to the pit crew, the driver change, and the
## radio message to the driver. Returns the radio message.
func send() -> Dictionary:
	if session == null or car < 0:
		return {}
	session.request_pit(car, plan_changes())
	# Driver change: a role swap that waits for the car in its box.
	var pend := session.pending_swap(car)
	var want: bool = draft["driver_change"] and can_change_driver()
	if want:
		var target := int(draft["driver_to"])
		if pend.is_empty() or int(pend.get("b", 0)) != target:
			session.request_role_swap(car, session.sim.entries[car].driver_peer(), target)
	elif not pend.is_empty():
		session.cancel_role_swap(car)
	var lines := message_lines()
	var msg := {"kind": "radio", "code": "pit_plan", "text": " ".join(lines), "lines": Array(lines),
		"from": _my_name(), "role": str(session.local_role)}
	# The driver hears it (not when the driver is planning their own stop).
	if session.local_car != car:
		session.send_team_radio(car, msg)
	sent_at = session.sim.race_time
	_sent_draft = draft.duplicate(true)
	_flash = "Sent to the driver" if session.local_car != car else "Plan set for your next stop"
	_flash_t = 3.0
	plan_sent.emit(msg)
	return msg


func _my_name() -> String:
	for m in session.sim.entries[car].crew:
		if int(m.get("peer_id", 0)) == session.local_peer:
			return str(m.get("name", "Pit wall"))
	return "Pit wall"


# --- Input ------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = event.position
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		var steps := 0
		match mb.button_index:
			MOUSE_BUTTON_LEFT: steps = 1
			MOUSE_BUTTON_RIGHT: steps = -1
			MOUSE_BUTTON_WHEEL_UP: steps = 2
			MOUSE_BUTTON_WHEEL_DOWN: steps = -2
		if steps != 0:
			click(mb.position, steps, mb.shift_pressed or mb.ctrl_pressed)
		accept_event()


## A click at pos (canvas units): steps 1 = left, -1 = right, ±2 = wheel.
func click(pos: Vector2, steps: int, add := false) -> bool:
	for k in range(_hits.size() - 1, -1, -1):
		var h: Array = _hits[k]
		if (h[0] as Rect2).has_point(pos):
			if h[1] == "none":
				return true
			if absi(steps) == 2 and not h[3]:
				return false
			_do(str(h[1]), h[2], signi(steps), add)
			Sound.ui("ui_tick" if absi(steps) == 2 else "ui_select", -4.0)
			return true
	return false


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.is_pressed():
		_key(event)
	elif event is InputEventJoypadButton and event.is_pressed():
		if event.is_action_pressed("ui_cancel"):
			close()
		elif event.is_action_pressed("ui_accept"):
			send()
		elif event.is_action_pressed("ui_up"):
			psi_picked(1)
		elif event.is_action_pressed("ui_down"):
			psi_picked(-1)
		elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
			var first := picked.find(true)
			cycle_tyre(maxi(first, 0), 1 if event.is_action_pressed("ui_right") else -1)
			for w in 4:
				if picked[w]:
					set_tyre(w, str(draft["tyres"][maxi(first, 0)]))
		else:
			return
		get_viewport().set_input_as_handled()


func _key(event: InputEventKey) -> void:
	if not visible or event.is_echo() and not event.keycode in [KEY_UP, KEY_DOWN]:
		get_viewport().set_input_as_handled()
		return
	var shift := event.shift_pressed or event.ctrl_pressed
	match event.keycode:
		KEY_ESCAPE: close()
		KEY_ENTER, KEY_KP_ENTER: send()
		KEY_BACKSPACE: load_from_car()
		KEY_1, KEY_2, KEY_3, KEY_4: _pick(int(event.keycode - KEY_1), shift)
		KEY_A: picked = [true, true, true, true]
		KEY_Q: fit_picked("")
		KEY_W: fit_picked(session.sim.dry_compound[car])
		KEY_E: fit_picked(PitRules.TYRE_INTER)
		KEY_R: fit_picked(PitRules.TYRE_WET)
		KEY_UP, KEY_EQUAL, KEY_KP_ADD: psi_picked(1)
		KEY_DOWN, KEY_MINUS, KEY_KP_SUBTRACT: psi_picked(-1)
		KEY_Z: change_wing("wing_front", -1)
		KEY_X: change_wing("wing_front", 1)
		KEY_C: change_wing("wing_rear", -1)
		KEY_V: change_wing("wing_rear", 1)
		KEY_F: change_fuel(-10 if shift else -1)
		KEY_G: change_fuel(10 if shift else 1)
		KEY_B: draft["box"] = not draft["box"]
		KEY_D: _do("driver", null, 1, false)
		KEY_H: draft["repair"] = not draft["repair"]
	get_viewport().set_input_as_handled()


func _pick(w: int, add: bool) -> void:
	if add:
		picked[w] = not picked[w]
	else:
		for k in 4:
			picked[k] = k == w


func _do(action: String, arg, dir: int, add: bool) -> void:
	match action:
		"close": close()
		"send": send()
		"reset": load_from_car()
		"pick": _pick(int(arg), add)
		"pick_set":
			var set: Array = PitRules.WHEEL_SETS.get(str(arg), [])
			for k in 4:
				picked[k] = k in set
		"tyre_cycle":
			cycle_tyre(int(arg), dir)
		"fit": fit_picked(str(arg))
		"psi": change_psi(int(arg[0]), _steps(int(arg[1]), dir))
		"psi_picked": psi_picked(int(arg) * dir)
		"wing": change_wing(str(arg[0]), _steps(int(arg[1]), dir))
		"fuel": change_fuel(_steps(int(arg), dir))
		"fuel_auto": draft["fuel"] = PitRules.FUEL_AUTO
		"fuel_none": draft["fuel"] = PitRules.FUEL_NONE
		"repair": draft["repair"] = not draft["repair"]
		"box": draft["box"] = not draft["box"]
		"driver":
			if can_change_driver():
				var opts := _driver_options()
				if not draft["driver_change"]:
					draft["driver_change"] = true
				elif opts.size() > 1 and opts.find(int(draft["driver_to"])) < opts.size() - 1:
					cycle_driver(1)
				else:
					draft["driver_change"] = false
					draft["driver_to"] = opts[0]


## A − / + button steps its way (backwards on a right-click); the value
## between them (arg 0) steps with the wheel.
static func _steps(arg: int, dir: int) -> int:
	return arg * dir if arg != 0 else dir


func _process(delta: float) -> void:
	if not visible:
		return
	size = get_viewport_rect().size
	_flash_t = maxf(_flash_t - delta, 0.0)
	if car >= 0 and session.sim.entries[car].finished:
		close()
	queue_redraw()


# --- Drawing ----------------------------------------------------------------------

func _text(pos: Vector2, s: String, fs := 15, col := Color.WHITE, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	if width <= 0.0 and align == HORIZONTAL_ALIGNMENT_RIGHT:
		# Right-aligned with no box: the text ends at pos.x.
		pos.x -= font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		align = HORIZONTAL_ALIGNMENT_LEFT
	if width > 0.0 and align == HORIZONTAL_ALIGNMENT_LEFT and font.get_string_size(s, align, -1, fs).x > width:
		while s.length() > 1 and font.get_string_size(s + "…", align, -1, fs).x > width:
			s = s.left(s.length() - 1)
		s += "…"
	draw_string(font, pos, s, align, width, fs, col)


func _hit(r: Rect2, action: String, arg = null, wheel := false) -> void:
	_hits.append([r, action, arg, wheel])


## A button: highlighted when hovered or on.
func _button(r: Rect2, label: String, action: String, arg = null, on := false, enabled := true, fs := 15,
		col := Color.WHITE) -> void:
	var hover := r.has_point(_hover) and enabled
	var bg := Color(1, 0.88, 0.35, 0.28) if on else Color(1, 1, 1, 0.1 if hover else 0.06)
	draw_rect(r, bg)
	draw_rect(r, Color(1, 0.88, 0.35, 0.85) if on else Color(1, 1, 1, 0.35 if hover else 0.16), false, 1.5 if on or hover else 1.0)
	_text(Vector2(r.position.x, r.position.y + r.size.y * 0.5 + fs * 0.36), label, fs,
		col if enabled else Color(1, 1, 1, 0.3), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	if enabled:
		_hit(r, action, arg)


## A value with − and + either side; the wheel over it steps it too.
func _stepper(o: Vector2, w: float, value: String, action: String, arg_minus, arg_plus, enabled := true,
		col := Color.WHITE, wheel_arg = null) -> void:
	var bw := 30.0
	_button(Rect2(o, Vector2(bw, 30)), "−", action, arg_minus, false, enabled, 18)
	_button(Rect2(o + Vector2(w - bw, 0), Vector2(bw, 30)), "+", action, arg_plus, false, enabled, 18)
	var mid := Rect2(o + Vector2(bw + 4, 0), Vector2(w - 2 * bw - 8, 30))
	draw_rect(mid, Color(0, 0, 0, 0.25))
	_text(Vector2(mid.position.x, mid.position.y + 21), value, 16, col if enabled else DIM, HORIZONTAL_ALIGNMENT_CENTER, mid.size.x)
	if enabled:
		_hit(mid, action, wheel_arg, true)


static func compound_colour(id: String) -> Color:
	if id.contains("wet"):
		return Color(0.35, 0.55, 1.0)
	if id.contains("inter"):
		return Color(0.35, 0.85, 0.4)
	return Color(0.92, 0.92, 0.92)


func _draw() -> void:
	_hits.clear()
	if session == null or car < 0 or draft.is_empty():
		return
	var vp := size
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, 0.45))
	var r := Rect2((vp - Vector2(W, H)) * 0.5, Vector2(W, H))
	_hit(r, "none")   # clicks on the panel don't fall through
	draw_rect(r, PANEL_BG)
	draw_rect(r, Color(1, 0.88, 0.35, 0.55), false, 2.0)
	var sim := session.sim
	var e := sim.entries[car]
	_text(r.position + Vector2(20, 36), "PIT STOP PLAN", 24, YELLOW)
	var lap := mini(e.laps_done + 1, sim.settings.laps)
	_text(r.position + Vector2(230, 35), "P%d  %s  ·  %s  ·  Lap %d/%d" % [e.position, e.at_wheel(),
		sim.defs[car].display_name, lap, sim.settings.laps], 17, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, W - 300)
	_button(Rect2(r.end.x - 52, r.position.y + 12, 36, 32), "✕", "close", null, false, true, 18)
	draw_line(r.position + Vector2(16, 54), Vector2(r.end.x - 16, r.position.y + 54), Color(1, 1, 1, 0.12))
	var left := Rect2(r.position + Vector2(16, 66), Vector2(640, H - 82))
	var right := Rect2(Vector2(left.end.x + 16, left.position.y), Vector2(r.end.x - left.end.x - 32, H - 82))
	_draw_car_plan(left)
	_draw_controls(right)


## A rounded card.
func _card(r: Rect2, bg: Color, border := Color(0, 0, 0, 0), radius := 6.0, width := 1.0) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(int(radius))
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(int(maxf(width, 1.0)))
	sb.anti_aliasing = true
	draw_style_box(sb, r)


## A compound badge: a dark disc with the compound's colour ring and letter
## (like the sidewall markings).
func _badge(c: Vector2, rad: float, tc: TyreCompound, dim := false) -> void:
	var col := compound_colour(tc.id)
	if dim:
		col = col.darkened(0.45)
	draw_circle(c, rad, Color(0.07, 0.07, 0.08))
	draw_arc(c, rad - 2.0, 0.0, TAU, 32, col, 3.0, true)
	_text(Vector2(c.x - rad, c.y + rad * 0.42), tc.display_name.left(1).to_upper(), int(rad * 1.05), col,
		HORIZONTAL_ALIGNMENT_CENTER, rad * 2.0)


## Aero numbers for a splitter / wing setting: {balance (front share), df, drag}
## relative to the car's default (CarSetup.apply's sums, ride height as now).
func aero(wf: float, wr: float) -> Dictionary:
	var sim := session.sim
	var base := sim.base_defs[car] if car < sim.base_defs.size() else sim.defs[car]
	var d := CarSetup.defaults(base)
	var s := CarSetup.complete(sim.defs[car], sim.defs[car].tuning)
	var bal0 := base.aero_balance_front
	var df_f := bal0 * (1.0 + CarSetup.WING_FRONT_DF * (wf - float(d["wing_front"])))
	var df_r := (1.0 - bal0) * (1.0 + CarSetup.WING_REAR_DF * (wr - float(d["wing_rear"])))
	var rake := (float(s["ride_rear"]) - float(s["ride_front"])) - (float(d["ride_rear"]) - float(d["ride_front"]))
	var drag := 1.0 + CarSetup.WING_FRONT_DRAG * (wf - float(d["wing_front"])) + CarSetup.WING_REAR_DRAG * (wr - float(d["wing_rear"]))
	return {"balance": clampf(df_f / maxf(df_f + df_r, 0.001) + CarSetup.RAKE_BALANCE * rake, 0.2, 0.7),
		"df": df_f + df_r, "drag": drag}


func _draw_car_plan(r: Rect2) -> void:
	_card(r, CARD, Color(1, 1, 1, 0.06), 8.0)
	var sim := session.sim
	_text(r.position + Vector2(14, 22), "CAR SETUP AT THE STOP", 13, YELLOW)
	_text(r.position + Vector2(r.size.x - 14, 22), "click a tyre to pick it, Shift-click for more", 12, DIM,
		HORIZONTAL_ALIGNMENT_RIGHT, -1)
	draw_line(r.position + Vector2(14, 30), Vector2(r.end.x - 14, r.position.y + 30), Color(1, 1, 1, 0.08))
	var now := sim.pits.current_setup(car)
	# Front splitter on top, rear wing and the aero balance at the bottom.
	_wing_card(Rect2(r.position.x + 10, r.position.y + 38, r.size.x - 20, 70), "wing_front", "FRONT SPLITTER", now)
	var bal_r := Rect2(r.position.x + 10, r.end.y - 40, r.size.x - 20, 30)
	_wing_card(Rect2(r.position.x + 10, bal_r.position.y - 78, r.size.x - 20, 70), "wing_rear", "REAR WING", now)
	_aero_strip(bal_r, now)
	var mid := Rect2(r.position.x, r.position.y + 116, r.size.x, bal_r.position.y - 78 - 8 - (r.position.y + 116))
	# The car from above, nose up.
	var c := mid.get_center()
	var L := minf(mid.size.y - 34, 380.0)
	var Wd := L * 0.36
	var top := c.y - L * 0.5
	_draw_car_body(c, L, Wd, top, now)
	# Tyres, and a card for each beside it.
	var tw := Wd * 0.3
	var th := L * 0.19
	var fy := top + L * 0.16
	var ry := top + L * 0.70
	var wpos := [Vector2(c.x - Wd * 0.5 - tw + 4, fy), Vector2(c.x + Wd * 0.5 - 4, fy),
		Vector2(c.x - Wd * 0.5 - tw + 4, ry), Vector2(c.x + Wd * 0.5 - 4, ry)]
	var card_w := 184.0
	var card_h := 150.0
	for w in 4:
		var tr := Rect2(wpos[w], Vector2(tw, th))
		var cx := r.position.x + 10 if w % 2 == 0 else r.end.x - 10 - card_w
		var cy := mid.position.y + 4 if w < 2 else mid.end.y - card_h - 4
		var cr := Rect2(cx, cy, card_w, card_h)
		# A leader line from the card to its tyre.
		var from := Vector2(cr.end.x if w % 2 == 0 else cr.position.x, tr.get_center().y)
		from.y = clampf(from.y, cr.position.y + 10, cr.end.y - 10)
		var to := Vector2(tr.position.x if w % 2 == 0 else tr.end.x, tr.get_center().y)
		draw_line(from, to, Color(1, 0.88, 0.35, 0.5) if picked[w] else Color(1, 1, 1, 0.15), 1.5 if picked[w] else 1.0)
		_tyre_card(cr, w)
		_draw_tyre(tr, w)


## The car's body from above in its colour: nose, arches, glasshouse,
## splitter and rear wing (yellow when the plan changes them).
func _draw_car_body(c: Vector2, L: float, Wd: float, top: float, now: Dictionary) -> void:
	var body := session.sim.defs[car].colour
	# Half-width along the car (0 nose .. 1 tail): arches front and rear.
	var prof := [[0.0, 0.55], [0.04, 0.80], [0.10, 0.95], [0.20, 1.0], [0.30, 0.96], [0.45, 0.92], [0.60, 0.94],
		[0.72, 1.0], [0.85, 0.99], [0.95, 0.93], [1.0, 0.82]]
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for p in prof:
		var y: float = top + float(p[0]) * L
		var hw: float = float(p[1]) * Wd * 0.5
		left.append(Vector2(c.x - hw, y))
		right.append(Vector2(c.x + hw, y))
	right.reverse()
	var pts := left + right
	draw_colored_polygon(pts, Color(0, 0, 0, 0.35))   # shadow
	var shade := PackedVector2Array()
	for q in pts:
		shade.append(q + Vector2(4, 5))
	draw_colored_polygon(shade, Color(0, 0, 0, 0.3))
	draw_colored_polygon(pts, body.darkened(0.25))
	var outline := pts.duplicate()
	outline.append(pts[0])
	draw_polyline(outline, body.lightened(0.35), 2.0, true)
	# Bonnet vents and centre line.
	draw_line(Vector2(c.x, top + L * 0.05), Vector2(c.x, top + L * 0.30), Color(body.lightened(0.2), 0.5), 1.5)
	for k in 2:
		var sx := -1.0 if k == 0 else 1.0
		_card(Rect2(c.x + sx * Wd * 0.2 - Wd * 0.06, top + L * 0.2, Wd * 0.12, L * 0.035), Color(0, 0, 0, 0.22), Color(0, 0, 0, 0), 3.0)
	# Glasshouse: windscreen, roof, rear window.
	var g0 := top + L * 0.34
	var g1 := top + L * 0.43
	var g2 := top + L * 0.63
	var g3 := top + L * 0.71
	var ws := PackedVector2Array([Vector2(c.x - Wd * 0.30, g0), Vector2(c.x + Wd * 0.30, g0),
		Vector2(c.x + Wd * 0.36, g1), Vector2(c.x - Wd * 0.36, g1)])
	draw_colored_polygon(ws, Color(0.12, 0.18, 0.24))
	draw_rect(Rect2(c.x - Wd * 0.36, g1, Wd * 0.72, g2 - g1), body.darkened(0.45))
	var rw := PackedVector2Array([Vector2(c.x - Wd * 0.36, g2), Vector2(c.x + Wd * 0.36, g2),
		Vector2(c.x + Wd * 0.28, g3), Vector2(c.x - Wd * 0.28, g3)])
	draw_colored_polygon(rw, Color(0.12, 0.18, 0.24))
	# Roof number disc.
	draw_circle(Vector2(c.x, (g1 + g2) * 0.5), Wd * 0.17, Color(1, 1, 1, 0.9))
	_text(Vector2(c.x - Wd * 0.17, (g1 + g2) * 0.5 + 6), str(session.sim.entries[car].position), 16, Color(0.1, 0.1, 0.1),
		HORIZONTAL_ALIGNMENT_CENTER, Wd * 0.34)
	# Splitter and rear wing (with end plates).
	var sp := Rect2(c.x - Wd * 0.52, top - 9, Wd * 1.04, 7)
	var wg := Rect2(c.x - Wd * 0.56, top + L + 4, Wd * 1.12, 12)
	for part in [[sp, "wing_front"], [wg, "wing_rear"]]:
		var key: String = part[1]
		var changed := absf(float(draft[key]) - float(now[key])) > 1e-4
		var pr: Rect2 = part[0]
		_card(pr, YELLOW if changed else Color(0.16, 0.18, 0.2), Color(1, 1, 1, 0.35), 2.0)
	for sx in [-1.0, 1.0]:
		draw_rect(Rect2(c.x + sx * Wd * 0.56 - (4.0 if sx > 0 else 0.0), top + L - 2, 4, 20), Color(0.1, 0.1, 0.12))
		draw_line(Vector2(c.x + sx * Wd * 0.2, top + L - 6), Vector2(c.x + sx * Wd * 0.2, top + L + 4), Color(0.1, 0.1, 0.12), 3.0)


## A splitter or wing: a segmented scale from least to most downforce, the
## setting now (white tick) and the planned one (filled, yellow when it
## changes), − / + either side; the wheel over the scale steps it.
func _wing_card(r: Rect2, key: String, title: String, now: Dictionary) -> void:
	var def := session.sim.defs[car]
	_card(r, Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.08), 6.0)
	var x := r.position.x + 12
	_text(Vector2(x, r.position.y + 20), title, 13, Color(1, 1, 1, 0.85))
	var hint := "more = front bites in fast corners" if key == "wing_front" else "more = rear grip in fast corners, less top speed"
	_text(Vector2(r.end.x - 12, r.position.y + 20), hint, 12, DIM, HORIZONTAL_ALIGNMENT_RIGHT, -1)
	if not CarSetup.adjustable(def, key):
		_text(Vector2(x, r.position.y + 50), "Fixed on this car", 15, DIM)
		return
	var rng := CarSetup.range_of(def, key)
	var lo := float(rng[1])
	var hi := float(rng[2])
	var stp := maxf(float(rng[3]), 0.001)
	var cur := float(now[key])
	var v := float(draft[key]) if can_tune() else cur
	var changed := absf(v - cur) > 1e-4
	var y := r.position.y + 30
	var bw := 30.0
	var val_w := 120.0
	var gx := x + bw + 8
	var gw := r.size.x - 24 - 2 * bw - 16 - val_w - 8
	var n := int(round((hi - lo) / stp)) + 1
	var seg := gw / n
	for k in n:
		var sv := lo + k * stp
		var sr := Rect2(gx + k * seg + 1, y + 6, seg - 2, 18)
		var on := sv <= v + 1e-4
		var col := Color(1, 1, 1, 0.1)
		if on:
			col = YELLOW if changed else Color(0.85, 0.9, 1.0, 0.8)
			col.a = 0.45 + 0.55 * float(k + 1) / n
		_card(sr, col, Color(0, 0, 0, 0), 2.0)
		if absf(sv - cur) < 1e-4:
			# Where it is now: a tick under the segment.
			var tx := sr.get_center().x
			draw_colored_polygon(PackedVector2Array([Vector2(tx, y + 26), Vector2(tx - 5, y + 33), Vector2(tx + 5, y + 33)]), Color.WHITE)
	_text(Vector2(gx, y + 42), "less", 11, Color(1, 1, 1, 0.35))
	_text(Vector2(gx + gw, y + 42), "more", 11, Color(1, 1, 1, 0.35), HORIZONTAL_ALIGNMENT_RIGHT, -1)
	var enabled := can_tune()
	_button(Rect2(x, y + 1, bw, 28), "−", "wing", [key, -1], false, enabled, 18)
	_button(Rect2(gx + gw + 8, y + 1, bw, 28), "+", "wing", [key, 1], false, enabled, 18)
	if enabled:
		_hit(Rect2(gx, y, gw, 30), "wing", [key, 0], true)
	var vx := gx + gw + 8 + bw + 8
	var txt := CarSetup.format_value(def, key, v)
	if changed:
		txt = "%s → %s" % [CarSetup.format_value(def, key, cur), txt]
	_text(Vector2(vx, y + 22), txt, 18, YELLOW if changed else Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, val_w)
	if changed:
		_text(Vector2(vx, y + 40), "%+d" % roundi((v - cur) / stp), 12, YELLOW, HORIZONTAL_ALIGNMENT_CENTER, val_w)
	elif not enabled:
		_text(Vector2(vx, y + 40), "setups fixed", 11, DIM, HORIZONTAL_ALIGNMENT_CENTER, val_w)


## The aero balance (front share of the downforce) now and after the stop,
## on a front-rear bar, with the change in downforce and drag.
func _aero_strip(r: Rect2, now: Dictionary) -> void:
	_card(r, Color(1, 1, 1, 0.03), Color(1, 1, 1, 0.06), 6.0)
	var a0 := aero(float(now["wing_front"]), float(now["wing_rear"]))
	var a1 := aero(float(draft["wing_front"]), float(draft["wing_rear"])) if can_tune() else a0
	var x := r.position.x + 12
	var cy := r.position.y + r.size.y * 0.5
	_text(Vector2(x, cy + 5), "AERO BALANCE", 12, DIM)
	var bx := x + 108
	var bw := 120.0
	draw_rect(Rect2(bx, cy - 3, bw, 6), Color(1, 1, 1, 0.12))
	_text(Vector2(bx - 4, cy + 5), "R", 11, DIM, HORIZONTAL_ALIGNMENT_RIGHT, -1)
	_text(Vector2(bx + bw + 4, cy + 5), "F", 11, DIM)
	# 30 % .. 60 % front across the bar.
	var px := func(b: float) -> float: return bx + clampf((b - 0.3) / 0.3, 0.0, 1.0) * bw
	var changed := absf(float(a1["balance"]) - float(a0["balance"])) > 0.0005
	draw_rect(Rect2(px.call(a0["balance"]) - 1.5, cy - 8, 3, 16), Color.WHITE)
	if changed:
		draw_circle(Vector2(px.call(a1["balance"]), cy), 6.0, YELLOW)
	var txt := "%.1f%% front" % (float(a0["balance"]) * 100.0)
	if changed:
		txt += "  →  %.1f%%" % (float(a1["balance"]) * 100.0)
	_text(Vector2(bx + bw + 22, cy + 5), txt, 14, YELLOW if changed else Color.WHITE)
	if changed or absf(float(a1["df"]) - float(a0["df"])) > 0.0005:
		var ddf := (float(a1["df"]) / float(a0["df"]) - 1.0) * 100.0
		var ddr := (float(a1["drag"]) / float(a0["drag"]) - 1.0) * 100.0
		_text(Vector2(r.end.x - 12, cy + 5), "downforce %+.0f%%  drag %+.0f%%" % [ddf, ddr], 12,
			Color(1, 1, 1, 0.75), HORIZONTAL_ALIGNMENT_RIGHT, -1)


func _draw_tyre(tr: Rect2, w: int) -> void:
	var sim := session.sim
	var id := str(draft["tyres"][w])
	var cur: TyreCompound = sim.wheel_compounds[car][w]
	var col := compound_colour(id if id != "" else cur.id)
	if id == "":
		col = col.darkened(0.5)
	if picked[w]:
		_card(tr.grow(5), Color(1, 0.88, 0.35, 0.15), YELLOW, 7.0, 2.0)
	elif tr.grow(5).has_point(_hover):
		_card(tr.grow(5), Color(0, 0, 0, 0), Color(1, 1, 1, 0.5), 7.0, 1.0)
	_card(tr, Color(0.06, 0.06, 0.07), Color(0, 0, 0, 0), 5.0)
	# Sidewall stripes in the compound's colour, tread between.
	draw_rect(Rect2(tr.position.x + 3, tr.position.y + 5, 3, tr.size.y - 10), col)
	draw_rect(Rect2(tr.end.x - 6, tr.position.y + 5, 3, tr.size.y - 10), col)
	for k in 6:
		var y := tr.position.y + 8 + k * (tr.size.y - 16) / 5.0
		draw_line(Vector2(tr.position.x + 8, y), Vector2(tr.end.x - 8, y), Color(1, 1, 1, 0.08), 2.0)
	if sim.cars[car].puncture[w] > 0.5:
		_card(tr, Color(0, 0, 0, 0), RED, 5.0, 3.0)
	_text(Vector2(tr.position.x, tr.position.y + tr.size.y * 0.5 + 5), WHEEL_SHORT[w], 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, tr.size.x)
	if id != "":
		# A "new" dot on the tyres the crew will change.
		draw_circle(Vector2(tr.get_center().x, tr.position.y - 12 if w < 2 else tr.end.y + 12), 5.0, col)
	_hit(tr.grow(5), "pick", w)


func _tyre_card(r: Rect2, w: int) -> void:
	var sim := session.sim
	var c := sim.cars[car]
	var cur: TyreCompound = sim.wheel_compounds[car][w]
	var hover := r.has_point(_hover)
	_card(r, Color(1, 1, 1, 0.08 if picked[w] or hover else 0.045),
		Color(1, 0.88, 0.35, 0.6) if picked[w] else Color(1, 1, 1, 0.08), 6.0, 1.5 if picked[w] else 1.0)
	_hit(r, "pick", w)
	var x := r.position.x + 10
	var iw := r.size.x - 20
	_text(Vector2(x, r.position.y + 19), WHEEL_NAMES[w].to_upper(), 13, YELLOW if picked[w] else Color(1, 1, 1, 0.7))
	# Now: compound badge, wear left and temperature.
	var wear := c.tyre_wear[w]
	var left := 1.0 - wear
	var by := r.position.y + 40
	_badge(Vector2(x + 11, by), 11.0, cur)
	var bar := Rect2(x + 30, by - 3, iw - 30 - 46, 6)
	draw_rect(bar, Color(1, 1, 1, 0.12))
	var wcol := RED if wear > 0.7 else (YELLOW if wear > 0.45 else GREEN)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(left, 0.0, 1.0), bar.size.y)), wcol)
	_text(Vector2(bar.position.x, by + 16), "%d%% left" % roundi(left * 100.0), 11, Color(1, 1, 1, 0.6))
	var t := c.tyre_temp[w]
	var tk := (t - cur.optimal_temp_c) / cur.temp_window_c
	var tcol := Color(0.45, 0.65, 1.0) if tk < -0.5 else (Color(1, 0.45, 0.35) if tk > 0.5 else GREEN)
	_text(Vector2(r.end.x - 10, by + 5), "%d°" % int(t), 14, tcol, HORIZONTAL_ALIGNMENT_RIGHT, -1)
	if c.puncture[w] > 0.5:
		_text(Vector2(r.end.x - 10, by + 21), "PUNCTURE", 11, RED, HORIZONTAL_ALIGNMENT_RIGHT, -1)
	# The change: keep, or fit a new compound (click cycles, wheel too).
	var id := str(draft["tyres"][w])
	var br := Rect2(x, r.position.y + 64, iw, 30)
	var label := "Keep these  ▸" if id == "" else "New %s  ▸" % (sim.tyre_defs[id] as TyreCompound).display_name
	_button(br, label, "tyre_cycle", w, id != "", true, 14, compound_colour(id) if id != "" else Color(1, 1, 1, 0.8))
	_hit(br, "tyre_cycle", w, true)
	# Cold pressure.
	var now: float = sim.pits.wheel_psi(car)[w]
	var changed := absf(float(draft["psi"][w]) - now) > 0.05
	var ptxt := "%.1f psi" % cold_psi(w)
	if not can_tune():
		_text(Vector2(x, r.position.y + 122), ptxt + " cold  (setups fixed)", 14, DIM)
		return
	_stepper(Vector2(x, r.position.y + 102), iw, ptxt, "psi", [w, -1], [w, 1], true,
		YELLOW if changed else Color.WHITE, [w, 0])
	var d := float(draft["psi"][w])
	var note := "cold, standard" if absf(d) < 0.05 else "cold, %+.1f on standard" % d
	if changed:
		note = "cold, was %.1f" % (cur.cold_psi + now)
	_text(Vector2(x, r.position.y + 145), note, 11, YELLOW if changed else Color(1, 1, 1, 0.45), HORIZONTAL_ALIGNMENT_CENTER, iw)


func _section(o: Vector2, title: String) -> void:
	_text(o, title, 12, DIM)


func _draw_controls(r: Rect2) -> void:
	var sim := session.sim
	var x := r.position.x
	var w := r.size.x
	var y := r.position.y + 6
	# Picked tyres: which, compound, pressure.
	_section(Vector2(x, y + 12), "PICKED TYRES" + _shortcut("  (1-4, A all)"))
	y += 20
	var sets := [["all", "All"], ["front", "Fronts"], ["rear", "Rears"], ["left", "Left"], ["right", "Right"]]
	var bw := (w - 4 * 6) / 5.0
	for k in sets.size():
		var on := true
		var set: Array = PitRules.WHEEL_SETS[sets[k][0]]
		for q in 4:
			if picked[q] != (q in set):
				on = false
		_button(Rect2(x + k * (bw + 6), y, bw, 30), sets[k][1], "pick_set", sets[k][0], on)
	y += 40
	var opts := [""] + compound_options()
	var keys := ["Q", "W", "E", "R"] if not InputPrompt.pad else []
	bw = (w - (opts.size() - 1) * 6) / opts.size()
	for k in opts.size():
		var id: String = opts[k]
		var name := "Keep" if id == "" else (sim.tyre_defs[id] as TyreCompound).display_name
		var on := true
		for q in 4:
			if picked[q] and str(draft["tyres"][q]) != id:
				on = false
		_button(Rect2(x + k * (bw + 6), y, bw, 34), ("%s  %s" % [keys[k], name]) if k < keys.size() else name, "fit", id,
			on and picked.has(true), true, 14, compound_colour(id) if id != "" else Color.WHITE)
	y += 42
	if can_tune():
		_text(Vector2(x, y + 20), "Pressure" + InputPrompt.pick(" (↑ ↓)", " (D-pad ↑ ↓)"), 14, Color(1, 1, 1, 0.8))
		_button(Rect2(x + w - 220, y, 104, 30), "− 0.5 psi", "psi_picked", -1)
		_button(Rect2(x + w - 108, y, 104, 30), "+ 0.5 psi", "psi_picked", 1)
	else:
		_text(Vector2(x, y + 20), "Pressures and downforce are fixed: the host fixed car setups", 13, DIM)
	y += 44
	draw_line(Vector2(x, y), Vector2(x + w, y), Color(1, 1, 1, 0.12))
	y += 10
	# Fuel, repairs, driver change, the call.
	if sim.settings.fuel_enabled:
		var fv := float(draft["fuel"])
		_text(Vector2(x, y + 21), "Fuel" + _shortcut(" (F G)"), 15)
		var fx := x + 70
		_button(Rect2(fx, y, 40, 30), "−10", "fuel", -10, false, true, 13)
		_stepper(Vector2(fx + 44, y), 190, RaceHud.fuel_plan_text(fv) if fv >= 0.0 else "to the end", "fuel", -1, 1, true, Color.WHITE, 0)
		_button(Rect2(fx + 238, y, 40, 30), "+10", "fuel", 10, false, true, 13)
		_button(Rect2(fx + 284, y, 70, 30), "To end", "fuel_auto", null, fv < 0.0, true, 13)
		_button(Rect2(fx + 358, y, x + w - fx - 358, 30), "None", "fuel_none", null, fv == 0.0, true, 13)
		# What it does: litres in, laps they add, laps on board against laps to go.
		var fpl := sim.pits.fuel_per_lap(car)
		if fpl > 0.0:
			var add := RaceHud.fuel_added_l(sim, car, fv)
			var after := (sim.cars[car].fuel_l + add) / fpl
			var to_go := sim.pits.laps_after_this(car) + 1
			var short := after < to_go - 0.05
			var room := maxf(sim.defs[car].fuel_capacity_l - sim.cars[car].fuel_l, 0.0)
			var line := "%d L in = +%.1f laps   ·   %.1f laps in the tank after, %d to go" % [roundi(add), add / fpl, after, to_go]
			if fv > room + 0.5:
				line += "   (tank full at %d L)" % roundi(room)
			_text(Vector2(fx, y + 50), line, 13, RED if short else Color(0.75, 1.0, 0.8), HORIZONTAL_ALIGNMENT_LEFT, x + w - fx)
			y += 22
		y += 40
	if sim.damage_level != CarDamage.Level.OFF:
		var parts := CarDamage.repair_plan(sim.cars[car])
		_text(Vector2(x, y + 21), "Repairs" + _shortcut(" (H)"), 15)
		var dmg_txt := "nothing to fix" if parts.is_empty() else "%d parts" % parts.size()
		_button(Rect2(x + 110, y, 170, 30), "Fix everything" if draft["repair"] else "No repairs", "repair", null, draft["repair"])
		_text(Vector2(x + 292, y + 21), dmg_txt, 14, DIM if parts.is_empty() else RED)
		y += 40
	_text(Vector2(x, y + 21), "Driver" + _shortcut(" (D)"), 15)
	if can_change_driver():
		var label := "Change: %s takes over" % _crew_name(int(draft["driver_to"])) if draft["driver_change"] else "No driver change"
		_button(Rect2(x + 110, y, w - 110, 30), label, "driver", null, draft["driver_change"])
	else:
		_text(Vector2(x + 110, y + 21), "%s drives (no co-driver in this car)" % session.sim.entries[car].at_wheel(), 14, DIM, HORIZONTAL_ALIGNMENT_LEFT, w - 110)
	y += 40
	_text(Vector2(x, y + 21), "Call" + _shortcut(" (B)"), 15)
	_button(Rect2(x + 110, y, w - 110, 30), "BOX THIS LAP" if draft["box"] else "Plan only, box later", "box", null, draft["box"])
	y += 46
	draw_line(Vector2(x, y), Vector2(x + w, y), Color(1, 1, 1, 0.12))
	y += 8
	# The queue: everything the crew will do, and the time.
	var wk := work()
	_section(Vector2(x, y + 12), "WORK QUEUE")
	var lost := sim.pits.stop_loss(car, draft_plan()) - float(sim.pits.service_for(car, draft_plan())["total_s"]) + float(wk["total_s"])
	_text(Vector2(x, y + 12), "about %.1f s stationary, %.0f s lost in all" % [float(wk["total_s"]), lost],
		13, Color(1, 1, 1, 0.8), HORIZONTAL_ALIGNMENT_RIGHT, w)
	y += 18
	var lines := message_lines()
	var bottom := r.end.y - 92
	for k in range(1, lines.size()):
		if y + 20 > bottom:
			_text(Vector2(x + 8, y + 16), "…", 14, DIM)
			break
		_text(Vector2(x + 8, y + 16), "•  " + lines[k], 14, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, w - 16)
		y += 20
	# Send.
	var by := r.end.y - 84
	var status := ""
	var scol := DIM
	if _flash_t > 0.0:
		status = _flash
		scol = GREEN
	elif sent_at >= 0.0 and not dirty():
		status = "Sent %s ago, nothing changed since" % _ago(sim.race_time - sent_at)
		scol = GREEN
	elif sent_at >= 0.0:
		status = "Changed since the last send"
		scol = YELLOW
	else:
		status = "Not sent yet: the crew and the driver don't know this plan"
		scol = YELLOW
	_text(Vector2(x, by + 2), status, 13, scol, HORIZONTAL_ALIGNMENT_LEFT, w)
	_button(Rect2(x, by + 14, 120, 54), "Start again", "reset", null, false, true, 14)
	var to_driver := session.local_car != car
	_button(Rect2(x + 130, by + 14, w - 130, 54), ("SEND TO DRIVER" if to_driver else "SET MY STOP") + "  " + InputPrompt.pick("⏎", InputPrompt.key("ui_accept")), "send", null,
		dirty(), true, 20, YELLOW)
	_text(Vector2(x, r.end.y + 6), InputPrompt.pick("Wheel / right-click: change   Q W E R tyres   Z X / C V downforce   Esc close",
		InputPrompt.fill("D-pad ←→: tyre for the picked wheels   ↑↓: pressure   {ui_accept} send   {ui_cancel} close   (mouse for the rest)")),
		12, Color(1, 1, 1, 0.45), HORIZONTAL_ALIGNMENT_LEFT, w)


## A keyboard shortcut's hint, left out while the player is on a controller
## (the planner's letter keys are fixed keyboard shortcuts).
static func _shortcut(hint: String) -> String:
	return "" if InputPrompt.pad else hint


static func _ago(s: float) -> String:
	return "%d s" % int(s) if s < 90.0 else "%d min" % int(s / 60.0)
