class_name TrackCatalog
extends RefCounted
## The circuits in the game, read from modules/tracks/data/*.json (made with
## tools/import_tumftm_track.py). Adding a track is adding a JSON file there.

const DIR := "res://modules/tracks/data"


## Light list for menus: [{id, name, location, length_m}]
static func list_all() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in JsonData.dicts_in(DIR):
		out.append({"id": d.get("id", ""), "name": d.get("name", ""),
			"location": d.get("location", ""), "length_m": d.get("length_m", 0.0)})
	return out


static func load_track(id: String) -> TrackData:
	var d = JsonData.load_json("%s/%s.json" % [DIR, id])
	return TrackData.from_dict(d) if d is Dictionary else null
