class_name NetworkManager
extends Node

## Autoload this node as `NetworkManager`. The game session owns simulation;
## this service owns transports, lobby replication, and authority boundaries.

signal connection_state_changed(state: int)
signal host_started(room: Dictionary)
signal connected_to_host(room: Dictionary)
signal connection_failed(reason: String)
signal room_closed(reason: String)

signal room_seen(room: Dictionary)
signal room_expired(room_key: String, room: Dictionary)
signal incompatible_room_seen(room: Dictionary)
signal room_list_changed(rooms: Array)

signal lobby_changed(snapshot: Dictionary)
signal peer_joined(peer_id: int, player: Dictionary)
signal peer_left(peer_id: int)
signal request_rejected(reason: String)

## These are host-only gameplay hooks. A GameSession subscribes to them and
## performs all simulation before publishing an authoritative result.
signal host_input_received(peer_id: int, movement: Vector2, aim: Vector2)
signal host_start_requested(peer_id: int)
signal host_action_requested(peer_id: int, action: StringName, payload: Dictionary)

## Client-facing replication hooks.
signal match_phase_changed(phase: StringName, payload: Dictionary)
signal player_state_snapshot_received(snapshot: Dictionary, server_tick: int)
signal match_event_received(event_name: StringName, payload: Dictionary)

enum ConnectionState { OFFLINE, HOSTING, CONNECTING, CONNECTED }

const SERVER_PEER_ID := 1
const DEFAULT_GAME_PORT := 10567
const DEFAULT_DISCOVERY_PORT := 47777
const DEFAULT_MAX_PLAYERS := 8
const DEFAULT_BEACON_INTERVAL_SEC := 1.0
const DEFAULT_ROOM_TIMEOUT_SEC := 3.0
const DEFAULT_PROTOCOL_VERSION := "1.0.0"

const INPUT_CHANNEL := 1
const STATE_CHANNEL := 2
const EVENT_CHANNEL := 3
const MAX_DISPLAY_NAME_LENGTH := 24
const MAX_ENTRY_ID_LENGTH := 64

const LanRoomDiscoveryScript = preload("res://scripts/network/lan_room_discovery.gd")

var game_port: int = DEFAULT_GAME_PORT
var discovery_port: int = DEFAULT_DISCOVERY_PORT
var max_players: int = DEFAULT_MAX_PLAYERS
var beacon_interval_sec: float = DEFAULT_BEACON_INTERVAL_SEC
var room_timeout_sec: float = DEFAULT_ROOM_TIMEOUT_SEC
var protocol_version: String = DEFAULT_PROTOCOL_VERSION

var local_display_name: String = "Player"
var local_team: int = 0

var _connection_state: int = 0
var _peer: ENetMultiplayerPeer = null
var _discovery = LanRoomDiscoveryScript.new()
var _lobby_players: Dictionary = {}
var _room: Dictionary = {}
var _phase: StringName = &"offline"
var _last_input_sequence: Dictionary = {}
var _next_input_sequence: int = 0
var _beacon_generation: int = 0
var _expiry_generation: int = 0
var _scanning_rooms := false


func _ready() -> void:
	# MultiplayerAPI and SceneTreeTimer are runtime objects whose lifetime
	# changes with a connection; their signal wiring cannot live in a tscn.
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_discovery.room_seen.connect(_on_discovery_room_seen)
	_discovery.room_expired.connect(_on_discovery_room_expired)
	_discovery.incompatible_room_seen.connect(_on_incompatible_room_seen)
	_apply_discovery_configuration()


func _exit_tree() -> void:
	shutdown()


func _process(_delta: float) -> void:
	if _scanning_rooms:
		_discovery.poll()


func configure_from_balance(balance: Resource) -> void:
	if balance == null:
		return
	game_port = clampi(int(balance.get("game_port")), 1, 65535)
	discovery_port = clampi(int(balance.get("discovery_port")), 1, 65535)
	max_players = maxi(1, int(balance.get("max_players")) if balance.get("max_players") != null else DEFAULT_MAX_PLAYERS)
	beacon_interval_sec = maxf(float(balance.get("beacon_interval_sec")), 0.1)
	room_timeout_sec = maxf(float(balance.get("room_timeout_sec")), 0.1)
	_apply_discovery_configuration()


func set_local_profile(display_name: String, preferred_team: int = 0) -> void:
	local_display_name = _sanitize_display_name(display_name)
	local_team = _sanitize_team(preferred_team)
	if is_host():
		var host_player: Dictionary = _lobby_players.get(SERVER_PEER_ID, {})
		if not host_player.is_empty():
			host_player["display_name"] = local_display_name
			host_player["team"] = local_team
			_lobby_players[SERVER_PEER_ID] = host_player
			_broadcast_lobby_snapshot()


func start_room_scan() -> Error:
	_apply_discovery_configuration()
	var error := _discovery.start_scanning()
	if error != OK:
		connection_failed.emit("Unable to listen for LAN rooms on UDP %d (%d)" % [discovery_port, error])
		return error
	_scanning_rooms = true
	_expiry_generation += 1
	_schedule_room_expiry(_expiry_generation)
	room_list_changed.emit(_discovery.rooms())
	return OK


func stop_room_scan() -> void:
	_scanning_rooms = false
	_expiry_generation += 1
	_discovery.stop_scanning()
	room_list_changed.emit([])


func rooms() -> Array[Dictionary]:
	return _discovery.rooms()


func host_room(room_name: String, map_id: StringName = &"medium", requested_max_players: int = DEFAULT_MAX_PLAYERS, map_revision: int = 1) -> Error:
	shutdown()
	max_players = clampi(requested_max_players, 1, 64)
	_peer = ENetMultiplayerPeer.new()
	var error := _peer.create_server(game_port, max_players)
	if error != OK:
		_peer = null
		connection_failed.emit("Unable to host ENet on port %d (%d)" % [game_port, error])
		return error
	multiplayer.multiplayer_peer = _peer
	_connection_state = ConnectionState.HOSTING
	_phase = &"lobby"
	_room = {"room_name": _sanitize_room_name(room_name), "host_ip": _discovery.get_preferred_local_address(), "game_port": game_port, "max_players": max_players, "map_id": String(map_id), "map_revision": maxi(map_revision, 0), "state": "waiting", "version": protocol_version}
	_lobby_players = {SERVER_PEER_ID: _make_player(SERVER_PEER_ID, local_display_name, local_team)}
	_last_input_sequence.clear()
	_connection_state_changed()
	_start_advertising()
	host_started.emit(room_snapshot())
	_broadcast_lobby_snapshot()
	return OK


func join_room(host_ip: String, host_port: int = -1) -> Error:
	var address := host_ip.strip_edges()
	if address.is_empty():
		return ERR_INVALID_PARAMETER
	shutdown()
	_peer = ENetMultiplayerPeer.new()
	var target_port := game_port if host_port < 1 else clampi(host_port, 1, 65535)
	var error := _peer.create_client(address, target_port)
	if error != OK:
		_peer = null
		connection_failed.emit("Unable to connect to %s:%d (%d)" % [address, target_port, error])
		return error
	multiplayer.multiplayer_peer = _peer
	_connection_state = ConnectionState.CONNECTING
	_phase = &"lobby"
	_room = {"host_ip": address, "game_port": target_port, "state": "connecting", "version": protocol_version}
	_connection_state_changed()
	return OK


func leave_room(reason: String = "left_room") -> void:
	var was_connected := _connection_state != ConnectionState.OFFLINE
	shutdown()
	if was_connected:
		room_closed.emit(reason)


func shutdown() -> void:
	_stop_advertising()
	stop_room_scan()
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_peer = null
	_lobby_players.clear()
	_last_input_sequence.clear()
	_room.clear()
	_phase = &"offline"
	if _connection_state != ConnectionState.OFFLINE:
		_connection_state = ConnectionState.OFFLINE
		_connection_state_changed()


func connection_state() -> int:
	return _connection_state


func is_host() -> bool:
	return _connection_state == ConnectionState.HOSTING and multiplayer.has_multiplayer_peer() and multiplayer.is_server()


func has_connection() -> bool:
	return _connection_state == ConnectionState.HOSTING or _connection_state == ConnectionState.CONNECTED


func local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return 0
	return multiplayer.get_unique_id()


func room_snapshot() -> Dictionary:
	return _room.duplicate(true)


func lobby_snapshot() -> Dictionary:
	var players: Array[Dictionary] = []
	for player_variant in _lobby_players.values():
		players.append(Dictionary(player_variant).duplicate(true))
	return {"room": room_snapshot(), "phase": String(_phase), "players": players}


func get_lobby_players() -> Dictionary:
	return _lobby_players.duplicate(true)


func host_set_player_team(peer_id: int, team: int) -> bool:
	if not is_host() or not _lobby_players.has(peer_id) or _phase != &"lobby":
		return false
	var player: Dictionary = _lobby_players[peer_id]
	player["team"] = _sanitize_team(team)
	_lobby_players[peer_id] = player
	_broadcast_lobby_snapshot()
	return true


func host_set_map(map_id: StringName, map_revision: int = 1) -> bool:
	if not is_host() or _phase != &"lobby":
		return false
	_room["map_id"] = String(map_id)
	_room["map_revision"] = maxi(map_revision, 0)
	_broadcast_lobby_snapshot()
	return true


func host_set_match_phase(phase: StringName, payload: Dictionary = {}) -> bool:
	if not is_host():
		return false
	_phase = phase
	_room["state"] = "playing" if phase == &"countdown" or phase == &"playing" or phase == &"score_lock" else "waiting"
	_receive_match_phase.rpc(String(phase), payload.duplicate(true))
	match_phase_changed.emit(phase, payload.duplicate(true))
	_broadcast_lobby_snapshot()
	return true


func host_publish_player_state(snapshot: Dictionary, server_tick: int) -> bool:
	if not is_host():
		return false
	_receive_player_state_snapshot.rpc(snapshot.duplicate(true), server_tick)
	return true


func host_publish_match_event(event_name: StringName, payload: Dictionary, reliable: bool = true) -> bool:
	if not is_host():
		return false
	if reliable:
		_receive_match_event.rpc(String(event_name), payload.duplicate(true))
	else:
		_receive_match_event_unreliable.rpc(String(event_name), payload.duplicate(true))
	match_event_received.emit(event_name, payload.duplicate(true))
	return true


func submit_local_input(movement: Vector2, aim: Vector2 = Vector2.ZERO) -> void:
	var sanitized_movement := _sanitize_direction(movement)
	var sanitized_aim := _sanitize_direction(aim)
	_next_input_sequence += 1
	if is_host():
		_accept_input(SERVER_PEER_ID, sanitized_movement, sanitized_aim, _next_input_sequence)
	elif _connection_state == ConnectionState.CONNECTED:
		_submit_input.rpc_id(SERVER_PEER_ID, sanitized_movement, sanitized_aim, _next_input_sequence)


func request_team_change(team: int) -> void:
	var sanitized_team := _sanitize_team(team)
	if is_host():
		host_set_player_team(SERVER_PEER_ID, sanitized_team)
	elif _connection_state == ConnectionState.CONNECTED:
		_request_team_change.rpc_id(SERVER_PEER_ID, sanitized_team)


func request_match_start() -> void:
	if is_host():
		host_start_requested.emit(SERVER_PEER_ID)
	elif _connection_state == ConnectionState.CONNECTED:
		_request_match_start.rpc_id(SERVER_PEER_ID)


func request_game_action(action: StringName, payload: Dictionary = {}) -> void:
	var sanitized := _sanitize_action_payload(action, payload)
	if sanitized.is_empty() and action != &"skill_upgrade":
		request_rejected.emit("Invalid game action")
		return
	if is_host():
		host_action_requested.emit(SERVER_PEER_ID, action, sanitized)
	elif _connection_state == ConnectionState.CONNECTED:
		_request_game_action.rpc_id(SERVER_PEER_ID, String(action), sanitized)


@rpc("any_peer", "reliable")
func _request_lobby_join(profile: Dictionary) -> void:
	if not is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id < SERVER_PEER_ID or not _lobby_players.has(sender_id):
		return
	var player: Dictionary = _lobby_players[sender_id]
	player["display_name"] = _sanitize_display_name(String(profile.get("display_name", "")))
	player["team"] = _sanitize_team(int(profile.get("team", 0)))
	_lobby_players[sender_id] = player
	_broadcast_lobby_snapshot()


@rpc("any_peer", "reliable")
func _request_team_change(team: int) -> void:
	if not is_host() or _phase != &"lobby":
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not host_set_player_team(sender_id, team):
		request_rejected.emit("Unable to change team")


@rpc("any_peer", "reliable")
func _request_match_start() -> void:
	if not is_host():
		return
	# The host explicitly owns start permission. Remote clients may request it,
	# but never trigger a countdown on their own.
	request_rejected.emit("Only the host can start the match")


@rpc("any_peer", "reliable")
func _request_game_action(action_text: String, payload: Dictionary) -> void:
	if not is_host():
		return
	var action := StringName(action_text)
	var sanitized := _sanitize_action_payload(action, payload)
	if sanitized.is_empty() and action != &"skill_upgrade":
		return
	host_action_requested.emit(multiplayer.get_remote_sender_id(), action, sanitized)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _submit_input(movement: Vector2, aim: Vector2, sequence: int) -> void:
	if not is_host():
		return
	_accept_input(multiplayer.get_remote_sender_id(), movement, aim, sequence)


@rpc("authority", "reliable")
func _receive_lobby_snapshot(snapshot: Dictionary) -> void:
	if is_host():
		return
	_apply_lobby_snapshot(snapshot)


@rpc("authority", "reliable")
func _receive_match_phase(phase_text: String, payload: Dictionary) -> void:
	if is_host():
		return
	_phase = StringName(phase_text)
	match_phase_changed.emit(_phase, payload.duplicate(true))


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _receive_player_state_snapshot(snapshot: Dictionary, server_tick: int) -> void:
	if is_host():
		return
	player_state_snapshot_received.emit(snapshot.duplicate(true), server_tick)


@rpc("authority", "call_remote", "reliable", 3)
func _receive_match_event(event_text: String, payload: Dictionary) -> void:
	if is_host():
		return
	match_event_received.emit(StringName(event_text), payload.duplicate(true))


@rpc("authority", "call_remote", "unreliable_ordered", 3)
func _receive_match_event_unreliable(event_text: String, payload: Dictionary) -> void:
	if is_host():
		return
	match_event_received.emit(StringName(event_text), payload.duplicate(true))


func _on_peer_connected(peer_id: int) -> void:
	if not is_host() or peer_id == SERVER_PEER_ID:
		return
	if _lobby_players.size() >= max_players:
		return
	var player := _make_player(peer_id, "Player %d" % peer_id, 1)
	_lobby_players[peer_id] = player
	peer_joined.emit(peer_id, player.duplicate(true))
	_broadcast_lobby_snapshot()


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host():
		return
	if _lobby_players.erase(peer_id):
		_last_input_sequence.erase(peer_id)
		peer_left.emit(peer_id)
		_broadcast_lobby_snapshot()


func _on_connected_to_server() -> void:
	if _connection_state != ConnectionState.CONNECTING:
		return
	_connection_state = ConnectionState.CONNECTED
	_connection_state_changed()
	_request_lobby_join.rpc_id(SERVER_PEER_ID, {"display_name": local_display_name, "team": local_team})
	connected_to_host.emit(room_snapshot())


func _on_connection_failed() -> void:
	var detail := "ENet connection failed"
	_reset_connection_state()
	connection_failed.emit(detail)


func _on_server_disconnected() -> void:
	_reset_connection_state()
	room_closed.emit("host_disconnected")


func _on_discovery_room_seen(room: Dictionary) -> void:
	room_seen.emit(room)
	room_list_changed.emit(_discovery.rooms())


func _on_discovery_room_expired(room_key: String, room: Dictionary) -> void:
	room_expired.emit(room_key, room)
	room_list_changed.emit(_discovery.rooms())


func _on_incompatible_room_seen(room: Dictionary) -> void:
	incompatible_room_seen.emit(room)


func _accept_input(peer_id: int, movement: Vector2, aim: Vector2, sequence: int) -> void:
	if not _lobby_players.has(peer_id):
		return
	var previous_sequence := int(_last_input_sequence.get(peer_id, -1))
	if sequence <= previous_sequence:
		return
	_last_input_sequence[peer_id] = sequence
	host_input_received.emit(peer_id, _sanitize_direction(movement), _sanitize_direction(aim))


func _broadcast_lobby_snapshot() -> void:
	if not is_host():
		return
	var snapshot := lobby_snapshot()
	_receive_lobby_snapshot.rpc(snapshot)
	lobby_changed.emit(snapshot)
	_refresh_beacon()


func _apply_lobby_snapshot(snapshot: Dictionary) -> void:
	_room = Dictionary(snapshot.get("room", {})).duplicate(true)
	_phase = StringName(String(snapshot.get("phase", "lobby")))
	_lobby_players.clear()
	for player_variant in Array(snapshot.get("players", [])):
		if not (player_variant is Dictionary):
			continue
		var player: Dictionary = player_variant
		var peer_id := int(player.get("peer_id", 0))
		if peer_id > 0:
			_lobby_players[peer_id] = player.duplicate(true)
	lobby_changed.emit(lobby_snapshot())


func _start_advertising() -> void:
	_apply_discovery_configuration()
	_refresh_beacon()
	var error := _discovery.start_advertising(_make_beacon())
	if error != OK:
		connection_failed.emit("Unable to advertise LAN room (%d)" % error)
		return
	_beacon_generation += 1
	_schedule_beacon(_beacon_generation)


func _stop_advertising() -> void:
	_beacon_generation += 1
	_discovery.stop_advertising()


func _refresh_beacon() -> void:
	if is_host():
		_discovery.set_beacon(_make_beacon())


func _make_beacon() -> Dictionary:
	return {"room_name": String(_room.get("room_name", "Sky Leaf Room")), "host_ip": String(_room.get("host_ip", _discovery.get_preferred_local_address())), "game_port": game_port, "players": _lobby_players.size(), "max_players": max_players, "map_size": String(_room.get("map_id", "medium")), "state": String(_room.get("state", "waiting"))}


func _schedule_beacon(generation: int) -> void:
	if not is_inside_tree() or generation != _beacon_generation or not is_host():
		return
	var timer := get_tree().create_timer(beacon_interval_sec)
	timer.timeout.connect(_on_beacon_timeout.bind(generation))


func _on_beacon_timeout(generation: int) -> void:
	if generation != _beacon_generation or not is_host():
		return
	_refresh_beacon()
	_discovery.publish_beacon()
	_schedule_beacon(generation)


func _schedule_room_expiry(generation: int) -> void:
	if not is_inside_tree() or generation != _expiry_generation or not _scanning_rooms:
		return
	var timer := get_tree().create_timer(minf(1.0, room_timeout_sec))
	timer.timeout.connect(_on_room_expiry_timeout.bind(generation))


func _on_room_expiry_timeout(generation: int) -> void:
	if generation != _expiry_generation or not _scanning_rooms:
		return
	_discovery.expire_rooms()
	_schedule_room_expiry(generation)


func _reset_connection_state() -> void:
	_stop_advertising()
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_peer = null
	_lobby_players.clear()
	_last_input_sequence.clear()
	_room.clear()
	_phase = &"offline"
	if _connection_state != ConnectionState.OFFLINE:
		_connection_state = ConnectionState.OFFLINE
		_connection_state_changed()


func _connection_state_changed() -> void:
	connection_state_changed.emit(_connection_state)


func _apply_discovery_configuration() -> void:
	_discovery.configure(discovery_port, protocol_version, room_timeout_sec)


func _make_player(peer_id: int, display_name: String, team: int) -> Dictionary:
	return {"peer_id": peer_id, "display_name": _sanitize_display_name(display_name), "team": _sanitize_team(team), "connected": true}


func _sanitize_display_name(value: String) -> String:
	var result := value.strip_edges().substr(0, MAX_DISPLAY_NAME_LENGTH)
	return "Player" if result.is_empty() else result


func _sanitize_room_name(value: String) -> String:
	var result := value.strip_edges().substr(0, 40)
	return "Sky Leaf Room" if result.is_empty() else result


func _sanitize_team(team: int) -> int:
	return 0 if team <= 0 else 1


func _sanitize_direction(direction: Vector2) -> Vector2:
	if not is_finite(direction.x) or not is_finite(direction.y):
		return Vector2.ZERO
	return direction.limit_length(1.0)


func _sanitize_action_payload(action: StringName, payload: Dictionary) -> Dictionary:
	match action:
		&"skill_upgrade":
			var entry_id := String(payload.get("entry_id", "")).strip_edges()
			if entry_id.is_empty() or entry_id.length() > MAX_ENTRY_ID_LENGTH:
				return {}
			return {"entry_id": entry_id}
		&"set_ready":
			return {"ready": bool(payload.get("ready", false))}
	return {}
