class_name ResultsDriver
extends VBoxContainer
## One driver's whole race on the results screen, opened by clicking their
## row (or A on it): the summary (grid to finish, best and average lap,
## potential lap, stops, penalties, points), every lap with its position,
## lap time, sector times, gap to the leader, tyre, tyre temperature and
## fuel, the rubber left on each tyre (FL FR RL RR) lap by lap and on a
## graph when tyre wear is on, their lap times on a graph against the
## winner's, and each stint (with the tyres' wear at its end) and pit stop.
## Purple = the best in the field, green = the driver's own best.

const PURPLE := Color(0.78, 0.45, 1.0)
const GREEN := Color(0.35, 0.9, 0.45)
const DIM := Color(1, 1, 1, 0.55)
const INK := Color(1, 1, 1, 0.92)
const ME := Color("#3987e5")
const REF := Color("#d95926")
const WHEELS := ["FL", "FR", "RL", "RR"]
const WEAR_W := 30        ## one tyre's column in the lap table

var data: Dictionary = {}
var row: Dictionary = {}


func setup(d: Dictionary, r: Dictionary) -> void:
	data = d
	row = r
	add_theme_constant_override("separation", 10)
	size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_summary())
	var mid := HBoxContainer.new()
	mid.size_flags_vertical = SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 16)
	add_child(mid)
	var laps := _panel()
	laps.size_flags_horizontal = SIZE_EXPAND_FILL
	laps.size_flags_stretch_ratio = 1.25
	mid.add_child(laps)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 4)
	laps.add_child(lv)
	lv.add_child(_label("LAP BY LAP", 15, RaceResults.ACCENT))
	lv.add_child(_lap_header())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	lv.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 1)
	scroll.add_child(list)
	var log: Array = r.get("lap_log", [])
	if log.is_empty():
		list.add_child(_label("No laps completed.", 14, DIM))
	for l in log:
		list.add_child(_lap_row(l))
	var side := VBoxContainer.new()
	side.size_flags_horizontal = SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 10)
	mid.add_child(side)
	side.add_child(_lap_graph())
	if _has_wear():
		side.add_child(_wear_graph())
	side.add_child(_stops())


## Tyre wear was on and this driver's laps have it.
func _has_wear() -> bool:
	if not data.get("wear", false):
		return false
	for l in row.get("lap_log", []):
		if (l.get("wear", []) as Array).size() >= 4:
			return true
	return false


## Percent of rubber left from a wear (0 new .. 1 worn out).
static func left_pct(wear: float) -> int:
	return roundi((1.0 - clampf(wear, 0.0, 1.0)) * 100.0)


## The car this driver is compared with on the graph: the winner (or P2
## when they won).
func _reference() -> Dictionary:
	var rows: Array = data.get("rows", [])
	for r in rows:
		if r["car"] != row["car"] and not (r.get("lap_log", []) as Array).is_empty():
			return r
	return {}


func _summary() -> Control:
	var p := _panel()
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 34)
	p.add_child(h)
	var who := VBoxContainer.new()
	who.add_theme_constant_override("separation", 0)
	h.add_child(who)
	var status := str(row.get("status", ""))
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	who.add_child(top)
	top.add_child(_label(status if status != "" else "P%d" % int(row["pos"]), 34,
		Color(1, 0.45, 0.4) if status != "" else (RaceResults.GOLD if row.get("is_me", false) else Color.WHITE)))
	var nm := _label(str(row["name"]), 30, Color.WHITE)
	nm.size_flags_vertical = SIZE_SHRINK_END
	top.add_child(nm)
	who.add_child(_label("%s%s" % [row["car_name"], "  ·  AI" if row.get("is_ai", false) else ""], 15, DIM))
	var grid := int(row.get("grid", 0))
	var g := int(row.get("gained", 0))
	if grid > 0 and not data.get("quali", false):
		_stat(h, "GRID TO FINISH", "P%d → %s" % [grid, status if status != "" else "P%d" % int(row["pos"])],
			"retired" if status != "" else (("+%d place%s" % [g, "" if g == 1 else "s"]) if g > 0 else
				(("%d place%s" % [g, "" if g == -1 else "s"]) if g < 0 else "held position")))
	if not data.get("derby", false):
		_stat(h, "BEST LAP", RaceResults.fmt_time(float(row["best_lap"])),
			"lap %d" % int(row["best_lap_no"]) if int(row.get("best_lap_no", 0)) > 0 else "", PURPLE if row.get("fastest", false) else Color.WHITE)
		_stat(h, "AVERAGE LAP", RaceResults.fmt_time(float(row["avg_lap"])), "%d laps" % int(row["laps"]))
		_stat(h, "POTENTIAL LAP", RaceResults.fmt_time(float(row["potential"])), "best sectors added up")
		if data.get("pits", false):
			var stops: Array = row.get("stop_log", [])
			var still := 0.0
			for s in stops:
				still += float(s.get("stationary_s", 0.0))
			_stat(h, "PIT STOPS", str(int(row["stops"])), "%.1f s stationary" % still if still > 0.0 else "")
	var extra := []
	if float(row.get("penalty_s", 0.0)) > 0.0:
		extra.append("+%d s penalties" % int(row["penalty_s"]))
	if int(row.get("points", 0)) > 0:
		extra.append("%d points" % int(row["points"]))
	if not extra.is_empty():
		_stat(h, "RESULT", str(row.get("gap", "")) if str(row.get("gap", "")) != "" else RaceResults.fmt_time(float(row["time"])),
			"  ·  ".join(extra))
	return p


func _stat(parent: Control, title: String, value: String, note := "", col := Color.WHITE) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	parent.add_child(v)
	v.add_child(_label(title, 12, DIM))
	v.add_child(_label(value, 21, col))
	if note != "":
		v.add_child(_label(note, 12, DIM))


## Columns: heading, width, alignment (0 left, 2 right).
func _lap_columns() -> Array:
	var out := [["LAP", 38, 0], ["POS", 40, 0], ["LAP TIME", 86, 2]]
	for s in int(data.get("sector_count", 0)):
		out.append(["S%d" % (s + 1), 64, 2])
	out.append_array([["GAP", 74, 2], ["", 8, 0], ["TYRE", 92, 0], ["TYRE TEMP", 74, 2]])
	if _has_wear():
		out.append(["WEAR", WEAR_W * 4 + 18, 2])
	out.append_array([["FUEL", 70, 2], ["WEATHER", 70, 0]])
	return out


func _lap_header() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	for c in _lap_columns():
		if c[0] == "WEAR":
			h.add_child(_wear_cells(["FL", "FR", "RL", "RR"].map(func(x): return [x, DIM]), 12))
			continue
		var l := _label(c[0], 12, DIM)
		l.custom_minimum_size = Vector2(c[1], 0)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if c[2] == 2 else HORIZONTAL_ALIGNMENT_LEFT
		h.add_child(l)
	return h


func _lap_row(l: Dictionary) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	var pitted: bool = l.get("pitted", false)
	sb.bg_color = Color(1, 0.8, 0.3, 0.09) if pitted else Color(1, 1, 1, 0.04 if int(l["lap"]) % 2 == 0 else 0.0)
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	sb.set_corner_radius_all(2)
	p.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	p.add_child(h)
	var field_best: Array = data.get("best_sectors", [])
	var own_best: Array = row.get("best_sectors", [])
	var cells := [[str(int(l["lap"])), DIM], ["P%d" % int(l["pos"]) if int(l["pos"]) > 0 else "-", INK]]
	var t := float(l["time"])
	var tcol := INK
	if t > 0.0 and is_equal_approx(t, float(data.get("fastest", {}).get("time", -1.0))) and row.get("fastest", false):
		tcol = PURPLE
	elif t > 0.0 and is_equal_approx(t, float(row.get("best_lap", -1.0))):
		tcol = GREEN
	cells.append([RaceResults.fmt_time(t), tcol])
	var secs: Array = l.get("sectors", [])
	for s in int(data.get("sector_count", 0)):
		var v: float = float(secs[s]) if s < secs.size() else 0.0
		var col := INK
		if v > 0.0 and s < field_best.size() and is_equal_approx(v, float(field_best[s])):
			col = PURPLE
		elif v > 0.0 and s < own_best.size() and is_equal_approx(v, float(own_best[s])):
			col = GREEN
		cells.append([RaceResults.fmt_sector(v), col])
	var gap := float(l.get("gap", 0.0))
	cells.append(["Leader" if gap < 0.05 and int(l["pos"]) == 1 else "+%.1f" % gap, DIM])
	cells.append(["", INK])
	var cid := str(l.get("compound", ""))
	cells.append([str(data.get("compounds", {}).get(cid, cid)) + ("   PIT" if pitted else ""), INK])
	cells.append([Units.temp(float(l.get("tyre_c", 0.0))) if float(l.get("tyre_c", 0.0)) > 0.0 else "", DIM])
	var has_wear := _has_wear()
	if has_wear:
		cells.append(["wear", INK])
	cells.append([Units.fuel(float(l.get("fuel_l", 0.0))) if float(l.get("fuel_l", 0.0)) > 0.0 else "", DIM])
	cells.append([str(l.get("weather", "")).capitalize(), DIM])
	var cols := _lap_columns()
	var tyre_col := cols.size() - (5 if has_wear else 4)
	for k in cells.size():
		if has_wear and k == tyre_col + 2:   # rubber left on each tyre
			var wl: Array = l.get("wear", [])
			var parts := []
			for w in 4:
				if w < wl.size():
					var wt := float(wl[w])
					parts.append(["%d" % left_pct(wt), ResultsTable.wear_colour(wt) if wt > 0.45 else INK])
				else:
					parts.append(["", INK])
			h.add_child(_wear_cells(parts, 14))
			continue
		if k == tyre_col:   # the tyre: a colour dot then the name
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 5)
			box.custom_minimum_size = Vector2(cols[k][1], 0)
			var dot := ColorRect.new()
			dot.color = ResultsTable.compound_colour(cid) if cid != "" else Color(0, 0, 0, 0)
			dot.custom_minimum_size = Vector2(8, 8)
			dot.size_flags_vertical = SIZE_SHRINK_CENTER
			box.add_child(dot)
			var tl := _label(cells[k][0], 14, cells[k][1])
			if pitted:
				tl.add_theme_color_override("font_color", RaceResults.GOLD)
			box.add_child(tl)
			h.add_child(box)
			continue
		var lab := _label(cells[k][0], 14, cells[k][1])
		lab.custom_minimum_size = Vector2(cols[k][1], 0)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if cols[k][2] == 2 else HORIZONTAL_ALIGNMENT_LEFT
		lab.clip_text = true
		h.add_child(lab)
	return p


## Their lap times against the winner's (or P2's). The scale stops a little
## above a normal lap so the slow first lap and the pit laps don't flatten
## everything; those run off the top, with a ring on the pit laps.
func _lap_graph() -> Control:
	var p := _panel()
	p.size_flags_vertical = SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = 1.3
	var v := VBoxContainer.new()
	p.add_child(v)
	var ref := _reference()
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	v.add_child(h)
	h.add_child(_label("LAP TIMES", 15, RaceResults.ACCENT))
	if not ref.is_empty():
		h.add_child(_label("against %s (P%d)" % [ref["name"], int(ref["pos"])], 12, DIM))
	var g := ResultsGraph.new()
	g.axis_text = func(x: float) -> String: return "%d:%02d" % [int(x) / 60, int(x) % 60]
	g.value_text = func(x: float) -> String: return RaceResults.fmt_time(x)
	g.size_flags_vertical = SIZE_EXPAND_FILL
	g.custom_minimum_size = Vector2(0, 160)
	v.add_child(g)
	var series := []
	var times := []
	for r in [ref, row]:
		if r.is_empty():
			continue
		var pts := []
		var marks := []
		for l in r.get("lap_log", []):
			if float(l["time"]) > 0.0:
				pts.append(Vector2(int(l["lap"]), float(l["time"])))
				times.append(float(l["time"]))
			if l.get("pitted", false):
				marks.append(int(l["lap"]))
		series.append({"car": r["car"], "name": r["name"], "points": pts, "marks": marks})
	var cols := {int(row["car"]): ME}
	if not ref.is_empty():
		cols[int(ref["car"])] = REF
	times.sort()
	var lo := float(times[0]) if not times.is_empty() else 0.0
	var med := float(times[times.size() / 2]) if not times.is_empty() else 1.0
	g.set_data(series, cols, [floorf(lo - 0.6), ceilf(maxf(med * 1.06, lo + 3.0))])
	return p


## Four right-aligned cells, one per tyre: [[text, colour], ...].
func _wear_cells(parts: Array, sz: int) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.custom_minimum_size = Vector2(WEAR_W * 4 + 18, 0)
	for p in parts:
		var lab := _label(p[0], sz, p[1])
		lab.custom_minimum_size = Vector2(WEAR_W, 0)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		box.add_child(lab)
	return box


## Rubber left on each tyre lap by lap, one line per corner, from 100 % on
## the grid; a ring on the laps they pitted (new tyres put a line back up).
func _wear_graph() -> Control:
	var p := _panel()
	p.size_flags_vertical = SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	p.add_child(v)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	v.add_child(h)
	h.add_child(_label("TYRE WEAR", 15, RaceResults.ACCENT))
	h.add_child(_label("rubber left on each tyre as each lap ended", 12, DIM))
	var g := ResultsGraph.new()
	g.y_format = "%.0f%%"
	g.value_text = func(x: float) -> String: return "%d%% left" % roundi(x)
	g.size_flags_vertical = SIZE_EXPAND_FILL
	g.custom_minimum_size = Vector2(0, 130)
	v.add_child(g)
	var series := []
	var cols := {}
	var lo := 100.0
	for t in 4:
		var pts := [Vector2(0, 100.0)]
		var marks := []
		for l in row.get("lap_log", []):
			var wl: Array = l.get("wear", [])
			if wl.size() < 4:
				continue
			var left := (1.0 - clampf(float(wl[t]), 0.0, 1.0)) * 100.0
			pts.append(Vector2(int(l["lap"]), left))
			lo = minf(lo, left)
			if l.get("pitted", false):
				marks.append(int(l["lap"]))
		series.append({"car": t, "name": WHEELS[t], "points": pts, "marks": marks})
		cols[t] = ResultsAnalysis.SLOTS[t]
	g.set_data(series, cols, [maxf(floorf((lo - 5.0) / 10.0) * 10.0, 0.0), 100.0])
	return p


func _stops() -> Control:
	var p := _panel()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	p.add_child(v)
	v.add_child(_label("STINTS AND PIT STOPS", 15, RaceResults.ACCENT))
	var comps: Dictionary = data.get("compounds", {})
	var stints: Array = row.get("stints", [])
	if stints.is_empty():
		v.add_child(_label("No laps completed.", 14, DIM))
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	bar.custom_minimum_size = Vector2(0, 16)
	for st in stints:
		var seg := ColorRect.new()
		seg.color = Color(ResultsTable.compound_colour(str(st["compound"])), 0.85)
		seg.size_flags_horizontal = SIZE_EXPAND_FILL
		seg.size_flags_stretch_ratio = maxf(float(st["laps"]), 0.5)
		bar.add_child(seg)
	if not stints.is_empty():
		v.add_child(bar)
	for k in stints.size():
		var st: Dictionary = stints[k]
		var nm := str(comps.get(st["compound"], st["compound"]))
		var line := "Stint %d   %s   laps %d-%d  (%d lap%s)" % [k + 1, nm, int(st["from"]), int(st["to"]),
			int(st["laps"]), "" if int(st["laps"]) == 1 else "s"]
		var we: Array = st.get("wear_end", [])
		if data.get("wear", false) and we.size() >= 4:
			var w_txt := []
			for t in 4:
				w_txt.append("%s %d%%" % [WHEELS[t], left_pct(float(we[t]))])
			line += "   ·   left at the end: " + "  ".join(w_txt)
		v.add_child(_label(line, 14, INK))
	var stops: Array = row.get("stop_log", [])
	if not stops.is_empty():
		v.add_child(_gap(4))
	for k in stops.size():
		var s: Dictionary = stops[k]
		var parts := ["Stop %d   lap %d" % [k + 1, int(s.get("lap", 0))]]
		if float(s.get("stationary_s", 0.0)) > 0.0:
			parts.append("%.1f s stationary" % float(s["stationary_s"]))
		var ty := str(s.get("tyre", ""))
		if ty != "":
			parts.append("new " + str(comps.get(ty, ty.capitalize())).to_lower() + " tyres")
		if float(s.get("fuel_l", 0.0)) > 0.1:
			parts.append(Units.fuel(float(s["fuel_l"])) + " fuel")
		if str(s.get("driver", "")) != "":
			parts.append("%s took over" % s["driver"])
		if s.get("in_window", false):
			parts.append("in the window")
		v.add_child(_label("   ·   ".join(parts), 14, Color(1, 0.86, 0.6)))
	if stops.is_empty() and data.get("pits", false):
		v.add_child(_label("No pit stops.", 14, DIM))
	return p


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.075, 0.09, 0.95)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _label(text: String, sz: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	return l


func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c
