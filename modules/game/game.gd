extends Node
## Autoload "Game" (game module): starts the game by wiring the modules
## together. It runs after GameData and before Net, and before the first scene.
##   - registers the input actions (input module) and tells it which
##     controller the player is using (ActivePad)
##   - loads all content into GameData (cars, tracks, physics, ai modules)


func _ready() -> void:
	# The player's own bindings and stick dead zone (Settings > Controller).
	var controls = GameData.prefs.get("controls", {})
	InputSetup.register_actions(controls if controls is Dictionary else {}, float(GameData.prefs.get("pad_deadzone", 12)) / 100.0)
	reload_content()


## Follows which game controller the player is using (input module).
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		ActivePad.observe(event)


func reload_content() -> void:
	GameData.cars = CarCatalog.load_all()
	GameData.tyres = TyreCatalog.load_all()
	GameData.tracks = TrackCatalog.list_all()
	GameData.drivers = DriverCatalog.load_all()
