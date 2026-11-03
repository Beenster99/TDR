extends Node
## Screenshot of race control's "give the place back" order in a real race:
## the car to let past has an orange-red outline and a LET PAST tag, the HUD
## names it (and points to it from the screen edge when it's out of view).
## Needs a GPU or xvfb + mesa vulkan:
##   godot --path . res://tests/give_back_shot.tscn -- <out.png> [track] [behind|ahead|sc|<n places ahead>] --autodrive --zoom 0.3

var session: RaceSession
var out := "user://give_back.png"
var who := "behind"
var _t0 := -1.0
var _done := false
var _victim := -1


func _ready() -> void:
	process_physics_priority = 100   # after the race steps, so our order stands each frame
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else out
	var track: String = a[1] if a.size() > 1 else "spa"
	who = a[2] if a.size() > 2 else who
	var s := RaceSettings.new()
	s.seed = 3
	s.track_id = track
	s.laps = 3
	s.ai_count = 7
	s.environment = {"time_h": 15.0, "weather": "dry"}
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": "bmw_m4_gt3"}], GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	add_child(load("res://modules/game/race.tscn").instantiate())
	get_tree().create_timer(300.0).timeout.connect(func(): print("[gb] gave up"); get_tree().quit(1))


func _physics_process(_delta: float) -> void:
	if session == null:
		return
	var sim := session.sim
	if sim.phase != RaceSim.Phase.RACING or sim.race_time < 14.0:
		return
	var mine := session.local_car
	var rc := sim.race_control
	if _t0 < 0.0:
		_t0 = sim.race_time
		var p := sim.running_order.find(mine)
		var j := -2
		if who == "behind":
			j = sim.running_order[p + 1] if p + 1 < sim.running_order.size() else sim.running_order[p - 1]
		elif who == "ahead":
			j = sim.running_order[maxi(p - 1, 0)] if p > 0 else sim.running_order[1]
		if who == "sc":
			rc._deploy_sc("Test")
		if who.is_valid_int():   # n places ahead in the running order
			j = sim.running_order[maxi(p - int(who), 0)]
		_victim = j
		print("[gb] told to give the place back to ", "the safety car" if j == -2 else sim.entries[j].driver_name)
	# Hold the order for the picture (the autodrive would give the place back).
	rc.give_back[mine] = {"victim": _victim, "until": sim.race_time + 9.0, "why": "Overtaking under yellow flags"}
	if not _done and sim.race_time - _t0 >= (8.0 if who == "sc" else 4.0):
		_shoot()


func _shoot() -> void:
	_done = true
	var sc = get_child(0)
	print("[gb] before draw: order ", session.sim.race_control.give_back, " scene target ", sc._give_back_to,
		" hud ", sc.hud.give_back_to, " flags shown ", sc.hud.item_shown("flags"), " same session ", sc.session == session)
	for k in 3:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[gb] saved ", out, " order still on: ", session.sim.race_control.give_back.has(session.local_car))
	get_tree().quit()
