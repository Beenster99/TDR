extends SceneTree
## Headless test runner:
##   godot --headless --path . --script res://tests/run_tests.gd
## Exits with code 0 on success, 1 on failure.

var failures := 0


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	test_module_boundaries()
	test_data_loads()
	test_input_wire_format()
	test_tyre_temperature_matters()
	test_ai_drivers()
	test_car_classes()
	test_every_track()
	test_weather_and_time()
	test_wet_grip()
	test_race_settings_and_grid()
	test_damage()
	test_elevation()
	test_barriers()
	var replay := test_ai_race_completes()
	test_deterministic_replay(replay)
	test_snapshot_restore(replay)
	test_telemetry(replay)
	test_weather_forecast()
	print("\n%s (%d failures, %.1fs)" % ["PASS" if failures == 0 else "FAIL", failures, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(1 if failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failures += 1
		printerr("  FAIL ", msg)


## Modules (docs/MODULES.md): manifests are valid, and every module only
## uses the public API of modules it declares in "depends".
func test_module_boundaries() -> void:
	print("modules")
	var mods := ModuleRegistry.load_all()
	check(mods.size() >= 12, "%d module manifests load" % mods.size())
	var problems := ModuleRegistry.check(mods)
	for p in problems:
		printerr("       ", p)
	check(problems.is_empty(), "dependencies exist, match versions and have no cycles")
	# Which module owns each public name (class_name or autoload).
	var owner := {}
	var declared := {}
	for id in mods:
		for name in mods[id].get("api", []) + mods[id].get("autoloads", []):
			owner[name] = id
	var leaks: Array[String] = []
	var sources := {}
	for id in mods:
		var files := _gd_files("res://modules/" + id)
		for f in files:
			var code := _strip_comments(FileAccess.get_file_as_string(f))
			sources[f] = [id, code]
			var m := RegEx.create_from_string("(?m)^class_name\\s+(\\w+)").search(code)
			if m:
				declared[m.get_string(1)] = [id, f]
	for name in declared:
		var home: String = declared[name][0]
		if owner.get(name, "") != home and not name in mods[home].get("internal", []):
			leaks.append("%s declares class %s, but its module.json lists it in neither api nor internal" % [declared[name][1], name])
	var word := RegEx.create_from_string("\\b[A-Z][A-Za-z0-9_]*\\b")
	for f in sources:
		var id: String = sources[f][0]
		var deps: Dictionary = mods[id].get("depends", {})
		var seen := {}
		for m in word.search_all(sources[f][1]):
			var name := m.get_string()
			if seen.has(name):
				continue
			seen[name] = true
			var other: String = owner.get(name, "")
			if other == "" and declared.has(name):
				other = declared[name][0]
			if other == "" or other == id:
				continue
			if not deps.has(other):
				leaks.append("%s uses %s from module %s, which isn't in its depends" % [f, name, other])
			elif name in mods[other].get("internal", []):
				leaks.append("%s uses %s, which is internal to module %s" % [f, name, other])
	for l in leaks:
		printerr("       ", l)
	check(leaks.is_empty(), "modules only use public API of modules they depend on")
	var order := ModuleRegistry.ordered(mods)
	print("       ", ", ".join(order.map(func(i): return "%s %s" % [i, mods[i]["version"]])))


func _gd_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_gd_files(dir + "/" + d))
	return out


## Drops comments and string contents so only real code is scanned.
func _strip_comments(code: String) -> String:
	var out := PackedStringArray()
	for line in code.split("\n"):
		var kept := ""
		var quote := ""
		for ch in line:
			if quote != "":
				if ch == quote:
					quote = ""
				continue
			if ch == "#":
				break
			if ch == "\"" or ch == "'":
				quote = ch
				continue
			kept += ch
		out.append(kept)
	return "\n".join(out)


func _data() -> Dictionary:
	return {"cars": CarCatalog.load_all(), "tyres": TyreCatalog.load_all(),
		"drivers": DriverCatalog.load_all(), "track": TrackCatalog.load_track("spielberg")}


## Plans and builds an AI-only race. Returns {sim, ai}.
func _race(settings: RaceSettings, d: Dictionary) -> Dictionary:
	var start := RaceFactory.plan(settings, [], d["cars"], d["drivers"])
	var sim := RaceFactory.build_sim(start, d["cars"], d["tyres"], d["track"])
	return {"sim": sim, "ai": AIDriver.for_all_ai(sim)}


func test_data_loads() -> void:
	print("data")
	var d := _data()
	check(d["cars"].size() >= 4, "cars load (%d)" % d["cars"].size())
	check(d["tyres"].has("road_semi_slick"), "tyre compounds load")
	var track: TrackData = d["track"]
	check(track != null and absf(track.length - 4315.0) < 20.0, "Spielberg loads, %.0f m" % track.length)
	for id in d["cars"]:
		var c: CarDefinition = d["cars"][id]
		print("       %-22s %4.0f kg %4.0f kW" % [c.display_name, c.mass, c.peak_power_kw()])


## Classes: a fixed class gives everyone that class's cars; multi-class
## spreads the AI over every class.
func test_car_classes() -> void:
	print("car classes")
	var d := _data()
	var classes := CarCatalog.classes(d["cars"])
	check(classes.size() >= 2 and classes[0] == "GT3", "classes, fastest first: %s" % [classes])
	var s := RaceSettings.new()
	s.ai_count = 9
	s.car_class = "GT3"
	var start := RaceFactory.plan(s, [{"name": "P", "car_id": "v8_mid_berlinetta"}], d["cars"], d["drivers"])
	var all_gt3 := true
	for e in start["entries"]:
		all_gt3 = all_gt3 and d["cars"][e["car_id"]].class_tag == "GT3"
	check(all_gt3, "GT3 race: every car is a GT3 (a player's road car is swapped)")
	s.car_class = RaceSettings.CLASS_MULTI
	start = RaceFactory.plan(s, [], d["cars"], d["drivers"])
	var seen := {}
	for e in start["entries"]:
		seen[d["cars"][e["car_id"]].class_tag] = true
	check(seen.size() == classes.size(), "multi-class race uses every class (%s)" % [seen.keys()])
	s.car_class = ""
	start = RaceFactory.plan(s, [{"name": "P", "car_id": "flat6_rear_gt"}], d["cars"], d["drivers"])
	var road := true
	for e in start["entries"]:
		road = road and d["cars"][e["car_id"]].class_tag == "Road"
	check(road, "open class: AI match the player's class")


## Every track: loads, is the real length, has a usable pit lane, and an AI
## car can drive a clean lap of it.
func test_every_track() -> void:
	print("tracks")
	var d := _data()
	var list := TrackCatalog.list_all()
	check(list.size() >= 5, "%d tracks listed" % list.size())
	for info in list:
		var t := TrackCatalog.load_track(info["id"])
		if t == null:
			check(false, "%s loads" % info["id"])
			continue
		var problems: Array[String] = []
		if not t.has_pit_lane():
			problems.append("no pit lane")
		else:
			var a := t.project(t.pit_path[0])
			var b := t.project(t.pit_path[t.pit_path.size() - 1])
			if absf(a["offset"]) > t.width_right[a["idx"]] + t.width_left[a["idx"]]:
				problems.append("pit entry %.0f m off the track" % a["offset"])
			if absf(b["offset"]) > t.width_right[b["idx"]] + t.width_left[b["idx"]]:
				problems.append("pit exit %.0f m off the track" % b["offset"])
			var box := t.pit_box(0)
			if not t.in_pit_lane(box["pos"]):
				problems.append("pit box 0 outside the lane")
			if t.surface_for(t.project(box["pos"])) != TrackData.Surface.TRACK:
				problems.append("pit lane isn't tarmac")
			if t.pit_length < 150.0:
				problems.append("pit lane only %.0f m" % t.pit_length)
		var lap := _solo_lap(t, d)
		if lap["time"] <= 0.0:
			problems.append("AI didn't finish a lap")
		if lap["offs"] > 6:  # the AI thread is still improving how cleanly it drives
			problems.append("AI went off %d times" % lap["offs"])
		for pr in problems:
			printerr("       ", t.id, ": ", pr)
		check(problems.is_empty(), "%-34s %5.0f m, pit lane %4.0f m (%s), AI lap %s, %d offs" % [t.display_name,
			t.length, t.pit_length, "right" if t.pit_side > 0 else "left", _laptime(lap["time"]), lap["offs"]])


## Elevation: every track has real heights in the right range, and physics
## feels them (rolls back on a hill, slower uphill, light over a crest).
func test_elevation() -> void:
	print("elevation")
	# Real lowest-to-highest height of the lap, roughly (metres): [min, max].
	var real := {"spa": [85, 125], "spielberg": [50, 80], "interlagos": [30, 55], "austin": [28, 55],
		"mugello": [32, 60], "monza": [5, 25], "silverstone": [5, 25], "bahrain": [8, 30], "melbourne": [0, 12]}
	for info in TrackCatalog.list_all():
		var t := TrackCatalog.load_track(info["id"])
		var r := t.height_range()
		var ok := t.has_elevation() and t.terrain_size.x > 10 and t.terrain_size.y > 10
		if real.has(t.id):
			ok = ok and r.y - r.x >= real[t.id][0] and r.y - r.x <= real[t.id][1]
		var steep := 0.0
		for k in t.point_count():
			steep = maxf(steep, absf(t.grade_at(t.cum_s[k])))
		ok = ok and steep <= 0.21
		check(ok, "%-34s %5.1f m high, steepest %4.1f%%, base %4.0f m above sea" % [t.display_name, r.y - r.x, steep * 100.0, t.base_alt_m])
	# Physics on Spa: find the steepest climb and the sharpest crest.
	var d := _data()
	var spa := TrackCatalog.load_track("spa")
	var def: CarDefinition = d["cars"]["porsche_911_gt3_r"]
	var tc: TyreCompound = d["tyres"][def.tyre_compound_id] if d["tyres"].has(def.tyre_compound_id) else d["tyres"].values()[0]
	var env := SimEnvironment.from_dict({})
	var climb_s := 0.0
	var crest_s := 0.0
	for k in spa.point_count():
		var s := spa.cum_s[k]
		if spa.grade_at(s) > spa.grade_at(climb_s):
			climb_s = s
		if spa.vertical_curvature_at(s) < spa.vertical_curvature_at(crest_s):
			crest_s = s
	var parked := _car_at(spa, climb_s, 0.0)
	var none := CarInput.new()
	for i in 120:
		CarPhysics.step(parked, none, def, tc, env, spa, 1.0 / 60.0, 0.0, [], 0)
	var back := parked.vel.dot(Vector2.from_angle(spa.heading_at(climb_s)))
	check(back < -0.5, "parked on a %.0f%% climb with no brakes, the car rolls back (%.1f m/s)" % [spa.grade_at(climb_s) * 100.0, back])
	var held := _car_at(spa, climb_s, 0.0)
	var brake := CarInput.new()
	brake.brake = 0.4  # below the "hold brake to reverse" threshold
	for i in 120:
		CarPhysics.step(held, brake, def, tc, env, spa, 1.0 / 60.0, 0.0, [], 0)
	check(held.vel.length() < 0.5, "with the brakes on it stays put (%.2f m/s)" % held.vel.length())
	var up := _car_at(spa, climb_s - 40.0, 30.0)
	var flat_track := TrackCatalog.load_track("spa")
	flat_track.height = PackedFloat64Array()
	var flat := _car_at(flat_track, climb_s - 40.0, 30.0)
	var go := CarInput.new()
	go.throttle = 1.0
	for i in 60:
		CarPhysics.step(up, go, def, tc, env, spa, 1.0 / 60.0, 0.0, [], 0)
		CarPhysics.step(flat, go, def, tc, env, flat_track, 1.0 / 60.0, 0.0, [], 0)
	check(up.speed() < flat.speed() - 0.5, "full throttle up the hill is slower than on the flat (%.1f vs %.1f m/s)" % [up.speed(), flat.speed()])
	var crest := _car_at(spa, crest_s, 60.0)
	CarPhysics.step(crest, none, def, tc, env, spa, 1.0 / 60.0, 0.0, [], 0)
	check(crest.load_factor < 0.95, "over the sharpest crest at 216 km/h the car goes light (%.2f g)" % crest.load_factor)


## Barriers: every track says what's at the edge of its run-off, gravel slows
## a car more than grass, and a tyre wall throws a car back less than a wall.
func test_barriers() -> void:
	print("barriers")
	for info in TrackCatalog.list_all():
		var t := TrackCatalog.load_track(info["id"])
		var n := t.point_count()
		var kinds := {}
		var gravel := 0
		for k in n:
			kinds[t.barrier_left[k] if t.barrier_left.size() == n else -1] = true
			kinds[t.barrier_right[k] if t.barrier_right.size() == n else -1] = true
			if t.runoff_left.size() == n and t.runoff_left[k] == TrackData.Surface.GRAVEL:
				gravel += 1
		var names := []
		for kd in kinds:
			names.append(TrackData.BARRIER_NAMES.get(kd, "none"))
		check(t.barrier_left.size() == n and t.runoff_right.size() == n and not kinds.has(-1),
			"%-34s %s; %d%% gravel on the left" % [t.display_name, ", ".join(names), 100 * gravel / n])
	var d := _data()
	var def: CarDefinition = d["cars"]["porsche_911_gt3_r"]
	var tc: TyreCompound = d["tyres"].values()[0]
	var env := SimEnvironment.from_dict({})
	var spa := TrackCatalog.load_track("spa")
	var speeds := {}
	for kind in [TrackData.Barrier.WALL, TrackData.Barrier.TYRES]:
		spa.barrier_right.fill(kind)
		var c := _car_at(spa, 2000.0, 0.0)
		c.pos = spa.position_at(2000.0, spa.width_right[spa.index_at(2000.0)] + spa.runoff + 0.5)
		c.vel = Vector2(-spa.seg_dir[spa.index_at(2000.0)].y, spa.seg_dir[spa.index_at(2000.0)].x) * 20.0
		var evs := []
		CarPhysics.step(c, CarInput.new(), def, tc, env, spa, 1.0 / 60.0, 0.0, evs, 0)
		speeds[kind] = c.vel.length()
		check(evs.size() > 0 and evs[0].get("barrier", -1) == kind, "a hit reports the barrier type (%s)" % TrackData.BARRIER_NAMES[kind])
	check(speeds[TrackData.Barrier.TYRES] < speeds[TrackData.Barrier.WALL], "a tyre wall bounces the car back less than a concrete wall (%.1f vs %.1f m/s)" % [speeds[TrackData.Barrier.TYRES], speeds[TrackData.Barrier.WALL]])
	check(TrackData.BARRIER_HARDNESS[TrackData.Barrier.TYRES] < TrackData.BARRIER_HARDNESS[TrackData.Barrier.ARMCO] and TrackData.BARRIER_HARDNESS[TrackData.Barrier.ARMCO] < TrackData.BARRIER_HARDNESS[TrackData.Barrier.WALL], "damage: tyre wall < armco < concrete wall")


func _car_at(t: TrackData, s: float, speed: float) -> CarState:
	var c := CarState.new()
	c.pos = t.position_at(s)
	c.heading = t.heading_at(s)
	c.vel = Vector2.from_angle(c.heading) * speed
	c.track_idx = t.index_at(s)
	c.gear = 2 if speed > 10.0 else 1
	return c


## One AI car (a GT3) drives one flying lap of a track on its own.
func _solo_lap(track: TrackData, d: Dictionary) -> Dictionary:
	var s := RaceSettings.new()
	s.track_id = track.id
	s.ai_count = 0
	s.laps = 2
	s.countdown_s = 0.5
	var start := RaceFactory.plan(s, [{"name": "bot", "car_id": "porsche_911_gt3_r"}], d["cars"], [])
	var sim := RaceFactory.build_sim(start, d["cars"], d["tyres"], track)
	var ai := AIDriver.new(track, sim.defs[0], sim.compounds[0], {"skill": 0.95, "consistency": 1.0}, 1)
	var offs := 0
	var was_off := false
	while sim.entries[0].laps_done < 2 and sim.tick < 60 * 600:
		sim.step([ai.get_input(sim, 0)])
		var off := sim.cars[0].surface >= TrackData.Surface.GRASS
		if off and not was_off:
			offs += 1
		was_off = off
	var e := sim.entries[0]
	return {"time": e.lap_times[1] if e.lap_times.size() > 1 else -1.0, "offs": offs}


func test_input_wire_format() -> void:
	print("input")
	var i := CarInput.new()
	i.throttle = 0.73; i.brake = 0.0; i.steer = -0.41; i.shift_up = true
	var j := CarInput.from_bytes(i.to_bytes())
	check(absf(j.throttle - 0.73) < 0.005 and absf(j.steer + 0.41) < 0.01 and j.shift_up, "4-byte input round trip")
	var q := i.quantized()
	check(q.to_bytes() == q.quantized().to_bytes(), "quantize is idempotent")


## Same car, same lap, cold vs optimal tyres: cold tyres must give less grip.
func test_tyre_temperature_matters() -> void:
	print("tyres")
	var d := _data()
	var tc: TyreCompound = d["tyres"]["road_semi_slick"]
	check(tc.temp_grip_factor(tc.optimal_temp_c) == 1.0, "peak grip at optimal temp")
	check(tc.temp_grip_factor(20.0) < 0.85, "cold tyre grip %.2f" % tc.temp_grip_factor(20.0))
	check(tc.temp_grip_factor(140.0) < 0.85, "overheated grip %.2f" % tc.temp_grip_factor(140.0))
	# Hot vs cold ambient changes air density -> power.
	var hot := SimEnvironment.from_dict({"ambient_c": 38.0})
	var cold := SimEnvironment.from_dict({"ambient_c": 5.0})
	check(cold.air_density() > hot.air_density(), "cold air denser (%.3f vs %.3f)" % [cold.air_density(), hot.air_density()])


func _fmt(a: PackedFloat64Array) -> String:
	var s := []
	for v in a: s.append("%.0f" % v)
	return "[" + ", ".join(s) + "]"


## Full AI-only race. Returns recorded inputs for the replay tests.
func test_ai_race_completes() -> Dictionary:
	print("race")
	var d := _data()
	var settings := RaceSettings.new()
	settings.laps = 2
	settings.ai_count = 8
	settings.seed = 777
	settings.set_damage_level("full")  # determinism / snapshot tests cover damage too
	var race := _race(settings, d)
	var sim: RaceSim = race["sim"]
	var ai: Dictionary = race["ai"]
	var recorded: Array = []
	var start_hash := sim.state_hash()
	var collisions := 0
	var max_ticks := 60 * 60 * 8
	var mid_snapshot := {}
	var mid_tick := 60 * 45
	# Race data watches the whole race; the determinism test replays without
	# it, which proves it never changes the race.
	var tel := RaceTelemetry.create(sim)
	var feed_events := 0
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < max_ticks:
		if sim.tick == mid_tick:
			mid_snapshot = sim.snapshot()
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		recorded.append(inputs)
		if sim.tick == 60 * 30:
			sim.post_event({"type": "radio", "car": 2, "topic": "tyres", "text": "Rears are going off"})
			sim.post_event({"type": "strategy", "car": 3, "text": "Pushing for the undercut", "plan": {"mode": "push"}})
		sim.step(inputs)
		var fe := tel.observe(sim)
		tel.on_events(sim.events)
		feed_events += fe.size()
		for e in sim.events:
			if e["type"] == "collision":
				collisions += 1
	check(sim.phase == RaceSim.Phase.FINISHED, "race finishes (tick %d, %.0f s race time)" % [sim.tick, sim.race_time])
	var finishers := 0
	for i in sim.running_order:
		var e := sim.entries[i]
		var c := sim.cars[i]
		if e.finished:
			finishers += 1
		print("       P%d %-15s %-18s laps %d best %s  tyres %s fuel %.1f" % [e.position, e.driver_name,
			sim.defs[i].display_name, e.laps_done, _laptime(e.best_lap), _fmt(c.tyre_temp), c.fuel_l])
	# Full damage is on: a badly damaged car may limp home too late (DNF).
	check(finishers >= sim.car_count() - 2, "%d of %d cars finish with full damage on" % [finishers, sim.car_count()])
	var t_start := lerpf(sim.env.ambient_c, sim.env.track_c, 0.4)
	var warm := 0
	var left_hotter := 0
	for c in sim.cars:
		var avg := (c.tyre_temp[0] + c.tyre_temp[1] + c.tyre_temp[2] + c.tyre_temp[3]) / 4.0
		if avg > t_start + 20.0: warm += 1
		if c.tyre_temp[CarState.FL] > c.tyre_temp[CarState.FR]: left_hotter += 1
	check(warm == sim.car_count(), "tyres warm up from %.0f C during the race" % t_start)
	check(left_hotter > sim.car_count() / 2, "left tyres run hotter on a clockwise track (%d/%d)" % [left_hotter, sim.car_count()])
	var best := INF
	for e in sim.entries:
		if e.best_lap > 0.0:
			best = minf(best, e.best_lap)
	check(best > 75.0 and best < 130.0, "plausible best lap %s (real GT cars ~1:35-1:45)" % _laptime(best))
	print("       %d car-to-car contacts" % collisions)
	return {"telemetry": tel, "sim": sim, "feed_events": feed_events, "inputs": recorded, "start_hash": start_hash, "end_hash": sim.state_hash(),
		"settings": settings, "mid": mid_snapshot, "mid_tick": mid_tick}


func _laptime(t: float) -> String:
	if t <= 0.0 or t == INF:
		return "--"
	return "%d:%06.3f" % [int(t) / 60, fmod(t, 60.0)]


func _fresh_sim(settings: RaceSettings) -> RaceSim:
	var d := _data()
	return _race(settings, d)["sim"]


## Server-authoritative core property: same settings + same inputs => same state.
func test_deterministic_replay(rep: Dictionary) -> void:
	print("determinism")
	var sim := _fresh_sim(rep["settings"])
	check(sim.state_hash() == rep["start_hash"], "identical initial state")
	for inputs in rep["inputs"]:
		sim.step(inputs)
	check(sim.state_hash() == rep["end_hash"], "replaying recorded inputs reproduces the race exactly")


## Late join / resync: restore a mid-race snapshot, replay the rest, same end.
func test_snapshot_restore(rep: Dictionary) -> void:
	print("snapshot")
	var sim := _fresh_sim(rep["settings"])
	sim.apply_snapshot(rep["mid"])
	var inputs: Array = rep["inputs"]
	for k in range(rep["mid_tick"], inputs.size()):
		sim.step(inputs[k])
	check(sim.state_hash() == rep["end_hash"], "snapshot restore + replay matches the original race")


## Wave 2: clock, temperatures and weather follow the settings, deterministically.
func test_weather_and_time() -> void:
	print("weather")
	var d := _data()
	var track: TrackData = d["track"]
	var tenv := track.default_environment
	var e := SimEnvironment.create(tenv, {"time_of_day_h": 14.0, "time_scale": 60.0}, 1)
	check(absf(e.ambient_c - tenv["ambient_c"]) < 1.5 and absf(e.track_c - tenv["track_c"]) < 2.0,
		"14:00 matches the track's reference temps (air %.1f, track %.1f)" % [e.ambient_c, e.track_c])
	for k in 60 * 60:
		e.update(1.0 / 60.0)
	check(absf(e.time_of_day_h - 15.0) < 0.02, "clock at 60x: one minute later it's %.2f h" % e.time_of_day_h)
	var night := SimEnvironment.create(tenv, {"time_of_day_h": 3.0}, 1)
	check(night.ambient_c < e.ambient_c - 5.0, "nights are colder (%.1f vs %.1f)" % [night.ambient_c, e.ambient_c])
	check(night.track_c - night.ambient_c < 1.0 and e.track_c - e.ambient_c > 8.0, "the sun heats the track by day only")
	check(night.darkness() > 0.9 and e.darkness() < 0.05, "dark at night, light by day")
	var cloudy := SimEnvironment.create(tenv, {"weather": "overcast"}, 1)
	var sunny := SimEnvironment.create(tenv, {"weather": "dry"}, 1)
	check(cloudy.track_c < sunny.track_c - 4.0, "cloud keeps the track cooler (%.1f vs %.1f)" % [cloudy.track_c, sunny.track_c])
	var heavy := SimEnvironment.create(tenv, {"weather": "heavy_rain"}, 1)
	var light := SimEnvironment.create(tenv, {"weather": "light_rain"}, 1)
	check(heavy.wetness > 0.9 and light.wetness > 0.3 and light.wetness < heavy.wetness,
		"rain starts on a wet track (light %.2f, heavy %.2f)" % [light.wetness, heavy.wetness])
	check(heavy.track_c < sunny.track_c - 8.0, "rain cools the track (%.1f)" % heavy.track_c)
	# Changing weather: same seed, same weather everywhere.
	var a := SimEnvironment.create(tenv, {"weather": "overcast", "weather_changes": true}, 42)
	var b := SimEnvironment.create(tenv, {"weather": "overcast", "weather_changes": true}, 42)
	var c := SimEnvironment.create(tenv, {"weather": "overcast", "weather_changes": true}, 43)
	check(a.timeline.size() > 5 and a.timeline == b.timeline and a.timeline != c.timeline, "weather timeline comes from the seed")
	var saw := {}
	for k in 60 * 60 * 40:  # 40 minutes
		a.update(1.0 / 60.0)
		saw[a.weather] = true
	check(saw.size() >= 2, "weather changes during a long race (%s)" % ", ".join(saw.keys()))
	# Drying: no rain, cars on track, warm day.
	var dry := SimEnvironment.create(tenv, {"weather": "dry"}, 1)
	dry.wetness = 1.0
	dry.traffic = 10
	for k in 60 * 240:
		dry.update(1.0 / 60.0)
	check(dry.wetness < 0.7, "a wet track dries in the sun (%.2f after 4 min)" % dry.wetness)
	check(dry.dry_line > 0.5 and dry.wetness_at(0.0) < dry.wetness_at(6.0) * 0.6,
		"traffic dries the racing line first (line %.2f, off line %.2f)" % [dry.wetness_at(0.0), dry.wetness_at(6.0)])
	check(SimEnvironment.resolve_start_weather({"weather": "random"}, {}, 9) in SimEnvironment.WEATHERS, "random weather resolves")


## Wave 2: water costs grip, wet tyres win in the wet and lose in the dry.
func test_wet_grip() -> void:
	print("wet grip")
	var d := _data()
	var tenv: Dictionary = d["track"].default_environment
	var dry := SimEnvironment.create(tenv, {"weather": "dry"}, 1)
	var wet := SimEnvironment.create(tenv, {"weather": "heavy_rain"}, 1)
	var damp := SimEnvironment.create(tenv, {"weather": "light_rain"}, 1)
	var names := ["race_slick", "intermediate", "full_wet"]
	var mu := {}
	for n in names:
		var tc: TyreCompound = d["tyres"][n]
		mu[n] = [tc.peak_mu * dry.grip_factor(tc, 5.0, 40.0), tc.peak_mu * damp.grip_factor(tc, 5.0, 40.0), tc.peak_mu * wet.grip_factor(tc, 5.0, 40.0)]
		print("       %-14s dry %.2f  damp %.2f  wet %.2f" % [n, mu[n][0], mu[n][1], mu[n][2]])
	check(mu["race_slick"][0] > mu["intermediate"][0] and mu["intermediate"][0] > mu["full_wet"][0], "slicks fastest in the dry")
	check(mu["intermediate"][1] > mu["race_slick"][1] and mu["intermediate"][1] > mu["full_wet"][1], "intermediates best on a damp track")
	check(mu["full_wet"][2] > mu["intermediate"][2] and mu["intermediate"][2] > mu["race_slick"][2], "full wets best in heavy rain")
	var slick: TyreCompound = d["tyres"]["race_slick"]
	check(wet.grip_factor(slick, 5.0, 70.0) < wet.grip_factor(slick, 5.0, 10.0), "slicks aquaplane at speed on standing water")
	# Braking from 150 km/h on the main straight: longer in the wet.
	var stops := []
	for env in [dry, wet]:
		stops.append(_stopping_distance(d, env))
	check(stops[1] > stops[0] * 1.3, "wet braking distance longer (%.0f m vs %.0f m)" % [stops[1], stops[0]])


func _stopping_distance(d: Dictionary, env: SimEnvironment) -> float:
	var track: TrackData = d["track"]
	env.bind_track(track)
	var def: CarDefinition = d["cars"].values()[0]
	var tc: TyreCompound = d["tyres"][def.tyre_compound_id]
	var s := CarState.new()
	var g := track.grid_slot(10)
	s.pos = g["pos"]
	s.heading = g["heading"]
	s.vel = Vector2.from_angle(s.heading) * 41.7
	s.gear = 4
	s.tyre_temp = PackedFloat64Array([tc.optimal_temp_c, tc.optimal_temp_c, tc.optimal_temp_c, tc.optimal_temp_c])
	var inp := CarInput.new()
	inp.brake = 1.0
	var start := s.pos
	var events := []
	for k in 60 * 4 * 20:
		CarPhysics.step(s, inp, def, tc, env, track, 1.0 / 240.0, 0.0, events, 0)
		if s.speed() < 1.0:
			break
	return start.distance_to(s.pos)


## Wave 2: settings survive the lobby trip, AI picks tyres for the weather,
## grid order works, and clients get the host's conditions.
func test_race_settings_and_grid() -> void:
	print("race settings")
	var d := _data()
	var s := RaceSettings.new()
	s.laps = 7
	s.ai_count = 6
	s.seed = 99
	s.grid_order = "reversed"
	s.environment = {"time_of_day_h": 19.0, "time_scale": 30.0, "weather": "heavy_rain", "weather_changes": true}
	var back := RaceSettings.from_dict(s.to_dict())
	check(back.laps == 7 and back.grid_order == "reversed" and back.environment == s.environment, "settings round trip")
	var humans := [{"name": "Me", "car_id": d["cars"].keys()[0], "tyre": "dry"}]
	var start := RaceFactory.plan(s, humans, d["cars"], d["drivers"])
	var ai_wets := 0
	var me_dry := false
	for e in start["entries"]:
		if e["is_ai"] and e["setup"].get("tyre_compound", "") == "full_wet":
			ai_wets += 1
		if not e["is_ai"]:
			me_dry = not e["setup"].has("tyre_compound")
	check(ai_wets == 6, "AI start on full wets in heavy rain (%d/6)" % ai_wets)
	check(me_dry, "a player can gamble on dry tyres")
	var sim := RaceFactory.build_sim(start, d["cars"], d["tyres"], d["track"])
	check(sim.compounds[0].id == "full_wet", "the sim fits the chosen compound")
	var pace := []
	for i in sim.car_count():
		pace.append(sim.defs[i].peak_power_kw() / sim.defs[i].mass)
	check(pace[0] <= pace[pace.size() - 1], "reversed grid puts quicker cars at the back")
	var randomised := RaceSettings.from_dict(s.to_dict())
	randomised.grid_order = "random"
	var r1 := RaceFactory.plan(randomised, humans, d["cars"], d["drivers"])
	var r2 := RaceFactory.plan(randomised, humans, d["cars"], d["drivers"])
	check(r1 == r2, "random grid is the same on every machine for one seed")
	# Client follows the host's conditions.
	var client := RaceFactory.build_sim(start, d["cars"], d["tyres"], d["track"])
	client.follower = true
	for k in 600:
		sim.step([])
	client.apply_race_state(sim.race_state())
	check(client.env.to_dict() == sim.env.to_dict(), "clients get the host's weather, clock and track state")
	check(absf(sim.env.time_of_day_h - (19.0 + 10.0 * 30.0 / 3600.0)) < 0.01, "race clock runs at the host's speed")


## The driver roster is valid and the traits change how the AI drives.
func test_ai_drivers() -> void:
	print("ai drivers")
	var drivers := DriverCatalog.load_all()
	check(drivers.size() >= 24, "%d named drivers (enough for a 25-car grid)" % drivers.size())
	var ids := {}
	var bad := []
	for d in drivers:
		if ids.has(d.get("id", "")) or d.get("name", "") == "":
			bad.append(d.get("id", "?"))
		ids[d.get("id", "")] = true
		for k in DriverTraits.NAMES:
			var v = d.get("traits", {}).get(k)
			if v == null or float(v) < 0.0 or float(v) > 1.0:
				bad.append("%s.%s" % [d.get("id", "?"), k])
	check(bad.is_empty(), "every driver has a unique id and all eight traits in 0..1 %s" % [bad])
	var legacy := DriverTraits.from_dict({"skill": 0.8, "racecraft": 0.3})
	check(legacy.pace == 0.8 and legacy.overtaking == 0.3, "old skill/racecraft trait names still load")
	var t := DriverTraits.from_dict({"pace": 0.9, "aggression": 0.6})
	var easy := t.with_difficulty(0.25)
	var hard := t.with_difficulty(1.0)
	check(easy.pace < t.pace and hard.pace > t.pace and hard.aggression == t.aggression, "difficulty scales skills (%.2f / %.2f / %.2f), not style" % [easy.pace, t.pace, hard.pace])
	# A slow driver plans slower corners than a fast one in the same car.
	var cars := CarCatalog.load_all()
	var track := TrackCatalog.load_track("spielberg")
	var car: CarDefinition = cars.values()[0]
	var tyre: TyreCompound = TyreCatalog.load_all().values()[0]
	var slow := AIDriver.new(track, car, tyre, {"pace": 0.6}, 1)
	var fast := AIDriver.new(track, car, tyre, {"pace": 1.0}, 1)
	var vs := 0.0
	var vf := 0.0
	for k in slow.target_speed.size():
		vs += slow.target_speed[k]
		vf += fast.target_speed[k]
	check(vf > vs * 1.03, "pace trait: faster plan for the faster driver (%.1f vs %.1f m/s avg)" % [vf / slow.target_speed.size(), vs / slow.target_speed.size()])


## Wave 3: hits bend the car and hurt the systems behind them, the car
## drives worse, the pits can fix it, incidents reach race control, and the
## damage survives the trip over the network.
func test_damage() -> void:
	print("damage")
	var d := _data()
	var def: CarDefinition = d["cars"]["ferrari_296_gt3"] if d["cars"].has("ferrari_296_gt3") else d["cars"].values()[0]
	var nose := Vector2(def.length * 0.5, 0.0)
	# Levels
	var off := CarState.new()
	CarDamage.apply_impact(off, def, 15.0, nose, CarDamage.Level.OFF, 1)
	check(CarDamage.body_total(off) == 0.0 and off.damage_aero == 0.0, "damage off: hits do nothing")
	var vis := CarState.new()
	CarDamage.apply_impact(vis, def, 15.0, nose, CarDamage.Level.VISUAL, 1)
	check(vis.body_damage[CarDamage.FRONT] > 0.5 and vis.damage_aero == 0.0 and vis.damage_engine == 0.0,
		"visual damage: the nose bends but the car is unhurt")
	check(CarDamage.repair_time(vis) == 0.0 and CarDamage.repair_plan(vis).has("aero"), "visual damage: fixed for free in the pits")
	var full := CarState.new()
	full.damage_level = CarDamage.Level.FULL
	CarDamage.apply_impact(full, def, 15.0, nose, CarDamage.Level.FULL, 1)
	check(full.damage_aero > 0.3 and full.damage_engine > 0.1 and full.damage_gearbox == 0.0,
		"front hit: aero %.2f, engine %.2f, gearbox untouched" % [full.damage_aero, full.damage_engine])
	var rear := CarState.new()
	CarDamage.apply_impact(rear, def, 15.0, Vector2(-def.length * 0.5, 0.2), CarDamage.Level.FULL, 1)
	check(rear.damage_gearbox > 0.2 and rear.body_damage[CarDamage.REAR] > 0.5, "rear hit: gearbox %.2f" % rear.damage_gearbox)
	var side := CarState.new()
	CarDamage.apply_impact(side, def, 12.0, Vector2(0.0, def.width * 0.5), CarDamage.Level.FULL, 1)
	check(side.damage_suspension > 0.15 and side.alignment > 0.1, "right side hit: suspension %.2f, pulls right %.2f" % [side.damage_suspension, side.alignment])
	check(CarDamage.apply_impact(CarState.new(), def, 1.0, nose, CarDamage.Level.FULL, 1)["amount"] == 0.0, "a nudge does no damage")
	var punctured := 0
	for k in 40:
		var p := CarState.new()
		CarDamage.apply_impact(p, def, 18.0, CarDamage.wheel_pos(CarState.FR, def) + Vector2(0.0, 0.3), CarDamage.Level.FULL, k)
		punctured += int(p.puncture[CarState.FR] > 0.5)
	check(punctured > 10 and punctured < 40, "hard hits next to a wheel sometimes puncture it (%d/40)" % punctured)
	# Effect on the car
	var base := _accel_test(d, def, CarState.new())
	var engine := CarState.new()
	engine.damage_level = CarDamage.Level.FULL
	engine.damage_engine = 0.45
	var slow := _accel_test(d, def, engine)
	check(slow["speed"] < base["speed"] - 3.0, "engine damage: slower (%.0f vs %.0f km/h after 7 s)" % [slow["speed"] * 3.6, base["speed"] * 3.6])
	var gbox := CarState.new()
	gbox.damage_level = CarDamage.Level.FULL
	gbox.damage_gearbox = 0.95
	var g := _accel_test(d, def, gbox)
	check(g["speed"] < base["speed"] - 3.0 and g["gear"] < base["gear"], "gearbox damage: lost top gears (gear %d vs %d)" % [g["gear"], base["gear"]])
	var flat := CarState.new()
	flat.damage_level = CarDamage.Level.FULL
	flat.puncture[CarState.FR] = 1.0
	var pf := _accel_test(d, def, flat)
	check(pf["drift"] > base["drift"] + 0.03, "right front puncture pulls the car right (%.2f vs %.2f rad)" % [pf["drift"], base["drift"]])
	var bent := CarState.new()
	bent.damage_level = CarDamage.Level.FULL
	bent.alignment = -0.8
	var pb := _accel_test(d, def, bent)
	check(pb["drift"] < base["drift"] - 0.03, "bent steering pulls left (%.2f rad)" % pb["drift"])
	var visual_only := CarState.new()
	visual_only.damage_level = CarDamage.Level.VISUAL
	visual_only.body_damage = PackedFloat64Array([1.0, 1.0, 1.0, 1.0])
	check(absf(_accel_test(d, def, visual_only)["speed"] - base["speed"]) < 0.01, "visual damage drives like new")
	# Repairs
	var plan := CarDamage.repair_plan(full)
	check(plan.has("aero") and plan.has("engine") and not plan.has("gearbox"), "repair plan lists the damaged parts %s" % str(plan.keys()))
	var t_all := CarDamage.repair_time(full)
	var t_aero := CarDamage.repair_time(full, ["aero"])
	check(t_all > t_aero and t_aero >= 8.0, "repair time %.0f s (aero alone %.0f s)" % [t_all, t_aero])
	CarDamage.repair(full, ["aero"])
	check(full.damage_aero == 0.0 and full.damage_engine > 0.0 and CarDamage.body_total(full) == 0.0, "repairing aero leaves the engine")
	CarDamage.repair(full)
	check(CarDamage.worst(full) == 0.0 and CarDamage.repair_plan(full).is_empty(), "full repair: as new")
	# Network: damage survives pack/unpack
	var a := CarState.new()
	CarDamage.apply_impact(a, def, 16.0, Vector2(0.0, -def.width * 0.5), CarDamage.Level.FULL, 3)
	a.puncture[CarState.RL] = 1.0
	a.damage_gearbox = 0.4
	var buf := PackedFloat32Array()
	a.pack_net(buf)
	check(buf.size() == CarState.NET_SIZE, "net packet is NET_SIZE floats")
	var b := CarState.new()
	b.unpack_net(buf, 0)
	check(b.puncture[CarState.RL] == 1.0 and is_equal_approx(b.damage_gearbox, 0.4) and is_equal_approx(b.alignment, a.alignment)
		and is_equal_approx(b.body_damage[CarDamage.LEFT], a.body_damage[CarDamage.LEFT]), "damage survives the network")
	var snap := CarState.new()
	snap.deserialize(a.serialize())
	check(snap.puncture == a.puncture and snap.body_damage == a.body_damage, "damage survives snapshots")
	# In a race: a barrier hit and a car-to-car crash raise incidents
	var st := RaceSettings.new()
	st.ai_count = 3
	st.seed = 5
	st.countdown_s = 0.0
	st.set_damage_level("full")
	var sim: RaceSim = _race(st, d)["sim"]
	sim.step([])
	var c0 := sim.cars[0]
	var q := sim.track.project(c0.pos, c0.track_idx)
	var dirv: Vector2 = q["dir"]
	var nrm := Vector2(-dirv.y, dirv.x)
	c0.pos = sim.track.position_at(q["s"], q["w_right"] + sim.track.runoff - 1.0)
	c0.heading = nrm.angle()
	c0.vel = nrm * 30.0
	var incidents := []
	for k in 120:
		sim.step([])
		for e in sim.events:
			if e["type"] == "incident":
				incidents.append(e)
	check(incidents.size() > 0 and incidents[0]["car"] == 0 and incidents[0]["kind"] == "barrier",
		"driving into the wall raises a barrier incident (%s)" % str(incidents.slice(0, 1)))
	check(c0.body_damage[CarDamage.FRONT] > 0.3, "the nose is bent after hitting the wall (%.2f)" % c0.body_damage[CarDamage.FRONT])
	var c1 := sim.cars[1]
	var c2 := sim.cars[2]
	var s_crash := sim.track.length * 0.5
	var fwd := Vector2.from_angle(sim.track.heading_at(s_crash))
	c1.pos = sim.track.position_at(s_crash)
	c2.pos = c1.pos + fwd * (sim.defs[1].length * 0.5 + sim.defs[2].length * 0.5 + 0.1)
	c1.heading = fwd.angle()
	c2.heading = (-fwd).angle()
	c1.vel = fwd * 15.0
	c2.vel = -fwd * 15.0
	var crash := []
	for k in 10:
		sim.step([])
		for e in sim.events:
			if e["type"] == "incident" and e["kind"] == "collision":
				crash.append(e)
	check(crash.size() >= 2 and crash[0]["severity"] > 0.5, "head-on crash: both cars report a serious incident (%d)" % crash.size())
	check(c1.body_damage[CarDamage.FRONT] > 0.5 and c2.body_damage[CarDamage.FRONT] > 0.5, "both noses smashed")
	c1.damage_engine = 1.0
	sim.step([])
	check(sim.is_retired(1) and sim.entries[1].dnf, "a failed engine retires the car")
	# Remote cars: the host sees damage that arrived from their owner
	for k in 70:
		sim.step([])
	sim.external[2] = 1
	c2.body_damage[CarDamage.LEFT] = 0.8
	c2.puncture[CarState.RR] = 1.0
	var remote := []
	sim.step([])
	for e in sim.events:
		if e["type"] == "incident" and e["car"] == 2:
			remote.append(e["kind"])
	check("impact" in remote and "puncture" in remote, "host reports incidents for a remote player's car %s" % str(remote))


## Full throttle, no steering, 7 s from a rolling start off the grid down
## the main straight. Returns speed, gear and how far the heading drifted.
func _accel_test(d: Dictionary, def: CarDefinition, s: CarState) -> Dictionary:
	var track: TrackData = d["track"]
	var env := SimEnvironment.create(track.default_environment, {}, 1)
	env.bind_track(track)
	var tc: TyreCompound = d["tyres"][def.tyre_compound_id]
	var g := track.grid_slot(0)
	s.pos = g["pos"]
	s.heading = g["heading"]
	s.vel = Vector2.from_angle(s.heading) * 20.0
	s.track_idx = track.project(s.pos)["idx"]
	s.tyre_temp = PackedFloat64Array([tc.optimal_temp_c, tc.optimal_temp_c, tc.optimal_temp_c, tc.optimal_temp_c])
	s.assist_stability = false
	var inp := CarInput.new()
	inp.throttle = 1.0
	var ev := []
	var drift := INF
	for k in 240 * 7:
		CarPhysics.step(s, inp, def, tc, env, track, 1.0 / 240.0, 0.0, ev, 0)
		# Heading drift is measured while the car is still on the road: once a
		# pulling car runs off (into a gravel trap, say) it can spin round.
		if drift == INF and s.surface >= TrackData.Surface.GRASS:
			drift = wrapf(s.heading - g["heading"], -PI, PI)
	if drift == INF:
		drift = wrapf(s.heading - g["heading"], -PI, PI)
	return {"speed": s.speed(), "gear": s.gear, "drift": drift}


## Race data for the pit wall: lap logs, averages, gaps, pit windows, feed, sync.
func test_telemetry(rep: Dictionary) -> void:
	print("telemetry")
	var tel: RaceTelemetry = rep["telemetry"]
	var sim: RaceSim = rep["sim"]
	var logs_ok := true
	var sectors_ok := true
	for i in sim.car_count():
		var c := tel.cars[i]
		if c.laps.size() != sim.entries[i].laps_done:
			logs_ok = false
		for l in c.laps:
			var sum := 0.0
			for x in l["sectors"]:
				sum += x
			if l["sectors"].size() != sim.track.sectors.size() or absf(sum - l["time"]) > 0.01:
				sectors_ok = false
	check(logs_ok, "every completed lap is in each car's lap log")
	check(sectors_ok, "each logged lap has all sector times, adding up to the lap time")
	var c0 := tel.cars[sim.running_order[0]]
	check(c0.last5_avg > 60.0 and c0.last5_avg < 200.0, "last-5-lap average for the winner (%s)" % _laptime(c0.last5_avg))
	check(tel.fastest_lap > 0.0 and absf(tel.fastest_lap - sim.entries[tel.fastest_car].best_lap) < 0.001,
		"fastest lap matches the race's best (%s, %s)" % [_laptime(tel.fastest_lap), tel.driver_name(tel.fastest_car)])
	print("       pit lane: lane %.1f s + stop %.1f s, bypasses %.0f m of track" % [tel.pit.lane_time, tel.pit.stop_time_s, tel.pit.span_m])
	var loss := tel.pit.loss_for(c0, sim.track.length)
	check(tel.pit.has_lane and loss > 10.0 and loss < 90.0, "pit lane loss on %s is plausible (%.1f s, %d track samples)" % [sim.track.id, loss, c0.span_times.size()])

	# Gaps mid-race, from a fresh run of the recorded race to a point where cars are spread out.
	var sim2 := _fresh_sim(rep["settings"])
	var tel2 := RaceTelemetry.create(sim2)
	var inputs: Array = rep["inputs"]
	var stop_at := mini(inputs.size() - 1, int(sim2.settings.countdown_s * 60) + 60 * 150)
	for k in stop_at:
		sim2.step(inputs[k])
		tel2.observe(sim2)
	tel2._compute_gaps(sim2)
	tel2.pit.analyse(tel2.cars, sim2)
	var order := sim2.running_order
	var mono := true
	var int_ok := true
	var lines := []
	for p in order.size():
		var c := tel2.cars[order[p]]
		if p > 0:
			var prev := tel2.cars[order[p - 1]]
			if c.gap_leader + 0.3 < prev.gap_leader:
				mono = false
			# Measured at different timing loops, so they differ by the pace
			# difference over the stretch between the two cars.
			if absf((c.gap_leader - prev.gap_leader) - c.interval) > maxf(1.0, 0.3 * c.interval):
				int_ok = false
		lines.append("P%d %s +%.2f int %.2f pit:%s" % [p + 1, sim2.entries[order[p]].driver_name, c.gap_leader, c.interval,
			"P%d%s" % [c.pit.get("rejoin_pos", 0), " clear" if c.pit.get("clear_air", false) else ""]])
	print("       " + "\n       ".join(lines))
	check(mono, "gaps to the leader grow down the order")
	check(int_ok, "intervals match the difference in gaps")
	var last := tel2.cars[order[-1]]
	check(tel2.cars[order[0]].gap_leader == 0.0 and last.gap_leader > 0.5, "leader has no gap, last car is behind (%.1f s)" % last.gap_leader)
	var pit_ok := true
	for i in order:
		var pa: Dictionary = tel2.cars[i].pit
		if pa.is_empty() or pa["rejoin_pos"] < sim2.entries[i].position or pa["rejoin_pos"] > order.size():
			pit_ok = false
	check(pit_ok, "pit analysis gives every car a rejoin position")

	# Feed: AI radio/strategy events and derived calls.
	var heard := tel.feed.items.filter(func(it): return it.get("text", "") in ["Rears are going off", "Pushing for the undercut"])
	check(heard.size() == 2, "radio and strategy calls posted with post_event reach the feed (%d radio, %d strategy calls in the race)" % [
		tel.feed.count_kind("radio"), tel.feed.count_kind("strategy")])
	check(tel.strategies.has(3) and tel.strategies[3]["plan"].get("mode", "") == "push", "a team's latest strategy is kept")
	check(rep["feed_events"] > 0, "the race data writes its own feed calls (%d)" % rep["feed_events"])
	for it in tel.feed.latest(6):
		print("       [%s] %s" % [it["kind"], it["text"]])

	# Sync: a client copy gets the host's gaps and feed.
	var client := RaceTelemetry.create(sim, false)
	client.apply_net(bytes_to_var(var_to_bytes(tel2.to_net())))
	var same := true
	for i in order:
		if absf(client.cars[i].gap_leader - tel2.cars[i].gap_leader) > 1e-6 or client.cars[i].pit != tel2.cars[i].pit:
			same = false
	check(same, "gaps and pit analysis survive the trip to a client")
	client.on_events([{"type": "feed", "kind": "pit", "car": 1, "text": "x", "t": 1.0, "lap": 1}])
	check(client.feed.items.size() == 1 and not client.feed.items[0].has("type"), "clients take feed items from host events")
	client.on_events([{"type": "safety_car", "state": "sc", "reason": "Car stopped at turn 3", "lap": 2},
		{"type": "penalty", "car": 0, "seconds": 5.0, "reason": "track limits"}])
	check(client.feed.count_kind("race_control") == 2, "race control calls reach the feed (%s)" % client.feed.items[-1]["text"])
	var saved = JSON.parse_string(JSON.stringify(tel.to_dict(sim)))
	check(saved is Dictionary and saved["cars"].size() == sim.car_count(), "the race log exports to JSON")


## Weather radar and forecast from the environment.
func test_weather_forecast() -> void:
	print("weather forecast")
	var d := _data()
	var f := WeatherForecast.new()
	f.setup(d["track"], 99)
	var env := SimEnvironment.new()
	f.update(env)
	check(f.changes.is_empty(), "fixed weather: nothing forecast (%s)" % f.summary())
	if env.get("timeline") == null:
		print("       (environment has no weather timeline in this build: forecast is current conditions only)")
		return
	env.set("timeline", [[0.0, 0.1, 0.0], [400.0, 0.85, 0.0], [700.0, 0.95, 0.35], [1300.0, 0.85, 0.0]])
	f.update(env)
	check(f.changes.size() == 3 and f.changes[0]["weather"] == "overcast", "forecast lists the coming changes")
	check(f.changes[1]["eta"] == 700.0 and f.changes[1]["confidence"] < f.changes[0]["confidence"], "later changes are less certain")
	check(f.radar_cells.size() > 0, "rain shows on the radar before it arrives (%d cells)" % f.radar_cells.size())
	var nearest := INF
	for c in f.radar_cells:
		if c["rain"] > 0.05:
			nearest = minf(nearest, c["pos"].distance_to(f.centre))
	check(nearest > f.track_radius, "rain still upwind of the track")
	print("       " + f.summary())
