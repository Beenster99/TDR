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
## (by the best power-to-weight in each class). Only the classes built for
## one kind of racing: "circuit" (default), "rallycross" or "derby".
static func classes(cars: Dictionary, discipline: String = "circuit") -> Array[String]:
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


## Each class's colour, as on a WEC / Le Mans timing screen and the number
## panels and lights on the cars: Hypercar red, LMP2 blue, GT3 green, road
## cars yellow. Other classes get a steady colour from their name.
const CLASS_COLOURS := {
	"Hypercar": Color(0.93, 0.16, 0.2),
	"LMP2": Color(0.18, 0.5, 1.0),
	"GT3": Color(0.16, 0.78, 0.33),
	"Road": Color(1.0, 0.78, 0.1),
	"RX1": Color(0.95, 0.45, 0.1),
	"Derby": Color(0.65, 0.5, 0.35),
}
## Short class names for tight spaces (timing tower, chips).
const CLASS_SHORT := {"Hypercar": "HYP", "LMP2": "LMP2", "GT3": "GT3", "Road": "ROAD", "RX1": "RX1", "Derby": "DRBY"}


static func class_colour(cls: String) -> Color:
	if CLASS_COLOURS.has(cls):
		return CLASS_COLOURS[cls]
	return Color.from_hsv(float(hash(cls) % 360) / 360.0, 0.7, 0.95)


static func class_short(cls: String) -> String:
	return CLASS_SHORT.get(cls, cls.left(4).to_upper())


## Text on a class colour: dark on the light ones (GT3 green, road yellow),
## white on the dark ones.
static func class_text_colour(cls: String) -> Color:
	var c := class_colour(cls)
	return Color(0.05, 0.05, 0.08) if c.get_luminance() > 0.5 else Color.WHITE


## Every class of every kind of racing (circuit classes first).
static func all_classes(cars: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var kinds := ["circuit", "rallycross", "derby"]
	for id in cars:
		var k: String = cars[id].discipline
		if not k in kinds:
			kinds.append(k)
	for k in kinds:
		out.append_array(classes(cars, k))
	return out


## Ids of the cars in one class, sorted by name. An empty class means all cars.
static func ids_in_class(cars: Dictionary, car_class: String) -> Array[String]:
	var out: Array[String] = []
	for id in cars:
		if car_class == "" or cars[id].class_tag == car_class:
			out.append(id)
	out.sort_custom(func(a, b): return cars[a].display_name < cars[b].display_name)
	return out
