extends Control
## Main menu + multiplayer lobby, built in code. Every control is reachable
## with a controller: D-pad/left stick moves focus, A selects, B goes back,
## left/right changes Stepper values.
##
## Command line (after "--"):
##   --server [--port 24690] [--laps 3] [--ai 4] [--min-players 1]   dedicated server
##   --host / --join 127.0.0.1 [--port 7777] [--name Bob]            skip the menu
##   --single [--laps 1] [--ai 3] [--car id]                         skip to a race
##   --autodrive --ready --quit-after-race --time-scale 3            test bots
##   race options: --weather heavy_rain --weather-changes --time 20 --clock-speed 60 --grid reversed


var pages := {}
var current_page := ""
var name_edit: LineEdit
var address_edit: LineEdit
var status_label: Label
var car_stepper: Stepper
var laps_stepper: Stepper
var ai_stepper: Stepper
var tyre_stepper: Stepper
var tod_stepper: Stepper
var clock_stepper: Stepper
var weather_stepper: Stepper
var weather_change_stepper: Stepper
var grid_stepper: Stepper
var lobby_list: VBoxContainer
var lobby_title: Label
var join_info_label: Label
var ready_button: Button
var start_button: Button
var lobby_settings_box: GridContainer
var _settings_steppers: Array[Stepper] = []


func _ready() -> void:
	_build_ui()
	Net.lobby_changed.connect(_refresh_lobby)
	# Named methods (not lambdas) so the connections die with this scene.
	Net.connection_failed.connect(_on_net_error)
	Net.disconnected.connect(_on_net_error)
	Net.race_started.connect(_on_race_started)
	Net.internet_status_changed.connect(_refresh_lobby)
	if Net.is_online():
		_show("lobby")
		_refresh_lobby()
	else:
		_show("main")
	_handle_cmdline()


func _on_net_error(reason: String) -> void:
	_show("main")
	_status(reason)


func _on_race_started(_start_data: Dictionary) -> void:
	get_tree().change_scene_to_file(GameData.SCENE_RACE)


func _handle_cmdline() -> void:
	var port := int(GameData.arg("port", Net.DEFAULT_PORT))
	if GameData.arg("name"):
		name_edit.text = str(GameData.arg("name"))
	if Net.is_online():
		return
	laps_stepper.set_value(int(GameData.arg("laps", laps_stepper.value)))
	ai_stepper.set_value(int(GameData.arg("ai", ai_stepper.value)))
	tod_stepper.set_value(int(GameData.arg("time", tod_stepper.value)))
	if GameData.arg("clock-speed"):
		clock_stepper.set_value(int(GameData.arg("clock-speed")))
	if GameData.arg("weather"):
		weather_stepper.set_value(str(GameData.arg("weather")))
	if GameData.arg("weather-changes"):
		weather_change_stepper.set_value(true)
	if GameData.arg("grid"):
		grid_stepper.set_value(str(GameData.arg("grid")))
	if GameData.arg("tyres"):
		tyre_stepper.set_value(str(GameData.arg("tyres")))
	if GameData.arg("car") and GameData.cars.has(GameData.arg("car")):
		car_stepper.set_value(GameData.arg("car"))
	if GameData.arg("single"):
		_on_single.call_deferred()
	elif GameData.arg("server"):
		var s := _settings_from_ui()
		if Net.host(port, "Server", true) == OK:
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
			"single", "join": _show("main")
			"lobby": _on_leave()


# --- UI construction -----------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.11, 0.1)
	bg.set_anchors_preset(PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	center.add_child(root)
	var title := Label.new()
	title.text = "TOP DOWN RACER"
	title.add_theme_font_size_override("font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)
	var sub := Label.new()
	sub.text = "Spielberg GP Circuit  ·  version %s  ·  keyboard or controller" % ProjectSettings.get_setting("application/config/version", "dev")
	sub.modulate = Color(1, 1, 1, 0.6)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(sub)

	# Shared: player name + car.
	name_edit = LineEdit.new()
	name_edit.text = "Driver %d" % (randi() % 900 + 100)
	name_edit.placeholder_text = "Your name"
	name_edit.custom_minimum_size = Vector2(420, 40)
	root.add_child(name_edit)
	var car_opts := []
	var ids: Array = GameData.cars.keys()
	ids.sort()
	for id in ids:
		var c: CarDefinition = GameData.cars[id]
		car_opts.append([id, "%s  (%.0f kW, %.0f kg)" % [c.display_name, c.peak_power_kw(), c.mass]])
	car_stepper = Stepper.choice("Car", car_opts, ids[0])
	car_stepper.value_changed.connect(func(v): if Net.is_online(): Net.update_me({"car_id": v}))
	root.add_child(car_stepper)
	tyre_stepper = Stepper.choice("Tyres", [["auto", "Auto (suit the weather)"], ["dry", "Dry"],
		["intermediate", "Intermediate"], ["wet", "Full wet"]], "auto")
	tyre_stepper.value_changed.connect(func(v): if Net.is_online(): Net.update_me({"tyre": v}))
	root.add_child(tyre_stepper)

	# Main page
	var main := _page(root, "main")
	_button(main, "Single race", func(): _show("single"))
	_button(main, "Host online race", _on_host)
	_button(main, "Join online race", func(): _show("join"))
	_button(main, "Quit", func(): get_tree().quit())

	# Race settings (single player page and host lobby share the values)
	laps_stepper = Stepper.numeric("Laps", 1, 50, 1, 3)
	ai_stepper = Stepper.numeric("AI drivers", 0, 15, 1, 5)
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
	_settings_steppers = [laps_stepper, ai_stepper, tod_stepper, clock_stepper, weather_stepper,
		weather_change_stepper, grid_stepper]

	var single := _page(root, "single")
	var single_settings := _settings_grid()
	single.add_child(single_settings)
	_button(single, "Start race", _on_single)
	_button(single, "Back", func(): _show("main"))
	single.set_meta("settings_box", single_settings)

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
	help.text = "Drive: W/S/A/D or arrows  ·  Pad: RT throttle, LT brake, left stick steer  ·  C/Y camera  ·  R/Back restart  ·  Esc/Start menu"
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
	current_page = id
	for k in pages:
		pages[k].visible = k == id
	# Settings steppers live on whichever page needs them.
	var box: Node = pages["single"].get_meta("settings_box") if id == "single" else lobby_settings_box
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


func _settings_from_ui() -> RaceSettings:
	var s := RaceSettings.new()
	s.laps = int(laps_stepper.value)
	s.ai_count = int(ai_stepper.value)
	s.environment = {"time_of_day_h": float(tod_stepper.value), "time_scale": float(clock_stepper.value),
		"weather": str(weather_stepper.value), "weather_changes": bool(weather_change_stepper.value)}
	s.grid_order = str(grid_stepper.value)
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
	_show("main")


func _push_settings() -> void:
	if Net.is_server():
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
	lobby_title.text = ("Hosting" if Net.is_server() else "Lobby") + "  ·  %d player(s)  ·  %d laps, %d AI  ·  %s, %02d:00" % [
		Net.players.size(), Net.settings.laps, Net.settings.ai_count,
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
	for s in _settings_steppers:
		s.disabled = not host
	if not host:
		laps_stepper.set_value(Net.settings.laps)
		ai_stepper.set_value(Net.settings.ai_count)
		var env := Net.settings.environment
		tod_stepper.set_value(int(env.get("time_of_day_h", 14)))
		clock_stepper.set_value(int(env.get("time_scale", 1)))
		weather_stepper.set_value(str(env.get("weather", "dry")))
		weather_change_stepper.set_value(bool(env.get("weather_changes", false)))
		grid_stepper.set_value(Net.settings.grid_order)
	join_info_label.visible = host and not Net.dedicated
	if join_info_label.visible:
		join_info_label.text = Net.join_instructions()
	ready_button.visible = not host
	ready_button.text = "Not ready" if _my_ready() else "Ready"
	start_button.visible = host and not Net.dedicated
