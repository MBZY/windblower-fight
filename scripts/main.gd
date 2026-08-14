extends Node

const GAME_SESSION := preload("res://scenes/game/game_session.tscn")
const MAIN_MENU := preload("res://scenes/main/main_menu.tscn")
const ROOM_BROWSER := preload("res://scenes/ui/room_browser.tscn")
const LOBBY := preload("res://scenes/ui/lobby.tscn")

var current_session: GameSession
var current_menu: MainMenu
var current_browser: RoomBrowser
var current_lobby: LobbyView
var _network_manager: NetworkManager
var _network_signals_bound := false

func _ready() -> void:
	_network_manager = get_node_or_null("NetworkManager") as NetworkManager
	show_menu()

func show_menu() -> void:
	_clear_flow_views()
	if current_session:
		current_session.leave_room()
		if current_session.get_parent() == self:
			remove_child(current_session)
		current_session.queue_free()
		current_session = null
	if current_menu:
		if current_menu.get_parent() == self:
			remove_child(current_menu)
		current_menu.queue_free()
	current_menu = MAIN_MENU.instantiate()
	add_child(current_menu)
	current_menu.create_room_requested.connect(_on_create_room)
	current_menu.browse_rooms_requested.connect(_on_browse_rooms)
	current_menu.join_ip_requested.connect(_on_join_ip)


func _clear_flow_views() -> void:
	for view in [current_browser, current_lobby]:
		if view:
			if view.get_parent() == self:
				remove_child(view)
			view.queue_free()
	current_browser = null
	current_lobby = null

func _start_session() -> GameSession:
	_clear_flow_views()
	if current_session:
		current_session.leave_room()
		if current_session.get_parent() == self:
			remove_child(current_session)
		current_session.queue_free()
		current_session = null
	if current_menu:
		if current_menu.get_parent() == self:
			remove_child(current_menu)
		current_menu.queue_free()
		current_menu = null
	current_session = GAME_SESSION.instantiate()
	current_session.auto_start_single_player = false
	add_child(current_session)
	return current_session

func _show_browser() -> void:
	_clear_flow_views()
	if current_menu:
		if current_menu.get_parent() == self:
			remove_child(current_menu)
		current_menu.queue_free()
		current_menu = null
	current_browser = ROOM_BROWSER.instantiate()
	add_child(current_browser)
	current_browser.back_requested.connect(show_menu)
	current_browser.refresh_requested.connect(_refresh_rooms)
	current_browser.join_ip_requested.connect(_on_join_ip)
	current_browser.join_room_requested.connect(_on_join_room)
	_refresh_rooms()

func _show_lobby(session: GameSession) -> void:
	_clear_flow_views()
	current_lobby = LOBBY.instantiate()
	add_child(current_lobby)
	current_lobby.set_host(_network_manager == null or _network_manager.is_host())
	current_lobby.leave_requested.connect(show_menu)
	current_lobby.start_requested.connect(_on_lobby_start)
	current_lobby.team_requested.connect(_on_team_requested)
	current_lobby.map_requested.connect(_on_map_requested)
	if _network_manager != null:
		_bind_network_signals()
	if not session.phase_changed.is_connected(_on_session_phase_changed):
		session.phase_changed.connect(_on_session_phase_changed)
	if not session.event_announced.is_connected(_on_session_event):
		session.event_announced.connect(_on_session_event)
	_update_lobby()
	if session.multiplayer.has_multiplayer_peer() and not session.multiplayer.is_server():
		session.multiplayer.connected_to_server.connect(_update_lobby)

func _refresh_rooms() -> void:
	if not current_browser:
		return
	if _network_manager != null:
		_bind_network_signals()
		_network_manager.start_room_scan()
		current_browser.show_rooms(_network_manager.rooms())

func _update_lobby() -> void:
	if not current_lobby or not current_session:
		return
	if _network_manager != null and _network_manager.has_connection():
		var snapshot := _network_manager.lobby_snapshot()
		current_lobby.set_room_snapshot(snapshot.get("room", {}), snapshot.get("players", []))
		return
	var roster: Array = []
	for player in current_session.players.values():
		if player is IslandPlayer:
			roster.append({"peer_id": player.player_id, "display_name": "Player %d" % player.player_id, "team": player.team})
	current_lobby.set_room_snapshot({"room_name": "Sky Leaf Room", "state": String(current_session.phase)}, roster)

func _on_network_lobby_changed(_snapshot: Dictionary) -> void:
	_update_lobby()

func _on_network_room_closed(_reason: String) -> void:
	if current_lobby:
		show_menu()

func _on_session_phase_changed(_phase: StringName) -> void:
	if current_session and (current_session.phase == &"countdown" or current_session.phase == &"playing" or current_session.phase == &"score_lock" or current_session.phase == &"results"):
		_clear_flow_views()
	elif current_session and current_session.phase == &"lobby" and current_lobby == null:
		_show_lobby(current_session)

func _on_session_event(_message: String) -> void:
	_update_lobby()

func _on_create_room(room_name: String) -> void:
	var session := _start_session()
	if session.host_room(room_name):
		_show_lobby(session)

func _on_browse_rooms() -> void:
	var session := _start_session()
	session.phase = &"lobby"
	session.phase_changed.emit(session.phase)
	_show_browser()

func _on_join_ip(host_ip: String) -> void:
	var session := _start_session()
	if session.join_room(host_ip):
		_show_lobby(session)

func _on_join_room(room: Dictionary) -> void:
	var session := _start_session()
	var host_ip := String(room.get("host_ip", ""))
	var host_port := int(room.get("game_port", -1))
	if session.join_room(host_ip, host_port):
		_show_lobby(session)

func _bind_network_signals() -> void:
	if _network_manager == null or _network_signals_bound:
		return
	_network_manager.lobby_changed.connect(_on_network_lobby_changed)
	_network_manager.room_closed.connect(_on_network_room_closed)
	_network_manager.room_list_changed.connect(_on_network_room_list_changed)
	_network_signals_bound = true

func _on_network_room_list_changed(rooms: Array) -> void:
	if current_browser:
		current_browser.show_rooms(rooms)


func _on_lobby_start() -> void:
	if current_session:
		if _network_manager != null and _network_manager.has_connection():
			_network_manager.request_match_start()
		else:
			current_session.begin_countdown()

func _on_team_requested(team: int) -> void:
	if _network_manager != null and _network_manager.has_connection():
		_network_manager.request_team_change(team)
		return
	if current_session and current_session.players.has(1):
		var player: IslandPlayer = current_session.players[1]
		player.team = team
		_update_lobby()

func _on_map_requested(map_id: StringName) -> void:
	if current_session == null:
		return
	if _network_manager != null and _network_manager.has_connection() and not _network_manager.is_host():
		return
	if current_session.select_map(map_id):
		_update_lobby()
