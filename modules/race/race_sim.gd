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
## Every tyre compound by id (pit stops fit new ones), and each car's own dry compound.
var tyre_defs: Dictionary = {}
var dry_compound: Array[String] = []
## Pit lane, pit stops, fuel strategy rules, mandatory stops (PitRules).
var pits: PitRules

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
## CarDamage.Level for this race (from settings.damage_level).
var damage_level: int = CarDamage.Level.OFF
## Hits at or above this delta-v (m/s) are reported as incidents (the
## safety car / race control listens), whatever the damage level.
const INCIDENT_DV := 5.0
const INCIDENT_COOLDOWN_S := 1.0
var _incident_cooldown := PackedFloat64Array()
## Damage last seen per car [body total, punctures bitmask, engine failed,
## gearbox failed], to report what changed on cars simulated elsewhere.
var _seen_damage: Array = []
## Events posted from outside the sim between steps (AI radio calls and
## strategy lines, later pit-wall commands). They join `events` at the start
## of the next step, so they are replicated like every other event.
var _posted: Array = []


## entries: RaceEntry per car, in grid order (index 0 = pole).
## car_defs: id -> CarDefinition, tyre_defs: id -> TyreCompound
func _init(p_settings: RaceSettings, p_track: TrackData, p_entries: Array[RaceEntry],
		car_defs: Dictionary, tyre_defs: Dictionary) -> void:
	settings = p_settings
	track = p_track
	var track_env := track.default_environment.duplicate()
	var climate = track.get("climate")  # tracks 1.1+ keep it beside default_environment
	if climate is Dictionary and not climate.is_empty():
		track_env["climate"] = climate
	env = SimEnvironment.create(track_env, settings.environment, settings.seed)
	env.bind_track(track)
	damage_level = CarDamage.level_from(settings.effective_damage_level())
	entries = p_entries
	self.tyre_defs = tyre_defs
	for i in entries.size():
		var e := entries[i]
		var base: CarDefinition = car_defs[e.car_id]
		var def := base.with_overrides(e.setup) if not e.setup.is_empty() else base
		defs.append(def)
		dry_compound.append(base.tyre_compound_id)
		var compound: TyreCompound = tyre_defs.get(def.tyre_compound_id, tyre_defs.values()[0])
		compounds.append(compound)
		cars.append(_make_car_on_grid(i, def))
		running_order.append(i)
		external.append(0)
		_incident_cooldown.append(0.0)
		_seen_damage.append([0.0, 0, false, false])
		if e.pit.is_empty():
			e.pit = PitRules.new_state(compound.id)
	pits = PitRules.new(self)
	_update_positions()


func _make_car_on_grid(slot: int, def: CarDefinition) -> CarState:
	var c := CarState.new()
	var g := track.grid_slot(slot)
	c.pos = g["pos"]
	c.heading = g["heading"]
	c.gear = 1
	c.rpm = def.idle_rpm
	c.damage_level = damage_level
	c.fuel_l = def.fuel_capacity_l if settings.start_fuel_l < 0.0 else minf(settings.start_fuel_l, def.fuel_capacity_l)
	# Tyres start between air and track temperature (no blankets).
	var t0 := lerpf(env.ambient_c, env.track_c, 0.4)
	c.tyre_temp = PackedFloat64Array([t0, t0, t0, t0])
	var q := track.project(c.pos)
	c.track_idx = q["idx"]
	c.track_s = q["s"]
	entries[slot].distance = c.track_s - track.length
	return c


## Queue an event (a Dictionary with at least "type") for the next step.
## Used by AI drivers for radio calls and strategy, e.g.
## {"type": "radio", "car": 3, "topic": "tyres", "text": "Rears are overheating"}.
func post_event(ev: Dictionary) -> void:
	if _posted.size() < 64:
		_posted.append(ev)


func car_count() -> int:
	return cars.size()


## Advance one tick. inputs[i] drives cars[i]; missing/null = neutral.
func step(inputs: Array) -> void:
	events.clear()
	if not _posted.is_empty():
		events.append_array(_posted)
		_posted.clear()
	tick += 1
	phase_time += TICK_DT
	var moving := 0
	for c in cars:
		if c.vel.length_squared() > 100.0:
			moving += 1
	env.traffic = moving
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
	var wear_rate := settings.tyre_wear_rate if settings.tyre_wear_enabled else 0.0
	inputs = pits.pre_step(inputs)
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
			CarPhysics.step(cars[i], inp, defs[i], compounds[i], env, track, sub_dt, fuel_rate, events, i, wear_rate)
		_resolve_collisions()
	_apply_damage()

	if follower:
		return
	for i in cars.size():
		_update_progress(i, prev_s[i])
	pits.host_update(events)
	_update_positions()
	_check_race_end()


# --- Pit lane and penalties (other modules read these) ------------------------

## True while car i is in the pit lane (entry to exit).
func in_pit_lane(i: int) -> bool:
	return pits.in_pit_lane(i)


## Car i's pit phase: "" (on track), "approach", "entry", "limit", "service", "leave", "exit".
func pit_phase(i: int) -> String:
	return pits.phase(i)


## True while the pit guide drives car i (AI drivers stand by).
func pit_controls(i: int) -> bool:
	return pits.controls(i)


## Host: a time penalty for car i, added to its race time in the classification.
func add_penalty(car: int, seconds: float, reason: String) -> void:
	if follower:
		return
	entries[car].penalty_s += seconds
	events.append({"type": "penalty", "car": car, "seconds": seconds, "reason": reason})


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
		pits.on_finished(i)
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
			# Classified on laps, then race time plus penalties.
			if ex.laps_done != ey.laps_done:
				return ex.laps_done > ey.laps_done
			var tx := ex.finish_time + ex.penalty_s
			var ty := ey.finish_time + ey.penalty_s
			if tx != ty:
				return tx < ty
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
	if phase == Phase.RACING and not entries.is_empty():
		var everyone_out := true
		for e in entries:
			if not e.dnf:
				everyone_out = false
		if everyone_out:
			phase = Phase.FINISHED
			_update_positions()
			events.append({"type": "race_finished"})
			return
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


# --- Damage and incidents ------------------------------------------------------

## Turns this tick's contacts and barrier hits into damage on the cars
## simulated here, and (on the authority) reports incidents and retirements
## for every car, including cars simulated elsewhere whose damage arrived
## over the network.
func _apply_damage() -> void:
	var n := cars.size()
	var hit_dv := PackedFloat64Array()
	hit_dv.resize(n)
	var hit_kind := []
	hit_kind.resize(n)
	var hit_other := PackedInt32Array()
	hit_other.resize(n)
	hit_other.fill(-1)
	var salt := 0
	for ev in events.duplicate():
		var t: String = ev.get("type", "")
		if t == "collision":
			for side in 2:
				var i: int = ev["a"] if side == 0 else ev["b"]
				if external[i]:
					continue
				var c := cars[i]
				var mass := defs[i].mass + c.fuel_l * CarPhysics.FUEL_DENSITY
				var dv: float = ev["impulse"] / mass
				var local: Vector2 = (ev["pos"] - c.pos).rotated(-c.heading)
				salt += 1
				_damage_hit(i, dv, local, salt)
				if dv > hit_dv[i]:
					hit_dv[i] = dv
					hit_kind[i] = "collision"
					hit_other[i] = ev["b"] if side == 0 else ev["a"]
		elif t == "barrier_impact":
			var i: int = ev["car"]
			if external[i]:
				continue
			var c := cars[i]
			# A concrete wall hurts more than armco, a tyre wall much less.
			var dv: float = ev["speed"] * 1.3 * float(TrackData.BARRIER_HARDNESS[ev.get("barrier", TrackData.Barrier.ARMCO)])
			var nrm: Vector2 = ev.get("normal", -c.right())
			var local := CarDamage.outline_point(nrm.rotated(-c.heading), defs[i])
			salt += 1
			_damage_hit(i, dv, local, salt)
			if dv > hit_dv[i]:
				hit_dv[i] = dv
				hit_kind[i] = "barrier"
				hit_other[i] = -1
	if follower:
		return
	for i in n:
		_incident_cooldown[i] = maxf(_incident_cooldown[i] - TICK_DT, 0.0)
		var c := cars[i]
		var seen: Array = _seen_damage[i]
		var body := CarDamage.body_total(c)
		var punct := 0
		for w in 4:
			if c.puncture[w] > 0.5:
				punct |= 1 << w
		var eng := CarDamage.engine_failed(c)
		var gbx := c.damage_gearbox >= 1.0
		var dv := hit_dv[i]
		var kind: String = hit_kind[i] if hit_kind[i] != null else ""
		if external[i] and body - float(seen[0]) > 0.2:
			# A car simulated elsewhere: its owner felt the hit, we see the dent.
			dv = CarDamage.DV_MIN + (body - float(seen[0])) * (CarDamage.DV_FULL - CarDamage.DV_MIN)
			kind = "impact"
		if dv >= INCIDENT_DV and _incident_cooldown[i] <= 0.0:
			_incident(i, kind, CarDamage.severity(dv), hit_other[i])
			_incident_cooldown[i] = INCIDENT_COOLDOWN_S
		if punct & ~int(seen[1]):
			_incident(i, "puncture", 0.3, -1)
		if eng and not seen[2]:
			_incident(i, "engine_failure", 1.0, -1)
		if gbx and not seen[3]:
			_incident(i, "gearbox_failure", 0.4, -1)
		_seen_damage[i] = [body, punct, eng, gbx]
		var e := entries[i]
		if eng and not e.dnf and not e.finished:
			e.dnf = true
			events.append({"type": "retired", "car": i, "reason": "engine"})


func _damage_hit(i: int, dv: float, local: Vector2, salt: int) -> void:
	if damage_level == CarDamage.Level.OFF:
		return
	var r := CarDamage.apply_impact(cars[i], defs[i], dv, local, damage_level, tick * 64 + i * 8 + salt)
	if r["zone"] >= 0 and r["amount"] > 0.03:
		events.append({"type": "damage", "car": i, "zone": CarDamage.ZONE_NAMES[r["zone"]], "amount": r["amount"]})


func _incident(i: int, kind: String, severity: float, other: int) -> void:
	if CarDamage.is_crippled(cars[i]):
		severity = 1.0
	events.append({"type": "incident", "car": i, "kind": kind, "severity": severity,
		"pos": cars[i].pos, "other": other})


## The car is out of the race (engine failure, or retired by the rules).
func is_retired(i: int) -> bool:
	return entries[i].dnf and not entries[i].finished


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
		"env": env.to_dict(), "cars": car_data, "entries": entry_data, "pits": pits.to_dict(),
	}


func apply_snapshot(snap: Dictionary) -> void:
	tick = snap["tick"]
	phase = snap["phase"]
	phase_time = snap["phase_time"]
	race_time = snap["race_time"]
	leader_finish_time = snap["leader_finish_time"]
	finish_order.assign(snap["finish_order"])
	env.apply_dict(snap["env"])
	for i in cars.size():
		cars[i].deserialize(snap["cars"][i])
		entries[i].from_dict(snap["entries"][i])
		pits.apply_remote(i, entries[i].pit)
	if snap.has("pits"):
		pits.from_dict(snap["pits"])
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
	env.apply_dict(st["env"])
	for i in mini(entries.size(), st["entries"].size()):
		# A car's pit state belongs to the machine that simulates it.
		var own_pit: Dictionary = entries[i].pit
		entries[i].from_dict(st["entries"][i])
		if not external[i]:
			entries[i].pit = own_pit
		else:
			pits.apply_remote(i, entries[i].pit)
	_update_positions()


func state_hash() -> String:
	return var_to_bytes(snapshot()).hex_encode().md5_text()
