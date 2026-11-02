class_name CarCatalog
extends RefCounted
## The cars in the game, read from modules/cars/data/*.json. Adding a car is
## adding a JSON file there; no code changes.

const DIR := "res://modules/cars/data"
## Cars that never race (kept out of every list): the safety car.
const SPECIAL_DIR := "res://modules/cars/special"
const SAFETY_CAR_ID := "safety_car_amg_gt_black_series"


## car id -> CarDefinition
static func load_all() -> Dictionary:
	var cars := {}
	for d in JsonData.dicts_in(DIR):
		var c := CarDefinition.from_dict(d)
		cars[c.id] = c
	return cars


## The safety car (Mercedes-AMG GT Black Series), for the graphics to build
## its model from real dimensions. Not in load_all(), so nobody can race it.
static func load_safety_car() -> CarDefinition:
	var d = JsonData.load_json("%s/%s.json" % [SPECIAL_DIR, SAFETY_CAR_ID])
	return CarDefinition.from_dict(d) if d is Dictionary else null


## The car classes present (e.g. ["GT3", "Road"]), fastest class first
## (by the best power-to-weight in each class). Only the classes of one
## discipline: "circuit" (default) leaves the Demolition Derby cars out,
## "derby" lists only them.
static func classes(cars: Dictionary, discipline := "circuit") -> Array[String]:
	var best := {}
	for id in cars:
		var c: CarDefinition = cars[id]
		if c.discipline != discipline:
			continue
		var ptw := c.peak_power_kw() / c.mass + c.cla * 0.05
		best[c.class_tag] = maxf(best.get(c.class_tag, 0.0), ptw)
	var out: Array[String] = []
	for k in best:
		out.append(k)
	out.sort_custom(func(a, b): return best[a] > best[b])
	return out


## Ids of the cars in one class, sorted by name. An empty class means all cars.
static func ids_in_class(cars: Dictionary, car_class: String) -> Array[String]:
	var out: Array[String] = []
	for id in cars:
		if car_class == "" or cars[id].class_tag == car_class:
			out.append(id)
	out.sort_custom(func(a, b): return cars[a].display_name < cars[b].display_name)
	return out
