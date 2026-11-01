class_name SimEnvironment
extends RefCounted
## Conditions the physics reads. Wave 1: static. Wave 2 adds a weather
## timeline and time-of-day progression via update(), which must stay
## deterministic (driven only by sim time + seed).

var ambient_c: float = 22.0
var track_c: float = 32.0
var time_of_day_h: float = 14.0
var weather: String = "dry"     ## "dry" | "damp" | "wet" (wave 2)
var wetness: float = 0.0        ## 0..1 surface water (wave 2)


static func from_dict(d: Dictionary) -> SimEnvironment:
	var e := SimEnvironment.new()
	e.ambient_c = d.get("ambient_c", e.ambient_c)
	e.track_c = d.get("track_c", e.track_c)
	e.time_of_day_h = d.get("time_of_day_h", e.time_of_day_h)
	e.weather = d.get("weather", e.weather)
	e.wetness = d.get("wetness", e.wetness)
	return e


func to_dict() -> Dictionary:
	return {"ambient_c": ambient_c, "track_c": track_c, "time_of_day_h": time_of_day_h,
		"weather": weather, "wetness": wetness}


## Air density relative to ISA sea level: hot air = less power, drag, downforce.
func air_density() -> float:
	return 1.225 * 288.15 / (ambient_c + 273.15)


## Surface grip multiplier. Asphalt grips best roughly 25..45 degC.
func surface_grip(compound: TyreCompound) -> float:
	var g := 1.0 - 0.002 * maxf(0.0, absf(track_c - 35.0) - 10.0)
	return g * lerpf(1.0, compound.wet_grip_factor, wetness)


func update(_dt: float) -> void:
	pass # wave 2: weather timeline, track temp following sun / rubber build-up
