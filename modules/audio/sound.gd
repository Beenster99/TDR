extends Node
## Autoload "Sound" (audio module): menu sounds and one-off effects, plus the
## audio buses (Effects for tyres, road and crashes; Engine for engines,
## turbos and exhaust pops; UI for menus). Any module above
## audio may call Sound.ui("ui_select") and so on.

const POOL := 6
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _radio: RadioVoice


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for bus in ["Effects", "Engine", "UI", "Radio"]:
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
	_radio = RadioVoice.new()
	add_child(_radio)


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


## Reads a team radio message out loud over the radio: the click and squelch,
## static under the race engineer's recorded voice (or the computer's), then
## the squelch tail. Queues behind a
## message still being read. With no voice on the machine (or the read-out
## off in Settings > Sound) only the crackle plays.
func radio(text: String) -> void:
	if _radio:
		_radio.say(text)


func radio_stop() -> void:
	if _radio:
		_radio.stop()


## True when this machine has a voice to read radio messages out with.
func radio_can_speak() -> bool:
	return _radio != null and _radio.can_speak()


## True when this message will be read out loud (the voice is on and can say
## every word of it), so it needn't be shown on screen too.
func radio_will_say(text: String) -> bool:
	return _radio != null and _radio.will_say(text)


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
