class_name CarAudio
extends Node2D
## The sound of one car. Follows the car's position for stereo panning.
##
## Engine: each car has an engine family (cross-plane V8, flat-six, V10 ...,
## see engine_profile()). The family's baked loops exist at many rpm bands, on
## throttle and on overrun. We play the two bands either side of the revs,
## crossfade them and nudge their pitch, and crossfade throttle against
## overrun. On top: rev limiter, gearshift cuts and blips (no exhaust pops or
## crackles), turbo whistle and wastegate flutter, supercharger whine, hybrid
## motor whine, straight-cut gearbox whine.
## Tyres and road: squeal (cornering past the grip peak), scrub (just under
## it), lock-up, wheelspin and the handbrake, road roar, kerbs, gravel,
## grass, wind, rain spray. Tyres only squeal on tarmac and kerbs: sliding
## on gravel, grass, dirt or mud makes that surface's own noise instead.
## Passing cars get a Doppler shift.

const SPEED_OF_SOUND := 343.0
## CarState.surface values (TrackData.Surface; audio doesn't depend on tracks).
const SURF_TRACK := 0
const SURF_KERB := 1
const SURF_GRASS := 2
const SURF_GRAVEL := 4
const SURF_RUNOFF := 5

var def: CarDefinition
var state: CarState
var is_local := false
var cylinders := 8
var profile: Dictionary = {}
var wetness := 0.0              ## 0..1 water on the track (set by RaceAudio)

var _bands: Array = []          ## [nominal, exact rpm]
var _eng := {}                  ## "on"/"off" -> [AudioStreamPlayer2D, AudioStreamPlayer2D]
var _eng_band := {}             ## player -> band index it is playing
var _layers := {}               ## name -> AudioStreamPlayer2D
var _shots: Array[AudioStreamPlayer2D] = []
var _shot_next := 0
var _throttle := 0.0
var _rpm := 1000.0
var _gear := 1
var _cut_t := 0.0               ## gearshift ignition cut left (s)
var _blip_t := 0.0              ## downshift blip left (s)
var _limiter_phase := 0.0
var _limiter_on := false
var _boost := 0.0
var _squeal_level := 0.0
var _scrub_level := 0.0
var _lock_level := 0.0
var _last_thr := 0.0
var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _doppler := 1.0
var _prev_pos := Vector2.ZERO
var _listener_vel := Vector2.ZERO


func setup(p_def: CarDefinition, p_state: CarState, p_local: bool) -> void:
	def = p_def
	state = p_state
	is_local = p_local
	cylinders = engine_cylinders(def)
	profile = engine_profile(def)
	_rng.seed = hash(def.id) ^ (1 if p_local else 2)
	_rpm = def.idle_rpm
	_gear = state.gear if state else 1
	_prev_pos = state.pos if state else Vector2.ZERO
	var all: Array = SoundBank.engine_bands(profile["voice"])
	if all.is_empty() and profile["voice"] != profile["family"]:
		profile["voice"] = profile["family"]
		all = SoundBank.engine_bands(profile["family"])
	# Only the bands this engine can reach (plus one above for the limiter).
	for b in all:
		_bands.append(b)
		if float(b[1]) > def.redline_rpm * 1.05:
			break
	for load in ["on", "off"]:
		_eng[load] = [_player(null, "Engine"), _player(null, "Engine")]
		for p in _eng[load]:
			_eng_band[p] = -1
	_layers["squeal"] = _player(SoundBank.get_sound("tyre_squeal"))
	_layers["lock"] = _player(SoundBank.get_sound("tyre_lock"))
	_layers["road"] = _player(SoundBank.get_sound("road_roar"))
	_layers["kerb"] = _player(SoundBank.get_sound("kerb"))
	_layers["gravel"] = _player(SoundBank.get_sound("gravel"))
	_layers["dirt"] = _player(SoundBank.get_sound("dirt"))
	_layers["grass"] = _player(SoundBank.get_sound("grass"))
	if is_local:
		_layers["scrub"] = _player(SoundBank.get_sound("tyre_scrub"))
		_layers["wind"] = _player(SoundBank.get_sound("wind"))
		_layers["spray"] = _player(SoundBank.get_sound("spray"))
	if profile["turbo"]:
		_layers["turbo"] = _player(SoundBank.get_sound("turbo_whistle"), "Engine")
	if profile["supercharged"]:
		_layers["supercharger"] = _player(SoundBank.get_sound("supercharger"), "Engine")
	if profile["hybrid"]:
		_layers["hybrid"] = _player(SoundBank.get_sound("hybrid_whine"), "Engine")
	if profile["gear_whine"]:
		_layers["gearbox"] = _player(SoundBank.get_sound("gear_whine"), "Engine")
	for i in 3:
		var s := AudioStreamPlayer2D.new()
		s.bus = "Engine"
		s.max_distance = 4000.0 if is_local else 900.0
		s.attenuation = 1.0 if is_local else 2.0
		s.panning_strength = 0.6
		add_child(s)
		_shots.append(s)


## Cylinder count from the car JSON ("engine": {"cylinders": 6}), else a
## guess from the car id (v8_, flat6_, i4_ ...), else 8.
static func engine_cylinders(d: CarDefinition) -> int:
	var eng: Dictionary = d.raw.get("engine", {})
	if eng.has("cylinders"):
		return int(eng["cylinders"])
	var re := RegEx.create_from_string("(?:v|flat|i|w|l)(\\d{1,2})")
	var m := re.search(d.id.to_lower())
	return int(m.get_string(1)) if m else 8


## What an engine sounds like: {family, turbo, supercharged, hybrid,
## gear_whine, limiter_hz}. A car can say it outright in its JSON:
##   "engine": {"sound": {"family": "v6_turbo", "hybrid": true}}
## otherwise it is worked out from the cylinders and the description
## ("twin-turbo", "flat-six", "Mid-engined ... V8" = flat-plane crank ...).
static func engine_profile(d: CarDefinition) -> Dictionary:
	var eng: Dictionary = d.raw.get("engine", {})
	var given: Dictionary = eng.get("sound", {})
	var text := (d.description + " " + d.id).to_lower()
	var cyl := engine_cylinders(d)
	var turbo := text.contains("turbo")
	var sc := text.contains("supercharg")
	var hybrid := text.contains("hybrid")
	var family := ""
	if cyl >= 12:
		family = "v12_na"
	elif cyl >= 10:
		family = "v10_na"
	elif cyl >= 8:
		var flat := text.contains("flat-plane") or (text.begins_with("mid-engined") and not text.contains("cross-plane"))
		family = ("v8_flat_" if flat else "v8_cross_") + ("turbo" if turbo else "na")
	elif cyl >= 5:
		if text.contains("flat-six") or text.contains("flat6") or text.contains("boxer"):
			family = "flat6_na"
		elif text.contains("straight-six") or text.contains("inline") or text.contains("i6"):
			family = "i6_turbo"
		else:
			family = "v6_turbo" if turbo else "v6_na"
	else:
		family = "i4_turbo"
	family = String(given.get("family", family))
	if not family in SoundBank.FAMILIES:
		family = "v8_cross_na"
	turbo = bool(given.get("turbo", turbo or family.ends_with("_turbo")))
	var p := {
		"family": family,
		# Which loops to play: recordings in samples/engines/<voice>/ when
		# there are any (the car's own "samples" set, else its family's),
		# otherwise the family's baked loops.
		"voice": String(given.get("samples", family)),
		"turbo": turbo,
		"supercharged": bool(given.get("supercharged", sc)),
		"hybrid": bool(given.get("hybrid", hybrid)),
		"gear_whine": bool(given.get("gear_whine", d.class_tag != "Road" and d.class_tag != "Safety" and d.class_tag != "")),
		# Limiter bounce: high-revving NA engines bang off it fast, turbos slower.
		"limiter_hz": float(given.get("limiter_hz", 9.0 if turbo else 14.0)),
	}
	return p


func _player(stream: AudioStream, bus := "Effects") -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.stream = stream
	p.bus = bus
	p.volume_db = -80.0
	p.max_distance = 4000.0 if is_local else 900.0
	p.attenuation = 1.0 if is_local else 2.0
	p.panning_strength = 0.6
	add_child(p)
	if stream and p.is_inside_tree():
		p.play(_rng.randf() * 0.5)
		p.stream_paused = true
	return p


## Sets a loop's level (0..1 linear) and pitch; pauses it when silent.
func _level(p: AudioStreamPlayer2D, level: float, pitch: float) -> void:
	if p == null or p.stream == null:
		return
	var on := level > 0.003
	if on:
		p.volume_db = linear_to_db(level)
		p.pitch_scale = clampf(pitch, 0.05, 8.0)
	if p.stream_paused == on:
		p.stream_paused = not on
	if on and not p.playing and p.is_inside_tree():
		p.play(_rng.randf() * 0.5)


## Where the listener is and how fast it moves, for the Doppler shift.
func set_listener(listen_at: Vector2, listen_vel: Vector2) -> void:
	_listener_vel = listen_vel
	if is_local:
		_doppler = 1.0
		return
	var to_l := listen_at - state.pos
	var dist := to_l.length()
	if dist < 1.0:
		_doppler = 1.0
		return
	var dir := to_l / dist
	var v_src := state.vel.dot(dir)          # towards the listener
	var v_lis := -_listener_vel.dot(dir)     # listener towards the source
	var target := clampf((SPEED_OF_SOUND + v_lis) / maxf(SPEED_OF_SOUND - v_src, 50.0), 0.6, 1.6)
	_doppler = lerpf(_doppler, target, 0.35)


## Called every frame with what the driver is doing (throttle 0..1).
func update(delta: float, throttle: float, volume_scale: float) -> void:
	if state == null:
		return
	_time += delta
	position = state.pos
	var vs := maxf(volume_scale, 0.0)
	var speed := state.speed()
	_throttle = lerpf(_throttle, throttle, 1.0 - exp(-14.0 * delta))
	_update_engine(delta, speed, vs)
	_update_tyres(delta, speed, vs)
	_last_thr = throttle


func _update_engine(delta: float, speed: float, vs: float) -> void:
	var idle := def.idle_rpm
	var red := def.redline_rpm
	# Revs the ear expects: the clutch slips off the line, and wheelspin flares them.
	var target := state.rpm
	if state.gear == 1 and speed < 12.0:
		target = maxf(target, lerpf(idle, minf(red * 0.62, idle * 3.5), _throttle))
	if state.wheelspin:
		target *= 1.06
	if state.gear <= 0:
		target = idle + (red - idle) * 0.25 * _throttle
	# Gearshifts: an upshift cuts the ignition for a moment, a downshift blips.
	if state.gear != _gear:
		if state.gear > _gear and _gear >= 1:
			_cut_t = 0.085
			_shot("shift", -12.0 if is_local else -16.0)
			if profile["turbo"] and _boost > 0.5:
				_shot("flutter", -10.0, _rng.randf_range(0.9, 1.1))
		elif state.gear < _gear and state.gear >= 1:
			_blip_t = 0.13
		_gear = state.gear
	_cut_t = maxf(_cut_t - delta, 0.0)
	_blip_t = maxf(_blip_t - delta, 0.0)
	var follow := 40.0 if target < _rpm else 18.0
	_rpm = lerpf(_rpm, target, 1.0 - exp(-follow * delta))
	# Rev limiter: on it with the pedal down, the ignition cuts in and out.
	_limiter_on = state.rpm >= red * 0.992 and _throttle > 0.55 and state.gear >= 1
	var mix := clampf(_throttle, 0.0, 1.0)
	var rpm := _rpm
	if _limiter_on:
		_limiter_phase += profile["limiter_hz"] * delta
		if _limiter_phase >= 1.0:
			_limiter_phase -= 1.0
		var cut := _limiter_phase < 0.4
		mix = 0.15 if cut else 1.0
		rpm = red * (0.985 - 0.03 * (1.0 - _limiter_phase))
	else:
		_limiter_phase = 0.0
	if _cut_t > 0.0:
		mix *= 0.08
	if _blip_t > 0.0:
		mix = maxf(mix, 0.75)
		rpm += (red - rpm) * 0.12 * (_blip_t / 0.13)
	# No exhaust pops or crackles on the overrun, limiter or downshifts: they
	# sounded like constant banging, so lifting off is just the overrun loop.
	var rev := clampf((rpm - idle) / maxf(red - idle, 1.0), 0.0, 1.0)
	# Band crossfade.
	var on_gain := lerpf(0.4, 1.0, rev) * vs
	var off_gain := lerpf(0.3, 0.55, rev) * vs
	var w := 0.0
	var lo := 0
	if _bands.size() > 0:
		lo = _bands.size() - 1
		for i in _bands.size() - 1:
			if rpm < float(_bands[i + 1][1]):
				lo = i
				break
		var hi := mini(lo + 1, _bands.size() - 1)
		var r0 := float(_bands[lo][1])
		var r1 := float(_bands[hi][1])
		w = clampf((rpm - r0) / maxf(r1 - r0, 1.0), 0.0, 1.0) if hi != lo else 0.0
		var gains := [cos(w * PI * 0.5), sin(w * PI * 0.5)]
		for load in ["on", "off"]:
			var lg: float = (on_gain * sqrt(mix)) if load == "on" else (off_gain * sqrt(1.0 - mix))
			_assign_bands(load, lo, hi)
			for p in _eng[load]:
				var b: int = _eng_band[p]
				var g: float = gains[0] if b == lo else (gains[1] if b == hi else 0.0)
				_level(p, lg * g, rpm / float(_bands[b][1]) * _doppler if b >= 0 else 1.0)
	# Turbo: boost builds with revs and throttle, with a little lag.
	if _layers.has("turbo"):
		var boost_target := _throttle * clampf((rpm - red * 0.35) / (red * 0.4), 0.0, 1.0)
		if _cut_t > 0.0 or _limiter_on:
			boost_target *= 0.6
		var rate := 3.0 if boost_target > _boost else 7.0
		var prev := _boost
		_boost = lerpf(_boost, boost_target, 1.0 - exp(-rate * delta))
		if prev > 0.6 and _throttle < 0.2 and _last_thr >= 0.2:
			_shot("flutter", -6.0 if is_local else -12.0, _rng.randf_range(0.9, 1.1))
		_level(_layers["turbo"], 0.32 * _boost * vs, (0.55 + 0.75 * _boost * (0.5 + 0.5 * rev)) * _doppler)
	if _layers.has("supercharger"):
		_level(_layers["supercharger"], 0.22 * (0.3 + 0.7 * _throttle) * (0.2 + 0.8 * rev) * vs,
			(0.4 + 2.2 * rpm / red) * _doppler)
	if _layers.has("hybrid"):
		var sp := clampf(state.speed() / 80.0, 0.0, 1.0)
		var drive := maxf(_throttle, clampf(-state.ax / 15.0, 0.0, 1.0))  # deploy or harvest
		_level(_layers["hybrid"], 0.28 * sp * (0.3 + 0.7 * drive) * vs, (0.3 + 1.6 * sp) * _doppler)
	if _layers.has("gearbox"):
		_level(_layers["gearbox"], 0.1 * rev * (0.4 + 0.6 * (1.0 - _throttle)) * vs, rpm / 60.0 * 12.0 / 1000.0 * _doppler)


## Keeps the two players of a load on bands lo and hi, swapping the stream
## only on a player that isn't already playing a band we need.
func _assign_bands(load: String, lo: int, hi: int) -> void:
	var players: Array = _eng[load]
	var want := [lo] if lo == hi else [lo, hi]
	var free := []
	for p in players:
		if _eng_band[p] in want:
			want.erase(_eng_band[p])
		else:
			free.append(p)
	for b in want:
		if free.is_empty():
			break
		var p: AudioStreamPlayer2D = free.pop_front()
		_eng_band[p] = b
		p.stream = SoundBank.engine_loop(profile["voice"], load == "on", int(_bands[b][0]))
		p.volume_db = -80.0
		if p.is_inside_tree():
			p.play(_rng.randf() * 0.3)
		p.stream_paused = false
	for p in free:
		_eng_band[p] = -1
		_level(p, 0.0, 1.0)


func _update_tyres(delta: float, speed: float, vs: float) -> void:
	var on_tarmac := state.surface == SURF_TRACK or state.surface == SURF_RUNOFF
	var kerb := state.surface == SURF_KERB
	var moving := clampf(speed / 8.0, 0.0, 1.0)
	var wet := clampf(wetness, 0.0, 1.0)
	# Loose earth under the car (rallycross and derby dirt, mud when wet).
	var loose := clampf(state.dirt, 0.0, 1.0) if (on_tarmac or kerb) else 0.0
	# Sideways: past the grip peak it squeals, just under it the tyres scrub.
	var lat := maxf(absf(state.slip_angle_rear) - 0.06, absf(state.slip_angle_front) - 0.085)
	var squeal := clampf(lat * 6.0, 0.0, 1.0)
	var scrub := clampf((maxf(absf(state.slip_angle_rear), absf(state.slip_angle_front)) - 0.03) * 12.0, 0.0, 1.0)
	# Lengthways: wheelspin, the handbrake, and heavy braking (locking without
	# ABS, ABS chatter with it).
	var lock := 0.0
	if state.wheelspin:
		lock = 0.55
	if state.handbrake:
		lock = maxf(lock, 0.7)
		squeal = maxf(squeal, 0.35)
	if state.ax < -11.0:
		var b := clampf((-state.ax - 11.0) / 9.0, 0.0, 1.0)
		if state.assist_abs:
			b *= 0.35 * (0.5 + 0.5 * sin(_time * TAU * 16.0))
		lock = maxf(lock, b)
	# Rubber only squeals on a hard surface: none on gravel, grass, dirt or mud.
	var grip_surface := (1.0 if (on_tarmac or kerb) else 0.0) * (1.0 - loose)
	var dry := 1.0 - 0.75 * wet  # wet tyres hiss more than they squeal
	_squeal_level = lerpf(_squeal_level, squeal * moving * grip_surface * dry, 1.0 - exp(-15.0 * delta))
	_scrub_level = lerpf(_scrub_level, scrub * (1.0 - squeal) * moving * grip_surface, 1.0 - exp(-12.0 * delta))
	_lock_level = lerpf(_lock_level, lock * moving * grip_surface * dry, 1.0 - exp(-20.0 * delta))
	var load := clampf(state.load_factor, 0.6, 1.4)
	_level(_layers["squeal"], 0.45 * _squeal_level * vs, (0.9 + 0.1 * _squeal_level + 0.05 * (load - 1.0)) * _doppler)
	_level(_layers["lock"], 0.55 * _lock_level * vs, (0.85 + 0.15 * clampf(speed / 60.0, 0.0, 1.0)) * _doppler)
	if _layers.has("scrub"):
		_level(_layers["scrub"], 0.3 * _scrub_level * vs, 0.9 + 0.3 * clampf(speed / 50.0, 0.0, 1.0))
	var sp := clampf(speed / 70.0, 0.0, 1.0)
	_level(_layers["road"], (0.22 if is_local else 0.12) * sp * grip_surface * vs, (0.6 + 0.7 * sp) * _doppler)
	# Kerb stripes ~0.9 m apart: the buzz rises with speed.
	var kerb_hz := speed / 0.9
	_level(_layers["kerb"], (0.55 * clampf(speed / 15.0, 0.0, 1.0) if kerb else 0.0) * vs, clampf(kerb_hz / 25.0, 0.3, 3.0))
	var gravel := state.surface == SURF_GRAVEL
	var grass := state.surface == SURF_GRASS
	_level(_layers["gravel"], (0.8 * clampf(speed / 20.0, 0.15, 1.0) if gravel and speed > 0.5 else 0.0) * vs,
		0.75 + 0.5 * clampf(speed / 40.0, 0.0, 1.0))
	_level(_layers["grass"], (0.6 * clampf(speed / 20.0, 0.1, 1.0) if grass and speed > 0.5 else 0.0) * vs,
		0.7 + 0.5 * clampf(speed / 40.0, 0.0, 1.0))
	# Dirt: a rolling rumble that grows into a scrabble of grit and clods
	# when the car slides, spins its wheels or locks them. Mud is lower.
	var churn := maxf(maxf(squeal, scrub * 0.5), lock)
	var dirt_vol := loose * (0.35 * clampf(speed / 25.0, 0.0, 1.0) + 0.5 * churn * moving) if speed > 0.5 else 0.0
	_level(_layers["dirt"], dirt_vol * vs, (0.7 + 0.45 * clampf(speed / 40.0, 0.0, 1.0) + 0.15 * churn) * (1.0 - 0.25 * wet) * _doppler)
	if _layers.has("wind"):
		_level(_layers["wind"], 0.16 * sp * sp * vs, 0.7 + 0.6 * sp)
	if _layers.has("spray"):
		_level(_layers["spray"], 0.4 * wet * sp * vs, 0.8 + 0.4 * sp)


func _shot(sound: String, db: float, pitch := 1.0) -> void:
	var p := _shots[_shot_next]
	_shot_next = (_shot_next + 1) % _shots.size()
	p.stream = SoundBank.get_sound(sound)
	p.volume_db = db + (0.0 if is_local else -4.0)
	p.pitch_scale = pitch * _doppler
	if p.is_inside_tree():
		p.play()


func silence() -> void:
	for load in _eng:
		for p in _eng[load]:
			p.volume_db = -80.0
	for k in _layers:
		_layers[k].volume_db = -80.0
