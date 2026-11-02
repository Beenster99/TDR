class_name PitRules
extends RefCounted
## Pit lane and pit stops: the pit limiter and speed limit, driving through the
## lane, the stop in the car's box (new tyres, fuel, repairs), counting the
## mandatory stops inside the pit window, and the penalties for speeding in the
## pit lane or missing a mandatory stop. Held by the race as RaceSim.pits.
##
## How a stop works:
##  * "Box this lap" (AI strategy, the player's box button, or a co-op pit
##    crew / strategist) sets the car's pit plan and its box flag. From about
##    300 m before the pit entry the car is then driven in automatically.
##  * A player can also just drive into the pit lane. They must be at the
##    speed limit by the limit line (the pit limiter button caps the speed),
##    or get a time penalty. From the limit line the car is guided to its box.
##  * In the box the crew works for the stop time (service_time), then the
##    car is guided to the end of the speed limit. AI cars are driven to the
##    end of the lane; players take over again at the limit line.
##
## Multiplayer: a car's pit state lives in RaceEntry.pit and belongs to the
## machine that simulates the car (like its physics). That machine runs the
## pit lane for its cars and sends the pit state to the host when it changes;
## the host counts stops, hands out penalties, raises the pit events and
## shares every car's pit state with everyone in the race state. Plan changes
## from other crew members go through the host to the car's owner.

const LIMIT_TOLERANCE := 1.0     ## m/s over the limit before it counts as speeding
const SPEEDING_PENALTY_S := 5.0
const MISSED_STOP_PENALTY_S := 60.0
const COMMIT_BEFORE_ENTRY := 320.0  ## m before the pit entry the car is driven in
const ROUTE_STEP := 3.0
const MANUAL_ENTRY_MARGIN := 3.0 ## m beyond the track edge that counts as taking the pit lane
const LANE_END_SKIP := 12.0      ## m of the lane's ends the guide cuts
const BRAKE_DECEL := 6.0         ## m/s^2 the guide plans to brake at
const ROUTE_GRIP := 1.4          ## tyre grip the route's speeds are planned for
const BOX_DECEL := 3.5
const LATERAL_G := 10.0          ## m/s^2 the guide plans to corner at
const ROUTE_MAX_SPEED := 75.0
## Stop time: the car up and down, a set of four tyres, fuel flow. Tyres and
## fuel are done at the same time; repairs come after.
const STOP_BASE_S := 2.5
const TYRE_CHANGE_S := 6.0
const FUEL_FLOW_LPS := 3.0
## Co-op driver change in the box: the stop lasts at least this long from
## the moment the drivers swap (done alongside tyres and fuel).
const DRIVER_CHANGE_S := 5.0

const PHASE_NONE := ""
const PHASE_APPROACH := "approach"  ## being driven to the pit entry (box requested)
const PHASE_ENTRY := "entry"        ## in the lane, before the limit line
const PHASE_LIMIT := "limit"        ## at the limit, heading for the box
const PHASE_SERVICE := "service"    ## stopped in the box
const PHASE_LEAVE := "leave"        ## from the box to the end of the limit
const PHASE_EXIT := "exit"          ## after the limit, back to the track
const IN_LANE := [PHASE_ENTRY, PHASE_LIMIT, PHASE_SERVICE, PHASE_LEAVE, PHASE_EXIT]

## Tyre choices in a pit plan.
const TYRE_AUTO := "auto"    ## suit the conditions
const TYRE_KEEP := "keep"
const TYRE_DRY := "dry"      ## the car's own dry compound
const TYRE_INTER := "intermediate"
const TYRE_WET := "full_wet"
const TYRE_CHOICES := [TYRE_AUTO, TYRE_DRY, TYRE_INTER, TYRE_WET, TYRE_KEEP]
## Fuel in a pit plan: litres to add, or one of these.
const FUEL_AUTO := -1.0      ## enough to finish
const FUEL_NONE := 0.0

var sim: RaceSim
var enabled := false             ## the track has a pit lane
## The guided route: from COMMIT_BEFORE_ENTRY before the pit entry, along the
## pit side of the track, then the whole pit lane. Route metres.
var route: PackedVector2Array = []
var route_cum: PackedFloat64Array = []
var route_speed: PackedFloat64Array = []
var route_len := 0.0
var lane_start := 0.0            ## route metres where the pit lane begins
var limit_start := 0.0           ## route metres of the limit lines
var limit_end := 0.0
var commit_s := 0.0              ## track distance where a boxing car is taken over
var route_time := 0.0            ## seconds to drive the whole route without stopping
var route_track_m := 0.0         ## track distance the route replaces
var window_open := 1             ## pit window, in laps (inclusive)
var window_close := 1

var _route_k: PackedInt32Array = []
var _box: PackedInt32Array = []
var _prev_s: PackedFloat64Array = []
var _lap_fuel: PackedFloat64Array = []
var _sent: Array = []            ## host: last pit state seen per car (events, penalties)


func _init(p_sim: RaceSim) -> void:
	sim = p_sim
	var t := sim.track
	enabled = t.has_pit_lane()
	_compute_window()
	var n := sim.car_count()
	for i in n:
		_route_k.append(0)
		_box.append(int(float(i) * t.pit_box_count / maxf(n, 1)) if enabled else 0)
		_prev_s.append(sim.cars[i].track_s)
		_lap_fuel.append(sim.cars[i].fuel_l)
		_sent.append(sim.entries[i].pit.duplicate(true))
	if enabled:
		_build_route()


static func new_state(compound_id: String) -> Dictionary:
	return {
		"phase": PHASE_NONE, "auto": false, "box": false, "limiter": false,
		"service_left": 0.0, "service_total": 0.0, "work": {},
		"plan": {"tyre": TYRE_AUTO, "fuel": FUEL_AUTO, "repair": true},
		"compound": compound_id, "stops": 0, "window_stops": 0, "speeding": 0,
		"stint_lap": 0, "lane_time": 0.0, "entry_lap": 0, "fuel_per_lap": 0.0, "last_stop": {},
	}


## The pit window never includes the last lap: the boxes are past the finish
## line, so a car that came in on the last lap would finish before its stop.
func _compute_window() -> void:
	var laps := maxi(sim.settings.laps, 1)
	var last := maxi(laps - 1, 1)
	var margin := roundi(laps * 0.2)
	window_open = clampi(sim.settings.pit_window_open_lap if sim.settings.pit_window_open_lap > 0 else margin + 1, 1, last)
	window_close = clampi(sim.settings.pit_window_close_lap if sim.settings.pit_window_close_lap > 0 else laps - maxi(margin, 1), window_open, last)


## Lap number (1 = first lap) in which car i is now.
func current_lap(i: int) -> int:
	return sim.entries[i].laps_done + 1


func in_window(lap: int) -> bool:
	return lap >= window_open and lap <= window_close


## Mandatory stops car i still has to make (none in a one-lap race).
func mandatory_left(i: int) -> int:
	if sim.settings.laps < 2:
		return 0
	return maxi(sim.settings.mandatory_pit_stops - int(sim.entries[i].pit["window_stops"]), 0)


func phase(i: int) -> String:
	return sim.entries[i].pit["phase"]


func in_pit_lane(i: int) -> bool:
	return phase(i) in IN_LANE


## True while the pit guide drives car i (its driver's input is ignored).
func controls(i: int) -> bool:
	var p: Dictionary = sim.entries[i].pit
	match p["phase"]:
		PHASE_APPROACH, PHASE_LIMIT, PHASE_SERVICE, PHASE_LEAVE:
			return true
		PHASE_ENTRY, PHASE_EXIT:
			return p["auto"]
	return false


# --- Plans (driver, pit crew, strategist or AI) -------------------------------

## Changes car i's pit plan and/or box flag. Only takes effect on the machine
## that simulates the car: RaceSession routes requests from elsewhere there.
## changes: any of {box: bool, tyre: String, fuel: float, repair: bool}
func set_plan(i: int, changes: Dictionary) -> void:
	var p: Dictionary = sim.entries[i].pit
	var plan: Dictionary = p["plan"]
	if changes.has("box") and p["phase"] == PHASE_NONE:
		p["box"] = bool(changes["box"]) and enabled
	if changes.has("tyre") and str(changes["tyre"]) in TYRE_CHOICES:
		plan["tyre"] = str(changes["tyre"])
	if changes.has("fuel"):
		plan["fuel"] = maxf(float(changes["fuel"]), FUEL_AUTO)
	if changes.has("repair"):
		plan["repair"] = bool(changes["repair"])


func set_limiter(i: int, on: bool) -> void:
	sim.entries[i].pit["limiter"] = on


## Fuel (litres) a car burns per lap: measured once it has done a lap,
## estimated from the car and track before that. 0 when fuel is off.
func fuel_per_lap(i: int) -> float:
	if not sim.settings.fuel_enabled:
		return 0.0
	var measured: float = sim.entries[i].pit["fuel_per_lap"]
	if measured > 0.0:
		return measured
	var d := sim.defs[i]
	var lap_s := sim.track.length / 42.0
	return d.peak_power_kw() * 0.55 * d.bsfc_l_per_kwh / 3600.0 * lap_s * sim.settings.fuel_rate


## Laps the fuel on board lasts (INF when fuel is off).
func fuel_laps(i: int) -> float:
	var fpl := fuel_per_lap(i)
	return INF if fpl <= 0.0 else sim.cars[i].fuel_l / fpl


## Laps car i still has to drive after the current one is done.
func laps_after_this(i: int) -> int:
	return maxi(sim.settings.laps - current_lap(i), 0)


## The compound "auto" would fit right now.
func compound_for_conditions(i: int) -> String:
	var w := sim.env.wetness
	if w > 0.55 or sim.env.rain > 0.6:
		return TYRE_WET
	if w > 0.18:
		return TYRE_INTER
	return sim.dry_compound[i]


func _plan_compound(i: int, plan: Dictionary) -> String:
	match plan["tyre"]:
		TYRE_KEEP: return ""
		TYRE_AUTO: return compound_for_conditions(i)
		TYRE_DRY: return sim.dry_compound[i]
	return plan["tyre"]


## What a stop with this plan would do and how long it would take now:
## {tyre: compound id or "", fuel_l, repair_parts: Array, tyre_s, fuel_s, repair_s, total_s}
func service_for(i: int, plan: Dictionary) -> Dictionary:
	var c := sim.cars[i]
	var tyre := _plan_compound(i, plan)
	if tyre != "" and not sim.tyre_defs.has(tyre):
		tyre = ""
	var fuel := 0.0
	if sim.settings.fuel_enabled:
		var room := maxf(sim.defs[i].fuel_capacity_l - c.fuel_l, 0.0)
		var want: float = plan["fuel"]
		if want < 0.0:  # enough to finish (this lap plus the rest) with a little spare
			want = maxf((laps_after_this(i) + 1.15) * fuel_per_lap(i) - c.fuel_l, 0.0)
		fuel = minf(want, room)
	var repair_s := 0.0
	var parts := []
	if plan["repair"] and sim.damage_level != CarDamage.Level.OFF:
		parts = CarDamage.repair_plan(c).keys()
		repair_s = CarDamage.repair_time(c, [])
	var tyre_s := TYRE_CHANGE_S if tyre != "" else 0.0
	var fuel_s := fuel / FUEL_FLOW_LPS
	var total := STOP_BASE_S + maxf(tyre_s, fuel_s) + repair_s
	return {"tyre": tyre, "fuel_l": fuel, "repair_parts": parts, "tyre_s": tyre_s,
		"fuel_s": fuel_s, "repair_s": repair_s, "total_s": total}


## Time a stop costs against staying out (lane at the limit + stop), seconds.
func stop_loss(i: int, plan: Dictionary = {}) -> float:
	if not enabled:
		return INF
	var laps := sim.entries[i].lap_times
	var avg_speed := sim.track.length / laps[-1] if laps.size() > 0 and laps[-1] > 0.0 else 42.0
	var service: float = service_for(i, plan if not plan.is_empty() else sim.entries[i].pit["plan"])["total_s"]
	return maxf(route_time + 4.0 - route_track_m / avg_speed, 5.0) + service


# --- Every tick ------------------------------------------------------------------

## Runs the pit lane for the cars simulated here and returns the inputs the
## physics should use (the pit guide replaces a driver's input while it drives).
func pre_step(inputs: Array) -> Array:
	if not enabled:
		return inputs
	var out := inputs.duplicate()
	for i in sim.car_count():
		if sim.external[i]:
			continue
		var inp: CarInput = out[i] if i < out.size() and out[i] != null else CarInput.neutral()
		var r := _step_car(i, inp)
		if i < out.size():
			out[i] = r
		else:
			out.append(r)
	return out


func _step_car(i: int, inp: CarInput) -> CarInput:
	var c := sim.cars[i]
	var e := sim.entries[i]
	var p: Dictionary = e.pit
	var t := sim.track
	var dt := RaceSim.TICK_DT
	_measure_fuel(i)
	match p["phase"]:
		PHASE_NONE:
			if sim.phase != RaceSim.Phase.RACING and sim.phase != RaceSim.Phase.CHEQUERED:
				return _limited(i, inp)
			if p["box"] and not e.finished and _near_commit(c.track_s):
				_enter_route(i, PHASE_APPROACH, true)
			elif _entered_lane_by_hand(i):
				_enter_route(i, PHASE_ENTRY, p["box"])
		PHASE_APPROACH:
			if t.in_pit_lane(c.pos) and t.project_pit(c.pos)["d"] > 2.0:
				p["phase"] = PHASE_ENTRY
				p["lane_time"] = sim.race_time
				p["entry_lap"] = current_lap(i)
			elif _route_d(i) > limit_start or _off_route(i, 40.0):
				p["phase"] = PHASE_NONE  # missed it: try again next lap
	match p["phase"]:
		PHASE_ENTRY:
			var d := _route_d(i)
			if d >= limit_start:
				if not p["auto"] and c.speed() > t.pit_speed_limit + LIMIT_TOLERANCE:
					p["speeding"] = int(p["speeding"]) + 1
				p["phase"] = PHASE_LIMIT
				p["limiter"] = true
			elif not p["auto"] and not t.in_pit_lane(c.pos) and _off_route(i, 20.0):
				p["phase"] = PHASE_NONE  # drove back out
		PHASE_LIMIT:
			var box_d := _box_d(i)
			if _route_d(i) >= box_d - 1.2 and c.speed() < 1.5:
				var work := service_for(i, p["plan"])
				p["work"] = work
				p["service_total"] = work["total_s"]
				p["service_left"] = work["total_s"]
				p["phase"] = PHASE_SERVICE
		PHASE_SERVICE:
			c.vel = Vector2.ZERO
			c.yaw_rate = 0.0
			p["service_left"] = maxf(float(p["service_left"]) - dt, 0.0)
			if p["service_left"] <= 0.0:
				_finish_service(i)
				p["phase"] = PHASE_LEAVE
		PHASE_LEAVE:
			if _route_d(i) >= limit_end:
				p["phase"] = PHASE_EXIT
				p["limiter"] = false
		PHASE_EXIT:
			if _route_d(i) >= route_len - 4.0 or (not t.in_pit_lane(c.pos) and _off_route(i, 12.0)):
				p["phase"] = PHASE_NONE
				p["auto"] = false
	if controls(i):
		return _guide(i)
	return _limited(i, inp)


## The pit limiter: no drive above the pit lane speed limit.
func _limited(i: int, inp: CarInput) -> CarInput:
	if sim.entries[i].pit["limiter"] and sim.cars[i].speed() > sim.track.pit_speed_limit - 0.3:
		var r := CarInput.new()
		r.throttle = 0.0
		r.brake = inp.brake
		r.steer = inp.steer
		return r.quantized()
	return inp


func _near_commit(s: float) -> bool:
	var ahead := fposmod(s - commit_s, sim.track.length)
	return ahead < 80.0


func _entered_lane_by_hand(i: int) -> bool:
	var t := sim.track
	var c := sim.cars[i]
	if not t.in_pit_lane(c.pos):
		return false
	var q := t.project_pit(c.pos)
	if q["d"] < 10.0 or q["d"] > t.pit_limit_start - 5.0:
		return false
	# Clearly off the race track itself, on the pit side, heading down the lane.
	var edge := t.width_right[c.track_idx] if t.pit_side > 0.0 else t.width_left[c.track_idx]
	if c.lateral_offset * t.pit_side < edge + MANUAL_ENTRY_MARGIN:
		return false
	return c.vel.dot(Vector2.from_angle(t.pit_heading_at(q["d"]))) > 0.9 * c.speed()


func _enter_route(i: int, new_phase: String, auto: bool) -> void:
	var p: Dictionary = sim.entries[i].pit
	p["phase"] = new_phase
	p["auto"] = auto
	p["lane_time"] = sim.race_time
	p["entry_lap"] = current_lap(i)
	_route_k[i] = _nearest_route(sim.cars[i].pos, -1)


func _finish_service(i: int) -> void:
	var c := sim.cars[i]
	var e := sim.entries[i]
	var p: Dictionary = e.pit
	var work: Dictionary = p["work"]
	var tyre: String = work.get("tyre", "")
	if tyre != "" and sim.tyre_defs.has(tyre):
		sim.compounds[i] = sim.tyre_defs[tyre]
		p["compound"] = tyre
		c.tyre_wear = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
		var warm := lerpf(sim.env.ambient_c, sim.env.track_c, 0.5) + 10.0
		c.tyre_temp = PackedFloat64Array([warm, warm, warm, warm])
		p["stint_lap"] = e.laps_done
		CarDamage.repair(c, ["tyres"])  # new tyres fix punctures
	c.fuel_l = minf(c.fuel_l + float(work.get("fuel_l", 0.0)), sim.defs[i].fuel_capacity_l)
	_lap_fuel[i] = c.fuel_l
	if not (work.get("repair_parts", []) as Array).is_empty():
		CarDamage.repair(c, work["repair_parts"])
	# A stop counts in the lap the car came into the pits.
	var lap := int(p["entry_lap"]) if int(p["entry_lap"]) > 0 else current_lap(i)
	p["stops"] = int(p["stops"]) + 1
	if in_window(lap):
		p["window_stops"] = int(p["window_stops"]) + 1
	p["last_stop"] = {"lap": lap, "stationary_s": p["service_total"], "tyre": tyre,
		"fuel_l": work.get("fuel_l", 0.0), "repairs": work.get("repair_parts", [])}
	p["box"] = false
	p["work"] = {}


## Fuel used per lap, measured at the line (laps with a refuel don't count).
func _measure_fuel(i: int) -> void:
	var c := sim.cars[i]
	var L := sim.track.length
	if _prev_s[i] > L - 60.0 and c.track_s < 60.0:
		var used := _lap_fuel[i] - c.fuel_l
		if used > 0.05 and sim.entries[i].laps_done >= 1:
			var p: Dictionary = sim.entries[i].pit
			var old: float = p["fuel_per_lap"]
			p["fuel_per_lap"] = used if old <= 0.0 else lerpf(old, used, 0.5)
		_lap_fuel[i] = c.fuel_l
	_prev_s[i] = c.track_s


# --- The pit guide (drives a car along the route) ---------------------------------

func _build_route() -> void:
	var t := sim.track
	commit_s = fposmod(t.pit_entry_s - COMMIT_BEFORE_ENTRY, t.length)
	route = PackedVector2Array()
	# Along the track, easing over to the pit side.
	var n_track := int(COMMIT_BEFORE_ENTRY / ROUTE_STEP)
	for k in n_track:
		var s := commit_s + k * ROUTE_STEP
		var idx := t.index_at(s)
		var edge := t.width_right[idx] if t.pit_side > 0.0 else t.width_left[idx]
		var f := smoothstep(0.0, 0.7, float(k) / n_track)
		route.append(t.position_at(s, t.pit_side * f * maxf(edge - 1.8, 0.0)))
	# Then the pit lane, on the fast-lane side away from the boxes. The very
	# ends of mapped lanes often hook into the track, so they are skipped.
	var d := LANE_END_SKIP
	var fast := -t.pit_side * 1.5
	var lane_end := t.pit_length - LANE_END_SKIP
	while d < lane_end:
		var ramp := smoothstep(LANE_END_SKIP, 50.0, d) * (1.0 - smoothstep(lane_end - 60.0, lane_end, d))
		route.append(t.pit_position_at(d, fast * ramp))
		d += ROUTE_STEP
	var last := t.pit_position_at(lane_end)
	if route[route.size() - 1].distance_to(last) > 1.0:
		route.append(last)
	# And onto the edge of the track, so the car rejoins on the tarmac.
	var exit_idx := t.index_at(t.pit_exit_s)
	var exit_edge := t.width_right[exit_idx] if t.pit_side > 0.0 else t.width_left[exit_idx]
	var exit_q := t.project(last, exit_idx, 60)
	for k in range(1, 6):
		route.append(t.position_at(float(exit_q["s"]) + 15.0 + k * 8.0, t.pit_side * maxf(exit_edge - 2.0, 0.0)))
	# Smooth the joins (track to lane, lane to track) so the guide flows.
	for _pass in 6:
		var sm := route.duplicate()
		for k in range(1, route.size() - 1):
			sm[k] = (route[k - 1] + route[k] * 2.0 + route[k + 1]) * 0.25
		route = sm
	route_cum.resize(route.size())
	var acc := 0.0
	for k in route.size():
		if k > 0:
			acc += route[k - 1].distance_to(route[k])
		route_cum[k] = acc
	route_len = acc
	lane_start = (route_cum[n_track] if n_track < route.size() else 0.0) - LANE_END_SKIP
	limit_start = lane_start + t.pit_limit_start
	limit_end = lane_start + t.pit_limit_end
	# Speeds: cornering limit, the speed limit zone, then braking in time.
	var m := route.size()
	route_speed.resize(m)
	for k in m:
		var v := ROUTE_MAX_SPEED
		if k >= 2 and k < m - 2:
			var radius := _radius(route[k - 2], route[k], route[k + 2])
			v = minf(v, sqrt(LATERAL_G * radius))
		if route_cum[k] >= limit_start - 2.0 and route_cum[k] <= limit_end:
			v = minf(v, t.pit_speed_limit - 0.4)
		route_speed[k] = v
	for j in m - 1:
		var k := m - 2 - j
		var ds := route_cum[k + 1] - route_cum[k]
		route_speed[k] = minf(route_speed[k], sqrt(route_speed[k + 1] * route_speed[k + 1] + 2.0 * BRAKE_DECEL * ds))
	# Time to drive the route (accelerating at ~5 m/s^2), for the stop-loss estimate.
	var v := route_speed[0]
	route_time = 0.0
	for k in range(1, m):
		var ds := route_cum[k] - route_cum[k - 1]
		var nv := minf(route_speed[k], sqrt(v * v + 2.0 * 5.0 * ds))
		route_time += ds / maxf((v + nv) * 0.5, 1.0)
		v = nv
	route_track_m = fposmod(t.pit_exit_s - commit_s, t.length)


static func _radius(a: Vector2, b: Vector2, c: Vector2) -> float:
	var area2 := absf((b - a).cross(c - a))
	if area2 < 1e-4:
		return INF
	return a.distance_to(b) * b.distance_to(c) * c.distance_to(a) / (2.0 * area2)


func _nearest_route(pos: Vector2, hint: int) -> int:
	var best := 0
	var best_d := INF
	var lo := 0 if hint < 0 else maxi(hint - 4, 0)
	var hi := route.size() if hint < 0 else mini(hint + 30, route.size())
	for k in range(lo, hi):
		var dd := pos.distance_squared_to(route[k])
		if dd < best_d:
			best_d = dd
			best = k
	return best


## Route metres car i has reached.
func _route_d(i: int) -> float:
	var c := sim.cars[i]
	var k := _nearest_route(c.pos, _route_k[i])
	if c.pos.distance_squared_to(route[k]) > 30.0 * 30.0:
		k = _nearest_route(c.pos, -1)  # lost (e.g. the car changed hands mid-lane)
	_route_k[i] = k
	if k < route.size() - 1:
		var seg := route[k + 1] - route[k]
		var l := seg.length()
		if l > 0.0001:
			return route_cum[k] + clampf((c.pos - route[k]).dot(seg / l), -l, l)
	return route_cum[k]


func _off_route(i: int, metres: float) -> bool:
	return sim.cars[i].pos.distance_to(route[_route_k[i]]) > metres


func _box_d(i: int) -> float:
	return lane_start + sim.track.pit_box(_box[i])["d"]


func _route_point(d: float) -> Vector2:
	d = clampf(d, 0.0, route_len)
	var lo := 0
	var hi := route.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if route_cum[mid] <= d:
			lo = mid
		else:
			hi = mid - 1
	if lo >= route.size() - 1:
		return route[lo]
	var l := route_cum[lo + 1] - route_cum[lo]
	return route[lo].lerp(route[lo + 1], (d - route_cum[lo]) / maxf(l, 0.0001))


func _route_speed_at(d: float) -> float:
	var k := clampi(int(d / ROUTE_STEP), 0, route.size() - 1)
	while k < route.size() - 1 and route_cum[k + 1] <= d:
		k += 1
	return route_speed[k]


func _guide(i: int) -> CarInput:
	var c := sim.cars[i]
	var def := sim.defs[i]
	var p: Dictionary = sim.entries[i].pit
	var inp := CarInput.new()
	var d := _route_d(i)
	var speed := c.speed()
	# The route's speeds are planned for a grippy race car in the dry: scale
	# them by this car's grip now (road tyres, rain, worn tyres).
	var tc := sim.compounds[i]
	var grip := tc.peak_mu * minf(def.front_grip, def.rear_grip) * sim.env.grip_factor(tc, 0.0, speed) \
		* CarPhysics.wear_grip_factor((c.tyre_wear[0] + c.tyre_wear[1] + c.tyre_wear[2] + c.tyre_wear[3]) * 0.25)
	var v_target := _route_speed_at(d)
	if v_target > sim.track.pit_speed_limit:
		v_target = maxf(v_target * clampf(sqrt(grip / ROUTE_GRIP), 0.5, 1.05), sim.track.pit_speed_limit - 0.4)
	var target_d := d + clampf(speed * 0.55, 7.0, 28.0)
	var aim := _route_point(target_d)
	var box_d := _box_d(i)
	match p["phase"]:
		PHASE_LIMIT:
			v_target = minf(v_target, sqrt(2.0 * BOX_DECEL * maxf(box_d - d, 0.0)))
			var box: Dictionary = sim.track.pit_box(_box[i])
			var into := smoothstep(box_d - 30.0, box_d - 6.0, d)
			if into > 0.0:
				aim = aim.lerp(box["pos"] + Vector2.from_angle(box["heading"]) * 3.0, into)
		PHASE_SERVICE:
			v_target = 0.0
		PHASE_LEAVE:
			if d < box_d + 15.0:
				v_target = minf(v_target, 8.0)
	# Drifting off the route (cold tyres, a slide): slow down to get back on it.
	var off := c.pos.distance_to(_route_point(d))
	if off > 3.0:
		v_target *= clampf(1.0 - (off - 3.0) / 30.0, 0.6, 1.0)
	# Keep a gap to a car right in front (the pit lane is single file).
	for j in sim.car_count():
		if j == i:
			continue
		var rel := sim.cars[j].pos - c.pos
		var ahead := rel.dot(c.forward())
		if ahead > 0.0 and ahead < 14.0 and absf(rel.dot(c.right())) < 2.2:
			v_target = minf(v_target, sim.cars[j].speed() * 0.9 + maxf(ahead - 8.0, 0.0) * 0.4)
	# Pure pursuit steering.
	var rel := aim - c.pos
	var lx := rel.dot(c.forward())
	var ly := rel.dot(c.right())
	var alpha := atan2(ly, lx)
	var steer := atan(2.0 * def.wheelbase * sin(alpha) / maxf(rel.length(), 1.0))
	inp.steer = clampf(steer / def.max_steer, -1.0, 1.0)
	# Catch a slide: counter-steer and come off the power. The rear slip angle
	# is worked out from the car's motion (not CarState.slip_angle_rear, which
	# isn't in snapshots), so a restored race steers exactly the same.
	var vx := c.vel.dot(c.forward())
	var slip_r := atan2(c.vel.dot(c.right()) - c.yaw_rate * (def.wheelbase - def.cg_to_front), maxf(absf(vx), CarPhysics.LOW_SPEED))
	var slide := slip_r - clampf(slip_r, -0.06, 0.06)
	if slide != 0.0:
		inp.steer = clampf(inp.steer + slide * 2.5, -1.0, 1.0)
	# Gentle on the pedals: hard braking while turning would push it wide.
	var dv := v_target - speed
	if v_target <= 0.05:
		inp.brake = 1.0 if speed < 3.0 else 0.6
	elif dv > 0.0:
		inp.throttle = clampf(dv * 0.3, 0.0, 1.0) * clampf(1.2 - absf(inp.steer), 0.3, 1.0)
		if absf(slip_r) > 0.1:
			inp.throttle *= 0.25
	elif dv < -0.8:
		inp.brake = clampf(-dv * 0.15, 0.0, 1.0) * clampf(1.0 - 1.5 * absf(inp.steer), 0.3, 1.0)
		if absf(slip_r) > 0.1:
			inp.brake *= 0.3
	if p["limiter"] and speed > sim.track.pit_speed_limit - 0.3:
		inp.throttle = 0.0
	return inp.quantized()


# --- Host: counting, penalties and events -------------------------------------------

## Host only, after each step: turns pit state changes (from this machine's
## cars or reported by their owners) into events, and hands out penalties.
func host_update(events: Array) -> void:
	for i in sim.car_count():
		var p: Dictionary = sim.entries[i].pit
		var was: Dictionary = _sent[i]
		if p["phase"] != was.get("phase", ""):
			if p["phase"] in IN_LANE and not (was.get("phase", "") in IN_LANE):
				events.append({"type": "pit_entry", "car": i, "lap": current_lap(i)})
			if p["phase"] == PHASE_SERVICE:
				events.append({"type": "pit_box", "car": i, "lap": current_lap(i), "work": p.get("work", {})})
			if p["phase"] == PHASE_NONE and was.get("phase", "") in IN_LANE:
				events.append({"type": "pit_exit", "car": i, "lap": current_lap(i),
					"lane_s": sim.race_time - float(p.get("lane_time", sim.race_time))})
		if int(p["stops"]) > int(was.get("stops", 0)):
			var last: Dictionary = p.get("last_stop", {})
			events.append({"type": "pit_stop", "car": i, "stop": p["stops"], "lap": last.get("lap", current_lap(i)),
				"stationary_s": last.get("stationary_s", 0.0), "tyre": last.get("tyre", ""),
				"fuel_l": last.get("fuel_l", 0.0), "in_window": int(p["window_stops"]) > int(was.get("window_stops", 0))})
		if p["box"] != was.get("box", false) and p["box"]:
			events.append({"type": "pit_request", "car": i, "lap": current_lap(i)})
		var speeding := int(p["speeding"]) - int(was.get("speeding", 0))
		for _k in maxi(speeding, 0):
			sim.add_penalty(i, SPEEDING_PENALTY_S, "Speeding in the pit lane")
		_sent[i] = p.duplicate(true)


## Host: when a car finishes, a missed mandatory stop costs a time penalty.
func on_finished(i: int) -> void:
	if not enabled:
		return
	var missing := mandatory_left(i)
	if missing > 0:
		sim.add_penalty(i, MISSED_STOP_PENALTY_S * missing,
			"Missed %d mandatory pit stop%s" % [missing, "s" if missing > 1 else ""])


## A pit state for car i reported by its owner (multiplayer). Also fits the
## tyres it now runs, so physics, HUD and race data here know about them.
func apply_remote(i: int, state: Dictionary) -> void:
	var e := sim.entries[i]
	e.pit = state.duplicate(true)
	var comp: String = e.pit.get("compound", "")
	if comp != "" and sim.tyre_defs.has(comp) and sim.compounds[i].id != comp:
		sim.compounds[i] = sim.tyre_defs[comp]


## Short signature of a car's pit state: changes when the owner should tell the host.
static func signature(p: Dictionary) -> String:
	return "%s|%s|%s|%s|%d|%d|%d|%s|%s|%d" % [p["phase"], p["auto"], p["box"], p["limiter"], p["stops"],
		p["window_stops"], p["speeding"], p["compound"], str(p["plan"]), int(float(p["service_left"]) * 2.0)]


# --- Co-op: handing a car to another machine --------------------------------

## Everything the machine that simulates car i keeps about its pit stop, for
## a driver change that moves the car to the new driver's machine.
func car_handover(i: int) -> Dictionary:
	return {"pit": sim.entries[i].pit.duplicate(true), "route_k": _route_k[i],
		"prev_s": _prev_s[i], "lap_fuel": _lap_fuel[i]}


## The new driver's machine takes over car i's pit state (see car_handover).
func apply_handover(i: int, d: Dictionary) -> void:
	if d.has("pit"):
		apply_remote(i, d["pit"])
	_route_k[i] = int(d.get("route_k", _route_k[i]))
	_prev_s[i] = float(d.get("prev_s", _prev_s[i]))
	_lap_fuel[i] = float(d.get("lap_fuel", _lap_fuel[i]))


## A driver change in the box: the stop goes on for at least DRIVER_CHANGE_S.
func add_driver_change(i: int) -> void:
	var p: Dictionary = sim.entries[i].pit
	if p["phase"] != PHASE_SERVICE:
		return
	var extra := maxf(DRIVER_CHANGE_S - float(p["service_left"]), 0.0)
	p["service_left"] = float(p["service_left"]) + extra
	p["service_total"] = float(p["service_total"]) + extra


# --- Snapshots ----------------------------------------------------------------

func to_dict() -> Dictionary:
	return {"route_k": _route_k.duplicate(), "prev_s": _prev_s.duplicate(), "lap_fuel": _lap_fuel.duplicate(),
		"sent": _sent.duplicate(true)}


func from_dict(d: Dictionary) -> void:
	_route_k = PackedInt32Array(d["route_k"])
	_prev_s = PackedFloat64Array(d["prev_s"])
	_lap_fuel = PackedFloat64Array(d["lap_fuel"])
	_sent = d["sent"].duplicate(true)
