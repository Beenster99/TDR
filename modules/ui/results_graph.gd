class_name ResultsGraph
extends Control
## A line graph for the results screen: laps along the bottom, one line per
## driver. Everybody is drawn as a quiet grey line; the cars picked out
## (`colors`: car -> Color) are drawn on top in their colour with their name
## at the line's end. Hovering shows a crosshair on that lap and a tooltip;
## the line nearest the mouse turns white. Clicking a line emits car_clicked.
##
## series: [{car, name, points: [Vector2(lap, value), ...], marks: [lap, ...]}]
##   marks are drawn as rings on the line (pit stops).

signal car_clicked(car: int)

const GRID := Color(1, 1, 1, 0.07)
const AXIS_TEXT := Color(1, 1, 1, 0.5)
const INK := Color(1, 1, 1, 0.92)
const QUIET := Color(0.62, 0.66, 0.72, 0.22)
const HOVER := Color(1, 1, 1, 0.95)
const SURFACE := Color(0.07, 0.075, 0.09)
const PAD_L := 46.0
const PAD_R := 118.0      ## room for the names at the lines' ends
const PAD_T := 10.0
const PAD_B := 26.0

var series: Array = []
var colors: Dictionary = {}          ## car -> Color, drawn on top with a label
var invert_y := false                ## true: small values at the top (positions, gaps)
var y_min := 0.0
var y_max := 1.0
var x_min := 0.0
var x_max := 1.0
var y_step := 0.0                    ## grid spacing (0 = about five lines)
var y_format := "%.0f"               ## axis labels
var value_text: Callable             ## value -> tooltip text (default y_format)
var axis_text: Callable              ## value -> axis label (default y_format)
var x_name := "Lap"
var integer_y := false               ## positions: whole numbers only
var hovered := -1
var _hover_x := -1.0


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_STOP
	clip_contents = true


## Sets the lines and works out the axes. y_range: [min, max] to clip to
## (empty = fit the data).
func set_data(p_series: Array, p_colors: Dictionary, y_range := []) -> void:
	series = p_series
	colors = p_colors
	var lo := INF
	var hi := -INF
	x_min = INF
	x_max = -INF
	for s in series:
		for p in s["points"]:
			lo = minf(lo, p.y)
			hi = maxf(hi, p.y)
			x_min = minf(x_min, p.x)
			x_max = maxf(x_max, p.x)
	if x_min == INF:
		x_min = 0.0
		x_max = 1.0
		lo = 0.0
		hi = 1.0
	if x_max <= x_min:
		x_max = x_min + 1.0
	if y_range.size() == 2:
		lo = float(y_range[0])
		hi = float(y_range[1])
	if hi <= lo:
		hi = lo + 1.0
	y_min = lo
	y_max = hi
	queue_redraw()


func plot_rect() -> Rect2:
	return Rect2(PAD_L, PAD_T, maxf(size.x - PAD_L - PAD_R, 10.0), maxf(size.y - PAD_T - PAD_B, 10.0))


func to_screen(p: Vector2) -> Vector2:
	var r := plot_rect()
	var fx := (p.x - x_min) / (x_max - x_min)
	var fy := (clampf(p.y, y_min, y_max) - y_min) / (y_max - y_min)
	if not invert_y:
		fy = 1.0 - fy
	return Vector2(r.position.x + fx * r.size.x, r.position.y + fy * r.size.y)


func _draw() -> void:
	var font := get_theme_default_font()
	var r := plot_rect()
	# Grid and axes: quiet, behind everything.
	var step := y_step
	if step <= 0.0:
		step = _nice_step((y_max - y_min) / 5.0)
	var v := ceilf(y_min / step) * step
	while v <= y_max + 0.0001:
		var y := to_screen(Vector2(x_min, v)).y
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), GRID, 1.0)
		draw_string(font, Vector2(0, y + 5), axis_text.call(v) if axis_text.is_valid() else y_format % v, HORIZONTAL_ALIGNMENT_RIGHT, PAD_L - 8, 12, AXIS_TEXT)
		v += step
	var xs := _nice_step((x_max - x_min) / 10.0)
	xs = maxf(xs, 1.0)
	var lx := ceilf(x_min / xs) * xs
	while lx <= x_max + 0.0001:
		var x := to_screen(Vector2(lx, y_min)).x
		draw_line(Vector2(x, r.end.y), Vector2(x, r.end.y + 4), AXIS_TEXT, 1.0)
		draw_string(font, Vector2(x - 20, r.end.y + 18), "%d" % int(lx), HORIZONTAL_ALIGNMENT_CENTER, 40, 12, AXIS_TEXT)
		lx += xs
	draw_string(font, Vector2(0, r.end.y + 18), x_name, HORIZONTAL_ALIGNMENT_RIGHT, PAD_L - 8, 12, AXIS_TEXT)
	draw_line(Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.end.y), Color(1, 1, 1, 0.18), 1.0)
	# The crosshair on the hovered lap.
	if _hover_x >= 0.0:
		var hx := to_screen(Vector2(_hover_x, y_min)).x
		draw_line(Vector2(hx, r.position.y), Vector2(hx, r.end.y), Color(1, 1, 1, 0.22), 1.0)
	# Quiet lines first, then the picked ones, then the hovered one on top.
	for s in series:
		if not colors.has(s["car"]) and s["car"] != hovered:
			_line(s, QUIET, 1.5)
	for s in series:
		if colors.has(s["car"]) and s["car"] != hovered:
			_line(s, colors[s["car"]], 2.5)
	for s in series:
		if s["car"] == hovered:
			_line(s, colors.get(s["car"], HOVER).lightened(0.25) if colors.has(s["car"]) else HOVER, 3.0)
	_end_labels(font)
	if _hover_x >= 0.0:
		_tooltip(font)


func _line(s: Dictionary, col: Color, w: float) -> void:
	var pts := PackedVector2Array()
	for p in s["points"]:
		pts.append(to_screen(p))
	if pts.size() >= 2:
		draw_polyline(pts, col, w, true)
	elif pts.size() == 1:
		draw_circle(pts[0], w + 1.0, col)
	if col == QUIET:
		return
	for m in s.get("marks", []):
		for p in s["points"]:
			if is_equal_approx(p.x, float(m)):
				var c := to_screen(p)
				draw_circle(c, 5.0, SURFACE)
				draw_arc(c, 5.0, 0, TAU, 16, col, 2.0, true)


## The picked drivers' names at the right-hand end of their lines, nudged
## apart so they don't sit on each other.
func _end_labels(font: Font) -> void:
	var labels := []
	for s in series:
		if (colors.has(s["car"]) or s["car"] == hovered) and not s["points"].is_empty():
			var end := to_screen(s["points"][-1])
			labels.append([end.y, s, end])
	labels.sort_custom(func(a, b): return a[0] < b[0])
	var last := -INF
	for l in labels:
		var y := maxf(float(l[0]), last + 14.0)
		last = y
		var s: Dictionary = l[1]
		var col: Color = colors.get(s["car"], HOVER)
		var end: Vector2 = l[2]
		draw_circle(Vector2(plot_rect().end.x + 8, y), 4.0, col)
		if absf(y - end.y) > 2.0:
			draw_line(end, Vector2(plot_rect().end.x + 4, y), Color(col, 0.4), 1.0)
		draw_string(font, Vector2(plot_rect().end.x + 16, y + 5), _short(str(s["name"])), HORIZONTAL_ALIGNMENT_LEFT,
			PAD_R - 18, 13, INK)


func _tooltip(font: Font) -> void:
	var lines := [["Lap %d" % int(_hover_x), INK, null]]
	var shown := []
	for s in series:
		if colors.has(s["car"]) or s["car"] == hovered:
			for p in s["points"]:
				if is_equal_approx(p.x, _hover_x):
					shown.append([p.y, s])
	shown.sort_custom(func(a, b): return a[0] < b[0] if invert_y else a[0] > b[0])
	for e in shown:
		var s: Dictionary = e[1]
		var txt: String = value_text.call(e[0]) if value_text.is_valid() else y_format % e[0]
		lines.append(["%s  %s" % [_short(str(s["name"])), txt], INK, colors.get(s["car"], HOVER)])
	if hovered >= 0:
		lines.append(["click for their race data", AXIS_TEXT, null])
	var w := 0.0
	for l in lines:
		w = maxf(w, font.get_string_size(l[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x)
	w += 30.0
	var h := lines.size() * 17.0 + 10.0
	var mp := get_local_mouse_position()
	var pos := mp + Vector2(16, 12)
	if pos.x + w > size.x:
		pos.x = mp.x - w - 16
	if pos.y + h > size.y:
		pos.y = maxf(size.y - h, 0.0)
	draw_rect(Rect2(pos, Vector2(w, h)), Color(0.03, 0.035, 0.045, 0.96))
	draw_rect(Rect2(pos, Vector2(w, h)), Color(1, 1, 1, 0.15), false, 1.0)
	var y := pos.y + 18.0
	for l in lines:
		var x := pos.x + 10.0
		if l[2] != null:
			draw_rect(Rect2(x, y - 9, 10, 3), l[2])
			x += 16.0
		draw_string(font, Vector2(x, y), l[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, l[1])
		y += 17.0


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover_at(event.position)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_hover_at(event.position)
		if hovered >= 0:
			car_clicked.emit(hovered)
			accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		hovered = -1
		_hover_x = -1.0
		queue_redraw()


func _hover_at(mp: Vector2) -> void:
	var r := plot_rect()
	if not r.grow(6).has_point(mp):
		if hovered != -1 or _hover_x >= 0.0:
			hovered = -1
			_hover_x = -1.0
			queue_redraw()
		return
	var lap := roundf(lerpf(x_min, x_max, clampf((mp.x - r.position.x) / r.size.x, 0.0, 1.0)))
	var best := -1
	var best_d := 14.0
	for s in series:
		var pts: Array = s["points"]
		for k in pts.size() - 1:
			var d := Geometry2D.get_closest_point_to_segment(mp, to_screen(pts[k]), to_screen(pts[k + 1])).distance_to(mp)
			if d < best_d:
				best_d = d
				best = s["car"]
		if pts.size() == 1 and to_screen(pts[0]).distance_to(mp) < best_d:
			best = s["car"]
	if best != hovered or lap != _hover_x:
		hovered = best
		_hover_x = lap
		mouse_default_cursor_shape = CURSOR_POINTING_HAND if best >= 0 else CURSOR_ARROW
		queue_redraw()


static func _short(n: String) -> String:
	# "Lewis Hamilton" -> "L. Hamilton" when it's long.
	if n.length() <= 13 or not n.contains(" "):
		return n
	var parts := n.split(" ", false)
	return "%s. %s" % [parts[0].substr(0, 1), " ".join(parts.slice(1))]


static func _nice_step(raw: float) -> float:
	if raw <= 0.0:
		return 1.0
	var mag := pow(10.0, floorf(log(raw) / log(10.0)))
	for m in [1.0, 2.0, 5.0, 10.0]:
		if raw <= m * mag:
			return m * mag
	return 10.0 * mag
