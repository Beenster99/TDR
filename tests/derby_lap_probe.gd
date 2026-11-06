extends SceneTree
## Derby lap probe: one AI car alone in each arena, 3 laps. Average speed on
## the dirt and on the tarmac, and how often it spins.
## godot --headless --path . --script res://tests/derby_lap_probe.gd

func _init() -> void:
	var cars := CarCatalog.load_all()
	var tyres := TyreCatalog.load_all()
	var drivers := DriverCatalog.load_all()
	for tid in TrackCatalog.ids_for(TrackCatalog.list_all(), "derby"):
		var track := TrackCatalog.load_track(tid)
		for car_id in ["derby_brannock_sovereign", "derby_tanaga_comet", "derby_corrigan_trailmaster"]:
			var s := RaceSettings.new()
			s.track_id = tid
			s.ai_count = 0
			s.laps = 3
			s.seed = 7
			s.apply_derby_rules()
			s.ai_count = 1
			var start := RaceFactory.plan(s, [], cars, drivers, track)
			var sim := RaceFactory.build_sim(start, cars, tyres, track)
			sim.defs[0] = cars[car_id]
			var ai := AIDriver.for_all_ai(sim)
			var dirt_v := 0.0; var dirt_n := 0; var tar_v := 0.0; var tar_n := 0; var spins := 0; var was := false
			while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 400:
				sim.step([ai[0].get_input(sim, 0)])
				var c: CarState = sim.cars[0]
				if sim.phase != RaceSim.Phase.RACING or c.air_h > 0.0:
					continue
				if c.dirt > 0.5:
					dirt_v += c.speed(); dirt_n += 1
				else:
					tar_v += c.speed(); tar_n += 1
				var sp := c.speed() > 3.0 and absf(angle_difference(c.heading, c.vel.angle())) > deg_to_rad(50.0)
				if sp and not was:
					spins += 1
				was = sp
			print("%-24s %-26s %6.1f s  tarmac %4.0f km/h  dirt %4.0f km/h  spins %d" % [tid, car_id.trim_prefix("derby_"),
				sim.race_time, tar_v / maxi(tar_n, 1) * 3.6, dirt_v / maxi(dirt_n, 1) * 3.6, spins])
	quit()
