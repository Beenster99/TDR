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
var _give_back_to := -1    ## the car we're highlighting to let past (-1 none)
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
var _joker_line: DrivingLine   ## rallycross: the line through the joker lane
## The results screen, faded in once every car has finished.
var results: RaceResults
## The podium ceremony (top three finish), played before the results.
var podium: PodiumCeremony
var _layer: CanvasLayer
## Spectator mode: once this player's car has finished (or retired) and
## others are still racing, they watch the race: any car, any camera view.
var spectator: SpectatorHud
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
	_layer = layer
	# Spectator mode's onboard views: the onboard camera, full screen, under the HUD.
	_onboard_rect = TextureRect.new()
	_onboard_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_onboard_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_onboard_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_onboard_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_onboard_rect.visible = false
	layer.add_child(_onboard_rect)
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
		_onboard = onboard
		crew.onboard = onboard
		pit_wall.onboard = onboard
	crew.cover = pit_wall
	crew.car_screen_pos = func(i: int) -> Vector2:
		if not _camera_placed or world.camera == null or world.camera.is_position_behind(car_views[i].global_position):
			return Vector2(-1000, -1000)
		return world.camera.unproject_position(car_views[i].global_position)
	# Where a car (or the safety car, RaceControl.GIVE_BACK_SC) is on screen, for
	# HUD's pointer to the car to let past. null when it can't be placed.
	hud.car_screen_pos = func(i: int):
		var v: Node3D = world.safety_car if i == RaceControl.GIVE_BACK_SC else (car_views[i] if i >= 0 and i < car_views.size() else null)
		if v == null or not _camera_placed or world.camera == null:
			return null
		var p := v.global_position
		if world.camera.is_position_behind(p):
			return null
		return world.camera.unproject_position(p)
	hud.give_back_to = _give_back_to
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
	spectator = SpectatorHud.new()
	layer.add_child(spectator)
	spectator.setup(session)
	spectator.car_picked.connect(_spec_watch)
	spectator.car_step.connect(_spec_step)
	spectator.view_step.connect(_spec_next_view)
	_add_pause_menu(layer)
	_apply_role()
	if GameData.arg("pit-wall"):
		pit_wall.open()
	results = RaceResults.new()
	results.visible = false
	layer.add_child(results)
	results.chosen.connect(_on_results_chosen)
	var pointer := PointerHider.new()   # no mouse pointer over the track while driving
	pointer.driving = _driving_view
	add_child(pointer)
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
	if session.sim.settings.is_rallycross() and session.sim.track.has_joker():
		_joker_line = DrivingLine.build_joker(session.sim.track, session.sim.defs[i], session.sim.compounds[i])
		if _joker_line:
			world.add_joker_line(_joker_line, int(GameData.prefs.get("aid_driving_line", DrivingLineView.LINE_FULL)),
				bool(GameData.prefs.get("aid_braking_zones", true)))


## Rallycross: while the player still owes the joker, the joker line shows
## where it leaves the lap, beside the lap's line, so they can see which way
## to go; on the joker lane it takes over from the lap's line. Once the
## joker is done it goes away (unless they drive the joker again).
func _update_joker_line(car: CarState) -> void:
	var jl := world.joker_line
	if jl == null:
		return
	var sim := session.sim
	var me := session.local_car
	if me < 0 or not jl.enabled or _spectating:
		jl.visible = false
		return
	var e: RaceEntry = sim.entries[me]
	var owed := not sim.settings.is_qualifying() and e.jokers < sim.settings.joker_laps and not e.finished
	if car.in_joker:
		jl.visible = true
		jl.set_branch_only(false)
		if world.driving_line:
			world.driving_line.visible = false
	else:
		jl.visible = owed
		jl.set_branch_only(true)


## Settings changed mid-race (the pause menu's Settings): apply the ones the
## race scene owns.
func _on_pref_changed(key, _v) -> void:
	var k := str(key)
	if k.begins_with("highlight_"):
		_refresh_highlights()
		_wake_highlights()
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
		if _joker_line:
			world.add_joker_line(_joker_line, int(GameData.prefs.get("aid_driving_line", DrivingLineView.LINE_FULL)),
				bool(GameData.prefs.get("aid_braking_zones", true)))
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
	pause_menu.resume_all_requested.connect(func(): Net.request_pause(false, true))
	pause_menu.reopened.connect(func(): Net.request_pause(true))
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
	if online:
		Net.pause_changed.connect(_on_net_pause_changed)


## Esc / Start. Offline the race stops. Online it stops for everyone: the host
## puts every player in the pause menu (_on_net_pause_changed).
func _open_pause_menu() -> void:
	get_tree().paused = true   # the race, its sounds and effects stop; the menu runs
	pause_menu.open()
	if session.mode != RaceSession.Mode.OFFLINE:
		Net.request_pause(true)


## Resume (or restart / quit). Online the race only goes again once every
## player has resumed, so until then this player sees who it's waiting for.
func _on_pause_closed() -> void:
	if session.mode == RaceSession.Mode.OFFLINE:
		get_tree().paused = false
		return
	Net.request_pause(false)
	if Net.is_paused() and pause_menu.visible == false:
		pause_menu.show_waiting(_waiting_text(Net.pause_waiting))


## How long the online countdown runs after the last player resumes (s).
const PAUSE_COUNTDOWN := 3
var _pause_token := 0


## Online: the shared pause changed (any machine's Esc or Resume, via the host).
func _on_net_pause_changed(waiting: Array) -> void:
	_pause_token += 1
	if not waiting.is_empty():
		get_tree().paused = true
		if waiting.has(Net.my_id()):
			if not pause_menu.visible or pause_menu.waiting_mode:
				pause_menu.open()   # someone else paused: this player gets the menu too
				_maybe_auto_resume()
		elif not pause_menu.visible or pause_menu.waiting_mode:
			pause_menu.show_waiting(_waiting_text(waiting))
		pause_menu.set_waiting_text(_waiting_text(waiting))
		print("[pause] %s: paused at %.1f s, waiting for %s" % [Net.local_name, session.sim.race_time, _names(waiting)])
		return
	if not get_tree().paused:
		return
	# Everyone's ready: count down, then go.
	print("[pause] %s: everyone resumed, counting down" % Net.local_name)
	var token := _pause_token
	for n in range(PAUSE_COUNTDOWN, 0, -1):
		pause_menu.show_waiting("Racing in %d" % n)
		await get_tree().create_timer(1.0, true).timeout
		if token != _pause_token or not is_inside_tree():
			return   # paused again (or the race ended) during the countdown
	pause_menu.close_quietly()
	get_tree().paused = false
	print("[pause] %s: racing again at %.1f s" % [Net.local_name, session.sim.race_time])


## Testing (--auto-resume S): press Resume S seconds after the menu opened.
func _maybe_auto_resume() -> void:
	if GameData.arg("auto-resume"):
		get_tree().create_timer(float(GameData.arg("auto-resume")), true).timeout.connect(func():
			if pause_menu.visible and not pause_menu.waiting_mode:
				print("[pause] %s pressed Resume" % Net.local_name)
				pause_menu.resume())


func _names(ids: Array) -> String:
	var names := []
	for id in ids:
		names.append(str(Net.players.get(id, {}).get("name", "Player %d" % id)))
	return ", ".join(names)


func _waiting_text(waiting: Array) -> String:
	var others := waiting.filter(func(id): return id != Net.my_id())
	if others.is_empty():
		return "PAUSED"
	return "PAUSED  ·  waiting for %s to resume" % _names(others)


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


## Each tick: the player at the wheel drives their own pit stops, up to the
## pit limit line or (their choice) the whole stop, unless the autodrive is
## driving for them; a car that's no longer theirs (handed to an AI
## co-driver) goes back to the guide.
func _update_self_drive() -> void:
	var pits := session.sim.pits
	if not pits.enabled:
		return
	var me := session.local_car
	var want := me >= 0 and autodrive == null
	var car := me if want else -1
	if car != _self_drive_car:
		if _self_drive_car >= 0 and session.owns(_self_drive_car):
			pits.set_drive_in(_self_drive_car, PitRules.DRIVE_GUIDED)
		_self_drive_car = car
	if car >= 0:
		var whole := str(GameData.prefs.get("pit_drive_in", "limit")) == "self"
		pits.set_drive_in(car, PitRules.DRIVE_STOP if whole else PitRules.DRIVE_TO_LIMIT)
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
		if was["phase"] == PitRules.PHASE_LIMIT and ph == PitRules.PHASE_SERVICE and session.sim.pits.self_drives(car):
			var extra := float((p.get("work", {}) as Dictionary).get("overshoot_s", 0.0))
			hud.flash("Overshot your box: +%.1f s" % extra if extra > 0.0 else "On your marks", 2.0)
		if bool(p.get("missed_box", false)) and not bool(was.get("missed", false)):
			hud.flash("Missed your box: box again next lap", 3.0)
	_seen_pit = {"phase": ph, "missed": bool(p.get("missed_box", false))}


## Outlines on the ground: gold round this player's own car (or the team's
## car on the pit wall), a fainter blue round cars other people are driving.
## Settings > Gameplay turns each on or off. When race control tells our car
## to give a place back, the car to let past (or the safety car) gets a
## pulsing orange-red outline and a "LET PAST" tag, always, until it's done.
func _refresh_highlights() -> void:
	var show_me := bool(GameData.prefs.get("highlight_me", true))
	var show_others := bool(GameData.prefs.get("highlight_players", true))
	var mine := session.local_car if session.local_car >= 0 else session.team_car
	_give_back_to = session.sim.race_control.give_back_target(mine)
	for i in car_views.size():
		var kind := CarView.Highlight.NONE
		if i == _give_back_to:
			kind = CarView.Highlight.GIVE_BACK
		elif i == mine:
			kind = CarView.Highlight.SELF if show_me else CarView.Highlight.NONE
		elif session.mode != RaceSession.Mode.OFFLINE and show_others and session.sim.entries[i].is_player_driving():
			kind = CarView.Highlight.PLAYER
		car_views[i].highlight_fade_s = float(GameData.prefs.get("highlight_fade", 0))
		car_views[i].set_highlight(kind)
	if world.safety_car:
		world.safety_car.set_highlight(CarView.Highlight.GIVE_BACK if _give_back_to == RaceControl.GIVE_BACK_SC else CarView.Highlight.SAFETY)
	if hud:
		hud.give_back_to = _give_back_to


## Every frame: follow race control's give-back order for our car.
func _update_give_back() -> void:
	var mine := session.local_car if session.local_car >= 0 else session.team_car
	var t := session.sim.race_control.give_back_target(mine)
	if t != _give_back_to or (t == RaceControl.GIVE_BACK_SC and world.safety_car \
			and world.safety_car.highlight != CarView.Highlight.GIVE_BACK):
		_refresh_highlights()


## Car highlights that fade (Settings > Gameplay "highlight_fade") come back at
## the green light and whenever the camera zooms.
func _wake_highlights() -> void:
	for v in car_views:
		if v.highlight != CarView.Highlight.NONE:
			v.wake_highlight()


## Testing: --autodrive lets the AI drive this player's car.
func _make_autodrive() -> void:
	autodrive = null
	if GameData.arg("autodrive") and session.local_car >= 0:
		autodrive = AIDriver.for_car(session.sim, session.local_car)
		autodrive.pit_strategy.telemetry = session.telemetry


## True when this player is in a car's crew but not driving it (co-op).
## At the wheel with nothing on screen that wants the mouse (PointerHider).
func _driving_view() -> bool:
	return session.local_car >= 0 and not _results_shown and not _spectating and not results.visible and not pause_menu.visible and not hud.editing \
		and not pit_wall.visible and not planner.visible and not pit_menu.visible and not driver_radio.visible \
		and not crew_game.is_active()


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
	get_tree().paused = false
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
		var mine := session.sim.entries[session.local_car]
		_note_finish()
		if mine.finished and autodrive == null and _free_drive() and not (hud.editing or pause_menu.visible):
			# Over the line: the car is still yours for FINISH_DRIVE_S.
			inp = local_input.read(delta, session.sim.cars[session.local_car].speed())
		elif mine.finished and autodrive == null:
			# Then the AI drives the cool-down lap under the results.
			if _cooldown_ai == null:
				_cooldown_ai = AIDriver.for_car(session.sim, session.local_car)
			inp = _cooldown_ai.get_input(session.sim, session.local_car)
		elif mine.dnf and not mine.finished:
			inp = CarInput.neutral()
		elif autodrive:
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
	# Testing: --pause-at 5: press Esc after 5 s of racing (online: pauses the
	# race for everyone). --auto-resume 2: press Resume 2 s after the menu opens.
	if GameData.arg("pause-at") and not _forced.has("pause") \
			and session.sim.race_time >= float(GameData.arg("pause-at")):
		_forced["pause"] = true
		_open_pause_menu()
		print("[pause] %s opened the menu at %.1f s, tree paused %s" % [Net.local_name, session.sim.race_time, get_tree().paused])
		_maybe_auto_resume()
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
	_wake_highlights()
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
	_update_spectator(delta)
	var focus := session.local_car if session.local_car >= 0 else session.team_car
	if focus < 0:
		focus = session.team_car if session.team_car >= 0 else session.sim.running_order[0]
	if _spectating:
		focus = _spec_car
	var car: CarState = session.sim.cars[focus]
	var target := car_views[focus].pos2
	var heading := car_views[focus].heading
	var speed := car.speed()
	# Held zoom: keys, bumpers and the right stick all ramp smoothly.
	var zin := Input.get_action_strength("zoom_out") - Input.get_action_strength("zoom_in")
	if absf(zin) > 0.0 and not pit_wall.visible and not _results_shown:  # the bumpers pick tyres on the pit wall
		_set_zoom(_zoom_target + zin * ZOOM_RATE * delta)
	_zoom = lerpf(_zoom, _zoom_target, 1.0 - exp(-8.0 * delta))
	# Zoom level: log scale from close up to the whole track, so every bit
	# of the stick changes the view by the same feel. A little pull-back with
	# speed only when you're right in close.
	var close := ZOOM_CLOSE * lerpf(1.0, 0.75, clampf(speed / 70.0, 0.0, 1.0) * (1.0 - _zoom))
	var fit := _fit_zoom()
	var zoom_level := _zoom
	if _spectating and _spec_view == SpecView.TRACK:
		zoom_level = 1.0
	var z := exp(lerpf(log(close), log(fit), zoom_level))
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
	if _is_crew() and not _spectating and crew.visible == box_view:
		crew.visible = not box_view
	_box_mix = move_toward(_box_mix, 1.0 if box_view else 0.0, delta * 2.5)
	if _box_mix > 0.0:
		var k := smoothstep(0.0, 1.0, _box_mix)
		var box_z := minf(_view_rect().size.x, _view_rect().size.y) / BOX_VIEW_M
		z = exp(lerpf(log(z), log(box_z), k))
		follow = follow.lerp(crew_game.view_centre() if crew_game.car >= 0 else target, k)
	var centre_mix := smoothstep(0.85, 1.0, zoom_level) * (1.0 - _box_mix)
	var cam_centre := follow.lerp(_track_rect.get_center(), centre_mix)
	var smooth := centre_mix < 0.01
	# Put the view's centre (not the window's) on the target.
	var shift := (_view_rect().get_center() - vs * 0.5) / z
	camera.position = cam_centre - shift
	camera.position_smoothing_enabled = smooth
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
	_log_pit_stop()
	_update_rejoin()
	world.set_safety_car(rc.sc_visible, rc.sc_pos, rc.sc_heading, rc.sc_speed, rc.sc_lights)
	_update_give_back()
	world.update_driving_line(car.pos, speed)
	_update_pit_guide(delta)
	if world.driving_line:
		world.driving_line.visible = world.driving_line.enabled and session.local_car >= 0 and not _spectating
	_update_joker_line(car)
	race_audio.update(delta, camera.position, local_input.last_throttle if autodrive == null else _autodrive_throttle, _zoom)
	var rot := rotate_camera and _zoom < 0.5 and _box_mix <= 0.0
	if _spectating:
		rot = _spec_view == SpecView.CHASE
	_update_onboard_view()
	camera.ignore_rotation = not rot
	if rot:
		camera.rotation = heading + PI * 0.5
	world.set_camera(camera.get_screen_center_position(), z, camera.rotation if rot else 0.0)
	if _spectating and _spec_view == SpecView.TV:
		_update_tv_camera(delta)
	_camera_placed = true
	_maybe_screenshot()


## The pit guide line follows this player's car while they drive in themselves.
func _update_pit_guide(delta: float) -> void:
	var me := session.local_car
	var pits := session.sim.pits
	if world.pit_guide == null or me < 0 or not pits.drives_in(me) or not hud.pit_guide_on:
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
var _pit_work_key := {}   ## car -> hash of the plan _pit_work was made from


var _pit_log := {}   ## what _log_pit_stop last printed


## Writes our car's pit stop to the log (godot.log) as it goes: each phase
## change, and once a stop runs long, what the crew are still waiting for.
## Player reports of a stuck stop come with the log.
func _log_pit_stop() -> void:
	var car := session.local_car if session.local_car >= 0 else session.team_car
	var pits := session.sim.pits
	if car < 0 or not pits.enabled:
		return
	var p: Dictionary = session.sim.entries[car].pit
	var ph: String = p["phase"]
	var t := session.sim.race_time
	if ph != str(_pit_log.get("phase", "")):
		print("[pit] t %.1f car %d %s -> %s  auto %s self %s owns %s play %d box %s  crew game %s" % [t, car, _pit_log.get("phase", "?"), ph,
			p["auto"], pits.self_drives(car), session.owns(car), int(p.get("crew_play", 0)), p["box"], crew_game.jobs if crew_game.stage != PitCrewGame.Stage.IDLE else []])
		_pit_log = {"phase": ph, "since": t, "long": false}
	var since := t - float(_pit_log.get("since", t))
	if ph == PitRules.PHASE_SERVICE and not bool(_pit_log.get("long", false)) and since > float(p.get("service_std", 0.0)) + 3.0:
		_pit_log["long"] = true
		var tl: Dictionary = (p.get("work", {}) as Dictionary).get("crew", {})
		print("[pit] long stop: %.1f s of %.1f (standard %.1f), release %s, jobs %s, fuel %s, screen %s, tyres %s" % [
			float(p["service_total"]) - float(p["service_left"]), float(p["service_total"]), float(p.get("service_std", 0.0)),
			tl.get("release", "?"), p.get("crew_jobs", {}), tl.get("fuel", []), tl.get("screen", []), tl.get("tyres", [])])
	if ph in [PitRules.PHASE_LEAVE, PitRules.PHASE_EXIT] and not bool(_pit_log.get("long", false)) and since > 20.0:
		_pit_log["long"] = true
		print("[pit] still in the lane %.0f s after the stop: phase %s, speed %.1f m/s, controls %s" % [since, ph,
			session.sim.cars[car].speed(), pits.controls(car)])


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
				or ph == PitRules.PHASE_NONE):
			# Called in: the crew come out of the garage to their marks (and
			# a co-op crew lays out the tyres) while the car is on its in-lap.
			state = PitCrews.Stop.COMING
			var key := hash(p["plan"])
			if not _pit_work.has(i) or int(p.get("crew_play", 0)) != 0 or (ph == PitRules.PHASE_NONE and _pit_work_key.get(i) != key):
				var coming := pits.service_for(i, p["plan"])
				coming["crew"] = pits.crew_timeline(i, coming, PitRules.played_jobs(p))
				_pit_work[i] = coming
				_pit_work_key[i] = key
			work = _pit_work[i]
		if state != PitCrews.Stop.COMING:
			_pit_work.erase(i)
			_pit_work_key.erase(i)
		var elapsed := float(p.get("service_total", 0.0)) - float(p.get("service_left", 0.0))
		world.set_pit_stop(i, state, elapsed, work)


## The band on the circuit where our car would rejoin after a clean stop.
## It's the strategist's tool, so only the strategist sees it: on the co-op
## pit wall console (a strategist, or the combined pit wall role), and a
## solo driver planning their own stop in the pit call menu. Never on the
## driver's view while driving, in or out of the pit lane.
func _update_rejoin() -> void:
	var car := session.local_car if session.local_car >= 0 else session.team_car
	var pits := session.sim.pits
	var show := pits.enabled and car >= 0 and session.sim.phase == RaceSim.Phase.RACING and not _spectating \
		and strategist_view()
	var est := {}
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


## True while this player looks at the race as the strategist: the co-op
## console with the strategist's duties, or a solo driver's pit call menu.
func strategist_view() -> bool:
	if crew.visible and _is_crew() and RaceEntry.role_covers(str(session.local_role), RaceEntry.ROLE_STRATEGIST):
		return true
	return pit_menu.visible and session.local_car >= 0


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
		# --screenshot-pause [settings]: with the pause menu (or its Settings) open.
		if GameData.arg("screenshot-pause"):
			_open_pause_menu()
			if str(GameData.arg("screenshot-pause")) == "settings":
				pause_menu._open_settings()
			for _f in 4:
				await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(str(GameData.arg("screenshot")))
		print("[screenshot] saved")
		get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if hud.editing or pit_menu.visible or pause_menu.visible:
		return
	if _live_results and results.visible and not event is InputEventMouseButton:
		return   # the live results have the keys
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
	elif event.is_action_pressed("camera_toggle") and not _is_crew() and not _spectating:
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
				_wake_highlights()
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
					hud.flash(says[e["state"]], 4.0 if e["state"] == "in_this_lap" else 2.5)
			"penalty":
				_penalties.append({"car": int(e["car"]), "seconds": float(e.get("seconds", 0.0)), "reason": str(e.get("reason", ""))})
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
		print("[results] %s\n" % title + "\n".join(lines))
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
		# Long enough for a guest who just crossed the line to drive on and see the results.
		get_tree().create_timer(3.0 if GameData.arg("quit-after-season") else FINISH_DRIVE_S + 10.0).timeout.connect(func(): Net.end_race())
		return
	if GameData.arg("quit-after-season") and session.mode == RaceSession.Mode.OFFLINE:
		_back_to_menu.call_deferred()  # the menu starts the next session
		return
	if GameData.arg("quit-after-season") and session.mode == RaceSession.Mode.CLIENT:
		return  # wait for the host to bring everyone back to the lobby
	var finish := func():
		var pod := _podium_drivers()
		if not pod.is_empty():
			_start_podium(pod, func(): _show_results(season_info, season_pts, prize))
		else:
			_show_results(season_info, season_pts, prize)
	if _own_drive_left() > 0.0:
		_end_waiting = finish   # still driving after the line: the podium / results come after it
		return
	finish.call()


# --- The podium --------------------------------------------------------------

## The top three for the podium ceremony, [{name, car, colour, is_me}], or []
## when there's no ceremony: this player's car wasn't in the top three (or
## didn't finish), it was qualifying, or it's off in Settings > Gameplay.
## --podium forces one (screenshots, tests), even headless.
func _podium_drivers() -> Array:
	var sim := session.sim
	var forced := bool(GameData.arg("podium", false))
	if GameData.arg("no-podium") or sim.settings.is_qualifying() or sim.running_order.is_empty():
		return []
	if not forced and (DisplayServer.get_name() == "headless" or not bool(GameData.prefs.get("podium", true))):
		return []
	var me := _own_car()
	var pos := sim.running_order.find(me)
	var derby := sim.settings.discipline == RaceSettings.DISCIPLINE_DERBY
	var ok := me >= 0 and pos >= 0 and pos < 3 and (derby or (sim.entries[me].finished and not sim.entries[me].dnf))
	if not ok and not forced:
		return []
	var out := []
	for p in mini(3, sim.running_order.size()):
		var i := sim.running_order[p]
		out.append({"name": sim.entries[i].driver_name, "car": sim.defs[i].display_name,
			"colour": car_views[i].paint_colour() if i < car_views.size() else Color(0.8, 0.1, 0.1), "is_me": i == me})
	return out


## Fades the race out and the podium in; then_show (the results) runs once it has faded out again.
func _start_podium(drivers: Array, then_show: Callable) -> void:
	_results_shown = true   # no pause menu, HUD keys or driving from here on
	_stop_spectating()
	results.visible = false   # the live table: the full one comes after the podium
	hud.visible = false
	crew.visible = false
	var slot := -1
	for p in drivers.size():
		if drivers[p]["is_me"]:
			slot = p
	podium = PodiumCeremony.new()
	podium.autoplay = bool(GameData.arg("podium-autoplay", false))
	_layer.add_child(podium)
	var title := "PODIUM"
	var season_info: Dictionary = session.start_data.get("season", {})
	if not season_info.is_empty():
		title = "PODIUM  ·  ROUND %d" % (int(season_info.get("round", 0)) + 1)
	podium.start(drivers, slot, {"track": session.sim.track.display_name, "title": title, "seed": session.sim.settings.seed})
	podium.covered.connect(func():
		world.visible = false   # nothing of the race left to draw behind it
		_duck_race_audio())
	podium.finished.connect(func():
		then_show.call()
		# The results fade their backdrop in under the black, then the black goes.
		get_tree().create_timer(RaceResults.FADE_OUT_S + 0.05).timeout.connect(func():
			if is_instance_valid(podium):
				podium.queue_free()
				podium = null))
	if GameData.arg("podium-shots"):
		_podium_shots()
	print("[podium] %s, you %s" % [", ".join(drivers.map(func(d): return str(d["name"]))), "P%d" % (slot + 1) if slot >= 0 else "watching"])


var _audio_db := {}


## The cars go quiet under the podium (and the results after it).
func _duck_race_audio() -> void:
	for bus in ["Engine", "Effects"]:
		var idx := AudioServer.get_bus_index(bus)
		if idx < 0:
			continue
		if not _audio_db.has(bus):
			_audio_db[bus] = AudioServer.get_bus_volume_db(idx)
		var from: float = _audio_db[bus]
		create_tween().tween_method(func(v: float): AudioServer.set_bus_volume_db(idx, v), from, -80.0, 0.8)


func _exit_tree() -> void:
	for bus in _audio_db:
		var idx := AudioServer.get_bus_index(bus)
		if idx >= 0:
			AudioServer.set_bus_volume_db(idx, _audio_db[bus])
	_audio_db.clear()


## Testing: --podium-shots DIR saves pictures of the podium: the trophies,
## the champagne going, and the results after.
func _podium_shots() -> void:
	var dir := str(GameData.arg("podium-shots"))
	DirAccess.make_dir_recursive_absolute(dir)
	if DisplayServer.get_name() == "headless":
		return
	for shot in [["podium_trophy", PodiumCeremony.INTRO_S + 1.8], ["podium_pop", PodiumCeremony.INTRO_S + PodiumCeremony.TROPHY_S + 1.5],
			["podium_spray", PodiumCeremony.INTRO_S + PodiumCeremony.TROPHY_S + 4.0], ["podium_spray2", PodiumCeremony.INTRO_S + PodiumCeremony.TROPHY_S + 7.5]]:
		while is_instance_valid(podium) and podium.elapsed() < float(shot[1]):
			await get_tree().process_frame
		if not is_instance_valid(podium):
			return
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, shot[0]])
		print("[screenshot] %s, soaked %d" % [shot[0], podium.view.player_soaked])
	if is_instance_valid(podium):
		podium.finish()
	while not results.is_shown():
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/results_after_podium.png" % dir)
	print("[screenshot] results after the podium")
	if GameData.arg("quit-after-shots"):
		get_tree().quit()


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


## Fades the race out and the results screen in (RaceResults), with the
## buttons for this kind of race.
func _show_results(season_info: Dictionary, season_pts: Dictionary, prize: int) -> void:
	_results_shown = true
	_stop_spectating()
	# The cars fade out with the race picture, so the table is quiet.
	race_audio.fade_out(RESULTS_SOUND_FADE_S)
	Sound.radio_stop()
	hud.visible = false
	crew.visible = false
	var sim := session.sim
	var d := ResultsTable.build(sim, session.telemetry, {"me": _own_car(), "penalties": _penalties,
		"points": season_pts, "points_name": PointsSystem.from_dict(season_info.get("points", {})).display_name() if not season_info.is_empty() else "",
		"single_race_points": season_info.is_empty()})
	var buttons := []
	var notes := []
	if session.mode == RaceSession.Mode.OFFLINE and session.start_data.has("season"):
		buttons = [["menu", "Continue season"]]
	elif session.mode == RaceSession.Mode.OFFLINE:
		buttons = [["again", "Race again"], ["menu", "Main menu"]]
	elif session.mode == RaceSession.Mode.SERVER:
		buttons = [["lobby", "Back to lobby"]]
	else:
		notes.append("Waiting for the host to go back to the lobby...")
		buttons = [["leave", "Leave"]]
	if prize > 0:
		notes.push_front("Prize money: +%s  (team budget %s)" % [UpgradeCatalog.format_money(prize),
			UpgradeCatalog.format_money(TeamProfile.load_or_new().money)])
	var me := _own_car()
	if me >= 0 and not sim.settings.is_qualifying():
		for r in d["rows"]:
			if r["car"] == me:
				var got := "  ·  +%d points" % int(r["points"]) if int(r["points"]) > 0 else ""
				notes.push_front(("You were classified P%d" % int(r["pos"]) if r["status"] == "" else "You didn't finish") + got)
	var sub := ""
	if not season_info.is_empty():
		sub = "%s  ·  round %d of %d  ·  %s  ·  %d lap%s" % [season_info.get("name", "Season"), int(season_info["round"]) + 1,
			int(season_info["rounds"]), sim.track.display_name, sim.settings.laps, "" if sim.settings.laps == 1 else "s"]
	var opts := {"title": "QUALIFYING" if sim.settings.is_qualifying() else "RESULTS",
		"subtitle": sub, "buttons": buttons, "notes": notes, "standings": _standings(season_info),
		"instant": bool(GameData.arg("results-instant", false))}
	if results.visible and _live_results:
		results.update_results(d, opts)   # the live table becomes the final one, no fade
	else:
		results.show_results(d, opts)
		Sound.wire_buttons(results)
	if _live_results:
		_live_shot(true)
	_live_results = false
	if GameData.arg("spectate-shots") and DisplayServer.get_name() != "headless":
		_results_shot()
	if session.mode == RaceSession.Mode.CLIENT and not season_info.is_empty():
		# The host records the race and shares the new standings a moment later.
		_results_season = season_info
		Net.lobby_changed.connect(_on_lobby_changed_after_race)
	if DisplayServer.get_name() == "headless":
		var r0: Dictionary = d["rows"][0] if not d["rows"].is_empty() else {}
		print("[results screen] %d rows, fastest %s, %d penalties, points %s, standings %s" % [d["rows"].size(),
			str(d["fastest"].get("name", "-")), d["penalties"].size(), str(d["has_points"]),
			str(not opts["standings"].is_empty())] + ("" if r0.is_empty() else ", P1 %s potential %s" % [r0["name"], RaceResults.fmt_time(float(r0["potential"]))]))


var _results_season := {}
const RESULTS_SOUND_FADE_S := 1.6   ## the race sound goes silent this fast under the results


func _on_lobby_changed_after_race() -> void:
	if results.visible:
		results.set_standings(_standings(_results_season))


func _on_results_chosen(id: String) -> void:
	match id:
		"watch": _watch_race()
		"again": _restart()
		"menu", "leave": _back_to_menu()
		"lobby": Net.end_race()


## The championship for the results screen: the host / offline player has
## the whole season; online guests get the standings the host shares after
## it has recorded the race. {} = not a championship.
func _standings(info: Dictionary) -> Dictionary:
	if info.is_empty():
		return {}
	var me := _own_car()
	var my_key := ""
	if me >= 0:
		my_key = SeasonResults.key_for(session.sim.entries[me].is_ai, session.sim.entries[me].driver_name)
	var s = GameData.season
	if s is Season and s.id == info.get("id", ""):
		var drivers := []
		for dr in s.driver_standings().slice(0, 12):
			drivers.append({"name": dr["name"], "team": dr["team"], "points": dr["points"], "is_me": dr["key"] == my_key})
		var teams := []
		for t in s.team_standings().slice(0, 6):
			teams.append({"team": t["team"], "points": t["points"]})
		return {"title": "CHAMPIONSHIP" + ("  ·  FINAL" if s.is_complete() else ""),
			"note": "After round %d of %d" % [mini(s.round_index, s.rounds.size()), s.rounds.size()] if not session.sim.settings.is_qualifying()
				else "Before this round's race", "drivers": drivers, "teams": teams,
			"champion": s.champion().get("name", "") if s.is_complete() else ""}
	var si: Dictionary = Net.season_info
	if si.get("id", "") != info.get("id", ""):
		return {"title": "CHAMPIONSHIP", "note": "The host has the standings", "drivers": [], "teams": []}
	var updated := int(si.get("round", 0)) > int(info.get("round", 0)) or bool(si.get("complete", false))
	var my_name := session.sim.entries[me].driver_name if me >= 0 else ""
	var out_d := []
	for dr in si.get("drivers", []):
		out_d.append({"name": dr["name"], "team": dr.get("team", ""), "points": dr["points"],
			"is_me": not dr.get("is_ai", false) and dr["name"] == my_name})
	return {"title": "CHAMPIONSHIP" + ("  ·  FINAL" if si.get("complete", false) else ""),
		"note": ("After this race" if updated else "Before this race: the host is adding this race's points")
			if not session.sim.settings.is_qualifying() else "Before this round's race",
		"drivers": out_d, "teams": si.get("teams", []), "champion": str(si.get("champion", ""))}


# --- Spectator mode -------------------------------------------------------------

enum SpecView { FOLLOW, CHASE, ONBOARD, REAR, TV, TRACK }
const SPEC_VIEW_NAMES := ["Follow", "Chase (turns with the car)", "Onboard", "Onboard, looking back", "Trackside TV", "Whole track"]
## Seconds this player keeps driving their car after crossing the line,
## before the results fade in (and fill up as the others finish).
const FINISH_DRIVE_S := 10.0
## Seconds after retiring before the results come up.
const SPECTATE_DELAY_S := 3.0
## A watched car that finishes: seconds before the view moves on to the
## next car still racing.
const SPEC_MOVE_ON_S := 5.0

var _spectating := false
var _spec_car := -1
var _spec_view := SpecView.FOLLOW
var _spec_done_for := 0.0       ## how long the watched car has been home
var _finish_tick := -1         ## sim tick this player's car finished (or retired)
var _live_results := false      ## the results are up (or one key away) while cars are still racing
var _live_count := -1           ## cars home (finished or out) when the live table was last built
var _live_since := 0.0
var _end_waiting := Callable()  ## the race ended while this player was driving after the line
var _cooldown_ai: AIDriver = null
var _penalties: Array = []      ## every penalty in the race {car, seconds, reason} (race events)
var _onboard: OnboardCamera = null
var _onboard_rect: TextureRect
var _tv_car := -1


## The car this player drives, or the car whose crew they're in (-1 none).
func _own_car() -> int:
	return session.local_car if session.local_car >= 0 else session.team_car


func _update_spectator(delta: float) -> void:
	var sim := session.sim
	if _results_shown:
		return
	if _end_waiting.is_valid():
		# The race ended while this player was still driving after the line.
		if _own_drive_left() <= 0.0:
			var f := _end_waiting
			_end_waiting = Callable()
			f.call()
		return
	if _live_results and results.visible:
		_update_live_results(delta)
		return
	if not _spectating and not _live_results:
		var me := _own_car()
		if me < 0 or sim.phase == RaceSim.Phase.FINISHED:
			return
		var e := sim.entries[me]
		if not (e.finished or e.dnf):
			return
		_note_finish()
		if GameData.arg("spectate-now"):
			_start_spectating()
		elif _own_drive_left() <= 0.0:
			_show_live_results()
		return
	if not _spectating:
		return
	# Spectating: the controls, and moving on from a car that's home.
	if not (pause_menu.visible or pit_wall.visible or planner.visible or hud.editing):
		if Input.is_action_just_pressed("steer_right"):
			_spec_step(1)
		elif Input.is_action_just_pressed("steer_left"):
			_spec_step(-1)
		if Input.is_action_just_pressed("camera_toggle"):
			_spec_next_view()
		if Input.is_action_just_pressed("handbrake"):
			_spec_watch(_own_car())
		if Input.is_action_just_pressed("hud_tower") and not GameData.arg("spectate-shots"):
			_show_live_results()
			return
	var w := sim.entries[_spec_car]
	if (w.finished or w.dnf) and _spec_car != _own_car() and not _shots_busy:
		_spec_done_for += delta
		var racing := ResultsTable.still_racing(sim)
		if _spec_done_for >= SPEC_MOVE_ON_S and not racing.is_empty():
			_spec_watch(racing[0])
	else:
		_spec_done_for = 0.0


## Remembers when this player's car (or crew car) finished or retired.
func _note_finish() -> void:
	var me := _own_car()
	if _finish_tick >= 0 or me < 0:
		return
	var e := session.sim.entries[me]
	if e.finished or e.dnf:
		_finish_tick = session.sim.tick


## Seconds left before the results come up after this player's car is home:
## FINISH_DRIVE_S after the flag (driving it, or watching it if crewing),
## SPECTATE_DELAY_S after retiring. 0 = none left (or not home yet).
func _own_drive_left() -> float:
	var me := _own_car()
	if me < 0 or _finish_tick < 0 or GameData.arg("spectate-now"):
		return 0.0
	var e := session.sim.entries[me]
	var wait := FINISH_DRIVE_S if e.finished else SPECTATE_DELAY_S
	return maxf(wait - (session.sim.tick - _finish_tick) * RaceSim.TICK_DT, 0.0)


## True while this player still drives their own car after the flag.
func _free_drive() -> bool:
	var me := session.local_car
	return me >= 0 and session.sim.entries[me].finished and _own_drive_left() > 0.0


## The results come up while the race runs on: the cars home so far, the
## ones still out dimmed below, filling up as each crosses the line.
func _show_live_results() -> void:
	_live_results = true
	_stop_spectating()
	hud.visible = false
	crew.visible = false
	driver_radio.close()
	crew.radio.close()
	race_audio.fade_out(RESULTS_SOUND_FADE_S)
	var d := _live_data()
	_live_count = _home_count()
	_live_since = 0.0
	results.show_results(d, _live_opts())
	Sound.wire_buttons(results)
	_live_shot()
	var racing := ResultsTable.still_racing(session.sim)
	print("[results] live table up for %s, %d home, %d still racing" % [Net.local_name, _live_count, racing.size()])


func _home_count() -> int:
	var n := 0
	for e in session.sim.entries:
		if e.finished or e.dnf:
			n += 1
	return n


func _live_data() -> Dictionary:
	var season_info: Dictionary = session.start_data.get("season", {})
	return ResultsTable.build(session.sim, session.telemetry, {"me": _own_car(), "penalties": _penalties,
		"single_race_points": season_info.is_empty()})


func _live_opts() -> Dictionary:
	var racing := ResultsTable.still_racing(session.sim).size()
	var notes := ["%d car%s still racing  ·  the table fills up as they cross the line" % [racing, "" if racing == 1 else "s"]
		if racing > 0 else "Every car is home"]
	var buttons := [["watch", "Watch the race"]]
	if session.mode == RaceSession.Mode.OFFLINE and not session.start_data.has("season"):
		buttons.append(["menu", "Main menu"])
	elif session.mode == RaceSession.Mode.CLIENT:
		buttons.append(["leave", "Leave"])
	var me := _own_car()
	if me >= 0 and not session.sim.settings.is_qualifying():
		var e := session.sim.entries[me]
		var pos := session.sim.running_order.find(me)
		notes.push_front("You finished P%d" % (pos + 1) if e.finished else "You didn't finish")
	return {"title": "QUALIFYING" if session.sim.settings.is_qualifying() else "RESULTS", "subtitle": "",
		"buttons": buttons, "notes": notes, "instant": bool(GameData.arg("results-instant", false))}


## Live table: rebuilt each time another car is home.
func _update_live_results(delta: float) -> void:
	_live_since += delta
	if _results_shown:
		return
	var n := _home_count()
	if n != _live_count and _live_since >= 0.2:
		_live_count = n
		_live_since = 0.0
		results.update_results(_live_data(), _live_opts())
		_live_shot()
		if DisplayServer.get_name() == "headless":
			print("[results] live table: %d home" % n)
	if Input.is_action_just_pressed("hud_tower") and results.is_shown() and not results.is_driver_open():
		_watch_race()


var _live_shots := 0


## Testing: --live-shots DIR saves the live results each time they change
## (live_0.png, live_1.png, ...), then the final table (live_final.png).
func _live_shot(final := false) -> void:
	if not GameData.arg("live-shots") or DisplayServer.get_name() == "headless":
		return
	var dir := str(GameData.arg("live-shots"))
	DirAccess.make_dir_recursive_absolute(dir)
	var n := _live_shots
	_live_shots += 1
	while not results.is_shown():
		await get_tree().process_frame
	for _k in 30:
		await get_tree().process_frame   # the new row's light fades a little
	await RenderingServer.frame_post_draw
	var path := "%s/live_%s.png" % [dir, "final" if final else str(n)]
	get_viewport().get_texture().get_image().save_png(path)
	print("[screenshot] %s" % path)
	if final and GameData.arg("quit-after-shots"):
		get_tree().quit()


## From the live table back to the race: spectating, with the sound back up.
func _watch_race() -> void:
	if _results_shown:
		return
	results.visible = false
	race_audio.fade_in(0.8)
	_start_spectating()


func _start_spectating() -> void:
	_spectating = true
	var racing := ResultsTable.still_racing(session.sim)
	var first: int = racing[0] if not racing.is_empty() else _own_car()
	_spec_view = clampi(int(GameData.arg("spectate-view", SpecView.FOLLOW)), 0, SPEC_VIEW_NAMES.size() - 1) as SpecView
	hud.visible = false
	crew.visible = false
	driver_radio.close()
	crew.radio.close()
	spectator.own_car = _own_car()
	spectator.visible = true
	_spec_watch(first)
	if GameData.arg("spectate-shots") and DisplayServer.get_name() != "headless":
		_spectate_shots()
	if DisplayServer.get_name() == "headless":
		print("[spectator] %s is spectating, watching %s (%d still racing)" % [Net.local_name,
			session.sim.entries[first].driver_name, racing.size()])


## Testing: --spectate-shots DIR saves a picture of every camera view once
## spectating starts, then one of the results screen.
var _shots_busy := false


func _spectate_shots() -> void:
	var dir := str(GameData.arg("spectate-shots"))
	DirAccess.make_dir_recursive_absolute(dir)
	_shots_busy = true
	var first := int(_spec_view)   # --spectate-view picks the first one
	for j in SPEC_VIEW_NAMES.size():
		var v := (first + j) % SPEC_VIEW_NAMES.size()
		_spec_view = v as SpecView
		_tv_car = -1
		spectator.watch(_spec_car, SPEC_VIEW_NAMES[_spec_view])
		for _f in 12:
			await get_tree().process_frame
		if _results_shown:
			break
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/spectate_%d.png" % [dir, v])
		print("[screenshot] spectator view %s" % SPEC_VIEW_NAMES[v])
	_shots_busy = false


func _results_shot() -> void:
	var dir := str(GameData.arg("spectate-shots"))
	while not results.is_shown():
		await get_tree().process_frame
	for _f in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/results.png" % dir)
	print("[screenshot] results")
	get_tree().quit()


func _stop_spectating() -> void:
	_spectating = false
	spectator.visible = false
	_onboard_rect.visible = false


func _spec_watch(car: int) -> void:
	if car < 0 or car >= session.sim.car_count():
		return
	_spec_car = car
	_spec_done_for = 0.0
	_tv_car = -1
	spectator.watch(car, SPEC_VIEW_NAMES[_spec_view])


func _spec_step(step: int) -> void:
	if _spectating:
		_spec_watch(ResultsTable.next_car(session.sim, _spec_car, step))


func _spec_next_view() -> void:
	if not _spectating:
		return
	_spec_view = ((_spec_view + 1) % SPEC_VIEW_NAMES.size()) as SpecView
	if _onboard == null and _spec_view in [SpecView.ONBOARD, SpecView.REAR]:
		_spec_view = SpecView.TV   # no onboard cameras on this machine
	_tv_car = -1
	spectator.watch(_spec_car, SPEC_VIEW_NAMES[_spec_view])


## The onboard views fill the screen with the watched car's roof camera.
func _update_onboard_view() -> void:
	var on := _spectating and _onboard != null and _spec_view in [SpecView.ONBOARD, SpecView.REAR]
	_onboard_rect.visible = on
	if not on:
		return
	var px := get_window().size
	_onboard.show_car(_spec_car, OnboardCamera.View.FRONT if _spec_view == SpecView.ONBOARD else OnboardCamera.View.REAR,
		Vector2i(px.x, px.y))
	if _onboard_rect.texture != _onboard.get_texture():
		_onboard_rect.texture = _onboard.get_texture()


## Trackside TV: broadcast cameras on poles round the circuit, every couple
## of hundred metres and alternating sides. The camera the car is coming up
## to follows it, panning and zooming to keep it the same size in the
## picture, and cuts to the next one once the car is past.
const TV_SPACING_M := 220.0
const TV_POLE_M := 9.0          ## camera height above the ground
const TV_FRAME_M := 14.0        ## how much of the scene the lens keeps in the picture, top to bottom
const TV_PAST_M := 60.0         ## cut to the next camera this far past the current one
var _tv_cams: Array = []        ## [{s, pos: Vector3}]
var _tv_cam := -1
var _tv_look := Vector3.ZERO
var _tv_fov := 30.0


func _build_tv_cams() -> void:
	var t := session.sim.track
	var n := maxi(6, int(t.length / TV_SPACING_M))
	for k in n:
		var s := t.length * k / n
		var side := 1.0 if k % 2 == 0 else -1.0
		var idx := int(t.project(t.position_at(s))["idx"])
		var w := maxf(t.width_left[idx], t.width_right[idx]) + minf(t.runoff * 0.5, 18.0) + 6.0
		var p := t.position_at(s, side * w)
		_tv_cams.append({"s": s, "pos": Vector3(p.x, t.ground_height_at(p) + TV_POLE_M, p.y)})


## The camera for a car at track_s: the nearest one it hasn't passed yet
## (or passed by less than TV_PAST_M).
func _tv_pick(track_s: float) -> int:
	var L := session.sim.track.length
	var best := -1
	var best_d := INF
	for k in _tv_cams.size():
		var d := wrapf(float(_tv_cams[k]["s"]) - track_s, -L * 0.5, L * 0.5)
		if d > -TV_PAST_M and d < best_d:
			best_d = d
			best = k
	return best


func _update_tv_camera(delta: float) -> void:
	if _tv_cams.is_empty():
		_build_tv_cams()
	var cv := car_views[_spec_car]
	var car_s := session.sim.cars[_spec_car].track_s
	var target := cv.global_position + Vector3(0, 0.6, 0)
	var cut := _tv_car != _spec_car or _tv_cam < 0
	if not cut:
		var L := session.sim.track.length
		var d := wrapf(float(_tv_cams[_tv_cam]["s"]) - car_s, -L * 0.5, L * 0.5)
		cut = d <= -TV_PAST_M or d > TV_SPACING_M * 2.5
	if cut:
		_tv_car = _spec_car
		_tv_cam = _tv_pick(car_s)
		_tv_look = target
	var from: Vector3 = _tv_cams[_tv_cam]["pos"]
	# A camera operator: a touch behind the car, never jerky.
	var k := 1.0 - exp(-9.0 * delta)
	_tv_look = target if cut else _tv_look.lerp(target, k)
	var dist := from.distance_to(_tv_look)
	var want := rad_to_deg(2.0 * atan(TV_FRAME_M * 0.5 / maxf(dist, 1.0)))
	_tv_fov = clampf(want if cut else lerpf(_tv_fov, want, k), 3.0, 55.0)
	world.set_camera_view(from, _tv_look, _tv_fov)


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
