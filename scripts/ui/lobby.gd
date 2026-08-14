class_name LobbyView
extends Control

signal leave_requested
signal start_requested
signal team_requested(team: int)
signal map_requested(map_id: StringName)

@onready var room_status: Label = $SafeMargin/Content/RoomStatus
@onready var red_roster: Label = $SafeMargin/Content/Teams/RedTeam/Contents/Roster
@onready var blue_roster: Label = $SafeMargin/Content/Teams/BlueTeam/Contents/Roster
@onready var map_select: OptionButton = $SafeMargin/Content/MapPanel/MapContents/MapSelect
@onready var start_button: Button = $SafeMargin/Content/StartButton
@onready var host_badge: Label = $SafeMargin/Content/Header/HostBadge

var is_host: bool = true
var _map_ids := [StringName("small"), StringName("medium"), StringName("large")]

func _ready() -> void:
	start_button.disabled = not is_host
	map_select.disabled = not is_host
	host_badge.visible = is_host

func set_host(value: bool) -> void:
	is_host = value
	if is_node_ready():
		start_button.disabled = not value
		map_select.disabled = not value
		host_badge.visible = value

func set_room_snapshot(room: Dictionary, players: Array) -> void:
	room_status.text = "%s  |  %s  |  %s" % [String(room.get("room_name", "LAN Room")), String(room.get("state", "waiting")).capitalize(), "%d players" % players.size()]
	set_map_id(StringName(String(room.get("map_id", "medium"))))
	var red: Array[String] = []
	var blue: Array[String] = []
	for player_variant in players:
		if not player_variant is Dictionary:
			continue
		var player: Dictionary = player_variant
		var line := "%s  (#%s)" % [String(player.get("display_name", "Player")), str(player.get("peer_id", 0))]
		if int(player.get("team", 0)) == 0:
			red.append(line)
		else:
			blue.append(line)
	red_roster.text = "\n".join(red) if not red.is_empty() else "Waiting for players"
	blue_roster.text = "\n".join(blue) if not blue.is_empty() else "Waiting for players"

func set_map_id(map_id: StringName) -> void:
	var index := _map_ids.find(map_id)
	if index >= 0:
		map_select.select(index)

func _on_leave_button_pressed() -> void:
	leave_requested.emit()

func _on_start_button_pressed() -> void:
	start_requested.emit()

func _on_red_join_pressed() -> void:
	team_requested.emit(0)

func _on_blue_join_pressed() -> void:
	team_requested.emit(1)

func _on_map_select_item_selected(index: int) -> void:
	if index >= 0 and index < _map_ids.size():
		map_requested.emit(_map_ids[index])
