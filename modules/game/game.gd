extends Node
## Autoload "Game" (game module): starts the game by wiring the modules
## together. It runs after GameData and before Net, and before the first scene.
##   - registers the input actions (input module) and tells it which
##     controller the player is using (ActivePad)
##   - loads all content into GameData (cars, tracks, physics, ai modules)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # keep following the input while a race is paused
	# The player's own bindings and stick dead zone (Settings > Controller).
	var controls = GameData.prefs.get("controls", {})
	InputSetup.register_actions(controls if controls is Dictionary else {}, float(GameData.prefs.get("pad_deadzone", 12)) / 100.0)
	reload_content()
	GameData.register_setting("gameplay", "podium", "Podium celebration", [[true, "On"], [false, "Off"]], true,
		"Finish in the top three and you go up on the podium before the results: lift the trophy, then shake the champagne, pop the cork and spray everyone. Off: straight to the results.")


## Follows which game controller the player is using, and whether they last
## touched a controller or the keyboard / mouse, for the prompts (input module).
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		ActivePad.observe(event)
	InputPrompt.observe(event)


func reload_content() -> void:
	GameData.cars = CarCatalog.load_all()
	GameData.tyres = TyreCatalog.load_all()
	GameData.tracks = TrackCatalog.list_all()
	GameData.drivers = DriverCatalog.load_all()
