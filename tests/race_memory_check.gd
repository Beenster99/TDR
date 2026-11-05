extends Node
## Race settings are remembered between races and restarts: the single race
## page and the host lobby each keep their last settings, per race type.
## Needs the autoloads, so it runs as a scene. It saves to a test settings
## file (not the player's), deleted before and after.
##   godot --headless --path . res://tests/race_memory_check.tscn -- --settings user://race_memory_test.cfg

const TEST_CFG := "user://race_memory_test.cfg"
var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _change(st: Stepper, v) -> void:   # as if the player picked it
	st.set_value(v)
	st.value_changed.emit(v)


func _menu() -> Node:
	var m: Node = load(GameData.SCENE_MENU).instantiate()
	add_child(m)
	await get_tree().process_frame
	return m


func _ready() -> void:
	if not GameData.persist_prefs:
		print("  FAIL run with -- --settings %s" % TEST_CFG)
		get_tree().quit(1)
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CFG))
	GameData.prefs.erase("race_memory")
	var m := await _menu()
	m._restore_race("single")
	m._show("single")
	check(int(m.laps_stepper.value) == 3, "first time: default laps")
	_change(m.track_stepper, "spa")
	_change(m.laps_stepper, 7)
	_change(m.weather_stepper, "heavy_rain")
	_change(m.ai_stepper, 11)
	var circuit_car: String = m.car_stepper.value
	_change(m.race_type_stepper, "rallycross")
	check(int(m.laps_stepper.value) == 6, "new race type gets its own defaults (6 laps)")
	var rx_track: String = m.track_stepper.options[-1][0]
	_change(m.track_stepper, rx_track)
	_change(m.laps_stepper, 4)
	_change(m.race_type_stepper, "circuit")
	check(m.track_stepper.value == "spa", "back to circuit: Spa again")
	check(int(m.laps_stepper.value) == 7, "back to circuit: 7 laps again")
	check(m.weather_stepper.value == "heavy_rain", "back to circuit: heavy rain again")
	check(int(m.ai_stepper.value) == 11, "back to circuit: 11 AI again")
	check(m.car_stepper.value == circuit_car, "back to circuit: same car")
	_change(m.race_type_stepper, "rallycross")
	check(m.track_stepper.value == rx_track and int(m.laps_stepper.value) == 4, "back to rallycross: its track and 4 laps")
	m.queue_free()
	await get_tree().process_frame

	# A restart: only what's on disk is left.
	GameData.prefs.erase("race_memory")
	GameData.load_prefs()
	check(GameData.prefs.has("race_memory"), "saved to the settings file")
	m = await _menu()
	m._show("main")
	m._restore_race("single")
	m._show("single")
	check(m._race_type() == "rallycross", "after restart: last race type (rallycross)")
	check(m.track_stepper.value == rx_track and int(m.laps_stepper.value) == 4, "after restart: rallycross track and laps")
	_change(m.race_type_stepper, "circuit")
	check(m.track_stepper.value == "spa" and int(m.laps_stepper.value) == 7, "after restart: circuit settings too")
	# The host lobby keeps its own.
	m._show("main")
	m._restore_race("host")
	check(int(m.laps_stepper.value) == 7, "host lobby with nothing saved keeps what's shown")
	_change(m.laps_stepper, 12)
	m._show("main")
	m._restore_race("single")
	check(int(m.laps_stepper.value) == 7, "single race not changed by the host lobby")
	m._show("main")
	m._restore_race("host")
	check(int(m.laps_stepper.value) == 12, "host lobby keeps its 12 laps")
	# Hosting for real: the lobby starts with the remembered settings.
	m._show("main")
	m._on_host()
	check(Net.is_server() and Net.settings.laps == 12, "hosting sends the remembered 12 laps")
	_change(m.laps_stepper, 9)
	check(Net.settings.laps == 9 and int(GameData.prefs["race_memory"]["host"]["circuit"]["laps"]) == 9,
		"a change in the lobby is sent and remembered")
	m._on_leave()
	# A season page doesn't change what's remembered.
	m._show("season_new")
	_change(m.laps_stepper, 2)
	m._restore_race("single")
	check(int(m.laps_stepper.value) == 7, "season pages don't overwrite it")
	# A saved car or track that no longer exists is skipped.
	var mem: Dictionary = GameData.prefs["race_memory"].duplicate(true)
	mem["single"]["circuit"]["track"] = "no_such_track"
	GameData.prefs["race_memory"] = mem
	m._show("main")
	m._restore_race("single")
	check(m.track_stepper.options.any(func(o): return o[0] == m.track_stepper.value), "unknown saved track is ignored")
	m.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CFG))
	print("race memory: %s" % ("all ok" if fails == 0 else "%d FAILED" % fails))
	get_tree().quit(1 if fails > 0 else 0)
