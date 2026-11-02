extends SceneTree
## Race start probe: how quickly each AI car gets away from the grid.
##   godot --headless --path . --script res://tests/start_probe.gd -- [ai] [track] [human: 0/1] [class]
## With human=1 a player on pole sits still for the first 3 seconds.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cars := CarCatalog.load_all()
	var settings := RaceSettings.new()
	settings.ai_count = int(args[0]) if args.size() > 0 else 12
	if args.size() > 1:
		settings.track_id = args[1]
	var human := args.size() > 2 and args[2] == "1"
	if args.size() > 3:
		settings.car_class = args[3]
	settings.seed = 7
	var players := [{"name": "You", "car_id": "bmw_m4_gt3"}] if human else []
	var start := RaceFactory.plan(settings, players, cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	var ai := AIDriver.for_all_ai(sim)
	var n := sim.car_count()
	var ai_h: AIDriver = AIDriver.for_car(sim, 0) if human else null
	var t_green := -1.0
	var stops := PackedInt32Array(); stops.resize(n)
	var moving := PackedByteArray(); moving.resize(n)
	var dist0 := PackedFloat64Array(); dist0.resize(n)
	var report := {}
	while sim.tick < 60 * 40:
		var inputs := []
		for i in n:
			if ai.has(i):
				inputs.append(ai[i].get_input(sim, i))
			else:
				var hi := CarInput.new()
				if sim.phase == RaceSim.Phase.RACING and t_green >= 0.0 and sim.tick * RaceSim.TICK_DT - t_green > 3.0:
					hi = ai_h.get_input(sim, i)
				inputs.append(hi)
		sim.step(inputs)
		if sim.phase == RaceSim.Phase.RACING and t_green < 0.0:
			t_green = sim.tick * RaceSim.TICK_DT
		if t_green < 0.0:
			continue
		var t := sim.tick * RaceSim.TICK_DT - t_green
		for i in n:
			var v := sim.cars[i].speed()
			if v > 3.0:
				moving[i] = 1
			elif moving[i] == 1 and v < 1.0:
				moving[i] = 0
				stops[i] += 1
		for mark in [2.0, 5.0, 10.0, 20.0]:
			if absf(t - mark) < RaceSim.TICK_DT * 0.5:
				for i in n:
					report[[i, mark]] = [sim.cars[i].speed() * 3.6, sim.entries[i].distance]
	for i in n:
		var line := "%2d %-22s" % [i, sim.entries[i].driver_name]
		for mark in [2.0, 5.0, 10.0, 20.0]:
			var r = report.get([i, mark], [0, 0])
			line += "  t%2d %3d km/h %5.0f m" % [mark, r[0], r[1]]
		line += "  stops %d" % stops[i]
		print(line)
	quit()
