class_name RaceControl
extends RefCounted
## Race control: flags, the virtual safety car (VSC), the safety car (SC) and
## penalties. Part of the pure race simulation (no nodes, no clock), so it
## runs the same on the host, on a dedicated server and in tests.
##
## Only the authority (offline / host) decides anything. Clients get the
## whole state in RaceSim.race_state()["race_control"] and only move the
## safety car along between updates so it looks smooth.
##
## How it works:
##  * Incidents (the damage module's "incident" events, big "collision"
##    events) and stranded cars (stopped on the circuit) raise local yellow
##    flags for that part of the track: no overtaking there.
##  * A car stopped on the racing surface, a retired car, a big crash or
##    several stranded cars escalate to a VSC (everyone keeps above a
##    reference lap, shown as a delta) or a full SC.
##  * The SC comes out ahead of the leader and the field bunches up behind
##    it. Once the track is clear, lapped cars may overtake and unlap
##    themselves, then "safety car in this lap": it peels off into the pit
##    lane and the leader controls the restart. Overtaking is allowed again
##    once a car crosses the control line.
##  * Overtaking under yellow / VSC / SC, passing the safety car, or running
##    too fast under the VSC gets a warning first (give the place back /
##    slow down) and then a time penalty (RaceSim.add_penalty), added to the
##    car's race time in the final classification.
##  * The host setting RaceSettings.safety_car_enabled switches the VSC and
##    SC on or off. Local yellow flags always apply.

enum Mode { GREEN, VSC, SC }
const MODE_NAMES := ["green", "vsc", "sc"]

## Safety car pace profile (m/s, m/s^2): a lap about 35-40 % slower than race pace.
const SC_MAX_SPEED := 38.0
const SC_LAT_ACCEL := 6.0
const SC_DECEL := 6.0
## The VSC reference is a little quicker than the SC itself.
const VSC_MAX_SPEED := 42.0
const VSC_LAT_ACCEL := 7.5
## Below this a car on the circuit counts as stopped.
const STOPPED_SPEED := 3.0
const MOVING_AGAIN := 8.0
const YELLOW_HALF_M := 120.0     ## a local yellow covers this much track either side
const YELLOW_HOLD_S := 12.0      ## stays out this long after the hazard is gone
const STRANDED_YELLOW_S := 2.0
const STRANDED_VSC_S := 6.0
const STRANDED_SC_S := 16.0
const RECOVERY_VSC_S := 25.0     ## marshals clear a stranded car in this time
const RECOVERY_SC_S := 40.0
const VSC_MIN_S := 20.0
const VSC_ENDING_S := 6.0
const SC_GAP_TARGET := 25.0      ## leader keeps this far behind the safety car
const SC_SPAWN_AHEAD := 160.0
const SC_PIT_SPEED := 17.0
const GIVE_BACK_S := 12.0        ## time to give a place back before a penalty
const PENALTY_S := 5.0
const VSC_DELTA_WARN := -0.5
const VSC_DELTA_PENALTY := -2.0
const RESTART_GO_BEFORE_LINE := 250.0  ## AI leader goes this far before the line

var sim: RaceSim
var enabled := true              ## settings.safety_car_enabled
var mode: int = Mode.GREEN
var mode_time: float = 0.0
var reason: String = ""
var deployments: int = 0
## VSC: "" or "ending" (green in a few seconds).
## SC: "out" (field bunching), "in_this_lap" (green lights, coming in),
## "restart" (gone into the pits; green when the leader reaches the line).
var stage: String = ""
var stage_time: float = 0.0
var wave_by := false             ## lapped cars may overtake
var sc_laps: int = 0             ## leader laps completed behind the SC
var _leader_laps_at: int = 0

## The safety car itself (draw it from these).
var sc_visible := false
var sc_s: float = 0.0            ## track distance (centre line), or pit metres while in the lane
var sc_in_pit := false
var sc_pos := Vector2.ZERO
var sc_heading: float = 0.0
var sc_speed: float = 0.0
var sc_lights: String = "off"    ## "off", "amber" (out), "green" (coming in)

## Local yellow flags: [{ "from": s, "to": s, "until": race_time, "car": i }]
var yellows: Array = []
## Per car
var stranded_t: PackedFloat64Array = []   ## seconds stopped on the circuit
var recovered: PackedByteArray = []       ## marshals have dealt with it (ignored from now on)
var carried: PackedByteArray = []         ## a recovery vehicle has it (lifted or on the strap)
## Recovery vehicles at work (CarRecovery jobs, one per retired car out on the
## circuit). Draw them from recovery_vehicles().
var recoveries: Array = []
var _cleared: PackedByteArray = []        ## a live stopped car the marshals have made safe (yellow only)
var vsc_delta: PackedFloat64Array = []    ## seconds; below 0 = faster than allowed
var vsc_warned: PackedByteArray = []
var vsc_penalised: PackedByteArray = []
var unlapping: PackedByteArray = []       ## allowed to overtake and unlap
var unlap_from: PackedFloat64Array = []   ## distance gap to the leader when waved by
var released: PackedByteArray = []        ## crossed the line since the restart: may race
## Pending "give the place back": car -> { "victim": j (-2 = the safety car), "until": t, "why": String }
var give_back: Dictionary = {}
var _prev_order: Array[int] = []
var _sc_behind: PackedByteArray = []      ## car was behind the SC last tick

var _sc_profile: PackedFloat64Array = []
var _vsc_profile: PackedFloat64Array = []
var _danger: float = 0.0                  ## how bad things are right now (0 none, 1 VSC, 2 SC)
var _big_incident_until: float = -1.0


func _init(p_sim: RaceSim) -> void:
	sim = p_sim
	enabled = sim.settings.safety_car_enabled
	var n := sim.cars.size()
	stranded_t.resize(n)
	recovered.resize(n)
	carried.resize(n)
	_cleared.resize(n)
	vsc_delta.resize(n)
	vsc_warned.resize(n)
	vsc_penalised.resize(n)
	unlapping.resize(n)
	unlap_from.resize(n)
	released.resize(n)
	_sc_behind.resize(n)
	released.fill(1)
	_build_profiles()


# --- Queries (AI, HUD, other race rules) ------------------------------------

## True once car i is no longer driven by the physics: craned / towed away,
## or recovered and gone.
func out_of_play(i: int) -> bool:
	return recovered[i] == 1 or carried[i] == 1


## What to draw for each recovery vehicle at work: see CarRecovery.view().
func recovery_vehicles() -> Array:
	var out := []
	for job in recoveries:
		if not job["done"]:
			out.append(CarRecovery.view(job))
	return out


## The recovery job for car i, or {} when there is none.
func recovery_for(i: int) -> Dictionary:
	for job in recoveries:
		if int(job["car"]) == i:
			return job
	return {}


func mode_name() -> String:
	return MODE_NAMES[mode]


## "green", "yellow" (only local yellows out), "vsc" or "sc".
func neutralisation() -> String:
	if mode != Mode.GREEN:
		return MODE_NAMES[mode]
	return "yellow" if not yellows.is_empty() else "green"


func safety_car_active() -> bool:
	return mode != Mode.GREEN


## Rough share of a normal pit stop's time loss saved by stopping now.
func pit_time_saving() -> float:
	match mode:
		Mode.SC:
			return 0.55 if stage == "out" or stage == "in_this_lap" else 0.2
		Mode.VSC:
			return 0.3 if stage == "" else 0.1
	return 0.0


## Is track distance s inside a local yellow flag zone?
func yellow_at(s: float) -> bool:
	for y in yellows:
		if _in_zone(s, y["from"], y["to"]):
			return true
	return false


## May car i overtake car j right now?
func may_pass(i: int, j: int) -> bool:
	var cj := sim.cars[j]
	var ej := sim.entries[j]
	if ej.finished or ej.dnf or recovered[j] or stranded_t[j] >= 1.0 or _pitting(j) or _pitting(i):
		return true
	# A car that has gone off or is crawling back after a spin may be passed.
	if cj.surface >= TrackData.Surface.GRASS or cj.speed() < maxf(STOPPED_SPEED + 2.0, sim.cars[i].speed() * 0.5):
		return true
	# Taking back a place someone has to give back.
	if give_back.has(j) and int(give_back[j]["victim"]) == i:
		return true
	if mode == Mode.GREEN:
		if not released[i]:
			return false
		return not (yellow_at(sim.cars[i].track_s) or yellow_at(cj.track_s))
	if unlapping[i]:
		return true
	return false


## Speed the VSC reference allows at track distance s (m/s).
func vsc_speed_at(s: float) -> float:
	return _vsc_profile[sim.track.index_at(s)] if not _vsc_profile.is_empty() else VSC_MAX_SPEED


func sc_speed_at(s: float) -> float:
	return _sc_profile[sim.track.index_at(s)] if not _sc_profile.is_empty() else SC_MAX_SPEED


## Gap from car i forward to the safety car along the track (m); INF when
## the SC isn't on the circuit.
func gap_to_sc(i: int) -> float:
	if not sc_visible or sc_in_pit:
		return INF
	return fposmod(sc_s - sim.cars[i].track_s, sim.track.length)


## Why the track isn't clear (debugging / reports).
func hazards() -> String:
	var out := []
	for i in sim.cars.size():
		if stranded_t[i] >= STRANDED_YELLOW_S:
			out.append("%s %.0fs%s%s" % [sim.entries[i].driver_name, stranded_t[i], " cleared" if _cleared[i] else "",
				" on track" if _on_racing_surface(i) else ""])
	return "danger %.0f: %s" % [_danger, ", ".join(out)]


## The car the safety car is picking up (normally the race leader).
func sc_train_leader() -> int:
	for i in sim.running_order:
		var e := sim.entries[i]
		if not e.finished and not e.dnf and not recovered[i] and not _pitting(i):
			return i
	return -1


## Is car i the one leading the field to the restart (SC already gone)?
func controls_restart(i: int) -> bool:
	return mode == Mode.SC and stage == "restart" and sc_train_leader() == i


## A short line for the HUD about what car i must do (empty = nothing).
func instruction_for(i: int) -> String:
	if i < 0 or i >= sim.cars.size():
		return ""
	if give_back.has(i):
		var g: Dictionary = give_back[i]
		var left := maxf(float(g["until"]) - sim.race_time, 0.0)
		var who := "the safety car" if int(g["victim"]) == -2 else sim.entries[int(g["victim"])].driver_name
		return "Give the place back to %s  (%d s)" % [who, ceili(left)]
	match mode:
		Mode.VSC:
			return "VSC ENDING - get ready" if stage == "ending" else "VIRTUAL SAFETY CAR  delta %+.1f" % vsc_delta[i]
		Mode.SC:
			if unlapping[i]:
				return "SAFETY CAR - lapped cars may overtake: unlap yourself"
			match stage:
				"in_this_lap": return "SAFETY CAR IN THIS LAP"
				"restart":
					if controls_restart(i):
						return "Restart: you control the pace, go when ready"
					return "RESTART - no overtaking until the line" if not released[i] else ""
			return "SAFETY CAR - no overtaking, close up"
	if yellow_at(sim.cars[i].track_s):
		return "YELLOW FLAG - slow down, no overtaking"
	if not released[i]:
		return "RESTART - no overtaking until the line"
	return ""


# --- Authority: decide ------------------------------------------------------

## Race director override (host only): send out the safety car or the VSC
## now, e.g. from a debug option or a future host command.
## Called between steps, so its events go out with the next step.
func deploy_safety_car(why := "Race director") -> void:
	if not sim.follower and sim.phase == RaceSim.Phase.RACING and mode != Mode.SC:
		var n := sim.events.size()
		_deploy_sc(why)
		_post_new_events(n)


func deploy_vsc(why := "Race director") -> void:
	if not sim.follower and sim.phase == RaceSim.Phase.RACING and mode == Mode.GREEN:
		var n := sim.events.size()
		_deploy_vsc(why)
		_post_new_events(n)


func _post_new_events(from: int) -> void:
	var fresh := sim.events.slice(from)
	sim.events.resize(from)
	for e in fresh:
		sim.post_event(e)


## Called by RaceSim.step on the authority after positions are updated.
func step(dt: float, prev_s: PackedFloat64Array) -> void:
	mode_time += dt
	stage_time += dt
	var racing := sim.phase == RaceSim.Phase.RACING
	if sim.phase == RaceSim.Phase.CHEQUERED or sim.phase == RaceSim.Phase.FINISHED:
		if mode != Mode.GREEN or not yellows.is_empty() or sc_visible:
			_end_all_on_chequered()
		_update_safety_car(dt)
		_update_recoveries(dt)
		return
	if not racing:
		return
	_read_incidents()
	_track_stranded(dt)
	_update_recoveries(dt)
	_expire_yellows()
	_escalate()
	_update_mode()
	_update_safety_car(dt)
	_update_vsc_delta(dt, prev_s)
	_update_released(prev_s)
	_check_overtakes()
	_update_unlapping()


func _read_incidents() -> void:
	for e in sim.events:
		var t: String = e.get("type", "")
		var sev := 0.0
		if t == "incident":
			sev = float(e.get("severity", 0.0))
		elif t == "collision":
			sev = clampf(float(e.get("impulse", 0.0)) / 16000.0, 0.0, 1.0)
		else:
			continue
		if sev < 0.25:
			continue
		var car := int(e.get("car", e.get("a", -1)))
		var s: float = sim.cars[car].track_s if car >= 0 and car < sim.cars.size() else 0.0
		if e.has("pos") and e["pos"] is Vector2:
			s = sim.track.project(e["pos"])["s"]
		_add_yellow(s, car, "Incident")
		if sev >= 0.85:
			_big_incident_until = sim.race_time + 8.0


func _track_stranded(dt: float) -> void:
	for i in sim.cars.size():
		var c := sim.cars[i]
		var e := sim.entries[i]
		if recovered[i] or e.finished or _pitting(i):
			stranded_t[i] = 0.0
			continue
		var stopped := c.speed() < STOPPED_SPEED or e.dnf
		if stopped and (e.started_lap or sim.race_time > 15.0):
			stranded_t[i] += dt
		elif c.speed() > MOVING_AGAIN:
			stranded_t[i] = 0.0
			_cleared[i] = 0
		if stranded_t[i] >= STRANDED_YELLOW_S:
			_add_yellow(c.track_s, i, "Car stopped")
		if e.dnf:
			# A retired car: send a crane or a tractor once it has come to rest.
			if stranded_t[i] >= STRANDED_VSC_S and c.speed() < STOPPED_SPEED and recovery_for(i).is_empty():
				_dispatch_recovery(i)
			continue
		var limit := RECOVERY_SC_S if mode == Mode.SC else RECOVERY_VSC_S
		if stranded_t[i] > limit + STRANDED_VSC_S:
			_cleared[i] = 1  # a live car the marshals have pushed clear: yellow flag only
			stranded_t[i] = STRANDED_YELLOW_S


# --- Recovery vehicles ---------------------------------------------------------

func _dispatch_recovery(i: int) -> void:
	var c := sim.cars[i]
	var job := CarRecovery.plan(sim.track, i, c.pos, c.heading, c.track_s, c.lateral_offset, sim.defs[i].length)
	recoveries.append(job)
	var what := "Crane" if job["kind"] == CarRecovery.CRANE else "Tractor"
	_event({"type": "flag", "flag": "recovery", "car": i, "kind": job["kind"],
		"reason": "%s sent to recover %s's car" % [what, sim.entries[i].driver_name]})


func _update_recoveries(dt: float) -> void:
	var k := 0
	while k < recoveries.size():
		var job: Dictionary = recoveries[k]
		var i: int = job["car"]
		CarRecovery.step(job, dt)
		if job["carrying"] and not recovered[i]:
			if sim.external[i]:
				recovered[i] = 1  # simulated on its owner's machine: just take it off
			else:
				carried[i] = 1
				_carry(i, job)
		if job["done"]:
			if not recovered[i]:
				recovered[i] = 1
				var how := "craned away" if job["kind"] == CarRecovery.CRANE else "towed away"
				_event({"type": "flag", "flag": "recovered", "car": i,
					"reason": "%s's car has been %s" % [sim.entries[i].driver_name, how]})
			carried[i] = 0
			stranded_t[i] = 0.0
			recoveries.remove_at(k)
			continue
		k += 1


## Puts the car where the recovery vehicle has it.
func _carry(i: int, job: Dictionary) -> void:
	var c := sim.cars[i]
	c.pos = job["car_pos"]
	c.heading = job["car_heading"]
	c.vel = Vector2.from_angle(c.heading) * float(job["speed"]) if job["kind"] == CarRecovery.TRACTOR else Vector2.ZERO
	c.yaw_rate = 0.0
	var q := sim.track.project(c.pos, c.track_idx)
	c.track_idx = q["idx"]
	c.track_s = q["s"]
	c.lateral_offset = q["offset"]


func _on_racing_surface(i: int) -> bool:
	var s := sim.cars[i].surface
	return s == TrackData.Surface.TRACK or s == TrackData.Surface.KERB


func _escalate() -> void:
	var danger := 0.0
	var stranded := 0
	var recovering := 0
	for i in sim.cars.size():
		var t := stranded_t[i]
		if t < STRANDED_YELLOW_S:
			continue
		stranded += 1
		if _cleared[i]:
			continue
		var on_track := _on_racing_surface(i)
		if sim.entries[i].dnf:
			# A retired car out on the circuit needs a recovery vehicle on
			# track: safety car until the car is clear.
			var job := recovery_for(i)
			if t >= STRANDED_VSC_S and (job.is_empty() or not CarRecovery.car_clear(job)):
				danger = maxf(danger, 2.0)
				recovering += 1
		elif on_track and t >= STRANDED_SC_S:
			danger = maxf(danger, 2.0)
		elif on_track and t >= STRANDED_VSC_S:
			danger = maxf(danger, 1.0)
	var live := 0
	for i in sim.cars.size():
		if stranded_t[i] >= STRANDED_YELLOW_S and not _cleared[i] and not _clear_retired(i):
			live += 1
	if live >= 3:
		danger = 2.0
	elif live == 2:
		danger = maxf(danger, 1.0)
	if _big_incident_until > sim.race_time and live > 0:
		danger = 2.0
	_danger = danger
	if not enabled:
		return
	var final_lap := _leader_laps() >= sim.settings.laps - 1
	if danger >= 2.0 and mode != Mode.SC and not final_lap:
		_deploy_sc("Recovery vehicle on track" if recovering > 0 else ("Car stopped on track" if stranded < 2 else "Multiple cars stopped"))
	elif danger >= 1.0 and mode == Mode.GREEN:
		_deploy_vsc("Car stopped" if stranded == 1 else "Incident")


## A retired car that a recovery vehicle has already got off the circuit.
func _clear_retired(i: int) -> bool:
	if not sim.entries[i].dnf:
		return false
	var job := recovery_for(i)
	return recovered[i] == 1 or (not job.is_empty() and CarRecovery.car_clear(job))


func _deploy_vsc(why: String) -> void:
	_set_mode(Mode.VSC, "", why)
	vsc_delta.fill(0.0)
	vsc_warned.fill(0)
	vsc_penalised.fill(0)
	_event({"type": "safety_car", "state": "vsc", "reason": why})


func _deploy_sc(why: String) -> void:
	_set_mode(Mode.SC, "out", why)
	deployments += 1
	sc_laps = 0
	_leader_laps_at = _leader_laps()
	wave_by = false
	unlapping.fill(0)
	var lead := sc_train_leader()
	var lead_s: float = sim.cars[lead].track_s if lead >= 0 else 0.0
	sc_s = fposmod(lead_s + SC_SPAWN_AHEAD, sim.track.length)
	var t := sim.track
	if t.has_pit_lane():
		# Come out of the pit lane if the exit is just ahead of the leader.
		var ahead := fposmod(t.pit_exit_s - lead_s, t.length)
		if ahead > 60.0 and ahead < 700.0:
			sc_s = t.pit_exit_s
	sc_in_pit = false
	sc_visible = true
	sc_speed = sc_speed_at(sc_s) * 0.6
	sc_lights = "amber"
	_place_sc()
	for i in sim.cars.size():
		_sc_behind[i] = 1 if fposmod(sc_s - sim.cars[i].track_s, t.length) < t.length * 0.5 else 0
	_event({"type": "safety_car", "state": "sc", "reason": why})


func _set_mode(m: int, st: String, why: String) -> void:
	mode = m
	mode_time = 0.0
	stage = st
	stage_time = 0.0
	reason = why


func _update_mode() -> void:
	match mode:
		Mode.VSC:
			if stage == "" and _danger < 1.0 and mode_time >= VSC_MIN_S:
				stage = "ending"
				stage_time = 0.0
				_event({"type": "safety_car", "state": "vsc_ending", "reason": "Track clear"})
			elif stage == "ending" and stage_time >= VSC_ENDING_S:
				_go_green("VSC over")
			if not enabled:
				_go_green("Safety car switched off")
		Mode.SC:
			var laps := _leader_laps()
			sc_laps = laps - _leader_laps_at
			var final_lap := laps >= sim.settings.laps - 1
			if stage == "out":
				var clear := _danger < 1.0
				if clear and not wave_by and sc_laps >= 1 and _any_lapped():
					wave_by = true
					_mark_unlappers()
					_event({"type": "safety_car", "state": "lapped_may_overtake", "reason": "Lapped cars may now overtake"})
				var unlap_done := not wave_by or not _any_unlapping() or stage_time > 240.0
				if (clear and sc_laps >= 1 and unlap_done and _field_bunched()) or (clear and sc_laps >= 2 and unlap_done) \
						or (clear and sc_laps >= 4) or final_lap:
					stage = "in_this_lap"
					stage_time = 0.0
					sc_lights = "green"
					_event({"type": "safety_car", "state": "in_this_lap", "reason": "Safety car in this lap"})
			elif stage == "restart":
				var lead := sc_train_leader()
				if lead < 0 or sim.entries[lead].laps_done > _restart_lap:
					_go_green("Restart")


var _restart_lap: int = 0


func _go_green(why: String) -> void:
	_set_mode(Mode.GREEN, "", why)
	wave_by = false
	unlapping.fill(0)
	sc_lights = "off"
	_event({"type": "safety_car", "state": "green", "reason": why})


func _end_all_on_chequered() -> void:
	if mode != Mode.GREEN:
		_set_mode(Mode.GREEN, "", "Chequered flag")
	yellows.clear()
	give_back.clear()
	unlapping.fill(0)
	released.fill(1)
	if sc_visible and not sc_in_pit:
		_send_sc_to_pits()


# --- The safety car ---------------------------------------------------------

func _update_safety_car(dt: float) -> void:
	if not sc_visible:
		return
	var t := sim.track
	if sc_in_pit:
		sc_speed = move_toward(sc_speed, SC_PIT_SPEED, SC_DECEL * dt)
		sc_s += sc_speed * dt
		if sc_s >= t.pit_length:
			sc_visible = false
			sc_in_pit = false
			sc_lights = "off"
		_place_sc()
		return
	var target := sc_speed_at(sc_s)
	# Look ahead so the SC brakes for corners in time.
	for k in range(1, 6):
		var s2 := sc_s + k * 20.0
		var v2 := sc_speed_at(s2)
		target = minf(target, sqrt(v2 * v2 + 2.0 * SC_DECEL * k * 20.0))
	var lead := sc_train_leader()
	if lead >= 0 and stage == "out":
		var gap := fposmod(sc_s - sim.cars[lead].track_s, t.length)
		if gap > t.length * 0.5:
			gap = 0.0  # the leader has gone past: carry on at pace
		if gap > SC_GAP_TARGET * 3.0:
			target *= 0.55  # wait for the leader to catch up
		elif gap > SC_GAP_TARGET * 1.5:
			target *= 0.8
	var acc := 4.0 if target > sc_speed else SC_DECEL
	sc_speed = move_toward(sc_speed, target, acc * dt)
	var prev := sc_s
	sc_s = fposmod(sc_s + sc_speed * dt, t.length)
	if stage == "in_this_lap" and _crossed(prev, sc_s, _peel_off_s()):
		_send_sc_to_pits()
		stage = "restart"
		stage_time = 0.0
		_restart_lap = sim.entries[lead].laps_done if lead >= 0 else 0
		released.fill(0)
		_event({"type": "safety_car", "state": "restart", "reason": "Safety car in, the leader controls the restart"})
	_place_sc()


## Off the circuit: down the pit lane when there is one, else gone.
func _send_sc_to_pits() -> void:
	sc_lights = "off"
	if sim.track.has_pit_lane():
		sc_in_pit = true
		sc_s = 0.0
		sc_speed = minf(sc_speed, 30.0)
	else:
		sc_visible = false


## Where the SC leaves the track: the pit entry when it's near the end of
## the lap, otherwise a bit before the line.
func _peel_off_s() -> float:
	var t := sim.track
	if t.has_pit_lane() and t.pit_entry_s > t.length * 0.6:
		return t.pit_entry_s
	return t.length - 300.0


func _place_sc() -> void:
	var t := sim.track
	if sc_in_pit:
		sc_pos = t.pit_position_at(sc_s)
		sc_heading = t.pit_heading_at(sc_s)
	else:
		sc_pos = t.position_at(sc_s)
		sc_heading = t.heading_at(sc_s + 4.0)


## Client: carry the SC along between race-state updates.
func follower_step(dt: float) -> void:
	for job in recoveries:
		CarRecovery.step(job, dt)
	if not sc_visible:
		return
	if sc_in_pit:
		sc_s = minf(sc_s + sc_speed * dt, sim.track.pit_length)
	else:
		sc_s = fposmod(sc_s + sc_speed * dt, sim.track.length)
	_place_sc()
	mode_time += dt
	stage_time += dt


# --- Rules ------------------------------------------------------------------

func _update_vsc_delta(dt: float, prev_s: PackedFloat64Array) -> void:
	if mode != Mode.VSC:
		return
	var L := sim.track.length
	for i in sim.cars.size():
		var e := sim.entries[i]
		if e.finished or e.dnf or _pitting(i) or stranded_t[i] > 0.0:
			continue
		var ds := sim.cars[i].track_s - prev_s[i]
		if ds < -L * 0.5:
			ds += L
		elif ds > L * 0.5:
			ds -= L
		var ref := maxf(vsc_speed_at(sim.cars[i].track_s), 5.0)
		vsc_delta[i] = minf(vsc_delta[i] + dt - maxf(ds, 0.0) / ref, 4.0)
		if vsc_delta[i] < VSC_DELTA_WARN and not vsc_warned[i]:
			vsc_warned[i] = 1
			_event({"type": "warning", "car": i, "text": "Too fast under the VSC, keep the delta positive"})
		if vsc_delta[i] < VSC_DELTA_PENALTY and not vsc_penalised[i]:
			vsc_penalised[i] = 1
			sim.add_penalty(i, PENALTY_S, "Speeding under the virtual safety car")


func _update_released(prev_s: PackedFloat64Array) -> void:
	for i in sim.cars.size():
		if not released[i] and _crossed(prev_s[i], sim.cars[i].track_s, 0.0):
			released[i] = 1


func _check_overtakes() -> void:
	var order := _settled_order()
	if _prev_order.size() != order.size():
		_prev_order = order.duplicate()
		return
	var neutral := mode != Mode.GREEN
	var prev_pos := {}
	for p in _prev_order.size():
		prev_pos[_prev_order[p]] = p
	for p in order.size():
		var i := order[p]
		if not prev_pos.has(i) or prev_pos[i] <= p:
			continue
		# i moved up: check each car it got ahead of.
		for q in range(p + 1, order.size()):
			var j := order[q]
			if prev_pos[j] >= prev_pos[i]:
				continue
			if may_pass(i, j) or _lapped_pair(i, j):
				continue
			var why := ""
			if mode == Mode.SC:
				why = "Overtaking under the safety car"
			elif mode == Mode.VSC:
				why = "Overtaking under the virtual safety car"
			elif not released[i]:
				why = "Overtaking before the restart line"
			elif yellow_at(sim.cars[i].track_s) or yellow_at(sim.cars[j].track_s):
				why = "Overtaking under yellow flags"
			if why == "" or give_back.has(i):
				continue
			give_back[i] = {"victim": j, "until": sim.race_time + GIVE_BACK_S, "why": why}
			_event({"type": "warning", "car": i, "victim": j,
				"text": "%s: give the place back to %s" % [why, sim.entries[j].driver_name]})
	_prev_order = order.duplicate()
	_check_sc_passes(neutral)
	# Settle the give-backs.
	for i in give_back.keys():
		var g: Dictionary = give_back[i]
		var j := int(g["victim"])
		var gave_back := false
		if j == -2:
			gave_back = gap_to_sc(i) < sim.track.length * 0.5 or not sc_visible or sc_in_pit
		else:
			gave_back = sim.entries[j].distance > sim.entries[i].distance + 3.0 or sim.entries[j].dnf or sim.entries[j].finished
		if gave_back:
			give_back.erase(i)
			_event({"type": "warning", "car": i, "text": "Place given back, no further action"})
		elif sim.race_time >= float(g["until"]):
			give_back.erase(i)
			sim.add_penalty(i, PENALTY_S, String(g["why"]))


## The running order, except that cars within a few metres of each other
## keep the order they had, so side-by-side wheel-banging isn't a string of
## overtakes and give-backs.
func _settled_order() -> Array[int]:
	var order: Array[int] = sim.running_order.duplicate()
	if _prev_order.size() != order.size():
		return order
	var rank := {}
	for p in _prev_order.size():
		rank[_prev_order[p]] = p
	for _pass in 2:
		for p in order.size() - 1:
			var a := order[p]
			var b := order[p + 1]
			if rank[b] < rank[a] and sim.entries[a].distance - sim.entries[b].distance < 3.0 \
					and not sim.entries[a].finished and not sim.entries[b].finished:
				order[p] = b
				order[p + 1] = a
	return order


## Passing the safety car itself is only for lapped cars that were waved by.
func _check_sc_passes(neutral: bool) -> void:
	if not sc_visible or sc_in_pit or not neutral:
		_sc_behind.fill(0)
		return
	var L := sim.track.length
	for i in sim.cars.size():
		var gap := fposmod(sc_s - sim.cars[i].track_s, L)
		var behind := gap < L * 0.5
		var close := gap < 60.0 or gap > L - 60.0
		if _sc_behind[i] and not behind and close and not unlapping[i] and not _pitting(i) \
				and not sim.entries[i].finished and not give_back.has(i):
			give_back[i] = {"victim": -2, "until": sim.race_time + GIVE_BACK_S, "why": "Passing the safety car"}
			_event({"type": "warning", "car": i, "victim": -2, "text": "Passing the safety car: drop back behind it"})
		_sc_behind[i] = 1 if behind else 0


## Lead-lap cars passing lapped ones (or the other way) don't change the
## race order, so they're not overtakes for the rules.
func _lapped_pair(i: int, j: int) -> bool:
	return absf(sim.entries[i].distance - sim.entries[j].distance) > sim.track.length * 0.5


func _mark_unlappers() -> void:
	var lead := sc_train_leader()
	if lead < 0:
		return
	var D := sim.entries[lead].distance
	for i in sim.cars.size():
		var e := sim.entries[i]
		if e.finished or e.dnf or recovered[i]:
			continue
		var rel := e.distance - D
		if rel < -sim.track.length * 0.5:
			unlapping[i] = 1
			unlap_from[i] = rel


func _update_unlapping() -> void:
	if mode != Mode.SC:
		return
	var lead := sc_train_leader()
	if lead < 0:
		return
	var D := sim.entries[lead].distance
	for i in sim.cars.size():
		if unlapping[i] and sim.entries[i].distance - D - unlap_from[i] > sim.track.length * 0.6:
			unlapping[i] = 0
			_event({"type": "warning", "car": i, "text": "Unlapped: join the back of the queue"})


func _any_lapped() -> bool:
	var lead := sc_train_leader()
	if lead < 0:
		return false
	for i in sim.cars.size():
		var e := sim.entries[i]
		if not e.finished and not e.dnf and not recovered[i] and e.distance < sim.entries[lead].distance - sim.track.length * 0.5:
			return true
	return false


func _any_unlapping() -> bool:
	for u in unlapping:
		if u:
			return true
	return false


## The lead-lap cars are lined up close behind the SC.
func _field_bunched() -> bool:
	var lead := sc_train_leader()
	if lead < 0:
		return true
	var D := sim.entries[lead].distance
	var count := 0
	for i in sim.cars.size():
		var e := sim.entries[i]
		if e.finished or e.dnf or recovered[i] or _pitting(i) or unlapping[i]:
			continue
		var rel := D - e.distance
		if rel > sim.track.length * 0.5:
			continue  # lapped
		count += 1
		if rel > 25.0 + 14.0 * count:
			return false
	return true


func _leader_laps() -> int:
	var lead := sc_train_leader()
	return sim.entries[lead].laps_done if lead >= 0 else 0


# --- Helpers ----------------------------------------------------------------

func _add_yellow(s: float, car: int, why: String) -> void:
	var L := sim.track.length
	var from := fposmod(s - YELLOW_HALF_M, L)
	var to := fposmod(s + YELLOW_HALF_M * 0.5, L)
	for y in yellows:
		if y["car"] == car and car >= 0:
			y["from"] = from
			y["to"] = to
			y["until"] = sim.race_time + YELLOW_HOLD_S
			return
	yellows.append({"from": from, "to": to, "until": sim.race_time + YELLOW_HOLD_S, "car": car})
	_event({"type": "flag", "flag": "yellow", "car": car, "zone_s": [from, to],
		"reason": why if car < 0 else "%s (%s)" % [why, sim.entries[car].driver_name]})


func _expire_yellows() -> void:
	var keep := []
	for y in yellows:
		if y["until"] > sim.race_time:
			keep.append(y)
		else:
			_event({"type": "flag", "flag": "clear", "car": y["car"], "zone_s": [y["from"], y["to"]], "reason": "Yellow flag withdrawn"})
	yellows = keep


static func _in_zone(s: float, from: float, to: float) -> bool:
	if from <= to:
		return s >= from and s <= to
	return s >= from or s <= to


## Did a car going from a to b (track distances) cross point x?
func _crossed(a: float, b: float, x: float) -> bool:
	var L := sim.track.length
	var d := fposmod(b - a, L)
	if d > L * 0.5:
		return false
	return fposmod(x - a, L) <= d and d > 0.0


func _pitting(i: int) -> bool:
	if sim.has_method("in_pit_lane"):
		return sim.call("in_pit_lane", i)
	return sim.track.has_pit_lane() and sim.track.in_pit_lane(sim.cars[i].pos)


func _event(e: Dictionary) -> void:
	e["lap"] = _leader_laps() + 1
	sim.events.append(e)


func _build_profiles() -> void:
	var t := sim.track
	var n := t.point_count()
	if n < 3:
		return
	var curv := PackedFloat64Array()
	curv.resize(n)
	for i in n:
		var a := t.seg_dir[(i - 1 + n) % n]
		var b := t.seg_dir[i]
		var ds := maxf((t.seg_len[(i - 1 + n) % n] + t.seg_len[i]) * 0.5, 0.5)
		curv[i] = absf(a.angle_to(b)) / ds
	# Smooth over about 30 m so kinks in the data don't make phantom corners.
	var smooth := PackedFloat64Array()
	smooth.resize(n)
	for i in n:
		var sum := 0.0
		var w := 0.0
		for o in range(-3, 4):
			sum += curv[(i + o + n) % n]
			w += 1.0
		smooth[i] = sum / w
	_sc_profile = _profile(smooth, SC_MAX_SPEED, SC_LAT_ACCEL, SC_DECEL)
	_vsc_profile = _profile(smooth, VSC_MAX_SPEED, VSC_LAT_ACCEL, SC_DECEL + 1.5)


func _profile(curv: PackedFloat64Array, vmax: float, lat: float, decel: float) -> PackedFloat64Array:
	var t := sim.track
	var n := curv.size()
	var v := PackedFloat64Array()
	v.resize(n)
	for i in n:
		v[i] = minf(vmax, sqrt(lat / maxf(curv[i], 1e-5)))
	# Braking: twice round so the wrap at the line is covered.
	for _pass in 2:
		for j in n:
			var i := n - 1 - j
			var nxt := v[(i + 1) % n]
			v[i] = minf(v[i], sqrt(nxt * nxt + 2.0 * decel * t.seg_len[i]))
	return v


# --- Replication ------------------------------------------------------------

## Full state for snapshots (late join, replays); race_state() sends the
## lighter version without the bookkeeping.
func to_dict(full := false) -> Dictionary:
	var d := {
		"mode": mode, "mode_time": mode_time, "reason": reason, "stage": stage, "stage_time": stage_time,
		"wave_by": wave_by, "sc_laps": sc_laps, "deployments": deployments,
		"sc_visible": sc_visible, "sc_s": sc_s, "sc_in_pit": sc_in_pit, "sc_speed": sc_speed, "sc_lights": sc_lights,
		"yellows": yellows.duplicate(true), "vsc_delta": vsc_delta.duplicate(),
		"unlapping": unlapping.duplicate(), "released": released.duplicate(), "recovered": recovered.duplicate(),
		"give_back": give_back.duplicate(true), "restart_lap": _restart_lap,
		"recoveries": recoveries.duplicate(true), "carried": carried.duplicate(),
	}
	if full:
		d["full"] = {"stranded_t": stranded_t.duplicate(), "cleared": _cleared.duplicate(),
			"vsc_warned": vsc_warned.duplicate(), "vsc_penalised": vsc_penalised.duplicate(),
			"unlap_from": unlap_from.duplicate(), "prev_order": _prev_order.duplicate(),
			"sc_behind": _sc_behind.duplicate(), "big_until": _big_incident_until,
			"leader_laps_at": _leader_laps_at, "danger": _danger}
	return d


func apply_dict(d: Dictionary) -> void:
	mode = d.get("mode", Mode.GREEN)
	mode_time = d.get("mode_time", 0.0)
	reason = d.get("reason", "")
	stage = d.get("stage", "")
	stage_time = d.get("stage_time", 0.0)
	wave_by = d.get("wave_by", false)
	sc_laps = d.get("sc_laps", 0)
	deployments = d.get("deployments", 0)
	sc_visible = d.get("sc_visible", false)
	sc_s = d.get("sc_s", 0.0)
	sc_in_pit = d.get("sc_in_pit", false)
	sc_speed = d.get("sc_speed", 0.0)
	sc_lights = d.get("sc_lights", "off")
	yellows = d.get("yellows", []).duplicate(true)
	_restart_lap = d.get("restart_lap", 0)
	give_back = d.get("give_back", {}).duplicate(true)
	recoveries = d.get("recoveries", []).duplicate(true)
	for k in ["vsc_delta", "unlapping", "released", "recovered", "carried"]:
		if d.has(k) and d[k].size() == get(k).size():
			set(k, d[k].duplicate())
	if d.has("full"):
		var f: Dictionary = d["full"]
		stranded_t = f["stranded_t"].duplicate()
		_cleared = f["cleared"].duplicate()
		vsc_warned = f["vsc_warned"].duplicate()
		vsc_penalised = f["vsc_penalised"].duplicate()
		unlap_from = f["unlap_from"].duplicate()
		_prev_order.assign(f["prev_order"])
		_sc_behind = f["sc_behind"].duplicate()
		_big_incident_until = f["big_until"]
		_leader_laps_at = f["leader_laps_at"]
		_danger = f["danger"]
	if sc_visible:
		_place_sc()
