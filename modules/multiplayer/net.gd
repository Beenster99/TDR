extends Node
## Autoload "Net": lobby + transport, set up the same way as Torque Shed's
## co-op: ENet, one player hosts (and plays), friends join by IP, packets are
## ZSTD-compressed, the host's router port is opened with UPnP, and each
## player simulates their own car and streams its state, relayed by the host
## to everyone. The host also runs the AI cars and the race rules.
## Every RPC lives on this node (/root/Net) so node paths match on all peers.
##
## Peer 1 is always the host. A dedicated server (--server) is peer 1 with no car.

signal lobby_changed
signal connection_failed(reason: String)
signal disconnected(reason: String)
signal race_started(start_data: Dictionary)
signal returned_to_lobby
signal internet_status_changed

## UDP port (Torque Shed uses 24680; this game has its own so both can run).
const DEFAULT_PORT := 24690
const MAX_PEERS := 16
## Bump whenever a message changes shape; mismatched games are told at the lobby.
const PROTOCOL_VERSION := 17  # 17: race type (discipline), joker laps and jokers taken, joker state in car states, 16: pit crew mini-game (pit plan "crew": players as wheel gunners), 15: per-wheel tyre compounds and pressures in pit plans and pit state, strategist pit plans read out on the radio, 14: car states stamped with the host's clock (synced by pings) so remote cars are placed in the present, 13: tyre choice per wheel, driver line-ups and AI co-drivers, 12: co-op crews (teams and roles in the lobby, role swaps, driver changes, team radio), 4: track elevation, 5: damage in car states, 6: barrier types and run-off surfaces, 7: race control in the race state, 8: pit stops, 9: car upgrades, liveries and upgrades_mode, 10: car setups (tuning), 11: seasons (season_info in the lobby)
const COMPRESSION := ENetConnection.COMPRESS_ZSTD
## How long a player's game may go silent before they're taken to have left (ms).
const TIMEOUT_MS := 15000

## "" (not hosting), "checking", "open" (UPnP opened the port) or "closed".
var internet_status := ""
var external_ip := ""
var port := DEFAULT_PORT
var _upnp: UPNP
var _upnp_thread: Thread
var _mapped_port := 0

var peer: ENetMultiplayerPeer = null
var dedicated := false
var local_name := "Player"
var local_car_id := ""
## peer_id -> { name, car_id, ready, team, role, ... }
## Co-op (wave 5): team groups up to MAX_CREW players onto one car (-1 = own
## car); role is RaceEntry.ROLE_DRIVER / ROLE_PIT_CREW / ROLE_STRATEGIST, or
## ROLE_PIT_WALL in a team of two. The host keeps every team's roles valid
## (one driver; see RaceEntry.share_roles). The team races the car of its
## first player (lowest peer id).
var players: Dictionary = {}
var settings := RaceSettings.new()
var session: RaceSession = null
var in_race := false
## Season mode: a summary the host shares with everyone in the lobby
## (Season.summary(): name, round, next track, standings). Empty = single race.
var season_info: Dictionary = {}
## The host's race clock, worked out from pings (NetClock). Every car state is
## stamped on the host's clock so each machine can place remote cars where
## they are now. clock_offset is 0 on the host and offline.
var clock := NetClock.new()
var clock_offset: float:
	get: return clock.offset
var clock_synced: bool:
	get: return clock.synced
const PING_EVERY := 0.5
var _ping_timer := 0.0
## Host: how to plan the next race, when not a plain single race. Called as
## planner.call(settings, humans) -> start data (a season plans its own field
## and grid). Unset = RaceFactory.plan with every AI driver.
var start_planner: Callable


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func(): _fail(
		"Could not reach the host. Check the address, that the host's UDP port %d is open (their lobby says), and that the firewall lets the game through." % port))
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _process(delta: float) -> void:
	if peer == null or is_server() or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_ping_timer -= delta
	if _ping_timer <= 0.0:
		_ping_timer = PING_EVERY
		_rpc_ping.rpc_id(1, precise_clock())


## This machine's race clock (RaceSession.clock(), physics time), read
## between physics ticks to the fraction of a tick.
static func precise_clock() -> float:
	var tps := float(Engine.physics_ticks_per_second)
	return (float(Engine.get_physics_frames()) + Engine.get_physics_interpolation_fraction()) / tps


## The host's race clock, as best this machine knows it.
func host_clock() -> float:
	return RaceSession.clock() + clock_offset


func is_online() -> bool:
	return peer != null


func is_server() -> bool:
	return peer != null and multiplayer.is_server()


func my_id() -> int:
	return multiplayer.get_unique_id() if peer != null else 0


# --- Connect / host -------------------------------------------------------

func host(p_port: int, player_name: String, p_dedicated := false) -> Error:
	leave()
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(p_port, MAX_PEERS)
	if err != OK:
		peer = null
		return err
	peer.host.compress(COMPRESSION)
	multiplayer.multiplayer_peer = peer
	port = p_port
	dedicated = p_dedicated
	local_name = player_name
	players.clear()
	if not dedicated:
		players[1] = _new_player(player_name, GameData.cars.keys()[0])
	_open_router_port(p_port)
	_start_ping_watch()
	lobby_changed.emit()
	return OK


## Host: each joiner's round trip in ms goes into their lobby entry ("ping"),
## so everyone can see how good each connection is.
const PING_WATCH_S := 2.0
var _ping_watch: Timer


func _start_ping_watch() -> void:
	if _ping_watch == null:
		_ping_watch = Timer.new()
		_ping_watch.wait_time = PING_WATCH_S
		_ping_watch.timeout.connect(_measure_pings)
		add_child(_ping_watch)
	_ping_watch.start()


func _measure_pings() -> void:
	if not is_server() or in_race or not (peer is ENetMultiplayerPeer):
		return
	var changed := false
	for id in players:
		var link: ENetPacketPeer = peer.get_peer(id) if id != 1 else null
		if link == null:
			continue
		var rtt := int(link.get_statistic(ENetPacketPeer.PEER_LAST_ROUND_TRIP_TIME))
		if absi(rtt - int(players[id].get("ping", -100))) >= 10:
			players[id]["ping"] = rtt
			changed = true
	if changed:
		_broadcast_lobby()


## Splits what a player typed into the join box into host and port. Takes
## "81.2.3.4", "81.2.3.4:24690", "[2a00::1]:24690", a bare IPv6 address or a
## host name (same rules as Torque Shed).
static func parse_address(text: String, default_port := DEFAULT_PORT) -> Dictionary:
	var h := text.strip_edges()
	var p := default_port
	for prefix in ["udp://", "http://", "https://"]:
		h = h.trim_prefix(prefix)
	h = h.trim_suffix("/")
	if h.begins_with("["):
		var close := h.find("]")
		if close > 0:
			var rest := h.substr(close + 1)
			if rest.begins_with(":") and rest.substr(1).is_valid_int():
				p = int(rest.substr(1))
			h = h.substr(1, close - 1)
	elif h.count(":") == 1:
		var parts := h.split(":")
		if parts[1].strip_edges().is_valid_int():
			p = int(parts[1])
		h = parts[0]
	h = h.strip_edges()
	if p <= 0 or p > 65535:
		p = default_port
	return {"host": h, "port": p}


func join(address: String, default_port: int, player_name: String, car_id := "") -> Error:
	leave()
	var where := parse_address(address, default_port)
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(where["host"], int(where["port"]))
	if err != OK:
		peer = null
		return err
	peer.host.compress(COMPRESSION)
	multiplayer.multiplayer_peer = peer
	port = int(where["port"])
	local_name = player_name
	local_car_id = car_id
	return OK


func leave() -> void:
	if peer != null:
		peer.close()
	_close_router_port()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	peer = null
	players.clear()
	session = null
	in_race = false
	dedicated = false
	season_info = {}
	start_planner = Callable()
	clock.reset()


# --- Reaching the host over the internet (UPnP, as in Torque Shed) ----------

## LAN addresses friends can join on.
func local_addresses() -> Array:
	var out := []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254"):
			out.append(a)
	return out


## Asks the home router to forward the port to this PC (UPnP) on a thread,
## since routers can take seconds to answer.
func _open_router_port(p: int) -> void:
	internet_status = "checking"
	external_ip = ""
	internet_status_changed.emit()
	if DisplayServer.get_name() == "headless" or GameData.arg("no-upnp"):
		_upnp_done.call_deferred(false, "", p)
		return
	_wait_upnp_thread()
	_upnp_thread = Thread.new()
	_upnp_thread.start(_upnp_work.bind(p))


func _upnp_work(p: int) -> void:
	var upnp := UPNP.new()
	var ok := false
	var ip := ""
	if upnp.discover(2500, 2, "InternetGatewayDevice") == UPNP.UPNP_RESULT_SUCCESS \
			and upnp.get_gateway() and upnp.get_gateway().is_valid_gateway():
		ip = upnp.query_external_address()
		ok = upnp.add_port_mapping(p, p, "Top Down Racer", "UDP", 0) == UPNP.UPNP_RESULT_SUCCESS
	_upnp = upnp if ok else null
	_upnp_done.call_deferred(ok, ip, p)


func _upnp_done(ok: bool, ip: String, p: int) -> void:
	_wait_upnp_thread()
	if not is_server():
		if ok and _upnp:
			_upnp.delete_port_mapping(p, "UDP")
		_upnp = null
		return
	_mapped_port = p if ok else 0
	internet_status = "open" if ok else "closed"
	external_ip = ip if ip.is_valid_ip_address() and not _is_private(ip) else ""
	internet_status_changed.emit()
	if external_ip == "":
		_lookup_public_ip()


## Asks a public "what's my IP" service when the router didn't say.
func _lookup_public_ip() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var http := HTTPRequest.new()
	http.timeout = 6.0
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h, body: PackedByteArray):
		http.queue_free()
		var ip := body.get_string_from_utf8().strip_edges()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200 and ip.is_valid_ip_address() and is_server():
			external_ip = ip
			internet_status_changed.emit())
	if http.request("https://api.ipify.org") != OK:
		http.queue_free()


static func _is_private(ip: String) -> bool:
	if ip.begins_with("10.") or ip.begins_with("192.168.") or ip.begins_with("127.") or ip.begins_with("169.254."):
		return true
	if ip.begins_with("172."):
		var second := int(ip.split(".")[1])
		return second >= 16 and second <= 31
	if ip.begins_with("100."):
		var second := int(ip.split(".")[1])  # carrier-grade NAT
		return second >= 64 and second <= 127
	return false


func _close_router_port() -> void:
	if _upnp and _mapped_port > 0:
		_upnp.delete_port_mapping(_mapped_port, "UDP")
	_upnp = null
	_mapped_port = 0
	internet_status = ""
	external_ip = ""


func _wait_upnp_thread() -> void:
	if _upnp_thread and _upnp_thread.is_started() and not _upnp_thread.is_alive():
		_upnp_thread.wait_to_finish()
		_upnp_thread = null


func _exit_tree() -> void:
	_close_router_port()
	if _upnp_thread and _upnp_thread.is_started():
		_upnp_thread.wait_to_finish()


## What to tell friends, shown in the host's lobby.
func join_instructions() -> String:
	var lan := ", ".join(local_addresses())
	var lines := ["Friends on your home network join with: %s" % lan]
	match internet_status:
		"checking":
			lines.append("Checking whether friends over the internet can reach you...")
		"open":
			lines.append("Your router opened port %d, so friends over the internet join with: %s" % [port,
				external_ip if external_ip != "" else "your public IP address"])
		"closed":
			lines.append("Your router didn't open the port automatically. For friends over the internet, forward UDP port %d to %s, then they join with: %s" % [
				port, local_addresses()[0] if not local_addresses().is_empty() else "this PC",
				external_ip if external_ip != "" else "your public IP address"])
	return "\n".join(lines)


func _new_player(player_name: String, car_id: String) -> Dictionary:
	return {"name": player_name, "car_id": car_id, "tyre": "auto", "ready": false, "team": -1,
		"role": RaceEntry.ROLE_DRIVER, "setup": {}, "livery": {}, "activity": "lobby"}


func _fail(reason: String) -> void:
	leave()
	connection_failed.emit(reason)


func _on_connected_to_server() -> void:
	_register.rpc_id(1, PROTOCOL_VERSION, local_name, local_car_id)


func _on_peer_connected(id: int) -> void:
	# Ride out a few seconds of silence (loading a track) instead of ENet's default 5 s drop.
	# A client's ENet link only knows the host (peer 1); other players come via the host.
	if peer and (is_server() or id == 1) and peer.get_peer(id):
		peer.get_peer(id).set_timeout(32, TIMEOUT_MS, 30000)


func _on_peer_disconnected(id: int) -> void:
	if not is_server():
		return
	players.erase(id)
	if session:
		session.on_peer_left(id)
	_broadcast_lobby()


func _on_server_disconnected() -> void:
	leave()
	disconnected.emit("Host closed the session.")


# --- Lobby RPCs -------------------------------------------------------------

@rpc("any_peer", "reliable")
func _register(version: int, player_name: String, car_id: String) -> void:
	if not is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if version != PROTOCOL_VERSION:
		_kick.rpc_id(id, "Version mismatch (host %d, you %d)." % [PROTOCOL_VERSION, version])
		return
	if in_race:
		_kick.rpc_id(id, "Race in progress. Spectating mid-race arrives in wave 2.")
		return
	player_name = player_name.strip_edges().left(20)
	if player_name.is_empty():
		player_name = "Player %d" % id
	if not GameData.cars.has(car_id):
		car_id = GameData.cars.keys()[0]
	players[id] = _new_player(player_name, car_id)
	_broadcast_lobby()


@rpc("authority", "reliable")
func _kick(reason: String) -> void:
	_fail(reason)


@rpc("authority", "reliable")
func _sync_lobby(p_players: Dictionary, p_settings: Dictionary, p_season: Dictionary) -> void:
	players = p_players
	settings = RaceSettings.from_dict(p_settings)
	season_info = p_season
	lobby_changed.emit()


func _broadcast_lobby() -> void:
	if not is_server():
		return
	_sync_lobby.rpc(players, settings.to_dict(), season_info)
	lobby_changed.emit()


const TYRE_CHOICES := ["auto", "dry", "intermediate", "wet"]
## What a player is doing in the menus, shown in everyone's lobby.
const ACTIVITIES := ["lobby", "garage", "setup", "settings"]
## Co-op: players sharing one car, and how many teams the lobby offers.
const MAX_CREW := 3
const MAX_TEAMS := 8


## Client (or host) changes its own lobby entry: car, tyres, ready flag.
func update_me(fields: Dictionary) -> void:
	if is_server():
		_apply_update(1, fields)
	else:
		_request_update.rpc_id(1, fields)


@rpc("any_peer", "reliable")
func _request_update(fields: Dictionary) -> void:
	if is_server():
		_apply_update(multiplayer.get_remote_sender_id(), fields)


func _apply_update(id: int, fields: Dictionary) -> void:
	if not players.has(id):
		return
	var p: Dictionary = players[id]
	if fields.has("car_id") and GameData.cars.has(fields["car_id"]):
		p["car_id"] = fields["car_id"]
	if fields.has("ready"):
		p["ready"] = bool(fields["ready"])
	if fields.has("tyre") and fields["tyre"] in TYRE_CHOICES:
		p["tyre"] = fields["tyre"]
	if fields.has("activity") and fields["activity"] in ACTIVITIES:
		p["activity"] = fields["activity"]
	# The car's setup (upgrade overrides + tuning) and livery, from the
	# player's own profile. The host's upgrades_mode decides what counts.
	if fields.get("setup") is Dictionary and str(fields["setup"]).length() < 4000:
		p["setup"] = fields["setup"]
	if fields.get("livery") is Dictionary:
		p["livery"] = fields["livery"]
	if fields.has("team") or fields.has("role"):
		_set_team(id, int(fields.get("team", p.get("team", -1))), str(fields.get("role", "")))
	_broadcast_lobby()


## Host: put a player in a co-op team (-1 = their own car) and/or give them a
## role in it (from the lobby's team list; works for any player).
func set_player_team(id: int, team: int, role := "") -> void:
	if is_server() and players.has(id):
		_set_team(id, team, role)
		_broadcast_lobby()


## Players in a team, by peer id (lowest first: the first one's car is raced).
func team_members(team: int) -> Array:
	var out := []
	if team < 0:
		return out
	for id in players:
		if int(players[id].get("team", -1)) == team:
			out.append(id)
	out.sort()
	return out


func _set_team(id: int, team: int, role: String) -> void:
	var p: Dictionary = players[id]
	team = clampi(team, -1, MAX_TEAMS - 1)
	var old_team := int(p.get("team", -1))
	if team != old_team and team >= 0 and team_members(team).size() >= MAX_CREW:
		team = old_team  # that car is full
	if team != old_team:
		p["team"] = team
		p["role"] = RaceEntry.ROLE_DRIVER if team_members(team).size() <= 1 else ""
		_share_team_roles(old_team)
	if team < 0:
		p["role"] = RaceEntry.ROLE_DRIVER
		return
	if role != "" and role in RaceEntry.roles_for_crew(team_members(team).size()):
		# Taking someone's role swaps with them.
		for other in team_members(team):
			if other != id and players[other].get("role", "") == role:
				players[other]["role"] = p.get("role", "")
		p["role"] = role
	_share_team_roles(team)


func _share_team_roles(team: int) -> void:
	if team < 0:
		return
	var members := []
	for id in team_members(team):
		members.append(players[id])
	RaceEntry.share_roles(members)


## Host only: race options.
func set_settings(new_settings: RaceSettings) -> void:
	if is_server():
		settings = new_settings
		_broadcast_lobby()


## Host only: the season everyone is playing ({} = single races).
func set_season_info(info: Dictionary) -> void:
	if is_server():
		season_info = info
		_broadcast_lobby()


func all_ready() -> bool:
	## The listen-server host starts the race, so only joiners must be ready.
	var count := 0
	for id in players:
		count += 1
		if id != 1 and not players[id]["ready"]:
			return false
	return count > 0


# --- Race start ---------------------------------------------------------------

## Host: group lobby players into cars (crews) and start for everyone.
func start_race() -> void:
	if not is_server() or in_race:
		return
	var humans := []
	var teams := {}
	var ids := players.keys()
	ids.sort()
	for t in MAX_TEAMS:
		_share_team_roles(t)
	for id in ids:
		var p: Dictionary = players[id]
		var team: int = p.get("team", -1)
		var key = team if team >= 0 and team_members(team).size() > 1 else "solo_%d" % id
		if not teams.has(key):
			teams[key] = {"name": p["name"], "car_id": p["car_id"], "tyre": p.get("tyre", "auto"), "crew": [],
				"setup": p.get("setup", {}), "livery": p.get("livery", {})}
			humans.append(teams[key])
		var role: String = RaceEntry.ROLE_DRIVER if str(key).begins_with("solo") else str(p.get("role", RaceEntry.ROLE_DRIVER))
		teams[key]["crew"].append({"peer_id": id, "name": p["name"], "role": role})
	settings.seed = randi()
	var start_data: Dictionary = start_planner.call(settings, humans) if start_planner.is_valid() \
		else RaceFactory.plan(settings, humans, GameData.cars, GameData.drivers)
	_begin_race.rpc(start_data)
	_begin_race(start_data)


@rpc("authority", "reliable")
func _begin_race(start_data: Dictionary) -> void:
	in_race = true
	var mode := RaceSession.Mode.SERVER if is_server() else RaceSession.Mode.CLIENT
	session = RaceSession.create(mode, start_data, my_id(), self)
	GameData.active_session = session
	race_started.emit(start_data)


## Host: everyone back to the lobby (after results).
func end_race() -> void:
	if is_server():
		for id in players:
			players[id]["ready"] = false
		_back_to_lobby.rpc()
		_back_to_lobby()
		_broadcast_lobby()


@rpc("authority", "reliable")
func _back_to_lobby() -> void:
	in_race = false
	session = null
	returned_to_lobby.emit()


# --- Clock sync (so every machine agrees on when a car state was taken) --------

@rpc("any_peer", "unreliable", "call_remote", 6)
func _rpc_ping(t0: float) -> void:
	if is_server():
		_rpc_pong.rpc_id(multiplayer.get_remote_sender_id(), t0, precise_clock())


@rpc("authority", "unreliable", "call_remote", 6)
func _rpc_pong(t0: float, host_t: float) -> void:
	_on_pong(t0, host_t, precise_clock())


func _on_pong(t0: float, host_t: float, now: float) -> void:
	clock.add_pong(t0, host_t, now)


# --- Race traffic -------------------------------------------------------------

## Each player streams the cars they simulate; the host relays to everyone.
func send_car_states(sent: float, data: PackedFloat32Array) -> void:
	_rpc_cars.rpc(sent, data)


@rpc("any_peer", "unreliable_ordered", "call_remote", 1)
func _rpc_cars(sent: float, data: PackedFloat32Array) -> void:
	if session:
		session.on_car_states(multiplayer.get_remote_sender_id(), sent, data)


func broadcast_race_state(bytes: PackedByteArray) -> void:
	_rpc_race_state.rpc(bytes)


@rpc("authority", "unreliable_ordered", "call_remote", 2)
func _rpc_race_state(bytes: PackedByteArray) -> void:
	if session:
		session.on_race_state(bytes)


func broadcast_events(evs: Array) -> void:
	_rpc_events.rpc(evs)


@rpc("authority", "reliable", "call_remote", 3)
func _rpc_events(evs: Array) -> void:
	if session:
		session.on_remote_events(evs)


## Pit stops: the owner of a car tells the host its pit state when it changes.
func send_pit_state(car: int, state: Dictionary) -> void:
	_rpc_pit_state.rpc_id(1, car, state)


@rpc("any_peer", "reliable", "call_remote", 4)
func _rpc_pit_state(car: int, state: Dictionary) -> void:
	if session and is_server():
		session.on_pit_state(multiplayer.get_remote_sender_id(), car, state)


## A crew member (driver, pit crew, strategist) changes a car's pit plan, the
## box call or the limiter. Goes to the host, which passes it to the car's owner.
func send_pit_request(to_peer: int, car: int, changes: Dictionary) -> void:
	_rpc_pit_request.rpc_id(to_peer, car, changes)


@rpc("any_peer", "reliable", "call_remote", 4)
func _rpc_pit_request(car: int, changes: Dictionary) -> void:
	if session:
		session.on_pit_request(multiplayer.get_remote_sender_id(), car, changes)



# --- Co-op crews: role swaps, driver changes, team radio ------------------------

## A crew member asks the host to swap two crew members' roles (0, 0 = cancel).
func send_role_swap(car: int, a: int, b: int) -> void:
	_rpc_role_swap.rpc_id(1, car, a, b)


@rpc("any_peer", "reliable", "call_remote", 4)
func _rpc_role_swap(car: int, a: int, b: int) -> void:
	if session and is_server():
		session.on_role_swap_request(multiplayer.get_remote_sender_id(), car, a, b)


## The machine that simulated a car hands it to the host for a driver change.
func send_handover(car: int, a: int, b: int, state: Dictionary) -> void:
	_rpc_handover.rpc_id(1, car, a, b, state)


@rpc("any_peer", "reliable", "call_remote", 4)
func _rpc_handover(car: int, a: int, b: int, state: Dictionary) -> void:
	if session and is_server():
		session.on_handover(multiplayer.get_remote_sender_id(), car, a, b, state)


## Host: a car's crew, owner, waiting driver change and (after a change) state.
func broadcast_crew(car: int, crew: Array, owner: int, pending: Dictionary, state: Dictionary) -> void:
	_rpc_crew.rpc(car, crew, owner, pending, state)


@rpc("authority", "reliable", "call_remote", 4)
func _rpc_crew(car: int, crew: Array, owner: int, pending: Dictionary, state: Dictionary) -> void:
	if session:
		session.apply_crew(car, crew, owner, pending, state)


## Team radio: a player sends to the host, the host to each crew member.
func send_team_radio(to_peer: int, car: int, msg: Dictionary) -> void:
	if str(msg).length() < 2000:
		_rpc_team_radio.rpc_id(to_peer, car, msg)


@rpc("any_peer", "reliable", "call_remote", 5)
func _rpc_team_radio(car: int, msg: Dictionary) -> void:
	if session:
		var sender := multiplayer.get_remote_sender_id()
		if is_server():
			session.on_team_radio(sender, car, msg)
		elif sender == 1:
			session.on_team_radio(1, car, msg)
