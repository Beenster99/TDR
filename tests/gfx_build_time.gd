extends SceneTree
## Times building the 3D world for a track (no window needed):
##   godot --headless --path . --script res://tests/gfx_build_time.gd -- --track spa
func _init() -> void:
	var tid := "spa"
	var a := OS.get_cmdline_user_args()
	if a.size() >= 2:
		tid = a[1]
	var t := TrackData.from_dict(JSON.parse_string(FileAccess.get_file_as_string("res://modules/tracks/data/%s.json" % tid)))
	var env := SimEnvironment.new()
	env.bind_track(t)
	var t0 := Time.get_ticks_msec()
	var tv := TrackView.new()
	root.add_child(tv)
	tv.setup(t, env)
	var t1 := Time.get_ticks_msec()
	var ts := Trackside.new()
	root.add_child(ts)
	ts.setup(tv)
	var t2 := Time.get_ticks_msec()
	print("[gfx] %s: track %d ms, trackside %d ms" % [tid, t1 - t0, t2 - t1])
	quit()
