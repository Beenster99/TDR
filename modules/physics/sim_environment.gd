class_name SimEnvironment
extends RefCounted
## Conditions the physics reads: clock, air and track temperature, cloud,
## rain, standing water, the drying racing line and rubber laid down.
##
## Deterministic: everything follows from the start settings, the race seed
## and sim time (update(dt) once per tick). Every machine builds the same
## weather timeline from the same start data with create(), so only the
## changing state (to_dict) needs to cross the network.

## Weather names, driest first. The current one is derived from cloud + rain.
const WEATHERS := ["dry", "overcast", "light_rain", "heavy_rain"]
## [cloud, rain] for each weather.
const WEATHER_LEVELS := {
	"dry": [0.1, 0.0], "overcast": [0.85, 0.0],
	"light_rain": [0.95, 0.35], "heavy_rain": [1.0, 0.9],
}
const TRANSITION_S := 90.0       ## how long a weather change takes to blend
const DRY_LINE_WIDTH := 2.2      ## metres either side of the racing line

# --- State (synced host -> clients) -----------------------------------------
var ambient_c: float = 22.0
var track_c: float = 32.0
var time_of_day_h: float = 14.0  ## 0..24, moves at time_scale
var weather: String = "dry"      ## one of WEATHERS, from cloud + rain
var cloud: float = 0.1           ## 0..1 cloud cover
var rain: float = 0.0            ## 0..1 rainfall right now
var wetness: float = 0.0         ## 0..1 standing water on the track
var dry_line: float = 0.0        ## 0..1 how much water traffic has cleared off the racing line
var rubber: float = 0.3          ## 0..1 rubber laid on the racing line (grip bonus in the dry)
var elapsed_s: float = 0.0       ## sim seconds since the environment started

# --- Settings (identical everywhere, built by create(), never streamed) ------
var time_scale: float = 1.0      ## game clock speed: 60 = one race minute is an hour
var ambient_night_c: float = 12.0
var ambient_day_c: float = 22.0
var solar_gain_c: float = 13.0   ## how much hotter the track gets than the air in full sun
var track_offset_c: float = 0.0
var timeline: Array = []         ## [[start_s, cloud, rain], ...] sorted by start_s
var traffic: int = 0             ## cars at speed this tick (set by the race before update)
var _raceline_offset := PackedFloat32Array()


## Builds the start environment.
##  track_env: the track's "default_environment" (ambient_c / track_c at
##             time_of_day_h), optionally with "climate": {ambient_day_c,
##             ambient_night_c, rain_chance}.
##  race_env:  host options: time_of_day_h, time_scale, weather ("dry",
##             "overcast", "light_rain", "heavy_rain" or "random"),
##             weather_changes (bool). ambient_c / track_c pin the start
##             temperatures (the clock and weather still move them).
static func create(track_env: Dictionary, race_env: Dictionary, seed: int) -> SimEnvironment:
	var e := SimEnvironment.new()
	var climate: Dictionary = track_env.get("climate", {})
	var ref_h: float = track_env.get("time_of_day_h", 14.0)
	var ref_air: float = track_env.get("ambient_c", 22.0)
	var ref_track: float = track_env.get("track_c", ref_air + 11.0)
	var swing: float = climate.get("day_night_swing_c", 9.0)
	if climate.has("ambient_day_c") and climate.has("ambient_night_c"):
		swing = maxf(float(climate["ambient_day_c"]) - float(climate["ambient_night_c"]), 1.0)
	# Pick night/day so the track's reference reading happens at its reference hour.
	e.ambient_night_c = climate.get("ambient_night_c", ref_air - swing * _diurnal(ref_h))
	e.ambient_day_c = e.ambient_night_c + swing
	e.solar_gain_c = (ref_track - ref_air) / maxf(_sun(ref_h), 0.2)
	e.time_scale = clampf(float(race_env.get("time_scale", 1.0)), 0.0, 3600.0)
	e.time_of_day_h = fposmod(float(race_env.get("time_of_day_h", ref_h)), 24.0)
	var start := resolve_start_weather(race_env, track_env, seed)
	e.timeline = _build_timeline(start, bool(race_env.get("weather_changes", false)),
		float(climate.get("rain_chance", 0.3)), seed)
	e.cloud = e.timeline[0][1]
	e.rain = e.timeline[0][2]
	e.weather = weather_for(e.cloud, e.rain)
	# A race that starts in the rain starts on a track that's already wet.
	e.wetness = _wet_target(e.rain)
	e.rubber = 0.3 * (1.0 - e.wetness)
	e.ambient_c = e._ambient_target()
	e.track_c = e._track_target()
	if race_env.has("ambient_c"):
		var d := float(race_env["ambient_c"]) - e.ambient_c
		e.ambient_night_c += d
		e.ambient_day_c += d
		e.ambient_c += d
		e.track_c += d
	if race_env.has("track_c"):
		e.track_offset_c = float(race_env["track_c"]) - e.track_c
		e.track_c += e.track_offset_c
	return e


## The weather a race starts in ("random" is picked from the seed).
static func resolve_start_weather(race_env: Dictionary, track_env: Dictionary, seed: int) -> String:
	var w: String = race_env.get("weather", track_env.get("weather", "dry"))
	if w == "random":
		var rng := RandomNumberGenerator.new()
		rng.seed = seed ^ 0x5EA7
		var chance: float = track_env.get("climate", {}).get("rain_chance", 0.3)
		var roll := rng.randf()
		if roll < chance * 0.4:
			return "heavy_rain"
		if roll < chance:
			return "light_rain"
		return "overcast" if roll < chance + 0.25 else "dry"
	# Older names from wave 1 data.
	match w:
		"damp": return "light_rain"
		"wet": return "heavy_rain"
	return w if w in WEATHERS else "dry"


static func weather_for(p_cloud: float, p_rain: float) -> String:
	if p_rain >= 0.6:
		return "heavy_rain"
	if p_rain >= 0.08:
		return "light_rain"
	return "overcast" if p_cloud >= 0.6 else "dry"


static func weather_name(w: String) -> String:
	return {"dry": "Dry", "overcast": "Overcast", "light_rain": "Light rain",
		"heavy_rain": "Heavy rain", "random": "Random"}.get(w, w.capitalize())


## Changing weather: a seeded chain of spells, each 3..8 minutes long, that
## drifts between neighbouring weathers. Fixed weather: one entry.
static func _build_timeline(start: String, changes: bool, rain_chance: float, seed: int) -> Array:
	var lv: Array = WEATHER_LEVELS[start]
	var out := [[0.0, lv[0], lv[1]]]
	if not changes:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed ^ 0x3A1B
	var t := 0.0
	var k := WEATHERS.find(start)
	while t < 4.0 * 3600.0:
		t += rng.randf_range(180.0, 480.0)
		var wetter := rng.randf() < lerpf(0.25, 0.75, rain_chance)
		k = clampi(k + (1 if wetter else -1), 0, WEATHERS.size() - 1)
		lv = WEATHER_LEVELS[WEATHERS[k]]
		out.append([t, lv[0], lv[1]])
	return out


## Legacy builder: a fixed environment straight from values.
static func from_dict(d: Dictionary) -> SimEnvironment:
	var e := SimEnvironment.new()
	e.apply_dict(d)
	if not d.has("rain"):
		var lv: Array = WEATHER_LEVELS[resolve_start_weather({"weather": e.weather}, {}, 0)]
		e.cloud = lv[0]
		e.rain = lv[1]
	e.timeline = [[0.0, e.cloud, e.rain]]
	e.time_scale = d.get("time_scale", 0.0)
	return e


## The changing state. Everything else is rebuilt from the start data.
func to_dict() -> Dictionary:
	return {"ambient_c": ambient_c, "track_c": track_c, "time_of_day_h": time_of_day_h,
		"weather": weather, "cloud": cloud, "rain": rain, "wetness": wetness,
		"dry_line": dry_line, "rubber": rubber, "elapsed_s": elapsed_s}


## Overwrites the changing state in place (snapshots, host race state).
func apply_dict(d: Dictionary) -> void:
	ambient_c = d.get("ambient_c", ambient_c)
	track_c = d.get("track_c", track_c)
	time_of_day_h = d.get("time_of_day_h", time_of_day_h)
	weather = resolve_start_weather({"weather": d.get("weather", weather)}, {}, 0)
	cloud = d.get("cloud", cloud)
	rain = d.get("rain", rain)
	wetness = d.get("wetness", wetness)
	dry_line = d.get("dry_line", dry_line)
	rubber = d.get("rubber", rubber)
	elapsed_s = d.get("elapsed_s", elapsed_s)


## Lets grip know where the racing line is (offset from the centre line at
## each centre-line point). Called once by the race.
func bind_track(track: TrackData) -> void:
	var n := track.point_count()
	_raceline_offset.resize(n)
	_raceline_offset.fill(0.0)
	if track.raceline.is_empty():
		return
	var seen := PackedByteArray()
	seen.resize(n)
	var hint := -1
	for p in track.raceline:
		var q := track.project(p, hint)
		hint = q["idx"]
		_raceline_offset[hint] = q["offset"]
		seen[hint] = 1
	# Fill any centre-line points the racing line skipped.
	var last := 0.0
	for k in 2 * n:
		var i := k % n
		if seen[i]:
			last = _raceline_offset[i]
		elif k >= n or i > 0:
			_raceline_offset[i] = last


## Racing line position at centre-line point idx (metres, + right).
func raceline_offset(idx: int) -> float:
	return _raceline_offset[idx] if idx < _raceline_offset.size() else 0.0


# --- What the physics and AI read -------------------------------------------

## Air density relative to ISA sea level: hot air = less power, drag, downforce.
func air_density() -> float:
	return 1.225 * 288.15 / (ambient_c + 273.15)


## Water under a car that's off_line metres from the racing line.
func wetness_at(off_line: float) -> float:
	return wetness * (1.0 - dry_line * exp(-pow(off_line / DRY_LINE_WIDTH, 2.0)))


## Surface grip multiplier for a tyre: track temperature (asphalt grips best
## around 25..45 degC), water (by compound), aquaplaning at speed on deep
## water, and rubber on the racing line.
func grip_factor(compound: TyreCompound, off_line := 0.0, speed := 0.0) -> float:
	var g := 1.0 - 0.002 * maxf(0.0, absf(track_c - 35.0) - 10.0)
	var w := wetness_at(off_line)
	g *= lerpf(1.0, compound.wet_grip_factor, w)
	var standing := clampf((w - 0.55) / 0.45, 0.0, 1.0)
	g *= 1.0 - standing * compound.aquaplaning * clampf(speed / 70.0, 0.0, 1.0)
	var on_line := exp(-pow(off_line / 3.0, 2.0))
	g *= 1.0 + 0.05 * rubber * on_line * (1.0 - w)
	return g


## Kept for wave 1 callers: grip on the centre line at low speed.
func surface_grip(compound: TyreCompound) -> float:
	return grip_factor(compound)


## 0 in daylight, 1 at night (twilight in between). Clouds don't count here.
func darkness() -> float:
	return 1.0 - clampf((_sun(time_of_day_h, true) + 0.15) / 0.35, 0.0, 1.0)


## Seconds until the weather next changes (-1 = no change coming).
func next_change_in() -> float:
	for k in timeline:
		if k[0] > elapsed_s:
			return k[0] - elapsed_s
	return -1.0


## The weather the next change brings ("" = none).
func next_weather() -> String:
	for k in timeline:
		if k[0] > elapsed_s:
			return weather_for(k[1], k[2])
	return ""


# --- Time step ---------------------------------------------------------------

func update(dt: float) -> void:
	elapsed_s += dt
	var game_dt := dt * time_scale
	time_of_day_h = fposmod(time_of_day_h + game_dt / 3600.0, 24.0)
	_follow_timeline()
	weather = weather_for(cloud, rain)
	# Water: rain fills the track up to a level, sun and warmth dry it out.
	var target := _wet_target(rain)
	if wetness < target:
		wetness = minf(target, wetness + (0.004 + 0.012 * rain) * dt)
	else:
		var sun := _sun(time_of_day_h) * (1.0 - 0.7 * cloud)
		var dry_rate := (0.0006 + 0.00004 * maxf(track_c - 5.0, 0.0) + 0.001 * sun) * (1.0 - clampf(rain * 4.0, 0.0, 0.9))
		wetness = maxf(target, wetness - dry_rate * dt)
	# Cars push water off the racing line; rain refills it.
	var cars := float(traffic)
	dry_line += (0.0007 * cars * (1.0 - dry_line) * (1.0 if wetness > 0.02 else 0.0) - 0.02 * rain * dry_line) * dt
	if wetness <= 0.02:
		dry_line = maxf(dry_line - 0.01 * dt, 0.0)
	dry_line = clampf(dry_line, 0.0, 1.0)
	# Rubber builds with laps in the dry and washes away in the rain.
	rubber = clampf(rubber + (0.00003 * cars * (1.0 - rubber) * (1.0 - wetness) - 0.003 * rain * rubber) * dt, 0.0, 1.0)
	# Temperatures ease toward what the sun, cloud and water make them.
	ambient_c += (_ambient_target() - ambient_c) * minf(game_dt / 1800.0 + dt / 600.0, 1.0)
	var track_tau := lerpf(900.0, 200.0, wetness)
	track_c += (_track_target() - track_c) * minf(game_dt / track_tau + dt / 240.0, 1.0)


func _follow_timeline() -> void:
	var i := 0
	while i + 1 < timeline.size() and timeline[i + 1][0] <= elapsed_s:
		i += 1
	var cur: Array = timeline[i]
	if i == 0:
		cloud = cur[1]
		rain = cur[2]
		return
	var prev: Array = timeline[i - 1]
	var f := smoothstep(0.0, 1.0, (elapsed_s - cur[0]) / TRANSITION_S)
	cloud = lerpf(prev[1], cur[1], f)
	rain = lerpf(prev[2], cur[2], f)


static func _wet_target(p_rain: float) -> float:
	return 0.0 if p_rain < 0.02 else clampf(0.2 + p_rain * 0.9, 0.0, 1.0)


func _ambient_target() -> float:
	return lerpf(ambient_night_c, ambient_day_c, _diurnal(time_of_day_h)) - 2.5 * cloud - 3.0 * rain


func _track_target() -> float:
	var sun := _sun(time_of_day_h) * (1.0 - 0.75 * cloud) * (1.0 - 0.85 * wetness)
	return ambient_c + solar_gain_c * sun + track_offset_c - 1.5 * wetness


## 0 at 04:00 (coldest), 1 at 16:00 (warmest).
static func _diurnal(h: float) -> float:
	return 0.5 - 0.5 * cos(TAU * (h - 4.0) / 24.0)


## Sun height 0..1: up at 06:00, down at 19:00. signed = below horizon goes negative.
static func _sun(h: float, signed := false) -> float:
	var s := sin(PI * (h - 6.0) / 13.0) if h >= 6.0 and h <= 19.0 else -0.3 * sin(PI * fposmod(h - 19.0, 24.0) / 11.0)
	return s if signed else maxf(s, 0.0)
