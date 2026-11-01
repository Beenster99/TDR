class_name DriverCatalog
extends RefCounted
## Named AI drivers, read from modules/ai/data/drivers.json.
## Each driver: {id, name, number, nationality, age, style, team, potential,
## traits: {pace, consistency, aggression, overtaking, defending,
## tyre_management, wet_skill, composure}} (see DriverTraits).

const PATH := "res://modules/ai/data/drivers.json"


## Every driver, in file order.
static func load_all() -> Array:
	var d = JsonData.load_json(PATH)
	return d.get("drivers", []) if d is Dictionary else []


## Team names, in file order.
static func load_teams() -> Array:
	var d = JsonData.load_json(PATH)
	return d.get("teams", []) if d is Dictionary else []


## One driver by id (empty Dictionary if unknown).
static func find(drivers: Array, id: String) -> Dictionary:
	for d in drivers:
		if d.get("id", "") == id:
			return d
	return {}


## Lines for showing a driver's traits, e.g. in a lobby or results screen:
## [{key, label, value (0..100), help}]
static func describe_traits(driver: Dictionary) -> Array:
	var t := DriverTraits.from_dict(driver.get("traits", {}))
	var out := []
	for k in DriverTraits.NAMES:
		out.append({"key": k, "label": DriverTraits.LABELS[k], "value": int(round(t.get(k) * 100.0)),
			"help": DriverTraits.HELP[k]})
	return out


## Overall 0..100 rating used for sorting.
static func rating(driver: Dictionary) -> int:
	return DriverTraits.from_dict(driver.get("traits", {})).rating()
