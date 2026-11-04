class_name ResultsAnalysis
extends HBoxContainer
## The results screen's race analysis: how the positions changed lap by lap,
## the gaps to the leader through the race, and every driver's places won or
## lost and tyre strategy. You (blue) and the winner start picked out on the
## graphs; clicking a driver in the list adds or removes them (up to four),
## clicking a line opens that driver's race data.

signal car_opened(car: int)

## The graphs' colours, in the order they're handed out (validated
## categorical slots for a dark surface). A driver keeps theirs.
const SLOTS := [Color("#3987e5"), Color("#d95926"), Color("#199e70"), Color("#9085e9")]

var data: Dictionary = {}
var picked: Dictionary = {}         ## car -> slot
var _pos_graph: ResultsGraph
var _gap_graph: ResultsGraph
var _strategy: ResultsStrategy
var _legend: HBoxContainer


func setup(d: Dictionary) -> void:
	data = d
	add_theme_constant_override("separation", 16)
	size_flags_vertical = SIZE_EXPAND_FILL
	var rows: Array = d.get("rows", [])
	picked.clear()
	for r in rows:
		if r.get("is_me", false):
			picked[int(r["car"])] = 0
	for r in rows:
		if picked.size() < 2 and not picked.has(int(r["car"])):
			_pick(int(r["car"]))
	var left := VBoxContainer.new()
	left.size_flags_horizontal = SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.6
	left.add_theme_constant_override("separation", 10)
	add_child(left)
	_legend = HBoxContainer.new()
	_legend.add_theme_constant_override("separation", 18)
	left.add_child(_legend)
	_pos_graph = ResultsGraph.new()
	_pos_graph.invert_y = true
	_pos_graph.integer_y = true
	_pos_graph.y_step = 1.0 if rows.size() <= 12 else 2.0
	_pos_graph.y_format = "P%d"
	_pos_graph.value_text = func(v: float) -> String: return "P%d" % int(v)
	_pos_graph.car_clicked.connect(func(c): car_opened.emit(c))
	left.add_child(_card("POSITIONS LAP BY LAP", "Lap 0 is the grid. Rings mark pit stops. Click a line for that driver.", _pos_graph, 1.25))
	_gap_graph = ResultsGraph.new()
	_gap_graph.invert_y = true
	_gap_graph.y_format = "+%.0f s"
	_gap_graph.value_text = func(v: float) -> String: return "+%.1f s" % v if v > 0.05 else "leader"
	_gap_graph.car_clicked.connect(func(c): car_opened.emit(c))
	left.add_child(_card("GAP TO THE LEADER", "Seconds behind the leader as each lap ended; lapped cars run off the bottom.", _gap_graph, 1.0))
	_strategy = ResultsStrategy.new()
	_strategy.size_flags_vertical = SIZE_EXPAND_FILL
	_strategy.car_toggled.connect(_toggle)
	_strategy.car_opened.connect(func(c): car_opened.emit(c))
	var right := _card("PLACES AND TYRE STRATEGY", "Click a name to add it to the graphs", _strategy, 1.0)
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	add_child(right)
	_refresh()


## The list on the right, for focus from the buttons.
func focus_target() -> Control:
	return _strategy


func _pick(car: int) -> void:
	var used := picked.values()
	for s in SLOTS.size():
		if not s in used:
			picked[car] = s
			return


func _toggle(car: int) -> void:
	if picked.has(car):
		picked.erase(car)
	elif picked.size() < SLOTS.size():
		_pick(car)
	else:
		return
	_refresh()


func colors() -> Dictionary:
	var out := {}
	for c in picked:
		out[c] = SLOTS[picked[c]]
	return out


func _refresh() -> void:
	var cols := colors()
	var rows: Array = data.get("rows", [])
	var pos_series := []
	var gap_series := []
	var lead_max := 0.0
	for r in rows:
		var pts := []
		var gps := []
		var marks := []
		if int(r.get("grid", 0)) > 0:
			pts.append(Vector2(0, int(r["grid"])))
		for l in r.get("lap_log", []):
			pts.append(Vector2(int(l["lap"]), int(l["pos"])))
			gps.append(Vector2(int(l["lap"]), float(l["gap"])))
			if l.get("pitted", false):
				marks.append(int(l["lap"]))
		pos_series.append({"car": r["car"], "name": r["name"], "points": pts, "marks": marks})
		gap_series.append({"car": r["car"], "name": r["name"], "points": gps, "marks": marks})
		# Scale the gaps to the cars that finished on the lead lap.
		if str(r.get("status", "")) == "" and not str(r.get("gap", "")).contains("lap") and not gps.is_empty():
			for p in gps:
				lead_max = maxf(lead_max, p.y)
	_pos_graph.set_data(pos_series, cols, [1, maxi(rows.size(), 2)])
	_gap_graph.set_data(gap_series, cols, [0.0, maxf(lead_max * 1.08, 5.0)])
	_strategy.set_data(rows, int(data.get("max_laps", data.get("laps", 1))), data.get("compounds", {}), cols)
	for c in _legend.get_children():
		c.queue_free()
	var hint := Label.new()
	hint.text = "ON THE GRAPHS"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_legend.add_child(hint)
	for r in rows:
		if cols.has(r["car"]):
			var chip := HBoxContainer.new()
			chip.add_theme_constant_override("separation", 6)
			var sw := ColorRect.new()
			sw.color = cols[r["car"]]
			sw.custom_minimum_size = Vector2(14, 4)
			sw.size_flags_vertical = SIZE_SHRINK_CENTER
			chip.add_child(sw)
			var l := Label.new()
			l.text = "P%d %s%s" % [int(r["pos"]), r["name"], "  (you)" if r.get("is_me", false) else ""] if str(r["status"]) == "" \
				else "%s %s" % [r["status"], r["name"]]
			l.add_theme_font_size_override("font_size", 14)
			chip.add_child(l)
			_legend.add_child(chip)
	var grey := Label.new()
	grey.text = "everyone else in grey"
	grey.add_theme_font_size_override("font_size", 12)
	grey.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	_legend.add_child(grey)


func _card(title: String, note: String, body: Control, ratio: float) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.075, 0.09, 0.95)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_vertical = SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = ratio
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	p.add_child(v)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	v.add_child(h)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 15)
	t.add_theme_color_override("font_color", RaceResults.ACCENT)
	h.add_child(t)
	var n := Label.new()
	n.text = note
	n.add_theme_font_size_override("font_size", 12)
	n.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	n.size_flags_horizontal = SIZE_EXPAND_FILL
	n.clip_text = true
	n.size_flags_vertical = SIZE_SHRINK_END
	h.add_child(n)
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.size_flags_horizontal = SIZE_EXPAND_FILL
	body.custom_minimum_size.y = maxf(body.custom_minimum_size.y, 120)
	v.add_child(body)
	return p
