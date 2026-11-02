extends Node
## Screenshot of player highlights: four BMW M4 GT3s on the grid, painted the
## way an online race paints them (WorldView.field_liveries): your car (gold
## outline), another player (blue outline) and two AI cars (no outline).
## Needs a GPU or xvfb + mesa vulkan:
##   godot --path . res://tests/highlight_shot.tscn -- <out.png> [zoom px/m]

func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var out: String = a[0] if a.size() > 0 else "user://highlight.png"
	var zoom: float = float(a[1]) if a.size() > 1 else 18.0
	var t := TrackCatalog.load_track("mugello")
	var w := WorldView.new()
	add_child(w)
	w.setup(t, null)
	var defs := CarCatalog.load_all()
	var def: CarDefinition = defs["bmw_m4_gt3"]
	var ids := ["bmw_m4_gt3", "bmw_m4_gt3", "bmw_m4_gt3", "bmw_m4_gt3"]
	var liv := WorldView.field_liveries(ids, [{}, {}, {}, {}], [false, true, true, false])
	var kinds := [CarView.Highlight.NONE, CarView.Highlight.SELF, CarView.Highlight.PLAYER, CarView.Highlight.NONE]
	var names := ["AI", "You", "Friend", "AI"]
	var q0 := t.project(t.points[3])
	var dir: Vector2 = q0["dir"]
	var side := dir.orthogonal()
	var centre: Vector2 = t.points[3]
	var views := []
	for k in 4:
		var st := CarState.new()
		st.pos = centre + dir * (float(k / 2) * -8.0 + 4.0) + side * (2.6 if k % 2 == 0 else -2.6)
		st.heading = dir.angle()
		var q := t.project(st.pos)
		st.track_idx = q["idx"]
		st.surface = t.surface_for(q)
		var v := w.add_car(def, st, names[k], k == 1, k + 1, liv[k])
		v.set_highlight(kinds[k])
		views.append(v)
	for i in 30:
		w.set_camera(centre, zoom)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	get_tree().quit()
