class_name TrackMarshals
extends RefCounted
## Marshals clearing debris off the circuit. Part of the pure race sim: plain
## numbers in Dictionaries, so it goes into snapshots and the race state and
## plays out the same everywhere. RaceControl keeps the debris build-up
## (RaceControl.debris) and the crews at work (RaceControl.marshal_jobs) and
## shows double yellow flags while they are out; WorldView draws them.
##
## Every crash leaves bits on the track (the damage module's "incident"
## events, by severity). One shunt isn't worth stopping for, but once the bits
## in one place add up to CLEAR_AT, a crew of marshals runs out from the
## barrier, sweeps the area and runs back. Double yellows cover that part of
## the track until they are back behind the barrier: slow right down (under
## double_yellow_limit), no overtaking.
##
## A spot: {s, pos, amount}. A job: see plan().

const MERGE_M := 60.0            ## debris this close together counts as one pile
const CLEAR_AT := 1.4            ## summed incident severity that needs marshals
const RUN_SPEED := 4.5           ## m/s, marshals running out and back
const SWEEP_S := 16.0            ## sweeping in all to clear the debris away
const BURST_MIN_S := 2.0         ## not worth running on for less than this
const SAFETY_S := 2.5            ## off the track this long before the next car arrives
const WAIT_OFF_M := 3.0          ## where they wait: this far off the track edge
const CREW := 4
const DOUBLE_BEFORE_M := 220.0   ## double yellow zone before the marshals
const DOUBLE_AFTER_M := 80.0     ## and after them
const DOUBLE_LIMIT := 1.2        ## speed limit: the VSC reference speed x this
const DOUBLE_TOLERANCE := 1.1    ## faster than limit x this past the marshals: penalty


## Adds amount of debris at track distance s / position pos.
static func add_debris(spots: Array, length: float, s: float, pos: Vector2, amount: float) -> void:
	for spot in spots:
		var d := absf(fposmod(float(spot["s"]) - s + length * 0.5, length) - length * 0.5)
		if d < MERGE_M:
			var total := float(spot["amount"]) + amount
			# The pile's centre moves towards the heavier side.
			spot["pos"] = (spot["pos"] as Vector2).lerp(pos, amount / total)
			spot["amount"] = total
			return
	spots.append({"s": s, "pos": pos, "amount": amount})


## A crew for a pile of debris. id: a number unique in the race (seeds where
## each marshal goes).
static func plan(track: TrackData, spot: Dictionary, id: int) -> Dictionary:
	var pos: Vector2 = spot["pos"]
	var q := track.project(pos)
	var s: float = q["s"]
	var off: float = q["offset"]
	# Out from the nearer side of the track.
	var side := 1.0 if off >= 0.0 else -1.0
	var i := track.index_at(s)
	var bo: float = (track.width_right[i] if side > 0.0 else track.width_left[i]) + track.runoff
	var crew := []
	for k in CREW:
		var along := (float(k) - (CREW - 1) * 0.5) * 7.0
		var gate := track.position_at(s + along * 0.6 - 10.0, side * (bo - 0.8))
		var r1 := _hash(id * 31 + k * 7)
		var r2 := _hash(id * 17 + k * 13 + 5)
		var at := track.position_at(s + along + (r1 - 0.5) * 4.0, off + (r2 - 0.5) * 6.0)
		var w: float = track.width_right[i] if side > 0.0 else track.width_left[i]
		var wait := track.position_at(s + along, side * (w + track.kerb_width + WAIT_OFF_M))
		crew.append({"gate": gate, "wait": wait, "at": at, "out": gate.distance_to(wait) / RUN_SPEED,
			"run": wait.distance_to(at) / RUN_SPEED, "seed": r1 * 10.0 + r2})
	return {"id": id, "s": s, "pos": pos, "side": side, "phase": "out", "t": 0.0, "crew": crew,
		"done": false, "cleared": false, "swept": 0.0, "burst": 0.0, "sorties": 0}


## gap: seconds until the next car reaches the debris (INF = none coming),
## from RaceControl. -1 = unknown (a client between race-state updates): keep
## doing what they are doing, never run on.
static func step(job: Dictionary, dt: float, gap: float = INF) -> void:
	if job["done"]:
		return
	job["t"] = float(job["t"]) + dt
	var t: float = job["t"]
	var run := _longest(job, "run")
	match String(job["phase"]):
		"out":
			if t >= _longest(job, "out"):
				_next(job, "wait")
		"wait":
			var left := SWEEP_S - float(job["swept"])
			var room := gap - 2.0 * run - SAFETY_S
			if gap >= 0.0 and room >= minf(BURST_MIN_S, left):
				job["burst"] = minf(left, room)
				job["sorties"] = int(job["sorties"]) + 1
				_next(job, "on")
		"on":
			if t >= run:
				_next(job, "sweep")
		"sweep":
			job["swept"] = float(job["swept"]) + dt
			# Off again when their time is up or a car is coming sooner than planned.
			if t >= float(job["burst"]) or (gap >= 0.0 and gap < run + SAFETY_S):
				_next(job, "off")
		"off":
			if t >= run:
				if float(job["swept"]) >= SWEEP_S - 0.01:
					job["cleared"] = true
					_next(job, "back")
				else:
					_next(job, "wait")
		"back":
			if t >= _longest(job, "out"):
				job["done"] = true
				job["phase"] = "done"


## Where each marshal is: [{pos, heading, action ("run"/"sweep"/"wave"), t}].
## Pure function of the job, so clients just step the clock.
static func view(job: Dictionary) -> Array:
	var out := []
	var t: float = job["t"]
	var phase: String = job["phase"]
	for m in job["crew"]:
		var gate: Vector2 = m["gate"]
		var wait: Vector2 = m["wait"]
		var at: Vector2 = m["at"]
		var seed: float = m["seed"]
		var p := wait
		var h := (at - wait).angle()
		var action := "wave"
		match phase:
			"out":
				var f := clampf(t / maxf(float(m["out"]), 0.1), 0.0, 1.0)
				p = gate.lerp(wait, f)
				action = "run" if f < 1.0 else "wave"
			"on":
				var f := clampf(t / maxf(float(m["run"]), 0.1), 0.0, 1.0)
				p = wait.lerp(at, f)
				action = "run"
			"sweep":
				# Small figure-of-eight around their patch, broom going.
				var w := t * 0.5 + seed
				p = at + Vector2(sin(w) * 2.2, sin(w * 2.0) * 1.1).rotated(h)
				h += cos(w) * 0.8
				action = "sweep"
			"off":
				var f := clampf(t / maxf(float(m["run"]), 0.1), 0.0, 1.0)
				p = at.lerp(wait, f)
				h += PI
				action = "run" if f < 1.0 else "wave"
			"back", "done":
				var f := clampf(t / maxf(float(m["out"]), 0.1), 0.0, 1.0)
				p = wait.lerp(gate, f)
				h = (gate - wait).angle()
				action = "run" if f < 1.0 else "wave"
		out.append({"pos": p, "heading": h, "action": action, "t": t + seed})
	return out


## True while any marshal is on the racing surface.
static func on_surface(job: Dictionary) -> bool:
	return job["phase"] in ["on", "sweep", "off"]


## True while marshals are out on the circuit (double yellows).
static func on_track(job: Dictionary) -> bool:
	return not job["done"]


static func _next(job: Dictionary, phase: String) -> void:
	job["phase"] = phase
	job["t"] = 0.0


static func _longest(job: Dictionary, key: String) -> float:
	var r := 0.0
	for m in job["crew"]:
		r = maxf(r, float(m[key]))
	return r


## Deterministic 0..1 from an int.
static func _hash(n: int) -> float:
	var x := (n * 1103515245 + 12345) & 0x7fffffff
	x = (x ^ (x >> 13)) * 1274126177 & 0x7fffffff
	return float(x % 10000) / 10000.0
