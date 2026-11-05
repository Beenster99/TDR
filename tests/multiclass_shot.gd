extends Control
## Multi-class races: the host picks 2 or 3 classes; the grid lines up class
## by class; the timing tower, results and the pit wall show each car's class
## and place in it; the pit wall says what the cars either side of us on the
## road are to us (racing us, a backmarker, a faster class coming through).
##   godot --headless --path . res://tests/multiclass_shot.tscn
## With a screen (xvfb): add -- <out_prefix> to save <prefix>_tower.png,
## <prefix>_wall.png and <prefix>_results.png.

var out := ""
var session: RaceSession
var hud: RaceHud
var wall: StrategistScreen
var results: RaceResults
var fails := 0
var _frames := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else ""
	_plan_checks()
	var s := RaceSettings.new()
	s.seed = 21
	s.track_id = "spa"
	s.laps = 30
	s.ai_count = 17
	s.car_class = RaceSettings.CLASS_MULTI
	s.multi_classes = ["Hypercar", "LMP2", "GT3"]
	s.safety_car_enabled = false
	s.flags_enabled = false
	s.environment = {"time_h": 14.0, "weather": "dry"}
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": "oreca_07_gibson"}], GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	var sim := session.sim
	var me := session.local_car
	var drv := AIDriver.for_car(sim, me)
	var guard := 0
	while guard < 400000:
		guard += 1
		session.tick(drv.get_input(sim, me))
		var o := sim.running_order
		if sim.phase == RaceSim.Phase.RACING and not o.is_empty() and sim.entries[o[0]].laps_done >= 4:
			break
	_race_checks()
	size = Vector2(1600, 900)
	hud = RaceHud.new()
	add_child(hud)
	hud.setup(session)
	hud.size = size
	hud.set_item_on("tower", true)


## RaceFactory: only the picked classes race, the grid is class by class, and
## a player's car from a class that isn't racing is swapped.
func _plan_checks() -> void:
	var s := RaceSettings.new()
	s.seed = 5
	s.car_class = RaceSettings.CLASS_MULTI
	s.multi_classes = ["Hypercar", "GT3"]
	s.ai_count = 20
	var start := RaceFactory.plan(s, [{"name": "P", "car_id": "oreca_07_gibson"}], GameData.cars, GameData.drivers)
	var seen := {}
	var order := []
	for d in start["entries"]:
		var cls: String = GameData.cars[d["car_id"]].class_tag
		seen[cls] = int(seen.get(cls, 0)) + 1
		if order.is_empty() or order[-1] != cls:
			order.append(cls)
	check(seen.keys().size() == 2 and seen.has("Hypercar") and seen.has("GT3"), "WEC mix: only Hypercar and GT3 race (%s)" % str(seen))
	check(order == ["Hypercar", "GT3"], "the grid lines up class by class, Hypercars first (%s)" % str(order))
	var mine: Dictionary = start["entries"].filter(func(d): return not d["is_ai"])[0]
	check(GameData.cars[mine["car_id"]].class_tag in ["Hypercar", "GT3"], "a player's LMP2 is swapped for a car in the race (%s)" % mine["car_id"])
	check(RaceSettings.from_dict(s.to_dict()).multi_classes == ["Hypercar", "GT3"], "the classes go to every player with the settings")
	s.multi_classes = ["GT3", "Road"]
	start = RaceFactory.plan(s, [], GameData.cars, GameData.drivers)
	var cl := {}
	for d in start["entries"]:
		cl[GameData.cars[d["car_id"]].class_tag] = true
	check(cl.keys().size() == 2 and cl.has("Road") and cl.has("GT3"), "GT3 v road cars (%s)" % str(cl.keys()))
	s.multi_classes = []
	start = RaceFactory.plan(s, [], GameData.cars, GameData.drivers)
	cl = {}
	for d in start["entries"]:
		cl[GameData.cars[d["car_id"]].class_tag] = true
	check(cl.size() == CarCatalog.classes(GameData.cars).size(), "old settings with no classes picked: every class, as before")


func _race_checks() -> void:
	var sim := session.sim
	var tel := session.telemetry
	var me := session.local_car
	check(RaceTelemetry.multi_class(sim), "a multi-class race")
	check(Array(RaceTelemetry.race_classes(sim)) == ["Hypercar", "LMP2", "GT3"], "classes fastest first (%s)" % str(RaceTelemetry.race_classes(sim)))
	var counts := {}
	var ok := true
	for i in sim.running_order:
		var c := sim.defs[i].class_tag
		counts[c] = int(counts.get(c, 0)) + 1
		ok = ok and RaceTelemetry.class_position(sim, i) == counts[c]
	check(ok, "class positions count up within each class")
	var hyp := -1
	var gt3 := -1
	for i in sim.car_count():
		if sim.defs[i].class_tag == "Hypercar" and hyp < 0:
			hyp = i
		if sim.defs[i].class_tag == "GT3" and gt3 < 0:
			gt3 = i
	check(RaceTelemetry.relation(sim, me, hyp) == RaceTelemetry.REL_FASTER, "to our LMP2 a Hypercar is a faster class")
	check(RaceTelemetry.relation(sim, me, gt3) == RaceTelemetry.REL_SLOWER, "and a GT3 a slower class")
	var road := tel.road_neighbours(sim, me)
	check(road["ahead"] >= 0 and road["behind"] >= 0 and road["ahead"] != me, "there are cars ahead and behind on the road (%s)" % str(road))
	print("  ahead:  %s" % StrategistScreen.road_advice(sim, me, road["ahead"], true))
	print("  behind: %s" % StrategistScreen.road_advice(sim, me, road["behind"], false))
	var d := ResultsTable.build(sim, tel, {"me": me, "single_race_points": true})
	check(d["multi"] and d["classes"] == ["Hypercar", "LMP2", "GT3"], "results know the classes")
	var firsts := 0
	for r in d["rows"]:
		firsts += 1 if int(r["class_pos"]) == 1 else 0
	check(firsts == 3, "each class has a leader in the results")


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 20 and out != "":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out + "_tower.png")
		print("  saved " + out + "_tower.png")
	if _frames == 22:
		hud.visible = false
		wall = StrategistScreen.new()
		add_child(wall)
		wall.setup(session)
		wall.open()
	if _frames == 40 and out != "":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out + "_wall.png")
		print("  saved " + out + "_wall.png")
	if _frames == 42:
		wall.visible = false
		# Finish the race on paper so the results are final.
		var sim := session.sim
		for p in sim.running_order.size():
			var e := sim.entries[sim.running_order[p]]
			e.finished = true
			e.finish_time = 600.0 + p * 7.3
		results = RaceResults.new()
		add_child(results)
		results.show_results(ResultsTable.build(sim, session.telemetry, {"me": session.local_car, "single_race_points": true}),
			{"title": "RESULTS"})
	if _frames == 70:
		while not results.is_shown():
			await get_tree().process_frame
		for _f in 4:
			await get_tree().process_frame
		if out != "":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out + "_results.png")
			print("  saved " + out + "_results.png")
		print("PASS" if fails == 0 else "FAIL (%d)" % fails)
		get_tree().quit(1 if fails > 0 else 0)
