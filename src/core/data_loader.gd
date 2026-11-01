class_name DataLoader
extends RefCounted
## Loads JSON game data from res://data. Static so the headless server and
## tests can use it without autoloads. NOTE: exports must include
## "data/*" in the export filter (non-resource files).

const CARS_DIR := "res://data/cars"
const TYRES_DIR := "res://data/tyres"
const TRACKS_DIR := "res://data/tracks"
const DRIVERS_PATH := "res://data/ai/drivers.json"


static func load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("DataLoader: cannot open %s" % path)
		return null
	var data = JSON.parse_string(f.get_as_text())
	if data == null:
		push_error("DataLoader: invalid JSON in %s" % path)
	return data


static func _json_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".json"):
			out.append(dir + "/" + f)
	out.sort()
	return out


static func load_cars() -> Dictionary:
	var cars := {}
	for p in _json_files(CARS_DIR):
		var d = load_json(p)
		if d is Dictionary:
			var c := CarDefinition.from_dict(d)
			cars[c.id] = c
	return cars


static func load_tyres() -> Dictionary:
	var tyres := {}
	for p in _json_files(TYRES_DIR):
		var d = load_json(p)
		if d is Dictionary:
			var t := TyreCompound.from_dict(d)
			tyres[t.id] = t
	return tyres


static func list_tracks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in _json_files(TRACKS_DIR):
		var d = load_json(p)
		if d is Dictionary:
			out.append({"id": d.get("id", ""), "name": d.get("name", ""),
				"location": d.get("location", ""), "length_m": d.get("length_m", 0.0)})
	return out


static func load_track(id: String) -> TrackData:
	var d = load_json("%s/%s.json" % [TRACKS_DIR, id])
	return TrackData.from_dict(d) if d is Dictionary else null


static func load_drivers() -> Array:
	var d = load_json(DRIVERS_PATH)
	return d.get("drivers", []) if d is Dictionary else []
