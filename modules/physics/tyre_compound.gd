class_name TyreCompound
extends RefCounted
## Tyre compound data (modules/physics/data/*.json). Grip depends on temperature,
## load and surface; temperature evolves from slip work, rolling, air and track.

var id: String = ""
var display_name: String = ""
var peak_mu: float = 1.2
var peak_slip_angle: float = deg_to_rad(7.5)
var shape_c: float = 1.45
var shape_b: float = 7.0
var load_sensitivity: float = 0.1
var optimal_temp_c: float = 85.0
var temp_window_c: float = 30.0
var cold_falloff: float = 0.06
var hot_falloff: float = 0.1
var min_grip_factor: float = 0.65
var heat_from_slip: float = 0.2      ## degC/s per kW of slip power
var heat_from_rolling: float = 0.012 ## degC/s per (m/s * load ratio)
var cool_to_air: float = 0.006
var cool_to_track: float = 0.004
var wet_grip_factor: float = 0.55    ## used by weather (wave 2)
var wear_rate: float = 0.0           ## used by tyre wear (wave 3/4)


static func from_dict(d: Dictionary) -> TyreCompound:
	var t := TyreCompound.new()
	t.id = d.get("id", "")
	t.display_name = d.get("name", t.id)
	t.peak_mu = d.get("peak_mu", t.peak_mu)
	t.peak_slip_angle = deg_to_rad(d.get("peak_slip_angle_deg", 7.5))
	t.shape_c = d.get("shape_c", t.shape_c)
	t.load_sensitivity = d.get("load_sensitivity", t.load_sensitivity)
	t.optimal_temp_c = d.get("optimal_temp_c", t.optimal_temp_c)
	t.temp_window_c = d.get("temp_window_c", t.temp_window_c)
	t.cold_falloff = d.get("cold_falloff", t.cold_falloff)
	t.hot_falloff = d.get("hot_falloff", t.hot_falloff)
	t.min_grip_factor = d.get("min_grip_factor", t.min_grip_factor)
	t.heat_from_slip = d.get("heat_from_slip", t.heat_from_slip)
	t.heat_from_rolling = d.get("heat_from_rolling", t.heat_from_rolling)
	t.cool_to_air = d.get("cool_to_air", t.cool_to_air)
	t.cool_to_track = d.get("cool_to_track", t.cool_to_track)
	t.wet_grip_factor = d.get("wet_grip_factor", t.wet_grip_factor)
	t.wear_rate = d.get("wear_rate", t.wear_rate)
	# Simplified Pacejka: F = sin(C * atan(B * alpha)) peaks where C*atan(B*a) = PI/2
	t.shape_b = tan(PI / (2.0 * t.shape_c)) / t.peak_slip_angle
	return t


## Grip multiplier from tyre temperature (1.0 inside the optimal point).
func temp_grip_factor(temp_c: float) -> float:
	var x := (temp_c - optimal_temp_c) / temp_window_c
	var k := cold_falloff if x < 0.0 else hot_falloff
	return maxf(min_grip_factor, 1.0 - k * x * x)


## Normalised lateral force curve for a slip angle (radians), range -1..1.
func lateral_curve(alpha: float) -> float:
	return sin(shape_c * atan(shape_b * alpha))
