extends SceneTree
## Handling probe: drives each car through manoeuvres a new player does
## (floor it, yank the stick, lift mid-corner, brake while turning) and
## reports whether it spins. godot --headless --path . --script res://tests/handling_probe.gd

const DT := 1.0 / 240.0
var track: TrackData
var tyres: Dictionary
var env := SimEnvironment.new()


func _init() -> void:
	var cl := []
	var R := 3000.0
	for k in 720:
		var a := TAU * k / 720.0
		cl.append([cos(a) * R, sin(a) * R, 400.0, 400.0])
	track = TrackData.from_dict({"id": "probe", "centerline": cl, "runoff_m": 50.0})
	tyres = TyreCatalog.load_all()
	assisted = not "--raw" in OS.get_cmdline_user_args()
	var cars := CarCatalog.load_all()
	var ids: Array = cars.keys()
	ids.sort()
	var total := 0
	for id in ids:
		var d: CarDefinition = cars[id]
		var tc: TyreCompound = tyres[d.tyre_compound_id]
		var r := []
		r.append(_run(d, tc, 0.0, "launch", func(t, v): return [0.0, 1.0, 0.0]))
		r.append(_run(d, tc, 15.0, "floor it turning", func(t, v): return [1.0, 1.0, 0.0]))
		for v0 in [25.0, 45.0]:
			r.append(_run(d, tc, v0, "full lock %d" % v0, func(t, v): return [1.0 if t > 0.3 else 0.0, 0.6, 0.0]))
			r.append(_run(d, tc, v0, "flick %d" % v0, func(t, v): return [1.0 if t < 0.6 else (-1.0 if t < 1.2 else 0.0), 0.5, 0.0]))
			r.append(_run(d, tc, v0, "lift mid-turn %d" % v0, func(t, v): return [0.7, 1.0 if t < 1.0 else 0.0, 0.0]))
			r.append(_run(d, tc, v0, "brake turning %d" % v0, func(t, v): return [0.8, 0.0, 1.0 if t > 0.5 else 0.0]))
		var spins := 0
		for x in r:
			if x[1]:
				spins += 1
		total += spins
		print("%-20s spins %d/%d" % [id, spins, r.size()])
		for x in r:
			print("    %-20s %s  max drift %4.0f deg  turned %4.0f deg" % [x[0], "SPIN" if x[1] else "ok  ", x[2], x[3]])
	print("TOTAL SPINS %d" % total)
	quit()


## Pad-style input through LocalInput's steering lock, cold tyres like a race start.
var assisted := true

func _run(d: CarDefinition, tc: TyreCompound, v0: float, name: String, ctl: Callable) -> Array:
	var s := CarState.new()
	s.pos = Vector2(3000, 0)
	s.heading = PI * 0.5
	s.vel = Vector2.from_angle(s.heading) * v0
	var t0 := lerpf(env.ambient_c, env.track_c, 0.4)
	s.tyre_temp = PackedFloat64Array([t0, t0, t0, t0])
	s.fuel_l = 40.0
	s.gear = 1
	s.assist_stability = assisted
	var q := track.project(s.pos)
	s.track_idx = q["idx"]
	var max_drift := 0.0
	var h0 := s.heading
	var turned := 0.0
	var spun := false
	var t := 0.0
	var ev := []
	while t < 4.0:
		var c: Array = ctl.call(t, s.speed())
		var inp := CarInput.new()
		var lock := clampf(1.0 / (1.0 + s.speed() / 28.0), 0.3, 1.0)
		inp.steer = c[0] * lock
		inp.throttle = c[1]
		inp.brake = c[2]
		var prev := s.heading
		CarPhysics.step(s, inp, d, tc, env, track, DT, 0.0, ev, 0)
		turned += absf(wrapf(s.heading - prev, -PI, PI))
		if s.speed() > 4.0:
			var drift := absf(rad_to_deg(wrapf(s.vel.angle() - s.heading, -PI, PI)))
			max_drift = maxf(max_drift, drift)
			if drift > 35.0:
				spun = true
		t += DT
	return [name, spun, max_drift, rad_to_deg(turned)]
