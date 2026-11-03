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
## With no flags to cover them (rallycross) the crew only goes out when it is
## safe: they wait behind the barrier
## ("wait") until the next car is far enough away for them to run out, sweep
## a while and run back, and they run back off ("back") as soon as a car is
## coming, then wait for the next gap. The sweeping adds up over the gaps
## until the pile is gone (SWEEP_S in all). step() gets clear_s: seconds
## until the next car reaches the pile (RaceControl.marshal_clear_s; INF on
## circuits, where double yellows cover them and they go straight out).
##
## A spot: {s, pos, amount}. A job: see plan().

const MERGE_M := 60.0            ## debris this close together counts as one pile
const CLEAR_AT := 1.4            ## summed incident severity that needs marshals
const RUN_SPEED := 4.5           ## m/s, marshals running out and back
const SWEEP_S := 16.0            ## sweeping the debris away
const CREW := 4
const DOUBLE_BEFORE_M := 220.0   ## double yellow zone before the marshals
const DOUBLE_AFTER_M := 80.0     ## and after them
const DOUBLE_LIMIT := 1.2        ## speed limit: the VSC reference speed x this
const DOUBLE_TOLERANCE := 1.1    ## faster than limit x this past the marshals: penalty
const MIN_WORK_S := 4.0          ## a gap must give at least this much sweeping
const BACK_MARGIN_S := 1.5       ## off the track this long before a car arrives


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
		crew.append({"gate": gate, "at": at, "run": gate.distance_to(at) / RUN_SPEED, "seed": r1 * 10.0 + r2})
	return {"id": id, "s": s, "pos": pos, "side": side, "phase": "wait", "t": 0.0, "crew": crew,
		"done": false, "cleared": false, "work_left": SWEEP_S}


## Moves the crew on by dt. clear_s: seconds until the next car reaches the
## pile (INF with no car coming).
static func step(job: Dictionary, dt: float, clear_s: float = INF) -> void:
	if job["done"]:
		return
	job["t"] = float(job["t"]) + dt
	var t: float = job["t"]
	var run := _longest_run(job)
	match String(job["phase"]):
		"wait":
			if clear_s > run * 2.0 + MIN_WORK_S + BACK_MARGIN_S:
				_next(job, "out")
		"out":
			if clear_s < minf(t, run) + BACK_MARGIN_S:
				# A car is coming: turn round where they are (continuous).
				_next(job, "back")
				job["t"] = maxf(run - t, 0.0)
			elif t >= run:
				_next(job, "sweep")
		"sweep":
			job["work_left"] = float(job.get("work_left", SWEEP_S)) - dt
			if float(job["work_left"]) <= 0.0:
				job["cleared"] = true
				_next(job, "back")
			elif clear_s < run + BACK_MARGIN_S:
				_next(job, "back")
		"back":
			if t >= run:
				if job["cleared"]:
					job["done"] = true
					job["phase"] = "done"
				else:
					_next(job, "wait")


## Where each marshal is: [{pos, heading, action ("run"/"sweep"/"wave"), t}].
## Pure function of the job, so clients just step the clock.
static func view(job: Dictionary) -> Array:
	var out := []
	var t: float = job["t"]
	var phase: String = job["phase"]
	for m in job["crew"]:
		var gate: Vector2 = m["gate"]
		var at: Vector2 = m["at"]
		var run: float = m["run"]
		var seed: float = m["seed"]
		var p := at
		var h := (at - gate).angle()
		var action := "sweep"
		match phase:
			"wait":   # behind the barrier, waiting for a gap
				p = gate
				action = "wave"
			"out":
				var f := clampf(t / maxf(run, 0.1), 0.0, 1.0)
				p = gate.lerp(at, f)
				action = "run" if f < 1.0 else "wave"
			"sweep":
				# Small figure-of-eight around their patch, broom going.
				var w := t * 0.5 + seed
				p = at + Vector2(sin(w) * 2.2, sin(w * 2.0) * 1.1).rotated(h)
				h += cos(w) * 0.8
			"back", "done":
				var f := clampf(t / maxf(run, 0.1), 0.0, 1.0)
				p = at.lerp(gate, f)
				h += PI
				action = "run" if f < 1.0 else "wave"
		out.append({"pos": p, "heading": h, "action": action, "t": t + seed})
	return out


## True while marshals are out on the circuit (not waiting behind the barrier).
static func on_track(job: Dictionary) -> bool:
	return not job["done"] and String(job["phase"]) != "wait"


static func _next(job: Dictionary, phase: String) -> void:
	job["phase"] = phase
	job["t"] = 0.0


static func _longest_run(job: Dictionary) -> float:
	var r := 0.0
	for m in job["crew"]:
		r = maxf(r, float(m["run"]))
	return r


## Deterministic 0..1 from an int.
static func _hash(n: int) -> float:
	var x := (n * 1103515245 + 12345) & 0x7fffffff
	x = (x ^ (x >> 13)) * 1274126177 & 0x7fffffff
	return float(x % 10000) / 10000.0
