extends SceneTree
## Launch probe: a standing start at a fixed throttle (the AI steers), with and without
## traction control. Prints the time to 100 km/h and how long the rear
## tyres spun, per car class.
##   godot --headless --path . --script res://tests/launch_probe.gd
func _init() -> void:
	for cls in (OS.get_cmdline_user_args() if not OS.get_cmdline_user_args().is_empty() else ["GT3", "Hypercar", "LMP2", "Road"]):
		for tc in [true, false]:
			var line := "%-9s tc %-3s" % [cls, "on" if tc else "off"]
			var car_name := ""
			for thr in [0.5, 0.7, 0.85, 1.0]:
				var r := run(cls, tc, thr)
				car_name = r["car"]
				line += "   thr %.2f: 100 in %.2f s, spin %.2f s" % [thr, r["t100"], r["spin"]]
			print(line + "   (" + car_name + ")")
	quit()


static func run(cls: String, tc: bool, thr: float) -> Dictionary:
	var cars := CarCatalog.load_all()
	var settings := RaceSettings.new()
	settings.ai_count = 1
	settings.car_class = cls
	settings.seed = 3
	var start := RaceFactory.plan(settings, [], cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	sim.cars[0].assist_tc = tc
	var ai := AIDriver.for_all_ai(sim)
	var t0 := -1
	var spin := 0.0
	while sim.tick < 60 * 30:
		var inp := CarInput.new()
		var steer: CarInput = ai[0].get_input(sim, 0)  # steering only
		inp.steer = steer.steer
		if sim.phase == RaceSim.Phase.RACING:
			if t0 < 0:
				t0 = sim.tick
			inp.throttle = thr
		sim.step([inp])
		if t0 >= 0:
			if sim.cars[0].wheelspin:
				spin += RaceSim.TICK_DT
			if sim.cars[0].speed() * 3.6 >= 100.0:
				return {"car": sim.defs[0].display_name, "t100": (sim.tick - t0) * RaceSim.TICK_DT, "spin": spin}
	print("   never reached 100: %s v=%.1f km/h surface %d gear %d rpm %.0f" % [sim.defs[0].display_name, sim.cars[0].speed() * 3.6, sim.cars[0].surface, sim.cars[0].gear, sim.cars[0].rpm])
	return {"car": sim.defs[0].display_name, "t100": INF, "spin": spin}
