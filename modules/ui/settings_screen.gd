class_name SettingsScreen
extends Control
## Settings: Gameplay, Controller, Graphics, Sound, Garage and Debug. Options come from
## GameData.settings_catalog (any module adds its own with
## GameData.register_setting), so this screen never needs to know them.
## Every change is applied and saved at once (GameData.set_pref).
##
## Controller: up/down picks a row, left/right changes it, LB/RB (or Q/E)
## switch section, B leaves. The section list on the left takes focus too.
##
## Controller also lists every control with two keyboard and two controller
## bindings: pick one, then press the new key or button (InputSetup turns it
## into a binding; saved in GameData.prefs["controls"]). A binding is cleared
## at once, no questions: right-click it, or with it picked press Delete /
## Backspace on the keyboard or X (Square) on the controller (CLEAR_BUTTON).

signal closed

const TITLES := {"gameplay": "Gameplay", "controller": "Controller", "graphics": "Graphics", "sound": "Sound", "garage": "Garage", "debug": "Debug"}
const ACCENT := Color(0.94, 0.26, 0.2)

var profile: TeamProfile
var _section := "gameplay"
var _tabs := {}               ## section -> Button
var _list: VBoxContainer
var _help: Label
var _title: Label
## Garage actions are handed in by the menu (it owns the garage screen).
var open_garage: Callable
## Waiting for a new key or button: {action, kind, slot, index, from, until}.
var _listen := {}
const LISTEN_TIME := 6.0
## The controller button that clears the picked binding (A picks, B leaves).
const CLEAR_BUTTON := InputSetup.CLEAR_BUTTON
## The HUD layout editor's preview, while it's open.
var _hud_preview: Control = null
## In a race (the pause menu, PauseMenu): only the player's own game settings.
## The garage is left out, the settings that change how the car drives are
## locked until the next race (PauseOptions.LOCKED_IN_RACE), and Edit HUD layout opens the
## editor over the race itself (edit_hud; left out when it isn't set).
var in_race := false
var edit_hud: Callable


## The sections this screen shows.
func sections() -> Array:
	return PauseOptions.RACE_SECTIONS if in_race else GameData.SECTIONS


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
	for id in sections():
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
	InputPrompt.live(keys, func():
		keys.text = InputPrompt.fill(InputPrompt.pick("↑↓: choose  ·  ←→: change  ·  Q / E: section  ·  {ui_cancel}: back.",
			"D-pad ↑↓: choose  ·  ←→: change  ·  %s / %s: section  ·  {ui_cancel}: back." % [
				InputPrompt.button(JOY_BUTTON_LEFT_SHOULDER), InputPrompt.button(JOY_BUTTON_RIGHT_SHOULDER)]))
		keys.text += "  Changes are saved straight away."
		if in_race:
			keys.text += "  Race settings and car settings are locked during a race.")
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
	if id == "controller":
		_build_controls()
	if id == "debug":
		_build_debug()
	if id == "gameplay" and in_race and edit_hud.is_valid():
		_action("Edit HUD layout", func():
			_close()
			edit_hud.call(),
			"Move, resize, hide and bring back each part of the race screen, over this race. Also F2 during a race.")
	elif id == "gameplay" and not in_race:
		_action("Edit HUD layout", _open_hud_editor,
			"Move, resize, hide and bring back each part of the race screen (timing tower, map, speed, tyres...) with the mouse and keyboard, over a live preview race. Also F2 during a race. Co-op drivers (sharing a car with team mates) have their own layout, minimal by default.")
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
	if in_race and e["key"] in PauseOptions.LOCKED_IN_RACE:
		st.disabled = true
		st.set_meta("help", (str(e.get("help", "")) + "\n\n" + PauseOptions.LOCKED_HELP).strip_edges())
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
	_action("Restore my garage from the backup", func():
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


# --- Controller: key and button bindings --------------------------------------

func _controls() -> Dictionary:
	var c = GameData.prefs.get("controls", {})
	return c if c is Dictionary else {}


func _build_controls() -> void:
	var hint := _note("", Color(1, 1, 1, 0.6))
	InputPrompt.live(hint, func(): hint.text = clear_hint())
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	for h in [["", 250], ["Keyboard", 306], ["Controller", 306]]:
		var l := Label.new()
		l.text = h[0]
		l.custom_minimum_size = Vector2(h[1], 0)
		l.modulate = Color(1, 0.86, 0.82)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		head.add_child(l)
	_list.add_child(head)
	var overrides := _controls()
	for r in InputSetup.REBINDABLE:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := Label.new()
		l.text = r[1]
		l.custom_minimum_size = Vector2(250, 0)
		l.clip_text = true
		row.add_child(l)
		var lists := {"keys": InputSetup.keys_of(overrides, r[0]), "pad": InputSetup.pads_of(overrides, r[0])}
		for kind in ["keys", "pad"]:
			for slot in InputSetup.SLOTS:
				var v = lists[kind][slot] if slot < lists[kind].size() else null
				var b := Button.new()
				b.text = InputSetup.describe(kind, v)
				b.custom_minimum_size = Vector2(150, 40)
				b.clip_text = true
				b.set_meta("help", "%s: %s %d is %s. Press it, then the new %s." % [r[1],
					"key" if kind == "keys" else "controller button", slot + 1,
					b.text if v != null else "not set", "key" if kind == "keys" else "button, trigger or stick direction"])
				b.set_meta("help_extra", true)   # + how to clear it, for the device in use
				b.pressed.connect(_start_listen.bind(r[0], kind, slot, b))
				b.gui_input.connect(_on_binding_input.bind(r[0], kind, slot, b))
				row.add_child(b)
		_list.add_child(row)
	_action("Reset controls to default", func():
		GameData.set_pref("controls", {})
		_show_section("controller", true)
		_help.text = "Controls reset to default.",
		"Puts every key and controller button back as it came.")


## How to pick and clear a binding, for the device in use.
static func clear_hint() -> String:
	return InputPrompt.pick("Click a binding, then press the new key or controller button.  Right-click a binding (or pick it and press Delete) to clear it.",
		"Pick a binding with %s, then press the new button or key.  %s clears the picked binding." % [
			InputPrompt.button(JOY_BUTTON_A), InputPrompt.button(CLEAR_BUTTON)])


## The ways to clear a binding without listening: right-click it, or press
## Delete / Backspace or the controller's clear button while it is picked.
func _on_binding_input(event: InputEvent, action: String, kind: String, slot: int, b: Button) -> void:
	if not _listen.is_empty():
		return
	if InputSetup.is_clear_event(event):
		b.accept_event()
		_clear(action, kind, slot, b)


func _clear(action: String, kind: String, slot: int, b: Button) -> void:
	var list: Array = InputSetup.keys_of(_controls(), action) if kind == "keys" else InputSetup.pads_of(_controls(), action)
	var buttons := _list.find_children("*", "BaseButton", true, false)
	_listen = {"action": action, "kind": kind, "slot": slot, "index": buttons.find(b)}
	if slot >= mini(list.size(), InputSetup.SLOTS):
		_end_listen("Nothing to clear.")
		return
	_bind(null)


func _start_listen(action: String, kind: String, slot: int, b: Button) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var buttons := _list.find_children("*", "BaseButton", true, false)
	# A short pause first, so the press that picked this row isn't taken as the new binding.
	_listen = {"action": action, "kind": kind, "slot": slot, "index": buttons.find(b), "from": now + 0.2,
		"until": now + LISTEN_TIME, "button": b}
	b.text = "press a key..." if kind == "keys" else "press a button..."
	_help.text = "Press the new %s now (%d s).  Delete clears it, Esc cancels." % [
		"key" if kind == "keys" else "controller button, trigger or stick direction", int(LISTEN_TIME)]


func _process(_dt: float) -> void:
	if not _listen.is_empty() and Time.get_ticks_msec() / 1000.0 > float(_listen["until"]):
		_end_listen("No change.")


func _input(event: InputEvent) -> void:
	if _listen.is_empty():
		return
	if event is InputEventMouseMotion:
		return
	get_viewport().set_input_as_handled()
	if Time.get_ticks_msec() / 1000.0 < float(_listen["from"]):
		return
	if event is InputEventMouseButton and event.pressed:
		_end_listen("No change.")
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var code: int = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		if code == KEY_ESCAPE:
			_end_listen("No change.")
			return
		if code == KEY_BACKSPACE or code == KEY_DELETE:
			_bind(null)
			return
	var got := InputSetup.binding_from_event(event)
	if got.is_empty() or got["kind"] != _listen["kind"]:
		return
	_bind(got["value"])


func _bind(value) -> void:
	var l := _listen
	var overrides := InputSetup.with_binding(_controls(), l["action"], l["kind"], l["slot"], value)
	var also := InputSetup.used_by(overrides, l["action"], l["kind"], value) if value != null else []
	GameData.set_pref("controls", overrides)
	_end_listen((InputSetup.cleared_message(overrides, l["action"], l["kind"]) if value == null
		else "Set to %s." % InputSetup.describe(l["kind"], value))
		+ ("  Also used for: %s." % ", ".join(also) if not also.is_empty() else ""))


func _end_listen(message: String) -> void:
	var index := int(_listen.get("index", -1))
	_listen = {}
	_show_section("controller", false)
	var buttons := _list.find_children("*", "BaseButton", true, false)
	if index >= 0 and index < buttons.size():
		(buttons[index] as Control).grab_focus.call_deferred()
	_help.text = message
	_set_help_later.call_deferred(message)


## Focusing the row shows its own help; put the result back over it.
func _set_help_later(message: String) -> void:
	_help.text = message


func _build_debug() -> void:
	_action("Open the save folder", func(): OS.shell_open(ProjectSettings.globalize_path("user://")),
		"Settings, garage, seasons, setups and race logs are kept here.")
	if not in_race:   # it would reset the locked ones too
		_action("Reset all settings to default", func():
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
	if b.get_meta("help_extra", false):
		h += "  " + InputPrompt.pick("Right-click or Delete clears it.", "%s clears it." % InputPrompt.button(CLEAR_BUTTON))
	_help.text = InputPrompt.fill(h)   # a setting's help can name controls: {crew_grab}


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


## Opens the HUD layout editor over a little preview race, hiding this screen
## until it's closed.
func _open_hud_editor() -> void:
	if _hud_preview != null:
		return
	var kids := []
	for c in get_children():
		if c is CanvasItem and c.visible:
			c.visible = false
			kids.append(c)
	_hud_preview = HudEditor.open_preview(self)
	_hud_preview.tree_exited.connect(func():
		_hud_preview = null
		for c in kids:
			if is_instance_valid(c):
				c.visible = true
		_show_section("gameplay", true))


func _unhandled_input(event: InputEvent) -> void:
	if _hud_preview != null:
		return
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
		var list := sections()
		var i := list.find(_section)
		_show_section(list[posmod(i + dir, list.size())])
		get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()
