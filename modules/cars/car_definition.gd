class_name CarDefinition
extends RefCounted
## Parsed car spec (modules/cars/data/*.json). Immutable during a race.
## Upgrades and per-track tuning (wave 4) are applied by building a new
## definition with with_overrides() before the race starts.

var raw: Dictionary = {}
var id: String = ""
var display_name: String = ""
var description: String = ""
var class_tag: String = ""
## Kind of racing the car is built for: "circuit", "rallycross" or "derby".
var discipline: String = "circuit"
## How much of a hit the car shrugs off: CarDamage divides damage by it
## (1 = a race car; old steel derby cars 1.2-3.2).
var toughness: float = 1.0
var colour: Color = Color.WHITE
var mass: float = 1400.0
var wheelbase: float = 2.6
var cg_to_front: float = 1.3
var cg_height: float = 0.45
var track_width: float = 1.6
var length: float = 4.5
var width: float = 1.9
## How far the middle of the bodywork sits ahead of the centre of gravity (m):
## the car's hit box is centred there ("body_offset_m", measured from the 3D model).
var body_offset: float = 0.0
var inertia: float = 2000.0
var front_grip: float = 1.0          ## tyre size / setup grip multipliers
var rear_grip: float = 1.1
var roll_stiffness_front: float = 0.6  ## share of lateral load transfer taken by the front
var idle_rpm: float = 1000.0
var redline_rpm: float = 7500.0
var shift_up_rpm: float = 7300.0
var shift_down_rpm: float = 4000.0
var torque_rpm: PackedFloat64Array = []
var torque_nm: PackedFloat64Array = []
var engine_brake_nm: float = 60.0
var gear_ratios: PackedFloat64Array = []
var final_drive: float = 4.0
var drivetrain_efficiency: float = 0.88
var front_drive_split: float = 0.0  ## 0 = RWD, 1 = FWD, between = AWD
var wheel_radius: float = 0.34
var brake_force: float = 18000.0
var brake_bias_front: float = 0.6
var max_steer: float = deg_to_rad(30.0)
var steer_rate: float = deg_to_rad(250.0)
var cda: float = 0.8
var cla: float = 0.8
var aero_balance_front: float = 0.42
var tyre_compound_id: String = ""
var fuel_capacity_l: float = 60.0
var bsfc_l_per_kwh: float = 0.3
## Setup (per-track tuning, see CarSetup): what the setup values became.
## Every car has them; with no "tuning" block they are the car's defaults.
var tuning: Dictionary = {}         ## the sanitised setup values given (empty = defaults)
var ride_front_mm: float = 58.0     ## static ride height
var ride_rear_mm: float = 72.0
var ride_ref_mm: float = 65.0       ## default average ride height (aero reference)
var plank_mm: float = 34.0          ## ride height at which the floor touches the ground
var spring_front: float = 200.0     ## wheel rate, N/mm
var spring_rear: float = 180.0
var spring_ref_front: float = 200.0
var spring_ref_rear: float = 180.0
var damper_front: float = 1.0       ## damper stiffness, 1 = default
var damper_rear: float = 1.0
var roll_stiffness: float = 1.0     ## total roll stiffness, 1 = default
var roll_deg_per_g: float = 1.0     ## body roll at default stiffness
var camber_front: float = -3.4      ## static camber, degrees
var camber_rear: float = -2.6
var camber_ref_front: float = -3.4
var camber_ref_rear: float = -2.6
var camber_gain: float = 0.6        ## camber lost on the outside tyre per degree of roll
var camber_opt_front: float = -2.5  ## best camber while cornering
var camber_opt_rear: float = -1.9
var toe_front: float = -0.06        ## degrees, negative = toe-out
var toe_rear: float = 0.14
var diff_power: float = 0.45        ## limited-slip locking on power, 0..1
var diff_coast: float = 0.3         ## and off power
var pressure_delta_front: float = 0.0 ## cold pressure vs the compound's own, psi
var pressure_delta_rear: float = 0.0
var setup_fuel_l: float = -1.0      ## start fuel from the setup, -1 = race default


static func from_dict(d: Dictionary) -> CarDefinition:
	var c := CarDefinition.new()
	c.raw = d.duplicate(true)
	c.id = d.get("id", "")
	c.display_name = d.get("name", c.id)
	c.description = d.get("description", "")
	c.class_tag = d.get("class_tag", "")
	c.discipline = str(d.get("discipline", "circuit"))
	c.toughness = maxf(float(d.get("toughness", 1.0)), 0.2)
	c.colour = Color.from_string(d.get("colour", "#ffffff"), Color.WHITE)
	c.mass = float(d.get("mass_kg", c.mass)) + float(d.get("ballast_kg", 0.0))
	c.wheelbase = d.get("wheelbase_m", c.wheelbase)
	c.cg_to_front = c.wheelbase * (1.0 - float(d.get("weight_front", 0.5)))
	c.cg_height = d.get("cg_height_m", c.cg_height)
	c.track_width = d.get("track_width_m", c.track_width)
	c.length = d.get("length_m", c.length)
	c.width = d.get("width_m", c.width)
	c.body_offset = float(d.get("body_offset_m", c.body_offset))
	var b := c.wheelbase - c.cg_to_front
	c.inertia = float(d.get("inertia_factor", 1.0)) * c.mass * c.cg_to_front * b * 1.1
	var ch: Dictionary = d.get("chassis", {})
	c.front_grip = ch.get("front_grip", c.front_grip)
	c.rear_grip = ch.get("rear_grip", c.rear_grip)
	c.roll_stiffness_front = ch.get("roll_stiffness_front", c.roll_stiffness_front)
	var e: Dictionary = d.get("engine", {})
	c.idle_rpm = e.get("idle_rpm", c.idle_rpm)
	c.redline_rpm = e.get("redline_rpm", c.redline_rpm)
	c.shift_up_rpm = e.get("shift_up_rpm", c.redline_rpm - 200.0)
	c.shift_down_rpm = e.get("shift_down_rpm", c.redline_rpm * 0.55)
	c.engine_brake_nm = e.get("engine_brake_nm", c.engine_brake_nm)
	for p in e.get("torque_curve", [[1000, 200], [7000, 300]]):
		c.torque_rpm.append(float(p[0]))
		c.torque_nm.append(float(p[1]))
	# Engine upgrades and balance of performance scale the whole curve.
	var torque_scale := float(e.get("torque_scale", 1.0))
	if torque_scale != 1.0:
		for i in c.torque_nm.size():
			c.torque_nm[i] *= torque_scale
	var g: Dictionary = d.get("gearbox", {})
	for r in g.get("ratios", [3.0, 2.0, 1.5, 1.2, 1.0]):
		c.gear_ratios.append(float(r))
	c.final_drive = g.get("final_drive", c.final_drive)
	c.drivetrain_efficiency = g.get("efficiency", c.drivetrain_efficiency)
	match String(d.get("drivetrain", "RWD")):
		"FWD": c.front_drive_split = 1.0
		"AWD": c.front_drive_split = d.get("awd_front_split", 0.4)
		_: c.front_drive_split = 0.0
	c.wheel_radius = d.get("wheel_radius_m", c.wheel_radius)
	var br: Dictionary = d.get("brakes", {})
	c.brake_force = br.get("max_force_n", c.brake_force)
	c.brake_bias_front = br.get("bias_front", c.brake_bias_front)
	var st: Dictionary = d.get("steering", {})
	c.max_steer = deg_to_rad(st.get("max_angle_deg", 30.0))
	c.steer_rate = deg_to_rad(st.get("rate_deg_s", 250.0))
	var ae: Dictionary = d.get("aero", {})
	c.cda = ae.get("cda", c.cda)
	c.cla = ae.get("cla", c.cla)
	c.aero_balance_front = ae.get("balance_front", c.aero_balance_front)
	c.tyre_compound_id = d.get("tyre_compound", "road_semi_slick")
	var f: Dictionary = d.get("fuel", {})
	c.fuel_capacity_l = f.get("capacity_l", c.fuel_capacity_l)
	c.bsfc_l_per_kwh = f.get("bsfc_l_per_kwh", c.bsfc_l_per_kwh)
	var tuning = d.get("tuning", {})
	CarSetup.apply(c, tuning if tuning is Dictionary else {})
	return c


## Deep-merge overrides (upgrades / tuning setups) over the base spec.
## e.g. {"aero": {"cla": 1.3}, "brakes": {"bias_front": 0.58}}
## Keys the sim reads besides the base spec: engine.torque_scale (multiplies
## the torque curve), ballast_kg (added to mass_kg). A "visual" block (upgrade
## parts for the 3D model, see the business module) is kept in raw only.
## A setup goes in as {"tuning": {...CarSetup values...}} and is applied after
## the rest.
func with_overrides(overrides: Dictionary) -> CarDefinition:
	var merged := raw.duplicate(true)
	_merge(merged, overrides)
	return CarDefinition.from_dict(merged)


static func _merge(into: Dictionary, src: Dictionary) -> void:
	for k in src:
		if into.get(k) is Dictionary and src[k] is Dictionary:
			_merge(into[k], src[k])
		else:
			into[k] = src[k]


func torque_at(rpm: float) -> float:
	var n := torque_rpm.size()
	if rpm <= torque_rpm[0]:
		return torque_nm[0]
	for i in range(1, n):
		if rpm <= torque_rpm[i]:
			var t := (rpm - torque_rpm[i - 1]) / (torque_rpm[i] - torque_rpm[i - 1])
			return lerpf(torque_nm[i - 1], torque_nm[i], t)
	return torque_nm[n - 1]


func gear_count() -> int:
	return gear_ratios.size()


func peak_power_kw() -> float:
	var best := 0.0
	var rpm := idle_rpm
	while rpm <= redline_rpm:
		best = maxf(best, torque_at(rpm) * rpm * TAU / 60.0 / 1000.0)
		rpm += 100.0
	return best
