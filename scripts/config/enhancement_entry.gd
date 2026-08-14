class_name EnhancementEntry
extends Resource

@export var id: StringName
@export var display_name: String = "Enhancement"
@export_multiline var description: String = ""
@export var weight: int = 10
@export var max_stack: int = 5
@export var value_per_stack: float = 0.1
@export var target_stat: StringName = &"blower_force"
@export var exclusive_group: StringName

