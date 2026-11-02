class_name Units
extends RefCounted
## Shows numbers in the player's units (Settings > Gameplay): "units" is
## "metric" (km/h, °C, km, litres), "uk" (mph, °C, miles, litres) or
## "imperial" (mph, °F, miles, US gallons); "power_unit" is "hp" (default),
## "kw" or "ps". The game itself always works in SI units (m/s, kW, °C, m, L);
## only what's shown changes.

const MPH_PER_MPS := 2.2369363
const KMH_PER_MPS := 3.6
const HP_PER_KW := 1.3410221     ## mechanical horsepower
const PS_PER_KW := 1.3596216
const M_PER_MILE := 1609.344
const L_PER_GAL := 3.7854118


## The player's prefs (GameData points this at GameData.prefs at start-up;
## tests can hand in their own).
static var prefs: Dictionary = {}


static func system() -> String:
	return str(prefs.get("units", "metric"))


static func power_unit() -> String:
	return str(prefs.get("power_unit", "hp"))


static func uses_mph() -> bool:
	return system() != "metric"


# --- Speed ---------------------------------------------------------------

static func speed_value(mps: float) -> float:
	return mps * (MPH_PER_MPS if uses_mph() else KMH_PER_MPS)


static func speed_unit() -> String:
	return "mph" if uses_mph() else "km/h"


static func speed(mps: float) -> String:
	return "%d %s" % [roundi(speed_value(mps)), speed_unit()]


# --- Power ---------------------------------------------------------------

static func power_value(kw: float) -> float:
	match power_unit():
		"kw": return kw
		"ps": return kw * PS_PER_KW
	return kw * HP_PER_KW


static func power_label() -> String:
	match power_unit():
		"kw": return "kW"
		"ps": return "PS"
	return "hp"


static func power(kw: float) -> String:
	return "%d %s" % [roundi(power_value(kw)), power_label()]


## Power per tonne, e.g. "412 hp/t".
static func power_per_tonne(kw_per_t: float) -> String:
	return "%d %s/t" % [roundi(power_value(kw_per_t)), power_label()]


# --- Temperature -----------------------------------------------------------

static func temp_value(c: float) -> float:
	return c * 1.8 + 32.0 if system() == "imperial" else c


static func temp_unit() -> String:
	return "°F" if system() == "imperial" else "°C"


static func temp(c: float) -> String:
	return "%d%s" % [roundi(temp_value(c)), temp_unit()]


# --- Distance ----------------------------------------------------------------

static func distance_value(m: float) -> float:
	return m / M_PER_MILE if uses_mph() else m / 1000.0


static func distance_unit() -> String:
	return "mi" if uses_mph() else "km"


static func distance(m: float, decimals := 2) -> String:
	return ("%." + str(decimals) + "f %s") % [distance_value(m), distance_unit()]


# --- Fuel ------------------------------------------------------------------

static func fuel_value(litres: float) -> float:
	return litres / L_PER_GAL if system() == "imperial" else litres


static func fuel_unit() -> String:
	return "gal" if system() == "imperial" else "L"


static func fuel(litres: float, decimals := 1) -> String:
	return ("%." + str(decimals) + "f %s") % [fuel_value(litres), fuel_unit()]
