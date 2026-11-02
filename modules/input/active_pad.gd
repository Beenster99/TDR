class_name ActivePad
extends RefCounted
## Which game controller is driving. Only that controller's sticks and
## triggers reach the input actions; buttons work from any controller.
##
## Why: Windows and SDL often list extra "controllers" next to the real one:
## a wheel's pedal set, a flight stick, a laptop's motion sensor, a virtual
## pad from Steam or DS4Windows. Some of those report an axis that rests away
## from zero (a pedal at +1). With every controller feeding every action, that
## axis held steer_right or zoom_out down all race long: the car pulled to one
## side whichever pad was used, and the camera zoomed on its own.
##
## The active pad is the one the player last used: a button press, or a stick
## or trigger that moved well away from where it rested when we first saw it
## (a stuck axis never moves, so it never takes over). Before that, the first
## controller Godot recognises as a game pad.

const MOVE_TO_TAKE_OVER := 0.5   ## how far an axis must move from rest to pick its pad

## Device id of the active controller, -1 = none connected.
static var device := -1
## device -> {axis -> value it rested at when first seen}.
static var _rest: Dictionary = {}
static var _started := false


## Picks the starting pad and follows controllers being plugged in or out.
## Called by InputSetup.apply_bindings() (only the first call does anything).
static func start() -> void:
	if _started:
		return
	_started = true
	Input.joy_connection_changed.connect(_on_connection)
	for d in Input.get_connected_joypads():
		_note_rest(d)
	_choose(_best_connected())


## Feed every input event here (the Game autoload does, from _input).
## Returns true when the active pad changed.
static func observe(event: InputEvent) -> bool:
	if event is InputEventJoypadButton and event.pressed:
		return _choose(event.device)
	if event is InputEventJoypadMotion:
		var rest: Dictionary = _rest.get_or_add(event.device, {})
		if not rest.has(event.axis):
			rest[event.axis] = event.axis_value
			return false
		if absf(event.axis_value - float(rest[event.axis])) >= MOVE_TO_TAKE_OVER:
			return _choose(event.device)
	return false


## The value of one axis on the active pad (0 when there is none).
static func axis(a: JoyAxis) -> float:
	return Input.get_joy_axis(device, a) if device >= 0 else 0.0


static func pad_name() -> String:
	return Input.get_joy_name(device) if device >= 0 else ""


static func _on_connection(dev: int, connected: bool) -> void:
	if connected:
		_note_rest(dev)
		if device < 0:
			_choose(dev)
	else:
		_rest.erase(dev)
		if dev == device:
			device = -1
			_choose(_best_connected())


## Where each axis of a controller sits now (taken as its rest position).
static func _note_rest(dev: int) -> void:
	var rest := {}
	for a in JOY_AXIS_SDL_MAX:
		rest[a] = Input.get_joy_axis(dev, a)
	_rest[dev] = rest


## A recognised game pad first, then anything else connected.
static func _best_connected() -> int:
	var pads := Input.get_connected_joypads()
	for d in pads:
		if Input.is_joy_known(d):
			return d
	return pads[0] if not pads.is_empty() else -1


static func _choose(dev: int) -> bool:
	if dev == device and dev >= 0:
		return false
	device = dev
	bind_axes()
	if dev >= 0:
		print("[input] driving with controller %d: %s" % [dev, Input.get_joy_name(dev)])
	return true


## Points every stick / trigger binding (ours and Godot's ui_* ones) at the
## active pad, and lets go of anything another pad was holding down.
static func bind_axes() -> void:
	for action in InputMap.get_actions():
		var touched := false
		for ev in InputMap.action_get_events(action):
			if ev is InputEventJoypadMotion and ev.device != maxi(device, 0):
				var copy: InputEventJoypadMotion = ev.duplicate()
				copy.device = maxi(device, 0)
				InputMap.action_erase_event(action, ev)
				InputMap.action_add_event(action, copy)
				touched = true
		if touched:
			Input.action_release(action)
