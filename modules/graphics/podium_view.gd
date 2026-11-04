class_name PodiumView
extends Node3D
## The podium after a race: the top three drivers in their team colours on
## the steps (1 in the middle, 2 on the left, 3 on the right) in front of a
## backdrop with the circuit's name, and a crowd of mechanics, team mates
## and photographers below them behind a barrier. Ticker tape comes down,
## the drivers lift their trophies, then the champagne comes out.
##
## Champagne: every driver has a bottle. A bottle builds pressure when it's
## shaken (shake), pops its cork the first time it sprays (set_spray), then
## sprays a stream of droplets that flies, falls and soaks whoever it hits:
## people flinch and cover up, and someone soaked enough counts as soaked
## (signal soaked). Pressure drops as it sprays (shake again for more) and
## the bottle runs dry after about ten seconds of spraying.
##
## The player's driver (player_slot) is aimed by aim() or aim_at() (a point
## in the world, e.g. under the mouse: it works out the arc that lands
## there); the other drivers spray on their own, at each other, at the
## player and at the crowd.
##
## Purely visual, in its own world: put it in a SubViewport with
## own_world_3d (ui PodiumCeremony does) and drive it with set_phase.

signal cork_popped(slot: int)
signal soaked(name: String, by_player: bool)

const GRAVITY := 9.8
const MAX_DROPS := 1600
const MAX_TAPE := 420
## Podium steps by finishing position (P1, P2, P3): x and height.
const STEP_X := [0.0, -2.25, 2.25]
const STEP_H := [1.3, 0.92, 0.62]
const STEP_W := 2.15
const STEP_D := 1.7
const BARRIER_Z := 2.7
## Aim limits for a bottle: yaw either side of straight at the crowd, pitch up / down.
const YAW_MAX := 1.45
const PITCH_MIN := -0.55
const PITCH_MAX := 1.15
## Spraying: droplets per second and their speed, from no pressure to full.
const RATE_MIN := 70.0
const RATE_MAX := 300.0
const SPEED_MIN := 4.2
const SPEED_MAX := 12.5
## Bottle drains per second of spraying (at no pressure .. full pressure).
const DRAIN_MIN := 0.065
const DRAIN_MAX := 0.11
const SOAKED_AT := 0.32         ## wetness at which someone counts as soaked

enum Pose { STAND, CHEER, WAVE, TROPHY, HOLD, SPRAY, SHAKE, SHIELD, CLAP, PHOTO }

## Phases, set by the ceremony.
enum Phase { INTRO, TROPHY, CHAMPAGNE, DONE }


class Figure:
	extends RefCounted
	var name := ""
	var kind := "crowd"          ## driver, crowd, photo
	var root: Node3D
	var body: Node3D
	var upper: Node3D
	var hip_l: Node3D
	var hip_r: Node3D
	var knee_l: Node3D
	var knee_r: Node3D
	var arm_l: Node3D
	var arm_r: Node3D
	var elbow_l: Node3D
	var elbow_r: Node3D
	var head: Node3D
	var hand_r: Node3D
	var trophy: Node3D
	var bottle: Node3D
	var camera_prop: Node3D
	var base := Vector3.ZERO     ## feet
	var face := 0.0              ## yaw (rotation.y)
	var pose := 0
	var phase := 0.0             ## so the crowd doesn't move as one
	var lively := 1.0
	var wet := 0.0
	var hit_t := -10.0
	var soaked := false
	var radius := 0.32
	var height := 1.85


class Bottle:
	extends RefCounted
	var slot := 0                ## podium position 0..2
	var fig: Figure
	var pressure := 0.2          ## 0..1
	var fill := 1.0              ## 1 full .. 0 empty
	var corked := true
	var spraying := false
	var shaking := 0.0           ## seconds left of the shaking animation
	var yaw := 0.0
	var pitch := 0.3
	var ai := true
	var ai_target: Figure
	var ai_timer := 0.0
	var ai_state := 0            ## 0 shaking, 1 spraying
	var emit_acc := 0.0
	var cork: Node3D
	var cork_vel := Vector3.ZERO
	var cork_flying := false


var phase := Phase.INTRO
var player_slot := -1
var camera: Camera3D
var figures: Array = []          ## Figure
var drivers: Array = []          ## Figure by podium position
var bottles: Array = []          ## Bottle by podium position
var player_soaked := 0           ## people the player has soaked
var player_hits := 0             ## droplets of the player's that hit someone
var _t := 0.0
var _phase_t := 0.0
var _rng := RandomNumberGenerator.new()
var _meshes := {}
# Champagne droplets.
var _drops: MultiMeshInstance3D
var _d_pos := PackedVector3Array()
var _d_vel := PackedVector3Array()
var _d_age := PackedFloat32Array()
var _d_owner := PackedInt32Array()
var _d_n := 0
var _d_buf := PackedFloat32Array()
# Ticker tape.
var _tape: MultiMeshInstance3D
var _tp_pos := PackedVector3Array()
var _tp_spin := PackedFloat32Array()
var _tp_n := 0
var _cam_from := Transform3D()
var _cam_to := Transform3D()
var _grid := {}


## drivers_info: by podium position (P1, P2, P3; fewer is fine), each
## {name, colour: Color, car}. p_player_slot: which of them the player
## drives (-1: none, everyone sprays on their own). title: the circuit's
## name on the backdrop. seed: the crowd's look.
func setup(drivers_info: Array, p_player_slot: int, title := "", seed := 7) -> void:
	_rng.seed = seed
	player_slot = p_player_slot
	_build_world(title)
	var team_cols := []
	for p in mini(drivers_info.size(), 3):
		var info: Dictionary = drivers_info[p]
		var col: Color = info.get("colour", Color(0.8, 0.1, 0.1))
		team_cols.append(col)
		var f := _figure("driver", col, Color(0.95, 0.95, 0.95))
		f.name = str(info.get("name", "Driver %d" % (p + 1)))
		f.base = Vector3(STEP_X[p], STEP_H[p], 0.1)
		f.face = _yaw_to_face(0.0)
		f.phase = p * 1.7
		f.trophy = _trophy(f, p)
		var b := Bottle.new()
		b.slot = p
		b.fig = f
		b.ai = p != player_slot
		b.pressure = 0.2
		b.ai_timer = _rng.randf_range(1.0, 2.6)
		b.yaw = [0.0, 0.35, -0.35][p]
		f.bottle = _bottle_prop(f, b)
		drivers.append(f)
		bottles.append(b)
	_build_crowd(team_cols)
	_build_fx()
	_place_camera()
	_layout()


## Moves the ceremony on: INTRO (wave to the crowd), TROPHY (lift the
## trophies), CHAMPAGNE (bottles out), DONE (bottles down).
func set_phase(p: int) -> void:
	phase = p as Phase
	_phase_t = 0.0
	for f in drivers:
		f.trophy.visible = phase == Phase.TROPHY
		f.bottle.visible = phase == Phase.CHAMPAGNE
	if phase == Phase.INTRO:
		_burst_tape(240)
	if phase == Phase.TROPHY:
		_burst_tape(MAX_TAPE)


# --- The player's bottle -----------------------------------------------------

func player_bottle() -> Bottle:
	return bottles[player_slot] if player_slot >= 0 and player_slot < bottles.size() else null


## Aims the player's bottle: yaw 0 = straight at the crowd, + to the right
## of the picture (towards +x); pitch up from level, radians.
func aim(yaw: float, pitch: float) -> void:
	var b := player_bottle()
	if b:
		b.yaw = clampf(yaw, -YAW_MAX, YAW_MAX)
		b.pitch = clampf(pitch, PITCH_MIN, PITCH_MAX)


## Aims the player's bottle so the stream lands on a point (e.g. the one
## under the mouse).
func aim_at(target: Vector3) -> void:
	var b := player_bottle()
	if b:
		var a := solve_aim(b, target)
		aim(a.x, a.y)


## Shakes the player's bottle (amount: how hard, 0..1).
func shake(amount := 0.15) -> void:
	var b := player_bottle()
	if b:
		_shake(b, amount)


## Holds the player's thumb off (true) or on (false) the bottle. The first
## spray pops the cork.
func set_spray(on: bool) -> void:
	var b := player_bottle()
	if b:
		_set_spray(b, on)


## The yaw and pitch that lands bottle b's stream on target at its current pressure.
func solve_aim(b: Bottle, target: Vector3) -> Vector2:
	var o := nozzle(b)
	var d := target - o
	var yaw := atan2(d.x, d.z)
	var dx := Vector2(d.x, d.z).length()
	var v := lerpf(SPEED_MIN, SPEED_MAX, b.pressure)
	var g := GRAVITY
	var disc := v * v * v * v - g * (g * dx * dx + 2.0 * d.y * v * v)
	var pitch := 0.75
	if disc >= 0.0 and dx > 0.05:
		pitch = atan((v * v - sqrt(disc)) / (g * dx))
	return Vector2(yaw, pitch)


## Where bottle b's stream comes out.
func nozzle(b: Bottle) -> Vector3:
	if b.fig.bottle and b.fig.bottle.is_inside_tree():
		return b.fig.bottle.global_transform * Vector3(0, -0.36, 0)
	return b.fig.base + Vector3(0, 1.45, 0) + aim_dir(b) * 0.7


static func aim_dir(b: Bottle) -> Vector3:
	return Vector3(sin(b.yaw) * cos(b.pitch), sin(b.pitch), cos(b.yaw) * cos(b.pitch))


## Where the player's stream would land now: on someone's head height
## (y 1.6) or the ground. For the aiming marker.
func landing_point() -> Vector3:
	var b := player_bottle()
	if b == null:
		return Vector3.ZERO
	var p := nozzle(b)
	var v := aim_dir(b) * lerpf(SPEED_MIN, SPEED_MAX, b.pressure)
	for i in 160:
		var np := p + v * 0.02
		v.y -= GRAVITY * 0.02
		if v.y < 0.0 and np.y < _floor_at(np) + 1.5:
			return np
		p = np
	return p


## How hard the champagne is going: 0 none .. about 3 (all three at full).
func spray_level() -> float:
	var s := 0.0
	for b in bottles:
		if b.spraying and not b.corked and b.fill > 0.0:
			s += 0.4 + 0.6 * b.pressure
	return s


## True once every bottle is empty.
func all_empty() -> bool:
	for b in bottles:
		if b.fill > 0.0:
			return false
	return true


# --- Bottles -----------------------------------------------------------------

func _shake(b: Bottle, amount: float) -> void:
	if b.fill <= 0.0:
		return
	b.pressure = minf(1.0, b.pressure + amount)
	b.shaking = 0.35


func _set_spray(b: Bottle, on: bool) -> void:
	if phase != Phase.CHAMPAGNE or b.fill <= 0.0:
		b.spraying = false
		return
	if on and b.corked:
		b.corked = false
		_pop_cork(b)
	b.spraying = on


func _pop_cork(b: Bottle) -> void:
	b.cork.visible = true
	b.cork.top_level = true
	b.cork.position = nozzle(b)
	b.cork_vel = aim_dir(b) * (8.0 + 8.0 * b.pressure) + Vector3(0, 2.5, 0)
	b.cork_flying = true
	# A burst of foam.
	for i in int(30 + 40 * b.pressure):
		_spawn_drop(b, 1.3)
	cork_popped.emit(b.slot)


func _update_bottle(b: Bottle, delta: float) -> void:
	if b.shaking > 0.0:
		b.shaking -= delta
	if b.cork_flying:
		b.cork_vel.y -= GRAVITY * delta
		b.cork.position += b.cork_vel * delta
		b.cork.rotate_x(delta * 18.0)
		if b.cork.position.y < 0.03:
			b.cork_flying = false
			b.cork.position.y = 0.03
	if b.spraying and not b.corked and b.fill > 0.0:
		var rate := lerpf(RATE_MIN, RATE_MAX, b.pressure)
		b.emit_acc += rate * delta
		while b.emit_acc >= 1.0:
			b.emit_acc -= 1.0
			_spawn_drop(b, 1.0)
		b.fill = maxf(0.0, b.fill - delta * lerpf(DRAIN_MIN, DRAIN_MAX, b.pressure))
		b.pressure = maxf(0.0, b.pressure - delta * 0.2)
		if b.fill <= 0.0:
			b.spraying = false
	else:
		b.pressure = maxf(0.0, b.pressure - delta * 0.04)


func _ai_bottle(b: Bottle, delta: float) -> void:
	if b.fill <= 0.0:
		b.spraying = false
		return
	b.ai_timer -= delta
	if b.ai_state == 0:
		# shaking it up
		if _rng.randf() < delta * 7.0:
			_shake(b, 0.09)
		if b.ai_timer <= 0.0:
			b.ai_state = 1
			b.ai_timer = _rng.randf_range(1.4, 3.2)
			b.ai_target = _pick_target(b)
			_set_spray(b, true)
	else:
		if b.ai_target == null or _rng.randf() < delta * 0.45:
			b.ai_target = _pick_target(b)
		var t: Figure = b.ai_target
		var aim_pt := t.base + Vector3(0, t.height * 0.85, 0)
		var a := solve_aim(b, aim_pt)
		var wob := Vector2(sin(_t * 2.3 + b.slot) * 0.12, sin(_t * 3.1 + b.slot * 2.0) * 0.07)
		b.yaw = lerp_angle(b.yaw, clampf(a.x + wob.x, -YAW_MAX - 0.6, YAW_MAX + 0.6), minf(1.0, delta * 4.0))
		b.pitch = lerpf(b.pitch, clampf(a.y + wob.y, PITCH_MIN, PITCH_MAX), minf(1.0, delta * 4.0))
		_set_spray(b, true)
		if b.ai_timer <= 0.0:
			b.ai_state = 0
			b.spraying = false
			b.ai_timer = _rng.randf_range(0.5, 1.3)


## Who an AI driver sprays: the other drivers (the player most of all) or someone in the crowd.
func _pick_target(b: Bottle) -> Figure:
	var r := _rng.randf()
	if r < 0.5 and drivers.size() > 1:
		var others := []
		for f in drivers:
			if f != b.fig:
				others.append(f)
				if player_slot >= 0 and f == drivers[player_slot]:
					others.append(f)   # the player gets it twice as often
		return others[_rng.randi() % others.size()]
	var crowd := figures.filter(func(f): return f.kind != "driver")
	return crowd[_rng.randi() % crowd.size()] if not crowd.is_empty() else b.fig


# --- Droplets ----------------------------------------------------------------

func _spawn_drop(b: Bottle, foam: float) -> void:
	var i := _d_n
	if i >= MAX_DROPS:
		i = _rng.randi() % MAX_DROPS   # full: replace an old one
	else:
		_d_n += 1
	var dir := aim_dir(b)
	var side := dir.cross(Vector3.UP).normalized()
	if side.length() < 0.1:
		side = Vector3.RIGHT
	var up := side.cross(dir).normalized()
	var spread := 0.045 + 0.05 * (1.0 - b.pressure) + (0.25 if foam > 1.0 else 0.0)
	dir = (dir + side * _rng.randfn(0.0, spread) + up * _rng.randfn(0.0, spread)).normalized()
	var speed := lerpf(SPEED_MIN, SPEED_MAX, b.pressure) * _rng.randf_range(0.82, 1.08) * (0.55 if foam > 1.0 else 1.0)
	_d_pos[i] = nozzle(b)
	_d_vel[i] = dir * speed
	_d_age[i] = 0.0 if foam <= 1.0 else -0.4   # foam starts big
	_d_owner[i] = b.slot


func _update_drops(delta: float) -> void:
	_build_grid()
	var i := 0
	while i < _d_n:
		var v := _d_vel[i]
		v.y -= GRAVITY * delta
		v *= 1.0 - 0.12 * delta
		var p := _d_pos[i] + v * delta
		var age := _d_age[i] + delta
		var dead := age > 3.0 or p.y < _floor_at(p) or p.y < -0.5 or (p.z < -1.03 and p.y < 6.0 and absf(p.x) < 6.8)
		if not dead:
			var f: Figure = _hit(p, _d_owner[i], age)
			if f != null:
				_soak(f, _d_owner[i])
				dead = _rng.randf() < 0.75
				v *= 0.25
		if dead:
			_d_n -= 1
			_d_pos[i] = _d_pos[_d_n]
			_d_vel[i] = _d_vel[_d_n]
			_d_age[i] = _d_age[_d_n]
			_d_owner[i] = _d_owner[_d_n]
			continue
		_d_pos[i] = p
		_d_vel[i] = v
		_d_age[i] = age
		i += 1
	# Draw them: a droplet is a small sphere, foam (young) is bigger.
	var mm := _drops.multimesh
	for k in _d_n:
		var age := _d_age[k]
		var s := 0.55 + 1.5 * clampf(0.35 - age, 0.0, 0.75) + clampf(age - 1.0, 0.0, 1.0) * -0.3
		var p := _d_pos[k]
		var o := k * 12
		_d_buf[o] = s
		_d_buf[o + 1] = 0.0
		_d_buf[o + 2] = 0.0
		_d_buf[o + 3] = p.x
		_d_buf[o + 4] = 0.0
		_d_buf[o + 5] = s
		_d_buf[o + 6] = 0.0
		_d_buf[o + 7] = p.y
		_d_buf[o + 8] = 0.0
		_d_buf[o + 9] = 0.0
		_d_buf[o + 10] = s
		_d_buf[o + 11] = p.z
	mm.buffer = _d_buf
	mm.visible_instance_count = _d_n


## The height of what's under p: a podium step or the ground.
func _floor_at(p: Vector3) -> float:
	for k in 3:
		if absf(p.x - STEP_X[k]) < STEP_W * 0.5 and absf(p.z) < STEP_D * 0.5:
			return STEP_H[k]
	return 0.0


func _build_grid() -> void:
	_grid.clear()
	for f in figures:
		var c := Vector2i(floori(f.base.x), floori(f.base.z))
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var k := Vector2i(c.x + dx, c.y + dz)
				if not _grid.has(k):
					_grid[k] = []
				_grid[k].append(f)


func _hit(p: Vector3, owner: int, age: float) -> Figure:
	var list = _grid.get(Vector2i(floori(p.x), floori(p.z)))
	if list == null:
		return null
	for f in list:
		if p.y < f.base.y or p.y > f.base.y + f.height:
			continue
		if Vector2(p.x - f.base.x, p.z - f.base.z).length_squared() > f.radius * f.radius:
			continue
		if f.kind == "driver" and owner >= 0 and owner < drivers.size() and drivers[owner] == f and age < 0.6:
			continue   # your own stream leaving the bottle
		return f
	return null


func _soak(f: Figure, owner: int) -> void:
	f.wet = minf(f.wet + 0.012, 1.0)
	f.hit_t = _t
	if owner == player_slot:
		player_hits += 1
	if not f.soaked and f.wet >= SOAKED_AT:
		f.soaked = true
		var by_player := owner == player_slot and player_slot >= 0
		if by_player:
			player_soaked += 1
		soaked.emit(f.name, by_player)


# --- Ticker tape -------------------------------------------------------------

func _burst_tape(n: int) -> void:
	for k in n:
		var i := _tp_n
		if i >= MAX_TAPE:
			i = _rng.randi() % MAX_TAPE
		else:
			_tp_n += 1
		_tp_pos[i] = Vector3(_rng.randf_range(-6.0, 6.0), _rng.randf_range(4.0, 9.0), _rng.randf_range(-1.0, 7.0))
		_tp_spin[i] = _rng.randf() * TAU


func _update_tape(delta: float) -> void:
	var mm := _tape.multimesh
	var i := 0
	while i < _tp_n:
		var p := _tp_pos[i]
		var sp := _tp_spin[i]
		p.y -= delta * (0.55 + 0.25 * sin(sp * 3.0))
		p.x += sin(_t * 1.3 + sp * 5.0) * delta * 0.5
		if p.y < 0.02:
			p.y = 0.02   # lies where it fell
		_tp_pos[i] = p
		var b := Basis(Vector3(sin(sp), 0.3, cos(sp)).normalized(), _t * (2.0 + sp) + sp) if p.y > 0.03 else Basis(Vector3.UP, sp)
		mm.set_instance_transform(i, Transform3D(b, p))
		i += 1
	mm.visible_instance_count = _tp_n


# --- Each frame --------------------------------------------------------------

func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	_t += delta
	_phase_t += delta
	if phase == Phase.CHAMPAGNE:
		for b in bottles:
			if b.ai:
				_ai_bottle(b, delta)
			_update_bottle(b, delta)
	else:
		for b in bottles:
			b.spraying = false
	_update_drops(delta)
	_update_tape(delta)
	_animate()
	# The camera eases in from a close shot of the winner to the whole podium.
	var k := smoothstep(0.0, 1.0, clampf(_t / 3.2, 0.0, 1.0))
	camera.transform = _cam_from.interpolate_with(_cam_to, k)
	camera.position += Vector3(sin(_t * 0.37) * 0.06, sin(_t * 0.51) * 0.04, 0)


func _animate() -> void:
	for f in figures:
		var hit_ago: float = _t - f.hit_t
		var pose: int = Pose.CHEER
		var face: float = f.face
		var bob := 0.0
		if f.kind == "driver":
			var b: Bottle = bottles[drivers.find(f)]
			match phase:
				Phase.INTRO:
					pose = Pose.WAVE
				Phase.TROPHY:
					pose = Pose.TROPHY
				Phase.CHAMPAGNE:
					if b.fill <= 0.0:
						pose = Pose.CHEER
					elif b.shaking > 0.0 and not b.spraying:
						pose = Pose.SHAKE
					elif b.spraying or not b.ai or b.ai_state == 1:
						pose = Pose.SPRAY
					else:
						pose = Pose.SHAKE
					face = _yaw_to_face(b.yaw) if pose == Pose.SPRAY else _yaw_to_face(b.yaw * 0.6)
				_:
					pose = Pose.CHEER
			if hit_ago < 0.35 and pose != Pose.SPRAY:
				pose = Pose.SHIELD
			bob = absf(sin(_t * 5.0 + f.phase)) * 0.05 if pose == Pose.CHEER or pose == Pose.WAVE else 0.0
		else:
			if f.kind == "photo":
				pose = Pose.PHOTO
			elif fmod(f.phase, 3.0) < 1.0:
				pose = Pose.CLAP
			if hit_ago < 0.5:
				pose = Pose.SHIELD
				face = f.face + 0.9 * signf(sin(f.phase))   # turn away from it
			elif f.soaked and hit_ago < 3.0:
				pose = Pose.CHEER
			var bounce := 0.09 if pose == Pose.CHEER else 0.03
			bob = absf(sin(_t * (4.0 + f.lively) + f.phase)) * bounce * f.lively if f.kind != "photo" else 0.0
		f.root.position = f.base + Vector3(0, bob, 0)
		f.root.rotation.y = lerp_angle(f.root.rotation.y, face, 0.25)
		_pose(f, pose)


## Sets the joints for a pose. Arms hang down -y; rotation.z swings them
## forward (+x, the way the figure faces), rotation.x out to the side.
func _pose(f: Figure, pose: int) -> void:
	var t := _t + f.phase
	var sl := Vector3.ZERO     # shoulder left (x out, z forward)
	var sr := Vector3.ZERO
	var el := 0.1
	var er := 0.1
	var lean := 0.0
	var knee := 0.04
	match pose:
		Pose.STAND:
			sl = Vector3(0.08, 0, 0.05)
			sr = Vector3(-0.08, 0, 0.05)
		Pose.CHEER:
			var w := sin(t * 6.0) * 0.22
			sl = Vector3(2.45 + w, 0, 0.3)
			sr = Vector3(-2.45 + w, 0, 0.3)
			el = 0.35
			er = 0.35
		Pose.WAVE:
			sl = Vector3(0.1, 0, 0.1)
			sr = Vector3(-2.3 - sin(t * 7.0) * 0.35, 0, 0.4)
			er = 0.5
		Pose.TROPHY:
			sl = Vector3(0.35, 0, 2.95)
			sr = Vector3(-0.35, 0, 2.95)
			el = 0.25
			er = 0.25
		Pose.HOLD:
			sl = Vector3(0.15, 0, 0.9)
			sr = Vector3(-0.15, 0, 0.9)
			el = 0.9
			er = 0.9
		Pose.SPRAY:
			var pitch := 0.3
			var bi := drivers.find(f)
			if bi >= 0:
				pitch = bottles[bi].pitch
			sr = Vector3(0.0, 0, PI * 0.5 + pitch)
			sl = Vector3(0.35, 0, PI * 0.5 + pitch - 0.45)
			el = 0.7
			er = 0.0
			lean = -0.12
		Pose.SHAKE:
			var s := sin(t * 26.0)
			sr = Vector3(-0.1, 0, 1.15 + s * 0.45)
			sl = Vector3(0.3, 0, 1.0)
			er = 1.1 + s * 0.35
			el = 1.2
		Pose.SHIELD:
			sl = Vector3(0.25, 0, 2.3)
			sr = Vector3(-0.25, 0, 2.3)
			el = 1.7
			er = 1.7
			lean = 0.35
			knee = 0.35
		Pose.CLAP:
			var c := sin(t * 14.0) * 0.18
			sl = Vector3(0.25 - c, 0, 0.95)
			sr = Vector3(-0.25 + c, 0, 0.95)
			el = 1.25
			er = 1.25
		Pose.PHOTO:
			sl = Vector3(0.2, 0, 1.3)
			sr = Vector3(-0.2, 0, 1.3)
			el = 1.95
			er = 1.95
	f.arm_l.rotation = Vector3(sl.x, 0, sl.z)
	f.arm_r.rotation = Vector3(sr.x, 0, sr.z)
	f.elbow_l.rotation.z = el
	f.elbow_r.rotation.z = er
	f.upper.rotation.z = lean
	f.knee_l.rotation.z = -knee
	f.knee_r.rotation.z = -knee
	f.hip_l.rotation.z = knee * 0.5
	f.hip_r.rotation.z = knee * 0.5
	f.body.position.y = -knee * 0.25


## rotation.y that faces a figure along a bottle yaw (0 = towards +z, the crowd).
static func _yaw_to_face(yaw: float) -> float:
	return atan2(-cos(yaw), sin(yaw))


# --- Building ----------------------------------------------------------------

func _mat(key: String, col: Color, rough := 0.7, metal := 0.0) -> StandardMaterial3D:
	if _meshes.has("m_" + key):
		return _meshes["m_" + key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	_meshes["m_" + key] = m
	return m


func _box(size: Vector3) -> BoxMesh:
	var key := "b_%s" % size
	if not _meshes.has(key):
		var b := BoxMesh.new()
		b.size = size
		_meshes[key] = b
	return _meshes[key]


func _capsule(r: float, h: float) -> CapsuleMesh:
	var key := "c_%.3f_%.3f" % [r, h]
	if not _meshes.has(key):
		var cm := CapsuleMesh.new()
		cm.radius = r
		cm.height = h
		cm.radial_segments = 10
		cm.rings = 3
		_meshes[key] = cm
	return _meshes[key]


func _sphere(r: float) -> SphereMesh:
	var key := "s_%.3f" % r
	if not _meshes.has(key):
		var sm := SphereMesh.new()
		sm.radius = r
		sm.height = r * 2.0
		sm.radial_segments = 12
		sm.rings = 7
		_meshes[key] = sm
	return _meshes[key]


func _cyl(top: float, bottom: float, h: float, seg := 14) -> CylinderMesh:
	var key := "y_%.3f_%.3f_%.3f" % [top, bottom, h]
	if not _meshes.has(key):
		var c := CylinderMesh.new()
		c.top_radius = top
		c.bottom_radius = bottom
		c.height = h
		c.radial_segments = seg
		_meshes[key] = c
	return _meshes[key]


func _part(parent: Node3D, mesh: Mesh, mat: Material, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
	return mi


func _joint(parent: Node3D, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = at
	parent.add_child(n)
	return n


func _label(parent: Node3D, text: String, size: int, at: Vector3, col := Color.WHITE) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = 0.01
	l.position = at
	l.modulate = col
	l.outline_size = 0
	l.double_sided = false
	l.shaded = true
	parent.add_child(l)
	return l


func _build_world(title: String) -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.22, 0.42, 0.78)
	sm.sky_horizon_color = Color(0.68, 0.78, 0.9)
	sm.ground_horizon_color = Color(0.5, 0.5, 0.5)
	sm.ground_bottom_color = Color(0.25, 0.25, 0.25)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.9
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	e.glow_intensity = 0.4
	e.ssao_enabled = true
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 28, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 200, 0)
	fill.light_energy = 0.25
	add_child(fill)
	# The ground: the pit lane's concrete with a painted apron under the crowd.
	_part(self, _box(Vector3(60, 0.2, 40)), _mat("concrete", Color(0.42, 0.43, 0.45), 0.9), Vector3(0, -0.1, 4))
	_part(self, _box(Vector3(16, 0.02, 7.5)), _mat("apron", Color(0.16, 0.2, 0.32), 0.8), Vector3(0, 0.01, 6.5))
	# The podium steps: white with a red front and the number.
	var steps := Node3D.new()
	add_child(steps)
	for k in 3:
		var h: float = STEP_H[k]
		_part(steps, _box(Vector3(STEP_W, h, STEP_D)), _mat("step", Color(0.93, 0.93, 0.95), 0.5), Vector3(STEP_X[k], h * 0.5, 0))
		_part(steps, _box(Vector3(STEP_W - 0.1, h - 0.12, 0.02)), _mat("step_front", Color(0.75, 0.08, 0.08), 0.5),
			Vector3(STEP_X[k], h * 0.5, STEP_D * 0.5 + 0.011))
		var num := _label(steps, str(k + 1), 96, Vector3(STEP_X[k], h * 0.5, STEP_D * 0.5 + 0.03), Color(1, 1, 1))
		num.pixel_size = 0.006 + 0.002 * (1.0 if k == 0 else 0.0)
	# Behind: the balcony back wall, sponsor boards and the circuit's name.
	var wall := Node3D.new()
	add_child(wall)
	_part(wall, _box(Vector3(13.5, 6.0, 0.3)), _mat("wall", Color(0.06, 0.08, 0.14), 0.6), Vector3(0, 3.0, -1.2))
	var board_cols := [Color(0.85, 0.1, 0.1), Color(0.95, 0.95, 0.95), Color(0.1, 0.3, 0.8), Color(0.98, 0.8, 0.1)]
	var words := ["TDR", "APEX", "PIT LANE", "GRID", "TDR", "CHEQUERED"]
	var n := 0
	for row in 2:
		for col in 6:
			var x := -5.6 + col * 2.24
			var y := 2.25 + row * 1.15
			var c: Color = board_cols[(row + col) % board_cols.size()]
			_part(wall, _box(Vector3(2.1, 1.0, 0.04)), _mat("board_%d" % ((row + col) % 4), c, 0.4), Vector3(x, y, -1.03))
			var tc := Color(0.05, 0.05, 0.08) if c.get_luminance() > 0.6 else Color(1, 1, 1)
			var w := _label(wall, words[n % words.size()], 64, Vector3(x, y, -1.0), tc)
			w.pixel_size = 0.0045
			n += 1
	_part(wall, _box(Vector3(13.5, 0.9, 0.06)), _mat("banner", Color(0.75, 0.08, 0.08), 0.5), Vector3(0, 4.95, -1.02))
	if title != "":
		var tl := _label(wall, title.to_upper(), 110, Vector3(0, 4.95, -0.98), Color(1, 1, 1))
		tl.pixel_size = 0.0055
	# The roof over the balcony and its pillars.
	_part(wall, _box(Vector3(14.5, 0.3, 3.6)), _mat("roof", Color(0.85, 0.86, 0.88), 0.5, 0.2), Vector3(0, 6.1, 0.4))
	for x in [-7.0, 7.0]:
		_part(wall, _box(Vector3(0.35, 6.1, 0.35)), _mat("pillar", Color(0.75, 0.76, 0.78), 0.5, 0.3), Vector3(x, 3.05, 1.9))
	# Flags on the roof.
	for k in 5:
		var pole := _joint(wall, Vector3(-5.0 + k * 2.5, 6.25, 0.4))
		_part(pole, _cyl(0.025, 0.025, 1.6, 6), _mat("pole", Color(0.8, 0.8, 0.8), 0.4, 0.6), Vector3(0, 0.8, 0))
		var flag_col: Color = [Color(0.1, 0.1, 0.1), Color(0.95, 0.95, 0.95), Color(0.85, 0.1, 0.1), Color(0.95, 0.95, 0.95), Color(0.1, 0.1, 0.1)][k]
		_part(pole, _box(Vector3(0.9, 0.55, 0.02)), _mat("flag_%d" % k, flag_col, 0.8), Vector3(0.46, 1.3, 0))
	# The barrier between the podium and the crowd.
	var rail := _mat("rail", Color(0.82, 0.82, 0.85), 0.35, 0.6)
	_part(self, _box(Vector3(15.0, 0.06, 0.06)), rail, Vector3(0, 1.05, BARRIER_Z))
	_part(self, _box(Vector3(15.0, 0.05, 0.05)), rail, Vector3(0, 0.55, BARRIER_Z))
	for k in 16:
		_part(self, _box(Vector3(0.05, 1.05, 0.05)), rail, Vector3(-7.5 + k, 0.53, BARRIER_Z))
	_part(self, _box(Vector3(15.0, 0.75, 0.02)), _mat("barrier_banner", Color(0.75, 0.08, 0.08), 0.6), Vector3(0, 0.62, BARRIER_Z + 0.05))
	# Grandstands far behind the crowd, for depth.
	for side in [-1.0, 1.0]:
		var gs := _joint(self, Vector3(side * 12.0, 0, 9.0))
		gs.rotation.y = side * 0.5
		for r in 6:
			_part(gs, _box(Vector3(9.0, 0.45, 0.8)), _mat("stand", Color(0.55, 0.57, 0.6), 0.8), Vector3(0, 0.25 + r * 0.45, r * 0.8))


## A person. kind: driver (race suit, cap) or crowd (team shirt, trousers).
func _figure(kind: String, col: Color, trim: Color) -> Figure:
	var f := Figure.new()
	f.kind = kind
	f.root = Node3D.new()
	add_child(f.root)
	f.body = _joint(f.root, Vector3.ZERO)
	var skin_tones := [Color(0.96, 0.8, 0.68), Color(0.87, 0.68, 0.52), Color(0.68, 0.48, 0.33), Color(0.45, 0.3, 0.2)]
	var skin: Color = skin_tones[_rng.randi() % skin_tones.size()]
	var shirt := _mat("shirt_%s" % col.to_html(), col, 0.75)
	var legs := _mat("legs_%s" % col.to_html(), col.darkened(0.35), 0.8) if kind == "driver" \
		else _mat("trousers", Color(0.12, 0.13, 0.16), 0.85)
	var trim_m := _mat("trim_%s" % trim.to_html(), trim, 0.5)
	var skin_m := _mat("skin_%s" % skin.to_html(), skin, 0.65)
	var boot := _mat("boot", Color(0.06, 0.06, 0.07), 0.6)
	for s in [-1.0, 1.0]:
		var hip := _joint(f.body, Vector3(0, 0.92, s * 0.11))
		_part(hip, _capsule(0.085, 0.5), legs, Vector3(0, -0.23, 0))
		var knee := _joint(hip, Vector3(0, -0.46, 0))
		_part(knee, _capsule(0.072, 0.48), legs, Vector3(0, -0.22, 0))
		_part(knee, _box(Vector3(0.25, 0.08, 0.11)), boot, Vector3(0.05, -0.44, 0))
		if s < 0.0:
			f.hip_l = hip
			f.knee_l = knee
		else:
			f.hip_r = hip
			f.knee_r = knee
	f.upper = _joint(f.body, Vector3(0, 0.92, 0))
	_part(f.upper, _box(Vector3(0.24, 0.2, 0.36)), legs, Vector3(0, 0.08, 0))
	_part(f.upper, _box(Vector3(0.26, 0.42, 0.44)), shirt, Vector3(0, 0.36, 0))
	if kind == "driver":
		# A white band and a sponsor patch on the suit.
		_part(f.upper, _box(Vector3(0.27, 0.06, 0.45)), trim_m, Vector3(0, 0.22, 0))
		_part(f.upper, _box(Vector3(0.02, 0.1, 0.16)), trim_m, Vector3(0.135, 0.44, 0))
	else:
		_part(f.upper, _box(Vector3(0.265, 0.12, 0.445)), trim_m, Vector3(0, 0.5, 0))
	f.head = _joint(f.upper, Vector3(0, 0.62, 0))
	_part(f.head, _capsule(0.05, 0.12), skin_m, Vector3(0, 0.02, 0))
	_part(f.head, _sphere(0.115), skin_m, Vector3(0.01, 0.16, 0))
	if kind == "driver" or _rng.randf() < 0.55:
		# A cap in the team's colour.
		var cap_m := shirt if kind == "driver" or _rng.randf() < 0.6 else trim_m
		_part(f.head, _sphere(0.12), cap_m, Vector3(0.0, 0.21, 0)).scale = Vector3(1, 0.6, 1)
		_part(f.head, _box(Vector3(0.14, 0.02, 0.18)), cap_m, Vector3(0.13, 0.2, 0))
	else:
		var hair: Color = [Color(0.1, 0.07, 0.05), Color(0.35, 0.22, 0.1), Color(0.75, 0.6, 0.35), Color(0.3, 0.3, 0.3)][_rng.randi() % 4]
		_part(f.head, _sphere(0.118), _mat("hair_%s" % hair.to_html(), hair, 0.9), Vector3(-0.015, 0.185, 0)).scale = Vector3(1, 0.75, 1)
	for s in [-1.0, 1.0]:
		var sh := _joint(f.upper, Vector3(0, 0.53, s * 0.27))
		_part(sh, _capsule(0.06, 0.34), shirt, Vector3(0, -0.15, 0))
		var el := _joint(sh, Vector3(0, -0.3, 0))
		_part(el, _capsule(0.055, 0.32), shirt if kind == "driver" else skin_m, Vector3(0, -0.14, 0))
		var hand := _joint(el, Vector3(0, -0.3, 0))
		_part(hand, _sphere(0.055), skin_m if kind != "driver" else _mat("glove", Color(0.1, 0.1, 0.1), 0.7), Vector3.ZERO)
		if s < 0.0:
			f.arm_l = sh
			f.elbow_l = el
		else:
			f.arm_r = sh
			f.elbow_r = el
			f.hand_r = hand
	figures.append(f)
	return f


## A gold trophy, held over the head (the winner's is the biggest).
func _trophy(f: Figure, pos: int) -> Node3D:
	var gold := _mat("gold", Color(1.0, 0.78, 0.28), 0.25, 0.9) if pos == 0 else \
		(_mat("silver", Color(0.85, 0.86, 0.9), 0.25, 0.9) if pos == 1 else _mat("bronze", Color(0.8, 0.5, 0.25), 0.3, 0.85))
	var s: float = [1.25, 1.05, 0.95][pos]
	var t := _joint(f.upper, Vector3(0.12, 1.42, 0))
	t.scale = Vector3.ONE * s
	_part(t, _cyl(0.07, 0.09, 0.08), _mat("plinth", Color(0.1, 0.1, 0.1), 0.4), Vector3(0, -0.12, 0))
	_part(t, _cyl(0.025, 0.04, 0.16), gold, Vector3(0, 0.0, 0))
	_part(t, _cyl(0.16, 0.05, 0.22), gold, Vector3(0, 0.19, 0))
	for z in [-0.17, 0.17]:
		var hnd := _part(t, _box(Vector3(0.03, 0.14, 0.04)), gold, Vector3(0, 0.2, z))
		hnd.rotation.x = 0.4 * signf(z)
	t.visible = false
	return t


## A champagne bottle in the right hand, pointing along the arm, with its cork.
func _bottle_prop(f: Figure, b: Bottle) -> Node3D:
	var n := _joint(f.hand_r, Vector3(0, -0.02, 0))
	var glass := _mat("bottle", Color(0.06, 0.22, 0.1), 0.15, 0.3)
	var foil := _mat("foil", Color(0.95, 0.75, 0.25), 0.3, 0.8)
	var label := _mat("bottle_label", Color(0.95, 0.92, 0.82), 0.6)
	_part(n, _cyl(0.048, 0.048, 0.24), glass, Vector3(0, -0.04, 0))
	_part(n, _cyl(0.0495, 0.0495, 0.09), label, Vector3(0, -0.06, 0))
	_part(n, _cyl(0.02, 0.046, 0.08), glass, Vector3(0, -0.2, 0))
	_part(n, _cyl(0.021, 0.021, 0.1), foil, Vector3(0, -0.29, 0))
	_part(n, _cyl(0.05, 0.05, 0.04), glass, Vector3(0, 0.1, 0))
	var cork := Node3D.new()
	n.add_child(cork)
	cork.position = Vector3(0, -0.36, 0)
	_part(cork, _cyl(0.02, 0.022, 0.04), _mat("cork", Color(0.72, 0.55, 0.32), 0.9), Vector3.ZERO)
	b.cork = cork
	n.visible = false
	return n


func _build_crowd(team_cols: Array) -> void:
	var cols := team_cols.duplicate()
	if cols.is_empty():
		cols = [Color(0.8, 0.1, 0.1)]
	var others := [Color(0.95, 0.95, 0.95), Color(0.15, 0.15, 0.18), Color(0.95, 0.55, 0.1), Color(0.15, 0.55, 0.3)]
	# Rows of people behind the barrier, the podium teams' mechanics nearest.
	var rows := [[3.35, 13], [4.1, 14], [4.85, 13], [5.6, 12], [6.4, 10]]
	for r in rows.size():
		var z: float = rows[r][0]
		var count: int = rows[r][1]
		for k in count:
			var x := -6.4 + (12.8 / (count - 1)) * k + _rng.randf_range(-0.22, 0.22) + (0.3 if r % 2 == 1 else 0.0)
			var col: Color
			if r < 2:
				col = cols[clampi(int((x + 6.4) / 12.8 * 3.0), 0, 2) % cols.size()]   # each team under its driver
			else:
				col = cols[_rng.randi() % cols.size()] if _rng.randf() < 0.6 else others[_rng.randi() % others.size()]
			var f := _figure("crowd", col, Color(0.95, 0.95, 0.95) if col.get_luminance() < 0.6 else Color(0.1, 0.1, 0.12))
			f.name = "mechanic"
			f.base = Vector3(x, 0.0, z + _rng.randf_range(-0.15, 0.15))
			var look := Vector2(-x * 0.4, -f.base.z).normalized()   # towards the podium
			f.face = atan2(-look.y, look.x)
			f.phase = _rng.randf() * 30.0
			f.lively = _rng.randf_range(0.6, 1.3)
			var sc := _rng.randf_range(0.92, 1.06)
			f.root.scale = Vector3.ONE * sc
			f.height *= sc
	# Photographers in front of the barrier, either side.
	for x in [-5.6, -4.4, 4.4, 5.6]:
		var f := _figure("photo", Color(0.12, 0.12, 0.14), Color(0.9, 0.6, 0.1))
		f.name = "photographer"
		f.base = Vector3(x, 0.0, 2.05 + _rng.randf_range(-0.1, 0.2))
		var look := Vector2(-x, -f.base.z).normalized()
		f.face = atan2(-look.y, look.x)
		f.phase = _rng.randf() * 10.0
		var cam := _joint(f.head, Vector3(0.18, 0.15, 0))
		_part(cam, _box(Vector3(0.12, 0.1, 0.16)), _mat("camera_body", Color(0.05, 0.05, 0.05), 0.4), Vector3.ZERO)
		_part(cam, _cyl(0.04, 0.04, 0.14, 10), _mat("lens", Color(0.1, 0.1, 0.1), 0.3), Vector3(0.1, 0, 0)).rotation.z = PI * 0.5
		f.camera_prop = cam


func _build_fx() -> void:
	_d_pos.resize(MAX_DROPS)
	_d_vel.resize(MAX_DROPS)
	_d_age.resize(MAX_DROPS)
	_d_owner.resize(MAX_DROPS)
	_d_buf.resize(MAX_DROPS * 12)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(1.0, 0.95, 0.72, 0.6)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.roughness = 0.05
	dm.metallic_specular = 0.9
	dm.emission_enabled = true
	dm.emission = Color(0.55, 0.5, 0.32)
	dm.emission_energy_multiplier = 0.35
	var sm := SphereMesh.new()
	sm.radius = 0.032
	sm.height = 0.064
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = dm
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sm
	mm.instance_count = MAX_DROPS
	mm.visible_instance_count = 0
	_drops = MultiMeshInstance3D.new()
	_drops.multimesh = mm
	_drops.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_drops.custom_aabb = AABB(Vector3(-30, -2, -30), Vector3(60, 30, 60))
	add_child(_drops)
	# Ticker tape: little paper strips in gold, white and red.
	_tp_pos.resize(MAX_TAPE)
	_tp_spin.resize(MAX_TAPE)
	var qm := QuadMesh.new()
	qm.size = Vector2(0.05, 0.12)
	var tm := StandardMaterial3D.new()
	tm.cull_mode = BaseMaterial3D.CULL_DISABLED
	tm.vertex_color_use_as_albedo = true
	tm.roughness = 0.4
	tm.metallic = 0.4
	qm.material = tm
	var tmm := MultiMesh.new()
	tmm.transform_format = MultiMesh.TRANSFORM_3D
	tmm.use_colors = true
	tmm.mesh = qm
	tmm.instance_count = MAX_TAPE
	var tape_cols := [Color(1.0, 0.8, 0.25), Color(0.95, 0.95, 0.95), Color(0.85, 0.1, 0.1), Color(1.0, 0.85, 0.4)]
	for i in MAX_TAPE:
		tmm.set_instance_color(i, tape_cols[i % tape_cols.size()])
	tmm.visible_instance_count = 0
	_tape = MultiMeshInstance3D.new()
	_tape.multimesh = tmm
	_tape.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tape.custom_aabb = AABB(Vector3(-30, -2, -30), Vector3(60, 30, 60))
	add_child(_tape)


func _place_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 44.0
	add_child(camera)
	var to := Transform3D(Basis(), Vector3(3.0, 5.4, 14.0))
	_cam_to = to.looking_at(Vector3(0.2, 1.9, 1.4), Vector3.UP)
	var from := Transform3D(Basis(), Vector3(1.4, 3.3, 6.0))
	_cam_from = from.looking_at(Vector3(0, 2.6, 0), Vector3.UP)
	camera.transform = _cam_from
	camera.current = true


func _layout() -> void:
	for f in figures:
		f.root.position = f.base
		f.root.rotation.y = f.face
		_pose(f, Pose.STAND)


## Where a world point is on the viewport (for name tags and the aim marker).
func screen_pos(p: Vector3) -> Vector2:
	if camera == null or camera.is_position_behind(p):
		return Vector2(-1000, -1000)
	return camera.unproject_position(p)


## The point on the ground at head height (y = h) under a viewport position (the mouse).
func world_under(screen: Vector2, h := 1.6) -> Vector3:
	var o := camera.project_ray_origin(screen)
	var d := camera.project_ray_normal(screen)
	if absf(d.y) < 0.001:
		return o + d * 10.0
	var k := (h - o.y) / d.y
	if k < 0.0:
		k = 20.0
	return o + d * k


## Head position of the driver in podium position p, for name tags.
func driver_head(p: int) -> Vector3:
	if p < 0 or p >= drivers.size():
		return Vector3.ZERO
	return drivers[p].base + Vector3(0, 2.15, 0)
