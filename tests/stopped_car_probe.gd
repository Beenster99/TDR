extends SceneTree
## Which cars end up parked at the side of the track, and what race control
## does about them:
##   godot --headless --path . --script res://tests/stopped_car_probe.gd -- [track] [cars] [laps] [seed] [class] [damage off|visual|full]
## Prints every stop of 5 s or more during the race (who, where, why) and the
## recovery events.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cars := CarCatalog.load_all()
	var settings := RaceSettings.new()
	if args.size() > 0 and args[0] != "":
		settings.track_id = args[0]
	settings.ai_count = int(args[1]) if args.size() > 1 else 20
	settings.laps = int(args[2]) if args.size() > 2 else 5
	settings.seed = int(args[3]) if args.size() > 3 else 1
	if args.size() > 4:
		settings.car_class = args[4]
	settings.set_damage_level(args[5] if args.size() > 5 else "full")
	var start := RaceFactory.plan(settings, [], cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	var ai := AIDriver.for_all_ai(sim)
	var n := sim.car_count()
	var still := PackedFloat64Array(); still.resize(n)
	var longest := PackedFloat64Array(); longest.resize(n)
	var reported := PackedByteArray(); reported.resize(n)
	var flags := {}
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 40:
		var inputs := []
		for i in n:
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		for e in sim.events:
			if e["type"] == "flag" and String(e.get("flag", "")) in ["recovery", "recovered"]:
				print("  %.0fs %s: %s" % [sim.race_time, e["flag"], e.get("reason", "")])
				flags[e["flag"]] = flags.get(e["flag"], 0) + 1
			if e["type"] == "retired":
				print("  %.0fs retired %s (%s)" % [sim.race_time, sim.entries[e["car"]].driver_name, e["reason"]])
			if e["type"] == "safety_car":
				print("  %.0fs safety car %s (%s)" % [sim.race_time, e.get("state", ""), e.get("reason", "")])
		if sim.phase != RaceSim.Phase.RACING:
			continue
		var rc := sim.race_control
		for i in n:
			var c := sim.cars[i]
			var en := sim.entries[i]
			if en.finished or rc.out_of_play(i) or sim.in_pit_lane(i):
				still[i] = 0.0
				reported[i] = 0
				continue
			if c.speed() < 3.0:
				still[i] += RaceSim.TICK_DT
			else:
				if still[i] >= 5.0:
					print("  %.0fs %s moving again after %.0f s" % [sim.race_time, en.driver_name, still[i]])
				still[i] = 0.0
				reported[i] = 0
			longest[i] = maxf(longest[i], still[i])
			if still[i] >= 5.0 and not reported[i]:
				reported[i] = 1
				print("  %.0fs STOP %s s=%.0f lat=%.1f surf=%d dnf=%s crippled=%s flats=%d susp=%.2f eng=%.2f mood=%s job=%s" % [
					sim.race_time, en.driver_name, c.track_s, c.lateral_offset, c.surface, en.dnf,
					CarDamage.is_crippled(c), CarDamage.punctures(c), c.damage_suspension,
					c.damage_engine, AIDriver.Mood.keys()[ai[i].mood], not rc.recovery_for(i).is_empty()])
	var parked := 0
	for i in n:
		if longest[i] >= 20.0:
			parked += 1
			print("  parked %s for %.0f s (dnf=%s, recovered=%d)" % [sim.entries[i].driver_name, longest[i], sim.entries[i].dnf, sim.race_control.recovered[i]])
	print("%s: %d cars parked 20 s+, flags %s" % [sim.track.name, parked, flags])
	quit()
