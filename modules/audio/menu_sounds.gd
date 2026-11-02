class_name MenuSounds
extends RefCounted
## Menu clicks, made in code: short, dry "switch" clicks (a sharp transient,
## a little filtered noise and a tiny body knock) instead of beeps, plus the
## intro's pass-by. Sound.ui() asks here first, then SoundBank.
##
## A recorded sample wins over the synthesised one: drop
## modules/audio/samples/<name>.wav (or .ogg) in and it's used instead.

const RATE := 44100
const SAMPLE_DIR := "res://modules/audio/samples/"
const NAMES := ["ui_move", "ui_select", "ui_back", "ui_tick", "gt3_passby"]

static var _cache: Dictionary = {}


## The sound for a menu name, or null if it isn't a menu sound.
static func get_sound(name: String) -> AudioStream:
	if not name in NAMES:
		return null
	if not _cache.has(name):
		_cache[name] = _sample(name)
		if _cache[name] == null:
			_cache[name] = _make(name)
	return _cache[name]


static func _sample(name: String) -> AudioStream:
	for ext in ["ogg", "wav"]:
		var p: String = SAMPLE_DIR + name + "." + ext
		if ResourceLoader.exists(p):
			return load(p) as AudioStream
	return null


static func _make(name: String) -> AudioStreamWAV:
	match name:
		"ui_move": return _click(0.55, 5200.0, 0.0, 0.018, 3)      # light tick as focus moves
		"ui_select": return _click(1.0, 3400.0, 210.0, 0.045, 5)   # firm click
		"ui_back": return _click(0.85, 2300.0, 150.0, 0.04, 7)     # lower click
		"ui_tick": return _click(0.45, 6500.0, 0.0, 0.012, 9)      # stepper notch
		"gt3_passby": return _passby()
	return null


## One click: a bright filtered noise burst (the contact), a short resonant
## ping at `tone` Hz (the switch), and an optional low knock (the body).
static func _click(vol: float, tone: float, knock_hz: float, length_s: float, seed: int) -> AudioStreamWAV:
	var n := int(RATE * length_s)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var hp_prev := 0.0
	var hp := 0.0
	for i in n:
		var t := float(i) / RATE
		var noise := rng.randf_range(-1.0, 1.0)
		hp = 0.86 * (hp + noise - hp_prev)   # high-pass: crisp, not hissy
		hp_prev = noise
		var contact := hp * exp(-t * 900.0)
		var ping := sin(TAU * tone * t) * exp(-t * 420.0) * 0.5
		var knock := sin(TAU * knock_hz * t) * exp(-t * 110.0) * 0.55 if knock_hz > 0.0 else 0.0
		out[i] = tanh((contact * 0.9 + ping + knock) * 1.3) * vol * 0.8
	return _wav(out, false)


## A GT3 car flat out past the camera: a flat-six at high revs (firing
## harmonics plus exhaust rasp), one upshift, Doppler pitch drop, loudness
## and brightness peaking as it passes, panned left to right. Stereo.
static func _passby() -> AudioStreamWAV:
	var length := 4.6
	var n := int(RATE * length)
	var pass_t := 1.9            # closest at this time
	var speed := 72.0            # m/s (about 260 km/h)
	var closest := 9.0           # metres from the camera
	var c := 343.0
	var cylinders := 6.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 2402
	var out := PackedFloat32Array()
	out.resize(n * 2)
	var phase := 0.0
	var lp := 0.0
	var rasp := 0.0
	var bright := 0.0
	for i in n:
		var t := float(i) / RATE
		var x := (t - pass_t) * speed                 # along the road, + = gone past
		var dist := sqrt(x * x + closest * closest)
		var v_radial := speed * x / dist              # + = moving away
		var doppler := c / (c + v_radial)
		# Revs climb, an upshift at 2.25 s drops them, then they climb again.
		var rpm := 8200.0 + 900.0 * clampf(t / 2.25, 0.0, 1.0)
		if t > 2.25:
			rpm = 7300.0 + 1100.0 * clampf((t - 2.25) / 2.3, 0.0, 1.0)
		var shift_cut := 1.0 - 0.75 * exp(-pow((t - 2.27) / 0.035, 2.0))
		var f := rpm / 60.0 * cylinders * 0.5 * doppler
		phase += f / RATE
		var ph := phase - floorf(phase)
		var v := 0.0
		var amps := [1.0, 0.7, 0.55, 0.42, 0.3, 0.22, 0.16, 0.12, 0.08, 0.06]
		for h in amps.size():
			v += amps[h] * sin(TAU * phase * (h + 1) + h * 0.9)
		v += 0.45 * sin(TAU * phase * 0.5)            # the uneven-firing burble
		# Exhaust rasp: noise pulsed by each firing.
		rasp += (rng.randf_range(-1.0, 1.0) - rasp) * 0.55
		var pulse := exp(-ph * 7.0)
		var s := v * 0.22 + rasp * pulse * 0.55
		# Closer = louder and brighter (air soaks up the highs further away).
		var near := closest / dist
		var k := clampf(0.08 + 0.85 * near, 0.05, 0.95)
		bright += (s - bright) * k
		lp += (bright - lp) * 0.5
		var gain := near * near * 0.9 + near * 0.15
		var y := tanh(lp * 2.2) * gain * shift_cut
		# Wind and tyre roar as it goes by.
		y += rng.randf_range(-1.0, 1.0) * 0.05 * near * near
		var fade := clampf(t / 0.25, 0.0, 1.0) * clampf((length - t) / 0.6, 0.0, 1.0)
		y *= fade * 0.95
		var pan := clampf(x / (closest * 2.5), -1.0, 1.0)  # left to right
		out[i * 2] = y * sqrt(0.5 * (1.0 - pan))
		out[i * 2 + 1] = y * sqrt(0.5 * (1.0 + pan))
	return _wav(out, true)


static func _wav(samples: PackedFloat32Array, stereo: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = stereo
	w.data = bytes
	return w
