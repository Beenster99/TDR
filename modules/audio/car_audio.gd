class_name CarAudio
extends Node2D
## The sound of one car: engine (throttle and overrun loops crossfaded),
## tyre squeal and grass rumble. Follows the car's position for stereo panning.

var def: CarDefinition
var state: CarState
var is_local := false
var cylinders := 8
var _on: AudioStreamPlayer2D
var _off: AudioStreamPlayer2D
var _squeal: AudioStreamPlayer2D
var _rumble: AudioStreamPlayer2D
var _throttle := 0.0
var _squeal_level := 0.0


func setup(p_def: CarDefinition, p_state: CarState, p_local: bool) -> void:
	def = p_def
	state = p_state
	is_local = p_local
	cylinders = engine_cylinders(def)
	_on = _player("engine_on")
	_off = _player("engine_off")
	_squeal = _player("squeal")
	_rumble = _player("rumble")


## Cylinder count from the car JSON ("engine": {"cylinders": 6}), else a
## guess from the car id (v8_, flat6_, i4_ ...), else 8.
static func engine_cylinders(d: CarDefinition) -> int:
	var eng: Dictionary = d.raw.get("engine", {})
	if eng.has("cylinders"):
		return int(eng["cylinders"])
	var re := RegEx.create_from_string("(?:v|flat|i|w|l)(\\d{1,2})")
	var m := re.search(d.id.to_lower())
	return int(m.get_string(1)) if m else 8


func _player(sound: String) -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.stream = SoundBank.get_sound(sound)
	p.bus = "Effects"
	p.volume_db = -80.0
	p.max_distance = 4000.0 if is_local else 900.0
	p.attenuation = 1.0 if is_local else 2.0
	p.panning_strength = 0.6
	add_child(p)
	p.play(randf() * 1.5)
	return p


## Called every frame with what the driver is doing (throttle 0..1).
func update(delta: float, throttle: float, volume_scale: float) -> void:
	if state == null:
		return
	position = state.pos
	_throttle = lerpf(_throttle, throttle, 1.0 - exp(-12.0 * delta))
	var firing_hz := state.rpm / 60.0 * cylinders * 0.5
	var pitch := clampf(firing_hz / SoundBank.ENGINE_BASE_HZ, 0.25, 6.0)
	_on.pitch_scale = pitch
	_off.pitch_scale = pitch
	var rev := clampf((state.rpm - def.idle_rpm) / maxf(def.redline_rpm - def.idle_rpm, 1.0), 0.0, 1.0)
	var base := -10.0 + 8.0 * rev
	var mix := clampf(_throttle, 0.0, 1.0)
	var vs := linear_to_db(maxf(volume_scale, 0.0001))
	_on.volume_db = base + linear_to_db(maxf(mix, 0.02)) + vs
	_off.volume_db = base - 5.0 + linear_to_db(maxf(1.0 - mix, 0.02)) + vs
	# Tyres: squeal grows with slip past the grip peak, wheelspin or locking.
	var speed := state.speed()
	var slip := maxf(absf(state.slip_angle_rear) - 0.07, absf(state.slip_angle_front) - 0.1) * 6.0
	if state.wheelspin:
		slip = maxf(slip, 0.6)
	if state.ax < -9.0:
		slip = maxf(slip, (absf(state.ax) - 9.0) * 0.15)
	var on_tarmac := state.surface <= 1 or state.surface == 5  # 5 = paved run-off (TrackData.Surface.RUNOFF)
	var target := clampf(slip, 0.0, 1.0) * clampf(speed / 8.0, 0.0, 1.0) * (1.0 if on_tarmac else 0.0)
	_squeal_level = lerpf(_squeal_level, target, 1.0 - exp(-15.0 * delta))
	_squeal.volume_db = linear_to_db(maxf(_squeal_level * 0.7, 0.0001)) + vs
	_squeal.pitch_scale = 0.9 + 0.25 * _squeal_level
	var rough := 0.0 if on_tarmac else clampf(speed / 25.0, 0.0, 1.0)
	_rumble.volume_db = linear_to_db(maxf(rough * 0.9, 0.0001)) + vs
	_rumble.pitch_scale = 0.7 + 0.5 * clampf(speed / 40.0, 0.0, 1.0)


func silence() -> void:
	for p in [_on, _off, _squeal, _rumble]:
		p.volume_db = -80.0
