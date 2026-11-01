class_name RaceSim
extends RefCounted
## The authoritative race simulation. Owns every car's state and the race
## state machine. Advances only through step(inputs), one fixed tick at a
## time, and never reads the clock, Input, or scene tree. That makes it:
##  * runnable headless on a dedicated server,
##  * replayable (same settings + seed + input stream => same result),
##  * snapshot-able for late join / client correction (snapshot()/apply_snapshot()).

enum Phase { COUNTDOWN, RACING, CHEQUERED, FINISHED }

const TICK_RATE := 60
const SUBSTEPS := 4
const TICK_DT := 1.0 / TICK_RATE

var settings: RaceSettings
var track: TrackData
var env: SimEnvironment
var defs: Array[CarDefinition] = []
var compounds: Array[TyreCompound] = []
var cars: Array[CarState] = []
var entries: Array[RaceEntry] = []

var tick: int = 0
var phase: int = Phase.COUNTDOWN
var phase_time: float = 0.0
var race_time: float = 0.0
var leader_finish_time: float = -1.0
var finish_order: Array[int] = []
var running_order: Array[int] = []
## Multiplayer (owner-simulated cars, as in Torque Shed): cars simulated on
## another machine are "external". Their state is written in from the network
## before each step; physics skips them and collisions only push our own cars.
var external: PackedByteArray = []
## A follower (multiplayer client) never decides race state itself: phase
## changes, laps and positions come from the host via apply_race_state().
var follower := false
## Events raised during the most recent step (HUD, audio, replication, and
## later damage / safety car logic all consume these).
var events: Array = []


## entries: RaceEntry per car, in grid order (index 0 = pole).
## car_defs: id -> CarDefinition, tyre_defs: id -> TyreCompound
func _init(p_settings: RaceSettings, p_track: TrackData, p_entries: Array[RaceEntry],
		car_defs: Dictionary, tyre_defs: Dictionary) -> void:
	settings = p_settings
	track = p_track
	var env_dict := track.default_environment.duplicate()
	env_dict.merge(settings.environment, true)
	env = SimEnvironment.from_dict(env_dict)
	entries = p_entries
	for i in entries.size():
		var e := entries[i]
		var base: CarDefinition = car_defs[e.car_id]
		var def := base.with_overrides(e.setup) if not e.setup.is_empty() else base
		defs.append(def)
		compounds.append(tyre_defs.get(def.tyre_compound_id, tyre_defs.values()[0]))
		cars.append(_make_car_on_grid(i, def))
		running_order.append(i)
		external.append(0)
	_update_positions()


func _make_car_on_grid(slot: int, def: CarDefinition) -> CarState:
	var c := CarState.new()
	var g := track.grid_slot(slot)
	c.pos = g["pos"]
	c.heading = g["heading"]
	c.gear = 1
	c.rpm = def.idle_rpm
	c.fuel_l = def.fuel_capacity_l if settings.start_fuel_l < 0.0 else minf(settings.start_fuel_l, def.fuel_capacity_l)
	# Tyres start between air and track temperature (no blankets).
	var t0 := lerpf(env.ambient_c, env.track_c, 0.4)
	c.tyre_temp = PackedFloat64Array([t0, t0, t0, t0])
	var q := track.project(c.pos)
	c.track_idx = q["idx"]
	c.track_s = q["s"]
	entries[slot].distance = c.track_s - track.length
	return c


func car_count() -> int:
	return cars.size()


## Advance one tick. inputs[i] drives cars[i]; missing/null = neutral.
func step(inputs: Array) -> void:
	events.clear()
	tick += 1
	phase_time += TICK_DT
	env.update(TICK_DT)

	if phase == Phase.COUNTDOWN and follower:
		_hold_cars_on_grid(inputs)
		return
	if phase == Phase.COUNTDOWN:
		var prev_light := int(ceil(settings.countdown_s - (phase_time - TICK_DT)))
		var light := int(ceil(settings.countdown_s - phase_time))
		if light != prev_light and light > 0:
			events.append({"type": "countdown", "value": light})
		if phase_time >= settings.countdown_s:
			phase = Phase.RACING
			phase_time = 0.0
			events.append({"type": "green"})
		else:
			_hold_cars_on_grid(inputs)
			return

	if phase != Phase.FINISHED:
		race_time += TICK_DT

	var sub_dt := TICK_DT / SUBSTEPS
	var fuel_rate := settings.fuel_rate if settings.fuel_enabled else 0.0
	var prev_s := PackedFloat64Array()
	for c in cars:
		prev_s.append(c.track_s)
	for i in cars.size():
		if external[i]:
			_refresh_track_position(cars[i])
	for _sub in SUBSTEPS:
		for i in cars.size():
			if external[i]:
				continue
			var inp: CarInput = inputs[i] if i < inputs.size() and inputs[i] != null else CarInput.neutral()
			CarPhysics.step(cars[i], inp, defs[i], compounds[i], env, track, sub_dt, fuel_rate, events, i)
		_resolve_collisions()

	if follower:
		return
	for i in cars.size():
		_update_progress(i, prev_s[i])
	_update_positions()
	_check_race_end()


func _refresh_track_position(c: CarState) -> void:
	var q := track.project(c.pos, c.track_idx)
	c.track_idx = q["idx"]
	c.track_s = q["s"]
	c.lateral_offset = q["offset"]
	c.surface = track.surface_for(q)


func _hold_cars_on_grid(inputs: Array) -> void:
	# Engines can rev on the grid, but nothing moves before the green light.
	for i in cars.size():
		var c := cars[i]
		var inp: CarInput = inputs[i] if i < inputs.size() and inputs[i] != null else CarInput.neutral()
		c.rpm = lerpf(c.rpm, lerpf(defs[i].idle_rpm, defs[i].redline_rpm * 0.8, inp.throttle), 0.2)


func _update_progress(i: int, prev_s: float) -> void:
	var c := cars[i]
	var e := entries[i]
	var L := track.length
	var ds := c.track_s - prev_s
	var crossed_forward := false
	if ds < -L * 0.5:
		ds += L
		crossed_forward = true
	elif ds > L * 0.5:
		ds -= L  # reversed over the line
		e.next_sector = 0  # invalidate this lap's sector sequence
	e.distance += ds
	if e.finished or e.dnf:
		return

	# Sector boundaries (excluding the line itself, which is sector 0).
	while e.next_sector >= 1 and e.next_sector < track.sectors.size():
		var boundary := track.sectors[e.next_sector] * L
		if prev_s < boundary and c.track_s >= boundary and not crossed_forward:
			e.sector_times.append(race_time - e.sector_start_time)
			e.sector_start_time = race_time
			e.next_sector += 1
		else:
			break

	if not crossed_forward:
		return
	var t_cross := race_time - TICK_DT * clampf(c.track_s / maxf(ds, 0.001), 0.0, 1.0)
	if not e.started_lap:
		e.started_lap = true
		e.lap_start_time = 0.0  # lap 1 is timed from the green light
		e.sector_start_time = 0.0
		e.next_sector = 1
		return
	if e.next_sector != track.sectors.size():
		# Missed a sector (cut / reversed): not a lap. Restart sector sequence.
		e.next_sector = 1
		e.sector_times = PackedFloat64Array()
		e.sector_start_time = t_cross
		return
	var lap_time := t_cross - e.lap_start_time
	e.sector_times.append(t_cross - e.sector_start_time)
	e.last_sector_times = e.sector_times
	e.sector_times = PackedFloat64Array()
	e.sector_start_time = t_cross
	e.next_sector = 1
	e.lap_times.append(lap_time)
	e.laps_done += 1
	if e.best_lap <= 0.0 or lap_time < e.best_lap:
		e.best_lap = lap_time
	e.lap_start_time = t_cross
	events.append({"type": "lap", "car": i, "lap": e.laps_done, "time": lap_time})
	if e.laps_done >= settings.laps or phase == Phase.CHEQUERED:
		e.finished = true
		e.finish_time = t_cross
		finish_order.append(i)
		events.append({"type": "finished", "car": i, "position": finish_order.size(), "time": t_cross})
		if phase == Phase.RACING:
			phase = Phase.CHEQUERED
			leader_finish_time = t_cross
			events.append({"type": "chequered", "car": i})


func _update_positions() -> void:
	var order: Array[int] = []
	for i in cars.size():
		order.append(i)
	order.sort_custom(func(x: int, y: int) -> bool:
		var ex := entries[x]
		var ey := entries[y]
		if ex.finished != ey.finished:
			return ex.finished
		if ex.finished:
			return finish_order.find(x) < finish_order.find(y)
		if ex.dnf != ey.dnf:
			return ey.dnf
		if ex.distance != ey.distance:
			return ex.distance > ey.distance
		return x < y)
	running_order = order
	for p in order.size():
		entries[order[p]].position = p + 1


func _check_race_end() -> void:
	if phase != Phase.CHEQUERED:
		return
	var all_done := true
	for e in entries:
		if not e.finished and not e.dnf:
			all_done = false
	if not all_done and race_time - leader_finish_time > settings.finish_timeout_s:
		for e in entries:
			if not e.finished:
				e.dnf = true
		all_done = true
	if all_done:
		phase = Phase.FINISHED
		_update_positions()
		events.append({"type": "race_finished"})


# --- Car-to-car contact (capsule vs capsule, impulse based) ----------------

func _resolve_collisions() -> void:
	var n := cars.size()
	for i in n:
		for j in range(i + 1, n):
			_collide_pair(i, j)


func _collide_pair(i: int, j: int) -> void:
	if external[i] and external[j]:
		return  # both simulated elsewhere: their owners resolve it
	var a := cars[i]
	var b := cars[j]
	var da := defs[i]
	var db := defs[j]
	var reach := (da.length + db.length) * 0.5
	if a.pos.distance_squared_to(b.pos) > reach * reach:
		return
	var ra := da.width * 0.5
	var rb := db.width * 0.5
	var ha := da.length * 0.5 - ra
	var hb := db.length * 0.5 - rb
	var fa := a.forward()
	var fb := b.forward()
	var cp := _closest_points(a.pos - fa * ha, a.pos + fa * ha, b.pos - fb * hb, b.pos + fb * hb)
	var pa: Vector2 = cp[0]
	var pb: Vector2 = cp[1]
	var delta := pb - pa
	var dist := delta.length()
	var min_dist := ra + rb
	if dist >= min_dist:
		return
	var nrm := delta / dist if dist > 0.0001 else (b.pos - a.pos).normalized()
	if nrm == Vector2.ZERO:
		nrm = Vector2.RIGHT
	var ma := da.mass + a.fuel_l * CarPhysics.FUEL_DENSITY
	var mb := db.mass + b.fuel_l * CarPhysics.FUEL_DENSITY
	var pen := min_dist - dist
	# Only cars simulated here move; a remote car acts like a solid wall here
	# and its owner applies the matching push on their side.
	var share_a := 0.0 if external[i] else (1.0 if external[j] else mb / (ma + mb))
	var share_b := 0.0 if external[j] else (1.0 if external[i] else ma / (ma + mb))
	a.pos -= nrm * pen * share_a
	b.pos += nrm * pen * share_b
	# Contact point halfway between surfaces.
	var contact := pa + nrm * ra
	var r_a := contact - a.pos
	var r_b := contact - b.pos
	var va := a.vel + a.yaw_rate * Vector2(-r_a.y, r_a.x)
	var vb := b.vel + b.yaw_rate * Vector2(-r_b.y, r_b.x)
	var vn := (vb - va).dot(nrm)
	if vn >= 0.0:
		return
	var restitution := 0.25
	var cra := r_a.cross(nrm)
	var crb := r_b.cross(nrm)
	var denom := 1.0 / ma + 1.0 / mb + cra * cra / da.inertia + crb * crb / db.inertia
	var jmag := -(1.0 + restitution) * vn / denom
	var imp := nrm * jmag
	if not external[i]:
		a.vel -= imp / ma
		a.yaw_rate -= r_a.cross(imp) / da.inertia
	if not external[j]:
		b.vel += imp / mb
		b.yaw_rate += r_b.cross(imp) / db.inertia
	if jmag > 500.0:
		events.append({"type": "collision", "a": i, "b": j, "impulse": jmag, "pos": contact})


static func _closest_points(p1: Vector2, q1: Vector2, p2: Vector2, q2: Vector2) -> Array:
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-6 and e <= 1e-6:
		return [p1, p2]
	if a <= 1e-6:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)
		if e <= 1e-6:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var denom := a * e - b * b
			s = clampf((b * f - c * e) / denom, 0.0, 1.0) if denom != 0.0 else 0.0
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	return [p1 + d1 * s, p2 + d2 * t]


# --- Snapshots (server -> client state, late join, replays) ----------------

func snapshot() -> Dictionary:
	var car_data := []
	for c in cars:
		car_data.append(c.serialize())
	var entry_data := []
	for e in entries:
		entry_data.append(e.to_dict())
	return {
		"tick": tick, "phase": phase, "phase_time": phase_time, "race_time": race_time,
		"leader_finish_time": leader_finish_time, "finish_order": finish_order.duplicate(),
		"env": env.to_dict(), "cars": car_data, "entries": entry_data,
	}


func apply_snapshot(snap: Dictionary) -> void:
	tick = snap["tick"]
	phase = snap["phase"]
	phase_time = snap["phase_time"]
	race_time = snap["race_time"]
	leader_finish_time = snap["leader_finish_time"]
	finish_order.assign(snap["finish_order"])
	env = SimEnvironment.from_dict(snap["env"])
	for i in cars.size():
		cars[i].deserialize(snap["cars"][i])
		entries[i].from_dict(snap["entries"][i])
	_update_positions()


## Race-only state (no car physics): what the host sends clients in
## multiplayer, since every car's physics comes from its own owner.
func race_state() -> Dictionary:
	var entry_data := []
	for e in entries:
		entry_data.append(e.to_dict())
	return {"tick": tick, "phase": phase, "phase_time": phase_time, "race_time": race_time,
		"leader_finish_time": leader_finish_time, "finish_order": finish_order.duplicate(),
		"env": env.to_dict(), "entries": entry_data}


func apply_race_state(st: Dictionary) -> void:
	phase = st["phase"]
	phase_time = st["phase_time"]
	race_time = st["race_time"]
	leader_finish_time = st["leader_finish_time"]
	finish_order.assign(st["finish_order"])
	env = SimEnvironment.from_dict(st["env"])
	for i in mini(entries.size(), st["entries"].size()):
		entries[i].from_dict(st["entries"][i])
	_update_positions()


func state_hash() -> String:
	return var_to_bytes(snapshot()).hex_encode().md5_text()
