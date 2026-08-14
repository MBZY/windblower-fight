class_name MainMenu
extends Control

signal create_room_requested(room_name: String)
signal browse_rooms_requested
signal join_ip_requested(host_ip: String)

@onready var ip_input: LineEdit = %IpInput

func _on_create_room_pressed() -> void:
	create_room_requested.emit("Sky Leaf Room")

func _on_find_rooms_pressed() -> void:
	browse_rooms_requested.emit()

func _on_join_ip_pressed() -> void:
	var host := ip_input.text.strip_edges()
	if not host.is_empty():
		join_ip_requested.emit(host)

