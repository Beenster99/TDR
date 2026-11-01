extends Node2D
## Race scene: owns the views, feeds local input into the RaceSession each
## physics tick, and shows results. Works for offline, host, client and
## headless dedicated server alike.

var session: RaceSession
var local_input := LocalInput.new()
var autodrive: AIDriver = null
var track_view: TrackView
var car_views: Array[CarView] = []
var camera: Camera2D
var hud: RaceHud
var pit_wall: StrategistScreen
var results: PanelContainer
var rotate_camera := false
var _results_shown := false


func _ready() -> void:
	session = GameData.active_session
	if session == null:
		session = _default_offline_session()
	GameData.active_session = session
	session.events_emitted.connect(_on_events)
	session.race_finished.connect(_on_race_finished)
	Net.returned_to_lobby.connect(_on_returned_to_lobby)
	Net.disconnected.connect(_on_disconnected)

	track_view = TrackView.new()
	add_child(track_view)
	track_view.setup(session.sim.track)
	for i in session.sim.car_count():
		var v := CarView.new()
		v.setup(session.sim.defs[i], session.sim.cars[i], session.sim.entries[i].driver_name, i == session.local_car)
		add_child(v)
		car_views.append(v)
	camera = Camera2D.new()
	camera.zoom = Vector2(7, 7)
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 8.0
	add_child(camera)
	camera.make_current()
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = RaceHud.new()
	layer.add_child(hud)
	hud.setup(session)
	pit_wall = StrategistScreen.new()
	layer.add_child(pit_wall)
	pit_wall.setup(session)
	if GameData.arg("pit-wall"):
		pit_wall.open()
	results = _build_results()
	layer.add_child(results)
	if GameData.arg("autodrive") and session.local_car >= 0:
		autodrive = AIDriver.for_car(session.sim, session.local_car)
	if DisplayServer.get_name() == "headless":
		print("[race] %s, %d cars, %d laps, local car %d" % [RaceSession.Mode.keys()[session.mode],
			session.sim.car_count(), session.sim.settings.laps, session.local_car])


func _on_returned_to_lobby() -> void:
	get_tree().change_scene_to_file(GameData.SCENE_MENU)


func _on_disconnected(_reason: String) -> void:
	_back_to_menu()


func _default_offline_session() -> RaceSession:
	var s := RaceSettings.new()
	s.seed = randi()
	var ids: Array = GameData.cars.keys()
	ids.sort()
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": ids[0]}], GameData.cars, GameData.drivers)
	return RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)


func _physics_process(delta: float) -> void:
	var inp: CarInput = null
	if session.local_car >= 0:
		if autodrive:
			inp = autodrive.get_input(session.sim, session.local_car)
		else:
			inp = local_input.read(delta, session.sim.cars[session.local_car].speed())
	session.tick(inp)


func _process(delta: float) -> void:
	var target: Vector2
	var heading := 0.0
	var speed := 0.0
	if session.local_car >= 0:
		var v := car_views[session.local_car]
		target = v.position
		heading = v.rotation
		speed = session.sim.cars[session.local_car].speed()
	else:
		var lead := session.sim.running_order[0]
		target = car_views[lead].position
		speed = session.sim.cars[lead].speed()
	# Look ahead in the direction of travel and zoom out with speed.
	camera.position = target + Vector2.from_angle(heading) * speed * 0.35
	var z := lerpf(9.0, 5.0, clampf(speed / 70.0, 0.0, 1.0))
	camera.zoom = camera.zoom.lerp(Vector2(z, z), 1.0 - exp(-2.0 * delta))
	camera.ignore_rotation = not rotate_camera
	if rotate_camera:
		camera.rotation = heading + PI * 0.5
	_maybe_screenshot()


var _shot_taken := false


## --screenshot out.png --screenshot-at 20 : save a frame after N race seconds, then quit.
func _maybe_screenshot() -> void:
	if _shot_taken or not GameData.arg("screenshot"):
		return
	if session.sim.race_time + session.sim.phase_time * float(session.sim.phase == RaceSim.Phase.COUNTDOWN) >= float(GameData.arg("screenshot-at", 10)):
		_shot_taken = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(str(GameData.arg("screenshot")))
		print("[screenshot] saved")
		get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("strategy_screen") and not _results_shown:
		pit_wall.toggle()
	elif event.is_action_pressed("camera_toggle"):
		rotate_camera = not rotate_camera
	elif event.is_action_pressed("restart_race") and session.mode == RaceSession.Mode.OFFLINE:
		_restart()
	elif event.is_action_pressed("back_to_menu") and not _results_shown and not pit_wall.visible:
		_back_to_menu()


func _on_events(evs: Array) -> void:
	for e in evs:
		match e["type"]:
			"countdown": pass
			"green": hud.flash("GO!", 1.5)
			"lap":
				if e["car"] == session.local_car:
					hud.flash("Lap %d  %s" % [e["lap"], RaceHud.fmt_time(e["time"])], 2.5)
			"chequered": hud.flash("Chequered flag! %s wins" % session.sim.entries[e["car"]].driver_name, 3.0)
			"finished":
				if e["car"] == session.local_car:
					hud.flash("Finished P%d" % e["position"], 4.0)


func _on_race_finished() -> void:
	var sim := session.sim
	_save_race_data()
	var lines := []
	for p in sim.running_order.size():
		var i := sim.running_order[p]
		var e := sim.entries[i]
		lines.append("P%-2d %-18s %-16s %s  best %s" % [p + 1, e.driver_name, sim.defs[i].display_name,
			"DNF" if e.dnf else RaceHud.fmt_time(e.finish_time), RaceHud.fmt_time(e.best_lap)])
	if DisplayServer.get_name() == "headless" or GameData.arg("quit-after-race"):
		print("[results]\n" + "\n".join(lines))
		var heard := []
		for i in session.timelines:
			heard.append("%s=%d" % [sim.entries[i].driver_name, session.timelines[i].received])
		if not heard.is_empty():
			print("[net] car states received: " + ", ".join(heard))
	if GameData.arg("quit-after-race"):
		get_tree().create_timer(2.0).timeout.connect(func(): get_tree().quit())
		return
	if session.mode == RaceSession.Mode.SERVER and Net.dedicated:
		get_tree().create_timer(10.0).timeout.connect(func(): Net.end_race())
		return
	_show_results(lines)


## Every race's data (lap log, sectors, gaps, feed, weather) is kept as JSON
## in user://race_data/, for the strategist tools to come.
func _save_race_data() -> void:
	DirAccess.make_dir_recursive_absolute("user://race_data")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "user://race_data/%s_%s.json" % [stamp, session.sim.track.id]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(session.telemetry.to_dict(session.sim), "\t"))
		f.close()
		if DisplayServer.get_name() == "headless":
			var gaps := []
			for c in session.telemetry.cars:
				gaps.append("%.1f" % c.gap_leader)
			print("[race data] saved %s (%d feed items, gaps %s)" % [ProjectSettings.globalize_path(path),
				session.telemetry.feed.items.size(), ", ".join(gaps)])


func _build_results() -> PanelContainer:
	var p := PanelContainer.new()
	p.visible = false
	p.set_anchors_preset(Control.PRESET_CENTER)
	return p


func _show_results(lines: Array) -> void:
	_results_shown = true
	for c in results.get_children():
		c.queue_free()
	var v := VBoxContainer.new()
	results.add_child(v)
	var t := Label.new()
	t.text = "RESULTS"
	t.add_theme_font_size_override("font_size", 30)
	v.add_child(t)
	var body := Label.new()
	body.text = "\n".join(lines)
	body.add_theme_font_override("font", SystemFont.new())
	v.add_child(body)
	var first: Button = null
	if session.mode == RaceSession.Mode.OFFLINE:
		first = _results_button(v, "Race again", _restart)
		_results_button(v, "Main menu", _back_to_menu)
	elif session.mode == RaceSession.Mode.SERVER:
		first = _results_button(v, "Back to lobby", func(): Net.end_race())
	else:
		var w := Label.new()
		w.text = "Waiting for the host..."
		v.add_child(w)
		first = _results_button(v, "Leave", _back_to_menu)
	results.visible = true
	results.reset_size()
	results.position = (get_viewport_rect().size - results.size) * 0.5
	if first:
		first.grab_focus.call_deferred()


func _results_button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(300, 42)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _restart() -> void:
	var start := session.start_data.duplicate(true)
	start["settings"]["seed"] = randi()
	GameData.active_session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	get_tree().reload_current_scene()


func _back_to_menu() -> void:
	if Net.is_online():
		Net.leave()
	GameData.active_session = null
	get_tree().change_scene_to_file(GameData.SCENE_MENU)
