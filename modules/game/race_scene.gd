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
## Co-op: the pit crew / strategist console (players in a car's crew who are
## not driving it) and the driver's radio calls to them.
var crew: CrewConsole
## Single player: the quick menu for a pit call (tyres, wings, fuel).
var pit_menu: PitCallMenu
var driver_radio: TeamRadio
## The pit crew mini-game for the car this player leads the crew of.
var crew_game: PitCrewGame
## The strategist's pit stop planner (over the pit wall screens).
var planner: PitPlanner
## Esc / Start: the pause menu (offline the race stops; online it's an overlay).
var pause_menu: PauseMenu
## The driving line aid's data, kept so Settings can turn it on and off mid-race.
var _driving_line: DrivingLine
var results: PanelContainer
var rotate_camera := false
var _results_shown := false
var _forced := {}


func _ready() -> void:
	session = GameData.active_session
	if session == null:
		session = _default_offline_session()
	GameData.active_session = session
	_set_driving_aids()
	session.events_emitted.connect(_on_events)
	session.role_changed.connect(_on_role_changed)
	session.team_radio.connect(_on_team_radio)
	session.race_finished.connect(_on_race_finished)
	Net.returned_to_lobby.connect(_on_returned_to_lobby)
	Net.disconnected.connect(_on_disconnected)

	world = WorldView.new()
	world.name = "World"
	add_child(world)
	world.setup(session.sim.track, session.sim.env)
	_add_driving_aids()
	# Painted from the race's start data only, never from which car is this
	# machine's, so the host and every guest see the same colours.
	var ids := []
	var own := []
	var players := []
	for i in session.sim.car_count():
		ids.append(session.sim.defs[i].id)
		own.append(session.sim.entries[i].livery)
		players.append(not session.sim.entries[i].is_ai)
	var liveries := WorldView.field_liveries(ids, own, players)
	for i in session.sim.car_count():
		car_views.append(world.add_car(session.sim.defs[i], session.sim.cars[i], session.sim.entries[i].driver_name,
			i == session.local_car, i + 1, liveries[i]))
	_refresh_highlights()
	session.crew_changed.connect(func(_car): _refresh_highlights())
	GameData.pref_changed.connect(_on_pref_changed)
	if session.sim.pits.enabled:
		for i in session.sim.car_count():
			world.add_pit_crew(i, session.sim.pits.box_index(i))
		world.fill_pit_lane()
		_add_pit_guide()
	race_audio = RaceAudio.new()
	add_child(race_audio)
	race_audio.setup(session.sim.cars, session.sim.defs, session.local_car)
	race_audio.set_environment(session.sim.env)
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
	crew = CrewConsole.new()
	layer.add_child(crew)
	crew.setup(session)
	crew.open_pit_wall.connect(pit_wall.open)
	if DisplayServer.get_name() != "headless":
		# The strategist's picture-in-picture onboard camera on any car.
		var onboard := OnboardCamera.new()
		onboard.name = "OnboardCamera"
		add_child(onboard)
		onboard.setup(world)
		crew.onboard = onboard
		pit_wall.onboard = onboard
	crew.cover = pit_wall
	crew.car_screen_pos = func(i: int) -> Vector2:
		if not _camera_placed or world.camera == null or world.camera.is_position_behind(car_views[i].global_position):
			return Vector2(-1000, -1000)
		return world.camera.unproject_position(car_views[i].global_position)
	pit_menu = PitCallMenu.new()
	layer.add_child(pit_menu)
	pit_menu.setup(session.sim)
	pit_menu.confirmed.connect(_on_pit_menu_confirmed)
	hud.pit_guide_on = bool(GameData.prefs.get("aid_pit_guide", true))
	driver_radio = TeamRadio.new()
	layer.add_child(driver_radio)
	driver_radio.setup(session, session.local_car, true)
	planner = PitPlanner.new()
	layer.add_child(planner)
	planner.setup(session)
	crew.planner = planner
	pit_wall.planner = planner
	crew.open_planner.connect(_open_planner)
	pit_wall.open_planner.connect(_open_planner)
	if GameData.arg("planner"):
		_open_planner.call_deferred()
	crew_game = PitCrewGame.new()   # after the consoles, so it hears its buttons first
	layer.add_child(crew_game)
	crew_game.setup(session, world.pit_crews)
	crew_game.autoplay = bool(GameData.arg("crew-autoplay", false))
	_add_pause_menu(layer)
	_apply_role()
	if GameData.arg("pit-wall"):
		pit_wall.open()
	results = _build_results()
	layer.add_child(results)
	_make_autodrive()
	# Filming (tools/record_highlights.sh): --no-hud shows just the race,
	# --rotate-camera turns the view with the car.
	if GameData.arg("no-hud"):
		layer.visible = false
	if GameData.arg("rotate-camera"):
		rotate_camera = true
	if DisplayServer.get_name() == "headless":
		var env := session.sim.env
		print("[race] %s, %d cars, %d laps, local car %d, %s %02d:00, air %d C, track %d C" % [RaceSession.Mode.keys()[session.mode],
			session.sim.car_count(), session.sim.settings.laps, session.local_car, env.weather,
			int(env.time_of_day_h), roundi(env.ambient_c), roundi(env.track_c)])


func _set_driving_aids() -> void:
	if session.local_car >= 0:
		var me: CarState = session.sim.cars[session.local_car]
		var help: int = GameData.prefs.get("driving_help", 2)
		me.assist_stability = help >= 2
		me.assist_tc = help >= 1
		me.assist_abs = help >= 1
		# Settings > Gameplay (the settings screen registers these keys).
		me.assist_track = clampi(int(GameData.prefs.get("aid_track_assist", 1)), 0, 2)
		me.manual_gears = bool(GameData.prefs.get("manual_gears", false))
		local_input.manual_gears = me.manual_gears


## The driving line and brake boards, for this player's car (or the team's
## car on the pit wall). Settings > Gameplay sets the line (full, corners
## only, off) and turns its braking colours on and off; the boards are always there.
func _add_driving_aids() -> void:
	var i := session.local_car if session.local_car >= 0 else maxi(session.team_car, 0)
	_driving_line = DrivingLine.build(session.sim.track, session.sim.defs[i], session.sim.compounds[i])
	world.add_driving_aids(_driving_line, int(GameData.prefs.get("aid_driving_line", DrivingLineView.LINE_FULL)),
		bool(GameData.prefs.get("aid_braking_zones", true)))


## Settings changed mid-race (the pause menu's Settings): apply the ones the
## race scene owns.
func _on_pref_changed(key, _v) -> void:
	var k := str(key)
	if k.begins_with("highlight_"):
		_refresh_highlights()
	elif k == "aid_driving_line" or k == "aid_braking_zones":
		# The line view is built once; build a fresh one with the new choice.
		if world.driving_line:
			world.driving_line.queue_free()
		var view := DrivingLineView.new()
		view.name = "DrivingLineAid"
		world.add_child(view)
		view.setup(_driving_line, world.track_view, int(GameData.prefs.get("aid_driving_line", DrivingLineView.LINE_FULL)),
			bool(GameData.prefs.get("aid_braking_zones", true)))
		world.driving_line = view
	elif k == "aid_pit_guide":
		hud.pit_guide_on = bool(GameData.prefs.get("aid_pit_guide", true))


## The pause menu: what it may offer depends on the race (offline, host, guest,
## championship).
func _add_pause_menu(layer: CanvasLayer) -> void:
	var online := session.mode != RaceSession.Mode.OFFLINE
	var host := session.mode == RaceSession.Mode.SERVER
	var blocked := ""
	if session.start_data.has("season"):
		blocked = "not in a championship"   # no do-overs (as the R key)
	elif session.mode == RaceSession.Mode.CLIENT:
		blocked = "only the host can"
	pause_menu = PauseMenu.new()
	layer.add_child(pause_menu)
	pause_menu.setup({"online": online, "host": host, "can_restart": blocked == "", "restart_blocked": blocked,
		"can_edit_hud": session.local_car >= 0})
	pause_menu.resumed.connect(_on_pause_closed)
	pause_menu.restart_requested.connect(func():
		_on_pause_closed()
		if session.mode == RaceSession.Mode.SERVER:
			Net.restart_race()   # everyone gets the new start; see _on_net_race_started
		else:
			_restart())
	pause_menu.end_race_requested.connect(func():
		_on_pause_closed()
		Net.end_race())
	pause_menu.quit_to_menu_requested.connect(func():
		_on_pause_closed()
		_back_to_menu())
	pause_menu.quit_to_desktop_requested.connect(func():
		GameData.save_prefs()
		if Net.is_online():
			Net.leave()
		get_tree().quit())
	pause_menu.edit_hud_requested.connect(func():
		if session.local_car >= 0:
			hud.open_editor())
	# Online: the host restarted the race; every machine starts the new one.
	Net.race_started.connect(_on_net_race_started)


func _open_pause_menu() -> void:
	if session.mode == RaceSession.Mode.OFFLINE:
		get_tree().paused = true   # the race, its sounds and effects stop; the menu runs
	pause_menu.open()


func _on_pause_closed() -> void:
	get_tree().paused = false


func _on_net_race_started(_start_data: Dictionary) -> void:
	print("[net] the host restarted the race")
	get_tree().paused = false
	get_tree().reload_current_scene.call_deferred()


## The pit guide (line into the pits, limit lines, box marks) for this
## player's car, or the team's car they may take over in co-op. Shown while
## they drive in themselves (Settings > Gameplay > Pit stops / Pit lane guide).
func _add_pit_guide() -> void:
	var i := session.local_car if session.local_car >= 0 else session.team_car
	if i < 0 or DisplayServer.get_name() == "headless":
		return
	world.add_pit_guide(session.sim.pits.guide_line(i))


## The car this machine has handed to its driver to drive into the pits
## themselves (-1 none), and that car's pit phase last tick (for messages).
var _self_drive_car := -1
var _seen_pit := {}


## Each tick: the player at the wheel drives their own pit stops (unless
## they chose automatic, or the autodrive is driving for them); a car that's
## no longer theirs (handed to an AI co-driver) goes back to the guide.
func _update_self_drive() -> void:
	var pits := session.sim.pits
	if not pits.enabled:
		return
	var me := session.local_car
	var want := me >= 0 and autodrive == null and str(GameData.prefs.get("pit_drive_in", "self")) == "self"
	var car := me if want else -1
	if car != _self_drive_car:
		if _self_drive_car >= 0 and session.owns(_self_drive_car):
			pits.set_self_drive(_self_drive_car, false)
		_self_drive_car = car
	if car >= 0:
		pits.set_self_drive(car, true)
		_pit_messages(car)


## Messages for a driver driving their own stop: a missed pit entry, a box
## overshot or missed.
func _pit_messages(car: int) -> void:
	var p: Dictionary = session.sim.entries[car].pit
	var was: Dictionary = _seen_pit
	var ph: String = p["phase"]
	if not was.is_empty():
		if was["phase"] == PitRules.PHASE_APPROACH and ph == PitRules.PHASE_NONE and p["box"]:
			hud.flash("Missed the pit entry: box next lap", 3.0)
		if was["phase"] == PitRules.PHASE_LIMIT and ph == PitRules.PHASE_SERVICE:
			var extra := float((p.get("work", {}) as Dictionary).get("overshoot_s", 0.0))
			hud.flash("Overshot your box: +%.1f s" % extra if extra > 0.0 else "On your marks", 2.0)
		if bool(p.get("missed_box", false)) and not bool(was.get("missed", false)):
			hud.flash("Missed your box: box again next lap", 3.0)
	_seen_pit = {"phase": ph, "missed": bool(p.get("missed_box", false))}


## Outlines on the ground: gold round this player's own car (or the team's
## car on the pit wall), a fainter blue round cars other people are driving.
## Settings > Gameplay turns each on or off.
func _refresh_highlights() -> void:
	var show_me := bool(GameData.prefs.get("highlight_me", true))
	var show_others := bool(GameData.prefs.get("highlight_players", true))
	var mine := session.local_car if session.local_car >= 0 else session.team_car
	for i in car_views.size():
		var kind := CarView.Highlight.NONE
		if i == mine:
			kind = CarView.Highlight.SELF if show_me else CarView.Highlight.NONE
		elif session.mode != RaceSession.Mode.OFFLINE and show_others and session.sim.entries[i].is_player_driving():
			kind = CarView.Highlight.PLAYER
		car_views[i].set_highlight(kind)


## Testing: --autodrive lets the AI drive this player's car.
func _make_autodrive() -> void:
	autodrive = null
	if GameData.arg("autodrive") and session.local_car >= 0:
		autodrive = AIDriver.for_car(session.sim, session.local_car)
		autodrive.pit_strategy.telemetry = session.telemetry


## True when this player is in a car's crew but not driving it (co-op).
func _is_crew() -> bool:
	return session.local_car < 0 and session.team_car >= 0


var _was_crew := false
var _camera_placed := false


## Shows the driving HUD or the pit wall console for the local role, and
## after a driver change hands the controls, sound and radio to the new driver.
func _apply_role() -> void:
	var is_crew := _is_crew()
	hud.visible = not is_crew
	crew.visible = is_crew
	crew.refresh_role()
	if not is_crew:
		crew.radio.close()
	driver_radio.car = session.local_car if session.local_car >= 0 else session.team_car
	driver_radio.close()
	if is_crew and not _was_crew:
		_zoom_before_full = _zoom_target
		_set_zoom(1.0)   # the pit wall starts on the whole track
	elif not is_crew and _was_crew:
		_set_zoom(_zoom_before_full)
	_was_crew = is_crew


## Co-op: this player's role changed, e.g. took over the wheel at a pit stop.
func _on_role_changed(role: String) -> void:
	local_input = LocalInput.new()
	_set_driving_aids()
	_make_autodrive()
	if DisplayServer.get_name() == "headless":
		print("[coop] %s is now %s of car %d (driving car %d)" % [Net.local_name, role, session.team_car, session.local_car])
	if race_audio:
		race_audio.queue_free()
	race_audio = RaceAudio.new()
	add_child(race_audio)
	race_audio.setup(session.sim.cars, session.sim.defs, session.local_car)
	race_audio.set_environment(session.sim.env)
	_apply_role()
	_refresh_highlights()
	hud.flash("You're driving!" if session.local_car >= 0 else "You're on the pit wall: " + CrewConsole.role_title(session.local_role).to_lower(), 3.0)


func _on_team_radio(car: int, msg: Dictionary) -> void:
	if car != session.team_car and car != session.local_car:
		return
	crew.add_radio(msg)
	var me := driver_radio.my_name() if session.local_car >= 0 else crew.radio.my_name()
	if session.local_car == car and str(msg.get("role", "")) != RaceEntry.ROLE_DRIVER:
		# The driver: on screen, and read out over the radio.
		var lines: Array = msg.get("lines", [])
		hud.show_radio(msg, clampf(4.0 + lines.size() * 2.2, 5.0, 16.0))
		Sound.radio(str(msg.get("text", "")))
	elif str(msg.get("from", "")) != me:
		Sound.ui("chime", -6.0)


## The pit stop planner for our car (the strategist's, or the driver's own).
func _open_planner() -> void:
	var car := session.team_car if session.team_car >= 0 else session.local_car
	if car >= 0 and session.sim.pits.enabled:
		planner.open_for(car)


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
	if (hud.editing or pit_menu.visible) and session.mode == RaceSession.Mode.OFFLINE:
		return   # offline races wait while the HUD layout is edited or a stop is planned
	for _k in _film_extra_ticks():
		_tick_once(delta)
	_tick_once(delta)
	_after_tick()


func _tick_once(delta: float) -> void:
	var inp: CarInput = null
	if session.local_car >= 0:
		if autodrive:
			inp = autodrive.get_input(session.sim, session.local_car)
			_autodrive_throttle = inp.throttle
		elif hud.editing or pause_menu.visible:
			inp = CarInput.neutral()   # online HUD editing / menu: the keys work the menu, not the car
		else:
			inp = local_input.read(delta, session.sim.cars[session.local_car].speed())
			if pit_menu.visible and inp.handbrake:
				inp.handbrake = false   # online the race runs on: A / Space confirms the menu, not the handbrake
	session.tick(inp)


func _after_tick() -> void:
	_update_self_drive()
	# Testing: --request-swap asks for a driver change (this player takes the
	# wheel at the next stop) once the race is green (and once they're on the
	# pit wall, after --hand-over).
	if GameData.arg("request-swap") and not _forced.has("swap") and session.team_car >= 0 \
			and session.local_car < 0 and session.sim.phase == RaceSim.Phase.RACING \
			and session.sim.pits.phase(session.team_car) == PitRules.PHASE_NONE:
		_forced["swap"] = true
		var driver := session.sim.entries[session.team_car].driver_peer()
		if driver > 0 or RaceEntry.is_ai_peer(driver):
			session.request_role_swap(session.team_car, session.local_peer, driver)
			print("[coop] %s asked to take over from peer %d at the next stop" % [Net.local_name, driver])
			if RaceEntry.is_ai_peer(driver):
				session.request_pit(session.team_car, {"box": true})  # call our AI co-driver in
	# Testing: --hand-over boxes this player's car and hands it to their
	# co-driver at that stop, once the race is green.
	if GameData.arg("hand-over") and not _forced.has("hand_over") and session.local_car >= 0 \
			and session.sim.phase == RaceSim.Phase.RACING:
		_forced["hand_over"] = true
		print("[coop] %s: %s" % [Net.local_name, RaceHud.toggle_driver_change(session, session.local_car)])
		session.request_pit(session.local_car, {"box": true})
	# Testing: --host-restart-at 5: the online host restarts the race for
	# everyone (the pause menu's Restart) once, after 5 s of racing.
	if GameData.arg("host-restart-at") and session.mode == RaceSession.Mode.SERVER \
			and session.sim.race_time >= float(GameData.arg("host-restart-at")):
		GameData.args.erase("host-restart-at")
		print("[pause] host restarts the race for everyone")
		Net.restart_race()
	# Testing: --force-sc 30 sends the safety car out after 30 s (--force-vsc too).
	for opt in ["force-sc", "force-vsc"]:
		if GameData.arg(opt) and not _forced.has(opt) and session.is_authority() \
				and session.sim.race_time >= float(GameData.arg(opt)):
			_forced[opt] = true
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
## The pit crew mini-game's close view of the box: metres across the
## view's short side, and how far the camera has moved to it (0..1).
const BOX_VIEW_M := 15.0
var _box_mix := 0.0
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
	var vs := _view_rect().size
	return minf(vs.x / _track_rect.size.x, vs.y / _track_rect.size.y) * 0.94


## The part of the window the race is seen through (the pit wall console
## covers the sides of the screen).
func _view_rect() -> Rect2:
	if crew and crew.visible:
		return crew.view_rect()
	return get_viewport_rect()


func _set_zoom(z: float) -> void:
	_zoom_target = clampf(z, 0.0, 1.0)
	GameData.prefs["zoom"] = _zoom_target


## Filming: --film-from 40 fast-forwards the race to 40 s (offline only:
## extra sim ticks per physics frame), then plays it at normal speed and
## prints the frame filming starts on.
var _film_rolling := false


func _film_extra_ticks() -> int:
	if _film_rolling or not GameData.arg("film-from") or session.mode != RaceSession.Mode.OFFLINE:
		return 0
	if session.sim.race_time + session.sim.phase_time * float(session.sim.phase == RaceSim.Phase.COUNTDOWN) \
			< float(GameData.arg("film-from")):
		return 9
	_film_rolling = true
	print("[film] rolling at frame %d" % Engine.get_frames_drawn())
	return 0


func _process(delta: float) -> void:
	var focus := session.local_car if session.local_car >= 0 else session.team_car
	if focus < 0:
		focus = session.team_car if session.team_car >= 0 else session.sim.running_order[0]
	var car: CarState = session.sim.cars[focus]
	var target := car_views[focus].pos2
	var heading := car_views[focus].heading
	var speed := car.speed()
	# Held zoom: keys, bumpers and the right stick all ramp smoothly.
	var zin := Input.get_action_strength("zoom_out") - Input.get_action_strength("zoom_in")
	if absf(zin) > 0.0 and not pit_wall.visible:  # the bumpers pick tyres on the pit wall
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
	# A player doing a crew job (PitCrewGame): close in on the box, north up.
	# On the pit wall the console steps aside for it, and comes back when the
	# lollipop sends the car.
	var box_view := crew_game.wants_close_view()
	if _is_crew() and crew.visible == box_view:
		crew.visible = not box_view
	_box_mix = move_toward(_box_mix, 1.0 if box_view else 0.0, delta * 2.5)
	if _box_mix > 0.0:
		var k := smoothstep(0.0, 1.0, _box_mix)
		var box_z := minf(_view_rect().size.x, _view_rect().size.y) / BOX_VIEW_M
		z = exp(lerpf(log(z), log(box_z), k))
		follow = follow.lerp(crew_game.view_centre() if crew_game.car >= 0 else target, k)
	var centre_mix := smoothstep(0.85, 1.0, _zoom) * (1.0 - _box_mix)
	# Put the view's centre (not the window's) on the target.
	var shift := (_view_rect().get_center() - vs * 0.5) / z
	camera.position = follow.lerp(_track_rect.get_center(), centre_mix) - shift
	camera.position_smoothing_enabled = centre_mix < 0.01
	camera.zoom = Vector2(z, z)
	var rc := session.sim.race_control
	var recovering := rc.recovery_vehicles()
	world.set_recovery_vehicles(recovering)
	world.set_marshals(rc.marshal_views())
	for i in car_views.size():
		car_views[i].visible = not rc.recovered[i]
		car_views[i].hoist = 0.0
	for v in recovering:
		if v["kind"] == "crane" and int(v["car"]) < car_views.size():
			car_views[int(v["car"])].hoist = v["hoist"]
	_update_pit_crews()
	_update_rejoin()
	world.set_safety_car(rc.sc_visible, rc.sc_pos, rc.sc_heading, rc.sc_speed, rc.sc_lights)
	world.update_driving_line(car.pos, speed)
	_update_pit_guide(delta)
	if world.driving_line:
		world.driving_line.visible = world.driving_line.enabled and session.local_car >= 0
	race_audio.update(delta, camera.position, local_input.last_throttle if autodrive == null else _autodrive_throttle, _zoom)
	var rot := rotate_camera and _zoom < 0.5 and _box_mix <= 0.0
	camera.ignore_rotation = not rot
	if rot:
		camera.rotation = heading + PI * 0.5
	world.set_camera(camera.get_screen_center_position(), z, camera.rotation if rot else 0.0)
	_camera_placed = true
	_maybe_screenshot()


## The pit guide line follows this player's car while they drive in themselves.
func _update_pit_guide(delta: float) -> void:
	var me := session.local_car
	var pits := session.sim.pits
	if world.pit_guide == null or me < 0 or not pits.self_drives(me) or not hud.pit_guide_on:
		world.update_pit_guide(PitRules.GUIDE_NONE, 0.0, true, false, delta)
		return
	var p: Dictionary = session.sim.entries[me].pit
	var ph: String = p["phase"]
	var g := pits.guide_info(me)
	var progress := pits.guide_progress(me)
	if ph == PitRules.PHASE_EXIT or str(g["stage"]) == "":
		progress = PitRules.GUIDE_NONE
	var stopping: bool = ph in [PitRules.PHASE_NONE, PitRules.PHASE_APPROACH, PitRules.PHASE_ENTRY, PitRules.PHASE_LIMIT] \
		and not bool(p.get("missed_box", false))
	world.update_pit_guide(progress, session.sim.cars[me].speed(), stopping, bool(g.get("on_marks", false)), delta)


var _pit_work := {}   ## car -> the stop's work while it's on its way in


## Tells the pit crews what each car's stop is doing.
func _update_pit_crews() -> void:
	var pits := session.sim.pits
	if not pits.enabled:
		return
	for i in session.sim.car_count():
		var p: Dictionary = session.sim.entries[i].pit
		var ph: String = p["phase"]
		var state := PitCrews.Stop.NONE
		var work: Dictionary = p.get("work", {})
		if ph == PitRules.PHASE_SERVICE:
			state = PitCrews.Stop.SERVICE
		elif ph == PitRules.PHASE_LEAVE:
			state = PitCrews.Stop.LEAVING
		elif p["box"] and (ph == PitRules.PHASE_ENTRY or ph == PitRules.PHASE_LIMIT or ph == PitRules.PHASE_APPROACH
				or (ph == PitRules.PHASE_NONE and int(p.get("crew_play", 0)) & PitRules.job_bit(PitRules.JOB_LANCE))):
			# On their way in (a co-op crew laying out the tyres: from the call).
			state = PitCrews.Stop.COMING
			if not _pit_work.has(i) or int(p.get("crew_play", 0)) != 0:
				var coming := pits.service_for(i, p["plan"])
				coming["crew"] = pits.crew_timeline(i, coming, PitRules.played_jobs(p))
				_pit_work[i] = coming
			work = _pit_work[i]
		if state != PitCrews.Stop.COMING:
			_pit_work.erase(i)
		var elapsed := float(p.get("service_total", 0.0)) - float(p.get("service_left", 0.0))
		world.set_pit_stop(i, state, elapsed, work)


## The band on the circuit where our car would rejoin after a clean stop:
## while it's boxing or in the pit lane, and always on the crew console
## (the pit wall plans the stop from it).
func _update_rejoin() -> void:
	var car := session.local_car if session.local_car >= 0 else session.team_car
	var pits := session.sim.pits
	var show := pits.enabled and car >= 0 and session.sim.phase == RaceSim.Phase.RACING
	var est := {}
	if show:
		var p: Dictionary = session.sim.entries[car].pit
		var ph: String = p["phase"]
		show = (p["box"] or (ph != PitRules.PHASE_NONE and ph != PitRules.PHASE_EXIT) or crew.visible)
		if show:
			est = pits.rejoin_estimate(car)
			show = not est.is_empty()
	if not show:
		world.set_rejoin(false)
		return
	# At least a few pixels long and wide however far out the camera is.
	var v: float = est["speed"]
	var ppm := maxf(camera.zoom.x, 0.01)
	world.set_rejoin(true, est["s"], maxf(v * 0.8, 40.0 / ppm), maxf(v * 0.2, 10.0 / ppm), RaceHud.rejoin_colour(est),
		maxf(6.0 / ppm - 4.0, 0.0))


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
		# --screenshot-pause [settings|restart|menu|desktop|lobby]: with the pause menu
		# (or its Settings, or its "Are you sure?" popup for that button) open.
		if GameData.arg("screenshot-pause"):
			_open_pause_menu()
			if str(GameData.arg("screenshot-pause")) == "settings":
				pause_menu._open_settings()
			elif str(GameData.arg("screenshot-pause")) in ["restart", "menu", "desktop", "lobby"]:
				pause_menu.ask_confirm(str(GameData.arg("screenshot-pause")))
			for _f in 4:
				await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(str(GameData.arg("screenshot")))
		print("[screenshot] saved")
		get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if hud.editing or pit_menu.visible or pause_menu.visible:
		return
	if event.is_action_pressed("hud_edit") and session.local_car >= 0 and not _results_shown and not pit_wall.visible:
		hud.open_editor()
	elif event.is_action_pressed("strategy_screen") and not _results_shown and session.sim.settings.has_pit_wall():
		pit_wall.toggle()   # no pit wall in rallycross or derby: no stops, flags or safety car
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_zoom(_zoom_target - ZOOM_WHEEL_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(_zoom_target + ZOOM_WHEEL_STEP)
	elif event.is_action_pressed("zoom_full"):
		_toggle_full_track()
	elif event.is_action_pressed("team_radio") and session.local_car >= 0 and _has_crew_mates():
		driver_radio.toggle()
	elif session.local_car >= 0 and _pit_input(event):
		pass
	elif event.is_action_pressed("camera_toggle") and not _is_crew():
		rotate_camera = not rotate_camera
	elif event.is_action_pressed("restart_race") and session.mode == RaceSession.Mode.OFFLINE \
			and not session.start_data.has("season"):  # no do-overs in a championship
		_restart()
	elif event.is_action_pressed("back_to_menu") and not _results_shown and not pit_wall.visible and not planner.visible \
			and not driver_radio.visible and not crew.radio.visible:
		get_viewport().set_input_as_handled()
		_open_pause_menu()


func _has_crew_mates() -> bool:
	return session.sim.entries[session.local_car].human_crew().size() > 1


## Pit calls for the car this player drives (see PitRules / RaceSession.request_pit).
const FUEL_STEPS := [-1.0, 0.0, 10.0, 20.0, 30.0, 50.0, 80.0]


func _pit_input(event: InputEvent) -> bool:
	var me := session.local_car
	var pits := session.sim.pits
	if not pits.enabled:
		return false
	var p: Dictionary = session.sim.entries[me].pit
	var plan: Dictionary = p["plan"]
	if event.is_action_pressed("pit_box"):
		var box: bool = not p["box"]
		if box and _pit_menu_wanted(me):
			pit_menu.open(me)
			return true
		session.request_pit(me, {"box": box})
		hud.flash("BOX THIS LAP" if box else "Pit call cancelled", 1.5)
	elif event.is_action_pressed("pit_limiter"):
		var on: bool = not p["limiter"]
		session.request_pit(me, {"limiter": on})
		hud.flash("Pit limiter ON" if on else "Pit limiter off", 1.2)
	elif event.is_action_pressed("pit_tyres"):
		var choices := PitRules.TYRE_CHOICES
		var next: String = choices[(choices.find(str(plan["tyre"])) + 1) % choices.size()]
		session.request_pit(me, {"tyre": next})
		hud.flash("Next stop tyres: " + RaceHud.tyre_plan_text(session.sim, me, next), 1.5)
	elif event.is_action_pressed("pit_fuel"):
		var k := FUEL_STEPS.find(float(plan["fuel"]))
		var next: float = FUEL_STEPS[(k + 1) % FUEL_STEPS.size()]
		session.request_pit(me, {"fuel": next})
		hud.flash("Next stop fuel: " + RaceHud.fuel_plan_text(next), 1.5)
	elif event.is_action_pressed("pit_wheels"):
		var ch := PitRules.WHEEL_CHOICES
		var next: String = ch[(ch.find(str(plan.get("wheels", PitRules.WHEELS_ALL))) + 1) % ch.size()]
		session.request_pit(me, {"wheels": next})
		hud.flash("Next stop: change " + RaceHud.wheels_text(next), 1.5)
	elif event.is_action_pressed("pit_driver"):
		hud.flash(RaceHud.toggle_driver_change(session, me), 2.0)
	else:
		return false
	return true



## Single player: calling a stop opens the pit call menu (Settings >
## Gameplay > Pit call menu). Online races don't stop for it, so there the
## keys and the pit wall do the job.
func _pit_menu_wanted(me: int) -> bool:
	return session.mode == RaceSession.Mode.OFFLINE and bool(GameData.prefs.get("pit_menu", true)) \
		and session.sim.pits.phase(me) == PitRules.PHASE_NONE and session.sim.phase == RaceSim.Phase.RACING


func _on_pit_menu_confirmed(changes: Dictionary) -> void:
	var me := session.local_car
	if me < 0:
		return
	changes["box"] = true
	session.request_pit(me, changes)
	hud.flash("BOX THIS LAP", 1.5)


func _on_events(evs: Array) -> void:
	race_audio.on_events(evs)
	for e in evs:
		match e["type"]:
			"collision":
				var ca: CarState = session.sim.cars[e["a"]]
				var cb: CarState = session.sim.cars[e["b"]]
				world.impact(e["pos"], (ca.vel + cb.vel) * 0.5, float(e["impulse"]) / 9000.0)
				world.car_hit(e["a"], e["pos"])
				world.car_hit(e["b"], e["pos"])
			"barrier_impact":
				var c: CarState = session.sim.cars[e["car"]]
				var nrm: Vector2 = e.get("normal", c.right())
				var soft: bool = int(e.get("barrier", TrackData.Barrier.ARMCO)) == TrackData.Barrier.TYRES
				world.impact(c.pos + nrm * session.sim.defs[e["car"]].width * 0.5, c.vel, float(e["speed"]) / 22.0, not soft)
				world.car_hit(e["car"], c.pos + nrm * session.sim.defs[e["car"]].width * 0.5)
			"countdown": pass
			"green":
				if session.sim.settings.is_qualifying():
					hud.flash("QUALIFYING: %d laps, your best lap sets your grid slot" % session.sim.settings.laps, 3.5)
				elif session.sim.settings.is_rallycross() and session.sim.track.has_joker():
					hud.flash("GO!  Take the joker lane once", 2.5)
				else:
					hud.flash("GO!", 1.5)
			"lap":
				if e["car"] == session.local_car:
					hud.flash("Lap %d  %s" % [e["lap"], RaceHud.fmt_time(e["time"])], 2.5)
			"chequered": hud.flash("Chequered flag! %s wins" % session.sim.entries[e["car"]].driver_name, 3.0)
			"finished":
				if e["car"] == session.local_car:
					hud.flash("Finished P%d" % e["position"], 4.0)
			"pit_stop":
				if e["car"] == session.local_car:
					var std := float(e.get("standard_s", 0.0))
					var txt := "Pit stop %.1f s" % e["stationary_s"]
					if std > 0.0 and not e.get("played", false):
						txt += "  (%s%.1f s on a standard stop)" % ["+" if float(e["stationary_s"]) >= std else "-", absf(float(e["stationary_s"]) - std)]
					if int(e.get("fumble", -1)) >= 0:
						txt += "  The crew fumbled the %s" % RaceHud.wheels_text(["fl", "fr", "rl", "rr"][int(e["fumble"])])
					hud.flash(txt, 3.5)
			"safety_car":
				var says := {"sc": "SAFETY CAR DEPLOYED", "vsc": "VIRTUAL SAFETY CAR", "vsc_ending": "VSC ENDING",
					"lapped_may_overtake": "LAPPED CARS MAY OVERTAKE", "in_this_lap": "SAFETY CAR IN THIS LAP",
					"restart": "SAFETY CAR IN - RESTART", "green": "GREEN FLAG"}
				if says.has(e.get("state", "")):
					hud.flash(says[e["state"]], 2.5)
			"penalty":
				if e["car"] == session.local_car:
					hud.flash("+%d s penalty: %s" % [int(e["seconds"]), e["reason"]], 4.0)
			"joker":
				if e["car"] == session.local_car:
					hud.flash("JOKER LAP TAKEN", 2.0)
			"retired":
				if e["car"] == session.local_car:
					hud.flash({"engine": "ENGINE GONE: YOU'RE OUT", "stopped": "YOUR CAR WON'T MOVE: YOU'RE OUT"}.get(str(e.get("reason", "")), "RETIRED"), 4.0)


func _on_race_finished() -> void:
	var sim := session.sim
	_save_race_data()
	var season_info: Dictionary = session.start_data.get("season", {})
	var season_pts := _season_session_done(season_info) if not season_info.is_empty() else {}
	var quali := sim.settings.is_qualifying()
	var lines := []
	for p in sim.running_order.size():
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var extra := ""
		if sim.pits.enabled and (sim.settings.mandatory_pit_stops > 0 or int(e.pit.get("stops", 0)) > 0):
			extra += "  stops %d" % int(e.pit.get("stops", 0))
		if e.penalty_s > 0.0:
			extra += "  +%d s pen" % int(e.penalty_s)
		if sim.settings.is_rallycross() and sim.track.has_joker():
			extra += "  joker %s" % ("yes" if e.jokers >= sim.settings.joker_laps else "MISSED")
		if quali:
			lines.append("P%-2d %-18s %-16s best %s" % [p + 1, e.driver_name, sim.defs[i].display_name,
				RaceHud.fmt_time(e.best_lap) if e.best_lap > 0.0 else "no time"])
			continue
		if not season_info.is_empty():
			var got: int = season_pts.get(SeasonResults.key_for(e.is_ai, e.driver_name), 0)
			extra += "  +%d pts" % got if got > 0 else ""
		lines.append("P%-2d %-18s %-16s %s  best %s%s" % [p + 1, e.driver_name, sim.defs[i].display_name,
			"DNF" if e.dnf else RaceHud.fmt_time(e.finish_time + e.penalty_s), RaceHud.fmt_time(e.best_lap), extra])
	var prize := _pay_prize() + _season_prize
	if prize > 0:
		lines.append("")
		lines.append("Prize money: +%s  (team budget %s)" % [UpgradeCatalog.format_money(prize),
			UpgradeCatalog.format_money(TeamProfile.load_or_new().money)])
	var title := "RESULTS"
	if not season_info.is_empty():
		title = "%s  ·  %s  ·  round %d of %d" % ["QUALIFYING" if quali else "RESULTS", season_info.get("name", "Season"),
			int(season_info["round"]) + 1, int(season_info["rounds"])]
		lines.append_array(_season_standings_lines(season_info))
	if DisplayServer.get_name() == "headless" or GameData.arg("quit-after-race"):
		for e in sim.entries:
			if not e.is_ai and not e.setup.is_empty():
				var keys: Array = e.setup.keys()
				keys.sort()
				print("[setup] %s: %s" % [e.driver_name, ", ".join(keys)])
		print("[results]\n" + "\n".join(lines))
		var heard := []
		for i in session.timelines:
			heard.append("%s=%d" % [sim.entries[i].driver_name, session.timelines[i].received])
		if not heard.is_empty():
			print("[net] car states received: " + ", ".join(heard))
			var present := 0
			for i in session.timelines:
				if session.timelines[i].clocks_agree():
					present += 1
			print("[net] clock synced %s (ping %d ms), %d of %d remote cars placed in the present" % [
				session.clock_synced(), roundi(Net.clock.rtt * 1000.0), present, session.timelines.size()])
	var final_session := not season_info.is_empty() and not quali \
		and int(season_info.get("round", 0)) + 1 >= int(season_info.get("rounds", 0))
	if GameData.arg("quit-after-race") or (GameData.arg("quit-after-season") and final_session):
		# Bound to the tree, not this scene: a client may leave the race scene
		# (host gone) before the timer fires.
		get_tree().create_timer(2.0).timeout.connect(get_tree().quit)
		return
	if session.mode == RaceSession.Mode.SERVER and Net.dedicated:
		get_tree().create_timer(3.0 if GameData.arg("quit-after-season") else 10.0).timeout.connect(func(): Net.end_race())
		return
	if GameData.arg("quit-after-season") and session.mode == RaceSession.Mode.OFFLINE:
		_back_to_menu.call_deferred()  # the menu starts the next session
		return
	if GameData.arg("quit-after-season") and session.mode == RaceSession.Mode.CLIENT:
		return  # wait for the host to bring everyone back to the lobby
	_show_results(lines, title)


## A season session (qualifying or race) just ended. The host / offline
## player records it in the season (GameData.season), saves the season and
## the session's race log, and online shares the new standings and the next
## round's settings with the lobby. Every machine works out the points the
## same way, and tells _on_season_round_done about its own car.
## Returns the points per driver key (race only).
func _season_session_done(info: Dictionary) -> Dictionary:
	var sim := session.sim
	var result := SeasonResults.from_race(sim, session.telemetry)
	var s = GameData.season
	var recorded := {}
	if session.is_authority() and s is Season and s.id == info.get("id", ""):
		recorded = s.record(result, int(info.get("round", -1)))
		if not recorded.is_empty():
			SeasonStore.save(s)
			SeasonStore.save_session_log(s.id, int(info["round"]), result["session"], result["log"])
			if session.mode == RaceSession.Mode.SERVER:
				Net.set_settings(s.settings_for_next())
				Net.set_season_info(s.summary())
			if DisplayServer.get_name() == "headless":
				print("[season] %s round %d %s recorded, next: %s" % [s.name, int(info["round"]) + 1, result["session"],
					"finished" if s.is_complete() else "round %d %s" % [s.round_index + 1, s.next_session()]])
	if sim.settings.is_qualifying():
		return {}
	var pts: Dictionary = recorded.get("points", {})
	if pts.is_empty():
		pts = Season.race_points(PointsSystem.from_dict(info.get("points", {})), result["classification"],
			result["fastest_key"], info.get("pole_key", ""))
	if session.team_car >= 0:
		var me := sim.entries[session.team_car]
		_on_season_round_done({"season_id": info.get("id", ""), "round": int(info.get("round", 0)),
			"rounds": int(info.get("rounds", 0)), "is_final_round": int(info.get("round", 0)) + 1 >= int(info.get("rounds", 0)),
			"my_position": me.position, "dnf": me.dnf and not me.finished, "field_size": sim.car_count(),
			"points_earned": int(pts.get(SeasonResults.key_for(me.is_ai, me.driver_name), 0))})
	return pts


## Championship races pay a little more than single races.
const SEASON_PRIZE_TIER := 1.25
var _season_prize := 0


## A season race ended for this player (on their own machine, online too):
## {season_id, round, rounds, is_final_round, my_position, dnf, field_size,
## points_earned}. Prize money (business module) is paid from here.
func _on_season_round_done(result: Dictionary) -> void:
	var sim := session.sim
	var pos: int = 0 if result["dnf"] else int(result["my_position"])
	var km := sim.settings.laps * sim.track.length / 1000.0
	_season_prize = Economy.race_prize(pos, int(result["field_size"]), km, SEASON_PRIZE_TIER)
	var profile := TeamProfile.load_or_new()
	profile.earn(_season_prize, "Season round %d: %s at %s" % [int(result["round"]) + 1,
		"P%d" % pos if pos > 0 else "DNF", sim.track.display_name])
	profile.save()


## The championship after this session (host / offline only; clients see it in the lobby).
func _season_standings_lines(info: Dictionary) -> Array:
	var s = GameData.season
	if not (s is Season and s.id == info.get("id", "")):
		return []
	var out := ["", "CHAMPIONSHIP" + ("  ·  FINAL" if s.is_complete() else "")]
	var k := 0
	for d in s.driver_standings().slice(0, 10):
		k += 1
		out.append("%2d %-18s %-20s %4d pts" % [k, d["name"].left(18), d["team"].left(20), d["points"]])
	if s.is_complete() and not s.champion().is_empty():
		out.append("%s is the champion!" % s.champion()["name"])
	return out


## Prize money for this player's own car, into their team budget (business
## module). Season rounds are paid by the season's own end-of-round hook.
func _pay_prize() -> int:
	var sim := session.sim
	if session.team_car < 0 or session.start_data.has("season"):
		return 0
	var e := sim.entries[session.team_car]
	var pos := 0 if e.dnf else sim.running_order.find(session.team_car) + 1
	var km := sim.settings.laps * sim.track.length / 1000.0
	var amount := Economy.race_prize(pos, sim.car_count(), km)
	var profile := TeamProfile.load_or_new()
	profile.earn(amount, "P%d at %s" % [pos, sim.track.display_name] if pos > 0 else "DNF at %s" % sim.track.display_name)
	profile.save()
	return amount


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


func _show_results(lines: Array, title := "RESULTS") -> void:
	_results_shown = true
	for c in results.get_children():
		c.queue_free()
	var v := VBoxContainer.new()
	results.add_child(v)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 30)
	v.add_child(t)
	var body := Label.new()
	body.text = "\n".join(lines)
	body.add_theme_font_override("font", SystemFont.new())
	v.add_child(body)
	var first: Button = null
	if session.mode == RaceSession.Mode.OFFLINE and session.start_data.has("season"):
		first = _results_button(v, "Continue season", _back_to_menu)
	elif session.mode == RaceSession.Mode.OFFLINE:
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
	get_tree().paused = false
	get_tree().reload_current_scene()


func _back_to_menu() -> void:
	get_tree().paused = false
	if Net.is_online():
		Net.leave()
	GameData.active_session = null
	get_tree().change_scene_to_file(GameData.SCENE_MENU)
