extends Node
## Screenshot of the safety car out on track, camera on it (needs a GPU or
## xvfb + mesa vulkan). zoom: pixels per metre (8 close, 1 far).
##   godot --path . res://tests/sc_shot.tscn -- <out.png> [zoom] [lights: amber|green] --autodrive

var out := "user://sc.png"
var zoom := 8.0
var lights := "amber"
var scene: Node
var session: RaceSession


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else out
	zoom = float(a[1]) if a.size() > 1 else zoom
	lights = a[2] if a.size() > 2 else lights
	GameData.persist_prefs = false
	process_priority = 1000
	var s := RaceSettings.new()
	s.seed = 5
	s.track_id = "spielberg"
	s.laps = 5
	s.ai_count = 7
	s.environment = {"time_h": 15.0, "weather": "dry"}
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": "bmw_m4_gt3"}], GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	while session.sim.race_time < 2.0:
		await get_tree().process_frame
	session.sim.race_control.deploy_safety_car("Test")
	while session.sim.race_time < 9.0:
		await get_tree().process_frame
	for k in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	get_tree().quit()


func _process(_d: float) -> void:
	if scene == null or session == null:
		return
	var rc := session.sim.race_control
	if rc.sc_visible:
		rc.sc_lights = lights
		scene.world.set_safety_car(true, rc.sc_pos, rc.sc_heading, rc.sc_speed, lights)
		scene.world.set_camera(rc.sc_pos, zoom)
