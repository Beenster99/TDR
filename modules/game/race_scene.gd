extends Node2D
## Race scene: owns the views, feeds local input into the RaceSession each
## physics tick, and shows results. Works for offline, host, client and
## headless dedicated server alike.

var session: RaceSession
var local_input := LocalInput.new()
var autodrive: AIDriver = null
var world: WorldView
var car_views: Array[CarView] = []
var camera: Camera2D
var hud: RaceHud
var race_audio: RaceAudio
var pit_wall: StrategistScreen
var results: PanelContainer
var rotate_camera := false
var _results_shown := false


func _ready() -> void:
	session = GameData.active_session
	if session == null:
		session = _default_offline_session()
	GameData.active_session = session
	if session.local_car >= 0:
		var me: CarState = session.sim.cars[session.local_car]
		var help: int = GameData.prefs.get("driving_help", 2)
		me.assist_stability = help >= 2
		me.assist_tc = help >= 1
		me.assist_abs = help >= 1
	session.events_emitted.connect(_on_events)
	session.race_finished.connect(_on_race_finished)
	Net.returned_to_lobby.connect(_on_returned_to_lobby)
	Net.disconnected.connect(_on_disconnected)

	world = WorldView.new()
	world.name = "World"
	add_child(world)
	world.setup(session.sim.track, session.sim.env)
	var seen := {}
	for i in session.sim.car_count():
		var def: CarDefinition = session.sim.defs[i]
		# Same model more than once: give the others their own colours.
		var k: int = seen.get(def.id, 0)
		seen[def.id] = k + 1
		var livery := {} if i == session.local_car else WorldView.livery_variant(k)
		car_views.append(world.add_car(def, session.sim.cars[i], session.sim.entries[i].driver_name,
			i == session.local_car, i + 1, livery))
	race_audio = RaceAudio.new()
	add_child(race_audio)
	race_audio.setup(session.sim.cars, session.sim.defs, session.local_car)
	camera = Camera2D.new()
	_zoom_setup()
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
		var env := session.sim.env
		print("[race] %s, %d cars, %d laps, local car %d, %s %02d:00, air %d C, track %d C" % [RaceSession.Mode.keys()[session.mode],
			session.sim.car_count(), session.sim.settings.laps, session.local_car, env.weather,
			int(env.time_of_day_h), roundi(env.ambient_c), roundi(env.track_c)])


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
			_autodrive_throttle = inp.throttle
		else:
			inp = local_input.read(delta, session.sim.cars[session.local_car].speed())
	session.tick(inp)
	# Testing: --force-sc 30 sends the safety car out after 30 s (--force-vsc too).
	for opt in ["force-sc", "force-vsc"]:
		if GameData.arg(opt) and not has_meta(opt) and session.is_authority() \
				and session.sim.race_time >= float(GameData.arg(opt)):
			set_meta(opt, true)
			if opt == "force-sc":
				session.sim.race_control.deploy_safety_car("Test")
			else:
				session.sim.race_control.deploy_vsc("Test")


## Camera zoom: GameData.prefs["zoom"] runs from 0 (close up) to 1 (the
## whole track and every car on screen), freely in between. Hold a key,
## a bumper or the right stick to zoom; the wheel steps. The further out you
## zoom, the more of the lap ahead the camera shows, and right at the end it
## settles on the middle of the track.
const ZOOM_CLOSE := 26.0         ## pixels per metre fully zoomed in (close enough to see the car's details)
const ZOOM_RATE := 0.45          ## share of the range per second while held
const ZOOM_WHEEL_STEP := 0.04
const LOOK_AHEAD := 0.32         ## how far ahead to aim, as a share of the screen
var _zoom_target := 0.2
var _zoom_before_full := 0.2
var _autodrive_throttle := 0.0
var _zoom := 0.2
var _track_rect := Rect2()


func _zoom_setup() -> void:
	var lo := Vector2(INF, INF)
	var hi := -lo
	var t := session.sim.track
	for i in t.point_count():
		var w := maxf(t.width_left[i], t.width_right[i]) + t.runoff
		lo = lo.min(t.points[i] - Vector2(w, w))
		hi = hi.max(t.points[i] + Vector2(w, w))
	_track_rect = Rect2(lo, hi - lo)
	_zoom_target = clampf(float(GameData.arg("zoom", GameData.prefs.get("zoom", 0.2))), 0.0, 1.0)
	_zoom = _zoom_target


## Pixels per metre that fit the whole track in the window (any resolution).
func _fit_zoom() -> float:
	var vs := get_viewport_rect().size
	return minf(vs.x / _track_rect.size.x, vs.y / _track_rect.size.y) * 0.94


func _set_zoom(z: float) -> void:
	_zoom_target = clampf(z, 0.0, 1.0)
	GameData.prefs["zoom"] = _zoom_target


func _process(delta: float) -> void:
	var focus := session.local_car
	if focus < 0:
		focus = session.sim.running_order[0]
	var car: CarState = session.sim.cars[focus]
	var target := car_views[focus].pos2
	var heading := car_views[focus].heading
	var speed := car.speed()
	# Held zoom: keys, bumpers and the right stick all ramp smoothly.
	var zin := Input.get_action_strength("zoom_out") - Input.get_action_strength("zoom_in")
	if absf(zin) > 0.0:
		_set_zoom(_zoom_target + zin * ZOOM_RATE * delta)
	_zoom = lerpf(_zoom, _zoom_target, 1.0 - exp(-8.0 * delta))
	# Zoom level: log scale from close up to the whole track, so every bit
	# of the stick changes the view by the same feel. A little pull-back with
	# speed only when you're right in close.
	var close := ZOOM_CLOSE * lerpf(1.0, 0.75, clampf(speed / 70.0, 0.0, 1.0) * (1.0 - _zoom))
	var fit := _fit_zoom()
	var z := exp(lerpf(log(close), log(fit), _zoom))
	# Look ahead along the track (not just the nose), further when zoomed out,
	# keeping your car on screen.
	var vs := get_viewport_rect().size
	var reach := LOOK_AHEAD * minf(vs.x, vs.y) / z
	var ahead := session.sim.track.position_at(car.track_s + reach * 1.6)
	var offset := ahead - target
	if offset.length() > reach:
		offset = offset.normalized() * reach
	if speed < 3.0:
		offset *= speed / 3.0
	var follow := target + offset
	var centre_mix := smoothstep(0.85, 1.0, _zoom)
	camera.position = follow.lerp(_track_rect.get_center(), centre_mix)
	camera.position_smoothing_enabled = centre_mix < 0.01
	camera.zoom = Vector2(z, z)
	for i in car_views.size():
		car_views[i].visible = not session.sim.race_control.recovered[i]
	race_audio.update(delta, camera.position, local_input.last_throttle if autodrive == null else _autodrive_throttle, _zoom)
	var rot := rotate_camera and _zoom < 0.5
	camera.ignore_rotation = not rot
	if rot:
		camera.rotation = heading + PI * 0.5
	world.set_camera(camera.get_screen_center_position(), z, camera.rotation if rot else 0.0)
	_maybe_screenshot()


## Z / R3: jump to the whole track, and back to where you were.
func _toggle_full_track() -> void:
	if _zoom_target > 0.97:
		_set_zoom(_zoom_before_full)
	else:
		_zoom_before_full = _zoom_target
		_set_zoom(1.0)


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
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_zoom(_zoom_target - ZOOM_WHEEL_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(_zoom_target + ZOOM_WHEEL_STEP)
	elif event.is_action_pressed("zoom_full"):
		_toggle_full_track()
	elif event.is_action_pressed("camera_toggle"):
		rotate_camera = not rotate_camera
	elif event.is_action_pressed("restart_race") and session.mode == RaceSession.Mode.OFFLINE:
		_restart()
	elif event.is_action_pressed("back_to_menu") and not _results_shown and not pit_wall.visible:
		_back_to_menu()


func _on_events(evs: Array) -> void:
	race_audio.on_events(evs)
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
			"safety_car":
				var says := {"sc": "SAFETY CAR DEPLOYED", "vsc": "VIRTUAL SAFETY CAR", "vsc_ending": "VSC ENDING",
					"lapped_may_overtake": "LAPPED CARS MAY OVERTAKE", "in_this_lap": "SAFETY CAR IN THIS LAP",
					"restart": "SAFETY CAR IN - RESTART", "green": "GREEN FLAG"}
				if says.has(e.get("state", "")):
					hud.flash(says[e["state"]], 2.5)
			"penalty":
				if e["car"] == session.local_car:
					hud.flash("+%d s penalty: %s" % [int(e["seconds"]), e["reason"]], 4.0)


func _on_race_finished() -> void:
	var sim := session.sim
	_save_race_data()
	var lines := []
	for p in sim.running_order.size():
		var i := sim.running_order[p]
		var e := sim.entries[i]
		lines.append("P%-2d %-18s %-16s %s  best %s%s" % [p + 1, e.driver_name, sim.defs[i].display_name,
			"DNF" if e.dnf else RaceHud.fmt_time(e.finish_time + e.penalty_s), RaceHud.fmt_time(e.best_lap),
			"  (+%d s penalty)" % int(e.penalty_s) if e.penalty_s > 0.0 else ""])
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
	Sound.wire_buttons(results)
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
