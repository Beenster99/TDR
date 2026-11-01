class_name SoundBank
extends RefCounted
## Makes every sound in code, once, and caches it. Loops are a whole number
## of cycles long so they repeat without clicks. Mono 16-bit, 22.05 kHz.

const RATE := 22050
## Engine loops are made at this firing frequency; players set pitch_scale
## to (firing frequency / ENGINE_BASE_HZ).
const ENGINE_BASE_HZ := 110.0

static var _cache: Dictionary = {}


static func get_sound(name: String) -> AudioStreamWAV:
	if not _cache.has(name):
		_cache[name] = _make(name)
	return _cache[name]


static func _make(name: String) -> AudioStreamWAV:
	match name:
		"engine_on": return _engine(true)
		"engine_off": return _engine(false)
		"squeal": return _squeal()
		"rumble": return _rumble()
		"crash": return _crash(0.55, 0.9)
		"bump": return _crash(0.18, 0.5)
		"beep": return _tone([880.0], 0.18, 0.5)
		"beep_go": return _tone([1320.0, 1760.0], 0.45, 0.5)
		"chime": return _tone([660.0, 990.0, 1320.0], 0.5, 0.35)
		"ui_move": return _tone([1500.0], 0.035, 0.25)
		"ui_select": return _tone([900.0, 1350.0], 0.09, 0.35)
		"ui_back": return _tone([600.0], 0.08, 0.3)
		"ui_tick": return _tone([2000.0], 0.025, 0.2)
	push_error("SoundBank: no sound called " + name)
	return _tone([440.0], 0.1, 0.1)


static func _to_wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	if loop:
		samples = _seamless(samples, int(RATE * 0.0909))
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w


## Crossfades the end of a loop into its start so the noise in it doesn't
## click each time it repeats. The loop gets `fade` samples shorter.
static func _seamless(src: PackedFloat32Array, fade: int) -> PackedFloat32Array:
	var n := src.size() - fade
	var out := src.slice(0, n)
	for i in fade:
		var k := float(i) / fade
		out[i] = src[i] * k + src[n + i] * (1.0 - k)
	return out


## Engine: a pulse for every firing stroke (a rich harmonic stack shaped like
## exhaust pulses) plus a little combustion noise. "On" is throttle: loud and
## buzzy. "Off" is overrun: softer, duller, with the odd pop.
static func _engine(on_load: bool) -> AudioStreamWAV:
	var cycles := 220  # 2 s at 110 Hz: a whole number of cycles
	var n := int(RATE * cycles / ENGINE_BASE_HZ)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7 if on_load else 11
	var lp := 0.0
	var harmonics := [1.0, 0.6, 0.45, 0.3, 0.22, 0.14, 0.1, 0.06] if on_load else [1.0, 0.45, 0.2, 0.1, 0.05]
	# Slight cycle-to-cycle variation, so it isn't a pure buzz.
	var amp := PackedFloat32Array()
	for c in cycles + 1:
		amp.append(rng.randf_range(0.8, 1.0))
	amp[cycles] = amp[0]
	for i in n:
		var ph := float(i) * ENGINE_BASE_HZ / RATE
		var cyc := int(ph)
		var frac := ph - cyc
		var a := lerpf(amp[cyc], amp[cyc + 1], frac)
		var v := 0.0
		for h in harmonics.size():
			v += harmonics[h] * sin(TAU * ph * (h + 1) + h * 0.7)
		# Sub-harmonic at half the firing rate: the lumpy "burble".
		v += (0.35 if on_load else 0.5) * sin(TAU * ph * 0.5)
		var noise := rng.randf_range(-1.0, 1.0) * exp(-frac * 6.0)
		lp += ((noise) - lp) * (0.5 if on_load else 0.2)
		v = v * a * 0.22 + lp * (0.25 if on_load else 0.12)
		if not on_load and rng.randf() < 0.00012:
			v += 0.8  # an overrun pop
		out[i] = tanh(v * (1.6 if on_load else 1.1)) * 0.8
	return _to_wav(out, true)


## Tyre squeal: a few close tones that beat against each other, with a
## wobble and some hiss. 1 s loop of whole cycles.
static func _squeal() -> AudioStreamWAV:
	var n := RATE
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var wob := sin(TAU * 6.0 * t) * 0.004 + sin(TAU * 11.0 * t) * 0.003
		var v := 0.5 * sin(TAU * 860.0 * t + 40.0 * wob) + 0.35 * sin(TAU * 1290.0 * t) + 0.25 * sin(TAU * 873.0 * t)
		v *= 0.7 + 0.3 * sin(TAU * 4.0 * t)
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.6
		out[i] = (v * 0.5 + lp * 0.18) * 0.8
	return _to_wav(out, true)


## Grass and gravel: low, rough noise.
static func _rumble() -> AudioStreamWAV:
	var n := RATE
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.08
		lp2 += (lp - lp2) * 0.1
		var t := float(i) / RATE
		out[i] = (lp * 2.5 + 0.25 * sin(TAU * 40.0 * t)) * (0.6 + 0.4 * sin(TAU * 9.0 * t)) * 0.7
	return _to_wav(out, true)


## Crash / bump: a thump plus a burst of crunchy noise that dies away.
static func _crash(length_s: float, crunch: float) -> AudioStreamWAV:
	var n := int(RATE * length_s)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var thump := sin(TAU * (70.0 - 30.0 * t / length_s) * t) * exp(-t * 18.0)
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.35
		var crunch_v := lp * exp(-t * 7.0 / length_s) * crunch
		if rng.randf() < 0.002:
			crunch_v += rng.randf_range(-0.6, 0.6) * exp(-t * 4.0 / length_s)
		out[i] = tanh((thump * 1.2 + crunch_v * 1.4)) * 0.85
	return _to_wav(out, false)


## Simple tones for the start lights, laps and menus.
static func _tone(freqs: Array, length_s: float, vol: float) -> AudioStreamWAV:
	var n := int(RATE * length_s)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / RATE
		var env := minf(t / 0.004, 1.0) * exp(-t * 3.5 / length_s)
		var v := 0.0
		for k in freqs.size():
			var start := k * length_s * 0.18
			if t >= start:
				v += sin(TAU * freqs[k] * (t - start))
		out[i] = v / freqs.size() * env * vol
	return _to_wav(out, false)
