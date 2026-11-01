class_name DriverCatalog
extends RefCounted
## AI driver names and traits, read from modules/ai/data/drivers.json.

const PATH := "res://modules/ai/data/drivers.json"


## [{name, traits: {skill, consistency, ...}}]
static func load_all() -> Array:
	var d = JsonData.load_json(PATH)
	return d.get("drivers", []) if d is Dictionary else []
