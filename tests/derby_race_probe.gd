extends SceneTree
## Derby race probe: a full AI field in each arena. Counts how often the AI
## gets lost (its line point jumps to another part of the lap, e.g. onto the
## other road at a crossover), drives the wrong way, or backs up (stuck),
## and how far the field gets in the first 15 s.
## godot --headless --path . --script res://tests/derby_race_probe.gd [-- seeds=3 tracks=a,b]

func _init() -> void:
	var cars := CarCatalog.load_all()
	var tyres := TyreCatalog.load_all()
	var drivers := DriverCatalog.load_all()
	var seeds := 3
	var only := []
	var secs := 400.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seeds="):
			seeds = int(a.trim_prefix("seeds="))
		elif a.begins_with("secs="):
			secs = float(a.trim_prefix("secs="))
		elif a.begins_with("tracks="):
			only = a.trim_prefix("tracks=").split(",")
	var tids := TrackCatalog.ids_for(TrackCatalog.list_all(), "derby")
	for tid in tids:
		if not only.is_empty() and not tid in only:
			continue
		var track := TrackCatalog.load_track(tid)
		var tot := {"lost": 0, "wrong": 0.0, "reverse": 0, "start_rev": 0, "d15": 0.0, "slow15": 0, "hits": 0, "time": 0.0, "laps": 0.0, "stuck_out": 0, "wrong_run": 0.0}
		for sd in seeds:
			var s := RaceSettings.new()
			s.track_id = tid
			s.ai_count = 15
			s.laps = 5
			s.seed = 100 + sd * 17
			s.apply_derby_rules()
			var start := RaceFactory.plan(s, [], cars, drivers, track)
			var sim := RaceFactory.build_sim(start, cars, tyres, track)
			var ai := AIDriver.for_all_ai(sim)
			var nc := sim.cars.size()
			var last_idx := []
			var was_rec := []
			var wr := []
			wr.resize(nc); wr.fill(0.0)
			last_idx.resize(nc); last_idx.fill(-1)
			was_rec.resize(nc); was_rec.fill(false)
			var d0 := []
			while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * (secs + 5.0):
				var inputs := []
				for i in nc:
					inputs.append(ai[i].get_input(sim, i) if ai.has(i) else null)
				sim.step(inputs)
				if sim.phase != RaceSim.Phase.RACING:
					continue
				if d0.is_empty():
					for i in nc:
						d0.append(sim.entries[i].distance)
				for e in sim.events:
					if e["type"] == "collision":
						tot["hits"] += 1
					if e["type"] == "retired" and e.get("reason", "") == "stopped":
						tot["stuck_out"] += 1
				var t_race := sim.race_time
				for i in nc:
					if sim.entries[i].dnf:
						continue
					var d: AIDriver = ai[i]
					var n := d.line.size()
					var c: CarState = sim.cars[i]
					if last_idx[i] >= 0:
						var j := wrapi(d.idx - last_idx[i], -n / 2, n / 2)
						if absi(j) > 12:
							tot["lost"] += 1
					last_idx[i] = d.idx
					if c.speed() > 4.0 and c.vel.dot(d.line[(d.idx + 1) % n] - d.line[d.idx]) < -0.3 * c.speed() * AIDriver.SPACING:
						tot["wrong"] += RaceSim.TICK_DT
						wr[i] += RaceSim.TICK_DT
						tot["wrong_run"] = maxf(tot["wrong_run"], wr[i])
					else:
						wr[i] = 0.0
					var rec := d.recover_time > 0.0
					if rec and not was_rec[i]:
						tot["reverse"] += 1
						if t_race < 15.0:
							tot["start_rev"] += 1
					was_rec[i] = rec
				if absf(t_race - 15.0) < RaceSim.TICK_DT * 0.5:
					for i in nc:
						var dd: float = sim.entries[i].distance - d0[i]
						tot["d15"] += dd / nc
						if dd < 100.0:
							tot["slow15"] += 1
			tot["time"] += sim.race_time
			var lp := 0.0
			for i in nc:
				lp += sim.entries[i].laps_done
			tot["laps"] += lp / nc
		print("%-24s lost %3d  wrong-way %5.1f s (longest %.1f s)  reverses %3d (start %2d)  15s avg %4.0f m (<100 m: %2d)  hits %4d  stopped-out %2d  laps %.1f  %.0f s" % [
			tid, tot["lost"], tot["wrong"], tot["wrong_run"], tot["reverse"], tot["start_rev"], tot["d15"] / seeds, tot["slow15"],
			tot["hits"], tot["stuck_out"], tot["laps"] / seeds, tot["time"] / seeds])
	quit()
