extends Node
## Screenshots of a rallycross race (needs a GPU or xvfb + mesa vulkan).
## The AI drives your car; the shot is taken once the car has been racing
## for [seconds] and is in the chosen place:
##   dirt  - on a dirt stretch at speed (dust or mud behind the cars)
##   joker - on the joker lane
##   any   - wherever it is
##   godot --path . res://tests/rx_shot.tscn -- <out.png> <dirt|joker|any> [track] [seconds] --car <id> --autodrive --zoom 0.15
## Add --wet for a rain race (mud instead of dust).

var session: RaceSession
var scene: Node
var where := "dirt"
var out := "user://rx.png"
var wait := 6.0
var _done := false
var _dirt_t := 0.0


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else out
	where = a[1] if a.size() > 1 else where
	var track: String = a[2] if a.size() > 2 else "holjes"
	wait = float(a[3]) if a.size() > 3 else wait
	var car := str(GameData.arg("car", "volkswagen_polo_r_supercar"))
	var s := RaceSettings.new()
	s.discipline = RaceSettings.DISCIPLINE_RALLYCROSS
	s.seed = 5
	s.track_id = track
	s.laps = 4
	s.ai_count = 5
	s.damage_enabled = true
	var wet := "--wet" in OS.get_cmdline_user_args()
	s.environment = {"time_h": 14.0, "weather": "heavy_rain" if wet else "dry"}
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": car}], GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	get_tree().create_timer(400.0).timeout.connect(func(): print("[rx] gave up"); get_tree().quit(1))


func _physics_process(_delta: float) -> void:
	if _done or session == null:
		return
	var sim := session.sim
	if sim.phase != RaceSim.Phase.RACING:
		return
	var me := sim.cars[session.local_car]
	if where == "joker" and scene.autodrive and scene.autodrive.joker_lap != 1:
		scene.autodrive.joker_lap = 1  # take it on the first lap
	if sim.race_time < wait:
		return
	var ok := true
	match where:
		"dirt":  # well into a dirt stretch, so the dust has built up
			_dirt_t = _dirt_t + 1.0 / 60.0 if me.dirt > 0.9 and not me.in_joker else 0.0
			ok = _dirt_t > 1.6 and me.speed() > 15.0
		"joker":
			ok = me.in_joker and track_frac(sim, me) > 0.3
	if ok:
		_shoot()


func track_frac(sim: RaceSim, me: CarState) -> float:
	return sim.track.project_joker(me.pos)["d"] / maxf(sim.track.joker_length, 1.0)


func _shoot() -> void:
	_done = true
	if "--nojoker" in OS.get_cmdline_user_args():  # debugging: hide the joker lane
		var j := scene.find_child("Joker", true, false)
		if j:
			j.visible = false
	# a few frames so the particles catch up
	for i in 3:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[rx] saved ", out, " t=", session.sim.race_time)
	get_tree().quit()
