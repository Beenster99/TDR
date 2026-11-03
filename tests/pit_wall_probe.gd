extends SceneTree
## Per circuit: the pit wall's length and how close it comes to the track's
## edge and to the pit lane (both must stay positive), and whether a car
## driven at it from the track side is stopped.
func _init() -> void:
	var dir := DirAccess.open("res://modules/tracks/data")
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var t := TrackCatalog.load_track(f.get_basename())
		if t == null or not t.has_pit_lane():
			continue
		var to_track := 1e9
		var to_lane := 1e9
		var hint := -1
		for p in t.pit_wall:
			var q := t.project(p, hint)
			hint = q["idx"]
			var edge: float = q["w_right"] if t.pit_side > 0 else q["w_left"]
			to_track = minf(to_track, float(q["offset"]) * t.pit_side - edge - TrackData.PIT_WALL_HALF)
			to_lane = minf(to_lane, t.project_pit(p)["dist"] - t.pit_width * 0.5 - TrackData.PIT_WALL_HALF)
		var n := t.pit_wall.size()
		var zone_a := t.pit_limit_start
		print("%-16s wall %5.0f m  clear of track %5.2f  clear of lane %5.2f  limits %.0f..%.0f" % [f.get_basename(), (n - 1) * TrackData.PIT_WALL_STEP, to_track, to_lane, zone_a, t.pit_limit_end])
	quit()
