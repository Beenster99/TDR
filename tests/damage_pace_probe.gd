extends SceneTree
## Damage pace probe: one AI car alone, damage held at a fixed level, laps 2-3
## timed against the same car undamaged. Prints the share of the lap time each
## part costs (what DamageAdvice.LOSS uses).
## godot --headless --path . --script res://tests/damage_pace_probe.gd [track] [car]

const CASES := [
	["clean", 0.0], ["aero", 0.25], ["aero", 0.5], ["aero", 0.75], ["aero", 1.0],
	["suspension", 0.25], ["suspension", 0.5], ["suspension", 0.75], ["suspension", 1.0],
	["alignment", 0.25], ["alignment", 0.5], ["alignment", 0.75], ["alignment", 1.0],
	["engine", 0.25], ["engine", 0.5], ["engine", 0.75], ["engine", 0.95],
	["gearbox", 0.25], ["gearbox", 0.5], ["gearbox", 0.75], ["gearbox", 1.0],
	["puncture_front", 1.0], ["puncture_rear", 1.0],
]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var tid := args[0] if args.size() > 0 else "brands_hatch"
	var car_id := args[1] if args.size() > 1 else ""
	var cars := CarCatalog.load_all()
	var tyres := TyreCatalog.load_all()
	var drivers := DriverCatalog.load_all()
	var track := TrackCatalog.load_track(tid)
	var clean := 0.0
	for cs in CASES:
		var s := RaceSettings.new()
		s.track_id = tid
		s.ai_count = 1
		s.laps = 3
		s.seed = 11
		s.set_damage_level("full")
		var start := RaceFactory.plan(s, [], cars, drivers, track)
		var sim := RaceFactory.build_sim(start, cars, tyres, track)
		if car_id != "":
			sim.defs[0] = cars[car_id]
		sim.pits.enabled = false   # held damage would only send it in for repairs
		var ai := AIDriver.for_all_ai(sim)
		while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 900:
			_hold(sim.cars[0], cs[0], cs[1])
			sim.step([ai[0].get_input(sim, 0)])
		var e: RaceEntry = sim.entries[0]
		if e.lap_times.size() < 3 or e.dnf:
			print("%-16s %.2f  did not finish (%d laps)" % [cs[0], cs[1], e.lap_times.size()])
			continue
		var t := (float(e.lap_times[1]) + float(e.lap_times[2])) * 0.5
		if cs[0] == "clean":
			clean = t
			print("%s  %s  clean %.3f s" % [tid, sim.defs[0].id, t])
			continue
		print("%-16s %.2f  %.3f s  +%.3f s  %.2f%%" % [cs[0], cs[1], t, t - clean, (t - clean) / clean * 100.0])
	quit()


func _hold(c: CarState, part: String, v: float) -> void:
	match part:
		"aero":
			c.damage_aero = v
			c.body_damage[CarDamage.FRONT] = v
		"suspension":
			c.damage_suspension = v
		"alignment":
			c.alignment = v
		"engine":
			c.damage_engine = v
		"gearbox":
			c.damage_gearbox = v
		"puncture_front":
			c.puncture[0] = v
		"puncture_rear":
			c.puncture[2] = v
