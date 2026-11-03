class_name PanelLayout
extends RefCounted
## Movable, scalable panels on the pit wall screens (CrewConsole and
## StrategistScreen). Drag a panel by its title bar (the top strip; the whole
## picture for the onboard camera) to move it. Drag the grip in its bottom
## right corner to scale it: the whole panel, text included, gets bigger or
## smaller, so the data is easier to read. Drag its right or bottom edge to
## make it wider or taller without changing the text size. Panels snap to the
## screen edges and to each other. A press on the title bar that doesn't move
## is still a click, so the buttons up there keep working.
##
## Saved in GameData.prefs["pit_wall_layout"] as
##   {screen: {panel_id: {"x": 0..1, "y": 0..1, "w": px, "h": px, "s": scale}}}
## x and y say where the panel sits in the room left around it inside the
## screen's bounds (0 against the left / top, 1 against the right / bottom),
## so a layout fits any screen shape. w and h are its size on screen in the
## 1600x900 canvas; s (1 if missing) how much its contents are scaled, so
## they're laid out in w / s by h / s. A panel with no entry sits where it
## was designed to.

const PREF := "pit_wall_layout"
const GRAB_H := 28.0        ## title bar height that moves a panel
const GRIP := 16.0          ## resize grip size, bottom right
const SNAP := 10.0          ## snap distance to edges
const GAP := 12.0           ## gap kept when snapping next to another panel
const DRAG_START := 5.0     ## pixels before a press on the title bar becomes a drag
const EDGE := 6.0           ## width of the right and bottom edges that resize
const MIN_SCALE := 0.6
const MAX_SCALE := 2.0

var screen := ""
## panel id -> {"x", "y", "w", "h", "s"}
var saved: Dictionary = {}
## panel id -> {"min": Vector2, "max": Vector2, "aspect": float, "grab_all": bool}
var specs: Dictionary = {}
## The panels as last placed this frame, in draw order: [[id, Rect2]].
var placed: Array = []
var bounds := Rect2()

var _press_id := ""
var _press_mode := ""       ## "move", "scale", "size", "size_x" or "size_y"
var _press_pos := Vector2.ZERO
var _press_rect := Rect2()
var _press_scale := 1.0
var dragging := false
## Save to GameData.prefs when a drag ends (off in tests).
var autosave := true


func _init(p_screen := "") -> void:
	screen = p_screen


## Declares a panel: its smallest and biggest size (canvas pixels), a fixed
## width / height ratio (0 = free) and whether the whole panel grabs (for the
## onboard picture, which has nothing to click).
func spec(id: String, min_size: Vector2, max_size := Vector2(4000, 4000), aspect := 0.0, grab_all := false) -> void:
	specs[id] = {"min": min_size, "max": max_size, "aspect": aspect, "grab_all": grab_all}


func load_from(prefs: Dictionary) -> void:
	saved.clear()
	var all = prefs.get(PREF, {})
	if all is Dictionary and all.get(screen) is Dictionary:
		for id in all[screen]:
			var v = all[screen][id]
			if v is Dictionary and v.has_all(["x", "y", "w", "h"]):
				saved[str(id)] = {"x": float(v["x"]), "y": float(v["y"]), "w": float(v["w"]), "h": float(v["h"])}
				if v.has("s"):
					saved[str(id)]["s"] = clampf(float(v["s"]), MIN_SCALE, MAX_SCALE)


## Writes this screen's layout into prefs (the caller saves them).
func store_in(prefs: Dictionary) -> void:
	var all: Dictionary = (prefs.get(PREF) as Dictionary).duplicate(true) if prefs.get(PREF) is Dictionary else {}
	if saved.is_empty():
		all.erase(screen)
	else:
		all[screen] = saved.duplicate(true)
	prefs[PREF] = all


func save() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var gd: Node = tree.root.get_node_or_null("/root/GameData") if tree else null
	if gd:
		store_in(gd.prefs)
		gd.save_prefs()


func is_moved(id: String) -> bool:
	return saved.has(id)


## How much panel id's contents are scaled (1 = as designed).
func scale_of(id: String) -> float:
	return float(saved[id].get("s", 1.0)) if saved.has(id) else 1.0


## Panels whose contents scale (not the onboard picture, which just resizes).
func scalable(id: String) -> bool:
	var sp: Dictionary = specs.get(id, {})
	return not bool(sp.get("grab_all", false)) and float(sp.get("aspect", 0.0)) <= 0.0


## The rect a scaled panel's contents are laid out in: r's top left corner,
## its size divided by the scale. Drawn with draw_transform(r, s).
func content_rect(id: String, r: Rect2) -> Rect2:
	return Rect2(r.position, r.size / scale_of(id))


func customised() -> bool:
	return not saved.is_empty()


func reset_all() -> void:
	saved.clear()
	_press_id = ""
	dragging = false


## Starts a frame's placing (call before the first rect_of of a draw).
func begin(p_bounds: Rect2) -> void:
	bounds = p_bounds
	placed.clear()


## Where panel `id` goes: its saved spot, or `default` if it was never moved.
## Kept inside the bounds and within its size limits.
func rect_of(id: String, default: Rect2, p_bounds := Rect2()) -> Rect2:
	var b := p_bounds if p_bounds.has_area() else bounds
	var r := Rect2(default.position, default.size.max(Vector2.ZERO))
	if saved.has(id):
		var s: Dictionary = saved[id]
		var sz := _fit_size(id, Vector2(s["w"], s["h"]), b, float(s.get("s", 1.0)))
		r = Rect2(b.position + (b.size - sz) * Vector2(s["x"], s["y"]).clamp(Vector2.ZERO, Vector2.ONE), sz)
	return r


## rect_of, and remembers it for dragging (in draw order: later is on top).
func place(id: String, default: Rect2) -> Rect2:
	var r := rect_of(id, default)
	for k in placed.size():
		if placed[k][0] == id:
			placed.remove_at(k)
			break
	placed.append([id, r])
	return r


## Size limits scale with the contents: a panel at 150 % needs 150 % of its
## smallest size to fit them.
func _fit_size(id: String, sz: Vector2, b: Rect2, sc := 1.0) -> Vector2:
	var sp: Dictionary = specs.get(id, {"min": Vector2(60, 40), "max": Vector2(4000, 4000), "aspect": 0.0})
	var lo: Vector2 = ((sp["min"] as Vector2) * sc).min(b.size)
	var hi: Vector2 = ((sp["max"] as Vector2) * sc).min(b.size)
	sz = sz.clamp(lo, hi.max(lo))
	var a: float = sp["aspect"]
	if a > 0.0:
		# Keep the ratio, shrinking whichever side is too long.
		if sz.x / sz.y > a:
			sz.x = sz.y * a
		else:
			sz.y = sz.x / a
	return sz


func _save_rect(id: String, r: Rect2, sc := 1.0) -> void:
	var room := bounds.size - r.size
	var off := r.position - bounds.position
	saved[id] = {"x": snappedf(off.x / room.x if room.x > 0.5 else 0.0, 0.0001),
		"y": snappedf(off.y / room.y if room.y > 0.5 else 0.0, 0.0001),
		"w": roundf(r.size.x), "h": roundf(r.size.y)}
	if absf(sc - 1.0) > 0.004:
		saved[id]["s"] = snappedf(sc, 0.01)


func _grab_rect(id: String, r: Rect2) -> Rect2:
	if bool(specs.get(id, {}).get("grab_all", false)):
		return r
	return Rect2(r.position, Vector2(r.size.x, minf(GRAB_H, r.size.y)))


func _grip_rect(r: Rect2) -> Rect2:
	return Rect2(r.end - Vector2(GRIP, GRIP), Vector2(GRIP, GRIP))


## What's under the mouse: [id, mode] (mode "move", "scale" for the corner
## grip, "size" for the picture's corner, "size_x" / "size_y" for the right
## and bottom edges), or [] for nothing.
func handle_at(pos: Vector2) -> Array:
	for k in range(placed.size() - 1, -1, -1):
		var id: String = placed[k][0]
		var r: Rect2 = placed[k][1]
		if not r.grow(3).has_point(pos):
			continue
		if _grip_rect(r).grow(3).has_point(pos):
			return [id, "scale" if scalable(id) else "size"]
		if _grab_rect(id, r).has_point(pos):
			return [id, "move"]
		if scalable(id):
			if pos.x >= r.end.x - EDGE:
				return [id, "size_x"]
			if pos.y >= r.end.y - EDGE:
				return [id, "size_y"]
		return []      # on a panel, but not on its handles: the panel's own clicks
	return []


## A left press. Returns true if it landed on a handle: the caller waits for
## release() before treating it as a click.
func press(pos: Vector2) -> bool:
	var h := handle_at(pos)
	if h.is_empty():
		return false
	_press_id = h[0]
	_press_mode = h[1]
	_press_pos = pos
	dragging = false
	for p in placed:
		if p[0] == _press_id:
			_press_rect = p[1]
	_press_scale = scale_of(_press_id)
	return true


## The mouse moved (held: the left button is still down). Returns true
## while a panel is being dragged.
func motion(pos: Vector2, held := true) -> bool:
	if _press_id == "":
		return false
	if not held:
		# The release went somewhere else (the screen closed): stop here.
		release()
		return false
	var d := pos - _press_pos
	if not dragging and d.length() < DRAG_START:
		return false
	dragging = true
	var r := _press_rect
	var sc := _press_scale
	if _press_mode == "scale":
		# The whole panel grows or shrinks with the mouse, contents and all.
		var f := (r.size + d) / r.size
		var k := (f.x + f.y) * 0.5
		var room := (bounds.end - r.position) / r.size
		k = minf(k, minf(room.x, room.y))
		sc = clampf(snappedf(_press_scale * k, 0.01), MIN_SCALE, MAX_SCALE)
		r.size = r.size * (sc / _press_scale)
		r.size = r.size.min(bounds.end - r.position)
	elif _press_mode.begins_with("size"):
		var dd := d
		if _press_mode == "size_x":
			dd.y = 0.0
		elif _press_mode == "size_y":
			dd.x = 0.0
		var sz := _fit_size(_press_id, r.size + dd, bounds, sc)
		sz = sz.min(bounds.end - r.position)   # stays on screen
		var snapped := _snap_size(_press_id, Rect2(r.position, sz))
		if _press_mode != "size_y":
			sz.x = snapped.x
		if _press_mode != "size_x":
			sz.y = snapped.y
		r.size = _fit_size(_press_id, sz, bounds, sc)
	else:
		r.position += d
		r.position = r.position.clamp(bounds.position, bounds.end - r.size)
		r.position = _snap_move(_press_id, r)
	_save_rect(_press_id, r, sc)
	return true


## A left release. Returns "click" if the press was a plain click on a
## title bar (the caller acts on it at press_position()), "moved" after a
## drag (the layout is saved), or "" if nothing was pressed here.
func release() -> String:
	if _press_id == "":
		return ""
	var was := dragging
	_press_id = ""
	dragging = false
	if was:
		if autosave:
			save()
		return "moved"
	return "click"


func press_position() -> Vector2:
	return _press_pos


func active_id() -> String:
	return _press_id if dragging else ""


func _others(id: String) -> Array:
	var out := []
	for p in placed:
		if p[0] != id and not bool(specs.get(p[0], {}).get("grab_all", false)):
			out.append(p[1])
	return out


func _snap_move(id: String, r: Rect2) -> Vector2:
	var xs := [bounds.position.x, bounds.end.x]
	var ys := [bounds.position.y, bounds.end.y]
	for o: Rect2 in _others(id):
		xs.append_array([o.position.x, o.end.x, o.position.x - GAP, o.end.x + GAP])
		ys.append_array([o.position.y, o.end.y, o.position.y - GAP, o.end.y + GAP])
	var p := r.position
	p.x = _snap_axis(r.position.x, r.size.x, xs)
	p.y = _snap_axis(r.position.y, r.size.y, ys)
	return p.clamp(bounds.position, bounds.end - r.size)


## Moves start (or start + length) onto the nearest line within SNAP.
static func _snap_axis(start: float, length: float, lines: Array) -> float:
	var best := SNAP + 0.001
	var out := start
	for l: float in lines:
		if absf(l - start) < best:
			best = absf(l - start)
			out = l
		if absf(l - (start + length)) < best:
			best = absf(l - (start + length))
			out = l - length
	return out


func _snap_size(id: String, r: Rect2) -> Vector2:
	var xs := [bounds.end.x]
	var ys := [bounds.end.y]
	for o: Rect2 in _others(id):
		xs.append_array([o.position.x - GAP, o.end.x])
		ys.append_array([o.position.y - GAP, o.end.y])
	var sz := r.size
	for l: float in xs:
		if absf(l - r.end.x) < SNAP:
			sz.x = l - r.position.x
	for l: float in ys:
		if absf(l - r.end.y) < SNAP:
			sz.y = l - r.position.y
	return sz


static func _cursor_for(mode: String) -> Input.CursorShape:
	match mode:
		"scale", "size": return Input.CURSOR_FDIAGSIZE
		"size_x": return Input.CURSOR_HSIZE
		"size_y": return Input.CURSOR_VSIZE
	return Input.CURSOR_MOVE


## The cursor for the mouse at pos (move over a title bar, diagonal arrows
## over the corner grip, sideways / up-down arrows over the edges, the arrow
## elsewhere).
func cursor_at(pos: Vector2) -> Input.CursorShape:
	if _press_id != "":
		return _cursor_for(_press_mode)
	var h := handle_at(pos)
	if h.is_empty():
		return Input.CURSOR_ARROW
	return _cursor_for(h[1])


## Draws the handles: a dotted grip on each title bar and the corner grip,
## brighter under the mouse; the edge under the mouse lit up; an outline round
## a panel being dragged and its size while it's scaled.
func draw_handles(ci: CanvasItem, hover: Vector2, font: Font = null) -> void:
	var h := handle_at(hover) if _press_id == "" else [_press_id, _press_mode]
	for p in placed:
		var id: String = p[0]
		var r: Rect2 = p[1]
		var hot: bool = not h.is_empty() and h[0] == id
		var mode: String = h[1] if hot else ""
		var a := 0.5 if hot else 0.18
		if not bool(specs.get(id, {}).get("grab_all", false)):
			# Six dots in the middle of the title bar.
			var c := Vector2(r.get_center().x, r.position.y + 7)
			for k in 3:
				for j in 2:
					ci.draw_circle(c + Vector2((k - 1) * 6, j * 5 - 2.5), 1.4, Color(1, 1, 1, a))
		var g := _grip_rect(r)
		var ga := a + (0.4 if mode in ["scale", "size"] else 0.0)
		var gc := Color(1.0, 0.88, 0.35, ga) if scalable(id) else Color(1, 1, 1, ga)
		for k in 3:
			var o := 4.0 + k * 4.0
			ci.draw_line(Vector2(g.end.x - o, g.end.y - 2), Vector2(g.end.x - 2, g.end.y - o), gc, 1.4)
		if mode == "size_x":
			ci.draw_line(Vector2(r.end.x - 1, r.position.y + GRAB_H), Vector2(r.end.x - 1, r.end.y - GRIP), Color(1, 1, 1, 0.7), 2.0)
		elif mode == "size_y":
			ci.draw_line(Vector2(r.position.x, r.end.y - 1), Vector2(r.end.x - GRIP, r.end.y - 1), Color(1, 1, 1, 0.7), 2.0)
		if active_id() == id:
			ci.draw_rect(r.grow(2), Color(1.0, 0.88, 0.35, 0.9), false, 2.0)
			if font and _press_mode == "scale":
				var txt := "%d %%" % roundi(scale_of(id) * 100.0)
				var tp := r.end - Vector2(70, 26)
				ci.draw_rect(Rect2(tp - Vector2(6, 18), Vector2(64, 24)), Color(0, 0, 0, 0.7))
				ci.draw_string(font, tp, txt, HORIZONTAL_ALIGNMENT_RIGHT, 52, 16, Color(1.0, 0.88, 0.35))


## The biggest rectangle inside `area` that no rect in `blocks` overlaps (the
## pit wall console frames the 3D race in it). Returns an empty Rect2 if
## there's none.
static func largest_free(area: Rect2, blocks: Array) -> Rect2:
	var xs := [area.position.x, area.end.x]
	var ys := [area.position.y, area.end.y]
	var inside: Array[Rect2] = []
	for b: Rect2 in blocks:
		var c := b.intersection(area)
		if not c.has_area():
			continue
		inside.append(c)
		xs.append_array([c.position.x, c.end.x])
		ys.append_array([c.position.y, c.end.y])
	xs.sort()
	ys.sort()
	var best := Rect2()
	for a in xs.size():
		for b in range(a + 1, xs.size()):
			var w: float = xs[b] - xs[a]
			if w <= 0.0:
				continue
			for c in ys.size():
				for d in range(c + 1, ys.size()):
					var r := Rect2(xs[a], ys[c], w, ys[d] - ys[c])
					if r.get_area() <= best.get_area():
						continue
					var clear := true
					for blk in inside:
						if r.intersects(blk):
							clear = false
							break
					if clear:
						best = r
	return best
