extends SceneTree
## Solo AI laps for tuning: prints lap times and every off-track excursion.
##   godot --headless --path . --script res://tests/debug_ai.gd -- [laps] [pace]
func _init() -> void:
	var cars := CarCatalog.load_all()
	var args := OS.get_cmdline_user_args()
	var laps := int(args[0]) if args.size() > 0 else 4
	var pace := float(args[1]) if args.size() > 1 else 0.95
	var only: String = args[2] if args.size() > 2 else ""
	var track_id: String = args[3] if args.size() > 3 else ""
	for car_id in cars:
		if only != "" and not car_id.contains(only):
			continue
		var settings := RaceSettings.new()
		settings.ai_count = 0
		settings.laps = laps
		if track_id != "":
			settings.track_id = track_id
		var start := RaceFactory.plan(settings, [{"name": "bot", "car_id": car_id}], cars, [])
		var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
		var ai := AIDriver.new(sim.track, sim.defs[0], sim.compounds[0], {"pace": pace, "consistency": 1.0}, 1)
		var was_off := false
		var offs := []
		while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 150 * laps:
			sim.step([ai.get_input(sim, 0)])
			var c := sim.cars[0]
			var off := c.surface >= TrackData.Surface.GRASS
			if off and not was_off:
				offs.append("L%d s=%.0f v=%.0f" % [sim.entries[0].laps_done + 1, c.track_s, c.speed()])
			was_off = off
		var e := sim.entries[0]
		var t := []
		for x in e.lap_times: t.append("%.2f" % x)
		var lsum := 0.0
		for v in ai.learn: lsum += v
		print("%-18s laps %s  learn %.3f  temps %s  offs %d %s" % [car_id, t, lsum / ai.learn.size(), _fmt(sim.cars[0].tyre_temp), offs.size(), offs])
	quit()


func _fmt(a: PackedFloat64Array) -> String:
	var s := []
	for v in a: s.append("%.0f" % v)
	return "[" + ", ".join(s) + "]"
