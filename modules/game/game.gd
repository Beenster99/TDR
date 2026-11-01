extends Node
## Autoload "Game" (game module): starts the game by wiring the modules
## together. It runs after GameData and before Net, and before the first scene.
##   - registers the input actions (input module)
##   - loads all content into GameData (cars, tracks, physics, ai modules)


func _ready() -> void:
	InputSetup.register_actions()
	reload_content()


func reload_content() -> void:
	GameData.cars = CarCatalog.load_all()
	GameData.tyres = TyreCatalog.load_all()
	GameData.tracks = TrackCatalog.list_all()
	GameData.drivers = DriverCatalog.load_all()
