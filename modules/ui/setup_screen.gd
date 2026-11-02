class_name SetupScreen
extends Control
## Car setup screen (wave 4 per-track tuning), built in code and driven
## entirely by controller or keyboard: up/down picks a setting, left/right
## changes it, A on a button presses it, B saves and goes back.
##
## Left: every setting, grouped (aero, suspension, alignment, brakes and diff,
## gearing, tyres, fuel). Right: what the focused setting does in plain words,
## what the current setup does to the car (downforce, drag, top speed, ride
## height in the worst compression, hot tyre pressures), and notes about the
## track. Setups are saved per car per track (SetupStore).

signal closed(setup: Dictionary)

var car: CarDefinition
var track: TrackData
var compound: TyreCompound
var conditions := {}
var setup := {}
var _rows := {}           ## key -> Stepper
var _help_title: Label
var _help: Label
var _info: Label
var _notes: Label
var _focus_key := ""
var _first: Control


## conditions: track_c, wetness, laps, fuel_enabled, fuel_rate (for the
## recommended setup and the tyre pressure estimate).
func open(p_car: CarDefinition, p_track: TrackData, p_compound: TyreCompound, p_conditions := {}) -> void:
	car = p_car
	track = p_track
	compound = p_compound
	conditions = p_conditions.duplicate()
	if compound:
		conditions["compound"] = compound
	setup = CarSetup.complete(car, SetupStore.load_setup(car.id, track.id))
	_build()
	_refresh_all()
	_first.grab_focus.call_deferred()


func _build() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.08, 1.0)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 40)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)
	var title := Label.new()
	title.text = "CAR SETUP  ·  %s  ·  %s" % [car.display_name, track.display_name]
	title.add_theme_font_size_override("font_size", 30)
	root.add_child(title)
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 30)
	root.add_child(cols)
	# Left: the settings.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560, 0)
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	cols.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	list.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(list)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	list.add_child(buttons)
	_first = _button(buttons, "Save and back", _close)
	_button(buttons, "Recommended", _recommend).focus_entered.connect(func(): _show_help("", "Recommended",
		"A setup worked out for this car on this track and the race conditions: the same kind of setup the AI drivers use. A good starting point."))
	_button(buttons, "Default", _reset).focus_entered.connect(func(): _show_help("", "Default", "Back to the car's standard setup."))
	_first.focus_entered.connect(func(): _show_help("", "Save and back", "Keeps this setup for %s at %s. You can also press B (Esc)." % [car.display_name, track.short_name]))
	var group := ""
	for item in CarSetup.ITEMS:
		var key: String = item[0]
		if not CarSetup.adjustable(car, key):
			continue
		if item[1] != group:
			group = item[1]
			var h := Label.new()
			h.text = group.to_upper()
			h.modulate = Color(0.6, 0.9, 0.7)
			h.add_theme_font_size_override("font_size", 14)
			list.add_child(h)
		var st := Stepper.choice(item[2], _options(key), setup[key])
		st.loop_options = false
		st.custom_minimum_size = Vector2(540, 36)
		st.value_changed.connect(func(v): _changed(key, v))
		st.focus_entered.connect(func(): _show_help(key, item[2], item[4]))
		list.add_child(st)
		_rows[key] = st
	# Right: explanation, live effect, track notes.
	var side := VBoxContainer.new()
	side.size_flags_horizontal = SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 14)
	cols.add_child(side)
	_help_title = Label.new()
	_help_title.add_theme_font_size_override("font_size", 24)
	side.add_child(_help_title)
	_help = _wrapped(side, Color(1, 1, 1, 0.9))
	var sep := HSeparator.new()
	side.add_child(sep)
	_info = _wrapped(side, Color(0.8, 0.92, 1.0))
	_notes = _wrapped(side, Color(1, 0.85, 0.55))
	var keys := Label.new()
	keys.text = "Up/down: pick a setting  ·  Left/right: change it  ·  B / Esc: save and back"
	keys.modulate = Color(1, 1, 1, 0.45)
	keys.add_theme_font_size_override("font_size", 13)
	root.add_child(keys)


func _wrapped(parent: Node, colour: Color) -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(420, 0)
	l.modulate = colour
	parent.add_child(l)
	return l


func _button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(170, 40)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


## [[value, text], ...] for one setting, every step from min to max.
func _options(key: String) -> Array:
	var r := CarSetup.range_of(car, key)
	var out := []
	if key == "fuel_l":
		out.append([-1.0, "Auto"])
		var v := 5.0
		while v <= r[2] + 0.001:
			out.append([v, "%d L" % roundi(v)])
			v += 1.0
		return out
	var n := roundi((r[2] - r[1]) / r[3])
	for k in n + 1:
		var v: float = r[1] + snappedf(k * r[3], r[3])
		out.append([v, _format(key, v)])
	return out


func _format(key: String, v: float) -> String:
	if key.begins_with("pressure_") and compound:
		return "%.1f psi cold (%+.1f)" % [compound.cold_psi + v, v]
	return CarSetup.format_value(car, key, v)


## The option value nearest v (floats from a file may not match exactly).
func _nearest(st: Stepper, v: float):
	var best = st.options[0][0]
	for o in st.options:
		if absf(float(o[0]) - v) < absf(float(best) - v):
			best = o[0]
	return best


func _changed(key: String, v) -> void:
	setup[key] = float(v)
	_refresh_info()


func _recommend() -> void:
	setup = CarSetup.complete(car, SetupAdvisor.recommend(car, track, conditions))
	_refresh_all()
	Sound.ui("ui_tick")


func _reset() -> void:
	setup = CarSetup.defaults(car)
	_refresh_all()
	Sound.ui("ui_tick")


func _refresh_all() -> void:
	for key in _rows:
		var st: Stepper = _rows[key]
		st.set_value(_nearest(st, float(setup[key])))
		setup[key] = float(st.value)
	_refresh_info()
	var notes := SetupAdvisor.notes(car, track)
	_notes.text = "%s\n%s" % [track.display_name, "\n".join(notes)]


func _show_help(key: String, title: String, text: String) -> void:
	_focus_key = key
	_help_title.text = title
	var extra := ""
	if key != "":
		var d := CarSetup.defaults(car)
		extra = "\n\nDefault: %s" % _format(key, float(d[key]))
	_help.text = text + extra


## What this setup does to the car, in numbers a player can act on.
func _refresh_info() -> void:
	var tuned := car.with_overrides({"tuning": CarSetup.sanitize(car, setup)})
	var lines: Array[String] = []
	var df := tuned.cla / maxf(car.cla, 0.01) - 1.0
	var dr := tuned.cda / maxf(car.cda, 0.01) - 1.0
	lines.append("Downforce %+d%%  ·  drag %+d%%  ·  %d%% of it on the front" % [roundi(df * 100.0), roundi(dr * 100.0),
		roundi(tuned.aero_balance_front * 100.0)])
	lines.append("Top speed at the limiter: %d km/h" % roundi(CarSetup.top_speed(tuned, tuned.final_drive) * 3.6))
	var lap := SetupAdvisor.analyse(tuned, track)
	var sink := SetupAdvisor.worst_sink(tuned, lap)
	var low_f: float = tuned.ride_front_mm - sink[0]
	var low_r: float = tuned.ride_rear_mm - sink[1]
	var warn := ""
	if minf(low_f, low_r) < tuned.plank_mm:
		warn = "  ·  THE FLOOR HITS THE GROUND"
	elif minf(low_f, low_r) < tuned.plank_mm + 3.0:
		warn = "  ·  close to bottoming"
	lines.append("Lowest ride height on this lap: front %d mm, rear %d mm (floor touches at %d mm)%s" % [
		roundi(low_f), roundi(low_r), roundi(tuned.plank_mm), warn])
	if compound:
		var track_c := float(conditions.get("track_c", 32.0))
		var t := compound.optimal_temp_c + 2.0 + SetupAdvisor.TYRE_TEMP_PER_TRACK_C * (track_c - 33.0)
		var pf := compound.hot_psi(tuned.pressure_delta_front, t)
		var pr := compound.hot_psi(tuned.pressure_delta_rear, t)
		lines.append("Hot tyre pressure at about %d C: front %.1f, rear %.1f psi (best %.1f)" % [roundi(t), pf, pr, compound.optimal_hot_psi])
	var tips: Array[String] = []
	var roll_f := tuned.roll_stiffness_front - car.roll_stiffness_front
	if tuned.aero_balance_front - car.aero_balance_front > 0.02 or roll_f < -0.03:
		tips.append("more oversteer")
	elif tuned.aero_balance_front - car.aero_balance_front < -0.02 or roll_f > 0.03:
		tips.append("more understeer")
	if not tips.is_empty():
		lines.append("Balance vs default: " + ", ".join(tips))
	lines.append("Track %d C%s" % [roundi(float(conditions.get("track_c", 32.0))), ", wet" if float(conditions.get("wetness", 0.0)) > 0.2 else ""])
	_info.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()


func _close() -> void:
	var values := CarSetup.sanitize(car, setup)
	# Only what differs from the default is kept.
	var d := CarSetup.defaults(car)
	var diff := {}
	for k in values:
		if absf(float(values[k]) - float(d[k])) > 0.0001:
			diff[k] = values[k]
	if diff.is_empty():
		SetupStore.erase(car.id, track.id)
	else:
		SetupStore.save_setup(car.id, track.id, diff)
	closed.emit(diff)
	queue_free()
