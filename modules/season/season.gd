class_name Season
extends RefCounted
## A championship: a calendar of rounds (each its own track, laps, weather
## and start time on top of the host's base race settings), a points system,
## a fixed field of AI drivers who keep their team, car and traits all season,
## the players taking part, and every result so far. Plain data: saved as
## JSON by SeasonStore and played round by round:
##
##   var start := season.plan_next(humans, cars, seed)   # qualifying or race
##   ... run the race (RaceSession) ...
##   season.record(SeasonResults.from_race(sim, telemetry))
##
## Qualifying is "off" (the base settings' grid order), "simulated" (the
## grid is worked out from cars and driver traits, no session) or "driven"
## (a short session before each race; best lap sets the grid).

const FORMAT := 1
const QUALI_OFF := "off"
const QUALI_SIMULATED := "simulated"
const QUALI_DRIVEN := "driven"
const QUALI_LAPS := 3
const SESSION_RACE := "race"
const SESSION_QUALIFYING := "qualifying"
const DRIVERS_PER_TEAM := 2

var id: String = ""
var name: String = "Season"
var number: int = 1                 ## 1 = first season, 2 = the one after (careers moved on)...
var created: String = ""
var seed: int = 0
var base_settings: Dictionary = {}  ## RaceSettings.to_dict() every round starts from
## [{track_id, laps, weather, time_of_day_h, weather_changes}]
var rounds: Array = []
var points := PointsSystem.new()
var qualifying: String = QUALI_OFF
## AI drivers racing this season: driver dicts (as in drivers.json) with
## their team, car_id and traits. They keep all three for the whole season.
var roster: Array = []
## Every other driver (free agents and reserves): careers go on for them too.
var reserves: Array = []
## Players taking part: name -> {team, car_id}. New players can join between rounds.
var humans: Dictionary = {}
## One per finished round: {round, track_id, grid, pole_key, classification,
## fastest_key, fastest_lap, points: {key: points}}
var results: Array = []
var round_index: int = 0
## Qualifying result waiting for this round's race (driven qualifying).
var pending_quali: Dictionary = {}
## Driver market news from the end of the season before (hires, fires, rookies).
var news: Array = []


# --- Making a season ---------------------------------------------------------

## base: the host's race settings (class, AI count, difficulty, fuel, damage...).
## rounds: [{track_id, laps, weather, time_of_day_h, weather_changes}].
## drivers: every AI driver (DriverCatalog.load_all()). human_car_id: the
## host's car, so an "open" class season gives the AI that car's class.
static func create(p_name: String, base: RaceSettings, p_rounds: Array, p_points: PointsSystem,
		p_qualifying: String, drivers: Array, cars: Dictionary, human_car_id := "", p_seed := 1) -> Season:
	var s := Season.new()
	s.name = p_name.strip_edges() if p_name.strip_edges() != "" else "Season"
	s.seed = p_seed
	s.id = "%s_%d" % [_slug(s.name), absi(p_seed) % 1000000]
	s.base_settings = base.to_dict()
	s.rounds = p_rounds.duplicate(true)
	s.points = p_points
	s.qualifying = p_qualifying if p_qualifying in [QUALI_OFF, QUALI_SIMULATED, QUALI_DRIVEN] else QUALI_OFF
	s._pick_field(drivers, cars, base, human_car_id)
	return s


static func _slug(t: String) -> String:
	var out := ""
	for ch in t.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	while "__" in out:
		out = out.replace("__", "_")
	return out.trim_prefix("_").trim_suffix("_").left(24) if out.trim_prefix("_") != "" else "season"


## Whole teams race: each team enters its two best drivers in one car model,
## so team standings mean something. Teams are drawn in a seeded order until
## the grid has base.ai_count AI drivers; everyone else is a reserve.
func _pick_field(drivers: Array, cars: Dictionary, base: RaceSettings, human_car_id: String) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var teams := {}
	var team_order := []
	for d in drivers:
		var t: String = d.get("team", "")
		if t == "":
			t = "Independent"
		if not teams.has(t):
			teams[t] = []
			team_order.append(t)
		teams[t].append(d.duplicate(true))
	for t in teams:
		teams[t].sort_custom(func(a, b): return DriverCatalog.rating(a) > DriverCatalog.rating(b))
	for i in range(team_order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = team_order[i]
		team_order[i] = team_order[j]
		team_order[j] = tmp
	var classes := _ai_classes(cars, base, human_car_id)
	var want: int = base.ai_count
	var k := 0
	for t in team_order:
		var car_id := ""
		if not classes.is_empty():
			var ids := CarCatalog.ids_in_class(cars, classes[k % classes.size()])
			car_id = ids[rng.randi_range(0, ids.size() - 1)] if not ids.is_empty() else ""
		var taken := 0
		for d in teams[t]:
			d["team"] = t
			if roster.size() < want and taken < DRIVERS_PER_TEAM:
				d["car_id"] = car_id
				roster.append(d)
				taken += 1
			else:
				d.erase("car_id")
				reserves.append(d)
		if taken > 0:
			k += 1


## Which classes the AI teams' cars come from (the same rule as RaceFactory).
static func _ai_classes(cars: Dictionary, base: RaceSettings, human_car_id: String) -> Array:
	var cls := base.car_class
	if cls != "" and cls != RaceSettings.CLASS_MULTI and not CarCatalog.ids_in_class(cars, cls).is_empty():
		return [cls]
	if cls == "" and cars.has(human_car_id):
		return [cars[human_car_id].class_tag]
	return Array(CarCatalog.classes(cars))


# --- Playing it ---------------------------------------------------------------

func is_complete() -> bool:
	return round_index >= rounds.size()


func current_round() -> Dictionary:
	return {} if is_complete() else rounds[round_index]


## "qualifying" or "race": what the next session is.
func next_session() -> String:
	if is_complete():
		return ""
	return SESSION_QUALIFYING if qualifying == QUALI_DRIVEN and pending_quali.is_empty() else SESSION_RACE


## The race settings for the next session: the base settings with this
## round's track, laps, weather and time of day.
func settings_for_next() -> RaceSettings:
	var s := RaceSettings.from_dict(base_settings)
	var r: Dictionary = current_round() if not is_complete() else (rounds[-1] if not rounds.is_empty() else {})
	s.track_id = str(r.get("track_id", s.track_id))
	s.laps = int(r.get("laps", s.laps))
	var env: Dictionary = s.environment.duplicate()
	for k in ["weather", "time_of_day_h", "weather_changes"]:
		if r.has(k):
			env[k] = r[k]
	s.environment = env
	s.ai_count = roster.size()
	s.session_type = next_session() if not is_complete() else SESSION_RACE
	if s.session_type == SESSION_QUALIFYING:
		s.laps = QUALI_LAPS
		s.mandatory_pit_stops = 0
		s.safety_car_enabled = false  # yellow flags only
		s.grid_order = "random"
	return s


## Start data for the next session (RaceFactory.plan with this season's
## field), with the grid from qualifying for a race, and a "season" block
## that tells every machine which round and session this is.
## humans: as for RaceFactory.plan ([{name, car_id, tyre, crew, ...}]).
func plan_next(p_humans: Array, cars: Dictionary, p_seed: int) -> Dictionary:
	var s := settings_for_next()
	s.seed = p_seed
	for h in p_humans:
		join(str(h.get("name", "Player")), str(h.get("car_id", "")))
	var start := RaceFactory.plan(s, p_humans, cars, roster)
	if s.session_type == SESSION_RACE:
		var order: Array = []
		if qualifying == QUALI_DRIVEN:
			order = pending_quali.get("grid", [])
		elif qualifying == QUALI_SIMULATED:
			order = simulated_grid(start["entries"], cars, s)
			pending_quali = {"grid": order, "simulated": true}
		if not order.is_empty():
			_order_entries(start["entries"], order)
	var grid: Array = pending_quali.get("grid", []) if s.session_type == SESSION_RACE else []
	start["season"] = {"id": id, "name": name, "round": round_index, "rounds": rounds.size(),
		"session": s.session_type, "points": points.to_dict(), "number": number,
		"pole_key": grid[0] if not grid.is_empty() else ""}
	return start


## For the online lobby: Net.start_planner = season.plan_for_lobby.bind(cars).
## Plans the next session with the players in the lobby and saves the
## season (new players joined).
func plan_for_lobby(settings: RaceSettings, p_humans: Array, cars: Dictionary) -> Dictionary:
	var start := plan_next(p_humans, cars, settings.seed)
	SeasonStore.save(self)
	return start


## A player joins the season (or is already in it).
func join(player_name: String, car_id := "") -> void:
	if not humans.has(player_name):
		humans[player_name] = {"team": "Team " + player_name, "car_id": car_id}
	elif car_id != "":
		humans[player_name]["car_id"] = car_id


## Grid from cars and drivers without a session: car performance, driver
## pace (and wet skill in the wet) and a little luck, less for consistent drivers.
static func simulated_grid(entries: Array, cars: Dictionary, s: RaceSettings) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = s.seed ^ 0x51a11
	var weather := SimEnvironment.resolve_start_weather(s.environment, {}, s.seed)
	var wet := weather in ["light_rain", "heavy_rain"]
	var scored := []
	for d in entries:
		var c: CarDefinition = cars.get(d.get("car_id", ""))
		var car_speed := pow(c.peak_power_kw() / c.mass, 0.3) if c else 0.6
		var is_ai: bool = d.get("is_ai", false)
		var t := DriverTraits.from_dict(d.get("traits", {}) if is_ai else {"pace": 0.9, "consistency": 0.85, "wet_skill": 0.7})
		var driver := 1.0 - 0.07 * (1.0 - t.pace)
		if wet:
			driver *= 1.0 - 0.05 * (1.0 - t.wet_skill)
		var luck := rng.randfn(0.0, 0.006 * (1.4 - t.consistency))
		scored.append([car_speed * driver * (1.0 + luck), SeasonResults.key_for(is_ai, d.get("driver_name", ""))])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	return scored.map(func(x): return x[1])


## Puts the entries in grid order (keys from qualifying first; anyone who
## didn't set a time keeps their place behind them).
static func _order_entries(entries: Array, order: Array) -> void:
	var ranked := []
	for i in entries.size():
		var d: Dictionary = entries[i]
		var k := order.find(SeasonResults.key_for(d.get("is_ai", false), d.get("driver_name", "")))
		ranked.append([k if k >= 0 else 10000 + i, d])
	ranked.sort_custom(func(a, b): return a[0] < b[0])
	for i in ranked.size():
		entries[i] = ranked[i][1]


## Records a finished session (SeasonResults.from_race). Returns what it
## meant: {session, round, points: {key: n}, pole_key, grid} or {} if the
## session wasn't the one this season was waiting for.
func record(result: Dictionary, for_round := -1) -> Dictionary:
	if is_complete() or (for_round >= 0 and for_round != round_index):
		return {}
	var session: String = result.get("session", SESSION_RACE)
	if session != next_session():
		return {}
	var cls: Array = result.get("classification", [])
	if session == SESSION_QUALIFYING:
		var order := []
		for row in cls:
			order.append(row["key"])
		pending_quali = {"grid": order, "classification": cls.duplicate(true)}
		return {"session": session, "round": round_index, "grid": order, "pole_key": order[0] if not order.is_empty() else ""}
	var grid: Array = pending_quali.get("grid", [])
	var pole: String = grid[0] if not grid.is_empty() else ""
	var fastest: String = result.get("fastest_key", "")
	var pts := race_points(points, cls, fastest, pole)
	var r := current_round()
	var rec := {"round": round_index, "track_id": r.get("track_id", result.get("track_id", "")),
		"grid": grid.duplicate(), "pole_key": pole, "classification": cls.duplicate(true),
		"fastest_key": fastest, "fastest_lap": float(result.get("fastest_lap", 0.0)), "points": pts}
	results.append(rec)
	round_index += 1
	pending_quali = {}
	return {"session": session, "round": rec["round"], "points": pts, "pole_key": pole}


## Points from one race: by position (none for a DNF), plus the fastest
## lap bonus (if that driver finished high enough) and the pole bonus.
## Static so every machine online can show the same points.
static func race_points(p: PointsSystem, cls: Array, fastest_key: String, pole_key: String) -> Dictionary:
	var pts := {}
	for row in cls:
		pts[row["key"]] = 0 if row.get("dnf", false) else p.for_position(int(row["position"]), cls.size())
	if p.fastest_lap_points > 0:
		for row in cls:
			if row["key"] == fastest_key and not row.get("dnf", false) \
					and (p.fastest_lap_top <= 0 or int(row["position"]) <= p.fastest_lap_top):
				pts[fastest_key] += p.fastest_lap_points
	if p.pole_points > 0 and pts.has(pole_key):
		pts[pole_key] += p.pole_points
	return pts


# --- Standings ------------------------------------------------------------------

func team_of(key: String) -> String:
	if key.begins_with("p:"):
		return humans.get(key.substr(2), {}).get("team", "Team " + key.substr(2))
	for d in roster:
		if "ai:" + str(d.get("name", "")) == key:
			return d.get("team", "")
	return ""


## Drivers in championship order: [{key, name, team, is_ai, points, wins,
## podiums, poles, results: [position or 0 = DNF or -1 = absent, per round]}].
## Ties go to the most wins, then seconds, and so on (countback).
func driver_standings() -> Array:
	var rows := {}
	var add := func(key: String, nm: String, is_ai: bool):
		if not rows.has(key):
			rows[key] = {"key": key, "name": nm, "team": team_of(key), "is_ai": is_ai, "points": 0,
				"wins": 0, "podiums": 0, "poles": 0, "fastest_laps": 0, "results": [], "_count": {}}
	for d in roster:
		add.call("ai:" + str(d.get("name", "")), str(d.get("name", "")), true)
	for n in humans:
		add.call("p:" + n, n, false)
	for rec in results:
		var seen := {}
		for row in rec["classification"]:
			var k: String = row["key"]
			add.call(k, row["name"], row.get("is_ai", false))
			var r: Dictionary = rows[k]
			var pos := 0 if row.get("dnf", false) else int(row["position"])
			r["results"].append(pos)
			r["points"] += int(rec["points"].get(k, 0))
			if pos == 1:
				r["wins"] += 1
			if pos >= 1 and pos <= 3:
				r["podiums"] += 1
			if pos > 0:
				r["_count"][pos] = int(r["_count"].get(pos, 0)) + 1
			seen[k] = true
		if rows.has(rec.get("pole_key", "")):
			rows[rec["pole_key"]]["poles"] += 1
		if rows.has(rec.get("fastest_key", "")):
			rows[rec["fastest_key"]]["fastest_laps"] += 1
		for k in rows:
			if not seen.has(k):
				rows[k]["results"].append(-1)
	var out: Array = rows.values()
	out.sort_custom(func(a, b) -> bool:
		if a["points"] != b["points"]:
			return a["points"] > b["points"]
		for p in range(1, 60):
			var ca: int = a["_count"].get(p, 0)
			var cb: int = b["_count"].get(p, 0)
			if ca != cb:
				return ca > cb
		return a["name"] < b["name"])
	for r in out:
		r.erase("_count")
	return out


## Teams in championship order: [{team, points, wins, drivers: [names]}].
func team_standings() -> Array:
	var rows := {}
	for d in driver_standings():
		var t: String = d["team"]
		if not rows.has(t):
			rows[t] = {"team": t, "points": 0, "wins": 0, "drivers": [], "best": 1000}
		rows[t]["points"] += d["points"]
		rows[t]["wins"] += d["wins"]
		rows[t]["drivers"].append(d["name"])
		for p in d["results"]:
			if p > 0:
				rows[t]["best"] = mini(rows[t]["best"], p)
	var out: Array = rows.values()
	out.sort_custom(func(a, b) -> bool:
		if a["points"] != b["points"]:
			return a["points"] > b["points"]
		if a["wins"] != b["wins"]:
			return a["wins"] > b["wins"]
		if a["best"] != b["best"]:
			return a["best"] < b["best"]
		return a["team"] < b["team"])
	return out


## The leader once every round is done ({} before then).
func champion() -> Dictionary:
	if not is_complete():
		return {}
	var st := driver_standings()
	return st[0] if not st.is_empty() else {}


## Small summary for the lobby and menus (also sent to every player online).
func summary(rows := 8) -> Dictionary:
	var drivers := []
	for d in driver_standings().slice(0, rows):
		drivers.append({"name": d["name"], "team": d["team"], "points": d["points"], "is_ai": d["is_ai"]})
	var teams := []
	for t in team_standings().slice(0, rows):
		teams.append({"team": t["team"], "points": t["points"]})
	var r := current_round()
	return {"id": id, "name": name, "number": number, "round": round_index, "rounds": rounds.size(),
		"complete": is_complete(), "next_session": next_session(), "next_track_id": r.get("track_id", ""),
		"next_laps": int(r.get("laps", 0)), "next_weather": r.get("weather", "dry"),
		"points_name": points.display_name(), "qualifying": qualifying,
		"champion": champion().get("name", ""), "drivers": drivers, "teams": teams}


# --- Next season ------------------------------------------------------------------

## The season after this one: same calendar, rules and players; a year on
## for every AI driver (they improve or decline, the oldest retire), and the
## driver market (teams drop drivers who scored poorly and sign free agents
## or rookies). What happened is in the new season's news.
func next_season(p_seed: int) -> Season:
	var s := Season.new()
	s.name = name
	s.number = number + 1
	s.seed = p_seed
	s.id = "%s_%d" % [_slug(name), absi(p_seed) % 1000000]
	s.base_settings = base_settings.duplicate(true)
	s.rounds = rounds.duplicate(true)
	s.points = PointsSystem.from_dict(points.to_dict())
	s.qualifying = qualifying
	s.humans = humans.duplicate(true)
	var moved := SeasonCareers.advance(self, p_seed)
	s.roster = moved["roster"]
	s.reserves = moved["reserves"]
	s.news = moved["news"]
	return s


# --- Saving ------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {"format": FORMAT, "id": id, "name": name, "number": number, "created": created, "seed": seed,
		"base_settings": base_settings, "rounds": rounds, "points": points.to_dict(), "qualifying": qualifying,
		"roster": roster, "reserves": reserves, "humans": humans, "results": results,
		"round_index": round_index, "pending_quali": pending_quali, "news": news}


static func from_dict(d: Dictionary) -> Season:
	var s := Season.new()
	s.id = str(d.get("id", "season"))
	s.name = str(d.get("name", "Season"))
	s.number = int(d.get("number", 1))
	s.created = str(d.get("created", ""))
	s.seed = int(d.get("seed", 0))
	s.base_settings = d.get("base_settings", {})
	s.rounds = d.get("rounds", [])
	s.points = PointsSystem.from_dict(d.get("points", {}))
	s.qualifying = str(d.get("qualifying", QUALI_OFF))
	s.roster = d.get("roster", [])
	s.reserves = d.get("reserves", [])
	s.humans = d.get("humans", {})
	s.results = d.get("results", [])
	s.round_index = int(d.get("round_index", 0))
	s.pending_quali = d.get("pending_quali", {})
	s.news = d.get("news", [])
	# JSON gives every number back as a float: positions and points are ints.
	for rec in s.results:
		rec["round"] = int(rec.get("round", 0))
		for row in rec.get("classification", []):
			row["position"] = int(row.get("position", 0))
			row["laps"] = int(row.get("laps", 0))
		var pts: Dictionary = rec.get("points", {})
		for k in pts:
			pts[k] = int(pts[k])
	for r in s.rounds:
		r["laps"] = int(r.get("laps", 3))
	return s
