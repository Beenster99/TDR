class_name CarRecovery
extends RefCounted
## Recovery vehicles: a car that has retired out on the circuit is taken away
## by the marshals, under the safety car. Part of the pure race sim (plain
## numbers, no nodes), so it plays out the same on the host, on clients and in
## replays. RaceControl owns the jobs (RaceControl.recoveries); WorldView draws
## them (WorldView.set_recovery_vehicles).
##
## Two kinds:
##  * CRANE, for a car that crashed into the wall: a crane truck drives up on
##    the service road behind the barrier, swings its boom over, lifts the car
##    over the barrier onto its flatbed and drives off with it.
##  * TRACTOR, for a car stopped anywhere else (on the track, in the gravel,
##    on the grass): a tractor comes through a marshals' gate in the barrier,
##    backs up to the car, hooks a strap on and tows it out through another
##    gate.
##
## A job is a Dictionary (so it goes straight into snapshots and the race
## state): see plan() for its fields.

const CRANE := "crane"
const TRACTOR := "tractor"

## Phases, in order. A crane: drive_in, reach, lift, swing, lower, drive_out.
## A tractor: drive_in, hook, drive_out. Then done.
const DRIVE_IN_SPEED := 10.0     ## m/s
const TOW_SPEED := 5.5
const CRANE_OUT_SPEED := 8.0
const HOOK_S := 6.0              ## tractor: hooking the strap on
const REACH_S := 3.5             ## crane: boom swings out over the car
const LIFT_S := 4.0              ## crane: lifts the car clear of the barrier
const SWING_S := 5.0             ## crane: swings it round onto the flatbed
const LOWER_S := 3.0             ## crane: lowers it onto the bed
const LIFT_HEIGHT := 4.2         ## m: high enough to clear any barrier and fence
const BED_HEIGHT := 1.15         ## m: top of the crane truck's flatbed
const TOW_GAP := 2.6             ## m: strap length between tractor and car
const CRANE_BEHIND := 3.8       ## m behind the barrier for the service road (clear of the tree line)
const GATE_OUT := 9.0            ## m behind the barrier where vehicles appear / vanish
## Size of each vehicle (m), for placing the car on the bed / at the hitch.
const TRACTOR_LENGTH := 4.2
const CRANE_LENGTH := 9.5
const CRANE_PIVOT := 1.8         ## turret ahead of the truck's centre
const CRANE_BED := -2.4          ## centre of the flatbed behind the truck's centre


## A new job for car `car` stopped at pos/heading (track distance car_s,
## lateral offset car_off, + = right). car_length in metres.
static func plan(track: TrackData, car: int, pos: Vector2, heading: float, car_s: float,
		car_off: float, car_length: float) -> Dictionary:
	var side := 1.0 if car_off >= 0.0 else -1.0
	var bo := _barrier_offset(track, car_s, side)
	var at_wall := absf(car_off) >= bo - 4.5
	var job := {
		"car": car, "kind": CRANE if at_wall else TRACTOR, "phase": "drive_in", "t": 0.0, "d": 0.0,
		"side": side, "car_half": car_length * 0.5, "car0_pos": pos, "car0_heading": heading,
		"car_pos": pos, "car_heading": heading, "hoist": 0.0, "reach": 0.0,
		"carrying": false, "done": false, "beacon": true,
		"pos": Vector2.ZERO, "heading": 0.0, "speed": 0.0,
	}
	var path_in := PackedVector2Array()
	var path_out := PackedVector2Array()
	if at_wall:
		# The service road behind the barrier, level with the car.
		var road := maxf(bo, absf(car_off)) + CRANE_BEHIND
		path_in.append(track.position_at(car_s - 140.0, side * (road + 2.0)))
		path_in.append(track.position_at(car_s - 70.0, side * road))
		path_in.append(track.position_at(car_s - CRANE_PIVOT, side * road))
		path_out.append(path_in[path_in.size() - 1])
		path_out.append(track.position_at(car_s + 70.0, side * road))
		path_out.append(track.position_at(car_s + 150.0, side * (road + 8.0)))
	else:
		# In through a gate, along the run-off and up to the front of the car,
		# tow it on and out through the next gate.
		var lane := bo - 3.5
		var hitch_s := car_s + car_length * 0.5 + TOW_GAP + TRACTOR_LENGTH * 0.5
		var gate_in := car_s - 55.0
		var gate_out := car_s + 70.0
		path_in.append(track.position_at(gate_in - 10.0, side * (bo + GATE_OUT)))
		path_in.append(track.position_at(gate_in, side * (bo + 2.0)))
		path_in.append(track.position_at(gate_in + 8.0, side * lane))
		path_in.append(track.position_at(car_s - 18.0, side * lane))
		path_in.append(track.position_at(car_s - 2.0, car_off + side * 0.5 * (lane - absf(car_off))))
		path_in.append(track.position_at(hitch_s, car_off))
		path_out.append(path_in[path_in.size() - 1])
		path_out.append(track.position_at(hitch_s + 16.0, car_off + side * 0.6 * (lane - absf(car_off))))
		path_out.append(track.position_at(gate_out - 12.0, side * lane))
		path_out.append(track.position_at(gate_out, side * (bo + 2.0)))
		path_out.append(track.position_at(gate_out + 10.0, side * (bo + GATE_OUT + 4.0)))
	job["path_in"] = path_in
	job["path_out"] = path_out
	_place(job, path_in, 0.0)
	return job


## Moves the job on by dt. Also sets car_pos / car_heading / hoist while the
## car is being carried or towed. Deterministic: the same steps give the same job.
static func step(job: Dictionary, dt: float) -> void:
	if job["done"]:
		return
	job["t"] = float(job["t"]) + dt
	var t: float = job["t"]
	var crane: bool = job["kind"] == CRANE
	match String(job["phase"]):
		"drive_in":
			var path: PackedVector2Array = job["path_in"]
			if _drive(job, path, DRIVE_IN_SPEED, dt):
				_next(job, "reach" if crane else "hook")
		"hook":
			job["speed"] = 0.0
			if t >= HOOK_S:
				job["carrying"] = true
				_next(job, "drive_out")
		"reach":
			job["reach"] = clampf(t / REACH_S, 0.0, 1.0)
			if t >= REACH_S:
				job["carrying"] = true
				_next(job, "lift")
		"lift":
			job["hoist"] = LIFT_HEIGHT * smoothstep(0.0, 1.0, t / LIFT_S)
			if t >= LIFT_S:
				_next(job, "swing")
		"swing":
			_swing(job, smoothstep(0.0, 1.0, clampf(t / SWING_S, 0.0, 1.0)))
			if t >= SWING_S:
				_next(job, "lower")
		"lower":
			job["hoist"] = lerpf(LIFT_HEIGHT, BED_HEIGHT, smoothstep(0.0, 1.0, t / LOWER_S))
			job["reach"] = 1.0 - 0.5 * clampf(t / LOWER_S, 0.0, 1.0)
			if t >= LOWER_S:
				job["reach"] = 0.0
				_next(job, "drive_out")
		"drive_out":
			var path: PackedVector2Array = job["path_out"]
			var finished := _drive(job, path, CRANE_OUT_SPEED if crane else TOW_SPEED, dt)
			if crane:
				_on_bed(job)
			else:
				_tow(job, dt)
			if finished:
				job["done"] = true
				job["phase"] = "done"


## True once the car is off the circuit (lifted over the wall or towed out
## through the gate): from then on it is no danger.
static func car_clear(job: Dictionary) -> bool:
	if job["done"]:
		return true
	if job["kind"] == CRANE:
		return job["phase"] == "lower" or job["phase"] == "drive_out"
	var path: PackedVector2Array = job["path_out"]
	return job["phase"] == "drive_out" and float(job["d"]) >= _length(path) - 12.0


## For drawing: {kind, pos, heading, speed, reach (0 stowed .. 1 over the car),
## hook (where the hook hangs, 2D), hoist (hook height above the ground),
## towing, beacon}.
static func view(job: Dictionary) -> Dictionary:
	return {"kind": job["kind"], "pos": job["pos"], "heading": job["heading"], "speed": job["speed"],
		"reach": job["reach"], "hook": job["car_pos"], "hoist": job["hoist"], "phase": job["phase"],
		"towing": job["kind"] == TRACTOR and job["carrying"], "car": job["car"], "car_pos": job["car_pos"], "car_heading": job["car_heading"],
		"beacon": job["beacon"]}


# --- Inside ------------------------------------------------------------------

static func _barrier_offset(track: TrackData, s: float, side: float) -> float:
	var i := track.index_at(s)
	var w: float = track.width_right[i] if side > 0.0 else track.width_left[i]
	return w + track.runoff


static func _next(job: Dictionary, phase: String) -> void:
	job["phase"] = phase
	job["t"] = 0.0
	job["d"] = 0.0


## Drives along path; true at the end. Slows down for the last few metres.
static func _drive(job: Dictionary, path: PackedVector2Array, vmax: float, dt: float) -> bool:
	var total := _length(path)
	var left := total - float(job["d"])
	var target := minf(vmax, 1.0 + 0.9 * left)
	var v := move_toward(float(job["speed"]), target, 3.0 * dt)
	job["speed"] = v
	job["d"] = minf(float(job["d"]) + v * dt, total)
	_place(job, path, job["d"])
	return float(job["d"]) >= total - 0.05


static func _place(job: Dictionary, path: PackedVector2Array, d: float) -> void:
	job["pos"] = _point(path, d)
	var a := _point(path, d - 2.5)
	var b := _point(path, d + 2.5)
	if a.distance_squared_to(b) > 0.01:
		job["heading"] = (b - a).angle()


static func _length(path: PackedVector2Array) -> float:
	var l := 0.0
	for k in range(1, path.size()):
		l += path[k - 1].distance_to(path[k])
	return l


static func _point(path: PackedVector2Array, d: float) -> Vector2:
	if path.is_empty():
		return Vector2.ZERO
	if d <= 0.0:
		return path[0]
	for k in range(1, path.size()):
		var seg := path[k - 1].distance_to(path[k])
		if d <= seg:
			return path[k - 1].lerp(path[k], d / maxf(seg, 0.001))
		d -= seg
	return path[path.size() - 1]


## The tractor pulls the car along on a strap (like a trailer).
static func _tow(job: Dictionary, _dt: float) -> void:
	var fwd := Vector2.from_angle(job["heading"])
	var hitch: Vector2 = job["pos"] - fwd * TRACTOR_LENGTH * 0.5
	var car_pos: Vector2 = job["car_pos"]
	var to := hitch - car_pos
	if to.length_squared() < 0.01:
		return
	var h := to.angle()
	# The strap is pulling on the car's nose: keep the car's centre half a car
	# length plus the strap behind the hitch.
	var reach := TOW_GAP + float(job["car_half"])
	job["car_heading"] = h
	job["car_pos"] = hitch - Vector2.from_angle(h) * reach


static func _pivot(job: Dictionary) -> Vector2:
	return job["pos"] + Vector2.from_angle(job["heading"]) * CRANE_PIVOT


static func _bed(job: Dictionary) -> Vector2:
	return job["pos"] + Vector2.from_angle(job["heading"]) * CRANE_BED


## Crane: swing the car from where it stopped round to the flatbed.
static func _swing(job: Dictionary, f: float) -> void:
	var pivot := _pivot(job)
	var from: Vector2 = job["car0_pos"] - pivot
	var to: Vector2 = _bed(job) - pivot
	var a := lerp_angle(from.angle(), to.angle(), f)
	var r := lerpf(from.length(), to.length(), f)
	job["car_pos"] = pivot + Vector2.from_angle(a) * r
	job["car_heading"] = lerp_angle(float(job["car0_heading"]), float(job["heading"]), f)


static func _on_bed(job: Dictionary) -> void:
	job["car_pos"] = _bed(job)
	job["car_heading"] = job["heading"]
	job["hoist"] = BED_HEIGHT
