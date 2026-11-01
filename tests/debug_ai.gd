extends SceneTree
## Solo AI laps for tuning: prints lap times and every off-track excursion.
func _init() -> void:
	var cars := DataLoader.load_cars()
	var args := OS.get_cmdline_user_args()
	for car_id in cars:
		var settings := RaceSettings.new()
		settings.ai_count = 0
		settings.laps = 3
		var race := RaceFactory.create(settings, [{"name": "bot", "car_id": car_id}], cars, DataLoader.load_tyres(), DataLoader.load_drivers())
		var sim: RaceSim = race["sim"]
		var ai := AIDriver.new(sim.track, sim.defs[0], sim.compounds[0], {"skill": 0.95, "consistency": 1.0}, 1)
		var was_off := false
		var offs := []
		while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 400:
			sim.step([ai.get_input(sim, 0)])
			var c := sim.cars[0]
			var off := c.surface >= CarState.Surface.GRASS
			if off and not was_off:
				offs.append("s=%.0f v=%.0f off=%.1f" % [c.track_s, c.speed(), c.lateral_offset])
			was_off = off
		var e := sim.entries[0]
		print("%-18s laps %s  temps %s  offs %d %s" % [car_id, e.lap_times, sim.cars[0].tyre_temp, offs.size(), offs])
	quit()
