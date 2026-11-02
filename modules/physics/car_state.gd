class_name CarState
extends RefCounted
## Complete physical state of one car. Everything the server replicates to
## clients lives here (plus RaceEntry for race progress). No Nodes, no
## rendering: pure data so the sim can run headless on a dedicated server.

const FL := 0
const FR := 1
const RL := 2
const RR := 3

var pos: Vector2 = Vector2.ZERO
var heading: float = 0.0       ## radians, 0 = +X, positive = clockwise on screen
var vel: Vector2 = Vector2.ZERO
var yaw_rate: float = 0.0
var steer_angle: float = 0.0
var gear: int = 1              ## -1 reverse, 1..n forward
var rpm: float = 1000.0
var ax: float = 0.0            ## body-frame accel from last step (load transfer)
var ay: float = 0.0
var fy_front: float = 0.0      ## axle lateral forces from last step (TC needs them)
var fy_rear: float = 0.0
var tyre_temp: PackedFloat64Array = [20.0, 20.0, 20.0, 20.0]
var tyre_wear: PackedFloat64Array = [0.0, 0.0, 0.0, 0.0] ## 0 = new, 1 = gone (wave 3)
var fuel_l: float = 30.0
## Damage 0..1 per system (see CarDamage). The race sim writes them from
## hits and kerbs, CarPhysics reads them, the pits repair them.
var damage_engine: float = 0.0
var damage_aero: float = 0.0
var damage_suspension: float = 0.0
var damage_gearbox: float = 0.0
var alignment: float = 0.0     ## -1 pulls left .. 1 pulls right (bent toe links)
var puncture: PackedFloat64Array = [0.0, 0.0, 0.0, 0.0] ## 1 = that tyre is flat
## Bodywork bend per zone (CarDamage.FRONT, REAR, LEFT, RIGHT), what you see.
var body_damage: PackedFloat64Array = [0.0, 0.0, 0.0, 0.0]
## CarDamage.Level the race runs at (set on the grid from the race settings).
var damage_level: int = 0
var shift_cut: float = 0.0     ## seconds of power cut left from a slow (damaged) gearshift
## Track tracking
var track_idx: int = 0
var track_s: float = 0.0
var lateral_offset: float = 0.0
var surface: int = TrackData.Surface.TRACK
## Driver aids (per player choice, replicated so server applies them)
var assist_tc: bool = true
var assist_abs: bool = true
## Stability help for human drivers: catches slides (like ESC, braking one
## wheel), adds some counter-steer and keeps the front tyres near their best
## slip angle. Off for AI, which drives the raw car.
var assist_stability: bool = false

## Telemetry (derived each step, not part of the authoritative snapshot)
var slip_angle_front: float = 0.0
var slip_angle_rear: float = 0.0
var grip_usage_rear: float = 0.0
var wheelspin: bool = false


func speed() -> float:
	return vel.length()


func forward() -> Vector2:
	return Vector2.from_angle(heading)


func right() -> Vector2:
	var f := forward()
	return Vector2(-f.y, f.x)


## Authoritative snapshot as a flat float array (cheap to diff/compress later).
func serialize() -> PackedFloat64Array:
	var a := PackedFloat64Array([
		pos.x, pos.y, heading, vel.x, vel.y, yaw_rate, steer_angle, gear, rpm, ax, ay,
		fuel_l, damage_engine, damage_aero, damage_suspension,
		track_idx, track_s, lateral_offset, surface, int(assist_tc), int(assist_abs), fy_front, fy_rear])
	a.append_array(tyre_temp)
	a.append_array(tyre_wear)
	a.append(int(assist_stability))
	a.append_array(PackedFloat64Array([damage_gearbox, alignment, damage_level, shift_cut]))
	a.append_array(puncture)
	a.append_array(body_damage)
	return a


## Compact float32 form streamed by the car's owner ~30 times a second.
const NET_SIZE := 28


func pack_net(out: PackedFloat32Array) -> void:
	out.append_array(PackedFloat32Array([pos.x, pos.y, heading, vel.x, vel.y, yaw_rate, steer_angle,
		gear, rpm, ax, ay, fuel_l, damage_engine, damage_aero, damage_suspension,
		int(assist_tc) | (int(assist_abs) << 1) | (int(wheelspin) << 2) | (int(assist_stability) << 3)
			| (int(puncture[0] > 0.5) << 4) | (int(puncture[1] > 0.5) << 5)
			| (int(puncture[2] > 0.5) << 6) | (int(puncture[3] > 0.5) << 7),
		tyre_temp[0], tyre_temp[1], tyre_temp[2], tyre_temp[3], fy_front, fy_rear,
		damage_gearbox, alignment, body_damage[0], body_damage[1], body_damage[2], body_damage[3]]))


func unpack_net(a: PackedFloat32Array, o: int) -> void:
	pos = Vector2(a[o], a[o + 1]); heading = a[o + 2]; vel = Vector2(a[o + 3], a[o + 4])
	yaw_rate = a[o + 5]; steer_angle = a[o + 6]; gear = int(a[o + 7]); rpm = a[o + 8]
	ax = a[o + 9]; ay = a[o + 10]; fuel_l = a[o + 11]
	damage_engine = a[o + 12]; damage_aero = a[o + 13]; damage_suspension = a[o + 14]
	var flags := int(a[o + 15])
	assist_tc = flags & 1 != 0; assist_abs = flags & 2 != 0; wheelspin = flags & 4 != 0
	assist_stability = flags & 8 != 0
	for w in 4:
		puncture[w] = 1.0 if flags & (16 << w) != 0 else 0.0
	tyre_temp = PackedFloat64Array([a[o + 16], a[o + 17], a[o + 18], a[o + 19]])
	fy_front = a[o + 20]; fy_rear = a[o + 21]
	damage_gearbox = a[o + 22]; alignment = a[o + 23]
	body_damage = PackedFloat64Array([a[o + 24], a[o + 25], a[o + 26], a[o + 27]])


func deserialize(a: PackedFloat64Array) -> void:
	pos = Vector2(a[0], a[1]); heading = a[2]; vel = Vector2(a[3], a[4])
	yaw_rate = a[5]; steer_angle = a[6]; gear = int(a[7]); rpm = a[8]; ax = a[9]; ay = a[10]
	fuel_l = a[11]; damage_engine = a[12]; damage_aero = a[13]; damage_suspension = a[14]
	track_idx = int(a[15]); track_s = a[16]; lateral_offset = a[17]; surface = int(a[18])
	assist_tc = a[19] != 0.0; assist_abs = a[20] != 0.0
	fy_front = a[21]; fy_rear = a[22]
	tyre_temp = a.slice(23, 27)
	tyre_wear = a.slice(27, 31)
	assist_stability = a.size() > 31 and a[31] != 0.0
	if a.size() >= 44:
		damage_gearbox = a[32]; alignment = a[33]; damage_level = int(a[34]); shift_cut = a[35]
		puncture = a.slice(36, 40)
		body_damage = a.slice(40, 44)
