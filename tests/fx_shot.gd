extends Node
## Close-up screenshot of one car standing at a point of a track (needs a GPU
## or xvfb + mesa vulkan). Used to check cars stay visible off the road:
##   godot --path . res://tests/fx_shot.tscn -- <out.png> <track> <x> <y> [zoom px/m] [car_id]

func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var out: String = a[0] if a.size() > 0 else "user://fx.png"
	var track_id: String = a[1] if a.size() > 1 else "spa"
	var p := Vector2(float(a[2]), float(a[3])) if a.size() > 3 else Vector2.ZERO
	var zoom: float = float(a[4]) if a.size() > 4 else 12.0
	var car_id: String = a[5] if a.size() > 5 else "bmw_m4_gt3"
	var t := TrackCatalog.load_track(track_id)
	var w := WorldView.new()
	add_child(w)
	w.setup(t, null)
	var q := t.project(p)
	var st := CarState.new()
	st.pos = p
	st.heading = (q["dir"] as Vector2).angle()
	st.track_idx = q["idx"]
	st.surface = t.surface_for(q)
	var defs := CarCatalog.load_all()
	w.add_car(defs[car_id], st, "Test", true, 7)
	print("surface ", TrackData.Surface.keys()[st.surface], " offset %.1f" % q["offset"])
	if OS.get_cmdline_user_args().has("--marks"):   # a test line of rubber beside the car
		for k in 40:
			var m := p + Vector2.from_angle(st.heading) * (k * 0.5 - 10.0) + Vector2.from_angle(st.heading + PI * 0.5) * 3.0
			w.skid_marks.mark(1, Vector3(m.x, w.track_view.surface_height(m), m.y), 1.0, 0.3)
		w.debris.burst(Vector3(p.x, w.track_view.surface_height(p) + 0.5, p.y), Vector3.ZERO, 12, Color.RED)
	for i in 30:
		w.set_camera(p, zoom)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	get_tree().quit()
