extends Node
## Autoload "GameData": cached game data + the settings handed from the menu
## to the race scene. Also registers input actions (kept in code so the
## project file stays readable and rebinding UI can reuse it later).

var cars: Dictionary = {}
var tyres: Dictionary = {}
var tracks: Array[Dictionary] = []
var drivers: Array = []

## Session the race scene should run (offline, server or client).
var active_session: RaceSession = null
## Parsed command line (after "--"), e.g. --server --port 7777 --autodrive
var args: Dictionary = {}

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


func _ready() -> void:
	reload()
	_register_actions()
	_parse_args()
	if args.has("time-scale"):
		Engine.time_scale = float(args["time-scale"])
		Engine.max_physics_steps_per_frame = 16


func reload() -> void:
	cars = DataLoader.load_cars()
	tyres = DataLoader.load_tyres()
	tracks = DataLoader.list_tracks()
	drivers = DataLoader.load_drivers()


func _register_actions() -> void:
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


func _parse_args() -> void:
	var list := OS.get_cmdline_user_args()
	var i := 0
	while i < list.size():
		var a: String = list[i]
		if a.begins_with("--"):
			var key := a.substr(2)
			if "=" in key:
				var kv := key.split("=", true, 1)
				args[kv[0]] = kv[1]
			elif i + 1 < list.size() and not list[i + 1].begins_with("--"):
				args[key] = list[i + 1]
				i += 1
			else:
				args[key] = true
		i += 1


func arg(name: String, default = null):
	return args.get(name, default)
