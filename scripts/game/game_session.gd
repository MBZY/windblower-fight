class_name GameSession
extends Node2D

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")
const MAP_SCENES := {
	&"small": preload("res://scenes/game/map_small.tscn"),
	&"medium": preload("res://scenes/game/map_medium.tscn"),
	&"large": preload("res://scenes/game/map_large.tscn"),
}

signal phase_changed(phase: StringName)
signal score_changed(red_score: int, blue_score: int)
signal skill_points_changed(player_id: int, points: int)
signal countdown_changed(seconds_left: int)
signal respawn_countdown_started(player_id: int, seconds: float)
signal player_respawned(player_id: int)
signal match_finished(winner_team: int, red_score: int, blue_score: int)
signal event_announced(message: String)
signal player_eliminated(killer_id: int, victim_id: int, reward: int)
signal return_to_menu_requested

@export var balance: BalanceConfig
@export var map_definition: MapDefinition
@export var enhancement_catalog: EnhancementCatalog
@export var auto_start_single_player: bool = true

@onready var countdown_timer: Timer = %CountdownTimer
@onready var match_timer: Timer = %MatchTimer
@onready var respawn_timer: Timer = %RespawnTimer
@onready var score_lock_timer: Timer = %ScoreLockTimer
@onready var hud: Control = $CanvasLayer/Control
@onready var map_root: Node2D = $MapRoot
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var network_players: Node2D = $NetworkPlayers
@onready var countdown_camera: Camera2D = $CountdownCamera
@onready var ambient_wind_sfx: AudioStreamPlayer = %AmbientWindSfx

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
var _current_map: Node2D
var _current_map_id: StringName = &""
var _island_polygon: PackedVector2Array = PackedVector2Array()
var _spawn_rng := RandomNumberGenerator.new()
var _network_match_time_left := 0.0
var _local_input_blocked := false
var _player_fashion_cache: Dictionary = {}

func _ready() -> void:
	_spawn_rng.randomize()
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
	player_spawner.spawn_function = _spawn_player_node
	player_spawner.spawned.connect(_on_player_spawned)
	_apply_map_definition()
	if auto_start_single_player:
		_ensure_local_players()
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

func _on_audio_phase_changed(next_phase: StringName) -> void:
	var should_play := next_phase == &"countdown" or next_phase == &"playing" or next_phase == &"score_lock"
	if should_play:
		if not ambient_wind_sfx.playing:
			ambient_wind_sfx.play()
	elif ambient_wind_sfx.playing:
		ambient_wind_sfx.stop()

func _on_ambient_wind_finished() -> void:
	if phase == &"countdown" or phase == &"playing" or phase == &"score_lock":
		ambient_wind_sfx.play()

func _process(delta: float) -> void:
	if phase == &"playing":
		var network_connected := _network_ready and _network_manager != null and _network_manager.has_connection()
		if network_connected and not _network_manager.is_host():
			_network_match_time_left = maxf(_network_match_time_left - delta, 0.0)
			var local_input := Vector2.ZERO if _local_input_blocked else Input.get_vector("move_left", "move_right", "move_up", "move_down")
			_preview_local_input(local_input)
			_network_manager.submit_local_input(local_input, local_input)
			return
		_network_sync_due = false
		if network_connected and _network_manager.is_host():
			var host_input := Vector2.ZERO if _local_input_blocked else Input.get_vector("move_left", "move_right", "move_up", "move_down")
			_network_manager.submit_local_input(host_input, host_input)
			_network_state_accumulator += delta
			var state_interval := 1.0 / maxf(balance.network_state_hz, 1.0)
			if _network_state_accumulator >= state_interval:
				_network_state_accumulator = fmod(_network_state_accumulator, state_interval)
				_network_sync_due = true
		_check_player_bounds()
		if network_connected and _network_sync_due:
			_network_tick += 1
			_publish_network_state()

func _physics_process(delta: float) -> void:
	if phase != &"playing":
		return
	var network_connected := _network_ready and _network_manager != null and _network_manager.has_connection()
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		player.decay_wind(delta)
	if network_connected and not _network_manager.is_host():
		return
	_apply_players_wind(delta)

func _check_player_bounds() -> void:
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		if player.is_active_in_match and not player.is_respawning and not player.is_landing and not _is_on_island(player.global_position):
			player.mark_fallen(player.last_attacker_id)

func _is_on_island(point: Vector2) -> bool:
	if _island_polygon.size() < 3:
		return map_definition.island_rect.grow(4.0).has_point(point)
	return Geometry2D.is_point_in_polygon(point, _island_polygon)

func _random_respawn_point() -> Vector2:
	if _island_polygon.size() < 3:
		return map_definition.island_rect.get_center()
	var safe_polygon := _island_polygon
	if map_definition.respawn_edge_margin > 0.0:
		var inset_regions := Geometry2D.offset_polygon(_island_polygon, -map_definition.respawn_edge_margin, Geometry2D.JOIN_ROUND)
		var inset_polygon := _largest_polygon(inset_regions)
		if inset_polygon.size() >= 3:
			safe_polygon = inset_polygon
	var bounds := Rect2(safe_polygon[0], Vector2.ZERO)
	for point in safe_polygon:
		bounds = bounds.expand(point)
	for _attempt in range(64):
		var candidate := Vector2(
			_spawn_rng.randf_range(bounds.position.x, bounds.end.x),
			_spawn_rng.randf_range(bounds.position.y, bounds.end.y)
		)
		if Geometry2D.is_point_in_polygon(candidate, safe_polygon):
			return candidate
	return bounds.get_center()

func _largest_polygon(polygons: Array[PackedVector2Array]) -> PackedVector2Array:
	var largest := PackedVector2Array()
	var largest_area := 0.0
	for polygon in polygons:
		var area := 0.0
		for index in range(polygon.size()):
			area += polygon[index].cross(polygon[(index + 1) % polygon.size()])
		area = absf(area * 0.5)
		if area > largest_area:
			largest = polygon
			largest_area = area
	return largest

func _preferred_spawn_for(player: IslandPlayer) -> Vector2:
	var preferred := map_definition.red_spawn if player.team == 0 else map_definition.blue_spawn
	return preferred if _is_on_island(preferred) else _random_respawn_point()

func _spawn_player_node(data: Variant) -> Node:
	var info: Dictionary = data as Dictionary if data is Dictionary else {}
	var player := PLAYER_SCENE.instantiate() as IslandPlayer
	var peer_id := int(info.get("peer_id", 1))
	player.name = "Player_%d" % peer_id
	player.player_id = peer_id
	player.team = int(info.get("team", 0))
	player.set_fashion_loadout(_resolved_player_fashion(peer_id, info.get("fashion", null)))
	player.set_display_name(player_display_name(peer_id))
	player.global_position = _preferred_spawn_for(player)
	player.set_multiplayer_authority(NetworkManager.SERVER_PEER_ID)
	return player

func _on_player_spawned(node: Node) -> void:
	var player := node as IslandPlayer
	if player == null:
		return
	player.configure_wind_pulse(balance)
	if not player.fell.is_connected(_on_player_fell):
		player.fell.connect(_on_player_fell)
	if not players.has(player.player_id):
		register_player(player)
	if _network_manager == null or not _network_manager.has_connection() or _network_manager.is_host():
		player.is_host_authority = true
	player.set_fashion_loadout(_resolved_player_fashion(player.player_id, player.fashion_loadout))
	player.set_display_name(player_display_name(player.player_id))
	player.set_active_in_match(phase == &"playing" or phase == &"score_lock")
	_refresh_local_views()

func _ensure_local_players() -> void:
	if _network_ready and _network_manager != null and _network_manager.has_connection():
		return
	var local_peer_id := 1
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() != 1:
		local_peer_id = multiplayer.get_unique_id()
	if not players.has(local_peer_id):
		_register_spawned_player(local_peer_id, 0, FashionProfile.load_loadout(load("res://resources/fashion/catalog.tres") as FashionCatalog))

func _register_spawned_player(peer_id: int, team: int, fashion: Dictionary = {}) -> IslandPlayer:
	if players.has(peer_id):
		return players[peer_id]
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return null
	var resolved_fashion := _resolved_player_fashion(peer_id, fashion)
	var player := player_spawner.spawn({"peer_id": peer_id, "team": team, "fashion": resolved_fashion}) as IslandPlayer
	if player != null:
		if not player.fell.is_connected(_on_player_fell):
			player.fell.connect(_on_player_fell)
		if not players.has(player.player_id):
			register_player(player)
		if _network_manager == null or not _network_manager.has_connection() or _network_manager.is_host():
			player.is_host_authority = true
		player.set_active_in_match(phase == &"playing" or phase == &"score_lock")
	return players.get(peer_id)

func _ensure_network_player(peer_id: int, team: int, fashion: Variant = null) -> IslandPlayer:
	if peer_id <= 0:
		return null
	if fashion is Dictionary:
		_cache_player_fashion(peer_id, fashion)
	if players.has(peer_id):
		var existing := players[peer_id] as IslandPlayer
		if existing != null and fashion is Dictionary:
			existing.set_fashion_loadout(_resolved_player_fashion(peer_id, fashion))
		return existing
	if _network_manager != null and _network_manager.has_connection() and not _network_manager.is_host():
		return null
	return _register_spawned_player(peer_id, team, _resolved_player_fashion(peer_id, fashion))

func _cache_player_fashion(peer_id: int, fashion: Dictionary) -> Dictionary:
	var sanitized := FashionProfile.sanitize_loadout(fashion)
	_player_fashion_cache[peer_id] = sanitized.duplicate(true)
	return sanitized

func _resolved_player_fashion(peer_id: int, fallback: Variant = null) -> Dictionary:
	if _network_manager != null:
		var lobby_player_variant: Variant = _network_manager.get_lobby_players().get(peer_id)
		if lobby_player_variant is Dictionary:
			var lobby_fashion_variant: Variant = lobby_player_variant.get("fashion", null)
			if lobby_fashion_variant is Dictionary:
				return _cache_player_fashion(peer_id, lobby_fashion_variant)
	var cached_variant: Variant = _player_fashion_cache.get(peer_id)
	if cached_variant is Dictionary:
		return Dictionary(cached_variant).duplicate(true)
	if fallback is Dictionary:
		return _cache_player_fashion(peer_id, fallback)
	return FashionProfile.empty_loadout()

func host_room(room_title: String = "鼓风机大乱斗房间", _map_id: String = "medium") -> bool:
	_player_fashion_cache.clear()
	select_map(&"medium")
	if _network_ready:
		var network_error := _network_manager.host_room(room_title, &"medium", 8, _map_revision)
		if network_error != OK:
			return false
		phase = &"lobby"
		# Hosting completes synchronously. Apply the authoritative roster here as
		# well as through the signal so the host player always exists immediately.
		_on_network_lobby_snapshot(_network_manager.lobby_snapshot())
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
	_player_fashion_cache.clear()
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
	if map_id != &"medium":
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
	_replace_map(map_definition.map_id)
	_center_countdown_camera()
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		player.global_position = _preferred_spawn_for(player)

func _replace_map(map_id: StringName) -> void:
	if _current_map_id == map_id and _current_map != null:
		return
	if _current_map != null:
		_current_map.queue_free()
	_current_map = null
	var scene: PackedScene = MAP_SCENES.get(map_id)
	if scene == null:
		_current_map_id = &""
		_island_polygon = PackedVector2Array()
		return
	_current_map = scene.instantiate()
	map_root.add_child(_current_map)
	_current_map_id = map_id
	_island_polygon = _read_island_polygon()

func _read_island_polygon() -> PackedVector2Array:
	if _current_map == null:
		return PackedVector2Array()
	var island := _current_map.get_node_or_null("Island") as Polygon2D
	if island == null:
		return PackedVector2Array()
	var world_polygon := PackedVector2Array()
	for point in island.polygon:
		world_polygon.append(island.to_global(point))
	return world_polygon

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
	_player_fashion_cache.clear()
	if _network_ready and _network_manager.has_connection():
		_network_manager.leave_room()
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	phase = &"menu"
	_set_countdown_camera_active(false)
	phase_changed.emit(phase)

func start_match() -> void:
	if phase == &"playing" or phase == &"countdown":
		return
	phase = &"countdown"
	_set_hud_visible(true)
	_set_countdown_camera_active(true)
	countdown_timer.start(balance.countdown_sec)
	countdown_changed.emit(ceili(balance.countdown_sec))
	phase_changed.emit(phase)
	if _network_ready and _network_manager.is_host():
		_network_manager.host_set_match_phase(&"countdown", {"seconds": balance.countdown_sec})

func _start_countdown_local() -> void:
	phase = &"countdown"
	_set_hud_visible(true)
	_set_countdown_camera_active(true)
	countdown_timer.start(balance.countdown_sec)
	countdown_changed.emit(ceili(balance.countdown_sec))
	phase_changed.emit(phase)

func _on_network_start_requested(_peer_id: int) -> void:
	if _network_manager != null and _network_manager.is_host():
		begin_countdown()

func _on_network_input_received(peer_id: int, movement: Vector2, aim: Vector2, _blowing: bool) -> void:
	_remote_inputs[peer_id] = {"movement": movement, "aim": aim}
	if players.has(peer_id) and players[peer_id].is_active_in_match:
		players[peer_id].set_input(movement, aim)

func _on_network_action_requested(peer_id: int, action: StringName, payload: Dictionary) -> void:
	match action:
		&"skill_upgrade":
			request_skill_upgrade(peer_id, StringName(payload.get("entry_id", "")))
		&"wind_pump":
			_pump_player_wind(peer_id, int(payload.get("count", 1)))

func _on_network_phase_received(network_phase: StringName, payload: Dictionary) -> void:
	if _network_manager != null and _network_manager.is_host():
		return
	phase = network_phase
	match network_phase:
		&"countdown":
			_reset_match_state()
			var countdown_seconds := float(payload.get("seconds", balance.countdown_sec))
			countdown_timer.start(countdown_seconds)
			countdown_changed.emit(ceili(countdown_seconds))
			_set_countdown_camera_active(true)
			_set_hud_visible(true)
		&"playing":
			_set_countdown_camera_active(false)
			match_timer.stop()
			_network_match_time_left = float(payload.get("match_duration", balance.match_duration_sec))
			_activate_lobby_players()
			_set_hud_visible(true)
		&"score_lock":
			_score_locked = true
		&"results":
			_set_countdown_camera_active(false)
			red_score = int(payload.get("red_score", red_score))
			blue_score = int(payload.get("blue_score", blue_score))
			score_changed.emit(red_score, blue_score)
			match_finished.emit(int(payload.get("winner_team", -1)), red_score, blue_score)
			_schedule_return_to_lobby()
		&"lobby":
			_set_countdown_camera_active(false)
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
		if player_id <= 0:
			continue
		var fashion_variant: Variant = player_data.get("fashion", {})
		var fashion := _cache_player_fashion(player_id, fashion_variant if fashion_variant is Dictionary else {})
		active_player_ids[player_id] = true
		var player := _ensure_network_player(player_id, int(player_data.get("team", 0)), fashion)
		if player == null:
			continue
		if players.has(player_id):
			players[player_id].team = int(player_data.get("team", players[player_id].team))
			players[player_id].set_display_name(String(player_data.get("display_name", player_display_name(player_id))))
			players[player_id].set_fashion_loadout(fashion)
		player.set_active_in_match(should_activate)
	for cached_id_variant in _player_fashion_cache.keys():
		if not active_player_ids.has(int(cached_id_variant)):
			_player_fashion_cache.erase(cached_id_variant)
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
	var fashion_variant: Variant = player_data.get("fashion", {})
	var fashion := _cache_player_fashion(peer_id, fashion_variant if fashion_variant is Dictionary else {})
	var player := _ensure_network_player(peer_id, int(player_data.get("team", 1)), fashion)
	if player != null:
		player.set_display_name(String(player_data.get("display_name", player_display_name(peer_id))))
		player.set_active_in_match(phase == &"playing" or phase == &"score_lock")

func _on_network_peer_left(peer_id: int) -> void:
	_player_fashion_cache.erase(peer_id)
	if not players.has(peer_id):
		return
	var player: IslandPlayer = players[peer_id]
	if peer_id == 1:
		player.set_active_in_match(false)
		return
	players.erase(peer_id)
	if is_instance_valid(player):
		player.queue_free()

func _on_network_state_received(snapshot: Dictionary, _server_tick: int) -> void:
	if _network_manager != null and _network_manager.is_host():
		return
	var next_red_score := int(snapshot.get("red_score", red_score))
	var next_blue_score := int(snapshot.get("blue_score", blue_score))
	_network_match_time_left = maxf(float(snapshot.get("match_time_left", _network_match_time_left)), 0.0)
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
		var target_position := Vector2(player_data.get("position", player.global_position))
		var was_respawning := player.is_respawning
		var respawning := bool(player_data.get("respawning", player.is_respawning))
		player.team = int(player_data.get("team", player.team))
		player.invulnerability_time = float(player_data.get("invulnerability", player.invulnerability_time))
		player.fall_count = int(player_data.get("fall_count", player.fall_count))
		player.apply_network_snapshot(target_position, Vector2(player_data.get("facing", player.facing)), float(player_data.get("wind_intensity", 0.0)), respawning)
		if was_respawning and not respawning:
			_last_fall_attacker.erase(player_id)
			player_respawned.emit(player_id)
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
			var scoring := _apply_fall_scoring(victim_id, attacker_id)
			var victim := players.get(victim_id) as IslandPlayer
			if victim != null:
				victim.last_attacker_id = attacker_id
				victim.set_respawning_state(true)
			respawn_countdown_started.emit(victim_id, float(payload.get("respawn_seconds", balance.respawn_base_sec)))
			if bool(scoring.get("applied", false)):
				player_eliminated.emit(attacker_id, victim_id, int(payload.get("reward", scoring.get("reward", 0))))
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
			state.append({"player_id": player.player_id, "position": player.global_position, "facing": player.facing, "wind_intensity": player.wind_intensity, "team": player.team, "respawning": player.is_respawning, "invulnerability": player.invulnerability_time, "coins": player.skill_points, "fall_count": player.fall_count, "enhancement_stacks": player.enhancement_stacks.duplicate(true), "skill_points": player.skill_points})
	_network_manager.host_publish_player_state({"players": state, "red_score": red_score, "blue_score": blue_score, "phase": String(phase), "match_time_left": match_timer.time_left}, _network_tick)

func _on_countdown_timeout() -> void:
	var network_connected := _network_ready and _network_manager != null and _network_manager.has_connection()
	if network_connected and not _network_manager.is_host():
		return
	phase = &"playing"
	_set_hud_visible(true)
	_set_countdown_camera_active(false)
	_reset_match_state()
	_activate_lobby_players()
	match_timer.start(balance.match_duration_sec)
	_network_match_time_left = balance.match_duration_sec
	phase_changed.emit(phase)
	if network_connected:
		_network_manager.host_set_match_phase(&"playing", {"match_duration": balance.match_duration_sec})

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
	_refresh_local_views()

func _refresh_local_views() -> void:
	var local_player_id := local_player_id()
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		var is_local := player.player_id == local_player_id
		player.set_local_view(is_local)
		if is_local:
			player.set_local_input_blocked(_local_input_blocked)

func local_player_id() -> int:
	if _network_ready and _network_manager != null and _network_manager.has_connection():
		return _network_manager.local_peer_id()
	if multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return 1

func player_display_name(player_id: int) -> String:
	if _network_manager != null:
		var player_data: Variant = _network_manager.get_lobby_players().get(player_id)
		if player_data is Dictionary:
			var display_name := String(player_data.get("display_name", "")).strip_edges()
			if not display_name.is_empty():
				return display_name
		if player_id == local_player_id():
			var local_name := _network_manager.local_display_name.strip_edges()
			if not local_name.is_empty():
				return local_name
	return "Player %d" % player_id

func match_time_left() -> float:
	if phase != &"playing":
		return 0.0
	if _network_ready and _network_manager != null and _network_manager.has_connection() and not _network_manager.is_host():
		return _network_match_time_left
	return match_timer.time_left

func _apply_players_wind(delta: float) -> void:
	for player_id in players:
		var player: IslandPlayer = players[player_id]
		if not player.is_active_in_match or player.is_respawning or player.is_landing or not player.is_blowing:
			continue
		for other_id in players:
			if other_id == player_id:
				continue
			var other: IslandPlayer = players[other_id]
			if not other.is_active_in_match or other.is_respawning or other.is_landing or other.invulnerability_time > 0.0:
				continue
			var target_point := other.be_blowed_position()
			if not player.affects_point(target_point):
				continue
			var wind_velocity := player.wind_at(target_point) * (player.push_force / maxf(player.wind_force, 1.0))
			if wind_velocity.length_squared() <= 0.0001:
				continue
			other.last_attacker_id = player.player_id
			other.apply_wind(wind_velocity, delta)
			if not _is_on_island(other.global_position):
				other.mark_fallen(player.player_id)

func pump_local_wind() -> Dictionary:
	if phase != &"playing" or _local_input_blocked:
		return {}
	var local_player := players.get(local_player_id()) as IslandPlayer
	if local_player == null:
		return {}
	var network_connected := _network_ready and _network_manager != null and _network_manager.has_connection()
	if network_connected:
		if _network_manager.is_host():
			return _pump_player_wind(local_player.player_id, 1)
		var preview := local_player.pump_wind()
		_network_manager.request_game_action(&"wind_pump", {"count": 1})
		return preview
	return local_player.pump_wind()

func _pump_player_wind(player_id: int, count: int) -> Dictionary:
	var player := players.get(player_id) as IslandPlayer
	return player.pump_wind(count) if player != null else {}

func _preview_local_input(direction: Vector2) -> void:
	if _network_manager == null:
		return
	var local_player := players.get(_network_manager.local_peer_id()) as IslandPlayer
	if local_player != null:
		local_player.set_input(direction, direction)

func set_local_input_blocked(value: bool) -> void:
	_local_input_blocked = value
	var local_player := players.get(local_player_id()) as IslandPlayer
	if local_player != null:
		local_player.set_local_input_blocked(value)
		if value:
			local_player.set_input(Vector2.ZERO, Vector2.ZERO)

func request_return_to_menu() -> void:
	set_local_input_blocked(true)
	return_to_menu_requested.emit()

func _on_match_timeout() -> void:
	if _network_ready and _network_manager != null and _network_manager.has_connection() and not _network_manager.is_host():
		return
	_score_locked = true
	_network_match_time_left = 0.0
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
	_set_countdown_camera_active(false)
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
	var scoring := _apply_fall_scoring(player_id, attacker_id)
	var respawn_wait := _schedule_respawn_for(player_id)
	if _network_ready and _network_manager != null and _network_manager.has_connection() and _network_manager.is_host():
		_network_manager.host_publish_match_event(&"player_fell", _with_map_revision({"victim_id": player_id, "attacker_id": attacker_id, "reward": int(scoring.get("reward", 0)), "respawn_seconds": respawn_wait}))
	if bool(scoring.get("applied", false)):
		player_eliminated.emit(attacker_id, player_id, int(scoring.get("reward", 0)))
	event_announced.emit("Player %d was blown off!" % player_id)

func _apply_fall_scoring(victim_id: int, attacker_id: int) -> Dictionary:
	if _last_fall_attacker.has(victim_id):
		return {"applied": false, "reward": 0}
	_last_fall_attacker[victim_id] = true
	var scored_team := 0
	var scorer_id := 0
	var reward := 0
	if attacker_id > 0 and players.has(attacker_id):
		scorer_id = attacker_id
		scored_team = players[attacker_id].team
		reward = balance.skill_points_per_fall
		players[attacker_id].add_skill_points(reward)
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
	return {"applied": true, "scorer_id": scorer_id, "reward": reward}

func _schedule_respawn_for(player_id: int) -> float:
	var player: IslandPlayer = players.get(player_id)
	if player == null:
		return 0.0
	var wait := minf(balance.respawn_max_sec, balance.respawn_base_sec + balance.respawn_increment_sec * maxi(player.fall_count - 1, 0))
	_pending_respawn[player_id] = Time.get_ticks_msec() + int(wait * 1000.0)
	respawn_countdown_started.emit(player_id, wait)
	_schedule_next_respawn()
	return wait

func _on_respawn_timeout() -> void:
	var now := Time.get_ticks_msec()
	for player_id in _pending_respawn.keys().duplicate():
		if now < int(_pending_respawn[player_id]):
			continue
		var player: IslandPlayer = players.get(player_id)
		if player:
			var spawn := _random_respawn_point()
			player.respawn(spawn, balance.respawn_invulnerability_sec)
			_last_fall_attacker.erase(player_id)
			player_respawned.emit(player_id)
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

func _center_countdown_camera() -> void:
	if countdown_camera == null:
		return
	if _island_polygon.size() < 3:
		countdown_camera.position = map_definition.island_rect.get_center()
		return
	var bounds := Rect2(_island_polygon[0], Vector2.ZERO)
	for point in _island_polygon:
		bounds = bounds.expand(point)
	countdown_camera.position = bounds.get_center()

func _set_countdown_camera_active(value: bool) -> void:
	if countdown_camera == null:
		return
	if value:
		_center_countdown_camera()
	countdown_camera.enabled = value

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
	_network_match_time_left = balance.match_duration_sec
	_pending_respawn.clear()
	_last_fall_attacker.clear()
	for player_variant in players.values():
		var player: IslandPlayer = player_variant
		var spawn := _preferred_spawn_for(player)
		player.reset_match_state(spawn)
		skill_points_changed.emit(player.player_id, player.skill_points)
	score_changed.emit(red_score, blue_score)
