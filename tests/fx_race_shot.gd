extends Node
## Screenshots of the race effects in a real race (needs a GPU or xvfb +
## mesa vulkan). Scenarios:
##   pit   - you box on lap 1; shot mid-stop (crew at work, car on jacks)
##   crash - a car is dropped in front of you; shot just after the hit
##   slide - your car is flicked sideways; shot of smoke and rubber marks
##   crane / tractor - your car is put out of the race in the wall (crane) or
##           in the gravel (tractor); shot [seconds] after the vehicle is sent
##   marshals - a crash leaves debris just ahead of you; marshals clear it
##           under double yellows (you're held parked at the side); shot
##           [seconds] after they're sent
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
	s.safety_car_enabled = scenario in ["crane", "tractor"]
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


		"crane", "tractor":
			if not _armed and sim.race_time > 9.0 and me.speed() > 30.0:
				_armed = true
				var t := sim.track
				var k := t.index_at(me.track_s)
				var off := t.width_left[k] + (t.runoff - 1.0 if scenario == "crane" else 12.0)
				me.pos = t.position_at(me.track_s, -off)
				me.heading += 0.7
				me.vel = Vector2.ZERO
				me.track_idx = -1
				me.damage_engine = 1.0
				sim.entries[mine].dnf = true
			if _armed and _t0 < 0.0 and not sim.race_control.recovery_for(mine).is_empty():
				_t0 = sim.race_time
			if _t0 >= 0.0 and sim.race_time - _t0 >= wait:
				var job := sim.race_control.recovery_for(mine)
				print("[fx] recovery ", job.get("kind", "?"), " phase ", job.get("phase", "done"), " hoist ", job.get("hoist", 0.0))
				_shoot()


		"marshals":
			var t := sim.track
			if not _armed and sim.race_time > 9.0:
				_armed = true
				_park_s = me.track_s
				var at := fposmod(_park_s + 4.0, t.length)
				for k in 5:
					var p := t.position_at(at + k * 3.0 - 6.0, (k - 2) * 1.5)
					scene.world.impact(p, Vector2.from_angle(t.heading_at(at)) * 30.0, 1.2)
				TrackMarshals.add_debris(sim.race_control.debris, t.length, at, t.position_at(at), 2.0)
			if _armed:
				# Parked at the side of the track, watching.
				me.pos = t.position_at(_park_s, -t.width_left[t.index_at(_park_s)] - 3.0)
				me.heading = t.heading_at(_park_s)
				me.vel = Vector2.ZERO
				if _t0 < 0.0 and not sim.race_control.marshal_jobs.is_empty():
					_t0 = sim.race_time
				if _t0 >= 0.0 and sim.race_time - _t0 >= wait:
					print("[fx] marshals ", sim.race_control.marshal_jobs[0]["phase"] if not sim.race_control.marshal_jobs.is_empty() else "done")
					_shoot()


var _park_s := 0.0


func _shoot() -> void:
	_done = true
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[fx] saved ", out, " debris ", scene.world.debris.piece_count(), " marks ", scene.world.skid_marks.count())
	get_tree().quit()
