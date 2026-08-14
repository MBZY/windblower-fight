class_name GameSession
extends Node2D

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

signal phase_changed(phase: StringName)
signal score_changed(red_score: int, blue_score: int)
signal skill_points_changed(player_id: int, points: int)
signal countdown_changed(seconds_left: int)
signal match_finished(winner_team: int, red_score: int, blue_score: int)
signal event_announced(message: String)

@export var balance: BalanceConfig
@export var map_definition: MapDefinition
@export var enhancement_catalog: EnhancementCatalog
@export var auto_start_single_player: bool = true

@onready var countdown_timer: Timer = %CountdownTimer
@onready var match_timer: Timer = %MatchTimer
@onready var respawn_timer: Timer = %RespawnTimer
@onready var score_lock_timer: Timer = %ScoreLockTimer
@onready var hud: Control = %GameHUD
@onready var red_player: IslandPlayer = %RedPlayer
@onready var blue_player: IslandPlayer = %BluePlayer
@onready var network_players: Node2D = $NetworkPlayers
@onready var map_medium: Node2D = $MapMedium
@onready var map_small: Node2D = $MapSmall
@onready var map_large: Node2D = $MapLarge

var phase: StringName = &"menu"
var red_score: int = 0
var blue_score: int = 0
var players: Dictionary = {}
var _pending_respawn: Dictionary = {}
var _score_locked: bool = false
var _enet_peer: ENetMultiplayerPeer
var _spawn_accumulator: float = 0.0
var _network_ready: bool = false
var _network_tick: int = 0
var _remote_inputs: Dictionary = {}
var _network_manager: NetworkManager
var _results_return_generation := 0
var _network_state_accumulator := 0.0
var _network_sync_due := false
var _map_revision := 1
var _last_fall_attacker: Dictionary = {}

func _ready() -> void:
	if balance == null:
		balance = BalanceConfig.new()
	if map_definition == null:
		map_definition = MapDefinition.new()
	if enhancement_catalog == null:
		enhancement_catalog = EnhancementCatalog.new()
	if enhancement_catalog.entries.is_empty():
		var catalog_resource := load("res://resources/enhancements/catalog.tres")
		if catalog_resource is EnhancementCatalog:
			enhancement_catalog = catalog_resource
	_network_manager = get_node_or_null("../NetworkManager") as NetworkManager
	if _network_manager != null:
		_network_manager.configure_from_balance(balance)
		_network_manager.host_input_received.connect(_on_network_input_received)
		_network_manager.host_start_requested.connect(_on_network_start_requested)
		_network_manager.host_action_requested.connect(_on_network_action_requested)
		_network_manager.match_phase_changed.connect(_on_network_phase_received)
		_network_manager.player_state_snapshot_received.connect(_on_network_state_received)
		_network_manager.match_event_received.connect(_on_network_match_event)
		_network_manager.lobby_changed.connect(_on_network_lobby_snapshot)
		_network_manager.peer_joined.connect(_on_network_peer_joined)
		_network_manager.peer_left.connect(_on_network_peer_left)
		_network_ready = true
	_apply_map_definition()
	register_player(red_player)
	register_player(blue_player)
	blue_player.set_active_in_match(false)
	_refresh_local_views()
	hud.bind_session(self)
	_set_hud_visible(false)
	if auto_start_single_player:
		start_match()
	else:
		phase = &"lobby"
		phase_changed.emit(phase)
		if _network_ready and _network_manager != null and _network_manager.is_host():
			_on_network_lobby_snapshot(_network_manager.lobby_snapshot())

func _exit_tree() -> void:
	_results_return_generation += 1

func _process(delta: float) -> void:
	if phase == &"playing":
		var network_connected := _network_ready and _network_manager != null and _network_manager.has_connection()
		if network_connected and not _network_manager.is_host():
			var local_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
			_network_manager.submit_local_input(local_input, local_input)
			return
		_network_sync_due = false
		if network_connected and _network_manager.is_host():
			var host_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
			_network_manager.submit_local_input(host_input, host_input)
			_network_state_accumulator += delta
			var state_interval := 1.0 / maxf(balance.network_state_hz, 1.0)
			if _network_state_accumulator >= state_interval:
				_network_state_accumulator = fmod(_network_state_accumulator, state_interval)
				_network_sync_due = true
		_check_player_bounds()
		_apply_players_wind()
		if network_connected and _network_sync_due:
			_network_tick += 1
			_publish_network_state()

func _check_player_bounds() -> void:
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		if player.is_active_in_match and not player.is_respawning and not map_definition.island_rect.grow(4.0).has_point(player.global_position):
			player.mark_fallen(player.last_attacker_id)

func host_room(room_title: String = "Sky Leaf Room", map_id: String = "medium") -> bool:
	select_map(StringName(map_id))
	if _network_ready:
		var network_error := _network_manager.host_room(room_title, StringName(map_id), 8, _map_revision)
		if network_error != OK:
			return false
		phase = &"lobby"
		phase_changed.emit(phase)
		return true
	_enet_peer = ENetMultiplayerPeer.new()
	var error := _enet_peer.create_server(balance.game_port, 8)
	if error != OK:
		event_announced.emit("Unable to host on port %d" % balance.game_port)
		return false
	multiplayer.multiplayer_peer = _enet_peer
	phase = &"lobby"
	phase_changed.emit(phase)
	return true

func join_room(host_ip: String, host_port: int = -1) -> bool:
	if _network_ready:
		var target_port := balance.game_port if host_port < 1 else host_port
		var network_error := _network_manager.join_room(host_ip, target_port)
		if network_error != OK:
			event_announced.emit("Unable to join %s" % host_ip)
			return false
		phase = &"lobby"
		phase_changed.emit(phase)
		return true
	_enet_peer = ENetMultiplayerPeer.new()
	var error := _enet_peer.create_client(host_ip, balance.game_port)
	if error != OK:
		event_announced.emit("Unable to join %s" % host_ip)
		return false
	multiplayer.multiplayer_peer = _enet_peer
	phase = &"lobby"
	phase_changed.emit(phase)
	return true

func select_map(map_id: StringName) -> bool:
	if phase != &"menu" and phase != &"lobby":
		return false
	if _network_ready and _network_manager != null and _network_manager.has_connection() and not _network_manager.is_host():
		return false
	var map_path := "res://resources/maps/%s.tres" % String(map_id)
	var selected := load(map_path) as MapDefinition
	if selected == null:
		return false
	if selected.map_id == map_definition.map_id:
		if _network_ready and _network_manager != null and _network_manager.is_host():
			_network_manager.host_set_map(map_definition.map_id, _map_revision)
		return true
	map_definition = selected
	_map_revision += 1
	if is_node_ready():
		_apply_map_definition()
	if _network_ready and _network_manager != null and _network_manager.is_host():
		_network_manager.host_set_map(map_definition.map_id, _map_revision)
	return true

func _apply_map_definition() -> void:
	red_player.position = map_definition.red_spawn
	blue_player.position = map_definition.blue_spawn
	map_medium.visible = map_definition.map_id == &"medium"
	map_small.visible = map_definition.map_id == &"small"
	map_large.visible = map_definition.map_id == &"large"
	map_medium.get_node("FallBoundary").monitoring = map_medium.visible
	map_small.get_node("FallBoundary").monitoring = map_small.visible
	map_large.get_node("FallBoundary").monitoring = map_large.visible

func _with_map_revision(payload: Dictionary) -> Dictionary:
	var result := payload.duplicate(true)
	result["map_revision"] = _map_revision
	return result

func _has_current_map_revision(payload: Dictionary) -> bool:
	return int(payload.get("map_revision", -1)) == _map_revision

func begin_countdown() -> void:
	if _network_ready and _network_manager.is_host():
		_network_manager.host_set_match_phase(&"countdown", {"seconds": balance.countdown_sec})
		_start_countdown_local()
		return
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		_start_countdown_local()

func leave_room() -> void:
	if _network_ready and _network_manager.has_connection():
		_network_manager.leave_room()
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	phase = &"menu"
	phase_changed.emit(phase)

func start_match() -> void:
	if phase == &"playing" or phase == &"countdown":
		return
	phase = &"countdown"
	_set_hud_visible(true)
	countdown_timer.start(balance.countdown_sec)
	countdown_changed.emit(ceili(balance.countdown_sec))
	phase_changed.emit(phase)
	if _network_ready and _network_manager.is_host():
		_network_manager.host_set_match_phase(&"countdown", {"seconds": balance.countdown_sec})

func _start_countdown_local() -> void:
	phase = &"countdown"
	_set_hud_visible(true)
	countdown_timer.start(balance.countdown_sec)
	countdown_changed.emit(ceili(balance.countdown_sec))
	phase_changed.emit(phase)

func _on_network_start_requested(_peer_id: int) -> void:
	if _network_manager != null and _network_manager.is_host():
		begin_countdown()

func _on_network_input_received(peer_id: int, movement: Vector2, aim: Vector2) -> void:
	_remote_inputs[peer_id] = {"movement": movement, "aim": aim}
	if players.has(peer_id) and players[peer_id].is_active_in_match:
		players[peer_id].set_input(movement)

func _on_network_action_requested(peer_id: int, action: StringName, payload: Dictionary) -> void:
	match action:
		&"skill_upgrade":
			request_skill_upgrade(peer_id, StringName(payload.get("entry_id", "")))

func _on_network_phase_received(network_phase: StringName, payload: Dictionary) -> void:
	if _network_manager != null and _network_manager.is_host():
		return
	phase = network_phase
	match network_phase:
		&"countdown":
			_reset_match_state()
			countdown_timer.start(float(payload.get("seconds", balance.countdown_sec)))
			_set_hud_visible(true)
		&"playing":
			match_timer.stop()
			_activate_lobby_players()
			_set_hud_visible(true)
		&"score_lock":
			_score_locked = true
		&"results":
			red_score = int(payload.get("red_score", red_score))
			blue_score = int(payload.get("blue_score", blue_score))
			score_changed.emit(red_score, blue_score)
			match_finished.emit(int(payload.get("winner_team", -1)), red_score, blue_score)
			_schedule_return_to_lobby()
		&"lobby":
			_score_locked = false
			_set_hud_visible(false)
			for player_variant in players.values():
				var player: IslandPlayer = player_variant
				player.set_active_in_match(false)
	phase_changed.emit(phase)

func _on_network_lobby_snapshot(snapshot: Dictionary) -> void:
	var room: Dictionary = snapshot.get("room", {})
	var map_id := StringName(String(room.get("map_id", map_definition.map_id)))
	var map_revision := maxi(int(room.get("map_revision", _map_revision)), 0)
	var revision_changed := map_revision != _map_revision
	_map_revision = map_revision
	if map_id != map_definition.map_id or revision_changed:
		_apply_network_map(map_id)
	var active_player_ids: Dictionary = {}
	var should_activate := phase == &"playing" or phase == &"score_lock"
	for player_variant in Array(snapshot.get("players", [])):
		if not (player_variant is Dictionary):
			continue
		var player_data: Dictionary = player_variant
		var player_id := int(player_data.get("peer_id", 0))
		var player := _ensure_network_player(player_id, int(player_data.get("team", 0)))
		if player == null:
			continue
		active_player_ids[player_id] = true
		player.set_active_in_match(should_activate)
		if players.has(player_id):
			players[player_id].team = int(player_data.get("team", players[player_id].team))
	for player_id_variant in players.keys():
		var player_id := int(player_id_variant)
		if not active_player_ids.has(player_id):
			var inactive_player: IslandPlayer = players[player_id]
			inactive_player.set_active_in_match(false)
	_refresh_local_views()

func _apply_network_map(map_id: StringName) -> void:
	var map_path := "res://resources/maps/%s.tres" % String(map_id)
	var selected := load(map_path) as MapDefinition
	if selected == null:
		return
	map_definition = selected
	if is_node_ready():
		_apply_map_definition()

func _on_network_peer_joined(peer_id: int, player_data: Dictionary) -> void:
	var player := _ensure_network_player(peer_id, int(player_data.get("team", 1)))
	if player != null:
		player.set_active_in_match(phase == &"playing" or phase == &"score_lock")

func _on_network_peer_left(peer_id: int) -> void:
	if not players.has(peer_id):
		return
	var player: IslandPlayer = players[peer_id]
	if peer_id <= 2:
		player.set_active_in_match(false)
		return
	players.erase(peer_id)
	if is_instance_valid(player):
		player.queue_free()

func _ensure_network_player(peer_id: int, team: int) -> IslandPlayer:
	if peer_id <= 0:
		return null
	if players.has(peer_id):
		return players[peer_id]
	var player := PLAYER_SCENE.instantiate() as IslandPlayer
	if player == null:
		return null
	player.player_id = peer_id
	player.team = team
	player.is_host_authority = _network_manager != null and _network_manager.is_host()
	player.global_position = map_definition.red_spawn if team == 0 else map_definition.blue_spawn
	network_players.add_child(player)
	register_player(player)
	_refresh_local_views()
	return player

func _on_network_state_received(snapshot: Dictionary, _server_tick: int) -> void:
	if _network_manager != null and _network_manager.is_host():
		return
	var next_red_score := int(snapshot.get("red_score", red_score))
	var next_blue_score := int(snapshot.get("blue_score", blue_score))
	if next_red_score != red_score or next_blue_score != blue_score:
		red_score = next_red_score
		blue_score = next_blue_score
		score_changed.emit(red_score, blue_score)
	for player_variant in snapshot.get("players", []):
		if not (player_variant is Dictionary):
			continue
		var player_data: Dictionary = player_variant
		var player_id := int(player_data.get("player_id", 0))
		var player := _ensure_network_player(player_id, int(player_data.get("team", 0)))
		if player == null:
			continue
		player.set_network_position(Vector2(player_data.get("position", player.global_position)))
		player.team = int(player_data.get("team", player.team))
		player.is_respawning = bool(player_data.get("respawning", player.is_respawning))
		player.invulnerability_time = float(player_data.get("invulnerability", player.invulnerability_time))
		player.fall_count = int(player_data.get("fall_count", player.fall_count))
		var stacks: Variant = player_data.get("enhancement_stacks", player.enhancement_stacks)
		if stacks is Dictionary:
			player.enhancement_stacks = stacks.duplicate(true)
		var points := int(player_data.get("skill_points", player.skill_points))
		if player.skill_points != points:
			player.skill_points = points
			skill_points_changed.emit(player_id, points)

func _on_network_match_event(event_name: StringName, payload: Dictionary) -> void:
	if _network_manager != null and _network_manager.is_host():
		return
	match event_name:
		&"player_fell":
			if not _has_current_map_revision(payload):
				return
			var victim_id := int(payload.get("victim_id", 0))
			var attacker_id := int(payload.get("attacker_id", 0))
			_apply_fall_scoring(victim_id, attacker_id)
			_schedule_respawn_for(victim_id)
			event_announced.emit("Player %d was blown off!" % victim_id)
		&"skill_upgraded":
			if not _has_current_map_revision(payload):
				return
			var target_id := int(payload.get("player_id", 0))
			var entry_id := StringName(String(payload.get("entry_id", "")))
			if players.has(target_id):
				var entry := _entry_from_id(entry_id)
				if entry != null:
					players[target_id].apply_skill(entry, 0)

func _entry_from_id(entry_id: StringName) -> EnhancementEntry:
	for entry_variant in enhancement_catalog.entries:
		var entry := entry_variant as EnhancementEntry
		if entry != null and entry.id == entry_id:
			return entry
	return null

func _publish_network_state() -> void:
	var state: Array[Dictionary] = []
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		if player.is_active_in_match:
			state.append({"player_id": player.player_id, "position": player.global_position, "team": player.team, "respawning": player.is_respawning, "invulnerability": player.invulnerability_time, "coins": player.skill_points, "fall_count": player.fall_count, "enhancement_stacks": player.enhancement_stacks.duplicate(true), "skill_points": player.skill_points})
	_network_manager.host_publish_player_state({"players": state, "red_score": red_score, "blue_score": blue_score, "phase": String(phase)}, _network_tick)

func _on_countdown_timeout() -> void:
	var network_connected := _network_ready and _network_manager != null and _network_manager.has_connection()
	if network_connected and not _network_manager.is_host():
		return
	phase = &"playing"
	_set_hud_visible(true)
	_reset_match_state()
	_activate_lobby_players()
	match_timer.start(balance.match_duration_sec)
	phase_changed.emit(phase)
	if network_connected:
		_network_manager.host_set_match_phase(&"playing")

func _on_beacon_timeout() -> void:
	return

func _activate_lobby_players() -> void:
	if _network_ready and _network_manager != null and _network_manager.has_connection():
		for player_id_variant in _network_manager.get_lobby_players().keys():
			var player_id := int(player_id_variant)
			if players.has(player_id):
				players[player_id].set_active_in_match(true)
		_refresh_local_views()
		return
	if players.has(1):
		players[1].set_active_in_match(true)
	if players.has(2):
		players[2].set_active_in_match(false)
	_refresh_local_views()

func _refresh_local_views() -> void:
	var local_player_id := 1
	if _network_ready and _network_manager != null and _network_manager.has_connection():
		local_player_id = _network_manager.local_peer_id()
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		player.set_local_view(player.player_id == local_player_id)

func _apply_players_wind() -> void:
	for player_id in players:
		var player: IslandPlayer = players[player_id]
		if not player.is_active_in_match or player.is_respawning:
			continue
		for other_id in players:
			if other_id == player_id:
				continue
			var other: IslandPlayer = players[other_id]
			if not other.is_active_in_match or other.is_respawning or other.invulnerability_time > 0.0:
				continue
			if not player.affects_point(other.global_position):
				continue
			other.last_attacker_id = player.player_id
			other.velocity += player.wind_at(other.global_position) * (player.push_force / maxf(player.wind_force, 1.0)) * 0.02
			if not map_definition.island_rect.has_point(other.global_position):
				other.mark_fallen(player.player_id)

func _on_match_timeout() -> void:
	if _network_ready and _network_manager != null and _network_manager.has_connection() and not _network_manager.is_host():
		return
	_score_locked = true
	phase = &"score_lock"
	score_lock_timer.start(balance.score_lock_sec)
	phase_changed.emit(phase)
	if _network_ready and _network_manager != null and _network_manager.is_host():
		_network_manager.host_set_match_phase(&"score_lock")

func _on_score_lock_timeout() -> void:
	if _network_ready and _network_manager != null and _network_manager.has_connection() and not _network_manager.is_host():
		return
	phase = &"results"
	var winner := -1 if red_score == blue_score else (0 if red_score > blue_score else 1)
	match_finished.emit(winner, red_score, blue_score)
	phase_changed.emit(phase)
	if _network_ready and _network_manager != null and _network_manager.is_host():
		_network_manager.host_set_match_phase(&"results", {"winner_team": winner, "red_score": red_score, "blue_score": blue_score})
	_schedule_return_to_lobby()

func _schedule_return_to_lobby() -> void:
	_results_return_generation += 1
	var generation := _results_return_generation
	get_tree().create_timer(3.0).timeout.connect(_return_to_lobby.bind(generation))

func _return_to_lobby(generation: int) -> void:
	if generation != _results_return_generation or phase != &"results":
		return
	phase = &"lobby"
	_score_locked = false
	_set_hud_visible(false)
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		player.set_active_in_match(false)
	phase_changed.emit(phase)
	if _network_ready and _network_manager != null and _network_manager.is_host():
		_network_manager.host_set_match_phase(&"lobby")

func register_player(player: IslandPlayer) -> void:
	players[player.player_id] = player

func _on_player_fell(player_id: int, fall_count: int) -> void:
	if _network_ready and _network_manager != null and _network_manager.has_connection() and not _network_manager.is_host():
		return
	if _score_locked:
		return
	var attacker_id := 0
	var victim: IslandPlayer = players.get(player_id)
	if victim != null:
		attacker_id = victim.last_attacker_id
	_apply_fall_scoring(player_id, attacker_id)
	if _network_ready and _network_manager != null and _network_manager.has_connection() and _network_manager.is_host():
		_network_manager.host_publish_match_event(&"player_fell", _with_map_revision({"victim_id": player_id, "attacker_id": attacker_id}))
	_schedule_respawn_for(player_id)
	event_announced.emit("Player %d was blown off!" % player_id)

func _apply_fall_scoring(victim_id: int, attacker_id: int) -> void:
	if _last_fall_attacker.has(victim_id):
		return
	_last_fall_attacker[victim_id] = true
	var scored_team := 0
	var scorer_id := 0
	if attacker_id > 0 and players.has(attacker_id):
		scorer_id = attacker_id
		scored_team = players[attacker_id].team
		players[attacker_id].add_skill_points(balance.skill_points_per_fall)
		skill_points_changed.emit(attacker_id, players[attacker_id].skill_points)
	else:
		var victim: IslandPlayer = players.get(victim_id)
		scored_team = 0 if victim == null or victim.team == 1 else 1
	if scored_team == 0:
		red_score += 1
	else:
		blue_score += 1
	score_changed.emit(red_score, blue_score)
	if scorer_id > 0:
		event_announced.emit("Player %d scored!" % scorer_id)

func _schedule_respawn_for(player_id: int) -> void:
	var player: IslandPlayer = players.get(player_id)
	if player == null:
		return
	var wait := minf(balance.respawn_max_sec, balance.respawn_base_sec + balance.respawn_increment_sec * maxi(player.fall_count - 1, 0))
	_pending_respawn[player_id] = Time.get_ticks_msec() + int(wait * 1000.0)
	_schedule_next_respawn()

func _on_respawn_timeout() -> void:
	var now := Time.get_ticks_msec()
	for player_id in _pending_respawn.keys().duplicate():
		if now < int(_pending_respawn[player_id]):
			continue
		var player: IslandPlayer = players.get(player_id)
		if player:
			var spawn := map_definition.red_spawn if player.team == 0 else map_definition.blue_spawn
			player.respawn(spawn, balance.respawn_invulnerability_sec)
			event_announced.emit("Player %d respawned" % player_id)
		_pending_respawn.erase(player_id)
	_schedule_next_respawn()

func _schedule_next_respawn() -> void:
	if _pending_respawn.is_empty():
		return
	var now := Time.get_ticks_msec()
	var next_due: int = -1
	for due_variant in _pending_respawn.values():
		var due := int(due_variant)
		if next_due < 0 or due < next_due:
			next_due = due
	respawn_timer.start(maxf(0.01, float(next_due - now) / 1000.0))

func _set_hud_visible(value: bool) -> void:
	if hud != null:
		hud.visible = value

func request_skill_upgrade(player_id: int, entry_id: StringName) -> Dictionary:
	if _network_ready and _network_manager != null and _network_manager.has_connection() and not _network_manager.is_host():
		_network_manager.request_game_action(&"skill_upgrade", {"entry_id": String(entry_id)})
		return {"ok": true, "pending": true}
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return {"ok": false, "reason": "host_only"}
	if not players.has(player_id):
		return {"ok": false, "reason": "unknown_player"}
	var player: IslandPlayer = players[player_id]
	var entry := _entry_from_id(entry_id)
	if entry == null:
		return {"ok": false, "reason": "unknown_entry"}
	if not player.apply_skill(entry, balance.skill_upgrade_price):
		return {"ok": false, "reason": "cannot_upgrade"}
	skill_points_changed.emit(player_id, player.skill_points)
	if _network_ready and _network_manager != null and _network_manager.is_host():
		_network_manager.host_publish_match_event(&"skill_upgraded", _with_map_revision({"player_id": player_id, "entry_id": String(entry_id)}))
	return {"ok": true}

func _reset_match_state() -> void:
	red_score = 0
	blue_score = 0
	_score_locked = false
	_spawn_accumulator = 0.0
	_network_state_accumulator = 0.0
	_network_sync_due = false
	_pending_respawn.clear()
	_last_fall_attacker.clear()
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		var spawn := map_definition.red_spawn if player.team == 0 else map_definition.blue_spawn
		player.reset_match_state(spawn)
		skill_points_changed.emit(player.player_id, player.skill_points)
	score_changed.emit(red_score, blue_score)
