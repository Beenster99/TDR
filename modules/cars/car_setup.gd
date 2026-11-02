class_name CarSetup
extends RefCounted
## Car setup for per-track tuning (wave 4): wings, ride height, springs,
## dampers, anti-roll bars, camber, toe, brake bias, differential, gearing,
## tyre pressures and fuel load.
##
## A setup is a plain Dictionary of the values the player sees, e.g.
## {"wing_rear": 3, "ride_front": 56, "pressure_front": -0.5, ...}. It travels
## as the "tuning" block of a race entry's setup overrides, so
## CarDefinition.from_dict() turns it into physical numbers with apply(),
## on top of whatever the car (and its upgrades) already is. Keys left out
## keep the car's default, so an empty setup is the car as it comes.
##
## Defaults come from the car's class (Hypercar, LMP2, GT3 or Road) and its own JSON
## ("brakes.bias_front", "gearbox.final_drive", "tuning_ranges", and an
## optional "setup" block that overrides any template value).

const GROUPS := ["Aero", "Suspension", "Alignment", "Brakes and diff", "Gearing", "Tyres", "Fuel"]

## Per class: [default, min, max, step] for each setting, plus physical
## constants of the suspension (see CarPhysics).
const TEMPLATES := {
	"GT3": {
		"wings": true,
		"wing_front": [5, 0, 10, 1], "wing_rear": [5, 0, 10, 1],
		"ride_front": [58, 48, 80, 1], "ride_rear": [72, 58, 95, 1],
		"spring_front": [200, 140, 300, 10], "spring_rear": [180, 120, 280, 10],
		"damper_front": [5, 1, 10, 1], "damper_rear": [5, 1, 10, 1],
		"arb_front": [5, 1, 10, 1], "arb_rear": [5, 1, 10, 1],
		"camber_front": [-3.4, -4.5, -2.0, 0.1], "camber_rear": [-2.6, -3.6, -1.5, 0.1],
		"toe_front": [-0.06, -0.30, 0.10, 0.02], "toe_rear": [0.14, -0.10, 0.40, 0.02],
		"diff_power": [0.45, 0.1, 0.9, 0.05], "diff_coast": [0.3, 0.1, 0.9, 0.05],
		"pressure_front": [0.0, -4.0, 4.0, 0.5], "pressure_rear": [0.0, -4.0, 4.0, 0.5],
		# Physics constants
		"plank_mm": 34.0, "roll_deg_per_g": 1.0, "camber_gain": 0.6,
		"camber_opt_front": -2.5, "camber_opt_rear": -1.9,
	},
	"Hypercar": {
		"wings": true,
		"wing_front": [5, 0, 10, 1], "wing_rear": [5, 0, 10, 1],
		"ride_front": [45, 36, 65, 1], "ride_rear": [58, 46, 80, 1],
		"spring_front": [260, 180, 380, 10], "spring_rear": [240, 160, 360, 10],
		"damper_front": [5, 1, 10, 1], "damper_rear": [5, 1, 10, 1],
		"arb_front": [5, 1, 10, 1], "arb_rear": [5, 1, 10, 1],
		"camber_front": [-3.2, -4.5, -2.0, 0.1], "camber_rear": [-2.2, -3.4, -1.2, 0.1],
		"toe_front": [-0.06, -0.30, 0.10, 0.02], "toe_rear": [0.12, -0.10, 0.40, 0.02],
		"diff_power": [0.4, 0.1, 0.9, 0.05], "diff_coast": [0.3, 0.1, 0.9, 0.05],
		"pressure_front": [0.0, -4.0, 4.0, 0.5], "pressure_rear": [0.0, -4.0, 4.0, 0.5],
		"plank_mm": 28.0, "roll_deg_per_g": 0.7, "camber_gain": 0.5,
		"camber_opt_front": -2.4, "camber_opt_rear": -1.7,
	},
	"LMP2": {
		"wings": true,
		"wing_front": [5, 0, 10, 1], "wing_rear": [5, 0, 10, 1],
		"ride_front": [42, 34, 62, 1], "ride_rear": [55, 44, 78, 1],
		"spring_front": [250, 170, 360, 10], "spring_rear": [230, 150, 340, 10],
		"damper_front": [5, 1, 10, 1], "damper_rear": [5, 1, 10, 1],
		"arb_front": [5, 1, 10, 1], "arb_rear": [5, 1, 10, 1],
		"camber_front": [-3.2, -4.5, -2.0, 0.1], "camber_rear": [-2.2, -3.4, -1.2, 0.1],
		"toe_front": [-0.06, -0.30, 0.10, 0.02], "toe_rear": [0.12, -0.10, 0.40, 0.02],
		"diff_power": [0.45, 0.1, 0.9, 0.05], "diff_coast": [0.3, 0.1, 0.9, 0.05],
		"pressure_front": [0.0, -4.0, 4.0, 0.5], "pressure_rear": [0.0, -4.0, 4.0, 0.5],
		"plank_mm": 28.0, "roll_deg_per_g": 0.75, "camber_gain": 0.5,
		"camber_opt_front": -2.4, "camber_opt_rear": -1.7,
	},
	"RX1": {
		# Rallycross supercars: long-travel suspension riding high for dirt,
		# bumps and jumps; a rear wing but little downforce.
		"wings": true,
		"wing_front": [5, 0, 10, 1], "wing_rear": [5, 0, 10, 1],
		"ride_front": [110, 90, 140, 1], "ride_rear": [115, 95, 145, 1],
		"spring_front": [90, 50, 150, 5], "spring_rear": [85, 45, 145, 5],
		"damper_front": [5, 1, 10, 1], "damper_rear": [5, 1, 10, 1],
		"arb_front": [5, 1, 10, 1], "arb_rear": [5, 1, 10, 1],
		"camber_front": [-2.2, -3.5, -0.5, 0.1], "camber_rear": [-1.6, -3.0, -0.5, 0.1],
		"toe_front": [0.0, -0.30, 0.20, 0.02], "toe_rear": [0.1, -0.10, 0.40, 0.02],
		"diff_power": [0.6, 0.1, 0.95, 0.05], "diff_coast": [0.35, 0.1, 0.9, 0.05],
		"pressure_front": [0.0, -5.0, 5.0, 0.5], "pressure_rear": [0.0, -5.0, 5.0, 0.5],
		"plank_mm": 70.0, "roll_deg_per_g": 1.8, "camber_gain": 0.45,
		"camber_opt_front": -1.6, "camber_opt_rear": -1.2,
	},
	"Road": {
		"wings": false,
		"wing_front": [5, 5, 5, 1], "wing_rear": [5, 5, 5, 1],
		"ride_front": [115, 95, 145, 1], "ride_rear": [120, 100, 150, 1],
		"spring_front": [70, 40, 120, 5], "spring_rear": [65, 35, 115, 5],
		"damper_front": [5, 1, 10, 1], "damper_rear": [5, 1, 10, 1],
		"arb_front": [5, 1, 10, 1], "arb_rear": [5, 1, 10, 1],
		"camber_front": [-1.8, -3.0, -0.5, 0.1], "camber_rear": [-1.5, -2.8, -0.5, 0.1],
		"toe_front": [0.0, -0.30, 0.20, 0.02], "toe_rear": [0.16, -0.10, 0.40, 0.02],
		"diff_power": [0.25, 0.0, 0.8, 0.05], "diff_coast": [0.15, 0.0, 0.8, 0.05],
		"pressure_front": [0.0, -5.0, 5.0, 0.5], "pressure_rear": [0.0, -5.0, 5.0, 0.5],
		"plank_mm": 62.0, "roll_deg_per_g": 2.3, "camber_gain": 0.42,
		"camber_opt_front": -0.9, "camber_opt_rear": -0.8,
	},
}

## Every setting in screen order: [key, group, label, unit, plain explanation].
const ITEMS := [
	["wing_front", "Aero", "Front splitter", "",
		"More = more front grip in fast corners, a little more drag. Less = the car pushes wide (understeers) in fast bends."],
	["wing_rear", "Aero", "Rear wing", "",
		"More = the rear sticks in fast corners and under braking, but a lower top speed. Less = faster on the straights, a looser rear in fast bends. Low for Monza, high for Hungary."],
	["ride_front", "Suspension", "Ride height front", " mm",
		"Lower = more downforce and a lower centre of gravity, but the floor can hit the ground in dips, over crests and in heavy braking, and then grip drops suddenly. Raise it on bumpy, hilly tracks."],
	["ride_rear", "Suspension", "Ride height rear", " mm",
		"Running the rear higher than the front (rake) moves grip to the front and adds a little drag. Too low and the floor hits the ground in compressions."],
	["spring_front", "Suspension", "Springs front", " N/mm",
		"Stiffer = sharper and the car sinks less at speed, but less grip over bumps and kerbs. Softer = more grip on bumpy tracks, but the car sinks more and may bottom out."],
	["spring_rear", "Suspension", "Springs rear", " N/mm",
		"Stiffer rear = more oversteer and better traction on smooth tracks. Softer rear = more grip over bumps and kerbs, but the rear squats more under power."],
	["damper_front", "Suspension", "Dampers front", "",
		"How fast the suspension moves. Stiffer = quicker response and a steadier car through dips and crests. Softer = rides kerbs and bumps better."],
	["damper_rear", "Suspension", "Dampers rear", "",
		"Stiffer = a steadier rear in quick direction changes. Softer = better traction over bumps and kerbs out of slow corners."],
	["arb_front", "Suspension", "Anti-roll bar front", "",
		"Stiffer front bar = more understeer (safer, the car pushes wide). Softer = the front grips better and the car turns in more."],
	["arb_rear", "Suspension", "Anti-roll bar rear", "",
		"Stiffer rear bar = more oversteer (the car rotates, but can snap). Softer = a calmer, more stable rear. Use both bars to balance the car."],
	["camber_front", "Alignment", "Camber front", "°",
		"How far the tyres lean in at the top. More (more negative) = more cornering grip, but less grip under braking and the tyres run hotter. Too much or too little both lose grip."],
	["camber_rear", "Alignment", "Camber rear", "°",
		"More rear camber = more grip in long corners, less traction out of slow ones, hotter rear tyres."],
	["toe_front", "Alignment", "Toe front", "°",
		"Negative = toe-out: sharper turn-in, a little more tyre heat and drag. Positive = calmer steering."],
	["toe_rear", "Alignment", "Toe rear", "°",
		"Positive = toe-in: a stable rear in fast corners and under power, a little more drag and heat. Less = the car rotates more."],
	["brake_bias", "Brakes and diff", "Brake bias", "% front",
		"How much of the braking goes to the front. More front = stable, but the fronts lock first. More rear = the car turns in under braking, but the rear can lock and spin."],
	["diff_power", "Brakes and diff", "Diff on power", "%",
		"How much the driven wheels are locked together when accelerating. More = better traction out of slow corners but more understeer on exit. Less = the car turns more, but the inside wheel can spin."],
	["diff_coast", "Brakes and diff", "Diff off power", "%",
		"Locking when you lift or brake. More = stable into corners. Less = the car turns in more on entry, but the rear gets lively."],
	["final_drive", "Gearing", "Gearing", "",
		"Shorter = quicker acceleration but you reach the limiter sooner. Longer = a higher top speed but slower out of corners. Aim to just reach the limiter at the end of the longest straight."],
	["pressure_front", "Tyres", "Tyre pressure front", " psi",
		"Pressure set cold in the garage; it rises as the tyres heat up. Lower = the tyres warm up faster and grip more, until they overheat and wear. Higher = cooler tyres, less grip. Aim for the hot pressure in the window. On a hot track start lower."],
	["pressure_rear", "Tyres", "Tyre pressure rear", " psi",
		"Same as the front. Rear tyres take the power, so they heat up more on tracks with slow corners."],
	["fuel_l", "Fuel", "Fuel load", " L",
		"Fuel at the start. Less is lighter and faster, but it must last until your stop. Auto = enough for the race (up to a full tank). Only matters when fuel use is on."],
]

const KEYS := ["wing_front", "wing_rear", "ride_front", "ride_rear", "spring_front", "spring_rear",
	"damper_front", "damper_rear", "arb_front", "arb_rear", "camber_front", "camber_rear",
	"toe_front", "toe_rear", "brake_bias", "diff_power", "diff_coast", "final_drive",
	"pressure_front", "pressure_rear", "fuel_l"]

## How much each setting moves the car (see apply()).
const WING_FRONT_DF := 0.05     ## front downforce per splitter click
const WING_REAR_DF := 0.06      ## rear downforce per wing click
const WING_FRONT_DRAG := 0.010  ## drag per click
const WING_REAR_DRAG := 0.024
const RAKE_BALANCE := 0.003     ## front aero share per mm of extra rake
const RAKE_DRAG := 0.0015       ## drag per mm of extra rake
const CG_PER_MM := 0.0009       ## centre of gravity height (m) per mm of ride height
const ARB_STEP := 0.1           ## roll stiffness per anti-roll bar click
const DAMPER_STEP := 0.1        ## damper stiffness per click
const TOE_STEER := 0.8          ## extra steering response per degree of front toe-out


static func template(def: CarDefinition) -> Dictionary:
	return TEMPLATES.get(def.class_tag, TEMPLATES["GT3" if def.cla > 1.5 else "Road"])


## [default, min, max, step] for one setting on this car (before any tuning).
static func range_of(def: CarDefinition, key: String) -> Array:
	var raw := def.raw
	var tr: Dictionary = raw.get("tuning_ranges", {})
	match key:
		"brake_bias":
			var b := float(raw.get("brakes", {}).get("bias_front", def.brake_bias_front))
			var r: Array = tr.get("brake_bias_front", [b - 0.06, b + 0.06])
			return [b, snappedf(float(r[0]), 0.005), snappedf(float(r[1]), 0.005), 0.005]
		"final_drive":
			var f := float(raw.get("gearbox", {}).get("final_drive", def.final_drive))
			var r: Array = tr.get("final_drive", [f * 0.92, f * 1.08])
			return [f, snappedf(float(r[0]), 0.01), snappedf(float(r[1]), 0.01), 0.01]
		"fuel_l":
			var cap := float(raw.get("fuel", {}).get("capacity_l", def.fuel_capacity_l))
			return [-1.0, -1.0, cap, 1.0]
	var t := template(def)
	var own: Dictionary = raw.get("setup", {})
	var r: Array = (t[key] as Array).duplicate()
	if own.has(key):
		r[0] = float(own[key])
	return r


## The car's default setup (every key).
static func defaults(def: CarDefinition) -> Dictionary:
	var out := {}
	for k in KEYS:
		out[k] = range_of(def, k)[0]
	return out


## True for settings this car can change (road cars have fixed wings).
static func adjustable(def: CarDefinition, key: String) -> bool:
	if key in ["wing_front", "wing_rear"]:
		return bool(template(def).get("wings", true))
	var r := range_of(def, key)
	return r[2] > r[1]


## Keeps only known keys, each clamped to its range and snapped to its step.
static func sanitize(def: CarDefinition, setup: Dictionary) -> Dictionary:
	var out := {}
	for k in setup:
		if not k in KEYS or not (setup[k] is float or setup[k] is int):
			continue
		var r := range_of(def, k)
		var v := clampf(float(setup[k]), r[1], r[2])
		if k != "fuel_l" or v >= 0.0:
			v = r[1] + snappedf(v - r[1], r[3])
		out[k] = clampf(v, r[1], r[2])
	return out


## Full setup: defaults with the given values on top.
static func complete(def: CarDefinition, setup: Dictionary) -> Dictionary:
	var out := defaults(def)
	out.merge(sanitize(def, setup), true)
	return out


## Turns a setup into physical numbers on a freshly parsed definition.
## Called by CarDefinition.from_dict() for its "tuning" block (and with an
## empty setup for every car, so the suspension numbers always exist).
static func apply(c: CarDefinition, setup: Dictionary) -> void:
	var t := template(c)
	var s := complete(c, setup)
	c.tuning = sanitize(c, setup)
	var d := defaults(c)
	# Aero: splitter and wing change downforce at each end and drag.
	var df_f: float = c.cla * c.aero_balance_front * (1.0 + WING_FRONT_DF * (s["wing_front"] - d["wing_front"]))
	var df_r: float = c.cla * (1.0 - c.aero_balance_front) * (1.0 + WING_REAR_DF * (s["wing_rear"] - d["wing_rear"]))
	var drag: float = 1.0 + WING_FRONT_DRAG * (s["wing_front"] - d["wing_front"]) + WING_REAR_DRAG * (s["wing_rear"] - d["wing_rear"])
	# Ride height: rake moves the aero balance forward, lower drops the CG.
	var rake: float = (s["ride_rear"] - s["ride_front"]) - (d["ride_rear"] - d["ride_front"])
	c.cla = maxf(df_f + df_r, 0.0)
	c.aero_balance_front = clampf(df_f / maxf(c.cla, 0.001) + RAKE_BALANCE * rake, 0.2, 0.7)
	c.cda *= maxf(drag + RAKE_DRAG * rake, 0.5)
	c.ride_front_mm = s["ride_front"]
	c.ride_rear_mm = s["ride_rear"]
	c.ride_ref_mm = (d["ride_front"] + d["ride_rear"]) * 0.5
	var avg_drop: float = c.ride_ref_mm - (s["ride_front"] + s["ride_rear"]) * 0.5
	c.cg_height = maxf(c.cg_height - CG_PER_MM * avg_drop, 0.15)
	c.plank_mm = float(t["plank_mm"])
	# Springs, dampers and bars.
	c.spring_front = s["spring_front"]
	c.spring_rear = s["spring_rear"]
	c.spring_ref_front = d["spring_front"]
	c.spring_ref_rear = d["spring_rear"]
	c.damper_front = 1.0 + DAMPER_STEP * (s["damper_front"] - d["damper_front"])
	c.damper_rear = 1.0 + DAMPER_STEP * (s["damper_rear"] - d["damper_rear"])
	# Roll stiffness at each end: half from the springs, half from the bar.
	var rf: float = 0.5 * c.spring_front / c.spring_ref_front + 0.5 * (1.0 + ARB_STEP * (s["arb_front"] - d["arb_front"]))
	var rr: float = 0.5 * c.spring_rear / c.spring_ref_rear + 0.5 * (1.0 + ARB_STEP * (s["arb_rear"] - d["arb_rear"]))
	var share := c.roll_stiffness_front
	c.roll_stiffness = share * rf + (1.0 - share) * rr
	c.roll_stiffness_front = clampf(share * rf / maxf(c.roll_stiffness, 0.01), 0.2, 0.85)
	c.roll_deg_per_g = float(t["roll_deg_per_g"])
	# Alignment.
	c.camber_front = s["camber_front"]
	c.camber_rear = s["camber_rear"]
	c.camber_ref_front = d["camber_front"]
	c.camber_ref_rear = d["camber_rear"]
	c.camber_gain = float(t["camber_gain"])
	c.camber_opt_front = float(t["camber_opt_front"])
	c.camber_opt_rear = float(t["camber_opt_rear"])
	c.toe_front = s["toe_front"]
	c.toe_rear = s["toe_rear"]
	# Quicker steering response from front toe-out and stiffer dampers.
	var resp := clampf(1.0 - TOE_STEER * (c.toe_front - float(d["toe_front"])), 0.7, 1.4)
	resp *= 1.0 + 0.04 * (c.damper_front - 1.0) / DAMPER_STEP / 5.0
	c.steer_rate *= resp
	# Brakes, diff, gearing.
	c.brake_bias_front = s["brake_bias"]
	c.diff_power = s["diff_power"]
	c.diff_coast = s["diff_coast"]
	c.final_drive = s["final_drive"]
	# Tyres: cold pressure offsets from the compound's own cold pressure.
	c.pressure_delta_front = s["pressure_front"]
	c.pressure_delta_rear = s["pressure_rear"]
	c.setup_fuel_l = s["fuel_l"] if float(s["fuel_l"]) > 0.0 else -1.0


## Top speed (m/s) at the shift point in top gear with this final drive.
static func top_speed(def: CarDefinition, final_drive: float) -> float:
	if def.gear_ratios.is_empty():
		return 0.0
	var ratio := def.gear_ratios[def.gear_ratios.size() - 1] * final_drive
	return def.redline_rpm / ratio * TAU / 60.0 * def.wheel_radius


## Short text for a value, as the setup screen shows it.
static func format_value(def: CarDefinition, key: String, value: float) -> String:
	match key:
		"brake_bias":
			return "%.1f%% front" % (value * 100.0)
		"diff_power", "diff_coast":
			return "%d%%" % roundi(value * 100.0)
		"final_drive":
			return "%.2f  (top %d km/h)" % [value, roundi(top_speed(def, value) * 3.6)]
		"camber_front", "camber_rear":
			return "%.1f°" % value
		"toe_front", "toe_rear":
			return "%+.2f°" % value
		"pressure_front", "pressure_rear":
			return "%+.1f psi" % value
		"fuel_l":
			return "Auto" if value < 0.0 else "%d L" % roundi(value)
		"ride_front", "ride_rear":
			return "%d mm" % roundi(value)
		"spring_front", "spring_rear":
			return "%d N/mm" % roundi(value)
	return str(roundi(value))
