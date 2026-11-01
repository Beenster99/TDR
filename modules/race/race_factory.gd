class_name RaceFactory
extends RefCounted
## Builds races in two steps so server and clients construct identical sims:
##  1. plan()  - host only: picks AI drivers/cars from the seed, returns
##               "start data" (plain Dictionary, sent to every client).
##  2. build_sim() - everyone: turns start data into a RaceSim.
## The AI drivers live in the ai module, which builds on this one.

## humans: [{ "name": String, "car_id": String, "crew": [{peer_id, name, role}] }]
static func plan(settings: RaceSettings, humans: Array, cars: Dictionary, drivers: Array) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = settings.seed
	var car_ids: Array = cars.keys()
	car_ids.sort()
	var entries := []
	var pool := drivers.duplicate()
	# AI fill the front of the grid, humans start behind (wave 2: qualifying).
	for k in settings.ai_count:
		var e := RaceEntry.new()
		e.is_ai = true
		if pool.is_empty():
			e.driver_name = "AI %d" % (k + 1)
			e.traits = {"skill": 0.9, "consistency": 0.9}
		else:
			var d: Dictionary = pool.pop_at(rng.randi_range(0, pool.size() - 1))
			e.driver_name = d.get("name", "AI")
			e.traits = d.get("traits", {})
		e.car_id = car_ids[rng.randi_range(0, car_ids.size() - 1)]
		entries.append(e.describe())
	for h in humans:
		var e := RaceEntry.new()
		e.driver_name = h.get("name", "Player")
		e.car_id = h.get("car_id", "") if cars.has(h.get("car_id", "")) else car_ids[0]
		e.crew = h.get("crew", [{"peer_id": 0, "name": e.driver_name, "role": RaceEntry.ROLE_DRIVER}])
		entries.append(e.describe())
	return {"settings": settings.to_dict(), "entries": entries}


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
