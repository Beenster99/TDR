class_name WeatherForecast
extends RefCounted
## Weather radar and forecast for the pit wall, read from the race's
## SimEnvironment. The environment's weather timeline is deterministic (same
## on every machine), so every machine builds the same forecast and radar
## without anything extra crossing the network.
##
## Works with any SimEnvironment: if it has no timeline (fixed weather), the
## forecast is just the current conditions.

const HORIZON_S := 1800.0      ## look 30 minutes ahead
const RADAR_LEAD_S := 1200.0   ## a spell 20 min away sits near the radar's edge

## Current conditions.
var weather: String = "dry"
var rain: float = 0.0
var cloud: float = 0.0
var wetness: float = 0.0
var track_c: float = 0.0
var ambient_c: float = 0.0
var time_of_day_h: float = 12.0
## Upcoming changes, soonest first:
## [{eta, eta_lo, eta_hi, weather, rain, cloud, confidence}]
var changes: Array = []
var has_timeline := false
## Radar picture in metres around the track's centre (+x east, +y south, the
## track's own coordinates): [{pos: Vector2, radius, rain, cloud}].
var radar_cells: Array = []
var radar_range: float = 3000.0   ## metres from the centre to the radar's edge
var wind_dir := Vector2.RIGHT     ## direction the weather moves
var centre := Vector2.ZERO
var track_radius: float = 1000.0
var _seed: int = 0


func setup(track: TrackData, seed: int) -> void:
	var lo := Vector2(INF, INF)
	var hi := -lo
	for p in track.points:
		lo = lo.min(p)
		hi = hi.max(p)
	centre = (lo + hi) * 0.5
	track_radius = maxf((hi - lo).length() * 0.5, 300.0)
	radar_range = track_radius * 3.0
	_seed = seed
	var rng := RandomNumberGenerator.new()
	rng.seed = seed ^ 0x7AD1
	wind_dir = Vector2.from_angle(rng.randf() * TAU)


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
	radar_cells.clear()
	var tl = env.get("timeline")
	var el = env.get("elapsed_s")
	has_timeline = tl is Array and el != null and tl.size() > 0
	if not has_timeline:
		_add_spell_cells(0, -INF, INF, cloud, rain)
		return
	var elapsed := float(el)
	var timeline: Array = tl
	var prev_w := weather
	for k in timeline.size():
		var start: float = timeline[k][0]
		var stop: float = timeline[k + 1][0] if k + 1 < timeline.size() else INF
		if stop <= elapsed - track_radius / _wind_speed() * 2.0:
			continue
		var eta := start - elapsed
		if eta > HORIZON_S:
			break
		_add_spell_cells(k, eta, stop - elapsed, timeline[k][1], timeline[k][2])
		if eta <= 0.0:
			continue
		var w := _weather_for(timeline[k][1], timeline[k][2])
		if w == prev_w:
			continue
		prev_w = w
		var spread := eta * (0.05 + 0.08 * eta / 1200.0)
		changes.append({"eta": eta, "eta_lo": maxf(eta - spread, 0.0), "eta_hi": eta + spread,
			"weather": w, "rain": timeline[k][2], "cloud": timeline[k][1],
			"confidence": clampf(0.97 - eta / 2400.0, 0.4, 0.97)})


## One line for the pit wall, e.g. "Light rain in 6-8 min (80%)".
func summary() -> String:
	if changes.is_empty():
		return "No change expected" if has_timeline else "Fixed conditions"
	var c: Dictionary = changes[0]
	return "%s in %s (%d%%)" % [weather_label(c["weather"]), eta_text(c), int(c["confidence"] * 100.0)]


## Will it be raining at the track `secs` from now (by the forecast)?
func rain_in(secs: float) -> float:
	var r := rain
	for c in changes:
		if c["eta"] <= secs:
			r = c["rain"]
	return r


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


func _wind_speed() -> float:
	return track_radius * 2.5 / RADAR_LEAD_S


## A spell of weather drawn as a band of cells. Its leading edge is upwind by
## how long until it arrives, its trailing edge by how long until it leaves.
func _add_spell_cells(k: int, eta: float, until: float, p_cloud: float, p_rain: float) -> void:
	if p_cloud < 0.5 and p_rain < 0.05:
		return
	var ws := _wind_speed()
	var lead := clampf(eta * ws, -radar_range * 1.2, radar_range * 1.3)
	var trail := clampf(until * ws, -radar_range * 1.2, radar_range * 1.3)
	if trail <= -radar_range or lead >= radar_range * 1.3:
		return
	var perp := Vector2(-wind_dir.y, wind_dir.x)
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed * 131 + k * 7919
	var step := track_radius * 0.55
	var d := lead
	var j := 0
	while d <= trail and j < 40:
		for lane in [-1.0, 0.0, 1.0]:
			var off: float = lane * track_radius * 0.9 + rng.randf_range(-0.35, 0.35) * track_radius
			var rad := track_radius * rng.randf_range(0.45, 0.8) * (0.7 + 0.5 * p_rain)
			var dd: float = d + rng.randf_range(0.0, step * 0.8)
			if dd > trail:
				continue
			var cell_rain: float = p_rain * rng.randf_range(0.6, 1.15)
			radar_cells.append({"pos": centre - wind_dir * dd + perp * off, "radius": rad,
				"rain": clampf(cell_rain, 0.0, 1.0), "cloud": p_cloud})
		d += step
		j += 1
