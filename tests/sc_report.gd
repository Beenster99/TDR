extends SceneTree
## Safety car scenario report (tuning aid, not part of the test run):
##   godot --headless --path . --script res://tests/sc_report.gd -- [track] [laps] [ai] [stop_at_s] [retire 0|1] [sc 0|1]
## Runs an AI race, stops one car on the track at stop_at_s and prints what
## race control does: flags, VSC/SC, the queue gaps, penalties, restart.

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var track_id := a[0] if a.size() > 0 else "spielberg"
	var settings := RaceSettings.new()
	settings.track_id = track_id
	settings.laps = int(a[1]) if a.size() > 1 else 5
	settings.ai_count = int(a[2]) if a.size() > 2 else 10
	var stop_at := float(a[3]) if a.size() > 3 else 60.0
	var retire := (a[4] == "1") if a.size() > 4 else true
	settings.safety_car_enabled = (a[5] != "0") if a.size() > 5 else true
	settings.seed = 4242
	if a.size() > 6:
		settings.car_class = a[6]
	var cars := CarCatalog.load_all()
	var start := RaceFactory.plan(settings, [], cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all(), TrackCatalog.load_track(track_id))
	var ai := AIDriver.for_all_ai(sim)
	var victim := -1
	var last_print := -100.0
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 30:
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		if sim.race_time >= stop_at and victim < 0 and sim.phase == RaceSim.Phase.RACING:
			victim = sim.running_order[sim.car_count() / 2]
			print("[%6.1f] >>> %s stops on track at %.0f m" % [sim.race_time, sim.entries[victim].driver_name, sim.cars[victim].track_s])
			if a.size() > 7 and a[7] == "force":
				sim.race_control._deploy_sc("Forced for the report")
			if a.size() > 8 and a[8] == "lap":
				var back := sim.running_order[sim.car_count() - 1]
				sim.entries[back].distance -= sim.track.length
				print("            %s now counts as a lap down" % sim.entries[back].driver_name)
		if victim >= 0:
			var stop := CarInput.new()
			stop.brake = 1.0
			inputs[victim] = stop
			if retire and sim.cars[victim].speed() < 1.0 and not sim.entries[victim].dnf:
				sim.entries[victim].dnf = true
		sim.step(inputs)
		for e in sim.events:
			if e["type"] == "lap" and sim.entries[e["car"]].position == 1:
				print("[%6.1f] lap %d leader %s %.1f s (%s)" % [sim.race_time, e["lap"], sim.entries[e["car"]].driver_name, e["time"], sim.race_control.neutralisation()])
			if e["type"] in ["flag", "safety_car", "penalty", "warning"]:
				print("[%6.1f] %s" % [sim.race_time, _ev(sim, e)])
		var rc := sim.race_control
		if rc.mode == RaceControl.Mode.SC and sim.race_time - last_print > 10.0:
			last_print = sim.race_time
			print("[%6.1f]     SC %s gap->leader %.0f m  speed %.0f km/h  queue %s" % [sim.race_time, rc.stage,
				rc.gap_to_sc(rc.sc_train_leader()), rc.sc_speed * 3.6, _queue(sim)])
			print("            ", rc.hazards())
			for i in sim.car_count():
				if rc.unlapping[i]:
					var d: AIDriver = ai[i]
					print("            unlapping %s mood %d pass %d bias %.1f speed %.0f yielding-ahead? gap_sc %.0f" % [sim.entries[i].driver_name,
						d.mood, d._pass_target, d.lateral_bias, sim.cars[i].speed() * 3.6, rc.gap_to_sc(i)])
	for p in sim.running_order.size():
		var i := sim.running_order[p]
		var e := sim.entries[i]
		print("P%-2d %-16s laps %d  %s  pen %.0f" % [p + 1, e.driver_name, e.laps_done, "DNF" if e.dnf else "%.1f" % e.finish_time, e.penalty_s])
	quit()


func _ev(sim: RaceSim, e: Dictionary) -> String:
	var who: String = sim.entries[e["car"]].driver_name if e.has("car") and int(e["car"]) >= 0 else ""
	match e["type"]:
		"flag": return "FLAG %s %s" % [e["flag"], e.get("reason", "")]
		"safety_car": return "RACE CONTROL %s (%s)" % [e["state"], e.get("reason", "")]
		"penalty": return "PENALTY %s +%.0f s: %s" % [who, e["seconds"], e["reason"]]
		"warning": return "WARNING %s: %s" % [who, e["text"]]
	return str(e)


func _queue(sim: RaceSim) -> String:
	var out := []
	var lead := sim.entries[sim.running_order[0]].distance
	for i in sim.running_order:
		var e := sim.entries[i]
		if e.dnf:
			continue
		out.append("%.0f" % (lead - e.distance))
	return ",".join(out)
