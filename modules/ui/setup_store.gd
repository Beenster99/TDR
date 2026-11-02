class_name SetupStore
extends RefCounted
## Saved car setups, one per car per track, in user://setups/<car>/<track>.json.
## A missing file means the car's default setup.

const DIR := "user://setups"


static func path(car_id: String, track_id: String) -> String:
	return "%s/%s/%s.json" % [DIR, car_id, track_id]


static func has(car_id: String, track_id: String) -> bool:
	return FileAccess.file_exists(path(car_id, track_id))


## The saved setup values (CarSetup keys), or {} for the default setup.
static func load_setup(car_id: String, track_id: String) -> Dictionary:
	var p := path(car_id, track_id)
	if not FileAccess.file_exists(p):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(p))
	if d is Dictionary and d.get("setup") is Dictionary:
		return d["setup"]
	return {}


static func save_setup(car_id: String, track_id: String, setup: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute("%s/%s" % [DIR, car_id])
	var f := FileAccess.open(path(car_id, track_id), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"format": 1, "car": car_id, "track": track_id, "setup": setup}, "  "))
	return true


static func erase(car_id: String, track_id: String) -> void:
	if has(car_id, track_id):
		DirAccess.remove_absolute(path(car_id, track_id))


## The setup overrides a race entry takes for this car here ({} = defaults).
static func entry_setup(car_id: String, track_id: String) -> Dictionary:
	var s := load_setup(car_id, track_id)
	return {} if s.is_empty() else {"tuning": s}
