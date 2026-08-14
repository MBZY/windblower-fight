class_name RoomEntry
extends HBoxContainer

signal join_requested(room: Dictionary)

@onready var summary_label: Label = %Summary
@onready var join_button: Button = %JoinButton

var room: Dictionary = {}

func _ready() -> void:
	# Room entries are instantiated before their owner enters the tree.
	# Refresh once more after @onready references become valid.
	set_room(room)

func set_room(value: Dictionary) -> void:
	room = value.duplicate(true)
	if not is_node_ready():
		return
	summary_label.text = "%s  |  %s  |  %s/%s" % [String(room.get("room_name", "LAN Room")), String(room.get("map_size", "medium")).capitalize(), room.get("players", 0), room.get("max_players", 8)]

func _on_join_pressed() -> void:
	join_requested.emit(room.duplicate(true))
