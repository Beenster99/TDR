class_name PauseMenu
extends Control
## The in-race pause menu: Esc (or Start on a controller) during a race.
## Resume, restart the race, settings, quit to the main menu, quit to the
## desktop. Offline the race stops while it's open (the race scene pauses the
## tree; this menu keeps running). Online the race carries on for everyone:
## the menu is an overlay over the live race, the player's car gets no input
## while it's open, and only the host can restart (for everyone).
##
## Settings here are the player's own game settings only (SettingsScreen with
## in_race): no garage, and the settings that change how the car drives are
## locked until the next race. Race settings and car setups aren't in it.
##
## Up / down (D-pad, stick, arrows) choose, A / Enter picks, B / Esc / Start
## go back to the race. Restart and the quit buttons act straight away: no
## "are you sure?" popup (the user asked for none, 2026-11-03).

signal resumed
signal restart_requested
signal quit_to_menu_requested
signal quit_to_desktop_requested
## Online host: end the race and take everyone back to the lobby.
signal end_race_requested
## Settings > Gameplay > Edit HUD layout, in a race: the race scene opens the
## HUD editor over the race itself.
signal edit_hud_requested

const ACCENT := Color(0.94, 0.26, 0.2)

## What this race allows (set by setup):
var online := false
var is_host := false
## Restart is allowed: offline, or the online host, never in a championship.
var can_restart := false
## Why restart isn't allowed ("" when it is), shown on the greyed button.
var restart_blocked := ""
## The player drives a car here (the HUD editor needs one).
var can_edit_hud := false

var settings: SettingsScreen = null
var _panel: PanelContainer
var _shade: ColorRect
var _buttons := {}           ## id -> Button
var _note: Label


## opts: {online, host, can_restart, restart_blocked, can_edit_hud}
func setup(opts: Dictionary) -> void:
	online = bool(opts.get("online", false))
	is_host = bool(opts.get("host", false))
	can_restart = bool(opts.get("can_restart", false))
	restart_blocked = str(opts.get("restart_blocked", ""))
	can_edit_hud = bool(opts.get("can_edit_hud", false))
	process_mode = Node.PROCESS_MODE_ALWAYS   # offline the tree is paused under it
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	visible = false
	_build()


func _build() -> void:
	_shade = ColorRect.new()
	# Offline the race is frozen behind it; online keep the race in view.
	_shade.color = Color(0.02, 0.025, 0.03, 0.35 if online else 0.6)
	_shade.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_shade)
	_shade.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.065, 0.075, 0.94)
	sb.border_color = ACCENT
	sb.border_width_top = 4
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(28)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_panel.add_child(v)
	var title := Label.new()
	title.text = "MENU" if online else "PAUSED"
	title.add_theme_font_size_override("font_size", 40)
	v.add_child(title)
	var sub := Label.new()
	sub.text = "The race carries on for everyone. Your car coasts while this is open." if online \
		else "The race waits while this is open."
	sub.modulate = Color(1, 0.86, 0.6) if online else Color(1, 1, 1, 0.6)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size = Vector2(420, 0)
	v.add_child(sub)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	v.add_child(gap)
	for id in PauseOptions.button_ids(online, is_host):
		var b := Button.new()
		b.text = PauseOptions.label_for(id, online, is_host)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(420, 48)
		b.add_theme_font_size_override("font_size", 20)
		b.pressed.connect(_on_pressed.bind(id))
		v.add_child(b)
		_buttons[id] = b
	if not can_restart:
		_buttons["restart"].disabled = true
		_buttons["restart"].focus_mode = FOCUS_NONE
		if restart_blocked != "":
			_buttons["restart"].text += "  ·  " + restart_blocked
	_note = Label.new()
	_note.modulate = Color(1, 1, 1, 0.4)
	_note.add_theme_font_size_override("font_size", 13)
	InputPrompt.live(_note, func(): _note.text = InputPrompt.fill(
		"{ui_accept}: choose  ·  " + InputPrompt.keys(["ui_cancel", "back_to_menu"]) + ": back to the race"))
	v.add_child(_note)
	Sound.wire_buttons(_panel)


func open() -> void:
	if visible:
		return
	visible = true
	_panel.visible = true
	_place.call_deferred()
	_buttons["resume"].grab_focus.call_deferred()
	Sound.ui("ui_select")


func resume() -> void:
	if not visible:
		return
	_close_settings()
	visible = false
	resumed.emit()


func _place() -> void:
	_panel.reset_size()
	_panel.position = ((get_viewport_rect().size - _panel.size) * 0.5).round()


func _on_pressed(id: String) -> void:
	match id:
		"resume":
			resume()
		"settings":
			_open_settings()
		"restart", "lobby", "menu", "desktop":
			visible = false
			match id:
				"restart": restart_requested.emit()
				"lobby": end_race_requested.emit()
				"menu": quit_to_menu_requested.emit()
				"desktop": quit_to_desktop_requested.emit()


func _open_settings() -> void:
	if settings:
		return
	_panel.visible = false
	_shade.visible = false
	settings = SettingsScreen.new()
	settings.in_race = true
	if can_edit_hud:
		settings.edit_hud = func():
			resume()
			edit_hud_requested.emit()
	add_child(settings)
	settings.open(null)
	settings.closed.connect(_on_settings_closed)


func _on_settings_closed() -> void:
	settings = null
	if not visible:
		return
	_panel.visible = true
	_shade.visible = true
	_buttons["settings"].grab_focus.call_deferred()


func _close_settings() -> void:
	if settings:
		var s := settings
		settings = null
		s.closed.disconnect(_on_settings_closed)
		s.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or settings != null:
		return
	if event.is_action_pressed("back_to_menu") or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		resume()
