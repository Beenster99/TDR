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
##    penalty_s, points, fastest (bool)}

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
		var key := SeasonResults.key_for(e.is_ai, e.driver_name)
		var row := {"pos": p + 1, "car": i, "name": e.driver_name, "car_name": sim.defs[i].display_name,
			"is_ai": e.is_ai, "is_me": i == me, "status": status, "laps": e.laps_done, "time": time, "gap": gap,
			"best_lap": e.best_lap, "best_lap_no": best_no, "avg_lap": avg, "best_sectors": bs,
			"potential": potential, "stops": int(e.pit.get("stops", 0)), "penalty_s": e.penalty_s,
			"points": int(pts.get(key, 0)) if has_points else 0, "fastest": false, "jokers": e.jokers}
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
		"pits": sim.pits.enabled}


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
