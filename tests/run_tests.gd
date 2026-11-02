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
	var replay := test_ai_race_completes()
	test_deterministic_replay(replay)
	test_snapshot_restore(replay)
	test_race_control_rules()
	test_safety_car_race()
	test_safety_car_off()
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
	var race := _race(settings, d)
	var sim: RaceSim = race["sim"]
	var ai: Dictionary = race["ai"]
	var recorded: Array = []
	var start_hash := sim.state_hash()
	var collisions := 0
	var max_ticks := 60 * 60 * 8
	var mid_snapshot := {}
	var mid_tick := 60 * 45
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < max_ticks:
		if sim.tick == mid_tick:
			mid_snapshot = sim.snapshot()
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		recorded.append(inputs)
		sim.step(inputs)
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
	check(finishers == sim.car_count(), "all %d cars finish (%d)" % [sim.car_count(), finishers])
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
	return {"inputs": recorded, "start_hash": start_hash, "end_hash": sim.state_hash(),
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


# --- Wave 3: race control (flags, VSC, safety car, penalties) -------------

## Runs an AI race in which one car stops and retires at stop_at seconds.
## force_sc deploys the safety car straight away (so the whole procedure is
## covered whatever the stopped car's spot). Returns a summary.
func _sc_race(settings: RaceSettings, stop_at: float, force_sc: bool, snapshot_at := -1.0) -> Dictionary:
	var d := _data()
	var race := _race(settings, d)
	var sim: RaceSim = race["sim"]
	var ai: Dictionary = race["ai"]
	var out := {"events": {}, "penalties": 0, "inputs": [], "sc_seen": false, "max_queue": 0.0,
		"queue_at_call_in": INF, "start_hash": sim.state_hash(), "snap": {}, "snap_tick": -1, "victim": -1}
	var victim := -1
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 15:
		if snapshot_at > 0.0 and out["snap_tick"] < 0 and sim.race_time >= snapshot_at:
			out["snap"] = sim.snapshot()
			out["snap_tick"] = sim.tick
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		if victim < 0 and sim.phase == RaceSim.Phase.RACING and sim.race_time >= stop_at:
			victim = sim.running_order[sim.car_count() / 2]
			out["victim"] = victim
			out["victim_tick"] = sim.tick
			if force_sc:
				sim.race_control._deploy_sc("test")
		if victim >= 0:
			var stop := CarInput.new()
			stop.brake = 1.0
			inputs[victim] = stop
			if sim.cars[victim].speed() < 1.0:
				sim.entries[victim].dnf = true  # retired (the damage module does this in a real race)
		out["inputs"].append(inputs)
		sim.step(inputs)
		var rc := sim.race_control
		for e in sim.events:
			var key: String = e["type"] + ":" + str(e.get("state", e.get("flag", "")))
			out["events"][key] = out["events"].get(key, 0) + 1
			if e["type"] == "penalty":
				out["penalties"] += 1
				print("       penalty: %s %s" % [sim.entries[e["car"]].driver_name, e["reason"]])
			if e["type"] == "safety_car" and e["state"] == "in_this_lap":
				out["queue_at_call_in"] = _lead_lap_queue(sim, 4)
		if rc.sc_visible:
			out["sc_seen"] = true
	out["sim"] = sim
	out["end_hash"] = sim.state_hash()
	return out


## Length of the queue formed by the first n lead-lap cars (metres).
func _lead_lap_queue(sim: RaceSim, n: int) -> float:
	var lead := sim.entries[sim.running_order[0]].distance
	var count := 0
	var last := 0.0
	for i in sim.running_order:
		var e := sim.entries[i]
		if e.dnf or lead - e.distance > sim.track.length * 0.5:
			continue
		last = lead - e.distance
		count += 1
		if count >= n:
			break
	return last


func test_safety_car_race() -> void:
	print("safety car")
	var settings := RaceSettings.new()
	settings.laps = 4
	settings.ai_count = 7
	settings.seed = 4242
	var r := _sc_race(settings, 45.0, true, 120.0)
	var sim: RaceSim = r["sim"]
	var ev: Dictionary = r["events"]
	check(r["sc_seen"] and sim.race_control.deployments == 1, "the safety car comes out")
	check(ev.has("flag:yellow"), "the stopped car gets a local yellow flag")
	check(ev.has("flag:recovered") and sim.race_control.recovered[r["victim"]] == 1, "marshals recover the retired car")
	check(r["queue_at_call_in"] < 120.0, "the field bunches up behind the safety car (first 4 within %.0f m)" % r["queue_at_call_in"])
	check(ev.has("safety_car:in_this_lap") and ev.has("safety_car:restart") and ev.has("safety_car:green"),
		"safety car in this lap, into the pits, restart, green flag")
	check(not sim.race_control.sc_visible and sim.race_control.mode == RaceControl.Mode.GREEN, "safety car gone after the restart")
	check(r["penalties"] <= 1, "AI keeps to the rules behind the safety car (%d penalties)" % r["penalties"])
	check(sim.phase == RaceSim.Phase.FINISHED, "race finishes after the safety car (%.0f s)" % sim.race_time)
	# Same inputs, same race: race control is part of the deterministic sim.
	var replay := _fresh_sim(settings)
	check(replay.state_hash() == r["start_hash"], "safety car race: identical start")
	var inputs: Array = r["inputs"]
	for k in inputs.size():
		if k == r["victim_tick"]:
			replay.race_control._deploy_sc("test")
		_retire_like(replay, k >= r["victim_tick"], r["victim"])
		replay.step(inputs[k])
	check(replay.state_hash() == r["end_hash"], "safety car race replays exactly")
	# Resync mid safety car from a snapshot.
	var late := _fresh_sim(settings)
	late.apply_snapshot(r["snap"])
	check(late.race_control.mode == RaceControl.Mode.SC, "snapshot taken under the safety car carries it")
	for k in range(r["snap_tick"], inputs.size()):
		_retire_like(late, k >= r["victim_tick"], r["victim"])
		late.step(inputs[k])
	check(late.state_hash() == r["end_hash"], "snapshot restore under the safety car matches the original race")


## Replays the test's retirement (the stopped car is marked retired once still).
func _retire_like(sim: RaceSim, stopped: bool, victim: int) -> void:
	if stopped and sim.cars[victim].speed() < 1.0:
		sim.entries[victim].dnf = true


func test_safety_car_off() -> void:
	print("safety car off")
	var settings := RaceSettings.new()
	settings.laps = 2
	settings.ai_count = 5
	settings.seed = 99
	settings.safety_car_enabled = false
	var r := _sc_race(settings, 30.0, false)
	var ev: Dictionary = r["events"]
	check(ev.has("flag:yellow"), "a stopped car still brings out yellow flags")
	check(not ev.has("safety_car:sc") and not ev.has("safety_car:vsc") and not r["sc_seen"], "no VSC or safety car when the host turns it off")
	check(r["sim"].phase == RaceSim.Phase.FINISHED, "race finishes")


## Rules without driving: penalties, classification, overtaking rules, sync.
func test_race_control_rules() -> void:
	print("race control rules")
	var d := _data()
	var settings := RaceSettings.new()
	settings.ai_count = 4
	settings.laps = 1
	var sim: RaceSim = _race(settings, d)["sim"]
	var rc := sim.race_control
	check(rc.neutralisation() == "green" and not sim.safety_car_active() and sim.pit_time_saving() == 0.0, "starts green")
	# Penalties count in the classification.
	sim.phase = RaceSim.Phase.RACING
	for i in 4:
		var e := sim.entries[i]
		e.finished = true
		e.laps_done = 1
		e.finish_time = 100.0 + i
		sim.finish_order.append(i)
	sim.add_penalty(0, 5.0, "test")
	sim._update_positions()
	check(sim.entries[0].penalty_s == 5.0 and sim.entries[0].position == 4, "a 5 s penalty drops the winner from P1 to P4")
	check(sim.events.back()["type"] == "penalty", "penalty event for the race feed")
	# Overtaking rules.
	var sim2: RaceSim = _race(settings, d)["sim"]
	var rc2 := sim2.race_control
	sim2.phase = RaceSim.Phase.RACING
	for c in sim2.cars:
		c.vel = Vector2.from_angle(c.heading) * 40.0
	check(rc2.may_pass(1, 0), "racing: overtaking allowed")
	rc2._deploy_sc("test")
	check(sim2.safety_car_active() and sim2.neutralisation() == "sc" and sim2.pit_time_saving() > 0.4, "safety car out: cheap pit stop")
	check(not rc2.may_pass(1, 0), "no overtaking behind the safety car")
	rc2.unlapping[1] = 1
	check(rc2.may_pass(1, 0), "a waved-by lapped car may overtake")
	rc2.unlapping[1] = 0
	sim2.cars[0].vel = Vector2.ZERO
	rc2.stranded_t[0] = 3.0
	check(rc2.may_pass(1, 0), "passing a stopped car is allowed")
	# Give the place back, or take a penalty.
	rc2.stranded_t[0] = 0.0
	sim2.cars[0].vel = Vector2.from_angle(sim2.cars[0].heading) * 40.0
	rc2._prev_order = [0, 1, 2, 3]
	sim2.entries[1].distance = sim2.entries[0].distance + 10.0
	sim2._update_positions()
	rc2._check_overtakes()
	check(rc2.give_back.has(1), "overtaking under the safety car: told to give the place back")
	check(rc2.instruction_for(1).begins_with("Give the place back"), "HUD tells the driver: %s" % rc2.instruction_for(1))
	sim2.race_time += RaceControl.GIVE_BACK_S + 1.0
	rc2._check_overtakes()
	check(sim2.entries[1].penalty_s == RaceControl.PENALTY_S, "not given back in time: %d s penalty" % int(RaceControl.PENALTY_S))
	# Clients get race control with the race state.
	var client: RaceSim = _race(settings, d)["sim"]
	client.follower = true
	client.apply_race_state(sim2.race_state())
	check(client.race_control.mode == RaceControl.Mode.SC and client.race_control.sc_visible
		and client.race_control.sc_pos.distance_to(rc2.sc_pos) < 0.01 and client.entries[1].penalty_s == RaceControl.PENALTY_S,
		"clients get the safety car, its position and penalties")
	var before := client.race_control.sc_s
	client.step([])
	check(client.race_control.sc_s != before, "clients move the safety car along between updates")
	# The safety car model data (graphics builds it from real dimensions).
	var sc_def := CarCatalog.load_safety_car()
	check(sc_def != null and is_equal_approx(sc_def.length, 4.546) and not d["cars"].has(sc_def.id),
		"safety car: AMG GT Black Series dimensions, never in the race car list")
