extends SceneTree
## Checks the baked sounds load and loop, prints each car's engine voice, and
## drives every car's CarAudio through launch, upshifts, the limiter, lift-off,
## kerbs and gravel.  godot --headless --path . --script res://tests/audio_probe.gd


var _done := false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return false


func _run() -> void:
	var ok := true
	for fam in SoundBank.FAMILIES:
		var bands := SoundBank.engine_bands(fam)
		if bands.is_empty():
			print("FAIL no bands for ", fam)
			ok = false
			continue
		for b in bands:
			for on in [true, false]:
				var s = SoundBank.engine_loop(fam, on, int(b[0]))
				if not (s is AudioStreamWAV) or (s as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_DISABLED:
					print("FAIL not a loop: ", fam, " ", b)
					ok = false
	for n in ["tyre_squeal", "tyre_scrub", "tyre_lock", "road_roar", "kerb", "gravel", "grass", "wind",
			"spray", "turbo_whistle", "supercharger", "hybrid_whine", "gear_whine", "pop_1", "crackle", "shift", "flutter"]:
		if SoundBank.get_sound(n) == null:
			print("FAIL missing ", n)
			ok = false
	var w := SoundBank.engine_loop("v8_cross_na", true, 3000) as AudioStreamWAV
	print("v8 3000 loop mode ", w.loop_mode, " end ", w.loop_end, " length ", w.get_length())
	var cars := CarCatalog.load_all()
	cars["safety"] = CarCatalog.load_safety_car()
	for id in cars:
		var d: CarDefinition = cars[id]
		var p := CarAudio.engine_profile(d)
		print("%-32s %-15s turbo=%s sc=%s hybrid=%s whine=%s redline=%d" % [id, p["family"], p["turbo"], p["supercharged"], p["hybrid"], p["gear_whine"], d.redline_rpm])
		var st := CarState.new()
		var ca := CarAudio.new()
		root.add_child(ca)
		ca.setup(d, st, true)
		var dt := 1.0 / 60.0
		for f in 600:
			var t := f * dt
			st.gear = 1 + int(t / 2.0) % 6
			st.rpm = lerpf(d.idle_rpm, d.redline_rpm * 1.001, fmod(t, 2.0) / 2.0)
			st.vel = Vector2(t * 6.0, 0)
			st.surface = [0, 1, 4, 2, 0][int(t) % 5]
			st.slip_angle_rear = 0.12 if int(t) % 3 == 0 else 0.0
			st.ax = -15.0 if f % 200 > 180 else 4.0
			ca.set_listener(Vector2(10, 10), Vector2.ZERO)
			ca.update(dt, 0.0 if f % 100 > 90 else 1.0, 1.0)
		ca.free()
	print("AUDIO PROBE ", "OK" if ok else "FAILED")
	quit(0 if ok else 1)
