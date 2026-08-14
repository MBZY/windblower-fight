class_name LobbyView
extends Control

signal leave_requested
signal start_requested
signal team_requested(team: int)

@onready var room_status: Label = $SafeMargin/Content/RoomStatus
@onready var red_roster: Label = $SafeMargin/Content/Teams/RedTeam/Contents/Roster
@onready var blue_roster: Label = $SafeMargin/Content/Teams/BlueTeam/Contents/Roster
@onready var start_button: Button = $SafeMargin/Content/StartButton
@onready var host_badge: Label = $SafeMargin/Content/Header/HostBadge

var is_host: bool = true

func _ready() -> void:
	start_button.disabled = not is_host
	host_badge.visible = is_host

func set_host(value: bool) -> void:
	is_host = value
	if is_node_ready():
		start_button.disabled = not value
		host_badge.visible = value

func set_room_snapshot(room: Dictionary, players: Array) -> void:
	var state := String(room.get("state", "waiting"))
	var state_text: String = String({
		"waiting": "等待中",
		"lobby": "准备中",
		"countdown": "倒计时",
		"playing": "游戏中",
		"score_lock": "结算中",
		"results": "已结束",
	}.get(state, state.capitalize()))
	room_status.text = "%s  ·  %s  ·  %d 名玩家" % [String(room.get("room_name", "局域网房间")), state_text, players.size()]
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
	red_roster.text = "\n".join(red) if not red.is_empty() else "等待玩家加入…"
	blue_roster.text = "\n".join(blue) if not blue.is_empty() else "等待玩家加入…"
func _on_leave_button_pressed() -> void:
	leave_requested.emit()

func _on_start_button_pressed() -> void:
	start_requested.emit()

func _on_red_join_pressed() -> void:
	team_requested.emit(0)

func _on_blue_join_pressed() -> void:
	team_requested.emit(1)

func _on_map_select_item_selected(_index: int) -> void:
	return
