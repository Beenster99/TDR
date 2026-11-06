extends Control
## The strategist's damage advice (DamageAdvice, StrategistScreen OUR CAR):
## runs a short race in the background (every car on AI), then damages our
## car in a few ways and checks the advice: how bad, lap time lost, repair
## time (the same numbers a stop uses) and the call.
##   godot --headless --path . res://tests/damage_advice_shot.tscn
## With a screen (xvfb): add -- <out_prefix> to save <prefix>_<case>.png of the
## Strategist screen for each case.

var out := ""
var session: RaceSession
var wall: StrategistScreen
var planner: PitPlanner
var fails := 0
var _frames := 0
var _shot := 0
const SHOTS := ["moderate", "at_stop", "light", "puncture", "engine", "planner"]


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else ""
	var s := RaceSettings.new()
	s.seed = 11
	s.track_id = "brands_hatch"
	s.laps = 14
	s.ai_count = 9
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.set_damage_level("full")
	s.safety_car_enabled = false
	s.tuning_enabled = true
	s.environment = {"time_h": 14.0, "weather": "dry"}
	var humans := [{"name": "You", "car_id": "bmw_m4_gt3"}]
	var start := RaceFactory.plan(s, humans, GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	var me := session.local_car
	var drv := AIDriver.for_car(session.sim, me)
	var guard := 0
	while guard < 200000:
		guard += 1
		session.tick(drv.get_input(session.sim, me))
		var o := session.sim.running_order
		if session.sim.phase == RaceSim.Phase.RACING and not o.is_empty() and session.sim.entries[o[0]].laps_done >= 4:
			break
	size = Vector2(1600, 900)
	wall = StrategistScreen.new()
	add_child(wall)
	wall.setup(session)
	planner = PitPlanner.new()
	add_child(planner)
	planner.setup(session)
	wall.planner = planner
	_checks()
	_damage("moderate")
	wall.open()


func _clear(c: CarState) -> void:
	CarDamage.repair(c)


func _damage(kind: String) -> void:
	var c: CarState = session.sim.cars[session.local_car]
	_clear(c)
	session.sim.settings.mandatory_pit_stops = 1 if kind == "at_stop" else 0
	match kind:
		"moderate", "at_stop":
			c.damage_aero = 0.42
			c.body_damage[CarDamage.FRONT] = 0.5
			c.damage_suspension = 0.22
			c.alignment = 0.18
		"light":
			c.damage_aero = 0.14
			c.body_damage[CarDamage.LEFT] = 0.2
		"puncture":
			c.puncture[1] = 1.0
			c.damage_aero = 0.1
			c.body_damage[CarDamage.RIGHT] = 0.3
		"planner":
			c.damage_aero = 0.42
			c.body_damage[CarDamage.FRONT] = 0.5
			c.damage_suspension = 0.22
			session.sim.settings.mandatory_pit_stops = 1
			planner.open_for(session.local_car)
		"engine":
			c.damage_engine = 0.58
			c.body_damage[CarDamage.FRONT] = 0.6
			c.damage_aero = 0.3


func _checks() -> void:
	var sim := session.sim
	var tel := session.telemetry
	var me := session.local_car
	var c: CarState = sim.cars[me]
	_clear(c)
	var adv := DamageAdvice.assess(sim, tel, me)
	check(int(adv["level"]) == DamageAdvice.NONE and adv["call"] == "", "a clean car: no damage, no call")
	c.damage_aero = 0.04
	c.body_damage[CarDamage.FRONT] = 0.05
	adv = DamageAdvice.assess(sim, tel, me)
	check(int(adv["level"]) == DamageAdvice.SCUFFS and float(adv["repair_s"]) == 0.0, "a 4%% scuff: SCUFFS, nothing to repair (%s)" % adv["why"])
	# Moderate: the repair time is the one a stop would take.
	_damage("moderate")
	adv = DamageAdvice.assess(sim, tel, me)
	var want := CarDamage.repair_time(c, PitRules.repair_parts(c))
	check(absf(float(adv["repair_s"]) - want) < 0.01, "repair time %.1f s = the stop's repair time %.1f s" % [adv["repair_s"], want])
	var plan: Dictionary = (sim.entries[me].pit["plan"] as Dictionary).duplicate()
	plan["repair"] = true
	check(absf(float(adv["repair_s"]) - float(sim.pits.service_for(me, plan)["repair_s"])) < 0.01, "and the same as PitRules.service_for")
	check(float(adv["loss_lap"]) > 0.3, "moderate damage costs time: +%.2f s a lap" % adv["loss_lap"])
	check(int(adv["level"]) == DamageAdvice.MODERATE, "aero 42%% is MODERATE (%s)" % adv["level_text"])
	check(adv["call"] != "", "and makes a call: %s (%s)" % [adv["call"], adv["why"]])
	var more := float(adv["loss_lap"])
	c.damage_aero = 0.8
	check(float(DamageAdvice.assess(sim, tel, me)["loss_lap"]) > more, "worse damage costs more a lap")
	# Puncture: box now.
	_damage("puncture")
	adv = DamageAdvice.assess(sim, tel, me)
	check(int(adv["level"]) == DamageAdvice.CRITICAL and adv["call"] == DamageAdvice.BOX_NOW, "a flat tyre: CRITICAL, BOX NOW (%s)" % adv["why"])
	# Engine leaking: box now, it will fail.
	_damage("engine")
	adv = DamageAdvice.assess(sim, tel, me)
	check(adv["call"] == DamageAdvice.BOX_NOW and (adv["risk"] as String) != "", "leaking engine: BOX NOW with the risk said (%s)" % adv["risk"])
	# Light damage with no stop coming: a whole stop for it isn't worth it.
	_damage("light")
	adv = DamageAdvice.assess(sim, tel, me)
	print("    light: %s, %.2f s/lap, repair %.1f s, stop %.1f s, due %s: %s" % [adv["call"], adv["loss_lap"], adv["repair_s"], adv["stop_loss"], adv["stop_due"], adv["why"]])
	if not bool(adv["stop_due"]):
		check(adv["call"] in [DamageAdvice.STAY_OUT, DamageAdvice.YOUR_CALL], "light damage, no stop due: not worth a stop of its own")
	# Damage off: no advice.
	var lvl := sim.damage_level
	sim.damage_level = CarDamage.Level.OFF
	check(int(DamageAdvice.assess(sim, tel, me)["level"]) == DamageAdvice.NONE, "damage off: no advice")
	sim.damage_level = lvl
	for i in sim.car_count():
		DamageAdvice.assess(sim, tel, i)   # any car, no errors


func _process(_d: float) -> void:
	_frames += 1
	if _frames % 12 == 0 and _shot < SHOTS.size():
		if out != "":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("%s_%s.png" % [out, SHOTS[_shot]])
			print("  saved %s_%s.png" % [out, SHOTS[_shot]])
		var adv := DamageAdvice.assess(session.sim, session.telemetry, session.local_car)
		print("    %s: %s %s, +%.2f s/lap, repair %.0f s, %s" % [SHOTS[_shot], adv["level_text"], adv["call"], adv["loss_lap"], adv["repair_s"], adv["why"]])
		_shot += 1
		if _shot < SHOTS.size():
			_damage(SHOTS[_shot])
		wall.queue_redraw()
	if _shot >= SHOTS.size():
		print("PASS" if fails == 0 else "FAIL (%d)" % fails)
		get_tree().quit(1 if fails > 0 else 0)
