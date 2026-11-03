extends SceneTree
## Racecraft probe: how often AI cars move sideways into a car alongside.
##   godot --headless --path . --script res://tests/racecraft_probe.gd -- [track] [seed] [laps] [cars]
## Car 0 stands in for a human: it drives its own line and ignores traffic,
## with extra pace so it has to pass. A side contact is counted against the
## car that was moving sideways towards the other one ("swerve in").
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var r := run(args[0] if args.size() > 0 else "spielberg", int(args[1]) if args.size() > 1 else 4242,
		int(args[2]) if args.size() > 2 else 3, int(args[3]) if args.size() > 3 else 12)
	print(r)
	quit()


static func run(track_id: String, seed: int, laps: int, count: int) -> Dictionary:
	var cars := CarCatalog.load_all()
	var settings := RaceSettings.new()
	settings.ai_count = count
	settings.laps = laps
	settings.seed = seed
	settings.track_id = track_id
	var start := RaceFactory.plan(settings, [], cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	var ai := AIDriver.for_all_ai(sim)
	var bot := sim.running_order[sim.car_count() - 1]  # starts last
	ai[bot] = AIDriver.new(sim.track, sim.defs[bot], sim.compounds[bot], {"pace": 1.0, "consistency": 1.0}, seed, 1.0)
	ai[bot].ignore_traffic = true
	var out := {"contacts": 0, "side": 0, "ai_swerve_into_bot": 0, "ai_swerve_into_ai": 0, "moods": {}, "bot_pos": 0, "bot_offs": 0}
	var last := {}
	var was_off := false
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 20:
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		var off := sim.cars[bot].surface >= TrackData.Surface.GRASS
		if off and not was_off:
			out["bot_offs"] += 1
		was_off = off
		for e in sim.events:
			if e["type"] != "collision":
				continue
			var a: int = e["a"]
			var b: int = e["b"]
			var key := "%d-%d" % [a, b]
			if sim.tick - int(last.get(key, -999)) < 60:
				continue  # same incident
			last[key] = sim.tick
			out["contacts"] += 1
			for side in 2:
				var me := a if side == 0 else b
				var other := b if side == 0 else a
				var c := sim.cars[me]
				var rel: Vector2 = sim.cars[other].pos - c.pos
				var lx := rel.dot(c.forward())
				var ly := rel.dot(c.right())
				var o_len := (sim.defs[me].length + sim.defs[other].length) * 0.5
				if absf(lx) > o_len * 0.95 or absf(ly) < 1.0:
					continue  # nose to tail
				if side == 0:
					out["side"] += 1
				if me != bot and other == bot:
					var lst: Array = out.get("bot_side", [])
					lst.append("t%.0f lx%.1f ly%.1f lat%.1f/%.1f %s" % [sim.tick / 60.0, lx, ly, c.vel.dot(c.right()) * signf(ly), sim.cars[other].vel.dot(c.right()) * signf(ly), AIDriver.Mood.keys()[ai[me].mood]])
					out["bot_side"] = lst
				# Sideways speed towards the other car, relative to its own.
				var my_lat := c.vel.dot(c.right()) * signf(ly)
				var their_lat := sim.cars[other].vel.dot(c.right()) * signf(ly)
				if me != bot and my_lat > 0.6 and my_lat > their_lat + 0.4:
					out["ai_swerve_into_bot" if other == bot else "ai_swerve_into_ai"] += 1
					var m: String = AIDriver.Mood.keys()[ai[me].mood]
					out["moods"][m] = out["moods"].get(m, 0) + 1
	out["bot_pos"] = sim.entries[bot].position
	return out
