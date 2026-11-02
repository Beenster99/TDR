class_name TrackCatalog
extends RefCounted
## The circuits in the game, read from modules/tracks/data/*.json (made with
## tools/import_tumftm_track.py). Adding a track is adding a JSON file there.

const DIR := "res://modules/tracks/data"


## Light list for menus, sorted by name:
## [{id, name, short_name, location, country, description, length_m,
##   has_pit_lane, outline, outline_height, pit_outline, sectors, climb_m,
##   discipline ("circuit" / "rallycross" / "derby"), dirt, joker_outline,
##   joker_length_m, crossovers, jumps, dirt_m}]
## outline: the centre line in race order (index 0 on the start line), cut to
## about OUTLINE_POINTS points, in metres (x right, y down, as seen from
## above in the game); outline_height: the height at each of those points
## (empty when the track has no elevation); pit_outline: the pit lane path;
## climb_m: highest minus lowest point of the lap; discipline: "circuit",
## "rallycross" or "derby"; dirt: loose stretches of the lap [[s_from, s_to]];
## joker_outline: the rallycross joker lane (empty when there is none).
static func list_all() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in JsonData.dicts_in(DIR):
		var o := _outline(d)
		out.append({"id": d.get("id", ""), "name": d.get("name", ""),
			"crossovers": d.get("crossovers", []).size(), "jumps": d.get("jumps", []).size(),
			"dirt_m": _dirt_m(d),
			"short_name": d.get("short_name", d.get("name", "")),
			"location": d.get("location", ""), "country": d.get("country", ""),
			"description": d.get("description", ""),
			"length_m": d.get("length_m", 0.0),
			"has_pit_lane": d.get("pit_lane") is Dictionary,
			"outline": o["points"], "outline_height": o["height"], "pit_outline": o["pit"],
			"sectors": d.get("sectors", [0.0, 0.333, 0.667]), "climb_m": o["climb"],
			"discipline": str(d.get("discipline", "circuit")), "dirt": d.get("dirt", []),
			"joker_outline": o["joker"], "joker_length_m": (d["joker"] as Dictionary).get("length_m", 0.0) if d.get("joker") is Dictionary else 0.0})
	out.sort_custom(func(a, b): return a["name"] < b["name"])
	return out


static func _dirt_m(d: Dictionary) -> float:
	var m := 0.0
	for r in d.get("dirt", []):
		m += float(r[1]) - float(r[0])
	return m


const OUTLINE_POINTS := 360


static func _outline(d: Dictionary) -> Dictionary:
	var pts := PackedVector2Array()
	var hs := PackedFloat32Array()
	var pit := PackedVector2Array()
	var cl: Array = d.get("centerline", [])
	var n := cl.size()
	var e = d.get("elevation")
	var heights: Array = e.get("height_m", []) if e is Dictionary else []
	var start := int(d.get("start_index", 0))
	var step := maxi(1, n / OUTLINE_POINTS)
	var lo := INF
	var hi := -INF
	for k in range(0, n, step):
		var i := (k + start) % n
		pts.append(Vector2(float(cl[i][0]), float(cl[i][1])))
		if heights.size() == n:
			hs.append(float(heights[i]))
	for h in heights:
		lo = minf(lo, float(h))
		hi = maxf(hi, float(h))
	var pl = d.get("pit_lane")
	if pl is Dictionary:
		var path: Array = pl.get("path", [])
		var ps := maxi(1, path.size() / 60)
		for k in range(0, path.size(), ps):
			pit.append(Vector2(float(path[k][0]), float(path[k][1])))
		if not path.is_empty():
			pit.append(Vector2(float(path[-1][0]), float(path[-1][1])))
	var joker := PackedVector2Array()
	var jk = d.get("joker")
	if jk is Dictionary:
		var jpath: Array = jk.get("path", [])
		var js := maxi(1, jpath.size() / 60)
		for k in range(0, jpath.size(), js):
			joker.append(Vector2(float(jpath[k][0]), float(jpath[k][1])))
		if not jpath.is_empty():
			joker.append(Vector2(float(jpath[-1][0]), float(jpath[-1][1])))
	return {"points": pts, "height": hs, "pit": pit, "joker": joker, "climb": hi - lo if hi >= lo else 0.0}


## Ids of the tracks for one kind of racing ("circuit", "rallycross", "derby").
static func ids_for(tracks: Array, discipline: String) -> Array[String]:
	var out: Array[String] = []
	for t in tracks:
		if str(t.get("discipline", "circuit")) == discipline:
			out.append(str(t["id"]))
	return out


static func load_track(id: String) -> TrackData:
	var d = JsonData.load_json("%s/%s.json" % [DIR, id])
	return TrackData.from_dict(d) if d is Dictionary else null
