class_name RaceSettings
extends RefCounted
## Host-chosen race options. In multiplayer the host's settings are sent to
## every client in the lobby (to_dict/from_dict) before the sim starts.

var track_id: String = "spielberg"
## Kind of racing (the race type): DISCIPLINE_CIRCUIT (road racing),
## DISCIPLINE_RALLYCROSS (mixed tarmac and dirt, short races, a joker lap,
## no pit stops, no co-op) or DISCIPLINE_DERBY (Demolition Derby: derby arenas
## and cars, damage always full, no safety car, no pit stops, no co-op car
## shares; see docs/DERBY.md). Tracks and car
## classes carry the same word.
var discipline: String = "circuit"
const DISCIPLINE_CIRCUIT := "circuit"
const DISCIPLINE_RALLYCROSS := "rallycross"
const DISCIPLINE_DERBY := "derby"
## Rallycross: joker laps each car must take in a race (taking the joker lane
## once), and the time added at the finish for each one missed.
var joker_laps: int = 1
const JOKER_MISSED_PENALTY_S := 30.0
## Most cars on a rallycross grid (the circuits are about a kilometre long).
const MAX_CARS_RALLYCROSS := 12
var laps: int = 3
var ai_count: int = 5
## Most cars on the grid (players + AI): one class, or several classes mixed.
const MAX_CARS_SINGLE_CLASS := 25
const MAX_CARS_MULTI_CLASS := 45
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
var tyre_wear_rate: float = 1.0    ## wear multiplier when tyre wear is on
var damage_enabled: bool = false  ## true unless damage_level is "off"
## Damage (CarDamage): "off", "visual" (bodywork bends, car drives as new)
## or "full" (aero, suspension, alignment, engine, gearbox, punctures).
var damage_level: String = "off"
var safety_car_enabled: bool = true  ## VSC + safety car (yellow flags always)
var mandatory_pit_stops: int = 0   ## stops each car must make inside the pit window
## Drivers sharing each car (1-3). With 2 or more, every AI car has a driver
## line-up that changes at its pit stops, and a solo player gets an AI
## co-driver they can hand the car to at a stop (see docs/PITS.md).
var drivers_per_car: int = 1
const MAX_DRIVERS_PER_CAR := 3
## Car setups (wave 4 per-track tuning): false = every car (players and AI)
## races the default setup and the race's fuel load, for equal-car races.
var tuning_enabled: bool = true
## Pit window (laps, inclusive) in which mandatory stops count. 0 = automatic:
## from about a fifth of the race in to a fifth before the end.
var pit_window_open_lap: int = 0
var pit_window_close_lap: int = 0
## Car upgrades (wave 4, host option): UPGRADES_ON = everyone races their
## upgraded cars, UPGRADES_BOP = balance of performance (upgrades are for
## looks only and every car in a class is brought to the same power-to-weight
## and downforce), UPGRADES_STOCK = factory cars. Track tuning has its own
## switch and is left alone here.
var upgrades_mode: String = "on"
const UPGRADES_ON := "on"
const UPGRADES_BOP := "bop"
const UPGRADES_STOCK := "stock"
var finish_timeout_s: float = 90.0 ## after the leader finishes
var countdown_s: float = 4.0
## "race" or "qualifying" (a timed session: classified by best lap, see RaceSim).
var session_type: String = "race"
const SESSION_RACE := "race"
const SESSION_QUALIFYING := "qualifying"


## Most cars this race may have (players and AI together).
func max_cars() -> int:
	return max_cars_for(car_class, discipline)


static func max_cars_for(p_class: String, p_discipline: String = DISCIPLINE_CIRCUIT) -> int:
	if p_discipline == DISCIPLINE_RALLYCROSS:
		return MAX_CARS_RALLYCROSS
	return MAX_CARS_MULTI_CLASS if p_class == CLASS_MULTI else MAX_CARS_SINGLE_CLASS


func is_rallycross() -> bool:
	return discipline == DISCIPLINE_RALLYCROSS


## Co-op crews and drivers sharing a car belong to circuit racing only.
func allows_coop() -> bool:
	return discipline == DISCIPLINE_CIRCUIT


func to_dict() -> Dictionary:
	return {
		"track_id": track_id, "car_class": car_class, "laps": laps, "ai_count": ai_count, "seed": seed,
		"environment": environment, "grid_order": grid_order, "ai_difficulty": ai_difficulty, "fuel_enabled": fuel_enabled, "fuel_rate": fuel_rate,
		"start_fuel_l": start_fuel_l, "tyre_wear_enabled": tyre_wear_enabled,
		"damage_enabled": damage_enabled, "damage_level": damage_level, "safety_car_enabled": safety_car_enabled,
		"mandatory_pit_stops": mandatory_pit_stops, "drivers_per_car": drivers_per_car, "finish_timeout_s": finish_timeout_s,
		"tyre_wear_rate": tyre_wear_rate, "pit_window_open_lap": pit_window_open_lap,
		"pit_window_close_lap": pit_window_close_lap,
		"countdown_s": countdown_s, "upgrades_mode": upgrades_mode, "tuning_enabled": tuning_enabled,
		"session_type": session_type, "discipline": discipline, "joker_laps": joker_laps,
	}


## Sets damage_level and keeps damage_enabled in step with it.
func set_damage_level(level: String) -> void:
	damage_level = level if level in ["off", "visual", "full"] else "off"
	damage_enabled = damage_level != "off"


## The damage level the sim uses. Older settings that only set
## damage_enabled = true mean full damage.
func effective_damage_level() -> String:
	if damage_level == "off" and damage_enabled:
		return "full"
	return damage_level


func is_derby() -> bool:
	return discipline == DISCIPLINE_DERBY


## Makes the settings fit a Demolition Derby: full damage, no safety car,
## no pit stops, fuel or tyre wear, one driver per car, the Derby class.
func apply_derby_rules() -> void:
	discipline = DISCIPLINE_DERBY
	car_class = "Derby"
	set_damage_level("full")
	safety_car_enabled = false
	mandatory_pit_stops = 0
	drivers_per_car = 1
	fuel_enabled = false
	tyre_wear_enabled = false
	session_type = SESSION_RACE


func is_qualifying() -> bool:
	return session_type == SESSION_QUALIFYING


static func from_dict(d: Dictionary) -> RaceSettings:
	var r := RaceSettings.new()
	for k in d:
		if k in r:
			r.set(k, d[k])
	return r
