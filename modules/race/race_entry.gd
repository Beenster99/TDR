class_name RaceEntry
extends RefCounted
## One competitor: who is driving what, plus race progress and timing.

var driver_name: String = ""
var is_ai: bool = false
## Players attached to this car, each with a role. Wave 1 uses one "driver"
## per car; co-op (wave 5) adds "pit_crew" / "strategist" members. Only the
## driver's inputs steer the car. [{ "peer_id": int, "name": String, "role": String }]
var crew: Array = []
var car_id: String = ""
var traits: Dictionary = {}      ## AI: the driver at the wheel now (changes with the line-up)
## AI cars that share the car between drivers (RaceSettings.drivers_per_car):
## [{name, traits}], the first is the starting driver (driver_name). The one
## at the wheel is pit["driver_idx"]; changes happen at pit stops (PitRules).
var lineup: Array = []
var setup: Dictionary = {}       ## CarDefinition overrides: upgrades, tuning ("tuning"), tyres, balance
## Paint scheme {pattern, primary, secondary, accent} ({} = the car's default).
var livery: Dictionary = {}

var started_lap: bool = false    ## crossed the line once (off the grid)
var laps_done: int = 0
var lap_start_time: float = 0.0
var lap_times: PackedFloat64Array = []
var best_lap: float = 0.0
var sector_times: PackedFloat64Array = []  ## current lap
var last_sector_times: PackedFloat64Array = []
var next_sector: int = 1
var sector_start_time: float = 0.0
var distance: float = 0.0        ## total race distance, for running order
var finished: bool = false
var finish_time: float = 0.0
var dnf: bool = false
var position: int = 0
## Time penalties (seconds) added to the race time in the classification.
var penalty_s: float = 0.0
## Pit lane and stops (see PitRules.new_state): phase, plan, stops, tyres...
var pit: Dictionary = {}


func to_dict() -> Dictionary:
	return {
		"started_lap": started_lap, "laps_done": laps_done, "lap_start_time": lap_start_time,
		"lap_times": lap_times.duplicate(), "best_lap": best_lap, "sector_times": sector_times.duplicate(),
		"last_sector_times": last_sector_times.duplicate(), "next_sector": next_sector,
		"sector_start_time": sector_start_time, "distance": distance,
		"finished": finished, "finish_time": finish_time, "dnf": dnf, "position": position,
		"penalty_s": penalty_s, "pit": pit.duplicate(true),
	}


func from_dict(d: Dictionary) -> void:
	for k in d:
		var v = d[k]
		if v is Dictionary:
			v = v.duplicate(true)
		elif v is PackedFloat64Array:
			v = v.duplicate()
		set(k, v)


func describe() -> Dictionary:
	var d := {"driver_name": driver_name, "is_ai": is_ai, "crew": crew,
		"car_id": car_id, "traits": traits, "setup": setup, "livery": livery}
	if not lineup.is_empty():
		d["lineup"] = lineup
	return d


static func from_description(d: Dictionary) -> RaceEntry:
	var e := RaceEntry.new()
	e.driver_name = d.get("driver_name", "")
	e.is_ai = d.get("is_ai", false)
	e.crew = d.get("crew", []).duplicate(true)
	e.car_id = d.get("car_id", "")
	e.traits = d.get("traits", {})
	e.setup = d.get("setup", {})
	e.livery = d.get("livery", {})
	e.lineup = d.get("lineup", []).duplicate(true)
	return e


const ROLE_DRIVER := "driver"
const ROLE_PIT_CREW := "pit_crew"
const ROLE_STRATEGIST := "strategist"
## Co-op with two players: one player is both pit crew and strategist.
const ROLE_PIT_WALL := "pit_wall"
## A solo player's AI co-driver is a crew member with this peer id (and
## "ai": true, "traits"). Swapping roles with it is a driver change: the AI
## takes the wheel at the next stop and the player runs the pit wall.
const AI_PEER := -2
## Every role, in the order the lobby offers them.
const ROLES := [ROLE_DRIVER, ROLE_PIT_CREW, ROLE_STRATEGIST, ROLE_PIT_WALL]


## Whether someone with this role does that duty: "pit_wall" covers both
## the pit crew and the strategist; every other role covers only itself.
static func role_covers(role: String, duty: String) -> bool:
	if role == duty:
		return true
	return role == ROLE_PIT_WALL and (duty == ROLE_PIT_CREW or duty == ROLE_STRATEGIST)


## The roles a crew of this many players shares out: 1 a driver; 2 a driver
## and a pit wall (pit crew + strategist); 3 a driver, a pit crew and a strategist.
static func roles_for_crew(size: int) -> Array:
	match size:
		0: return []
		1: return [ROLE_DRIVER]
		2: return [ROLE_DRIVER, ROLE_PIT_WALL]
		_: return [ROLE_DRIVER, ROLE_PIT_CREW, ROLE_STRATEGIST]


## Gives every member of a crew (array of dicts with "role") a different role
## that fits the crew's size, keeping the roles they already hold where it can.
## Members past three are left without a valid role (callers cap crews at 3).
static func share_roles(members: Array) -> void:
	var wanted := roles_for_crew(mini(members.size(), 3))
	var free := wanted.duplicate()
	var unset := []
	for m in members:
		var r: String = m.get("role", "")
		if r in free:
			free.erase(r)
		else:
			unset.append(m)
	for m in unset:
		m["role"] = free.pop_front() if not free.is_empty() else ""


## Role of a crew member (peer), "" if they're not in this car's crew.
func member_role(peer_id: int) -> String:
	for m in crew:
		if int(m.get("peer_id", 0)) == peer_id:
			return m.get("role", "")
	return ""


## Whether a crew member's peer id is an AI co-driver (not a machine).
static func is_ai_peer(peer_id: int) -> bool:
	return peer_id <= AI_PEER


## Crew members who are players (AI co-drivers left out).
func human_crew() -> Array:
	return crew.filter(func(m): return not is_ai_peer(int(m.get("peer_id", 0))))


## The crew member at the wheel ({} when nobody, e.g. an AI car).
func driver_member() -> Dictionary:
	for m in crew:
		if m.get("role", "") == ROLE_DRIVER:
			return m
	return {}


## Who is driving the car now: the line-up driver at the wheel (AI cars), the
## crew member at the wheel (players and AI co-drivers), else driver_name.
func at_wheel() -> String:
	if lineup.size() > 1:
		var k := int(pit.get("driver_idx", 0))
		if k >= 0 and k < lineup.size():
			return str(lineup[k].get("name", driver_name))
	var m := driver_member()
	if not m.is_empty() and crew.size() > 1:
		return str(m.get("name", driver_name))
	return driver_name


## Peer whose inputs drive this car (0 = local/offline player, -1 = nobody,
## AI_PEER = the AI co-driver).
func driver_peer() -> int:
	for m in crew:
		if m.get("role", "") == ROLE_DRIVER:
			return int(m.get("peer_id", 0))
	return -1


## True when a person is at the wheel (not the AI, not an AI co-driver).
func is_player_driving() -> bool:
	if is_ai:
		return false
	var d := driver_peer()
	return d >= 0 and not is_ai_peer(d)


func has_peer(peer_id: int) -> bool:
	for m in crew:
		if int(m.get("peer_id", 0)) == peer_id:
			return true
	return false
