extends Node
## Screenshots of the driver's own pit stop (needs a GPU or xvfb):
##   approach - box called, a little before the pit lane: the guide line,
##              red where to brake for the limit line, and the HUD cues
##   box      - in the lane at the limit, closing on the box marks
##   menu     - the pit call menu over the race (single player)
##   godot --path . res://tests/pit_guide_shot.tscn -- <out.png> <scenario> [track] [seconds]

var session: RaceSession
var scene: Node
var scenario := "approach"
var out := "user://pit_guide.png"
var wait := 1.5
var _t0 := -1.0
var _done := false
var _armed := false


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else out
	scenario = a[1] if a.size() > 1 else scenario
	var track: String = a[2] if a.size() > 2 else "spielberg"
	wait = float(a[3]) if a.size() > 3 else wait
	var s := RaceSettings.new()
	s.seed = 3
	s.track_id = track
	s.laps = 5
	s.ai_count = 5
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.damage_level = "full"
	s.damage_enabled = true
	s.safety_car_enabled = false
	s.tuning_enabled = true
	s.environment = {"time_h": 14.0, "weather": "dry"}
	GameData.prefs["zoom"] = 0.3 if scenario == "approach" else 0.12
	GameData.prefs["pit_drive_in"] = "self"
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": "bmw_m4_gt3"}], GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	get_tree().create_timer(900.0).timeout.connect(func(): print("[pit guide] gave up"); get_tree().quit(1))


func _place(me: CarState, pos: Vector2, heading: float, speed: float) -> void:
	var t := session.sim.track
	me.pos = pos
	me.heading = heading
	me.vel = Vector2.from_angle(heading) * speed
	me.yaw_rate = 0.0
	var q := t.project(pos)
	me.track_idx = q["idx"]
	me.track_s = q["s"]


func _physics_process(_delta: float) -> void:
	if _done or session == null:
		return
	var sim := session.sim
	if sim.phase != RaceSim.Phase.RACING:
		return
	var mine := session.local_car
	var me := sim.cars[mine]
	var t := sim.track
	if not _armed:
		_armed = true
		_t0 = sim.race_time
		match scenario:
			"approach":
				var s0 := fposmod(sim.pits.commit_s + 40.0, t.length)
				_place(me, t.position_at(s0), t.heading_at(s0), 52.0)
				session.request_pit(mine, {"box": true})
			"box":
				var g := sim.pits.guide_line(mine)
				var d := float(g["box_d"]) - 42.0
				var pts: PackedVector2Array = g["points"]
				var ds: PackedFloat64Array = g["dist"]
				var k := 0
				while k < ds.size() - 2 and ds[k] < d:
					k += 1
				_place(me, pts[k], (pts[k + 1] - pts[k]).angle(), 13.0)
				var p: Dictionary = sim.entries[mine].pit
				session.request_pit(mine, {"box": true})
				p["phase"] = PitRules.PHASE_LIMIT
				p["auto"] = false
				p["limiter"] = true
			"menu":
				scene.pit_menu.open(mine)
	if sim.race_time - _t0 >= wait or (scenario == "menu" and Time.get_ticks_msec() > 0 and _armed and sim.race_time - _t0 >= 0.0 and Engine.get_physics_frames() % 120 == 0):
		_shoot()


func _shoot() -> void:
	_done = true
	for k in 3:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	var info := session.sim.pits.guide_info(session.local_car)
	print("[pit guide] saved ", out, " ", info)
	get_tree().quit()
