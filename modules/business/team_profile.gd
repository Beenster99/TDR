class_name TeamProfile
extends RefCounted
## The player's own team, saved on this machine (user://profile.json): money,
## the upgrade levels bought for each car, and each car's livery. Upgrades
## stay with the car between races and seasons.
##
## Each player's profile lives on their own machine; for a race the lobby sends
## setup_for(car_id) (CarDefinition overrides) and livery_for(car_id).

const DEFAULT_PATH := "user://profile.json"
## Where load_or_new() looks when given no path (the menu sets it from
## the --profile command line option, so test bots can have their own teams).
static var default_path := DEFAULT_PATH
const VERSION := 1

var path := DEFAULT_PATH
var money: int = 0
## car id -> {"upgrades": {category: level}, "livery": {pattern, primary, secondary, accent}}
var cars: Dictionary = {}
## Last few money changes, newest last: [{"amount", "reason"}]
var ledger: Array = []


static func load_or_new(p_path := "") -> TeamProfile:
	if p_path == "":
		p_path = default_path
	var p := TeamProfile.new()
	p.path = p_path
	p.money = int(UpgradeCatalog.data().get("start_money", 150000))
	if FileAccess.file_exists(p_path):
		var d = JSON.parse_string(FileAccess.get_file_as_string(p_path))
		if d is Dictionary:
			p.from_dict(d)
	return p


func to_dict() -> Dictionary:
	return {"version": VERSION, "money": money, "cars": cars.duplicate(true), "ledger": ledger.duplicate(true)}


func from_dict(d: Dictionary) -> void:
	money = int(d.get("money", money))
	cars = d.get("cars", {}).duplicate(true) if d.get("cars") is Dictionary else {}
	ledger = d.get("ledger", []).duplicate(true) if d.get("ledger") is Array else []
	# JSON numbers come back as floats.
	for id in cars:
		var ups: Dictionary = cars[id].get("upgrades", {})
		for k in ups:
			ups[k] = int(ups[k])


func save() -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), " "))
	return OK


func earn(amount: int, reason: String) -> void:
	money += amount
	_log(amount, reason)


## Takes money if there is enough. Returns false (and changes nothing) if not.
func spend(amount: int, reason: String) -> bool:
	if amount > money:
		return false
	money -= amount
	_log(-amount, reason)
	return true


func _log(amount: int, reason: String) -> void:
	ledger.append({"amount": amount, "reason": reason})
	while ledger.size() > 30:
		ledger.pop_front()


func _car(car_id: String) -> Dictionary:
	if not cars.has(car_id):
		cars[car_id] = {"upgrades": {}, "livery": {}}
	return cars[car_id]


func levels(car_id: String) -> Dictionary:
	return cars.get(car_id, {}).get("upgrades", {}).duplicate()


func level(car_id: String, cat_id: String) -> int:
	return int(cars.get(car_id, {}).get("upgrades", {}).get(cat_id, 0))


## Money needed to move one category to `to` (negative = refund).
func cost_to(def: CarDefinition, cat_id: String, to: int) -> int:
	return UpgradeCatalog.cost_of_change(def, cat_id, level(def.id, cat_id), to)


## Buys (or sells back, for a partial refund) upgrade levels until the
## category is at `to`. Returns false if there isn't enough money.
func set_level(def: CarDefinition, cat_id: String, to: int) -> bool:
	to = clampi(to, 0, UpgradeCatalog.max_level(cat_id))
	var from := level(def.id, cat_id)
	if to == from:
		return true
	var cost := UpgradeCatalog.cost_of_change(def, cat_id, from, to)
	var what := "%s %s: %s" % [def.display_name, UpgradeCatalog.category(cat_id).get("name", cat_id),
		UpgradeCatalog.level_info(cat_id, to).get("name", "")]
	if cost > 0:
		if not spend(cost, what):
			return false
	elif cost < 0:
		earn(-cost, "Sold " + what)
	var ups: Dictionary = _car(def.id)["upgrades"]
	if to == 0:
		ups.erase(cat_id)
	else:
		ups[cat_id] = to
	return true


## The car's livery ({} = its default livery).
func livery_for(car_id: String) -> Dictionary:
	return cars.get(car_id, {}).get("livery", {}).duplicate()


func set_livery(car_id: String, livery: Dictionary) -> void:
	_car(car_id)["livery"] = livery.duplicate()


## Overrides to race this car with its upgrades (for RaceEntry.setup).
func setup_for(def: CarDefinition) -> Dictionary:
	return UpgradeCatalog.overrides_for(def, levels(def.id))


## What a race needs from the profile for one car: {"setup", "livery"}.
func race_entry_for(def: CarDefinition) -> Dictionary:
	return {"setup": setup_for(def), "livery": livery_for(def.id)}
