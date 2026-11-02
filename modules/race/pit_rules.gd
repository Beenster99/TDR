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
## Stop time: the car up and down, the tyres, fuel flow. Tyres and fuel are
## done at the same time; repairs come after.
const STOP_BASE_S := 2.5
const TYRE_CHANGE_S := 6.0       ## all four tyres
## Fewer tyres are quicker: TYRE_SETUP_S + TYRE_PER_WHEEL_S for each one
## (4 tyres = TYRE_CHANGE_S, 2 tyres 3.75 s, 1 tyre 2.6 s).
const TYRE_SETUP_S := 1.5
const TYRE_PER_WHEEL_S := 1.125
const FUEL_FLOW_LPS := 3.0
## Driver change in the box (co-op, a player handing over to their AI
## co-driver, or an AI car's driver line-up): the stop lasts at least this
## long from the moment the drivers swap (done alongside tyres and fuel).
const DRIVER_CHANGE_S := 5.0
## The pit crew mini-game (docs/PIT_CREW_GAME.md). A crew leader who plays a
## stop sets plan-free flags in the pit state (set_plan "crew"): the car then
## waits in the box until the leader releases it (or the crew give up waiting
## and release it at CREW_GIVE_UP x the standard time). A played stop can't be
## quicker than CREW_FASTEST x standard, and a release into a car coming down
## the lane is an unsafe release (UNSAFE_RELEASE_PENALTY_S).
const CREW_GIVE_UP := 1.6
const CREW_FASTEST := 0.6
const UNSAFE_RELEASE_PENALTY_S := 5.0
const RELEASE_LOOK_BACK := 32.0  ## m behind the box a car coming down the lane makes a release unsafe
## Crews nobody plays: AI teams work a little faster or slower each stop
## (CREW_SPREAD either way) and now and then fumble a wheel (CREW_FUMBLE_S);
## a player's crew they don't play works at the standard time.
const CREW_SPREAD := 0.08
const CREW_FUMBLE_CHANCE := 0.06
const CREW_FUMBLE_S := 1.5

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
## Which tyres to change (plan "wheels"). Wheel indices as CarState: 0 front
## left, 1 front right, 2 rear left, 3 rear right. A change to a different
## compound always fits all four (compounds aren't mixed on a car), and a
## punctured tyre is always changed when the plan allows repairs.
const WHEELS_ALL := "all"
const WHEEL_CHOICES := ["all", "front", "rear", "left", "right", "fl", "fr", "rl", "rr"]
const WHEEL_SETS := {"all": [0, 1, 2, 3], "front": [0, 1], "rear": [2, 3], "left": [0, 2],
	"right": [1, 3], "fl": [0], "fr": [1], "rl": [2], "rr": [3]}
const WHEEL_LABELS := {"all": "all four", "front": "fronts", "rear": "rears", "left": "left side",
	"right": "right side", "fl": "front left", "fr": "front right", "rl": "rear left", "rr": "rear right"}
## Setup changes the crew can make during a stop (plan "setup": {key: value},
## absolute CarSetup values). Only when the host allows car setups.
const PIT_SETUP_KEYS := ["wing_front", "wing_rear", "pressure_front", "pressure_rear"]
const WING_CHANGE_S := 2.5       ## per wing adjusted (done while the tyres are changed)
const PRESSURE_ONLY_S := 4.0     ## re-setting pressures without changing tyres
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
var route_end_s := 0.0           ## track distance where the route ends (back on the track)
var _route_tcum: PackedFloat64Array = []  ## seconds to drive the route up to each point
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
		"plan": {"tyre": TYRE_AUTO, "wheels": WHEELS_ALL, "fuel": FUEL_AUTO, "repair": true, "driver_change": false},
		"compound": compound_id, "stops": 0, "window_stops": 0, "speeding": 0,
		"stint_lap": 0, "lane_time": 0.0, "entry_lap": 0, "fuel_per_lap": 0.0, "last_stop": {},
		# AI cars with a driver line-up (RaceEntry.lineup): who drives now, and
		# the lap they took over.
		"driver_idx": 0, "driver_from_lap": 1,
		# Pit crew mini-game: the leader plays this stop / has released the car;
		# the standard time and the earliest release (seconds into the stop);
		# unsafe releases so far.
		"crew_game": false, "crew_release": false, "service_std": 0.0, "service_floor": 0.0, "unsafe": 0,
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


## The pit box car i stops in (index for TrackData.pit_box).
func box_index(i: int) -> int:
	return _box[i] if i < _box.size() else 0


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
## changes: any of {box: bool, tyre: String, wheels: String (WHEEL_CHOICES),
## fuel: float, repair: bool, driver_change: bool (cars with a driver line-up),
## setup: {key: value} for PIT_SETUP_KEYS (merged; an empty dict clears it),
## crew: the pit crew mini-game, see crew_input}
func set_plan(i: int, changes: Dictionary) -> void:
	var p: Dictionary = sim.entries[i].pit
	var plan: Dictionary = p["plan"]
	if changes.get("crew") is Dictionary:
		crew_input(i, changes["crew"])
	if changes.has("box") and p["phase"] == PHASE_NONE:
		p["box"] = bool(changes["box"]) and enabled
	if changes.has("tyre") and str(changes["tyre"]) in TYRE_CHOICES:
		plan["tyre"] = str(changes["tyre"])
	if changes.has("wheels") and str(changes["wheels"]) in WHEEL_CHOICES:
		plan["wheels"] = str(changes["wheels"])
	if changes.has("driver_change"):
		plan["driver_change"] = bool(changes["driver_change"]) and sim.entries[i].lineup.size() > 1
	if changes.has("fuel"):
		plan["fuel"] = maxf(float(changes["fuel"]), FUEL_AUTO)
	if changes.has("repair"):
		plan["repair"] = bool(changes["repair"])
	if changes.has("setup") and changes["setup"] is Dictionary and sim.settings.tuning_enabled:
		var want: Dictionary = changes["setup"]
		var cur: Dictionary = plan.get("setup", {}).duplicate()
		if want.is_empty():
			cur = {}
		var def := sim.defs[i]
		for k in want:
			if k in PIT_SETUP_KEYS and CarSetup.adjustable(def, k):
				cur.merge(CarSetup.sanitize(def, {k: want[k]}), true)
		if cur.is_empty():
			plan.erase("setup")
		else:
			plan["setup"] = cur


## The pit crew mini-game for car i (from the crew leader's screen, through
## RaceSession.request_pit(car, {"crew": {...}})):
##   {play: true}  the leader is playing the coming stop: in the box the car
##                 waits for their release (sent before the car stops;
##                 {play: false} takes it back);
##   {release: true, fuel_l: litres actually put in}  the leader drops the
##                 lollipop. Unsafe if a car is coming down the lane.
func crew_input(i: int, d: Dictionary) -> void:
	var p: Dictionary = sim.entries[i].pit
	if d.has("play") and p["phase"] != PHASE_SERVICE and p["phase"] != PHASE_LEAVE:
		p["crew_game"] = bool(d["play"])
	if bool(d.get("release", false)) and p["phase"] == PHASE_SERVICE and bool(p.get("crew_game", false)) \
			and not bool(p.get("crew_release", false)):
		p["crew_release"] = true
		var work: Dictionary = p["work"]
		if d.has("fuel_l") and float(work.get("fuel_l", 0.0)) > 0.0:
			work["fuel_l"] = clampf(float(d["fuel_l"]), 0.0, float(work["fuel_l"]))
		if not release_clear(i):
			p["unsafe"] = int(p.get("unsafe", 0)) + 1


## True when car i can leave its box safely: no car coming down the lane
## right behind it, about to pass the box.
func release_clear(i: int) -> bool:
	if not enabled:
		return true
	var box_d := _box_d(i)
	for j in sim.car_count():
		if j == i or not (phase(j) in [PHASE_ENTRY, PHASE_LIMIT, PHASE_LEAVE]):
			continue
		if sim.cars[i].pos.distance_to(sim.cars[j].pos) > RELEASE_LOOK_BACK + 10.0 or sim.cars[j].speed() < 3.0:
			continue
		var d := _route_d(j)
		if d > box_d - RELEASE_LOOK_BACK and d < box_d + 2.0:
			return false
	return true


## How the crew nobody plays does this stop, as a share of the standard
## time plus a fumble (seconds): AI teams vary from stop to stop (the same
## every time for the same race), a player's own crew is standard.
func crew_pace(i: int) -> Vector2:
	var e := sim.entries[i]
	if not e.is_ai:
		return Vector2(1.0, 0.0)
	var h := hash([sim.settings.seed, i, int(e.pit["stops"]), "crew"])
	var r1 := float(h & 0xFFFF) / 65535.0
	var r2 := float((h >> 16) & 0xFFFF) / 65535.0
	return Vector2(1.0 + CREW_SPREAD * (2.0 * r1 - 1.0), CREW_FUMBLE_S if r2 < CREW_FUMBLE_CHANCE else 0.0)


## Car i's current value of each pit-adjustable setup key.
func current_setup(i: int) -> Dictionary:
	var full := CarSetup.complete(sim.defs[i], sim.defs[i].tuning)
	var out := {}
	for k in PIT_SETUP_KEYS:
		out[k] = full[k]
	return out


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


## The wheels (0-3) a wheel choice covers.
static func wheels_of(choice: String) -> Array:
	return (WHEEL_SETS.get(choice, WHEEL_SETS[WHEELS_ALL]) as Array).duplicate()


## Time to change this many tyres (0 = none).
static func tyre_time(count: int) -> float:
	return TYRE_SETUP_S + TYRE_PER_WHEEL_S * count if count > 0 else 0.0


## What a stop with this plan would do and how long it would take now:
## {tyre: compound id or "", wheels: [0-3 changed], fuel_l, repair_parts: Array,
##  driver: line-up index taking over (-1 none), tyre_s, fuel_s, repair_s, total_s}
func service_for(i: int, plan: Dictionary) -> Dictionary:
	var c := sim.cars[i]
	var tyre := _plan_compound(i, plan)
	if tyre != "" and not sim.tyre_defs.has(tyre):
		tyre = ""
	# Which tyres: the plan's choice; all four for a new compound; and any
	# punctured tyre when repairs are on (with the compound it runs now).
	var wheels: Array = []
	if tyre != "":
		wheels = wheels_of(str(plan.get("wheels", WHEELS_ALL)))
		if tyre != sim.compounds[i].id:
			wheels = [0, 1, 2, 3]
	if plan["repair"] and sim.damage_level != CarDamage.Level.OFF:
		for w in 4:
			if c.puncture[w] > 0.5 and not w in wheels:
				wheels.append(w)
				if tyre == "":
					tyre = sim.compounds[i].id
	wheels.sort()
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
	var tyre_s := tyre_time(wheels.size()) if tyre != "" else 0.0
	var fuel_s := fuel / FUEL_FLOW_LPS
	# Setup changes: only what differs from the car now.
	var setup := {}
	var setup_s := 0.0
	var want: Dictionary = plan.get("setup", {})
	if not want.is_empty() and sim.settings.tuning_enabled:
		var now := current_setup(i)
		for k in want:
			if now.has(k) and absf(float(want[k]) - float(now[k])) > 1e-4:
				setup[k] = float(want[k])
		for k in ["wing_front", "wing_rear"]:
			if setup.has(k):
				setup_s += WING_CHANGE_S
		if tyre == "" and (setup.has("pressure_front") or setup.has("pressure_rear")):
			setup_s += PRESSURE_ONLY_S
	var total := STOP_BASE_S + maxf(maxf(tyre_s, fuel_s), setup_s) + repair_s
	# Driver change (cars with a driver line-up): at least DRIVER_CHANGE_S.
	var driver := -1
	if bool(plan.get("driver_change", false)):
		driver = next_driver(i)
		if driver >= 0:
			total = maxf(total, DRIVER_CHANGE_S)
	return {"tyre": tyre, "wheels": wheels, "fuel_l": fuel, "repair_parts": parts, "tyre_s": tyre_s,
		"fuel_s": fuel_s, "repair_s": repair_s, "setup": setup, "setup_s": setup_s, "driver": driver, "total_s": total}


# --- Driver line-ups (AI cars sharing a car between drivers) ---------------------

## Index in RaceEntry.lineup of the driver at the wheel of car i.
func driver_index(i: int) -> int:
	return int(sim.entries[i].pit.get("driver_idx", 0))


## The line-up driver who would take over at the next change (the next one
## in the line-up, round in turn), -1 when the car has nobody to change to.
func next_driver(i: int) -> int:
	var e := sim.entries[i]
	if e.lineup.size() < 2:
		return -1
	var now := driver_index(i)
	return (now + 1) % e.lineup.size()


## Laps the driver now at the wheel of car i has driven in this stint,
## counting the lap they are on.
func driver_stint_laps(i: int) -> int:
	return current_lap(i) - int(sim.entries[i].pit.get("driver_from_lap", 1)) + 1


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
				_arrive(i)
		PHASE_SERVICE:
			c.vel = Vector2.ZERO
			c.yaw_rate = 0.0
			p["service_left"] = maxf(float(p["service_left"]) - dt, 0.0)
			if bool(p.get("crew_release", false)):
				# Released by the crew leader: go, once the work can have been done.
				var elapsed := float(p["service_total"]) - float(p["service_left"])
				var left := minf(float(p["service_left"]), maxf(float(p.get("service_floor", 0.0)) - elapsed, 0.0))
				p["service_left"] = left
				p["service_total"] = elapsed + left
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


## Car i has stopped in its box: the crew start work. A stop the crew
## leader plays waits for their release; otherwise the crew take the
## standard time (AI teams a little more or less, see crew_pace).
func _arrive(i: int) -> void:
	var p: Dictionary = sim.entries[i].pit
	var work := service_for(i, p["plan"])
	p["work"] = work
	var std: float = work["total_s"]
	p["service_std"] = std
	p["crew_release"] = false
	var t := std
	if bool(p.get("crew_game", false)):
		# The leader is playing: wait for their release, or give up waiting.
		t = std * CREW_GIVE_UP
		p["service_floor"] = std * CREW_FASTEST
		if int(work.get("driver", -1)) >= 0:
			p["service_floor"] = maxf(float(p["service_floor"]), DRIVER_CHANGE_S)
	else:
		var pace := crew_pace(i)
		t = std * pace.x + pace.y
		if int(work.get("driver", -1)) >= 0:
			t = maxf(t, DRIVER_CHANGE_S)
	p["service_total"] = t
	p["service_left"] = t
	p["phase"] = PHASE_SERVICE


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
	var wheels: Array = work.get("wheels", [0, 1, 2, 3])
	if tyre != "" and sim.tyre_defs.has(tyre) and not wheels.is_empty():
		sim.compounds[i] = sim.tyre_defs[tyre]
		p["compound"] = tyre
		var warm := lerpf(sim.env.ambient_c, sim.env.track_c, 0.5) + 10.0
		for w in wheels:
			c.tyre_wear[int(w)] = 0.0
			c.tyre_temp[int(w)] = warm
			c.puncture[int(w)] = 0.0  # a new tyre fixes a puncture
		if wheels.size() == 4:
			p["stint_lap"] = e.laps_done
	c.fuel_l = minf(c.fuel_l + float(work.get("fuel_l", 0.0)), sim.defs[i].fuel_capacity_l)
	_lap_fuel[i] = c.fuel_l
	if not (work.get("repair_parts", []) as Array).is_empty():
		CarDamage.repair(c, work["repair_parts"])
	var setup: Dictionary = work.get("setup", {})
	if not setup.is_empty():
		sim.change_setup(i, setup)
		(p["plan"] as Dictionary).erase("setup")
	var driver := int(work.get("driver", -1))
	var handed := ""
	if driver >= 0 and driver < e.lineup.size():
		handed = str(e.lineup[driver].get("name", ""))
		p["driver_idx"] = driver
		p["driver_from_lap"] = current_lap(i)
		e.traits = e.lineup[driver].get("traits", e.traits)
	(p["plan"] as Dictionary)["driver_change"] = false
	# A stop counts in the lap the car came into the pits.
	var lap := int(p["entry_lap"]) if int(p["entry_lap"]) > 0 else current_lap(i)
	p["stops"] = int(p["stops"]) + 1
	if in_window(lap):
		p["window_stops"] = int(p["window_stops"]) + 1
	var stationary := float(p["service_total"])
	p["last_stop"] = {"lap": lap, "stationary_s": stationary, "standard_s": float(p.get("service_std", stationary)),
		"played": bool(p.get("crew_game", false)), "tyre": tyre, "wheels": wheels if tyre != "" else [],
		"fuel_l": work.get("fuel_l", 0.0), "repairs": work.get("repair_parts", []), "setup": work.get("setup", {}),
		"driver": handed}
	p["box"] = false
	p["work"] = {}
	p["crew_game"] = false
	p["crew_release"] = false


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
	_route_tcum.resize(m)
	_route_tcum[0] = 0.0
	for k in range(1, m):
		var ds := route_cum[k] - route_cum[k - 1]
		var nv := minf(route_speed[k], sqrt(v * v + 2.0 * 5.0 * ds))
		route_time += ds / maxf((v + nv) * 0.5, 1.0)
		_route_tcum[k] = route_time
		v = nv
	route_track_m = fposmod(t.pit_exit_s - commit_s, t.length)
	route_end_s = float(t.project(route[m - 1], exit_idx, 60)["s"])


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


# --- Where a stop rejoins -------------------------------------------------------

## Where car i comes back out among the cars on the circuit after a clean
## stop at the crew's standard pace: the stop it is making (boxing or in the
## lane), or one it would make if it boxed now. Works on every machine.
## {s: the spot on the circuit, now, whose traffic will be passing the pit
##  exit as the car leaves it (it slides up to the exit as the stop goes on),
##  exit_in: seconds until the car is back on the track, position: race
##  position there, ahead / behind: the cars either side there (-1 none),
##  gap_ahead / gap_behind: seconds to them (-1 none), speed: m/s used}
## {} when the track has no pit lane or the car is out of the race.
func rejoin_estimate(i: int) -> Dictionary:
	var e := sim.entries[i]
	if not enabled or e.finished or e.dnf or sim.race_control.recovered[i]:
		return {}
	var t := sim.track
	var L := t.length
	var c := sim.cars[i]
	var p: Dictionary = e.pit
	var v := L / e.lap_times[-1] if e.lap_times.size() > 0 and e.lap_times[-1] > 0.0 else 42.0
	if sim.race_control.safety_car_active():
		v = minf(v, 30.0)
	var ph: String = p["phase"]
	var exit_in := 0.0
	var fwd := 0.0   # metres along the circuit from the car to where it rejoins
	if ph in IN_LANE or ph == PHASE_APPROACH:
		var d := _route_d_peek(i)
		exit_in = maxf(route_time - _route_time_at(d), 0.0)
		match ph:
			PHASE_SERVICE:
				exit_in += maxf(float(p.get("service_std", p["service_total"])) - (float(p["service_total"]) - float(p["service_left"])), 0.0)
			PHASE_LEAVE, PHASE_EXIT:
				pass
			_:
				exit_in += float(service_for(i, p["plan"])["total_s"])
		fwd = fposmod(route_end_s - c.track_s, L)
		if fwd > L - 400.0:
			fwd -= L   # the lane has taken it a little past the exit already
	else:
		var to_commit := fposmod(commit_s - c.track_s, L)
		exit_in = to_commit / v + route_time + float(service_for(i, p["plan"])["total_s"])
		fwd = to_commit + fposmod(route_end_s - commit_s, L)
	var ghost := e.distance + fwd - exit_in * v
	var ahead := -1
	var behind := -1
	var da := INF
	var db := INF
	var pos := 1
	for j in sim.car_count():
		var o := sim.entries[j]
		if j == i or o.finished or o.dnf or sim.race_control.recovered[j]:
			continue
		var dd := o.distance - ghost
		if dd > 0.0:
			pos += 1
			if dd < da:
				da = dd
				ahead = j
		elif -dd < db:
			db = -dd
			behind = j
	return {"s": fposmod(ghost, L), "exit_in": exit_in, "position": pos, "ahead": ahead, "behind": behind,
		"gap_ahead": da / v if ahead >= 0 else -1.0, "gap_behind": db / v if behind >= 0 else -1.0, "speed": v}


## Route metres car i has reached, without moving its route marker (any
## machine, any car).
func _route_d_peek(i: int) -> float:
	var keep := _route_k[i]
	var d := _route_d(i)
	_route_k[i] = keep
	return d


## Seconds to drive the route up to route metres d.
func _route_time_at(d: float) -> float:
	if _route_tcum.is_empty():
		return 0.0
	var k := clampi(int(d / ROUTE_STEP), 0, route.size() - 1)
	while k > 0 and route_cum[k] > d:
		k -= 1
	while k < route.size() - 1 and route_cum[k + 1] <= d:
		k += 1
	if k >= route.size() - 1:
		return _route_tcum[k]
	var f := clampf((d - route_cum[k]) / maxf(route_cum[k + 1] - route_cum[k], 0.0001), 0.0, 1.0)
	return lerpf(_route_tcum[k], _route_tcum[k + 1], f)


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
				"stationary_s": last.get("stationary_s", 0.0), "standard_s": last.get("standard_s", 0.0),
				"played": last.get("played", false), "tyre": last.get("tyre", ""), "wheels": last.get("wheels", []),
				"fuel_l": last.get("fuel_l", 0.0), "driver": last.get("driver", ""),
				"in_window": int(p["window_stops"]) > int(was.get("window_stops", 0))})
		if p["box"] != was.get("box", false) and p["box"]:
			events.append({"type": "pit_request", "car": i, "lap": current_lap(i)})
		var speeding := int(p["speeding"]) - int(was.get("speeding", 0))
		for _k in maxi(speeding, 0):
			sim.add_penalty(i, SPEEDING_PENALTY_S, "Speeding in the pit lane")
		for _k in maxi(int(p.get("unsafe", 0)) - int(was.get("unsafe", 0)), 0):
			sim.add_penalty(i, UNSAFE_RELEASE_PENALTY_S, "Unsafe release")
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
	var idx := int(e.pit.get("driver_idx", 0))
	if idx >= 0 and idx < e.lineup.size():
		e.traits = e.lineup[idx].get("traits", e.traits)
	var comp: String = e.pit.get("compound", "")
	if comp != "" and sim.tyre_defs.has(comp) and sim.compounds[i].id != comp:
		sim.compounds[i] = sim.tyre_defs[comp]


## The stop's clock for the HUD: time left, or (a stop the crew leader is
## playing, which ends on their release) time so far.
static func service_text(p: Dictionary, head: String) -> String:
	if bool(p.get("crew_game", false)):
		return "%s  %.1f s" % [head, float(p["service_total"]) - float(p["service_left"])]
	return "%s  %.1f s" % [head, float(p["service_left"])]


## Short signature of a car's pit state: changes when the owner should tell the host.
static func signature(p: Dictionary) -> String:
	return "%s|%s|%s|%s|%d|%d|%d|%s|%s|%d|%d|%s|%s|%d" % [p["phase"], p["auto"], p["box"], p["limiter"], p["stops"],
		p["window_stops"], p["speeding"], p["compound"], str(p["plan"]), int(float(p["service_left"]) * 2.0),
		int(p.get("driver_idx", 0)), p.get("crew_game", false), p.get("crew_release", false), int(p.get("unsafe", 0))]


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
	# A played stop: the crew leader can't release the car before the swap is done.
	var elapsed := float(p["service_total"]) - float(p["service_left"])
	p["service_floor"] = maxf(float(p.get("service_floor", 0.0)), elapsed + DRIVER_CHANGE_S)


# --- Snapshots ----------------------------------------------------------------

func to_dict() -> Dictionary:
	return {"route_k": _route_k.duplicate(), "prev_s": _prev_s.duplicate(), "lap_fuel": _lap_fuel.duplicate(),
		"sent": _sent.duplicate(true)}


func from_dict(d: Dictionary) -> void:
	_route_k = PackedInt32Array(d["route_k"])
	_prev_s = PackedFloat64Array(d["prev_s"])
	_lap_fuel = PackedFloat64Array(d["lap_fuel"])
	_sent = d["sent"].duplicate(true)
