extends SceneTree
## Straight-line and cornering numbers per car, to compare classes:
##   godot --headless --path . --script res://tests/class_probe.gd
## Prints 0-200 km/h, top speed (60 s flat out), braking 250-100 km/h, and the
## steady lateral grip at 120 and 220 km/h.

const DT := 1.0 / 240.0
var track: TrackData
var env := SimEnvironment.new()


func _init() -> void:
	var cl := []
	var R := 6000.0
	for k in 1440:
		var a := TAU * k / 1440.0
		cl.append([cos(a) * R, sin(a) * R, 400.0, 400.0])
	track = TrackData.from_dict({"id": "probe", "centerline": cl, "runoff_m": 50.0})
	var tyres := TyreCatalog.load_all()
	var cars := CarCatalog.load_all()
	var ids: Array = []
	for cls in CarCatalog.classes(cars):
		ids.append_array(CarCatalog.ids_in_class(cars, cls))
	print("%-28s %-8s %7s %7s %8s %6s %6s" % ["car", "class", "0-200", "top", "250-100", "g@120", "g@220"])
	for id in ids:
		var d: CarDefinition = cars[id]
		var tc: TyreCompound = tyres[d.tyre_compound_id]
		var s := _state(0.0)
		var t := 0.0
		var t200 := -1.0
		var top := 0.0
		while t < 60.0:
			_step(s, d, tc, 0.0, 1.0, 0.0)
			t += DT
			if t200 < 0.0 and s.speed() * 3.6 >= 200.0:
				t200 = t
			top = maxf(top, s.speed() * 3.6)
		s = _state(250.0 / 3.6)
		t = 0.0
		var dist := 0.0
		while s.speed() > 100.0 / 3.6 and t < 20.0:
			_step(s, d, tc, 0.0, 0.0, 1.0)
			dist += s.speed() * DT
			t += DT
		print("%-28s %-8s %6.2fs %4.0fkmh %6.0f m %5.2fg %5.2fg" % [d.display_name, d.class_tag, t200, top, dist, _lat(d, tc, 120.0), _lat(d, tc, 220.0)])
	quit()


func _state(v: float) -> CarState:
	var s := CarState.new()
	s.pos = Vector2(6000, 0)
	s.heading = PI * 0.5
	s.vel = Vector2.from_angle(s.heading) * v
	s.tyre_temp = PackedFloat64Array([90.0, 90.0, 90.0, 90.0])
	s.fuel_l = 40.0
	s.gear = 1
	var q := track.project(s.pos)
	s.track_idx = q["idx"]
	return s


func _step(s: CarState, d: CarDefinition, tc: TyreCompound, steer: float, thr: float, brk: float) -> void:
	var inp := CarInput.new()
	inp.steer = steer
	inp.throttle = thr
	inp.brake = brk
	CarPhysics.step(s, inp, d, tc, env, track, DT, 0.0, [], 0)


## Highest steady lateral acceleration holding a speed: ramp steering until the car slides.
func _lat(d: CarDefinition, tc: TyreCompound, kmh: float) -> float:
	var best := 0.0
	for k in range(1, 30):
		var s := _state(kmh / 3.6)
		s.gear = 4
		var steer := k * 0.012
		var sum := 0.0
		var n := 0
		for i in 720:
			s.vel = s.vel.normalized() * kmh / 3.6
			_step(s, d, tc, steer, 0.35, 0.0)
			if i > 480:
				sum += absf(s.ay)
				n += 1
		var drift := absf(rad_to_deg(wrapf(s.vel.angle() - s.heading, -PI, PI)))
		if drift < 12.0:
			best = maxf(best, sum / maxf(n, 1) / 9.81)
	return best
