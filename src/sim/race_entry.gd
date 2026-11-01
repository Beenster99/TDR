class_name RaceEntry
extends RefCounted
## One competitor: who is driving what, plus race progress and timing.

var driver_name: String = ""
var is_ai: bool = false
## Players attached to this car, each with a role. Wave 1 uses one "driver"
## per car; co-op (wave 4) adds "pit_crew" / "strategist" members. Only the
## driver's inputs steer the car. [{ "peer_id": int, "name": String, "role": String }]
var crew: Array = []
var car_id: String = ""
var traits: Dictionary = {}
var setup: Dictionary = {}       ## tuning overrides (wave 4)

var started_lap: bool = false    ## crossed the line once (off the grid)
var laps_done: int = 0
var lap_start_time: float = 0.0
var lap_times: PackedFloat64Array = []
var best_lap: float = 0.0
var sector_times: PackedFloat64Array = []  ## current lap
var last_sector_times: PackedFloat64Array = []
var next_sector: int = 1
var sector_start_time: float = 0.0
var distance: float = 0.0        ## total race distance, for running order
var finished: bool = false
var finish_time: float = 0.0
var dnf: bool = false
var position: int = 0


func to_dict() -> Dictionary:
	return {
		"started_lap": started_lap, "laps_done": laps_done, "lap_start_time": lap_start_time,
		"lap_times": lap_times.duplicate(), "best_lap": best_lap, "sector_times": sector_times.duplicate(),
		"last_sector_times": last_sector_times.duplicate(), "next_sector": next_sector,
		"sector_start_time": sector_start_time, "distance": distance,
		"finished": finished, "finish_time": finish_time, "dnf": dnf, "position": position,
	}


func from_dict(d: Dictionary) -> void:
	for k in d:
		var v = d[k]
		set(k, v.duplicate() if v is PackedFloat64Array else v)


func describe() -> Dictionary:
	return {"driver_name": driver_name, "is_ai": is_ai, "crew": crew,
		"car_id": car_id, "traits": traits, "setup": setup}


static func from_description(d: Dictionary) -> RaceEntry:
	var e := RaceEntry.new()
	e.driver_name = d.get("driver_name", "")
	e.is_ai = d.get("is_ai", false)
	e.crew = d.get("crew", []).duplicate(true)
	e.car_id = d.get("car_id", "")
	e.traits = d.get("traits", {})
	e.setup = d.get("setup", {})
	return e


const ROLE_DRIVER := "driver"
const ROLE_PIT_CREW := "pit_crew"
const ROLE_STRATEGIST := "strategist"


## Peer whose inputs drive this car (0 = local/offline player, -1 = nobody).
func driver_peer() -> int:
	for m in crew:
		if m.get("role", "") == ROLE_DRIVER:
			return int(m.get("peer_id", 0))
	return -1


func has_peer(peer_id: int) -> bool:
	for m in crew:
		if int(m.get("peer_id", 0)) == peer_id:
			return true
	return false
