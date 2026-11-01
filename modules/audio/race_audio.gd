class_name RaceAudio
extends Node2D
## All the race sounds: your car up close, the nearest rivals around you,
## crashes and contacts, start lights, laps and the chequered flag.
## Add it to the race scene and call update() every frame and on_events()
## with the race events. Only listens; never changes the race.

const RIVAL_VOICES := 3          ## rivals heard at once (the nearest ones)
const RIVAL_RANGE := 250.0       ## metres

var _cars: Array = []            ## CarState
var _defs: Array = []            ## CarDefinition
var _local := -1
var _voices: Dictionary = {}     ## car index -> CarAudio
var _fx: Array[AudioStreamPlayer2D] = []
var _fx_next := 0
var _beeper: AudioStreamPlayer
var _listener: AudioListener2D
var _last_bump := {}             ## car index -> time, so a scrape isn't a machine gun
var _time := 0.0


func setup(cars: Array, defs: Array, local_car: int) -> void:
	_cars = cars
	_defs = defs
	_local = local_car
	_listener = AudioListener2D.new()
	add_child(_listener)
	_listener.make_current()
	for i in 8:
		var p := AudioStreamPlayer2D.new()
		p.bus = "Effects"
		p.max_distance = 1500.0
		p.attenuation = 1.5
		add_child(p)
		_fx.append(p)
	_beeper = AudioStreamPlayer.new()
	_beeper.bus = "Effects"
	add_child(_beeper)
	if _local >= 0:
		_voices[_local] = _make_voice(_local)


func _make_voice(i: int) -> CarAudio:
	var v := CarAudio.new()
	add_child(v)
	v.setup(_defs[i], _cars[i], i == _local)
	return v


## listen_at: where the ears are (the camera). local_throttle: your pedal.
## zoom_out: 0 close .. 1 whole track; far out the rivals fade so it isn't noise.
func update(delta: float, listen_at: Vector2, local_throttle: float, zoom_out: float) -> void:
	_time += delta
	_listener.global_position = listen_at if _local < 0 else _cars[_local].pos
	# Which rivals are close enough to hear?
	var near := []
	var ref: Vector2 = _listener.global_position
	for i in _cars.size():
		if i == _local:
			continue
		var d: float = (_cars[i] as CarState).pos.distance_to(ref)
		if d < RIVAL_RANGE:
			near.append([d, i])
	near.sort()
	var keep := {}
	for k in mini(near.size(), RIVAL_VOICES):
		keep[near[k][1]] = true
	for i in _voices.keys():
		if i != _local and not keep.has(i):
			_voices[i].queue_free()
			_voices.erase(i)
	for i in keep:
		if not _voices.has(i):
			_voices[i] = _make_voice(i)
	for i in _voices:
		var c: CarState = _cars[i]
		var thr := local_throttle if i == _local else _guess_throttle(c)
		var vol := 1.0 if i == _local else 0.55 * (1.0 - 0.7 * zoom_out)
		_voices[i].update(delta, thr, vol)


## Rivals: we don't get their pedals, so guess from how they accelerate.
func _guess_throttle(c: CarState) -> float:
	return clampf(0.3 + c.ax / 4.0, 0.0, 1.0)


func on_events(evs: Array) -> void:
	for e in evs:
		match e["type"]:
			"countdown": _beep("beep")
			"green": _beep("beep_go")
			"lap":
				if e["car"] == _local:
					_beep("chime", -8.0)
			"finished":
				if e["car"] == _local:
					_beep("chime", -2.0)
			"barrier_impact":
				_impact(e["car"], float(e["speed"]), _cars[e["car"]].pos)
			"collision":
				var strength := float(e["impulse"]) / 700.0  # about the closing speed in m/s
				var pos: Vector2 = e.get("pos", _cars[e["a"]].pos)
				_impact(e["a"], strength, pos, e["b"])


func _impact(car: int, speed: float, pos: Vector2, other := -1) -> void:
	if speed < 1.5:
		return
	var key := car * 100 + other
	if _time - float(_last_bump.get(key, -9.0)) < 0.25:
		return
	_last_bump[key] = _time
	var big := speed > 8.0
	var p := _fx[_fx_next]
	_fx_next = (_fx_next + 1) % _fx.size()
	p.stream = SoundBank.get_sound("crash" if big else "bump")
	p.global_position = pos
	var near_me := car == _local or other == _local
	p.volume_db = linear_to_db(clampf(speed / 15.0, 0.25, 1.0)) + (0.0 if near_me else -6.0)
	p.pitch_scale = randf_range(0.85, 1.1)
	p.play()


func _beep(name: String, db := -4.0) -> void:
	_beeper.stream = SoundBank.get_sound(name)
	_beeper.volume_db = db
	_beeper.play()
