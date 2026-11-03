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
##   --race-type circuit|rallycross|derby                            race type (before --track)
##   --autodrive --ready --quit-after-race --time-scale 3            test bots
##   --resume-season id|latest  --menu-page season_new  --menu-shot out.png   (screenshots)
##   --season 2 [--qualifying driven|simulated|off] [--points f1]     a quick season of N rounds
##        at --track (with --single or --server); --quit-after-season ends when it's done
##   --profile user://bob.json                                       use another team save
##   race options: --weather heavy_rain --weather-changes --time 20 --clock-speed 60 --grid reversed
##                 --damage off|visual|full  --upgrades on|bop|stock
##   --setup-screen [--menu-screenshot out.png]                     open the car setup screen
##   --open-settings gameplay|graphics|sound|garage|debug  --open-garage  --splash-shot out.png
##   --host --host-demo   (screenshots) the host changes the track, weather and laps once two guests are in


var pages := {}
var current_page := ""
var name_edit: LineEdit
var address_edit: LineEdit
var join_name_label: Label
var status_label: Label
var car_stepper: Stepper
var class_stepper: Stepper
## Race type (RaceSettings.discipline): circuit racing, rallycross ... It
## narrows the track and class lists and hides settings that don't apply.
var race_type_stepper: Stepper
const RACE_TYPE_NAMES := {"circuit": "Circuit racing", "rallycross": "Rallycross", "derby": "Demolition Derby"}
## Settings that rallycross doesn't use (no pit stops, fuel, safety car,
## shared cars or tyre choice), hidden while it's picked.
var _circuit_only: Array[Control] = []
var car_filter_stepper: Stepper   ## narrows the car list to one class (multi-class / open races)
var track_stepper: Stepper
## Settings a Demolition Derby doesn't have on top of those (damage is
## always full; no upgrades or setups), hidden while it's picked.
var _derby_hidden: Array[Control] = []
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
var drivers_stepper: Stepper
var safety_car_stepper: Stepper
var damage_stepper: Stepper
var tuning_stepper: Stepper
var setup_button: Button
var upgrades_stepper: Stepper
## This player's team (business module): money, upgrades and liveries.
var profile: TeamProfile
var _garage: GarageScreen
var _settings: SettingsScreen
var badge: ProfileBadge
var profile_info: Label
## Class, car, track, tyres and setup: shown on the pages that start a race.
var race_box: VBoxContainer
var _title_label: Label
var _menu_root: Control
var lobby_list: VBoxContainer
## Co-op crews in the lobby: one row per player with a car share and a role.
var crew_box: VBoxContainer
var _crew_rows: Dictionary = {}   ## peer id -> {"team": Stepper, "role": Stepper}
var _crew_ids: Array = []
var _cmdline_team_sent := false
var _demo_done := false
var lobby_title: Label
var join_info_label: Label
var ready_button: Button
var start_button: Button
var lobby_ready_label: Label
## Race set-up layout (see _build_ui and _layout).
const COLUMN_GAP := 20
var _margin: MarginContainer
var _root_box: VBoxContainer
var _page_title: Label
var _stripe: ColorRect
var _sub_label: Label
var _setup_row: HBoxContainer
var _cols: Array[VBoxContainer] = []
var _circuit_card: PanelContainer
var _car_card: PanelContainer
var _settings_panel: PanelContainer
var _settings_holder: VBoxContainer
var _settings_change_label: Label
var _track_map: TrackMap
var _track_title: Label
var _track_facts: Label
var _track_desc: Label
var _car_preview: CarPreview
var _car_title: Label
var _car_facts: Label
var _car_desc: Label
## What each host setting showed last time (guests: to flash what the host changed).
var _last_shown := {}
var _recent_changes := {}   ## Stepper -> {"text", "t"}: what the host changed lately
const PAGE_TITLES := {"single": "SINGLE RACE", "lobby": "ONLINE LOBBY", "season_new": "NEW SEASON",
	"season_hub": "SEASON", "season_list": "SEASONS", "join": "JOIN ONLINE RACE", "profile": "PROFILE"}
## Pages laid out in the set-up columns (the others are a plain list on the left).
const SETUP_PAGES := ["single", "lobby", "season_new", "season_hub"]
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
	if GameData.arg("profile"):
		TeamProfile.default_path = str(GameData.arg("profile"))
	profile = TeamProfile.load_or_new()
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
		# Back from an online race as the host: the rebuilt menu shows the
		# settings we raced with, not the defaults.
		if Net.is_server() and not Net.dedicated and Net.season_info.is_empty():
			_restore_race(MEMORY_HOST)
			_push_settings()
		_show("lobby")
		_refresh_lobby()
	elif GameData.season != null:
		_show("season_hub")
	else:
		_show("main")
	_handle_cmdline()
	_refresh_setup_button()


func _on_net_error(reason: String) -> void:
	_show("season_hub" if GameData.season != null else "main")
	_status(reason)


func _on_race_started(_start_data: Dictionary) -> void:
	get_tree().change_scene_to_file(GameData.SCENE_RACE)


func _handle_cmdline() -> void:
	var port := int(GameData.arg("port", Net.DEFAULT_PORT))
	if GameData.arg("name"):   # this run only: the saved driver name stays as it is
		name_edit.text = str(GameData.arg("name"))
	if Net.is_online():
		return
	laps_stepper.set_value(int(GameData.arg("laps", laps_stepper.value)))
	ai_stepper.set_value(int(GameData.arg("ai", ai_stepper.value)))
	if GameData.arg("race-type") and str(GameData.arg("race-type")) != _race_type():
		race_type_stepper.set_value(str(GameData.arg("race-type")))
		_on_race_type_changed(false)
	elif GameData.arg("track") and str(_track_info(str(GameData.arg("track"))).get("discipline", "circuit")) != _race_type():
		race_type_stepper.set_value(str(_track_info(str(GameData.arg("track")))["discipline"]))
		_on_race_type_changed(false)
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
	if GameData.arg("drivers"):
		drivers_stepper.set_value(int(GameData.arg("drivers")))
	if GameData.arg("safety-car"):
		safety_car_stepper.set_value(str(GameData.arg("safety-car")) != "off")
	if GameData.arg("damage"):
		damage_stepper.set_value(str(GameData.arg("damage")))
	if GameData.arg("upgrades"):
		upgrades_stepper.set_value(str(GameData.arg("upgrades")))
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
	if GameData.arg("open-settings"):   # --open-settings graphics (screenshots)
		_open_settings()
		var sec := str(GameData.arg("open-settings"))
		if sec in GameData.SECTIONS:
			_settings._show_section(sec)
	if GameData.arg("open-garage"):
		_open_garage()
	if GameData.arg("menu-shot"):
		_menu_shot.call_deferred(str(GameData.arg("menu-shot")))
	if GameData.arg("setup-screen"):
		_open_setup.call_deferred()
	if GameData.arg("menu-screenshot"):
		get_tree().create_timer(2.0).timeout.connect(func():
			get_viewport().get_texture().get_image().save_png(str(GameData.arg("menu-screenshot")))
			print("[screenshot] saved")
			get_tree().quit())
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
				Net.start_planner = season.plan_for_lobby.bind(GameData.cars)
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
		_on_join(false)


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
	if has_node("SetupScreen"):
		return  # the setup screen handles its own back button
	if event.is_action_pressed("ui_cancel") and _garage == null and _settings == null:
		match current_page:
			"single", "join", "season_list", "profile": _show("main")
			"season_new": _show("season_list")
			"season_hub": _leave_season()
			"lobby": _on_leave()


# --- UI construction -----------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	# Race highlights loop behind everything (or the key art).
	add_child(MenuBackground.new())
	# Scrolls when a page is taller than the window (season set-up); the
	# focused control is always kept in view, so a controller never gets lost.
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(PRESET_FULL_RECT)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	# The menu sits on the left, over the dark side of the background, so the
	# racing shows on the right. Race set-up pages use the whole width.
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = SIZE_EXPAND_FILL
	margin.size_flags_vertical = SIZE_EXPAND_FILL
	_margin = margin
	scroll.add_child(margin)
	_menu_root = scroll
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	root.size_flags_horizontal = SIZE_SHRINK_BEGIN
	margin.add_child(root)
	_root_box = root
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 22)
	root.add_child(head)
	var title := Label.new()
	title.text = "TOP DOWN RACER"
	title.add_theme_font_override("font", SplashScreen.title_font())
	title.add_theme_font_size_override("font_size", 54)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("outline_size", 8)
	head.add_child(title)
	_page_title = Label.new()
	_page_title.add_theme_font_size_override("font_size", 30)
	_page_title.add_theme_color_override("font_color", Color(0.94, 0.26, 0.2))
	_page_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_page_title.add_theme_constant_override("outline_size", 6)
	_page_title.size_flags_vertical = SIZE_SHRINK_CENTER
	head.add_child(_page_title)
	var stripe := ColorRect.new()
	stripe.color = Color(0.94, 0.26, 0.2)
	stripe.custom_minimum_size = Vector2(300, 5)
	stripe.size_flags_horizontal = SIZE_SHRINK_BEGIN
	root.add_child(stripe)
	_stripe = stripe
	var sub := Label.new()
	sub.text = "%d cars  ·  %d circuits  ·  version %s" % [GameData.cars.size(),
		GameData.tracks.size(), ProjectSettings.get_setting("application/config/version", "dev")]
	sub.modulate = Color(1, 1, 1, 0.6)
	root.add_child(sub)
	_sub_label = sub
	_title_label = title

	# The player's name lives on the profile page (top right badge).
	name_edit = LineEdit.new()
	# The name is who you are in a season, so it stays the same between races.
	if not GameData.prefs.has("name"):
		GameData.set_pref("name", "Driver %d" % (randi() % 900 + 100))
	name_edit.text = str(GameData.prefs["name"])
	# Saved as you type, so the name is still there next time the game starts.
	name_edit.text_changed.connect(func(t):
		GameData.set_pref("name", t)
		_refresh_badge())
	name_edit.max_length = 24
	name_edit.placeholder_text = "Your driver name"
	name_edit.custom_minimum_size = Vector2(420, 40)

	# Race set-up: three columns that fit one screen (built for 1600x900,
	# scaled by the window, so the same at 1080p and 4K). The circuit and car
	# cards, and the page itself, are placed into the columns by _show.
	_setup_row = HBoxContainer.new()
	_setup_row.add_theme_constant_override("separation", COLUMN_GAP)
	_setup_row.size_flags_vertical = SIZE_EXPAND_FILL
	root.add_child(_setup_row)
	for i in 3:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 10)
		_setup_row.add_child(col)
		_cols.append(col)
	race_box = VBoxContainer.new()   # kept for the season pages' layout checks
	_build_circuit_card()
	_build_car_card()
	_settings_panel = _card("RACE SETTINGS")
	_settings_change_label = Label.new()
	_settings_change_label.add_theme_font_size_override("font_size", 14)
	_settings_change_label.add_theme_color_override("font_color", Color(1, 0.85, 0.35))
	_settings_change_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_settings_change_label.visible = false
	_card_box(_settings_panel).add_child(_settings_change_label)
	_settings_holder = VBoxContainer.new()
	_settings_holder.add_theme_constant_override("separation", 3)
	_card_box(_settings_panel).add_child(_settings_holder)

	# Main page
	var main := _page(root, "main")
	main.add_theme_constant_override("separation", 10)
	for b in [["Single race", func(): _restore_race(MEMORY_SINGLE); _show("single")], ["Season / championship", func(): _show("season_list")],
			["Garage", _open_garage], ["Host online race", _on_host], ["Join online race", func(): _show("join")],
			["Settings", _open_settings],
			["Quit", func(): GameData.save_prefs(); get_tree().quit()]]:
		var btn := _button(main, b[0], b[1])
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(440, 54)
		btn.size_flags_horizontal = SIZE_SHRINK_BEGIN
		btn.add_theme_font_size_override("font_size", 22)

	# Profile page: your name and colour (the badge top right opens it).
	var prof := _page(root, "profile")
	var ph := Label.new()
	ph.text = "PROFILE"
	ph.add_theme_font_size_override("font_size", 26)
	prof.add_child(ph)
	var name_label := Label.new()
	name_label.text = "Driver name (used in races, seasons and online)"
	name_label.modulate = Color(1, 1, 1, 0.7)
	prof.add_child(name_label)
	prof.add_child(name_edit)
	var colour_stepper := Stepper.choice("Colour", ProfileBadge.COLOURS, str(GameData.prefs.get("profile_colour", "#e8412f")))
	colour_stepper.value_changed.connect(func(v): GameData.set_pref("profile_colour", v); _refresh_badge())
	prof.add_child(colour_stepper)
	profile_info = Label.new()
	profile_info.modulate = Color(0.85, 0.92, 1)
	profile_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	profile_info.custom_minimum_size = Vector2(420, 0)
	prof.add_child(profile_info)
	_button(prof, "Garage", _open_garage)
	_button(prof, "Back", func(): GameData.save_prefs(); _show("main"))

	# Race settings (single player page and host lobby share the values)
	laps_stepper = Stepper.numeric("Laps", 1, 50, 1, 3)
	ai_stepper = Stepper.numeric("AI drivers", 0, RaceSettings.MAX_CARS_SINGLE_CLASS - 1, 1, 5)
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
	drivers_stepper = Stepper.choice("Drivers per car", [[1, "1 (no driver changes)"],
		[2, "2 (AI co-driver at stops)"], [3, "3 (endurance line-ups)"]], 2)
	safety_car_stepper = Stepper.choice("Safety car", [[true, "On (yellows, VSC, SC)"], [false, "Off (yellow flags only)"]], true)
	damage_stepper = Stepper.choice("Damage", [["off", "Off"], ["visual", "Visual only"],
		["full", "Full (affects the car)"]], "full")
	tuning_stepper = Stepper.choice("Car setups", [[true, "Free (tune per track)"], [false, "Fixed (all on default)"]], true)
	tuning_stepper.value_changed.connect(func(_v): _setup_changed())
	upgrades_stepper = Stepper.choice("Car upgrades", [[RaceSettings.UPGRADES_ON, "On (R&D counts)"],
		[RaceSettings.UPGRADES_BOP, "BoP (looks only)"], [RaceSettings.UPGRADES_STOCK, "Off (stock cars)"]],
		RaceSettings.UPGRADES_ON)
	_circuit_only.append_array([fuel_stepper, wear_stepper, stops_stepper, drivers_stepper, safety_car_stepper])
	_derby_hidden = [damage_stepper, upgrades_stepper, tuning_stepper]
	_settings_steppers = [laps_stepper, ai_stepper, difficulty_stepper, tod_stepper, clock_stepper, weather_stepper,
		weather_change_stepper, grid_stepper, damage_stepper, safety_car_stepper, fuel_stepper, wear_stepper, stops_stepper,
		drivers_stepper, upgrades_stepper, tuning_stepper]

	var single := _page(root, "single")
	var sb := HBoxContainer.new()
	sb.add_theme_constant_override("separation", 10)
	single.add_child(sb)
	var go := _button(sb, "Start race", _on_single)
	go.size_flags_horizontal = SIZE_EXPAND_FILL
	go.custom_minimum_size = Vector2(0, 50)
	go.add_theme_font_size_override("font_size", 20)
	var back := _button(sb, "Back", func(): _show("main"))
	back.custom_minimum_size = Vector2(150, 50)
	single.set_meta("settings_box", _settings_holder)

	_build_season_pages(root)

	var join := _page(root, "join")
	join_name_label = Label.new()
	join_name_label.modulate = Color(1, 1, 1, 0.7)
	join.add_child(join_name_label)
	address_edit = LineEdit.new()
	# The last host you joined is remembered (saved when you connect).
	address_edit.text = str(GameData.prefs.get("join_address", "127.0.0.1"))
	address_edit.text_submitted.connect(func(_t): _on_join())
	address_edit.placeholder_text = "Host address, e.g. 81.2.3.4 or 81.2.3.4:24690"
	address_edit.custom_minimum_size = Vector2(420, 40)
	join.add_child(address_edit)
	_button(join, "Connect", _on_join)
	_button(join, "Back", func(): _show("main"))

	# Lobby: who's here and whether they're ready, big and clear; co-op car
	# shares; how friends join; then the buttons.
	var lobby := _page(root, "lobby")
	var players_card := _card("DRIVERS")
	players_card.size_flags_vertical = SIZE_EXPAND_FILL
	lobby.add_child(players_card)
	var pbox := _card_box(players_card)
	lobby_title = Label.new()
	lobby_title.add_theme_font_size_override("font_size", 22)
	lobby_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	pbox.add_child(lobby_title)
	lobby_ready_label = Label.new()
	lobby_ready_label.add_theme_font_size_override("font_size", 15)
	lobby_ready_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	pbox.add_child(lobby_ready_label)
	var list_scroll := ScrollContainer.new()
	list_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.custom_minimum_size = Vector2(0, 200)
	pbox.add_child(list_scroll)
	var list_v := VBoxContainer.new()
	list_v.size_flags_horizontal = SIZE_EXPAND_FILL
	list_v.add_theme_constant_override("separation", 6)
	list_scroll.add_child(list_v)
	lobby_list = VBoxContainer.new()
	lobby_list.add_theme_constant_override("separation", 6)
	list_v.add_child(lobby_list)
	crew_box = VBoxContainer.new()
	crew_box.add_theme_constant_override("separation", 3)
	list_v.add_child(crew_box)
	var crew_head := Label.new()
	crew_head.text = "CO-OP  ·  share a car with up to 3 players (driver, pit crew, strategist)"
	crew_head.add_theme_font_size_override("font_size", 14)
	crew_head.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	crew_head.modulate = Color(0.75, 0.9, 1)
	crew_box.add_child(crew_head)
	join_info_label = Label.new()
	join_info_label.modulate = Color(0.75, 0.9, 1)
	join_info_label.add_theme_font_size_override("font_size", 14)
	join_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pbox.add_child(join_info_label)
	lobby_season_label = Label.new()
	lobby_season_label.add_theme_font_override("font", _mono())
	lobby_season_label.add_theme_font_size_override("font_size", 13)
	lobby_season_label.modulate = Color(1, 0.95, 0.75)
	pbox.add_child(lobby_season_label)
	lobby.set_meta("settings_box", _settings_holder)
	var actions := GridContainer.new()
	actions.columns = 2
	actions.add_theme_constant_override("h_separation", 10)
	actions.add_theme_constant_override("v_separation", 8)
	lobby.add_child(actions)
	ready_button = _button(actions, "Ready", func(): Net.update_me({"ready": not _my_ready()}))
	start_button = _button(actions, "Start race", _on_start_online)
	for big in [ready_button, start_button]:
		big.add_theme_font_size_override("font_size", 20)
	var gb := _button(actions, "Garage", _open_garage)
	var lb := _button(actions, "Leave", _on_leave)
	for btn in [ready_button, start_button, gb, lb]:
		btn.custom_minimum_size = Vector2(0, 48)
		btn.size_flags_horizontal = SIZE_EXPAND_FILL

	for s in _settings_steppers:
		s.value_changed.connect(func(_v): _push_settings())
	for s in _remembered_steppers().values():
		s.value_changed.connect(func(_v): _remember_race())

	status_label = Label.new()
	status_label.modulate = Color(1, 0.75, 0.4)
	status_label.size_flags_vertical = SIZE_SHRINK_CENTER
	head.add_child(status_label)
	var help := Label.new()
	help_label = help
	help.text = "Drive: W/S/A/D or arrows  ·  Pad: RT throttle, LT brake, left stick steer\nZoom (hold): Q/E or mouse wheel, Z whole track  ·  Pad: LB/RB or right stick, R3 whole track  ·  C/Y camera  ·  R/Back restart  ·  Esc/Start menu\nPits: B or D-pad left box this lap  ·  L or L3 pit limiter  ·  T or pad B next tyres  ·  F next fuel\nThese are the defaults: change any of them in Settings > Controller."
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	help.modulate = Color(1, 1, 1, 0.45)
	help.add_theme_font_size_override("font_size", 13)
	root.add_child(help)
	# Profile, top right.
	badge = ProfileBadge.new()
	add_child(badge)
	badge.pressed.connect(func(): _show("profile"))
	_refresh_badge()
	_limit_grid()
	_apply_race_type_rules()


## Race settings sit in two columns so the page fits on screen; D-pad moves between them.
func _settings_grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 4)
	return g


## A dark panel with a heading, for the race set-up columns.
func _card(heading: String) -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.05, 0.82)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(14)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	pc.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	pc.add_child(v)
	var h := Label.new()
	h.text = heading
	h.add_theme_font_size_override("font_size", 15)
	h.add_theme_color_override("font_color", Color(0.94, 0.26, 0.2))
	v.add_child(h)
	pc.set_meta("heading", h)
	return pc


func _card_box(card: PanelContainer) -> VBoxContainer:
	return card.get_child(0) as VBoxContainer


## Circuit: the track picker, the circuit from above, and what it's like.
func _build_circuit_card() -> void:
	_circuit_card = _card("CIRCUIT")
	var box := _card_box(_circuit_card)
	var types := []
	for t in GameData.tracks:
		var dsc := str(t.get("discipline", "circuit"))
		if not types.any(func(o): return o[0] == dsc):
			types.append([dsc, RACE_TYPE_NAMES.get(dsc, dsc.capitalize())])
	types.sort_custom(func(a, b): return RACE_TYPE_NAMES.keys().find(a[0]) < RACE_TYPE_NAMES.keys().find(b[0]))
	race_type_stepper = Stepper.choice("Race type", types, "circuit")
	race_type_stepper.value_changed.connect(func(_v): _on_race_type_changed())
	race_type_stepper.visible = types.size() > 1
	box.add_child(race_type_stepper)
	var track_opts := _track_options("circuit")
	var default_track: String = "mugello" if _track_info("mugello") else track_opts[0][0]
	track_stepper = Stepper.choice("Track", track_opts, default_track)
	track_stepper.value_changed.connect(func(_v): _push_settings(); _refresh_cards())
	box.add_child(track_stepper)
	_track_map = TrackMap.new()
	_track_map.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_child(_track_map)
	_track_title = Label.new()
	_track_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_track_title.add_theme_font_size_override("font_size", 19)
	box.add_child(_track_title)
	_track_facts = Label.new()
	_track_facts.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_track_facts.add_theme_font_size_override("font_size", 14)
	_track_facts.modulate = Color(0.8, 0.86, 0.92)
	box.add_child(_track_facts)
	_track_desc = Label.new()
	_track_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_track_desc.add_theme_font_size_override("font_size", 15)
	_track_desc.modulate = Color(1, 1, 1, 0.82)
	box.add_child(_track_desc)


## Car: class filter, the car picker, the car turning in its livery, what it
## is, then your tyres and setup.
func _build_car_card() -> void:
	_car_card = _card("YOUR CAR")
	var box := _card_box(_car_card)
	# Class (host setting): placed with the race settings on the single race
	# and lobby pages, at the top of this card elsewhere.
	var class_opts := _class_options("circuit")
	var default_class: String = "GT3" if CarCatalog.ids_in_class(GameData.cars, "GT3").size() > 0 else class_opts[0][0]
	class_stepper = Stepper.choice("Class", class_opts, default_class)
	class_stepper.value_changed.connect(func(_v): _rebuild_car_options(); _limit_grid(); _push_settings())
	box.add_child(class_stepper)
	# With every class on the grid (multi-class / open) the car list is long:
	# this narrows it to one class. Shown only then.
	var filter_opts := _filter_options("circuit")
	var want_filter = GameData.prefs.get("car_filter", "")
	car_filter_stepper = Stepper.choice("Car class", filter_opts,
		want_filter if filter_opts.any(func(o): return o[0] == want_filter) else "")
	car_filter_stepper.value_changed.connect(func(v):
		GameData.set_pref("car_filter", v)
		_rebuild_car_options())
	box.add_child(car_filter_stepper)
	car_stepper = Stepper.choice("Car", [], "")
	car_stepper.value_changed.connect(func(v):
		GameData.prefs["car_id"] = v
		_refresh_cards()
		if Net.is_online(): Net.update_me(_my_lobby_fields(v)))
	box.add_child(car_stepper)
	_car_preview = CarPreview.new()
	_car_preview.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_child(_car_preview)
	_car_title = Label.new()
	_car_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_car_title.add_theme_font_size_override("font_size", 19)
	box.add_child(_car_title)
	_car_facts = Label.new()
	_car_facts.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_car_facts.add_theme_font_size_override("font_size", 14)
	_car_facts.modulate = Color(0.8, 0.86, 0.92)
	box.add_child(_car_facts)
	_car_desc = Label.new()
	_car_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_car_desc.add_theme_font_size_override("font_size", 15)
	_car_desc.modulate = Color(1, 1, 1, 0.82)
	box.add_child(_car_desc)
	# Driving aids, gears and units are in Settings > Gameplay.
	tyre_stepper = Stepper.choice("Tyres", [["auto", "Auto (suit the weather)"], ["dry", "Dry"],
		["intermediate", "Intermediate"], ["wet", "Full wet"]], "auto")
	tyre_stepper.value_changed.connect(func(v): if Net.is_online(): Net.update_me({"tyre": v}))
	box.add_child(tyre_stepper)
	_circuit_only.append(tyre_stepper)
	setup_button = _button(box, "Car setup", _open_setup)
	car_stepper.value_changed.connect(func(_v): _setup_changed())
	track_stepper.value_changed.connect(func(_v): _setup_changed())
	_rebuild_car_options()


## Track picker entries for one race type.
func _track_options(discipline: String) -> Array:
	var opts := []
	for t in GameData.tracks:
		if str(t.get("discipline", "circuit")) == discipline:
			opts.append([t["id"], t["name"]])
	return opts


## Class picker entries for one race type (multi-class and open only where
## there is more than one class).
func _class_options(discipline: String) -> Array:
	var opts := []
	var classes := CarCatalog.classes(GameData.cars, discipline)
	for c in classes:
		opts.append([c, "%s  (%d cars)" % [c, CarCatalog.ids_in_class(GameData.cars, c).size()]])
	if classes.size() > 1:
		opts.append([RaceSettings.CLASS_MULTI, "Multi-class (all cars)"])
		opts.append(["", "Open (AI match the players)"])
	return opts


func _filter_options(discipline: String) -> Array:
	var opts := [["", "All classes"]]
	for c in CarCatalog.classes(GameData.cars, discipline):
		opts.append([c, "%s  (%d cars)" % [c, CarCatalog.ids_in_class(GameData.cars, c).size()]])
	return opts


func _race_type() -> String:
	return str(race_type_stepper.value) if race_type_stepper else "circuit"


## A new race type: its tracks and classes, sensible race lengths, and only
## the settings that apply (rallycross: no pit stops, fuel, safety car, tyre
## choice or co-op).
func _on_race_type_changed(push := true) -> void:
	var dsc := _race_type()
	var topts := _track_options(dsc)
	if topts.is_empty():
		return
	# Remembering: keep what the old race type had, then bring back what this
	# one had last time (its track, car, laps ...), if it was raced before.
	var recalled := {}
	if _mem_slot != "" and not _mem_restoring:
		_remember_race(_mem_type)
		recalled = _race_memory().get(_mem_slot, {}).get(dsc, {})
	_mem_type = dsc
	track_stepper.options = topts
	if not topts.any(func(o): return o[0] == track_stepper.value):
		track_stepper.set_value(topts[0][0])
	else:
		track_stepper.set_value(track_stepper.value)
	var copts := _class_options(dsc)
	class_stepper.options = copts
	if not copts.any(func(o): return o[0] == class_stepper.value):
		class_stepper.set_value(copts[0][0])
	else:
		class_stepper.set_value(class_stepper.value)
	car_filter_stepper.options = _filter_options(dsc)
	car_filter_stepper.set_value("")
	if recalled.is_empty() and push and not _building and (not Net.is_online() or Net.is_server()):
		if dsc == RaceSettings.DISCIPLINE_RALLYCROSS:
			laps_stepper.set_value(6)   # a World RX final: 6 laps, 6 cars
			ai_stepper.set_value(5)
		elif dsc == RaceSettings.DISCIPLINE_DERBY:
			laps_stepper.set_value(8)   # long enough for the field to wreck itself
		elif int(laps_stepper.value) in [6, 8]:
			laps_stepper.set_value(3)
	_apply_race_type_rules()
	_rebuild_car_options()
	_limit_grid()
	_refresh_cards()
	if not recalled.is_empty():
		_apply_remembered(recalled)
		_refresh_cards()
	if _mem_slot != "" and not _mem_restoring:
		_remember_race()
	if push:
		_push_settings()


func _apply_race_type_rules() -> void:
	var circuit := _race_type() == RaceSettings.DISCIPLINE_CIRCUIT
	for c in _circuit_only:
		c.visible = circuit
	for c in _derby_hidden:
		c.visible = _race_type() != RaceSettings.DISCIPLINE_DERBY
	if crew_box:
		crew_box.visible = circuit
	_circuit_card.get_meta("heading").text = "CIRCUIT" if circuit else RACE_TYPE_NAMES.get(_race_type(), "CIRCUIT").to_upper()


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
	if id == "profile":
		_refresh_badge()
	if id == "join":
		join_name_label.text = "Joining as %s  (change it on your profile)" % name_edit.text
	if id != "lobby":  # host-only settings are editable again off-line
		class_stepper.disabled = false
		track_stepper.disabled = false
		race_type_stepper.disabled = false
		for st in _settings_steppers:
			st.disabled = false
		_settings_change_label.visible = false
		_last_shown.clear()
		_recent_changes.clear()
	for k in pages:
		pages[k].visible = k == id
	# In a season the season picks the class and each round's track.
	class_stepper.visible = not id in SEASON_PAGES
	track_stepper.visible = not id in SEASON_PAGES
	# Seasons are circuit racing.
	var season_page := id.begins_with("season")
	race_type_stepper.visible = not season_page and race_type_stepper.options.size() > 1
	if season_page and _race_type() != RaceSettings.DISCIPLINE_CIRCUIT:
		race_type_stepper.set_value(RaceSettings.DISCIPLINE_CIRCUIT)
	if id != "lobby":
		race_type_stepper.disabled = false
	help_label.visible = id == "main"
	if not id in [MEMORY_SINGLE, "lobby"]:
		_mem_slot = ""   # seasons and guests don't touch the remembered settings
	if id == "season_hub":
		_refresh_hub()
	elif id == "season_list":
		_refresh_season_list()
	elif id == "season_new":
		_refresh_calendar()
	_layout(id)
	# Settings steppers live on whichever page needs them.
	var box: Node = pages[id].get_meta("settings_box") if pages[id].has_meta("settings_box") else _settings_holder
	for s in _settings_steppers:
		if s.get_parent() != box:
			if s.get_parent():
				s.get_parent().remove_child(s)
			box.add_child(s)
	_style_steppers(box == _settings_holder)
	_refresh_cards()
	_status("")
	_focus_first.call_deferred(pages[id])


func _move(node: Control, parent: Node) -> void:
	if node.get_parent() != parent:
		if node.get_parent():
			node.get_parent().remove_child(node)
		parent.add_child(node)


## Places the circuit card, the car card, the race settings and the page into
## the three columns. Single race: circuit | car | settings + start. Lobby:
## circuit over car | drivers | settings. Seasons: circuit over car | page.
## Other pages: a plain list on the left, over the background.
func _layout(id: String) -> void:
	var setup: bool = id in SETUP_PAGES
	var lobby := id == "lobby"
	var single := id == "single"
	_margin.add_theme_constant_override("margin_left", 40 if setup else 80)
	_margin.add_theme_constant_override("margin_right", 40)
	_margin.add_theme_constant_override("margin_top", 22 if setup else 56)
	_margin.add_theme_constant_override("margin_bottom", 18 if setup else 40)
	_root_box.size_flags_horizontal = SIZE_EXPAND_FILL if setup else SIZE_SHRINK_BEGIN
	_root_box.add_theme_constant_override("separation", 10 if setup else 12)
	_title_label.add_theme_font_size_override("font_size", 34 if setup else 54)
	_page_title.text = PAGE_TITLES.get(id, "")
	if lobby:
		_page_title.text = "HOSTING ONLINE" if Net.is_server() else "ONLINE LOBBY"
	_stripe.visible = not setup
	_sub_label.visible = id == "main"
	_setup_row.visible = setup
	# Fixed column widths add up to the 1520 px inside the margins.
	var widths: Array = [470, 470, 500] if single else ([440, 540, 500] if lobby else [440, 1000, 0])
	for i in 3:
		_cols[i].custom_minimum_size.x = widths[i]
		_cols[i].visible = widths[i] > 0
		_cols[i].size_flags_horizontal = SIZE_EXPAND_FILL if i == 1 and not (single or lobby) else SIZE_FILL
	if not setup:
		for c in [_circuit_card, _car_card, _settings_panel]:
			if c.get_parent():
				c.get_parent().remove_child(c)
		for k in pages:
			_move(pages[k], _root_box)
		_root_box.move_child(help_label, -1)
		return
	_move(_circuit_card, _cols[0])
	_move(_car_card, _cols[1] if single else _cols[0])
	_circuit_card.visible = id != "season_hub" or (GameData.season != null and not GameData.season.is_complete())
	# Big pictures when each card has a column to itself, smaller stacked.
	_track_map.custom_minimum_size = Vector2(0, 300 if single else 170)
	_track_map.show_profile = single
	_car_preview.custom_minimum_size = Vector2(0, 260 if single else 120)
	for l in [_track_desc, _car_desc]:
		l.add_theme_font_size_override("font_size", 15 if single else 14)
	_circuit_card.size_flags_vertical = SIZE_EXPAND_FILL
	_car_card.size_flags_vertical = SIZE_EXPAND_FILL
	if single or lobby:
		_move(_settings_panel, _cols[2])
		_settings_panel.size_flags_vertical = SIZE_EXPAND_FILL if lobby else SIZE_FILL
		_move(pages[id], _cols[2] if single else _cols[1])
		pages[id].size_flags_vertical = SIZE_EXPAND_FILL if lobby else SIZE_FILL
		# Class decides who's on the grid: a race setting here.
		_move(class_stepper, _settings_holder)
		_settings_holder.move_child(class_stepper, 0)
	else:
		if _settings_panel.get_parent():
			_settings_panel.get_parent().remove_child(_settings_panel)
		_move(pages[id], _cols[1])
		pages[id].size_flags_vertical = SIZE_FILL
		_move(class_stepper, _card_box(_car_card))
		_card_box(_car_card).move_child(class_stepper, 1)


## Steppers in the set-up columns: shorter rows, values lined up, and (for
## guests) still easy to read while only the host can change them.
func _style_steppers(compact: bool) -> void:
	var list: Array = _settings_steppers.duplicate()
	list.append(class_stepper)
	for st in list:
		st.custom_minimum_size = Vector2(0, 33) if compact else Vector2(420, 40)
		st.value_column = 190.0 if compact else 0.0
		st.add_theme_font_size_override("font_size", 16)
		st.add_theme_color_override("font_disabled_color", Color(0.86, 0.89, 0.93))
	for st in [track_stepper, car_filter_stepper, car_stepper, tyre_stepper]:
		st.custom_minimum_size = Vector2(0, 36)
		st.value_column = 110.0
		st.add_theme_font_size_override("font_size", 17)
		st.add_theme_color_override("font_disabled_color", Color(0.86, 0.89, 0.93))
	setup_button.custom_minimum_size = Vector2(0, 36)


## The circuit and car cards: map, picture and words for what's picked.
func _refresh_cards() -> void:
	if _track_map == null or car_stepper == null:
		return
	var t := _track_info(str(track_stepper.value))
	_track_map.show_track(t)
	_track_title.text = t.get("name", "")
	var facts := ["%.2f km" % (float(t.get("length_m", 0.0)) / 1000.0), str(t.get("location", ""))]
	if t.get("has_pit_lane", false):
		facts.append("pit lane")
	if str(t.get("discipline", "")) == RaceSettings.DISCIPLINE_RALLYCROSS:
		var L := maxf(float(t.get("length_m", 1.0)), 1.0)
		var loose := 0.0
		for r in t.get("dirt", []):
			loose += fposmod(float(r[1]) - float(r[0]), L)
		facts.append("%d%% dirt" % roundi(loose / L * 100.0))
		if float(t.get("joker_length_m", 0.0)) > 0.0:
			facts.append("joker lap")
	if int(t.get("crossovers", 0)) > 0:
		facts.append("%d crossover%s" % [t["crossovers"], "s" if int(t["crossovers"]) > 1 else ""])
	if int(t.get("jumps", 0)) > 0:
		facts.append("%d jump%s" % [t["jumps"], "s" if int(t["jumps"]) > 1 else ""])
	if float(t.get("dirt_m", 0.0)) > 0.0 and str(t.get("discipline", "")) == RaceSettings.DISCIPLINE_DERBY:
		facts.append("%d%% dirt" % roundi(100.0 * float(t["dirt_m"]) / maxf(float(t.get("length_m", 1.0)), 1.0)))
	_track_facts.text = "  ·  ".join(facts)
	_track_desc.text = str(t.get("description", ""))
	var c: CarDefinition = GameData.cars.get(str(car_stepper.value))
	if c == null:
		return
	var levels := profile.levels(c.id)
	var def := c.with_overrides(UpgradeCatalog.overrides_for(c, levels))
	_car_preview.show_car(def, profile.livery_for(c.id))
	var st := UpgradeCatalog.stats(c, levels)
	var rd := 0
	for l in levels.values():
		rd += int(l)
	_car_title.text = c.display_name
	var drive := "RWD" if c.front_drive_split <= 0.01 else ("FWD" if c.front_drive_split >= 0.99 else "AWD")
	var parts := [c.class_tag, Units.power(st["power_kw"]), "%.0f kg" % st["mass_kg"], drive]
	if rd > 0:
		parts.append("R&D %d" % rd)
	if profile.owns(c.id):
		parts.append("in your garage")
	_car_facts.text = "  ·  ".join(parts)
	_car_desc.text = c.description


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
	car_filter_stepper.visible = not fixed
	var filter: String = "" if fixed else str(car_filter_stepper.value)
	var dsc := _race_type()
	var ids := CarCatalog.ids_in_class(GameData.cars, cls if fixed else filter).filter(func(id): return GameData.cars[id].discipline == dsc)
	if ids.is_empty():
		ids = CarCatalog.ids_in_class(GameData.cars, cls if fixed else "").filter(func(id): return GameData.cars[id].discipline == dsc)
	var opts := []
	for id in ids:
		var c: CarDefinition = GameData.cars[id]
		# The card under the picker shows the numbers; the list stays short.
		opts.append([id, "%s%s%s" % [c.display_name, "  (%s)" % c.class_tag if not fixed else "",
			"  ★" if profile.owns(id) else ""]])
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
			Net.update_me(_my_lobby_fields(car_stepper.value))
	else:
		car_stepper.set_value(car_stepper.value)
	_refresh_cards()


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
	s.drivers_per_car = int(drivers_stepper.value)
	s.safety_car_enabled = bool(safety_car_stepper.value)
	s.set_damage_level(str(damage_stepper.value))
	s.upgrades_mode = str(upgrades_stepper.value)
	s.tuning_enabled = bool(tuning_stepper.value)
	s.discipline = _race_type()
	if not s.allows_coop():   # rallycross: sprints, no stops, no shared cars
		s.drivers_per_car = 1
		s.mandatory_pit_stops = 0
		s.fuel_enabled = false
		s.safety_car_enabled = false
		s.tyre_wear_enabled = false
	if s.is_derby():
		s.apply_derby_rules()
	return s


# --- Car setup (per car per track) ----------------------------------------

func _setup_changed() -> void:
	_refresh_setup_button()
	if Net.is_online() and Net.players.has(Net.my_id()):
		Net.update_me({"setup": _my_setup(str(car_stepper.value))})


func _refresh_setup_button() -> void:
	if setup_button == null:
		return
	var free: bool = tuning_stepper == null or bool(tuning_stepper.value)
	var saved := SetupStore.has(str(car_stepper.value), str(track_stepper.value))
	var where: String = _track_info(str(track_stepper.value)).get("short_name", str(track_stepper.value))
	if not free:
		setup_button.text = "Car setup  ·  fixed by the race settings"
	else:
		setup_button.text = "Car setup  ·  %s at %s" % ["your setup" if saved else "default", where]
	setup_button.disabled = not free


func _open_setup() -> void:
	var car: CarDefinition = GameData.cars.get(car_stepper.value)
	var track := TrackCatalog.load_track(str(track_stepper.value))
	if car == null or track == null:
		return
	var s := _settings_from_ui() if not Net.is_online() or Net.is_server() else Net.settings
	var track_env := track.default_environment.duplicate()
	if not track.climate.is_empty():
		track_env["climate"] = track.climate
	var env := SimEnvironment.create(track_env, s.environment, s.seed)
	var screen := SetupScreen.new()
	screen.name = "SetupScreen"
	add_child(screen)
	screen.open(car, track, GameData.tyres.get(car.tyre_compound_id), {"track_c": env.track_c,
		"ambient_c": env.ambient_c, "wetness": env.wetness, "laps": s.laps, "fuel_enabled": s.fuel_enabled,
		"fuel_rate": s.fuel_rate})
	_set_activity("setup")
	screen.closed.connect(func(_setup):
		_set_activity("lobby")
		_setup_changed()
		setup_button.grab_focus())


# --- Actions --------------------------------------------------------------

func _on_single() -> void:
	var s := _settings_from_ui()
	s.seed = randi()
	# Testing the co-op screens alone: --role strategist (or pit_crew, pit_wall)
	# puts you on your car's pit wall with the AI at the wheel.
	var role := str(GameData.arg("role", RaceEntry.ROLE_DRIVER))
	if not role in RaceEntry.ROLES:
		role = RaceEntry.ROLE_DRIVER
	var humans := [{"name": name_edit.text, "car_id": car_stepper.value, "tyre": tyre_stepper.value,
		"crew": [{"peer_id": 0, "name": name_edit.text, "role": role}],
		"setup": _my_setup(car_stepper.value), "livery": profile.livery_for(car_stepper.value)}]
	var start := RaceFactory.plan(s, humans, GameData.cars, GameData.drivers)
	GameData.active_session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	get_tree().change_scene_to_file(GameData.SCENE_RACE)


func _on_host() -> void:
	var port := int(GameData.arg("port", Net.DEFAULT_PORT))
	if not GameData.arg("host"):   # test runs set their own settings
		_restore_race(MEMORY_HOST)
	var err := Net.host(port, name_edit.text)
	if err != OK:
		_mem_slot = ""
		_status("Could not host on port %d (error %d)." % [port, err])
		return
	var fields := _my_lobby_fields(car_stepper.value)
	fields["tyre"] = tyre_stepper.value
	Net.update_me(fields)
	Net.set_settings(_settings_from_ui())
	_show("lobby")


## remember: save the address for next time (not for --join test runs).
func _on_join(remember := true) -> void:
	var port := int(GameData.arg("port", Net.DEFAULT_PORT))
	address_edit.text = address_edit.text.strip_edges()
	if remember and address_edit.text != "":
		GameData.set_pref("join_address", address_edit.text)
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


const ROLE_NAMES := {"driver": "driver", "pit_crew": "pit crew", "strategist": "strategist",
	"pit_wall": "pit crew + strategist"}


## The lobby's co-op rows: each player's car share and role. The host can set
## anyone's; players set their own. Rows are kept (not rebuilt) while the
## same players are in, so a controller keeps its place.
func _refresh_crews() -> void:
	var ids := Net.players.keys()
	ids.sort()
	if ids != _crew_ids:
		_crew_ids = ids
		for id in _crew_rows:
			_crew_rows[id]["row"].queue_free()
		_crew_rows.clear()
		for id in ids:
			var row := HBoxContainer.new()
			var team_opts := [[-1, "own car"]]
			for t in Net.MAX_TEAMS:
				team_opts.append([t, "car share %d" % (t + 1)])
			var ts := Stepper.choice(str(Net.players[id]["name"]).left(14), team_opts, -1)
			ts.custom_minimum_size = Vector2(360, 40)
			var rs := Stepper.choice("Role", [[RaceEntry.ROLE_DRIVER, "driver"]], RaceEntry.ROLE_DRIVER)
			rs.custom_minimum_size = Vector2(400, 40)
			ts.value_changed.connect(func(v): _set_crew(id, {"team": int(v)}))
			rs.value_changed.connect(func(v): _set_crew(id, {"role": str(v)}))
			# Co-op pit stops: the crew job this player does in the tyre change.
			var js := Stepper.choice("Pit stop job", [["fuel", "fuel man"]], "fuel")
			js.value_changed.connect(func(v): _set_crew(id, {"pit_job": str(v)}))
			js.tooltip_text = "Co-op pit stops: the strategist refuels; the driver cleans the windscreen first, a third player lays out the tyres and guns and puts the air jacks in, then each of them does this job."
			row.add_child(ts)
			row.add_child(rs)
			var block := VBoxContainer.new()
			block.add_theme_constant_override("separation", 1)
			block.add_child(row)
			block.add_child(js)
			crew_box.add_child(block)
			for st in [ts, rs, js]:   # after add_child: Stepper._ready sets its own size
				st.custom_minimum_size = Vector2(0, 32)
				st.size_flags_horizontal = SIZE_EXPAND_FILL
				st.value_column = 130.0 if st == ts else (200.0 if st == js else 60.0)
				st.add_theme_font_size_override("font_size", 15)
			_crew_rows[id] = {"row": block, "team": ts, "role": rs, "job": js}
		Sound.wire_buttons(crew_box)
	var me := Net.my_id()
	for id in ids:
		var p: Dictionary = Net.players[id]
		var r: Dictionary = _crew_rows[id]
		var team: int = p.get("team", -1)
		var size := Net.team_members(team).size() if team >= 0 else 1
		var mine: bool = id == me or Net.is_server()
		r["team"].set_value(team)
		r["team"].disabled = not mine or Net.in_race
		var opts := []
		for role in RaceEntry.roles_for_crew(maxi(size, 1)):
			opts.append([role, ROLE_NAMES[role]])
		r["role"].options = opts
		r["role"].set_value(p.get("role", RaceEntry.ROLE_DRIVER))
		r["role"].disabled = not mine or size <= 1 or Net.in_race
		# Pit stop job: only in a car share, picked by the driver and a pit crew player.
		var role := str(p.get("role", ""))
		r["job"].visible = team >= 0 and size > 1
		if RaceEntry.picks_pit_job(role):
			var jobs := []
			for j in RaceEntry.PIT_JOBS:
				jobs.append([j, RaceEntry.PIT_JOB_NAMES[j]])
			r["job"].options = jobs
			r["job"].set_value(str(p.get("pit_job", "gun_l")) if str(p.get("pit_job", "")) in RaceEntry.PIT_JOBS else "gun_l")
			r["job"].disabled = not mine or Net.in_race
		else:
			r["job"].options = [["fuel", "fuel man (strategist)"]]
			r["job"].set_value("fuel")
			r["job"].disabled = true


## Guests: the host's changes show straight away (the lobby is sent to every
## player on each change); a setting the host just changed lights up, and the
## settings card says what it was.
func _flash_host_changes() -> void:
	var list: Array = [race_type_stepper, track_stepper, class_stepper]
	list.append_array(_settings_steppers)
	var changed := []
	for st in list:
		var shown: String = st.label_text + "=" + str(st.value)
		if _last_shown.has(st) and _last_shown[st] != shown:
			changed.append(st)
		_last_shown[st] = shown
	if changed.is_empty():
		return
	var now := Time.get_ticks_msec()
	for st in changed:
		_recent_changes[st] = {"text": "%s: %s" % [st.label_text, st.shown_text()], "t": now}
		var tw: Tween = st.create_tween()
		st.modulate = Color(1.0, 0.82, 0.3)
		tw.tween_property(st, "modulate", Color.WHITE, 2.5).set_delay(0.6)
	# Changes made close together are listed together.
	var words := []
	for st in _recent_changes.keys():
		if now - int(_recent_changes[st]["t"]) > 8000:
			_recent_changes.erase(st)
		else:
			words.append(_recent_changes[st]["text"])
	_settings_change_label.text = "The host changed " + ",  ".join(words.slice(-4))
	_settings_change_label.visible = true
	if changed.has(track_stepper):
		var tw: Tween = _track_map.create_tween()
		_track_map.modulate = Color(1.3, 1.2, 0.8)
		tw.tween_property(_track_map, "modulate", Color.WHITE, 1.5)


const ACTIVITY_NAMES := {"lobby": "", "garage": "in the garage", "setup": "tuning the car setup",
	"settings": "in settings"}
const TYRE_NAMES := {"auto": "", "dry": "dry tyres", "intermediate": "inters", "wet": "wets"}


func _not_ready_names() -> String:
	var names := []
	for id in Net.players:
		if id != 1 and not Net.players[id]["ready"]:
			names.append(str(Net.players[id]["name"]))
	return ", ".join(names.slice(0, 3)) + (" ..." if names.size() > 3 else "")


## One driver in the lobby: their paint colour, name, car and what they're
## doing on the left; a big READY / NOT READY / HOST tag on the right.
func _player_row(id: int, p: Dictionary) -> Control:
	var me := id == Net.my_id()
	var host := id == 1
	var ready: bool = p.get("ready", false)
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.09) if me else Color(1, 1, 1, 0.04)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 0
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	if me:
		sb.border_color = Color(1, 0.8, 0.3, 0.6)
		sb.set_border_width_all(1)
	pc.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	pc.add_child(row)
	var car: CarDefinition = GameData.cars.get(p["car_id"])
	var paint := car.colour if car else Color.GRAY
	var liv: Dictionary = p.get("livery", {})
	if liv.get("primary") is String and str(liv["primary"]).begins_with("#"):
		paint = Color(str(liv["primary"]))
	var swatch := ColorRect.new()
	swatch.color = paint
	swatch.custom_minimum_size = Vector2(8, 0)
	row.add_child(swatch)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	var name_l := Label.new()
	name_l.text = str(p["name"]) + ("  (you)" if me else "")
	name_l.add_theme_font_size_override("font_size", 21)
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.add_child(name_l)
	var bits := [car.display_name if car else str(p["car_id"])]
	if TYRE_NAMES.get(p.get("tyre", "auto"), "") != "":
		bits.append(TYRE_NAMES[p["tyre"]])
	var vis: Dictionary = p.get("setup", {}).get("visual", {})
	if not p.get("setup", {}).is_empty() and Net.settings.upgrades_mode == RaceSettings.UPGRADES_ON:
		bits.append("upgraded")
	elif not vis.is_empty() and Net.settings.upgrades_mode == RaceSettings.UPGRADES_BOP:
		bits.append("upgraded (looks only)")
	var team: int = p.get("team", -1)
	if team >= 0 and Net.team_members(team).size() > 1:
		bits.append("car share %d: %s" % [team + 1, ROLE_NAMES.get(p.get("role", ""), "?")])
	var info := Label.new()
	info.text = "  ·  ".join(bits)
	info.add_theme_font_size_override("font_size", 14)
	info.modulate = Color(0.8, 0.86, 0.92)
	info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.add_child(info)
	var doing := str(ACTIVITY_NAMES.get(p.get("activity", "lobby"), ""))
	var ping := int(p.get("ping", -1))
	if doing != "" or (ping >= 0 and not host):
		var act := Label.new()
		var parts := []
		if doing != "":
			parts.append(doing[0].to_upper() + doing.substr(1))
		if ping >= 0 and not host:
			parts.append("ping %d ms" % ping)
		act.text = "  ·  ".join(parts)
		act.add_theme_font_size_override("font_size", 13)
		act.add_theme_color_override("font_color", Color(0.65, 0.85, 1) if doing != "" else Color(1, 1, 1, 0.5))
		if ping > 150:
			act.add_theme_color_override("font_color", Color(1, 0.6, 0.4))
		text.add_child(act)
	var tag := Label.new()
	var tag_sb := StyleBoxFlat.new()
	tag_sb.set_corner_radius_all(5)
	tag_sb.content_margin_left = 12
	tag_sb.content_margin_right = 12
	tag_sb.content_margin_top = 4
	tag_sb.content_margin_bottom = 4
	if host:
		tag.text = "HOST"
		tag_sb.bg_color = Color(0.2, 0.45, 0.9)
	elif ready:
		tag.text = "READY"
		tag_sb.bg_color = Color(0.16, 0.62, 0.3)
	else:
		tag.text = "NOT READY"
		tag_sb.bg_color = Color(0.75, 0.45, 0.08)
	tag.add_theme_stylebox_override("normal", tag_sb)
	tag.add_theme_font_size_override("font_size", 17)
	tag.size_flags_vertical = SIZE_SHRINK_CENTER
	tag.custom_minimum_size = Vector2(122, 0)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(tag)
	return pc


func _set_crew(id: int, fields: Dictionary) -> void:
	if id == Net.my_id():
		Net.update_me(fields)
	elif Net.is_server() and fields.has("pit_job"):
		Net.set_player_pit_job(id, str(fields["pit_job"]))
	elif Net.is_server():
		Net.set_player_team(id, int(fields.get("team", Net.players.get(id, {}).get("team", -1))), str(fields.get("role", "")))


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
		# Send my upgrades and livery once the host knows me (and after changes).
		var mine := _my_lobby_fields(my_car)
		if JSON.stringify(Net.players[me].get("setup", {})) != JSON.stringify(mine["setup"]) \
				or JSON.stringify(Net.players[me].get("livery", {})) != JSON.stringify(mine["livery"]):
			Net.update_me({"setup": mine["setup"], "livery": mine["livery"]})
		var my_tyre: String = Net.players[me].get("tyre", "auto")
		if my_tyre != tyre_stepper.value:
			if my_tyre == "auto" and tyre_stepper.value != "auto":
				Net.update_me({"tyre": tyre_stepper.value})  # just joined: send my choice
			else:
				tyre_stepper.set_value(my_tyre)
	if GameData.arg("host-demo") and Net.is_server() and Net.players.size() >= 3 and not _demo_done:
		_demo_done = true
		get_tree().create_timer(2.0).timeout.connect(func():
			track_stepper._nudge(1, false)
			weather_stepper._nudge(1, false)
			laps_stepper._nudge(1, false))
	if GameData.arg("ready") and Net.players.has(me) and not _my_ready():
		Net.update_me({"ready": true})
	var env_s := Net.settings.environment
	lobby_title.text = "%d driver%s  ·  %s  ·  %d laps  ·  %d AI  ·  %s, %02d:00" % [
		Net.players.size(), "" if Net.players.size() == 1 else "s",
		_track_info(Net.settings.track_id).get("short_name", Net.settings.track_id),
		Net.settings.laps, Net.settings.ai_count,
		SimEnvironment.weather_name(env_s.get("weather", "dry")), int(env_s.get("time_of_day_h", 14))]
	var joiners := 0
	var ready_n := 0
	for id in Net.players:
		if id != 1:
			joiners += 1
			ready_n += 1 if Net.players[id]["ready"] else 0
	if joiners == 0:
		lobby_ready_label.text = "Waiting for drivers to join" if Net.is_server() else "Connecting ..."
		lobby_ready_label.add_theme_color_override("font_color", Color(0.75, 0.85, 1))
	elif ready_n == joiners:
		lobby_ready_label.text = "Everyone is ready" + ("  ·  start when you like" if Net.is_server() else "  ·  waiting for the host to start")
		lobby_ready_label.add_theme_color_override("font_color", Color(0.45, 0.95, 0.55))
	else:
		lobby_ready_label.text = "%d of %d ready  ·  waiting for %s" % [ready_n, joiners, _not_ready_names()]
		lobby_ready_label.add_theme_color_override("font_color", Color(1, 0.78, 0.3))
	for c in lobby_list.get_children():
		c.queue_free()
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		lobby_list.add_child(_player_row(id, Net.players[id]))
	_refresh_crews()
	if GameData.arg("team") and Net.players.has(me) and not _cmdline_team_sent:
		_cmdline_team_sent = true  # testing: --team 1 --role strategist
		Net.update_me({"team": int(GameData.arg("team")) - 1, "role": str(GameData.arg("role", ""))})
		if GameData.arg("pit-job"):
			Net.update_me({"pit_job": str(GameData.arg("pit-job"))})
	var host := Net.is_server()
	var in_season := not Net.season_info.is_empty()
	for s in _settings_steppers:
		s.disabled = not host or in_season
	class_stepper.disabled = not host or in_season
	track_stepper.disabled = not host or in_season
	race_type_stepper.disabled = not host or in_season
	lobby_season_label.visible = in_season
	if in_season:
		lobby_season_label.text = _season_info_text(Net.season_info)
	race_type_stepper.disabled = not host or in_season
	if not host or in_season:
		if race_type_stepper.value != Net.settings.discipline:
			race_type_stepper.set_value(Net.settings.discipline)
			_on_race_type_changed(false)
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
		drivers_stepper.set_value(Net.settings.drivers_per_car)
		safety_car_stepper.set_value(Net.settings.safety_car_enabled)
		damage_stepper.set_value(Net.settings.effective_damage_level())
		upgrades_stepper.set_value(Net.settings.upgrades_mode)
		if tuning_stepper.value != Net.settings.tuning_enabled:
			tuning_stepper.set_value(Net.settings.tuning_enabled)
		_flash_host_changes()
	_refresh_setup_button()
	_refresh_cards()
	var mine: Dictionary = Net.players.get(me, {})
	if not mine.is_empty() and JSON.stringify(mine.get("setup", {})) != JSON.stringify(_my_setup(str(car_stepper.value))):
		Net.update_me({"setup": _my_setup(str(car_stepper.value))})  # joined, or the host changed track
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
	var n_circuits := TrackCatalog.ids_for(GameData.tracks, RaceSettings.DISCIPLINE_CIRCUIT).size()
	_button(cal, "Every track (%d rounds)" % n_circuits, func(): _quick_calendar(n_circuits))
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
		l.size_flags_vertical = SIZE_SHRINK_BEGIN
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
	var ids := Array(TrackCatalog.ids_for(GameData.tracks, RaceSettings.DISCIPLINE_CIRCUIT))
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
	# The circuit card shows the next round.
	if not s.is_complete() and _track_info(str(s.current_round()["track_id"])):
		track_stepper.set_value(str(s.current_round()["track_id"]))
		_refresh_setup_button()
	var champ := s.champion()
	if s.is_complete():
		hub_info.text = "Season finished.  Champion: %s (%s), %d points." % [champ.get("name", "?"), champ.get("team", ""), champ.get("points", 0)]
	else:
		var r := s.current_round()
		hub_info.text = "Round %d of %d: %s, %d laps, %s, %02d:00  ·  next: %s\nPoints: %s  ·  qualifying: %s  ·  %d AI drivers" % [
			s.round_index + 1, s.rounds.size(), _track_info(r["track_id"]).get("name", r["track_id"]), int(r["laps"]),
			SimEnvironment.weather_name(r.get("weather", "dry")).to_lower(), int(r.get("time_of_day_h", 14)),
			s.next_session(), s.points.display_name(), s.qualifying, s.roster.size()]
	var lines := ["DRIVERS                                   PTS  W  POD"]
	var k := 0
	for d in s.driver_standings():
		k += 1
		if k > 25:
			break
		lines.append("%2d %s%-18s %-18s %4d %2d %3d" % [k, " " if d["is_ai"] else ">", d["name"].left(18),
			d["team"].left(18), d["points"], d["wins"], d["podiums"]])
	hub_drivers.text = "\n".join(lines)
	var right := ["TEAMS                      PTS"]
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
	Net.start_planner = s.plan_for_lobby.bind(GameData.cars)
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
	if GameData.arg("menu-shot-wait"):  # e.g. let friends join the lobby first
		await get_tree().create_timer(float(GameData.arg("menu-shot-wait"))).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[screenshot] saved")
	get_tree().quit()


# --- Garage and the player's team (business module) ------------------------

## CarDefinition overrides to race this car with: its bought upgrades.
## (Track tuning, from the setup screen, is merged into the same dictionary.)
func _my_setup(id: String) -> Dictionary:
	var c: CarDefinition = GameData.cars.get(id)
	var out: Dictionary = profile.setup_for(c).duplicate(true) if c else {}
	out.merge(SetupStore.entry_setup(id, str(track_stepper.value)), true)
	return out


## Lobby fields for my car: id, setup and livery.
func _my_lobby_fields(id: String) -> Dictionary:
	return {"car_id": id, "setup": _my_setup(id), "livery": profile.livery_for(id)}


func _open_garage() -> void:
	if _garage:
		return
	_garage = GarageScreen.new()
	_menu_root.visible = false
	badge.visible = false
	add_child(_garage)
	_garage.open(car_stepper.value, profile)
	_garage.closed.connect(_on_garage_closed)
	_set_activity("garage")


## Online: tell the lobby what I'm doing (garage, car setup, settings).
func _set_activity(what: String) -> void:
	if Net.is_online() and Net.players.has(Net.my_id()):
		Net.update_me({"activity": what})


func _on_garage_closed(picked_car: String) -> void:
	_garage = null
	_set_activity("settings" if _settings else "lobby")
	_menu_root.visible = true
	badge.visible = true
	profile = TeamProfile.load_or_new()
	_refresh_badge()
	# Race the car you were working on, if the class allows it.
	_rebuild_car_options()
	for o in car_stepper.options:
		if o[0] == picked_car:
			car_stepper.set_value(picked_car)
	if Net.is_online():
		Net.update_me(_my_lobby_fields(car_stepper.value))
	_show(current_page)


# --- Settings, profile, grid size ---------------------------------------------

func _open_settings() -> void:
	if _settings or _garage:
		return
	_settings = SettingsScreen.new()
	_settings.open_garage = _open_garage
	_menu_root.visible = false
	badge.visible = false
	add_child(_settings)
	_settings.open(profile)
	_settings.closed.connect(_on_settings_closed)
	_set_activity("settings")


func _on_settings_closed() -> void:
	_settings = null
	_set_activity("garage" if _garage else "lobby")
	if _garage == null:
		_menu_root.visible = true
		badge.visible = true
		_show(current_page)
	_rebuild_car_options()   # power units may have changed
	_refresh_badge()


func _refresh_badge() -> void:
	if badge == null:
		return
	badge.show_profile(name_edit.text, profile)
	if profile_info:
		var owned: Array = profile.owned_ids()
		var names := []
		for id in owned:
			if GameData.cars.has(id):
				names.append(GameData.cars[id].display_name)
		profile_info.text = "Team budget %s\nGarage: %s\nSeasons played: %d" % [UpgradeCatalog.format_money(profile.money),
			", ".join(names) if not names.is_empty() else "no cars bought yet", SeasonStore.list().size()]


## The grid holds 25 cars of one class or 45 in a multi-class race; the AI
## stepper stops at that (minus you).
func _limit_grid() -> void:
	var most := RaceSettings.max_cars_for(str(class_stepper.value), _race_type()) - 1
	ai_stepper.max_value = most
	if int(ai_stepper.value) > most:
		ai_stepper.set_value(most)
		if not _building:
			_push_settings()


# --- Remembered race settings -------------------------------------------------
# The single race page and the online host lobby each keep the settings they
# were last left with, for every race type (circuit, rallycross, derby), in
# GameData.prefs["race_memory"] (saved to disk, so they survive a restart):
#   {"single": {"type": "rallycross", "circuit": {"track": "spa", "laps": 5 ...},
#               "rallycross": {...}}, "host": {...}}
# Seasons pick their own settings and guests see the host's, so neither uses it.

const MEMORY_KEY := "race_memory"
const MEMORY_SINGLE := "single"
const MEMORY_HOST := "host"
var _mem_slot := ""         ## "single" / "host" while that page is open, else ""
var _mem_type := "circuit"  ## the race type the steppers hold values for
var _mem_restoring := false


## Pref key -> stepper for everything remembered (besides the race type).
func _remembered_steppers() -> Dictionary:
	return {"track": track_stepper, "class": class_stepper, "car_filter": car_filter_stepper, "car": car_stepper,
		"tyre": tyre_stepper, "laps": laps_stepper, "ai": ai_stepper, "difficulty": difficulty_stepper,
		"time": tod_stepper, "clock": clock_stepper, "weather": weather_stepper,
		"weather_changes": weather_change_stepper, "grid": grid_stepper, "fuel": fuel_stepper,
		"tyre_wear": wear_stepper, "pit_stops": stops_stepper, "drivers": drivers_stepper,
		"safety_car": safety_car_stepper, "damage": damage_stepper, "car_setups": tuning_stepper,
		"upgrades": upgrades_stepper}


func _race_memory() -> Dictionary:
	var m = GameData.prefs.get(MEMORY_KEY, {})
	return m if m is Dictionary else {}


## Saves what the page shows now under race type `dsc` (default: the one picked).
func _remember_race(dsc := "") -> void:
	if _mem_slot == "" or _mem_restoring or _building:
		return
	if dsc == "":
		dsc = _race_type()
	var values := {}
	var steppers := _remembered_steppers()
	for k in steppers:
		values[k] = steppers[k].value
	var mem := _race_memory().duplicate(true)
	var slot: Dictionary = mem.get(_mem_slot, {})
	slot[dsc] = values
	slot["type"] = _race_type()
	mem[_mem_slot] = slot
	GameData.set_pref(MEMORY_KEY, mem)


## Brings back the settings this page (single or host) was last left with.
func _restore_race(slot_name: String) -> void:
	_mem_slot = slot_name
	var slot: Dictionary = _race_memory().get(slot_name, {})
	var dsc := str(slot.get("type", _race_type()))
	if not race_type_stepper.options.any(func(o): return o[0] == dsc):
		dsc = _race_type()
	_mem_restoring = true
	if dsc != _race_type():
		race_type_stepper.set_value(dsc)
		_on_race_type_changed(false)
	_mem_type = dsc
	var values: Dictionary = slot.get(dsc, {})
	if not values.is_empty():
		_apply_remembered(values)
	_mem_restoring = false
	_apply_race_type_rules()
	_refresh_cards()
	_setup_changed()


## Sets the steppers to saved values, skipping any that no longer fit (a car or
## track that's gone, a number out of range).
func _apply_remembered(values: Dictionary) -> void:
	var steppers := _remembered_steppers()
	for k in steppers:
		if not values.has(k):
			continue
		var st: Stepper = steppers[k]
		var v = values[k]
		if st.options.is_empty():
			if not (v is int or v is float):
				continue
			st.set_value(clampf(float(v), st.min_value, st.max_value) if v is float \
				else clampi(int(v), int(st.min_value), int(st.max_value)))
		elif st.options.any(func(o): return _same_value(o[0], v)):
			st.set_value(v)
		else:
			continue
		if st == class_stepper or st == car_filter_stepper:
			_rebuild_car_options()   # the car comes after these, so it's picked from the new list
			_limit_grid()
		elif st == car_stepper:
			GameData.prefs["car_id"] = v
	_limit_grid()


## Saved values come back from disk as the same types, but numbers may be
## int or float; anything else must match its type exactly.
static func _same_value(a, b) -> bool:
	var na := a is int or a is float
	var nb := b is int or b is float
	if na or nb:
		return na and nb and is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b
