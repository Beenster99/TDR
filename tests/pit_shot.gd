extends Node
## Screenshots of each track's pit entry and pit exit from above, to check how
## the pit lane joins the circuit (needs a GPU or xvfb + mesa vulkan):
##   godot --path . res://tests/pit_shot.tscn -- <out_dir> [track,track,...] [zoom px/m]
## Saves <out_dir>/<track>_entry.png and <track>_exit.png.

func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var out: String = a[0] if a.size() > 0 else "user://pits"
	var ids: Array = str(a[1]).split(",") if a.size() > 1 and str(a[1]) != "all" else TrackCatalog.list_all().map(func(d): return d["id"])
	var zoom: float = float(a[2]) if a.size() > 2 else 5.0
	DirAccess.make_dir_recursive_absolute(out)
	for id in ids:
		var t := TrackCatalog.load_track(id)
		if t == null or not t.has_pit_lane():
			continue
		var w := WorldView.new()
		add_child(w)
		w.setup(t, null)
		for n in OS.get_environment("PIT_SHOT_HIDE").split(",", false):   # debugging: hide meshes by name
			for parent in [w.track_view, w.trackside]:
				for ch in parent.get_children():
					if str(ch.name).begins_with(n):
						ch.visible = false
		if OS.get_environment("PIT_SHOT_PATH") != "":   # debugging: the pit path in red, track centre in blue
			var im := ImmediateMesh.new()
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.vertex_color_use_as_albedo = true
			mat.no_depth_test = true
			im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
			for j in t.pit_path.size() - 1:
				for p in [t.pit_path[j], t.pit_path[j + 1]]:
					im.surface_set_color(Color.RED)
					im.surface_add_vertex(Vector3(p.x, t.surface_height_at(p) + 0.3, p.y))
			for j in t.point_count():
				for p in [t.points[j], t.points[(j + 1) % t.point_count()]]:
					im.surface_set_color(Color.BLUE)
					im.surface_add_vertex(Vector3(p.x, t.surface_height_at(p) + 0.3, p.y))
			im.surface_end()
			var mi := MeshInstance3D.new()
			mi.mesh = im
			w.add_child(mi)
		# frame the first / last ~110 m of the lane: where it leaves and rejoins
		var spots := {"entry": t.pit_position_at(55.0), "exit": t.pit_position_at(t.pit_length - 55.0)}
		for dd in OS.get_environment("PIT_SHOT_D").split(",", false):   # more spots, in pit metres
			spots["d" + dd] = t.pit_position_at(float(dd))
		for k in spots:
			for i in 8:
				w.set_camera(spots[k], zoom)
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [out, id, k])
			print("saved ", id, " ", k)
		w.queue_free()
		await get_tree().process_frame
	get_tree().quit()
