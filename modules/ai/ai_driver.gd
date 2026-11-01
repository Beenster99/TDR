class_name AIDriver
extends RefCounted
## A computer driver. It produces a CarInput exactly like a human, so it runs
## on the host and is invisible to netcode and to the race rules.
##
## How it drives:
##  * Follows the track's racing line (pure-pursuit steering, catches slides).
##  * Speed comes from a grip-based profile of the line (corner speeds plus
##    braking points), scaled by the driver's pace. The profile is learned per
##    32 m section during the race: a section where the car slid or ran wide
##    is taken a little slower next time, a clean one a little faster, up to
##    the driver's limit. That makes every car, track and weather work
##    without hand tuning.
##  * Live grip changes the plan: tyre temperature, the track surface and
##    weather (wet skill decides how much of the loss a driver copes with).
##  * Racecraft: follows at a gap set by aggression, picks a side and commits
##    to a pass (overtaking), covers the inside when attacked (defending,
##    one move), leaves racing room alongside, and moves over for leaders.
##  * Mistakes: running wide or braking too late now and then, more often
##    under pressure, at night and in the wet (consistency, composure).
##
## Traits are described in DriverTraits and set per driver in
## modules/ai/data/drivers.json. Everything random uses a seeded RNG, so a
## race with the same seed and the same human inputs plays out the same way.

const SPACING := 4.0          ## metres between racing line points
const BLOCK := 8              ## line points per learning section (32 m)
const MAX_SPEED := 95.0
const EDGE_MARGIN := 2.6      ## line keeps this far from the track edge
const ROOM_MARGIN := 1.2      ## how close to the edge a car centre may go when off line
const DEFAULT_DIFFICULTY := 0.75
const AERO_TRUST := 0.9      ## share of the downforce the profile counts on
const OFF_LINE_TROUBLE := 4.0

## What the driver is doing right now (for HUD / debugging).
enum Mood { RACING, ATTACKING, DEFENDING, YIELDING, MISTAKE, RECOVERING }

var traits: Dictionary         ## as given (RaceEntry.traits)
var profile: DriverTraits      ## after difficulty
var rng := RandomNumberGenerator.new()
var mood: int = Mood.RACING

var line: PackedVector2Array = []
var line_right: PackedVector2Array = []
var room_left: PackedFloat64Array = []   ## metres the car may move left of the line
var room_right: PackedFloat64Array = []
var curv: PackedFloat64Array = []        ## signed curvature (+ = right-hander)
var target_speed: PackedFloat64Array = []
var learn: PackedFloat64Array = []       ## per-section pace scale (learned)
var _learn_hit: PackedByteArray = []     ## section has found its limit once
var idx: int = -1

var _mu := 1.0
var _mass := 1400.0
var _aero := 0.0
var _drag := 0.0
var _corner_frac := 0.9
var _brake_frac := 0.85
var _profile_dirty := false
var _profile_age := 0

var lateral_bias: float = 0.0   ## offset from the line (m, + right)
var speed_noise: float = 0.0
var _block: int = -1
var _block_trouble := false
var _block_clean := true
var stuck_time: float = 0.0
var stuck_idx: int = 0
var recover_time: float = 0.0

var _pass_side := 0
var _pass_target := -1
var _pass_timer := 0.0
var _pass_cooldown := 0.0
var _defend_side := 0
var _defend_from := -1
var _defend_timer := 0.0
var _defend_decided := -1
var _mistake_kind := ""
var _mistake_until := -1
var _mistake_side := 0
var _last_pressure := 0.0
var _radio_cooldown := 30.0
var _held_up := 0.0
var _hot_said := false
var _wet_said := false
var _plan_said := false


## An AI driver for car i of a race, using that entry's traits and the
## host's difficulty setting (if the race settings carry one).
static func for_car(sim: RaceSim, i: int) -> AIDriver:
	var t := sim.entries[i].traits
	if t.is_empty():
		t = {"pace": 0.9, "consistency": 0.9}
	var difficulty := DEFAULT_DIFFICULTY
	if "ai_difficulty" in sim.settings:
		difficulty = float(sim.settings.get("ai_difficulty"))
	return AIDriver.new(sim.track, sim.defs[i], sim.compounds[i], t, sim.settings.seed * 31 + i, difficulty)


## car index -> AIDriver, for every AI entry in the race.
static func for_all_ai(sim: RaceSim) -> Dictionary:
	var ai := {}
	for i in sim.entries.size():
		if sim.entries[i].is_ai:
			ai[i] = for_car(sim, i)
	return ai


func _init(track: TrackData, def: CarDefinition, compound: TyreCompound, p_traits: Dictionary,
		seed: int, difficulty: float = DEFAULT_DIFFICULTY) -> void:
	traits = p_traits
	profile = DriverTraits.from_dict(p_traits).with_difficulty(difficulty)
	rng.seed = seed
	_build_line(track)
	_setup_car(def, compound)
	_build_speed_profile()


# --- Racing line -------------------------------------------------------------

func _build_line(track: TrackData) -> void:
	var src := track.raceline if track.raceline.size() > 10 else track.points
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
	# centimetre of track, which leaves no room for tracking error. Aggressive
	# drivers use a little more of the kerbs.
	var margin := EDGE_MARGIN - 0.5 * profile.aggression
	var hint := -1
	room_left.resize(count)
	room_right.resize(count)
	for k in count:
		var q := track.project(line[k], hint)
		hint = q["idx"]
		var off: float = q["offset"]
		var lim: float = (q["w_right"] if off > 0.0 else q["w_left"]) - margin
		var clamped := clampf(off * 0.8, -maxf(lim, 0.0), maxf(lim, 0.0))
		line[k] += Vector2(-q["dir"].y, q["dir"].x) * (clamped - off)
		room_right[k] = maxf(float(q["w_right"]) - clamped - ROOM_MARGIN, 0.0)
		room_left[k] = maxf(float(q["w_left"]) + clamped - ROOM_MARGIN, 0.0)
	for k in count:
		var d := (line[(k + 1) % count] - line[(k - 1 + count) % count]).normalized()
		line_right.append(Vector2(-d.y, d.x))
	curv.resize(count)
	for k in count:
		# Menger curvature over a +-3 point window (24 m chord) for smoothness.
		var a := line[(k - 3 + count) % count]
		var b := line[k]
		var c := line[(k + 3) % count]
		var cross := (b - a).cross(c - b)
		var denom := a.distance_to(b) * b.distance_to(c) * c.distance_to(a)
		curv[k] = 2.0 * cross / maxf(denom, 0.001)
	learn.resize((count + BLOCK - 1) / BLOCK)
	learn.fill(0.94)
	_learn_hit.resize(learn.size())
	_learn_hit.fill(0)


func _setup_car(def: CarDefinition, compound: TyreCompound) -> void:
	_mu = compound.peak_mu * minf(def.front_grip, def.rear_grip)
	_mass = def.mass + 40.0
	_aero = 0.5 * 1.2 * def.cla
	_drag = 0.5 * 1.2 * def.cda
	# Pace: how much of the estimated limit is used in corners and braking.
	_corner_frac = lerpf(0.72, 1.0, profile.pace)
	_brake_frac = lerpf(0.65, 0.95, profile.pace) + 0.04 * profile.aggression


## Corner speeds along the line, then a backward pass so the car can brake
## in time for every corner. Uses the learned per-section scale.
func _build_speed_profile() -> void:
	var n := line.size()
	target_speed.resize(n)
	for k in n:
		var mu := _mu * _corner_frac * learn[k / BLOCK]
		var kk := maxf(absf(curv[k]), 1e-5)
		var den := _mass * kk - mu * _aero * AERO_TRUST
		var v := MAX_SPEED if den <= 0.0 else sqrt(mu * _mass * CarPhysics.G / den)
		target_speed[k] = minf(v, MAX_SPEED)
	for _pass in 2:
		for j in n:
			var k := n - 1 - j
			var nxt := target_speed[(k + 1) % n]
			var mu := _mu * _brake_frac * learn[k / BLOCK]
			var decel := mu * (CarPhysics.G + _aero * AERO_TRUST * nxt * nxt / _mass) + _drag * nxt * nxt / _mass * 0.5
			target_speed[k] = minf(target_speed[k], sqrt(nxt * nxt + 2.0 * decel * SPACING))
	_profile_dirty = false
	_profile_age = 0


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


## +1 if the next corner (30..160 m ahead) turns right, -1 if left, 0 if straight.
func _next_corner_dir(from: int) -> int:
	var n := line.size()
	var sum := 0.0
	for k in range(8, 40):
		sum += curv[(from + k) % n]
	if absf(sum) < 0.02:
		return 0
	return 1 if sum > 0.0 else -1


## Offset (m, + right) of a position from the racing line, searching near
## line point guess. Works for other cars in corners, where our own car's
## frame would give the wrong answer.
func _line_offset(pos: Vector2, guess: int) -> float:
	var n := line.size()
	var best := guess
	var best_d := INF
	for o in range(-4, 5):
		var k := (guess + o + n) % n
		var d := pos.distance_squared_to(line[k])
		if d < best_d:
			best_d = d
			best = k
	return (pos - line[best]).dot(line_right[best])


func _room(side: int, k: int) -> float:
	return room_right[k] if side > 0 else room_left[k]


# --- Conditions ---------------------------------------------------------------

func _env_grip(sim: RaceSim, me: int, speed: float) -> float:
	return sim.env.grip_factor(sim.compounds[me], lateral_bias, speed)


func _darkness(sim: RaceSim) -> float:
	return clampf(sim.env.darkness(), 0.0, 1.0)


# --- Driving -----------------------------------------------------------------

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
		mood = Mood.RECOVERING
		recover_time -= RaceSim.TICK_DT
		inp.brake = 1.0
		var to_line := line[(idx + 3) % n] - car.pos
		inp.steer = -signf(to_line.dot(rgt))
		return inp
	stuck_time += RaceSim.TICK_DT
	if stuck_time >= 3.0:
		var progressed := wrapi(idx - stuck_idx, -n / 2, n / 2)
		if progressed < 2 and sim.phase != RaceSim.Phase.FINISHED:
			recover_time = 1.8
		stuck_time = 0.0
		stuck_idx = idx

	var p := profile
	mood = Mood.RACING
	var yielding := false
	var cool_down := sim.phase == RaceSim.Phase.FINISHED or sim.entries[me].finished
	var dark := _darkness(sim)
	var wetness := sim.env.wetness

	# --- Learning: judge the section we just left. ---
	var block := idx / BLOCK
	var signed_off := (car.pos - line[idx]).dot(line_right[idx]) - lateral_bias
	var off_line := absf(signed_off)
	if car.surface == TrackData.Surface.GRASS or absf(car.slip_angle_rear) > 0.16 or off_line > OFF_LINE_TROUBLE:
		_block_trouble = true
	if block != _block:
		_end_block(block, sim, me, dark, wetness)
	_profile_age += 1
	if _profile_dirty and _profile_age > 30:
		_build_speed_profile()

	# --- Traffic and racecraft. ---
	var corner_dir := _next_corner_dir(idx)
	var want_bias := 0.0
	var follow_limit := INF
	var pressure := 0.0
	var my_dist := sim.entries[me].distance
	var half_w := def.width * 0.5
	var my_off := (car.pos - line[idx]).dot(line_right[idx])
	var alongside := []   ## [their offset from the line, side I keep to, centre gap, their lx]
	var ahead := -1
	var ahead_lx := INF
	var behind := -1
	var behind_lx := -INF
	for j in sim.cars.size():
		if j == me:
			continue
		var o := sim.cars[j]
		var rel := o.pos - car.pos
		if rel.length_squared() > 70.0 * 70.0:
			continue
		var lx := rel.dot(fwd)
		var ly := rel.dot(rgt)
		var o_half := sim.defs[j].width * 0.5
		var o_len := (def.length + sim.defs[j].length) * 0.5
		if absf(ly) > 9.0:
			continue
		var o_v := o.vel.dot(fwd)
		var lapped_by := sim.entries[j].distance > my_dist + sim.track.length * 0.5
		# Cars behind: pressure, defending, letting leaders by.
		if lx < -o_len * 0.6:
			if lx > behind_lx and lx > -30.0:
				behind = j
				behind_lx = lx
			if lx > -maxf(speed, 10.0) * 1.0:
				pressure = maxf(pressure, 0.7)
			if lapped_by and lx > -40.0 and not cool_down:
				yielding = true
		# Alongside: leave racing room.
		elif lx < o_len * 0.9:
			pressure = 1.0
			var away := -signf(ly) if absf(ly) > 0.05 else (1.0 if me < j else -1.0)
			alongside.append([_line_offset(o.pos, idx), away, half_w + o_half + 1.1, lx])
		# Ahead.
		else:
			if lx < ahead_lx and absf(ly) < half_w + o_half + 2.5:
				ahead = j
				ahead_lx = lx
			if absf(ly) < half_w + o_half + 0.4:
				var gap := 3.0 + speed * lerpf(0.32, 0.16, p.aggression)
				if sim.entries[me].laps_done == 0:
					gap *= 1.5  # opening lap: brake a little earlier in the pack
				if _pass_side != 0 and _pass_target == j:
					gap *= 0.6
				var decel := _mu * _brake_frac * CarPhysics.G * 0.8
				var room_m := maxf(lx - o_len - gap, 0.0)
				follow_limit = minf(follow_limit, sqrt(maxf(o_v, 0.0) ** 2 + 2.0 * decel * room_m))

	# Attack: pick a side and commit until the pass is done or it times out.
	_pass_timer -= RaceSim.TICK_DT
	_pass_cooldown -= RaceSim.TICK_DT
	if _pass_target >= 0:
		var o := sim.cars[_pass_target]
		var rel := o.pos - car.pos
		var o_len := (def.length + sim.defs[_pass_target].length) * 0.5
		var lx := rel.dot(fwd)
		if _pass_timer <= 0.0 or lx < -o_len or lx > 45.0 or cool_down:
			_pass_side = 0
			_pass_target = -1
			_pass_cooldown = 1.0
	if _pass_target < 0 and ahead >= 0 and not cool_down and ahead_lx < 30.0 and _pass_cooldown <= 0.0:
		var o := sim.cars[ahead]
		var closing := speed - o.vel.dot(fwd)
		if closing > 0.3 or ahead_lx < 14.0:
			# Decide twice a second whether to go for it.
			_pass_cooldown = 0.5
			var chance := 0.15 + 0.45 * p.overtaking + 0.3 * p.aggression
			if sim.entries[me].laps_done == 0:
				chance *= 0.35  # opening lap: everyone is close, keep it clean
			if sim.entries[ahead].distance < my_dist - sim.track.length * 0.5:
				chance = 1.0  # backmarker
			if rng.randf() < chance * 0.5:
				var oly := _line_offset(o.pos, (idx + int(ahead_lx / SPACING)) % n)
				var need := half_w + sim.defs[ahead].width * 0.5 + 1.3
				var side := corner_dir if corner_dir != 0 else (1 if oly < 0.0 else -1)
				if _room(side, idx) - side * oly < need:
					side = -side
				if _room(side, idx) - side * oly >= need:
					_pass_side = side
					_pass_target = ahead
					_pass_timer = 4.0 + 4.0 * p.overtaking
	if _pass_target >= 0:
		mood = Mood.ATTACKING
		var o := sim.cars[_pass_target]
		var oly := _line_offset(o.pos, (idx + int(maxf((o.pos - car.pos).dot(fwd), 0.0) / SPACING)) % n)
		var need := half_w + sim.defs[_pass_target].width * 0.5 + lerpf(1.7, 1.1, p.aggression)
		want_bias = oly + _pass_side * need
		# Not enough room any more on that side: give up and tuck back in.
		if _room(_pass_side, idx) - _pass_side * oly < need - 0.6:
			_pass_timer = 0.0
	elif ahead >= 0 and ahead_lx < 20.0 and target_speed[idx] > sim.cars[ahead].vel.length() + 2.0:
		pressure = maxf(pressure, 0.5)

	# Defend: cover the inside once when a faster car is right behind.
	_defend_timer -= RaceSim.TICK_DT
	if behind >= 0 and not cool_down and not yielding:
		var b := sim.cars[behind]
		var closing_b := b.vel.dot(fwd) - speed
		if _defend_decided != behind:
			_defend_decided = behind
			var chance := p.defending * lerpf(0.4, 0.9, p.aggression)
			if rng.randf() < chance and corner_dir != 0:
				_defend_side = corner_dir
				_defend_from = behind
				_defend_timer = 3.0
		if _defend_from == behind and _defend_timer > 0.0 and behind_lx > -18.0 and closing_b > -2.0:
			# No moving under braking: only commit while the corner is still ahead.
			if target_speed[(idx + 10) % n] > speed * 0.85 or absf(lateral_bias) > 0.3:
				mood = Mood.DEFENDING
				var cover := minf(_room(_defend_side, idx), 1.2 + 2.0 * p.defending)
				want_bias = _defend_side * cover
	else:
		_defend_decided = -1
		_defend_from = -1

	# Let a leader through: move away from their line and lift a little.
	var yield_scale := 1.0
	if yielding:
		mood = Mood.YIELDING
		var side := -corner_dir if corner_dir != 0 else 1
		want_bias = side * minf(_room(side, idx), 3.0)
		yield_scale = 0.93

	# Mistakes: running wide.
	if _mistake_kind == "wide" and _mistake_until >= 0:
		want_bias = _mistake_side * minf(_room(_mistake_side, idx) + 1.5, 3.5)

	# Racing room: never move into a car alongside. If there is no room left
	# on our side, the car further back lifts and drops in behind.
	var squeezed := false
	for a in alongside:
		var keep: float = a[0] + a[1] * a[2]
		if a[1] > 0.0:
			want_bias = maxf(want_bias, keep)
		else:
			want_bias = minf(want_bias, keep)
		if (a[1] > 0.0 and keep > room_right[idx]) or (a[1] < 0.0 and -keep > room_left[idx]):
			if a[3] > 0.0:
				squeezed = true
	want_bias = clampf(want_bias, -room_left[idx], room_right[idx])
	var bias_rate := lerpf(2.5, 4.5, p.aggression)
	if not alongside.is_empty():
		bias_rate = 6.0
	lateral_bias = move_toward(lateral_bias, want_bias, bias_rate * RaceSim.TICK_DT)
	if absf(lateral_bias) > 0.6:
		_block_clean = false
	if follow_limit < INF:
		_block_clean = false

	# --- Steering: pure pursuit on the racing line (+ offset). ---
	var look := 5.0 + 0.42 * speed
	var aim := (idx + int(look / SPACING)) % n
	var target := line[aim] + line_right[aim] * clampf(lateral_bias, -room_left[aim], room_right[aim])
	var local := target - car.pos
	var lx := local.dot(fwd)
	var ly := local.dot(rgt)
	var alpha := atan2(ly, maxf(lx, 0.1))
	var ld := maxf(local.length(), 1.0)
	var steer_angle := atan(2.0 * def.wheelbase * sin(alpha) / ld)
	# Catch slides: steer into the slide when the rear steps out.
	var excess_slip := car.slip_angle_rear - clampf(car.slip_angle_rear, -0.06, 0.06)
	steer_angle += lerpf(0.7, 1.0, p.consistency) * excess_slip
	inp.steer = clampf(steer_angle / def.max_steer, -1.0, 1.0)

	# --- Speed. ---
	var grip := 0.0
	var temp_sum := 0.0
	for i in 4:
		grip += sim.compounds[me].temp_grip_factor(car.tyre_temp[i])
		temp_sum += car.tyre_temp[i]
	grip /= 4.0
	var env_grip := _env_grip(sim, me, speed)
	# Wet: everyone loses the grip; drivers low on wet skill add extra margin.
	var wet_caution := 1.0 - (1.0 - clampf(env_grip, 0.0, 1.0)) * (1.0 - p.wet_skill) * 0.6
	var scale := sqrt(grip * clampf(env_grip, 0.2, 1.2) * wet_caution)
	# Tyre management: back off when the tyres run hot (good managers more so).
	var tc := sim.compounds[me]
	var over := (temp_sum / 4.0 - tc.optimal_temp_c) / tc.temp_window_c
	if over > 0.3:
		scale *= 1.0 - 0.06 * p.tyre_management * minf(over - 0.3, 1.0)
	scale *= 1.0 - 0.012 * absf(lateral_bias)
	scale *= (1.0 + speed_noise) * yield_scale
	if squeezed:
		scale *= 0.95
	var v_target := target_speed[idx]
	var look_pts := 2 + int(speed * 0.45 / SPACING)
	for k in range(1, look_pts):
		v_target = minf(v_target, target_speed[(idx + k) % n])
	v_target *= scale
	if _mistake_kind == "late" and _mistake_until >= 0:
		v_target *= 1.10
	if _mistake_until >= 0 and wrapi(idx - _mistake_until, -n / 2, n / 2) >= 0:
		_mistake_kind = ""
		_mistake_until = -1
	elif _mistake_until >= 0:
		mood = Mood.MISTAKE
		_block_clean = false
	if car.surface == TrackData.Surface.GRASS:
		v_target = minf(v_target, 30.0)
		# Rejoin carefully: wait for a gap when a car is coming.
		if behind >= 0 and behind_lx > -25.0:
			v_target = minf(v_target, 18.0)
	v_target = minf(v_target, follow_limit)
	if cool_down:
		v_target = minf(v_target, 35.0)
	var err := v_target - speed
	if err > 0.0:
		inp.throttle = clampf(0.35 + err * 0.4, 0.0, 1.0)
		# Slower drivers are more patient with the throttle out of corners.
		if absf(curv[idx]) > 0.008:
			inp.throttle = minf(inp.throttle, lerpf(0.55, 1.0, p.pace))
		if absf(car.slip_angle_rear) > lerpf(0.13, 0.17, p.aggression):
			inp.throttle *= 0.4
		# Running wide on the exit: wait with the power.
		var outward := -signf(curv[idx]) * signed_off
		if outward > 1.0 and speed > 12.0 and car.surface <= TrackData.Surface.KERB:
			inp.throttle *= clampf(1.0 - (outward - 1.0) * 0.45, 0.15, 1.0)
	elif err < -0.8:
		inp.brake = clampf(-err * 0.5, 0.0, 1.0)
		# Trail braking: ease off the brake as the steering winds on, and when
		# the rear starts to step out.
		inp.brake = minf(inp.brake, lerpf(1.0, lerpf(0.35, 0.55, p.aggression), minf(absf(inp.steer) / 0.45, 1.0)))
		if absf(car.slip_angle_rear) > 0.12:
			inp.brake *= 0.5
	_last_pressure = pressure
	_radio_tick(sim, me, follow_limit < INF and ahead >= 0, over, ahead)
	return inp.quantized()


## Leaving a section: learn from how it went, then roll for this section's
## lap-to-lap variation and for a mistake.
func _end_block(new_block: int, sim: RaceSim, me: int, dark: float, wetness: float) -> void:
	var nb := learn.size()
	if _block >= 0 and (new_block == (_block + 1) % nb):
		var hi := lerpf(0.94, 1.06, profile.pace)
		if _block_trouble and _mistake_until < 0:
			for b in [_block, (_block - 1 + nb) % nb, (_block - 2 + nb) % nb]:
				learn[b] = maxf(learn[b] - 0.03, 0.75)
				_learn_hit[b] = 1
			_profile_dirty = true
		elif _block_clean and not _block_trouble:
			learn[_block] = minf(learn[_block] + (0.005 if _learn_hit[_block] else 0.02), hi)
			_profile_dirty = true
	_block = new_block
	_block_trouble = false
	_block_clean = true
	var p := profile
	var variability := (1.0 - p.consistency) * 0.05 * (1.0 + 0.5 * dark)
	speed_noise = -absf(rng.randfn(0.0, variability))
	# Mistakes only matter where there is a corner to get wrong.
	var n := line.size()
	if _mistake_until >= 0 or sim.phase != RaceSim.Phase.RACING:
		return
	var corner_ahead := false
	var v_now := target_speed[idx]
	for k in range(4, 24):
		if target_speed[(idx + k) % n] < v_now * 0.8:
			corner_ahead = true
			break
	if not corner_ahead:
		return
	var rate := (1.0 - p.consistency) * 0.02 + 0.0015
	rate *= 1.0 + _last_pressure * 2.5 * (1.0 - p.composure)
	rate *= 1.0 + 0.5 * dark + 2.0 * wetness * (1.0 - p.wet_skill)
	rate *= 1.0 + 0.5 * p.aggression
	if rng.randf() < rate:
		_mistake_kind = "late" if rng.randf() < 0.5 else "wide"
		_radio(sim, me, "incident", "Locked up, went in too deep." if _mistake_kind == "late" else "Ran wide, lost a bit of time.")
		var cd := _next_corner_dir(idx)
		_mistake_side = -cd if cd != 0 else 1
		_mistake_until = (idx + 26) % n


# --- Team radio (shown in the strategist feed, if the race module has one) ---

func _radio(sim: RaceSim, me: int, topic: String, text: String, force := false) -> void:
	if not force and _radio_cooldown > 0.0:
		return
	if sim.has_method("post_event"):
		sim.call("post_event", {"type": "radio", "car": me, "topic": topic, "text": text})
	_radio_cooldown = 75.0


func _radio_tick(sim: RaceSim, me: int, held_up: bool, tyre_over: float, ahead: int) -> void:
	_radio_cooldown -= RaceSim.TICK_DT
	if sim.phase != RaceSim.Phase.RACING or sim.entries[me].finished:
		return
	var p := profile
	if not _plan_said and sim.race_time > 5.0:
		_plan_said = true
		var mode := "push" if p.aggression > 0.65 else ("manage" if p.tyre_management > 0.7 else "defend" if p.defending > 0.75 else "push")
		var lines := {"push": "Flat out from the start, let's make up places.",
			"manage": "Looking after the tyres early, we'll be strong at the end.",
			"defend": "Hold position, keep it clean and make them work for it."}
		if sim.has_method("post_event"):
			sim.call("post_event", {"type": "strategy", "car": me, "text": lines[mode], "plan": {"mode": mode}})
	_held_up = _held_up + RaceSim.TICK_DT if held_up else 0.0
	if _held_up > 12.0 and ahead >= 0:
		_held_up = 0.0
		_radio(sim, me, "traffic", "Stuck behind %s, I'm faster but can't find a way past." % sim.entries[ahead].driver_name)
	if tyre_over > 0.6 and not _hot_said:
		_hot_said = true
		_radio(sim, me, "tyres", "Tyres are overheating, backing off to bring them back." if p.tyre_management > 0.5 else "Tyres are cooking, grip is going.")
	elif tyre_over < 0.2:
		_hot_said = false
	if sim.env.wetness > 0.3 and not _wet_said:
		_wet_said = true
		_radio(sim, me, "weather", "Track's getting slippery out here." if p.wet_skill < 0.6 else "Getting wet, good, this suits me.", true)
