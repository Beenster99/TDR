extends Node
## Screenshots of the driving line aid through corners, from above, to check
## the racing line (needs a GPU or xvfb + mesa vulkan):
##   godot --path . res://tests/line_shot.tscn -- <out_dir> <track> [s,s,...] [zoom px/m] [car id]
## Without track distances it frames the slowest corners. Saves
## <out_dir>/<track>_<s>.png and prints the distances it used.

func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var out: String = a[0] if a.size() > 0 else "user://lines"
	var id: String = a[1] if a.size() > 1 else "monza"
	var zoom: float = float(a[3]) if a.size() > 3 else 4.0
	var car_id: String = a[4] if a.size() > 4 else "ferrari_296_gt3"
	DirAccess.make_dir_recursive_absolute(out)
	var t := TrackCatalog.load_track(id)
	var def: CarDefinition = CarCatalog.load_all().get(car_id)
	var line := DrivingLine.build(t, def, TyreCatalog.load_all().get(def.tyre_compound_id))
	var spots: Array = []
	if a.size() > 2 and str(a[2]) != "auto":
		for s in str(a[2]).split(","):
			spots.append(float(s))
	else:
		var zs := line.zones.duplicate()
		zs.sort_custom(func(x, y): return x["apex_v"] < y["apex_v"])
		for z in zs:
			var s := snappedf(line.track_s[z["end"]], 1.0)
			if spots.all(func(o): return absf(o - s) > 200.0 and absf(o - s) < t.length - 200.0):
				spots.append(s)
			if spots.size() >= 3:
				break
	print("spots ", ",".join(spots.map(func(s): return str(int(s)))))
	var w := WorldView.new()
	add_child(w)
	w.setup(t, null)
	w.add_driving_aids(line, DrivingLineView.LINE_FULL if OS.get_environment("LINE_MODE") == "" else int(OS.get_environment("LINE_MODE")), true)
	for s in spots:
		# The car 140 m before the corner at the reference lap speed, so the
		# braking colours show as they would on a good lap.
		var k := line.locate(t.position_at(s - 140.0))
		w.update_driving_line(line.points[k], line.lap_speed[k])
		# Frame the corner a little after its slowest point (exit included).
		var centre := t.position_at(s + 15.0)
		for i in 8:
			w.set_camera(centre, zoom)
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s_%d.png" % [out, id, int(s)])
		print("saved ", id, " ", int(s))
	get_tree().quit()
