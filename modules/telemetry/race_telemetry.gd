class_name RaceTelemetry
extends RefCounted
## Race data for the pit manager and strategist. Watches a RaceSim (never
## changes it) and keeps, for every car: the lap-by-lap log with sector
## times, the last-5-lap average, gap to the leader, interval to the car
## ahead, tyre state and a pit-window analysis. Also builds the weather radar
## and forecast, and a feed of radio, strategy, timing and weather calls.
##
## Gaps are timed the way real timing does it: the lap is cut into timing
## loops (about every 80 m), every car's crossing time at each loop is
## recorded, and a gap is the difference between two cars' times at the
## same loop.
##
## Multiplayer: every machine runs one. The authority (offline / host) times
## the gaps, analyses pit windows and writes the feed; clients get gaps and
## pit analysis from the host (to_net / apply_net, inside the race state) and
## feed items as reliable race events. Lap logs, tyres and the weather
## forecast are worked out locally on every machine from data it already has.

const LOOP_SPACING := 80.0       ## metres between timing loops (rounded to fit the lap)
const KEEP_LAPS := 3             ## loop history kept per car (gaps to lapped cars)
const ANALYSE_EVERY := 15        ## ticks between gap / pit / feed updates (4 Hz)
const MAX_SPAN_SAMPLES := 5

var track: TrackData
var cars: Array[CarTelemetry] = []
var feed := RaceFeed.new()
var pit := PitWindow.new()
var forecast := WeatherForecast.new()
## Latest strategy line per car index: {text, plan, t}.
var strategies: Dictionary = {}
## Conditions sampled every time the leader completes a lap.
var weather_log: Array = []
var authority := true
var fastest_lap: float = 0.0
var fastest_car: int = -1
var best_sectors: PackedFloat64Array = []  ## overall best per sector

var loop_count: int = 1
var spacing: float = LOOP_SPACING
var _entry_loop := -1
var _exit_loop := -1
var _loops: Array = []            ## per car: loop index -> crossing time
var _prev_d := PackedFloat64Array()
var _prev_t: float = 0.0
var _laps_seen := PackedInt32Array()
var _in_pits_at := PackedFloat64Array()  ## per car: race time last seen in the pit lane
var _last_tick := -1
var _cool: Dictionary = {}        ## feed cooldowns: key -> race time last said
var _prev_pos := PackedInt32Array()
var _prev_interval := PackedFloat64Array()
var _prev_tyre: Array = []
var _prev_ideal: Array = []
var _announced_eta: Dictionary = {}
var _prev_weather := ""
var _leader_laps := 0
var _names: Array = []


static func create(sim: RaceSim, p_authority := true) -> RaceTelemetry:
	var t := RaceTelemetry.new()
	t.setup(sim, p_authority)
	return t


func setup(sim: RaceSim, p_authority := true) -> void:
	authority = p_authority
	track = sim.track
	loop_count = maxi(int(round(track.length / LOOP_SPACING)), 12)
	spacing = track.length / loop_count
	pit.setup(track)
	if pit.has_lane:
		_entry_loop = int(round(pit.entry_s / spacing)) % loop_count
		_exit_loop = int(round(pit.exit_s / spacing)) % loop_count
	forecast.setup(track, sim.settings.seed)
	forecast.update(sim.env)
	_prev_weather = forecast.weather
	best_sectors.resize(track.sectors.size())
	best_sectors.fill(0.0)
	for i in sim.car_count():
		var c := CarTelemetry.new()
		c.car = i
		c.best_sectors.resize(track.sectors.size())
		c.best_sectors.fill(0.0)
		c.grid_pos = sim.entries[i].position
		cars.append(c)
		_loops.append({})
		_prev_d.append(sim.entries[i].distance)
		_laps_seen.append(0)
		_prev_pos.append(sim.entries[i].position)
		_prev_interval.append(99.0)
		_prev_tyre.append("cold")
		_prev_ideal.append(false)
		_names.append(sim.entries[i].driver_name)
	_prev_t = sim.race_time


## Call once per tick after sim.step(). Returns the feed items this step
## created (authority only) as race events {"type": "feed", ...} for the
## session to broadcast. They're already in `feed`.
func observe(sim: RaceSim) -> Array:
	if sim.tick == _last_tick:
		return []
	_last_tick = sim.tick
	var out := []
	if _in_pits_at.size() != sim.car_count():
		_in_pits_at.resize(sim.car_count())
		_in_pits_at.fill(-1.0)
	for i in sim.car_count():
		_names[i] = sim.entries[i].driver_name
		if sim.in_pit_lane(i):
			_in_pits_at[i] = sim.race_time
	if sim.phase == RaceSim.Phase.COUNTDOWN:
		for i in sim.car_count():
			_prev_d[i] = sim.entries[i].distance
			cars[i].grid_pos = sim.entries[i].position
		_prev_t = sim.race_time
		return out
	var new_laps := _archive_laps(sim, out)
	if authority:
		_record_loops(sim)
	if sim.tick % ANALYSE_EVERY == 0 or new_laps:
		if authority:
			_compute_gaps(sim)
			pit.analyse(cars, sim)
		_update_tyres(sim)
		forecast.update(sim.env)
		if authority:
			_derive_feed(sim, out)
	return out


## Events from the race: AI radio / strategy calls (RaceSim.post_event), the
## host's feed items (clients), contacts.
func on_events(evs: Array) -> void:
	for ev in evs:
		match ev.get("type", ""):
			"radio":
				feed.add({"t": _now(), "lap": _leader_laps, "kind": "radio", "car": int(ev.get("car", -1)),
					"topic": ev.get("topic", ""), "text": str(ev.get("text", ""))})
			"strategy":
				var car := int(ev.get("car", -1))
				strategies[car] = {"text": str(ev.get("text", "")), "plan": ev.get("plan", {}), "t": _now()}
				feed.add({"t": _now(), "lap": _leader_laps, "kind": "strategy", "car": car,
					"text": str(ev.get("text", ""))})
			"pit_stop":
				var sc := int(ev.get("car", -1))
				if sc >= 0 and sc < cars.size():
					cars[sc].stops.append({"lap": int(ev.get("lap", 0)), "stationary_s": snappedf(float(ev.get("stationary_s", 0.0)), 0.01),
						"tyre": str(ev.get("tyre", "")), "fuel_l": snappedf(float(ev.get("fuel_l", 0.0)), 0.1),
						"driver": str(ev.get("driver", "")), "in_window": bool(ev.get("in_window", false))})
				# Driver line-ups: who took over in the box.
				var who := str(ev.get("driver", ""))
				if who != "":
					var car := int(ev.get("car", -1))
					feed.add({"t": _now(), "lap": _leader_laps, "kind": "pit", "car": car,
						"text": "Driver change: %s takes over the car" % who})
			"flag", "safety_car", "penalty", "warning":
				# Race control (wave 3 safety car / stewards), shown as it comes.
				var text := str(ev.get("text", ev.get("reason", "")))
				match ev["type"]:
					"flag":
						if ev.get("flag", "") in ["yellow", "clear"]:
							text = "%s flag%s" % [str(ev.get("flag", "")).capitalize(), (": " + text) if text != "" else ""]
					"safety_car":
						text = "%s%s" % [{"vsc": "Virtual safety car", "sc": "Safety car deployed", "green": "Green flag, racing resumes",
							"in_this_lap": "Safety car in this lap", "vsc_ending": "VSC ending",
							"lapped_may_overtake": "Lapped cars may overtake",
							"restart": "Safety car in, restart"}.get(str(ev.get("state", "")), str(ev.get("state", ""))),
							(": " + text) if text != "" else ""]
					"penalty":
						text = "%s: %.0f s penalty%s" % [driver_name(int(ev.get("car", -1))), float(ev.get("seconds", 0.0)),
							(" (" + text + ")") if text != "" else ""]
					"warning":
						text = "%s: %s" % [driver_name(int(ev.get("car", -1))), text]
				feed.add({"t": _now(), "lap": _leader_laps, "kind": "race_control", "car": int(ev.get("car", -1)), "text": text})
			"feed":
				if not authority:
					var it: Dictionary = ev.duplicate()
					it.erase("type")
					feed.add(it)


var _race_time := 0.0


func _now() -> float:
	return _race_time


## Who's who in feed text.
func driver_name(car: int) -> String:
	return _names[car] if car >= 0 and car < _names.size() else ""


# --- Lap log -----------------------------------------------------------------

func _archive_laps(sim: RaceSim, out: Array) -> bool:
	_race_time = sim.race_time
	var any := false
	for i in sim.car_count():
		var e := sim.entries[i]
		var c := cars[i]
		while _laps_seen[i] < e.lap_times.size():
			var k := _laps_seen[i]
			_laps_seen[i] += 1
			any = true
			var newest := _laps_seen[i] == e.lap_times.size()
			var sectors: Array = Array(e.last_sector_times) if newest else []
			var car := sim.cars[i]
			var temps := Array(car.tyre_temp)
			var avg := 0.0
			for t in temps:
				avg += t
			avg /= maxf(temps.size(), 1.0)
			var lap_time := e.lap_times[k]
			var stops_now := int(e.pit.get("stops", 0)) if newest else (int(c.laps[-1].get("stops", 0)) if not c.laps.is_empty() else 0)
			c.laps.append({"lap": k + 1, "time": lap_time, "sectors": sectors, "position": e.position,
				"gap_leader": snappedf(c.gap_leader, 0.001), "tyre_avg_c": snappedf(avg, 0.1),
				"tyre_temps": temps.map(func(x): return snappedf(x, 0.1)), "fuel_l": snappedf(car.fuel_l, 0.01),
				"weather": sim.env.weather, "wetness": snappedf(sim.env.wetness, 0.01),
				"race_time": snappedf(sim.race_time, 0.001),
				"compound": sim.compounds[i].id if i < sim.compounds.size() and sim.compounds[i] else "",
				"stops": stops_now, "pitted": stops_now > (int(c.laps[-1].get("stops", 0)) if not c.laps.is_empty() else 0)})
			c.update_average()
			for s in sectors.size():
				if s < c.best_sectors.size() and (c.best_sectors[s] <= 0.0 or sectors[s] < c.best_sectors[s]):
					c.best_sectors[s] = sectors[s]
				if s < best_sectors.size() and (best_sectors[s] <= 0.0 or sectors[s] < best_sectors[s]):
					best_sectors[s] = sectors[s]
			if fastest_lap <= 0.0 or lap_time < fastest_lap:
				var had := fastest_lap > 0.0
				fastest_lap = lap_time
				fastest_car = i
				if authority and had and k >= 1:
					_say(out, "timing", i, "Fastest lap: %s, %s" % [driver_name(i), _fmt(lap_time)], "fl", 15.0)
			if sim.running_order.size() > 0 and i == sim.running_order[0] and e.laps_done > _leader_laps:
				_leader_laps = e.laps_done
				weather_log.append({"lap": _leader_laps, "t": snappedf(sim.race_time, 0.1), "weather": sim.env.weather,
					"wetness": snappedf(sim.env.wetness, 0.01), "track_c": snappedf(sim.env.track_c, 0.1),
					"ambient_c": snappedf(sim.env.ambient_c, 0.1)})
	return any


# --- Timing loops and gaps --------------------------------------------------

func _record_loops(sim: RaceSim) -> void:
	var t1 := sim.race_time
	var t0 := _prev_t
	_prev_t = t1
	if sim.phase == RaceSim.Phase.FINISHED:
		return
	for i in sim.car_count():
		var e := sim.entries[i]
		var d1 := e.distance
		var d0 := _prev_d[i]
		_prev_d[i] = d1
		if e.finished or e.dnf or d1 <= d0 or t1 <= t0:
			continue
		var k0 := int(floor(d0 / spacing)) + 1
		var k1 := int(floor(d1 / spacing))
		if k1 - k0 > 20:
			k0 = k1 - 20
		var loops: Dictionary = _loops[i]
		for k in range(k0, k1 + 1):
			var f := (k * spacing - d0) / (d1 - d0)
			var t := t0 + (t1 - t0) * f
			loops[k] = t
			_on_loop(i, k, t)
		if k1 % loop_count == 0 and k1 >= k0:
			var oldest := k1 - KEEP_LAPS * loop_count
			for key in loops.keys():
				if key < oldest:
					loops.erase(key)


func _on_loop(i: int, k: int, t: float) -> void:
	if _exit_loop < 0 or posmod(k, loop_count) != _exit_loop:
		return
	var span := posmod(_exit_loop - _entry_loop, loop_count)
	if span == 0:
		return
	var t_entry = _loops[i].get(k - span)
	if t_entry == null:
		return
	if i < _in_pits_at.size() and _in_pits_at[i] >= float(t_entry):
		return  # it went through the pit lane: not a time on track
	var c := cars[i]
	c.span_times.append(t - float(t_entry))
	if c.span_times.size() > MAX_SPAN_SAMPLES:
		c.span_times.remove_at(0)


## Time car `behind` lost to car `ahead` at the last loop `behind` crossed;
## falls back to distance over speed when the loop history doesn't reach.
func _gap(sim: RaceSim, behind: int, ahead: int) -> float:
	var d := sim.entries[behind].distance
	var k := int(floor(d / spacing))
	var tb = _loops[behind].get(k)
	var ta = _loops[ahead].get(k)
	if tb != null and ta != null:
		return maxf(float(tb) - float(ta), 0.0)
	var dd := sim.entries[ahead].distance - d
	var c := cars[behind]
	var v := track.length / c.last5_avg if c.last5_avg > 0.0 else maxf(sim.cars[behind].speed(), 30.0)
	return maxf(dd / v, 0.0)


func _compute_gaps(sim: RaceSim) -> void:
	var order := sim.running_order
	if order.is_empty():
		return
	var leader := order[0]
	for p in order.size():
		var i := order[p]
		var e := sim.entries[i]
		var c := cars[i]
		if e.finished or e.dnf:
			continue
		if p == 0:
			c.gap_leader = 0.0
			c.interval = 0.0
			c.laps_down = 0
		else:
			c.gap_leader = _gap(sim, i, leader)
			c.interval = _gap(sim, i, order[p - 1])
			# A car that has just got by is ahead on the road before the next
			# timing loop says so: never show it closer to the leader than
			# the car it passed.
			var prev := sim.entries[order[p - 1]]
			if p > 1 and not (prev.finished or prev.dnf):
				c.gap_leader = maxf(c.gap_leader, cars[order[p - 1]].gap_leader)
			c.laps_down = int(floor((sim.entries[leader].distance - e.distance) / track.length))
	for p in order.size():
		var c := cars[order[p]]
		c.gap_behind = cars[order[p + 1]].interval if p + 1 < order.size() else -1.0


func _update_tyres(sim: RaceSim) -> void:
	for i in sim.car_count():
		var car := sim.cars[i]
		var tc := sim.compounds[i]
		var grip := 0.0
		var hot := 0
		var cold := 0
		for k in 4:
			var t := car.tyre_temp[k]
			grip += tc.temp_grip_factor(t)
			if t > tc.optimal_temp_c + tc.temp_window_c * 0.6:
				hot += 1
			elif t < tc.optimal_temp_c - tc.temp_window_c * 0.6:
				cold += 1
		cars[i].tyre_grip = grip / 4.0
		cars[i].tyre_state = "hot" if hot >= 2 else ("cold" if cold >= 2 else "ok")


# --- Feed ----------------------------------------------------------------------

func _say(out: Array, kind: String, car: int, text: String, key: String, cooldown: float, car2 := -1) -> void:
	if key != "":
		var last = _cool.get(key)
		if last != null and _race_time - float(last) < cooldown:
			return
		_cool[key] = _race_time
	var it := {"t": snappedf(_race_time, 0.01), "lap": _leader_laps, "kind": kind, "car": car, "text": text}
	if car2 >= 0:
		it["car2"] = car2
	feed.add(it)
	var ev := it.duplicate()
	ev["type"] = "feed"
	out.append(ev)


func _derive_feed(sim: RaceSim, out: Array) -> void:
	var racing := sim.phase == RaceSim.Phase.RACING or sim.phase == RaceSim.Phase.CHEQUERED
	var order := sim.running_order
	for p in order.size():
		var i := order[p]
		var e := sim.entries[i]
		var c := cars[i]
		if e.finished or e.dnf or not racing:
			_prev_pos[i] = e.position
			continue
		# Overtakes in the top ten (not in the first-lap scramble).
		if e.position < _prev_pos[i] and e.position <= 10 and _leader_laps >= 1 and p + 1 < order.size():
			var j := order[p + 1]
			if _prev_pos[j] == e.position:
				_say(out, "timing", i, "%s passes %s for P%d" % [driver_name(i), driver_name(j), e.position],
					"pass%d_%d" % [mini(i, j), maxi(i, j)], 20.0, j)
		_prev_pos[i] = e.position
		# Closing in: inside a second of the car ahead.
		if p > 0 and e.laps_done >= 1 and c.interval < 1.0 and _prev_interval[i] >= 1.2:
			_say(out, "timing", i, "%s is within a second of %s for P%d" % [driver_name(i),
				driver_name(order[p - 1]), e.position - 1], "close%d" % i, 60.0, order[p - 1])
		_prev_interval[i] = c.interval
		# Tyres going out of their window.
		if c.tyre_state == "hot" and _prev_tyre[i] != "hot" and e.laps_done >= 1:
			_say(out, "tyres", i, "%s: tyres overheating (%d°C, grip %d%%)" % [driver_name(i),
				int(_avg(sim.cars[i].tyre_temp)), int(c.tyre_grip * 100.0)], "hot%d" % i, 90.0)
		_prev_tyre[i] = c.tyre_state
		# A gap has opened for a stop that loses no places.
		var ideal: bool = c.pit.get("ideal", false)
		if ideal and not _prev_ideal[i] and e.laps_done >= 1 and e.laps_done < sim.settings.laps - 1:
			_say(out, "pit", i, "Pit window: %s can stop now and rejoin P%d in clear air (gap behind %.1f s, pit loss %.1f s)" % [
				driver_name(i), c.pit["rejoin_pos"], maxf(c.gap_behind, 0.0), c.pit["loss"]], "pit%d" % i, 120.0)
		_prev_ideal[i] = ideal
	for ev in sim.events:
		if ev.get("type", "") == "collision" and float(ev.get("impulse", 0.0)) > 2500.0 and racing:
			var a := int(ev["a"])
			var b := int(ev["b"])
			_say(out, "incident", a, "Contact: %s and %s" % [driver_name(a), driver_name(b)],
				"hit%d_%d" % [mini(a, b), maxi(a, b)], 15.0, b)
	# Weather: what the radar shows coming, and changes as they happen.
	if forecast.weather != _prev_weather:
		_say(out, "weather", -1, "Weather now %s, track %d°C, wetness %d%%" % [
			WeatherForecast.weather_label(forecast.weather).to_lower(), int(forecast.track_c),
			int(forecast.wetness * 100.0)], "wx_now", 30.0)
		_prev_weather = forecast.weather
	if not forecast.changes.is_empty():
		var ch: Dictionary = forecast.changes[0]
		for mark in [600.0, 300.0, 120.0]:
			var key := "%s@%d:%d" % [ch["weather"], int(mark), int(ch.get("k", int(_race_time + ch["eta"]) / 30))]
			if ch["eta"] <= mark and ch["eta"] > mark - 60.0 and not _announced_eta.has(key):
				_announced_eta[key] = true
				_say(out, "weather", -1, "Radar: %s in %s (%d%% likely)" % [
					WeatherForecast.weather_label(ch["weather"]).to_lower(), WeatherForecast.eta_text(ch),
					int(ch["confidence"] * 100.0)], "", 0.0)


# --- Pace and who's racing whom (the strategist's pace table) -----------------

## The pace measures the pit wall ranks cars on.
const PACE_KEYS := ["last", "avg3", "avg5"]
const PACE_LABELS := {"last": "LAST LAP", "avg3": "LAST 3", "avg5": "LAST 5"}


## Car i's time on a pace measure (0 = no time yet).
func pace_value(i: int, key: String) -> float:
	var c := cars[i]
	match key:
		"last": return c.last_lap()
		"avg3": return c.avg_last(3)
		"avg5": return c.last5_avg
	return 0.0


## Every car still racing with a time, fastest first, on each pace measure:
## {"last": [car, ...], "avg3": [...], "avg5": [...]}. With a class tag only
## cars of that class (multi-class races rank each class on its own).
func pace_ranks(sim: RaceSim, cls := "") -> Dictionary:
	var out := {}
	for key in PACE_KEYS:
		var list: Array = []
		for i in sim.car_count():
			if sim.is_retired(i) or (cls != "" and sim.defs[i].class_tag != cls):
				continue
			if pace_value(i, key) > 0.0:
				list.append(i)
		list.sort_custom(func(a: int, b: int): return pace_value(a, key) < pace_value(b, key))
		out[key] = list
	return out


## True when the race has more than one class of car.
static func multi_class(sim: RaceSim) -> bool:
	for i in sim.car_count():
		if sim.defs[i].class_tag != sim.defs[0].class_tag:
			return true
	return false


## Laps `other` is down on `car`, to the nearest lap: 1 for a car we have
## lapped or are about to lap (more than half a lap behind us in race
## distance), 0 on our lap, negative when they're ahead.
func laps_behind(sim: RaceSim, car: int, other: int) -> int:
	return roundi((sim.entries[car].distance - sim.entries[other].distance) / track.length)


## A backmarker for `car`: a car still running more than half a lap behind it
## in race distance, so one it has lapped or is coming up to lap (blue flags).
func is_backmarker(sim: RaceSim, car: int, other: int) -> bool:
	if car < 0 or other < 0 or other == car or sim.entries[other].dnf or sim.entries[other].finished:
		return false
	return laps_behind(sim, car, other) >= 1


## The car `car` is really racing: of the cars in its class on the same lap,
## the nearer of the one just ahead and the one just behind (by time).
## -1 when there's nobody (alone in its class, or finished).
func rival_of(sim: RaceSim, car: int) -> int:
	if car < 0 or car >= sim.car_count() or sim.entries[car].finished or sim.entries[car].dnf:
		return -1
	var cls := sim.defs[car].class_tag
	var order := sim.running_order
	var p := order.find(car)
	var ahead := -1
	var behind := -1
	for k in range(p - 1, -1, -1):
		var j := order[k]
		if sim.defs[j].class_tag == cls and not sim.entries[j].dnf and laps_behind(sim, j, car) == 0 and not sim.entries[j].finished:
			ahead = j
			break
	for k in range(p + 1, order.size()):
		var j := order[k]
		if sim.defs[j].class_tag == cls and not sim.entries[j].dnf and laps_behind(sim, car, j) == 0:
			behind = j
			break
	if ahead < 0:
		return behind
	if behind < 0:
		return ahead
	return ahead if _gap(sim, car, ahead) <= _gap(sim, behind, car) else behind


## Backmarkers up the road from `car`, nearest first, up to `most`:
## [{car, laps (down on us), metres, seconds (on the road at our pace)}].
## Only those within half a lap ahead on the road: the ones we'll come up on
## soon (not the ones we've just lapped, behind us).
func backmarkers_ahead(sim: RaceSim, car: int, most := 3) -> Array:
	var out: Array = []
	if car < 0:
		return out
	var c := cars[car]
	var v := track.length / c.last5_avg if c.last5_avg > 0.0 else maxf(sim.cars[car].speed(), 30.0)
	var d := sim.entries[car].distance
	for j in sim.car_count():
		if not is_backmarker(sim, car, j) or sim.in_pit_lane(j):
			continue
		var m := fposmod(sim.entries[j].distance - d, track.length)
		if m > track.length * 0.5:
			continue
		out.append({"car": j, "laps": laps_behind(sim, car, j), "metres": m, "seconds": m / v})
	out.sort_custom(func(a: Dictionary, b: Dictionary): return float(a["metres"]) < float(b["metres"]))
	return out.slice(0, most)


static func _avg(a: PackedFloat64Array) -> float:
	var s := 0.0
	for x in a:
		s += x
	return s / maxf(a.size(), 1.0)


static func _fmt(t: float) -> String:
	if t <= 0.0:
		return "--:--.---"
	return "%d:%06.3f" % [int(t) / 60, fmod(t, 60.0)]


# --- Sync and export -----------------------------------------------------------

## Host -> clients, inside the race state (2 Hz): gaps, intervals, pit analysis.
func to_net() -> Dictionary:
	var a := []
	for c in cars:
		a.append(c.to_net())
	return {"cars": a}


func apply_net(d: Dictionary) -> void:
	var a: Array = d.get("cars", [])
	for i in mini(a.size(), cars.size()):
		cars[i].apply_net(a[i])


## The whole race's data, for saving after the race.
func to_dict(sim: RaceSim) -> Dictionary:
	var car_data := []
	for i in cars.size():
		var d := cars[i].to_dict()
		d["driver"] = sim.entries[i].driver_name
		d["car_id"] = sim.entries[i].car_id
		d["is_ai"] = sim.entries[i].is_ai
		d["position"] = sim.entries[i].position
		d["strategy"] = strategies.get(i, {})
		car_data.append(d)
	return {"format": 1, "track": track.id, "track_name": track.display_name, "settings": sim.settings.to_dict(),
		"race_time": sim.race_time, "fastest_lap": fastest_lap, "fastest_car": fastest_car,
		"best_sectors": Array(best_sectors), "pit_lane_time": pit.lane_time, "pit_stop_time": pit.stop_time_s,
		"cars": car_data, "feed": feed.items, "weather": weather_log}
