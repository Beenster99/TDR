class_name HudLayout
extends RefCounted
## The driver's own race HUD layout: where each HUD item sits, how big it is
## and whether it's shown. Edited in the HUD layout editor (HudEditor) and
## saved in GameData.prefs["hud_layout"] as
##   {item_id: {"x": 0..1, "y": 0..1, "s": scale, "on": bool}}
## x and y say where the item sits in the space left around it: 0 is hard
## against the left (top) edge, 1 against the right (bottom) edge and 0.5
## centred, so the layout fits any screen shape and an item on an edge stays
## on that edge. A missing key means "as designed": the item's own spot,
## 100 % size, shown.

const PREF := "hud_layout"
const MIN_SCALE := 0.5
const MAX_SCALE := 2.0

var items: Dictionary = {}


static func from_value(v) -> HudLayout:
	var l := HudLayout.new()
	if v is Dictionary:
		for id in v:
			if v[id] is Dictionary:
				l.items[str(id)] = (v[id] as Dictionary).duplicate()
	return l


## A copy for saving (prefs), with items left as designed dropped.
func to_value() -> Dictionary:
	var out := {}
	for id in items:
		if not (items[id] as Dictionary).is_empty():
			out[id] = (items[id] as Dictionary).duplicate()
	return out


func copy() -> HudLayout:
	return HudLayout.from_value(to_value())


func _item(id: String) -> Dictionary:
	if not items.has(id):
		items[id] = {}
	return items[id]


func has_pos(id: String) -> bool:
	return items.has(id) and items[id].has("x") and items[id].has("y")


func pos(id: String) -> Vector2:
	if not has_pos(id):
		return Vector2(-1, -1)
	return Vector2(float(items[id]["x"]), float(items[id]["y"]))


func set_pos(id: String, frac: Vector2) -> void:
	var it := _item(id)
	it["x"] = clampf(frac.x, 0.0, 1.0)
	it["y"] = clampf(frac.y, 0.0, 1.0)


func scale_of(id: String) -> float:
	return clampf(float(items[id].get("s", 1.0)), MIN_SCALE, MAX_SCALE) if items.has(id) else 1.0


func set_scale(id: String, s: float) -> void:
	s = clampf(snappedf(s, 0.01), MIN_SCALE, MAX_SCALE)
	if absf(s - 1.0) < 0.001:
		_item(id).erase("s")
	else:
		_item(id)["s"] = s


func is_on(id: String) -> bool:
	return bool(items[id].get("on", true)) if items.has(id) else true


func set_on(id: String, on: bool) -> void:
	if on:
		_item(id).erase("on")
	else:
		_item(id)["on"] = false


## Back to as designed: its own spot and size (shown or hidden stays).
func reset(id: String) -> void:
	if not items.has(id):
		return
	var on := is_on(id)
	items[id] = {}
	set_on(id, on)


func reset_all() -> void:
	items.clear()


## Top-left corner of an item of `size` placed at `frac` on a `vp` screen.
static func place(frac: Vector2, size: Vector2, vp: Vector2) -> Vector2:
	return (vp - size) * frac.clamp(Vector2.ZERO, Vector2.ONE)


## The inverse of place(): where a top-left corner sits as a fraction.
static func frac_of(top_left: Vector2, size: Vector2, vp: Vector2) -> Vector2:
	var room := vp - size
	return Vector2(top_left.x / room.x if room.x > 0.5 else 0.5,
		top_left.y / room.y if room.y > 0.5 else 0.5).clamp(Vector2.ZERO, Vector2.ONE)
