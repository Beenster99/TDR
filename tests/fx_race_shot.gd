extends Node
## Screenshots of the race effects in a real race (needs a GPU or xvfb +
## mesa vulkan). Scenarios:
##   pit   - you box on lap 1; shot mid-stop (crew at work, car on jacks)
##   crash - a car is dropped in front of you; shot just after the hit
##   slide - your car is flicked sideways; shot of smoke and rubber marks
##   godot --path . res://tests/fx_race_shot.tscn -- <out.png> <scenario> [track] [seconds into it] --autodrive --zoom 0

var session: RaceSession
var scene: Node
var scenario := "pit"
var out := "user://fx_race.png"
var wait := 2.5
var _t0 := -1.0
var _done := false
var _armed := false


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else out
	scenario = a[1] if a.size() > 1 else scenario
	var track: String = a[2] if a.size() > 2 else "spa"
	wait = float(a[3]) if a.size() > 3 else wait
	var s := RaceSettings.new()
	s.seed = 3
	s.track_id = track
	s.laps = 3
	s.ai_count = 7
	s.damage_level = "full"
	s.damage_enabled = true
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.safety_car_enabled = false
	s.environment = {"time_h": 15.0, "weather": "dry"}
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": "bmw_m4_gt3"}], GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	get_tree().create_timer(600.0).timeout.connect(func(): print("[fx] gave up"); get_tree().quit(1))


func _physics_process(_delta: float) -> void:
	if _done or session == null:
		return
	var sim := session.sim
	if sim.phase != RaceSim.Phase.RACING:
		return
	var mine := session.local_car
	var me := sim.cars[mine]
	match scenario:
		"pit":
			if not _armed:
				_armed = true
				# start just before the pit entry so we don't wait a lap
				var t := sim.track
				var s0 := fposmod(sim.pits.commit_s - 120.0, t.length)
				me.pos = t.position_at(s0)
				me.heading = t.heading_at(s0)
				me.vel = me.forward() * 40.0
				me.track_idx = t.index_at(s0)
				me.track_s = s0
				session.request_pit(mine, {"box": true, "tyre": "race_slick", "fuel": 30.0})
			var p: Dictionary = sim.entries[mine].pit
			if p["phase"] == PitRules.PHASE_SERVICE and float(p["service_total"]) - float(p["service_left"]) >= wait:
				_shoot()
		"crash":
			if not _armed and sim.race_time > 9.0 and me.speed() > 40.0:
				_armed = true
				var other := sim.cars[(mine + 1) % sim.car_count()]
				other.pos = me.pos + me.forward() * 14.0
				other.heading = me.heading + 1.4
				other.vel = Vector2.ZERO
				_t0 = sim.race_time
			if _armed and sim.race_time - _t0 >= wait:
				_shoot()
		"slide":
			if not _armed and sim.race_time > 12.0 and me.speed() > 35.0:
				_armed = true
				me.yaw_rate = 1.6
				me.heading += 0.35
				_t0 = sim.race_time
			if _armed and sim.race_time - _t0 >= wait:
				_shoot()


func _shoot() -> void:
	_done = true
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[fx] saved ", out, " debris ", scene.world.debris.piece_count(), " marks ", scene.world.skid_marks.count())
	get_tree().quit()
