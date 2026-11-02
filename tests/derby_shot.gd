extends Node
## Screenshots of a Demolition Derby (needs a GPU or xvfb + mesa vulkan).
##   godot --path . res://tests/derby_shot.tscn -- <out.png> <scenario> [track] [seconds] [car] --autodrive --zoom 0.6
## Scenarios:
##   race   - a 15-car derby; shot [seconds] into it
##   wrecks - a row of cars from new to wrecked, parked by your car: crumpled
##            bodywork, cracked and smashed windscreens, lids open and torn
##            off, steam, smoke and fire, parts on the ground
##   jump   - shot while your car is in the air off a jump
##   dirt   - shot while your car is flat out on the dirt (dust and mud)

var session: RaceSession
var scene: Node
var scenario := "race"
var out := "user://derby.png"
var wait := 20.0
var _t0 := -1.0
var _done := false
var _armed := false


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else out
	scenario = a[1] if a.size() > 1 else scenario
	var track: String = a[2] if a.size() > 2 else "derby_rustbelt_eight"
	wait = float(a[3]) if a.size() > 3 else wait
	var car: String = a[4] if a.size() > 4 else "derby_brannock_sovereign"
	var s := RaceSettings.new()
	s.seed = 7
	s.track_id = track
	s.laps = 10
	s.ai_count = 14 if scenario == "race" else (7 if scenario == "wrecks" else 5)
	s.environment = {"time_of_day_h": 17.5, "weather": "dry"}
	s.apply_derby_rules()
	s.countdown_s = 1.0
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": car}], GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	get_tree().create_timer(900.0).timeout.connect(func(): print("[derby] gave up"); get_tree().quit(1))


func _physics_process(_delta: float) -> void:
	if _done or session == null:
		return
	var sim := session.sim
	if sim.tick % 600 == 0:
		print("[derby] tick ", sim.tick, " phase ", sim.phase, " t ", snappedf(sim.race_time, 0.1), " fps ", Engine.get_frames_per_second())
	if sim.phase != RaceSim.Phase.RACING:
		return
	var mine := session.local_car
	var me := sim.cars[mine]
	match scenario:
		"race":
			if sim.race_time >= wait:
				_shoot()
		"jump":
			if me.air_h > 0.8 and sim.race_time > 3.0:
				_shoot()
		"dirt":
			if sim.track.dirt_at(me.track_s) > 0.9 and me.speed() > 18.0 and sim.race_time > wait:
				_shoot()
		"wrecks":
			if not _armed and sim.race_time > 1.0:
				_armed = true
				_t0 = sim.race_time
				var t := sim.track
				var s0 := me.track_s + 30.0
				var levels := [0.0, 0.25, 0.45, 0.6, 0.75, 0.9, 1.0]
				var k := 0
				for i in sim.car_count():
					if i == mine:
						continue
					if k >= levels.size():
						break
					var c := sim.cars[i]
					var lv: float = levels[k]
					var side := -1.0 if k % 2 == 0 else 1.0
					c.pos = t.position_at(s0 + k * 3.2, side * 3.2)
					c.heading = t.heading_at(s0) + side * 0.35
					c.vel = Vector2.ZERO
					c.track_idx = t.index_at(s0 + k * 3.2)
					c.body_damage = PackedFloat64Array([lv, lv * 0.7, lv * (0.9 if k % 2 == 0 else 0.3), lv * (0.3 if k % 2 == 0 else 0.9)])
					c.damage_engine = minf(lv * 1.05, 0.99)
					sim.entries[i].dnf = true
					k += 1
				me.vel = Vector2.ZERO
			if _armed:
				me.vel = Vector2.ZERO
				for i in sim.car_count():
					if i != mine and sim.entries[i].dnf:
						sim.cars[i].vel = Vector2.ZERO
						sim.cars[i].yaw_rate = 0.0
			if _armed and sim.race_time - _t0 >= wait:
				_shoot()


func _shoot() -> void:
	_done = true
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[derby] saved ", out, " debris ", scene.world.debris.piece_count())
	get_tree().quit()
