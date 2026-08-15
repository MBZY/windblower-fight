extends Node

const GAME_SESSION := preload("res://scenes/game/game_session.tscn")
const MAIN_MENU := preload("res://scenes/main/main_menu.tscn")
const ROOM_BROWSER := preload("res://scenes/ui/room_browser.tscn")
const LOBBY := preload("res://scenes/ui/lobby.tscn")

@onready var menu_bgm: AudioStreamPlayer = $MenuBgm
@onready var lobby_bgm: AudioStreamPlayer = $LobbyBgm
@onready var match_bgm: AudioStreamPlayer = $MatchBgm
@onready var ui_confirm_sfx: AudioStreamPlayer = $UiConfirmSfx
@onready var ui_back_sfx: AudioStreamPlayer = $UiBackSfx
@onready var ui_team_sfx: AudioStreamPlayer = $UiTeamSfx
@onready var ui_error_sfx: AudioStreamPlayer = $UiErrorSfx
@onready var system_notice: Control = %SystemNotice
@onready var system_notice_title: Label = %SystemNoticeTitle
@onready var system_notice_message: Label = %SystemNoticeMessage

var current_session: GameSession
var current_menu: MainMenu
var current_browser: RoomBrowser
var current_lobby: LobbyView
var _network_manager: NetworkManager
var _current_bgm: AudioStreamPlayer
var _bgm_tween: Tween
var _bgm_base_volumes: Dictionary = {}
var _match_playlist: Array[AudioStreamPlayer] = []
var _match_playlist_index := 0
var _match_playlist_active := false
var _suppress_disconnect_notice := false

func _ready() -> void:
	_network_manager = get_node_or_null("NetworkManager") as NetworkManager
	_bgm_base_volumes = {
		menu_bgm: menu_bgm.volume_db,
		lobby_bgm: lobby_bgm.volume_db,
		match_bgm: match_bgm.volume_db,
	}
	_match_playlist = [match_bgm, menu_bgm, lobby_bgm]
	show_menu()

func show_menu() -> void:
	_match_playlist_active = false
	_switch_bgm(menu_bgm)
	_hide_system_notice()
	_clear_flow_views()
	if current_session:
		_suppress_disconnect_notice = true
		current_session.leave_room()
		_suppress_disconnect_notice = false
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
	current_menu.profile_submitted.connect(_on_profile_submitted)
	current_menu.fashion_changed.connect(_on_fashion_changed)
	_on_profile_submitted(current_menu.profile_name())
	_on_fashion_changed(current_menu.fashion_loadout())


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
	current_session.return_to_menu_requested.connect(_on_session_return_to_menu_requested)
	return current_session

func _show_browser() -> void:
	_match_playlist_active = false
	_switch_bgm(menu_bgm)
	_clear_flow_views()
	if current_menu:
		if current_menu.get_parent() == self:
			remove_child(current_menu)
		current_menu.queue_free()
		current_menu = null
	current_browser = ROOM_BROWSER.instantiate()
	add_child(current_browser)
	current_browser.back_requested.connect(_on_browser_back)
	current_browser.refresh_requested.connect(_on_browser_refresh)
	current_browser.join_ip_requested.connect(_on_join_ip)
	current_browser.join_room_requested.connect(_on_join_room)
	_refresh_rooms()

func _show_lobby(session: GameSession) -> void:
	_match_playlist_active = false
	_switch_bgm(lobby_bgm)
	_clear_flow_views()
	current_lobby = LOBBY.instantiate()
	add_child(current_lobby)
	current_lobby.set_host(_network_manager == null or _network_manager.is_host())
	current_lobby.leave_requested.connect(_on_lobby_leave)
	current_lobby.start_requested.connect(_on_lobby_start)
	current_lobby.team_requested.connect(_on_team_requested)
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
	current_lobby.set_room_snapshot({"room_name": "鼓风机大乱斗房间", "state": String(current_session.phase)}, roster)

func _on_network_lobby_changed(_snapshot: Dictionary) -> void:
	_update_lobby()

func _on_network_room_closed(reason: String) -> void:
	if _suppress_disconnect_notice or reason == "left_room":
		return
	if current_session != null:
		current_session.set_local_input_blocked(true)
	ui_error_sfx.play()
	HapticFeedback.alert()
	_show_system_notice("连接已中断", _connection_message(reason))

func _on_session_phase_changed(next_phase: StringName) -> void:
	if next_phase == &"lobby":
		_match_playlist_active = false
		_switch_bgm(lobby_bgm)
	elif next_phase == &"countdown" or next_phase == &"playing" or next_phase == &"score_lock" or next_phase == &"results":
		if not _match_playlist_active:
			_match_playlist_active = true
			_match_playlist_index = 0
			_switch_bgm(_match_playlist[_match_playlist_index])
	if current_session and (current_session.phase == &"countdown" or current_session.phase == &"playing" or current_session.phase == &"score_lock" or current_session.phase == &"results"):
		_clear_flow_views()
	elif current_session and current_session.phase == &"lobby" and current_lobby == null:
		_show_lobby(current_session)

func _on_session_event(_message: String) -> void:
	_update_lobby()

func _on_create_room(room_name: String) -> void:
	var session := _start_session()
	if session.host_room(room_name):
		ui_confirm_sfx.play()
		_show_lobby(session)
	else:
		ui_error_sfx.play()

func _on_browse_rooms() -> void:
	ui_confirm_sfx.play()
	var session := _start_session()
	session.phase = &"lobby"
	session.phase_changed.emit(session.phase)
	_show_browser()

func _on_join_ip(host_ip: String) -> void:
	var endpoint := _parse_host_endpoint(host_ip)
	if endpoint.is_empty():
		ui_error_sfx.play()
		return
	var session := _start_session()
	if session.join_room(String(endpoint.get("host", "")), int(endpoint.get("port", -1))):
		ui_confirm_sfx.play()
		_show_lobby(session)
	else:
		ui_error_sfx.play()

func _parse_host_endpoint(value: String) -> Dictionary:
	var endpoint := value.strip_edges()
	if endpoint.is_empty():
		return {}

	var host := endpoint
	var port := -1
	if endpoint.begins_with("["):
		var bracket_end := endpoint.find("]")
		if bracket_end <= 1:
			return {}
		host = endpoint.substr(1, bracket_end - 1).strip_edges()
		var suffix := endpoint.substr(bracket_end + 1)
		if not suffix.is_empty():
			if not suffix.begins_with(":"):
				return {}
			var port_text := suffix.substr(1)
			if not port_text.is_valid_int():
				return {}
			port = int(port_text)
	elif endpoint.count(":") == 1:
		var separator := endpoint.rfind(":")
		var port_text := endpoint.substr(separator + 1)
		if not port_text.is_valid_int():
			return {}
		host = endpoint.substr(0, separator).strip_edges()
		port = int(port_text)

	if host.is_empty() or (port != -1 and (port < 1 or port > 65535)):
		return {}
	return {"host": host, "port": port}

func _on_profile_submitted(display_name: String) -> void:
	if _network_manager != null:
		_network_manager.set_local_profile(display_name)

func _on_fashion_changed(loadout: Dictionary) -> void:
	if _network_manager != null:
		_network_manager.set_local_fashion(loadout)

func _on_join_room(room: Dictionary) -> void:
	var session := _start_session()
	var host_ip := String(room.get("host_ip", ""))
	var host_port := int(room.get("game_port", -1))
	if session.join_room(host_ip, host_port):
		ui_confirm_sfx.play()
		_show_lobby(session)
	else:
		ui_error_sfx.play()

func _on_network_room_list_changed(rooms: Array) -> void:
	if current_browser:
		current_browser.show_rooms(rooms)


func _on_lobby_start() -> void:
	if current_session:
		ui_confirm_sfx.play()
		if _network_manager != null and _network_manager.has_connection():
			_network_manager.request_match_start()
		else:
			current_session.begin_countdown()

func _on_team_requested(team: int) -> void:
	ui_team_sfx.play()
	if _network_manager != null and _network_manager.has_connection():
		_network_manager.request_team_change(team)
		return
	if current_session and current_session.players.has(1):
		var player: IslandPlayer = current_session.players[1]
		player.team = team
		_update_lobby()

func _on_browser_back() -> void:
	ui_back_sfx.play()
	show_menu()

func _on_browser_refresh() -> void:
	ui_confirm_sfx.play()
	_refresh_rooms()

func _on_lobby_leave() -> void:
	ui_back_sfx.play()
	show_menu()

func _on_session_return_to_menu_requested() -> void:
	ui_back_sfx.play()
	show_menu()

func _on_network_connection_failed(reason: String) -> void:
	if _suppress_disconnect_notice:
		return
	if current_session != null:
		current_session.set_local_input_blocked(true)
	ui_error_sfx.play()
	HapticFeedback.alert()
	_show_system_notice("无法连接", _connection_message(reason))

func _show_system_notice(title: String, message: String) -> void:
	if system_notice == null:
		return
	system_notice_title.text = title
	system_notice_message.text = message
	system_notice.visible = true

func _hide_system_notice() -> void:
	if system_notice != null:
		system_notice.visible = false

func _on_system_notice_return_pressed() -> void:
	HapticFeedback.light()
	show_menu()

func _connection_message(reason: String) -> String:
	match reason:
		"host_disconnected":
			return "与主机的连接已断开，本局已停止。"
		"ENet connection failed":
			return "无法连接到主机，请检查 IP、端口和网络状态。"
		_:
			if reason.contains("listen for LAN rooms"):
				return "无法搜索局域网房间，请检查网络权限后重试。"
			if reason.contains("host ENet"):
				return "创建房间失败，端口可能被其他程序占用。"
			if reason.contains("connect"):
				return "连接失败，请检查 IP、端口和网络状态。"
	return "网络连接出现问题，请返回首页后重试。"

func _switch_bgm(next_bgm: AudioStreamPlayer) -> void:
	if next_bgm == null:
		return
	if _current_bgm == next_bgm:
		if not next_bgm.playing:
			next_bgm.play()
		return
	if _bgm_tween != null:
		_bgm_tween.kill()
	var previous := _current_bgm
	_current_bgm = next_bgm
	var target_volume := float(_bgm_base_volumes.get(next_bgm, next_bgm.volume_db))
	next_bgm.volume_db = -36.0
	next_bgm.play()
	_bgm_tween = create_tween().set_parallel(true)
	_bgm_tween.tween_property(next_bgm, "volume_db", target_volume, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if previous != null:
		var previous_volume := float(_bgm_base_volumes.get(previous, previous.volume_db))
		_bgm_tween.tween_property(previous, "volume_db", -36.0, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_bgm_tween.chain().tween_callback(func() -> void:
			if previous != _current_bgm:
				previous.stop()
			previous.volume_db = previous_volume
		)

func _replay_bgm(player: AudioStreamPlayer) -> void:
	if _match_playlist_active:
		_advance_match_bgm()
		return
	if player == _current_bgm:
		player.play()

func _advance_match_bgm() -> void:
	if _match_playlist.is_empty():
		return
	_match_playlist_index = (_match_playlist_index + 1) % _match_playlist.size()
	_switch_bgm(_match_playlist[_match_playlist_index])

func _on_menu_bgm_finished() -> void:
	_replay_bgm(menu_bgm)

func _on_lobby_bgm_finished() -> void:
	_replay_bgm(lobby_bgm)

func _on_match_bgm_finished() -> void:
	_replay_bgm(match_bgm)
