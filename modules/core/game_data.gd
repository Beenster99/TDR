extends Node
## Autoload "GameData" (core module): the game's shared state, which any
## module may read. It knows nothing about other modules' types, so core
## stays at the bottom of the dependency tree:
##   - content: filled at startup by the game module (Game autoload)
##   - the race session handed from the menu to the race scene
##   - the parsed command line
##   - the paths of the two main scenes

const SCENE_MENU := "res://modules/ui/main_menu.tscn"
const SCENE_RACE := "res://modules/game/race.tscn"

var cars: Dictionary = {}               ## car id -> CarDefinition (cars module)
var tyres: Dictionary = {}              ## compound id -> TyreCompound (physics module)
var tracks: Array[Dictionary] = []      ## [{id, name, location, length_m}] (tracks module)
var drivers: Array = []                 ## AI drivers (ai module)

## Session the race scene should run (offline, server or client). A
## RaceSession from the multiplayer module; untyped so core doesn't depend on it.
var active_session = null
## This player's own choices, kept between races.
##   driving_help: 2 = full (traction control, ABS, stability), 1 = TC + ABS, 0 = off
##   zoom: camera zoom level the player last used (0 = close, 1 = whole track)
var prefs: Dictionary = {"driving_help": 2, "zoom": 0.15}
## Parsed command line (after "--"), e.g. --server --port 7777 --autodrive
var args: Dictionary = {}


func _ready() -> void:
	_parse_args()
	if args.has("time-scale"):
		Engine.time_scale = float(args["time-scale"])
		Engine.max_physics_steps_per_frame = 16


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
