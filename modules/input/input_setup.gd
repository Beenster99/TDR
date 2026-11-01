class_name InputSetup
extends RefCounted
## Registers every input action in code (keyboard + gamepad), so the project
## file stays readable and a rebinding screen can reuse these tables later.
## Called once at startup by the game module.

const KEYS := {
	"accelerate": [KEY_W, KEY_UP],
	"brake": [KEY_S, KEY_DOWN],
	"steer_left": [KEY_A, KEY_LEFT],
	"steer_right": [KEY_D, KEY_RIGHT],
	"camera_toggle": [KEY_C],
	"restart_race": [KEY_R],
	"back_to_menu": [KEY_ESCAPE],
}
## Gamepad: analog triggers + left stick. Buttons use the Xbox layout names
## (Godot maps PlayStation/Nintendo pads to the same positions).
const PAD_AXES := {
	"accelerate": [JOY_AXIS_TRIGGER_RIGHT, 1.0],
	"brake": [JOY_AXIS_TRIGGER_LEFT, 1.0],
	"steer_left": [JOY_AXIS_LEFT_X, -1.0],
	"steer_right": [JOY_AXIS_LEFT_X, 1.0],
}
const PAD_BUTTONS := {
	"accelerate": [JOY_BUTTON_A],          # for pads without analog triggers
	"brake": [JOY_BUTTON_X],
	"camera_toggle": [JOY_BUTTON_Y],
	"restart_race": [JOY_BUTTON_BACK],
	"back_to_menu": [JOY_BUTTON_START],
}
const STICK_DEADZONE := 0.12
const TRIGGER_DEADZONE := 0.05


static func register_actions() -> void:
	for action in KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, STICK_DEADZONE)
		for key in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
	for action in PAD_AXES:
		var m := InputEventJoypadMotion.new()
		m.device = -1  # any controller
		m.axis = PAD_AXES[action][0]
		m.axis_value = PAD_AXES[action][1]
		InputMap.action_add_event(action, m)
	for action in PAD_BUTTONS:
		for b in PAD_BUTTONS[action]:
			var e := InputEventJoypadButton.new()
			e.device = -1
			e.button_index = b
			InputMap.action_add_event(action, e)
	InputMap.action_set_deadzone("accelerate", TRIGGER_DEADZONE)
	InputMap.action_set_deadzone("brake", TRIGGER_DEADZONE)
