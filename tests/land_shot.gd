extends Node
## Screenshots of a track's ground and scenery from above (needs a GPU or
## xvfb + mesa vulkan), several views in one run:
##   godot --path . res://tests/land_shot.tscn -- <out_prefix> <track> <x,y,zoom> [x,y,zoom ...] [--old]
## zoom is pixels per metre; 0 = the whole track. Saves <out_prefix>_<n>.png.

func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var prefix: String = a[0] if a.size() > 0 else "user://land"
	var track_id: String = a[1] if a.size() > 1 else "silverstone"
	var t := TrackCatalog.load_track(track_id)
	var w := WorldView.new()
	add_child(w)
	w.setup(t, null)
	var views := a.slice(2)
	if views.is_empty():
		views = ["0,0,0"]
	var n := 0
	for v in views:
		var f := str(v).split(",")
		var p := Vector2(float(f[0]), float(f[1]))
		var zoom := float(f[2])
		if zoom <= 0.0:
			p = w.track_view.bounds.get_center()
			zoom = get_viewport().get_visible_rect().size.y / (w.track_view.bounds.size.y / 1.5)
		for i in 20:
			w.set_camera(p, zoom)
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var out := "%s_%d.png" % [prefix, n]
		get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out)
		n += 1
	get_tree().quit()
