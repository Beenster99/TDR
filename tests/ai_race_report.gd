extends SceneTree
## AI-only race report for tuning racecraft:
##   godot --headless --path . --script res://tests/ai_race_report.gd -- [cars] [laps] [seed] [difficulty] [wetness] [trace driver] [trace from s] [class] [track]
## Prints results, best laps, passes, contacts, offs, mistakes per driver.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cars := CarCatalog.load_all()
	var settings := RaceSettings.new()
	settings.ai_count = int(args[0]) if args.size() > 0 else 12
	settings.laps = int(args[1]) if args.size() > 1 else 3
	settings.seed = int(args[2]) if args.size() > 2 else 4242
	if args.size() > 7:
		settings.car_class = args[7]
	if args.size() > 8:
		settings.track_id = args[8]
	if args.size() > 4 and float(args[4]) > 0.0:
		settings.environment = {"wetness": float(args[4]), "weather": "wet"}
	var start := RaceFactory.plan(settings, [], cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	var ai := AIDriver.for_all_ai(sim)
	if args.size() > 3:
		for i in ai:
			ai[i] = AIDriver.new(sim.track, sim.defs[i], sim.compounds[i], sim.entries[i].traits, settings.seed * 31 + i, float(args[3]))
	var n := sim.car_count()
	var passes := PackedInt32Array(); passes.resize(n)
	var lost := PackedInt32Array(); lost.resize(n)
	var offs := PackedInt32Array(); offs.resize(n)
	var mistakes := PackedInt32Array(); mistakes.resize(n)
	var contacts := PackedInt32Array(); contacts.resize(n)
	var was_off := PackedByteArray(); was_off.resize(n)
	var was_mistake := PackedByteArray(); was_mistake.resize(n)
	var prev_pos := PackedInt32Array(); prev_pos.resize(n)
	for i in n: prev_pos[i] = sim.entries[i].position
	var total_contacts := 0
	var trace_name: String = args[5] if args.size() > 5 else ""
	var trace_from: float = float(args[6]) if args.size() > 6 else 0.0
	var off_causes := {}
	var contact_kinds := {}
	var last_contact := PackedInt32Array(); last_contact.resize(n); last_contact.fill(-9999)
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 30:
		var inputs := []
		for i in n:
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		for e in sim.events:
			if e["type"] == "collision":
				total_contacts += 1
				contacts[e["a"]] += 1
				contacts[e["b"]] += 1
				var ca := sim.cars[e["a"]]
				var rel: Vector2 = sim.cars[e["b"]].pos - ca.pos
				var lyy := rel.dot(ca.right())
				var lxx := rel.dot(ca.forward())
				var back: int = e["a"] if lxx > 0.0 else e["b"]
				var kind := "%s %s L%d" % ["side" if absf(lyy) > 1.4 else "rear", AIDriver.Mood.keys()[ai[back].mood], sim.entries[back].laps_done + 1]
				contact_kinds[kind] = contact_kinds.get(kind, 0) + 1
				last_contact[e["a"]] = sim.tick
				last_contact[e["b"]] = sim.tick
		for i in n:
			if sim.tick % 15 == 0 and sim.entries[i].driver_name == trace_name and sim.tick > trace_from * 60 and sim.tick < trace_from * 60 + 900:
				var c := sim.cars[i]
				var inp: CarInput = inputs[i]
				print("t=%.1f s=%.0f v=%.1f lat=%.1f surf=%d mood=%s thr=%.2f brk=%.2f st=%.2f gear=%d bias=%.1f idx=%d herr=%.2f" % [sim.tick / 60.0, c.track_s, c.speed(), c.lateral_offset, c.surface, AIDriver.Mood.keys()[ai[i].mood], inp.throttle, inp.brake, inp.steer, c.gear, ai[i].lateral_bias, ai[i].idx, wrapf(c.heading - sim.track.heading_at(c.track_s), -PI, PI)])
			var off := sim.cars[i].surface >= TrackData.Surface.GRASS
			if off and not was_off[i]:
				offs[i] += 1
				var key := "%s bias%d%s L%d" % [AIDriver.Mood.keys()[ai[i].mood], int(round(absf(ai[i].lateral_bias))), " after contact" if sim.tick - last_contact[i] < 90 else "", sim.entries[i].laps_done + 1]
				off_causes[key] = off_causes.get(key, 0) + 1
			was_off[i] = int(off)
			var m: bool = ai[i].mood == AIDriver.Mood.MISTAKE
			if m and not was_mistake[i]: mistakes[i] += 1
			was_mistake[i] = int(m)
			if sim.tick % 30 == 0 and sim.phase == RaceSim.Phase.RACING:
				var p := sim.entries[i].position
				if p < prev_pos[i]: passes[i] += prev_pos[i] - p
				elif p > prev_pos[i]: lost[i] += p - prev_pos[i]
				prev_pos[i] = p
	var total_passes := 0
	for i in n:
		if sim.entries[i].laps_done < settings.laps:
			var c := sim.cars[i]
			print("unfinished %s: laps %d s=%.0f v=%.1f lat=%.1f surf=%d mood=%s heading_err=%.2f" % [sim.entries[i].driver_name, sim.entries[i].laps_done, c.track_s, c.speed(), c.lateral_offset, c.surface, AIDriver.Mood.keys()[ai[i].mood], wrapf(c.heading - sim.track.heading_at(c.track_s), -PI, PI)])
	print("%s, %d cars, %d laps, %.0f s" % [sim.track.display_name, n, settings.laps, sim.race_time])
	print("Pos Grid Driver            Car                Best      Gained Lost Offs Mist Cont  pace cons aggr ovt  def  tyre")
	for i in sim.running_order:
		var e := sim.entries[i]
		var t := DriverTraits.from_dict(e.traits)
		total_passes += passes[i]
		print("P%-2d %3d  %-17s %-18s %s %5d %4d %4d %4d %4d  %.2f %.2f %.2f %.2f %.2f %.2f" % [e.position, i + 1, e.driver_name, sim.defs[i].display_name,
			_lt(e.best_lap), passes[i], lost[i], offs[i], mistakes[i], contacts[i], t.pace, t.consistency, t.aggression, t.overtaking, t.defending, t.tyre_management])
	print("position changes %d, contacts %d" % [total_passes, total_contacts])
	print("contacts (car behind's mood): ", contact_kinds)
	print("offs by what the driver was doing: ", off_causes)
	quit()


func _lt(t: float) -> String:
	if t <= 0.0: return "   --   "
	return "%d:%06.3f" % [int(t) / 60, fmod(t, 60.0)]
