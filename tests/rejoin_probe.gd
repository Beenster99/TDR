extends SceneTree
## Rejoin probe: how safely AI cars come back onto the track after an off.
##   godot --headless --path . --script res://tests/rejoin_probe.gd -- [trials per track] [tracks,comma,separated]
## Each trial races an AI field for a while, then puts one car off the track
## (on the run-off beside the road, slow, nose angled back at the track) just
## ahead of another car, and watches the next 20 s:
##   contact   the rejoining car touched another car
##   cut       the rejoining car was in an approaching car's path with less
##             than 1.5 s before that car reached it
##   crossed   it crossed the racing line while a car was under 2.5 s behind
##   rejoin    seconds until it was back on the road and racing again (up to speed,
##             or past the edge it holds after rejoining)
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var trials := int(args[0]) if args.size() > 0 else 6
	var tracks := (args[1] if args.size() > 1 else "brands_hatch,spa,monza,silverstone,imola,suzuka").split(",")
	var cars := CarCatalog.load_all()
	var drivers := DriverCatalog.load_all()
	var tyres := TyreCatalog.load_all()
	var tot := {"trials": 0, "contact": 0, "cut": 0, "crossed": 0, "slow": 0, "rejoin": 0.0}
	for tid in tracks:
		var row := {"trials": 0, "contact": 0, "cut": 0, "crossed": 0, "slow": 0, "rejoin": 0.0}
		for t in trials:
			var r := _trial(tid, t, cars, drivers, tyres)
			if r.is_empty():
				continue
			if OS.get_environment("REJOIN_VERBOSE") != "":
				print("  ", tid, " #", t, " ", r)
			for k in ["contact", "cut", "crossed", "slow"]:
				row[k] += int(r[k])
			row["rejoin"] += r["rejoin"]
			row["trials"] += 1
		print("%-14s trials %2d  contact %2d  cut %2d  crossed %2d  >15s %2d  mean rejoin %.1f s" % [tid, row["trials"],
			row["contact"], row["cut"], row["crossed"], row["slow"], row["rejoin"] / maxf(row["trials"], 1)])
		for k in row:
			tot[k] += row[k]
	print("TOTAL          trials %2d  contact %2d  cut %2d  crossed %2d  >15s %2d  mean rejoin %.1f s" % [tot["trials"],
		tot["contact"], tot["cut"], tot["crossed"], tot["slow"], tot["rejoin"] / maxf(tot["trials"], 1)])
	quit()


func _trial(tid: String, t: int, cars: Dictionary, drivers, tyres: Dictionary) -> Dictionary:
	var settings := RaceSettings.new()
	settings.ai_count = 10
	settings.track_id = tid
	settings.seed = 100 + t * 13
	settings.laps = 20
	var start := RaceFactory.plan(settings, [], cars, drivers)
	var sim := RaceFactory.build_sim(start, cars, tyres)
	var ai := AIDriver.for_all_ai(sim)
	var n := sim.car_count()
	var rng := RandomNumberGenerator.new()
	rng.seed = settings.seed
	var green := -1
	var warm := 60 * (40 + t * 7)
	var victim := -1
	var side := 0
	var t0 := 0
	var res := {"contact": false, "cut": false, "crossed": false, "slow": false, "rejoin": 20.0}
	var rejoined := false
	var prev_line_side := 0
	var L := sim.track.length
	while true:
		var inputs := []
		for i in n:
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		if sim.phase == RaceSim.Phase.RACING and green < 0:
			green = sim.tick
		if green < 0:
			continue
		var since := sim.tick - green
		if victim < 0 and since >= warm:
			victim = _pick(sim, rng)
			if victim < 0:
				if since > warm + 60 * 30:
					return {}
				continue
			var c := sim.cars[victim]
			var q := sim.track.project(c.pos, c.track_idx)
			side = 1 if rng.randf() < 0.5 else -1
			var w: float = q["w_right"] if side > 0 else q["w_left"]
			var s: float = q["s"]
			c.pos = sim.track.position_at(s, side * (w + sim.track.kerb_width + 2.5))
			c.heading = sim.track.heading_at(s) - side * rng.randf_range(0.15, 0.6)
			c.vel = Vector2.from_angle(c.heading) * rng.randf_range(5.0, 14.0)
			c.yaw_rate = 0.0
			sim._refresh_track_position(c)
			ai[victim].idx = -1
			t0 = sim.tick
			prev_line_side = 0
			continue
		if victim < 0:
			continue
		var dt := (sim.tick - t0) * RaceSim.TICK_DT
		if dt > 20.0:
			break
		var c := sim.cars[victim]
		var d: AIDriver = ai[victim]
		for ev in sim.events:
			if ev.get("type") == "incident" and int(ev.get("other", -1)) >= 0 \
					and (int(ev["car"]) == victim or int(ev["other"]) == victim):
				res["contact"] = true
		var k := d._nearest(c.pos)
		var on_road := c.surface <= TrackData.Surface.KERB
		if not rejoined and on_road and (d.rejoin_side == 0 if "rejoin_side" in d else c.speed() > d.target_speed[k] * 0.7):
			rejoined = true
			res["rejoin"] = dt
		# Traffic behind on the road: time until it reaches us, and whether we are in its path.
		var close_behind := INF
		for j in n:
			if j == victim:
				continue
			var o := sim.cars[j]
			if o.surface > TrackData.Surface.KERB:
				continue
			var gap := fposmod(c.track_s - o.track_s, L)
			if gap > 150.0 or gap < 1.0:
				continue
			var closing := o.speed() - c.vel.dot(Vector2.from_angle(sim.track.heading_at(c.track_s)))
			var ttc := gap / maxf(closing, 0.1)
			if closing > 1.0:
				close_behind = minf(close_behind, ttc)
			var lat_gap := absf(c.lateral_offset - o.lateral_offset)
			if on_road and lat_gap < (sim.defs[victim].width + sim.defs[j].width) * 0.5 + 0.3 and closing > 3.0 and ttc < 1.5:
				res["cut"] = true
		if OS.get_environment("REJOIN_TRACE") == str(t) and (sim.tick - t0) % 15 == 0:
			var near := ""
			for j in n:
				var g := fposmod(c.track_s - sim.cars[j].track_s, L)
				if j != victim and (g < 120.0 or g > L - 20.0):
					near += " [%d gap %.0f lat %.1f v %.0f surf %d]" % [j, g if g < L * 0.5 else g - L, sim.cars[j].lateral_offset, sim.cars[j].speed(), sim.cars[j].surface]
			print("%5.2f surf %d lat %.1f v %.1f side %d wait %.1f mood %d%s" % [dt, c.surface, c.lateral_offset, c.speed(),
				d.rejoin_side if "rejoin_side" in d else 0, d._rejoin_wait if "_rejoin_wait" in d else 0.0, d.mood, near])
			for ev in sim.events:
				if ev.get("type") == "incident":
					print("   ", ev)
		var ls := signi(int(signf(d._line_offset(c.pos, k))))
		if prev_line_side != 0 and ls != 0 and ls != prev_line_side and close_behind < 2.5:
			res["crossed"] = true
		if ls != 0:
			prev_line_side = ls
	res["wait"] = ai[victim]._rejoin_wait if "_rejoin_wait" in ai[victim] else 0.0
	res["surface"] = sim.cars[victim].surface
	res["speed"] = sim.cars[victim].speed()
	if not rejoined:
		res["slow"] = true
	elif res["rejoin"] > 15.0:
		res["slow"] = true
	return res


## A car on the road, racing, with another car 40..110 m behind it on the road.
func _pick(sim: RaceSim, rng: RandomNumberGenerator) -> int:
	var n := sim.car_count()
	var L := sim.track.length
	var cands := []
	for i in n:
		var c := sim.cars[i]
		if c.surface != TrackData.Surface.TRACK or c.speed() < 25.0 or sim.in_pit_lane(i):
			continue
		for j in n:
			if j == i or sim.cars[j].surface != TrackData.Surface.TRACK:
				continue
			var gap := fposmod(c.track_s - sim.cars[j].track_s, L)
			if gap > 40.0 and gap < 110.0:
				cands.append(i)
				break
	if cands.is_empty():
		return -1
	return cands[rng.randi() % cands.size()]
