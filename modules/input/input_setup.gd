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
	"zoom_in": [KEY_E, KEY_EQUAL, KEY_KP_ADD, KEY_PAGEUP],
	"zoom_out": [KEY_Q, KEY_MINUS, KEY_KP_SUBTRACT, KEY_PAGEDOWN],
	"zoom_full": [KEY_Z, KEY_TAB],
	"strategy_screen": [KEY_P],
	"pit_box": [KEY_B],
	"pit_limiter": [KEY_L],
	"pit_tyres": [KEY_T],
	"pit_fuel": [KEY_F],
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
		if not InputMap.has_action(action):
			InputMap.add_action(action, STICK_DEADZONE)
		var m := InputEventJoypadMotion.new()
		m.device = -1  # any controller
		m.axis = PAD_AXES[action][0]
		m.axis_value = PAD_AXES[action][1]
		InputMap.action_add_event(action, m)
	for action in PAD_BUTTONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, STICK_DEADZONE)
		for b in PAD_BUTTONS[action]:
			var e := InputEventJoypadButton.new()
			e.device = -1
			e.button_index = b
			InputMap.action_add_event(action, e)
	InputMap.action_set_deadzone("accelerate", TRIGGER_DEADZONE)
	InputMap.action_set_deadzone("brake", TRIGGER_DEADZONE)
