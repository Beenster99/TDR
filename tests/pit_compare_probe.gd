extends SceneTree
## Player vs AI pit stops: where each car stops against its box and how long
## each stop takes, broken down (tyres, fuel, repairs).
##   godot --headless --path . --script res://tests/pit_compare_probe.gd -- [track] [laps]
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cars := CarCatalog.load_all()
	var s := RaceSettings.new()
	s.track_id = args[0] if args.size() > 0 else "mugello"
	s.laps = int(args[1]) if args.size() > 1 else 4
	s.mandatory_pit_stops = 1
	s.fuel_enabled = true
	s.fuel_rate = 3.0
	s.tyre_wear_enabled = true
	s.tyre_wear_rate = 3.0
	s.ai_count = 7
	s.car_class = ""
	s.seed = 777
	s.set_damage_level(OS.get_environment("DAMAGE") if OS.has_environment("DAMAGE") else "full")
	var start := RaceFactory.plan(s, [{"name": "Player", "car_id": "v8_mid_berlinetta"}], cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	var ai := AIDriver.for_all_ai(sim)
	for i in sim.car_count():
		if not ai.has(i):
			ai[i] = AIDriver.for_car(sim, i)
	var settle := {}
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 200 * s.laps:
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		for i in sim.car_count():
			var ph := sim.pit_phase(i)
			if ph == PitRules.PHASE_SERVICE and not settle.has(i):
				var m := sim.pits.box_marks(i, sim.cars[i].pos)
				var dh := wrapf(sim.cars[i].heading - float(sim.track.pit_box(sim.pits.box_index(i))["heading"]), -PI, PI)
				settle[i] = [m["along"], m["across"], rad_to_deg(dh)]
			if ph == PitRules.PHASE_LEAVE and settle.has(i) and settle[i].size() == 3:
				var m := sim.pits.box_marks(i, sim.cars[i].pos)
				settle[i].append_array([m["along"], m["across"]])
		for ev in sim.events:
			if ev["type"] == "pit_box":
				var w: Dictionary = ev["work"]
				var tl: Dictionary = w.get("crew", {})
				print("%-14s ai=%s box  tyre_s %.2f fuel_s %.2f repair_s %.2f setup_s %.2f total %.2f release %.2f skill %.2f" % [
					sim.entries[ev["car"]].driver_name, sim.entries[ev["car"]].is_ai, w.get("tyre_s", 0), w.get("fuel_s", 0),
					w.get("repair_s", 0), w.get("setup_s", 0), w.get("total_s", 0), tl.get("release", 0), sim.pits.crew_skill(ev["car"])])
			if ev["type"] == "pit_stop":
				var i: int = ev["car"]
				print("%-14s stop stationary %.2f  arrive along %.2f across %.2f yaw %.1f | leave along %s" % [sim.entries[i].driver_name,
					float(sim.entries[i].pit["last_stop"].get("stationary_s", 0)), settle[i][0], settle[i][1], settle[i][2], str(settle[i].slice(3))])
				settle.erase(i)
	quit()
