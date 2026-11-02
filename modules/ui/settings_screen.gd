class_name SettingsScreen
extends Control
## Settings: Gameplay, Graphics, Sound, Garage and Debug. Options come from
## GameData.settings_catalog (any module adds its own with
## GameData.register_setting), so this screen never needs to know them.
## Every change is applied and saved at once (GameData.set_pref).
##
## Controller: up/down picks a row, left/right changes it, LB/RB (or Q/E)
## switch section, B leaves. The section list on the left takes focus too.

signal closed

const TITLES := {"gameplay": "Gameplay", "graphics": "Graphics", "sound": "Sound", "garage": "Garage", "debug": "Debug"}
const ACCENT := Color(0.94, 0.26, 0.2)

var profile: TeamProfile
var _section := "gameplay"
var _tabs := {}               ## section -> Button
var _list: VBoxContainer
var _help: Label
var _title: Label
## Garage actions are handed in by the menu (it owns the garage screen).
var open_garage: Callable


func open(p_profile: TeamProfile, section := "gameplay") -> void:
	profile = p_profile
	_build()
	_show_section(section)


func _build() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.035, 0.04, 0.82)
	add_child(shade)
	shade.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	add_child(margin)
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 90)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 70)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 18)
	margin.add_child(outer)
	_title = Label.new()
	_title.text = "SETTINGS"
	_title.add_theme_font_size_override("font_size", 44)
	outer.add_child(_title)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 36)
	cols.size_flags_vertical = SIZE_EXPAND_FILL
	outer.add_child(cols)
	var tabs := VBoxContainer.new()
	tabs.custom_minimum_size = Vector2(260, 0)
	tabs.add_theme_constant_override("separation", 6)
	cols.add_child(tabs)
	for id in GameData.SECTIONS:
		var b := Button.new()
		b.text = TITLES.get(id, id.capitalize())
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(260, 52)
		b.add_theme_font_size_override("font_size", 22)
		b.pressed.connect(_show_section.bind(id, true))
		tabs.add_child(b)
		_tabs[id] = b
	var spacer := Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	tabs.add_child(spacer)
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(260, 48)
	back.pressed.connect(_close)
	tabs.add_child(back)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 14)
	cols.add_child(right)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	_help = Label.new()
	_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help.custom_minimum_size = Vector2(0, 64)
	_help.modulate = Color(1, 1, 1, 0.72)
	right.add_child(_help)
	var keys := Label.new()
	keys.text = "Up/down: choose  ·  Left/right: change  ·  LB/RB or Q/E: section  ·  B/Esc: back.  Changes are saved straight away."
	keys.modulate = Color(1, 1, 1, 0.4)
	keys.add_theme_font_size_override("font_size", 13)
	right.add_child(keys)


func _show_section(id: String, focus_list := false) -> void:
	_section = id
	for k in _tabs:
		_tabs[k].button_pressed = k == id
		_tabs[k].modulate = Color(1, 0.86, 0.82) if k == id else Color.WHITE
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	if id == "garage":
		_build_garage()
	for e in GameData.settings_in(id):
		_list.add_child(_row(e))
	if id == "debug":
		_build_debug()
	if id == "sound":
		_action("Play test sound", func(): Sound.passby())
	_help.text = ""
	Sound.wire_buttons(self)
	for b in _list.find_children("*", "BaseButton", true, false):
		(b as Control).focus_entered.connect(_on_row_focus.bind(b))
	_link_focus()
	if focus_list:
		_focus_first_row.call_deferred()
	else:
		_tabs[id].grab_focus.call_deferred()


func _row(e: Dictionary) -> Stepper:
	var st: Stepper
	var v = GameData.prefs.get(e["key"], e["default"])
	if e["kind"] == "number":
		st = Stepper.numeric(e["label"], e["min"], e["max"], e["step"], v, e.get("suffix", ""))
		st.loop_options = false
	else:
		st = Stepper.choice(e["label"], e["options"], v)
	st.custom_minimum_size = Vector2(720, 46)
	st.size_flags_horizontal = SIZE_EXPAND_FILL
	st.value_column = 300.0
	st.focus_entered.connect(st.queue_redraw)
	st.focus_exited.connect(st.queue_redraw)
	st.set_meta("help", e.get("help", ""))
	st.value_changed.connect(func(nv): GameData.set_pref(e["key"], nv))
	return st


func _action(text: String, cb: Callable, help := "") -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(720, 44)
	b.set_meta("help", help)
	b.pressed.connect(cb)
	_list.add_child(b)
	return b


func _note(text: String, colour := Color(1, 1, 1, 0.8)) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = colour
	_list.add_child(l)
	return l


## A button that asks once more before doing something you can't undo.
func _confirm_action(text: String, cb: Callable, help := "") -> Button:
	var b := _action(text, func(): pass, help)
	b.pressed.connect(func():
		if b.text == text:
			b.text = text + "  ·  sure? press again"
		else:
			b.text = text
			cb.call())
	return b


func _build_garage() -> void:
	var owned := profile.owned_ids() if profile else []
	_note("Team budget  %s   ·   %d car%s in your garage" % [UpgradeCatalog.format_money(profile.money if profile else 0),
		owned.size(), "" if owned.size() == 1 else "s"], Color(0.55, 0.95, 0.6))
	for id in owned:
		var def: CarDefinition = GameData.cars.get(id)
		if def == null:
			continue
		var rd := 0
		for l in profile.levels(id).values():
			rd += int(l)
		_note("   %s  (%s)   %s%s" % [def.display_name, def.class_tag, Units.power(UpgradeCatalog.stats(def, profile.levels(id))["power_kw"]),
			"   ·   R&D %d" % rd if rd > 0 else "   ·   stock"], Color(0.85, 0.92, 1))
	if owned.is_empty():
		_note("   No cars bought yet. Buy one in the garage; any car can still be raced stock.", Color(1, 1, 1, 0.55))
	if open_garage.is_valid():
		_action("Open the garage", func():
			_close()
			open_garage.call(), "Buy cars, fit upgrades and paint liveries.")
	_action("Save a backup of my garage", func():
		var err := _copy(profile.path, profile.path.get_basename() + "_backup.json")
		_help.text = "Backup saved." if err == OK else "Could not save the backup (error %d)." % err,
		"Copies your garage, money and liveries to a backup file you can restore later.")
	_confirm_action("Restore my garage from the backup", func():
		var backup := profile.path.get_basename() + "_backup.json"
		if not FileAccess.file_exists(backup):
			_help.text = "There is no backup yet."
			return
		_copy(backup, profile.path)
		var fresh := TeamProfile.load_or_new(profile.path)
		profile.money = fresh.money
		profile.cars = fresh.cars
		profile.ledger = fresh.ledger
		_show_section("garage", true)
		_help.text = "Garage restored from the backup.",
		"Puts back the garage from your last backup.")
	var where := ProjectSettings.globalize_path(profile.path) if profile else ""
	_note("Your garage is saved automatically after every change, in %s" % where, Color(1, 1, 1, 0.45))


func _build_debug() -> void:
	_action("Open the save folder", func(): OS.shell_open(ProjectSettings.globalize_path("user://")),
		"Settings, garage, seasons, setups and race logs are kept here.")
	_confirm_action("Reset all settings to default", func():
		GameData.reset_settings()
		_show_section("debug", true)
		_help.text = "Settings reset.")
	_note("Version %s  ·  Godot %s  ·  %s  ·  %s" % [ProjectSettings.get_setting("application/config/version", "dev"),
		Engine.get_version_info().get("string", ""), RenderingServer.get_video_adapter_name(), OS.get_name()], Color(1, 1, 1, 0.5))


static func _copy(from: String, to: String) -> Error:
	if not FileAccess.file_exists(from):
		return ERR_FILE_NOT_FOUND
	var data := FileAccess.get_file_as_bytes(from)
	var f := FileAccess.open(to, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(data)
	return OK


func _on_row_focus(b: Control) -> void:
	var h := str(b.get_meta("help", ""))
	_help.text = h


## Left from a row goes to the section list, right from the list to the rows.
func _link_focus() -> void:
	var rows := _list.find_children("*", "BaseButton", true, false)
	if rows.is_empty():
		return
	for k in _tabs:
		_tabs[k].focus_neighbor_right = _tabs[k].get_path_to(rows[0])


func _focus_first_row() -> void:
	for b in _list.find_children("*", "BaseButton", true, false):
		if (b as Control).is_visible_in_tree():
			(b as Control).grab_focus()
			return


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()
		return
	var dir := 0
	if event is InputEventKey and event.pressed and not event.echo:
		dir = {KEY_Q: -1, KEY_E: 1}.get(event.keycode, 0)
	elif event is InputEventJoypadButton and event.pressed:
		dir = {JOY_BUTTON_LEFT_SHOULDER: -1, JOY_BUTTON_RIGHT_SHOULDER: 1}.get(event.button_index, 0)
	if dir != 0:
		var i := GameData.SECTIONS.find(_section)
		_show_section(GameData.SECTIONS[posmod(i + dir, GameData.SECTIONS.size())])
		get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()
