class_name AIPitStrategy
extends RefCounted
## When an AI driver pits, and what for. Decides once a lap, a little before
## the pit entry, from:
##  * mandatory stops: the host's number of stops must be made inside the pit
##    window. Each driver picks the laps at the start: spread over the window,
##    earlier for aggressive drivers (the undercut), later for drivers who look
##    after their tyres, with a little randomness so the field splits.
##  * fuel: never runs dry; stops when the next lap would be too tight.
##  * tyres: worn tyres (the limit depends on tyre management and how many laps
##    are left), or the wrong tyres for the weather (wet skill decides how long
##    a driver stays out on slicks in the wet; forecast rain keeps them out on
##    wets).
##  * damage worth repairing.
##  * gaps: a planned stop waits a lap if the car would come out in traffic
##    and the window allows; aggressive drivers stop early to undercut a car
##    just ahead.
##  * safety car: a stop under the safety car costs less, so drivers who need
##    to stop anyway take it.
## The plan (tyres, fuel, repairs) goes to the race's PitRules, which then
## drives the car into the pits.

var profile: DriverTraits
var rng := RandomNumberGenerator.new()
## Optional race data (telemetry module) for gaps and the forecast. Anything
## with cars[i].pit = {clear_air, ...} and forecast.rain_in(secs).
var telemetry = null
var planned_laps: Array[int] = []
var reason := ""                 ## why the car is boxing (for the radio / HUD)
var _decided_lap := -1
var _delayed := 0


func _init(p_profile: DriverTraits, seed: int) -> void:
	profile = p_profile
	rng.seed = seed


## Every tick, on the machine that drives the car.
func update(sim: RaceSim, me: int) -> void:
	var pits := sim.pits
	if pits == null or not pits.enabled:
		return
	var e := sim.entries[me]
	if sim.phase != RaceSim.Phase.RACING or e.finished or e.dnf:
		return
	if planned_laps.is_empty() and sim.settings.mandatory_pit_stops > 0:
		_plan_laps(sim)
	if e.pit["phase"] != PitRules.PHASE_NONE or e.pit["box"]:
		return
	# Decide once a lap, a little before the car would be taken into the pits.
	var to_commit := fposmod(pits.commit_s - sim.cars[me].track_s, sim.track.length)
	if to_commit > 260.0 or to_commit < 60.0:
		return
	var lap := pits.current_lap(me)
	if _decided_lap == lap:
		return
	_decided_lap = lap
	reason = _reason_to_box(sim, me, lap)
	if reason == "":
		return
	var plan := _plan(sim, me)
	plan["box"] = true
	pits.set_plan(me, plan)
	_radio(sim, me, plan)


func _plan_laps(sim: RaceSim) -> void:
	var pits := sim.pits
	var n := sim.settings.mandatory_pit_stops
	var span := pits.window_close - pits.window_open
	var shift := 0
	if profile.aggression > 0.65:
		shift -= 1
	if profile.tyre_management > 0.7:
		shift += 1
	for k in n:
		var lap := pits.window_open + roundi(float(k + 1) * span / (n + 1)) + shift + rng.randi_range(-1, 1)
		planned_laps.append(clampi(lap, pits.window_open, pits.window_close))
	planned_laps.sort()


func _reason_to_box(sim: RaceSim, me: int, lap: int) -> String:
	var pits := sim.pits
	var c := sim.cars[me]
	var e := sim.entries[me]
	var laps_after := pits.laps_after_this(me)
	var p := profile
	# Fuel: will it reach the end? If not, stop before the tank runs too low.
	var fuel_laps := pits.fuel_laps(me)
	var needs_fuel := fuel_laps < laps_after + 1.05
	if needs_fuel and fuel_laps < 2.05:
		return "fuel"
	# Wrong tyres for the weather.
	var kind := sim.compounds[me].kind
	var w := sim.env.wetness
	var rain_soon := _rain_soon(sim)
	if laps_after >= 1:
		if kind == "dry" and w > 0.22 + 0.25 * p.wet_skill and (sim.env.rain > 0.15 or w > 0.5):
			return "wet"
		if kind != "dry" and w < 0.1 and sim.env.rain < 0.05 and not rain_soon:
			return "dry"
		if kind == "wet" and w < 0.35 and sim.env.rain < 0.3:
			return "inters"
	# Worn tyres: the limit rises when only a few laps are left.
	var wear := _avg_wear(c)
	var wear_limit := lerpf(0.55, 0.75, p.tyre_management) + 0.06 * p.aggression + 0.05 * maxf(3.0 - laps_after, 0.0)
	if laps_after >= 1 and wear > wear_limit:
		return "tyres"
	# Damage worth fixing.
	var damage := maxf(c.damage_engine, maxf(c.damage_aero, c.damage_suspension))
	if sim.settings.damage_enabled and damage > 0.35 and laps_after >= 2:
		return "damage"
	# Mandatory stops.
	var left := pits.mandatory_left(me)
	var window_now := pits.in_window(lap)
	var cheap := sim.has_method("pit_time_saving") and float(sim.call("pit_time_saving")) > 0.2
	if left > 0 and window_now:
		var chances := pits.window_close - lap + 1
		if chances <= left:
			return "mandatory"
		if cheap:
			return "safety car"
		var due := planned_laps[mini(planned_laps.size() - left, planned_laps.size() - 1)] if not planned_laps.is_empty() else pits.window_open
		if lap >= due - 1 and _undercut_chance(sim, me):
			return "undercut"
		if lap >= due:
			# Coming out into traffic? Wait a lap if the window allows.
			if _delayed < 2 and chances > left + 1 and not _clear_air(sim, me):
				_delayed += 1
				return ""
			_delayed = 0
			return "mandatory"
	# Stopping anyway soon: take it while the safety car makes it cheap.
	if cheap and laps_after >= 2 and (needs_fuel or wear > wear_limit * 0.6):
		return "safety car"
	if needs_fuel and fuel_laps < 3.05 and _clear_air(sim, me) and (left == 0 or not window_now):
		return "fuel"
	return ""


func _plan(sim: RaceSim, me: int) -> Dictionary:
	var c := sim.cars[me]
	var tyre := PitRules.TYRE_AUTO
	match reason:
		"wet":
			tyre = PitRules.TYRE_WET if sim.env.wetness > 0.55 or sim.env.rain > 0.6 else PitRules.TYRE_INTER
		"inters":
			tyre = PitRules.TYRE_INTER
		"dry":
			tyre = PitRules.TYRE_DRY if not _rain_soon(sim) else PitRules.TYRE_INTER
	var damage := maxf(c.damage_engine, maxf(c.damage_aero, c.damage_suspension))
	var plan := {"tyre": tyre, "wheels": _wheels(sim, me, tyre), "fuel": PitRules.FUEL_AUTO, "repair": damage > 0.08}
	plan["driver_change"] = _driver_change_due(sim, me)
	return plan


## Which tyres to change: when the compound stays the same and one axle has
## worn much more than the other (still good), only that axle, which is quicker.
func _wheels(sim: RaceSim, me: int, tyre: String) -> String:
	var pits := sim.pits
	if tyre != PitRules.TYRE_AUTO or pits.compound_for_conditions(me) != sim.compounds[me].id:
		return PitRules.WHEELS_ALL
	var w := sim.cars[me].tyre_wear
	var front := (w[0] + w[1]) * 0.5
	var rear := (w[2] + w[3]) * 0.5
	var laps_after := pits.laps_after_this(me)
	# The fresher pair must last to the end (or the next stop) too.
	var fresh := minf(front, rear)
	if absf(front - rear) > 0.22 and fresh < 0.25 - 0.01 * laps_after:
		return "front" if front > rear else "rear"
	return PitRules.WHEELS_ALL


## Cars that share the car between drivers hand over at a stop once the
## driver at the wheel has done about half their share of the race or more
## (a stop is rarely exactly where the shares meet).
func _driver_change_due(sim: RaceSim, me: int) -> bool:
	var e := sim.entries[me]
	if e.lineup.size() < 2 or sim.pits.laps_after_this(me) < 1:
		return false
	var share := float(sim.settings.laps) / e.lineup.size()
	return sim.pits.driver_stint_laps(me) >= share * 0.5


func _avg_wear(c: CarState) -> float:
	var s := 0.0
	for k in 4:
		s += c.tyre_wear[k]
	return s / 4.0


func _rain_soon(sim: RaceSim) -> bool:
	if telemetry != null and telemetry.get("forecast") != null:
		return telemetry.forecast.rain_in(180.0) > 0.3
	return sim.env.next_change_in() >= 0.0 and sim.env.next_change_in() < 180.0 \
		and sim.env.next_weather() in ["light_rain", "heavy_rain"]


## Would the car come out of the pits with nobody close (within ~1.5 s)?
func _clear_air(sim: RaceSim, me: int) -> bool:
	if telemetry != null and telemetry.get("cars") != null and me < telemetry.cars.size():
		var pt = telemetry.cars[me].get("pit")
		if pt is Dictionary and pt.has("clear_air"):
			return bool(pt["clear_air"])
	var v := _avg_speed(sim, me)
	var rejoin := sim.entries[me].distance - sim.pits.stop_loss(me) * v
	for j in sim.car_count():
		if j == me or sim.entries[j].finished or sim.entries[j].dnf or sim.in_pit_lane(j):
			continue
		if absf(sim.entries[j].distance - rejoin) < 1.5 * v:
			return false
	return true


## A car just ahead (< 1.5 s) that hasn't stopped yet: stop first and use the
## new tyres to jump it. Aggressive drivers go for it.
func _undercut_chance(sim: RaceSim, me: int) -> bool:
	if profile.aggression < 0.6:
		return false
	var v := _avg_speed(sim, me)
	var mine := sim.entries[me]
	for j in sim.car_count():
		var other := sim.entries[j]
		if j == me or other.finished:
			continue
		var gap := other.distance - mine.distance
		if gap > 0.0 and gap < 1.5 * v and int(other.pit["window_stops"]) <= int(mine.pit["window_stops"]):
			return true
	return false


func _avg_speed(sim: RaceSim, me: int) -> float:
	var laps := sim.entries[me].lap_times
	if laps.size() > 0 and laps[-1] > 0.0:
		return sim.track.length / laps[-1]
	return 42.0


func _radio(sim: RaceSim, me: int, plan: Dictionary) -> void:
	if not sim.has_method("post_event"):
		return
	var tyre_word := {"auto": "", "dry": " for slicks", "intermediate": " for inters", "full_wet": " for full wets"}
	var lines := {
		"fuel": "Box this lap, we need fuel.",
		"wet": "It's too wet for slicks, boxing%s." % tyre_word.get(plan["tyre"], ""),
		"inters": "Rain's easing, boxing for inters.",
		"dry": "Dry line's there, boxing%s." % tyre_word.get(plan["tyre"], ""),
		"tyres": "Tyres are gone, box this lap.",
		"damage": "Car's damaged, boxing for repairs.",
		"mandatory": "Box this lap for the mandatory stop.",
		"undercut": "Going for the undercut, box now.",
		"safety car": "Safety car, box box, it's a cheap stop.",
	}
	sim.call("post_event", {"type": "radio", "car": me, "topic": "pit", "text": lines.get(reason, "Boxing this lap.")})
