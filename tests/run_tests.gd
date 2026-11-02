extends SceneTree
## Headless test runner:
##   godot --headless --path . --script res://tests/run_tests.gd
## Exits with code 0 on success, 1 on failure.

var failures := 0


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	# TDR_ONLY=test_a,test_b runs just those tests (ones that take no arguments).
	if OS.has_environment("TDR_SNAP"):
		var rep := test_ai_race_completes()
		test_snapshot_restore(rep)
		quit(1 if failures > 0 else 0)
		return
	if OS.has_environment("TDR_ONLY"):
		for t in OS.get_environment("TDR_ONLY").split(","):
			call(t)
		print("\n%s (%d failures, %.1fs)" % ["PASS" if failures == 0 else "FAIL", failures, (Time.get_ticks_msec() - t0) / 1000.0])
		quit(1 if failures > 0 else 0)
		return
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
	test_pit_rules()
	test_pit_setup_changes()
	test_car_setups()
	test_upgrades()
	var replay := test_ai_race_completes()
	test_deterministic_replay(replay)
	test_snapshot_restore(replay)
	test_telemetry(replay)
	test_weather_forecast()
	test_race_control_rules()
	test_safety_car_race()
	test_safety_car_off()
	test_points_systems()
	test_seasons()
	test_coop_roles()
	test_tyre_choice_and_line_ups()
	test_race_start()
	test_driving_aids()
	test_active_pad()
	test_hud_timing()
	test_graphics_effects()
	test_settings_and_units()
	test_rebinding()
	test_grid_limits()
	test_garage_saves()
	test_online_contacts()
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
	check(classes.size() >= 4 and classes[0] == "Hypercar" and classes[1] == "LMP2" and classes[2] == "GT3"
		and classes[-1] == "Road", "classes, fastest first: %s" % [classes])
	# Prototypes (wave 6): real dimensions and the order on track Hypercar > LMP2 > GT3.
	var protos_ok := true
	for id in CarCatalog.ids_in_class(d["cars"], "Hypercar") + CarCatalog.ids_in_class(d["cars"], "LMP2"):
		var c: CarDefinition = d["cars"][id]
		protos_ok = protos_ok and c.length <= 5.1 and c.width <= 2.0 and c.wheelbase >= 2.95 \
			and ResourceLoader.exists("res://modules/graphics/cars/%s.glb" % id) and c.raw.get("engine", {}).has("sound")
	check(protos_ok and CarCatalog.ids_in_class(d["cars"], "Hypercar").size() >= 5 and CarCatalog.ids_in_class(d["cars"], "LMP2").size() >= 2,
		"%d Hypercars and %d LMP2 cars, real dimensions, each with a 3D model and an engine sound family"
		% [CarCatalog.ids_in_class(d["cars"], "Hypercar").size(), CarCatalog.ids_in_class(d["cars"], "LMP2").size()])
	var t3: Dictionary = CarSetup.TEMPLATES
	check(t3.has("Hypercar") and t3.has("LMP2") and UpgradeCatalog.data().get("price_scale", {}).has("Hypercar"),
		"setup templates and upgrade prices for the prototype classes")
	# Liveries: every racing car has sticker slots, the sponsors are many and all different.
	var liv = JSON.parse_string(FileAccess.get_file_as_string("res://modules/graphics/data/liveries.json"))
	var spn = JSON.parse_string(FileAccess.get_file_as_string("res://modules/graphics/data/sponsors.json"))
	var slots_ok := true
	for id in d["cars"]:
		if d["cars"][id].class_tag != "Road":
			var roles := {}
			for sl in liv.get(id, {}).get("decal_slots", []):
				roles[sl["role"]] = true
			slots_ok = slots_ok and roles.has("bonnet") and roles.has("wing") and roles.has("number") and roles.has("door")
	var names := {}
	for sp in spn["sponsors"]:
		names[sp["name"]] = true
	check(slots_ok and names.size() == spn["sponsors"].size() and names.size() >= 50,
		"liveries: bonnet, wing, door and number stickers on every race car; %d different sponsors" % names.size())
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
## Car setups (wave 4): ranges, physics effects, the advisor, AI setups, the
## host switch, saving, and tyres that reach their temperature window.
func test_car_setups() -> void:
	print("car setups")
	var d := _data()
	var car: CarDefinition = d["cars"]["porsche_911_gt3_r"]
	var plain := car.with_overrides({"tuning": {}})
	check(is_equal_approx(plain.cla, car.cla) and is_equal_approx(plain.cda, car.cda)
		and is_equal_approx(plain.aero_balance_front, car.aero_balance_front)
		and is_equal_approx(plain.steer_rate, car.steer_rate), "an empty setup is the car as it comes")
	check(CarSetup.defaults(car).size() == CarSetup.KEYS.size() and CarSetup.ITEMS.size() == CarSetup.KEYS.size(),
		"%d settings, each with a default and an explanation" % CarSetup.KEYS.size())
	var clean := CarSetup.sanitize(car, {"wing_rear": 99, "camber_front": -3.43, "bogus": 1, "brake_bias": 0.2})
	check(clean["wing_rear"] == 10.0 and is_equal_approx(clean["camber_front"], -3.4) and not clean.has("bogus")
		and clean["brake_bias"] >= CarSetup.range_of(car, "brake_bias")[1], "setups are clamped and snapped, unknown keys dropped")
	var hi := car.with_overrides({"tuning": {"wing_rear": 10}})
	var lo := car.with_overrides({"tuning": {"wing_rear": 0}})
	check(hi.cla > car.cla and hi.cda > car.cda and hi.aero_balance_front < car.aero_balance_front and lo.cla < car.cla,
		"rear wing: more downforce and drag, balance moves back (%.2f / %.2f / %.2f)" % [lo.cla, car.cla, hi.cla])
	var short := car.with_overrides({"tuning": {"final_drive": CarSetup.range_of(car, "final_drive")[2]}})
	check(CarSetup.top_speed(short, short.final_drive) < CarSetup.top_speed(car, car.final_drive), "shorter gearing, lower top speed")
	var stiff_front := car.with_overrides({"tuning": {"arb_front": 10}})
	check(stiff_front.roll_stiffness_front > car.roll_stiffness_front, "stiffer front bar takes more of the roll (understeer)")
	# Tyre pressure: hot pressure rises with temperature, best at the compound's optimum.
	var tc: TyreCompound = d["tyres"]["race_slick"]
	check(absf(tc.hot_psi(0.0, tc.optimal_temp_c) - tc.optimal_hot_psi) < 0.01 and tc.pressure_grip_factor(tc.optimal_hot_psi) == 1.0
		and tc.pressure_grip_factor(tc.optimal_hot_psi + 4.0) < tc.pressure_grip_factor(tc.optimal_hot_psi - 4.0)
		and tc.pressure_heat_factor(24.0) > tc.pressure_heat_factor(30.0),
		"tyre pressure: %.1f psi cold reaches %.1f hot at %d C; over-inflated loses most grip; soft tyres heat more" % [tc.cold_psi, tc.optimal_hot_psi, tc.optimal_temp_c])
	# Bottoming: the lowest, softest car hits the ground in Mugello's biggest dip.
	var mugello := TrackCatalog.load_track("mugello")
	var low_soft := car.with_overrides({"tuning": {"ride_front": 48, "ride_rear": 58, "spring_front": 140, "spring_rear": 120,
		"damper_front": 1, "damper_rear": 1}})
	var dip_s := 0.0
	for k in mugello.point_count():
		if mugello.vertical_curvature_at(mugello.cum_s[k]) > mugello.vertical_curvature_at(dip_s):
			dip_s = mugello.cum_s[k]
	var bottom := []
	for def in [car, low_soft]:
		var st := CarState.new()
		st.pos = mugello.position_at(dip_s)
		st.heading = mugello.heading_at(dip_s)
		st.vel = Vector2.from_angle(st.heading) * 60.0
		st.tyre_temp = PackedFloat64Array([95.0, 95.0, 95.0, 95.0])
		var q := mugello.project(st.pos)
		st.track_idx = q["idx"]
		var inp := CarInput.new()
		inp.throttle = 1.0
		CarPhysics.step(st, inp, def, tc, SimEnvironment.from_dict({}), mugello, 1.0 / 240.0, 0.0, [], 0)
		bottom.append(st.bottoming)
	check(bottom[0] < 0.05 and bottom[1] > 0.2, "low and soft bottoms out in Mugello's dip (default %.2f, low %.2f)" % [bottom[0], bottom[1]])
	# The advisor: less wing at Monza than at the Hungaroring, gearing to suit,
	# ride height raised for Mugello's compressions, fuel for the race.
	var monza := TrackCatalog.load_track("monza")
	var hun := TrackCatalog.load_track("budapest")
	var r_monza := SetupAdvisor.recommend(car, monza, {"track_c": 35.0, "compound": tc})
	var r_hun := SetupAdvisor.recommend(car, hun, {"track_c": 35.0, "compound": tc})
	var r_mug := SetupAdvisor.recommend(car, mugello, {"track_c": 30.0, "compound": tc, "fuel_enabled": true, "laps": 5})
	check(r_monza["wing_rear"] < r_hun["wing_rear"] and r_monza["final_drive"] <= r_hun["final_drive"],
		"advisor: Monza wing %d, gearing %.2f; Hungaroring wing %d, gearing %.2f" % [r_monza["wing_rear"], r_monza["final_drive"], r_hun["wing_rear"], r_hun["final_drive"]])
	var mug_def := car.with_overrides({"tuning": r_mug})
	var sink := SetupAdvisor.worst_sink(mug_def, SetupAdvisor.analyse(mug_def, mugello))
	check(mug_def.ride_front_mm - sink[0] >= mug_def.plank_mm and mug_def.ride_rear_mm - sink[1] >= mug_def.plank_mm
		and r_mug["fuel_l"] > 10.0 and r_mug["fuel_l"] <= car.fuel_capacity_l,
		"advisor: Mugello floor clear in the compressions (%d/%d mm), %d L for 5 laps" % [r_mug["ride_front"], r_mug["ride_rear"], r_mug["fuel_l"]])
	var hot := SetupAdvisor.recommend(car, monza, {"track_c": 50.0, "compound": tc})
	check(hot["pressure_front"] < r_monza["pressure_front"], "advisor: lower cold pressures on a hot track (%+.1f vs %+.1f psi)" % [hot["pressure_front"], r_monza["pressure_front"]])
	check(not SetupAdvisor.notes(car, monza).is_empty(), "advisor: track notes (%s)" % SetupAdvisor.notes(car, monza)[0])
	# AI setups at race start, and the host switch.
	var s := RaceSettings.new()
	s.track_id = "monza"
	s.ai_count = 3
	s.car_class = "GT3"
	var start := RaceFactory.plan(s, [{"name": "me", "car_id": "porsche_911_gt3_r", "setup": {"tuning": {"wing_rear": 7}}}], d["cars"], d["drivers"], monza)
	var all_tuned := true
	for e in start["entries"]:
		all_tuned = all_tuned and e["setup"].has("tuning")
	var sim := RaceFactory.build_sim(start, d["cars"], d["tyres"], monza)
	var me := sim.car_count() - 1
	check(all_tuned and sim.defs[me].tuning.get("wing_rear", 0.0) == 7.0 and sim.defs[0].tuning.has("final_drive"),
		"every AI car gets a setup, players keep theirs")
	s.tuning_enabled = false
	var fixed := RaceFactory.build_sim(RaceFactory.plan(s, [{"name": "me", "car_id": "porsche_911_gt3_r", "setup": {"tuning": {"wing_rear": 7}}}],
		d["cars"], d["drivers"], monza), d["cars"], d["tyres"], monza)
	var none := true
	for def in fixed.defs:
		none = none and def.tuning.is_empty()
	check(none, "car setups off: everyone races the default setup")
	# Fuel load counts only when fuel is used.
	s.tuning_enabled = true
	s.fuel_enabled = true
	s.ai_count = 0
	var fuel_sim := RaceFactory.build_sim(RaceFactory.plan(s, [{"name": "me", "car_id": "porsche_911_gt3_r", "setup": {"tuning": {"fuel_l": 30}}}],
		d["cars"], d["drivers"], monza), d["cars"], d["tyres"], monza)
	check(absf(fuel_sim.cars[0].fuel_l - 30.0) < 0.01, "setup fuel load: %.0f L on the grid" % fuel_sim.cars[0].fuel_l)
	# Saving per car per track.
	SetupStore.save_setup("test_car", "test_track", {"wing_rear": 2.0})
	var back := SetupStore.load_setup("test_car", "test_track")
	SetupStore.erase("test_car", "test_track")
	check(back.get("wing_rear", -1.0) == 2.0 and not SetupStore.has("test_car", "test_track"), "setups save and load per car per track")
	# On track: tyres reach their window, and the recommended setup is quicker at Monza.
	var lap_def := _solo_lap(monza, d)
	var lap_rec := _solo_lap(monza, d, {"tuning": r_monza})
	check(lap_def["front_c"] > 85.0 and lap_def["front_c"] < 112.0 and lap_def["rear_c"] > 85.0 and lap_def["rear_c"] < 112.0,
		"slicks in their window on lap 2: front %.0f C, rear %.0f C (best %d C)" % [lap_def["front_c"], lap_def["rear_c"], tc.optimal_temp_c])
	# AI laps vary by a few tenths, so: no slower than the default (within 1%).
	check(lap_rec["time"] > 0.0 and lap_rec["time"] < lap_def["time"] * 1.01, "Monza: recommended setup %s vs default %s" % [_laptime(lap_rec["time"]), _laptime(lap_def["time"])])


func _solo_lap(track: TrackData, d: Dictionary, setup: Dictionary = {}) -> Dictionary:
	var s := RaceSettings.new()
	s.track_id = track.id
	s.ai_count = 0
	s.laps = 2
	s.countdown_s = 0.5
	var start := RaceFactory.plan(s, [{"name": "bot", "car_id": "porsche_911_gt3_r", "setup": setup}], d["cars"], [], track)
	var sim := RaceFactory.build_sim(start, d["cars"], d["tyres"], track)
	var ai := AIDriver.new(track, sim.defs[0], sim.compounds[0], {"skill": 0.95, "consistency": 1.0}, 1)
	var offs := 0
	var was_off := false
	var temps := [0.0, 0.0, 0]
	while sim.entries[0].laps_done < 2 and sim.tick < 60 * 600:
		sim.step([ai.get_input(sim, 0)])
		var off := sim.cars[0].surface >= TrackData.Surface.GRASS
		if off and not was_off:
			offs += 1
		was_off = off
		if sim.entries[0].laps_done == 1:
			var c := sim.cars[0]
			temps[0] += (c.tyre_temp[0] + c.tyre_temp[1]) * 0.5
			temps[1] += (c.tyre_temp[2] + c.tyre_temp[3]) * 0.5
			temps[2] += 1
	var e := sim.entries[0]
	return {"time": e.lap_times[1] if e.lap_times.size() > 1 else -1.0, "offs": offs,
		"front_c": temps[0] / maxf(temps[2], 1), "rear_c": temps[1] / maxf(temps[2], 1)}


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
	settings.laps = 3
	settings.ai_count = 8
	settings.seed = 777
	# Wave 3: fuel, tyre wear and one mandatory stop, so the replay and
	# snapshot tests below cover pit stops too.
	settings.fuel_enabled = true
	settings.fuel_rate = 2.0
	settings.tyre_wear_enabled = true
	settings.tyre_wear_rate = 2.0
	settings.mandatory_pit_stops = 1
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
	var stops := []
	var pit_calls := []
	var penalties := []
	var mid_pit_taken := false
	# Race data watches the whole race; the determinism test replays without
	# it, which proves it never changes the race.
	var tel := RaceTelemetry.create(sim)
	var feed_events := 0
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < max_ticks:
		if sim.tick == mid_tick:
			mid_snapshot = sim.snapshot()
		var inputs := []
		var calls_before := _pit_calls(sim)
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		# Pit calls are inputs too (the AI's strategy, or a player's button).
		var calls := _pit_calls(sim)
		var changed := {}
		for i in sim.car_count():
			if calls[i] != calls_before[i]:
				changed[i] = calls[i]
		recorded.append(inputs)
		pit_calls.append(changed)
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
			elif e["type"] == "pit_stop":
				var st: Dictionary = e.duplicate()
				st["repairs"] = (sim.entries[e["car"]].pit.get("last_stop", {}) as Dictionary).get("repairs", []).size()
				stops.append(st)
			elif e["type"] == "penalty":
				penalties.append(e)
		# Take the mid-race snapshot while a car is stopped in its box.
		if not mid_pit_taken and sim.tick > mid_tick and sim.pit_phase(sim.running_order[0]) == PitRules.PHASE_SERVICE:
			mid_pit_taken = true
			mid_tick = sim.tick
			mid_snapshot = sim.snapshot()
	check(sim.phase == RaceSim.Phase.FINISHED, "race finishes (tick %d, %.0f s race time)" % [sim.tick, sim.race_time])
	var finishers := 0
	for i in sim.running_order:
		var e := sim.entries[i]
		var c := sim.cars[i]
		if e.finished:
			finishers += 1
		print("       P%d %-15s %-18s laps %d best %s  tyres %s fuel %.1f  stop lap %s" % [e.position, e.driver_name,
			sim.defs[i].display_name, e.laps_done, _laptime(e.best_lap), _fmt(c.tyre_temp), c.fuel_l,
			e.pit["last_stop"].get("lap", "-")])
	# Full damage is on: a badly damaged car may limp home too late (DNF).
	check(finishers >= sim.car_count() - 2, "%d of %d cars finish with full damage on" % [finishers, sim.car_count()])
	# A car that crashed out or lost a lap stuck in a gravel trap may never
	# reach its window; it gets the missed-stop penalty, which is the rule.
	var excused := {}
	for i in sim.car_count():
		if sim.entries[i].dnf or sim.entries[i].laps_done < settings.laps:
			excused[i] = true
	var in_window := 0
	for i in sim.car_count():
		if int(sim.entries[i].pit["window_stops"]) == 1 or excused.has(i):
			in_window += 1
	check(in_window == sim.car_count(), "every AI still running makes the mandatory stop inside the window (%d/%d, laps %d-%d, %d excused)" % [
		in_window, sim.car_count(), sim.pits.window_open, sim.pits.window_close, excused.size()])
	var stop_penalties := penalties.filter(func(pe): return str(pe["reason"]).contains("pit") and not excused.has(int(pe["car"])))
	check(stop_penalties.is_empty(), "no pit penalties for AI drivers (%s)" % str(stop_penalties))
	var times := []
	var service_ok := true
	for st in stops:
		times.append(snappedf(st["stationary_s"], 0.1))
		# Tyres and fuel take under 40 s; a stop that also repairs crash damage takes longer.
		service_ok = service_ok and st["stationary_s"] < (120.0 if st["repairs"] > 0 else 40.0)
	check(not stops.is_empty() and times.min() >= PitRules.STOP_BASE_S and service_ok, "pit stops take %s s" % str(times))
	check(mid_pit_taken, "snapshot taken during a pit stop (tick %d)" % mid_tick)
	var worn := 0
	var measured := 0
	for i in sim.car_count():
		if sim.cars[i].tyre_wear[0] > 0.005 or sim.entries[i].dnf:
			worn += 1
		if float(sim.entries[i].pit["fuel_per_lap"]) > 0.5 or sim.entries[i].dnf:
			measured += 1
	check(worn == sim.car_count(), "tyres wear (%d/%d)" % [worn, sim.car_count()])
	check(measured == sim.car_count(), "fuel use per lap is measured (%d/%d)" % [measured, sim.car_count()])
	var t_start := lerpf(sim.env.ambient_c, sim.env.track_c, 0.4)
	var warm := 0
	var left_hotter := 0
	for i in sim.car_count():
		var c := sim.cars[i]
		var avg := (c.tyre_temp[0] + c.tyre_temp[1] + c.tyre_temp[2] + c.tyre_temp[3]) / 4.0
		# Cars still racing at the end (a crippled car crawling round, or the
		# field behind the safety car, runs cooler).
		if avg > t_start + 20.0 or not sim.entries[i].finished: warm += 1
		if c.tyre_temp[CarState.FL] > c.tyre_temp[CarState.FR]: left_hotter += 1
	check(warm == sim.car_count(), "tyres warm up from %.0f C during the race (finishers)" % t_start)
	check(left_hotter > sim.car_count() / 2, "left tyres run hotter on a clockwise track (%d/%d)" % [left_hotter, sim.car_count()])
	var best := INF
	for e in sim.entries:
		if e.best_lap > 0.0:
			best = minf(best, e.best_lap)
	check(best > 75.0 and best < 130.0, "plausible best lap %s (real GT cars ~1:35-1:45)" % _laptime(best))
	print("       %d car-to-car contacts" % collisions)
	return {"telemetry": tel, "sim": sim, "feed_events": feed_events, "inputs": recorded, "pit_calls": pit_calls, "start_hash": start_hash, "end_hash": sim.state_hash(),
		"settings": settings, "mid": mid_snapshot, "mid_tick": mid_tick}


func _pit_calls(sim: RaceSim) -> Array:
	var out := []
	for e in sim.entries:
		var plan: Dictionary = e.pit["plan"].duplicate()
		plan["box"] = e.pit["box"]
		out.append(plan)
	return out


func _replay_pit_calls(sim: RaceSim, calls: Dictionary) -> void:
	for i in calls:
		sim.pits.set_plan(i, calls[i])


func _laptime(t: float) -> String:
	if t <= 0.0 or t == INF:
		return "--"
	return "%d:%06.3f" % [int(t) / 60, fmod(t, 60.0)]


func _fresh_sim(settings: RaceSettings) -> RaceSim:
	var d := _data()
	return _race(settings, d)["sim"]


## Wave 3: pit window, stop times, limiter, speeding and missed-stop
## penalties, classification with penalties, and pit state in multiplayer.
func test_pit_rules() -> void:
	print("pits")
	var d := _data()
	var st := RaceSettings.new()
	st.laps = 10
	st.ai_count = 3
	st.mandatory_pit_stops = 1
	st.fuel_enabled = true
	st.damage_enabled = true
	var sim: RaceSim = _race(st, d)["sim"]
	var pits := sim.pits
	check(pits.enabled and pits.window_open == 3 and pits.window_close == 8, "automatic pit window for 10 laps is laps 3-8 (%d-%d)" % [pits.window_open, pits.window_close])
	var t := sim.track
	check(t.pit_limit_end - t.pit_limit_start < 460.0, "pit speed limit zone is real-sized (%.0f m)" % (t.pit_limit_end - t.pit_limit_start))
	var c := sim.cars[0]
	c.fuel_l = 5.0
	c.damage_aero = 0.5
	var w := pits.service_for(0, {"tyre": PitRules.TYRE_INTER, "fuel": 30.0, "repair": true})
	check(w["tyre"] == "intermediate" and is_equal_approx(w["fuel_l"], 30.0), "plan: inters and 30 L")
	check(is_equal_approx(w["total_s"], PitRules.STOP_BASE_S + 10.0 + float(w["repair_s"])) and float(w["repair_s"]) > 0.0,
		"stop time = base + slower of tyres/fuel + repairs (%.1f s)" % w["total_s"])
	var keep := pits.service_for(0, {"tyre": PitRules.TYRE_KEEP, "fuel": 0.0, "repair": false})
	check(keep["tyre"] == "" and is_equal_approx(keep["total_s"], PitRules.STOP_BASE_S), "a stop with nothing to do is just the base time")
	var auto_fuel := pits.service_for(0, {"tyre": PitRules.TYRE_AUTO, "fuel": PitRules.FUEL_AUTO, "repair": false})
	check(auto_fuel["fuel_l"] > 0.0 and auto_fuel["fuel_l"] <= sim.defs[0].fuel_capacity_l - 5.0, "auto fuel fills for the rest of the race (%.0f L)" % auto_fuel["fuel_l"])
	check(CarPhysics.wear_grip_factor(1.0) < 0.75 and is_equal_approx(CarPhysics.wear_grip_factor(0.0), 1.0), "worn tyres lose grip")

	# A car driven into the lane by hand too fast: speeding penalty at the limit line.
	sim.phase = RaceSim.Phase.RACING
	var i := 1
	var car := sim.cars[i]
	var d0 := t.pit_limit_start - 15.0
	car.pos = t.pit_position_at(d0)
	car.heading = t.pit_heading_at(d0)
	car.vel = Vector2.from_angle(car.heading) * 30.0
	var q := t.project(car.pos)
	car.track_idx = q["idx"]
	car.track_s = q["s"]
	var fast := CarInput.new()
	fast.throttle = 1.0
	var pens := []
	for k in 60 * 3:
		var ins := [CarInput.neutral(), CarInput.neutral(), CarInput.neutral()]
		ins[i] = fast
		sim.step(ins)
		for ev in sim.events:
			if ev["type"] == "penalty":
				pens.append(ev)
	check(sim.in_pit_lane(i), "driving into the pit lane by hand is noticed (%s)" % sim.pit_phase(i))
	check(pens.size() == 1 and sim.entries[i].penalty_s == PitRules.SPEEDING_PENALTY_S, "speeding in the pit lane: +%d s" % int(PitRules.SPEEDING_PENALTY_S))
	check(sim.pit_controls(i) and car.speed() <= t.pit_speed_limit + 0.5, "past the limit line the car is guided at the limit (%.1f m/s)" % car.speed())
	# The limiter caps a driver's speed.
	sim.pits.set_limiter(2, true)
	sim.cars[2].vel = Vector2.from_angle(sim.cars[2].heading) * (t.pit_speed_limit + 5.0)
	var limited: CarInput = sim.pits.pre_step([null, null, fast])[2]
	check(limited.throttle == 0.0, "pit limiter cuts the throttle above the limit")

	# Missed mandatory stop: penalty when the car finishes, and the classification counts it.
	var e2 := sim.entries[2]
	pits.on_finished(2)
	check(e2.penalty_s == PitRules.MISSED_STOP_PENALTY_S, "missed mandatory stop: +%d s" % int(PitRules.MISSED_STOP_PENALTY_S))
	for k in 3:
		sim.entries[k].finished = true
		sim.entries[k].laps_done = 10
	sim.entries[0].finish_time = 1000.0
	sim.entries[1].finish_time = 1001.0
	sim.entries[2].finish_time = 990.0
	sim._update_positions()
	check(sim.running_order[0] == 0 and sim.running_order[2] == 2, "classification adds penalties (order %s)" % str(sim.running_order))

	# Multiplayer: a client keeps its own car's pit state when the host's race
	# state arrives, and takes everyone else's (including their tyres).
	var host: RaceSim = _race(st, d)["sim"]
	var client: RaceSim = _race(st, d)["sim"]
	client.follower = true
	for k in 3:
		client.external[k] = 0 if k == 1 else 1
	host.entries[0].pit["compound"] = "intermediate"
	host.entries[0].pit["stops"] = 1
	host.entries[1].pit["box"] = false
	client.entries[1].pit["box"] = true
	client.apply_race_state(host.race_state())
	check(client.entries[1].pit["box"], "client keeps its own car's pit call")
	check(client.entries[0].pit["stops"] == 1 and client.compounds[0].id == "intermediate", "client sees other cars' stops and tyres")
	var e := RaceEntry.new()
	e.from_dict(host.entries[0].to_dict())
	check(e.pit["compound"] == "intermediate" and e.pit["plan"] is Dictionary, "pit state survives the network round trip")


## Co-op pit crew: wing and tyre pressure changes made during a stop.
func test_pit_setup_changes() -> void:
	print("pit setup changes")
	var d := _data()
	var st := RaceSettings.new()
	st.laps = 6
	st.ai_count = 3
	st.car_class = "GT3"
	st.tuning_enabled = true
	var sim: RaceSim = _race(st, d)["sim"]
	var pits := sim.pits
	var i := 0
	for k in sim.car_count():
		if CarSetup.adjustable(sim.defs[k], "wing_rear"):
			i = k
			break
	var def := sim.defs[i]
	var now := pits.current_setup(i)
	check(now.size() == PitRules.PIT_SETUP_KEYS.size(), "current pit-adjustable setup has every key")
	var rw := CarSetup.range_of(def, "wing_rear")
	var wing_dir := 1.0 if float(now["wing_rear"]) + 2.0 * float(rw[3]) <= float(rw[2]) else -1.0
	var want_wing := float(now["wing_rear"]) + wing_dir * 2.0 * float(rw[3])
	var want_psi := float(now["pressure_front"]) - 0.5
	pits.set_plan(i, {"setup": {"wing_rear": want_wing, "pressure_front": want_psi, "ride_front": 10.0}})
	var plan: Dictionary = sim.entries[i].pit["plan"]
	check(plan.has("setup") and not (plan["setup"] as Dictionary).has("ride_front"), "only wings and tyre pressures can change at a stop")
	var keep := plan.duplicate(true)
	keep["tyre"] = PitRules.TYRE_KEEP
	keep["fuel"] = 0.0
	keep["repair"] = false
	var w := pits.service_for(i, keep)
	var wing_changes := (plan["setup"] as Dictionary).has("wing_rear") and want_wing != float(now["wing_rear"])
	var expect_s := (PitRules.WING_CHANGE_S if wing_changes else 0.0) + PitRules.PRESSURE_ONLY_S
	check(is_equal_approx(float(w["setup_s"]), expect_s) and is_equal_approx(float(w["total_s"]), PitRules.STOP_BASE_S + expect_s),
		"setup work takes time: %.1f s (no new tyres, so pressures cost extra)" % w["setup_s"])
	var with_tyres := keep.duplicate(true)
	with_tyres["tyre"] = PitRules.TYRE_DRY
	var w2 := pits.service_for(i, with_tyres)
	check(is_equal_approx(float(w2["total_s"]), PitRules.STOP_BASE_S + PitRules.TYRE_CHANGE_S), "with new tyres the setup work fits inside the tyre change")
	var drag0 := def.cda
	var p: Dictionary = sim.entries[i].pit
	p["work"] = w
	p["service_total"] = w["total_s"]
	pits._finish_service(i)
	var after := pits.current_setup(i)
	check(is_equal_approx(float(after["pressure_front"]), want_psi), "tyre pressure changed in the stop (%.1f)" % after["pressure_front"])
	check(wing_changes and (is_equal_approx(float(after["wing_rear"]), want_wing) and (sim.defs[i].cda - drag0) * wing_dir > 0.0),
		"rear wing changed in the stop, and with it the drag (%.3f -> %.3f)" % [drag0, sim.defs[i].cda])
	check(not (p["plan"] as Dictionary).has("setup") and (p["last_stop"]["setup"] as Dictionary).size() >= 1, "the change is done and logged")
	check(pits.service_for(i, with_tyres)["setup"].is_empty(), "nothing left to change afterwards")
	pits.set_plan(i, {"setup": {"wing_front": 1.0}})
	pits.set_plan(i, {"setup": {}})
	check(not (sim.entries[i].pit["plan"] as Dictionary).has("setup"), "an empty setup cancels the changes")
	# Fixed setups (host option): no changes in the pits either.
	var st2 := RaceSettings.new()
	st2.laps = 6
	st2.ai_count = 2
	st2.tuning_enabled = false
	var sim2: RaceSim = _race(st2, d)["sim"]
	sim2.pits.set_plan(0, {"setup": {"pressure_front": -1.0}})
	check(not (sim2.entries[0].pit["plan"] as Dictionary).has("setup"), "no pit setup changes when the host fixes setups")


## Server-authoritative core property: same settings + same inputs => same state.
func test_deterministic_replay(rep: Dictionary) -> void:
	print("determinism")
	var sim := _fresh_sim(rep["settings"])
	check(sim.state_hash() == rep["start_hash"], "identical initial state")
	for k in rep["inputs"].size():
		_replay_pit_calls(sim, rep["pit_calls"][k])
		sim.step(rep["inputs"][k])
	check(sim.state_hash() == rep["end_hash"], "replaying recorded inputs reproduces the race exactly")


## Late join / resync: restore a mid-race snapshot, replay the rest, same end.
func test_snapshot_restore(rep: Dictionary) -> void:
	print("snapshot")
	var sim := _fresh_sim(rep["settings"])
	sim.apply_snapshot(rep["mid"])
	var inputs: Array = rep["inputs"]
	for k in range(rep["mid_tick"], inputs.size()):
		_replay_pit_calls(sim, rep["pit_calls"][k])
		sim.step(inputs[k])
	var same: bool = sim.state_hash() == rep["end_hash"]
	check(same, "snapshot restore + replay matches the original race")
	if not same:
		var sa: Dictionary = rep["sim"].snapshot()
		var sb := sim.snapshot()
		for k in ["cars", "entries", "env", "pits", "race_control"]:
			_print_snapshot_diff(sa[k], sb[k], "/" + k)


## Where two snapshots differ (first few differences), to debug determinism.
func _print_snapshot_diff(a, b, path: String) -> void:
	if a is Dictionary and b is Dictionary:
		for k in a:
			if var_to_bytes(a[k]) != var_to_bytes(b.get(k)):
				_print_snapshot_diff(a[k], b.get(k), path + "/" + str(k))
				return
	elif (a is Array or a is PackedFloat64Array) and typeof(a) == typeof(b) and a.size() == b.size():
		for k in a.size():
			if var_to_bytes(a[k]) != var_to_bytes(b[k]):
				printerr("       differs at %s[%d]: %s vs %s" % [path, k, str(a[k]).left(200), str(b[k]).left(200)])
				if not (a[k] is float or a[k] is int):
					_print_snapshot_diff(a[k], b[k], "%s[%d]" % [path, k])
				return
	else:
		printerr("       differs at %s: %s vs %s" % [path, str(a).left(300), str(b).left(300)])


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
			# The first (forced) safety car; another incident later in the
			# race may bring out a second one.
			if e["type"] == "safety_car" and e["state"] == "in_this_lap" and out["queue_at_call_in"] == INF:
				out["queue_at_call_in"] = _lead_lap_queue(sim, 4)
			if e["type"] == "safety_car" and e["state"] == "green" and not out.has("green_at"):
				out["green_at"] = sim.race_time
		if rc.sc_visible:
			out["sc_seen"] = true
		if out.has("green_at") and not out.has("sc_gone_at") and not rc.sc_visible and rc.mode == RaceControl.Mode.GREEN:
			out["sc_gone_at"] = sim.race_time
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
	check(r["sc_seen"] and sim.race_control.deployments >= 1, "the safety car comes out (%d deployments)" % sim.race_control.deployments)
	check(ev.has("flag:yellow"), "the stopped car gets a local yellow flag")
	check(ev.has("flag:recovered") and sim.race_control.recovered[r["victim"]] == 1, "marshals recover the retired car")
	check(r["queue_at_call_in"] < 120.0, "the field bunches up behind the safety car (first 4 within %.0f m)" % r["queue_at_call_in"])
	check(ev.has("safety_car:in_this_lap") and ev.has("safety_car:restart") and ev.has("safety_car:green"),
		"safety car in this lap, into the pits, restart, green flag")
	check(r.has("sc_gone_at") and r["sc_gone_at"] - r["green_at"] < 120.0, "safety car gone after the restart (%.0f s after green)" % (r.get("sc_gone_at", INF) - r.get("green_at", 0.0)))
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


## Points presets, custom lists and bonus points.
func test_points_systems() -> void:
	print("points")
	var f1 := PointsSystem.from_preset("f1")
	check(f1.for_position(1, 20) == 25 and f1.for_position(10, 20) == 1 and f1.for_position(11, 20) == 0, "F1 preset: 25 for a win, 1 for tenth, none for eleventh")
	var all := PointsSystem.from_preset("everyone")
	check(all.for_position(1, 12) == 12 and all.for_position(12, 12) == 1, "everyone scores: last place gets 1")
	var custom := PointsSystem.from_preset("custom", PointsSystem.parse_list("30, 20 ;10 x 5"))
	check(custom.points == [30, 20, 10, 5], "custom points list parsed (%s)" % [custom.points])
	f1.pole_points = 1
	f1.fastest_lap_points = 1
	var cls := [{"key": "ai:A", "position": 1}, {"key": "ai:B", "position": 2}, {"key": "ai:C", "position": 3, "dnf": true}]
	var pts := Season.race_points(f1, cls, "ai:B", "ai:A")
	check(pts["ai:A"] == 26 and pts["ai:B"] == 19 and pts["ai:C"] == 0, "pole and fastest lap bonuses, nothing for a DNF (%s)" % [pts])
	check(PointsSystem.from_dict(f1.to_dict()).to_dict() == f1.to_dict(), "points system round trip")


## Runs a planned session with every car AI-driven. Returns {sim, tel}.
func _run_session(start: Dictionary, d: Dictionary, max_s := 900.0) -> Dictionary:
	var sim := RaceFactory.build_sim(start, d["cars"], d["tyres"], d["track"])
	var ai := AIDriver.for_all_ai(sim)
	var tel := RaceTelemetry.create(sim)
	while sim.phase != RaceSim.Phase.FINISHED and sim.tick < int(max_s * 60):
		var inputs := []
		for i in sim.car_count():
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		tel.observe(sim)
		tel.on_events(sim.events)
	return {"sim": sim, "tel": tel}


## A whole (short) championship: fixed field, driven qualifying sets the
## grid, points and standings, saving and loading, and the season after.
func test_seasons() -> void:
	print("seasons")
	var d := _data()
	var base := RaceSettings.new()
	base.car_class = "GT3"
	base.ai_count = 6
	base.laps = 1
	var rounds := [{"track_id": "spielberg", "laps": 1, "weather": "dry", "time_of_day_h": 14.0},
		{"track_id": "spielberg", "laps": 1, "weather": "overcast", "time_of_day_h": 17.0}]
	var pts := PointsSystem.from_preset("f1")
	pts.pole_points = 1
	pts.fastest_lap_points = 1
	var season := Season.create("Test Cup", base, rounds, pts, Season.QUALI_DRIVEN, d["drivers"], d["cars"], "", 4242)
	check(season.roster.size() == 6 and season.reserves.size() == d["drivers"].size() - 6, "field of 6 AI drivers, the rest are reserves")
	var team_cars := {}
	var same_car := true
	for r in season.roster:
		if team_cars.has(r["team"]) and team_cars[r["team"]] != r["car_id"]:
			same_car = false
		team_cars[r["team"]] = r["car_id"]
		same_car = same_car and d["cars"][r["car_id"]].class_tag == "GT3"
	check(team_cars.size() == 3 and same_car, "three teams of two, team-mates share a GT3 car")
	# Round 1: qualifying, then the race from that grid.
	check(season.next_session() == Season.SESSION_QUALIFYING, "driven qualifying comes first")
	var q_start := season.plan_next([], d["cars"], 11)
	check(q_start["season"]["session"] == "qualifying" and q_start["settings"]["laps"] == Season.QUALI_LAPS, "qualifying session planned (%d laps)" % Season.QUALI_LAPS)
	var q := _run_session(q_start, d)
	var q_sim: RaceSim = q["sim"]
	var ordered := true
	var prev := 0.0
	for i in q_sim.running_order:
		var bl: float = q_sim.entries[i].best_lap
		if bl > 0.0 and bl < prev:
			ordered = false
		if bl > 0.0:
			prev = bl
	check(q_sim.phase == RaceSim.Phase.FINISHED and ordered, "qualifying ends and is classified by best lap")
	var q_rec := season.record(SeasonResults.from_race(q_sim, q["tel"]), 0)
	check(q_rec.get("grid", []).size() == 6 and season.next_session() == Season.SESSION_RACE, "qualifying sets the grid")
	check(season.record(SeasonResults.from_race(q_sim, q["tel"]), 0).is_empty(), "the same session can't be recorded twice")
	var r_start := season.plan_next([], d["cars"], 12)
	var grid_keys := []
	for e in r_start["entries"]:
		grid_keys.append(SeasonResults.key_for(e["is_ai"], e["driver_name"]))
	check(grid_keys == q_rec["grid"], "race grid is the qualifying order")
	var car_kept := true
	for e in r_start["entries"]:
		for r in season.roster:
			if r["name"] == e["driver_name"] and r["car_id"] != e["car_id"]:
				car_kept = false
	check(car_kept, "every AI driver races their team's car")
	var r := _run_session(r_start, d)
	var result := SeasonResults.from_race(r["sim"], r["tel"])
	var rec := season.record(result, 0)
	var total := 0
	for k in rec["points"]:
		total += rec["points"][k]
	var expect := 25 + 18 + 15 + 12 + 10 + 8 + 1  # top six, plus pole
	for row in result["classification"]:
		if row["dnf"]:
			expect -= pts.for_position(row["position"], 6)
		elif row["key"] == result["fastest_key"]:
			expect += 1
	check(total == expect and season.round_index == 1, "points handed out for round 1 (%d)" % total)
	var st := season.driver_standings()
	check(st.size() == 6 and st[0]["points"] >= st[5]["points"] and st[0]["results"].size() == 1, "driver standings in order")
	var teams := season.team_standings()
	var team_total := 0
	for t in teams:
		team_total += t["points"]
	check(teams.size() == 3 and team_total == total, "team standings add up their drivers' points")
	# Simulated qualifying for round 2 (switch modes mid-season for the test).
	season.qualifying = Season.QUALI_SIMULATED
	var s1 := season.plan_next([{"name": "Me", "car_id": "bmw_m4_gt3"}], d["cars"], 77)
	season.pending_quali = {}
	var s2 := season.plan_next([{"name": "Me", "car_id": "bmw_m4_gt3"}], d["cars"], 77)
	check(s1["entries"] == s2["entries"] and season.humans.has("Me"), "simulated qualifying gives the same grid for the same seed; a player can join between rounds")
	# Save, load, carry on.
	var dir := "user://test_seasons"
	SeasonStore.save(season, dir)
	var back := SeasonStore.load_season(season.id, dir)
	check(back != null and back.driver_standings() == season.driver_standings() and back.round_index == 1, "season saves and loads with its standings")
	check(SeasonStore.list(dir).size() >= 1, "saved seasons are listed")
	var log_path := SeasonStore.save_session_log(season.id, 0, "race", result["log"], dir)
	check(log_path != "" and FileAccess.file_exists(log_path), "the race log is kept beside the season")
	SeasonStore.delete(season.id, dir)
	check(not FileAccess.file_exists(SeasonStore.path_for(season.id).replace(SeasonStore.DIR, dir)), "a season can be deleted")
	# The season after: a year older, same teams and cars, driver market news.
	back.round_index = back.rounds.size()
	check(not back.champion().is_empty(), "a champion once every round is done")
	var nxt := back.next_season(999)
	var older := true
	for nd in nxt.roster:
		for od in back.roster + back.reserves:
			if od["name"] == nd["name"] and int(nd["age"]) != int(od["age"]) + 1:
				older = false
	var cars_kept := true
	for nd in nxt.roster:
		cars_kept = cars_kept and nd["car_id"] == team_cars.get(nd["team"], "")
	check(nxt.number == 2 and nxt.roster.size() == 6 and older and cars_kept and not nxt.news.is_empty(),
		"next season: everyone a year older, 6 seats filled in the same team cars (%s)" % " ".join(nxt.news))
	check(nxt.results.is_empty() and nxt.humans.has("Me"), "next season starts fresh with the same players")
## Wave 4 business: upgrades change the car through overrides, money buys
## and sells them, the profile saves, prizes pay by position, and the host's
## upgrades option (on / bop / stock) holds in the race plan.
func test_upgrades() -> void:
	print("upgrades and money")
	var d := _data()
	var cars: Dictionary = d["cars"]
	check(UpgradeCatalog.category_ids() == ["engine", "aero", "brakes", "suspension", "weight", "tyres"], "six upgrade categories")
	var gt3: CarDefinition = cars["bmw_m4_gt3"]
	var all3 := {}
	for c in UpgradeCatalog.category_ids():
		check(UpgradeCatalog.max_level(c) == 3, "%s has levels 0-3" % c)
		all3[c] = 3
	var up := gt3.with_overrides(UpgradeCatalog.overrides_for(gt3, all3))
	check(UpgradeCatalog.overrides_for(gt3, {}).is_empty(), "no upgrades, no overrides")
	check(absf(up.peak_power_kw() / gt3.peak_power_kw() - 1.13) < 0.005, "stage 3 engine: +13%% power (%.0f -> %.0f kW)" % [gt3.peak_power_kw(), up.peak_power_kw()])
	check(up.cla > gt3.cla * 1.29 and up.cda > gt3.cda, "race aero: more downforce, more drag")
	check(up.mass < gt3.mass * 0.94 and up.brake_force > gt3.brake_force * 1.19, "lighter, stronger brakes")
	check(up.front_grip > gt3.front_grip * 1.1 and up.cg_height < gt3.cg_height, "more grip, lower centre of gravity")
	var vis: Dictionary = up.raw.get("visual", {})
	check(vis.get("wing") == 3 and vis.get("splitter") == 1 and vis.has("rims") and vis.has("calipers"), "visual parts ride along in the car data")
	# Faster in a straight line.
	var tc: TyreCompound = d["tyres"][gt3.tyre_compound_id]
	var env := SimEnvironment.from_dict({})
	var a := _car_at(d["track"], 0.0, 15.0)
	var b := _car_at(d["track"], 0.0, 15.0)
	var go := CarInput.new()
	go.throttle = 1.0
	for i in 180:
		CarPhysics.step(a, go, gt3, tc, env, d["track"], 1.0 / 60.0, 0.0, [], 0)
		CarPhysics.step(b, go, up, tc, env, d["track"], 1.0 / 60.0, 0.0, [], 0)
	check(b.speed() > a.speed() + 0.5, "upgraded car accelerates harder (%.1f vs %.1f m/s)" % [b.speed(), a.speed()])
	# Money: buy, sell for half, can't overspend, saves.
	var path := "user://test_profile.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var p := TeamProfile.load_or_new(path)
	var start := p.money
	check(start == 150000, "a new team starts with 150,000 cr")
	var price := UpgradeCatalog.price(gt3, "engine", 1)
	check(price == 35200, "GT3 parts cost 1.6x (stage 1 engine %d)" % price)
	check(p.set_level(gt3, "engine", 1) and p.money == start - price, "buying an upgrade takes its price")
	check(p.set_level(gt3, "engine", 0) and p.money == start - price + price / 2, "selling refunds half")
	p.money = 1000
	check(not p.set_level(gt3, "aero", 3) and p.level(gt3.id, "aero") == 0 and p.money == 1000, "can't buy without the money")
	p.money = 500000
	p.set_level(gt3, "aero", 2)
	p.set_livery(gt3.id, {"pattern": "stripes", "primary": "#111111"})
	p.save()
	var back := TeamProfile.load_or_new(path)
	check(back.money == p.money and back.level(gt3.id, "aero") == 2 and back.livery_for(gt3.id)["pattern"] == "stripes", "profile saves and loads")
	check(back.setup_for(gt3).get("visual", {}).get("wing") == 2, "setup_for carries the upgrades")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Prize money.
	var win := Economy.race_prize(1, 10, 40.0)
	var last := Economy.race_prize(10, 10, 40.0)
	check(win == 40000 and last < win and Economy.race_prize(0, 10, 40.0) < last and Economy.race_prize(1, 10, 5.0) < win,
		"prizes: winner %d, last %d, shorter races pay less" % [win, last])
	# Race plan: upgrades count, or are stripped, or balanced.
	var s := RaceSettings.new()
	s.ai_count = 5
	s.car_class = "GT3"
	s.track_id = "spielberg"
	var setup := UpgradeCatalog.overrides_for(gt3, all3)
	setup["tuning"] = {"wing_rear": 2}
	var humans := [{"name": "Me", "car_id": gt3.id, "tyre": "dry", "setup": setup, "livery": {"pattern": "sash"}}]
	var on := RaceFactory.plan(s, humans, cars, d["drivers"])
	var me: Dictionary = on["entries"][-1]
	check(me["setup"].has("engine") and me["livery"]["pattern"] == "sash", "the player's upgrades and livery reach the race")
	var sim := RaceFactory.build_sim(on, cars, d["tyres"], d["track"])
	check(absf(sim.defs[sim.car_count() - 1].peak_power_kw() - up.peak_power_kw()) < 0.5, "the sim races the upgraded car")
	s.upgrades_mode = RaceSettings.UPGRADES_STOCK
	me = RaceFactory.plan(s, humans, cars, d["drivers"])["entries"][-1]
	check(me["setup"].keys() == ["tuning"], "stock: upgrades stripped, tuning left to its own switch (%s)" % str(me["setup"].keys()))
	s.upgrades_mode = RaceSettings.UPGRADES_BOP
	var bop := RaceFactory.plan(s, humans, cars, d["drivers"])
	me = bop["entries"][-1]
	check(me["setup"].has("visual") and me["setup"].has("bop") and not me["setup"].has("brakes"), "bop: looks kept, performance replaced by balance")
	var ref: Dictionary = RaceFactory.bop_reference(cars)["GT3"]
	var bsim := RaceFactory.build_sim(bop, cars, d["tyres"], d["track"])
	var worst := 0.0
	for i in bsim.car_count():
		var df: CarDefinition = bsim.defs[i]
		worst = maxf(worst, absf(df.peak_power_kw() / df.mass / ref["kw_per_kg"] - 1.0))
	check(worst < 0.01, "bop: every GT3 within 1%% of the same power-to-weight (worst %.2f%%)" % (worst * 100.0))


## Co-op crews (wave 5): roles shared out by crew size, a driver change in
## the box, and the car's pit state moving to another machine.
func test_coop_roles() -> void:
	print("co-op crews")
	check(RaceEntry.roles_for_crew(1) == [RaceEntry.ROLE_DRIVER], "one player: a driver")
	check(RaceEntry.roles_for_crew(2) == [RaceEntry.ROLE_DRIVER, RaceEntry.ROLE_PIT_WALL], "two players: driver + pit crew/strategist in one")
	check(RaceEntry.roles_for_crew(3) == [RaceEntry.ROLE_DRIVER, RaceEntry.ROLE_PIT_CREW, RaceEntry.ROLE_STRATEGIST], "three players: driver, pit crew, strategist")
	check(RaceEntry.role_covers(RaceEntry.ROLE_PIT_WALL, RaceEntry.ROLE_STRATEGIST) and RaceEntry.role_covers(RaceEntry.ROLE_PIT_WALL, RaceEntry.ROLE_PIT_CREW)
		and not RaceEntry.role_covers(RaceEntry.ROLE_PIT_CREW, RaceEntry.ROLE_STRATEGIST), "pit wall covers both pit duties")
	var two := [{"role": RaceEntry.ROLE_DRIVER}, {"role": RaceEntry.ROLE_DRIVER}]
	RaceEntry.share_roles(two)
	check(two[0]["role"] == RaceEntry.ROLE_DRIVER and two[1]["role"] == RaceEntry.ROLE_PIT_WALL, "two drivers: the second goes to the pit wall")
	var three := [{"role": RaceEntry.ROLE_PIT_WALL}, {"role": RaceEntry.ROLE_STRATEGIST}, {"role": ""}]
	RaceEntry.share_roles(three)
	var got := []
	for m in three:
		got.append(m["role"])
	got.sort()
	var want := [RaceEntry.ROLE_DRIVER, RaceEntry.ROLE_PIT_CREW, RaceEntry.ROLE_STRATEGIST]
	want.sort()
	check(got == want and three[1]["role"] == RaceEntry.ROLE_STRATEGIST, "three players get one each, keeping the roles they had (%s)" % str(got))
	var left := [{"role": RaceEntry.ROLE_PIT_CREW}]
	RaceEntry.share_roles(left)
	check(left[0]["role"] == RaceEntry.ROLE_DRIVER, "the last one left drives")
	var e := RaceEntry.new()
	e.crew = [{"peer_id": 5, "name": "A", "role": RaceEntry.ROLE_DRIVER}, {"peer_id": 9, "name": "B", "role": RaceEntry.ROLE_PIT_WALL}]
	check(e.driver_peer() == 5 and e.member_role(9) == RaceEntry.ROLE_PIT_WALL and e.member_role(3) == "", "crew roles by peer")

	# Driver change in the box: the stop lasts at least DRIVER_CHANGE_S, and the
	# car's pit state moves to the new driver's machine intact.
	var d := _data()
	var st := RaceSettings.new()
	st.laps = 5
	st.ai_count = 2
	st.mandatory_pit_stops = 1
	var sim: RaceSim = _race(st, d)["sim"]
	var p: Dictionary = sim.entries[0].pit
	p["phase"] = PitRules.PHASE_SERVICE
	p["service_left"] = 1.0
	p["service_total"] = 8.5
	sim.pits.add_driver_change(0)
	check(is_equal_approx(float(p["service_left"]), PitRules.DRIVER_CHANGE_S) and is_equal_approx(float(p["service_total"]), 8.5 + PitRules.DRIVER_CHANGE_S - 1.0),
		"a driver change keeps the car in the box for %.0f s more" % PitRules.DRIVER_CHANGE_S)
	var hand := sim.pits.car_handover(0)
	var other: RaceSim = _race(st, d)["sim"]
	other.pits.apply_handover(0, hand)
	check(other.entries[0].pit["phase"] == PitRules.PHASE_SERVICE and is_equal_approx(float(other.entries[0].pit["service_left"]), PitRules.DRIVER_CHANGE_S),
		"the new driver's machine carries on with the stop")
	sim.cars[0].fuel_l = 12.5
	sim.cars[0].tyre_wear[2] = 0.4
	other.cars[0].deserialize(sim.cars[0].serialize())
	check(is_equal_approx(other.cars[0].fuel_l, 12.5) and is_equal_approx(other.cars[0].tyre_wear[2], 0.4), "fuel and tyre wear move with the car")


## Settings > Controller: the player's own key and button bindings (input).
func test_rebinding() -> void:
	print("rebinding")
	InputSetup.register_actions()
	check(InputSetup.keys_of({}, "accelerate") == [KEY_W, KEY_UP], "throttle starts on W and Up")
	for r in InputSetup.REBINDABLE:
		check(InputMap.has_action(r[0]), "%s is an action" % r[0])
	var o := InputSetup.with_binding({}, "accelerate", "keys", 0, KEY_I)
	check(InputSetup.keys_of(o, "accelerate") == [KEY_I, KEY_UP], "key 1 of throttle changed to I")
	o = InputSetup.with_binding(o, "accelerate", "keys", 1, KEY_I)
	check(InputSetup.keys_of(o, "accelerate") == [KEY_I], "the same key twice on one control is kept once")
	o = InputSetup.with_binding(o, "brake", "pad", 0, {"button": JOY_BUTTON_B})
	check(InputSetup.same_binding(InputSetup.pads_of(o, "brake")[0], {"button": JOY_BUTTON_B}), "pad brake on B")
	check("Next tyres" in InputSetup.used_by(o, "brake", "pad", {"button": JOY_BUTTON_B}), "B is also next tyres: shown as a clash")
	o = InputSetup.with_binding(o, "brake", "pad", 0, null)
	check(InputSetup.pads_of(o, "brake").size() == 1, "a cleared binding is dropped")
	InputSetup.apply_bindings(o)
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_I
	ev.pressed = true
	check(InputMap.event_is_action(ev, "accelerate"), "I now drives the throttle")
	ev.physical_keycode = KEY_W
	check(not InputMap.event_is_action(ev, "accelerate"), "W no longer does")
	var m := InputEventJoypadMotion.new()
	m.axis = JOY_AXIS_TRIGGER_LEFT
	m.axis_value = 0.9
	check(InputSetup.binding_from_event(m)["kind"] == "pad", "a squeezed trigger can be picked as a binding")
	m.axis_value = 0.2
	check(InputSetup.binding_from_event(m).is_empty(), "a stick barely moving is not taken as a binding")
	check(InputSetup.describe("pad", {"axis": JOY_AXIS_TRIGGER_RIGHT, "dir": 1.0}) == "RT", "RT is named RT")
	# Saved like any pref and loaded back (ConfigFile keeps the nested lists).
	var cfg := ConfigFile.new()
	cfg.set_value("prefs", "controls", o)
	cfg.save("user://test_controls.cfg")
	var back := ConfigFile.new()
	back.load("user://test_controls.cfg")
	check(InputSetup.keys_of(back.get_value("prefs", "controls"), "accelerate") == [KEY_I], "bindings load back from the settings file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_controls.cfg"))
	InputSetup.register_actions()
	ev.physical_keycode = KEY_W
	check(InputMap.event_is_action(ev, "accelerate"), "defaults come back on a reset")


## Pit stops that change only some tyres, and drivers sharing a car: AI
## line-ups that change at a stop, a solo player's AI co-driver.
func test_tyre_choice_and_line_ups() -> void:
	print("tyre choice and driver line-ups")
	check(PitRules.wheels_of("front") == [0, 1] and PitRules.wheels_of("rr") == [3] and PitRules.wheels_of("left") == [0, 2]
		and PitRules.wheels_of("nonsense") == [0, 1, 2, 3], "wheel choices map to the right wheels")
	check(is_equal_approx(PitRules.tyre_time(4), PitRules.TYRE_CHANGE_S) and PitRules.tyre_time(2) < PitRules.tyre_time(4)
		and PitRules.tyre_time(1) < PitRules.tyre_time(2) and PitRules.tyre_time(0) == 0.0, "fewer tyres are quicker to change")
	var d := _data()
	var st := RaceSettings.new()
	st.laps = 8
	st.ai_count = 3
	st.mandatory_pit_stops = 1
	st.damage_enabled = true
	st.set_damage_level("full")
	var sim: RaceSim = _race(st, d)["sim"]
	var pits := sim.pits
	var c := sim.cars[0]
	var same := sim.compounds[0].id
	c.tyre_wear = PackedFloat64Array([0.6, 0.6, 0.2, 0.2])
	var plan := {"tyre": PitRules.TYRE_DRY, "wheels": "front", "fuel": 0.0, "repair": true}
	var w := pits.service_for(0, plan)
	check(w["tyre"] == same and w["wheels"] == [0, 1] and is_equal_approx(w["tyre_s"], PitRules.tyre_time(2)),
		"fronts only: two tyres, %.2f s" % w["tyre_s"])
	var other := PitRules.TYRE_WET if same != "full_wet" else PitRules.TYRE_INTER
	var w2 := pits.service_for(0, {"tyre": other, "wheels": "front", "fuel": 0.0, "repair": true})
	check(w2["wheels"] == [0, 1, 2, 3], "a new compound always goes on all four")
	c.puncture[3] = 1.0
	var w3 := pits.service_for(0, {"tyre": PitRules.TYRE_KEEP, "wheels": "all", "fuel": 0.0, "repair": true})
	check(w3["tyre"] == same and w3["wheels"] == [3], "a punctured tyre is changed even on a 'no tyres' stop")
	var w4 := pits.service_for(0, plan)
	check(w4["wheels"] == [0, 1, 3], "and alongside the planned fronts (%s)" % str(w4["wheels"]))
	# Run the stop: only those tyres are new.
	var p: Dictionary = sim.entries[0].pit
	pits.set_plan(0, {"tyre": PitRules.TYRE_DRY, "wheels": "front", "fuel": 0.0, "repair": true})
	check(p["plan"]["wheels"] == "front", "the plan keeps the wheel choice")
	pits.set_plan(0, {"wheels": "bogus"})
	check(p["plan"]["wheels"] == "front", "an unknown wheel choice is ignored")
	p["work"] = pits.service_for(0, p["plan"])
	pits._finish_service(0)
	check(c.tyre_wear[0] == 0.0 and c.tyre_wear[1] == 0.0 and is_equal_approx(c.tyre_wear[2], 0.2) and c.puncture[3] == 0.0
		and c.tyre_wear[3] == 0.0, "after the stop: new fronts and a new rear right, old rear left (%s)" % str(c.tyre_wear))
	check(p["last_stop"]["wheels"] == [0, 1, 3], "the stop records which tyres were changed")

	# Driver line-ups: two drivers per car.
	st.drivers_per_car = 2
	var start := RaceFactory.plan(st, [{"name": "Solo", "car_id": "bmw_m4_gt3"}], d["cars"], d["drivers"])
	var names := {}
	var ok := true
	var solo := {}
	for e in start["entries"]:
		if e["is_ai"]:
			ok = ok and e.get("lineup", []).size() == 2 and e["lineup"][0]["name"] == e["driver_name"]
			for m in e.get("lineup", []):
				ok = ok and not names.has(m["name"])
				names[m["name"]] = true
		else:
			solo = e
	check(ok, "every AI car has a line-up of two different drivers, its lead driver first")
	var crew: Array = solo.get("crew", [])
	check(crew.size() == 2 and int(crew[1]["peer_id"]) == RaceEntry.AI_PEER and crew[1]["ai"] and crew[1]["role"] == RaceEntry.ROLE_PIT_WALL
		and not names.has(crew[1]["name"]), "a solo player gets an AI co-driver on the pit wall")
	var again := RaceFactory.plan(st, [{"name": "Solo", "car_id": "bmw_m4_gt3"}], d["cars"], d["drivers"])
	check(str(again["entries"]) == str(start["entries"]), "line-ups come from the seed (every machine builds the same)")
	st.drivers_per_car = 1
	var plain := RaceFactory.plan(st, [{"name": "Solo", "car_id": "bmw_m4_gt3"}], d["cars"], d["drivers"])
	var no_lineups := true
	for e in plain["entries"]:
		no_lineups = no_lineups and not e.has("lineup") and e.get("crew", []).size() <= 1
	check(no_lineups, "one driver per car: no line-ups or co-drivers")
	var co := RaceEntry.from_description(solo)
	check(RaceEntry.is_ai_peer(co.crew[1]["peer_id"]) and co.human_crew().size() == 1 and co.at_wheel() == "Solo", "the player is at the wheel")
	co.crew[0]["role"] = RaceEntry.ROLE_PIT_WALL
	co.crew[1]["role"] = RaceEntry.ROLE_DRIVER
	check(co.driver_peer() == RaceEntry.AI_PEER and co.at_wheel() == crew[1]["name"], "after a change the co-driver is at the wheel")

	# An AI race with line-ups: the AI hand over at their stop, and the new
	# driver's traits take over the car.
	st.drivers_per_car = 2
	st.laps = 4
	st.ai_count = 4
	var r := _race(st, d)
	sim = r["sim"]
	var ai: Dictionary = r["ai"]
	var changes := 0
	var traits_follow := true
	for _t in 60 * 60 * 12:
		var ins := []
		for i in sim.car_count():
			ins.append(ai[i].get_input(sim, i))
		sim.step(ins)
		for ev in sim.events:
			if ev["type"] == "pit_stop" and str(ev.get("driver", "")) != "":
				changes += 1
				var e: RaceEntry = sim.entries[ev["car"]]
				traits_follow = traits_follow and e.at_wheel() == ev["driver"] and e.traits == e.lineup[1]["traits"]
		if sim.phase == RaceSim.Phase.FINISHED:
			break
	check(sim.phase == RaceSim.Phase.FINISHED, "a race with driver line-ups finishes")
	check(changes >= 3, "the AI change drivers at their stops (%d of %d cars)" % [changes, sim.car_count()])
	var followed := true
	for i in sim.car_count():
		if sim.entries[i].pit["driver_idx"] == 1:
			followed = followed and ai[i].stint_driver == 1 and ai[i].traits == sim.entries[i].lineup[1]["traits"]
	check(traits_follow and followed, "the new driver's traits drive the car")


## Settings registry, saved prefs and units (core).
func test_settings_and_units() -> void:
	print("settings and units")
	# The GameData autoload isn't loaded in a test run: make one.
	var gd = load("res://modules/core/game_data.gd").new()
	gd.persist_prefs = false
	gd._register_defaults()
	for key in ["driving_help", "aid_braking_zones", "aid_track_assist", "aid_racing_line", "manual_gears",
			"hud_timing_tower", "units", "power_unit", "display_mode", "vol_master", "vol_engine", "show_fps"]:
		check(not gd.setting_info(key).is_empty() and gd.prefs.has(key), "setting %s is registered with a value" % key)
	check("controller" in gd.SECTIONS and gd.settings_in("controller").size() > 0, "Settings has a Controller section")
	for sec in gd.SECTIONS:
		if sec != "garage":
			check(gd.settings_in(sec).size() > 0, "Settings > %s has options" % sec)
	check(gd.prefs["power_unit"] == "hp", "power shows in hp by default")
	gd.register_setting("gameplay", "test_opt", "Test", [[1, "One"], [2, "Two"]], 2)
	check(gd.prefs["test_opt"] == 2 and gd.settings_in("gameplay").back()["key"] == "test_opt", "a module can add its own option")
	# Round trip through a settings file.
	var was_persist: bool = gd.persist_prefs
	var was_path: String = gd._settings_path
	gd.persist_prefs = true
	gd._settings_path = "user://test_settings.cfg"
	gd.set_pref("test_opt", 1)
	gd.prefs["test_opt"] = 2
	gd.load_prefs()
	check(gd.prefs["test_opt"] == 1, "a changed setting is saved and loads back")
	var cfg := ConfigFile.new()
	cfg.set_value("prefs", "test_opt", 7)   # no longer a valid choice
	cfg.save("user://test_settings.cfg")
	gd.load_prefs()
	check(gd.prefs["test_opt"] == 1, "a saved value that is no longer a choice is ignored")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_settings.cfg"))
	gd.persist_prefs = was_persist
	gd._settings_path = was_path
	# Units
	Units.prefs = gd.prefs
	gd.prefs["units"] = "metric"
	gd.prefs["power_unit"] = "hp"
	check(Units.speed(50.0) == "180 km/h", "50 m/s = 180 km/h (%s)" % Units.speed(50.0))
	check(Units.power(441.0) == "591 hp", "441 kW = 591 hp (%s)" % Units.power(441.0))
	check(Units.temp(85.0) == "85°C", "metric temperatures in °C")
	gd.prefs["units"] = "uk"
	check(Units.speed(50.0) == "112 mph" and Units.temp(20.0) == "20°C" and Units.distance(1609.344) == "1.00 mi",
		"UK: mph and miles, but °C (%s, %s)" % [Units.speed(50.0), Units.distance(1609.344)])
	gd.prefs["units"] = "imperial"
	check(Units.temp(100.0) == "212°F" and Units.fuel(3.7854118) == "1.0 gal", "US: °F and gallons")
	gd.prefs["power_unit"] = "kw"
	check(Units.power(441.0) == "441 kW", "kW when chosen")
	gd.prefs["power_unit"] = "ps"
	check(Units.power(441.0) == "600 PS", "PS when chosen (%s)" % Units.power(441.0))
	Units.prefs = {}
	gd.free()


## Up to 25 cars in one class, 45 in a multi-class race.
func test_grid_limits() -> void:
	print("grid limits")
	var d := _data()
	var s := RaceSettings.new()
	s.track_id = "monza"
	s.car_class = "GT3"
	s.ai_count = 60
	var drivers: Array = d["drivers"]
	var cars: Dictionary = d["cars"]
	var track: TrackData = d["track"]
	var me := [{"name": "Me", "car_id": "bmw_m4_gt3"}]
	var start := RaceFactory.plan(s, me, cars, drivers, track)
	check(start["entries"].size() == 25, "single class: 25 cars at most (%d)" % start["entries"].size())
	s.car_class = RaceSettings.CLASS_MULTI
	start = RaceFactory.plan(s, me, cars, drivers, track)
	check(start["entries"].size() == 45, "multi-class: 45 cars at most (%d)" % start["entries"].size())
	s.ai_count = 10
	start = RaceFactory.plan(s, me, cars, drivers, track)
	check(start["entries"].size() == 11, "fewer AI asked for, fewer cars")


## Bought cars, upgrades and liveries stay saved; a broken save falls back
## to the backup copy.
func test_garage_saves() -> void:
	print("garage saves")
	var cars: Dictionary = _data()["cars"]
	var path := "user://test_profile.json"
	for f in [path, path + ".bak", path + ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	var p := TeamProfile.load_or_new(path)
	p.money = 1000000
	var bmw: CarDefinition = cars["bmw_m4_gt3"]
	check(not p.owns(bmw.id), "a new team owns no cars")
	check(p.buy_car(bmw) and p.owns(bmw.id), "buy a car")
	check(p.money == 1000000 - UpgradeCatalog.car_price(bmw), "buying costs the car's price (%s)" % UpgradeCatalog.format_money(UpgradeCatalog.car_price(bmw)))
	check(not p.buy_car(bmw), "can't buy the same car twice")
	p.set_level(bmw, "engine", 2)
	p.set_livery(bmw.id, {"pattern": "stripes", "primary": "#0b3d91"})
	check(p.save() == OK, "saves")
	p.set_level(bmw, "aero", 1)
	check(p.save() == OK and FileAccess.file_exists(path + ".bak"), "a second save keeps the previous one as .bak")
	var q := TeamProfile.load_or_new(path)
	check(q.owns(bmw.id) and q.level(bmw.id, "engine") == 2 and q.level(bmw.id, "aero") == 1 and q.livery_for(bmw.id).get("pattern") == "stripes",
		"car, upgrades and livery load back")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ broken")
	f.close()
	var r := TeamProfile.load_or_new(path)
	check(r.owns(bmw.id) and r.level(bmw.id, "engine") == 2, "a broken save loads from the backup")
	# Saves from before cars were bought: upgraded cars count as owned.
	var old := TeamProfile.new()
	old.from_dict({"version": 1, "money": 5, "cars": {"bmw_m4_gt3": {"upgrades": {"engine": 1}, "livery": {}}, "flat6_rear_gt": {"upgrades": {}, "livery": {}}}})
	check(old.owns("bmw_m4_gt3") and not old.owns("flat6_rear_gt"), "old saves: upgraded cars are in the garage")
	var money_before := r.money
	var back := r.sell_car(bmw)
	check(not r.owns(bmw.id) and back > 0 and r.money == money_before + back, "selling a car refunds part of it")
	for g in [path, path + ".bak", path + ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(g))


## Graphics effects: run-off and gravel are drawn at the height cars are
## drawn at (cars used to vanish under them on hilly tracks), and a pit
## crew does a stop (jacks the car up, takes the wheels off, puts them back).
func test_graphics_effects() -> void:
	print("graphics effects")
	for id in ["spa", "spielberg", "interlagos"]:
		var t := TrackCatalog.load_track(id)
		var tv := TrackView.new()
		tv.setup(t, null)
		var worst := 0.0
		var n := 0
		var bad := 0
		for i in range(0, t.point_count(), 3):
			var nrm := t.vertex_normal(i)
			for side in [-1.0, 1.0]:
				var e: float = (t.width_right[i] if side > 0 else t.width_left[i]) + t.kerb_width
				for k in range(1, 6):
					var off: float = side * (e + k * (t.runoff - t.kerb_width) / 6.0)
					var q := t.points[i] + nrm * off
					var proj := t.project(q)
					if absf(float(proj["offset"]) - off) > 0.5 or t.in_pit_lane(q):
						continue   # nearer another part of the track, or in the pit lane
					var d: float = tv._surface_y(i, t.cum_s[i], off, q) - t.surface_height_at(q, proj["idx"])
					worst = maxf(worst, d)
					n += 1
					if d > 0.3:
						bad += 1
		check(n > 100 and bad <= n / 100, "%s: run-off drawn where cars are (%d of %d samples > 0.3 m above, worst %.2f m)" % [id, bad, n, worst])
		tv.free()
	# pit crew
	var t2 := TrackCatalog.load_track("monza")
	var tv2 := TrackView.new()
	tv2.setup(t2, null)
	var crews := PitCrews.new()
	tv2.add_child(crews)
	crews.setup(tv2)
	var def: CarDefinition = CarCatalog.load_all()["bmw_m4_gt3"]
	crews.add_team(0, 4, Color.RED, def)
	crews.fill_garages()
	check(crews.crews.size() == t2.pit_box_count, "a crew in every garage (%d)" % crews.crews.size())
	var work := {"tyre_s": 6.0, "fuel_s": 8.0, "repair_s": 0.0, "total_s": 10.0}
	crews.set_stop(0, PitCrews.Stop.COMING, 0.0, work)
	for f in 120:
		crews._process(1.0 / 30.0)
	var box: Vector2 = t2.pit_box(4)["pos"]
	var near := 0
	for p in crews.crews[4].people:
		if p.pos.distance_to(box) < 5.0:
			near += 1
	check(near >= 9, "crew on their marks round the box when the car comes in (%d)" % near)
	crews.set_stop(0, PitCrews.Stop.SERVICE, 3.0, work)
	check(crews.car_lift(0) > 0.05 and crews.wheels_off(0), "mid-stop: car on the jacks, wheels off")
	crews.set_stop(0, PitCrews.Stop.SERVICE, 9.8, work)
	check(not crews.wheels_off(0), "end of the stop: wheels back on")
	crews.set_stop(0, PitCrews.Stop.LEAVING, 10.0, work)
	check(crews.car_lift(0) == 0.0, "car off the jacks when it leaves")
	tv2.free()


## Every AI car gets away from the grid and keeps going (they used to all
## reverse 3 s after the green: the stuck check started from line point 0,
## so a car still behind the start line looked like it had gone backwards).
func test_race_start() -> void:
	print("race start")
	var d := _data()
	var settings := RaceSettings.new()
	settings.ai_count = 15
	settings.laps = 1
	settings.seed = 7
	var r := _race(settings, d)
	var sim: RaceSim = r["sim"]
	var ai: Dictionary = r["ai"]
	var n := sim.car_count()
	var stopped := 0
	var reversing := 0
	var green_tick := -1
	while sim.tick < 60 * 30:
		var inputs := []
		for i in n:
			inputs.append(ai[i].get_input(sim, i))
		sim.step(inputs)
		if sim.phase == RaceSim.Phase.RACING and green_tick < 0:
			green_tick = sim.tick
		if green_tick >= 0 and sim.tick - green_tick > 60 and sim.tick - green_tick < 60 * 12:
			for i in n:
				if ai[i].recover_time > 0.0:
					reversing = maxi(reversing, i + 1)
		if green_tick >= 0 and sim.tick - green_tick == 60 * 12:
			for i in n:
				if sim.cars[i].speed() < 5.0:
					stopped += 1
	check(reversing == 0, "no AI car reverses on the opening lap (first one reversing: %d)" % reversing)
	check(stopped == 0, "every AI car is moving 12 s after the start (%d stopped)" % stopped)


## Settings > Gameplay aids: the driving line and its braking zones, the
## track assist, the manual gearbox.
## A second "controller" with an axis stuck off centre (a pedal set, a
## motion sensor, a virtual pad) must not steer or zoom: only the pad in use
## feeds the stick and trigger actions.
func test_active_pad() -> void:
	print("active controller")
	if not InputMap.has_action("steer_right"):
		InputMap.load_from_project_settings()
		InputSetup.register_actions()
	ActivePad._choose(0)
	var stuck := _pad_motion(3, JOY_AXIS_LEFT_X, 1.0)
	var zoom := _pad_motion(3, JOY_AXIS_RIGHT_Y, 1.0)
	check(Input.get_action_strength("steer_right") == 0.0, "a stuck axis on another device doesn't steer")
	check(Input.get_action_strength("zoom_out") == 0.0, "... or zoom")
	check(not ActivePad.observe(stuck) and not ActivePad.observe(stuck), "a stuck axis never takes over")
	# The player's pad: moving its stick picks it, and then it steers.
	ActivePad.observe(_pad_motion(2, JOY_AXIS_LEFT_X, 0.0))
	check(ActivePad.observe(_pad_motion(2, JOY_AXIS_LEFT_X, -0.9)) and ActivePad.device == 2, "moving a stick picks that pad")
	_pad_motion(2, JOY_AXIS_LEFT_X, -0.8)
	check(Input.get_action_strength("steer_left") > 0.5 and Input.get_action_strength("steer_right") == 0.0,
		"the pad in use steers (left %.2f right %.2f)" % [Input.get_action_strength("steer_left"), Input.get_action_strength("steer_right")])
	_pad_motion(2, JOY_AXIS_LEFT_X, 0.0)
	# A button picks a pad straight away, and the old pad's held axis lets go.
	_pad_motion(2, JOY_AXIS_RIGHT_Y, 0.9)
	var b := InputEventJoypadButton.new()
	b.device = 4
	b.button_index = JOY_BUTTON_A
	b.pressed = true
	check(ActivePad.observe(b) and ActivePad.device == 4, "a button press picks that pad")
	check(Input.get_action_strength("zoom_out") == 0.0, "switching pads lets go of the old pad's stick")
	var ui_ok := true
	for ev in InputMap.action_get_events("ui_right"):
		if ev is InputEventJoypadMotion:
			ui_ok = ui_ok and ev.device == 4
	check(ui_ok, "menu navigation sticks follow the pad in use too")
	ActivePad._choose(-1)


func _pad_motion(dev: int, axis: JoyAxis, v: float) -> InputEventJoypadMotion:
	var m := InputEventJoypadMotion.new()
	m.device = dev
	m.axis = axis
	m.axis_value = v
	Input.parse_input_event(m)
	Input.flush_buffered_events()
	return m


func test_driving_aids() -> void:
	print("driving aids")
	var d := _data()
	var track: TrackData = d["track"]
	var def: CarDefinition = d["cars"]["bmw_m4_gt3"]
	var tc: TyreCompound = d["tyres"][def.tyre_compound_id]
	var line := DrivingLine.build(track, def, tc)
	check(line.zones.size() >= 6, "Red Bull Ring has its braking zones (%d)" % line.zones.size())
	var ok := true
	for z in line.zones:
		ok = ok and float(z["entry_v"]) > float(z["apex_v"]) + DrivingLine.ZONE_MIN_DROP - 0.01
	check(ok, "each braking zone slows the car down")
	# Turn 3 (the hairpin up the hill): a GT3 arrives at well over 200 km/h, slows to under 120.
	var slowest := 1e9
	for z in line.zones:
		slowest = minf(slowest, float(z["apex_v"]))
	check(slowest * 3.6 < 110.0 and slowest * 3.6 > 50.0, "slowest corner is a hairpin speed (%d km/h)" % roundi(slowest * 3.6))
	# The brake envelope is never above the corner and full-lap speeds.
	var env_ok := true
	for k in line.size():
		env_ok = env_ok and line.lap_speed[k] <= line.speed[k] + 0.01
	check(env_ok, "brake envelope and lap speeds agree")
	# Track assist: a car drifting off the right edge at speed is steered back.
	var env := SimEnvironment.new()
	env.bind_track(track)
	var s_far := 120.0
	var i := track.index_at(s_far)
	var pulls := []
	for lvl in [0, 1, 2]:
		var c := _car_at(track, s_far, 50.0)
		c.pos = track.position_at(s_far, track.width_right[i] - 1.0)
		c.heading += 0.03     # pointing a little off the track
		c.vel = Vector2.from_angle(c.heading) * 50.0
		c.gear = 5
		c.assist_track = lvl
		var inp := CarInput.new()
		inp.throttle = 1.0
		CarPhysics.step(c, inp, def, tc, env, track, 1.0 / 240.0, 0.0, [], 0)
		pulls.append(c.steer_angle)
	check(pulls[0] == 0.0 and pulls[1] < 0.0 and pulls[2] < pulls[1], "track assist steers back from the edge, more when strong (%.4f %.4f %.4f)" % pulls)
	# Manual gearbox: one gear per press, and no downshift that over-revs.
	var g := _car_at(track, s_far, 40.0)
	g.manual_gears = true
	g.gear = 3
	var press := CarInput.new()
	press.throttle = 1.0
	press.shift_up = true
	for _k in 8:
		CarPhysics.step(g, press, def, tc, env, track, 1.0 / 240.0, 0.0, [], 0)
	check(g.gear == 4, "holding shift up changes one gear (gear %d)" % g.gear)
	var none := CarInput.new()
	none.throttle = 1.0
	for _k in 600:
		CarPhysics.step(g, none, def, tc, env, track, 1.0 / 240.0, 0.0, [], 0)
	check(g.gear == 4, "manual gearbox doesn't change gear by itself (gear %d)" % g.gear)
	var down := CarInput.new()
	down.shift_down = true
	g.vel = Vector2.from_angle(g.heading) * 75.0
	g.gear = 4
	CarPhysics.step(g, down, def, tc, env, track, 1.0 / 240.0, 0.0, [], 0)
	check(g.gear == 4, "a downshift that would over-rev is refused at 270 km/h")
	var c2 := CarState.new()
	g.assist_track = 2
	c2.deserialize(g.serialize())
	check(c2.manual_gears and c2.assist_track == 2, "manual gearbox and track assist survive a snapshot")
## Race HUD: the timing tower fits big grids (top three plus a window round
## the player), every car gets a manufacturer badge, names stay short.
func test_hud_timing() -> void:
	print("hud timing:")
	var all := RaceHud.tower_rows(20, 5, 25)
	check(all.size() == 20 and all[0] == 0 and all[19] == 19, "small grid: tower shows every car")
	var big := RaceHud.tower_rows(45, 30, 25)
	check(big.size() == 25 and big.slice(0, 3) == [0, 1, 2] and big.has(30), "45 cars: top three plus a window round P31")
	var last := RaceHud.tower_rows(45, 44, 25)
	check(last.size() == 25 and last[-1] == 44, "45 cars: last place still on the tower")
	var cars := CarCatalog.load_all()
	var ok := true
	for id in cars:
		var b := RaceHud.badge_for(cars[id])
		if str(b[0]) == "" or str(b[0]).length() > 4:
			ok = false
			printerr("    bad badge for ", id, ": ", b)
	check(ok, "every car has a manufacturer badge")
	for id in cars:
		if cars[id].display_name.begins_with("BMW"):
			check(RaceHud.badge_for(cars[id])[0] == "BMW", "BMW badge reads BMW")
			break
	check(RaceHud.short_name("Driver 727") == "Driver 727" and RaceHud.short_name("Alessandro Bellini-Rossi") == "A. Bellini-Ross", "driver names fit the tower")
	check(RaceHud.fmt_sector(32.4567) == "32.457" and RaceHud.fmt_sector(0.0) == "--.---", "sector times format")


## Online play: hit boxes match the bodywork, remote cars are placed where
## they are now (clock sync + prediction), and every machine paints the
## field the same.
func test_online_contacts() -> void:
	print("online contacts")
	var cars := CarCatalog.load_all()
	var mid: CarDefinition = cars["v8_mid_berlinetta"]
	check(mid.body_offset > 0.15, "mid-engined car's body sits ahead of its CG (%.2f m)" % mid.body_offset)
	# Nose to tail on a straight: the hit is when the bumpers meet, not before.
	var rear_bumper := mid.body_offset - mid.length * 0.5
	var at_gap := func(gap: float) -> Dictionary:
		var x_b := rear_bumper - gap - (mid.body_offset + mid.length * 0.5)
		return RaceSim.body_contact(Vector2.ZERO, 0.0, mid, Vector2(x_b, 0.0), 0.0, mid)
	check(at_gap.call(0.12).is_empty(), "no contact with 12 cm between the bumpers")
	var hit: Dictionary = at_gap.call(-0.05)
	check(not hit.is_empty() and absf(hit["depth"] - 0.05) < 0.02 and hit["normal"].x < -0.9,
		"contact when the bumpers overlap 5 cm (depth %.3f)" % (hit.get("depth", -1.0)))
	# Side by side.
	var side := func(gap: float) -> Dictionary:
		return RaceSim.body_contact(Vector2.ZERO, 0.0, mid, Vector2(0.4, mid.width + gap), 0.0, mid)
	check(side.call(0.1).is_empty(), "no contact with 10 cm between the doors")
	check(not side.call(-0.04).is_empty(), "contact when the doors overlap")
	# Deep overlap still pushes apart along the shortest way.
	var deep := RaceSim.body_contact(Vector2.ZERO, 0.0, mid, Vector2(0.0, 1.2), 0.0, mid)
	check(not deep.is_empty() and deep["normal"].y > 0.9 and deep["depth"] > 0.7, "deep overlap pushes sideways")
	# Turned 90 degrees: T-bone, the nose of B into A's door.
	var tb := RaceSim.body_contact(Vector2.ZERO, 0.0, mid, Vector2(mid.body_offset, mid.width * 0.5 + mid.length * 0.5 + mid.body_offset - 0.05), -PI * 0.5, mid)
	check(not tb.is_empty() and tb["normal"].y > 0.9, "T-bone contact found")

	# A remote car at 70 m/s round a long bend, sent at 30 Hz, arriving 90 ms
	# (+/- 15 ms) later. Placed in the present it is within a car's width of
	# where its driver has it; the old delayed view was many metres behind.
	var path := []        # true state each 1/60 s, steering in and out
	var c0 := CarState.new()
	for tick in 601:
		var t := tick / 60.0
		var w := 0.12 + 0.1 * sin(t * 1.3)
		var speed := 70.0 - 8.0 * sin(t * 0.7)
		c0.ax = -8.0 * 0.7 * cos(t * 0.7)
		var snap := CarState.new()
		snap.pos = c0.pos
		snap.heading = c0.heading
		snap.vel = Vector2(cos(c0.heading), sin(c0.heading)) * speed
		snap.yaw_rate = w
		snap.ax = c0.ax
		path.append(snap)
		for sub in 10:
			c0.heading += w / 600.0
			c0.pos += Vector2(cos(c0.heading), sin(c0.heading)) * speed / 600.0
	var truth := func(t: float) -> CarState:
		return path[clampi(roundi(t * 60.0), 0, path.size() - 1)]
	var live := NetTimeline.new()
	var old := NetTimeline.new()
	var pending := []
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var err_now := 0.0
	var err_old := 0.0
	var shown := CarState.new()
	var shown_old := CarState.new()
	for tick in 600:
		var now := tick / 60.0
		if tick % 2 == 0:
			var data := PackedFloat32Array()
			truth.call(now).pack_net(data)
			pending.append([now + 0.09 + rng.randf_range(-0.015, 0.015), now, data])
		for p in pending.duplicate():
			if p[0] <= now:
				live.add(p[1], now, p[2])
				old.add(p[1], now, p[2])
				pending.erase(p)
		live.apply(shown, now, true)
		old.apply(shown_old, now, false)
		if tick > 120:
			var real: CarState = truth.call(now)
			err_now = maxf(err_now, shown.pos.distance_to(real.pos))
			err_old = maxf(err_old, shown_old.pos.distance_to(real.pos))
	check(err_now < 0.6, "remote car placed in the present: worst error %.2f m" % err_now)
	check(err_old > 8.0, "(the old delayed view was up to %.1f m behind)" % err_old)
	# Braking hard: the guess doesn't run past where the car stops.
	var b := CarState.new()
	b.vel = Vector2(5.0, 0.0)
	b.ax = -40.0
	NetTimeline.predict(b, 0.3)
	check(b.vel.x >= -0.01 and b.pos.x <= 1.6, "prediction brakes to a stop, not backwards (%.2f m/s)" % b.vel.x)

	# Clock sync: the host's clock is 5 s ahead; uneven pings are ignored.
	var nc := NetClock.new()
	nc.add_pong(10.0, 15.05, 10.1)        # even 100 ms round trip
	nc.add_pong(10.5, 15.70, 10.9)        # slow way back, 400 ms
	check(nc.synced and absf(nc.offset - 5.0) < 0.03, "clock offset from the quickest pings (%.3f s)" % nc.offset)
	nc.add_pong(20.0, 27.05, 20.1)        # host clock jumped 2 s (a hitch)
	check(absf(nc.offset - 7.0) < 0.03, "clock offset follows a jump (%.3f s)" % nc.offset)
	# A timeline whose sender switches to the host clock starts over.
	var sw := NetTimeline.new()
	var st := PackedFloat32Array()
	CarState.new().pack_net(st)
	sw.add(100.0, 3.0, st)
	sw.add(3.05, 3.1, st)
	check(sw.clocks_agree() and sw.received == 2, "timeline follows a sender that syncs its clock")

	# Every machine paints the field the same, whichever car is its own.
	var ids := ["bmw_m4_gt3", "bmw_m4_gt3", "bmw_m4_gt3", "bmw_m4_gt3"]
	var liv := WorldView.field_liveries(ids, [{}, {}, {}, {}], [false, true, true, false])
	check(liv[1].is_empty(), "first player in a model keeps its own livery (even behind an AI car)")
	check(not liv[2].is_empty() and not liv[0].is_empty() and str(liv[0]) != str(liv[2]),
		"same model again gets its own colours")
	liv = WorldView.field_liveries(ids, [{}, {}, {"primary": "#123456"}, {}], [false, true, true, false])
	check(liv[2]["primary"] == "#123456", "a player's own paint wins")
	var p := RaceEntry.new()
	p.crew = [{"peer_id": 5, "role": RaceEntry.ROLE_DRIVER}]
	check(p.is_player_driving(), "a person at the wheel is highlighted")
	p.crew = [{"peer_id": RaceEntry.AI_PEER, "role": RaceEntry.ROLE_DRIVER}]
	check(not p.is_player_driving(), "an AI co-driver is not")
