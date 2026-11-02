class_name CarDamage
extends RefCounted
## Damage and repairs (wave 3). Pure static functions on CarState, so the
## race stays deterministic and runs the same headless.
##
## How a hit becomes damage:
##   * The race sim turns every car-to-car contact and barrier hit into a
##     change of speed (delta-v, m/s) and the direction of the hit point as
##     seen from the car (body frame: x forward, y right).
##   * The hit lands on one of four body zones (front, rear, left, right).
##     The zone's bodywork is bent (that is what you see on the car), and
##     the systems behind it take a share: the nose holds the splitter and
##     the radiators, the rear holds the wing, diffuser and gearbox, the
##     sides hold the suspension arms (and knock the alignment out).
##   * A hit close to a wheel can puncture that tyre. Kerbs taken flat out
##     wear the suspension and can puncture a tyre too (CarPhysics).
##
## What damage does (only at level FULL; CarPhysics reads it):
##   aero        less downforce and more drag, balance moves away from the
##               damaged end
##   suspension  less grip on every tyre
##   alignment   the car pulls to one side (signed, -1 left .. 1 right)
##   engine      less torque; past half it gets worse under load; at 1 it fails
##   gearbox     slow, power-cutting shifts; past 0.6 the top gears go
##   puncture    that tyre has almost no grip, drags and pulls the car over
##
## Levels: OFF = nothing, VISUAL = the bodywork bends but the car drives as
## new, FULL = everything above.

enum Level { OFF, VISUAL, FULL }
const LEVEL_IDS := ["off", "visual", "full"]

const FRONT := 0
const REAR := 1
const LEFT := 2
const RIGHT := 3
const ZONE_NAMES := ["front", "rear", "left", "right"]

## Hits below this delta-v (m/s) only scuff the paint.
const DV_MIN := 1.5
## Delta-v (m/s) of a hit that fully wrecks a zone's bodywork.
const DV_FULL := 20.0
## Delta-v (m/s) from which a hit near a wheel can puncture it.
const DV_PUNCTURE := 6.0
## How close (m) to a wheel a hit must land to puncture it.
const PUNCTURE_REACH := 0.9

## Share of a zone hit that each system takes, per zone:
## [aero, suspension, alignment, engine, gearbox]
const SPREAD := [
	[0.60, 0.25, 0.30, 0.35, 0.00],  # front: splitter, radiators, front arms
	[0.50, 0.20, 0.10, 0.00, 0.45],  # rear: wing, diffuser, gearbox
	[0.15, 0.45, 0.50, 0.00, 0.00],  # left side: suspension arms, toe
	[0.15, 0.45, 0.50, 0.00, 0.00],  # right side
]

## Engine past this damage gets worse under load (oil / water leaking).
const ENGINE_LEAK_FROM := 0.5
const ENGINE_LEAK_RATE := 0.012   ## per second at full throttle, full rpm, damage 1
## Gearbox: shift time (s) at full damage, and damage from which top gears go.
const GEARBOX_SHIFT_CUT := 0.45
const GEARBOX_LOSE_FROM := 0.6

## Pit repair time (seconds) per part: base + per unit of damage.
const REPAIR := {
	"aero": [8.0, 10.0],         # nose / wing change, panels taped up
	"suspension": [10.0, 30.0],  # arms, toe links, alignment
	"engine": [20.0, 60.0],      # radiators, oil lines; a failed engine is beyond the pits
	"gearbox": [15.0, 45.0],
	"tyres": [0.0, 0.0],         # punctures: needs a tyre change, nothing extra
}
const PARTS := ["aero", "suspension", "engine", "gearbox", "tyres"]


static func level_from(id: String) -> int:
	var k := LEVEL_IDS.find(id)
	return Level.OFF if k < 0 else k


# --- Taking damage ----------------------------------------------------------

## The point on the car's outline in direction `local_dir` (body frame).
static func outline_point(local_dir: Vector2, d: CarDefinition) -> Vector2:
	var n := local_dir.normalized()
	if n == Vector2.ZERO:
		return Vector2(d.length * 0.5, 0.0)
	var tx := (d.length * 0.5) / absf(n.x) if absf(n.x) > 1e-4 else INF
	var ty := (d.width * 0.5) / absf(n.y) if absf(n.y) > 1e-4 else INF
	return n * minf(tx, ty)


## Which zone a hit at `local_point` (body frame, metres) lands on.
static func zone_of(local_point: Vector2, d: CarDefinition) -> int:
	var fx := local_point.x / (d.length * 0.5)
	var fy := local_point.y / (d.width * 0.5)
	if absf(fx) >= absf(fy) * 0.9:
		return FRONT if fx >= 0.0 else REAR
	return RIGHT if fy >= 0.0 else LEFT


## Applies one hit. dv = change of speed it caused (m/s), local_point = where
## on the car it landed (body frame, metres, from the centre). salt makes
## the puncture roll deterministic (e.g. tick * 64 + car index).
## Returns what happened: {"zone", "amount", "punctured": wheel or -1,
## "engine_failed": bool, "gearbox_failed": bool}.
static func apply_impact(s: CarState, d: CarDefinition, dv: float, local_point: Vector2,
		level: int, salt: int) -> Dictionary:
	var out := {"zone": -1, "amount": 0.0, "punctured": -1, "engine_failed": false, "gearbox_failed": false}
	if level == Level.OFF or dv <= DV_MIN:
		return out
	# Damage grows faster than the speed of the hit (closer to its energy),
	# so rubbing wheels or a tap do little and a big hit does a lot.
	var amount := pow((dv - DV_MIN) / (DV_FULL - DV_MIN), 1.5)
	var zone := zone_of(local_point, d)
	out["zone"] = zone
	out["amount"] = amount
	s.body_damage[zone] = minf(s.body_damage[zone] + amount, 1.0)
	if level != Level.FULL:
		return out
	var engine_was := s.damage_engine
	var gearbox_was := s.damage_gearbox
	var w: Array = SPREAD[zone]
	s.damage_aero = minf(s.damage_aero + amount * w[0], 1.0)
	s.damage_suspension = minf(s.damage_suspension + amount * w[1], 1.0)
	# The car pulls towards the side that was hit.
	var side := signf(local_point.y) if zone < LEFT else (1.0 if zone == RIGHT else -1.0)
	s.alignment = clampf(s.alignment + side * amount * w[2], -1.0, 1.0)
	s.damage_engine = minf(s.damage_engine + amount * w[3], 1.0)
	s.damage_gearbox = minf(s.damage_gearbox + amount * w[4], 1.0)
	out["engine_failed"] = engine_was < 1.0 and s.damage_engine >= 1.0
	out["gearbox_failed"] = gearbox_was < 1.0 and s.damage_gearbox >= 1.0
	# Puncture: a hard hit landing next to a wheel.
	if dv > DV_PUNCTURE:
		var wheel := nearest_wheel(local_point, d)
		if wheel >= 0 and s.puncture[wheel] < 0.5:
			var chance := clampf((dv - DV_PUNCTURE) / 12.0, 0.0, 0.85)
			if roll(salt) < chance:
				s.puncture[wheel] = 1.0
				out["punctured"] = wheel
	return out


## Index of the wheel within PUNCTURE_REACH of a body-frame point, or -1.
static func nearest_wheel(p: Vector2, d: CarDefinition) -> int:
	var best := -1
	var best_d := PUNCTURE_REACH
	for i in 4:
		var dist := p.distance_to(wheel_pos(i, d))
		if dist < best_d:
			best_d = dist
			best = i
	return best


## Body-frame position of a wheel (CarState.FL / FR / RL / RR).
static func wheel_pos(i: int, d: CarDefinition) -> Vector2:
	var x := d.cg_to_front if i < 2 else -(d.wheelbase - d.cg_to_front)
	var y := d.track_width * 0.5 * (1.0 if i % 2 == 1 else -1.0)
	return Vector2(x, y)


## Deterministic 0..1 from an integer (no RNG, so replays match).
static func roll(salt: int) -> float:
	var h := hash(salt * 2654435761 + 97531)
	return float(h & 0xFFFF) / 65535.0


## How serious a hit of delta-v dv (m/s) is, 0..1 (1 = a wrecking hit).
static func severity(dv: float) -> float:
	return clampf((dv - DV_MIN) / (DV_FULL - DV_MIN), 0.0, 1.0)


# --- State queries --------------------------------------------------------

static func punctures(s: CarState) -> int:
	var n := 0
	for i in 4:
		if s.puncture[i] > 0.5:
			n += 1
	return n


static func engine_failed(s: CarState) -> bool:
	return s.damage_engine >= 1.0


## The car can't race on: engine gone, or two or more tyres flat.
static func is_crippled(s: CarState) -> bool:
	return engine_failed(s) or punctures(s) >= 2


## Forward gears the gearbox still has (of n).
static func usable_gears(s: CarState, n: int) -> int:
	if s.damage_gearbox <= GEARBOX_LOSE_FROM:
		return n
	var lost := int(ceil((s.damage_gearbox - GEARBOX_LOSE_FROM) / 0.15))
	return clampi(n - lost, 2, n)


## One number for "how bad": the worst system (0..1), for the HUD and AI.
static func worst(s: CarState) -> float:
	var w := maxf(maxf(s.damage_aero, s.damage_suspension), maxf(s.damage_engine, s.damage_gearbox))
	w = maxf(w, absf(s.alignment))
	if punctures(s) > 0:
		w = maxf(w, 0.7)
	return w


## Total bodywork bend (sum of the four zones), what the visuals show.
static func body_total(s: CarState) -> float:
	return s.body_damage[0] + s.body_damage[1] + s.body_damage[2] + s.body_damage[3]


## What each 3D part should look like, 0 = as new .. 1 = hanging off / gone.
## Wheels: 1 = punctured (running on the rim). "smoke": engine smoke 0..1.
static func visual_parts(s: CarState) -> Dictionary:
	var f := s.body_damage[FRONT]
	var r := s.body_damage[REAR]
	var l := s.body_damage[LEFT]
	var rt := s.body_damage[RIGHT]
	return {
		"splitter": clampf(f * 1.4, 0.0, 1.0),
		"front_bumper": f,
		"bonnet": clampf(f * 0.7, 0.0, 1.0),
		"rear_wing": clampf(r * 1.3, 0.0, 1.0),
		"diffuser": clampf(r * 1.1, 0.0, 1.0),
		"rear_bumper": r,
		"side_left": l,
		"side_right": rt,
		"mirror_left": clampf(l * 1.6, 0.0, 1.0),
		"mirror_right": clampf(rt * 1.6, 0.0, 1.0),
		"wheel_fl": s.puncture[0], "wheel_fr": s.puncture[1],
		"wheel_rl": s.puncture[2], "wheel_rr": s.puncture[3],
		"smoke": clampf((s.damage_engine - 0.3) / 0.7, 0.0, 1.0),
	}


## Per-system damage for the HUD / pit wall, 0..1 each.
static func report(s: CarState) -> Dictionary:
	return {
		"aero": s.damage_aero, "suspension": s.damage_suspension, "alignment": s.alignment,
		"engine": s.damage_engine, "gearbox": s.damage_gearbox,
		"punctures": [s.puncture[0] > 0.5, s.puncture[1] > 0.5, s.puncture[2] > 0.5, s.puncture[3] > 0.5],
		"body": [s.body_damage[0], s.body_damage[1], s.body_damage[2], s.body_damage[3]],
	}


# --- Repairs (the pit stop calls these) -------------------------------------

## Seconds each damaged part takes to fix in the pits. Only parts that need
## work are listed. "tyres" (punctures) costs 0 s: it needs a tyre change.
## Bodywork with no performance damage (VISUAL level) is fixed for free with
## "aero".
static func repair_plan(s: CarState) -> Dictionary:
	var plan := {}
	var levels := {
		"aero": s.damage_aero,
		"suspension": maxf(s.damage_suspension, absf(s.alignment)),
		"engine": s.damage_engine,
		"gearbox": s.damage_gearbox,
	}
	for part in levels:
		var dmg: float = levels[part]
		if dmg > 0.01:
			plan[part] = REPAIR[part][0] + REPAIR[part][1] * dmg
	if not plan.has("aero") and body_total(s) > 0.01:
		plan["aero"] = 0.0
	if punctures(s) > 0:
		plan["tyres"] = 0.0
	return plan


## Total pit time to repair `parts` (empty = everything that needs it). The
## crew works on them one after another, so the times add up.
static func repair_time(s: CarState, parts: Array = []) -> float:
	var plan := repair_plan(s)
	var t := 0.0
	for part in plan:
		if parts.is_empty() or parts.has(part):
			t += plan[part]
	return t


## Fixes `parts` (empty = everything). A failed engine can't be fixed in the
## pits; the car has already retired.
static func repair(s: CarState, parts: Array = []) -> void:
	var all := parts.is_empty()
	if all or parts.has("aero"):
		s.damage_aero = 0.0
		for z in 4:
			s.body_damage[z] = 0.0
	if all or parts.has("suspension"):
		s.damage_suspension = 0.0
		s.alignment = 0.0
	if (all or parts.has("engine")) and not engine_failed(s):
		s.damage_engine = 0.0
	if all or parts.has("gearbox"):
		s.damage_gearbox = 0.0
		s.shift_cut = 0.0
	if all or parts.has("tyres"):
		for i in 4:
			s.puncture[i] = 0.0
