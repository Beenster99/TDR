extends SceneTree
## Gravel probe: how hard a gravel trap is to get out of, and how much it
## costs to run through one.
##  * escape: a car stopped in the middle of a gravel trap (after a crash),
##    pointing back at the track at 45 degrees, full throttle. Time to get
##    back on the tarmac (or "stuck").
##  * through: a car runs into the gravel at 40 m/s off the throttle. Speed
##    after 1 and 2 s and how far it slides before it stops.
##   godot --headless --path . --script res://tests/gravel_probe.gd -- [track] [car]

const DT := 1.0 / 240.0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var track_id: String = args[0] if args.size() > 0 else "monza"
	var car_ids: Array = [args[1]] if args.size() > 1 else ["bmw_m4_gt3", "porsche_963", "oreca_07_gibson", "i4_light_roadster"]
	var track := TrackCatalog.load_track(track_id)
	var cars := CarCatalog.load_all()
	var tyres := TyreCatalog.load_all()
	var spot := _gravel_spot(track)
	if spot.is_empty():
		print("no gravel on ", track_id)
		quit()
		return
	print("%s: gravel at s=%.0f m, %s side" % [track_id, spot["s"], "right" if spot["side"] > 0 else "left"])
	for id in car_ids:
		if not cars.has(id):
			continue
		var d: CarDefinition = cars[id]
		var tc: TyreCompound = tyres[d.tyre_compound_id]
		for tcs in [true, false]:
			var r := _escape(track, d, tc, spot, tcs)
			print("  %-22s escape (TC %s): %s" % [id, "on " if tcs else "off", r])
		print("  %-22s through at 40 m/s: %s" % [id, _through(track, d, tc, spot)])
	quit()


## Middle of the longest gravel trap.
func _gravel_spot(track: TrackData) -> Dictionary:
	var best := {}
	var best_run := 0
	for side in [1.0, -1.0]:
		var arr := track.runoff_right if side > 0 else track.runoff_left
		if arr.size() != track.point_count():
			continue
		var run := 0
		for i in arr.size():
			if arr[i] == TrackData.Surface.GRAVEL:
				run += 1
				if run > best_run:
					best_run = run
					best = {"idx": i - run / 2, "side": side}
			else:
				run = 0
	if best.is_empty():
		return {}
	var i: int = best["idx"]
	best["s"] = track.cum_s[i]
	var w: float = track.width_right[i] if best["side"] > 0 else track.width_left[i]
	best["edge"] = w + track.kerb_width
	return best


func _car(track: TrackData, spot: Dictionary, off: float, heading: float, speed: float, tcs: bool) -> CarState:
	var s := CarState.new()
	s.pos = track.position_at(spot["s"], spot["side"] * off)
	s.heading = heading
	s.vel = Vector2.from_angle(heading) * speed
	s.tyre_temp = PackedFloat64Array([80.0, 80.0, 80.0, 80.0])
	s.assist_tc = tcs
	s.assist_abs = true
	s.track_idx = spot["idx"]
	return s


func _escape(track: TrackData, d: CarDefinition, tc: TyreCompound, spot: Dictionary, tcs: bool) -> String:
	var env := SimEnvironment.new()
	env.bind_track(track)
	var along := track.heading_at(spot["s"])
	# Pointing 45 degrees back towards the track.
	var heading: float = along - spot["side"] * PI * 0.25
	var s := _car(track, spot, spot["edge"] + track.runoff * 0.5, heading, 0.0, tcs)
	var events := []
	var t := 0.0
	var in_gravel := 0.0
	while t < 30.0:
		var inp := CarInput.new()
		inp.throttle = 1.0
		# Straighten up once close to the track.
		var q := track.project(s.pos, s.track_idx)
		var off_edge: float = absf(q["offset"]) - spot["edge"]
		if off_edge < 4.0:
			inp.steer = clampf(wrapf(along - s.heading, -PI, PI) * 2.0, -1.0, 1.0)
		CarPhysics.step(s, inp, d, tc, env, track, DT, 0.0, events, 0)
		t += DT
		if OS.get_environment("TDR_DEBUG") != "" and fmod(t, 0.5) < DT:
			print("    t %.1f vx %.2f vy %.2f yaw %.2f gear %d rpm %.0f surf %d spin %s slope %s ax %.2f" % [t, s.vel.dot(s.forward()), s.vel.dot(s.right()), s.yaw_rate, s.gear, s.rpm, s.surface, s.wheelspin, track.surface_gradient(q), s.ax])
		if s.surface == TrackData.Surface.GRAVEL:
			in_gravel = t
		if s.surface == TrackData.Surface.TRACK or s.surface == TrackData.Surface.KERB:
			return "back on track in %.1f s at %.0f km/h (out of the gravel after %.1f s)" % [t, s.speed() * 3.6, in_gravel]
	return "STUCK: %.1f m/s after 30 s" % s.speed()


func _through(track: TrackData, d: CarDefinition, tc: TyreCompound, spot: Dictionary) -> String:
	var env := SimEnvironment.new()
	env.bind_track(track)
	var along := track.heading_at(spot["s"])
	var s := _car(track, spot, spot["edge"] + track.runoff * 0.5, along, 40.0, true)
	var events := []
	var t := 0.0
	var start := s.pos
	var v1 := 0.0
	var v2 := 0.0
	while t < 15.0 and s.speed() > 1.0:
		var inp := CarInput.new()
		CarPhysics.step(s, inp, d, tc, env, track, DT, 0.0, events, 0)
		t += DT
		if v1 == 0.0 and t >= 1.0:
			v1 = s.speed()
		if v2 == 0.0 and t >= 2.0:
			v2 = s.speed()
	return "%.0f km/h after 1 s, %.0f after 2 s, stops in %.0f m / %.1f s" % [v1 * 3.6, v2 * 3.6, start.distance_to(s.pos), t]
