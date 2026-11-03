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
## Co-op (wave 5): this player's role changed (e.g. a driver change at a pit
## stop). local_car, team_car and local_role already hold the new values.
signal role_changed(role: String)
## A car's crew changed: roles swapped, someone left, or a driver change was
## asked for or done (see pending_swap).
signal crew_changed(car: int)
## Team radio / pings for a car's crew (see send_team_radio).
signal team_radio(car: int, msg: Dictionary)
## Co-op pit stops: a team mate's crew member (from their machine): {job, x,
## y, f, pose, carry, props} (see send_crew_pose).
signal crew_pose(car: int, peer: int, pose: Dictionary)

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
var local_car: int = -1               ## car this player drives (-1 = spectator / dedicated / not driving)
## Co-op: the car whose crew this player is in, driving or not (-1 = none).
var team_car: int = -1
## Co-op: this player's role in team_car's crew (RaceEntry.ROLE_*, "" = none).
var local_role: String = ""
var owners: PackedInt32Array = []     ## car index -> peer that simulates it
var inputs: Array[CarInput] = []
var timelines: Dictionary = {}        ## car index -> NetTimeline (remote cars)
var net = null                        ## Net autoload (null offline)
var _finished_emitted := false
var _pit_sent: Dictionary = {}        ## car -> pit state signature last sent to the host
var _last_race_tick := -1
var _pending: Dictionary = {}         ## car -> {a, b}: a driver change waiting for the pit box


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
		if not e.is_ai and owner < 0:
			# A crew with nobody at the wheel (e.g. --role strategist): the AI drives.
			owner = HOST_PEER
			if p_mode != Mode.CLIENT:
				s.ai[i] = AIDriver.for_car(s.sim, i)
				s.ai[i].pit_strategy.telemetry = s.telemetry
		if p_mode == Mode.OFFLINE:
			owner = p_local_peer
		s.owners.append(owner)
	s._apply_ownership()
	s._refresh_local_roles(false)
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


## The race clock shared by every machine: the host's clock (this machine's
## clock plus Net.clock_offset). Car states are stamped with it.
func net_clock() -> float:
	return clock() + (net.clock_offset if net else 0.0)


## True when net_clock() is the host's clock (the host itself, or a client
## that has synced), so remote cars can be placed in the present.
func clock_synced() -> bool:
	return net == null or mode != Mode.CLIENT or net.clock_synced


## Called once per physics tick by the race scene with this player's input.
func tick(local_input: CarInput) -> void:
	var now := net_clock()
	var synced := clock_synced()
	for i in timelines:
		timelines[i].apply(sim.cars[i], now, synced)
	if local_car >= 0 and local_input != null:
		inputs[local_car] = local_input.quantized()
	for i in ai:
		if owns(i):
			inputs[i] = ai[i].get_input(sim, i)
	_do_handovers()
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
	var now := net_clock()
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
		_pending.erase(i)
		var co_driver := {}
		for m in e.crew:
			if RaceEntry.is_ai_peer(int(m.get("peer_id", 0))):
				co_driver = m
		if e.human_crew().is_empty():
			# Only an AI co-driver (or nobody) left: the host's AI drives on.
			e.crew = [co_driver] if not co_driver.is_empty() else []
			if not co_driver.is_empty():
				co_driver["role"] = RaceEntry.ROLE_DRIVER
			if not ai.has(i):
				owners[i] = local_peer
				ai[i] = AIDriver.for_car(sim, i)
				ai[i].pit_strategy.telemetry = telemetry
				if co_driver.is_empty():
					e.driver_name += " (AI)"
		elif was_driver and not e.crew.is_empty():
			# The next crew member takes the wheel where the car is.
			for m in e.crew:
				m["role"] = ""
			e.crew[0]["role"] = RaceEntry.ROLE_DRIVER
			owners[i] = int(e.crew[0]["peer_id"])
		RaceEntry.share_roles(e.crew)
		_share_crew(i, {})
	_apply_ownership()


# --- Co-op: roles, driver changes and team radio ---------------------------------

## Works out local_car, team_car and local_role from the crews.
func _refresh_local_roles(notify := true) -> void:
	var old_role := local_role
	var old_car := local_car
	var old_team := team_car
	local_car = -1
	team_car = -1
	local_role = ""
	for i in sim.car_count():
		var e := sim.entries[i]
		if e.is_ai or not e.has_peer(local_peer):
			continue
		team_car = i
		local_role = e.member_role(local_peer)
		if local_role == RaceEntry.ROLE_DRIVER and owners[i] == local_peer:
			local_car = i
		break
	if notify and (old_role != local_role or old_car != local_car or old_team != team_car):
		role_changed.emit(local_role)


## The crew of a car: [{peer_id, name, role}].
func crew_of(car: int) -> Array:
	return sim.entries[car].crew if car >= 0 and car < sim.car_count() else []


## A driver change asked for and waiting for the car to stop in its box:
## {"a": peer, "b": peer}, or {} when none is waiting.
func pending_swap(car: int) -> Dictionary:
	return _pending.get(car, {})


## Swap the roles of two members (peers) of a car's crew. Any crew member may
## ask. Swaps between the pit crew and strategist happen at once. A swap that
## involves the driver is a driver change: it waits until the car is stopped
## in its pit box (the stop lasts at least PitRules.DRIVER_CHANGE_S), or
## happens at once on the grid before the start. The car, with its fuel, tyres
## and damage, then moves to the new driver's machine.
func request_role_swap(car: int, peer_a: int, peer_b: int) -> void:
	if car < 0 or car >= sim.car_count():
		return
	if is_authority():
		on_role_swap_request(local_peer, car, peer_a, peer_b)
	elif net:
		net.send_role_swap(car, peer_a, peer_b)


## Take back a driver change that is still waiting for the pit box.
func cancel_role_swap(car: int) -> void:
	request_role_swap(car, 0, 0)


## Host: a crew member asks for a role swap (a == b == 0 cancels a waiting one).
func on_role_swap_request(sender: int, car: int, a: int, b: int) -> void:
	if not is_authority() or car < 0 or car >= sim.car_count():
		return
	var e := sim.entries[car]
	if not e.has_peer(sender):
		return
	if a == 0 and b == 0:
		if _pending.erase(car):
			_share_crew(car, {})
		return
	if a == b or not e.has_peer(a) or not e.has_peer(b) or sim.phase == RaceSim.Phase.FINISHED:
		return
	var ra := e.member_role(a)
	var rb := e.member_role(b)
	if ra != RaceEntry.ROLE_DRIVER and rb != RaceEntry.ROLE_DRIVER:
		_swap_roles(e, a, b)
		_share_crew(car, {})
		return
	_pending[car] = {"a": a, "b": b}
	_share_crew(car, {})


func _swap_roles(e: RaceEntry, a: int, b: int) -> void:
	var ra := e.member_role(a)
	var rb := e.member_role(b)
	for m in e.crew:
		var pid := int(m.get("peer_id", 0))
		if pid == a:
			m["role"] = rb
		elif pid == b:
			m["role"] = ra


## The machine that simulates a car with a driver change waiting does the
## change as soon as the car is in its box (or still on the grid).
func _do_handovers() -> void:
	for car in _pending.keys():
		if not owns(car):
			continue
		var phase: String = sim.entries[car].pit.get("phase", "")
		if sim.phase != RaceSim.Phase.COUNTDOWN and phase != PitRules.PHASE_SERVICE:
			continue
		var d: Dictionary = _pending[car]
		_pending.erase(car)
		sim.pits.add_driver_change(car)
		var state := {"car": sim.cars[car].serialize(), "pits": sim.pits.car_handover(car)}
		if is_authority():
			on_handover(local_peer, car, int(d["a"]), int(d["b"]), state)
		elif net:
			# Stop simulating it here; the new driver's machine carries on.
			var e := sim.entries[car]
			var next_driver := int(d["b"]) if e.member_role(int(d["a"])) == RaceEntry.ROLE_DRIVER else int(d["a"])
			owners[car] = HOST_PEER if RaceEntry.is_ai_peer(next_driver) else next_driver
			_apply_ownership()
			net.send_handover(car, int(d["a"]), int(d["b"]), state)


## Host: the machine that simulated a car hands it over for a driver change.
func on_handover(sender: int, car: int, a: int, b: int, state: Dictionary) -> void:
	if not is_authority() or car < 0 or car >= sim.car_count() or owners[car] != sender:
		return
	var e := sim.entries[car]
	if e.has_peer(a) and e.has_peer(b):
		_swap_roles(e, a, b)
	_pending.erase(car)
	var driver := e.driver_peer()
	if RaceEntry.is_ai_peer(driver):
		# The player's AI co-driver takes the wheel: this machine (the host)
		# runs the car from the state handed over.
		owners[car] = local_peer
		if state.has("car"):
			sim.cars[car].deserialize(PackedFloat64Array(state["car"]))
		ai[car] = AIDriver.for_car(sim, car)
		ai[car].pit_strategy.telemetry = telemetry
	elif driver > 0 or mode == Mode.OFFLINE:
		owners[car] = driver if mode != Mode.OFFLINE else local_peer
	if DisplayServer.get_name() == "headless":
		print("[coop] driver change: car %d now driven by %s" % [car, _member_name(e, driver)])
	_share_crew(car, state)


func _member_name(e: RaceEntry, peer_id: int) -> String:
	for m in e.crew:
		if int(m.get("peer_id", 0)) == peer_id:
			return str(m.get("name", "?"))
	return "nobody"


## Host: tell everyone (and this machine) a car's crew, owner and waiting swap.
func _share_crew(car: int, state: Dictionary) -> void:
	var crew: Array = sim.entries[car].crew.duplicate(true)
	var pending: Dictionary = _pending.get(car, {})
	if net:
		net.broadcast_crew(car, crew, owners[car], pending, state)
	apply_crew(car, crew, owners[car], pending, state)


## A car's crew from the host (also used by the host itself): roles, the
## machine that simulates it, a waiting driver change, and after a driver
## change the car's full state so the new driver carries on exactly.
func apply_crew(car: int, crew: Array, owner: int, pending: Dictionary, state: Dictionary) -> void:
	if car < 0 or car >= sim.car_count():
		return
	var e := sim.entries[car]
	if not is_authority():
		e.crew = crew.duplicate(true)
		owners[car] = owner
	if pending.is_empty():
		_pending.erase(car)
	else:
		_pending[car] = pending.duplicate()
	if not state.is_empty():
		sim.cars[car].deserialize(PackedFloat64Array(state["car"]))
		sim.pits.apply_handover(car, state.get("pits", {}))
		_pit_sent.erase(car)
		if timelines.has(car):
			var fresh := NetTimeline.new()
			fresh.received = timelines[car].received
			timelines[car] = fresh
	var driver := e.driver_peer()
	if ai.has(car) and not e.is_ai and driver >= 0 and not RaceEntry.is_ai_peer(driver) \
			and (driver > 0 or mode == Mode.OFFLINE):
		ai.erase(car)  # a player has the wheel again
	_apply_ownership()
	_refresh_local_roles()
	crew_changed.emit(car)


## Team radio and pings to a car's crew: msg = {kind: "ping"|"radio", code,
## text, ...}; "from" (name) and "role" are filled in for the sender. Every
## crew member's machine (this one too) gets team_radio(car, msg).
func send_team_radio(car: int, msg: Dictionary) -> void:
	if car < 0 or car >= sim.car_count():
		return
	var m := msg.duplicate(true)
	if not m.has("from"):
		m["from"] = _member_name(sim.entries[car], local_peer) if sim.entries[car].has_peer(local_peer) \
			else (net.local_name if net else "You")
	if not m.has("role"):
		m["role"] = local_role
	m["peer"] = local_peer
	if is_authority():
		on_team_radio(local_peer, car, m)
	elif net:
		net.send_team_radio(HOST_PEER, car, m)


## Host: passes a crew's radio to every member of that crew. Clients: shows it.
func on_team_radio(sender: int, car: int, msg: Dictionary) -> void:
	if car < 0 or car >= sim.car_count():
		return
	var e := sim.entries[car]
	if is_authority():
		if not e.has_peer(sender):
			return
		msg["peer"] = sender
		for m in e.crew:
			var pid := int(m.get("peer_id", 0))
			if pid != local_peer and net and not RaceEntry.is_ai_peer(pid):
				net.send_team_radio(pid, car, msg)
		if e.has_peer(local_peer):
			team_radio.emit(car, msg)
	elif e.has_peer(local_peer):
		team_radio.emit(car, msg)


## Co-op pit stops (ui PitCrewGame): tells the rest of car's crew where this
## player's crew member is. Through the host, to every other player in the crew.
func send_crew_pose(car: int, pose: Dictionary) -> void:
	if car < 0 or car >= sim.car_count() or net == null or mode == Mode.OFFLINE:
		return
	var p := pose.duplicate()
	p["peer"] = local_peer
	if is_authority():
		on_crew_pose(local_peer, car, p)
	else:
		net.send_crew_pose(HOST_PEER, car, p)


## Host: passes a crew member's pose to the rest of their crew. Clients: shows it.
func on_crew_pose(sender: int, car: int, pose: Dictionary) -> void:
	if car < 0 or car >= sim.car_count():
		return
	var e := sim.entries[car]
	if is_authority():
		if not e.has_peer(sender):
			return
		pose["peer"] = sender
		for m in e.crew:
			var pid := int(m.get("peer_id", 0))
			if pid != sender and pid != local_peer and net and not RaceEntry.is_ai_peer(pid):
				net.send_crew_pose(pid, car, pose)
		if sender != local_peer and e.has_peer(local_peer):
			crew_pose.emit(car, sender, pose)
	elif e.has_peer(local_peer) and int(pose.get("peer", -1)) != local_peer:
		crew_pose.emit(car, int(pose.get("peer", sender)), pose)
