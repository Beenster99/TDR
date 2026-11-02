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
##    300 m before the pit entry the car is then driven in automatically,
##    unless its driver drives in themselves (set_self_drive, Settings >
##    Gameplay): then they follow the pit guide line (guide_line) into the
##    lane, must be down to the limit by the limit line, stop on their box
##    (BOX_STOP_*, overshooting costs time) and drive out with the limiter.
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
## A driver stopping in their box themselves (self drive): how close to the
## box's marks counts. Along the lane: up to BOX_STOP_SHORT before the marks
## and BOX_STOP_LONG past them is spot on; up to BOX_OVERSHOOT_MAX past them
## the crew still work on the car, but it costs BOX_OVERSHOOT_S plus
## BOX_OVERSHOOT_S_PER_M a metre (they have to move the kit to it); further
## than that the car has missed its box and goes round again. Across: within
## BOX_STOP_WIDE of the marks.
const BOX_STOP_SHORT := 3.0
const BOX_STOP_LONG := 2.0
const BOX_STOP_WIDE := 2.6
const BOX_STOP_SPEED := 1.0      ## m/s: stopped
const BOX_OVERSHOOT_MAX := 12.0
const BOX_OVERSHOOT_S := 1.0
const BOX_OVERSHOOT_S_PER_M := 0.35
## The pit guide line for a driver driving in themselves (guide_line): it
## starts GUIDE_LEAD track metres before the route, and its speeds are
## planned for a driver braking at GUIDE_DECEL (to the limit line) and
## GUIDE_BOX_DECEL (onto the box), cornering at GUIDE_LATERAL_G.
const GUIDE_LEAD := 320.0
const GUIDE_DECEL := 9.0
const GUIDE_BOX_DECEL := 4.0
const GUIDE_LATERAL_G := 15.0
const GUIDE_MAX_SPEED := 100.0
const GUIDE_AHEAD := 900.0       ## m before the route the HUD starts counting down
const GUIDE_NONE := -1.0e9       ## guide_progress: not heading into the pits
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
var window_open := 1             ## pit window, in laps (inclusive)
var window_close := 1

var _route_k: PackedInt32Array = []
var _box: PackedInt32Array = []
var _prev_s: PackedFloat64Array = []
var _lap_fuel: PackedFloat64Array = []
var _sent: Array = []            ## host: last pit state seen per car (events, penalties)
## Cars whose driver drives in and stops in the box themselves (set by the
## machine that simulates the car; not part of the race state).
var _self: PackedByteArray = []


func _init(p_sim: RaceSim) -> void:
	sim = p_sim
	var t := sim.track
	enabled = t.has_pit_lane()
	_compute_window()
	var n := sim.car_count()
	for i in n:
		_route_k.append(0)
		_self.append(0)
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
		"compound": compound_id, "compounds": [compound_id, compound_id, compound_id, compound_id],
		"psi_trim": [0.0, 0.0, 0.0, 0.0], "stops": 0, "window_stops": 0, "speeding": 0,
		"stint_lap": 0, "lane_time": 0.0, "entry_lap": 0, "fuel_per_lap": 0.0, "last_stop": {},
		# AI cars with a driver line-up (RaceEntry.lineup): who drives now, and
		# the lap they took over.
		"driver_idx": 0, "driver_from_lap": 1,
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
		PHASE_SERVICE:
			return true
		PHASE_LIMIT, PHASE_LEAVE:
			return not self_drives(i)
		PHASE_APPROACH, PHASE_ENTRY, PHASE_EXIT:
			return p["auto"]
	return false


## The driver of car i drives into the pits and stops in the box themselves,
## following the pit guide line, instead of the car being driven in. Set by
## the machine that simulates the car, for a player at the wheel who wants
## it (Settings > Gameplay). Turning it off mid-stop hands the rest of the
## stop to the guide (e.g. an AI co-driver taking over).
func set_self_drive(i: int, on: bool) -> void:
	if i < 0 or i >= _self.size():
		return
	_self[i] = 1 if on else 0
	var p: Dictionary = sim.entries[i].pit
	if not on and p["phase"] != PHASE_NONE and p["phase"] != PHASE_EXIT:
		p["auto"] = true


## True while car i's driver is driving its pit stop themselves.
func self_drives(i: int) -> bool:
	return i >= 0 and i < _self.size() and _self[i] == 1 and not sim.entries[i].pit["auto"]


# --- Plans (driver, pit crew, strategist or AI) -------------------------------

## Changes car i's pit plan and/or box flag. Only takes effect on the machine
## that simulates the car: RaceSession routes requests from elsewhere there.
## changes: any of {box: bool, tyre: String, wheels: String (WHEEL_CHOICES),
## fuel: float, repair: bool, driver_change: bool (cars with a driver line-up),
## setup: {key: value} for PIT_SETUP_KEYS (merged; an empty dict clears it),
## wheel_tyres: [4] per wheel (FL, FR, RL, RR) a TYRE_CHOICES entry or a
## compound id, "" or "keep" for no change (mixed compounds allowed; [] clears
## it and the plan's tyre / wheels apply again), psi: [4] cold pressure per
## wheel as a delta on the compound's own, like CarSetup pressure_front
## ([] clears; only with car setups allowed)}
## A strategist's planned stop (wheel_tyres, psi) is used once, then cleared.
func set_plan(i: int, changes: Dictionary) -> void:
	var p: Dictionary = sim.entries[i].pit
	var plan: Dictionary = p["plan"]
	if changes.has("box") and p["phase"] == PHASE_NONE:
		p["box"] = bool(changes["box"]) and enabled
	if changes.has("tyre") and str(changes["tyre"]) in TYRE_CHOICES:
		plan["tyre"] = str(changes["tyre"])
		if not changes.has("wheel_tyres"):
			plan.erase("wheel_tyres")  # a plain tyre call replaces a per-wheel plan
	if changes.has("wheels") and str(changes["wheels"]) in WHEEL_CHOICES:
		plan["wheels"] = str(changes["wheels"])
		if not changes.has("wheel_tyres"):
			plan.erase("wheel_tyres")
	if changes.has("wheel_tyres"):
		var wt = changes["wheel_tyres"]
		var out := []
		if wt is Array and wt.size() == 4:
			for v in wt:
				var ch := str(v)
				out.append("" if ch == TYRE_KEEP or not (ch == "" or ch in TYRE_CHOICES or sim.tyre_defs.has(ch)) else ch)
		if out.size() == 4:
			plan["wheel_tyres"] = out
		else:
			plan.erase("wheel_tyres")
	if changes.has("psi"):
		var ps = changes["psi"]
		if ps is Array and ps.size() == 4 and sim.settings.tuning_enabled:
			var r := CarSetup.range_of(sim.defs[i], "pressure_front")
			var out := []
			for v in ps:
				out.append(clampf(snappedf(float(v), 0.1), float(r[1]), float(r[2])))
			plan["psi"] = out
		else:
			plan.erase("psi")
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
	return choice_compound(i, str(plan["tyre"]))


## The compound id a tyre choice means for car i now ("" = no change).
func choice_compound(i: int, choice: String) -> String:
	match choice:
		"", TYRE_KEEP: return ""
		TYRE_AUTO: return compound_for_conditions(i)
		TYRE_DRY: return sim.dry_compound[i]
	return choice


## Cold pressure of each wheel of car i now, as a delta on its compound's own
## cold pressure (the setup's front / rear plus the per-wheel trim).
func wheel_psi(i: int) -> Array:
	var d := sim.defs[i]
	var trim: Array = sim.entries[i].pit.get("psi_trim", [0.0, 0.0, 0.0, 0.0])
	return [d.pressure_delta_front + float(trim[0]), d.pressure_delta_front + float(trim[1]),
		d.pressure_delta_rear + float(trim[2]), d.pressure_delta_rear + float(trim[3])]


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
	# A per-wheel plan (wheel_tyres) says it wheel by wheel, mixing allowed.
	var per := ["", "", "", ""]
	var wt: Array = plan.get("wheel_tyres", [])
	if wt.size() == 4:
		for w in 4:
			var id := choice_compound(i, str(wt[w]))
			if sim.tyre_defs.has(id):
				per[w] = id
	elif tyre != "":
		var on := wheels_of(str(plan.get("wheels", WHEELS_ALL)))
		if tyre != sim.compounds[i].id or sim.mixed_tyres(i):
			on = [0, 1, 2, 3]
		for w in on:
			per[w] = tyre
	if plan["repair"] and sim.damage_level != CarDamage.Level.OFF:
		for w in 4:
			if c.puncture[w] > 0.5 and per[w] == "":
				per[w] = (sim.wheel_compounds[i][w] as TyreCompound).id
	var wheels: Array = []
	var fitted := []
	for w in 4:
		if per[w] != "":
			wheels.append(w)
			fitted.append(sim.tyre_defs[per[w]])
	tyre = RaceSim.main_compound(fitted).id if not fitted.is_empty() else ""
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
	# Pressures set tyre by tyre: kept as a trim on the setup's front / rear.
	var psi_trim := []
	var ps: Array = plan.get("psi", [])
	if ps.size() == 4 and sim.settings.tuning_enabled:
		var now_psi := wheel_psi(i)
		var d := sim.defs[i]
		var axle := [d.pressure_delta_front, d.pressure_delta_front, d.pressure_delta_rear, d.pressure_delta_rear]
		var changed_only := false
		for w in 4:
			if absf(float(ps[w]) - float(now_psi[w])) > 0.05:
				psi_trim = [0.0, 0.0, 0.0, 0.0]
				if not w in wheels:
					changed_only = true
		if not psi_trim.is_empty():
			for w in 4:
				psi_trim[w] = float(ps[w]) - float(axle[w])
			if changed_only:
				setup_s = maxf(setup_s, PRESSURE_ONLY_S)
	var total := STOP_BASE_S + maxf(maxf(tyre_s, fuel_s), setup_s) + repair_s
	# Driver change (cars with a driver line-up): at least DRIVER_CHANGE_S.
	var driver := -1
	if bool(plan.get("driver_change", false)):
		driver = next_driver(i)
		if driver >= 0:
			total = maxf(total, DRIVER_CHANGE_S)
	return {"tyre": tyre, "wheels": wheels, "wheel_tyres": per, "fuel_l": fuel, "repair_parts": parts, "tyre_s": tyre_s,
		"fuel_s": fuel_s, "repair_s": repair_s, "setup": setup, "setup_s": setup_s, "psi_trim": psi_trim,
		"driver": driver, "total_s": total}


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
				_enter_route(i, PHASE_APPROACH, _self[i] == 0)
			elif _entered_lane_by_hand(i):
				_enter_route(i, PHASE_ENTRY, p["box"] and _self[i] == 0)
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
			if self_drives(i):
				_self_drive_box(i)
			elif _route_d(i) >= box_d - 1.2 and c.speed() < 1.5:
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


## A driver stopping in their own box (self drive, PHASE_LIMIT): on the
## marks, the stop starts; a little past them it starts but costs time; well
## past them they've missed the box: the stop is off this lap (the box call
## stays, so they come in again next lap). Past the end of the speed limit
## they're on their way out.
func _self_drive_box(i: int) -> void:
	var c := sim.cars[i]
	var p: Dictionary = sim.entries[i].pit
	var m := box_marks(i, c.pos)
	var along: float = m["along"]
	if c.speed() < BOX_STOP_SPEED and absf(m["across"]) < BOX_STOP_WIDE and along > -BOX_STOP_SHORT \
			and along < BOX_OVERSHOOT_MAX and not bool(p.get("missed_box", false)):
		var work := service_for(i, p["plan"])
		var extra := 0.0
		if along > BOX_STOP_LONG:
			extra = BOX_OVERSHOOT_S + BOX_OVERSHOOT_S_PER_M * (along - BOX_STOP_LONG)
		work["overshoot_s"] = extra
		work["total_s"] = float(work["total_s"]) + extra
		p["work"] = work
		p["service_total"] = work["total_s"]
		p["service_left"] = work["total_s"]
		p["phase"] = PHASE_SERVICE
	elif along >= BOX_OVERSHOOT_MAX and absf(m["across"]) < 8.0:
		p["missed_box"] = true
	if p["phase"] == PHASE_LIMIT and _route_d(i) >= limit_end:
		p["phase"] = PHASE_EXIT
		p["limiter"] = false
		p.erase("missed_box")


## Where a point is against car i's box marks, in metres: along the lane
## (+ = past the marks) and across it.
func box_marks(i: int, pos: Vector2) -> Dictionary:
	var box: Dictionary = sim.track.pit_box(box_index(i))
	var fwd := Vector2.from_angle(box["heading"])
	var rel := pos - (box["pos"] as Vector2)
	return {"along": rel.dot(fwd), "across": rel.dot(Vector2(-fwd.y, fwd.x))}


## The pit limiter: no drive above the pit lane speed limit (always on for a
## driver driving themselves from the limit line to the end of the limit).
func _limited(i: int, inp: CarInput) -> CarInput:
	var p: Dictionary = sim.entries[i].pit
	var on: bool = p["limiter"] or (p["phase"] in [PHASE_LIMIT, PHASE_LEAVE] and self_drives(i))
	if on and sim.cars[i].speed() > sim.track.pit_speed_limit - 0.3:
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
	p.erase("missed_box")
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
	var per: Array = work.get("wheel_tyres", [])
	if per.size() != 4:
		per = ["", "", "", ""]
		for w in wheels:
			per[int(w)] = tyre
	if tyre != "" and not wheels.is_empty():
		var warm := lerpf(sim.env.ambient_c, sim.env.track_c, 0.5) + 10.0
		for w in wheels:
			var id := str(per[int(w)])
			if not sim.tyre_defs.has(id):
				continue
			sim.fit_tyres(i, [int(w)], sim.tyre_defs[id])
			c.tyre_wear[int(w)] = 0.0
			c.tyre_temp[int(w)] = warm
			c.puncture[int(w)] = 0.0  # a new tyre fixes a puncture
		p["compound"] = sim.compounds[i].id
		p["compounds"] = sim.wheel_compounds[i].map(func(t: TyreCompound) -> String: return t.id)
		if wheels.size() == 4:
			p["stint_lap"] = e.laps_done
	var trim: Array = work.get("psi_trim", [])
	if trim.size() == 4:
		p["psi_trim"] = trim.duplicate()
		c.psi_trim = PackedFloat64Array(trim)
	(p["plan"] as Dictionary).erase("wheel_tyres")
	(p["plan"] as Dictionary).erase("psi")
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
	p["last_stop"] = {"lap": lap, "stationary_s": p["service_total"], "tyre": tyre, "wheels": wheels if tyre != "" else [],
		"wheel_tyres": per if tyre != "" else [],
		"fuel_l": work.get("fuel_l", 0.0), "repairs": work.get("repair_parts", []), "setup": work.get("setup", {}),
		"driver": handed}
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


# --- The pit guide line (drivers driving in themselves) ------------------------

## The line a driver follows into the pits, to their box and out again, for
## car i: GUIDE_LEAD metres along the track before the guided route, then the
## route (easing to the pit side, down the lane past the boxes, back onto the
## track), with the speed to be doing at each point: braking in time for the
## pit limit line, the limit through the zone, braking onto the box (speed 0
## there), the limit again to the end of the zone. Guide metres throughout
## (route metres + GUIDE_LEAD). {} without a pit lane.
## {points: PackedVector2Array, dist, speed: PackedFloat64Array, length,
##  limit_start, limit_end, box_d, box_pos, box_heading, limit: m/s}
func guide_line(i: int) -> Dictionary:
	if not enabled:
		return {}
	var t := sim.track
	var pts := PackedVector2Array()
	var dist := PackedFloat64Array()
	var lead := int(GUIDE_LEAD / ROUTE_STEP)
	for k in lead:
		var s := commit_s - GUIDE_LEAD + k * ROUTE_STEP
		pts.append(t.position_at(fposmod(s, t.length), 0.0))
		dist.append(k * ROUTE_STEP)
	for k in route.size():
		pts.append(route[k])
		dist.append(GUIDE_LEAD + route_cum[k])
	var box_d := GUIDE_LEAD + _box_d(i)
	# Near the box the line swings over from the fast lane onto the box
	# (the garage side), and back out after it.
	for k in pts.size():
		var into := smoothstep(box_d - 32.0, box_d - 8.0, dist[k]) * (1.0 - smoothstep(box_d + 6.0, box_d + 30.0, dist[k]))
		if into > 0.0:
			var lane_d := dist[k] - GUIDE_LEAD - lane_start
			pts[k] = pts[k].lerp(t.pit_position_at(lane_d, t.pit_side * t.pit_width * 0.25), into)
	var ls := GUIDE_LEAD + limit_start
	var le := GUIDE_LEAD + limit_end
	var vl := t.pit_speed_limit - 0.4
	var m := pts.size()
	var speed := PackedFloat64Array()
	speed.resize(m)
	for k in m:
		var v := GUIDE_MAX_SPEED
		if k >= 2 and k < m - 2:
			v = minf(v, sqrt(GUIDE_LATERAL_G * _radius(pts[k - 2], pts[k], pts[k + 2])))
		if dist[k] >= ls - 2.0 and dist[k] <= le:
			v = minf(v, vl)
		if dist[k] >= ls and dist[k] < box_d + 1.0:
			v = minf(v, sqrt(2.0 * GUIDE_BOX_DECEL * maxf(box_d - dist[k], 0.0)))
		speed[k] = v
	# Braking in time, backwards from every slow point (not across the box:
	# leaving it, the car pulls away from rest).
	for j in m - 1:
		var k := m - 2 - j
		if dist[k] >= box_d - 1.0:
			continue
		var ds := dist[k + 1] - dist[k]
		var dec := GUIDE_BOX_DECEL if dist[k] >= ls else GUIDE_DECEL
		speed[k] = minf(speed[k], sqrt(speed[k + 1] * speed[k + 1] + 2.0 * dec * ds))
	var box: Dictionary = t.pit_box(box_index(i))
	return {"points": pts, "dist": dist, "speed": speed, "length": dist[m - 1], "limit_start": ls,
		"limit_end": le, "box_d": box_d, "box_pos": box["pos"], "box_heading": box["heading"], "limit": t.pit_speed_limit}


## Where car i is along its guide line (guide metres; negative before the
## line starts), or GUIDE_NONE when it isn't heading into the pits: no box
## call, or the pits are still more than GUIDE_AHEAD metres away. Doesn't
## change anything (any machine, any car).
func guide_progress(i: int) -> float:
	if not enabled:
		return GUIDE_NONE
	var p: Dictionary = sim.entries[i].pit
	var ph: String = p["phase"]
	if ph == PHASE_NONE:
		if not p["box"] or sim.entries[i].finished:
			return GUIDE_NONE
		var to_commit := fposmod(commit_s - sim.cars[i].track_s, sim.track.length)
		if to_commit > sim.track.length - 80.0:
			to_commit -= sim.track.length   # just past the commit point
		return GUIDE_LEAD - to_commit if to_commit <= GUIDE_AHEAD else GUIDE_NONE
	var keep := _route_k[i]
	var d := _route_d(i)
	_route_k[i] = keep
	return GUIDE_LEAD + d


## What a driver driving in themselves needs to know right now, for the HUD:
## {stage: "approach" (to the limit line) / "box" (to the box) / "service" /
##  "leave" (to the end of the limit) / "" (nothing), to_limit: metres to the
##  limit line, to_box: metres to the box marks (negative = past them),
##  to_end: metres to the end of the limit, limit: m/s, speed: m/s,
##  brake_at: metres before the limit line / box where braking has to start
##  (at GUIDE_DECEL / GUIDE_BOX_DECEL), across: metres off the box sideways,
##  on_marks: stopped well enough here,
##  missed: drove past the box}
func guide_info(i: int) -> Dictionary:
	var g := guide_progress(i)
	if g <= GUIDE_NONE:
		return {"stage": ""}
	var p: Dictionary = sim.entries[i].pit
	var c := sim.cars[i]
	var v := c.speed()
	var lim := sim.track.pit_speed_limit
	var out := {"stage": "", "limit": lim, "speed": v, "missed": bool(p.get("missed_box", false))}
	out["to_limit"] = GUIDE_LEAD + limit_start - g
	out["to_end"] = GUIDE_LEAD + limit_end - g
	var m := box_marks(i, c.pos)
	out["to_box"] = -float(m["along"])
	out["across"] = float(m["across"])
	out["on_marks"] = float(m["along"]) > -BOX_STOP_SHORT and float(m["along"]) <= BOX_STOP_LONG \
		and absf(m["across"]) < BOX_STOP_WIDE
	match str(p["phase"]):
		PHASE_NONE, PHASE_APPROACH, PHASE_ENTRY:
			out["stage"] = "approach"
			out["brake_at"] = maxf(v * v - lim * lim, 0.0) / (2.0 * GUIDE_DECEL)
		PHASE_LIMIT:
			out["stage"] = "leave" if out["missed"] else "box"
			out["brake_at"] = v * v / (2.0 * GUIDE_BOX_DECEL)
		PHASE_SERVICE:
			out["stage"] = "service"
		PHASE_LEAVE:
			out["stage"] = "leave"
	return out


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
				"stationary_s": last.get("stationary_s", 0.0), "tyre": last.get("tyre", ""), "wheels": last.get("wheels", []),
				"fuel_l": last.get("fuel_l", 0.0), "driver": last.get("driver", ""),
				"in_window": int(p["window_stops"]) > int(was.get("window_stops", 0))})
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
	var idx := int(e.pit.get("driver_idx", 0))
	if idx >= 0 and idx < e.lineup.size():
		e.traits = e.lineup[idx].get("traits", e.traits)
	var comp: String = e.pit.get("compound", "")
	var per: Array = e.pit.get("compounds", [])
	if per.size() == 4:
		for w in 4:
			var id := str(per[w])
			if sim.tyre_defs.has(id) and (sim.wheel_compounds[i][w] as TyreCompound).id != id:
				sim.fit_tyres(i, [w], sim.tyre_defs[id])
	# A state that only names the main compound (or disagrees with the wheels): all four.
	if comp != "" and sim.tyre_defs.has(comp) and sim.compounds[i].id != comp:
		sim.fit_tyres(i, [0, 1, 2, 3], sim.tyre_defs[comp])
	var trim: Array = e.pit.get("psi_trim", [])
	if trim.size() == 4:
		sim.cars[i].psi_trim = PackedFloat64Array(trim)


## Short signature of a car's pit state: changes when the owner should tell the host.
static func signature(p: Dictionary) -> String:
	return "%s|%s|%s|%s|%d|%d|%d|%s|%s|%d|%d|%s" % [p["phase"], p["auto"], p["box"], p["limiter"], p["stops"],
		p["window_stops"], p["speeding"], p["compound"], str(p["plan"]), int(float(p["service_left"]) * 2.0),
		int(p.get("driver_idx", 0)), str(p.get("compounds", ""))]


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
