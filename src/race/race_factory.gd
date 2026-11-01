class_name RaceFactory
extends RefCounted
## Builds races in two steps so server and clients construct identical sims:
##  1. plan()  - host only: picks AI drivers/cars from the seed, returns
##               "start data" (plain Dictionary, sent to every client).
##  2. build() - everyone: turns start data into a RaceSim (+ AI on the
##               authority only).

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


## Returns { "sim": RaceSim, "ai": { car_index: AIDriver } }. AI is only
## created when with_ai is true (server / offline), clients just mirror.
static func build(start_data: Dictionary, cars: Dictionary, tyres: Dictionary, with_ai: bool,
		track: TrackData = null) -> Dictionary:
	var settings := RaceSettings.from_dict(start_data["settings"])
	if track == null:
		track = DataLoader.load_track(settings.track_id)
	var entries: Array[RaceEntry] = []
	for d in start_data["entries"]:
		entries.append(RaceEntry.from_description(d))
	var sim := RaceSim.new(settings, track, entries, cars, tyres)
	var ai := {}
	if with_ai:
		for i in entries.size():
			if entries[i].is_ai:
				ai[i] = make_ai(sim, i)
	return {"sim": sim, "ai": ai}


static func make_ai(sim: RaceSim, i: int) -> AIDriver:
	var traits := sim.entries[i].traits
	if traits.is_empty():
		traits = {"skill": 0.9, "consistency": 0.9}
	return AIDriver.new(sim.track, sim.defs[i], sim.compounds[i], traits, sim.settings.seed * 31 + i)


## Convenience for tests / offline: plan + build in one go.
static func create(settings: RaceSettings, humans: Array, cars: Dictionary, tyres: Dictionary,
		drivers: Array, track: TrackData = null) -> Dictionary:
	return build(plan(settings, humans, cars, drivers), cars, tyres, true, track)
