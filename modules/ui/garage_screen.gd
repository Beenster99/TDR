class_name GarageScreen
extends Control
## The garage: buy cars into your garage (saved for good in the team
## profile), spend the team budget on R&D upgrades (engine, aero, brakes,
## suspension, weight, tyres) and paint each car's livery, with the car
## turning on a stand in 3D so visible parts (splitter, wings, canards,
## calipers, rims, ride height) show as you pick them.
##
## Controller: up/down moves between rows, left/right changes a row, A on
## "Buy" pays for the picked levels, B (ui_cancel) leaves. Picked but unpaid
## levels are only a preview; leaving drops them.
## Built for 1600x900 and scaled by the window (canvas_items), so it's sharp at 4K.

signal closed(car_id: String)

const BAR_MAX := {"kw_per_t": 600.0, "cla": 4.0, "brake_n": 40000.0, "grip": 1.6}

var profile: TeamProfile
var car_id := ""
var _pending := {}                ## category -> level picked but not paid for
var _car_stepper: Stepper
var _class_stepper: Stepper       ## filters the car list: a class, all, or your own cars
var _upgrade_steppers := {}       ## category -> Stepper
var _livery_steppers := {}        ## pattern / primary / secondary / accent -> Stepper
var _money_label: Label
var _cost_label: Label
var _status: Label
var _buy_button: Button
var _stats_grid: GridContainer
var _preview: CarPreview
var _rebuilding := false
var _message := ""            ## last buy result, shown until the next pick
var _own_label: Label
var _own_button: Button
var _leave_warned := false    ## pressed leave once with unpaid picks


## car: the car to open on (id). The profile is loaded from this machine.
func open(p_car_id: String, p_profile: TeamProfile = null) -> void:
	profile = p_profile if p_profile else TeamProfile.load_or_new()
	car_id = p_car_id if GameData.cars.has(p_car_id) else _all_car_ids()[0]
	_build()
	_select_car(car_id)
	_focus_first.call_deferred()


func _all_car_ids() -> Array:
	var ids: Array = []
	for cls in _classes():
		ids.append_array(CarCatalog.ids_in_class(GameData.cars, cls))
	return ids


## Circuit classes, then the Demolition Derby cars.
func _classes() -> Array:
	return Array(CarCatalog.classes(GameData.cars)) + Array(CarCatalog.classes(GameData.cars, "derby"))


func _def() -> CarDefinition:
	return GameData.cars[car_id]


func _levels_with_pending() -> Dictionary:
	var l := profile.levels(car_id)
	for k in _pending:
		l[k] = _pending[k]
	return l


func _livery() -> Dictionary:
	var l := CarView.default_livery(_def())
	l.merge(profile.livery_for(car_id), true)
	return l


# --- Layout ---------------------------------------------------------------

func _build() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.085)
	add_child(bg)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	add_child(margin)
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 28)
	margin.add_child(cols)

	# Left: the car on its stand, then its numbers.
	var left := VBoxContainer.new()
	left.size_flags_horizontal = SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 12)
	cols.add_child(left)
	var title := Label.new()
	title.text = "GARAGE"
	title.add_theme_font_size_override("font_size", 40)
	left.add_child(title)
	_preview = CarPreview.new()
	_preview.size_flags_vertical = SIZE_EXPAND_FILL
	_preview.custom_minimum_size = Vector2(760, 440)
	left.add_child(_preview)
	_stats_grid = GridContainer.new()
	_stats_grid.columns = 4
	_stats_grid.add_theme_constant_override("h_separation", 18)
	left.add_child(_stats_grid)

	# Right: money, car, upgrades, livery, buttons.
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(560, 0)
	right.add_theme_constant_override("separation", 3)
	cols.add_child(right)
	_money_label = Label.new()
	_money_label.add_theme_font_size_override("font_size", 28)
	_money_label.add_theme_color_override("font_color", Color(0.55, 0.95, 0.6))
	right.add_child(_money_label)
	_class_stepper = Stepper.choice("Class", _class_options(), _def().class_tag)
	_class_stepper.value_changed.connect(func(_v): _filter_changed())
	_class_stepper.custom_minimum_size = Vector2(560, 36)
	right.add_child(_class_stepper)
	_car_stepper = Stepper.choice("Car", _car_options(), car_id)
	_car_stepper.value_changed.connect(func(v): _select_car(v))
	right.add_child(_car_stepper)
	var own_row := HBoxContainer.new()
	own_row.add_theme_constant_override("separation", 8)
	right.add_child(own_row)
	_own_label = Label.new()
	_own_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_own_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	own_row.add_child(_own_label)
	_own_button = _button(own_row, "Buy car", _buy_or_sell_car)
	_own_button.size_flags_horizontal = SIZE_SHRINK_END
	_own_button.custom_minimum_size = Vector2(240, 44)
	right.add_child(_heading("R&D upgrades"))
	for cat in UpgradeCatalog.category_ids():
		var info := UpgradeCatalog.category(cat)
		var st := Stepper.choice(info.get("name", cat), [], 0)
		st.custom_minimum_size = Vector2(560, 36)
		st.tooltip_text = info.get("blurb", "")
		st.value_changed.connect(func(v): _pick_level(cat, int(v)))
		right.add_child(st)
		_upgrade_steppers[cat] = st
	_cost_label = Label.new()
	_cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_cost_label)
	_status = _cost_label   # one line for prices and messages
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	right.add_child(row)
	_buy_button = _button(row, "Buy", _buy)
	_button(row, "Reset picks", func(): _pending.clear(); _refresh())

	right.add_child(_heading("Livery"))
	var opts := UpgradeCatalog.livery_options()
	var pattern_opts := []
	for p in opts.get("patterns", ["solid"]):
		pattern_opts.append([p, opts.get("pattern_names", {}).get(p, p)])
	var colour_opts := []
	for c in opts.get("palette", []):
		colour_opts.append([c[0], c[1]] if c is Array else [c, c])
	_livery_steppers["pattern"] = Stepper.choice("Pattern", pattern_opts, "solid")
	_livery_steppers["primary"] = Stepper.choice("Main colour", colour_opts, "")
	_livery_steppers["secondary"] = Stepper.choice("Second colour", colour_opts, "")
	_livery_steppers["accent"] = Stepper.choice("Accent colour", colour_opts, "")
	var sponsor_opts := [[0, "New each race"], [-1, "None (clean car)"]]
	for k in range(1, 25):
		sponsor_opts.append([k, "%s package" % CarView.title_sponsor(k)])
	_livery_steppers["sponsor_pack"] = Stepper.choice("Sponsors", sponsor_opts, 0)
	for k in _livery_steppers:
		var st: Stepper = _livery_steppers[k]
		st.custom_minimum_size = Vector2(560, 36)
		st.value_changed.connect(func(_v): _livery_changed())
		right.add_child(st)
	var spacer := Control.new()
	spacer.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(spacer)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	right.add_child(row2)
	_button(row2, "Default livery", func():
		profile.set_livery(car_id, {})
		profile.save()
		_select_car(car_id))
	_button(row2, "Done", _close)
	var help := Label.new()
	help.text = "Up/down: choose  ·  Left/right: change  ·  A: buy  ·  B: leave\nBought cars, upgrades and liveries are saved straight away. Picked levels are a preview until you buy them. Selling refunds half."
	help.modulate = Color(1, 1, 1, 0.45)
	help.add_theme_font_size_override("font_size", 13)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # never wider than the column
	right.add_child(help)
	# Slimmer rows so the whole column fits a 900-high screen (after add_child:
	# a Stepper sets its own size when it enters the tree).
	for c in right.get_children():
		if c is Stepper:
			c.custom_minimum_size = Vector2(560, 36)
	Sound.wire_buttons(self)


## The class filter: every class with its number of cars, all cars, and the cars you own.
func _class_options() -> Array:
	var opts := []
	for cls in _classes():
		opts.append([cls, "%s  (%d cars)" % [cls, CarCatalog.ids_in_class(GameData.cars, cls).size()]])
	opts.append(["", "All classes"])
	opts.append(["*owned", "My garage (%d)" % profile.owned_ids().size()])
	return opts


## The cars the class filter lets through (all of them if none would be).
func _filtered_ids() -> Array:
	var f: String = _class_stepper.value if is_instance_valid(_class_stepper) else ""
	var ids := _all_car_ids().filter(func(id):
		return f == "" or (profile.owns(id) if f == "*owned" else GameData.cars[id].class_tag == f))
	return ids if not ids.is_empty() else _all_car_ids()


func _car_options() -> Array:
	var opts := []
	var ids := _filtered_ids()
	if car_id != "" and not car_id in ids and _class_stepper and _class_stepper.value == "*owned":
		ids.push_front(car_id)   # just sold: stays shown until you pick another
	for id in ids:
		var c: CarDefinition = GameData.cars[id]
		opts.append([id, "%s%s  (%s)" % ["★ " if profile.owns(id) else "", c.display_name, c.class_tag]])
	return opts


func _filter_changed() -> void:
	var ids := _filtered_ids()
	if not car_id in ids:
		_select_car(ids[0])
	_car_stepper.options = _car_options()
	_car_stepper.set_value(car_id)


func _buy_or_sell_car() -> void:
	var def := _def()
	if profile.owns(car_id):
		if _own_button.text.begins_with("Sell") and not _own_button.text.ends_with("?"):
			_own_button.text = "Sell car: sure?"
			return
		var got := profile.sell_car(def)
		profile.save()
		_message = "Sold the %s for %s." % [def.display_name, UpgradeCatalog.format_money(got)]
	else:
		var price := UpgradeCatalog.car_price(def)
		if not profile.buy_car(def):
			_message = "Not enough money: the %s costs %s, the team has %s." % [def.display_name,
				UpgradeCatalog.format_money(price), UpgradeCatalog.format_money(profile.money)]
		else:
			profile.save()
			_message = "The %s is in your garage." % def.display_name
	_class_stepper.options = _class_options()
	_class_stepper.set_value(_class_stepper.value)
	_car_stepper.options = _car_options()
	_car_stepper.set_value(car_id)
	_pending.clear()
	_refresh()


func _heading(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 20)
	l.modulate = Color(1, 1, 1, 0.7)
	return l


func _button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(200, 44)
	b.size_flags_horizontal = SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _focus_first() -> void:
	if is_instance_valid(_class_stepper):
		_class_stepper.grab_focus()


func _rebuild_view() -> void:
	_preview.show_car(_def().with_overrides(UpgradeCatalog.overrides_for(_def(), _levels_with_pending())), _livery())


# --- Behaviour ------------------------------------------------------------

func _select_car(id: String) -> void:
	car_id = id
	_pending.clear()
	_rebuilding = true
	var liv := _livery()
	for k in _livery_steppers:
		var st: Stepper = _livery_steppers[k]
		var want = liv.get(k, st.options[0][0] if not st.options.is_empty() else "")
		if k == "sponsor_pack":
			want = int(want)
		elif k != "pattern":
			want = _nearest_palette(str(want), st.options)
		st.set_value(want)
	_rebuilding = false
	_refresh()


## The palette colour closest to a livery colour (default liveries use
## colours that are not in the palette).
func _nearest_palette(hex: String, options: Array) -> String:
	if options.is_empty():
		return hex
	var want := Color(hex) if Color.html_is_valid(hex) else Color.WHITE
	var best: String = options[0][0]
	var best_d := INF
	for o in options:
		var c := Color(str(o[0]))
		var d := Vector3(c.r - want.r, c.g - want.g, c.b - want.b).length_squared()
		if d < best_d:
			best_d = d
			best = o[0]
	return best


func _pick_level(cat: String, level: int) -> void:
	if _rebuilding:
		return
	_message = ""
	if level == profile.level(car_id, cat):
		_pending.erase(cat)
	else:
		_pending[cat] = level
	_refresh()


func _pending_cost() -> int:
	var total := 0
	for cat in _pending:
		total += profile.cost_to(_def(), cat, _pending[cat])
	return total


func _buy() -> void:
	if _pending.is_empty():
		_status.text = "Pick a level with left/right first."
		return
	var cost := _pending_cost()
	if cost > profile.money:
		_status.text = "Not enough money: that costs %s, the team has %s." % [
			UpgradeCatalog.format_money(cost), UpgradeCatalog.format_money(profile.money)]
		return
	# Sell first so refunds pay for the buys.
	var cats: Array = _pending.keys()
	cats.sort_custom(func(a, b): return profile.cost_to(_def(), a, _pending[a]) < profile.cost_to(_def(), b, _pending[b]))
	for cat in cats:
		profile.set_level(_def(), cat, _pending[cat])
	profile.save()
	_pending.clear()
	_message = "Done: %s %s." % ["paid" if cost >= 0 else "refunded", UpgradeCatalog.format_money(absi(cost))]
	_refresh()


func _livery_changed() -> void:
	if _rebuilding:
		return
	var liv := {}
	for k in _livery_steppers:
		liv[k] = _livery_steppers[k].value
	profile.set_livery(car_id, liv)
	profile.save()
	_rebuild_view()


func _refresh() -> void:
	var def := _def()
	_leave_warned = false
	_money_label.text = "Team budget  %s" % UpgradeCatalog.format_money(profile.money)
	var is_owned := profile.owns(car_id)
	if is_owned:
		_own_label.text = "In your garage"
		_own_label.add_theme_color_override("font_color", Color(0.55, 0.95, 0.6))
		var back := int(float(profile.cars[car_id].get("bought_for", UpgradeCatalog.car_price(def))) * UpgradeCatalog.refund_share())
		_own_button.text = "Sell car  +%s" % UpgradeCatalog.format_money(back)
	else:
		var price := UpgradeCatalog.car_price(def)
		_own_label.text = "Not yours yet: you can race it stock. Buy it to upgrade and paint it."
		_own_label.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
		_own_button.text = "Buy car  %s" % UpgradeCatalog.format_money(price)
		_own_button.disabled = false
	for k in _livery_steppers:
		_livery_steppers[k].disabled = not is_owned
	_rebuilding = true
	for cat in _upgrade_steppers:
		var st: Stepper = _upgrade_steppers[cat]
		var owned := profile.level(car_id, cat)
		var opts := []
		for l in UpgradeCatalog.max_level(cat) + 1:
			var info := UpgradeCatalog.level_info(cat, l)
			var tag := ""
			if l == owned:
				tag = "fitted"
			elif l < owned:
				tag = "sell +%s" % UpgradeCatalog.format_money(-profile.cost_to(def, cat, l))
			else:
				tag = UpgradeCatalog.format_money(profile.cost_to(def, cat, l))
			opts.append([l, "%s%s  ·  %s" % ["●".repeat(l) + "○".repeat(UpgradeCatalog.max_level(cat) - l) + "  ", info.get("name", ""), tag]])
		st.options = opts
		st.disabled = not profile.owns(car_id)
		st.set_value(_pending.get(cat, owned))
		st.modulate = Color(1, 0.9, 0.55) if _pending.has(cat) else Color.WHITE
	_rebuilding = false
	var cost := _pending_cost()
	if _pending.is_empty():
		_cost_label.text = _message
	elif cost >= 0:
		_cost_label.text = "Picked upgrades cost %s%s" % [UpgradeCatalog.format_money(cost),
			"  (not enough money)" if cost > profile.money else ""]
	else:
		_cost_label.text = "Selling refunds %s" % UpgradeCatalog.format_money(-cost)
	_buy_button.text = "Buy" if cost >= 0 else "Sell"
	_buy_button.disabled = _pending.is_empty() or cost > profile.money
	_show_stats()
	_rebuild_view()


func _show_stats() -> void:
	for c in _stats_grid.get_children():
		c.queue_free()
	var stock := UpgradeCatalog.stats(_def(), {})
	var now := UpgradeCatalog.stats(_def(), _levels_with_pending())
	var rows := [
		["Power", "power_kw", Units.power, "kw_per_t"],
		["Weight", "mass_kg", "%.0f kg", ""],
		["Power to weight", "kw_per_t", Units.power_per_tonne, "kw_per_t"],
		["Downforce", "cla", "%.2f", "cla"],
		["Brakes", "brake_n", "%.0f N", "brake_n"],
		["Grip", "grip", "%.2f", "grip"],
	]
	for r in rows:
		var name := Label.new()
		name.text = r[0]
		name.custom_minimum_size = Vector2(170, 0)
		_stats_grid.add_child(name)
		var a := Label.new()
		a.text = _fmt(r[2], stock[r[1]])
		a.modulate = Color(1, 1, 1, 0.6)
		a.custom_minimum_size = Vector2(130, 0)
		_stats_grid.add_child(a)
		var b := Label.new()
		var change: float = now[r[1]] / maxf(stock[r[1]], 1e-6) - 1.0
		b.text = _fmt(r[2], now[r[1]]) + ("" if absf(change) < 0.0005 else "  (%+.1f%%)" % (change * 100.0))
		var better: bool = change < 0.0 if r[1] == "mass_kg" else change > 0.0
		b.add_theme_color_override("font_color", Color(0.55, 0.95, 0.6) if better and absf(change) >= 0.0005 else Color(0.9, 0.9, 0.9))
		b.custom_minimum_size = Vector2(230, 0)
		_stats_grid.add_child(b)
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(160, 14)
		bar.size_flags_vertical = SIZE_SHRINK_CENTER
		var key: String = r[3]
		bar.max_value = BAR_MAX.get(key, 1.0)
		bar.value = now[key] if key != "" else 0.0
		bar.modulate.a = 1.0 if key != "" else 0.0
		_stats_grid.add_child(bar)


func _fmt(f, v: float) -> String:
	return f.call(v) if f is Callable else f % v


func _close() -> void:
	# Leaving with picked but unpaid upgrades: say so once, so nothing is lost by accident.
	if not _pending.is_empty() and not _leave_warned:
		_status.text = "You picked upgrades but haven't bought them. Press Buy to keep them, or leave again to drop them."
		_status.add_theme_color_override("font_color", Color(1, 0.8, 0.4))
		_leave_warned = true
		return
	closed.emit(car_id)
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()
