class_name WeatherRadar
extends RefCounted
## The pit wall's weather radar panel, drawn like a real rain radar: a map
## under range rings centred on the circuit, rain from light blue through
## green and yellow to red, arrows showing where the cells are heading, and
## lines marking where rain is 10, 20 and 30 minutes from the track. ▶ plays
## the last 15 minutes and the forecast for the next 30; the bar under the
## radar jumps to any moment; + / − (or the mouse wheel) zoom. Beside it: the
## conditions now, a 30-minute rain strip for the track, and the forecast
## changes with ETA ranges, how long they last and how sure the forecast is.
##
## Reads everything from WeatherForecast (telemetry). The rain picture is
## worked out a slice at a time over a few frames, so the pit wall never
## stutters. The owner (StrategistScreen) calls draw() from its _draw() and
## passes clicks on hits tagged "radar" to click().

const ZOOMS := [1.0, 0.6, 0.35]            ## share of the full radar range shown
const LOOP_FROM := -900.0                  ## the loop starts 15 min ago...
const LOOP_TO := 1800.0                    ## ...and runs to 30 min ahead
const LOOP_STEP := 150.0
const FRAME_S := 0.45                      ## seconds per loop frame
const HOLD_S := 1.4                        ## pause on "now" and at the end
const PIXELS_PER_FRAME := 1500             ## rain pixels worked out per drawn frame
const MAX_PIXELS := 14000                  ## the rain picture's size budget
const TEXT_W := 232.0                      ## forecast column width beside the radar
const DIM := Color(1, 1, 1, 0.55)
const YELLOW := Color(1.0, 0.88, 0.35)
const RAIN_BLUE := Color(0.55, 0.78, 1.0)
## Rain colour scale: [rain, colour], like the radar's dBZ scale.
const SCALE := [[0.04, Color(0.72, 0.97, 1.0)], [0.12, Color(0.25, 0.9, 0.97)], [0.22, Color(0.12, 0.55, 0.98)],
	[0.32, Color(0.35, 0.72, 0.28)], [0.44, Color(0.72, 0.84, 0.15)], [0.55, Color(1.0, 0.95, 0.12)],
	[0.7, Color(1.0, 0.6, 0.05)], [0.85, Color(0.95, 0.15, 0.05)], [1.0, Color(0.7, 0.0, 0.3)]]

var zoom := 0
var playing := false
var offset_s := 0.0                        ## moment shown: 0 now, < 0 past, > 0 forecast
var _hold := 0.0
var _lut := PackedByteArray()              ## 256 RGBA colours
var _map_tex: ImageTexture
var _map_key := ""
var _rain_tex: ImageTexture
var _rain_key := ""                         ## what _rain_tex shows
var _job := {}                              ## the picture being worked out
var _last_done_ms := 0
var _seed := 0


func _init() -> void:
	_lut.resize(256 * 4)
	for i in 256:
		var v := i / 255.0
		var c := Color(0, 0, 0, 0)
		if v >= SCALE[0][0]:
			c = SCALE[-1][1]
			for k in range(1, SCALE.size()):
				if v <= SCALE[k][0]:
					var f: float = (v - SCALE[k - 1][0]) / (SCALE[k][0] - SCALE[k - 1][0])
					c = (SCALE[k - 1][1] as Color).lerp(SCALE[k][1], f)
					break
			c.a = 0.82
		_lut[i * 4] = int(c.r * 255.0)
		_lut[i * 4 + 1] = int(c.g * 255.0)
		_lut[i * 4 + 2] = int(c.b * 255.0)
		_lut[i * 4 + 3] = int(c.a * 255.0)


static func colour_for(rain: float) -> Color:
	if rain < SCALE[0][0]:
		return Color(1, 1, 1, 0.08)
	for k in range(1, SCALE.size()):
		if rain <= SCALE[k][0]:
			return (SCALE[k - 1][1] as Color).lerp(SCALE[k][1], (rain - SCALE[k - 1][0]) / (SCALE[k][0] - SCALE[k - 1][0]))
	return SCALE[-1][1]


## Moves the loop on. Call every frame while the pit wall is open.
func process(delta: float) -> void:
	if not playing:
		return
	_hold -= delta
	if _hold > 0.0:
		return
	offset_s += LOOP_STEP
	if offset_s > LOOP_TO + 1.0:
		offset_s = LOOP_FROM
	_hold = HOLD_S if is_zero_approx(offset_s) or offset_s >= LOOP_TO else FRAME_S


## A click on one of the radar's hits: arg is the action, dir 1 left click,
## -1 right, -2 / 2 wheel up / down. x is the click's x (for the time bar).
func click(arg, dir: int, x := 0.0) -> void:
	var a := str(arg[0]) if arg is Array else str(arg)
	match a:
		"zoom_in":
			if absi(dir) == 1:
				zoom = mini(zoom + 1, ZOOMS.size() - 1)
		"zoom_out":
			if absi(dir) == 1:
				zoom = maxi(zoom - 1, 0)
		"area":
			if dir == -2:
				zoom = mini(zoom + 1, ZOOMS.size() - 1)
			elif dir == 2:
				zoom = maxi(zoom - 1, 0)
		"play":
			if dir == 1:
				playing = not playing
				if playing:
					offset_s = LOOP_FROM
					_hold = FRAME_S
				else:
					offset_s = 0.0
		"now":
			if dir == 1:
				playing = false
				offset_s = 0.0
		"time":
			var bar: Rect2 = arg[1]
			if absi(dir) == 1:
				playing = false
				var f := clampf((x - bar.position.x) / bar.size.x, 0.0, 1.0)
				offset_s = snappedf(lerpf(LOOP_FROM, LOOP_TO, f), LOOP_STEP)
			else:
				playing = false
				offset_s = clampf(offset_s + signf(dir) * LOOP_STEP, LOOP_FROM, LOOP_TO)


# --- Drawing -----------------------------------------------------------------------

## Draws the whole panel content into r (the panel's rect, title bar
## included). hits gets [Rect2, "radar", arg] entries.
func draw(ci: CanvasItem, font: Font, r: Rect2, f: WeatherForecast, track_pts: PackedVector2Array,
		track_name: String, hover: Vector2, hits: Array) -> void:
	if _seed == 0:
		_seed = absi(hash(track_name)) + 1
	var inner := Rect2(r.position + Vector2(8, 30), r.size - Vector2(16, 38))
	var side := inner.size.x >= 470.0
	var area := inner
	var text_r := Rect2()
	if side:
		area.size.x = inner.size.x - TEXT_W - 10.0
		text_r = Rect2(area.end.x + 12.0, inner.position.y, TEXT_W - 2.0, inner.size.y)
	elif inner.size.y >= 330.0:
		area.size.y = inner.size.y - 130.0
		text_r = Rect2(inner.position.x, area.end.y + 8.0, inner.size.x, 122.0)
	var bar := Rect2(area.position.x, area.end.y - 16.0, area.size.x, 16.0)
	area.size.y -= 20.0
	if area.size.x < 40.0 or area.size.y < 40.0:
		return
	var range_m: float = f.radar_range * ZOOMS[zoom]
	var px_per_m := minf(area.size.x, area.size.y) * 0.5 / range_m
	var world := Rect2(f.centre - area.size * 0.5 / px_per_m, area.size / px_per_m)
	var to_px := func(p: Vector2) -> Vector2: return area.get_center() + (p - f.centre) * px_per_m
	# Map, then the rain over it.
	_ensure_map(world, area.size)
	ci.draw_texture_rect(_map_tex, area, false)
	_work_on_rain(f, world, area.size)
	if _rain_tex:
		ci.draw_texture_rect(_rain_tex, area, false)
	if offset_s > 0.0:
		ci.draw_rect(area, Color(1.0, 0.9, 0.4, 0.07))
	hits.append([area, "radar", "area"])     # under the buttons drawn later
	# Range rings and cross hairs.
	var ring_col := Color(0.28, 0.28, 0.32, 0.85)
	var cpx: Vector2 = to_px.call(f.centre)
	var max_r := area.size.length() * 0.5 + 4.0
	var rr := f.ring_step * px_per_m
	var n := 1
	while rr * n <= max_r and n < 40:
		_clipped_circle(ci, cpx, rr * n, area, ring_col, 1.3)
		n += 1
	ci.draw_line(Vector2(area.position.x, cpx.y), Vector2(area.end.x, cpx.y), ring_col, 1.0)
	ci.draw_line(Vector2(cpx.x, area.position.y), Vector2(cpx.x, area.end.y), ring_col, 1.0)
	var every := maxi(1, int(ceil(34.0 / maxf(rr, 1.0))))
	for k in range(every, n, every):
		var lx := cpx.x - rr * k
		if lx < area.position.x + 4.0:
			break
		_label(ci, font, Vector2(lx + 3.0, cpx.y - 4.0), _km(f.ring_step * k), 11)
	# Where the rain is 10, 20 and 30 minutes from the track.
	var est := f.wind_speed / (1.0 + WeatherForecast.SPEED_ERR * f.speed_error)
	var perp := Vector2(-f.wind_dir.y, f.wind_dir.x)
	for mins: int in [10, 20, 30]:
		var c: Vector2 = cpx - f.wind_dir * (est * mins * 60.0 - est * maxf(offset_s, 0.0)) * px_per_m
		var a := c - perp * max_r * 2.0
		var b := c + perp * max_r * 2.0
		if _dashed_clipped(ci, a, b, area, Color(1, 1, 1, 0.55), 1.2):
			var lp := _clip_point_towards(c, area.grow(-14.0))
			_label(ci, font, lp + Vector2(-16, 4), "%d min" % mins, 11, Color(1, 1, 1, 0.9))
	# The circuit.
	var pts := PackedVector2Array()
	for p in track_pts:
		pts.append(to_px.call(p))
	if pts.size() > 1:
		var big := f.track_radius * px_per_m > 6.0
		if big:
			ci.draw_polyline(pts, Color(0.05, 0.05, 0.05, 0.9), 3.5)
			ci.draw_polyline(pts, Color(1.0, 0.85, 0.2), 1.8)
		else:
			ci.draw_circle(cpx, 4.5, Color(0.05, 0.05, 0.05, 0.9))
			ci.draw_circle(cpx, 3.0, Color(1.0, 0.85, 0.2))
		var lw := font.get_string_size(track_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var lx := cpx.x + f.track_radius * px_per_m + 6.0
		if lx + lw > area.end.x - 4.0:
			lx = cpx.x - f.track_radius * px_per_m - 6.0 - lw
		if lx >= area.position.x + 4.0:
			_label(ci, font, Vector2(lx, cpx.y + 16.0), track_name, 12, Color.WHITE)
	# Arrows on the heaviest cells: where they'll be in 10 minutes.
	_draw_cell_arrows(ci, area, f, px_per_m)
	# Header strip: the moment shown, and the way the weather is moving.
	var tag := "NOW  %02d:%02d" % [int(f.time_of_day_h), int(fmod(f.time_of_day_h, 1.0) * 60.0)]
	var tag_col := Color(0.1, 0.1, 0.12, 0.8)
	if offset_s > 0.0:
		tag = "FORECAST  +%d min" % int(round(offset_s / 60.0))
		tag_col = Color(0.55, 0.42, 0.0, 0.88)
	elif offset_s < 0.0:
		tag = "%d min ago" % int(round(-offset_s / 60.0))
	var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 14.0
	ci.draw_rect(Rect2(area.position + Vector2(4, 4), Vector2(tw, 20)), tag_col)
	ci.draw_string(font, area.position + Vector2(11, 19), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
	var mv := "%s  %d km/h" % [f.heading_name(), int(round(f.wind_speed * 3.6))]
	var mw := font.get_string_size(mv, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 36.0
	var mr := Rect2(Vector2(area.end.x - mw - 4.0, area.position.y + 4.0), Vector2(mw, 20))
	ci.draw_rect(mr, Color(0.1, 0.1, 0.12, 0.8))
	var ac := mr.position + Vector2(13, 10)
	_arrow(ci, ac - f.wind_dir * 8.0, ac + f.wind_dir * 8.0, Color.WHITE, 2.0, 5.0)
	ci.draw_string(font, mr.position + Vector2(26, 15), mv, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
	# North.
	var nr := Vector2(area.end.x - 14.0, area.position.y + 40.0)
	ci.draw_string_outline(font, nr + Vector2(-4, 0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color(0, 0, 0, 0.7))
	ci.draw_string(font, nr + Vector2(-4, 0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	_arrow(ci, nr + Vector2(0, 16), nr + Vector2(0, 4), Color.WHITE, 1.5, 4.0)
	# Buttons: zoom and play.
	var by := area.end.y - 30.0
	var bx := area.end.x - 30.0
	for b in [["+", "zoom_in", zoom < ZOOMS.size() - 1], ["−", "zoom_out", zoom > 0],
			["■" if playing else "▶", "play", true]]:
		var br := Rect2(bx, by, 26, 26)
		var hot: bool = br.has_point(hover) and b[2]
		ci.draw_rect(br, Color(0.08, 0.08, 0.1, 0.85 if hot else 0.7))
		ci.draw_rect(br, Color(1, 1, 1, 0.6 if hot else 0.3), false, 1.0)
		ci.draw_string(font, Vector2(br.position.x, br.position.y + 19), b[0], HORIZONTAL_ALIGNMENT_CENTER, br.size.x, 16,
			Color.WHITE if b[2] else Color(1, 1, 1, 0.3))
		hits.append([br, "radar", b[1]])
		bx -= 30.0
	# Legend.
	var lg := Rect2(area.position.x + 6.0, area.end.y - 18.0, minf(150.0, area.size.x * 0.4), 8.0)
	for k in 30:
		var v := lerpf(0.05, 1.0, k / 29.0)
		ci.draw_rect(Rect2(lg.position.x + lg.size.x * k / 30.0, lg.position.y, lg.size.x / 30.0 + 0.5, lg.size.y), colour_for(v))
	ci.draw_rect(lg, Color(0, 0, 0, 0.5), false, 1.0)
	_label(ci, font, lg.position + Vector2(0, -3), "light", 10)
	_label(ci, font, Vector2(lg.end.x - 24, lg.position.y - 3), "heavy", 10)
	ci.draw_rect(area, Color(1, 1, 1, 0.2), false, 1.0)
	_draw_time_bar(ci, font, bar, f, hover, hits)
	if text_r.size.x > 0.0:
		_draw_text(ci, font, text_r, f)


## The bar under the radar: 15 minutes ago to 30 minutes ahead, with the
## moment shown and the forecast rain at the track along it.
func _draw_time_bar(ci: CanvasItem, font: Font, bar: Rect2, f: WeatherForecast, hover: Vector2, hits: Array) -> void:
	ci.draw_rect(bar, Color(0, 0, 0, 0.35))
	var steps := 45
	for k in steps:
		var t := lerpf(LOOP_FROM, LOOP_TO, (k + 0.5) / steps)
		var v := f.rain_in(t) if t > 0.0 else f.timeline_rain(f.elapsed + t)
		if v >= 0.04:
			var c := colour_for(v)
			c.a = 0.85
			ci.draw_rect(Rect2(bar.position.x + bar.size.x * k / steps, bar.position.y + 3, bar.size.x / steps + 0.5, bar.size.y - 6), c)
	var now_x := bar.position.x + bar.size.x * (-LOOP_FROM) / (LOOP_TO - LOOP_FROM)
	ci.draw_line(Vector2(now_x, bar.position.y), Vector2(now_x, bar.end.y), Color.WHITE, 1.5)
	var at_x := bar.position.x + bar.size.x * (offset_s - LOOP_FROM) / (LOOP_TO - LOOP_FROM)
	ci.draw_rect(Rect2(at_x - 3, bar.position.y - 1, 6, bar.size.y + 2), YELLOW)
	ci.draw_rect(bar, Color(1, 1, 1, 0.5 if bar.has_point(hover) else 0.25), false, 1.0)
	for m: int in [-15, 0, 10, 20, 30]:
		var x := bar.position.x + bar.size.x * (m * 60.0 - LOOP_FROM) / (LOOP_TO - LOOP_FROM)
		var s := "now" if m == 0 else ("%+d" % m)
		if m == 30:
			x -= font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x + 6.0
		ci.draw_string_outline(font, Vector2(x + 3, bar.position.y + 12), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, 3, Color(0, 0, 0, 0.6))
		ci.draw_string(font, Vector2(x + 3, bar.position.y + 12), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.85))
	hits.append([bar, "radar", ["time", bar]])


func _draw_text(ci: CanvasItem, font: Font, r: Rect2, f: WeatherForecast) -> void:
	var x := r.position.x
	var w := r.size.x
	var y := r.position.y + 14.0
	_t(ci, font, Vector2(x, y), "Now: " + WeatherForecast.weather_label(f.weather), 17,
		RAIN_BLUE if f.rain > 0.05 else Color.WHITE, w)
	y += 21.0
	_t(ci, font, Vector2(x, y), "Rain %d%%   Track wet %d%%" % [int(f.rain * 100.0), int(f.wetness * 100.0)], 13, DIM, w)
	y += 18.0
	_t(ci, font, Vector2(x, y), "Air %d°C   Track %d°C" % [int(f.ambient_c), int(f.track_c)], 13, DIM, w)
	y += 18.0
	_t(ci, font, Vector2(x, y), "Moving %s at %d km/h" % [f.heading_name(), int(round(f.wind_speed * 3.6))], 13, DIM, w)
	y += 24.0
	if y + 40.0 > r.end.y:
		return
	_t(ci, font, Vector2(x, y), "RAIN AT THE TRACK, NEXT 30 MIN", 11, DIM, w)
	y += 6.0
	var strip := Rect2(x, y, w, 12)
	ci.draw_rect(strip, Color(1, 1, 1, 0.06))
	for k in 30:
		var v := f.rain_in(k * 60.0 + 30.0)
		if v >= 0.04:
			ci.draw_rect(Rect2(x + w * k / 30.0, y, w / 30.0 + 0.5, 12), colour_for(v))
	for m: int in [10, 20]:
		ci.draw_line(Vector2(x + w * m / 30.0, y), Vector2(x + w * m / 30.0, y + 12), Color(1, 1, 1, 0.4), 1.0)
	y += 34.0
	_t(ci, font, Vector2(x, y - 6.0), "FORECAST", 11, DIM, w)
	y += 12.0
	if f.changes.is_empty():
		_t(ci, font, Vector2(x, y), f.summary(), 14, Color(0.75, 0.85, 1.0), w)
		return
	for ch in f.changes:
		if y + 4.0 > r.end.y:
			break
		var wet: bool = ch["rain"] > 0.05
		_t(ci, font, Vector2(x, y), WeatherForecast.weather_label(ch["weather"]), 15, RAIN_BLUE if wet else Color.WHITE, w * 0.44)
		_t(ci, font, Vector2(x + w * 0.44, y), WeatherForecast.eta_text(ch), 14, Color.WHITE, w * 0.38)
		_t(ci, font, Vector2(x + w * 0.83, y), "%d%%" % int(ch["confidence"] * 100.0), 13, DIM, w * 0.17)
		y += 17.0
		if y + 2.0 <= r.end.y:
			var lasts: float = ch.get("lasts", -1.0)
			var note := "for about %d min" % maxi(int(round(lasts)), 1) if lasts > 0.0 else "for 30 min or more"
			if wet:
				note = ("heavy, " if ch["rain"] >= 0.6 else "light, ") + note
			_t(ci, font, Vector2(x + 10.0, y), note, 12, DIM, w - 10.0)
			y += 21.0


# --- The pictures -------------------------------------------------------------------

## The map under the radar: fields, woods, lakes, a river and towns around
## the circuit, fixed to the ground. Made once per zoom and size.
func _ensure_map(world: Rect2, px: Vector2) -> void:
	var key := "%s|%s" % [world, px]
	if key == _map_key and _map_tex:
		return
	_map_key = key
	var w := clampi(int(px.x / 2.0), 16, 320)
	var h := clampi(int(px.y / 2.0), 16, 320)
	var nf := FastNoiseLite.new()
	nf.seed = _seed
	nf.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	nf.fractal_octaves = 4
	var data := PackedByteArray()
	data.resize(w * h * 3)
	var base := Color(0.86, 0.86, 0.82)
	var field := Color(0.79, 0.86, 0.69)
	var wood := Color(0.63, 0.76, 0.55)
	var water := Color(0.6, 0.74, 0.9)
	var town := Color(0.8, 0.79, 0.81)
	var i := 0
	for y in h:
		for x in w:
			var p := world.position + Vector2((x + 0.5) * world.size.x / w, (y + 0.5) * world.size.y / h)
			nf.frequency = 1.0 / 2500.0
			var a := nf.get_noise_2d(p.x, p.y)
			nf.frequency = 1.0 / 6000.0
			var b := nf.get_noise_2d(p.x + 9000.0, p.y - 4000.0)
			nf.frequency = 1.0 / 14000.0
			var lake := nf.get_noise_2d(p.x - 20000.0, p.y + 7000.0)
			var river := absf(nf.get_noise_2d(p.x * 0.6 + 31000.0, p.y * 0.6))
			var c := base.lerp(field, clampf(a * 2.0 + 0.5, 0.0, 1.0) * 0.8)
			if b > 0.18:
				c = c.lerp(wood, clampf((b - 0.18) * 6.0, 0.0, 1.0))
			if a < -0.42 and b < 0.0:
				c = c.lerp(town, 0.85)
			if lake < -0.5 or river < 0.012:
				c = water
			data[i] = int(c.r * 255.0)
			data[i + 1] = int(c.g * 255.0)
			data[i + 2] = int(c.b * 255.0)
			i += 3
	_map_tex = ImageTexture.create_from_image(Image.create_from_data(w, h, false, Image.FORMAT_RGB8, data))


## Works out a slice of the rain picture each frame; starts a new picture
## about once a second (sooner when the zoom, size or moment changes).
func _work_on_rain(f: WeatherForecast, world: Rect2, px: Vector2) -> void:
	var cell := maxf(2.5, sqrt(px.x * px.y / MAX_PIXELS))
	var w := maxi(int(px.x / cell), 8)
	var h := maxi(int(px.y / cell), 8)
	var key := "%s|%d|%d|%d" % [world, w, h, int(offset_s)]
	var now := Time.get_ticks_msec()
	if _job.is_empty() and (key != _rain_key or now - _last_done_ms > 1000):
		var buf := PackedByteArray()
		buf.resize(w * h * 4)
		_job = {"key": key, "world": world, "w": w, "h": h, "row": 0, "buf": buf, "offset": offset_s}
	if _job.is_empty():
		return
	if _job["key"] != key and _job["row"] > 0 and key != _rain_key:
		_job.clear()     # the view changed: start again on the next frame
		return
	var jw: int = _job["w"]
	var jh: int = _job["h"]
	var rows := maxi(1, PIXELS_PER_FRAME / jw)
	# A new view with nothing to show yet: do it all at once.
	if _rain_key.split("|")[0] != key.split("|")[0] or _rain_tex == null:
		rows = jh
	var row: int = _job["row"]
	var vals := f.sample_grid(_job["world"], jw, jh, _job["offset"], row, rows)
	var buf: PackedByteArray = _job["buf"]
	var o := row * jw * 4
	for v in vals:
		var li := int(v * 255.0) * 4
		buf[o] = _lut[li]
		buf[o + 1] = _lut[li + 1]
		buf[o + 2] = _lut[li + 2]
		buf[o + 3] = _lut[li + 3]
		o += 4
	row += vals.size() / jw
	_job["row"] = row
	_job["buf"] = buf
	if row >= jh:
		var img := Image.create_from_data(jw, jh, false, Image.FORMAT_RGBA8, buf)
		if _rain_tex and _rain_tex.get_size() == Vector2(jw, jh):
			_rain_tex.update(img)
		else:
			_rain_tex = ImageTexture.create_from_image(img)
		_rain_key = _job["key"]
		_last_done_ms = now
		_job.clear()


func _draw_cell_arrows(ci: CanvasItem, area: Rect2, f: WeatherForecast, px_per_m: float) -> void:
	if not _rain_key or _rain_tex == null:
		return
	# Sample a coarse grid of the field and arrow the strongest spots.
	var picks: Array = []
	var gx := 7
	var gy := maxi(int(7.0 * area.size.y / area.size.x), 3)
	for j in gy:
		for i in gx:
			var sp := area.position + Vector2((i + 0.5) * area.size.x / gx, (j + 0.5) * area.size.y / gy)
			var p := f.centre + (sp - area.get_center()) / px_per_m
			var v := f.rain_at(p, offset_s)
			if v > 0.18:
				picks.append([v, sp])
	picks.sort_custom(func(a, b): return a[0] > b[0])
	var len_px := clampf(f.wind_speed * 600.0 * px_per_m, 14.0, 44.0)
	for k in mini(picks.size(), 6):
		var a: Vector2 = picks[k][1]
		var b := a + f.wind_dir * len_px
		if not area.grow(-6.0).has_point(b):
			continue
		_arrow(ci, a, b, Color(0, 0, 0, 0.55), 4.0, 8.0)
		_arrow(ci, a, b, Color.WHITE, 2.0, 7.0)


# --- Small helpers -------------------------------------------------------------------

func _t(ci: CanvasItem, font: Font, pos: Vector2, s: String, fs: int, col: Color, width: float) -> void:
	ci.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, width, fs, col, TextServer.JUSTIFICATION_NONE)


func _label(ci: CanvasItem, font: Font, pos: Vector2, s: String, fs: int, col := Color.WHITE) -> void:
	ci.draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(0, 0, 0, 0.75))
	ci.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


static func _km(m: float) -> String:
	return ("%d km" % int(m / 1000.0)) if fmod(m, 1000.0) == 0.0 else ("%.1f km" % (m / 1000.0))


static func _arrow(ci: CanvasItem, a: Vector2, b: Vector2, col: Color, width: float, head: float) -> void:
	var d := (b - a).normalized()
	ci.draw_line(a, b - d * head * 0.5, col, width)
	var n := Vector2(-d.y, d.x)
	ci.draw_colored_polygon(PackedVector2Array([b, b - d * head + n * head * 0.6, b - d * head - n * head * 0.6]), col)


## A circle drawn only where it's inside r.
static func _clipped_circle(ci: CanvasItem, c: Vector2, rad: float, r: Rect2, col: Color, width: float) -> void:
	var seg := clampi(int(rad * 0.25), 48, 256)
	var run := PackedVector2Array()
	for k in seg + 1:
		var p := c + Vector2.from_angle(TAU * k / seg) * rad
		if r.has_point(p):
			run.append(p)
		else:
			if run.size() > 1:
				ci.draw_polyline(run, col, width)
			run.clear()
	if run.size() > 1:
		ci.draw_polyline(run, col, width)


## A dashed line drawn only inside r. True if any of it showed.
static func _dashed_clipped(ci: CanvasItem, a: Vector2, b: Vector2, r: Rect2, col: Color, width: float) -> bool:
	var len := a.distance_to(b)
	var d := (b - a) / len
	var shown := false
	var s := 0.0
	while s < len:
		var p := a + d * s
		var q := a + d * minf(s + 7.0, len)
		if r.has_point(p) and r.has_point(q):
			ci.draw_line(p, q, col, width)
			shown = true
		s += 12.0
	return shown


## Pulls a point inside r (for labels on lines that start off the picture).
static func _clip_point_towards(p: Vector2, r: Rect2) -> Vector2:
	return p.clamp(r.position, r.end)
