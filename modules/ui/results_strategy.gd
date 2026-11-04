class_name ResultsStrategy
extends Control
## The results analysis's driver list: one row per driver in finishing
## order with places won or lost from the grid and their tyre strategy
## (each stint as a bar along the race, coloured by tyre, a ring at every
## stop). It is also the graphs' legend: clicking a driver (or A on the
## picked row) shows them on the graphs, in the colour of their swatch.

signal car_toggled(car: int)
signal car_opened(car: int)

const INK := Color(1, 1, 1, 0.92)
const DIM := Color(1, 1, 1, 0.5)
const GAINED := Color(0.22, 0.53, 0.9)     ## blue: places won
const LOST := Color(0.85, 0.35, 0.15)      ## orange: places lost
const ROW_MAX := 26.0
const W_SWATCH := 18.0
const W_POS := 34.0
const W_NAME := 128.0
const W_GAIN := 92.0

var rows: Array = []           ## ResultsTable rows
var max_laps := 1
var compounds: Dictionary = {}
var colors: Dictionary = {}    ## car -> Color (the cars on the graphs)
var cursor := -1               ## keyboard / pad row
var _hover := -1


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_STOP
	focus_mode = FOCUS_ALL


func set_data(p_rows: Array, p_max_laps: int, p_compounds: Dictionary, p_colors: Dictionary) -> void:
	rows = p_rows
	max_laps = maxi(p_max_laps, 1)
	compounds = p_compounds
	colors = p_colors
	custom_minimum_size.y = 24.0 + rows.size() * 15.0
	queue_redraw()


func row_h() -> float:
	return clampf((size.y - 24.0) / maxf(rows.size(), 1.0), 12.0, ROW_MAX)


func _draw() -> void:
	var font := get_theme_default_font()
	var rh := row_h()
	var fs := 13 if rh >= 18.0 else 11
	var bar_x := W_SWATCH + W_POS + W_NAME + W_GAIN + 8.0
	var bar_w := maxf(size.x - bar_x - 8.0, 40.0)
	# Headings.
	draw_string(font, Vector2(W_SWATCH, 14), "POS", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DIM)
	draw_string(font, Vector2(W_SWATCH + W_POS, 14), "DRIVER", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DIM)
	draw_string(font, Vector2(W_SWATCH + W_POS + W_NAME, 14), "FROM GRID", HORIZONTAL_ALIGNMENT_CENTER, W_GAIN, 11, DIM)
	draw_string(font, Vector2(bar_x, 14), "TYRES AND STOPS", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DIM)
	draw_string(font, Vector2(bar_x, 14), "lap %d" % max_laps, HORIZONTAL_ALIGNMENT_RIGHT, bar_w, 11, DIM)
	for k in rows.size():
		var r: Dictionary = rows[k]
		var y := 22.0 + k * rh
		var mid := y + rh * 0.5
		var car := int(r["car"])
		if k == _hover or k == cursor:
			draw_rect(Rect2(0, y, size.x, rh - 1), Color(1, 1, 1, 0.08))
		if k == cursor and has_focus():
			draw_rect(Rect2(0, y, size.x, rh - 1), Color(1, 0.8, 0.3, 0.7), false, 1.5)
		if bool(r.get("is_me", false)):
			draw_rect(Rect2(0, y, 3, rh - 1), Color(1.0, 0.8, 0.3))
		# Swatch: filled when the driver is on the graphs.
		var sw := Rect2(5, mid - 5, 10, 10)
		if colors.has(car):
			draw_rect(sw, colors[car])
		else:
			draw_rect(sw, Color(1, 1, 1, 0.25), false, 1.0)
		var pos_t := str(r["status"]) if str(r["status"]) != "" else "P%d" % int(r["pos"])
		draw_string(font, Vector2(W_SWATCH, mid + fs * 0.36), pos_t, HORIZONTAL_ALIGNMENT_LEFT, W_POS, fs,
			Color(1, 0.45, 0.4) if str(r["status"]) != "" else INK)
		draw_string(font, Vector2(W_SWATCH + W_POS, mid + fs * 0.36), ResultsGraph._short(str(r["name"])),
			HORIZONTAL_ALIGNMENT_LEFT, W_NAME - 4, fs, INK)
		_gain(font, r, Rect2(W_SWATCH + W_POS + W_NAME, y + 2, W_GAIN, rh - 4), fs)
		_stints(font, r, Rect2(bar_x, y + 3, bar_w, rh - 6), fs)


## Places won or lost: a bar right (blue) or left (orange) of the middle.
func _gain(font: Font, r: Dictionary, box: Rect2, fs: int) -> void:
	var g := int(r.get("gained", 0))
	var cx := box.position.x + box.size.x * 0.5
	draw_line(Vector2(cx, box.position.y), Vector2(cx, box.end.y), Color(1, 1, 1, 0.18), 1.0)
	if int(r.get("grid", 0)) <= 0:
		return
	var half := box.size.x * 0.5 - 22.0
	var bl := minf(absf(g) / 10.0, 1.0) * half
	var mid := box.position.y + box.size.y * 0.5
	var h := minf(box.size.y, 10.0)
	if g > 0:
		draw_rect(Rect2(cx + 1, mid - h * 0.5, maxf(bl, 3.0), h), GAINED)
		draw_string(font, Vector2(cx + bl + 4, mid + fs * 0.36), "+%d" % g, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, INK)
	elif g < 0:
		draw_rect(Rect2(cx - 1 - maxf(bl, 3.0), mid - h * 0.5, maxf(bl, 3.0), h), LOST)
		draw_string(font, Vector2(cx - bl - 26, mid + fs * 0.36), "%d" % g, HORIZONTAL_ALIGNMENT_RIGHT, 22, fs - 1, INK)
	else:
		draw_string(font, Vector2(cx + 4, mid + fs * 0.36), "=", HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, DIM)


## The race as a bar: each stint in its tyre's colour, 2 px apart.
func _stints(font: Font, r: Dictionary, box: Rect2, fs: int) -> void:
	draw_rect(box, Color(1, 1, 1, 0.04))
	var per := box.size.x / float(max_laps)
	for st in r.get("stints", []):
		var x0 := box.position.x + (int(st["from"]) - 1) * per
		var x1 := box.position.x + int(st["to"]) * per
		var seg := Rect2(x0 + 1, box.position.y, maxf(x1 - x0 - 2, 2.0), box.size.y)
		var col := ResultsTable.compound_colour(str(st["compound"]))
		draw_rect(seg, Color(col, 0.85))
		var cname := str(compounds.get(st["compound"], ""))
		if cname != "" and seg.size.x > font.get_string_size(cname, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2).x + 8:
			draw_string(font, Vector2(seg.position.x + 4, seg.position.y + seg.size.y * 0.5 + (fs - 2) * 0.36), cname,
				HORIZONTAL_ALIGNMENT_LEFT, seg.size.x - 6, fs - 2, Color(0.05, 0.06, 0.08))
	var laps := int(r.get("laps", 0))
	if str(r["status"]) != "" and laps < max_laps:
		draw_string(font, Vector2(box.position.x + laps * per + 6, box.position.y + box.size.y * 0.5 + (fs - 2) * 0.36),
			str(r["status"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2, Color(1, 0.45, 0.4))


func _row_at(p: Vector2) -> int:
	if p.y < 22.0:
		return -1
	var k := int((p.y - 22.0) / row_h())
	return k if k >= 0 and k < rows.size() else -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var k := _row_at(event.position)
		if k != _hover:
			_hover = k
			mouse_default_cursor_shape = CURSOR_POINTING_HAND if k >= 0 else CURSOR_ARROW
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var k := _row_at(event.position)
		if k >= 0:
			cursor = k
			if event.double_click:
				car_opened.emit(int(rows[k]["car"]))
			else:
				car_toggled.emit(int(rows[k]["car"]))
			accept_event()
	elif has_focus() and not rows.is_empty():
		var step := 0
		if event.is_action_pressed("ui_down"):
			step = 1
		elif event.is_action_pressed("ui_up"):
			step = -1
		if step != 0:
			var nk := cursor + step
			if nk < 0 or nk >= rows.size():
				return   # let focus move on to the buttons
			cursor = nk
			queue_redraw()
			accept_event()
		elif event.is_action_pressed("ui_accept") and cursor >= 0:
			car_toggled.emit(int(rows[cursor]["car"]))
			accept_event()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_MOUSE_EXIT:
			_hover = -1
			queue_redraw()
		NOTIFICATION_FOCUS_ENTER:
			if cursor < 0:
				cursor = 0
			queue_redraw()
		NOTIFICATION_FOCUS_EXIT:
			queue_redraw()
