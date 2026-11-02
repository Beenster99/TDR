class_name SeasonResults
extends RefCounted
## Turns a finished race or qualifying session into the plain result a
## season keeps: the classification, read from the sim, plus the fastest lap
## and the full race log from the race data (telemetry) module.

## Who a competitor is across a season: AI drivers by name, players by
## their player name (kept apart so a player can't take an AI's points).
static func key_for(is_ai: bool, driver_name: String) -> String:
	return ("ai:" if is_ai else "p:") + driver_name


## [{key, name, is_ai, car_id, position, dnf, laps, time, best_lap, penalty_s}]
## in finishing order (for qualifying: in order of best lap).
static func classification(sim: RaceSim) -> Array:
	var out := []
	for p in sim.running_order.size():
		var i: int = sim.running_order[p]
		var e: RaceEntry = sim.entries[i]
		out.append({"key": key_for(e.is_ai, e.driver_name), "name": e.driver_name, "is_ai": e.is_ai,
			"car_id": e.car_id, "position": p + 1, "dnf": e.dnf and not e.finished, "laps": e.laps_done,
			"time": e.finish_time + e.penalty_s if e.finished else 0.0, "best_lap": e.best_lap,
			"penalty_s": e.penalty_s})
	return out


## Everything a season stores about one session.
## {session, classification, fastest_key, fastest_lap, log (the telemetry's to_dict)}
static func from_race(sim: RaceSim, telemetry: RaceTelemetry) -> Dictionary:
	var fastest_key := ""
	var fastest_lap := 0.0
	if telemetry and telemetry.fastest_car >= 0:
		var e: RaceEntry = sim.entries[telemetry.fastest_car]
		fastest_key = key_for(e.is_ai, e.driver_name)
		fastest_lap = telemetry.fastest_lap
	else:  # no race data: take it from the lap times
		for e in sim.entries:
			if e.best_lap > 0.0 and (fastest_lap <= 0.0 or e.best_lap < fastest_lap):
				fastest_lap = e.best_lap
				fastest_key = key_for(e.is_ai, e.driver_name)
	return {"session": sim.settings.session_type, "track_id": sim.track.id,
		"classification": classification(sim), "fastest_key": fastest_key, "fastest_lap": fastest_lap,
		"log": telemetry.to_dict(sim) if telemetry else {}}
