extends Node
## Screenshots of where a rallycross lap changes between tarmac and dirt
## (needs a GPU or xvfb + mesa vulkan). One shot per change of surface:
##   godot --path . res://tests/dirt_blend_shot.tscn -- <out_prefix> <track> [zoom] [max_shots]
## zoom is pixels per metre (default 7). Saves <out_prefix>_<n>.png.

func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var prefix: String = a[0] if a.size() > 0 else "user://dirt"
	var track_id: String = a[1] if a.size() > 1 else "holjes"
	var zoom := float(a[2]) if a.size() > 2 else 7.0
	var most := int(a[3]) if a.size() > 3 else 99
	var t := TrackCatalog.load_track(track_id)
	var w := WorldView.new()
	add_child(w)
	w.setup(t, null)
	var ends: Array = []
	for r in t.dirt:
		ends.append(r[0])
		ends.append(r[1])
	var n := 0
	for s in ends:
		if n >= most:
			break
		var p := t.position_at(fposmod(float(s), t.length))
		for i in 20:
			w.set_camera(p, zoom)
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var out := "%s_%d.png" % [prefix, n]
		get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out, " s=", s)
		n += 1
	get_tree().quit()
