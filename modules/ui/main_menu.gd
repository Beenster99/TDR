extends Control
## Main menu + multiplayer lobby, built in code. Every control is reachable
## with a controller: D-pad/left stick moves focus, A selects, B goes back,
## left/right changes Stepper values.
##
## Command line (after "--"):
##   --server [--port 24690] [--laps 3] [--ai 4] [--min-players 1]   dedicated server
##   --host / --join 127.0.0.1 [--port 7777] [--name Bob]            skip the menu
##   --single [--laps 1] [--ai 3] [--car id]                         skip to a race
##   --track id  --class GT3|Road|multi|open                         pick track / car class
##   --autodrive --ready --quit-after-race --time-scale 3            test bots
##   --resume-season id|latest  --menu-page season_new  --menu-shot out.png   (screenshots)
##   --season 2 [--qualifying driven|simulated|off] [--points f1]     a quick season of N rounds
##        at --track (with --single or --server); --quit-after-season ends when it's done
##   race options: --weather heavy_rain --weather-changes --time 20 --clock-speed 60 --grid reversed
##                 --damage off|visual|full


var pages := {}
var current_page := ""
var name_edit: LineEdit
var address_edit: LineEdit
var status_label: Label
var car_stepper: Stepper
var class_stepper: Stepper
var track_stepper: Stepper
var laps_stepper: Stepper
var ai_stepper: Stepper
var tyre_stepper: Stepper
var tod_stepper: Stepper
var clock_stepper: Stepper
var weather_stepper: Stepper
var weather_change_stepper: Stepper
var grid_stepper: Stepper
var difficulty_stepper: Stepper
var fuel_stepper: Stepper
var wear_stepper: Stepper
var stops_stepper: Stepper
var safety_car_stepper: Stepper
var damage_stepper: Stepper
var lobby_list: VBoxContainer
var lobby_title: Label
var join_info_label: Label
var ready_button: Button
var start_button: Button
var lobby_settings_box: GridContainer
var lobby_season_label: Label
var _settings_steppers: Array[Stepper] = []
var help_label: Label
# Seasons
var season_name_edit: LineEdit
var points_stepper: Stepper
var custom_points_edit: LineEdit
var pole_stepper: Stepper
var fastest_lap_stepper: Stepper
var quali_stepper: Stepper
var calendar_label: Label
var draft_rounds: Array = []
var season_list_box: VBoxContainer
var hub_title: Label
var hub_info: Label
var hub_drivers: Label
var hub_teams: Label
var hub_news: Label
var hub_start_button: Button
var hub_host_button: Button
var hub_next_button: Button
## Pages where the season decides the class and the track.
const SEASON_PAGES := ["season_list", "season_hub"]


var _building := false


func _ready() -> void:
	_building = true
	_build_ui()
	_building = false
	Net.lobby_changed.connect(_refresh_lobby)
	# Named methods (not lambdas) so the connections die with this scene.
	Net.connection_failed.connect(_on_net_error)
	Net.disconnected.connect(_on_net_error)
	Net.race_started.connect(_on_race_started)
	Net.internet_status_changed.connect(_refresh_lobby)
	if Net.is_online():
		_show("lobby")
		_refresh_lobby()
	elif GameData.season != null:
		_show("season_hub")
	else:
		_show("main")
	_handle_cmdline()


func _on_net_error(reason: String) -> void:
	_show("season_hub" if GameData.season != null else "main")
	_status(reason)


func _on_race_started(_start_data: Dictionary) -> void:
	get_tree().change_scene_to_file(GameData.SCENE_RACE)


func _handle_cmdline() -> void:
	var port := int(GameData.arg("port", Net.DEFAULT_PORT))
	if GameData.arg("name"):
		name_edit.text = str(GameData.arg("name"))
		GameData.prefs["name"] = name_edit.text
	if Net.is_online():
		return
	laps_stepper.set_value(int(GameData.arg("laps", laps_stepper.value)))
	ai_stepper.set_value(int(GameData.arg("ai", ai_stepper.value)))
	if GameData.arg("track") and _track_info(str(GameData.arg("track"))):
		track_stepper.set_value(str(GameData.arg("track")))
	if GameData.arg("class"):
		var cls := str(GameData.arg("class"))
		class_stepper.set_value("" if cls == "open" else cls)
		_rebuild_car_options()
	tod_stepper.set_value(int(GameData.arg("time", tod_stepper.value)))
	if GameData.arg("clock-speed"):
		clock_stepper.set_value(int(GameData.arg("clock-speed")))
	if GameData.arg("weather"):
		weather_stepper.set_value(str(GameData.arg("weather")))
	if GameData.arg("weather-changes"):
		weather_change_stepper.set_value(true)
	if GameData.arg("grid"):
		grid_stepper.set_value(str(GameData.arg("grid")))
	if GameData.arg("fuel"):
		fuel_stepper.set_value(float(GameData.arg("fuel")))
	if GameData.arg("tyre-wear"):
		wear_stepper.set_value(float(GameData.arg("tyre-wear")))
	if GameData.arg("pit-stops"):
		stops_stepper.set_value(int(GameData.arg("pit-stops")))
	if GameData.arg("safety-car"):
		safety_car_stepper.set_value(str(GameData.arg("safety-car")) != "off")
	if GameData.arg("damage"):
		damage_stepper.set_value(str(GameData.arg("damage")))
	if GameData.arg("tyres"):
		tyre_stepper.set_value(str(GameData.arg("tyres")))
	if GameData.arg("car") and GameData.cars.has(GameData.arg("car")):
		if not GameData.arg("class"):
			class_stepper.set_value(RaceSettings.CLASS_MULTI)
			_rebuild_car_options()
		car_stepper.set_value(GameData.arg("car"))
		GameData.prefs["car_id"] = car_stepper.value
	if GameData.arg("resume-season") and GameData.season == null:
		var saved := SeasonStore.list()
		var want := str(GameData.arg("resume-season"))
		for info in saved:
			if info["id"] == want or (want == "latest" and info == saved[0]):
				_resume_season(info["id"])
	if GameData.arg("menu-page"):
		_show(str(GameData.arg("menu-page")))
	if GameData.arg("menu-shot"):
		_menu_shot.call_deferred(str(GameData.arg("menu-shot")))
	if GameData.arg("single") and GameData.arg("season"):
		if GameData.season == null:
			GameData.season = _cmdline_season(_settings_from_ui())
		_on_season_start.call_deferred()
	elif GameData.arg("single"):
		_on_single.call_deferred()
	elif GameData.arg("server"):
		var s := _settings_from_ui()
		if Net.host(port, "Server", true) == OK:
			if GameData.arg("season"):
				var season := _cmdline_season(s)
				GameData.season = season
				Net.start_planner = season.plan_for_lobby
				Net.set_settings(season.settings_for_next())
				Net.set_season_info(season.summary())
			else:
				Net.set_settings(s)
			print("[server] listening on port %d" % port)
			_show("lobby")
	elif GameData.arg("host"):
		_on_host()
	elif GameData.arg("join"):
		address_edit.text = str(GameData.arg("join")) if GameData.arg("join") is String else "127.0.0.1"
		_on_join()


func _process(_dt: float) -> void:
	# Dedicated server auto-starts once enough players are ready.
	if Net.is_server() and Net.dedicated and not Net.in_race:
		if Net.players.size() >= int(GameData.arg("min-players", 1)) and Net.all_ready():
			_ready_all_check()


var _start_timer := -1.0


func _ready_all_check() -> void:
	if _start_timer < 0.0:
		_start_timer = Time.get_ticks_msec() / 1000.0
	elif Time.get_ticks_msec() / 1000.0 - _start_timer > 2.0:
		_start_timer = -1.0
		print("[server] starting race with %d player(s)" % Net.players.size())
		Net.start_race()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		match current_page:
			"single", "join", "season_list": _show("main")
			"season_new": _show("season_list")
			"season_hub": _leave_season()
			"lobby": _on_leave()


# --- UI construction -----------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.11, 0.1)
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	# Scrolls when a page is taller than the window (season set-up); the
	# focused control is always kept in view, so a controller never gets lost.
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(PRESET_FULL_RECT)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = SIZE_EXPAND_FILL
	center.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.add_child(center)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	center.add_child(root)
	var title := Label.new()
	title.text = "TOP DOWN RACER"
	title.add_theme_font_size_override("font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)
	var sub := Label.new()
	sub.text = "%d cars  ·  %d circuits  ·  version %s  ·  keyboard or controller" % [GameData.cars.size(),
		GameData.tracks.size(), ProjectSettings.get_setting("application/config/version", "dev")]
	sub.modulate = Color(1, 1, 1, 0.6)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(sub)

	# Shared: player name + car.
	name_edit = LineEdit.new()
	# The name is who you are in a season, so it stays the same between races.
	if not GameData.prefs.has("name"):
		GameData.prefs["name"] = "Driver %d" % (randi() % 900 + 100)
	name_edit.text = GameData.prefs["name"]
	name_edit.text_changed.connect(func(t): GameData.prefs["name"] = t)
	name_edit.placeholder_text = "Your name"
	name_edit.custom_minimum_size = Vector2(420, 40)
	root.add_child(name_edit)
	# Class (host setting), then car (yours), then track (host setting).
	var class_opts := []
	for c in CarCatalog.classes(GameData.cars):
		class_opts.append([c, "%s  (%d cars)" % [c, CarCatalog.ids_in_class(GameData.cars, c).size()]])
	class_opts.append([RaceSettings.CLASS_MULTI, "Multi-class (all cars)"])
	class_opts.append(["", "Open (AI match the players)"])
	var default_class: String = "GT3" if CarCatalog.ids_in_class(GameData.cars, "GT3").size() > 0 else class_opts[0][0]
	class_stepper = Stepper.choice("Class", class_opts, default_class)
	class_stepper.value_changed.connect(func(_v): _rebuild_car_options(); _push_settings())
	root.add_child(class_stepper)
	car_stepper = Stepper.choice("Car", [], "")
	car_stepper.value_changed.connect(func(v):
		GameData.prefs["car_id"] = v
		if Net.is_online(): Net.update_me({"car_id": v}))
	root.add_child(car_stepper)
	_rebuild_car_options()
	var help_stepper := Stepper.choice("Driving help", [[2, "Full (stability, traction, ABS)"],
		[1, "Some (traction, ABS)"], [0, "Off"]], GameData.prefs["driving_help"])
	help_stepper.value_changed.connect(func(v): GameData.prefs["driving_help"] = v)
	root.add_child(help_stepper)
	var track_opts := []
	for t in GameData.tracks:
		track_opts.append([t["id"], "%s  (%.1f km, %s)" % [t["name"], t["length_m"] / 1000.0, t["location"]]])
	var default_track: String = "mugello" if _track_info("mugello") else track_opts[0][0]
	track_stepper = Stepper.choice("Track", track_opts, default_track)
	track_stepper.value_changed.connect(func(_v): _push_settings())
	root.add_child(track_stepper)
	tyre_stepper = Stepper.choice("Tyres", [["auto", "Auto (suit the weather)"], ["dry", "Dry"],
		["intermediate", "Intermediate"], ["wet", "Full wet"]], "auto")
	tyre_stepper.value_changed.connect(func(v): if Net.is_online(): Net.update_me({"tyre": v}))
	root.add_child(tyre_stepper)

	# Main page
	var main := _page(root, "main")
	_button(main, "Single race", func(): _show("single"))
	_button(main, "Season / championship", func(): _show("season_list"))
	_button(main, "Host online race", _on_host)
	_button(main, "Join online race", func(): _show("join"))
	_button(main, "Quit", func(): get_tree().quit())

	# Race settings (single player page and host lobby share the values)
	laps_stepper = Stepper.numeric("Laps", 1, 50, 1, 3)
	ai_stepper = Stepper.numeric("AI drivers", 0, 24, 1, 5)
	difficulty_stepper = Stepper.choice("AI difficulty", [[0.25, "Rookie"], [0.5, "Amateur"], [0.75, "Pro"],
		[0.9, "Expert"], [1.0, "Alien"]], 0.75)
	tod_stepper = Stepper.numeric("Start time", 0, 23, 1, 14, ":00")
	clock_stepper = Stepper.choice("Clock speed", [[1, "Real time"], [2, "2x"], [5, "5x"], [10, "10x"],
		[30, "30x"], [60, "60x (1 min = 1 h)"], [0, "Frozen"]], 1)
	var weathers := []
	for w in SimEnvironment.WEATHERS + ["random"]:
		weathers.append([w, SimEnvironment.weather_name(w)])
	weather_stepper = Stepper.choice("Weather", weathers, "dry")
	weather_change_stepper = Stepper.choice("Weather changes", [[false, "No, stays the same"], [true, "Yes, can change"]], false)
	grid_stepper = Stepper.choice("Grid order", [["standard", "AI ahead, players behind"], ["random", "Random"],
		["reversed", "Reversed (fastest at back)"]], "standard")
	var rates := [[0.0, "Off"], [1.0, "Real"], [2.0, "2x"], [3.0, "3x"], [5.0, "5x"]]
	fuel_stepper = Stepper.choice("Fuel use", rates, 0.0)
	wear_stepper = Stepper.choice("Tyre wear", rates, 0.0)
	stops_stepper = Stepper.numeric("Mandatory pit stops", 0, 3, 1, 0)
	safety_car_stepper = Stepper.choice("Safety car", [[true, "On (yellows, VSC and safety car)"], [false, "Off (yellow flags only)"]], true)
	damage_stepper = Stepper.choice("Damage", [["off", "Off"], ["visual", "Visual only"],
		["full", "Full (affects the car)"]], "full")
	_settings_steppers = [laps_stepper, ai_stepper, difficulty_stepper, tod_stepper, clock_stepper, weather_stepper,
		weather_change_stepper, grid_stepper, damage_stepper, safety_car_stepper, fuel_stepper, wear_stepper, stops_stepper]

	var single := _page(root, "single")
	var single_settings := _settings_grid()
	single.add_child(single_settings)
	_button(single, "Start race", _on_single)
	_button(single, "Back", func(): _show("main"))
	single.set_meta("settings_box", single_settings)

	_build_season_pages(root)

	var join := _page(root, "join")
	address_edit = LineEdit.new()
	address_edit.text = "127.0.0.1"
	address_edit.placeholder_text = "Host address, e.g. 81.2.3.4 or 81.2.3.4:24690"
	address_edit.custom_minimum_size = Vector2(420, 40)
	join.add_child(address_edit)
	_button(join, "Connect", _on_join)
	_button(join, "Back", func(): _show("main"))

	var lobby := _page(root, "lobby")
	lobby_title = Label.new()
	lobby.add_child(lobby_title)
	lobby_list = VBoxContainer.new()
	lobby.add_child(lobby_list)
	join_info_label = Label.new()
	join_info_label.modulate = Color(0.75, 0.9, 1)
	join_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	join_info_label.custom_minimum_size = Vector2(420, 0)
	lobby.add_child(join_info_label)
	lobby_season_label = Label.new()
	lobby_season_label.add_theme_font_override("font", _mono())
	lobby_season_label.add_theme_font_size_override("font_size", 14)
	lobby_season_label.modulate = Color(1, 0.95, 0.75)
	lobby.add_child(lobby_season_label)
	lobby_settings_box = _settings_grid()
	lobby.add_child(lobby_settings_box)
	ready_button = _button(lobby, "Ready", func(): Net.update_me({"ready": not _my_ready()}))
	start_button = _button(lobby, "Start race", _on_start_online)
	_button(lobby, "Leave", _on_leave)

	for s in _settings_steppers:
		s.value_changed.connect(func(_v): _push_settings())

	status_label = Label.new()
	status_label.modulate = Color(1, 0.75, 0.4)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(status_label)
	var help := Label.new()
	help_label = help
	help.text = "Drive: W/S/A/D or arrows  ·  Pad: RT throttle, LT brake, left stick steer\nZoom (hold): Q/E or mouse wheel, Z whole track  ·  Pad: LB/RB or right stick, R3 whole track  ·  C/Y camera  ·  R/Back restart  ·  Esc/Start menu\nPits: B or D-pad left box this lap  ·  L or L3 pit limiter  ·  T or pad B next tyres  ·  F next fuel"
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.modulate = Color(1, 1, 1, 0.45)
	help.add_theme_font_size_override("font_size", 13)
	root.add_child(help)


## Race settings sit in two columns so the page fits on screen; D-pad moves between them.
func _settings_grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 4)
	return g


func _page(parent: Node, id: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	parent.add_child(v)
	pages[id] = v
	return v


func _button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(420, 44)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _show(id: String) -> void:
	Sound.wire_buttons(self)
	current_page = id
	if id != "lobby":  # host-only settings are editable again off-line
		class_stepper.disabled = false
		track_stepper.disabled = false
		for st in _settings_steppers:
			st.disabled = false
	for k in pages:
		pages[k].visible = k == id
	# In a season the season picks the class and each round's track.
	class_stepper.visible = not id in SEASON_PAGES
	track_stepper.visible = not id in SEASON_PAGES
	help_label.visible = id != "season_new"
	if id == "season_hub":
		_refresh_hub()
	elif id == "season_list":
		_refresh_season_list()
	elif id == "season_new":
		_refresh_calendar()
	# Settings steppers live on whichever page needs them.
	var box: Node = pages[id].get_meta("settings_box") if pages[id].has_meta("settings_box") else lobby_settings_box
	for s in _settings_steppers:
		if s.get_parent() != box:
			if s.get_parent():
				s.get_parent().remove_child(s)
			box.add_child(s)
	_status("")
	_focus_first.call_deferred(pages[id])


func _focus_first(page: Control) -> void:
	for c in page.find_children("*", "BaseButton", true, false):
		if c.is_visible_in_tree() and not c.disabled:
			c.grab_focus()
			return


func _status(t: String) -> void:
	status_label.text = t


## Car list for the chosen class (all cars for multi-class / open). Keeps
## the current car if it's still allowed.
func _rebuild_car_options() -> void:
	var cls: String = class_stepper.value
	var fixed: bool = cls != "" and cls != RaceSettings.CLASS_MULTI
	var opts := []
	for id in CarCatalog.ids_in_class(GameData.cars, cls if fixed else ""):
		var c: CarDefinition = GameData.cars[id]
		opts.append([id, "%s  (%s, %.0f kW, %.0f kg)" % [c.display_name, c.class_tag, c.peak_power_kw(), c.mass]])
	car_stepper.options = opts
	var keep := false
	for o in opts:
		keep = keep or o[0] == car_stepper.value
	if not keep and not opts.is_empty():
		# Back from a race the menu is rebuilt: keep the car you last chose.
		var pick: String = opts[0][0]
		for o in opts:
			if o[0] == GameData.prefs.get("car_id", ""):
				pick = o[0]
		car_stepper.set_value(pick)
		if Net.is_online() and not _building:  # online, the lobby already knows our car
			Net.update_me({"car_id": car_stepper.value})
	else:
		car_stepper.set_value(car_stepper.value)


func _track_info(id: String) -> Dictionary:
	for t in GameData.tracks:
		if t["id"] == id:
			return t
	return {}


func _settings_from_ui() -> RaceSettings:
	var s := RaceSettings.new()
	s.track_id = track_stepper.value
	s.car_class = class_stepper.value
	s.laps = int(laps_stepper.value)
	s.ai_count = int(ai_stepper.value)
	s.ai_difficulty = float(difficulty_stepper.value)
	s.environment = {"time_of_day_h": float(tod_stepper.value), "time_scale": float(clock_stepper.value),
		"weather": str(weather_stepper.value), "weather_changes": bool(weather_change_stepper.value)}
	s.grid_order = str(grid_stepper.value)
	s.fuel_rate = float(fuel_stepper.value)
	s.fuel_enabled = s.fuel_rate > 0.0
	s.tyre_wear_rate = float(wear_stepper.value)
	s.tyre_wear_enabled = s.tyre_wear_rate > 0.0
	s.mandatory_pit_stops = int(stops_stepper.value)
	s.safety_car_enabled = bool(safety_car_stepper.value)
	s.set_damage_level(str(damage_stepper.value))
	return s


# --- Actions --------------------------------------------------------------

func _on_single() -> void:
	var s := _settings_from_ui()
	s.seed = randi()
	var humans := [{"name": name_edit.text, "car_id": car_stepper.value, "tyre": tyre_stepper.value,
		"crew": [{"peer_id": 0, "name": name_edit.text, "role": RaceEntry.ROLE_DRIVER}]}]
	var start := RaceFactory.plan(s, humans, GameData.cars, GameData.drivers)
	GameData.active_session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	get_tree().change_scene_to_file(GameData.SCENE_RACE)


func _on_host() -> void:
	var port := int(GameData.arg("port", Net.DEFAULT_PORT))
	var err := Net.host(port, name_edit.text)
	if err != OK:
		_status("Could not host on port %d (error %d)." % [port, err])
		return
	Net.update_me({"car_id": car_stepper.value, "tyre": tyre_stepper.value})
	Net.set_settings(_settings_from_ui())
	_show("lobby")


func _on_join() -> void:
	var port := int(GameData.arg("port", Net.DEFAULT_PORT))
	var err := Net.join(address_edit.text, port, name_edit.text, car_stepper.value)
	if err != OK:
		_status("Could not connect (error %d)." % err)
		return
	_show("lobby")
	var where := Net.parse_address(address_edit.text, port)
	_status("Connecting to %s:%d ..." % [where["host"], where["port"]])


func _on_start_online() -> void:
	if not Net.all_ready():
		_status("Waiting for everyone to be ready.")
		return
	Net.start_race()


func _on_leave() -> void:
	Net.leave()
	_show("season_hub" if GameData.season != null else "main")


func _push_settings() -> void:
	if Net.is_server() and Net.season_info.is_empty():  # in a season, the season sets the race
		Net.set_settings(_settings_from_ui())


func _my_ready() -> bool:
	return Net.players.get(Net.my_id(), {}).get("ready", false)


func _refresh_lobby() -> void:
	if not Net.is_online():
		return
	if current_page != "lobby":
		_show("lobby")
	var me := Net.my_id()
	if Net.players.has(me):
		_status("")
		var my_car: String = Net.players[me]["car_id"]
		if my_car != car_stepper.value:
			car_stepper.set_value(my_car)
		var my_tyre: String = Net.players[me].get("tyre", "auto")
		if my_tyre != tyre_stepper.value:
			if my_tyre == "auto" and tyre_stepper.value != "auto":
				Net.update_me({"tyre": tyre_stepper.value})  # just joined: send my choice
			else:
				tyre_stepper.set_value(my_tyre)
	if GameData.arg("ready") and Net.players.has(me) and not _my_ready():
		Net.update_me({"ready": true})
	var env_s := Net.settings.environment
	lobby_title.text = ("Hosting" if Net.is_server() else "Lobby") + "  ·  %d player(s)  ·  %s, %d laps, %d AI  ·  %s, %02d:00" % [
		Net.players.size(), _track_info(Net.settings.track_id).get("short_name", Net.settings.track_id),
		Net.settings.laps, Net.settings.ai_count,
		SimEnvironment.weather_name(env_s.get("weather", "dry")), int(env_s.get("time_of_day_h", 14))]
	for c in lobby_list.get_children():
		c.queue_free()
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		var p: Dictionary = Net.players[id]
		var l := Label.new()
		var car: CarDefinition = GameData.cars.get(p["car_id"])
		var tyre_name: String = {"auto": "", "dry": "  ·  dry tyres", "intermediate": "  ·  inters", "wet": "  ·  wets"}.get(p.get("tyre", "auto"), "")
		l.text = "%s %s  ·  %s%s%s" % ["★" if id == 1 else "•", p["name"], car.display_name if car else p["car_id"], tyre_name,
			"" if id == 1 else ("  ·  READY" if p["ready"] else "  ·  not ready")]
		lobby_list.add_child(l)
	var host := Net.is_server()
	var in_season := not Net.season_info.is_empty()
	for s in _settings_steppers:
		s.disabled = not host or in_season
	class_stepper.disabled = not host or in_season
	track_stepper.disabled = not host or in_season
	lobby_season_label.visible = in_season
	if in_season:
		lobby_season_label.text = _season_info_text(Net.season_info)
	if not host or in_season:
		if _track_info(Net.settings.track_id):
			track_stepper.set_value(Net.settings.track_id)
		if class_stepper.value != Net.settings.car_class:
			class_stepper.set_value(Net.settings.car_class)
			_rebuild_car_options()
		laps_stepper.set_value(Net.settings.laps)
		ai_stepper.set_value(Net.settings.ai_count)
		difficulty_stepper.set_value(Net.settings.ai_difficulty)
		var env := Net.settings.environment
		tod_stepper.set_value(int(env.get("time_of_day_h", 14)))
		clock_stepper.set_value(int(env.get("time_scale", 1)))
		weather_stepper.set_value(str(env.get("weather", "dry")))
		weather_change_stepper.set_value(bool(env.get("weather_changes", false)))
		grid_stepper.set_value(Net.settings.grid_order)
		fuel_stepper.set_value(Net.settings.fuel_rate if Net.settings.fuel_enabled else 0.0)
		wear_stepper.set_value(Net.settings.tyre_wear_rate if Net.settings.tyre_wear_enabled else 0.0)
		stops_stepper.set_value(Net.settings.mandatory_pit_stops)
		safety_car_stepper.set_value(Net.settings.safety_car_enabled)
		damage_stepper.set_value(Net.settings.effective_damage_level())
	join_info_label.visible = host and not Net.dedicated
	if join_info_label.visible:
		join_info_label.text = Net.join_instructions()
	ready_button.visible = not host
	ready_button.text = "Not ready" if _my_ready() else "Ready"
	start_button.visible = host and not Net.dedicated
	start_button.disabled = in_season and Net.season_info.get("complete", false)
	start_button.text = "Start race"
	if in_season:
		start_button.text = "Season finished" if Net.season_info.get("complete", false) else \
			("Start qualifying" if Net.season_info.get("next_session", "") == "qualifying" else "Start race")



# --- Seasons ------------------------------------------------------------------

static func _mono() -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["DejaVu Sans Mono", "Consolas", "Menlo", "Courier New", "monospace"])
	return f


func _track_name(id: String) -> String:
	var t := _track_info(id)
	return t.get("short_name", t.get("name", id)) if not t.is_empty() else id


func _build_season_pages(root: Node) -> void:
	# Saved seasons: resume one, or start a new one.
	var list := _page(root, "season_list")
	var head := Label.new()
	head.text = "SEASONS  ·  build a calendar, race every round, win the championship"
	list.add_child(head)
	season_list_box = VBoxContainer.new()
	season_list_box.add_theme_constant_override("separation", 6)
	list.add_child(season_list_box)
	_button(list, "New season", func(): _show("season_new"))
	_button(list, "Back", func(): _show("main"))

	# New season: rules, calendar, and the race settings every round shares.
	var new_page := _page(root, "season_new")
	season_name_edit = LineEdit.new()
	season_name_edit.text = "Championship"
	season_name_edit.placeholder_text = "Season name"
	season_name_edit.custom_minimum_size = Vector2(420, 40)
	new_page.add_child(season_name_edit)
	var rules := _settings_grid()
	new_page.add_child(rules)
	var presets := []
	for id in PointsSystem.PRESET_ORDER:
		presets.append([id, PointsSystem.PRESETS[id]["name"]])
	points_stepper = Stepper.choice("Points", presets, "f1")
	points_stepper.value_changed.connect(func(v): custom_points_edit.visible = v == "custom")
	rules.add_child(points_stepper)
	quali_stepper = Stepper.choice("Qualifying", [[Season.QUALI_DRIVEN, "Driven (%d-lap session)" % Season.QUALI_LAPS],
		[Season.QUALI_SIMULATED, "Quick (worked out, no session)"], [Season.QUALI_OFF, "Off (use Grid order)"]], Season.QUALI_DRIVEN)
	rules.add_child(quali_stepper)
	pole_stepper = Stepper.choice("Pole position", [[0, "No bonus"], [1, "+1 point"], [3, "+3 points"]], 0)
	rules.add_child(pole_stepper)
	fastest_lap_stepper = Stepper.choice("Fastest lap", [[0, "No bonus"], [1, "+1 point (top 10)"]], 0)
	rules.add_child(fastest_lap_stepper)
	custom_points_edit = LineEdit.new()
	custom_points_edit.placeholder_text = "Custom points by position, e.g. 30,24,20,16,12"
	custom_points_edit.text = "25,18,15,12,10,8,6,4,2,1"
	custom_points_edit.custom_minimum_size = Vector2(420, 40)
	custom_points_edit.visible = false
	new_page.add_child(custom_points_edit)
	var cal_head := Label.new()
	cal_head.text = "CALENDAR  ·  Add round uses the Track above and the Laps, Weather, Start time and Weather changes below"
	cal_head.modulate = Color(1, 1, 1, 0.7)
	new_page.add_child(cal_head)
	calendar_label = Label.new()
	calendar_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	calendar_label.custom_minimum_size = Vector2(852, 0)
	calendar_label.modulate = Color(0.85, 0.95, 1)
	new_page.add_child(calendar_label)
	var cal := _settings_grid()
	new_page.add_child(cal)
	_button(cal, "Add round", _add_round)
	_button(cal, "Remove last round", func():
		if not draft_rounds.is_empty():
			draft_rounds.pop_back()
		_refresh_calendar())
	_button(cal, "Random calendar (6 rounds)", func(): _quick_calendar(6))
	_button(cal, "Every track (%d rounds)" % GameData.tracks.size(), func(): _quick_calendar(GameData.tracks.size()))
	_button(cal, "Start season", _on_create_season)
	_button(cal, "Back", func(): _show("season_list"))
	var shared := _settings_grid()
	new_page.add_child(shared)
	new_page.set_meta("settings_box", shared)

	# Season hub: standings, the next round, play it offline or online.
	var hub := _page(root, "season_hub")
	hub_title = Label.new()
	hub_title.add_theme_font_size_override("font_size", 26)
	hub.add_child(hub_title)
	hub_info = Label.new()
	hub_info.modulate = Color(0.85, 0.95, 1)
	hub.add_child(hub_info)
	var tables := HBoxContainer.new()
	tables.add_theme_constant_override("separation", 28)
	hub.add_child(tables)
	hub_drivers = Label.new()
	hub_teams = Label.new()
	for l in [hub_drivers, hub_teams]:
		l.add_theme_font_override("font", _mono())
		l.add_theme_font_size_override("font_size", 14)
		tables.add_child(l)
	hub_news = Label.new()
	hub_news.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hub_news.custom_minimum_size = Vector2(852, 0)
	hub_news.modulate = Color(1, 0.9, 0.7)
	hub.add_child(hub_news)
	var actions := _settings_grid()
	hub.add_child(actions)
	hub_start_button = _button(actions, "Start race", _on_season_start)
	hub_host_button = _button(actions, "Host online season", _on_season_host)
	hub_next_button = _button(actions, "Start next season", _on_next_season)
	_button(actions, "Back to main menu", _leave_season)


func _refresh_season_list() -> void:
	for c in season_list_box.get_children():
		c.queue_free()
	var saved := SeasonStore.list()
	if saved.is_empty():
		var l := Label.new()
		l.text = "No saved seasons yet."
		l.modulate = Color(1, 1, 1, 0.6)
		season_list_box.add_child(l)
	for info in saved.slice(0, 8):
		var row := HBoxContainer.new()
		season_list_box.add_child(row)
		var where: String = "finished" if info["complete"] else "round %d of %d" % [info["round"] + 1, info["rounds"]]
		var b := _button(row, "Resume  %s%s  ·  %s" % [info["name"], "" if info["number"] <= 1 else " (season %d)" % info["number"], where],
			_resume_season.bind(info["id"]))
		b.custom_minimum_size = Vector2(640, 44)
		var del := _button(row, "Delete", func(): pass)
		del.custom_minimum_size = Vector2(150, 44)
		del.pressed.connect(func():
			if del.text == "Delete":
				del.text = "Sure? Press again"
			else:
				SeasonStore.delete(info["id"])
				_refresh_season_list()
				_focus_first.call_deferred(pages["season_list"]))
	Sound.wire_buttons(season_list_box)


func _resume_season(id: String) -> void:
	var s := SeasonStore.load_season(id)
	if s == null:
		_status("Could not load that season.")
		return
	GameData.season = s
	_show("season_hub")


func _round_from_ui() -> Dictionary:
	return {"track_id": track_stepper.value, "laps": int(laps_stepper.value), "weather": str(weather_stepper.value),
		"time_of_day_h": float(tod_stepper.value), "weather_changes": bool(weather_change_stepper.value)}


func _add_round() -> void:
	draft_rounds.append(_round_from_ui())
	_refresh_calendar()


## A calendar from the tracks, in a random order, using the Laps, Weather and
## Start time settings for every round.
func _quick_calendar(n: int) -> void:
	var ids := []
	for t in GameData.tracks:
		ids.append(t["id"])
	ids.shuffle()
	draft_rounds.clear()
	var r := _round_from_ui()
	for id in ids.slice(0, mini(n, ids.size())):
		var one := r.duplicate()
		one["track_id"] = id
		draft_rounds.append(one)
	_refresh_calendar()


func _round_text(i: int, r: Dictionary) -> String:
	return "%d %s %dL %s %02d:00" % [i + 1, _track_name(r["track_id"]), int(r["laps"]),
		SimEnvironment.weather_name(r.get("weather", "dry")).to_lower(), int(r.get("time_of_day_h", 14))]


func _refresh_calendar() -> void:
	if draft_rounds.is_empty():
		calendar_label.text = "No rounds yet."
		return
	var parts := []
	for i in draft_rounds.size():
		parts.append(_round_text(i, draft_rounds[i]))
	calendar_label.text = "   ·   ".join(parts)


func _on_create_season() -> void:
	if draft_rounds.is_empty():
		_status("Add at least one round to the calendar.")
		return
	var base := _settings_from_ui()
	var p := PointsSystem.from_preset(points_stepper.value, PointsSystem.parse_list(custom_points_edit.text))
	p.pole_points = int(pole_stepper.value)
	p.fastest_lap_points = int(fastest_lap_stepper.value)
	var s := Season.create(season_name_edit.text, base, draft_rounds, p, str(quali_stepper.value),
		GameData.drivers, GameData.cars, car_stepper.value, randi())
	s.created = Time.get_datetime_string_from_system()
	s.join(name_edit.text, car_stepper.value)
	SeasonStore.save(s)
	GameData.season = s
	draft_rounds = []
	_show("season_hub")


func _leave_season() -> void:
	GameData.season = null
	_show("main")


## Driver and team tables, calendar and news for the season hub.
func _refresh_hub() -> void:
	var s: Season = GameData.season
	if s == null:
		_show.call_deferred("main")
		return
	# The season's class decides which cars the player can pick.
	var cls := str(s.base_settings.get("car_class", ""))
	if class_stepper.value != cls:
		class_stepper.set_value(cls)
		_rebuild_car_options()
	hub_title.text = "%s%s" % [s.name, "" if s.number <= 1 else "  ·  season %d" % s.number]
	var champ := s.champion()
	if s.is_complete():
		hub_info.text = "Season finished.  Champion: %s (%s), %d points." % [champ.get("name", "?"), champ.get("team", ""), champ.get("points", 0)]
	else:
		var r := s.current_round()
		hub_info.text = "Round %d of %d: %s, %d laps, %s, %02d:00  ·  next: %s\nPoints: %s  ·  qualifying: %s  ·  %d AI drivers" % [
			s.round_index + 1, s.rounds.size(), _track_info(r["track_id"]).get("name", r["track_id"]), int(r["laps"]),
			SimEnvironment.weather_name(r.get("weather", "dry")).to_lower(), int(r.get("time_of_day_h", 14)),
			s.next_session(), s.points.display_name(), s.qualifying, s.roster.size()]
	var lines := ["DRIVERS                      PTS  W  POD"]
	var k := 0
	for d in s.driver_standings():
		k += 1
		if k > 25:
			break
		lines.append("%2d %s%-18s %-6s %4d %2d %3d" % [k, " " if d["is_ai"] else ">", d["name"].left(18),
			d["team"].left(6), d["points"], d["wins"], d["podiums"]])
	hub_drivers.text = "\n".join(lines)
	var right := ["TEAMS                     PTS"]
	k = 0
	for t in s.team_standings():
		k += 1
		right.append("%2d %-22s %4d" % [k, t["team"].left(22), t["points"]])
	right.append("")
	right.append("CALENDAR")
	var names := {}
	for d in s.driver_standings():
		names[d["key"]] = d["name"]
	for i in s.rounds.size():
		var r: Dictionary = s.rounds[i]
		var mark := ""
		if i < s.results.size() and not s.results[i]["classification"].is_empty():
			mark = "  won by " + str(s.results[i]["classification"][0]["name"])
		elif i == s.round_index:
			mark = "  <- next"
		right.append("%2d %-16s%s" % [i + 1, _track_name(r["track_id"]).left(16), mark])
	hub_teams.text = "\n".join(right)
	hub_news.text = "" if s.news.is_empty() or s.round_index > 0 else "Driver market: " + "  ".join(s.news)
	hub_news.visible = hub_news.text != ""
	hub_start_button.visible = not s.is_complete()
	hub_host_button.visible = not s.is_complete()
	hub_next_button.visible = s.is_complete()
	hub_start_button.text = "Start qualifying" if s.next_session() == Season.SESSION_QUALIFYING else "Start race"


func _on_season_start() -> void:
	var s: Season = GameData.season
	if s == null or s.is_complete():
		return
	var humans := [{"name": name_edit.text, "car_id": car_stepper.value, "tyre": tyre_stepper.value,
		"crew": [{"peer_id": 0, "name": name_edit.text, "role": RaceEntry.ROLE_DRIVER}]}]
	var start := s.plan_next(humans, GameData.cars, randi())
	SeasonStore.save(s)
	GameData.active_session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	get_tree().change_scene_to_file(GameData.SCENE_RACE)


## Hosts the season online: friends join as usual, the lobby shows the
## standings, and each session is planned by the season (same AI field,
## grid from qualifying). Players are matched to the season by name, so the
## same group can pick it up again another night.
func _on_season_host() -> void:
	var s: Season = GameData.season
	var port := int(GameData.arg("port", Net.DEFAULT_PORT))
	var err := Net.host(port, name_edit.text)
	if err != OK:
		_status("Could not host on port %d (error %d)." % [port, err])
		return
	Net.start_planner = s.plan_for_lobby
	Net.update_me({"car_id": car_stepper.value, "tyre": tyre_stepper.value})
	Net.set_settings(s.settings_for_next())
	Net.set_season_info(s.summary())
	_show("lobby")


func _on_next_season() -> void:
	var s: Season = GameData.season
	var n := s.next_season(randi())
	n.created = Time.get_datetime_string_from_system()
	SeasonStore.save(n)
	GameData.season = n
	_show("season_hub")


## Lobby text for a season (works on every machine, from Net.season_info).
func _season_info_text(info: Dictionary) -> String:
	var lines := []
	var head := "SEASON  %s  ·  " % info.get("name", "")
	if info.get("complete", false):
		head += "finished, champion %s" % info.get("champion", "?")
	else:
		head += "round %d of %d: %s, %d laps  ·  next: %s" % [int(info.get("round", 0)) + 1, int(info.get("rounds", 0)),
			_track_name(info.get("next_track_id", "")), int(info.get("next_laps", 0)), info.get("next_session", "race")]
	lines.append(head)
	var drivers: Array = info.get("drivers", [])
	var teams: Array = info.get("teams", [])
	for i in mini(6, maxi(drivers.size(), teams.size())):
		var dl := ""
		if i < drivers.size():
			dl = "%d %s%-18s %4d" % [i + 1, " " if drivers[i].get("is_ai", true) else ">", str(drivers[i]["name"]).left(18), int(drivers[i]["points"])]
		var tl := ""
		if i < teams.size():
			tl = "%-20s %4d" % [str(teams[i]["team"]).left(20), int(teams[i]["points"])]
		lines.append("%-28s   %s" % [dl, tl])
	return "\n".join(lines)


## --season N: a season of N rounds at the chosen track and settings (tests, servers).
func _cmdline_season(base: RaceSettings) -> Season:
	var rounds := []
	for i in maxi(int(GameData.arg("season", 1)), 1):
		rounds.append({"track_id": base.track_id, "laps": base.laps, "weather": base.environment.get("weather", "dry"),
			"time_of_day_h": base.environment.get("time_of_day_h", 14.0), "weather_changes": base.environment.get("weather_changes", false)})
	var p := PointsSystem.from_preset(str(GameData.arg("points", "f1")))
	var s := Season.create("Command line season", base, rounds, p, str(GameData.arg("qualifying", Season.QUALI_DRIVEN)),
		GameData.drivers, GameData.cars, car_stepper.value, randi())
	s.created = Time.get_datetime_string_from_system()
	SeasonStore.save(s)
	print("[season] %s: %d rounds, %d AI, qualifying %s" % [s.id, s.rounds.size(), s.roster.size(), s.qualifying])
	return s


func _menu_shot(path: String) -> void:
	for _i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[screenshot] saved")
	get_tree().quit()
