class_name DamageAdvice
extends RefCounted
## Damage advice for the strategist: how bad a car's damage is, the lap time
## it is costing, what fixing it would cost in the pits, and a call: box for
## it, fix it at the stop you are making anyway, leave it, or your call.
##
## Pure data like the rest of the race data: it only reads the sim (CarDamage
## for the damage, PitRules for the repair times, the same numbers every
## stop uses: repair_parts / REPAIR_MIN, service_for, stop_loss) and the
## timing gaps, and never changes the race.

## Share of a clean lap each system costs, at damage 0, 0.25, 0.5, 0.75 and
## 1.0 (straight lines in between). Measured with tests/damage_pace_probe.gd:
## a BMW M4 GT3 on AI alone, the damage held, laps 2-3 against the same car
## clean, at Brands Hatch, Spa and Monza (the mean of the three; the spread
## is about a third either way, so the screen calls it an estimate).
const LOSS_AT := [0.0, 0.25, 0.5, 0.75, 1.0]
const LOSS := {
	"aero": [0.0, 0.0177, 0.0393, 0.0651, 0.0877],
	"suspension": [0.0, 0.0208, 0.0466, 0.0841, 0.133],
	"alignment": [0.0, 0.0074, 0.0231, 0.044, 0.0686],
	"engine": [0.0, 0.0139, 0.034, 0.0624, 0.098],
	"gearbox": [0.0, 0.0042, 0.0079, 0.0315, 0.0949],
}
## Share of a lap one flat tyre costs (front 52%, rear 60%, same probe).
const PUNCTURE_LOSS := 0.56

## How bad it is, worst system 0..1 (CarDamage.worst).
const LEVELS := ["NONE", "SCUFFS", "LIGHT", "MODERATE", "HEAVY", "CRITICAL"]
const NONE := 0
const SCUFFS := 1
const LIGHT := 2
const MODERATE := 3
const HEAVY := 4
const CRITICAL := 5

## The calls.
const BOX_NOW := "BOX NOW"
const FIX_AT_STOP := "FIX AT YOUR STOP"
const SKIP_REPAIR := "STOP, BUT DON'T REPAIR"
const STAY_OUT := "STAY OUT"
const YOUR_CALL := "YOUR CALL"
const NO_ADVICE := ""

## A call closer than this (seconds over the rest of the race) is your call.
const CLOSE_S := 2.5
## Lap time lost (s) from which a stop that is due anyway is brought forward.
const BRING_FORWARD_S := 0.8

## Rows the advice lists: a repair the crew does covers each of these.
const ROWS := [
	["aero", "Aero / bodywork"],
	["suspension", "Suspension"],
	["engine", "Engine"],
	["gearbox", "Gearbox"],
	["tyres", "Punctures"],
]


## Seconds a lap at this damage costs, from LOSS.
static func part_loss_share(part: String, dmg: float) -> float:
	var t: Array = LOSS.get(part, [])
	if t.is_empty():
		return 0.0
	var d := clampf(absf(dmg), 0.0, 1.0)
	for k in range(1, LOSS_AT.size()):
		if d <= LOSS_AT[k]:
			var a: float = LOSS_AT[k - 1]
			var b: float = LOSS_AT[k]
			return lerpf(float(t[k - 1]), float(t[k]), (d - a) / (b - a))
	return float(t[-1])


## The lap time a clean lap of this car takes (what the shares are of).
static func reference_lap(sim: RaceSim, tel, i: int) -> float:
	if tel != null and i < tel.cars.size():
		var c: CarTelemetry = tel.cars[i]
		if c.last5_avg > 0.0:
			return c.last5_avg
		if c.best_lap() > 0.0:
			return c.best_lap()
	var e := sim.entries[i]
	if e.best_lap > 0.0:
		return e.best_lap
	return sim.track.length / 42.0


## How bad: NONE .. CRITICAL.
static func severity(sim: RaceSim, i: int) -> int:
	if sim.damage_level == CarDamage.Level.OFF:
		return NONE
	var c := sim.cars[i]
	if CarDamage.punctures(c) > 0 or CarDamage.engine_failed(c) or c.damage_engine >= CarDamage.ENGINE_LEAK_FROM \
			or c.damage_gearbox > CarDamage.GEARBOX_LOSE_FROM:
		return CRITICAL
	var w := CarDamage.worst(c)
	if w < 0.01 and CarDamage.body_total(c) < 0.01:
		return NONE
	if w < PitRules.REPAIR_MIN:
		return SCUFFS
	if w < 0.3:
		return LIGHT
	if w < 0.6:
		return MODERATE
	return HEAVY


static func level_colour(level: int) -> Color:
	return [Color(0.55, 0.9, 0.6), Color(0.7, 0.85, 0.7), Color(1.0, 0.85, 0.4), Color(1.0, 0.62, 0.3),
		Color(1.0, 0.4, 0.3), Color(1.0, 0.25, 0.25)][clampi(level, 0, 5)]


static func call_colour(call: String) -> Color:
	match call:
		BOX_NOW:
			return Color(1.0, 0.4, 0.3)
		FIX_AT_STOP:
			return Color(1.0, 0.75, 0.4)
		SKIP_REPAIR, STAY_OUT:
			return Color(0.55, 0.9, 0.6)
	return Color(0.9, 0.9, 0.95)


## The advice for car i:
## {level: NONE..CRITICAL, level_text, parts: [{part, label, pct (0..100),
##  loss_s (per lap), repair_s, fixed (the crew would fix it at a stop)}],
##  loss_lap: s/lap lost, laps_left: laps after this one, cost_out: s lost
##  to the flag staying damaged, repair_s: crew time for the repairs,
##  stop_due: a stop is needed anyway (fuel, tyres, mandatory),
##  stop_loss: s a stop just for the repairs costs (lane + standing),
##  places: places a repair costs (the cars that get by), call, why, risk}
static func assess(sim: RaceSim, tel, i: int) -> Dictionary:
	var out := {"level": NONE, "level_text": LEVELS[NONE], "parts": [], "loss_lap": 0.0, "laps_left": 0,
		"cost_out": 0.0, "repair_s": 0.0, "stop_due": false, "stop_loss": 0.0, "places": 0,
		"call": NO_ADVICE, "why": "", "risk": ""}
	if i < 0 or i >= sim.car_count() or sim.damage_level == CarDamage.Level.OFF:
		return out
	var c := sim.cars[i]
	var level := severity(sim, i)
	out["level"] = level
	out["level_text"] = LEVELS[level]
	if level == NONE:
		return out
	var full := sim.damage_level == CarDamage.Level.FULL
	var lap := reference_lap(sim, tel, i)
	var fixes := PitRules.repair_parts(c)
	var plan := CarDamage.repair_plan(c)
	var levels := {"aero": c.damage_aero, "suspension": maxf(c.damage_suspension, absf(c.alignment)),
		"engine": c.damage_engine, "gearbox": c.damage_gearbox}
	var loss_lap := 0.0
	var parts := []
	for row in ROWS:
		var part: String = row[0]
		var loss := 0.0
		var pct := 0.0
		if part == "tyres":
			var n := CarDamage.punctures(c)
			if n == 0:
				continue
			pct = 100.0 * n
			loss = lap * PUNCTURE_LOSS * n
		else:
			pct = float(levels[part]) * 100.0
			if pct < 1.0:
				continue
			loss = lap * part_loss_share(part, float(levels[part]) if part != "suspension" else c.damage_suspension)
			if part == "suspension":
				loss += lap * part_loss_share("alignment", c.alignment)
		if not full:
			loss = 0.0
		loss_lap += loss
		var fixed := fixes.has(part)
		parts.append({"part": part, "label": row[1], "pct": pct, "loss_s": loss,
			"repair_s": float(plan.get(part, 0.0)) if fixed else 0.0, "fixed": fixed})
	out["parts"] = parts
	out["loss_lap"] = loss_lap
	if not full:
		out["why"] = "Looks only: damage doesn't slow the car in this race."
		return out
	var pits := sim.pits
	if pits == null or not pits.enabled:
		out["why"] = "No pit stops in this race: drive round it."
		return out
	var e := sim.entries[i]
	var laps_left := pits.laps_after_this(i)
	out["laps_left"] = laps_left
	var cost_out := loss_lap * laps_left
	out["cost_out"] = cost_out
	# The repairs the crew would do (the same rule as every stop).
	var with_fix: Dictionary = (e.pit["plan"] as Dictionary).duplicate()
	with_fix["repair"] = true
	var no_fix := with_fix.duplicate()
	no_fix["repair"] = false
	var repair_s := float(pits.service_for(i, with_fix)["repair_s"])
	out["repair_s"] = repair_s
	var due := stop_due(sim, tel, i)
	out["stop_due"] = due
	var saving := 1.0 - sim.pit_time_saving()
	# With a stop due anyway, the repairs add to that stop; otherwise it's a
	# stop just for them (tyres kept unless one is flat, no fuel).
	var just_fix := {"tyre": PitRules.TYRE_KEEP, "wheels": PitRules.WHEELS_ALL, "fuel": 0.0, "repair": true, "driver_change": false}
	var loss_fix := pits.stop_loss(i, with_fix if due else just_fix) * saving
	var loss_nofix := pits.stop_loss(i, no_fix) * saving
	out["stop_loss"] = loss_fix
	# Places the repair costs: the cars close enough behind to get by.
	var places := places_within(sim, tel, i, loss_fix) - (places_within(sim, tel, i, loss_nofix) if due else 0)
	out["places"] = maxi(places, 0)
	# Things that won't wait.
	if CarDamage.punctures(c) > 0:
		out["risk"] = "Running on the rim: slow, and a second flat ends the race."
		out["call"] = BOX_NOW
		out["why"] = "Flat tyre: about %.0f s a lap lost. The tyre change mends it." % (lap * PUNCTURE_LOSS)
		return out
	if c.damage_engine >= CarDamage.ENGINE_LEAK_FROM and not CarDamage.engine_failed(c):
		out["risk"] = "Engine leaking: it gets worse under load and will fail."
		if laps_left == 0:
			out["call"] = YOUR_CALL
			out["why"] = "Last lap: short-shift and nurse it to the flag."
		else:
			out["call"] = BOX_NOW
			out["why"] = "Repairs take %.0f s, the engine won't last %d more laps." % [repair_s, laps_left]
		return out
	if c.damage_gearbox > CarDamage.GEARBOX_LOSE_FROM:
		out["risk"] = "Gearbox losing gears: it only has %d of %d." % [
			CarDamage.usable_gears(c, sim.defs[i].gear_ratios.size()), sim.defs[i].gear_ratios.size()]
	if repair_s <= 0.0:
		out["call"] = STAY_OUT
		out["why"] = "Scuffs only: the crew wouldn't touch them."
		if not fixes.is_empty():
			out["why"] = "Bodywork only: taped up for free at your next stop."
		return out
	if laps_left == 0:
		out["call"] = STAY_OUT
		out["why"] = "Last lap: bring it home, about %.1f s lost." % loss_lap
		return out
	var place_txt := "" if out["places"] == 0 else ", costs %d place%s" % [out["places"], "" if out["places"] == 1 else "s"]
	if due:
		# A stop is coming anyway: is the repair worth its time at that stop?
		var gain := cost_out - repair_s
		if gain > CLOSE_S:
			out["call"] = BOX_NOW if loss_lap >= BRING_FORWARD_S else FIX_AT_STOP
			out["why"] = "Fixing adds %.0f s to your stop%s; leaving it costs %.0f s to the flag." % [repair_s, place_txt, cost_out]
		elif gain < -CLOSE_S:
			out["call"] = SKIP_REPAIR
			out["why"] = "Repairs add %.0f s, more than the %.0f s the damage costs to the flag." % [repair_s, cost_out]
		else:
			out["call"] = YOUR_CALL
			out["why"] = "Repairs add %.0f s%s, the damage costs about %.0f s: much the same." % [repair_s, place_txt, cost_out]
		return out
	var gain2 := cost_out - loss_fix
	if gain2 > CLOSE_S:
		out["call"] = BOX_NOW
		out["why"] = "A stop to fix it loses %.0f s%s; staying out loses %.0f s to the flag." % [loss_fix, place_txt, cost_out]
	elif gain2 < -CLOSE_S:
		out["call"] = STAY_OUT
		out["why"] = "Staying out loses %.0f s to the flag; a stop to fix it loses %.0f s%s." % [cost_out, loss_fix, place_txt]
		if loss_lap > 0.05:
			out["why"] += " A stop pays with %d+ laps to go." % ceili(loss_fix / loss_lap)
	else:
		out["call"] = YOUR_CALL
		out["why"] = "A stop loses %.0f s%s, staying out about %.0f s: much the same." % [loss_fix, place_txt, cost_out]
	return out


## Will car i stop again before the flag anyway? A mandatory stop still to
## make, not enough fuel, or a tyre that won't last.
static func stop_due(sim: RaceSim, tel, i: int) -> bool:
	var pits := sim.pits
	if pits.mandatory_left(i) > 0:
		return true
	var to_go := pits.laps_after_this(i) + 1
	if sim.settings.fuel_enabled and pits.fuel_laps(i) < to_go:
		return true
	if sim.settings.tyre_wear_enabled and tel != null and i < tel.cars.size():
		var rate: PackedFloat64Array = (tel.cars[i] as CarTelemetry).wear_per_lap()
		for w in 4:
			if CarTelemetry.laps_to_worn(sim.cars[i].tyre_wear[w], rate[w]) < to_go:
				return true
	return false


## Running cars behind car i (on the road, any class) within `loss` seconds:
## the places a stop that long costs.
static func places_within(sim: RaceSim, tel, i: int, loss: float) -> int:
	if tel == null or i >= tel.cars.size():
		return 0
	var me: CarTelemetry = tel.cars[i]
	var n := 0
	for j in sim.car_count():
		var o := sim.entries[j]
		if j == i or o.finished or o.dnf or j >= tel.cars.size():
			continue
		if o.distance > sim.entries[i].distance:
			continue
		var g: float = (tel.cars[j] as CarTelemetry).gap_leader - me.gap_leader
		if g >= 0.0 and g < loss and tel.cars[j].laps_down == me.laps_down:
			n += 1
	return n
