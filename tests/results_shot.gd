extends Node
## Screenshot of the results screen after a quick AI race (no 3D world, so
## it's fast in xvfb):
##   godot --path . res://tests/results_shot.tscn -- <out.png> [laps] [ai] [track] [--view=analysis|driver|both]
## --view=analysis also saves the race analysis, driver the own driver's race
## data, both every view (<out>_analysis.png, <out>_driver.png).
## Runs the race in the pure sim, scores it as round 1 of a 6-round season
## with a pit stop and a penalty, and shows RaceResults with the standings.

func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var out: String = a[0] if a.size() > 0 else "user://results.png"
	var s := RaceSettings.new()
	s.laps = int(a[1]) if a.size() > 1 else 4
	s.ai_count = int(a[2]) if a.size() > 2 else 15
	s.seed = 4242
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.mandatory_pit_stops = 1
	var cars := CarCatalog.load_all()
	var start := RaceFactory.plan(s, [{"name": "beenster", "car_id": "bmw_m4_gt3"}], cars, DriverCatalog.load_all())
	var track := TrackCatalog.load_track(str(a[3]) if a.size() > 3 else "silverstone")
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all(), track)
	var ai := AIDriver.for_all_ai(sim)
	var me := -1
	for i in sim.car_count():
		if not sim.entries[i].is_ai:
			me = i
	var drive := AIDriver.for_car(sim, me)
	var tel := RaceTelemetry.create(sim)
	var pens := []
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 30:
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i) if ai.has(i) else drive.get_input(sim, i))
		sim.step(inputs)
		tel.observe(sim)
		tel.on_events(sim.events)
		for e in sim.events:
			if e["type"] == "penalty":
				pens.append(e)
		if sim.tick == 60 * 90:
			sim.add_penalty(sim.running_order[4], 5.0, "Causing a collision")
	var ps := PointsSystem.from_preset("f1")
	var cls := SeasonResults.classification(sim)
	var res := SeasonResults.from_race(sim, tel)
	var pts := Season.race_points(ps, cls, res["fastest_key"], "")
	var d := ResultsTable.build(sim, tel, {"me": me, "penalties": pens, "points": pts, "points_name": ps.display_name()})
	var drivers := []
	for row in cls.slice(0, 12):
		drivers.append({"name": row["name"], "team": "", "points": pts.get(row["key"], 0), "is_me": row["name"] == "beenster"})
	drivers.sort_custom(func(x, y): return x["points"] > y["points"])
	var bg := ColorRect.new()
	bg.color = Color(0.2, 0.3, 0.2)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var layer := CanvasLayer.new()
	add_child(layer)
	layer.add_child(bg)
	var r := RaceResults.new()
	layer.add_child(r)
	r.show_results(d, {"title": "RESULTS", "subtitle": "Test Championship  ·  round 1 of 6  ·  %s  ·  %d laps" % [track.display_name, s.laps],
		"buttons": [["menu", "Continue season"]], "notes": ["You were classified P%d" % (sim.running_order.find(me) + 1), "Prize money: +9,000 cr"],
		"standings": {"title": "CHAMPIONSHIP", "note": "After round 1 of 6", "drivers": drivers,
			"teams": [{"team": "Team beenster", "points": 25}]}})
	while not r.is_shown():
		await get_tree().process_frame
	for _f in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[screenshot] ", out)
	var view := ""
	for x in OS.get_cmdline_user_args():
		if str(x).begins_with("--view="):
			view = str(x).substr(7)
	if view in ["analysis", "both"]:
		r.toggle_analysis()
		await _shot(out.get_basename() + "_analysis.png")
	if view in ["driver", "both"]:
		r.open_driver(me)
		await _shot(out.get_basename() + "_driver.png")
		var other: int = sim.running_order[0] if sim.running_order[0] != me else sim.running_order[1]
		r.open_driver(other)
		await _shot(out.get_basename() + "_driver_winner.png")
	get_tree().quit()


func _shot(path: String) -> void:
	for _f in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[screenshot] ", path)
