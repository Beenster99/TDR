class_name RadioVoice
extends Node
## Reads team radio out loud like a race radio: the click and squelch as the
## channel opens, static under the voice, the squelch tail as it closes. The
## voice is the computer's own text-to-speech (Windows SAPI, macOS, Linux
## speech-dispatcher), so it plays outside Godot's buses; the crackle plays
## on the Radio bus (Settings > Sound > Team radio). Without a voice on the
## machine, or with the read-out switched off, only the crackle plays.
## Messages queue up and are read one after another. Owned by Sound.

const OPEN_S := 0.22                 ## crackle before the voice starts
const WORDS_PER_S := 2.9             ## for the static when the voice can't say when it's done
const QUEUE_MAX := 4

var _open: AudioStreamPlayer
var _bed: AudioStreamPlayer
var _close: AudioStreamPlayer
var _queue: Array[String] = []
var _speaking := false
var _utterance := -1
var _time_left := 0.0                ## seconds until the read-out is taken to be over
var _start_in := -1.0                ## seconds until the voice starts
var _text := ""
var _voice := ""
var _tts_ready := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_open = _player("radio_open")
	_bed = _player("radio_static")
	_close = _player("radio_close")
	_tts_ready = _setup_tts()


func _player(sound: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Radio" if AudioServer.get_bus_index("Radio") >= 0 else "UI"
	p.stream = SoundBank.get_sound(sound)
	add_child(p)
	return p


func _setup_tts() -> bool:
	if DisplayServer.get_name() == "headless" or not ProjectSettings.get_setting("audio/general/text_to_speech", false):
		return false
	var voices := DisplayServer.tts_get_voices_for_language("en")
	if voices.is_empty():
		voices = DisplayServer.tts_get_voices_for_language(OS.get_locale_language())
	if voices.is_empty():
		return false
	# A British voice if there is one (it's a British pit wall), else the first English one.
	_voice = voices[0]
	for v in DisplayServer.tts_get_voices():
		if str(v.get("id", "")) in voices and str(v.get("language", "")).to_lower().replace("-", "_").begins_with("en_gb"):
			_voice = str(v["id"])
			break
	DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_ENDED, _on_ended)
	DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_CANCELED, _on_ended)
	return true


## True when this machine can read messages out (has a text-to-speech voice).
func can_speak() -> bool:
	return _tts_ready


func busy() -> bool:
	return _speaking or not _queue.is_empty()


## Queue a message to be read out over the radio.
func say(text: String) -> void:
	text = text.strip_edges()
	if text == "":
		return
	if _queue.size() >= QUEUE_MAX:
		_queue.pop_front()
	_queue.append(text)
	if not _speaking:
		_next()


## Stop reading and clear the queue.
func stop() -> void:
	_queue.clear()
	if _tts_ready and _speaking:
		DisplayServer.tts_stop()
	_finish(false)


func _next() -> void:
	if _queue.is_empty():
		return
	_text = _queue.pop_front()
	_speaking = true
	_open.play()
	_bed.volume_db = -14.0
	_bed.play()
	_start_in = OPEN_S
	_time_left = OPEN_S + 0.6 + _text.split(" ", false).size() / WORDS_PER_S


func _process(delta: float) -> void:
	if not _speaking:
		return
	if _start_in >= 0.0:
		_start_in -= delta
		if _start_in < 0.0 and _tts_ready and _voice_on():
			_utterance += 1
			# A touch quick and flat, like a race engineer on the radio.
			DisplayServer.tts_speak(_text, _voice, _tts_volume(), 1.0, 1.08, _utterance, false)
			# The engine says when it's done; this is only a safety net.
			_time_left += 6.0
	_time_left -= delta
	if _time_left <= 0.0:
		_finish(true)


func _on_ended(id: int) -> void:
	if id == _utterance and _speaking and _start_in < 0.0:
		_finish(true)


func _finish(tail: bool) -> void:
	if not _speaking:
		return
	_speaking = false
	_bed.stop()
	if tail:
		_close.play()
	if not _queue.is_empty():
		# A little gap between messages, then the next one.
		get_tree().create_timer(0.35, true).timeout.connect(_next)


func _voice_on() -> bool:
	return bool(GameData.prefs.get("radio_voice", true))


## The voice's loudness (0-100) from the master and team radio volumes.
func _tts_volume() -> int:
	var v := float(GameData.prefs.get("vol_master", 100)) * float(GameData.prefs.get("vol_radio", 90)) / 100.0
	return clampi(int(v), 0, 100)
