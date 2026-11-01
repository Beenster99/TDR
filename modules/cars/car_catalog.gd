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


## The car classes present (e.g. ["GT3", "Road"]), fastest class first
## (by the best power-to-weight in each class).
static func classes(cars: Dictionary) -> Array[String]:
	var best := {}
	for id in cars:
		var c: CarDefinition = cars[id]
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
