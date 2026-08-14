class_name IslandPlayer
extends CharacterBody2D

signal fell(player_id: int, fall_count: int)
signal state_changed(player_id: int)

@export var player_id: int = 1
@export var team: int = 0
@export var move_speed: float = 170.0
@export var wind_range: float = 300.0
@export var wind_angle_deg: float = 30.0
@export var wind_force: float = 800.0
@export var push_force: float = 400.0
@export var wind_falloff: float = 0.5
@export var invulnerability_time: float = 0.0

var skill_points: int = 0
var fall_count: int = 0
var facing: Vector2 = Vector2.RIGHT
var input_vector: Vector2 = Vector2.ZERO
var is_respawning: bool = false
var is_host_authority: bool = true
var is_active_in_match: bool = true
var is_blowing: bool = true
var last_attacker_id: int = 0
var enhancement_stacks: Dictionary = {}
var _is_local_view: bool = false
var _network_target_position := Vector2.ZERO
var _has_network_target := false
var _base_move_speed := 0.0
var _base_wind_range := 0.0
var _base_wind_angle_deg := 0.0
var _base_wind_force := 0.0
var _base_push_force := 0.0
var _base_wind_falloff := 0.0

@onready var wind_blower: Node2D = $WindBlower
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var player_camera: Camera2D = $Camera2D

func _ready() -> void:
	add_to_group("players")
	_base_move_speed = move_speed
	_base_wind_range = wind_range
	_base_wind_angle_deg = wind_angle_deg
	_base_wind_force = wind_force
	_base_push_force = push_force
	_base_wind_falloff = wind_falloff
	wind_blower.rotation = facing.angle()
	player_camera.enabled = false
	if not is_multiplayer_authority() and multiplayer.has_multiplayer_peer():
		is_host_authority = false

func _physics_process(_delta: float) -> void:
	if not is_active_in_match or not is_host_authority or is_respawning:
		return
	if multiplayer.has_multiplayer_peer() and not is_multiplayer_authority():
		return
	if not multiplayer.has_multiplayer_peer():
		input_vector = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if input_vector.length_squared() > 0.0001:
		facing = input_vector.normalized()
		velocity = input_vector * move_speed
	else:
		velocity = Vector2.ZERO
	wind_blower.rotation = facing.angle()
	move_and_slide()

func set_input(direction: Vector2) -> void:
	if not is_active_in_match:
		return
	input_vector = direction.limit_length(1.0)
	if input_vector.length_squared() > 0.0001:
		facing = input_vector.normalized()
	wind_blower.rotation = facing.angle()

func wind_origin() -> Vector2:
	return global_position + facing * 16.0

func affects_point(point: Vector2) -> bool:
	var offset := point - wind_origin()
	var distance := offset.length()
	if distance > wind_range or distance < 0.001:
		return false
	return facing.dot(offset / distance) >= cos(deg_to_rad(wind_angle_deg))

func wind_at(point: Vector2) -> Vector2:
	if not is_blowing or not affects_point(point):
		return Vector2.ZERO
	var distance := maxf((point - wind_origin()).length(), 1.0)
	var falloff := pow(maxf(0.0, 1.0 - distance / wind_range), wind_falloff)
	return facing * wind_force * falloff

func add_skill_points(amount: int) -> void:
	skill_points = maxi(0, skill_points + amount)
	state_changed.emit(player_id)

func apply_skill(entry: EnhancementEntry, price: int = 1) -> bool:
	if skill_points < price:
		return false
	var current := int(enhancement_stacks.get(entry.id, 0))
	if current >= entry.max_stack:
		return false
	if entry.exclusive_group != StringName():
		for other_entry in _catalog_entries():
			if other_entry.id != entry.id and other_entry.exclusive_group == entry.exclusive_group and int(enhancement_stacks.get(other_entry.id, 0)) > 0:
				return false
	enhancement_stacks[entry.id] = current + 1
	skill_points -= price
	match entry.target_stat:
		&"move_speed": move_speed *= 1.0 + entry.value_per_stack
		&"blower_force": wind_force *= 1.0 + entry.value_per_stack
		&"blower_push_force": push_force *= 1.0 + entry.value_per_stack
		&"blower_falloff": wind_falloff = maxf(0.05, wind_falloff - entry.value_per_stack)
		&"blower_angle_deg": wind_angle_deg += entry.value_per_stack
	state_changed.emit(player_id)
	return true

func _catalog_entries() -> Array[EnhancementEntry]:
	var catalog := load("res://resources/enhancements/catalog.tres") as EnhancementCatalog
	return catalog.entries if catalog else []

func mark_fallen(attacker_id: int = 0) -> void:
	if not is_active_in_match or is_respawning:
		return
	last_attacker_id = attacker_id
	fall_count += 1
	is_respawning = true
	velocity = Vector2.ZERO
	fell.emit(player_id, fall_count)
	state_changed.emit(player_id)

func respawn(at: Vector2, invulnerability_sec: float) -> void:
	global_position = at
	is_respawning = false
	invulnerability_time = invulnerability_sec
	state_changed.emit(player_id)

func _process(delta: float) -> void:
	if not is_active_in_match:
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server() and _has_network_target:
		global_position = global_position.lerp(_network_target_position, minf(delta * 16.0, 1.0))
	if invulnerability_time > 0.0:
		invulnerability_time = maxf(0.0, invulnerability_time - delta)

func set_network_position(target: Vector2) -> void:
	_network_target_position = target
	_has_network_target = true

func reset_match_state(at: Vector2) -> void:
	global_position = at
	_network_target_position = at
	_has_network_target = false
	skill_points = 0
	fall_count = 0
	facing = Vector2.RIGHT
	input_vector = Vector2.ZERO
	is_respawning = false
	invulnerability_time = 0.0
	last_attacker_id = 0
	enhancement_stacks.clear()
	move_speed = _base_move_speed
	wind_range = _base_wind_range
	wind_angle_deg = _base_wind_angle_deg
	wind_force = _base_wind_force
	push_force = _base_push_force
	wind_falloff = _base_wind_falloff
	wind_blower.rotation = facing.angle()
	state_changed.emit(player_id)

func set_active_in_match(value: bool) -> void:
	is_active_in_match = value
	visible = value
	if collision_shape != null:
		collision_shape.disabled = not value
	if player_camera != null:
		player_camera.enabled = _is_local_view and value
	if not value:
		velocity = Vector2.ZERO
		input_vector = Vector2.ZERO
		is_respawning = false

func set_local_view(value: bool) -> void:
	_is_local_view = value
	if player_camera != null:
		player_camera.enabled = value and is_active_in_match
