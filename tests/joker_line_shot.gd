extends Node
## Screenshots of the rallycross joker driving line from above (needs a GPU
## or xvfb + mesa vulkan):
##   godot --path . res://tests/joker_line_shot.tscn -- <out_dir> <track> [zoom px/m] [car id]
## Saves <out_dir>/<track>_approach.png (car before the joker, joker still
## owed: the joker branch shows beside the lap's line) and
## <track>_on_joker.png (car on the joker lane: the joker line only).
## LINE_MODE env var: 2 full (default), 1 corners only, 0 off.

func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var out: String = a[0] if a.size() > 0 else "user://joker_lines"
	var id: String = a[1] if a.size() > 1 else "holjes"
	var zoom: float = float(a[2]) if a.size() > 2 else 2.2
	var car_id: String = a[3] if a.size() > 3 else "skoda_fabia_rx"
	var mode := DrivingLineView.LINE_FULL if OS.get_environment("LINE_MODE") == "" else int(OS.get_environment("LINE_MODE"))
	DirAccess.make_dir_recursive_absolute(out)
	var t := TrackCatalog.load_track(id)
	var def: CarDefinition = CarCatalog.load_all().get(car_id)
	var tc: TyreCompound = TyreCatalog.load_all().get(def.tyre_compound_id)
	var line := DrivingLine.build(t, def, tc)
	var jline := DrivingLine.build_joker(t, def, tc)
	var w := WorldView.new()
	add_child(w)
	w.setup(t, null)
	w.add_driving_aids(line, mode, true)
	w.add_joker_line(jline, mode, true)
	var entry := t.joker_position_at(0.0)
	var mid := t.joker_position_at(t.joker_length * 0.5)
	var shots := {
		# 70 m before the joker turns off, at the lap's reference speed.
		"approach": {"pos": t.position_at(t.joker_entry_s - 70.0), "centre": entry.lerp(mid, 0.5), "branch": true},
		# A third of the way along the joker lane.
		"on_joker": {"pos": t.joker_position_at(t.joker_length * 0.2), "centre": mid, "branch": false},
	}
	for name in shots:
		var sh: Dictionary = shots[name]
		w.joker_line.set_branch_only(sh["branch"])
		w.driving_line.visible = sh["branch"]
		# A sensible speed for where the car is (the joker's own on the joker).
		var ref: DrivingLine = line if sh["branch"] else jline
		var k := ref.locate(sh["pos"])
		var v := ref.lap_speed[k] * 0.9
		w.update_driving_line(sh["pos"], v)
		for i in 8:
			w.set_camera(sh["centre"], zoom)
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [out, id, name])
		print("saved ", id, " ", name)
	get_tree().quit()
