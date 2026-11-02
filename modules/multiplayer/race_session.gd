class_name RaceSession
extends RefCounted
## Runs one race in one of three modes, with a single code path:
##   OFFLINE - every car simulated here (single player + AI).
##   SERVER  - the host: simulates its own car and all AI cars, and decides
##             the race (countdown, laps, positions, finish) for everyone.
##   CLIENT  - simulates only its own car; follows the host for race state.
##
## Multiplayer works the way Torque Shed's co-op does: each player simulates
## their own car and streams its state (no input lag, whatever the ping), and
## the server relays it to everyone. Other players' cars are drawn from a
## NetTimeline a little in the past, blended between their states. The host
## owns the AI cars and the race rules, and streams those the same way.
##
## A dedicated server is SERVER mode with no car of its own.

signal events_emitted(events: Array)
signal race_finished

enum Mode { OFFLINE, SERVER, CLIENT }

const SEND_EVERY := 2         ## car states: 30 Hz
const RACE_STATE_EVERY := 6   ## timing/positions: 10 Hz
const TELEMETRY_EVERY := 5    ## gaps / pit analysis ride on every 5th race state: 2 Hz
const HOST_PEER := 1

var mode: int = Mode.OFFLINE
var sim: RaceSim
## Race data for the pit wall (timing, gaps, pit windows, weather, feed).
var telemetry: RaceTelemetry
var ai: Dictionary = {}               ## car index -> AIDriver (cars this machine runs for the AI)
var start_data: Dictionary = {}
var local_peer: int = 0
var local_car: int = -1               ## car this player drives (-1 = spectator / dedicated)
var owners: PackedInt32Array = []     ## car index -> peer that simulates it
var inputs: Array[CarInput] = []
var timelines: Dictionary = {}        ## car index -> NetTimeline (remote cars)
var net = null                        ## Net autoload (null offline)
var _finished_emitted := false
var _pit_sent: Dictionary = {}        ## car -> pit state signature last sent to the host
var _last_race_tick := -1


static func create(p_mode: int, p_start_data: Dictionary, p_local_peer: int, p_net = null) -> RaceSession:
	var s := RaceSession.new()
	s.mode = p_mode
	s.start_data = p_start_data
	s.local_peer = p_local_peer
	s.net = p_net
	s.sim = RaceFactory.build_sim(p_start_data, GameData.cars, GameData.tyres)
	if p_mode != Mode.CLIENT:
		s.ai = AIDriver.for_all_ai(s.sim)
	s.sim.follower = p_mode == Mode.CLIENT
	s.telemetry = RaceTelemetry.create(s.sim, p_mode != Mode.CLIENT)
	for i in s.ai:
		s.ai[i].pit_strategy.telemetry = s.telemetry
	for i in s.sim.car_count():
		s.inputs.append(CarInput.neutral())
		var e := s.sim.entries[i]
		var owner := HOST_PEER if e.is_ai else e.driver_peer()
		if p_mode == Mode.OFFLINE:
			owner = p_local_peer
		s.owners.append(owner)
		if not e.is_ai and e.driver_peer() == p_local_peer:
			s.local_car = i
	s._apply_ownership()
	return s


func is_authority() -> bool:
	return mode != Mode.CLIENT


func owns(car: int) -> bool:
	return owners[car] == local_peer


func _apply_ownership() -> void:
	for i in sim.car_count():
		var mine := owns(i)
		sim.external[i] = 0 if mine else 1
		if mine:
			timelines.erase(i)
		elif not timelines.has(i):
			timelines[i] = NetTimeline.new()


static func clock() -> float:
	return float(Engine.get_physics_frames()) / Engine.physics_ticks_per_second


## Called once per physics tick by the race scene with this player's input.
func tick(local_input: CarInput) -> void:
	var now := clock()
	for i in timelines:
		timelines[i].apply(sim.cars[i], now)
	if local_car >= 0 and local_input != null:
		inputs[local_car] = local_input.quantized()
	for i in ai:
		if owns(i):
			inputs[i] = ai[i].get_input(sim, i)
	sim.step(inputs)
	var feed_events := telemetry.observe(sim)
	if mode == Mode.OFFLINE or mode == Mode.SERVER:
		telemetry.on_events(sim.events)
		if not sim.events.is_empty() or not feed_events.is_empty():
			var evs := sim.events.duplicate(true)
			evs.append_array(feed_events)
			events_emitted.emit(evs)
			if net:
				net.broadcast_events(evs)
		if net and sim.tick % RACE_STATE_EVERY == 0:
			net.broadcast_race_state(var_to_bytes(_race_state()))
	if net and sim.tick % SEND_EVERY == 0:
		_send_my_cars(now)
	if net and mode == Mode.CLIENT:
		_send_my_pit_states()
	_check_finished()


func _send_my_cars(now: float) -> void:
	var data := PackedFloat32Array()
	for i in sim.car_count():
		if owns(i):
			data.append(i)
			sim.cars[i].pack_net(data)
	if not data.is_empty():
		net.send_car_states(now, data)


## Client: tell the host about pit state changes of the cars simulated here.
func _send_my_pit_states() -> void:
	for i in sim.car_count():
		if not owns(i):
			continue
		var sig := PitRules.signature(sim.entries[i].pit)
		if _pit_sent.get(i, "") != sig:
			_pit_sent[i] = sig
			net.send_pit_state(i, sim.entries[i].pit)


# --- Pit wall: anyone in a car's crew can call it in or change the plan ----------

## Change car's pit plan: {box, tyre, fuel, repair} (see PitRules.set_plan) or
## {limiter: bool}. Works from any machine whose player is in the car's crew
## (the driver, or a co-op pit crew / strategist): it reaches the machine that
## simulates the car through the host.
func request_pit(car: int, changes: Dictionary) -> void:
	if car < 0 or car >= sim.car_count():
		return
	if owns(car):
		_apply_pit_request(car, changes)
	elif net:
		net.send_pit_request(owners[car] if is_authority() else HOST_PEER, car, changes)


func _apply_pit_request(car: int, changes: Dictionary) -> void:
	if changes.has("limiter"):
		sim.pits.set_limiter(car, bool(changes["limiter"]))
	sim.pits.set_plan(car, changes)


func on_pit_request(sender: int, car: int, changes: Dictionary) -> void:
	if car < 0 or car >= sim.car_count():
		return
	if is_authority():
		# Only the car's own crew (or its owner) may call its stops.
		if sender != owners[car] and not sim.entries[car].has_peer(sender):
			return
		if owns(car):
			_apply_pit_request(car, changes)
		elif net:
			net.send_pit_request(owners[car], car, changes)
	elif sender == HOST_PEER and owns(car):
		_apply_pit_request(car, changes)


## Host: a car's owner reports its pit state.
func on_pit_state(sender: int, car: int, state: Dictionary) -> void:
	if not is_authority() or car < 0 or car >= sim.car_count() or owners[car] != sender:
		return
	sim.pits.apply_remote(car, state)


func _check_finished() -> void:
	if sim.phase == RaceSim.Phase.FINISHED and not _finished_emitted:
		_finished_emitted = true
		race_finished.emit()


func _race_state() -> Dictionary:
	var st := sim.race_state()
	st["owners"] = owners
	if (sim.tick / RACE_STATE_EVERY) % TELEMETRY_EVERY == 0:
		st["telemetry"] = telemetry.to_net()
	return st


# --- Received from the network ---------------------------------------------

## Car states from the peer that simulates them. Only a car's owner may move it.
func on_car_states(sender: int, sent: float, data: PackedFloat32Array) -> void:
	var stride := 1 + CarState.NET_SIZE
	var now := clock()
	var o := 0
	while o + stride <= data.size():
		var i := int(data[o])
		if i >= 0 and i < owners.size() and owners[i] == sender and timelines.has(i):
			timelines[i].add(sent, now, data.slice(o + 1, o + stride))
		o += stride


## Host's race state: phase, timing, positions, and who simulates which car.
func on_race_state(bytes: PackedByteArray) -> void:
	if mode != Mode.CLIENT:
		return
	var st = bytes_to_var(bytes)
	if not (st is Dictionary) or int(st.get("tick", -1)) <= _last_race_tick:
		return
	_last_race_tick = int(st["tick"])
	var was_countdown := sim.phase == RaceSim.Phase.COUNTDOWN
	sim.apply_race_state(st)
	if st.has("telemetry"):
		telemetry.apply_net(st["telemetry"])
	if st.has("owners") and PackedInt32Array(st["owners"]) != owners:
		owners = PackedInt32Array(st["owners"])
		_apply_ownership()
	if was_countdown and sim.phase != RaceSim.Phase.COUNTDOWN:
		events_emitted.emit([{"type": "green"}])
	_check_finished()


func on_remote_events(evs: Array) -> void:
	if mode == Mode.CLIENT:
		telemetry.on_events(evs)
		events_emitted.emit(evs)


## Host: a player left mid-race. Another crew member takes the wheel, or the
## host's AI takes the car over from where it was.
func on_peer_left(peer_id: int) -> void:
	if not is_authority():
		return
	for i in sim.car_count():
		var e := sim.entries[i]
		if not e.has_peer(peer_id):
			continue
		var was_driver := e.driver_peer() == peer_id
		e.crew = e.crew.filter(func(m): return int(m.get("peer_id", 0)) != peer_id)
		if not was_driver:
			continue
		if not e.crew.is_empty():
			e.crew[0]["role"] = RaceEntry.ROLE_DRIVER
			owners[i] = int(e.crew[0]["peer_id"])
		else:
			owners[i] = local_peer
			ai[i] = AIDriver.for_car(sim, i)
			ai[i].pit_strategy.telemetry = telemetry
			e.driver_name += " (AI)"
	_apply_ownership()
