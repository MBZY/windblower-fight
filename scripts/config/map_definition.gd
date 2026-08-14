class_name MapDefinition
extends Resource

@export var map_id: StringName = &"medium"
@export var display_name: String = "Medium Island"
@export var island_radius: float = 1000.0
@export var island_rect: Rect2 = Rect2(20, 80, 360, 640)
@export var red_spawn: Vector2 = Vector2(120, 400)
@export var blue_spawn: Vector2 = Vector2(280, 400)
@export_range(0.0, 128.0, 1.0) var respawn_edge_margin: float = 0.0
