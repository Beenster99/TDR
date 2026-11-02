class_name InputSetup
extends RefCounted
## Registers every input action in code (keyboard + gamepad), so the project
## file stays readable. Called once at startup by the game module, with the
## player's own bindings from Settings > Controller laid over the defaults.
##
## Player bindings ("overrides", saved in GameData.prefs["controls"]):
##   {action: {"keys": [physical keycode, ...], "pad": [pad binding, ...]}}
## A pad binding is {"button": JoyButton} or {"axis": JoyAxis, "dir": -1.0 | 1.0}.
## An action without "keys" (or "pad") keeps its default keys (or pad).

const KEYS := {
	"accelerate": [KEY_W, KEY_UP],
	"brake": [KEY_S, KEY_DOWN],
	"steer_left": [KEY_A, KEY_LEFT],
	"steer_right": [KEY_D, KEY_RIGHT],
	"camera_toggle": [KEY_C],
	"restart_race": [KEY_R],
	"back_to_menu": [KEY_ESCAPE],
	"zoom_in": [KEY_E, KEY_EQUAL, KEY_KP_ADD, KEY_PAGEUP],
	"zoom_out": [KEY_Q, KEY_MINUS, KEY_KP_SUBTRACT, KEY_PAGEDOWN],
	"zoom_full": [KEY_Z, KEY_TAB],
	"strategy_screen": [KEY_P],
	"pit_box": [KEY_B],
	"pit_limiter": [KEY_L],
	"pit_tyres": [KEY_T],
	"pit_fuel": [KEY_F],
	"pit_wheels": [KEY_Y],     # which tyres the next stop changes (all, fronts, rears, a side, one)
	"pit_driver": [KEY_N],     # driver change at the next stop (co-driver / team mate)
	"team_radio": [KEY_V],     # radio / pings between the driver and the pit wall (co-op)
	"crew_tab": [KEY_C],       # pit wall roles: switch between pit crew and strategy
	"shift_up": [KEY_SHIFT, KEY_PERIOD],      # manual gearbox (Settings > Gameplay)
	"shift_down": [KEY_CTRL, KEY_COMMA],
	"hud_tower": [KEY_H],      # race HUD: timing tower on/off (also Settings > Gameplay)
	"hud_edit": [KEY_F2],      # race HUD: layout editor (move, resize, hide items; also Settings > Gameplay)
	# Pit crew mini-game (a wheel gunner in the box): run about, hold the gun.
	"crew_up": [KEY_W, KEY_UP],
	"crew_down": [KEY_S, KEY_DOWN],
	"crew_left": [KEY_A, KEY_LEFT],
	"crew_right": [KEY_D, KEY_RIGHT],
	"crew_gun": [KEY_SPACE, KEY_ENTER],
}
## Gamepad: analog triggers + left stick. Buttons use the Xbox layout names
## (Godot maps PlayStation/Nintendo pads to the same positions).
const PAD_AXES := {
	"accelerate": [JOY_AXIS_TRIGGER_RIGHT, 1.0],
	"brake": [JOY_AXIS_TRIGGER_LEFT, 1.0],
	"steer_left": [JOY_AXIS_LEFT_X, -1.0],
	"steer_right": [JOY_AXIS_LEFT_X, 1.0],
	"zoom_in": [JOY_AXIS_RIGHT_Y, -1.0],
	"zoom_out": [JOY_AXIS_RIGHT_Y, 1.0],
	"crew_up": [JOY_AXIS_LEFT_Y, -1.0],
	"crew_down": [JOY_AXIS_LEFT_Y, 1.0],
	"crew_left": [JOY_AXIS_LEFT_X, -1.0],
	"crew_right": [JOY_AXIS_LEFT_X, 1.0],
	"crew_gun": [JOY_AXIS_TRIGGER_RIGHT, 1.0],
}
const PAD_BUTTONS := {
	"accelerate": [JOY_BUTTON_A],          # for pads without analog triggers
	"brake": [JOY_BUTTON_X],
	"camera_toggle": [JOY_BUTTON_Y],
	"restart_race": [JOY_BUTTON_BACK],
	"back_to_menu": [JOY_BUTTON_START],
	"zoom_in": [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_DPAD_UP],      # hold
	"zoom_out": [JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_DPAD_DOWN],  # hold
	"zoom_full": [JOY_BUTTON_RIGHT_STICK],
	"strategy_screen": [JOY_BUTTON_DPAD_RIGHT],  # pit wall (strategist screen); B closes
	"pit_box": [JOY_BUTTON_DPAD_LEFT],
	"pit_limiter": [JOY_BUTTON_LEFT_STICK],
	"pit_tyres": [JOY_BUTTON_B],  # B closes the pit wall when it's open
	"team_radio": [JOY_BUTTON_BACK],
	"crew_tab": [JOY_BUTTON_Y],
	"shift_up": [JOY_BUTTON_A],     # manual gearbox: A up, X down (pedals stay on the triggers)
	"shift_down": [JOY_BUTTON_X],
	"crew_gun": [JOY_BUTTON_A],
}
const STICK_DEADZONE := 0.12
const TRIGGER_DEADZONE := 0.05
## The controls Settings > Controller lets the player change, in order, with
## the name shown there.
const REBINDABLE := [
	["accelerate", "Throttle"], ["brake", "Brake"], ["steer_left", "Steer left"], ["steer_right", "Steer right"],
	["shift_up", "Shift up (manual gears)"], ["shift_down", "Shift down (manual gears)"],
	["zoom_in", "Zoom in"], ["zoom_out", "Zoom out"], ["zoom_full", "Whole track"], ["camera_toggle", "Camera"],
	["pit_box", "Box this lap"], ["pit_limiter", "Pit limiter"], ["pit_tyres", "Next tyres"], ["pit_fuel", "Next fuel"],
	["pit_wheels", "Which tyres to change"], ["pit_driver", "Driver change"],
	["strategy_screen", "Pit wall"], ["crew_tab", "Pit wall: switch tab"], ["team_radio", "Team radio"],
	["crew_gun", "Pit crew: wheel gun"], ["hud_tower", "Timing tower"], ["hud_edit", "Edit HUD layout"], ["restart_race", "Restart race"], ["back_to_menu", "Pause / menu"],
]
## Bindings shown (and changeable) per action: keyboard 1 and 2, controller 1 and 2.
const SLOTS := 2
const PAD_BUTTON_NAMES := {
	JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y", JOY_BUTTON_BACK: "Back / View",
	JOY_BUTTON_GUIDE: "Guide", JOY_BUTTON_START: "Start / Menu", JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB", JOY_BUTTON_DPAD_UP: "D-pad up",
	JOY_BUTTON_DPAD_DOWN: "D-pad down", JOY_BUTTON_DPAD_LEFT: "D-pad left", JOY_BUTTON_DPAD_RIGHT: "D-pad right",
	JOY_BUTTON_MISC1: "Share", JOY_BUTTON_TOUCHPAD: "Touchpad",
}
## Stick and trigger moves past this count when you pick a pad binding.
const LISTEN_AXIS := 0.6


## Builds every action: the defaults above, then the player's own bindings
## (overrides, see the top of this file). deadzone: the sticks' dead zone.
static func register_actions(overrides: Dictionary = {}, deadzone := STICK_DEADZONE) -> void:
	apply_bindings(overrides)
	set_deadzone(deadzone)


## Puts every action back to its defaults, then lays the player's bindings over them.
static func apply_bindings(overrides: Dictionary) -> void:
	for action in _all_actions():
		if not InputMap.has_action(action):
			InputMap.add_action(action, STICK_DEADZONE)
		InputMap.action_erase_events(action)
		var o: Dictionary = overrides.get(action, {}) if overrides.get(action) is Dictionary else {}
		for code in o.get("keys", KEYS.get(action, [])):
			InputMap.action_add_event(action, key_event(int(code)))
		for b in o.get("pad", default_pad(action)):
			var ev := pad_event(b)
			if ev:
				InputMap.action_add_event(action, ev)
	# Sticks and triggers listen to one controller only (the one in use).
	ActivePad.start()
	ActivePad.bind_axes()


## The stick dead zone for every action (0..1); the pedals keep a small one
## so a light squeeze of the trigger still counts.
static func set_deadzone(deadzone: float) -> void:
	for action in _all_actions():
		if InputMap.has_action(action):
			InputMap.action_set_deadzone(action, clampf(deadzone, 0.02, 0.6))
	InputMap.action_set_deadzone("accelerate", TRIGGER_DEADZONE)
	InputMap.action_set_deadzone("brake", TRIGGER_DEADZONE)


static func _all_actions() -> Array:
	var all: Array = KEYS.keys()
	for a in PAD_AXES.keys() + PAD_BUTTONS.keys():
		if not a in all:
			all.append(a)
	return all


## The default pad bindings of an action (stick / trigger first, then buttons).
static func default_pad(action: String) -> Array:
	var out := []
	if PAD_AXES.has(action):
		out.append({"axis": int(PAD_AXES[action][0]), "dir": float(PAD_AXES[action][1])})
	for b in PAD_BUTTONS.get(action, []):
		out.append({"button": int(b)})
	return out


## The keys (physical keycodes) and pad bindings an action has now, with the
## player's overrides.
static func keys_of(overrides: Dictionary, action: String) -> Array:
	var o = overrides.get(action, {})
	return (o["keys"] if o is Dictionary and o.has("keys") else KEYS.get(action, [])).duplicate()


static func pads_of(overrides: Dictionary, action: String) -> Array:
	var o = overrides.get(action, {})
	return (o["pad"] if o is Dictionary and o.has("pad") else default_pad(action)).duplicate(true)


## A copy of overrides with one binding changed. kind "keys" or "pad", slot
## 0 or 1, value a keycode / pad binding, or null to clear that slot. Only the
## shown slots are kept for that action, so a hidden default can't linger.
static func with_binding(overrides: Dictionary, action: String, kind: String, slot: int, value) -> Dictionary:
	var out := overrides.duplicate(true)
	var list: Array = keys_of(overrides, action) if kind == "keys" else pads_of(overrides, action)
	list = list.slice(0, SLOTS)
	while list.size() <= slot:
		list.append(null)
	list[slot] = value
	# The same binding twice on one action is pointless: keep the new one.
	for i in list.size():
		if i != slot and value != null and same_binding(list[i], value):
			list[i] = null
	list = list.filter(func(v): return v != null)
	var o: Dictionary = out.get(action, {}) if out.get(action) is Dictionary else {}
	o[kind] = list
	out[action] = o
	return out


static func same_binding(a, b) -> bool:
	if a == null or b == null:
		return false
	if a is Dictionary and b is Dictionary:
		if a.has("button") and b.has("button"):
			return int(a["button"]) == int(b["button"])
		if a.has("axis") and b.has("axis"):
			return int(a["axis"]) == int(b["axis"]) and signf(float(a["dir"])) == signf(float(b["dir"]))
		return false
	if a is Dictionary or b is Dictionary:
		return false
	return int(a) == int(b)


## The other rebindable actions that already use this binding (their names).
static func used_by(overrides: Dictionary, action: String, kind: String, value) -> Array:
	var out := []
	for r in REBINDABLE:
		if r[0] == action:
			continue
		var list: Array = keys_of(overrides, r[0]) if kind == "keys" else pads_of(overrides, r[0])
		if list.any(func(v): return same_binding(v, value)):
			out.append(r[1])
	return out


## What a key or pad input means as a binding: {"kind": "keys", "value": code}
## or {"kind": "pad", "value": {...}}, or {} if it isn't one (a key let go, a
## stick barely moved).
static func binding_from_event(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		var code: int = ev.physical_keycode if ev.physical_keycode != KEY_NONE else ev.keycode
		return {"kind": "keys", "value": code} if code != KEY_NONE else {}
	if ev is InputEventJoypadButton and ev.pressed:
		return {"kind": "pad", "value": {"button": int(ev.button_index)}}
	if ev is InputEventJoypadMotion and absf(ev.axis_value) >= LISTEN_AXIS:
		return {"kind": "pad", "value": {"axis": int(ev.axis), "dir": signf(ev.axis_value)}}
	return {}


static func key_event(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code as Key
	return ev


static func pad_event(b) -> InputEvent:
	if not b is Dictionary:
		return null
	if b.has("button"):
		var e := InputEventJoypadButton.new()
		e.device = -1  # any controller
		e.button_index = int(b["button"]) as JoyButton
		return e
	if b.has("axis"):
		var m := InputEventJoypadMotion.new()
		m.device = -1
		m.axis = int(b["axis"]) as JoyAxis
		m.axis_value = signf(float(b.get("dir", 1.0)))
		return m
	return null


## A binding's name for the screen: "W", "Left Shift", "RT", "Left stick left".
static func describe(kind: String, value) -> String:
	if value == null:
		return "-"
	if kind == "keys":
		return OS.get_keycode_string(int(value) as Key)   # named by its place on a US keyboard
	if value is Dictionary and value.has("button"):
		return PAD_BUTTON_NAMES.get(int(value["button"]), "Button %d" % int(value["button"]))
	if value is Dictionary and value.has("axis"):
		var neg: bool = float(value.get("dir", 1.0)) < 0.0
		match int(value["axis"]):
			JOY_AXIS_LEFT_X: return "Left stick left" if neg else "Left stick right"
			JOY_AXIS_LEFT_Y: return "Left stick up" if neg else "Left stick down"
			JOY_AXIS_RIGHT_X: return "Right stick left" if neg else "Right stick right"
			JOY_AXIS_RIGHT_Y: return "Right stick up" if neg else "Right stick down"
			JOY_AXIS_TRIGGER_LEFT: return "LT"
			JOY_AXIS_TRIGGER_RIGHT: return "RT"
		return "Axis %d %s" % [int(value["axis"]), "-" if neg else "+"]
	return "?"
