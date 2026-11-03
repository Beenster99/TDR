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
const LINE_EDGE := 0.3        ## how close the track's racing line comes to the edge (raceline.py KERB_M)
const ROOM_MARGIN := 1.2      ## how close to the edge a car centre may go when off line
const DEFAULT_DIFFICULTY := 0.75
const AERO_TRUST := 0.9      ## share of the downforce the profile counts on
const OFF_LINE_TROUBLE := 4.0
const BRAKE_TURNING := 0.35  ## share of braking grip left at the cornering limit
const ALONGSIDE_GAP := 1.1   ## clear metres kept between our side and a car alongside
const DEFEND_RATE := 2.5     ## m/s: fastest sideways move when covering a line
const START_HOLD_MAX_M := 1200.0  ## opening lap: furthest the grid lanes are held

## What the driver is doing right now (for HUD / debugging).
enum Mood { RACING, ATTACKING, DEFENDING, YIELDING, MISTAKE, RECOVERING }

var traits: Dictionary         ## as given (RaceEntry.traits)
var profile: DriverTraits      ## after difficulty
var _difficulty := DEFAULT_DIFFICULTY
## Line-up driver at the wheel (RaceEntry.pit "driver_idx"): when it changes at
## a stop, the new driver's traits take over.
var stint_driver := 0
var rng := RandomNumberGenerator.new()
var mood: int = Mood.RACING

var line: PackedVector2Array = []
var line_right: PackedVector2Array = []
var room_left: PackedFloat64Array = []   ## metres the car may move left of the line
var room_right: PackedFloat64Array = []
var curv: PackedFloat64Array = []        ## signed curvature (+ = right-hander)
var grade: PackedFloat64Array = []       ## road gradient at each line point (+ = uphill)
var vcurv: PackedFloat64Array = []       ## vertical curvature (+ = dip, - = crest)
var target_speed: PackedFloat64Array = []
var learn: PackedFloat64Array = []       ## per-section pace scale (learned)
var loose: PackedFloat64Array = []       ## rallycross: how loose the surface is at each line point (0..1)
var _learn_hit: PackedByteArray = []     ## section has found its limit once
var idx: int = -1

var _mu := 1.0
var _dirt_grip := 0.6
## Rallycross joker: the line through the joker lane is a second set of line
## arrays (_lines[1]); the driver swaps sets before the joker on the lap it
## has chosen, and back once it has rejoined the lap.
var _lines: Array = []
var _on_joker_line := false
var joker_lap := 0     ## lap (1 = first) on which this driver takes the joker
const LINE_FIELDS := ["line", "line_right", "room_left", "room_right", "curv", "grade", "vcurv", "loose",
	"target_speed", "learn", "_learn_hit"]
var _mass := 1400.0
var _aero := 0.0
var _drag := 0.0
var _corner_frac := 0.9
var _brake_frac := 0.85
var _profile_dirty := false
var _profile_age := 0

var lateral_bias: float = 0.0   ## offset from the line (m, + right)
## Test hook: drive as if alone on track (stands in for a human who holds
## their own line whatever the cars around them do).
var ignore_traffic := false
## Test hook: when set (not NAN), hold this offset from the line (m, + right).
var hold_bias := NAN
var speed_noise: float = 0.0
var _block: int = -1
var _block_trouble := false
var _block_clean := true
var stuck_time: float = 0.0
var stuck_idx: int = -1   ## line point at the last stuck check (-1 = not checked yet)
var recover_time: float = 0.0

var _pass_side := 0
var _pass_target := -1
var _pass_timer := 0.0
var _pass_cooldown := 0.0
var _defend_side := 0
var _defend_from := -1
var _defend_timer := 0.0
var _defend_decided := -1
## Standing start: the lateral spot on the track the car started from (held
## until the braking zone of the first corner, so the field races side by
## side to turn 1 instead of filing onto the racing line), whether this
## driver floors it off the line, and the launch throttle a careful starter
## is feeling for.
var _start_lat := NAN
var _start_hold := false
var _launch_hot := false
var _launch_thr := 0.9
var _mistake_kind := ""
var _mistake_until := -1
var _mistake_side := 0
var _last_pressure := 0.0
var _radio_cooldown := 30.0
var _held_up := 0.0
var _hot_said := false
var _wet_said := false
var _plan_said := false
## When to pit and what for (see AIPitStrategy).
var pit_strategy: AIPitStrategy


## An AI driver for car i of a race, using that entry's traits and the
## host's difficulty setting (if the race settings carry one).
static func for_car(sim: RaceSim, i: int) -> AIDriver:
	var t := sim.entries[i].traits
	var m := sim.entries[i].driver_member()
	if m.get("ai", false) and m.get("traits", {}) is Dictionary and not (m["traits"] as Dictionary).is_empty():
		t = m["traits"]  # a player's AI co-driver
	if t.is_empty():
		t = {"pace": 0.9, "consistency": 0.9}
	var difficulty := DEFAULT_DIFFICULTY
	if "ai_difficulty" in sim.settings:
		difficulty = float(sim.settings.get("ai_difficulty"))
	var d := AIDriver.new(sim.track, sim.defs[i], sim.compounds[i], t, sim.settings.seed * 31 + i, difficulty)
	d.stint_driver = int(sim.entries[i].pit.get("driver_idx", 0))
	return d


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
	_difficulty = difficulty
	profile = DriverTraits.from_dict(p_traits).with_difficulty(difficulty)
	rng.seed = seed
	pit_strategy = AIPitStrategy.new(profile, seed * 7 + 3)
	_build_line(track)
	_setup_car(def, compound)
	_build_speed_profile()
	if track.has_joker():
		_lines.append(_line_set())
		_build_joker_line(track)
		_build_speed_profile()
		_lines.append(_line_set())
		_on_joker_line = true  # the joker set is in place now
		_use_line_set(0)


## A driver change at a stop: the new driver's traits (pace, racecraft, pit
## calls) take over the car from here.
func change_driver(p_traits: Dictionary, def: CarDefinition, compound: TyreCompound) -> void:
	traits = p_traits
	profile = DriverTraits.from_dict(p_traits).with_difficulty(_difficulty)
	pit_strategy.profile = profile
	_setup_car(def, compound)
	_profile_dirty = true


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
	# drivers use a little more of the kerbs. The line is squeezed towards the
	# centre in proportion (not cut off at the margin), so it keeps its shape:
	# wide entry, late apex, out to the edge, just with room to spare.
	var margin := EDGE_MARGIN - 0.5 * profile.aggression
	var hint := -1
	room_left.resize(count)
	room_right.resize(count)
	for k in count:
		var q := track.project(line[k], hint)
		hint = q["idx"]
		var off: float = q["offset"]
		var w: float = q["w_right"] if off > 0.0 else q["w_left"]
		var lim := maxf(w - margin, 0.0)
		var clamped := clampf(off * lim / maxf(w - LINE_EDGE, 0.1), -lim, lim)
		line[k] += Vector2(-q["dir"].y, q["dir"].x) * (clamped - off)
		room_right[k] = maxf(float(q["w_right"]) - clamped - ROOM_MARGIN, 0.0)
		room_left[k] = maxf(float(q["w_left"]) + clamped - ROOM_MARGIN, 0.0)
		grade.append(track.grade_at(q["s"]))
		vcurv.append(track.vertical_curvature_at(q["s"]))
		loose.append(track.dirt_at(q["s"]))
	_finish_line()


## Directions, curvature and learning sections for the line points.
func _finish_line() -> void:
	var count := line.size()
	line_right = PackedVector2Array()
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


## The racing line with the joker lane spliced in: the lap's line up to where
## the joker leaves, the joker's centre line, then the lap's line again from
## where it rejoins. Called with the lap's line in place; replaces it.
func _build_joker_line(track: TrackData) -> void:
	var n := line.size()
	var keep := PackedByteArray()
	keep.resize(n)
	var hint := -1
	var first_skip := -1
	for k in n:
		var q := track.project(line[k], hint)
		hint = q["idx"]
		var skip := track.joker_spans(q["s"])
		keep[k] = 0 if skip else 1
		if skip and first_skip < 0 and k > 0 and keep[k - 1] == 1:
			first_skip = k
	if first_skip < 0:
		first_skip = 0
		while first_skip < n and keep[first_skip] == 1:
			first_skip += 1
	var nl := PackedVector2Array()
	var nrl := PackedFloat64Array()
	var nrr := PackedFloat64Array()
	var ng := PackedFloat64Array()
	var nv := PackedFloat64Array()
	var nlo := PackedFloat64Array()
	var room := maxf(track.joker_width * 0.5 - ROOM_MARGIN, 0.5)
	var spliced := false
	for j in n:
		var k := (first_skip + j) % n
		if keep[k] == 1:
			nl.append(line[k]); nrl.append(room_left[k]); nrr.append(room_right[k])
			ng.append(grade[k]); nv.append(vcurv[k]); nlo.append(loose[k])
		elif not spliced:
			spliced = true
			var steps := maxi(2, int(track.joker_length / SPACING))
			for m in steps + 1:
				var d := track.joker_length * float(m) / steps
				nl.append(track.joker_position_at(d)); nrl.append(room); nrr.append(room)
				var ls := track.joker_lap_s(d)
				ng.append(track.grade_at(ls)); nv.append(0.0); nlo.append(track.joker_dirt_at(d))
	line = nl
	room_left = nrl
	room_right = nrr
	grade = ng
	vcurv = nv
	loose = nlo
	_finish_line()
	target_speed = PackedFloat64Array()


func _line_set() -> Dictionary:
	var d := {}
	for f in LINE_FIELDS:
		d[f] = get(f).duplicate()  # its own copy: the other set must not share arrays
	return d


func _use_line_set(k: int) -> void:
	if k >= _lines.size():
		return
	if not _lines.is_empty() and _lines.size() > 1:
		# keep what the current set has learned
		var cur := 1 if _on_joker_line else 0
		_lines[cur] = _line_set()
	for f in LINE_FIELDS:
		set(f, _lines[k][f].duplicate())
	_on_joker_line = k == 1
	idx = -1
	_block = -1
	stuck_idx = -1


## Rallycross: swap to the joker line ahead of the joker on the chosen lap,
## and back to the lap's line once past it.
func _joker_plan(sim: RaceSim, me: int) -> void:
	if _lines.size() < 2:
		return
	var t := sim.track
	var e := sim.entries[me]
	var need: int = int(sim.settings.get("joker_laps")) if "joker_laps" in sim.settings else 1
	# A joker that runs over the finish line can't be taken on the last lap
	# (the race ends half way along it).
	var last := int(sim.settings.laps)
	if t.joker_entry_s > t.joker_exit_s and last > 1:
		last -= 1
	if joker_lap <= 0:
		joker_lap = rng.randi_range(1, maxi(1, last))
	var c := sim.cars[me]
	if c.in_joker:
		return
	var to_entry := fposmod(t.joker_entry_s - c.track_s, t.length)
	var from_exit := fposmod(c.track_s - t.joker_exit_s, t.length)
	var want := e.jokers < need and e.started_lap and (e.laps_done + 1 >= joker_lap or e.laps_done + 1 >= last)
	if want and not _on_joker_line and to_entry > 25.0 and to_entry < 160.0:
		_use_line_set(1)
	elif _on_joker_line and not want and from_exit > 25.0 and from_exit < 200.0:
		_use_line_set(0)


func _setup_car(def: CarDefinition, compound: TyreCompound) -> void:
	_mu = compound.peak_mu * minf(def.front_grip, def.rear_grip)
	_dirt_grip = compound.dirt_grip
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
	var has_loose := loose.size() == n
	for k in n:
		var mu := _mu * _corner_frac * learn[k / BLOCK]
		if has_loose:
			mu *= lerpf(1.0, _dirt_grip, loose[k])
		var kk := maxf(absf(curv[k]), 1e-5)
		# Over a crest the car is lighter (less grip), in a dip heavier.
		var den := _mass * kk - mu * _aero * AERO_TRUST - mu * _mass * vcurv[k]
		var v := MAX_SPEED if den <= 0.0 else sqrt(mu * _mass * CarPhysics.G / den)
		target_speed[k] = minf(v, MAX_SPEED)
	for _pass in 2:
		for j in n:
			var k := n - 1 - j
			var nxt := target_speed[(k + 1) % n]
			var mu := _mu * _brake_frac * learn[k / BLOCK]
			if has_loose:
				mu *= lerpf(1.0, _dirt_grip, loose[k])
			# Braking downhill or over a crest takes longer; uphill helps.
			var weight_g := maxf(CarPhysics.G + nxt * nxt * vcurv[k], CarPhysics.G * 0.25)
			var grip_acc := weight_g + _aero * AERO_TRUST * nxt * nxt / _mass
			# Grip used for cornering can't brake as well (friction circle):
			# through a chicane the car must slow before the next turn-in.
			var lat := nxt * nxt * absf(curv[k]) / maxf(_mu * _corner_frac * learn[k / BLOCK] * grip_acc, 0.1)
			var share := sqrt(maxf(1.0 - lat * lat, BRAKE_TURNING * BRAKE_TURNING))
			var decel := mu * grip_acc * share + _drag * nxt * nxt / _mass * 0.5 + CarPhysics.G * grade[k]
			decel = maxf(decel, 2.0)
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
	var at_wheel := int(sim.entries[me].pit.get("driver_idx", 0))
	if at_wheel != stint_driver:
		stint_driver = at_wheel
		change_driver(sim.entries[me].traits, def, sim.compounds[me])
	pit_strategy.update(sim, me)
	if sim.pit_controls(me):
		# The pit lane guide drives; pick the line up again afterwards.
		idx = -1
		_block = -1
		stuck_time = 0.0
		stuck_idx = -1
		return inp
	_joker_plan(sim, me)
	idx = _nearest(car.pos)
	var speed := car.speed()
	var fwd := car.forward()
	var rgt := car.right()

	if sim.phase == RaceSim.Phase.COUNTDOWN:
		stuck_idx = idx
		stuck_time = 0.0
		if is_nan(_start_lat):
			_start_lat = float(sim.track.project(car.pos, -1)["offset"])
			lateral_bias = (car.pos - line[idx]).dot(line_right[idx])  # start in our grid lane
			_start_hold = true
			# Aggressive starters floor it and spin the tyres; the rest feel
			# for the grip. Always the same for the same driver and seed.
			_launch_hot = rng.randf() < 0.15 + 0.8 * profile.aggression * profile.aggression
			_launch_thr = 0.9
		return inp

	# --- Stuck recovery: reverse out, then carry on. ---
	if recover_time > 0.0:
		mood = Mood.RECOVERING
		recover_time -= RaceSim.TICK_DT
		inp.brake = 1.0
		var to_line := line[(idx + 3) % n] - car.pos
		inp.steer = -signf(to_line.dot(rgt))
		return inp
	if stuck_idx < 0:
		stuck_idx = idx
	stuck_time += RaceSim.TICK_DT
	if stuck_time >= 3.0:
		# Stuck = hardly moved along the line in 3 s while crawling. (The
		# check used to start from line point 0, so every car on the grid
		# behind the start line "had gone backwards" and reversed at 3 s.)
		var progressed := wrapi(idx - stuck_idx, -n / 2, n / 2)
		if progressed < 2 and speed < 4.0 and sim.phase != RaceSim.Phase.FINISHED:
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
	if car.surface >= TrackData.Surface.GRASS or absf(car.slip_angle_rear) > 0.16 or off_line > OFF_LINE_TROUBLE:
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
	# Demolition Derby: no braking for the car ahead; go for it instead.
	var derby := sim.settings.is_derby()
	var ram := -1
	var ram_lx := INF
	for j in sim.cars.size():
		if j == me or ignore_traffic:
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
		# Overlapping (nose level with our rear wheels or further up) and off
		# to one side: alongside, even if mostly behind. Racing room is
		# owed from the first bit of overlap.
		var overlap := not derby and lx < o_len * 0.9 and lx > -o_len - 0.5 \
			and absf(ly) > (half_w + o_half) * 0.7
		# Cars behind: pressure, defending, letting leaders by.
		if lx < -o_len * 0.6 and not overlap:
			if lx > behind_lx and lx > -30.0:
				behind = j
				behind_lx = lx
			if lx > -maxf(speed, 10.0) * 1.0:
				pressure = maxf(pressure, 0.7)
			if lapped_by and lx > -40.0 and not cool_down and not sim.race_control.safety_car_active():
				yielding = true  # blue flag (not behind the safety car)
			# Behind the safety car: make room for lapped cars unlapping themselves.
			if sim.race_control.unlapping[j] and not sim.race_control.unlapping[me] and lx > -40.0 and not cool_down:
				yielding = true
		# Alongside: leave racing room.
		elif lx < o_len * 0.9:
			pressure = 1.0
			var away := -signf(ly) if absf(ly) > 0.05 else (1.0 if me < j else -1.0)
			alongside.append([_line_offset(o.pos, idx), away, half_w + o_half + ALONGSIDE_GAP, lx])
		# Ahead.
		else:
			if lx < ahead_lx and absf(ly) < half_w + o_half + 2.5:
				ahead = j
				ahead_lx = lx
			if derby and not sim.entries[j].dnf and lx < 40.0 and absf(ly) < 7.0 and lx < ram_lx:
				ram = j
				ram_lx = lx
			if absf(ly) < half_w + o_half + 0.4 and not (derby and not sim.entries[j].dnf):
				var gap := 3.0 + speed * lerpf(0.32, 0.16, p.aggression)
				if _start_hold and o_v > speed - 1.0:
					gap = 2.0 + speed * 0.12  # off the line: everyone goes together, nose to tail
				elif sim.entries[me].laps_done == 0:
					gap *= 1.5  # opening lap: brake a little earlier in the pack
				if _pass_side != 0 and _pass_target == j:
					gap *= 0.6
				var decel := _mu * _brake_frac * CarPhysics.G * 0.8
				var room_m := maxf(lx - o_len - gap, 0.0)
				follow_limit = minf(follow_limit, sqrt(maxf(o_v, 0.0) ** 2 + 2.0 * decel * room_m))

	# Race control: yellow flags, VSC, safety car (no overtaking, follow the
	# safety car, lapped cars unlap themselves when waved by).
	var rc := sim.race_control
	var unlapping := rc.unlapping[me] == 1
	var giving_back := rc.give_back.has(me)
	var sc_bias := INF
	if rc.sc_visible and not rc.sc_in_pit and not cool_down:
		var sc_gap := rc.gap_to_sc(me)
		var sc_rel := rc.sc_pos - car.pos
		if sc_gap < 160.0 and sc_rel.dot(fwd) > 0.0:
			if unlapping:
				# Pass the safety car on the side away from its line.
				if sc_gap < 50.0:
					var sc_oly := _line_offset(rc.sc_pos, (idx + int(sc_gap / SPACING)) % n)
					var side := 1 if sc_oly < 0.0 else -1
					sc_bias = sc_oly + side * (half_w + 2.4)
			else:
				var decel := _mu * _brake_frac * CarPhysics.G * 0.5
				var room_m := maxf(sc_gap - def.length - RaceControl.SC_GAP_TARGET, 0.0)
				var sc_limit := sqrt(rc.sc_speed ** 2 + 2.0 * decel * room_m)
				if sc_gap < RaceControl.SC_GAP_TARGET * 0.5:
					sc_limit = rc.sc_speed * 0.8  # far too close: drop back
				follow_limit = minf(follow_limit, sc_limit)
	if _pass_target >= 0 and not rc.may_pass(me, _pass_target):
		_pass_timer = 0.0
	if rc.mode != RaceControl.Mode.GREEN or not rc.released[me] or rc.yellow_at(car.track_s):
		# No creeping past a car alongside when overtaking isn't allowed.
		for j in sim.cars.size():
			if j == me:
				continue
			var rel := sim.cars[j].pos - car.pos
			var lx := rel.dot(fwd)
			if lx > -1.0 and lx < 12.0 and absf(rel.dot(rgt)) < 5.0 and not rc.may_pass(me, j):
				follow_limit = minf(follow_limit, maxf(sim.cars[j].vel.dot(fwd) - 0.5, 0.0) if lx < 6.0 else sim.cars[j].vel.dot(fwd))

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
	if _pass_target < 0 and ahead >= 0 and not cool_down and ahead_lx < 30.0 and _pass_cooldown <= 0.0 \
			and rc.may_pass(me, ahead):
		var o := sim.cars[ahead]
		var closing := speed - o.vel.dot(fwd)
		if closing > 0.3 or ahead_lx < 14.0:
			# Decide twice a second whether to go for it.
			_pass_cooldown = 0.5
			var chance := 0.15 + 0.45 * p.overtaking + 0.3 * p.aggression
			if sim.entries[me].laps_done == 0:
				chance *= 0.35  # opening lap: everyone is close, keep it clean
			if sim.entries[ahead].distance < my_dist - sim.track.length * 0.5 or unlapping:
				chance = 1.0  # backmarker, or unlapping behind the safety car
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
	# Demolition Derby: aim at a rear corner of the car ahead to spin it.
	if derby and ram >= 0 and not cool_down:
		mood = Mood.ATTACKING
		_pass_target = -1
		_pass_side = 0
		var o := sim.cars[ram]
		var oly := _line_offset(o.pos, (idx + int(maxf(ram_lx, 0.0) / SPACING)) % n)
		var corner := sim.defs[ram].width * 0.35 * (1.0 if (ram + me) % 2 == 0 else -1.0)
		want_bias = oly + corner

	# Defend: cover the inside once when a faster car is right behind.
	_defend_timer -= RaceSim.TICK_DT
	if behind >= 0 and not cool_down and not yielding:
		var b := sim.cars[behind]
		var closing_b := b.vel.dot(fwd) - speed
		# Where the attacker is (+ = on our right), relative to us.
		var b_side := (b.pos - car.pos).dot(rgt)
		var b_committed := corner_dir != 0 and b_side * corner_dir > half_w
		if _defend_decided != behind:
			_defend_decided = behind
			var chance := p.defending * lerpf(0.4, 0.9, p.aggression)
			# One move, made before the attacker commits: never across a car
			# that is already on that side.
			if rng.randf() < chance and corner_dir != 0 and not b_committed:
				_defend_side = corner_dir
				_defend_from = behind
				_defend_timer = 3.0
		# The attacker has pulled out to the side we were covering and is
		# close: the move is over, leave them the room.
		if _defend_from == behind and b_side * _defend_side > half_w and behind_lx > -sim.defs[behind].length * 2.0:
			_defend_timer = 0.0
		if _defend_from == behind and _defend_timer > 0.0 and behind_lx > -18.0 and closing_b > -2.0:
			# No moving under braking: only commit while the corner is still ahead.
			if target_speed[(idx + 10) % n] > speed * 0.85 or absf(lateral_bias) > 0.3:
				mood = Mood.DEFENDING
				var cover := minf(_room(_defend_side, idx), 1.2 + 2.0 * p.defending)
				want_bias = _defend_side * cover
	else:
		_defend_decided = -1
		_defend_from = -1

	# Opening lap: hold the grid lane down to the first corner, then funnel in.
	if _start_hold:
		var brake_soon := false
		for k in range(1, 3 + int(speed * 2.5 / SPACING)):
			if target_speed[(idx + k) % n] < speed * 0.9:
				brake_soon = true
				break
		if sim.entries[me].laps_done > 0 or brake_soon or car.surface >= TrackData.Surface.GRASS \
				or sim.entries[me].distance > START_HOLD_MAX_M or rc.mode != RaceControl.Mode.GREEN:
			_start_hold = false
		elif _pass_target < 0:
			want_bias = my_off + (_start_lat - car.lateral_offset)

	# Let a leader through: move away from their line and lift a little.
	var yield_scale := 1.0
	if yielding:
		mood = Mood.YIELDING
		var side := -corner_dir if corner_dir != 0 else 1
		want_bias = side * minf(_room(side, idx), 3.0)
		yield_scale = 0.93

	if sc_bias < INF:
		want_bias = sc_bias

	# Mistakes: running wide.
	if _mistake_kind == "wide" and _mistake_until >= 0:
		want_bias = _mistake_side * minf(_room(_mistake_side, idx) + 1.5, 3.5)

	if not is_nan(hold_bias):
		want_bias = hold_bias

	# Racing room: never move into a car alongside. If there is no room left
	# on our side, the car further back lifts and drops in behind.
	var squeezed := false
	var look := 5.0 + 0.42 * speed
	var aim := (idx + int(look / SPACING)) % n
	# How far the line moves across the track (+ = right) between here and
	# the steering aim point. A car alongside holds its piece of track, so
	# when the line sweeps towards it (turn-in, apex, exit) we must not
	# follow the line into it: keep the gap at the aim point too.
	var sweep := ((room_left[aim] - room_right[aim]) - (room_left[idx] - room_right[idx])) * 0.5
	for a in alongside:
		var keep: float = a[0] + a[1] * a[2]
		if derby:
			pass  # Demolition Derby: contact is the point
		elif a[1] < 0.0:
			keep -= maxf(sweep, 0.0)
		else:
			keep -= minf(sweep, 0.0)
		if a[1] > 0.0:
			want_bias = maxf(want_bias, keep)
		else:
			want_bias = minf(want_bias, keep)
		if (a[1] > 0.0 and keep > room_right[idx]) or (a[1] < 0.0 and -keep > room_left[idx]):
			if a[3] > 0.0:
				squeezed = true
	# Room here and where we steer to: an attack out wide on a corner exit
	# must not run us off where the line itself goes out to the edge.
	want_bias = clampf(want_bias, -minf(room_left[idx], room_left[aim]), minf(room_right[idx], room_right[aim]))
	var bias_rate := lerpf(2.5, 4.5, p.aggression)
	if mood == Mood.DEFENDING:
		bias_rate = minf(bias_rate, DEFEND_RATE)  # a steady move, not a chop
	if not alongside.is_empty():
		bias_rate = 6.0
	lateral_bias = move_toward(lateral_bias, want_bias, bias_rate * RaceSim.TICK_DT)
	if absf(lateral_bias) > 0.6:
		_block_clean = false
	if follow_limit < INF:
		_block_clean = false

	# --- Steering: pure pursuit on the racing line (+ offset). ---
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
	if car.surface >= TrackData.Surface.GRASS:
		v_target = minf(v_target, 30.0)
		# Rejoin carefully: wait for a gap when a car is coming.
		if behind >= 0 and behind_lx > -25.0:
			v_target = minf(v_target, 18.0)
	v_target = minf(v_target, follow_limit)
	v_target = minf(v_target, _race_control_limit(sim, me, rc, unlapping))
	if giving_back:
		v_target *= 0.8  # let the car we passed back through
	if cool_down:
		v_target = minf(v_target, 35.0)
	var err := v_target - speed
	var launching := _start_hold and speed < CarPhysics.LAUNCH_SPEED and car.gear == 1 and err > 0.0
	if launching:
		# Off the line: hot starters keep it floored through the wheelspin
		# and lose a little; careful ones back off as soon as it spins.
		inp.throttle = clampf(0.35 + err * 0.4, 0.0, 1.0)
		if not _launch_hot:
			_launch_thr = clampf(_launch_thr + (-2.0 if car.wheelspin else 0.6) * RaceSim.TICK_DT, 0.5, 1.0)
			inp.throttle = minf(inp.throttle, _launch_thr)
	elif err > 0.0:
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


## Speed race control allows: the VSC reference, closing up to the safety
## car queue, the leader holding the pace until the restart, lifting for
## yellow flags. INF = no limit.
func _race_control_limit(sim: RaceSim, me: int, rc: RaceControl, unlapping: bool) -> float:
	var car := sim.cars[me]
	if sim.entries[me].finished:
		return INF
	match rc.mode:
		RaceControl.Mode.VSC:
			_block_clean = false
			return rc.vsc_speed_at(car.track_s) * 0.95
		RaceControl.Mode.SC:
			_block_clean = false
			if rc.stage == "restart":
				if rc.controls_restart(me):
					var go_at := sim.track.length - RaceControl.RESTART_GO_BEFORE_LINE * lerpf(0.5, 1.3, profile.aggression)
					if car.track_s < go_at and car.track_s > sim.track.length * 0.3:
						return rc.sc_speed_at(car.track_s)
				return INF
			# Close up to the queue quickly, then match its pace.
			if _queue_gap(sim, me) > 120.0 and not rc.yellow_at(car.track_s):
				return INF
			return rc.vsc_speed_at(car.track_s) * (1.3 if unlapping else 1.15)
	if rc.double_yellow_at(car.track_s):
		# Marshals on the track: well under the limit, ready to stop.
		_block_clean = false
		return minf(target_speed[idx] * 0.8, rc.double_yellow_limit(car.track_s) * 0.92)
	if rc.yellow_at(car.track_s):
		_block_clean = false
		return target_speed[idx] * 0.9
	return INF


## Track distance to the next car (or the safety car) ahead, metres.
func _queue_gap(sim: RaceSim, me: int) -> float:
	var L := sim.track.length
	var my_s := sim.cars[me].track_s
	var best := sim.race_control.gap_to_sc(me)
	for j in sim.cars.size():
		if j == me or sim.entries[j].dnf or sim.entries[j].finished:
			continue
		best = minf(best, fposmod(sim.cars[j].track_s - my_s, L))
	return best


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
	if _mistake_until >= 0 or sim.phase != RaceSim.Phase.RACING or sim.race_control.safety_car_active():
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
