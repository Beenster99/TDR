class_name RaceResults
extends Control
## The results screen at the end of a race. It fades in over the race once
## this player's car has been home for a while (or once the race ends) and,
## while the rest of the field is still racing, fills up as each car crosses
## the line (live: update_results()); the cars still out are dimmed rows
## at the bottom.
##
## A table of the whole field (position, driver, car, laps, race time and
## gap, best lap and the lap it came on, average lap, best sector times,
## best potential lap from the driver's best sectors, pit stops, penalties,
## points), the fastest lap and the field's best sectors, every penalty with
## its reason, and, in a championship, the standings after this race.
## The player's own row is gold, the fastest lap and each sector's best time
## in the field are purple.
##
## Click a driver's row (or A on it) for their whole race (ResultsDriver:
## every lap's position, time, sectors, gap, tyre and fuel, a lap time graph,
## stints and stops). Race analysis (ResultsAnalysis) shows how the
## positions changed lap by lap, the gaps to the leader, places won and lost
## and everyone's tyre strategy. Esc / B goes back.
##
## Mouse: scroll the table with the wheel, click a row or a button.
## Controller and keys: up / down (stick, D-pad, arrows) move through the
## rows, A / Enter opens one, left / right pick a button.
##
## The race scene builds the data (ResultsTable.build) and the buttons, and
## listens for `chosen`.

signal chosen(id: String)

const ACCENT := Color(0.94, 0.26, 0.2)
const GOLD := Color(1.0, 0.8, 0.3)
const PURPLE := Color(0.78, 0.45, 1.0)
const DIM := Color(1, 1, 1, 0.55)
const FADE_OUT_S := 0.9     ## race to black
const FADE_IN_S := 0.7      ## black to the results

## Columns: id, heading, width, alignment (0 left, 2 right).
const COLUMNS := [
	["pos", "POS", 44, 0], ["name", "DRIVER", 160, 0], ["car_name", "CAR", 150, 0], ["laps", "LAPS", 40, 2],
	["time", "TIME / GAP", 100, 2], ["best_lap", "BEST LAP", 112, 2], ["avg_lap", "AVG LAP", 84, 2],
	["s", "S", 66, 2], ["potential", "POTENTIAL", 88, 2], ["stops", "STOPS", 48, 2], ["pen", "PEN", 50, 2],
	["points", "PTS", 40, 2],
]
const SEP := 6
const ROW_FONT := 15

var data: Dictionary = {}
var _backdrop: ColorRect
var _content: Control
var _scroll: ScrollContainer
var _standings_box: VBoxContainer
var _buttons: Array[Button] = []
var _t := 0.0
var _shown := false
var _table_view: Control
var _analysis: ResultsAnalysis
var _driver_view: Control
var _driver_box: VBoxContainer
var _driver_car := -1
var _analysis_btn: Button
var _views_parent: VBoxContainer
var _from_analysis := false
var _row_nodes := {}            ## car -> row panel (to focus it again)
var _pending: Array = []        ## [d, opts] waiting until the table is back on screen
const NEW_ROW_FLASH_S := 1.2    ## a car that has just finished lights up this long


func _ready() -> void:
	_ensure_built()


func _ensure_built() -> void:
	if _backdrop:
		return
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0.015, 0.018, 0.024, 0.0)
	_backdrop.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_backdrop)
	_backdrop.set_anchors_and_offsets_preset(PRESET_FULL_RECT)


## Shows the results. d: ResultsTable.build(). opts:
##   title, subtitle: the heading lines
##   buttons: [[id, text], ...] (the first has focus)
##   notes: [text, ...] under the table (prize money, waiting for the host)
##   standings: {title, note, drivers: [{name, team, points, is_me}], teams: [{team, points}]}
##   instant: true = no fade (screenshots, tests)
## Rows with racing = true (cars still out) show dimmed with just their lap.
func show_results(d: Dictionary, opts := {}) -> void:
	_ensure_built()
	data = d
	_pending = []
	if _content:
		_content.queue_free()
	_buttons.clear()
	_content = _build(d, opts)
	add_child(_content)
	visible = true
	_shown = false
	_t = 0.0
	_content.modulate.a = 0.0
	if opts.get("instant", false):
		_t = FADE_OUT_S + FADE_IN_S
	_step_fade(0.0)


## New numbers for the table already on screen, without fading it again:
## cars that have just finished take their place and light up, the scroll
## and the row with focus stay where they were. While a driver's page or the
## race analysis is open it waits until the table is back. Not shown yet:
## show_results().
func update_results(d: Dictionary, opts := {}) -> void:
	if not visible or _content == null:
		show_results(d, opts)
		return
	if is_driver_open() or is_analysis_open():
		_pending = [d, opts]
		return
	_pending = []
	var was_home := {}
	for r in data.get("rows", []):
		if not r.get("racing", false):
			was_home[int(r["car"])] = true
	var keep := _scroll.scroll_vertical if _scroll else 0
	var focus_car := -1
	var focus_btn := -1
	var fo := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	for car in _row_nodes:
		if _row_nodes[car] == fo:
			focus_car = car
	focus_btn = _buttons.find(fo)
	data = d
	var a := _content.modulate.a
	_content.queue_free()
	_buttons.clear()
	_content = _build(d, opts)
	add_child(_content)
	_content.modulate.a = a
	var snd := get_node_or_null("/root/Sound") if is_inside_tree() else null
	if snd:
		snd.wire_buttons(_content)
	for r in d.get("rows", []):
		var car := int(r["car"])
		if not r.get("racing", false) and not was_home.has(car) and _row_nodes.has(car):
			var row: Control = _row_nodes[car]
			row.modulate = Color(1.9, 1.7, 1.2)
			row.create_tween().tween_property(row, "modulate", Color.WHITE, NEW_ROW_FLASH_S)
	if _shown:
		if focus_car >= 0 and _row_nodes.has(focus_car):
			_focus(_row_nodes[focus_car])
		elif focus_btn >= 0 and focus_btn < _buttons.size():
			_focus(_buttons[focus_btn])
		elif not _buttons.is_empty():
			_focus(_buttons[0])
	if _scroll:
		_scroll.set_deferred("scroll_vertical", keep)


## True while some rows are cars still racing.
func is_live() -> bool:
	return data.get("rows", []).any(func(r): return r.get("racing", false))


func _apply_pending() -> void:
	if not _pending.is_empty():
		var p := _pending
		_pending = []
		update_results.call_deferred(p[0], p[1])


## The championship part only (online guests get the standings a moment
## after the race, when the host has recorded it).
func set_standings(st: Dictionary) -> void:
	if _standings_box == null:
		return
	for c in _standings_box.get_children():
		c.queue_free()
	_fill_standings(_standings_box, st)


func _process(delta: float) -> void:
	if visible and not _shown:
		_step_fade(delta)


func _step_fade(delta: float) -> void:
	_t += delta
	var out := clampf(_t / FADE_OUT_S, 0.0, 1.0)
	var inn := clampf((_t - FADE_OUT_S) / FADE_IN_S, 0.0, 1.0)
	# Down to black, then the screen comes up over a slightly lifted black.
	_backdrop.color.a = lerpf(out, 0.94, inn)
	if _content:
		_content.modulate.a = inn
	if inn >= 1.0:
		_shown = true
		if not _buttons.is_empty():
			_buttons[0].grab_focus()


## True once the fade has finished and the table is on screen.
func is_shown() -> bool:
	return _shown


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _scroll == null:
		return
	if event.is_action_pressed("ui_cancel") and _shown:
		if _driver_view and _driver_view.visible:
			close_driver()
			get_viewport().set_input_as_handled()
			return
		if _analysis and _analysis.visible:
			toggle_analysis()
			get_viewport().set_input_as_handled()
			return
	if not _table_view.visible:
		return
	var step := 0
	if event.is_action_pressed("ui_down"):
		step = 1
	elif event.is_action_pressed("ui_up"):
		step = -1
	if step != 0:
		_scroll.scroll_vertical += step * 30
		get_viewport().set_input_as_handled()


# --- Building it ---------------------------------------------------------------

func _build(d: Dictionary, opts: Dictionary) -> Control:
	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	for side in ["left", "right"]:
		root.add_theme_constant_override("margin_" + side, 30)
	root.add_theme_constant_override("margin_top", 26)
	root.add_theme_constant_override("margin_bottom", 22)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	root.add_child(v)
	_views_parent = v
	v.add_child(_header(d, opts))
	var mid := HBoxContainer.new()
	_table_view = mid
	_row_nodes.clear()
	_analysis = null
	_driver_view = null
	_driver_car = -1
	mid.size_flags_vertical = SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 16)
	v.add_child(mid)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	mid.add_child(left)
	left.add_child(_table_header(d))
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.follow_focus = true
	left.add_child(_scroll)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 2)
	rows.size_flags_horizontal = SIZE_EXPAND_FILL
	_scroll.add_child(rows)
	for r in d.get("rows", []):
		rows.add_child(_row(d, r))
	var pens: Array = d.get("penalties", [])
	if not pens.is_empty():
		rows.add_child(_gap(10))
		rows.add_child(_label("PENALTIES", 15, ACCENT))
		for p in pens:
			rows.add_child(_label("%s  +%d s  %s" % [p["name"], int(p["seconds"]), p["reason"]], 14, DIM))
	if d.get("has_points", false) and str(d.get("points_name", "")) != "":
		rows.add_child(_gap(6))
		rows.add_child(_label("Points: " + str(d["points_name"]), 13, DIM))
	var st: Dictionary = opts.get("standings", {})
	if not st.is_empty():
		var panel := _panel()
		panel.custom_minimum_size = Vector2(280, 0)
		mid.add_child(panel)
		_standings_box = VBoxContainer.new()
		_standings_box.add_theme_constant_override("separation", 3)
		panel.add_child(_standings_box)
		_fill_standings(_standings_box, st)
	else:
		_standings_box = null
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 14)
	v.add_child(foot)
	var notes := VBoxContainer.new()
	notes.size_flags_horizontal = SIZE_EXPAND_FILL
	foot.add_child(notes)
	for n in opts.get("notes", []):
		notes.add_child(_label(str(n), 16, Color(1, 0.86, 0.6)))
	if has_analysis(d):
		_analysis_btn = Button.new()
		_analysis_btn.text = "Race analysis"
		_analysis_btn.custom_minimum_size = Vector2(200, 46)
		_analysis_btn.add_theme_font_size_override("font_size", 19)
		_analysis_btn.pressed.connect(toggle_analysis)
		foot.add_child(_analysis_btn)
	else:
		_analysis_btn = null
	for b in opts.get("buttons", []):
		var btn := Button.new()
		btn.text = str(b[1])
		btn.custom_minimum_size = Vector2(230, 46)
		btn.add_theme_font_size_override("font_size", 19)
		btn.pressed.connect(func(): chosen.emit(str(b[0])))
		foot.add_child(btn)
		_buttons.append(btn)
	return root


func _header(d: Dictionary, opts: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 30)
	var t := VBoxContainer.new()
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	h.add_child(t)
	var title := _label(str(opts.get("title", "RESULTS")), 44, Color.WHITE)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("outline_size", 6)
	t.add_child(title)
	var sub := str(opts.get("subtitle", ""))
	if sub == "":
		sub = "%s  ·  %d lap%s" % [d.get("track", ""), int(d.get("laps", 0)), "" if int(d.get("laps", 0)) == 1 else "s"]
	t.add_child(_label(sub, 18, ACCENT))
	var fl: Dictionary = d.get("fastest", {})
	if not fl.is_empty() and not d.get("derby", false):
		var card := _panel()
		h.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 28)
		card.add_child(row)
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 2)
		row.add_child(cv)
		cv.add_child(_label("FASTEST LAP", 13, PURPLE))
		cv.add_child(_label("%s  %s" % [fl["name"], fmt_time(float(fl["time"]))], 19, Color.WHITE))
		if int(fl.get("lap", 0)) > 0:
			cv.add_child(_label("on lap %d" % int(fl["lap"]), 13, DIM))
		var bs: Array = d.get("best_sectors", [])
		var parts := []
		var ideal := 0.0
		for s in bs.size():
			parts.append("S%d %s" % [s + 1, fmt_sector(float(bs[s]))])
			ideal = ideal + float(bs[s]) if float(bs[s]) > 0.0 and ideal >= 0.0 else -1.0
		if not parts.is_empty():
			var c2 := VBoxContainer.new()
			c2.add_theme_constant_override("separation", 2)
			row.add_child(c2)
			c2.add_child(_label("BEST SECTORS IN THE FIELD", 13, PURPLE))
			c2.add_child(_label("   ".join(parts), 19, Color.WHITE))
			if ideal > 0.0:
				c2.add_child(_label("ideal lap %s" % fmt_time(ideal), 13, DIM))
	return h


## Which columns this race shows: no sectors without sector times, no
## stops without pit stops, no points in qualifying, a derby is just who
## lasted.
func _columns(d: Dictionary) -> Array:
	var out := []
	for c in COLUMNS:
		var id: String = c[0]
		if d.get("derby", false) and id in ["best_lap", "avg_lap", "s", "potential", "stops", "pen", "points", "laps"]:
			continue
		if id == "stops" and not d.get("pits", false):
			continue
		if id == "points" and not d.get("has_points", false):
			continue
		if id == "s":
			for s in int(d.get("sector_count", 0)):
				out.append(["s%d" % s, "S%d" % (s + 1), c[2], c[3]])
			continue
		if id == "time" and d.get("quali", false):
			out.append(["time", "GAP", c[2], c[3]])
			continue
		out.append(c)
	return out


func _table_header(d: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", SEP)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(6, 0)
	h.add_child(pad)
	for c in _columns(d):
		var l := _label(c[1], 13, DIM)
		l.custom_minimum_size = Vector2(c[2], 0)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if c[3] == 2 else HORIZONTAL_ALIGNMENT_LEFT
		h.add_child(l)
	return h


func _row(d: Dictionary, r: Dictionary) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	var me: bool = r.get("is_me", false)
	var racing: bool = r.get("racing", false)
	sb.bg_color = Color(0.32, 0.24, 0.06, 0.75) if me else Color(1, 1, 1, 0.045 if int(r["pos"]) % 2 == 0 else 0.0)
	if me:
		sb.border_color = GOLD
		sb.border_width_left = 4
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	p.add_theme_stylebox_override("panel", sb)
	# A row opens the driver's race data: click it, or A / Enter on it.
	var car := int(r["car"])
	_row_nodes[car] = p
	p.focus_mode = FOCUS_ALL
	p.mouse_filter = MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = CURSOR_POINTING_HAND
	p.tooltip_text = ""
	var base_bg := sb.bg_color
	var lit := func(on: bool) -> void:
		sb.bg_color = base_bg.lerp(Color(1, 1, 1, 0.16), 0.6) if on else base_bg
		sb.border_color = GOLD if on or me else sb.border_color
		sb.border_width_left = 4 if on or me else 0
	p.mouse_entered.connect(lit.bind(true))
	p.mouse_exited.connect(func(): lit.call(p.has_focus()))
	p.focus_entered.connect(lit.bind(true))
	p.focus_exited.connect(lit.bind(false))
	p.gui_input.connect(_on_row_input.bind(p, car))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", SEP)
	h.mouse_filter = MOUSE_FILTER_IGNORE
	p.add_child(h)
	var field_best: Array = d.get("best_sectors", [])
	for c in _columns(d):
		var id: String = c[0]
		var text := ""
		var col := Color.WHITE if not me else Color(1, 0.95, 0.82)
		match id:
			"pos":
				text = r["status"] if r["status"] != "" else "P%d" % int(r["pos"])
				if r["status"] != "":
					col = Color(1, 0.45, 0.4)
			"name":
				text = str(r["name"])
			"car_name":
				text = str(r["car_name"])
				col = DIM if not me else col
			"laps":
				text = str(int(r["laps"]))
			"time":
				if d.get("quali", false):
					text = "" if int(r["pos"]) == 1 else _quali_gap(d, r)
				elif d.get("derby", false):
					text = "Winner" if int(r["pos"]) == 1 and r["status"] == "" else ("" if r["status"] == "" else "wrecked")
				elif r["status"] != "":
					text = "%d lap%s" % [int(r["laps"]), "" if int(r["laps"]) == 1 else "s"]
				elif int(r["pos"]) == 1 or str(r["gap"]) == "":
					text = fmt_time(float(r["time"]))
				else:
					text = str(r["gap"])
			"best_lap":
				text = fmt_time(float(r["best_lap"])) if float(r["best_lap"]) > 0.0 else "-"
				if r.get("fastest", false):
					col = PURPLE
				if int(r.get("best_lap_no", 0)) > 0:
					text += "  L%d" % int(r["best_lap_no"])
			"avg_lap":
				text = fmt_time(float(r["avg_lap"])) if float(r["avg_lap"]) > 0.0 else "-"
			"potential":
				text = fmt_time(float(r["potential"])) if float(r["potential"]) > 0.0 else "-"
			"stops":
				text = str(int(r["stops"]))
			"pen":
				text = "+%d s" % int(r["penalty_s"]) if float(r["penalty_s"]) > 0.0 else ""
				col = Color(1, 0.6, 0.35)
			"points":
				text = str(int(r["points"])) if int(r["points"]) > 0 and not racing else ""
				col = GOLD
			_:
				if id.begins_with("s"):
					var s := int(id.substr(1))
					var bs: Array = r.get("best_sectors", [])
					var v: float = float(bs[s]) if s < bs.size() else 0.0
					text = fmt_sector(v)
					if v > 0.0 and s < field_best.size() and is_equal_approx(v, float(field_best[s])):
						col = PURPLE
		if racing:
			# Still out on track: a dimmed place holder until it crosses the line.
			match id:
				"pos": text = "·"
				"name", "car_name": pass
				"laps": text = str(int(r["laps"]))
				"time": text = "racing" if not d.get("derby", false) else "still going"
				_: text = ""
			col = Color(1, 1, 1, 0.38) if not me else Color(1, 0.85, 0.5, 0.6)
		var l := _label(text, ROW_FONT, col)
		l.custom_minimum_size = Vector2(c[2], 0)
		l.mouse_filter = MOUSE_FILTER_IGNORE
		l.clip_text = true
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if c[3] == 2 else HORIZONTAL_ALIGNMENT_LEFT
		h.add_child(l)
	return p


# --- Driver data and race analysis ------------------------------------------------

func _focus(c: Control) -> void:
	if c and c.is_inside_tree():
		c.grab_focus()


func _on_row_input(ev: InputEvent, row: Control, car: int) -> void:
	var click: bool = ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT
	if click or ev.is_action_pressed("ui_accept"):
		row.accept_event()
		open_driver(car)


## True when the race has laps to analyse (not a derby).
static func has_analysis(d: Dictionary) -> bool:
	if d.get("derby", false):
		return false
	for r in d.get("rows", []):
		if not (r.get("lap_log", []) as Array).is_empty():
			return true
	return false


## Shows or hides the race analysis graphs in place of the table.
func toggle_analysis() -> void:
	if _analysis_btn == null:
		return
	if _driver_view and _driver_view.visible:
		close_driver()
	if _analysis == null:
		_analysis = ResultsAnalysis.new()
		_analysis.setup(data)
		_analysis.car_opened.connect(open_driver)
		_views_parent.add_child(_analysis)
		_views_parent.move_child(_analysis, _table_view.get_index() + 1)
		_analysis.visible = false
	var on := not _analysis.visible
	_analysis.visible = on
	_table_view.visible = not on
	_analysis_btn.text = "Results table" if on else "Race analysis"
	if on:
		_focus(_analysis.focus_target())
	else:
		_focus(_analysis_btn)
		_apply_pending()


func is_analysis_open() -> bool:
	return _analysis != null and _analysis.visible


## Opens one driver's whole race (ResultsDriver) in place of the table or the
## analysis; prev / next step through the field.
func open_driver(car: int) -> void:
	var rows: Array = data.get("rows", [])
	var k := rows.find_custom(func(r): return int(r["car"]) == car)
	if k < 0:
		return
	if _driver_view == null:
		_driver_view = VBoxContainer.new()
		(_driver_view as VBoxContainer).add_theme_constant_override("separation", 8)
		_driver_view.size_flags_vertical = SIZE_EXPAND_FILL
		_views_parent.add_child(_driver_view)
		_views_parent.move_child(_driver_view, _table_view.get_index() + 1)
		var bar := HBoxContainer.new()
		bar.add_theme_constant_override("separation", 10)
		_driver_view.add_child(bar)
		for b in [["back", "‹  Back"], ["prev", "‹ Previous driver"], ["next", "Next driver ›"]]:
			var btn := Button.new()
			btn.name = b[0]
			btn.text = b[1]
			btn.custom_minimum_size = Vector2(150, 34)
			btn.add_theme_font_size_override("font_size", 16)
			btn.pressed.connect(_driver_nav.bind(b[0]))
			bar.add_child(btn)
		var hint := _label("Esc / B to go back", 13, DIM)
		hint.size_flags_vertical = SIZE_SHRINK_CENTER
		bar.add_child(hint)
		var snd := get_node_or_null("/root/Sound") if is_inside_tree() else null
		if snd:
			snd.wire_buttons(bar)
	if not _driver_view.visible:
		_from_analysis = is_analysis_open()
	if _driver_box:
		_driver_box.queue_free()
	var dv := ResultsDriver.new()
	dv.setup(data, rows[k])
	_driver_box = dv
	_driver_view.add_child(dv)
	_driver_car = car
	_driver_view.visible = true
	_table_view.visible = false
	if _analysis:
		_analysis.visible = false
	if _analysis_btn:
		_analysis_btn.visible = false
	var back: Button = _driver_view.get_child(0).get_node("back")
	_focus(back)


func is_driver_open() -> bool:
	return _driver_view != null and _driver_view.visible


func _driver_nav(what: String) -> void:
	if what == "back":
		close_driver()
		return
	var rows: Array = data.get("rows", [])
	var k := rows.find_custom(func(r): return int(r["car"]) == _driver_car)
	var nk := wrapi(k + (1 if what == "next" else -1), 0, rows.size())
	open_driver(int(rows[nk]["car"]))
	_focus((_driver_view.get_child(0).get_node(what) as Button))


## Back from a driver to where they were opened from.
func close_driver() -> void:
	if _driver_view == null:
		return
	_driver_view.visible = false
	if _analysis_btn:
		_analysis_btn.visible = true
	if _from_analysis and _analysis:
		_analysis.visible = true
		_focus(_analysis.focus_target())
	else:
		_table_view.visible = true
		var row: Control = _row_nodes.get(_driver_car)
		if row:
			_focus(row)
		_apply_pending()


func _quali_gap(d: Dictionary, r: Dictionary) -> String:
	var rows: Array = d.get("rows", [])
	if rows.is_empty() or float(r["best_lap"]) <= 0.0 or float(rows[0]["best_lap"]) <= 0.0:
		return "no time" if float(r["best_lap"]) <= 0.0 else ""
	return "+%.3f" % (float(r["best_lap"]) - float(rows[0]["best_lap"]))


func _fill_standings(box: VBoxContainer, st: Dictionary) -> void:
	box.add_child(_label(str(st.get("title", "CHAMPIONSHIP")), 18, ACCENT))
	if str(st.get("note", "")) != "":
		var n := _label(str(st["note"]), 13, DIM)
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(n)
	box.add_child(_gap(4))
	var k := 0
	for dr in st.get("drivers", []):
		k += 1
		var h := HBoxContainer.new()
		var me: bool = dr.get("is_me", false)
		var col := GOLD if me else Color.WHITE
		var a := _label("%d" % k, 15, DIM)
		a.custom_minimum_size = Vector2(26, 0)
		h.add_child(a)
		var nm := _label(str(dr.get("name", "")), 15, col)
		nm.size_flags_horizontal = SIZE_EXPAND_FILL
		nm.clip_text = true
		h.add_child(nm)
		var pts := _label("%d" % int(dr.get("points", 0)), 15, col)
		pts.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		pts.custom_minimum_size = Vector2(46, 0)
		h.add_child(pts)
		box.add_child(h)
		if str(dr.get("team", "")) != "":
			var tm := _label("     " + str(dr["team"]), 12, DIM)
			tm.clip_text = true
			box.add_child(tm)
	var teams: Array = st.get("teams", [])
	if not teams.is_empty():
		box.add_child(_gap(8))
		box.add_child(_label("TEAMS", 15, ACCENT))
		var j := 0
		for t in teams:
			j += 1
			var h := HBoxContainer.new()
			var a := _label("%d" % j, 14, DIM)
			a.custom_minimum_size = Vector2(26, 0)
			h.add_child(a)
			var nm := _label(str(t.get("team", "")), 14, Color.WHITE)
			nm.size_flags_horizontal = SIZE_EXPAND_FILL
			nm.clip_text = true
			h.add_child(nm)
			var pts := _label("%d" % int(t.get("points", 0)), 14, Color.WHITE)
			pts.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			pts.custom_minimum_size = Vector2(46, 0)
			h.add_child(pts)
			box.add_child(h)
	if str(st.get("champion", "")) != "":
		box.add_child(_gap(8))
		box.add_child(_label("%s is the champion!" % st["champion"], 17, GOLD))


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.075, 0.09, 0.95)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


static func fmt_time(t: float) -> String:
	if t <= 0.0:
		return "--:--.---"
	return "%d:%06.3f" % [int(t) / 60, fmod(t, 60.0)]


static func fmt_sector(t: float) -> String:
	if t <= 0.0:
		return "-"
	if t >= 60.0:
		return fmt_time(t)
	return "%.3f" % t
