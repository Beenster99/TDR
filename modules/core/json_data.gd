class_name JsonData
extends RefCounted
## Reads JSON files. Static so the headless server and tests can use it
## without autoloads. Each content module keeps its JSON in its own data/
## folder and reads it through this (cars, tracks, physics tyres, ai drivers).
## NOTE: exports must include "modules/*.json" in the export filter, since
## JSON files aren't Godot resources.


static func load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("JsonData: cannot open %s" % path)
		return null
	var data = JSON.parse_string(f.get_as_text())
	if data == null:
		push_error("JsonData: invalid JSON in %s" % path)
	return data


## Sorted paths of the .json files in a folder (sorted so every machine loads
## content in the same order).
static func files_in(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".json"):
			out.append(dir + "/" + f)
	out.sort()
	return out


## Every Dictionary in a folder's .json files, in file order.
static func dicts_in(dir: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in files_in(dir):
		var d = load_json(p)
		if d is Dictionary:
			out.append(d)
	return out
