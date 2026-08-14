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
var is_landing: bool = false
var is_host_authority: bool = true
var is_active_in_match: bool = true
var is_blowing: bool = false
var wind_intensity: float = 0.0
var wind_combo: int = 0
var last_attacker_id: int = 0
var enhancement_stacks: Dictionary = {}
var _is_local_view: bool = false
var _wind_velocity := Vector2.ZERO
var _network_target_position := Vector2.ZERO
var _has_network_target := false
var _base_move_speed := 0.0
var _base_wind_range := 0.0
var _base_wind_angle_deg := 0.0
var _base_wind_force := 0.0
var _base_push_force := 0.0
var _base_wind_falloff := 0.0
var _wind_tap_gain := 0.16
var _wind_decay_per_sec := 0.34
var _wind_active_threshold := 0.04
var _wind_combo_window_sec := 0.5
var _wind_combo_limit := 12
var _last_wind_tap_at := -10.0
var _display_name := "Player"

@onready var wind_blower: Node2D = $WindBlower
@onready var wind_origin_marker: Marker2D = $WindBlower/WindOrigin
@onready var wind_area: Polygon2D = $WindBlower/WindOrigin/WindArea
@onready var wind_particles: GPUParticles2D = $WindBlower/WindOrigin/WindParticles
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var player_camera: Camera2D = $Camera2D
@onready var visual: Sprite2D = $Visual
@onready var fall_animation_player: AnimationPlayer = %FallAnimationPlayer
@onready var respawn_animation_player: AnimationPlayer = %RespawnAnimationPlayer
@onready var player_shadow: Polygon2D = %PlayerShadow
@onready var name_label: Label = %NameLabel

func _ready() -> void:
	add_to_group("players")
	_base_move_speed = move_speed
	_base_wind_range = wind_range
	_base_wind_angle_deg = wind_angle_deg
	_base_wind_force = wind_force
	_base_push_force = push_force
	_base_wind_falloff = wind_falloff
	wind_blower.rotation = facing.angle()
	_refresh_name_label()
	_refresh_wind_visual()
	player_camera.enabled = false
	if not is_multiplayer_authority() and multiplayer.has_multiplayer_peer():
		is_host_authority = false

func _physics_process(delta: float) -> void:
	if not is_active_in_match or not is_host_authority or is_respawning or is_landing:
		return
	if multiplayer.has_multiplayer_peer() and (not multiplayer.is_server() or not is_multiplayer_authority()):
		return
	if not multiplayer.has_multiplayer_peer():
		input_vector = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if input_vector.length_squared() > 0.0001:
		facing = input_vector.normalized()
	velocity = input_vector * move_speed + _wind_velocity
	wind_blower.rotation = facing.angle()
	move_and_slide()
	_wind_velocity = _wind_velocity.move_toward(Vector2.ZERO, maxf(push_force * 0.5, 1.0) * delta)

func set_input(direction: Vector2, aim: Vector2 = Vector2.ZERO) -> void:
	if not is_active_in_match:
		return
	input_vector = direction.limit_length(1.0)
	var next_facing := aim if aim.length_squared() > 0.0001 else input_vector
	if next_facing.length_squared() > 0.0001:
		facing = next_facing.normalized()
		wind_blower.rotation = facing.angle()

func configure_wind_pulse(balance: BalanceConfig) -> void:
	if balance == null:
		return
	_wind_tap_gain = balance.blower_tap_gain
	_wind_decay_per_sec = balance.blower_decay_per_sec
	_wind_active_threshold = balance.blower_active_threshold
	_wind_combo_window_sec = balance.blower_combo_window_sec
	_wind_combo_limit = balance.blower_combo_limit

func pump_wind(taps: int = 1) -> Dictionary:
	if not is_active_in_match or is_respawning or is_landing:
		return {}
	var now := Time.get_ticks_msec() * 0.001
	wind_combo = mini(wind_combo + 1, _wind_combo_limit) if now - _last_wind_tap_at <= _wind_combo_window_sec else 1
	_last_wind_tap_at = now
	var combo_bonus := 1.0 + minf(float(wind_combo - 1), 8.0) * 0.06
	var gain := _wind_tap_gain * float(clampi(taps, 1, 2)) * combo_bonus
	set_wind_intensity(wind_intensity + gain)
	return {"combo": wind_combo, "gain": gain, "intensity": wind_intensity}

func decay_wind(delta: float) -> void:
	if wind_intensity <= 0.0:
		return
	set_wind_intensity(wind_intensity - _wind_decay_per_sec * delta)
	if wind_intensity <= 0.0:
		wind_combo = 0

func set_wind_intensity(value: float) -> void:
	var next_intensity := clampf(value, 0.0, 1.0)
	if is_equal_approx(wind_intensity, next_intensity):
		return
	wind_intensity = next_intensity
	is_blowing = wind_intensity >= _wind_active_threshold and is_active_in_match and not is_respawning and not is_landing
	_refresh_wind_visual()

func apply_wind(force: Vector2, delta: float) -> void:
	if force.length_squared() <= 0.0001 or is_respawning or is_landing or not is_active_in_match:
		return
	_wind_velocity = (_wind_velocity + force * delta).limit_length(maxf(push_force, 1.0))

func wind_origin() -> Vector2:
	return wind_origin_marker.global_position

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
	return facing * wind_force * wind_intensity * falloff

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
	_refresh_wind_visual()
	state_changed.emit(player_id)
	return true

func _refresh_wind_visual() -> void:
	if not is_node_ready() or wind_area == null or wind_particles == null:
		return
	var safe_angle := clampf(wind_angle_deg, 1.0, 85.0)
	var half_width := tan(deg_to_rad(safe_angle)) * wind_range
	wind_area.polygon = PackedVector2Array([
		Vector2.ZERO,
		Vector2(wind_range, -half_width),
		Vector2(wind_range, half_width),
	])
	var active := is_blowing and is_active_in_match and not is_respawning and not is_landing
	wind_area.visible = active
	wind_particles.emitting = active
	var visual_strength := clampf(wind_intensity, 0.0, 1.0)
	wind_area.color = Color(0.3, 0.82, 1.0, lerpf(0.04, 0.22, visual_strength)).lerp(Color(1.0, 0.7, 0.25, lerpf(0.08, 0.3, visual_strength)), visual_strength)
	wind_particles.lifetime = maxf(wind_range / 220.0, 0.35)
	wind_particles.visibility_rect = Rect2(0.0, -half_width - 24.0, wind_range + 48.0, half_width * 2.0 + 48.0)
	wind_particles.amount_ratio = lerpf(0.2, 1.0, visual_strength)
	wind_particles.speed_scale = lerpf(0.55, 1.45, visual_strength)
	var particle_material := wind_particles.process_material as ParticleProcessMaterial
	if particle_material != null:
		particle_material.spread = safe_angle
		var travel_speed := wind_range / wind_particles.lifetime * lerpf(0.55, 1.35, visual_strength)
		particle_material.initial_velocity_min = travel_speed * 0.75
		particle_material.initial_velocity_max = travel_speed * 1.15
		particle_material.color = Color(0.62, 0.93, 1.0, 0.42).lerp(Color(1.0, 0.68, 0.2, 0.95), visual_strength)

func _catalog_entries() -> Array[EnhancementEntry]:
	var catalog := load("res://resources/enhancements/catalog.tres") as EnhancementCatalog
	return catalog.entries if catalog else []

func mark_fallen(attacker_id: int = 0) -> void:
	if not is_active_in_match or is_respawning or is_landing:
		return
	last_attacker_id = attacker_id
	fall_count += 1
	set_respawning_state(true)
	fell.emit(player_id, fall_count)
	state_changed.emit(player_id)

func respawn(at: Vector2, invulnerability_sec: float) -> void:
	global_position = at
	_network_target_position = at
	_has_network_target = false
	_wind_velocity = Vector2.ZERO
	set_respawning_state(false)
	_reset_fall_visual()
	invulnerability_time = invulnerability_sec
	_play_respawn_animation()
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

func set_network_state(next_facing: Vector2, next_wind_intensity: float) -> void:
	if next_facing.length_squared() > 0.0001:
		facing = next_facing.normalized()
		wind_blower.rotation = facing.angle()
	set_wind_intensity(next_wind_intensity if not is_respawning else 0.0)

func apply_network_snapshot(target_position: Vector2, next_facing: Vector2, next_wind_intensity: float, respawning: bool) -> void:
	var was_respawning := is_respawning
	set_respawning_state(respawning)
	if was_respawning and not respawning:
		global_position = target_position
		_network_target_position = target_position
		_has_network_target = false
		_play_respawn_animation()
	else:
		set_network_position(target_position)
	set_network_state(next_facing, next_wind_intensity)

func set_respawning_state(value: bool) -> void:
	if is_respawning == value:
		return
	is_respawning = value
	if value:
		is_landing = false
		_reset_respawn_visual()
		velocity = Vector2.ZERO
		_wind_velocity = Vector2.ZERO
		input_vector = Vector2.ZERO
		is_blowing = false
		wind_intensity = 0.0
		wind_combo = 0
		_play_fall_animation()
	else:
		_reset_fall_visual()
	_refresh_wind_visual()
	_refresh_body_presence()

func _refresh_body_presence() -> void:
	var body_enabled := is_active_in_match and not is_respawning and not is_landing
	visible = is_active_in_match
	if collision_shape != null:
		collision_shape.set_deferred("disabled", not body_enabled)
	if visual != null:
		visual.visible = is_active_in_match
	if wind_blower != null:
		wind_blower.visible = is_active_in_match and not is_respawning
	if player_shadow != null:
		player_shadow.visible = is_active_in_match and not is_respawning
	if name_label != null:
		name_label.visible = is_active_in_match and not is_respawning

func _play_fall_animation() -> void:
	if not is_node_ready() or fall_animation_player == null:
		return
	fall_animation_player.stop()
	fall_animation_player.play(&"fall")

func _reset_fall_visual() -> void:
	if not is_node_ready() or fall_animation_player == null:
		return
	fall_animation_player.stop()
	fall_animation_player.play(&"RESET")
	fall_animation_player.advance(0.0)
	fall_animation_player.stop()

func _play_respawn_animation() -> void:
	if not is_node_ready() or respawn_animation_player == null:
		return
	is_landing = true
	_refresh_body_presence()
	respawn_animation_player.stop()
	respawn_animation_player.play(&"respawn_drop")

func _reset_respawn_visual() -> void:
	if not is_node_ready() or respawn_animation_player == null:
		return
	respawn_animation_player.stop()
	respawn_animation_player.play(&"RESET")
	respawn_animation_player.advance(0.0)
	respawn_animation_player.stop()

func _on_respawn_animation_finished(animation_name: StringName) -> void:
	if animation_name != &"respawn_drop":
		return
	is_landing = false
	_refresh_body_presence()
	state_changed.emit(player_id)

func set_display_name(value: String) -> void:
	var cleaned := value.strip_edges().substr(0, 16)
	_display_name = cleaned if not cleaned.is_empty() else "Player %d" % player_id
	_refresh_name_label()

func _refresh_name_label() -> void:
	if not is_node_ready() or name_label == null:
		return
	name_label.text = _display_name
	name_label.modulate = Color(1.0, 0.48, 0.54) if team == 0 else Color(0.48, 0.82, 1.0)

func reset_match_state(at: Vector2) -> void:
	global_position = at
	_wind_velocity = Vector2.ZERO
	_network_target_position = at
	_has_network_target = false
	skill_points = 0
	fall_count = 0
	facing = Vector2.RIGHT
	input_vector = Vector2.ZERO
	invulnerability_time = 0.0
	is_landing = false
	is_blowing = false
	wind_intensity = 0.0
	wind_combo = 0
	_last_wind_tap_at = -10.0
	last_attacker_id = 0
	enhancement_stacks.clear()
	move_speed = _base_move_speed
	wind_range = _base_wind_range
	wind_angle_deg = _base_wind_angle_deg
	wind_force = _base_wind_force
	push_force = _base_push_force
	wind_falloff = _base_wind_falloff
	wind_blower.rotation = facing.angle()
	set_respawning_state(false)
	_reset_fall_visual()
	_reset_respawn_visual()
	_refresh_wind_visual()
	state_changed.emit(player_id)

func set_active_in_match(value: bool) -> void:
	is_active_in_match = value
	if player_camera != null:
		player_camera.enabled = _is_local_view and value
	if not value:
		is_landing = false
		velocity = Vector2.ZERO
		_wind_velocity = Vector2.ZERO
		input_vector = Vector2.ZERO
		is_blowing = false
		wind_intensity = 0.0
		wind_combo = 0
		is_respawning = false
		_reset_fall_visual()
		_reset_respawn_visual()
	_refresh_wind_visual()
	_refresh_body_presence()

func set_local_view(value: bool) -> void:
	_is_local_view = value
	if player_camera != null:
		player_camera.enabled = value and is_active_in_match
