class_name InputPrompt
extends RefCounted
## What the game's tips and button prompts should say: the key or button the
## player has mapped to an action, for the input device they touched last.
##
## Touch the keyboard or mouse and every prompt names keys ("Space", "G");
## press a controller button or move a stick and they name pad buttons ("A",
## "RT"). The names come from the player's own bindings (Settings >
## Controller), so a rebound action is shown by its new key or button.
##
## Use it like this:
##   InputPrompt.key("crew_grab")                 -> "G" or "X"
##   InputPrompt.fill("Put the gun down ({crew_grab})")
##   InputPrompt.pick("Click a car", "D-pad: pick a car")
## Text drawn every frame (_draw) just calls these. A Label set once keeps
## itself up to date with InputPrompt.live(label, func(): label.text = ...).

## How far the mouse must move in one event to count as "using the mouse"
## (pixels), so a nudged desk doesn't flip a pad player's prompts.
const MOUSE_MOVE := 6.0
## Shown when an action has no key or button at all.
const UNBOUND := "(not set)"

## true: the player last used a game controller; false: keyboard or mouse.
static var pad := false
## Goes up by one whenever what prompts say may have changed (the device
## switched, or bindings were changed). Live labels watch it.
static var serial := 0
static var _started := false


## Picks the starting device: a controller if one is plugged in, otherwise
## the keyboard. Called by InputSetup.apply_bindings(); only the first call
## sets the device.
static func start() -> void:
	if not _started:
		_started = true
		pad = ActivePad.device >= 0
	serial += 1


## Feed every input event here (the Game autoload does, from _input).
## Returns true when the prompts switched device.
static func observe(event: InputEvent) -> bool:
	var now := pad
	if event is InputEventKey and event.pressed:
		now = false
	elif event is InputEventMouseButton and event.pressed:
		now = false
	elif event is InputEventMouseMotion and event.relative.length() >= MOUSE_MOVE:
		now = false
	elif event is InputEventJoypadButton and event.pressed:
		now = true
	elif event is InputEventJoypadMotion and ActivePad.is_deliberate(event):
		now = true
	return set_pad(now)


## Switches the prompts to the controller (true) or keyboard / mouse (false).
static func set_pad(on: bool) -> bool:
	if on == pad:
		return false
	pad = on
	serial += 1
	return true


## Two wordings, one for each device: the one for the device in use.
static func pick(keyboard_text: String, pad_text: String) -> String:
	return pad_text if pad else keyboard_text


## The name of the key or button the player has mapped to an action, for the
## device in use ("Space" / "A"). An action with nothing on that device names
## its binding on the other one, so the player still learns how to do it.
static func key(action: String) -> String:
	var n := name_for(action, pad)
	if n.is_empty():
		n = name_for(action, not pad)
	return n if not n.is_empty() else UNBOUND


## The names of several actions' keys for the device in use, joined:
## keys(["crew_up", "crew_down"], "/") -> "W/S".
static func keys(actions: Array, sep := " / ") -> String:
	var out: Array[String] = []
	for a in actions:
		var n := key(str(a))
		if not n in out:
			out.append(n)
	return sep.join(out)


## The first binding of an action on a device ("" if it has none there).
static func name_for(action: String, on_pad: bool) -> String:
	if InputSetup.is_ours(action):
		var list: Array = InputSetup.pads_of(InputSetup.applied, action) if on_pad \
			else InputSetup.keys_of(InputSetup.applied, action)
		return InputSetup.describe("pad" if on_pad else "keys", list[0]) if not list.is_empty() else ""
	# Godot's own ui_* actions (menus): read what the input map holds.
	if not InputMap.has_action(action):
		return ""
	for ev in InputMap.action_get_events(action):
		if on_pad and ev is InputEventJoypadButton:
			return InputSetup.describe("pad", {"button": int(ev.button_index)})
		if on_pad and ev is InputEventJoypadMotion:
			return InputSetup.describe("pad", {"axis": int(ev.axis), "dir": signf(ev.axis_value)})
		if not on_pad and ev is InputEventKey:
			var code: int = ev.physical_keycode if ev.physical_keycode != KEY_NONE else ev.keycode
			if code != KEY_NONE:
				return InputSetup.describe("keys", code)
	return ""


## Two opposite actions in a few words: "A / D", or "Left stick" when both
## are the two ways of one stick ({steer_left} and {steer_right} on a pad).
static func pair(a: String, b: String) -> String:
	var na := key(a)
	var nb := key(b)
	for stick in ["Left stick", "Right stick"]:
		if na.begins_with(stick) and nb.begins_with(stick):
			return stick
	return na if na == nb else "%s / %s" % [na, nb]


## The name of a fixed controller button (one a screen reads directly, not
## through an action): "LB", or "L1" on a PlayStation pad.
static func button(b: JoyButton) -> String:
	return InputSetup.describe("pad", {"button": int(b)})


## Text with {action} names swapped for that action's key or button:
## "Hold {crew_gun} to wipe" -> "Hold Space to wipe" / "Hold RT to wipe".
## Braces around anything that isn't an input action are left alone.
static func fill(text: String) -> String:
	if not "{" in text:
		return text
	var out := ""
	var i := 0
	while i < text.length():
		var open := text.find("{", i)
		if open < 0:
			break
		var close := text.find("}", open)
		if close < 0:
			break
		var name := text.substr(open + 1, close - open - 1)
		out += text.substr(i, open - i)
		out += key(name) if InputMap.has_action(name) or InputSetup.is_ours(name) else text.substr(open, close - open + 1)
		i = close + 1
	return out + text.substr(i)


## Keeps a node's text right: calls refresh now and again whenever the
## device in use or the bindings change, for as long as the node lives.
## refresh: a Callable with no arguments, e.g. func(): label.text = ...
static func live(node: Node, refresh: Callable) -> void:
	refresh.call()
	var w := _Watcher.new()
	w.refresh = refresh
	w.seen = serial
	node.add_child(w, false, Node.INTERNAL_MODE_BACK)


class _Watcher extends Node:
	var refresh: Callable
	var seen := 0

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS   # pause menus too

	func _process(_dt: float) -> void:
		if seen != InputPrompt.serial:
			seen = InputPrompt.serial
			if refresh.is_valid():
				refresh.call()
