class_name PitCrews
extends Node3D
## The people of the pit lane. Every team in the race has a crew at its
## garage in team colours: they hang about in front of the garage, step out
## to their marks when their car is called in, and do the stop for real, the
## Le Mans way, following the stop's crew timeline (PitRules.crew_timeline,
## in work["crew"]): the car controller waves the car onto its marks with
## the lollipop, the refueller carries the hose over from the rig and plugs
## it in (with the fire extinguisher and cut-off valve attendants beside the
## rig) while a mechanic wipes the windscreen, a mechanic plugs the air lance
## in and the car rises on its air jacks, then on each side a gun man and a
## wheel man change the wheels, front then rear: the gun man kneels and guns
## the nut off, the wheel man pulls the old wheel, puts it down, picks up the
## new one laid out beside the car and offers it up, the gun man does it up.
## The cockpit helper opens the door for a driver change, mechanics work on
## the nose and tail for repairs, the lance comes out, the car drops and the
## lollipop turns green to send it away. Between stops mechanics wander
## between the garage and the apron, and a strategist sits on the pit wall.
## Tyre stacks (dry, intermediate, wet) under blankets, a trolley with the
## spare wheel guns and a fuel rig stand at each garage.
##
## The people are jointed figures (hips, knees, shoulders, elbows) in race
## suits with helmets, gloves and boots, who carry what they work with: the
## wheels in both arms, the wheel gun in the right hand, the fuel hose, the
## windscreen cloth, the lollipop, the extinguisher.
##
## Players doing crew jobs (ui PitCrewGame) drive their own crew member
## (drive_member) and say where the things they put down are (set_props).
##
## Purely visual: the race scene tells it what each car's stop is doing
## (set_stop) and it never changes the race.

const RUN_SPEED := 4.2          ## m/s, crew jogging to their marks
const WALK_SPEED := 1.4
const SHOW_DIST := 450.0        ## camera distance (m) beyond which people hide

enum Stop { NONE, COMING, SERVICE, LEAVING }
enum Pose { STAND, KNEEL, CROUCH, LEAN, SIGNAL, CARRY, SIT, GUN, WIPE, HOSE }
## What a crew member has in their hands.
enum Carry { NONE, TYRE, GUN, HOSE, CLOTH, LANCE, LOLLIPOP, EXTINGUISHER }

## Roles in the stop crew (index into a crew's members).
const LOLLIPOP := 0      ## the car controller
const LANCE := 1         ## air lance: the car up on its air jacks and down again
const GUN_L := 2         ## gun man down the left side (front left, then rear left)
const GUN_R := 3         ## and down the right side
const WHEEL_L := 4       ## wheel man down the left side (old wheel off, new one on)
const WHEEL_R := 5
const FUEL := 6          ## the refueller
const EXTINGUISHER := 7  ## fire extinguisher attendant, beside the refueller
const VALVE := 8         ## cut-off valve attendant, at the rig
const COCKPIT := 9       ## cockpit helper (driver changes)
const WANDER_A := 10     ## mechanics: repairs, or wandering between stops
const WANDER_B := 11
const SCREEN := 12       ## cleans the windscreen while the fuel goes in
const CREW_SIZE := 13
## The crew member who does each of the pit crew game's jobs (PitRules.JOBS).
const JOB_MEMBER := {"fuel": FUEL, "screen": SCREEN, "lance": LANCE, "wheel_l": WHEEL_L, "gun_l": GUN_L,
	"wheel_r": WHEEL_R, "gun_r": GUN_R}
## Tyre stacks at the garage, by kind: dry, intermediate, wet (blanket colours).
const STACK_KINDS := ["dry", "intermediate", "wet"]
const STACK_COLOURS := [Color(0.85, 0.12, 0.1), Color(0.15, 0.7, 0.25), Color(0.15, 0.4, 0.9)]

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
	var upper: Node3D     ## the torso, leans forward
	var leg_l: Node3D     ## hips
	var leg_r: Node3D
	var knee_l: Node3D
	var knee_r: Node3D
	var arm_l: Node3D     ## shoulders (swing forward / back)
	var arm_r: Node3D
	var elbow_l: Node3D
	var elbow_r: Node3D
	var head: Node3D
	var items: Dictionary = {}   ## Carry -> Node3D held in the hands
	var pos := Vector2.ZERO
	var face := 0.0
	var target := Vector2.ZERO
	var target_face := 0.0
	var pose := 0
	var carry := 0
	var speed := 4.2
	var walk := 0.0
	var fidget := 0.0
	var next_wander := 0.0
	var marker: MeshInstance3D   ## ring on the ground under a player's crew member


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
	var new_tyres: Array = []     ## the new wheels laid out by each corner (Node3D x4)
	var old_tyres: Array = []     ## the old wheels put down (x4)
	var guns: Array = []          ## a wheel gun lying on the ground, each side (x2)
	var hose: MeshInstance3D
	var rig := Vector2.ZERO       ## fuel rig, where the hose comes from
	var lolly: MeshInstance3D     ## lollipop disc (red = wait, green = go)
	var state := 0
	var elapsed := 0.0
	var work := {}
	var dims := {}
	## Players driving crew members: member index -> [pos, face, pose, carry, marker colour].
	var driven := {}
	## Where players have put things (set_props), overriding the timeline.
	var props := {}


func setup(p_tv: TrackView) -> void:
	name = "PitCrews"
	tv = p_tv
	track = tv.track
	_rng.seed = 99


# --- Where things are in a box ----------------------------------------------------

## A box's measurements for a car (crew_spot): the car's front / rear from its
## centre, axles, half track, the garage front and the fuel rig.
static func crew_dims(def: CarDefinition, p_track: TrackData) -> Dictionary:
	var d := {"front": 2.3, "rear": 2.3, "axle_f": 1.4, "axle_r": 1.4, "tw": 0.85, "len": 4.6}
	if def:
		d["front"] = def.cg_to_front + def.length * 0.22
		d["rear"] = def.length - float(d["front"])
		d["tw"] = def.track_width * 0.5
		d["axle_f"] = def.cg_to_front
		d["axle_r"] = def.wheelbase - def.cg_to_front
		d["len"] = def.length
	var pw := p_track.pit_width if p_track else 12.0
	d["gw"] = pw * 0.5 + 3.0 - pw * 0.25   # garage front, from the box centre
	return d


## Where something is in a box: [ground spot, facing]. frame: {pos, dir (along
## the lane), out (towards the garage)}; dims: crew_dims. Kinds (idx):
##   "wheel" (0-3) where a gun / wheel man works on a wheel; "new_tyre" (0-3)
##   where its new wheel is laid out; "old_tyre" (0-3) where the AI puts the
##   old one; "gun" (side 0 left / 1 right) where a wheel gun is laid out;
##   "wait" (side) where a side's crew wait for the car; "filler" the fuel
##   filler (the refueller stands here); "rig" the fuel rig; "screen" the
##   windscreen; "lance" the air lance socket; "stack" (0 dry, 1 inter, 2 wet)
##   the garage's tyre stacks; "trolley" the spare wheel guns.
## The right side of the car (wheels 1 and 3) faces the garage.
static func crew_spot(frame: Dictionary, dims: Dictionary, kind: String, idx := 0) -> Array:
	var pos: Vector2 = frame.get("pos", Vector2.ZERO)
	var dir: Vector2 = frame.get("dir", Vector2.RIGHT)
	var out: Vector2 = frame.get("out", Vector2.UP)
	var tw := float(dims.get("tw", 0.85))
	var gw := float(dims.get("gw", 6.0))
	var to_car := (-out).angle()
	var from_out := out.angle()
	var at := func(along: float, across: float) -> Vector2: return pos + dir * along + out * across
	var s := 1.0 if idx % 2 == 1 else -1.0
	var front := idx < 2
	var x := float(dims.get("axle_f", 1.4)) if front else -float(dims.get("axle_r", 1.4))
	match kind:
		"wheel":
			return [at.call(x, s * (tw + 0.75)), to_car if s > 0.0 else from_out]
		"new_tyre":
			return [at.call(x + (0.95 if front else -0.95), s * (tw + 1.25)), to_car if s > 0.0 else from_out]
		"old_tyre":
			return [at.call(x + (0.3 if front else -0.3), s * (tw + 2.05)), to_car if s > 0.0 else from_out]
		"gun":
			var gs := 1.0 if idx == 1 else -1.0
			return [at.call(0.15, gs * (tw + 1.35)), to_car if gs > 0.0 else from_out]
		"wait":
			var ws := 1.0 if idx == 1 else -1.0
			return [at.call(float(dims.get("axle_f", 1.4)) + 1.3, ws * (tw + 1.0)), to_car if ws > 0.0 else from_out]
		"filler":
			return [at.call(-0.5, tw + 0.85), to_car]
		"rig":
			return [at.call(-1.2, gw - 0.3) + out * -0.6, to_car]
		"screen":
			return [at.call(float(dims.get("front", 2.3)) + 0.45, -0.25), dir.angle() + PI]
		"lance":
			return [at.call(-float(dims.get("rear", 2.3)) + 0.35, tw + 0.75), to_car]
		"stack":
			return [at.call(-3.6 + idx * 0.85, gw - 0.35) - out * 0.55, from_out]
		"trolley":
			return [at.call(3.0, gw - 0.45) - out * 0.6, from_out]
	return [pos, 0.0]


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
	c.dims = crew_dims(def, track)
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
## work being done {tyre_s, fuel_s, repair_s, total_s, crew} (seconds; 0 = none).
func set_stop(car: int, state: int, elapsed: float, work: Dictionary) -> void:
	if not _car_box.has(car) or not crews.has(_car_box[car]):
		return
	var c: Crew = crews[_car_box[car]]
	# Two cars in one box: whichever is actually stopping wins.
	if state == Stop.NONE and c.state != Stop.NONE and c.work.get("car", -1) != car:
		return
	if state == Stop.NONE and c.state != Stop.NONE:
		c.props = {}
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
	var rise := clampf((e - float(up[0])) / maxf(float(up[1]) - float(up[0]), 0.05), 0.0, 1.0) if not is_inf(float(up[0])) else 0.0
	var fall := clampf((float(down[1]) - e) / maxf(float(down[1]) - float(down[0]), 0.05), 0.0, 1.0) if not is_inf(float(down[0])) else 1.0
	return 0.075 * minf(rise, fall)


## Which wheels are off the car right now: bits 1 front left, 2 front
## right, 4 rear left, 8 rear right.
func wheels_off_mask(car: int) -> int:
	var c := _crew_of(car)
	if c == null or c.state != Stop.SERVICE:
		return 0
	var mask := 0
	for job in _jobs(c):
		if c.elapsed > float(job.get("wheel_off", INF)) and c.elapsed < float(job.get("wheel_on", INF)):
			mask |= 1 << int(job["wheel"])
	return mask


func wheels_off(car: int) -> bool:
	return wheels_off_mask(car) != 0


# --- Players doing crew jobs (ui PitCrewGame) --------------------------------------

## Car's crew (by its box), whether or not it's stopping now.
func _crew_for(car: int) -> Crew:
	return crews.get(_car_box.get(car, -1)) if _car_box.has(car) else null


## A player is doing this crew job (PitRules.JOBS) for car: draw their crew
## member here (pos: ground metres, face: radians, pose: Pose, carry: Carry),
## with a ring of this colour under them. pos = null: the AI has it again.
func drive_member(car: int, job: String, pos, face := 0.0, pose := Pose.STAND, carry := Carry.NONE,
		ring := Color(1.0, 0.85, 0.2)) -> void:
	var c := _crew_for(car)
	if c == null or not JOB_MEMBER.has(job):
		return
	var k: int = JOB_MEMBER[job]
	if pos == null:
		c.driven.erase(k)
	else:
		c.driven[k] = [pos, face, pose, carry, ring]


## Where players have put things in car's box, overriding where the crew
## timeline would have them (keys left out keep the timeline's):
##   new_tyres: {wheel: Vector2 laid out at, or null (picked up / not out)}
##   new_kinds: {wheel: 0 dry / 1 inter / 2 wet} (the tyre's band colour)
##   old_tyres: {wheel: Vector2 put down at}
##   guns: {side: Vector2 lying at, or null (in someone's hands / not out)}
##   hose: "rig", "hand" or "car"
func set_props(car: int, props: Dictionary) -> void:
	var c := _crew_for(car)
	if c == null:
		return
	for k in props:
		if props[k] is Dictionary and c.props.get(k) is Dictionary:
			(c.props[k] as Dictionary).merge(props[k], true)
		else:
			c.props[k] = props[k].duplicate() if props[k] is Dictionary else props[k]


## Where something is in car's box (see crew_spot): [spot, facing], [] without a crew.
func spot(car: int, kind: String, idx := 0) -> Array:
	var c := _crew_for(car)
	if c == null:
		return []
	return crew_spot(box_frame(car), c.dims, kind, idx)


## Where a gun / wheel man works on a wheel (0 front left .. 3 rear right) of
## car, round where it is now in its box: [spot, facing]. [] without a crew.
func wheel_spot(car: int, wheel: int) -> Array:
	return spot(car, "wheel", wheel)


## The box car stops in: {pos, dir (along the lane), out (towards the garage)}.
func box_frame(car: int) -> Dictionary:
	var c := _crew_for(car)
	if c == null:
		return {}
	return {"pos": c.pos, "dir": c.dir, "out": c.out}


## The box's measurements for car's crew (crew_dims).
func box_dims(car: int) -> Dictionary:
	var c := _crew_for(car)
	return c.dims if c else {}


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


## Every wheel job, both sides: [{wheel, start, nut_off, wheel_off, wheel_on, on, side}].
func _jobs(c: Crew) -> Array:
	var out := []
	var tyres: Array = _tl(c).get("tyres", _tl(c).get("guns", []))
	for g in tyres.size():
		for job in tyres[g]:
			var j: Dictionary = (job as Dictionary).duplicate()
			j["side"] = g
			if not j.has("wheel_off"):   # an older timeline: shares of the job
				var d := float(j["on"]) - float(j["off"])
				j["start"] = float(j["off"])
				j["nut_off"] = float(j["off"]) + d * 0.18
				j["wheel_off"] = float(j["off"]) + d * 0.3
				j["wheel_on"] = float(j["off"]) + d * 0.7
			out.append(j)
	return out


func _side_jobs(c: Crew, g: int) -> Array:
	return _jobs(c).filter(func(j): return int(j["side"]) == g)


## The car goes up on its jacks (tyres or repairs to do).
func _lifts(c: Crew) -> bool:
	return float(c.work.get("tyre_s", 0.0)) > 0.0 or float(c.work.get("repair_s", 0.0)) > 0.0


func _in(e: float, span) -> bool:
	return span is Array and (span as Array).size() >= 2 and e >= float(span[0]) and e <= float(span[-1])


func _sp(c: Crew, kind: String, idx := 0) -> Array:
	return crew_spot({"pos": c.pos, "dir": c.dir, "out": c.out}, c.dims, kind, idx)


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
		p.marker.visible = false
		if c.driven.has(i):
			var d: Array = c.driven[i]
			p.target = d[0]
			p.target_face = d[1]
			p.pose = d[2]
			p.carry = d[3]
			p.speed = RUN_SPEED * 3.0   # keeps right with the player's stick
			p.marker.visible = true
			(p.marker.material_override as StandardMaterial3D).albedo_color = Color(d[4], 0.85)
			continue
		p.carry = _default_carry(i)
		if not active:
			p.speed = WALK_SPEED if c.state == Stop.NONE else RUN_SPEED * 0.6
			if i >= WANDER_A and i <= WANDER_B or (c.filler and i % 3 == 1):
				_wander(c, p, home)
			else:
				p.target = home[0]
				p.target_face = home[1]
			p.pose = Pose.STAND
			if i == LOLLIPOP and c.state == Stop.LEAVING:
				p.pose = Pose.SIGNAL
			if i == GUN_L or i == GUN_R or i == FUEL or i == SCREEN:
				p.carry = Carry.NONE
			continue
		p.speed = RUN_SPEED * (1.5 if i == WHEEL_L or i == WHEEL_R else 1.0)
		var st := _station(c, i, tl)
		p.target = st[0]
		p.target_face = st[1]
		p.pose = st[2]
		if st.size() > 3:
			p.carry = st[3]
	# lollipop: red while working, green to go
	if c.lolly:
		var down_end := float((tl.get("down", [1e9, 1e9]) as Array)[-1])
		var go: bool = c.state == Stop.LEAVING or (c.state == Stop.SERVICE and e > down_end)
		(c.lolly.material_override as StandardMaterial3D).albedo_color = Color(0.1, 0.8, 0.2) if go else Color(0.85, 0.08, 0.06)


func _default_carry(i: int) -> int:
	match i:
		LOLLIPOP: return Carry.LOLLIPOP
		EXTINGUISHER: return Carry.EXTINGUISHER
		GUN_L, GUN_R: return Carry.GUN
		SCREEN: return Carry.CLOTH
	return Carry.NONE


## A crew member's mark around the car in the box: [spot, facing, pose(, carry)].
func _station(c: Crew, i: int, tl: Dictionary) -> Array:
	var e := c.elapsed
	var serving := c.state == Stop.SERVICE
	var tw := float(c.dims["tw"])
	var into := c.dir.angle()       # facing along the lane
	var to_car := (-c.out).angle()  # facing the car from the garage side
	var from_out := c.out.angle()   # facing the car from the far side
	var fuel: Array = tl.get("fuel", [])
	var fuel_on: bool = serving and fuel.size() >= 4 and e >= float(fuel[0]) and e <= float(fuel[3])
	var repairing: bool = serving and _in(e, tl.get("repair", []))
	var front := float(c.dims["front"])
	var rear := float(c.dims["rear"])
	match i:
		LOLLIPOP:
			return [_at(c, front + 2.2, 0.0), into + PI, Pose.SIGNAL]
		LANCE:
			# plugs the air lance in at the back on the garage side, holds it, pulls it out
			var sock := _sp(c, "lance")
			if not _lifts(c):
				return [_at(c, -rear - 0.6, tw + 2.4), to_car, Pose.STAND]
			var up: Array = tl.get("up", [0.0, 0.0])
			var down: Array = tl.get("down", [1e9, 1e9])
			var plugging: bool = serving and (_in(e, [float(up[0]) - 0.3, up[1]]) or _in(e, down))
			var lance_in: bool = serving and e >= float(up[0]) and e < float(down[1])
			return [sock[0], sock[1], Pose.CROUCH if plugging else Pose.STAND, Carry.LANCE if not lance_in or plugging else Carry.NONE]
		GUN_L, GUN_R:
			var g := i - GUN_L
			var jobs := _side_jobs(c, g)
			var gun_at := _sp(c, "gun", g)
			if jobs.is_empty():
				return [_at(c, 0.6 if g == 0 else -0.6, tw + 2.8), to_car, Pose.STAND, Carry.NONE]
			# the wheel being done now, or the next one, or the last one done
			var job: Dictionary = jobs[0]
			for j in jobs:
				job = j
				if e < float(j["on"]):
					break
			var ws := _sp(c, "wheel", int(job["wheel"]))
			var back: Vector2 = ws[0] + (ws[0] - c.pos).normalized() * 0.55
			if not serving:
				return [_sp(c, "wait", g)[0], ws[1], Pose.GUN, Carry.GUN]
			if e > float(jobs[-1]["on"]):
				return [gun_at[0] + c.dir * 0.6, gun_at[1], Pose.STAND, Carry.NONE]   # gun put down
			if e < float(job["start"]):
				return [ws[0], ws[1], Pose.GUN, Carry.GUN]
			if e < float(job["nut_off"]) or (e >= float(job["wheel_on"]) and e < float(job["on"])):
				return [ws[0], ws[1], Pose.KNEEL, Carry.GUN]
			return [back, ws[1], Pose.GUN, Carry.GUN]
		WHEEL_L, WHEEL_R:
			var g := i - WHEEL_L
			var jobs := _side_jobs(c, g)
			if jobs.is_empty():
				return [_at(c, 1.2 if g == 0 else -1.2, tw + 2.8), to_car, Pose.STAND]
			var job: Dictionary = jobs[0]
			for j in jobs:
				job = j
				if e < float(j["wheel_on"]):
					break
			var w := int(job["wheel"])
			var ws := _sp(c, "wheel", w)
			var beside: Vector2 = ws[0] + c.dir * (0.55 if w < 2 else -0.55)
			if not serving or e < float(job["wheel_off"]) - 0.25:
				return [beside, ws[1], Pose.STAND]
			if e < float(job["wheel_off"]):
				return [ws[0], ws[1], Pose.CROUCH]
			var won := float(job["wheel_on"])
			if e >= won:
				return [beside, ws[1], Pose.STAND]
			var off := float(job["wheel_off"])
			var f := (e - off) / maxf(won - off, 0.1) if not is_inf(won) else 0.0
			if is_inf(won):
				return [_sp(c, "old_tyre", w)[0], ws[1], Pose.CARRY, Carry.TYRE]
			if f < 0.35:
				return [_sp(c, "old_tyre", w)[0], ws[1], Pose.CARRY, Carry.TYRE]   # old wheel out
			if f < 0.55:
				return [_sp(c, "new_tyre", w)[0], ws[1], Pose.CROUCH]               # pick up the new one
			if f < 0.85:
				return [ws[0], ws[1], Pose.CARRY, Carry.TYRE]                       # offer it up
			return [ws[0], ws[1], Pose.CROUCH]
		FUEL:
			var fs := _sp(c, "filler")
			if fuel.is_empty():
				return [_at(c, -0.4, tw + 3.4), to_car, Pose.STAND]
			if fuel_on:
				return [fs[0], fs[1], Pose.LEAN, Carry.HOSE]
			if serving and e > float(fuel[-1]):
				return [_sp(c, "rig")[0], to_car, Pose.STAND]
			return [fs[0], fs[1], Pose.HOSE, Carry.HOSE]
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
		SCREEN:
			var sc := _sp(c, "screen")
			var span: Array = tl.get("screen", [])
			if serving and _in(e, span):
				return [sc[0], sc[1], Pose.WIPE, Carry.CLOTH]
			return [_at(c, front + 0.8, -(tw + 1.0)), into + PI, Pose.STAND, Carry.CLOTH]
		_:
			# spare mechanics help with repairs, or watch from the garage
			if repairing:
				return [_at(c, front + 0.5 if i == WANDER_A else -rear - 0.5, -0.4 if i == WANDER_A else 0.6),
					into + PI if i == WANDER_A else into, Pose.CROUCH]
			return [_at(c, 2.0 if i == WANDER_A else -2.0, tw + 3.6), to_car, Pose.STAND]


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


## Joint angles for a pose (radians; + swings a limb forward / bends a joint):
## [hips drop, lean, leg_l, leg_r, knee_l, knee_r, arm_l, arm_r, elbow_l, elbow_r].
func _pose_angles(p: Person, pose: int, moving: bool) -> Array:
	var swing := sin(p.walk) * (0.75 if p.speed > 2.0 else 0.45) if moving else 0.0
	var knee_l := maxf(0.0, -sin(p.walk - 0.6)) * (1.1 if p.speed > 2.0 else 0.6) if moving else 0.04
	var knee_r := maxf(0.0, sin(p.walk - 0.6)) * (1.1 if p.speed > 2.0 else 0.6) if moving else 0.04
	var a := [0.0, 0.06 if moving and p.speed > 2.0 else 0.0, swing, -swing, knee_l, knee_r,
		-swing * 0.8, swing * 0.8, 0.35 if moving else 0.12, 0.35 if moving else 0.12]
	var f := p.fidget
	match pose:
		Pose.STAND:
			a[6] = float(a[6]) + 0.06 + sin(f * 1.3) * 0.04
			a[7] = float(a[7]) + 0.06 + sin(f * 1.1 + 1.0) * 0.04
		Pose.KNEEL:
			a = [-0.5, 0.35, 1.5, -0.1, 1.55, 1.75, 1.15, 1.25 + sin(f * 41.0) * 0.06, 0.6, 0.45]
		Pose.CROUCH:
			a = [-0.35, 0.75, 1.0, 0.5, 1.6, 1.2, 1.1, 1.1, 0.4, 0.4]
		Pose.LEAN:
			a[1] = 0.3
			a[6] = 0.95
			a[7] = 0.85
			a[8] = 0.5
			a[9] = 0.5
		Pose.SIGNAL:
			a[6] = 1.45
			a[8] = 0.1
			a[7] = 0.1
		Pose.CARRY:
			# a wheel held in front in both arms
			a[1] = -0.08
			a[6] = 0.75
			a[7] = 0.75
			a[8] = 1.2
			a[9] = 1.2
		Pose.GUN:
			a[7] = 0.6
			a[9] = 0.9
		Pose.WIPE:
			a[1] = 0.55
			a[6] = 1.3 + sin(f * 9.0) * 0.35
			a[8] = 0.3
			a[7] = 0.9
			a[9] = 0.5
		Pose.HOSE:
			a[6] = 0.55
			a[7] = 0.7
			a[8] = 0.9
			a[9] = 0.8
		Pose.SIT:
			a = [-0.42, 0.0, 1.5, 1.5, 1.5, 1.5, 0.7 + sin(f * 0.7) * 0.1, 0.5, 0.9, 0.6]
	return a


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
	# Walking keeps the arms of a pose that holds something (a wheel, a gun, a hose).
	var pose := p.pose
	if moving and not (pose in [Pose.CARRY, Pose.GUN, Pose.HOSE]):
		pose = Pose.STAND
	var a := _pose_angles(p, pose, moving)
	if moving and pose != Pose.STAND:
		var w := _pose_angles(p, Pose.STAND, true)
		for k in [0, 1, 2, 3, 4, 5]:
			a[k] = w[k]
	var k := 1.0 - exp(-14.0 * delta)
	p.body.position.y = lerpf(p.body.position.y, a[0], k)
	p.upper.rotation.z = lerpf(p.upper.rotation.z, -float(a[1]), k)
	p.leg_l.rotation.z = lerpf(p.leg_l.rotation.z, a[2], k)
	p.leg_r.rotation.z = lerpf(p.leg_r.rotation.z, a[3], k)
	p.knee_l.rotation.z = lerpf(p.knee_l.rotation.z, -float(a[4]), k)
	p.knee_r.rotation.z = lerpf(p.knee_r.rotation.z, -float(a[5]), k)
	p.arm_l.rotation.z = lerpf(p.arm_l.rotation.z, a[6], k)
	p.arm_r.rotation.z = lerpf(p.arm_r.rotation.z, a[7], k)
	p.elbow_l.rotation.z = lerpf(p.elbow_l.rotation.z, a[8], k)
	p.elbow_r.rotation.z = lerpf(p.elbow_r.rotation.z, a[9], k)
	for item in p.items:
		(p.items[item] as Node3D).visible = item == p.carry


## The wheels laid out and put down, the guns on the ground, the fuel hose.
func _props(c: Crew) -> void:
	var tl := _tl(c)
	var e := c.elapsed
	var active := c.state == Stop.COMING or c.state == Stop.SERVICE
	var serving := c.state == Stop.SERVICE
	var jobs := _jobs(c) if active else []
	var by_wheel := {}
	for j in jobs:
		by_wheel[int(j["wheel"])] = j
	var pnew: Dictionary = c.props.get("new_tyres", {})
	var pkind: Dictionary = c.props.get("new_kinds", {})
	var pold: Dictionary = c.props.get("old_tyres", {})
	var kind := _kind_of(str(c.work.get("tyre", "")))
	for w in 4:
		var nt: Node3D = c.new_tyres[w]
		var ot: Node3D = c.old_tyres[w]
		# New wheel: laid out by the corner until the wheel man picks it up.
		var at = null
		if pnew.has(w):
			at = pnew[w]
		elif by_wheel.has(w):
			var j: Dictionary = by_wheel[w]
			var off := float(j["wheel_off"])
			var won := float(j["wheel_on"])
			var picked := serving and not is_inf(off) and e > off + (won - off) * 0.5 if not is_inf(won) else false
			if bool(j.get("wheel_player", false)):
				picked = serving and e >= won   # a player's: the props say when they pick it up
			var ready := float(j.get("tyre_ready", 0.0))
			if not picked and (not serving or e >= ready) and (is_inf(ready) == false):
				at = _sp(c, "new_tyre", w)[0]
		nt.visible = at != null
		if at != null:
			_place_tyre(c, nt, at, int(pkind.get(w, kind)))
		# Old wheel: on the ground from when it's put down until the car leaves.
		var oat = null
		if pold.has(w):
			oat = pold[w]
		elif serving and by_wheel.has(w):
			var j: Dictionary = by_wheel[w]
			var off := float(j["wheel_off"])
			var won := float(j["wheel_on"])
			if not bool(j.get("wheel_player", false)) and not is_inf(off) and e > off + (won - off) * 0.35:
				oat = _sp(c, "old_tyre", w)[0]
		ot.visible = oat != null and (serving or pold.has(w))
		if oat != null:
			_place_tyre(c, ot, oat, -1)
	# Wheel guns lying on the ground (when their gun man isn't holding one).
	var pguns: Dictionary = c.props.get("guns", {})
	for g in 2:
		var gn: Node3D = c.guns[g]
		var at = null
		if pguns.has(g):
			at = pguns[g]
		elif active:
			var holder: Person = c.people[GUN_L + g]
			if holder.carry != Carry.GUN and not _side_jobs(c, g).is_empty():
				at = _sp(c, "gun", g)[0]
		gn.visible = at != null
		if at != null:
			gn.position = Vector3((at as Vector2).x, c.y + 0.07, (at as Vector2).y)
			gn.rotation.y = -c.dir.angle()
	# Hose from the rig to the refueller's hands, or to the car's filler.
	var f: Person = c.people[FUEL]
	var mode := str(c.props.get("hose", ""))
	var fuel: Array = tl.get("fuel", [])
	if mode == "":
		mode = "rig"
		if f.carry == Carry.HOSE:
			mode = "car" if serving and fuel.size() >= 4 and e >= float(fuel[0]) and e <= float(fuel[3]) else "hand"
	var a := Vector3(c.rig.x, c.y + 1.1, c.rig.y)
	var b := a + Vector3(0, -0.6, 0)
	if mode == "hand":
		var hand := f.pos + Vector2.from_angle(f.face) * 0.45
		b = Vector3(hand.x, c.y + 1.0, hand.y)
	elif mode == "car":
		var fl: Vector2 = _sp(c, "filler")[0] - c.out * 0.45
		b = Vector3(fl.x, c.y + 0.95, fl.y)
	var d := b - a
	var len := d.length()
	c.hose.visible = len > 0.3 and active and (mode != "rig" or not fuel.is_empty())
	if c.hose.visible:
		var xa := d / len
		var ya := xa.cross(Vector3.UP).normalized()
		if ya.length_squared() < 0.5:
			ya = Vector3.FORWARD
		var za := xa.cross(ya)
		c.hose.transform = Transform3D(Basis(xa * len, ya, za), (a + b) * 0.5)


## Stack index for a compound id: 0 dry, 1 intermediate, 2 wet.
static func _kind_of(compound: String) -> int:
	if compound.contains("inter"):
		return 1
	if compound.contains("wet"):
		return 2
	return 0


func _place_tyre(c: Crew, t: Node3D, at: Vector2, kind: int) -> void:
	t.position = Vector3(at.x, c.y + 0.16, at.y)
	var band := t.get_node_or_null("Band") as MeshInstance3D
	if band:
		band.visible = kind >= 0
		if kind >= 0:
			band.material_override = _mat("band_%d" % kind, STACK_COLOURS[kind], 0.6)


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


func _capsule(r: float, h: float) -> CapsuleMesh:
	var key := "c_%.3f_%.3f" % [r, h]
	if not _meshes.has(key):
		var cm := CapsuleMesh.new()
		cm.radius = r
		cm.height = h
		cm.radial_segments = 8
		cm.rings = 2
		_meshes[key] = cm
	return _meshes[key]


func _sphere(r: float) -> SphereMesh:
	var key := "s_%.3f" % r
	if not _meshes.has(key):
		var sm := SphereMesh.new()
		sm.radius = r
		sm.height = r * 2.0
		sm.radial_segments = 10
		sm.rings = 6
		_meshes[key] = sm
	return _meshes[key]


func _part(parent: Node3D, mesh: Mesh, mat: Material, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # thousands of little meshes: no shadows
	mi.visibility_range_end = SHOW_DIST
	parent.add_child(mi)
	return mi


func _joint(parent: Node3D, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = at
	parent.add_child(n)
	return n


func _tyre_mesh() -> CylinderMesh:
	if not _meshes.has("tyre"):
		var cy := CylinderMesh.new()
		cy.top_radius = 0.34
		cy.bottom_radius = 0.34
		cy.height = 0.3
		cy.radial_segments = 14
		_meshes["tyre"] = cy
	return _meshes["tyre"]


## A wheel: tyre, rim and (laid-out new ones) a coloured compound band.
func _wheel_prop(parent: Node3D, upright: bool) -> Node3D:
	var n := Node3D.new()
	parent.add_child(n)
	var t := _part(n, _tyre_mesh(), _mat("rubber", Color(0.05, 0.05, 0.05), 0.85), Vector3.ZERO)
	if not _meshes.has("rim"):
		var rim := CylinderMesh.new()
		rim.top_radius = 0.22
		rim.bottom_radius = 0.22
		rim.height = 0.31
		rim.radial_segments = 12
		_meshes["rim"] = rim
		var band := CylinderMesh.new()
		band.top_radius = 0.345
		band.bottom_radius = 0.345
		band.height = 0.05
		band.radial_segments = 14
		_meshes["band"] = band
	var r := _part(n, _meshes["rim"], _mat("rim", Color(0.55, 0.56, 0.6), 0.3, 0.7), Vector3.ZERO)
	var b := _part(n, _meshes["band"], _mat("band_0", STACK_COLOURS[0], 0.6), Vector3(0, 0.13, 0))
	b.name = "Band"
	if upright:
		for m in [t, r, b]:
			m.rotation.x = PI * 0.5
	return n


func _gun_prop(parent: Node3D) -> Node3D:
	var n := Node3D.new()
	parent.add_child(n)
	var metal := _mat("gun", Color(0.72, 0.72, 0.76), 0.3, 0.6)
	_part(n, _box_mesh(Vector3(0.3, 0.11, 0.11)), metal, Vector3.ZERO)
	_part(n, _box_mesh(Vector3(0.06, 0.16, 0.07)), _mat("gun_grip", Color(0.9, 0.75, 0.1), 0.5), Vector3(-0.08, -0.1, 0))
	_part(n, _box_mesh(Vector3(0.08, 0.08, 0.08)), _mat("dark", Color(0.05, 0.05, 0.05)), Vector3(0.18, 0, 0))
	return n


## A crew member. holds: the Carry items they ever have in their hands.
func _person(c: Crew, suit: Color, helmet: Color, holds: Array = []) -> Person:
	var p := Person.new()
	p.root = Node3D.new()
	add_child(p.root)
	p.root.position.y = c.y
	p.body = Node3D.new()
	p.root.add_child(p.body)
	var suit_m := _mat("suit_%s" % suit.to_html(), suit, 0.8)
	var dark_m := _mat("suit_dark_%s" % suit.to_html(), suit.darkened(0.45), 0.85)
	var stripe := _mat("stripe", Color(0.95, 0.95, 0.9), 0.4, 0.2)
	var helm := _mat("helm_%s" % helmet.to_html(), helmet, 0.25, 0.1)
	var visor := _mat("visor", Color(0.03, 0.04, 0.06), 0.05, 0.3)
	var glove := _mat("glove", Color(0.08, 0.08, 0.09), 0.7)
	var boot := _mat("boot", Color(0.06, 0.06, 0.07), 0.6)
	# Legs: hip -> thigh -> knee -> shin -> boot. +x is forward (the way they face).
	for s in [-1.0, 1.0]:
		var hip := _joint(p.body, Vector3(0, 0.92, s * 0.11))
		_part(hip, _capsule(0.085, 0.5), dark_m, Vector3(0, -0.23, 0))
		var knee := _joint(hip, Vector3(0, -0.46, 0))
		_part(knee, _capsule(0.07, 0.48), dark_m, Vector3(0, -0.22, 0))
		_part(knee, _box_mesh(Vector3(0.24, 0.08, 0.11)), boot, Vector3(0.05, -0.44, 0))
		if s < 0.0:
			p.leg_l = hip
			p.knee_l = knee
		else:
			p.leg_r = hip
			p.knee_r = knee
	# Torso: race suit, reflective stripe, team-coloured shoulders.
	p.upper = _joint(p.body, Vector3(0, 0.92, 0))
	_part(p.upper, _box_mesh(Vector3(0.24, 0.2, 0.36)), dark_m, Vector3(0, 0.08, 0))
	_part(p.upper, _box_mesh(Vector3(0.26, 0.42, 0.44)), suit_m, Vector3(0, 0.36, 0))
	_part(p.upper, _box_mesh(Vector3(0.27, 0.05, 0.45)), stripe, Vector3(0, 0.3, 0))
	# Head: helmet with a visor.
	p.head = _joint(p.upper, Vector3(0, 0.62, 0))
	_part(p.head, _capsule(0.05, 0.12), dark_m, Vector3(0, 0.02, 0))
	_part(p.head, _sphere(0.15), helm, Vector3(0, 0.17, 0))
	_part(p.head, _box_mesh(Vector3(0.07, 0.09, 0.22)), visor, Vector3(0.12, 0.17, 0))
	# Arms: shoulder -> upper arm -> elbow -> forearm -> glove.
	for s in [-1.0, 1.0]:
		var sh := _joint(p.upper, Vector3(0, 0.53, s * 0.27))
		_part(sh, _capsule(0.06, 0.34), suit_m, Vector3(0, -0.15, 0))
		var el := _joint(sh, Vector3(0, -0.3, 0))
		_part(el, _capsule(0.055, 0.32), suit_m, Vector3(0, -0.14, 0))
		var hand := _joint(el, Vector3(0, -0.3, 0))
		_part(hand, _sphere(0.055), glove, Vector3.ZERO)
		if s < 0.0:
			p.arm_l = sh
			p.elbow_l = el
		else:
			p.arm_r = sh
			p.elbow_r = el
	# What they can hold. The right hand holds tools; a wheel sits in front of
	# the chest between both hands.
	var hand_r: Node3D = p.elbow_r.get_child(p.elbow_r.get_child_count() - 1)
	var hand_l: Node3D = p.elbow_l.get_child(p.elbow_l.get_child_count() - 1)
	if Carry.TYRE in holds:
		var tyre := _joint(p.upper, Vector3(0.42, 0.25, 0))
		_wheel_prop(tyre, true).get_node("Band").visible = false
		p.items[Carry.TYRE] = tyre
	if Carry.GUN in holds:
		var gun := _joint(hand_r, Vector3(0.05, -0.04, 0))
		_gun_prop(gun)
		p.items[Carry.GUN] = gun
	if Carry.HOSE in holds:
		var hose := _joint(hand_r, Vector3(0.1, -0.02, -0.12))
		_part(hose, _box_mesh(Vector3(0.36, 0.12, 0.12)), _mat("nozzle", Color(0.85, 0.85, 0.8), 0.4, 0.5), Vector3.ZERO)
		p.items[Carry.HOSE] = hose
	if Carry.CLOTH in holds:
		var cloth := _joint(hand_l, Vector3(0.04, -0.04, 0))
		_part(cloth, _box_mesh(Vector3(0.18, 0.03, 0.14)), _mat("cloth", Color(0.95, 0.95, 1.0), 0.9), Vector3.ZERO)
		p.items[Carry.CLOTH] = cloth
	if Carry.LANCE in holds:
		var lance := _joint(hand_r, Vector3(0.08, -0.04, 0))
		_part(lance, _box_mesh(Vector3(0.55, 0.06, 0.06)), _mat("lance", Color(0.75, 0.15, 0.1), 0.4, 0.4), Vector3(0.22, 0, 0))
		p.items[Carry.LANCE] = lance
	if Carry.EXTINGUISHER in holds:
		var ext := _joint(hand_r, Vector3(0, -0.2, 0))
		_part(ext, _capsule(0.08, 0.45), _mat("extinguisher", Color(0.85, 0.08, 0.06), 0.4, 0.2), Vector3.ZERO)
		p.items[Carry.EXTINGUISHER] = ext
	for k in p.items:
		(p.items[k] as Node3D).visible = false
	# A ring on the ground under a crew member a player drives.
	if not _meshes.has("ring"):
		var ring := TorusMesh.new()
		ring.inner_radius = 0.48
		ring.outer_radius = 0.62
		ring.rings = 20
		ring.ring_segments = 6
		_meshes["ring"] = ring
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.albedo_color = Color(1.0, 0.85, 0.2, 0.85)
	rm.no_depth_test = true
	rm.render_priority = 2
	p.marker = _part(p.root, _meshes["ring"], rm, Vector3(0, 0.08, 0))
	p.marker.scale = Vector3(1, 0.25, 1)
	p.marker.visible = false
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
	var gw := float(c.dims["gw"])
	# Who ever holds what (any job can be a player's, who may pick up a wheel or a gun).
	var holds := {LANCE: [Carry.LANCE, Carry.TYRE, Carry.GUN], GUN_L: [Carry.GUN, Carry.TYRE], GUN_R: [Carry.GUN, Carry.TYRE],
		WHEEL_L: [Carry.TYRE, Carry.GUN], WHEEL_R: [Carry.TYRE, Carry.GUN], FUEL: [Carry.HOSE], SCREEN: [Carry.CLOTH],
		EXTINGUISHER: [Carry.EXTINGUISHER]}
	for i in CREW_SIZE:
		var p := _person(c, suit, helmet, holds.get(i, []) if not c.filler else [])
		# home: two loose rows in front of the garage
		var along := -3.6 + (i % 7) * 1.25 + _rng.randf_range(-0.2, 0.2)
		var across := gw - 0.8 - (i / 7) * 1.1 + _rng.randf_range(-0.15, 0.15)
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
		if i == LOLLIPOP:
			var hand_l: Node3D = p.elbow_l.get_child(p.elbow_l.get_child_count() - 1)
			var lp := _joint(hand_l, Vector3.ZERO)
			_part(lp, _box_mesh(Vector3(0.04, 1.1, 0.04)), _mat("dark", Color.BLACK), Vector3(0, -0.5, 0))
			var disc := CylinderMesh.new()
			disc.top_radius = 0.32
			disc.bottom_radius = 0.32
			disc.height = 0.04
			disc.radial_segments = 16
			c.lolly = _part(lp, disc, StandardMaterial3D.new(), Vector3(0, -1.1, 0))
			(c.lolly.material_override as StandardMaterial3D).albedo_color = Color(0.85, 0.08, 0.06)
			p.items[Carry.LOLLIPOP] = lp
			lp.visible = false
	# new wheels laid out, old wheels put down, guns on the ground
	for k in 4:
		var nt := _wheel_prop(self, false)
		nt.visible = false
		c.new_tyres.append(nt)
		var ot := _wheel_prop(self, false)
		ot.get_node("Band").visible = false
		ot.visible = false
		c.old_tyres.append(ot)
	for g in 2:
		var gn := _gun_prop(self)
		gn.visible = false
		c.guns.append(gn)
	# garage props: tyre stacks (dry, intermediate, wet) under blankets, the
	# gun trolley, the fuel rig
	var frame := {"pos": c.pos, "dir": c.dir, "out": c.out}
	for k in 3:
		var at: Vector2 = crew_spot(frame, c.dims, "stack", k)[0] + c.out * 0.55
		for h in 4:
			var t := _wheel_prop(self, false)
			t.position = Vector3(at.x, c.y + 0.15 + h * 0.3, at.y)
			(t.get_node("Band") as MeshInstance3D).material_override = _mat("band_%d" % k, STACK_COLOURS[k], 0.6)
		if not _meshes.has("cover"):
			var cover := CylinderMesh.new()
			cover.top_radius = 0.36
			cover.bottom_radius = 0.37
			cover.height = 0.5
			cover.radial_segments = 14
			_meshes["cover"] = cover
		var blanket := _mat("blanket_%d_%s" % [k, suit.to_html()], suit.darkened(0.15).lerp(STACK_COLOURS[k], 0.35), 0.9)
		_part(self, _meshes["cover"], blanket, Vector3(at.x, c.y + 1.3, at.y))
	var trolley: Vector2 = crew_spot(frame, c.dims, "trolley")[0] + c.out * 0.6
	var tr := _part(self, _box_mesh(Vector3(1.0, 0.9, 0.6)), _mat("trolley", Color(0.7, 0.1, 0.1), 0.4, 0.4), Vector3(trolley.x, c.y + 0.45, trolley.y))
	tr.rotation.y = -c.dir.angle()
	for g in 2:
		var spare := _gun_prop(self)
		var sp := trolley + c.dir * (g * 0.4 - 0.2)
		spare.position = Vector3(sp.x, c.y + 0.96, sp.y)
		spare.rotation.y = -c.dir.angle()
	c.rig = _at(c, -1.2, gw - 0.3)
	_part(self, _box_mesh(Vector3(0.6, 2.0, 0.6)), _mat("rig", Color(0.85, 0.85, 0.82), 0.5, 0.3), Vector3(c.rig.x, c.y + 1.0, c.rig.y))
	var hose_mesh := _box_mesh(Vector3(1.0, 0.07, 0.07))
	c.hose = _part(self, hose_mesh, _mat("dark", Color.BLACK), Vector3.ZERO)
	c.hose.visible = false
	# strategist on the pit wall, opposite the garage
	var wall := _at(c, 0.0, -(track.pit_width * 0.5 + 0.6) - track.pit_width * 0.25 - 0.1)
	var s := _person(c, suit, helmet)
	s.pos = wall + c.out * 0.55
	s.target = s.pos
	s.face = (-c.out).angle() + PI
	s.target_face = s.face
	s.pose = Pose.SIT
	s.speed = 0.0
	_part(self, _box_mesh(Vector3(0.5, 0.5, 0.5)), _mat("stool", Color(0.2, 0.2, 0.22)), Vector3(s.pos.x, c.y + 0.25, s.pos.y))
	var screen := _part(self, _box_mesh(Vector3(0.1, 0.45, 0.8)), _mat("screen", Color(0.05, 0.06, 0.08), 0.1, 0.2),
		Vector3(wall.x, c.y + 1.35, wall.y))
	screen.rotation.y = -c.out.angle()
	c.people.append(s)
	c.home.append([s.pos, s.face])
	# step the crew once so everyone starts in their pose
	for p in c.people:
		p.carry = _default_carry(c.people.find(p)) if c.people.find(p) < CREW_SIZE else Carry.NONE
		if p.carry in [Carry.GUN, Carry.CLOTH]:
			p.carry = Carry.NONE
		_move(p, 0.5)


## Number of people in the pit lane (for tests).
func people_count() -> int:
	var n := 0
	for k in crews:
		n += (crews[k] as Crew).people.size()
	return n
