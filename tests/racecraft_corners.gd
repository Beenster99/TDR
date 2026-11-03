extends SceneTree
## Racecraft corner probe: at every corner on a track, a car that ignores
## traffic (a stand-in for a human) sits on the AI car's inside with its nose
## level with the AI's rear wheels, and holds the inside line. Counts how
## often the AI car turns in on it (contact) and how often the inside car
## ends up off the track. "outside" puts it on the outside instead (the AI
## must not run it wide on the exit).
##   godot --headless --path . --script res://tests/racecraft_corners.gd -- [track] [seed] [outside]
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	print(run(args[0] if args.size() > 0 else "spielberg", int(args[1]) if args.size() > 1 else 7, args.size() > 2 and args[2] == "outside"))
	quit()


static func run(track_id: String, seed: int, outside := false) -> Dictionary:
	var cars := CarCatalog.load_all()
	var settings := RaceSettings.new()
	settings.ai_count = 2
	settings.laps = 50
	settings.seed = seed
	settings.track_id = track_id
	settings.set_damage_level("off")
	var start := RaceFactory.plan(settings, [], cars, DriverCatalog.load_all())
	var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
	var ai := AIDriver.for_all_ai(sim)
	var me := 0
	var bot := 1
	var traits := {"pace": 1.0, "consistency": 1.0, "aggression": 1.0, "defending": 1.0, "overtaking": 1.0}
	ai[me] = AIDriver.new(sim.track, sim.defs[me], sim.compounds[me], traits, seed, 1.0)
	ai[bot] = AIDriver.new(sim.track, sim.defs[bot], sim.compounds[bot], {"pace": 1.0, "consistency": 1.0}, seed + 1, 1.0)
	ai[bot].ignore_traffic = true
	var drv: AIDriver = ai[me]
	var n := drv.line.size()
	# Corner approaches: the line point where the next corner first shows.
	var spots := []
	var k := 0
	while k < n:
		if drv._next_corner_dir(k) != 0 and drv._next_corner_dir((k - 6 + n) % n) == 0:
			spots.append(k)
			k += 30
		k += 2
	var out := {"corners": spots.size(), "trials": 0, "contacts": 0, "bot_off": 0, "min_gap": [] }
	while sim.phase == RaceSim.Phase.COUNTDOWN:
		sim.step([CarInput.new(), CarInput.new()])
	for spot in spots:
		var side: int = drv._next_corner_dir(spot) * (-1 if outside else 1)
		var gap := (sim.defs[me].width + sim.defs[bot].width) * 0.5 + 0.7
		if (drv.room_right[spot] if side > 0 else drv.room_left[spot]) < gap:
			continue
		out["trials"] += 1
		var r: Vector2 = drv.line_right[spot]
		var f := Vector2(r.y, -r.x)
		var v := minf(drv.target_speed[spot] * 0.9, 60.0)
		var back := (sim.defs[me].length + sim.defs[bot].length) * 0.5 - 1.0
		_place(sim.cars[me], drv.line[spot], f, v)
		_place(sim.cars[bot], drv.line[spot] + r * side * gap - f * back, f, v + 1.0)
		for i in [me, bot]:
			ai[i].idx = -1
			ai[i].stuck_idx = -1
			ai[i].lateral_bias = 0.0
			ai[i]._defend_decided = -1
			ai[i]._pass_target = -1
		ai[bot].lateral_bias = side * gap
		ai[bot].hold_bias = side * gap
		var touched := false
		var off := false
		var min_gap := INF
		for t in 60 * 4:
			var inputs := [ai[0].get_input(sim, 0), ai[1].get_input(sim, 1)]
			sim.step(inputs)
			for e in sim.events:
				if e["type"] == "collision":
					touched = true
			if sim.cars[bot].surface >= TrackData.Surface.GRASS:
				off = true
			var rel := sim.cars[bot].pos - sim.cars[me].pos
			var c := sim.cars[me]
			if absf(rel.dot(c.forward())) < (sim.defs[me].length + sim.defs[bot].length) * 0.5:
				min_gap = minf(min_gap, absf(rel.dot(c.right())) - (sim.defs[me].width + sim.defs[bot].width) * 0.5)
		if touched:
			out["contacts"] += 1
		if off:
			out["bot_off"] += 1
		if min_gap < INF:
			out["min_gap"].append(snappedf(min_gap, 0.1))
	return out


static func _place(c: CarState, pos: Vector2, f: Vector2, v: float) -> void:
	c.pos = pos
	c.heading = f.angle()
	c.vel = f * v
	c.yaw_rate = 0.0
	c.steer_angle = 0.0
