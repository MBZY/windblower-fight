class_name GameHUD
extends Control

@onready var red_label: Label = $TopMargin/TopRow/RedScore/Value
@onready var blue_label: Label = $TopMargin/TopRow/BlueScore/Value
@onready var timer_label: Label = $TopMargin/TopRow/Timer/Value
@onready var skill_points_label: Label = $PersonalSkillPoints
@onready var event_label: Label = $EventLabel
@onready var respawn_label: Label = $RespawnNotice
@onready var skill_overlay: Control = $SkillOverlay
@onready var option_row: HBoxContainer = $SkillOverlay/Panel/Margin/Content/Options
@onready var skill_title: Label = $SkillOverlay/Panel/Margin/Content/Title

var _session: GameSession
var _local_player_id := 1
var _skill_options: Array[EnhancementEntry] = []

func _ready() -> void:
	event_label.visible = false
	respawn_label.visible = false
	skill_overlay.visible = false

func bind_session(session: GameSession) -> void:
	_session = session
	_local_player_id = multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
	session.skill_points_changed.connect(_on_skill_points_changed)

func _on_score_changed(red: int, blue: int) -> void:
	red_label.text = "RED %d" % red
	blue_label.text = "BLUE %d" % blue

func _on_phase_changed(phase: StringName) -> void:
	timer_label.text = String(phase).to_upper()
	if phase != &"playing":
		skill_overlay.visible = false

func _on_countdown_changed(seconds: int) -> void:
	timer_label.text = str(seconds)

func _on_match_finished(winner: int, red: int, blue: int) -> void:
	timer_label.text = "DRAW" if winner < 0 or red == blue else ("RED WINS" if winner == 0 else "BLUE WINS")
	skill_overlay.visible = false

func _on_skill_points_changed(player_id: int, points: int) -> void:
	if player_id == _local_player_id:
		skill_points_label.text = "技能点 %d" % points

func _on_skills_button_pressed() -> void:
	if _session == null:
		return
	var player: IslandPlayer = _session.players.get(_local_player_id) as IslandPlayer
	if player == null:
		return
	_rebuild_skill_options(player)
	skill_overlay.visible = not skill_overlay.visible

func _rebuild_skill_options(player: IslandPlayer) -> void:
	for child in option_row.get_children():
		child.queue_free()
	_skill_options.clear()
	for entry_variant in _session.enhancement_catalog.entries:
		if not entry_variant is EnhancementEntry:
			continue
		var entry := entry_variant as EnhancementEntry
		var current := int(player.enhancement_stacks.get(entry.id, 0))
		if current >= entry.max_stack:
			continue
		if entry.exclusive_group != StringName():
			var blocked := false
			for other_variant in _session.enhancement_catalog.entries:
				var other := other_variant as EnhancementEntry
				if other != null and other.id != entry.id and other.exclusive_group == entry.exclusive_group and int(player.enhancement_stacks.get(other.id, 0)) > 0:
					blocked = true
					break
			if blocked:
				continue
		_skill_options.append(entry)
		var button := Button.new()
		button.custom_minimum_size = Vector2(140, 64)
		button.text = "%s Lv%d\n%s" % [entry.display_name, current, entry.description]
		button.pressed.connect(_on_skill_option_selected.bind(entry.id))
		option_row.add_child(button)

func _on_skill_option_selected(entry_id: StringName) -> void:
	if _session:
		_session.request_skill_upgrade(_local_player_id, entry_id)

func _on_skill_overlay_close_pressed() -> void:
	skill_overlay.visible = false

func _on_event_announced(message: String) -> void:
	event_label.text = message
	event_label.visible = true
	get_tree().create_timer(2.0).timeout.connect(_hide_event)
	if message.contains("fell"):
		respawn_label.visible = true
	elif message.contains("respawned"):
		respawn_label.visible = false

func _hide_event() -> void:
	if is_instance_valid(event_label):
		event_label.visible = false
