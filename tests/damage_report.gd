extends SceneTree
## Damage in an AI race: what each car ends with, and the incidents raised.
##   godot --headless --path . -s tests/damage_report.gd -- [--track mugello] [--laps 3] [--ai 12]

func _init() -> void:
	var args := {}
	var list := OS.get_cmdline_user_args()
	for k in range(0, list.size() - 1, 2):
		args[list[k].trim_prefix("--")] = list[k + 1]
	var cars := CarCatalog.load_all()
	var tyres := TyreCatalog.load_all()
	var drivers := DriverCatalog.load_all()
	var st := RaceSettings.new()
	st.track_id = args.get("track", "spielberg")
	st.laps = int(args.get("laps", "2"))
	st.ai_count = int(args.get("ai", "8"))
	st.seed = int(args.get("seed", "777"))
	st.set_damage_level(args.get("damage", "full"))
	var start := RaceFactory.plan(st, [], cars, drivers)
	var sim := RaceFactory.build_sim(start, cars, tyres, TrackCatalog.load_track(st.track_id))
	var ai := AIDriver.for_all_ai(sim)
	var kinds := {}
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 20:
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		for e in sim.events:
			if e["type"] == "incident" or e["type"] == "puncture" or e["type"] == "retired":
				var key: String = e["type"] + ":" + str(e.get("kind", e.get("cause", e.get("reason", ""))))
				kinds[key] = kinds.get(key, 0) + 1
				print("  t=%.1f %s car %d sev %.2f" % [sim.race_time, key, e["car"], e.get("severity", 0.0)])
	for i in sim.running_order:
		var e := sim.entries[i]
		var c := sim.cars[i]
		print("P%d %-16s best %.1f %s aero %.2f susp %.2f align %+.2f eng %.2f gbx %.2f punct %s body %s" % [e.position, e.driver_name,
			e.best_lap, "DNF" if e.dnf else "", c.damage_aero, c.damage_suspension, c.alignment, c.damage_engine, c.damage_gearbox, c.puncture, c.body_damage])
	print(kinds)
	quit()
