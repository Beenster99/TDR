extends Node
## Autoload "Sound" (audio module): menu sounds and one-off effects, plus the
## two audio buses (Effects for the race, UI for menus). Any module above
## audio may call Sound.ui("ui_select") and so on.

const POOL := 6
var _players: Array[AudioStreamPlayer] = []
var _next := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for bus in ["Effects", "UI"]:
		if AudioServer.get_bus_index(bus) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus)
			AudioServer.set_bus_send(idx, "Master")
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("UI"), -6.0)
	# A gentle limiter on the master bus so a big crash never clips.
	if AudioServer.get_bus_effect_count(0) == 0:
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = -0.5
		AudioServer.add_bus_effect(0, lim)
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "UI"
		add_child(p)
		_players.append(p)


## Plays a short sound by SoundBank name, e.g. "ui_move", "ui_select", "beep".
func ui(name: String, volume_db := 0.0, pitch := 1.0) -> void:
	if _players.is_empty():
		return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	var menu := MenuSounds.get_sound(name)
	p.stream = menu if menu else SoundBank.get_sound(name)
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


## The intro's GT3 pass-by (a recorded sample if one is in
## modules/audio/samples/, else made in code). Plays on the UI bus.
func passby(volume_db := 0.0) -> void:
	ui("gt3_passby", volume_db)


## Gives every button under a node click and focus sounds (menus, results).
func wire_buttons(root: Node) -> void:
	for c in root.find_children("*", "BaseButton", true, false):
		var b := c as BaseButton
		if b.has_meta("sound_wired"):
			continue
		b.set_meta("sound_wired", true)
		b.focus_entered.connect(_on_focus)
		b.pressed.connect(_on_press.bind(b))


func _on_focus() -> void:
	ui("ui_move")


func _on_press(b: BaseButton) -> void:
	ui("ui_back" if b is Button and (b as Button).text in ["Back", "Leave", "Quit", "Main menu"] else "ui_select")
