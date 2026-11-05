class_name RadioVoice
extends Node
## Reads team radio out loud like a race radio: the click and squelch as the
## channel opens, static under the voice, the squelch tail as it closes.
## The voice is a recorded race engineer (RadioPhrases: neural voice clips
## baked by tools/radio_voice_bake.py, male or female, Settings > Sound >
## Radio voice), played on the Radio bus with the crackle. A message the
## clips can't say, or the "Computer voice" choice, uses the computer's own
## text-to-speech (Windows SAPI, macOS, Linux speech-dispatcher), which plays
## outside Godot's buses. With the voice off only the crackle plays.
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
var _speech: AudioStreamPlayer
var _clips: Array = []               ## recorded clips still to play: [[path, s, pause after], ...]
var _gap := -1.0                     ## seconds until the next clip
var _serial := 0                     ## counts messages, so a late timer can't end the next one


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_open = _player("radio_open")
	_bed = _player("radio_static")
	_close = _player("radio_close")
	_speech = _player("")
	_speech.finished.connect(_on_clip_done)
	_tts_ready = _setup_tts()


func _player(sound: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Radio" if AudioServer.get_bus_index("Radio") >= 0 else "UI"
	if sound != "":
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


## True when messages are read out loud: the voice is on, and it's a
## recorded voice or this machine has a text-to-speech voice.
func can_speak() -> bool:
	var v := recorded_voice()
	if v != "":
		return not RadioPhrases.bank(v).is_empty() or _tts_ready
	return _voice_on() and _tts_ready


## True when this message will be heard: the recorded voice has every word
## of it, or the computer's voice can read it.
func will_say(text: String) -> bool:
	var v := recorded_voice()
	if v != "" and RadioPhrases.can_say(text, v):
		return true
	return _voice_on() and _tts_ready


## The recorded voice picked in Settings (a RadioPhrases voice), or "" for
## the computer's voice or none.
func recorded_voice() -> String:
	match GameData.prefs.get("radio_voice", true):
		true:
			return "engineer_male"
		"female":
			return "engineer_female"
	return ""


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
	_clips.clear()
	_speech.stop()
	_finish(false)


func _next() -> void:
	if _queue.is_empty():
		return
	_text = _queue.pop_front()
	_speaking = true
	_serial += 1
	_open.play()
	_bed.volume_db = -14.0
	_bed.play()
	_start_in = OPEN_S
	_clips = RadioPhrases.compose(_text, recorded_voice()) if recorded_voice() != "" else []
	if not _clips.is_empty():
		# Ends when the last clip has played; this is only a safety net.
		var total := 0.0
		for c in _clips:
			total += float(c[1]) + float(c[2])
		_time_left = OPEN_S + total + 3.0
	else:
		_time_left = OPEN_S + 0.6 + _text.split(" ", false).size() / WORDS_PER_S


func _process(delta: float) -> void:
	if not _speaking:
		return
	if _start_in >= 0.0:
		_start_in -= delta
		if _start_in < 0.0 and not _clips.is_empty():
			_play_clip()
		elif _start_in < 0.0 and _tts_ready and _voice_on():
			_utterance += 1
			# A touch quick and flat, like a race engineer on the radio.
			DisplayServer.tts_speak(_text, _voice, _tts_volume(), 1.0, 1.08, _utterance, false)
			# The engine says when it's done; this is only a safety net.
			_time_left += 6.0
	if _gap >= 0.0:
		_gap -= delta
		if _gap < 0.0:
			_play_clip()
	_time_left -= delta
	if _time_left <= 0.0:
		_finish(true)


func _play_clip() -> void:
	if _clips.is_empty() or not _speaking:
		return
	var c: Array = _clips[0]
	_speech.stream = load(str(c[0]))
	_speech.play()


func _on_clip_done() -> void:
	if _clips.is_empty() or not _speaking:
		return
	var c: Array = _clips.pop_front()
	if _clips.is_empty():
		var serial := _serial
		get_tree().create_timer(0.12, true).timeout.connect(func():
			if serial == _serial:
				_finish(true))
	else:
		_gap = float(c[2])


func _on_ended(id: int) -> void:
	if id == _utterance and _speaking and _start_in < 0.0:
		_finish(true)


func _finish(tail: bool) -> void:
	if not _speaking:
		return
	_speaking = false
	_gap = -1.0
	_clips.clear()
	_bed.stop()
	if tail:
		_close.play()
	if not _queue.is_empty():
		# A little gap between messages, then the next one.
		get_tree().create_timer(0.35, true).timeout.connect(_next)


func _voice_on() -> bool:
	var v = GameData.prefs.get("radio_voice", true)
	return v is String or bool(v)


## The voice's loudness (0-100) from the master and team radio volumes.
func _tts_volume() -> int:
	var v := float(GameData.prefs.get("vol_master", 100)) * float(GameData.prefs.get("vol_radio", 90)) / 100.0
	return clampi(int(v), 0, 100)
