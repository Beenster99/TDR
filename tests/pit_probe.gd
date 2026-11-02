extends SceneTree
## AI race with pit rules on, for tuning: prints every pit event and the result.
##   godot --headless --path . --script res://tests/pit_probe.gd -- [track] [laps] [stops] [fuel_rate] [wear_rate] [weather]
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cars := CarCatalog.load_all()
	var s := RaceSettings.new()
	s.track_id = args[0] if args.size() > 0 else "mugello"
	s.laps = int(args[1]) if args.size() > 1 else 5
	s.mandatory_pit_stops = int(args[2]) if args.size() > 2 else 1
	var fr := float(args[3]) if args.size() > 3 else 0.0
	s.fuel_enabled = fr > 0.0
	s.fuel_rate = fr
	var wr := float(args[4]) if args.size() > 4 else 0.0
	s.tyre_wear_enabled = wr > 0.0
	s.tyre_wear_rate = wr
	if args.size() > 5:
		s.environment = {"weather": args[5], "weather_changes": true}
	s.ai_count = 6
	s.car_class = "GT3"
	s.seed = 7
	var start := RaceFactory.plan(s, [], cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	var ai := AIDriver.for_all_ai(sim)
	print("window laps %d-%d, commit_s %.0f, route %.0f m (lane from %.0f, limit %.0f-%.0f)" % [sim.pits.window_open,
		sim.pits.window_close, sim.pits.commit_s, sim.pits.route_len, sim.pits.lane_start, sim.pits.limit_start, sim.pits.limit_end])
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 200 * s.laps:
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		for ev in sim.events:
			if str(ev["type"]).begins_with("pit") or ev["type"] in ["penalty", "radio"] and (ev.get("topic", "pit") == "pit"):
				print("%7.1f %-12s %-16s %s" % [sim.race_time, ev["type"], sim.entries[ev["car"]].driver_name, ev])
	for p in sim.running_order.size():
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var c := sim.cars[i]
		print("P%d %-16s laps %d time %.1f pen %.0f stops %d/%d fuel %.1f wear %.2f %s tyre %s fpl %.2f laps %s" % [p + 1, e.driver_name,
			e.laps_done, e.finish_time, e.penalty_s, e.pit["stops"], e.pit["window_stops"], c.fuel_l,
			(c.tyre_wear[0] + c.tyre_wear[1] + c.tyre_wear[2] + c.tyre_wear[3]) / 4.0, "DNF" if e.dnf else "",
			e.pit["compound"], e.pit["fuel_per_lap"], Array(e.lap_times).map(func(x): return snappedf(x, 0.1))])
	quit()
