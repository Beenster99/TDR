class_name HudEditor
extends Control
## The HUD layout editor: the driver moves, resizes, hides and brings back
## each race HUD item with the mouse and keyboard. Opens over a race (F2,
## RaceHud.open_editor) or from Settings > Gameplay over a live preview race
## (HudEditor.open_preview). Saves to GameData.prefs["hud_layout"] (HudLayout).
##
## Mouse: drag an item to move it (it snaps to the screen edges, the centre and
## other items; hold Alt to place it freely), drag a corner or use the wheel
## to resize, right-click to hide. The panel lists every item: tick to show.
## Keys: Tab picks the next item, arrows nudge (Shift: 10x), + / - resize,
## Delete hides, R resets the item, Ctrl+Z undoes, Enter or Esc saves and
## closes. Cancel puts everything back as it was.

signal closed(saved: bool)

const ACCENT := Color(0.94, 0.26, 0.2)
const GUIDE := Color(0.35, 0.85, 1.0, 0.9)
const SNAP_PX := 8.0
const EDGE := 10.0          ## snap margin from the screen edges
const HANDLE := 12.0
const SCALE_STEP := 0.05

var hud: RaceHud
var selected := ""
var _hover := ""
var _drag := ""             ## "move", "scale" or ""
var _drag_offset := Vector2.ZERO
var _drag_corner := Vector2.ZERO   ## the corner being dragged (0/1, 0/1)
var _drag_start_s := 1.0
var _drag_start_len := 1.0
var _guides: Array = []     ## [from, to] lines shown while snapping
var _undo: Array = []
var _start: Dictionary      ## layout + tower when the editor opened (Cancel)
## Settings preview: the layout not being shown (solo or co-op driver), so
## both can be edited and saved together.
var _other: HudLayout = null
var _mode_buttons := {}     ## coop (bool) -> Button
var _panel: PanelContainer
var _checks := {}           ## id -> CheckBox
var _sel_label: Label
var _panel_drag := false
var _panel_drag_from := Vector2.ZERO
var _refreshing := false
var _fold: Button
var _foldable: Array = []   ## panel parts hidden when the list is folded up


func setup(p_hud: RaceHud) -> void:
	hud = p_hud
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	focus_mode = FOCUS_ALL
	if hud.drives_session:
		var gd := get_node_or_null("/root/GameData")
		_other = HudLayout.load_from(gd.prefs if gd != null else {}, not hud.coop, RaceHud.item_ids())
	_start = _snapshot()
	_build_panel()
	_refresh_panel()


# --- Settings preview -------------------------------------------------------------

## Opens the editor from the menus: a HUD over a little all-AI race (no 3D,
## the menu's background shows through), driven by the HUD itself. Returns
## the root node, already added to `host`; it frees itself when closed.
static func open_preview(host: Node) -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	host.add_child(root)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.03, 0.04, 0.45)
	shade.mouse_filter = MOUSE_FILTER_IGNORE
	root.add_child(shade)
	shade.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var session := preview_session()
	var hud := RaceHud.new()
	root.add_child(hud)
	hud.setup(session)
	hud.drives_session = true
	hud.open_editor()
	hud.edit_finished.connect(func(_saved: bool): root.queue_free())
	return root


## A short all-AI race to show the HUD with live numbers: pits, fuel, tyre
## wear and damage on, run on a little so there are lap and sector times.
static func preview_session() -> RaceSession:
	var gd: Node = Engine.get_main_loop().root.get_node_or_null("/root/GameData")
	var s := RaceSettings.new()
	s.seed = 2026
	s.laps = 20
	s.ai_count = 11
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.damage_level = "full"
	s.damage_enabled = true
	s.mandatory_pit_stops = 1
	s.countdown_s = 0.5
	var start := RaceFactory.plan(s, [], gd.cars, gd.drivers)
	var session := RaceSession.create(RaceSession.Mode.OFFLINE, start, 1)
	session.local_car = 5
	for _k in 60 * 40:   # 40 s of racing: everyone has sector times
		session.tick(null)
	return session


# --- Saving, undo -------------------------------------------------------------------

func _snapshot() -> Dictionary:
	return {"layout": hud.layout.to_value(), "tower": hud.show_tower(), "coop": hud.coop,
		"other": _other.to_value() if _other != null else {}}


func _restore(snap: Dictionary) -> void:
	hud.coop = bool(snap["coop"])
	hud.layout = HudLayout.from_value(snap["layout"])
	hud.set_show_tower(bool(snap["tower"]))
	if _other != null:
		_other = HudLayout.from_value(snap["other"])
	_refresh_panel()


## Settings preview: edit the solo layout or the co-op driver's.
func set_coop(on: bool) -> void:
	if _other == null or hud.coop == on:
		_refresh_panel()
		return
	_push_undo()
	var shown := hud.layout
	hud.layout = _other
	_other = shown
	hud.coop = on
	selected = ""
	_refresh_panel()


func _push_undo() -> void:
	_undo.append(_snapshot())
	if _undo.size() > 100:
		_undo.pop_front()


func undo() -> void:
	if _undo.is_empty():
		return
	_restore(_undo.pop_back())


func save_and_close() -> void:
	hud.save_layout()
	var gd := get_node_or_null("/root/GameData")
	if _other != null and gd != null and gd.has_method("set_pref"):
		gd.call("set_pref", HudLayout.PREF if hud.coop else HudLayout.PREF_COOP, _other.to_value())
	_close(true)


func cancel() -> void:
	_restore(_start)
	_close(false)


func _close(saved: bool) -> void:
	closed.emit(saved)
	queue_free()


# --- Items under the mouse -------------------------------------------------------

## The items shown now, in drawing order.
func _shown() -> Array:
	var out := []
	for it in RaceHud.ITEMS:
		if hud.item_shown(it[0]) and hud.item_rect(it[0]).size != Vector2.ZERO:
			out.append(it[0])
	return out


## The top item under a point ("" for none).
func item_at(p: Vector2) -> String:
	var ids := _shown()
	for k in range(ids.size() - 1, -1, -1):
		if hud.item_rect(ids[k]).grow(2.0).has_point(p):
			return ids[k]
	return ""


## The selected item's corner under a point (Vector2(-1, -1) for none).
func _corner_at(p: Vector2) -> Vector2:
	if selected == "" or not hud.item_shown(selected):
		return Vector2(-1, -1)
	var r := hud.item_rect(selected)
	for c in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		var at: Vector2 = r.position + r.size * c
		if Rect2(at - Vector2(HANDLE, HANDLE), Vector2(HANDLE, HANDLE) * 2.0).has_point(p):
			return c
	return Vector2(-1, -1)


func select(id: String) -> void:
	selected = id
	_refresh_panel()


# --- Mouse --------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			grab_focus()
			var corner := _corner_at(mb.position)
			if corner.x >= 0.0:
				_push_undo()
				_drag = "scale"
				_drag_corner = corner
				var r := hud.item_rect(selected)
				_drag_start_s = hud.layout.scale_of(selected)
				_drag_start_len = maxf((mb.position - (r.position + r.size * (Vector2.ONE - corner))).length(), 1.0)
			else:
				var id := item_at(mb.position)
				select(id)
				if id != "":
					_push_undo()
					_drag = "move"
					_drag_offset = mb.position - hud.item_rect(id).position
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_drag = ""
			_guides.clear()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var id := item_at(mb.position)
			if id != "":
				_push_undo()
				hud.set_item_on(id, false)
				if selected == id:
					selected = ""
				_refresh_panel()
			accept_event()
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var id := item_at(mb.position)
			if id != "":
				select(id)
				_push_undo()
				var r := hud.item_rect(id)
				var keep := ((mb.position - r.position) / r.size).clamp(Vector2.ZERO, Vector2.ONE)
				var step := SCALE_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -SCALE_STEP
				hud.scale_item(id, hud.layout.scale_of(id) + step, keep)
				_refresh_panel()
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag == "move" and selected != "":
			var r := hud.item_rect(selected)
			var tl := mm.position - _drag_offset
			if not mm.alt_pressed:
				tl = _snap(selected, Rect2(tl, r.size))
			else:
				_guides.clear()
			hud.move_item(selected, tl)
		elif _drag == "scale" and selected != "":
			var r := hud.item_rect(selected)
			var pin := Vector2.ONE - _drag_corner
			var dist := (mm.position - (r.position + r.size * pin)).length()
			hud.scale_item(selected, _drag_start_s * dist / _drag_start_len, pin)
			_refresh_panel()
		else:
			var corner := _corner_at(mm.position)
			_hover = item_at(mm.position)
			if corner.x >= 0.0:
				mouse_default_cursor_shape = CURSOR_FDIAGSIZE if corner.x == corner.y else CURSOR_BDIAGSIZE
			else:
				mouse_default_cursor_shape = CURSOR_MOVE if _hover != "" else CURSOR_ARROW
		accept_event()


## Snaps a rect being dragged to the screen edges and centre and to the other
## items' edges and centres; returns its top-left corner and sets the guides.
func _snap(id: String, r: Rect2) -> Vector2:
	_guides.clear()
	var vp := hud.size
	var xs := [EDGE, vp.x * 0.5, vp.x - EDGE]
	var ys := [EDGE, vp.y * 0.5, vp.y - EDGE]
	for other in _shown():
		if other == id:
			continue
		var o := hud.item_rect(other)
		xs.append_array([o.position.x, o.get_center().x, o.end.x, o.position.x - EDGE, o.end.x + EDGE])
		ys.append_array([o.position.y, o.get_center().y, o.end.y, o.position.y - EDGE, o.end.y + EDGE])
	var tl := r.position
	var bx := _best(xs, [r.position.x, r.get_center().x, r.end.x])
	if bx.size() > 0:
		tl.x += bx[0]
		_guides.append([Vector2(bx[1], 0), Vector2(bx[1], vp.y)])
	var by := _best(ys, [r.position.y, r.get_center().y, r.end.y])
	if by.size() > 0:
		tl.y += by[0]
		_guides.append([Vector2(0, by[1]), Vector2(vp.x, by[1])])
	return tl


## The smallest shift (within SNAP_PX) lining one of `mine` up with one of
## `targets`: [shift, target], or [] for none.
static func _best(targets: Array, mine: Array) -> Array:
	var best := []
	var best_d := SNAP_PX + 0.001
	for m in mine:
		for t in targets:
			var d := absf(float(t) - float(m))
			if d < best_d:
				best_d = d
				best = [float(t) - float(m), float(t)]
	return best


# --- Keyboard -----------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var k := event as InputEventKey
	var handled := true
	var step := 10.0 if k.shift_pressed else 1.0
	match k.keycode:
		KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER:
			save_and_close()
		KEY_TAB:
			_cycle(-1 if k.shift_pressed else 1)
		KEY_LEFT: _nudge(Vector2(-step, 0), k.echo)
		KEY_RIGHT: _nudge(Vector2(step, 0), k.echo)
		KEY_UP: _nudge(Vector2(0, -step), k.echo)
		KEY_DOWN: _nudge(Vector2(0, step), k.echo)
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD, KEY_BRACKETRIGHT:
			_rescale(SCALE_STEP)
		KEY_MINUS, KEY_KP_SUBTRACT, KEY_BRACKETLEFT:
			_rescale(-SCALE_STEP)
		KEY_DELETE, KEY_BACKSPACE:
			if selected != "":
				_push_undo()
				hud.set_item_on(selected, false)
				selected = ""
				_refresh_panel()
		KEY_L:
			toggle_list()
		KEY_R:
			if selected != "":
				reset_selected()
		KEY_Z:
			if k.ctrl_pressed or k.meta_pressed:
				undo()
			else:
				handled = false
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _cycle(dir: int) -> void:
	var ids := _shown()
	if ids.is_empty():
		return
	var k := ids.find(selected)
	select(ids[posmod(k + dir, ids.size())] if k >= 0 else ids[0 if dir > 0 else ids.size() - 1])


func _nudge(by: Vector2, repeat: bool) -> void:
	if selected == "":
		return
	if not repeat:
		_push_undo()
	hud.move_item(selected, hud.item_rect(selected).position + by)


func _rescale(by: float) -> void:
	if selected == "":
		return
	_push_undo()
	hud.scale_item(selected, hud.layout.scale_of(selected) + by)
	_refresh_panel()


func reset_selected() -> void:
	_push_undo()
	hud.layout.reset(selected)
	_refresh_panel()


# --- Drawing ------------------------------------------------------------------------

func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	for id in _shown():
		var r := hud.item_rect(id)
		var sel: bool = id == selected
		var col := ACCENT if sel else (Color(1, 1, 1, 0.75) if id == _hover else Color(1, 1, 1, 0.3))
		draw_rect(r, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.10) if sel else Color(1, 1, 1, 0.03))
		draw_rect(r, col, false, 2.0 if sel else 1.0)
		var label := RaceHud.item_name(id)
		var pct := roundi(hud.layout.scale_of(id) * 100.0)
		if pct != 100:
			label += "  %d%%" % pct
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 12
		var ly := r.position.y - 20 if r.position.y > 22 else r.end.y + 2
		draw_rect(Rect2(r.position.x, ly, tw, 18), Color(ACCENT, 0.95) if sel else Color(0, 0, 0, 0.7))
		draw_string(font, Vector2(r.position.x + 6, ly + 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		if sel:
			for c in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
				var at: Vector2 = r.position + r.size * c
				draw_rect(Rect2(at - Vector2(6, 6), Vector2(12, 12)), Color.WHITE)
				draw_rect(Rect2(at - Vector2(6, 6), Vector2(12, 12)), ACCENT, false, 2.0)
	for g in _guides:
		draw_dashed_line(g[0], g[1], GUIDE, 1.5, 8.0)


# --- The panel: item list and buttons -----------------------------------------------

func _build_panel() -> void:
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.07, 0.93)
	sb.border_color = Color(1, 1, 1, 0.15)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_panel.add_child(box)
	var title := Label.new()
	title.text = "HUD LAYOUT"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1, 0.86, 0.82))
	title.mouse_filter = MOUSE_FILTER_STOP
	title.mouse_default_cursor_shape = CURSOR_MOVE
	title.tooltip_text = "Drag to move this panel"
	title.gui_input.connect(_on_title_input)
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	var head := HBoxContainer.new()
	box.add_child(head)
	head.add_child(title)
	_fold = _button("Hide list", toggle_list)
	_fold.tooltip_text = "Fold the panel up to see the HUD behind it (L)"
	head.add_child(_fold)
	var help := Label.new()
	help.text = "Drag items to move them (Alt: no snapping). Wheel or a corner to resize. Right-click hides.\nTab next · arrows nudge (Shift ×10) · + / − size · Del hide · R reset · L fold list · Ctrl+Z undo · Enter/Esc save"
	help.add_theme_font_size_override("font_size", 12)
	help.modulate = Color(1, 1, 1, 0.6)
	help.custom_minimum_size = Vector2(500, 0)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(help)
	_foldable.append(help)
	if hud.session != null and hud.session.mode != RaceSession.Mode.OFFLINE and not hud.drives_session:
		var live := Label.new()
		live.text = "Online race: the race keeps running while you edit."
		live.add_theme_font_size_override("font_size", 13)
		live.add_theme_color_override("font_color", Color(1, 0.7, 0.35))
		box.add_child(live)
	if _other != null:
		# Settings: pick which layout to edit.
		var modes := HBoxContainer.new()
		modes.add_theme_constant_override("separation", 6)
		box.add_child(modes)
		var l := Label.new()
		l.text = "Layout for"
		modes.add_child(l)
		for c in [false, true]:
			var b := _button("Co-op driver" if c else "Solo and online", set_coop.bind(c))
			b.toggle_mode = true
			b.tooltip_text = "When you drive a car shared with team mates, who tell you what you need over voice: a minimal HUD." if c \
				else "Your normal race screen."
			modes.add_child(b)
			_mode_buttons[c] = b
	elif hud.coop:
		var note := Label.new()
		note.text = "Co-op driver layout: used while you drive a car shared with team mates."
		note.add_theme_font_size_override("font_size", 13)
		note.add_theme_color_override("font_color", Color(0.6, 0.85, 1))
		box.add_child(note)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 2)
	box.add_child(grid)
	_foldable.append(grid)
	for it in RaceHud.ITEMS:
		var cb := CheckBox.new()
		cb.text = it[1]
		cb.focus_mode = FOCUS_NONE
		cb.custom_minimum_size = Vector2(240, 0)
		cb.tooltip_text = "Tick to show, untick to hide."
		cb.toggled.connect(_on_check.bind(it[0]))
		grid.add_child(cb)
		_checks[it[0]] = cb
	box.add_child(HSeparator.new())
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 8)
	box.add_child(size_row)
	_sel_label = Label.new()
	_sel_label.size_flags_horizontal = SIZE_EXPAND_FILL
	size_row.add_child(_sel_label)
	size_row.add_child(_button("−", func(): _rescale(-SCALE_STEP), Vector2(40, 0)))
	size_row.add_child(_button("+", func(): _rescale(SCALE_STEP), Vector2(40, 0)))
	size_row.add_child(_button("Reset item", func():
		if selected != "":
			reset_selected()))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	row.add_child(_button("Undo", undo))
	row.add_child(_button("Reset all", func():
		_push_undo()
		hud.reset_layout()
		_refresh_panel()))
	var gap := Control.new()
	gap.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(gap)
	row.add_child(_button("Cancel", cancel))
	var done := _button("Save and close", save_and_close)
	done.add_theme_color_override("font_color", Color(1, 0.86, 0.82))
	row.add_child(done)
	# Start in the middle of the screen, where the HUD leaves room.
	_panel.reset_size()
	var vp := hud.size if hud.size != Vector2.ZERO else get_viewport_rect().size
	_panel.position = ((vp - _panel.get_combined_minimum_size()) * Vector2(0.5, 0.6)).round()


## Folds the panel's help and item list away (or back).
func toggle_list() -> void:
	var show: bool = not _foldable[0].visible
	for c in _foldable:
		c.visible = show
	_fold.text = "Hide list" if show else "Show list"
	_panel.reset_size()


func _button(text: String, cb: Callable, min_size := Vector2(0, 0)) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = FOCUS_NONE
	b.custom_minimum_size = min_size
	b.pressed.connect(cb)
	return b


func _on_check(on: bool, id: String) -> void:
	if _refreshing:
		return
	_push_undo()
	hud.set_item_on(id, on)
	selected = id if on else ("" if selected == id else selected)
	_refresh_panel()


func _on_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_panel_drag = event.pressed
		_panel_drag_from = event.global_position - _panel.position
	elif event is InputEventMouseMotion and _panel_drag:
		var vp := get_viewport_rect().size
		_panel.position = (event.global_position - _panel_drag_from).clamp(Vector2.ZERO, vp - _panel.size)


func _refresh_panel() -> void:
	if _panel == null:
		return
	_refreshing = true
	for c in _mode_buttons:
		_mode_buttons[c].button_pressed = c == hud.coop
		_mode_buttons[c].modulate = Color(1, 0.86, 0.82) if c == hud.coop else Color.WHITE
	for id in _checks:
		var cb: CheckBox = _checks[id]
		cb.button_pressed = hud.item_on(id)
		var note := ""
		if id == "standings" and hud.item_on(id) and hud.item_on("tower"):
			note = "  (when the tower is off)"
		cb.text = RaceHud.item_name(id) + note
		cb.modulate = Color(1, 0.86, 0.82) if id == selected else Color.WHITE
	_refreshing = false
	if selected == "":
		_sel_label.text = "Click an item to pick it"
	else:
		_sel_label.text = "%s  ·  %d%%" % [RaceHud.item_name(selected), roundi(hud.layout.scale_of(selected) * 100.0)]
