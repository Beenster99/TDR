class_name RaceSettings
extends RefCounted
## Host-chosen race options. In multiplayer the host's settings are sent to
## every client in the lobby (to_dict/from_dict) before the sim starts.

var track_id: String = "spielberg"
var laps: int = 3
var ai_count: int = 5
var seed: int = 12345
## Which cars race: a class name (e.g. "GT3") = everyone in that class,
## CLASS_MULTI = classes mixed (AI spread over all classes), "" = open (AI
## drive the classes the players picked).
var car_class: String = ""
const CLASS_MULTI := "multi"
## Conditions (see SimEnvironment.create): time_of_day_h, time_scale,
## weather ("dry" | "overcast" | "light_rain" | "heavy_rain" | "random"),
## weather_changes (bool). Empty = the track's defaults.
var environment: Dictionary = {}
## Starting order: "standard" (AI ahead, humans behind), "random", or
## "reversed" (fastest car + driver at the back).
var grid_order: String = "standard"
## AI skill level, 0 = rookie .. 1 = alien (0.75 = the drivers as written).
var ai_difficulty: float = 0.75
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
		"track_id": track_id, "car_class": car_class, "laps": laps, "ai_count": ai_count, "seed": seed,
		"environment": environment, "grid_order": grid_order, "ai_difficulty": ai_difficulty, "fuel_enabled": fuel_enabled, "fuel_rate": fuel_rate,
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
