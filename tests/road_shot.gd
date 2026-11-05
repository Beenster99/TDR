extends Node
## Road surface screenshot: camera over a point on the track with one car for
## scale (needs a GPU or xvfb + mesa vulkan):
##   godot --path . res://tests/road_shot.tscn -- <out.png> <track> <s metres> [zoom px/m] [--wet] [--damp] [--bench]   (s < 0: -N = Nth sharpest corner)

func _ready() -> void:
	var args := Array(OS.get_cmdline_user_args())
	var a := args.filter(func(x): return not str(x).begins_with("--"))
	var out: String = a[0] if a.size() > 0 else "user://road.png"
	var track_id: String = a[1] if a.size() > 1 else "silverstone"
	var s: float = float(a[2]) if a.size() > 2 else 0.0
	var zoom: float = float(a[3]) if a.size() > 3 else 12.0
	var t := TrackCatalog.load_track(track_id)
	var env := SimEnvironment.new()
	env.time_of_day_h = 13.0
	if args.has("--wet"):
		env.rain = 0.7
		env.cloud = 0.9
		env.wetness = 0.8
		env.dry_line = 0.3
	elif args.has("--damp"):
		env.cloud = 0.6
		env.wetness = 0.35
		env.dry_line = 0.8
	var w := WorldView.new()
	add_child(w)
	w.setup(t, env)
	if s < 0.0:   # -N = the Nth sharpest corner (apex)
		var best := []
		var n := t.point_count()
		for i in n:
			best.append([absf(t.seg_dir[(i - 5 + n) % n].angle_to(t.seg_dir[(i + 5) % n])), t.cum_s[i]])
		best.sort_custom(func(x, y): return x[0] > y[0])
		var picked := []
		for b in best:
			if picked.all(func(q): return absf(q - b[1]) > 150.0):
				picked.append(b[1])
			if picked.size() >= int(-s):
				break
		s = picked[-1]
		print("corner at s=%.0f" % s)
	var p := t.position_at(s, 0.0)
	var st := CarState.new()
	st.pos = t.position_at(s, 2.5)
	st.heading = t.heading_at(s)
	var q := t.project(st.pos)
	st.track_idx = q["idx"]
	st.surface = t.surface_for(q)
	var defs := CarCatalog.load_all()
	w.add_car(defs["bmw_m4_gt3"], st, "Test", true, 7)
	var rot := -t.heading_at(s) - PI * 0.5 if args.has("--rotate") else 0.0
	for i in 30:
		w.set_camera(p, zoom, rot)
		await get_tree().process_frame
	if args.has("--bench"):   # average frame time over 3 s (road-heavy view)
		var t0 := Time.get_ticks_usec()
		var frames := 0
		while Time.get_ticks_usec() - t0 < 3000000:
			await get_tree().process_frame
			frames += 1
		print("bench %.2f ms/frame over %d frames" % [(Time.get_ticks_usec() - t0) / 1000.0 / frames, frames])
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	get_tree().quit()
