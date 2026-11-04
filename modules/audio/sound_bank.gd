class_name SoundBank
extends RefCounted
## Every sound in the game. Two kinds:
## - Baked: engines (one set of loops per engine family, at many rpm bands),
##   turbo/supercharger/hybrid/gearbox whines, tyres, road, kerbs, gravel,
##   grass, wind, rain spray, exhaust pops and gearshift sounds. These are
##   synthesised offline by tools/engine_synth.py into baked/ (no recordings,
##   nothing to license) and loaded here.
## - Made here in code on first use: crashes, start lights, chimes, menu sounds.
## Loops are a whole number of cycles long so they repeat without clicks.

const RATE := 22050
## Kept for older callers: the firing frequency the old single engine loop
## was made at.
const ENGINE_BASE_HZ := 110.0
const BAKED_DIR := "res://modules/audio/baked/"
## Recorded sounds win over the synthesised ones (see docs/AUDIO.md):
## samples/<name>.wav|.ogg replaces a baked loop or one-shot (tyre_squeal,
## road_roar ...), and samples/engines/<voice>/on_<rpm>.wav + off_<rpm>.wav
## replace an engine family's rpm bands (or give one car its own voice with
## "engine": {"sound": {"samples": "<voice>"}}).
const SAMPLE_DIR := "res://modules/audio/samples/"
## Engine families baked by tools/engine_synth.py (see docs/AUDIO.md).
const FAMILIES := ["i4_turbo", "i6_turbo", "v6_turbo", "v6_na", "flat6_na", "v8_cross_na",
	"v8_cross_turbo", "v8_flat_na", "v8_flat_turbo", "v10_na", "v12_na"]

static var _cache: Dictionary = {}
static var _manifest: Dictionary = {}
static var _sample_bands: Dictionary = {}  ## voice -> bands from recordings ([] if none)


static func get_sound(name: String) -> AudioStream:
	if not _cache.has(name):
		# (Menu sounds and the intro pass-by take their samples in MenuSounds.)
		var baked: AudioStream = null if name in MenuSounds.NAMES else _load_sample(SAMPLE_DIR + name, _is_loop(name))
		if baked == null:
			baked = _load_baked(name)
		_cache[name] = baked if baked != null else _make(name)
	return _cache[name]


## The rpm bands an engine family was baked at: [[nominal, exact rpm], ...],
## low to high. Empty if the family is unknown.
static func engine_bands(family: String) -> Array:
	var rec := recorded_bands(family)
	if not rec.is_empty():
		return rec
	if _manifest.is_empty():
		var f := FileAccess.open(BAKED_DIR + "manifest.json", FileAccess.READ)
		if f:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				_manifest = parsed
	var fam: Dictionary = _manifest.get("families", {}).get(family, {})
	return fam.get("bands", [])


## One engine loop: family, on throttle (true) or overrun (false), band (nominal rpm).
static func engine_loop(family: String, on_load: bool, band: int) -> AudioStream:
	if not recorded_bands(family).is_empty():
		var key := "rec:%s_%s_%d" % [family, "on" if on_load else "off", band]
		if not _cache.has(key):
			_cache[key] = _load_sample("%sengines/%s/%s_%d" % [SAMPLE_DIR, family, "on" if on_load else "off", band], true)
		return _cache[key]
	return get_sound("%s_%s_%d" % [family, "on" if on_load else "off", band])


## Bands of a recorded engine voice in samples/engines/<voice>/: every rpm
## that has both an on_<rpm> and an off_<rpm> file, as [[rpm, rpm], ...] low
## to high. Empty when there are no recordings for it.
static func recorded_bands(voice: String) -> Array:
	if _sample_bands.has(voice):
		return _sample_bands[voice]
	var dir := SAMPLE_DIR + "engines/" + voice + "/"
	var on := {}
	var off := {}
	if DirAccess.dir_exists_absolute(dir):
		for f in ResourceLoader.list_directory(dir):
			var base := f.get_basename()
			if not f.get_extension() in ["wav", "ogg"]:
				continue
			var parts := base.split("_")
			if parts.size() != 2 or not parts[1].is_valid_int():
				continue
			if parts[0] == "on":
				on[int(parts[1])] = true
			elif parts[0] == "off":
				off[int(parts[1])] = true
	var rpms := []
	for r in on:
		if off.has(r):
			rpms.append(r)
	rpms.sort()
	var bands := []
	for r in rpms:
		bands.append([r, float(r)])
	_sample_bands[voice] = bands
	return bands


## A recorded sound at path (without extension, .ogg or .wav), looping if
## asked; null if there is none.
static func _load_sample(path: String, loop: bool) -> AudioStream:
	for ext in ["ogg", "wav"]:
		if not ResourceLoader.exists(path + "." + ext):
			continue
		var s = load(path + "." + ext)
		if s is AudioStreamOggVorbis:
			(s as AudioStreamOggVorbis).loop = loop
		elif s is AudioStreamWAV and loop:
			var w := s as AudioStreamWAV
			if w.loop_mode == AudioStreamWAV.LOOP_DISABLED:
				w.loop_mode = AudioStreamWAV.LOOP_FORWARD
				w.loop_begin = 0
				w.loop_end = _frames(w)
		return s
	return null


## Loads a baked sound, making sure loops loop (the .import files aren't in
## git, so the WAV's own loop points are used and re-applied here).
static func _load_baked(name: String) -> AudioStream:
	var path := BAKED_DIR + name + ".wav"
	if not ResourceLoader.exists(path):
		return null
	var s = load(path)
	if s is AudioStreamWAV and _is_loop(name):
		var w := s as AudioStreamWAV
		if w.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = _frames(w)
	return s


static func _is_loop(name: String) -> bool:
	return not (name.begins_with("pop_") or name in ["crackle", "shift", "flutter", "blowoff", "radio_open", "radio_close"])


static func _frames(w: AudioStreamWAV) -> int:
	var b := 2 if w.format == AudioStreamWAV.FORMAT_16_BITS else 1
	if w.format == AudioStreamWAV.FORMAT_16_BITS or w.format == AudioStreamWAV.FORMAT_8_BITS:
		return w.data.size() / (b * (2 if w.stereo else 1))
	return int(w.get_length() * w.mix_rate)


static func _make(name: String) -> AudioStreamWAV:
	match name:
		"engine_on": return _engine(true)
		"engine_off": return _engine(false)
		"squeal": return _squeal()
		"rumble": return _rumble()
		"tyre_squeal": return _squeal()
		"gravel", "grass": return _rumble()
		"crash": return _crash(0.55, 0.9)
		"bump": return _crash(0.18, 0.5)
		"beep": return _tone([880.0], 0.18, 0.5)
		"beep_go": return _tone([1320.0, 1760.0], 0.45, 0.5)
		"chime": return _tone([660.0, 990.0, 1320.0], 0.5, 0.35)
		"ui_move": return _tone([1500.0], 0.035, 0.25)
		"ui_select": return _tone([900.0, 1350.0], 0.09, 0.35)
		"ui_back": return _tone([600.0], 0.08, 0.3)
		"ui_tick": return _tone([2000.0], 0.025, 0.2)
		"radio_open": return _radio_burst(0.2, true, 11)
		"radio_close": return _radio_burst(0.26, false, 13)
		"radio_static": return _radio_static(1.6)
		"cork_pop": return _cork_pop()
		"champagne_spray": return _champagne_spray()
		"crowd_cheer": return _crowd_cheer()
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


## Team radio: band-limited noise (a narrow "radio" band, about 300 Hz to
## 3 kHz) with sparse crackles. Used by RadioVoice under a read-out.
static func _radio_noise(rng: RandomNumberGenerator, state: Array) -> float:
	var x := rng.randf_range(-1.0, 1.0)
	# High-pass (one pole, ~300 Hz) then low-pass (one pole, ~3 kHz).
	var hp: float = 0.92 * (float(state[0]) + x - float(state[1]))
	state[1] = x
	state[0] = hp
	var lp: float = float(state[2]) + 0.55 * (hp - float(state[2]))
	state[2] = lp
	return lp


## The click and hiss as a radio opens (open = true: a click, a burst of
## static and a short chirp) or closes (the squelch tail and a click).
static func _radio_burst(length_s: float, open: bool, seed: int) -> AudioStreamWAV:
	var n := int(RATE * length_s)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var st := [0.0, 0.0, 0.0]
	for i in n:
		var t := float(i) / RATE
		var env := exp(-t * 9.0) if open else clampf(1.0 - t / length_s, 0.0, 1.0) * (0.6 + 0.4 * sin(t * 90.0))
		var v := _radio_noise(rng, st) * 0.75 * env
		if rng.randf() < 0.004:
			v += rng.randf_range(-0.8, 0.8)
		# The key click: a sharp edge at the start (open) or end (close).
		var edge := t if open else length_s - t
		if edge < 0.004:
			v += 0.9 * (1.0 - edge / 0.004) * (1.0 if i % 2 == 0 else -1.0)
		# A short chirp after the click as the channel opens.
		if open and t > 0.03 and t < 0.085:
			v += 0.22 * sin(TAU * 1250.0 * t)
		out[i] = v
	return _to_wav(out, false)


## The quiet static bed under a radio read-out (a loop).
static func _radio_static(length_s: float) -> AudioStreamWAV:
	var n := int(RATE * length_s)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	var st := [0.0, 0.0, 0.0]
	var pop := 0.0
	for i in n:
		var t := float(i) / RATE
		var v := _radio_noise(rng, st) * (0.32 + 0.12 * sin(t * 7.3) + 0.06 * sin(t * 23.0))
		# Crackles: little pops that die away in a few milliseconds.
		if rng.randf() < 0.0012:
			pop = rng.randf_range(-0.9, 0.9)
		v += pop
		pop *= 0.82
		out[i] = v + 0.02 * sin(TAU * 50.0 * t)
	return _to_wav(out, true)


## The podium: a champagne cork popping, a sharp knock with a hollow
## "thoonk" falling in pitch and a little fizz after it.
static func _cork_pop() -> AudioStreamWAV:
	var n := int(RATE * 0.45)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var hp := 0.0
	var prev := 0.0
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var noise := rng.randf_range(-1.0, 1.0)
		hp = 0.7 * (hp + noise - prev)
		prev = noise
		ph += TAU * (820.0 * exp(-t * 9.0) + 260.0) / RATE
		var knock := noise * exp(-t * 260.0) * 1.1
		var thoonk := sin(ph) * exp(-t * 32.0) * 0.8
		var fizz := hp * exp(-t * 6.0) * 0.12 * minf(1.0, t / 0.03)
		out[i] = tanh(knock + thoonk + fizz) * 0.9
	return _to_wav(out, false)


## The podium: champagne spraying, a loop of bright hiss that gusts, with
## the crackle of bubbles in it.
static func _champagne_spray() -> AudioStreamWAV:
	var n := int(RATE * 2.0)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 37
	var hp := 0.0
	var prev := 0.0
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var noise := rng.randf_range(-1.0, 1.0)
		hp = 0.92 * (hp + noise - prev)
		prev = noise
		lp += (hp - lp) * 0.55
		var gust := 0.7 + 0.2 * sin(TAU * 1.5 * t) + 0.1 * sin(TAU * 4.0 * t + 1.0)
		var bubble := 0.0
		if rng.randf() < 0.004:
			bubble = rng.randf_range(-0.5, 0.5)
		out[i] = (lp * 0.55 * gust + bubble) * 0.8
	return _to_wav(out, true)


## The podium: a crowd cheering and clapping, a loop. A bed of many voices
## (noise shaped like voices, swelling and fading), whoops that rise in
## pitch, and claps.
static func _crowd_cheer() -> AudioStreamWAV:
	var n := int(RATE * 4.0)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	# The bed: band-limited noise, swelling.
	var a := 0.0
	var b := 0.0
	for i in n:
		var t := float(i) / RATE
		var noise := rng.randf_range(-1.0, 1.0)
		a += (noise - a) * 0.25
		b += (a - b) * 0.08
		var swell := 0.75 + 0.15 * sin(TAU * 0.5 * t) + 0.1 * sin(TAU * 1.25 * t + 2.0)
		out[i] = (a - b) * 0.9 * swell
	# Voices: whoops and "hey"s at random pitches, each a buzzy tone through a soft vowel.
	for v in 26:
		var start := rng.randi_range(0, n - 1)
		var length := int(RATE * rng.randf_range(0.25, 0.8))
		var f0 := rng.randf_range(170.0, 420.0)
		var rise := rng.randf_range(0.0, 0.6)
		var vol := rng.randf_range(0.04, 0.1)
		var ph := 0.0
		var lpv := 0.0
		for k in length:
			var i := (start + k) % n   # wraps so the loop has no seam
			var x := float(k) / length
			var env := sin(PI * x) * (1.0 - 0.5 * x)
			ph += TAU * f0 * (1.0 + rise * x + 0.02 * sin(TAU * 6.0 * x)) / RATE
			var buzz := sin(ph) + 0.5 * sin(2.0 * ph) + 0.3 * sin(3.0 * ph) + 0.15 * sin(5.0 * ph)
			lpv += (buzz - lpv) * 0.3
			out[i] += lpv * env * vol
	# Claps: short bursts of noise.
	for c in 90:
		var start := rng.randi_range(0, n - 1)
		var vol := rng.randf_range(0.08, 0.22)
		var clap_n := int(RATE * 0.03)
		for k in clap_n:
			var i := (start + k) % n
			out[i] += rng.randf_range(-1.0, 1.0) * exp(-float(k) / clap_n * 5.0) * vol
	for i in n:
		out[i] = tanh(out[i] * 1.1) * 0.8
	return _to_wav(out, true)
