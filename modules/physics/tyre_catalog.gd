class_name TyreCatalog
extends RefCounted
## Tyre compounds, read from modules/physics/data/*.json. Tyres live in the
## physics module because a compound is mostly its grip/temperature model.

const DIR := "res://modules/physics/data"


## compound id -> TyreCompound
static func load_all() -> Dictionary:
	var tyres := {}
	for d in JsonData.dicts_in(DIR):
		var t := TyreCompound.from_dict(d)
		tyres[t.id] = t
	return tyres
