class_name SpectatorHud
extends Control
## What a player sees once their own car has finished (or retired) while the
## rest of the field is still racing: they watch the race, pick any car and
## any camera view, until the last car is home and the results come up.
##
## On screen: a SPECTATING banner with how many cars are still racing, the
## running order down the left (click a driver to watch them), a card for
## the car being watched (position, lap, last and best lap, gaps to the cars
## around it) and the camera view, with the controls.
##
## Controls (the race scene reads them): left / right (A / D, arrows, the
## left stick) the car before / after in the running order, C / Y the next
## camera view, Space / A back to your own car, the zoom keys and Z / R3 as
## in the race. Mouse: click a driver, or the arrows and the camera button.

signal car_picked(car: int)
signal car_step(step: int)
signal view_step

const ACCENT := Color(0.94, 0.26, 0.2)
const GOLD := Color(1.0, 0.8, 0.3)
const DIM := Color(1, 1, 1, 0.55)
const REFRESH_S := 0.25
const TOWER_ROWS := 25

var session: RaceSession
var car := -1                 ## the car being watched
var own_car := -1             ## this player's car (gold)
var view_name := ""
var _banner: Label
var _sub: Label
var _tower: VBoxContainer
var _card_title: Label
var _card_lines: Label
var _view_btn: Button
var _hint: Label
var _since := 0.0


func setup(p_session: RaceSession) -> void:
	session = p_session
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	visible = false
	_build()


func _build() -> void:
	var top := VBoxContainer.new()
	top.set_anchors_and_offsets_preset(PRESET_TOP_WIDE)
	top.offset_top = 14
	top.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(top)
	_banner = _label("SPECTATING", 30, Color.WHITE)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_banner.add_theme_constant_override("outline_size", 6)
	top.add_child(_banner)
	_sub = _label("", 16, Color(1, 0.86, 0.6))
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_sub.add_theme_constant_override("outline_size", 4)
	top.add_child(_sub)

	var left := _panel()
	left.position = Vector2(14, 70)
	add_child(left)
	_tower = VBoxContainer.new()
	_tower.add_theme_constant_override("separation", 0)
	left.add_child(_tower)

	# The card sits at the bottom middle, as tall as its lines.
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	col.offset_bottom = -16
	col.alignment = BoxContainer.ALIGNMENT_END
	col.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(col)
	var centre := HBoxContainer.new()
	centre.alignment = BoxContainer.ALIGNMENT_CENTER
	centre.mouse_filter = MOUSE_FILTER_IGNORE
	col.add_child(centre)
	var card := _panel()
	card.custom_minimum_size = Vector2(620, 0)
	centre.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 4)
	card.add_child(cv)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	cv.add_child(row)
	var prev := _button("◀", func(): car_step.emit(-1))
	row.add_child(prev)
	_card_title = _label("", 22, Color.WHITE)
	_card_title.size_flags_horizontal = SIZE_EXPAND_FILL
	_card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_title.clip_text = true
	row.add_child(_card_title)
	var nxt := _button("▶", func(): car_step.emit(1))
	row.add_child(nxt)
	_card_lines = _label("", 15, Color(1, 1, 1, 0.85))
	_card_lines.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_card_lines)
	var vrow := HBoxContainer.new()
	vrow.alignment = BoxContainer.ALIGNMENT_CENTER
	cv.add_child(vrow)
	_view_btn = _button("Camera", func(): view_step.emit())
	_view_btn.custom_minimum_size = Vector2(260, 32)
	vrow.add_child(_view_btn)
	_hint = _label("", 12, DIM)
	InputPrompt.live(_hint, func(): _hint.text = InputPrompt.fill("◀ ▶  %s: change car   ·   {camera_toggle}: camera   ·   {handbrake}: your car   ·   {zoom_full}: whole track"
		% InputPrompt.pair("steer_left", "steer_right")))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_hint)


## Watch car `i` through the camera called `p_view_name`.
func watch(i: int, p_view_name: String) -> void:
	var changed := i != car or p_view_name != view_name
	car = i
	view_name = p_view_name
	if changed:
		_refresh()


func _process(delta: float) -> void:
	if not visible or session == null:
		return
	_since += delta
	if _since >= REFRESH_S:
		_since = 0.0
		_refresh()


func _refresh() -> void:
	if session == null or car < 0 or car >= session.sim.car_count():
		return
	var sim := session.sim
	var racing := ResultsTable.still_racing(sim)
	_sub.text = ("%d car%s still racing  ·  results when the last car finishes" % [racing.size(), "" if racing.size() == 1 else "s"]) \
		if not racing.is_empty() else "Every car is home"
	_view_btn.text = "Camera: " + view_name
	# The running order (this player gold, the car being watched lit up).
	for c in _tower.get_children():
		c.queue_free()
	var order := sim.running_order
	var start := 0
	var k := order.find(car)
	if order.size() > TOWER_ROWS and k >= 0:
		start = clampi(k - TOWER_ROWS / 2, 0, order.size() - TOWER_ROWS)
	for p in range(start, mini(order.size(), start + TOWER_ROWS)):
		var i: int = order[p]
		var e: RaceEntry = sim.entries[i]
		var state := ""
		if e.finished:
			state = "  ⚑"
		elif e.dnf:
			state = "  OUT"
		var b := Button.new()
		b.flat = true
		b.focus_mode = FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%2d  %s%s" % [p + 1, e.driver_name, state]
		b.custom_minimum_size = Vector2(230, 0)
		b.add_theme_font_size_override("font_size", 14)
		var col := Color.WHITE
		if i == own_car:
			col = GOLD
		elif e.dnf and not e.finished:
			col = Color(1, 1, 1, 0.4)
		if i == car:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(ACCENT, 0.55)
			sb.set_corner_radius_all(3)
			sb.content_margin_left = 4
			b.add_theme_stylebox_override("normal", sb)
		b.add_theme_color_override("font_color", col)
		b.pressed.connect(car_picked.emit.bind(i))
		_tower.add_child(b)
	# The watched car.
	var e: RaceEntry = sim.entries[car]
	var pos := order.find(car) + 1
	_card_title.text = "P%d  %s" % [pos, e.driver_name] + ("  (you)" if car == own_car else "")
	var bits := [sim.defs[car].display_name]
	if e.finished:
		bits.append("finished")
	elif e.dnf:
		bits.append("out of the race")
	elif not sim.settings.is_derby():
		bits.append("lap %d / %d" % [mini(e.laps_done + 1, sim.settings.laps), sim.settings.laps])
	var lines := ["  ·  ".join(bits)]
	if not sim.settings.is_derby():
		var t := []
		if not e.lap_times.is_empty():
			t.append("last " + RaceResults.fmt_time(e.lap_times[-1]))
		if e.best_lap > 0.0:
			t.append("best " + RaceResults.fmt_time(e.best_lap))
		var ct: CarTelemetry = session.telemetry.cars[car] if car < session.telemetry.cars.size() else null
		if ct and not e.finished and not e.dnf:
			if pos > 1 and ct.interval > 0.0:
				t.append("%.1f s behind P%d" % [ct.interval, pos - 1])
			if ct.gap_behind > 0.0:
				t.append("%.1f s ahead of P%d" % [ct.gap_behind, pos + 1])
		if not t.is_empty():
			lines.append("  ·  ".join(t))
	_card_lines.text = "\n".join(lines)


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.055, 0.065, 0.82)
	sb.border_color = ACCENT
	sb.border_width_top = 3
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = FOCUS_NONE
	b.custom_minimum_size = Vector2(40, 32)
	b.pressed.connect(cb)
	return b


func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = MOUSE_FILTER_IGNORE
	return l
