class_name PitCrews
extends Node3D
## The people of the pit lane. Every team in the race has a crew at its
## garage in team colours: they hang about in front of the garage, step out
## to their marks when their car is called in, and do the stop for real, the
## Le Mans way, following the stop's crew timeline (PitRules.crew_timeline,
## in work["crew"]): the car controller waves the car onto its marks with
## the lollipop, the refueller plugs in the hose with the fire extinguisher
## and cut-off valve attendants beside the rig, a mechanic puts the air
## lance in and the car rises on its air jacks, two mechanics change the
## tyres unaided (one down each side, front then rear: gun the nut off, swap
## the wheel, gun the new one on), two technicians kneel by the old tyres to
## check them, the cockpit helper opens the door for a driver change,
## mechanics work on the nose and tail for repairs, the lance comes out, the
## car drops and the lollipop turns green to send it away. Between stops
## mechanics wander between the garage and the apron, and a strategist sits
## on the pit wall. Tyre stacks under blankets, trolleys and fuel rigs stand
## at each garage.
##
## Purely visual: the race scene tells it what each car's stop is doing
## (set_stop) and it never changes the race.

const RUN_SPEED := 4.2          ## m/s, crew jogging to their marks
const WALK_SPEED := 1.4
const SHOW_DIST := 450.0        ## camera distance (m) beyond which people hide

enum Stop { NONE, COMING, SERVICE, LEAVING }
enum Pose { STAND, KNEEL, CROUCH, LEAN, SIGNAL, CARRY, SIT }

## Roles in the stop crew (index into a crew's members).
const LOLLIPOP := 0      ## the car controller
const LANCE := 1         ## air lance: the car up on its air jacks and down again
const GUN_L := 2         ## tyre changer down the left side (front left, then rear left)
const GUN_R := 3         ## and down the right side
const TECH_A := 4        ## tyre and brake technicians (check the old tyres)
const TECH_B := 5
const FUEL := 6          ## the refueller
const EXTINGUISHER := 7  ## fire extinguisher attendant, beside the refueller
const VALVE := 8         ## cut-off valve attendant, at the rig
const COCKPIT := 9       ## cockpit helper (driver changes)
const WANDER_A := 10     ## mechanics: repairs, or wandering between stops
const WANDER_B := 11
const CREW_SIZE := 12
## Share of a wheel's time: gun the nut off, swap the wheel, gun the new one on.
const NUT_OFF := 0.35
const NEW_ON := 0.6

var track: TrackData
var tv: TrackView
var crews := {}                 ## box index -> Crew
var _car_box := {}              ## car index -> box index
var _meshes := {}
var _show := true
var _cam_centre := Vector2.ZERO
var _cam_reach := INF
var _t := 0.0
var _rng := RandomNumberGenerator.new()


class Person:
	extends RefCounted
	var root: Node3D
	var body: Node3D      ## raised / lowered (kneeling)
	var upper: Node3D     ## leans forward
	var leg_l: Node3D
	var leg_r: Node3D
	var arm_l: Node3D
	var arm_r: Node3D
	var held: Node3D      ## gun / lollipop / extinguisher in the hands (may be null)
	var tyre: Node3D      ## a wheel carried in the arms (gunners), shown while carrying
	var pos := Vector2.ZERO
	var face := 0.0
	var target := Vector2.ZERO
	var target_face := 0.0
	var pose := 0
	var speed := 4.2
	var walk := 0.0
	var fidget := 0.0
	var next_wander := 0.0


class Crew:
	extends RefCounted
	var box := 0
	var filler := false           ## a garage no car in this race uses
	var box_pos := Vector2.ZERO
	var box_dir := Vector2.RIGHT
	var pos := Vector2.ZERO       ## the car's spot in the box (where it actually stopped, mid-stop)
	var dir := Vector2.RIGHT      ## along the lane
	var out := Vector2.UP         ## from the box towards the garage
	var y := 0.0
	var team := Color.WHITE
	var people: Array = []        ## Person
	var home: Array = []          ## [Vector2 spot, face] per person, by the garage
	var ground_tyres: Array = []  ## old tyres lying by the wheels mid-stop
	var hose: MeshInstance3D
	var rig := Vector2.ZERO       ## fuel rig, where the hose comes from
	var lolly: MeshInstance3D     ## lollipop disc (red = wait, green = go)
	var state := 0
	var elapsed := 0.0
	var work := {}
	var car_len := 4.6
	var car_front := 2.3
	var car_rear := 2.3
	var track_w := 1.7
	var axle_f := 1.4
	var axle_r := 1.4


func setup(p_tv: TrackView) -> void:
	name = "PitCrews"
	tv = p_tv
	track = tv.track
	_rng.seed = 99


## A team's crew at its garage (box index from the race's pit rules), in
## the team's colour. Cars sharing a box share the crew.
func add_team(car: int, box: int, colour: Color, def: CarDefinition) -> void:
	_car_box[car] = box
	if crews.has(box) or not track.has_pit_lane():
		return
	_new_crew(box, colour, def)


func _new_crew(box: int, colour: Color, def: CarDefinition) -> Crew:
	var c := Crew.new()
	c.box = box
	var b := track.pit_box(box)
	c.box_pos = b["pos"]
	c.box_dir = Vector2.from_angle(b["heading"])
	c.pos = c.box_pos
	c.dir = c.box_dir
	c.out = Vector2(-c.dir.y, c.dir.x) * track.pit_side
	c.y = tv.pit_height(b["d"])
	c.team = colour
	if def:
		c.car_front = def.cg_to_front + def.length * 0.22
		c.car_rear = def.length - c.car_front
		c.track_w = def.track_width
		c.axle_f = def.cg_to_front
		c.axle_r = def.wheelbase - def.cg_to_front
		c.car_len = def.length
	crews[box] = c
	_build_crew(c)
	return c


## Garages no car in this race uses still have people in them (other
## teams' mechanics), so the whole pit lane is busy. Call after add_team.
func fill_garages() -> void:
	if not track.has_pit_lane():
		return
	var palette := [Color(0.85, 0.1, 0.1), Color(0.1, 0.25, 0.7), Color(0.92, 0.92, 0.92), Color(0.12, 0.12, 0.12),
		Color(0.95, 0.5, 0.05), Color(0.1, 0.55, 0.3), Color(0.9, 0.8, 0.1), Color(0.45, 0.2, 0.6)]
	for b in track.pit_box_count:
		if not crews.has(b):
			var c := _new_crew(b, palette[(b * 3) % palette.size()], null)
			c.filler = true


## Where car i is (drawn), so the crew work round the car where it stopped.
func set_car_pose(car: int, pos: Vector2, heading: float) -> void:
	var c := _crew_of(car)
	if c == null:
		return
	if c.state == Stop.SERVICE:
		c.pos = pos
		c.dir = Vector2.from_angle(heading)
	else:
		c.pos = c.box_pos
		c.dir = c.box_dir


## What car's stop is doing: state (Stop), seconds since it stopped, and the
## work being done {tyre_s, fuel_s, repair_s, total_s} (seconds; 0 = none).
func set_stop(car: int, state: int, elapsed: float, work: Dictionary) -> void:
	if not _car_box.has(car) or not crews.has(_car_box[car]):
		return
	var c: Crew = crews[_car_box[car]]
	# Two cars in one box: whichever is actually stopping wins.
	if state == Stop.NONE and c.state != Stop.NONE and c.work.get("car", -1) != car:
		return
	c.state = state
	c.elapsed = elapsed
	if state == Stop.SERVICE or state == Stop.COMING:
		c.work = work.duplicate()
		c.work["car"] = car


## How high the car in this box is on its air jacks (metres).
func car_lift(car: int) -> float:
	var c := _crew_of(car)
	if c == null or c.state != Stop.SERVICE:
		return 0.0
	var tl := _tl(c)
	var up: Array = tl.get("up", [0.0, 0.0])
	var down: Array = tl.get("down", [1e9, 1e9])
	if not _lifts(c):
		return 0.0
	var e := c.elapsed
	var rise := clampf((e - float(up[0])) / maxf(float(up[1]) - float(up[0]), 0.05), 0.0, 1.0)
	var fall := clampf((float(down[1]) - e) / maxf(float(down[1]) - float(down[0]), 0.05), 0.0, 1.0)
	return 0.075 * minf(rise, fall)


## Which wheels are off the car right now: bits 1 front left, 2 front
## right, 4 rear left, 8 rear right.
func wheels_off_mask(car: int) -> int:
	var c := _crew_of(car)
	if c == null or c.state != Stop.SERVICE:
		return 0
	var mask := 0
	for job in _jobs(c):
		var d: float = float(job["on"]) - float(job["off"])
		if c.elapsed > float(job["off"]) + d * NUT_OFF and c.elapsed < float(job["off"]) + d * NEW_ON:
			mask |= 1 << int(job["wheel"])
	return mask


func wheels_off(car: int) -> bool:
	return wheels_off_mask(car) != 0


## People are drawn only when the camera is this close (metres); crews far
## off screen stand still.
func set_camera(centre: Vector2, d: float) -> void:
	_cam_centre = centre
	_cam_reach = d * 0.75 + 40.0
	var show := d < SHOW_DIST
	if show != _show:
		_show = show
		visible = show


func _crew_of(car: int) -> Crew:
	if not _car_box.has(car):
		return null
	var c: Crew = crews.get(_car_box[car])
	if c == null or c.work.get("car", -1) != car:
		return null
	return c


## The stop's crew timeline (PitRules.crew_timeline), {} before it's known.
func _tl(c: Crew) -> Dictionary:
	var tl = c.work.get("crew", {})
	return tl if tl is Dictionary else {}


## Every wheel job, both gunners: [{wheel, off, on, fumble, gun}].
func _jobs(c: Crew) -> Array:
	var out := []
	var guns: Array = _tl(c).get("guns", [])
	for g in guns.size():
		for job in guns[g]:
			var j: Dictionary = (job as Dictionary).duplicate()
			j["gun"] = g
			out.append(j)
	return out


## The car goes up on its jacks (tyres or repairs to do).
func _lifts(c: Crew) -> bool:
	return float(c.work.get("tyre_s", 0.0)) > 0.0 or float(c.work.get("repair_s", 0.0)) > 0.0


func _in(e: float, span) -> bool:
	return span is Array and (span as Array).size() >= 2 and e >= float(span[0]) and e <= float(span[-1])


# --- Each frame ------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _show:
		return
	delta = minf(delta, 0.05)
	_t += delta
	for k in crews:
		var c: Crew = crews[k]
		if c.box_pos.distance_to(_cam_centre) > _cam_reach and c.state == Stop.NONE:
			continue
		_plan(c)
		for p in c.people:
			_move(p, delta)
		_props(c)


## Where everyone in a crew should be and what they're doing.
func _plan(c: Crew) -> void:
	var tl := _tl(c)
	var e := c.elapsed
	var active := c.state == Stop.COMING or c.state == Stop.SERVICE
	for i in CREW_SIZE:
		var p: Person = c.people[i]
		var home: Array = c.home[i]
		if not active:
			p.speed = WALK_SPEED if c.state == Stop.NONE else RUN_SPEED * 0.6
			if i >= WANDER_A or (c.filler and i % 3 == 1):
				_wander(c, p, home)
			else:
				p.target = home[0]
				p.target_face = home[1]
			p.pose = Pose.STAND
			if i == LOLLIPOP and c.state == Stop.LEAVING:
				p.pose = Pose.SIGNAL
			continue
		p.speed = RUN_SPEED
		var spot := _station(c, i, tl)
		p.target = spot[0]
		p.target_face = spot[1]
		p.pose = spot[2]
	# lollipop: red while working, green to go
	if c.lolly:
		var go: bool = c.state == Stop.LEAVING or (c.state == Stop.SERVICE and e > float((tl.get("down", [1e9, 1e9]) as Array)[-1]))
		(c.lolly.material_override as StandardMaterial3D).albedo_color = Color(0.1, 0.8, 0.2) if go else Color(0.85, 0.08, 0.06)


## A crew member's mark around the car in the box: [spot, facing, pose].
## The right side of the car (wheels 1 and 3) faces the garage.
func _station(c: Crew, i: int, tl: Dictionary) -> Array:
	var e := c.elapsed
	var serving := c.state == Stop.SERVICE
	var tw := c.track_w * 0.5
	var into := c.dir.angle()       # facing along the lane
	var to_car := (-c.out).angle()  # facing the car from the garage side
	var from_out := c.out.angle()   # facing the car from the far side
	var fuel: Array = tl.get("fuel", [])
	var fuel_on: bool = serving and _in(e, fuel)
	var repairing: bool = serving and _in(e, tl.get("repair", []))
	var down: Array = tl.get("down", [1e9, 1e9])
	match i:
		LOLLIPOP:
			return [_at(c, c.car_front + 2.2, 0.0), into + PI, Pose.SIGNAL]
		LANCE:
			# plugs the air lance in at the back on the garage side, holds it, pulls it out
			var spot := _at(c, -c.car_rear + 0.35, tw + 0.75)
			if not _lifts(c):
				return [_at(c, -c.car_rear - 0.6, tw + 2.4), to_car, Pose.STAND]
			var up: Array = tl.get("up", [0.0, 0.0])
			var plugging: bool = serving and (_in(e, [float(up[0]) - 0.3, up[1]]) or _in(e, down))
			return [spot, to_car, Pose.CROUCH if plugging else Pose.STAND]
		GUN_L, GUN_R:
			var g := i - GUN_L
			var s := 1.0 if g == 1 else -1.0
			var face := to_car if s > 0.0 else from_out
			var jobs: Array = (tl.get("guns", [[], []]) as Array)[g] if (tl.get("guns", []) as Array).size() > g else []
			if jobs.is_empty():
				return [_at(c, 0.6 if g == 0 else -0.6, tw + 2.8), to_car, Pose.STAND]
			# the wheel being done now, or the next one, or the last one done
			var job: Dictionary = jobs[0]
			for j in jobs:
				job = j
				if e < float(j["on"]):
					break
			var x := c.axle_f if int(job["wheel"]) < 2 else -c.axle_r
			var wheel_spot := _at(c, x, s * (tw + 0.75))
			if not serving:
				return [wheel_spot, face, Pose.STAND]
			var d: float = float(job["on"]) - float(job["off"])
			var f := (e - float(job["off"])) / maxf(d, 0.01)
			if f < 0.0 or f > 1.0:
				return [wheel_spot, face, Pose.STAND]
			if f > NUT_OFF and f < NEW_ON:
				# old wheel out, new one in (a fumble shows as a longer swap)
				return [_at(c, x + 0.5, s * (tw + 1.35)), face, Pose.CARRY]
			return [wheel_spot, face, Pose.KNEEL]
		TECH_A, TECH_B:
			# kneel by the old tyres the gunners have taken off, checking them
			var front := i == TECH_A
			var x := (c.axle_f if front else -c.axle_r) + 0.55
			var checking := false
			for job in _jobs(c):
				if (int(job["wheel"]) < 2) == front and serving \
						and e > float(job["off"]) + (float(job["on"]) - float(job["off"])) * NEW_ON:
					checking = true
			if checking:
				return [_at(c, x + 0.6, tw + 1.4), to_car, Pose.CROUCH]
			return [_at(c, x, tw + 3.0), to_car, Pose.STAND]
		FUEL:
			if fuel.is_empty():
				return [_at(c, -0.4, tw + 3.4), to_car, Pose.STAND]
			return [_at(c, -0.6, tw + 0.85), to_car, Pose.LEAN if fuel_on else Pose.STAND]
		EXTINGUISHER:
			if fuel.is_empty():
				return [_at(c, -1.4, tw + 3.6), to_car, Pose.STAND]
			return [_at(c, -1.7, tw + 1.7), to_car + 0.4, Pose.STAND]
		VALVE:
			var by_rig := c.rig + c.dir * 0.6 - c.out * 0.5
			return [by_rig, to_car, Pose.CROUCH if fuel_on else Pose.STAND]
		COCKPIT:
			var swap: Array = tl.get("driver", [])
			if serving and _in(e, swap):
				return [_at(c, 0.1, -(tw + 0.7)), from_out, Pose.LEAN]
			return [_at(c, 1.4, tw + 3.2), to_car, Pose.STAND]
		_:
			# spare mechanics help with repairs, or watch from the garage
			if repairing:
				return [_at(c, c.car_front + 0.5 if i == WANDER_A else -c.car_rear - 0.5, -0.4 if i == WANDER_A else 0.6),
					into + PI if i == WANDER_A else into, Pose.CROUCH]
			return [_at(c, 2.0 if i == WANDER_A else -2.0, tw + 3.6), to_car, Pose.STAND]


## The wheels (0 front left .. 3 rear right) this stop changes.
func _wheels(c: Crew) -> Array:
	return c.work.get("wheels", [0, 1, 2, 3])


## A point in the box: along metres forward from the car's centre, across
## metres towards the garage.
func _at(c: Crew, along: float, across: float) -> Vector2:
	return c.pos + c.dir * along + c.out * across


func _wander(c: Crew, p: Person, home: Array) -> void:
	if _t < p.next_wander and p.target != Vector2.ZERO:
		return
	p.next_wander = _t + _rng.randf_range(3.0, 9.0)
	if _rng.randf() < 0.4:
		p.target = home[0]
	else:
		var gw := track.pit_width * 0.5 + 2.4
		var across := _rng.randf_range(gw - 3.4, gw) - track.pit_width * 0.25
		p.target = _at(c, _rng.randf_range(-3.5, 3.5), across)
	p.target_face = c.out.angle() + PI + _rng.randf_range(-1.2, 1.2)


func _move(p: Person, delta: float) -> void:
	var to := p.target - p.pos
	var dist := to.length()
	var moving := dist > 0.06
	if moving:
		var step := minf(dist, p.speed * delta)
		p.pos += to / dist * step
		p.face = lerp_angle(p.face, to.angle(), 1.0 - exp(-12.0 * delta))
		p.walk += step * (3.4 if p.speed > 2.0 else 4.2)
	else:
		p.face = lerp_angle(p.face, p.target_face, 1.0 - exp(-7.0 * delta))
		p.walk = lerpf(p.walk, roundf(p.walk / PI) * PI, 1.0 - exp(-10.0 * delta))
	p.fidget += delta
	p.root.position = Vector3(p.pos.x, p.root.position.y, p.pos.y)
	p.root.rotation.y = -p.face
	# Pose
	var swing := sin(p.walk) * (0.7 if p.speed > 2.0 else 0.45) if moving else 0.0
	var hips := 0.0
	var lean := 0.0
	var leg_l := swing
	var leg_r := -swing
	var arm_l := -swing * 0.8
	var arm_r := swing * 0.8
	var pose := p.pose if not moving or p.pose == Pose.CARRY else Pose.STAND
	match pose:
		Pose.STAND:
			arm_l += 0.06 + sin(p.fidget * 1.3) * 0.04
			arm_r += 0.06 + sin(p.fidget * 1.1 + 1.0) * 0.04
		Pose.KNEEL:
			hips = -0.42
			leg_l = 1.45
			leg_r = -1.0
			lean = -0.45
			arm_l = 1.35 + sin(p.fidget * 38.0) * 0.05    # gun rattling on the nut
			arm_r = 1.25 + sin(p.fidget * 41.0) * 0.05
		Pose.CROUCH:
			hips = -0.28
			leg_l = 0.9
			leg_r = 0.4
			lean = -0.7
			arm_l = 1.2
			arm_r = 1.2
		Pose.LEAN:
			lean = -0.3
			arm_l = 0.95
			arm_r = 0.8
		Pose.SIGNAL:
			arm_l = 2.7
			arm_r = 0.1
		Pose.CARRY:
			arm_l = 1.0
			arm_r = 1.0
			lean = 0.08
		Pose.SIT:
			hips = -0.4
			leg_l = 1.5
			leg_r = 1.5
			arm_l = 0.7 + sin(p.fidget * 0.7) * 0.1
			arm_r = 0.5
	var k := 1.0 - exp(-14.0 * delta)
	p.body.position.y = lerpf(p.body.position.y, hips, k)
	p.upper.rotation.z = lerpf(p.upper.rotation.z, lean, k)
	p.leg_l.rotation.z = lerpf(p.leg_l.rotation.z, leg_l, k)
	p.leg_r.rotation.z = lerpf(p.leg_r.rotation.z, leg_r, k)
	p.arm_l.rotation.z = lerpf(p.arm_l.rotation.z, arm_l, k)
	p.arm_r.rotation.z = lerpf(p.arm_r.rotation.z, arm_r, k)
	if p.tyre:
		p.tyre.visible = p.pose == Pose.CARRY


## Old tyres on the ground while the wheels are off; the fuel hose.
func _props(c: Crew) -> void:
	# Old tyres on the ground from when they come off until the car leaves.
	var down_at := [false, false, false, false]
	if c.state == Stop.SERVICE:
		for job in _jobs(c):
			if c.elapsed > float(job["off"]) + (float(job["on"]) - float(job["off"])) * NUT_OFF:
				down_at[int(job["wheel"])] = true
	# Ground tyres by corner: front +side, front -side, rear +side, rear -side.
	var corner_wheel := [1, 0, 3, 2]
	var off := false
	for k in c.ground_tyres.size():
		var on_ground: bool = down_at[corner_wheel[k % 4]]
		(c.ground_tyres[k] as Node3D).visible = on_ground
		off = off or on_ground
	if off:
		var tw := c.track_w * 0.5
		var k := 0
		for corner in [[c.axle_f, 1.0], [c.axle_f, -1.0], [-c.axle_r, 1.0], [-c.axle_r, -1.0]]:
			var q := _at(c, corner[0] + 0.55, corner[1] * (tw + 0.45))
			(c.ground_tyres[k] as Node3D).position = Vector3(q.x, c.y + 0.16, q.y)
			k += 1
	# hose from the rig to the fueller's hands
	var f: Person = c.people[FUEL]
	var hand := f.pos + Vector2.from_angle(f.face) * 0.45
	var a := Vector3(c.rig.x, c.y + 1.1, c.rig.y)
	var b := Vector3(hand.x, c.y + 1.0, hand.y)
	var d := b - a
	var len := d.length()
	c.hose.visible = len > 0.3 and not (_tl(c).get("fuel", []) as Array).is_empty() and c.state != Stop.NONE
	if c.hose.visible:
		var xa := d / len
		var ya := xa.cross(Vector3.UP).normalized()
		if ya.length_squared() < 0.5:
			ya = Vector3.FORWARD
		var za := xa.cross(ya)
		c.hose.transform = Transform3D(Basis(xa * len, ya, za), (a + b) * 0.5)


# --- Building --------------------------------------------------------------------

func _mat(key: String, col: Color, rough := 0.7, metal := 0.0) -> StandardMaterial3D:
	if _meshes.has("m_" + key):
		return _meshes["m_" + key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	_meshes["m_" + key] = m
	return m


func _box_mesh(size: Vector3) -> BoxMesh:
	var key := "b_%s" % size
	if not _meshes.has(key):
		var b := BoxMesh.new()
		b.size = size
		_meshes[key] = b
	return _meshes[key]


func _part(parent: Node3D, mesh: Mesh, mat: Material, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # thousands of little meshes: no shadows
	parent.add_child(mi)
	return mi


func _tyre_mesh() -> CylinderMesh:
	if not _meshes.has("tyre"):
		var cy := CylinderMesh.new()
		cy.top_radius = 0.34
		cy.bottom_radius = 0.34
		cy.height = 0.3
		cy.radial_segments = 14
		_meshes["tyre"] = cy
	return _meshes["tyre"]


func _person(c: Crew, suit: Color, helmet: Color) -> Person:
	var p := Person.new()
	p.root = Node3D.new()
	add_child(p.root)
	p.root.position.y = c.y
	p.body = Node3D.new()
	p.root.add_child(p.body)
	var suit_m := _mat("suit_%s" % suit.to_html(), suit, 0.8)
	var helm := _mat("helm_%s" % helmet.to_html(), helmet, 0.25, 0.1)
	var visor := _mat("visor", Color(0.03, 0.04, 0.06), 0.05, 0.3)
	# legs swing from the hips
	for s in [-1.0, 1.0]:
		var hip := Node3D.new()
		hip.position = Vector3(0, 0.9, s * 0.11)
		p.body.add_child(hip)
		_part(hip, _box_mesh(Vector3(0.17, 0.86, 0.17)), suit_m, Vector3(0, -0.43, 0))
		if s < 0.0:
			p.leg_l = hip
		else:
			p.leg_r = hip
	p.upper = Node3D.new()
	p.upper.position = Vector3(0, 0.9, 0)
	p.body.add_child(p.upper)
	_part(p.upper, _box_mesh(Vector3(0.27, 0.62, 0.48)), suit_m, Vector3(0, 0.31, 0))
	if not _meshes.has("head"):
		var head := SphereMesh.new()
		head.radius = 0.15
		head.height = 0.3
		head.radial_segments = 10
		head.rings = 6
		_meshes["head"] = head
	_part(p.upper, _meshes["head"], helm, Vector3(0, 0.79, 0))
	_part(p.upper, _box_mesh(Vector3(0.06, 0.1, 0.2)), visor, Vector3(0.13, 0.78, 0))
	for s in [-1.0, 1.0]:
		var sh := Node3D.new()
		sh.position = Vector3(0, 0.56, s * 0.3)
		p.upper.add_child(sh)
		_part(sh, _box_mesh(Vector3(0.13, 0.66, 0.13)), suit_m, Vector3(0, -0.32, 0))
		if s < 0.0:
			p.arm_l = sh
		else:
			p.arm_r = sh
	for mi in _all_meshes(p.root):
		mi.visibility_range_end = SHOW_DIST
	return p


func _all_meshes(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		out.append_array(_all_meshes(c))
	return out


func _build_crew(c: Crew) -> void:
	var suit := c.team
	var helmet := Color(0.95, 0.95, 0.95) if c.team.get_luminance() < 0.6 else Color(0.1, 0.1, 0.12)
	var gw := track.pit_width * 0.5 + 3.0 - track.pit_width * 0.25   # garage front, from the box centre
	for i in CREW_SIZE:
		var p := _person(c, suit, helmet)
		# home: two loose rows in front of the garage
		var along := -3.6 + (i % 6) * 1.45 + _rng.randf_range(-0.2, 0.2)
		var across := gw - 0.8 - (i / 6) * 1.1 + _rng.randf_range(-0.15, 0.15)
		var spot := _at(c, along, across)
		var face := (-c.out).angle() + _rng.randf_range(-0.5, 0.5)
		c.home.append([spot, face])
		p.pos = spot
		p.target = spot
		p.face = face
		p.target_face = face
		p.fidget = _rng.randf() * 10.0
		p.next_wander = _rng.randf_range(0.0, 6.0)
		c.people.append(p)
		# what they hold
		if i == GUN_L or i == GUN_R:
			var gun := _part(p.arm_r, _box_mesh(Vector3(0.32, 0.12, 0.12)), _mat("gun", Color(0.75, 0.75, 0.78), 0.3, 0.6), Vector3(0.12, -0.66, -0.1))
			gun.name = "Gun"
			p.held = gun
			# they carry the wheels themselves (unaided, Le Mans rules)
			var holder := Node3D.new()
			holder.name = "Tyre"
			holder.position = Vector3(0.42, 0.35, 0)
			p.upper.add_child(holder)
			var t := _part(holder, _tyre_mesh(), _mat("rubber", Color(0.05, 0.05, 0.05), 0.85), Vector3.ZERO)
			t.rotation.x = PI * 0.5
			t.visibility_range_end = SHOW_DIST
			holder.visible = false
			p.tyre = holder
		elif i == EXTINGUISHER:
			var ext := _part(p.arm_r, _box_mesh(Vector3(0.18, 0.5, 0.18)), _mat("extinguisher", Color(0.85, 0.08, 0.06), 0.4, 0.2), Vector3(0.1, -0.7, 0))
			ext.visibility_range_end = SHOW_DIST
			p.held = ext
		elif i == LOLLIPOP:
			var stick := _part(p.arm_l, _box_mesh(Vector3(0.04, 1.1, 0.04)), _mat("dark", Color.BLACK), Vector3(0, -1.1, 0))
			stick.visibility_range_end = SHOW_DIST
			var disc := CylinderMesh.new()
			disc.top_radius = 0.32
			disc.bottom_radius = 0.32
			disc.height = 0.04
			disc.radial_segments = 16
			c.lolly = _part(p.arm_l, disc, StandardMaterial3D.new(), Vector3(0, -1.7, 0))
			(c.lolly.material_override as StandardMaterial3D).albedo_color = Color(0.85, 0.08, 0.06)
			c.lolly.visibility_range_end = SHOW_DIST
	# old tyres by the wheels during a stop
	for k in 4:
		var t := _part(self, _tyre_mesh(), _mat("rubber", Color(0.05, 0.05, 0.05), 0.85), Vector3.ZERO)
		t.visible = false
		t.visibility_range_end = SHOW_DIST
		c.ground_tyres.append(t)
	# garage props: tyre stacks under team-coloured blankets, trolley, fuel rig
	var blanket := _mat("blanket_%s" % suit.to_html(), suit.darkened(0.15), 0.9)
	for k in 2:
		var at := _at(c, -3.2 + k * 0.85, gw - 0.35)
		for h in 4:
			var t := _part(self, _tyre_mesh(), _mat("rubber", Color(0.05, 0.05, 0.05), 0.85), Vector3(at.x, c.y + 0.15 + h * 0.3, at.y))
			t.visibility_range_end = SHOW_DIST
		if not _meshes.has("cover"):
			var cover := CylinderMesh.new()
			cover.top_radius = 0.36
			cover.bottom_radius = 0.37
			cover.height = 0.5
			cover.radial_segments = 14
			_meshes["cover"] = cover
		_part(self, _meshes["cover"], blanket, Vector3(at.x, c.y + 1.0, at.y)).visibility_range_end = SHOW_DIST
	var trolley := _at(c, 3.0, gw - 0.45)
	var tr := _part(self, _box_mesh(Vector3(1.0, 0.9, 0.6)), _mat("trolley", Color(0.7, 0.1, 0.1), 0.4, 0.4), Vector3(trolley.x, c.y + 0.45, trolley.y))
	tr.rotation.y = -c.dir.angle()
	tr.visibility_range_end = SHOW_DIST
	c.rig = _at(c, -1.2, gw - 0.3)
	var rig := _part(self, _box_mesh(Vector3(0.6, 2.0, 0.6)), _mat("rig", Color(0.85, 0.85, 0.82), 0.5, 0.3), Vector3(c.rig.x, c.y + 1.0, c.rig.y))
	rig.visibility_range_end = SHOW_DIST
	var hose_mesh := _box_mesh(Vector3(1.0, 0.07, 0.07))
	c.hose = _part(self, hose_mesh, _mat("dark", Color.BLACK), Vector3.ZERO)
	c.hose.visible = false
	c.hose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# strategist on the pit wall, opposite the garage
	var wall := _at(c, 0.0, -(track.pit_width * 0.5 + 0.6) - track.pit_width * 0.25 - 0.1)
	var s := _person(c, suit, helmet)
	s.pos = wall + c.out * 0.55
	s.target = s.pos
	s.face = (-c.out).angle() + PI
	s.target_face = s.face
	s.pose = Pose.SIT
	s.speed = 0.0
	var stool := _part(self, _box_mesh(Vector3(0.5, 0.5, 0.5)), _mat("stool", Color(0.2, 0.2, 0.22)), Vector3(s.pos.x, c.y + 0.25, s.pos.y))
	stool.visibility_range_end = SHOW_DIST
	var screen := _part(self, _box_mesh(Vector3(0.1, 0.45, 0.8)), _mat("screen", Color(0.05, 0.06, 0.08), 0.1, 0.2),
		Vector3(wall.x, c.y + 1.35, wall.y))
	screen.rotation.y = -c.out.angle()
	screen.visibility_range_end = SHOW_DIST
	c.people.append(s)
	c.home.append([s.pos, s.face])
	# step the crew once so everyone starts in their pose
	for p in c.people:
		_move(p, 0.5)


## Number of people in the pit lane (for tests).
func people_count() -> int:
	var n := 0
	for k in crews:
		n += (crews[k] as Crew).people.size()
	return n
