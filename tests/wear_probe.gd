extends SceneTree
## Tyre wear: player vs AI probe.
##   godot --headless --path . --script res://tests/wear_probe.gd -- [track] [laps] [mode] [ai_count]
## mode: ai (car 0 is an AI entry), default (a human entry on the car's
## default setup, driven by the AI), human (the same, with pad-style inputs:
## pedals mashed, steering overdriven).
## Prints per-lap wear per corner for car 0 and the average of the AI cars,
## plus car 0's average temperatures and pressures.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cars := CarCatalog.load_all()
	var settings := RaceSettings.new()
	settings.track_id = args[0] if args.size() > 0 else "silverstone"
	settings.laps = int(args[1]) if args.size() > 1 else 4
	var mode: String = args[2] if args.size() > 2 else "default"
	settings.ai_count = int(args[3]) if args.size() > 3 else 5
	settings.car_class = "GT3"
	settings.seed = 777
	settings.tyre_wear_enabled = true
	settings.tyre_wear_rate = 1.0
	var humans := []
	if mode != "ai":
		humans.append({"peer_id": 1, "name": "Player", "car_id": "porsche_911_gt3_r", "setup": {}})
	var start := RaceFactory.plan(settings, humans, cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	var n := sim.car_count()
	var me := n - 1 if mode != "ai" else 0
	var ai := AIDriver.for_all_ai(sim)
	if not ai.has(me):
		ai[me] = AIDriver.for_car(sim, me)
	var area := 0.0
	var pts := sim.track.points
	for k in pts.size():
		var a: Vector2 = pts[k]
		var b: Vector2 = pts[(k + 1) % pts.size()]
		area += a.x * b.y - b.x * a.y
	print("%s mode=%s car0=%s (%s)  signed area %.0f  air %.1f track %.1f" % [settings.track_id, mode,
		sim.entries[me].car_id, sim.entries[me].driver_name, area, sim.env.ambient_c, sim.env.track_c])
	var gain := float(OS.get_environment("TDR_GAIN")) if OS.has_environment("TDR_GAIN") else 1.2
	var saw := float(OS.get_environment("TDR_SAW")) if OS.has_environment("TDR_SAW") else 0.0
	var mash := not OS.has_environment("TDR_NOMASH")
	if OS.has_environment("TDR_TRACK"):
		sim.cars[me].assist_track = int(OS.get_environment("TDR_TRACK"))
	if OS.has_environment("TDR_HELP"):
		var help := int(OS.get_environment("TDR_HELP"))
		sim.cars[me].assist_stability = help >= 2
		sim.cars[me].assist_tc = help >= 1
		sim.cars[me].assist_abs = help >= 1
	print("gain %.2f saw %.2f mash %s  aids tc %s abs %s stab %s track %d" % [gain, saw, mash, sim.cars[me].assist_tc, sim.cars[me].assist_abs, sim.cars[me].assist_stability, sim.cars[me].assist_track])
	var tmax := [0.0, 0.0, 0.0, 0.0]
	var lap_seen := 0
	var acc := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0]
	var last_wear := PackedFloat64Array([0, 0, 0, 0])
	var prev_wear_ai := {}
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 40:
		var inputs := []
		for i in n:
			var inp: CarInput = ai[i].get_input(sim, i)
			if i == me and mode == "human" and sim.phase == RaceSim.Phase.RACING and not sim.pit_controls(i):
				if mash:
					inp.throttle = 1.0 if inp.throttle > 0.25 else 0.0
					inp.brake = 1.0 if inp.brake > 0.25 else 0.0
				inp.steer = clampf(inp.steer * gain + saw * sin(sim.tick / 60.0 * TAU * 1.5), -1.0, 1.0)
			inputs.append(inp)
		sim.step(inputs)
		if sim.phase != RaceSim.Phase.RACING:
			continue
		var c := sim.cars[me]
		for k in 4:
			tmax[k] = maxf(tmax[k], c.tyre_temp[k])
			acc[k] += c.tyre_temp[k]
			acc[4 + k] += c.tyre_psi[k]
		acc[8] += 1
		var e := sim.entries[me]
		if e.lap_times.size() > lap_seen:
			lap_seen = e.lap_times.size()
			var d := PackedFloat64Array()
			for k in 4:
				d.append(c.tyre_wear[k] - last_wear[k])
			last_wear = c.tyre_wear.duplicate()
			# AI average total wear so far
			var aw := [0.0, 0.0, 0.0, 0.0]
			var na := 0
			for i in n:
				if i == me:
					continue
				na += 1
				for k in 4:
					aw[k] += sim.cars[i].tyre_wear[k]
			var cnt: float = maxf(acc[8], 1)
			print("  lap %d %6.2fs  wear/lap FL %4.1f%% FR %4.1f%% RL %4.1f%% RR %4.1f%% | total %4.1f %4.1f %4.1f %4.1f | AI avg total %4.1f %4.1f %4.1f %4.1f | T %3.0f %3.0f %3.0f %3.0f  psi %4.1f %4.1f %4.1f %4.1f" % [
				lap_seen, e.lap_times[lap_seen - 1], d[0] * 100, d[1] * 100, d[2] * 100, d[3] * 100,
				c.tyre_wear[0] * 100, c.tyre_wear[1] * 100, c.tyre_wear[2] * 100, c.tyre_wear[3] * 100,
				aw[0] / na * 100, aw[1] / na * 100, aw[2] / na * 100, aw[3] / na * 100,
				acc[0] / cnt, acc[1] / cnt, acc[2] / cnt, acc[3] / cnt, acc[4] / cnt, acc[5] / cnt, acc[6] / cnt, acc[7] / cnt])
			print("     max T %3.0f %3.0f %3.0f %3.0f" % tmax)
			tmax = [0.0, 0.0, 0.0, 0.0]
			acc = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0]
	quit()
