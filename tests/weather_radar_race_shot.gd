extends Node
## The pit wall's weather radar in a real race (needs the autoloads, so it
## runs as a scene): changing weather at Spa, we hand the car to the AI
## co-driver and watch from the pit wall. Checks the radar draws and the
## forecast agrees with the race's weather.
##   godot --headless --path . res://tests/weather_radar_race_shot.tscn
## With a screen (xvfb, --rendering-driver opengl3): add -- <out.png>.

var session: RaceSession
var scene: Node
var out := ""
var fails := 0
var _handed := false
var _opened_at := -1.0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else ""
	var s := RaceSettings.new()
	s.seed = 12
	s.track_id = "spa"
	s.laps = 3
	s.ai_count = 7
	s.drivers_per_car = 2
	s.safety_car_enabled = false
	s.environment = {"time_of_day_h": 15.0, "weather": "light_rain", "weather_changes": true}
	var humans := [{"name": "You", "car_id": "bmw_m4_gt3", "crew": [{"peer_id": 0, "name": "You", "role": RaceEntry.ROLE_DRIVER}]}]
	var start := RaceFactory.plan(s, humans, GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	get_tree().create_timer(1500.0).timeout.connect(func(): print("[radar] gave up"); _end())


func _physics_process(_delta: float) -> void:
	if session == null:
		return
	if not _handed and session.local_car >= 0:
		_handed = true
		session.request_role_swap(session.local_car, 0, RaceEntry.AI_PEER)
	if session.sim.phase != RaceSim.Phase.RACING:
		return
	var pw: StrategistScreen = scene.pit_wall
	if _opened_at < 0.0:
		pw.open()
		_opened_at = session.sim.race_time
		return
	if session.sim.race_time - _opened_at < 4.0:
		return
	set_physics_process(false)
	var f := session.telemetry.forecast
	check(pw.visible, "the pit wall is open")
	check(pw.radar._rain_tex != null, "the radar has drawn its rain picture")
	check(absf(f.truth_at(f.centre, f.elapsed) - session.sim.env.rain) < 0.001, "the radar's rain at the track is the race's rain")
	print("       %s; moving %s %d km/h" % [f.summary(), f.heading_name(), int(f.wind_speed * 3.6)])
	if out != "":
		# Main still draws the co-op console over the full pit wall (fixed by
		# the movable panels change): hide it for a clean picture.
		if scene.crew:
			scene.crew.visible = false
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out)
		print("  saved " + out)
	_end()


func _end() -> void:
	print("PASS" if fails == 0 else "FAIL (%d)" % fails)
	get_tree().quit(1 if fails > 0 else 0)
