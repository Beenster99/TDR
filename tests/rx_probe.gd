extends SceneTree
## Rallycross race check: AI field on each rallycross circuit; prints lap
## times, jokers, penalties and offs.
##   godot --headless --path . --script res://tests/rx_probe.gd -- [laps] [track]
func _init() -> void:
	var cars := CarCatalog.load_all()
	var args := OS.get_cmdline_user_args()
	var laps := int(args[0]) if args.size() > 0 else 4
	var only: String = args[1] if args.size() > 1 else ""
	var drivers: Array = DriverCatalog.load_all()
	for t in TrackCatalog.list_all():
		if t["discipline"] != "rallycross" or (only != "" and t["id"] != only):
			continue
		var settings := RaceSettings.new()
		settings.discipline = RaceSettings.DISCIPLINE_RALLYCROSS
		settings.track_id = t["id"]
		settings.car_class = "RX1"
		settings.ai_count = 6
		settings.laps = laps
		settings.set_damage_level("full")
		var start := RaceFactory.plan(settings, [], cars, drivers)
		var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
		var ai := AIDriver.for_all_ai(sim)
		var offs := {}
		var was_off := {}
		while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 100 * laps:
			var inputs := []
			for i in sim.car_count():
				inputs.append(ai[i].get_input(sim, i))
			sim.step(inputs)
			for i in sim.car_count():
				var off := sim.cars[i].surface >= TrackData.Surface.GRASS
				if off and not was_off.get(i, false):
					offs[i] = offs.get(i, 0) + 1
				was_off[i] = off
		print("%s (%.0f m, joker %.0f m): %s after %.0f s" % [t["id"], sim.track.length, sim.track.joker_length,
			"finished" if sim.phase == RaceSim.Phase.FINISHED else "NOT FINISHED", sim.race_time])
		for i in sim.running_order:
			var e := sim.entries[i]
			var lt := []
			for x in e.lap_times: lt.append("%.1f" % x)
			print("   P%d %-16s %-28s laps %d %s best %.2f jokers %d pen %.0f offs %d" % [e.position, e.driver_name,
				sim.defs[i].display_name, e.laps_done, lt, e.best_lap, e.jokers, e.penalty_s, offs.get(i, 0)])
	quit()
