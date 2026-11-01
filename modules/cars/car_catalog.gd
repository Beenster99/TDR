class_name CarCatalog
extends RefCounted
## The cars in the game, read from modules/cars/data/*.json. Adding a car is
## adding a JSON file there; no code changes.

const DIR := "res://modules/cars/data"


## car id -> CarDefinition
static func load_all() -> Dictionary:
	var cars := {}
	for d in JsonData.dicts_in(DIR):
		var c := CarDefinition.from_dict(d)
		cars[c.id] = c
	return cars
