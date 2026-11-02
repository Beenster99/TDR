class_name SeasonStore
extends RefCounted
## Saved seasons, so a championship carries on across sessions (and the same
## group of friends can pick an online season up again). One JSON file per
## season in user://seasons/, plus a folder per season holding each
## session's full race log from the race data module:
##   user://seasons/<id>.json
##   user://seasons/<id>/r03_qualifying.json, r03_race.json

const DIR := "user://seasons"


static func path_for(id: String) -> String:
	return "%s/%s.json" % [DIR, id]


static func save(season: Season, dir := DIR) -> bool:
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open("%s/%s.json" % [dir, season.id], FileAccess.WRITE)
	if f == null:
		push_error("SeasonStore: cannot write %s" % season.id)
		return false
	f.store_string(JSON.stringify(season.to_dict(), "\t"))
	f.close()
	return true


static func load_season(id: String, dir := DIR) -> Season:
	var d = JsonData.load_json("%s/%s.json" % [dir, id])
	return Season.from_dict(d) if d is Dictionary else null


## Every saved season, newest round played first:
## [{id, name, number, round, rounds, complete, modified}]
static func list(dir := DIR) -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".json"):
			continue
		var path := "%s/%s" % [dir, f]
		var d = JsonData.load_json(path)
		if not d is Dictionary or not d.has("rounds"):
			continue
		out.append({"id": d.get("id", f.get_basename()), "name": d.get("name", "Season"),
			"number": int(d.get("number", 1)), "round": int(d.get("round_index", 0)),
			"rounds": d.get("rounds", []).size(), "complete": int(d.get("round_index", 0)) >= d.get("rounds", []).size(),
			"humans": d.get("humans", {}).keys(), "modified": FileAccess.get_modified_time(path)})
	out.sort_custom(func(a, b): return a["modified"] > b["modified"])
	return out


static func delete(id: String, dir := DIR) -> void:
	DirAccess.remove_absolute("%s/%s.json" % [dir, id])
	var sub := "%s/%s" % [dir, id]
	if DirAccess.dir_exists_absolute(sub):
		for f in DirAccess.get_files_at(sub):
			DirAccess.remove_absolute("%s/%s" % [sub, f])
		DirAccess.remove_absolute(sub)


## Keeps a session's full race log (RaceTelemetry.to_dict) beside the season.
static func save_session_log(season_id: String, round_index: int, session: String, log: Dictionary, dir := DIR) -> String:
	var sub := "%s/%s" % [dir, season_id]
	DirAccess.make_dir_recursive_absolute(sub)
	var path := "%s/r%02d_%s.json" % [sub, round_index + 1, session]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(log, "\t"))
	f.close()
	return path
