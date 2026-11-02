class_name UpgradeCatalog
extends RefCounted
## Car upgrades (R&D parts): engine, aero, brakes, suspension, weight and
## tyres, each from level 0 (stock) to 3. Read from data/upgrades.json.
##
## An upgraded car is the stock car with overrides (CarDefinition.with_overrides):
## overrides_for() turns upgrade levels into the spec values the physics reads,
## plus a "visual" block that tells the 3D model which parts to show.
## Pure data: no nodes, safe in the sim, on a headless host and in tests.

const PATH := "res://modules/business/data/upgrades.json"
const MAX_LEVEL := 3

static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var d = JsonData.load_json(PATH)
		_data = d if d is Dictionary else {"categories": []}
	return _data


## Category ids in display order: engine, aero, brakes, suspension, weight, tyres.
static func category_ids() -> Array:
	var out := []
	for c in data().get("categories", []):
		out.append(c["id"])
	return out


static func category(id: String) -> Dictionary:
	for c in data().get("categories", []):
		if c["id"] == id:
			return c
	return {}


static func level_info(cat_id: String, level: int) -> Dictionary:
	var levels: Array = category(cat_id).get("levels", [])
	if levels.is_empty():
		return {}
	return levels[clampi(level, 0, levels.size() - 1)]


static func max_level(cat_id: String) -> int:
	return maxi(category(cat_id).get("levels", []).size() - 1, 0)


## Price of one level for a car (class scales it: GT3 parts cost more).
static func price(def: CarDefinition, cat_id: String, level: int) -> int:
	var scale: float = data().get("price_scale", {}).get(def.class_tag if def else "", 1.0)
	return int(round(float(level_info(cat_id, level).get("price", 0)) * scale / 100.0)) * 100


## What a car costs to buy into the garage: its class's price from
## data/upgrades.json ("car_prices"), nudged by its power-to-weight so faster
## cars in a class cost a little more. Rounded to 1,000.
static func car_price(def: CarDefinition) -> int:
	var prices: Dictionary = data().get("car_prices", {})
	var base := float(prices.get(def.class_tag, prices.get("default", 120000)))
	var ptw := def.peak_power_kw() / maxf(def.mass, 1.0)
	var nudge := clampf(ptw / 0.35, 0.8, 1.25) if def.class_tag == "Road" else 1.0
	return int(round(base * nudge / 1000.0)) * 1000


## Share of the price paid back when selling a car or an upgrade.
static func refund_share() -> float:
	return float(data().get("refund_share", 0.5))


## What going from level `from` to `to` costs (negative = refund for selling).
static func cost_of_change(def: CarDefinition, cat_id: String, from: int, to: int) -> int:
	var total := 0
	if to > from:
		for l in range(from + 1, to + 1):
			total += price(def, cat_id, l)
	else:
		var share: float = data().get("refund_share", 0.5)
		for l in range(to + 1, from + 1):
			total -= int(round(price(def, cat_id, l) * share / 100.0)) * 100
	return total


## levels: {category id: level}. Returns the overrides for
## CarDefinition.with_overrides(), computed from the car's own (stock) spec,
## so each car keeps its character. Empty when everything is stock.
static func overrides_for(def: CarDefinition, levels: Dictionary) -> Dictionary:
	var o := {}
	var lv := func(cat: String) -> Dictionary: return level_info(cat, int(levels.get(cat, 0)))
	var engine: Dictionary = lv.call("engine")
	var aero: Dictionary = lv.call("aero")
	var brakes: Dictionary = lv.call("brakes")
	var susp: Dictionary = lv.call("suspension")
	var weight: Dictionary = lv.call("weight")
	var tyres: Dictionary = lv.call("tyres")
	var ts: float = engine.get("torque_scale", 1.0)
	if ts != 1.0:
		var base_ts: float = def.raw.get("engine", {}).get("torque_scale", 1.0)
		o["engine"] = {"torque_scale": base_ts * ts}
	if aero.get("cla_scale", 1.0) != 1.0 or aero.get("cda_scale", 1.0) != 1.0:
		o["aero"] = {"cla": def.cla * float(aero.get("cla_scale", 1.0)), "cda": def.cda * float(aero.get("cda_scale", 1.0))}
	if brakes.get("brake_scale", 1.0) != 1.0:
		o["brakes"] = {"max_force_n": def.brake_force * float(brakes.get("brake_scale", 1.0))}
	var grip: float = float(susp.get("grip_scale", 1.0)) * float(tyres.get("grip_scale", 1.0))
	if grip != 1.0:
		o["chassis"] = {"front_grip": def.front_grip * grip, "rear_grip": def.rear_grip * grip}
	if susp.get("cg_drop_m", 0.0) != 0.0:
		o["cg_height_m"] = def.cg_height - float(susp["cg_drop_m"])
	if weight.get("mass_scale", 1.0) != 1.0:
		o["mass_kg"] = float(def.raw.get("mass_kg", def.mass)) * float(weight["mass_scale"])
	var vis := visual_for(levels)
	if not vis.is_empty():
		o["visual"] = vis
	return o


## The 3D parts and finishes for a set of levels: splitter (1), wing (2, 3),
## canards (1), calipers / rims (colour), tyre_width (scale), ride_drop_m.
static func visual_for(levels: Dictionary) -> Dictionary:
	var vis := {}
	for cat in category_ids():
		vis.merge(level_info(cat, int(levels.get(cat, 0))).get("visual", {}), true)
	return vis


## Rough performance numbers for the garage: power, weight, power-to-weight,
## downforce and braking for a car with these levels.
static func stats(def: CarDefinition, levels: Dictionary) -> Dictionary:
	var d := def.with_overrides(overrides_for(def, levels)) if not levels.is_empty() else def
	return {
		"power_kw": d.peak_power_kw(),
		"mass_kg": d.mass,
		"kw_per_t": d.peak_power_kw() / d.mass * 1000.0,
		"cla": d.cla,
		"cda": d.cda,
		"brake_n": d.brake_force,
		"grip": (d.front_grip + d.rear_grip) * 0.5,
	}


## Livery editor options: patterns, their names and the colour palette.
static func livery_options() -> Dictionary:
	return data().get("livery", {})


static func currency() -> String:
	return data().get("currency", "cr")


static func format_money(amount: int) -> String:
	var s := str(absi(amount))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if amount < 0 else "") + s + out + " " + currency()
