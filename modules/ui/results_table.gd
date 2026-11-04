class_name ResultsTable
extends RefCounted
## The numbers behind the race results screen (RaceResults), worked out from
## the finished race (RaceSim) and its race data (RaceTelemetry). Pure: no
## nodes, no autoloads, so every machine online builds the same table from
## the same synced race, and the tests can check it.
##
## build() returns:
##   {title_session, track, laps, rows: [row, ...], fastest: {car, name, time, lap},
##    best_sectors: [s1, s2, s3] (the whole field's), sector_count,
##    penalties: [{car, name, seconds, reason}], has_points, points_name, quali, derby}
## Each row:
##   {pos, car, name, car_name, is_ai, is_me, status ("" | "DNF" | "OUT"),
##    laps, time (incl. penalties, 0 = not classified), gap ("+12.345" / "+1 lap"),
##    best_lap, best_lap_no, avg_lap, best_sectors: [..], potential, stops,
##    penalty_s, points, fastest (bool), racing (still out on track: the
##    results are filling up while the race runs on),
##    grid (start position, 0 = unknown), gained (grid - pos, + = places won),
##    lap_log: [{lap, time, sectors, pos, gap (s to the leader's crossing of
##      that lap), compound, pitted, fuel_l, tyre_c, weather, wear: [fl, fr,
##      rl, rr] (0 new .. 1 worn out, at the line; empty in old data)}],
##    stints: [{compound, from, to, laps, wear_end: [fl, fr, rl, rr]}], stop_log: [{lap, stationary_s, tyre, fuel_l, driver}]}
## and for the analysis charts: max_laps, compounds: {id -> short name},
## wear (true when tyre wear was on in this race).

const SINGLE_RACE_POINTS := "f1"


## opts:
##   me: the car this player drives or crews (-1 none)
##   penalties: [{car, seconds, reason}] seen during the race (race events)
##   points: {driver key -> points} (a season's points; empty = single race)
##   points_name: shown under the table
##   single_race_points: true = score a single race with the F1 points
static func build(sim: RaceSim, telemetry: RaceTelemetry, opts := {}) -> Dictionary:
	var me := int(opts.get("me", -1))
	var quali := sim.settings.is_qualifying()
	var derby := sim.settings.is_derby()
	var sector_count := sim.track.sectors.size()
	var pts: Dictionary = opts.get("points", {})
	var points_name := str(opts.get("points_name", ""))
	var has_points := not quali and not derby and (not pts.is_empty() or bool(opts.get("single_race_points", false)))
	if has_points and pts.is_empty():
		var ps := PointsSystem.from_preset(SINGLE_RACE_POINTS)
		pts = Season.race_points(ps, SeasonResults.classification(sim), _fastest_key(sim, telemetry), "")
		points_name = ps.display_name()
	var field_best := []
	for s in sector_count:
		field_best.append(telemetry.best_sectors[s] if telemetry and s < telemetry.best_sectors.size() else 0.0)
	var fastest := {}
	var rows := []
	# When the first car crossed the line at the end of each lap (the leader).
	var lead_t := []
	if telemetry:
		for ct0 in telemetry.cars:
			for l in ct0.laps:
				var k := int(l.get("lap", 0)) - 1
				if k < 0:
					continue
				while lead_t.size() <= k:
					lead_t.append(INF)
				lead_t[k] = minf(lead_t[k], float(l.get("race_time", INF)))
	var compounds := {}
	var max_laps := 0
	var leader_laps := 0
	var leader_time := 0.0
	for p in sim.running_order.size():
		var i: int = sim.running_order[p]
		var e: RaceEntry = sim.entries[i]
		var ct: CarTelemetry = telemetry.cars[i] if telemetry and i < telemetry.cars.size() else null
		var best_no := 0
		for k in e.lap_times.size():
			if e.lap_times[k] == e.best_lap:
				best_no = k + 1
				break
		var bs := []
		var potential := 0.0
		for s in sector_count:
			var v := ct.best_sectors[s] if ct and s < ct.best_sectors.size() else 0.0
			bs.append(v)
			potential = potential + v if v > 0.0 and potential >= 0.0 else -1.0
		if potential <= 0.0:
			potential = 0.0
		var avg := 0.0
		if not e.lap_times.is_empty():
			for t in e.lap_times:
				avg += t
			avg /= e.lap_times.size()
		var status := ""
		if e.dnf and not e.finished:
			status = "OUT" if derby else "DNF"
		var time := e.finish_time + e.penalty_s if e.finished else 0.0
		if p == 0:
			leader_laps = e.laps_done
			leader_time = time
		var gap := ""
		if p > 0 and status == "" and not quali and not derby:
			if e.laps_done < leader_laps:
				var down := leader_laps - e.laps_done
				gap = "+%d lap%s" % [down, "" if down == 1 else "s"]
			elif time > 0.0 and leader_time > 0.0:
				gap = "+%.3f" % (time - leader_time)
		var lap_log := []
		var stints := []
		# The laps the car came into the pits on (a stop counts in its in-lap).
		var stop_laps := {}
		for st0 in (ct.stops if ct else []):
			stop_laps[int(st0.get("lap", 0))] = true
		if ct and ct.stops.is_empty():
			for l0 in ct.laps:   # no stop log (old data): the lap the count went up, less one
				if l0.get("pitted", false):
					stop_laps[maxi(int(l0.get("lap", 1)) - 1, 1)] = true
		for l in (ct.laps if ct else []):
			var k := int(l.get("lap", 0))
			var cid := str(l.get("compound", ""))
			if cid != "" and not compounds.has(cid):
				compounds[cid] = short_compound(sim, cid)
			var lt := float(l.get("race_time", 0.0))
			var gap_s := lt - float(lead_t[k - 1]) if k >= 1 and k <= lead_t.size() and lead_t[k - 1] < INF else 0.0
			lap_log.append({"lap": k, "time": float(l.get("time", 0.0)), "sectors": l.get("sectors", []),
				"pos": int(l.get("position", 0)), "gap": maxf(gap_s, 0.0), "compound": cid,
				"pitted": stop_laps.has(k), "fuel_l": float(l.get("fuel_l", 0.0)),
				"tyre_c": float(l.get("tyre_avg_c", 0.0)), "weather": str(l.get("weather", "")),
				"wear": (l.get("tyre_wear", []) as Array).duplicate()})
			# A new stint after a stop or when the tyre on the car changes.
			if stints.is_empty() or stop_laps.has(k - 1) or (cid != "" and cid != str(stints[-1]["compound"])):
				if not stints.is_empty() and int(stints[-1]["to"]) >= k:
					stints[-1]["to"] = k - 1
				stints.append({"compound": cid, "from": k, "to": k})
			else:
				stints[-1]["to"] = k
			max_laps = maxi(max_laps, k)
		for st in stints:
			st["laps"] = int(st["to"]) - int(st["from"]) + 1
			st["wear_end"] = stint_wear(lap_log, int(st["from"]), int(st["to"]))
		var grid := ct.grid_pos if ct else 0
		var key := SeasonResults.key_for(e.is_ai, e.driver_name)
		var row := {"pos": p + 1, "car": i, "name": e.driver_name, "car_name": sim.defs[i].display_name,
			"is_ai": e.is_ai, "is_me": i == me, "status": status, "laps": e.laps_done, "time": time, "gap": gap,
			"best_lap": e.best_lap, "best_lap_no": best_no, "avg_lap": avg, "best_sectors": bs,
			"potential": potential, "stops": int(e.pit.get("stops", 0)), "penalty_s": e.penalty_s,
			"points": int(pts.get(key, 0)) if has_points else 0, "fastest": false, "jokers": e.jokers,
			"racing": not e.finished and not e.dnf,
			"grid": grid, "gained": grid - (p + 1) if grid > 0 else 0, "lap_log": lap_log, "stints": stints,
			"stop_log": (ct.stops.duplicate(true) if ct else [])}
		rows.append(row)
		if e.best_lap > 0.0 and (fastest.is_empty() or e.best_lap < float(fastest["time"])):
			fastest = {"car": i, "name": e.driver_name, "time": e.best_lap, "lap": best_no}
	for r in rows:
		if not fastest.is_empty() and r["car"] == fastest["car"]:
			r["fastest"] = true
	var pens := []
	for pen in opts.get("penalties", []):
		var c := int(pen.get("car", -1))
		if c >= 0 and c < sim.car_count():
			pens.append({"car": c, "name": sim.entries[c].driver_name, "seconds": float(pen.get("seconds", 0.0)),
				"reason": str(pen.get("reason", ""))})
	return {"track": sim.track.display_name, "laps": sim.settings.laps, "rows": rows, "fastest": fastest,
		"best_sectors": field_best, "sector_count": sector_count, "penalties": pens, "has_points": has_points,
		"points_name": points_name, "quali": quali, "derby": derby,
		"rallycross": sim.settings.is_rallycross() and sim.track.has_joker(), "joker_laps": sim.settings.joker_laps,
		"pits": sim.pits.enabled, "max_laps": max_laps, "compounds": compounds,
		"wear": sim.settings.tyre_wear_enabled}


## Each tyre's wear by the end of a stint (laps from..to): the most it got
## to in those laps, so it's right whether the stop came before or after the
## line on the in-lap. Empty when the log has no wear (old data).
static func stint_wear(lap_log: Array, from: int, to: int) -> Array:
	var out := []
	for l in lap_log:
		var k := int(l.get("lap", 0))
		var w: Array = l.get("wear", [])
		if k < from or k > to or w.size() < 4:
			continue
		if out.is_empty():
			out = [0.0, 0.0, 0.0, 0.0]
		for t in 4:
			out[t] = maxf(out[t], float(w[t]))
	return out


## A tyre's colour by its wear (0 new .. 1 worn out), as the pit planner
## shows it: green, then yellow past 45 % worn, red past 70 %.
static func wear_colour(wear: float) -> Color:
	return Color(1.0, 0.4, 0.35) if wear > 0.7 else (Color(1.0, 0.88, 0.35) if wear > 0.45 else Color(0.4, 1.0, 0.5))


## A tyre's colour on the results graphs (the pit planner's: wets blue,
## intermediates green, dry tyres white).
static func compound_colour(id: String) -> Color:
	if id.contains("wet"):
		return Color(0.35, 0.55, 1.0)
	if id.contains("inter"):
		return Color(0.35, 0.85, 0.4)
	return Color(0.92, 0.92, 0.92)


## A tyre's short name for the tables ("Slick", "Inter", "Wet").
static func short_compound(sim: RaceSim, id: String) -> String:
	if id.contains("inter"):
		return "Inter"
	if id.contains("wet"):
		return "Wet"
	var short := {"race_slick": "Slick", "road_semi_slick": "Semi-slick", "rx_tyre": "RX", "derby_tyre": "Derby"}
	if short.has(id):
		return short[id]
	if sim.tyre_defs.has(id):
		return str(sim.tyre_defs[id].display_name)
	return id.capitalize()


static func _fastest_key(sim: RaceSim, telemetry: RaceTelemetry) -> String:
	var car := telemetry.fastest_car if telemetry else -1
	if car < 0:   # no race data: the lap times
		var best := 0.0
		for i in sim.car_count():
			var b := sim.entries[i].best_lap
			if b > 0.0 and (best <= 0.0 or b < best):
				best = b
				car = i
	return SeasonResults.key_for(sim.entries[car].is_ai, sim.entries[car].driver_name) if car >= 0 else ""


## The cars still racing, in running order (for the spectator's car picker).
static func still_racing(sim: RaceSim) -> Array:
	var out := []
	for i in sim.running_order:
		var e: RaceEntry = sim.entries[i]
		if not e.finished and not e.dnf:
			out.append(i)
	return out


## The car after (step 1) or before (step -1) `car` in the running order,
## skipping retired cars that the marshals took away.
static func next_car(sim: RaceSim, car: int, step: int) -> int:
	var order: Array = Array(sim.running_order)
	var visible := []
	for i in order:
		if not sim.race_control.recovered[i]:
			visible.append(i)
	if visible.is_empty():
		return car
	var k := visible.find(car)
	if k < 0:
		return visible[0]
	return visible[wrapi(k + step, 0, visible.size())]
