extends Node
## Autoload "GameData" (core module): the game's shared state, which any
## module may read. It knows nothing about other modules' types, so core
## stays at the bottom of the dependency tree:
##   - content: filled at startup by the game module (Game autoload)
##   - the race session handed from the menu to the race scene
##   - the parsed command line
##   - the paths of the two main scenes
##   - the player's preferences (prefs), saved on this machine, and the list
##     of options the Settings screen shows (register_setting)

const SCENE_MENU := "res://modules/ui/main_menu.tscn"
const SCENE_RACE := "res://modules/game/race.tscn"
const SCENE_SPLASH := "res://modules/ui/splash.tscn"
## Where prefs are saved (--settings user://other.cfg uses another file).
const SETTINGS_PATH := "user://settings.cfg"
## Settings screen sections, in order.
const SECTIONS := ["gameplay", "controller", "graphics", "sound", "garage", "debug"]

## A pref changed through set_pref() (the Settings screen uses it), so
## anything showing or applying that pref can follow along.
signal pref_changed(key: String, value)

var cars: Dictionary = {}               ## car id -> CarDefinition (cars module)
var tyres: Dictionary = {}              ## compound id -> TyreCompound (physics module)
var tracks: Array[Dictionary] = []      ## [{id, name, location, length_m}] (tracks module)
var drivers: Array = []                 ## AI drivers (ai module)

## Session the race scene should run (offline, server or client). A
## RaceSession from the multiplayer module; untyped so core doesn't depend on it.
var active_session = null
## The championship being played, if any: a Season from the season module
## (untyped, like active_session). The menu, lobby and race scene share it.
var season = null
## This player's own choices, kept between races.
##   driving_help: 2 = full (traction control, ABS, stability), 1 = TC + ABS, 0 = off
##   zoom: camera zoom level the player last used (0 = close, 1 = whole track)
## Every registered setting (below) is in here too, with its default until
## the player changes it. Saved to SETTINGS_PATH when changed with set_pref()
## and when the game closes.
var prefs: Dictionary = {"driving_help": 2, "zoom": 0.15}
## Options shown on the Settings screen, in order:
## [{section, key, label, kind ("choice" | "number"), options [[value, label]]
##   (choice) or min/max/step/suffix (number), default, help}]
var settings_catalog: Array = []
## False for test bots and servers, so they never touch the player's settings.
var persist_prefs := true
var _settings_path := SETTINGS_PATH
## Parsed command line (after "--"), e.g. --server --port 7777 --autodrive
var args: Dictionary = {}


func _ready() -> void:
	_parse_args()
	_settings_path = str(args.get("settings", SETTINGS_PATH))
	persist_prefs = args.has("settings") or not (args.has("server") or args.has("autodrive") \
		or DisplayServer.get_name() == "headless")
	_register_defaults()
	load_prefs()
	Units.prefs = prefs
	if args.has("time-scale"):
		Engine.time_scale = float(args["time-scale"])
		Engine.max_physics_steps_per_frame = 16


func _parse_args() -> void:
	var list := OS.get_cmdline_user_args()
	var i := 0
	while i < list.size():
		var a: String = list[i]
		if a.begins_with("--"):
			var key := a.substr(2)
			if "=" in key:
				var kv := key.split("=", true, 1)
				args[kv[0]] = kv[1]
			elif i + 1 < list.size() and not list[i + 1].begins_with("--"):
				args[key] = list[i + 1]
				i += 1
			else:
				args[key] = true
		i += 1


func arg(name: String, default = null):
	return args.get(name, default)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		save_prefs()


# --- Settings ----------------------------------------------------------------

## Adds an option with a fixed list of choices to a Settings section
## ("gameplay", "controller", "graphics", "sound", "garage", "debug"). options: [[value, label], ...].
## Any module may call this at start-up; the Settings screen shows it, prefs
## holds its value (the default until the player changes it) and it's saved.
func register_setting(section: String, key: String, label: String, options: Array, default, help := "") -> void:
	_register({"section": section, "key": key, "label": label, "kind": "choice", "options": options,
		"default": default, "help": help})


## Adds a number option (a slider-like stepper), e.g. a volume 0..100 %.
func register_number(section: String, key: String, label: String, min_v: float, max_v: float, step: float,
		default: float, suffix := "", help := "") -> void:
	_register({"section": section, "key": key, "label": label, "kind": "number", "min": min_v, "max": max_v,
		"step": step, "suffix": suffix, "default": default, "help": help})


func _register(entry: Dictionary) -> void:
	for i in settings_catalog.size():
		if settings_catalog[i]["key"] == entry["key"]:
			settings_catalog[i] = entry   # re-registering replaces (label, options), keeps the value
			return
	settings_catalog.append(entry)
	if not prefs.has(entry["key"]):
		prefs[entry["key"]] = entry["default"]


## The options in one Settings section, in the order they were registered.
func settings_in(section: String) -> Array:
	return settings_catalog.filter(func(e): return e["section"] == section)


func setting_info(key: String) -> Dictionary:
	for e in settings_catalog:
		if e["key"] == key:
			return e
	return {}


## Changes a pref, saves it and tells anyone listening (pref_changed).
func set_pref(key: String, value) -> void:
	if prefs.get(key) == value:
		return
	prefs[key] = value
	save_prefs()
	pref_changed.emit(key, value)


## Puts every registered setting back to its default.
func reset_settings() -> void:
	for e in settings_catalog:
		set_pref(e["key"], e["default"])


func load_prefs() -> void:
	if not persist_prefs:
		return
	var cfg := ConfigFile.new()
	if cfg.load(_settings_path) != OK:
		return
	for key in cfg.get_section_keys("prefs") if cfg.has_section("prefs") else []:
		var v = cfg.get_value("prefs", key)
		var info := setting_info(key)
		# Keep a saved value only if it's still one of the choices.
		if info.get("kind") == "choice" and not info["options"].any(func(o): return o[0] == v):
			continue
		prefs[key] = v


func save_prefs() -> void:
	if not persist_prefs:
		return
	var cfg := ConfigFile.new()
	for key in prefs:
		cfg.set_value("prefs", key, prefs[key])
	cfg.save(_settings_path)


## The game's own options. Other modules add theirs with register_setting().
func _register_defaults() -> void:
	# Gameplay: driving aids (read by the race when it starts)
	register_setting("gameplay", "driving_help", "Driving help", [[2, "Full (stability, traction, ABS)"],
		[1, "Some (traction, ABS)"], [0, "Off"]], 2, "Electronic aids on your car. Stability control stops spins, traction control stops wheelspin, ABS stops the wheels locking under braking.")
	register_setting("gameplay", "aid_braking_zones", "Braking zones", [[true, "On"], [false, "Off"]], true,
		"Coloured braking zones on the racing line: green to keep the throttle down, yellow to lift, red to brake.")
	register_setting("gameplay", "aid_track_assist", "Track assist", [[0, "Off"], [1, "Light"], [2, "Strong"]], 1,
		"A gentle pull on the steering that helps you stay inside the track limits and on the driving line.")
	register_setting("gameplay", "aid_racing_line", "Racing line", [[true, "On"], [false, "Off"]], true,
		"Shows the ideal line through each corner.")
	register_setting("gameplay", "pit_drive_in", "Pit stops", [["self", "Drive in yourself"], ["auto", "Automatic"]], "self",
		"Drive in yourself: when you've called a stop, follow the pit line, be down to the speed limit by the limit line and stop on your box (overshoot and it costs time). Automatic: the car drives itself in and out.")
	register_setting("gameplay", "aid_pit_guide", "Pit lane guide", [[true, "On"], [false, "Off"]], true,
		"When you drive in yourself: a line into the pit lane and onto your box, red where you must brake for the speed limit or to stop, plus distance and brake cues on screen.")
	register_setting("gameplay", "pit_menu", "Pit call menu", [[true, "On"], [false, "Off"]], true,
		"Single player: calling a stop opens a quick menu (tyres, which tyres, front splitter, rear wing, fuel) and pauses the race while it's open.")
	register_setting("gameplay", "manual_gears", "Gears", [[false, "Automatic"], [true, "Manual"]], false,
		"Manual: change gear yourself with the shift buttons.")
	register_setting("gameplay", "pit_crew_game", "Pit crew mini-game: be a wheel gunner", [[false, "Off: the AI crew do the stop"], [true, "On"]], false,
		"At your stops you're one of the two wheel gunners in the box: run to each wheel (stick / WASD), hold the gun (RT / A / Space) to undo the nut, then hold it again and let go in the green. The driver guns the left side, a co-op team mate the right. Off, your AI crew do the stop at their own pace.")
	register_setting("gameplay", "hud_timing_tower", "Timing tower", [[true, "Show"], [false, "Hide"]], true,
		"The column on the left of the race screen: position, make, driver, last lap and gap to the car ahead.")
	register_setting("gameplay", "highlight_me", "Highlight my car", [[true, "On"], [false, "Off"]], true,
		"A soft gold outline on the ground round your own car (or your team's car on the pit wall), so you can find it at any zoom.")
	register_setting("gameplay", "highlight_players", "Highlight other players", [[true, "On"], [false, "Off"]], true,
		"Online: a faint blue outline round cars driven by other people, so you can tell them from the AI.")
	register_setting("gameplay", "units", "Units of measure", [["metric", "Metric (km/h, °C, km, litres)"],
		["uk", "UK (mph, °C, miles, litres)"], ["imperial", "US (mph, °F, miles, gallons)"]], "metric",
		"How speeds, temperatures, distances and fuel are shown.")
	register_setting("gameplay", "power_unit", "Power", [["hp", "Horsepower (hp)"], ["kw", "Kilowatts (kW)"],
		["ps", "Metric horsepower (PS)"]], "hp", "How engine power is shown in the garage and car lists.")
	# Controller (the key and button bindings are listed under these, see InputSetup)
	register_number("controller", "pad_deadzone", "Stick dead zone", 2, 30, 2, 12, "%",
		"How far a stick has to move before it counts. Raise it if the car or the menus drift on their own.")
	# Graphics
	register_setting("graphics", "display_mode", "Display", [["fullscreen", "Fullscreen"],
		["exclusive", "Exclusive fullscreen"], ["windowed", "Window"]], "fullscreen")
	register_setting("graphics", "vsync", "V-sync", [[true, "On"], [false, "Off"]], true,
		"On stops screen tearing; off can feel more responsive.")
	register_setting("graphics", "max_fps", "Frame rate limit", [[0, "Unlimited"], [30, "30"], [60, "60"],
		[120, "120"], [144, "144"], [165, "165"], [240, "240"]], 0)
	register_number("graphics", "render_scale", "3D resolution", 50, 100, 5, 100, "%",
		"Lower renders the 3D world at fewer pixels and upscales it (FSR), for more speed at 4K.")
	register_setting("graphics", "msaa", "Anti-aliasing", [[0, "Off"], [1, "2x MSAA"], [2, "4x MSAA"],
		[3, "8x MSAA"]], 1)
	register_setting("graphics", "shadows", "Shadows", [[0, "Off"], [1, "Medium"], [2, "High"], [3, "Ultra"]], 3)
	register_setting("graphics", "ssao", "Ambient occlusion", [[true, "On"], [false, "Off"]], true)
	register_setting("graphics", "glow", "Glow and lights bloom", [[true, "On"], [false, "Off"]], true)
	register_setting("graphics", "trees", "Trees", [[0.0, "None"], [0.5, "Few"], [1.0, "Normal"],
		[1.5, "Dense"]], 1.0, "Takes effect at the next race.")
	register_setting("graphics", "camera_tilt", "Camera tilt", [[0.0, "Straight down"], [6.0, "Slight"],
		[12.0, "Normal"], [20.0, "Strong"], [28.0, "Very strong"]], 12.0, "How far the camera leans to show hills and the sides of cars.")
	register_setting("graphics", "menu_video", "Menu background", [[true, "Race highlights"], [false, "Plain"]], true)
	# Sound (0..100 %)
	register_number("sound", "vol_master", "Master volume", 0, 100, 5, 100, "%")
	register_number("sound", "vol_engine", "Engines", 0, 100, 5, 100, "%")
	register_number("sound", "vol_effects", "Tyres, crashes and effects", 0, 100, 5, 100, "%")
	register_number("sound", "vol_ui", "Menus", 0, 100, 5, 80, "%")
	register_number("sound", "vol_radio", "Team radio", 0, 100, 5, 90, "%")
	register_setting("sound", "radio_voice", "Radio read-out", [[true, "On"], [false, "Off"]], true,
		"Reads pit wall messages to the driver out loud, with radio crackle (uses the computer's own voice).")
	register_setting("sound", "splash_sound", "Intro sound", [[true, "On"], [false, "Off"]], true)
	# Debug
	register_setting("debug", "show_fps", "Frame rate counter", [[false, "Off"], [true, "On"]], false)
	register_setting("debug", "skip_splash", "Intro screen", [[false, "Show"], [true, "Skip"]], false)
