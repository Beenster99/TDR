extends SceneTree
## Tyre temperature and lap pace probe (per-track tuning work):
##   godot --headless --path . --script res://tests/tyre_probe.gd -- [track] [cars] [laps] [class]
## Runs an AI-only race and prints, per lap, every car's lap time and its
## average tyre temperatures (front / rear) while racing.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cars := CarCatalog.load_all()
	var settings := RaceSettings.new()
	settings.track_id = args[0] if args.size() > 0 else "mugello"
	settings.ai_count = int(args[1]) if args.size() > 1 else 6
	settings.laps = int(args[2]) if args.size() > 2 else 3
	settings.car_class = args[3] if args.size() > 3 else "GT3"
	settings.seed = 777
	var start := RaceFactory.plan(settings, [], cars, DriverCatalog.load_all())
	if OS.has_environment("TDR_ALIEN"):
		settings.ai_difficulty = 1.0
		start["settings"]["ai_difficulty"] = 1.0
		for e in start["entries"]:
			e["traits"] = {"pace": 1.0, "consistency": 1.0, "aggression": 0.5, "composure": 1.0}
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	var ai := AIDriver.for_all_ai(sim)
	var n := sim.car_count()
	var sums := []
	for i in n:
		sums.append([0.0, 0.0, 0])
	var lap_seen := PackedInt32Array(); lap_seen.resize(n)
	print("%s, %.1f C air, %.1f C track" % [settings.track_id, sim.env.ambient_c, sim.env.track_c])
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 40:
		var inputs := []
		for i in n:
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		if OS.has_environment("TDR_HOT"):
			for c in sim.cars:
				c.tyre_temp = PackedFloat64Array([95.0, 95.0, 95.0, 95.0])
		if sim.phase != RaceSim.Phase.RACING:
			continue
		for i in n:
			var c := sim.cars[i]
			var s: Array = sums[i]
			s[0] += (c.tyre_temp[0] + c.tyre_temp[1]) * 0.5
			s[1] += (c.tyre_temp[2] + c.tyre_temp[3]) * 0.5
			s[2] += 1
			var e := sim.entries[i]
			if OS.has_environment("TDR_TRACE") and i == 0 and sim.tick % 60 == 0 and e.lap_times.size() == 2:
				var a: AIDriver = ai[i]
				print("    s %6.0f  v %5.1f  target %5.1f  gear %d  rpm %5.0f  ay %5.2f g  ax %5.2f g  load %.2f  fz-aero  F %.0f/%.0f R %.0f/%.0f" % [c.track_s, c.speed(), a.target_speed[a.idx], c.gear, c.rpm, c.ay / 9.81, c.ax / 9.81, c.load_factor, c.tyre_temp[0], c.tyre_temp[1], c.tyre_temp[2], c.tyre_temp[3]])
			if e.lap_times.size() > lap_seen[i]:
				lap_seen[i] = e.lap_times.size()
				print("  %-22s %-22s lap %d  %7.2f s   front %5.1f C  rear %5.1f C" % [e.driver_name, e.car_id, lap_seen[i],
					e.lap_times[lap_seen[i] - 1], s[0] / maxf(s[2], 1), s[1] / maxf(s[2], 1)])
				sums[i] = [0.0, 0.0, 0]
	quit()
