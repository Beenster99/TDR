extends SceneTree
## Track assist probe: a clumsy keyboard "player" (digital steering with a
## reaction delay, like a new player tapping A / D) laps a real track with
## the track assist off, light and strong. Reports time off the track, the
## lap time and how far it wanders from the line on the straights.
##   godot --headless --path . --script res://tests/track_assist_probe.gd -- [track] [car] [laps]

const DT := 1.0 / 60.0
const SUB := 4
const REACTION := 0.18          ## s between seeing and pressing
var KEYBOARD := OS.get_environment("TDR_KEYS") != ""
var STICK_GAIN := float(OS.get_environment("TDR_GAIN")) if OS.get_environment("TDR_GAIN") != "" else 4.0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var track_id: String = args[0] if args.size() > 0 else "spielberg"
	var car_id: String = args[1] if args.size() > 1 else "bmw_m4_gt3"
	var laps := int(args[2]) if args.size() > 2 else 2
	var track := TrackCatalog.load_track(track_id)
	var cars := CarCatalog.load_all()
	var tyres := TyreCatalog.load_all()
	var d: CarDefinition = cars[car_id]
	var tc: TyreCompound = tyres[d.tyre_compound_id]
	var line := DrivingLine.build(track, d, tc)
	print("%s, %s: %d braking zones" % [track_id, car_id, line.zones.size()])
	for lvl in [0, 1, 2]:
		var r := _run(track, d, tc, line, lvl, laps)
		print("track assist %d: off track %5.1f s, wall hits %d, %d laps in %6.1f s, straight wander %.2f m" % [lvl, r[0], r[1], laps, r[2], r[3]])
	quit()


func _run(track: TrackData, d: CarDefinition, tc: TyreCompound, line: DrivingLine, lvl: int, laps: int) -> Array:
	var env := SimEnvironment.new()
	env.bind_track(track)
	var s := CarState.new()
	var slot := track.grid_slot(0)
	s.pos = slot["pos"]
	s.heading = slot["heading"]
	s.tyre_temp = PackedFloat64Array([70.0, 70.0, 70.0, 70.0])
	s.assist_tc = true
	s.assist_abs = true
	s.assist_stability = true
	s.assist_track = lvl
	var steer := 0.0
	var pending: Array = []      # [time, key] presses waiting out the reaction delay
	var key := 0.0
	var off_t := 0.0
	var hits := 0
	var t := 0.0
	var dist := 0.0
	var prev_s := s.track_s
	var wander := 0.0
	var wander_n := 0
	var hint := -1
	var events := []
	while dist < track.length * laps and t < 400.0 * laps:
		hint = line.locate(s.pos, hint)
		var speed := s.speed()
		# Aim at the line 12 m + 0.5 s ahead; decide a key now, press it later.
		var ahead := (hint + int((15.0 + speed * 0.9) / DrivingLine.SPACING)) % line.size()
		var to := line.points[ahead] - s.pos
		# Where the car is heading vs where the line goes (angle), plus the
		# drift sideways: tap a key while it's off by more than a little.
		var ang := s.vel.angle_to(to) if speed > 3.0 else s.forward().angle_to(to)
		var ly := ang * 10.0
		var want := 0.0
		if KEYBOARD:
			want = 1.0 if ang > 0.025 else (-1.0 if ang < -0.025 else 0.0)
		else:
			want = clampf(ang * STICK_GAIN, -1.0, 1.0)
		pending.append([t + REACTION, want])
		while not pending.is_empty() and pending[0][0] <= t:
			key = pending.pop_front()[1]
		if KEYBOARD:
			steer = LocalInput.key_steer(steer, key, speed, DT)
		else:
			steer = move_toward(steer, signf(key) * pow(absf(key), 1.6), LocalInput.PAD_STEER_RATE * DT)
		var inp := CarInput.new()
		inp.steer = steer * LocalInput.steer_lock(speed)
		# Pedals: brake where the line says (a bit late, like a player).
		var look := (hint + int(speed * 0.35 / DrivingLine.SPACING) + 1) % line.size()
		var v_ok := line.speed[look] * 0.97
		if speed > v_ok + 1.0:
			inp.brake = 1.0
		else:
			inp.throttle = 1.0
		events.clear()
		for _k in SUB:
			CarPhysics.step(s, inp.quantized(), d, tc, env, track, DT / SUB, 0.0, events, 0)
		for e in events:
			if e["type"] == "barrier_impact":
				hits += 1
		if s.surface >= TrackData.Surface.GRASS and s.surface != TrackData.Surface.RUNOFF:
			off_t += DT
		var ds := s.track_s - prev_s
		if ds < -track.length * 0.5:
			ds += track.length
		elif ds > track.length * 0.5:
			ds -= track.length
		dist += ds
		prev_s = s.track_s
		if absf(line.curv[hint]) < 0.002 and speed > 30.0:
			wander += absf((s.pos - line.points[hint]).dot(Vector2(-(line.points[(hint + 1) % line.size()] - line.points[hint]).normalized().y,
				(line.points[(hint + 1) % line.size()] - line.points[hint]).normalized().x)))
			wander_n += 1
		t += DT
		if OS.get_environment("TDR_TRACE") != "" and int(t * 60) % 60 == 0:
			print("  t=%5.1f v=%5.1f surf=%d s=%6.0f off=%5.1f ly=%5.1f steer=%.2f thr=%.1f brk=%.1f line_v=%.1f gear=%d rpm=%d yaw=%.3f beta=%.3f" % [t, speed, s.surface, s.track_s, s.lateral_offset, ly, inp.steer, inp.throttle, inp.brake, line.speed[look], s.gear, s.rpm, s.yaw_rate, s.vel.angle_to(s.forward())])
	return [off_t, hits, t, wander / maxf(wander_n, 1)]
