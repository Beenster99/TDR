class_name TrackMap
extends Control
## A circuit seen from above for the race setup pages: the lap coloured by
## sector, the pit lane, the start line with an arrow for the direction of
## travel, and the height profile of the lap along the bottom. Drawn as
## vectors, so it's sharp at any resolution.

const SECTOR_COLOURS := [Color(0.96, 0.33, 0.27), Color(0.27, 0.72, 0.98), Color(0.99, 0.8, 0.25)]
const PROFILE_H := 40.0

var _info: Dictionary = {}
## Draw the height profile under the map (off where space is short).
var show_profile := true:
	set(v):
		show_profile = v
		queue_redraw()


## info: a GameData.tracks entry (TrackCatalog.list_all).
const DIRT_COLOUR := Color(0.72, 0.52, 0.3)
const JOKER_COLOUR := Color(1.0, 0.62, 0.15)


func show_track(info: Dictionary) -> void:
	_info = info
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.07, 0.85))
	var pts: PackedVector2Array = _info.get("outline", PackedVector2Array())
	if pts.size() < 3:
		return
	var hs: PackedFloat32Array = _info.get("outline_height", PackedFloat32Array())
	var has_profile := show_profile and hs.size() == pts.size() and float(_info.get("climb_m", 0.0)) > 0.5
	var area := Rect2(Vector2(18, 16), size - Vector2(36, 32 + (PROFILE_H + 26.0 if has_profile else 0.0)))
	var pit: PackedVector2Array = _info.get("pit_outline", PackedVector2Array())
	var bounds := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		bounds = bounds.expand(p)
	for p in pit:
		bounds = bounds.expand(p)
	var joker: PackedVector2Array = _info.get("joker_outline", PackedVector2Array())
	for p in joker:
		bounds = bounds.expand(p)
	var k := minf(area.size.x / maxf(bounds.size.x, 1.0), area.size.y / maxf(bounds.size.y, 1.0))
	var off := area.position + (area.size - bounds.size * k) * 0.5 - bounds.position * k
	var map := func(p: Vector2) -> Vector2: return p * k + off
	var screen := PackedVector2Array()
	for p in pts:
		screen.append(map.call(p))
	# Pit lane under the track.
	if pit.size() >= 2:
		var ps := PackedVector2Array()
		for p in pit:
			ps.append(map.call(p))
		draw_polyline(ps, Color(0.55, 0.58, 0.62, 0.9), 2.5, true)
	# Dark edge, then the lap in its three sector colours.
	var closed := screen.duplicate()
	closed.append(screen[0])
	draw_polyline(closed, Color(0, 0, 0, 0.75), 9.0, true)
	draw_polyline(closed, Color(0.86, 0.88, 0.9), 6.0, true)
	var sectors: Array = _info.get("sectors", [0.0, 0.333, 0.667])
	var n := screen.size()
	var dirt: Array = _info.get("dirt", [])
	if str(_info.get("discipline", "circuit")) == "rallycross":
		# Rallycross: the lap by surface (tarmac grey, dirt brown) and the
		# joker lane in orange, instead of sector colours.
		sectors = []
		var L := maxf(float(_info.get("length_m", 1.0)), 1.0)
		for r in dirt:
			var a := int(float(r[0]) / L * n)
			var b := int(float(r[1]) / L * n)
			if b < a:
				b += n
			var seg := PackedVector2Array()
			for i in range(a, b + 1):
				seg.append(screen[i % n])
			if seg.size() >= 2:
				draw_polyline(seg, DIRT_COLOUR, 4.2, true)
		if joker.size() >= 2:
			var js := PackedVector2Array()
			for p in joker:
				js.append(map.call(p))
			draw_polyline(js, Color(0, 0, 0, 0.75), 7.0, true)
			draw_polyline(js, JOKER_COLOUR, 3.6, true)
			var mid := js[js.size() / 2]
			draw_string(ThemeDB.fallback_font, mid + Vector2(8, -6), "JOKER", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, JOKER_COLOUR)
	for si in sectors.size():
		var a := int(float(sectors[si]) * n)
		var b := int(float(sectors[si + 1]) * n) if si + 1 < sectors.size() else n
		var seg := PackedVector2Array()
		for i in range(a, b + 1):
			seg.append(screen[i % n])
		if seg.size() >= 2:
			draw_polyline(seg, SECTOR_COLOURS[si % SECTOR_COLOURS.size()], 3.6, true)
	# Start line across the track, and an arrow showing the way round.
	var dir := (screen[mini(3, n - 1)] - screen[0]).normalized()
	var nrm := Vector2(-dir.y, dir.x)
	draw_line(screen[0] - nrm * 9.0, screen[0] + nrm * 9.0, Color.WHITE, 4.0, true)
	draw_line(screen[0] - nrm * 9.0, screen[0] + nrm * 9.0, Color.BLACK, 1.5, true)
	var tip := screen[mini(maxi(n / 30, 4), n - 1)]
	var ad := (tip - screen[mini(maxi(n / 30, 4) - 2, n - 1)]).normalized()
	var an := Vector2(-ad.y, ad.x)
	tip += an * 14.0
	draw_colored_polygon(PackedVector2Array([tip + ad * 8.0, tip - ad * 5.0 + an * 6.0, tip - ad * 5.0 - an * 6.0]), Color.WHITE)
	# Height profile along the lap.
	if has_profile:
		var r := Rect2(Vector2(18, size.y - PROFILE_H - 14), Vector2(size.x - 36, PROFILE_H))
		var lo := INF
		var hi := -INF
		for h in hs:
			lo = minf(lo, h)
			hi = maxf(hi, h)
		var span := maxf(hi - lo, 1.0)
		var poly := PackedVector2Array([r.position + Vector2(0, r.size.y)])
		var line := PackedVector2Array()
		for i in hs.size():
			var q := r.position + Vector2(r.size.x * i / float(hs.size() - 1), r.size.y * (1.0 - (hs[i] - lo) / span) * 0.85 + r.size.y * 0.15)
			poly.append(q)
			line.append(q)
		poly.append(r.position + r.size)
		draw_colored_polygon(poly, Color(0.35, 0.6, 0.4, 0.35))
		draw_polyline(line, Color(0.6, 0.9, 0.65), 1.5, true)
		var font := get_theme_font("font")
		draw_string(font, r.position + Vector2(0, -5), "Height over the lap  ·  %d m from lowest to highest" % roundi(float(_info["climb_m"])),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.6))
