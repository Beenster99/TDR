class_name RaceSettings
extends RefCounted
## Host-chosen race options. In multiplayer the host's settings are sent to
## every client in the lobby (to_dict/from_dict) before the sim starts.

var track_id: String = "spielberg"
var laps: int = 3
var ai_count: int = 5
var seed: int = 12345
var environment: Dictionary = {}   ## empty = track default
## Wave 3 switches (already read by the sim where noted)
var fuel_enabled: bool = false     ## sim burns fuel when true
var fuel_rate: float = 1.0         ## consumption multiplier
var start_fuel_l: float = -1.0     ## -1 = full tank
var tyre_wear_enabled: bool = false
var damage_enabled: bool = false
var safety_car_enabled: bool = false
var mandatory_pit_stops: int = 0
var finish_timeout_s: float = 90.0 ## after the leader finishes
var countdown_s: float = 4.0


func to_dict() -> Dictionary:
	return {
		"track_id": track_id, "laps": laps, "ai_count": ai_count, "seed": seed,
		"environment": environment, "fuel_enabled": fuel_enabled, "fuel_rate": fuel_rate,
		"start_fuel_l": start_fuel_l, "tyre_wear_enabled": tyre_wear_enabled,
		"damage_enabled": damage_enabled, "safety_car_enabled": safety_car_enabled,
		"mandatory_pit_stops": mandatory_pit_stops, "finish_timeout_s": finish_timeout_s,
		"countdown_s": countdown_s,
	}


static func from_dict(d: Dictionary) -> RaceSettings:
	var r := RaceSettings.new()
	for k in d:
		if k in r:
			r.set(k, d[k])
	return r
