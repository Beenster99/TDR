class_name SeasonCareers
extends RefCounted
## What happens to AI drivers between seasons: everyone gets a year older,
## young drivers grow towards their potential, older ones slowly fade and
## the oldest retire. Then the driver market: a team whose driver finished
## in the bottom third of the championship may drop them and sign the best
## free agent, or a rookie with high potential. Seeded, so a saved season
## always moves on the same way.

const RETIRE_AGE := 39
const GROWTH_AGE := 27     ## younger than this: still improving
const DECLINE_AGE := 33    ## older than this: losing a little each year
const DROP_CHANCE := 0.6   ## chance a team drops a driver in the bottom third
const SKILLS := ["pace", "consistency", "overtaking", "defending", "tyre_management", "wet_skill", "composure"]

const FIRST_NAMES := ["Aiden", "Bea", "Caio", "Dara", "Emil", "Freya", "Gus", "Hana", "Ivo", "Jun",
	"Kai", "Lena", "Milo", "Nia", "Oren", "Pia", "Quin", "Rhea", "Sami", "Tove", "Uma", "Vik", "Wren",
	"Xavi", "Yara", "Zeno"]
const LAST_NAMES := ["Achter", "Brandt", "Castell", "Dorn", "Esposito", "Falk", "Gallo", "Hollis",
	"Ilves", "Juarez", "Kovac", "Lindqvist", "Moreau", "Nakai", "Okafor", "Petrov", "Quaid", "Rossi",
	"Sato", "Tanner", "Ueda", "Varga", "Weller", "Yilmaz", "Zarate"]
const NATIONS := ["GB", "DE", "IT", "FR", "ES", "NL", "BR", "JP", "AU", "US", "MX", "SE", "FI", "BE"]


## Returns {roster, reserves, news} for the season after `old`.
static func advance(old: Season, p_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed ^ 0xca5ee5
	var news := []
	var standings := old.driver_standings()
	var place := {}
	for i in standings.size():
		place[standings[i]["key"]] = i
	var field := standings.size()
	var roster := []
	var free := []
	# A year on for everyone.
	for d in old.roster + old.reserves:
		var nd: Dictionary = d.duplicate(true)
		nd["age"] = int(nd.get("age", 28)) + 1
		_develop(nd, rng)
		if int(nd["age"]) >= RETIRE_AGE:
			news.append("%s retires at %d." % [nd.get("name", "?"), nd["age"]])
			continue
		if old.roster.has(d):
			roster.append(nd)
		else:
			free.append(nd)
	# Seats where the driver retired go to the market too.
	var open_seats := []
	for d in old.roster:
		if int(d.get("age", 28)) + 1 >= RETIRE_AGE:
			open_seats.append({"team": d.get("team", ""), "car_id": d.get("car_id", ""), "retired": d.get("name", "")})
	# Teams drop drivers who finished in the bottom third.
	var kept := []
	for d in roster:
		var p: int = place.get("ai:" + str(d.get("name", "")), 0)
		if field >= 6 and p >= field * 2.0 / 3.0 and rng.randf() < DROP_CHANCE:
			open_seats.append({"team": d.get("team", ""), "car_id": d.get("car_id", ""), "dropped": d.get("name", "")})
			d.erase("car_id")
			free.append(d)
		else:
			kept.append(d)
	roster = kept
	# Fill the seats: best value first (rating now, plus what they could become).
	for seat in open_seats:
		free.sort_custom(func(a, b): return _value(a) > _value(b))
		var signing: Dictionary
		var rookie := false
		var best_free: Dictionary = free[0] if not free.is_empty() else {}
		if best_free.is_empty() or rng.randf() < 0.3 or best_free.get("name", "") == seat.get("dropped", ""):
			signing = _rookie(rng, roster + free)
			rookie = true
		else:
			signing = best_free
			free.erase(best_free)
		signing["team"] = seat["team"]
		signing["car_id"] = seat["car_id"]
		roster.append(signing)
		var line := ""
		if seat.has("dropped"):
			line = "%s drop %s. " % [seat["team"], seat["dropped"]]
		elif seat.has("retired"):
			line = "To replace %s, " % seat["retired"]
		if rookie:
			line += "%s sign rookie %s (%d, %s)." % [seat["team"], signing["name"], signing["age"], signing.get("nationality", "")]
		else:
			line += "%s sign %s." % [seat["team"], signing["name"]]
		news.append(line)
	if news.is_empty():
		news.append("No driver changes: every team keeps its line-up.")
	return {"roster": roster, "reserves": free, "news": news}


## How much a team wants a driver.
static func _value(d: Dictionary) -> float:
	var r := DriverCatalog.rating(d) / 100.0
	var pot := float(d.get("potential", r))
	var young := 1.0 if int(d.get("age", 28)) < GROWTH_AGE else 0.0
	return r * 0.75 + pot * 0.25 * (0.6 + 0.4 * young)


## A year's change in skill: growth towards potential when young, a small
## decline when old. Aggression is a style and doesn't change.
static func _develop(d: Dictionary, rng: RandomNumberGenerator) -> void:
	var age: int = d.get("age", 28)
	var t: Dictionary = d.get("traits", {}).duplicate()
	var pot := float(d.get("potential", 0.9))
	for k in SKILLS:
		var v := float(t.get(k, 0.7))
		if age < GROWTH_AGE and pot > v:
			v += (pot - v) * rng.randf_range(0.1, 0.35)
		elif age > DECLINE_AGE:
			v -= 0.006 * (age - DECLINE_AGE) * rng.randf_range(0.5, 1.5)
		t[k] = snappedf(clampf(v, 0.3, 1.0), 0.001)
	d["traits"] = t


static func _rookie(rng: RandomNumberGenerator, taken: Array) -> Dictionary:
	var names := {}
	for d in taken:
		names[d.get("name", "")] = true
	var nm := ""
	for _i in 50:
		nm = "%s %s" % [FIRST_NAMES[rng.randi_range(0, FIRST_NAMES.size() - 1)], LAST_NAMES[rng.randi_range(0, LAST_NAMES.size() - 1)]]
		if not names.has(nm):
			break
	var pot := rng.randf_range(0.82, 0.99)
	var base := rng.randf_range(0.72, 0.84)
	var traits := {"aggression": snappedf(rng.randf_range(0.4, 0.9), 0.01)}
	for k in SKILLS:
		traits[k] = snappedf(clampf(base + rng.randf_range(-0.08, 0.08), 0.4, pot), 0.01)
	return {"id": nm.to_lower().replace(" ", "_"), "name": nm, "number": rng.randi_range(2, 99),
		"nationality": NATIONS[rng.randi_range(0, NATIONS.size() - 1)], "age": rng.randi_range(18, 20),
		"style": "rookie", "potential": snappedf(pot, 0.01), "traits": traits, "rookie": true}
