extends Node
## Screenshots of a co-op pit stop in a real race (needs a GPU or xvfb + mesa
## vulkan). You drive car share 1 (windscreen, then your tyre job) with two
## team mates on this machine played by the autoplay: a pit crew player (lays
## out the tyres and guns, the air lance, then their tyre job) and the
## strategist (fuel man). Your own jobs are played too with --crew-autoplay.
##   godot --path . res://tests/coop_pit_shot.tscn -- <out.png> <when> [track] [seconds] --autodrive --crew-autoplay
## when: "call" <seconds> after the box call (tyres being laid out), "box"
## <seconds> into the stop, "after" <seconds> after the stop. A crew of two
## (no pit crew player) with --crew2.

var session: RaceSession
var scene: Node
var when := "box"
var out := "user://coop_pit.png"
var wait := 6.0
var _t0 := -1.0
var _t1 := -1.0
var _done := false
var _armed := false
var _mates: Array = []


## A team mate's view of the race for their PitCrewGame (what a RaceSession
## would give them on their own machine).
class Mate:
	extends RefCounted
	var real: RaceSession
	var sim: RaceSim
	var local_car := -1
	var team_car := 0
	var local_role := ""
	var local_peer := 0

	func request_pit(car: int, changes: Dictionary) -> void:
		real.request_pit(car, changes)


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else out
	when = a[1] if a.size() > 1 else when
	var track: String = a[2] if a.size() > 2 else "spa"
	wait = float(a[3]) if a.size() > 3 else wait
	var s := RaceSettings.new()
	s.seed = 5
	s.track_id = track
	s.laps = 3
	s.ai_count = 5
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.environment = {"time_h": 14.0, "weather": "dry"}
	var crew := [{"peer_id": 0, "name": "You", "role": RaceEntry.ROLE_DRIVER, "pit_job": "wheel_l"}]
	if GameData.arg("crew2"):
		crew.append({"peer_id": 3, "name": "Sam", "role": RaceEntry.ROLE_PIT_WALL})
	else:
		crew.append({"peer_id": 2, "name": "Alex", "role": RaceEntry.ROLE_PIT_CREW, "pit_job": "gun_l"})
		crew.append({"peer_id": 3, "name": "Sam", "role": RaceEntry.ROLE_STRATEGIST})
	var humans := [{"name": "You", "car_id": "bmw_m4_gt3", "crew": crew}]
	var start := RaceFactory.plan(s, humans, GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	GameData.prefs["pit_crew_coop"] = true
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	for m in crew:
		if int(m["peer_id"]) == 0:
			continue
		var mate := Mate.new()
		mate.real = session
		mate.sim = session.sim
		mate.team_car = session.team_car if session.team_car >= 0 else session.local_car
		mate.local_role = str(m["role"])
		mate.local_peer = int(m["peer_id"])
		var g := PitCrewGame.new()
		g.session = mate
		g.crews = scene.world.pit_crews
		g.enabled_override = true
		g.autoplay = true
		g.ring_colour = PitCrewGame.BLUE
		g.guide = false
		g.visible = false
		add_child(g)
		_mates.append(g)
	get_tree().create_timer(900.0).timeout.connect(func(): print("[coop] gave up"); get_tree().quit(1))


func _physics_process(_delta: float) -> void:
	if _done or session == null:
		return
	var sim := session.sim
	if sim.phase != RaceSim.Phase.RACING:
		return
	var mine := session.local_car
	var me := sim.cars[mine]
	if not _armed:
		_armed = true
		# start before the pit entry so we don't wait a lap
		var t := sim.track
		var s0 := fposmod(sim.pits.commit_s - 300.0, t.length)
		me.pos = t.position_at(s0)
		me.heading = t.heading_at(s0)
		me.vel = me.forward() * 40.0
		me.track_idx = t.index_at(s0)
		me.track_s = s0
		session.request_pit(mine, {"box": true, "tyre": "race_slick", "fuel": 20.0})
		_t0 = sim.race_time
	var p: Dictionary = sim.entries[mine].pit
	match when:
		"call":
			if sim.race_time - _t0 >= wait:
				_shoot()
		"box":
			if p["phase"] == PitRules.PHASE_SERVICE and float(p["service_total"]) - float(p["service_left"]) >= wait:
				_shoot()
		"after":
			if int(p["stops"]) >= 1 and _t1 < 0.0:
				_t1 = sim.race_time
				print("[coop] stop ", p["last_stop"])
			if _t1 >= 0.0 and sim.race_time - _t1 >= wait:
				_shoot()


func _shoot() -> void:
	_done = true
	var p: Dictionary = session.sim.entries[session.local_car].pit
	print("[coop] phase ", p["phase"], " play ", p.get("crew_play", 0), " jobs ", p.get("crew_jobs", {}))
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[coop] saved ", out)
	get_tree().quit()
