class_name RaceFactory
extends RefCounted
## Builds races in two steps so server and clients construct identical sims:
##  1. plan()  - host only: picks AI drivers/cars from the seed, returns
##               "start data" (plain Dictionary, sent to every client).
##  2. build_sim() - everyone: turns start data into a RaceSim.
## The AI drivers live in the ai module, which builds on this one.

## humans: [{ "name": String, "car_id": String, "tyre": String, "crew": [{peer_id, name, role}] }]
## tyre: "auto" (match the start weather), "dry", "intermediate" or "wet".
static func plan(settings: RaceSettings, humans: Array, cars: Dictionary, drivers: Array) -> Dictionary:
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
	# Standard grid: AI fill the front, humans start behind.
	for k in settings.ai_count:
		var e := RaceEntry.new()
		e.is_ai = true
		if pool.is_empty():
			e.driver_name = "AI %d" % (k + 1)
			e.traits = {"pace": 0.9, "consistency": 0.9}
		else:
			var d: Dictionary = pool.pop_at(rng.randi_range(0, pool.size() - 1))
			e.driver_name = d.get("name", "AI")
			e.traits = d.get("traits", {})
		var in_class: Array = CarCatalog.ids_in_class(cars, ai_classes[k % ai_classes.size()])
		e.car_id = in_class[rng.randi_range(0, in_class.size() - 1)]
		_fit_tyres(e, "auto", start_weather)
		entries.append(e.describe())
	for k in humans.size():
		var h: Dictionary = humans[k]
		var e := RaceEntry.new()
		e.driver_name = h.get("name", "Player")
		e.car_id = human_cars[k]
		e.crew = h.get("crew", [{"peer_id": 0, "name": e.driver_name, "role": RaceEntry.ROLE_DRIVER}])
		_fit_tyres(e, h.get("tyre", "auto"), start_weather)
		entries.append(e.describe())
	_order_grid(entries, settings.grid_order, cars, rng)
	return {"settings": settings.to_dict(), "entries": entries}


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
