extends Control
## The strategist's screens without the 3D race: runs a short race in the
## background (every car on AI, as fast as it goes), then draws the full pit
## wall (StrategistScreen) with its pace table and the pit stop planner
## (PitPlanner) over it. Checks the pace numbers agree with the lap logs.
##   godot --headless --path . res://tests/strategist_shot.tscn
## With a screen (xvfb): add -- <out_prefix> to save <prefix>_wall.png and
## <prefix>_planner.png, <prefix>_pace.png (the pace view) and
## <prefix>_console.png (the co-op console's strategy tab). For the pictures
## the car just ahead of ours is then put a lap down, to show a backmarker.

var out := ""
var session: RaceSession
var wall: StrategistScreen
var planner: PitPlanner
var console: CrewConsole
var ais: Array = []
var fails := 0
var _frames := 0
var LAPS_BEFORE := 4


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else ""
	if a.size() > 1:
		LAPS_BEFORE = int(a[1])
	var s := RaceSettings.new()
	s.seed = 11
	s.track_id = "brands_hatch"
	s.laps = 12
	s.ai_count = 9
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.damage_enabled = true
	s.damage_level = "full"
	s.safety_car_enabled = false
	s.tuning_enabled = true
	s.environment = {"time_h": 14.0, "weather": "dry"}
	var humans := [{"name": "You", "car_id": "bmw_m4_gt3"}]
	var start := RaceFactory.plan(s, humans, GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	var me := session.local_car
	var drv := AIDriver.for_car(session.sim, me)
	# Race until the leader has done 7 laps (lap logs for last 3 / last 5).
	var t0 := Time.get_ticks_msec()
	var guard := 0
	while guard < 200000:
		guard += 1
		session.tick(drv.get_input(session.sim, me))
		var o := session.sim.running_order
		if session.sim.phase == RaceSim.Phase.RACING and not o.is_empty() and session.sim.entries[o[0]].laps_done >= LAPS_BEFORE:
			break
	print("  raced %.1f s of race time in %d ms" % [session.sim.race_time, Time.get_ticks_msec() - t0])
	size = Vector2(1600, 900)
	wall = StrategistScreen.new()
	add_child(wall)
	wall.setup(session)
	planner = PitPlanner.new()
	add_child(planner)
	planner.setup(session)
	wall.planner = planner
	console = CrewConsole.new()
	add_child(console)
	console.setup(session)
	console.visible = false
	_checks()
	# A backmarker for the pictures: the car just ahead, a lap down.
	var o := session.sim.running_order
	var p := o.find(session.local_car)
	if p > 0:
		session.sim.entries[o[p - 1]].distance -= session.sim.track.length
		check(session.telemetry.backmarkers_ahead(session.sim, session.local_car).size() == 1, "the car put a lap down is a backmarker up the road")
	wall.open()


func _checks() -> void:
	var tel := session.telemetry
	var sim := session.sim
	for i in sim.car_count():
		var c := tel.cars[i]
		if c.laps.size() >= 4:
			var want := (float(c.laps[-1]["time"]) + float(c.laps[-2]["time"]) + float(c.laps[-3]["time"])) / 3.0
			var got := c.avg_last(3)
			check(absf(got - want) < 1e-6, "car %d last 3 average %.3f = %.3f" % [i, got, want])
			break
	var pace := tel.pace_ranks(sim)
	for key in ["last", "avg3", "avg5"]:
		var best: int = pace[key][0] if not (pace[key] as Array).is_empty() else -1
		check(best >= 0, "someone is fastest on %s (car %d)" % [key, best])
	var rival := tel.rival_of(sim, session.local_car)
	check(rival >= 0 and rival != session.local_car, "our car has a rival (car %d)" % rival)


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 20 and out != "":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out + "_wall.png")
		print("  saved " + out + "_wall.png")
	if _frames == 24:
		wall.view = 1
	if _frames == 40 and out != "":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out + "_pace.png")
		print("  saved " + out + "_pace.png")
	if _frames == 44:
		planner.open_for(session.local_car)
		planner._pick(0, false)
		planner._pick(2, true)
		planner.fit_picked(PitRules.TYRE_INTER)
		planner.change_psi(0, -2)
		planner.change_wing("wing_rear", 2)
	if _frames == 60 and out != "":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out + "_planner.png")
		print("  saved " + out + "_planner.png")
	if _frames == 62:
		planner.visible = false
		wall.visible = false
		console.visible = true
	if _frames == 76:
		if out != "":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out + "_console.png")
			print("  saved " + out + "_console.png")
		print("PASS" if fails == 0 else "FAIL (%d)" % fails)
		get_tree().quit(1 if fails > 0 else 0)
