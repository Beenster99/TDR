class_name Stepper
extends Button
## Controller-friendly value picker: "Laps   < 3 >". Left/right (D-pad, stick,
## arrow keys) changes the value; A / click steps forward and wraps.

signal value_changed(value)

var label_text := ""
var options: Array = []        ## [[value, "display"], ...] for choice lists
var min_value := 0.0
var max_value := 10.0
var step_value := 1.0
var value = 0
var suffix := ""


static func numeric(p_label: String, p_min: float, p_max: float, p_step: float, p_value: float, p_suffix := "") -> Stepper:
	var s := Stepper.new()
	s.label_text = p_label
	s.min_value = p_min
	s.max_value = p_max
	s.step_value = p_step
	s.value = p_value
	s.suffix = p_suffix
	s._refresh()
	return s


static func choice(p_label: String, p_options: Array, p_value) -> Stepper:
	var s := Stepper.new()
	s.label_text = p_label
	s.options = p_options
	s.value = p_value
	s._refresh()
	return s


func _ready() -> void:
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	custom_minimum_size = Vector2(420, 40)
	pressed.connect(func(): _nudge(1, true))


func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event.is_action_pressed("ui_left"):
		_nudge(-1, false)
		accept_event()
	elif event.is_action_pressed("ui_right"):
		_nudge(1, false)
		accept_event()


func _nudge(dir: int, wrap: bool) -> void:  # wrap: numeric values loop when pressed
	if options.is_empty():
		var v: float = value + dir * step_value
		if wrap and v > max_value:
			v = min_value
		value = clampf(v, min_value, max_value)
		if step_value == int(step_value):
			value = int(value)
	else:
		var i := 0
		for k in options.size():
			if options[k][0] == value:
				i = k
		i += dir
		i = posmod(i, options.size())
		value = options[i][0]
	_refresh()
	Sound.ui("ui_tick")
	value_changed.emit(value)


func set_value(v) -> void:
	value = v
	_refresh()


func _refresh() -> void:
	var shown := str(value) + suffix
	for o in options:
		if o[0] == value:
			shown = o[1]
	text = "%-16s <  %s  >" % [label_text, shown]
