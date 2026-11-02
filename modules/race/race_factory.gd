class_name RaceFactory
extends RefCounted
## Builds races in two steps so server and clients construct identical sims:
##  1. plan()  - host only: picks AI drivers/cars from the seed, returns
##               "start data" (plain Dictionary, sent to every client).
##  2. build_sim() - everyone: turns start data into a RaceSim.
## The AI drivers live in the ai module, which builds on this one.

## humans: [{ "name": String, "car_id": String, "tyre": String, "crew": [{peer_id, name, role}],
##           "setup": Dictionary (CarDefinition overrides: upgrades, tuning), "livery": Dictionary }]
## tyre: "auto" (match the start weather), "dry", "intermediate" or "wet".
## drivers: the AI to draw from, as in drivers.json. A driver with a "car_id"
## (a season's fixed field) drives that car if the race's class allows it.
## track: the race's track (loaded from settings.track_id when not given),
## used to pick the AI's setups.
static func plan(settings: RaceSettings, humans: Array, cars: Dictionary, drivers: Array,
		track: TrackData = null) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = settings.seed
	var all_ids: Array = cars.keys()
	all_ids.sort()
	var fixed_class := settings.car_class != "" and settings.car_class != RaceSettings.CLASS_MULTI \
		and not CarCatalog.ids_in_class(cars, settings.car_class).is_empty()
	var class_ids: Array = CarCatalog.ids_in_class(cars, settings.car_class) if fixed_class else all_ids
	# Human cars: their pick, unless it's outside a fixed class.
	var human_cars := []
	for h in humans:
		var id: String = h.get("car_id", "")
		human_cars.append(id if id in class_ids else class_ids[0])
	# AI cars come from these classes, taken in turn so every class is used.
	var ai_classes: Array = []
	if fixed_class:
		ai_classes = [settings.car_class]
	elif settings.car_class == RaceSettings.CLASS_MULTI or humans.is_empty():
		ai_classes = CarCatalog.classes(cars)
	else:
		for id in human_cars:
			if not cars[id].class_tag in ai_classes:
				ai_classes.append(cars[id].class_tag)
	var entries := []
	var pool := drivers.duplicate()
	var start_weather := SimEnvironment.resolve_start_weather(settings.environment, {}, settings.seed)
	# Standard grid: AI fill the front, humans start behind. The grid holds
	# 25 cars of one class, or 45 in a multi-class race.
	var ai_count := clampi(settings.ai_count, 0, maxi(0, settings.max_cars() - humans.size()))
	for k in ai_count:
		var e := RaceEntry.new()
		e.is_ai = true
		if pool.is_empty():
			e.driver_name = "AI %d" % (k + 1)
			e.traits = {"pace": 0.9, "consistency": 0.9}
		else:
			var d: Dictionary = pool.pop_at(rng.randi_range(0, pool.size() - 1))
			e.driver_name = d.get("name", "AI")
			e.traits = d.get("traits", {})
			e.car_id = d.get("car_id", "")  # a season's AI keep their team's car
		var in_class: Array = CarCatalog.ids_in_class(cars, ai_classes[k % ai_classes.size()])
		var pick: String = in_class[rng.randi_range(0, in_class.size() - 1)]
		if not cars.has(e.car_id) or (fixed_class and not e.car_id in class_ids):
			e.car_id = pick
		_fit_tyres(e, "auto", start_weather)
		entries.append(e.describe())
	if settings.tuning_enabled and ai_count > 0:
		_ai_setups(settings, entries, cars, track)
	for k in humans.size():
		var h: Dictionary = humans[k]
		var e := RaceEntry.new()
		e.driver_name = h.get("name", "Player")
		e.car_id = human_cars[k]
		e.crew = h.get("crew", [{"peer_id": 0, "name": e.driver_name, "role": RaceEntry.ROLE_DRIVER}])
		if h.get("car_id", "") == e.car_id:   # upgrades belong to the car they were bought for
			var su = h.get("setup", {})
			e.setup = su.duplicate(true) if su is Dictionary else {}
		var lv = h.get("livery", {})
		e.livery = lv.duplicate(true) if lv is Dictionary else {}
		_fit_tyres(e, h.get("tyre", "auto"), start_weather)
		entries.append(e.describe())
	apply_balance(entries, settings.upgrades_mode, cars)
	_order_grid(entries, settings.grid_order, cars, rng)
	if settings.drivers_per_car > 1:
		add_co_drivers(entries, settings.drivers_per_car, settings.seed)
	return {"settings": settings.to_dict(), "entries": entries}


const CO_DRIVERS_PATH := "res://modules/race/data/co_drivers.json"
## A solo player's AI co-driver: a steady, decent driver.
const PLAYER_CO_DRIVER := {"pace": 0.86, "consistency": 0.9, "aggression": 0.45, "overtaking": 0.6,
	"defending": 0.6, "tyre_management": 0.75, "wet_skill": 0.7, "composure": 0.8}


## Drivers sharing cars (RaceSettings.drivers_per_car > 1), on entry
## descriptions: every AI car gets a "lineup" of that many drivers (the lead
## driver first), and a player racing alone gets one AI co-driver in their
## crew (RaceEntry.AI_PEER) to hand the car to at a stop. Co-op crews share
## the car between themselves. Names come from co_drivers.json, never one
## already in the race; traits are the lead driver's, a little lower.
static func add_co_drivers(entries: Array, per_car: int, seed: int) -> void:
	per_car = clampi(per_car, 1, RaceSettings.MAX_DRIVERS_PER_CAR)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed * 13 + 5   # its own stream: the grid itself stays as it was
	var data = JsonData.load_json(CO_DRIVERS_PATH)
	var first: Array = data.get("first", ["Alex"]) if data is Dictionary else ["Alex"]
	var last: Array = data.get("last", ["Reserve"]) if data is Dictionary else ["Reserve"]
	var used := {}
	for d in entries:
		used[str(d.get("driver_name", ""))] = true
		for m in d.get("crew", []):
			used[str(m.get("name", ""))] = true
	var pick_name := func() -> String:
		for _t in 200:
			var n := "%s %s" % [first[rng.randi_range(0, first.size() - 1)], last[rng.randi_range(0, last.size() - 1)]]
			if not used.has(n):
				used[n] = true
				return n
		return "Reserve %d" % used.size()
	for d in entries:
		if d.get("is_ai", false):
			var lead: Dictionary = d.get("traits", {})
			var lineup := [{"name": d.get("driver_name", "AI"), "traits": lead}]
			for _k in per_car - 1:
				var t := {}
				for key in lead:
					t[key] = clampf(float(lead[key]) * rng.randf_range(0.9, 1.0), 0.0, 1.0)
				if t.is_empty():
					t = {"pace": 0.86, "consistency": 0.88}
				lineup.append({"name": pick_name.call(), "traits": t})
			d["lineup"] = lineup
		else:
			var crew: Array = (d.get("crew", []) as Array).duplicate(true)
			if crew.size() != 1 or crew[0].get("role", "") != RaceEntry.ROLE_DRIVER:
				continue
			d["crew"] = crew
			var t := {}
			for key in PLAYER_CO_DRIVER:
				t[key] = clampf(PLAYER_CO_DRIVER[key] + rng.randf_range(-0.04, 0.04), 0.0, 1.0)
			crew.append({"peer_id": RaceEntry.AI_PEER, "name": pick_name.call(), "role": RaceEntry.ROLE_PIT_WALL,
				"ai": true, "traits": t})


## Every AI car gets a good setup for this track and the start conditions
## (SetupAdvisor), so the AI is as quick as a well set-up player.
static func _ai_setups(settings: RaceSettings, entries: Array, cars: Dictionary, track: TrackData) -> void:
	if track == null:
		track = TrackCatalog.load_track(settings.track_id)
	if track == null:
		return
	var track_env := track.default_environment.duplicate()
	if not track.climate.is_empty():
		track_env["climate"] = track.climate
	var env := SimEnvironment.create(track_env, settings.environment, settings.seed)
	var tyres := TyreCatalog.load_all()
	for d in entries:
		var def: CarDefinition = cars.get(d["car_id"])
		if def == null:
			continue
		var compound: String = d["setup"].get("tyre_compound", def.tyre_compound_id)
		var cond := {"track_c": env.track_c, "ambient_c": env.ambient_c, "wetness": env.wetness,
			"laps": settings.laps, "fuel_enabled": settings.fuel_enabled, "fuel_rate": settings.fuel_rate,
			"compound": tyres.get(def.tyre_compound_id)}
		if compound != def.tyre_compound_id:
			cond["wetness"] = maxf(env.wetness, 0.5)
		d["setup"]["tuning"] = SetupAdvisor.recommend(def, track, cond)


## Setup keys that are not upgrades: tyre choice and track tuning (its own
## host switch), kept in every upgrades mode.
const NOT_UPGRADES := ["tyre_compound", "tuning"]
## Balance of performance limits.
const BOP_POWER := Vector2(0.85, 1.15)
const BOP_DOWNFORCE := Vector2(0.8, 1.25)


## Host option RaceSettings.upgrades_mode on entry descriptions (plan output):
##   "on": as they are. "stock": upgrades removed (looks too).
##   "bop": upgrade performance removed but the looks kept, then every car is
##   given engine.torque_scale and aero.cla so its power-to-weight and
##   downforce-to-weight match the median of the stock cars in its class.
## The result is written in setup["bop"] = {"power": x, "downforce": y}.
static func apply_balance(entries: Array, mode: String, cars: Dictionary) -> void:
	if mode != RaceSettings.UPGRADES_STOCK and mode != RaceSettings.UPGRADES_BOP:
		return
	for d in entries:
		var keep := {}
		for k in NOT_UPGRADES:
			if d.get("setup", {}).has(k):
				keep[k] = d["setup"][k]
		if mode == RaceSettings.UPGRADES_BOP and d.get("setup", {}).has("visual"):
			keep["visual"] = d["setup"]["visual"]
		d["setup"] = keep
	if mode != RaceSettings.UPGRADES_BOP:
		return
	var ref := bop_reference(cars)
	for d in entries:
		var c: CarDefinition = cars.get(d.get("car_id", ""))
		if c == null or not ref.has(c.class_tag):
			continue
		var r: Dictionary = ref[c.class_tag]
		var power := clampf(r["kw_per_kg"] / (c.peak_power_kw() / c.mass), BOP_POWER.x, BOP_POWER.y)
		var down := clampf(r["cla_per_kg"] / (c.cla / c.mass), BOP_DOWNFORCE.x, BOP_DOWNFORCE.y)
		var su: Dictionary = d["setup"]
		var base_ts: float = c.raw.get("engine", {}).get("torque_scale", 1.0)
		su["engine"] = {"torque_scale": base_ts * power}
		su["aero"] = {"cla": c.cla * down}
		su["bop"] = {"power": snappedf(power, 0.001), "downforce": snappedf(down, 0.001)}


## Per class: median stock power-to-weight (kW/kg) and downforce (ClA/kg).
static func bop_reference(cars: Dictionary) -> Dictionary:
	var out := {}
	for cls in CarCatalog.classes(cars):
		var pw: Array = []
		var df: Array = []
		for id in CarCatalog.ids_in_class(cars, cls):
			var c: CarDefinition = cars[id]
			pw.append(c.peak_power_kw() / c.mass)
			df.append(c.cla / c.mass)
		pw.sort()
		df.sort()
		out[cls] = {"kw_per_kg": pw[pw.size() / 2], "cla_per_kg": df[df.size() / 2]}
	return out


const TYRE_FOR_WEATHER := {"light_rain": "intermediate", "heavy_rain": "full_wet"}
const TYRE_CHOICES := {"intermediate": "intermediate", "wet": "full_wet"}


## Puts the chosen tyres on a car ("dry" = the car's own compound).
static func _fit_tyres(e: RaceEntry, choice: String, start_weather: String) -> void:
	var compound: String = TYRE_FOR_WEATHER.get(start_weather, "") if choice == "auto" else TYRE_CHOICES.get(choice, "")
	if compound != "":
		e.setup["tyre_compound"] = compound


static func _order_grid(entries: Array, order: String, cars: Dictionary, rng: RandomNumberGenerator) -> void:
	match order:
		"random":
			for i in range(entries.size() - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var t = entries[i]
				entries[i] = entries[j]
				entries[j] = t
		"reversed":
			var pace := func(d: Dictionary) -> float:
				var c: CarDefinition = cars.get(d["car_id"])
				var t: Dictionary = d.get("traits", {})
				var skill: float = t.get("pace", t.get("skill", 1.0)) if d.get("is_ai", false) else 1.0
				return (c.peak_power_kw() / c.mass if c else 0.25) * lerpf(0.85, 1.0, skill)
			entries.sort_custom(func(a, b): return pace.call(a) < pace.call(b))


## Turns start data into a RaceSim. Everyone builds the same sim from the
## same start data. AI drivers are added by the caller where needed (only the
## machine that runs the AI: see AIDriver.for_all_ai in the ai module).
static func build_sim(start_data: Dictionary, cars: Dictionary, tyres: Dictionary,
		track: TrackData = null) -> RaceSim:
	var settings := RaceSettings.from_dict(start_data["settings"])
	if track == null:
		track = TrackCatalog.load_track(settings.track_id)
	var entries: Array[RaceEntry] = []
	for d in start_data["entries"]:
		entries.append(RaceEntry.from_description(d))
	return RaceSim.new(settings, track, entries, cars, tyres)
