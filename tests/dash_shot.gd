extends Node
## The GT3-style dash (speed item) and the sectors bar in each flag colour,
## cropped from a race (needs a GPU or xvfb + mesa vulkan).
##   godot --path . res://tests/dash_shot.tscn -- <out_dir>

var out := "user://"
var scene: Node
var session: RaceSession


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else out
	GameData.persist_prefs = false
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
	while session.sim.race_time < 40.0:
		await get_tree().process_frame
	var hud: RaceHud = scene.hud
	for f in [["none", Color(0, 0, 0, 0)], ["yellow", RaceHud.DASH_YELLOW], ["red", RaceHud.DASH_RED],
			["blue", RaceHud.DASH_BLUE], ["white", RaceHud.DASH_WHITE]]:
		hud.dash_preview = f[1]
		hud.queue_redraw()
		for k in 2:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.path_join("dash_%s.png" % f[0]))
	get_tree().quit()
