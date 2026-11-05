extends Node
## Records the pit wall's radio as the driver hears it in the game (the
## crackle, static and the race engineer's voice, through the game's own
## audio buses) into a WAV, for checking the voice by ear:
##   godot --headless --path . res://tests/radio_sample.tscn -- <out.wav> [male|female]
## Plays a few calls and a full pit stop plan with numbers.

const MESSAGES := [
	"Box, box. Box this lap.",
	"Box, box. Box this lap. Four new race slicks. Pressures: front left 27.5, rear right 26.5 psi. Front downforce up 1 to 6. 64 litres of fuel. We fix the damage.",
	"Rain is coming, be ready for a tyre call.",
	"Car behind is closing. Defend.",
	"Plan for the next stop. New intermediates, fronts. Fuel to the end. Driver change at this stop.",
]

var _rec: AudioEffectRecord
var _out := "radio_sample.wav"
var _t := 0.0
var _started := false


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args())
	if a.size() > 0:
		_out = str(a[0])
	GameData.prefs["radio_voice"] = "female" if a.size() > 1 and str(a[1]) == "female" else true
	_rec = AudioEffectRecord.new()
	AudioServer.add_bus_effect(0, _rec)
	_rec.set_recording_active(true)
	for m in MESSAGES:
		print(m, " -> ", RadioPhrases.compose(m, Sound._radio.recorded_voice()).size(), " clips")
		Sound.radio(m)


func _process(delta: float) -> void:
	_t += delta
	if _t > 1.0 and not Sound._radio.busy() and not _started:
		_started = true
		get_tree().create_timer(0.8).timeout.connect(_save)
	if _t > 120.0:
		_save()


func _save() -> void:
	_rec.set_recording_active(false)
	var wav := _rec.get_recording()
	if wav == null:
		print("FAIL nothing recorded (no audio mixing?)")
		get_tree().quit(1)
		return
	wav.save_to_wav(_out)
	print("saved %s (%.1f s)" % [_out, wav.get_length()])
	get_tree().quit(0)
