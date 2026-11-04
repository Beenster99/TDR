extends SceneTree
## Race control incident count over AI-only races (tuning aid, not part of the test run):
##   godot --headless --path . --script res://tests/incident_report.gd -- [tracks,comma] [seeds] [cars] [laps] [class] [first seed]
## Runs one race per track and seed with full damage, flags and safety car on,
## and counts what brings out the flags: yellow flags by reason, VSC and
## safety car deployments, car-to-car contacts (heavy ones too), offs (by
## cause), spins, retirements. Ends with a TOTAL line per track and overall.
## INCIDENT_VERBOSE=1 prints every flag as it happens; INCIDENT_MISTAKES=3 sets
## the "AI mistakes" race setting (RaceSettings.ai_mistakes).

const HEAVY := 0.35   ## RaceControl.CONTACT_DEBRIS_SEV: contact that leaves debris


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var tracks: PackedStringArray = (a[0] if a.size() > 0 else "spielberg,brands_hatch,monza,spa,imola,silverstone").split(",")
	var seeds := int(a[1]) if a.size() > 1 else 2
	var cars_n := int(a[2]) if a.size() > 2 else 20
	var laps := int(a[3]) if a.size() > 3 else 5
	var klass: String = a[4] if a.size() > 4 else "GT3"
	var first := int(a[5]) if a.size() > 5 else 0
	var verbose := OS.get_environment("INCIDENT_VERBOSE") == "1"
	var cars := CarCatalog.load_all()
	var tyres := TyreCatalog.load_all()
	var drivers := DriverCatalog.load_all()
	var grand := {}
	for track_id in tracks:
		var per_track := {}
		for sd in range(first, first + seeds):
			var settings := RaceSettings.new()
			settings.track_id = track_id
			settings.laps = laps
			settings.ai_count = cars_n
			settings.seed = 1000 + sd * 7919
			settings.car_class = klass
			settings.set_damage_level("full")
			if OS.get_environment("INCIDENT_MISTAKES") != "":
				settings.ai_mistakes = float(OS.get_environment("INCIDENT_MISTAKES"))
			var start := RaceFactory.plan(settings, [], cars, drivers)
			var sim := RaceFactory.build_sim(start, cars, tyres, TrackCatalog.load_track(track_id))
			var ai := AIDriver.for_all_ai(sim)
			var r := _run(sim, ai, verbose)
			print("%-14s seed %d: %s" % [track_id, sd, _fmt(r)])
			_add(per_track, r)
		print("%-14s TOTAL: %s" % [track_id, _fmt(per_track)])
		_add(grand, per_track)
	print("ALL TOTAL (%d races): %s" % [tracks.size() * seeds, _fmt(grand)])
	quit()


func _run(sim: RaceSim, ai: Dictionary, verbose: bool) -> Dictionary:
	var n := sim.car_count()
	var r := {"yellow": 0, "y_off": 0, "y_spun": 0, "y_stopped": 0, "y_crash": 0, "y_other": 0,
		"vsc": 0, "sc": 0, "contacts": 0, "heavy": 0, "offs": 0, "offs_contact": 0, "offs_mistake": 0,
		"spins": 0, "dnf": 0, "best_sum": 0.0, "best_n": 0, "race_s": 0.0}
	var was_off := PackedByteArray(); was_off.resize(n)
	var was_spun := PackedByteArray(); was_spun.resize(n)
	var last_contact := PackedInt32Array(); last_contact.resize(n); last_contact.fill(-9999)
	var pair_seen := {}
	var trace := OS.get_environment("INCIDENT_TRACE").split(":") if OS.get_environment("INCIDENT_TRACE") != "" else PackedStringArray()
	var kinds := {}
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 40:
		var inputs := []
		for i in n:
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		for e in sim.events:
			match e["type"]:
				"collision":
					var key := "%d-%d" % [mini(e["a"], e["b"]), maxi(e["a"], e["b"])]
					# One contact = one touch; the physics reports every tick they overlap.
					if sim.tick - int(pair_seen.get(key, -9999)) > 60:
						r["contacts"] += 1
						var ca := sim.cars[e["a"]]
						var rel: Vector2 = sim.cars[e["b"]].pos - ca.pos
						var back: int = e["a"] if rel.dot(ca.forward()) > 0.0 else e["b"]
						var kind := "%s/%s" % ["side" if absf(rel.dot(ca.right())) > 1.4 else "rear", AIDriver.Mood.keys()[ai[back].mood]]
						kinds[kind] = kinds.get(kind, 0) + 1
						if verbose:
							print("  [%6.1f] contact %s at %.0f m, lap %d" % [sim.race_time, kind, ca.track_s, sim.entries[back].laps_done + 1])
					pair_seen[key] = sim.tick
					last_contact[e["a"]] = sim.tick
					last_contact[e["b"]] = sim.tick
				"incident":
					if e.get("kind", "") in ["collision", "impact"] and float(e.get("severity", 0.0)) >= HEAVY:
						r["heavy"] += 1
				"flag":
					if e["flag"] == "yellow":
						r["yellow"] += 1
						var why: String = e.get("reason", "")
						if why.begins_with("Car off"): r["y_off"] += 1
						elif why.begins_with("Car spun"): r["y_spun"] += 1
						elif why.begins_with("Car stopped"): r["y_stopped"] += 1
						elif why.begins_with("Crash"): r["y_crash"] += 1
						else: r["y_other"] += 1
						if verbose:
							print("  [%6.1f] yellow: %s" % [sim.race_time, why])
				"safety_car":
					if e.get("state", "") == "vsc":
						r["vsc"] += 1
					elif e.get("state", "") == "out" or e.get("state", "") == "sc":
						r["sc"] += 1
					if verbose:
						print("  [%6.1f] %s: %s" % [sim.race_time, e.get("state", ""), e.get("reason", "")])
		if trace.size() == 3:
			for i in n:
				var c := sim.cars[i]
				if sim.entries[i].driver_name == trace[0] and c.track_s > float(trace[1]) and c.track_s < float(trace[2]) and sim.tick % 6 == 0:
					var d: AIDriver = ai[i]
					var inp: CarInput = inputs[i]
					var q := sim.track.project(c.pos, c.track_idx)
					var near := ""
					for j in n:
						var rel := sim.cars[j].pos - c.pos
						if j != i and rel.length() < 25.0:
							near += " %s(%.0f,%.1f)" % [sim.entries[j].driver_name.substr(0, 4), rel.dot(c.forward()), rel.dot(c.right())]
					print("  T L%d s=%.0f v=%.1f tgt=%.1f lat=%.1f/%.1f/%.1f surf=%d mood=%s bias=%.1f lineoff=%.1f thr=%.2f brk=%.2f st=%.2f slipR=%.2f yaw=%.2f%s" % [sim.entries[i].laps_done + 1, c.track_s, c.speed(), d.target_speed[d.idx], q["offset"], q["w_left"], q["w_right"], c.surface,
						AIDriver.Mood.keys()[d.mood], d.lateral_bias, (c.pos - d.line[d.idx]).dot(d.line_right[d.idx]), inp.throttle, inp.brake, inp.steer, c.slip_angle_rear, c.yaw_rate, near])
		if sim.phase != RaceSim.Phase.RACING:
			continue
		for i in n:
			var c := sim.cars[i]
			var off := c.surface >= TrackData.Surface.GRASS
			if off and not was_off[i] and not sim.entries[i].finished:
				r["offs"] += 1
				if verbose:
					print("  [%6.1f] off %s at %.0f m mood %s bias %.1f lap %d%s" % [sim.race_time, sim.entries[i].driver_name, c.track_s,
						AIDriver.Mood.keys()[ai[i].mood], ai[i].lateral_bias, sim.entries[i].laps_done + 1, " after contact" if sim.tick - last_contact[i] < 120 else ""])
					print("           v %.1f susp %.2f aero %.2f punct %s align %.2f temps %.0f/%.0f/%.0f/%.0f learn %.3f" % [c.speed(), c.damage_suspension, c.damage_aero, c.puncture, c.alignment,
						c.tyre_temp[0], c.tyre_temp[1], c.tyre_temp[2], c.tyre_temp[3], ai[i].learn[maxi(ai[i].idx, 0) / AIDriver.BLOCK]])
				if sim.tick - last_contact[i] < 120:
					r["offs_contact"] += 1
				elif ai[i].mood == AIDriver.Mood.MISTAKE:
					r["offs_mistake"] += 1
			was_off[i] = int(off)
			var facing := Vector2.from_angle(c.heading).dot(Vector2.from_angle(sim.track.heading_at(c.track_s)))
			var spun := facing < -0.25 and c.speed() > 1.0
			if spun and not was_spun[i]:
				r["spins"] += 1
			was_spun[i] = int(spun)
	for i in n:
		if sim.entries[i].dnf:
			r["dnf"] += 1
		if sim.entries[i].best_lap > 0.0:
			r["best_sum"] += sim.entries[i].best_lap
			r["best_n"] += 1
	r["race_s"] = sim.race_time
	if verbose:
		print("  contacts by kind (car behind's mood): ", kinds)
	return r


func _add(into: Dictionary, r: Dictionary) -> void:
	for k in r:
		into[k] = into.get(k, 0) + r[k]


func _fmt(r: Dictionary) -> String:
	var avg := float(r["best_sum"]) / maxf(float(r["best_n"]), 1.0)
	return "yellows %d (off %d, spun %d, stopped %d, crash %d, other %d)  VSC %d  SC %d  contacts %d (heavy %d)  offs %d (after contact %d, mistake %d)  spins %d  DNF %d  avg best lap %.2f s" % [
		r["yellow"], r["y_off"], r["y_spun"], r["y_stopped"], r["y_crash"], r["y_other"], r["vsc"], r["sc"],
		r["contacts"], r["heavy"], r["offs"], r["offs_contact"], r["offs_mistake"], r["spins"], r["dnf"], avg]
