class_name WeatherForecast
extends RefCounted
## Weather radar and forecast for the pit wall, read from the race's
## SimEnvironment. The environment's weather timeline is deterministic (same
## on every machine), so every machine builds the same radar and forecast
## without anything extra crossing the network.
##
## The radar is a rain field around the track (rain_at / sample_grid). The
## weather moves with a seeded wind: rain that's d metres upwind now is the
## rain the timeline brings to the track d / wind_speed seconds from now, so
## what the radar shows is what then really happens at the track. Rain cells
## have ragged fronts, holes and cores, a limited width across the wind, and
## grow or fade a little as they come in (only at the track do they match the
## timeline exactly).
##
## The forecast is what a forecaster makes of that radar: it moves the rain
## it sees at an estimated speed (a little off, by a slowly changing error)
## and assumes cells keep their strength. So it's close but not perfect, and
## it gets better as the weather gets closer. Each change comes with an ETA
## range that nearly always holds the real time, and a confidence.
##
## Works with any SimEnvironment: if it has no timeline (fixed weather), the
## forecast is just the current conditions.

const HORIZON_S := 1800.0      ## the forecast looks 30 minutes ahead
const SPEED_ERR := 0.18        ## the forecaster's speed estimate is up to 18% off
const GROW_RANGE_S := 1500.0   ## cells this far out (in time) show their full growth/decay
const TRANSITION_S := 90.0     ## same blend as SimEnvironment.TRANSITION_S
const TILE := 256              ## noise tile, pixels a side
const TILE_M := 42000.0        ## metres the noise tile covers
const WOBBLE := 1.6            ## how ragged fronts and cell sides are
const RING_STEPS := [500.0, 1000.0, 2000.0, 2500.0, 5000.0, 10000.0]

## Current conditions.
var weather: String = "dry"
var rain: float = 0.0
var cloud: float = 0.0
var wetness: float = 0.0
var track_c: float = 0.0
var ambient_c: float = 0.0
var time_of_day_h: float = 12.0
## Upcoming changes, soonest first, as forecast (not the truth):
## [{eta, eta_lo, eta_hi, weather, rain, cloud, confidence, lasts, k}]
## lasts = forecast minutes the new weather holds (-1 = beyond the horizon),
## k = the timeline spell it comes from.
var changes: Array = []
var has_timeline := false
## Older radar picture, kept for callers from telemetry 1.0: rain cells
## sampled from the field, [{pos, radius, rain, cloud}]. Worked out when read.
var radar_cells: Array:
	get = _sampled_cells
var radar_range: float = 15000.0  ## metres from the centre to the radar's edge (zoom 1)
var ring_step: float = 2500.0     ## metres between range rings
var wind_dir := Vector2.RIGHT     ## direction the weather moves (+x east, +y south)
var wind_speed: float = 8.0       ## metres per second
var centre := Vector2.ZERO        ## track centre in track metres
var track_radius: float = 1000.0
var elapsed: float = 0.0          ## environment seconds the radar is drawn for
var speed_error: float = 0.0      ## -1..1, how far off the forecaster's speed is now
var _seed: int = 0
var _timeline: Array = [[0.0, 0.1, 0.0]]
var _spells: Dictionary = {}      ## k -> [offset across the wind, half width, growth]
var _tile := PackedByteArray()


func setup(track: TrackData, seed: int) -> void:
	var lo := Vector2(INF, INF)
	var hi := -lo
	for p in track.points:
		lo = lo.min(p)
		hi = hi.max(p)
	centre = (lo + hi) * 0.5
	track_radius = maxf((hi - lo).length() * 0.5, 300.0)
	_seed = seed
	var rng := RandomNumberGenerator.new()
	rng.seed = seed ^ 0x7AD1
	wind_dir = Vector2.from_angle(rng.randf() * TAU)
	wind_speed = rng.randf_range(5.5, 12.0)   # 20-43 km/h
	# Range: what the next 30-35 minutes cover, in whole rings.
	var want := wind_speed * HORIZON_S * 1.15 + track_radius
	ring_step = RING_STEPS[-1]
	for s in RING_STEPS:
		if want / s <= 6.0:
			ring_step = s
			break
	radar_range = ceilf(want / ring_step) * ring_step
	var n := FastNoiseLite.new()
	n.seed = seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 5
	n.frequency = 0.012
	var img := n.get_seamless_image(TILE, TILE)
	img.convert(Image.FORMAT_L8)
	_tile = img.get_data()
	_spells.clear()


func update(env: SimEnvironment) -> void:
	weather = env.weather
	wetness = env.wetness
	track_c = env.track_c
	ambient_c = env.ambient_c
	time_of_day_h = env.time_of_day_h
	var r = env.get("rain")
	var c = env.get("cloud")
	rain = float(r) if r != null else {"light_rain": 0.35, "heavy_rain": 0.9, "damp": 0.35, "wet": 0.9}.get(weather, 0.0)
	cloud = float(c) if c != null else (0.85 if weather != "dry" else 0.1)
	changes.clear()
	var tl = env.get("timeline")
	var el = env.get("elapsed_s")
	has_timeline = tl is Array and el != null and tl.size() > 0
	if not has_timeline:
		_set_timeline([[0.0, cloud, rain]])
		elapsed = 0.0
		speed_error = 0.0
		return
	_set_timeline(tl)
	elapsed = float(el)
	speed_error = _speed_error(elapsed)
	_build_changes()


# --- Truth: the rain field ----------------------------------------------------------

## Rain (0..1) the radar sees at p (track metres) at environment time t.
## At the track centre this is the SimEnvironment's own rain at t.
func truth_at(p: Vector2, t: float) -> float:
	var d := p - centre
	var s := d.dot(-wind_dir)
	var q := d.dot(Vector2(-wind_dir.y, wind_dir.x))
	var tau0 := t + s / wind_speed
	var sp := _spell_params(tau0)
	var tau: float = tau0 + _wobble(q, tau0, sp[1]) / wind_speed
	var r := timeline_rain(tau)
	if r <= 0.0:
		return 0.0
	sp = _spell_params(tau)
	var env: float = _envelope(q, tau, sp[0], sp[1])
	var grow: float = 1.0 + sp[2] * clampf(s / (wind_speed * GROW_RANGE_S), 0.0, 1.0)
	var a := (p - wind_dir * wind_speed * t) * (float(TILE) / TILE_M)
	var m := _cells(_tile_at(a.x, a.y), q, d.length())
	return clampf(r * env * grow * m, 0.0, 1.0)


## Rain the radar shows at p, `offset_s` from now: now and the past are the
## truth, the future is the forecast (today's picture moved on at the
## forecaster's estimated speed).
func rain_at(p: Vector2, offset_s := 0.0) -> float:
	if offset_s <= 0.0:
		return truth_at(p, elapsed + offset_s)
	return truth_at(p - wind_dir * _est_speed() * offset_s, elapsed)


## The radar picture over `area` (track metres) as w x h values 0..1, row by
## row from the top. Rows from row0 for n_rows rows (all by default), so the
## caller can spread a big picture over several frames.
func sample_grid(area: Rect2, w: int, h: int, offset_s := 0.0, row0 := 0, n_rows := -1) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var rows := h - row0 if n_rows < 0 else mini(n_rows, h - row0)
	out.resize(maxi(rows, 0) * w)
	if rows <= 0:
		return out
	var t := elapsed + minf(offset_s, 0.0)
	var shift := wind_dir * _est_speed() * maxf(offset_s, 0.0)
	var perp := Vector2(-wind_dir.y, wind_dir.x)
	var ws := wind_speed
	var step := area.size / Vector2(w, h)
	# Spell parameters along the wind, once per call, every 4 seconds of arrival time.
	var span := (area.size.length() * 0.5 + area.get_center().distance_to(centre) + shift.length()) / ws + 600.0
	var t_lo := t - span
	var n_prof := int(span * 2.0 / 4.0) + 2
	var prof := PackedFloat32Array()
	prof.resize(n_prof * 4)
	for i in n_prof:
		var tau := t_lo + i * 4.0
		var sp := _spell_params(tau)
		prof[i * 4] = timeline_rain(tau)
		prof[i * 4 + 1] = sp[0]
		prof[i * 4 + 2] = sp[1]
		prof[i * 4 + 3] = sp[2]
	var tex_scale := float(TILE) / TILE_M
	var adv_off := wind_dir * ws * t
	var grow_m := 1.0 / (ws * GROW_RANGE_S)
	var k := 0
	for y in range(row0, row0 + rows):
		for x in w:
			var p := area.position + Vector2((x + 0.5) * step.x, (y + 0.5) * step.y) - shift
			var d := p - centre
			var s := -d.dot(wind_dir)
			var q := d.dot(perp)
			var tau0 := t + s / ws
			var i0 := clampi(int((tau0 - t_lo) * 0.25), 0, n_prof - 1)
			var tau := tau0 + _wobble(q, tau0, prof[i0 * 4 + 2]) / ws
			var i := clampi(int((tau - t_lo) * 0.25), 0, n_prof - 1)
			var r := prof[i * 4]
			if r < 0.01:
				out[k] = 0.0
				k += 1
				continue
			var env := _envelope(q, tau, prof[i * 4 + 1], prof[i * 4 + 2])
			if env <= 0.0:
				out[k] = 0.0
				k += 1
				continue
			var grow := 1.0 + prof[i * 4 + 3] * clampf(s * grow_m, 0.0, 1.0)
			var a := (p - adv_off) * tex_scale
			var m := _cells(_tile_at(a.x, a.y), q, d.length())
			out[k] = clampf(r * env * grow * m, 0.0, 1.0)
			k += 1
	return out


## The timeline's rain at environment time t, blended like SimEnvironment.
func timeline_rain(t: float) -> float:
	var i := _index_at(t)
	if i == 0:
		return _timeline[0][2]
	var f: float = smoothstep(0.0, 1.0, (t - _timeline[i][0]) / TRANSITION_S)
	return lerpf(_timeline[i - 1][2], _timeline[i][2], f)


func _sampled_cells() -> Array:
	var out := []
	var n := 12
	var cell := radar_range * 2.0 / n
	for j in n:
		for i in n:
			var p := centre + Vector2((i + 0.5) * cell - radar_range, (j + 0.5) * cell - radar_range)
			var r := rain_at(p)
			if r > 0.05:
				out.append({"pos": p, "radius": cell * 0.6, "rain": r, "cloud": maxf(cloud, 0.9)})
	return out


# --- Forecast -------------------------------------------------------------------------

## Forecast rain at the track `secs` from now (0..1).
func rain_in(secs: float) -> float:
	if secs <= 0.0:
		return rain
	var s := _est_speed() * secs          # where that rain is on the radar now
	var tau := elapsed + s / wind_speed
	var sp := _spell_params(tau)
	return clampf(timeline_rain(tau) * (1.0 + sp[2] * clampf(s / (wind_speed * GROW_RANGE_S), 0.0, 1.0)), 0.0, 1.0)


## One line for the pit wall, e.g. "Light rain in 6-8 min (80%)".
func summary() -> String:
	if changes.is_empty():
		return "No change expected" if has_timeline else "Fixed conditions"
	var c: Dictionary = changes[0]
	return "%s in %s (%d%%)" % [weather_label(c["weather"]), eta_text(c), int(c["confidence"] * 100.0)]


## Compass point the weather is moving towards (north is -y), e.g. "NE".
func heading_name() -> String:
	return compass(wind_dir)


static func compass(dir: Vector2) -> String:
	var a := fposmod(rad_to_deg(atan2(dir.x, -dir.y)), 360.0)
	return ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"][int(round(a / 22.5)) % 16]


static func eta_text(c: Dictionary) -> String:
	var lo := int(c["eta_lo"] / 60.0)
	var hi := int(ceil(c["eta_hi"] / 60.0))
	if hi <= 1:
		return "under a minute"
	if lo == hi or hi - lo <= 1 and lo == 0:
		return "about %d min" % hi
	return "%d-%d min" % [lo, hi]


static func weather_label(w: String) -> String:
	return {"dry": "Dry", "overcast": "Overcast", "light_rain": "Light rain", "heavy_rain": "Heavy rain",
		"damp": "Damp", "wet": "Wet"}.get(w, w.capitalize())


static func _weather_for(c: float, r: float) -> String:
	if r >= 0.6:
		return "heavy_rain"
	if r >= 0.08:
		return "light_rain"
	return "overcast" if c >= 0.6 else "dry"


func _build_changes() -> void:
	var ratio := 1.0 + SPEED_ERR * speed_error   # forecast eta / real eta
	var prev_w := weather
	var start := _index_at(elapsed) + 1
	for k in range(start, _timeline.size()):
		var eta: float = _timeline[k][0] - elapsed
		var est := eta * ratio
		if est > HORIZON_S:
			break
		var p_rain := rain_in(est + TRANSITION_S * 1.05 * ratio)   # once the change has blended in
		var w := _weather_for(_timeline[k][1], p_rain)
		if w == prev_w:
			continue
		prev_w = w
		var lasts := -1.0
		for j in range(k + 1, _timeline.size()):
			if _weather_for(_timeline[j][1], _timeline[j][2]) != _weather_for(_timeline[k][1], _timeline[k][2]):
				lasts = (_timeline[j][0] - _timeline[k][0]) * ratio / 60.0
				break
		if lasts > (HORIZON_S - est) / 60.0:
			lasts = -1.0
		var conf := clampf(0.97 - est / 2400.0, 0.4, 0.97)
		if absf(p_rain - _timeline[k][2]) > 0.1:
			conf -= 0.05     # a cell that's still changing strength
		# The range allows for most (not all) of the speed error.
		changes.append({"eta": est, "eta_lo": maxf(est / (1.0 + SPEED_ERR * 0.8) - 20.0, 0.0),
			"eta_hi": est / (1.0 - SPEED_ERR * 0.8) + 20.0,
			"weather": w, "rain": p_rain, "cloud": _timeline[k][1], "confidence": conf,
			"lasts": lasts, "k": k})


func _est_speed() -> float:
	return wind_speed / (1.0 + SPEED_ERR * speed_error)


## The forecaster's speed error drifts slowly through the race.
func _speed_error(t: float) -> float:
	return clampf((_tile_at(t / 1500.0 * 9.0, 31.0) - 0.5) * 3.5, -1.0, 1.0)


func _set_timeline(tl: Array) -> void:
	if tl.size() != _timeline.size() or tl[0] != _timeline[0] or tl[-1] != _timeline[-1]:
		_spells.clear()
	_timeline = tl


func _index_at(t: float) -> int:
	var lo := 0
	var hi := _timeline.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if _timeline[mid][0] <= t:
			lo = mid
		else:
			hi = mid - 1
	return lo


## [offset across the wind, half width, growth] of the weather arriving at
## time t, blended between spells like the rain.
func _spell_params(t: float) -> Array:
	var i := _index_at(t)
	var b := _spell(i)
	if i == 0:
		return b
	var f: float = smoothstep(0.0, 1.0, (t - _timeline[i][0]) / TRANSITION_S)
	if f >= 1.0:
		return b
	var a := _spell(i - 1)
	return [lerpf(a[0], b[0], f), lerpf(a[1], b[1], f), lerpf(a[2], b[2], f)]


func _spell(k: int) -> Array:
	if not _spells.has(k):
		var rng := RandomNumberGenerator.new()
		rng.seed = _seed * 131 + k * 7919 + 17
		var half := maxf(radar_range * rng.randf_range(0.3, 0.7), track_radius * 3.0)
		_spells[k] = [half * rng.randf_range(-0.4, 0.4), half, rng.randf_range(-0.45, 0.45)]
	return _spells[k]


## Ragged fronts: shifts where along the wind a front sits, by position
## across the wind. Zero on the track's own line, so the track still gets the
## weather exactly when the timeline says.
func _wobble(q: float, tau: float, half: float) -> float:
	var y := tau / 700.0 * 9.0
	return (_tile_at(q / half * 40.0, y) - _tile_at(0.0, y)) * WOBBLE * half


## How much of a spell's rain falls q metres across the wind: full in the
## middle, fading out at ragged sides.
func _envelope(q: float, tau: float, off: float, half: float) -> float:
	var y := tau / 500.0 * 9.0
	var edge := (_tile_at(q / half * 30.0 + 97.0, y) - _tile_at(97.0, y)) * WOBBLE * 0.8
	return 1.0 - smoothstep(0.45, 1.0, absf(q - off) / half + edge)


## Cells with holes and cores (0..1.5), from the drifting noise value n.
## They even out over the circuit itself, which gets the race's own rain.
func _cells(n: float, _q: float, dist: float) -> float:
	var m := clampf(0.68 + (n - 0.5) * 5.0, 0.0, 1.5)
	return lerpf(1.0, m, smoothstep(0.0, 1.0, dist / (track_radius * 2.0)))


## The noise tile, 0..1, bilinear, wrapping (pixel units).
func _tile_at(x: float, y: float) -> float:
	if _tile.is_empty():
		return 0.5
	var fx := floorf(x)
	var fy := floorf(y)
	var tx := x - fx
	var ty := y - fy
	var x0 := posmod(int(fx), TILE)
	var y0 := posmod(int(fy), TILE)
	var x1 := (x0 + 1) % TILE
	var y1 := (y0 + 1) % TILE
	var a := lerpf(_tile[y0 * TILE + x0], _tile[y0 * TILE + x1], tx)
	var b := lerpf(_tile[y1 * TILE + x0], _tile[y1 * TILE + x1], tx)
	return lerpf(a, b, ty) / 255.0
