class_name PodiumCeremony
extends Control
## The podium ceremony, when the player finishes in the top three: the race
## fades to black and the podium comes up (graphics PodiumView, in its own
## 3D world), the crowd cheers, ticker tape falls, the three drivers wave and
## lift their trophies, then the champagne: the player shakes their bottle,
## pops the cork and sprays the other drivers, the mechanics and the
## photographers. Then it fades to black again and the results come up.
##
## Controls (the device touched last is named in the prompts):
##   aim:   mouse (the stream lands under the pointer), or W A S D / arrows /
##          the left stick (crew_up / down / left / right)
##   spray: hold left mouse, Space / Enter, RT or A (crew_gun); the first
##          spray pops the cork
##   shake: right mouse, G / X, pad X (crew_grab), or waggle the stick
##   skip to the results: Esc, B or Start, or click the button
##
## The race scene calls start() and listens for `covered` (the screen is
## black: hide the race) and `finished` (black again: show the results).

signal covered
signal finished

const ACCENT := Color(0.94, 0.26, 0.2)
const GOLD := Color(1.0, 0.8, 0.3)
const DIM := Color(1, 1, 1, 0.6)
const FADE_S := 0.7
const INTRO_S := 2.6
const TROPHY_S := 3.2
## Once every bottle is empty, seconds before the results come up on their own.
const AFTER_EMPTY_S := 6.0
## However it goes, the results come up after this long.
const MAX_S := 75.0
const AIM_YAW_SPEED := 1.7     ## rad/s at full stick
const AIM_PITCH_SPEED := 1.1
## Places, by podium position, for the cards.
const PLACE := ["1ST", "2ND", "3RD"]

var view: PodiumView
var autoplay := false          ## tests: the player's bottle sprays on its own
var _vp: SubViewport
var _box: SubViewportContainer
var _black: ColorRect
var _hud: Control
var _tags: Array[Label] = []
var _banner: Label
var _sub: Label
var _hint: Label
var _pressure: ProgressBar
var _fill: ProgressBar
var _soaked: Label
var _bottle_box: Control
var _marker: Control
var _skip: Button
var _flash: Label
var _flash_t := 0.0
var _t := 0.0
var _state := 0                ## 0 fading in, 1 on, 2 fading out, 3 done
var _fade := 0.0
var _mouse_aim := false
var _mouse_pos := Vector2.ZERO
var _last_x := 0.0
var _empty_t := -1.0
var _spray_snd: AudioStreamPlayer
var _crowd_snd: AudioStreamPlayer
var _cheer_boost := 0.0
var _drivers: Array = []
var _player_slot := -1
var _hint_t := 0.0


## drivers: by podium position, [{name, car, colour, is_me}]; player_slot:
## which one the player drives (-1 none). info: {track, title, seed}.
func start(drivers: Array, player_slot: int, info := {}) -> void:
	_drivers = drivers
	_player_slot = player_slot
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_box = SubViewportContainer.new()
	_box.stretch = true
	_box.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_box.mouse_filter = MOUSE_FILTER_IGNORE
	_box.visible = false
	add_child(_box)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.handle_input_locally = false
	_box.add_child(_vp)
	view = PodiumView.new()
	_vp.add_child(view)
	view.setup(drivers, player_slot, str(info.get("track", "")), int(info.get("seed", 7)))
	view.cork_popped.connect(_on_cork)
	view.soaked.connect(_on_soaked)
	view.process_mode = Node.PROCESS_MODE_DISABLED   # until the race has faded out
	_build_hud(info)
	_black = ColorRect.new()
	_black.color = Color(0, 0, 0, 0)
	_black.mouse_filter = MOUSE_FILTER_IGNORE
	_black.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(_black)
	_sounds()


func _build_hud(info: Dictionary) -> void:
	_hud = Control.new()
	_hud.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_hud.mouse_filter = MOUSE_FILTER_IGNORE
	_hud.visible = false
	add_child(_hud)
	var top := VBoxContainer.new()
	top.set_anchors_and_offsets_preset(PRESET_TOP_WIDE)
	top.offset_top = 18
	top.mouse_filter = MOUSE_FILTER_IGNORE
	_hud.add_child(top)
	_banner = _label(str(info.get("title", "PODIUM")), 40, Color.WHITE)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(_banner)
	_sub = _label("", 18, GOLD)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(_sub)
	if _player_slot >= 0:
		_sub.text = "You finished %s" % ["first: you won!", "second", "third"][_player_slot]
	# A name card over each driver.
	for p in _drivers.size():
		var d: Dictionary = _drivers[p]
		var l := _label("%s  %s\n%s" % [PLACE[p], str(d.get("name", "")), str(d.get("car", ""))], 17,
			GOLD if bool(d.get("is_me", false)) else Color.WHITE)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.size = Vector2(320, 50)
		_hud.add_child(l)
		_tags.append(l)
	# The flash in the middle: POP!, SOAKED!
	_flash = _label("", 34, GOLD)
	_flash.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_flash.set_anchors_and_offsets_preset(PRESET_CENTER_BOTTOM)
	_flash.offset_top = -150
	_flash.offset_bottom = -100
	_flash.offset_left = -300
	_flash.offset_right = 300
	_hud.add_child(_flash)
	# The bottle: pressure, how much is left, how many you've soaked.
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.06, 0.72)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchors_and_offsets_preset(PRESET_BOTTOM_LEFT)
	panel.offset_left = 24
	panel.offset_bottom = -24
	panel.offset_top = -170
	panel.offset_right = 300
	panel.mouse_filter = MOUSE_FILTER_IGNORE
	panel.visible = _player_slot >= 0
	_hud.add_child(panel)
	_bottle_box = panel
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)
	col.add_child(_label("CHAMPAGNE", 16, GOLD))
	col.add_child(_label("Pressure", 13, DIM))
	_pressure = _bar(Color(1.0, 0.55, 0.15))
	col.add_child(_pressure)
	col.add_child(_label("Bottle", 13, DIM))
	_fill = _bar(Color(0.95, 0.88, 0.5))
	col.add_child(_fill)
	_soaked = _label("Soaked: 0", 18, Color.WHITE)
	col.add_child(_soaked)
	# Controls along the bottom.
	_hint = _label("", 18, Color.WHITE)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE)
	_hint.offset_top = -56
	_hint.offset_bottom = -26
	_hud.add_child(_hint)
	InputPrompt.live(_hint, _refresh_hint)
	_skip = Button.new()
	_skip.focus_mode = FOCUS_NONE   # A and Enter spray; the button is for the mouse
	_skip.add_theme_font_size_override("font_size", 18)
	_skip.set_anchors_and_offsets_preset(PRESET_BOTTOM_RIGHT)
	_skip.offset_left = -270
	_skip.offset_top = -74
	_skip.offset_right = -24
	_skip.offset_bottom = -24
	_skip.pressed.connect(finish)
	_hud.add_child(_skip)
	InputPrompt.live(_skip, func(): _skip.text = "Results  (%s)" % InputPrompt.key("ui_cancel"))
	# Where the stream will land.
	_marker = _Marker.new()
	_marker.mouse_filter = MOUSE_FILTER_IGNORE
	_marker.size = Vector2(36, 36)
	_marker.visible = false
	_hud.add_child(_marker)


class _Marker extends Control:
	func _draw() -> void:
		var c := size * 0.5
		draw_arc(c, 14.0, 0.0, TAU, 32, Color(1, 0.85, 0.35, 0.9), 2.5, true)
		draw_circle(c, 3.0, Color(1, 0.85, 0.35, 0.9))


func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = MOUSE_FILTER_IGNORE
	return l


func _bar(col: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.min_value = 0.0
	b.max_value = 1.0
	b.show_percentage = false
	b.custom_minimum_size = Vector2(240, 12)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.12)
	bg.set_corner_radius_all(3)
	var fg := StyleBoxFlat.new()
	fg.bg_color = col
	fg.set_corner_radius_all(3)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	b.mouse_filter = MOUSE_FILTER_IGNORE
	return b


func _refresh_hint() -> void:
	if _hint == null or view == null:
		return
	var aim_txt := InputPrompt.pick("mouse or " + InputPrompt.keys(["crew_up", "crew_left", "crew_down", "crew_right"], " "), "left stick")
	var b := view.player_bottle()
	if b == null:
		_hint.text = ""
		return
	if view.phase != PodiumView.Phase.CHAMPAGNE:
		_hint.text = "Here comes the champagne..."
	elif b.fill <= 0.0:
		_hint.text = "Bottle empty!  %s: on to the results" % InputPrompt.pick("Enter / Esc", InputPrompt.key("ui_cancel"))
	elif b.corked:
		_hint.text = "Shake it up: %s  ·  Pop the cork: %s  ·  Aim: %s" % [InputPrompt.pick("right click / " + InputPrompt.key("crew_grab"),
			InputPrompt.key("crew_grab") + " or waggle the stick"), InputPrompt.pick("left click / " + InputPrompt.key("crew_gun"),
			InputPrompt.key("crew_gun")), aim_txt]
	else:
		_hint.text = "Spray: hold %s  ·  More fizz: %s  ·  Aim: %s" % [InputPrompt.pick("left click / " + InputPrompt.key("crew_gun"),
			InputPrompt.key("crew_gun")), InputPrompt.pick("right click / " + InputPrompt.key("crew_grab"), InputPrompt.key("crew_grab")), aim_txt]


func _sounds() -> void:
	_spray_snd = AudioStreamPlayer.new()
	_spray_snd.stream = SoundBank.get_sound("champagne_spray")
	_spray_snd.volume_db = -60.0
	add_child(_spray_snd)
	_crowd_snd = AudioStreamPlayer.new()
	_crowd_snd.stream = SoundBank.get_sound("crowd_cheer")
	_crowd_snd.volume_db = -60.0
	add_child(_crowd_snd)


# --- Each frame --------------------------------------------------------------

func _process(delta: float) -> void:
	if view == null:
		return
	_t += delta
	match _state:
		0:
			_fade = minf(1.0, _fade + delta / FADE_S)
			_black.color.a = _fade
			if _fade >= 1.0:
				_state = 1
				_t = 0.0
				_box.visible = true
				_hud.visible = true
				view.process_mode = Node.PROCESS_MODE_INHERIT
				view.set_phase(PodiumView.Phase.INTRO)
				_spray_snd.play()
				_crowd_snd.play()
				covered.emit()
		1:
			_fade = maxf(0.0, _fade - delta / FADE_S)
			_black.color.a = _fade
			_run(delta)
		2:
			_fade = minf(1.0, _fade + delta / FADE_S)
			_black.color.a = _fade
			_crowd_snd.volume_db = lerpf(-8.0, -60.0, _fade)
			_spray_snd.volume_db = -60.0
			if _fade >= 1.0:
				_state = 3
				_crowd_snd.stop()
				_spray_snd.stop()
				view.process_mode = Node.PROCESS_MODE_DISABLED
				_box.visible = false
				_hud.visible = false
				finished.emit()


func _run(delta: float) -> void:
	if view.phase == PodiumView.Phase.INTRO and _t > INTRO_S:
		view.set_phase(PodiumView.Phase.TROPHY)
		_cheer_boost = 1.0
		_refresh_hint()
	elif view.phase == PodiumView.Phase.TROPHY and _t > INTRO_S + TROPHY_S:
		view.set_phase(PodiumView.Phase.CHAMPAGNE)
		_refresh_hint()
	if view.phase == PodiumView.Phase.CHAMPAGNE:
		_control(delta)
		_hint_t -= delta
		if _hint_t <= 0.0:
			_hint_t = 0.3
			_refresh_hint()
		if view.all_empty():
			if _empty_t < 0.0:
				_empty_t = _t
				_refresh_hint()
			elif _t - _empty_t > AFTER_EMPTY_S:
				finish()
	if _t > MAX_S:
		finish()
	# Sounds: the crowd, louder when someone gets soaked; the spray's hiss.
	_cheer_boost = maxf(0.0, _cheer_boost - delta * 0.6)
	_crowd_snd.volume_db = lerpf(-60.0, -10.0 + 5.0 * _cheer_boost, minf(1.0, _t / 1.2))
	var s := view.spray_level()
	_spray_snd.volume_db = -60.0 if s <= 0.01 else linear_to_db(clampf(s / 2.0, 0.05, 1.0)) - 6.0
	_spray_snd.pitch_scale = 0.9 + 0.2 * clampf(s, 0.0, 1.0)
	# Name cards over the drivers' heads.
	for p in _tags.size():
		var at := view.screen_pos(view.driver_head(p))
		_tags[p].position = at - Vector2(_tags[p].size.x * 0.5, 54)
	if _flash_t > 0.0:
		_flash_t -= delta
		_flash.modulate.a = clampf(_flash_t / 0.4, 0.0, 1.0)
	# The bottle panel.
	var b := view.player_bottle()
	if b:
		_pressure.value = b.pressure
		_fill.value = b.fill
		_soaked.text = "Soaked: %d" % view.player_soaked
		var show_marker := view.phase == PodiumView.Phase.CHAMPAGNE and b.fill > 0.0
		_marker.visible = show_marker
		if show_marker:
			_marker.position = view.screen_pos(view.landing_point()) - _marker.size * 0.5
			_marker.queue_redraw()


## The player's bottle from the mouse, keys and pad.
func _control(delta: float) -> void:
	var b := view.player_bottle()
	if b == null:
		return
	if autoplay:
		_autoplay(b, delta)
		return
	var x := Input.get_axis("crew_left", "crew_right")
	var y := Input.get_axis("crew_down", "crew_up")
	if absf(x) > 0.15 or absf(y) > 0.15:
		_mouse_aim = false
		# The picture looks at the crowd from the front: stick right turns the stream right.
		view.aim(b.yaw + x * AIM_YAW_SPEED * delta, b.pitch + y * AIM_PITCH_SPEED * delta)
	elif _mouse_aim:
		view.aim_at(view.world_under(_to_viewport(_mouse_pos)))
	# Waggling the stick hard from side to side shakes the bottle.
	if absf(x) > 0.7 and signf(x) != signf(_last_x) and absf(_last_x) > 0.7:
		view.shake(0.07)
	if absf(x) > 0.7:
		_last_x = x
	var spray := Input.is_action_pressed("crew_gun") or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var was_corked := b.corked
	view.set_spray(spray)
	if was_corked != b.corked:
		_refresh_hint()


## Tests and screenshots: shake, pop and spray along the crowd.
func _autoplay(b: PodiumView.Bottle, delta: float) -> void:
	var k := _t - INTRO_S - TROPHY_S
	if k < 1.2:
		if fmod(k, 0.2) < delta:
			view.shake(0.15)
		return
	view.aim_at(Vector3(sin(k * 0.8) * 4.5, 1.6, 3.8))
	view.set_spray(fmod(k, 3.0) < 2.4)
	if fmod(k, 3.0) > 2.4 and fmod(k, 0.2) < delta:
		view.shake(0.12)


func _to_viewport(p: Vector2) -> Vector2:
	# The container stretches the viewport over the whole screen.
	if _box.size.x <= 0.0 or _box.size.y <= 0.0:
		return p
	return (p - _box.global_position) * Vector2(_vp.size) / _box.size


func _input(event: InputEvent) -> void:
	if _state != 1:
		if _state == 0 or _state == 2:
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		_mouse_pos = event.position
		if (event as InputEventMouseMotion).relative.length() > 2.0:
			_mouse_aim = true
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		view.shake(0.14)
		_refresh_hint()
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("back_to_menu"):
		finish()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("crew_grab"):
		view.shake(0.14)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("crew_gun") and _empty_t >= 0.0:
		finish()
		get_viewport().set_input_as_handled()


func _on_cork(slot: int) -> void:
	Sound.ui("cork_pop", -2.0 if slot == _player_slot else -8.0, randf_range(0.92, 1.1))
	if slot == _player_slot:
		_say("POP!")
	_cheer_boost = maxf(_cheer_boost, 0.6)


func _on_soaked(who: String, by_player: bool) -> void:
	_cheer_boost = minf(1.5, _cheer_boost + 0.35)
	if by_player:
		var n := view.player_soaked
		_say("SOAKED %s!" % who.to_upper() if who != "mechanic" and who != "photographer" else
			("SOAKED A PHOTOGRAPHER!" if who == "photographer" else "SOAKED! x%d" % n))


func _say(text: String) -> void:
	_flash.text = text
	_flash_t = 1.2
	_flash.modulate.a = 1.0


## Off to the results (once).
func finish() -> void:
	if _state != 1:
		return
	_state = 2


## Seconds since the podium came up (-1 while fading in, or once it's over).
func elapsed() -> float:
	return _t if _state == 1 else -1.0


func is_running() -> bool:
	return _state < 3
