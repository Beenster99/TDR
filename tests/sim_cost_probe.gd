extends Node
## What one race tick costs on the CPU, split into AI, car physics,
## collisions and the rest, with a full grid from the start (no graphics).
##   godot --headless --path . res://tests/sim_cost_probe.tscn -- [track] [cars] [seconds]

func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var pos := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var track: String = pos[0] if pos.size() > 0 else "brands_hatch"
	var cars := int(pos[1]) if pos.size() > 1 else 25
	var secs := float(pos[2]) if pos.size() > 2 else 30.0
	var s := RaceSettings.new()
	s.seed = 3
	s.track_id = track
	s.laps = 3
	s.ai_count = cars - 1
	s.damage_enabled = true
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.environment = {"time_h": 15.0, "weather": "dry"}
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": "bmw_m4_gt3"}], GameData.cars, GameData.drivers)
	var session := RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	var me := AIDriver.for_car(session.sim, 0)
	var sim := session.sim
	var bucket := {}
	var t_ai := 0.0
	var t_step := 0.0
	var t_tel := 0.0
	var n := 0
	var win := 0.0
	var win_ai := 0.0
	var win_n := 0
	while sim.race_time < secs:
		var t0 := Time.get_ticks_usec()
		var inp := me.get_input(sim, 0)
		for i in session.ai:
			session.inputs[i] = session.ai[i].get_input(sim, i)
		var t1 := Time.get_ticks_usec()
		session.inputs[0] = inp
		sim.step(session.inputs)
		var t2 := Time.get_ticks_usec()
		session.telemetry.observe(sim)
		session.telemetry.on_events(sim.events)
		var t3 := Time.get_ticks_usec()
		if sim.phase == RaceSim.Phase.RACING:
			t_ai += (t1 - t0) / 1000.0
			t_step += (t2 - t1) / 1000.0
			t_tel += (t3 - t2) / 1000.0
			n += 1
			win += (t3 - t0) / 1000.0
			win_ai += (t1 - t0) / 1000.0
			win_n += 1
			if win_n == 120:
				print("[sim] t=%5.1f s: %.2f ms/tick (ai %.2f)" % [sim.race_time, win / win_n, win_ai / win_n])
				win = 0.0; win_ai = 0.0; win_n = 0
	print("[sim] %s %d cars, %d ticks: ai %.2f ms, sim.step %.2f ms, telemetry %.2f ms per tick" % [track, cars, n, t_ai / n, t_step / n, t_tel / n])
	var h := PackedFloat64Array()
	for c in sim.cars:
		h.append_array([c.pos.x, c.pos.y, c.vel.x, c.vel.y, c.heading])
	print("[sim] state hash after %.1f s: %d" % [sim.race_time, hash(h)])
	get_tree().quit()
