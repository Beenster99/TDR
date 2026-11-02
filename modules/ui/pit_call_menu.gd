class_name PitCallMenu
extends Control
## The driver's quick pit call menu (single player): calling a stop (B, or
## D-pad left) opens it over the race, which waits while it's open. The
## driver picks the basics for the stop: the tyres to fit, which tyres to
## change, the front splitter and rear wing (when the race allows car
## setups and the car has adjustable wings), fuel and repairs, then confirms
## "Box this lap". The stop's time is worked out as they go.
##
## Up / down choose a line, left / right change it, A / Enter (or the box
## button again) confirms, B / Esc closes without calling the stop. With a
## mouse: click a line's arrows, or the buttons at the bottom.

signal confirmed(changes: Dictionary)
signal cancelled

const FUEL_STEPS := [-1.0, 0.0, 10.0, 20.0, 30.0, 50.0, 80.0]
const YELLOW := Color(1.0, 0.88, 0.35)
const W := 600.0
const ROW_H := 44.0

var sim: RaceSim
var car := -1
var font: Font
## Lines: {id, label, options: [[value, text]], value, help}
var rows: Array = []
var selected := 0
var _now := {}           ## the car's pit-adjustable setup now
var _rects: Array = []   ## per row (and the two buttons): screen rects for the mouse


func setup(p_sim: RaceSim) -> void:
	sim = p_sim
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	visible = false


## Opens the menu for car i, starting from its current pit plan.
func open(i: int) -> void:
	car = i
	_build_rows()
	selected = 0
	visible = true


func close() -> void:
	visible = false


## True when the menu has anything worth asking (the car can change
## something at a stop: always, as there are tyres).
static func wanted(sim: RaceSim) -> bool:
	return sim.pits.enabled


func _build_rows() -> void:
	var p: Dictionary = sim.entries[car].pit
	var plan: Dictionary = p["plan"]
	rows.clear()
	var tyres := []
	for ch in PitRules.TYRE_CHOICES:
		tyres.append([ch, _cap(RaceHud.tyre_plan_text(sim, car, ch)) if ch != PitRules.TYRE_AUTO \
			else "Auto: " + RaceHud.tyre_plan_text(sim, car, ch).trim_prefix("auto (").trim_suffix(")")])
	rows.append({"id": "tyre", "label": "Tyres", "options": tyres, "value": str(plan["tyre"]),
		"help": "Auto picks slicks, inters or wets for the weather when you stop."})
	var wheels := []
	for ch in PitRules.WHEEL_CHOICES:
		wheels.append([ch, _cap(RaceHud.wheels_text(ch))])
	rows.append({"id": "wheels", "label": "Change", "options": wheels, "value": str(plan.get("wheels", PitRules.WHEELS_ALL)),
		"help": "Fewer tyres is a quicker stop. A different compound always goes on all four."})
	_now = sim.pits.current_setup(car)
	var want: Dictionary = plan.get("setup", {})
	if sim.settings.tuning_enabled:
		for key in ["wing_front", "wing_rear"]:
			if not CarSetup.adjustable(sim.defs[car], key):
				continue
			var r := CarSetup.range_of(sim.defs[car], key)
			var opts := []
			var v := float(r[1])
			while v <= float(r[2]) + 1e-4:
				var txt := str(snappedf(v, 0.1)).trim_suffix(".0")
				if absf(v - float(_now[key])) < 1e-4:
					txt += "  (now)"
				opts.append([snappedf(v, 0.1), txt])
				v += float(r[3])
			var help := "More = more front grip in fast corners. Less = it pushes wide." if key == "wing_front" \
				else "More = more rear grip, lower top speed. Less = faster on the straights."
			rows.append({"id": key, "label": "Front splitter" if key == "wing_front" else "Rear wing", "options": opts,
				"value": snappedf(float(want.get(key, _now[key])), 0.1), "help": help + " +%.1f s a wing." % PitRules.WING_CHANGE_S})
	if sim.settings.fuel_enabled:
		var fuel := []
		for f in FUEL_STEPS:
			fuel.append([f, "To the end" if f < 0.0 else _cap(RaceHud.fuel_plan_text(f))])
		var fv := float(plan["fuel"])
		if not FUEL_STEPS.has(fv):
			fuel.append([fv, RaceHud.fuel_plan_text(fv)])
		rows.append({"id": "fuel", "label": "Fuel", "options": fuel, "value": fv,
			"help": "Fuel goes in while the tyres are changed (3 L a second)."})
	if sim.damage_level != CarDamage.Level.OFF:
		rows.append({"id": "repair", "label": "Repairs", "options": [[true, "Fix damage"], [false, "Leave it"]],
			"value": bool(plan["repair"]), "help": "Repairs come after the tyres and fuel."})
	rows.append({"id": "box", "label": "BOX THIS LAP", "options": [], "value": null, "help": ""})
	rows.append({"id": "cancel", "label": "Cancel", "options": [], "value": null, "help": ""})


static func _cap(t: String) -> String:
	return t.left(1).to_upper() + t.substr(1)


func _row(id: String) -> Dictionary:
	for r in rows:
		if r["id"] == id:
			return r
	return {}


## The pit plan changes the menu stands for now.
func changes() -> Dictionary:
	var out := {}
	var setup := {}
	for r in rows:
		match str(r["id"]):
			"tyre", "wheels", "fuel", "repair":
				out[r["id"]] = r["value"]
			"wing_front", "wing_rear":
				if absf(float(r["value"]) - float(_now[r["id"]])) > 1e-4:
					setup[r["id"]] = float(r["value"])
	if sim.settings.tuning_enabled:
		out["setup"] = setup  # {} clears an earlier wing change
	return out


## What the stop would do and how long it would take (PitRules.service_for).
func preview() -> Dictionary:
	var plan: Dictionary = (sim.entries[car].pit["plan"] as Dictionary).duplicate(true)
	var ch := changes()
	for k in ch:
		plan[k] = ch[k]
	plan.erase("wheel_tyres")
	return sim.pits.service_for(car, plan)


func step(row: int, dir: int) -> void:
	var r: Dictionary = rows[row]
	var opts: Array = r["options"]
	if opts.is_empty():
		return
	var k := 0
	for j in opts.size():
		if opts[j][0] == r["value"]:
			k = j
	# Numbers stop at the ends; choices go round.
	var numeric: bool = r["id"] in ["wing_front", "wing_rear", "fuel"]
	k = clampi(k + dir, 0, opts.size() - 1) if numeric else posmod(k + dir, opts.size())
	r["value"] = opts[k][0]
	_tick()


func confirm() -> void:
	var ch := changes()
	close()
	confirmed.emit(ch)


func cancel() -> void:
	close()
	cancelled.emit()


func _tick() -> void:
	var s := get_node_or_null("/root/Sound") if is_inside_tree() else null
	if s:
		s.call("ui", "ui_tick")


func _input(event: InputEvent) -> void:
	if not visible or not event.is_pressed():
		return
	var n := rows.size()
	if event.is_action_pressed("ui_cancel"):
		cancel()
	elif event.is_action_pressed("ui_up", true):
		selected = posmod(selected - 1, n)
		_tick()
	elif event.is_action_pressed("ui_down", true):
		selected = posmod(selected + 1, n)
		_tick()
	elif event.is_action_pressed("ui_left", true):
		step(selected, -1)
	elif event.is_action_pressed("ui_right", true):
		step(selected, 1)
	elif event.is_action_pressed("pit_box"):  # (after the arrows: on a pad it's D-pad left)
		confirm()
	elif event.is_action_pressed("ui_accept"):
		if rows[selected]["id"] == "cancel":
			cancel()
		else:
			confirm()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_click(event.position)
	else:
		return
	get_viewport().set_input_as_handled()


func _click(pos: Vector2) -> void:
	for k in mini(_rects.size(), rows.size()):
		var r: Rect2 = _rects[k]
		if not r.has_point(pos):
			continue
		selected = k
		match str(rows[k]["id"]):
			"box": confirm()
			"cancel": cancel()
			_:
				step(k, -1 if pos.x < r.position.x + r.size.x * 0.62 else 1)
		return


func _process(_delta: float) -> void:
	if visible:
		size = get_viewport_rect().size
		queue_redraw()


func _draw() -> void:
	if car < 0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	var opts_rows := rows.filter(func(r): return not (r["options"] as Array).is_empty())
	var h := 70.0 + opts_rows.size() * ROW_H + 64.0 + 56.0 + 40.0
	var r := Rect2((size.x - W) * 0.5, (size.y - h) * 0.5, W, h)
	draw_rect(r, Color(0.02, 0.04, 0.07, 0.95))
	draw_rect(r, Color(1, 0.88, 0.35, 0.55), false, 2.0)
	draw_string(font, r.position + Vector2(20, 38), "PIT STOP", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, YELLOW)
	draw_string(font, Vector2(r.end.x - 220, r.position.y + 38), "race paused", HORIZONTAL_ALIGNMENT_RIGHT, 200, 13, Color(1, 1, 1, 0.45))
	_rects.clear()
	var y := r.position.y + 58.0
	var vx := r.position.x + 230.0
	for k in rows.size():
		var row: Dictionary = rows[k]
		if (row["options"] as Array).is_empty():
			continue
		var rr := Rect2(r.position.x + 12, y, W - 24, ROW_H - 6)
		_rects.append(rr)
		var sel := k == selected
		if sel:
			draw_rect(rr, Color(1, 0.88, 0.35, 0.16))
			draw_rect(rr, Color(1, 0.88, 0.35, 0.7), false, 1.5)
		draw_string(font, Vector2(rr.position.x + 12, y + 26), row["label"], HORIZONTAL_ALIGNMENT_LEFT, 200, 18, Color.WHITE)
		var txt := ""
		for o in row["options"]:
			if o[0] == row["value"]:
				txt = o[1]
		var accent := Color(0.94, 0.26, 0.2) if sel else Color(1, 1, 1, 0.35)
		draw_string(font, Vector2(vx, y + 26), "<", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, accent)
		draw_string(font, Vector2(vx + 26, y + 26), txt, HORIZONTAL_ALIGNMENT_LEFT, W - 300, 18, YELLOW if sel else Color(1, 1, 1, 0.9))
		draw_string(font, Vector2(rr.end.x - 26, y + 26), ">", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, accent)
		y += ROW_H
	# The selected line's help, and what the stop comes to.
	var help := str(rows[selected].get("help", ""))
	draw_string(font, Vector2(r.position.x + 20, y + 18), help, HORIZONTAL_ALIGNMENT_LEFT, W - 40, 13, Color(1, 1, 1, 0.55))
	var w := preview()
	var parts := []
	if str(w["tyre"]) != "":
		parts.append("%d tyre%s" % [(w["wheels"] as Array).size(), "s" if (w["wheels"] as Array).size() != 1 else ""])
	if float(w["fuel_l"]) > 0.0:
		parts.append("%d L fuel" % roundi(float(w["fuel_l"])))
	if not (w["setup"] as Dictionary).is_empty():
		parts.append("wings")
	if not (w["repair_parts"] as Array).is_empty():
		parts.append("repairs")
	var what := ", ".join(parts) if not parts.is_empty() else "nothing to do"
	draw_string(font, Vector2(r.position.x + 20, y + 44), "Stop about %.1f s  (%s)" % [float(w["total_s"]), what],
		HORIZONTAL_ALIGNMENT_LEFT, W - 40, 16, Color(0.6, 1, 0.6))
	y += 64.0
	# The two buttons.
	var bw := (W - 36) * 0.5
	for b in 2:
		var k := rows.size() - 2 + b
		var br := Rect2(r.position.x + 12 + b * (bw + 12), y, bw, 44)
		_rects.append(br)
		var sel := k == selected
		var col := Color(0.15, 0.5, 0.2, 0.9) if b == 0 else Color(0.3, 0.12, 0.1, 0.9)
		draw_rect(br, col if sel else col.darkened(0.45))
		if sel:
			draw_rect(br, Color(1, 1, 1, 0.8), false, 2.0)
		draw_string(font, Vector2(br.position.x, br.position.y + 29), rows[k]["label"], HORIZONTAL_ALIGNMENT_CENTER, bw, 18, Color.WHITE)
	draw_string(font, Vector2(r.position.x + 20, r.end.y - 14), "↑↓ choose   ←→ change   A / Enter box this lap   B / Esc cancel",
		HORIZONTAL_ALIGNMENT_LEFT, W - 40, 13, Color(1, 1, 1, 0.5))
