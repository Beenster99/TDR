class_name AIDriver
extends RefCounted
## Placeholder AI: follows the track's racing line with pure-pursuit steering
## and a curvature-based speed profile. It produces a CarInput exactly like a
## human, so it runs on the server and is invisible to netcode.
##
## Traits (modules/ai/data/drivers.json) used in wave 1: skill, consistency.
## Reserved for wave 2: aggression, racecraft, tyre_management.

const SPACING := 4.0
const MAX_SPEED := 95.0
const EDGE_MARGIN := 2.6

var traits: Dictionary
var rng := RandomNumberGenerator.new()
var line: PackedVector2Array = []
var line_right: PackedVector2Array = []
var target_speed: PackedFloat64Array = []
var idx: int = -1
var lateral_bias: float = 0.0       ## avoidance offset (m, + right)
var speed_noise: float = 0.0
var noise_block: int = -1
var stuck_time: float = 0.0
var stuck_idx: int = 0
var recover_time: float = 0.0


## An AI driver for car i of a race, using that entry's traits.
static func for_car(sim: RaceSim, i: int) -> AIDriver:
	var traits := sim.entries[i].traits
	if traits.is_empty():
		traits = {"skill": 0.9, "consistency": 0.9}
	return AIDriver.new(sim.track, sim.defs[i], sim.compounds[i], traits, sim.settings.seed * 31 + i)


## car index -> AIDriver, for every AI entry in the race.
static func for_all_ai(sim: RaceSim) -> Dictionary:
	var ai := {}
	for i in sim.entries.size():
		if sim.entries[i].is_ai:
			ai[i] = for_car(sim, i)
	return ai


func _init(track: TrackData, def: CarDefinition, compound: TyreCompound, p_traits: Dictionary, seed: int) -> void:
	traits = p_traits
	rng.seed = seed
	_build_line(track)
	_build_speed_profile(def, compound)


func _trait(name: String, default: float) -> float:
	return float(traits.get(name, default))


func _build_line(track: TrackData) -> void:
	var src := track.raceline if track.raceline.size() > 10 else track.points
	# Resample to even spacing.
	var n := src.size()
	var total := 0.0
	for i in n:
		total += src[i].distance_to(src[(i + 1) % n])
	var count := int(total / SPACING)
	var step := total / count
	var seg := 0
	var seg_start := 0.0
	var seg_len := src[0].distance_to(src[1 % n])
	for k in count:
		var s := k * step
		while s > seg_start + seg_len:
			seg_start += seg_len
			seg = (seg + 1) % n
			seg_len = src[seg].distance_to(src[(seg + 1) % n])
		var t := (s - seg_start) / maxf(seg_len, 0.001)
		line.append(src[seg].lerp(src[(seg + 1) % n], t))
	# Keep a safety margin from the edges: the optimal line uses every
	# centimetre of track, which leaves no room for tracking error.
	var hint := -1
	for k in count:
		var q := track.project(line[k], hint)
		hint = q["idx"]
		var off: float = q["offset"]
		var lim: float = (q["w_right"] if off > 0.0 else q["w_left"]) - EDGE_MARGIN
		var clamped := clampf(off * 0.8, -maxf(lim, 0.0), maxf(lim, 0.0))
		line[k] += Vector2(-q["dir"].y, q["dir"].x) * (clamped - off)
	for k in count:
		var d := (line[(k + 1) % count] - line[(k - 1 + count) % count]).normalized()
		line_right.append(Vector2(-d.y, d.x))


func _build_speed_profile(def: CarDefinition, compound: TyreCompound) -> void:
	var n := line.size()
	var curv := PackedFloat64Array()
	curv.resize(n)
	for k in n:
		# Menger curvature over a +-3 point window (12 m chord) for smoothness.
		var a := line[(k - 3 + n) % n]
		var b := line[k]
		var c := line[(k + 3) % n]
		var area2 := absf((b - a).cross(c - a))
		var denom := a.distance_to(b) * b.distance_to(c) * c.distance_to(a)
		curv[k] = 2.0 * area2 / maxf(denom, 0.001)
	var skill := _trait("skill", 0.9)
	var mu := compound.peak_mu * def.front_grip * 0.84 * lerpf(0.88, 1.0, skill)
	var m := def.mass + 40.0
	var aero := 0.5 * 1.2 * def.cla * 0.6
	target_speed.resize(n)
	for k in n:
		var kk := maxf(curv[k], 1e-5)
		var den := m * kk - mu * aero
		var v := MAX_SPEED if den <= 0.0 else sqrt(mu * m * CarPhysics.G / den)
		target_speed[k] = minf(v, MAX_SPEED)
	# Backward pass: be able to brake in time for every corner.
	var decel := mu * CarPhysics.G * lerpf(0.75, 0.9, skill)
	for _pass in 2:
		for j in n:
			var k := n - 1 - j
			var nxt := target_speed[(k + 1) % n]
			target_speed[k] = minf(target_speed[k], sqrt(nxt * nxt + 2.0 * decel * SPACING))


func _nearest(pos: Vector2) -> int:
	var n := line.size()
	var best := 0
	var best_d := INF
	if idx >= 0:
		for o in range(-6, 16):
			var k := (idx + o + n) % n
			var d := pos.distance_squared_to(line[k])
			if d < best_d:
				best_d = d
				best = k
		if best_d < 40.0 * 40.0:
			return best
	for k in n:
		var d := pos.distance_squared_to(line[k])
		if d < best_d:
			best_d = d
			best = k
	return best


func get_input(sim: RaceSim, me: int) -> CarInput:
	var car := sim.cars[me]
	var def := sim.defs[me]
	var inp := CarInput.new()
	var n := line.size()
	idx = _nearest(car.pos)
	var speed := car.speed()
	var fwd := car.forward()
	var rgt := car.right()

	if sim.phase == RaceSim.Phase.COUNTDOWN:
		return inp

	# --- Stuck recovery: reverse out, then carry on. ---
	if recover_time > 0.0:
		recover_time -= RaceSim.TICK_DT
		inp.brake = 1.0
		var to_line := line[(idx + 3) % n] - car.pos
		inp.steer = -signf(to_line.dot(rgt))
		return inp
	# Stuck = little progress along the racing line for a while.
	stuck_time += RaceSim.TICK_DT
	if stuck_time >= 3.0:
		var progressed := wrapi(idx - stuck_idx, -n / 2, n / 2)
		if progressed < 2 and sim.phase != RaceSim.Phase.FINISHED:
			recover_time = 1.8
		stuck_time = 0.0
		stuck_idx = idx

	# --- Traffic: steer around a slower car directly ahead. ---
	var want_bias := 0.0
	var follow_limit := INF
	for j in sim.cars.size():
		if j == me:
			continue
		var rel := sim.cars[j].pos - car.pos
		var lx := rel.dot(fwd)
		var ly := rel.dot(rgt)
		if lx > 0.0 and lx < 25.0 and absf(ly) < 3.0:
			var closing := speed - sim.cars[j].vel.dot(fwd)
			if closing > 0.5:
				want_bias = -3.0 * signf(ly) if absf(ly) > 0.2 else 3.0 * (1.0 if me % 2 == 0 else -1.0)
				if lx < 10.0:
					follow_limit = minf(follow_limit, sim.cars[j].vel.dot(fwd) + lx * 0.5)
	lateral_bias = move_toward(lateral_bias, want_bias, 4.0 * RaceSim.TICK_DT)

	# --- Steering: pure pursuit on the racing line. ---
	var look := 5.0 + 0.42 * speed
	var ahead := (idx + int(look / SPACING)) % n
	var target := line[ahead] + line_right[ahead] * lateral_bias
	var local := target - car.pos
	var lx := local.dot(fwd)
	var ly := local.dot(rgt)
	var alpha := atan2(ly, maxf(lx, 0.1))
	var ld := maxf(local.length(), 1.0)
	var steer_angle := atan(2.0 * def.wheelbase * sin(alpha) / ld)
	# Catch slides: when the rear steps out (rear slip angle beyond the normal
	# cornering range), steer into the slide. Rear sliding left in a right-hander
	# gives a negative slip angle, and the fix is to steer left (negative).
	var excess_slip := car.slip_angle_rear - clampf(car.slip_angle_rear, -0.06, 0.06)
	steer_angle += 0.9 * excess_slip
	inp.steer = clampf(steer_angle / def.max_steer, -1.0, 1.0)

	# --- Speed: follow the profile, scaled by how warm the tyres are. ---
	var block := idx / 50
	if block != noise_block:
		noise_block = block
		speed_noise = rng.randfn(0.0, (1.0 - _trait("consistency", 0.9)) * 0.06)
	var grip := 0.0
	for i in 4:
		grip += sim.compounds[me].temp_grip_factor(car.tyre_temp[i])
	grip /= 4.0
	var v_target := target_speed[idx]
	for k in range(1, 2 + int(speed * 0.45 / SPACING)):
		v_target = minf(v_target, target_speed[(idx + k) % n])
	v_target *= sqrt(grip) * (1.0 + speed_noise)
	if car.surface == TrackData.Surface.GRASS:
		v_target = minf(v_target, 30.0)
	v_target = minf(v_target, follow_limit)
	if sim.phase == RaceSim.Phase.FINISHED or sim.entries[me].finished:
		v_target = minf(v_target, 35.0)  # cool-down lap
	var err := v_target - speed
	if err > 0.0:
		inp.throttle = clampf(0.35 + err * 0.4, 0.0, 1.0)
		# Feather the throttle if the rear is close to the limit.
		if absf(car.slip_angle_rear) > 0.1:
			inp.throttle *= 0.4
	elif err < -0.8:
		inp.brake = clampf(-err * 0.5, 0.0, 1.0)
	return inp.quantized()
