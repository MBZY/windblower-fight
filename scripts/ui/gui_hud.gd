class_name GuiHud
extends Control

@onready var rest_time_label: Label = $VBoxContainer/RestTime
@onready var rest_time_progress: ProgressBar = $VBoxContainer/RestTimeProgress
@onready var winning_progress: TextureProgressBar = $VBoxContainer/HBoxContainer/VBoxContainer/PanelContainer/WiningProgress
@onready var score1_label: Label = $VBoxContainer/HBoxContainer/VBoxContainer/HBoxContainer2/Score1
@onready var score2_label: Label = $VBoxContainer/HBoxContainer/VBoxContainer/HBoxContainer2/Score2
@onready var group_money_label: Label = $VBoxContainer/HBoxContainer/VBoxContainer/HBoxContainer/GroupMoney
@onready var group_money2_label: Label = $VBoxContainer/HBoxContainer/VBoxContainer/HBoxContainer/GroupMoney2
@onready var player_list_a: VBoxContainer = $VBoxContainer/HBoxContainer/PlayerListA
@onready var player_list_b: VBoxContainer = $VBoxContainer/HBoxContainer/PlayerListB
@onready var gacha_alarm: Label = $Gacha/GachaAlarm
@onready var gacha_button: TextureButton = $Gacha/GachaButton
@onready var gacha_panel: MarginContainer = $GachaPanel
@onready var gacha_options: Array[GachaOption] = [
	$GachaPanel/PanelContainer/VBoxContainer/HBoxContainer/GachaOption1,
	$GachaPanel/PanelContainer/VBoxContainer/HBoxContainer/GachaOption2,
	$GachaPanel/PanelContainer/VBoxContainer/HBoxContainer/GachaOption3,
]

var _session: GameSession
var _local_player_id := 1
var _price := 50

func _ready() -> void:
	gacha_panel.visible = false

func bind_session(session: GameSession) -> void:
	_session = session
	_local_player_id = session.local_player_id()
	_price = session.balance.skill_upgrade_price if session.balance != null else _price
	session.score_changed.connect(_on_score_changed)
	session.countdown_changed.connect(_on_countdown_changed)
	session.skill_points_changed.connect(_on_skill_points_changed)
	session.phase_changed.connect(_on_phase_changed)
	session.match_finished.connect(_on_match_finished)
	_on_score_changed(session.red_score, session.blue_score)
	_on_phase_changed(session.phase)
	_refresh_player_lists()
	_update_money_labels()

func _process(_delta: float) -> void:
	if _session == null:
		return
	if _session.phase == &"playing" and _session.match_timer != null:
		var remaining := _session.match_time_left()
		rest_time_label.text = "%ds" % ceili(remaining)
		rest_time_progress.value = 100.0 * (1.0 - remaining / maxf(_session.balance.match_duration_sec, 1.0))
	elif _session.phase == &"countdown":
		rest_time_label.text = "%ds" % ceili(_session.countdown_timer.time_left)
		rest_time_progress.value = 100.0

func _on_score_changed(red: int, blue: int) -> void:
	score1_label.text = str(red)
	score2_label.text = str(blue)
	var total := red + blue
	winning_progress.value = 50.0 if total == 0 else 100.0 * red / float(total)

func _on_countdown_changed(seconds_left: int) -> void:
	rest_time_label.text = "%ds" % seconds_left
	rest_time_progress.value = 100.0

func _on_skill_points_changed(_player_id: int, _points: int) -> void:
	_update_money_labels()
	_refresh_player_lists()

func _on_phase_changed(phase: StringName) -> void:
	match phase:
		&"playing", &"countdown", &"score_lock":
			gacha_panel.visible = false
			$Gacha.visible = true
		&"results":
			$Gacha.visible = false
		_:
			$Gacha.visible = false
			gacha_panel.visible = false

func _on_match_finished(_winner: int, red: int, blue: int) -> void:
	rest_time_label.text = "结束"
	rest_time_progress.value = 100.0

func _update_money_labels() -> void:
	var local := _local_player()
	if local != null:
		gacha_alarm.text = "%d$" % local.skill_points
	var team0 := 0
	var team1 := 0
	if _session != null:
		for player_variant in _session.players.values():
			var player: IslandPlayer = player_variant
			if player.team == 0:
				team0 += player.skill_points
			else:
				team1 += player.skill_points
	group_money_label.text = "%d$" % team0
	group_money2_label.text = "%d$" % team1

func _refresh_player_lists() -> void:
	if _session == null:
		return
	var team_a: Array = []
	var team_b: Array = []
	for player_variant in _session.players.values():
		var player: IslandPlayer = player_variant
		if player.team == 0:
			team_a.append(player)
		else:
			team_b.append(player)
	_fill_player_list(player_list_a, team_a)
	_fill_player_list(player_list_b, team_b)

func _fill_player_list(list_container: VBoxContainer, team_players: Array) -> void:
	for index in range(3):
		var unit: PanelContainer = list_container.get_child(index)
		if index < team_players.size():
			var player: IslandPlayer = team_players[index]
			unit.visible = true
			unit.get_node("PlayerName").text = "玩家%d" % player.player_id
			unit.get_node("PlayerMoney").text = "%d$" % player.skill_points
		else:
			unit.visible = false

func _local_player() -> IslandPlayer:
	if _session == null:
		return null
	_local_player_id = _session.local_player_id()
	return _session.players.get(_local_player_id) as IslandPlayer

func _open_gacha() -> void:
	var player := _local_player()
	if player == null or _session == null or _session.phase != &"playing":
		return
	if player.skill_points < _price:
		gacha_alarm.text = "金币不足!"
		return
	var available := _session.enhancement_catalog.available(player.enhancement_stacks) if _session.enhancement_catalog != null else []
	if available.is_empty():
		gacha_alarm.text = "已全部强化!"
		return
	var picks := _weighted_picks(available, 3)
	for index in range(gacha_options.size()):
		var option: GachaOption = gacha_options[index]
		if index < picks.size():
			var entry: EnhancementEntry = picks[index]
			option.configure(entry, _price, int(player.enhancement_stacks.get(entry.id, 0)))
			option.visible = true
		else:
			option.visible = false
	gacha_panel.visible = true

func _weighted_picks(pool: Array, count: int) -> Array:
	var candidates: Array = pool.duplicate()
	var picks: Array = []
	var total_weight := 0
	for candidate in candidates:
		total_weight += candidate.weight
	while picks.size() < count and not candidates.is_empty():
		var roll := randf() * total_weight
		var pick_index := 0
		for index in range(candidates.size()):
			roll -= candidates[index].weight
			if roll <= 0.0:
				pick_index = index
				break
		var picked: EnhancementEntry = candidates[pick_index]
		picks.append(picked)
		candidates.remove_at(pick_index)
		total_weight -= picked.weight
	return picks

func _on_gacha_option_pressed(option: GachaOption) -> void:
	if _session == null or option.entry == null:
		return
	_local_player_id = _session.local_player_id()
	var result := _session.request_skill_upgrade(_local_player_id, option.entry.id)
	if result.get("ok", false):
		gacha_panel.visible = false
		gacha_alarm.text = "%d$" % _local_player().skill_points
	else:
		gacha_alarm.text = String(result.get("reason", "失败"))

func _on_gacha_skip_pressed() -> void:
	gacha_panel.visible = false

func _on_blow_button_down() -> void:
	if _session != null:
		_session.set_local_blowing(true)

func _on_blow_button_up() -> void:
	if _session != null:
		_session.set_local_blowing(false)
