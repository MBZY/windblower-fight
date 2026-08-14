class_name RoomBrowser
extends Control

const ROOM_ENTRY = preload("res://scenes/ui/room_entry.tscn")

signal back_requested
signal refresh_requested
signal join_ip_requested(host_ip: String)
signal join_room_requested(room: Dictionary)

@onready var room_list: VBoxContainer = $SafeMargin/Content/RoomScroll/RoomList
@onready var status_label: Label = $SafeMargin/Content/StatusLabel
@onready var ip_input: LineEdit = $SafeMargin/Content/ManualJoin/IpInput

var _rooms: Dictionary = {}

func _ready() -> void:
	_set_status("Scanning for LAN rooms...")

func show_rooms(rooms: Array) -> void:
	_rooms.clear()
	for child in room_list.get_children():
		child.queue_free()
	for room_variant in rooms:
		if room_variant is Dictionary:
			_add_room(room_variant)
	_set_status("Found %d room(s)" % _rooms.size() if not _rooms.is_empty() else "No rooms found. Enter a host IP to join.")

func _add_room(room: Dictionary) -> void:
	var host_ip := String(room.get("host_ip", ""))
	if host_ip.is_empty():
		return
	_rooms[host_ip] = room.duplicate(true)
	var row = ROOM_ENTRY.instantiate()
	row.set_room(room)
	row.join_requested.connect(_on_room_entry_join_requested)
	room_list.add_child(row)

func _set_status(text: String) -> void:
	status_label.text = text

func _on_room_entry_join_requested(room: Dictionary) -> void:
	var host_ip := String(room.get("host_ip", ""))
	if host_ip.is_empty():
		return
	join_room_requested.emit(room)

func _on_back_button_pressed() -> void:
	back_requested.emit()

func _on_refresh_button_pressed() -> void:
	refresh_requested.emit()

func _on_join_button_pressed() -> void:
	var host := ip_input.text.strip_edges()
	if not host.is_empty():
		join_ip_requested.emit(host)
