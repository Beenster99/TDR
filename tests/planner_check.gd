extends Node
## The strategist's pit planner in a real race scene (needs the autoloads, so
## it runs as a scene, not with -s). You start as the driver, hand the car to
## your AI co-driver on the grid and run the pit wall. Plans a mixed-tyre stop with new pressures,
## downforce, fuel and a driver change, sends it, then checks the crew got
## the plan, the radio message went out, and the stop fitted it.
##   godot --headless --path . res://tests/planner_check.tscn
## With a screen (xvfb): add -- <out.png> to save a shot of the planner.

var session: RaceSession
var scene: Node
var out := ""
var fails := 0
var _step := 0
var _radio: Array = []
var _sent_at := 0.0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else ""
	var s := RaceSettings.new()
	s.seed = 5
	s.track_id = "spa"
	s.laps = 4
	s.ai_count = 3
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.damage_enabled = true
	s.damage_level = "full"
	s.safety_car_enabled = false
	s.tuning_enabled = true
	s.drivers_per_car = 2
	s.environment = {"time_h": 14.0, "weather": "dry"}
	var humans := [{"name": "You", "car_id": "bmw_m4_gt3", "crew": [{"peer_id": 0, "name": "You", "role": RaceEntry.ROLE_DRIVER}]}]
	var start := RaceFactory.plan(s, humans, GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	session.team_radio.connect(func(_car: int, msg: Dictionary): _radio.append(msg))
	GameData.active_session = session
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	get_tree().create_timer(900.0).timeout.connect(func(): print("[planner] gave up"); _end())


var _handed := false


func _physics_process(_delta: float) -> void:
	if session == null:
		return
	if not _handed and session.local_car >= 0:
		# On the grid: the AI co-driver takes the wheel, we go to the pit wall.
		_handed = true
		session.request_role_swap(session.local_car, 0, RaceEntry.AI_PEER)
	if session.sim.phase != RaceSim.Phase.RACING:
		return
	var sim := session.sim
	var car := session.team_car
	var planner: PitPlanner = scene.planner
	match _step:
		0:
			print("pit planner")
			check(car >= 0 and session.local_car < 0, "we're the strategist of a car (car %d)" % car)
			scene._open_planner()
			check(planner.visible and planner.car == car, "the planner opens for our car")
			var dry := sim.dry_compound[car]
			# Inters on the left, new slicks on the right: mixed.
			planner._pick(0, false)
			planner._pick(2, true)
			planner.fit_picked(PitRules.TYRE_INTER)
			planner._do("pick_set", "right", 1, false)
			planner.fit_picked(dry)
			check(planner.draft["tyres"] == [PitRules.TYRE_INTER, dry, PitRules.TYRE_INTER, dry], "each tyre gets its own compound (%s)" % str(planner.draft["tyres"]))
			var psi0: float = planner.draft["psi"][1]
			planner._do("psi", [1, 1], 1, false)
			planner._do("psi", [1, 1], 1, false)
			planner._do("psi", [3, -1], 1, false)
			check(is_equal_approx(float(planner.draft["psi"][1]), psi0 + 1.0), "front right pressure up 1.0 psi on its own")
			var wf: float = planner.draft["wing_front"]
			planner._do("wing", ["wing_front", 1], 1, false)
			planner._do("wing", ["wing_rear", -1], 1, false)
			check(float(planner.draft["wing_front"]) == wf + 1.0, "front downforce up one")
			planner._do("fuel_none", null, 1, false)
			planner.change_fuel(2)
			check(float(planner.draft["fuel"]) == 10.0, "fuel set to 10 L (%s)" % str(planner.draft["fuel"]))
			check(planner.can_change_driver(), "the AI co-driver can hand over")
			planner._do("driver", null, 1, false)
			check(planner.draft["driver_change"], "driver change queued")
			check(planner.dirty(), "nothing is sent until Send")
			check(not sim.entries[car].pit["plan"].has("wheel_tyres"), "the crew's plan is untouched before Send")
			var lines := planner.message_lines()
			print("       " + " | ".join(lines))
			check(lines[0].begins_with("Box"), "the message starts with the box call")
			check(" ".join(lines).contains("Pressures:") and " ".join(lines).contains("Front downforce up 1")
				and " ".join(lines).contains("Driver change"), "the message names pressures, downforce and the driver change")
			_step = 1
			if out != "":
				_shot()
				return
			_send()
		2:
			# Wait for the stop to finish.
			if int(sim.entries[car].pit["stops"]) >= 1:
				var p: Dictionary = sim.entries[car].pit
				var dry := sim.dry_compound[car]
				var ids: Array = sim.wheel_compounds[car].map(func(t: TyreCompound) -> String: return t.id)
				check(ids == [PitRules.TYRE_INTER, dry, PitRules.TYRE_INTER, dry], "the stop fitted mixed tyres (%s)" % str(ids))
				check(sim.mixed_tyres(car) and p["compounds"] == ids, "and the pit state says so")
				check(absf(float(p["psi_trim"][1]) - float(p["psi_trim"][0])) > 0.9, "per-tyre pressures applied (%s)" % str(p["psi_trim"]))
				check(not p["plan"].has("wheel_tyres") and not p["plan"].has("psi"), "the one-off plan is cleared after the stop")
				var last: Dictionary = p["last_stop"]
				check(last.get("driver", "") != "" or session.local_car == car or sim.entries[car].driver_peer() == 0,
					"the driver change happened (now %s)" % sim.entries[car].at_wheel())
				_step = 3
				_end()
			elif sim.race_time - _sent_at > 420.0:
				check(false, "the car stopped within 7 minutes")
				_end()


func _send() -> void:
	var planner: PitPlanner = scene.planner
	var car := session.team_car
	var msg := planner.send()
	_sent_at = session.sim.race_time
	var p: Dictionary = session.sim.entries[car].pit
	check(p["box"], "Send calls the car in")
	check((p["plan"] as Dictionary).has("wheel_tyres") and (p["plan"] as Dictionary).has("psi"), "Send gives the crew the per-tyre plan")
	check(not session.pending_swap(car).is_empty(), "Send queues the driver change")
	check(str(msg.get("code", "")) == "pit_plan" and (msg.get("lines", []) as Array).size() >= 4, "Send radios the plan to the driver")
	check(not planner.dirty(), "after Send nothing is waiting")
	var w := session.sim.pits.service_for(car, p["plan"])
	check((w["wheels"] as Array).size() == 4 and w["tyre_s"] > 0.0, "the stop will change all four tyres (%s)" % str(w["wheel_tyres"]))
	planner.close()
	_step = 2


func _shot() -> void:
	for k in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[planner] shot saved to ", out)
	_send()
	# Then the pit wall console with the plan sent (radio log, plan row).
	for k in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.get_basename() + "_console.png")
	# And what the driver sees: the plan on the race screen.
	scene.crew.visible = false
	scene.hud.visible = true
	scene.hud.show_radio(_radio[-1] if not _radio.is_empty() else {}, 30.0)
	for k in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.get_basename() + "_driver.png")
	print("[planner] shots saved")
	_end()


func _end() -> void:
	print("PASS" if fails == 0 else "FAIL (%d failures)" % fails)
	get_tree().quit(1 if fails > 0 else 0)
