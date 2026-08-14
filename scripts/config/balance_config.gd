class_name BalanceConfig
extends Resource

@export var match_duration_sec: float = 180.0
@export var countdown_sec: float = 3.0
@export var score_lock_sec: float = 1.0
@export var respawn_base_sec: float = 5.0
@export var respawn_increment_sec: float = 2.0
@export var respawn_max_sec: float = 15.0
@export var respawn_invulnerability_sec: float = 2.0
@export var player_speed: float = 170.0
@export var blower_range: float = 300.0
@export var blower_angle_deg: float = 30.0
@export var blower_force: float = 800.0
@export var blower_push_force: float = 400.0
@export var blower_falloff: float = 0.5
@export var skill_points_per_fall: int = 1
@export var skill_upgrade_price: int = 1
@export var discovery_port: int = 47777
@export var game_port: int = 10567
@export var beacon_interval_sec: float = 1.0
@export var room_timeout_sec: float = 3.0
@export_range(5.0, 30.0, 1.0) var network_state_hz: float = 15.0
