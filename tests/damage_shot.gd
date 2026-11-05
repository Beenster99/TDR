extends Node
## Close-up of crumpled bodywork (needs a GPU or xvfb + mesa vulkan): a row of
## the same car, each hit in a different place, from new to wrecked.
##   godot --path . res://tests/damage_shot.tscn -- <out.png> [car_id] [track] [zoom px/m] [tilt deg]
## Left to right: new, nose crushed (hit on the left of the nose), tail
## crushed, left doors caved in, right doors caved in, everything (a wreck).

const CASES := [
	# [front, rear, left, right], hit points (body frame, m from the centre: +x nose, +y right)
	[[0.0, 0.0, 0.0, 0.0], []],
	[[0.9, 0.0, 0.0, 0.0], [Vector2(2.4, -0.5)]],
	[[0.0, 0.9, 0.0, 0.0], [Vector2(-2.4, 0.3)]],
	[[0.0, 0.0, 0.9, 0.0], [Vector2(0.2, -1.0)]],
	[[0.0, 0.0, 0.0, 0.9], [Vector2(-0.4, 1.0)]],
	[[1.0, 0.8, 0.9, 0.7], [Vector2(2.4, 0.4), Vector2(-2.4, -0.3), Vector2(0.6, -1.0), Vector2(-0.8, 1.0)]],
]


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var out: String = a[0] if a.size() > 0 else "user://damage.png"
	var car_id: String = a[1] if a.size() > 1 else "derby_brannock_sovereign"
	var track_id: String = a[2] if a.size() > 2 else "derby_rustbelt_eight"
	var zoom: float = float(a[3]) if a.size() > 3 else 62.0
	GfxSettings.tilt_deg = float(a[4]) if a.size() > 4 else 26.0
	var t := TrackCatalog.load_track(track_id)
	var w := WorldView.new()
	add_child(w)
	w.setup(t, null)
	var defs := CarCatalog.load_all()
	var def: CarDefinition = defs[car_id]
	var s0 := 40.0
	var fwd := Vector2.from_angle(t.heading_at(s0))
	var right := fwd.orthogonal()
	var centre := t.position_at(s0)
	var n := CASES.size()
	var views: Array = []
	for i in n:
		var st := CarState.new()
		# Side by side, noses pointing up the screen, a little apart.
		st.pos = centre - right * ((i - (n - 1) * 0.5) * (def.width + 1.1))
		st.heading = fwd.angle()
		st.track_idx = t.index_at(s0)
		var c: Array = CASES[i][0]
		st.body_damage = PackedFloat64Array(c)
		var v := w.add_car(def, st, "Car %d" % i, false, 10 + i)
		views.append([v, st, CASES[i][1]])
	for f in 3:
		await get_tree().process_frame
	for e in views:
		for p: Vector2 in e[2]:
			var st: CarState = e[1]
			(e[0] as CarView).note_hit(st.pos + p.rotated(st.heading))
	for i in 30:
		w.set_camera(centre, zoom, fwd.angle() + PI * 0.5)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	get_tree().quit()
